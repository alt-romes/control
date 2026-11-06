-- | What the runs seen on the broker say about the system.
module Model
  ( Run (..), Logged (..), State (..), Index (..), Link (..), Ghost (..)
  , apply, setConnected, topicOf, index, latest, problems, pendingTriggers, awaitedReactions, graph, places, matches, duration, fmtDuration, firstLine
  , Health (..), Tick (..), tick, recent, trace
  ) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), Trigger (..))
import Data.Aeson (FromJSON, ToJSON (..), Value (..), object, (.=))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe, maybeToList)
import Data.Ord (Down (..))
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)
import Network.MQTT.Topic (unFilter, unTopic)

data Run = Run
  { eid :: EventId
  , start :: Timed (EvtMsg Value)
  , end :: Maybe (Timed EvtDone)
  }

-- | A line of the history file: what 'react' handed us.
data Logged = Started EventId (Timed (EvtMsg Value)) | Finished UUID (Timed EvtDone)
  deriving (Generic, ToJSON, FromJSON)

data State = State
  { runs :: Map UUID Run
  , byTopic :: Map Text [UUID]
    -- ^ Newest first
  , required :: [Text]
  , connected :: Bool
  }

-- | How many runs of each topic to remember.
keep :: Int
keep = 200

-- | So a run expected every minute doesn't race its own schedule.
grace :: NominalDiffTime
grace = 60

