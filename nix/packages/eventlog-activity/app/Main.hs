-- | Turn a GHC eventlog into a timeline image: along X (wall-clock time) a strip
-- of colored bars showing WORK vs each kind of WAITING, with GC as its own third
-- category. Work takes precedence: any instant where a mutator thread is running
-- is painted as work, never as waiting.
--
-- The log must be produced with  -ddump-timings +RTS -l -RTS  so that GHC emits
-- the "GHC:started: systool:as" / "GHC:finished: systool:as" markers; foreign-call
-- waits are then labeled by which external tool (as/hs-cpp/linker/cc) is running.
--
-- Usage:  eventlog-activity <in.eventlog> <out.png> [width height]

module Main where

import GHC.RTS.Events
import GHC.RTS.Events.Incremental (readEventLog)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Set as Set
import qualified Data.Map.Strict as M
import Data.List (sortBy, foldl', isPrefixOf, find, stripPrefix)
import Data.Ord (comparing)
import Data.Maybe (fromMaybe)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

import Graphics.Rendering.Chart.Easy
import Graphics.Rendering.Chart.Backend.Cairo (renderableToFile, FileOptions(..))

-- | The three top-level categories.
data Class = Work | GC | Wait String
  deriving (Eq, Ord, Show)

className :: Class -> String
className Work      = "work"
className GC        = "GC"
className (Wait s)  = s

-- Fixed colors for the meaningful categories; anything else gets a stable
-- color hashed from its label so it is still distinct and consistent.
colorOf :: Class -> AlphaColour Double
colorOf Work               = opaque forestgreen
colorOf GC                 = opaque steelblue
colorOf (Wait "systool:as")      = opaque red
colorOf (Wait "systool:hs-cpp")  = opaque orange
colorOf (Wait "systool:linker")  = opaque saddlebrown
colorOf (Wait "systool:cc")      = opaque purple
colorOf (Wait s)           = opaque (palette !! (hash s `mod` length palette))
  where hash = foldl' (\a c -> a * 31 + fromEnum c) 7
        palette = [ magenta, teal, olive, deeppink, gold, darkcyan, sienna ]

-- | Classify why the machine is idle, given the RTS stop reason of the thread
-- whose stop emptied the run queue, and the active withTiming span stack.
classify :: ThreadStopStatus -> [String] -> Class
classify st stack = case showThreadStopStatus st of
  "heap overflow"        -> GC
  "making a foreign call" ->
    Wait (fromMaybe "foreign (non-systool)" (find ("systool:" `isPrefixOf`) stack))
  other
    | "blocked on black hole" `isPrefixOf` other -> Wait "blocked on black hole"
    | otherwise                                  -> Wait other

--------------------------------------------------------------------------------
-- Fold the event stream into timeline segments [(start, end, class)].
--------------------------------------------------------------------------------

data S = S
  { running   :: !(Set.Set Int)  -- caps currently executing a thread
  , spans     :: ![String]       -- active withTiming spans, innermost first
  , reason    :: !Class          -- class to use while idle (last stop cause)
  , segStart  :: !Double         -- start time of the current segment
  , curClass  :: !Class          -- class of the current segment
  , segs      :: ![(Double, Double, Class)]
  }

secs :: Timestamp -> Double
secs t = fromIntegral t / 1e9

step :: S -> Event -> S
step s ev =
  let cap = fromMaybe (-1) (evCap ev)
      t   = secs (evTime ev)
      s1  = case evSpec ev of
        RunThread _         -> s { running = Set.insert cap (running s) }
        StopThread _ status -> s { running = Set.delete cap (running s)
                                 , reason  = classify status (spans s) }
        UserMarker m        -> s { spans = marker (T.unpack m) (spans s) }
        _                   -> s
      newClass | Set.null (running s1) = reason s1
               | otherwise             = Work
  in if newClass == curClass s1
       then s1
       else s1 { segs     = (segStart s1, t, curClass s1) : segs s1
               , segStart = t
               , curClass = newClass }

-- push on "GHC:started: X", pop the matching frame on "GHC:finished: X"
marker :: String -> [String] -> [String]
marker m st
  | Just nm <- stripPrefix "GHC:started: "  m = nm : st
  | Just nm <- stripPrefix "GHC:finished: " m = dropFirst nm st
  | otherwise                                 = st
  where dropFirst nm xs = case break (== nm) xs of
                            (pre, _:post) -> pre ++ post
                            (pre, [])     -> pre

-- merge adjacent segments of the same class to keep the rectangle count small
merge :: [(Double, Double, Class)] -> [(Double, Double, Class)]
merge ((a0,a1,ca):(b0,b1,cb):rest)
  | ca == cb  = merge ((a0, b1, ca) : rest)
  | otherwise = (a0,a1,ca) : merge ((b0,b1,cb):rest)
merge xs = xs

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

-- one Chart Plot per class: fills all its rectangles (y in [0,1]) and adds a
-- single legend entry
catPlot :: Class -> [(Double, Double)] -> Plot Double Double
catPlot cls rects = Plot
  { _plot_render = \pmap ->
      withFillStyle (solidFillStyle (colorOf cls)) $
        mapM_ (\(x0,x1) ->
                 fillPath (rectPath (Rect (pmap (LValue x0, LValue 0))
                                          (pmap (LValue x1, LValue 1))))) rects
  , _plot_legend = [(className cls, \r -> withFillStyle (solidFillStyle (colorOf cls))
                                        (fillPath (rectPath r)))]
  , _plot_all_points = (concatMap (\(a,b) -> [a,b]) rects, [0,1])
  }

main :: IO ()
main = do
  args <- getArgs
  (inp, out, w, h) <- case args of
    [i,o]     -> pure (i,o,1800,260)
    [i,o,a,b] -> pure (i,o,read a,read b)
    _         -> ioError (userError "usage: eventlog-activity <in.eventlog> <out.png> [W H]")
  bs <- BL.readFile inp
  case readEventLog bs of
    Left err        -> ioError (userError ("parse error: " ++ err))
    Right (el, _)   -> do
      let evs = sortBy (comparing evTime) (events (dat el))
      case evs of
        [] -> ioError (userError "no events")
        (e0:_) -> do
          let t0 = secs (evTime e0)
              s0 = S Set.empty [] (Wait "idle") t0 Work []
              sN = foldl' step s0 evs
              tEnd = secs (evTime (last evs))
              allSegs = merge $ reverse $ (segStart sN, tEnd, curClass sN) : segs sN
              byClass = toListWith (++)
                          [ (c, [(a,b)]) | (a,b,c) <- allSegs ]
              plots = [ catPlot c rects | (c, rects) <- byClass ]

          -- stderr summary: total seconds per class
          let totals = M.fromListWith (+) [ (c, b-a) | (a,b,c) <- allSegs ]
          hPutStrLn stderr "seconds per category:"
          mapM_ (\(c,d) -> hPutStrLn stderr (printf "  %-24s %8.3f s" (className c) d))
                (sortBy (comparing (negate . snd)) (M.toList totals))

          let layout = def
                & layout_title .~ "GHC activity over time (work vs waiting)"
                & layout_x_axis . laxis_title .~ "wall-clock time (s)"
                & layout_y_axis . laxis_override .~
                    (\ad -> ad { _axis_visibility = AxisVisibility False False False })
                & layout_plots .~ plots
                & layout_legend .~ Just def
                :: Layout Double Double
          _ <- renderableToFile (def { _fo_size = (w,h) }) out (toRenderable layout)
          hPutStrLn stderr ("wrote " ++ out)

-- group (key,val) pairs, concatenating values
toListWith :: Ord k => (v -> v -> v) -> [(k,v)] -> [(k,v)]
toListWith f = M.toList . M.fromListWith f
