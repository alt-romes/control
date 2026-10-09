{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM_, void)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
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
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Generic (ParseRecord, getRecord)
import Servant
import Servant.HTML.Blaze (HTML)
import System.IO (BufferMode (..), hSetBuffering, stdout)
import System.Process (callProcess)
import Text.Blaze.Html5 (Html)
import Views

-- | CLI options, parsed generically from the field names: @--host@,
-- @--port@, @--persistent@ (see 'mqttLoop'), repeatable @--require TOPIC@
-- and @--link URL@, and
-- @--alert CMD@, run by @sh -c@ with each new thing needing attention as @$1@.
--
-- A required topic is a crisis until a run of it is seen.
data Options = Options
  { host :: Maybe String
  , port :: Maybe Int
  , persistent :: Bool
  , require :: [String]
  , link :: [Text]
  , alert :: Maybe String
  }
  deriving (Generic)

instance ParseRecord Options

type API = QueryFlag "live" :>
  (    Get '[HTML] Html
  :<|> "topic" :> CaptureAll "topic" Text :> Get '[HTML] Html
  :<|> "run" :> Capture "run" UUID :>
         (    Get '[HTML] Html
         :<|> "trigger" :> Capture "trigger" Int :> (Get '[HTML] Html :<|> Post '[HTML] Html)
         )
  )

server :: Options -> State -> Server API
server opts st live =
       view overviewPage
  :<|> view . topicPage . fromString . T.unpack . T.intercalate "/"
  :<|> \u -> view (runPage u) :<|> \i -> view (triggerPage u i) :<|> trigger u i
  where
    -- Only triggers a run announced, and not yet sent, can be sent.
    trigger u i = do
      ix <- index <$> liftIO (readTVarIO st.runs)
      case Map.lookup u ix.runs >>= \r -> (r,) <$> lookup i (pendingTriggers ix r) of
        Just (r, t) -> liftIO (try @SomeException (sendTrigger r t))
          >>= either (\e -> throwError err500 {errBody = fromString (displayException e)}) (\v -> redirect ("/run/" <> UUID.toASCIIBytes v))
        Nothing -> throwError err404 {errBody = "That run has no such trigger pending."}
    redirect :: ByteString -> Handler Html
    redirect l = throwError err303 {errHeaders = [("Location", l)]}
    view f = liftIO $ (\c -> render c live (f c)) <$> ctx opts st

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
        try @SomeException (callProcess "sh" ["-c", cmd, "alert", T.unpack a]) >>= either (putStrLn . ("alert: " <>) . displayException) pure
      go now

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  opts <- getRecord "A trivially simple HTML dashboard server" :: IO Options
  let theHost = fromMaybe "127.0.0.1" opts.host
      thePort = fromMaybe 8080 opts.port
  st <- newState
  void (forkIO (mqttLoop opts.persistent st))
  forM_ opts.alert $ \cmd -> forkIO (alertLoop cmd (ctx opts st))
  putStrLn $ "Serving on http://" <> theHost <> ":" <> show thePort
  runSettings (setHost (fromString theHost) (setPort thePort defaultSettings)) (serve (Proxy @API) (server opts st))
