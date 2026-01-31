-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

vim.keymap.set({ "n", "x" }, "d", '"_d', { desc = "Delete without yanking" })
vim.keymap.set({ "n", "x" }, "D", '"_D', { desc = "Delete to end without yanking" })
vim.keymap.set("n", "dd", '"_dd', { desc = "Delete line without yanking" })

vim.keymap.set({ "n", "x" }, "m", "d", { desc = "Cut" })
vim.keymap.set({ "n", "x" }, "M", "D", { desc = "Cut to end" })
vim.keymap.set("n", "mm", "dd", { desc = "Cut line" })

vim.keymap.set("n", "<leader>o", function()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, line - 1, line + 1, false)

  local line_above = lines[1] or ""
  local line_below = lines[2] or ""

  -- Check if there's already an empty line above
  local need_line_above = line_above:match("^%s*$") == nil
  -- Check if there's already an empty line below
  local need_line_below = line_below:match("^%s*$") == nil

  local new_lines = {}
  if need_line_above then
    table.insert(new_lines, "")
  end
  table.insert(new_lines, "")
  if need_line_below then
    table.insert(new_lines, "")
  end

  vim.api.nvim_buf_set_lines(0, line, line, false, new_lines)

  -- Move cursor to the new middle line
  local offset = need_line_above and 2 or 1
  vim.api.nvim_win_set_cursor(0, { line + offset, 0 })
  vim.cmd("startinsert")
end, { desc = "Insert line with padding" })
