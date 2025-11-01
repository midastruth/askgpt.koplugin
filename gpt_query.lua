--[[--
Reader AI 客户端模块 - 处理与AI后端服务的通信
支持字典查询和文本摘要功能，提供自动重试和错误处理机制

依赖库：
- json: JSON编码解码
- ltn12: LuaSocket数据传输抽象层
- socket.http: HTTP客户端
- ssl.https: HTTPS客户端
- socket: 套接字操作（用于重试延迟）
]]

local json    = require("json")     -- JSON数据处理
local ltn12   = require("ltn12")    -- 数据传输抽象层
local http    = require("socket.http")   -- HTTP客户端库
local https   = require("ssl.https")     -- HTTPS客户端库
local socket  = require("socket")   -- 套接字操作库

--[[--
全局配置变量
从用户的 configuration.lua 文件中加载配置信息
如果文件不存在则保持为 nil，使用默认配置
]]
local CONFIGURATION = nil

--[[--
安全加载用户配置文件
使用 pcall 保护调用，避免配置文件不存在或语法错误导致插件崩溃

@return table|nil 配置表，如果加载失败则返回 nil
]]
local function load_configuration()
  local success, result = pcall(function()
    return require("configuration")  -- 尝试加载 configuration.lua
  end)

  if success then
    return result  -- 配置加载成功
  end

  -- 配置文件不存在或有语法错误，使用默认配置
  print("configuration.lua not found, skipping...")
  return nil
end

-- 加载用户配置
CONFIGURATION = load_configuration()

--[[--
默认服务配置
当用户未提供配置或配置不完整时使用的默认值
]]
local DEFAULT_READER_AI_BASE_URL = "http://192.168.0.19:8000"  -- 默认AI服务器地址
local DEFAULT_READER_AI_DICTIONARY_PATH = "/ai/dictionary"      -- 字典查询API路径
local DEFAULT_READER_AI_SUMMARIZE_PATH = "/ai/summarize"        -- 文本摘要API路径

--[[--
网络请求配置参数
这些参数控制网络请求的超时和重试行为
]]
local REQUEST_TIMEOUT = 1000      -- 单次请求超时时间（秒），设置较长以适应AI处理时间
local MAX_RETRY_ATTEMPTS = 3      -- 失败后的最大重试次数
local RETRY_DELAY = 2            -- 重试之间的等待时间（秒）

-- 导出的 ReaderAI 模块表，包含所有公开的 API 函数
local ReaderAI = {}

--[[--
字符串去除首尾空白字符
处理用户输入或API响应中的多余空格

@param text string|nil 待处理的字符串
@return string 去除首尾空格后的字符串，如果输入为nil则返回空字符串
]]
local function trim(text)
  return (text or ""):match("^%s*(.-)%s*$")
end

--[[--
根据URL协议自动选择HTTP库
检查URL是否使用HTTPS协议，选择对应的请求库

@param url string 请求的URL地址
@return table 返回 https 或 http 库
]]
local function choose_request_library(url)
  if type(url) == "string" and url:match("^https://") then
    return https  -- HTTPS请求使用ssl.https库
  end
  return http    -- HTTP请求使用socket.http库
end

