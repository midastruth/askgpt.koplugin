-- 任务执行入口：lookup / summarize / analyze
-- lookup 同步；summarize / analyze 路由到 background_jobs（子进程）
local UIManager     = require("ui/uimanager")
local InfoMessage   = require("ui/widget/infomessage")
local ChatGPTViewer = require("chatgptviewer")
local _ = require("gettext")

local AiClient         = require("askgpt.ai_client")
local Errors           = require("askgpt.errors")
local Formatter        = require("askgpt.formatter")
local Util             = require("askgpt.util")
local BackgroundJobs   = require("askgpt.background_jobs")

local Workflow = {}

-- ── 私有工具 ─────────────────────────────────────────────────────────────────

local function show_loading()
  local loading = InfoMessage:new { text = _("Loading..."), timeout = 0.1 }
  UIManager:show(loading)
  return loading
end

local function get_doc_props(ui)
  local props = ui.document and ui.document:getProps() or {}
  return props.title or nil, props.authors or nil
end

local function build_lookup_context(ui, highlighted_text, extra_context)
  local props  = ui.document and ui.document:getProps() or {}
  local title  = props.title   or _("Unknown Title")
  local author = props.authors or _("Unknown Author")
  local parts  = {
    _("Document title: ") .. title,
    _("Author: ") .. author,
  }
  if highlighted_text and highlighted_text ~= "" then
    table.insert(parts, _("Highlighted text: ") .. highlighted_text)
  end
  if extra_context and extra_context ~= "" then
    table.insert(parts, _("User request: ") .. extra_context)
  end
  return table.concat(parts, "\n")
end

-- ── 核心 helper ───────────────────────────────────────────────────────────────
--
-- spec 字段:
--   ui            KOReader UI 引用
--   viewer_title  string
--   call_ai       function() -> block_string | nil
--                   nil 表示失败（函数内部已调用 Errors.show*）
--   call_followup function(trimmed_input) -> block_string | nil
--                   nil 表示失败或静默跳过
--
local function run_viewer_workflow(spec)
  local blocks       = {}
  local current_text = ""

  local loading = show_loading()
  UIManager:scheduleIn(0.1, function()
    if loading then UIManager:close(loading) end

    local block = spec.call_ai()
    if not block then return end

    table.insert(blocks, block)
    current_text = table.concat(blocks, "\n\n")

    local chatgpt_viewer

    local function handleAddToNote(viewer)
      if not spec.ui.highlight or not spec.ui.highlight.addNote then
        Errors.show(_("错误：无法找到高亮对象。"))
        return
      end
      spec.ui.highlight:addNote(current_text)
      UIManager:close(viewer or chatgpt_viewer)
      if spec.ui.highlight.onClose then spec.ui.highlight:onClose() end
    end

    local function handleFollowUp(viewer, input)
      local trimmed = Util.trim(input or "")
      if trimmed == "" then return end
      local follow_block = spec.call_followup(trimmed)
      if not follow_block then return end
      table.insert(blocks, follow_block)
      current_text = table.concat(blocks, "\n\n")
      viewer:update(current_text)
    end

    chatgpt_viewer = ChatGPTViewer:new {
      ui            = spec.ui,
      title         = spec.viewer_title,
      text          = current_text,
      onAskQuestion = handleFollowUp,
      onAddToNote   = handleAddToNote,
    }
    UIManager:show(chatgpt_viewer)
  end)
end

-- ── Lookup (字典) ─────────────────────────────────────────────────────────────

-- options: term, highlighted_text, question, language, request_language,
--          context, skip_context_question, viewer_title,
--          followup_language, followup_request_language
function Workflow.lookup(ui, options, default_highlighted)
  local request_term = Util.trim(options.term or "")
  if request_term == "" then
    Errors.show(_("词条不能为空。"))
    return
  end

  local question          = Util.trim(options.question or "")
  local base_context      = type(options.context) == "string"
                            and Util.trim(options.context) or ""
  local skip_ctx_question = options.skip_context_question
  local request_language  = options.request_language or options.language
  local doc_title, doc_author = get_doc_props(ui)

  local function compose_context(prompt_text)
    local trimmed = Util.trim(prompt_text)
    if base_context ~= "" then
      if trimmed ~= "" and not skip_ctx_question then
        return base_context .. "\n" .. trimmed
      end
      return base_context
    end
    return build_lookup_context(ui, options.highlighted_text or default_highlighted, trimmed)
  end

  run_viewer_workflow({
    ui           = ui,
    viewer_title = options.viewer_title or _("Reader AI Dictionary"),

    call_ai = function()
      local ok, dictionary = pcall(AiClient.dictionaryLookup, {
        term     = request_term,
        language = request_language,
        context  = compose_context(question),
      })
      if not ok then
        Errors.show_request_error(dictionary, _("字典查询"))
        return nil
      end
      if type(dictionary) ~= "table" then
        Errors.show(_("字典查询返回了未知格式。"))
        return nil
      end
      return Formatter.dictionary {
        highlighted_text = options.highlighted_text,
        question         = question,
        term             = request_term,
        dictionary       = dictionary,
        language         = options.language,
        title            = doc_title,
        author           = doc_author,
      }
    end,

    call_followup = function(input)
      local follow_lang     = options.followup_language or options.language
      local follow_req_lang = options.followup_request_language
                              or options.request_language or follow_lang
      local ok2, dict_follow = pcall(AiClient.dictionaryLookup, {
        term     = input,
        language = follow_req_lang,
        context  = compose_context(input),
      })
      if not ok2 then
        Errors.show_request_error(dict_follow, _("字典查询"))
        return nil
      end
      return Formatter.dictionary {
        question   = input,
        term       = input,
        dictionary = dict_follow,
        language   = follow_lang,
        title      = doc_title,
        author     = doc_author,
      }
    end,
  })
end

-- ── Summarize → 后台执行 ──────────────────────────────────────────────────────

-- 提交摘要到后台子进程；立即返回，不阻塞 UI
-- options: content, highlighted_text, prompt, language, viewer_title
function Workflow.summarize(ui, options, default_highlighted)
  local doc_title, doc_author = get_doc_props(ui)
  BackgroundJobs.submit_summary(ui, options, default_highlighted, doc_title, doc_author)
end

-- ── Analyze → 后台执行 ────────────────────────────────────────────────────────

-- 提交分析到后台子进程；立即返回，不阻塞 UI
-- options: content, highlighted_text, focus_points_input, language, viewer_title
function Workflow.analyze(ui, options, default_highlighted)
  local doc_title, doc_author = get_doc_props(ui)
  BackgroundJobs.submit_analyze(ui, options, default_highlighted, doc_title, doc_author)
end

return Workflow
