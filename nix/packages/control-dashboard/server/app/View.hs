{-# LANGUAGE NoFieldSelectors #-}
-- | The dashboard as JSON for the game to draw: every topic as it stands,
-- and a topic's runs.
module View (Item (..), Summary (..), judged, summarise, system, topicView) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Timed (..), Trigger (..))
import Data.Aeson (Key, ToJSON (..), Value (..), object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Graph (dfs, graphFromEdges)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing, listToMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time (UTCTime, diffUTCTime)
import Data.Tree (Tree (..))
import GHC.Generics (Generic)
import Model
import Network.MQTT.Topic (unTopic)

-- | A topic as its latest run leaves it, unless that run was dismissed.
data Item = Item {topic :: Text, run :: Maybe Run, status :: Health, problems :: [Text], sends :: [(Int, Trigger)]}

-- | All a status line needs.
data Summary = Summary {connected :: Bool, status :: Health, bad :: Int, waiting :: Int}
  deriving (Generic, ToJSON)

-- | Every topic with a place of its own: machines, services and events.
judged :: UTCTime -> State -> [Item]
judged now st = map item (Set.toList (Set.fromList (filter listed (Map.keys st.byTopic ++ st.required) ++ fst (graph st))))
  where
    ix = index st
    listed t = any (`T.isPrefixOf` t) ["system/", "healthcheck/"]
    item t = case latest st t of
      Nothing
        | t `elem` st.required -> Item t Nothing Bad ["Required, but never seen."] []
        | otherwise -> Item t Nothing Unseen [] []
      Just r ->
        let quiet = Set.member r.eid.correlationId st.dismissed
            ps = if quiet then [] else problems now st ix r ++ ["Disk " <> tshow d <> "% full." | Just d <- [percent r "diskUsed"], d >= 95]
            sends = if quiet then [] else pendingTriggers ix r
            s | not (null ps) = Bad
              | not (null sends) = Waiting
              | isNothing r.end = Running
              | otherwise = Fine
         in Item t (Just r) s ps sends

-- | A percentage a machine reports about itself.
percent :: Run -> Key -> Maybe Int
percent r k = case r.start.e.content of
  Just (Object o) -> KM.lookup k o >>= \case
    String s | [(n, "")] <- reads (T.unpack (T.dropWhileEnd (== '%') s)) -> Just n
    Number n -> Just (round n)
    _ -> Nothing
  _ -> Nothing

summarise :: State -> [Item] -> Summary
summarise st is = Summary st.connected (minimum (Fine : [Waiting | waiting > 0] ++ [Bad | bad > 0])) bad waiting
  where
    bad = length [() | i <- is, i.status == Bad]
    waiting = length [() | i <- is, _ <- i.sends]

-- | Machines, services, events and the triggers the user may send. Events
-- come as trees, each once, under what its latest run reacted to, after any
-- trigger that led there.
system :: UTCTime -> State -> [Item] -> Value
system now st is = object
  [ "summary" .= summarise st is
  , "triggers" .= [object ["topic" .= t, "content" .= c, "last" .= fmap (ago now) (latest st t)] | (t, c) <- st.triggerable]
  , "items" .= ([item "machine" 0 Nothing Nothing i | i <- under "system/"] ++ [item "service" 0 Nothing Nothing i | i <- under "healthcheck/"] ++ events)
  ]
  where
    ix = index st
    under p = filter ((p `T.isPrefixOf`) . (.topic)) is
    item :: Text -> Int -> Maybe Text -> Maybe Text -> Item -> Value
    item kind depth parent via i = object
      [ "topic" .= i.topic
      , "kind" .= kind
      , "status" .= i.status
      , "problems" .= i.problems
      , "when" .= maybe "never seen" (ago now) i.run
      , "run" .= fmap (.eid.correlationId) i.run
      , "runs" .= [h | r <- reverse (take 30 (runsOf st i.topic)), let Tick h _ = tick now st r]
      , "gauges" .= object [k .= v | Just r <- [i.run], (k, Just v) <- [("load", percent r "loadPct"), ("memory", (100 -) <$> percent r "memAvailPct"), ("disk", percent r "diskUsed")]]
      , "sends" .= [sendJson r s | Just r <- [i.run], s <- i.sends]
      , "awaited" .= [f | Just r <- [i.run], not (Set.member r.eid.correlationId st.dismissed), f <- awaitedReactions ix r]
      , "dismiss" .= listToMaybe [r.eid.correlationId | Just r <- [i.run], not (null i.problems && null i.sends)]
      , "depth" .= depth
      , "parent" .= parent
      , "via" .= via
      ]
    (topics, links) = graph st
    items = Map.fromList [(i.topic, i) | i <- is]
    (graph', fromVertex, toVertex) = graphFromEdges [(k, k, [b | (a, b, _) <- links, a == k]) | k <- topics]
    events = concatMap (tree 0 Nothing) (dfs graph' (mapMaybe toVertex (filter (`notElem` [b | (_, b, _) <- links]) topics ++ topics)))
    tree depth parent (Node n kids) =
      let (k, _, _) = fromVertex n
          via = listToMaybe [l | (a, b, Just l) <- links, Just a == parent, b == k]
       in item "event" depth parent via (items Map.! k) : concatMap (tree (depth + 1) (Just k)) kids

-- | A topic's last 20 runs, newest first, each with the chain it's part of.
-- Given the end of its log, if there is one.
topicView :: UTCTime -> State -> Maybe Text -> Text -> Value
topicView now st logTail t = object ["topic" .= t, "log" .= logTail, "runs" .= map run (take 20 (runsOf st t))]
  where
    ix = index st
    health r = let Tick h _ = tick now st r in h
    run r =
      let quiet = Set.member r.eid.correlationId st.dismissed
          ps = if quiet then [] else problems now st ix r
          sends = if quiet then [] else pendingTriggers ix r
       in object
            [ "run" .= r.eid.correlationId
            , "label" .= r.start.e.label
            , "status" .= if quiet then Fine else if null ps then health r else Bad
            , "when" .= ago now r
            , "took" .= fmap (const (fmtDuration (duration now r))) r.end
            , "problems" .= ps
            , "sends" .= map (sendJson r) sends
            , "summary" .= [firstLine (T.pack d.e.summary) | Just d <- [r.end], d.e.success, not (null d.e.summary)]
            , "content" .= fmap said r.start.e.content
            , "result" .= fmap said (r.end >>= (.e.result))
            , "chain" .= [object ["depth" .= d, "topic" .= topicOf x, "status" .= health x, "when" .= ago now x] | let c = trace st ix r, length c > 1, (d, x) <- c]
            ]
    -- Text as it reads, anything else as JSON, laid out.
    said = \case
      String s -> s
      v -> T.decodeUtf8 (BL.toStrict (encodePretty v))

sendJson :: Run -> (Int, Trigger) -> Value
sendJson r (n, trig) = object ["run" .= r.eid.correlationId, "index" .= n, "label" .= trig.triggerLabel, "to" .= unTopic trig.triggerTopic]

runsOf :: State -> Text -> [Run]
runsOf st t = mapMaybe (`Map.lookup` st.runs) (Map.findWithDefault [] t st.byTopic)

ago :: UTCTime -> Run -> Text
ago now r
  | isNothing r.end = "running for " <> fmtDuration (diffUTCTime now r.start.at)
  | otherwise = fmtDuration (diffUTCTime now r.start.at) <> " ago"

tshow :: Show a => a -> Text
tshow = T.pack . show
