-- 对话框协调器：InputDialog 创建、按钮回调、调用 workflow
local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local _ = require("gettext")

local Highlight = require("askgpt.highlight")
local Config    = require("askgpt.config")
local Util      = require("askgpt.util")
local Workflow  = require("askgpt.workflow")

local DialogController = {}

local input_dialog  -- 当前活动的输入对话框

function DialogController.show(ui, highlight_source)
  local highlighted_text, highlighted_context = Highlight.extract(highlight_source)

  local buttons = {
    {
      text = _("Cancel"),
      callback = function()
        UIManager:close(input_dialog)
      end,
    },
    {
      text = _("Ask"),
      callback = function()
        local question = input_dialog and Util.trim(input_dialog:getInputText()) or ""
        UIManager:close(input_dialog)
        Workflow.lookup(ui, {
          term             = highlighted_text,
          highlighted_text = highlighted_text,
          question         = question,
          action           = "ask",
          viewer_title     = _("Reader AI Dictionary"),
        }, highlighted_text)
      end,
    },
  }

  table.insert(buttons, {
    text = _("Summarize"),
    callback = function()
      local question = input_dialog and Util.trim(input_dialog:getInputText()) or ""
      UIManager:close(input_dialog)
      Workflow.summarize(ui, {
        content          = highlighted_text,
        highlighted_text = highlighted_text,
        prompt           = question,
        viewer_title     = _("Reader AI Summary"),
      }, highlighted_text)
    end,
  })

  table.insert(buttons, {
    text = _("Analyze"),
    callback = function()
      local focus_input = input_dialog and Util.trim(input_dialog:getInputText()) or ""
      UIManager:close(input_dialog)
      Workflow.analyze(ui, {
        content            = highlighted_text,
        highlighted_text   = highlighted_text,
        focus_points_input = focus_input,
        viewer_title       = _("Reader AI Analysis"),
      }, highlighted_text)
    end,
  })

  local target_language = Config.get_translate_target()
  if target_language then
    table.insert(buttons, {
      text = _("Dictionary"),
      callback = function()
        UIManager:close(input_dialog)
        Workflow.lookup(ui, {
          term                    = highlighted_text,
          highlighted_text        = highlighted_text,
          question                = _("Dictionary lookup with ") .. target_language .. _(" translation"),
          action                  = "dictionary",
          language                = target_language,
          request_language        = "auto",
          viewer_title            = _("Dictionary"),
          followup_language       = target_language,
          followup_request_language = "auto",
          context                 = highlighted_context,
          skip_context_question   = true,
        }, highlighted_text)
      end,
    })
  end

  input_dialog = InputDialog:new {
    title      = _("Ask a question about the highlighted text"),
    input_hint = _("Type your question here..."),
    input_type = "text",
    buttons    = { buttons },
  }
  UIManager:show(input_dialog)
end

return DialogController
