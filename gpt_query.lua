local json = require("json")
local ltn12 = require("ltn12")
local http = require("socket.http")
local https = require("ssl.https")
local socket = require("socket")

--[[
  Reader AI 客户端配置，仅使用新的 FastAPI 后端。
  CONFIGURATION 由用户提供的 configuration.lua 注入。
]]
local CONFIGURATION = nil

-- 尝试加载 configuration.lua，如果不存在则保持默认。
local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

-- Reader AI 默认服务地址与路径。
local DEFAULT_READER_AI_BASE_URL = "http://192.168.0.19:8000"
local DEFAULT_READER_AI_DICTIONARY_PATH = "/ai/dictionary"
local DEFAULT_READER_AI_SUMMARIZE_PATH = "/ai/summarize"

-- 网络请求配置
local REQUEST_TIMEOUT = 10  -- 请求超时时间（秒）
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

local function resolve_dictionary_endpoint()
  return resolve_endpoint(
    {
      "reader_ai_dictionary_path",
      "reader_ai_generate_path",
      "generate_endpoint",
    },
    DEFAULT_READER_AI_DICTIONARY_PATH,
    {
      "/ai/[^/]*$",
      "/ai$",
      "/dictionary$",
    }
  )
end

local function resolve_summarize_endpoint()
  return resolve_endpoint(
    {
      "reader_ai_summarize_path",
      "reader_ai_summary_path",
    },
    DEFAULT_READER_AI_SUMMARIZE_PATH,
    {
      "/ai/[^/]*$",
      "/ai$",
      "/summarize$",
    }
  )
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
    
    -- 设置超时
    local old_timeout = http.TIMEOUT
    http.TIMEOUT = REQUEST_TIMEOUT
    if request_library == https then
      https.TIMEOUT = REQUEST_TIMEOUT
    end
    
    local response_chunks = {}
    local request_copy = {}
    for k, v in pairs(request_params) do
      request_copy[k] = v
    end
    request_copy.sink = ltn12.sink.table(response_chunks)
    
    local success, res, code = pcall(function()
      return request_library.request(request_copy)
    end)
    
    -- 恢复原始超时设置
    http.TIMEOUT = old_timeout
    if request_library == https then
      https.TIMEOUT = old_timeout
    end
    
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
    
    -- 如果不是最后一次尝试，等待后重试
    if attempts < MAX_RETRY_ATTEMPTS then
      socket.sleep(RETRY_DELAY)
    end
  end
  
  return false, nil, last_error
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

  local endpoint = resolve_dictionary_endpoint()
  
  local payload = {
    term = term,
    language = resolve_default_language(params.language),
  }

  if params.context and params.context ~= "" then
    payload.context = params.context
  end

  local body = json.encode(payload)
  
  -- 使用带重试机制的HTTP请求
  local success, status_code, result = http_request_with_retry({
    url = endpoint,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#body),
    },
    source = ltn12.source.string(body),
  })

  if not success then
    error("Failed to contact Reader AI dictionary backend after " .. MAX_RETRY_ATTEMPTS .. " attempts. Last error: " .. tostring(result))
  end

  local response_chunks = result

  if type(response_chunks) ~= "table" then
    error("Reader AI dictionary backend returned an invalid response buffer.")
  end

  if status_code ~= 200 then
    local error_body = response_chunks and table.concat(response_chunks) or ""
    error("Reader AI dictionary backend error (" .. tostring(status_code) .. "): " .. error_body)
  end

  local concatenated = table.concat(response_chunks)
  local ok, decoded = pcall(json.decode, concatenated)
  if not ok or type(decoded) ~= "table" then
    error("Failed to decode Reader AI dictionary response: " .. concatenated)
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

  local endpoint = resolve_summarize_endpoint()
  
  local payload = {
    content = content,
  }

  if params.language and params.language ~= "" then
    payload.language = params.language
  end

  if params.context and params.context ~= "" then
    payload.context = params.context
  end

  local body = json.encode(payload)
  
  -- 使用带重试机制的HTTP请求
  local success, status_code, result = http_request_with_retry({
    url = endpoint,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#body),
    },
    source = ltn12.source.string(body),
  })

  if not success then
    error("Failed to contact Reader AI summarize backend after " .. MAX_RETRY_ATTEMPTS .. " attempts. Last error: " .. tostring(result))
  end

  local response_chunks = result

  if type(response_chunks) ~= "table" then
    error("Reader AI summarize backend returned an invalid response buffer.")
  end

  if status_code ~= 200 then
    local error_body = response_chunks and table.concat(response_chunks) or ""
    error("Reader AI summarize backend error (" .. tostring(status_code) .. "): " .. error_body)
  end

  local concatenated = table.concat(response_chunks)
  local ok, decoded = pcall(json.decode, concatenated)
  if not ok then
    error("Failed to decode Reader AI summarize response: " .. concatenated)
  end

  local summary
  if type(decoded) == "table" then
    summary = decoded.summary or decoded.content or decoded.result or decoded.output
  elseif type(decoded) == "string" then
    summary = decoded
    decoded = { summary = decoded }
  end

  if type(summary) ~= "string" or summary == "" then
    error("Reader AI summarize response missing summary field.")
  end

  return {
    summary = summary,
    raw = decoded,
  }
end

return ReaderAI
