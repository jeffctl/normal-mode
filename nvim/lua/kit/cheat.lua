-- Cheat sheet, the side panel. Space K toggles a slim split on the right with
-- every key and a short blurb, grouped in learner order. The file you are
-- working in stays visible, so you can try a key while you read it. q or Esc
-- closes it. Opened from the agenda, an org file, a capture or the file
-- tree, it scrolls straight to the keys for that place. Space ? is the
-- popup that narrows these same rows as you type (kit/cheatpick.lua).
--
-- Every org key below is orgmode's default (pack/kit/start/orgmode/lua/
-- orgmode/config/defaults.lua); every other key is set in init.lua.
local M = {}

-- the few rows that differ between Windows and macOS
local win = vim.fn.has('win32') == 1
local block_select = win and { 'Ctrl q', 'Block select (not Ctrl v)' } or { 'Ctrl v', 'Block select' }
local clipboard = win and 'Uses the Windows clipboard' or 'Uses the system clipboard'
local splits = vim.env.TMUX and 'Move between splits / panes' or 'Move between splits'
-- Ctrl + arrows never reach Neovim on a Mac (macOS Spaces / Mission
-- Control), and Alt k / Alt j exist on Windows only (see ARROW KEYS, init.lua)
local ctrl_arrows = win and { 'Ctrl + arrow', splits } or nil
local alt_jk = win and { 'Alt k / j', 'Same, if Alt arrows fail' } or nil
-- a Windows console never hands Neovim a Ctrl Space (see tick, init.lua)
local ctrl_space = not win and { 'Ctrl Space', 'Tick a checkbox, also typing' } or nil
-- When Ctrl s is the tmux prefix (your tmux.conf): one press waits for a
-- tmux key and the next key goes to tmux (d detaches). Pressed twice it
-- reaches Neovim (bind C-s send-prefix). Without that binding it never does.
local save_now = { 'Ctrl s', 'Save now' }
if vim.env.TMUX then
  local function tmux(...)
    local cmd = { 'tmux', ... }
    local ok, r = pcall(function() return vim.system(cmd, { text = true }):wait(1000) end)
    return ok and r.code == 0 and vim.trim(r.stdout or '') or nil
  end
  if tmux('show-options', '-gv', 'prefix') == 'C-s' then
    -- (list-keys with the key named prints nothing in tmux 3.7: read the table)
    local keys = tmux('list-keys', '-T', 'prefix') or ''
    save_now = keys:find('%sC%-s%s+send%-prefix') and { 'Ctrl s Ctrl s', 'Save now (tmux: press twice)' } or nil
  end
end

