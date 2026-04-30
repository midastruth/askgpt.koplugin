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
  is_doc_only = false,
}

local updateMessageShown = false

local function isFileManagerUI(ui)
  return ui and type(ui.addFileDialogButtons) == "function"
end

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
  self.ui.menu:registerToMainMenu(self)

  -- 文件管理器：长按书籍文件弹出"上传到 Book-Aware"按钮
  -- 注意：FileManager 加载插件时 file_chooser 可能尚未创建，不能用
  -- self.ui.file_chooser 判断；addFileDialogButtons 方法才是稳定特征。
  if isFileManagerUI(self.ui) then
    self.ui:addFileDialogButtons("askgpt_upload_file", function(file, is_file)
      if not is_file then return end
      local ext = tostring(file or ""):lower():match("%.([^.]+)$")
      if ext ~= "epub" then return end
      return {
        {
          text = _("Upload to Book-Aware"),
          callback = function()
            if not checkNetworkAndConfig() then return end
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenOnline(function()
              BookUpload.upload_file(file)
            end)
          end,
        },
      }
    end)
    return
  end

  if not self.ui.highlight or type(self.ui.highlight.addToHighlightDialog) ~= "function" then
    return
  end

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

-- AskGPT 入口：统一放到 Tools/工具 菜单下的 AskGPT 子菜单
function AskGPT:addToMainMenu(menu_items)
  local askgpt_items = {
    {
      text = _("Recent results"),
      callback = function()
        local ok, err = pcall(function()
          BackgroundJobs.show_results_menu(self.ui)
        end)
        if not ok then
          UIManager:show(InfoMessage:new {
            text    = _("打开 AskGPT 最近结果失败：") .. tostring(err),
            timeout = 6,
          })
        end
      end,
    },
  }

  if not isFileManagerUI(self.ui) then
    table.insert(askgpt_items, {
      text = _("Upload current book to Book-Aware"),
      callback = function()
        if not checkNetworkAndConfig() then return end
        NetworkMgr:runWhenOnline(function()
          BookUpload.upload_current(self.ui)
        end)
      end,
    })
  end

  table.insert(askgpt_items, {
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
  })

  menu_items.askgpt = {
    text = _("AskGPT"),
    sorting_hint = "tools",
    sub_item_table = askgpt_items,
  }
end

return AskGPT
