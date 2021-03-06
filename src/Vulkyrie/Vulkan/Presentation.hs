{-# LANGUAGE Strict #-}
module Vulkyrie.Vulkan.Presentation
  ( SwapchainInfo (..)
  , SyncMode (..)
  , createSurface
  , createSwapchain
  ) where

import           Data.Maybe
import           Data.Semigroup
import qualified Graphics.UI.GLFW                     as GLFW
import           Graphics.Vulkan
import           Graphics.Vulkan.Core_1_0
import           Graphics.Vulkan.Ext.VK_KHR_surface
import           Graphics.Vulkan.Ext.VK_KHR_swapchain
import           Graphics.Vulkan.Marshal.Create
import           UnliftIO.Exception

import           Vulkyrie.Program
import           Vulkyrie.Program.Foreign
import           Vulkyrie.Resource
import           Vulkyrie.Vulkan.Device

data SyncMode = VSyncTriple | VSync | NoSync deriving (Eq, Ord, Show)

createSurface :: VkInstance -> GLFW.Window -> MetaResource VkSurfaceKHR
createSurface vkInstance window =
  metaResource (\s -> liftIO $ vkDestroySurfaceKHR vkInstance s VK_NULL) $
    allocaPeek $
      runVk . GLFW.createWindowSurface vkInstance window VK_NULL


chooseSwapSurfaceFormat :: SwapchainSupportDetails
                        -> Prog r VkSurfaceFormatKHR
chooseSwapSurfaceFormat SwapchainSupportDetails {..}
    = maybe (throwString "No available surface formats!")
            (pure . argVal . getMin)
    $ foldMap (Just . Min . fmtCost) formats
  where
    argVal (Arg _ b) = b
    bestFmt :: VkSurfaceFormatKHR
    bestFmt = createVk @VkSurfaceFormatKHR
      $  set @"format" VK_FORMAT_B8G8R8A8_UNORM
      &* set @"colorSpace" VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
    fmtCost :: VkSurfaceFormatKHR -> Arg Int VkSurfaceFormatKHR
    fmtCost f = case (getField @"format" f, getField @"colorSpace" f) of
      (VK_FORMAT_UNDEFINED, _) -> Arg 0 bestFmt
      (VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) -> Arg 1 f
      (_, _) -> Arg 2 f


chooseSwapPresentMode :: SwapchainSupportDetails -> SyncMode -> VkPresentModeKHR
chooseSwapPresentMode SwapchainSupportDetails { presentModes } syncMode
  = let prio = case syncMode of
          -- Only the VK_PRESENT_MODE_FIFO_KHR mode is guaranteed to be available
          VSyncTriple -> [VK_PRESENT_MODE_MAILBOX_KHR, VK_PRESENT_MODE_FIFO_KHR]
          VSync -> [VK_PRESENT_MODE_FIFO_KHR]
          NoSync -> [VK_PRESENT_MODE_IMMEDIATE_KHR, VK_PRESENT_MODE_FIFO_KHR]
    in head [x | x <- prio, x `elem` presentModes]
  -- TODO if VSyncTriple and MAILBOX is not available, implement DIY triple buffering


chooseSwapExtent :: SwapchainSupportDetails -> VkExtent2D
chooseSwapExtent SwapchainSupportDetails {..}
    = createVk @VkExtent2D
    $  set @"width"
      ( max (ew $ getField @"minImageExtent" capabilities)
                $ min (ew $ getField @"maxImageExtent" capabilities)
                      (ew $ getField @"currentExtent"  capabilities)
      )
    &* set @"height"
      ( max (eh $ getField @"minImageExtent" capabilities)
                $ min (eh $ getField @"maxImageExtent" capabilities)
                      (eh $ getField @"currentExtent"  capabilities)
      )
  where
    ew = getField @"width"
    eh = getField @"height"


data SwapchainInfo
  = SwapchainInfo
  { swapImgs      :: [VkImage]
  , swapImgFormat :: VkFormat
  , swapExtent    :: VkExtent2D
  , swapMaxAcquired :: Int
  } deriving (Eq, Show)


-- | When recreating the swapchain, the old one has to be destroyed manually.
--
--   Destroy the old one after non of its images are in use any more.
createSwapchain :: VkDevice
                -> SwapchainSupportDetails
                -> DevQueues
                -> VkSurfaceKHR
                -> SyncMode
                -> Maybe VkSwapchainKHR
                -> Resource (VkSwapchainKHR, SwapchainInfo)
createSwapchain dev scsd queues surf syncMode mayOldSwapchain = Resource $ do

  -- TODO not necessary every time I think
  surfFmt <- chooseSwapSurfaceFormat scsd
  let spMode = chooseSwapPresentMode scsd syncMode
      sExtent = chooseSwapExtent scsd
  logInfo $ "available present modes " <> showt (presentModes scsd)
  logInfo $ "using present mode " <> showt spMode

  let maxIC = getField @"maxImageCount" $ capabilities scsd
      minIC = getField @"minImageCount" $ capabilities scsd
      idealIC = minIC + 1
      imageCount = if maxIC <= 0
                   then idealIC
                   else min maxIC idealIC
  -- logInfo $ "swapchain minImageCount " ++ show minIC
  -- logInfo $ "swapchain maxImageCount " ++ show maxIC

  -- write VkSwapchainCreateInfoKHR
  let swCreateInfo = createVk @VkSwapchainCreateInfoKHR
        $  set @"sType" VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
        &* set @"pNext" VK_NULL_HANDLE
        &* set @"flags" VK_ZERO_FLAGS
        &* set @"surface" surf
        &* set @"minImageCount" imageCount
        &* set @"imageFormat" (getField @"format" surfFmt)
        &* set @"imageColorSpace" (getField @"colorSpace" surfFmt)
        &* set @"imageExtent" sExtent
        &* set @"imageArrayLayers" 1
        &* set @"imageUsage" VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
        &*
        ( if graphicsQueue queues /= presentQueue queues
          then set @"imageSharingMode" VK_SHARING_MODE_CONCURRENT
            &* set @"queueFamilyIndexCount" 2
            &* set @"pQueueFamilyIndices" (qFamIndices queues)
          else set @"imageSharingMode" VK_SHARING_MODE_EXCLUSIVE
            &* set @"queueFamilyIndexCount" 0
            &* set @"pQueueFamilyIndices" VK_NULL_HANDLE
        )
        &* set @"preTransform" (getField @"currentTransform" $ capabilities scsd)
        &* set @"compositeAlpha" VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
        &* set @"presentMode" spMode
        &* set @"clipped" VK_TRUE
        &* set @"oldSwapchain" (fromMaybe VK_NULL_HANDLE mayOldSwapchain)

  swapchain <-
    autoDestroyCreate
      (liftIO . flip (vkDestroySwapchainKHR dev) VK_NULL)
      (withVkPtr swCreateInfo $ \swciPtr -> allocaPeek
        $ runVk . vkCreateSwapchainKHR dev swciPtr VK_NULL)

  swapImgs <- asListVk
    $ \x -> runVk . vkGetSwapchainImagesKHR dev swapchain x

  let info = SwapchainInfo
        { swapImgs      = swapImgs
        , swapImgFormat = getField @"format" surfFmt
        , swapExtent    = sExtent
        , swapMaxAcquired = length swapImgs - fromIntegral minIC + 1
        }
  return (swapchain, info)