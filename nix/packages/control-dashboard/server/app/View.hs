{-# LANGUAGE NoFieldSelectors #-}
-- | What the page is sent: the system as a net of topics, the runs over a
-- stretch of time, and one topic's runs in full.
module View (Item (..), Summary (..), judged, summarise, system, runsSince, topic, nodeOf) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Timed (..), Trigger (..))
import Data.Aeson (Key, ToJSON (..), Value (..), object, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Ord (Down (..))
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, diffUTCTime)
import GHC.Generics (Generic)
import Model
import Network.MQTT.Topic (unTopic)

-- | A topic as its latest run leaves it, unless that run was dismissed, with
-- the unsent triggers of every run of it not dismissed.
data Item = Item {topic :: Text, run :: Maybe Run, status :: Health, problems :: [Text], sends :: [(Run, (Int, Trigger))]}

-- | All a status line needs.
data Summary = Summary {connected :: Bool, status :: Health, bad :: Int, waiting :: Int}
  deriving (Generic, ToJSON)

-- | Every topic judged on its own: machines, services and events.
judged :: UTCTime -> State -> [Item]
judged now st = map item (filter (own st) (Set.toList (Set.fromList (Map.keys st.byTopic ++ st.required))))
  where
    ix = index st
    item t = case latest st t of
      Nothing
        | t `elem` st.required -> Item t Nothing Bad ["Required, but never seen."] []
        | otherwise -> Item t Nothing Unseen [] []
      Just r ->
        let ps = if quiet st r then [] else problems now st ix r ++ ["Disk " <> tshow d <> "% full." | Just d <- [percent r "diskUsed"], d >= 95]
            sends = [(x, s) | x <- runsOf st t, not (quiet st x), s <- pendingTriggers ix x]
            s | not (null ps) = Bad
              | not (null sends) = Waiting
              | isNothing r.end = Running
              | otherwise = Fine
         in Item t (Just r) s ps sends

summarise :: State -> [Item] -> Summary
summarise st is = Summary st.connected (minimum (Fine : [Waiting | waiting > 0] ++ [Bad | bad > 0])) bad waiting
  where
    bad = length [() | i <- is, i.status == Bad]
    waiting = length [() | i <- is, _ <- i.sends]

-- | The node a topic is drawn as: what the dashboard announces about every
-- topic is one node per kind of announcement.
nodeOf :: Text -> Text
nodeOf t = case T.splitOn "/" t of
  "dashboard" : k : _ : _ -> "dashboard/" <> k
  _ -> t

