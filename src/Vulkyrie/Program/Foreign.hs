{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MagicHash      #-}
{-# LANGUAGE Strict         #-}
{-# LANGUAGE UnboxedTuples  #-}
-- | Collection of functions adapted from @Foreign@ module hierarchy
module Vulkyrie.Program.Foreign
    ( Ptr, plusPtr, Storable.sizeOf
    , withVkPtr
    , withArrayLen
    , withVkArrayLen
    , alloca, allocaArray
    , peek, peekArray, poke
    , ptrAtIndex
    , asListVk
    , allocaPeek, allocaPeekVk, allocaPeekDF
    , mallocRes, mallocArrayRes, newArrayRes
    , withUnsafeField
    , getListCountAndRef
    ) where

import qualified GHC.Base
import GHC.TypeLits (Symbol)
import Data.Kind (Type)

import           Control.Monad.IO.Class
import           Foreign.Ptr
import           Foreign.Storable        (Storable)
import qualified Foreign.Storable        as Storable
import           Graphics.Vulkan.Marshal
import           Numeric.DataFrame
import           Numeric.DataFrame.IO
import           Numeric.Dimensions

import           UnliftIO
import qualified UnliftIO.Foreign as Foreign
import           Vulkyrie.Program

withVkPtr :: VulkanMarshal a
          => a
          -> (Ptr a -> Program b)
          -> Program b
withVkPtr x f = do
  u <- askUnliftIO
  liftIO (withPtr x (unliftIO u . f))
{-# INLINE withVkPtr #-}

-- | This should probably be in Graphics.Vulkan.Marshal
withArrayLen :: (Storable a, VulkanMarshal a) => [a] -> (Word32 -> Ptr a -> IO b) -> IO b
withArrayLen xs pf = do
  ret <- Foreign.withArrayLen xs (pf . fromIntegral)
  touch xs
  return ret
{-# INLINE withArrayLen #-}

withVkArrayLen :: (Storable a, VulkanMarshal a) => [a] -> (Word32 -> Ptr a -> Program b) -> Program b
withVkArrayLen xs pf = do
  u <- askUnliftIO
  liftIO $ withArrayLen xs (\l p -> unliftIO u $ pf l p)
{-# INLINE withVkArrayLen #-}

-- | Uses `newVkData`, deallocation happens via GC.
allocaPeekVk :: VulkanMarshal a
             => (Ptr a -> Program ())
             -> Program a
allocaPeekVk pf = do
  u <- askUnliftIO
  liftIO $ newVkData (unliftIO u . pf)
{-# INLINE allocaPeekVk #-}

-- | Prevent earlier GC of given value
touch :: a -> IO ()
touch x = GHC.Base.IO $ \s -> case GHC.Base.touch# x s of s' -> (# s', () #)
{-# INLINE touch #-}

alloca :: Storable a
       => (Ptr a -> Program b)
       -> Program b
alloca f = do
  u <- askUnliftIO
  liftIO $ Foreign.alloca (unliftIO u . f)
{-# INLINE alloca #-}

allocaPeekDF :: forall a (ns :: [Nat])
              . (PrimBytes a, Dimensions ns)
             => (Ptr a -> Program ())
             -> Program (DataFrame a ns)
allocaPeekDF pf
  | Dict <- inferKnownBackend @a @ns
  = do
    u <- askUnliftIO
    mdf <- liftIO newPinnedDataFrame
    liftIO $ withDataFramePtr mdf (unliftIO u . pf)
    liftIO $ unsafeFreezeDataFrame mdf
{-# INLINE allocaPeekDF #-}

allocaArray :: Storable a
            => Int
            -> (Ptr a -> Program b)
            -> Program b
allocaArray n f = do
  u <- askUnliftIO
  liftIO $ Foreign.allocaArray n (unliftIO u . f)
{-# INLINE allocaArray #-}


allocaPeek :: Storable a
           => (Ptr a -> Program ())
           -> Program a
allocaPeek f = alloca $ \ptr -> f ptr >> liftIO (Storable.peek ptr)
{-# INLINE allocaPeek #-}


peekArray :: Storable a => Int -> Ptr a -> Program [a]
peekArray n = liftIO . Foreign.peekArray n
{-# INLINE peekArray #-}

peek :: Storable a => Ptr a -> Program a
peek = liftIO . Storable.peek
{-# INLINE peek #-}

poke :: Storable a => Ptr a -> a -> Program ()
poke p v = liftIO $ Storable.poke p v
{-# INLINE poke #-}

ptrAtIndex :: forall a. Storable a => Ptr a -> Int -> Ptr a
ptrAtIndex ptr i = ptr `plusPtr` (i * Storable.sizeOf @a undefined)
{-# INLINE ptrAtIndex #-}


-- | Get size of action output and then get the result,
--   performing data copy.
asListVk :: Storable x
         => (Ptr Word32 -> Ptr x -> Program ())
         -> Program [x]
asListVk action = alloca $ \counterPtr -> do
  action counterPtr VK_NULL_HANDLE
  counter <- liftIO $ fromIntegral <$> Storable.peek counterPtr
  if counter <= 0
  then pure []
  else allocaArray counter $ \valPtr -> do
    action counterPtr valPtr
    liftIO $ Foreign.peekArray counter valPtr

-- TODO free
mallocArrayRes :: Storable a => Int -> Program (Ptr a)
mallocArrayRes n = liftIO $ Foreign.mallocArray n
{-# INLINE mallocArrayRes #-}

-- TODO free
mallocRes :: Storable a => Program (Ptr a)
mallocRes = liftIO $ Foreign.malloc
{-# INLINE mallocRes #-}

-- TODO free
newArrayRes :: Storable a => [a] -> Program (Ptr a)
newArrayRes xs = liftIO $ Foreign.newArray xs
{-# INLINE newArrayRes #-}

-- | Keeps the vk struct alive while doing something with a unsafe field (like Ptr).
--
--   If the field has pointers to memory that has its lifetime coupled to the
--   struct, this function can be used to ensure the memory is kept alive.
withUnsafeField :: forall (fname :: Symbol) (struct :: Type) (a :: Type)
                . (CanReadField fname struct)
                => struct -> (FieldType fname struct -> IO a) -> IO a
withUnsafeField vkStruct fun = do
  let ptr = getField @fname vkStruct
  ret <- fun ptr
  touch vkStruct
  return ret

getListCountAndRef :: forall (countFname :: Symbol) (arrayFname :: Symbol) (struct :: Type) (a :: Type)
                   . (CanReadField countFname struct, CanReadField arrayFname struct, Storable a,
                      FieldType arrayFname struct ~ Ptr a,
                      FieldType countFname struct ~ Word32)
                   => struct -> IO [a]
getListCountAndRef vkStruct =
  withUnsafeField @arrayFname vkStruct (Foreign.peekArray (fromIntegral (getField @countFname vkStruct)))