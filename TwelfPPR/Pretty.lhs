%----------------------------------------------------------------------------
%--
%-- Module      :  TwelfPPR.Pretty
%-- Copyright   :  (c) Troels Henriksen 2010
%-- License     :  BSD3-style (see LICENSE)
%--
%-----------------------------------------------------------------------------

\begin{ignore}
\begin{code}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
\end{code}
\end{ignore}

\chapter{|TwelfPPR.Pretty|}
\label{chap:twelfppr.pretty}

This module defines primitives for printing Twelf terms by themselves.

\begin{code}
module TwelfPPR.Pretty ( PrintConf(..)
                       , emptyPrintConf
                       , SymPrettifier
                       , Prettifier
                       , TypeVarPrinter
                       , PrintEnv(..)
                       , emptyPrintEnv
                       , MonadPrint(..)
                       , defPrettyTypeApp
                       , defPrettyConstApp
                       , defPrettyTypeVar
                       , defPrettyRuleSym
                       , pprTypeVar
                       , pprObject
                       , prettyVar
                       , prettyConst
                       , prettyName
                       , prettyProd
                       , prettyRules
                       , premiseWithEnv
                       , judgementWithEnv
                       , judgementNoEnv
                       , premiseWithContext )
    where

import Control.Monad.Reader

import Data.Char
import Data.List
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Maybe
import Data.Monoid

import Text.Regex

import TwelfPPR.InfGen
import TwelfPPR.GrammarGen
import TwelfPPR.LF
import TwelfPPR.Util
\end{code}

\section{Type variables}

\begin{code}
varMap :: MonadPrint m => S.Set (TypeRef, Type) ->
          m (M.Map Type (M.Map TypeRef String))
varMap s = liftM M.fromList (mapM procVars $ M.toList table)
    where table = foldl f M.empty $ S.toList s
          f m (tr, t) = M.insertWith (++) t [tr] m

splitVar :: TypeRef -> (String, Maybe Integer)
splitVar (TypeRef tn) =
  case matchRegex r tn of
    Just [name, i] -> (name, Just $ read i)
    _              -> (tn, Nothing)
    where r = mkRegex "([^0-9]+)([0-9]+)"

procVars :: MonadPrint m =>
            (Type, [TypeRef])
         -> m (Type, M.Map TypeRef String)
