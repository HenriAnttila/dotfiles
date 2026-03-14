-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- Sync terminal background with Neovim colorscheme (hides padding)
local function set_bg(color)
  local hex = string.format("#%06x", color)
  if vim.env.TMUX then
    io.write(string.format("\027Ptmux;\027\027]11;%s\007\027\\", hex))
    vim.fn.system({ "tmux", "set", "-g", "status-style", "bg=" .. hex })
  else
    io.write(string.format("\027]11;%s\027\\", hex))
  end
end

local function reset_bg()
  if vim.env.TMUX then
    io.write("\027Ptmux;\027\027]111;\007\027\\")
    vim.fn.system({ "tmux", "set", "-g", "status-style", "bg=#2E3440" })
  else
    io.write("\027]111\027\\")
  end
end

vim.api.nvim_create_autocmd({ "UIEnter", "ColorScheme" }, {
  callback = function()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
    if not normal.bg then return end
    set_bg(normal.bg)
  end,
})

vim.api.nvim_create_autocmd("UILeave", {
  callback = function() reset_bg() end,
})
