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
import Data.Aeson (Value (..), encode)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as BL
import Data.FileEmbed (embedStringFile)
import Data.List (isSuffixOf, partition, sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing, listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Data.Time (NominalDiffTime, TimeZone, UTCTime, defaultTimeLocale, diffUTCTime, formatTime, utcToLocalTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Events
import Network.HTTP.Types (urlEncode)
import Network.MQTT.Topic (Topic, split, unFilter, unTopic)
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
  , acked :: Set UUID -- ^ runs whose problems are acknowledged
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
-- @<cmd>/<name>/...@.
overviewPage :: Ctx -> Page
overviewPage c = Page "Overview" $ do
  unless c.connected $ H.h1 $ flag Crisis "Broker unreachable: this may be stale"
  H.h1 $ flag (maximum (Healthy : map (severity c) flagged)) $
    if null flagged then "All clear" else toHtml (tshow (length flagged) <> " need attention")
  H.p $ toHtml $ tshow (length latest - unmonitored) <> " monitored · " <> tshow unmonitored <> " unmonitored"
  unless (null flagged) $ overview c (sortOn (\r -> (Down (severity c r), fst (failingSince c r))) flagged)
  forM_ (Map.toList (Map.fromListWith (flip (++)) [(take 1 (drop 1 (split r.eid.evtTopic)), [r]) | r <- rest])) $ \(name, rs) ->
    H.h2 (foldMap (toHtml . unTopic) name) >> overview c rs
  where
    (flagged, rest) = partition (needsAttention c) (shown c)
    latest = latestRuns c.ix
    unmonitored = length (filter ((== Unmonitored) . severity c) latest)

-- | Every run seen on one topic.
topicPage :: Topic -> Ctx -> Page
topicPage t c = Page (unTopic t) $ do
  H.h1 (toHtml (unTopic t))
  case Map.findWithDefault [] t c.ix.byTopic of
    [] -> H.p "No runs seen on this topic yet."
    rs@(latest : _) -> do
      when (isNothing latest.start.x.rules.expected) $
        H.p "No expected interval is set, so the dashboard can't tell if this stops running."
      H.p "Healthy runs in a row are kept as one, with how many there were."
      table c rs

-- | One run in full: what's wrong with it, its details, the triggers it
-- announced, and the runs related to it.
runPage :: UUID -> Ctx -> Page
runPage u c = case Map.lookup u c.ix.runs of
  Nothing -> Page "Run not found" $
    H.p "Run not found. Healthy runs in a row are kept as one, so it may have been folded into an earlier run."
  Just r -> Page (unTopic r.eid.evtTopic <> " run") $ do
    H.h1 (topicLink r.eid.evtTopic)
    let ps = problems c.now c.ix r
    unless (null ps) $ H.div ! colour (severity c r) $ do
      H.ul $ forM_ ps $ \(name, why) -> H.li $ H.strong (toHtml name) >> " " >> toHtml why
      if u `Set.member` c.acked then "Acknowledged." else ackButton c r
    H.dl $ do
      field "Label" (toHtml r.start.x.label)
      field "Started" $ toHtml (localTime c r.start.at) >> " (" >> ago c r.start.at >> ")"
      forM_ r.folded $ \(n, at) -> field "Followed by" $
        toHtml (tshow n <> " healthy runs, the last at " <> localTime c at) >> " (" >> ago c at >> ")"
      field "Finished" $ case r.end of
        Just e -> toHtml (localTime c e.at)
        Nothing | timedOut c r -> "never received"
                | otherwise -> "not yet"
      field "Took" $ took c r >> foldMap (\d -> toHtml (" (typically " <> fmtDuration d <> ")")) (typical c r.eid.evtTopic)
      field "Summary" (toHtml (summaryOf r))
      field "Timeout" $ toHtml (fmtDuration (fromIntegral r.start.x.rules.timeout))
      field "Expected every" $ maybe "not set" (\d -> toHtml (fmtDuration d <> " (+" <> fmtDuration grace <> " grace)")) r.start.x.rules.expected
      forM_ r.start.x.rules.subtasks $ field "Expected subtasks" . toHtml . T.intercalate ", " . map T.pack
      forM_ r.start.x.rules.reactions $ field "Expected reactions" . toHtml . T.intercalate ", " . map unFilter
      when r.start.x.rules.critical $ field "Critical" "yes: any problem is a crisis until acknowledged"
      forM_ r.start.x.scope $ field "Part of" . eventLink
      forM_ r.start.x.reactTo $ field "Reacting to" . eventLink
      field "Correlation id" $ H.code (toHtml (UUID.toText u))
    forM_ (contentOf r) $ \v -> H.h2 "Content" >> H.pre (pretty v)
    forM_ (r.end >>= (.x.result)) $ \v -> H.h2 "Result" >> H.pre (pretty v)
    unless (null (triggersOf r)) $ do
      H.h2 "Triggers"
      H.table $ do
        H.tr $ mapM_ H.th ["Topic", "Content", ""]
        forM_ (zip [0 ..] (triggersOf r)) $ \(i, t) -> H.tr $ do
          H.td (topicLink t.triggerTopic)
          H.td $ forM_ t.triggerData (H.code . toHtml . json)
          H.td (triggerButton r (i, t))
    forM_ (Map.lookup u c.ix.scopedTo) $ \rs -> H.h2 "Subtasks" >> table c rs
    forM_ (Map.lookup u c.ix.reactingTo) $ \rs -> H.h2 "Reactions" >> table c rs
  where
    field :: Text -> Html -> Html
    field k v = H.dt (toHtml k) >> H.dd v
    eventLink e = case Map.lookup e.correlationId c.ix.runs of
      Just p -> runLink p (toHtml (unTopic p.eid.evtTopic))
      Nothing -> H.code (toHtml (unTopic e.evtTopic <> " " <> UUID.toText e.correlationId))

--------------------------------------------------------------------------------
-- What needs attention

-- | How much a run needs attention, least first. A run without an expected
-- interval is unmonitored: if it stops running, nothing can tell.
data Severity = Healthy | Unmonitored | Actionable | Crisis
  deriving (Eq, Ord)

severity :: Ctx -> Run -> Severity
severity c r
  | bad c r && r.eid.correlationId `Set.notMember` c.acked = if r.start.x.rules.critical then Crisis else Actionable
  | isNothing r.start.x.rules.expected = Unmonitored
  | otherwise = Healthy

needsAttention :: Ctx -> Run -> Bool
needsAttention c r = severity c r >= Actionable

-- | What needs attention, and the broker if it's unreachable.
attention :: Ctx -> Int
attention c = length (filter (needsAttention c) (shown c)) + fromEnum (not c.connected)

-- | The latest run of every event, and every crisis, newest first.
shown :: Ctx -> [Run]
shown c = sortOn (Down . (.start.at)) [r | r <- Map.elems c.ix.runs, severity c r == Crisis || r.eid.correlationId `Set.member` latest]
  where latest = Set.fromList (map (.eid.correlationId) (latestRuns c.ix))

bad :: Ctx -> Run -> Bool
bad c = not . null . problems c.now c.ix

-- | Since when the run's topic has had problems in a row, up to the run, and
-- in how many runs.
failingSince :: Ctx -> Run -> (UTCTime, Int)
failingSince c r = (maybe r.start.at (.start.at) (listToMaybe (reverse streak)), length streak)
  where streak = takeWhile (bad c) (dropWhile ((/= r.eid.correlationId) . (.eid.correlationId)) (topLevel c.ix r.eid.evtTopic))

--------------------------------------------------------------------------------
-- Pieces

-- | The latest state of topics: what's wrong and since when, the latest run
-- against the expected interval, and the topic's recent history.
overview :: Ctx -> [Run] -> Html
overview c rs = H.table $ do
  H.tr $ mapM_ H.th ["", "Event", "Problem", "Last run", "History", ""]
  forM_ rs $ \r -> H.tr $ do
    H.td (marker (severity c r))
    H.td (topicLink r.eid.evtTopic)
    H.td $ flag (severity c r) $ unless (null (problems c.now c.ix r)) $ do
      toHtml (T.intercalate " " (map snd (problems c.now c.ix r)))
      let (since, n) = failingSince c r
      when (n > 1) $ toHtml (" Since " <> localTime c since <> ", " <> tshow n <> " runs.")
      when (r.eid.correlationId `Set.member` c.acked) " (acknowledged)"
    H.td $ runLink r (ago c (lastStart r)) >> forM_ r.start.x.rules.expected (\d -> toHtml (" / " <> fmtDuration d))
    H.td (history c r.eid.evtTopic)
    H.td (actions c r)

-- | Runs as a table. Consecutive runs that differ only in when they ran are
-- shown once, as the first, with how many there were.
table :: Ctx -> [Run] -> Html
table c rs = H.table $ do
  H.tr $ mapM_ H.th ["", "Problem", "Event", "Run", "Took", "Label", "Summary", ""]
  forM_ (NE.groupWith key rs) $ \g@(r :| _) -> H.tr $ do
    H.td (marker (severity c r))
    H.td $ flag (severity c r) $ toHtml (T.intercalate ", " (map fst (problems c.now c.ix r)))
    H.td (topicLink r.eid.evtTopic)
    H.td $ runLink r (ago c r.start.at) >> times c (NE.toList g)
    H.td (took c r)
    H.td (toHtml r.start.x.label)
    H.td (toHtml (summaryOf r))
    H.td (actions c r)
  where
    key r = (r.eid.evtTopic, map fst (problems c.now c.ix r), severity c r, r.start.x.label, summaryOf r)

-- | The latest top-level runs of a topic, oldest first, a mark each.
history :: Ctx -> Topic -> Html
history c t = H.span ! A.class_ "history" $ forM_ (reverse (take 20 (topLevel c.ix t))) $ \r ->
  runLink r mempty
    ! A.class_ ("tick" <> (if bad c r then " bad" else "") <> (if isNothing r.folded then "" else " folded"))
    ! A.title (toValue (T.unwords (localTime c r.start.at : foldMap (\(n, _) -> ["and " <> tshow n <> " more"]) r.folded ++ map fst (problems c.now c.ix r))))

actions :: Ctx -> Run -> Html
actions c r = ackButton c r >> mapM_ (triggerButton r) (zip [0 ..] (triggersOf r))

ackButton :: Ctx -> Run -> Html
ackButton c r = when (needsAttention c r) $ action r "ack" Nothing "Acknowledge"

-- | Send a trigger the run announced.
triggerButton :: Run -> (Int, Trigger) -> Html
triggerButton r (i, t) = action r ("trigger/" <> tshow i) (Just ("Trigger " <> T.pack t.triggerLabel <> "?")) (toHtml t.triggerLabel)
  ! A.title (toValue (unTopic t.triggerTopic))

-- | A button posting to one of the run's actions, maybe asking first.
action :: Run -> Text -> Maybe Text -> Html -> Html
action r a confirm b = H.form ! A.method "post" ! A.action (toValue (runUrl r <> "/" <> a)) ! A.style "display: inline"
  ! foldMap (\q -> A.onsubmit (toValue ("return confirm(" <> json (String q) <> ")"))) confirm $ H.button b

flag :: Severity -> Html -> Html
flag s = H.span ! colour s

colour :: Severity -> H.Attribute
colour = \case
  Crisis -> A.class_ "crisis"
  Actionable -> A.class_ "bad"
  Unmonitored -> A.class_ "quiet"
  Healthy -> mempty

marker :: Severity -> Html
marker = \case
  Crisis -> flag Crisis "◆"
  Actionable -> flag Actionable "●"
  Unmonitored -> flag Unmonitored "○" ! A.title "No expected interval: nothing can tell if this stops running"
  Healthy -> mempty

-- | How many runs, if more than one, listing them on hover.
times :: Ctx -> [Run] -> Html
times c rs = when (n > 1) $
  H.span ! A.title (toValue (T.intercalate "\n" (concatMap when' rs))) $ toHtml (" ×" <> tshow n)
  where
    n = sum [1 + maybe 0 fst r.folded | r <- rs]
    when' r = localTime c r.start.at : foldMap (\(k, at) -> ["and " <> tshow k <> " more until " <> localTime c at]) r.folded

-- | How long a finished run took, or how long an unfinished one has been
-- running. An unfinished run past its timeout isn't running any more.
took :: Ctx -> Run -> Html
took c r = case r.end of
  Just _ -> toHtml (fmtDuration (duration c.now r))
  Nothing -> unless (timedOut c r) $ toHtml (fmtDuration (duration c.now r) <> ", running")

-- | The median time the latest finished top-level runs of a topic took, if
-- there are a few.
typical :: Ctx -> Topic -> Maybe NominalDiffTime
typical c t = case sort (mapMaybe (\r -> duration c.now r <$ r.end) (take 20 (topLevel c.ix t))) of
  ds | length ds >= 3 -> Just (ds !! (length ds `div` 2))
  _ -> Nothing

timedOut :: Ctx -> Run -> Bool
timedOut c r = duration c.now r > fromIntegral r.start.x.rules.timeout

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
