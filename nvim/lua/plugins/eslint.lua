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
        -- Don't force a config mode. ESLint 9 defaults to flat config
        -- (eslint.config.*); legacy projects with .eslintrc.* are still
        -- auto-detected by the server. Hard-coding useFlatConfig = false broke
        -- flat-config projects (server looked for a nonexistent .eslintrc and
        -- threw -32603 "no eslint config").
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
