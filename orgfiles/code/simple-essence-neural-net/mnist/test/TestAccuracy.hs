module Main where

import Data.List (isPrefixOf, find)
import System.Exit
import System.Process

main :: IO ()
main = do
  output <- readProcess "mnist" [] ""
  putStr output
  case find ("Test accuracy:" `isPrefixOf`) (lines output) of
    Nothing -> do
      putStrLn "Could not find 'Test accuracy:' line in mnist output"
      exitFailure
    Just l -> do
      let acc = read (drop (length "Test accuracy: ") l) :: Double
      if acc > 0.90
        then putStrLn $ "OK: accuracy " ++ show acc ++ " > 0.90"
        else do
          putStrLn $ "FAIL: accuracy " ++ show acc ++ " is not > 0.90"
          exitFailure
