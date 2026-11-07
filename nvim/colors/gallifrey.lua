-- ═══════════════════════════════════════════════════════════════════════════
--  gallifrey — matches the space wallpaper (~/Pictures/space-*.png)
--  Near-black teal space, glowing Gallifreyan teal as the accent, soft cyan
--  text, one warm gold for numbers and warnings.
--  Built on tokyonight for full Treesitter / LSP / plugin coverage, like
--  evilware.
-- ═══════════════════════════════════════════════════════════════════════════

local ok, tokyonight = pcall(require, "tokyonight")
if not ok then
  vim.notify("gallifrey: tokyonight.nvim not found", vim.log.levels.ERROR)
  return
end

-- ─── Palette ────────────────────────────────────────────────────────────────
local bg      = "#040b0d" -- the wallpaper's space; Ghostty's background
local bg_dark = "#020607"
local float   = "#071417" -- popups, completion menu
local faint   = "#081719" -- cursorline
local sel     = "#0f3236" -- selection / visual: the teal haze
local border  = "#1d4a4b"
local comment = "#3f6966"
local fg_dim  = "#7fa3a0"
local fg      = "#b9d6d3" -- soft cyan-grey text
local glow    = "#bef5f0" -- the glyphs' white-hot core
local teal    = "#46e1cd" -- the glyphs: accent, functions, cursor
local cyan    = "#7ad6e6" -- types
local blue    = "#5fb3d9" -- keywords
local mint    = "#8fd6b4" -- strings
local gold    = "#d9b56c" -- numbers, constants, warnings
local violet  = "#a99be0" -- specials
local red     = "#e06c75" -- errors

tokyonight.setup({
  style = "night",
  transparent = false, -- autocmds.lua clears Normal's bg; Ghostty paints `bg`
  styles = {
    comments = { italic = true },
    keywords = { italic = false },
  },

  on_colors = function(c)
    c.bg = bg
    c.bg_dark = bg_dark
    c.bg_dark1 = bg_dark
    c.bg_float = float
    c.bg_popup = float
    c.bg_sidebar = bg
    c.bg_statusline = bg
    c.bg_highlight = faint
    c.bg_visual = sel
    c.fg = fg
    c.fg_dark = fg_dim
    c.fg_float = fg
    c.fg_gutter = comment
    c.dark3 = comment
    c.dark5 = fg_dim
    c.comment = comment
    c.border = border
    c.border_highlight = teal
    c.blue = blue
    c.blue0 = sel
    c.blue1 = cyan
    c.blue2 = teal
    c.blue5 = cyan
    c.blue6 = glow
    c.blue7 = sel
    c.cyan = cyan
    c.teal = teal
    c.green = mint
    c.green1 = teal
    c.green2 = teal
    c.magenta = violet
    c.magenta2 = violet
    c.purple = violet
    c.orange = gold
    c.yellow = gold
    c.red = red
    c.red1 = red
  end,

  on_highlights = function(hl, c)
    hl.Normal       = { fg = fg, bg = bg }
    hl.NormalNC     = { fg = fg, bg = bg }
    hl.NormalFloat  = { fg = fg, bg = float }
    hl.FloatBorder  = { fg = border, bg = float }
    hl.FloatTitle   = { fg = teal, bg = float, bold = true }
    hl.LineNr       = { fg = comment }
    hl.CursorLineNr = { fg = teal, bold = true }
    hl.CursorLine   = { bg = faint }
    hl.Visual       = { bg = sel }
    hl.Search       = { fg = bg, bg = mint }
    hl.IncSearch    = { fg = bg, bg = teal }
    hl.CurSearch    = { fg = bg, bg = teal }
    hl.MatchParen   = { fg = glow, bold = true, underline = true }
    hl.WinSeparator = { fg = border }
    hl.Cursor       = { fg = bg, bg = teal }
    hl.Pmenu        = { fg = fg, bg = float }
    hl.PmenuSel     = { fg = bg, bg = teal, bold = true }
    hl.PmenuSbar    = { bg = float }
    hl.PmenuThumb   = { bg = border }
    hl.StatusLine   = { fg = fg_dim, bg = "NONE" }

    hl.DiagnosticError = { fg = red }
    hl.DiagnosticWarn  = { fg = gold }
    hl.DiagnosticInfo  = { fg = cyan }
    hl.DiagnosticHint  = { fg = teal }

    hl.Comment     = { fg = comment, italic = true }
    hl.Keyword     = { fg = blue }
    hl.Statement   = { fg = blue }
    hl.Conditional = { fg = blue }
    hl.Operator    = { fg = fg_dim }
    hl.Function    = { fg = teal, bold = true }
    hl.String      = { fg = mint }
    hl.Constant    = { fg = gold }
    hl.Number      = { fg = gold }
    hl.Boolean     = { fg = gold }
    hl.Type        = { fg = cyan }
    hl.Special     = { fg = violet }
    hl.Identifier  = { fg = fg }

    hl["@variable"]            = { fg = fg }
    hl["@variable.member"]     = { fg = glow }
    hl["@property"]            = { fg = glow }
    hl["@keyword"]             = { fg = blue }
    hl["@function"]            = { fg = teal, bold = true }
    hl["@function.call"]       = { fg = teal }
    hl["@string"]              = { fg = mint }
    hl["@constant"]            = { fg = gold }
    hl["@punctuation.bracket"] = { fg = fg_dim }
    hl["@comment"]             = { fg = comment, italic = true }
  end,
})

tokyonight.load()
vim.g.colors_name = "gallifrey"

-- The terminal palette: Ghostty, the shell and yazi's `ansi` flavor get these
-- through autocmds.lua (OSC 4) and the tmux theme picker.
local term = {
  "#0a1a1c", red, mint, gold, blue, violet, teal, fg,
  "#2f5552", "#f08a91", "#aee6cc", "#e8cc8f", "#86c8e6", "#c2b8ee", "#8aefe0", "#e6fbf8",
}
for i, col in ipairs(term) do
  vim.g["terminal_color_" .. (i - 1)] = col
end
