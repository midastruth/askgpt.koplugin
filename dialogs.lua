--[[--
AskGPT对话管理模块 - UI工作流协调器
负责处理用户界面交互、AI服务调用协调和响应显示

主要功能：
- 处理高亮文本数据提取和上下文构建
- 管理字典查询、文本摘要和翻译工作流
- 格式化AI响应内容的显示
- 提供用户交互界面（输入对话框、查看器等）
- 处理错误信息和加载状态显示

依赖的KOReader UI组件：
- InputDialog: 用户输入对话框
- ChatGPTViewer: AI响应查看器（自定义组件）
- UIManager: UI管理器
- InfoMessage: 信息提示组件
]]

local InputDialog = require("ui/widget/inputdialog")  -- 用户输入对话框组件
local ChatGPTViewer = require("chatgptviewer")        -- AI响应查看器组件
local UIManager = require("ui/uimanager")             -- UI管理器
local InfoMessage = require("ui/widget/infomessage")   -- 信息提示组件
local _ = require("gettext")                          -- 国际化支持

local ReaderAI = require("gpt_query")                 -- AI服务客户端模块

--[[--
全局变量定义
- CONFIGURATION: 用户配置信息
- input_dialog: 当前活动的输入对话框实例
]]
local CONFIGURATION = nil
local input_dialog

-- 安全加载用户配置文件
local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

--[[--
工具函数：去除字符串首尾空白字符
@param text string|nil 待处理的字符串
@return string 去除首尾空格后的字符串，如果输入为nil则返回空字符串
]]
local function trim(text)
  return (text or ""):match("^%s*(.-)%s*$")
end

--[[--
从KOReader高亮数据中提取文本内容和上下文
KOReader的高亮数据结构复杂，可能包含多种格式和嵌套结构
此函数负责统一处理这些不同的数据格式，提取出有用的文本信息

支持的数据结构：
- 字符串类型：直接作为高亮文本
- 表类型：可能包含 selected_text、text、before、selection、after 等字段
- 嵌套表：递归提取字符串内容

@param source string|table KOReader提供的高亮数据源
@return string, string 高亮文本, 上下文文本
]]
local function extract_highlight_data(source)
  local highlighted_text = ""
  local context_text = nil

  --[[--
  内部函数：从复杂数据结构中提取字符串内容
  递归处理嵌套的表结构，查找可用的文本内容

  支持的字段优先级：
  1. 直接字符串值
  2. value.text 字段
  3. before + selection + after 组合
  4. 数组中的第一个有效字符串

  @param value any 待提取的值
  @return string|nil 提取的字符串，如果无法提取则返回nil
  ]]
  local function extract_string(value)
    -- 直接返回字符串类型的值
    if type(value) == "string" then
      return value
    elseif type(value) == "table" then
      -- 优先使用 text 字段
      if type(value.text) == "string" then
        return value.text
      end

      -- 尝试组合 before、selection、after 字段（用于处理选择上下文）
      local before = type(value.before) == "string" and value.before or nil
      local selection = type(value.selection) == "string" and value.selection or nil
      local after = type(value.after) == "string" and value.after or nil
      if before or selection or after then
        local parts = {}
        if before and before ~= "" then
          table.insert(parts, before)
        end
        if selection and selection ~= "" then
          table.insert(parts, selection)
        end
        if after and after ~= "" then
          table.insert(parts, after)
        end
        if #parts > 0 then
          return table.concat(parts, " ")
        end
      end

      -- 遍历数组，查找第一个有效字符串
      for _, item in ipairs(value) do
        if type(item) == "string" and item ~= "" then
          return item
        end
      end
    end
    return nil
  end

  -- 处理表类型的高亮数据源
  if type(source) == "table" then
    local selected = source.selected_text or source
    if type(selected) == "table" then
      -- 提取主要的高亮文本
      highlighted_text = selected.text or highlighted_text

      -- 按优先级尝试获取上下文信息
      -- 这些字段名对应KOReader可能提供的不同类型的上下文数据
      local candidates = {
        selected.context,           -- 通用上下文
        selected.paragraph,         -- 段落上下文
        selected.sentence,          -- 句子上下文
        selected.snippet,           -- 文本片段
        selected.selection_context, -- 选择上下文
        selected.text_block,        -- 文本块
        selected.full_text,         -- 完整文本
        selected.extended_text,     -- 扩展文本
      }

      -- 使用第一个可用的上下文数据
      for _, candidate in ipairs(candidates) do
        local candidate_text = extract_string(candidate)
        if candidate_text and candidate_text ~= "" then
          context_text = candidate_text
          break
        end
      end
    end
  elseif type(source) == "string" then
    -- 直接处理字符串类型的数据源
    highlighted_text = source
  end

  -- 清理和标准化提取的文本
  highlighted_text = trim(highlighted_text)

  -- 如果没有找到独立的上下文，使用高亮文本作为上下文
  if not context_text or context_text == "" then
    context_text = highlighted_text
  end

  return highlighted_text, trim(context_text)