-- | Every topic but triggers as a node, with edges for what was part of what
-- and what reacted to what. A trigger is an edge from what announced it, or
-- from the user, to what reacted to it. A trigger nothing reacted to yet, and
-- a reaction a run expects, lead to a ghost of what should happen.
system :: UTCTime -> State -> [Item] -> Value
system now st is = object ["summary" .= summarise st is, "now" .= now, "actions" .= map action st.triggerable, "requests" .= requests now st ix, "nodes" .= (map node (Map.toList members) ++ others), "edges" .= edges]
  where
    ix = index st
    items = Map.fromList [(i.topic, i) | i <- is]
    members = Map.fromListWith (++) [(nodeOf t, [t]) | t <- Map.keys st.byTopic ++ st.required, not (isTrigger t)]
    runs = Map.elems st.runs
    causes r = [unTopic p.evtTopic | p <- fromMaybe [] r.start.e.reactTo]
    reactors t = nub [nodeOf (topicOf r) | r <- runs, t `elem` causes r]
    announcers t = case nub [nodeOf c | r <- runsOf st t, c <- causes r] of [] -> ["@you"]; as -> as
    towards t = case reactors t of [] -> ["?" <> t]; bs -> bs
    expecting f = case filter (matches f) (Map.keys members) of [] -> ["?" <> f]; ts -> ts
    leaf = T.drop (T.length "trigger/")
    seen r = (1 :: Int, Just r.start.at, False)
    links = Map.fromListWith (\(n, a, p) (m, b, q) -> (n + m, max a b, p || q)) $
      [ ((nodeOf (unTopic p.evtTopic), nodeOf (topicOf r), "part" :: Text, ""), seen r) | r <- runs, Just p <- [r.start.e.scope] ]
      ++ [ ((nodeOf c, nodeOf (topicOf r), "reaction", ""), seen r) | r <- runs, not (isTrigger (topicOf r)), c <- causes r, not (isTrigger c) ]
      ++ [ ((a, nodeOf (topicOf r), "trigger", leaf c), seen r) | r <- runs, c <- causes r, isTrigger c, a <- announcers c ]
      ++ [ ((a, "?" <> t, "trigger", leaf t), seen r) | t <- Map.keys st.byTopic, isTrigger t, null (reactors t), Just r <- [latest st t], a <- announcers t ]
      ++ [ (("@you", b, "trigger", leaf t), (0, Nothing, False)) | t <- st.triggerable, b <- towards t ]
      ++ [ ((i.topic, b, "trigger", leaf t), (0, Nothing, True)) | i <- is, (_, (_, s)) <- i.sends, let t = unTopic s.triggerTopic, b <- towards t ]
      ++ [ ((i.topic, b, "awaited", f), (0, Nothing, False)) | i <- is, Just r <- [i.run], not (quiet st r), f <- awaitedReactions ix r, b <- expecting f ]
    known n = Map.member n members || n `elem` map fst extra
    edges =
      [ object ["source" .= a, "target" .= b, "kind" .= k, "label" .= l, "count" .= n, "last" .= at, "pending" .= p]
      | ((a, b, k, l), (n, at, p)) <- Map.toList links, a /= b, known a, known b ]
    extra = [(b, "ghost") | b <- nub [b | (_, b, _, _) <- Map.keys links], "?" `T.isPrefixOf` b] ++ [("@you", "you") | any (\(a, _, _, _) -> a == "@you") (Map.keys links)]
    others = [object ["id" .= n, "kind" .= k, "topic" .= T.drop 1 n, "status" .= k] | (n, k :: Text) <- extra]
    node (n, ts) = object
      [ "id" .= n, "kind" .= T.takeWhile (/= '/') n, "topic" .= n, "status" .= status, "problems" .= ps
      , "sends" .= map (uncurry send) sends, "latest" .= fmap brief run, "rules" .= fmap (.start.e.rules) run
      , "ticks" .= [health now st r | r <- reverse (take 30 rs)], "gauges" .= foldMap gauges run, "required" .= (n `elem` st.required), "own" .= Map.member n items ]
      where
        rs = newest (concatMap (runsOf st) ts)
        run = listToMaybe rs
        (status, ps, sends) = case Map.lookup n items of
          Just i -> (i.status, i.problems, i.sends)
          Nothing -> case run of
            Just r | not (quiet st r) -> (health now st r, problems now st ix r, [])
                   | otherwise -> (Fine, [], [])
            Nothing -> (Unseen, [], [])
    action t = object ["topic" .= t, "last" .= fmap (outcome now st ix) (listToMaybe (runsOf st t))]

-- | The runs that went on since then, each with the run it was part of and
-- those it reacted to.
runsSince :: UTCTime -> State -> UTCTime -> Value
runsSince now st from = toJSON
  [ object
      [ "id" .= r.eid.correlationId, "node" .= nodeOf (topicOf r), "topic" .= topicOf r, "label" .= r.start.e.label
      , "start" .= r.start.at, "end" .= fmap (.at) r.end, "health" .= health now st r
      , "parent" .= fmap (.correlationId) r.start.e.scope, "reactTo" .= map (.correlationId) (fromMaybe [] r.start.e.reactTo) ]
  | r <- Map.elems st.runs, maybe True ((> from) . (.at)) r.end ]

