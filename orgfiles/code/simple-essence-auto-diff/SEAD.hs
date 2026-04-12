{-# LANGUAGE GADTs, UnicodeSyntax, PatternSynonyms, DerivingStrategies, BlockArguments #-}
module SEAD where

import Prelude hiding (id, (.))
import Control.Category

-- | A Linear map (not necessarily linear in the linear logic sense IIUC)
-- INVARIANT: only constructed with linear mappings from a -> b
--
-- > A function f is said to be linear when it distributes over (preserves the
-- structure of) vector addition and scalar multiplication, i.e.:
--
-- > f (a + a′) = f a + f a′
-- > f (s·a)    = s·f a
newtype L a b = L { (|>) :: (a -> b) }
  deriving newtype Category

-- | Differentiable functions, compositionally.
--
-- > Although diﬀerentiation is not computable when given just an arbitrary
--    computable function, we can instead build up diﬀerentiable functions
--    compositionally, using exactly the forms introduced above, (namely (◦),
--    (×) and linear functions), together with various non-linear primitives
--    having known derivatives. Computations expressed in this vocabulary are
--    differentiable by construction thanks to Corollaries 1.1 through 3.1.
data a :-> b where
  -- | A non-linear primitive differentiable function, defined by its
  -- image and derivative at a point a
  Prim  :: (a -> (b, L a b)) -> (a :-> b)
  -- | Any linear function is differentiable.
  --
  -- The derivative of every linear function is itself, everywhere.
  -- Theorem 3 (linear rule) For all linear functions f, D f a= f.
  Lin   :: L a b -> (a :-> b)
  -- | Sequencial composition
  Comp  :: (b :-> c) -> (a :-> b) -> (a :-> c)
  -- | Parallel composition
  Cross :: (a :-> c) -> (b :-> d) -> ((a, b) :-> (c, d))

(∘) = Comp
(×) = Cross

-- Given a differentiable function, give derivative and value at point a
-- D⁺ from paper
diff :: a :-> b -> (a -> (b, L a b))
diff (Prim d)    a = d a
diff (Lin f) a = (f |> a, f)
diff (Comp g f)  a =
  let (b, f') = diff f a
      (c, g') = diff g b
   in (c, (g' . f'))
diff (Cross f g) (a, b) =
  let (c, f') = diff f a
      (d, g') = diff g b
   in ((c,d), L \(a', b') -> (f' |> a', g' |> b'))



