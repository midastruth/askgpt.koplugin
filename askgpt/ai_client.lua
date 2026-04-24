-- AI HTTP 客户端：endpoint 解析、HTTP/HTTPS 选择、JSON POST、重试
-- timeout 单位：秒（LuaSocket/ssl.https 均以秒计）
local json   = require("json")
local ltn12  = require("ltn12")
local http   = require("socket.http")
local https  = require("ssl.https")
local socket = require("socket")

local Util   = require("askgpt.util")
local Config = require("askgpt.config")

local REQUEST_TIMEOUT    = 10   -- 秒
local MAX_RETRY_ATTEMPTS = 3
local RETRY_DELAY        = 2    -- 秒

local DEFAULT_READ_PATH = "/ai/query"

local AiClient = {}
AiClient.MAX_RETRY_ATTEMPTS = MAX_RETRY_ATTEMPTS  -- 供外部错误提示引用

-- ── 内部工具 ─────────────────────────────────────────────────────────────

local function choose_lib(url)
  if type(url) == "string" and url:match("^https://") then return https end
  return http
end

local function extract_error_detail(raw_error)
  if raw_error == nil then return nil end
  if type(raw_error) ~= "string" then raw_error = tostring(raw_error) end
  local message = Util.trim(raw_error)
  if message == "" then return nil end
  local first = message:sub(1, 1)
  if first == "{" or first == "[" then
    local ok, decoded = pcall(json.decode, message)
    if ok and type(decoded) == "table" then
      local detail = decoded.detail or decoded.message or decoded.error or decoded.error_description
      if detail ~= nil then
        if type(detail) == "table" then
          local enc_ok, encoded = pcall(json.encode, detail)
          detail = enc_ok and encoded or tostring(detail)
        end
        if type(detail) ~= "string" then detail = tostring(detail) end
        detail = Util.trim(detail)
        if detail ~= "" then return detail end
      end
    end
  end
  return message
end

-- ── endpoint 解析 ─────────────────────────────────────────────────────────

-- 与 config.validate() 严格一致：无有效 endpoint 时直接 error，不静默回退
local function resolve_base_url()
  local cfg = Config.get()
  if cfg then
    if type(cfg.reader_ai_base_url) == "string" and cfg.reader_ai_base_url ~= "" then
      local base = cfg.reader_ai_base_url
      if base:sub(-1) == "/" then base = base:sub(1, -2) end
      return base
    end
    if type(cfg.base_url) == "string" and cfg.base_url ~= ""
        and not cfg.base_url:match("/chat/completions") then
      local base = cfg.base_url
      if base:sub(-1) == "/" then base = base:sub(1, -2) end
      return base
    end
  end
  error("No valid API endpoint configured (set reader_ai_base_url or a non-OpenAI base_url)")
end

local function pick_config_path(key)
  local cfg = Config.get()
  if not cfg then return nil end
  local current = cfg
  for part in key:gmatch("[^%.]+") do
    if type(current) ~= "table" then return nil end
    current = current[part]
  end
  if type(current) == "string" and current ~= "" then return current end
  return nil
end

local function normalize_path(path)
  if not path or path == "" then return "" end
  if path:sub(1, 1) ~= "/" then return "/" .. path end
  return path
end

local function resolve_read_endpoint()
  local base = resolve_base_url()
  local path = normalize_path(
    pick_config_path("reader_ai_query_path")
    or pick_config_path("reader_ai_read_path") -- backward-compatible config key
    or DEFAULT_READ_PATH
  )

  if base:match("/ai/query$") or base:match("/query$")
      or base:match("/ai/read$") or base:match("/read$") then
    return base
  end
  if base:match("/ai$") then
    if path == DEFAULT_READ_PATH then return base .. "/query" end
    if path:match("^/ai/") then return base .. path:sub(4) end
  end
  return base .. path
end

local function has_values(t)
  if type(t) ~= "table" then return false end
  for _, value in pairs(t) do
    if value ~= nil and value ~= "" then return true end
  end
  return false
end

local function build_book(params)
  if type(params.book) == "table" and has_values(params.book) then
    return params.book
  end
  local book = {
    sha256 = params.file_sha256,
    title  = params.title,
    author = params.author,
  }
  return has_values(book) and book or nil
end

local function build_location(params)
  if type(params.location) == "table" and has_values(params.location) then
    return params.location
  end
  return nil
end

local function add_read_metadata(payload, params)
  if params.question and params.question ~= "" then payload.question = params.question end
  local book = build_book(params)
  if book then payload.book = book end
  local location = build_location(params)
  if location then payload.location = location end
end

-- ── HTTP 请求 ─────────────────────────────────────────────────────────────

