module Main (main) where

import Data.String (fromString)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Applicative
import Servant
import Servant.HTML.Blaze (HTML)
import Text.Blaze.Html5 (Html)
import qualified Text.Blaze.Html5 as H

-- | CLI options.
data Options = Options
  { optHost :: String
  , optPort :: Int
  }

options :: Parser Options
options =
  Options
    <$> strOption
      ( long "host"
          <> metavar "HOST"
          <> value "127.0.0.1"
          <> showDefault
          <> help "Host to bind to"
      )
    <*> option
      auto
      ( long "port"
          <> metavar "PORT"
          <> value 8080
          <> showDefault
          <> help "Port to listen on"
      )

-- | The whole API: a single page served at the root.
type API = Get '[HTML] Html

server :: Server API
server = pure page

page :: Html
page = H.docTypeHtml $ do
  H.head $ H.title "control-dashboard"
  H.body $ do
    H.h1 "control-dashboard"
    H.p "It works."

main :: IO ()
main = do
  Options {optHost, optPort} <-
    execParser $
      info
        (options <**> helper)
        (fullDesc <> progDesc "A trivially simple HTML dashboard server")
  let settings =
        setHost (fromString optHost) $
          setPort optPort defaultSettings
  putStrLn $ "Serving on http://" <> optHost <> ":" <> show optPort
  runSettings settings (serve (Proxy :: Proxy API) server)
