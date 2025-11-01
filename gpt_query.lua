local json    = require("json")
local ltn12   = require("ltn12")
local http    = require("socket.http")
local https   = require("ssl.https")
local socket  = require("socket")

--[[
  Reader AI 客户端配置，仅使用新的 FastAPI 后端。
  CONFIGURATION 由用户提供的 configuration.lua 注入。
]]
local CONFIGURATION = nil

local function load_configuration()
  local success, result = pcall(function()
    return require("configuration")
  end)

  if success then
    return result
  end

  print("configuration.lua not found, skipping...")
  return nil
end

CONFIGURATION = load_configuration()

-- Reader AI 默认服务地址与路径。
local DEFAULT_READER_AI_BASE_URL = "http://192.168.0.19:8000"
local DEFAULT_READER_AI_DICTIONARY_PATH = "/ai/dictionary"
local DEFAULT_READER_AI_SUMMARIZE_PATH = "/ai/summarize"

-- 网络请求配置
local REQUEST_TIMEOUT = 1000  -- 请求超时时间（秒）
local MAX_RETRY_ATTEMPTS = 3  -- 最大重试次数
local RETRY_DELAY = 2  -- 重试间隔（秒）

local ReaderAI = {}

local function trim(text)
  return (text or ""):match("^%s*(.-)%s*$")
end

-- 根据 URL 协议选择 HTTP / HTTPS 库。
local function choose_request_library(url)
  if type(url) == "string" and url:match("^https://") then
    return https
  end
  return http
end

