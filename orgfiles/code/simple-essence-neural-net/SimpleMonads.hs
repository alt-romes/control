{-# LANGUAGE GHC2024, UnicodeSyntax, LinearTypes, BlockArguments, TypeFamilies, UndecidableInstances, AllowAmbiguousTypes, NoMonomorphismRestriction, RebindableSyntax #-}
import Prelude hiding (Monad(..))
import Control.Monad hiding (Monad(..))
import Unsafe.Coerce (unsafeCoerce)

unsafeLinear :: (a -> b) -> (a ⊸ b)
unsafeLinear = unsafeCoerce

plus :: Num a => a -> a ⊸ a -- See (W5)
plus k = unsafeLinear \x -> x + k

data D a b = D { image :: b, deriv :: a <-- b }
newtype a <-- b = Dual { (<|) :: b ⊸ a }

(>>=) :: D a b ⊸ (b ⊸ D b c) ⊸ D a c -- See (W1) and (W2) below
D b (Dual ba) >>= f = D c (Dual (\x -> ba (cb x)))
              where !(D c (Dual cb)) = f b

pure :: b ⊸ D b b
pure x = D x (Dual \dx -> dx)

sigmoid :: Floating a => a ⊸ D a a
sigmoid x = neg x >>= exp' >>= (\x' -> rec (1 `plus` x')) -- See (W5)

neuron :: Floating a => [a] ⊸ [a] ⊸ D a a -- See (W6)
neuron   = sigmoid . weightedSum
-- xorNet i = neuron . (n × (n × (n × n)) × id) where n = fixed neuron i

scale :: Num a => a -> a <-- a
scale y = Dual \dx -> unsafeLinear (*) dx y
--------------------------------------------------------------------------------
neg, rec, exp', log' :: Floating a => a ⊸ D a a
neg x = D (unsafeLinear negate x) (scale (-1))
-- add  = linear (uncurry (+)) (Dual \x -> (x,x))
-- mul  = D \(x,y) -> (x*y, Dual \df -> (df*y,df*x))
rec  = unsafeLinear \x -> D (recip x) (scale (-1 / x^2))
exp' = unsafeLinear \x -> let e = exp x in D e (scale e) -- See (W3)
log' = unsafeLinear \x -> D (log x) (scale (1/x))
--------------------------------------------------------------------------------

-- (W1) I'm pretty sure this is unsound if we didn't use linear functions... that's novel I think.
-- We basically regain the guarantee necessary from You Only Linearize Once of explicit Dup.
-- Because if we didn't have this as a linear function, we could have duplicated something we shouldn't have?
-- What's an example?????????? TODO!!! This is just a feeling until I have an example
-- (>>=) :: D a b ⊸ (b ⊸ D b c) ⊸ D a c
-- D b (Dual ba) >>= f = D c (Dual (\x -> ba (cb x)))
--               where !(D c (Dual cb)) = f b

-- (W2) I think I need indexed monads?
-- instance Monad (D a) where
--   D b (Dual ba) >>= f =
--     let D c (Dual cb) = f b
--      in D c (Dual (ba . cb))

-- (W3) The `x` in `exp` or `log` gets used in both the derivative and in the
-- image. We justify this because we use a linearly typed interface to
-- guarantee algebraic linearity and that the derivatives account for all
-- duplication or weaking explicitly. See (W1). This is clearly not fleshed out.
-- But the intuition feels pretty strong...

-- (W4) Related to (W3) and (W1), the linearly typed interface:
--  - Addition must be linear in both arguments, fairly sure
--  - Scaling can be unrestricted in the scalar argument?
--  Not very sure about this yet.

-- (W5) Can we pure something that will bypass our chain rule and thus result in wrong behavior?
--  My gut feeling is that the linearly typed API prevents this.
--
--  For instance,
--
--    exp >>= (\x -> pure (x*x))
--
--  must definitely be rejected, because we're using `*` on a function
--  variable `x` but don't add the derivative of `*` to the right places.
--
--  On the other hand,
--
--    exp >>= (\x -> pure (x+1))
--
--  Is fine, because the derivative of (x+1) is still `id`.
--
--  Linear types prevent the former and can allow the latter, but only because
--  we allow `+` to work on linear variables.
--    A) doing `\x -> pure (x+x)` is still forbidden because `x` can't be duplicated like this:
--      - We'd be forgetting the derivative of (x+x) (defined as scale 2)
--    B) but `\x -> pure (x+1)` is OK, because `x` is not duplicated.
--
--  That said, I think we'll need an explicit `dup` operation (it also shows up
--  in You Only Linearize Once). That would allow scenario `A`.
--
--  So, maybe, `+` should take 1 unrestricted argument and 1 linear argument,
--  guaranteeing it's only ever applied to constants + variables





