local M = {}

local function has(glob)
  return vim.fn.glob(glob) ~= ""
end

-- decide JS vs TS by looking for ts/tsx files in `dir`, then one level up
local function is_ts(dir)
  if has(dir .. "/*.ts") or has(dir .. "/*.tsx") then
    return true
  end
  if has(dir .. "/*.js") or has(dir .. "/*.jsx") then
    return false
  end
  local up = vim.fs.dirname(dir)
  if has(up .. "/*.ts") or has(up .. "/*.tsx") then
    return true
  end
  return false
end

-- Create a barrel-export component inside `dir`:
--   <name>/index.{js,ts}    -> export { default } from "./<name>";
--   <name>/<name>.{jsx,tsx} -> export default function <name>() { return <div></div>; }
-- Returns the component file path on success.
function M.create(dir, name)
  name = vim.trim(name or "")
  if not dir or dir == "" or name == "" then
    return
  end

  local target = dir .. "/" .. name
  if vim.fn.isdirectory(target) == 1 then
    vim.notify("Directory already exists: " .. target, vim.log.levels.ERROR)
    return
  end

  local ts = is_ts(dir)
  local index_path = target .. "/index." .. (ts and "ts" or "js")
  local comp_path = target .. "/" .. name .. "." .. (ts and "tsx" or "jsx")

  vim.fn.mkdir(target, "p")
  vim.fn.writefile({ string.format('export { default } from "./%s";', name) }, index_path)
  vim.fn.writefile({
    string.format("export default function %s() {", name),
    "  return <div></div>;",
    "}",
  }, comp_path)

  vim.notify(string.format("Created barrel %s (%s)", name, ts and "ts" or "js"))
  return comp_path
end

return M
