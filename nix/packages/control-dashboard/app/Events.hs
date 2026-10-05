{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields, LambdaCase, DataKinds, RequiredTypeArguments #-}
-- | Runs of control-events as seen on the MQTT broker, how they relate, and
-- what's wrong with them.
module Events
  ( Run (..), pendingTriggers, rootCause
  , State (..), newState, mqttLoop, sendTrigger
  , Index (..), index, topLevel, latestRuns, isCritical
  , problems, duration, timedOut, prune
  , fmtDuration
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Events (Conn, EventId (..), EvtDone (..), EvtMsg (..), Rules (..), SessionData (..), StaticTopic, Timed (..), Trigger (..), done, event, evtReactions, react, reacted, simple, waitConnDisconnect, withConn, withMsg, withPersistentConn, (&), (.~), (?~))
import Control.Exception (SomeException, try)
import Control.Monad (forever, unless)
import Data.Aeson (Value (..))
import Data.List (sortOn, unsnoc)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Ord (Down (..))
import qualified Data.Set as Set
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import Data.UUID (UUID)
import Network.MQTT.Topic (Filter, Topic, match, split, unFilter, unTopic)

-- | A run of an event: how it started and, once finished, how it ended.
data Run = Run
  { eid :: EventId
  , start :: Timed (EvtMsg Value)
  , end :: Maybe (Timed EvtDone)
  }

--------------------------------------------------------------------------------

data State = State
  { runs :: TVar (Map UUID Run) -- ^ by correlation id
  , connected :: TVar Bool -- ^ to the broker
  }

newState :: IO State
newState = State <$> newTVarIO Map.empty <*> newTVarIO False

-- | Stay subscribed to every event, reconnecting if the broker goes away.
--
-- A finish arriving over twice its timeout after its start, or whose start
-- came before a restart or reconnect, is lost (see control-events).
--
-- A persistent session keeps a fixed client id, and the broker queues messages
-- for up to a day while we're away. Otherwise the broker assigns a fresh id, so
-- other instances (e.g. dev runs) can't take over the persistent session.
mqttLoop :: Bool -> State -> IO ()
mqttLoop persistent st = forever $ do
  r <- try @SomeException $
    if persistent
      then withPersistentConn (SPersistentSession @'["#"] "control-dashboard") base listen
      else withConn base listen
  atomically $ writeTVar st.connected False
  putStrLn ("mqtt: " <> either show (const "disconnected") r)
  threadDelay 5_000_000
  where
    base = "server/control-dashboard"
    listen :: StaticTopic s "#" => Conn s -> IO ()
    listen c = do
      atomically $ writeTVar st.connected True
      _ <- react c "#" (\eid s -> started eid s >> pure (finished eid))
      waitConnDisconnect c
    started eid s = unless (isTest eid.evtTopic) $ atomically $ modifyTVar' st.runs (prune . Map.insert eid.correlationId (Run eid s Nothing))
    finished eid e = atomically $ modifyTVar' st.runs (Map.adjust (\r -> r {end = Just e}) eid.correlationId)

-- | Events on test/... topics are ignored.
isTest :: Topic -> Bool
isTest t = "test/" `T.isPrefixOf` unTopic t

-- | Send a trigger announced by a run, as an event reacting to that run. Like
-- any event it's a run of its own, which whoever listens on the trigger's
-- topic is expected to react to. Returns its correlation id.
sendTrigger :: Run -> Trigger -> IO UUID
sendTrigger r t = case splitLast t.triggerTopic of
  Just (base, leaf) -> withConn base $ \c -> event c leaf msg $ \e -> pure (done "Sent" e.correlationId)
  _ -> fail ("A trigger's topic needs at least two levels, unlike " <> show (unTopic t.triggerTopic))
  where
    msg = simple t.triggerLabel & withMsg .~ t.triggerData & reacted ?~ r.eid & evtReactions ?~ ["#"]

-- | A topic's levels but the last, and its last, if it has at least two.
splitLast :: Topic -> Maybe (Topic, Topic)
splitLast tp = case unsnoc (split tp) of
  Just (l : ls, leaf) -> Just (foldl (<>) l ls, leaf)
  _ -> Nothing

-- | Bound memory: past 20000 runs, keep only the latest 500 top-level runs of
-- each topic, with their subtasks.
prune :: Map UUID Run -> Map UUID Run
prune m
  | Map.size m <= 20000 = m
  | otherwise = Map.restrictKeys m (Set.fromList (concatMap (tree ix) kept))
  where
    ix = index m
    kept = concatMap (take 500 . topLevel ix) (Map.keys ix.byTopic)

-- | A run and, recursively, its subtasks.
tree :: Index -> Run -> [UUID]
tree ix r = r.eid.correlationId : concatMap (tree ix) (Map.findWithDefault [] r.eid.correlationId ix.scopedTo)

--------------------------------------------------------------------------------

-- | Runs arranged for lookups, each list newest first.
data Index = Index
  { runs :: Map UUID Run
  , byTopic :: Map Topic [Run]
  , scopedTo :: Map UUID [Run] -- ^ the runs scoped to each run
  , reactingTo :: Map UUID [Run] -- ^ the runs reacting to each run
  }

index :: Map UUID Run -> Index
index runs = Index
  { runs
  , byTopic = by (Just . (.eid.evtTopic))
  , scopedTo = by (fmap (.correlationId) . (.start.e.scope))
  , reactingTo = by (fmap (.correlationId) . (.start.e.reactTo))
  }
  where
    by k = Map.fromListWith (flip (++)) [(p, [r]) | r <- sortOn (Down . (.start.at)) (Map.elems runs), Just p <- [k r]]

-- | The triggers a run announced when it finished that haven't been sent yet,
-- each with its position among all it announced. Triggers are one-shot: one
-- counts as sent once a run reacting to the run is seen on its topic.
pendingTriggers :: Index -> Run -> [(Int, Trigger)]
pendingTriggers ix r = [(i, t) | (i, t) <- zip [0 ..] (foldMap (fromMaybe [] . (.e.triggers)) r.end), t.triggerTopic `notElem` sent]
  where sent = map (.eid.evtTopic) (Map.findWithDefault [] r.eid.correlationId ix.reactingTo)

-- | The first run in the chain of reactions a run is part of.
rootCause :: Index -> Run -> Run
rootCause ix r = maybe r (rootCause ix) (r.start.e.reactTo >>= \e -> Map.lookup e.correlationId ix.runs)

-- | Whether a run is critical: marked so, or part of or reacting to a
-- critical run.
isCritical :: Index -> Run -> Bool
isCritical ix r = r.start.e.rules.critical || any (isCritical ix) [p | Just e <- [r.start.e.scope, r.start.e.reactTo], Just p <- [Map.lookup e.correlationId ix.runs]]

-- | The top-level runs of a topic, i.e. not scoped to another, newest first.
topLevel :: Index -> Topic -> [Run]
topLevel ix t = filter (isNothing . (.start.e.scope)) (Map.findWithDefault [] t ix.byTopic)

-- | The latest run of each top-level event, i.e. not scoped to another.
latestRuns :: Index -> [Run]
latestRuns ix = [r | rs <- Map.elems ix.byTopic, r <- take 1 rs, isNothing r.start.e.scope]

-- | How long a run took, or has been running for.
duration :: UTCTime -> Run -> NominalDiffTime
duration now r = diffUTCTime (maybe now (.at) r.end) r.start.at

-- | Everything wrong with a run at the given time, each with an explanation:
-- whether it failed, and each rule it broke. The run is overdue if the next
-- run on its topic, which may not have started yet, started too late after
-- it. Subtasks are given the run's timeout to show up; a reaction is missing
-- until it arrives, and awaits the trigger the run announced for it, if any.
-- A subtask's problems are the run's too.
problems :: UTCTime -> Index -> Run -> [(Text, Text)]
problems now ix r =
  [ ("failed", "Finished unsuccessfully" <> foldMap (": " <>) (nonEmpty e.e.summary) <> foldMap (" — " <>) (firstLine e.e.result))
    | Just e <- [r.end], not e.e.success ]
    ++ [ ("timed out", (if isJust r.end then "Took " else "No finish after ") <> fmtDuration taken <> "; the limit is " <> fmtDuration limit <> ".") | timedOut now r ]
    ++ [ ("overdue", overdue d) | Just d <- [rules.expected], gap > d + grace ]
    ++ [p | diffUTCTime now r.start.at > limit, p <- none "subtasks" (unmatched [fromString (T.unpack (unTopic r.eid.evtTopic) <> "/" <> s) | s <- fromMaybe [] rules.subtasks] ix.scopedTo)]
    ++ [("failed subtasks", T.intercalate "; " fs <> ".") | let fs = failedSubtasks, not (null fs)]
    ++ [("awaiting trigger", "Not yet sent: " <> T.intercalate ", " (map (T.pack . (.triggerLabel)) awaited) <> ".") | not (null awaited)]
    ++ none "reactions" [f | f <- reactions, not (any (match f . (.triggerTopic)) awaited)]
  where
    rules = r.start.e.rules
    taken = duration now r
    limit = fromIntegral rules.timeout
    next = listToMaybe (reverse (takeWhile (> r.start.at) [s.start.at | s <- Map.findWithDefault [] r.eid.evtTopic ix.byTopic]))
    gap = diffUTCTime (fromMaybe now next) r.start.at
    overdue d = "The next run was expected within " <> fmtDuration d <> " (+" <> fmtDuration grace <> " grace)" <> case next of
      Nothing -> ", but none has started in " <> fmtDuration gap <> "."
      Just _ -> ", but it started " <> fmtDuration gap <> " later."
    -- Each filter must match the topic of a related run.
    unmatched :: [Filter] -> Map UUID [Run] -> [Filter]
    unmatched fs m = [f | f <- fs, not (any (match f . (.eid.evtTopic)) (Map.findWithDefault [] r.eid.correlationId m))]
    none name fs = [(name, "None matching " <> T.intercalate ", " (map unFilter fs) <> ".") | not (null fs)]
    -- A missing reaction a pending trigger would provide is waiting on it.
    reactions = unmatched (fromMaybe [] rules.reactions) ix.reactingTo
    awaited = [t | (_, t) <- pendingTriggers ix r, any (`match` t.triggerTopic) reactions]
    failedSubtasks = [unTopic s.eid.evtTopic <> ": " <> T.intercalate ", " (map fst ps) | s <- Map.findWithDefault [] r.eid.correlationId ix.scopedTo, let ps = problems now ix s, not (null ps)]
    nonEmpty s = if null s then Nothing else Just (T.pack s)
    firstLine = \case
      Just (String t) | not (T.null t) -> Just (T.takeWhile (/= '\n') t)
      _ -> Nothing

-- | Whether a run took, or has been running for, longer than its timeout.
timedOut :: UTCTime -> Run -> Bool
timedOut now r = duration now r > fromIntegral r.start.e.rules.timeout

-- | Leeway on 'expected', so a run expected every minute doesn't race its
-- own schedule.
grace :: NominalDiffTime
grace = 60

-- | A short human duration, e.g. @340ms@, @4.2s@, @3m 12s@, @2h 5m@, @3d 4h@.
fmtDuration :: NominalDiffTime -> Text
fmtDuration d
  | ms < 1000 = tshow ms <> "ms"
  | s < 10 = tshow (fromIntegral (ms `div` 100) / 10 :: Double) <> "s"
  | s < 60 = tshow s <> "s"
  | s < 3600 = tshow (s `div` 60) <> "m" <> unit (s `mod` 60) "s"
  | s < 86400 = tshow (s `div` 3600) <> "h" <> unit (s `mod` 3600 `div` 60) "m"
  | otherwise = tshow (s `div` 86400) <> "d" <> unit (s `mod` 86400 `div` 3600) "h"
  where
    ms = round (d * 1000) :: Integer
    s = ms `div` 1000
    unit n u = if n == 0 then "" else " " <> tshow n <> u
    tshow :: Show a => a -> Text
    tshow = T.pack . show
