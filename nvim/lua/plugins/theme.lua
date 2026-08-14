-- Indent guides and line numbers are pinned to fixed colors rather than each
-- theme's, because the background is forced to one color regardless of theme,
-- so per-theme values drift against it.
--
-- They used to share a single value. Line numbers need to read as text, indent
-- guides only need to hint, so line numbers get their own, lighter one. For
-- reference the themes' own LineNr sits around #505050-#6e6a86, so this is
-- still well below what they'd pick.
local function applySnackStyling(indent, linenr)
  indent = indent or "#242423"
  linenr = linenr or "#3a3a38"
  vim.api.nvim_set_hl(0, "SnacksIndent", { fg = indent })
  vim.api.nvim_set_hl(0, "SnacksIndentScope", { fg = indent })
  vim.api.nvim_set_hl(0, "SnacksIndentChunk", { fg = indent })
  vim.api.nvim_set_hl(0, "LineNr", { fg = linenr })
end

-- Apply my indent-guide + LineNr colors on every colorscheme, not just vesper.
vim.api.nvim_create_autocmd("ColorScheme", {
  pattern = "*",
  callback = function()
    applySnackStyling()
  end,
})

-- Remember whatever I switch to with `:colorscheme` and restore it next launch
-- (the LazyVim `colorscheme` opt below reads this file on startup).
local last_colorscheme = vim.fn.stdpath("data") .. "/last_colorscheme.txt"
vim.api.nvim_create_autocmd("ColorScheme", {
  pattern = "*",
  callback = function(args)
    pcall(vim.fn.writefile, { args.match }, last_colorscheme)
  end,
})

-- Garbage themes will not be kept here :D
return {
  {
    "kepano/flexoki-neovim",
    name = "flexoki",
    priority = 1010,
    lazy = false,
  },
  {
    "datsfilipe/vesper.nvim",
    priority = 1005,
    lazy = false,
    config = function()
      applySnackStyling()
    end,
  },
  {
    "henrianttila/electric-nord.nvim",
    priority = 1006,
    name = "electric-nord",
    lazy = false,
  },
  {
    "ramojus/mellifluous.nvim",
  },
  {
    "sam4llis/nvim-tundra",
  },
  {
    "kuri-sun/yoda.nvim",
  },
  {
    "smit4k/shale.nvim",
  },
  {
    -- ayu
    "Shatur/neovim-ayu",
  },
  {
    "loctvl842/monokai-pro.nvim",
    lazy = false,
    priority = 1000,
  },
  {
    "valonmulolli/heap.nvim",
  },
  {
    "ologio/monobiome",
    priority = 1005,
  },
  {
    "rmehri01/onenord.nvim",
    priority = 1000,
    lazy = false,
  },
  {
    --kanagawa
    "rebelot/kanagawa.nvim",
    priority = 1006,
  },
  {
    "rose-pine/neovim",
    name = "rose-pine",
  },
  {
    "vague-theme/vague.nvim",
    priority = 1003,
  },
  {
    "olimorris/onedarkpro.nvim",
    priority = 1000,
  },
  {
    "bluz71/vim-moonfly-colors",
    priority = 1000,
  },
  {
    "savq/melange-nvim",
    priority = 1001,
  },
  {
    "sainnhe/gruvbox-material",
    priority = 1002,
    lazy = false,
    config = function()
      vim.g.gruvbox_material_foreground = "original"
      vim.g.gruvbox_material_background = "hard"
      vim.g.gruvbox_material_enable_bold = 1
    end,
  },
  {
    "ribru17/bamboo.nvim",
    priority = 1003,
  },
  {
    "Mofiqul/vscode.nvim",
    priority = 1000,
  },
  {
    "tiesen243/vercel.nvim",
    config = function()
      require("vercel").setup({
        theme = "dark",
      })
    end,
  },
  {
    -- base for the custom `evilware` colorscheme (colors/evilware.lua)
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1010,
  },
  {
    "sdhrt/codesandbox-theme.nvim",
    priority = 1000,
    lazy = false,
  },
  {
    "LazyVim/LazyVim",
    opts = {
      -- Restore the last `:colorscheme` I picked; fall back to evilware.
      colorscheme = function()
        local ok, lines = pcall(vim.fn.readfile, last_colorscheme)
        local saved = ok and lines[1]
        if saved and saved ~= "" and pcall(vim.cmd.colorscheme, saved) then
          return
        end
        vim.cmd.colorscheme("evilware")
      end,
    },
  },
}
