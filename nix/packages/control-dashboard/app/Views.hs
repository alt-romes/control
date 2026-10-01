{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields, LambdaCase, TemplateHaskell #-}
-- | The dashboard's pages. Live pages keep themselves up to date, and each
-- page counts what needs attention in its title.
--
-- Only problems are coloured: a page with nothing wrong has no colour at all.
module Views
  ( Ctx (..), Page, render
  , overviewPage, topicPage, runPage, triggersPage, triggerPage
  ) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..))
import Control.Monad (forM_, guard, unless, when)
import Data.Aeson (Value (..), encode)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as BL
import Data.FileEmbed (embedStringFile)
import Data.List (isSuffixOf, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing, listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Data.Time (Day, TimeZone, UTCTime, defaultTimeLocale, diffDays, diffUTCTime, formatTime, localDay, utcToLocalTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Events
import Network.HTTP.Types (urlEncode)
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
  , lost :: Map Text UTCTime -- ^ connections that dropped, by service topic
  , reconciled :: [(String, Maybe Day)] -- ^ when each journal was last reconciled
  , acked :: Set UUID -- ^ critical failures acknowledged
  }

data Page = Page {title :: Text, live :: Bool, body :: Html}

-- | The whole page, or with @live@ just its title and body. A live page
-- fetches itself every 5s and morphs in the result, whose title keeps the
-- count of what needs attention current.
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
          H.nav $ (H.a ! A.href "/" $ "Overview") >> (H.a ! A.href "/triggers" $ "Triggers")
          H.nav $ forM_ links $ \h ->
            H.a ! A.href (toValue ((if ".localhost" `isSuffixOf` h then "http://" else "https://") <> h)) $ toHtml h
        if p.live
          then H.main ! customAttribute "hx-get" "?live" ! customAttribute "hx-trigger" "every 5s" ! customAttribute "hx-swap" "innerMorph" $ body
          else H.main body
  where
    n = attention c
    title = toHtml ((if n == 0 then "" else "(" <> tshow n <> ") ") <> p.title <> " · control-dashboard")
    body = p.body >> when p.live (H.p (toHtml ("Updated " <> formatTime defaultTimeLocale "%H:%M:%S" (utcToLocalTime c.tz c.now))))
    links = ["alt-romes.github.io", "analytics.mogbit.com", "dashboard.stripe.com", "ledger.localhost", "satisago.localhost"]

--------------------------------------------------------------------------------
-- Pages

-- | What needs attention, then the latest run of every event and of every
-- healthcheck, and the finances.
overviewPage :: Ctx -> Page
overviewPage c = Page "Overview" True $ do
  red (n > 0) $ H.h1 $ if n == 0 then "All clear" else toHtml (tshow n <> " need attention")
  when (any (.critical) rs) $ red True $ H.h1 "CRITICAL FAILURE"
  unless c.connected $ red True $ H.p "Broker unreachable: this may be stale."
  section ["script", "server"]
  H.h2 "Healthchecks"
  section ["healthcheck"]
  unless (null c.reconciled) $ do
    H.h2 $ H.a ! A.href "http://ledger.localhost" $ "Finances"
    H.ul $ forM_ c.reconciled $ \(name, d) -> red (stale c d) $ H.li $ toHtml $
      name <> ": " <> maybe "last reconciled date unknown" (\d' -> show (daysSince c d') <> " days since last reconciled") d
  where
    rs = rows c
    n = attention c
    section roots = table c [r | r <- rs, T.takeWhile (/= '/') r.topic `elem` roots]

-- | Every run seen on one topic.
topicPage :: Text -> Ctx -> Page
topicPage t c = Page t True $ do
  H.h1 (toHtml t)
  case Map.findWithDefault [] t c.ix.byTopic of
    [] -> H.p "No runs seen on this topic yet."
    rs@((_, latest) : _) -> do
      when (isNothing latest.start.x.rules.expected) $
        H.p "No expected interval is set, so the dashboard can't tell if this stops running."
      table c (map (runRow c) rs)

