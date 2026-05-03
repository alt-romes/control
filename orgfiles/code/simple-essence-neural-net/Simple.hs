import Prelude hiding (id, (.)); import Control.Category

newtype a :-> b = D { (#)  :: a -> (b, b -> a) }
linear f fd = D (\a -> (f a, fd))

instance Category (:->) where
  id = linear id id
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
dotI      = D $ \(ss, xs) -> (sum (zipWith (*) ss xs), \dfs -> (map (*dfs) xs, map (*dfs) ss))
crossI fs = D $ \as -> let (bs, bsas) = unzip (zipWith (#) fs as) in (bs, zipWith ($) bsas)
fixed f a = D $ \b -> let (c, d) = f # (a, b) in (c, snd . d)
--------------------------------------------------------------------------------
sigmoid   = rec . (fixed add 1) . exp' . neg -- 1/(1+exp(-x))
neuron    = sigmoid . add . (dotI × id) . assoc
xorNet  i = neuron . (crossI [n, n, n, n] × id) where n = fixed neuron i
cost (e1,e2,e3,e4) = add . (add × add) . ((cost1 e1 × cost1 e2) × (cost1 e3 × cost1 e4)) . (dup × dup) . dup
  where cost1 (i, o) = mul . dup . (fixed add (negate o)) . xorNet i

step examples (i :: Int) weights = do
  let (r, grad) = cost examples # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  pure $ weights + grad (-10)

main = do -- perl -pe's/r/rand/ge'<<<'([([r,r],r),([r,r],r),([r,r],r),([r,r],r)],([r,r,r,r],r))' | ./Simple
  let xamples@((i1,o1),(i2,o2),(i3,o3),(i4,o4)) = (([0,0],0), ([0,1],1), ([1,0],1), ([1,1],0))
  initialWeights <- readLn @([([Double], Double)], ([Double], Double))
  finalWeights   <- foldl' (\acc i -> acc >>= step xamples i) (pure initialWeights) [0..300000]
  putStrLn $ "Neural net results: " ++ let run i = fst (xorNet i # finalWeights) in show (run i1, run i2, run i3, run i4)
  putStrLn $ "Expected results:   " ++ show (o1, o2, o3, o4)

instance (Num a, Num b) => Num ([a], b) where (w1,b1) + (w2,b2) = (zipWith (+) w1 w2, b1 + b2)
dup :: Num a => a :-> (a,a)
