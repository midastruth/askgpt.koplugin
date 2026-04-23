local H = require("spec.helpers")

H.section("F. askgpt/workflow.lua")

local spy = H.mock_koreader()

-- ── Mock all workflow dependencies ────────────────────────────────────────

H.reset("askgpt.workflow", "askgpt.background_jobs", "askgpt.ai_client",
        "chatgptviewer", "askgpt.formatter", "askgpt.errors",
        "askgpt.util", "askgpt.highlight")

local bj_calls = {}
package.loaded["askgpt.background_jobs"] = {
  submit_summary    = function(...) table.insert(bj_calls, { kind="summary", n = select("#",...) }) end,
  submit_analyze    = function(...) table.insert(bj_calls, { kind="analyze", n = select("#",...) }) end,
  show_results_menu = function() end,
}

local ai_calls = {}
package.loaded["askgpt.ai_client"] = {
  dictionaryLookup = function(params)
    table.insert(ai_calls, params)
    return { term = params.term, definition = "mock definition" }
  end,
  MAX_RETRY_ATTEMPTS = 3,
}

package.loaded["chatgptviewer"] = {
  new = function(_, args)
    return { _type = "ChatGPTViewer", update = function() end }
  end,
}

package.loaded["askgpt.formatter"] = {
  dictionary = function(args) return "dict:" .. (args.term or "?") end,
  summary    = function(args) return "sum" end,
  analysis   = function(args) return "ana" end,
}

package.loaded["askgpt.errors"] = {
  show              = function() end,
  show_request_error = function() end,
}

-- Make scheduleIn execute its callback synchronously so lookup is testable
spy.UIManager.scheduleIn = function(_, delay, fn)
  if fn then fn() end
end

local Workflow = require("askgpt.workflow")

-- Shared fake UI
local fake_ui = {
  document = {
    getProps = function() return { title = "Test Book", authors = "Test Author" } end,
  },
  highlight = {
    addNote  = function() end,
    onClose  = function() end,
    addToHighlightDialog = function() end,
  },
  menu = { registerToMainMenu = function() end },
}

-- ── summarize → BackgroundJobs.submit_summary ─────────────────────────────

bj_calls = {}
H.no_error("summarize() runs without error", function()
  Workflow.summarize(fake_ui, { content = "some text" }, "some text")
end)
H.eq("summarize() delegates to BackgroundJobs", #bj_calls, 1)
H.eq("summarize() kind is 'summary'", bj_calls[1] and bj_calls[1].kind, "summary")

-- ── analyze → BackgroundJobs.submit_analyze ───────────────────────────────

bj_calls = {}
H.no_error("analyze() runs without error", function()
  Workflow.analyze(fake_ui, { content = "some text" }, "some text")
end)
H.eq("analyze() delegates to BackgroundJobs", #bj_calls, 1)
H.eq("analyze() kind is 'analyze'", bj_calls[1] and bj_calls[1].kind, "analyze")

-- ── lookup → synchronous, does NOT touch BackgroundJobs ──────────────────

bj_calls = {}
ai_calls = {}
spy.shown = {}

H.no_error("lookup() runs without error", function()
  Workflow.lookup(fake_ui, {
    term             = "serendipity",
    highlighted_text = "serendipity",
  }, "serendipity")
end)

H.eq("lookup() does NOT call BackgroundJobs", #bj_calls, 0)
H.eq("lookup() calls AiClient.dictionaryLookup", #ai_calls, 1)

-- Viewer should have been shown
local viewer_shown = false
for _, w in ipairs(spy.shown) do
  if w._type == "ChatGPTViewer" then viewer_shown = true end
end
H.is_true("lookup() shows ChatGPTViewer", viewer_shown)