end

--[[--
构建AI查询的上下文信息
将文档信息、高亮文本和用户请求组合成结构化的上下文，
帮助AI更好地理解查询背景和提供准确的回答

包含的信息：
- 文档标题和作者（来自文档元数据）
- 高亮的文本内容
- 用户的具体问题或请求

@param ui table KOReader的UI实例，用于获取文档信息
@param highlighted_text string 用户高亮的文本内容
@param extra_context string 用户输入的额外上下文或问题
@return string 格式化的上下文字符串，用于发送给AI服务
]]
local function buildLookupContext(ui, highlighted_text, extra_context)
  -- 获取文档属性信息
  local props = ui.document and ui.document:getProps() or {}
  local title = props.title or _("Unknown Title")
  local author = props.authors or _("Unknown Author")

  -- 构建上下文信息的各个部分
  local parts = {
    _("Document title: ") .. title,
    _("Author: ") .. author,
  }

  -- 添加高亮文本信息
  if highlighted_text and highlighted_text ~= "" then
    table.insert(parts, _("Highlighted text: ") .. highlighted_text)
  end

  -- 添加用户的具体请求
  if extra_context and extra_context ~= "" then
    table.insert(parts, _("User request: ") .. extra_context)
  end

  -- 将所有部分用换行符连接
  return table.concat(parts, "\n")
end

--[[--
格式化字符串列表为用户友好的显示格式
将数组转换为带标签的项目列表，用于显示例句、同义词等信息

处理步骤：
1. 验证输入数据类型
2. 清理数组中的字符串项目（去空格、过滤空值）
3. 格式化为带有项目符号的列表

@param label string 列表的标签名称
@param values table|nil 字符串数组
@return string|nil 格式化的列表字符串，如果没有有效项目则返回nil

示例输出：
"Examples
- This is an example sentence.
- Another example here."
]]
local function format_list(label, values)
  -- 验证输入参数类型
  if type(values) ~= "table" then
    return nil
  end

  -- 清理数组中的字符串项目
  local cleaned = {}
  for _, value in ipairs(values) do
    if type(value) == "string" then
      local trimmed_value = trim(value)
      if trimmed_value ~= "" then
        table.insert(cleaned, trimmed_value)
      end
    end
  end

  -- 如果没有有效的项目，返回nil
  if #cleaned == 0 then
    return nil
  end

  -- 格式化为带项目符号的列表
  return label .. "\n- " .. table.concat(cleaned, "\n- ")
end

