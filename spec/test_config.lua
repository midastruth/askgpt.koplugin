local H = require("spec.helpers")

H.section("B. askgpt/config.lua")

-- Helper: load a fresh Config with a given mock configuration value.
-- config_mock can be any value (table, string, nil …).
local function with_config(config_mock, fn)
  H.reset("askgpt.config", "configuration")
  package.loaded["configuration"] = config_mock
  local Config = require("askgpt.config")
  fn(Config)
  H.reset("askgpt.config", "configuration")
end

-- Non-table return from configuration.lua
with_config("not a table", function(Config)
  local ok, msg = Config.validate()
  H.is_false("non-table config: validate() returns false", ok)
  H.contains("non-table config: error mentions 'non-table'", msg, "non-table")
end)

-- nil configuration (module not found behaves the same way)
with_config(nil, function(Config)
  -- package.loaded["configuration"] = nil means require will try to find the
  -- file on disk.  Force a load failure by setting it to false (package.loaded
  -- false = "module not found, don't try again").
  -- Re-run with explicit false so require returns false → pcall ok=true but
  -- result is false (not a table).
  H.reset("askgpt.config", "configuration")
  package.loaded["configuration"] = false   -- signals "not found"
  local Config2 = require("askgpt.config")
  local ok, msg = Config2.validate()
  H.is_false("nil config: validate() returns false", ok)
end)

-- Both URLs empty
with_config({ reader_ai_base_url = "", base_url = "" }, function(Config)
  local ok, _ = Config.validate()
  H.is_false("empty URLs: validate() returns false", ok)
end)

-- base_url is an OpenAI completions endpoint → rejected
with_config({ base_url = "https://api.openai.com/v1/chat/completions" }, function(Config)
  local ok, _ = Config.validate()
  H.is_false("OpenAI completions URL: validate() returns false", ok)
end)

-- Valid reader_ai_base_url
with_config({ reader_ai_base_url = "https://example.com" }, function(Config)
  local ok, cfg = Config.validate()
  H.is_true("reader_ai_base_url set: validate() returns true", ok)
  H.is_true("reader_ai_base_url: returns cfg table", type(cfg) == "table")
end)

-- Valid non-OpenAI base_url
with_config({ base_url = "https://example.com/ai" }, function(Config)
  local ok, _ = Config.validate()
  H.is_true("non-OpenAI base_url: validate() returns true", ok)
end)

-- reader_ai_base_url takes priority over base_url
with_config({ reader_ai_base_url = "https://primary.example.com",
              base_url           = "" }, function(Config)
  local ok, _ = Config.validate()
  H.is_true("reader_ai_base_url wins over empty base_url", ok)
end)
