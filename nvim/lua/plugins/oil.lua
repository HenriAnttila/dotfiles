return {
  "stevearc/oil.nvim",
  lazy = false,
  dependencies = { { "echasnovski/mini.icons", opts = {} } },
  opts = {},
  keys = {
    { "-", "<cmd>Oil<cr>", desc = "Open parent directory (Oil)" },
  },
}