--------------------------------------------------------------------------------

-- This works...! Use Qualified Do.
-- (<=<) :: (a -> D a b) -> (b -> D b c) -> (a -> D a c)
-- f <=< g = \a -> let D b (Dual f') = f a
--                     D c (Dual g') = g b
--                  in D c (Dual (f' . g'))

-- No longer needed, chain rule instead appears in >>=/>=>
-- instance Category (:->) where
--   id = linear id (Dual id)
--   g . f = D \a ->
--     let (b, Dual f') = f # a
--         (c, Dual g') = g # b
--      in (c, Dual (f' . g'))
--
-- f × g = D \(a,b) ->
--   let (c, Dual f') = f # a
--       (d, Dual g') = g # b
--    in ((c,d), Dual \(x,y) -> (f' x, g' y))
--
-- exl = linear fst (Dual $ \x -> (x, 0))
-- exr = linear snd (Dual $ \x -> (0, x))
-- dup = linear (\x -> (x,x)) (Dual $ uncurry (+))
-- scale y = Dual \dx -> dx*y
-- --------------------------------------------------------------------------------
-- (+>) k = D \x -> (k+x, Dual id)
-- fixed f a = D \b -> let (c, Dual d) = f # (a, b) in (c, Dual \c' -> snd (d c'))
-- --------------------------------------------------------------------------------
-- instance (Num a, Num b) => Num (a, b) where
--   fromInteger x = (fromInteger x, fromInteger x)
--   (+) (a, b) (c, d) = (a+c, b+d)
--   negate (a, b)     = (negate a, negate b)
--
-- class    WSum a      where weightedSum :: (a,a) :-> Double
-- instance WSum Double where weightedSum = mul
-- instance (Num b, WSum b) => WSum (Double, b) where
--   weightedSum = add . (mul × weightedSum) . ((exl × exl) × (exr × exr)) . dup
--
-- sigmoid  = rec . (1 +>) . exp' . neg -- 1/(1+exp(-x))
-- neuron   = sigmoid . weightedSum
-- xorNet i = neuron . (n × (n × (n × n)) × id) where n = fixed neuron i
--
-- cost (p:ps) = foldl' (\acc x -> add . (cost1 x × acc) . dup) (cost1 p) ps
--   where cost1 (i, o) = mul . dup . (negate o +>) . xorNet i
--
-- examples = [((0,0),0), ((0,1),1), ((1,0),1), ((1,1),0)]
--
-- step i weights = do
--   let (r, Dual grad) = cost examples # weights
--   putStrLn $ "Cost(" ++ show i ++ "): " ++ show r
--   pure $ weights + grad (-10)
--
-- train initialWeights = do
--   finalWeights <- foldl' (\acc i -> acc >>= step i) (pure initialWeights) [0..1000000]
--   putStrLn "Neural net result on examples:"
--   print $ map (\ex -> fst (xorNet (fst ex) # finalWeights)) examples
--   putStrLn "Expected results:"
--   print (map snd examples)
--
-- main = do
--   let randomWeights = (((0.263158804855843,0.9198593145637255),((0.29665240651775127,8.055163018364941e-2),((0.5928698356302193,0.8933566967251643),(0.6951127432289572,0.9105678050355198)))),(0.28879960912172786,(0.9519938818911216,(0.3136325216345741,2.7947832757196922e-2))))
--   train (randomWeights :: (((Double, Double), ((Double, Double), ((Double, Double), (Double, Double)))), (Double, (Double, (Double, Double)))))
