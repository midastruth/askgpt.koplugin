local H = require("spec.helpers")

H.section("E. main.lua")

local spy = H.mock_koreader()

-- Provide stub modules that main.lua requires
H.reset("main", "askgpt.config", "askgpt.dialog_controller",
        "askgpt.background_jobs", "update_checker")

package.loaded["askgpt.config"] = {
  validate = function() return true, {} end,
  get      = function() return {} end,
}
package.loaded["askgpt.dialog_controller"] = { show = function() end }
package.loaded["askgpt.background_jobs"]   = {
  submit_summary    = function() end,
  submit_analyze    = function() end,
  show_results_menu = function() end,
}
-- update_checker already set by mock_koreader

local AskGPT = require("main")

H.is_true("main.lua returns a table (AskGPT object)", type(AskGPT) == "table")

-- ── Test init() ────────────────────────────────────────────────────────────

local reg_calls = {}   -- registerToMainMenu call log
local add_calls = {}   -- addToHighlightDialog call log

local fake_self = {
  ui = {
    menu = {
      registerToMainMenu = function(_, obj)
        table.insert(reg_calls, obj)
      end,
    },
    highlight = {
      addToHighlightDialog = function(_, key, factory_fn)
        table.insert(add_calls, { key = key, fn = factory_fn })
      end,
    },
  },
}

H.no_error("init() runs without error", function()
  AskGPT.init(fake_self)
end)

H.eq("init() calls registerToMainMenu once", #reg_calls, 1)
H.eq("init() calls addToHighlightDialog once", #add_calls, 1)
H.eq("addToHighlightDialog key is 'askgpt_GPT'",
     add_calls[1] and add_calls[1].key, "askgpt_GPT")

-- The factory function returned to addToHighlightDialog should produce a table
-- with .text and .callback
local factory = add_calls[1] and add_calls[1].fn
if factory then
  local entry = factory({})          -- pass a dummy highlight source
  H.is_true("highlight entry has .text",     type(entry.text) == "string")
  H.is_true("highlight entry has .callback", type(entry.callback) == "function")
else
  H.is_false("factory_fn was registered", true)  -- force fail
end

-- ── Test addToMainMenu() ───────────────────────────────────────────────────

local menu_items = {}
H.no_error("addToMainMenu() runs without error", function()
  AskGPT.addToMainMenu(fake_self, menu_items)
end)

H.is_true("addToMainMenu creates askgpt_results key",
          menu_items.askgpt_results ~= nil)
H.is_true("askgpt_results.text is a string",
          type(menu_items.askgpt_results and menu_items.askgpt_results.text) == "string")
H.is_true("askgpt_results.callback is a function",
          type(menu_items.askgpt_results and menu_items.askgpt_results.callback) == "function")
