{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
module AST where

import GHC.Types (Symbol)

type Var = String
data Typ = Int
         | Fun Typ Typ

data Expr p = Lit (XLit p) Integer
            | Var (XVar p) Var
            | Ann (XAnn p) (Expr p) Typ
            | Abs (XAbs p) Var (Expr p)
            | App (XApp p) (Expr p) (Expr p)
            | XExpr !(XXExpr p) -- Constructor extension point

type family XLit p
type family XVar p
type family XAnn p
type family XAbs p
type family XApp p
type family XXExpr p

class TTG p (s :: Symbol) t where
    override :: t -> t

printT :: Typ -> String
printT = \case
    Int -> "Int"
    Fun a b -> "(" <> printT a <> ") -> (" <> printT b <> ")"

printE :: Expr p -> String
printE = \case
    Lit _ i -> show i
    Var _ s -> s
    Ann _ e t -> "(" <> printE e <> ") :: (" <> printT t <> ")"
    Abs _ v e -> "λ" <> v <> "." <> printE e
    App _ f v -> "(" <> printE f <> ") (" <> printE v <> ")"
    XExpr _ -> ""

instance TTG p "show" (Expr p -> String) => Show (Expr p) where
    show = override @p @"show" printE

class Pretty p where
    ppr :: p -> String

instance TTG p "ppr" (Expr p -> String) => Pretty (Expr p) where
    ppr = override @p @"ppr" printE

