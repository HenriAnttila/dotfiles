-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- Sync terminal background with Neovim colorscheme (hides padding)
local function set_bg(color)
  local hex = string.format("#%06x", color)
  if vim.env.TMUX then
    io.write(string.format("\027Ptmux;\027\027]11;%s\007\027\\", hex))
  else
    io.write(string.format("\027]11;%s\027\\", hex))
  end
end

local function reset_bg()
  if vim.env.TMUX then
    io.write("\027Ptmux;\027\027]111;\007\027\\")
  else
    io.write("\027]111\027\\")
  end
end

-- Make the background transparent on every theme change so the terminal
-- (and its blur/wallpaper) shows through.
local transparent_groups = {
  "Normal",
  "NormalNC",
  "NormalFloat",
  "FloatBorder",
  "FloatTitle",
  "SignColumn",
  "MsgArea",
  "TelescopeNormal",
  "TelescopeBorder",
  "NormalSB",
  "WinBar",
  "WinBarNC",
}

local function make_transparent()
  for _, group in ipairs(transparent_groups) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group })
    if ok and next(hl) ~= nil then
      hl.bg = nil
      hl.ctermbg = nil
      vim.api.nvim_set_hl(0, group, hl)
    end
  end
end

-- Push the colorscheme's accent (Function fg) into tmux so the status bar
-- recolors to match. Mirrors the background sync above.
local function set_accent()
  if not vim.env.TMUX then
    return
  end
  local accent = "#1688f0" -- fallback if the theme has no Function fg
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "Function", link = false })
  if ok and hl and hl.fg then
    accent = string.format("#%06x", hl.fg)
  end
  vim.fn.jobstart({ "tmux", "set", "-g", "@accent", accent })
  -- A muted version for pane borders: same hue/saturation, just dimmer
  -- (brightness scaled down) so the active split is the accent but not loud.
  local function chan(h, i)
    return tonumber(h:sub(i, i + 1), 16)
  end
  local f = 0.6 -- brightness scale; lower = darker/quieter
  local dim = string.format(
    "#%02x%02x%02x",
    math.floor(chan(accent, 2) * f + 0.5),
    math.floor(chan(accent, 4) * f + 0.5),
    math.floor(chan(accent, 6) * f + 0.5)
  )
  vim.fn.jobstart({ "tmux", "set", "-g", "@accent_dim", dim })
end

-- Sync the terminal's 16-color ANSI palette (OSC 4) to the colorscheme so the
-- shell — prompt, ls, git output — matches nvim. Colors persist after nvim
-- exits (no reset), so the terminal keeps the last theme.
local function set_palette()
  for i = 0, 15 do
    local c = vim.g["terminal_color_" .. i]
    if type(c) == "string" and c:match("^#%x%x%x%x%x%x$") then
      if vim.env.TMUX then
        io.write(string.format("\027Ptmux;\027\027]4;%d;%s\007\027\\", i, c))
      else
        io.write(string.format("\027]4;%d;%s\027\\", i, c))
      end
    end
  end
end

vim.api.nvim_create_autocmd({ "UIEnter", "ColorScheme" }, {
  callback = function()
    make_transparent()
    -- Background is now transparent, so let the terminal's own bg show through.
    reset_bg()
    -- Sync the tmux status-bar accent to this colorscheme.
    set_accent()
    -- Sync the terminal's ANSI palette to this colorscheme.
    set_palette()
  end,
})

vim.api.nvim_create_autocmd("UILeave", {
  callback = function() reset_bg() end,
})

-- Skeleton for new .jsx files: insert a default-export arrow component named
-- after the file. For the `index.jsx` folder-component convention, name it
-- after the parent folder instead (so Foo/index.jsx -> `Foo`).
vim.api.nvim_create_autocmd("BufNewFile", {
  pattern = "*.jsx",
  callback = function(args)
    local path = args.file
    local stem = vim.fn.fnamemodify(path, ":t:r")
    if stem == "index" then
      stem = vim.fn.fnamemodify(path, ":h:t")
    end
    -- Make a safe PascalCase-ish identifier (strip non-word chars).
    local name = (stem:gsub("[^%w_]", ""))
    if name == "" then
      name = "Component"
    end

    -- Expand as a snippet (JetBrains-style tab stops): $1 = props, $2 = JSX
    -- body, $0 = final cursor. Jump fields with <Tab>/<S-Tab> (LazyVim default).
    local snippet = table.concat({
      "const " .. name .. " = ({ ${1} }) => {",
      "  return (",
      "    <div>${2}</div>",
      "  );",
      "};",
      "",
      "export default " .. name .. ";$0",
    }, "\n")
    -- Defer so it runs after the BufNewFile handler returns, with the cursor
    -- on the empty buffer's first line.
    vim.schedule(function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.snippet.expand(snippet)
    end)
  end,
})
