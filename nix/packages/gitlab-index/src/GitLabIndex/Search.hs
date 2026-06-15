-- | The interactive fzf search and the @preview@/@open@ subcommands it drives.
module GitLabIndex.Search
  ( runSearch
  , runPreview
  , runOpen
  , runEdit
  , runComment
  , runDiff
  ) where

import Control.Exception (finally)
import Data.Aeson (parseJSON)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, findExecutable, getTemporaryDirectory, removeFile)
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (IOMode (ReadMode), hClose, openFile, openTempFile)
import System.Process

import GitLabIndex.Config
import GitLabIndex.Render
import GitLabIndex.Store
import GitLabIndex.Types

-- | Launch fzf over @index.tsv@ with two interchangeable search modes,
-- toggled live with ctrl-t:
--
--   * title  — fzf's own fuzzy matching over the displayed rows.
--   * grep   — a live ripgrep full-text search over everything (titles,
--              bodies and comments); fzf's own search is disabled and rg
--              re-runs on every keystroke.
--
-- @full@ only chooses which mode it starts in. Enter renders the full item
-- locally (paged); ctrl-v opens it in the editor; ctrl-o in the browser.
runSearch :: Config -> Bool -> IO ()
runSearch cfg full = do
  let idx = indexPath cfg
  ex <- doesFileExist idx
  if not ex
    then putStrLn "No index found. Run `gitlab-index sync` first."
    else do
      previewCmd <- mkPreviewCmd cfg
      let idxq   = shq idx
          rg     = "rg --color=never --smart-case --no-filename --no-line-number -e {q} -- "
                <> idxq <> " || true"
          catAll = "cat " <> idxq

          -- ctrl-t flips between the two modes based on the current prompt.
          -- grep mode: disable fzf search and (re)bind change->rg reload.
          -- title mode: re-enable fzf search, unbind change, reload full list.
          dq s   = "\"" <> s <> "\""
          toGrep  = "change-prompt(grep> )+disable-search+rebind(change)+reload(" <> rg <> ")"
          toTitle = "change-prompt(title> )+enable-search+unbind(change)+reload(" <> catAll <> ")"
          toggle = "ctrl-t:transform:[ \"$FZF_PROMPT\" = \"title> \" ]"
                <> " && echo " <> dq toGrep
                <> " || echo " <> dq toTitle

          -- ctrl-s: run a sync (terminal handed over so progress shows), then
          -- reload the list from the rebuilt index in the current mode.
          syncReload = "transform:[ \"$FZF_PROMPT\" = \"title> \" ]"
                    <> " && echo " <> dq ("reload(" <> catAll <> ")")
                    <> " || echo " <> dq ("reload(" <> rg <> ")")
          syncBind = "ctrl-s:execute(" <> previewCmd <> " sync)+" <> syncReload

          (startBind, promptArg, disabledArgs)
            | full      = ( "start:reload(" <> rg <> ")", "grep> ", ["--disabled"] )
            | otherwise = ( "start:reload(" <> catAll <> ")+unbind(change)", "title> ", [] )

          args =
            [ "--delimiter", "\t"
            -- Show only column 1, but search the whole line (default --nth), so
            -- title mode still matches bodies/comments in column 4.
            , "--with-nth", "1"
            -- Rank by where the match starts. Column 1 begins each line with the
            -- padded ref (#/!<iid>), so an item that *is* #16188 (match at the
            -- very start) beats one that merely mentions it mid-line. No
            -- --no-sort, so title mode ranks by score; grep mode keeps ripgrep's
            -- order because its fzf search is disabled (nothing to score).
            , "--tiebreak", "begin"
            , "--ansi"
            , "--prompt", promptArg
            , "--header", "ctrl-t: title/grep · enter: read · ctrl-v: vim · ctrl-d: diff · ctrl-o: browser · ctrl-r: comment · ctrl-s: sync"
            , "--preview", previewCmd <> " preview {2} {3}"
            , "--preview-window", "right,55%,wrap"
            , "--bind", "change:reload(" <> rg <> ")"
            , "--bind", startBind
            , "--bind", toggle
            , "--bind", "enter:execute(" <> previewCmd <> " preview {2} {3} --page)"
            , "--bind", "ctrl-v:execute(" <> previewCmd <> " edit {2} {3})"
            , "--bind", "ctrl-d:execute(" <> previewCmd <> " diff {2} {3})"
            , "--bind", "ctrl-o:execute-silent(" <> previewCmd <> " open {2} {3})"
            , "--bind", "ctrl-r:execute(" <> previewCmd <> " comment {2} {3})"
            , "--bind", syncBind
            ] ++ disabledArgs
      h <- openFile "/dev/null" ReadMode
      (_, _, _, ph) <- createProcess (proc "fzf" args) { std_in = UseHandle h }
      _ <- waitForProcess ph
      hClose h

