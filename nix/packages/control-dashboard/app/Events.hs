{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields, LambdaCase #-}
-- | Runs of control-events as seen on the MQTT broker, how they relate, and
-- what's wrong with them.
module Events
  ( Run (..), localRun, triggersOf
  , State (..), newState, mqttLoop, sendTrigger
  , Index (..), index, latestRuns
  , problems, duration, grace, prune
  , isHealthcheck, forgetHealthy
  , fmtDuration
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), Trigger (..), done, event, reacted, simple, withConn, withMsg, (&), (.~), (?~))
import Control.Exception (SomeException, try)
import Control.Monad (forever, void)
import Data.Aeson (Value (..), decode)
import qualified Data.ByteString as BS
import Data.List (sortOn, unsnoc)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust, fromMaybe, isJust, isNothing, listToMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V5 as UUID
import Network.MQTT.Client
import Network.MQTT.Topic (Filter, match, split, unFilter, unTopic)
import Network.URI (parseURI)

-- | A run of an event: how it started and, once finished, how it ended.
data Run = Run
  { eid :: EventId
  , start :: Timed (EvtMsg Value)
  , end :: Maybe (Timed EvtDone)
  , followedAt :: Maybe UTCTime -- ^ when the next run on its topic started, if remembered
  }

-- | A run the dashboard knows of itself rather than from the broker, over as
-- soon as it starts. Its id is derived from its topic and start, so making it
-- again gives the same run.
localRun :: Topic -> UTCTime -> EvtMsg () -> (EvtDone, ()) -> Run
localRun tp at msg (d, ()) = Run (EventId u tp) (Timed at (msg & withMsg .~ Nothing)) (Just (Timed at d)) Nothing
  where u = UUID.generateNamed UUID.namespaceURL (BS.unpack (encodeUtf8 (unTopic tp <> "@" <> T.pack (show at))))

-- | The triggers a run announced when it finished.
triggersOf :: Run -> [Trigger]
triggersOf r = foldMap (fromMaybe [] . (.x.triggers)) r.end

--------------------------------------------------------------------------------

data State = State
  { runs :: TVar (Map UUID Run) -- ^ by correlation id
  , broker :: TVar (Maybe MQTTClient) -- ^ while connected
  , acked :: TVar (Set UUID) -- ^ critical failures acknowledged
  }

newState :: IO State
newState = State <$> newTVarIO Map.empty <*> newTVarIO Nothing <*> newTVarIO Set.empty

-- | Stay subscribed to every event, reconnecting if the broker goes away.
-- Messages are handled in order, so a run's start comes before its finish:
-- the publisher waits for the broker to have the start.
--
-- A persistent session keeps a fixed client id, and the broker queues messages
-- for up to a day while we're away. Otherwise the broker assigns a fresh id, so
-- other instances (e.g. dev runs) can't take over the persistent session.
mqttLoop :: Bool -> State -> IO ()
mqttLoop persistent st = forever $ do
  r <- try @SomeException $ do
    mc <- connectURI mqttConfig {_msgCB = OrderedCallback onMsg, _protocol = Protocol50, _cleanSession = not persistent, _connProps = sessionProps} uri
    void $ subscribe mc [("#", subOptions {_subQoS = QoS2})] []
    atomically $ writeTVar st.broker (Just mc)
    waitForClient mc
  atomically $ writeTVar st.broker Nothing
  putStrLn ("mqtt: " <> either show (const "disconnected") r)
  threadDelay 5_000_000
  where
    -- connectURI takes the client id from the fragment, ignoring '_connID'.
    uri = fromJust (parseURI ("mqtt://127.0.0.1:1883" <> if persistent then "#control-dashboard" else ""))
    sessionProps = [PropSessionExpiryInterval 86400 | persistent]
    onMsg _ tp body props = atomically $
      case (unsnoc (split tp), listToMaybe [u | PropCorrelationData c <- props, Just u <- [UUID.fromLazyASCIIBytes c]]) of
        (Just (l : ls, kind), Just u)
          | kind == "start", Just s <- decode body, let t = foldl (<>) l ls ->
              modifyTVar' st.runs (prune . forgetHealthy s.at t . Map.insert u (Run (EventId u t) s Nothing Nothing))
          | kind == "finished", Just e <- decode body -> modifyTVar' st.runs (Map.adjust (\r -> r {end = Just e}) u)
        _ -> pure ()

-- | Send a trigger announced by a run, as an event reacting to that run. Like
-- any event it's a run of its own, which whoever listens on the trigger's
-- topic is expected to react to within its timeout. Returns its correlation id.
sendTrigger :: Run -> Trigger -> IO UUID
sendTrigger r t = case unsnoc (split t.triggerTopic) of
  Just (b : bs, leaf) -> withConn (foldl (<>) b bs) $ \c -> event c msg leaf $ \e -> pure (done "Sent" e.correlationId)
  _ -> fail ("A trigger's topic needs at least two levels, unlike " <> show (unTopic t.triggerTopic))
  where
    msg0 = simple t.triggerLabel & withMsg .~ t.triggerData & reacted ?~ r.eid
    msg = msg0 {rules = msg0.rules {reactions = Just ["#"]}}

