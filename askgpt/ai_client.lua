-- AI HTTP 客户端：endpoint 解析、HTTP/HTTPS 选择、JSON POST、重试
-- timeout 单位：秒（LuaSocket/ssl.https 均以秒计）
local json   = require("json")
local ltn12  = require("ltn12")
local http   = require("socket.http")
local https  = require("ssl.https")
local socket = require("socket")

local Util   = require("askgpt.util")
local Config = require("askgpt.config")

local REQUEST_TIMEOUT          = 10   -- 秒
local BOOK_LOOKUP_TIMEOUT      = 30   -- 秒
local IMPORT_EPUB_TIMEOUT      = 300  -- 秒：EPUB 上传/后端导入可能较慢
local MAX_RETRY_ATTEMPTS       = 3
local RETRY_DELAY              = 2    -- 秒

local DEFAULT_READ_PATH        = "/ai/query"
local DEFAULT_ASK_STREAM_PATH  = "/ai/query/stream"
local DEFAULT_IMPORT_EPUB_PATH = "/books/import/epub"
local DEFAULT_BOOKS_PATH       = "/books"

local AiClient = {}
AiClient.MAX_RETRY_ATTEMPTS = MAX_RETRY_ATTEMPTS  -- 供外部错误提示引用

-- ── 内部工具 ─────────────────────────────────────────────────────────────

local function choose_lib(url)
  if type(url) == "string" and url:match("^https://") then return https end
  return http
end

local function extract_error_detail(raw_error)
  local function stringify_detail(detail)
    if detail == nil then return nil end
    if type(detail) == "table" then
      local nested = stringify_detail(detail.detail or detail.message or detail.error or detail.error_description)
      if nested then
        local code = detail.code and tostring(detail.code) or nil
        return code and (code .. ": " .. nested) or nested
      end
      local enc_ok, encoded = pcall(json.encode, detail)
      detail = enc_ok and encoded or tostring(detail)
    elseif type(detail) ~= "string" then
      detail = tostring(detail)
    end
    detail = Util.trim(detail)
    return detail ~= "" and detail or nil
  end

  if raw_error == nil then return nil end
  if type(raw_error) ~= "string" then raw_error = tostring(raw_error) end
  local message = Util.trim(raw_error)
  if message == "" then return nil end
  local first = message:sub(1, 1)
  if first == "{" or first == "[" then
    local ok, decoded = pcall(json.decode, message)
    if ok and type(decoded) == "table" then
      local detail = stringify_detail(decoded.detail or decoded.message or decoded.error or decoded.error_description)
      if detail then return detail end
    end
  end
  return message
end

local function format_bytes(bytes)
  bytes = tonumber(bytes)
  if not bytes then return "unknown size" end
  local units = { "B", "KB", "MB", "GB" }
  local value = bytes
  local unit = 1
  while value >= 1024 and unit < #units do
    value = value / 1024
    unit = unit + 1
  end
  if unit == 1 then return string.format("%d %s", value, units[unit]) end
  return string.format("%.1f %s", value, units[unit])
end

local function upload_payload_hint(context_label, request_body)
  if context_label ~= "Book-Aware EPUB import" or type(request_body) ~= "string" then
    return ""
  end
  local body_size = #request_body
  if body_size < 4 * 1024 * 1024 then return "" end
  local epub_size = math.floor(body_size * 3 / 4)
  return string.format(
    " (upload payload size: %s, EPUB roughly %s; if you use the public read.opensociety.eu.org backend, this usually means the EPUB is larger than its request-body limit. Use a smaller EPUB, raise the backend/proxy body-size limit, or switch to a backend that supports streaming/multipart upload.)",
    format_bytes(body_size), format_bytes(epub_size)
  )
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

local function pick_config_value(key)
  local cfg = Config.get()
  if not cfg then return nil end
  local current = cfg
  for part in key:gmatch("[^%.]+") do
    if type(current) ~= "table" then return nil end
    current = current[part]
  end
  return current
end

local function pick_config_path(key)
  local value = pick_config_value(key)
  if type(value) == "string" and value ~= "" then return value end
  return nil
end

local function pick_config_number(key)
  local value = pick_config_value(key)
  if value == nil or value == "" then return nil end
  value = tonumber(value)
  if value and value > 0 then return value end
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

local function resolve_service_base_url()
  local base = resolve_base_url()
  base = base:gsub("/ai/query$", "")
             :gsub("/ai/read$", "")
             :gsub("/query$", "")
             :gsub("/read$", "")
             :gsub("/ai$", "")
  return base
end

local function resolve_ask_stream_endpoint()
  local path = normalize_path(
    pick_config_path("reader_ai_ask_stream_path") or DEFAULT_ASK_STREAM_PATH
  )
  return resolve_service_base_url() .. path
