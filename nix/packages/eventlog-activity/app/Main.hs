-- | Render a GHC eventlog (produced with -ddump-timings +RTS -l -RTS) as a
-- work-vs-waiting activity timeline: a static PNG, or --html for an interactive
-- Vega-Lite webpage. Work takes precedence: any instant with a running mutator
-- thread is "work", never waiting. GC is its own category.
--
-- See also ghc-events-analyze
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import GHC.RTS.Events
import GHC.RTS.Events.Incremental (readEventLog)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import qualified Data.Set as Set
import qualified Data.Map.Strict as M
import qualified Data.Aeson as A
import Data.List (sortBy, foldl', isPrefixOf, find, stripPrefix)
import Data.Ord (comparing)
import Data.Maybe (fromMaybe)
import Data.Colour.SRGB (sRGB24read)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)
import GHC.Generics (Generic)
import Options.Generic (ParseRecord, getRecord)

import Graphics.Rendering.Chart.Easy
import Graphics.Rendering.Chart.Backend.Cairo (renderableToFile, FileOptions(..))

data Options = Options
  { input  :: FilePath
  , output :: FilePath
  , html   :: Bool
  , width  :: Maybe Int
  , height :: Maybe Int
  } deriving Generic
instance ParseRecord Options

-- | The three top-level categories.
data Class = Work | GC | Wait String
  deriving (Eq, Ord, Show)

className :: Class -> String
className Work      = "work"
className GC        = "GC"
className (Wait s)  = s

hexOf :: Class -> String
hexOf Work                       = "#2ca02c"
hexOf GC                         = "#1f77b4"
hexOf (Wait "systool:as")        = "#d62728"
hexOf (Wait "systool:hs-cpp")    = "#ff7f0e"
hexOf (Wait "systool:linker")    = "#8c564b"
hexOf (Wait "systool:cc")        = "#9467bd"
hexOf (Wait s)                   = palette !! (hash s `mod` length palette)
  where hash = foldl' (\a c -> a * 31 + fromEnum c) 7
        palette = ["#e377c2","#17becf","#bcbd22","#9edae5","#c49c94","#f7b6d2","#dbdb8d"]

colorOf :: Class -> AlphaColour Double
colorOf = opaque . sRGB24read . hexOf

-- | Classify why the machine is idle from the stop reason of the thread whose
-- stop emptied the run queue, plus the active withTiming span stack.
classify :: ThreadStopStatus -> [String] -> Class
classify st stack = case showThreadStopStatus st of
  "heap overflow"         -> GC
  "making a foreign call" ->
    Wait (fromMaybe "foreign (non-systool)" (find ("systool:" `isPrefixOf`) stack))
  other
    | "blocked on black hole" `isPrefixOf` other -> Wait "blocked on black hole"
    | otherwise                                  -> Wait other

--------------------------------------------------------------------------------
-- Eventlog -> timeline segments
--------------------------------------------------------------------------------

