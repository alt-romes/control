{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields, LambdaCase #-}
-- | The graph the page draws: a node per event topic, showing its latest run,
-- inside the node of the run it is @scope@d to or else in a group with the
-- topics of its service, linked from the run it @reactTo@s (through the
-- trigger, if it was triggered), and followed by a node showing its output.
-- Machines and healthchecks are listed apart.
module Tree (Ctx (..), Severity (..), Link (..), View (..), events, holder, links, outputOf, views, shapes, tableOf, files, failingSince, orphaned, filling, dailyCount, perDay, madeUp, graphJson, runsJson, alerts) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), Trigger (..), reacted, (^.))
import Data.Aeson (ToJSON (..), Value (..), object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Data.Function (on)
import Data.List (nub, nubBy)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe, mapMaybe, maybeToList)
import Data.Char (isDigit, isLetter)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (NominalDiffTime, UTCTime (..), diffUTCTime, fromGregorian)
import Data.UUID (UUID)
import Events
import Network.MQTT.Topic (Topic, split, unTopic)

data Ctx = Ctx
  { now :: UTCTime
  , ix :: Index
  , connected :: Bool
  , sleeps :: [(UTCTime, UTCTime)]
  , required :: [Topic]
  , since :: UTCTime
  , wills :: [(Topic, UTCTime)]
    -- ^ The service topics whose connections died, and when
    -- ^ When the dashboard started: whether its machine slept before, it can't tell
  , logs :: Map.Map Topic Text
    -- ^ The end of the log of each event topic whose latest run failed
  }

data Severity = Healthy | Actionable | Crisis
  deriving (Eq, Ord, Show)

instance ToJSON Severity where
  toJSON = String . T.toLower . T.pack . show

-- | A reaction, a trigger sent, or one pending, which can be sent from here.
data Link = Link {source :: Topic, target :: Topic, trigger :: Maybe Text, pending :: Maybe (UUID, Int)}
  deriving (Eq, Show)

topics :: Ctx -> [Topic]
topics c = nub (Map.keys c.ix.byTopic ++ c.required)

kind :: Text -> Topic -> Bool
kind k t = (k <> "/") `T.isPrefixOf` unTopic t

-- | Topics drawn as nodes: not machines or healthchecks, which are listed
-- apart, nor triggers, which label the links they make.
events :: Ctx -> [Topic]
events c = [t | t <- topics c, not (any (`kind` t) ["system", "healthcheck", "trigger"])]

latest :: Ctx -> Topic -> Maybe Run
latest c t = case Map.findWithDefault [] t c.ix.byTopic of
  r : _ -> Just r
  [] -> Nothing

-- | The run a run is scoped to, or reacts to.
via :: Ctx -> (EvtMsg Value -> Maybe EventId) -> Run -> Maybe Run
via c f r = f r.start.e >>= \e -> Map.lookup e.correlationId c.ix.runs

-- | The event topic whose node holds this one, unless that would nest it in itself.
scopeParent :: Ctx -> Topic -> Maybe Topic
scopeParent c t = scopeOf t >>= \p -> if loops [t] p || p `notElem` events c then Nothing else Just p
  where
    scopeOf u = (.eid.evtTopic) <$> (latest c u >>= via c (.scope))
    loops seen u = u `elem` seen || maybe False (loops (u : seen)) (scopeOf u)

-- | The service a topic belongs to: what follows its kind.
service :: Topic -> Text
service t = case map unTopic (split t) of
  _ : s : _ -> s
  s : _ -> s
  [] -> ""

-- | Top-level event topics, by service.
groups :: Ctx -> Map.Map Text [Topic]
groups c = Map.fromListWith (flip (++)) [(service t, [t]) | t <- events c, isNothing (scopeParent c t)]

-- | The id of the node holding a topic's: the topic it's scoped to, or else
-- its service's group, which ends in a slash, as topics never do. A service
-- of one topic isn't a group.
holder :: Ctx -> Topic -> Maybe Text
holder c t = case scopeParent c t of
  Just p -> Just (unTopic p)
  Nothing | length (Map.findWithDefault [] (service t) (groups c)) > 1 -> Just (service t <> "/")
          | otherwise -> Nothing

