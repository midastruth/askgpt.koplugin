-- 格式化 AI 响应为可读文本块
local _ = require("gettext")
local Util = require("askgpt.util")

local Formatter = {}

local function format_list(label, values)
  if type(values) ~= "table" then return nil end
  local cleaned = {}
  for _, value in ipairs(values) do
    if type(value) == "string" then
      local v = Util.trim(value)
      if v ~= "" then table.insert(cleaned, v) end
    end
  end
  if #cleaned == 0 then return nil end
  return label .. "\n- " .. table.concat(cleaned, "\n- ")
end

-- args: highlighted_text, question, term, dictionary{}, language, title, author
function Formatter.dictionary(args)
  local dictionary = args.dictionary or {}
  local segments = {}

  if args.highlighted_text and args.highlighted_text ~= "" then
    table.insert(segments, _("Highlighted text: ") .. "\"" .. args.highlighted_text .. "\"")
  end
  if args.question and args.question ~= "" then
    table.insert(segments, _("Question: ") .. args.question)
  end

  local entry_parts = {}
  local term_to_show = dictionary.term or args.term
  if term_to_show and term_to_show ~= "" then
    table.insert(entry_parts, _("Term: ") .. term_to_show)
  end
  if dictionary.pronunciation and dictionary.pronunciation ~= "" then
    table.insert(entry_parts, _("Pronunciation: ") .. dictionary.pronunciation)
  end
  if dictionary.part_of_speech and dictionary.part_of_speech ~= "" then
    table.insert(entry_parts, _("Part of speech: ") .. dictionary.part_of_speech)
  end
  if dictionary.definition and dictionary.definition ~= "" then
    table.insert(entry_parts, _("Definition: ") .. dictionary.definition)
  end

  local examples = format_list(_("Examples"), dictionary.examples)
  if examples then table.insert(entry_parts, examples) end
  local synonyms = format_list(_("Synonyms"), dictionary.synonyms)
  if synonyms then table.insert(entry_parts, synonyms) end
  local antonyms = format_list(_("Antonyms"), dictionary.antonyms)
  if antonyms then table.insert(entry_parts, antonyms) end

  if dictionary.notes and dictionary.notes ~= "" then
    table.insert(entry_parts, _("Notes: ") .. dictionary.notes)
  end
  if args.language and args.language ~= "" and args.language ~= "auto" then
    table.insert(entry_parts, _("Language: ") .. args.language)
  end
  if args.title or args.author then
    local doc_info = _("Document: ") .. (args.title or _("Unknown Title"))
    if args.author and args.author ~= "" then
      doc_info = doc_info .. _(" by ") .. args.author
    end
    table.insert(entry_parts, doc_info)
  end

  if #entry_parts > 0 then
    table.insert(segments, table.concat(entry_parts, "\n\n"))
  end
  if #segments == 0 then return _("No dictionary content available.") end
  return table.concat(segments, "\n\n")
end

-- args: highlighted_text, prompt, summary, details{}, language, title, author
function Formatter.summary(args)
  local segments = {}

  if args.highlighted_text and args.highlighted_text ~= "" then
    table.insert(segments, _("Original text: ") .. "\"" .. args.highlighted_text .. "\"")
  end
  if args.prompt and args.prompt ~= "" then
    table.insert(segments, _("Instruction: ") .. args.prompt)
  end
  if args.summary and args.summary ~= "" then
    table.insert(segments, _("Summary: ") .. args.summary)
  end

  local details = args.details
  if type(details) == "table" then
    local key_points = format_list(_("Key points"), details.key_points or details.bullet_points)
    if key_points then table.insert(segments, key_points) end
    local highlights = format_list(_("Highlights"), details.highlights)
    if highlights then table.insert(segments, highlights) end
    if type(details.language) == "string" and details.language ~= "" then
      table.insert(segments, _("Language: ") .. details.language)
    end
  end

  if args.title or args.author then
    local doc_info = _("Document: ") .. (args.title or _("Unknown Title"))
    if args.author and args.author ~= "" then
      doc_info = doc_info .. _(" by ") .. args.author
    end
    table.insert(segments, doc_info)
  end

  if #segments == 0 then return _("No summary available.") end
  return table.concat(segments, "\n\n")
end

-- args: highlighted_text, focus_points[], analysis{}, language, title, author
function Formatter.analysis(args)
  local segments = {}
  local analysis = args.analysis or {}

  if args.highlighted_text and args.highlighted_text ~= "" then
    table.insert(segments, _("Original text: ") .. "\"" .. args.highlighted_text .. "\"")
  end
  if args.focus_points and type(args.focus_points) == "table" and #args.focus_points > 0 then
    table.insert(segments, _("Focus points: ") .. table.concat(args.focus_points, ", "))
  end
  if analysis.analysis and analysis.analysis ~= "" then
    table.insert(segments, _("Analysis: ") .. analysis.analysis)
  end

  if type(analysis) == "table" then
    local keywords = analysis.keywords or analysis.key_words
    if type(keywords) == "table" and #keywords > 0 then
      table.insert(segments, _("Keywords: ") .. table.concat(keywords, ", "))
    end
    local themes = analysis.themes or analysis.topics
    local themes_formatted = format_list(_("Themes"), themes)
    if themes_formatted then table.insert(segments, themes_formatted) end
    if analysis.sentiment then
      table.insert(segments, _("Sentiment: ") .. analysis.sentiment)
    end
    local key_points = format_list(_("Key points"), analysis.key_points or analysis.main_points)
    if key_points then table.insert(segments, key_points) end
    if analysis.summary and analysis.summary ~= "" then
      table.insert(segments, _("Summary: ") .. analysis.summary)
    end
  end

  if args.title or args.author then
    local doc_info = _("Document: ") .. (args.title or _("Unknown Title"))
    if args.author and args.author ~= "" then
      doc_info = doc_info .. _(" by ") .. args.author
    end
    table.insert(segments, doc_info)
  end

  if #segments == 0 then return _("No analysis available.") end
  return table.concat(segments, "\n\n")
end

return Formatter
