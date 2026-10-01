{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields, LambdaCase #-}
-- | Runs of control-events as seen on the MQTT broker, and what's wrong with
-- them.
module Events
  ( State (..), Run (..), Trigger (..), newState, mqttLoop, publishTrigger
  , Index (..), index, latestRuns, topLevel
  , problems, duration, grace, prune
  , fmtDuration
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), simple, withMsg, (&), (.~))
import Control.Exception (SomeException, try)
import Control.Monad (forever, void)
import Data.Aeson (Value (..), decode, eitherDecodeStrict, encode)
import Data.List (sortOn, (\\))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust, fromMaybe, isJust, listToMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import GHC.Generics (Generic)
import Network.MQTT.Client
import Network.MQTT.Topic (mkTopic, unTopic)
import Network.URI (parseURI)
import Web.FormUrlEncoded (FromForm)

-- | A run of an event: how it started and, once finished, how it ended.
-- A trigger is a run that finishes as soon as it's sent.
data Run = Run
  { topic :: Text -- ^ without the @start@/@finished@ suffix
  , start :: Timed (EvtMsg Value)
  , end :: Maybe (Timed EvtDone)
  }

data State = State
  { runs :: TVar (Map UUID Run) -- ^ by correlation id
  , broker :: TVar (Maybe MQTTClient) -- ^ while connected
  , lost :: TVar (Map Text UTCTime) -- ^ connections (by service topic) that dropped without disconnecting
  , acked :: TVar (Set UUID) -- ^ critical failures acknowledged
  }

newState :: IO State
newState = State <$> newTVarIO Map.empty <*> newTVarIO Nothing <*> newTVarIO Map.empty <*> newTVarIO Set.empty

-- | Stay subscribed to the control-events topics, reconnecting if the broker
-- goes away. Messages are handled in order, so a run's start comes before its
-- finish: the publisher waits for the broker to have the start.
--
-- A persistent session keeps a fixed client id, and the broker queues messages
-- for up to a day while we're away. Otherwise the broker assigns a fresh id, so
-- other instances (e.g. dev runs) can't take over the persistent session.
mqttLoop :: Bool -> State -> IO ()
mqttLoop persistent st = forever $ do
  r <- try @SomeException $ do
    mc <- connectURI mqttConfig {_msgCB = OrderedCallback onMsg, _protocol = Protocol50, _cleanSession = not persistent, _connProps = props} uri
    void $ subscribe mc [(f, subOptions {_subQoS = QoS2}) | f <- ["script/#", "server/#", "healthcheck/#", "trigger/#"]] []
    atomically $ writeTVar st.broker (Just mc)
    waitForClient mc
  atomically $ writeTVar st.broker Nothing
  putStrLn ("mqtt: " <> either show (const "disconnected") r)
  threadDelay 5_000_000
  where
    -- connectURI takes the client id from the fragment, ignoring '_connID'.
    uri = fromJust (parseURI ("mqtt://127.0.0.1:1883" <> if persistent then "#control-dashboard" else ""))
    props = [PropSessionExpiryInterval 86400 | persistent]
    onMsg _ tp body props = getCurrentTime >>= \now -> atomically $ do
      let t = unTopic tp
          (base, kind) = T.breakOnEnd "/" t
          evt = T.dropEnd 1 base
          cid = listToMaybe [u | PropCorrelationData c <- props, Just u <- [UUID.fromLazyASCIIBytes c]]
      modifyTVar' st.lost $ if kind == "last-will-testament"
        then Map.insert evt now
        else Map.filterWithKey (\svc _ -> not ((svc <> "/") `T.isPrefixOf` t))
      case (kind, cid) of
        ("start", Just u) | Just s <- decode body -> modifyTVar' st.runs (prune . Map.insert u (Run evt s Nothing))
        ("finished", Just u) | Just e <- decode body -> modifyTVar' st.runs (Map.adjust (\r -> r {end = Just e}) u)
        (_, Just u) | "trigger/" `T.isPrefixOf` t, Just s <- decode body ->
          modifyTVar' st.runs (prune . Map.insert u (Run t s (Just (Timed s.at (EvtDone "Sent" True Nothing)))))
        _ -> pure ()

-- | Bound memory: past 20000 runs, keep only the latest 500 top-level runs of
-- each topic, with their subtasks.
prune :: Map UUID Run -> Map UUID Run
prune m
  | Map.size m <= 20000 = m
  | otherwise = Map.restrictKeys m (Set.fromList (concatMap tree kept))
  where
    ix = index m
    kept = concatMap (map fst . take 500 . filter (topLevel ix . snd)) (Map.elems ix.byTopic)
    tree u = u : concatMap (tree . fst) (Map.findWithDefault [] u ix.subtasks)

