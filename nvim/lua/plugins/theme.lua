local function applySnackStyling(color)
  color = color or "#242423"
  vim.api.nvim_set_hl(0, "SnacksIndent", { fg = color })
  vim.api.nvim_set_hl(0, "SnacksIndentScope", { fg = color })
  vim.api.nvim_set_hl(0, "SnacksIndentChunk", { fg = color })
  vim.api.nvim_set_hl(0, "LineNr", { fg = color })
end

vim.api.nvim_create_autocmd("ColorScheme", {
  pattern = "vesper",
  callback = function()
    applySnackStyling()
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
      colorscheme = "evilware",
    },
  },
}
