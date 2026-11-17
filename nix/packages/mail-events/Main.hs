{-# LANGUAGE OverloadedStrings, OverloadedRecordDot, DeriveAnyClass #-}
-- | notmuch's post-new hook: publishes a @script/mail/received@ event per
-- message tagged @new@ and sent by one of the trusted addresses given as
-- arguments, then removes the tag from those messages. Mail older than two
-- days gets no event, so a first full sync doesn't flood the broker.
--
-- Mail is from an address when rspamd's @X-Spamd-Result@ (which rspamd strips
-- from incoming mail before adding its own) shows DMARC passed for the
-- address's domain, and the @From@ address is it. Untrusted mail never becomes
-- an event, so what reacts to events can trust them.
--
-- Usage: @mail-received ADDRESS...@
module Main (main) where

import Control.Events
import Control.Monad (filterM)
import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString (ByteString)
import Data.Char (toLower)
import Data.Foldable (toList)
import Data.IMF (Address (..), BodyHandler (..), Mailbox (..), header, headerFrom, message, renderAddressSpec)
import Data.MIME (defaultCharsets)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Generics (Generic)
import System.Environment (getArgs)
import System.Process.Typed (byteStringInput, proc, readProcessStdout_, runProcess_, setStdin)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
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
  trusted <- map (BS8.pack . map toLower) <$> getArgs
  out <- readProcessStdout_ $ proc "notmuch"
    ["show", "--format=json", "--body=false", "--entire-thread=false", "tag:new"]
  new <- either fail (pure . mapMaybe (parseMaybe mail) . messages) (eitherDecode out)
  now <- getPOSIXTime
  received <- filterM (sentBy trusted)
    [ m | (t, m) <- new, (now - fromInteger t) < 2 * 86400 {- 2 days only -} ]
  withConn (script <> "mail") $ \c ->
    mapM_ (\m -> event_ c "received" (simple ("Mail from " <> m.from) & withMsg ?~ m) pure) received
  runProcess_ $ setStdin (byteStringInput (LBS8.unlines [ LBS8.pack ("-new -- " <> query m) | (_, m) <- new ]))
              $ proc "notmuch" ["tag", "--batch"]

-- | Whether the mail was sent by one of the addresses, see the module header.
sentBy :: [ByteString] -> Mail -> IO Bool
sentBy addresses m = do
  raw <- readProcessStdout_ (proc "notmuch" ["show", "--format=raw", query m])
  pure $ fromMaybe False $ do
    msg <- parseMaybe' (message (const (NoBody ()))) (LBS.toStrict raw)
    [Single (Mailbox _ sender)] <- pure (msg ^. headerFrom defaultCharsets)
    symbols <- parseMaybe' (spamdResult <* A.endOfInput) =<< msg ^? header "X-Spamd-Result"
    domain : _ <- lookup "DMARC_POLICY_ALLOW" symbols
    let address = BS8.map toLower (renderAddressSpec sender)
    pure (address `elem` addresses && ("@" <> BS8.map toLower domain) `BS8.isSuffixOf` address)
  where parseMaybe' p = either (const Nothing) Just . A.parseOnly p

-- | The symbols in an @X-Spamd-Result@ header with their arguments, as in
-- @default: False [1.00 / 15.00]; DMARC_POLICY_ALLOW(-0.50)[gmail.com,none]; ...@
spamdResult :: A.Parser [(ByteString, [ByteString])]
spamdResult = A.skipWhile (/= ';') *> A.char ';' *> A.skipSpace *> A.sepBy symbol (A.char ';' *> A.skipSpace) <* A.skipSpace
  where
    symbol = (,) <$> A.takeWhile1 (A.inClass "A-Z0-9_") <* A.char '(' <* A.takeTill (== ')') <* A.char ')'
                 <*> (A.char '[' *> A.sepBy (A.takeTill (A.inClass ",]")) (A.char ',') <* A.char ']')

query :: Mail -> String
query m = "id:\"" <> m.messageId <> "\""

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
  let field k = h .:? k .!= ""
  (,) <$> o .: "timestamp"
      <*> (Mail <$> o .: "id" <*> field "From" <*> field "To" <*> field "Cc" <*> field "Subject")
