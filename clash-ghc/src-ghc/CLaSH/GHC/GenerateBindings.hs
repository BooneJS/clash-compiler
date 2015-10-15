module CLaSH.GHC.GenerateBindings
  (generateBindings)
where

import           Control.Lens            ((%~),(&))
import           Control.Monad.State     (State)
import qualified Control.Monad.State     as State
import           Data.Either             (lefts, rights)
import           Data.HashMap.Strict     (HashMap)
import qualified Data.HashMap.Strict     as HashMap
import           Data.IntMap.Strict      (IntMap)
import qualified Data.IntMap.Strict      as IM
import           Data.List               (isSuffixOf)
import qualified Data.Set                as Set
import qualified Data.Set.Lens           as Lens
import           Unbound.Generics.LocallyNameless (name2String, runFreshM, unembed)

import qualified BasicTypes              as GHC
import qualified CoreSyn                 as GHC
import qualified DynFlags                as GHC
import qualified TyCon                   as GHC
import qualified TysWiredIn              as GHC

import           CLaSH.Annotations.TopEntity (TopEntity)
import           CLaSH.Core.FreeVars     (termFreeIds)
import           CLaSH.Core.Term         (Term (..), TmName)
import           CLaSH.Core.Type         (Type, TypeView (..), coreView, mkFunTy, splitFunForallTy)
import           CLaSH.Core.TyCon        (TyCon, TyConName)
import           CLaSH.Core.TysPrim      (tysPrimMap)
import           CLaSH.Core.Subst        (substTms)
import           CLaSH.Core.Util         (mkLams, mkTyLams, termType)
import           CLaSH.Core.Var          (Var (..))
import           CLaSH.Driver.Types      (BindingMap)
import           CLaSH.GHC.GHC2Core      (GHC2CoreState, tyConMap, coreToId, coreToName, coreToTerm,
                                          makeAllTyCons, qualfiedNameString, emptyGHC2CoreState)
import           CLaSH.GHC.LoadModules   (loadModules)
import           CLaSH.Normalize.Util
import           CLaSH.Primitives.Types  (PrimMap)
import           CLaSH.Rewrite.Util      (mkInternalVar, mkSelectorCase)
import           CLaSH.Util              ((***),first)

generateBindings ::
  PrimMap
  -> String
  -> Maybe  (GHC.DynFlags)
  -> IO (BindingMap,HashMap TyConName TyCon,IntMap TyConName,Maybe TopEntity)
