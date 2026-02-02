return {
  {
    "saghen/blink.cmp",
    opts = {
      keymap = {
        ["<Tab>"] = {
          LazyVim.cmp.map({ "snippet_forward" }),
          "fallback",
        },
        ["<C-y>"] = {
          LazyVim.cmp.map({ "ai_accept" }),
          "fallback",
        },
      },
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        copilot = {
          keys = {
            {
              "<C-y>",
              function()
                vim.lsp.inline_completion.accept()
              end,
              desc = "Accept Copilot Suggestion",
              mode = "i",
            },
            {
              "<PageDown>",
              function()
                vim.lsp.inline_completion.select({ count = 1 })
              end,
              desc = "Next Copilot Suggestion",
              mode = { "i", "n" },
            },
            {
              "<PageUp>",
              function()
                vim.lsp.inline_completion.select({ count = -1 })
              end,
              desc = "Prev Copilot Suggestion",
              mode = { "i", "n" },
            },
          },
        },
      },
    },
  },
}