-- | Render one stored item as Markdown to the terminal, via @glow@ when
-- available. @page@ shows it in glow's pager (used by Enter); otherwise it is
-- sized to the fzf preview pane.
runPreview :: Config -> Bool -> ItemType -> Int -> IO ()
runPreview cfg page t iid = do
  ms <- readStored cfg t iid
  case ms of
    Nothing -> putStrLn $ "Not found: " <> typeSlug t <> " #" <> show iid
    Just s  -> do
      let md = renderStored t s
      mglow <- findExecutable "glow"
      case mglow of
        Nothing -> TIO.putStr md
        Just _  -> do
          -- Force the style: in the fzf preview pane glow's stdout is not a
          -- TTY, so its light/dark auto-detection fails and falls back to dark.
          let styleArgs = ["-s", cfgStyle cfg]
          widthArgs <-
            if page
              then pure ["-p"]                                   -- glow's own pager
              else maybe [] (\c -> ["-w", c]) <$> lookupEnv "FZF_PREVIEW_COLUMNS"
          (Just hin, _, _, ph) <-
            createProcess (proc "glow" (styleArgs <> widthArgs)) { std_in = CreatePipe }
          TIO.hPutStr hin md
          hClose hin
          _ <- waitForProcess ph
          pure ()

-- | Open an item's web URL in the browser.
runOpen :: Config -> ItemType -> Int -> IO ()
runOpen cfg t iid = do
  ms <- readStored cfg t iid
  case ms >>= parseMaybe parseJSON . sItem of
    Just m  -> callProcess "open" [T.unpack (mUrl m)]
    Nothing -> pure ()

-- | Render an item to a temporary @.md@ file and open it in the user's editor
-- (@$VISUAL@/@$EDITOR@, falling back to nvim/vim/vi), then clean up.
runEdit :: Config -> ItemType -> Int -> IO ()
runEdit cfg t iid = do
  ms <- readStored cfg t iid
  case ms of
    Nothing -> putStrLn $ "Not found: " <> typeSlug t <> " #" <> show iid
    Just s  -> do
      let md = renderStored t s
      editor <- pickEditor
      tmpDir <- getTemporaryDirectory
      (path, h) <- openTempFile tmpDir ("gitlab-index-" <> typeSlug t <> show iid <> ".md")
      TIO.hPutStr h md
      hClose h
      callProcess editor [path] `finally` removeFile path

-- | Compose a comment in the editor and post it to the item via @glab api@.
runComment :: Config -> ItemType -> Int -> IO ()
runComment cfg t iid = do
  editor <- pickEditor
  tmpDir <- getTemporaryDirectory
  (path, h) <- openTempFile tmpDir ("gitlab-index-comment-" <> typeSlug t <> show iid <> ".md")
  hClose h
  flip finally (removeFile path) $ do
    callProcess editor [path]                 -- inherits the terminal, so vim works
    body <- TIO.readFile path
    if T.null (T.strip body)
      then putStrLn "Empty comment — nothing posted."
      else do
        let ep = "projects/" <> projectApiId cfg <> "/" <> typeApi t
              <> "/" <> show iid <> "/notes"
        (ec, _, err) <- readProcessWithExitCode "glab"
          [ "api", "--hostname", cfgHost cfg, "--method", "POST", ep
          , "--raw-field", "body=" <> T.unpack body ] ""
        case ec of
          ExitSuccess   -> putStrLn ("Comment posted to " <> typeSlug t <> " #" <> show iid <> ".")
          ExitFailure _ -> putStrLn ("Failed to post comment:\n" <> err)