-- | What each latest run reacts to, seen through triggers, and the triggers
-- pending whose target is known from earlier runs.
links :: Ctx -> [Link]
links c = nubBy ((==) `on` ends) (pendings ++ sent)
  where
    ends l = (l.source, l.target)
    shown = events c
    sent =
      [ l
      | t <- shown, Just r <- [latest c t], Just p <- [via c (^. reacted) r]
      , l <- if kind "trigger" p.eid.evtTopic
               then [Link q.eid.evtTopic t (Just (T.pack p.start.e.label)) Nothing | Just q <- [via c (^. reacted) p]]
               else [Link p.eid.evtTopic t Nothing Nothing]
      , l.source `elem` shown, l.source /= t ]
    pendings = [Link t u (Just (T.pack tr.triggerLabel)) (Just (r.eid.correlationId, i)) | t <- shown, Just r <- [latest c t], isNothing (orphaned c r), (i, tr) <- pendingTriggers c.ix r, Just u <- [reactor c tr.triggerTopic]]

-- | An event topic that reacted to a trigger sent on this topic before.
reactor :: Ctx -> Topic -> Maybe Topic
reactor c tt = listToMaybe
  [ s.eid.evtTopic | p <- Map.findWithDefault [] tt c.ix.byTopic, s <- Map.findWithDefault [] p.eid.correlationId c.ix.reactingTo
  , s.eid.evtTopic `elem` events c ]

-- | What the latest run produced worth showing: a result besides an exit code
-- or flag, or else a summary too long for its card, and the files named in
-- the result or in the data of the triggers it offers.
outputOf :: Ctx -> Run -> Maybe (Maybe Value, [FilePath])
outputOf c r = if isNothing shown && null fs then Nothing else Just (shown, fs)
  where
    result = r.end >>= (.e.result)
    shown = case result of
      Just v@(String _) -> Just v
      Just v@(Object _) -> Just v
      Just v@(Array _) -> Just v
      _ | Just e <- r.end, '\n' `elem` e.e.summary -> Just (String (T.pack e.e.summary))
        | otherwise -> Nothing
    fs = nub (concatMap paths (maybeToList result ++ mapMaybe ((.triggerData) . snd) (pendingTriggers c.ix r)))
    paths = \case
      String s | "/" `T.isPrefixOf` s, any (`T.isSuffixOf` T.toLower s) exts -> [T.unpack s]
      Object o -> concatMap paths (toList o)
      Array a -> concatMap paths (toList a)
      _ -> []
    exts = [".pdf", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"]

-- | The only files the page may fetch: those its output nodes show.
files :: Ctx -> [FilePath]
files c = [T.unpack f | t <- events c, View k Nothing (String f) <- views c t, k `elem` ["document", "image"], not ("data:" `T.isPrefixOf` f)]

-- | What a topic's latest run holds that is recognisably something, each to be
-- shown in a node of its own: a table of figures, documents, images, the end
-- of its log, or else text or data; and the people its recent runs were about.
views :: Ctx -> Topic -> [View]
views c t = case Map.findWithDefault [] t c.ix.byTopic of
  [] -> []
  rs@(r : _) ->
    shapes (mapMaybe (.start.e.content) rs)
      ++ [v | Just (shown, fs) <- [outputOf c r], v <- resultViews shown ++ map fileView fs]
      ++ [View "log" Nothing (String l) | Just l <- [Map.lookup t c.logs]]
      ++ [View "people" Nothing (toJSON ps) | let ps = people rs, not (null ps)]
      ++ [View "runs" Nothing (toJSON (map recent latest8)) | isJust (dailyCount c rs), isNothing (scopeParent c t), length (nub (map said latest8)) > 1]
  where
    -- A result is shown as whatever it's laid out as, or else as it is.
    resultViews = \case
      Just v | vs@(_ : _) <- shapes (v : [x | r' <- drop 1 allRuns, Just e <- [r'.end], Just x <- [e.e.result]]) -> vs
      Just (String s) | Just rows <- tableOf s -> [View "table" Nothing (toJSON rows)]
                      | otherwise -> [View "text" Nothing (String s)]
      Just v -> [View "data" Nothing v]
      Nothing -> []
    fileView f = View (if ".pdf" `T.isSuffixOf` T.toLower (T.pack f) then "document" else "image") Nothing (String (T.pack f))
    allRuns = Map.findWithDefault [] t c.ix.byTopic
    latest8 = take 8 allRuns
    -- Requests come with what they were and how they went.
    said r = (r.start.e.label, foldMap (.e.summary) r.end)
    recent r = object
      [ "label" .= r.start.e.label, "summary" .= foldMap (.e.summary) r.end, "bad" .= not (null (problemsOf c r))
      , "ago" .= (fmtDuration (max 1 (fromInteger (floor (diffUTCTime c.now r.start.at)))) <> " ago") ]
    people rs =
      [ object ["name" .= name, "email" .= e, "madeUp" .= maybe False (`madeUp` e) name, "ago" .= (fmtDuration (max 1 (fromInteger (floor (diffUTCTime c.now r.start.at)))) <> " ago")]
      | r <- take 10 rs, Just (Object o) <- [r.start.e.content], Just (String e) <- [o KM.!? "email"]
      , let name = case o KM.!? "name" of Just (String n) -> Just n; _ -> Nothing ]

