module Main (main) where

import Control.Monad (unless)
import Data.Aeson (Value, decode, encode, object, toJSON, (.=))
import Data.Maybe (fromJust)
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import Data.Time (UTCTime)
import qualified Data.UUID as UUID
import Model
import View
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
      st0 = State mempty mempty [] ["trigger/go"] True (read "2026-11-01 00:00:00 UTC") [] mempty
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

  -- A missed run is only a problem once the server has been awake long enough to see it.
  let e = UUID.toText (UUID.fromWords 7 7 7 7)
      due = apply (started (eid e "healthcheck/h") (object ["at" .= ("2026-11-01T09:55:00Z" :: String), "e" .= object
        ["rules" .= object ["timeout" .= (600 :: Int), "expected" .= (120 :: Int)], "label" .= ("h" :: String)]])) st0
      missed x = length (problems now x (index x) (fromJust (latest x "healthcheck/h")))
  check "missed" (missed due, missed due {awake = read "2026-11-01 10:04:00 UTC"}) (1, 0)

  -- Time the computer slept doesn't count against a run's limit.
  let f = UUID.toText (UUID.fromWords 6 6 6 6)
      stuck = apply (started (eid f "healthcheck/s") (object ["at" .= ("2026-11-01T09:55:00Z" :: String), "e" .= object
        ["rules" .= object ["timeout" .= (60 :: Int)], "label" .= ("s" :: String)]])) st0
      unfinished x = problems now x (index x) (fromJust (latest x "healthcheck/s"))
  check "awake" (unfinished stuck) ["No finish after 10m; the limit is 1m."]
  check "slept" (unfinished stuck {slept = [(read "2026-11-01 09:55:30 UTC", read "2026-11-01 10:04:50 UTC")]}) []

  -- A run's chain: the trigger it announced was sent, and reacted to it.
  check "trace" [(d, topicOf x) | (d, x) <- trace st' (index st') r'] [(0, "script/s"), (1, "trigger/x")]

  -- The failed run and its unsent trigger need the user, until dismissed.
  let needs x = [(i.topic, i.status, i.problems, length i.sends) | i <- judged now x]
      has x = all ((`B8.isInfixOf` BL.toStrict (encode x)) . B8.pack)
  check "judged" (needs st) [("script/s", Bad, ["Failed: boom"], 1)]
  check "dismissed" (needs (apply (Dismissed (fromJust (UUID.fromText a))) st)) [("script/s", Fine, [], 0)]
  check "system" (has (system now st (judged now st)) ["Failed: boom", "\"pending\":true", "\"?trigger/x\"", "\"@you\"", "trigger/go"]) True
  check "reacted" (has (system now st' (judged now st')) ["\"source\":\"script/s\"", "\"target\":\"?trigger/x\""]) True
  check "topic" (has (topic now st' Nothing "script/s") ["Failed: boom", "trigger/x"]) True

  -- A newer run of the topic doesn't hide what an older one asked for.
  let g = UUID.toText (UUID.fromWords 4 4 4 4)
      again = foldl (flip apply) st
        [ started (eid g "script/s") (object ["at" .= ("2026-11-01T10:02:00Z" :: String), "e" .= object
            ["rules" .= object ["timeout" .= (60 :: Int)], "label" .= ("s" :: String)]])
        , finished (toJSON g) (object ["at" .= ("2026-11-01T10:02:01Z" :: String), "e" .= object ["summary" .= ("" :: String), "success" .= True]])
        ]
  check "still asked" (needs again) [("script/s", Waiting, [], 1)]
  check "requests" (has (system now again (judged now again)) ["\"requests\":[{", "\"label\":\"retry\"", "\"sent\":null", "\"actions\":[{\"last\":null,\"topic\":\"trigger/go\"}]"]) True
  check "answered" (has (system now st' (judged now st')) ["\"sent\":{\"at\":\"2026-11-01T10:06:00Z\""]) True