-- `where` marks a section as the one to jump to from that place (see place()).
-- Descriptions are short blurbs (28 columns fit the narrowest panel); a longer
-- one runs off the right edge and scrolls into view sideways.
local sections = {
  -- the mode bar (kit/mode.lua)
  { title = 'MODES (the bar at the bottom)', rows = {
    { 'NORMAL (blue)', 'Keys are commands' },
    { 'INSERT (green)', 'Typing text (i starts)' },
    { 'VISUAL (mauve)', 'Selecting (v / V start)' },
    { 'REPLACE (red)', 'Typing over text' },
    { 'COMMAND (peach)', 'Typing a : command' },
    { 'FIND (peach)', 'Typing narrows the list' },
    { 'Esc', 'Back to NORMAL, clear search' },
    { 'Space o ...', 'Waiting for more keys' },
    -- the key hint window (kit/clue.lua)
    { 'a pause', 'Hint lists the next keys' },
    { 'Esc (hint)', 'Cancel, nothing happens' },
    { 'Backspace (hint)', 'Take back one key' },
    { 'Enter (hint)', 'Run the key typed so far' },
    { 'Ctrl d / u (hint)', 'Scroll a long hint' },
    { '[+]', 'Not saved yet' },
  } },
  { title = 'AGENDA & NOTES', rows = {
    { 'Space o a d', 'Your day (home screen)' },
    { 'Space o a a', 'This week, Mon to Sun' },
    { 'Space o a t', 'Tasks, list by list' },
    { 'Space o a p', 'Tasks by priority, all files' },
    { 'Space o a c', 'Done, newest first' },
    { 'Space o a', 'Agenda menu (search, ...)' },
    { 'Space o c t', 'New task into inbox' },
    { 'Space o c s', 'New task with a start date' },
    { 'Space o c d', 'New task with a due date' },
    { 'Space o c n', 'New note into inbox' },
    { 'Space fo', 'Open an org file' },
    { 'g?', 'All org keys for this spot' },
  } },
  { title = 'FILES & EXPLORER', rows = {
    { 'Space ee', 'File tree on / off' },
    { 'Space ef', 'File tree at this file' },
    { 'Space ff', 'Find a file (this folder)' },
    { 'Space fb', 'Switch to an open file' },
    { 'Space pr', 'Recent files' },
    { 'Space fp', 'Copy this file path' },
  } },
  { title = 'IN A FINDER', rows = {
    { 'type', 'Narrow the list' },
    { 'Ctrl j / Ctrl k', 'Down / up (arrows too)' },
    { 'Enter', 'Open it' },
    { 'Esc', 'Close' },
  } },
  { title = 'MOVE & SEARCH', rows = {
    { 'Ctrl d / Ctrl u', 'Half page down / up' },
    { 'Shift Down / Up', 'Half page down / up' },
    { 'n / N', 'Next / prev match' },
    { 'Ctrl c', 'Clear search, leave insert' },
    { 'j / k', 'Down / up a screen line' },
  } },
  { title = 'EDITING', rows = {
    { 'J (visual)', 'Move lines down' },
    { 'K (visual)', 'Move lines up' },
    { 'J (normal)', 'Join the next line' },
    { 'gcc / gc', 'Comment line / selection' },
    { 'p (visual)', 'Paste over (copy stays)' },
    { 'Space d', 'Delete (not copied)' },
    { 'dd', 'Delete a line (copied)' },
    { 'x', 'Delete a char (not copied)' },
    { 'Space s Enter', 'Replace word everywhere' },
    { '< / >', 'Outdent / indent (visual)' },
    { 'Tab / Shift Tab', 'Indent / outdent (visual)' },
    { 'Shift Tab', 'Outdent while typing' },
    { 'Alt t', 'ISO time stamp (typing)' },
    { 'Alt w', 'Week, like W39 (typing)' },
    block_select,
    { 'Alt Up / Down', 'Move line or selection' },
    alt_jk,
  } },
  { title = 'SPLITS & WINDOWS', rows = {
    { 'Space sv', 'Split side by side' },
    { 'Space sh', 'Split stacked' },
    { 'Space se', 'Equal split sizes' },
    { 'Space sx', 'Close this split' },
    { 'Ctrl h/j/k/l', splits },
    { 'Space then arrow', splits },
    ctrl_arrows,
  } },
  { title = 'TABS', rows = {
    { 'Space to', 'New tab' },
    { 'Space tf', 'This file in a new tab' },
    { 'Space tn / tp', 'Next / prev tab' },
    { 'Space tx', 'Close this tab' },
  } },
  { title = 'SAVE & MISC', rows = {
    { '(nothing)', 'Autosave is on' },
    save_now,
    { 'y / p', clipboard },
    { 'u / Ctrl r', 'Undo / redo (kept)' },
    { 'F5', 'Spell check on / off' },
    { 'Space Space', 'Re-run this .lua file' },
    { 'Space re', 'Restart Neovim' },
    { ':h thing', 'Help for thing' },
    { 'Space ?', 'Find a key (type to narrow)' },
    { 'Space K', 'Keys panel (side)' },
  } },
  { title = 'IN THE AGENDA', where = 'agenda', rows = {
    { 'Enter', 'Open item / fold a list' },
    { 'Tab', 'Open item in a split' },
    { 'Shift Tab', 'Open / close all lists' },
    { 'o', 'Lists by file / by priority' },
    { 't', 'Change state: mark TODO/DONE' },
    { 'f / b', 'Next / prev day/week/month' },
    { '.', 'Back to today' },
    { 'vd / vw / vm', 'Day / week / month view' },
    { 'J', 'Jump to a date' },
    { 'Space o i s', 'Start date (SCHEDULED)' },
    { 'Space o i d', 'Set a deadline' },
    { '+ / -', 'Priority up / down' },
    { 'V then t / + / -', 'State / priority, all rows' },
    { 'V then Space o i s/d', 'Dates for all rows' },
    { 'V then Space o $', 'Archive all rows' },
    { 'Space o t', 'Set tags' },
    { 'Space o p s', 'Set START to now' },
    { 'Space o p p', 'Set a property' },
    { 'u / Ctrl r', 'Undo / redo t, +, dates...' },
    { '/', 'Filter: word, +tag' },
    { 'K', 'Peek at item' },
    { 'r', 'Refresh' },
    { 'I / O', 'Clock in / out' },
    { 'Space o r', 'Refile it' },
    { 'Space o $', 'Archive it' },
    { 'Space ee', 'File tree at org folder' },
    { 'g?', 'All agenda keys' },
    { 'q', 'Close (back to file)' },
  } },
  { title = 'READING THE AGENDA', rows = {
    { '10:00', 'At that time' },
    { 'due', 'Deadline today' },
    { 'in 3d', 'Deadline or start in 3 days' },
    { '3d ago', 'Past due by 3 days' },
    { '12d', 'Started 12 days ago (dim)' },
    { 'Started', 'Begun, no deadline yet' },
    { 'day 2/3', 'Day 2 of 3' },
    { 'd / s', 'Month: due / starts that day' },
    { '· A', 'Priority A (red = urgent)' },
    { 'To do (no date)', 'Tasks with no date' },
  } },
  { title = 'IN AN ORG FILE', where = 'org', rows = {
    { 'Tab', 'Fold / unfold task, drawer' },
    { 'Shift Tab', 'Fold / unfold all' },
    { 'cit', 'Change state: mark TODO/DONE' },
    { 'Space Enter', 'New heading / item below' },
    { 'Space o i t', 'New TODO below' },
    { 'Space o i h', 'New heading below' },
    { 'Space o i s', 'Start date (SCHEDULED)' },
    { 'Space o i d', 'Deadline (warns 14d ahead)' },
    { 'Space o i .', 'Date (an appointment)' },
    { 'Space o ,', 'Priority (A top, F low)' },
    { 'Space o t', 'Set tags' },
    { 'Space o p s', 'Set START to now' },
    { 'Space o p p', 'Set a property' },
    { '<< / >>', 'Promote / demote' },
    { '<s / >s', 'Same, with children' },
    { 'Space o K / J', 'Swap task with the next one' },
    { 'Alt Up / Down', 'Move a task or list item' },
    { 'Space o r', 'Refile under a heading' },
    { 'Space o $', 'Archive heading' },
    { 'Space x', 'Tick a checkbox (adds one)' },
    { 'Ctrl a / Ctrl x', 'Date under cursor up / down' },
    { 'Space o l i', 'Insert a link' },
    { 'Space o o', 'Open link / date' },
    { 'Space o x i / x o', 'Clock in / out' },
    { 'g?', 'All org keys' },
    { '-----', 'Line across (3+ dashes)' },
    ctrl_space,
  } },
  { title = 'WRITING A CAPTURE', where = 'capture', rows = {
    { '(next line)', 'Notes' },
    { 'Space o i s / d', 'Start / due date' },
    { 'Ctrl c', 'Save (twice if typing)' },
    { 'Space o r', 'Save under a heading' },
    { 'Space o k', 'Throw away (asks if typed)' },
  } },
  { title = 'IN THE FILE EXPLORER', where = 'explorer', rows = {
    { 'Enter', 'Open file / folder' },
    { 'Tab', 'Peek (tree keeps focus)' },
    { 'Ctrl v / Ctrl x', 'Open split: side / stacked' },
    { 'Backspace', 'Close the folder it is in' },
    { 'a', 'New (name/ makes a folder)' },
    { 'r', 'Rename' },
    { 'd', 'Delete (asks first)' },
    { 'x / c / p', 'Cut / copy / paste' },
    { 'y / Y', 'Copy name / relative path' },
    { '-', 'Up a folder' },
    { 'Ctrl ]', 'Make this folder the top' },
    { 'W / E', 'Fold / unfold all' },
    { 'f / F', 'Filter by name / clear' },
    { 'H', 'Show / hide dotfiles' },
    { 'R', 'Refresh' },
    { 'q', 'Close' },
    { 'g?', 'All tree keys' },
  } },
}