data S = S
  { running  :: !(Set.Set Int)
  , spans    :: ![String]
  , reason   :: !Class
  , segStart :: !Double
  , curClass :: !Class
  , segs     :: ![(Double, Double, Class)]
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

marker :: String -> [String] -> [String]
marker m st
  | Just nm <- stripPrefix "GHC:started: "  m = nm : st
  | Just nm <- stripPrefix "GHC:finished: " m = dropFirst nm st
  | otherwise                                 = st
  where dropFirst nm xs = case break (== nm) xs of
                            (pre, _:post) -> pre ++ post
                            (pre, [])     -> pre

merge :: [(Double, Double, Class)] -> [(Double, Double, Class)]
merge ((a0,_,ca):(_,b1,cb):rest) | ca == cb = merge ((a0, b1, ca) : rest)
merge (x:rest) = x : merge rest
merge []       = []

timeline :: [Event] -> [(Double, Double, Class)]
timeline evs = merge (reverse ((segStart sN, tEnd, curClass sN) : segs sN))
  where t0   = secs (evTime (head evs))
        tEnd = secs (evTime (last evs))
        sN   = foldl' step (S Set.empty [] (Wait "idle") t0 Work []) evs

--------------------------------------------------------------------------------
-- PNG (Chart + cairo)
--------------------------------------------------------------------------------

catPlot :: Class -> [(Double, Double)] -> Plot Double Double
catPlot cls rects = Plot
  { _plot_render = \pmap ->
      withFillStyle (solidFillStyle (colorOf cls)) $
        mapM_ (\(x0,x1) -> fillPath (rectPath (Rect (pmap (LValue x0, LValue 0))
                                                    (pmap (LValue x1, LValue 1))))) rects
  , _plot_legend = [(className cls, \r -> withFillStyle (solidFillStyle (colorOf cls))
                                            (fillPath (rectPath r)))]
  , _plot_all_points = (concatMap (\(a,b) -> [a,b]) rects, [0,1])
  }

renderPng :: Int -> Int -> FilePath -> [(Double, Double, Class)] -> IO ()
renderPng w h out ss = do
  let byCls = M.toList (M.fromListWith (++) [ (c, [(a,b)]) | (a,b,c) <- ss ])
      layout = def
        & layout_title .~ "GHC activity over time (work vs waiting)"
        & layout_x_axis . laxis_title .~ "wall-clock time (s)"
        & layout_y_axis . laxis_override .~
            (\ad -> ad { _axis_visibility = AxisVisibility False False False })
        & layout_plots .~ [ catPlot c rects | (c, rects) <- byCls ]
        & layout_legend .~ Just def
        :: Layout Double Double
  _ <- renderableToFile (def { _fo_size = (w,h) }) out (toRenderable layout)
  pure ()

--------------------------------------------------------------------------------
-- Interactive Vega-Lite webpage
--------------------------------------------------------------------------------

renderHtml :: FilePath -> [(Double, Double, Class)] -> IO ()
renderHtml out ss = writeFile out page
  where
    s = A.String
    (.=) :: A.ToJSON v => A.Key -> v -> (A.Key, A.Value)
    (.=) = (A..=)          -- shadow Chart.Easy's .= within this spec builder
    tEnd    = maximum (0 : [ b | (_,b,_) <- ss ])
    classes = Set.toList (Set.fromList [ c | (_,_,c) <- ss ])
    rows    = [ A.object ["start" .= a, "end" .= b, "dur" .= (b-a), "cat" .= className c]
              | (a,b,c) <- ss ]
    qfmt f  = A.object ["field" .= s f, "type" .= s "quantitative", "format" .= s ".3f"]
    spec = A.object
      [ "$schema" .= s "https://vega.github.io/schema/vega-lite/v5.json"
      , "width" .= s "container", "height" .= (140 :: Int)
      , "data" .= A.object ["values" .= rows]
      , "mark" .= A.object ["type" .= s "rect", "tooltip" .= True]
      , "params" .=
          [ A.object ["name" .= s "zoom", "bind" .= s "scales"
                     , "select" .= A.object ["type" .= s "interval", "encodings" .= [s "x"]]]
          , A.object ["name" .= s "legendSel", "bind" .= s "legend"
                     , "select" .= A.object ["type" .= s "point", "fields" .= [s "cat"]]]
          ]
      , "encoding" .= A.object
          [ "x"  .= A.object ["field" .= s "start", "type" .= s "quantitative"
                             , "title" .= s "wall-clock time (s)"
                             , "scale" .= A.object ["domain" .= [0 :: Double, tEnd]]]
          , "x2" .= A.object ["field" .= s "end"]
          , "color" .= A.object
              [ "field" .= s "cat", "type" .= s "nominal"
              , "scale" .= A.object ["domain" .= map className classes
                                    , "range"  .= map hexOf classes]
              , "legend" .= A.object ["title" .= s "category"] ]
          , "opacity" .= A.object
              [ "condition" .= A.object ["param" .= s "legendSel", "value" .= (1 :: Double)]
              , "value" .= (0.25 :: Double) ]
          , "tooltip" .=
              [ A.object ["field" .= s "cat", "title" .= s "category"]
              , qfmt "start", qfmt "end", qfmt "dur" ]
          ]
      , "config" .= A.object ["view" .= A.object ["stroke" .= A.Null]]
      ]
    page = unlines
      [ "<!doctype html><html><head><meta charset=utf-8>"
      , "<script src=\"https://cdn.jsdelivr.net/npm/vega@5\"></script>"
      , "<script src=\"https://cdn.jsdelivr.net/npm/vega-lite@5\"></script>"
      , "<script src=\"https://cdn.jsdelivr.net/npm/vega-embed@6\"></script>"
      , "<style>#vis{width:100%}</style></head><body><div id=vis></div>"
      , "<script>vegaEmbed('#vis'," ++ BLC.unpack (A.encode spec)
          ++ ",{renderer:'canvas'});</script></body></html>"
      ]

--------------------------------------------------------------------------------

main :: IO ()
main = do
  putStrLn "Make sure the .eventlog file was produced by running ghc with '-ddump-timings +RTS -l -RTS'"
  opts <- getRecord "Render a GHC eventlog as a work-vs-waiting activity timeline"
  bs <- BL.readFile (input opts)
  case readEventLog bs of
    Left err      -> ioError (userError ("parse error: " ++ err))
    Right (el, _) -> case sortBy (comparing evTime) (events (dat el)) of
      []  -> ioError (userError "no events")
      evs -> do
        let ss = timeline evs
            totals = M.fromListWith (+) [ (c, b-a) | (a,b,c) <- ss ]
        hPutStrLn stderr "seconds per category:"
        mapM_ (\(c,d) -> hPutStrLn stderr (printf "  %-24s %8.3f s" (className c) d))
              (sortBy (comparing (negate . snd)) (M.toList totals))
        if html opts
          then renderHtml (output opts) ss
          else renderPng (fromMaybe 1800 (width opts)) (fromMaybe 260 (height opts))
                         (output opts) ss
        hPutStrLn stderr ("wrote " ++ output opts)
