-- A text graph of a Rojo project's modules, walked one module at a time.
--
-- The module in the middle is the one you're on; on the left is everything that
-- uses it (requires it, starts it, fires a remote it listens to), on the right
-- everything it uses. Enter on a neighbour moves the middle to it, so the graph
-- is walked link by link. The line under the title says what the module under
-- the cursor does: its header comment, or the sentence codegraph's AI wrote.
--
-- The graph comes from ~/dotfiles/codegraph (graph.ts --json, run with bun in
-- the background), cached per project and fetched again after a script in it is
-- saved.

local M = {}

local SCRIPT = vim.fn.expand("~/dotfiles/codegraph/graph.ts")
local ns = vim.api.nvim_create_namespace("codegraph")
local cache = {}

local BOX_H = 4 -- top border, name, folder, bottom border
local CONN = 22 -- room between a side's boxes and the middle for a link's label
local MAX_BOX = 34
local KIND_ORDER = { starts = 1, remote = 2, require = 3 }

local function highlights()
  for name, link in pairs({
    CodeGraphCurrent = "Special",
    CodeGraphBox = "FloatBorder",
    CodeGraphName = "Function",
    CodeGraphTitle = "Title",
    CodeGraphWhere = "Comment",
    CodeGraphLine = "NonText",
    CodeGraphLabel = "Type",
    CodeGraphSelected = "Visual",
    CodeGraphHelp = "Comment",
    CodeGraphAbout = "Normal",
  }) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

local function bun()
  local path = vim.fn.exepath("bun")
  return path ~= "" and path or vim.fn.expand("~/.bun/bin/bun")
end

local function project_of(path)
  local found = vim.fs.find("sourcemap.json", { upward = true, path = vim.fs.dirname(path) })[1]
  return found and vim.fs.dirname(found) or nil
end

-- Scripts in a project changed: its graph is fetched again on next use.
vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = { "*.lua", "*.luau", "*.project.json" },
  callback = function(ev)
    local name = vim.api.nvim_buf_get_name(ev.buf)
    for root, c in pairs(cache) do
      if vim.startswith(name, root .. "/") then
        c.stale = true
      end
    end
  end,
})

local function index(graph, root)
  local c = { graph = graph, root = root, by_id = {}, incoming = {}, outgoing = {} }
  for _, n in ipairs(graph.nodes) do
    c.by_id[n.id] = n
  end
  for _, e in ipairs(graph.edges) do
    c.outgoing[e.source] = c.outgoing[e.source] or {}
    table.insert(c.outgoing[e.source], e)
    c.incoming[e.target] = c.incoming[e.target] or {}
    table.insert(c.incoming[e.target], e)
  end
  return c
end

local function load(root, done)
  local c = cache[root]
  if c and not c.stale then
    return done(c)
  end
  vim.system({ bun(), SCRIPT, root, "--json" }, { text = true }, function(res)
    vim.schedule(function()
      local ok, graph = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
      if res.code ~= 0 or not ok then
        return vim.notify("codegraph: couldn't read the project's graph\n" .. (res.stderr or ""), vim.log.levels.ERROR)
      end
      cache[root] = index(graph, root)
      done(cache[root])
    end)
  end)
end

-- ---------------------------------------------------------------- what a module is

