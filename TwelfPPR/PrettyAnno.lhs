%----------------------------------------------------------------------------
%--
%-- Module      :  TwelfPPR.PrettyAnno
%-- Copyright   :  (c) Troels Henriksen 2010
%-- License     :  BSD3-style (see LICENSE)
%--
%-----------------------------------------------------------------------------

\chapter{|TwelfPPR.PrettyAnno|}

Plainly prettyprinted Twelf signatures are not very visually
interesting, and the usage of only basic application syntax can make
them hard to read.  Hence, we provide the user with the ability to
define how applications of given types and kinds (herein referred to
as \textit{operators} should be represented visually in the \TeX
output.  For example, instead of a rather boring \texttt{eval(E, V)}
we might desire $E \rightarrow V$.

\begin{code}
module TwelfPPR.PrettyAnno ( PrettyAnno(..)
                           , prettifiers
                           , macroargs
                           , parseAnnotations
                           , prettyAnno)
    where

import Control.Applicative
import Control.Monad
import Data.Char
import Data.Maybe
import Data.List

import qualified Data.Map as M

import Text.Parsec hiding ((<|>), many, optional)
import Text.Parsec.String

import TwelfPPR.LF
import TwelfPPR.Parser
import TwelfPPR.Pretty
\end{code}

The information we need is very basic: a kind or type name, and the
\TeX command that should be used whenever an application of the
operator is encountered.

\begin{code}
data PrettyAnno = KindAppAnno KindRef String
                | TypeAppAnno TypeRef String
\end{code}

Given a list of |PrettyAnno|s (which describes both kinds and types),
we can produce a triple of functions: two for printing normal kind and
type applications and another for printing type applications in a
production rule context.  The logic is the same for the two former
cases, in that we look up in a map and fall back to a default printer
if the operator is not found, but we must maintain two different
functions to keep the name spaces separate.  The latter function is
slightly more complicated, and will be described further below.

\begin{code}
prettifiers :: MonadPrint m => [PrettyAnno] 
            -> (Prettifier KindRef m,
                Prettifier TypeRef m,
                SymPrettifier m)
prettifiers descs = ( f defPrettyKindApp kindapps
                    , f defPrettyTypeApp tyapps
                    , prettifyRuleSym tyapps)
    where kindapps = M.fromList $ catMaybes $ map kindapp descs
          kindapp (KindAppAnno kr s) = Just (kr, s)
          kindapp _                  = Nothing
          tyapps = M.fromList $ catMaybes $ map tyapp descs
          tyapp (TypeAppAnno kr s) = Just (kr, s)
          tyapp _                  = Nothing
          f def dm r os = case M.lookup r dm of
                            Just s -> liftM (s++) (macroargs os)
                            Nothing -> def r os
\end{code}

Associating operators with \TeX commands is all well and good, but we
need to pass the operands to the command so they can be properly
integrated.  For example, one might use the following \TeX command for
defining how to print types of kind \texttt{eval}:

\begin{verbatim}
\newcommand{\LFKEval}[2]{#1 \rightarrow #2}
\end{verbatim}

In the case of a type like \texttt{eval E1 E2}, determining what the
arguments should be is obvious, but what about objects that bind local
variables, like \texttt{lam [x] E x}?  In LF terms, there is only a
single argument to \texttt{lam}, namely \texttt{[x] E x}, but we would
like to be able to write \TeX commands, such as the following, that
receive the bound variable and body in different parameters.

\begin{verbatim}
\newcommand{\LFTLam}[2]{\lambda #1.#2}
\end{verbatim}

Therefore we \textit{split} variable-binding arguments (that is,
$\lambda$-abstraction) into separate arguments to the \TeX command:
their formal parameter, and whatever \TeX command arguments result
from their body.

\begin{code}
macroargs :: MonadPrint m => [Object] -> m String
macroargs os = liftM concat $ (mapM arg $ realargs os)
    where arg o = do po <- prettyObject o
                     return $ "{" ++ po ++ "}"
          realargs = concatMap realarg
          realarg (Lambda tr o) = Var tr : realarg o
          realarg o             = [o]
\end{code}

\section{Annotations and production rules}

As outlined in \Fref{chap:twelfppr.pretty}, some kinds are visually
presented as production rules in a grammar.  A production rule is
essentially just a sequence of type applications, but using the type
application printer shown above will not yield satisfactory results,
so we have to define a different one.

\begin{code}
prettifyRuleSym :: MonadPrint m =>
                   M.Map TypeRef String -> SymPrettifier m
prettifyRuleSym dm sig (tr, rs) =
    case M.lookup tr dm of
      Nothing -> defPrettyRuleSym sig (tr, rs)
      Just s  -> liftM (s++) (liftM (concatMap wrap . concat) $
                              mapM prettyPremise rs)
        where wrap x = "{" ++ x ++ "}"
              prettyPremise ([], ((KindRef kn, _), [])) = do
                return [prettyName kn]
              prettyPremise ([], ((kr, _), os)) = do
                pta  <- asksPrettyEnv prettyKindApp
                p    <- pta kr os
                return [p]
              prettyPremise (KindRef kn:tms, ka) = do
                more <- prettyPremise (tms, ka)
                return (("\\$" ++ prettyName kn) : more)
\end{code}

\section{Parsing printing annotations}

We define a simple textual format, and an parser, for printing
annotations.  Each annotation consists of three tokens: either the
string \texttt{kind} or \texttt{type}, followed by an operator name,
followed by the name of a \TeX command.  Annotations are separated by
whitespace (in a file, for example by line breaks).

\begin{code}
prettyAnno :: GenParser Char () PrettyAnno
prettyAnno = (    string "kind" *> f KindAppAnno KindRef
              <|> string "type" *> f TypeAppAnno TypeRef) <* spaces
    where f c sc = spaces *>
                   pure c <*> (pure sc <*> many1 idChar )
                          <*> (spaces *> many1 (satisfy $ not . isSpace))

parseAnnotations :: SourceName -> String -> Either ParseError [PrettyAnno]
parseAnnotations = parse (spaces *> many prettyAnno)
\end{code}
