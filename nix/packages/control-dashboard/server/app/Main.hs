{-# LANGUAGE NoFieldSelectors #-}
-- | Listens to everything on the broker through control-events, judges it,
-- and serves the result to the dashboard's windows. See ../protocol.md.
module Main (main) where

import Claude (brief, diagnose)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (race_)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, withMVar)
import Control.Concurrent.STM
import Control.Events (Conn, EventId (..), EvtDone (..), EvtMsg (..), Timed (..), Trigger (..), done, event, evtReactions, newPersistentSession, react, reacted, reactedMany, simple, waitConnDisconnect, withConn, withMsg, withPersistentConn, (&), (.~), (?~))
import Control.Exception (IOException, SomeException, displayException, evaluate, try)
import Control.Monad (forever, mfilter, when)
import Data.Aeson (FromJSON, ToJSON (..), Value (..), decode, decodeStrict, encode, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe)
import qualified Data.Set as Set
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Time (Day, UTCTime, getCurrentTime, getTimeZone, localDay, utcToLocalTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import GHC.Generics (Generic)
import Model
import Network.HTTP.Types (hContentType, status200, status400, status404, status409, status500)
import Network.MQTT.Topic (unTopic)
import Network.Wai (Application, lazyRequestBody, pathInfo, queryString, requestMethod, responseLBS)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Network.Wai.Handler.WebSockets (websocketsOr)
import qualified Network.WebSockets as WS
import Notes (Note (..), scan, ticked)
import System.Directory (createDirectoryIfMissing, doesFileExist, getHomeDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeExtension, (</>))
import System.IO

usage :: String
usage = unlines
  [ "usage: control-dashboard-server [--host HOST] [--port PORT] [--require TOPIC]... [--logs PATTERN] [--notes DIR]... [--claude PATH]"
  , "                                [--session ID | --clean] [--state DIR] [--web DIR]"
  , ""
  , "  --host, --port    where to serve (default: 127.0.0.1:5001)"
  , "  --require TOPIC   a topic that must have runs, e.g. healthcheck/scrollsent"
  , "  --logs PATTERN    where a failed script's log is, %s for the last level of its topic"
  , "  --notes DIR       Markdown and Org notes whose \"- [ ]\" checkboxes to show"
  , "  --claude PATH     the claude CLI, to diagnose runs that went wrong"
  , "  --session ID      the broker session to resume (default: control-dashboard)"
  , "  --clean           no broker session: miss whatever happens while closed"
  , "  --state DIR       history and layout (default: ~/.local/state/control-dashboard)"
  , "  --web DIR         the dashboard for browsers, served at /" ]

data Opts = Opts {host :: String, port :: Int, require :: [Text], logs :: Maybe String, noteDirs :: [FilePath], claude :: Maybe FilePath, session :: Maybe String, state :: FilePath, web :: Maybe FilePath}

opts :: IO Opts
opts = do
  home <- getHomeDirectory
  getArgs >>= go (Opts "127.0.0.1" 5001 [] Nothing [] Nothing (Just "control-dashboard") (home </> ".local/state/control-dashboard") Nothing)
  where
    go o = \case
      [] -> pure o
      "--host" : v : as -> go o {host = v} as
      "--port" : v : as -> go o {port = read v} as
      "--require" : v : as -> go o {require = o.require ++ [T.pack v]} as
      "--logs" : v : as -> go o {logs = Just v} as
      "--notes" : v : as -> go o {noteDirs = o.noteDirs ++ [v]} as
      "--claude" : v : as -> go o {claude = Just v} as
      "--session" : v : as -> go o {session = Just v} as
      "--clean" : as -> go o {session = Nothing} as
      "--state" : v : as -> go o {state = v} as
      "--web" : v : as -> go o {web = Just v} as
      ["-h"] -> hPutStr stderr usage >> exitWith ExitSuccess
      a : _ -> hPutStr stderr ("unknown argument " <> a <> "\n" <> usage) >> exitWith (ExitFailure 2)

-- | What the server knows, besides its options.
data Env = Env
  { st :: TVar State
  , notes :: TVar [(FilePath, Note)]
  , since :: UTCTime
    -- ^ When the history begins.
  , past :: MVar (Maybe (UTCTime, State))
    -- ^ The last state rewound to.
  , asking :: MVar ()
    -- ^ Held while Claude diagnoses a run, so one is asked at a time.
  , writing :: MVar ()
    -- ^ Held while the history file is written to or read.
  }

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  o <- opts
  createDirectoryIfMissing True (o.state </> "diagnoses")
  logged <- loadHistory (historyFile o)
  started <- getCurrentTime
  env <- Env <$> newTVarIO (foldl (flip apply) (fresh o) logged) <*> newTVarIO [] <*> pure (foldr (min . loggedAt) started logged) <*> newMVar Nothing <*> newMVar () <*> newMVar ()
  let record l = do
        withMVar env.writing \_ -> BL8.appendFile (historyFile o) (encode l <> "\n")
        atomically (modifyTVar' env.st (apply l))
  _ <- forkIO (listen o.session env.st record)
  _ <- forkIO (forever (rescan o env >> threadDelay 10_000_000))
  putStrLn ("Serving on http://" <> o.host <> ":" <> show o.port)
  runSettings (setHost (fromString o.host) (setPort o.port defaultSettings)) $
    websocketsOr WS.defaultConnectionOptions (live env) (http o env)

fresh :: Opts -> State
fresh o = State mempty mempty o.require False mempty

historyFile :: Opts -> FilePath
historyFile o = o.state </> "events.jsonl"

-- | Replays the history file, keeping only its recent half, and every todo,
-- once it grows too long.
loadHistory :: FilePath -> IO [Logged]
loadHistory f = do
  ls <- doesFileExist f >>= \e -> if e then B8.lines <$> B8.readFile f else pure []
  let (old, newer) = splitAt (length ls - 100_000) ls
      kept = if length ls > 200_000 then filter todo old ++ newer else ls
      todo l = case decodeStrict @Logged l of Just (Started e _) -> "todo/" `T.isPrefixOf` unTopic e.evtTopic; _ -> False
  when (length kept < length ls) $ B8.writeFile f (B8.unlines kept)
  pure (mapMaybe decodeStrict kept)

-- | What the server would have known at a time: the history up to then.
stateAt :: Opts -> Env -> UTCTime -> IO State
stateAt o env t = modifyMVar env.past \case
  Just (t', s) | t' == t -> pure (Just (t', s), s)
  _ -> do
    ls <- B8.lines <$> withMVar env.writing \_ -> B8.readFile (historyFile o)
    s <- evaluate (setConnected True (foldl' (flip apply) (fresh o) (filter ((<= t) . loggedAt) (mapMaybe decodeStrict ls))))
    pure (Just (t, s), s)

rescan :: Opts -> Env -> IO ()
rescan o env = try @SomeException (scan o.noteDirs) >>= either (hPutStrLn stderr . ("notes: " <>) . displayException) (atomically . writeTVar env.notes)

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

-- | What the windows ask of the todos, as the event it becomes.
data TodoReq = TodoReq {verb :: Text, label :: Maybe Text, item :: Maybe UUID, about :: Maybe Text, when :: Maybe Text}
  deriving (Generic, FromJSON)

-- | The project, label, what it reacts to and content of a todo event. A
-- capture's project is "project/path: " before its text, or what it's about.
todoEvent :: Day -> State -> TodoReq -> Maybe (Text, Text, [EventId], Maybe Value)
todoEvent day s q = case q.verb of
  "capture" | Just l <- label -> let (p, t) = projectOf l in Just (p, t, [], due)
  "when" | Just i <- found, Just _ <- due -> Just (i.project, "", [i.item], due)
  "done" | Just i <- found -> Just (i.project, "", [i.item], Just (toJSON (Change Nothing (Just True))))
  _ -> Nothing
  where
    found = q.item >>= (`Map.lookup` s.todos)
    label = mfilter (not . T.null) (T.strip <$> q.label)
    due = (\h -> toJSON (Change (Just (endOf h day)) Nothing)) <$> case fromMaybe "today" q.when of
      "today" -> Just Today; "week" -> Just Week; "year" -> Just Year; _ -> Nothing
    projectOf l = case T.breakOn ": " l of
      (p, rest) | valid p, not (T.null rest) -> (p, T.strip (T.drop 2 rest))
      _ -> (fromMaybe "general" (mfilter valid q.about), l)
    valid p = not (T.null p) && not (T.any (`elem` [' ', '+', '#']) p) && notElem "" (T.splitOn "/" p)

sendTodo :: (Text, Text, [EventId], Maybe Value) -> IO ()
sendTodo (project, l, rs, c) = withConn "todo" \conn -> event conn (fromString (T.unpack project)) msg \_ -> pure (done "OK" ())
  where msg = simple (T.unpack l) & withMsg .~ c & reactedMany .~ (if null rs then Nothing else Just rs)

-- | The local day at a time.
dayOf :: UTCTime -> IO Day
dayOf t = (\z -> localDay (utcToLocalTime z t)) <$> getTimeZone t

-- * What the windows are shown

data Health = Bad | Waiting | Running | Fine | Unseen
  deriving (Eq, Ord)

instance ToJSON Health where
  toJSON = String . \case Bad -> "bad"; Waiting -> "waiting"; Running -> "running"; Fine -> "fine"; Unseen -> "unseen"

data Item = Item {topic :: Text, status :: Health, last :: Maybe UTCTime, stats :: Maybe Text, problems :: [Text], group :: Maybe Text, recent :: [Tick], content :: Maybe Value, result :: Maybe Value}
  deriving (Generic, ToJSON)

data TodoItem = TodoItem {key :: Text, title :: Text, project :: Text, due :: Day, when :: Text, problems :: [Text]}
  deriving (Generic, ToJSON)

-- | Something that needs you: what's wrong, what waits for you to send a
-- trigger, and what's to do today.
data Attention = Attention {key :: Text, title :: Text, project :: Maybe Text, status :: Health, problems :: [Text], triggers :: [Value]}
  deriving (Generic, ToJSON)

data View = View
  { connected :: Bool
  , status :: Health
  , since :: UTCTime
  , now :: [Attention]
  , machines :: [Item]
  , services :: [Item]
  , nodes :: [Item]
  , ghosts :: [Ghost]
  , links :: [Link]
  , todos :: [TodoItem]
  , notes :: [Note]
  }
  deriving (Generic, ToJSON)

view :: Day -> UTCTime -> UTCTime -> [Note] -> State -> View
view day now since notes st = View st.connected (foldr (min . (.status)) Fine attention) since attention machines services nodes ghosts links todos notes
  where
    machines = listed "system/"
    services = listed "healthcheck/"
    nodes = [(item t) {group = groupOf t} | t <- topics]
    items = machines ++ services ++ nodes
    attention =
      [Attention i.topic i.topic Nothing Bad i.problems [] | i <- items, i.status == Bad]
        ++ [Attention t.key t.title (Just t.project) Bad t.problems [] | t <- todos, not (null t.problems)]
        ++ [Attention i.topic i.topic Nothing Waiting [] (sends i.topic) | i <- items, i.status == Waiting]
        ++ [Attention t.key t.title (Just t.project) Fine [] [] | t <- todos, t.when == "today", null t.problems]
    sends t = [object ["run" .= r.eid.correlationId, "index" .= i, "label" .= trig.triggerLabel] | Just r <- [latest st t], (i, trig) <- pendingTriggers ix r]
    todos = [TodoItem (todoKey i.item.correlationId) i.title i.project i.due (horizonName (horizon day i)) (todoProblems day i) | i <- openTodos st]
    horizonName = \case Today -> "today"; Week -> "week"; Year -> "year"
    -- Topics are grouped by their second level, e.g. script/finances/… and
    -- server/finances/… as "finances", when there's more than one.
    second t = case T.splitOn "/" t of _ : g : _ : _ -> Just g; _ -> Nothing
    groupOf t = second t >>= \g -> if length (filter ((== Just g) . second) topics) > 1 then Just g else Nothing
    ix = index st
    (topics, ghosts, links) = graph st ix
    listed p = map item (filter (p `T.isPrefixOf`) (Set.toList (Set.fromList (Map.keys st.byTopic ++ st.required))))
    item t = case latest st t of
      Nothing | t `elem` st.required -> Item t Bad Nothing Nothing ["Required, but never seen."] Nothing [] Nothing Nothing
              | otherwise -> Item t Unseen Nothing Nothing [] Nothing [] Nothing Nothing
      Just r ->
        let ps = problems now st ix r ++ ["Disk " <> d <> " full." | Just d <- [stat r "diskUsed"], maybe False (>= 90) (readInt d)]
            s | not (null ps) = Bad
              | not (null (pendingTriggers ix r)) = Waiting
              | isNothing r.end = Running
              | otherwise = Fine
         in Item t s (Just r.start.at) (machine r) ps Nothing (recent now st t) r.start.e.content (r.end >>= (.e.result))
    stat r k = case r.start.e.content of
      Just (Object o) -> KM.lookup k o >>= \case String s -> Just s; Number n -> Just (T.pack (show (round n :: Int))); _ -> Nothing
      _ -> Nothing
    machine r = (\l m d -> "load " <> l <> "%  mem " <> m <> "% free  disk " <> d) <$> stat r "loadPct" <*> stat r "memAvailPct" <*> stat r "diskUsed"
    readInt d = case reads (T.unpack (T.dropWhileEnd (== '%') d)) of [(n, "")] -> Just (n :: Int); _ -> Nothing

current :: Env -> IO View
current env = do
  now <- getCurrentTime
  view <$> dayOf now <*> pure now <*> pure env.since <*> (map snd <$> readTVarIO env.notes) <*> readTVarIO env.st

-- | The whole view on connecting, and again whenever it changes: rules
-- about time change it too, so it's looked at every second.
live :: Env -> WS.ServerApp
live env pending = do
  c <- WS.acceptRequest pending
  WS.withPingThread c 30 (pure ()) $
    race_ (forever (WS.receiveDataMessage c)) (go c "")
  where
    go c sent = do
      j <- encode <$> current env
      when (j /= sent) $ WS.sendTextData c j
      before <- fingerprint <$> readTVarIO env.st
      wake <- registerDelay 1_000_000
      atomically $ (readTVar wake >>= check) `orElse` (readTVar env.st >>= check . (/= before) . fingerprint)
      go c j
    fingerprint s = (Map.size s.runs, length (filter (isJust . (.end)) (Map.elems s.runs)), s.connected)

-- * Everything else, over plain HTTP

data Send = Send {run :: UUID, index :: Int}
  deriving (Generic, FromJSON)

data Diagnose = Diagnose {run :: UUID}
  deriving (Generic, FromJSON)

http :: Opts -> Env -> Application
http o env req respond = case (requestMethod req, pathInfo req) of
  ("GET", ["api", "view"]) -> do
    (now, s) <- asked
    d <- dayOf now
    ns <- readTVarIO env.notes
    json (toJSON (view d now env.since (map snd ns) s))
  ("GET", ["api", "topic"]) | Just t <- param "topic" -> do
    (now, s) <- asked
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
  ("POST", ["api", "todo"]) -> do
    body <- lazyRequestBody req
    (d, s) <- (,) <$> (dayOf =<< getCurrentTime) <*> readTVarIO env.st
    case decode body >>= todoEvent d s of
      Just e -> try @SomeException (sendTodo e) >>= either (text status500 . T.pack . displayException) (const (text status200 "Sent"))
      Nothing -> text status400 "Not something to do."
  ("POST", ["api", "note"]) -> do
    body <- lazyRequestBody req
    ns <- readTVarIO env.notes
    case decode @Note body of
      Just n | Just f <- lookup n.file [(m.file, p) | (p, m) <- ns] -> do
        s <- either (const Nothing) Just . T.decodeUtf8' <$> B.readFile f
        case s >>= ticked n.line n.text of
          Just s' -> B.writeFile f (T.encodeUtf8 s') >> rescan o env >> text status200 "Ticked"
          Nothing -> text status409 "The note has changed."
      _ -> text status400 "No such note."
  ("POST", ["api", "diagnose"]) | Just c <- o.claude -> do
    body <- lazyRequestBody req
    (now, s) <- (,) <$> getCurrentTime <*> readTVarIO env.st
    case decode body of
      Just (Diagnose i) | Just r <- Map.lookup i s.runs -> do
        a <- withMVar env.asking \_ -> readMaybe (diagnosisFile i) >>= \case
          Just d -> pure (Right (T.decodeUtf8Lenient (BL8.toStrict d)))
          Nothing -> do
            a <- diagnose c . (\l -> brief now s l r) =<< logOf r
            either (const (pure ())) (B.writeFile (diagnosisFile i) . T.encodeUtf8) a
            pure a
        either (text status500) (text status200) a
      _ -> text status400 "No such run."
  ("GET", ["api", "layout"]) -> respond . responseLBS status200 [(hContentType, "application/json")] . fromMaybe "{}" =<< readMaybe layoutFile
  ("PUT", ["api", "layout"]) -> do
    body <- lazyRequestBody req
    case decode @Value body of
      Just _ -> BL8.writeFile layoutFile body >> text status200 "Saved"
      Nothing -> text status400 "Not JSON."
  -- Only files runs gave as their result, or images in their content, so
  -- this can't read anything else.
  ("GET", ["file"]) | Just p <- param "path" -> do
    s <- readTVarIO env.st
    let given = [f | r <- Map.elems s.runs, Just d <- [r.end], Just (String f) <- [d.e.result]]
          ++ [f | r <- Map.elems s.runs, f <- strings r.start.e.content, T.toLower (T.pack (takeExtension (T.unpack f))) `elem` [".png", ".jpg", ".jpeg"]]
    if p `elem` given
      then readMaybe (T.unpack p) >>= maybe (text status404 "Gone.") (respond . responseLBS status200 [(hContentType, mime (takeExtension (T.unpack p)))])
      else text status404 "Not a result."
  -- The dashboard for browsers: its files, by name, and nothing else.
  ("GET", path) | Just dir <- o.web, all (\p -> not (T.null p) && T.head p /= '.') path -> do
    let name = if null path then "index.html" else T.unpack (T.intercalate "/" path)
    readMaybe (dir </> name) >>= maybe (text status404 "Not found.") (respond . responseLBS status200 [(hContentType, mime (takeExtension name))])
  _ -> text status404 "Not found."
  where
    layoutFile = o.state </> "layout.json"
    diagnosisFile i = o.state </> "diagnoses" </> UUID.toString i <> ".txt"
    param k = T.decodeUtf8 <$> (lookup k (queryString req) >>= id)
    -- Now, or the time asked about, and what the server knew then.
    asked = case param "at" >>= iso8601ParseM . T.unpack of
      Just t -> (t,) <$> stateAt o env t
      Nothing -> (,) <$> getCurrentTime <*> readTVarIO env.st
    json = respond . responseLBS status200 [(hContentType, "application/json")] . encode
    text s = respond . responseLBS s [(hContentType, "text/plain; charset=utf-8")] . BL8.fromStrict . T.encodeUtf8
    readMaybe f = doesFileExist f >>= \e -> if e then Just <$> BL8.readFile f else pure Nothing
    mime = \case ".html" -> "text/html; charset=utf-8"; ".js" -> "text/javascript"; ".wasm" -> "application/wasm"; ".pdf" -> "application/pdf"; ".png" -> "image/png"; ".jpg" -> "image/jpeg"; ".jpeg" -> "image/jpeg"; ".svg" -> "image/svg+xml"; _ -> "application/octet-stream"
    strings = \case
      Just (String t) -> [t]
      Just (Object m) -> concatMap (strings . Just) (toList m)
      Just (Array a) -> concatMap (strings . Just) (toList a)
      _ -> []
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
          statusOf x = let Tick t _ = tick now x in t
      tailOfLog <- if bad r then logOf r else pure Nothing
      diagnosis <- readMaybe (diagnosisFile r.eid.correlationId)
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
        , "diagnosis" .= fmap (T.decodeUtf8Lenient . BL8.toStrict) diagnosis
        , "diagnosable" .= (isJust o.claude && bad r)
        ]
