{-# LANGUAGE GHC2024, BlockArguments, TypeFamilies, UndecidableInstances, AllowAmbiguousTypes, NoMonomorphismRestriction #-}
import GHC.TypeNats
import Prelude hiding (id, (.))
import Control.Category
import Data.Bifunctor

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
sum' = D \xs -> (sum xs, Dual \x -> replicate (length xs) x)
hadamard = D \(ss, xs) -> (ss .*. xs, Dual \dfs -> (xs .*. dfs, ss .*. dfs)) where (.*.) = zipWith (*)
cons x = D \xs -> (x:xs, Dual \(dx:dxs) -> dxs) -- add a constant number to head of Vec. All weight vecs have leading biases
--------------------------------------------------------------------------------
fixed f a = D \b -> let (c, Dual d) = f # (a, b) in (c, Dual \c' -> snd (d c'))

crossI :: [a :-> b] -> ([a] :-> [b])
crossI fs = D \as -> let (bs, bsas) = unzip $ zipWith (#) fs as in (bs, Dual \dbs -> zipWith (<|) bsas dbs)

sigmoid  = rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))

neuron :: ([Double]{-size n-}, [Double]{-size n+1-}) :-> Double
neuron = sigmoid . sum' . hadamard . (cons 1 × id)

xorNet :: [Double]{-size n-} -> ([[Double]{-size n+1-}], [Double]) :-> Double
xorNet i = neuron . (crossI (replicate 4 n) × id) where n = fixed neuron i

cost :: [([Double], Double)] -> ([[Double]], [Double]) :-> Double
cost (p:ps) = foldl' (\acc x -> add . (cost1 x × acc) . dup) (cost1 p) ps
  where cost1 (i, o) = mul . dup . (negate o +>) . xorNet i

examples = [([ 0,0 ],0), ([ 0,1 ],1), ([ 1,0 ],1), ([ 1,1 ],0)]

step :: Double -> ([[Double]], [Double]) -> IO ([[Double]], [Double])
step i weights = do
  let (r, Dual grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + (grad (-10))

train :: ([[Double]], [Double]) -> IO ()
train initialWeights = do
  finalWeights <- foldl' (\acc i -> acc >>= step i) (pure initialWeights) [0..1000000]
  putStrLn "Neural net result on examples:"
  print $ map (\ex -> fst (xorNet (fst ex) # finalWeights)) examples
  putStrLn "Expected results:"
  print (map snd examples)

main = do
  let randomWeights = ([[0.263158804855843,0.9198593145637255], [0.29665240651775127,8.055163018364941e-2], [0.5928698356302193,0.8933566967251643], [0.6951127432289572,0.9105678050355198]],[0.28879960912172786,0.9519938818911216,0.3136325216345741,2.7947832757196922e-2])
  train randomWeights
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

