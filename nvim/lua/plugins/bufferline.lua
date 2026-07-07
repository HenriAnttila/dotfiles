-- Disable the bufferline (buffer tabs at the top). Navigation is handled by
-- Harpoon + telescope, so the tabs were just noise — especially with the tmux
-- status bar also sitting at the top.
return {
  { "akinsho/bufferline.nvim", enabled = false },
  {
    "kiennt63/harpoon-files.nvim",
    dependencies = {
      { "ThePrimeagen/harpoon", branch = "harpoon2" },
    },
    main = "harpoon_files",
    opts = {
      max_length = 20,
      show_icon = true,
      show_index = true,
      show_filename = true,
    },
  },
}
