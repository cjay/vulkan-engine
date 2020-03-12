{-# LANGUAGE Strict           #-}
module Lib.Vulkan.RenderPass
  ( createPrivateAttachments
  , createRenderPass
  , createFramebuffer
  , createRenderPassBeginInfo
  ) where

import           Data.Bits
import           Graphics.Vulkan
import           Graphics.Vulkan.Core_1_0
import           Graphics.Vulkan.Marshal.Create
import           Graphics.Vulkan.Marshal.Create.DataFrame
import           Numeric.Vector

import           Lib.Program
import           Lib.Program.Foreign
import           Lib.Resource
import           Lib.Vulkan.Engine
import           Lib.Vulkan.Image

  -- The colorOut is manually passed as last attachment to the renderpass and has 1 sample.
  -- If samples = 1bit then colorOut is used as the color attachment, otherwise
  -- colorOut is used as the resolve attachment.
  --
  -- => order of attachments has to be: depth, color, maybe resolve

-- | Create attachments that are only internally needed by the renderpass, in the expected order.
createPrivateAttachments :: EngineCapability
                         -> VkExtent2D
                         -> VkFormat
                         -> VkSampleCountFlagBits
                         -> Resource r ([(VkSemaphore, VkPipelineStageBitmask a)], [VkImageView])
createPrivateAttachments cap extent imgFormat samples = do
  let msaaOn = samples /= VK_SAMPLE_COUNT_1_BIT
  fmap unzip . sequence $
    [createDepthAttImgView cap extent samples]
    <> [createColorAttImgView cap imgFormat extent samples | msaaOn]

createRenderPass :: VkDevice
                 -> VkFormat
                 -> VkFormat
                 -> VkSampleCountFlagBits
                 -> VkImageLayout
                 -> Resource r VkRenderPass
createRenderPass dev colorFormat depthFormat samples colorOutFinalLayout =
  let msaaOn = samples /= VK_SAMPLE_COUNT_1_BIT
      finalColorLayout =
        if msaaOn then
          VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        else
          colorOutFinalLayout
      depthAttachment = createVk @VkAttachmentDescription
        $  set @"flags" VK_ZERO_FLAGS
        &* set @"format" depthFormat
        &* set @"samples" samples
        &* set @"loadOp" VK_ATTACHMENT_LOAD_OP_CLEAR
        &* set @"storeOp" VK_ATTACHMENT_STORE_OP_DONT_CARE
        &* set @"stencilLoadOp" VK_ATTACHMENT_LOAD_OP_DONT_CARE
        &* set @"stencilStoreOp" VK_ATTACHMENT_STORE_OP_DONT_CARE
        &* set @"initialLayout" VK_IMAGE_LAYOUT_UNDEFINED
        &* set @"finalLayout" VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL

      colorAttachment = createVk @VkAttachmentDescription
        $  set @"flags" VK_ZERO_FLAGS
        &* set @"format" colorFormat
        &* set @"samples" samples
        &* set @"loadOp" VK_ATTACHMENT_LOAD_OP_CLEAR
        &* set @"storeOp" VK_ATTACHMENT_STORE_OP_STORE
        &* set @"stencilLoadOp" VK_ATTACHMENT_LOAD_OP_DONT_CARE
        &* set @"stencilStoreOp" VK_ATTACHMENT_STORE_OP_DONT_CARE
        &* set @"initialLayout" VK_IMAGE_LAYOUT_UNDEFINED
        &* set @"finalLayout" finalColorLayout

      -- this is needed when msaaOn
      resolveAttachment = createVk @VkAttachmentDescription
        $  set @"flags" VK_ZERO_FLAGS
        &* set @"format" colorFormat
        &* set @"samples" VK_SAMPLE_COUNT_1_BIT
        &* set @"loadOp" VK_ATTACHMENT_LOAD_OP_DONT_CARE
        &* set @"storeOp" VK_ATTACHMENT_STORE_OP_STORE
        &* set @"stencilLoadOp" VK_ATTACHMENT_LOAD_OP_DONT_CARE
        &* set @"stencilStoreOp" VK_ATTACHMENT_STORE_OP_DONT_CARE
        &* set @"initialLayout" VK_IMAGE_LAYOUT_UNDEFINED
        -- resolve attachment used => it is the color output
        &* set @"finalLayout" colorOutFinalLayout

      -- subpasses and attachment references
      depthAttachmentRef = createVk @VkAttachmentReference
        $  set @"attachment" 0
        &* set @"layout" VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL

      colorAttachmentRef = createVk @VkAttachmentReference
        $  set @"attachment" 1
        &* set @"layout" VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL

      resolveAttachmentRef = createVk @VkAttachmentReference
        $  set @"attachment" 2
        &* set @"layout" VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL

      subpass = createVk @VkSubpassDescription
        $  set @"pipelineBindPoint" VK_PIPELINE_BIND_POINT_GRAPHICS
        &* set @"colorAttachmentCount" 1
        &* setVkRef @"pColorAttachments" colorAttachmentRef
        &* setVkRef @"pDepthStencilAttachment" depthAttachmentRef
        &* ( if msaaOn then
               setVkRef @"pResolveAttachments" resolveAttachmentRef
             else
               set @"pResolveAttachments" VK_NULL
           )
        &* set @"pPreserveAttachments" VK_NULL
        &* set @"pInputAttachments" VK_NULL

      -- subpass dependencies
      dependency = createVk @VkSubpassDependency
        $  set @"srcSubpass" VK_SUBPASS_EXTERNAL
        &* set @"dstSubpass" 0
        &* set @"srcStageMask" VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
        &* set @"srcAccessMask" VK_ZERO_FLAGS
        &* set @"dstStageMask" VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
        &* set @"dstAccessMask"
            (   VK_ACCESS_COLOR_ATTACHMENT_READ_BIT
            .|. VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )

      -- render pass
      rpCreateInfo = createVk @VkRenderPassCreateInfo
        $  set @"sType" VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* setListCountAndRef @"attachmentCount" @"pAttachments"
            ([depthAttachment, colorAttachment] <> [resolveAttachment | msaaOn])
        &* set @"subpassCount" 1
        &* setVkRef @"pSubpasses" subpass
        &* set @"dependencyCount" 1
        &* setVkRef @"pDependencies" dependency

  in resource $ metaResource
       (\rp -> liftIO $ vkDestroyRenderPass dev rp VK_NULL) $
       withVkPtr rpCreateInfo $ \rpciPtr -> allocaPeek $
         runVk . vkCreateRenderPass dev rpciPtr VK_NULL


-- | expects private attachments first, followed by the color output attachment
createFramebuffer :: VkDevice
                  -> VkRenderPass
                  -> VkExtent2D
                  -> [VkImageView]
                  -> Resource r VkFramebuffer
createFramebuffer dev renderPass extent attachments =
  resource $ metaResource
    (\fb -> liftIO $ vkDestroyFramebuffer dev fb VK_NULL)
    (let fbci = createVk @VkFramebufferCreateInfo
            $  set @"sType" VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
            &* set @"pNext" VK_NULL
            &* set @"flags" VK_ZERO_FLAGS
            &* set @"renderPass" renderPass
            -- this needs to fit the renderpass attachments
            &* setListCountAndRef @"attachmentCount" @"pAttachments" attachments
            &* set @"width" (getField @"width" extent)
            &* set @"height" (getField @"height" extent)
            &* set @"layers" 1
      in allocaPeek $ \fbPtr -> withVkPtr fbci $ \fbciPtr ->
          runVk $ vkCreateFramebuffer dev fbciPtr VK_NULL fbPtr
    )


createRenderPassBeginInfo :: VkRenderPass -> VkFramebuffer -> VkExtent2D -> VkRenderPassBeginInfo
createRenderPassBeginInfo renderPass framebuffer extent =
  createVk @VkRenderPassBeginInfo
      $  set @"sType" VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
      &* set @"pNext" VK_NULL
      &* set @"renderPass" renderPass
      &* set @"framebuffer" framebuffer
      &* setVk @"renderArea"
          (  setVk @"offset"
              ( set @"x" 0 &* set @"y" 0 )
          &* set @"extent" extent
          )
      &* setListCountAndRef @"clearValueCount" @"pClearValues"
          -- This needs to fit the renderpass attachments. Clear values for
          -- attachments that don't use VK_ATTACHMENT_LOAD_OP_CLEAR in loadOp or
          -- stencilLoadOp are ignored.
          [ createVk @VkClearValue
             $ setVk @"depthStencil"
             -- this needs to fit pipeline settings regarding depth, including depthCompareOp
             $  set @"depth" 1.0
             &* set @"stencil" 0
          , createVk @VkClearValue
             $ setVk @"color"
             $ setVec @"float32" (vec4 0 0 0.2 1)
          ]
