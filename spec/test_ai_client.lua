local H = require("spec.helpers")

H.section("H. askgpt/ai_client.lua")

-- ── shared state ──────────────────────────────────────────────────────────

local last_https_timeout = nil
local request_results    = {}  -- queue: each entry is returned by next request()

local function next_result()
  return table.remove(request_results, 1) or { nil, nil, nil }
end

-- Pre-declare so closures can capture by upvalue (Lua self-reference pattern).
local http_lib
local https_lib

local function make_libs()
  http_lib = {
    TIMEOUT = 10,
    request = function(_)
      local r = next_result()
      return r[1], r[2], r[3]
    end,
  }
  https_lib = {
    TIMEOUT = 10,
    request = function(_)
      last_https_timeout = https_lib.TIMEOUT  -- upvalue; valid after assignment
      local r = next_result()
      return r[1], r[2], r[3]
    end,
  }
end

-- ── helper: fresh AiClient with controllable request mocks ────────────────

local function load_ai_client(base_url)
  H.reset("askgpt.ai_client", "askgpt.config", "askgpt.util")
  package.loaded["socket.http"] = http_lib
  package.loaded["ssl.https"]   = https_lib
  package.loaded["socket"]      = { sleep = function() end }
  package.loaded["ltn12"] = {
    sink   = { table  = function(t) return function(c) if c then table.insert(t, c) end return 1 end end },
    source = { string = function(s) local d=false return function() if not d then d=true return s end end end },
  }
  package.loaded["json"] = {
    encode = function() return "{}" end,
    decode = function() return {} end,
  }
  package.loaded["askgpt.config"] = {
    get      = function() return { reader_ai_base_url = base_url or "https://example.com" } end,
    validate = function() return true end,
  }
  return require("askgpt.ai_client")
end

-- ── Section 1: timeout propagation ────────────────────────────────────────

-- analyzeContent must use 90s timeout on the HTTPS lib.
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  last_https_timeout = nil
  local AiClient = load_ai_client()
  pcall(AiClient.analyzeContent, { content = "test" })
  H.eq("analyzeContent uses 90s timeout", last_https_timeout, 90)
end

-- summarizeContent must also use 90s timeout.
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  last_https_timeout = nil
  local AiClient = load_ai_client()
  pcall(AiClient.summarizeContent, { content = "test" })
  H.eq("summarizeContent uses 90s timeout", last_https_timeout, 90)
end

-- dictionaryLookup should use the default 10s timeout.
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  last_https_timeout = nil
  local AiClient = load_ai_client()
  pcall(AiClient.dictionaryLookup, { term = "serendipity" })
  H.eq("dictionaryLookup uses default 10s timeout", last_https_timeout, 10)
end

-- TIMEOUT is restored after each request (no global side-effect).
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  local AiClient = load_ai_client()
  pcall(AiClient.analyzeContent, { content = "test" })
  H.eq("https TIMEOUT restored after analyzeContent", https_lib.TIMEOUT, 10)
end

-- ── Section 2: wantread / transport error classification ──────────────────

-- LuaSec returns (nil, "wantread", nil) when a non-blocking SSL read times out.
-- ai_client should surface this as "Connection failed: wantread", not an HTTP error.
do
  make_libs()
  -- res=nil, code="wantread" → triggers the `elseif not res` branch
  for _ = 1, 3 do request_results[#request_results+1] = {nil, "wantread", nil} end
  local AiClient = load_ai_client()
  local ok, err = pcall(AiClient.analyzeContent, { content = "test" })
  H.is_false("wantread causes error (not success)", ok)
  H.contains("wantread error mentions 'Connection failed'", tostring(err), "Connection failed")
  H.contains("wantread error mentions 'wantread'",          tostring(err), "wantread")
end

-- ── Section 3: retry count ─────────────────────────────────────────────────

-- On repeated connection failure the client retries exactly MAX_RETRY_ATTEMPTS times.
do
  local call_count = 0
  http_lib  = { TIMEOUT = 10, request = function(_) call_count = call_count + 1 return nil, nil, nil end }
  https_lib = { TIMEOUT = 10, request = function(_) call_count = call_count + 1 return nil, nil, nil end }
  local AiClient = load_ai_client()
  pcall(AiClient.analyzeContent, { content = "test" })
  H.eq("analyzeContent retries MAX_RETRY_ATTEMPTS (3) times",
       call_count, AiClient.MAX_RETRY_ATTEMPTS)
end

-- ── Section 4: success path ────────────────────────────────────────────────

-- When the server returns HTTP 200, analyzeContent returns the decoded table.
do
  make_libs()
  -- res=1, code=200 → success branch in http_request_with_retry
  request_results = { {1, 200, {}} }
  local AiClient = load_ai_client()
  -- Mutate the shared json table so the module sees the updated decode.
  package.loaded["json"].decode = function() return { answer = "ok" } end
  local ok, result = pcall(AiClient.analyzeContent, { content = "test" })
  H.is_true("analyzeContent succeeds on HTTP 200", ok)
  H.is_true("analyzeContent returns a table", type(result) == "table")
end

-- ── Section 5: input validation ───────────────────────────────────────────

do
  make_libs()
  local AiClient = load_ai_client()

  local ok1, err1 = pcall(AiClient.analyzeContent, { content = "" })
  H.is_false("analyzeContent rejects empty content", ok1)
  H.contains("analyzeContent empty content error", tostring(err1), "requires content")

  local ok2 = pcall(AiClient.analyzeContent, nil)
  H.is_false("analyzeContent rejects nil params", ok2)

  local ok3 = pcall(AiClient.summarizeContent, { content = "" })
  H.is_false("summarizeContent rejects empty content", ok3)

  local ok4 = pcall(AiClient.dictionaryLookup, { term = "" })
  H.is_false("dictionaryLookup rejects empty term", ok4)
end