-- | Something a run holds, shown in a node of its own: what kind of thing it
-- is, the field it came from, if any, and the thing.
data View = View {viewKind :: Text, viewTitle :: Maybe Text, viewValue :: Value}

-- | Data recognised by how it's laid out, not by what it's called, from the
-- same place in the latest runs, newest first: a list of records is a table,
-- numbers are a trend across runs, an email is one sent, an inline image is
-- one. Fields of an object are recognised in turn.
shapes :: [Value] -> [View]
shapes vs = case vs of
  _ : _ | Just (k, x) <- shape vs -> [View k Nothing x]
  Object o : _ -> [View k (Just (K.toText key)) x | key <- KM.keys o, Just (k, x) <- [shape [x' | Object o' <- vs, Just x' <- [o' KM.!? key]]]]
  _ -> []
  where
    shape = \case
      Array xs : _ | Just tbl <- records (toList xs) -> Just ("records", tbl)
      older@(Object o : _) | not (KM.null o), all isNumber o -> Just ("trend", toJSON (trend older))
                           | KM.member "to" o && KM.member "subject" o -> Just ("mail", Object o)
      String s : _ | "data:image/" `T.isPrefixOf` s -> Just ("image", String s)
      _ -> Nothing
    isNumber = \case Number _ -> True; _ -> False
    trend older = Map.fromListWith (flip (++)) [(K.toText k, [realToFrac n :: Double]) | Object o <- reverse (take 288 older), (k, Number n) <- KM.toList o]
    records = \case
      xs@(Object o : _) | all ((== KM.keys o) . keysOf) xs, all (all scalar) [o' | Object o' <- xs] ->
        Just (object ["columns" .= map K.toText (KM.keys o), "rows" .= [toList o' | Object o' <- xs]])
      _ -> Nothing
    keysOf = \case Object o -> KM.keys o; _ -> []
    scalar = \case Object _ -> False; Array _ -> False; _ -> True

-- | Whether a name looks made up for an email: none of its words are in the
-- address, as when a bot signs up someone else's.
madeUp :: Text -> Text -> Bool
madeUp name email = not (null ws) && not (any (`T.isInfixOf` local) ws)
  where
    local = T.toLower (T.takeWhile (/= '@') email)
    ws = [w | w <- T.words (T.toLower (T.map (\ch -> if isLetter ch then ch else ' ') name)), T.length w > 2, w `notElem` ["mr", "mrs", "dr", "miss"]]

-- | Text laid out as figures: lines of a label, an amount and maybe a note,
-- under headings. Amounts have decimals, so a number in a label isn't one.
tableOf :: Text -> Maybe [Value]
tableOf s = case traverse row (filter (not . T.null . T.strip) (T.lines s)) of
  Just rows | length [() | Right _ <- rows] >= 2 -> Just (map (either (\h -> object ["head" .= h]) (\cs -> object ["cells" .= cs])) rows)
  _ -> Nothing
  where
    row l = case break amount (filter (not . T.null) (map T.strip (T.splitOn "  " l))) of
      (label@(_ : _), v : note) -> Just (Right [T.unwords label, v, T.unwords note])
      ([h], []) -> Just (Left h)
      _ -> Nothing
    amount x = case T.split (`elem` [',', '.']) (T.dropWhile (== '-') x) of
      [i, d] -> not (T.null i) && not (T.null d) && T.all isDigit i && T.all isDigit d
      _ -> False

severityOf :: Ctx -> Run -> Severity
severityOf c r
  | null (problemsOf c r) = Healthy
  | isCritical c.ix r = Crisis
  | otherwise = Actionable

severity :: Ctx -> Topic -> Severity
severity c = maybe Crisis (severityOf c) . latest c

problemsOf :: Ctx -> Run -> [(Text, Text)]
problemsOf c = problems ((UTCTime (fromGregorian 1970 1 1) 0, c.since) : c.sleeps) c.now c.ix

