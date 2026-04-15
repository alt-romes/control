{-# LANGUAGE GADTs, UnicodeSyntax, PatternSynonyms, DerivingStrategies, BlockArguments, TypeFamilies, UndecidableInstances #-}
module SEADS where
import Data.Kind
import Prelude hiding (id, (.))
import Control.Category
--------------------------------------------------------------------------------
class Category k => Monoidal k where
  (×) :: (a `k` c) -> (b `k` d) -> ((a,b) `k` (c,d))

instance Monoidal (->) where f × g = \(a,b) -> (f a, g b)
--------------------------------------------------------------------------------
-- | Differential function as composition of image and derivative at that point
newtype D k a b = UnsD { (#) :: a -> (b, a `k` b) }

-- | Any linear function is differentiable
-- (the derivative of every linear function is itself, everywhere)
linear :: (a -> b) -> (a `k` b) -> D k a b
linear f f' = UnsD (\a -> (f a, f'))

-- | Composition of differentiable functions is differentiable
instance Category k => Category (D k) where
  id = linear id id
  g . f = UnsD \a -> -- chain rule
    let (b, f') = f # a
        (c, g') = g # b
     in (c, (g' . f'))

-- | Parallel composition of differentiable functions is differentiable
instance Monoidal k => Monoidal (D k) where
  f × g = UnsD \(a,b) ->
    let (c, f') = f # a
        (d, g') = g # b
     in ((c,d), f' × g')
--------------------------------------------------------------------------------
-- | Let's focus on R -> R functions first
type (:->) = D L

-- | The derivative of f : R -> R at point f(x) is a linear map from tangent
-- space R to R (the tangent spaces matches with the domain and codomain space)
--
-- Linear Map:
--   f (x+y) = f x + f y
--   f (d*x) = d*f x
newtype L a b = L { (|>) :: a -> b } deriving newtype (Category, Monoidal)

scale :: Num a => a -> L a a
scale x = L (*x)

addL :: Num a => L (a,a) a
addL = L (uncurry (+))

lin  f = linear f (L f)
unit x = UnsD \() -> (x, L \() -> 0)

negD, recD, expD, logD, sinD, cosD :: Floating a => a :-> a
addD, subD, mulD, divD :: Floating a => (a,a) :-> a
negD = lin negate
addD = lin (uncurry (+))
subD = lin (uncurry (-))
mulD = UnsD \(a,b) -> (a * b, addL . (L (*b) × L (*a)))
divD = UnsD \(a,b) -> (a / b, scale (-1 / b^2) . addL . (scale b × scale (-a)))
recD = UnsD \a -> (recip a, scale (-1 / a^2))
expD = UnsD \a -> let e = exp a in (e, scale e)
logD = UnsD \a -> let l = log a in (l, scale (-1 / l))
sinD = UnsD \a -> (sin a, scale (cos a))
cosD = UnsD \a -> (cos a, scale (- (sin a)))

sigmoid = recD . addD . ((unit 1) × (expD . negD))
--------------------------------------------------------------------------------

-- Neural Network

s x = 1 / (1 + exp (-x))

neuron' :: Floating o => (p -> i -> o) -> p -> o -> i -> o
neuron' w p b x = s (w p x + b)

n2 :: (Floating o1, Floating o2)
   => (p1 -> o1 -> o2) -- Layer 2
   -> (p2 -> i1 -> o1) -- Layer 1
   -> o2 -- Bias 2
   -> o1 -- Bias 1
   -> p2 -- Params layer 2 (to optimize)
   -> p1 -- Params layer 1 ditto
   -> i1 -- input
   -> o2 -- output
n2 w2 w1 b2 b1 p1 p2 = neuron' w2 p2 b2 . neuron' w1 p1 b1

