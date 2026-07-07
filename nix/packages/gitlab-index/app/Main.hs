-- | @gitlab-index@: build and search a local index of a GitLab project's
-- issues and merge requests.
--
-- > gitlab-index sync                  # fetch new/changed items + comments
-- > gitlab-index search                # fuzzy-search titles; enter=read, ctrl-o=browser
-- > gitlab-index search --full         # search bodies and comments too
-- > gitlab-index reindex               # rebuild index.tsv from stored items
module Main (main) where

import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit (die)

import GitLabIndex.Config
import GitLabIndex.Search
import GitLabIndex.Store (buildIndex)
import GitLabIndex.Sync
import GitLabIndex.Types

data Opts = Opts
  { oHost    :: String
  , oProject :: Maybe String
  , oDataDir :: Maybe FilePath
  , oRepo    :: Maybe FilePath
  , oJobs    :: Int
  , oStyle   :: String
  , oCmd     :: Cmd
  }

data Cmd
  = Sync
  | Search Bool (Maybe String) (Maybe String)  -- ^ full?, --author, --assignee
  | Preview Bool String Int   -- ^ paged?, type, iid
  | Open String Int
  | Edit String Int
  | Comment String Int
  | Diff String Int
  | Reindex

optsP :: Parser Opts
optsP = Opts
  <$> strOption
        ( long "host" <> metavar "HOST" <> value "gitlab.haskell.org" <> showDefault
       <> help "GitLab host (passed to glab --hostname)" )
  <*> optional (strOption
        ( long "project" <> short 'p' <> metavar "PATH|ID"
       <> help "Project path (ghc/ghc) or numeric id; defaults to $GITLAB_INDEX_PROJECT" ))
  <*> optional (strOption
        ( long "data-dir" <> metavar "DIR"
       <> help "Base data directory (default: $XDG_DATA_HOME/gitlab-index)" ))
  <*> optional (strOption
        ( long "repo" <> metavar "DIR"
       <> help "Local clone to open Fugitive diffs in; defaults to $GITLAB_INDEX_REPO" ))
  <*> option auto
        ( long "jobs" <> short 'j' <> metavar "N" <> value 8 <> showDefault
       <> help "Max concurrent note fetches during sync" )
  <*> strOption
        ( long "style" <> metavar "STYLE" <> value "auto" <> showDefault
       <> help "glow style for previews: auto|light|dark|… (use light/dark if auto-detection fails)" )
  <*> cmdP

cmdP :: Parser Cmd
cmdP = hsubparser
  ( command "sync"   (info (pure Sync)
      (progDesc "Fetch new/changed issues, MRs and their comments"))
 <> command "search" (info (Search
                              <$> switch (long "full" <> short 'f'
                                    <> help "Search bodies and comments, not just titles")
                              <*> optional (strOption (long "author" <> metavar "USER"
                                    <> help "Show only items authored by USER (exact username)"))
                              <*> optional (strOption (long "assignee" <> metavar "USER"
                                    <> help "Show only items assigned to USER (exact username)")))
      (progDesc "Fuzzy-search the index with fzf"))
 <> command "preview" (info (Preview <$> switch (long "page"
                                                  <> help "Show in glow's pager (full screen)")
                                     <*> argument str (metavar "TYPE")
                                     <*> argument auto (metavar "IID"))
      (progDesc "Render one item as Markdown (used by the fzf preview)"))
 <> command "open" (info (Open <$> argument str (metavar "TYPE")
                               <*> argument auto (metavar "IID"))
      (progDesc "Open an item's web URL in the browser"))
 <> command "edit" (info (Edit <$> argument str (metavar "TYPE")
                               <*> argument auto (metavar "IID"))
      (progDesc "Open an item's rendered Markdown in $EDITOR (vim)"))
 <> command "comment" (info (Comment <$> argument str (metavar "TYPE")
                                     <*> argument auto (metavar "IID"))
      (progDesc "Compose a comment in $EDITOR (vim) and post it via glab"))
 <> command "diff" (info (Diff <$> argument str (metavar "TYPE")
                               <*> argument auto (metavar "IID"))
      (progDesc "Open a vim Fugitive diff of an MR's branch against its base (needs --repo)"))
 <> command "reindex" (info (pure Reindex)
      (progDesc "Rebuild index.tsv from stored items"))
  )

main :: IO ()
main = do
  opts <- execParser $ info (optsP <**> helper)
    ( fullDesc <> progDesc "Local searchable index of GitLab issues & merge requests" )
  envProject <- lookupEnv "GITLAB_INDEX_PROJECT"
  project <- case oProject opts `orElse` envProject of
    Just p  -> pure p
    Nothing -> die "No project given. Use --project PATH|ID or set $GITLAB_INDEX_PROJECT."
  (base, dir) <- resolveDataDir (oHost opts) project (oDataDir opts)
  envRepo <- lookupEnv "GITLAB_INDEX_REPO"
  let cfg = Config
        { cfgHost = oHost opts, cfgProject = project
        , cfgDataBase = base <$ oDataDir opts, cfgDataDir = dir
        , cfgJobs = max 1 (oJobs opts), cfgStyle = oStyle opts
        , cfgRepo = oRepo opts `orElse` envRepo }
  case oCmd opts of
    Sync                   -> sync cfg
    Search full aut asg    -> runSearch cfg full aut asg
    Reindex                -> buildIndex cfg
    Preview page tslug iid -> withType tslug (\t -> runPreview cfg page t iid)
    Open tslug iid         -> withType tslug (\t -> runOpen cfg t iid)
    Edit tslug iid         -> withType tslug (\t -> runEdit cfg t iid)
    Comment tslug iid      -> withType tslug (\t -> runComment cfg t iid)
    Diff tslug iid         -> withType tslug (\t -> runDiff cfg t iid)
  where
    orElse a b = maybe b Just a
    withType tslug k = case parseTypeSlug tslug of
      Just t  -> k t
      Nothing -> die ("Unknown item type: " <> tslug <> " (expected 'issue' or 'mr')")
