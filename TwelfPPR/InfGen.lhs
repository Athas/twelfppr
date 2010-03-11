%----------------------------------------------------------------------------
%--
%-- Module      :  TwelfPPR.InfGen
%-- Copyright   :  (c) Troels Henriksen 2009
%-- License     :  BSD3-style (see LICENSE)
%--
%-----------------------------------------------------------------------------

\chapter{|TwelfPPR.InfGen|}

In Twelf, we represent judgements as types, with a given type
corresponding to an inference rule in traditional notation.  This
module implements the transformation of a subset of Twelf types to a
simple abstract form of inference rules.

\begin{code}
module TwelfPPR.InfGen ( InfRules(..)
                       , InfRule(..)
                       , Judgement
                       , JudgementEnv
                       , Conclusion
                       , pprAsInfRules
                       , judgeEnv
                       , infRuleTypeVars
                       , infRuleMetaVars ) 
    where

import Control.Arrow

import Data.List
import Data.Monoid
import qualified Data.Set as S

import TwelfPPR.LF
\end{code}

We define an inference rule to consist of a set of \textit{premises},
with each premise corresponding to an LF type of kind \texttt{*} (that
is, no arrows), and a single \textit{conclusion}, also corresponding
to an LF type.  Note that this simple model does not include the
concept of an ``environment'' in which judgements are made, putting a
heavy restriction on the kinds of LF types we can represent as
inference rules.

A type family maps to a single \textit{judgement definition}, which
maps names of types in the family to inference rules.  An inference
rule consists of a potentially empty set of premises (actually a list,
as we wish to preserve the order in which the programmer originally
specified the premises in the Twelf code) and a conclusion, both of
which are simply the name of some kind applied to a potentially empty
sequence of objects.  The kind in the conclusion will always be the
same kind as the judgement definition describes, as that would be the
original criteria for inclusion.

\begin{code}
data InfRules = InfRules KindRef Kind [(TypeRef, InfRule)]
data InfRule = InfRule [Judgement] Conclusion
type Judgement = (JudgementEnv, KindRef, [Object])
type JudgementEnv = (S.Set (TypeRef, Type), [(KindRef, [Object])])
type Conclusion = (KindRef, [Object])
\end{code}

Given the name of a kind and its definition, we can produce the above
abstract representation of a judgement by mapping each type in
the kind to its corresponding inference rule.

\begin{code}
pprAsInfRules :: (KindRef, KindDef) -> InfRules
pprAsInfRules (kr, KindDef k ms) = 
  InfRules kr k $ map (second pprAsRule) ms
\end{code}

\begin{code}
judgeEnv :: InfRules -> S.Set KindRef
judgeEnv (InfRules _ _ m) = S.fromList $ concatMap (ruleEnv . snd) m
    where ruleEnv (InfRule ps _) = concatMap judgEnv ps
          judgEnv ((_, ce), _, _) = map fst ce
\end{code}

\begin{code}
pprAsRule :: Type -> InfRule
pprAsRule (TyCon mtr t1 t2)
    | maybe True (not . flip freeInType t2) mtr =
        InfRule (pprAsJudgement t1 : ps) c
    | otherwise = pprAsRule t2
    where InfRule ps c = pprAsRule t2
pprAsRule t = InfRule [] $ pprAsConclusion t
\end{code}

\begin{code}
pprAsConclusion :: Type -> Conclusion
pprAsConclusion t = ppr t []
    where ppr (TyKind kr) os = (kr, os)
          ppr (TyApp t' o) os = ppr t' (o:os)
          ppr _ _ = error "Type constructor found unexpectedly in term"
\end{code}

\begin{code}
pprAsJudgement :: Type -> Judgement
pprAsJudgement t = ppr t S.empty []
    where ppr (TyCon Nothing t1 t2) es ps = ppr t2 es (ppr' t1 []:ps)
          ppr (TyCon (Just tr) ty t2) es ps =
            ppr t2' ((tr', ty) `S.insert` es) ps
                where (tr', t2') = fixShadowing ps (tr, t2)
          ppr t1 es ps = ((es, reverse ps), kr, os)
              where (kr, os) = ppr' t1 []
          ppr' (TyKind kr) os = (kr, os)
          ppr' (TyApp t1 o) os = ppr' t1 (o:os)
          ppr' _ _ = error "Type constructor found unexpectedly in term"
\end{code}

Removal of shadowing can be accomplished by renaming the bound
variable, thus turning the problem into a search for a name that is
not free in any of the premises (we refer to such a name as
\textit{available}).  This can be done by simply appending apostrophes
to the name --- this process is guaranteed to terminate, as there is a
finite amount of premises.

\begin{code}
fixShadowing :: [(KindRef, [Object])] 
             -> (TypeRef, Type)
             -> (TypeRef, Type)
fixShadowing ps (tr, t)
    | available tr = (tr, t)
    | otherwise    = (tr', renameType tr tr' t)
    where available tr'' = all (not . any (freeInObj tr'') . snd) ps
          trs  = tr : [ TypeRef (tn ++ "'") | TypeRef tn <- trs ]
          tr' = head $ filter available trs
\end{code}

\section{Inspecting inference rules}

We will eventually need to know the set of type variables mentioned
by a given inference rule.

\begin{code}
infRuleTypeVars :: InfRule -> S.Set (TypeRef, Type)
infRuleTypeVars (InfRule js (_, os)) =
  foldl S.union (ovars os) $ map jvars js
    where ovars = mconcat . map objFreeVars
          jvars (je, _, os') = jevars je `S.union` ovars os'
          jevars (vars, aps) =
            (mconcat $ map (ovars . snd) aps) `S.difference` vars

infRuleMetaVars :: InfRule -> S.Set (TypeRef, Type)
infRuleMetaVars (InfRule js (_, os)) =
  foldl S.union (ovars os) $ map jvars js
    where ovars = mconcat . map objBoundVars
          jvars (je, _, os') = jevars je `S.union` ovars os'
          jevars (vars, aps) =
            (mconcat $ map (ovars . snd) aps) `S.union` vars
\end{code}
