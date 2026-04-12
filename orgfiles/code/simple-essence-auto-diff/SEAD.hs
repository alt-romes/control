{-# LANGUAGE GADTs, UnicodeSyntax, PatternSynonyms, DerivingStrategies, BlockArguments #-}

-- | Simple essence of automatic differentiation distilled
--
-- @
-- import Prelude hiding (Num(..), Floating(..), id, (.))
-- import SEAD
--
-- squared = (*) . dup
-- @
--
-- Could the definition of :-> functions be simpler if we used Arrows?
module SEAD
 ( L((|>))
 , (:->), (#)
 , linear

 , negate
 , (+), (-), (*)

 , Monoidal((×))

 -- Re-exports
 , Category(..)
 , Num(fromInteger)
 , Fractional(fromRational)
 , Floating(pi)
 ) where

import Prelude hiding (id, (.), Num(..))
import Prelude (Num(fromInteger), Fractional(fromRational), Floating(pi))
import qualified Prelude as P
import Control.Category

-- | A linear map (not necessarily linear in the linear logic sense IIUC)
-- INVARIANT: only constructed with linear mappings from a -> b
--
-- > A function f is said to be linear when it distributes over (preserves the
-- structure of) vector addition and scalar multiplication, i.e.:
--
-- > f (a + a′) = f a + f a′
-- > f (s·a)    = s·f a
--
-- The SEAD theory works for linear map generically, or even categorical
-- generalizations of linear maps. Generalizing the use of L to other things
-- gets us
newtype L a b = UnsL { (|>) :: (a -> b) }
  deriving newtype (Category, Monoidal, Cartesian)

instance Cocartesian L where
  inl = UnsL \a -> (a, 0)
  inr = UnsL \a -> (0, a)
  jam = UnsL \(a,b) -> a P.+ b

instance Num a => Scalable L a where
  scale a = UnsL \da -> a P.* da

-- The operator (D+) is a Functor FROM the category of differentiable
-- functions (e.g. @f@) TO the category of functions which return both the
-- image at point @a@ (@f a@) AND the derivative at point @a@ as a linear map.
--
-- D+ :: (a -> b) -> (a -> (b, a ⊸ b))
-- D+ f = \a -> (f a, D f a)
--
-- We call the latter Category (combination of function and its derivative):
newtype D k a b = UnsD { (#) :: a -> (b, a `k` b) }

-- | Any linear function is differentiable, so it can be lifted to (:->).
--
-- The derivative of every linear function is itself, everywhere.
-- Theorem 3 (linear rule) For all linear functions f, D f a= f.
linear :: (a -> b) -> (a `k` b) -> D k a b
linear f f' = UnsD (\a -> (f a, f'))

instance Category k => Category (D k) where
  id = linear id id
  g . f = UnsD \a -> -- chain rule
    let (b, f') = f # a
        (c, g') = g # b
     in (c, (g' . f'))

instance Monoidal k => Monoidal (D k) where
  f × g = UnsD \(a,b) ->
    let (c, f') = f # a
        (d, g') = g # b
     in ((c,d), f' × g')

instance Cartesian k => Cartesian (D k) where
  exl = linear exl exl
  exr = linear exr exr
  dup = linear dup dup

--------------------------------------------------------------------------------

-- Num
negate :: Num a => D k a a
negate = linear P.negate

(+), (-), (*) :: Num a => D k (a,a) a
(+) = linear (UnsL (P.uncurry (P.+)))
(-) = linear (UnsL (P.uncurry (P.-)))
(*) = UnsD \(a,b) -> (a P.* b, scale b ▽ scale a)

-- Fractional
(/) :: Fractional a => D k (a,a) a
(/) = UnsD \(a,b) ->
  (a P./ b, scale (-1 P./ b^2) . (scale b ▽ scale (-a)))

-- Floating
exp, log, sin, cos :: Floating a => D k a a
exp = UnsD \a -> let e = P.exp a in (e, scale e)
log = UnsD \a -> let l = P.log a in (l, scale (-1 P./ l))
sin = UnsD \a -> (P.sin a, scale (P.cos a))
cos = UnsD \a -> (P.cos a, scale (- (P.sin a)))

--------------------------------------------------------------------------------

class Category k => Monoidal k where
  (×) :: (a `k` c) -> (b `k` d) -> ((a,b) `k` (c,d))

instance Monoidal (->) where
  f × g = \(a,b) -> (f a, g b)

class Monoidal k => Cartesian k where
  exl :: (a,b) `k` a
  exr :: (a,b) `k` b
  dup :: a `k` (a,a)

instance Cartesian (->) where
  exl = \(a,_) -> a
  exr = \(_,b) -> b
  dup = \a -> (a,a)

-- in principle the Num constraints should be an associated constraint and the
-- co-product coinciding with product should be given in associated type
-- family, but this is simpler
class Monoidal k => Cocartesian k where
  inl :: Num b => a `k` (a,b)
  inr :: Num b => a `k` (b,a)
  jam :: Num a => (a,a) `k` a

(△) :: Cartesian k => (a `k` c) -> (a `k` d) -> (a `k` (c,d))
f △ g = (f × g) . dup

(▽) :: (Cocartesian k, Num a) => (c `k` a) -> (d `k` a) -> ((c,d) `k` a)
f ▽ g = jam . (f × g)

-- generalize scalar multiplication
class Scalable k a where
  scale :: a -> (a `k` a)