-- | A node's last 20 runs in full, newest first, each with the chain of runs
-- it is part of; the end of its log, if there is one; and a machine's gauges
-- over every run remembered.
topic :: UTCTime -> State -> Maybe Text -> Text -> Value
topic now st logTail n = object
  [ "topic" .= n, "log" .= logTail, "runs" .= map full (take 20 rs)
  , "gauges" .= [object ["at" .= r.start.at, "gauges" .= gauges r] | "system/" `T.isPrefixOf` n, r <- rs] ]
  where
    ix = index st
    rs = newest (concat [runsOf st t | t <- Map.keys st.byTopic, nodeOf t == n])
    full r = object
      [ "id" .= r.eid.correlationId, "topic" .= topicOf r, "label" .= r.start.e.label, "start" .= r.start.at, "end" .= fmap (.at) r.end
      , "health" .= health now st r, "dismissed" .= quiet st r, "problems" .= problems now st ix r
      , "sends" .= if quiet st r then [] else map (send r) (pendingTriggers ix r)
      , "success" .= fmap (.e.success) r.end, "summary" .= fmap (.e.summary) r.end
      , "content" .= r.start.e.content, "result" .= (r.end >>= (.e.result)), "rules" .= r.start.e.rules
      , "chain" .= [ object ["depth" .= d, "id" .= x.eid.correlationId, "topic" .= topicOf x, "node" .= nodeOf (topicOf x), "start" .= x.start.at, "end" .= fmap (.at) x.end, "health" .= health now st x]
                   | let chain = trace st ix r, length chain > 1, (d, x) <- chain ] ]

brief :: Run -> Value
brief r = object ["id" .= r.eid.correlationId, "label" .= r.start.e.label, "start" .= r.start.at, "end" .= fmap (.at) r.end]

send :: Run -> (Int, Trigger) -> Value
send r (n, t) = object (sendFields r (n, t))

sendFields :: Run -> (Int, Trigger) -> [(Key, Value)]
sendFields r (n, t) =
  [ "run" .= r.eid.correlationId, "index" .= n, "label" .= t.triggerLabel, "topic" .= unTopic t.triggerTopic, "data" .= t.triggerData
  , "from" .= nodeOf (topicOf r), "asked" .= fmap (.at) r.end, "summary" .= fmap (.e.summary) r.end ]

-- | What runs asked the user to send, waiting ones first, newest first:
-- every unsent trigger of a run not dismissed, and those sent in the last day
-- with what came of them.
requests :: UTCTime -> State -> Index -> [Value]
requests now st ix = map snd $ sortOn fst
  [ (Down (isNothing sentAs, d.at), object (sendFields r (n, t) ++ ["sent" .= fmap (outcome now st ix) sentAs]))
  | r <- Map.elems st.runs, Just d <- [r.end], (n, t) <- zip [0 ..] (fromMaybe [] d.e.triggers)
  , let sentAs = listToMaybe [x | x <- related (.reactors) ix r, topicOf x == unTopic t.triggerTopic]
  , maybe (not (quiet st r)) (\x -> diffUTCTime now x.start.at < 86400) sentAs ]

-- | When a trigger was sent, and how what reacted to it went.
outcome :: UTCTime -> State -> Index -> Run -> Value
outcome now st ix x = object
  [ "at" .= x.start.at
  , "reactions" .= [object ["node" .= nodeOf (topicOf y), "health" .= health now st y] | y <- related (.reactors) ix x] ]

-- | What a machine reports about itself, in percent.
gauges :: Run -> Map Text Int
gauges r = Map.fromList [(k, v) | (k, Just v) <- [("load", percent r "loadPct"), ("memory", (100 -) <$> percent r "memAvailPct"), ("disk", percent r "diskUsed")]]

percent :: Run -> Key -> Maybe Int
percent r k = case r.start.e.content of
  Just (Object o) -> KM.lookup k o >>= \case
    String s | [(n, "")] <- reads (T.unpack (T.dropWhileEnd (== '%') s)) -> Just n
    Number n -> Just (round n)
    _ -> Nothing
  _ -> Nothing

health :: UTCTime -> State -> Run -> Health
health now st r = let Tick h _ = tick now st r in h

quiet :: State -> Run -> Bool
quiet st r = Set.member r.eid.correlationId st.dismissed

newest :: [Run] -> [Run]
newest = sortOn (Down . (.start.at))

isTrigger :: Text -> Bool
isTrigger = T.isPrefixOf "trigger/"

tshow :: Show a => a -> Text
tshow = T.pack . show
