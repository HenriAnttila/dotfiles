local function applySnackStyling()
  -- subtle snacks.nvim indent lines using #242423
  vim.api.nvim_set_hl(0, "SnacksIndent", { fg = "#242423" })
  vim.api.nvim_set_hl(0, "SnacksIndentScope", { fg = "#242423" })
  vim.api.nvim_set_hl(0, "SnacksIndentChunk", { fg = "#242423" })
  vim.api.nvim_set_hl(0, "LineNr", { fg = "#242423" })
end

return {
  -- Gruvbox Material Original with custom background
  {
    "sainnhe/gruvbox-material",
    lazy = false,
    priority = 1001,
    config = function()
      vim.g.gruvbox_material_background = "hard" -- soft, medium, hard
      vim.g.gruvbox_material_foreground = "original"
      vim.g.gruvbox_material_enable_bold = 1
      vim.g.gruvbox_material_enable_italic = 1

      -- Apply colorscheme FIRST
      vim.cmd([[colorscheme gruvbox-material]])

      -- Then override the background with custom color
      vim.cmd([[highlight Normal guibg=#0e0f17 ctermbg=NONE]])
      vim.cmd([[highlight NormalNC guibg=#0e0f17 ctermbg=NONE]]) -- Non-current windows
    end,
  },
  {
    "tiesen243/vercel.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      require("vercel").setup({
        theme = "dark",
        transparent = false,
        italics = {
          comments = true,
          keywords = true,
          functions = true,
          strings = true,
          variables = true,
          bufferline = false,
        },
        overrides = {},
      })

      vim.cmd.colorscheme("vercel")
      applySnackStyling()
    end,
  },
  {
    "AlexvZyl/nordic.nvim",
    lazy = false,
    priority = 1000,
  },
  {
    "Mofiqul/vscode.nvim",
    lazy = false,
    priority = 1000,
  },
  { "EdenEast/nightfox.nvim", lazy = false, priority = 1000
 },
  {
    "vague-theme/vague.nvim",
    lazy = false, -- make sure we load this during startup if it is your main colorscheme
    priority = 1100, -- make sure to load this before all the other plugins
    config = function()
      vim.cmd("colorscheme vague")
      applySnackStyling()
    end,
  },
}