-- drop the rows this machine does not have (the nil ones above), wherever
-- they sit in a section, so the rows after them still show
for _, s in ipairs(sections) do
  local rows = {}
  for i = 1, table.maxn(s.rows) do
    if s.rows[i] then table.insert(rows, s.rows[i]) end
  end
  s.rows = rows
end

local KEY_W = 18
local ns = vim.api.nvim_create_namespace('kit_cheat')

-- Mocha: lavender title, blue sections, sapphire keys, overlay hints / notes
local function define_highlights()
  local set = vim.api.nvim_set_hl
  set(0, 'KitCheatTitle', { fg = '#b4befe', bold = true })
  set(0, 'KitCheatHint', { fg = '#7f849c' })
  set(0, 'KitCheatSection', { fg = '#89b4fa', bold = true })
  set(0, 'KitCheatKey', { fg = '#74c7ec' })
  set(0, 'KitCheatNote', { fg = '#7f849c' })
end

-- which section to scroll to, from the buffer Space ? was pressed in
local function place()
  if vim.b.org_capture then return 'capture' end
  local ft = vim.bo.filetype
  if ft == 'orgagenda' then return 'agenda' end
  if ft == 'org' then return 'org' end
  if ft == 'NvimTree' then return 'explorer' end
end

local function build(where)
  local lines, marks, jump = {}, {}, nil
  local function add(line, hl)
    table.insert(lines, line)
    if hl then
      table.insert(marks, { #lines - 1, 0, #line, hl })
    end
    return #lines - 1
  end

  add('')
  add('   Neovim keys (leader = Space)', 'KitCheatTitle')
  add('   "Space o a" = Space, o, a in turn', 'KitCheatHint')
  for _, s in ipairs(sections) do
    add('')
    local here = where ~= nil and s.where == where
    local r = add('  ' .. s.title .. (here and '  (you are here)' or ''))
    table.insert(marks, { r, 2, 2 + #s.title, 'KitCheatSection' })
    if here then
      table.insert(marks, { r, 2 + #s.title, #lines[r + 1], 'KitCheatNote' })
      jump = r + 1
    end
    for _, row in ipairs(s.rows) do
      local key, desc = row[1], row[2]
      -- a key as wide as its column ("V then Space o i s/d") gets a line of
      -- its own, and its blurb goes under the other blurbs
      if vim.api.nvim_strwidth(key) >= KEY_W then
        r = add('  ' .. key)
        table.insert(marks, { r, 2, 2 + #key, 'KitCheatKey' })
        key = ''
      end
      -- pad by screen width, not bytes ("· A" is 3 cells, 4 bytes)
      local gap = string.rep(' ', math.max(KEY_W - vim.api.nvim_strwidth(key), 0))
      r = add('  ' .. key .. gap .. desc)
      if key ~= '' then
        table.insert(marks, { r, 2, 2 + #key, 'KitCheatKey' })
      end
      local a, b = desc:find('%(.-%)')
      if a then
        local off = 2 + #key + #gap
        table.insert(marks, { r, off + a - 1, off + b, 'KitCheatNote' })
      end
    end
  end
  add('')
  return lines, marks, jump
end

local function close(win)
  if not pcall(vim.api.nvim_win_close, win, true) then
    -- it was the last window: leave an empty buffer rather than an error
    vim.api.nvim_win_call(win, function() vim.cmd.enew() end)
  end
end

-- the rows for `where` into the panel's buffer; the "you are here" row back
local function fill(buf, where)
  local lines, marks, jump = build(where)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  return jump
end

-- that row at the top of the panel
local function scroll(win, jump)
  if jump then
    vim.api.nvim_win_set_cursor(win, { jump, 0 })
    vim.api.nvim_win_call(win, function() vim.cmd('normal! zt') end)
  end
end

local function open()
  local where = place()
  define_highlights()

  local buf = vim.api.nvim_create_buf(false, true)
  local jump = fill(buf, where)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'kitcheat'

  -- a top-level split on the far right (past the file tree), so it also
  -- works from a floating window
  -- about a third of the screen (48 to 68 columns), so it can stay open out
  -- of the way; rows do not wrap, a long one scrolls sideways
  local width = math.max(48, math.min(68, math.floor(vim.o.columns / 3)))
  local from = vim.api.nvim_get_current_win()
  local win = vim.api.nvim_open_win(buf, true, { split = 'right', win = -1, width = width })
  local function wo(name, value)
    vim.api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
  wo('number', false)
  wo('relativenumber', false)
  -- rows never wrap: anything past the edge scrolls into view sideways
  -- (trackpad, or zl / zh)
  wo('wrap', false)
  wo('sidescrolloff', 0)
  wo('cursorline', false)
  wo('spell', false)
  wo('list', false)
  wo('winfixwidth', true)
  wo('signcolumn', 'no')
  wo('foldcolumn', '0')
  wo('scrolloff', 0) -- so the "you are here" section lands on the top line
  wo('statusline', ' keys   q closes   Space ? finds a key')

  -- q / Esc: back to the window you opened it from. (Neovim would pick the
  -- window beside it, which is the file, not the file tree you were in: the
  -- next key you pressed then typed into the file.)
  local function close_here()
    close(win)
    if vim.api.nvim_win_is_valid(from) then
      vim.api.nvim_set_current_win(from)
    end
  end
  vim.keymap.set('n', 'q', close_here, { buffer = buf, nowait = true, desc = 'Close the cheat sheet' })
  vim.keymap.set('n', '<Esc>', close_here, { buffer = buf, nowait = true, desc = 'Close the cheat sheet' })

  scroll(win, jump)

  -- a panel kept open follows you: into an org file, a capture, the file
  -- tree or the agenda, "(you are here)" moves to that section and the
  -- panel scrolls to it; anywhere else the marker goes. Popups (Space ?,
  -- hints) leave it be.
  local follow = vim.api.nvim_create_augroup('kit_cheat_follow_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'FileType' }, {
    group = follow,
    callback = function()
      vim.schedule(function()
        local cur = vim.api.nvim_get_current_win()
        if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_win_get_buf(cur) == buf
          or vim.api.nvim_win_get_config(cur).relative ~= '' then
          return
        end
        local now = place()
        if now == where then
          return
        end
        where = now
        local row = fill(buf, where)
        for _, w in ipairs(vim.fn.win_findbuf(buf)) do
          scroll(w, row)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = follow,
    buffer = buf,
    callback = function()
      vim.schedule(function() pcall(vim.api.nvim_del_augroup_by_id, follow) end)
    end,
  })
end

function M.toggle()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'kitcheat' then
      return close(win)
    end
  end
  open()
end

-- the rows as data, for kit/cheatpick.lua
M.sections = sections
-- and where Space ? was pressed (kit/cheatpick.lua puts that place first)
M.place = place

return M
