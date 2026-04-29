{-# LANGUAGE GHC2024, BlockArguments, TypeApplications, TypeFamilies, UndecidableInstances, AllowAmbiguousTypes, NoMonomorphismRestriction #-}
import Prelude hiding (id, (.))
import Control.Category

newtype a :-> b = D { (#) :: a -> (b, a <-- b) }
newtype a <-- b = Dual { (<|) :: b -> a }
linear f fd = D (\a -> (f a, fd))

instance Category (:->) where
  id = linear id (Dual id)
  g . f = D \a ->
    let (b, Dual f') = f # a
        (c, Dual g') = g # b
     in (c, Dual (f' . g'))

f × g = D \(a,b) ->
  let (c, Dual f') = f # a
      (d, Dual g') = g # b
   in ((c,d), Dual \(x,y) -> (f' x, g' y))

exl = linear fst (Dual $ \x -> (x, 0))
exr = linear snd (Dual $ \x -> (0, x))
dup = linear (\x -> (x,x)) (Dual $ uncurry (+))
scale y = Dual \dx -> dx*y
--------------------------------------------------------------------------------
neg  = linear negate (scale (-1))
add  = linear (uncurry (+)) (Dual $ \x -> (x,x))
mul  = D \(x,y) -> (x*y, Dual \df -> (df*y,df*x))
rec  = D \x -> (recip x, scale (-1 / x^2))
exp' = D \x -> let e = exp x in (e, scale e)
log' = D \x -> (log x, scale (1/x))
(+>) k = D \x -> (k+x, Dual id)
fixed f a = D \b -> let (c, Dual d) = f # (a, b) in (c, Dual \c' -> snd (d c'))
--------------------------------------------------------------------------------
instance (Num a, Num b) => Num (a, b) where
  fromInteger x = (fromInteger x, fromInteger x)
  (+) (a, b) (c, d) = (a+c, b+d)
  negate (a, b)     = (negate a, negate b)

class    WSum a      where weightedSum :: (a,a) :-> Double
instance WSum Double where weightedSum = mul
instance (Num b, WSum b) => WSum (Double, b) where
  weightedSum = add . (mul × weightedSum) . ((exl × exl) × (exr × exr)) . dup

sigmoid  = rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
neuron   = sigmoid . weightedSum
xorNet i = neuron . (n × (n × (n × n)) × id) where n = fixed neuron i

cost (p:ps) = foldl' (\acc x -> add . (cost1 x × acc) . dup) (cost1 p) ps
  where cost1 (i, o) = mul . dup . (negate o +>) . xorNet i

examples = [((0,0),0), ((0,1),1), ((1,0),1), ((1,1),0)] :: [((Double, Double), Double)]

step (i :: Int) weights = do
  let (r, Dual grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10)

train initialWeights = do
  finalWeights <- foldl' (\acc i -> acc >>= step i) (pure initialWeights) [0..1000000]
  putStrLn "Neural net result on examples:"
  print $ map (\ex -> fst (xorNet (fst ex) # finalWeights)) examples
  putStrLn "Expected results:"
  print (map snd examples)

-- perl -pe's/x/rand/ge'<<<'(((x,x),((x,x),((x,x),(x,x)))),(x,(x,(x,x))))'
main = readLn >>= \weights -> train weights

--------------------------------------------------------------------------------
-- -- Not obvious!
-- curry' :: (a :-> (b :-> c)) -> ((a, b) :-> c)
-- curry' f = D \(a, b) ->
--   let (bc, bca) = f # a
--       (c, cb)  = bc # b
--    in (c, Dual \c -> (bca <| bc, cb <| c))
-- uncurry' :: ((a,b) :-> c) -> (a :-> (b :-> c))
-- uncurry' f = D \a ->
--   (D \b ->
--     let
--         (c, c_ab) = f # (a,b)
--      in _
--     , _)
