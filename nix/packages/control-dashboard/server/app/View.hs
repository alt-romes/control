{-# LANGUAGE NoFieldSelectors #-}
-- | The dashboard as a page: what needs the user, what can be sent and how
-- every topic has been doing; and a topic's runs.
module View (Item (..), Summary (..), judged, summarise, page, overview, topicView) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Timed (..), Trigger (..))
import Control.Monad (unless, when)
import Data.Aeson (Key, ToJSON, Value (..), encode, object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (for_)
import Data.Graph (dfs, graphFromEdges)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time (UTCTime, diffUTCTime)
import Data.Tree (Tree (..))
import qualified Data.UUID as UUID
import GHC.Generics (Generic)
import Lucid hiding (for_)
import Lucid.Base (makeAttribute)
import Model
import Network.HTTP.Types (urlEncode)
import Network.MQTT.Topic (unTopic)

-- | A topic as its latest run leaves it, unless that run was dismissed.
data Item = Item {topic :: Text, run :: Maybe Run, status :: Health, problems :: [Text], sends :: [(Int, Trigger)]}

-- | All a status line needs.
data Summary = Summary {connected :: Bool, status :: Health, bad :: Int, waiting :: Int}
  deriving (Generic, ToJSON)

-- | Every topic with a row of its own: machines, services and events.
judged :: UTCTime -> State -> [Item]
judged now st = map item (Set.toList (Set.fromList (filter listed (Map.keys st.byTopic ++ st.required) ++ fst (graph st))))
  where
    ix = index st
    listed t = any (`T.isPrefixOf` t) ["system/", "healthcheck/"]
    item t = case latest st t of
      Nothing
        | t `elem` st.required -> Item t Nothing Bad ["Required, but never seen."] []
        | otherwise -> Item t Nothing Unseen [] []
      Just r ->
        let quiet = Set.member r.eid.correlationId st.dismissed
            ps = if quiet then [] else problems now st ix r ++ ["Disk " <> tshow d <> "% full." | Just d <- [percent r "diskUsed"], d >= 90]
            sends = if quiet then [] else pendingTriggers ix r
            s | not (null ps) = Bad
              | not (null sends) = Waiting
              | isNothing r.end = Running
              | otherwise = Fine
         in Item t (Just r) s ps sends

-- | A percentage a machine reports about itself.
percent :: Run -> Key -> Maybe Int
percent r k = case r.start.e.content of
  Just (Object o) -> KM.lookup k o >>= \case
    String s | [(n, "")] <- reads (T.unpack (T.dropWhileEnd (== '%') s)) -> Just n
    Number n -> Just (round n)
    _ -> Nothing
  _ -> Nothing

summarise :: State -> [Item] -> Summary
summarise st is = Summary st.connected (minimum (Fine : [Waiting | waiting > 0] ++ [Bad | bad > 0])) bad waiting
  where
    bad = length [() | i <- is, i.status == Bad]
    waiting = length [() | i <- is, _ <- i.sends]

-- | Around the overview or a topic's runs. The tab's title and icon say how
-- things are, and the page keeps itself fresh: see 'js'.
page :: Summary -> Maybe Text -> Html () -> Html ()
page s here content = doctypehtml_ do
  head_ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    title_ (toHtml (count "!" s.bad <> count "?" s.waiting <> "Control"))
    link_ [rel_ "icon", href_ ("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Ccircle cx='8' cy='8' r='6' fill='%23" <> dot <> "'/%3E%3C/svg%3E")]
    style_ css
    script_ js
  body_ do
    header_ do
      a_ [href_ "/"] "Control"
      for_ here \t -> span_ [class_ "dim"] "/" >> toHtml t
      unless s.connected (span_ [class_ "bad"] "The server can't reach the broker.")
    main_ content
  where
    count mark n = if n > 0 then mark <> tshow n <> " " else ""
    dot = case s.status of Bad -> "d33"; Waiting -> "b80"; _ -> "888" :: Text

overview :: UTCTime -> State -> [Item] -> Html ()
overview now st is = do
  section "Needs you" "Nothing." (map problem (filter ((== Bad) . (.status)) is) ++ [waiting i r s | i <- is, Just r <- [i.run], s <- i.sends])
  unless (null st.triggerable) (section "Triggers" "" (map offered st.triggerable))
  section "Machines" "No machines." [row (link i.topic (T.drop 7 i.topic)) i (foldMap gauges i.run) | i <- under "system/"]
  section "Services" "No services." [row (link i.topic (T.drop 12 i.topic)) i mempty | i <- under "healthcheck/"]
  section "Events" "No events." events
  where
    ix = index st
    section :: Text -> Text -> [Html ()] -> Html ()
    section title none rows = h2_ (toHtml title) >> if null rows then p_ [class_ "dim"] (toHtml none) else table_ (sequence_ rows)
    under p = filter ((p `T.isPrefixOf`) . (.topic)) is
    problem :: Item -> Html ()
    problem i = tr_ [class_ "bad"] do
      td_ (link i.topic i.topic >> ul_ (for_ i.problems (li_ . toHtml)))
      td_ (for_ i.run dismiss)
    waiting :: Item -> Run -> (Int, Trigger) -> Html ()
    waiting i r s = tr_ [class_ "waiting"] do
      td_ (toHtml (snd s).triggerLabel >> span_ [class_ "dim"] " from " >> link i.topic i.topic)
      td_ (send r s >> dismiss r)
    offered :: Text -> Html ()
    offered t = tr_ do
      td_ (link t t)
      td_ (post "/api/trigger" (object ["topic" .= t]) (Just ("Send " <> t <> "?")) "Send" (input_ [name_ "content", placeholder_ "message, if any"]))
      td_ [class_ "dim"] (toHtml (maybe "never sent" (ago now) (latest st t)))
    -- A topic, its last 30 runs and when the latest was.
    row :: Html () -> Item -> Html () -> Html ()
    row name i extra = tr_ [class_ (cls i.status)] do
      td_ name
      td_ (span_ [class_ "strip"] (for_ (reverse (take 30 (runsOf st i.topic))) mark))
      td_ [class_ "dim"] (toHtml (maybe "never seen" (ago now) i.run))
      extra
    mark, gauges :: Run -> Html ()
    mark r = let Tick h _ = tick now r in a_ [class_ (cls h), href_ (runHref r), title_ (T.pack r.start.e.label <> ", " <> ago now r <> took now r)] ""
    gauges r = for_ [("load", percent r "loadPct"), ("memory", (100 -) <$> percent r "memAvailPct"), ("disk", percent r "diskUsed")] \(name, v) ->
      for_ v \n -> td_ [class_ "dim"] do
        toHtml (name :: Text)
        meter_ [value_ (tshow n), max_ "100", makeAttribute "high" "85", title_ (tshow n <> "%")] ""
    -- The events as trees, each once, under what its latest run reacted to.
    (topics, links) = graph st
    items = Map.fromList [(i.topic, i) | i <- is]
    (graph', fromVertex, toVertex) = graphFromEdges [(k, k, [b | (a, b, _) <- links, a == k]) | k <- topics]
    events = concatMap (tree 0 Nothing) (dfs graph' (mapMaybe toVertex (filter (`notElem` [b | (_, b, _) <- links]) topics ++ topics)))
    tree depth parent (Node n kids) =
      let (k, _, _) = fromVertex n
          i = items Map.! k
          via = listToMaybe [l | (a, b, Just l) <- links, Just a == parent, b == k]
       in row (nest depth (foldMap arrow via >> link k k)) i mempty : concatMap (tree (depth + 1) (Just k)) kids ++ ghosts (depth + 1) i
    arrow :: Text -> Html ()
    arrow l = span_ [class_ "dim"] (toHtml (l <> " → "))
    -- What hasn't happened yet: the reaction to each unsent trigger, and the reactions a run's rules still expect.
    ghosts :: Int -> Item -> [Html ()]
    ghosts depth i =
      [ tr_ [class_ "waiting"] do
          td_ (nest depth (arrow (T.pack (snd s).triggerLabel) >> toHtml (reactor (unTopic (snd s).triggerTopic))))
          td_ (send r s >> dismiss r)
      | Just r <- [i.run], s <- i.sends ]
        ++ [ tr_ [class_ "dim"] (td_ (nest depth (toHtml f)) >> td_ "expected")
           | Just r <- [i.run], not (Set.member r.eid.correlationId st.dismissed), f <- awaitedReactions ix r ]
    -- What reacted to a trigger before, if anything did.
    reactor t = fromMaybe t (listToMaybe [topicOf x | x <- Map.elems st.runs, p <- fromMaybe [] x.start.e.reactTo, unTopic p.evtTopic == t])

-- | A topic's last 20 runs, newest first and open. Given the end of its log,
-- if there is one.
topicView :: UTCTime -> State -> Maybe Text -> Text -> Html ()
topicView now st logTail t = do
  when (null runs) (p_ [class_ "dim"] "No runs.")
  for_ (zip (True : repeat False) runs) \(newest, r) -> do
    let quiet = Set.member r.eid.correlationId st.dismissed
        ps = if quiet then [] else problems now st ix r
        sends = if quiet then [] else pendingTriggers ix r
        h = if quiet then Fine else if null ps then health r else Bad
    details_ ([id_ ("r" <> short r), class_ (cls h)] ++ [makeAttribute "open" "" | newest]) do
      summary_ (toHtml r.start.e.label >> span_ [class_ "dim"] (toHtml ("  " <> ago now r <> took now r)))
      unless (null ps) (ul_ (for_ ps (li_ . toHtml)))
      for_ sends \s -> p_ [class_ "waiting"] (toHtml (snd s).triggerLabel >> " " >> send r s)
      for_ r.end \d -> when (d.e.success && not (null d.e.summary)) (p_ (toHtml (firstLine (T.pack d.e.summary))))
      for_ r.start.e.content (said "content")
      for_ (r.end >>= (.e.result)) (said "result")
      when (newest && not (null ps)) (for_ logTail (pre_ . toHtml))
      waterfall (trace st ix r)
      when (newest && not (null ps && null sends)) (p_ (dismiss r))
  where
    ix = index st
    runs = take 20 (runsOf st t)
    health r = let Tick h _ = tick now r in h
    -- Text as it reads, anything else as JSON, laid out.
    said :: Text -> Value -> Html ()
    said k v = p_ [class_ "dim"] (toHtml k) >> pre_ (toHtml (case v of String s -> s; _ -> T.decodeUtf8 (BL.toStrict (encodePretty v))))
    -- The chain a run is part of, each run with a bar for when it ran in the
    -- chain's time; a chain longer than ten minutes says how long after its
    -- start each run began instead.
    waterfall :: [(Int, Run)] -> Html ()
    waterfall chain = unless (length chain < 2) $ table_ [class_ "chain"] $ for_ chain \(d, x) -> tr_ [class_ (cls (health x))] do
      let t0 = minimum [y.start.at | (_, y) <- chain]
          over = diffUTCTime (maximum [maybe now (.at) y.end | (_, y) <- chain]) t0
          bars = over > 0 && over <= 600
          cell at = floor (realToFrac (diffUTCTime at t0) / realToFrac over * 100 :: Double) :: Int
          a = min 99 (cell x.start.at)
      td_ (nest d (a_ [href_ (runHref x)] (toHtml (topicOf x))))
      when bars (td_ (div_ [style_ ("margin-left:" <> tshow a <> "%;width:" <> tshow (max 1 (cell (maybe now (.at) x.end) - a)) <> "%")] ""))
      td_ [class_ "dim"] (toHtml ((if bars || x.start.at == t0 then "" else "+" <> fmtDuration (diffUTCTime x.start.at t0)) <> took now x))

-- | A button that POSTs the body, with the form's @content@ if any is typed,
-- after asking if there's something to ask.
post :: Text -> Value -> Maybe Text -> Text -> Html () -> Html ()
post to body ask label input =
  form_ ([data_ "post" to, data_ "body" (json body)] ++ [data_ "ask" a | Just a <- [ask]]) (input >> button_ (toHtml label))

send :: Run -> (Int, Trigger) -> Html ()
send r (n, trig) = post "/api/send" (object ["run" .= r.eid.correlationId, "index" .= n])
  (Just ("Send “" <> T.pack trig.triggerLabel <> "” for " <> topicOf r <> "?")) "Send" mempty

dismiss :: Run -> Html ()
dismiss r = post "/api/dismiss" (object ["run" .= r.eid.correlationId]) Nothing "Dismiss" mempty

link :: Text -> Text -> Html ()
link t name = a_ [href_ (topicHref t)] (toHtml name)

topicHref :: Text -> Text
topicHref t = "/?topic=" <> T.decodeUtf8 (urlEncode True (T.encodeUtf8 t))

runHref :: Run -> Text
runHref r = topicHref (topicOf r) <> "#r" <> short r

-- | Under whatever is a level less deep.
nest :: Int -> Html () -> Html ()
nest d h = if d == 0 then h else span_ [style_ ("padding-left:" <> tshow (2 * (d - 1)) <> "em")] ("↳ " >> h)

runsOf :: State -> Text -> [Run]
runsOf st t = mapMaybe (`Map.lookup` st.runs) (Map.findWithDefault [] t st.byTopic)

short :: Run -> Text
short r = T.take 8 (UUID.toText r.eid.correlationId)

ago :: UTCTime -> Run -> Text
ago now r
  | isNothing r.end = "running for " <> fmtDuration (diffUTCTime now r.start.at)
  | otherwise = fmtDuration (diffUTCTime now r.start.at) <> " ago"

took :: UTCTime -> Run -> Text
took now r = foldMap (const ("  took " <> fmtDuration (duration now r))) r.end

cls :: Health -> Text
cls = T.toLower . tshow

json :: ToJSON a => a -> Text
json = T.decodeUtf8 . BL.toStrict . encode

tshow :: Show a => a -> Text
tshow = T.pack . show

css :: Text
css = ":root{color-scheme:light dark}\
      \body{font:15px/1.5 system-ui,sans-serif;max-width:64rem;margin:auto;padding:1rem}body.stale{opacity:.4}\
      \header{display:flex;gap:.5em;font-weight:600}a{color:inherit;text-decoration:none}a:hover{text-decoration:underline}\
      \h2{font-size:.8rem;text-transform:uppercase;letter-spacing:.05em;opacity:.6;margin:2rem 0 .3rem}\
      \table{border-collapse:collapse}td{padding:.15rem 1.5rem .15rem 0;vertical-align:top;white-space:nowrap}td:first-child{white-space:normal;min-width:24rem}\
      \ul{margin:0;padding-left:1.2em}p{margin:.3em 0}form{display:inline}button,input{font:inherit;margin-right:.4em}meter{width:4em;margin-left:.4em}\
      \pre{white-space:pre-wrap;overflow-wrap:anywhere;margin:.3em 0;font-size:.9em}\
      \details{padding:.2rem 0}summary{cursor:pointer}details>:not(summary){margin-left:1.2rem}\
      \.dim{opacity:.6}.bad{color:#d33}.waiting{color:#b80}.running{color:#48c}\
      \.strip{display:inline-flex;align-items:flex-end;justify-content:flex-end;gap:1px;width:150px;height:1.1em}\
      \.strip a{width:4px;height:25%;background:currentColor;opacity:.35}.strip a:hover{opacity:1}\
      \.strip .bad{height:100%;opacity:1;background:#d33}.strip .running{height:60%;opacity:1;background:#48c}\
      \.chain td:nth-child(2){width:16rem}.chain div{height:.6em;margin-top:.45em;min-width:2px;border-radius:2px;background:currentColor}"

-- | A form POSTs what it says. The page is fetched again every 5 seconds and
-- whenever the server says things changed, unless something is being typed
-- or selected, keeping which runs are open.
js :: Text
js = "async function refresh(force){\
     \if(!force&&(getSelection().toString()||[...document.querySelectorAll('input')].some(i=>i.value||i==document.activeElement)))return;\
     \try{const r=await fetch(location.href);if(!r.ok)throw r;\
     \const d=new DOMParser().parseFromString(await r.text(),'text/html'),o={};\
     \document.querySelectorAll('details').forEach(x=>o[x.id]=x.open);\
     \document.body.replaceWith(d.body);\
     \document.querySelectorAll('details').forEach(x=>{if(x.id in o)x.open=o[x.id]});\
     \document.title=d.title;document.querySelector('link').href=d.querySelector('link').href\
     \}catch(e){document.body.className='stale';document.title='✕ Control'}}\
     \addEventListener('submit',async e=>{e.preventDefault();\
     \const f=e.target,b=JSON.parse(f.dataset.body),c=f.elements.content;\
     \if(c&&c.value)b.content=c.value;\
     \if(f.dataset.ask&&!confirm(f.dataset.ask+(b.content?' With: '+b.content:'')))return;\
     \const r=await fetch(f.dataset.post,{method:'POST',body:JSON.stringify(b)});\
     \if(r.ok){if(c)c.value='';refresh(true)}else alert(await r.text())});\
     \addEventListener('DOMContentLoaded',()=>{const h=document.getElementById(location.hash.slice(1));if(h)h.open=true});\
     \setInterval(refresh,5000);\
     \(function live(){const s=new WebSocket(location.origin.replace('http','ws'));s.onmessage=()=>refresh();s.onclose=()=>setTimeout(live,5000)})()"
