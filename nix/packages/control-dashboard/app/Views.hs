{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields, LambdaCase, TemplateHaskell #-}
-- | The dashboard's pages. Pages keep themselves up to date, and count what
-- needs attention in their title.
--
-- Only what needs attention is coloured: a page with nothing wrong has no
-- colour at all.
module Views
  ( Ctx (..), Page, render
  , overviewPage, topicPage, runPage, triggerPage
  , alerts
  ) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), Trigger (..))
import Control.Monad (forM_, guard, unless, when)
import Data.Aeson (Value (..), encode, toJSON)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as BL
import Data.FileEmbed (embedStringFile)
import Data.Containers.ListUtils (nubOrdOn)
import Data.List (partition, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
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
  , links :: [Text] -- ^ URLs linked to in the header
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
          H.nav $ forM_ c.links $ \u -> H.a ! A.href (toValue u) $ toHtml (snd (T.breakOnEnd "://" u))
        H.main ! customAttribute "hx-get" "?live" ! customAttribute "hx-trigger" "every 5s" ! customAttribute "hx-swap" "innerMorph" $ body
  where
    n = attention c
    title = toHtml ((if n == 0 then "" else "(" <> tshow n <> ") ") <> p.title <> " · control-dashboard")
    body = p.body >> H.p (toHtml ("Updated " <> formatTime defaultTimeLocale "%H:%M:%S" (utcToLocalTime c.tz c.now)))

--------------------------------------------------------------------------------
-- Pages

-- | What needs attention, then everything else by name, as in
-- @<cmd>/<name>/...@. Each run is shown in its chain of reactions, from the
-- first cause.
overviewPage :: Ctx -> Page
overviewPage c = Page "Overview" $ do
  unless c.connected $ H.h1 $ flag Crisis "Broker unreachable: this may be stale"
  forM_ (missing c) $ \t -> H.h1 $ flag Crisis $ "No run seen of required " >> topicLink t
  H.h1 $ flag (maximum (Healthy : map (severity c) flagged)) $
    if null flagged then "All clear" else toHtml (tshow (length flagged) <> " need attention")
  table c Nothing True $
    [("Needs attention", concat urgent) | not (null urgent)]
      ++ Map.toList (Map.fromListWith (flip (++)) [(name r, rows) | rows@(RunRow _ r : _) <- calm])
  where
    flagged = filter (needsAttention c) (shown c)
    chains = map (chain c 0) (nubOrdOn (.eid.correlationId) (map (rootCause c.ix) (shown c)))
    (urgent, calm) = partition (any ((`elem` map (.eid.correlationId) flagged) . (.eid.correlationId)) . runsOf) chains
    name r = foldMap unTopic (take 1 (drop 1 (split r.eid.evtTopic)))

-- | Every run seen on one topic.
topicPage :: Topic -> Ctx -> Page
topicPage t c = Page (unTopic t) $ do
  H.h1 (toHtml (unTopic t))
  case Map.findWithDefault [] t c.ix.byTopic of
    [] -> H.p "No runs seen on this topic yet."
    rs@(latest : _) -> do
      when (isNothing latest.start.e.rules.expected) $
        H.p "No expected interval is set, so the dashboard can't tell if this stops running."
      table c Nothing False [("", concatMap (chain c 0) rs)]

-- | One run in full: what's wrong with it, its details, its subtasks, and the
-- whole chain of reactions it's part of.
runPage :: UUID -> Ctx -> Page
runPage u c = case Map.lookup u c.ix.runs of
  Nothing -> Page "Run not found" $ H.p "Run not found: it may have been pruned."
  Just r -> Page (unTopic r.eid.evtTopic <> " run") $ do
    H.h1 (topicLink r.eid.evtTopic)
    let ps = problemsOf c r
    unless (null ps) $ H.ul ! colour (severity c r) $ forM_ ps $ \(name, why) -> H.li $ H.strong (toHtml name) >> " " >> toHtml why
    H.dl $ do
      field "Label" (toHtml r.start.e.label)
      field "Started" $ toHtml (localTime c r.start.at) >> " (" >> ago c r.start.at >> ")"
      field "Finished" $ case r.end of
        Just e -> toHtml (localTime c e.at)
        Nothing | timedOut c.now r -> "never received"
                | otherwise -> "not yet"
      field "Took" (took c r)
      field "Summary" (H.span ! A.class_ "summary" $ toHtml (summaryOf r))
      forM_ r.start.e.scope $ field "Part of" . eventLink c
      forM_ r.start.e.reactTo $ field "Reacting to" . eventLink c
      field "Correlation id" $ H.code (toHtml (UUID.toText u))
    sequence_ [H.h2 h >> H.pre (pretty v) | (h, Just v) <- [("Rules", Just (toJSON r.start.e.rules)), ("Content", contentOf r), ("Result", r.end >>= (.e.result))]]
    let subtasks = concatMap (chain c 0) (Map.findWithDefault [] u c.ix.scopedTo)
        whole = chain c 0 (rootCause c.ix r)
    table c (Just u) False ([("Subtasks", subtasks) | not (null subtasks)] ++ [("Chain of reactions", whole) | length whole > 1])
  where
    field :: Text -> Html -> Html
    field k v = H.dt (toHtml k) >> H.dd v

-- | A trigger a run announced and hasn't sent yet: what it would send, and
-- the button to send it.
triggerPage :: UUID -> Int -> Ctx -> Page
triggerPage u i c = case Map.lookup u c.ix.runs >>= \r -> (r,) <$> lookup i (pendingTriggers c.ix r) of
  Nothing -> Page "Trigger not found" $ H.p "No such trigger pending: it may have been sent, or its run pruned."
  Just (r, t) -> Page (T.pack t.triggerLabel) $ do
    H.h1 (toHtml t.triggerLabel)
    H.dl $ do
      H.dt "Topic" >> H.dd (topicLink t.triggerTopic)
      H.dt "Announced by" >> H.dd (runLink r (toHtml (unTopic r.eid.evtTopic)) >> " " >> ago c (maybe r.start.at (.at) r.end))
    forM_ t.triggerData $ \v -> H.h2 "Value" >> H.pre (pretty v)
    triggerButton r (i, t)

--------------------------------------------------------------------------------
-- What needs attention

-- | How much a run needs attention, least first.
data Severity = Healthy | Actionable | Crisis
  deriving (Eq, Ord)

severity :: Ctx -> Run -> Severity
severity c r
  | bad c r = if isCritical c.ix r then Crisis else Actionable
  | otherwise = Healthy

needsAttention :: Ctx -> Run -> Bool
needsAttention c r = severity c r >= Actionable

-- | What needs attention, the required topics never seen, and the broker if
-- it's unreachable.
attention :: Ctx -> Int
attention c = length (filter (needsAttention c) (shown c)) + length (missing c) + fromEnum (not c.connected)

-- | The latest run of every event, newest first.
shown :: Ctx -> [Run]
shown c = sortOn (Down . (.start.at)) (latestRuns c.ix)

-- | What needs attention, one line each, but the broker being unreachable,
-- which happens briefly on every wake.
alerts :: Ctx -> [Text]
alerts c = [unTopic r.eid.evtTopic <> ": " <> T.intercalate ", " (map fst (problemsOf c r)) | r <- shown c, needsAttention c r]
  ++ ["no run seen of required " <> unTopic t | t <- missing c]

missing :: Ctx -> [Topic]
missing c = filter (`Map.notMember` c.ix.byTopic) c.required

problemsOf :: Ctx -> Run -> [(Text, Text)]
problemsOf c = problems c.now c.ix

bad :: Ctx -> Run -> Bool
bad c = not . null . problemsOf c

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
-- current run, and with @hist@ the 'history' of each run's topic. A subtask
-- names the run it's part of, unless that's the current run.
table :: Ctx -> Maybe UUID -> Bool -> [(Text, [Row])] -> Html
table c current hist sections = unless (null sections) $ H.table $ do
  H.tr $ mapM_ H.th (["", "Event"] ++ ["History" | hist] ++ ["Problem", "Run", "Took", "Summary", ""])
  forM_ sections $ \(name, rows) -> do
    unless (T.null name) $ H.tr ! A.class_ "section" $ H.th ! A.colspan (if hist then "8" else "7") $ toHtml name
    forM_ rows $ \case
      RunRow d r -> H.tr ! (if current == Just r.eid.correlationId then A.class_ "current" else mempty) $ do
        H.td (marker (severity c r))
        H.td ! A.class_ "topic" ! indent d $ do
          arrow d >> topicLink r.eid.evtTopic
          forM_ r.start.e.scope $ \e -> unless (current == Just e.correlationId) $ H.span ! A.class_ "muted" $ " in " >> eventLink c e
        when hist $ H.td ! A.class_ "history" $ history c r.eid.evtTopic
        H.td $ let ps = problemsOf c r in flag (severity c r) ! A.title (toValue (T.unwords (map snd ps))) $ toHtml (T.intercalate ", " (map fst ps))
        H.td ! A.class_ "time" $ runLink r (ago c r.start.at) >> forM_ r.start.e.rules.expected (\e -> toHtml (" / " <> fmtDuration e))
        H.td ! A.class_ "time" $ took c r
        H.td ! A.class_ "summary" $ toHtml (summaryOf r)
        H.td mempty
      TriggerRow d r t -> H.tr ! A.class_ "pending" $ do
        H.td mempty
        H.td ! A.class_ "topic" ! indent d $ arrow d >> topicLink (snd t).triggerTopic
        when hist $ H.td mempty
        H.td mempty
        H.td ! A.class_ "time" $ "not sent"
        H.td mempty
        H.td ! A.class_ "summary" $ H.a ! A.href (toValue (triggerUrl r (fst t))) $ toHtml (snd t).triggerLabel
        H.td mempty
  where
    indent d = A.style (toValue ("padding-left: " <> tshow (0.5 + 1.5 * fromIntegral d :: Double) <> "em"))
    arrow d = when (d > 0) "↳ "

-- | The last 24 hours of a topic's top-level runs, oldest first, one mark
-- per hour: coloured if a run needed attention, muted if none ran.
history :: Ctx -> Topic -> Html
history c t = forM_ [23, 22 .. 0 :: Int] $ \h ->
  case [r | r <- topLevel c.ix t, let age = diffUTCTime c.now r.start.at, age >= hour h, age < hour (h + 1)] of
    [] -> H.span ! A.class_ "muted" $ "·"
    rs -> flag (maximum (map (severity c) rs)) "▮"
  where hour n = fromIntegral (3600 * n)

-- | Send a trigger the run announced.
triggerButton :: Run -> (Int, Trigger) -> Html
triggerButton r (i, t) = H.form ! A.method "post" ! A.action (toValue (triggerUrl r i))
  ! A.onsubmit (toValue ("return confirm(" <> json (String (T.pack t.triggerLabel <> "?")) <> ")"))
  $ H.button "Send"

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
  Crisis -> "CRITICAL"
  Actionable -> "●"
  Healthy -> mempty

-- | How long a finished run took, or how long an unfinished one has been
-- running. An unfinished run past its timeout isn't running any more.
took :: Ctx -> Run -> Html
took c r = case r.end of
  Just _ -> toHtml (fmtDuration (duration c.now r))
  Nothing -> unless (timedOut c.now r) $ toHtml (fmtDuration (duration c.now r) <> ", running")

summaryOf :: Run -> Text
summaryOf r = foldMap (\e -> T.pack e.e.summary) r.end

-- | The run's content, unless empty.
contentOf :: Run -> Maybe Value
contentOf r = r.start.e.content >>= \v -> v <$ guard (v `notElem` [Null, Object mempty, Array mempty])

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

triggerUrl :: Run -> Int -> Text
triggerUrl r i = runUrl r <> "/trigger/" <> tshow i

-- | A link to an event's run, if it's known.
eventLink :: Ctx -> EventId -> Html
eventLink c e = case Map.lookup e.correlationId c.ix.runs of
  Just p -> runLink p (toHtml (unTopic p.eid.evtTopic))
  Nothing -> H.code (toHtml (unTopic e.evtTopic <> " " <> UUID.toText e.correlationId))

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
