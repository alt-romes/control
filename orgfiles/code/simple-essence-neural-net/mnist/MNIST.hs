{-# LANGUAGE GHC2024, NoMonomorphismRestriction, PartialTypeSignatures, Strict #-} -- Strict makes a HUGE difference in this scenario
import Prelude hiding (id, (.))
import Control.Category
import System.Random.Stateful
import qualified Data.ByteString as BS
import Data.Finite hiding (add)
import Data.Vector.Generic.Sized (Vector)
import qualified Data.Vector.Generic.Sized as VG
import qualified Data.Vector.Generic as VC
import qualified Data.Vector.Sized as VS
import qualified Data.Vector.Unboxed.Sized as UV
import qualified Data.Vector as NV
import qualified Data.Vector.Unboxed as NUV
import Data.Maybe
import GHC.TypeNats

--------------------- Differentiable functions----------------------------------
newtype a :-> b = D { (#) :: a -> (b, b -> a) }

instance Category (:->) where
  id = D $ \a -> (a, id)
  g . f = D $ \a -> -- chain rule
    let (b, f') = f # a; (c, g') = g # b
     in (c, f' . g')

f × g = D $ \(a,b) ->
  let (c, f') = f # a; (d, g') = g # b
   in ((c,d), \(x,y) -> (f' x, g' y))
--------------------------------------------------------------------------------

----------------------- Primitive functions ------------------------------------
assoc    = D $ \(a,(b,c)) -> (((a,b),c), \((a,b),c) -> (a,(b,c)))
dup      = D $ \x -> ((x,x), uncurry (+))          ; dup :: Num a => a :-> (a,a)
add      = D $ \(x,y) -> (x + y, \x -> (x,x))
mul      = D $ \(x,y) -> (x*y, \df -> (df*y,df*x))
rec      = D $ \x -> (1/x, (*(-1 / x^2)))
exp'     = D $ \x -> let e = exp x in (e, (*e))
log'     = D $ \x -> (log x, (*(1/x)))                          -- new addition!
f `at` a = D $ \b -> let (c, d) = f # (a, b) in (c, snd . d)  -- papp static val
--------------------------------------------------------------------------------

------------------------- Vec primitives ---------------------------------------
rep'     = D $ \x -> (VG.replicate x, VG.sum)                -- repeat/replicate
sum'     = D $ \xs -> (UV.sum xs, UV.replicate)
zip'     = D $ \(xs,ys) -> (VG.zipWith (,) xs ys, (VG.unzip))
max'     = D $ \v -> (UV.maximum v, UV.replicate)
dot'     = D $ \case (a,b) | r <- UV.sum (UV.zipWith (*) a b) -- MUST bind for perf
                         -> (r, \d -> (UV.map (*d) b, UV.map (*d) a))
map' f   = D $ \as ->
  let pairs = VS.generate (\i -> f # VG.index as i)
   in ( VG.generate (\i -> fst (VS.index pairs i))
      , (\d -> VG.generate (\i -> snd (VS.index pairs i) (VG.index d i))) )
cross fs = D $ \as ->
  let pairs = VS.generate (\i -> VS.index fs i # VS.index as i)
   in ( UV.generate (\i -> fst (VS.index pairs i))
      , (\dfs -> VS.generate (\i -> snd (VS.index pairs i) (UV.index dfs i))) )

-- Todo: NO CONS
cons :: UV.Unbox a => a -> UV.Vector n a :-> UV.Vector (1 + n) a
cons    x = D $ \xs -> (x `UV.cons` xs, (\dxs -> UV.drop @1 dxs)) -- add a constant number to head of Vec. All weight vecs have leading biases
--------------------------------------------------------------------------------

------------------------- Neural Network ---------------------------------------
sigmoid        = rec . (add `at` 1) . exp' . (mul `at` (-1))    -- 1/(1+exp(-x))
relu = D $ \v -> (max v 0, if v > 0 then id else const 0)            -- max(x,0)
neuron activation = activation . dot' -- . (cons 1 × id)                -- φ(W·I+b)
  -- TODO GET RID OF CONS; AWFUL COPYING; USE `assoc` probably. See Simpler.hs

softmax    = map' (mul . ((rec . sum' . map' exp') × exp')) . (zip' :: _ :-> UV.Vector _ _)
            . (rep' × id) . dup . map' add . zip' . ((rep' . (mul `at` (-1)) . max') × id){-safe softmax-} . dup
mnistnet i = softmax . map' (neuron id) . zip' . ((rep' . map' (neuron relu `at` i)) × id) -- 784x300x10
  -- softmax at 150 batches: 90% accuracy; sigmoid: 16%... (btw: softmax . (map sigmoid) is 85% instead! makes some sense)

-- Using meanSquareError means 20% accuracy on 150 batches. cross entropy gets us 90% with same 150 batches.
meanSquareError o = (mul `at` (1 / batchSize)) . sum' . map' ({-sqr=-}mul . dup) . (add `at` (UV.map (*(-1)) o))
crossEntropy o = (mul `at` (-1)) . sum' . map' (mul . (id × log')) . (zip' `at` o)

cost1 (i, o) = crossEntropy o . mnistnet i
cost ps = sum' . cross (VS.map cost1 ps) . rep'

{-
step i weights | let (r, grad) = cost exs # weights
               = putStrLn ("Cost(" ++ show i ++ "): " ++ show r)
               >> return (weights + grad (-10))
-}

step examples i weights = do
  let off = (i * batchSize) `mod` (nExamples - batchSize)
      batch = fromJust $ VS.toSized @BatchSize $ NV.slice off batchSize (VS.fromSized examples)
      (r, grad) = cost batch # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-0.0075)

type BatchSize = 60
batchSize = 60

type NIn = 784
type NMid = 300
type NOut = 10
type NExamples = 60000
nIn = 784
nMid = 300
nExamples = 60000

main = do
  rawImages <- BS.drop 16 <$> BS.readFile "train-images.idx3-ubyte"
  rawLabels <- BS.drop 8  <$> BS.readFile "train-labels.idx1-ubyte"
  let allImgs = NUV.generate (BS.length rawImages) (\i -> fromIntegral @_ @Double (BS.index rawImages i) / 255)
      allLbls = NUV.generate (BS.length rawLabels) (\i -> fromIntegral @_ @Double (BS.index rawLabels i))
      examples = fromJust $ VS.fromList @NExamples $
        [ ( fromJust $ UV.toSized @NIn $ NUV.slice (i * nIn) nIn allImgs
          , labelToVec (allLbls NUV.! i) )
        | i <- [0..nExamples-1] ]

  let xavier n = (\r -> (2*r - 1) / sqrt (fromIntegral n)) <$> randomM globalStdGen
  initialWeights <- (,) <$> VS.replicateM @NMid (UV.replicateM @(NIn)  (xavier nIn))
                        <*> VS.replicateM @NOut (UV.replicateM @(NMid) (xavier nMid))
  finalWeights   <- foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..150] -- (nExamples `div` batchSize)

  -- Load test data
  rawTestImages <- BS.drop 16 <$> BS.readFile "t10k-images.idx3-ubyte"
  rawTestLabels <- BS.drop 8  <$> BS.readFile "t10k-labels.idx1-ubyte"

  let testImgs = NUV.generate (BS.length rawTestImages)
          (\i -> fromIntegral @_ @Double (BS.index rawTestImages i) / 255)

      testLbls = NUV.generate (BS.length rawTestLabels)
          (\i -> fromIntegral @_ @Double (BS.index rawTestLabels i))

      nTest = BS.length rawTestLabels

      testExamples = fromJust $ VS.fromList @10000
        [ ( fromJust $ UV.toSized @NIn $ NUV.slice (i * nIn) nIn testImgs
          , labelToVec (testLbls NUV.! i) )
        | i <- [0 .. nTest - 1]
        ]

      predict e = UV.maxIndex $ fst (mnistnet e # finalWeights)
      target  t = UV.maxIndex t
      -- we need to pick the max index, rather than compare results, bc neural
      -- net will approximate out (like 0.99 rather than 1). We want to pick
      -- a number based on the most active output neuron

      results = VS.map (\(e, t) -> (predict e, target t)) testExamples

      correct = length $ filter (uncurry (==)) (VS.toList results)
      total   = VS.length results

      accuracy = fromIntegral correct / fromIntegral total :: Double

      loss (e, t) =
        let (y, _) = mnistnet e # finalWeights
        in UV.sum $ UV.map (^2) (y - t)

      totalLoss = VS.sum $ VS.map loss testExamples
      avgLoss   = totalLoss / fromIntegral total

  putStrLn $ "Test accuracy: " ++ show accuracy
  putStrLn $ "Test loss:     " ++ show avgLoss

  putStrLn "Sample predictions (predicted, actual):"
  print $ take 10 $ VS.toList results


labelToVec d = UV.generate @10 (\i -> if fromIntegral (getFinite i) == d then 1 else 0)

type Weights nin nmid a = (VS.Vector NMid (UV.Vector nin a), VS.Vector NOut (UV.Vector nmid a))
instance (KnownNat nin, KnownNat nmid, Num a, UV.Unbox a) => Num (Weights nin nmid a) where
  fromInteger x' = (VS.replicate @NMid (UV.replicate @nin x), VS.replicate @NOut (UV.replicate @nmid x)) where x = fromInteger x'
  (w1, w2) + (w3, w4) = (VS.zipWith (UV.zipWith(+)) w1 w3, VS.zipWith (UV.zipWith(+)) w2 w4)
