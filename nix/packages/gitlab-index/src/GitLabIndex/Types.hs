-- | Core types and the (lenient) projections we pull out of GitLab's JSON.
--
-- The raw API objects are stored verbatim on disk; these types only describe
-- the handful of fields we render and index, so schema drift elsewhere is
-- harmless.
module GitLabIndex.Types
  ( ItemType(..)
  , typeSlug
  , typeApi
  , parseTypeSlug
  , allTypes
  , Meta(..)
  , Note(..)
  , Position(..)
  , Stored(..)
  ) where

import Data.Aeson
import Data.Text (Text)

data ItemType = Issue | MR deriving (Eq, Show)

-- | On-disk / index slug.
typeSlug :: ItemType -> String
typeSlug Issue = "issue"
typeSlug MR    = "mr"

-- | REST collection name.
typeApi :: ItemType -> String
typeApi Issue = "issues"
typeApi MR    = "merge_requests"

parseTypeSlug :: String -> Maybe ItemType
parseTypeSlug "issue" = Just Issue
parseTypeSlug "mr"    = Just MR
parseTypeSlug _       = Nothing

allTypes :: [ItemType]
allTypes = [Issue, MR]

newtype Author = Author { authorName :: Text }

instance FromJSON Author where
  parseJSON = withObject "author" $ \o -> Author <$> o .: "username"

-- | The fields we index and render.
data Meta = Meta
  { mIid        :: Int
  , mState      :: Text
  , mTitle      :: Text
  , mAuthor     :: Text
  , mLabels     :: [Text]
  , mUpdated    :: Text   -- ^ ISO-8601 @updated_at@; bumped when comments change.
  , mUrl        :: Text
  , mBody       :: Text
  , mNotesCount :: Int     -- ^ @user_notes_count@; lets us skip note fetches.
  , mSourceBranch :: Maybe Text -- ^ MR source branch (absent on issues).
  , mTargetBranch :: Maybe Text -- ^ MR target/base branch (absent on issues).
  } deriving Show

instance FromJSON Meta where
  parseJSON = withObject "item" $ \o -> do
    mauth <- o .:? "author"
    Meta
      <$> o .:  "iid"
      <*> o .:  "state"
      <*> o .:  "title"
      <*> pure (maybe "" authorName mauth)
      <*> o .:? "labels"           .!= []
      <*> o .:  "updated_at"
      <*> o .:  "web_url"
      <*> o .:? "description"      .!= ""
      <*> o .:? "user_notes_count" .!= 0
      <*> o .:? "source_branch"
      <*> o .:? "target_branch"

data Note = Note
  { nAuthor  :: Text
  , nCreated :: Text
  , nBody    :: Text
  , nSystem  :: Bool          -- ^ System notes ("changed label …") are filtered out.
  , nPos     :: Maybe Position -- ^ Present for inline diff comments.
  } deriving Show

instance FromJSON Note where
  parseJSON = withObject "note" $ \o -> do
    mauth <- o .:? "author"
    Note
      <$> pure (maybe "" authorName mauth)
      <*> o .:  "created_at"
      <*> o .:? "body"     .!= ""
      <*> o .:? "system"   .!= False
      <*> o .:? "position"

-- | Where an inline comment is anchored in the diff.
data Position = Position
  { posNewPath :: Maybe Text
  , posOldPath :: Maybe Text
  , posNewLine :: Maybe Int
  , posOldLine :: Maybe Int
  } deriving (Eq, Show)

instance FromJSON Position where
  parseJSON = withObject "position" $ \o -> Position
    <$> o .:? "new_path"
    <*> o .:? "old_path"
    <*> o .:? "new_line"
    <*> o .:? "old_line"

-- | What we persist per item: the raw object plus its raw notes.
data Stored = Stored { sItem :: Value, sNotes :: [Value] }

instance ToJSON Stored where
  toJSON (Stored i n) = object ["item" .= i, "notes" .= n]

instance FromJSON Stored where
  parseJSON = withObject "stored" $ \o ->
    Stored <$> o .: "item" <*> o .:? "notes" .!= []
