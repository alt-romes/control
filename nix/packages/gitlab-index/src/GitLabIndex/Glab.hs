-- | Thin wrapper over the @glab api@ CLI.
--
-- We shell out to @glab@ so that authentication, host config and tokens stay
-- entirely glab's concern. Pagination follows the @Link: rel="next"@ header
-- (GitLab keyset pagination), which avoids offset-pagination limits.
module GitLabIndex.Glab
  ( glabPage
  , glabPaged
  , GlabError(..)
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (Exception, catch, throwIO)
import Control.Monad (when)
import Data.Aeson (Value, eitherDecodeStrict')
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.Char (toLower)
import Data.List (find, isInfixOf, isPrefixOf)
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, hSetBinaryMode, stderr)
import System.Process

-- | A failed @glab api@ call, carrying the HTTP status if we could parse one.
data GlabError = GlabError { geStatus :: Maybe Int, geMessage :: String }

instance Show GlabError where show = geMessage
instance Exception GlabError

-- | Worth retrying? Network/timeout/decode errors (no status), plus 408, 429
-- and 5xx. Client errors like 401/403/404 are permanent — fail fast.
isTransient :: GlabError -> Bool
isTransient e = case geStatus e of
  Nothing -> True
  Just s  -> s == 408 || s == 429 || s >= 500

-- | Fetch a single page. Returns the decoded array and the endpoint of the
-- next page, if any. Transient failures are retried with exponential backoff.
glabPage :: String -> String -> IO ([Value], Maybe String)
glabPage host endpoint = withRetry 6 $ do
  (ec, out, err) <- runProc "glab" ["api", "--hostname", host, "-i", endpoint]
  let errStr = BS8.unpack err
  when (ec /= ExitSuccess) $
    throwIO $ GlabError (parseHttpStatus errStr)
                        ("glab api failed for " <> endpoint <> ":\n" <> errStr)
  let (hdrs, body) = splitHeaders out
  case eitherDecodeStrict' body of
    Right vals -> pure (vals, nextEndpoint hdrs)
    Left e     -> throwIO $ GlabError Nothing
                              ("could not decode glab response for " <> endpoint <> ": " <> e)

-- | Retry a 'GlabError' action while it is transient, backing off 1s, 2s,
-- 4s, … Permanent errors are re-raised immediately, as is the last error
-- once attempts are exhausted.
withRetry :: Int -> IO a -> IO a
withRetry maxAttempts act = go 1
  where
    go n = act `catch` \e ->
      if n >= maxAttempts || not (isTransient e)
        then throwIO e
        else do
          let secs = 2 ^ (n - 1) :: Int
          hPutStrLn stderr $
            "\n  warning: request failed (attempt " <> show n <> "/" <> show maxAttempts
            <> "), retrying in " <> show secs <> "s: " <> geMessage e
          threadDelay (secs * 1000000)
          go (n + 1)

-- | Pull a 3-digit HTTP status out of glab's error text, e.g. @(HTTP 403)@.
parseHttpStatus :: String -> Maybe Int
parseHttpStatus = go
  where
    go s = case s of
      []       -> Nothing
      ('(' : 'H' : 'T' : 'T' : 'P' : ' ' : rest) -> readStatus rest
      (_ : t)  -> go t
    readStatus rest = case span (`elem` ['0' .. '9']) rest of
      (ds@(_ : _), _) -> Just (read (take 3 ds))
      _               -> Nothing

-- | Fetch every page, accumulating the results. Use only for small
-- collections (e.g. the notes of one item).
glabPaged :: String -> String -> IO [Value]
glabPaged host = go []
  where
    go acc ep = do
      (vals, next) <- glabPage host ep
      let acc' = acc <> vals
      maybe (pure acc') (go acc') next

-- | Run a process, capturing stdout and stderr as raw bytes without deadlock.
runProc :: String -> [String] -> IO (ExitCode, ByteString, ByteString)
runProc cmd args = do
  (_, Just hout, Just herr, ph) <-
    createProcess (proc cmd args) { std_out = CreatePipe, std_err = CreatePipe }
  hSetBinaryMode hout True
  hSetBinaryMode herr True
  errVar <- newEmptyMVar
  _ <- forkIO (BS.hGetContents herr >>= putMVar errVar)
  out <- BS.hGetContents hout
  err <- takeMVar errVar
  ec  <- waitForProcess ph
  pure (ec, out, err)

-- | Split an HTTP response (as produced by @glab api -i@) into its header
-- block (as text) and body (raw bytes), at the first blank line.
splitHeaders :: ByteString -> (String, ByteString)
splitHeaders out =
  let (h1, r1) = BS.breakSubstring "\r\n\r\n" out
  in if not (BS.null r1)
       then (BS8.unpack h1, BS.drop 4 r1)
       else let (h2, r2) = BS.breakSubstring "\n\n" out
            in if not (BS.null r2)
                 then (BS8.unpack h2, BS.drop 2 r2)
                 else ("", out)

-- | Parse the @Link@ header and return the @rel="next"@ endpoint, stripped
-- down to the path after @\/api\/v4\/@ (what @glab api@ expects).
nextEndpoint :: String -> Maybe String
nextEndpoint hdrs = do
  line <- find (("link:" `isPrefixOf`) . map toLower) (map stripCR (lines hdrs))
  let val = dropWhile (== ' ') (drop 1 (dropWhile (/= ':') line))
  part <- find ("rel=\"next\"" `isInfixOf`) (splitOn ',' val)
  url  <- betweenAngles part
  Just (afterApiV4 url)
  where
    stripCR s = if not (null s) && last s == '\r' then init s else s

betweenAngles :: String -> Maybe String
betweenAngles s = case dropWhile (/= '<') s of
  ('<' : rest) -> Just (takeWhile (/= '>') rest)
  _            -> Nothing

afterApiV4 :: String -> String
afterApiV4 = go
  where
    go xs
      | "/api/v4/" `isPrefixOf` xs = drop 8 xs
      | (_ : rest) <- xs           = go rest
      | otherwise                  = xs

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, [])       -> [a]
  (a, _ : rest) -> a : splitOn c rest