-- | Open a vim Fugitive diff of an MR's source branch against its base branch,
-- in the local clone given by @--repo@ / @$GITLAB_INDEX_REPO@.
--
-- GitLab exposes an MR's head commit as the special ref
-- @refs\/merge-requests\/<iid>\/head@. We fetch that and the current tip of the
-- target branch into private @refs\/gitlab-index\/*@ refs (so we never touch
-- the user's own branches), then open Fugitive on @base...mr@ — the three-dot
-- form shows exactly what the MR introduces since it diverged from its base.
runDiff :: Config -> ItemType -> Int -> IO ()
runDiff _   Issue _   = putStrLn "Diffs only apply to merge requests."
runDiff cfg MR    iid =
  case cfgRepo cfg of
    Nothing   -> putStrLn "No repo configured. Pass --repo DIR or set $GITLAB_INDEX_REPO."
    Just repo -> do
      ms <- readStored cfg MR iid
      case ms >>= parseMaybe parseJSON . sItem of
        Nothing -> putStrLn ("Not found: mr !" <> show iid)
        Just m  -> case mTargetBranch m of
          Nothing     -> putStrLn ("MR !" <> show iid <> " has no target branch recorded; re-run sync.")
          Just target -> do
            let mrRef   = "refs/gitlab-index/mr-" <> show iid
                baseRef = "refs/gitlab-index/base-" <> show iid
                refSpecs =
                  [ "+refs/merge-requests/" <> show iid <> "/head:" <> mrRef
                  , "+" <> T.unpack target <> ":" <> baseRef ]
            (ec, _, err) <- readProcessWithExitCode "git"
              (["-C", repo, "fetch", "origin"] <> refSpecs) ""
            case ec of
              ExitFailure _ -> putStrLn ("git fetch failed:\n" <> err)
              ExitSuccess   -> do
                vim <- pickVim
                (_, _, _, ph) <- createProcess
                  (proc vim ["-c", "Git diff --no-ext-diff " <> baseRef <> "..." <> mrRef])
                    { cwd = Just repo }  -- so Fugitive runs git in the clone
                _ <- waitForProcess ph
                pure ()

-- | First available vim that Fugitive can run in: nvim, then vim, then vi.
pickVim :: IO String
pickVim = go ["nvim", "vim", "vi"]
  where
    go []       = pure "vim"
    go (c : cs) = maybe (go cs) (const (pure c)) =<< findExecutable c

-- | First available of @$VISUAL@, @$EDITOR@, then nvim/vim/vi.
pickEditor :: IO String
pickEditor = do
  env <- catMaybes <$> mapM lookupEnv ["VISUAL", "EDITOR"]
  go (env <> ["nvim", "vim", "vi"])
  where
    go []       = pure "vim"
    go (c : cs) = case words c of
      []      -> go cs
      (p : _) -> maybe (go cs) (const (pure p)) =<< findExecutable p

-- | Parse and render a stored item to Markdown (shared by preview and edit).
renderStored :: ItemType -> Stored -> T.Text
renderStored t s = case parseMaybe parseJSON (sItem s) of
  Nothing -> "_(failed to parse stored item)_"
  Just m  -> renderMarkdown t m (mapMaybe (parseMaybe parseJSON) (sNotes s))

-- | The invocation prefix fzf should use to call us back, carrying the same
-- host/project/data-dir/style. Prefers @GITLAB_INDEX_SELF@ (set by the Nix
-- wrapper, so @glow@ etc. are on PATH) over the raw exe path.
mkPreviewCmd :: Config -> IO String
mkPreviewCmd cfg = do
  exe  <- getExecutablePath
  self <- fromMaybe exe <$> lookupEnv "GITLAB_INDEX_SELF"
  let base = [ shq self, "--host", shq (cfgHost cfg), "--project", shq (cfgProject cfg)
             , "--style", shq (cfgStyle cfg) ]
           ++ maybe [] (\d -> ["--data-dir", shq d]) (cfgDataBase cfg)
           ++ maybe [] (\r -> ["--repo", shq r]) (cfgRepo cfg)
  pure (unwords base)

-- | Single-quote a string for safe interpolation into a shell command.
shq :: String -> String
shq s = "'" <> concatMap esc s <> "'"
  where
    esc '\'' = "'\\''"
    esc c    = [c]
