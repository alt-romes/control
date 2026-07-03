-- prof-diff-test — differential GHC compiler profiles across two build trees.
--
-- The GHC `+RTS -pj` JSON profile is parsed with aeson, so the fold to Brendan
-- Gregg stacks is total and type-checked.
--
-- Runs one or more testsuite tests under two GHC build trees (each must be built
-- with a +profiled_ghc flavour), capturing a JSON cost-centre profile of *the
-- compiler* (`+RTS -pj`), then per test:
--   1. renders an individual flame graph per tree (flamegraph.pl), and
--   2. renders a differential flame graph A -> B
--      (difffolded.pl | flamegraph.pl, per
--       http://www.brendangregg.com/blog/2014-11-09/differential-flame-graphs.html).
-- The raw <tree>.prof files are JSON and load directly into
-- https://www.speedscope.app/ for per-tree inspection (no differential there).
--
-- How the profile is captured: EXTRA_HC_OPTS="+RTS -pj -po<stem> -RTS", which
-- hadrian folds into ghc_compiler_always_flags, so every test compile runs the
-- (profiled) GHC with those RTS options and -pj writes a JSON profile to
-- <stem>.prof.  We use a fixed <stem> per tree per test and expect a SINGLE
-- file: if a test invokes GHC more than once they all write the same file (last
-- wins) — intentional, we don't separate or merge invocations.
--
-- Heap profiles: if the test declares a residency metric in its all.T
-- (collect_compiler_residency => peak_megabytes_allocated + max_bytes_used),
-- the testsuite driver itself compiles with "+RTS -A256k -i0 -hT -RTS"
-- (RESIDENCY_OPTS in testlib.py), which thanks to -po already writes the heap
-- profile to <stem>.hp — adding our own -hc would abort the RTS with
-- "multiple heap profile options" — so for those tests we only add
-- -l-agu -ol<stem>-heap.eventlog to mirror the heap samples into an eventlog.
-- Only for --heap forced on a non-residency test do we pass -hc ourselves.
-- The peaks are compared and the profiles rendered with hp2pretty (.hp -> SVG)
-- and eventlog2html (.eventlog -> interactive HTML).  --heap / --no-heap
-- force/disable.
--
-- A failure in one test (or one tree) doesn't abort the run: the artifacts
-- that could be produced are, everything missing is reported at the end, and
-- a summary table of all tests closes the run.
--
-- Usage:
--   prof-diff-test <baseA> <rootA> <baseB> <rootB> <test>...
--
-- Runtime CLIs (hadrian-util, flamegraph.pl, difffolded.pl, hp2pretty,
-- eventlog2html) must be on PATH: the Nix wrapper puts them there, so set up
-- the nix environment before running.

{-# LANGUAGE DataKinds #-}

module Main (main) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (filterM, forM, forM_, unless, when)
import Data.Aeson (FromJSON (..), decode, withObject, (.!=), (.:), (.:?))
import qualified Data.ByteString.Lazy as BL
import Data.List (find, intercalate, isInfixOf, isPrefixOf, tails, transpose)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showFFloat)
import Options.Applicative (eitherReader)
import Options.Generic
import System.Directory
import System.Environment (getEnvironment, getProgName)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((<.>), (</>))
import System.IO
import System.Process (callCommand, createProcess, cwd, env, proc, readProcessWithExitCode, waitForProcess)

-- ---------------------------------------------------------------------------
-- Profile model (subset of GHC's -pj JSON; unknown fields are ignored)

data Measure = Alloc | Ticks

instance ParseField Measure where
  readField = eitherReader $ \s -> case s of
    "alloc" -> Right Alloc
    "ticks" -> Right Ticks
    _ -> Left ("expected 'alloc' or 'ticks', got '" ++ s ++ "'")
  metavar _ = "alloc|ticks"

measureFlag :: Measure -> String
measureFlag Alloc = "alloc"
measureFlag Ticks = "ticks"

countName :: Measure -> String
countName Alloc = "bytes"
countName Ticks = "ticks"

data CostCentre = CostCentre
  { ccId :: !Int
  , ccLabel :: !String
  , ccModule :: !String
  }

instance FromJSON CostCentre where
  parseJSON = withObject "CostCentre" $ \o ->
    CostCentre <$> o .: "id" <*> o .: "label" <*> o .: "module"

-- A cost-centre-stack tree node. ticks/alloc are self (exclusive of children).
data Node = Node
  { nId :: !Int
  , nTicks :: !Integer
  , nAlloc :: !Integer
  , nChildren :: ![Node]
  }

instance FromJSON Node where
  parseJSON = withObject "Node" $ \o ->
    Node
      <$> o .: "id"
      <*> (o .:? "ticks" .!= 0)
      <*> (o .:? "alloc" .!= 0)
      <*> (o .:? "children" .!= [])

data Profile = Profile
  { pTotalAlloc :: !Integer
  , pTotalTicks :: !Integer
  , pCostCentres :: ![CostCentre]
  , pTree :: !Node
  }

instance FromJSON Profile where
  parseJSON = withObject "Profile" $ \o ->
    Profile
      <$> (o .:? "total_alloc" .!= 0)
      <*> (o .:? "total_ticks" .!= 0)
      <*> o .: "cost_centres"
      <*> o .: "profile"

profileTotal :: Measure -> Profile -> Integer
profileTotal Alloc = pTotalAlloc
profileTotal Ticks = pTotalTicks

-- Fold a profile to Brendan Gregg folded stacks: one (stack, self-cost) per node.
foldProfile :: Measure -> Profile -> [(String, Integer)]
foldProfile measure p = go "" (pTree p)
  where
    names = Map.fromList [(ccId c, ccModule c ++ "." ++ ccLabel c) | c <- pCostCentres p]
    self n = case measure of Alloc -> nAlloc n; Ticks -> nTicks n
    go prefix n =
      let nm = Map.findWithDefault ('?' : show (nId n)) (nId n) names
          stack = if null prefix then nm else prefix ++ ";" ++ nm
          here = [(stack, self n) | self n > 0]
       in here ++ concatMap (go stack) (nChildren n)

renderFolded :: [(String, Integer)] -> String
renderFolded = unlines . map (\(s, v) -> s ++ " " ++ show v)

-- ---------------------------------------------------------------------------
-- Options

-- Internal options record, assembled from the parsed CLI.
data Opts = Opts
  { optOut :: Maybe FilePath
  , optJ :: Int
  , optMeasure :: Measure
  , optFlavourCheck :: Bool
  , optHeap :: Maybe Bool -- Nothing = auto-detect from the test's declared metrics
  }

-- Command line, parsed with optparse-generic: named options come from CLI's
-- field names (cli prefix stripped, then lisp-cased), positional arguments
-- from Positional's unnamed fields; Args's hand-written ParseRecord instance
-- combines the two generically-derived parsers.
data CLI = CLI
  { cliOut :: Maybe FilePath <?> "Output/work directory (default: a temp dir)"
  , cliJ :: Maybe Int <?> "Hadrian parallelism (default: 8)"
  , cliMeasure :: Maybe Measure <?> "Measurement: alloc (bytes, default) or ticks (time)"
  , cliHeap :: Bool <?> "Force heap profiling on (default: auto — on iff the test declares a residency metric in its all.T)"
  , cliNoHeap :: Bool <?> "Disable heap profiling"
  , cliNoFlavourCheck :: Bool <?> "Don't require +profiled_ghc in the flavour"
  }
  deriving (Generic)

data Positional = Positional
  (FilePath <?> "Path to GHC source worktree A")
  (String <?> "hadrian-util build-root name for A (\"\"/default => _build, debug => _build-debug, ...)")
  (FilePath <?> "Path to GHC source worktree B")
  (String <?> "hadrian-util build-root name for B")
  ([String] <?> "Testsuite tests (each --only=); space-separated strings are split")
  deriving (Generic)

instance ParseRecord Positional

data Args = Args CLI Positional

instance ParseRecord Args where
  parseRecord = Args <$> parseRecordWithModifiers cliMods <*> parseRecord
    where
      cliMods =
        lispCaseModifiers
          { fieldNameModifier = fieldNameModifier lispCaseModifiers . drop (length ("cli" :: String))
          , shortNameModifier = \f -> lookup f [("cliOut", 'o'), ("cliJ", 'j'), ("cliMeasure", 'm')]
          }

-- Interpret the CLI: apply defaults and split each test spec on whitespace so
-- both `... rootB "T1 T2 T3"` and `... rootB T1 T2 T3` work.
interpretArgs :: Args -> (Opts, (FilePath, String, FilePath, String, [String]))
interpretArgs (Args cli (Positional (Helpful baseA) (Helpful rootA) (Helpful baseB) (Helpful rootB) (Helpful testArgs))) =
  (opts, (baseA, rootA, baseB, rootB, concatMap words testArgs))
  where
    opts =
      Opts
        { optOut = unHelpful (cliOut cli)
        , optJ = fromMaybe 8 (unHelpful (cliJ cli))
        , optMeasure = fromMaybe Alloc (unHelpful (cliMeasure cli))
        , optFlavourCheck = not (unHelpful (cliNoFlavourCheck cli))
        , optHeap = case (unHelpful (cliHeap cli), unHelpful (cliNoHeap cli)) of
            (True, _) -> Just True
            (_, True) -> Just False
            _ -> Nothing
        }

die :: String -> IO a
die msg = do
  pn <- getProgName
  hPutStrLn stderr (pn ++ ": error: " ++ msg)
  exitFailure

note :: String -> IO ()
note msg = do
  pn <- getProgName
  hPutStrLn stderr (pn ++ ": " ++ msg)

-- ---------------------------------------------------------------------------
-- Build-root resolution and validation

-- hadrian-util convention: default root => _build, named root => _build-<name>.
resolveBuildDir :: FilePath -> String -> FilePath
resolveBuildDir base root = base </> sub
  where
    sub
      | root `elem` ["", "default", "_build"] = "_build"
      | "_build-" `isPrefixOf` root = root
      | otherwise = "_build-" ++ root

ghcOf :: FilePath -> FilePath
ghcOf dir = dir </> "stage1" </> "bin" </> "ghc" -- stageN ghc lives under stage(N-1)/bin

readFlavour :: FilePath -> IO String
readFlavour dir = do
  let f = dir </> ".flavour"
  ex <- doesFileExist f
  if ex then filter (/= '\n') <$> readFile f else pure ""

checkTree :: Opts -> String -> FilePath -> String -> IO ()
checkTree opts label base root = do
  baseOk <- doesDirectoryExist base
  unless baseOk $ die (label ++ " base path does not exist: " ++ base)
  let dir = resolveBuildDir base root
  dirOk <- doesDirectoryExist dir
  unless dirOk $ die (label ++ " build root not found: " ++ dir ++ " (root name '" ++ root ++ "')")
  let ghc = ghcOf dir
  ghcOk <- doesFileExist ghc
  unless ghcOk $ die (label ++ " compiler not found/built: " ++ ghc)
  flav <- readFlavour dir
  when (optFlavourCheck opts && not ("profiled_ghc" `isInfixOf` flav)) $
    die
      ( label
          ++ " flavour ('"
          ++ (if null flav then "<empty>" else flav)
          ++ "') lacks +profiled_ghc; +RTS -pj needs a profiled compiler. "
          ++ "Rebuild with a +profiled_ghc flavour, or pass --no-flavour-check."
      )
  note (label ++ ": " ++ dir ++ "  (flavour=" ++ (if null flav then "<default>" else flav) ++ ")")

-- ---------------------------------------------------------------------------
-- Heap-measurement detection

-- Metric names that mean a test measures heap rather than total allocations.
-- collect_compiler_residency / collect_residency expand to
-- peak_megabytes_allocated + max_bytes_used, so "residency" catches those.
heapMetricKeywords :: [String]
heapMetricKeywords = ["residency", "peak_megabytes_allocated", "max_bytes_used"]

-- Does <test> declare a residency metric?  Greps <base>/testsuite for the
-- test('<test>' declaration, extracts the (possibly multi-line) test(...) call
-- by paren balance, and looks for the keywords.  False if nothing is found.
testMeasuresHeap :: FilePath -> String -> IO Bool
testMeasuresHeap base test = do
  let dir = base </> "testsuite"
      escRe c = if c `elem` ("\\^$.[]|()*+?{}" :: String) then ['\\', c] else [c]
      pat = "test\\(['\"]" ++ concatMap escRe test ++ "['\"]"
  (ec, outp, _) <- readProcessWithExitCode "grep" ["-rlE", "--include=*.T", pat, dir] ""
  case ec of
    ExitSuccess -> do
      decls <- mapM (fmap (testDecl test) . readFile) (lines outp)
      pure (any (\d -> any (`isInfixOf` d) heapMetricKeywords) decls)
    _ -> do
      note ("could not find a test('" ++ test ++ "' declaration under " ++ dir ++ "; assuming no heap measurement (--heap overrides)")
      pure False

-- The test(...) call for <test> in an all.T's contents, up to the balancing
-- close paren ("" if not present).  Parens in embedded strings/comments would
-- fool the balance, which is fine for a keyword search.
testDecl :: String -> String -> String
testDecl test contents =
  maybe "" balanced (find opens (tails contents))
  where
    opens s = any (`isPrefixOf` s) ["test('" ++ test ++ "'", "test(\"" ++ test ++ "\""]
    balanced = go (0 :: Int)
      where
        go _ [] = []
        go d (c : cs)
          | c == '(' = c : go (d + 1) cs
          | c == ')' = if d == 1 then [c] else c : go (d - 1) cs
          | otherwise = c : go d cs

-- Peak heap of a .hp profile: the largest per-sample sum of the cost-centre
-- byte counts (header lines and non-numeric words fall through the reads).
hpPeak :: FilePath -> IO Integer
hpPeak f = go 0 0 . lines <$> readFile f
  where
    go peak _ [] = peak
    go peak cur (l : ls)
      | "BEGIN_SAMPLE" `isPrefixOf` l = go peak 0 ls
      | "END_SAMPLE" `isPrefixOf` l = go (max peak cur) 0 ls
      | otherwise = case reverse (words l) of
          (w : _) | [(v, "")] <- reads w -> go peak (cur + v) ls
          _ -> go peak cur ls

-- ---------------------------------------------------------------------------
-- Running one test in one tree, writing a single JSON profile to <stem>.prof

-- Extra RTS flags for heap profiling.  Residency tests already compile with
-- "+RTS -A256k -i0 -hT -RTS" from the testsuite driver (RESIDENCY_OPTS), and
-- a second heap profile flag aborts the RTS ("multiple heap profile options"),
-- so there we add only the eventlog flags and let their -hT write <stem>.hp;
-- otherwise (--heap forced on a non-residency test) we pass -hc ourselves,
-- with -i0.01 because test compiles are short and the default 0.1s sampling
-- gives too coarse a picture of the peak.  -l-agu mirrors the heap samples
-- into an eventlog (other event classes suppressed to keep it small, per
-- eventlog2html's recommendation); -ol pins it to our heap stem so nothing
-- lands in the test dirs.
heapRtsFlags :: Bool -> FilePath -> String
heapRtsFlags residency stem =
  (if residency then "" else " -hc -i0.01")
    ++ " -l-agu -ol" ++ (heapStem stem <.> "eventlog")

-- Run the test; returns what went wrong (missing artifacts) rather than dying.
-- heap: Nothing = no heap profiling, Just residency = heap profiling on.
runTree :: Opts -> String -> FilePath -> String -> String -> FilePath -> Maybe Bool -> IO [String]
runTree opts label base root test stem heap = do
  -- The default build root is selected by omitting -d; a named root with -d.
  let dargs = if root `elem` ["", "default", "_build"] then [] else ["-d", root]
      args =
        ["run"] ++ dargs
          ++ ["test", "--only=" ++ test, "--keep-test-files", "--freeze1", "-j" ++ show (optJ opts)]
  -- EXTRA_HC_OPTS is folded by hadrian into ghc_compiler_always_flags, so every
  -- test compile runs the profiled GHC with these RTS options; -pj writes JSON
  -- to <stem>.prof.  A fixed stem => a single file (last invocation wins).
  let rts = "+RTS -pj -po" ++ stem ++ maybe "" (`heapRtsFlags` stem) heap ++ " -RTS"
  baseEnv <- getEnvironment
  let procEnv = ("EXTRA_HC_OPTS", rts) : filter ((/= "EXTRA_HC_OPTS") . fst) baseEnv
  note ("[" ++ label ++ "] running '" ++ test ++ "' with EXTRA_HC_OPTS=\"" ++ rts ++ "\"")
  (_, _, _, ph) <- createProcess (proc "hadrian-util" args) {cwd = Just base, env = Just procEnv}
  ec <- waitForProcess ph
  case ec of
    ExitSuccess -> pure ()
    _ -> note ("[" ++ label ++ "] hadrian-util exited non-zero (test may have failed); checking for a profile anyway")
  let prof = stem <.> "prof"
  profOk <- doesFileExist prof
  heapErrs <- case heap of
    Nothing -> pure []
    Just _ -> do
      let hp = stem <.> "hp"
          ev = heapStem stem <.> "eventlog"
      hpOk <- doesFileExist hp
      -- <stem>.svg is the flame graph, and hp2pretty renders <x>.hp to <x>.svg,
      -- so move the heap profile to its own stem (the eventlog is already
      -- there via -ol).
      when hpOk $ renameFile hp (heapStem stem <.> "hp")
      evOk <- doesFileExist ev
      pure $
        [label ++ ": no heap profile at " ++ hp | not hpOk]
          ++ [label ++ ": no eventlog at " ++ ev | not evOk]
  pure $
    [ label ++ ": no profile at " ++ prof
        ++ " — is the compiler built with +profiled_ghc, and did '" ++ test ++ "' actually compile something?"
    | not profOk
    ]
      ++ heapErrs

-- Stem for heap-profile artifacts (<stem>-heap.hp / <stem>-heap.svg).
heapStem :: FilePath -> FilePath
heapStem stem = stem ++ "-heap"

-- Fold a single JSON profile file to a folded-stacks file, returning the
-- profile's total measure (or what went wrong).
foldProf :: Measure -> FilePath -> FilePath -> IO (Either String Integer)
foldProf measure prof outFold = do
  bs <- BL.readFile prof
  case decode bs of
    Nothing -> pure (Left ("invalid/empty JSON profile: " ++ prof))
    Just p -> do
      let folded = foldProfile measure p
      if null folded
        then pure (Left ("folded output empty for " ++ prof ++ " (no cost centres with >0 " ++ measureFlag measure ++ "?)"))
        else do
          writeFile outFold (renderFolded folded)
          pure (Right (profileTotal measure p))

-- ---------------------------------------------------------------------------
-- flamegraph.pl / difffolded.pl (expected on PATH; set up the nix env first)

-- Single-quote a string for safe embedding in a /bin/sh command.
shq :: String -> String
shq s = "'" ++ concatMap esc s ++ "'"
  where
    esc '\'' = "'\\''"
    esc c = [c]

flamegraphCmd :: Measure -> String -> FilePath -> FilePath -> String
flamegraphCmd measure title folded out =
  "flamegraph.pl --countname " ++ countName measure
    ++ " --title " ++ shq title
    ++ " " ++ shq folded
    ++ " > " ++ shq out

diffCmd :: Measure -> String -> FilePath -> FilePath -> FilePath -> String
diffCmd measure title foldedBefore foldedAfter out =
  -- difffolded.pl A B: width = B, colour = B - A (red = more in B).
  "difffolded.pl " ++ shq foldedBefore ++ " " ++ shq foldedAfter
    ++ " | flamegraph.pl --countname " ++ countName measure
    ++ " --title " ++ shq title
    ++ " > " ++ shq out

-- ---------------------------------------------------------------------------

-- A->B percentage change ("n/a" when A is 0).
pctStr :: Integer -> Integer -> String
pctStr a b
  | a == 0 = "n/a"
  | otherwise =
      let p = fromIntegral (b - a) / fromIntegral a * 100 :: Double
       in (if p >= 0 then "+" else "") ++ showFFloat (Just 1) p "%"

-- Human summary of an A->B change in some quantity.
reportDelta :: String -> String -> Integer -> Integer -> IO ()
reportDelta what test a b =
  note (test ++ ": " ++ what ++ " " ++ show a ++ " -> " ++ show b ++ "  (" ++ signed (b - a) ++ ", " ++ pctStr a b ++ ")")
  where
    signed n = (if n >= 0 then "+" else "") ++ show n

-- 1234567 -> "1,234,567"
grouped :: Integer -> String
grouped n
  | n < 0 = '-' : grouped (negate n)
  | otherwise = reverse (go (reverse (show n)))
  where
    go s = case splitAt 3 s of
      (a, []) -> a
      (a, rest) -> a ++ "," ++ go rest

-- Per-test outcome, for the end-of-run summary.
data TestSummary = TestSummary
  { tsTest :: String
  , tsHeap :: Bool
  , tsTotals :: Maybe (Integer, Integer) -- total measure A/B (Nothing if a tree failed)
  , tsPeaks :: Maybe (Integer, Integer) -- peak heap bytes A/B, when heap-profiled
  , tsErrors :: [String]
  }

-- Aligned summary table; "-" for missing values, peak columns only if any.
summaryTable :: Measure -> [TestSummary] -> String
summaryTable measure rs = unlines (map renderRow rows)
  where
    anyPeaks = any (isJust . tsPeaks) rs
    rows = header : map row rs
    header =
      ["test", "A " ++ measureFlag measure, "B " ++ measureFlag measure, "Δ%"]
        ++ (if anyPeaks then ["A peak", "B peak", "Δpeak%"] else [])
    row r = tsTest r : pair (tsTotals r) ++ (if anyPeaks then pair (tsPeaks r) else [])
    pair (Just (a, b)) = [grouped a, grouped b, pctStr a b]
    pair Nothing = ["-", "-", "-"]
    widths = map (maximum . map length) (transpose rows)
    -- first column left-aligned, the rest right-aligned
    renderRow cols = intercalate "   " (zipWith3 pad [0 :: Int ..] widths cols)
    pad i w s
      | i == 0 = s ++ replicate (w - length s) ' '
      | otherwise = replicate (w - length s) ' ' ++ s

-- Process one test: run both trees, fold, render -- everything lands in tout.
-- Produces whatever artifacts it can; failures end up in tsErrors.
processTest :: Opts -> (FilePath, String) -> (FilePath, String) -> FilePath -> String -> IO TestSummary
processTest opts (baseA, rootA) (baseB, rootB) tout test = do
  createDirectoryIfMissing True tout
  -- heap: Nothing = off, Just residency = on (residency decides -hT vs -hc,
  -- see heapRtsFlags).
  heap <- case optHeap opts of
    Just False -> pure Nothing
    Just True -> Just <$> testMeasuresHeap baseA test
    Nothing -> do
      residency <- testMeasuresHeap baseA test
      pure (if residency then Just True else Nothing)
  forM_ heap $ \residency ->
    note (test ++ ": taking heap profiles (" ++ (if residency then "residency test, testsuite adds -hT" else "+RTS -hc") ++ ")")
  let measure = optMeasure opts
      stemA = tout </> "treeA"
      stemB = tout </> "treeB"
      -- run the test under one tree and fold its profile to <stem>.folded,
      -- returning the tree's total measure if everything worked.
      profileTree label base root stem = do
        runErrs <- runTree opts label base root test stem heap
        profOk <- doesFileExist (stem <.> "prof")
        if not profOk
          then pure (runErrs, Nothing)
          else do
            r <- foldProf measure (stem <.> "prof") (stem <.> "folded")
            pure $ case r of
              Left e -> (runErrs ++ [label ++ ": " ++ e], Nothing)
              Right t -> (runErrs, Just t)
  (errsA, mTotalA) <- profileTree "A" baseA rootA stemA
  (errsB, mTotalB) <- profileTree "B" baseB rootB stemB
  case (mTotalA, mTotalB) of
    (Just a, Just b) -> reportDelta ("total " ++ measureFlag measure) test a b
    _ -> pure ()

  let foldedA = stemA <.> "folded"
      foldedB = stemB <.> "folded"
      -- difffolded before->after: width = after; red = more in after.
      diffTitle before after =
        test ++ " diff: " ++ before ++ " -> " ++ after
          ++ "  (width=" ++ after ++ "; red=more in " ++ after ++ ", blue=less)"
  when (isJust mTotalA) $ callCommand (flamegraphCmd measure (test ++ " - tree A (" ++ rootA ++ ")") foldedA (stemA <.> "svg"))
  when (isJust mTotalB) $ callCommand (flamegraphCmd measure (test ++ " - tree B (" ++ rootB ++ ")") foldedB (stemB <.> "svg"))
  when (isJust mTotalA && isJust mTotalB) $ do
    callCommand (diffCmd measure (diffTitle rootA rootB) foldedA foldedB (tout </> "diff.svg"))
    callCommand (diffCmd measure (diffTitle rootB rootA) foldedB foldedA (tout </> "diff-reverse.svg"))

  peaks <- case heap of
    Nothing -> pure Nothing
    Just _ -> do
      -- hp2pretty renders <x>.hp to <x>.svg next to it; eventlog2html renders
      -- <x>.eventlog to <x>.eventlog.html next to it.  Render what exists.
      renderExisting "hp2pretty" [heapStem s <.> "hp" | s <- [stemA, stemB]]
      renderExisting "eventlog2html" [heapStem s <.> "eventlog" | s <- [stemA, stemB]]
      mpA <- peakOf (heapStem stemA <.> "hp")
      mpB <- peakOf (heapStem stemB <.> "hp")
      case (mpA, mpB) of
        (Just a, Just b) -> do
          reportDelta "peak heap bytes (profiled)" test a b
          pure (Just (a, b))
        _ -> pure Nothing
  pure
    TestSummary
      { tsTest = test
      , tsHeap = isJust heap
      , tsTotals = (,) <$> mTotalA <*> mTotalB
      , tsPeaks = peaks
      , tsErrors = errsA ++ errsB
      }
  where
    peakOf hp = do
      ok <- doesFileExist hp
      if ok then Just <$> hpPeak hp else pure Nothing
    -- Run "<tool> <file>" on each existing file, if tool is on PATH.
    renderExisting tool files = do
      found <- findExecutable tool
      case found of
        Nothing -> note (tool ++ " not on PATH; skipping its rendering (raw files kept)")
        Just _ -> do
          existing <- filterM doesFileExist files
          forM_ existing $ \f -> callCommand (tool ++ " " ++ shq f)

main :: IO ()
main = do
  hSetBuffering stderr LineBuffering
  args <- getRecord "prof-diff-test - differential GHC compiler profiles across two build trees"
  let (opts, (baseA, rootA, baseB, rootB, tests)) = interpretArgs args
  when (null tests) $ die "no test names given"

  checkTree opts "tree A" baseA rootA
  checkTree opts "tree B" baseB rootB

  -- Absolute work dir, so -po stems are absolute.
  out <- case optOut opts of
    Just d -> createDirectoryIfMissing True d >> makeAbsolute d
    Nothing -> do
      tmp <- getTemporaryDirectory
      t <- getPOSIXTime
      let d = tmp </> ("prof-diff-" ++ show (round (t * 1000) :: Integer))
      createDirectoryIfMissing True d
      makeAbsolute d
  note ("work dir: " ++ out)

  let measure = optMeasure opts

  -- Per-test artifacts land in <out>/<test>/ (one hadrian run per tree per
  -- test).  One test failing (even by exception) doesn't stop the others.
  note ("tests: " ++ unwords tests)
  results <- forM tests $ \test -> do
    note ("==== " ++ test ++ " ====")
    r <- try (processTest opts (baseA, rootA) (baseB, rootB) (out </> test) test)
    case r of
      Right s -> pure s
      Left (e :: SomeException) -> do
        note (test ++ ": failed: " ++ displayException e)
        pure TestSummary {tsTest = test, tsHeap = False, tsTotals = Nothing, tsPeaks = Nothing, tsErrors = [displayException e]}

  let anyHeap = any tsHeap results
      failed = [r | r <- results, not (null (tsErrors r))]
  pn <- getProgName
  hPutStr stderr $
    unlines $
      [ ""
      , pn ++ ": done. Artifacts in " ++ out
      , "  per test in <test>/:"
      , "    treeA.prof / treeB.prof   JSON profiles  -> https://www.speedscope.app/"
      , "    treeA.svg  / treeB.svg    individual flame graphs (" ++ measureFlag measure ++ ")"
      , "    diff.svg                  " ++ rootA ++ " -> " ++ rootB ++ "  (width=" ++ rootB ++ "; red=more in " ++ rootB ++ ")"
      , "    diff-reverse.svg          " ++ rootB ++ " -> " ++ rootA ++ "  (width=" ++ rootA ++ "; red=more in " ++ rootA ++ ")"
      ]
        ++ [ "    tree{A,B}-heap.hp/.svg            heap profiles (heap-measured tests only)"
           | anyHeap
           ]
        ++ [ "    tree{A,B}-heap.eventlog(.html)    same heap samples as eventlog / eventlog2html render"
           | anyHeap
           ]
        ++ ["  " ++ (out </> test </> "diff.svg") | test <- tests]
        ++ ["", "==== summary (A = " ++ rootA ++ ", B = " ++ rootB ++ ") ===="]
  hPutStr stderr (summaryTable measure results)
  unless (null failed) $ do
    note (show (length failed) ++ " of " ++ show (length results) ++ " test(s) incomplete:")
    forM_ failed $ \r ->
      forM_ (tsErrors r) $ \e -> hPutStrLn stderr ("  " ++ tsTest r ++ ": " ++ e)
  putStrLn out
  unless (null failed) exitFailure