local function where(c, id)
  local n = c.by_id[id]
  if not n or not n.parent then
    return ""
  end
  local parts = vim.split(n.parent, "/")
  return table.concat(vim.list_slice(parts, math.max(1, #parts - 1)), ".")
end

local function about(n)
  local text = n.doc and vim.split(n.doc, "\n%s*\n")[1] or n.purpose
  return text and vim.trim(text:gsub("%s*\n%s*", " ")) or nil
end

local function fit(text, width)
  if vim.fn.strchars(text) > width then
    return vim.fn.strcharpart(text, 0, width - 1) .. "…"
  end
  return text .. string.rep(" ", width - vim.fn.strchars(text))
end

local function wrap(text, width, max_lines)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    if line ~= "" and vim.fn.strchars(line) + 1 + vim.fn.strchars(word) > width then
      table.insert(lines, line)
      line = word
    else
      line = line == "" and word or (line .. " " .. word)
    end
  end
  if line ~= "" then
    table.insert(lines, line)
  end
  if #lines > max_lines then
    lines = vim.list_slice(lines, 1, max_lines)
    lines[max_lines] = fit(lines[max_lines], width):gsub("%s+$", "")
    if not lines[max_lines]:find("…$") then
      lines[max_lines] = lines[max_lines] .. " …"
    end
  end
  return lines
end

-- ---------------------------------------------------------------- canvas
--
-- Text goes into cells; lines are kept apart as which ways each cell joins
-- (up, down, left, right) and turned into box-drawing characters at the end,
-- so where a link meets a bus or another link the right junction comes out.

local U, D, L, R = 1, 2, 4, 8
local GLYPHS = {
  [U + D] = "│", [L + R] = "─", [D + R] = "┌", [D + L] = "┐", [U + R] = "└", [U + L] = "┘",
  [U + D + R] = "├", [U + D + L] = "┤", [D + L + R] = "┬", [U + L + R] = "┴", [U + D + L + R] = "┼",
  [U] = "│", [D] = "│", [L] = "─", [R] = "─",
}

local function canvas()
  return { cells = {}, joins = {}, hls = {}, height = 0, width = 0 }
end

local function chars(text)
  local out = {}
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = ch
  end
  return out
end

local function put(cv, row, col, text, hl)
  local list = chars(text)
  cv.cells[row] = cv.cells[row] or {}
  for i, ch in ipairs(list) do
    cv.cells[row][col + i - 1] = ch
  end
  cv.height = math.max(cv.height, row)
  cv.width = math.max(cv.width, col + #list - 1)
  if hl and #list > 0 then
    table.insert(cv.hls, { row = row, from = col, to = col + #list - 1, hl = hl })
  end
end

local function join(cv, row, col, bits)
  if bits == 0 then
    return
  end
  cv.joins[row] = cv.joins[row] or {}
  cv.joins[row][col] = bit.bor(cv.joins[row][col] or 0, bits)
  cv.height = math.max(cv.height, row)
  cv.width = math.max(cv.width, col)
end

local function hline(cv, row, from, to)
  local a, b = math.min(from, to), math.max(from, to)
  for col = a, b do
    join(cv, row, col, (col > a and L or 0) + (col < b and R or 0))
  end
end

local function vline(cv, col, from, to)
  local a, b = math.min(from, to), math.max(from, to)
  for row = a, b do
    join(cv, row, col, (row > a and U or 0) + (row < b and D or 0))
  end
end

-- Lines of text, and for each line the byte offset of every display column, so
-- highlights given in columns can be placed.
local function render(cv)
  local lines, offsets = {}, {}
  for row = 1, cv.height do
    local parts, cols, bytes = {}, {}, 0
    local line_from
    for col = 1, cv.width do
      local text = cv.cells[row] and cv.cells[row][col]
      local bits = cv.joins[row] and cv.joins[row][col]
      local ch = text or (bits and GLYPHS[bits]) or " "
      cols[col] = bytes
      parts[#parts + 1] = ch
      bytes = bytes + #ch
      if not text and bits then
        line_from = line_from or col
      elseif line_from then
        table.insert(cv.hls, { row = row, from = line_from, to = col - 1, hl = "CodeGraphLine" })
        line_from = nil
      end
    end
    if line_from then
      table.insert(cv.hls, { row = row, from = line_from, to = cv.width, hl = "CodeGraphLine" })
    end
    cols[cv.width + 1] = bytes
    lines[row] = (table.concat(parts):gsub("%s+$", ""))
    offsets[row] = cols
  end
  return lines, offsets
end

local function box(cv, top, left, width, name, folder, current)
  local b = current and { "╔", "╗", "╚", "╝", "═", "║" } or { "┌", "┐", "└", "┘", "─", "│" }
  local border = current and "CodeGraphCurrent" or "CodeGraphBox"
  put(cv, top, left, b[1] .. string.rep(b[5], width - 2) .. b[2], border)
  for i, row in ipairs({ { name, current and "CodeGraphTitle" or "CodeGraphName" }, { folder, "CodeGraphWhere" } }) do
    put(cv, top + i, left, b[6], border)
    put(cv, top + i, left + 1, " " .. fit(row[1], width - 4) .. " ")
    table.insert(cv.hls, { row = top + i, from = left + 2, to = left + 1 + math.min(vim.fn.strchars(row[1]), width - 4), hl = row[2] })
    put(cv, top + i, left + width - 1, b[6], border)
  end
  put(cv, top + 3, left, b[3] .. string.rep(b[5], width - 2) .. b[4], border)
end

-- ---------------------------------------------------------------- the view

local view = { buf = nil, win = nil, origin = nil, c = nil, current = nil, history = {}, boxes = {}, offsets = {}, info_row = 0 }

local function sides(c, id)
  local left, right = {}, {}
  for _, e in ipairs(c.incoming[id] or {}) do
    if e.source ~= id then
      table.insert(left, { id = e.source, kind = e.kind, label = e.label })
    end
  end
  for _, e in ipairs(c.outgoing[id] or {}) do
    if e.target ~= id then
      table.insert(right, { id = e.target, kind = e.kind, label = e.label })
    end
  end
  local order = function(x, y)
    if KIND_ORDER[x.kind] ~= KIND_ORDER[y.kind] then
      return KIND_ORDER[x.kind] < KIND_ORDER[y.kind]
    end
    return c.by_id[x.id].label < c.by_id[y.id].label
  end
  table.sort(left, order)
  table.sort(right, order)
  return left, right
end

local function link_label(link)
  if link.kind == "starts" then
    return "starts"
  elseif link.kind == "remote" then
    return "remote " .. (link.label or "")
  end
  return nil
end

local function side_width(c, list)
  local width = 16
  for _, item in ipairs(list) do
    width = math.max(width, vim.fn.strchars(c.by_id[item.id].label) + 4, vim.fn.strchars(where(c, item.id)) + 4)
  end
  return math.min(width, MAX_BOX)
end

local function draw(c, id, width)
  local cv = canvas()
  local n = c.by_id[id]
  local left, right = sides(c, id)
  view.boxes = {}

  put(cv, 1, 2, n.label, "CodeGraphTitle")
  put(cv, 1, 3 + vim.fn.strchars(n.label), "· " .. (n.parent or ""):gsub("/", ".") .. " · " .. n.className, "CodeGraphWhere")
  local row = 2
  for _, line in ipairs(wrap(about(n) or "No description yet.", width - 4, 3)) do
    put(cv, row, 2, line, "CodeGraphAbout")
    row = row + 1
  end
  put(cv, row, 2, "h/l side · j/k move · ⏎ go to it · o open file · u back · q close", "CodeGraphHelp")
  view.info_row = row + 1
  local titles = row + 3

  local lw, rw = side_width(c, left), side_width(c, right)
  local lx = 2
  local bus_l = lx + lw + CONN
  local cx = bus_l + 4
  local cw = math.max(vim.fn.strchars(n.label), vim.fn.strchars(where(c, id))) + 6
  local bus_r = cx + cw + 3
  local rx = bus_r + CONN
  local top = titles + 1
  local center_top = top + math.min(math.floor((math.max(#left, #right, 1) - 1) / 2), 3) * BOX_H
  local rc = center_top + 1

  put(cv, titles, lx, ("used by %d"):format(#left), "CodeGraphHelp")
  put(cv, titles, rx, ("uses %d"):format(#right), "CodeGraphHelp")

  box(cv, center_top, cx, cw, n.label, where(c, id), true)
  table.insert(view.boxes, { id = id, side = "center", top = center_top, bottom = center_top + 3, left = cx, right = cx + cw - 1 })

  if #left == 0 then
    put(cv, top + 1, lx, "nothing here uses it", "CodeGraphHelp")
  else
    local rows = { rc }
    for i, item in ipairs(left) do
      local t = top + (i - 1) * BOX_H
      box(cv, t, lx, lw, c.by_id[item.id].label, where(c, item.id))
      table.insert(view.boxes, { id = item.id, side = "left", link = item, top = t, bottom = t + 3, left = lx, right = lx + lw - 1 })
      hline(cv, t + 1, lx + lw, bus_l)
      local label = link_label(item)
      if label then
        put(cv, t + 1, lx + lw + 1, " " .. fit(label, CONN - 4):gsub("%s+$", "") .. " ", "CodeGraphLabel")
      end
      table.insert(rows, t + 1)
    end
    vline(cv, bus_l, math.min(unpack(rows)), math.max(unpack(rows)))
    hline(cv, rc, bus_l, cx - 2)
    put(cv, rc, cx - 1, "▶", "CodeGraphLine")
  end

  if #right == 0 then
    put(cv, top + 1, rx, "uses nothing here", "CodeGraphHelp")
  else
    local rows = { rc }
    hline(cv, rc, cx + cw, bus_r)
    for i, item in ipairs(right) do
      local t = top + (i - 1) * BOX_H
      box(cv, t, rx, rw, c.by_id[item.id].label, where(c, item.id))
      table.insert(view.boxes, { id = item.id, side = "right", link = item, top = t, bottom = t + 3, left = rx, right = rx + rw - 1 })
      hline(cv, t + 1, bus_r, rx - 2)
      put(cv, t + 1, rx - 1, "▶", "CodeGraphLine")
      local label = link_label(item)
      if label then
        put(cv, t + 1, bus_r + 2, " " .. fit(label, CONN - 5):gsub("%s+$", "") .. " ", "CodeGraphLabel")
      end
      table.insert(rows, t + 1)
    end
    vline(cv, bus_r, math.min(unpack(rows)), math.max(unpack(rows)))
  end

  -- A blank line kept for what the box under the cursor does.
  put(cv, view.info_row, 1, " ")
  return cv
end

local function box_at(row, col)
  for _, b in ipairs(view.boxes) do
    if row >= b.top and row <= b.bottom and col >= b.left and col <= b.right then
      return b
    end
  end
end

local function cursor_box()
  local row = vim.api.nvim_win_get_cursor(view.win)[1]
  return box_at(row, vim.fn.virtcol("."))
end

local function byte_col(row, col)
  local cols = view.offsets[row]
  return cols and (cols[col] or cols[#cols]) or 0
end

local function focus_box(b)
  if b then
    vim.api.nvim_win_set_cursor(view.win, { b.top + 1, byte_col(b.top + 1, b.left + 2) })
  end
end

local selected_ns = vim.api.nvim_create_namespace("codegraph_selected")

local function on_move()
  if not (view.buf and vim.api.nvim_buf_is_valid(view.buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(view.buf, selected_ns, 0, -1)
  local b = cursor_box()
  if not b then
    return
  end
  for row = b.top, b.bottom do
    local line = vim.api.nvim_buf_get_lines(view.buf, row - 1, row, false)[1] or ""
    local from = math.min(byte_col(row, b.left), #line)
    local to = math.min(byte_col(row, b.right + 1), #line)
    if to > from then
      vim.api.nvim_buf_set_extmark(view.buf, selected_ns, row - 1, from, { end_col = to, hl_group = "CodeGraphSelected", priority = 200 })
    end
  end
  -- The box under the cursor: its full link (a line only has room for the
  -- start of a remote's name) and what the module does.
  if b.side ~= "center" then
    local n = view.c.by_id[b.id]
    local link = link_label(b.link)
    local head = " ▸ " .. n.label .. (link and (" · " .. link) or "") .. ": "
    local text = about(n) or "No description yet."
    local room = vim.api.nvim_win_get_width(view.win) - vim.fn.strchars(head) - 2
    vim.api.nvim_buf_set_extmark(view.buf, selected_ns, view.info_row - 1, 0, {
      virt_text = { { head, "CodeGraphName" }, { (fit(text, math.max(10, room)):gsub("%s+$", "")), "CodeGraphHelp" } },
      virt_text_pos = "overlay",
    })
  end
end

local function show(id)
  local c = view.c
  view.current = id
  local width = vim.api.nvim_win_get_width(view.win)
  local cv = draw(c, id, width)
  local lines, offsets = render(cv)
  view.offsets = offsets
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
  for _, h in ipairs(cv.hls) do
    local line = lines[h.row] or ""
    local from = math.min(byte_col(h.row, h.from), #line)
    local to = math.min(byte_col(h.row, h.to + 1), #line)
    if to > from then
      vim.api.nvim_buf_set_extmark(view.buf, ns, h.row - 1, from, { end_col = to, hl_group = h.hl })
    end
  end
  vim.api.nvim_win_set_config(view.win, { title = " codegraph · " .. c.by_id[id].label .. " ", title_pos = "center" })
  for _, b in ipairs(view.boxes) do
    if b.side == "center" then
      focus_box(b)
    end
  end
  on_move()
end

local function go(id)
  if id == view.current then
    return
  end
  table.insert(view.history, view.current)
  show(id)
end

local function open_file(id)
  local n = view.c.by_id[id]
  if not (n and n.file) then
    return vim.notify("codegraph: " .. (n and n.label or id) .. " has no file", vim.log.levels.WARN)
  end
  local path = view.c.root .. "/" .. n.file
  local origin = view.origin
  vim.api.nvim_win_close(view.win, true)
  if origin and vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

-- Up and down stay in the column; left and right change column, landing on
-- the box nearest the row the cursor is on.
local function move(direction)
  local b = cursor_box()
  local row = vim.api.nvim_win_get_cursor(view.win)[1]
  local function column(side)
    return vim.tbl_filter(function(x)
      return x.side == side
    end, view.boxes)
  end
  local function nearest(list)
    local best
    for _, x in ipairs(list) do
      if not best or math.abs(x.top + 1 - row) < math.abs(best.top + 1 - row) then
        best = x
      end
    end
    return best
  end
  local side = b and b.side or "center"
  if direction == "h" or direction == "l" then
    local order = { "left", "center", "right" }
    local at = ({ left = 1, center = 2, right = 3 })[side]
    local step = direction == "h" and -1 or 1
    for i = at + step, direction == "h" and 1 or 3, step do
      local target = nearest(column(order[i]))
      if target then
        return focus_box(target)
      end
    end
    return
  end
  local list = column(side)
  local index = 1
  for i, x in ipairs(list) do
    if b and x.id == b.id and x.top == b.top then
      index = i
    end
  end
  focus_box(list[index + (direction == "j" and 1 or -1)])
end

local function keymaps(buf)
  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  for _, key in ipairs({ "h", "j", "k", "l" }) do
    map(key, function()
      move(key)
    end)
  end
  map("<Left>", function() move("h") end)
  map("<Right>", function() move("l") end)
  map("<Down>", function() move("j") end)
  map("<Up>", function() move("k") end)
  map("<CR>", function()
    local b = cursor_box()
    if not b or b.side == "center" then
      return open_file(view.current)
    end
    go(b.id)
  end)
  map("o", function()
    local b = cursor_box()
    open_file(b and b.id or view.current)
  end)
  local back = function()
    local previous = table.remove(view.history)
    if previous then
      show(previous)
    end
  end
  map("u", back)
  map("<BS>", back)
  map("q", function()
    vim.api.nvim_win_close(view.win, true)
  end)
  map("<Esc>", function()
    vim.api.nvim_win_close(view.win, true)
  end)
end

local function open_window(c, id, origin)
  highlights()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "codegraph"
  local width = math.floor(vim.o.columns * 0.92)
  local height = math.floor(vim.o.lines * 0.86)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  view = { buf = buf, win = win, origin = origin, c = c, current = nil, history = {}, boxes = {}, offsets = {}, info_row = 0 }
  keymaps(buf)
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = on_move })
  show(id)
end

local function scripts(c)
  local list = vim.tbl_filter(function(n)
    return n.kind == "script"
  end, c.graph.nodes)
  table.sort(list, function(a, b)
    return a.label < b.label
  end)
  return list
end

-- Opens on the module of the current file; anywhere else in the project, asks
-- which module to start from.
function M.open()
  local file = vim.api.nvim_buf_get_name(0)
  local root = project_of(file ~= "" and file or (vim.fn.getcwd() .. "/."))
  if not root then
    return vim.notify("codegraph: not in a Rojo project (no sourcemap.json above here)", vim.log.levels.WARN)
  end
  local origin = vim.api.nvim_get_current_win()
  load(root, function(c)
    local id = c.graph.files[file:sub(#root + 2)]
    if id and c.by_id[id] and c.by_id[id].kind == "script" then
      return open_window(c, id, origin)
    end
    vim.ui.select(scripts(c), {
      prompt = "Module",
      format_item = function(n)
        return n.label .. "  " .. (n.parent or ""):gsub("/", ".")
      end,
    }, function(choice)
      if choice then
        open_window(c, choice.id, origin)
      end
    end)
  end)
end

return M
