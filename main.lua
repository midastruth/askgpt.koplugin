local Device       = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr   = require("ui/network/manager")
local InfoMessage  = require("ui/widget/infomessage")
local UIManager    = require("ui/uimanager")
local _ = require("gettext")

local Config           = require("askgpt.config")
local DialogController = require("askgpt.dialog_controller")
local BackgroundJobs   = require("askgpt.background_jobs")
local BookUpload       = require("askgpt.book_upload")
local UpdateChecker    = require("update_checker")

local AskGPT = InputContainer:new {
  name        = "askgpt",
  is_doc_only = true,
}

local updateMessageShown = false

local function autoUploadEnabled()
  local cfg = Config.get()
  return type(cfg) == "table"
      and (cfg.reader_ai_auto_upload_book == true
           or cfg.book_aware_auto_upload == true)
end

local function checkNetworkAndConfig()
  local config_valid, config_result = Config.validate()
  if not config_valid then
    UIManager:show(InfoMessage:new {
      text    = _("AskGPT插件配置错误：") .. config_result .. _("\n请检查configuration.lua文件。"),
      timeout = 5,
    })
    return false
  end
  if not NetworkMgr:isOnline() then
    UIManager:show(InfoMessage:new {
      text    = _("网络未连接，请检查网络设置后重试。"),
      timeout = 3,
    })
    return false
  end
  return true
end

function AskGPT:init()
  -- 注册主菜单条目（AskGPT Recent Results），必须在 init 里调用
  self.ui.menu:registerToMainMenu(self)

  self.ui.highlight:addToHighlightDialog("askgpt_GPT", function(_reader_highlight_instance)
    return {
      text    = _("Ask GPT"),
      enabled = Device:hasClipboard(),
      callback = function()
        if not checkNetworkAndConfig() then return end
        NetworkMgr:runWhenOnline(function()
          if not updateMessageShown then
            UpdateChecker.checkForUpdates()
            updateMessageShown = true
          end
          local success, error_msg = pcall(function()
            DialogController.show(self.ui, _reader_highlight_instance)
          end)
          if not success then
            UIManager:show(InfoMessage:new {
              text    = _("AskGPT运行失败：") .. tostring(error_msg),
              timeout = 5,
            })
          end
        end)
      end,
    }
  end)

  if autoUploadEnabled() then
    UIManager:scheduleIn(1, function()
      if not checkNetworkAndConfig() then return end
      NetworkMgr:runWhenOnline(function()
        BookUpload.upload_current(self.ui)
      end)
    end)
  end
end

-- "稍后查看"入口：在 Reader 主菜单注册 AskGPT Results 条目
function AskGPT:addToMainMenu(menu_items)
  menu_items.askgpt_upload_book = {
    text = _("Upload current book to Book-Aware"),
    callback = function()
      if not checkNetworkAndConfig() then return end
      NetworkMgr:runWhenOnline(function()
        BookUpload.upload_current(self.ui)
      end)
    end,
  }

  menu_items.askgpt_update = {
    text = _("检查 AskGPT 更新"),
    callback = function()
      if not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new {
          text    = _("网络未连接，请检查网络设置后重试。"),
          timeout = 3,
        })
        return
      end
      NetworkMgr:runWhenOnline(function()
        UpdateChecker.checkAndPromptInstall()
      end)
    end,
  }

  menu_items.askgpt_results = {
    text = _("AskGPT Recent Results"),
    callback = function()
      BackgroundJobs.show_results_menu(self.ui)
    end,
  }
end

return AskGPT