--[[--
格式化字典查询结果为用户可读的显示块
将AI返回的字典数据转换为结构化的显示格式

包含的信息：
- 用户查询的上下文（高亮文本、问题）
- 词典条目信息（词条、发音、词性、定义）
- 相关信息（例句、同义词、反义词、备注）
- 元数据（语言、文档信息）

@param args table 格式化参数，包含以下字段：
  - highlighted_text: 高亮文本
  - question: 用户问题
  - term: 查询词条
  - dictionary: AI返回的字典数据
  - language: 目标语言
  - title, author: 文档信息
@return string 格式化的显示文本
]]
local function formatDictionaryBlock(args)
  local dictionary = args.dictionary or {}
  local segments = {}

  -- 添加查询上下文信息
  if args.highlighted_text and args.highlighted_text ~= "" then
    table.insert(segments, _("Highlighted text: ") .. "\"" .. args.highlighted_text .. "\"")
  end

  if args.question and args.question ~= "" then
    table.insert(segments, _("Question: ") .. args.question)
  end

  -- 构建字典条目信息
  local entry_parts = {}

  -- 词条名称（优先使用AI返回的词条，回退到用户输入的词条）
  local term_to_show = dictionary.term or args.term
  if term_to_show and term_to_show ~= "" then
    table.insert(entry_parts, _("Term: ") .. term_to_show)
  end

  -- 发音信息
  if dictionary.pronunciation and dictionary.pronunciation ~= "" then
    table.insert(entry_parts, _("Pronunciation: ") .. dictionary.pronunciation)
  end

  -- 词性
  if dictionary.part_of_speech and dictionary.part_of_speech ~= "" then
    table.insert(entry_parts, _("Part of speech: ") .. dictionary.part_of_speech)
  end

  -- 定义（核心内容）
  if dictionary.definition and dictionary.definition ~= "" then
    table.insert(entry_parts, _("Definition: ") .. dictionary.definition)
  end

  -- 格式化相关信息列表
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

  -- 备注信息
  if dictionary.notes and dictionary.notes ~= "" then
    table.insert(entry_parts, _("Notes: ") .. dictionary.notes)
  end

  -- 语言信息（仅在非自动检测时显示）
  if args.language and args.language ~= "" and args.language ~= "auto" then
    table.insert(entry_parts, _("Language: ") .. args.language)
  end

  -- 文档来源信息
  if args.title or args.author then
    local document_info = _("Document: ") .. (args.title or _("Unknown Title"))
    if args.author and args.author ~= "" then
      document_info = document_info .. _(" by ") .. args.author
    end
    table.insert(entry_parts, document_info)
  end

  -- 组装最终的显示内容
  if #entry_parts > 0 then
    table.insert(segments, table.concat(entry_parts, "\n\n"))
  end

  -- 处理空结果的情况
  if #segments == 0 then
    return _("No dictionary content available.")
  end

  return table.concat(segments, "\n\n")
end

--[[--
格式化文本摘要结果为用户可读的显示块
将AI返回的摘要数据转换为结构化的显示格式

包含的信息：
- 原始文本内容
- 用户的摘要指令
- AI生成的摘要内容
- 详细信息（要点、亮点等）
- 文档来源信息

@param args table 格式化参数，包含以下字段：
  - highlighted_text: 原始高亮文本
  - prompt: 用户的摘要指令
  - summary: AI生成的摘要
  - details: AI返回的详细信息（可能包含key_points、highlights等）
  - language: 语言信息
  - title, author: 文档信息
@return string 格式化的显示文本
]]
local function formatSummaryBlock(args)
  local segments = {}

  -- 添加原始文本信息
  if args.highlighted_text and args.highlighted_text ~= "" then
    table.insert(segments, _("Original text: ") .. "\"" .. args.highlighted_text .. "\"")
  end

  -- 添加用户的摘要指令
  if args.prompt and args.prompt ~= "" then
    table.insert(segments, _("Instruction: ") .. args.prompt)
  end

  -- 添加AI生成的摘要（核心内容）
  if args.summary and args.summary ~= "" then
    table.insert(segments, _("Summary: ") .. args.summary)
  end

  -- 处理AI返回的详细信息
  local details = args.details
  if type(details) == "table" then
    -- 格式化关键要点
    local key_points = format_list(_("Key points"), details.key_points or details.bullet_points)
    if key_points then
      table.insert(segments, key_points)
    end

    -- 格式化重要亮点
    local highlights = format_list(_("Highlights"), details.highlights)
    if highlights then
      table.insert(segments, highlights)
    end

    -- 添加语言信息
    if type(details.language) == "string" and details.language ~= "" then
      table.insert(segments, _("Language: ") .. details.language)
    end
  end

  -- 添加文档来源信息
  if args.title or args.author then
    local document_info = _("Document: ") .. (args.title or _("Unknown Title"))
    if args.author and args.author ~= "" then
      document_info = document_info .. _(" by ") .. args.author
    end
    table.insert(segments, document_info)
  end

  -- 处理空结果的情况
  if #segments == 0 then
    return _("No summary available.")
  end

  return table.concat(segments, "\n\n")