-- | Bound memory: past 20000 runs, keep only the latest 500 top-level runs of
-- each topic, with their subtasks.
prune :: Map UUID Run -> Map UUID Run
prune m
  | Map.size m <= 20000 = m
  | otherwise = Map.restrictKeys m (Set.fromList (concatMap tree kept))
  where
    ix = index m
    kept = concatMap (take 500 . filter (isNothing . (.start.x.scope))) (Map.elems ix.byTopic)
    tree r = r.eid.correlationId : concatMap tree (Map.findWithDefault [] r.eid.correlationId ix.scopedTo)

-- | Healthchecks run often and alike, so only what went wrong with them is
-- worth keeping.
isHealthcheck :: Topic -> Bool
isHealthcheck t = take 1 (split t) == ["healthcheck"]

-- | Forget the healthy top-level runs of a healthcheck, once settled, but its
-- first and latest: what's left is what went wrong, and since when it's
-- known. Each run kept remembers when the next started, which may be
-- forgotten, so it isn't then overdue.
forgetHealthy :: UTCTime -> Topic -> Map UUID Run -> Map UUID Run
forgetHealthy now t m
  | isHealthcheck t = foldr step m (zip (drop 1 rs) rs)
  | otherwise = m
  where
    ix = index m
    rs = filter (isNothing . (.start.x.scope)) (Map.findWithDefault [] t ix.byTopic)
    first = map (.eid.correlationId) (take 1 (reverse rs))
    step (r, newer)
      | healthy r && r.eid.correlationId `notElem` first = Map.delete r.eid.correlationId
      | otherwise = Map.insert r.eid.correlationId r {followedAt = r.followedAt <|> Just newer.start.at}
    healthy r = isJust r.end && diffUTCTime now r.start.at > fromIntegral r.start.x.rules.timeout && null (problems now ix r)

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
  , scopedTo = by (fmap (.correlationId) . (.start.x.scope))
  , reactingTo = by (fmap (.correlationId) . (.start.x.reactTo))
  }
  where
    by k = Map.fromListWith (flip (++)) [(p, [r]) | r <- sortOn (Down . (.start.at)) (Map.elems runs), Just p <- [k r]]

-- | The latest run of each top-level event, i.e. not scoped to another.
latestRuns :: Index -> [Run]
latestRuns ix = [r | rs <- Map.elems ix.byTopic, r <- take 1 rs, isNothing r.start.x.scope]

-- | How long a run took, or has been running for.
duration :: UTCTime -> Run -> NominalDiffTime
duration now r = diffUTCTime (maybe now (.at) r.end) r.start.at

-- | Everything wrong with a run at the given time, each with an explanation:
-- whether it failed, and each rule it broke. The run is overdue if the next
-- run on its topic, which may not have started yet, started too late. Related
-- runs are given the run's timeout to show up.
problems :: UTCTime -> Index -> Run -> [(Text, Text)]
problems now ix r =
  [ ("failed", "Finished unsuccessfully" <> foldMap (": " <>) (nonEmpty e.x.summary) <> foldMap (" — " <>) (firstLine e.x.result))
    | Just e <- [r.end], not e.x.success ]
    ++ [ ("timed out", (if isJust r.end then "Took " else "No finish after ") <> fmtDuration taken <> "; the limit is " <> fmtDuration limit <> ".") | taken > limit ]
    ++ [ ("overdue", overdue d) | Just d <- [rules.expected], gap > d + grace ]
    ++ related "subtasks" [fromString (T.unpack (unTopic r.eid.evtTopic) <> "/" <> s) | s <- fromMaybe [] rules.subtasks] ix.scopedTo
    ++ related "reactions" (fromMaybe [] rules.reactions) ix.reactingTo
  where
    rules = r.start.x.rules
    taken = duration now r
    limit = fromIntegral rules.timeout
    next = r.followedAt <|> listToMaybe (reverse (takeWhile (> r.start.at) [s.start.at | s <- Map.findWithDefault [] r.eid.evtTopic ix.byTopic]))
    gap = diffUTCTime (fromMaybe now next) r.start.at
    overdue d = "The next run was expected within " <> fmtDuration d <> " (+" <> fmtDuration grace <> " grace)" <> case next of
      Nothing -> ", but none has started in " <> fmtDuration gap <> "."
      Just _ -> ", but it started " <> fmtDuration gap <> " later."
    -- Each filter must match the topic of a related run.
    related :: Text -> [Filter] -> Map UUID [Run] -> [(Text, Text)]
    related name fs m =
      [ (name, "None matching " <> T.intercalate ", " (map unFilter missing) <> ".") | diffUTCTime now r.start.at > limit
      , let topics = map (.eid.evtTopic) (Map.findWithDefault [] r.eid.correlationId m)
      , let missing = [f | f <- fs, not (any (match f) topics)], not (null missing) ]
    nonEmpty s = if null s then Nothing else Just (T.pack s)
    firstLine = \case
      Just (String t) | not (T.null t) -> Just (T.takeWhile (/= '\n') t)
      _ -> Nothing

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
