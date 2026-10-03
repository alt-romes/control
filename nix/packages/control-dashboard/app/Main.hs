{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM_, forever, void)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
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
import Text.Blaze.Html5 (Html)
import Views

-- | CLI options, parsed generically from the field names: @--host@,
-- @--port@, @--persistent@ (see 'mqttLoop'), @--state FILE@ to keep runs
-- across restarts, and repeatable @--require TOPIC@ and @--link HOST@.
--
-- A required topic is a crisis until a run of it is seen.
data Options = Options
  { host :: Maybe String
  , port :: Maybe Int
  , persistent :: Bool
  , state :: Maybe FilePath
  , require :: [String]
  , link :: [String]
  }
  deriving (Generic)

instance ParseRecord Options

type API = QueryFlag "live" :>
  (    Get '[HTML] Html
  :<|> "topic" :> CaptureAll "topic" Text :> Get '[HTML] Html
  :<|> "run" :> Capture "run" UUID :>
         (    Get '[HTML] Html
         :<|> "ack" :> Header "Referer" Text :> Post '[HTML] Html
         :<|> "trigger" :> Capture "trigger" Int :> Post '[HTML] Html
         )
  )

server :: Options -> State -> Server API
server opts st live =
       view overviewPage
  :<|> view . topicPage . fromString . T.unpack . T.intercalate "/"
  :<|> \u -> view (runPage u) :<|> ack u :<|> trigger u
  where
    ack u back = liftIO (atomically (modifyTVar' st.runs (Map.adjust (\r -> r {acked = True}) u))) >> redirect (maybe "/" encodeUtf8 back)
    -- Only triggers a run announced, and not yet sent, can be sent.
    trigger u i = do
      ix <- index <$> liftIO (readTVarIO st.runs)
      case Map.lookup u ix.runs >>= \r -> (r,) <$> lookup i (pendingTriggers ix r) of
        Just (r, t) -> liftIO (try @SomeException (sendTrigger r t))
          >>= either (\e -> throwError err500 {errBody = fromString (displayException e)}) (\v -> redirect ("/run/" <> UUID.toASCIIBytes v))
        Nothing -> throwError err404 {errBody = "That run has no such trigger pending."}
    redirect :: ByteString -> Handler Html
    redirect l = throwError err303 {errHeaders = [("Location", l)]}
    view f = liftIO $ do
      now <- getCurrentTime
      tz <- getCurrentTimeZone
      atomically $ do
        ix <- index <$> readTVar st.runs
        connected <- isJust <$> readTVar st.broker
        let c = Ctx {now, tz, ix, connected, required = map fromString opts.require, links = opts.link}
        pure (render c live (f c))

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  opts <- getRecord "A trivially simple HTML dashboard server" :: IO Options
  let theHost = fromMaybe "127.0.0.1" opts.host
      thePort = fromMaybe 8080 opts.port
  st <- newState
  forM_ opts.state (`load` st)
  void (forkIO (mqttLoop opts.persistent st))
  forM_ opts.state $ \p -> forkIO $ forever $ do
    threadDelay 60_000_000
    try @SomeException (save p st) >>= either (putStrLn . ("save: " <>) . displayException) pure
  putStrLn $ "Serving on http://" <> theHost <> ":" <> show thePort
  runSettings (setHost (fromString theHost) (setPort thePort defaultSettings)) (serve (Proxy @API) (server opts st))
