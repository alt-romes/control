{- cabal:
  build-depends: base, random
-}
{-# LANGUAGE GHC2024, BlockArguments, TypeFamilies, UndecidableInstances, AllowAmbiguousTypes #-}
import GHC.TypeNats
import Prelude hiding (id, (.))
import Control.Category

-- | Differentiable+ function
newtype a :-> b = D { (#) :: a -> (b, a -> b) }

-- | The derivative of every linear function is itself, everywhere
linear :: (a -> b) -> (a :-> b)
linear f = D (\a -> (f a, f))

-- | Differentiable+ functions form a Category
instance Category (:->) where
  id = linear (\x -> x)
  g . f = D \a -> -- chain rule
    let (b, f') = f # a
        (c, g') = g # b
     in (c, \x -> g' (f' x))

-- Monoidal
type (×) = (,)
(×) :: (a :-> c) -> (b :-> d) -> ((a×b) :-> (c×d))
f × g = D \(a,b) -> -- paralell composition
  let (c, f') = f # a
      (d, g') = g # b
   in ((c,d), \(x,y) -> (f' x, g' y))

-- Cartesian (algebraically, but not substructurally, linear)
exl = linear fst
exr = linear snd
dup = linear (\x -> (x,x))
--------------------------------------------------------------------------------
neg  = linear negate
add  = linear (uncurry (+))
mul  = D (\(x,y) -> (x*y, \(dx,dy) -> dx*y + dy*x))
rec  = D (\x -> (recip x, \dx -> dx*(-1 / x^2)))
exp' = D (\x -> let e = exp x in (e, \dx -> dx*e))
log' = D (\x -> let l = log x in (l, \dx -> dx*(-1/l)))

(+>) :: Num a => a -> (a :-> a) -- adds constant number
(+>) k = D \x -> (k+x, \dx -> dx)

sigmoid = rec . (1 +>) . exp' . neg
--------------------------------------------------------------------------------
type family R n where
  R 1 = Double
  R n = Double × R (n-1)

-- ugly... how to avoid this completely?
class Layer a where
  weightedSum :: a -> a :-> R 1
  weightedSum' :: (a × a) :-> R 1
instance Layer Double where
  weightedSum x = linear (* x)
  weightedSum' = mul
instance Layer b => Layer (Double, b) where
  weightedSum (x, xs) = add . (linear (* x) × weightedSum xs) . (exl × exr) . dup
  weightedSum' :: ((Double, b) × (Double, b)) :-> R 1
  weightedSum' = add . (mul × weightedSum') . ((exl × exl) × (exr × exr)) . dup

type L1W = (R 2 × (R 2 × (R 2 × R 2)))

-- Weights: 2x4=8 + 4x1
-- Biases: 2 + 4
xorNet :: R 2 -> (L1W, R 4) :-> R 1
xorNet i = sigmoid . l2 . ((l1 i . exl) × exr) . dup

l1 :: R 2 -> L1W :-> R 4
l1 i = ( sigmoid . weightedSum @(R 2) i) ×
       ((sigmoid . weightedSum @(R 2) i) ×
       ((sigmoid . weightedSum @(R 2) i) ×
        (sigmoid . weightedSum @(R 2) i)))

l2 :: (R 4 × R 4) :-> R 1
l2 = weightedSum'

cost :: [(R 2, R 1)] -> (L1W × R 4) :-> R 1
cost (p:ps) = normalize . foldl' (\acc x -> add . (cost1 x × acc) . dup) (cost1 p) ps
  where
    cost1 :: (R 2, R 1) -> (L1W × R 4) :-> R 1
    cost1 (i, o) = mul . dup . (negate o +>) . xorNet i

    normalize = id -- TODO

-- TODO: Neural Networks made moderately complex:
--  do more complicated version which uses size-indexed vecs,
--  and which uses Matrix multiplication by making `L a b` by a data family
--  which, for something like L (V 4) (V 4), is instanced to (M 4 4)
--
--  Also, try the Cont k, Dual -o, and
--  Transposition of structurally linear functions.
--
-- We take a few simplifications:
--  - We don't use proper linear types -o (see connection between substructural
--    and algebraic linearity in "You only linearize once")
--  - We assume the tangent space matches the (co)domain space
