{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
-- | Checks of how runs are judged: failures, rules, grouping and pruning.
module Main (main) where

import Control.Events (EventId (..), EvtMsg (..), Rules (..), Timed (..), done, evtExpected, evtSubtasks, failed, reacted, scoped, simple, withMsg, (&), (.~), (?~))
import Control.Monad (forM_, unless)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Aeson (Value)
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.List (sort)
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Events
import Network.MQTT.Topic (mkFilter, mkTopic)
import System.Exit (exitFailure)

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

sec :: NominalDiffTime -> UTCTime
sec s = addUTCTime s t0

uuid :: Int -> UUID
uuid n = UUID.fromWords 0 0 0 (fromIntegral n)

-- | A run on a topic starting at a second, maybe finished after some seconds.
-- Its id is set by 'numbered'.
run :: Text -> NominalDiffTime -> Maybe (NominalDiffTime, Bool) -> Run
run topic s end = Run
  { eid = EventId (uuid 0) (fromJust (mkTopic topic))
  , start = Timed (sec s) (simple "" & withMsg .~ Nothing)
  , end = (\(took, ok) -> Timed (sec (s + took)) (fst ((if ok then done else failed) "" ()))) <$> end
  , followedAt = Nothing
  }

with :: (EvtMsg Value -> EvtMsg Value) -> Run -> Run
with f r = r {start = r.start {x = f r.start.x}}

expecting :: NominalDiffTime -> Run -> Run
expecting d = with (evtExpected ?~ d)

expectingSubtasks :: [String] -> Run -> Run
expectingSubtasks ts = with (evtSubtasks ?~ ts)

expectingReactions :: [Text] -> Run -> Run
expectingReactions fs = with (\m -> m {rules = m.rules {reactions = Just (map (fromJust . mkFilter) fs)}})

partOf, reactionTo :: Int -> Run -> Run
partOf p = with (scoped ?~ EventId (uuid p) (fromJust (mkTopic "t")))
reactionTo p = with (reacted ?~ EventId (uuid p) (fromJust (mkTopic "t")))

-- | Numbered runs, by id.
numbered :: [(Int, Run)] -> Map UUID Run
numbered rs = Map.fromList [(uuid n, r {eid = r.eid {correlationId = uuid n}}) | (n, r) <- rs]

-- | The problems of the run numbered @n@, among the given runs.
problemsOf :: NominalDiffTime -> [(Int, Run)] -> Int -> [(Text, Text)]
problemsOf now rs n = let m = numbered rs in problems (sec now) (index m) (m Map.! uuid n)

ids :: [Run] -> [UUID]
ids = map (.eid.correlationId)

names :: NominalDiffTime -> [(Int, Run)] -> Int -> [Text]
names now rs = map fst . problemsOf now rs

main :: IO ()
main = do
  let ok = Just (1, True)
      a = run "script/a" 0 ok
      hc = fromJust (mkTopic "healthcheck/x")
      beat s = expecting 60 . run "healthcheck/x" s
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
            let r = expectingSubtasks ["x", "y"] a in names 400 [(1, r), (2, partOf 1 (run "script/a/x" 0 ok)), (3, partOf 1 (run "script/a/y" 0 ok))] 1 == [])
        , ("repeated and unlisted subtasks are fine",
            let r = expectingSubtasks ["x"] a in names 400 [(1, r), (2, partOf 1 (run "script/a/x" 0 ok)), (3, partOf 1 (run "script/a/x" 0 ok)), (4, partOf 1 (run "script/a/z" 0 ok))] 1 == [])
        , ("a missing subtask is reported",
            let r = expectingSubtasks ["x", "y", "z"] a
             in problemsOf 400 [(1, r), (2, partOf 1 (run "script/a/x" 0 ok)), (3, partOf 1 (run "script/a/x/y" 0 ok))] 1 == [("subtasks", "None matching script/a/y, script/a/z.")])
        , ("a subtask must be scoped to the run", let r = expectingSubtasks ["x"] a in names 400 [(1, r), (2, run "script/a/x" 0 ok)] 1 == ["subtasks"])
        , ("subtasks aren't checked within the timeout, even once finished", let r = expectingSubtasks ["x"] a in names 299 [(1, r)] 1 == [])
        , ("subtasks are checked once timed out", let r = expectingSubtasks ["x"] (run "script/a" 0 Nothing) in names 301 [(1, r)] 1 == ["timed out", "subtasks"])
        , ("matching reactions are fine",
            let r = expectingReactions ["script/#", "server/b"] a
             in names 400 [(1, r), (2, reactionTo 1 (run "script/x/y" 5 ok)), (3, reactionTo 1 (run "server/b" 9 ok))] 1 == [])
        , ("a missing reaction is reported", let r = expectingReactions ["script/#", "server/b"] a in problemsOf 400 [(1, r), (2, reactionTo 1 (run "script/x" 5 ok))] 1 == [("reactions", "None matching server/b.")])
        , ("a reaction must react to the run", let r = expectingReactions ["#"] a in names 400 [(1, r), (2, run "script/x" 5 ok)] 1 == ["reactions"])
        , ("reactions aren't checked within the timeout, even once finished", let r = expectingReactions ["#"] a in names 299 [(1, r)] 1 == [])
        , ("a reaction is top-level", sort (ids (latestRuns (index (numbered [(1, a), (2, reactionTo 1 (run "script/b" 5 ok))])))) == [uuid 1, uuid 2])
        , ("a subtask isn't top-level, even of an unknown run", ids (latestRuns (index (numbered [(1, a), (2, partOf 1 (run "script/a/sub" 0 ok)), (3, partOf 9 (run "script/a/sub2" 0 ok))]))) == [uuid 1])
        , ("the latest runs are one per topic",
            sort (ids (latestRuns (index (numbered [(1, run "script/b" 20 ok), (2, run "script/a" 50 ok), (3, a)])))) == [uuid 1, uuid 2])
        , ("subtasks are newest first",
            ids (Map.findWithDefault [] (uuid 1) (index (numbered [(1, a), (3, partOf 1 (run "script/a/y" 5 ok)), (2, partOf 1 (run "script/a/x" 9 ok))])).scopedTo)
              == [uuid 2, uuid 3])
        , ("pruning keeps the latest 500 runs of each topic",
            let m = prune (numbered [(n, run "script/a" (fromIntegral n) ok) | n <- [1 .. 20001]])
             in Map.size m == 500 && Map.member (uuid 20001) m && Map.notMember (uuid 19501) m)
        , ("pruning keeps whole trees of the latest top-level runs",
            -- each parent has 3 subtasks; only the 2 oldest parents are pruned
            let parents = [(n, run "script/a" (fromIntegral n) ok) | n <- [1 .. 502]]
                subs = [(1000 * p + k, partOf p (run "script/a/x" (fromIntegral p) ok)) | p <- [1 .. 502], k <- [1 .. 3]]
                bulk = [(10 ^ (6 :: Int) + n, run "script/b" 0 ok) | n <- [1 .. 20000 - 2008 + 1]]
                m = prune (numbered (parents ++ subs ++ bulk))
             in Map.member (uuid 502) m && Map.member (uuid 3003) m && Map.notMember (uuid 2) m && Map.notMember (uuid 2003) m
                  && Map.size m == 500 * 4 + 500)
        , ("pruning leaves small histories alone", Map.size (prune (numbered [(n, a) | n <- [1 .. 100]])) == 100)
        , ("a healthcheck forgets its settled healthy runs but its first and latest",
            Map.keys (forgetHealthy (sec 1000) hc (numbered [(n, beat (60 * fromIntegral n) ok) | n <- [1 .. 4]])) == [uuid 1, uuid 4])
        , ("a healthcheck doesn't forget unsettled runs",
            Map.size (forgetHealthy (sec 400) hc (numbered [(n, beat (60 * fromIntegral n) ok) | n <- [1 .. 4]])) == 4)
        , ("a healthcheck keeps its failures, not then overdue",
            let m = forgetHealthy (sec 1000) hc (numbered [(1, beat 0 ok), (2, beat 60 (Just (1, False))), (3, beat 120 ok), (4, beat 180 ok)])
             in Map.keys m == [uuid 1, uuid 2, uuid 4] && map fst (problems (sec 1000) (index m) (m Map.! uuid 2)) == ["failed"])
        , ("a healthcheck keeps the run before a missed one",
            Map.keys (forgetHealthy (sec 1000) hc (numbered [(1, beat 0 ok), (2, beat 60 ok), (3, beat 300 ok), (4, beat 360 ok)])) == [uuid 1, uuid 2, uuid 4])
        , ("other topics are kept whole",
            Map.size (forgetHealthy (sec 1000) (fromJust (mkTopic "script/a")) (numbered [(n, expecting 60 (run "script/a" (60 * fromIntegral n) ok)) | n <- [1 .. 4]])) == 4)
        ]
  forM_ checks $ \(name, passed) -> putStrLn ((if passed then "ok   " else "FAIL ") <> name)
  unless (all snd checks) exitFailure
