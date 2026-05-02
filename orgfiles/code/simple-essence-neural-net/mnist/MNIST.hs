{-# LANGUAGE GHC2024, TypeAbstractions, Strict, OverloadedStrings,
             DeriveTraversable, DeriveGeneric, MultiParamTypeClasses,
             FlexibleInstances, LambdaCase, TypeFamilies, NoMonomorphismRestriction #-}
{-# OPTIONS_GHC -fpolymorphic-specialisation -fspecialise-aggressively -fexpose-all-unfoldings #-}
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
import GHC.TypeLits

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
dupI :: KnownNat n => (V.Vector n a -> a) -> a :-> V.Vector n a
dupI @n join = linear (\x -> V.replicate x) (Dual join)
crossI fs = D $ \as -> let (bs, bsas) = V.unzip (V.zipWith (#) fs as) in (bs, Dual (V.zipWith (<|) bsas))
sumI :: (KnownNat n, Num b) => V.Vector n b :-> b
sumI      = D $ \xs -> (sum xs, Dual (\x -> V.replicate x))
hadamard  = D $ \(ss, xs) -> (ss .*. xs, Dual (\dfs -> (xs .*. dfs, ss .*. dfs))) where (.*.) = V.zipWith (*)
fixed f a = D $ \b -> let (c, Dual d) = f # (a, b) in (c, Dual (snd . d))
cons    x = D $ \xs -> (x `V.cons` xs, Dual (\dxs -> V.drop @1 dxs)) -- add a constant number to head of Vec. All weight vecs have leading biases
--------------------------------------------------------------------------------
sigmoid  = rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
neuron   = sigmoid . (sumI . hadamard) -- . (cons 1 × id) TODO: Re-add BIAS
l2       = crossI (V.replicate @NOut neuron) . (linear (\(xs,ys) -> V.zipWith (,) xs ys) (Dual V.unzip))
l1 i     = crossI (V.replicate @NMid (fixed neuron i))
mnistNet i = l2 . ((dupI @NOut (V.foldr1 (V.zipWith (+))) . l1 i) × id) where n = fixed neuron i

cost :: (KnownNat nexs, Floating a) => V.Vector nexs (V.Vector NIn a, V.Vector NOut a) -> Weights a :-> a
cost  ps = sumI . crossI (V.map cost1 ps) . dupI sum
  where cost1 (i, o) = sqrt' . sumI . crossI (V.replicate @NOut sqr) . (V.map (*(-1)) o +>) . mnistNet i
        sqr = mul . dup

step :: (Show a, Floating a) => V.Vector NExamples (V.Vector NIn a, V.Vector NOut a) -> Int -> Weights a -> IO (Weights a)
step examples (i :: Int) weights = do
  let (r, Dual grad) = cost (V.take @1 ({-drop (i*10)-} examples)) # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  -- putStrLn $ "Grad(" ++ show i ++ "): " ++ show (V.index (fst $ grad 1) (finite 0))
  pure $ weights + grad 100

type NIn = 784
type NMid = 300
type NOut = 10
type NExamples = 60000
nIn = 784
nMid = 300
nOut = 10
nExamples = 60000

main = symGradCostSize
mainX = do
-- main = do
  rawImages <- BS.drop 16 <$> BS.readFile "train-images.idx3-ubyte"
  rawLabels <- BS.drop 8  <$> BS.readFile "train-labels.idx1-ubyte"
  let toV bs  = NV.generate (BS.length bs) (fromIntegral @_ @Double . BS.index bs)
      allImgs = toV rawImages
      allLbls = toV rawLabels
      examples = fromJust $ V.fromList $
        [ ( fromJust $ V.toSized @NIn $ NV.slice (i * nIn) nIn allImgs
          , labelToVec (allLbls NV.! i) )
        | i <- [0..nExamples-1] ]
  initialWeights <- (,) <$> V.replicateM @NMid (V.replicateM @NIn $ randomM globalStdGen) <*> V.replicateM @NOut (V.replicateM @NMid $ (randomM globalStdGen))
  finalWeights   <- foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..1]
  pure ()
  -- putStrLn $ "Neural net results: " ++ show (map (\(e,_) -> fst (mnistNet e # finalWeights)) (V.toList examples))
  -- putStrLn $ "Expected results:   " ++ show (map snd (V.toList examples))

labelToVec :: Double -> V.Vector 10 Double
labelToVec d = V.generate @10 (\i -> if fromIntegral (getFinite i) == d then 1 else 0)

type Weights a = (V.Vector NMid (V.Vector NIn a), V.Vector NOut (V.Vector NMid a))
instance Num a => Num (Weights a) where
  fromInteger x' = (V.replicate @NMid (V.replicate @NIn x), V.replicate @NOut (V.replicate @NMid x)) where x = fromInteger x'
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

symGrad :: IO ()
symGrad = do
  let (yS, Dual gS) = sigmoid # Var "x"
  putStrLn $ "sigmoid(x)         = " ++ show yS
  putStrLn $ "k * d/dx sigmoid x = " ++ show (gS (Var "k"))
  putStrLn $ "k * d/dx sigmoid x = " ++ show (gS (Var "k"))
  let sqr = mul . dup
      (yQ, Dual gQ) = sqr # Var "x"
  putStrLn $ "x*x                = " ++ show yQ
  putStrLn $ "k * d/dx (x*x)     = " ++ show (gQ (Var "k"))

size :: Expr -> Int
size (Const _) = 1
size (Var _)   = 1
size (Add a b) = 1 + size a + size b
size (Mul a b) = 1 + size a + size b
size (Neg a)   = 1 + size a
size (Rec a)   = 1 + size a
size (Exp a)   = 1 + size a
size (Sqrt a)  = 1 + size a

eval :: (String -> Double) -> Expr -> Double
eval _env (Const d) = d
eval  env (Var x)   = env x
eval  env (Add a b) = eval env a + eval env b
eval  env (Mul a b) = eval env a * eval env b
eval  env (Neg a)   = negate (eval env a)
eval  env (Rec a)   = recip (eval env a)
eval  env (Exp a)   = exp (eval env a)
eval  env (Sqrt a)  = sqrt (eval env a)

lookupVec :: (V.Vector 784 Double, V.Vector 10 Double) -> String -> Double
lookupVec (ins,out) ('x':is) = V.index ins (finite @784 (read is))
lookupVec (ins,out) ('y':is) = V.index out (finite @10 (read is))

-- symGradCostSize :: IO ()
-- symGradCostSize = do
symGradCostSize = do
  rawImages <- BS.drop 16 <$> BS.readFile "train-images.idx3-ubyte"
  rawLabels <- BS.drop 8  <$> BS.readFile "train-labels.idx1-ubyte"
  let toV bs  = NV.generate (BS.length bs) (fromIntegral @_ @Double . BS.index bs)
      allImgs = toV rawImages
      allLbls = toV rawLabels
      examples = fromJust $ V.fromList @NExamples $
        [ ( fromJust $ V.toSized @NIn $ NV.slice (i * nIn) nIn allImgs
          , labelToVec (allLbls NV.! i) )
        | i <- [0..nExamples-1] ]
      example = (V.generate @NIn (\i -> Var $ 'x':show i), V.generate @NOut (\i -> Var $ 'y':show i))
  weights <- (,) <$> V.replicateM @NMid (V.replicateM @NIn $ Const <$> randomM globalStdGen) <*> V.replicateM @NOut (V.replicateM @NMid $ Const <$> randomM globalStdGen)
  let
      (r, Dual g) = cost (V.singleton example) # weights
      (gw1, gw2) = g (Const 1)
      report name e =
        let s0 = size e
        in do
          putStrLn $ name ++ "(size: " ++ show s0 ++ "): " ++ take 10000 (show e) -- (eval (lookupVec (head examples)) e)
          -- putStrLn $ name ++ ".EVAL: " ++ show (eval (lookupVec (V.head examples)) e)
  -- report "full cost            " r
  report "d cost / d ws1[0][0]" (V.index (V.index gw1 (finite 0)) (finite 0))
  -- report "d cost / d ws2[0][0]" (gw2 V.! 0 V.! 0)
