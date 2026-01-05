-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

vim.keymap.set({ "n", "x" }, "d", '"_d', { desc = "Delete without yanking" })
vim.keymap.set({ "n", "x" }, "D", '"_D', { desc = "Delete to end without yanking" })
vim.keymap.set("n", "dd", '"_dd', { desc = "Delete line without yanking" })

vim.keymap.set({ "n", "x" }, "m", "d", { desc = "Cut" })
vim.keymap.set({ "n", "x" }, "M", "D", { desc = "Cut to end" })
vim.keymap.set("n", "mm", "dd", { desc = "Cut line" })
