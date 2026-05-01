{- cabal:
 build-depends: base, random, bytestring
-}
{-# LANGUAGE GHC2024 #-}
import Debug.Trace
import Debug.RecoverRTTI
import Prelude hiding (id, (.))
import Control.Category
import Control.Monad
import System.Random.Stateful
import qualified Data.ByteString as BS
import GHC.Base (build)

newtype a :-> b = D    { (#)  :: a -> (b, a <-- b) }
newtype a <-- b = Dual { (<|) :: b -> a            }
linear f fd = D (\a -> (f a, fd))
scale  y    = Dual (\dx -> dx*y)

instance Category (:->) where
  id = trace "id" $ linear id (Dual id)
  g . f = trace "." $ D $ \a -> -- chain rule
    let (b, Dual f') = f # a; (c, Dual g') = trace ("f(a)=" ++ anythingToString a) $ g # b
     in (c, Dual (f' . g'))

f × g = trace "×" $ D $ \(a,b) ->
  let (c, f') = f # a; (d, g') = g # b
   in ((c,d), Dual (\(x,y) -> (f' <| x, g' <| y)))
--------------------------------------------------------------------------------
dup       = trace "dup" $ linear (\x -> (x,x)) (Dual (uncurry (+)))
neg       = trace "neg" $ linear negate (scale (-1))
(+>) k    = trace "+>" $ linear (+k) (Dual id)
mul       = trace "mul" $ D $ \(x,y) -> (x*y, Dual (\df -> (df*y,df*x)))
rec       = trace "rec" $ D $ \x -> (recip x, scale (-1 / x^2))
exp'      = trace "exp" $ D $ \x -> let e = exp x in (e, scale e)
-- pow  k    = D $ \x -> (x^k, scale (k*x^(k-1))) -- (^) only works for integral exponents
sqrt'     = D $ \x -> let r = sqrt x in (r, scale (r*(1/2)))
--------------------------------------------------------------------------------
dupI    n = trace "dupI" $ linear (\x -> replicate n x) (Dual sum)
crossI fs = trace "crossI" $ D $ \as -> let (bs, bsas) = unzip (zipWith (#) fs as) in (bs, Dual (zipWith (<|) bsas))
sumI      = trace "sumI" $ D $ \xs -> (sum xs, Dual (\x -> replicate (length xs) x))
hadamard  = trace "hadamard" $ D $ \(ss, xs) -> (ss .*. xs, Dual (\dfs -> (xs .*. dfs, ss .*. dfs))) where (.*.) = zipWith (*)
fixed f a = trace "fixed" $ D $ \b -> let (c, Dual d) = f # (a, b) in (c, Dual (snd . d))
cons    x = trace "cons" $ D $ \xs -> (x:xs, Dual (\(_dx:dxs) -> dxs)) -- add a constant number to head of Vec. All weight vecs have leading biases
--------------------------------------------------------------------------------
sigmoid  = trace "sigmoid" $ rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
neuron :: ([Double], [Double]) :-> Double
c1 = trace "C1" (.)
c2 = trace "C2" (.)
neuron   = trace "neuron" $ trace "neuron:s" sigmoid `c1` (trace "neuron:si" sumI . trace "neuron:had" hadamard) `c2` (trace "neuron:cs" cons 1 × trace "neuron:id" id) `c2` trace "RUNNING NEURON NOW" id
myunzip = trace "what is happening" unzip
l2 = trace "l2" $ crossI (trace "repl10" $ replicate 10 neuron) . trace "l2:linear" (linear (\(xs,ys) -> trace "going to zip:" $ trace (show xs) $ trace "now y" $ trace (show ys) $ let z = zipWith (,) xs ys in trace "now the result z: " $ trace (show z) $ z) (Dual (trace "UNZIPPING" myunzip)))
l1 i = trace "l1" $ crossI (replicate 300 (fixed neuron i))
mnistNet :: [Double] -> ([[Double]], [[Double]]) :-> [Double]
mnistNet i = trace "mnistNet" $ l2 . ((dupI 10 . l1 i) × id) where n = fixed neuron i
cost :: [([Double], [Double])] -> ([[Double]], [[Double]]) :-> Double
cost  ps = trace "cost" $ sumI . crossI (map cost1 ps) . dupI (length ps)
  where cost1 (i, o) = trace ("cost1:" ++ show (i,o)) $ sqrt' . sumI . crossI (replicate 10 sqr) . (negate o +>) . mnistNet (trace "the-I" i)
        sqr :: Double :-> Double
        sqr = trace "sqr" $ mul . dup

step examples (i :: Int) weights = trace "a single step" $ do
  let (r, Dual grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10)

main = do
  images <- map (fromIntegral @_ @Double) . BS.unpack <$> BS.readFile "train-images.idx3-ubyte"
  labels <- map (fromIntegral @_ @Double) . BS.unpack <$> BS.readFile "train-labels.idx1-ubyte"
  let examples :: [([Double], [Double])]
      examples = zipWith (,) (chunksOf 784 images) (map (:[]) labels)
  initialWeights <- (,) <$> mapM (const $ replicateM 785 $ randomM globalStdGen) [1..300] <*> mapM (const $ replicateM 301 $ randomM globalStdGen) [1..10]
  finalWeights   <- foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..1000]
  putStrLn $ "Neural net results: " ++ show (map (\(e,_) -> fst (mnistNet e # finalWeights)) examples)
  putStrLn $ "Expected results:   " ++ show (map snd examples)

type Weights = ([[Double]], [[Double]])
instance Num Weights where
  fromInteger x' = (replicate 300 (replicate 785 x), replicate 10 (replicate 301 x)) where x = fromInteger x'
  (w1, w2) + (w3, w4) = (zipWith (+) w1 w3, zipWith (+) w2 w4)
instance Num [Double] where
  fromInteger = replicate 10{-a very big hack, bc this is only needed for `dupI 10`...-} . fromInteger
  (+) = zipWith (+)
chunksOf :: Int -> [e] -> [[e]]
chunksOf i ls = map (take i) (build (splitter ls))
 where
  splitter :: [e] -> ([e] -> a -> a) -> a -> a
  splitter [] _ n = n
  splitter l c n = l `c` splitter (drop i l) c n
