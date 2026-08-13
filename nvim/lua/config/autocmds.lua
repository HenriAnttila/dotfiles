-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- Scale a #rrggbb string's channels by f (0..1). Multiplying rather than
-- subtracting keeps hue and saturation, and is self-limiting: a theme that is
-- already near-black barely moves, while a lighter one drops a lot.
local function darken(hex, f)
  local function chan(i)
    return tonumber(hex:sub(i, i + 1), 16)
  end
  return string.format(
    "#%02x%02x%02x",
    math.floor(chan(2) * f + 0.5),
    math.floor(chan(4) * f + 0.5),
    math.floor(chan(6) * f + 0.5)
  )
end

-- Target brightness for the terminal background: the value the *brightest*
-- channel gets scaled to. 0x0a is near-black. Raise for a lighter backdrop.
local BG_LEVEL = 0x0a

-- Pin a colour to BG_LEVEL while keeping its hue. Scaling by the peak channel
-- (rather than by a flat factor) puts every theme at the same depth, so what
-- separates them is only their colour cast -- kanagawa's blue, rose-pine's
-- violet -- and not their lightness. A flat factor would instead shrink those
-- differences along with the brightness, which is what washes them out.
-- Never brightens: a theme already darker than BG_LEVEL is left as it is.
local function near_black(hex)
  local function chan(i)
    return tonumber(hex:sub(i, i + 1), 16)
  end
  local r, g, b = chan(2), chan(4), chan(6)
  local peak = math.max(r, g, b)
  if peak == 0 then
    return "#000000"
  end
  return darken(hex, math.min(1, BG_LEVEL / peak))
end

-- Sync terminal background with Neovim colorscheme (hides padding)
local function set_bg(color)
  local hex = near_black(string.format("#%06x", color))
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

-- Remember the last real Normal background. make_transparent() below clears
-- Normal.bg, and UIEnter can fire *after* that has already run, so reading the
-- highlight at that point returns nil. Caching keeps a color available.
local last_bg

local function normal_bg()
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  if ok and hl and hl.bg then
    last_bg = hl.bg
  end
  return last_bg
end

-- Strip nvim's own background on every theme change. The terminal itself is
-- painted the same color via OSC 11 below, so this leaves no seam between the
-- buffer, the window padding, and the tmux status bar.
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
  -- A muted version for pane borders: same hue/saturation, just dimmer, so the
  -- active split is the accent but not loud.
  vim.fn.jobstart({ "tmux", "set", "-g", "@accent_dim", darken(accent, 0.6) })
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
    -- Read Normal.bg before make_transparent() clears it.
    local bg = normal_bg()
    make_transparent()
    -- Paint the terminal itself the colorscheme's background. ghostty's
    -- window-padding-color=extend-always makes the padding follow, and the tmux
    -- status bar is bg=default, so the whole window ends up one colour.
    if bg then
      set_bg(bg)
    else
      -- Theme defines no Normal bg; fall back to the terminal's own default.
      reset_bg()
    end
    -- Sync the tmux status-bar accent to this colorscheme.
    set_accent()
    -- Sync the terminal's ANSI palette to this colorscheme.
    set_palette()
  end,
})

-- Deliberately no UILeave reset: the background persists after nvim exits, the
-- same way set_palette() leaves the ANSI palette in place, so the shell keeps
-- the theme instead of snapping back to ghostty's static `background`. Add
-- `vim.api.nvim_create_autocmd("UILeave", { callback = reset_bg })` to undo.

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
