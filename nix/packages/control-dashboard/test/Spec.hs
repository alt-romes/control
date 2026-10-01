{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
-- | Checks of how runs are judged: failures, rules, grouping and pruning.
module Main (main) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Rules (..), Timed (..), evtSubtasks, (&), (?~))
import Control.Monad (forM_, unless)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Events
import Network.MQTT.Topic (mkTopic)
import System.Exit (exitFailure)

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

sec :: NominalDiffTime -> UTCTime
sec s = addUTCTime s t0

uuid :: Int -> UUID
uuid n = UUID.fromWords 0 0 0 (fromIntegral n)

-- | A run on a topic starting at a second, maybe finished after some seconds.
run :: Text -> NominalDiffTime -> Maybe (NominalDiffTime, Bool) -> Run
run topic s end = Run
  { topic
  , start = Timed (sec s) EvtMsg {scope = Nothing, rules = Rules {timeout = 300, expected = Nothing, subtasks = Nothing, critical = False}, label = "", content = Nothing}
  , end = (\(took, ok) -> Timed (sec (s + took)) EvtDone {summary = "", success = ok, result = Nothing}) <$> end
  }

expecting :: NominalDiffTime -> Run -> Run
expecting d r = r {start = r.start {x = r.start.x {rules = r.start.x.rules {expected = Just d}}}}

expectingSubtasks :: [String] -> Run -> Run
expectingSubtasks ts r = r {start = r.start {x = r.start.x & evtSubtasks ?~ ts}}

scopedTo :: Int -> Run -> Run
scopedTo p r = r {start = r.start {x = r.start.x {scope = Just (EventId (uuid p) (fromJust (mkTopic "t")))}}}

-- | The problems of the run numbered @n@, among the given runs.
problemsOf :: NominalDiffTime -> [(Int, Run)] -> Int -> [(Text, Text)]
problemsOf now rs n = problems (sec now) (index (Map.fromList [(uuid m, x) | (m, x) <- rs])) (uuid n, fromJust (lookup n rs))

names :: NominalDiffTime -> [(Int, Run)] -> Int -> [Text]
names now rs = map fst . problemsOf now rs

