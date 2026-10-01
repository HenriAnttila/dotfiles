-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.opt.number = true
vim.opt.relativenumber = true
vim.o.linespace = 11
-- Blink the cursor in every mode (VS Code style, ~500ms on / 500ms off)
vim.opt.guicursor:append("a:blinkwait500-blinkon500-blinkoff500")