-- | One run in full: what's wrong with it, its details, content and subtasks.
runPage :: UUID -> Ctx -> Page
runPage u c = case Map.lookup u c.ix.runs of
  Nothing -> Page "Run not found" False $
    H.p "Run not found. The dashboard only knows runs published since it last started."
  Just r -> Page (r.topic <> " run") True $ do
    H.h1 (topicLink r.topic)
    let ps = problems c.now c.ix (u, r)
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
      forM_ r.start.x.rules.subtasks $ \ts -> field "Expected subtasks" $ toHtml (T.intercalate ", " (map T.pack ts))
      when r.start.x.rules.critical $ field "Critical" $ do
        "yes: any problem is a CRITICAL FAILURE"
        when (u `Set.member` c.acked) " (acknowledged)"
        ackButton c (u, r)
      forM_ r.start.x.scope $ \p -> field "Part of" $ case Map.lookup p.correlationId c.ix.runs of
        Just parent -> runLink p.correlationId (toHtml parent.topic)
        Nothing -> H.code (toHtml (UUID.toText p.correlationId))
      field "Correlation id" $ H.code (toHtml (UUID.toText u))
    forM_ (contentOf r) $ \v -> H.h2 "Content" >> H.pre (pretty v)
    forM_ (r.end >>= (.x.result)) $ \v -> H.h2 "Result" >> H.pre (pretty v)
    unless (null (subtasksOf c u)) $ H.h2 "Subtasks" >> table c (map (runRow c) (subtasksOf c u))
  where
    field :: Text -> Html -> Html
    field k v = H.dt (toHtml k) >> H.dd v

-- | The triggers seen on the broker, from anywhere, with the runs the latest
-- of each caused: by convention, a service handling a trigger scopes its run
-- to it. Identical triggers are shown once, with how many were sent.
triggersPage :: Ctx -> Page
triggersPage c = Page "Triggers" True $ do
  H.h1 "Triggers"
  H.p (H.a ! A.href "/trigger" $ "New trigger")
  H.table $ do
    H.tr $ mapM_ H.th ["Sent", "Topic", "Label", "Content", "Caused", ""]
    forM_ (sortOn (Down . (.start.at) . snd . NE.head . snd) (Map.toList (sent c))) $ \(t, g@((u, r) :| _)) -> H.tr $ do
      H.td $ runLink u (ago c r.start.at) >> times c [x.start.at | (_, x) <- NE.toList g]
      H.td (toHtml t.topic)
      H.td (toHtml t.label)
      H.td (H.code (toHtml t.content))
      H.td $ forM_ (subtasksOf c u) $ \ur@(cu, cr) -> H.div $ runLink cu (toHtml cr.topic) >> " " >> flag (runRow c ur)
      H.td $ do
        resend t (H.form ! A.action "/trigger") "Edit"
        " "
        resend t (H.form ! A.method "post" ! A.action "/trigger" ! A.onsubmit "return confirm('Publish again?')") "Send again"
  where
    resend t form b = form ! A.style "display: inline" $ do
      forM_ [("topic", t.topic), ("label", t.label), ("content", t.content)] $ \(k, v) ->
        H.input ! A.type_ "hidden" ! A.name k ! A.value (toValue v)
      H.button b

-- | A form to publish a trigger, prefilled, with why the last attempt failed.
triggerPage :: Trigger -> Maybe Text -> Ctx -> Page
triggerPage t err c = Page "New trigger" False $ do
  H.h1 "New trigger"
  H.p "Publish a control-events message for the services listening on trigger/<topic>."
  forM_ err $ red True . H.p . toHtml
  H.form ! A.method "post" ! A.action "/trigger" $ do
    H.label $ do
      "Topic"
      H.span ! A.class_ "prefixed" $ do
        "trigger/"
        H.input ! A.name "topic" ! A.value (toValue t.topic) ! A.required "" ! A.list "topics" ! A.placeholder "finances/fetch"
    H.label $ "Label" >> H.input ! A.name "label" ! A.value (toValue t.label) ! A.placeholder "What this is for"
    H.label $ "Content (JSON, optional)" >> (H.textarea ! A.name "content" ! A.rows "6" ! A.placeholder "{\"daysBack\": 7}" $ toHtml t.content)
    H.button "Publish"
  H.datalist ! A.id "topics" $ forM_ (Set.fromList (map (.topic) (Map.keys (sent c)))) $ \tp ->
    H.option ! A.value (toValue tp) $ mempty

-- | Every trigger sent, by what was sent, newest first.
sent :: Ctx -> Map Trigger (NonEmpty (UUID, Run))
sent c = Map.fromListWith (flip (<>))
  [ (Trigger tp (T.pack r.start.x.label) (foldMap (decodeUtf8Lenient . BL.toStrict . encode) (contentOf r)), pure ur)
  | (t, rs) <- Map.toList c.ix.byTopic, Just tp <- [T.stripPrefix "trigger/" t], ur@(_, r) <- rs, topLevel c.ix r ]

--------------------------------------------------------------------------------
-- What needs attention

-- | A line in a table of runs: a run, or something wrong with a topic that
-- has no run to show for it.
data Row = Row
  { topic :: Text
  , run :: Maybe (UUID, Run)
  , at :: Maybe UTCTime
  , critical :: Bool
  , issues :: [Text]
  , summary :: Text
  }

