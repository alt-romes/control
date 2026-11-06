-- | What Claude makes of the system: of a run that went wrong, or of a
-- question about the recent history. It's handed everything the server knows
-- about it and only replies: no tools, no settings, MCP servers, hooks or
-- CLAUDE.md, and a sandbox in which it can't read the home directory or write
-- anywhere but its own state.
module Claude (Question (..), brief, overview, ask) where

import Control.Concurrent.Async (concurrently)
import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Timed (..))
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.List (find)
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time (UTCTime)
import Model
import System.Directory (getHomeDirectory)
import System.Exit (ExitCode (..))
import System.IO (hClose)
import System.Process
import System.Timeout (timeout)

data Question = Diagnosis | History

-- | The run, the problems the dashboard sees, the chain of runs it's part
-- of, its topic's other recent runs, the last that went well, and its log.
brief :: UTCTime -> State -> Maybe Text -> Run -> Value
brief now st logTail r = object
  [ "now" .= now
  , "run" .= run r
  , "problems" .= problems now st ix r
  , "chain" .= [object ["depth" .= d, "run" .= run x, "problems" .= problems now st ix x] | (d, x) <- trace st ix r]
  , "recentRuns" .= [glance now x | x <- take 10 others]
  , "lastSuccess" .= fmap run (find (maybe False (.e.success) . (.end)) others)
  , "log" .= logTail
  ]
  where
    ix = index st
    run x = object ["topic" .= topicOf x, "started" .= x.start, "finished" .= x.end]
    others = [x | i <- Map.findWithDefault [] (topicOf r) st.byTopic, i /= r.eid.correlationId, Just x <- [Map.lookup i st.runs]]

-- | Every topic's problems and last runs, and the question about them.
overview :: UTCTime -> State -> Text -> Value
overview now st q = object
  [ "now" .= now
  , "question" .= q
  , "topics" .= [ object ["topic" .= t, "problems" .= foldMap (problems now st ix) (latest st t), "runs" .= [glance now x | i <- take 15 is, Just x <- [Map.lookup i st.runs]]]
                | (t, is) <- Map.toList st.byTopic ]
  ]
  where ix = index st

glance :: UTCTime -> Run -> Value
glance now x = object
  [ "label" .= x.start.e.label, "start" .= x.start.at, "took" .= duration now x
  , "success" .= fmap (.e.success) x.end, "summary" .= fmap (T.take 160 . firstLine . T.pack . (.e.summary)) x.end ]

ask :: FilePath -> Question -> Value -> IO (Either Text Text)
ask claude q b = do
  home <- getHomeDirectory
  let p = (proc "/usr/bin/sandbox-exec" (["-p", sandbox home, claude] ++ flags q)) {cwd = Just "/", std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
  r <- timeout 300_000_000 $ withCreateProcess p \i o e h -> case (i, o, e) of
    (Just i', Just o', Just e') -> do
      BL.hPut i' (encode b) >> hClose i'
      (out, err) <- concurrently (B.hGetContents o') (B.hGetContents e')
      code <- waitForProcess h
      pure if code == ExitSuccess then Right (T.decodeUtf8Lenient out) else Left (T.decodeUtf8Lenient (err <> out))
    _ -> pure (Left "Couldn't run Claude.")
  pure (fromMaybe (Left "Claude took more than 5 minutes.") r)

flags :: Question -> [String]
flags q =
  [ "-p", "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"
  , "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence", "--permission-mode", "dontAsk"
  , "--system-prompt", unwords (setting : task q) ]

setting :: String
setting = unwords
  [ "You help one person with their automation system, built on control-events: programs announce runs on MQTT topics,"
  , "with rules (a timeout, when the next run is expected, subtasks and reactions that must follow), and finish with a summary,"
  , "whether they succeeded, a result, and triggers the person may send. A dashboard watches them all and hands you, as JSON,"
  , "what it knows. You have no tools and can't look anything up: answer from what's given. Reply in plain text, with no"
  , "Markdown (no asterisks, backticks or headings), briefly. If the evidence isn't enough, say so and say what would tell." ]

task :: Question -> [String]
task = \case
  Diagnosis ->
    [ "The dashboard found a problem with a run: you're given the run, the problems it sees, the chain of runs it's part of,"
    , "its topic's recent runs, the last one that went well, and the end of its log. Say the most likely cause, the evidence"
    , "for it, and what the person should do." ]
  History ->
    [ "You're given every topic's current problems and last runs, and the person's question about them. Answer it." ]

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
