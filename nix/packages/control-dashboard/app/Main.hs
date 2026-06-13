module Main (main) where

import Control.Exception (IOException, try)
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isDigit, isSpace)
import Data.List (foldl', stripPrefix, tails)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.String (fromString)
import Data.Time (Day, diffDays, getCurrentTime, utctDay)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import GHC.Generics (Generic)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Generic (ParseRecord, getRecord)
import Servant
import Servant.HTML.Blaze (HTML)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Text.Blaze (customAttribute)
import Text.Blaze.Html5 (Html, (!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

-- | A named hledger journal to report on.
data Journal = Journal
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
parseJournal :: String -> Journal
parseJournal s = case break (== '=') s of
  (name, '=' : path) -> Journal (trim name) path
  (name, _) -> Journal (trim name) ""

-- | The API: the instant-loading index page, plus the finances fragment that
-- htmx fetches lazily once the page has loaded.
type API =
  Get '[HTML] Html
    :<|> "finances" :> Get '[HTML] Html

server :: Bool -> [Journal] -> Server API
server finances journals = pure (indexPage finances) :<|> financesHandler
  where
    financesHandler = liftIO $ do
      today <- utctDay <$> getCurrentTime
      financesFragment <$> mapM (journalStatus today) journals

-- | The index page. It does no slow work, so it loads instantly. When finances
-- are enabled it embeds htmx and a placeholder that fetches @\/finances@ on
-- load, swapping itself out for the rendered fragment as soon as it arrives.
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
    when finances $
      H.div
        ! customAttribute "hx-get" "/finances"
        ! customAttribute "hx-trigger" "load"
        ! customAttribute "hx-swap" "outerHTML"
        $ "Loading finances…"

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
journalStatus :: Day -> Journal -> IO (String, Maybe Integer)
journalStatus today (Journal name path) = do
  mlast <- latestAssertionDate path
  pure (name, diffDays today <$> mlast)

-- | Latest balance-assertion date in a journal, or 'Nothing' if hledger is
-- unavailable, errors, or the journal has no assertions. Reconciliation is
-- recorded as balance assertions, so the last reconciliation is the latest
-- date among postings carrying one. We let @hledger@ parse the journal (it
-- resolves @include@s) and scan its normalized @print@ output.
latestAssertionDate :: FilePath -> IO (Maybe Day)
latestAssertionDate path = do
  res <- try (readProcessWithExitCode "hledger" ["print", "-f", path] "")
    :: IO (Either IOException (ExitCode, String, String))
  pure $ case res of
    Right (ExitSuccess, out, _) -> scanJournal (lines out)
    _ -> Nothing

-- | Scan normalized journal lines for the latest assertion date. Tracks the
-- current transaction date; a posting carrying a balance assertion (@=@) counts
-- at its @date:@ tag if present, else the transaction date.
scanJournal :: [String] -> Maybe Day
scanJournal = snd . foldl' step (Nothing, Nothing)
  where
    step (cur, maxD) line
      | startsTransaction line =
          (parseDay (takeWhile (\c -> isDigit c || c == '-') line), maxD)
      | isPosting line && hasAssertion line =
          (cur, max maxD (tagDate line `orElse` cur))
      | otherwise = (cur, maxD)

-- | A line beginning with a digit starts a transaction (its date).
startsTransaction :: String -> Bool
startsTransaction (c : _) = isDigit c
startsTransaction _ = False

-- | A posting line is indented and non-blank.
isPosting :: String -> Bool
isPosting line = case line of
  (c : _) -> isSpace c && not (all isSpace line)
  _ -> False

-- | True when the posting (ignoring its comment) contains a balance assertion.
hasAssertion :: String -> Bool
hasAssertion = elem '=' . takeWhile (/= ';')

-- | The @date:@ posting tag, if present in the line's comment.
tagDate :: String -> Maybe Day
tagDate line = listToMaybe
  [ d
  | t <- tails line
  , Just rest <- [stripPrefix "date:" t]
  , let val = takeWhile (\c -> isDigit c || c == '-') (dropWhile isSpace rest)
  , Just d <- [parseDay val]
  ]

parseDay :: String -> Maybe Day
parseDay = parseTimeM True defaultTimeLocale "%Y-%m-%d"

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just x) _ = Just x
orElse Nothing y = y

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
