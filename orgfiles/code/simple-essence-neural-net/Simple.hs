import Prelude hiding (id, (.))
import Control.Category

newtype a :-> b = D { (#)  :: a -> (b, b -> a) }
linear f fd = D (\a -> (f a, fd))

instance Category (:->) where
  id = linear id (id)
  g . f = D $ \a -> -- chain rule
    let (b, f') = f # a; (c, g') = g # b
     in (c, f' . g')

f × g = D $ \(a,b) ->
  let (c, f') = f # a; (d, g') = g # b
   in ((c,d), \(x,y) -> (f' x, g' y))
--------------------------------------------------------------------------------
assoc     = linear (\(a,(b,c)) -> ((a,b),c)) (\((a,b),c) -> (a,(b,c)))
dup       = linear (\x -> (x,x)) (uncurry (+))
neg       = linear negate (*(-1))
add       = linear (uncurry (+)) (\x -> (x,x))
mul       = D $ \(x,y) -> (x*y, \df -> (df*y,df*x))
rec       = D $ \x -> (recip x, (*(-1 / x^2)))
exp'      = D $ \x -> let e = exp x in (e, (*e))
--------------------------------------------------------------------------------
dupI    n = linear (replicate n) sum
crossI fs = D $ \as -> let (bs, bsas) = unzip (zipWith (#) fs as) in (bs, zipWith ($) bsas)
sumI      = D $ \xs -> (sum xs, replicate (length xs))
hadamard  = D $ \(ss, xs) -> (ss .*. xs, \dfs -> (xs .*. dfs, ss .*. dfs)) where (.*.) = zipWith (*)
fixed f a = D $ \b -> let (c, d) = f # (a, b) in (c, snd . d)
--------------------------------------------------------------------------------
sigmoid  = rec . (fixed add 1) . exp' . neg -- 1/(1+exp(-x))
neuron   = sigmoid . add . ((sumI . hadamard) × id) . assoc
xorNet i = neuron . (crossI [n, n, n, n] × id) where n = fixed neuron i
cost  ps = sumI . crossI (map cost1 ps) . dupI (length ps)
  where cost1 (i, o) = mul . dup . (fixed add (negate o)) . xorNet i

step examples (i :: Int) weights = do
  let (r, grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10)

main = do
  let examples = [([0,0],0), ([0,1],1), ([1,0],1), ([1,1],0)]
  initialWeights <- readLn @([([Double], Double)], ([Double], Double))
  finalWeights   <- foldl' (\acc i -> acc >>= step examples i) (pure initialWeights) [0..1000000]
  putStrLn $ "Neural net results: " ++ show (map (\(e,_) -> fst (xorNet e # finalWeights)) examples)
  putStrLn $ "Expected results:   " ++ show (map snd examples)

instance Num ([([Double], Double)], ([Double], Double)) where
  fromInteger x' = (replicate 4 ([x,x], x), ([x,x,x,x],x)) where x = fromInteger x'
  (w1, (w2,b2)) + (w3, (w4,b4)) = (zipWith (\(ws1, b1) (ws2, b2) -> (zipWith (+) ws1 ws2, b1+b2)) w1 w3, (zipWith (+) w2 w4, b2+b4))

-- . ^ only needed to do the hacky smallest thing. with "NN made moderately
-- complex" we can introduce all the nice classes for this to extend to all
-- vector lengths, used typed indexes, just do it much better.
--------------------------------------------------------------------------------
