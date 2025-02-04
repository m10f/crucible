------------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.LLVM.Globals
-- Description      : Operations for working with LLVM global variables
-- Copyright        : (c) Galois, Inc 2018
-- License          : BSD3
-- Maintainer       : Rob Dockins <rdockins@galois.com>
-- Stability        : provisional
--
-- This module provides support for dealing with LLVM global variables,
-- including initial allocation and populating variables with their
-- initial values.  A @GlobalInitializerMap@ is constructed during
-- module translation and can subsequently be used to populate
-- global variables.  This can either be done all at once using
-- @populateAllGlobals@; or it can be done in a more selective manner,
-- using one of the other \"populate\" operations.
------------------------------------------------------------------------

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE ImplicitParams        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

module Lang.Crucible.LLVM.Globals
  ( initializeMemory
  , initializeAllMemory
  , initializeMemoryConstGlobals
  , populateGlobal
  , populateGlobals
  , populateAllGlobals
  , populateConstGlobals

  , GlobalInitializerMap
  , makeGlobalMap
  ) where

import           Control.Arrow ((&&&))
import           Control.Monad.Except
import           Control.Lens hiding (op, (:>) )
import           Data.List (foldl')
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import           Data.String
import           Control.Monad.State (StateT, runStateT, get, put)
import           Data.Maybe (fromMaybe)
import qualified Data.Parameterized.Context as Ctx

import qualified Text.LLVM.AST as L
import qualified Text.LLVM.PP as LPP

import qualified Data.BitVector.Sized as BV
import           Data.Parameterized.NatRepr as NatRepr

import           Lang.Crucible.LLVM.Bytes
import           Lang.Crucible.LLVM.DataLayout
import           Lang.Crucible.LLVM.MemType
import           Lang.Crucible.LLVM.MemModel
import qualified Lang.Crucible.LLVM.MemModel.Generic as G
import           Lang.Crucible.LLVM.Translation.Constant
import           Lang.Crucible.LLVM.Translation.Monad
import           Lang.Crucible.LLVM.Translation.Types
import           Lang.Crucible.LLVM.TypeContext

import           Lang.Crucible.Backend

import           What4.Interface

import           GHC.Stack

------------------------------------------------------------------------
-- GlobalInitializerMap

-- | A @GlobalInitializerMap@ records the initialized values of globals in an @L.Module@.
--
-- The @Left@ constructor is used to signal errors in translation,
-- which can happen when:
--  * The declaration is ill-typed
--  * The global isn't linked (@extern global@)
--
-- The @Nothing@ constructor is used to signal that the global isn't actually a
-- compile-time constant.
--
-- These failures are as granular as possible (attached to the values)
-- so that simulation still succeeds if the module has a bad global that the
-- verified function never touches.
--
-- To actually initialize globals, saw-script translates them into
-- instances of @MemModel.LLVMVal@.
type GlobalInitializerMap = Map L.Symbol (L.Global, Either String (MemType, Maybe LLVMConst))


------------------------------------------------------------------------
-- makeGlobalMap

-- | @makeGlobalMap@ creates a map from names of LLVM global variables
-- to the values of their initializers, if any are included in the module.
makeGlobalMap :: forall arch wptr. (?lc :: TypeContext, HasPtrWidth wptr)
              => LLVMContext arch
              -> L.Module
              -> GlobalInitializerMap
makeGlobalMap ctx m = foldl' addAliases globalMap (Map.toList (llvmGlobalAliases ctx))

  where
   addAliases mp (glob, aliases) =
        case Map.lookup glob mp of
          Just initzr -> insertAll (map L.aliasName (Set.toList aliases)) initzr mp
          Nothing     -> mp -- should this be an error/exception?

   globalMap = Map.fromList $ map (L.globalSym &&& (id &&& globalToConst))
                                  (L.modGlobals m)

   insertAll ks v mp = foldr (flip Map.insert v) mp ks

   -- Catch the error from @transConstant@, turn it into @Either@
   globalToConst :: L.Global -> Either String (MemType, Maybe LLVMConst)
   globalToConst g =
     catchError
       (globalToConst' g)
       (\err -> Left $
         "Encountered error while processing global "
           ++ showSymbol (L.globalSym g)
           ++ ": "
           ++ err)
     where showSymbol sym =
             show $ let ?config = LPP.Config False False False
                    in LPP.ppSymbol $ sym

   globalToConst' :: forall m. (MonadError String m)
                  => L.Global -> m (MemType, Maybe LLVMConst)
   globalToConst' g =
     do let ?lc  = ctx^.llvmTypeCtx -- implicitly passed to transConstant
        let gty  = L.globalType g
        let gval = L.globalValue g
        mt  <- liftMemType gty
        val <- traverse (transConstant' mt) gval
        return (mt, val)

-------------------------------------------------------------------------
-- initializeMemory

-- | Build the initial memory for an LLVM program.  Note, this process
-- allocates space for global variables, but does not set their
-- initial values.
initializeAllMemory
   :: ( IsSymBackend sym bak, HasPtrWidth wptr, HasLLVMAnn sym
      , ?memOpts :: MemOptions )
   => bak
   -> LLVMContext arch
   -> L.Module
   -> IO (MemImpl sym)
initializeAllMemory = initializeMemory (const True)

initializeMemoryConstGlobals
   :: ( IsSymBackend sym bak, HasPtrWidth wptr, HasLLVMAnn sym
      , ?memOpts :: MemOptions )
   => bak
   -> LLVMContext arch
   -> L.Module
   -> IO (MemImpl sym)
initializeMemoryConstGlobals = initializeMemory (L.gaConstant . L.globalAttrs)

initializeMemory
   :: ( IsSymBackend sym bak, HasPtrWidth wptr, HasLLVMAnn sym
      , ?memOpts :: MemOptions )
   => (L.Global -> Bool)
   -> bak
   -> LLVMContext arch
   -> L.Module
   -> IO (MemImpl sym)
initializeMemory predicate bak llvm_ctx llvmModl = do
   -- Create initial memory of appropriate endianness
   let ?lc = llvm_ctx^.llvmTypeCtx
   let dl = llvmDataLayout ?lc
   let endianness = dl^.intLayout
   mem0 <- emptyMem endianness

   -- allocate pointers values for function symbols, but do not
   -- yet bind them to function handles
   let decls = map Left (L.modDeclares llvmModl) ++ map Right (L.modDefines llvmModl)
   mem <- foldM (allocLLVMFunPtr bak llvm_ctx) mem0 decls

   -- Allocate global values
   let globAliases = llvmGlobalAliases llvm_ctx
   let globals     = L.modGlobals llvmModl
   gs_alloc <- mapM (\g -> do
                        let err msg = malformedLLVMModule
                                    ("Invalid type for global" <> fromString (show (L.globalSym g)))
                                    [fromString msg]
                        ty <- either err return $ liftMemType $ L.globalType g
                        let sz      = memTypeSize dl ty
                        let tyAlign = memTypeAlign dl ty
                        let aliases = map L.aliasName . Set.toList $
                              fromMaybe Set.empty (Map.lookup (L.globalSym g) globAliases)
                        -- LLVM documentation regarding global variable alignment:
                        --
                        -- An explicit alignment may be specified for
                        -- a global, which must be a power of 2. If
                        -- not present, or if the alignment is set to
                        -- zero, the alignment of the global is set by
                        -- the target to whatever it feels
                        -- convenient. If an explicit alignment is
                        -- specified, the global is forced to have
                        -- exactly that alignment.
                        alignment <-
                          case L.globalAlign g of
                            Just a | a > 0 ->
                              case toAlignment (toBytes a) of
                                Nothing -> fail $ "Invalid alignemnt: " ++ show a ++ "\n  " ++
                                                  "specified for global: " ++ show (L.globalSym g)
                                Just al -> return al
                            _ -> return tyAlign
                        return (g, aliases, sz, alignment))
                    globals
   allocGlobals bak (filter (\(g, _, _, _) -> predicate g) gs_alloc) mem


allocLLVMFunPtr ::
  ( IsSymBackend sym bak, HasPtrWidth wptr, HasLLVMAnn sym
  , ?memOpts :: MemOptions ) =>
  bak ->
  LLVMContext arch ->
  MemImpl sym ->
  Either L.Declare L.Define ->
  IO (MemImpl sym)
allocLLVMFunPtr bak llvm_ctx mem decl =
  do let sym = backendGetSym bak
     let (symbol, displayString) =
           case decl of
             Left d ->
               let s@(L.Symbol nm) = L.decName d
                in ( s, "[external function] " ++ nm )
             Right d ->
               let s@(L.Symbol nm) = L.defName d
                in ( s, "[defined function ] " ++ nm)
     let funAliases = llvmFunctionAliases llvm_ctx
     let aliases = map L.aliasName $ maybe [] Set.toList $ Map.lookup symbol funAliases
     z <- bvLit sym ?ptrWidth (BV.zero ?ptrWidth)
     (ptr, mem') <- doMalloc bak G.GlobalAlloc G.Immutable displayString mem z noAlignment
     return $ registerGlobal mem' (symbol:aliases) ptr

------------------------------------------------------------------------
-- ** populateGlobals

-- | Populate the globals mentioned in the given @GlobalInitializerMap@
--   provided they satisfy the given filter function.
--
--   This will (necessarily) populate any globals that the ones in the
--   filtered list transitively reference.
populateGlobals ::
  ( ?lc :: TypeContext
  , ?memOpts :: MemOptions
  , 16 <= wptr
  , HasPtrWidth wptr
  , HasLLVMAnn sym
  , IsSymBackend sym bak) =>
  (L.Global -> Bool)   {- ^ Filter function, globals that cause this to return true will be populated -} ->
  bak ->
  GlobalInitializerMap ->
  MemImpl sym ->
  IO (MemImpl sym)
populateGlobals select bak gimap mem0 = foldM f mem0 (Map.elems gimap)
  where
  f mem (gl, _) | not (select gl)    = return mem
  f _   (_,  Left msg)               = fail msg
  f mem (gl, Right (mty, Just cval)) = populateGlobal bak gl mty cval gimap mem
  f mem (gl, Right (mty, Nothing))   = populateExternalGlobal bak gl mty mem


-- | Populate all the globals mentioned in the given @GlobalInitializerMap@.
populateAllGlobals ::
  ( ?lc :: TypeContext
  , ?memOpts :: MemOptions
  , 16 <= wptr
  , HasPtrWidth wptr
  , HasLLVMAnn sym
  , IsSymBackend sym bak) =>
  bak ->
  GlobalInitializerMap ->
  MemImpl sym ->
  IO (MemImpl sym)
populateAllGlobals = populateGlobals (const True)


-- | Populate only the constant global variables mentioned in the
--   given @GlobalInitializerMap@ (and any they transitively refer to).
populateConstGlobals ::
  ( ?lc :: TypeContext
  , ?memOpts :: MemOptions
  , 16 <= wptr
  , HasPtrWidth wptr
  , HasLLVMAnn sym
  , IsSymBackend sym bak) =>
  bak ->
  GlobalInitializerMap ->
  MemImpl sym ->
  IO (MemImpl sym)
populateConstGlobals = populateGlobals f
  where f = L.gaConstant . L.globalAttrs


-- | Ordinarily external globals do not receive initalizing writes.  However,
--   when 'lax-loads-and-stores` is enabled in the `stable-symbolic` mode, we
--   populate external global variables with fresh bytes.
populateExternalGlobal ::
  ( ?lc :: TypeContext
  , 16 <= wptr
  , HasPtrWidth wptr
  , IsSymBackend sym bak
  , HasLLVMAnn sym
  , HasCallStack
  , ?memOpts :: MemOptions
  ) =>
  bak ->
  L.Global {- ^ The global to populate -} ->
  MemType {- ^ Type of the global -} ->
  MemImpl sym ->
  IO (MemImpl sym)
populateExternalGlobal bak gl memty mem
  | laxLoadsAndStores ?memOpts
  , indeterminateLoadBehavior ?memOpts == StableSymbolic

  =  do let sym = backendGetSym bak
        bytes <- freshConstant sym emptySymbol
                    (BaseArrayRepr (Ctx.singleton $ BaseBVRepr ?ptrWidth)
                        (BaseBVRepr (knownNat @8)))
        let dl = llvmDataLayout ?lc
        let sz = memTypeSize dl memty
        let tyAlign = memTypeAlign dl memty
        sz' <- bvLit sym PtrWidth (bytesToBV PtrWidth sz)
        ptr <- doResolveGlobal bak mem (L.globalSym gl)
        doArrayConstStore bak mem ptr tyAlign bytes sz'

  | otherwise = return mem


-- | Write the value of the given LLVMConst into the given global variable.
--   This is intended to be used at initialization time, and will populate
--   even read-only global data.
populateGlobal :: forall sym bak wptr.
  ( ?lc :: TypeContext
  , 16 <= wptr
  , HasPtrWidth wptr
  , IsSymBackend sym bak
  , HasLLVMAnn sym
  , ?memOpts :: MemOptions
  , HasCallStack
  ) =>
  bak ->
  L.Global {- ^ The global to populate -} ->
  MemType {- ^ Type of the global -} ->
  LLVMConst {- ^ Constant value to initialize with -} ->
  GlobalInitializerMap ->
  MemImpl sym ->
  IO (MemImpl sym)
populateGlobal bak gl memty cval giMap mem =
  do let sym = backendGetSym bak
     let alignment = memTypeAlign (llvmDataLayout ?lc) memty

     -- So that globals can populate and look up the globals they reference
     -- during initialization
     let populateRec :: HasCallStack
                     => L.Symbol -> StateT (MemImpl sym) IO (LLVMPtr sym wptr)
         populateRec symbol = do
           memimpl0 <- get
           memimpl <-
            case Map.lookup symbol (memImplGlobalMap mem) of
              Just _  -> pure memimpl0 -- We already populated this one
              Nothing ->
                -- For explanations of the various modes of failure, see the
                -- comment on 'GlobalInitializerMap'.
                case Map.lookup symbol giMap of
                  Nothing -> fail $ unlines $
                    [ "Couldn't find global variable: " ++ show symbol ]
                  Just (glob, Left str) -> fail $ unlines $
                    [ "Couldn't find global variable's initializer: " ++
                        show symbol
                    , "Reason:"
                    , str
                    , "Full definition:"
                    , show glob
                    ]
                  Just (glob, Right (_, Nothing)) -> fail $ unlines $
                    [ "Global was not a compile-time constant:" ++ show symbol
                    , "Full definition:"
                    , show glob
                    ]
                  Just (glob, Right (memty_, Just cval_)) ->
                    liftIO $ populateGlobal bak glob memty_ cval_ giMap memimpl0
           put memimpl
           liftIO $ doResolveGlobal bak memimpl symbol

     ty <- toStorableType memty
     ptr <- doResolveGlobal bak mem (L.globalSym gl)
     (val, mem') <- runStateT (constToLLVMValP sym populateRec cval) mem
     storeConstRaw bak mem' ptr ty alignment val
