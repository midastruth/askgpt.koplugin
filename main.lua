local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local showChatGPTDialog = require("dialogs")
local UpdateChecker = require("update_checker")

local AskGPT = InputContainer:new {
  name = "askgpt",
  is_doc_only = true,
}

-- Flag to ensure the update message is shown only once per session
local updateMessageShown = false

-- 配置验证函数
local function validateConfiguration()
  local config_success, CONFIGURATION = pcall(function() return require("configuration") end)
  if not config_success then
    return false, "configuration.lua not found"
  end
  
  -- 检查必要的配置项
  if not CONFIGURATION.base_url and not CONFIGURATION.reader_ai_base_url then
    return false, "No API endpoint configured"
  end
  
  return true, CONFIGURATION
end

-- 网络状态检查函数
local function checkNetworkAndConfig()
  local config_valid, config_result = validateConfiguration()
  
  if not config_valid then
    UIManager:show(InfoMessage:new {
      text = _("AskGPT插件配置错误：") .. config_result .. _("\n请检查configuration.lua文件。"),
      timeout = 5
    })
    return false
  end
  
  -- 检查网络连接
  if not NetworkMgr:isOnline() then
    UIManager:show(InfoMessage:new {
      text = _("网络未连接，请检查网络设置后重试。"),
      timeout = 3
    })
    return false
  end
  
  return true
end

function AskGPT:init()
  self.ui.highlight:addToHighlightDialog("askgpt_ChatGPT", function(_reader_highlight_instance)
    return {
      text = _("Ask ChatGPT"),
      enabled = Device:hasClipboard(),
      callback = function()
        -- 先检查网络和配置
        if not checkNetworkAndConfig() then
          return
        end
        
        NetworkMgr:runWhenOnline(function()
          if not updateMessageShown then
            UpdateChecker.checkForUpdates()
            updateMessageShown = true -- Set flag to true so it won't show again
          end
          
          -- 安全地调用对话框函数
          local success, error_msg = pcall(function()
            showChatGPTDialog(self.ui, _reader_highlight_instance.selected_text.text)
          end)
          
          if not success then
            UIManager:show(InfoMessage:new {
              text = _("AskGPT运行失败：") .. tostring(error_msg),
              timeout = 5
            })
          end
        end)
      end,
    }
  end)
end

return AskGPT
