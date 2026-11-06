-- | What Claude makes of a run that went wrong. It's handed everything the
-- server knows about the run and only replies: no tools, no settings, MCP
-- servers, hooks or CLAUDE.md, and a sandbox in which it can't read the home
-- directory or write anywhere but its own state.
module Claude (brief, diagnose) where

import Control.Concurrent.Async (concurrently)
import Control.Events (EventId (..), EvtDone (..), Timed (..))
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.List (find)
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.Encoding as T
import Data.Time (UTCTime)
import Model
import System.Directory (getHomeDirectory)
import System.Exit (ExitCode (..))
import System.IO (hClose)
import System.Process
import System.Timeout (timeout)

-- | The run, the problems the dashboard sees, the chain of runs it's part
-- of, its topic's other recent runs, the last that went well, and its log.
brief :: UTCTime -> State -> Maybe Text -> Run -> Value
brief now st logTail r = object
  [ "now" .= now
  , "run" .= run r
  , "problems" .= problems now st ix r
  , "chain" .= [object ["depth" .= d, "run" .= run x, "problems" .= problems now st ix x] | (d, x) <- trace st ix r]
  , "recentRuns" .= [object ["start" .= x.start.at, "took" .= duration now x, "success" .= fmap (.e.success) x.end, "summary" .= fmap (.e.summary) x.end] | x <- take 10 others]
  , "lastSuccess" .= fmap run (find (maybe False (.e.success) . (.end)) others)
  , "log" .= logTail
  ]
  where
    ix = index st
    run x = object ["topic" .= topicOf x, "started" .= x.start, "finished" .= x.end]
    others = [x | i <- Map.findWithDefault [] (topicOf r) st.byTopic, i /= r.eid.correlationId, Just x <- [Map.lookup i st.runs]]

diagnose :: FilePath -> Value -> IO (Either Text Text)
diagnose claude b = do
  home <- getHomeDirectory
  let p = (proc "/usr/bin/sandbox-exec" (["-p", sandbox home, claude] ++ flags)) {cwd = Just "/", std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
  r <- timeout 300_000_000 $ withCreateProcess p \i o e h -> case (i, o, e) of
    (Just i', Just o', Just e') -> do
      BL.hPut i' (encode b) >> hClose i'
      (out, err) <- concurrently (B.hGetContents o') (B.hGetContents e')
      code <- waitForProcess h
      pure if code == ExitSuccess then Right (T.decodeUtf8Lenient out) else Left (T.decodeUtf8Lenient (err <> out))
    _ -> pure (Left "Couldn't run Claude.")
  pure (fromMaybe (Left "Claude took more than 5 minutes.") r)

flags :: [String]
flags =
  [ "-p", "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"
  , "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence", "--permission-mode", "dontAsk"
  , "--system-prompt", instructions ]

instructions :: String
instructions = unwords
  [ "You diagnose failures in one person's automation system, built on control-events: programs announce runs on MQTT topics,"
  , "with rules (a timeout, when the next run is expected, subtasks and reactions that must follow), and finish with a summary,"
  , "whether they succeeded, a result, and triggers the person may send. A dashboard found a problem with a run, and hands you"
  , "as JSON everything it knows: the run, the problems it sees, the chain of runs it's part of, its topic's recent runs, the"
  , "last one that went well, and the end of its log. You have no tools and can't look anything up: answer from what's given."
  , "Reply in plain text, with no Markdown (no asterisks, backticks or headings), briefly: the most likely cause, the evidence for it, and what the person should do. If the evidence"
  , "isn't enough, say so and say what would tell." ]

-- | Reads of the home directory are denied but for Claude's own state and
-- the keychain it signs in with; writes are denied but for that and
-- temporary files.
sandbox :: FilePath -> String
sandbox home = unlines
  [ "(version 1)"
  , "(allow default)"
  , "(deny file-read* (subpath " <> show home <> "))"
  , "(deny file-write*)"
  , "(allow file-read-metadata (literal " <> show home <> "))"
  , "(allow file-read* (subpath " <> show (home <> "/Library/Keychains") <> "))"
  , "(allow file-read* file-write* (subpath " <> show (home <> "/.claude") <> ") (regex #\"^" <> regex (home <> "/.claude.json") <> "\")"
  , "  (subpath \"/private/var/folders\") (subpath \"/dev\"))" ]
  where
    regex = concatMap \c -> if c == '.' then "\\." else [c]
