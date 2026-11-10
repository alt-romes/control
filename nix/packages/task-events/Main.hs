-- | Turns what happens on the broker into taskwarrior tasks: mail to
-- todo@mogbit.com (its subject is what one would type after @task add@),
-- problems the dashboard announces, and triggers runs announce for the user
-- to send. Adding a task is an event reacting to what caused it.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Events
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forever, guard, unless, when)
import Data.Aeson (FromJSON, Value, eitherDecode, withObject, (.:))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Foldable (for_)
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Network.MQTT.Topic (unTopic)
import System.IO (hPutStrLn, stderr)
import System.Process.Typed (proc, readProcessStdout_, runProcess_)

main :: IO ()
main = do
  session <- newPersistentSession "task-events"
  forever do
    r <- try @SomeException $ withPersistentConn session (script <> "tasks") \c -> do
      _ <- react c "#" \e s -> pure \d ->
        try @SomeException (handle c e s d) >>= either (hPutStrLn stderr . displayException) pure
      waitConnDisconnect c
    hPutStrLn stderr ("mqtt: " <> either displayException (const "disconnected") r)
    threadDelay 5_000_000

handle :: Conn s -> EventId -> Timed (EvtMsg Value) -> Timed EvtDone -> IO ()
handle c e s d = unless ("test/" `T.isPrefixOf` topic) do
  when (topic == "script/mail/received") $
    for_ (s.e.content >>= parseMaybe todo) (add . words)
  for_ (T.stripPrefix "dashboard/problem/" topic) \about ->
    addOnce (T.isPrefixOf (about <> ": ")) "+problem" (T.unpack about <> ": " <> s.e.label)
  for_ (fromMaybe [] d.e.triggers) \t ->
    let task = "Send \"" <> t.triggerLabel <> "\" from " <> T.unpack topic
     in addOnce (== T.pack task) "+trigger" task
  where
    topic = unTopic e.evtTopic
    add args = event_ c "add" (simple ("task add " <> unwords args) & reacted ?~ e) \_ ->
      runProcess_ (proc "task" ("add" : args))
    -- Not while a pending task already says the same.
    addOnce same tag task = do
      pending :: [Task] <- either fail pure . eitherDecode =<< readProcessStdout_ (proc "task" ["status:pending", "export"])
      unless (any (same . (.description)) pending) (add ["project:control-system", tag, "--", task])

-- | The subject of a mail to todo@mogbit.com.
todo :: Value -> Parser String
todo = withObject "mail" \o -> do
  recipients <- o .: "to"
  guard ("todo@mogbit.com" `isInfixOf` recipients)
  o .: "subject"

data Task = Task {description :: Text}
  deriving (Generic, FromJSON)