end

--[[--
格式化文本分析结果为用户可读的显示块
将AI返回的分析数据转换为结构化的显示格式

包含的信息：
- 原始文本内容
- 用户的分析重点
- AI生成的分析结果
- 详细信息（关键词、情感分析、主题等）
- 文档来源信息

@param args table 格式化参数，包含以下字段：
  - highlighted_text: 原始高亮文本
  - focus_points: 用户的分析重点
  - analysis: AI返回的分析结果
  - language: 语言信息
  - title, author: 文档信息
@return string 格式化的显示文本
]]
local function formatAnalysisBlock(args)
  local segments = {}
  local analysis = args.analysis or {}

  -- 添加原始文本信息
  if args.highlighted_text and args.highlighted_text ~= "" then
    table.insert(segments, _("Original text: ") .. "\"" .. args.highlighted_text .. "\"")
  end

  -- 添加用户的分析重点
  if args.focus_points and type(args.focus_points) == "table" and #args.focus_points > 0 then
    local focus_text = _("Focus points: ") .. table.concat(args.focus_points, ", ")
    table.insert(segments, focus_text)
  end

  -- 添加AI生成的主要分析结果
  if analysis.analysis and analysis.analysis ~= "" then
    table.insert(segments, _("Analysis: ") .. analysis.analysis)
  end

  -- 处理AI返回的详细信息
  if type(analysis) == "table" then
    -- 格式化关键词
    if analysis.keywords or analysis.key_words then
      local keywords = analysis.keywords or analysis.key_words
      if type(keywords) == "table" and #keywords > 0 then
        local keywords_text = _("Keywords: ") .. table.concat(keywords, ", ")
        table.insert(segments, keywords_text)
      end
    end

    -- 格式化主题
    if analysis.themes or analysis.topics then
      local themes = analysis.themes or analysis.topics
      local themes_formatted = format_list(_("Themes"), themes)
      if themes_formatted then
        table.insert(segments, themes_formatted)
      end
    end

    -- 格式化情感分析
    if analysis.sentiment then
      table.insert(segments, _("Sentiment: ") .. analysis.sentiment)
    end

    -- 格式化重要观点
    local key_points = format_list(_("Key points"), analysis.key_points or analysis.main_points)
    if key_points then
      table.insert(segments, key_points)
    end

    -- 添加分析摘要
    if analysis.summary and analysis.summary ~= "" then
      table.insert(segments, _("Summary: ") .. analysis.summary)
    end
  end

  -- 添加文档来源信息
  if args.title or args.author then
    local document_info = _("Document: ") .. (args.title or _("Unknown Title"))
    if args.author and args.author ~= "" then
      document_info = document_info .. _(" by ") .. args.author
    end
    table.insert(segments, document_info)
  end

  -- 处理空结果的情况
  if #segments == 0 then
    return _("No analysis available.")
  end

  return table.concat(segments, "\n\n")
end

--[[--
显示加载提示对话框
在AI请求处理期间向用户显示加载状态，提升用户体验

@return table InfoMessage实例，可用于后续关闭操作
]]
local function showLoadingDialog()
  local loading = InfoMessage:new{
    text = _("Loading..."),
    timeout = 0.1  -- 短暂超时，主要通过代码控制显示和关闭
  }
  UIManager:show(loading)
  return loading
end

--[[--
显示错误信息对话框
向用户显示操作失败或异常的错误信息

@param message string 要显示的错误消息
]]
local function showError(message)
  UIManager:show(InfoMessage:new { text = message })
end

--[[--
执行字典查询并处理错误
封装对ReaderAI.dictionaryLookup的调用，提供统一的错误处理和用户友好的错误消息

错误类型处理：
- timeout: 网络超时错误
- connection: 连接失败错误
- attempts: 重试次数耗尽
- 其他: 通用错误信息

@param request_opts table 字典查询参数
@return table|nil 查询结果，失败时返回nil
]]
local function performLookup(request_opts)
  local ok, response = pcall(ReaderAI.dictionaryLookup, request_opts)
  if not ok then
    local error_msg = tostring(response)
    -- 根据错误类型显示相应的用户友好消息
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

  -- 验证响应数据格式
  if type(response) ~= "table" then
    showError(_("字典查询返回了未知格式。"))
    return nil
  end

  return response
