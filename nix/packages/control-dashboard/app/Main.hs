module Main (main) where

import Control.Exception (IOException, try)
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isDigit, isSpace)
import Data.List (foldl', stripPrefix, tails)
import Data.Maybe (listToMaybe)
import Data.String (fromString)
import Data.Time (Day, diffDays, getCurrentTime, utctDay)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Applicative
import Servant
import Servant.HTML.Blaze (HTML)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Text.Blaze.Html5 (Html, (!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

-- | A named hledger journal to report on.
data Journal = Journal
  { jName :: String
  , jPath :: FilePath
  }

-- | CLI options.
data Options = Options
  { optHost :: String
  , optPort :: Int
  , optFinances :: Bool
  , optJournals :: [Journal]
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
    <*> option
      auto
      ( long "finances"
          <> metavar "BOOL"
          <> value False
          <> showDefault
          <> help "Show the finances section (link + per-journal reconciliation)"
      )
    <*> many
      ( option
          journalReader
          ( long "journal"
              <> metavar "NAME=PATH"
              <> help "A journal to report the last reconciliation date for (repeatable)"
          )
      )

journalReader :: ReadM Journal
journalReader = eitherReader $ \s -> case break (== '=') s of
  (name, '=' : path) -> Right (Journal (trim name) path)
  _ -> Left "expected NAME=PATH"

-- | The whole API: a single page served at the root.
type API = Get '[HTML] Html

server :: Bool -> [Journal] -> Server API
server finances journals = do
  statuses <-
    liftIO $
      if finances
        then do
          today <- utctDay <$> getCurrentTime
          mapM (journalStatus today) journals
        else pure []
  pure (page finances statuses)

page :: Bool -> [(String, Maybe Integer)] -> Html
page finances statuses = H.docTypeHtml $ do
  H.head $ H.title "control-dashboard"
  H.body $ do
    H.h1 "control-dashboard"
    H.p "It works."
    when finances $ do
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
  Options {optHost, optPort, optFinances, optJournals} <-
    execParser $
      info
        (options <**> helper)
        (fullDesc <> progDesc "A trivially simple HTML dashboard server")
  let settings =
        setHost (fromString optHost) $
          setPort optPort defaultSettings
  putStrLn $ "Serving on http://" <> optHost <> ":" <> show optPort
  runSettings settings (serve (Proxy :: Proxy API) (server optFinances optJournals))
