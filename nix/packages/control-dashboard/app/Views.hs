{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields, LambdaCase, TemplateHaskell #-}
-- | The dashboard's pages. Pages keep themselves up to date, and count what
-- needs attention in their title.
--
-- Only problems are coloured: a page with nothing wrong has no colour at all.
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
import Data.List (isSuffixOf, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Data.Time (TimeZone, UTCTime, defaultTimeLocale, diffUTCTime, formatTime, utcToLocalTime)
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
  , acked :: Set UUID -- ^ critical failures acknowledged
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
          H.nav $ forM_ links $ \h ->
            H.a ! A.href (toValue ((if ".localhost" `isSuffixOf` h then "http://" else "https://") <> h)) $ toHtml h
        H.main ! customAttribute "hx-get" "?live" ! customAttribute "hx-trigger" "every 5s" ! customAttribute "hx-swap" "innerMorph" $ body
  where
    n = length (filter (bad c) (shown c))
    title = toHtml ((if n == 0 then "" else "(" <> tshow n <> ") ") <> p.title <> " · control-dashboard")
    body = p.body >> H.p (toHtml ("Updated " <> formatTime defaultTimeLocale "%H:%M:%S" (utcToLocalTime c.tz c.now)))
    links = ["alt-romes.github.io", "analytics.mogbit.com", "dashboard.stripe.com", "ledger.localhost", "satisago.localhost"]

--------------------------------------------------------------------------------
-- Pages

-- | What needs attention, then the latest run of every event, by root topic.
overviewPage :: Ctx -> Page
overviewPage c = Page "Overview" $ do
  red (n > 0) $ H.h1 $ if n == 0 then "All clear" else toHtml (tshow n <> " need attention")
  when (any (alarm c) rs) $ red True $ H.h1 "CRITICAL FAILURE"
  unless c.connected $ red True $ H.p "Broker unreachable: this may be stale."
  forM_ (Map.toList (Map.fromListWith (flip (++)) [(take 1 (split r.eid.evtTopic), [r]) | r <- rs])) $ \(root, rs') ->
    H.h2 (foldMap (toHtml . unTopic) root) >> table c rs'
  where
    rs = shown c
    n = length (filter (bad c) rs)

-- | Every run seen on one topic.
topicPage :: Topic -> Ctx -> Page
topicPage t c = Page (unTopic t) $ do
  H.h1 (toHtml (unTopic t))
  case Map.findWithDefault [] t c.ix.byTopic of
    [] -> H.p "No runs seen on this topic yet."
    rs@(latest : _) -> do
      when (isHealthcheck t) $
        H.p "Healthy runs of a healthcheck aren't kept, only its first, its latest, and those with problems."
      when (isNothing latest.start.x.rules.expected) $
        H.p "No expected interval is set, so the dashboard can't tell if this stops running."
      table c rs

-- | One run in full: what's wrong with it, its details, the triggers it
-- announced, and the runs related to it.
runPage :: UUID -> Ctx -> Page
runPage u c = case Map.lookup u c.ix.runs of
  Nothing -> Page "Run not found" $
    H.p "Run not found. The dashboard only knows runs published since it last started."
  Just r -> Page (unTopic r.eid.evtTopic <> " run") $ do
    H.h1 (topicLink r.eid.evtTopic)
    let ps = problems c.now c.ix r
    unless (null ps) $ red True $ H.ul $ forM_ ps $ \(name, why) -> H.li $ H.strong (toHtml name) >> " " >> toHtml why
    H.dl $ do
      field "Label" (toHtml r.start.x.label)
      field "Started" $ toHtml (localTime c r.start.at) >> " (" >> ago c r.start.at >> ")"
      field "Finished" $ case r.end of
        Just e -> toHtml (localTime c e.at)
        Nothing | timedOut c r -> "never received"
                | otherwise -> "not yet"
      field "Took" (took c r)
      field "Summary" (toHtml (summaryOf r))
      field "Timeout" $ toHtml (fmtDuration (fromIntegral r.start.x.rules.timeout))
      field "Expected every" $ maybe "not set" (\d -> toHtml (fmtDuration d <> " (+" <> fmtDuration grace <> " grace)")) r.start.x.rules.expected
      forM_ r.start.x.rules.subtasks $ field "Expected subtasks" . toHtml . T.intercalate ", " . map T.pack
      forM_ r.start.x.rules.reactions $ field "Expected reactions" . toHtml . T.intercalate ", " . map unFilter
      when r.start.x.rules.critical $ field "Critical" $ do
        "yes: any problem is a CRITICAL FAILURE"
        when (u `Set.member` c.acked) " (acknowledged)"
        ackButton c r
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

-- | The latest run of every event, and every unacknowledged critical failure,
-- newest first.
shown :: Ctx -> [Run]
shown c = sortOn (Down . (.start.at)) [r | r <- Map.elems c.ix.runs, alarm c r || r.eid.correlationId `Set.member` latest]
  where latest = Set.fromList (map (.eid.correlationId) (latestRuns c.ix))

bad :: Ctx -> Run -> Bool
bad c = not . null . problems c.now c.ix

-- | A problem with a critical run, not yet acknowledged.
alarm :: Ctx -> Run -> Bool
alarm c r = r.start.x.rules.critical && r.eid.correlationId `Set.notMember` c.acked && bad c r

--------------------------------------------------------------------------------
-- Pieces

-- | Runs as a table. Consecutive runs that differ only in when they ran are
-- shown once, as the first, with how many there were.
table :: Ctx -> [Run] -> Html
table c rs = H.table $ do
  H.tr $ mapM_ H.th ["Problem", "Event", "Run", "Took", "Label", "Summary", ""]
  forM_ (NE.groupWith key rs) $ \g@(r :| _) -> H.tr $ do
    H.td $ H.span ! A.class_ "bad" $ do
      when (alarm c r) (H.strong "CRITICAL ")
      toHtml (T.intercalate ", " (map fst (problems c.now c.ix r)))
    H.td (topicLink r.eid.evtTopic)
    H.td $ runLink r (ago c r.start.at) >> times c (map (.start.at) (NE.toList g))
    H.td (took c r)
    H.td (toHtml r.start.x.label)
    H.td (toHtml (summaryOf r))
    H.td $ ackButton c r >> mapM_ (triggerButton r) (zip [0 ..] (triggersOf r))
  where
    key r = (r.eid.evtTopic, map fst (problems c.now c.ix r), alarm c r, r.start.x.label, summaryOf r)

ackButton :: Ctx -> Run -> Html
ackButton c r = when (alarm c r) $ action r "ack" Nothing "Acknowledge"

-- | Send a trigger the run announced.
triggerButton :: Run -> (Int, Trigger) -> Html
triggerButton r (i, t) = action r ("trigger/" <> tshow i) (Just ("Trigger " <> T.pack t.triggerLabel <> "?")) (toHtml t.triggerLabel)
  ! A.title (toValue (unTopic t.triggerTopic))

-- | A button posting to one of the run's actions, maybe asking first.
action :: Run -> Text -> Maybe Text -> Html -> Html
action r a confirm b = H.form ! A.method "post" ! A.action (toValue (runUrl r <> "/" <> a)) ! A.style "display: inline"
  ! foldMap (\q -> A.onsubmit (toValue ("return confirm(" <> json (String q) <> ")"))) confirm $ H.button b

red :: Bool -> Html -> Html
red b h = if b then h ! A.class_ "bad" else h

-- | How many times, if more than one, listing them on hover.
times :: Ctx -> [UTCTime] -> Html
times c ts = when (length ts > 1) $
  H.span ! A.title (toValue (T.intercalate "\n" (map (localTime c) ts))) $ toHtml (" ×" <> tshow (length ts))

-- | How long a finished run took, or how long an unfinished one has been
-- running. An unfinished run past its timeout isn't running any more.
took :: Ctx -> Run -> Html
took c r = case r.end of
  Just _ -> toHtml (fmtDuration (duration c.now r))
  Nothing -> unless (timedOut c r) $ toHtml (fmtDuration (duration c.now r) <> ", running")

timedOut :: Ctx -> Run -> Bool
timedOut c r = duration c.now r > fromIntegral r.start.x.rules.timeout

summaryOf :: Run -> Text
summaryOf r = foldMap (\e -> T.pack e.x.summary) r.end

-- | The run's content, unless empty.
contentOf :: Run -> Maybe Value
contentOf r = r.start.x.content >>= \v -> v <$ guard (v `notElem` [Null, Object mempty, Array mempty])

ago :: Ctx -> UTCTime -> Html
ago c t = H.span ! A.title (toValue (localTime c t)) $ toHtml (rel <> " ago")
  where
    s = round (diffUTCTime c.now t) :: Integer
    rel | s < 60 = tshow (max 0 s) <> "s"
        | s < 3600 = tshow (s `div` 60) <> "m"
        | s < 86400 = tshow (s `div` 3600) <> "h"
        | otherwise = tshow (s `div` 86400) <> "d"

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
