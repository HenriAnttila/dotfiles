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
    -- Derive a muted fg from the bg so inactive dotbar text always has contrast
    local r = math.floor(color / 65536)
    local g = math.floor(color / 256) % 256
    local b = color % 256
    local lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    local fg
    if lum > 0.5 then
      fg = string.format("#%02x%02x%02x", math.max(0, r - 70), math.max(0, g - 70), math.max(0, b - 70))
    else
      fg = string.format("#%02x%02x%02x", math.min(255, r + 50), math.min(255, g + 50), math.min(255, b + 50))
    end
    vim.fn.jobstart({ "bash", "-c", string.format(
      "tmux set -g @tmux-dotbar-bg '%s' && tmux set -g @tmux-dotbar-fg '%s' && ~/.tmux/plugins/tmux-dotbar/dotbar.tmux",
      hex, fg
    ) })
  else
    io.write(string.format("\027]11;%s\027\\", hex))
  end
end

local function reset_bg()
  if vim.env.TMUX then
    io.write("\027Ptmux;\027\027]111;\007\027\\")
    vim.fn.jobstart({ "bash", "-c",
      "tmux set -g @tmux-dotbar-bg default && tmux set -g @tmux-dotbar-fg '#4C566A' && ~/.tmux/plugins/tmux-dotbar/dotbar.tmux",
    })
  else
    io.write("\027]111\027\\")
  end
end

-- Make the background transparent on every theme change so the terminal
-- (and its blur/wallpaper) shows through.
local transparent_groups = {
  "Normal",
  "NormalNC",
  "NormalFloat",
  "FloatBorder",
  "FloatTitle",
  "SignColumn",
  "MsgArea",
  "TelescopeNormal",
  "TelescopeBorder",
  "NormalSB",
  "WinBar",
  "WinBarNC",
}

local function make_transparent()
  for _, group in ipairs(transparent_groups) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group })
    if ok and next(hl) ~= nil then
      hl.bg = nil
      hl.ctermbg = nil
      vim.api.nvim_set_hl(0, group, hl)
    end
  end
end

vim.api.nvim_create_autocmd({ "UIEnter", "ColorScheme" }, {
  callback = function()
    make_transparent()
    -- Background is now transparent, so let the terminal's own bg show through.
    reset_bg()
  end,
})

vim.api.nvim_create_autocmd("UILeave", {
  callback = function() reset_bg() end,
})
