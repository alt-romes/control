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
import qualified Data.Vector.Sized as VS
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
add'      = D $ \(x,y) -> (x+y, Dual (\df -> (df,df)))
mul       = D $ \(x,y) -> (x*y, Dual (\df -> (df*y,df*x)))
rec       = D $ \x -> (recip x, scale (-1 / x^2))
exp'      = D $ \x -> let e = exp x in (e, scale e)
log'      = D $ \x -> (log x, scale (1/x))
{-# INLINE dup #-}
{-# INLINE neg #-}
{-# INLINE (+>) #-}
{-# INLINE mul #-}
{-# INLINE rec #-}
{-# INLINE exp' #-}
-- pow  k    = D $ \x -> (x^k, scale (k*x^(k-1))) -- (^) only works for integral exponents
--------------------------------------------------------------------------------
dupI :: (KnownNat n, UV.Unbox a) => (UV.Vector n a -> a) -> a :-> UV.Vector n a
dupI @n join = linear UV.replicate (Dual join)
dupIB :: (KnownNat n) => (VS.Vector n a -> a) -> a :-> VS.Vector n a
dupIB @n join = linear VS.replicate (Dual join)
mapI :: forall n b a. (KnownNat n, UV.Unbox a, UV.Unbox b) => (b :-> a) -> UV.Vector n b :-> UV.Vector n a
mapI f = D $ \as ->
  let pairs = VS.generate @n (\i -> f # UV.index as i)
   in (UV.generate (\i -> fst (VS.index pairs i)), Dual (\dfs -> UV.generate (\i -> snd (VS.index pairs i) <| UV.index dfs i)))
mapIB :: forall n b a. (KnownNat n, UV.Unbox a, UV.Unbox b) => (b :-> a) -> VS.Vector n b :-> UV.Vector n a -- could merge these two by using GV.Vector as first arg and as result of Dual
mapIB f = D $ \as ->
  let pairs = VS.generate @n (\i -> f # VS.index as i)
   in (UV.generate (\i -> fst (VS.index pairs i)), Dual (\dfs -> VS.generate (\i -> snd (VS.index pairs i) <| UV.index dfs i)))
crossI :: forall n b a. (KnownNat n, UV.Unbox a, UV.Unbox b) => VS.Vector n (b :-> a) -> UV.Vector n b :-> UV.Vector n a
crossI fs = D $ \as ->
  let pairs = VS.generate @n (\i -> VS.index fs i # UV.index as i)
   in (UV.generate (\i -> fst (VS.index pairs i)), Dual (\dfs -> UV.generate (\i -> snd (VS.index pairs i) <| UV.index dfs i)))
crossIB :: forall n b a. (KnownNat n, UV.Unbox a) => VS.Vector n (b :-> a) -> VS.Vector n b :-> UV.Vector n a
crossIB fs = D $ \as ->
  let pairs = VS.generate @n (\i -> VS.index fs i # VS.index as i)
   in (UV.generate (\i -> fst (VS.index pairs i)), Dual (\dfs -> VS.generate (\i -> snd (VS.index pairs i) <| UV.index dfs i)))
sumI :: (KnownNat n, Num b, UV.Unbox b) => UV.Vector n b :-> b
sumI      = D $ \xs -> (UV.sum xs, Dual UV.replicate)
dot :: forall n. (KnownNat n) => (UV.Vector n Double, UV.Vector n Double) :-> Double
dot = D $ \(ss, xs) ->
  let tot = UV.sum $ UV.zipWith (*) ss xs
   in (tot, Dual (\dfs -> (UV.map (*dfs) xs, UV.map (*dfs) ss)))
fixed f a = D $ \b -> let (c, Dual d) = f # (a, b) in (c, Dual (snd . d))
cons :: UV.Unbox a => a -> UV.Vector n a :-> UV.Vector (1 + n) a
cons    x = D $ \xs -> (x `UV.cons` xs, Dual (\dxs -> UV.drop @1 dxs)) -- add a constant number to head of Vec. All weight vecs have leading biases
-- zip' :: _ => (GV.Vector v n a, GV.Vector v n b) :-> GV.Vector v n (a, b)
-- zip' :: (UV.Vector n a, UV.Vector n b) :-> VS.Vector n (a, b)
zip' = linear (\(xs,ys) -> UV.zipWith (,) xs ys) (Dual UV.unzip)
zipB :: (VS.Vector n a, VS.Vector n b) :-> VS.Vector n (a, b)
zipB = linear (\(xs,ys) -> VS.zipWith (,) xs ys) (Dual VS.unzip)
{-# INLINE dupI #-}
{-# INLINE crossI #-}
{-# INLINE sumI #-}
{-# INLINE dot #-}
{-# INLINE fixed #-}
{-# INLINE cons #-}
{-# INLINE zip' #-}
max' :: KnownNat (n+1) => UV.Vector (n+1) Double :-> Double
max' = D $ \v -> (UV.maximum v, Dual UV.replicate)
{-# INLINE max' #-}

relu = D $ \v -> (max v 0, Dual (if v > 0 then id else const 0))
--------------------------------------------------------------------------------
sigmoid  = {-# SCC sigmoid #-} rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
softmax :: forall n. KnownNat (n+1) -- safe softmax (to not get NaN)
        => UV.Vector (n+1) Double :-> UV.Vector (n+1) Double
softmax  = {-# SCC softmax #-}
  mapI @(n+1) (mul . ((rec . sumI . mapI exp') × exp'))
    . zip' . (dupI UV.sum × id) . dup . mapI add' . zip' . ((dupI @(n+1) UV.sum . neg . max') × id){-safe softmax-} . dup
neuron :: KnownNat (1+n) => (UV.Vector n Double, UV.Vector (1 + n) Double) :-> Double
neuron   = {-# SCC neuron #-} dot . (cons 1 × id)
l2 :: (VS.Vector NOut (UV.Vector NMid Double), VS.Vector NOut (UV.Vector (1 + NMid) Double)) :-> UV.Vector NOut Double
l2       = {-# SCC l2 #-} softmax . mapIB neuron . zipB
l1 :: UV.Vector NIn Double -> VS.Vector NMid (UV.Vector (1 + NIn) Double) :-> UV.Vector NMid Double
l1 i     = {-# SCC l1 #-} mapIB (relu {-sigmoid-} . fixed neuron i)
mnistNet :: UV.Vector NIn Double -> Weights (1+NIn) (1+NMid) Double :-> UV.Vector NOut Double
mnistNet i = {-# SCC mnistNet #-} l2 . ((dupIB @NOut (VS.foldr1 (UV.zipWith (+))) . l1 i) × id)

meanSquareError :: UV.Vector NOut Double -> UV.Vector NOut Double :-> Double -- well, already after subtract
meanSquareError o = fixed mul (1 / fromIntegral batchSize) . sumI . mapI sqr . (UV.map (*(-1)) o +>)
  where sqr = {-# SCC sqr #-} mul . dup

crossEntropy :: UV.Vector NOut Double -> UV.Vector NOut Double :-> Double
crossEntropy o = neg . sumI . mapI (mul . (id × log')) . fixed zip' o

cost :: VS.Vector BatchSize (UV.Vector NIn Double, UV.Vector NOut Double) -> Weights (1+NIn) (1+NMid) Double :-> Double
cost  ps = {-# SCC cost #-} sumI . crossIB (VS.map cost1 ps) . dupIB VS.sum
  where cost1 (i, o) = {-# SCC cost1 #-} crossEntropy o . mnistNet i

step :: VS.Vector NExamples (UV.Vector NIn Double, UV.Vector NOut Double) -> Int
     -> Weights (1+NIn) (1+NMid) Double
     -> IO (Weights (1+NIn) (1+NMid) Double)
step examples i weights = {-# SCC step #-} do
  let off = (i * batchSize) `mod` (nExamples - batchSize)
      batch = fromJust $ VS.toSized @BatchSize $ NV.slice off batchSize (VS.fromSized examples)
      (r, Dual grad) = cost batch # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  -- putStrLn $ "Grad(" ++ show i ++ "): " ++ show (V.index (fst $ grad 1) (finite 0))
  -- putStrLn $ "Max weights:" ++ show (UV.maximum $ VS.maximum $ snd weights)
  pure $ weights + grad (-0.01)

type BatchSize = 64
batchSize = 64

type NIn = 784
type NMid = 300
type NOut = 10
type NExamples = 60000
nIn = 784
nMid = 300
nOut = 10
nExamples = 60000

-- -- main = symGradCostSize
-- -- mainX = do
main = do
  rawImages <- BS.drop 16 <$> BS.readFile "train-images.idx3-ubyte"
  rawLabels <- BS.drop 8  <$> BS.readFile "train-labels.idx1-ubyte"
  let allImgs = NUV.generate (BS.length rawImages) (\i -> fromIntegral @_ @Double (BS.index rawImages i) / 255)
      allLbls = NUV.generate (BS.length rawLabels) (\i -> fromIntegral @_ @Double (BS.index rawLabels i))
      examples = force $ fromJust $ VS.fromList $
        [ ( fromJust $ UV.toSized @NIn $ NUV.slice (i * nIn) nIn allImgs
          , labelToVec (allLbls NUV.! i) )
        | i <- [0..nExamples-1] ]

  let xavier n = (\r -> (2*r - 1) / sqrt (fromIntegral n)) <$> randomM globalStdGen
  initialWeights <- (,) <$> VS.replicateM @NMid (UV.replicateM @(1+NIn)  (xavier nIn))
                        <*> VS.replicateM @NOut (UV.replicateM @(1+NMid) (xavier nMid))
  finalWeights   <- foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..(nExamples `div` batchSize)]
  -- finalWeights   <- foldl' (\acc i -> acc >>= step examples i) (pure finalWeights0) [0..(nExamples `div` batchSize)]

  -- Load test data
  rawTestImages <- BS.drop 16 <$> BS.readFile "t10k-images.idx3-ubyte"
  rawTestLabels <- BS.drop 8  <$> BS.readFile "t10k-labels.idx1-ubyte"

  let testImgs = force $ NUV.generate (BS.length rawTestImages)
          (\i -> fromIntegral @_ @Double (BS.index rawTestImages i) / 255)

      testLbls = force $ NUV.generate (BS.length rawTestLabels)
          (\i -> fromIntegral @_ @Double (BS.index rawTestLabels i))

      nTest = BS.length rawTestLabels

      testExamples = force $ fromJust $ VS.fromList @10000
        [ ( fromJust $ UV.toSized @NIn $ NUV.slice (i * nIn) nIn testImgs
          , labelToVec (testLbls NUV.! i) )
        | i <- [0 .. nTest - 1]
        ]

      predict e = UV.maxIndex $ fst (mnistNet e # finalWeights)
      target  t = UV.maxIndex t
      -- we need to pick the max index, rather than compare results, bc neural
      -- net will approximate out (like 0.99 rather than 1). We want to pick
      -- a number based on the most active output neuron

      results = VS.map (\(e, t) -> (predict e, target t)) testExamples

      correct = length $ filter (uncurry (==)) (VS.toList results)
      total   = VS.length results

      accuracy = fromIntegral correct / fromIntegral total :: Double

      loss (e, t) =
        let (y, _) = mnistNet e # finalWeights
        in UV.sum $ UV.map (^2) (y - t)

      totalLoss = VS.sum $ VS.map loss testExamples
      avgLoss   = totalLoss / fromIntegral total

  putStrLn $ "Test accuracy: " ++ show accuracy
  putStrLn $ "Test loss:     " ++ show avgLoss

  putStrLn "Sample predictions (predicted, actual):"
  print $ take 10 $ VS.toList results


labelToVec :: Double -> UV.Vector 10 Double
labelToVec d = UV.generate @10 (\i -> if fromIntegral (getFinite i) == d then 1 else 0)

type Weights nin nmid a = (VS.Vector NMid (UV.Vector nin a), VS.Vector NOut (UV.Vector nmid a))
instance (KnownNat nin, KnownNat nmid, Num a, UV.Unbox a) => Num (Weights nin nmid a) where
  fromInteger x' = (VS.replicate @NMid (UV.replicate @nin x), VS.replicate @NOut (UV.replicate @nmid x)) where x = fromInteger x'
  (w1, w2) + (w3, w4) = (VS.zipWith (UV.zipWith(+)) w1 w3, VS.zipWith (UV.zipWith(+)) w2 w4)

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
