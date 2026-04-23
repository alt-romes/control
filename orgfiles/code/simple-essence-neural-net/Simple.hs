{-# LANGUAGE GHC2024, BlockArguments, TypeFamilies, UndecidableInstances, AllowAmbiguousTypes, NoMonomorphismRestriction #-}
import GHC.TypeNats
import Prelude hiding (id, (.))
import Control.Category

-- | Differentiable+ functions
newtype a :-> b = D { (#) :: a -> (b, a <-- b) }

-- | Dual of Linear Map. See also "Transposition (Fig 11)" in "You Only Linearize Once".
newtype a <-- b = Dual { runDual :: b -> a }

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

type (×) = (,)
(×) :: (a :-> c) -> (b :-> d) -> ((a×b) :-> (c×d))
f × g = D \(a,b) -> -- paralell composition
  let (c, Dual f') = f # a
      (d, Dual g') = g # b
   in ((c,d), Dual \(x,y) -> (f' x, g' y))

exl = linear fst (Dual $ \x -> (x, 0))          -- TDropLin
exr = linear snd (Dual $ \x -> (0, x))          -- TDropLin
dup = linear (\x -> (x,x)) (Dual $ uncurry (+)) -- TLinDup

scale y = Dual \dx -> dx*y -- (linearly) scale argument by fixed y (TLinMul)
--------------------------------------------------------------------------------
neg  = linear negate (scale (-1))
add  = linear (uncurry (+)) (Dual $ \x -> (x,x))
mul  = D \(x,y) -> (x*y, Dual \df -> (df*y,df*x))
rec  = D \x -> (recip x, scale (-1 / x^2))
exp' = D \x -> let e = exp x in (e, scale e)
log' = D \x -> let l = log x in (l, scale (-1/l))

(+>) :: Num a => a -> (a :-> a)
(+>) k = D \x -> (k+x, Dual id) -- adds constant number

sigmoid = rec . (1 +>) . exp' . neg
--------------------------------------------------------------------------------
type family R n where
  R 1 = Double
  R n = Double × R (n-1)

instance (Num a, Num b) => Num (a, b) where
  fromInteger x = (fromInteger x, fromInteger x)
  (+) (a, b) (c, d) = (a+c, b+d)
  negate (a, b)     = (negate a, negate b)

class Layer a where -- ugly... how to avoid this completely?
  weightedSum  :: a -> a :-> R 1
  weightedSum' :: (a × a) :-> R 1
instance Layer Double where
  weightedSum x = linear (*x) (scale x)
  weightedSum'  = mul

instance (Num b, Layer b) => Layer (Double, b) where
  weightedSum (x, xs) = add . (linear (*x) (scale x) × weightedSum xs)
  weightedSum'        = add . (mul × weightedSum') . ((exl × exl) × (exr × exr)) . dup

type L1W = (R 2 × (R 2 × (R 2 × R 2)))

xorNet :: R 2 -> (L1W, R 4) :-> R 1
xorNet i = l2 . ((l1 i . exl) × exr) . dup

l1 :: R 2 -> L1W :-> R 4
l1 i = ( sigmoid . weightedSum @(R 2) i) × ((sigmoid . weightedSum @(R 2) i) ×
       ((sigmoid . weightedSum @(R 2) i) × (sigmoid . weightedSum @(R 2) i)))

l2 :: (R 4 × R 4) :-> R 1
l2 = sigmoid . weightedSum'

cost :: [(R 2, R 1)] -> (L1W × R 4) :-> R 1
cost (p:ps) = linear (*n) (scale n) . foldl' (\acc x -> add . (cost1 x × acc) . dup) (cost1 p) ps
  where
    cost1 :: (R 2, R 1) -> (L1W × R 4) :-> R 1
    cost1 (i, o) = mul . dup . (negate o +>) . xorNet i

    n = 1/fromIntegral (length ps + 1)

examples :: [(R 2, R 1)]
examples = [((0,0),0), ((0,1),1), ((1,0),1), ((1,1),0)]

step :: Int -> (L1W, R 4) -> IO (L1W, R 4)
step i weights = do
  let (r, Dual grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10) -- adjust weights

train :: (L1W, R 4) -> IO ()
train initialWeights = do
  finalWeights <- foldl' (\acc i -> acc >>= step i) (pure initialWeights) [0..1000000]
  putStrLn "Neural net result on examples:"
  print $ map (\ex -> fst (xorNet (fst ex) # finalWeights)) examples
  putStrLn "Expected results:"
  print (map snd examples)

main = do -- try something like `awk 'BEGIN{srand(); for (i=1;i<100;i++) print(rand())}' | ./Simple`
  -- generated with: initialWeights <- randomIO @(L1W, R 4)
  let randomWeights = (((0.263158804855843,0.9198593145637255),((0.29665240651775127,8.055163018364941e-2),((0.5928698356302193,0.8933566967251643),(0.6951127432289572,0.9105678050355198)))),(0.28879960912172786,(0.9519938818911216,(0.3136325216345741,2.7947832757196922e-2))))
  train randomWeights

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
-- unrestricted) and making addition work normally OK)
