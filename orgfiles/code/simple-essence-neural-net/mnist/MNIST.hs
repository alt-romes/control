{-# LANGUAGE GHC2024, TypeAbstractions, Strict, OverloadedStrings, PartialTypeSignatures,
             DeriveTraversable, DeriveGeneric, MultiParamTypeClasses,
             FlexibleInstances, LambdaCase, TypeFamilies, NoMonomorphismRestriction #-}
{-# OPTIONS_GHC -fpolymorphic-specialisation -fspecialise-aggressively -ddump-simpl -ddump-to-file -dsuppress-all #-}
import Prelude hiding (id, (.))
import Control.Category
import Control.Monad
import System.Random.Stateful
import qualified Data.ByteString as BS
import Data.Finite
import qualified Data.Vector.Sized as V
import qualified Data.Vector.Unboxed.Sized as UV
import qualified Data.Vector.Generic.Sized as GV
import qualified Data.Vector as NV
import qualified Data.Vector.Unboxed as NUV
import GHC.Generics (Generic)
import Data.Equality.Saturation (Fix(..), equalitySaturation, CostFunction, Rewrite(..))
import Data.Equality.Matching (pat)
import Data.Equality.Analysis (Analysis(..))
import Data.Equality.Graph (EGraph, represent, merge)
import Data.Equality.Graph.Lens ((^.), _class, _data)
import Data.Maybe
import GHC.TypeNats
import Control.DeepSeq (force)
import Data.Proxy

newtype a :-> b = D    { (#)  :: a -> (b, a <-- b) }
newtype a <-- b = Dual { (<|) :: b -> a            }
linear f fd = D (\a -> (f a, fd))
{-# INLINE linear #-}
scale  y    = Dual (\dx -> dx*y)
{-# INLINE scale #-}

instance Category (:->) where
  id = linear id (Dual id)
  {-# INLINE id #-}
  g . f = D $ \a -> -- chain rule
    let (b, Dual f') = f # a; (c, Dual g') = g # b
     in (c, Dual (f' . g'))
  {-# INLINE (.) #-}

f × g = D $ \(a,b) ->
  let (c, f') = f # a; (d, g') = g # b
   in ((c,d), Dual (\(x,y) -> (f' <| x, g' <| y)))
{-# INLINE (×) #-}
--------------------------------------------------------------------------------
dup       = linear (\x -> (x,x)) (Dual (uncurry (+)))
neg       = linear negate (scale (-1))
(+>) k    = linear (+k) (Dual id)
mul       = D $ \(x,y) -> (x*y, Dual (\df -> (df*y,df*x)))
rec       = D $ \x -> (recip x, scale (-1 / x^2))
exp'      = D $ \x -> let e = exp x in (e, scale e)
{-# INLINE dup #-}
{-# INLINE neg #-}
{-# INLINE (+>) #-}
{-# INLINE mul #-}
{-# INLINE rec #-}
{-# INLINE exp' #-}
-- pow  k    = D $ \x -> (x^k, scale (k*x^(k-1))) -- (^) only works for integral exponents
--------------------------------------------------------------------------------
dupI :: KnownNat n => (UV.Vector n a -> a) -> a :-> UV.Vector n a
dupI @n join = linear (\x -> UV.replicate x) (Dual join)
mapI :: (a3 :-> a2) -> UV.Vector n a3 :-> UV.Vector n a2
mapI f = D $ \as -> let (bs, bsas) = UV.unzip (UV.map (f #) as) in (bs, Dual (UV.zipWith (<|) bsas))
crossI :: V.Vector n (b :-> a) -> UV.Vector n b :-> UV.Vector n a
crossI fs = D $ \as -> let (bs, bsas) = V.unzip (V.zipWith (#) fs as) in (bs, Dual (V.zipWith (<|) bsas))
sumI :: (KnownNat n, Num b) => UV.Vector n b :-> b
sumI      = D $ \xs -> (sum xs, Dual (\x -> UV.replicate x))
weightedSum :: forall n. (KnownNat n) => (UV.Vector n Double, UV.Vector n Double) :-> Double
weightedSum = D $ \(ss, xs) ->
  let tot = foldl' (\acc i -> acc + (UV.unsafeIndex ss i * UV.unsafeIndex xs i)) 0 [0..UV.length ss-1]
   in (tot, Dual (\dfs -> (UV.map (*dfs) xs, UV.map (*dfs) ss)))
fixed f a = D $ \b -> let (c, Dual d) = f # (a, b) in (c, Dual (snd . d))
cons :: a -> UV.Vector n a :-> UV.Vector (1 + n) a
cons    x = D $ \xs -> (x `UV.cons` xs, Dual (\dxs -> UV.drop @1 dxs)) -- add a constant number to head of Vec. All weight vecs have leading biases
zip' :: _ => (GV.Vector v n a, GV.Vector v n b) :-> GV.Vector v n (a, b)
zip' = linear (\(xs,ys) -> GV.zipWith (,) xs ys) (Dual GV.unzip)
{-# INLINE dupI #-}
{-# INLINE crossI #-}
{-# INLINE sumI #-}
{-# INLINE weightedSum #-}
{-# INLINE fixed #-}
{-# INLINE cons #-}
{-# INLINE zip' #-}
--------------------------------------------------------------------------------
sigmoid  = {-# SCC sigmoid #-} rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
softmax :: forall n a. KnownNat n => UV.Vector n Double :-> UV.Vector n Double
softmax  = {-# SCC softmax #-} mapI (mul . ((rec . sumI . mapI exp') × id)) . zip' . (dupI @n sum × id) . dup
neuron :: (UV.Vector n Double, UV.Vector (1 + n) Double) :-> Double
neuron   = {-# SCC neuron #-} weightedSum . (cons 1 × id)
l2 :: (V.Vector n1 (UV.Vector n2 Double), V.Vector n1 (UV.Vector (1 + n2) Double)) :-> UV.Vector n1 Double
l2       = {-# SCC l2 #-} softmax . crossI (V.replicate neuron) . zip'
l1 :: UV.Vector n1 Double -> V.Vector n2 (UV.Vector (1 + n1) Double) :-> UV.Vector n2 Double
l1 i     = {-# SCC l1 #-} mapI (sigmoid . fixed neuron i)
mnistNet :: UV.Vector n1 Double -> Weights (1+NIn) (1+NMid) Double :-> UV.Vector NOut Double
mnistNet i = {-# SCC mnistNet #-} l2 . ((dupI @NOut (V.foldr1 (V.zipWith (+))) . l1 i) × id) where n = fixed neuron i

cost :: V.Vector BatchSize (UV.Vector NIn Double, UV.Vector NOut Double) -> Weights (1+NIn) (1+NMid) Double :-> Double
cost  ps = {-# SCC cost #-} sumI . crossI (V.map cost1 ps) . dupI sum
  where cost1 (i, o) = {-# SCC cost1 #-} fixed mul (fromIntegral $ natVal (Proxy @BatchSize)) . rec . sumI . mapI sqr . (UV.map (*(-1)) o +>) . mnistNet i
        sqr = {-# SCC sqr #-} mul . dup

type BatchSize = 32
batchSize = 32

step :: V.Vector NExamples (UV.Vector NIn Double, UV.Vector NOut Double) -> Int
     -> Weights (1+NIn) (1+NMid) Double
     -> IO (Weights (1+NIn) (1+NMid) Double)
step examples i weights = {-# SCC step #-} do
  let off = (i * batchSize) `mod` (nExamples - batchSize)
      batch = fromJust $ V.toSized @BatchSize $ NV.slice off batchSize (V.fromSized examples)
      (r, Dual grad) = cost batch # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  -- putStrLn $ "Grad(" ++ show i ++ "): " ++ show (V.index (fst $ grad 1) (finite 0))
  pure $ weights + grad (-0.01/batchSize)

type NIn = 784
type NMid = 300
type NOut = 10
type NExamples = 60000
nIn = 784
nMid = 300
nOut = 10
nExamples = 60000

-- main = symGradCostSize
-- mainX = do
main = do
  rawImages <- BS.drop 16 <$> BS.readFile "train-images.idx3-ubyte"
  rawLabels <- BS.drop 8  <$> BS.readFile "train-labels.idx1-ubyte"
  let allImgs = NUV.generate (BS.length rawImages) (\i -> fromIntegral @_ @Double (BS.index rawImages i) / 255)
      allLbls = NUV.generate (BS.length rawLabels) (\i -> fromIntegral @_ @Double (BS.index rawLabels i))
      examples = force $ fromJust $ V.fromList $
        [ ( fromJust $ UV.toSized @NIn $ NUV.slice (i * nIn) nIn allImgs
          , labelToVec (allLbls NUV.! i) )
        | i <- [0..nExamples-1] ]

  let xavier n = (\r -> (2*r - 1) / sqrt (fromIntegral n)) <$> randomM globalStdGen
  initialWeights <- (,) <$> V.replicateM @NMid (V.replicateM @(1+NIn)  (xavier nIn))
                        <*> V.replicateM @NOut (V.replicateM @(1+NMid) (xavier nMid))
  finalWeights   <- foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..150]

  -- Load test data
  rawTestImages <- BS.drop 16 <$> BS.readFile "t10k-images.idx3-ubyte"
  rawTestLabels <- BS.drop 8  <$> BS.readFile "t10k-labels.idx1-ubyte"

  let testImgs = force $ NUV.generate (BS.length rawTestImages)
          (\i -> fromIntegral @_ @Double (BS.index rawTestImages i) / 255)

      testLbls = force $ NUV.generate (BS.length rawTestLabels)
          (\i -> fromIntegral @_ @Double (BS.index rawTestLabels i))

      nTest = BS.length rawTestLabels

      testExamples = force $ V.take @1000 $ fromJust $ V.fromList @10000
        [ ( fromJust $ UV.toSized @NIn $ NUV.slice (i * nIn) nIn testImgs
          , labelToVec (testLbls NUV.! i) )
        | i <- [0 .. nTest - 1]
        ]

      predict e = UV.maxIndex $ fst (mnistNet e # finalWeights)
      target  t = UV.maxIndex t

      results = V.map (\(e, t) -> (predict e, target t)) testExamples

      correct = length $ filter (uncurry (==)) (V.toList results)
      total   = V.length results

      accuracy = fromIntegral correct / fromIntegral total :: Double

      loss (e, t) =
        let (y, _) = mnistNet e # finalWeights
        in V.sum $ V.map (^2) (y - t)   -- use your existing loss

      totalLoss = V.sum $ V.map loss testExamples
      avgLoss   = totalLoss / fromIntegral total

  putStrLn $ "Test accuracy: " ++ show accuracy
  putStrLn $ "Test loss:     " ++ show avgLoss

  putStrLn "Sample predictions (predicted, actual):"
  print $ take 10 $ V.toList results


labelToVec :: Double -> UV.Vector 10 Double
labelToVec d = UV.generate @10 (\i -> if fromIntegral (getFinite i) == d then 1 else 0)

type Weights nin nmid a = (V.Vector NMid (UV.Vector nin a), V.Vector NOut (UV.Vector nmid a))
instance (KnownNat nin, KnownNat nmid, Num a) => Num (Weights nin nmid a) where
  fromInteger x' = (V.replicate @NMid (UV.replicate @nin x), V.replicate @NOut (UV.replicate @nmid x)) where x = fromInteger x'
  (w1, w2) + (w3, w4) = (V.zipWith (UV.zipWith(+)) w1 w3, V.zipWith (UV.zipWith(+)) w2 w4)

--------------------------------------------------------------------------------
-- Symbolic ad
--------------------------------------------------------------------------------

data Expr = Const Double
          | Var String
          | Add Expr Expr
          | Mul Expr Expr
          | Neg Expr
          | Rec Expr
          | Exp Expr
          | Sqrt Expr

instance Show Expr where
  show (Const d) = show d
  show (Var c)   = c
  show (Add a b) = "(" ++ show a ++ " + " ++ show b ++ ")"
  show (Mul a b) = "(" ++ show a ++ " * " ++ show b ++ ")"
  show (Neg a)   = "(-" ++ show a ++ ")"
  show (Rec a)   = "(1/" ++ show a ++ ")"
  show (Exp a)   = "exp(" ++ show a ++ ")"
  show (Sqrt a)  = "sqrt(" ++ show a ++ ")"

instance Num Expr where
  (+)         = Add
  (*)         = Mul
  negate      = Neg
  fromInteger = Const . fromInteger

instance Fractional Expr where
  recip        = Rec
  fromRational = Const . fromRational

instance Floating Expr where
  exp   = Exp
  sqrt  = Sqrt
  pi    = Const pi

-- symGrad :: IO ()
-- symGrad = do
--   let (yS, Dual gS) = sigmoid # Var "x"
--   putStrLn $ "sigmoid(x)         = " ++ show yS
--   putStrLn $ "k * d/dx sigmoid x = " ++ show (gS (Var "k"))
--   putStrLn $ "k * d/dx sigmoid x = " ++ show (gS (Var "k"))
--   let sqr = mul . dup
--       (yQ, Dual gQ) = sqr # Var "x"
--   putStrLn $ "x*x                = " ++ show yQ
--   putStrLn $ "k * d/dx (x*x)     = " ++ show (gQ (Var "k"))
