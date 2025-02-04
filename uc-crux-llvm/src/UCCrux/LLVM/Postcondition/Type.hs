{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}

{-
Module       : UCCrux.LLVM.Postcondition.Type
Description  : Postconditions for LLVM functions
Copyright    : (c) Galois, Inc 2021
License      : BSD3
Maintainer   : Langston Barrett <langston@galois.com>
Stability    : provisional

A postcondition for a function summarizes its return value and its effect of a
function on LLVM memory. Of course, the most complete summary of a function is
semantically equivalent to its implementation. The postconditions in this module
are significantly less expressive than that. The aims are to support
postcondition inference, and to support partial (user- or programmer-supplied)
specifications of external functions.

There are two representations of postconditions: 'UPostcond' and 'Postcond'.
These are related by 'typecheckPostcond', which takes a 'UPostcond' and returns
a 'Postcond'. The idea is that 'UPostcond' is not statically known to correspond
to a given function type signature, whereas 'Postcond' specifically matches a
particular 'FuncSig'. 'Postcond' can be "applied" (see
"UCCrux.LLVM.Postcondition.Apply") to a given program state with less error
handling, since it carries additional type-safety information. Essentially, a
lot of partiality can be front-loaded into 'typecheckPostcond' so that later
operations don't have to handle impossible error cases.

'ClobberGlobal' and 'ClobberArg' can explicitly set a type of data to generate,
which may or may not actually match the declared type of the data in question.
This is useful for clobbering e.g. a @char*@ or @void*@ with structured data.
However, it yields some API and implementation complexity due to possible type
mismatches (see 'OpaquePointers').
-}

module UCCrux.LLVM.Postcondition.Type
  ( ClobberValue(..)
  , SomeClobberValue(..)
  , ppClobberValue
  , ClobberArg(..)
  , SomeClobberArg(..)
  , UPostcond(..)
  , uArgClobbers
  , uGlobalClobbers
  , uReturnValue
  , emptyUPostcond
  , minimalUPostcond
  , minimalPostcond
  , ppUPostcond
  , Postcond(..)
  , PostcondTypeError
  , ppPostcondTypeError
  , typecheckPostcond
  , ReturnValue(..)
  , toUPostcond
  )
where

import           Control.Lens (Lens', (^.))
import qualified Control.Lens as Lens
import           Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Type.Equality ((:~:)(Refl), testEquality)

import qualified Prettyprinter as PP

import           Data.Parameterized.Classes (IxedF'(ixF'))
import           Data.Parameterized.Context (Assignment)
import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.TraversableFC.WithIndex (ifoldrFC)

import           UCCrux.LLVM.Constraints (ConstrainedShape, ConstrainedTypedValue(ConstrainedTypedValue), minimalConstrainedShape, ppConstrainedShape)
import           UCCrux.LLVM.Cursor (Cursor, ppCursor)
import           UCCrux.LLVM.Errors.Panic (panic)
import           UCCrux.LLVM.FullType.CrucibleType (SameCrucibleType, sameCrucibleType, makeSameCrucibleType, testSameCrucibleType)
import           UCCrux.LLVM.FullType.FuncSig (FuncSig, FuncSigRepr, ReturnTypeRepr)
import qualified UCCrux.LLVM.FullType.FuncSig as FS
import           UCCrux.LLVM.FullType.PP (ppFullTypeRepr)
import           UCCrux.LLVM.FullType.Type (FullType(FTPtr), FullTypeRepr)
import           UCCrux.LLVM.FullType.VarArgs (VarArgsRepr)
import           UCCrux.LLVM.Module (GlobalSymbol, getGlobalSymbol)

