-- Headless half of the theme picker (see theme-apply.sh). Loads every
-- colorscheme nvim knows about, minus the ones shipped in $VIMRUNTIME, and
-- writes one tab-separated row per scheme to the path in vim.g.theme_out:
--
--   name  bg  fg  cursor  selection  accent  c0 .. c15
--
-- accent is the Function fg, the same color autocmds.lua pushes into tmux as
-- @accent, so a preview from the picker matches what nvim sets afterwards.
-- A missing color is written as "-" and the apply script leaves it alone.
--
-- Runs headless, where LazyVim never fires VeryLazy, so autocmds.lua (which
-- makes Normal transparent and writes OSC sequences) is not loaded here.
-- theme.lua's "remember the last colorscheme" autocmd *is* loaded, though;
-- theme-apply.sh saves and restores last_colorscheme.txt around this run.

local out = assert(vim.g.theme_out, "set g:theme_out")
local runtime = vim.fs.normalize(vim.env.VIMRUNTIME)

local function hex(n)
  return n and string.format("#%06x", n) or "-"
end

local function hl(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and h or {}
end

-- Schemes from my own colors/ go last: evilware calls tokyonight.setup(),
-- which sticks for the rest of the session, so every tokyonight variant
-- loaded after it would come out as evilware.
local mine = vim.fs.normalize(vim.fn.stdpath("config"))
local names, own = {}, {}
for _, name in ipairs(vim.fn.getcompletion("", "color")) do
  local file = vim.api.nvim_get_runtime_file("colors/" .. name .. ".*", false)[1]
  file = file and vim.fs.normalize(vim.fn.resolve(file))
  if file and not vim.startswith(file, runtime) then
    table.insert(vim.startswith(file, vim.fn.resolve(mine)) and own or names, name)
  end
end
vim.list_extend(names, own)

local rows = {}
for _, name in ipairs(names) do
  do
    for i = 0, 15 do
      vim.g["terminal_color_" .. i] = nil
    end
    vim.cmd("hi clear")
    vim.o.background = "dark"
    if pcall(vim.cmd.colorscheme, name) then
      local normal, cursor, visual = hl("Normal"), hl("Cursor"), hl("Visual")
      -- Transparent-by-design schemes (evilware) have no Normal bg.
      local bg = normal.bg and hex(normal.bg) or "#000000"
      local fg = hex(normal.fg)
      local row = {
        name,
        bg,
        fg,
        cursor.bg and hex(cursor.bg) or fg,
        hex(visual.bg),
        hex(hl("Function").fg),
      }
      for i = 0, 15 do
        local c = vim.g["terminal_color_" .. i]
        row[#row + 1] = (type(c) == "string" and c:match("^#%x%x%x%x%x%x$")) and c:lower() or "-"
      end
      rows[#rows + 1] = table.concat(row, "\t")
    end
  end
end

table.sort(rows)
vim.fn.writefile(rows, out)
