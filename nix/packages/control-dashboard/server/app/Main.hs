{-# LANGUAGE NoFieldSelectors #-}
-- | Listens to everything on the broker through control-events, judges it,
-- announces what goes wrong, and serves it to the page in web/. See
-- ../protocol.md.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (race_)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Concurrent.STM
import Control.Events (Conn, EventId (..), EvtDone (..), EvtMsg (..), Timed (..), Trigger (..), done, event, evtReactions, newPersistentSession, react, reacted, simple, waitConnDisconnect, withConn, withMsg, withPersistentConn, (&), (.~), (?~))
import Control.Exception (IOException, SomeException, displayException, try)
import Control.Monad (forever, mfilter, unless, void, when)
import Data.Aeson (FromJSON, ToJSON, decode, decodeStrict, encode, object, (.=))
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Time (addUTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)
import Model
import Network.HTTP.Types (hCacheControl, hContentType, status200, status400, status404, status500)
import Network.MQTT.Topic (unTopic)
import Network.Wai (Application, lazyRequestBody, pathInfo, queryString, requestMethod, responseLBS)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Network.Wai.Handler.WebSockets (websocketsOr)
import qualified Network.WebSockets as WS
import System.Directory (createDirectoryIfMissing, doesFileExist, getHomeDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeExtension, (</>))
import System.IO
import Text.Read (readMaybe)
import View

usage :: String
usage = unlines
  [ "usage: control-dashboard-server [--host HOST] [--port PORT] [--require TOPIC]... [--trigger TOPIC]... [--logs PATTERN]"
  , "                                [--session ID | --clean] [--state DIR] [--web DIR]"
  , ""
  , "  --host, --port    where to serve (default: 127.0.0.1:5001)"
  , "  --require TOPIC   a topic that must have runs, e.g. healthcheck/scrollsent"
  , "  --trigger TOPIC   a trigger to offer for sending, e.g. trigger/backup"
  , "  --logs PATTERN    where a failed script's log is, %s for the last level of its topic"
  , "  --session ID      the broker session to resume (default: control-dashboard)"
  , "  --clean           no broker session: miss whatever happens while closed"
  , "  --state DIR       history (default: ~/.local/state/control-dashboard)"
  , "  --web DIR         the page to serve" ]

data Opts = Opts {host :: String, port :: Int, require :: [Text], offered :: [Text], logs :: Maybe String, session :: Maybe String, state :: FilePath, web :: Maybe FilePath}

opts :: IO Opts
opts = do
  home <- getHomeDirectory
  getArgs >>= go (Opts "127.0.0.1" 5001 [] [] Nothing (Just "control-dashboard") (home </> ".local/state/control-dashboard") Nothing)
  where
    go o = \case
      [] -> pure o
      "--host" : v : as -> go o {host = v} as
      "--port" : v : as -> go o {port = read v} as
      "--require" : v : as -> go o {require = o.require ++ [T.pack v]} as
      "--trigger" : v : as -> go o {offered = o.offered ++ [T.pack v]} as
      "--logs" : v : as -> go o {logs = Just v} as
      "--session" : v : as -> go o {session = Just v} as
      "--clean" : as -> go o {session = Nothing} as
      "--state" : v : as -> go o {state = v} as
      "--web" : v : as -> go o {web = Just v} as
      ["-h"] -> hPutStr stderr usage >> exitWith ExitSuccess
      a : _ -> hPutStr stderr ("unknown argument " <> a <> "\n" <> usage) >> exitWith (ExitFailure 2)

-- | What the server knows, besides its options.
data Env = Env
  { st :: TVar State
  , view :: TVar BL8.ByteString
    -- ^ The summary, as it was last judged.
  , record :: Logged -> IO ()
    -- ^ Into the history and the state
  }

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  o <- opts
  createDirectoryIfMissing True o.state
  let historyFile = o.state </> "events.jsonl"
  now <- getCurrentTime
  st <- newTVarIO . foldl (flip apply) (State mempty mempty o.require o.offered False now [] mempty) =<< loadHistory historyFile
  history <- openFile historyFile AppendMode
  lock <- newMVar ()
  let record l = do
        withMVar lock \_ -> BL8.hPut history (encode l <> "\n") >> hFlush history
        atomically (modifyTVar' st (apply l))
  env <- (\v -> Env st v record) <$> newTVarIO ""
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
sendTrigger r t = publish (unTopic t.triggerTopic) (simple t.triggerLabel & withMsg .~ t.triggerData & reacted ?~ r.eid)

-- | Sends a trigger, expecting something to react to it.
publish :: ToJSON m => Text -> EvtMsg m -> IO ()
publish t msg = case T.breakOnEnd "/" t of
  (base, leaf) | T.length base > 1, not (T.null leaf) ->
    withConn (topic (T.init base)) \c -> event c (topic leaf) (msg & evtReactions ?~ ["#"]) \_ -> pure (done "Sent" ())
  _ -> fail ("A trigger's topic needs two levels, unlike " <> show t)
  where
    topic = fromString . T.unpack

-- * Judging

-- | Judges the state whenever it changes, and every second since rules about
-- time change it too. Keeps the summary the windows are sent, and announces
-- each topic going bad, and healthy again, as events of its own.
judge :: Env -> IO ()
judge env = getCurrentTime >>= go Nothing
  where
    go before seen = do
      now <- getCurrentTime
      -- A second that took this long was the computer sleeping.
      when (diffUTCTime now seen > 30) $ atomically (modifyTVar' env.st \s -> s {awake = now, slept = take 100 ((seen, now) : s.slept)})
      s <- readTVarIO env.st
      let is = judged now s
      atomically (writeTVar env.view (encode (summarise s is)))
      let bad = Map.fromList [(i.topic, i) | i <- is, i.status == Bad]
      for_ before \b -> announce (Map.difference bad b) (Map.keys (Map.difference b bad))
      wake <- registerDelay 1_000_000
      atomically $ (readTVar wake >>= check) `orElse` (readTVar env.st >>= check . (/= fingerprint s) . fingerprint)
      go (Just bad) now
    fingerprint s = (Map.size s.runs, length (filter (isJust . (.end)) (Map.elems s.runs)), s.connected, Set.size s.dismissed)

-- | @dashboard/problem/<topic>@ for each topic gone bad, with what's wrong
-- and its run, and @dashboard/healthy/<topic>@ for each that recovered.
announce :: Map Text Item -> [Text] -> IO ()
announce went came = unless (Map.null went && null came) . void . forkIO $ do
  r <- try @SomeException $ withConn "dashboard" \c -> do
    for_ went \i -> say c "problem" i.topic (fromMaybe "Bad." (listToMaybe i.problems)) $ object
      ["topic" .= i.topic, "problems" .= i.problems, "run" .= fmap (.eid.correlationId) i.run]
    for_ came \t -> say c "healthy" t "Healthy again." (object ["topic" .= t])
  either (hPutStrLn stderr . ("announcing: " <>) . displayException) pure r
  where
    say c kind t l v = event c (fromString (T.unpack (kind <> "/" <> t))) (simple (T.unpack l) & withMsg ?~ v) \_ -> pure (done "Announced" ())

-- * What the windows are shown

-- | The summary on connecting, and again whenever it's judged different.
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

data Send = Send {run :: UUID, index :: Int}
  deriving (Generic, FromJSON)

data Fire = Fire {topic :: Text, content :: Maybe Text}
  deriving (Generic, FromJSON)

newtype Dismiss = Dismiss {run :: UUID}
  deriving (Generic)
  deriving anyclass (FromJSON)

http :: Opts -> Env -> Application
http o env req respond = case (requestMethod req, pathInfo req) of
  ("GET", ["api", "status"]) -> json =<< readTVarIO env.view
  ("GET", ["api", "system"]) -> json . encode . (\(now, s) -> system now s (judged now s)) =<< snapshot
  ("GET", ["api", "runs"]) -> do
    (now, s) <- snapshot
    let hours = fromMaybe 6 (readMaybe . T.unpack =<< param "hours") :: Integer
    json (encode (runsSince now s (addUTCTime (fromIntegral (-3600 * hours)) now)))
  ("GET", ["api", "topic"]) | Just t <- param "topic" -> do
    (now, s) <- snapshot
    json . encode . (\l -> topic now s l t) =<< logOf t
  ("POST", ["api", "send"]) -> do
    body <- lazyRequestBody req
    s <- readTVarIO env.st
    case decode body of
      Just (Send i n) | Just r <- Map.lookup i s.runs, not (Set.member i s.dismissed), Just t <- lookup n (pendingTriggers (index s) r) ->
        sent (sendTrigger r t)
      _ -> text status400 "This trigger doesn't wait to be sent: it was sent or dismissed already."
  ("POST", ["api", "trigger"]) -> do
    body <- lazyRequestBody req
    s <- readTVarIO env.st
    case decode body of
      Just (Fire t c) | t `elem` s.triggerable -> sent (publish t (simple "Sent from the dashboard" & withMsg .~ mfilter (not . T.null) c))
      _ -> text status400 "No such trigger."
  ("POST", ["api", "dismiss"]) -> do
    body <- lazyRequestBody req
    s <- readTVarIO env.st
    case decode body of
      Just (Dismiss i) | Map.member i s.runs -> env.record (Dismissed i) >> text status200 "Dismissed"
      _ -> text status400 "No such run."
  ("GET", p) | Just dir <- o.web, not (any ("." `T.isPrefixOf`) p) -> do
    let f = foldl (</>) dir (map T.unpack (if null p then ["index.html"] else p))
    try @IOException (B8.readFile f) >>= either (const (text status404 "Not found.")) (respond . responseLBS status200 [(hContentType, mime f), (hCacheControl, "no-cache")] . BL8.fromStrict)
  _ -> text status404 "Not found."
  where
    param k = T.decodeUtf8 <$> (lookup k (queryString req) >>= id)
    text s = respond . responseLBS s [(hContentType, "text/plain; charset=utf-8")] . BL8.fromStrict . T.encodeUtf8
    json = respond . responseLBS status200 [(hContentType, "application/json")]
    snapshot = (,) <$> getCurrentTime <*> readTVarIO env.st
    sent act = try @SomeException act >>= either (text status500 . T.pack . displayException) (const (text status200 "Sent"))
    mime f = case takeExtension f of
      ".html" -> "text/html; charset=utf-8"
      ".js" -> "text/javascript; charset=utf-8"
      ".css" -> "text/css; charset=utf-8"
      _ -> "application/octet-stream"
    -- Only a log that's there: a missing one says nothing about the run.
    logOf t = case o.logs of
      Just p -> either (const Nothing) (Just . T.unlines . lastN 30 . filter (not . T.null . T.strip) . T.lines)
        <$> try @IOException (T.readFile (T.unpack (T.replace "%s" (last (T.splitOn "/" t)) (T.pack p))))
      Nothing -> pure Nothing
    lastN n xs = drop (length xs - n) xs
