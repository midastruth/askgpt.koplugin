-- Web highlight ↔ KOReader native annotation sync (Phase 1–3)
--
-- Phase 1: find text, write annotation.
-- Phase 2: improved candidate scoring (prefix/suffix/chapter/progression),
--          structured conflict reporting, short-text conservatism.
-- Phase 3: bidirectional sync — push local note/color changes back to
--          book-aware; apply tombstones (reader-web deletes).
--
-- Scoring breakdown (max 120 pts):
--   (a) prefix similarity:       0–40 pts
--   (b) suffix similarity:       0–40 pts
--   (c) chapter match/proximity: 0–20 pts  (new in Phase 2)
--   (d) progression proximity:   0–20 pts  (improved: estimates from XPointer)
--
-- Disambiguation:
--   Single candidate → always resolved.
--   Multiple candidates → requires best_score >= MIN_SCORE AND margin >= threshold.
--   Short text (< SHORT_TEXT_CHARS chars OR < SHORT_TEXT_WORDS words) uses
--   SHORT_MARGIN instead of MIN_MARGIN (more conservative).

local AiClient = require("askgpt.ai_client")
local Util     = require("askgpt.util")

local AnnotationSync = {}

-- ── color mapping ─────────────────────────────────────────────────────────

-- Maps book-aware colors to KOReader annotation colors.
-- Shared set: yellow, green, blue, red, purple, gray.
-- gray = KOReader e-ink default (saved_color = "gray" on non-color screens).
local COLOR_MAP = {
  yellow = "yellow",
  green  = "green",
  blue   = "blue",
  red    = "red",
  purple = "purple",
  gray   = "gray",
}

-- ── Phase 2 disambiguation constants ──────────────────────────────────────

local MIN_SCORE        = 10   -- multi-candidate: best must clear this floor
local MIN_MARGIN       = 15   -- multi-candidate: gap required for normal text
local SHORT_TEXT_CHARS = 8    -- exact text shorter than this is "short"
local SHORT_TEXT_WORDS = 3    -- or fewer words → short
local SHORT_MARGIN     = 45   -- short text needs a larger gap to auto-resolve

-- ── text helpers ──────────────────────────────────────────────────────────

-- True if exact text is short enough to warrant conservative disambiguation.
local function is_short_text(exact)
  if #exact < SHORT_TEXT_CHARS then return true end
  local words = 0
  for _ in exact:gmatch("%S+") do
    words = words + 1
    if words >= SHORT_TEXT_WORDS then return false end
  end
  return true
end

