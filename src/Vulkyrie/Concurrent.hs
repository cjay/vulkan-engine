{-# LANGUAGE RankNTypes #-}
module Vulkyrie.Concurrent
  ( ChildThreadException (..)
  , threadRes

  , ThreadOwner
  , threadOwner
  , ownedThread

  , asyncRedo
  ) where

import Control.Exception (AsyncException (ThreadKilled), asyncExceptionFromException, asyncExceptionToException)
import Control.Monad
import Control.Monad.Logger (logDebugN, logErrorN)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text, pack)
import GHC.Stack (HasCallStack, callStack, prettyCallStack)
import UnliftIO.Concurrent
import UnliftIO.Exception
import Vulkyrie.Program
import Vulkyrie.Resource
import UnliftIO.IORef
import Vulkyrie.Utils (catchAsync)


data ChildThreadException =
  ChildThreadException
  { threadSrc :: Text
  , exception :: SomeException
  }
  deriving (Show, Typeable)

instance Exception ChildThreadException where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | A thread as a resource.
--
-- Not suitable for large numbers of threads that mostly end on their own. See
-- threadOwner and ownedThread for that.
threadRes :: HasCallStack => (forall r. Prog r ()) -> Resource ThreadId
threadRes prog = Resource $ do
  parentThreadId <- myThreadId
  let threadSrc = pack $ prettyCallStack callStack
  alive <- newIORef True
  autoDestroyCreate
    (\tid -> do
      readIORef alive >>= flip when (do
        logDebugN $
          "killing thread through resource destruction\n\nthread defined at: "
            <> threadSrc
        killThread tid)
    )
    -- this happens in masked context because of autoDestroyCreate
    (forkIOWithUnmask $ \unmask -> do
      unmask prog `catchAsync` \(e :: SomeException) ->
        unless (fromException e == Just ThreadKilled) $
          case fromException e of
            Just (_ :: ChildThreadException) -> throwTo parentThreadId e
            _ -> do
              -- Logging here just in case the recursive destruction of
              -- resources gets stuck somewhere or the user aborts the program
              -- before the ChildThreadException hits the main thread.
              logErrorN $
                "uncaught exception in a thread\n\nthread defined at: "
                  <> threadSrc <> "\n\n" <> showt e
              throwTo parentThreadId (ChildThreadException threadSrc e)
      -- alive only gets written in one spot, no race conditions possible
      writeIORef alive False
    )

data ThreadOwner =
  ThreadOwner
  -- MVar to allow threads to remove themselves
  { threadsVar :: MVar (Set ThreadId) -- ^ keeps track of alive threads
  }

-- | A  Resource that owns threads and limits their lifetime to the region.
--
-- Use this for creating large amounts of threads that can end before the region
-- ends. With threadRes, each thread creation leaves an entry in the destructor
-- list that needs to be processed at the end of the region. Owned threads remove
-- themselves from the ThreadOwner automatically when they end.
threadOwner :: HasCallStack => Resource ThreadOwner
threadOwner = Resource $ do
  let ownerSrc = pack $ prettyCallStack callStack
  autoDestroyCreate
    (\ThreadOwner{ threadsVar } -> do
      threads <- takeMVar threadsVar
      unless (null threads) $
        logDebugN $
          "killing some threads through ThreadOwner destruction\n\nowner defined at: "
            <> ownerSrc
      forM_ threads killThread
    )
    (ThreadOwner <$> newMVar Set.empty)

-- | Make a new thread owned by the ThreadOwner.
--
-- Make sure to only use this while the region that contains the thread owner is
-- still alive.
ownedThread :: HasCallStack => ThreadOwner -> (forall r. Prog r ()) -> Prog r' ThreadId
ownedThread ThreadOwner{ threadsVar } prog = do
  parentThreadId <- myThreadId
  let threadSrc = pack $ prettyCallStack callStack
  mask_ $ do
    threads <- takeMVar threadsVar
    threadId <- forkIOWithUnmask $ \unmask -> do
      threadId <- myThreadId
      unmask prog `catchAsync` \(e :: SomeException) ->
        unless (fromException e == Just ThreadKilled) $
          case fromException e of
            Just (_ :: ChildThreadException) -> throwTo parentThreadId e
            _ -> do
              -- Logging here just in case the recursive destruction of
              -- resources gets stuck somewhere or the user aborts the program
              -- before the ChildThreadException hits the main thread.
              logErrorN $
                "uncaught exception in a thread\n\nthread defined at: "
                  <> threadSrc <> "\n\n" <> showt e
              throwTo parentThreadId (ChildThreadException threadSrc e)
      modifyMVar_ threadsVar $ pure . Set.delete threadId
    putMVar threadsVar $ Set.insert threadId threads
    pure threadId


data RedoSignal = SigRedo | SigExit deriving Eq

-- | Enables deferred destruction of resources.
--
-- The argument action gets passed a redo trigger that causes the action to be
-- restarted in a new thread while the old one is still running.
asyncRedo :: (forall r. (forall s. Prog s ()) -> Prog r ()) -> Prog t ()
asyncRedo prog = region $ do
  owner <- auto threadOwner
  -- TODO how to deal with older redo threads that are still running when SigExit happens? Currently they get killed.
  go owner
  where
  go owner = do
    control <- newEmptyMVar
    -- TODO use forkOS when using unsafe ffi calls?
    void $ ownedThread owner $ do
      prog $ do
            success <- tryPutMVar control SigRedo
            unless success $ throwString "asyncRedo action tried to signal more than once"
            yield

      -- When the redo-thread exits, we only need to signal exit to the parent
      -- if nothing else has been signalled yet.
      void $ tryPutMVar control SigExit
    sig <- takeMVar control
    when (sig == SigRedo) (go owner)
