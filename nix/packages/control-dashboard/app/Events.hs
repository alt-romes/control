{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields, LambdaCase #-}
module Events
  ( Run (..), pendingTriggers
  , State (..), newState, mqttLoop, sleepLoop, willLoop, sendTrigger, started, finished, willed
  , Index (..), index, topLevel, latestRuns, isCritical
  , problems, duration, timedOut, prune
  , fmtDuration, trySync
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Events (Conn, EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), Trigger (..), done, event, evtReactions, newPersistentSession, react, reacted, reactedMany, simple, waitConnDisconnect, withConn, withMsg, withPersistentConn, (&), (.~), (?~), (^.))
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad (forM_, forever, unless, when)
import Data.Aeson (Value (..), decodeStrict)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (sortOn, unsnoc)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust, fromMaybe, isJust, isNothing, listToMaybe, maybeToList)
import Data.Ord (Down (..))
import qualified Data.Set as Set
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import Network.MQTT.Client (MessageCallback (..), ProtocolLevel (..), connectURI, mqttConfig, subOptions, subscribe, waitForClient, _msgCB, _protocol)
import Network.MQTT.Topic (Filter, Topic, match, split, unFilter, unTopic)
import Network.URI (parseURI)

data Run = Run
  { eid :: EventId
  , start :: Timed (EvtMsg Value)
  , end :: Maybe (Timed EvtDone)
  }

data State = State
  { runs :: TVar (Map UUID Run)
  , connected :: TVar Bool
  , sleeps :: TVar [(UTCTime, UTCTime)]
  , wills :: TVar [(Topic, UTCTime)]
    -- ^ The service topics whose connections died, and when
  , bootedAt :: UTCTime
  }

newState :: IO State
newState = State <$> newTVarIO Map.empty <*> newTVarIO False <*> newTVarIO [] <*> newTVarIO [] <*> getCurrentTime

-- | A connection's last will: it died without saying goodbye, so whatever it
-- was waiting for, nobody is anymore.
willLoop :: State -> IO ()
willLoop st = forever $ do
  r <- trySync $ do
    c <- connectURI mqttConfig {_msgCB = SimpleCallback (\_ t _ _ -> getCurrentTime >>= willed st t), _protocol = Protocol50} (fromJust (parseURI "mqtt://127.0.0.1"))
    _ <- subscribe c [(f, subOptions) | f <- ["+/last-will-testament", "+/+/last-will-testament", "+/+/+/last-will-testament"]] []
    waitForClient c
  putStrLn ("mqtt wills: " <> either show (const "disconnected") r)
  threadDelay 5_000_000

willed :: State -> Topic -> UTCTime -> IO ()
willed st t at = forM_ (T.stripSuffix "/last-will-testament" (unTopic t)) $ \base ->
  atomically $ modifyTVar' st.wills (take 200 . ((fromString (T.unpack base), at) :))