-- | A trigger to publish on @trigger/<topic>@: a control-events message
-- carrying the label and JSON content.
data Trigger = Trigger {topic :: Text, label :: Text, content :: Text}
  deriving (Eq, Ord, Generic)

instance FromForm Trigger

publishTrigger :: State -> Trigger -> IO (Either Text ())
publishTrigger st t = do
  mc <- readTVarIO st.broker
  case (mkTopic ("trigger/" <> T.strip t.topic), content, mc) of
    (Nothing, _, _) -> pure (Left "That isn't a valid MQTT topic (no wildcards or empty levels).")
    (_, Left err, _) -> pure (Left ("The content isn't valid JSON: " <> T.pack err))
    (_, _, Nothing) -> pure (Left "Not connected to the broker.")
    (Just tp, Right v, Just c) -> do
      u <- UUID.nextRandom
      now <- getCurrentTime
      let msg = simple (T.unpack t.label) & withMsg .~ v
      Right <$> publishq c tp (encode (Timed now msg)) False QoS2 [PropCorrelationData (UUID.toLazyASCIIBytes u)]
  where
    content :: Either String (Maybe Value)
    content
      | T.null (T.strip t.content) = Right Nothing
      | otherwise = Just <$> eitherDecodeStrict (encodeUtf8 t.content)

--------------------------------------------------------------------------------

-- | Runs arranged for lookups, each list newest first.
data Index = Index
  { runs :: Map UUID Run
  , byTopic :: Map Text [(UUID, Run)]
  , subtasks :: Map UUID [(UUID, Run)] -- ^ by the parent's correlation id
  }

index :: Map UUID Run -> Index
index runs = Index
  { runs
  , byTopic = Map.fromListWith (flip (++)) [(r.topic, [ur]) | ur@(_, r) <- ordered]
  , subtasks = Map.fromListWith (flip (++)) [(p.correlationId, [ur]) | ur@(_, r) <- ordered, Just p <- [r.start.x.scope]]
  }
  where
    ordered = sortOn (Down . (.start.at) . snd) (Map.toList runs)

-- | The latest run of each top-level event, newest first.
latestRuns :: Index -> [(UUID, Run)]
latestRuns ix = sortOn (Down . (.start.at) . snd) [ur | rs <- Map.elems ix.byTopic, ur <- take 1 (filter (topLevel ix . snd) rs)]

-- | A run is top-level unless it's a subtask: scoped to a run we know, under
-- its topic. So runs a trigger caused, or scoped to a run from before the
-- dashboard started, are top-level too.
topLevel :: Index -> Run -> Bool
topLevel ix r = case r.start.x.scope >>= \p -> Map.lookup p.correlationId ix.runs of
  Just parent -> not ((parent.topic <> "/") `T.isPrefixOf` r.topic)
  Nothing -> True

-- | How long a run took, or has been running for.
duration :: UTCTime -> Run -> NominalDiffTime
duration now r = diffUTCTime (maybe now (.at) r.end) r.start.at

-- | Everything wrong with a run at the given time, each with an explanation:
-- failure and violated rules. The run is overdue if the next run on its topic,
-- which may not have started yet, started too late. Its subtasks are only
-- checked once it's over.
problems :: UTCTime -> Index -> (UUID, Run) -> [(Text, Text)]
problems now ix (u, r) =
  [ ("failed", "Finished unsuccessfully" <> foldMap (": " <>) (nonEmpty e.x.summary) <> foldMap (" — " <>) (firstLine e.x.result))
    | Just e <- [r.end], not e.x.success ]
    ++ [ ("timed out", (if isJust r.end then "Took " else "No finish after ") <> fmtDuration taken <> "; the limit is " <> fmtDuration limit <> ".") | taken > limit ]
    ++ [ ("overdue", overdue d) | Just d <- [r.start.x.rules.expected], gap > d + grace ]
    ++ [ ("subtasks", "Missing " <> T.intercalate ", " missing <> ".") | Just ts <- [r.start.x.rules.subtasks], isJust r.end || taken > limit
       , let missing = map T.pack ts \\ subtopics, not (null missing) ]
  where
    taken = duration now r
    limit = fromIntegral r.start.x.rules.timeout
    next = listToMaybe (reverse (takeWhile (> r.start.at) [s.start.at | (_, s) <- Map.findWithDefault [] r.topic ix.byTopic]))
    gap = diffUTCTime (fromMaybe now next) r.start.at
    overdue d = "The next run was expected within " <> fmtDuration d <> " (+" <> fmtDuration grace <> " grace)" <> case next of
      Nothing -> ", but none has started in " <> fmtDuration gap <> "."
      Just _ -> ", but it started " <> fmtDuration gap <> " later."
    subtopics = [t | (_, s) <- Map.findWithDefault [] u ix.subtasks, Just t <- [T.stripPrefix (r.topic <> "/") s.topic]]
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
