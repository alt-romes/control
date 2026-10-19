{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
-- | The home page: what needs you, what's broken, what's waiting, what's next,
-- and everything else, in that order.
module Home (homeJson, actions, broken, waiting, upcoming, healthy, streak) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), Trigger (..))
import Data.Aeson (Value, object, (.=))
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing, listToMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, addUTCTime, diffUTCTime)
import Events
import Network.MQTT.Topic (Topic, unTopic)
import Tree

homeJson :: Ctx -> Value
homeJson c = object
  [ "now" .= c.now, "connected" .= c.connected, "links" .= c.links, "alerting" .= c.alerting
  , "since" .= c.since, "sinceAgo" .= ago c c.since
  , "lastEvent" .= fmap (ago c) (maximumMay starts)
  , "quiet" .= (diffUTCTime c.now (maximum (c.since : starts)) > 600)
  , "actions" .= [ object ["topic" .= unTopic r.eid.evtTopic, "run" .= runJson c r, "index" .= i, "label" .= t.triggerLabel] | (r, i, t) <- actions c ]
  , "broken" .= map brokenJson (broken c)
  , "waiting" .= ([ object ["topic" .= unTopic r.eid.evtTopic, "run" .= runJson c r, "why" .= why r] | r <- waiting c ]
      ++ [ object ["topic" .= unTopic t, "why" .= ("Required; not seen yet since the dashboard started " <> ago c c.since <> "." :: Text)] | t <- missing c, t `notElem` map snd (flagged c) ])
  , "upcoming" .= [ object ["topic" .= unTopic r.eid.evtTopic, "label" .= r.start.e.label, "due" .= d, "in" .= fmtDuration (diffUTCTime d c.now)] | (d, r) <- upcoming c ]
  , "healthy" .= [ object ["service" .= s, "items" .= map okJson rs] | (s, rs) <- healthy c ]
  ]
  where
    starts = [r.start.at | r <- Map.elems c.ix.runs]
    brokenJson t = case Map.findWithDefault [] t c.ix.byTopic of
      [] -> object ["topic" .= unTopic t, "severity" .= Crisis, "problems" .= [object ["name" .= ("never seen" :: Text), "why" .= ("Required, but no run seen in the " <> T.dropEnd 4 (ago c c.since) <> " since the dashboard started." :: Text)]], "runs" .= ([] :: [Value])]
      rs@(r : _) -> let (bad, ok) = streak c rs in object
        [ "topic" .= unTopic t, "severity" .= severityOf c r, "id" .= r.eid.correlationId
        , "problems" .= [object ["name" .= p, "why" .= w] | (p, w) <- problemsOf c r]
        , "streak" .= length bad, "since" .= fmap (ago c . (.start.at)) (lastMay bad), "lastOk" .= fmap (ago c . (.start.at)) ok
        , "spark" .= spark c rs, "runs" .= map (runJson c) (take 10 rs)
        ]
    why r
      | isAcked c r = "Acknowledged " <> foldMap (ago c) (Map.lookup r.eid.correlationId c.acked) <> "; flagged again if the next run has problems too."
      | otherwise = "Running for " <> fmtDuration (duration c.now r) <> " of its " <> fmtDuration (fromIntegral r.start.e.rules.timeout) <> " limit."
    okJson r = object
      [ "topic" .= unTopic r.eid.evtTopic, "title" .= T.intercalate "/" (drop 1 (pathOf r.eid.evtTopic)), "label" .= r.start.e.label
      , "ago" .= ago c r.start.at, "every" .= fmap fmtDuration r.start.e.rules.expected, "summary" .= foldMap (.e.summary) r.end, "kv" .= kv r
      , "spark" .= spark c (Map.findWithDefault [] r.eid.evtTopic c.ix.byTopic)
      ]

-- | Decisions only you can make: triggers the latest run of a topic offers.
actions :: Ctx -> [(Run, Int, Trigger)]
actions c = [(r, i, t) | r <- latestRuns c.ix, (i, t) <- pendingTriggers c.ix r]

-- | Flagged topics, but not those only awaiting a trigger, which are 'actions'.
-- Crises first.
broken :: Ctx -> [Topic]
broken c = sortOn (Down . maybe Crisis (severityOf c) . latest c) [t | (_, t) <- flagged c, maybe True (any ((/= "awaiting trigger") . fst) . problemsOf c) (latest c t)]

-- | Acknowledged problems and runs that have been going a while.
waiting :: Ctx -> [Run]
waiting c = [r | r <- latestRuns c.ix, if severityOf c r > Healthy then isAcked c r else running r]
  where running r = isNothing r.end && not (timedOut c.now r) && duration c.now r > 5

-- | When each healthy scheduled job (at most hourly) should next start.
upcoming :: Ctx -> [(UTCTime, Run)]
upcoming c = sortOn fst [(addUTCTime d r.start.at, r) | r <- latestRuns c.ix, Just d <- [r.start.e.rules.expected], d >= 3600, severityOf c r == Healthy]

-- | Healthy topics by service.
healthy :: Ctx -> [(Text, [Run])]
healthy c = Map.toList (Map.fromListWith (flip (++)) [(s, [r]) | r <- latestRuns c.ix, severityOf c r == Healthy, not ("trigger/" `T.isPrefixOf` unTopic r.eid.evtTopic), s : _ <- [pathOf r.eid.evtTopic]])

-- | The latest runs with problems, and the last run without.
streak :: Ctx -> [Run] -> ([Run], Maybe Run)
streak c rs = let (bad, rest) = span ((> Healthy) . severityOf c) rs in (bad, listToMaybe rest)

maximumMay :: Ord a => [a] -> Maybe a
maximumMay [] = Nothing
maximumMay xs = Just (maximum xs)

lastMay :: [a] -> Maybe a
lastMay = listToMaybe . reverse