local function http_request_with_retry(request_params)
  local lib = choose_lib(request_params.url)
  local attempts = 0
  local last_error, last_status_code, last_error_text, last_status_line

  while attempts < MAX_RETRY_ATTEMPTS do
    attempts = attempts + 1

    local prev_http_timeout  = http.TIMEOUT
    local prev_https_timeout = https.TIMEOUT
    http.TIMEOUT  = REQUEST_TIMEOUT
    https.TIMEOUT = REQUEST_TIMEOUT

    local response_chunks = {}
    local req_copy  = Util.clone_table(request_params)
    req_copy.sink   = ltn12.sink.table(response_chunks)

    local success, res, code, _, status_line = pcall(function()
      return lib.request(req_copy)
    end)

    http.TIMEOUT  = prev_http_timeout
    https.TIMEOUT = prev_https_timeout

    local status_code = tonumber(code) or code
    if success and res and status_code == 200 then
      return true, status_code, response_chunks
    end

    if success and status_code then
      local body = type(response_chunks) == "table"
        and table.concat(response_chunks) or tostring(response_chunks or "")
      last_status_code = status_code
      last_status_line = status_line or ""
      last_error_text  = extract_error_detail(body) or extract_error_detail(last_status_line)
      if not last_error_text or last_error_text == "" then
        if body ~= "" then
          last_error_text = body
        elseif last_status_line ~= "" then
          last_error_text = last_status_line
        else
          last_error_text = "HTTP status " .. tostring(status_code)
        end
      end
      last_error = nil
      break
    elseif not success then
      last_error = "Request failed: " .. tostring(res)
    elseif not res then
      last_error = "Connection failed"
    else
      last_error = "HTTP error: " .. tostring(code)
    end

    if attempts < MAX_RETRY_ATTEMPTS then socket.sleep(RETRY_DELAY) end
  end

  if last_status_code then
    return false, last_status_code, last_error_text or last_status_line
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
    source = ltn12.source.string(body),
  })

  if not success then
    if status_code then
      local friendly = extract_error_detail(response_chunks) or tostring(response_chunks or "")
      error(string.format(
        "%s backend returned HTTP %s: %s",
        context_label, tostring(status_code),
        friendly ~= "" and friendly or "unknown error"
      ))
    end
    error(string.format(
      "Failed to contact %s backend after %d attempts. Last error: %s",
      context_label, MAX_RETRY_ATTEMPTS, tostring(response_chunks)
    ))
  end

  if type(response_chunks) ~= "table" then
    error(string.format("%s backend returned an invalid response buffer.", context_label))
  end
  local response_body = table.concat(response_chunks)
  if status_code ~= 200 then
    error(string.format(
      "%s backend error (%s): %s", context_label, tostring(status_code), response_body
    ))
  end

  local ok, decoded = pcall(json.decode, response_body)
  if not ok then
    error(string.format("Failed to decode %s response: %s", context_label, response_body))
  end
  return decoded, response_body
end

-- ── 公开 API ─────────────────────────────────────────────────────────────

function AiClient.dictionaryLookup(params)
  if type(params) ~= "table" then
    error("Reader AI dictionary query expects a parameter table.")
  end
  local term = Util.trim(params.term)
  if not term or term == "" then error("Reader AI dictionary query requires a term.") end

  local ep = resolve_read_endpoint()
  local payload = {
    action = params.action or "ask",
    text   = term,
  }
  add_read_metadata(payload, params)

  local decoded = perform_json_post(ep, payload, "Reader AI dictionary")
  if type(decoded) ~= "table" then
    error("Reader AI dictionary response did not contain a JSON object.")
  end
  -- 兼容性：某些后端用 output 而非 definition
  if decoded.definition == nil and decoded.output ~= nil
      and type(decoded.output) ~= "table" then
    decoded.definition = decoded.output
  end
  return decoded
end

function AiClient.summarizeContent(params)
  if type(params) ~= "table" then
    error("Reader AI summarize expects a parameter table.")
  end
  local content = Util.trim(params.content or params.text or params.highlight)
  if not content or content == "" then error("Reader AI summarize requires content text.") end

  local ep = resolve_read_endpoint()
  local payload = {
    action = "summarize",
    text   = content,
  }
  if params.context and params.context ~= "" and not params.question then
    payload.question = params.context
  end
  add_read_metadata(payload, params)

  local decoded = perform_json_post(ep, payload, "Reader AI summarize")
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
  return { summary = summary, raw = decoded }
end

function AiClient.analyzeContent(params)
  if type(params) ~= "table" then
    error("Reader AI analyze expects a parameter table.")
  end
  local content = Util.trim(params.content)
  if not content or content == "" then error("Reader AI analyze requires content text.") end

  local ep = resolve_read_endpoint()
  local payload = {
    action = "analyze",
    text   = content,
  }
  if type(params.focus_points) == "table" and #params.focus_points > 0
      and not params.question then
    payload.question = table.concat(params.focus_points, ", ")
  end
  add_read_metadata(payload, params)

  local decoded = perform_json_post(ep, payload, "Reader AI analyze")
  if type(decoded) ~= "table" then
    error("Reader AI analyze response did not contain a JSON object.")
  end
  return decoded
end

return AiClient
