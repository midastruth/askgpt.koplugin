-- Unit tests for annotation_sync.lua (Phase 2 + Phase 3)
-- Phase 2: 5 disambiguation scenarios + list_conflicts
-- Phase 3: backend-id storage, push changes, tombstone handling

local H = require("spec.helpers")
H.section("F. annotation_sync.lua (Phase 2+3)")

local SHA = string.rep("a", 64)

-- ── mock infrastructure ────────────────────────────────────────────────────

local function reset_modules()
  H.reset("askgpt.annotation_sync", "askgpt.ai_client", "askgpt.util", "ui/event")
  package.loaded["askgpt.util"] = { sha256_file = function() error("not used in tests") end }
  package.loaded["ui/event"] = {
    new = function(_, name, data) return { name = name, data = data } end,
  }
end

-- Build a spy AiClient loaded with the given pending highlights.
-- Returns the client table and the update_calls log.
local function make_ai_client(pending_hls)
  local update_calls = {}
  local ai = {
    listHighlights  = function(_sha, _status) return { highlights = pending_hls } end,
    updateHighlight = function(_sha, id, patch)
      table.insert(update_calls, { id = id, patch = patch })
      return {}
    end,
  }
  package.loaded["askgpt.ai_client"] = ai
  return ai, update_calls
end

-- Build a minimal fake ui object.
-- find_fn: function(self, text, ...) → array of candidate tables
-- opts.pages: table[xpointer] = page_number
-- opts.toc_pages: table[page_number] = chapter_title
-- opts.page_count: total pages (default 100)
-- opts.saved_color: KOReader saved_color (default "gray")
local function make_ui(find_fn, opts)
  opts = opts or {}
  local annotation = {
    _calls      = {},
    annotations = {},
    addItem = function(self, item)
      table.insert(self._calls, item)
      table.insert(self.annotations, item)
      return #self.annotations
    end,
  }
  local toc = nil
  if opts.toc_pages then
    toc = {
      getTocTitleByPage = function(self, page)
        return opts.toc_pages[page] or ""
      end,
    }
  end
  return {
    document = {
      file                = "/fake/book.epub",
      findAllText         = find_fn or function() return {} end,
      getPageFromXPointer = function(self, xp)
        return (opts.pages and opts.pages[xp]) or 1
      end,
      getPageCount = function() return opts.page_count or 100 end,
    },
    annotation   = annotation,
    rolling      = true,
    toc          = toc,
    view         = { highlight = { saved_color = opts.saved_color or "gray" } },
    doc_settings = {
      readSetting = function(self, key)
        return key == "file_sha256" and SHA or nil
      end,
      saveSetting = function() end,
    },
    handleEvent = function() end,
  }
end

-- ── Scenario 1: unique candidate → resolved, addItem called ───────────────

