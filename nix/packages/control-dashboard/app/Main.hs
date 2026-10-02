{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeException, displayException, try)
import Control.Events (EventId (..), done, evtCritical, evtExpected, simple, (&), (.~), (?~))
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (getCurrentTime, getCurrentTimeZone)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Events
import Finances
import GHC.Generics (Generic)
import Network.MQTT.Topic (Topic)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Generic (ParseRecord, getRecord)
import Servant
import Servant.HTML.Blaze (HTML)
import System.IO (BufferMode (..), hSetBuffering, stdout)
import Text.Blaze.Html5 (Html)
import Views

-- | CLI options, parsed generically from the field names: @--host@, @--port@,
-- repeatable @--journal NAME=PATH@ and @--persistent@ (see 'mqttLoop').
data Options = Options
  { host :: Maybe String
  , port :: Maybe Int
  , journal :: [String]
  , persistent :: Bool
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

server :: State -> Server API
server st live =
       view overviewPage
  :<|> view . topicPage . fromString . T.unpack . T.intercalate "/"
  :<|> \u -> view (runPage u) :<|> ack u :<|> trigger u
  where
    ack u back = liftIO (atomically (modifyTVar' st.acked (Set.insert u))) >> redirect (maybe "/" encodeUtf8 back)
    -- Only triggers a run announced can be sent.
    trigger u i = do
      runs <- liftIO (readTVarIO st.runs)
      case [(r, t) | Just r <- [Map.lookup u runs], t <- take 1 (drop i (triggersOf r))] of
        [(r, t)] -> liftIO (try @SomeException (sendTrigger r t))
          >>= either (\e -> throwError err500 {errBody = fromString (displayException e)}) (\v -> redirect ("/run/" <> UUID.toASCIIBytes v))
        _ -> throwError err404 {errBody = "That run announced no such trigger."}
    redirect :: ByteString -> Handler Html
    redirect l = throwError err303 {errHeaders = [("Location", l)]}
    view f = liftIO $ do
      now <- getCurrentTime
      tz <- getCurrentTimeZone
      atomically $ do
        ix <- index <$> readTVar st.runs
        connected <- isJust <$> readTVar st.broker
        acked <- readTVar st.acked
        let c = Ctx {now, tz, ix, connected, acked}
        pure (render c live (f c))

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  opts <- getRecord "A trivially simple HTML dashboard server" :: IO Options
  let theHost = fromMaybe "127.0.0.1" opts.host
      thePort = fromMaybe 8080 opts.port
  st <- newState
  started <- getCurrentTime
  let insert = atomically . modifyTVar' st.runs . flip (foldr (\r -> Map.insert r.eid.correlationId r))
  insert [localRun t started (simple "Dashboard started" & evtExpected ?~ 60 & evtCritical .~ True) (done "Expecting this healthcheck" ()) | t <- requiredHealthchecks]
  void (forkIO (mqttLoop opts.persistent st))
  void $ forkIO $ forever $ do
    tz <- getCurrentTimeZone
    insert =<< mapM (reconciliation tz started) opts.journal
    threadDelay 60_000_000
  putStrLn $ "Serving on http://" <> theHost <> ":" <> show thePort
  runSettings (setHost (fromString theHost) (setPort thePort defaultSettings)) (serve (Proxy @API) (server st))

-- | Healthchecks that must always be running: until one is seen, the
-- dashboard critically expects it from when it started.
requiredHealthchecks :: [Topic]
requiredHealthchecks = ["healthcheck/kanjideck/fulfillment-server", "healthcheck/scrollsent"]