apply :: Logged -> State -> State
apply (Finished i d) st = st {runs = Map.adjust (\r -> r {end = Just d}) i st.runs}
apply (Started e s) st
  | Map.member e.correlationId st.runs || "test/" `T.isPrefixOf` t = st
  | otherwise = st {runs = foldr Map.delete runs' old, byTopic = Map.insert t kept st.byTopic}
  where
    t = unTopic e.evtTopic
    runs' = Map.insert e.correlationId (Run e s Nothing) st.runs
    (kept, old) = splitAt keep (sortOn (Down . startAt) (e.correlationId : Map.findWithDefault [] t st.byTopic))
    startAt i = (runs' Map.! i).start.at

setConnected :: Bool -> State -> State
setConnected b st = st {connected = b}

topicOf :: Run -> Text
topicOf r = unTopic r.eid.evtTopic

latest :: State -> Text -> Maybe Run
latest st t = Map.lookup t st.byTopic >>= listToMaybe >>= (`Map.lookup` st.runs)

-- | Who each run's subtasks and reactions are, built once per frame.
data Index = Index
  { children :: Map UUID [Run]
  , reactors :: Map UUID [Run]
  }

index :: State -> Index
index st = Index (by (maybeToList . (.scope))) (by (fromMaybe [] . (.reactTo)))
  where by k = Map.fromListWith (++) [(p.correlationId, [r]) | r <- Map.elems st.runs, p <- k r.start.e]

related :: (Index -> Map UUID [Run]) -> Index -> Run -> [Run]
related f ix r = Map.findWithDefault [] r.eid.correlationId (f ix)

-- | The chain of runs this one is part of, from the run that began it, with
-- how deep each is: every run is followed by its subtasks and reactions.
trace :: State -> Index -> Run -> [(Int, Run)]
trace st ix r = take 60 (go 0 (root (20 :: Int) r))
  where
    parent x = listToMaybe [p | e <- maybeToList x.start.e.scope ++ fromMaybe [] x.start.e.reactTo, Just p <- [Map.lookup e.correlationId st.runs]]
    root n x = case parent x of
      Just p | n > 0 -> root (n - 1) p
      _ -> x
    go d x = (d, x) : if d >= 10 then [] else concatMap (go (d + 1)) (sortOn (.start.at) (related (.children) ix x ++ related (.reactors) ix x))

-- | Reactions a run expects that haven't come, besides those a pending
-- trigger would cause: that's the user's to send.
awaitedReactions :: Index -> Run -> [Text]
awaitedReactions ix r =
  [ f | f <- map unFilter (fromMaybe [] r.start.e.rules.reactions)
  , not (any (matches f . topicOf) (related (.reactors) ix r))
  , not (any (matches f . unTopic . (.triggerTopic) . snd) (pendingTriggers ix r)) ]

-- | Announced triggers nobody has sent yet: each is sent once.
pendingTriggers :: Index -> Run -> [(Int, Trigger)]
pendingTriggers ix r =
  [ (i, t) | (i, t) <- zip [0 ..] (foldMap (fromMaybe [] . (.e.triggers)) r.end)
  , unTopic t.triggerTopic `notElem` map topicOf (related (.reactors) ix r) ]

duration :: UTCTime -> Run -> NominalDiffTime
duration now r = diffUTCTime (maybe now (.at) r.end) r.start.at

-- | Worst first.
data Health = Bad | Waiting | Running | Fine | Unseen
  deriving (Eq, Ord, Show)

instance ToJSON Health where
  toJSON = String . \case Bad -> "bad"; Waiting -> "waiting"; Running -> "running"; Fine -> "fine"; Unseen -> "unseen"

-- | A run at a glance: whether it went wrong by itself, and how long it took.
data Tick = Tick Health NominalDiffTime

instance ToJSON Tick where
  toJSON (Tick s took) = object ["status" .= s, "took" .= took]

tick :: UTCTime -> Run -> Tick
tick now r = Tick status took
  where
    took = duration now r
    status
      | maybe False (not . (.e.success)) r.end || took > fromIntegral r.start.e.rules.timeout = Bad
      | isNothing r.end = Running
      | otherwise = Fine

-- | A topic's last runs, oldest first.
recent :: UTCTime -> State -> Text -> [Tick]
recent now st t = reverse [tick now r | i <- take 30 (Map.findWithDefault [] t st.byTopic), Just r <- [Map.lookup i st.runs]]

problems :: UTCTime -> State -> Index -> Run -> [Text]
problems now st ix r =
  [ "Failed: " <> firstLine (T.pack d.e.summary) | Just d <- [r.end], not d.e.success ]
  ++ [ verb <> " " <> fmtDuration took <> "; the limit is " <> fmtDuration limit <> "." | took > limit ]
  ++ [ "The next run was expected within " <> fmtDuration d <> ", but " <> maybe "hasn't started after " (const "started ") next <> fmtDuration gap <> "."
     | Just d <- [rules.expected], gap > d + grace ]
  ++ [ "No subtask " <> T.pack s <> "." | took > limit, s <- fromMaybe [] rules.subtasks
     , not (any (matches (topicOf r <> "/" <> T.pack s) . topicOf) children) ]
  ++ [ leaf (topicOf c) <> ": " <> p | c <- children, p <- problems now st ix c ]
  -- A reaction comes after the run, so it gets a moment to.
  ++ [ "No reaction on " <> f <> " since it finished " <> fmtDuration (diffUTCTime now d.at) <> " ago."
     | Just d <- [r.end], diffUTCTime now d.at > grace, f <- awaitedReactions ix r ]
  where
    rules = r.start.e.rules
    took = duration now r
    limit = fromIntegral rules.timeout
    verb = maybe "No finish after" (const "Took") r.end
    children = related (.children) ix r
    next = listToMaybe (reverse [at | i <- Map.findWithDefault [] (topicOf r) st.byTopic, Just s <- [Map.lookup i st.runs], let at = s.start.at, at > r.start.at])
    gap = diffUTCTime (fromMaybe now next) r.start.at
    leaf = last . T.splitOn "/"

data Link = Link {from :: Text, to :: Text, label :: Maybe Text, send :: Maybe (UUID, Int)}

instance ToJSON Link where
  toJSON l = object ["from" .= l.from, "to" .= l.to, "label" .= l.label, "trigger" .= fmap (\(r, i) -> object ["run" .= r, "index" .= i]) l.send]

-- | An event that hasn't happened yet: the reaction to a pending trigger,
-- or one a run's rules expect.
data Ghost = Ghost {key :: Text, title :: Text, announcer :: Text}
  deriving (Generic, ToJSON)

-- | Topics worth a node and the links between them. Machines and services
-- are listed apart, subtasks live inside their parent's runs, and a trigger
-- is a labelled link from its announcer to whatever reacted.
graph :: State -> Index -> ([Text], [Ghost], [Link])
graph st ix = (nodes, ghosts ++ awaitedGhosts, plain ++ viaTriggers ++ pending ++ awaited)
  where
    edges kind = Set.toList (Set.fromList [(unTopic p.evtTopic, topicOf r) | r <- Map.elems st.runs, p <- kind r.start.e])
    scoped = Set.fromList (map snd (edges (maybeToList . (.scope))))
    reactions = edges (fromMaybe [] . (.reactTo))
    hidden t = any (`T.isPrefixOf` t) ["system/", "healthcheck/", "trigger/", "dashboard/"] || Set.member t scoped
    nodes = filter (not . hidden) (Set.toList (Set.fromList (Map.keys st.byTopic ++ st.required ++ concat [[a, b] | (a, b) <- reactions])))
    plain = [Link a b Nothing Nothing | (a, b) <- reactions, a /= b, not (hidden a), not (hidden b)]
    viaTriggers =
      [ Link a b ((\r -> T.pack r.start.e.label) <$> latest st t) Nothing
      | (t, b) <- reactions, "trigger/" `T.isPrefixOf` t, not (hidden b), (a, t') <- reactions, t' == t, not (hidden a) ]
    announced = [(t, r, i, trig) | t <- nodes, Just r <- [latest st t], (i, trig) <- pendingTriggers ix r]
    pending = [Link t (ghostKey t trig) (Just (T.pack trig.triggerLabel)) (Just (r.eid.correlationId, i)) | (t, r, i, trig) <- announced]
    ghosts = [Ghost (ghostKey t trig) (relative t (expected trig)) t | (t, _, _, trig) <- announced]
    ghostKey t trig = t <> "|" <> unTopic trig.triggerTopic
    awaitedFrom = [(t, f) | t <- nodes, Just r <- [latest st t], f <- awaitedReactions ix r]
    awaited = [Link t (t <> "|" <> f) Nothing Nothing | (t, f) <- awaitedFrom]
    awaitedGhosts = [Ghost (t <> "|" <> f) (relative t f) t | (t, f) <- awaitedFrom]
    -- Named from where its run is, as a sibling is: "checking", not "script/finances/revolut-import/checking".
    relative t f = let (a, b) = (T.splitOn "/" t, T.splitOn "/" f) in T.intercalate "/" (drop (length (takeWhile id (zipWith (==) (init a) b))) b)
    expected trig = let tt = unTopic trig.triggerTopic in maybe tt snd (listToMaybe [l | l <- reactions, fst l == tt, not (hidden (snd l))])

-- | Where each node goes, as a column and a row: a column per step down
-- the longest chain of links to it, and a row per chain. A node's first
-- link further right stays on its row, and the nodes hanging under it take
-- the rows right below. Nodes are visited in the order given, those nothing
-- links to first, and a link back up a chain doesn't count.
places :: [Text] -> [(Text, Text)] -> [(Text, Text)] -> Map Text (Int, Int)
places keys links under = snd (foldl visit (0, Map.empty) order)
  where
    order = filter (`notElem` map snd links) keys ++ keys
    forward = snd (foldl (\acc k -> walk [] k acc) (Set.empty, []) order)
    walk path k (seen, es)
      | Set.member k seen = (seen, es)
      | otherwise = foldl step (Set.insert k seen, es) [b | (a, b) <- links, a == k]
      where
        step acc b
          | b `elem` k : path = acc
          | otherwise = (\(s, e) -> (s, (k, b) : e)) (walk (k : path) b acc)
    col :: Text -> Int
    col k = maximum (0 : [1 + col a | (a, b) <- forward, b == k])
    visit acc@(next, m) k
      | Map.member k m = acc
      | otherwise = place k next (next + 1, m)
    place k row (next, m) = go True (foldl below (next, Map.insert k (col k, row) m) [c | (p, c) <- under, p == k]) [b | (a, b) <- links, a == k]
      where
        below (n, m') c = (n + 1, Map.insert c (col k, n) m')
        go _ acc [] = acc
        go first acc@(n, m') (t : ts)
          | Map.member t m' = go first acc ts
          | first, col t > col k = go False (place t row acc) ts
          | otherwise = go False (place t n (n + 1, m')) ts

-- | MQTT topic filter matching, with @+@ and @#@.
matches :: Text -> Text -> Bool
matches f t = go (T.splitOn "/" f) (T.splitOn "/" t)
  where
    go ["#"] _ = True
    go [] [] = True
    go ("+" : fs) (_ : ts) = go fs ts
    go (a : fs) (b : ts) = a == b && go fs ts
    go _ _ = False

firstLine :: Text -> Text
firstLine = fromMaybe "" . listToMaybe . filter (not . T.null) . map T.strip . T.lines

fmtDuration :: NominalDiffTime -> Text
fmtDuration d
  | ms < 1000 = tshow ms <> "ms"
  | s < 10 = tshow (fromIntegral (ms `div` 100) / 10 :: Double) <> "s"
  | s < 60 = tshow s <> "s"
  | s < 3600 = tshow (s `div` 60) <> "m" <> unit (s `mod` 60) "s"
  | s < 86400 = tshow (s `div` 3600) <> "h" <> unit (s `mod` 3600 `div` 60) "m"
  | otherwise = tshow (s `div` 86400) <> "d" <> unit (s `mod` 86400 `div` 3600) "h"
  where
    ms = max 0 (round (d * 1000)) :: Integer
    s = ms `div` 1000
    unit n u = if n == 0 then "" else " " <> tshow n <> u
    tshow :: Show a => a -> Text
    tshow = T.pack . show
