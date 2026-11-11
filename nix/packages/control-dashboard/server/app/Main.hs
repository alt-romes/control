{-# LANGUAGE NoFieldSelectors #-}
-- | Listens to everything on the broker through control-events, judges it,
-- announces what goes wrong, and serves the result to the dashboard's
-- windows. See ../protocol.md.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (race_)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Concurrent.STM
import Control.Events (Conn, EventId (..), EvtDone (..), EvtMsg (..), Timed (..), Trigger (..), done, event, evtReactions, newPersistentSession, react, reacted, simple, waitConnDisconnect, withConn, withMsg, withPersistentConn, (&), (.~), (?~))
import Control.Exception (IOException, SomeException, displayException, try)
import Control.Monad (forever, unless, void, when)
import Data.Aeson (FromJSON, ToJSON (..), Value (..), decode, decodeStrict, encode, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Foldable (find, for_, traverse_)
import Data.Graph (dfs, graphFromEdges)
import Data.List (groupBy, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Tree (Tree (..))
import Data.UUID (UUID)
import GHC.Generics (Generic)
import Lucid (Html, body_, button_, charset_, class_, content_, div_, doctypehtml_, h2_, head_, httpEquiv_, li_, meta_, name_, onclick_, p_, renderBS, small_, span_, style_, title_, toHtml, ul_)
import Model
import Network.HTTP.Types (hContentType, status200, status400, status404, status500)
import Network.MQTT.Topic (unTopic)
import Network.Wai (Application, lazyRequestBody, pathInfo, queryString, requestMethod, responseLBS)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Network.Wai.Handler.WebSockets (websocketsOr)
import qualified Network.WebSockets as WS
import System.Directory (createDirectoryIfMissing, doesFileExist, getHomeDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO

usage :: String
usage = unlines
  [ "usage: control-dashboard-server [--host HOST] [--port PORT] [--require TOPIC]... [--logs PATTERN]"
  , "                                [--session ID | --clean] [--state DIR]"
  , ""
  , "  --host, --port    where to serve (default: 127.0.0.1:5001)"
  , "  --require TOPIC   a topic that must have runs, e.g. healthcheck/scrollsent"
  , "  --logs PATTERN    where a failed script's log is, %s for the last level of its topic"
  , "  --session ID      the broker session to resume (default: control-dashboard)"
  , "  --clean           no broker session: miss whatever happens while closed"
  , "  --state DIR       history (default: ~/.local/state/control-dashboard)" ]

data Opts = Opts {host :: String, port :: Int, require :: [Text], logs :: Maybe String, session :: Maybe String, state :: FilePath}

opts :: IO Opts
opts = do
  home <- getHomeDirectory
  getArgs >>= go (Opts "127.0.0.1" 5001 [] Nothing (Just "control-dashboard") (home </> ".local/state/control-dashboard"))
  where
    go o = \case
      [] -> pure o
      "--host" : v : as -> go o {host = v} as
      "--port" : v : as -> go o {port = read v} as
      "--require" : v : as -> go o {require = o.require ++ [T.pack v]} as
      "--logs" : v : as -> go o {logs = Just v} as
      "--session" : v : as -> go o {session = Just v} as
      "--clean" : as -> go o {session = Nothing} as
      "--state" : v : as -> go o {state = v} as
      ["-h"] -> hPutStr stderr usage >> exitWith ExitSuccess
      a : _ -> hPutStr stderr ("unknown argument " <> a <> "\n" <> usage) >> exitWith (ExitFailure 2)

-- | What the server knows, besides its options.
data Env = Env
  { st :: TVar State
  , view :: TVar BL8.ByteString
    -- ^ What the windows are sent, as it was last judged.
  }

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  o <- opts
  createDirectoryIfMissing True o.state
  let historyFile = o.state </> "events.jsonl"
  now <- getCurrentTime
  st <- newTVarIO . foldl (flip apply) (State mempty mempty o.require False now) =<< loadHistory historyFile
  history <- openFile historyFile AppendMode
  lock <- newMVar ()
  let record l = do
        withMVar lock \_ -> BL8.hPut history (encode l <> "\n") >> hFlush history
        atomically (modifyTVar' st (apply l))
  env <- Env st <$> newTVarIO ""
  _ <- forkIO (listen o.session st record)
  _ <- forkIO (judge env)
  putStrLn ("Serving on http://" <> o.host <> ":" <> show o.port)
  runSettings (setHost (fromString o.host) (setPort o.port defaultSettings)) $
    websocketsOr WS.defaultConnectionOptions (live env) (http o env)

-- | Replays the history file, keeping only its recent half once it grows too long.
loadHistory :: FilePath -> IO [Logged]
loadHistory f = do
  ls <- doesFileExist f >>= \e -> if e then B8.lines <$> B8.readFile f else pure []
  let kept = if length ls > 200_000 then drop (length ls - 100_000) ls else ls
  when (length kept < length ls) $ B8.writeFile f (B8.unlines kept)
  pure (mapMaybe decodeStrict kept)

-- | With a session, the broker keeps what we miss for a day while we're down.
listen :: Maybe String -> TVar State -> (Logged -> IO ()) -> IO ()
listen session st record = do
  sd <- traverse newPersistentSession session
  forever $ do
    r <- try @SomeException $ maybe (withConn base go) (\s -> withPersistentConn s base go) sd
    atomically $ modifyTVar' st (setConnected False)
    hPutStrLn stderr ("mqtt: " <> either displayException (const "disconnected") r)
    threadDelay 5_000_000
  where
    base = "server/control-dashboard"
    go :: Conn s -> IO ()
    go c = do
      atomically $ modifyTVar' st (setConnected True)
      _ <- react c "#" \e s -> record (Started e s) >> pure (record . Finished e.correlationId)
      waitConnDisconnect c

-- | A trigger is an event of its own, reacting to the run that announced it.
sendTrigger :: Run -> Trigger -> IO ()
sendTrigger r t = case T.breakOnEnd "/" (unTopic t.triggerTopic) of
  (base, leaf) | T.length base > 1, not (T.null leaf) ->
    withConn (topic (T.init base)) \c -> event c (topic leaf) msg \_ -> pure (done "Sent" ())
  _ -> fail ("A trigger's topic needs two levels, unlike " <> show (unTopic t.triggerTopic))
  where
    msg = simple t.triggerLabel & withMsg .~ t.triggerData & reacted ?~ r.eid & evtReactions ?~ ["#"]
    topic = fromString . T.unpack

-- * Judging

-- | Judges the state whenever it changes, and every second since rules about
-- time change it too. Keeps the view the windows are sent, and announces each
-- topic going bad, and healthy again, as events of its own.
judge :: Env -> IO ()
judge env = getCurrentTime >>= go Nothing
  where
    go before seen = do
      now <- getCurrentTime
      -- A second that took this long was the computer sleeping.
      when (diffUTCTime now seen > 30) $ atomically (modifyTVar' env.st \s -> s {awake = now})
      s <- readTVarIO env.st
      let v = view now s
      atomically (writeTVar env.view (encode v))
      let bad = Map.fromList [(i.topic, i) | i <- v.machines ++ v.services ++ v.nodes, i.status == Bad]
      for_ before \b -> announce s (Map.difference bad b) (Map.keys (Map.difference b bad))
      wake <- registerDelay 1_000_000
      atomically $ (readTVar wake >>= check) `orElse` (readTVar env.st >>= check . (/= fingerprint s) . fingerprint)
      go (Just bad) now
    fingerprint s = (Map.size s.runs, length (filter (isJust . (.end)) (Map.elems s.runs)), s.connected)

-- | @dashboard/problem/<topic>@ for each topic gone bad, with what's wrong
-- and its run, and @dashboard/healthy/<topic>@ for each that recovered.
announce :: State -> Map Text Item -> [Text] -> IO ()
announce s went came = unless (Map.null went && null came) . void . forkIO $ do
  r <- try @SomeException $ withConn "dashboard" \c -> do
    for_ went \i -> say c "problem" i.topic (fromMaybe "Bad." (listToMaybe i.problems)) $ object
      ["topic" .= i.topic, "problems" .= i.problems, "run" .= fmap (.eid.correlationId) (latest s i.topic)]
    for_ came \t -> say c "healthy" t "Healthy again." (object ["topic" .= t])
  either (hPutStrLn stderr . ("announcing: " <>) . displayException) pure r
  where
    say c kind t l v = event c (fromString (T.unpack (kind <> "/" <> t))) (simple (T.unpack l) & withMsg ?~ v) \_ -> pure (done "Announced" ())

-- * What the windows are shown

data Item = Item {topic :: Text, status :: Health, last :: Maybe UTCTime, stats :: Maybe Text, problems :: [Text], group :: Maybe Text, recent :: [Tick]}
  deriving (Generic, ToJSON)

-- | Something that needs you: what's wrong, and what waits for you to send a trigger.
data Attention = Attention {key :: Text, status :: Health, problems :: [Text], triggers :: [Sendable]}
  deriving (Generic, ToJSON)

-- | A pending trigger, and what 'Send' needs to send it.
data Sendable = Sendable {run :: UUID, index :: Int, label :: Text}
  deriving (Generic, ToJSON)

-- | What a node's latest run started with, or finished with, as a node under it.
data Said = Said {key :: Text, under :: Text, title :: Text, value :: Value}
  deriving (Generic, ToJSON)

data View = View
  { connected :: Bool
  , status :: Health
  , now :: [Attention]
  , machines :: [Item]
  , services :: [Item]
  , nodes :: [Item]
  , ghosts :: [Ghost]
  , links :: [Link]
  , said :: [Said]
  , places :: Map Text (Int, Int)
  }
  deriving (Generic, ToJSON)

view :: UTCTime -> State -> View
view now st = View st.connected (foldr (min . (.status)) Fine attention) attention machines services nodes ghosts links said places'
  where
    machines = listed "system/"
    services = listed "healthcheck/"
    nodes = [(item t) {group = groupOf t} | t <- topics]
    items = machines ++ services ++ nodes
    attention =
      [Attention i.topic Bad i.problems [] | i <- items, i.status == Bad]
        ++ [Attention i.topic Waiting [] (sends i.topic) | i <- items, i.status == Waiting]
    sends t = [Sendable r.eid.correlationId i (T.pack trig.triggerLabel) | Just r <- [latest st t], (i, trig) <- pendingTriggers ix r]
    said = [Said (t <> "#" <> k) t k v | t <- topics, Just r <- [latest st t], (k, Just v) <- [("content", r.start.e.content), ("result", r.end >>= (.e.result))]]
    -- A block per group, with the ghosts its nodes announce.
    blocks = [map (.topic) ns ++ [g.key | g <- ghosts, g.announcer `elem` map (.topic) ns] | ns <- groupBy (\a b -> a.group == b.group) (sortOn (\i -> (i.group, i.topic)) nodes)]
    places' = places blocks [(l.from, l.to) | l <- links] [(s.under, s.key) | s <- said]
    -- Topics are grouped by their second level, e.g. script/finances/… and
    -- server/finances/… as "finances", when there's more than one.
    second t = case T.splitOn "/" t of _ : g : _ : _ -> Just g; _ -> Nothing
    groupOf t = second t >>= \g -> if length (filter ((== Just g) . second) topics) > 1 then Just g else Nothing
    ix = index st
    (topics, ghosts, links) = graph st ix
    listed p = map item (filter (p `T.isPrefixOf`) (Set.toList (Set.fromList (Map.keys st.byTopic ++ st.required))))
    item t = case latest st t of
      Nothing | t `elem` st.required -> Item t Bad Nothing Nothing ["Required, but never seen."] Nothing []
              | otherwise -> Item t Unseen Nothing Nothing [] Nothing []
      Just r ->
        let ps = problems now st ix r ++ ["Disk " <> d <> " full." | Just d <- [stat r "diskUsed"], maybe False (>= 90) (readInt d)]
            s | not (null ps) = Bad
              | not (null (pendingTriggers ix r)) = Waiting
              | isNothing r.end = Running
              | otherwise = Fine
         in Item t s (Just r.start.at) (machine r) ps Nothing (recent now st t)
    stat r k = case r.start.e.content of
      Just (Object o) -> KM.lookup k o >>= \case String s -> Just s; Number n -> Just (T.pack (show (round n :: Int))); _ -> Nothing
      _ -> Nothing
    machine r = (\l m d -> "load " <> l <> "%  mem " <> m <> "% free  disk " <> d) <$> stat r "loadPct" <*> stat r "memAvailPct" <*> stat r "diskUsed"
    readInt d = case reads (T.unpack (T.dropWhileEnd (== '%') d)) of [(n, "")] -> Just (n :: Int); _ -> Nothing

-- | The view on connecting, and again whenever it's judged different.
live :: Env -> WS.ServerApp
live env pending = do
  c <- WS.acceptRequest pending
  WS.withPingThread c 30 (pure ()) $
    race_ (forever (WS.receiveDataMessage c)) (go c "")
  where
    go c sent = do
      j <- atomically do
        j <- readTVar env.view
        j <$ check (j /= sent && not (BL8.null j))
      WS.sendTextData c j
      go c j

-- * Everything else, over plain HTTP

data Send = Send {run :: UUID, index :: Int}
  deriving (Generic, FromJSON)

http :: Opts -> Env -> Application
http o env req respond = case (requestMethod req, pathInfo req) of
  ("GET", ["api", "topic"]) | Just t <- param "topic" -> do
    (now, s) <- (,) <$> getCurrentTime <*> readTVarIO env.st
    let ix = index s
    rs <- traverse (details now s ix) (take 20 (mapMaybe (`Map.lookup` s.runs) (Map.findWithDefault [] t s.byTopic)))
    json (toJSON rs)
  ("POST", ["api", "send"]) -> do
    body <- lazyRequestBody req
    s <- readTVarIO env.st
    case decode body of
      Just (Send i n) | Just r <- Map.lookup i s.runs, Just t <- lookup n (zip [0 ..] (foldMap (fromMaybe [] . (.e.triggers)) r.end)) ->
        try @SomeException (sendTrigger r t) >>= either (\e -> text status500 (T.pack (displayException e))) (const (text status200 "Sent"))
      _ -> text status400 "No such trigger."
  ("GET", []) -> do
    (now, s) <- (,) <$> getCurrentTime <*> readTVarIO env.st
    respond (responseLBS status200 [(hContentType, "text/html; charset=utf-8")] (renderBS (page now (view now s))))
  _ -> text status404 "Not found."
  where
    param k = T.decodeUtf8 <$> (lookup k (queryString req) >>= id)
    json = respond . responseLBS status200 [(hContentType, "application/json")] . encode
    text s = respond . responseLBS s [(hContentType, "text/plain; charset=utf-8")] . BL8.fromStrict . T.encodeUtf8
    -- Only a log that's there: a missing one says nothing about the run.
    logOf r = case o.logs of
      Just p -> either (const Nothing) (Just . T.unlines . lastN 30 . filter (not . T.null . T.strip) . T.lines)
        <$> try @IOException (T.readFile (T.unpack (T.replace "%s" (last (T.splitOn "/" (topicOf r))) (T.pack p))))
      Nothing -> pure Nothing
    lastN n xs = drop (length xs - n) xs
    details now s ix r = do
      let bad c = not (null (problems now s ix c))
          said d = object ["summary" .= d.e.summary, "success" .= d.e.success, "result" .= d.e.result]
          chain = trace s ix r
          statusOf x = let Tick h _ = tick now x in h
      tailOfLog <- if bad r then logOf r else pure Nothing
      pure $ object
        [ "id" .= r.eid.correlationId
        , "label" .= r.start.e.label
        , "content" .= r.start.e.content
        , "start" .= r.start.at
        , "end" .= fmap (.at) r.end
        , "took" .= duration now r
        , "problems" .= problems now s ix r
        , "said" .= fmap said r.end
        , "subtasks" .= [object ["topic" .= topicOf c, "problems" .= problems now s ix c, "said" .= fmap said c.end] | c <- Map.findWithDefault [] r.eid.correlationId ix.children, bad c]
        , "triggers" .= [object ["index" .= i, "label" .= t.triggerLabel] | (i, t) <- pendingTriggers ix r]
        , "log" .= tailOfLog
        , "trace" .= if length chain < 2 then [] else
            [object ["id" .= x.eid.correlationId, "topic" .= topicOf x, "label" .= x.start.e.label, "start" .= x.start.at, "end" .= fmap (.at) x.end, "depth" .= d, "status" .= statusOf x] | (d, x) <- chain]
        ]

-- * The page for browsers

-- | The view as one page: the graph as an indented list, each node followed
-- by what its links lead to.
page :: UTCTime -> View -> Html ()
page now v = doctypehtml_ do
  head_ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    meta_ [httpEquiv_ "refresh", content_ "5"]
    title_ "Control"
    style_ css
  body_ do
    unless v.connected (p_ [class_ "bad"] "The server can't reach the broker.")
    h2_ "Now"
    when (null v.now) (p_ [class_ "dim"] "Nothing needs you.")
    ul_ $ for_ v.now \a -> li_ do
      span_ [class_ (cls a.status)] (toHtml a.key)
      for_ a.triggers \t -> sendButton t.run t.index t.label
      traverse_ (div_ . toHtml) a.problems
    h2_ "Events"
    ul_ (traverse_ tree forest)
    h2_ "Machines"
    ul_ (traverse_ (li_ . item) v.machines)
    h2_ "Healthchecks"
    ul_ (traverse_ (li_ . item) v.services)
  where
    css :: Text
    css = "body{font:15px/1.5 system-ui;max-width:50em;margin:auto;padding:1em;overflow-wrap:anywhere}:root{color-scheme:light dark}\
          \ul{list-style:none;padding-left:1.2em}body>ul{padding:0}small,.dim{opacity:.6}button{margin-left:.5em}\
          \.bad{color:#d33}.waiting{color:#b80}.running{color:#48c}"
    cls :: Health -> Text
    cls = T.toLower . T.pack . show
    item :: Item -> Html ()
    item i = do
      span_ [class_ (cls i.status)] (toHtml i.topic)
      small_ (toHtml (maybe "" (" " <>) i.stats <> maybe " never seen" (\t -> " " <> fmtDuration (diffUTCTime now t) <> " ago") i.last))
      for_ i.problems (div_ [class_ "bad"] . toHtml)
    -- Each node once: under the first that links to it, or by itself.
    keys = map (.topic) v.nodes ++ map (.key) v.ghosts
    (graph', fromVertex, toVertex) = graphFromEdges [(k, k, [l.to | l <- v.links, l.from == k]) | k <- keys]
    forest = dfs graph' (mapMaybe toVertex (filter (`notElem` map (.to) v.links) keys ++ keys))
    tree :: Tree Int -> Html ()
    tree (Node n kids) = li_ do
      let (k, _, _) = fromVertex n
      case find ((== k) . (.topic)) v.nodes of
        Just i -> item i
        -- A ghost: what a pending trigger, or a run's rules, expect to happen.
        Nothing -> do
          span_ [class_ "dim"] (toHtml (maybe k (.title) (find ((== k) . (.key)) v.ghosts)))
          for_ (find ((== k) . (.to)) v.links) \l -> for_ ((,) <$> l.send <*> l.label) \((r, i), label) -> sendButton r i label
      unless (null kids) (ul_ (traverse_ tree kids))

sendButton :: UUID -> Int -> Text -> Html ()
sendButton r i label = button_ [onclick_ ("fetch('/api/send',{method:'POST',body:'" <> body <> "'}).then(()=>location.reload())")] (toHtml label)
  where body = T.decodeUtf8 (BL8.toStrict (encode (object ["run" .= r, "index" .= i])))
