-- | Incremental synchronisation.
--
-- We list items ordered by @updated_at@ ascending, filtered by
-- @updated_after=<watermark>@. Because GitLab bumps an item's @updated_at@
-- whenever it changes — including when a comment is added — re-fetching the
-- changed items (and their notes) is enough to keep comments in sync. The
-- watermark is nudged back a couple of seconds so items sharing the boundary
-- timestamp are not missed; re-writing an unchanged item is idempotent.
module GitLabIndex.Sync (sync) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_, catch, throwIO)
import Control.Monad (when)
import Data.Aeson (Value, parseJSON)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import System.IO (hFlush, hPutStr, hPutStrLn, stderr)

import GitLabIndex.Config
import GitLabIndex.Glab (GlabError (..), glabPage, glabPaged)
import GitLabIndex.Store
import GitLabIndex.Types

-- | Sync issues then merge requests, then rebuild the index.
sync :: Config -> IO ()
sync cfg = do
  st0 <- loadState cfg
  st1 <- syncTypeSafe cfg st0 Issue
  st2 <- syncTypeSafe cfg st1 MR
  saveState cfg st2
  hPutStrLn stderr "Rebuilding index..."
  buildIndex cfg
  hPutStrLn stderr "Done."

-- | Run 'syncType', but treat a 403/404 (resource disabled or inaccessible —
-- e.g. a project with merge requests turned off) as "skip", not "abort".
syncTypeSafe :: Config -> SyncState -> ItemType -> IO SyncState
syncTypeSafe cfg st t = syncType cfg st t `catch` \e ->
  case geStatus e of
    Just s | s == 403 || s == 404 -> do
      hPutStrLn stderr ("  skipping " <> typeApi t <> " (unavailable: HTTP " <> show s <> ")")
      pure st
    _ -> throwIO e

syncType :: Config -> SyncState -> ItemType -> IO SyncState
syncType cfg st t = do
  let after = watermarkFor st t
      ep0   = "projects/" <> projectApiId cfg <> "/" <> typeApi t
              <> "?per_page=100&order_by=updated_at&sort=asc&pagination=keyset"
              <> maybe "" (\w -> "&updated_after=" <> urlEncode (T.unpack (shiftBack w))) after
  hPutStrLn stderr $ "Syncing " <> typeApi t
                   <> maybe " (full backfill)" (\w -> " updated after " <> T.unpack w) after
                   <> " ..."
  loop ep0 (0 :: Int) (fromMaybe "" after) st
  where
    loop ep done maxUpd stAcc = do
      (vals, next) <- glabPage (cfgHost cfg) ep
      if null vals
        then finish done maxUpd stAcc
        else do
          updates <- mapPool (cfgJobs cfg) (processItem cfg t) vals
          let done'   = done + length vals
              maxUpd' = maximum (maxUpd : updates)
              stAcc'  = checkpoint t maxUpd' stAcc
          hPutStr stderr ("\r  " <> typeApi t <> ": " <> show done' <> " items...")
          hFlush stderr
          saveState cfg stAcc'   -- checkpoint so an interrupted backfill resumes
          case next of
            Nothing  -> finish done' maxUpd' stAcc'
            Just ep' -> loop ep' done' maxUpd' stAcc'

    finish done maxUpd stAcc = do
      when (done > 0) (hPutStr stderr "\r")
      hPutStrLn stderr ("  " <> typeApi t <> ": " <> show done <> " new/updated.")
      pure (checkpoint t maxUpd stAcc)

    checkpoint ty w s = if T.null w then s else setWatermark s ty w

-- | Persist one item: fetch its notes (only if it has any) and write it out.
-- Returns the item's @updated_at@ for watermark tracking.
processItem :: Config -> ItemType -> Value -> IO Text
processItem cfg t v = case parseMaybe parseJSON v of
  Nothing -> pure ""
  Just m  -> do
    notes <-
      if mNotesCount m > 0
        then glabPaged (cfgHost cfg)
               ("projects/" <> projectApiId cfg <> "/" <> typeApi t
                <> "/" <> show (mIid m) <> "/notes?per_page=100&sort=asc&order_by=created_at")
             `catch` \e -> do
               -- Don't let one item's notes (already retried if transient)
               -- abort the whole run; store it without comments and warn.
               hPutStrLn stderr ("\n  warning: no comments for " <> typeApi t <> " #"
                                 <> show (mIid m) <> ": " <> geMessage (e :: GlabError))
               pure []
        else pure []
    writeStored cfg t (mIid m) (Stored v notes)
    pure (mUpdated m)

-- | @mapM@ with bounded concurrency: at most @n@ actions run at once, results
-- kept in input order. Pagination stays sequential (we follow the @Link@
-- header); this parallelises the per-item notes fetches within a page.
mapPool :: Int -> (a -> IO b) -> [a] -> IO [b]
mapPool n f xs
  | n <= 1    = mapM f xs
  | otherwise = do
      sem <- newQSem n
      mapConcurrently (\x -> bracket_ (waitQSem sem) (signalQSem sem) (f x)) xs

-- | Move an ISO-8601 timestamp back 2s, to cover items sharing the boundary.
shiftBack :: Text -> Text
shiftBack w = case parseTimeM True defaultTimeLocale fmt (T.unpack w) of
  Just ts -> T.pack (formatTime defaultTimeLocale fmt (addUTCTime (-2) (ts :: UTCTime)))
  Nothing  -> w
  where fmt = "%Y-%m-%dT%H:%M:%S%QZ"
