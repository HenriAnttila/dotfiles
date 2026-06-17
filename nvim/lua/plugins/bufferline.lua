-- Disable the bufferline (buffer tabs at the top). Navigation is handled by
-- Harpoon + telescope, so the tabs were just noise — especially with the tmux
-- status bar also sitting at the top.
return {
  { "akinsho/bufferline.nvim", enabled = false },
}
