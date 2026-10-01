{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe, isJust)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (Day, getCurrentTime, getCurrentTimeZone)
import Data.UUID (UUID)
import Events
import Finances
import GHC.Generics (Generic)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Generic (ParseRecord, getRecord)
import Servant
import Servant.HTML.Blaze (HTML)
import Text.Blaze.Html5 (Html)
import Views

-- | CLI options, parsed generically from the field names: @--host@, @--port@
-- and repeatable @--journal NAME=PATH@.
data Options = Options
  { host :: Maybe String
  , port :: Maybe Int
  , journal :: [String]
  }
  deriving (Generic)

instance ParseRecord Options

type API = QueryFlag "live" :>
  (    Get '[HTML] Html
  :<|> "topic" :> CaptureAll "topic" Text :> Get '[HTML] Html
  :<|> "run" :> Capture "run" UUID :> Get '[HTML] Html
  :<|> "triggers" :> Get '[HTML] Html
  :<|> "trigger" :> QueryParam "topic" Text :> QueryParam "label" Text :> QueryParam "content" Text :> Get '[HTML] Html
  :<|> "trigger" :> ReqBody '[FormUrlEncoded] Trigger :> Post '[HTML] Html
  :<|> "ack" :> Capture "run" UUID :> Header "Referer" Text :> Post '[HTML] Html
  )

server :: State -> TVar [(String, Maybe Day)] -> Server API
server st journals live =
       view overviewPage
  :<|> view . topicPage . T.intercalate "/"
  :<|> view . runPage
  :<|> view triggersPage
  :<|> (\t l c -> view (triggerPage (Trigger (orEmpty t) (orEmpty l) (orEmpty c)) Nothing))
  :<|> (\t -> liftIO (publishTrigger st t) >>= either (view . triggerPage t . Just) (\() -> redirect "/triggers"))
  :<|> (\u back -> liftIO (atomically (modifyTVar' st.acked (Set.insert u))) >> redirect (maybe "/" encodeUtf8 back))
  where
    orEmpty = fromMaybe ""
    redirect :: ByteString -> Handler Html
    redirect l = throwError err303 {errHeaders = [("Location", l)]}
    view f = liftIO $ do
      now <- getCurrentTime
      tz <- getCurrentTimeZone
      atomically $ do
        ix <- index <$> readTVar st.runs
        connected <- isJust <$> readTVar st.broker
        lost <- readTVar st.lost
        reconciled <- readTVar journals
        acked <- readTVar st.acked
        let c = Ctx {now, tz, ix, connected, lost, reconciled, acked}
        pure (render c live (f c))

main :: IO ()
main = do
  opts <- getRecord "A trivially simple HTML dashboard server" :: IO Options
  let theHost = fromMaybe "127.0.0.1" opts.host
      thePort = fromMaybe 8080 opts.port
  st <- newState
  journals <- newTVarIO []
  void (forkIO (mqttLoop st))
  void $ forkIO $ forever $ do
    rs <- mapM (\s -> let (name, path) = break (== '=') s in (name,) <$> lastReconciled (drop 1 path)) opts.journal
    atomically (writeTVar journals rs)
    threadDelay 60_000_000
  putStrLn $ "Serving on http://" <> theHost <> ":" <> show thePort
  runSettings (setHost (fromString theHost) (setPort thePort defaultSettings)) (serve (Proxy @API) (server st journals))
