{-# LANGUAGE GADTs, UnicodeSyntax, PatternSynonyms, DerivingStrategies, BlockArguments, TypeFamilies, UndecidableInstances #-}

-- | Simple essence of automatic differentiation distilled
--
-- @
-- import Prelude hiding (id, (.))
-- import Control.Category
-- import SEAD
-- @
module SEAD where

import Data.Kind
import Prelude hiding (id, (.))
import Control.Category

-- The operator (D+) is a Functor FROM the category of differentiable
-- functions (e.g. @f@) TO the category of functions which return both the
-- image at point @a@ (@f a@) AND the derivative at point @a@ as a linear map.
--
-- D+ :: (a -> b) -> (a -> (b, a ⊸ b))
-- D+ f = \a -> (f a, D f a)
--
-- We call the latter Category (combination of function and its derivative) @D@.
--
-- The @k@ type argument generalizes the linear map representing the derivative.
-- We can e.g. instance it to (->) for traditional scalar derivatives.
newtype D k a b = UnsD { (#) :: a -> (b, a `k` b) }

-- | Any linear function is differentiable, so it can be lifted to @D@
-- The derivative of every linear function is itself, everywhere.
linear :: (a -> b) -> (a `k` b) -> D k a b
linear f f' = UnsD (\a -> (f a, f'))

instance Category k => Category (D k) where
  id = linear id id
  g . f = UnsD \a -> -- chain rule
    let (b, f') = f # a
        (c, g') = g # b
     in (c, (g' . f'))

instance Monoidal k => Monoidal (D k) where
  type Obj (D k) x = (Num x, Obj k x)
  f × g = UnsD \(a,b) ->
    let (c, f') = f # a
        (d, g') = g # b
     in ((c,d), f' × g')

instance Cartesian k => Cartesian (D k) where
  exl = linear exl exl
  exr = linear exr exr
  dup = linear dup dup

instance Cocartesian k => Cocartesian (D k) where
  inl = linear (unAddFun inl) inl
  inr = linear (unAddFun inr) inr
  jam = linear (unAddFun jam) jam

--------------------------------------------------------------------------------

newtype a →⁺ b = AddFun { unAddFun :: a -> b }
  deriving newtype (Category, Cartesian)

instance Monoidal (→⁺) where
  type Obj (→⁺) x = Num x
  AddFun f × AddFun g = AddFun \(a, b) -> (f a, g b)

instance Cocartesian (→⁺) where
  inl = AddFun (\x -> (x, 0))
  inr = AddFun (\x -> (0, x))
  jam = AddFun (\(a,b) -> a + b)

instance Num a => Scalable (→⁺) a where
  scale a = AddFun \da -> a * da

--------------------------------------------------------------------------------

newtype Cont k r a b = Cont { unCont :: (b `k` r) -> (a `k` r) }

cont :: Category k => (a `k` b) -> Cont k r a b
cont f = Cont (. f)

instance Category k => Category (Cont k r) where
  id = cont id
  Cont g . Cont f = Cont (f . g)

instance (Cocartesian k, Obj k r) => Monoidal (Cont k r) where
  type Obj (Cont k r) x = Obj k x
  Cont f × Cont g = Cont (join . (f × g) . (\h -> (h . inl, h . inr)))

instance (Cocartesian k, Obj k r) => Cartesian (Cont k r) where
  -- exl = Cont (_)
  -- exr = Cont (_)
  -- dup = Cont (jam . unjoin)

--------------------------------------------------------------------------------

class NumCat k a where
  negC :: a `k` a
  addC, subC, mulC :: (a,a) `k` a

class NumCat k a => FloatingCat k a where
  divC :: (a,a) `k` a
  expC, logC, sinC, cosC :: a `k` a

instance (Num a, Obj k a, NumCat k a, Scalable k a, Cocartesian k) => NumCat (D k) a where
  negC = linear negate negC
  addC = linear (uncurry (+)) addC
  subC = linear (uncurry (-)) subC
  mulC = UnsD \(a,b) -> (a * b, scale b ▽ scale a)

instance (Floating a, NumCat k a, Scalable k a, Obj k a, Cocartesian k) => FloatingCat (D k) a where
  divC = UnsD \(a,b) ->
    (a / b, scale (-1 / b^2) . (scale b ▽ scale (-a)))

  expC = UnsD \a -> let e = exp a in (e, scale e)
  logC = UnsD \a -> let l = log a in (l, scale (-1 / l))
  sinC = UnsD \a -> (sin a, scale (cos a))
  cosC = UnsD \a -> (cos a, scale (- (sin a)))

--------------------------------------------------------------------------------

class Category k => Monoidal k where
  type Obj k x :: Constraint
  (×) :: (Obj k a, Obj k b, Obj k c, Obj k d) => (a `k` c) -> (b `k` d) -> ((a,b) `k` (c,d))

instance Monoidal (->) where
  type Obj (->) x = ()
  f × g = \(a,b) -> (f a, g b)

class Monoidal k => Cartesian k where
  exl :: (Obj k a, Obj k b) => (a,b) `k` a
  exr :: (Obj k a, Obj k b) => (a,b) `k` b
  dup :: (Obj k a) => a `k` (a,a)

instance Cartesian (->) where
  exl = \(a,_) -> a
  exr = \(_,b) -> b
  dup = \a -> (a,a)

class Monoidal k => Cocartesian k where
  inl :: (Obj k a, Obj k b) => a `k` (a,b)
  inr :: (Obj k a, Obj k b) => a `k` (b,a)
  jam :: Obj k a => (a,a) `k` a

(△) :: (Obj k a, Obj k c, Obj k d, Cartesian k) => (a `k` c) -> (a `k` d) -> (a `k` (c,d))
f △ g = (f × g) . dup

(▽) :: (Obj k a, Obj k c, Obj k d, Cocartesian k) => (c `k` a) -> (d `k` a) -> ((c,d) `k` a)
f ▽ g = jam . (f × g)

-- join and unjoin iso witnesses invertability of ▽
join :: (Obj k a, Obj k c, Obj k d, Cocartesian k) => (c `k` a, d `k` a) -> ((c, d) `k` a)
join (f, g) = f ▽ g
unjoin :: (Obj k a, Obj k c, Obj k d, Cocartesian k) => ((c, d) `k` a) -> (c `k` a, d `k` a)
unjoin h = (h . inl, h . inr)

class Scalable k a where
  scale :: a -> (a `k` a)