end

local function resolve_import_epub_endpoint()
  local path = normalize_path(
    pick_config_path("reader_ai_import_epub_path") or DEFAULT_IMPORT_EPUB_PATH
  )
  return resolve_service_base_url() .. path
end

local function url_encode(value)
  return tostring(value or ""):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

local function resolve_book_lookup_endpoint(sha256)
  local path = normalize_path(pick_config_path("reader_ai_books_path") or DEFAULT_BOOKS_PATH)
  if path:sub(-1) == "/" then path = path:sub(1, -2) end
  return resolve_service_base_url() .. path .. "/" .. url_encode(sha256)
end

local function resolve_book_lookup_timeout()
  return pick_config_number("reader_ai_book_lookup_timeout")
      or pick_config_number("book_aware_lookup_timeout")
      or BOOK_LOOKUP_TIMEOUT
end

local function resolve_import_epub_timeout()
  return pick_config_number("reader_ai_import_epub_timeout")
      or pick_config_number("reader_ai_import_timeout")
      or pick_config_number("reader_ai_upload_timeout")
      or pick_config_number("book_aware_upload_timeout")
      or IMPORT_EPUB_TIMEOUT
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

local function http_request_with_retry(request_params, timeout)
  timeout = timeout or REQUEST_TIMEOUT
  local lib = choose_lib(request_params.url)
  local attempts = 0
  local last_error, last_status_code, last_error_text, last_status_line

  while attempts < MAX_RETRY_ATTEMPTS do
    attempts = attempts + 1

    local prev_http_timeout  = http.TIMEOUT
    local prev_https_timeout = https.TIMEOUT
    http.TIMEOUT  = timeout
    https.TIMEOUT = timeout

    local response_chunks = {}
    local req_copy  = Util.clone_table(request_params)
    req_copy.sink   = ltn12.sink.table(response_chunks)

    local success, res, code, _, status_line = pcall(function()
      return lib.request(req_copy)
    end)

    http.TIMEOUT  = prev_http_timeout
    https.TIMEOUT = prev_https_timeout

    -- LuaSocket/LuaSec may return transport errors such as "timeout",
    -- "wantread", or "wantwrite" in the second return value.  These are
    -- not HTTP status codes and must be treated as retryable connection
    -- failures instead of being reported as "HTTP wantread".
    local status_code = tonumber(code)
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
      local transport_error = code or status_line
      if transport_error ~= nil and tostring(transport_error) ~= "" then
        last_error = "Connection failed: " .. tostring(transport_error)
      else
        last_error = "Connection failed"
      end
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