local function clone_table(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

local function resolve_base_url()
  local base = DEFAULT_READER_AI_BASE_URL

  if CONFIGURATION then
    if CONFIGURATION.reader_ai_base_url and CONFIGURATION.reader_ai_base_url ~= "" then
      base = CONFIGURATION.reader_ai_base_url
    elseif CONFIGURATION.base_url and CONFIGURATION.base_url ~= "" and not CONFIGURATION.base_url:match("/chat/completions") then
      base = CONFIGURATION.base_url
    end
  end

  if base:sub(-1) == "/" then
    base = base:sub(1, -2)
  end

  return base
end

local function pick_config_path(key)
  if not CONFIGURATION then
    return nil
  end

  local current = CONFIGURATION
  for part in key:gmatch("[^%.]+") do
    if type(current) ~= "table" then
      return nil
    end
    current = current[part]
  end

  if type(current) == "string" and current ~= "" then
    return current
  end

  return nil
end

local function normalize_path(path)
  if not path or path == "" then
    return ""
  end
  if path:sub(1, 1) ~= "/" then
    return "/" .. path
  end
  return path
end

local function resolve_endpoint(path_keys, default_path, terminal_patterns)
  local base = resolve_base_url()
  local path = default_path

  if CONFIGURATION then
    for _, key in ipairs(path_keys) do
      local value = pick_config_path(key)
      if value then
        path = value
        break
      end
    end
  end

  path = normalize_path(path)

  if terminal_patterns then
    for _, pattern in ipairs(terminal_patterns) do
      if base:match(pattern) then
        return base
      end
    end
  end

  return base .. path
end

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

local function resolve_reader_ai_endpoint(definition)
  return resolve_endpoint(definition.path_keys, definition.default_path, definition.terminal_patterns)
end

local function resolve_default_language(request_language)
  if request_language and request_language ~= "" then
    return request_language
  end

  if CONFIGURATION then
    if CONFIGURATION.language and CONFIGURATION.language ~= "" then
      return CONFIGURATION.language
    end
    if CONFIGURATION.features and CONFIGURATION.features.dictionary_language and CONFIGURATION.features.dictionary_language ~= "" then
      return CONFIGURATION.features.dictionary_language
    end
  end

  return "auto"
end

-- 带超时和重试机制的HTTP请求函数
local function http_request_with_retry(request_params)
  local request_library = choose_request_library(request_params.url)
  local attempts = 0
  local last_error = nil

  while attempts < MAX_RETRY_ATTEMPTS do
    attempts = attempts + 1

    local previous_http_timeout  = http.TIMEOUT
    local previous_https_timeout = https.TIMEOUT
    http.TIMEOUT  = REQUEST_TIMEOUT
    https.TIMEOUT = REQUEST_TIMEOUT

    local response_chunks = {}
    local request_copy    = clone_table(request_params)
    request_copy.sink     = ltn12.sink.table(response_chunks)

    local success, res, code = pcall(function()
      return request_library.request(request_copy)
    end)

    http.TIMEOUT  = previous_http_timeout
    https.TIMEOUT = previous_https_timeout

    if success and res and code == 200 then
      return true, code, response_chunks
    end

    if not success then
      last_error = "Request failed: " .. tostring(res)
    elseif not res then
      last_error = "Connection failed"
    else
      last_error = "HTTP error: " .. tostring(code)
    end

    if attempts < MAX_RETRY_ATTEMPTS then
      socket.sleep(RETRY_DELAY)
    end
  end

  return false, nil, last_error
end

local function perform_json_post(endpoint, payload, context_label)
  local body = json.encode(payload)

  local success, status_code, response_chunks = http_request_with_retry({
    url     = endpoint,
    method  = "POST",
    headers = {
      ["Accept"]         = "application/json",
      ["Content-Type"]   = "application/json",
      ["Content-Length"] = tostring(#body),
    },
    source  = ltn12.source.string(body),
  })

  if not success then
    error(string.format(
      "Failed to contact %s backend after %d attempts. Last error: %s",
      context_label,
      MAX_RETRY_ATTEMPTS,
      tostring(response_chunks)
    ))
  end

  if type(response_chunks) ~= "table" then
    error(string.format("%s backend returned an invalid response buffer.", context_label))
  end

  local response_body = table.concat(response_chunks)

  if status_code ~= 200 then
    error(string.format(
      "%s backend error (%s): %s",
      context_label,
      tostring(status_code),
      response_body
    ))
  end

  local ok, decoded = pcall(json.decode, response_body)
  if not ok then
    error(string.format("Failed to decode %s response: %s", context_label, response_body))
  end

  return decoded, response_body
end

-- 调用 Reader AI FastAPI 字典服务，返回解析后的词典结果表。
function ReaderAI.dictionaryLookup(params)
  if type(params) ~= "table" then
    error("Reader AI dictionary query expects a parameter table.")
  end

  local term = trim(params.term)
  if not term or term == "" then
    error("Reader AI dictionary query requires a term.")
  end

  local endpoint = resolve_reader_ai_endpoint(READER_AI_ENDPOINTS.dictionary)

  local payload = {
    term     = term,
    language = resolve_default_language(params.language),
  }

  if params.context and params.context ~= "" then
    payload.context = params.context
  end

  local decoded = perform_json_post(endpoint, payload, "Reader AI dictionary")

  if type(decoded) ~= "table" then
    error("Reader AI dictionary response did not contain a JSON object.")
  end

  if decoded.definition == nil and decoded.output ~= nil and type(decoded.output) ~= "table" then
    decoded.definition = decoded.output
  end

  return decoded
end

-- 调用 Reader AI FastAPI 总结服务，返回摘要字符串与原始数据。
function ReaderAI.summarizeContent(params)
  if type(params) ~= "table" then
    error("Reader AI summarize expects a parameter table.")
  end

  local content = trim(params.content or params.text or params.highlight)
  if not content or content == "" then
    error("Reader AI summarize requires content text.")
  end

  local endpoint = resolve_reader_ai_endpoint(READER_AI_ENDPOINTS.summarize)

  local payload = {
    content = content,
  }

  if params.language and params.language ~= "" then
    payload.language = params.language
  end

  if params.context and params.context ~= "" then
    payload.context = params.context
  end

local decoded = perform_json_post(endpoint, payload, "Reader AI summarize")

  local summary
  if type(decoded) == "table" then
    summary = decoded.summary or decoded.content or decoded.result or decoded.output
  elseif type(decoded) == "string" then
    summary = decoded
    decoded = { summary = decoded }
  else
    error("Reader AI summarize response did not contain a JSON object or string.")
  end

  if type(summary) ~= "string" or summary == "" then
    error("Reader AI summarize response missing summary field.")
  end

  return {
    summary = summary,
    raw     = decoded,
  }
end

return ReaderAI
