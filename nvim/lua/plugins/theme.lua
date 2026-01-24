local function applySnackStyling()
  -- subtle snacks.nvim indent lines using #242423
  vim.api.nvim_set_hl(0, "SnacksIndent", { fg = "#242423" })
  vim.api.nvim_set_hl(0, "SnacksIndentScope", { fg = "#242423" })
  vim.api.nvim_set_hl(0, "SnacksIndentChunk", { fg = "#242423" })
  vim.api.nvim_set_hl(0, "LineNr", { fg = "#242423" })
end

return {
  {
    "datsfilipe/vesper.nvim",
    priority = 1005,
    lazy = false,
    config = function()
      vim.cmd("colorscheme vesper")
      applySnackStyling()
    end,
  },
}
