return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      pyright = {
        settings = {
          python = {
            pythonPath = "/opt/anaconda3/bin/python",
          },
        },
      },
    },
  },
}
