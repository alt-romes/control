{-# LANGUAGE TypeFamilies #-}
module Undecorated where

import Data.Void

import AST

data UD

type instance XLit   UD = ()
type instance XVar   UD = ()
type instance XAnn   UD = ()
type instance XAbs   UD = ()
type instance XApp   UD = ()
type instance XXExpr UD = Void

printUndecorated = printExpr