graphJson :: Ctx -> Value
graphJson c = object
  [ "connected" .= c.connected
  , "slept" .= [fmtDuration (diffUTCTime b a) | (a, b) <- c.sleeps, diffUTCTime c.now b < 86400]
  , "machines" .= listed "system"
  , "healthchecks" .= listed "healthcheck"
  , "nodes" .= ( [ object ["id" .= (s <> "/"), "title" .= s, "group" .= True, "severity" .= maximum (map (severity c) ts)]
                 | (s, ts) <- Map.toList (groups c), length ts > 1 ]
                 ++ concatMap node (events c) )
  , "edges" .= ( [ object ["source" .= unTopic l.source, "target" .= unTopic l.target, "kind" .= linkKind l
                          , "label" .= l.trigger, "run" .= fmap fst l.pending, "index" .= fmap snd l.pending]
                 | l <- links c ]
                 ++ [object ["source" .= unTopic t, "target" .= viewId t i, "kind" .= ("output" :: Text)] | t <- events c, (i, _) <- zip [0 :: Int ..] (views c t)] )
  ]
  where
    linked = [p | Link {pending = Just p} <- links c]
    viewId t i = unTopic t <> "#" <> T.pack (show i)
    runsOf t = Map.findWithDefault [] t c.ix.byTopic
    -- A subtask runs when its run does, so how often isn't news.
    daily t = if isJust (scopeParent c t) then Nothing else dailyCount c (runsOf t)
    since at = fmtDuration (max 1 (fromInteger (floor (diffUTCTime c.now at))))
    listed k =
      [ card t (T.drop (T.length k + 1) (unTopic t)) ["spark" .= spark c (runsOf t), "series" .= series (runsOf t)]
          [if d <= 0 then m <> " is full" else m <> " full in ~" <> fmtDuration d <> " at this rate" | (m, d) <- filling c (runsOf t)]
      | t <- topics c, kind k t ]
    linkKind :: Link -> Text
    linkKind l = case (l.trigger, l.pending) of
      (Nothing, _) -> "reaction"
      (_, Nothing) -> "trigger"
      _ -> "pending"
    title t = case (scopeParent c t, holder c t) of
      (Just p, _) -> fromMaybe (unTopic t) (T.stripPrefix (unTopic p <> "/") (unTopic t))
      (_, Just _) -> T.intercalate "/" (drop 2 (map unTopic (split t)))
      _ -> unTopic t
    card t name extra more = object $ ["id" .= unTopic t, "title" .= name] ++ extra ++ case latest c t of
      Nothing -> ["severity" .= Crisis, "problems" .= ["never seen" :: Text]]
      Just r ->
        [ "severity" .= max (severityOf c r) (if null more then Healthy else Actionable)
        , "sub" .= (since r.start.at <> " ago" <> foldMap ((" · failing for " <>) . since) (failingSince c (runsOf t)) <> foldMap (\n -> " · " <> T.pack (show n) <> " in the last day") (daily t))
        -- A trigger awaited shows as its button.
        , "problems" .= ([w | (p, w) <- problemsOf c r, p /= "awaiting trigger"] ++ ["Its process died while waiting, " <> since at <> " ago; nothing will react to it now." | Just at <- [orphaned c r]] ++ more)
        ]
    node t =
      card t (title t)
        [ "parent" .= holder c t
        , "pending" .= [object ["run" .= r.eid.correlationId, "index" .= i, "label" .= tr.triggerLabel] | Just r <- [latest c t], isNothing (orphaned c r), (i, tr) <- pendingTriggers c.ix r, (r.eid.correlationId, i) `notElem` linked]
        , "history" .= reverse [not (null (problemsOf c r)) | r <- take 24 (runsOf t)]
        , "days" .= (daily t >> Just (perDay c (runsOf t))) ] []
        : [object ["id" .= viewId t i, "parent" .= holder c t, "view" .= v.viewKind, "title" .= v.viewTitle, "value" .= v.viewValue] | (i, v) <- zip [0 :: Int ..] (views c t)]

-- | When the process of a run still waiting, unfinished or for its triggers,
-- died: its service's connection left its last will after the run started.
orphaned :: Ctx -> Run -> Maybe UTCTime
orphaned c r
  | isNothing r.end || not (null (pendingTriggers c.ix r)) =
      listToMaybe [at | (base, at) <- c.wills, at > r.start.at, (unTopic base <> "/") `T.isPrefixOf` unTopic r.eid.evtTopic]
  | otherwise = Nothing