end

--[[--
执行文本摘要并处理错误
封装对ReaderAI.summarizeContent的调用，提供统一的错误处理和响应验证

错误类型处理：
- timeout: 网络超时错误
- connection: 连接失败错误
- attempts: 重试次数耗尽
- 其他: 通用错误信息

@param request_opts table 摘要请求参数
@return table|nil 摘要结果，失败时返回nil（结果包含summary字段）
]]
local function performSummarize(request_opts)
  local ok, response = pcall(ReaderAI.summarizeContent, request_opts)
  if not ok then
    local error_msg = tostring(response)
    -- 根据错误类型显示相应的用户友好消息
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

  -- 验证响应数据格式和必要字段
  if type(response) ~= "table" or type(response.summary) ~= "string" then
    showError(_("摘要返回格式无效。"))
    return nil
  end

  return response
end

--[[--
执行文本分析并处理错误
封装对ReaderAI.analyzeContent的调用，提供统一的错误处理和响应验证

错误类型处理：
- timeout: 网络超时错误
- connection: 连接失败错误
- attempts: 重试次数耗尽
- 其他: 通用错误信息

@param request_opts table 分析请求参数
@return table|nil 分析结果，失败时返回nil
]]
local function performAnalyze(request_opts)
  local ok, response = pcall(ReaderAI.analyzeContent, request_opts)
  if not ok then
    local error_msg = tostring(response)
    -- 根据错误类型显示相应的用户友好消息
    if error_msg:match("timeout") then
      showError(_("网络请求超时，请检查网络连接后重试。"))
    elseif error_msg:match("connection") or error_msg:match("Failed to contact") then
      showError(_("无法连接到AI服务，请检查网络设置。"))
    elseif error_msg:match("attempts") then
      showError(_("网络连接失败，已重试" .. MAX_RETRY_ATTEMPTS .. "次。请检查网络后重试。"))
    else
      showError(_("文本分析失败：") .. error_msg)
    end
    return nil
  end

  -- 验证响应数据格式
  if type(response) ~= "table" then
    showError(_("分析返回格式无效。"))
    return nil
  end

  return response
end

