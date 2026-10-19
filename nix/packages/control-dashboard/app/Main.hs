{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Exception (displayException)
import Control.Monad (forM_, guard, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime, getCurrentTimeZone)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Events
import GHC.Generics (Generic)
import Network.HTTP.Types (hCacheControl, hContentType, notFound404, ok200)
import Network.Wai (pathInfo, responseLBS)
import Network.Wai.Middleware.Gzip (defaultGzipSettings, gzip)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Generic (ParseRecord, getRecord)
import Servant
import Servant.HTML.Blaze (HTML)
import System.IO (BufferMode (..), hSetBuffering, stdout)
import System.Process (callProcess)
import Text.Blaze.Html5 (Html, preEscapedToHtml)
import Views

-- | CLI options, parsed generically from the field names: @--host@,
-- @--port@, @--persistent@ (see 'mqttLoop') with the client id @--session@
-- (by default @control-dashboard@), repeatable @--require TOPIC@
-- and @--link URL@, and
-- @--alert CMD@, run by @sh -c@ with each new thing needing attention as @$1@.
-- For development, @--assets DIR@ serves @graph.html@ and @js/@ from
-- @DIR@ instead of those built in.
--
-- A required topic is a crisis until a run of it is seen.
data Options = Options
  { host :: Maybe String
  , port :: Maybe Int
  , persistent :: Bool
  , session :: Maybe String
  , require :: [String]
  , link :: [Text]
  , alert :: Maybe String
  , assets :: Maybe FilePath
  }
  deriving (Generic)

instance ParseRecord Options

type API =
       Get '[HTML] Html
  :<|> "graph" :> CaptureAll "path" Text :> Get '[HTML] Html
  :<|> "js" :> Raw
  :<|> "api" :> "state" :> QueryParam "hours" Double :> Get '[JSON] Value
  :<|> QueryFlag "live" :>
  (    "list" :> Get '[HTML] Html
  :<|> "topic" :> CaptureAll "topic" Text :> Get '[HTML] Html
  :<|> "run" :> Capture "run" UUID :>
         (    Get '[HTML] Html
         :<|> "trigger" :> Capture "trigger" Int :> Post '[HTML] Html
         )
  )

server :: Options -> State -> Server API
server opts st =
       graph
  :<|> const graph
  :<|> Tagged (\req send -> do
         let f = T.unpack (T.intercalate "/" (pathInfo req))
         js <- maybe (pure (BL.fromStrict <$> lookup f jsFiles)) (\d -> Just <$> BL.readFile (d <> "/js/" <> f)) opts.assets
         send $ maybe (responseLBS notFound404 [] "") (responseLBS ok200 [(hContentType, "text/javascript"), (hCacheControl, "no-cache")]) js)
  :<|> (\h -> liftIO $ (`stateJson` realToFrac (3600 * fromMaybe 6 h)) <$> ctx opts st)
  :<|> \live ->
              view live overviewPage
         :<|> view live . topicPage . fromString . T.unpack . T.intercalate "/"
         :<|> \u -> view live (runPage u) :<|> trigger u
  where
    graph = maybe (pure graphPage) (\d -> liftIO (preEscapedToHtml <$> readFile (d <> "/graph.html"))) opts.assets
    view live f = liftIO $ (\c -> render c live (f c)) <$> ctx opts st
    -- Only triggers a run announced, and not yet sent, can be sent.
    trigger u i = do
      ix <- index <$> liftIO (readTVarIO st.runs)
      case Map.lookup u ix.runs >>= \r -> (r,) <$> lookup i (pendingTriggers ix r) of
        Just (r, t) -> liftIO (trySync (sendTrigger r t))
          >>= either (\e -> throwError err500 {errBody = fromString (displayException e)}) (\v -> redirect ("/run/" <> UUID.toASCIIBytes v))
        Nothing -> throwError err404 {errBody = "That run has no such trigger pending."}
    redirect :: ByteString -> Handler Html
    redirect l = throwError err303 {errHeaders = [("Location", l)]}

ctx :: Options -> State -> IO Ctx
ctx opts st = do
  now <- getCurrentTime
  tz <- getCurrentTimeZone
  atomically $ do
    ix <- index <$> readTVar st.runs
    connected <- readTVar st.connected
    pure Ctx {now, tz, ix, connected, required = map fromString opts.require, links = opts.link}

-- | Run the command for each thing newly needing attention, checking every 5s.
alertLoop :: String -> IO Ctx -> IO ()
alertLoop cmd getCtx = getCtx >>= go . alerts
  where
    go seen = do
      threadDelay 5_000_000
      now <- alerts <$> getCtx
      forM_ (filter (`notElem` seen) now) $ \a ->
        trySync (callProcess "sh" ["-c", cmd, "alert", T.unpack a]) >>= either (putStrLn . ("alert: " <>) . displayException) pure
      go now

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  opts <- getRecord "A trivially simple HTML dashboard server" :: IO Options
  let theHost = fromMaybe "127.0.0.1" opts.host
      thePort = fromMaybe 8080 opts.port
  st <- newState
  void (forkIO (mqttLoop (fromMaybe "control-dashboard" opts.session <$ guard opts.persistent) st))
  forM_ opts.alert $ \cmd -> forkIO (alertLoop cmd (ctx opts st))
  putStrLn $ "Serving on http://" <> theHost <> ":" <> show thePort
  runSettings (setHost (fromString theHost) (setPort thePort defaultSettings)) (gzip defaultGzipSettings (serve (Proxy @API) (server opts st)))
