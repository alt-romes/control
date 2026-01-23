{-# LANGUAGE UndecidableInstances #-}
module X where
import Data.List (sortOn)

data Expr a
  = K Float
  | S Char
  | M a a
  | D a a
  | SHL a a
  deriving (Functor, Foldable, Traversable, Eq, Ord, Show)

-- data EgrT l v
--   = Pure v -- monad?
--   | Add (l v) (v -> EgrT l v) -- PHOAS?
--   | Merge v v (EgrT l v)

data EgrT l
  = Pure (EClass l)
  | Add (l (EClass l)) (EgrT l) -- HOS?
  | Merge (EClass l) (EClass l) (EgrT l)

add :: l (EClass l)
    -> (EClass l -> EgrT l)
    -> EgrT l
add x f = Add x body
  where
    body = f _
        -- oh, can't be PHOAS, then I wouldn't know what the Id is)

merge :: EClass l -> EClass l -> EgrT l -> EgrT l
merge = Merge

repExpr :: EgrT Expr
repExpr =
  -- (a*2)/2
  add (S 'a')   $ \c1 ->
  add (K 2)     $ \c2 ->
  add (M c1 c2) $ \c3 ->
  add (D c3 c2) $ \c4 ->

  -- (a<<1)
  add (K 1)       $ \c5 ->
  add (SHL c1 c5) $ \c6 ->

  -- (a*2) ~ (a<<1)
  merge c3 c6     $

  -- a*(2/2)
  add (D c2 c2) $ \c8 -> 
  add (M c1 c8) $ \c9 -> 

  -- (a*2)/2 ~ a*(2/2)
  merge c9 c4 $
  -- (2/2) ~ 1
  merge c8 c5 $
  -- a*1 ~ a
  merge c9 c5 $

  Pure c4

-- -- how to turn repExpr into repExprFinal?
-- magic :: EgrT Expr (EClass Expr) -> EClass Expr
-- magic x = case x of
--   Pure v -> v
--   Add lv v2EgrTlv ->
--     magic (v2EgrTlv (EClass [lv]))
--   Merge (EClass v1) (EClass v2) v2EgrTlv ->
--     magic $ v2EgrTlv (EClass (v1 ++ v2))


-- type Eclass = Fix (Compose [] l)
newtype EClass l = EClass { enodes :: [l (EClass l)] }
deriving instance Show (l (EClass l)) => Show (EClass l)

-- Reduce to:
repExprFinal :: EClass Expr
repExprFinal = do
  let c1 = EClass [S 'a']
      c2 = EClass [K 2]
      c3 = EClass [M c1 c2, SHL c1 c4]
      c4 = EClass [D c3 c2, K 1, D c2 c2, M c1 c4]
   in c4

extract :: EClass Expr -> Fix Expr
extract cl = case best cl of
  K a -> Fix (K a)
  S s -> Fix (S s)
  M a b -> Fix $ M (extract a) (extract b)
  D a b -> Fix $ D (extract a) (extract b)
  SHL a b -> Fix $ M (extract a) (extract b)

best (EClass l) = head $ sortOn bestLazy l

-- todo: recursion schemes rather than this hack,
-- also, how to do this well?
bestLazy :: Expr (EClass Expr) -> [Int]
bestLazy x = case x of
  K a -> [0]
  S s -> [0]
  M a b -> [1] ++ bestLazy (best a) ++ bestLazy (best b)
  D a b -> [5] ++ bestLazy (best a) ++ bestLazy (best b)
  SHL a b -> [2] ++ bestLazy (best a) ++ bestLazy (best b)

--------------------------------------------------------------------------------

loeb :: Functor f => f (f a -> a) -> f a
loeb xs = fix (\fa -> fmap ($ fa) xs)

fix :: (a -> a) -> a
fix f = let y = f y in y

newtype Fix f = Fix (f (Fix f))

deriving instance Show (f (Fix f)) => Show (Fix f)
