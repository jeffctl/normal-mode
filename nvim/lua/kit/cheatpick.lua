-- Space ?: find a key. A popup in the middle of the screen lists every row of
-- the cheat sheet (kit/cheat.lua) in three columns, group / key / what it
-- does. Type to narrow it: each word you type has to turn up, letters in
-- order, in one of the three columns ("spl" finds the split keys, "agenda
-- tab" the agenda's Tab), and a key's name ("ctrl s", "space d") puts that
-- key on top. When no row is left, one line says so.
-- Up / Down or Ctrl j / k move, the mouse
-- wheel scrolls, Shift Up / Down jump half a page (Alt Up / Down, which
-- move lines in a file, do nothing here). Enter or Esc closes it; nothing
-- runs. Opened in the agenda, an org file, a capture or the file tree, that
-- place's keys come first and the top line says where you are.
--
-- The rows are read from require('kit.cheat').sections each time it opens,
-- so a row added there shows up here too. Space K is the old side panel.
local M = {}

-- short names for the group column; a group not listed here gets its title
-- in lower case, without "in the" and anything after "&"
local LABELS = {
  ['MODES (the bar at the bottom)'] = 'modes',
  ['AGENDA & NOTES'] = 'notes',
  ['FILES & EXPLORER'] = 'files',
  ['IN A FINDER'] = 'finder',
  ['MOVE & SEARCH'] = 'move',
  ['EDITING'] = 'editing',
  ['SPLITS & WINDOWS'] = 'splits',
  ['TABS'] = 'tabs',
  ['SAVE & MISC'] = 'misc',
  ['IN THE AGENDA'] = 'agenda',
  ['READING THE AGENDA'] = 'agenda text',
  ['IN AN ORG FILE'] = 'org file',
  ['WRITING A CAPTURE'] = 'capture',
  ['IN THE FILE EXPLORER'] = 'file tree',
}

-- for the top line: "keys (you are in: the agenda)"
local HERE = {
  agenda = 'the agenda',
  org = 'an org file',
  capture = 'a capture',
  explorer = 'the file tree',
}

local KEY_MAX = 20 -- a longer key just pushes its row's text right

local ns = vim.api.nvim_create_namespace('kit_cheatpick')

-- Mocha, as in the side panel: sapphire keys, overlay groups and notes, the
-- group you are in blue
local function define_highlights()
  local set = vim.api.nvim_set_hl
  set(0, 'KitPickGroup', { fg = '#7f849c' })
  set(0, 'KitPickHere', { fg = '#89b4fa', bold = true })
  set(0, 'KitPickKey', { fg = '#74c7ec' })
  set(0, 'KitPickNote', { fg = '#7f849c' })
end

local function label(title)
  if LABELS[title] then return LABELS[title] end
  local t = title:lower():gsub('^in the ', ''):gsub('^in an? ', ''):gsub('%s*&.*$', '')
  return t
end

local function pad(s, w)
  return s .. string.rep(' ', math.max(w - vim.api.nvim_strwidth(s), 0))
end

-- the keys in a key column, split at " / " ("Ctrl d / Ctrl u" is "Ctrl d"
-- and "Ctrl u"), plus the whole column, each with its byte offset
local function alternatives(key)
  local alts = {}
  for at, part in (key .. ' / '):gmatch('()(.-) / ') do
    table.insert(alts, { at = at, s = part, lower = part:lower() })
  end
  if #alts > 1 then table.insert(alts, { at = 1, s = key, lower = key:lower() }) end
  return alts
end

-- every cheat row as an item, the place's own group first
local function build(where)
  local sections = require('kit.cheat').sections
  local ordered = {}
  for _, s in ipairs(sections) do
    if where and s.where == where then table.insert(ordered, s) end
  end
  for _, s in ipairs(sections) do
    if not (where and s.where == where) then table.insert(ordered, s) end
  end

  local group_w, key_w = 0, 0
  for _, s in ipairs(ordered) do
    group_w = math.max(group_w, vim.api.nvim_strwidth(label(s.title)))
    for _, row in ipairs(s.rows) do
      if type(row[1]) == 'string' then
        key_w = math.max(key_w, math.min(KEY_MAX, vim.api.nvim_strwidth(row[1])))
      end
    end
  end

  local items = {}
  for _, s in ipairs(ordered) do
    local group = label(s.title)
    for _, row in ipairs(s.rows) do
      local key, desc = row[1], row[2]
      if type(key) == 'string' and type(desc) == 'string' then
        local a = ' ' .. pad(group, group_w) .. '  '
        local b = pad(key, key_w) .. '  '
        table.insert(items, {
          text = a .. b .. desc,
          cols = { group, key, desc },
          lower = { group:lower(), key:lower(), desc:lower() },
          alts = alternatives(key),
          -- byte offset of each column in the line (0-based)
          offs = { 1, #a, #a + #b },
          here = where ~= nil and s.where == where,
        })
      end
    end
  end
  return items
end

-- The tightest run of `s` holding the letters of `t` in order (bytes): its
-- width and where each letter sits, or nil. From each start the earliest
-- next letter gives the shortest run; when one start runs out of text, every
-- later start does too.
local function fuzzy(s, t)
  local first = t:sub(1, 1)
  local best_w, best_pos
  local init = 1
  while true do
    local st = s:find(first, init, true)
    if not st then break end
    local pos, cur = { st }, st
    for j = 2, #t do
      cur = s:find(t:sub(j, j), cur + 1, true)
      if not cur then return best_w, best_pos end
      pos[j] = cur
    end
    local w = cur - st + 1
    if not best_w or w < best_w then best_w, best_pos = w, pos end
    if w == #t then break end
    init = st + 1
  end
  return best_w, best_pos
end

-- the typed words, and whether case counts (only with a capital, like
-- 'smartcase')
local function words(query)
  local prompt = table.concat(query)
  return vim.split(prompt, '%s+', { trimempty = true }), prompt:lower() ~= prompt
end

-- the best column for one word: its width, column number and letter spots.
-- On a tie the key, then what it does, then the group ("move line" is
-- about moving lines, not about the move group)
local function best_column(item, word, case)
  local cols = case and item.cols or item.lower
  local w_best, c_best, p_best
  for _, c in ipairs({ 2, 3, 1 }) do
    local w, pos = fuzzy(cols[c], word)
    if w and (not w_best or w < w_best) then w_best, c_best, p_best = w, c, pos end
  end
  return w_best, c_best, p_best
end

-- the word found whole there ("line" in "Move line or", not in "lines")
local function whole_word(s, word, pos)
  if not pos or pos[#pos] - pos[1] + 1 ~= #word then return false end
  local before, after = s:sub(pos[1] - 1, pos[1] - 1), s:sub(pos[#pos] + 1, pos[#pos] + 1)
  return not before:match('%w') and not after:match('%w')
end

-- the typed words as one key name ("ctrl s"), in lower case unless case counts
local function key_name(ws, case)
  local want = table.concat(ws, ' ')
  return case and want or want:lower()
end

-- Typed a key's name? 0 when it is the row's key (or one of its keys around
-- a " / "), 1 when one of them starts with it, nil otherwise; and the byte
-- in the key column where that key starts.
local function key_hit(item, want, case)
  if want == '' then return end
  local prefix
  for _, alt in ipairs(item.alts) do
    local s = case and alt.s or alt.lower
    if s == want then return 0, alt.at end
    if not prefix and s:sub(1, #want) == want then prefix = alt.at end
  end
  if prefix then return 1, prefix end
end

local function make_match(items)
  -- keep rows with every word. Rows whose key is what you typed come first,
  -- then rows whose key starts with it ("ctrl s" puts Ctrl s on top, "space
  -- s" Space s and then Space sv ...), then the tightest total, then the
  -- fewest words found only in the group name, then the fewest found inside
  -- a longer word ("move line": Alt Up / Down "Move line or selection"
  -- before J "Move lines down" and the move group's "screen line"), then
  -- sheet order (so the place you are in wins a tie)
  return function(_, inds, query)
    local ws, case = words(query)
    local want = key_name(ws, case)
    local keep = {}
    for _, i in ipairs(inds) do
      local total, in_group, partial = 0, 0, 0
      local cols = case and items[i].cols or items[i].lower
      for _, w in ipairs(ws) do
        w = case and w or w:lower()
        local width, c, pos = best_column(items[i], w, case)
        if not width then
          total = nil
          break
        end
        total = total + width
        in_group = in_group + (c == 1 and 1 or 0)
        partial = partial + (whole_word(cols[c], w, pos) and 0 or 1)
      end
      if total then table.insert(keep, { i, total, key_hit(items[i], want, case) or 2, in_group, partial }) end
    end
    table.sort(keep, function(a, b)
      if a[3] ~= b[3] then return a[3] < b[3] end
      if a[2] ~= b[2] then return a[2] < b[2] end
      if a[4] ~= b[4] then return a[4] < b[4] end
      if a[5] ~= b[5] then return a[5] < b[5] end
      return a[1] < b[1]
    end)
    return vim.tbl_map(function(k) return k[1] end, keep)
  end
end

local function mark(buf, row, from, to, hl, priority)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, from, { end_col = to, hl_group = hl, priority = priority })
end

local NO_MATCH = ' No key matches. Try one word.'

local function show(buf, shown, query)
  local lines = {}
  for i, item in ipairs(shown) do lines[i] = item.text end
  local ws, case = words(query)
  -- nothing left: say so, rather than an empty box
  if #shown == 0 and #ws > 0 then lines = { NO_MATCH } end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if #shown == 0 and #ws > 0 then mark(buf, 0, 0, #NO_MATCH, 'KitPickNote', 150) end
  local want = key_name(ws, case)
  for i, item in ipairs(shown) do
    local r, o = i - 1, item.offs
    mark(buf, r, o[1], o[1] + #item.cols[1], item.here and 'KitPickHere' or 'KitPickGroup', 150)
    mark(buf, r, o[2], o[2] + #item.cols[2], 'KitPickKey', 150)
    local a, b = item.cols[3]:find('%(.-%)')
    if a then mark(buf, r, o[3] + a - 1, o[3] + b, 'KitPickNote', 150) end
    -- the typed letters, where they matched (as mini.pick does); a key name
    -- lights up in the key column
    local hit, at = key_hit(item, want, case)
    if hit then
      mark(buf, r, o[2] + at - 1, o[2] + at - 1 + #want, 'MiniPickMatchRanges', 200)
    else
      for _, w in ipairs(ws) do
        local _, c, pos = best_column(item, case and w or w:lower(), case)
        for _, p in ipairs(pos or {}) do
          mark(buf, r, o[c] + p - 1, o[c] + p, 'MiniPickMatchRanges', 200)
        end
      end
    end
  end
end

-- move the highlighted row by n (clamped to the list)
local function move_by(n)
  local m = MiniPick.get_picker_matches()
  if not m or not m.all_inds or #m.all_inds == 0 then return end
  local at = 1
  for i, ind in ipairs(m.all_inds) do
    if ind == m.current_ind then
      at = i
      break
    end
  end
  local to = math.max(1, math.min(#m.all_inds, at + n))
  MiniPick.set_picker_match_inds({ m.all_inds[to] }, 'current')
end

local function half_page()
  local win = (MiniPick.get_picker_state() or {}).windows
  local ok, h = pcall(vim.api.nvim_win_get_height, win and win.main or -1)
  return math.max(1, math.floor((ok and h or 20) / 2))
end

-- a click on a row highlights it (a click outside closes the popup)
local function click()
  local m = MiniPick.get_picker_matches()
  local ind = m and m.shown_inds and m.shown_inds[vim.v.mouse_lnum]
  if ind then MiniPick.set_picker_match_inds({ ind }, 'current') end
end

-- about 80% of the screen, in the middle
local function win_config()
  local lines = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(lines * 0.8)
  return {
    relative = 'editor',
    anchor = 'NW',
    width = width,
    height = height,
    row = math.floor((lines - height - 2) / 2),
    col = math.floor((vim.o.columns - width - 2) / 2),
  }
end

function M.open()
  local cheat = require('kit.cheat')
  -- no mini.pick (it did not load): the side panel still shows every key
  if not _G.MiniPick then return cheat.toggle() end

  local where = cheat.place and cheat.place() or nil
  -- The mini.files explorer closes itself a second after something else
  -- takes the focus, and takes the focus back as it goes, which would shut
  -- the popup too. So close it first (it keeps your place) and open it again
  -- after. Only when Space ? was pressed inside it: any other explorer (a
  -- file tree) stays as it is, and no mini.files window appears.
  local reopen = false
  if vim.bo.filetype == 'minifiles' and _G.MiniFiles then
    local closed = MiniFiles.close()
    if closed == false then
      return -- kept unsaved explorer edits: stay in the explorer
    end
    reopen = closed == true
  end

  define_highlights()
  local items = build(where)
  local prompt = where and HERE[where] and ('keys (you are in: ' .. HERE[where] .. ') > ') or 'keys > '

  MiniPick.start({
    source = {
      items = items,
      name = 'type to narrow   Up / Down move   Esc closes',
      match = make_match(items),
      show = show,
      choose = function() end, -- Enter only closes
    },
    mappings = {
      -- nothing here opens a split, a tab, a preview or marks rows
      choose_in_split = '',
      choose_in_tabpage = '',
      choose_in_vsplit = '',
      choose_marked = '',
      mark = '',
      mark_all = '',
      refine = '',
      refine_marked = '',
      toggle_info = '',
      toggle_preview = '',
      kit_wheel_down = { char = '<ScrollWheelDown>', func = function() move_by(3) end },
      kit_wheel_up = { char = '<ScrollWheelUp>', func = function() move_by(-3) end },
      kit_half_down = { char = '<S-Down>', func = function() move_by(half_page()) end },
      kit_half_up = { char = '<S-Up>', func = function() move_by(-half_page()) end },
      kit_click = { char = '<LeftMouse>', func = click },
      -- any other key re-runs the search, which puts the highlight back on
      -- the first row; the rest of a click or a sideways scroll is not one
      kit_release = { char = '<LeftRelease>', func = function() end },
      kit_drag = { char = '<LeftDrag>', func = function() end },
      kit_double = { char = '<2-LeftMouse>', func = click },
      kit_wheel_left = { char = '<ScrollWheelLeft>', func = function() end },
      kit_wheel_right = { char = '<ScrollWheelRight>', func = function() end },
      -- Alt Up / Down move lines in a file (and Alt k / j on Windows); here
      -- they do nothing, rather than jump back to the first row
      kit_alt_up = { char = '<M-Up>', func = function() end },
      kit_alt_down = { char = '<M-Down>', func = function() end },
      kit_alt_k = { char = '<M-k>', func = function() end },
      kit_alt_j = { char = '<M-j>', func = function() end },
    },
    window = { config = win_config, prompt_prefix = prompt },
  })

  if reopen then pcall(MiniFiles.open, MiniFiles.get_latest_path()) end
end

return M
