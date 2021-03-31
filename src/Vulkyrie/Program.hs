{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StrictData            #-}

module Vulkyrie.Program
    ( Prog (..)
    , runProgram
    , askResourceContext
    , withResourceContext
    , askRegion
    , MonadIO (..)
      -- * Exception handling
    , VulkanException (..)
    , runVk
    , runVkResult
    , runAndCatchVk
      -- * Logging
    , logDebug
    , logInfo
    , logWarn
    , logError
    , showt
      -- * Other
    , LoopControl (..)
    , loop
    , occupyThreadAndFork
    , touchIORef
    ) where


import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.IO.Unlift
import           Control.Monad.Logger.CallStack hiding (logDebug)
import qualified Control.Monad.Logger as Logger
import           Control.Monad.Reader.Class
import           Control.Monad.Trans (lift)
import           Control.Monad.Trans.Reader (ReaderT, runReaderT)
import           Data.Text
import           GHC.Stack ( HasCallStack, callStack )
import           Graphics.Vulkan.Core_1_0 ( VkResult(VK_SUCCESS) )
import           System.Exit
import           UnliftIO.Concurrent
import           UnliftIO.Exception
import           UnliftIO.IORef

import           Vulkyrie.BuildFlags


data ProgContext = ProgContext

data Context r =
  Context
  {
    resourceContext :: r
  , progContext :: ProgContext
  }

newtype Prog r a = Prog (ReaderT (Context r) (LoggingT IO) a)
  deriving (Functor, Applicative, Monad, MonadLogger, MonadIO, MonadUnliftIO)


askResourceContext :: Prog r r
askResourceContext = resourceContext <$> Prog ask

runProgram :: Prog () a -> IO a
runProgram prog = run (Context () ProgContext) prog

withResourceContext :: r -> Prog r a -> Prog r' a
withResourceContext rctx (Prog prog) = Prog $ do
  ctx <- ask
  lift $ runReaderT prog ctx{ resourceContext = rctx }

-- | For registering a resource with a different (usually enclosing) region scope.
askRegion :: Prog r (Prog r a -> Prog r' a)
askRegion = withResourceContext <$> askResourceContext

run :: Context r -> Prog r a -> IO a
run ctx (Prog prog) = runStdoutLoggingT $ runReaderT prog ctx




newtype VulkanException = VulkanException VkResult
  deriving (Show, Typeable)

instance Exception VulkanException

runVk :: MonadIO m => IO VkResult -> m ()
runVk = void . runVkResult

runVkResult :: MonadIO m => IO VkResult -> m VkResult
runVkResult action = do
  r <- liftIO action
  when (r < VK_SUCCESS) (throwIO $ VulkanException r)
  return r

-- | Calls handler directly for error VkResult codes.
-- TODO rewrite rule?
runAndCatchVk :: MonadIO m => IO VkResult -> (VulkanException -> m ()) -> m ()
runAndCatchVk action handler = do
  r <- liftIO action
  when (r < VK_SUCCESS) (handler $ VulkanException r)



logDebug :: (HasCallStack, MonadLogger m) => Text -> m ()
logDebug =
  if isDEVELOPMENT
  -- Can't use Control.Monad.Logger.CallStack.logDebug here because then the
  -- location info in the log message refers to this wrapper function.
  then Logger.logDebugCS callStack
  else const (pure ())
{-# INLINE logDebug #-}

-- | Relevant for logging now. Like showt from TextShow, but doesn't require a new typeclass.
-- TODO vulkan-api should generate TextShow instances..
showt :: Show a => a -> Text
showt = pack . show


data LoopControl a = ContinueLoop | AbortLoop a deriving Eq

loop :: Prog r (LoopControl a) -> Prog r a
loop action = go
  where go = action >>= \case
          ContinueLoop -> go
          AbortLoop a -> return a


-- | For C functions that have to run in the main thread as long as the program runs.
--
--   Caveat: The separate thread is not a bound thread, in contrast to the main thread.
--   Use `runInBoundThread` there if you need thread local state for C libs.
occupyThreadAndFork :: Prog r () -- ^ the program to run in the main thread
                    -> Prog r () -- ^ the program to run in a separate thread
                    -> Prog r ()
occupyThreadAndFork mainProg deputyProg = do
  mainThreadId <- myThreadId
  -- TODO proper thread management. at least wrap in some AsyncException.
  void $ forkFinally deputyProg $ \case
    Left exception -> throwTo mainThreadId exception
    Right ()       -> throwTo mainThreadId ExitSuccess
  mainProg


-- | to make sure IORef writes arrive in other threads
-- TODO Investigate cache coherence + IORefs. I'm not 100% sure this does what I want.
touchIORef :: IORef a -> Prog r ()
touchIORef ref = atomicModifyIORef' ref (\x -> (x, ()))
