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
    "bluz71/vim-moonfly-colors",
    priority = 1000,
    lazy = false,
  },
  {
    "savq/melange-nvim",
    priority = 1001,
    lazy = false,
    config = function()
      vim.cmd.colorscheme("melange")
    end,
  },
  {
    "sainnhe/gruvbox-material",
    priority = 1002,
  },
  {
    "ribru17/bamboo.nvim",
    priority = 1003,
  },
}
