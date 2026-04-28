local H = require("spec.helpers")

H.section("E. main.lua")

local spy = H.mock_koreader()

-- Provide stub modules that main.lua requires
H.reset("main", "askgpt.config", "askgpt.dialog_controller",
        "askgpt.background_jobs", "askgpt.book_upload", "update_checker")

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
package.loaded["askgpt.book_upload"] = {
  upload_current = function() end,
  upload_file    = function() end,
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

-- ── Test init() in FileManager context ────────────────────────────────────

local fm_reg_calls       = {}
local fm_dialog_calls    = {}  -- addFileDialogButtons call log

local fake_fm_self = {
  ui = {
    -- Real KOReader FileManager loads plugins before file_chooser is created.
    -- addFileDialogButtons is the stable FileManager capability to detect.
    menu = {
      registerToMainMenu = function(_, obj)
        table.insert(fm_reg_calls, obj)
      end,
    },
    addFileDialogButtons = function(_, row_id, row_func)
      table.insert(fm_dialog_calls, { id = row_id, fn = row_func })
    end,
  },
}

H.reset("main")
AskGPT = require("main")

H.no_error("init() in FileManager context runs without error", function()
  AskGPT.init(fake_fm_self)
end)

H.eq("FileManager init() calls registerToMainMenu once", #fm_reg_calls, 1)
H.eq("FileManager init() registers one file dialog button row", #fm_dialog_calls, 1)
H.eq("file dialog row_id is 'askgpt_upload_file'",
     fm_dialog_calls[1] and fm_dialog_calls[1].id, "askgpt_upload_file")

local row_fn = fm_dialog_calls[1] and fm_dialog_calls[1].fn
-- non-file: should return nil (no button)
H.is_true("row_fn returns nil for non-file",
          row_fn and row_fn("/books/folder", false) == nil)
-- non-epub file: should return nil
H.is_true("row_fn returns nil for non-epub file",
          row_fn and row_fn("/books/book.pdf", true) == nil)
-- epub file: should return a table with one button
local buttons = row_fn and row_fn("/books/book.epub", true)
H.is_true("row_fn returns table for epub",  type(buttons) == "table")
H.is_true("button row has one entry",       buttons and #buttons == 1)
H.is_true("button has .text",               buttons and type(buttons[1].text) == "string")
H.is_true("button has .callback",           buttons and type(buttons[1].callback) == "function")

-- ── Test addToMainMenu() ───────────────────────────────────────────────────

local menu_items = {}
H.no_error("addToMainMenu() runs without error", function()
  AskGPT.addToMainMenu(fake_self, menu_items)
end)

H.is_true("addToMainMenu creates askgpt_upload_book key",
          menu_items.askgpt_upload_book ~= nil)
H.is_true("askgpt_upload_book.callback is a function",
          type(menu_items.askgpt_upload_book and menu_items.askgpt_upload_book.callback) == "function")
H.is_true("addToMainMenu creates askgpt_update key",
          menu_items.askgpt_update ~= nil)
H.is_true("askgpt_update.text is a string",
          type(menu_items.askgpt_update and menu_items.askgpt_update.text) == "string")
H.is_true("askgpt_update.callback is a function",
          type(menu_items.askgpt_update and menu_items.askgpt_update.callback) == "function")
H.is_true("addToMainMenu creates askgpt_results key",
          menu_items.askgpt_results ~= nil)
H.is_true("askgpt_results.text is a string",
          type(menu_items.askgpt_results and menu_items.askgpt_results.text) == "string")
H.is_true("askgpt_results.callback is a function",
          type(menu_items.askgpt_results and menu_items.askgpt_results.callback) == "function")

-- In FileManager context, askgpt_upload_book must NOT appear (no open book).
local fm_menu_items = {}
H.no_error("addToMainMenu() in FileManager context runs without error", function()
  AskGPT.addToMainMenu(fake_fm_self, fm_menu_items)
end)
H.is_true("FileManager addToMainMenu: no askgpt_upload_book key",
          fm_menu_items.askgpt_upload_book == nil)
H.is_true("FileManager addToMainMenu: askgpt_update still present",
          fm_menu_items.askgpt_update ~= nil)
H.is_true("FileManager addToMainMenu: askgpt_results still present",
          fm_menu_items.askgpt_results ~= nil)