-- | When the latest runs started having problems, if more than one has.
-- Awaiting a trigger is waiting on someone, not failing.
failingSince :: Ctx -> [Run] -> Maybe UTCTime
failingSince c rs = case takeWhile (any ((/= "awaiting trigger") . fst) . problemsOf c) rs of
  bad@(_ : _ : _) -> Just (last bad).start.at
  _ -> Nothing

-- | How many runs started in the last day, for topics not run on a schedule,
-- whose runs are requests from elsewhere: how often they come is the news.
dailyCount :: Ctx -> [Run] -> Maybe Int
dailyCount c rs = case rs of
  r : _ | isNothing r.start.e.rules.expected, n <- length (takeWhile ((< 86400) . diffUTCTime c.now . (.start.at)) rs), n > 1 -> Just n
  _ -> Nothing

-- | How many runs started each of the last 14 days, oldest first.
perDay :: Ctx -> [Run] -> [Int]
perDay c rs = [length [() | r <- rs, floor (diffUTCTime c.now r.start.at / 86400) == i] | i <- [13, 12 .. 0 :: Int]]

-- | The last day in quarter hours, oldest first: null without runs, else
-- whether one had problems. Being overdue shows as a gap, not a failure.
spark :: Ctx -> [Run] -> [Value]
spark c rs =
  [ case [r | r <- rs, floor (diffUTCTime c.now r.start.at / 900) == i] of
      [] -> Null
      xs -> Bool (any (any ((/= "overdue") . fst) . problemsOf c) xs)
  | i <- [95, 94 .. 0 :: Int] ]

-- | Percentages the runs started with that, rising as they have over the last
-- day, reach 100% within a week, and how soon.
filling :: Ctx -> [Run] -> [(Text, NominalDiffTime)]
filling c rs =
  [ (k, realToFrac ((100 - y1) / slope))
  | (k, pts@((t0, _) : _ : _ : _)) <- Map.toList samples, let (t1, y1) = last pts, t1 - t0 > 3600
  , let slope = fitSlope pts, slope > 0, (100 - y1) / slope < 7 * 86400 ]
  where
    samples = Map.fromListWith (flip (++))
      [ (K.toText k, [(realToFrac (diffUTCTime r.start.at c.now) :: Double, x)])
      | r <- reverse (takeWhile ((< 86400) . diffUTCTime c.now . (.start.at)) rs), Just (Object o) <- [r.start.e.content]
      , (k, String v) <- KM.toList o, Just p <- [T.stripSuffix "%" v], [(x, "")] <- [reads (T.unpack p)] ]
    fitSlope pts = let n = fromIntegral (length pts); mx = sum (map fst pts) / n; my = sum (map snd pts) / n
                   in sum [(x - mx) * (y - my) | (x, y) <- pts] / sum [(x - mx) ^ (2 :: Int) | (x, _) <- pts]

-- | Each number (or percentage) the runs started with, oldest first.
series :: [Run] -> Map.Map Text [Double]
series rs = Map.fromListWith (flip (++)) [(K.toText k, [x]) | r <- reverse (take 288 rs), Just (Object o) <- [r.start.e.content], (k, v) <- KM.toList o, Just x <- [number v]]
  where
    number = \case
      Number n -> Just (realToFrac n)
      String s | Just p <- T.stripSuffix "%" s, [(x, "")] <- reads (T.unpack p) -> Just x
      _ -> Nothing

-- | A topic's latest runs, for its details.
runsJson :: Ctx -> Topic -> Value
runsJson c t = toJSON
  [ object
      [ "at" .= r.start.at, "ago" .= ago r.start.at, "label" .= r.start.e.label
      , "took" .= if isNothing r.end && timedOut c.now r then "never finished" else fmtDuration (duration c.now r) <> maybe ", running" (const "") r.end
      , "summary" .= foldMap (.e.summary) r.end
      , "problems" .= [p <> ": " <> w | (p, w) <- problemsOf c r]
      , "content" .= r.start.e.content, "result" .= (r.end >>= (.e.result))
      ]
  | r <- take 20 (Map.findWithDefault [] t c.ix.byTopic) ]
  where ago at = fmtDuration (max 1 (fromInteger (floor (diffUTCTime c.now at)))) <> " ago"

-- | Each top-level topic with problems, for @--alert@.
alerts :: Ctx -> [Text]
alerts c =
  [ unTopic t <> ": " <> maybe "no run seen of this required topic" (T.intercalate ", " . map fst . problemsOf c) mr
  | t <- topics c, let mr = latest c t
  , maybe True (\r -> isNothing r.start.e.scope && not (null (problemsOf c r))) mr ]
