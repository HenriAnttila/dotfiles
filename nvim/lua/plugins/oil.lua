return {
  "stevearc/oil.nvim",
  lazy = false,
  dependencies = { { "nvim-mini/mini.icons", opts = {} } },
  opts = {
    keymaps = {
      ["q"] = "actions.close",
    },
  },
  keys = {
    { "-", "<cmd>Oil<cr>", desc = "Open parent directory (Oil)" },
    -- `_` (Shift+-) always opens at the project root (nvim's cwd), so you get
    -- the full top-level view every time and drill down from there. Closing
    -- oil drops you back on your file; reopening gives the fresh root view again.
    {
      "_",
      function()
        require("oil").open(vim.uv.cwd())
      end,
      desc = "Open project root / cwd (Oil)",
    },
  },
}