-- | Specification of how a (part of a) value is clobbered, i.e., which parts to
-- write to and with what data.
--
-- Note that the freshly-generated value may be of a different type (@realTy@)
-- than the value being overwritten, see 'clobberValueCompat'.
data ClobberValue m (inTy :: FullType m) =
  forall realTy atTy.
  ClobberValue
  { -- | Location of pointer within container value
    clobberValueCursor :: Cursor m realTy ('FTPtr atTy),
    -- | Specification of value to write to the pointer
    clobberValue :: ConstrainedShape m atTy,
    -- | Type of the container value
    clobberValueType :: FullTypeRepr m realTy,
    clobberValueCompat :: SameCrucibleType realTy inTy
  }

data SomeClobberValue m = forall inTy. SomeClobberValue (ClobberValue m inTy)

ppClobberValue :: ClobberValue m inTy -> PP.Doc ann
ppClobberValue (ClobberValue cur val ty _proof) =
  PP.hsep
    [ ppCursor (show (ppConstrainedShape val)) cur
    , ":"
    , ppFullTypeRepr ty
    ]

-- | Specification of how a (part of a) pointer argument is clobbered, i.e.,
-- which parts to write to and with what data.
data ClobberArg m (inTy :: FullType m) where
  DontClobberArg :: ClobberArg m inTy
  DoClobberArg :: ClobberValue m inTy -> ClobberArg m inTy

data SomeClobberArg m = forall inTy. SomeClobberArg (ClobberArg m inTy)

-- | Untyped postcondition of an LLVM function.
--
-- The U stands for untyped, see 'Postcond'.
--
-- NOTE(lb): The explicit kind signature here is necessary for GHC 8.8
-- compatibility.
data UPostcond m = UPostcond
  { -- | Specifications of which pointer arguments are written to, and how
    _uArgClobbers :: IntMap (SomeClobberArg m),
    -- | Specifications of which global variables are written to, and how
    _uGlobalClobbers :: Map (GlobalSymbol m) (SomeClobberValue m),
    -- | Specification of the return value
    _uReturnValue :: Maybe (ConstrainedTypedValue m)
  }

uArgClobbers :: Lens' (UPostcond m) (IntMap (SomeClobberArg m))
uArgClobbers = Lens.lens _uArgClobbers (\s v -> s { _uArgClobbers = v })

uGlobalClobbers :: Lens' (UPostcond m) (Map (GlobalSymbol m) (SomeClobberValue m))
uGlobalClobbers = Lens.lens _uGlobalClobbers (\s v -> s { _uGlobalClobbers = v })

uReturnValue :: Lens' (UPostcond m) (Maybe (ConstrainedTypedValue m))
uReturnValue = Lens.lens _uReturnValue (\s v -> s { _uReturnValue = v })

-- | A postcondition which imposes no constraints and has a no return value (is
-- void).
emptyUPostcond :: UPostcond m
emptyUPostcond =
  UPostcond
    { _uArgClobbers = IntMap.empty,
      _uGlobalClobbers = Map.empty,
      _uReturnValue = Nothing
    }

-- | A postcondition which imposes no constraints and has some
-- minimally-constrained return value.
minimalUPostcond :: ReturnTypeRepr m ft -> UPostcond m
minimalUPostcond retRepr =
  UPostcond
    { _uArgClobbers = IntMap.empty,
      _uGlobalClobbers = Map.empty,
      _uReturnValue =
        case retRepr of
          FS.VoidRepr -> Nothing
          FS.NonVoidRepr ft ->
            Just (ConstrainedTypedValue ft (minimalConstrainedShape ft))
    }

ppUPostcond :: UPostcond m -> PP.Doc ann
ppUPostcond post =
  PP.vsep $ bullets
    [ "Return value:" PP.<+>
        case _uReturnValue post of
          Just (ConstrainedTypedValue _type shape) -> ppConstrainedShape shape
          Nothing -> "<void>"
    , header
        "Argument clobbers:"
        (map (uncurry ppArg) (IntMap.toList (_uArgClobbers post)))
    , header
        "Global clobbers:"
        (map (uncurry ppGlob) (Map.toList (_uGlobalClobbers post)))
    ]
  where
    bullets = map ("-" PP.<+>)
    header hd items = PP.nest 2 (PP.vsep (hd : bullets items))

    ppArg i (SomeClobberArg ca) =
      (PP.viaShow i <> ":") PP.<+>
        case ca of
          DontClobberArg -> "no clobbering"
          DoClobberArg cv -> ppClobberValue cv

    ppGlob gSymb (SomeClobberValue cv) =
      (PP.viaShow (getGlobalSymbol gSymb) <> ":") PP.<+> ppClobberValue cv

data ReturnValue m (mft :: Maybe (FullType m)) f where
  ReturnVoid :: ReturnValue m 'Nothing f
  ReturnValue :: f ft -> ReturnValue m ('Just ft) f

-- | A more strongly typed version of 'UPostcond'.
data Postcond m (fs :: FuncSig m) where
  Postcond ::
    { pVarArgs :: VarArgsRepr va,
      -- | Specifications of which pointer arguments are written to, and how
      pArgClobbers :: Assignment (ClobberArg m) argTypes,
      -- | Specifications of which global variables are written to, and how
      pGlobalClobbers :: Map (GlobalSymbol m) (SomeClobberValue m),
      -- | Specification of the return value
      pReturnValue :: ReturnValue m mft (ConstrainedShape m)
    } ->
    Postcond m ('FS.FuncSig va mft argTypes)

-- | A postcondition which imposes no constraints and has some
-- minimally-constrained return value.
minimalPostcond ::
  (fs ~ 'FS.FuncSig va mft args) =>
  FuncSigRepr m fs ->
  Postcond m fs
minimalPostcond fsRepr@(FS.FuncSigRepr _ _ retRepr) =
  case typecheckPostcond (minimalUPostcond retRepr) fsRepr of
    Left err ->
      panic
        "minimalPostcond"
        [ "Impossible: type mismatch on fresh postcond!"
        , show (ppPostcondTypeError err)
        ]
    Right val -> val

data RetMismatch
  = BadRetType
  | FunctionWasVoid
  | FunctionWasNonVoid
  deriving (Eq, Ord)

ppRetMismatch :: RetMismatch -> PP.Doc ann
ppRetMismatch =
  \case
    BadRetType -> "Specification had an ill-typed return value"
    FunctionWasVoid ->
      "Specification provided a return value, but the function was void"
    FunctionWasNonVoid ->
      "Specification didn't provide a return value, for a void function"

data PostcondTypeError
  = -- | Fields are actual index, maximum index
    PostcondMismatchedSize !Int !Int
  | PostcondMismatchedType
  | PostcondMismatchedRet !RetMismatch
  deriving (Eq, Ord)

ppPostcondTypeError :: PostcondTypeError -> PP.Doc ann
ppPostcondTypeError =
  \case
    PostcondMismatchedSize idx numArgs ->
      PP.hsep
        [ "Specification for values clobbered by the skipped function",
          "included an argument index"
          , PP.viaShow idx
          , "that is out of range for that function, which only has"
          , PP.viaShow numArgs
          , "arguments"
        ]
    PostcondMismatchedType ->
      PP.hsep
        [ "Specification for values clobbered by the skipped function",
          "included a value that was ill-typed with respect to that function's",
          "arguments."
        ]
    PostcondMismatchedRet mis ->
      PP.hsep
        [ "Specification for return value of the skipped function was ill-typed."
        , ppRetMismatch mis
        ]

-- | Check that the given untyped postcondition ('UPostcond') matches the
-- given function signature ('FuncSigRepr'), returning a strongly typed
-- postcondition ('Postcond') if so or an error if not.
typecheckPostcond ::
  (fs ~ 'FS.FuncSig va mft args) =>
  UPostcond m ->
  FuncSigRepr m fs ->
  Either PostcondTypeError (Postcond m fs)
typecheckPostcond post fs =
  do -- For each argument, check that the specified value has the right type.
     let argTypes = FS.fsArgTypes fs
     let uArgs = _uArgClobbers post
     args <-
       Ctx.generateM
       (Ctx.size argTypes)
       (\idx ->
          case IntMap.lookup (Ctx.indexVal idx) uArgs of
            Nothing -> Right DontClobberArg
            Just (SomeClobberArg DontClobberArg) -> Right DontClobberArg
            Just (SomeClobberArg (DoClobberArg (ClobberValue cur val ty _prf))) ->
              let argType = argTypes ^. ixF' idx
              in case testSameCrucibleType argType ty of
                   Nothing -> Left PostcondMismatchedType
                   Just prf -> Right $ DoClobberArg $
                     ClobberValue
                      { clobberValueCursor = cur,
                        clobberValue = val,
                        clobberValueType = ty,
                        clobberValueCompat =
                          makeSameCrucibleType $ \arch ->
                            case sameCrucibleType prf arch of Refl -> Refl
                      })

     -- Check that the correct number of arguments were specified
     let maxIdx = if IntMap.null uArgs then 0 else maximum (IntMap.keys uArgs)
     let numArgs = Ctx.sizeInt (Ctx.size argTypes)
     () <-
       if maxIdx > numArgs
       then Left (PostcondMismatchedSize maxIdx numArgs)
       else Right ()

     -- Check that the return value has the right type
     ret <-
       case (FS.fsRetType fs, _uReturnValue post) of
         (FS.NonVoidRepr{}, Nothing) -> Left (PostcondMismatchedRet FunctionWasNonVoid)
         (FS.VoidRepr{}, Just{}) -> Left (PostcondMismatchedRet FunctionWasVoid)
         (FS.VoidRepr, Nothing) -> Right ReturnVoid
         (FS.NonVoidRepr ft, Just (ConstrainedTypedValue ty val)) ->
           case testEquality ft ty of
             Just Refl -> Right (ReturnValue val)
             Nothing -> Left (PostcondMismatchedRet BadRetType)

     return $
       Postcond
         { pVarArgs = FS.fsVarArgs fs,
           pArgClobbers = args,
           pGlobalClobbers = _uGlobalClobbers post,
           pReturnValue = ret
         }

-- | Inverse of 'typecheckPostcond'
toUPostcond :: FuncSigRepr m fs -> Postcond m fs -> UPostcond m
toUPostcond (FS.FuncSigRepr _ _ retTy) (Postcond _ argClob globClob ret) =
  UPostcond
    { _uArgClobbers = ifoldrFC mkArg IntMap.empty argClob,
      _uGlobalClobbers = globClob,
      _uReturnValue =
        case (ret, retTy) of
          (ReturnVoid, FS.VoidRepr) -> Nothing
          (ReturnValue val, FS.NonVoidRepr retTyRep) ->
            Just (ConstrainedTypedValue retTyRep val)
    }
  where
    mkArg idx arg intMap =
      IntMap.insert (Ctx.indexVal idx) (SomeClobberArg arg) intMap
