%----------------------------------------------------------------------------
%--
%-- Module      :  LF
%-- Copyright   :  (c) Troels Henriksen 2009
%-- License     :  BSD3-style (see LICENSE)
%--
%-- Maintainer  :  athas@sigkill.dk
%-- Stability   :  unstable
%-- Portability :  not portable, uses mtl, posix
%--
%-- A tool for prettyprinting Twelf signatures.
%--
%-----------------------------------------------------------------------------

\chapter{LF representation}
\label{chap:lf representation}

This chapter implements the data types and ancillary functions for
representing LF in Haskell.

\begin{code}
module TwelfPPR.LF ( KindRef(..)
                   , TypeRef(..)
                   , Type(..)
                   , conclusion
                   , premises
                   , Object(..)
                   , KindDef(..)
                   , Signature
                   , freeInType
                   , freeInObj
                   , renameType
                   , renameObj
                   , referencedKinds )
    where
import Data.Maybe
import qualified Data.Map as M
import qualified Data.Set as S
\end{code}

The full LF type theory is defined by the following grammar.
\\
\begin{tabular}{lrcl}
Kinds & $K$ & ::= & $\text{type} \mid \Pi x:A.K$ \\
Families & $A$ & ::= & $a \mid A\ M \mid \Pi x:A_1.A_2$ \\
Objects & $M$ & ::= & $c \mid x \mid \lambda x:A. M \mid M_1\ M_2$ \\
Signatures & $\Sigma$ & ::= & $\cdot \mid \Sigma, a:K \mid \Sigma,
c:A$ \\
Contexts & $\Gamma$ & ::= & $\cdot \mid \Gamma, x:A$
\end{tabular}
\\

We ignore contexts, they do not matter for our purposes.  A $c$ is the
name of a type constant, and an $x$ is the name of a type variable.
An $a$ is the name of a kind.  This leads us to the following
definition of types.  We define disjunct types for naming kinds and
types for increased type safety.

\begin{code}
newtype KindRef = KindRef String
    deriving (Show, Eq, Ord)
newtype TypeRef = TypeRef String
    deriving (Show, Eq, Ord)

data Type = TyCon (Maybe TypeRef) Type Type
          | TyApp Type Object
          | TyKind KindRef
            deriving (Show, Eq)
\end{code}

A type $\Pi x_1 : A_1. \Pi x_2 : A_2.\ldots \Pi x_{n-1} : A_{n-1}.A_n$
is said to have the \textit{premises} $A_1, A_2 \ldots A_{n-1}$ and
the \textit{conclusion} $A_n$.  This is a bit of a stretch, as this
terminology is usually reserved for cases when $x_i$ is not free in
the enclosed term, but useful none the less.

\begin{code}
conclusion :: Type -> Type
conclusion (TyCon _ _ t2) = conclusion t2
conclusion t              = t

premises :: Type -> [Type]
premises (TyCon _ t1 t2) = t1 : premises t2
premises _               = []
\end{code}

LF |Object|s should always be in $\beta$ normal form, though that
restriction is not enforced by this definition.  We distinguish
between referencing types that are part of some top-level constant
definition in the signature (the |Const| constructor) and those that
are type variables in the enclosing term (|Var|).

\begin{code}
data Object = Const TypeRef
            | Var TypeRef
            | Lambda TypeRef Object
            | App Object Object
              deriving (Show, Eq)
\end{code}

A kind definition maps type names to the actual types (or
specifically, type families) themselves.

\begin{code}
data KindDef = KindDef (M.Map TypeRef Type)
                   deriving (Show, Eq)
\end{code}

A Twelf signature is a map of names of kind names to kind definitions.

\begin{code}
type Signature = M.Map KindRef KindDef
\end{code}

\section{Operations on LF terms}

We will eventually need to extract various interesting nuggets of
information about LF definitions.  In particular, whether a given
variable is free in a type or object will be of interest to many
transformations.

\begin{code}
freeInType :: TypeRef -> Type -> Bool
freeInType tr (TyCon (Just tr') t1 t2)
    | tr == tr' = True
    | otherwise = freeInType tr t1 || freeInType tr t2
freeInType tr (TyApp t o) = freeInType tr t || freeInObj tr o
freeInType _ _ = False

freeInObj :: TypeRef -> Object -> Bool
freeInObj tr (Const tr') = tr == tr'
freeInObj tr (Var tr') = tr == tr'
freeInObj tr (Lambda tr' o)
    | tr == tr' = False
    | otherwise = freeInObj tr o
freeInObj tr (App o1 o2) = freeInObj tr o1 || freeInObj tr o2
\end{code}

The meaning of an LF term is independent of how its type variables are
named (that is, $\alpha$-conversion is permitted).  Therefore, we can
define functions that rename variables.

\begin{code}
renameType :: TypeRef -> TypeRef -> Type -> Type
renameType from to = r
    where r (TyCon Nothing t1 t2) = 
            TyCon Nothing (r t1) (r t2)
          r (TyCon (Just tr) t1 t2)
            | tr == from = TyCon (Just tr) t1 t2
            | otherwise  = TyCon (Just tr) (r t1) (r t2)
          r (TyApp t o) = TyApp (r t) (renameObj from to o)
          r t = t 

renameObj :: TypeRef -> TypeRef -> Object -> Object
renameObj from to = r
    where r (Const tr) = Const (var tr)
          r (Var tr)   = Var (var tr)
          r (Lambda tr o)
              | tr == from = Lambda tr o
              | otherwise  = Lambda tr (r o)
          r (App o1 o2) = App (r o1) (r o2)
          var tr | tr == from = to
                 | otherwise  = tr
\end{code}

To determine which kinds are applied in some type $t$ we
can trivially walk through the tree.

\begin{code}
refsInType :: Type -> S.Set KindRef
refsInType (TyCon _ t1 t2) = refsInType t1 `S.union` refsInType t2
refsInType (TyApp t _)     = refsInType t
refsInType (TyKind k)      = S.singleton k
\end{code}

The kind applications of some type family definition is the union of
all kind applications in the member types.

\begin{code}
refsInTyFam :: KindDef -> S.Set KindRef
refsInTyFam (KindDef fam) = 
  foldl S.union S.empty $ map refsInType $ M.elems fam
\end{code}

The above definitions only catch immediate references, which will not
be adequate for our purposes.  Thus, we also need to recursively
inspect the referenced kinds.

\begin{code}
referencedKinds :: Signature -> KindRef -> S.Set KindRef
referencedKinds sig = referencedKinds' S.empty
    where referencedKinds' visited fr
              | fr `S.member` visited = S.empty
              | otherwise = foldl S.union (S.singleton fr) refs'
              where refs' = map (referencedKinds' visited') refs
                    refs  = S.toList $ refsInTyFam $ fromJust $ M.lookup fr sig
                    visited' = S.insert fr visited
\end{code}
