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
-- Usage:
--   prof-diff-test <baseA> <rootA> <baseB> <rootB> <test>...
--
-- Runtime CLIs (hadrian-util, flamegraph.pl, difffolded.pl) must be on PATH:
-- the Nix wrapper puts them there, so set up the nix environment before running.

module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.Aeson (FromJSON (..), decode, withObject, (.!=), (.:), (.:?))
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as Map
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showFFloat)
import System.Directory
import System.Environment (getArgs, getEnvironment, getProgName)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.FilePath ((<.>), (</>))
import System.IO
import System.Process (callCommand, createProcess, cwd, env, proc, waitForProcess)

-- ---------------------------------------------------------------------------
-- Profile model (subset of GHC's -pj JSON; unknown fields are ignored)

data Measure = Alloc | Ticks

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

data Opts = Opts
  { optOut :: Maybe FilePath
  , optJ :: Int
  , optMeasure :: Measure
  , optFlavourCheck :: Bool
  }

defOpts :: Opts
defOpts = Opts {optOut = Nothing, optJ = 8, optMeasure = Alloc, optFlavourCheck = True}

usageText :: String
usageText =
  unlines
    [ "Usage: prof-diff-test [options] <baseA> <rootA> <baseB> <rootB> <test>..."
    , ""
    , "  <baseA>/<baseB>   path to each GHC source worktree"
    , "  <rootA>/<rootB>   hadrian-util build-root *name* (\"\"/default => _build,"
    , "                    \"debug\" => _build-debug, ...)"
    , "  <test>...         one or more testsuite tests (each --only=); accepts"
    , "                    several args and/or a space-separated string. One"
    , "                    hadrian run per tree per test; artifacts in <out>/<test>/."
    , ""
    , "Options:"
    , "  -o DIR    output/work directory (default: a temp dir)"
    , "  -j N      hadrian parallelism (default: 8)"
    , "  -m M      measurement: alloc (bytes, default) or ticks (time)"
    , "  --no-flavour-check   don't require +profiled_ghc in the flavour"
    , "  -h        this help"
    ]

die :: String -> IO a
die msg = do
  pn <- getProgName
  hPutStrLn stderr (pn ++ ": error: " ++ msg)
  exitFailure

note :: String -> IO ()
note msg = do
  pn <- getProgName
  hPutStrLn stderr (pn ++ ": " ++ msg)

parseArgs :: [String] -> IO (Opts, (FilePath, String, FilePath, String, [String]))
parseArgs = go defOpts []
  where
    go o pos [] = finish o (reverse pos)
    go o pos (a : as) = case a of
      "-o" -> need as $ \v rest -> go o {optOut = Just v} pos rest
      "-j" -> need as $ \v rest -> case reads v of [(n, "")] -> go o {optJ = n} pos rest; _ -> die ("-j expects an integer, got '" ++ v ++ "'")
      "-m" -> need as $ \v rest -> do m <- parseMeasure v; go o {optMeasure = m} pos rest
      "--no-flavour-check" -> go o {optFlavourCheck = False} pos as
      "-h" -> putStr usageText >> exitSuccess
      "--help" -> putStr usageText >> exitSuccess
      "--" -> finish o (reverse pos ++ as)
      _
        | "-" `isPrefixOf` a -> die ("unknown option: " ++ a ++ " (try -h)")
        | otherwise -> go o (a : pos) as
    need as k = case as of (v : rest) -> k v rest; [] -> die "missing option argument"
    parseMeasure "alloc" = pure Alloc
    parseMeasure "ticks" = pure Ticks
    parseMeasure x = die ("-m must be 'alloc' or 'ticks', got '" ++ x ++ "'")
    -- Positions 5.. are test specs; split each on whitespace so both
    --   ... rootB "T1 T2 T3"   and   ... rootB T1 T2 T3   work.
    finish o pos = case pos of
      (ba : ra : bb : rb : rest@(_ : _)) -> case concatMap words rest of
        [] -> bad "no test names given"
        tests -> pure (o, (ba, ra, bb, rb, tests))
      _ -> bad ("expected at least 5 positional args, got " ++ show (length pos))
      where
        bad msg = do note msg; hPutStr stderr usageText; exitFailure

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
-- Running one test in one tree, writing a single JSON profile to <stem>.prof

runTree :: Opts -> String -> FilePath -> String -> String -> FilePath -> IO ()
runTree opts label base root test stem = do
  -- The default build root is selected by omitting -d; a named root with -d.
  let dargs = if root `elem` ["", "default", "_build"] then [] else ["-d", root]
      args =
        ["run"] ++ dargs
          ++ ["test", "--only=" ++ test, "--keep-test-files", "--freeze1", "-j" ++ show (optJ opts)]
  -- EXTRA_HC_OPTS is folded by hadrian into ghc_compiler_always_flags, so every
  -- test compile runs the profiled GHC with these RTS options; -pj writes JSON
  -- to <stem>.prof.  A fixed stem => a single file (last invocation wins).
  baseEnv <- getEnvironment
  let procEnv = ("EXTRA_HC_OPTS", "+RTS -pj -po" ++ stem ++ " -RTS") : filter ((/= "EXTRA_HC_OPTS") . fst) baseEnv
  note ("[" ++ label ++ "] running '" ++ test ++ "' with +RTS -pj  (-> " ++ stem ++ ".prof)")
  (_, _, _, ph) <- createProcess (proc "hadrian-util" args) {cwd = Just base, env = Just procEnv}
  ec <- waitForProcess ph
  case ec of
    ExitSuccess -> pure ()
    _ -> note ("[" ++ label ++ "] hadrian-util exited non-zero (test may have failed); checking for a profile anyway")
  let prof = stem ++ ".prof"
  ok <- doesFileExist prof
  unless ok $
    die ("[" ++ label ++ "] no profile at " ++ prof ++ " — is the compiler built with +profiled_ghc, and did '" ++ test ++ "' actually compile something?")

-- Fold a single JSON profile file to a folded-stacks file, returning the
-- profile's total measure.
foldProf :: Measure -> FilePath -> FilePath -> IO Integer
foldProf measure prof outFold = do
  bs <- BL.readFile prof
  case decode bs of
    Nothing -> die ("invalid/empty JSON profile: " ++ prof)
    Just p -> do
      let folded = foldProfile measure p
      when (null folded) $ die ("folded output empty for " ++ prof ++ " (no cost centres with >0 " ++ measureFlag measure ++ "?)")
      writeFile outFold (renderFolded folded)
      pure (profileTotal measure p)

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

-- Human summary of the A->B change in the total measure.
reportTotal :: Measure -> String -> Integer -> Integer -> IO ()
reportTotal measure test a b =
  note (test ++ ": total " ++ measureFlag measure ++ " " ++ show a ++ " -> " ++ show b ++ "  (" ++ signed (b - a) ++ ", " ++ pct ++ ")")
  where
    signed n = (if n >= 0 then "+" else "") ++ show n
    pct
      | a == 0 = "n/a"
      | otherwise =
          let p = fromIntegral (b - a) / fromIntegral a * 100 :: Double
           in (if p >= 0 then "+" else "") ++ showFFloat (Just 1) p "%"

-- Process one test: run both trees, fold, render -- everything lands in tout.
processTest :: Opts -> (FilePath, String) -> (FilePath, String) -> FilePath -> String -> IO ()
processTest opts (baseA, rootA) (baseB, rootB) tout test = do
  createDirectoryIfMissing True tout
  let measure = optMeasure opts
      stemA = tout </> "treeA"
      stemB = tout </> "treeB"
      -- run the test under one tree and fold its profile to <stem>.folded,
      -- returning the tree's total measure.
      profileTree label base root stem = do
        runTree opts label base root test stem
        foldProf measure (stem <.> "prof") (stem <.> "folded")
  totalA <- profileTree "A" baseA rootA stemA
  totalB <- profileTree "B" baseB rootB stemB
  reportTotal measure test totalA totalB

  let foldedA = stemA <.> "folded"
      foldedB = stemB <.> "folded"
      -- difffolded before->after: width = after; red = more in after.
      diffTitle before after =
        test ++ " diff: " ++ before ++ " -> " ++ after
          ++ "  (width=" ++ after ++ "; red=more in " ++ after ++ ", blue=less)"
  callCommand (flamegraphCmd measure (test ++ " - tree A (" ++ rootA ++ ")") foldedA (stemA <.> "svg"))
  callCommand (flamegraphCmd measure (test ++ " - tree B (" ++ rootB ++ ")") foldedB (stemB <.> "svg"))
  callCommand (diffCmd measure (diffTitle rootA rootB) foldedA foldedB (tout </> "diff.svg"))
  callCommand (diffCmd measure (diffTitle rootB rootA) foldedB foldedA (tout </> "diff-reverse.svg"))

main :: IO ()
main = do
  hSetBuffering stderr LineBuffering
  (opts, (baseA, rootA, baseB, rootB, tests)) <- parseArgs =<< getArgs

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

  -- Per-test artifacts land in <out>/<test>/ (one hadrian run per tree per test).
  note ("tests: " ++ unwords tests)
  forM_ tests $ \test -> do
    note ("==== " ++ test ++ " ====")
    processTest opts (baseA, rootA) (baseB, rootB) (out </> test) test

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
        ++ ["  " ++ (out </> test </> "diff.svg") | test <- tests]
  putStrLn out
