{- cabal:
 build-depends: base, random, bytestring
-}
{-# LANGUAGE GHC2024, OverloadedLists, Strict #-}
import Prelude hiding (id, (.))
import Control.Category
import Control.Monad
import System.Random.Stateful
import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as UV

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
crossI :: V.Vector (b :-> a) -> UV.Vector b :-> UV.Vector a
crossI fs = D $ \as -> let (bs, bsas) = V.unzip (V.zipWith (#) fs (UV.convert as)) in (UV.convert bs, Dual (UV.convert . V.zipWith (<|) bsas . UV.convert))
sumI      = D $ \xs -> (sum xs, Dual (\x -> UV.replicate (length xs) x))
hadamard  = D $ \(ss, xs) -> (ss .*. xs, Dual (\dfs -> (xs .*. dfs, ss .*. dfs))) where (.*.) = UV.zipWith (*)
fixed f a = D $ \b -> let (c, Dual d) = f # (a, b) in (c, Dual (snd . d))
cons    x = D $ \xs -> (x `UV.cons` xs, Dual (\dxs -> UV.drop 1 dxs)) -- add a constant number to head of Vec. All weight vecs have leading biases
--------------------------------------------------------------------------------
sigmoid  = rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
neuron   = sigmoid . (sumI . hadamard) . (cons 1 × id)
l2 :: (V.Vector (UV.Vector Double), V.Vector (UV.Vector Double)) :-> UV.Vector Double
l2 = crossI (V.replicate 10 neuron) . (linear (\(xs,ys) -> UV.convert $ V.zipWith (,) xs ys) (Dual (UV.convert V.unzip)))
l1 i = crossI (V.replicate 300 (fixed neuron i))
mnistNet :: UV.Vector Double -> Weights :-> UV.Vector Double
mnistNet i = l2 . ((dupI (V.foldr1 (UV.zipWith (+))) 10 . l1 i) × id) where n = fixed neuron i
cost :: [(UV.Vector Double, UV.Vector Double)] -> Weights :-> Double
cost  ps = sumI . crossI (V.map cost1 (V.fromList ps)) . dupI sum (length ps)
  where cost1 (i, o) = sqrt' . sumI . crossI (V.replicate 10 sqr) . what o . mnistNet i
        cost1 :: (UV.Vector Double, UV.Vector Double) -> Weights :-> Double
        sqr :: Double :-> Double
        sqr = mul . dup
        what :: UV.Vector b -> UV.Vector b :-> UV.Vector b
        what o = (UV.map (*(-1)) o +>)

step examples (i :: Int) weights = do
  let (r, Dual grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10)

main = do
  rawImages <- BS.drop 16 <$> BS.readFile "train-images.idx3-ubyte"
  rawLabels <- BS.drop 8  <$> BS.readFile "train-labels.idx1-ubyte"
  let n      = BS.length rawLabels
      imgVec :: UV.Vector Double
      imgVec  = UV.generate (n * 784) (\i -> fromIntegral (BS.index rawImages i))
      examples :: [(UV.Vector Double, UV.Vector Double)]
      examples = take 100 [ ( UV.generate 784 (\j -> imgVec UV.! (i * 784 + j))
                   , UV.singleton (fromIntegral (BS.index rawLabels i))
                   )
                 | i <- [0..n-1] ]
  initialWeights <- (,) <$> V.mapM (const $ UV.replicateM 785 $ randomM globalStdGen) [1..300] <*> V.mapM (const $ UV.replicateM 301 $ randomM globalStdGen) [1..10]
  finalWeights   <- V.foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..1000]
  putStrLn $ "Neural net results: " ++ show (map (\(e,_) -> fst (mnistNet e # finalWeights)) examples)
  putStrLn $ "Expected results:   " ++ show (map snd examples)

type Weights = (V.Vector (UV.Vector Double), V.Vector (UV.Vector Double))
instance Num Weights where
  fromInteger x' = (V.replicate 300 (UV.replicate 785 x), V.replicate 10 (UV.replicate 301 x)) where x = fromInteger x'
  (w1, w2) + (w3, w4) = (V.zipWith (UV.zipWith(+)) w1 w3, V.zipWith (UV.zipWith(+)) w2 w4)
instance Num (UV.Vector Double) where
  -- the negate/fromInteger 0/fromInteger -1 was causing such a weird loop (also the `sum` from `dupI` needing a zero..) wow.
  (+) = UV.zipWith (+)
