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
local BookSync         = require("askgpt.book_sync")
local UpdateChecker    = require("update_checker")
local AnnotationSync   = require("askgpt.annotation_sync")

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

local function autoSyncEnabled()
  local cfg = Config.get()
  return type(cfg) == "table"
      and (cfg.reader_ai_auto_sync_books == true
           or cfg.book_aware_auto_sync == true)
end

local function autoSyncWebHighlightsEnabled()
  local cfg = Config.get()
  return type(cfg) == "table" and cfg.auto_sync_web_highlights == true
end

local function placeAskGPTBeforeToc()
  local ok, order = pcall(require, "ui/elements/reader_menu_order")
  if not ok or type(order) ~= "table" or type(order.navi) ~= "table" then
    return false
  end

  for i = #order.navi, 1, -1 do
    if order.navi[i] == "askgpt" then
      table.remove(order.navi, i)
    end
  end

  local insert_at = 1
  for i, item_id in ipairs(order.navi) do
    if item_id == "table_of_contents" then
      insert_at = i
      break
    end
  end
  table.insert(order.navi, insert_at, "askgpt")
  return true
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

  if autoSyncEnabled() then
    UIManager:scheduleIn(2, function()
      if not checkNetworkAndConfig() then return end
      NetworkMgr:runWhenOnline(function()
        BookSync.sync_all(self.ui)
      end)
    end)
  end

  if autoSyncWebHighlightsEnabled() then
    UIManager:scheduleIn(3, function()
      if self._auto_synced_sha then return end
      local cfg_ok = Config.validate()
      if not cfg_ok then return end
      NetworkMgr:runWhenOnline(function()
        if self._auto_synced_sha then return end
        self._auto_synced_sha = true
        local ok, err = pcall(AnnotationSync.sync, self.ui)
        if not ok then
          print("[book-aware] auto sync web highlights failed: " .. tostring(err))
        end
      end)
    end)
  end
end

-- Push local note/color changes during save/close (silent, best-effort).
local function pushWebHighlightChanges(self, reason)
  if not autoSyncWebHighlightsEnabled() then return end
  if isFileManagerUI(self.ui) then return end
  local cfg_ok = Config.validate()
  if not cfg_ok then return end
  if not NetworkMgr:isOnline() then return end
  local ok, err = pcall(AnnotationSync.push_changes_only, self.ui)
  if not ok then
    print("[book-aware] auto push on " .. tostring(reason) .. " failed: " .. tostring(err))
  end
end

function AskGPT:onSaveSettings()
  pushWebHighlightChanges(self, "save")
end

function AskGPT:onCloseDocument()
  pushWebHighlightChanges(self, "close")
end

-- AskGPT 入口：阅读器中放到 Navigation/导航 菜单的目录上方；文件管理器中仍放到 Tools/工具。
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
    text = _("Book-Aware book sync"),
    callback = function()
      if not checkNetworkAndConfig() then return end
      NetworkMgr:runWhenOnline(function()
        BookSync.show(self.ui)
      end)
    end,
  })

  if not isFileManagerUI(self.ui) then
    table.insert(askgpt_items, {
      text = _("Sync web highlights"),
      callback = function()
        if not checkNetworkAndConfig() then return end
        NetworkMgr:runWhenOnline(function()
          UIManager:show(InfoMessage:new {
            text    = _("正在同步 Web 高亮..."),
            timeout = 1,
          })
          local ok, result = pcall(AnnotationSync.sync, self.ui)
          if not ok then
            UIManager:show(InfoMessage:new {
              text    = _("Web 高亮同步失败：") .. tostring(result),
              timeout = 8,
            })
          else
            UIManager:show(InfoMessage:new {
              text = string.format(
                _("Web 高亮同步完成。\n同步：%d  推送：%d  删除：%d\n冲突：%d  失败：%d"),
                result.resolved, result.pushed or 0, result.removed or 0,
                result.conflict, result.failed
              ),
              timeout = (result.failed or 0) > 0 and 8 or 5,
            })
          end
        end)
      end,
    })
  end

  if not isFileManagerUI(self.ui) then
    table.insert(askgpt_items, {
      text = _("View conflict highlights"),
      callback = function()
        if not checkNetworkAndConfig() then return end
        NetworkMgr:runWhenOnline(function()
          local ok, data = pcall(AnnotationSync.list_conflicts, self.ui)
          if not ok then
            UIManager:show(InfoMessage:new {
              text    = _("无法获取冲突高亮：") .. tostring(data),
              timeout = 6,
            })
            return
          end
          if #data == 0 then
            UIManager:show(InfoMessage:new {
              text    = _("无冲突高亮。"),
              timeout = 3,
            })
            return
          end
          local lines = {}
          for i, hl in ipairs(data) do
            local excerpt = (type(hl.exact) == "string" and #hl.exact > 0)
              and hl.exact:sub(1, 60) or "?"
            local err = (hl.koreader and type(hl.koreader.error) == "string")
              and hl.koreader.error:sub(1, 120) or ""
            table.insert(lines, string.format(
              "%d. \"%s\"\n   %s", i, excerpt, err))
          end
          UIManager:show(InfoMessage:new {
            text = string.format(
              _("冲突高亮（%d）：\n\n%s"), #data, table.concat(lines, "\n\n")),
            timeout = 15,
          })
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

  local sorting_hint = "tools"
  if not isFileManagerUI(self.ui) then
    placeAskGPTBeforeToc()
    sorting_hint = "navi"
  end

  menu_items.askgpt = {
    text = _("AskGPT"),
    sorting_hint = sorting_hint,
    sub_item_table = askgpt_items,
  }
end

return AskGPT
