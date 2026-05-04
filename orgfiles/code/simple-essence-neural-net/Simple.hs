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

----------------------- Primitive functions ------------------------------------
assoc    = D (\(a,(b,c)) -> (((a,b),c), \((a,b),c) -> (a,(b,c))))
dup      = D (\x -> ((x,x), uncurry (+)))          ; dup :: Num a => a :-> (a,a)
add      = D (\(x,y) -> (x + y, \x -> (x,x)))
mul      = D (\(x,y) -> (x*y, \df -> (df*y,df*x)))
rec      = D (\x -> (1/x, (*(-1 / x^2))))
exp'     = D (\x -> let e = exp x in (e, (*e)))
dot'     = D (\(a,b) -> (sum (zipWith (*) a b), \d -> (map (*d) b, map (*d) a)))
map' f   = D (\a -> let (b, f') = unzip (map (f #) a) in (b, zipWith ($) f'))
f `at` a = D (\b -> let (c, d) = f # (a, b) in (c, snd . d))  -- papp static val

------------------------- Neural Network ---------------------------------------
sigmoid        = rec . (add `at` 1) . exp' . (mul `at` (-1))    -- 1/(1+exp(-x))
neuron         = sigmoid . add . (dot' × id) . assoc                 -- σ(W·I+b)
xornet i       = neuron . (map' (neuron `at` i) × id)        -- 2x4x1 neural net
cost1 (i, o)   = mul . dup . (add `at` (-o)) . xornet i  -- sqr err cost of 1 ex
cost [m,n,l,p] = add . (add × add) . ((cost1 m × cost1 n) × (cost1 l × cost1 p))
                                                             . (dup × dup) . dup
step i weights | let (r, grad) = cost exs # weights
               = putStrLn ("Cost(" ++ show i ++ "): " ++ show r)
               >> return (weights + grad (-10))

exs@[(a,a'),(b,b'),(c,c'),(d,d')] = [([0,0],0), ([0,1],1), ([1,0],1), ([1,1],0)]
main = do
  ws0 <- readLn @([([Double], Double)], ([Double], Double))      -- read weights
  ws1 <- foldl' (\ws' i -> ws' >>= step i) (pure ws0) [0..99999] -- upd. weights
  print $ map (\(i,o) -> show (fst (xornet i # ws1)) ++ " ~=? " ++ show o) exs

instance Num a => Num ([a], a) where (w,b) + (v,c) = (zipWith (+) w v, b + c)
