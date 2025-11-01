local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local ReaderAI = require("gpt_query")

local CONFIGURATION = nil
local input_dialog

local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

local function trim(text)
  return (text or ""):match("^%s*(.-)%s*$")
end

local function buildLookupContext(ui, highlighted_text, extra_context)
  local props = ui.document and ui.document:getProps() or {}
  local title = props.title or _("Unknown Title")
  local author = props.authors or _("Unknown Author")

  local parts = {
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

local function format_list(label, values)
  if type(values) ~= "table" then
    return nil
  end

  local cleaned = {}
  for _, value in ipairs(values) do
    if type(value) == "string" then
      local trimmed_value = trim(value)
      if trimmed_value ~= "" then
        table.insert(cleaned, trimmed_value)
      end
    end
  end

  if #cleaned == 0 then
    return nil
  end

  return label .. "\n- " .. table.concat(cleaned, "\n- ")
end

local function formatDictionaryBlock(args)
  local dictionary = args.dictionary or {}
  local segments = {}

  if args.highlighted_text and args.highlighted_text ~= "" then
    table.insert(segments, _("Highlighted text: ") .. "\"" .. args.highlighted_text .. "\"")
  end

  if args.question and args.question ~= "" then
    table.insert(segments, _("Question: ") .. args.question)
  end

  local entry_parts = {}
  local term_to_show = dictionary.term or args.term
  if term_to_show and term_to_show ~= "" then
    table.insert(entry_parts, _("Term: ") .. term_to_show)
  end

  if dictionary.pronunciation and dictionary.pronunciation ~= "" then
    table.insert(entry_parts, _("Pronunciation: ") .. dictionary.pronunciation)
  end

  if dictionary.part_of_speech and dictionary.part_of_speech ~= "" then
    table.insert(entry_parts, _("Part of speech: ") .. dictionary.part_of_speech)
  end

  if dictionary.definition and dictionary.definition ~= "" then
    table.insert(entry_parts, _("Definition: ") .. dictionary.definition)
  end

  local examples = format_list(_("Examples"), dictionary.examples)
  if examples then
    table.insert(entry_parts, examples)
  end

  local synonyms = format_list(_("Synonyms"), dictionary.synonyms)
  if synonyms then
    table.insert(entry_parts, synonyms)
  end

  local antonyms = format_list(_("Antonyms"), dictionary.antonyms)
  if antonyms then
    table.insert(entry_parts, antonyms)
  end

  if dictionary.notes and dictionary.notes ~= "" then
    table.insert(entry_parts, _("Notes: ") .. dictionary.notes)
  end

  if args.language and args.language ~= "" and args.language ~= "auto" then
    table.insert(entry_parts, _("Language: ") .. args.language)
  end

  if args.title or args.author then
    local document_info = _("Document: ") .. (args.title or _("Unknown Title"))
    if args.author and args.author ~= "" then
      document_info = document_info .. _(" by ") .. args.author
    end
    table.insert(entry_parts, document_info)
  end

  if #entry_parts > 0 then
    table.insert(segments, table.concat(entry_parts, "\n\n"))
  end

  if #segments == 0 then
    return _("No dictionary content available.")
  end

  return table.concat(segments, "\n\n")
end

local function formatSummaryBlock(args)
  local segments = {}

  if args.highlighted_text and args.highlighted_text ~= "" then
    table.insert(segments, _("Original text: ") .. "\"" .. args.highlighted_text .. "\"")
  end

  if args.prompt and args.prompt ~= "" then
    table.insert(segments, _("Instruction: ") .. args.prompt)
  end

  if args.summary and args.summary ~= "" then
    table.insert(segments, _("Summary: ") .. args.summary)
  end

  local details = args.details
  if type(details) == "table" then
    local key_points = format_list(_("Key points"), details.key_points or details.bullet_points)
    if key_points then
      table.insert(segments, key_points)
    end

    local highlights = format_list(_("Highlights"), details.highlights)
    if highlights then
      table.insert(segments, highlights)
    end

    if type(details.language) == "string" and details.language ~= "" then
      table.insert(segments, _("Language: ") .. details.language)
    end
  end

  if args.title or args.author then
    local document_info = _("Document: ") .. (args.title or _("Unknown Title"))
    if args.author and args.author ~= "" then
      document_info = document_info .. _(" by ") .. args.author
    end
    table.insert(segments, document_info)
  end

  if #segments == 0 then
    return _("No summary available.")
  end

  return table.concat(segments, "\n\n")
end

local function showLoadingDialog()
  local loading = InfoMessage:new{
    text = _("Loading..."),
    timeout = 0.1
  }
  UIManager:show(loading)
  return loading
end

local function showError(message)
  UIManager:show(InfoMessage:new { text = message })
end

local function performLookup(request_opts)
  local ok, response = pcall(ReaderAI.dictionaryLookup, request_opts)
  if not ok then
    local error_msg = tostring(response)
    if error_msg:match("timeout") then
      showError(_("网络请求超时，请检查网络连接后重试。"))
    elseif error_msg:match("connection") or error_msg:match("Failed to contact") then
      showError(_("无法连接到AI服务，请检查网络设置。"))
    elseif error_msg:match("attempts") then
      showError(_("网络连接失败，已重试" .. MAX_RETRY_ATTEMPTS .. "次。请检查网络后重试。"))
    else
      showError(_("字典查询失败：") .. error_msg)
    end
    return nil
  end
  if type(response) ~= "table" then
    showError(_("字典查询返回了未知格式。"))
    return nil
  end
  return response
end

local function performSummarize(request_opts)
  local ok, response = pcall(ReaderAI.summarizeContent, request_opts)
  if not ok then
    local error_msg = tostring(response)
    if error_msg:match("timeout") then
      showError(_("网络请求超时，请检查网络连接后重试。"))
    elseif error_msg:match("connection") or error_msg:match("Failed to contact") then
      showError(_("无法连接到AI服务，请检查网络设置。"))
    elseif error_msg:match("attempts") then
      showError(_("网络连接失败，已重试" .. MAX_RETRY_ATTEMPTS .. "次。请检查网络后重试。"))
    else
      showError(_("摘要生成失败：") .. error_msg)
    end
    return nil
  end
  if type(response) ~= "table" or type(response.summary) ~= "string" then
    showError(_("摘要返回格式无效。"))
    return nil
  end
  return response
end

local function showChatGPTDialog(ui, highlightedText)
  local props = ui.document and ui.document:getProps() or {}
  local title = props.title or _("Unknown Title")
  local author = props.authors or _("Unknown Author")
  local function startLookup(options)
    local blocks = {}
    local current_text = ""

    local loading = showLoadingDialog()
    UIManager:scheduleIn(0.1, function()
      if loading then
        UIManager:close(loading)
      end

      local question = trim(options.question)
      local context = buildLookupContext(ui, options.highlighted_text or highlightedText, question)
      if options.context and options.context ~= "" then
        context = context .. "\n" .. options.context
      end

      local request_term = trim(options.term)
      if request_term == "" then
        showError(_("词条不能为空。"))
        return
      end

      local dictionary = performLookup {
        term = request_term,
        language = options.language,
        context = context,
      }
      if not dictionary then
        return
      end

      local block = formatDictionaryBlock {
        highlighted_text = options.highlighted_text,
        question = question,
        term = request_term,
        dictionary = dictionary,
        language = options.language,
        title = title,
        author = author,
      }
      table.insert(blocks, block)
      current_text = table.concat(blocks, "\n\n")

      local chatgpt_viewer

      local function handleAddToNote(viewer)
        if not ui.highlight or not ui.highlight.addNote then
          showError(_("错误：无法找到高亮对象。"))
          return
        end

        ui.highlight:addNote(current_text)
        UIManager:close(viewer or chatgpt_viewer)
        if ui.highlight.onClose then
          ui.highlight:onClose()
        end
      end

      local function handleNewQuestion(viewer, new_term)
        local follow_term = trim(new_term)
        if follow_term == "" then
          return
        end

        local follow_context = buildLookupContext(ui, highlightedText, follow_term)
        local dictionary_follow = performLookup {
          term = follow_term,
          language = options.followup_language or options.language,
          context = follow_context,
        }
        if not dictionary_follow then
          return
        end

        local follow_block = formatDictionaryBlock {
          question = follow_term,
          term = follow_term,
          dictionary = dictionary_follow,
          language = options.followup_language or options.language,
          title = title,
          author = author,
        }
        table.insert(blocks, follow_block)
        current_text = table.concat(blocks, "\n\n")
        viewer:update(current_text)
      end

      chatgpt_viewer = ChatGPTViewer:new {
        ui = ui,
        title = options.viewer_title or _("Reader AI Dictionary"),
        text = current_text,
        onAskQuestion = handleNewQuestion,
        onAddToNote = handleAddToNote,
      }
      UIManager:show(chatgpt_viewer)
    end)
  end

  local function startSummarize(options)
    local blocks = {}
    local current_text = ""

    local loading = showLoadingDialog()
    UIManager:scheduleIn(0.1, function()
      if loading then
        UIManager:close(loading)
      end

      local prompt = trim(options.prompt)
      local base_content = options.content or options.highlighted_text or highlightedText
      local content = trim(base_content)

      if content == "" then
        showError(_("内容不能为空。"))
        return
      end

      local summary = performSummarize {
        content = content,
        language = options.language,
        context = prompt,
      }
      if not summary then
        return
      end

      local block = formatSummaryBlock {
        highlighted_text = options.highlighted_text or content,
        prompt = prompt,
        summary = summary.summary,
        details = summary.raw,
        language = options.language,
        title = title,
        author = author,
      }
      table.insert(blocks, block)
      current_text = table.concat(blocks, "\n\n")

      local chatgpt_viewer

      local function handleAddToNote(viewer)
        if not ui.highlight or not ui.highlight.addNote then
          showError(_("错误：无法找到高亮对象。"))
          return
        end

        ui.highlight:addNote(current_text)
        UIManager:close(viewer or chatgpt_viewer)
        if ui.highlight.onClose then
          ui.highlight:onClose()
        end
      end

      local function handleNewSummary(viewer, new_instruction)
        local follow_instruction = trim(new_instruction)
        if follow_instruction == "" then
          return
        end

        local summary_follow = performSummarize {
          content = content,
          language = options.language,
          context = follow_instruction,
        }
        if not summary_follow then
          return
        end

        local follow_block = formatSummaryBlock {
          highlighted_text = options.highlighted_text or content,
          prompt = follow_instruction,
          summary = summary_follow.summary,
          details = summary_follow.raw,
          language = options.language,
          title = title,
          author = author,
        }
        table.insert(blocks, follow_block)
        current_text = table.concat(blocks, "\n\n")
        viewer:update(current_text)
      end

      chatgpt_viewer = ChatGPTViewer:new {
        ui = ui,
        title = options.viewer_title or _("Reader AI Summary"),
        text = current_text,
        onAskQuestion = handleNewSummary,
        onAddToNote = handleAddToNote,
      }
      UIManager:show(chatgpt_viewer)
    end)
  end

  local function onAsk()
    local question = input_dialog and trim(input_dialog:getInputText()) or ""
    UIManager:close(input_dialog)
    startLookup {
      term = highlightedText,
      highlighted_text = highlightedText,
      question = question,
      viewer_title = _("Reader AI Dictionary"),
    }
  end

  local buttons = {
    {
      text = _("Cancel"),
      callback = function()
        UIManager:close(input_dialog)
      end,
    },
    {
      text = _("Ask"),
      callback = onAsk,
    },
  }

  table.insert(buttons, {
    text = _("Summarize"),
    callback = function()
      local question = input_dialog and trim(input_dialog:getInputText()) or ""
      UIManager:close(input_dialog)
      startSummarize {
        content = highlightedText,
        highlighted_text = highlightedText,
        prompt = question,
        viewer_title = _("Reader AI Summary"),
      }
    end,
  })

  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.translate_to and CONFIGURATION.features.translate_to ~= "" then
    local target_language = CONFIGURATION.features.translate_to
    table.insert(buttons, {
      text = _("Translate"),
      callback = function()
        UIManager:close(input_dialog)
        startLookup {
          term = highlightedText,
          highlighted_text = highlightedText,
          question = _("Translate to ") .. target_language,
          language = target_language,
          viewer_title = _("Translation"),
          followup_language = target_language,
        }
      end,
    })
  end

  input_dialog = InputDialog:new {
    title = _("Ask a question about the highlighted text"),
    input_hint = _("Type your question here..."),
    input_type = "text",
    buttons = { buttons },
  }
  UIManager:show(input_dialog)
end

return showChatGPTDialog
