{-# LANGUAGE OverloadedStrings, OverloadedRecordDot, DeriveAnyClass #-}
-- | notmuch's post-new hook: publishes a @script/mail/received@ event per
-- message tagged @new@, then removes the tag from those messages. Mail older
-- than two days gets no event, so a first full sync doesn't flood the broker.
module Main (main) where

import Control.Events
import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Foldable (toList)
import Data.Maybe (mapMaybe)
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Generics (Generic)
import System.Process.Typed (byteStringInput, proc, readProcessStdout_, runProcess_, setStdin)
import qualified Data.ByteString.Lazy.Char8 as LBS8

data Mail = Mail
  { messageId :: String
  , from      :: String
  , to        :: String
  , cc        :: String
  , subject   :: String
  }
  deriving (Generic, ToJSON)

main :: IO ()
main = do
  out <- readProcessStdout_ $ proc "notmuch"
    ["show", "--format=json", "--body=false", "--entire-thread=false", "tag:new"]
  new <- either fail (pure . mapMaybe (parseMaybe mail) . messages) (eitherDecode out)
  now <- getPOSIXTime
  withConn (script <> "mail") $ \c ->
    mapM_ (\m -> event_ c "received" (simple ("Mail from " <> m.from) & withMsg ?~ m) pure)
      [ m | (t, m) <- new, (now - fromInteger t) < 2 * 86400 {- 2 days only -} ]
  runProcess_ $ setStdin (byteStringInput (LBS8.unlines [ LBS8.pack ("-new -- id:\"" <> m.messageId <> "\"") | (_, m) <- new ]))
              $ proc "notmuch" ["tag", "--batch"]

-- | notmuch threads are forests of @[message, replies]@ pairs.
messages :: Value -> [Value]
messages (Array xs) = case toList xs of
  [m@(Object _), rs] -> m : messages rs
  ys                 -> concatMap messages ys
messages _ = []

-- | A message and when it was received, in seconds since the epoch.
mail :: Value -> Parser (Integer, Mail)
mail = withObject "message" $ \o -> do
  h <- o .: "headers"
  let header k = h .:? k .!= ""
  (,) <$> o .: "timestamp"
      <*> (Mail <$> o .: "id" <*> header "From" <*> header "To" <*> header "Cc" <*> header "Subject")
