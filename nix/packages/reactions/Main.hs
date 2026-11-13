-- | Runs the reactions declared in nix: on each completed event whose topic
-- matches a reaction's filter, runs its program with the 'Occurred' event as
-- JSON on stdin. If the reaction has a topic, the run is reported as an event
-- under @script/<topic>@ reacting to the one that caused it.
--
-- Usage: @reactions CONFIG@, where CONFIG is a JSON list of 'Reaction's.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (forConcurrently_)
import Control.Events
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forever, when)
import Data.Aeson (FromJSON, ToJSON, Value, eitherDecodeFileStrict, encode)
import Data.Text (Text)
import GHC.Generics (Generic)
import Network.MQTT.Topic (Topic, match)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)
import System.Process.Typed (byteStringInput, proc, runProcess_, setStdin)

data Reaction = Reaction
  { name  :: String
  , on    :: Text
  , topic :: Maybe Text
  , run   :: FilePath
  }
  deriving (Generic, FromJSON)

data Occurred = Occurred
  { event    :: EventId
  , start    :: Timed (EvtMsg Value)
  , finished :: Timed EvtDone
  }
  deriving (Generic, ToJSON)

main :: IO ()
main = do
  [config] <- getArgs
  reactions <- mapM parse =<< either fail pure =<< eitherDecodeFileStrict @[Reaction] config
  session <- newPersistentSession "reactions"
  forever do
    r <- try @SomeException $ withPersistentConn session script \c -> do
      _ <- react c "#" \e s -> pure \d ->
        forConcurrently_ reactions \(f, t, r) -> when (match f e.evtTopic && Just e.evtTopic /= fmap (script <>) t) $
          try @SomeException (respond c e r t (Occurred e s d)) >>= either (hPutStrLn stderr . displayException) pure
      waitConnDisconnect c
    hPutStrLn stderr ("mqtt: " <> either displayException (const "disconnected") r)
    threadDelay 5_000_000
  where
    parse r = maybe (fail ("Bad filter or topic in reaction " <> r.name)) pure
      ((,,r) <$> mkFilter r.on <*> traverse mkTopic r.topic)

respond :: Conn s -> EventId -> Reaction -> Maybe Topic -> Occurred -> IO ()
respond c e r t o = maybe id report t (runProcess_ (setStdin (byteStringInput (encode o)) (proc r.run [])))
  where
    report t' = event_ c t' (simple r.name & reacted ?~ e) . const