runRow :: Ctx -> (UUID, Run) -> Row
runRow c ur@(u, r) = Row r.topic (Just ur) (Just r.start.at) crit (map fst ps) (summaryOf r)
  where
    ps = problems c.now c.ix ur
    crit = r.start.x.rules.critical && u `Set.notMember` c.acked && not (null ps)

-- | Lost connections, required healthchecks missing, unacknowledged critical
-- failures and the latest run of every event: anything never seen first, then
-- newest first.
rows :: Ctx -> [Row]
rows c = sortOn (fmap Down . (.at)) $
     [Row svc Nothing (Just t) False ["connection lost"] "A client dropped without disconnecting." | (svc, t) <- Map.toList c.lost]
  ++ [Row t ur ((.start.at) . snd <$> ur) True ["missing"] "A required healthcheck isn't running." | (t, ur) <- missing]
  ++ [row | ur@(u, r) <- Map.toList c.ix.runs, r.topic `notElem` map fst missing, let row = runRow c ur, row.critical || u `Set.member` latest]
  where
    latest = Set.fromList (map fst (latestRuns c.ix))
    missing = [(t, ur) | t <- requiredHealthchecks, let ur = listToMaybe (Map.findWithDefault [] t c.ix.byTopic), all (isBad . runRow c) ur]

-- | Healthchecks that must always be running: missing one is a CRITICAL
-- FAILURE.
requiredHealthchecks :: [Text]
requiredHealthchecks = ["healthcheck/kanjideck/fulfillment-server", "healthcheck/scrollsent"]

-- | How many things need attention: rows with problems and journals not
-- reconciled in a month.
attention :: Ctx -> Int
attention c = length (filter isBad (rows c)) + length (filter (stale c . snd) c.reconciled)

isBad :: Row -> Bool
isBad = not . null . (.issues)

stale :: Ctx -> Maybe Day -> Bool
stale c = maybe True ((> 31) . daysSince c)

daysSince :: Ctx -> Day -> Integer
daysSince c = diffDays (localDay (utcToLocalTime c.tz c.now))

--------------------------------------------------------------------------------
-- Pieces

-- | Rows as a table. Consecutive rows that differ only in when they ran are
-- shown once, as the first, with how many there were.
table :: Ctx -> [Row] -> Html
table c rs = H.table $ do
  H.tr $ mapM_ H.th ["Problem", "Event", "Run", "Took", "Label", "Summary", ""]
  forM_ (NE.groupWith (\r -> (r.topic, r.critical, r.issues, label r, r.summary)) rs) $ \g@(r :| _) -> H.tr $ do
    H.td (flag r)
    H.td (topicLink r.topic)
    H.td $ maybe id (runLink . fst) r.run (foldMap (ago c) r.at) >> times c (mapMaybe (.at) (NE.toList g))
    H.td $ foldMap (took c . snd) r.run
    H.td $ toHtml (label r)
    H.td $ toHtml r.summary
    H.td $ foldMap (ackButton c) r.run
  where
    label r = foldMap (T.pack . (.start.x.label) . snd) r.run

-- | What's wrong, in red, or nothing.
flag :: Row -> Html
flag r = H.span ! A.class_ "bad" $ unless (null r.issues) $
  when r.critical (H.strong "CRITICAL ") >> toHtml (T.intercalate ", " r.issues)

ackButton :: Ctx -> (UUID, Run) -> Html
ackButton c ur@(u, _) = when (runRow c ur).critical $
  H.form ! A.method "post" ! A.action (toValue ("/ack/" <> UUID.toText u)) ! A.style "display: inline" $ H.button "Acknowledge"

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

subtasksOf :: Ctx -> UUID -> [(UUID, Run)]
subtasksOf c u = Map.findWithDefault [] u c.ix.subtasks

topicLink :: Text -> Html
topicLink t = H.a ! A.href (toValue ("/topic/" <> T.intercalate "/" (map enc (T.splitOn "/" t)))) $ toHtml t
  where enc = decodeUtf8Lenient . urlEncode True . encodeUtf8

runLink :: UUID -> Html -> Html
runLink u = H.a ! A.href (toValue ("/run/" <> UUID.toText u))

-- | Strings as they are (e.g. exception details), anything else as JSON.
pretty :: Value -> Html
pretty = \case
  String t -> toHtml t
  v -> toHtml (decodeUtf8Lenient (BL.toStrict (encodePretty v)))

tshow :: Show a => a -> Text
tshow = T.pack . show