procVars (t@(TyKind kr), trs) = do
  tm <- mapM proc $ uniqify trs []
  return (t, M.fromList tm)
    where proc (tr, tr') = do
            pta <- asksPrintConf prettyTypeVar 
            s <- pta tr' kr
            return (tr, s)
procVars (t, trs) = do
  return (t, M.fromList $ map proc trs)
      where proc tr@(TypeRef tn) = (tr, prettyVar tn)

uniqify :: [TypeRef]
        -> [((TypeRef, TypeRef), Maybe Integer)]
        -> [(TypeRef, TypeRef)]
uniqify [] seen = map fst seen
uniqify (tr:trs) seen =
  uniqify trs (((tr, tr'), idx'):seen)
    where (name, idx) = splitVar tr
          tr' = TypeRef (name ++ maybe "" show idx')
          idx' | elem idx (map snd seen) =
                   Just (1 + maximum (0:catMaybes (map snd seen)))
               | otherwise = idx

cfgVarMap :: MonadPrint m => S.Set (TypeRef, Type) -> m ()
cfgVarMap s = do
  vm <- varMap s
  modifyPrintEnv $ \e -> e { type_vars = vm }
\end{code}

\section{Generalities}

\begin{code}
type SymPrettifier m =
    Signature -> (TypeRef, RuleSymbol) -> m String
type Prettifier o m = o -> [Object] -> m String
\end{code}

\begin{code}
prettyConst :: String -> String
prettyConst s = "\\textrm{" ++ texescape s ++ "}"

prettyVar :: String -> String
prettyVar s = case matchRegex r s of
                Just [name, i] -> texescape name ++ "_{" ++ i ++ "}"
                _ -> texescape s
    where r = mkRegex "([^0-9]+)([0-9]+)"
\end{code}

\begin{code}
defPrettyTypeApp :: MonadPrint m => Prettifier KindRef m
defPrettyTypeApp (KindRef kn) [] = return $ prettyConst kn
defPrettyTypeApp (KindRef kn) os = do
  args <- mapM pprObject os
  return $ prettyConst kn ++ "(" ++ intercalate ", " args ++ ")"

defPrettyConstApp :: MonadPrint m => Prettifier TypeRef m
defPrettyConstApp (TypeRef tn) [] = return $ prettyConst tn
defPrettyConstApp (TypeRef tn) os = do
  args <- mapM pprObject os
  return $ prettyConst tn ++ "(" ++ intercalate ", " args  ++ ")"

type TypeVarPrinter m = TypeRef -> KindRef -> m String

defPrettyTypeVar :: MonadPrint m => TypeVarPrinter m
defPrettyTypeVar (TypeRef tn) _ = return $ prettyVar tn
\end{code}

\begin{code}
pprObject :: MonadPrint m => Object -> m String
pprObject (Const tr) =
  pprConstApp tr []
pprObject (Var tr (TyKind kr)) =
  pprTypeVar tr kr
pprObject (Var (TypeRef tn) _) =
  return $ prettyVar tn
pprObject (Lambda (TypeRef tn) _ o) = do
  body <- pprObject o
  return $ prettyVar tn ++ "." ++ body
pprObject (App o1 o2) = descend o1 [o2]
  where descend (Var (TypeRef tn) _) os = do
          args <- mapM pprObject os
          return $ prettyVar tn ++ "[" ++ intercalate "][" args ++ "]"
        descend (Const tr) os = pprConstApp tr os
        descend (App o1' o2') os = descend o1' $ o2' : os
        descend o os = do
          args <- mapM pprObject os
          o' <- pprObject o
          return $ o' ++ "\\ " ++ intercalate "\\ " args
\end{code}

\section{Rendering inference rules}

\begin{code}
type JudgementPrinter m =
    (KindRef -> S.Set (KindRef, [Object]))
        -> JudgementEnv -> Conclusion -> m String

judgementWithEnv :: MonadPrint m => JudgementPrinter m
judgementWithEnv kenv (_, vs) (kr, os) = do
  liftM2 (++) env (pprTypeApp kr os)
      where env | kenv kr /= S.empty  = do
                    vars' <- liftM (concatMap $ \s -> "\\{" ++ s ++ "\\}")
                             (mapM (uncurry pprTypeApp) vs)
                    return ("\\Gamma " ++ vars' ++ "\\vdash")
                | otherwise = return ""

judgementNoEnv :: MonadPrint m => JudgementPrinter m
judgementNoEnv _ _ = uncurry pprTypeApp
\end{code}

\begin{code}
prettyRules :: MonadPrint m => 
               (KindRef -> S.Set (KindRef, [Object]))
            -> InfRules -> m String
prettyRules kenv (InfRules kr@(KindRef name) rules) = do
  rules'   <- mapM ppr $ M.toList rules
  envrules <- mapM pprvar $ S.toList $ kenv kr
  return $ "[" ++ name ++ "]\n" ++ concatMap (++"\n") (rules' ++ envrules)
    where ppr (TypeRef tn, ir@(InfRule ps con)) = do
            cfgVarMap $ infRuleTypeVars ir
            asRule tn $ do
              pp   <- asksPrintConf premisePrinter
              ps'  <- mapM (pp kenv) $ reverse ps
              con' <- pprJudgement kenv (S.empty, []) con
              return ("\\nfrac{\n" ++ intercalate "\n\\quad\n" ps' ++
                      "}{\n" ++ con' ++ "\n}")
          pprvar x@(KindRef kn, os) = do
            cfgVarMap $ mconcat $ map objTypeVars os
            asRule rulename $
              pprJudgement kenv (S.empty, [x]) x
                where rulename = ("Var-" ++ name ++ kn)

asRule :: Monad m => String -> m String -> m String
asRule label body = do
  body' <- body
  return ("\\begin{displaymath}\n" ++ body' ++
          "\\quad" ++ ruleLabel label ++ 
          "\n\\end{displaymath}\n")

type PremisePrinter m =
    (KindRef -> S.Set (KindRef, [Object]))
    -> Judgement -> m String

premiseWithEnv :: MonadPrint m => PremisePrinter m
premiseWithEnv kenv ((vs, ps), kr, os) =
  pprJudgement kenv (vs, ps) (kr, os)

premiseWithContext :: MonadPrint m => PremisePrinter m
premiseWithContext kenv ((_, []), kr, os) = 
  pprJudgement kenv (S.empty, []) (kr, os)
premiseWithContext kenv ((_, ps), kr, os) = do
  con <- pprJudgement kenv (S.empty, []) (kr, os)
  ps'  <- liftM concat $ mapM proc ps
  return $ "{{" ++ ps' ++ "}\\atop" ++ "{\n" ++ con ++ "\n}}"
      where proc p = do p' <- pprJudgement kenv (S.empty, []) p
                        return ("{\\nfrac{}{" ++ p' ++
                                   "}\\atop{\\vdots}}")
\end{code}

\begin{code}
ruleLabel :: String -> String
ruleLabel tn = "\\textsc{" ++ (texescape . capitalise  . pretty) tn ++ "}"
    where pretty ('_':c:s) = '-' : c : pretty s
          pretty (c:s)     = c : pretty s
          pretty []        = []
\end{code}

\section{Monad}

\begin{code}
data PrintConf m = PrintConf
  { prettyTypeApp   :: Prettifier KindRef m
  , prettyConstApp  :: Prettifier TypeRef m
  , prettyTypeVar   :: TypeVarPrinter m
  , prettyRuleSym   :: SymPrettifier m
  , prettyJudgement :: JudgementPrinter m
  , premisePrinter  :: PremisePrinter m
  }

emptyPrintConf :: MonadPrint m => PrintConf m
emptyPrintConf = PrintConf 
  { prettyTypeApp   = defPrettyTypeApp
  , prettyConstApp  = defPrettyConstApp
  , prettyTypeVar   = defPrettyTypeVar
  , prettyRuleSym   = defPrettyRuleSym
  , prettyJudgement = judgementWithEnv
  , premisePrinter  = premiseWithEnv 
  }

pprJudgement :: MonadPrint m => JudgementPrinter m
pprJudgement kenv x y = do
  pj <- asksPrintConf prettyJudgement
  pj kenv x y

pprTypeApp :: MonadPrint m => Prettifier KindRef m
pprTypeApp kr os = do
  pka <- asksPrintConf prettyTypeApp
  pka kr os

pprConstApp :: MonadPrint m => Prettifier TypeRef m
pprConstApp tr os = do
  pta <- asksPrintConf prettyConstApp
  pta tr os
\end{code}

\begin{code}
type NameContext = M.Map KindRef (M.Map FreeVarContext TypeRef)

data PrintEnv = PrintEnv 
    { name_context :: NameContext
    , type_vars :: M.Map Type (M.Map TypeRef String)
    }

emptyPrintEnv :: PrintEnv
emptyPrintEnv = PrintEnv { name_context = M.empty
                         , type_vars    = M.empty }

pprTypeVar :: MonadPrint m => TypeVarPrinter m
pprTypeVar tr kr = do
  tv <- getsPrintEnv type_vars
  maybe (error $ "Internal error" ++ show tr ++ show kr ++ show tv) return $ do
    M.lookup tr =<< M.lookup (TyKind kr) tv
\end{code}

\begin{code}
class Monad m => MonadPrint m where
    getPrintEnv :: m PrintEnv
    putPrintEnv :: PrintEnv -> m ()

    getsPrintEnv :: (PrintEnv -> a) -> m a
    getsPrintEnv f = getPrintEnv >>= \s -> return (f s)

    modifyPrintEnv :: (PrintEnv -> PrintEnv) -> m ()
    modifyPrintEnv f = getPrintEnv >>= \s ->
                            putPrintEnv (f s)

    askPrintConf  :: m (PrintConf m)
    asksPrintConf :: (PrintConf m -> a) -> m a
\end{code}

\section{Rendering production rules}

\begin{code}
prettyName :: String -> String
prettyName s = "\\textrm{" ++ s' ++ "}"
    where s' = texescape $ capitalise s
\end{code}

\begin{code}
prettyProd :: MonadPrint m => Signature
           -> KindUsage
           -> ProdRule
           -> m String
prettyProd sig ku@(kr, _) prod@(ts, vars) = do
  cfgVarMap =<< prodRuleTypeVars sig ku prod
  tr   <- namer sig ku
  name <- pprTypeVar tr kr
  terms <- mapM (prettySymbol sig) $ M.toList ts
  let terms' = if vars 
               then ("\\$"++prettyName name) : terms
               else terms
  return ("\\begin{tabular}{rl}\n$" ++
          texescape name ++ "$ ::=& $" ++ 
          intercalate "$\\\\ \n $\\mid$ & $" terms' ++ "$\n" ++
          "\\end{tabular}\n")
\end{code}

\begin{code}
prettySymbol :: MonadPrint m => Signature 
             -> (TypeRef, RuleSymbol)
             -> m String
prettySymbol sig (tr, ts) = do
  prs <- asksPrintConf prettyRuleSym
  prs sig (tr, ts)

defPrettyRuleSym :: MonadPrint m => SymPrettifier m
defPrettyRuleSym _ (TypeRef tn, []) =
  return $ prettyName tn
defPrettyRuleSym sig (TypeRef tn, ts) = do
  args <- liftM (intercalate ", ") $ mapM prettyPremise ts
  return $ prettyName tn ++ "(" ++ args ++ ")"
      where prettyPremise ([], ku@(kr, _)) = do
              tr <- namer sig ku
              pprTypeVar tr kr
            prettyPremise (KindRef kn:tms, ka) = do
              more <- prettyPremise (tms, ka)
              return (("\\$" ++ prettyName kn ++ ".") ++ more)
\end{code}

\begin{code}
namer :: MonadPrint m => Signature -> KindUsage -> m TypeRef
namer sig (kr@(KindRef kn), vs) = do
  context <- getsPrintEnv name_context
  case M.lookup kr context of
    Just m  -> case M.lookup vs m of
                 Just n -> return n
                 Nothing -> do
                   let new = newName m
                   modifyPrintEnv $ \s ->
                     s { name_context =
                         M.insert kr (M.insert vs new m) context }
                   return new
    Nothing -> do
      let new = newName M.empty
      modifyPrintEnv $ \s ->
          s { name_context =
              M.insert kr (M.singleton vs new) context }
      return new
    where newName existing
             | vs == c = TypeRef kn
             | otherwise = TypeRef $ kn ++ replicate n '\''
             where n = 1 + M.size (M.filterWithKey (\k _ -> k/=c) existing)
          c  = initContext kr fd
          fd = fromJust $ M.lookup kr sig
\end{code}


\begin{code}
prodRuleTypeVars :: MonadPrint m => Signature
                 -> KindUsage
                 -> ProdRule 
                 -> m (S.Set (TypeRef, Type))
prodRuleTypeVars sig ku@(kr, _) (syms, _) = do
  s <- liftM (mconcat . concat) (mapM symvars $ M.toList syms)
  tr <- namer sig ku
  return $ S.insert (tr, TyKind kr) s
    where symvars (_, ps) = do
            liftM mconcat (mapM premvars ps)
          premvars (krs, ku'@(kr', _)) = do
            tr <- namer sig ku'
            let s = S.singleton (tr, TyKind kr')
            liftM (s:) (mapM f krs)
          f kr' = do
            tr <- namer sig (kr', c)
            return $ S.singleton (tr, TyKind kr')
                where c = initContext kr' $
                          fromJust $ M.lookup kr' sig
\end{code}
