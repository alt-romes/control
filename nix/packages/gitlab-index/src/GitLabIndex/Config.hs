-- | Configuration and on-disk layout.
--
-- All state lives under @<data-dir>/<host>/<project>/@:
--
-- > items/issue/<iid>.json   raw issue object + its notes
-- > items/mr/<iid>.json      raw MR object + its notes
-- > index.tsv                derived, fed to fzf
-- > state.json               sync watermarks
module GitLabIndex.Config
  ( Config(..)
  , resolveDataDir
  , projectApiId
  , urlEncode
  ) where

import Data.Char (isDigit, isAlphaNum, ord, intToDigit)
import System.Directory (XdgDirectory (..), getXdgDirectory, createDirectoryIfMissing)
import System.FilePath ((</>))

data Config = Config
  { cfgHost     :: String        -- ^ GitLab host, passed to @glab --hostname@.
  , cfgProject  :: String        -- ^ Project path (@ghc/ghc@) or numeric id.
  , cfgDataBase :: Maybe FilePath -- ^ Original @--data-dir@ value, if any (re-passed to subprocesses).
  , cfgDataDir  :: FilePath      -- ^ Resolved @<base>/<host>/<project>@ directory.
  , cfgJobs     :: Int           -- ^ Max concurrent note fetches during sync.
  , cfgStyle    :: String        -- ^ glow style for previews (@auto@/@light@/@dark@/…).
  }

-- | The project identifier as it must appear in a REST path: a bare number,
-- or the URL-encoded path.
projectApiId :: Config -> String
projectApiId c
  | not (null p) && all isDigit p = p
  | otherwise                     = urlEncode p
  where p = cfgProject c

sanitize :: String -> String
sanitize = map (\ch -> if ch `elem` ("/\\: " :: String) then '-' else ch)

-- | Resolve and create the per-(host,project) data directory.
resolveDataDir :: String -> String -> Maybe FilePath -> IO (FilePath, FilePath)
resolveDataDir host project mbase = do
  base <- maybe (getXdgDirectory XdgData "gitlab-index") pure mbase
  let dir = base </> sanitize host </> sanitize project
  createDirectoryIfMissing True dir
  pure (base, dir)

-- | Percent-encode a string for safe use inside a query value.
urlEncode :: String -> String
urlEncode = concatMap enc
  where
    enc c
      | isAlphaNum c || c `elem` ("-_.~" :: String) = [c]
      | otherwise = '%' : hex (ord c)
    hex n = [intToDigit (n `div` 16), intToDigit (n `mod` 16)]
