{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields, LambdaCase, TemplateHaskell #-}
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Exception (displayException)
import Control.Monad (forM_, guard, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, decode, decodeStrict, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.FileEmbed (embedDir, embedFile)
import qualified Data.Map.Strict as Map
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Data.Time (defaultTimeLocale, getCurrentTime, parseTimeM)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Control.Events (EventId (..), EvtDone (..), Timed (..))
import Events
import GHC.Generics (Generic)
import Network.MQTT.Topic (unTopic)
import Network.HTTP.Types (hCacheControl, hContentType, notFound404, ok200)
import Network.Wai (pathInfo, queryString, responseLBS)
import Network.Wai.Middleware.Gzip (defaultGzipSettings, gzip)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Generic (ParseRecord, getRecord)
import Servant
import System.FilePath (takeExtension)
import System.IO (BufferMode (..), hSetBuffering, stdout)
import System.Process (callProcess)
import Tree

-- | @--alert CMD@ runs @sh -c CMD@ with each new thing needing attention as @$1@.
-- @--logs PATTERN@ is where a script's log is, with @%s@ for the last level of
-- its topic, e.g. @/tmp/org.romes.%s.err.log@: a failed run shows its end.
-- @--replay FILE@ starts from the messages in FILE, as @mosquitto_sub -F %j@
-- writes them.
data Options = Options
  { host :: Maybe String
  , port :: Maybe Int
  , persistent :: Bool
  , session :: Maybe String
  , require :: [String]
  , alert :: Maybe String
  , logs :: Maybe String
  , replay :: Maybe FilePath
  , assets :: Maybe FilePath
  }
  deriving (Generic)

instance ParseRecord Options

type API =
       "api" :> "graph" :> Get '[JSON] Value
  :<|> "api" :> "runs" :> CaptureAll "topic" Text :> Get '[JSON] Value
  :<|> "run" :> Capture "run" UUID :> "trigger" :> Capture "trigger" Int :> Post '[JSON] NoContent
  :<|> Raw

server :: Options -> State -> Server API
server opts st =
       liftIO (graphJson <$> ctx opts st)
  :<|> (\t -> liftIO ((`runsJson` fromString (T.unpack (T.intercalate "/" t))) <$> ctx opts st))
  :<|> trigger
  :<|> Tagged (\req send -> do
         let reply ty = send . maybe (responseLBS notFound404 [] "") (responseLBS ok200 [(hContentType, ty), (hCacheControl, "no-cache")])
         case pathInfo req of
           ["file"] | Just (Just p) <- lookup "path" (queryString req) -> do
             let f = T.unpack (decodeUtf8Lenient p)
             shown <- files <$> ctx opts st
             body <- if f `elem` shown then either (const Nothing) Just <$> trySync (BL.readFile f) else pure Nothing
             reply (fromMaybe "application/octet-stream" (lookup (takeExtension f) mimes)) body
           "js" : p -> asset ("js/" <> T.unpack (T.intercalate "/" p)) >>= reply "text/javascript"
           _ -> asset "graph.html" >>= reply "text/html; charset=utf-8")
  where
    asset f = maybe (pure (BL.fromStrict <$> lookup f embedded)) (\d -> Just <$> BL.readFile (d <> "/" <> f)) opts.assets
    trigger u i = do
      ix <- index <$> liftIO (readTVarIO st.runs)
      case Map.lookup u ix.runs >>= \r -> (r,) <$> lookup i (pendingTriggers ix r) of
        Just (r, t) -> liftIO (trySync (sendTrigger r t)) >>= \case
          Left e -> throwError err500 {errBody = fromString (displayException e)}
          Right _ -> pure NoContent
        Nothing -> throwError err404 {errBody = "That run has no such trigger pending."}
    mimes = [(".pdf", "application/pdf"), (".png", "image/png"), (".jpg", "image/jpeg"), (".jpeg", "image/jpeg"), (".gif", "image/gif"), (".svg", "image/svg+xml"), (".webp", "image/webp")]

embedded :: [(FilePath, ByteString)]
embedded = ("graph.html", $(embedFile "app/graph.html")) : [("js/" <> f, b) | (f, b) <- $(embedDir "app/js")]

ctx :: Options -> State -> IO Ctx
ctx opts st = do
  now <- getCurrentTime
  (ix, connected, sleeps, wills) <- atomically $ (,,,) <$> (index <$> readTVar st.runs) <*> readTVar st.connected <*> readTVar st.sleeps <*> readTVar st.wills
  let mk logs = Ctx {now, ix, connected, sleeps, required = map fromString opts.require, since = st.bootedAt, wills, logs}
  tails <- sequence
    [ (t,) <$> trySync (BL.readFile (logPath p t))
    | Just p <- [opts.logs]
    , t <- [t | t <- events (mk Map.empty), r : _ <- [Map.findWithDefault [] t ix.byTopic], Just e <- [r.end], not e.e.success]
           -- A healthcheck that stops reporting has no run to fail: its log may say why.
           ++ [t | t <- nub (Map.keys ix.byTopic ++ map fromString opts.require), "healthcheck/" `T.isPrefixOf` unTopic t] ]
  pure (mk (Map.fromList [(t, T.unlines (end (T.lines (decodeUtf8Lenient (BL.toStrict b))))) | (t, Right b) <- tails]))
  where
    logPath p t = T.unpack (T.replace "%s" (last (T.splitOn "/" (unTopic t))) (T.pack p))
    -- Its last lines, each once: a failure repeated each run would fill it otherwise.
    end = reverse . nub . take 40 . reverse . filter (not . T.null . T.strip)

alertLoop :: String -> IO Ctx -> IO ()
alertLoop cmd getCtx = getCtx >>= go . alerts
  where
    go seen = do
      threadDelay 5_000_000
      now <- alerts <$> getCtx
      forM_ (filter (`notElem` seen) now) $ \a ->
        trySync (callProcess "sh" ["-c", cmd, "alert", T.unpack a]) >>= either (putStrLn . ("alert: " <>) . displayException) pure
      go now

replayFile :: State -> FilePath -> IO ()
replayFile st f = do
  ls <- BL.readFile f
  forM_ (BL8.lines ls) $ \l -> do
   forM_ (decode l >>= parseMaybe will) $ \(t, at) -> willed st (fromString (T.unpack t)) at
   forM_ (decode l >>= parseMaybe msg) $ \(t, u, p) ->
    case (splitLast t, UUID.fromText u) of
      (Just (base, "start"), Just i) -> forM_ (decodeStrict (encodeUtf8 p)) (started st (EventId i (fromString (T.unpack base))))
      (Just (base, "finished"), Just i) -> forM_ (decodeStrict (encodeUtf8 p)) (finished st (EventId i (fromString (T.unpack base))))
      _ -> pure ()
  where
    will = withObject "will" $ \o -> do
      t <- o .: "topic"
      guard ("/last-will-testament" `T.isSuffixOf` t)
      tst <- o .: "tst"
      (t,) <$> parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" tst
    msg = withObject "message" $ \o -> (,,) <$> o .: "topic" <*> (o .: "properties" >>= (.: "correlation-data")) <*> o .: "payload"
    splitLast t = let (a, b) = T.breakOnEnd "/" t in if T.null a then Nothing else Just (T.dropEnd 1 a, b)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  opts <- getRecord "A trivially simple HTML dashboard server" :: IO Options
  let theHost = fromMaybe "127.0.0.1" opts.host
      thePort = fromMaybe 8080 opts.port
  st <- newState
  forM_ opts.replay (replayFile st)
  void (forkIO (sleepLoop st))
  void (forkIO (willLoop st))
  void (forkIO (mqttLoop (fromMaybe "control-dashboard" opts.session <$ guard opts.persistent) st))
  forM_ opts.alert $ \cmd -> forkIO (alertLoop cmd (ctx opts st))
  putStrLn $ "Serving on http://" <> theHost <> ":" <> show thePort
  runSettings (setHost (fromString theHost) (setPort thePort defaultSettings)) (gzip defaultGzipSettings (serve (Proxy @API) (server opts st)))
