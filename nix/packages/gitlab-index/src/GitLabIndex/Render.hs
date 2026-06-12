-- | Render a stored item as Markdown (for the @glow@ preview / editor).
--
-- Inline diff comments are labelled with their @path:line@ so it's clear what
-- they refer to.
module GitLabIndex.Render (renderMarkdown) where

import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import GitLabIndex.Types

renderMarkdown :: ItemType -> Meta -> [Note] -> Text
renderMarkdown t m notes = T.intercalate "\n" $
  [ "# " <> kind <> " #" <> tshow (mIid m) <> " — " <> mTitle m
  , ""
  , "**State:** " <> mState m <> "  ·  **Author:** " <> mAuthor m <> "  ·  **Updated:** " <> mUpdated m
  ]
  ++ [ "**Labels:** " <> T.intercalate ", " (mLabels m) | not (null (mLabels m)) ]
  ++
  [ "<" <> mUrl m <> ">"
  , ""
  , "---"
  , ""
  , if T.null (T.strip (mBody m)) then "_(no description)_" else mBody m
  ]
  ++ renderNotes (filter (not . nSystem) notes)
  where
    kind  = case t of Issue -> "Issue"; MR -> "Merge Request"
    tshow = T.pack . show

    -- Walk notes in order; when consecutive notes share a diff anchor (a reply
    -- thread on one line) show the path label only once, before the thread.
    renderNotes = go Nothing
      where
        go _ []          = []
        go prev (n : ns) = block (posKey n /= prev) n ++ go (posKey n) ns

    block fresh n =
      ["", "---", ""]
      ++ (if fresh then diffLabel n else [])
      ++ [ "**" <> nAuthor n <> "**  ·  " <> nCreated n, "", nBody n ]

    posKey n = (\p -> (posNewPath p, posNewLine p, posOldLine p)) <$> nPos n

    diffLabel n = case nPos n of
      Nothing -> []
      Just p  ->
        let path = fromMaybe "?" (posNewPath p <|> posOldPath p)
            line = maybe "" ((":" <>) . tshow) (posNewLine p <|> posOldLine p)
        in [ "**`" <> path <> line <> "`**", "" ]
