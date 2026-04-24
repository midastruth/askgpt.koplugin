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

function Util.file_stat(filepath)
  if not filepath or filepath == "" then return nil, nil end

  local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
  if ok_lfs and lfs and type(lfs.attributes) == "function" then
    local ok_attr, attr = pcall(lfs.attributes, filepath)
    if ok_attr and type(attr) == "table" then
      return attr.size, attr.modification
    end
  end

  local file = io.open(filepath, "rb")
  if not file then return nil, nil end
  local size = file:seek("end")
  file:close()
  return size, nil
end

function Util.sha256_file(filepath)
  if not filepath or filepath == "" then
    return nil, "missing file path"
  end

  local ok_sha, sha = pcall(require, "ffi/sha2")
  if not ok_sha or type(sha) ~= "table" or type(sha.sha256) ~= "function" then
    return nil, "ffi/sha2.sha256 unavailable"
  end

  local file, open_err = io.open(filepath, "rb")
  if not file then
    return nil, open_err or "cannot open file"
  end

  local ok_hash, digest = pcall(function()
    local ok_init, update = pcall(sha.sha256)
    if ok_init and type(update) == "function" then
      while true do
        local chunk = file:read(64 * 1024)
        if not chunk then break end
        update(chunk)
      end
      return update()
    end

    file:seek("set", 0)
    local data = file:read("*all") or ""
    return sha.sha256(data)
  end)
  file:close()

  if not ok_hash then
    return nil, tostring(digest)
  end
  if type(digest) ~= "string" or digest == "" then
    return nil, "empty sha256 digest"
  end
  return digest
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
