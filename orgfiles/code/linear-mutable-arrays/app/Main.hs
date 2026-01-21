{-# LANGUAGE NoImplicitPrelude, LinearTypes, NegativeLiterals #-}
module Main (main) where

import qualified Prelude as P

-- linear
import Linear (normalize)
import Linear.V3 (cross, V3(..))

-- linear-base
import Prelude.Linear
import qualified Data.Array.Mutable.Linear as Array (Array, get, set, alloc, toList, map)

{- | Compute the smooth normal vectors of a mesh surface.

Uses Inigo Quilez's fast and correct algorithm: https://iquilezles.org/articles/normals/

void Mesh_normalize( Mesh *myself )
{
    Vert     *vert = myself->vert;
    Triangle *face = myself->face;

    for( int i=0; i<myself->mNumVerts; i++ ) vert[i].normal = vec3(0.0f);

    for( int i=0; i<myself->mNumFaces; i++ )
    {
        const int ia = face[i].v[0];
        const int ib = face[i].v[1];
        const int ic = face[i].v[2];

        const vec3 e1 = vert[ia].pos - vert[ib].pos;
        const vec3 e2 = vert[ic].pos - vert[ib].pos;
        const vec3 no = cross( e1, e2 );

        vert[ia].normal += no;
        vert[ib].normal += no;
        vert[ic].normal += no;
    }

    for( i=0; i<myself->mNumVerts; i++ ) verts[i].normal = normalize( verts[i].normal );
}

Task: implement meshNormalise, which has an unrestricted API, by using linear mutable Arrays under the hood.
-}
meshNormalise :: [V3 Int] -- ^ The Mesh face (3 indices form a face)
              -> [V3 Float] -- ^ The Mesh verts (each vertex has x,y,z)
              -> [V3 Float] -- ^ The smooth Normals at each vertex
meshNormalise faces vs = _


_test :: Bool
_test = meshNormalise _octaFaces _octaVerts P.== _octaVerts

_octaVerts :: [V3 Float]
_octaVerts =
  [ V3  0  0  1 -- 0
  , V3  1  0  0 -- 1
  , V3  0  1  0 -- 2
  , V3 -1  0  0 -- 3
  , V3  0 -1  0 -- 4
  , V3  0  0 -1 -- 5
  ]

_octaFaces :: [V3 Int]
_octaFaces =
  [ V3 0 4 3
  , V3 0 3 2
  , V3 0 2 1
  , V3 0 1 4
  , V3 5 4 1
  , V3 5 1 2
  , V3 5 2 3
  , V3 5 3 4
  ]

main :: IO ()
main = do
  print _test


--------------------------------------------------------------------------------
-- My solution
--------------------------------------------------------------------------------

_meshNormalise :: [V3 Int] -- ^ The Mesh face (3 indices form a face)
               -> [V3 Float] -- ^ The Mesh verts (each vertex has x,y,z)
               -> [V3 Float] -- ^ The smooth Normals at each vertex
_meshNormalise faces vs =
  unur $
  Array.alloc (P.length vs) (V3 0 0 0) $ \arr0 ->
    Array.toList $
    Array.map normalize $
      foldl' (\arr (Ur (V3 ia ib ic)) -> let
           e1 = ((vs P.!! ia) :: (V3 Float)) P.- (vs P.!! ib)
           e2 = (vs P.!! ic) P.- (vs P.!! ib)
           no = cross e1 e2 
        in arr & ia += no
               & ib += no
               & ic += no
        ) arr0 (P.map Ur faces)
  where

    (+=) :: Int -> V3 Float -> Array.Array (V3 Float) %1 -> Array.Array (V3 Float)
    (+=) i new arr0 = case Array.get i arr0 of
      (Ur exists, arr1) -> Array.set i (new P.+ exists) arr1
