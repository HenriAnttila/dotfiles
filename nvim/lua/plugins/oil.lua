return {
  "stevearc/oil.nvim",
  dependencies = { "nvim-mini/mini.icons" },
  cmd = "Oil",
  keys = {
    {
      "-",
      "<cmd>Oil<cr>",
      desc = "Open parent directory in oil",
    },
  },
  ---@type oil.SetupOpts
  opts = {
    -- don't take over directory buffers (`nvim .`, `:e dir`)
    default_file_explorer = false,
  },
}