--[[--
显示主要的AskGPT交互对话框
这是插件的核心函数，负责协调整个用户交互流程

工作流程：
1. 提取和处理高亮文本数据
2. 获取文档元数据信息
3. 定义内部的AI服务调用函数
4. 创建用户输入对话框
5. 配置各种操作按钮（询问、摘要、翻译）

@param ui table KOReader的UI实例
@param highlight_source table|string 高亮数据源
]]
local function showChatGPTDialog(ui, highlight_source)
  -- 提取高亮文本和上下文信息
  local highlightedText, highlightedContext = extract_highlight_data(highlight_source)

  -- 获取当前文档的元数据信息
  local props = ui.document and ui.document:getProps() or {}
  local title = props.title or _("Unknown Title")
  local author = props.authors or _("Unknown Author")
  --[[--
  内部函数：启动字典查询工作流
  处理字典查询的完整流程，包括上下文构建、AI调用和结果显示

  @param options table 查询选项，包含term、question、language等参数
  ]]
  local function startLookup(options)
    local blocks = {}      -- 存储多个查询结果块
    local current_text = "" -- 当前显示的完整文本

    -- 显示加载状态
    local loading = showLoadingDialog()
    UIManager:scheduleIn(0.1, function()
      -- 关闭加载对话框
      if loading then
        UIManager:close(loading)
      end

      -- 处理用户输入的问题和上下文
      local question = trim(options.question)
      local base_context = ""
      if type(options.context) == "string" then
        base_context = trim(options.context)
      end
      local skip_context_question = options.skip_context_question

      --[[--
      内部函数：组合查询上下文
      根据不同的参数组合生成最终的查询上下文

      @param prompt_text string 用户输入的提示文本
      @return string 组合后的上下文
      ]]
      local function compose_context(prompt_text)
        local trimmed_prompt = trim(prompt_text)
        if base_context ~= "" then
          -- 如果有预设的base_context，优先使用
          if trimmed_prompt ~= "" and not skip_context_question then
            return base_context .. "\n" .. trimmed_prompt
          end
          return base_context
        end
        -- 否则构建标准的查询上下文
        return buildLookupContext(ui, options.highlighted_text or highlightedText, trimmed_prompt)
      end

      -- 组合最终的查询上下文
      local request_context = compose_context(question)

      -- 验证查询词条
      local request_term = trim(options.term)
      if request_term == "" then
        showError(_("词条不能为空。"))
        return
      end

      -- 执行字典查询
      local request_language = options.request_language or options.language
      local dictionary = performLookup {
        term = request_term,
        language = request_language,
        context = request_context,
      }
      if not dictionary then
        return -- performLookup已经显示了错误信息
      end

      -- 格式化查询结果
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

      --[[--
      内部函数：处理"添加到笔记"按钮点击事件
      将当前的AI响应内容添加到KOReader的笔记系统中

      @param viewer table 查看器实例
      ]]
      local function handleAddToNote(viewer)
        if not ui.highlight or not ui.highlight.addNote then
          showError(_("错误：无法找到高亮对象。"))
          return
        end

        -- 将当前显示的文本添加为笔记
        ui.highlight:addNote(current_text)
        UIManager:close(viewer or chatgpt_viewer)
        if ui.highlight.onClose then
          ui.highlight:onClose()
        end
      end

      --[[--
      内部函数：处理"再问一个问题"按钮点击事件
      允许用户在同一个查看器中进行连续的字典查询

      @param viewer table 查看器实例
      @param new_term string 新的查询词条
      ]]
      local function handleNewQuestion(viewer, new_term)
        local follow_term = trim(new_term)
        if follow_term == "" then
          return
        end

        -- 使用相同的上下文构建方法进行后续查询
        local follow_context = compose_context(follow_term)
        local follow_language = options.followup_language or options.language
        local follow_request_language = options.followup_request_language or options.request_language or follow_language

        -- 执行后续查询
        local dictionary_follow = performLookup {
          term = follow_term,
          language = follow_request_language,
          context = follow_context,
        }
        if not dictionary_follow then
          return
        end

        -- 格式化并追加新的查询结果
        local follow_block = formatDictionaryBlock {
          question = follow_term,
          term = follow_term,
          dictionary = dictionary_follow,
          language = follow_language,
          title = title,
          author = author,
        }
        table.insert(blocks, follow_block)
        current_text = table.concat(blocks, "\n\n")

        -- 更新查看器显示
        viewer:update(current_text)
      end

      -- 创建并显示字典查询结果查看器
      chatgpt_viewer = ChatGPTViewer:new {
        ui = ui,
        title = options.viewer_title or _("Reader AI Dictionary"),
        text = current_text,
        onAskQuestion = handleNewQuestion,  -- 绑定后续提问处理函数
        onAddToNote = handleAddToNote,      -- 绑定添加笔记处理函数
      }
      UIManager:show(chatgpt_viewer)
    end)
  end

  --[[--
  内部函数：启动文本摘要工作流
  处理文本摘要的完整流程，包括内容验证、AI调用和结果显示

  @param options table 摘要选项，包含content、prompt、language等参数
  ]]
  local function startSummarize(options)
    local blocks = {}      -- 存储多个摘要结果块
    local current_text = "" -- 当前显示的完整文本

    -- 显示加载状态
    local loading = showLoadingDialog()
    UIManager:scheduleIn(0.1, function()
      -- 关闭加载对话框
      if loading then
        UIManager:close(loading)
      end

      -- 处理摘要指令和内容
      local prompt = trim(options.prompt)
      local base_content = options.content or options.highlighted_text or highlightedText
      local content = trim(base_content)

      -- 验证内容不为空
      if content == "" then
        showError(_("内容不能为空。"))
        return
      end

      -- 执行文本摘要
      local summary = performSummarize {
        content = content,
        language = options.language,
        context = prompt,
      }
      if not summary then
        return -- performSummarize已经显示了错误信息
      end

      -- 格式化摘要结果
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

      --[[--
      内部函数：处理摘要的"添加到笔记"按钮点击事件
      @param viewer table 查看器实例
      ]]
      local function handleAddToNote(viewer)
        if not ui.highlight or not ui.highlight.addNote then
          showError(_("错误：无法找到高亮对象。"))
          return
        end

        -- 将当前摘要内容添加为笔记
        ui.highlight:addNote(current_text)
        UIManager:close(viewer or chatgpt_viewer)
        if ui.highlight.onClose then
          ui.highlight:onClose()
        end
      end

      --[[--
      内部函数：处理"再问一个问题"按钮点击事件（用于摘要的后续指令）
      允许用户对同一文本内容使用不同的摘要指令

      @param viewer table 查看器实例
      @param new_instruction string 新的摘要指令
      ]]
      local function handleNewSummary(viewer, new_instruction)
        local follow_instruction = trim(new_instruction)
        if follow_instruction == "" then
          return
        end

        -- 使用新指令对同一内容进行摘要
        local summary_follow = performSummarize {
          content = content,
          language = options.language,
          context = follow_instruction,
        }
        if not summary_follow then
          return
        end

        -- 格式化并追加新的摘要结果
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

        -- 更新查看器显示
        viewer:update(current_text)
      end

      -- 创建并显示文本摘要结果查看器
      chatgpt_viewer = ChatGPTViewer:new {
        ui = ui,
        title = options.viewer_title or _("Reader AI Summary"),
        text = current_text,
        onAskQuestion = handleNewSummary, -- 绑定后续摘要处理函数
        onAddToNote = handleAddToNote,    -- 绑定添加笔记处理函数
      }
      UIManager:show(chatgpt_viewer)
    end)
  end

  --[[--
  内部函数：启动文本分析工作流
  处理文本分析的完整流程，包括内容验证、AI调用和结果显示

  @param options table 分析选项，包含content、focus_points、language等参数
  ]]
  local function startAnalyze(options)
    local blocks = {}      -- 存储多个分析结果块
    local current_text = "" -- 当前显示的完整文本

    -- 显示加载状态
    local loading = showLoadingDialog()
    UIManager:scheduleIn(0.1, function()
      -- 关闭加载对话框
      if loading then
        UIManager:close(loading)
      end

      -- 处理分析重点和内容
      local focus_points_input = trim(options.focus_points_input or "")
      local focus_points = nil
      if focus_points_input ~= "" then
        -- 将用户输入的分析重点转换为数组
        focus_points = {}
        for point in focus_points_input:gmatch("[^,]+") do
          local trimmed_point = trim(point)
          if trimmed_point ~= "" then
            table.insert(focus_points, trimmed_point)
          end
        end
        if #focus_points == 0 then
          focus_points = nil
        end
      end

      local base_content = options.content or options.highlighted_text or highlightedText
      local content = trim(base_content)

      -- 验证内容不为空
      if content == "" then
        showError(_("内容不能为空。"))
        return
      end

      -- 执行文本分析
      local analysis_result = performAnalyze {
        content = content,
        focus_points = focus_points,
        language = options.language,
      }
      if not analysis_result then
        return -- performAnalyze已经显示了错误信息
      end

      -- 格式化分析结果
      local block = formatAnalysisBlock {
        highlighted_text = options.highlighted_text or content,
        focus_points = focus_points,
        analysis = analysis_result,
        language = options.language,
        title = title,
        author = author,
      }
      table.insert(blocks, block)
      current_text = table.concat(blocks, "\n\n")

      local chatgpt_viewer

      --[[--
      内部函数：处理分析的"添加到笔记"按钮点击事件
      @param viewer table 查看器实例
      ]]
      local function handleAddToNote(viewer)
        if not ui.highlight or not ui.highlight.addNote then
          showError(_("错误：无法找到高亮对象。"))
          return
        end

        -- 将当前分析内容添加为笔记
        ui.highlight:addNote(current_text)
        UIManager:close(viewer or chatgpt_viewer)
        if ui.highlight.onClose then
          ui.highlight:onClose()
        end
      end

      --[[--
      内部函数：处理"再问一个问题"按钮点击事件（用于分析的后续重点）
      允许用户对同一文本内容使用不同的分析重点

      @param viewer table 查看器实例
      @param new_focus string 新的分析重点
      ]]
      local function handleNewAnalysis(viewer, new_focus)
        local follow_focus = trim(new_focus)
        if follow_focus == "" then
          return
        end

        -- 转换新的分析重点为数组
        local follow_focus_points = {}
        for point in follow_focus:gmatch("[^,]+") do
          local trimmed_point = trim(point)
          if trimmed_point ~= "" then
            table.insert(follow_focus_points, trimmed_point)
          end
        end

        if #follow_focus_points == 0 then
          return
        end

        -- 使用新重点对同一内容进行分析
        local analysis_follow = performAnalyze {
          content = content,
          focus_points = follow_focus_points,
          language = options.language,
        }
        if not analysis_follow then
          return
        end

        -- 格式化并追加新的分析结果
        local follow_block = formatAnalysisBlock {
          highlighted_text = options.highlighted_text or content,
          focus_points = follow_focus_points,
          analysis = analysis_follow,
          language = options.language,
          title = title,
          author = author,
        }
        table.insert(blocks, follow_block)
        current_text = table.concat(blocks, "\n\n")

        -- 更新查看器显示
        viewer:update(current_text)
      end

      -- 创建并显示文本分析结果查看器
      chatgpt_viewer = ChatGPTViewer:new {
        ui = ui,
        title = options.viewer_title or _("Reader AI Analysis"),
        text = current_text,
        onAskQuestion = handleNewAnalysis, -- 绑定后续分析处理函数
        onAddToNote = handleAddToNote,     -- 绑定添加笔记处理函数
      }
      UIManager:show(chatgpt_viewer)
    end)
  end

  --[[--
  按钮回调函数：处理"Ask"按钮点击事件
  启动字典查询工作流
  ]]
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

  -- 配置输入对话框的按钮
  local buttons = {
    {
      text = _("Cancel"),  -- 取消按钮
      callback = function()
        UIManager:close(input_dialog)
      end,
    },
    {
      text = _("Ask"),     -- 询问按钮
      callback = onAsk,
    },
  }

  -- 添加摘要功能按钮
  table.insert(buttons, {
    text = _("Summarize"),  -- 摘要按钮
    callback = function()
      local question = input_dialog and trim(input_dialog:getInputText()) or ""
      UIManager:close(input_dialog)
      startSummarize {
        content = highlightedText,
        highlighted_text = highlightedText,
        prompt = question,  -- 用户输入作为摘要指令
        viewer_title = _("Reader AI Summary"),
      }
    end,
  })

  -- 添加分析功能按钮
  table.insert(buttons, {
    text = _("Analyze"),  -- 分析按钮
    callback = function()
      local focus_input = input_dialog and trim(input_dialog:getInputText()) or ""
      UIManager:close(input_dialog)
      startAnalyze {
        content = highlightedText,
        highlighted_text = highlightedText,
        focus_points_input = focus_input,  -- 用户输入作为分析重点
        viewer_title = _("Reader AI Analysis"),
      }
    end,
  })

  -- 根据配置添加字典查询功能按钮（含翻译）
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.translate_to and CONFIGURATION.features.translate_to ~= "" then
    local target_language = CONFIGURATION.features.translate_to
    table.insert(buttons, {
      text = _("Dictionary"),  -- 字典按钮
      callback = function()
        UIManager:close(input_dialog)
        startLookup {
          term = highlightedText,
          highlighted_text = highlightedText,
          question = _("Dictionary lookup with ") .. target_language .. _(" translation"),
          language = target_language,
          request_language = "auto",        -- 自动检测源语言
          viewer_title = _("Dictionary"),
          followup_language = target_language,
          followup_request_language = "auto",
          context = highlightedContext,     -- 使用高亮上下文
          skip_context_question = true,     -- 跳过上下文问题组合
        }
      end,
    })
  end

  -- 创建并显示用户输入对话框
  input_dialog = InputDialog:new {
    title = _("Ask a question about the highlighted text"),
    input_hint = _("Type your question here..."),
    input_type = "text",
    buttons = { buttons },
  }
  UIManager:show(input_dialog)
end

--[[--
模块导出
返回主要的对话框显示函数，供main.lua调用
]]
return showChatGPTDialog
