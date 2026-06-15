-- | On-disk persistence: stored items, sync state, and the fzf index.
module GitLabIndex.Store
  ( -- * Paths
    itemPath
  , indexPath
    -- * Items
  , writeStored
  , readStored
  , listItemIids
    -- * Sync state
  , SyncState(..)
  , emptyState
  , loadState
  , saveState
  , watermarkFor
  , setWatermark
    -- * Index
  , buildIndex
  ) where

import Control.Monad (forM)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy as BL
import Data.List (isSuffixOf, sortOn)
import Data.Maybe (catMaybes, mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
import System.FilePath ((</>), (<.>), takeBaseName)
import Text.Read (readMaybe)

import GitLabIndex.Config
import GitLabIndex.Types

itemTypeDir :: Config -> ItemType -> FilePath
itemTypeDir cfg t = cfgDataDir cfg </> "items" </> typeSlug t

itemPath :: Config -> ItemType -> Int -> FilePath
itemPath cfg t iid = itemTypeDir cfg t </> show iid <.> "json"

indexPath :: Config -> FilePath
indexPath cfg = cfgDataDir cfg </> "index.tsv"

statePath :: Config -> FilePath
statePath cfg = cfgDataDir cfg </> "state.json"

writeStored :: Config -> ItemType -> Int -> Stored -> IO ()
writeStored cfg t iid s = do
  createDirectoryIfMissing True (itemTypeDir cfg t)
  BL.writeFile (itemPath cfg t iid) (encode s)

readStored :: Config -> ItemType -> Int -> IO (Maybe Stored)
readStored cfg t iid = do
  let p = itemPath cfg t iid
  ex <- doesFileExist p
  if ex then decodeFileStrict' p else pure Nothing

-- | All item ids of a type currently on disk.
listItemIids :: Config -> ItemType -> IO [Int]
listItemIids cfg t = do
  let dir = itemTypeDir cfg t
  ex <- doesDirectoryExist dir
  if not ex
    then pure []
    else do
      fs <- listDirectory dir
      pure $ mapMaybe (readMaybe . takeBaseName) (filter (".json" `isSuffixOf`) fs)

-- Sync state -----------------------------------------------------------------

-- | Per-type @updated_after@ watermarks.
data SyncState = SyncState
  { stIssuesAfter :: Maybe Text
  , stMrsAfter    :: Maybe Text
  }

instance ToJSON SyncState where
  toJSON s = object ["issues_after" .= stIssuesAfter s, "mrs_after" .= stMrsAfter s]

instance FromJSON SyncState where
  parseJSON = withObject "state" $ \o ->
    SyncState <$> o .:? "issues_after" <*> o .:? "mrs_after"

emptyState :: SyncState
emptyState = SyncState Nothing Nothing

loadState :: Config -> IO SyncState
loadState cfg = do
  let p = statePath cfg
  ex <- doesFileExist p
  if ex then maybe emptyState id <$> decodeFileStrict' p else pure emptyState

saveState :: Config -> SyncState -> IO ()
saveState cfg = BL.writeFile (statePath cfg) . encode

watermarkFor :: SyncState -> ItemType -> Maybe Text
watermarkFor s Issue = stIssuesAfter s
watermarkFor s MR    = stMrsAfter s

setWatermark :: SyncState -> ItemType -> Text -> SyncState
setWatermark s Issue w = s { stIssuesAfter = Just w }
setWatermark s MR    w = s { stMrsAfter = Just w }

-- Index ----------------------------------------------------------------------

-- | Collapse whitespace that would break the one-line-per-item TSV format.
flatten :: Text -> Text
flatten = T.map (\c -> if c `elem` ("\t\n\r" :: String) then ' ' else c)

-- | One index line. Tab-separated columns:
--
-- > 1 display  human-readable, with title/state/author/labels  (fzf --with-nth 1)
-- > 2 type     issue|mr   (locates the stored file; preview placeholder {2})
-- > 3 iid      (preview placeholder {3})
-- > 4 extra    body + comments, for full-text mode  (fzf --with-nth '1,4')
--
-- Title mode shows column 1 but fzf searches the whole line; full mode greps
-- the whole line with ripgrep. Either way, anything searchable (bodies,
-- comments) must live on the line — hence column 4.
-- | Issues are @#<iid>@, merge requests @!<iid>@.
refText :: ItemType -> Meta -> Text
refText t m = (case t of Issue -> "#"; MR -> "!") <> T.pack (show (mIid m))

indexLine :: Int -> ItemType -> Meta -> [Note] -> Text
indexLine refW t m notes = T.intercalate "\t" [display, T.pack (typeSlug t), tshow (mIid m), extra]
  where
    -- Pad the ref to a common width so titles line up across rows.
    ref = T.justifyLeft refW ' ' (refText t m)
    labelsTxt
      | null (mLabels m) = ""
      | otherwise        = "  {" <> T.intercalate "," (mLabels m) <> "}"
    display = T.concat [ref, " ", stateGlyph (mState m), " ", flatten (mTitle m)
                       , "  (", mAuthor m, ")", flatten labelsTxt]
    extra   = flatten (T.unwords (mBody m : map nBody (filter (not . nSystem) notes)))
    tshow   = T.pack . show

-- | Compact state indicator. The #/! prefix already says issue vs MR, and on
-- GHC a closed issue/MR usually just means "done" (merged), so this is a plain
-- open-vs-done distinction: hollow dot = open, filled dot = closed/merged.
stateGlyph :: Text -> Text
stateGlyph "opened" = "○"
stateGlyph _        = "●"

-- | Rebuild @index.tsv@ from every stored item, newest first.
buildIndex :: Config -> IO ()
buildIndex cfg = do
  rows <- fmap concat $ forM allTypes $ \t -> do
    iids <- listItemIids cfg t
    fmap catMaybes $ forM iids $ \iid -> do
      ms <- readStored cfg t iid
      pure $ do
        s <- ms
        m <- parseMaybe parseJSON (sItem s)
        let notes = mapMaybe (parseMaybe parseJSON) (sNotes s)
        Just (mUpdated m, t, m, notes)
  let refW    = maximum (1 : [ T.length (refText t m) | (_, t, m, _) <- rows ])
      ordered = sortOn (\(u, _, _, _) -> Down u) rows
      ls      = [ indexLine refW t m notes | (_, t, m, notes) <- ordered ]
  TIO.writeFile (indexPath cfg) (T.unlines ls)
