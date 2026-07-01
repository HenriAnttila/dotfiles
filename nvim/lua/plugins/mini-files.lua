return {
  "nvim-mini/mini.files",
  version = false,
  dependencies = { { "nvim-mini/mini.icons", opts = {} } },
  opts = {
    windows = {
      preview = true,
      width_preview = 50,
    },
  },
  keys = {
    {
      "<leader>fm",
      function()
        local files = require("mini.files")
        -- open at the current file, or cwd if the buffer has no file
        if not files.close() then
          files.open(vim.api.nvim_buf_get_name(0), true)
        end
      end,
      desc = "Open file explorer (mini.files)",
    },
    {
      "<leader>fM",
      function()
        require("mini.files").open(vim.uv.cwd(), true)
      end,
      desc = "Open file explorer (cwd)",
    },
  },
  config = function(_, opts)
    require("mini.files").setup(opts)

    -- `B` in any mini.files buffer creates a barrel-export component
    -- in the folder under the cursor.
    vim.api.nvim_create_autocmd("User", {
      pattern = "MiniFilesBufferCreate",
      callback = function(args)
        vim.keymap.set("n", "B", function()
          require("util.barrel").mini_action()
        end, { buffer = args.data.buf_id, desc = "Create barrel export" })
      end,
    })
  end,
}
