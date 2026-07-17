-- | Render a GHC eventlog (from -ddump-timings +RTS -l) as a work-vs-waiting
-- activity timeline: an interactive Vega-Lite webpage.
--
-- Extract class-labelled intervals from the events ('intervals'), then show
-- the highest-priority class at every instant ('overlay'). Waiting inside a
-- systool span is thereby attributed to that tool, not to the anonymous
-- foreign calls doing the waiting. See also ghc-events-analyze.
{-# LANGUAGE QuasiQuotes #-}
module Main where

import GHC.RTS.Events
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import qualified Data.Set as Set
import qualified Data.Map.Strict as M
import qualified Data.IntervalMap.Strict as IM
import Data.Interval (Extended(Finite), (<=..<), lowerBound, upperBound)
import Data.Aeson (encode)
import Data.Aeson.QQ (aesonQQ)
import Control.Monad (mfilter)
import Data.List (sortOn, isPrefixOf, stripPrefix)
import qualified Data.List.NonEmpty as NE
import Data.Ord (Down(..))
import Data.Maybe (fromMaybe)
import System.IO (hPutStrLn, stderr)
import Text.Printf (hPrintf)
import GHC.Generics (Generic)
import Options.Generic (ParseRecord, getRecord)

data Options = Options
  { input  :: FilePath
  , output :: FilePath
  } deriving Generic
instance ParseRecord Options

type Seconds = Double
type Iv      = (Seconds, Seconds, Class)

-- | Timeline categories; the derived 'Ord' is the overlay priority. Foreign
-- ranks low because housekeeping threads sit in foreign calls all run long.
data Class = Work | GC | Systool String | Blocked String | Foreign | Idle
  deriving (Eq, Ord)

className :: Class -> String
className Work        = "work"
className GC          = "GC"
className (Systool s) = s
className (Blocked s) = s
className Foreign     = "foreign (non-systool)"
className Idle        = "idle"

-- | Why a stopped thread is stopped. Idle spells never show (lowest priority).
classify :: ThreadStopStatus -> Class
classify ThreadFinished                = Idle
classify ThreadYielding                = Idle
classify HeapOverflow                  = GC
classify ForeignCall                   = Foreign
classify BlockedOnBlackHole            = Blocked "blocked on black hole"
classify (BlockedOnBlackHoleOwnedBy _) = Blocked "blocked on black hole"
classify other                         = Blocked (showThreadStopStatus other)

secs :: Timestamp -> Seconds
secs t = fromIntegral t / 1e9

--------------------------------------------------------------------------------
-- Stage 1: eventlog -> class-labelled intervals
--------------------------------------------------------------------------------

-- | An independent source of activity.
data Source = Running Int | GCing Int | Stopped ThreadId | Tool String
  deriving (Eq, Ord)

-- | The activities an event starts (Just their class) or ends (Nothing).
changes :: Event -> [(Source, Maybe Class)]
changes ev = case (evCap ev, evSpec ev) of
  (Just cap, RunThread tid)      -> [(Running cap, Just Work), (Stopped tid, Nothing)]
  (Just cap, StopThread tid why) -> [(Running cap, Nothing), (Stopped tid, Just (classify why))]
  (Just cap, StartGC)            -> [(GCing cap, Just GC)]
  (Just cap, EndGC)              -> [(GCing cap, Nothing)]
  (_, UserMarker msg)            -- GHC's withTiming markers around systool calls
    | Just nm <- timed "GHC:started: "  -> [(Tool nm, Just (Systool nm))]
    | Just nm <- timed "GHC:finished: " -> [(Tool nm, Nothing)]
    where timed prefix = mfilter ("systool:" `isPrefixOf`) (stripPrefix prefix (T.unpack msg))
  _ -> []

-- | All class-labelled intervals. A source is active where its opens (Just)
-- outnumber its closes (Nothing), so treat opens/closes as brackets and track
-- the nesting depth, emitting one interval each time the depth returns to zero.
-- This makes the tricky cases facts rather than coincidences: nested/overlapping
-- opens (systool spans) merge into a single interval; a close with nothing open
-- is a no-op ("can't close what isn't open"); a spell still open at the end of
-- the log ends there.
intervals :: [Event] -> [Iv]
intervals evs = concatMap spells (M.elems bySource)
  where
    bySource = reverse <$> M.fromListWith (++)   -- per source, in time order
      [ (src, [(secs (evTime ev), c)]) | ev <- evs, (src, c) <- changes ev ]
    tEnd = secs (evTime (last evs))
    spells = go 0 Nothing   -- depth, and the start/class of the open run (if any)
      where
        go :: Int -> Maybe (Seconds, Class) -> [(Seconds, Maybe Class)] -> [Iv]
        go d open []                           = [ (s, tEnd, c) | d > 0, Just (s, c) <- [open] ]
        go 0 _    ((_, Nothing) : cs)          = go 0 Nothing cs        -- stray close
        go 0 _    ((t, Just c)  : cs)          = go 1 (Just (t, c)) cs  -- open a run
        go d open ((_, Just _)  : cs)          = go (d + 1) open cs     -- nested open
        go 1 (Just (s, c)) ((e, Nothing) : cs) = (s, e, c) : go 0 Nothing cs  -- close run
        go d open ((_, Nothing) : cs)          = go (d - 1) open cs     -- close inner

--------------------------------------------------------------------------------
-- Stage 2: overlay intervals by priority
--------------------------------------------------------------------------------

-- | At every instant, keep the minimum (= highest-priority) class among the
-- intervals covering it: an interval map resolving overlaps with 'min'. Its
-- slices come out ascending and gapless (the Idle background covers the whole
-- log), so runs of equal-class slices merge, first start to last end.
overlay :: [Iv] -> [Iv]
overlay ivs =
    [ (a, b, c)
    | run <- NE.groupWith (\(_, _, c) -> c) slices
    , let (a, _, c) = NE.head run
          (_, b, _) = NE.last run ]
  where
    slices = [ (a, b, c)
             | (iv, c) <- IM.toAscList (IM.fromListWith min
                            [ (Finite a <=..< Finite b, c) | (a, b, c) <- ivs ])
             , Finite a <- [lowerBound iv], Finite b <- [upperBound iv] ]

-- | The timeline: the intervals overlaid on a whole-log Idle background.
analyse :: [Event] -> [Iv]
analyse []            = []
analyse evs@(ev0 : _) = overlay (background : intervals evs)
  where background = (secs (evTime ev0), secs (evTime (last evs)), Idle)

--------------------------------------------------------------------------------
-- Interactive Vega-Lite webpage
--------------------------------------------------------------------------------

-- | Categories with a meaning get a fixed colour; the rest cycle a palette.
colorsOf :: [Class] -> [String]
colorsOf classes = [ fromMaybe p (lookup c fixed) | (c, p) <- zip classes (cycle palette) ]
  where
    fixed = [ (Work, "#2ca02c"), (GC, "#1f77b4")
            , (Systool "systool:as", "#d62728"), (Systool "systool:hs-cpp", "#ff7f0e")
            , (Systool "systool:linker", "#8c564b"), (Systool "systool:cc", "#9467bd") ]
    palette = ["#e377c2","#17becf","#bcbd22","#9edae5","#c49c94","#f7b6d2","#dbdb8d"]

renderHtml :: FilePath -> [Iv] -> IO ()
renderHtml out segs = writeFile out page
  where
    tEnd    = maximum (0 : [ b | (_,b,_) <- segs ])
    classes = Set.toList (Set.fromList [ c | (_,_,c) <- segs ])
    rows    = [ [aesonQQ| {"start": #{a}, "end": #{b}, "dur": #{b-a}, "cat": #{className c}} |]
              | (a,b,c) <- segs ]
    vlSpec = [aesonQQ|
      { "$schema": "https://vega.github.io/schema/vega-lite/v5.json",
        "width": "container", "height": 60,
        "data": { "values": #{rows} },
        "mark": { "type": "rect", "tooltip": true },
        "params": [
          { "name": "zoom", "bind": "scales",
            "select": { "type": "interval", "encodings": ["x"] } },
          { "name": "legendSel", "bind": "legend",
            "select": { "type": "point", "fields": ["cat"] } }
        ],
        "encoding": {
          "x":  { "field": "start", "type": "quantitative",
                  "title": "wall-clock time (s)",
                  "scale": { "domain": [0, #{tEnd}] } },
          "x2": { "field": "end" },
          "color": { "field": "cat", "type": "nominal",
                     "scale": { "domain": #{map className classes},
                                "range":  #{colorsOf classes} },
                     "legend": { "title": "category" } },
          "opacity": { "condition": { "param": "legendSel", "value": 1 },
                       "value": 0.25 },
          "tooltip": [
            { "field": "cat",   "title": "category" },
            { "field": "start", "type": "quantitative", "format": ".3f" },
            { "field": "end",   "type": "quantitative", "format": ".3f" },
            { "field": "dur",   "type": "quantitative", "format": ".3f" }
          ]
        },
        "config": { "view": { "stroke": null } }
      } |]
    page = unlines
      [ "<!doctype html><html><head><meta charset=utf-8>"
      , "<script src=\"https://cdn.jsdelivr.net/npm/vega@5\"></script>"
      , "<script src=\"https://cdn.jsdelivr.net/npm/vega-lite@5\"></script>"
      , "<script src=\"https://cdn.jsdelivr.net/npm/vega-embed@6\"></script>"
      , "<style>#vis{width:100%}</style></head><body><div id=vis></div>"
      , "<script>vegaEmbed('#vis'," ++ BLC.unpack (encode vlSpec)
          ++ ",{renderer:'canvas'});</script></body></html>"
      ]

--------------------------------------------------------------------------------

main :: IO ()
main = do
  opts <- getRecord (T.pack "Render a GHC eventlog as a work-vs-waiting activity timeline")
  putStrLn "Make sure the .eventlog file was produced by running ghc with '-ddump-timings +RTS -l -RTS'"
  el <- either (fail . ("parse error: " ++)) pure =<< readEventLogFromFile (input opts)
  let timeline = analyse (sortEvents (events (dat el)))
      totals   = M.fromListWith (+) [ (c, b-a) | (a,b,c) <- timeline ]
  hPutStrLn stderr "seconds per category:"
  sequence_ [ hPrintf stderr "  %-24s %8.3f s\n" (className c) d
            | (c, d) <- sortOn (Down . snd) (M.toList totals) ]
  renderHtml (output opts) timeline
  hPutStrLn stderr ("wrote " ++ output opts)
