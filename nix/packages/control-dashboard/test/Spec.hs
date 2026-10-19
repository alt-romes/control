{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
-- | Checks of how runs are judged (failures, rules, grouping and pruning),
-- and of the tree the dashboard shows them in.
module Main (main) where

import Control.Events (EventId (..), EvtDone (..), EvtMsg (..), Timed (..), Trigger (..), done, evtCritical, evtExpected, evtReactions, evtSubtasks, failed, reacted, scoped, simple, withMsg, (&), (.~), (?~))
import Control.Monad (forM_, unless)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Maybe (fromJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.List (sort)
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Events
import Network.MQTT.Topic (Topic, mkFilter, mkTopic)
import System.Exit (exitFailure)
import Tree

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
  }

with :: (EvtMsg Value -> EvtMsg Value) -> Run -> Run
with f r = r {start = r.start {e = f r.start.e}}

expecting :: NominalDiffTime -> Run -> Run
expecting d = with (evtExpected ?~ d)

expectingSubtasks :: [String] -> Run -> Run
expectingSubtasks ts = with (evtSubtasks ?~ ts)

expectingReactions :: [Text] -> Run -> Run
expectingReactions fs = with (evtReactions ?~ map (fromJust . mkFilter) fs)

announcing :: Text -> Run -> Run
announcing t r = r {end = (\d -> d {e = d.e {triggers = Just [Trigger (fromJust (mkTopic t)) "Send" Nothing]}}) <$> r.end}

partOf, reactionTo :: Int -> Run -> Run
partOf p = with (scoped ?~ EventId (uuid p) (fromJust (mkTopic "t")))
reactionTo p = with (reacted ?~ EventId (uuid p) (fromJust (mkTopic "t")))

-- | Numbered runs, by id.
numbered :: [(Int, Run)] -> Map UUID Run
numbered rs = Map.fromList [(uuid n, r {eid = r.eid {correlationId = uuid n}}) | (n, r) <- rs]

-- | The problems of the run numbered @n@, among the given runs.
problemsOf :: NominalDiffTime -> [(Int, Run)] -> Int -> [(Text, Text)]
problemsOf = problemsAsleep []

-- | Like 'problemsOf', with the machine asleep between the given seconds.
problemsAsleep :: [(NominalDiffTime, NominalDiffTime)] -> NominalDiffTime -> [(Int, Run)] -> Int -> [(Text, Text)]
problemsAsleep sleeps now rs n = let m = numbered rs in problems [(sec a, sec b) | (a, b) <- sleeps] (sec now) (index m) (m Map.! uuid n)

-- | The dashboard at a second.
ctxOf :: NominalDiffTime -> [(Int, Run)] -> Ctx
ctxOf now = ctxWills now []

-- | Like 'ctxOf', with these services' connections having died.
ctxWills :: NominalDiffTime -> [(Topic, UTCTime)] -> [(Int, Run)] -> Ctx
ctxWills now ws rs = Ctx (sec now) (index (numbered rs)) True [] [] t0 ws Map.empty

resulting :: Value -> Run -> Run
resulting v r = r {end = (\d -> d {e = d.e {result = Just v}}) <$> r.end}

tp :: Text -> Topic
tp = fromJust . mkTopic

ids :: [Run] -> [UUID]
ids = map (.eid.correlationId)

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
        , ("time asleep isn't overdue", let r = expecting 60 a; n = run "script/a" 1000 ok in map fst (problemsAsleep [(50, 950)] 1100 [(1, r), (2, n)] 1) == [])
        , ("time awake around a sleep is overdue", let r = expecting 60 a in map fst (problemsAsleep [(50, 950)] 1100 [(1, r)] 1) == ["overdue"])
        , ("the latest run past grace is overdue", let r = expecting 60 a in names 121 [(1, r)] 1 == ["overdue"])
        , ("all expected subtasks is fine",
            let r = expectingSubtasks ["x", "y"] a in names 400 [(1, r), (2, partOf 1 (run "script/a/x" 0 ok)), (3, partOf 1 (run "script/a/y" 0 ok))] 1 == [])
        , ("repeated and unlisted subtasks are fine",
            let r = expectingSubtasks ["x"] a in names 400 [(1, r), (2, partOf 1 (run "script/a/x" 0 ok)), (3, partOf 1 (run "script/a/x" 0 ok)), (4, partOf 1 (run "script/a/z" 0 ok))] 1 == [])
        , ("a missing subtask is reported",
            let r = expectingSubtasks ["x", "y", "z"] a
             in problemsOf 400 [(1, r), (2, partOf 1 (run "script/a/x" 0 ok)), (3, partOf 1 (run "script/a/x/y" 0 ok))] 1 == [("subtasks", "No subtask yet matching script/a/y, script/a/z.")])
        , ("a subtask must be scoped to the run", let r = expectingSubtasks ["x"] a in names 400 [(1, r), (2, run "script/a/x" 0 ok)] 1 == ["subtasks"])
        , ("subtasks aren't checked within the timeout, even once finished", let r = expectingSubtasks ["x"] a in names 299 [(1, r)] 1 == [])
        , ("subtasks are checked once timed out", let r = expectingSubtasks ["x"] (run "script/a" 0 Nothing) in names 301 [(1, r)] 1 == ["timed out", "subtasks"])
        , ("a failed subtask is reported", problemsOf 10 [(1, a), (2, partOf 1 (run "script/a/x" 0 (Just (1, False))))] 1 == [("failed subtasks", "Subtasks with problems: script/a/x: failed.")])
        , ("matching reactions are fine",
            let r = expectingReactions ["script/#", "server/b"] a
             in names 400 [(1, r), (2, reactionTo 1 (run "script/x/y" 5 ok)), (3, reactionTo 1 (run "server/b" 9 ok))] 1 == [])
        , ("a missing reaction is reported", let r = expectingReactions ["script/#", "server/b"] a in problemsOf 400 [(1, r), (2, reactionTo 1 (run "script/x" 5 ok))] 1 == [("reactions", "No reaction yet matching server/b.")])
        , ("a reaction must react to the run", let r = expectingReactions ["#"] a in names 400 [(1, r), (2, run "script/x" 5 ok)] 1 == ["reactions"])
        , ("a reaction is missing until it arrives, even within the timeout", let r = expectingReactions ["#"] a in names 1 [(1, r)] 1 == ["reactions"])
        , ("a missing reaction a pending trigger would provide awaits it",
            let r = announcing "trigger/x" (expectingReactions ["trigger/#", "server/b"] a)
             in problemsOf 400 [(1, r)] 1 == [("awaiting trigger", "Not yet sent: Send."), ("reactions", "No reaction yet matching server/b.")])
        , ("a sent trigger is no longer awaited",
            let r = announcing "trigger/x" (expectingReactions ["trigger/#"] a) in names 400 [(1, r), (2, reactionTo 1 (run "trigger/x" 5 ok))] 1 == [])
        , ("a pending trigger no reaction is expected of is no problem", names 400 [(1, announcing "trigger/x" a)] 1 == [])
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
        , ("subtasks and reactions of a critical run are critical, transitively",
            let ix = index (numbered [(1, with (evtCritical .~ True) a), (2, partOf 1 (run "script/a/x" 0 ok)), (3, reactionTo 2 (run "script/b" 5 ok)), (4, a)])
             in map (isCritical ix) (Map.elems ix.runs) == [True, True, True, False])
        , ("a subtask's node is inside its run's", holder (ctxOf 10 [(1, a), (2, partOf 1 (run "script/a/x" 0 ok))]) (tp "script/a/x") == Just "script/a")
        , ("a subtask of an unknown run is top-level", holder (ctxOf 10 [(2, partOf 9 (run "script/a/x" 0 ok))]) (tp "script/a/x") == Nothing)
        , ("topics scoped to each other aren't nested",
            let c = ctxOf 10 [(1, partOf 2 (run "script/a" 0 ok)), (2, partOf 1 (run "script/b" 0 ok))] in holder c (tp "script/a") == Nothing && holder c (tp "script/b") == Nothing)
        , ("top-level topics of a service are grouped, whatever their kind; a service of one isn't",
            let c = ctxOf 10 [(1, run "script/a/x" 0 ok), (2, run "server/a/y" 0 ok), (3, run "script/b/z" 0 ok)]
             in map (holder c . tp) ["script/a/x", "server/a/y", "script/b/z"] == [Just "a/", Just "a/", Nothing])
        , ("machines, healthchecks and triggers aren't event nodes",
            events (ctxOf 10 [(1, run "system/m" 0 ok), (2, run "trigger/x" 0 ok), (3, run "healthcheck/h" 0 ok), (4, a)]) == [tp "script/a"])
        , ("a reaction links from the topic it reacts to", links (ctxOf 10 [(1, a), (2, reactionTo 1 (run "script/b" 1 ok))]) == [Link (tp "script/a") (tp "script/b") Nothing Nothing])
        , ("a sent trigger links its announcer to what it started, labelled",
            links (ctxOf 10 [(1, announcing "trigger/b" a), (2, reactionTo 1 (with (\e -> e {label = "Go"}) (run "trigger/b" 2 ok))), (3, reactionTo 2 (run "script/b" 3 ok))])
              == [Link (tp "script/a") (tp "script/b") (Just "Go") Nothing])
        , ("a pending trigger links to what it started before, and can be sent from there",
            links (ctxOf 10 [(1, announcing "trigger/b" a), (2, reactionTo 1 (run "trigger/b" 2 ok)), (3, reactionTo 2 (run "script/b" 3 ok)), (4, announcing "trigger/b" (run "script/a" 5 ok))])
              == [Link (tp "script/a") (tp "script/b") (Just "Send") (Just (uuid 4, 0))])
        , ("a pending trigger never sent before has no link", null (links (ctxOf 10 [(1, announcing "trigger/b" a)])))
        , ("failing since the first of the latest runs with problems",
            let bad s' = run "script/a" s' (Just (1, False)); c = ctxOf 100 [(1, a), (2, bad 10), (3, bad 20)]
             in failingSince c (Map.findWithDefault [] (tp "script/a") c.ix.byTopic) == Just (sec 10))
        , ("one bad run isn't failing for a while",
            let c = ctxOf 100 [(1, a), (2, run "script/a" 10 (Just (1, False)))] in isNothing (failingSince c (Map.findWithDefault [] (tp "script/a") c.ix.byTopic)))
        , ("unscheduled topics count their runs in the last day",
            let c = ctxOf 90000 [(1, a), (2, run "script/a" 5000 ok), (3, run "script/a" 6000 ok)] in dailyCount c (Map.findWithDefault [] (tp "script/a") c.ix.byTopic) == Just 2)
        , ("scheduled topics don't",
            let c = ctxOf 100 [(1, expecting 60 a), (2, expecting 60 (run "script/a" 50 ok))] in isNothing (dailyCount c (Map.findWithDefault [] (tp "script/a") c.ix.byTopic)))
        , ("time before the dashboard started isn't overdue, as it may have been asleep",
            let c now = (ctxOf now [(1, expecting 60 a)]) {since = sec 1000}
                overdue now = alerts (c now) == ["script/a: overdue"]
             in not (overdue 1100) && overdue 1200)
        , ("figures under headings are a table",
            tableOf "IVA\n  Campo 8        0,00  isentas\n\nSS\n  mês  7         0,00\n"
              == Just [object ["head" .= ("IVA" :: Text)], object ["cells" .= ["Campo 8", "0,00", "isentas" :: Text]], object ["head" .= ("SS" :: Text)], object ["cells" .= ["mês 7", "0,00", "" :: Text]]])
        , ("text with a line that isn't a figure or heading isn't a table", isNothing (tableOf "a  1,00\nb  2,00\nsome words  and more"))
        , ("one figure isn't a table", isNothing (tableOf "total  1,00"))
        , ("a log is shown, and recent people too",
            let p n = with (\e -> e {content = Just (object ["email" .= (n <> "@x.org" :: Text), "name" .= n])}) (run "server/s" 0 ok)
                c = (ctxOf 10 [(1, p "ana"), (2, p "bo")]) {logs = Map.fromList [(tp "server/s", "oops")]}
             in map (.viewKind) (views c (tp "server/s")) == ["log", "people"])
        , ("documents and images get their own views",
            map (.viewKind) (views (ctxOf 10 [(1, resulting (object ["a" .= ("/x/a.pdf" :: Text), "b" .= ("/x/b.png" :: Text)]) a)]) (tp "script/a")) == ["data", "document", "image"])
        , ("a name in no part of its email looks made up", madeUp "Mr. Norval Tillman" "jmoverton@outlook.com")
        , ("a name in its email doesn't", not (madeUp "Rodrigo Mesquita" "rodrigo.m.mesquita@gmail.com") && not (madeUp "Al" "x@y.z"))
        , ("runs per day, oldest first",
            let c = ctxOf (86400 * 2 + 10) [(1, a), (2, run "script/a" 86400 ok), (3, run "script/a" 86401 ok)]
             in drop 11 (perDay c (Map.findWithDefault [] (tp "script/a") c.ix.byTopic)) == [1, 2, 0])
        , ("awaiting a trigger isn't failing",
            let w s' = announcing "trigger/x" (expectingReactions ["trigger/#"] (run "script/a" s' ok)); c = ctxOf 400 [(1, w 0), (2, w 10)]
             in isNothing (failingSince c (Map.findWithDefault [] (tp "script/a") c.ix.byTopic)))
        , ("a run waiting on its triggers is orphaned when its service's connection dies after it started",
            let r = announcing "trigger/x" a; c ws = ctxWills 100 ws [(1, r)]
             in orphaned (c [(tp "script", sec 50)]) r == Just (sec 50) && isNothing (orphaned (c [(tp "script", sec 0)]) r)
                  && isNothing (orphaned (c [(tp "server", sec 50)]) r) && null (links (c [(tp "script", sec 50)])))
        , ("a finished run with nothing pending isn't orphaned", isNothing (orphaned (ctxWills 100 [(tp "script", sec 50)] [(1, a)]) a))
        , ("requests that say different things list their recent runs",
            let req l = with (\e -> e {label = l}) (run "server/s" 0 ok)
             in "runs" `elem` map (.viewKind) (views (ctxOf 10 [(1, req "by a"), (2, req "by b")]) (tp "server/s"))
                  && "runs" `notElem` map (.viewKind) (views (ctxOf 10 [(1, req "same"), (2, req "same")]) (tp "server/s")))
        , ("a list of records is a table", map (.viewKind) (shapes [toJSON [object ["date" .= ("d1" :: Text), "amount" .= (1 :: Int)], object ["date" .= ("d2" :: Text), "amount" .= (2 :: Int)]]]) == ["records"])
        , ("numbers are a trend across runs, oldest first",
            map (\v -> (v.viewKind, v.viewValue)) (shapes [object ["usd" .= (3 :: Int)], object ["usd" .= (1 :: Int)]]) == [("trend", object ["usd" .= [1, 3 :: Double]])])
        , ("an email sent is recognised", map (.viewKind) (shapes [object ["to" .= ["a@b.c" :: Text], "subject" .= ("Invoice" :: Text)]]) == ["mail"])
        , ("fields of an object are recognised in turn, by name",
            map (\v -> (v.viewKind, v.viewTitle)) (shapes [object ["balances" .= object ["a" .= (1 :: Int)], "note" .= ("x" :: Text)]]) == [("trend", Just "balances")])
        , ("plain fields aren't anything", null (shapes [object ["Order Item" .= ("132391" :: Text), "Resource" .= ("Access Link" :: Text)]]))
        , ("a percentage rising to 100% within a week is filling",
            let disk s' p = with (\e -> e {content = Just (object ["diskUsed" .= (T.pack (show (p :: Int)) <> "%")])}) (run "system/m" s' ok)
                c = ctxOf 7200 [(1, disk 0 97), (2, disk 3600 98), (3, disk 7200 99)]
             in map fst (filling c (Map.findWithDefault [] (tp "system/m") c.ix.byTopic)) == ["diskUsed"])
        , ("a flat percentage isn't",
            let disk s' = with (\e -> e {content = Just (object ["diskUsed" .= ("98%" :: Text)])}) (run "system/m" s' ok)
                c = ctxOf 7200 [(1, disk 0), (2, disk 3600), (3, disk 7200)]
             in null (filling c (Map.findWithDefault [] (tp "system/m") c.ix.byTopic)))
        , ("an exit code isn't output", let c = ctxOf 10 [(1, resulting (Number 0) a)] in isNothing (outputOf c (resulting (Number 0) a)))
        , ("a summary of many lines is output", let r = a {end = (\d -> d {e = d.e {summary = "a\nb"}}) <$> a.end} in outputOf (ctxOf 10 [(1, r)]) r == Just (Just (String "a\nb"), []))
        , ("text is output", let r = resulting (String "oops") a in outputOf (ctxOf 10 [(1, r)]) r == Just (Just (String "oops"), []))
        , ("absolute paths to documents and images in a result are files to show",
            let v = object ["pdfPath" .= ("/x/a.PDF" :: Text), "rel" .= ("b.pdf" :: Text), "log" .= ("/x/c.txt" :: Text), "more" .= [String "/x/d.png"]]
             in sort (files (ctxOf 10 [(1, resulting v a)])) == ["/x/a.PDF", "/x/d.png"])
        , ("files in a pending trigger's data are shown too",
            let r = a {end = (\d -> d {e = d.e {triggers = Just [Trigger (tp "trigger/x") "Send" (Just (String "/x/invoice.pdf"))]}}) <$> a.end}
             in files (ctxOf 10 [(1, r)]) == ["/x/invoice.pdf"])
        , ("only the latest run's files are shown", files (ctxOf 10 [(1, resulting (String "/x/old.pdf") a), (2, run "script/a" 5 ok)]) == [])
        , ("a required topic never seen is alerted", alerts ((ctxOf 10 []) {required = [tp "script/z"]}) == ["script/z: no run seen of this required topic"])
        , ("a subtask's problems aren't alerted on their own",
            alerts (ctxOf 10 [(1, a), (2, partOf 1 (run "script/a/x" 0 (Just (1, False))))]) == ["script/a: failed subtasks"])
        ]
  forM_ checks $ \(name, passed) -> putStrLn ((if passed then "ok   " else "FAIL ") <> name)
  unless (all snd checks) exitFailure
