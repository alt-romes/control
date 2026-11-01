module Main (main) where

import Control.Monad (unless)
import Data.Aeson (Value, decode, encode, object, toJSON, (.=))
import Data.Maybe (fromJust)
import Data.Time (UTCTime)
import qualified Data.UUID as UUID
import Model
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
      st0 = State mempty mempty [] True
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
