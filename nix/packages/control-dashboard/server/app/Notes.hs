-- | The unticked checkboxes, @- [ ] …@, in directories of notes.
module Notes (Note (..), checkbox, ticked, scan) where

import Control.Monad (filterM)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.ByteString as B
import Data.Char (isSpace)
import Data.List (isPrefixOf, sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import GHC.Generics (Generic)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (dropTrailingPathSeparator, makeRelative, takeExtension, takeFileName, (</>))

-- | A checkbox: the file it's in, named from its directory, e.g.
-- @satisago/README.md@, the line it's on, from 0, its indent, and its text.
data Note = Note {file :: Text, line :: Int, indent :: Int, text :: Text}
  deriving (Generic, ToJSON, FromJSON)

-- | The indent of a line that's an unticked checkbox, and the rest of it
-- after the box.
checkbox :: Text -> Maybe (Text, Text)
checkbox l = case T.stripPrefix "- [ ]" rest of
  Just t | Just (c, _) <- T.uncons t, isSpace c -> Just (ws, t)
  _ -> Nothing
  where (ws, rest) = T.span isSpace l

-- | The notes with that line ticked, if it's still that checkbox.
ticked :: Int -> Text -> Text -> Maybe Text
ticked n t s = case splitAt n (T.splitOn "\n" s) of
  (before, l : after) | Just (ws, t') <- checkbox l, T.strip t' == t -> Just (T.intercalate "\n" (before ++ ws <> "- [x]" <> t' : after))
  _ -> Nothing

-- | Every checkbox in the Markdown and Org files under these directories,
-- with the file it's in.
scan :: [FilePath] -> IO [(FilePath, Note)]
scan = fmap concat . traverse \root -> do
  let name f = T.pack (takeFileName (dropTrailingPathSeparator root) </> makeRelative root f)
  fs <- files root
  concat <$> traverse (\f -> map (f,) . notes (name f) <$> B.readFile f) fs
  where
    files d = do
      es <- map (d </>) . sort . filter (not . ("." `isPrefixOf`)) <$> listDirectory d
      dirs <- filterM doesDirectoryExist es
      (filter ((`elem` [".md", ".org"]) . takeExtension) es ++) . concat <$> traverse files dirs
    -- Files that aren't UTF-8 are left alone, so ticking can't garble them.
    notes name b = case T.decodeUtf8' b of
      Right s -> [Note name n (T.length ws) (T.strip t) | (n, l) <- zip [0 ..] (T.splitOn "\n" s), Just (ws, t) <- [checkbox l]]
      Left _ -> []
