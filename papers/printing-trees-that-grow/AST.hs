{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
module AST where

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

printExpr :: Expr p -> String
printExpr = \case
    Lit _ i -> 
