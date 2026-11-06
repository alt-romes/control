module Main (main) where

import Control.Monad (unless)
import Data.Aeson (Value, decode, encode, object, toJSON, (.=))
import Data.Maybe (fromJust)
import qualified Data.Text as T
import Data.Time (Day, UTCTime)
import qualified Data.UUID as UUID
import Model
import Notes (checkbox, ticked)
import System.Exit (exitFailure)

check :: (Eq a, Show a) => String -> a -> a -> IO ()
check what got want = unless (got == want) do
  putStrLn (what <> ": got " <> show got <> ", want " <> show want)
  exitFailure

-- | Things as they arrive on the wire.
started, finished :: Value -> Value -> Logged
started i s = fromJust (decode (encode (object ["tag" .= ("Started" :: String), "contents" .= [i, s]])))
finished i d = fromJust (decode (encode (object ["tag" .= ("Finished" :: String), "contents" .= [i, d]])))

main :: IO ()
main = do
  check "filters" (map (uncurry matches) [("a/#", "a"), ("a/+/c", "a/b/c"), ("a/+", "a/b/c"), ("#", "x/y")]) [True, True, False, True]
  check "durations" (map fmtDuration [1.5, 3720, 120]) ["1.5s", "1h 2m", "2m"]

  let (a, b) = (UUID.toText (UUID.fromWords 1 2 3 4), UUID.toText (UUID.fromWords 5 6 7 8))
      eid i t = object ["correlationId" .= i, "evtTopic" .= (t :: String)]
      now = read "2026-11-01 10:05:00 UTC" :: UTCTime
      run = started (eid a "script/s") (object ["at" .= ("2026-11-01T10:00:00Z" :: String), "e" .= object
              ["rules" .= object ["timeout" .= (60 :: Int), "reactions" .= ["trigger/x" :: String]], "label" .= ("s" :: String)]])
      st0 = State mempty mempty [] True mempty
  let st = foldl (flip apply) st0
        [ run
        , finished (toJSON a) (object ["at" .= ("2026-11-01T10:00:01Z" :: String), "e" .= object
            ["summary" .= ("boom\nmore" :: String), "success" .= False
            , "triggers" .= [object ["triggerTopic" .= ("trigger/x" :: String), "triggerLabel" .= ("retry" :: String)]]]])
        ]
      r = fromJust (latest st "script/s")
  check "problems" (problems now st (index st) r) ["Failed: boom"]
  check "pending" (length (pendingTriggers (index st) r)) 1
  let st' = foldl (flip apply) st
        [ started (eid b "trigger/x") (object ["at" .= ("2026-11-01T10:06:00Z" :: String), "e" .= object
            ["reactTo" .= [eid a "script/s"], "rules" .= object ["timeout" .= (300 :: Int)], "label" .= ("retry" :: String)]])
        , run -- delivered twice, which mustn't undo the finish
        ]
      r' = fromJust (latest st' "script/s")
  check "sent" (length (pendingTriggers (index st') r')) 0
  check "still finished" (problems now st' (index st') r') ["Failed: boom"]

  -- A reaction the rules expect is shown as awaited, and wrong once it's late.
  let c = UUID.toText (UUID.fromWords 9 9 9 9)
      waiting = foldl (flip apply) st0
        [ started (eid c "script/w") (object ["at" .= ("2026-11-01T10:00:00Z" :: String), "e" .= object
            ["rules" .= object ["timeout" .= (60 :: Int), "reactions" .= ["script/w/checking" :: String]], "label" .= ("w" :: String)]])
        , finished (toJSON c) (object ["at" .= ("2026-11-01T10:00:01Z" :: String), "e" .= object ["summary" .= ("" :: String), "success" .= True]])
        ]
      w = fromJust (latest waiting "script/w")
  check "awaited" (awaitedReactions (index waiting) w) ["script/w/checking"]
  check "late" (problems now waiting (index waiting) w) ["No reaction on script/w/checking since it finished 4m 59s ago."]

  -- Todos: a project is the path, later events on it reschedule and close it.
  let (t1, t2) = (UUID.fromWords 2 0 0 1, UUID.fromWords 2 0 0 2)
      day = read "2026-11-04" :: Day -- a Wednesday
      todo i p d label more = started (eid (UUID.toText i) ("todo/" <> p)) (object ["at" .= ("2026-11-0" <> show (d :: Int) <> "T10:00:00Z"), "e" .= object
        (["label" .= (label :: String), "rules" .= object ["timeout" .= (300 :: Int)]] ++ more)])
      on i p d v = todo (UUID.fromWords 3 0 0 (fromIntegral d)) p d "" ["reactTo" .= [eid (UUID.toText i) ("todo/" <> p)], "content" .= v]
      todos = foldl (flip apply) st0
        [ todo t1 "finances/irs" 1 "File the IRS" ["content" .= object ["due" .= ("2026-11-03" :: String)]]
        , todo t2 "home" 2 "Water the plants" []
        , on t2 "home" 3 (object ["due" .= ("2026-11-08" :: String)])
        ]
      open s = [(t.project, t.title, horizon day t, todoProblems day t) | t <- openTodos s]
  check "todos" (open todos) [("finances/irs", "File the IRS", Today, ["Was due Tue  3 Nov."]), ("home", "Water the plants", Week, [])]
  check "ends" (map (`endOf` day) [Today, Week, Year]) (map read ["2026-11-04", "2026-11-08", "2026-12-31"])
  let todos' = apply (on t1 "finances/irs" 5 (object ["done" .= True])) todos
  check "done" (map (.title) (openTodos todos')) ["Water the plants"]

  -- A run's chain: the trigger it announced was sent, and reacted to it.
  check "trace" [(d, topicOf x) | (d, x) <- trace st' (index st') r'] [(0, "script/s"), (1, "trigger/x")]
  check "strips" [[s | Tick s _ <- recent now x t] | (x, t) <- [(st', "script/s"), (waiting, "script/w")]] [["bad"], ["fine"]]

  -- Notes: any space after the box, and ticking keeps the rest of the line.
  let md = "# x\n  - [ ]\160Do this\n- [x] Done\n- [ ] Or that"
  check "checkboxes" [(n, T.strip t) | (n, l) <- zip [0 :: Int ..] (T.splitOn "\n" md), Just (_, t) <- [checkbox l]] [(1, "Do this"), (3, "Or that")]
  check "ticked" (ticked 1 "Do this" md) (Just "# x\n  - [x]\160Do this\n- [x] Done\n- [ ] Or that")
  check "changed" (ticked 3 "Do this" md) Nothing
