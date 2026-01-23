{-# LANGUAGE RecursiveDo #-}
module Main where

data Expr a
  = K Float
  | S Char
  | M a a
  | D a a
  | SHL a a

--------------------------------------------------------------------------------

data Cofree f a = a :< f (Cofree f a)
-- unwrap :: m a -> f (m a)
-- unfold :: Functor f => (b -> (a, f b)) -> b -> Cofree f a

data Free f a = Pure a | Free (f (Free f a))
-- wrap :: f (m a) -> m a

data Fix f = Fix (f (Fix f))

--------------------------------------------------------------------------------

type CoEgraph l = Cofree l
type Egraph   l = Free l

type CoHegg l = Fix (Cofree l)
type Hegg l   = Fix (Free l)

--------------------------------------------------------------------------------

-- or is it Cofree Comonad?
-- data Egraph l a
--   = Add a
--   | Merge a a

extract :: Egraph l a -> a
extract = _

add :: l a -> Egraph l a
add x = Pure (extract x)

-- Fix point?
run :: Egraph l a -> l a
run = _

repExpr :: Egraph Expr a
repExpr = do
  -- (a*2)/2
  c1 <- add (S 'a')
  c2 <- add (K 2)
  c3 <- add (M c1 c2)
  c4 <- add (D c3 c2)

  -- (a<<1)
  c5 <- add (K 1)
  c6 <- add (SHL c1 c5)

  -- (a*2) ~ (a<<1)
  c7 <- merge c3 c6

  -- a*(2/2)
  c8 <- add (D c2 c2)
  c9 <- add (M c1 c8)

  -- (a*2)/2 ~ a*(2/2)
  c10 <- merge c9 c4
  -- (2/2) ~ 1
  c11 <- merge c8 c5
  -- a*1 ~ a
  c12 <- merge c9 c5

  return c4

main = pure ()

-- type Eclass = Fix (Compose [] l)
newtype EClass l = EClass [l (EClass l)]

-- unfold :: Functor f => (b -> (a, f b)) -> b -> Cofree f a
--
-- iter :: (l (EClass l) -> (EClass l)) -> Free l (EClass l) -> (EClass l)

loeb :: Functor f => f (f a -> a) -> f a
loeb xs = fix (\fa -> fmap ($ fa) xs)

fix :: (a -> a) -> a
fix f = let y = f y in y

data Egr' a
  = Add' a
  | Merge' a a
  deriving Functor

-- doit :: Egr' (EClass l) -> EClass l
-- doit egr = case egr of
--   Add' x -> x
--   Merge' y z -> _

-- duplicate' (Add' a) = Add' (Add' a)
-- duplicate' (Merge' a b) = Add' (Merge' a b)

-- extend' :: (Egr' a -> b) -> Egr' a -> Egr' b
-- extend' f x = case x of
--   Add' a -> Add' (f x)
--   Merge' a b -> Merge' (f a) (f b)

-- extract' (Add' a) = a
-- extract' (Merge' a b) = a <> b

-- extract . duplicate      = id
-- fmap extract . duplicate = id
-- duplicate . duplicate    = fmap duplicate . duplicate

-- Comonad Egr?
-- duplicate :: w a -> w (w a)
-- extract :: w a -> a

-- add' :: _

-- loebwhat :: Fix (Compose [] Expr)
-- loebwhat = _


repExprFinal :: Fix Expr -> EClass l
repExprFinal =
  let
    c1 = add' [(S 'a')]
    c2 = add' [(K 2)]
    c3 = add' [(M c1 c2), (SHL c1 c4)]
    c4 = add' [(D c3 c2), (K 1), (D c2 c2), (M c1 c4)]
  in c4

--------------------------------------------------------------------------------

-- No
-- type Egr l = Cofree EClass (l (EClass l))
  -- the top-most e-class and the term it represents? but it could represent more than one term...
  --  EClass l a :< l (Cofree l (EClass l a))
  --
  --  l (EClass l) :< EClass (l (EClass l) :< (EClass (l (Class)))

-- or perhaps:
--  Egraph l a = EClass l a :<
--  Cofree l (EClass l a) = (EClass l a) :< l (Cofree l (EClass l a))

--------------------------------------------------------------------------------

data EgrT l v
  = Add (l v) (v -> EgrT l v {-monad?-})
  | Merge v v (v -> EgrT l v)

repExpr'' :: EgrT Expr v
repExpr'' =
  -- (a*2)/2
  Add (S 'a')   $ \c1 ->
  Add (K 2)     $ \c2 ->
  Add (M c1 c2) $ \c3 ->
  Add (D c3 c2) $ \c4 ->

  -- (a<<1)
  Add (K 1)       $ \c5 ->
  Add (SHL c1 c5) $ \c6 ->

  -- (a*2) ~ (a<<1)
  Merge c3 c6     $ \c7 ->

  -- a*(2/2)
  Add (D c2 c2) $ \c8 -> 
  Add (M c1 c8) $ \c9 -> 

  -- (a*2)/2 ~ a*(2/2)
  Merge c9 c4 $ \c10 ->
  -- (2/2) ~ 1
  Merge c8 c5 $ \c11 ->
  -- a*1 ~ a
  Merge c9 c5 $ \c12 ->

  return c4
