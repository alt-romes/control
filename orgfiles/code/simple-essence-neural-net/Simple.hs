import Prelude hiding (id, (.))
import Control.Category

newtype a :-> b = D    { (#)  :: a -> (b, a <-- b) }
newtype a <-- b = Dual { (<|) :: b -> a            }
linear f fd = D (\a -> (f a, fd))
scale  y    = Dual (\dx -> dx*y)

instance Category (:->) where
  id = linear id (Dual id)
  g . f = D $ \a -> -- chain rule
    let (b, Dual f') = f # a; (c, Dual g') = g # b
     in (c, Dual (f' . g'))

f × g = D $ \(a,b) ->
  let (c, f') = f # a; (d, g') = g # b
   in ((c,d), Dual (\(x,y) -> (f' <| x, g' <| y)))
--------------------------------------------------------------------------------
assoc     = linear (\(a,(b,c)) -> ((a,b),c)) (Dual (\((a,b),c) -> (a,(b,c))))
dup       = linear (\x -> (x,x)) (Dual (uncurry (+)))
neg       = linear negate (scale (-1))
add       = linear (uncurry (+)) (Dual $ \x -> (x,x))
(+>) k    = linear (+k) (Dual id)
mul       = D $ \(x,y) -> (x*y, Dual (\df -> (df*y,df*x)))
rec       = D $ \x -> (recip x, scale (-1 / x^2))
exp'      = D $ \x -> let e = exp x in (e, scale e)
--------------------------------------------------------------------------------
dupI    n = linear (\x -> replicate n x) (Dual sum)
crossI fs = D $ \as -> let (bs, bsas) = unzip (zipWith (#) fs as) in (bs, Dual (zipWith (<|) bsas))
sumI      = D $ \xs -> (sum xs, Dual (\x -> replicate (length xs) x))
hadamard  = D $ \(ss, xs) -> (ss .*. xs, Dual (\dfs -> (xs .*. dfs, ss .*. dfs))) where (.*.) = zipWith (*)
fixed f a = D $ \b -> let (c, Dual d) = f # (a, b) in (c, Dual (snd . d))
--------------------------------------------------------------------------------
sigmoid  = rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
neuron   = sigmoid . add . ((sumI . hadamard) × id) . assoc
xorNet i = neuron . (crossI [n, n, n, n] × id) where n = fixed neuron i
cost  ps = sumI . crossI (map cost1 ps) . dupI (length ps)
  where cost1 (i, o) = mul . dup . (negate o +>) . xorNet i

step examples (i :: Int) weights = do
  let (r, Dual grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10)

main = do
  let examples = [([0,0],0), ([0,1],1), ([1,0],1), ([1,1],0)]
  initialWeights <- readLn @Weights
  finalWeights   <- foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..1000000]
  putStrLn $ "Neural net results: " ++ show (map (\(e,_) -> fst (xorNet e # finalWeights)) examples)
  putStrLn $ "Expected results:   " ++ show (map snd examples)

type Weights = ([([Double], Double)], ([Double], Double))
instance Num Weights where
  fromInteger x' = (replicate 4 ([x,x], x), ([x,x,x,x],x)) where x = fromInteger x'
  (w1, (w2,b2)) + (w3, (w4,b4)) = (zipWith (\(ws1, b1) (ws2, b2) -> (zipWith (+) ws1 ws2, b1+b2)) w1 w3, (zipWith (+) w2 w4, b2+b4))















-- . ^ only needed to do the hacky smallest thing. with "NN made moderately
-- complex" we can introduce all the nice classes for this to extend to all
-- vector lengths, used typed indexes, just do it much better.
--------------------------------------------------------------------------------
-- Some other notes:
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
