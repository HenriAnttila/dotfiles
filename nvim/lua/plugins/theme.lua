local function applySnackStyling(color)
  color = color or "#242423"
  vim.api.nvim_set_hl(0, "SnacksIndent", { fg = color })
  vim.api.nvim_set_hl(0, "SnacksIndentScope", { fg = color })
  vim.api.nvim_set_hl(0, "SnacksIndentChunk", { fg = color })
  vim.api.nvim_set_hl(0, "LineNr", { fg = color })
end

-- Garbage themes will not be kept here :D
return {
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
  },
  {
    "ribru17/bamboo.nvim",
    priority = 1003,
  },
  {
    "Mofiqul/vscode.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("vscode")
    end,
  },
  {
    "tiesen243/vercel.nvim",
    config = function()
      require("vercel").setup({
        theme = "dark",
      })
    end,
  },
}
