-- ═══════════════════════════════════════════════════════════════════════════
--  evilware — eDEX-UI inspired colorscheme
--  Electric cyan + hot crimson on transparent/black.
--  Built on tokyonight for full Treesitter / LSP / plugin coverage.
-- ═══════════════════════════════════════════════════════════════════════════

local ok, tokyonight = pcall(require, "tokyonight")
if not ok then
  vim.notify("evilware: tokyonight.nvim not found", vim.log.levels.ERROR)
  return
end

-- ─── Palette ────────────────────────────────────────────────────────────────
local cyan    = "#00FAFF" -- primary electric cyan
local teal    = "#00FFE1" -- bright accent / strings
local crimson = "#F10042" -- the "evil" pop — keywords, errors, cursor
local pink    = "#FF0059" -- secondary warm — numbers / constants
local dim     = "#0E5A5E" -- muted cyan — comments, line numbers
local faint   = "#06181A" -- barely-there cyan tint for cursorline
local sel     = "#072025" -- selection / visual
local black   = "#000000"

tokyonight.setup({
  style = "night",
  transparent = true, -- let Alacritty's pure-black show through
  styles = {
    sidebars = "transparent",
    floats = "transparent",
    comments = { italic = true },
    keywords = { italic = false },
  },

  -- Shift tokyonight's accent palette toward the evilware two-tone.
  on_colors = function(c)
    c.bg = black
    c.bg_dark = black
    c.bg_float = black
    c.bg_sidebar = black
    c.bg_statusline = black
    c.fg = cyan
    c.fg_dark = cyan
    c.blue = cyan
    c.blue1 = cyan
    c.cyan = teal
    c.green = teal
    c.green1 = teal
    c.teal = teal
    c.magenta = crimson
    c.magenta2 = crimson
    c.purple = crimson
    c.red = crimson
    c.red1 = crimson
    c.orange = pink
    c.yellow = pink
    c.border = cyan
    c.comment = dim
  end,

  -- Pin the structural groups: transparency + crisp cyan/crimson contrast.
  on_highlights = function(hl, c)
    hl.Normal       = { fg = cyan, bg = "NONE" }
    hl.NormalNC     = { fg = cyan, bg = "NONE" }
    hl.NormalFloat  = { fg = cyan, bg = "NONE" }
    hl.FloatBorder  = { fg = cyan, bg = "NONE" }
    hl.FloatTitle   = { fg = crimson, bold = true }
    hl.SignColumn   = { bg = "NONE" }
    hl.LineNr       = { fg = dim }
    hl.CursorLineNr = { fg = cyan, bold = true }
    hl.CursorLine   = { bg = faint }
    hl.Visual       = { bg = sel }
    hl.Search       = { fg = black, bg = teal }
    hl.IncSearch    = { fg = black, bg = crimson }
    hl.CurSearch    = { fg = black, bg = crimson }
    hl.MatchParen   = { fg = crimson, bold = true }
    hl.WinSeparator = { fg = cyan, bg = "NONE" }
    hl.Cursor       = { fg = black, bg = crimson }
    hl.Pmenu        = { fg = cyan, bg = "#04090A" }
    hl.PmenuSel     = { fg = black, bg = cyan, bold = true }
    hl.PmenuSbar    = { bg = "#04090A" }
    hl.PmenuThumb   = { bg = cyan }
    hl.StatusLine   = { fg = cyan, bg = "NONE" }

    -- Diagnostics: crimson screams, the rest stay in the cool range.
    hl.DiagnosticError = { fg = crimson }
    hl.DiagnosticWarn  = { fg = pink }
    hl.DiagnosticInfo  = { fg = cyan }
    hl.DiagnosticHint  = { fg = teal }

    -- Syntax — keep enough separation to stay readable.
    hl.Comment    = { fg = dim, italic = true }
    hl.Keyword    = { fg = crimson }
    hl.Statement  = { fg = crimson }
    hl.Conditional = { fg = crimson }
    hl.Operator   = { fg = pink }
    hl.Function   = { fg = cyan, bold = true }
    hl.String     = { fg = teal }
    hl.Constant   = { fg = pink }
    hl.Number     = { fg = pink }
    hl.Boolean    = { fg = pink }
    hl.Type       = { fg = cyan }
    hl.Identifier = { fg = "#7FFFED" }

    -- Treesitter niceties
    hl["@variable"]        = { fg = "#9CFCFF" }
    hl["@keyword"]         = { fg = crimson }
    hl["@function"]        = { fg = cyan, bold = true }
    hl["@function.call"]   = { fg = cyan }
    hl["@string"]          = { fg = teal }
    hl["@constant"]        = { fg = pink }
    hl["@punctuation.bracket"] = { fg = dim }
    hl["@comment"]         = { fg = dim, italic = true }
  end,
})

tokyonight.load()
vim.g.colors_name = "evilware"
