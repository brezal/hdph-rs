-- Locations
--   includes API for error and debug messages
--
-- Author: Rob Stewart, Patrick Maier
-----------------------------------------------------------------------------

module Control.Parallel.HdpH.Internal.Location
  ( -- * node IDs (and their constitutent parts)
    NodeId,           -- instances: Eq, Ord, Show, NFData, Serialize

    -- * reading all node IDs and this node's own node ID
    allNodes,             -- :: IO [NodeId]
    myNode,               -- :: IO NodeId
    myNode',              -- :: IO (Maybe NodeId)
    MyNodeException(..),  -- instances: Exception, Show, Typeable

    -- * error messages tagged by emitting node
    error,  -- :: String -> a

    -- * debug messages tagged by emitting node
    debug,  -- :: Int -> String -> IO ()

    -- * debug levels
    dbgNone,       -- :: Int
    dbgStats,      -- :: Int
    dbgStaticTab,  -- :: Int
    dbgSpark,      -- :: Int
    dbgMsgSend,    -- :: Int
    dbgMsgRcvd,    -- :: Int
    dbgGIVar,      -- :: Int
    dbgIVar,       -- :: Int
    dbgGRef,       -- :: Int
    dbgFailure     -- :: Int
  ) where

import Prelude hiding (catch, error)
import qualified Prelude (error)
import Control.Exception (catch, evaluate)
import Control.Monad (when)
import Data.Functor ((<$>))
import Data.IORef (readIORef)
import System.IO (stderr, hPutStrLn)
import System.IO.Unsafe (unsafePerformIO)

import Control.Parallel.HdpH.Internal.State.Location
       (myNodeRef, allNodesRef, debugRef)
import Control.Parallel.HdpH.Internal.Type.Location
       (NodeId, MyNodeException(NodeIdUnset))


-----------------------------------------------------------------------------
-- reading this node's own node ID

-- Return this node's node ID;
-- raises 'NodeIdUnset :: MyNodeException' if node ID has not yet been set
-- (by module HdpH.Internal.Comm).
myNode :: IO NodeId
myNode = readIORef myNodeRef


-- Return 'Just' this node's node ID, or 'Nothing' if ID has not yet been set.
myNode' :: IO (Maybe NodeId)
myNode' =
  catch (Just <$> (evaluate =<< myNode))
        (const $ return Nothing :: MyNodeException -> IO (Maybe NodeId))


-- Return list of all nodes (with main node being head of the list),
-- provided the list has been initialised (by module HdpH.Internal.Comm);
-- otherwise returns the empty list.
allNodes :: IO [NodeId]
allNodes = readIORef allNodesRef


-----------------------------------------------------------------------------
-- error messages tagged by emitting node

-- Abort with error 'message'.
error :: String -> a
error message = case unsafePerformIO myNode' of
                  Just node -> Prelude.error (show node ++ " " ++ message)
                  Nothing   -> Prelude.error message


-----------------------------------------------------------------------------
-- debug messages tagged by emitting node

-- Output a debug 'message' to 'stderr' if the given 'level' is less than
-- or equal to the system level; 'level' should be positive.
debug :: Int -> String -> IO ()
debug level message = do
  sysLevel <- readIORef debugRef
  when (level <= sysLevel) $ do
    maybe_this <- myNode'
    case maybe_this of
      Just this -> hPutStrLn stderr $ show this ++ " " ++ message
      Nothing   -> hPutStrLn stderr $ "<unknown> " ++ message


-- debug levels
dbgNone,dbgStats,dbgStaticTab,dbgSpark,
  dbgMsgSend,dbgMsgRcvd,dbgGIVar,dbgIVar,
  dbgGRef,dbgFailure :: Int
dbgNone      = 0 :: Int  -- no debug output
dbgStats     = 1 :: Int  -- print final stats
dbgStaticTab = 2 :: Int  -- on main node, print Static table
dbgSpark     = 3 :: Int  -- spark created or converted
dbgMsgSend   = 4 :: Int  -- message to be sent
dbgMsgRcvd   = 5 :: Int  -- message being handled
dbgGIVar     = 6 :: Int  -- op on a GIVar (globalising or writing to)
dbgIVar      = 7 :: Int  -- blocking/unblocking on IVar (only log event type)
dbgGRef      = 8 :: Int  -- registry update (globalise or free)
dbgFailure   = 9 :: Int  -- Node failure, failed message transmittion
