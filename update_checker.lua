local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local socket = require("socket")
local meta = require("_meta")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

-- 更新检查配置
local UPDATE_CHECK_TIMEOUT = 5  -- 更新检查超时时间（秒）
local MAX_UPDATE_RETRY_ATTEMPTS = 2  -- 更新检查最大重试次数

local function checkForUpdates()
  local attempts = 0
  local last_error = nil
  
  while attempts < MAX_UPDATE_RETRY_ATTEMPTS do
    attempts = attempts + 1
    
    local response_body = {}
    local success, code = pcall(function()
      -- 设置超时
      local old_timeout = http.TIMEOUT
      http.TIMEOUT = UPDATE_CHECK_TIMEOUT
      
      local result
      result, code = http.request {
        url = "https://api.github.com/repos/drewbaumann/AskGPT",
        headers = {
            ["Accept"] = "application/vnd.github.v3+json"
        },
        sink = ltn12.sink.table(response_body)
      }
      
      -- 恢复原始超时设置
      http.TIMEOUT = old_timeout
      
      return result, code
    end)
    
    if success and code == 200 then
      local ok, parsed_data = pcall(function()
        local data = table.concat(response_body)
        return json.decode(data)
      end)
      
      if ok and parsed_data and parsed_data.tag_name then
        local latest_version = parsed_data.tag_name -- e.g., "v0.9"
        local stripped_latest_version = latest_version:match("^v(.+)$")
        -- Compare with current version
        if stripped_latest_version and meta.version < tonumber(stripped_latest_version) then
          -- Show notification to the user if a new version is available
          local message = "A new version of the app (" .. latest_version .. ") is available. Please update!"
          local info_message = InfoMessage:new{
              text = message,
              timeout = 5 -- Display message for 5 seconds
          }
          UIManager:show(info_message)
        end
        return -- 成功完成，退出函数
      else
        last_error = "Invalid response format"
      end
    else
      if not success then
        last_error = "Request failed: " .. tostring(code)
      else
        last_error = "HTTP error: " .. tostring(code)
      end
    end
    
    -- 如果不是最后一次尝试，等待后重试
    if attempts < MAX_UPDATE_RETRY_ATTEMPTS then
      socket.sleep(1) -- 1秒重试间隔
    end
  end
  
  -- 如果所有尝试都失败，只在调试模式下打印错误
  print("Failed to check for updates after " .. MAX_UPDATE_RETRY_ATTEMPTS .. " attempts. Last error: " .. tostring(last_error))
end

return {
  checkForUpdates = checkForUpdates
}
