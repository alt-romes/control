{-# LANGUAGE GHC2024, TypeAbstractions, Strict, OverloadedStrings,
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
import qualified Data.Vector as NV
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
dupI :: KnownNat n => (V.Vector n a -> a) -> a :-> V.Vector n a
dupI @n join = linear (\x -> V.replicate x) (Dual join)
crossI fs = D $ \as -> let (bs, bsas) = V.unzip (V.zipWith (#) fs as) in (bs, Dual (V.zipWith (<|) bsas))
sumI :: (KnownNat n, Num b) => V.Vector n b :-> b
sumI      = D $ \xs -> (sum xs, Dual (\x -> V.replicate x))
weightedSum :: forall n c. (KnownNat n, Num c)
            => (V.Vector n c, V.Vector n c) :-> c
weightedSum = D $ \(ss, xs) ->
  let tot = foldl' (\acc i -> acc + (V.unsafeIndex ss i * V.unsafeIndex xs i)) 0 [0..V.length ss-1]
   in (tot, Dual (\dfs -> (V.zipWith (*) xs (V.replicate dfs), V.zipWith (*) ss (V.replicate dfs))))
fixed f a = D $ \b -> let (c, Dual d) = f # (a, b) in (c, Dual (snd . d))
cons :: a -> V.Vector n a :-> V.Vector (1 + n) a
cons    x = D $ \xs -> (x `V.cons` xs, Dual (\dxs -> V.drop @1 dxs)) -- add a constant number to head of Vec. All weight vecs have leading biases
zip' = linear (\(xs,ys) -> V.zipWith (,) xs ys) (Dual V.unzip)
{-# INLINE dupI #-}
{-# INLINE crossI #-}
{-# INLINE sumI #-}
{-# INLINE weightedSum #-}
{-# INLINE fixed #-}
{-# INLINE cons #-}
{-# INLINE zip' #-}
--------------------------------------------------------------------------------
sigmoid  = {-# SCC sigmoid #-} rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
softmax :: forall n a. (KnownNat n, Floating a) => V.Vector n a :-> V.Vector n a
softmax  = {-# SCC softmax #-} crossI (V.replicate @n (mul . ((rec . sumI . crossI (V.replicate @n exp')) × id))) . zip' . (dupI @n sum × id) . dup
neuron   = {-# SCC neuron #-} weightedSum . (cons 1 × id)
l2       = {-# SCC l2 #-} softmax . crossI (V.replicate @NOut neuron) . zip'
l1 i     = {-# SCC l1 #-} crossI (V.replicate @NMid (sigmoid . fixed neuron i))
mnistNet i = {-# SCC mnistNet #-} l2 . ((dupI @NOut (V.foldr1 (V.zipWith (+))) . l1 i) × id) where n = fixed neuron i

cost :: V.Vector BatchSize (V.Vector NIn Double, V.Vector NOut Double) -> Weights (1+NIn) (1+NMid) Double :-> Double
cost  ps = {-# SCC cost #-} sumI . crossI (V.map cost1 ps) . dupI sum
  where cost1 (i, o) = {-# SCC cost1 #-} fixed mul (fromIntegral $ natVal (Proxy @BatchSize)) . rec . sumI . crossI (V.replicate @NOut sqr) . (V.map (*(-1)) o +>) . mnistNet i
        sqr = {-# SCC sqr #-} mul . dup

type BatchSize = 32
batchSize = 32

step :: V.Vector NExamples (V.Vector NIn Double, V.Vector NOut Double) -> Int
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
  let allImgs = force $ NV.generate (BS.length rawImages) (\i -> fromIntegral @_ @Double (BS.index rawImages i) / 255)
      allLbls = force $ NV.generate (BS.length rawLabels) (\i -> fromIntegral @_ @Double (BS.index rawLabels i))
      examples = force $ fromJust $ V.fromList $
        [ ( fromJust $ V.toSized @NIn $ NV.slice (i * nIn) nIn allImgs
          , labelToVec (allLbls NV.! i) )
        | i <- [0..nExamples-1] ]

  let xavier n = (\r -> (2*r - 1) / sqrt (fromIntegral n)) <$> randomM globalStdGen
  initialWeights <- (,) <$> V.replicateM @NMid (V.replicateM @(1+NIn)  (xavier nIn))
                        <*> V.replicateM @NOut (V.replicateM @(1+NMid) (xavier nMid))
  finalWeights   <- foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..150]

  -- Load test data
  rawTestImages <- BS.drop 16 <$> BS.readFile "t10k-images.idx3-ubyte"
  rawTestLabels <- BS.drop 8  <$> BS.readFile "t10k-labels.idx1-ubyte"

  let testImgs = force $ NV.generate (BS.length rawTestImages)
          (\i -> fromIntegral @_ @Double (BS.index rawTestImages i) / 255)

      testLbls = force $ NV.generate (BS.length rawTestLabels)
          (\i -> fromIntegral @_ @Double (BS.index rawTestLabels i))

      nTest = BS.length rawTestLabels

      testExamples = force $ V.take @1000 $ fromJust $ V.fromList @10000
        [ ( fromJust $ V.toSized @NIn $ NV.slice (i * nIn) nIn testImgs
          , labelToVec (testLbls NV.! i) )
        | i <- [0 .. nTest - 1]
        ]

      predict e = V.maxIndex $ fst (mnistNet e # finalWeights)
      target  t = V.maxIndex t

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


labelToVec :: Double -> V.Vector 10 Double
labelToVec d = V.generate @10 (\i -> if fromIntegral (getFinite i) == d then 1 else 0)

type Weights nin nmid a = (V.Vector NMid (V.Vector nin a), V.Vector NOut (V.Vector nmid a))
instance (KnownNat nin, KnownNat nmid, Num a) => Num (Weights nin nmid a) where
  fromInteger x' = (V.replicate @NMid (V.replicate @nin x), V.replicate @NOut (V.replicate @nmid x)) where x = fromInteger x'
  (w1, w2) + (w3, w4) = (V.zipWith (V.zipWith(+)) w1 w3, V.zipWith (V.zipWith(+)) w2 w4)

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
