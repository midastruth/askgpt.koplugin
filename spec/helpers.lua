-- Minimal test framework: assertions + KOReader mock factory
local H = {}

H.passed    = 0
H.failed    = 0
H._failures = {}

-- ── Serialization ─────────────────────────────────────────────────────────

local function serialize(v)
  if type(v) == "table" then
    local parts = {}
    for i, item in ipairs(v) do parts[i] = tostring(item) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(v)
end

local function values_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table"  then return a == b end
  if #a ~= #b            then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- ── Assertion helpers ──────────────────────────────────────────────────────

function H.section(name)
  print("\n[" .. name .. "]")
end

local function pass(desc)
  H.passed = H.passed + 1
  print("  PASS  " .. desc)
end

local function fail(desc, detail)
  H.failed = H.failed + 1
  print("  FAIL  " .. desc .. "\n         " .. detail)
  table.insert(H._failures, desc)
end

function H.eq(desc, got, expected)
  if values_equal(got, expected) then
    pass(desc)
  else
    fail(desc, "expected " .. serialize(expected) .. ", got " .. serialize(got))
  end
end

function H.is_true(desc, v)
  if v then pass(desc) else fail(desc, "expected truthy, got " .. tostring(v)) end
end

function H.is_false(desc, v)
  if not v then pass(desc) else fail(desc, "expected falsy, got " .. tostring(v)) end
end

function H.contains(desc, str, sub)
  if type(str) == "string" and str:find(sub, 1, true) then
    pass(desc)
  else
    fail(desc, "expected '" .. tostring(str) .. "' to contain '" .. tostring(sub) .. "'")
  end
end

function H.no_error(desc, fn)
  local ok, err = pcall(fn)
  if ok then pass(desc) else fail(desc, "unexpected error: " .. tostring(err)) end
end

-- ── Module cache helpers ───────────────────────────────────────────────────

function H.reset(...)
  for _, name in ipairs({...}) do
    package.loaded[name] = nil
  end
end

-- ── KOReader stub factory ──────────────────────────────────────────────────
-- Sets up package.loaded with minimal mocks for all KOReader dependencies.
-- Returns a spy table whose fields (.shown, .closed, .scheduled) are shared
-- with the mock closures — mutate spy.shown = {} to reset between tests.
-- spy.UIManager and spy.ffiutil expose the mock objects for overriding.
function H.mock_koreader()
  local spy = { shown = {}, closed = {}, scheduled = {} }

  -- gettext: identity function
  package.loaded["gettext"] = function(s) return s end

  -- UIManager
  local UIManager = {}
  UIManager.show      = function(_, w) table.insert(spy.shown, w) end
  UIManager.close     = function(_, w) table.insert(spy.closed, w) end
  UIManager.scheduleIn = function(_, delay, fn)
    table.insert(spy.scheduled, { delay = delay, fn = fn })
  end
  package.loaded["ui/uimanager"] = UIManager
  spy.UIManager = UIManager

  package.loaded["ui/widget/infomessage"] = {
    new = function(_, args)
      return { _type = "InfoMessage", text = args.text, timeout = args.timeout }
    end,
  }

  package.loaded["ui/widget/confirmbox"] = {
    new = function(_, args)
      return { _type = "ConfirmBox", text = args.text,
               ok_callback = args.ok_callback, ok_text = args.ok_text }
    end,
  }

  package.loaded["ui/widget/buttondialog"] = {
    new = function(_, args)
      return { _type = "ButtonDialog", title = args.title, buttons = args.buttons }
    end,
  }

  package.loaded["ui/widget/inputdialog"] = {
    new = function(_, args)
      return { _type = "InputDialog", getInputText = function() return "" end }
    end,
  }

  -- InputContainer: simple prototype factory
  local IC = {}
  IC.__index = IC
  IC.new = function(self, tbl)
    tbl = tbl or {}
    setmetatable(tbl, { __index = self })
    return tbl
  end
  package.loaded["ui/widget/container/inputcontainer"] = IC

  package.loaded["ui/network/manager"] = {
    isOnline      = function() return true end,
    runWhenOnline = function(_, fn) if fn then fn() end end,
  }

  package.loaded["device"] = {
    hasClipboard = function() return true end,
  }

  -- ffiutil: dot-notation calls, no self
  local ffiutil = {}
  ffiutil._fork_fails = false
  ffiutil.runInSubProcess = function(fn, with_pipe)
    if ffiutil._fork_fails then return nil, nil end
    return 999, 42
  end
  ffiutil.isSubProcessDone       = function(pid) return true end
  ffiutil.getNonBlockingReadSize = function(fd)  return 0 end
  ffiutil.readAllFromFD          = function(fd)  return "" end
  ffiutil.writeToFD              = function(fd, data, close_flag) end
  package.loaded["ffi/util"] = ffiutil
  spy.ffiutil = ffiutil

  -- Minimal JSON (only encode needed; decode not exercised in tests)
  package.loaded["json"] = {
    encode = function(t)
      if type(t) ~= "table" then return tostring(t) end
      local parts = {}
      for k, v in pairs(t) do
        local val = type(v) == "string" and ('"' .. v .. '"') or tostring(v)
        table.insert(parts, '"' .. tostring(k) .. '":' .. val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end,
    decode = function(s)
      return nil  -- not needed in current tests
    end,
  }

  -- ltn12, socket stubs (needed by ai_client but not exercised here)
  package.loaded["ltn12"] = {
    sink   = { table  = function(t) return function(c) if c then table.insert(t,c) end end end },
    source = { string = function(s) local d=false; return function() if not d then d=true; return s end end end },
  }
  package.loaded["socket"]      = { sleep = function() end }
  package.loaded["socket.http"] = { TIMEOUT = 10, request = function() return nil,nil,nil end }
  package.loaded["ssl.https"]   = { TIMEOUT = 10, request = function() return nil,nil,nil end }

  package.loaded["update_checker"] = { checkForUpdates = function() end }

  return spy
end

-- ── Summary ────────────────────────────────────────────────────────────────

function H.summary()
  local total = H.passed + H.failed
  print(string.format("\n=============================="))
  print(string.format("  %d/%d passed", H.passed, total))
  if H.failed > 0 then
    print("  Failed:")
    for _, f in ipairs(H._failures) do print("    - " .. f) end
  end
  print("==============================")
  return H.failed == 0
end

return H