main :: IO ()
main = do
  let ok = Just (1, True)
      a = run "script/a" 0 ok
      checks =
        [ ("a successful run has no problems", names 10 [(1, a)] 1 == [])
        , ("a failed run is failed", let r = run "script/a" 0 (Just (1, False)) in names 10 [(1, r)] 1 == ["failed"])
        , ("an unfinished run past its timeout timed out", let r = run "script/a" 0 Nothing in names 301 [(1, r)] 1 == ["timed out"])
        , ("an unfinished run within its timeout is fine", let r = run "script/a" 0 Nothing in names 299 [(1, r)] 1 == [])
        , ("a slow finish timed out", let r = run "script/a" 0 (Just (400, True)) in names 500 [(1, r)] 1 == ["timed out"])
        , ("a failure and a broken rule are both reported", let r = expecting 60 (run "script/a" 0 (Just (400, False))) in names 1000 [(1, r)] 1 == ["failed", "timed out", "overdue"])
        , ("the next run within expected + grace is fine", let r = expecting 60 a; n = run "script/a" 100 ok in names 200 [(1, r), (2, n)] 1 == [])
        , ("the next run after expected + grace is overdue", let r = expecting 60 a; n = run "script/a" 130 ok in names 200 [(1, r), (2, n)] 1 == ["overdue"])
        , ("the latest run within grace is fine", let r = expecting 60 a in names 90 [(1, r)] 1 == [])
        , ("the latest run past grace is overdue", let r = expecting 60 a in names 121 [(1, r)] 1 == ["overdue"])
        , ("all expected subtasks is fine",
            let r = expectingSubtasks ["x", "y"] a in names 10 [(1, r), (2, scopedTo 1 (run "script/a/x" 0 ok)), (3, scopedTo 1 (run "script/a/y" 0 ok))] 1 == [])
        , ("repeated and unlisted subtasks are fine",
            let r = expectingSubtasks ["x"] a in names 10 [(1, r), (2, scopedTo 1 (run "script/a/x" 0 ok)), (3, scopedTo 1 (run "script/a/x" 0 ok)), (4, scopedTo 1 (run "script/a/z" 0 ok))] 1 == [])
        , ("a missing subtask is reported",
            let r = expectingSubtasks ["x", "y", "z"] a
             in problemsOf 10 [(1, r), (2, scopedTo 1 (run "script/a/x" 0 ok)), (3, scopedTo 1 (run "script/a/x/y" 0 ok))] 1 == [("subtasks", "Missing y, z.")])
        , ("each repeated entry needs its own subtask",
            let r = expectingSubtasks ["x", "x", "y"] a in problemsOf 10 [(1, r), (2, scopedTo 1 (run "script/a/x" 0 ok)), (3, scopedTo 1 (run "script/a/y" 0 ok))] 1 == [("subtasks", "Missing x.")])
        , ("subtasks aren't checked while running", let r = expectingSubtasks ["x"] (run "script/a" 0 Nothing) in names 10 [(1, r)] 1 == [])
        , ("subtasks are checked once timed out", let r = expectingSubtasks ["x"] (run "script/a" 0 Nothing) in names 301 [(1, r)] 1 == ["timed out", "subtasks"])
        , ("a subtask of a known run isn't top-level", map fst (latestRuns (index (Map.fromList [(uuid 1, a), (uuid 2, scopedTo 1 (run "script/a/sub" 0 ok))]))) == [uuid 1])
        , ("a subtask of an unknown run is top-level", map fst (latestRuns (index (Map.fromList [(uuid 2, scopedTo 9 (run "script/a/sub" 0 ok))]))) == [uuid 2])
        , ("a run scoped to a known run off its topic, like a trigger's, is top-level",
            map fst (latestRuns (index (Map.fromList [(uuid 1, run "trigger/a" 0 ok), (uuid 2, scopedTo 1 (run "script/b" 1 ok))]))) == [uuid 2, uuid 1])
        , ("the latest runs are one per topic, newest first",
            map fst (latestRuns (index (Map.fromList [(uuid 1, run "script/b" 20 ok), (uuid 2, run "script/a" 50 ok), (uuid 3, a)]))) == [uuid 2, uuid 1])
        , ("subtasks are newest first",
            map fst (Map.findWithDefault [] (uuid 1) (index (Map.fromList [(uuid 1, a), (uuid 3, scopedTo 1 (run "script/a/y" 5 ok)), (uuid 2, scopedTo 1 (run "script/a/x" 9 ok))])).subtasks)
              == [uuid 2, uuid 3])
        , ("pruning keeps the latest 500 runs of each topic",
            let m = prune (Map.fromList [(uuid n, run "script/a" (fromIntegral n) ok) | n <- [1 .. 20001]])
             in Map.size m == 500 && Map.member (uuid 20001) m && Map.notMember (uuid 19501) m)
        , ("pruning keeps whole trees of the latest top-level runs",
            -- each parent has 3 subtasks; only the 2 oldest parents are pruned
            let parents = [(n, run "script/a" (fromIntegral n) ok) | n <- [1 .. 502]]
                subs = [(1000 * p + k, scopedTo p (run "script/a/x" (fromIntegral p) ok)) | p <- [1 .. 502], k <- [1 .. 3]]
                bulk = [(10 ^ (6 :: Int) + n, run "script/b" 0 ok) | n <- [1 .. 20000 - 2008 + 1]]
                m = prune (Map.fromList [(uuid n, r) | (n, r) <- parents ++ subs ++ bulk])
             in Map.member (uuid 502) m && Map.member (uuid 3003) m && Map.notMember (uuid 2) m && Map.notMember (uuid 2003) m
                  && Map.size m == 500 * 4 + 500)
        , ("pruning leaves small histories alone", Map.size (prune (Map.fromList [(uuid n, a) | n <- [1 .. 100]])) == 100)
        ]
  forM_ checks $ \(name, passed) -> putStrLn ((if passed then "ok   " else "FAIL ") <> name)
  unless (all snd checks) exitFailure
