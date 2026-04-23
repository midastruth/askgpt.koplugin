-- 通用工具函数
local Util = {}

function Util.trim(text)
  return (text or ""):match("^%s*(.-)%s*$")
end

function Util.clone_table(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

-- 将逗号分隔字符串拆分为去空格后的数组；nil/空字符串均返回空表
function Util.split_csv(text)
  if not text then return {} end
  local parts = {}
  for part in tostring(text):gmatch("[^,]+") do
    local trimmed = Util.trim(part)
    if trimmed ~= "" then
      table.insert(parts, trimmed)
    end
  end
  return parts
end

return Util
