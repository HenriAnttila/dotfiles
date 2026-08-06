-- Trim the LazyVim lualine statusline: drop the git branch, the current
-- folder (root_dir), and the clock.
return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "f-person/git-blame.nvim" },
  opts = function(_, opts)
    local s = opts.sections

    -- Current-line git blame (author • relative date • summary). Only shows
    -- when blame info is available for the line under the cursor.
    local ok_blame, git_blame = pcall(require, "gitblame")
    if ok_blame then
      table.insert(s.lualine_x, 1, {
        git_blame.get_current_blame_text,
        cond = git_blame.is_blame_text_available,
      })
    end

    -- git branch lives alone in section b
    s.lualine_b = {}

    -- the clock (os.date) lives alone in section z
    s.lualine_z = {}

    -- LazyVim puts root_dir (current folder) as the first item of section c;
    -- remove it but keep diagnostics / filetype / file path.
    if s.lualine_c and s.lualine_c[1] then
      table.remove(s.lualine_c, 1)
    end

    -- Show the Harpoon list in the statusline so pinned files are always
    -- visible instead of hidden behind <leader>1..9. Next.js app-router means
    -- every file is page.js/layout.js/route.js, so the bare filename is
    -- useless — show "parentdir/filename" to actually tell them apart.
    vim.api.nvim_set_hl(0, "HarpoonStatusActive", { link = "DiffText", default = true })

    -- Next.js app-router convention files carry no info in their name — the
    -- parent folder is the route. For those, show just the folder.
    local nextjs_files = {
      page = true,
      layout = true,
      route = true,
      loading = true,
      error = true,
      ["not-found"] = true,
      template = true,
      default = true,
      ["global-error"] = true,
    }

    -- Segments that carry no routing meaning on their own.
    local noise_roots = { app = true, src = true, [""] = true, ["."] = true }
    local function is_dynamic(seg) -- [slug], [...catchAll], (group)
      return seg:match("^%[.*%]$") ~= nil or seg:match("^%(.*%)$") ~= nil
    end
    local function strip_brackets(seg)
      return (seg:gsub("^[%[%(](.-)[%]%)]$", "%1"))
    end

    -- Build a contextual label: for convention files, walk up to the nearest
    -- real folder (skipping app/src and [dynamic]/(group) segments). Fall back
    -- to a bracket-stripped segment + the file's role, then to the role alone.
    local function harpoon_label(path)
      local parts = vim.split(path, "/", { plain = true })
      local n = #parts
      local file = parts[n] or path
      local stem = file:match("^(.*)%.[^.]+$") or file
      local conv = nextjs_files[stem]

      local strong, weak
      for i = n - 1, 1, -1 do
        local seg = parts[i]
        if not noise_roots[seg] then
          if is_dynamic(seg) then
            weak = weak or strip_brackets(seg)
          else
            strong = seg
            break
          end
        end
      end

      if conv then
        if strong then
          return strong
        elseif weak then
          return weak .. "/" .. stem
        end
        return stem
      end
      if strong then
        return strong .. "/" .. file
      end
      return file
    end

    local function harpoon_component()
      local ok, harpoon = pcall(require, "harpoon")
      if not ok then
        return ""
      end
      local items = harpoon:list().items or {}
      if #items == 0 then
        return ""
      end
      local cur = vim.fn.expand("%:.")
      local out = {}
      for i, it in ipairs(items) do
        if it.value and it.value ~= "" then
          local label = i .. " " .. harpoon_label(it.value)
          if it.value == cur then
            label = "%#HarpoonStatusActive#" .. label .. "%*"
          end
          out[#out + 1] = label
        end
      end
      return table.concat(out, "  ")
    end

    table.insert(s.lualine_c, { harpoon_component })
  end,
}
