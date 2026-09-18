return {
  {
    "akinsho/toggleterm.nvim",
    version = "*",
    keys = {
      {
        "<leader>th",
        "<cmd>ToggleTerm direction=horizontal size=10<cr>",
        desc = "Open horizontal terminal",
        mode = "n",
      },
      {
        "<leader>tv",
        "<cmd>ToggleTerm direction=vertical<cr>",
        desc = "Open vertical terminal",
        mode = "n",
      },
      {
        "<leader>tf",
        "<cmd>ToggleTerm direction=float<cr>",
        desc = "Open floating terminal",
        mode = "n",
      },
      -- <leader>ac / <leader>af now belong to claudecode.nvim (see
      -- plugins/claudecode.lua). They opened plain `claude` floats here.
      {
        "<leader>rd",
        function()
          require("toggleterm.terminal").Terminal
            :new({
              cmd = "npm run dev",
              direction = "horizontal",
              id = 98,
            })
            :toggle()
        end,
        desc = "NPM Run Dev",
        mode = "n",
      },
      {
        "<leader>re",
        function()
          require("toggleterm.terminal").Terminal
            :new({
              cmd = "npx expo start",
              direction = "horizontal",
              id = 99,
            })
            :toggle()
        end,
        desc = "Expo Start",
        mode = "n",
      },
      {
        "<leader>tt",
        "<cmd>ToggleTerm<cr>",
        desc = "Toggle terminal",
        mode = "n",
      },
      {
        "<leader>t1",
        "<cmd>1ToggleTerm<cr>",
        desc = "Toggle terminal 1",
        mode = "n",
      },
      {
        "<leader>t2",
        "<cmd>2ToggleTerm<cr>",
        desc = "Toggle terminal 2",
        mode = "n",
      },
      {
        "<leader>t3",
        "<cmd>3ToggleTerm<cr>",
        desc = "Toggle terminal 3",
        mode = "n",
      },
    },
    config = function()
      require("toggleterm").setup({
        size = 10,
        hide_numbers = true,
        shade_terminals = true,
        shading_factor = 2,
        start_in_insert = true,
        persist_size = true,
        direction = "horizontal",
        close_on_exit = true,
        float_opts = {
          border = "curved",
          winblend = 0,
          highlights = { border = "Normal", background = "Normal" },
        },
      })
    end,
  },
}
