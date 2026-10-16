-- Wrapped prose and images share one layout. Native inline virtual text cannot
-- reserve rows inside a soft-wrapped source line, so render complete source rows
-- as virtual blocks and reveal the cursor's source row for editing.
local State = require("mathlive.state")
local Util = require("mathlive.util")
local Terminal = require("mathlive.image.terminal")
local Placeholders = require("mathlive.image.placeholders")
local Conceal = require("mathlive.conceal")
local Config = require("mathlive.config")
local M = {}
local windows = {}
local pending = false
local running = false
local legacy_ns = vim.api.nvim_create_namespace("mathlive.image")

function M.enabled(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.wo[win].wrap
    and Terminal.supported == true
    and vim.wo[win].conceallevel >= 2
    and vim.bo[buf].buftype == ""
    and vim.tbl_contains(Config.filetypes, vim.bo[buf].filetype)
    and State.placements[buf] ~= nil
    and vim.api.nvim__ns_set ~= nil
end

function M.legacy_windows()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not M.enabled(win) then
      wins[#wins + 1] = win
    end
  end
  return wins
end

local function chunk(line, text, hl)
  if text == "" then
    return
  end
  local last = line[#line]
  if last and last[2] == hl then
    last[1] = last[1] .. text
  else
    line[#line + 1] = { text, hl }
  end
end

-- Images are indivisible boxes; text wraps at words when 'linebreak' is set.
-- An overlong word still wraps at Unicode character boundaries.
function M.layout(atoms, width, linebreak, indent)
  width = math.max(1, width)
  indent = math.min(indent or 0, width - 1)
  local lines, row, used, continuation = {}, {}, 0, false
  local function flush()
    local height = 1
    for _, item in ipairs(row) do
      height = math.max(height, #item.atom.lines)
    end
    for y = 1, height do
      local line, col = {}, 0
      for _, item in ipairs(row) do
        chunk(line, string.rep(" ", item.col - col), "Normal")
        chunk(line, item.atom.lines[y] or string.rep(" ", item.atom.width), item.atom.hl)
        col = item.col + item.atom.width
      end
      lines[#lines + 1] = line
    end
    row, used, continuation = {}, indent, true
  end
  local function place(atom)
    if atom.tab then
      for _ = 1, atom.tab - used % atom.tab do
        place({ lines = { " " }, width = 1, hl = atom.hl, space = true })
      end
      return
    end
    if used + atom.width > width and #row > 0 then
      flush()
    end
    if #row == 0 and used + atom.width > width then
      used = 0
    end
    row[#row + 1] = { col = used, atom = atom }
    used = used + atom.width
  end
  local i = 1
  while i <= #atoms do
    local a = atoms[i]
    if a.image then
      place(a)
      i = i + 1
    elseif linebreak and not a.space then
      local stop, word_width = i, 0
      while stop <= #atoms and not atoms[stop].space and not atoms[stop].image do
        word_width = word_width + atoms[stop].width
        stop = stop + 1
      end
      if used + word_width > width and #row > 0 and word_width <= width - indent then
        flush()
      end
      for j = i, stop - 1 do
        place(atoms[j])
      end
      i = stop
    else
      if not (continuation and #row == 0 and a.space) then
        place(a)
      end
      i = i + 1
    end
  end
  if #row > 0 then
    flush()
  end
  return lines
end

local function release_image(image)
  Terminal.delete_placement(image.img, image.id)
  Terminal.delete_image(image.img)
  Util.del_hl(image.hl)
end

local function image_atom(p, width, ctx)
  local size = Util.pixels_to_cells(p.img.size)
  local scale =
    math.min(1, width / size.width, #Placeholders.diacritics / size.width, #Placeholders.diacritics / size.height)
  local w, h = math.max(1, math.floor(size.width * scale)), math.max(1, math.ceil(size.height * scale))
  local key = tostring(p.id)
  local image = ctx.images[key]
  if not image or image.source ~= p.img.id or image.width ~= w or image.height ~= h then
    if image then
      release_image(image)
    end
    local id = Terminal.generate_id()
    local img = Terminal.generate_id()
    image = { id = id, img = img, source = p.img.id, width = w, height = h, used = true }
    ctx.images[key] = image
    p.img:transmit(img, { id = id, width = w, height = h })
    image.hl = "MathLiveWrapImage" .. id
    Util.set_hl({ [image.hl] = { fg = img, sp = id, nocombine = true } })
    image.grid = Placeholders.grid({ width = w, height = h })
  end
  image.used = true
  return { image = true, width = w, lines = image.grid, hl = image.hl }
end

local function source_atoms(buf, row, text, placements, width, ctx)
  local atoms, col, index = {}, 0, 1
  local spans = Conceal.collect_ts_spans(buf, row)
  local marks = Conceal.collect_extmarks(buf, row)
  local signature = {
    text,
    width,
    vim.b[buf].changedtick,
    vim.bo[buf].tabstop,
    vim.treesitter.highlighter.active[buf] ~= nil,
    spans,
  }
  for _, item in ipairs(placements) do
    image_atom(item.placement, width, ctx)
    signature[#signature + 1] = { item.range, ctx.images[tostring(item.placement.id)].id }
  end
  for _, mark in ipairs(marks) do
    local d = mark.details
    if d.conceal or d.hl_group or (d.virt_text and d.virt_text_pos == "inline") then
      signature[#signature + 1] =
        { mark.col, d.end_row, d.end_col, d.conceal, d.hl_group, d.virt_text, d.virt_text_pos }
    end
  end
  local key = vim.inspect(signature)
  ctx.sources = ctx.sources or {}
  local cached = ctx.sources[row]
  if cached and cached.key == key then
    return cached.atoms
  end
  local hidden, virtual = {}, {}
  for _, span in ipairs(spans) do
    for c = span.start_col, math.min(#text, span.end_col) - 1 do
      hidden[c] = true
    end
  end
  for _, mark in ipairs(marks) do
    local d = mark.details
    if d.conceal and d.end_col then
      for c = mark.col, math.min(#text, d.end_col) - 1 do
        hidden[c] = true
      end
    end
    if d.virt_text and d.virt_text_pos == "inline" then
      virtual[mark.col] = d.virt_text
    end
  end
  local function append_text(value, hl)
    for _, cp in ipairs(vim.fn.str2list(value, true)) do
      local ch = vim.fn.nr2char(cp)
      local w = vim.fn.strdisplaywidth(ch)
      local tab = ch == "\t" and vim.bo[buf].tabstop or nil
      if tab then
        ch = string.rep(" ", tab)
        w = tab
      end
      if w == 0 and #atoms > 0 and not atoms[#atoms].image then
        atoms[#atoms].lines[1] = atoms[#atoms].lines[1] .. ch
      else
        atoms[#atoms + 1] =
          { lines = { ch }, width = w, hl = hl or "Normal", space = ch:match("^%s+$") ~= nil, tab = tab }
      end
    end
  end
  while col < #text do
    local item = placements[index]
    if item and col == item.range[2] then
      atoms[#atoms + 1] = image_atom(item.placement, width, ctx)
      col = item.range[4]
      index = index + 1
    else
      for _, v in ipairs(virtual[col] or {}) do
        append_text(v[1], v[2])
      end
      local ch = vim.fn.strcharpart(text:sub(col + 1), 0, 1)
      if not hidden[col] then
        local inspect = vim.inspect_pos(
          buf,
          row,
          col,
          { syntax = true, treesitter = true, semantic_tokens = false, extmarks = false }
        )
        local hl = {}
        for _, s in ipairs(inspect.syntax or {}) do
          hl[#hl + 1] = s.hl_group
        end
        for _, s in ipairs(inspect.treesitter or {}) do
          hl[#hl + 1] = s.hl_group
        end
        for _, mark in ipairs(marks) do
          local d = mark.details
          if d.hl_group and mark.col <= col and ((d.end_row or mark.row) > row or (d.end_col or 0) > col) then
            hl[#hl + 1] = d.hl_group
          end
        end
        append_text(ch, #hl > 0 and hl or "Normal")
      end
      col = col + #ch
    end
  end
  ctx.sources[row] = { key = key, atoms = atoms }
  return atoms
end

local function clear(ctx)
  if vim.api.nvim_buf_is_valid(ctx.buf) then
    vim.api.nvim_buf_clear_namespace(ctx.buf, ctx.ns, 0, -1)
  end
end

local function dispose(ctx)
  clear(ctx)
  for _, image in pairs(ctx.images) do
    release_image(image)
    Util.del_hl(image.hl)
  end
end

local function update(win, ctx)
  local buf = vim.api.nvim_win_get_buf(win)
  local view = vim.fn.winsaveview()
  clear(ctx)
  local width = math.max(1, vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(win)[1] - 1
  for _, image in pairs(ctx.images) do
    image.used = false
  end
  local by_row, display = {}, {}
  for _, entry in pairs(State.placements[buf] or {}) do
    local p = entry.placement
    local range = p and not p.closed and p:get_range()
    if range and p._grid then
      local image = ctx.images[tostring(p.id)]
      if image then
        image.used = true
      end
      if p.kind == "inline_formula" and range[1] == range[3] then
        local row = range[1]
        by_row[row] = by_row[row] or {}
        by_row[row][#by_row[row] + 1] = { placement = p, range = range }
      elseif p.kind == "displayed_equation" then
        display[range[1]] = { placement = p, range = range }
      end
    end
  end
  local blocks = {}
  local row = 0
  local visual = win == vim.api.nvim_get_current_win() and vim.fn.mode():match("[vV\22]")
  while row < #lines do
    local d = display[row]
    if d then
      if not visual and (cursor < row or cursor > d.range[3]) then
        local atom = image_atom(d.placement, width, ctx)
        blocks[#blocks + 1] = { first = row, last = d.range[3], lines = M.layout({ atom }, width, false) }
      end
      row = d.range[3] + 1
    else
      local ps = by_row[row]
      if ps and row ~= cursor and not visual then
        table.sort(ps, function(a, b)
          return a.range[2] < b.range[2]
        end)
        local atoms = source_atoms(buf, row, lines[row + 1], ps, width, ctx)
        local indent = vim.wo[win].breakindent and vim.fn.indent(row + 1) or 0
        blocks[#blocks + 1] = { first = row, last = row, lines = M.layout(atoms, width, vim.wo[win].linebreak, indent) }
      end
      row = row + 1
    end
  end
  local groups = {}
  for _, block in ipairs(blocks) do
    local prev = groups[#groups]
    if prev and prev.last + 1 == block.first then
      prev.last = block.last
      vim.list_extend(prev.lines, block.lines)
    else
      groups[#groups + 1] = block
    end
  end
  for _, g in ipairs(groups) do
    -- At EOF a single visible cursor row always provides an anchor. For a
    -- group starting at line zero, attach above the next unconcealed row.
    local anchor = g.first > 0 and g.first - 1 or g.last + 1
    if anchor < #lines then
      vim.api.nvim_buf_set_extmark(buf, ctx.ns, g.first, 0, {
        end_row = g.last,
        end_col = #lines[g.last + 1],
        conceal_lines = "",
        priority = 10000,
      })
      vim.api.nvim_buf_set_extmark(buf, ctx.ns, anchor, 0, {
        virt_lines = g.lines,
        virt_lines_above = g.first == 0,
        priority = 10000,
      })
      if view.topline - 1 >= g.first and view.topline - 1 <= g.last then
        view.topline = anchor + 1
        view.topfill = g.first == 0 and #g.lines or 0
        view.skipcol = 0
      end
    end
  end
  for key, image in pairs(ctx.images) do
    if not image.used then
      release_image(image)
      Util.del_hl(image.hl)
      ctx.images[key] = nil
    end
  end
  vim.fn.winrestview(view)
end

function M.refresh()
  if not vim.api.nvim__ns_set then
    return
  end
  if running then
    return
  end
  running = true
  local legacy = M.legacy_windows()
  vim.api.nvim__ns_set(legacy_ns, { wins = #legacy == #vim.api.nvim_list_wins() and {} or legacy })
  if #legacy == 0 then
    for buf in pairs(State.placements) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, legacy_ns, 0, -1)
      end
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if M.enabled(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local ctx = windows[win]
      if ctx and ctx.buf ~= buf then
        dispose(ctx)
        windows[win] = nil
        ctx = nil
      end
      if not ctx then
        ctx = { buf = buf, ns = vim.api.nvim_create_namespace("mathlive.wrap." .. win), images = {} }
        vim.api.nvim__ns_set(ctx.ns, { wins = { win } })
        windows[win] = ctx
      end
      local ok, err = pcall(vim.api.nvim_win_call, win, function()
        update(win, ctx)
      end)
      if not ok then
        running = false
        error(err)
      end
    end
  end
  for win, ctx in pairs(windows) do
    if not vim.api.nvim_win_is_valid(win) or not M.enabled(win) then
      dispose(ctx)
      windows[win] = nil
      if vim.api.nvim_win_is_valid(win) then
        for _, entry in pairs(State.placements[ctx.buf] or {}) do
          if entry.placement and not entry.placement.closed then
            entry.placement:render()
          end
        end
      end
    end
  end
  running = false
end

function M.request()
  if next(windows) == nil then
    local found = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if M.enabled(win) then
        found = true
        break
      end
    end
    if not found then
      return
    end
  end
  if pending then
    return
  end
  pending = true
  vim.defer_fn(function()
    pending = false
    M.refresh()
  end, 20)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("mathlive.wrap", { clear = true })
  vim.api.nvim_create_autocmd({
    "CursorMoved",
    "CursorMovedI",
    "TextChanged",
    "TextChangedI",
    "BufWinEnter",
    "WinEnter",
    "WinClosed",
    "WinResized",
    "VimResized",
    "ModeChanged",
    "ColorScheme",
  }, { group = group, callback = M.request })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = {
      "wrap",
      "linebreak",
      "breakindent",
      "conceallevel",
      "number",
      "relativenumber",
      "signcolumn",
      "tabstop",
    },
    callback = M.request,
  })
end
return M