do
  reset_modules()
  local _, updates = make_ai_client({
    {
      id     = "hl-001",
      exact  = "The quick brown fox",
      prefix = "Once upon a time ",
      suffix = " jumps over the lazy dog",
    },
  })

  local ui = make_ui(function(self, text)
    if text == "The quick brown fox" then
      return {{
        start     = "/body/p[1].0",
        ["end"]   = "/body/p[1].19",
        prev_text = "Once upon a time ",
        next_text = " jumps over the lazy dog",
      }}
    end
    return {}
  end)

  local AS = require("askgpt.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T1 resolved=1",          r.resolved, 1)
  H.eq("T1 conflict=0",          r.conflict, 0)
  H.eq("T1 failed=0",            r.failed, 0)
  H.eq("T1 addItem called once", #ui.annotation._calls, 1)
  H.eq("T1 backend update once", #updates, 1)
  H.eq("T1 status=resolved",     updates[1].patch.koreader.status, "resolved")
  H.eq("T1 pos0 correct",        updates[1].patch.koreader.pos0, "/body/p[1].0")
  H.eq("T1 pos1 correct",        updates[1].patch.koreader.pos1, "/body/p[1].19")
end

-- ── Scenario 2: multiple candidates, clear winner → resolved to correct one

do
  reset_modules()
  local _, updates = make_ai_client({
    {
      id     = "hl-002",
      exact  = "luminous grace",
      prefix = "bathed in this luminous grace the sky",
      suffix = " falls upon the valley below us",
    },
  })

  local ui = make_ui(function(self, text)
    if text == "luminous grace" then
      return {
        { -- Winner: context matches perfectly (similarity 1.0 for both)
          start     = "/body/p[2].0",
          ["end"]   = "/body/p[2].14",
          prev_text = "bathed in this luminous grace the sky",
          next_text = " falls upon the valley below us",
        },
        { -- Noise: completely different context
          start     = "/body/p[10].0",
          ["end"]   = "/body/p[10].14",
          prev_text = "",
          next_text = "",
        },
        { -- Also noise
          start     = "/body/p[20].0",
          ["end"]   = "/body/p[20].14",
          prev_text = "",
          next_text = "",
        },
      }
    end
    return {}
  end)

  local AS = require("askgpt.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T2 resolved=1",                     r.resolved, 1)
  H.eq("T2 conflict=0",                     r.conflict, 0)
  H.eq("T2 addItem called once",            #ui.annotation._calls, 1)
  H.eq("T2 resolved to correct candidate",  updates[1].patch.koreader.pos0, "/body/p[2].0")
end

-- ── Scenario 3: multiple candidates, scores tied → conflict, no addItem ───

do
  reset_modules()
  local _, updates = make_ai_client({
    {
      id     = "hl-003",
      exact  = "the gathering light",
      prefix = "we watched as the gathering light",
      suffix = " faded slowly into the horizon",
    },
  })

  -- Both candidates have identical context → scores tied, margin = 0.
  local same_prev = "we watched as the gathering light"
  local same_next = " faded slowly into the horizon"

  local ui = make_ui(function(self, text)
    if text == "the gathering light" then
      return {
        {
          start     = "/body/p[1].0",
          ["end"]   = "/body/p[1].19",
          prev_text = same_prev,
          next_text = same_next,
        },
        {
          start     = "/body/p[5].0",
          ["end"]   = "/body/p[5].19",
          prev_text = same_prev,
          next_text = same_next,
        },
      }
    end
    return {}
  end)

  local AS = require("askgpt.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T3 conflict=1",         r.conflict, 1)
  H.eq("T3 resolved=0",         r.resolved, 0)
  H.eq("T3 addItem NOT called", #ui.annotation._calls, 0)
  H.eq("T3 status=conflict",    updates[1].patch.koreader.status, "conflict")
  H.eq("T3 candidates_count=2", updates[1].patch.koreader.candidates_count, 2)
  H.is_true("T3 error mentions 2 candidates",
    type(updates[1].patch.koreader.error) == "string" and
    updates[1].patch.koreader.error:find("2 candidates") ~= nil)
  H.is_true("T3 conflict_scores present",
    type(updates[1].patch.koreader.conflict_scores) == "table")
end

-- ── Scenario 4: text not found → failed, no addItem ──────────────────────

do
  reset_modules()
  local _, updates = make_ai_client({
    {
      id    = "hl-004",
      exact = "xyzzy this text does not appear anywhere",
    },
  })

  local ui = make_ui(function() return {} end)

  local AS = require("askgpt.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T4 failed=1",           r.failed, 1)
  H.eq("T4 resolved=0",         r.resolved, 0)
  H.eq("T4 addItem NOT called", #ui.annotation._calls, 0)
  H.eq("T4 status=failed",      updates[1].patch.koreader.status, "failed")
  H.contains("T4 error mentions not found",
    updates[1].patch.koreader.error or "", "not found")
end

-- ── Scenario 5: short text, multiple candidates → conflict ────────────────
-- A margin of 40 pts would auto-resolve for normal text (MIN_MARGIN=15)
-- but conflicts for short text (SHORT_MARGIN=45).

do
  reset_modules()
  local _, updates = make_ai_client({
    {
      id     = "hl-005",
      exact  = "me",     -- 2 chars < SHORT_TEXT_CHARS=8 → short text
      prefix = "tell",   -- used for scoring
    },
  })

  local ui = make_ui(function(self, text)
    if text == "me" then
      return {
        { -- Better candidate: prefix exact match → 40 pts
          start     = "/body/p[1].0",
          ["end"]   = "/body/p[1].2",
          prev_text = "tell",   -- identical to hl.prefix → similarity=1.0 → 40 pts
          next_text = "",
        },
        { -- Worse candidate: no context → 0 pts
          start     = "/body/p[9].0",
          ["end"]   = "/body/p[9].2",
          prev_text = "",
          next_text = "",
        },
      }
    end
    return {}
  end)

  -- Margin = 40 - 0 = 40.
  -- Normal text: 40 >= MIN_MARGIN(15) → would resolve.
  -- Short text:  40 <  SHORT_MARGIN(45) → must conflict.
  local AS = require("askgpt.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T5 conflict=1 (short text conservatism)", r.conflict, 1)
  H.eq("T5 resolved=0",    r.resolved, 0)
  H.eq("T5 addItem NOT called", #ui.annotation._calls, 0)
  H.eq("T5 status=conflict",   updates[1].patch.koreader.status, "conflict")
  H.is_true("T5 error mentions short text",
    type(updates[1].patch.koreader.error) == "string" and
    updates[1].patch.koreader.error:find("short") ~= nil)
  H.is_true("T5 conflict_scores.margin is 40",
    type(updates[1].patch.koreader.conflict_scores) == "table" and
    math.abs(updates[1].patch.koreader.conflict_scores.margin - 40) < 0.01)
end

-- ── Bonus: list_conflicts returns correct array ───────────────────────────

do
  reset_modules()
  local conflict_hls = {
    { id = "c-1", exact = "foo", koreader = { status = "conflict", error = "2 candidates" } },
    { id = "c-2", exact = "bar", koreader = { status = "conflict", error = "3 candidates" } },
  }
  package.loaded["askgpt.ai_client"] = {
    listHighlights  = function(_sha, status)
      if status == "conflict" then return { highlights = conflict_hls } end
      return { highlights = {} }
    end,
    updateHighlight = function() return {} end,
  }

  local ui = make_ui()  -- no findAllText needed; we're only calling list_conflicts

  local AS = require("askgpt.annotation_sync")
  local list = AS.list_conflicts(ui)

  H.eq("list_conflicts returns 2 items",    #list, 2)
  H.eq("list_conflicts first id",  list[1] and list[1].id, "c-1")
  H.eq("list_conflicts second id", list[2] and list[2].id, "c-2")
end

-- ══════════════════════════════════════════════════════════════════════════
-- Phase 3 tests
-- ══════════════════════════════════════════════════════════════════════════

-- Phase 3 mock: supports both pending-highlights call and include_deleted call.
-- pending_hls    — returned for listHighlights(sha, "pending")
-- all_with_deleted — returned for listHighlights(sha, nil, true)
local function make_ai_client_p3(pending_hls, all_with_deleted)
  local update_calls = {}
  local ai = {
    listHighlights = function(_sha, _status, include_deleted)
      if include_deleted then
        return { highlights = all_with_deleted or {} }
      end
      return { highlights = pending_hls or {} }
    end,
    updateHighlight = function(_sha, id, patch)
      table.insert(update_calls, { id = id, patch = patch })
      return {}
    end,
  }
  package.loaded["askgpt.ai_client"] = ai
  return ai, update_calls
end

-- ── T6: resolved annotation stores bookaware_highlight_id and sha256 ──────

do
  reset_modules()
  local _, updates = make_ai_client_p3({
    {
      id     = "hl-006",
      exact  = "unique sentinel text here",
      prefix = "prefix text ",
      suffix = " suffix text",
    },
  }, {})

  local ui = make_ui(function(self, text)
    if text == "unique sentinel text here" then
      return {{
        start     = "/body/p[1].0",
        ["end"]   = "/body/p[1].26",
        prev_text = "prefix text ",
        next_text = " suffix text",
      }}
    end
    return {}
  end)

  local AS = require("askgpt.annotation_sync")
  AS.sync(ui)

  local item = ui.annotation._calls[1]
  H.eq("T6 annotation stores bookaware_highlight_id",
    item and item.bookaware_highlight_id, "hl-006")
  H.eq("T6 annotation stores bookaware_sha256",
    item and item.bookaware_sha256, SHA)
  H.is_true("T6 bookaware_synced_color stored",
    item and type(item.bookaware_synced_color) == "string")
end

-- ── T7: push_changes — local color change → PATCH sent ───────────────────

do
  reset_modules()
  local _, updates = make_ai_client_p3({}, {})  -- no pending, no tombstones

  local ui = make_ui(function() return {} end)
  -- Insert a pre-existing "synced" annotation with a changed color.
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-007",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "yellow",   -- what was last synced
    bookaware_synced_note  = "",
    color                  = "blue",     -- changed by user in KOReader
    note                   = "",
  })

  local AS = require("askgpt.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T7 pushed=1",    r.pushed, 1)
  H.eq("T7 resolved=0",  r.resolved, 0)
  H.is_true("T7 updateHighlight called for hl-007",
    #updates == 1 and updates[1].id == "hl-007")
  H.eq("T7 patch.color=blue",
    updates[1] and updates[1].patch.color, "blue")
  H.eq("T7 patch.updated_by=koreader",
    updates[1] and updates[1].patch.updated_by, "koreader")
end

-- ── T8: apply_tombstones — annotation removed when backend has deleted_at ──

do
  reset_modules()
  local _, updates = make_ai_client_p3({}, {
    { id = "hl-008", exact = "tombstone text", deleted_at = "2026-01-01T00:00:00Z" },
  })

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-008",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "gray",
    bookaware_synced_note  = "",
    color                  = "gray",
    note                   = "",
  })

  local AS = require("askgpt.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T8 removed=1",                r.removed, 1)
  H.eq("T8 resolved=0",               r.resolved, 0)
  H.eq("T8 annotation table is empty", #ui.annotation.annotations, 0)
end

-- ── T9: tombstone for missing local annotation → no error ─────────────────

do
  reset_modules()
  local _, updates = make_ai_client_p3({}, {
    { id = "hl-009", exact = "ghost text", deleted_at = "2026-01-01T00:00:00Z" },
  })

  -- UI has no annotations; tombstone has no local counterpart.
  local ui = make_ui(function() return {} end)

  local AS = require("askgpt.annotation_sync")
  H.no_error("T9 tombstone for missing annotation doesn't crash", function()
    AS.sync(ui)
  end)
  H.eq("T9 no annotations removed", #ui.annotation.annotations, 0)
end

-- ── T10: push_changes_only — changed color → PATCH sent ──────────────────

do
  reset_modules()
  local update_calls = {}
  package.loaded["askgpt.ai_client"] = {
    listHighlights  = function() return { highlights = {} } end,
    updateHighlight = function(_sha, id, patch)
      table.insert(update_calls, { id = id, patch = patch })
      return {}
    end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-010",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "yellow",
    bookaware_synced_note  = "",
    color                  = "green",
    note                   = "",
  })

  local AS = require("askgpt.annotation_sync")
  local r  = AS.push_changes_only(ui)

  H.eq("T10 pushed=1",                    r.pushed, 1)
  H.eq("T10 failed=0",                    r.failed, 0)
  H.eq("T10 updateHighlight called once", #update_calls, 1)
  H.eq("T10 patch.color=green",           update_calls[1] and update_calls[1].patch.color, "green")
  H.eq("T10 patch.updated_by=koreader",   update_calls[1] and update_calls[1].patch.updated_by, "koreader")
end

-- ── T11: push_changes_only — no drift → no PATCH sent ────────────────────

do
  reset_modules()
  local update_calls = {}
  package.loaded["askgpt.ai_client"] = {
    listHighlights  = function() return { highlights = {} } end,
    updateHighlight = function(_sha, id, patch)
      table.insert(update_calls, { id = id, patch = patch })
      return {}
    end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-011",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "blue",
    bookaware_synced_note  = "my note",
    color                  = "blue",
    note                   = "my note",
  })

  local AS = require("askgpt.annotation_sync")
  local r  = AS.push_changes_only(ui)

  H.eq("T11 pushed=0",                 r.pushed, 0)
  H.eq("T11 no updateHighlight calls", #update_calls, 0)
end

-- ── T12: push failures are included in sync failed count ─────────────────

do
  reset_modules()
  package.loaded["askgpt.ai_client"] = {
    listHighlights = function(_sha, _status, include_deleted)
      return { highlights = {} }
    end,
    updateHighlight = function()
      error("backend unavailable")
    end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-012",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "yellow",
    bookaware_synced_note  = "old note",
    color                  = "green",
    note                   = "new note",
  })

  local AS = require("askgpt.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T12 pushed=0 after backend failure", r.pushed, 0)
  H.eq("T12 failed includes push failure",   r.failed, 1)
  H.eq("T12 synced color unchanged",         ui.annotation.annotations[1].bookaware_synced_color, "yellow")
  H.eq("T12 synced note unchanged",          ui.annotation.annotations[1].bookaware_synced_note, "old note")
end

-- ── T13: tombstone fetch failures propagate instead of reporting success ──

do
  reset_modules()
  package.loaded["askgpt.ai_client"] = {
    listHighlights = function(_sha, _status, include_deleted)
      if include_deleted then error("tombstone fetch failed") end
      return { highlights = {} }
    end,
    updateHighlight = function() return {} end,
  }

  local ui = make_ui(function() return {} end)
  local AS = require("askgpt.annotation_sync")
  local ok, err = pcall(function() AS.sync(ui) end)

  H.is_false("T13 sync raises on tombstone fetch failure", ok)
  H.contains("T13 error mentions tombstone failure", tostring(err), "tombstone fetch failed")
end

-- ── T14: backend resolution failure does not duplicate local annotations ──

do
  reset_modules()
  local pending = {
    {
      id     = "hl-014",
      exact  = "retry duplicate sentinel",
      prefix = "before ",
      suffix = " after",
    },
  }
  package.loaded["askgpt.ai_client"] = {
    listHighlights = function(_sha, _status, include_deleted)
      if include_deleted then return { highlights = {} } end
      return { highlights = pending }
    end,
    updateHighlight = function()
      error("backend resolution failed")
    end,
  }

  local ui = make_ui(function(self, text)
    if text == "retry duplicate sentinel" then
      return {{
        start     = "/body/p[14].0",
        ["end"]   = "/body/p[14].24",
        prev_text = "before ",
        next_text = " after",
      }}
    end
    return {}
  end)

  local AS = require("askgpt.annotation_sync")
  local r1 = AS.sync(ui)
  local r2 = AS.sync(ui)

  H.eq("T14 first sync counted failed",       r1.failed, 1)
  H.eq("T14 second sync counted failed",      r2.failed, 1)
  H.eq("T14 addItem called only once",        #ui.annotation._calls, 1)
  H.eq("T14 annotation table has one item",   #ui.annotation.annotations, 1)
  H.eq("T14 stored backend id",               ui.annotation.annotations[1].bookaware_highlight_id, "hl-014")
end
