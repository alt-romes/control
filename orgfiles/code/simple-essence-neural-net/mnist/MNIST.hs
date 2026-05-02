{- cabal:
 build-depends: base, random, bytestring, vector, hegg, containers
-}
{-# LANGUAGE GHC2024, OverloadedLists, Strict, OverloadedStrings,
             DeriveTraversable, DeriveGeneric, MultiParamTypeClasses,
             FlexibleInstances, LambdaCase, TypeFamilies #-}
import Prelude hiding (id, (.))
import Control.Category
import Control.Monad
import System.Random.Stateful
import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as UV
import GHC.Generics (Generic)
import Data.Equality.Saturation (Fix(..), equalitySaturation, CostFunction, Rewrite(..))
import Data.Equality.Matching (pat)
import Data.Equality.Analysis (Analysis(..))
import Data.Equality.Graph (EGraph, represent, merge)
import Data.Equality.Graph.Lens ((^.), _class, _data)

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
neuron   = sigmoid . (sumI . hadamard) . (cons 1 × id)
l2       = crossI (V.replicate 10 neuron) . (linear (\(xs,ys) -> V.zipWith (,) xs ys) (Dual V.unzip))
l1 i     = crossI (V.replicate 300 (fixed neuron i))
mnistNet :: V.Vector Expr -> (V.Vector (V.Vector Expr), V.Vector (V.Vector Expr)) :-> V.Vector Expr
mnistNet i = l2 . ((dupI (V.foldr1 (V.zipWith (+))) 10 . l1 i) × id) where n = fixed neuron i
cost :: [(V.Vector Expr, V.Vector Expr)]
     -> (V.Vector (V.Vector Expr), V.Vector (V.Vector Expr)) :-> Expr
cost  ps = sumI . crossI (V.map cost1 (V.fromList ps)) . dupI sum (length ps)
  where cost1 (i, o) = sqrt' . sumI . crossI (V.replicate 10 sqr) . (V.map (*(-1)) o +>) . mnistNet i
        sqr :: Expr :-> Expr
        sqr = mul . dup

step examples (i :: Int) weights = do
  let (r, Dual grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10)

main = do
  rawImages <- BS.drop 16 <$> BS.readFile "train-images.idx3-ubyte"
  rawLabels <- BS.drop 8  <$> BS.readFile "train-labels.idx1-ubyte"
  let n       = BS.length rawLabels
      toV bs  = V.generate (BS.length bs) (Const . fromIntegral . BS.index bs)
      allImgs = toV rawImages
      allLbls = toV rawLabels
      examples :: [(V.Vector Expr, V.Vector Expr)]
      examples = [ ( V.slice (i * 784) 784 allImgs
                   , V.singleton (allLbls V.! i) )
                 | i <- [0..n-1] ]
  initialWeights <- (,) <$> V.mapM (const $ V.replicateM 785 $ (Const <$> randomM globalStdGen)) [1..300] <*> V.mapM (const $ V.replicateM 301 $ (Const <$> randomM globalStdGen)) [1..10]
  finalWeights   <- V.foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..1000]
  putStrLn $ "Neural net results: " ++ show (map (\(e,_) -> fst (mnistNet e # finalWeights)) examples)
  putStrLn $ "Expected results:   " ++ show (map snd examples)

type Weights = (V.Vector (V.Vector Expr), V.Vector (V.Vector Expr))
instance Num Weights where
  fromInteger x' = (V.replicate 300 (V.replicate 785 x), V.replicate 10 (V.replicate 301 x)) where x = fromInteger x'
  (w1, w2) + (w3, w4) = (V.zipWith (V.zipWith(+)) w1 w3, V.zipWith (V.zipWith(+)) w2 w4)
instance Num (V.Vector Expr) where
  -- the negate/fromInteger 0/fromInteger -1 was causing such a weird loop (also the `sum` from `dupI` needing a zero..) wow.
  (+) = V.zipWith (+)

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
  let (yS, Dual gS) = (sigmoid :: Expr :-> Expr) # Var "x"
  putStrLn $ "sigmoid(x)         = " ++ show yS
  putStrLn $ "k * d/dx sigmoid x = " ++ show (gS (Var "k"))
  putStrLn $ "        simplified = " ++ show (simplify yS)
  putStrLn $ "k * d/dx sigmoid x = " ++ show (gS (Var "k"))
  putStrLn $ "        simplified = " ++ show (simplify (gS (Var "k")))
  let sqr = mul . dup
      (yQ, Dual gQ) = (sqr :: Expr :-> Expr) # Var "x"
  putStrLn $ "x*x                = " ++ show yQ
  putStrLn $ "        simplified = " ++ show (simplify yQ)
  putStrLn $ "k * d/dx (x*x)     = " ++ show (gQ (Var "k"))
  putStrLn $ "        simplified = " ++ show (simplify (gQ (Var "k")))

size :: Expr -> Int
size (Const _) = 1
size (Var _)   = 1
size (Add a b) = 1 + size a + size b
size (Mul a b) = 1 + size a + size b
size (Neg a)   = 1 + size a
size (Rec a)   = 1 + size a
size (Exp a)   = 1 + size a
size (Sqrt a)  = 1 + size a

-- Same structure as mnistNet/cost, but tiny (2 inputs, 2 hidden, 1 output) so
-- the symbolic gradient is small enough to print.
miniNet :: V.Vector Expr
        -> (V.Vector (V.Vector Expr), V.Vector (V.Vector Expr)) :-> V.Vector Expr
miniNet i = mL2 . ((dupI (V.foldr1 (V.zipWith (+))) 1 . mL1 i) × id)
  where mL1 j = crossI (V.replicate 2 (fixed neuron j))
        mL2   = crossI (V.replicate 1 neuron)
              . (linear (\(xs,ys) -> V.zipWith (,) xs ys) (Dual V.unzip))

miniCost :: [(V.Vector Expr, V.Vector Expr)]
         -> (V.Vector (V.Vector Expr), V.Vector (V.Vector Expr)) :-> Expr
miniCost ps = sumI . crossI (V.map cost1 (V.fromList ps)) . dupI sum (length ps)
  where cost1 (i, o) = sqrt' . sumI . crossI (V.replicate 1 sqr)
                     . (V.map (*(-1)) o +>) . miniNet i
        sqr :: Expr :-> Expr
        sqr = mul . dup

symGradCost :: IO ()
symGradCost = do
  let example = ( V.fromList [Var "a", Var "b"]
                , V.singleton (Var "y") )
      ws1 = V.fromList [ V.fromList [Var "1", Var "2", Var "3"]    -- hidden 1: bias, w_a, w_b
                       , V.fromList [Var "4", Var "5", Var "6"] ]  -- hidden 2
      ws2 = V.fromList [ V.fromList [Var "p", Var "q", Var "r"] ]  -- output: bias, v_h1, v_h2
      (r, Dual g) = miniCost [example] # (ws1, ws2)
      (gw1, gw2) = g (Const 1)
  putStrLn $ "cost = " ++ show r
  putStrLn $ "  (size: " ++ show (size r) ++ " nodes)"
  putStrLn ""
  putStrLn "d cost / d ws1:"
  V.imapM_ (\i row -> V.imapM_ (\j v ->
      putStrLn ("  ws1[" ++ show i ++ "][" ++ show j ++ "] = " ++ show v)) row) gw1
  putStrLn "d cost / d ws2:"
  V.imapM_ (\i row -> V.imapM_ (\j v ->
      putStrLn ("  ws2[" ++ show i ++ "][" ++ show j ++ "] = " ++ show v)) row) gw2

-- For the full mnist-sized cost: too big to print, but we can measure it
-- and feed components through `simplify` (equality saturation) to compress.
symGradCostSize :: IO ()
symGradCostSize = do
  let example = ( V.replicate 784 (Var "x"), V.singleton (Var "y") )
      weights = ( V.replicate 300 (V.replicate 785 (Var "w"))
                , V.replicate 10  (V.replicate 301 (Var "v")) )
      (r, Dual g) = cost [example] # weights
      (gw1, gw2) = g (Const 1)
      report name e =
        let s0 = size e
            e' = simplify e
            s1 = size e'
        in putStrLn $ name ++ ": " ++ show s0 ++ " -> " ++ show s1 ++ " nodes"
  report "full cost            " r
  report "d cost / d ws1[0][0]" (gw1 V.! 0 V.! 0)
  report "d cost / d ws2[0][0]" (gw2 V.! 0 V.! 0)

--------------------------------------------------------------------------------
-- Equality saturation via hegg
--------------------------------------------------------------------------------

-- | Base functor of 'Expr' so it can serve as a hegg 'Language'.
data ExprF a = ConstF !Double
             | VarF !String
             | AddF a a
             | MulF a a
             | NegF a
             | RecF a
             | ExpF a
             | SqrtF a
             deriving (Eq, Ord, Show, Functor, Foldable, Traversable, Generic)

toFix :: Expr -> Fix ExprF
toFix = \case
  Const d  -> Fix (ConstF d)
  Var c    -> Fix (VarF c)
  Add a b  -> Fix (AddF (toFix a) (toFix b))
  Mul a b  -> Fix (MulF (toFix a) (toFix b))
  Neg a    -> Fix (NegF (toFix a))
  Rec a    -> Fix (RecF (toFix a))
  Exp a    -> Fix (ExpF (toFix a))
  Sqrt a   -> Fix (SqrtF (toFix a))

fromFix :: Fix ExprF -> Expr
fromFix (Fix e) = case e of
  ConstF d  -> Const d
  VarF c    -> Var c
  AddF a b  -> Add (fromFix a) (fromFix b)
  MulF a b  -> Mul (fromFix a) (fromFix b)
  NegF a    -> Neg (fromFix a)
  RecF a    -> Rec (fromFix a)
  ExpF a    -> Exp (fromFix a)
  SqrtF a   -> Sqrt (fromFix a)

-- | Constant-folding analysis: each e-class carries the constant value of its
-- expressions when known.
instance Analysis (Maybe Double) ExprF where
  makeA = \case
    ConstF x -> Just x
    VarF _   -> Nothing
    AddF x y -> (+) <$> x <*> y
    MulF x y -> (*) <$> x <*> y
    NegF x   -> negate <$> x
    RecF x   -> recip <$> x
    ExpF x   -> exp <$> x
    SqrtF x  -> sqrt <$> x

  joinA Nothing  y         = y
  joinA x        Nothing   = x
  joinA (Just x) (Just y)
    | x == y    = Just x
    | otherwise = error "Analysis: merged inconsistent constants"

  modifyA c eg = case eg ^._class c._data of
    Nothing -> eg
    Just d  ->
      let (c', eg') = represent (Fix (ConstF d)) eg
       in snd (merge c c' eg')

exprCost :: CostFunction ExprF Int
exprCost = \case
  ConstF _ -> 1
  VarF _   -> 1
  AddF a b -> a + b + 2
  MulF a b -> a + b + 3
  NegF a   -> a + 1
  RecF a   -> a + 4
  ExpF a   -> a + 8
  SqrtF a  -> a + 8

rewrites :: [Rewrite (Maybe Double) ExprF]
rewrites =
  [ pat (AddF "a" "b")                                  := pat (AddF "b" "a")
  , pat (MulF "a" "b")                                  := pat (MulF "b" "a")
  , pat (AddF "a" (pat (AddF "b" "c")))                 := pat (AddF (pat (AddF "a" "b")) "c")
  , pat (MulF "a" (pat (MulF "b" "c")))                 := pat (MulF (pat (MulF "a" "b")) "c")
  , pat (AddF "a" (pat (ConstF 0)))                     := "a"
  , pat (MulF "a" (pat (ConstF 0)))                     := pat (ConstF 0)
  , pat (MulF "a" (pat (ConstF 1)))                     := "a"
  , pat (NegF (pat (NegF "a")))                         := "a"
  , pat (NegF (pat (ConstF 0)))                         := pat (ConstF 0)
  , pat (AddF "a" (pat (NegF "a")))                     := pat (ConstF 0)
  , pat (NegF "a")                                      := pat (MulF (pat (ConstF (-1))) "a")
  , pat (MulF "a" (pat (AddF "b" "c")))                 := pat (AddF (pat (MulF "a" "b")) (pat (MulF "a" "c")))
  , pat (RecF (pat (RecF "a")))                         := "a"
  , pat (RecF (pat (ConstF 1)))                         := pat (ConstF 1)
  , pat (ExpF (pat (ConstF 0)))                         := pat (ConstF 1)
  , pat (SqrtF (pat (ConstF 0)))                        := pat (ConstF 0)
  , pat (SqrtF (pat (ConstF 1)))                        := pat (ConstF 1)
  ]

simplify :: Expr -> Expr
simplify e =
  fromFix (fst (equalitySaturation (toFix e) rewrites exprCost
                  :: (Fix ExprF, EGraph (Maybe Double) ExprF)))
