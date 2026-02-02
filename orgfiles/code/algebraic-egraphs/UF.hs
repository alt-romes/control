module Data.Equality.Graph.ReprUnionFind
  ( ReprUnionFind
  , emptyUF
  , makeNewSet
  , unionSets
  , findRepr
  ) where

import qualified Data.IntMap.Internal as IIM (IntMap(..))
import qualified Data.IntMap.Strict as IIM

data ReprUnionFind = RUF (IIM.IntMap Int) !Int

-- | The empty 'ReprUnionFind'.
emptyUF :: ReprUnionFind
emptyUF = RUF IIM.Nil 1

-- | Create a new e-class id in the given 'ReprUnionFind'.
makeNewSet :: ReprUnionFind -> (Int, ReprUnionFind)
makeNewSet (RUF im si) = (si, RUF (IIM.insert si 0 im) (si + 1))

-- | Union @a@ and @b@
unionSets :: Int {-a-} -> Int {-b-} -> ReprUnionFind
          -> ReprUnionFind -- ^ The new leader is always @a@
unionSets a b (RUF im si) = RUF (IIM.insert b a im) si

-- | Find the canonical representation of an e-class id
findRepr :: Int -> ReprUnionFind -> Int
findRepr v (RUF m s) =
  case m IIM.! v of
    0 -> v
    x -> findRepr x (RUF m s)
