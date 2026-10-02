{-# LANGUAGE TypeApplications #-}
-- | When hledger journals were last reconciled.
module Finances (reconciliation) where

import Control.Events (done, evtExpected, failed, simple, (&), (?~))
import Control.Exception (SomeException, try)
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Time (Day, LocalTime (..), TimeZone, UTCTime, localTimeToUTC, midnight, nominalDay)
import Events (Run, localRun)
import Hledger (definputopts, jtxns, pbalanceassertion, pdate, readJournalFile, runExceptT, tdate, tpostings)

-- | A journal's last reconciliation, given as @NAME=PATH@: a run on
-- @journal/NAME@ expected monthly, or a failed one if it's unknown.
reconciliation :: TimeZone -> UTCTime -> String -> IO Run
reconciliation tz started s = do
  d <- lastReconciled (drop 1 path)
  pure $ case d of
    Just day -> localRun tp (localTimeToUTC tz (LocalTime day midnight)) (simple "Reconciled" & evtExpected ?~ 31 * nominalDay) (done "Reconciled" ())
    Nothing -> localRun tp started (simple "Reconciled") (failed "Couldn't tell when it was last reconciled" ())
  where
    (name, path) = break (== '=') s
    tp = fromString ("journal/" <> name)

-- | Reconciliation is recorded as balance assertions, so a journal was last
-- reconciled on the latest date of a posting carrying one. hledger parses the
-- journal, resolving its includes.
lastReconciled :: FilePath -> IO (Maybe Day)
lastReconciled path = do
  res <- try @SomeException (runExceptT (readJournalFile definputopts path))
  pure $ case res of
    Right (Right j) -> foldr (max . Just) Nothing
      [fromMaybe (tdate t) (pdate p) | t <- jtxns j, p <- tpostings t, Just _ <- [pbalanceassertion p]]
    _ -> Nothing