generateBindings primMap modName dflagsM = do
  (bindings,clsOps,unlocatable,fiEnvs,topEntM) <- loadModules modName dflagsM
  let ((bindingsMap,clsVMap),tcMap) = State.runState (mkBindings primMap bindings clsOps unlocatable) emptyGHC2CoreState
      (tcMap',tupTcCache)           = mkTupTyCons tcMap
      tcCache                       = makeAllTyCons tcMap' fiEnvs
      allTcCache                    = tysPrimMap `HashMap.union` tcCache
      clsMap                        = HashMap.map (\(ty,i) -> (ty,mkClassSelector allTcCache ty i)) clsVMap
      allBindings                   = bindingsMap `HashMap.union` clsMap
      droppedAndRetypedBindings     = dropAndRetypeBindings allTcCache allBindings
  return (droppedAndRetypedBindings,allTcCache,tupTcCache,topEntM)

dropAndRetypeBindings :: HashMap TyConName TyCon -> BindingMap -> BindingMap
dropAndRetypeBindings allTcCache allBindings = oBindings
  where
    topEntities     = HashMap.toList
                    $ HashMap.filterWithKey
                        (\var _ -> isSuffixOf ".topEntity" $ name2String var)
                        allBindings
    testInputs      = HashMap.toList
                    $ HashMap.filterWithKey
                        (\var _ -> isSuffixOf ".testInput" $ name2String var)
                        allBindings
    expectedOutputs = HashMap.toList
                    $ HashMap.filterWithKey
                        (\var _ -> isSuffixOf ".expectedOutput" $ name2String var)
                        allBindings

    dropAndRetype d (t,_) = snd
                          $ retype allTcCache
                                   ([],lambdaDropPrep d t)
                                   t

    tBindings = case topEntities of
                  (topEntity:_) -> dropAndRetype allBindings topEntity
                  _             -> allBindings

    iBindings = case testInputs of
                  (testInput:_) -> dropAndRetype tBindings testInput
                  _             -> tBindings

    oBindings = case expectedOutputs of
                  (expectedOutput:_) -> dropAndRetype iBindings expectedOutput
                  _                  -> iBindings

-- | clean up cast-removal mess
retype :: HashMap TyConName TyCon
       -> ([TmName], BindingMap) -- (visited, bindings)
       -> TmName                 -- top
       -> ([TmName], BindingMap)
retype tcm (visited,bindings) current = (visited', HashMap.insert current (ty',tm') bindings')
  where
    (_,tm)               = bindings HashMap.! current
    used                 = Set.toList $ Lens.setOf termFreeIds tm
    (visited',bindings') = foldl (retype tcm) (current:visited,bindings) (filter (`notElem` visited) used)
    usedTys              = map (fst . (bindings' HashMap.!)) used
    usedVars             = zipWith Var usedTys used
    tm'                  = substTms (zip used usedVars) tm
    ty'                  = runFreshM (termType tcm tm')

mkBindings :: PrimMap
           -> [(GHC.CoreBndr, GHC.CoreExpr)] -- Binders
           -> [(GHC.CoreBndr,Int)]           -- Class operations
           -> [GHC.CoreBndr]                 -- Unlocatable Expressions
           -> State GHC2CoreState
                    ( BindingMap
                    , HashMap TmName (Type,Int)
                    )
mkBindings primMap bindings clsOps unlocatable = do
  bindingsList <- mapM (\(v,e) -> do
                          tm <- coreToTerm primMap unlocatable e
                          v' <- coreToId v
                          return (varName v', (unembed (varType v'), tm))
                       ) bindings
  clsOpList    <- mapM (\(v,i) -> do
                          v' <- coreToId v
                          let ty = unembed $ varType v'
                          return (varName v', (ty,i))
                       ) clsOps

  return (HashMap.fromList bindingsList, HashMap.fromList clsOpList)

mkClassSelector :: HashMap TyConName TyCon
                -> Type
                -> Int
                -> Term
mkClassSelector tcm ty sel = newExpr
  where
    ((tvs,dictTy:_),_) = first (lefts *** rights)
                       $ first (span (\l -> case l of Left _ -> True
                                                      _      -> False))
                       $ splitFunForallTy ty
    newExpr = case coreView tcm dictTy of
      (TyConApp _ _) -> runFreshM $ flip State.evalStateT (0 :: Int) $ do
                          (dcId,dcVar) <- mkInternalVar "dict" dictTy
                          selE         <- mkSelectorCase "mkClassSelector" tcm dcVar 1 sel
                          return (mkTyLams (mkLams selE [dcId]) tvs)
      (FunTy arg res) -> runFreshM $ flip State.evalStateT (0 :: Int) $ do
                           (dcId,dcVar) <- mkInternalVar "dict" (mkFunTy arg res)
                           return (mkTyLams (mkLams dcVar [dcId]) tvs)
      (OtherType oTy) -> runFreshM $ flip State.evalStateT (0 :: Int) $ do
                           (dcId,dcVar) <- mkInternalVar "dict" oTy
                           return (mkTyLams (mkLams dcVar [dcId]) tvs)

mkTupTyCons :: GHC2CoreState -> (GHC2CoreState,IntMap TyConName)
mkTupTyCons tcMap = (tcMap'',tupTcCache)
  where
    tupTyCons        = map (GHC.tupleTyCon GHC.BoxedTuple) [2..62]
    (tcNames,tcMap') = State.runState (mapM (\tc -> coreToName GHC.tyConName GHC.tyConUnique qualfiedNameString tc) tupTyCons) tcMap
    tupTcCache       = IM.fromList (zip [2..62] tcNames)
    tupHM            = HashMap.fromList (zip tcNames tupTyCons)
    tcMap''          = tcMap' & tyConMap %~ (`HashMap.union` tupHM)
