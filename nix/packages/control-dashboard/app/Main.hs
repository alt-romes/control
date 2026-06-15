module Main (main) where

import Control.Exception (IOException, try)
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isSpace)
import Data.List (isSuffixOf)
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Time (Day, diffDays, getCurrentTime, utctDay)
import GHC.Generics (Generic)
import Hledger (Journal, definputopts, jtxns, pbalanceassertion, pdate, readJournalFile, runExceptT, tdate, tpostings)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Generic (ParseRecord, getRecord)
import Servant
import Servant.HTML.Blaze (HTML)
import Text.Blaze (customAttribute)
import Text.Blaze.Html5 (Html, (!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

-- | A named hledger journal to report on.
data JournalSpec = JournalSpec
  { jName :: String
  , jPath :: FilePath
  }

-- | CLI options, parsed generically from the field names:
-- @--host@, @--port@, @--finances@ (a switch) and repeatable @--journal@.
data Options = Options
  { host :: Maybe String
  , port :: Maybe Int
  , finances :: Bool
  , journal :: [String]
  }
  deriving (Generic)

instance ParseRecord Options

-- | Parse a @NAME=PATH@ journal argument; a missing @=@ leaves the path empty.
parseJournal :: String -> JournalSpec
parseJournal s = case break (== '=') s of
  (name, '=' : path) -> JournalSpec (trim name) path
  (name, _) -> JournalSpec (trim name) ""

type API =               Get '[HTML] Html
      :<|> "finances" :> Get '[HTML] Html

server :: Bool -> [JournalSpec] -> Server API
server finances journals = pure (indexPage finances) :<|> financesHandler
  where
    financesHandler = liftIO $ do
      today <- utctDay <$> getCurrentTime
      financesFragment <$> mapM (journalStatus today) journals

-- | The index page loads fast. Htmx fetches slower pieces like @\/finances@,
-- swapping itself out for the rendered fragment as soon as it arrives.
indexPage :: Bool -> Html
indexPage finances = H.docTypeHtml $ do
  H.head $ do
    H.title "control-dashboard"
    H.script
      ! A.src "https://cdn.jsdelivr.net/npm/htmx.org@4.0.0-beta4"
      ! customAttribute "integrity" "sha384-aWZK1NtOs/aWb/+YZdTM8q2JkWEshlMc9mgZ189numT9bwFhyAyYEoO4nO/2dTXt"
      ! customAttribute "crossorigin" "anonymous"
      $ mempty
  H.body $ do
    H.h1 "control-dashboard"
    H.p "It works."
    linksSection
    when finances $
      H.div
        ! customAttribute "hx-get" "/finances"
        ! customAttribute "hx-trigger" "load"
        ! customAttribute "hx-swap" "outerHTML"
        $ "Loading finances…"

-- | A static list of links to the things this dashboard fronts. Bare hostnames
-- are turned into clickable links; @.localhost@ hosts use @http@, the rest
-- @https@.
linksSection :: Html
linksSection = do
  H.h2 "Links"
  H.ul $ forM_ links $ \host' ->
    H.li $ H.a ! A.href (fromString (scheme host' <> host')) $ H.toHtml host'
  where
    links =
      [ "alt-romes.github.io"
      , "analytics.mogbit.com"
      , "dashboard.stripe.com"
      , "ledger.localhost"
      , "satisago.localhost"
      ]
    scheme h
      | ".localhost" `isSuffixOf` h = "http://"
      | otherwise = "https://"

-- | The lazily-loaded finances fragment: a link to finances plus the last
-- reconciliation date of each journal.
financesFragment :: [(String, Maybe Integer)] -> Html
financesFragment statuses = H.div $ do
  H.p $ H.a ! A.href "http://ledger.localhost" $ "Finances"
  H.ul $ forM_ statuses $ \(name, days) ->
    H.li $ H.toHtml $ name <> ": " <> describe days
  where
    describe (Just d) = show d <> " days since last reconciled"
    describe Nothing = "last reconciled date unknown"

-- | Days between today and a journal's most recent balance assertion.
journalStatus :: Day -> JournalSpec -> IO (String, Maybe Integer)
journalStatus today (JournalSpec name path) = do
  mlast <- latestAssertionDate path
  pure (name, diffDays today <$> mlast)

-- | Reconciliation is recorded as balance assertions, so the last
-- reconciliation is the latest date among postings carrying one. We let
-- @hledger@ parse the journal (it resolves @include@s) and inspect the
-- resulting transactions.
latestAssertionDate :: FilePath -> IO (Maybe Day)
latestAssertionDate path = do
  res <- try (runExceptT (readJournalFile definputopts path))
    :: IO (Either IOException (Either String Journal))
  pure $ case res of
    Right (Right j) -> latestAssertion j
    _ -> Nothing

latestAssertion :: Journal -> Maybe Day
latestAssertion j = case dates of
  [] -> Nothing
  ds -> Just (maximum ds)
  where
    dates =
      [ fromMaybe (tdate t) (pdate p)
      | t <- jtxns j
      , p <- tpostings t
      , Just _ <- [pbalanceassertion p]
      ]

trim :: String -> String
trim = f . f where f = reverse . dropWhile isSpace

main :: IO ()
main = do
  opts <- getRecord "A trivially simple HTML dashboard server"
  let theHost = fromMaybe "127.0.0.1" (host opts)
      thePort = fromMaybe 8080 (port opts)
      journals = map parseJournal (journal opts)
      settings = setHost (fromString theHost) (setPort thePort defaultSettings)
  putStrLn $ "Serving on http://" <> theHost <> ":" <> show thePort
  runSettings settings (serve (Proxy :: Proxy API) (server (finances opts) journals))