-- Shared-substring n-gram similarity between two strings, 0–1.
local function text_similarity(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return 0 end
  a = a:lower():sub(1, 300)
  b = b:lower():sub(1, 300)
  if a == "" or b == "" then return 0 end
  if a == b then return 1.0 end
  local la = #a
  local step = math.max(2, math.floor(math.min(la, #b) / 25))
  local hits, total = 0, 0
  for i = 1, la - step + 1, step do
    local chunk = a:sub(i, i + step - 1)
    if b:find(chunk, 1, true) then hits = hits + 1 end
    total = total + 1
  end
  return total > 0 and (hits / total) or 0
end

-- Estimate total-publication progression (0-1) from an XPointer.
local function estimate_progression(ui, xp)
  local ok_p, page = pcall(function() return ui.document:getPageFromXPointer(xp) end)
  if not ok_p or not page then return nil end
  local ok_c, count = pcall(function() return ui.document:getPageCount() end)
  if not ok_c or not count or count == 0 then return nil end
  return (page - 1) / count
end

-- Resolve the TOC chapter title for an XPointer position.
local function get_chapter_for_xpointer(ui, xp)
  if not ui.toc then return nil end
  local ok_p, page = pcall(function() return ui.document:getPageFromXPointer(xp) end)
  if not ok_p or not page then return nil end
  local ok1, t = pcall(function() return ui.toc:getTocTitleByPage(page) end)
  if ok1 and type(t) == "string" and t ~= "" then return t end
  local ok2, ft = pcall(function() return ui.toc:getFullTocTitleByPage(page) end)
  if ok2 and type(ft) == "string" and ft ~= "" then return ft end
  return nil
end

-- ── Phase 2 candidate scoring ─────────────────────────────────────────────

local function score_candidate(ui, candidate, hl)
  local score = 0

  -- (a) prefix similarity: 0–40 pts
  if type(hl.prefix) == "string" and hl.prefix ~= ""
      and type(candidate.prev_text) == "string" then
    score = score + text_similarity(candidate.prev_text, hl.prefix) * 40
  end

  -- (b) suffix similarity: 0–40 pts
  if type(hl.suffix) == "string" and hl.suffix ~= ""
      and type(candidate.next_text) == "string" then
    score = score + text_similarity(candidate.next_text, hl.suffix) * 40
  end

  -- (c) chapter match: 0–20 pts
  if type(hl.chapter) == "string" and hl.chapter ~= "" then
    local cand_ch = get_chapter_for_xpointer(ui, candidate.start)
    if type(cand_ch) == "string" and cand_ch ~= "" then
      score = score + text_similarity(cand_ch, hl.chapter) * 20
    end
  end

  -- (d) progression proximity: 0–20 pts
  --     Use candidate.progression if present; otherwise estimate from XPointer.
  local prog = type(candidate.progression) == "number" and candidate.progression
    or estimate_progression(ui, candidate.start)
  if prog and type(hl.total_progression) == "number" then
    score = score + (1 - math.min(1, math.abs(prog - hl.total_progression))) * 20
  end

  return score
end

-- ── disambiguation judgment ───────────────────────────────────────────────

-- Returns (ok, reason) for a multi-candidate result set.
-- n >= 2.  Returns true/"" on success, false/detail_string on conflict.
local function check_disambiguation(exact, n, best_score, second_score)
  local margin      = best_score - second_score
  local needed      = is_short_text(exact) and SHORT_MARGIN or MIN_MARGIN
  local short_label = is_short_text(exact) and "short" or "normal"

  if best_score < MIN_SCORE then
    return false, string.format(
      "%d candidates; best=%.1f second=%.1f margin=%.1f; "
        .. "insufficient context score (best < min=%d)",
      n, best_score, second_score, margin, MIN_SCORE)
  end
  if margin < needed then
    return false, string.format(
      "%d candidates; best=%.1f second=%.1f margin=%.1f; "
        .. "%s text, margin too small (need %d)",
      n, best_score, second_score, margin, short_label, needed)
  end
  return true, nil
end

-- ── write a native KOReader annotation ───────────────────────────────────

-- sha256 is stored in the annotation for Phase 3 push/tombstone tracking.
local function write_annotation(ui, hl, pos0_xp, pos1_xp, sha256)
  local Event = require("ui/event")
  -- Resolve color: backend color first, then KOReader's own saved_color.
  local native_default = (ui.view and ui.view.highlight
    and type(ui.view.highlight.saved_color) == "string"
    and ui.view.highlight.saved_color ~= "")
      and ui.view.highlight.saved_color or "gray"
  local color = (type(hl.color) == "string" and hl.color ~= ""
    and COLOR_MAP[hl.color]) or native_default
  local synced_note = (type(hl.note) == "string" and hl.note ~= "") and hl.note or ""
  local item = {
    page    = pos0_xp,
    pos0    = pos0_xp,
    pos1    = pos1_xp,
    text    = hl.exact,
    note    = synced_note ~= "" and synced_note or nil,
    drawer  = "lighten",
    color   = color,
    chapter = (type(hl.chapter) == "string" and hl.chapter ~= "") and hl.chapter or nil,
    -- Phase 3: backend tracking fields (persisted with annotation)
    bookaware_highlight_id = hl.id,
    bookaware_sha256       = sha256,
    bookaware_synced_color = color,
    bookaware_synced_note  = synced_note,
  }
  local index = ui.annotation:addItem(item)
  ui:handleEvent(Event:new("AnnotationsModified",
    { item, nb_highlights_added = 1, index_modified = index }))
  return index
end

-- ── backend annotation identity helpers ──────────────────────────────────

local function find_synced_annotation(ui, sha256, highlight_id)
  if type(highlight_id) ~= "string" or highlight_id == "" then return nil end
  if type(ui.annotation) ~= "table"
      or type(ui.annotation.annotations) ~= "table" then
    return nil
  end
  for i, ann in ipairs(ui.annotation.annotations) do
    if ann.bookaware_highlight_id == highlight_id
        and ann.bookaware_sha256 == sha256 then
      return ann, i
    end
  end
  return nil
end

-- ── SHA256 resolution ─────────────────────────────────────────────────────

local function get_sha256(ui)
  if not ui then return nil end
  if ui.doc_settings and type(ui.doc_settings.readSetting) == "function" then
    local ok, v = pcall(function()
      return ui.doc_settings:readSetting("file_sha256")
    end)
    if ok and type(v) == "string" and v ~= "" then return v end
  end
  if ui.document and type(ui.document.file) == "string" and ui.document.file ~= "" then
    local ok, digest = pcall(Util.sha256_file, ui.document.file)
    if ok and type(digest) == "string" and digest ~= "" then return digest end
  end
  return nil
end

-- ── Phase 3: push local changes to book-aware ────────────────────────────

-- Push note/color changes that were made in KOReader back to the backend.
-- Only annotations with bookaware_highlight_id that differ from their last
-- synced values are sent.
local function push_changes(ui, sha256)
  if type(ui.annotation) ~= "table"
      or type(ui.annotation.annotations) ~= "table" then
    return { pushed = 0, failed = 0 }
  end
  local pushed, failed = 0, 0
  for _, ann in ipairs(ui.annotation.annotations) do
    local bid     = type(ann.bookaware_highlight_id) == "string" and ann.bookaware_highlight_id or nil
    local ann_sha = type(ann.bookaware_sha256)       == "string" and ann.bookaware_sha256       or nil
    if bid and ann_sha == sha256 then
      local cur_color = type(ann.color) == "string" and ann.color or ""
      local cur_note  = type(ann.note)  == "string" and ann.note  or ""
      local syn_color = type(ann.bookaware_synced_color) == "string" and ann.bookaware_synced_color or ""
      local syn_note  = type(ann.bookaware_synced_note)  == "string" and ann.bookaware_synced_note  or ""
      if cur_color ~= syn_color or cur_note ~= syn_note then
        local ok_p = pcall(function()
          local patch = { updated_by = "koreader" }
          if cur_color ~= "" then patch.color = cur_color end
          patch.note = cur_note  -- send even when empty to clear backend note
          AiClient.updateHighlight(ann_sha, bid, patch)
          ann.bookaware_synced_color = cur_color
          ann.bookaware_synced_note  = cur_note
          pushed = pushed + 1
        end)
        if not ok_p then failed = failed + 1 end
      end
    end
  end
  return { pushed = pushed, failed = failed }
end

-- ── Phase 3: apply tombstones from book-aware ─────────────────────────────

-- Remove local annotations whose backend highlight has deleted_at set.
local function apply_tombstones(ui, sha256)
  if type(ui.annotation) ~= "table"
      or type(ui.annotation.annotations) ~= "table" then
    return 0
  end

  -- Fetch all highlights including deleted ones. Network/API failures must
  -- propagate so sync does not report success while web deletes were skipped.
  local result = AiClient.listHighlights(sha256, nil, true)
  local all_hls = (type(result) == "table" and type(result.highlights) == "table")
    and result.highlights or {}

  -- Build the set of tombstoned backend IDs.
  local deleted_ids = {}
  for _, hl in ipairs(all_hls) do
    if type(hl.id) == "string"
        and type(hl.deleted_at) == "string" and hl.deleted_at ~= "" then
      deleted_ids[hl.id] = true
    end
  end
  if not next(deleted_ids) then return 0 end

  -- Remove matching local annotations. Mirror KOReader's own removal event
  -- shape: include the removed item and a negative index_modified so
  -- ReaderAnnotation:onAnnotationsModified() does not treat this as an edit.
  local Event       = require("ui/event")
  local annotations = ui.annotation.annotations
  local removed     = 0
  local i = 1
  while i <= #annotations do
    local ann     = annotations[i]
    local bid     = type(ann.bookaware_highlight_id) == "string" and ann.bookaware_highlight_id or nil
    local ann_sha = type(ann.bookaware_sha256)       == "string" and ann.bookaware_sha256       or nil
    if bid and ann_sha == sha256 and deleted_ids[bid] then
      local removed_item = table.remove(annotations, i)
      removed = removed + 1
      ui:handleEvent(Event:new("AnnotationsModified", {
        removed_item,
        nb_highlights_added = -1,
        index_modified = -i,
      }))
    else
      i = i + 1
    end
  end

  if removed > 0 and ui.doc_settings and type(ui.doc_settings.saveSetting) == "function" then
    ui.doc_settings:saveSetting("annotations", annotations)
  end
  return removed
end

-- ── public API ────────────────────────────────────────────────────────────

-- Sync web highlights for the currently open book.
-- Phase 1/2: pull pending highlights, locate in document, write native annotations.
-- Phase 3a: push local note/color changes back to book-aware.
-- Phase 3b: apply tombstones — remove annotations deleted via reader-web.
-- Returns { resolved, conflict, failed, pushed, removed } counts.
-- Raises on fatal errors (no document, can't determine SHA256, network failure).
function AnnotationSync.sync(ui)
  if not ui or not ui.document then
    error("AnnotationSync.sync: no open document")
  end
  if not ui.annotation then
    error("AnnotationSync.sync: ui.annotation not available (EPUB rolling reader required)")
  end
  if not ui.rolling then
    error("AnnotationSync.sync: only EPUB (rolling) documents are supported in Phase 1")
  end

  local sha256 = get_sha256(ui)
  if not sha256 then
    error("AnnotationSync.sync: cannot determine book SHA256")
  end

  local resolved, conflict, failed = 0, 0, 0

  -- ── Phase 1/2: pull pending highlights ────────────────────────────────
  local pending_result = AiClient.listHighlights(sha256, "pending")
  local highlights = (type(pending_result) == "table"
    and type(pending_result.highlights) == "table")
    and pending_result.highlights or {}

  for _, hl in ipairs(highlights) do
    local ok, err = pcall(function()
      local exact = type(hl.exact) == "string" and hl.exact or ""
      if exact == "" then error("empty exact text") end

      local results = ui.document:findAllText(exact, true, 8, 200, false)
      if not results or #results == 0 then
        AiClient.updateHighlight(sha256, hl.id, {
          koreader = { status = "failed", error = "text not found in document" }
        })
        failed = failed + 1
        return
      end

      local best_idx, best_score, second_score = 1, -1, -1
      for i, candidate in ipairs(results) do
        local s = score_candidate(ui, candidate, hl)
        if s > best_score then
          second_score = best_score
          best_score   = s
          best_idx     = i
        elseif s > second_score then
          second_score = s
        end
      end
      if second_score < 0 then second_score = 0 end

      if #results > 1 then
        local ok_d, reason = check_disambiguation(exact, #results, best_score, second_score)
        if not ok_d then
          AiClient.updateHighlight(sha256, hl.id, {
            koreader = {
              status           = "conflict",
              error            = reason,
              candidates_count = #results,
              conflict_scores  = {
                best   = best_score,
                second = second_score,
                margin = best_score - second_score,
              },
            }
          })
          conflict = conflict + 1
          return
        end
      end

      local winner  = results[best_idx]
      local pos0_xp = winner.start
      local pos1_xp = winner["end"]

      if type(pos0_xp) ~= "string" or type(pos1_xp) ~= "string" then
        AiClient.updateHighlight(sha256, hl.id, {
          koreader = { status = "failed", error = "findAllText result missing XPointer" }
        })
        failed = failed + 1
        return
      end

      -- Idempotency guard: if a previous sync inserted this local annotation
      -- but failed before marking the backend highlight resolved, retry the
      -- backend resolution without adding a duplicate KOReader annotation.
      if not find_synced_annotation(ui, sha256, hl.id) then
        write_annotation(ui, hl, pos0_xp, pos1_xp, sha256)
      end

      local pageno = ""
      local ok_page, pn = pcall(function()
        return ui.document:getPageFromXPointer(pos0_xp)
      end)
      if ok_page and pn then pageno = tostring(pn) end

      AiClient.updateHighlight(sha256, hl.id, {
        koreader = {
          status = "resolved",
          pos0   = pos0_xp,
          pos1   = pos1_xp,
          page   = pageno,
        }
      })
      resolved = resolved + 1
    end)

    if not ok then
      pcall(AiClient.updateHighlight, sha256, hl.id, {
        koreader = { status = "failed", error = tostring(err) }
      })
      failed = failed + 1
    end
  end

  if resolved > 0 and ui.doc_settings
      and type(ui.doc_settings.saveSetting) == "function" then
    ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
  end

  -- ── Phase 3a: push local note/color changes ────────────────────────────
  local push_result = push_changes(ui, sha256)

  -- ── Phase 3b: apply tombstones from book-aware ─────────────────────────
  local removed = apply_tombstones(ui, sha256)

  -- Save synced_color/note fields updated by push_changes.
  if push_result.pushed > 0 and ui.doc_settings
      and type(ui.doc_settings.saveSetting) == "function" then
    ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
  end

  local total_failed = failed + (push_result.failed or 0)
  return {
    resolved = resolved,
    conflict = conflict,
    failed   = total_failed,
    pushed   = push_result.pushed,
    removed  = removed,
  }
end

-- Push-only sync: push local note/color changes back to book-aware.
-- Does NOT pull pending highlights or apply tombstones — safe to call on close.
-- Returns { pushed, failed }.
-- Raises on fatal errors (no document, can't determine SHA256).
function AnnotationSync.push_changes_only(ui)
  if not ui or not ui.document then
    error("AnnotationSync.push_changes_only: no open document")
  end
  local sha256 = get_sha256(ui)
  if not sha256 then
    error("AnnotationSync.push_changes_only: cannot determine book SHA256")
  end
  return push_changes(ui, sha256)
end

-- Fetch conflict highlights for the currently open book.
-- Returns an array of WebHighlight objects with status="conflict".
-- Raises on fatal errors (SHA256 not found, network failure).
function AnnotationSync.list_conflicts(ui)
  local sha256 = get_sha256(ui)
  if not sha256 then
    error("AnnotationSync.list_conflicts: cannot determine book SHA256")
  end
  local result = AiClient.listHighlights(sha256, "conflict")
  return (type(result) == "table" and type(result.highlights) == "table")
    and result.highlights or {}
end

return AnnotationSync