local function perform_json_post(endpoint, payload, context_label, timeout)
  local body = json.encode(payload)
  local payload_hint = upload_payload_hint(context_label, body)
  local success, status_code, response_chunks = http_request_with_retry({
    url     = endpoint,
    method  = "POST",
    headers = {
      ["Accept"]         = "application/json",
      ["Content-Type"]   = "application/json",
      ["Content-Length"] = tostring(#body),
    },
    source = ltn12.source.string(body),
  }, timeout)

  if not success then
    if status_code then
      local friendly = extract_error_detail(response_chunks) or tostring(response_chunks or "")
      error(string.format(
        "%s backend returned HTTP %s: %s%s",
        context_label, tostring(status_code),
        friendly ~= "" and friendly or "unknown error",
        payload_hint
      ))
    end
    error(string.format(
      "Failed to contact %s backend after %d attempts. Last error: %s%s",
      context_label, MAX_RETRY_ATTEMPTS, tostring(response_chunks), payload_hint
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

  local decoded = perform_json_post(ep, payload, "Reader AI summarize", 90)
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

  local decoded = perform_json_post(ep, payload, "Reader AI analyze", 90)
  if type(decoded) ~= "table" then
    error("Reader AI analyze response did not contain a JSON object.")
  end
  return decoded
end

function AiClient.getBook(sha256)
  sha256 = Util.trim(sha256 or "")
  if sha256 == "" then error("Book-Aware book lookup requires sha256.") end

  local endpoint = resolve_book_lookup_endpoint(sha256)
  local success, status_code, response_chunks = http_request_with_retry({
    url     = endpoint,
    method  = "GET",
    headers = { ["Accept"] = "application/json" },
  }, resolve_book_lookup_timeout())

  if not success then
    if tonumber(status_code) == 404 then return nil end
    if status_code then
      local friendly = extract_error_detail(response_chunks) or tostring(response_chunks or "")
      error(string.format(
        "Book-Aware book lookup returned HTTP %s: %s",
        tostring(status_code), friendly ~= "" and friendly or "unknown error"
      ))
    end
    error(string.format(
      "Failed to contact Book-Aware book lookup after %d attempts. Last error: %s",
      MAX_RETRY_ATTEMPTS, tostring(response_chunks)
    ))
  end

  if type(response_chunks) ~= "table" then
    error("Book-Aware book lookup returned an invalid response buffer.")
  end
  local response_body = table.concat(response_chunks)
  local ok, decoded = pcall(json.decode, response_body)
  if not ok then
    error("Failed to decode Book-Aware book lookup response: " .. response_body)
  end
  return decoded
end

function AiClient.importEpub(params)
  if type(params) ~= "table" then
    error("Book-Aware EPUB import expects a parameter table.")
  end
  if type(params.content_base64) ~= "string" or params.content_base64 == "" then
    error("Book-Aware EPUB import requires content_base64.")
  end

  local payload = {
    filename       = params.filename or "book.epub",
    content_base64 = params.content_base64,
    book           = params.book or {},
  }
  if params.markdown and params.markdown ~= "" then payload.markdown = params.markdown end
  if params.markdown_path and params.markdown_path ~= "" then payload.markdown_path = params.markdown_path end

  local decoded = perform_json_post(
    resolve_import_epub_endpoint(), payload,
    "Book-Aware EPUB import", resolve_import_epub_timeout()
  )
  if type(decoded) ~= "table" then
    error("Book-Aware EPUB import response did not contain a JSON object.")
  end
  return decoded
end

-- ── SSE 流式 Ask ─────────────────────────────────────────────────────────
-- 在子进程中调用；把增量文字和最终结果写入 tmpfile，供主进程轮询。
-- 写入格式：
--   增量中：直接写累积文字
--   完成时：累积文字 .. "<<ASKGPT_DONE>>" .. json(final)
--   出错时："<<ASKGPT_ERROR>>" .. message
function AiClient.streamAsk(params, tmpfile)
  if type(params) ~= "table" then
    error("streamAsk expects a parameter table.")
  end

  local endpoint = resolve_ask_stream_endpoint()
  local lib      = choose_lib(endpoint)

  local payload = {
    action = "ask",
    text   = Util.trim(params.text or params.term or ""),
  }
  add_read_metadata(payload, params)
  local body = json.encode(payload)

  local accumulated = ""
  local line_buf    = ""
  local finished    = false

  local function write_tmp(content)
    local f = io.open(tmpfile, "w")
    if f then f:write(content) f:close() end
  end

  local function process_line(line)
    if finished then return end
    if not line:match("^data: ") then return end
    local data = line:sub(7)
    if data == "" then return end

    local ok, ev = pcall(json.decode, data)
    if not ok or type(ev) ~= "table" then return end

    if type(ev.text) == "string" then
      accumulated = accumulated .. ev.text
      write_tmp(accumulated)
    elseif ev.answer ~= nil then
      finished = true
      local final_blob = json.encode({
        answer     = ev.answer,
        sources    = ev.sources,
        session_id = ev.session_id,
      })
      write_tmp(accumulated .. "<<ASKGPT_DONE>>" .. final_blob)
    elseif ev.code ~= nil then
      finished = true
      write_tmp("<<ASKGPT_ERROR>>" .. tostring(ev.message or ev.code))
    end
  end

  local sink = function(chunk, _)
    if chunk == nil then
      if line_buf ~= "" then
        process_line(line_buf)
        line_buf = ""
      end
      return 1
    end
    line_buf = line_buf .. chunk
    while true do
      local nl = line_buf:find("\n")
      if not nl then break end
      local line = line_buf:sub(1, nl - 1):gsub("\r$", "")
      line_buf = line_buf:sub(nl + 1)
      process_line(line)
    end
    return 1
  end

  local prev_timeout = lib.TIMEOUT
  lib.TIMEOUT = 90

  local ok, res, code = pcall(function()
    return lib.request({
      url    = endpoint,
      method = "POST",
      headers = {
        ["Accept"]         = "text/event-stream",
        ["Content-Type"]   = "application/json",
        ["Content-Length"] = tostring(#body),
      },
      source = ltn12.source.string(body),
      sink   = sink,
    })
  end)

  lib.TIMEOUT = prev_timeout

  if not finished then
    if not ok then
      write_tmp("<<ASKGPT_ERROR>>Connection failed: " .. tostring(res))
    elseif not res or (tonumber(code) and tonumber(code) ~= 200) then
      write_tmp("<<ASKGPT_ERROR>>HTTP " .. tostring(code))
    else
      write_tmp("<<ASKGPT_ERROR>>Stream ended without final event")
    end
  end
end

return AiClient
