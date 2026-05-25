{-# LANGUAGE GHC2024, TypeAbstractions, NoMonomorphismRestriction, PartialTypeSignatures, Strict #-} -- Strict makes a HUGE difference in this scenario
import Prelude hiding (id, (.)); import Control.Category
import System.Random.Stateful
import qualified Data.ByteString as BS
import Data.Vector.Generic.Sized (Vector)
import qualified Data.Vector.Generic.Sized as VG
import qualified Data.Vector.Generic as VC
import qualified Data.Vector.Sized as VS
import qualified Data.Vector.Unboxed.Sized as UV
import Data.Finite
import Data.Maybe
import GHC.TypeNats
import Data.Word

--------------------- Differentiable functions----------------------------------
newtype a :-> b = D { (#) :: a -> (b, b -> a) }

instance Category (:->) where
  id    = D $ \a -> (a, id)
  g . f = D $ \a -> let (b, f') = f # a; (c, g') = g # b in (c, f' . g')
                                                                   -- chain rule
f × g = D $ \(a,b) -> let (c, f') = f # a; (d, g') = g # b
                       in ((c,d), \(x,y) -> (f' x, g' y))

----------------------- Primitive/Vec functions --------------------------------
mul      = D $ \(x,y) -> (x*y, \df -> (df*y,df*x))
add'     = D $ \(x,y) -> (x+y, \d -> (d,d))
log'     = D $ \x -> (log x, (*(1/x)))
reassoc  = D $ \(a,(b,c)) -> (((a,b),c), \((da,db),dc) -> (da,(db,dc)))
f `at` a = D $ \b -> let (c, d) = f # (a, b) in (c, snd . d)  -- papp static val
rep'     = D $ \x -> (VG.replicate x, VG.sum)                -- repeat/replicate
sum'     = D $ \xs -> (UV.sum xs, UV.replicate)
zip'     = D $ \(xs,ys) -> (VG.zipWith (,) xs ys, (VG.unzip))
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

------------------------- Neural Network ---------------------------------------
relu    = D $ \v -> (max v 0, if v > 0 then id else const 0)         -- max(x,0)
softmax = D $ \v ->
  let exps = VG.generate (\i -> exp (UV.index v i - UV.maximum v)); t = UV.sum exps
      sx = VG.map (/ t) exps; s = VG.index sx; ds j i = s i * ((if i == j then 1 else 0) - s j)
  in (sx, \dv -> UV.generate (\i -> VG.sum (VG.imap (\j -> (ds i j*)) dv)))
neuron activ   = activ . add' . (dot' × id) . reassoc                -- φ(W·I+b)
mnistnet i     = softmax . map' (neuron id) . zip' . ((rep' . map' (neuron relu `at` i)) × id) -- 784x300x10
crossEntropy o = (mul `at` (-1)) . sum' . map' (mul . (id × log')) . (zip' `at` o)
cost1 (i, o)   = crossEntropy o . mnistnet i
cost ps        = sum' . cross (VS.map cost1 ps) . rep'

step i examples weights = do
  let start     = fromIntegral (getFinite i) * batchSize `mod` (nExamples - batchSize)
      batch     = fromJust $ VS.toSized @BatchSize (VC.slice start batchSize (VS.fromSized examples))
      (r, grad) = cost batch # weights
  putStrLn $ "Cost(" ++ show (getFinite i) ++ "): " ++ show r
  pure $ weights + grad (-0.0075)

loadSamples :: forall n. KnownNat n => FilePath -> FilePath -> IO (VS.Vector n (UV.Vector NIn Double, UV.Vector NOut Double))
loadSamples imgPath lblPath = do
  rawImgs <- BS.drop 16 <$> BS.readFile imgPath
  rawLbls <- BS.drop 8  <$> BS.readFile lblPath
  let labelToVec d = UV.generate (\i -> if fromIntegral (getFinite i) == d then 1 else 0)
  pure $ VS.generate $ \i ->
    let off = fromIntegral (getFinite i) * nIn
        img = UV.generate (\j -> fromIntegral (BS.index rawImgs (off + fromIntegral (getFinite j))) / 255)
    in (img, labelToVec (BS.index rawLbls (fromIntegral (getFinite i))))

type BatchSize = 60; type NIn = 784; type NMid = 300; type NOut = 10
batchSize      = 60; nIn      = 784; nMid      = 300; nExamples = 60000; type NExamples = 60000

main = do
  examples     <- loadSamples @60000 "train-images.idx3-ubyte" "train-labels.idx1-ubyte"
  testExamples <- loadSamples @10000 "t10k-images.idx3-ubyte"  "t10k-labels.idx1-ubyte"

  let xavier n = (\r -> (2*r - 1) / sqrt (fromIntegral n)) <$> randomM globalStdGen
  initialWeights <- (,) <$> VS.replicateM @NMid ((,) <$> UV.replicateM @NIn  (xavier nIn)  <*> randomM globalStdGen)
                        <*> VS.replicateM @NOut ((,) <$> UV.replicateM @NMid (xavier nMid) <*> randomM globalStdGen)
  finalWeights   <- VS.ifoldM' (\acc i _ -> step i examples acc) initialWeights (VS.enumFromN @150 {-@(NExamples `Div` BatchSize)-} 0)

  let predict e = UV.maxIndex $ fst (mnistnet e # finalWeights)
      target  t = UV.maxIndex t
      results   = VS.map (\(e, t) -> (predict e, target t)) testExamples
      correct   = length $ filter (uncurry (==)) (VS.toList results)
      accuracy  = fromIntegral correct / fromIntegral (VS.length results) :: Double

  putStrLn $ "Test accuracy: " ++ show accuracy

instance (KnownNat nin, KnownNat nmid, Num a, UV.Unbox a) => Num (VS.Vector NMid (UV.Vector nin a, a), VS.Vector NOut (UV.Vector nmid a, a)) where
  fromInteger x' = (VS.replicate @NMid (UV.replicate @nin x, x), VS.replicate @NOut (UV.replicate @nmid x, x)) where x = fromInteger x'
  (w1, w2) + (w3, w4) = (VS.zipWith addN w1 w3, VS.zipWith addN w2 w4)
    where addN (a,b) (c,d) = (UV.zipWith (+) a c, b + d)

{-
Notes:

- softmax at 150 batches: 90% accuracy; sigmoid: 16%... (btw: softmax . (map sigmoid) is 85% instead! makes some sense)
- softmax must use the "safe" version which normalizes by subtracting by the maximum before computing
- Using meanSquareError means 20% accuracy on 150 batches. cross entropy gets us 90% with same 150 batches.
- removing the bias doesn't have an effect on accuracy. but perhaps we should be initializing the biases to 0?
- Using random weights (rather than e.g. Xavier initialization) results in lots of NaNs very soon.
- Using "Strict" and let-binding the total result in `dot'` matter a lot for performance.
- The Num instance for Weights is also important for performance. e.g. using Num (a,b) kills the performance.
- We could write softmax as a composition of primitives, but it's complex.
  Follow https://eli.thegreenplace.net/2016/the-softmax-function-and-its-derivative/ instead.
  (For reference, the definition as compositions):
    softmax = map' (mul . ((rec . sum' . map' exp') × exp')) . (zip' :: _ :-> UV.Vector _ _)
            . (rep' × id) . dup . map' add . zip' . ((rep' . (mul `at` (-1)) . max') × id) . dup
- The reverse-mode/adjoint derivative of softmax, if we visualize the forward
  mode linear map derivative as a Jacobian matrix, is the matrix transpose. In
  per-output-elem terms, that means each row i uses DiS1...DiSn rather than
  D1Si...DnSi (see CoB Notebook)
     {- for forward mode, it'd be `d j i` (but the accuracy is very similar regardless of which is used...) -}
-}
