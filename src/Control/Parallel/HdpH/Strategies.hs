-- Strategies (and skeletons) in the Par monad
--
-- Author: Patrick Maier
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}  -- for type annotations in Static decl
{-# LANGUAGE FlexibleInstances #-}    -- req'd for some 'ToClosure' instances
{-# LANGUAGE TemplateHaskell #-}      -- req'd for 'mkClosure', etc
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}


module Control.Parallel.HdpH.Strategies
  ( -- * Strategy type
    Strategy,
    using,
    
    -- * Basic sequential strategies
    r0,
    rseq,
    rdeepseq,

    -- * Fully forcing Closure strategy
    forceC,
    forceCC,
    ForceCC(
      locForceCC
    ),
    StaticForceCC,
    staticForceCC,

    -- * Proto-strategies for generating parallelism
    ProtoStrategy,
    sparkClosure,
    pushClosure,

    -- * Strategies for lists
    evalList,
    evalClosureListClosure,
    parClosureList,
    pushClosureList,
    pushRandClosureList,

    -- ** Clustering strategies
    parClosureListClusterBy,
    parClosureListChunked,
    parClosureListSliced,

    -- * Task farm skeletons
    -- | Task farm skeletons are parallel maps, applying a function to a list
    -- in parallel. For technical reasons, the function to be applied must
    -- wrapped in a Closure (ie. a function Closure).

    -- ** Lazy task placement
    parMap,
    parMapNF,
    parMapChunked,
    parMapChunkedNF,
    parMapSliced,
    parMapSlicedNF,

    parClosureMapM,
    parMapM,
    parMapM_,

    -- ** Round-robin task placement
    pushMap,
    pushMapNF,
    pushMapSlicedNF,

    pushClosureMapM,
    pushMapM,
    pushMapM_,

    -- ** Random task placement
    pushRandClosureMapM,
    pushRandMapM,
    pushRandMapM_,

    -- * Divide and conquer skeletons
    divideAndConquer,
    forkDivideAndConquer,
    parDivideAndConquer,
    pushDivideAndConquer,

    -- mapReduce
    parMapReduceRangeThresh,
    pushMapReduceRangeThresh,
    InclusiveRange(..),

    -- * This module's Static declaration
    declareStatic    -- :: StaticDecl
  ) where

import Prelude hiding (min,max)
import Control.DeepSeq (NFData, deepseq)
import Control.Monad (zipWithM, zipWithM_,foldM)
import Data.Functor ((<$>))
import Data.List (transpose)
import Data.Monoid (mconcat)
import System.Random (randomRIO)

import Control.Parallel.HdpH 
       (Par, io, fork, pushTo, spark, new, get, glob, rput, put,
        NodeId, IVar, GIVar, spawn, spawnAt,
        Env, LocT, here,allNodes,
        Closure, unClosure, mkClosure, mkClosureLoc, apC, compC,
        ToClosure(locToClosure), toClosure, forceClosure,
        StaticToClosure, staticToClosure,
        Static, static, static_, staticLoc_,
        StaticDecl, declare)
import qualified Control.Parallel.HdpH as HdpH (declareStatic)
import qualified Control.Parallel.HdpH.Internal.Type.ToClosureInstances as ToClosureInstances  (declareStatic)
import Control.Parallel.HdpH.Internal.Type.ToClosureInstances (InclusiveRange(..))


-----------------------------------------------------------------------------
-- Static declaration

-- 'ToClosure' instance required for 'evalClosureListClosure'
instance ToClosure [Closure a] where locToClosure = $(here)
instance ForceCC (Closure a) where locForceCC = $(here)

declareStatic :: StaticDecl
declareStatic =
  mconcat
    [HdpH.declareStatic,  -- 'Static' decl of imported modules
     ToClosureInstances.declareStatic,
     declare (staticToClosure :: forall a . StaticToClosure [Closure a]),
     declare (staticForceCC :: forall a . StaticForceCC (Closure a)),
     declare $(static 'sparkClosure_abs),
     declare $(static 'pushClosure_abs),
     declare $(static_ 'evalClosureListClosure),
     declare $(static 'parClosureMapM_abs),
     declare $(static 'parMapM_abs),
     declare $(static_ 'constReturnUnit),
     declare $(static 'parDivideAndConquer_abs),
     declare $(static 'pushDivideAndConquer_abs),
     declare $(static 'parMapReduceRangeThresh_abs),
     declare $(static 'pushMapReduceRangeThresh_abs)]


-----------------------------------------------------------------------------
-- Strategy type

-- | A @'Strategy'@ for type @a@ is a (semantic) identity in the @'Par'@ monad.
-- For an elaboration of this concept (in the context of the @Eval@ monad)
-- see the paper:
--   Marlow et al.
--   /Seq no more: Better Strategies for parallel Haskell./
--   Haskell 2010.
type Strategy a = a -> Par a

-- | Strategy application is actual application (in the @'Par'@ monad).
using :: a -> Strategy a -> Par a
using = flip ($)


-----------------------------------------------------------------------------
-- Basic sequential strategies (polymorphic);
-- these are exactly as in the "Seq no more" paper.

-- | /Do Nothing/ strategy.
r0 :: Strategy a
r0 = return

-- | /Evaluate head-strict/ strategy; probably not very useful in HdpH.
rseq :: Strategy a
rseq x = x `seq` return x -- Order of eval irrelevant due to 2nd arg converging

-- | /Evaluate fully/ strategy.
rdeepseq :: (NFData a) => Strategy a
rdeepseq x = x `deepseq` return x  -- Order of eval irrelevant (2nd arg conv)


-----------------------------------------------------------------------------
-- fully forcing strategy for Closures

-- | @forceC@ is the fully forcing @'Closure'@ strategy, ie. it fully normalises
-- the thunk inside an explicit @'Closure'@.
-- Importantly, @forceC@ alters the serialisable @'Closure'@ represention
-- so that serialisation will not force the @'Closure'@ again.
forceC :: (NFData a, ToClosure a) => Strategy (Closure a)
forceC clo = return $! forceClosure clo

-- Note that 'forceC clo' does not have the same effect as
-- * 'rdeepseq clo' (because 'forceC' changes the closure representation), or
-- * 'rdeepseq $ toClosure $ unClosure clo' (because 'forceC' does not force
--   the serialised environment of its result), or
-- * 'rdeepseq clo >> return (toClosure (unClosure clo))' (because this does
--   hang on to the old serialisable environment whereas 'forceC' replaces
--   the old enviroment with a new one).
--
-- Note that it does not make sense to construct a variant of 'forceC' that
-- would evaluate the thunk inside a Closure head-strict only. The reason is
-- that serialising such a Closure would turn it into a fully forced one.


-----------------------------------------------------------------------------
-- fully forcing Closure strategy wrapped into a Closure
--
-- To enable passing strategy @'forceC'@ around in distributed contexts, it
-- has to be wrapped into a @'Closure'@. That is, this module should export
--
-- > forceCC :: (NFData a, ToClosure a) => Closure (Strategy (Closure a))
--
-- The tutorial in module 'Control.Parallel.HdpH.Closure' details how to cope
-- with the type class constraint by introducing a new class.

-- | @forceCC@ is a @'Closure'@ wrapping the fully forcing Closure strategy
-- @'forceC'@; see the tutorial in module 'Control.Parallel.HdpH.Closure' for
-- details on the implementation of @forceCC@.
forceCC :: (ForceCC a) => Closure (Strategy (Closure a))
forceCC = $(mkClosureLoc [| forceC |]) locForceCC

-- | Indexing class, recording which types support @'forceCC'@; see the
-- tutorial in module 'Control.Parallel.HdpH.Closure' for a more thorough
-- explanation.
class (NFData a, ToClosure a) => ForceCC a where
  -- | Only method of class @ForceCC@, recording the source location
  -- where an instance of @ForceCC@ is declared.
  locForceCC :: LocT (Strategy (Closure a))
                -- The phantom type argument of 'LocT' is the type of the thunk
                -- that is quoted and passed to 'mkClosureLoc' above.

-- | Type synonym for declaring the @'Static'@ deserialisers required by
-- @'ForceCC'@ instances; see the tutorial in module
-- 'Control.Parallel.HdpH.Closure' for a more thorough explanation.
type StaticForceCC a = Static (Env -> Strategy (Closure a))

-- | @'Static'@ deserialiser required by a 'ForceCC' instance; see the tutorial
-- in module 'Control.Parallel.HdpH.Closure' for a more thorough explanation.
staticForceCC :: (ForceCC a) => StaticForceCC a
staticForceCC = $(staticLoc_ 'forceC) locForceCC


-----------------------------------------------------------------------------
-- proto-strategies for generating parallelism

-- | A @'ProtoStrategy'@ is almost a @'Strategy'@.
-- More precisely, a @'ProtoStrategy'@ for type @a@ is a /delayed/ (semantic)
-- identity function in the @'Par'@ monad, ie. it returns an @'IVar'@ (rather
-- than a term) of type @a@.
type ProtoStrategy a = a -> Par (IVar a)


-- | @sparkClosure clo_strat@ is a @'ProtoStrategy'@ that sparks a @'Closure'@;
-- evaluation of the sparked @'Closure'@ is governed by the strategy
-- @'unClosure' clo_strat@.
sparkClosure :: Closure (Strategy (Closure a)) ->
                  ProtoStrategy (Closure a)
sparkClosure clo_strat clo = do
  v <- new
  gv <- glob v
  spark $(mkClosure [| sparkClosure_abs (clo, clo_strat, gv) |])
  return v

sparkClosure_abs :: (Closure a,
                     Closure (Strategy (Closure a)),
                     GIVar (Closure a))
                 -> Par ()
sparkClosure_abs (clo, clo_strat, gv) =
  (clo `using` unClosure clo_strat) >>= rput gv


-- | @pushClosure clo_strat n@ is a @'ProtoStrategy'@ that pushes a @'Closure'@
-- to be executed in a new thread on node @n@;
-- evaluation of the pushed @'Closure'@ is governed by the strategy
-- @'unClosure' clo_strat@.
pushClosure :: Closure (Strategy (Closure a)) -> NodeId ->
                 ProtoStrategy (Closure a)
pushClosure clo_strat node clo = do
  v <- new
  gv <- glob v
  pushTo $(mkClosure [| pushClosure_abs (clo, clo_strat, gv) |]) node
  return v

pushClosure_abs :: (Closure a,
                    Closure (Strategy (Closure a)),
                    GIVar (Closure a))
                -> Par ()
pushClosure_abs (clo, clo_strat, gv) =
  fork $ (clo `using` unClosure clo_strat) >>= rput gv


------------------------------------------------------------------------------
-- strategies for lists

-- 'evalList' is a (type-restricted) monadic map; should be suitably
-- generalisable for all data structures that support mapping over
-- | Evaluate each element of a list according to the given strategy.
evalList :: Strategy a -> Strategy [a]
evalList _strat []     = return []
evalList  strat (x:xs) = do x' <- strat x
                            xs' <- evalList strat xs
                            return (x':xs')


-- | Specialisation of @'evalList'@ to a list of Closures (wrapped in a
-- Closure). Useful for building clustering strategies.
evalClosureListClosure :: Strategy (Closure a) -> Strategy (Closure [Closure a])
evalClosureListClosure strat clo =
  toClosure <$> (unClosure clo `using` evalList strat)


-- | Evaluate each element of a list of Closures in parallel according to
-- the given strategy (wrapped in a Closure). Work is distributed by
-- lazy work stealing.
parClosureList :: Closure (Strategy (Closure a)) -> Strategy [Closure a]
parClosureList clo_strat xs = mapM (sparkClosure clo_strat) xs >>=
                              mapM get


-- | Evaluate each element of a list of Closures in parallel according to
-- the given strategy (wrapped in a Closure). Work is pushed round-robin
-- to the given list of nodes.
pushClosureList :: Closure (Strategy (Closure a))
                -> [NodeId]
                -> Strategy [Closure a]
pushClosureList clo_strat nodes xs =
  zipWithM (pushClosure clo_strat) (cycle nodes) xs >>=
  mapM get


-- | Evaluate each element of a list of Closures in parallel according to
-- the given strategy (wrapped in a Closure). Work is pushed randomly
-- to the given list of nodes.
pushRandClosureList :: Closure (Strategy (Closure a))
                    -> [NodeId]
                    -> Strategy [Closure a]
pushRandClosureList clo_strat nodes xs =
  mapM (\ x -> do { node <- rand; pushClosure clo_strat node x}) xs >>=
  mapM get
    where
      rand :: Par NodeId
      rand = (nodes !!) <$> io (randomRIO (0, length nodes - 1))


------------------------------------------------------------------------------
-- clustering strategies

-- generic clustering strategy combinator
evalClusterBy :: (a -> b) -> (b -> a) -> Strategy b -> Strategy a
evalClusterBy cluster uncluster strat x =
  uncluster <$> (cluster x `using` strat)


-- | @parClosureListClusterBy cluster uncluster@ is a generic parallel
-- clustering strategy combinator for lists of Closures, evaluating
-- clusters generated by @cluster@ in parallel.
-- Clusters are distributed by lazy work stealing.
-- The function @uncluster@ must be a /left inverse/ of @cluster@,
-- that is @uncluster . cluster@ must be the identity.
parClosureListClusterBy :: ([Closure a] -> [[Closure a]])
                        -> ([[Closure a]] -> [Closure a])
                        -> Closure (Strategy (Closure a))
                        -> Strategy [Closure a]
parClosureListClusterBy cluster uncluster clo_strat =
  evalClusterBy cluster' uncluster' strat'
    where cluster'   = map toClosure . cluster
          uncluster' = uncluster . map unClosure
       -- strat' :: Strategy [Closure [Closure a]]
          strat' = parClosureList clo_strat''
       -- clo_strat'' :: Closure (Strategy (Closure [Closure a]))
          clo_strat'' =
            $(mkClosure [| evalClosureListClosure |]) `apC` clo_strat

pushClosureListClusterBy :: [NodeId]
                        -> ([Closure a] -> [[Closure a]])
                        -> ([[Closure a]] -> [Closure a])
                        -> Closure (Strategy (Closure a))
                        -> Strategy [Closure a]
pushClosureListClusterBy nodes cluster uncluster clo_strat =
  evalClusterBy cluster' uncluster' strat'
    where cluster'   = map toClosure . cluster
          uncluster' = uncluster . map unClosure
       -- strat' :: Strategy [Closure [Closure a]]
          strat' = pushRandClosureList clo_strat'' nodes
       -- clo_strat'' :: Closure (Strategy (Closure [Closure a]))
          clo_strat'' =
            $(mkClosure [| evalClosureListClosure |]) `apC` clo_strat


-- | @parClosureListChunked n@ evaluates chunks of size @n@ of a list of
-- Closures in parallel according to the given strategy (wrapped in a Closure).
-- Chunks are distributed by lazy work stealing.
-- For instance, dividing the list @[c1,c2,c3,c4,c5]@ into chunks of size 3
-- results in the following list of chunks @[[c1,c2,c3], [c4,c5]]@.
parClosureListChunked :: Int
                      -> Closure (Strategy (Closure a))
                      -> Strategy [Closure a]
parClosureListChunked n = parClosureListClusterBy (chunk n) unchunk


-- | @parClosureListSliced n@ evaluates @n@ slices of a list of Closures in
-- parallel according to the given strategy (wrapped in a Closure).
-- Slices are distributed by lazy work stealing.
-- For instance, dividing the list @[c1,c2,c3,c4,c5]@ into 3 slices
-- results in the following list of slices @[[c1,c4], [c2,c5], [c3]]@.
parClosureListSliced :: Int
                     -> Closure (Strategy (Closure a))
                     -> Strategy [Closure a]
parClosureListSliced n = parClosureListClusterBy (slice n) unslice

pushClosureListSliced :: [NodeId]
                     -> Int
                     -> Closure (Strategy (Closure a))
                     -> Strategy [Closure a]
pushClosureListSliced nodes n = pushClosureListClusterBy nodes (slice n) unslice

-- clustering functions: chunking and slicing
chunk :: Int -> [a] -> [[a]]
chunk n | n <= 0    = chunk 1
        | otherwise = go
            where
              go [] = []
              go xs = ys : go zs where (ys,zs) = splitAt n xs

unchunk :: [[a]] -> [a]
unchunk = concat

slice :: Int -> [a] -> [[a]]
slice n = transpose . chunk n

unslice :: [[a]] -> [a]
unslice = concat . transpose


------------------------------------------------------------------------------
-- skeletons

-- | Task farm, evaluates tasks (function Closure applied to an element
-- of the input list) in parallel and according to the given strategy (wrapped
-- in a Closure).
-- Note that @parMap@ should only be used if the terms in the input list are
-- already in normal form, as they may be forced sequentially otherwise.
parMap :: (ToClosure a)
       => Closure (Strategy (Closure b))
       -> Closure (a -> b)
       -> [a]
       -> Par [b]
parMap clo_strat clo_f xs =
  do clo_ys <- map f clo_xs `using` parClosureList clo_strat
     return $ map unClosure clo_ys
       where f = apC clo_f
             clo_xs = map toClosure xs

-- | Specialisation of @'parMap'@ to the fully forcing Closure strategy.
-- That is, @parMapNF@ forces every element of the output list to normalform.
parMapNF :: (ToClosure a, ForceCC b)
         => Closure (a -> b)
         -> [a]
         -> Par [b]
parMapNF = parMap forceCC


-- | Chunking task farm, divides the input list into chunks of given size
-- and evaluates tasks (function Closure mapped on a chunk of the input list) 
-- in parallel and according to the given strategy (wrapped in a Closure).
-- @parMapChunked@ should only be used if the terms in the input list
-- are already in normal form.
parMapChunked :: (ToClosure a)
              => Int
              -> Closure (Strategy (Closure b))
              -> Closure (a -> b)
              -> [a]
              -> Par [b]
parMapChunked n clo_strat clo_f xs =
  do clo_ys <- map f clo_xs `using` parClosureListChunked n clo_strat
     return $ map unClosure clo_ys
       where f = apC clo_f
             clo_xs = map toClosure xs

-- | Specialisation of @'parMapChunked'@ to the fully forcing Closure strategy.
parMapChunkedNF :: (ToClosure a, ForceCC b)
                => Int
                -> Closure (a -> b)
                -> [a]
                -> Par [b]
parMapChunkedNF n = parMapChunked n forceCC


-- | Slicing task farm, divides the input list into given number of slices
-- and evaluates tasks (function Closure mapped on a slice of the input list) 
-- in parallel and according to the given strategy (wrapped in a Closure).
-- @parMapSliced@ should only be used if the terms in the input list
-- are already in normal form.
parMapSliced :: (ToClosure a)
             => Int
             -> Closure (Strategy (Closure b))
             -> Closure (a -> b)
             -> [a]
             -> Par [b]
parMapSliced n clo_strat clo_f xs =
  do clo_ys <- map f clo_xs `using` parClosureListSliced n clo_strat
     return $ map unClosure clo_ys
       where f = apC clo_f
             clo_xs = map toClosure xs

-- | Specialisation of @'parMapSliced'@ to the fully forcing Closure strategy.
parMapSlicedNF :: (ToClosure a, ForceCC b)
               => Int
               -> Closure (a -> b)
               -> [a]
               -> Par [b]
parMapSlicedNF n = parMapSliced n forceCC

pushMapSliced :: (ToClosure a)
             => [NodeId]
             -> Int
             -> Closure (Strategy (Closure b))
             -> Closure (a -> b)
             -> [a]
             -> Par [b]
pushMapSliced nodes n clo_strat clo_f xs =
  do clo_ys <- map f clo_xs `using` pushClosureListSliced nodes n clo_strat
     return $ map unClosure clo_ys
       where f = apC clo_f
             clo_xs = map toClosure xs

-- | Specialisation of @'parMapSliced'@ to the fully forcing Closure strategy.
pushMapSlicedNF :: (ToClosure a, ForceCC b)
               => [NodeId]
               -> Int
               -> Closure (a -> b)
               -> [a]
               -> Par [b]
pushMapSlicedNF nodes n = pushMapSliced nodes n forceCC


-- | Monadic task farm for Closures, evaluates tasks (@'Par'@-monadic function
-- Closure applied to a Closure of the input list) in parallel.
-- Note the absence of a strategy argument; strategies aren't needed because
-- they can be baked into the monadic function Closure.
parClosureMapM :: Closure (Closure a -> Par (Closure b))
               -> [Closure a]
               -> Par [Closure b]
parClosureMapM clo_f clo_xs =
  do vs <- mapM spawn' clo_xs
     mapM get vs
       where
         spawn' clo_x = do
           v <- new
           gv <- glob v
           spark $(mkClosure [| parClosureMapM_abs (clo_f, clo_x, gv) |])
           return v

parClosureMapM_abs :: (Closure (Closure a -> Par (Closure b)),
                       Closure a,
                       GIVar (Closure b))
                   -> Par ()
parClosureMapM_abs (clo_f, clo_x, gv) = unClosure clo_f clo_x >>= rput gv

-- | Monadic task farm, evaluates tasks (pure function
-- applied to an element of the input list) in parallel.
-- Each task is forked locally, so this skeleton is only
-- suitable for shared-memory parallelism. Each task writes
-- a value to an @'IVar'@. The return value is a list of values
-- retrieved using @'get'@ on each @'IVar'@.
parMapForkM :: (NFData b)
            => (a -> Par b)
            -> [a]
            -> Par [b]
parMapForkM f xs =
  do vs <- mapM spawn' xs
     mapM (\ v -> get v) vs
       where
         spawn' x = do
           v <- new
           fork (f x >>= put v)
           return v


-- | Monadic task farm, evaluates tasks (@'Par'@-monadic function Closure
-- applied to an element of the input list) in parallel.
-- Note the absence of a strategy argument; strategies aren't needed because
-- they can be baked into the monadic function Closure.
-- @parMap@ should only be used if the terms in the input list are already
-- in normal form, as they may be forced sequentially otherwise.
parMapM :: (ToClosure a)
        => Closure (a -> Par (Closure b))
        -> [a]
        -> Par [b]
parMapM clo_f xs =
  do vs <- mapM spawn' xs
     mapM (\ v -> unClosure <$> get v) vs
       where
         spawn' x = do
           let clo_x = toClosure x
           v <- new
           gv <- glob v
           spark $(mkClosure [| parMapM_abs (clo_f, clo_x, gv) |])
           return v

parMapM_abs :: (Closure (a -> Par (Closure b)), 
                Closure a, 
                GIVar (Closure b)) 
            -> Par ()
parMapM_abs (clo_f, clo_x, gv) = unClosure (clo_f `apC` clo_x) >>= rput gv


-- | Specialisation of @'parMapM'@, not returning any result.
parMapM_ :: (ToClosure a)
         => Closure (a -> Par b)
         -> [a]
         -> Par ()
parMapM_ clo_f xs = mapM_ (spark . apC (termParC `compC` clo_f) . toClosure) xs
-- Note that applying the @'termParC'@ transformation is necessary because
-- @'spark'@ only accepts Closures of type @Par ()@.

-- terminal arrow in the Par monad, wrapped in a Closure
termParC :: Closure (a -> Par ())
termParC = $(mkClosure [| constReturnUnit |])

{-# INLINE constReturnUnit #-}
constReturnUnit :: a -> Par ()
constReturnUnit = const (return ())


-- | Task farm like @'parMap'@ but pushes tasks in a round-robin fashion
-- to the given list of nodes.
pushMap :: (ToClosure a)
        => Closure (Strategy (Closure b))
        -> [NodeId]
        -> Closure (a -> b)
        -> [a]
        -> Par [b]
pushMap clo_strat nodes clo_f xs =
  do clo_ys <- map f clo_xs `using` pushClosureList clo_strat nodes
     return $ map unClosure clo_ys
       where f = apC clo_f
             clo_xs = map toClosure xs

-- | Task farm like @'parMapNF'@ but pushes tasks in a round-robin fashion
-- to the given list of nodes.
pushMapNF :: (ToClosure a, ForceCC b)
          => [NodeId]
          -> Closure (a -> b)
          -> [a]
          -> Par [b]
pushMapNF = pushMap forceCC


-- | Monadic task farm for Closures like @'parClosureMapM'@ but pushes tasks
-- in a round-robin fashion to the given list of nodes.
pushClosureMapM :: [NodeId]
                -> Closure (Closure a -> Par (Closure b))
                -> [Closure a]
                -> Par [Closure b]
pushClosureMapM nodes clo_f clo_xs =
  do vs <- zipWithM spawn' (cycle nodes) clo_xs
     mapM get vs
       where
         spawn' node clo_x = do
           v <- new
           gv <- glob v
           pushTo $(mkClosure [| parClosureMapM_abs (clo_f, clo_x, gv) |]) node
           return v


-- | Monadic task farm like @'parMapM'@ but pushes tasks
-- in a round-robin fashion to the given list of nodes.
pushMapM :: (ToClosure a)
         => [NodeId]
         -> Closure (a -> Par (Closure b))
         -> [a]
         -> Par [b]
pushMapM nodes clo_f xs =
  do vs <- zipWithM spawn' (cycle nodes) xs
     mapM (\ v -> unClosure <$> get v) vs
       where
         spawn' node x = do
           let clo_x = toClosure x
           v <- new
           gv <- glob v
           pushTo $(mkClosure [| parMapM_abs (clo_f, clo_x, gv) |]) node
           return v


-- | Monadic task farm like @'parMapM_'@ but pushes tasks
-- in a round-robin fashion to the given list of nodes.
pushMapM_ :: (ToClosure a)
          => [NodeId]
          -> Closure (a -> Par b)
          -> [a]
          -> Par ()
pushMapM_ nodes clo_f xs =
  zipWithM_
    (\ node x -> pushTo (compC termParC clo_f `apC` toClosure x) node)
    (cycle nodes)
    xs


-- | Monadic task farm for Closures like @'parClosureMapM'@
-- but pushes to random nodes on the given list.
pushRandClosureMapM :: [NodeId]
                    -> Closure (Closure a -> Par (Closure b))
                    -> [Closure a]
                    -> Par [Closure b]
pushRandClosureMapM nodes clo_f clo_xs =
  do vs <- mapM spawn' clo_xs
     mapM get vs
       where
         rand = (nodes !!) <$> io (randomRIO (0, length nodes - 1))
         spawn' clo_x = do
           v <- new
           gv <- glob v
           node <- rand
           pushTo $(mkClosure [| parClosureMapM_abs (clo_f, clo_x, gv) |]) node
           return v


-- | Monadic task farm like @'parMapM'@
-- but pushes to random nodes on the given list.
pushRandMapM :: (ToClosure a)
             => [NodeId]
             -> Closure (a -> Par (Closure b))
             -> [a]
             -> Par [b]
pushRandMapM nodes clo_f xs =
  do vs <- mapM spawn' xs
     mapM (\ v -> unClosure <$> get v) vs
       where
         rand = (nodes !!) <$> io (randomRIO (0, length nodes - 1))
         spawn' x = do
           let clo_x = toClosure x
           v <- new
           gv <- glob v
           node <- rand
           pushTo $(mkClosure [| parMapM_abs (clo_f, clo_x, gv) |]) node
           return v


-- | Monadic task farm like @'parMapM_'@
-- but pushes to random nodes on the given list.
pushRandMapM_ :: (ToClosure a)
              => [NodeId]
              -> Closure (a -> Par b)
              -> [a]
              -> Par ()
pushRandMapM_ nodes clo_f xs =
  mapM_ spawn' xs
    where
      rand = (nodes !!) <$> io (randomRIO (0, length nodes - 1))
      spawn' x = do
        node <- rand
        pushTo (compC termParC clo_f `apC` toClosure x) node


-- | Sequential divide-and-conquer skeleton.
-- @didvideAndConquer trivial decompose combine f x@ repeatedly decomposes
-- the problem @x@ until trivial, applies @f@ to the trivial sub-problems
-- and combines the solutions.
divideAndConquer :: (a -> Bool)      -- isTrivial
                 -> (a -> [a])       -- decomposeProblem
                 -> (a -> [b] -> b)  -- combineSolutions
                 -> (a -> b)         -- trivialAlgorithm
                 -> a                -- problem
                 -> b
divideAndConquer trivial decompose combine f x
  | trivial x = f x
  | otherwise = combine x $ map solveRec (decompose x)
      where
        solveRec = divideAndConquer trivial decompose combine f

-- | TODO: document
forkDivideAndConquer :: (NFData b)
                 => (a -> Bool)      -- isTrivial
                 -> (a -> [a])       -- decomposeProblem
                 -> (a -> [b] -> b)  -- combineSolutions
                 -> (a -> Par b)     -- trivialAlgorithm
                 -> a                -- problem
                 -> Par b
forkDivideAndConquer trivial decompose combine f x
 | trivial x = f x
 | otherwise = combine x <$> parMapForkM solveRec (decompose x)
     where
       solveRec = forkDivideAndConquer trivial decompose combine f


-- | Parallel divide-and-conquer skeleton with lazy work distribution.
-- @parDivideAndConquer trivial_clo decompose_clo combine_clo f_clo x@ follows
-- the divide-and-conquer pattern of @'divideAndConquer'@ except that, for
-- technical reasons, all arguments are Closures.
parDivideAndConquer :: Closure (Closure a -> Bool)
                    -> Closure (Closure a -> [Closure a])
                    -> Closure (Closure a -> [Closure b] -> Closure b)
                    -> Closure (Closure a -> Par (Closure b))
                    -> Closure a
                    -> Par (Closure b)
parDivideAndConquer trivial_clo decompose_clo combine_clo f_clo x
  | trivial x = f x
  | otherwise = combine x <$> parClosureMapM solveRec_clo (decompose x)
      where
        trivial   = unClosure trivial_clo
        decompose = unClosure decompose_clo
        combine   = unClosure combine_clo
        f         = unClosure f_clo
        solveRec_clo =
          $(mkClosure [| parDivideAndConquer_abs
                           (trivial_clo, decompose_clo, combine_clo, f_clo) |])

parDivideAndConquer_abs :: (Closure (Closure a -> Bool),
                            Closure (Closure a -> [Closure a]),
                            Closure (Closure a -> [Closure b] -> Closure b),
                            Closure (Closure a -> Par (Closure b)))
                        -> Closure a -> Par (Closure b)
parDivideAndConquer_abs (trivial_clo, decompose_clo, combine_clo, f_clo) =
  parDivideAndConquer trivial_clo decompose_clo combine_clo f_clo


-- | Parallel divide-and-conquer skeleton with eager random work distribution,
-- pushing work to the given list of nodes.
-- @pushDivideAndConquer nodes trivial_clo decompose_clo combine_clo f_clo x@
-- follows the divide-and-conquer pattern of @'divideAndConquer'@ except that,
-- for technical reasons, all arguments are Closures.
pushDivideAndConquer :: [NodeId]
                     -> Closure (Closure a -> Bool)
                     -> Closure (Closure a -> [Closure a])
                     -> Closure (Closure a -> [Closure b] -> Closure b)
                     -> Closure (Closure a -> Par (Closure b))
                     -> Closure a
                     -> Par (Closure b)
pushDivideAndConquer ns trivial_clo decompose_clo combine_clo f_clo x
  | trivial x = f x
  | otherwise = combine x <$> pushRandClosureMapM ns solveRec_clo (decompose x)
      where
        trivial   = unClosure trivial_clo
        decompose = unClosure decompose_clo
        combine   = unClosure combine_clo
        f         = unClosure f_clo
        solveRec_clo =
          $(mkClosure [| pushDivideAndConquer_abs
                           (ns,trivial_clo,decompose_clo,combine_clo,f_clo) |])

pushDivideAndConquer_abs :: ([NodeId],
                             Closure (Closure a -> Bool),
                             Closure (Closure a -> [Closure a]),
                             Closure (Closure a -> [Closure b] -> Closure b),
                             Closure (Closure a -> Par (Closure b)))
                         -> Closure a -> Par (Closure b)
pushDivideAndConquer_abs (ns, trivial_clo, decompose_clo, combine_clo, f_clo) =
  pushDivideAndConquer ns trivial_clo decompose_clo combine_clo f_clo

------------------------------------------------------
-- parMapReduceRangeThresh

parMapReduceRangeThresh
  :: forall a. Closure Int
  -> Closure InclusiveRange
  -> Closure (Closure Int -> Par (Closure a))
  -> Closure (Closure a -> Closure a -> Par (Closure a))
  -> Closure a
  -> Par (Closure a)
parMapReduceRangeThresh = mapReduceRangeThresh (toClosure True)

pushMapReduceRangeThresh
  :: forall a. Closure Int
  -> Closure InclusiveRange
  -> Closure (Closure Int -> Par (Closure a))
  -> Closure (Closure a -> Closure a -> Par (Closure a))
  -> Closure a
  -> Par (Closure a)
pushMapReduceRangeThresh = mapReduceRangeThresh (toClosure False)

-- | Computes a binary map\/reduce over a finite range.  The range is
-- recursively split into two, the result for each half is computed in
-- parallel, and then the two results are combined.  When the range
-- reaches the threshold size, the remaining elements of the range are
-- computed sequentially.
-- Adapted from monad-par-extras library <http://hackage.haskell.org/packages/archive/monad-par-extras/latest/doc/html/Control-Monad-Par-Combinator.html>
mapReduceRangeThresh
  :: Closure Bool
  -> Closure Int                                         -- ^ threshold
  -> Closure InclusiveRange                              -- ^ range over which to calculate
  -> Closure (Closure Int -> Par (Closure a))                    -- ^ compute one result
  -> Closure (Closure a -> Closure a -> Par (Closure a)) -- ^ compute two results (associate)
  -> Closure a                                           -- ^ initial value
  -> Par (Closure a)
mapReduceRangeThresh isLazy_clo threshold_clo range_clo f_clo combine_clo init_clo = do
    let (InclusiveRange min max) = unClosure $ range_clo
        binop = unClosure combine_clo
        xs = map toClosure [min..max]
    if (max - min) <= unClosure threshold_clo
      then
        let mapred a_clo b_clo = do let f = unClosure f_clo
                                    x <- f b_clo
                                    result <- a_clo `binop` x
                                    return result
        in foldM mapred init_clo xs
      else do
        let mid = (min + ((max - min) `quot` 2))
            rangeLower_clo = toClosure $ InclusiveRange min mid
            rangeUpper_clo = toClosure $ InclusiveRange (mid+1) max
        rght <- if (unClosure isLazy_clo)
           then do
             spawn $(mkClosure [|
               parMapReduceRangeThresh_abs (isLazy_clo,threshold_clo,rangeUpper_clo,f_clo,combine_clo,init_clo) |])
           else do
             nodes <- allNodes
             let rand = (nodes !!) <$> io (randomRIO (0, length nodes - 1))
             node <- rand
             spawnAt
                 $(mkClosure [| pushMapReduceRangeThresh_abs (isLazy_clo,threshold_clo,rangeUpper_clo,f_clo,combine_clo,init_clo) |])
                 node
        l <- mapReduceRangeThresh isLazy_clo threshold_clo rangeLower_clo f_clo combine_clo init_clo
        r <- get rght
        l `binop` r

pushMapReduceRangeThresh_abs
  :: (Closure Bool,
      Closure Int,
      Closure InclusiveRange,
      Closure (Closure Int -> Par (Closure a)),
      Closure (Closure a -> Closure a -> Par (Closure a)),
      Closure a)
  -> Par (Closure a)
pushMapReduceRangeThresh_abs (isLazy_clo,threshold_clo,range_clo,f_clo,combine_clo,init_clo) = do
  v <- new
  gv <- glob v
  fork (mapReduceRangeThresh isLazy_clo threshold_clo range_clo f_clo combine_clo init_clo >>= rput gv)
  get v

parMapReduceRangeThresh_abs
  :: (Closure Bool,
      Closure Int,
      Closure InclusiveRange,
      Closure (Closure Int -> Par (Closure a)),
      Closure (Closure a -> Closure a -> Par (Closure a)),
      Closure a)
  -> Par (Closure a)
parMapReduceRangeThresh_abs (isLazy_clo,threshold_clo,range_clo,f_clo,combine_clo,init_clo) = do
  mapReduceRangeThresh isLazy_clo threshold_clo range_clo f_clo combine_clo init_clo
