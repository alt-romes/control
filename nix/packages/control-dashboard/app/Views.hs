{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields, LambdaCase, TemplateHaskell #-}
-- | The dashboard's pages. Pages keep themselves up to date, and count what
-- needs attention in their title.
--
-- Only what needs attention is coloured: a page with nothing wrong has no
-- colour at all.
module Views
  ( Ctx (..), Page, render
  , overviewPage, topicPage, runPage
  ) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), Trigger (..))
import Control.Monad (forM_, guard, unless, when)
import Data.Aeson (Value (..), encode, toJSON)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as BL
import Data.FileEmbed (embedStringFile)
import Data.Containers.ListUtils (nubOrdOn)
import Data.List (isSuffixOf, partition, sortOn)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing, listToMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Data.Time (TimeZone, UTCTime, defaultTimeLocale, diffUTCTime, formatTime, utcToLocalTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Events
import Network.HTTP.Types (urlEncode)
import Network.MQTT.Topic (Topic, split, unTopic)
import Text.Blaze (customAttribute)
import Text.Blaze.Html5 (Html, toHtml, toValue, (!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

-- | Everything the pages show.
data Ctx = Ctx
  { now :: UTCTime
  , tz :: TimeZone
  , ix :: Index
  , connected :: Bool
  , required :: [Topic] -- ^ topics that must have run
  , links :: [String] -- ^ hosts linked to in the header
  }

data Page = Page {title :: Text, body :: Html}

-- | The whole page, or with @live@ just its title and body. A page fetches
-- itself live every 5s and morphs in the result, whose title keeps the count
-- of what needs attention current.
render :: Ctx -> Bool -> Page -> Html
render c live p
  | live = H.title title >> body
  | otherwise = H.docTypeHtml $ do
      H.head $ do
        H.meta ! A.charset "utf-8"
        H.title title
        H.link ! A.rel "icon" ! A.href "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect width='16' height='16'/%3E%3C/svg%3E"
        H.style $ H.preEscapedString $(embedStringFile "app/style.css")
        H.script ! A.src "https://cdn.jsdelivr.net/npm/htmx.org@4.0.0-beta4"
          ! customAttribute "integrity" "sha384-aWZK1NtOs/aWb/+YZdTM8q2JkWEshlMc9mgZ189numT9bwFhyAyYEoO4nO/2dTXt"
          ! customAttribute "crossorigin" "anonymous"
          $ mempty
      H.body $ do
        H.header $ do
          H.nav $ H.a ! A.href "/" $ "Overview"
          H.nav $ forM_ c.links $ \h ->
            H.a ! A.href (toValue ((if ".localhost" `isSuffixOf` h then "http://" else "https://") <> h)) $ toHtml h
        H.main ! customAttribute "hx-get" "?live" ! customAttribute "hx-trigger" "every 5s" ! customAttribute "hx-swap" "innerMorph" $ body
  where
    n = attention c
    title = toHtml ((if n == 0 then "" else "(" <> tshow n <> ") ") <> p.title <> " · control-dashboard")
    body = p.body >> H.p (toHtml ("Updated " <> formatTime defaultTimeLocale "%H:%M:%S" (utcToLocalTime c.tz c.now)))

--------------------------------------------------------------------------------
-- Pages

-- | What needs attention, most first, then everything else by name, as in
-- @<cmd>/<name>/...@. Each run is shown in its chain of reactions, from the
-- first cause.
overviewPage :: Ctx -> Page
overviewPage c = Page "Overview" $ do
  unless c.connected $ H.h1 $ flag Crisis "Broker unreachable: this may be stale"
  forM_ (missing c) $ \t -> H.h1 $ flag Crisis $ "No run seen of required " >> topicLink t
  H.h1 $ flag (maximum (Healthy : map (severity c) flagged)) $
    if null flagged then "All clear" else toHtml (tshow (length flagged) <> " need attention")
  table c Nothing $
    [("Needs attention", concatMap snd (sortOn (\(rs, _) -> (Down (maximum (map (severity c) rs)), minimum (map (fst . failingSince c) rs))) urgent)) | not (null urgent)]
      ++ Map.toList (Map.fromListWith (flip (++)) [(foldMap unTopic (take 1 (drop 1 (split r.eid.evtTopic))), rows) | (_, rows@(RunRow _ r : _)) <- calm])
  where
    flagged = filter (needsAttention c) (shown c)
    chains = map (chain c 0) (nubOrdOn (.eid.correlationId) [last (r : causes c.ix r) | r <- shown c])
    (urgent, calm) = partition (not . null . fst) [([r | r <- runsOf rows, r.eid.correlationId `elem` map (.eid.correlationId) flagged], rows) | rows <- chains]

-- | Every run seen on one topic.
topicPage :: Topic -> Ctx -> Page
topicPage t c = Page (unTopic t) $ do
  H.h1 (toHtml (unTopic t))
  case Map.findWithDefault [] t c.ix.byTopic of
    [] -> H.p "No runs seen on this topic yet."
    rs@(latest : _) -> do
      when (isNothing latest.start.x.rules.expected) $
        H.p "No expected interval is set, so the dashboard can't tell if this stops running."
      table c Nothing [("", concatMap (chain c 0) rs)]

-- | One run in full: what's wrong with it, its details, its subtasks, and the
-- whole chain of reactions it's part of.
runPage :: UUID -> Ctx -> Page
runPage u c = case Map.lookup u c.ix.runs of
  Nothing -> Page "Run not found" $ H.p "Run not found: it may have been pruned."
  Just r -> Page (unTopic r.eid.evtTopic <> " run") $ do
    H.h1 (topicLink r.eid.evtTopic)
    let ps = problemsOf c r
    unless (null ps) $ H.div ! colour (severity c r) $ do
      H.ul $ forM_ ps $ \(name, why) -> H.li $ H.strong (toHtml name) >> " " >> toHtml why
      when r.acked "Acknowledged."
    H.p (ackButton c r)
    H.dl $ do
      field "Label" (toHtml r.start.x.label)
      field "Started" $ toHtml (localTime c r.start.at) >> " (" >> ago c r.start.at >> ")"
      field "Finished" $ case r.end of
        Just e -> toHtml (localTime c e.at)
        Nothing | timedOut c.now r -> "never received"
                | otherwise -> "not yet"
      field "Took" (took c r)
      field "Summary" (toHtml (summaryOf r))
      forM_ r.start.x.scope $ field "Part of" . eventLink
      forM_ r.start.x.reactTo $ field "Reacting to" . eventLink
      field "Correlation id" $ H.code (toHtml (UUID.toText u))
    sequence_ [H.h2 h >> H.pre (pretty v) | (h, Just v) <- [("Rules", Just (toJSON r.start.x.rules)), ("Content", contentOf r), ("Result", r.end >>= (.x.result))]]
    let whole = chain c 0 (last (r : causes c.ix r))
    table c (Just u) [(name, rows) | (name, rows) <- [("Subtasks", concatMap (chain c 0) (Map.findWithDefault [] u c.ix.scopedTo)), ("Chain of reactions", whole)], length rows > 1 || name == "Subtasks" && not (null rows)]
  where
    field :: Text -> Html -> Html
    field k v = H.dt (toHtml k) >> H.dd v
    eventLink e = case Map.lookup e.correlationId c.ix.runs of
      Just p -> runLink p (toHtml (unTopic p.eid.evtTopic))
      Nothing -> H.code (toHtml (unTopic e.evtTopic <> " " <> UUID.toText e.correlationId))

--------------------------------------------------------------------------------
-- What needs attention

-- | How much a run needs attention, least first.
data Severity = Healthy | Actionable | Crisis
  deriving (Eq, Ord)

severity :: Ctx -> Run -> Severity
severity c r
  | bad c r && not r.acked = if r.start.x.rules.critical then Crisis else Actionable
  | otherwise = Healthy

needsAttention :: Ctx -> Run -> Bool
needsAttention c r = severity c r >= Actionable

-- | What needs attention, the required topics never seen, and the broker if
-- it's unreachable.
attention :: Ctx -> Int
attention c = length (filter (needsAttention c) (shown c)) + length (missing c) + fromEnum (not c.connected)

-- | The latest run of every event, and every crisis, newest first.
shown :: Ctx -> [Run]
shown c = sortOn (Down . (.start.at)) [r | r <- Map.elems c.ix.runs, severity c r == Crisis || r.eid.correlationId `elem` latest]
  where latest = map (.eid.correlationId) (latestRuns c.ix)

missing :: Ctx -> [Topic]
missing c = filter (`Map.notMember` c.ix.byTopic) c.required

problemsOf :: Ctx -> Run -> [(Text, Text)]
problemsOf c = problems c.now c.ix

bad :: Ctx -> Run -> Bool
bad c = not . null . problemsOf c

-- | Since when the run's topic has had problems in a row, up to the run, and
-- in how many runs.
failingSince :: Ctx -> Run -> (UTCTime, Int)
failingSince c r = (maybe r.start.at (.start.at) (listToMaybe (reverse streak)), length streak)
  where streak = takeWhile (bad c) (dropWhile ((/= r.eid.correlationId) . (.eid.correlationId)) (topLevel c.ix r.eid.evtTopic))

--------------------------------------------------------------------------------
-- Pieces

-- | A row of a 'table', indented by how deep in a chain of reactions it is:
-- a run, or a trigger a run has yet to send.
data Row = RunRow Int Run | TriggerRow Int Run (Int, Trigger)

-- | A run, then the runs reacting to it, oldest first, then the triggers it
-- has yet to send, where their runs will show up.
chain :: Ctx -> Int -> Run -> [Row]
chain c d r = RunRow d r : concatMap (chain c (d + 1)) (reverse (reactionsTo c r)) ++ [TriggerRow (d + 1) r t | t <- pendingTriggers c.ix r]

runsOf :: [Row] -> [Run]
runsOf rows = [r | RunRow _ r <- rows]

reactionsTo :: Ctx -> Run -> [Run]
reactionsTo c r = Map.findWithDefault [] r.eid.correlationId c.ix.reactingTo

-- | Rows as one table, in sections named unless empty, highlighting the
-- current run. Consecutive runs that differ only in when they ran are shown
-- once, as the first, with how many there were. The latest run of a topic
-- shows the topic's recent history.
table :: Ctx -> Maybe UUID -> [(Text, [Row])] -> Html
table c current sections = unless (null sections) $ H.table $ do
  H.tr $ mapM_ H.th ["", "Event", "Problem", "Run", "Took", "Summary", "History", ""]
  forM_ sections $ \(name, rows) -> do
    unless (T.null name) $ H.tr ! A.class_ "section" $ H.th ! A.colspan "8" $ toHtml name
    forM_ (NE.groupBy same rows) $ \g -> case NE.head g of
      RunRow d r -> H.tr ! (if current == Just r.eid.correlationId then A.class_ "current" else mempty) $ do
        H.td (marker (severity c r))
        H.td ! A.class_ "topic" ! indent d $ arrow d >> topicLink r.eid.evtTopic
        H.td (problem r)
        H.td ! A.class_ "time" $ runLink r (ago c r.start.at) >> times c (runsOf (NE.toList g)) >> forM_ r.start.x.rules.expected (\e -> toHtml (" / " <> fmtDuration e))
        H.td ! A.class_ "time" $ took c r
        H.td (toHtml (summaryOf r))
        H.td $ when (map (.eid.correlationId) (take 1 (topLevel c.ix r.eid.evtTopic)) == [r.eid.correlationId]) (history c r.eid.evtTopic)
        H.td (ackButton c r)
      TriggerRow d r t -> H.tr ! A.class_ "pending" $ do
        H.td mempty
        H.td ! A.class_ "topic" ! indent d $ arrow d >> topicLink (snd t).triggerTopic
        H.td mempty
        H.td ! A.class_ "time" $ "not sent"
        H.td mempty
        H.td (toHtml (snd t).triggerLabel)
        H.td mempty
        H.td (triggerButton r t)
  where
    -- A run with reactions or triggers is never folded in, lest they show
    -- under another run.
    same (RunRow d r) (RunRow d' r') = d == d' && key r == key r' && null (reactionsTo c r') && null (pendingTriggers c.ix r')
    same _ _ = False
    key r = (r.eid.evtTopic, problemsOf c r, severity c r, summaryOf r)
    indent d = A.style (toValue ("padding-left: " <> tshow (0.5 + 1.5 * fromIntegral d :: Double) <> "em"))
    arrow d = when (d > 0) "↳ "
    problem r = let ps = problemsOf c r in
      flag (severity c r) ! A.title (toValue (T.unwords (map snd ps))) $ unless (null ps) $ do
        toHtml (T.intercalate ", " (map fst ps))
        let (since, n) = failingSince c r
        when (n > 1) $ toHtml (", for " <> tshow n <> " runs since ") >> ago c since
        when r.acked " (acknowledged)"

-- | The latest top-level runs of a topic, oldest first, a mark each.
history :: Ctx -> Topic -> Html
history c t = H.span ! A.class_ "history" $ forM_ (reverse (take 20 (topLevel c.ix t))) $ \r ->
  runLink r mempty
    ! A.class_ (if bad c r then "tick bad" else "tick")
    ! A.title (toValue (T.unwords (localTime c r.start.at : map fst (problemsOf c r))))

ackButton :: Ctx -> Run -> Html
ackButton c r = when (needsAttention c r) $ action r "ack" Nothing "Acknowledge"

-- | Send a trigger the run announced.
triggerButton :: Run -> (Int, Trigger) -> Html
triggerButton r (i, t) = action r ("trigger/" <> tshow i) (Just (T.pack t.triggerLabel <> "?")) "Send"
  ! A.title (toValue (unTopic t.triggerTopic <> foldMap ((" " <>) . json) t.triggerData))

-- | A button posting to one of the run's actions, maybe asking first.
action :: Run -> Text -> Maybe Text -> Html -> Html
action r a confirm b = H.form ! A.method "post" ! A.action (toValue (runUrl r <> "/" <> a))
  ! foldMap (\q -> A.onsubmit (toValue ("return confirm(" <> json (String q) <> ")"))) confirm $ H.button b

flag :: Severity -> Html -> Html
flag s = H.span ! colour s

colour :: Severity -> H.Attribute
colour = \case
  Crisis -> A.class_ "crisis"
  Actionable -> A.class_ "bad"
  Healthy -> mempty

-- | How much the run needs attention.
marker :: Severity -> Html
marker s = flag s $ case s of
  Crisis -> "▲"
  Actionable -> "●"
  Healthy -> mempty

-- | How many runs, if more than one, listing them on hover.
times :: Ctx -> [Run] -> Html
times c rs = when (length rs > 1) $
  H.span ! A.title (toValue (T.intercalate "\n" (map (localTime c . (.start.at)) rs))) $ toHtml (" ×" <> tshow (length rs))

-- | How long a finished run took, or how long an unfinished one has been
-- running. An unfinished run past its timeout isn't running any more.
took :: Ctx -> Run -> Html
took c r = case r.end of
  Just _ -> toHtml (fmtDuration (duration c.now r))
  Nothing -> unless (timedOut c.now r) $ toHtml (fmtDuration (duration c.now r) <> ", running")

summaryOf :: Run -> Text
summaryOf r = foldMap (\e -> T.pack e.x.summary) r.end

-- | The run's content, unless empty.
contentOf :: Run -> Maybe Value
contentOf r = r.start.x.content >>= \v -> v <$ guard (v `notElem` [Null, Object mempty, Array mempty])

ago :: Ctx -> UTCTime -> Html
ago c t = H.span ! A.title (toValue (localTime c t)) $
  toHtml (fmtDuration (fromInteger (max 1 (floor (diffUTCTime c.now t)))) <> " ago")

localTime :: Ctx -> UTCTime -> Text
localTime c = T.pack . formatTime defaultTimeLocale "%a %d %b %H:%M:%S" . utcToLocalTime c.tz

topicLink :: Topic -> Html
topicLink t = H.a ! A.href (toValue ("/topic/" <> T.intercalate "/" (map (enc . unTopic) (split t)))) $ toHtml (unTopic t)
  where enc = decodeUtf8Lenient . urlEncode True . encodeUtf8

runUrl :: Run -> Text
runUrl r = "/run/" <> UUID.toText r.eid.correlationId

runLink :: Run -> Html -> Html
runLink r = H.a ! A.href (toValue (runUrl r))

json :: Value -> Text
json = decodeUtf8Lenient . BL.toStrict . encode

-- | Strings as they are (e.g. exception details), anything else as JSON.
pretty :: Value -> Html
pretty = \case
  String t -> toHtml t
  v -> toHtml (decodeUtf8Lenient (BL.toStrict (encodePretty v)))

tshow :: Show a => a -> Text
tshow = T.pack . show
