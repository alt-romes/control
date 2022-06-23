{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
module Extend where

import Data.Void

import AST

data UD

type instance XLit   UD = ()
type instance XVar   UD = ()
type instance XAnn   UD = ()
type instance XAbs   UD = ()
type instance XApp   UD = ()
type instance XXExpr UD = Void

instance TTG UD "show" (Expr p -> String) where
    override = id

printUndecorated :: Expr UD -> String
printUndecorated = printE

data Decorated

type instance XLit   Decorated = String
type instance XVar   Decorated = Maybe String
type instance XAnn   Decorated = String
type instance XAbs   Decorated = ()
type instance XApp   Decorated = ()
type instance XXExpr Decorated = Typ

instance TTG Decorated "show" (Expr Decorated -> String) where
    override def = \case
        Lit s i -> s <> show i
        Var Nothing _ -> "impossible var"
        Var (Just x) y -> x <> y
        Ann an e t -> an <> "(" <> printE e <> ") :: (" <> printT t <> ")"
        x -> def x

instance TTG Decorated "ppr" (Expr Decorated -> String) where
    override def = \case
        Lit s i -> s <> show i
        Var Nothing _ -> "impossible var"
        Var (Just x) y -> x <> y
        Ann an e t -> an <> "(" <> printE e <> ") :: (" <> printT t <> ")"
        x -> def x

