-- | What the runs seen on the broker say about the system.
module Model
  ( Run (..), Logged (..), State (..), Index (..), Link (..), Ghost (..)
  , apply, loggedAt, setConnected, topicOf, index, latest, problems, pendingTriggers, awaitedReactions, graph, matches, duration, fmtDuration, firstLine
  , Tick (..), tick, recent, trace
  , Todo (..), Change (Change), Horizon (..), openTodos, todoKey, horizon, endOf, todoProblems
  ) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), Trigger (..))
import Data.Aeson (FromJSON, Result (..), ToJSON (..), Value, fromJSON, object, (.=))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe, maybeToList)
import Data.Ord (Down (..))
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, NominalDiffTime, UTCTime, addDays, defaultTimeLocale, diffUTCTime, formatTime, fromGregorian, toGregorian, utctDay)
import Data.Time.Calendar.WeekDate (toWeekDate)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
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
  , todos :: Map UUID Todo
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
  | Just project <- T.stripPrefix "todo/" t = todo project e s st
  | Map.member e.correlationId st.runs || "test/" `T.isPrefixOf` t = st
  | otherwise = st {runs = foldr Map.delete runs' old, byTopic = Map.insert t kept st.byTopic}
  where
    t = unTopic e.evtTopic
    runs' = Map.insert e.correlationId (Run e s Nothing) st.runs
    (kept, old) = splitAt keep (sortOn (Down . startAt) (e.correlationId : Map.findWithDefault [] t st.byTopic))
    startAt i = (runs' Map.! i).start.at

loggedAt :: Logged -> UTCTime
loggedAt = \case Started _ s -> s.at; Finished _ d -> d.at

-- * Todos
--
-- A todo is an event on @todo/<project>@, so a project is just a path. Later
-- events on its topic react to it: @{"due": day}@ reschedules it and
-- @{"done": true}@ closes it; a label renames it. Anything can add one.

data Todo = Todo
  { item :: EventId
  , title :: Text
  , project :: Text
  , captured :: UTCTime
  , due :: Day
  , closed :: Maybe UTCTime
  }

-- | A todo event's content.
data Change = Change {due :: Maybe Day, done :: Maybe Bool}
  deriving (Generic, ToJSON, FromJSON)

todo :: Text -> EventId -> Timed (EvtMsg Value) -> State -> State
todo project e s st = case [i | r <- fromMaybe [] s.e.reactTo, Just i <- [Map.lookup r.correlationId st.todos]] of
  i : _ -> st {todos = Map.insert i.item.correlationId (change i) st.todos}
  [] -> st {todos = Map.insertWith (\_ old -> old) e.correlationId (Todo e label project s.at (fromMaybe (utctDay s.at) c.due) Nothing) st.todos}
  where
    label = T.strip (T.pack s.e.label)
    c = case fromJSON <$> s.e.content of Just (Success x) -> x; _ -> Change Nothing Nothing
    change i = i {title = if T.null label then i.title else label, due = fromMaybe i.due c.due, closed = if c.done == Just True then Just s.at else i.closed}

-- | Open todos by project, soonest first.
openTodos :: State -> [Todo]
openTodos st = sortOn (\i -> (i.project, i.due)) [i | i <- Map.elems st.todos, isNothing i.closed]

todoKey :: UUID -> Text
todoKey i = "todo/" <> UUID.toText i

data Horizon = Today | Week | Year
  deriving (Eq, Show)

-- | When a todo is for: anything late is for today.
horizon :: Day -> Todo -> Horizon
horizon today i
  | i.due <= today = Today
  | i.due <= endOf Week today = Week
  | otherwise = Year

endOf :: Horizon -> Day -> Day
endOf h today = case h of
  Today -> today
  Week -> let (_, _, d) = toWeekDate today in addDays (fromIntegral (7 - d)) today
  Year -> let (y, _, _) = toGregorian today in fromGregorian y 12 31

todoProblems :: Day -> Todo -> [Text]
todoProblems today i = ["Was due " <> T.pack (formatTime defaultTimeLocale "%a %e %b" i.due) <> "." | i.due < today]

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

-- | A run at a glance: whether it went wrong by itself, and how long it took.
data Tick = Tick Text NominalDiffTime

instance ToJSON Tick where
  toJSON (Tick s took) = object ["status" .= s, "took" .= took]

tick :: UTCTime -> Run -> Tick
tick now r = Tick status took
  where
    took = duration now r
    status
      | maybe False (not . (.e.success)) r.end || took > fromIntegral r.start.e.rules.timeout = "bad"
      | isNothing r.end = "running"
      | otherwise = "fine"

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
    hidden t = any (`T.isPrefixOf` t) ["system/", "healthcheck/", "trigger/"] || Set.member t scoped
    nodes = filter (not . hidden) (Set.toList (Set.fromList (Map.keys st.byTopic ++ st.required ++ concat [[a, b] | (a, b) <- reactions])))
    plain = [Link a b Nothing Nothing | (a, b) <- reactions, not (hidden a), not (hidden b)]
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
