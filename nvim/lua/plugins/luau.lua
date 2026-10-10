-- Roblox / Luau support via luau-lsp.nvim.
-- Tools (rojo, wally, selene, stylua) are pinned per-project with rokit.

-- Treat .lua files inside a Rojo project as Luau so luau-lsp attaches
-- instead of lua_ls.
vim.filetype.add({
  extension = {
    lua = function(path)
      local root = vim.fs.root(path, function(name)
        return name:match("%.project%.json$") ~= nil
      end)
      return root and "luau" or "lua"
    end,
  },
})

return {
  {
    "lopi-py/luau-lsp.nvim",
    ft = "luau",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      platform = { type = "roblox" },
      types = { roblox_security_level = "PluginSecurity" },
      sourcemap = {
        enabled = true,
        autogenerate = true, -- runs `rojo sourcemap --watch`
        rojo_project_file = "default.project.json",
      },
      plugin = { enabled = true, port = 3667 },
    },
  },
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "luau-lsp" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        -- luau-lsp.nvim starts the server itself; keep mason-lspconfig from
        -- enabling a second instance.
        luau_lsp = { enabled = false },
      },
    },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "luau" } },
  },
}
