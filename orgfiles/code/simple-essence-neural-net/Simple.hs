import Prelude hiding (id, (.)); import Control.Category

--------------------- Differentiable functions----------------------------------
newtype a :-> b = D { (#) :: a -> (b, b -> a) }

instance Category (:->) where
  id = D $ \a -> (a, id)
  g . f = D $ \a -> -- chain rule
    let (b, f') = f # a; (c, g') = g # b
     in (c, f' . g')

f × g = D $ \(a,b) ->
  let (c, f') = f # a; (d, g') = g # b
   in ((c,d), \(x,y) -> (f' x, g' y))

------------------------- Building Blocks --------------------------------------
assoc    = D $ \(a,(b,c)) -> (((a,b),c), \((a,b),c) -> (a,(b,c)))
dup      = D $ \x -> ((x,x), uncurry (+))          ; dup :: Num a => a :-> (a,a)
neg      = D $ \x -> (-x, (*(-1)))
add      = D $ \(x,y) -> (x + y, \x -> (x,x))
mul      = D $ \(x,y) -> (x*y, \df -> (df*y,df*x))
rec      = D $ \x -> (1/x, (*(-1 / x^2)))
exp'     = D $ \x -> let e = exp x in (e, (*e))
dot'     = D $ \(a,b) -> (sum (zipWith (*) a b), \d -> (map (*d) b, map (*d) a))
map' f   = D $ \a -> let (b, f') = unzip (map (f #) a) in (b, zipWith ($) f')
f `at` a = D $ \b -> let (c, d) = f # (a, b) in (c, snd . d)  -- papp static val

------------------------- Neural Network ---------------------------------------
sigmoid        = rec . (add `at` 1) . exp' . neg                -- 1/(1+exp(-x))
neuron         = sigmoid . add . (dot' × id) . assoc                 -- σ(W·I+b)
xorNet i       = neuron . (map' (neuron `at` i) × id)
cost1 (i, o)   = mul . dup . (add `at` (-o)) . xorNet i
cost (m,n,l,p) = add . (add × add) . ((cost1 m × cost1 n) × (cost1 l × cost1 p)) . (dup × dup) . dup

step (i :: Int) weights = do
  let (r, grad) = cost exs # weights
  putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
  return $ weights + grad (-10)

exs@((a,a'),(b,b'),(c,c'),(d,d')) = (([0,0],0), ([0,1],1), ([1,0],1), ([1,1],0))
main = do -- perl -pe's/r/rand/ge'<<<'([([r,r],r),([r,r],r),([r,r],r),([r,r],r)],([r,r,r,r],r))' | ./Simple
  initialWeights <- readLn @([([Double], Double)], ([Double], Double))
  finalWeights   <- foldl' (\acc i -> acc >>= step i) (pure initialWeights) [0..300000]
  putStrLn $ "Neural net results: " ++ let r i = fst (xorNet i # finalWeights) in show (r a, r b, r c, r d)
  putStrLn $ "Expected results:   " ++ show (a', b', c', d')

instance (Num a, Num b) => Num ([a], b) where (w1,b1) + (w2,b2) = (zipWith (+) w1 w2, b1 + b2)
