{- cabal:
 build-depends: base, random, bytestring
-}
{-# LANGUAGE GHC2024, OverloadedLists #-}
import Prelude hiding (id, (.))
import Control.Category
import Control.Monad
import System.Random.Stateful
import qualified Data.ByteString as BS
import qualified Data.Vector as V
import GHC.Base (build)

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
dupI join n = linear (\x -> V.replicate n x) (Dual join)
crossI fs = D $ \as -> let (bs, bsas) = V.unzip (V.zipWith (#) fs as) in (bs, Dual (V.zipWith (<|) bsas))
sumI      = D $ \xs -> (sum xs, Dual (\x -> V.replicate (length xs) x))
hadamard  = D $ \(ss, xs) -> (ss .*. xs, Dual (\dfs -> (xs .*. dfs, ss .*. dfs))) where (.*.) = V.zipWith (*)
fixed f a = D $ \b -> let (c, Dual d) = f # (a, b) in (c, Dual (snd . d))
cons    x = D $ \xs -> (x `V.cons` xs, Dual (\dxs -> V.drop 1 dxs)) -- add a constant number to head of Vec. All weight vecs have leading biases
--------------------------------------------------------------------------------
sigmoid  = rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
neuron :: (V.Vector Double, V.Vector Double) :-> Double
neuron   = sigmoid . (sumI . hadamard) . (cons 1 × id)
l2 = crossI (V.replicate 10 neuron) . (linear (\(xs,ys) -> V.zipWith (,) xs ys) (Dual V.unzip))
l1 :: V.Vector Double -> V.Vector (V.Vector Double) :-> V.Vector Double
l1 i = crossI (V.replicate 300 (fixed neuron i))
mnistNet :: V.Vector Double -> (V.Vector (V.Vector Double), V.Vector (V.Vector Double)) :-> V.Vector Double
mnistNet i = l2 . ((dupI (V.foldr1 (V.zipWith (+))) 10 . l1 i) × id) where n = fixed neuron i
cost :: [(V.Vector Double, V.Vector Double)]
     -> (V.Vector (V.Vector Double), V.Vector (V.Vector Double)) :-> Double
cost  ps = sumI . crossI (V.map cost1 (V.fromList ps)) . dupI sum (length ps)
  where cost1 (i, o) = sqrt' . sumI . crossI (V.replicate 10 sqr) . (V.map (*(-1)) o +>) . mnistNet i
        sqr :: Double :-> Double
        sqr = mul . dup

step :: [(V.Vector Double, V.Vector Double)]
     -> Int
     -> (V.Vector (V.Vector Double), V.Vector (V.Vector Double))
     -> IO (V.Vector (V.Vector Double), V.Vector (V.Vector Double))
step examples (i :: Int) weights = do
  let (r, Dual grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10)

main = do
  images <- map (fromIntegral @_ @Double) . BS.unpack <$> BS.readFile "train-images.idx3-ubyte"
  labels <- map (fromIntegral @_ @Double) . BS.unpack <$> BS.readFile "train-labels.idx1-ubyte"
  let examples :: [(V.Vector Double, V.Vector Double)]
      examples = zipWith (,) (map V.fromList $ chunksOf 784 images) (map V.singleton labels)
  initialWeights <- (,) <$> V.mapM (const $ V.replicateM 785 $ randomM globalStdGen) [1..300] <*> V.mapM (const $ V.replicateM 301 $ randomM globalStdGen) [1..10]
  finalWeights   <- V.foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..1000]
  putStrLn $ "Neural net results: " ++ show (map (\(e,_) -> fst (mnistNet e # finalWeights)) examples)
  putStrLn $ "Expected results:   " ++ show (map snd examples)

type Weights = (V.Vector (V.Vector Double), V.Vector (V.Vector Double))
instance Num Weights where
  fromInteger x' = (V.replicate 300 (V.replicate 785 x), V.replicate 10 (V.replicate 301 x)) where x = fromInteger x'
  (w1, w2) + (w3, w4) = (V.zipWith (V.zipWith(+)) w1 w3, V.zipWith (V.zipWith(+)) w2 w4)
instance Num (V.Vector Double) where
  -- the negate/fromInteger 0/fromInteger -1 was causing such a weird loop (also the `sum` from `dupI` needing a zero..) wow.
  (+) = V.zipWith (+)
chunksOf :: Int -> [e] -> [[e]]
chunksOf i ls = map (take i) (build (splitter ls))
 where
  splitter :: [e] -> ([e] -> a -> a) -> a -> a
  splitter [] _ n = n
  splitter l c n = l `c` splitter (drop i l) c n
