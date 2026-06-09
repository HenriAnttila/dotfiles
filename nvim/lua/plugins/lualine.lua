-- Trim the LazyVim lualine statusline: drop the git branch, the current
-- folder (root_dir), and the clock.
return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    local s = opts.sections

    -- git branch lives alone in section b
    s.lualine_b = {}

    -- the clock (os.date) lives alone in section z
    s.lualine_z = {}

    -- LazyVim puts root_dir (current folder) as the first item of section c;
    -- remove it but keep diagnostics / filetype / file path.
    if s.lualine_c and s.lualine_c[1] then
      table.remove(s.lualine_c, 1)
    end
  end,
}