--[[--
浅拷贝表
创建表的副本，避免修改原表影响其他代码

@param source table 源表
@return table 拷贝后的新表
]]
local function clone_table(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

--[[--
解析AI服务的基础URL地址
优先使用用户配置，配置缺失时使用默认地址

配置优先级：
1. CONFIGURATION.reader_ai_base_url (专用Reader AI配置)
2. CONFIGURATION.base_url (通用base_url，但排除OpenAI chat/completions端点)
3. DEFAULT_READER_AI_BASE_URL (默认地址)

@return string 标准化后的基础URL（去除末尾斜杠）
]]
local function resolve_base_url()
  local base = DEFAULT_READER_AI_BASE_URL

  if CONFIGURATION then
    -- 优先使用专用的reader_ai_base_url配置
    if CONFIGURATION.reader_ai_base_url and CONFIGURATION.reader_ai_base_url ~= "" then
      base = CONFIGURATION.reader_ai_base_url
    -- 如果没有专用配置，使用通用base_url（但排除OpenAI格式的URL）
    elseif CONFIGURATION.base_url and CONFIGURATION.base_url ~= "" and not CONFIGURATION.base_url:match("/chat/completions") then
      base = CONFIGURATION.base_url
    end
  end

  -- 标准化URL：去除末尾的斜杠
  if base:sub(-1) == "/" then
    base = base:sub(1, -2)
  end

  return base
end

--[[--
从配置中提取指定路径的值
支持点号分隔的嵌套路径，如 "features.dictionary_language"

@param key string 配置路径，使用点号分隔嵌套字段
@return string|nil 配置值（非空字符串），如果路径不存在或值为空则返回nil
]]
local function pick_config_path(key)
  if not CONFIGURATION then
    return nil
  end

  -- 遍历点号分隔的路径
  local current = CONFIGURATION
  for part in key:gmatch("[^%.]+") do
    if type(current) ~= "table" then
      return nil  -- 中间路径不是表，无法继续访问
    end
    current = current[part]
  end

  -- 只返回非空字符串值
  if type(current) == "string" and current ~= "" then
    return current
  end

  return nil
end

--[[--
标准化API路径格式
确保路径以斜杠开头，用于URL拼接

@param path string|nil API路径
@return string 标准化后的路径
]]
local function normalize_path(path)
  if not path or path == "" then
    return ""
  end
  -- 确保路径以斜杠开头
  if path:sub(1, 1) ~= "/" then
    return "/" .. path
  end
  return path
end

--[[--
解析API端点的完整URL
根据配置和默认值构建最终的API端点地址

@param path_keys table 配置中可能包含路径的字段名列表（按优先级排序）
@param default_path string 默认API路径
@param terminal_patterns table|nil 终端模式列表，如果base_url匹配这些模式则直接返回base_url
@return string 完整的API端点URL
]]
local function resolve_endpoint(path_keys, default_path, terminal_patterns)
  local base = resolve_base_url()
  local path = default_path

  -- 尝试从配置中获取自定义路径（按优先级顺序）
  if CONFIGURATION then
    for _, key in ipairs(path_keys) do
      local value = pick_config_path(key)
      if value then
        path = value  -- 使用第一个找到的配置值
        break
      end
    end
  end

  path = normalize_path(path)

  -- 检查base_url是否已经是完整端点（终端模式）
  -- 如果base_url已经指向具体的API端点，直接返回
  if terminal_patterns then
    for _, pattern in ipairs(terminal_patterns) do
      if base:match(pattern) then
        return base  -- base_url已经是完整端点
      end
    end
  end

  -- 拼接base_url和路径
  return base .. path
end

--[[--
API端点配置定义
定义了各种AI服务的端点配置，包括：
- path_keys: 配置文件中可能包含路径的字段名（按优先级排序）
- default_path: 默认API路径
- terminal_patterns: 用于检测base_url是否已经是完整端点的正则表达式
]]
local READER_AI_ENDPOINTS = {
  dictionary = {
    path_keys          = { "reader_ai_dictionary_path", "reader_ai_generate_path", "generate_endpoint" },
    default_path       = DEFAULT_READER_AI_DICTIONARY_PATH,
    terminal_patterns  = { "/ai/[^/]*$", "/ai$", "/dictionary$" },
  },
  summarize = {
    path_keys          = { "reader_ai_summarize_path", "reader_ai_summary_path" },
    default_path       = DEFAULT_READER_AI_SUMMARIZE_PATH,
    terminal_patterns  = { "/ai/[^/]*$", "/ai$", "/summarize$" },
  },
}

--[[--
解析Reader AI端点URL的便捷函数
使用预定义的端点配置来解析完整的API地址

@param definition table 端点配置定义（来自READER_AI_ENDPOINTS）
@return string 完整的API端点URL
]]
local function resolve_reader_ai_endpoint(definition)
  return resolve_endpoint(definition.path_keys, definition.default_path, definition.terminal_patterns)
end

--[[--
解析默认语言设置
根据请求参数和用户配置确定使用的语言

优先级：
1. 请求中明确指定的语言
2. 全局语言配置 (CONFIGURATION.language)
3. 字典功能专用语言配置 (CONFIGURATION.features.dictionary_language)
4. 默认值 "auto"

@param request_language string|nil 请求中指定的语言
@return string 最终使用的语言代码
]]
local function resolve_default_language(request_language)
  -- 优先使用请求中明确指定的语言
  if request_language and request_language ~= "" then
    return request_language
  end

  if CONFIGURATION then
    -- 使用全局语言配置
    if CONFIGURATION.language and CONFIGURATION.language ~= "" then
      return CONFIGURATION.language
    end
    -- 使用字典功能专用语言配置
    if CONFIGURATION.features and CONFIGURATION.features.dictionary_language and CONFIGURATION.features.dictionary_language ~= "" then
      return CONFIGURATION.features.dictionary_language
    end
  end

  return "auto"  -- 默认自动检测语言
end

--[[--
带超时和重试机制的HTTP请求函数
提供网络鲁棒性，自动处理临时网络问题

特性：
- 根据URL协议自动选择HTTP/HTTPS库
- 设置请求超时以防止无限等待
- 失败后自动重试（最多3次）
- 保护性地恢复原始超时设置
- 详细的错误信息记录

@param request_params table HTTP请求参数表
@return boolean, number|nil, table|string 成功标志、状态码、响应数据或错误信息
]]
local function http_request_with_retry(request_params)
  local request_library = choose_request_library(request_params.url)
  local attempts = 0
  local last_error = nil

  while attempts < MAX_RETRY_ATTEMPTS do
    attempts = attempts + 1

    -- 保存原始超时设置，并应用新的超时配置
    local previous_http_timeout  = http.TIMEOUT
    local previous_https_timeout = https.TIMEOUT
    http.TIMEOUT  = REQUEST_TIMEOUT
    https.TIMEOUT = REQUEST_TIMEOUT

    -- 准备响应数据接收器
    local response_chunks = {}
    local request_copy    = clone_table(request_params)
    request_copy.sink     = ltn12.sink.table(response_chunks)

    -- 执行HTTP请求，使用pcall保护调用
    local success, res, code = pcall(function()
      return request_library.request(request_copy)
    end)

    -- 恢复原始超时设置
    http.TIMEOUT  = previous_http_timeout
    https.TIMEOUT = previous_https_timeout

    -- 检查请求是否成功
    if success and res and code == 200 then
      return true, code, response_chunks
    end

    -- 记录错误信息
    if not success then
      last_error = "Request failed: " .. tostring(res)  -- pcall失败
    elseif not res then
      last_error = "Connection failed"                  -- 连接失败
    else
      last_error = "HTTP error: " .. tostring(code)     -- HTTP错误状态码
    end

    -- 在重试前等待，避免立即重试给服务器造成压力
    if attempts < MAX_RETRY_ATTEMPTS then
      socket.sleep(RETRY_DELAY)
    end
  end

  -- 所有重试都失败
  return false, nil, last_error
end

--[[--
执行JSON POST请求的通用函数
封装了完整的POST请求流程，包括JSON编码、请求发送和响应解析

处理流程：
1. 将payload编码为JSON
2. 发送POST请求（使用重试机制）
3. 验证响应格式和状态
4. 解析JSON响应

@param endpoint string API端点URL
@param payload table 要发送的数据（将被JSON编码）
@param context_label string 上下文标签，用于错误消息
@return table, string 解析后的响应数据和原始响应体
@throws error 如果请求失败、响应格式错误或JSON解析失败
]]
local function perform_json_post(endpoint, payload, context_label)
  -- 将请求数据编码为JSON
  local body = json.encode(payload)

  -- 发送HTTP POST请求
  local success, status_code, response_chunks = http_request_with_retry({
    url     = endpoint,
    method  = "POST",
    headers = {
      ["Accept"]         = "application/json",      -- 期望JSON响应
      ["Content-Type"]   = "application/json",      -- 发送JSON数据
      ["Content-Length"] = tostring(#body),         -- 内容长度
    },
    source  = ltn12.source.string(body),           -- 请求体数据源
  })

  -- 检查请求是否成功
  if not success then
    error(string.format(
      "Failed to contact %s backend after %d attempts. Last error: %s",
      context_label,
      MAX_RETRY_ATTEMPTS,
      tostring(response_chunks)  -- 这里包含错误信息
    ))
  end

  -- 验证响应数据格式
  if type(response_chunks) ~= "table" then
    error(string.format("%s backend returned an invalid response buffer.", context_label))
  end

  -- 拼接响应体
  local response_body = table.concat(response_chunks)

  -- 检查HTTP状态码（这里实际上是冗余检查，因为重试函数已经检查过了）
  if status_code ~= 200 then
    error(string.format(
      "%s backend error (%s): %s",
      context_label,
      tostring(status_code),
      response_body
    ))
  end

  -- 解析JSON响应
  local ok, decoded = pcall(json.decode, response_body)
  if not ok then
    error(string.format("Failed to decode %s response: %s", context_label, response_body))
  end

  return decoded, response_body
end

--[[--
调用Reader AI字典查询服务
提供词汇定义、发音、词性、例句等信息

支持的参数：
- term: 要查询的词汇或短语（必需）
- language: 目标语言（可选，默认使用配置或"auto"）
- context: 上下文信息，帮助AI理解词汇的具体含义（可选）

@param params table 查询参数表
@return table 包含词典信息的表，可能包含 definition, pronunciation, examples 等字段
@throws error 如果参数无效、网络请求失败或响应格式错误
]]
function ReaderAI.dictionaryLookup(params)
  -- 参数验证
  if type(params) ~= "table" then
    error("Reader AI dictionary query expects a parameter table.")
  end

  local term = trim(params.term)
  if not term or term == "" then
    error("Reader AI dictionary query requires a term.")
  end

  -- 解析API端点
  local endpoint = resolve_reader_ai_endpoint(READER_AI_ENDPOINTS.dictionary)

  -- 构建请求载荷
  local payload = {
    term     = term,
    language = resolve_default_language(params.language),
  }

  -- 添加可选的上下文信息
  if params.context and params.context ~= "" then
    payload.context = params.context
  end

  -- 发送请求并获取响应
  local decoded = perform_json_post(endpoint, payload, "Reader AI dictionary")

  -- 验证响应格式
  if type(decoded) ~= "table" then
    error("Reader AI dictionary response did not contain a JSON object.")
  end

  -- 兼容性处理：某些后端可能使用 output 字段而不是 definition
  if decoded.definition == nil and decoded.output ~= nil and type(decoded.output) ~= "table" then
    decoded.definition = decoded.output
  end

  return decoded
end

--[[--
调用Reader AI文本摘要服务
生成文本内容的简洁摘要

支持的参数：
- content/text/highlight: 要摘要的文本内容（必需，支持多个字段名）
- language: 摘要输出语言（可选）
- context: 摘要上下文或指令（可选）

@param params table 摘要参数表
@return table 包含摘要结果的表，格式为 { summary = "摘要文本", raw = 原始响应数据 }
@throws error 如果参数无效、网络请求失败或响应格式错误
]]
function ReaderAI.summarizeContent(params)
  -- 参数验证
  if type(params) ~= "table" then
    error("Reader AI summarize expects a parameter table.")
  end

  -- 提取文本内容（支持多个可能的字段名）
  local content = trim(params.content or params.text or params.highlight)
  if not content or content == "" then
    error("Reader AI summarize requires content text.")
  end

  -- 解析API端点
  local endpoint = resolve_reader_ai_endpoint(READER_AI_ENDPOINTS.summarize)

  -- 构建请求载荷
  local payload = {
    content = content,
  }

  -- 添加可选参数
  if params.language and params.language ~= "" then
    payload.language = params.language
  end

  if params.context and params.context ~= "" then
    payload.context = params.context
  end

  -- 发送请求并获取响应
  local decoded = perform_json_post(endpoint, payload, "Reader AI summarize")

  -- 解析摘要内容（支持多种响应格式）
  local summary
  if type(decoded) == "table" then
    -- 尝试多个可能的字段名
    summary = decoded.summary or decoded.content or decoded.result or decoded.output
  elseif type(decoded) == "string" then
    -- 直接返回字符串的情况
    summary = decoded
    decoded = { summary = decoded }
  else
    error("Reader AI summarize response did not contain a JSON object or string.")
  end

  -- 验证摘要内容
  if type(summary) ~= "string" or summary == "" then
    error("Reader AI summarize response missing summary field.")
  end

  -- 返回标准化的摘要结果
  return {
    summary = summary,    -- 摘要文本
    raw     = decoded,   -- 原始响应数据（可能包含其他信息）
  }
end

-- 导出ReaderAI模块
return ReaderAI
