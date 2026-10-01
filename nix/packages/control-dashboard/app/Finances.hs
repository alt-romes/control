{-# LANGUAGE TypeApplications #-}
-- | When hledger journals were last reconciled.
module Finances (lastReconciled) where

import Control.Exception (SomeException, try)
import Data.Maybe (fromMaybe)
import Data.Time (Day)
import Hledger (definputopts, jtxns, pbalanceassertion, pdate, readJournalFile, runExceptT, tdate, tpostings)

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
