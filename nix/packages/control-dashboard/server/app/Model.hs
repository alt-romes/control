-- | What the runs seen on the broker say about the system.
module Model
  ( Run (..), Logged (..), State (..), Index (..)
  , apply, setConnected, topicOf, index, related, latest, problems, pendingTriggers, awaitedReactions, own, runsOf, matches, duration, fmtDuration, firstLine
  , Health (..), Tick (..), tick, trace
  ) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), Trigger (..))
import Data.Aeson (FromJSON, ToJSON (..), Value (..))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe, mapMaybe, maybeToList)
import Data.Ord (Down (..))
import Data.Set (Set)
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

-- | A line of the history file: what 'react' handed us, and what the user dismissed.
data Logged = Started EventId (Timed (EvtMsg Value)) | Finished UUID (Timed EvtDone) | Dismissed UUID
  deriving (Generic, ToJSON, FromJSON)

data State = State
  { runs :: Map UUID Run
  , byTopic :: Map Text [UUID]
    -- ^ Newest first
  , required :: [Text]
  , triggerable :: [Text]
    -- ^ Trigger topics something reacts to, for the user to send at will
  , connected :: Bool
  , awake :: UTCTime
    -- ^ Since when the server has been watching, without sleeping
  , slept :: [(UTCTime, UTCTime)]
    -- ^ When the computer slept, newest first
  , dismissed :: Set UUID
    -- ^ Runs whose problems and triggers the user wants no more of
  }

-- | How many runs of each topic to remember.
keep :: Int
keep = 200

-- | So a run expected every minute doesn't race its own schedule.
grace :: NominalDiffTime
grace = 60

apply :: Logged -> State -> State
apply (Dismissed i) st = st {dismissed = Set.insert i st.dismissed}
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

tick :: UTCTime -> State -> Run -> Tick
tick now st r = Tick status took
  where
    took = awakeFor now st r
    status
      | maybe False (not . (.e.success)) r.end || took > fromIntegral r.start.e.rules.timeout = Bad
      | isNothing r.end = Running
      | otherwise = Fine

-- | How long a run has been going, or went, leaving out when the computer
-- slept: it can't be blamed for that.
awakeFor :: UTCTime -> State -> Run -> NominalDiffTime
awakeFor now st r = duration now r - sum [max 0 (diffUTCTime (min b end) (max a r.start.at)) | (a, b) <- st.slept]
  where
    end = maybe now (.at) r.end

problems :: UTCTime -> State -> Index -> Run -> [Text]
problems now st ix r =
  [ "Failed: " <> firstLine (T.pack d.e.summary) | Just d <- [r.end], not d.e.success ]
  ++ [ verb <> " " <> fmtDuration took <> "; the limit is " <> fmtDuration limit <> "." | took > limit ]
  ++ [ "The next run was expected within " <> fmtDuration d <> ", but " <> maybe "hasn't started after " (const "started ") next <> fmtDuration gap <> "."
     | Just d <- [rules.expected], gap > d + grace, diffUTCTime now st.awake > d + grace ]
  ++ [ "No subtask " <> T.pack s <> "." | took > limit, s <- fromMaybe [] rules.subtasks
     , not (any (matches (topicOf r <> "/" <> T.pack s) . topicOf) children) ]
  ++ [ leaf (topicOf c) <> ": " <> p | c <- children, p <- problems now st ix c ]
  -- A reaction comes after the run, so it gets a moment to.
  ++ [ "No reaction on " <> f <> " since it finished " <> fmtDuration (diffUTCTime now d.at) <> " ago."
     | Just d <- [r.end], diffUTCTime now d.at > grace, f <- awaitedReactions ix r ]
  where
    rules = r.start.e.rules
    took = awakeFor now st r
    limit = fromIntegral rules.timeout
    verb = maybe "No finish after" (const "Took") r.end
    children = related (.children) ix r
    next = listToMaybe (reverse [at | i <- Map.findWithDefault [] (topicOf r) st.byTopic, Just s <- [Map.lookup i st.runs], let at = s.start.at, at > r.start.at])
    gap = diffUTCTime (fromMaybe now next) r.start.at
    leaf = last . T.splitOn "/"

-- | Whether a topic is judged on its own: triggers and the dashboard's own
-- announcements aren't, and subtasks are judged within their parent's runs.
own :: State -> Text -> Bool
own st t = not (any (`T.isPrefixOf` t) ["trigger/", "dashboard/"] || any (isJust . (.start.e.scope)) (runsOf st t))

-- | Newest first.
runsOf :: State -> Text -> [Run]
runsOf st t = mapMaybe (`Map.lookup` st.runs) (Map.findWithDefault [] t st.byTopic)

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
