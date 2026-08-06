-- git blame for the current line, surfaced in the lualine statusline instead
-- of as inline virtual text. The lualine component lives in lualine.lua.
return {
  "f-person/git-blame.nvim",
  event = "VeryLazy",
  opts = {
    enabled = true,
    -- We render the blame in the statusline, so turn off the end-of-line
    -- virtual text.
    virtual_text = false,
    display_virtual_text = false,
    message_template = "  <author> • <date> • <summary>",
    date_format = "%r", -- relative time, e.g. "3 days ago"
  },
}
