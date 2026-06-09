-- Only let the ESLint LSP attach when the project actually has an ESLint
-- config. Without this, eslint attaches via the .git/package.json fallback in
-- config-less projects and spams:
--   -32603: Request textDocument/diagnostic failed ... Could not find config file
-- The root_dir callback (nvim 0.11+ async form) only calls on_dir when a real
-- config exists; otherwise the server never starts for that buffer.
return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      eslint = {
        -- ESLint 9 defaults to flat config (eslint.config.js). Projects still
        -- on legacy .eslintrc.* make the server throw:
        --   -32603: ... Could not find config file
        -- Force legacy config resolution so it picks up the .eslintrc.json.
        settings = {
          useFlatConfig = false,
        },
        root_dir = function(bufnr, on_dir)
          local root = vim.fs.root(bufnr, {
            ".eslintrc",
            ".eslintrc.js",
            ".eslintrc.cjs",
            ".eslintrc.yaml",
            ".eslintrc.yml",
            ".eslintrc.json",
            "eslint.config.js",
            "eslint.config.mjs",
            "eslint.config.cjs",
            "eslint.config.ts",
            "eslint.config.mts",
            "eslint.config.cts",
          })
          if root then
            on_dir(root)
          end
        end,
      },
    },
  },
}
