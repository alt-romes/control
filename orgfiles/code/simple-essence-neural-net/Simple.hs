{-# LANGUAGE GHC2024, UnicodeSyntax, BlockArguments, TypeFamilies, UndecidableInstances, AllowAmbiguousTypes, NoMonomorphismRestriction, DataKinds #-}
{-# OPTIONS_GHC -Wno-missing-methods #-}
import GHC.TypeLits
import Prelude hiding (id, (.))
import Control.Category
import Data.Proxy

-- | Vectors
newtype V (n :: Nat) a = V { els :: [a] } deriving (Eq, Functor, Show)

instance (KnownNat n, Num a) => Num (V n a) where -- really, instance Vector Space
  fromInteger a     = V [fromInteger a | _ <- [1..natVal @n Proxy]]
  (+) (V as) (V bs) = V (zipWith (+) as bs)
  (*) (V as) (V bs) = V (zipWith (*) as bs) -- hadamard product
  negate            = fmap negate

-- | Differentiable+ functions
newtype a :-> b = D { (#) :: a -> (b, a <-- b) }

-- | Dual of Linear Map. See "Transposition (Fig 11)" in "You Only Linearize Once".
newtype a <-- b = Dual { (<|) :: b -> a }

-- | The derivative of every linear function is itself, everywhere
linear :: (a -> b) -> (a <-- b) -> (a :-> b)
linear f fd = D (\a -> (f a, fd))

-- | Differentiable+ functions form a Category
instance Category (:->) where
  id = linear id (Dual id)
  g . f = D \a -> -- chain rule
    let (b, Dual f') = f # a
        (c, Dual g') = g # b
     in (c, Dual (f' . g') {- invert ! -})

(×) :: (a :-> c) -> (b :-> d) -> ((a,b) :-> (c,d))
f × g = D \(a,b) -> -- paralell composition
  let (c, Dual f') = f # a
      (d, Dual g') = g # b
   in ((c,d), Dual \(x,y) -> (f' x, g' y))

exl = linear fst (Dual \x -> (x, 0))            -- TDropLin
exr = linear snd (Dual \x -> (0, x))            -- TDropLin
dup = linear (\x -> (x,x)) (Dual \(x,y) -> x+y) -- TLinDup
--------------------------------------------------------------------------------
scale y = Dual \dx -> dx*y -- (linearly) scale argument by fixed y (TLinMul)
--------------------------------------------------------------------------------
add  = linear (uncurry (+)) (Dual \x -> (x,x))
mul  = D \(x,y) -> (x*y, Dual \df -> (df*y, df*x))
neg  = linear negate (scale (-1))
rec  = D \x -> (recip x, scale (-1 / x^2))
exp' = D \x -> let e = exp x in (e, scale e)
log' = D \x -> let l = log x in (l, scale (-1/l))

(+>) :: Num a => a -> (a :-> a)
(+>) k = D \x -> (k+x, Dual id) -- adds constant number

sigmoid = rec . (1 +>) . exp' . neg -- 1 / (1 + exp (-x))
--------------------------------------------------------------------------------
-- | Kind of uncurry, allows fixing one of the inputs
fixed :: ((a,b) :-> c) -> (a -> (b :-> c))
fixed f a = D \b -> let (c, Dual d) = f # (a, b) in (c, Dual \c' -> snd (d c'))

type S   = Double -- scalar (R 1)
type R n = V n Double

-- | weightedSum ([a, b], [c, d]) == a*c+b*d
weightedSum = addN . mul

xorNet :: R 2 -> (V 4 (R 2), R 4) :-> S
xorNet i = l2 . (l1 i × id)

l1 :: R 2 -> V 4 (R 2) :-> R 4
l1 i = crossN (V [sigmoid . fixed weightedSum i | _ <- [1..4]])

l2 :: (R 4, R 4) :-> S
l2 = sigmoid . weightedSum

instance (Num a, Num b) => Num (a, b) where
  fromInteger a     = (fromInteger a, fromInteger a)
  (+) (a, b) (c, d) = (a+c, b+d)
  negate (a, b)     = (negate a, negate b)

cost :: [(R 2, S)] -> (V 4 (R 2), R 4) :-> S
cost (p:ps) = linear (*n) (scale n) .
              foldl' (\acc x -> add . (cost1 x × acc) . dup) (cost1 p) ps
  where
    cost1 :: (R 2, S) -> (V 4 (R 2), R 4) :-> S
    cost1 (i, o) = mul . dup . (negate o +>) . xorNet i

    n = 1/fromIntegral (length ps + 1)

examples :: [(R 2, S)]
examples = [(V [0,0],0), (V [0,1],1), (V [1,0],1), (V [1,1],0)]

step :: Int -> (V 4 (R 2), R 4) -> IO (V 4 (R 2), R 4)
step i weights = do
  let (r, Dual grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10) -- adjust weights

train :: (V 4 (R 2), R 4) -> IO ()
train initialWeights = do
  finalWeights <- foldl' (\acc i -> acc >>= step i) (pure initialWeights) [0..1000000]
  putStrLn "Neural net result on examples:"
  print $ map (\ex -> fst (xorNet (fst ex) # finalWeights)) examples
  putStrLn "Expected results:"
  print (map snd examples)

main = do -- try something like `awk 'BEGIN{srand(); for (i=1;i<100;i++) print(rand())}' | ./Simple`
  -- generated with: initialWeights <- randomIO @(L1W, R 4)
  let
    randomWeights =
      (V[V[0.263158804855843,0.9198593145637255], V[0.29665240651775127,8.055163018364941e-2], V[0.5928698356302193,0.8933566967251643], V[0.6951127432289572,0.9105678050355198]],V[0.28879960912172786,0.9519938818911216,0.3136325216345741,2.7947832757196922e-2])
  train randomWeights

--------------------------------------------------------------------------------
-- N-ary dup and cross
dupN :: ∀ n a. KnownNat n => Num a => a :-> V n a
dupN = linear (\x -> V [x | _ <- [1..natVal @n Proxy]]) (Dual (sum . els)) -- TLinDup
crossN :: V n (a :-> b) -> (V n a :-> V n b)
crossN (V fs) = D \(V as) -> -- paralell composition
  let (bs, ds) = unzip (zipWith (#) fs as)
   in (V bs, Dual \(V das) -> V (zipWith (<|) ds das))
addN, mulN :: ∀ n a. KnownNat n => (Eq a, Num a) => V n a :-> a
addN = linear (sum . els) (Dual \x -> V [x | _ <- [1..natVal @n Proxy]])
mulN = D \(V as) -> (product as, Dual \df -> let ixs = zip as [1::Int ..] in
           V [df*product [v | (v,j) <- ixs, j /= i] | (_,i) <- ixs])
--------------------------------------------------------------------------------
-- -- Simple Example
-- sqr = mul . dup
-- sqrMag = add . (sqr × sqr)
--
-- -- gradient is [2x 2y]
-- sqrMagGrad x y = (snd (sqrMag # (x,y))) <| 1 {- seed for the output == 1, returns gradient vector -}

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
--
-- We could do an linear algebraically module based on linear substructurally
-- by making multiplication receive only 1 linear argument (the other is
-- unrestricted) and making addition work normally OK