sleepLoop :: State -> IO ()
sleepLoop st = getCurrentTime >>= go
  where
    go t = do
      threadDelay 5_000_000
      t' <- getCurrentTime
      when (diffUTCTime t' t > 30) $ atomically (modifyTVar' st.sleeps (take 1000 . ((t, t') :)))
      go t'

-- | With a persistent session the broker queues messages for a day while
-- we're away; without one it assigns a fresh id, so dev runs can't take it over.
mqttLoop :: Maybe String -> State -> IO ()
mqttLoop persistent st = do
  session <- traverse newPersistentSession persistent
  forever $ do
    r <- trySync $
      case session of
        Just s -> withPersistentConn s base listen
        Nothing -> withConn base listen
    atomically $ writeTVar st.connected False
    putStrLn ("mqtt: " <> either show (const "disconnected") r)
    threadDelay 5_000_000
  where
    base = "server/control-dashboard"
    listen :: Conn s -> IO ()
    listen c = do
      atomically $ writeTVar st.connected True
      _ <- react c "#" (\eid s -> started st eid s >> pure (finished st eid))
      waitConnDisconnect c

started :: State -> EventId -> Timed (EvtMsg Value) -> IO ()
started st eid s = unless (isTest eid.evtTopic) $ atomically $ modifyTVar' st.runs (prune . Map.insert eid.correlationId (Run eid s Nothing))

finished :: State -> EventId -> Timed EvtDone -> IO ()
finished st eid e = atomically $ modifyTVar' st.runs (Map.adjust (\r -> r {end = Just e}) eid.correlationId)

-- | Rethrows asynchronous exceptions, so the thread still stops when told to.
trySync :: IO a -> IO (Either SomeException a)
trySync act = try act >>= \case
  Left e | Just _ <- fromException @SomeAsyncException e -> throwIO e
  r -> pure r

isTest :: Topic -> Bool
isTest t = "test/" `T.isPrefixOf` unTopic t

sendTrigger :: Run -> Trigger -> IO UUID
sendTrigger r t = case splitLast t.triggerTopic of
  Just (base, leaf) -> withConn base $ \c -> event c leaf msg $ \e -> pure (done "Sent" e.correlationId)
  _ -> fail ("A trigger's topic needs at least two levels, unlike " <> show (unTopic t.triggerTopic))
  where
    msg = simple t.triggerLabel & withMsg .~ t.triggerData & reacted ?~ r.eid & evtReactions ?~ ["#"]

splitLast :: Topic -> Maybe (Topic, Topic)
splitLast tp = case unsnoc (split tp) of
  Just (l : ls, leaf) -> Just (foldl (<>) l ls, leaf)
  _ -> Nothing

prune :: Map UUID Run -> Map UUID Run
prune m
  | Map.size m <= 20000 = m
  | otherwise = Map.restrictKeys m (Set.fromList (concatMap (tree ix) kept))
  where
    ix = index m
    kept = concatMap (take 500 . topLevel ix) (Map.keys ix.byTopic)

tree :: Index -> Run -> [UUID]
tree ix r = r.eid.correlationId : concatMap (tree ix) (Map.findWithDefault [] r.eid.correlationId ix.scopedTo)

data Index = Index
  { runs :: Map UUID Run
  , byTopic :: Map Topic [Run]
  , scopedTo :: Map UUID [Run]
  , reactingTo :: Map UUID [Run]
  }

index :: Map UUID Run -> Index
index runs = Index
  { runs
  , byTopic = by (Just . (.eid.evtTopic))
  , scopedTo = by (fmap (.correlationId) . (.start.e.scope))
  , reactingTo = byMany (maybe [] (map (.correlationId)) . (^. reactedMany) . (.start.e))
  }
  where
    by k = byMany (maybeToList . k)
    byMany k = Map.fromListWith (flip (++)) [(p, [r]) | r <- sortOn (Down . (.start.at)) (Map.elems runs), p <- k r]

-- | Triggers are one-shot: sent once a run reacting to the run is seen on its topic.
pendingTriggers :: Index -> Run -> [(Int, Trigger)]
pendingTriggers ix r = [(i, t) | (i, t) <- zip [0 ..] (foldMap (fromMaybe [] . (.e.triggers)) r.end), t.triggerTopic `notElem` sent]
  where sent = map (.eid.evtTopic) (Map.findWithDefault [] r.eid.correlationId ix.reactingTo)

isCritical :: Index -> Run -> Bool
isCritical ix r = r.start.e.rules.critical == Just True || any (isCritical ix) [p | Just e <- [r.start.e.scope, r.start.e ^. reacted], Just p <- [Map.lookup e.correlationId ix.runs]]

topLevel :: Index -> Topic -> [Run]
topLevel ix t = filter (isNothing . (.start.e.scope)) (Map.findWithDefault [] t ix.byTopic)

latestRuns :: Index -> [Run]
latestRuns ix = [r | rs <- Map.elems ix.byTopic, r <- take 1 rs, isNothing r.start.e.scope]

duration :: UTCTime -> Run -> NominalDiffTime
duration now r = diffUTCTime (maybe now (.at) r.end) r.start.at

-- | Overdue is judged by when the next run started (or now), not counting time
-- asleep. Subtasks get the run's timeout to show up.
problems :: [(UTCTime, UTCTime)] -> UTCTime -> Index -> Run -> [(Text, Text)]
problems sleeps now ix r =
  [ ("failed", fromMaybe "Failed" (nonEmpty e.e.summary >>= gist . said) <> foldMap (" — " <>) (case e.e.result of Just (String t) -> gist t; _ -> Nothing))
    | Just e <- [r.end], not e.e.success ]
    ++ [ ("timed out", (if isJust r.end then "Took " else "No finish after ") <> fmtDuration taken <> "; the limit is " <> fmtDuration limit <> ".") | timedOut now r ]
    ++ [ ("overdue", overdue d) | Just d <- [rules.expected], gap > d + grace ]
    ++ [p | diffUTCTime now r.start.at > limit, p <- none "subtasks" "No subtask yet matching " (unmatched [fromString (T.unpack (unTopic r.eid.evtTopic) <> "/" <> s) | s <- fromMaybe [] rules.subtasks] ix.scopedTo)]
    ++ [("failed subtasks", "Subtasks with problems: " <> T.intercalate "; " fs <> ".") | let fs = failedSubtasks, not (null fs)]
    ++ [("awaiting trigger", "Not yet sent: " <> T.intercalate ", " (map (T.pack . (.triggerLabel)) awaited) <> ".") | not (null awaited)]
    ++ none "reactions" "No reaction yet matching " [f | f <- reactions, not (any (match f . (.triggerTopic)) awaited)]
  where
    rules = r.start.e.rules
    taken = duration now r
    limit = fromIntegral rules.timeout
    next = listToMaybe (reverse (takeWhile (> r.start.at) [s.start.at | s <- Map.findWithDefault [] r.eid.evtTopic ix.byTopic]))
    gap = awake sleeps r.start.at (fromMaybe now next)
    overdue d = "The next run was expected within " <> fmtDuration d <> " (+" <> fmtDuration grace <> " grace)" <> case next of
      Nothing -> ", but none has started in " <> fmtDuration gap <> "."
      Just _ -> ", but it started " <> fmtDuration gap <> " later."
    unmatched :: [Filter] -> Map UUID [Run] -> [Filter]
    unmatched fs m = [f | f <- fs, not (any (match f . (.eid.evtTopic)) (Map.findWithDefault [] r.eid.correlationId m))]
    none name what fs = [(name, what <> T.intercalate ", " (map unFilter fs) <> ".") | not (null fs)]
    reactions = unmatched (fromMaybe [] rules.reactions) ix.reactingTo
    awaited = [t | (_, t) <- pendingTriggers ix r, any (`match` t.triggerTopic) reactions]
    failedSubtasks = [unTopic s.eid.evtTopic <> ": " <> T.intercalate ", " (map fst ps) | s <- Map.findWithDefault [] r.eid.correlationId ix.scopedTo, let ps = problems sleeps now ix s, not (null ps)]
    nonEmpty s = if null s then Nothing else Just (T.pack s)
    -- The gist: a JSON error says it in its message, and the rest is in the run.
    said t = case decodeStrict (T.encodeUtf8 t) of
      Just (Object o) | m : _ <- [m | (k, String m) <- KM.toList o, T.toLower (K.toText k) `elem` ["message", "error"]] -> m
      _ -> t
    -- The first line saying something, not blank nor a heading for what follows, cut short.
    gist t = case [l | l <- map T.strip (T.lines t), not (T.null l), not (":" `T.isSuffixOf` l)] of
      l : _ | Just code <- after "statusCode = " l -> Just ("HTTP " <> code <> foldMap (" from " <>) (T.dropAround (== '"') <$> after "Host = " l))
            | otherwise -> Just (if T.length l > 80 then T.take 80 l <> "…" else l)
      [] -> Nothing
    -- The word after a marker, as in a shown HTTP request or response.
    after m l = case T.breakOn m l of
      (_, rest) | not (T.null rest) -> Just (T.takeWhile (\ch -> ch /= ',' && ch /= '}' && ch /= ' ') (T.drop (T.length m) rest))
      _ -> Nothing

awake :: [(UTCTime, UTCTime)] -> UTCTime -> UTCTime -> NominalDiffTime
awake sleeps a b = diffUTCTime b a - sum [diffUTCTime (min b s1) (max a s0) | (s0, s1) <- sleeps, s0 < b, s1 > a]

timedOut :: UTCTime -> Run -> Bool
timedOut now r = duration now r > fromIntegral r.start.e.rules.timeout

-- | So a run expected every minute doesn't race its own schedule.
grace :: NominalDiffTime
grace = 60

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
