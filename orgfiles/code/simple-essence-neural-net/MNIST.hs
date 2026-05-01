{- cabal:
 build-depends: base, random, bytestring
-}
{-# LANGUAGE GHC2024 #-}
import Prelude hiding (id, (.))
import Control.Category
import System.Random.Stateful
import qualified Data.ByteString as BS

newtype a :-> b = D    { (#)  :: a -> (b, a <-- b) }
newtype a <-- b = Dual { (<|) :: b -> a            }
linear f fd = D (\a -> (f a, fd))
scale  y    = Dual (\dx -> dx*y)

instance Category (:->) where
  id = linear id (Dual id)
  g . f = D $ \a -> -- chain rule
    let (b, Dual f') = f # a; (c, Dual g') = g # b
     in (c, Dual (f' . g'))

f × g = D $ \(a,b) ->
  let (c, f') = f # a; (d, g') = g # b
   in ((c,d), Dual (\(x,y) -> (f' <| x, g' <| y)))
--------------------------------------------------------------------------------
dup       = linear (\x -> (x,x)) (Dual (uncurry (+)))
neg       = linear negate (scale (-1))
(+>) k    = linear (+k) (Dual id)
mul       = D $ \(x,y) -> (x*y, Dual (\df -> (df*y,df*x)))
rec       = D $ \x -> (recip x, scale (-1 / x^2))
exp'      = D $ \x -> let e = exp x in (e, scale e)
-- pow  k    = D $ \x -> (x^k, scale (k*x^(k-1))) -- (^) only works for integral exponents
sqrt'     = D $ \x -> let r = sqrt x in (r, scale (r*(1/2)))
--------------------------------------------------------------------------------
dupI    n = linear (\x -> replicate n x) (Dual sum)
crossI fs = D $ \as -> let (bs, bsas) = unzip (zipWith (#) fs as) in (bs, Dual (zipWith (<|) bsas))
sumI      = D $ \xs -> (sum xs, Dual (\x -> replicate (length xs) x))
hadamard  = D $ \(ss, xs) -> (ss .*. xs, Dual (\dfs -> (xs .*. dfs, ss .*. dfs))) where (.*.) = zipWith (*)
fixed f a = D $ \b -> let (c, Dual d) = f # (a, b) in (c, Dual (snd . d))
cons    x = D $ \xs -> (x:xs, Dual (\(_dx:dxs) -> dxs)) -- add a constant number to head of Vec. All weight vecs have leading biases
--------------------------------------------------------------------------------
sigmoid  = rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
neuron :: ([Double], [Double]) :-> Double
neuron   = sigmoid . (sumI . hadamard) . (cons 1 × id)
l2 = crossI (replicate 10 neuron) . linear (\(xs,ys) -> zipWith (,) xs ys) (Dual unzip)
l1 i = crossI (replicate 300 (fixed neuron i))
mnistNet :: [Double] -> ([[Double]], [[Double]]) :-> [Double]
mnistNet i = l2 . ((dupI 10 . l1 i) × id) where n = fixed neuron i
cost :: [([Double], [Double])] -> ([[Double]], [[Double]]) :-> Double
cost  ps = sumI . crossI (map cost1 ps) . dupI (length ps)
  where cost1 (i, o) = sqrt' . sumI . crossI (replicate 10 sqr) . (negate o +>) . mnistNet i
        sqr :: Double :-> Double
        sqr = mul . dup

step examples (i :: Int) weights = do
  let (r, Dual grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10)

main = do
  let examples :: [([Double], [Double])]
      examples = _
  initialWeights <- (,) <$> mapM (const $ uniformListM 785 globalStdGen) [1..300] <*> mapM (const $ uniformListM 301 globalStdGen) [1..10]
  finalWeights   <- foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..1000000]
  putStrLn $ "Neural net results: " ++ show (map (\(e,_) -> fst (mnistNet e # finalWeights)) examples)
  putStrLn $ "Expected results:   " ++ show (map snd examples)

type Weights = ([[Double]], [[Double]])
instance Num Weights where
  fromInteger x' = (replicate 300 (replicate 785 x), replicate 10 (replicate 301 x)) where x = fromInteger x'
  (w1, w2) + (w3, w4) = (w1 + w3, w2 + w4)
instance Num a => Num [a] where
  fromInteger = repeat . fromInteger
  (+) = zipWith (+)
