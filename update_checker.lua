-- 检查 GitHub releases/latest 并在有新版本时通知用户
local https       = require("ssl.https")
local ltn12       = require("ltn12")
local json        = require("json")
local meta        = require("_meta")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")

local RELEASES_URL = "https://api.github.com/repos/midastruth/askgpt.koplugin/releases/latest"
local TIMEOUT      = 5  -- 秒

local function checkForUpdates()
  local chunks      = {}
  local prev_timeout = https.TIMEOUT
  https.TIMEOUT     = TIMEOUT

  -- pcall 正确接收三个返回值：ok, result(1或nil), code(HTTP状态)
  local ok, _, code = pcall(function()
    return https.request {
      url     = RELEASES_URL,
      headers = { ["Accept"] = "application/vnd.github.v3+json" },
      sink    = ltn12.sink.table(chunks),
    }
  end)

  https.TIMEOUT = prev_timeout

  if not ok or code ~= 200 then return end

  local parse_ok, data = pcall(json.decode, table.concat(chunks))
  if not parse_ok or type(data) ~= "table" or not data.tag_name then return end

  -- tag_name 格式为 "v1.1"，去掉前缀后转为数字比较
  local latest = tonumber(data.tag_name:match("^v(.+)$"))
  if latest and latest > meta.version then
    UIManager:show(InfoMessage:new {
      text    = "A new version of AskGPT (" .. data.tag_name .. ") is available. Please update!",
      timeout = 5,
    })
  end
end

return { checkForUpdates = checkForUpdates }
