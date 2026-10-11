-- Roblox / Luau support via luau-lsp.nvim.
-- Tools (rojo, wally, selene, stylua) are pinned per-project with rokit.

---@param source string|integer path or buffer
local function rojo_root(source)
  return vim.fs.root(source, function(name)
    return name:match("%.project%.json$") ~= nil
  end)
end

-- Treat .lua files inside a Rojo project as Luau so luau-lsp attaches
-- instead of lua_ls.
vim.filetype.add({
  extension = {
    lua = function(path)
      return rojo_root(path) and "luau" or "lua"
    end,
  },
})

-- luau-lsp.nvim finds the project file, writes sourcemap.json and runs rojo (a rokit
-- shim that only works inside the project) all relative to the cwd. Move the tab into
-- the Rojo project first, so it works however nvim was started. Registered before
-- lazy.nvim's ft handler, so it runs before the plugin loads.
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("luau-rojo-root", {}),
  pattern = "luau",
  callback = function(args)
    local root = rojo_root(args.buf)
    if root and vim.uv.cwd() ~= root then
      vim.cmd.tcd(root)
    end
  end,
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
  {
    -- selene alongside luau-lsp: it catches things the type checker lets through.
    -- Uses the project's rokit-pinned selene, so it's not installed through mason.
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = { luau = { "selene" } },
      linters = {
        selene = {
          -- only in projects that configure selene. Also runs selene from that project:
          -- rokit's shim picks the pinned version from the cwd's rokit.toml and fails
          -- anywhere else, which nvim-lint would swallow silently.
          condition = function(ctx)
            local config = vim.fs.find("selene.toml", { path = ctx.filename, upward = true })[1]
            if not config then
              return false
            end
            require("lint").linters.selene.cwd = vim.fs.dirname(config)
            return true
          end,
        },
      },
    },
  },
}
