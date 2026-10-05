-- ============================================================================
--  Normal Mode: a Neovim kit with an org-mode agenda, for people coming
--  from VS Code. The same config on Windows and macOS. Cheat sheet: Space
--  then ?
--
--  Windows: start it with nvim.cmd. That runs the Neovim bundled in this
--  repo with THIS folder as its config: nothing gets installed, no admin, no
--  PATH edits, no network. Mac: nvim.command does the same with the Mac
--  Neovim bundled here (no Homebrew). A plain `nvim` is the kit too when
--  ~/.config/nvim links to this folder. Plugins are vendored in
--  pack\kit\start and load on their own (Neovim's built-in packages); there
--  is no plugin manager.
--
--  Org mode needs a compiled tree-sitter parser and a locked-down machine
--  has no compiler, so prebuilt ones ship here: Windows in the orgmode
--  folder, Mac and Linux in org-parser\ (see the README). This file checks
--  the parser BEFORE orgmode starts. If it will not load, orgmode is skipped
--  and you are told why, instead of orgmode trying to download and compile a
--  new one.
--
--  An error in a Lua config stops the rest of the file, so keybindings come
--  first and every plugin is set up inside try(). Whatever goes wrong is
--  collected in `problems` and printed at startup as "nvim kit:" lines.
--  Silence means everything loaded.
-- ============================================================================

-- Neovim's own file browser (netrw) off, first thing: the file tree
-- (nvim-tree) replaces it, and its docs ask for this at the very start.
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

local problems = {}

local function note(msg)
  table.insert(problems, msg)
end

-- Run fn; record the failure and keep going.
local function try(label, fn)
  local ok, err = pcall(fn)
  if not ok then
    note(label .. ': ' .. tostring(err))
  end
  return ok
end

local is_win = vim.fn.has('win32') == 1

local function same_dir(a, b)
  a, b = vim.fs.normalize(a), vim.fs.normalize(b)
  if is_win then
    a, b = a:lower(), b:lower()
  end
  return a == b
end

-- Your org files: C:\Users\<you>\org on Windows (USERPROFILE rather than ~
-- on purpose: on some corporate machines ~ points at a network drive), ~/org
-- on a Mac. Change this line to keep them somewhere else.
local org_dir = vim.fs.normalize(vim.fs.joinpath(vim.env.USERPROFILE or vim.env.HOME, 'org'))

local config_dir = vim.fn.stdpath('config') -- the nvim folder
local kit_dir = vim.fs.dirname(vim.fs.normalize(config_dir)) -- the kit folder, where nvim.cmd lives

-- ============================================================================
--  KEYBINDINGS - first, so nothing further down can stop them registering
-- ============================================================================
vim.g.mapleader = ' '
vim.g.maplocalleader = '\\'

local map = vim.keymap.set

-- cheat sheet (kit/cheat.lua)
map('n', '<leader>?', function() require('kit.cheatpick').open() end, { desc = 'Find a key (type to narrow)' })
-- the same keys as a side panel that stays open (Space ? is the popup)
map('n', '<leader>K', function() require('kit.cheat').toggle() end, { desc = 'Keys panel (side)' })

-- finders: mini.pick when it loaded, built-in fallbacks otherwise, so these
-- keys always do something useful
local function pick()
  return package.loaded['mini.pick'] and _G.MiniPick
end

-- mini.pick picks git when git is installed, and git lists nothing outside a
-- repo (the org folder is not one), so only use it inside a repo
local function files_tool(cwd)
  if vim.fn.executable('rg') == 1 then return 'rg' end
  if vim.fn.executable('fd') == 1 then return 'fd' end
  if vim.fn.executable('git') == 1 and vim.fs.root(cwd, '.git') then return 'git' end
  return 'fallback'
end

local function find_files(cwd)
  cwd = cwd or vim.fn.getcwd()
  if pick() then
    MiniPick.builtin.files({ tool = files_tool(cwd) }, { source = { cwd = cwd } })
  else
    vim.api.nvim_feedkeys(':find *', 'n', false)
  end
end

map('n', '<leader>ff', function() find_files() end, { desc = 'Find a file (this folder)' })
map('n', '<leader>fo', function() find_files(org_dir) end, { desc = 'Find one of your org files' })
map('n', '<leader>fb', function()
  if pick() then MiniPick.builtin.buffers() else vim.api.nvim_feedkeys(':ls\r:b ', 'n', false) end
end, { desc = 'Jump to another open file' })
map('n', '<leader>pr', function()
  if not pick() then return vim.cmd('browse oldfiles') end
  local items = vim.tbl_filter(function(f) return vim.fn.filereadable(f) == 1 end, vim.v.oldfiles)
  MiniPick.start({ source = { items = items, name = 'Recent files' } })
end, { desc = 'Open a recent file' })

-- file tree (nvim-tree), a sidebar on the right. From the agenda it
-- opens on your org folder, wherever Neovim was started; elsewhere on the
-- current folder, folded the way you left it. If nvim-tree did not load (the
-- startup message says so), the old explorer, mini.files, stands in.
local tree_ok = false -- set once nvim-tree is set up (FILE TREE, below)

local function tree_home()
  if vim.bo.filetype == 'orgagenda' and vim.fn.isdirectory(org_dir) == 1 then
    return org_dir
  end
  return vim.fn.getcwd()
end

local function spare_explorer(path)
  if _G.MiniFiles then
    if MiniFiles.close() == nil then MiniFiles.open(path, false) end
  else
    vim.notify('nvim kit: the file tree did not load (see the nvim kit: lines at startup)', vim.log.levels.WARN)
  end
end

-- open the tree on `dir`; one already showing it keeps its open folders
local function tree_open(dir)
  local api = require('nvim-tree.api')
  local ok, core = pcall(require, 'nvim-tree.core')
  local root = ok and core.get_cwd and core.get_cwd()
  -- (the tree keeps the real path, links resolved)
  if root and same_dir(root, vim.uv.fs_realpath(dir) or dir) then
    api.tree.open()
  else
    api.tree.open({ path = dir })
  end
end

map('n', '<leader>ee', function()
  if not tree_ok then return spare_explorer(tree_home()) end
  local api = require('nvim-tree.api')
  if api.tree.is_visible() then
    return api.tree.close()
  end
  tree_open(tree_home())
end, { desc = 'Open / close the file tree' })
map('n', '<leader>ef', function()
  local file = vim.api.nvim_buf_get_name(0)
  local real_file = vim.fn.filereadable(file) == 1
  if not tree_ok then return spare_explorer(real_file and file or tree_home()) end
  if real_file then
    -- (a file outside the tree's folder moves the tree to the file's folder)
    require('nvim-tree.api').tree.find_file({ buf = file, open = true, focus = true, update_root = true })
  else
    tree_open(tree_home())
  end
end, { desc = 'File tree at this file' })

-- Space Space: re-run the .lua / .vim file you are editing (:so).
-- Anything else would be read as vim commands and error out.
map('n', '<leader><leader>', function()
  local ft = vim.bo.filetype
  if ft == 'lua' or ft == 'vim' then
    vim.cmd.source()
  else
    vim.notify('Space Space re-runs a .lua or .vim config file; this buffer is ' .. (ft ~= '' and ft or 'plain text'))
  end
end, { desc = 'Re-run this .lua / .vim file' })
-- restart! = fresh start, like closing and reopening. Plain :restart also
-- restores the session, which stacks a second copy of the startup agenda.
map('n', '<leader>re', '<cmd>restart!<CR>', { desc = 'Restart Neovim' })

-- exit insert + clear search highlight (C-c for both)
map('i', '<C-c>', '<Esc>', { desc = 'Leave insert mode' })
map('n', '<C-c>', '<cmd>nohlsearch<CR>', { desc = 'Clear search highlight' })

-- move selected lines; join lines with the cursor staying put
map('v', 'J', ":m '>+1<CR>gv=gv", { desc = 'Move selection down' })
map('v', 'K', ":m '<-2<CR>gv=gv", { desc = 'Move selection up' })
map('n', 'J', 'mzJ`z', { desc = 'Join the next line (cursor stays)' })

-- centered scrolling + search. (In an org file n / N are set again
-- with the same keys, plus folding the drawers passed: see DRAWERS.)
map('n', '<C-d>', '<C-d>zz', { desc = 'Half a page down, centered' })
map('n', '<C-u>', '<C-u>zz', { desc = 'Half a page up, centered' })
map('n', 'n', 'nzzzv', { desc = 'Next match, centered' })
map('n', 'N', 'Nzzzv', { desc = 'Previous match, centered' })

-- Shift Down / Shift Up: the same half page, centered, the arrow habit. Also
-- in org files: orgmode's own Shift Up / Down (the date under the cursor one
-- day on / back) is turned off in org_setup(); Ctrl a / Ctrl x still do that.
map({ 'n', 'x' }, '<S-Down>', '<C-d>zz', { desc = 'Half a page down' })
map({ 'n', 'x' }, '<S-Up>', '<C-u>zz', { desc = 'Half a page up' })

-- keep selection when indenting
map('v', '<', '<gv', { desc = 'Outdent, keep the selection' })
map('v', '>', '>gv', { desc = 'Indent, keep the selection' })

-- Shift Tab outdents like other editors: the line you are typing on (Vim's
-- own key for that is Ctrl d), or selected lines. Tab indents a selection.
-- (Normal mode Shift Tab is left alone: in org files it folds everything.)
map('i', '<S-Tab>', '<C-d>', { desc = 'Outdent this line' })

-- Stamps while typing (the VS Code habit). Alt t: full ISO 8601 time stamp
-- with the UTC offset, like 2026-09-25T21:52:08-07:00. Alt w: this ISO week,
-- like W39. Alt keys, because Windows Terminal keeps Ctrl+Shift+Space for its
-- new-tab menu; nothing claims Alt t / Alt w in Windows Terminal, Ghostty or
-- a stock tmux.
local function iso_now()
  local t = os.time()
  local utc = os.date('!*t', t)
  utc.isdst = os.date('*t', t).isdst -- so the offset is right in summer time too
  local off = os.difftime(t, os.time(utc))
  local sign = off < 0 and '-' or '+'
  off = math.abs(off)
  return os.date('%Y-%m-%dT%H:%M:%S', t)
    .. ('%s%02d:%02d'):format(sign, math.floor(off / 3600), math.floor(off % 3600 / 60))
end
map('i', '<M-t>', iso_now, { expr = true, desc = 'Insert an ISO time stamp' })
map('i', '<M-w>', function() return 'W' .. vim.fn.strftime('%V') end, { expr = true, desc = 'Insert this week, like W39' })
map('x', '<Tab>', '>gv', { desc = 'Indent selection' })
map('x', '<S-Tab>', '<gv', { desc = 'Outdent selection' })

-- paste/delete without clobbering the yank register
map('x', 'p', '"_dP', { desc = 'Paste over it (copy kept)' })
map({ 'n', 'v' }, '<leader>d', '"_d', { desc = 'Delete without copying' })
map('n', 'x', '"_x', { desc = 'Delete a letter (not copied)' })

-- replace the word under the cursor everywhere
map('n', '<leader>s', [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]], { desc = 'Replace word everywhere' })

-- splits and window moves
map('n', '<leader>sv', '<C-w>v', { desc = 'Split left | right' })
map('n', '<leader>sh', '<C-w>s', { desc = 'Split top / bottom' })
map('n', '<leader>se', '<C-w>=', { desc = 'Equal split sizes' })
map('n', '<leader>sx', '<cmd>close<CR>', { desc = 'Close this split' })
-- Ctrl h/j/k/l move between splits. Inside tmux, stepping off the edge
-- moves to the tmux pane beyond it, which is what vim-tmux-navigator on
-- the tmux side expects from the Neovim side.
local function nav(dir)
  local win = vim.api.nvim_get_current_win()
  vim.cmd.wincmd(dir)
  if vim.env.TMUX and win == vim.api.nvim_get_current_win() then
    vim.fn.system({ 'tmux', 'select-pane', '-' .. ({ h = 'L', j = 'D', k = 'U', l = 'R' })[dir] })
  end
end
map('n', '<C-h>', function() nav('h') end, { desc = 'Split / pane to the left' })
map('n', '<C-j>', function() nav('j') end, { desc = 'Split / pane below' })
map('n', '<C-k>', function() nav('k') end, { desc = 'Split / pane above' })
map('n', '<C-l>', function() nav('l') end, { desc = 'Split / pane to the right' })

-- tabs
map('n', '<leader>to', '<cmd>tabnew<CR>', { desc = 'New tab' })
map('n', '<leader>tx', '<cmd>tabclose<CR>', { desc = 'Close tab' })
map('n', '<leader>tn', '<cmd>tabnext<CR>', { desc = 'Next tab' })
map('n', '<leader>tp', '<cmd>tabprevious<CR>', { desc = 'Previous tab' })
map('n', '<leader>tf', '<cmd>tabnew %<CR>', { desc = 'This file in a new tab' })

-- copy file path to the clipboard
map('n', '<leader>fp', function()
  local path = vim.fn.expand('%:~')
  vim.fn.setreg('+', path)
  print('Copied: ' .. path)
end, { desc = 'Copy file path' })

-- --- kept from an earlier gVim setup ---
-- move by screen line on wrapped text, but a count (5j) still jumps real
-- lines so relative line numbers stay right
map({ 'n', 'x' }, 'j', "v:count == 0 ? 'gj' : 'j'", { expr = true, desc = 'Down a screen line' })
map({ 'n', 'x' }, 'k', "v:count == 0 ? 'gk' : 'k'", { expr = true, desc = 'Up a screen line' })
map('n', '<F5>', '<cmd>setlocal spell!<CR>', { desc = 'Toggle spell-check' })
map('n', '<C-s>', '<cmd>write<CR>', { desc = 'Save' })
map('i', '<C-s>', '<Esc><cmd>write<CR>', { desc = 'Save' })

-- ============================================================================
--  ARROW KEYS - the VS Code habits. The Vim keys above all still work.
--
--  Between splits: Ctrl + an arrow, or Space then an arrow. Same as Ctrl
--  h/j/k/l, stepping into the next tmux pane at the edge included. On a Mac
--  Ctrl + arrows never reach Neovim: macOS keeps them for Spaces and Mission
--  Control (System Settings > Keyboard > Keyboard Shortcuts), so there use
--  Space then an arrow. Windows Terminal binds no plain Ctrl + arrow.
--
--  Moving lines: Alt Up / Alt Down move what the cursor is on one line per
--  press, as in VS Code: it goes up or down one line, and the line it passes
--  takes its place. Selected lines move the same way. While typing you stay
--  typing; a selection stays selected. A count moves further (3 Alt Down),
--  one u undoes one press, and at the top or bottom nothing happens. Lines
--  keep the indent they had. A closed fold is one line: it moves as one and
--  is passed as one. (A folded task's fold reaches over the layout after
--  its text, see below; a line moving down stops above that, right under
--  the text.)
--  In an org file some lines only work together, so they stay together:
--    * A task's title with its SCHEDULED / DEADLINE line and drawers.
--      orgmode (and Emacs org-mode) read a date only right under the
--      title, and properties only in the drawer after it; a line put in
--      between turns them into plain text. So a moving line passes all of
--      them in one press, never stopping in between.
--    * On a task's title (or its date line, or its drawer) the task moves:
--      the title with its notes and lists, down to its last line of text.
--      Blank lines after it, and a rule (-----) or a "# Section" comment at
--      the left margin, are the file's layout and stay where they are.
--      Just the title line would leave its notes to the task above.
--    * On the first line of a list item the item moves, with its wrapped
--      lines and sub-items (the lines indented further).
--  Everything else is one line. A task moved up through the task above
--  passes that task's lines one press at a time; they sit under the moving
--  task until it is past, then the task above is in one piece again.
--  Two kinds of task still pass the whole task next to them at their level
--  in one press, as Space o K / J do for any task: a folded one (it is one
--  line on screen), and one with sub-tasks. The layout after them is not
--  theirs either: they pass a blank line, a rule or a "# Section" comment
--  one press at a time, like any task, and never carry one along.
--  Windows Terminal: Alt + arrows are its "move to the next pane" keys, but
--  when there is no pane to move to (a normal nvim.cmd window) it passes them
--  on to Neovim (microsoft/terminal PR 10806, July 2021). With Terminal panes
--  open, or an older Terminal, they never arrive, so on Windows Alt k / Alt j
--  do the same. (Alt Shift + arrows would not help: Terminal resizes panes
--  with those.)
-- ============================================================================
map('n', '<C-Left>', function() nav('h') end, { desc = 'Split / pane to the left' })
map('n', '<C-Down>', function() nav('j') end, { desc = 'Split / pane below' })
map('n', '<C-Up>', function() nav('k') end, { desc = 'Split / pane above' })
map('n', '<C-Right>', function() nav('l') end, { desc = 'Split / pane to the right' })
map('n', '<leader><Left>', function() nav('h') end, { desc = 'Split / pane to the left' })
map('n', '<leader><Down>', function() nav('j') end, { desc = 'Split / pane below' })
map('n', '<leader><Up>', function() nav('k') end, { desc = 'Split / pane above' })
map('n', '<leader><Right>', function() nav('l') end, { desc = 'Split / pane to the right' })

-- Org: the lines that belong right under a heading, before any notes: its
-- SCHEDULED / DEADLINE / CLOSED line, drawers (:PROPERTIES: ... :END:,
-- :LOGBOOK:) and a lone time stamp (a capture's "created" line). orgmode
-- (and Emacs org-mode) read a SCHEDULED or DEADLINE only right under the
-- heading, and properties only in the drawer after it; a line put in
-- between turns the date into plain text.
local function org_line(row)
  return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
end
local function is_org_heading(row)
  return org_line(row):match('^%*+%s') ~= nil
end
local function is_drawer_end(row)
  return org_line(row):match('^%s*:END:%s*$') ~= nil
end
local function is_drawer_start(row)
  return org_line(row):match('^%s*:[%w_%-]+:%s*$') ~= nil and not is_drawer_end(row)
end
-- the :END: of the drawer starting at `row`; nil when it has none before
-- the next heading (then it is no drawer)
local function drawer_end(row)
  for r = row + 1, vim.api.nvim_buf_line_count(0) do
    if is_drawer_end(r) then return r end
    if is_org_heading(r) then return nil end
  end
end
-- the last of the heading's own lines (the heading itself when it has none)
local function org_head_end(row)
  local last, total = row, vim.api.nvim_buf_line_count(0)
  while last < total do
    local r = last + 1
    local text = org_line(r)
    if is_drawer_start(r) then
      local e = drawer_end(r)
      if not e then break end
      last = e
    elseif text:match('^%s*SCHEDULED:') or text:match('^%s*DEADLINE:') or text:match('^%s*CLOSED:')
        or text:match('^%s*[<%[]%d%d%d%d%-%d%d%-%d%d[^%]>]*[%]>]%s*$') then
      last = r
    else
      break
    end
  end
  return last
end
-- A line on the move passes a heading with those lines, or a drawer, as one
-- piece, so it never lands inside it.
-- is `row` one of a heading's own lines, or inside a drawer?
local function in_org_piece(row)
  if is_drawer_end(row) then return true end
  local after_drawer = false
  for r = row - 1, 1, -1 do
    if is_org_heading(r) then
      return org_head_end(r) >= row
    elseif is_drawer_end(r) then
      after_drawer = true
    elseif is_drawer_start(r) and not after_drawer then
      return (drawer_end(r) or 0) >= row
    end
  end
  return false
end
-- the heading `row` is one of the own lines of (the title itself, its date
-- line, its drawers); nil on a note
local function org_head_of(row)
  for r = row, 1, -1 do
    if is_org_heading(r) then
      return (r == row or org_head_end(r) >= row) and r or nil
    end
  end
end

-- the drawer around `row`, for one that is not a heading's own (a :LOGBOOK:
-- further down in the notes): its first and last line
local function org_drawer_around(row)
  for r = row, 1, -1 do
    if is_org_heading(r) or (r < row and is_drawer_end(r)) then return nil end
    if is_drawer_start(r) then
      local e = drawer_end(r)
      if e and e >= row then return r, e end
      return nil
    end
  end
end

-- the piece `row` is in: (down) its last line, (up) its first. `row` itself
-- for a line on its own.
local function org_piece_end(row)
  local head = org_head_of(row)
  if head then return org_head_end(head) end
  local _, d_last = org_drawer_around(row)
  return d_last or row
end
local function org_piece_start(row)
  local head = org_head_of(row)
  if head then return head end
  local d_first = org_drawer_around(row)
  return d_first or row
end

-- Lines that lay a file out rather than belong to a task: blank lines, and
-- at the left margin a rule (a line of dashes) or a comment ("# Section").
local function is_org_layout(row)
  local text = org_line(row)
  return text:match('^%s*$') ~= nil or text:match('^%-%-%-+%s*$') ~= nil or text:match('^#%s') ~= nil or text == '#'
end

-- the last line of the task whose title is at `row` and whose last line
-- before the next heading is `tree_end`: layout after its text is not its
local function org_task_end(row, tree_end)
  local last = tree_end
  while last > row and is_org_layout(last) do
    last = last - 1
  end
  return math.max(last, org_head_end(row))
end

local function has_org_heading(first, last)
  for r = first, last do
    if is_org_heading(r) then return true end
  end
  return false
end

-- Move lines first..last by n steps (up when n < 0). A step is one line; a
-- closed fold on the way counts as one line, and in an org file so does a
-- heading with its dates and drawers (see above). The lines keep their
-- indent. Returns the new first line, or nil when there is nowhere to go.
local function move_block(first, last, n, pieces)
  -- the agenda, the cheat sheet and help can not be edited
  if not vim.bo.modifiable then
    vim.api.nvim_echo({ { 'Nothing to move: this view is read-only' } }, false, {})
    return nil
  end
  local is_org = vim.bo.filetype == 'org'
  -- (lines that are themselves inside a piece, a selected property say,
  -- move a line at a time: that is how one gets out. `pieces` is handed in
  -- by a press that repeats the one before: see last_move.)
  if pieces == nil then pieces = is_org and not in_org_piece(first) end
  local total = vim.api.nvim_buf_line_count(0)
  local dest -- :move puts the lines below this line (0 = the very top)
  if n > 0 then
    dest = last
    for _ = 1, n do
      if dest >= total then break end
      dest = dest + 1
      if pieces then dest = org_piece_end(dest) end
      local fold_start = vim.fn.foldclosed(dest)
      if fold_start ~= -1 then
        local fold_end = vim.fn.foldclosedend(dest)
        -- (right after a move a fold can be a line off for a moment)
        if pieces then fold_end = org_piece_end(fold_end) end
        -- A folded task's fold reaches to the next heading, over the
        -- layout after its text (blank lines, a rule, a "# Section"
        -- comment). The lines stop right under the text, and pass that
        -- layout a line at a time (a count): it is not the task's, and
        -- under it they would sit in the next section.
        local text_end = is_org and is_org_heading(fold_start) and org_task_end(fold_start, fold_end) or fold_end
        if dest <= text_end then dest = text_end end
      end
    end
    if dest == last then return nil end
  else
    -- What sits above a file's first heading (#+TITLE, #+TODO, a few words
    -- on what the file is) belongs to the file. A task does not go above
    -- such a line, where it would turn into the task's notes. (Blank
    -- lines, rules and "# Section" comments it does pass.)
    local file_lines = 0 -- the lines up to here are the file's own
    if is_org and has_org_heading(first, last) then
      file_lines = first - 1
      for r = 1, first - 1 do
        if is_org_heading(r) then
          file_lines = r - 1
          break
        end
      end
    end
    local above, stopped = first, false -- the lines go in front of `above`
    for _ = 1, -n do
      if above <= 1 then break end
      if above - 1 <= file_lines and not is_org_layout(above - 1) then
        stopped = true
        break
      end
      above = above - 1
      local fold_start = vim.fn.foldclosed(above)
      if fold_start ~= -1 then above = fold_start end
      if pieces then above = org_piece_start(above) end
    end
    if above == first then
      if stopped then
        vim.api.nvim_echo({ { 'Already the first task in the file' } }, false, {})
      end
      return nil
    end
    dest = above - 1
  end
  vim.cmd(('silent keepjumps %d,%dmove %d'):format(first, last, dest))
  local size = last - first + 1
  return n > 0 and dest - size + 1 or dest + 1
end

-- Org headings. The stars' count is the level: "** Task" is 2.
local function heading_level(row)
  local stars = vim.fn.getline(row):match('^(%*+)%s')
  return stars and #stars or nil
end

-- the last line under whatever sits at `row`, at `level`: the line before
-- the next heading at that level or higher (fewer stars), else the last line
local function subtree_end(row, level)
  local total = vim.api.nvim_buf_line_count(0)
  for r = row + 1, total do
    local l = heading_level(r)
    if l and l <= level then return r - 1 end
  end
  return total
end

-- a list item's first line: "- text", "+ text", "1. text", "1) text", and
-- "* text" when indented (at the margin that is a heading)
local function is_org_bullet(row)
  local text = org_line(row)
  return text:match('^%s*[-+]%s') ~= nil or text:match('^%s+%*%s') ~= nil or text:match('^%s*%d+[.)]%s') ~= nil
end

-- the last line of the list item starting at `row`: the lines right under
-- it that are indented further (its wrapped lines and sub-items)
local function org_item_end(row)
  local indent = #org_line(row):match('^%s*')
  local last = row
  for r = row + 1, vim.api.nvim_buf_line_count(0) do
    local text = org_line(r)
    if text:match('^%s*$') or #text:match('^%s*') <= indent then break end
    last = r
  end
  return last
end

-- What the last Alt Up / Down moved, for as long as nothing else changes
-- the file and the cursor stays where that press left it: the next press
-- moves the same lines, the same way. Worked out again they could come out
-- different. A task or list item that moved up has the line it passed right
-- under it, and that line would count as its own and ride along, out of
-- its place. A drawer moved up to a task's title would count as the
-- title's own, and the whole task would move.
-- A folded task that trades places keeps doing that too: its fold is back a
-- moment after the move, and a held key must not find it open in between
-- and start moving it a line at a time.
local last_move -- { buf, tick, at, first, last, pieces } or { buf, tick, at, swap = true, folded }
-- (and folded / fold_off: what was a closed fold, see move_line / move_selection)
-- How often the buffer's text has changed since this first looked.
-- (Neovim's own count, b:changedtick, goes up on every save as well, and
-- the kit saves by itself a second after a change.)
local text_ticks = {}
local function text_tick()
  local buf = vim.api.nvim_get_current_buf()
  if not text_ticks[buf] then
    text_ticks[buf] = 0
    local function changed()
      text_ticks[buf] = (text_ticks[buf] or 0) + 1
    end
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = changed,
      on_reload = changed,
      on_detach = function() text_ticks[buf] = nil end,
    })
  end
  return text_ticks[buf]
end
-- `at`: where that press left things: 'n' and the cursor's line, or 'v' and
-- the selection's first line
local function moved_again(at)
  local tick, m = text_tick(), last_move
  if m and m.buf == vim.api.nvim_get_current_buf() and m.tick == tick and m.at == at then
    return m
  end
end
local function remember_move(at, move)
  move.buf, move.tick, move.at = vim.api.nvim_get_current_buf(), text_tick(), at
  last_move = move
end

-- Lines first..last in an org file, starting on a heading: the whole
-- headings they cover (level, first, last). nil: plain lines (not org, not
-- on a heading). false: they reach past their parent, a heading with fewer
-- stars (Emacs refuses those too: "Cannot move past superior level").
local function org_headings(first, last)
  if vim.bo.filetype ~= 'org' then return nil end
  local level = heading_level(first)
  if not level then return nil end
  for r = first + 1, last do
    local l = heading_level(r)
    if l and l < level then return false end
  end
  return level, first, subtree_end(last, level)
end

local function past_parent()
  vim.api.nvim_echo({ { 'Not moved: the lines reach past their parent heading' } }, false, {})
end

-- :move lines first..last to below line `dest`, with folds off for it. A
-- folded task moves without the layout after its text, which its fold
-- reaches over: with folds on, Neovim widens a range inside a closed fold
-- to the whole fold, and the layout would ride along. With them off the
-- moved lines keep a fold of their own extent, closed as before, and what
-- stays behind falls out of it.
local function move_lines(first, last, dest)
  local folds = vim.wo.foldenable
  vim.wo.foldenable = false
  vim.cmd(('silent keepjumps %d,%dmove %d'):format(first, last, dest))
  vim.wo.foldenable = folds
end

-- Move the headings first..last (at `level`: a task's title through its
-- last line of text, sub-tasks included) n steps (up when n < 0). A step
-- passes what is next: a line of the layout (blank, a rule, a "# Section"
-- comment) on its own, or the whole task next to them at their level, its
-- title through its last line of text. Up, a folded task is passed whole
-- (it is one line on screen, and the layout hidden in its fold stays
-- under it); down, the lines stop right under its text, above that layout.
-- Stops at the parent heading. Returns the new first line, or nil when
-- there is nothing to pass (says so).
local function move_headings(level, first, last, n)
  if not vim.bo.modifiable then
    vim.api.nvim_echo({ { 'Nothing to move: this view is read-only' } }, false, {})
    return nil
  end
  local size = last - first + 1
  local moved = false
  for _ = 1, math.abs(n) do
    local dest -- :move puts the lines below this line
    if n > 0 then
      -- after the text: its layout, then a heading at its level or higher
      local next_row = last + 1
      if next_row > vim.api.nvim_buf_line_count(0) then break end
      if is_org_layout(next_row) then
        dest = next_row
      else
        if heading_level(next_row) ~= level then break end
        dest = org_task_end(next_row, subtree_end(next_row, level))
      end
    else
      local above = first - 1
      if above < 1 then break end
      local fold_start = vim.fn.foldclosed(above)
      if fold_start ~= -1 then above = fold_start end
      if is_org_layout(above) then
        dest = above - 1
      else
        local prev -- the heading above at this level; stop at the parent
        for r = above, 1, -1 do
          local l = heading_level(r)
          if l and l <= level then
            prev = l == level and r or nil
            break
          end
        end
        if not prev then break end
        dest = prev - 1
      end
    end
    move_lines(first, last, dest)
    first = n > 0 and dest - size + 1 or dest + 1
    last = first + size - 1
    moved = true
  end
  if not moved then
    local where = n > 0 and 'last' or 'first'
    vim.api.nvim_echo({ { ('Already the %s heading at this level'):format(where) } }, false, {})
    return nil
  end
  return first
end

local fold_ns = vim.api.nvim_create_namespace('kit_move_fold')

-- folds every drawer again, but the ones you opened (set in DRAWERS, below)
local fold_drawers
-- is tree-sitter still to look at some line? (set in DRAWERS, below)
local folds_pending

-- After a move, the line at `row`: `closed` (it was a closed fold) stays
-- closed, and any other line stays in sight. Org folds are worked out again
-- a moment after the move (tree-sitter, scheduled), and Neovim then hands
-- the open / closed state back by place, not by line: a moved fold can come
-- back open, a task moved next to a folded one can come back folded, and a
-- line moved to the end of a folded task would vanish into it. So this
-- looks again a few times; an extmark follows the line, and a later move (a
-- held key) takes over. Each look ends with the drawers folded again: what
-- it opens to keep the line in sight opens the drawers under it too.
-- The first look waits for tree-sitter (a few milliseconds, the scheduled
-- work runs meanwhile). Until it has looked, the moved lines have no level,
-- and Neovim counts them into the closed fold before them when the lines
-- after them still carry their old level: a task put right under a folded
-- task's text, above the layout its fold reaches over, is hidden in that
-- fold for the moment. Keeping it in sight then would open the folded task.
local settling -- the move whose line is being looked after
local function settle_fold(row, closed)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if vim.wo.foldmethod == 'expr' then vim.wait(50, function() return not folds_pending() end, 2) end
  -- The tasks the line is under now: a folded one opens. (By the headings
  -- above it, not by the folds: those only take the line in a moment later.)
  local level = vim.bo.filetype == 'org' and (heading_level(row) or math.huge) or 1
  for r = row - 1, 1, -1 do
    if level <= 1 then break end -- (a top-level task is under nothing)
    local l = heading_level(r)
    if l and l < level then
      if vim.fn.foldclosed(r) ~= -1 then vim.cmd(('silent! %dfoldopen!'):format(r)) end
      level = l
    end
  end
  local function fix(lnum)
    if not closed then
      if vim.fn.foldclosed(lnum) ~= -1 then vim.cmd(('silent! %dfoldopen!'):format(lnum)) end
      fold_drawers()
      return
    end
    -- in sight: a closed fold around it (it moved into a folded task) opens
    for _ = 1, 8 do
      local start = vim.fn.foldclosed(lnum)
      if start == -1 or start == lnum then break end
      vim.cmd(('silent! %dfoldopen'):format(lnum))
    end
    if vim.fn.foldclosed(lnum) == -1 and vim.fn.foldlevel(lnum) > 0 then
      vim.cmd(('silent! %dfoldclose'):format(lnum))
      -- (its own fold not there yet: that closed the one around it)
      if vim.fn.foldclosed(lnum) ~= lnum then vim.cmd(('silent! %dfoldopen'):format(lnum)) end
    end
    fold_drawers()
  end
  fix(row)
  vim.api.nvim_buf_clear_namespace(buf, fold_ns, 0, -1)
  local mark = vim.api.nvim_buf_set_extmark(buf, fold_ns, row - 1, 0, {})
  local this = {}
  settling = this
  local function look()
    if settling ~= this then return end
    local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, fold_ns, mark, {})
    if not (ok and pos[1] and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
      return
    end
    vim.api.nvim_win_call(win, function()
      fix(pos[1] + 1)
    end)
  end
  vim.schedule(look)
  for _, ms in ipairs({ 60, 250 }) do
    vim.defer_fn(look, ms)
  end
end

-- normal mode and while typing: the cursor stays on the same letter
local function move_line(dir)
  return function()
    local typing = vim.fn.mode() ~= 'n' -- insert (or replace) mode
    local n = typing and dir or vim.v.count1 * dir
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local first, last = row, row
    local folded = vim.fn.foldclosed(row) ~= -1
    if folded then
      first, last = vim.fn.foldclosed(row), vim.fn.foldclosedend(row)
    end
    local keep = first -- the cursor stays on this line (a closed fold: its first)
    local swap -- a level: whole headings trade places with the next at that level
    local pieces -- nil: move_block works it out
    local again = moved_again('n' .. row)
    if again and not again.swap then
      -- (and as open or as folded as it was: the fold may be wrong just now)
      first, last, pieces, keep, folded = again.first, again.last, again.pieces, row, again.folded
      -- (wrong, and closed over a line that was in sight, a folded drawer's
      -- fold grown by a line say: it opens, or :move would take the whole
      -- fold along)
      if not folded and vim.fn.foldclosed(row) ~= -1 then vim.cmd(('silent! %dfoldopen!'):format(row)) end
    elseif vim.bo.filetype == 'org' then
      local head = org_head_of(first)
      -- (a closed fold that does not start on a heading, but the cursor is on
      -- one: that heading. Right after a move, while tree-sitter has not yet
      -- worked the folds out again, a fold can be wrong for a moment.)
      if not head and folded and is_org_heading(row) then
        head, keep, last = row, row, row
      end
      if head then
        local level = heading_level(head)
        local tree_end = subtree_end(head, level)
        if (again and again.swap) or vim.fn.foldclosed(head) ~= -1 or has_org_heading(head + 1, tree_end) then
          -- folded, or with sub-tasks: past the whole task next to it (and
          -- without the layout after its text, even when its fold hides it)
          swap, first, last = level, head, org_task_end(head, tree_end)
          folded = folded or (again ~= nil and again.folded == true)
        else
          first, last = head, math.max(last, org_task_end(head, tree_end))
        end
      else
        local d_first, d_last = org_drawer_around(first)
        if d_first then
          first, last = d_first, math.max(last, d_last)
        elseif is_org_bullet(first) then
          last = math.max(last, org_item_end(first))
        end
      end
    end
    if pieces == nil and vim.bo.filetype == 'org' then pieces = not in_org_piece(first) end
    -- while typing, the move is its own undo step (setting undolevels to
    -- itself closes the one in progress; see :h undo-break)
    if typing then vim.cmd('let &g:undolevels = &g:undolevels') end
    local new_first
    if swap then
      new_first = move_headings(swap, first, last, n)
    else
      new_first = move_block(first, last, n, pieces)
    end
    if not new_first then return end
    if typing then vim.cmd('let &g:undolevels = &g:undolevels') end
    -- the cursor goes along, on the same line and letter
    local new_row = new_first + keep - first
    vim.api.nvim_win_set_cursor(0, { new_row, math.min(col, #vim.fn.getline(new_row)) })
    if swap then
      remember_move('n' .. new_row, { swap = true, folded = folded })
    else
      remember_move('n' .. new_row, {
        first = new_first, last = new_first + last - first, pieces = pieces, folded = folded,
      })
    end
    settle_fold(new_row, folded)
  end
end

-- visual mode: the same lines stay selected
local function move_selection(dir)
  return function()
    local n = vim.v.count1 * dir
    local cursor = vim.fn.line('.') -- (gv puts the cursor back at this end)
    local first, last = vim.fn.line('v'), cursor
    if first > last then first, last = last, first end
    -- starting on an org heading: whole headings (their folds are inside)
    local level, h_first, h_last = org_headings(first, last)
    if vim.fn.foldclosed(first) ~= -1 then first = vim.fn.foldclosed(first) end
    if vim.fn.foldclosedend(last) ~= -1 then last = vim.fn.foldclosedend(last) end
    if level == nil then
      level, h_first, h_last = org_headings(first, last)
    end
    if level == false then return past_parent() end
    local swap, pieces = false, nil
    -- The closed fold the cursor's end of the selection is on (a folded
    -- drawer, say), as a line of the block: it stays closed after the move,
    -- as the cursor's line does in normal mode (see settle_fold). Without
    -- that it came back open: gv puts the cursor on its last line, and the
    -- drawers pass leaves the drawer the cursor is inside alone.
    local fold_off = vim.fn.foldclosed(cursor) ~= -1 and vim.fn.foldclosed(cursor) - first or nil
    -- (a press that repeats the one before: the same lines, see last_move.
    -- And the same fold: right after a move it can be open for a moment.)
    local again = moved_again('v' .. first)
    fold_off = fold_off or (again and again.fold_off) or nil
    if again and not again.swap and again.last >= last then
      first, last, pieces = again.first, again.last, again.pieces
    elseif level then
      local last_head, whole = h_first, (again ~= nil and again.swap == true) or vim.fn.foldclosed(h_first) ~= -1
      for r = h_first + 1, h_last do
        local l = heading_level(r)
        if l then
          whole = whole or l ~= level or vim.fn.foldclosed(r) ~= -1
          if r <= last then last_head = r end
        end
      end
      if whole then
        -- folded, or with sub-tasks: past the whole task next to them (and
        -- without the layout after their text, even when a fold hides it)
        swap, first, last = true, h_first, org_task_end(h_first, h_last)
      else
        first, last = h_first, math.max(last, org_task_end(last_head, h_last))
      end
    elseif vim.bo.filetype == 'org' then
      -- plain lines: a title among them is not cut from its dates and drawers
      local head = org_head_of(last)
      if head and head >= first then last = math.max(last, org_head_end(head)) end
    end
    if pieces == nil and vim.bo.filetype == 'org' then pieces = not in_org_piece(first) end
    vim.cmd('normal! \27') -- leave visual; :move carries its marks along for gv
    local sel_last = vim.fn.line("'>")
    local new_first
    if swap then
      new_first = move_headings(level, first, last, n)
      if new_first then
        -- (the selection reached past the block, over the layout hidden in
        -- a folded task's fold: its end mark stayed there, and gv would take
        -- in what the block passed. It ends with the block.)
        if sel_last > last then vim.fn.setpos("'>", { 0, new_first + last - first, 1, 0 }) end
        remember_move('v' .. new_first, { swap = true, fold_off = fold_off })
      end
    else
      new_first = move_block(first, last, n, pieces)
      if new_first then
        remember_move('v' .. new_first, {
          first = new_first, last = new_first + last - first, pieces = pieces, fold_off = fold_off,
        })
      end
    end
    vim.cmd('normal! gv')
    -- (and with no closed fold in the selection, its first line stays in
    -- sight: put right under a folded task's text it can come back folded)
    if new_first then settle_fold(new_first + (fold_off or 0), fold_off ~= nil) end
  end
end

map({ 'n', 'i' }, '<M-Up>', move_line(-1), { desc = 'Move this line up' })
map({ 'n', 'i' }, '<M-Down>', move_line(1), { desc = 'Move this line down' })
map('x', '<M-Up>', move_selection(-1), { desc = 'Move the selected lines up' })
map('x', '<M-Down>', move_selection(1), { desc = 'Move the selected lines down' })
if is_win then
  map({ 'n', 'i' }, '<M-k>', move_line(-1), { desc = 'Move this line up' })
  map({ 'n', 'i' }, '<M-j>', move_line(1), { desc = 'Move this line down' })
  map('x', '<M-k>', move_selection(-1), { desc = 'Move the selected lines up' })
  map('x', '<M-j>', move_selection(1), { desc = 'Move the selected lines down' })
end
-- ============================================================================
--  (end of ARROW KEYS)
-- ============================================================================

-- ============================================================================
--  OPTIONS
-- ============================================================================
local o = vim.opt
o.termguicolors = true -- before orgmode: it only accepts hex keyword colors with this on
o.background = 'dark' -- set here: nvim.cmd turns off Neovim's terminal color probe
o.number = true
o.relativenumber = true
o.cursorline = true
o.signcolumn = 'yes'
o.wrap = true
o.linebreak = true
o.breakindent = true
-- a wrapped line breaks at a space, not inside ":tag:" (Vim's default
-- break characters include the colon, which split a tag over two lines)
o.breakat:remove(':')
o.scrolloff = 8
o.sidescrolloff = 8
o.ignorecase = true
o.smartcase = true
o.tabstop = 4
o.shiftwidth = 4
o.expandtab = true
o.smartindent = true
o.splitright = true
o.splitbelow = true
o.swapfile = false
o.undofile = true -- Neovim keeps undo history in its own state folder
o.mouse = 'a'
o.clipboard = 'unnamedplus' -- the Windows clipboard, via win32yank.exe next to nvim.exe
o.path:append('**') -- :find fallback searches subfolders
o.inccommand = 'split'
-- no stock "Nvim is open source" start screen: a plain launch shows your day,
-- or says why it cannot. Seeing that screen means Neovim started WITHOUT this
-- config (nvim.exe run directly instead of nvim.cmd).
o.shortmess:append('I')

local group = vim.api.nvim_create_augroup('kit', { clear = true })

vim.api.nvim_create_autocmd('TextYankPost', {
  group = group,
  callback = function() vim.hl.on_yank() end,
})

-- ConEmu only (the plain console is fine): it does not understand Neovim's
-- OSC 52 clipboard probe (ESC P ... ESC \), prints part of it and mis-reads
-- the cursor sequence after it, which leaves a stray "H" and draws the day
-- view from the wrong row. The kit copies through win32yank, so the probe
-- is off (:help g:termfeatures); termsync is off too (ConEmu has no
-- synchronized output), and the screen is redrawn once the day view is up.
if vim.env.ConEmuPID then
  local features = vim.g.termfeatures or {}
  features.osc52 = false
  vim.g.termfeatures = features
  o.termsync = false
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'orgagenda',
    once = true,
    callback = function()
      vim.defer_fn(function()
        -- not over a "Press ENTER" message or while typing
        if vim.api.nvim_get_mode().mode == 'n' then
          vim.cmd('mode') -- clears the screen and draws it again (:help :mode)
        end
      end, 300)
    end,
  })
end

-- ============================================================================
--  DRAWERS - in an org file a drawer (:PROPERTIES: ... :END:, :LOGBOOK:, a
--  :NOTE: of your own) stays folded, one line ending in "...", unless you
--  open it yourself: Tab on it opens it, Tab again closes it (on a line
--  inside it too, and the cursor goes to its first line). One you opened
--  stays open until you close it, press Shift Tab or open the file again.
--  Nothing else opens one: not opening the file, not Shift Tab (Show All
--  shows everything but the inside of drawers), not Tab on a task, not
--  orgmode writing or changing one (START on INPROGRESS, Space o p s /
--  Space o p p, a LOGBOOK entry), not Alt Up / Down, not u / Ctrl r.
--  A drawer you type by hand is left alone while you type. When you leave
--  insert mode inside it, and it has its :END:, it folds. n / N still open
--  the drawer a match is in (so do zo and the other z keys); that one folds
--  again at the next change or Tab, never while the cursor is inside it.
--  The folds themselves are orgmode's (tree-sitter, queries/org/folds.scm).
-- ============================================================================
-- Which drawers you opened: a mark on the first line of each. It follows
-- the line as the file changes and goes when the line is deleted.
local drawer_ns = vim.api.nvim_create_namespace('kit_drawer_open')

-- every drawer in the file: { first line, last line }
local function org_drawers()
  local found, row, total = {}, 1, vim.api.nvim_buf_line_count(0)
  while row <= total do
    local last = is_drawer_start(row) and drawer_end(row)
    if last then
      found[#found + 1] = { row, last }
      row = last -- (a property with no value, ":START:", starts no drawer in there)
    end
    row = row + 1
  end
  return found
end

-- Is tree-sitter still to look at some line? The lines a change or an undo
-- puts in have no fold level (-1) until it has, a moment later (see
-- settle_fold); the window's folds are not to be trusted until then.
-- (declared with settle_fold, above)
folds_pending = function()
  for l = 1, vim.api.nvim_buf_line_count(0) do
    if tostring(vim.treesitter.foldexpr(l)) == '-1' then return true end
  end
  return false
end

-- Fold the drawer on lines `row`..`last`: true when it folded. Only a fold
-- of exactly those lines will do. There can be none: inside a #+BEGIN
-- block a ":name:" line is plain text, and right after a change the folds
-- are not worked out yet, or are a line off (see settle_fold). And Neovim
-- can lose one for good after a move or an undo: tree-sitter has a fold
-- starting there, the window has none. Then, with `rebuild`, 'foldmethod'
-- is set again: even set to what it already is, that has the window's
-- folds worked out afresh, and open and closed ones stay as they are. Not
-- while tree-sitter still owes a level, though: the folds worked out then
-- would miss the lines it has not done yet, and a fold Neovim has to make
-- again comes out as open or closed as the fold before it. Then it is left
-- to the next look. The second value says whether the rebuild was tried
-- (done, or skipped for that): once per pass is enough.
local function close_drawer(row, last, rebuild)
  if not tostring(vim.treesitter.foldexpr(row)):find('^>') then return false end
  for try = 1, rebuild and 2 or 1 do
    if try == 2 then
      if folds_pending() then return false, true end
      vim.wo.foldmethod = 'expr'
    end
    if vim.fn.foldlevel(row) > 0 then
      vim.cmd(('silent! %dfoldclose'):format(row))
      if vim.fn.foldclosed(row) == row and vim.fn.foldclosedend(row) == last then return true, try == 2 end
      -- (that closed another fold, the one around it say: open it again)
      if vim.fn.foldclosed(row) ~= -1 then vim.cmd(('silent! %dfoldopen'):format(row)) end
    end
  end
  return false, rebuild
end

-- In this window: every drawer folds, but the ones you opened (those open
-- again, should a change have folded them) and the one the cursor is
-- inside: nothing folds under the cursor. With `force` (Shift Tab, leaving
-- insert mode, u / Ctrl r) that one folds too, and the cursor goes to its
-- first line. Never while you type: Neovim works out no folds then, and
-- leaving insert mode does it.
fold_drawers = function(force)
  if vim.bo.filetype ~= 'org' or not vim.wo.foldenable or vim.wo.foldmethod ~= 'expr' then return end
  if vim.api.nvim_get_mode().mode:match('^[iR]') then return end
  local buf = vim.api.nvim_get_current_buf()
  local opened = {} -- first line -> its mark
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, drawer_ns, 0, -1, {})) do
    opened[m[2] + 1] = m[1]
  end
  local cursor = vim.fn.line('.')
  local rebuild = true -- (once is enough: it does the whole window)
  for _, d in ipairs(org_drawers()) do
    local first, last = d[1], d[2]
    local closed = vim.fn.foldclosed(first)
    if opened[first] then
      opened[first] = nil
      if closed == first then vim.cmd(('silent! %dfoldopen'):format(first)) end
    elseif closed == -1 then
      local inside = cursor > first and cursor <= last
      if force or not inside then
        local folded, rebuilt = close_drawer(first, last, rebuild)
        rebuild = rebuild and not rebuilt
        if folded and inside then vim.fn.cursor(first, 1) end
      end
    end
  end
  -- a mark left over: its line is no drawer's first line any more
  for _, id in pairs(opened) do
    vim.api.nvim_buf_del_extmark(buf, drawer_ns, id)
  end
end

-- the same in every window that shows `buf`
local function fold_drawers_in(buf, force)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    -- (not orgmode's hidden edit window, a float: see the agenda's keys)
    if vim.api.nvim_win_get_config(win).relative == '' then
      vim.api.nvim_win_call(win, function() fold_drawers(force) end)
    end
  end
end

-- Now, and twice more a moment later: after a change the folds are worked
-- out again in their own time (see settle_fold), and a drawer can come back
-- open then. A later change takes over. The later looks keep `force` as
-- long as the cursor has not moved since: right after u the lines it put
-- back have no folds yet, so the first look can not fold the drawer the
-- cursor landed in. (Moved since, the cursor is where you put it: a search
-- that lands in a drawer shows its match, u just before or not.)
local looking -- the change being looked after
local function fold_drawers_soon(buf, force)
  fold_drawers_in(buf, force)
  local win, at = vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0)
  local this = {}
  looking = this
  for _, ms in ipairs({ 60, 250 }) do
    vim.defer_fn(function()
      if looking ~= this then return end
      local still = force and vim.api.nvim_get_current_win() == win
        and vim.deep_equal(vim.api.nvim_win_get_cursor(0), at)
      fold_drawers_in(buf, still)
    end, ms)
  end
end

-- Any change to an org file folds its drawers again, whoever made it: you,
-- orgmode, a key in the agenda while the file shows in a split. After u or
-- Ctrl r that is also the drawer the cursor landed in (Vim opens the folds
-- there), so taking a change back never leaves one open.
local watched = {} -- buf -> its change number: { nr = the last seen, top = the highest }
local function watch_drawers(buf)
  -- (a file opened again, with :e, starts with every drawer folded)
  vim.api.nvim_buf_clear_namespace(buf, drawer_ns, 0, -1)
  if watched[buf] then return end
  local w = { nr = vim.api.nvim_buf_call(buf, vim.fn.changenr) }
  w.top = w.nr
  watched[buf] = w
  local function changed()
    if w.queued then return end
    w.queued = true
    vim.schedule(function()
      w.queued = false
      if not vim.api.nvim_buf_is_valid(buf) then return end
      -- u / Ctrl r: the change number went back, or on to one it had before
      local nr = vim.api.nvim_buf_call(buf, vim.fn.changenr)
      local undone = nr < w.nr or (nr > w.nr and nr <= w.top)
      w.nr, w.top = nr, math.max(w.top, nr)
      -- (typing: nothing to do until insert mode is left)
      if not vim.api.nvim_get_mode().mode:match('^[iR]') then fold_drawers_soon(buf, undone) end
    end)
  end
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = changed,
    on_reload = changed,
    on_detach = function() watched[buf] = nil end,
  })
end

-- A file as it opens or comes back into a window. (Scheduled: orgmode turns
-- its folds on in its own setup, which runs after this.)
vim.api.nvim_create_autocmd('BufWinEnter', {
  group = group,
  callback = function(ev)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(ev.buf) and vim.bo[ev.buf].filetype == 'org' then fold_drawers_soon(ev.buf) end
    end)
  end,
})

-- Tab in an org file. On a drawer (its first line, folded or not, or a line
-- inside an open one) just that drawer opens or closes. Anywhere else it is
-- orgmode's own Tab, which folds and unfolds the task: the drawers that
-- opens fold again.
local function org_tab()
  local row = vim.fn.line('.')
  local closed = vim.fn.foldclosed(row)
  for _, d in ipairs(vim.wo.foldenable and org_drawers() or {}) do
    local first, last = d[1], d[2]
    if closed == first then
      -- folded: open it, and mark it as one you opened
      vim.cmd(('silent! %dfoldopen'):format(first))
      vim.api.nvim_buf_clear_namespace(0, drawer_ns, first - 1, first)
      vim.api.nvim_buf_set_extmark(0, drawer_ns, first - 1, 0, { invalidate = true, undo_restore = false })
      return
    end
    if closed == -1 and row >= first and row <= last then
      if not close_drawer(first, last, true) then break end -- (no fold of its own: orgmode's Tab)
      vim.api.nvim_buf_clear_namespace(0, drawer_ns, first - 1, first)
      if row ~= first then vim.fn.cursor(first, 1) end
      return
    end
  end
  require('orgmode').action('org_mappings.cycle')
  fold_drawers()
end

-- Shift Tab: orgmode's own (Overview, Contents, Show All), and in all three
-- every drawer is folded, the ones you opened too
local function org_shift_tab()
  vim.api.nvim_buf_clear_namespace(0, drawer_ns, 0, -1)
  require('orgmode').action('org_mappings.global_cycle')
  fold_drawers(true)
end
-- ============================================================================
--  (end of DRAWERS)
-- ============================================================================

-- ============================================================================
--  AUTOSAVE, like VS Code's: a changed file is written when you leave insert
--  mode, a moment after you pause (typing or not), and when you switch files,
--  windows or away from Neovim. Only real files: not the agenda, the cheat
--  sheet, the file tree, or orgmode's capture / note windows (those live
--  in Neovim's temp folder, and orgmode uses "unsaved" there to ask before
--  throwing a capture away). A save that fails says so. Undo history is kept
--  across saves and restarts (u / Ctrl r), so an autosave is never final.
-- ============================================================================
-- real paths: on macOS the temp folder is reached through a link
-- (/var -> /private/var), and the two spellings must compare equal
local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end
local tmp_dir = real(vim.fn.fnamemodify(vim.fn.tempname(), ':h'))

local function autosave(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local bo = vim.bo[buf]
  if not bo.modified or bo.buftype ~= '' or not bo.modifiable or bo.readonly or vim.b[buf].org_capture then return end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or real(vim.fn.fnamemodify(name, ':h')):find(tmp_dir, 1, true) == 1 then return end
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function() vim.cmd('silent update') end)
  if not ok then
    -- just the E123: line, not the Lua traceback around it
    local why = tostring(err):match('(E%d+:[^\n]*)') or tostring(err):match('^[^\n]*')
    vim.notify('Not saved: ' .. vim.fn.fnamemodify(name, ':~:.') .. '  (' .. why .. ')', vim.log.levels.WARN)
  end
end

local save_timer = vim.uv.new_timer()
local function autosave_soon(buf, ms)
  save_timer:stop()
  save_timer:start(ms, 0, vim.schedule_wrap(function() autosave(buf) end))
end

vim.api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave', 'WinLeave' }, {
  group = group,
  callback = function(ev) autosave(ev.buf) end,
})
vim.api.nvim_create_autocmd('FocusLost', {
  group = group,
  callback = function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      autosave(buf)
    end
  end,
})
vim.api.nvim_create_autocmd('TextChanged', {
  group = group,
  callback = function(ev) autosave_soon(ev.buf, 1000) end,
})
vim.api.nvim_create_autocmd('TextChangedI', {
  group = group,
  callback = function(ev) autosave_soon(ev.buf, 2000) end,
})
-- org files: the line you were typing on stays in view after Esc. A note
-- typed with o under a heading that had none (the last under its parent)
-- turns that heading into a fold, which Neovim closes over the new line
-- (tree-sitter re-folds after InsertLeave, so this waits a moment). Typed
-- inside a drawer, the drawer folds and its first line stays in view (see
-- DRAWERS).
vim.api.nvim_create_autocmd('InsertLeave', {
  group = group,
  callback = function(ev)
    if vim.bo[ev.buf].filetype ~= 'org' then return end
    local win = vim.api.nvim_get_current_win()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == ev.buf then
        vim.api.nvim_win_call(win, function()
          if vim.fn.foldclosed('.') ~= -1 then vim.cmd('normal! zv') end
          fold_drawers(true)
        end)
        fold_drawers_soon(ev.buf)
      end
    end)
  end,
})
-- and pick up changes made elsewhere (a sync tool, another program) when
-- you come back to Neovim or to a file you have not touched
vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter' }, {
  group = group,
  callback = function() pcall(vim.cmd.checktime) end,
})

vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = { 'markdown', 'text', 'gitcommit' },
  callback = function()
    vim.opt_local.spell = true
    vim.opt_local.spelllang = 'en_us'
  end,
})

-- Org files are saved with plain LF line endings, Windows too. New files on
-- Windows would otherwise get CRLF, and orgmode reads a CRLF file it has not
-- opened with a blank line after every line: SCHEDULED / DEADLINE then stop
-- counting and agenda keys land on the wrong task. A CRLF file is switched
-- over (and saved) the first time it is opened; see also the reader fix in
-- org_setup().
vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'org',
  callback = function(ev)
    local b = vim.bo[ev.buf]
    if b.buftype == '' and b.fileformat ~= 'unix' and vim.api.nvim_buf_get_name(ev.buf) ~= '' then
      local was_modified = b.modified
      b.fileformat = 'unix'
      if not was_modified then
        vim.schedule(function() autosave(ev.buf) end)
      end
    end
  end,
})

-- A heading's tags sit one space after its title (org_tags_column = 0 in
-- org_setup()). orgmode's default (org_tags_column = -80) pads them to end
-- at column 80 (Emacs pads them too), and a window narrower than that wraps
-- such a heading in the middle of the padding: the tag alone at the right
-- edge, the end of the title on the next line. So a file that still has padded
-- headings gets them pulled in when you open it: all of them at once, as one
-- undo step (u puts the padding back), and the file is saved. Only what the
-- org parser reads as a heading's tags is moved. A ":word:" inside a title,
-- a text line that ends in one and a starred line in a #+BEGIN ... #+END
-- block stay as they are, and a heading with one space there already is not
-- touched.
local function pull_tags_in(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  local bo = vim.bo[buf]
  if bo.filetype ~= 'org' or bo.buftype ~= '' or not bo.modifiable or bo.readonly then return end
  -- not a capture (or anything else in Neovim's temp folder, as for
  -- autosave), and not a file orgmode is editing from the agenda right now
  if vim.b[buf].org_capture or vim.b[buf].org_tmp_edit_window then return end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or real(vim.fn.fnamemodify(name, ':h')):find(tmp_dir, 1, true) == 1 then return end
  local parser = vim.treesitter.get_parser(buf, 'org')
  if not parser then return end
  local tagged = vim.treesitter.query.parse('org', '(headline (tag_list) @tags)')
  local gaps = {}
  for _, tags in tagged:iter_captures(parser:parse()[1]:root(), buf) do
    local row, col = tags:start()
    local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
    -- the spaces and tabs between the title and the first colon
    local gap = text:sub(1, col):match('[ \t]*$')
    if gap ~= ' ' and gap ~= '' then
      gaps[#gaps + 1] = { row, col - #gap, col }
    end
  end
  if #gaps == 0 then return end
  -- (each gap is on a line of its own, so closing one moves no other)
  for _, g in ipairs(gaps) do
    vim.api.nvim_buf_set_text(buf, g[1], g[2], g[1], g[3], { ' ' })
  end
  autosave(buf)
end
-- Only for a file opened in a window of its own. An edit from the agenda
-- reads the task's file into a hidden window (b:org_tmp_edit_window is set
-- before the file is read), and u in the agenda reads it with no window at
-- all: both change one task and must find every other line as it was. And
-- not right here but a moment later: the file is still being read. What
-- changes meanwhile Neovim counts as saved and tells no one (the day view
-- would keep the old heading text), and when a file is read again after a
-- change from outside, the parser still has the text from before.
-- And again each time the file is shown in a window (BufWinEnter). A file
-- that sits in a hidden buffer behind the day view, changed on disk by a
-- sync, is read again in a window of Neovim's own (a float too) when :e,
-- Tab in the agenda or Enter in the file tree brings it back, or when the
-- day view re-reads it as it redraws: that read alone left it padded until
-- the next restart. (A look at a file with nothing to pull in changes
-- nothing.)
vim.api.nvim_create_autocmd({ 'FileType', 'BufWinEnter' }, {
  group = group,
  callback = function(ev)
    if vim.bo[ev.buf].filetype ~= 'org' then return end
    if vim.b[ev.buf].org_tmp_edit_window or vim.api.nvim_win_get_config(0).relative ~= '' then return end
    vim.schedule(function() pcall(pull_tags_in, ev.buf) end)
  end,
})

-- ============================================================================
--  TASK PROPERTIES AND CAPTURE NOTES (the org and agenda keys below use these)
-- ============================================================================
-- now as an inactive org time stamp, like [2026-09-28 Mon 14:03]
local function org_now()
  return require('orgmode.objects.date').now():to_wrapped_string(false)
end

-- :START: is when you began a task. orgmode writes it into the task's
-- :PROPERTIES: drawer, making the drawer when there is none: right under the
-- heading and its SCHEDULED / DEADLINE line, the rest of the file untouched.
local function set_start(task)
  local stamp = org_now()
  task:set_property('START', stamp)
  return stamp
end

-- the task the cursor is in (on its heading or anywhere under it)
local function task_here()
  local ok, task = pcall(function()
    return require('orgmode').files:get_closest_headline_or_nil()
  end)
  if not ok or not task then
    vim.notify('Not on a task: put the cursor on a heading or under one')
    return nil
  end
  return task
end

-- Space x: the checkbox of the list item under the cursor.
--   - [ ] text   is ticked, [X], and the next press unticks it
--   - text       gets an empty box
-- orgmode does the ticking, so the box of the item above a sub-item and a
-- [1/3] counter on the heading follow. Ctrl Space is orgmode's own key for
-- it and works too where the terminal sends it (macOS; never on Windows:
-- a console there hands Neovim no Ctrl Space at all). While typing, Ctrl
-- Space was Vim's "put in what you typed last, and stop typing"; it ticks
-- there too now, and you stay typing.
local function tick()
  local no_item = 'No list item here. A checkbox is a line like:  - [ ] text'
  local pos = vim.api.nvim_win_get_cursor(0)
  pcall(function() vim.treesitter.get_parser(0):parse() end)
  -- (asked from the first letter of the line: there the syntax node is the item)
  vim.api.nvim_win_set_cursor(0, { pos[1], #vim.api.nvim_get_current_line():match('^%s*') })
  local ok, item = pcall(function()
    return require('orgmode').files:get_closest_listitem()
  end)
  vim.api.nvim_win_set_cursor(0, pos)
  if not (ok and item) then
    vim.api.nvim_echo({ { no_item } }, false, {})
    return
  end
  if item:checkbox() then
    item:update_checkbox('toggle')
    return
  end
  local row = item.listitem:range() -- the item's first line, counted from 0
  local text = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ''
  local bullet = text:match('^%s*[-+*]%s+') or text:match('^%s*%d+[.)]%s+')
  if not bullet then
    vim.api.nvim_echo({ { no_item } }, false, {})
    return
  end
  vim.api.nvim_buf_set_text(0, row, #bullet, row, #bullet, { '[ ] ' })
  if pos[1] == row + 1 and pos[2] >= #bullet then
    vim.api.nvim_win_set_cursor(0, { pos[1], pos[2] + 4 })
  end
end

-- A drawer typed by hand lines up. orgmode re-indents a line when a ":" is
-- typed on it, but only once the drawer is complete: so :END: alone jumped
-- to orgmode's own indent, away from the lines above it (typed after a Tab
-- they sat further in). That rule is off (see the org file type below), and
-- this runs instead when :END: has just been typed: the line takes the
-- indent of the drawer's first line (":PROPERTIES:"), and in a drawer of
-- properties so do the lines in between.
local function align_drawer()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  if col ~= #line or not line:match('^%s*:END:$') then return end
  local start
  for r = row - 1, math.max(1, row - 200), -1 do
    local text = vim.fn.getline(r)
    if text:match('^%*+%s') or text:match('^%s*:END:%s*$') then return end
    if text:match('^%s*:[%w_%-]+:%s*$') then
      start = r
      break
    end
  end
  if not start then return end
  local indent = vim.fn.getline(start):match('^%s*')
  local rows = { row }
  local all_properties = true -- every line between is ":name: value"
  for r = start + 1, row - 1 do
    all_properties = all_properties and vim.fn.getline(r):match('^%s*:[%w_%-+]+:') ~= nil
  end
  if all_properties then
    for r = start + 1, row - 1 do rows[#rows + 1] = r end
  end
  for _, r in ipairs(rows) do
    local now = vim.fn.getline(r):match('^%s*')
    if now ~= indent then vim.api.nvim_buf_set_text(0, r - 1, 0, r - 1, #now, { indent }) end
  end
  vim.api.nvim_win_set_cursor(0, { row, #vim.api.nvim_get_current_line() })
end
vim.api.nvim_create_autocmd('TextChangedI', {
  group = group,
  callback = function(ev)
    if vim.bo[ev.buf].filetype == 'org' then align_drawer() end
  end,
})

-- Space o p p asks for a name, then a value (it starts with the value the
-- task has now, from `current(name)`). Nil when you cancel or leave one empty.
local function ask_property(current)
  local function ask(prompt, default)
    local ok, answer = pcall(vim.fn.input, { prompt = prompt, default = default or '', cancelreturn = vim.NIL })
    if not ok or answer == vim.NIL then
      return nil
    end
    return vim.trim(answer)
  end
  -- (":START:" typed out in full works too)
  local name = ask('Property: ')
  name = name and name:gsub('^:+', ''):gsub(':+$', '')
  if not name or name == '' then
    return nil
  end
  if name:find('[%s:]') then
    vim.notify('A property name has no spaces or colons: ' .. name, vim.log.levels.WARN)
    return nil
  end
  local value = ask(name .. ': ', current(name))
  if not value or value == '' then
    vim.notify('Nothing changed (no value)')
    return nil
  end
  return name, value
end

-- Enter at the end of a heading, in an org file or a capture's title: a
-- new line under the heading's own lines (SCHEDULED / DEADLINE, drawers,
-- the created stamp: see org_head_end), at its notes' indent, where notes
-- go. A plain Enter put the note between the heading and its SCHEDULED
-- line, and the date then read as plain text: a started task turned
-- Overdue. False when the cursor is anywhere else (Enter then works as
-- usual).
local function heading_notes()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local stars = line:match('^(%*+)%s')
  if not stars or col < #line then
    return false
  end
  local last = org_head_end(row)
  local indent = require('orgmode.config'):get_indent(#stars + 1, 0)
  vim.api.nvim_buf_set_lines(0, last, last, false, { indent })
  vim.api.nvim_win_set_cursor(0, { last + 1, #indent })
  return true
end

-- org files are laid out in 2-space steps (notes sit 2 in under a task), so
-- Tab / Shift Tab move 2 at a time there instead of 4
vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'org',
  callback = function(ev)
    vim.opt_local.shiftwidth = 2
    vim.opt_local.softtabstop = 2
    -- orgmode's "re-indent the line when a : is typed" off (see align_drawer;
    -- scheduled: orgmode adds the rule in its own setup, which runs after this)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(ev.buf) then
        vim.bo[ev.buf].indentkeys = (vim.bo[ev.buf].indentkeys:gsub(',?<:>', ''))
      end
    end)

    -- Space o i h / t / T: new heading. Above the first heading (a new file's
    -- #+TITLE line, say) orgmode's own versions split the line at the cursor,
    -- and in Vim the cursor sits ON the last letter, so that letter moved into
    -- the heading (or, from column 1, the whole line became one). There, open
    -- a fresh line below and put the heading on it; everywhere else it is
    -- orgmode's own behavior.
    local function new_heading(action)
      return function()
        local row = vim.fn.line('.')
        local above = false
        for l = row, 1, -1 do
          if vim.fn.getline(l):match('^%*+%s') then
            above = true
            break
          end
        end
        if not above and vim.fn.getline(row) ~= '' then
          vim.api.nvim_buf_set_lines(0, row, row, false, { '' })
          vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
        end
        require('orgmode').action(action)
      end
    end
    local opts = { buffer = ev.buf, silent = true }
    -- V then J / K: the same move as Alt Down / Up. The plain line move (:m)
    -- left a heading's SCHEDULED / DEADLINE line and notes behind, and the
    -- date went to the task above.
    map('x', 'J', move_selection(1), vim.tbl_extend('force', opts, { desc = 'Move the selected lines down' }))
    map('x', 'K', move_selection(-1), vim.tbl_extend('force', opts, { desc = 'Move the selected lines up' }))
    map('n', '<leader>oih', new_heading('org_mappings.insert_heading_respect_content'),
      vim.tbl_extend('force', opts, { desc = 'New heading below this one' }))
    map('n', '<leader>oit', new_heading('org_mappings.insert_todo_heading_respect_content'),
      vim.tbl_extend('force', opts, { desc = 'New TODO heading below this one' }))
    map('n', '<leader>oiT', new_heading('org_mappings.insert_todo_heading'),
      vim.tbl_extend('force', opts, { desc = 'New TODO heading right after this heading' }))

    -- Enter while typing: at the end of a heading, to a notes line under its
    -- dates; anywhere else orgmode's own Enter (tables, then a plain new line)
    map('i', '<CR>', function()
      if not heading_notes() then
        require('orgmode').action('org_mappings.org_return')
      end
    end, vim.tbl_extend('force', opts, { desc = 'New line (end of a heading: under its dates)' }))

    map('n', '<leader>x', tick, vim.tbl_extend('force', opts, { desc = 'Tick a checkbox' }))
    map({ 'n', 'i' }, '<C-Space>', tick, vim.tbl_extend('force', opts, { desc = 'Tick a checkbox' }))

    -- Tab / Shift Tab fold as orgmode's own do, but drawers stay folded, and
    -- Tab on a drawer opens or closes just that one (see DRAWERS)
    map('n', '<Tab>', org_tab, vim.tbl_extend('force', opts, { desc = 'Fold / unfold the task or drawer' }))
    map('n', '<S-Tab>', org_shift_tab, vim.tbl_extend('force', opts, { desc = 'Fold / unfold everything' }))
    watch_drawers(ev.buf)
    -- n / N as everywhere: the match centered, the folds it is in opened. The
    -- drawer the match before was in folds again, so a search does not leave
    -- a trail of open drawers.
    for key, desc in pairs({ n = 'Next match, centered', N = 'Previous match, centered' }) do
      map('n', key, function()
        vim.schedule(fold_drawers)
        return key .. 'zzzv'
      end, { buffer = ev.buf, expr = true, desc = desc })
    end

    -- Space o p s: START = now, replacing one already there. Space o p p:
    -- any property, by name. (Moving a task to INPROGRESS sets START by
    -- itself when it has none; see org_setup.)
    map('n', '<leader>ops', function()
      local task = task_here()
      if task then
        vim.notify('START set to ' .. set_start(task))
      end
    end, vim.tbl_extend('force', opts, { desc = 'Set START to now' }))
    map('n', '<leader>opp', function()
      local task = task_here()
      if not task then
        return
      end
      local name, value = ask_property(function(n)
        return task:get_property(n, false)
      end)
      if name then
        task:set_property(name, value)
        vim.notify(name .. ' set to ' .. value)
      end
    end, vim.tbl_extend('force', opts, { desc = 'Set a property' }))
  end,
})

-- ============================================================================
--  COLORS - Catppuccin Mocha, blue as the primary accent. Orgmode only sets
--  `default` colors, so these always win.
-- ============================================================================
local P = {
  base = '#1e1e2e', mantle = '#181825', surface0 = '#313244', surface1 = '#45475a',
  overlay0 = '#6c7086', overlay1 = '#7f849c', subtext0 = '#a6adc8', text = '#cdd6f4',
  lavender = '#b4befe', blue = '#89b4fa', sapphire = '#74c7ec', sky = '#89dceb',
  teal = '#94e2d5', green = '#a6e3a1', peach = '#fab387', mauve = '#cba6f7', red = '#f38ba8',
}

-- the agenda look (lua/kit/agenda.lua) brings its own colors
local look_ok, look = pcall(require, 'kit.agenda')
if not look_ok then
  note('agenda look: ' .. tostring(look))
end

try('catppuccin', function()
  require('catppuccin').setup({
    flavour = 'mocha',
    -- (the theme only spots plugins installed by a plugin manager, so name them)
    integrations = { mini = { enabled = true }, nvimtree = true },
    custom_highlights = function()
      return vim.tbl_extend('force', look_ok and look.colors(P) or {}, {
        -- headings in cool tones (the theme's defaults run peach / pink / mauve)
        ['@org.headline.level1'] = { fg = P.blue, bold = true },
        ['@org.headline.level2'] = { fg = P.sapphire, bold = true },
        ['@org.headline.level3'] = { fg = P.teal },
        ['@org.headline.level4'] = { fg = P.lavender },
        ['@org.headline.level5'] = { fg = P.sky },
        ['@org.headline.level6'] = { fg = P.blue },
        ['@org.headline.level7'] = { fg = P.sapphire },
        ['@org.headline.level8'] = { fg = P.teal },
        ['@org.timestamp.active'] = { fg = P.sapphire },
        ['@org.timestamp.inactive'] = { fg = P.overlay1 },
        ['@org.plan'] = { fg = P.overlay1 },
        -- no background on folded lines: with one, a fold and a selection
        -- look the same in visual mode. A fold still ends in "..."
        -- (orgmode's mark for one).
        Folded = { fg = P.subtext0, bg = 'NONE' },
        -- a line of dashes, drawn as a rule (see RULES)
        KitOrgRule = { fg = P.overlay0 },
        -- *bold* in the theme is red, which reads as urgent
        ['@org.bold'] = { fg = P.text, bold = true },
        ['@org.bold.delimiter'] = { fg = P.overlay1 },
        -- priority cookies: the lone red is A (urgent), B-C lavender, D-F recede
        ['@org.priority.highest'] = { fg = P.red, bold = true },
        ['@org.priority.high'] = { fg = P.lavender, bold = true },
        ['@org.priority.default'] = { fg = P.overlay1 },
        ['@org.priority.low'] = { fg = P.overlay0 },
        ['@org.priority.lowest'] = { fg = P.overlay0 },
        -- orgmode's own agenda colors (what shows if the kit's look cannot load)
        ['@org.agenda.header'] = { fg = P.blue, bold = true },
        ['@org.agenda.day'] = { fg = P.sapphire, bold = true },
        ['@org.agenda.today'] = { fg = P.blue, bold = true },
        ['@org.agenda.weekend'] = { fg = P.sapphire, bold = true },
        ['@org.agenda.weekend.today'] = { fg = P.blue, bold = true },
        ['@org.agenda.scheduled'] = { fg = P.text },
        ['@org.agenda.scheduled_past'] = { fg = P.subtext0 },
        ['@org.agenda.deadline'] = { fg = P.peach },
        ['@org.agenda.deadline.upcoming'] = { fg = P.text },
        ['@org.agenda.time_grid'] = { fg = P.surface1 },
        ['@org.agenda.separator'] = { fg = P.surface1 },
        ['@org.agenda.tag'] = { fg = P.overlay1 },
      })
    end,
  })
  vim.cmd.colorscheme('catppuccin-mocha')
end)
if not vim.g.colors_name then
  pcall(vim.cmd.colorscheme, 'habamax') -- plugin missing: stay readable
end

-- ============================================================================
--  RULES - in an org file a line of only dashes, three or more (org itself
--  asks for five), is drawn as a quiet line across the window, to break a
--  file up. The file keeps the dashes as typed, and while you type on that
--  line it shows them as they are. Dashes inside a #+BEGIN ... #+END block
--  stay text.
-- ============================================================================
vim.api.nvim_set_hl(0, 'KitOrgRule', { link = 'Comment', default = true })
local rule_ns = vim.api.nvim_create_namespace('kit_rule')
local rule_width = 0 -- columns of text in the window being drawn
vim.api.nvim_set_decoration_provider(rule_ns, {
  on_win = function(_, win, buf)
    if vim.bo[buf].filetype ~= 'org' then return false end
    local info = vim.fn.getwininfo(win)[1]
    rule_width = info and (info.width - info.textoff) or 0
    return true
  end,
  on_line = function(_, win, buf, row)
    local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
    local indent, dashes = text:match('^(%s*)(%-%-%-+)%s*$')
    if not dashes then return end
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, #indent } })
    for _ = 1, 4 do
      if not (ok and node) then break end
      if node:type() == 'block' then return end
      node = node:parent()
    end
    local width = rule_width - vim.fn.strdisplaywidth(indent)
    local typing_here = win == vim.api.nvim_get_current_win() and vim.api.nvim_win_get_cursor(win)[1] == row + 1
      and vim.api.nvim_get_mode().mode:match('^[iR]') ~= nil
    if typing_here or width < #dashes then
      vim.api.nvim_buf_set_extmark(buf, rule_ns, row, #indent, {
        end_col = #indent + #dashes, hl_group = 'KitOrgRule', ephemeral = true,
      })
    else
      vim.api.nvim_buf_set_extmark(buf, rule_ns, row, #indent, {
        virt_text = { { string.rep('─', width), 'KitOrgRule' } }, virt_text_pos = 'overlay',
        hl_mode = 'combine', ephemeral = true,
      })
    end
  end,
})

-- ============================================================================
--  FINDER + FILE TREE (mini.pick, nvim-tree; mini.files is the spare)
--  No Nerd Font on a locked-down machine, so no icon glyphs anywhere (they
--  draw as empty boxes). mini.files folders get a plain "+ ", tree folders an
--  arrow.
-- ============================================================================
try('mini.pick', function()
  require('mini.pick').setup({
    mappings = { move_down = '<C-j>', move_up = '<C-k>' }, -- Ctrl j / k to move, the Vim habit; arrows work too
    source = {
      show = function(buf_id, items, query)
        MiniPick.default_show(buf_id, items, query, { show_icons = false })
      end,
    },
    window = { prompt_caret = '|' },
  })
end)

try('mini.files', function()
  require('mini.files').setup({
    content = {
      prefix = function(entry)
        if entry.fs_type == 'directory' then return '+ ', 'MiniFilesDirectory' end
        return '  ', 'MiniFilesFile'
      end,
    },
    -- Enter opens, L opens and closes the explorer, _ goes up
    mappings = { go_in = '<CR>', go_in_plus = 'L', go_out = '_', go_out_plus = 'H' },
    -- folders you open (:e some\folder) show in the file tree instead
    options = { use_as_default_explorer = false },
  })
end)

-- The file tree: on the right, 35 wide, relative line numbers, indent lines,
-- arrows on folders. No icons (no Nerd Font on a locked-down machine): the
-- arrows and lines are plain characters that Cascadia Mono has. No git marks
-- (the machine may have no git). Keys: nvim-tree's own (g? lists them),
-- except Ctrl k, which moves between splits here too.
try('nvim-tree', function()
  local dir = vim.fs.joinpath(config_dir, 'pack', 'kit', 'start', 'nvim-tree')
  if vim.fn.isdirectory(dir) == 0 then
    error('missing: ' .. dir .. ' (the repo copy is incomplete; re-download it). Space ee opens mini.files meanwhile', 0)
  end
  local api = require('nvim-tree.api')
  require('nvim-tree').setup({
    on_attach = function(buf)
      api.map.on_attach.default(buf)
      pcall(vim.keymap.del, 'n', '<C-k>', { buffer = buf }) -- was: file info
    end,
    view = { side = 'right', width = 35, relativenumber = true },
    renderer = {
      indent_markers = { enable = true },
      icons = {
        show = {
          file = false, folder = false, folder_arrow = true, git = false,
          modified = false, hidden = false, diagnostics = false, bookmarks = true,
        },
        symlink_arrow = ' -> ',
        glyphs = {
          bookmark = '*', modified = '+', hidden = 'h',
          folder = { arrow_closed = '→', arrow_open = '↓' },
        },
      },
    },
    -- Enter opens in the window you came from, no "pick a window" letters
    actions = { open_file = { window_picker = { enable = false } } },
    filters = { custom = { '^\\.DS_Store$' } },
    git = { enable = false },
    -- "plan.org was properly removed.", not the whole path: a long path ran
    -- onto a second line and stopped at "Press ENTER" after every change
    notify = { absolute_path = false },
    -- nvim-tree's docs warn its folder watching can bog Windows down, so it is
    -- off there: the tree then redraws after its own changes and every save,
    -- and R picks up anything changed outside Neovim
    filesystem_watchers = { enable = not is_win },
  })
  tree_ok = true
end)

-- ============================================================================
--  ORG MODE - agenda + notes. The TODO keywords, priorities and colors are
--  set here, in one place, so a task means the same thing everywhere.
-- ============================================================================
local org_ok = false

-- a window the agenda or a capture can use: not a float (a finder, the date
-- picker), not the file tree, not the cheat panel
local function org_target(win)
  if not (win and win ~= 0 and vim.api.nvim_win_is_valid(win)) or vim.api.nvim_win_get_config(win).relative ~= '' then
    return false
  end
  local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
  return ft ~= 'NvimTree' and ft ~= 'kitcheat'
end

-- The agenda is the home screen: it opens full size in the window you are in,
-- file or not. The file stays open underneath and q in the agenda goes back
-- to it. Capture opens in a split below.
local function org_window(name)
  -- Never inside the file tree, the cheat panel or a float: go to the
  -- window you came from if it is a usable one, else the first usable one
  -- on screen. Only when there is none (the tree alone) open one beside it.
  -- (Stepping back with wincmd p alone went wrong: from the tree it can land
  -- in the cheat panel, and after a closed float it stays in the tree.)
  if not org_target(vim.api.nvim_get_current_win()) then
    local target = vim.fn.win_getid(vim.fn.winnr('#'))
    if not org_target(target) then
      target = nil
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if org_target(win) then
          target = win
          break
        end
      end
    end
    if target then
      vim.api.nvim_set_current_win(target)
    else
      vim.cmd('topleft vnew')
    end
  end
  if name == 'orgagenda' then
    -- remember the file for q (Vim's own "previous file" is lost after a capture)
    local from = vim.api.nvim_get_current_buf()
    vim.w.kit_agenda_from = vim.fn.buflisted(from) == 1 and from or nil
    vim.cmd.edit(vim.fn.fnameescape(name))
  else
    vim.cmd(('16split %s'):format(vim.fn.fnameescape(name)))
  end
end

local function org_setup()
  if vim.fn.has('nvim-0.12') == 0 then
    local v = vim.version()
    local how = is_win and '. Start it with nvim.cmd' or ''
    note(('this is Neovim %d.%d; the kit needs 0.12%s'):format(v.major, v.minor, how))
    return
  end
  local parser = vim.fs.joinpath(config_dir, 'pack', 'kit', 'start', 'orgmode', 'parser', 'org.so')
  if vim.fn.filereadable(parser) == 0 then
    note('org parser missing: ' .. parser .. ' (the repo copy is incomplete; re-download it)')
    return
  end
  -- The parser in the orgmode folder is the WINDOWS build (macOS kills a
  -- process that tries to load it). On macOS, register the Mac build first
  -- (one file for Apple Silicon and Intel, macOS 11 and up); after that
  -- nothing loads the Windows file. If the Mac one will not load, stop here,
  -- before orgmode reaches for the other file itself. Linux (x86_64) works
  -- the same way with its own build.
  if not is_win then
    local own = vim.fs.joinpath(config_dir, 'org-parser', vim.fn.has('linux') == 1 and 'org-linux-x86_64.so' or 'org-macos.so')
    local ok, loaded, err = pcall(vim.treesitter.language.add, 'org', { path = own })
    if not ok or not loaded then
      local why = tostring(err or loaded):gsub('^.-%.lua:%d+: ', '')
      note('org parser for this machine would not load: ' .. why .. ' (' .. own .. ')')
      return
    end
    parser = own
  end
  local ok, loaded, err = pcall(vim.treesitter.language.add, 'org')
  if not ok or not loaded then
    local why = tostring(err or loaded):gsub('^.-%.lua:%d+: ', '') -- drop Neovim's own file:line prefix
    note('org parser would not load: ' .. why .. ' (' .. parser .. ')')
    return
  end

  if vim.fn.isdirectory(org_dir) == 0 then
    pcall(vim.fn.mkdir, org_dir, 'p')
    if vim.fn.isdirectory(org_dir) == 0 then
      note('could not create your org folder ' .. org_dir)
    end
  end
  -- first launch: create inbox.org, where captures go. orgmode can write a
  -- capture into a missing file, but not while that file is open unsaved.
  local inbox = vim.fs.joinpath(org_dir, 'inbox.org')
  if vim.fn.isdirectory(org_dir) == 1 and vim.fn.filereadable(inbox) == 0 then
    pcall(vim.fn.writefile, { '#+TITLE: Inbox', '' }, inbox)
  end

  -- orgmode reads the files it has not opened itself by splitting on \r OR
  -- \n, so each CRLF line ending (Windows) counts as two and every line after
  -- the first is off: SCHEDULED / DEADLINE are no longer under their heading,
  -- and agenda keys edit whatever task sits at the doubled line number. Read
  -- them the right way. (orgmode calls utils.readfile through the module
  -- table, so replacing it here is enough.)
  local u = require('orgmode.utils')
  local readfile = u.readfile
  u.readfile = function(file, opts)
    if opts and opts.raw then
      return readfile(file, opts)
    end
    return readfile(file, vim.tbl_extend('force', opts or {}, { raw = true })):next(function(data)
      local lines = vim.split(data, '\r?\n')
      if lines[#lines] == '' then
        table.remove(lines)
      end
      return lines
    end)
  end

  require('orgmode').setup({
    org_agenda_files = org_dir .. '/**/*',
    org_default_notes_file = org_dir .. '/inbox.org',

    -- the TODO keywords; the letter is the key in the cit menu
    org_todo_keywords = {
      'TODO(t)', 'INPROGRESS(i)', 'WAITING(w)', 'BLOCKED(b)', 'SCHEDULED(s)', 'DEFERRED(f)', 'SOMEDAY(o)',
      '|', 'DONE(d)', 'DELEGATED(g)', 'CANCELLED(c)',
    },
    org_todo_keyword_faces = {
      TODO = ':foreground ' .. P.blue .. ' :weight bold',
      INPROGRESS = ':foreground ' .. P.teal .. ' :weight bold',
      WAITING = ':foreground ' .. P.lavender .. ' :weight bold',
      BLOCKED = ':foreground ' .. P.red .. ' :weight bold',
      SCHEDULED = ':foreground ' .. P.sky .. ' :weight bold',
      DEFERRED = ':foreground ' .. P.overlay1,
      SOMEDAY = ':foreground ' .. P.mauve,
      DONE = ':foreground ' .. P.overlay1,
      DELEGATED = ':foreground ' .. P.green,
      CANCELLED = ':foreground ' .. P.overlay0,
    },
    org_priority_highest = 'A',
    org_priority_lowest = 'F',
    org_priority_default = 'D',

    org_log_done = 'time',
    org_log_repeat = 'time',
    org_log_into_drawer = 'LOGBOOK',
    org_startup_folded = 'content',
    org_hide_leading_stars = true,
    org_id_method = 'ts', -- the default runs uuidgen, which Windows does not have
    -- tags go one space after the title. orgmode's default (-80) pads them
    -- out to end at column 80, and a window narrower than that wraps the
    -- heading in the middle of the padding (see pull_tags_in() above)
    org_tags_column = 0,

    -- Space o c, then the letter. You type the title; Enter at the end of it
    -- goes to a new line under the dates, where notes go (see heading_notes
    -- above). s and d first ask for the date with the date picker.
    org_capture_templates = {
      t = { description = 'Task', template = '* TODO %?\n  %u' },
      s = { description = 'Task with a start date', template = '* TODO %?\n  SCHEDULED: %^{Start date}t\n  %u' },
      d = { description = 'Task with a due date', template = '* TODO %?\n  DEADLINE: %^{Due date}t\n  %u' },
      n = { description = 'Note', template = '* %?\n  %u' },
    },

    -- the agenda. How it reads (columns, hours, overdue) is lua/kit/agenda.lua.
    -- Space o a a is a week, Monday to Sunday, empty days kept.
    org_agenda_span = 'week',
    org_agenda_start_on_weekday = 1,
    org_agenda_skip_scheduled_if_done = true,
    org_agenda_skip_deadline_if_done = true,
    org_agenda_remove_tags = true,
    org_agenda_hide_empty_blocks = true,
    org_agenda_block_separator = ' ',
    org_agenda_current_time_string = 'now ' .. string.rep('─', 30),
    org_agenda_time_grid = {
      type = { 'daily', 'today', 'require-timed' },
      times = { 800, 1000, 1200, 1400, 1600, 1800, 2000 }, -- the hours a day shows
      time_separator = '  ',
      time_label = string.rep('─', 12),
    },
    -- Space o a d, the home screen: today with its hours, then Overdue,
    -- Coming up (deadlines, start dates and appointments in the next 14
    -- days, and any deadline of a task already started) and Started
    -- (SCHEDULED is a start date: passed, with no deadline), then the open
    -- work by state. "To do" lists only tasks with no date; dated ones show
    -- on their day, or under Coming up before it. Last comes Completed:
    -- what you closed in the last 14 days, the newest first (the number is
    -- COMPLETED_DAYS in lua/kit/agenda.lua; Space o a c lists everything).
    -- (Filtering with org_agenda_todo_ignore_scheduled = 'past' / 'future'
    -- is inverted at the pinned orgmode commit; 'all' works.)
    org_agenda_custom_commands = {
      d = {
        description = 'My day: today, overdue, coming up, open work, completed',
        types = {
          { type = 'agenda', org_agenda_span = 'day' },
          { type = 'tags_todo', match = '/INPROGRESS', org_agenda_overriding_header = 'In progress' },
          { type = 'tags_todo', match = '/WAITING|BLOCKED', org_agenda_overriding_header = 'Waiting / blocked' },
          {
            type = 'tags_todo',
            match = '/TODO|SCHEDULED',
            org_agenda_overriding_header = look_ok and look.UNDATED or 'To do',
            org_agenda_todo_ignore_scheduled = 'all',
            org_agenda_todo_ignore_deadlines = 'all',
          },
          { type = 'tags_todo', match = '/SOMEDAY|DEFERRED', org_agenda_overriding_header = 'Someday / deferred' },
          {
            type = 'tags',
            match = '/DONE|DELEGATED|CANCELLED',
            org_agenda_overriding_header = look_ok and look.COMPLETED or 'Completed',
          },
        },
      },
      -- Space o a c: what you finished, grouped by the day it was closed
      -- (CLOSED: line), newest first; lua/kit/agenda.lua draws it
      c = {
        description = 'Done, newest first',
        types = {
          {
            type = 'tags',
            match = '/DONE|DELEGATED|CANCELLED',
            org_agenda_overriding_header = look_ok and look.DONE or 'Done',
          },
        },
      },
      -- Space o a p: the task lists of Space o a t, one per priority instead
      -- of one per file, every file's tasks in one place (lua/kit/agenda.lua
      -- draws it; o in the lists flips between the two)
      p = look_ok and {
        description = 'Tasks by priority, every file',
        types = {},
        kit_lists = 'priority',
      } or nil,
    },

    win_split_mode = org_window,
    mappings = {
      -- replaced below: q never errors on the last window; Tab always splits;
      -- Enter / Tab on a list header (Space o a t) fold it
      agenda = { org_agenda_quit = false, org_agenda_goto = false, org_agenda_switch_to = false },
      -- replaced below: above the first heading these split your line; Enter
      -- at the end of a heading goes to a notes line under its dates
      org = {
        org_insert_heading_respect_content = false,
        org_insert_todo_heading = false,
        org_insert_todo_heading_respect_content = false,
        org_return = false,
        -- Shift Up / Down scroll half a page everywhere (see the keys above)
        org_timestamp_up_day = false,
        org_timestamp_down_day = false,
        -- Ctrl Space: the kit's tick (Space x), which also adds a box
        org_toggle_checkbox = false,
        -- Tab / Shift Tab: the kit's, which leave drawers folded (see DRAWERS)
        org_cycle = false,
        org_global_cycle = false,
      },
    },
  })
  org_ok = true

  -- A task moved to INPROGRESS (t in the agenda, V then t, cit in a file)
  -- gets :START: [now] when it has no START yet (an empty one counts as
  -- none). orgmode announces every state change it makes; typing the word
  -- by hand is not one.
  try('START on INPROGRESS', function()
    local events = require('orgmode.events')
    events.listen(events.event.TodoChanged, function(event)
      -- (never let this stop orgmode's own change, which goes on after it)
      local ok, err = pcall(function()
        local task = event.headline
        if task:get_todo() ~= 'INPROGRESS' or event.old_todo_state == 'INPROGRESS' then
          return
        end
        local start = task:get_property('START', false)
        if not start or vim.trim(start) == '' then
          set_start(task)
        end
      end)
      if not ok then
        vim.notify('nvim kit: START not set: ' .. tostring(err), vim.log.levels.WARN)
      end
    end)
  end)

  -- The date picker (Space o i s / d, a dated capture): Down / Up move a
  -- week, Right / Left a day, on into the next or previous month (Down on
  -- the last row lands on the same weekday there). orgmode's own stop at
  -- the edge of the month, and Enter then picked the day still under the
  -- cursor. While the time is being set they change the time, as before.
  try('date picker', function()
    local Calendar = require('orgmode.objects.calendar')
    for _, name in ipairs({ 'render', 'jump_day', 'get_selected_date', '_time_picker_active' }) do
      assert(type(Calendar[name]) == 'function', 'orgmode\'s date picker has no ' .. name .. '() any more')
    end
    for name, days in pairs({ cursor_down = 7, cursor_up = -7, cursor_right = 1, cursor_left = -1 }) do
      local own = Calendar[name]
      Calendar[name] = function(self, ...)
        if self:_time_picker_active() then
          return own(self, ...)
        end
        -- from the day under the cursor (a mouse click moves it too)
        local line, col = vim.fn.line('.'), vim.fn.col('.')
        if line >= 3 and line <= 8 and vim.fn.getline('.'):sub(col, col):match('%d') then
          self.date = self:get_selected_date()
        end
        self.date = self.date:add({ day = days * vim.v.count1 })
        self:render()
        self:jump_day()
      end
    end
  end)

  -- Space o k in a capture throws it away. Once anything was typed into it
  -- (it no longer holds just what the template put there), it asks first:
  -- y throws it away, any other key keeps it.
  try('Space o k asks first', function()
    local Capture = require('orgmode.capture')
    local setup_mappings, kill = Capture.setup_mappings, Capture.kill
    assert(type(setup_mappings) == 'function' and type(kill) == 'function', 'orgmode\'s capture changed')
    -- (runs in the new capture, right after the template is filled in)
    Capture.setup_mappings = function(self, ...)
      vim.b.kit_capture_start = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      return setup_mappings(self, ...)
    end
    Capture.kill = function(self, from_mapping, ...)
      local start = vim.b.kit_capture_start
      if from_mapping and vim.b.org_capture and start
        and not vim.deep_equal(start, vim.api.nvim_buf_get_lines(0, 0, -1, false)) then
        pcall(vim.cmd, 'redrawstatus')
        vim.api.nvim_echo({ { 'Throw away this capture? y/N ', 'WarningMsg' } }, false, {})
        local ok, key = pcall(vim.fn.getcharstr)
        if not (ok and (key == 'y' or key == 'Y')) then
          vim.api.nvim_echo({ { 'Kept. Ctrl c saves it.' } }, false, {})
          return
        end
        vim.api.nvim_echo({ { '' } }, false, {})
      end
      return kill(self, from_mapping, ...)
    end
  end)

  if look_ok then
    -- without the look, its no-date filter is gone too, so that block is just
    -- "To do"; and the Done list is orgmode's plain one, not newest first
    look.on_fail = function()
      local rename = { [look.UNDATED] = 'To do', [look.DONE] = 'Done' }
      for _, command in pairs(require('orgmode.config').org_agenda_custom_commands) do
        for _, t in ipairs(command.types) do
          t.org_agenda_overriding_header = rename[t.org_agenda_overriding_header] or t.org_agenda_overriding_header
        end
      end
    end
    local ok, why = look.setup()
    if not ok then
      note('agenda look: ' .. tostring(why) .. '; showing orgmode\'s plain agenda')
      pcall(look.on_fail)
    end
  end
end

try('orgmode', org_setup)

-- the agenda reads like a list, not a file: no line numbers. q goes back to
-- the file you opened it from; with none, it closes (or leaves an empty
-- window instead of an error when it is the only one)
vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'orgagenda',
  callback = function(ev)
    vim.opt_local.number = false
    vim.opt_local.relativenumber = false
    vim.opt_local.signcolumn = 'no'
    -- opening in the start buffer: drop the "Loading your day" text
    vim.api.nvim_buf_clear_namespace(ev.buf, vim.api.nvim_create_namespace('kit_splash'), 0, -1)
    map('n', 'q', function()
      local from = vim.w.kit_agenda_from
      vim.w.kit_agenda_from = nil
      -- (at startup the agenda reuses the empty start buffer, so from == ev.buf)
      if from and from ~= ev.buf and vim.api.nvim_buf_is_valid(from) and vim.fn.buflisted(from) == 1 then
        vim.cmd.buffer(from)
        return
      end
      -- the file tree and the keys panel (Space K) do not count as other
      -- windows: closing the agenda beside them would leave them alone on
      -- screen (the panel then full width; Esc there, a blank screen)
      local others = vim.tbl_filter(function(w)
        local ft = vim.bo[vim.api.nvim_win_get_buf(w)].filetype
        return w ~= vim.api.nvim_get_current_win() and vim.api.nvim_win_get_config(w).relative == ''
          and ft ~= 'NvimTree' and ft ~= 'kitcheat'
      end, vim.api.nvim_tabpage_list_wins(0))
      if #others == 0 or not pcall(vim.cmd.close) then
        vim.cmd.enew()
      end
    end, { buffer = ev.buf, desc = 'Close the agenda' })
    -- Tab: the task in a split above (or in the org file already on screen),
    -- the agenda stays. orgmode's own Tab takes any empty window, and after an
    -- edit from the agenda that is its hidden edit window, so the file ended
    -- up replacing the agenda.
    map('n', '<CR>', function()
      local agenda = require('orgmode').agenda
      if agenda:get_headline_at_cursor() then
        return agenda:switch_to_item()
      end
      pcall(function() require('kit.agenda').toggle_list() end)
    end, { buffer = ev.buf, desc = 'Open the item here' })
    map('n', '<Tab>', function()
      local headline = require('orgmode').agenda:get_headline_at_cursor()
      if not headline then
        pcall(function() require('kit.agenda').toggle_list() end)
        return
      end
      local target
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(w).relative == '' and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'org' then
          target = w
        end
      end
      if target then
        vim.api.nvim_set_current_win(target)
      else
        vim.cmd('aboveleft split')
      end
      require('orgmode.utils').goto_headline(headline)
    end, { buffer = ev.buf, desc = 'Open the item in a split' })
    -- Space o p s / Space o p p on a task row, as in its file
    local function property_key(ask)
      return function()
        local task = require('orgmode').agenda:get_headline_at_cursor()
        if not task then
          vim.notify('Not on a task row')
          return
        end
        local name, value = 'START', nil
        if ask then
          name, value = ask_property(function(n)
            return task:get_property(n, false)
          end)
          if not name then
            return
          end
        end
        local ok, ran = pcall(require('kit.agenda').edit, function(t)
          if ask then
            t:set_property(name, value)
          else
            value = set_start(t)
          end
        end)
        if not ok then
          vim.notify('nvim kit: ' .. tostring(ran), vim.log.levels.ERROR)
        elseif ran then
          vim.notify(name .. ' set to ' .. value)
        end
      end
    end
    map('n', '<leader>ops', property_key(false), { buffer = ev.buf, desc = 'Set START to now' })
    map('n', '<leader>opp', property_key(true), { buffer = ev.buf, desc = 'Set a property' })
    -- u / Ctrl r: take back / make again the last change made here (t, + / -,
    -- dates, tags, properties, also after V), in the task's file (see
    -- lua/kit/agenda.lua). The agenda buffer is not modifiable, so plain u
    -- errors (E21).
    local function undo_key(redo)
      return function()
        local ok, look_mod = pcall(require, 'kit.agenda')
        if not ok then
          vim.notify('Undo from the agenda needs the kit\'s agenda look (Tab to the task, then u)', vim.log.levels.WARN)
          return
        end
        for _ = 1, vim.v.count1 do
          if not look_mod.undo(redo) then
            break
          end
        end
      end
    end
    map('n', 'u', undo_key(false), { buffer = ev.buf, desc = 'Undo the last change made here' })
    map('n', '<C-r>', undo_key(true), { buffer = ev.buf, desc = 'Redo it' })
    -- V (select rows), then the same key as for one task: the change goes to
    -- every task in the selected rows. t and Space o i s / d ask once.
    -- (<Cmd> maps, not Lua callbacks: from a callback the keyword menu opens
    -- behind a "Press ENTER" prompt, and Enter cancels it)
    for key, bulk in pairs(look_ok and {
      t = { 'todo', 'Change TODO state of the selected tasks' },
      ['+'] = { 'up', 'Priority up for the selected tasks' },
      ['-'] = { 'down', 'Priority down for the selected tasks' },
      ['<leader>ois'] = { 'schedule', 'Start date for the selected tasks' },
      ['<leader>oid'] = { 'deadline', 'Deadline for the selected tasks' },
      ['<leader>o$'] = { 'archive', 'Archive the selected tasks' },
    } or {}) do
      map('x', key, ('<Cmd>lua require("kit.agenda").bulk("%s")<CR>'):format(bulk[1]),
        { buffer = ev.buf, desc = bulk[2] })
    end
  end,
})

-- The day view remembers each task by the line it sat on when it was drawn.
-- Edit an org file after that (add lines, move tasks under a heading, write a
-- capture) and those lines point at other tasks: + in the day view would then
-- change the wrong one. So typing in any org file marks the day view out of
-- date, and coming back to it redraws it first. orgmode's own edits from the
-- day view run in a hidden float and keep its lines right, so they do not
-- count. Coming back to Neovim counts too (a sync tool may have changed a file).
-- Never from inside orgmode's hidden edit window (a float that shows the
-- agenda for a moment when t / + / Space o i s open the task): a redraw
-- started there finished during the edit and moved that window's cursor.
-- The redraw is finished before any key you already typed runs (they wait
-- in line), and the cursor goes back to the same task, not the same line
-- number (rows above it may have come or gone).
local agenda_outdated = false
local function refresh_agenda_if_outdated()
  if not agenda_outdated or vim.bo.filetype ~= 'orgagenda' then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative ~= '' then
    return
  end
  agenda_outdated = false
  -- lua/kit/agenda.lua: redraw, wait for it, cursor back on the same row
  pcall(function() require('kit.agenda').refresh_now() end)
end
-- a freshly drawn agenda is up to date
vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'orgagenda',
  callback = function()
    agenda_outdated = false
  end,
})
vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
  group = group,
  pattern = '*.org',
  callback = function()
    if vim.api.nvim_win_get_config(0).relative == '' and not vim.b.org_tmp_edit_window then
      agenda_outdated = true
    end
  end,
})
-- Not right after a capture closes (:wq, ZZ, :x, Space s x): orgmode queues
-- the write to the file (capture/init.lua) and the window close lands in
-- the agenda first. A synchronous redraw there runs the queued write
-- inside the close, where it cannot open the file, and the capture is
-- lost. So that redraw is deferred one tick, behind the write.
-- (The window you land in always gets a WinEnter or BufEnter right after
-- the capture's buffer goes, which queues the redraw behind the write.)
local capture_closed = false
vim.api.nvim_create_autocmd('BufWipeout', {
  group = group,
  callback = function(ev)
    if vim.b[ev.buf].org_capture then
      capture_closed = true
    end
  end,
})
local refresh_queued = false
vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
  group = group,
  callback = function()
    if not capture_closed then
      return refresh_agenda_if_outdated()
    end
    if not refresh_queued then
      refresh_queued = true
      vim.schedule(function()
        refresh_queued = false
        capture_closed = false
        refresh_agenda_if_outdated()
      end)
    end
  end,
})
vim.api.nvim_create_autocmd('FocusGained', {
  group = group,
  callback = function()
    agenda_outdated = true
    refresh_agenda_if_outdated()
  end,
})

local function open_day()
  require('orgmode').agenda:open_by_key('d')
end

-- What a plain launch shows until your day has drawn. Virtual text only, so
-- the start buffer stays empty and the agenda can still open in its place.
local splash_ns = vim.api.nvim_create_namespace('kit_splash')
local function splash(buf, lines, hl)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, splash_ns, 0, -1)
  local rest = {}
  for i = 2, #lines do
    table.insert(rest, { { '  ' .. lines[i], hl } })
  end
  vim.api.nvim_buf_set_extmark(buf, splash_ns, 0, 0, {
    virt_text = { { '  ' .. lines[1], hl } },
    virt_text_pos = 'overlay',
    virt_lines = rest,
  })
end

-- ============================================================================
--  STARTUP - a plain launch opens your day. Started from the kit folder (a
--  double-click) or your home folder (a new terminal), move to the org folder
--  first, so the file tree and finders start there. Started anywhere else (a
--  project), stay put. Then say out loud what did not load.
-- ============================================================================
local function report()
  if vim.g.colors_name ~= 'catppuccin-mocha' then
    note('catppuccin did not load; colors are the fallback theme')
  end
  if vim.fn.has('clipboard') == 0 then
    note('no clipboard tool found, so yank / paste stay inside Neovim'
      .. (is_win and ' (win32yank.exe should sit next to nvim.exe)' or ''))
  end
  if #problems == 0 then
    return
  end
  -- always two or more lines, so Neovim holds them on screen with a
  -- "Press ENTER" prompt instead of letting the agenda redraw wipe them
  local chunks = { { ('nvim kit: %d thing(s) did not load\n'):format(#problems), 'WarningMsg' } }
  for i, msg in ipairs(problems) do
    table.insert(chunks, { 'nvim kit: ' .. msg .. (i < #problems and '\n' or ''), 'WarningMsg' })
  end
  vim.api.nvim_echo(chunks, true, {})
end

vim.api.nvim_create_autocmd('VimEnter', {
  group = group,
  once = true,
  callback = function()
    if vim.fn.argc() == 0 then
      local cwd = vim.fn.getcwd()
      local home = vim.env.USERPROFILE or vim.env.HOME or ''
      -- (the kit folder only counts when a launcher pointed the config
      -- straight at it, nvim.cmd or nvim.command: with ~/.config/nvim linked
      -- to this folder the config path is that link, which would make
      -- ~/.config count)
      local launched = is_win or (vim.env.XDG_CONFIG_HOME ~= nil and same_dir(vim.env.XDG_CONFIG_HOME, kit_dir))
      local at_start = (launched and same_dir(cwd, kit_dir)) or (home ~= '' and same_dir(cwd, home))
        or (vim.env.HOME and same_dir(cwd, vim.env.HOME))
      if at_start and vim.fn.isdirectory(org_dir) == 1 then
        vim.cmd.cd(vim.fn.fnameescape(org_dir))
      end
      local buf = vim.api.nvim_get_current_buf()
      vim.opt_local.number = false
      vim.opt_local.relativenumber = false
      vim.opt_local.cursorline = false
      if org_ok then
        splash(buf, { 'Loading your day...' }, 'Comment')
        try('opening the agenda', open_day)
        -- a slow machine (antivirus reading every file) can take a while; if
        -- the day view still has not replaced this screen, say what to do
        vim.defer_fn(function()
          -- the agenda REUSES this empty buffer when it opens (same number),
          -- so check it is still the unnamed empty start buffer
          if vim.api.nvim_get_current_buf() == buf and vim.api.nvim_buf_get_name(buf) == '' and vim.bo[buf].filetype == '' then
            splash(buf, {
              'Your day has not opened yet.',
              'If nothing changes, press Space o a d to open it,',
              'and type :messages then Enter to see any error.',
            }, 'WarningMsg')
          end
        end, 20000)
      else
        splash(buf, {
          'Org mode did not load, so there is no agenda. The reason:',
          problems[1] or 'unknown (type :messages then Enter)',
          'Space ? still shows every key.',
        }, 'WarningMsg')
      end
    end
    -- after the agenda has drawn (it renders asynchronously)
    vim.defer_fn(report, 300)
  end,
})

-- ============================================================================
--  AGENDA SHIFT TAB - in the task lists (Space o a t / p) Shift Tab opens every
--  list when any is closed, else closes them all, like Shift Tab in an org
--  file. Each list then stays that way, as after Enter on its header (the
--  open_lists table in lua/kit/agenda.lua); while every list is open, one
--  that appears later (a first capture into an empty Inbox) opens too.
--  The other agenda views have no lists: there it changes nothing and says
--  so. Windows Terminal sends Shift Tab as ESC [ Z and binds only Ctrl
--  Shift Tab itself (microsoft/terminal
--  src/terminal/input/terminalInput.cpp, defaults.json);
--  Neovim reads ESC [ Z as Shift Tab (src/nvim/tui/termkey/driver-csi.c).
-- ============================================================================
local function toggle_all_lists()
  local look_mod = package.loaded['kit.agenda']
  local agenda = org_ok and look_mod and require('orgmode').agenda
  local heads = {} -- list key -> its header line, for lists with a fold
  for _, v in ipairs(agenda and agenda.views or {}) do
    local lines = v.kit_list and v.view and v.view.lines
    if lines and lines[1] and vim.fn.foldlevel(lines[1].line_nr) > 0 then
      heads[v.kit_list] = lines[1].line_nr
    end
  end
  if next(heads) == nil then
    local where = agenda and agenda.views and agenda.views[1] and agenda.views[1].kit_list
      and 'No list to open or close' or 'Shift Tab opens / closes the lists in Space o a t / p'
    vim.api.nvim_echo({ { where .. '. Nothing done.' } }, false, {})
    return
  end
  vim.wo.foldenable = true -- folding back on, if zi turned it off
  local any_closed = false
  for _, lnum in pairs(heads) do
    any_closed = any_closed or vim.fn.foldclosed(lnum) ~= -1
  end
  for key, lnum in pairs(heads) do
    local closed = vim.fn.foldclosed(lnum) ~= -1
    if any_closed and closed then
      vim.cmd(('%dfoldopen'):format(lnum))
    elseif not any_closed then
      vim.cmd(('%dfoldclose'):format(lnum))
    end
    look_mod.open_lists[key] = vim.fn.foldclosed(lnum) == -1
  end
  -- never left inside a closed list (a key there would act on a hidden task)
  local fold_start = vim.fn.foldclosed('.')
  if fold_start ~= -1 then
    vim.fn.cursor(fold_start, 1)
  end
end

vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'orgagenda',
  callback = function(ev)
    map('n', '<S-Tab>', toggle_all_lists, { buffer = ev.buf, desc = 'Open / close all task lists' })
    -- o: the task lists by file (Space o a t) <-> by priority (Space o a p)
    if package.loaded['kit.agenda'] then
      map('n', 'o', function()
        require('kit.agenda').flip_lists()
      end, { buffer = ev.buf, desc = 'Task lists: by file / by priority' })
    end
  end,
})
-- ============================================================================
--  (end of AGENDA SHIFT TAB)
-- ============================================================================

-- ============================================================================
--  MODES - the mode you are in, impossible to miss (lua/kit/mode.lua). The
--  bar at the bottom of the window says it in words on a color (NORMAL blue,
--  INSERT green, VISUAL mauve, REPLACE red, COMMAND peach, TERMINAL teal,
--  FIND peach in a finder or the Space ? popup, whose float has no bar: the
--  bar under it says it), with the file, [+] until it is saved, and Ln /
--  Col. Keys Neovim is still waiting on (Space o ...) show next to the
--  mode. The cursor line turns green while you type, a selection is
--  lavender. Esc in normal mode flashes the mode block and clears search
--  highlight.
--  Cursor shape (block / bar / underline) is sent as DECSCUSR (ESC [ n SP q).
--  Windows Terminal draws those (Microsoft's "Console Virtual Terminal
--  Sequences", Cursor Shape), and Neovim 0.12.5 sends them there: with no
--  $TERM it names a VT console "vtpcon" (src/nvim/os/os_win_console.c), and
--  its built-in vtpcon entry has the cursor-style codes
--  (src/nvim/tui/terminfo_builtin.h). Ghostty, and tmux on macOS, are on
--  Neovim's DECSCUSR list (src/nvim/tui/tui.c).
--  Kept last: it needs only the palette P, and nothing above depends on it.
-- ============================================================================
try('mode bar', function() require('kit.mode').setup(P) end)
-- ============================================================================
--  (end of MODES)
-- ============================================================================

-- ============================================================================
--  KEY HINTS - no timeout traps (lua/kit/clue.lua, on the vendored
--  mini.clue). After Space, g, z, [ or ], Ctrl w, or the first key of any
--  longer shortcut (cit, << in an org file, vd in the agenda), Neovim waits
--  for the next key as long as you like, instead of giving up after a second
--  and running what you typed as plain keys (Space o, a pause, then o opened
--  a new line). After 300 ms a small window at the bottom right lists what
--  can come next. Esc cancels, Backspace takes back a key, Enter runs a
--  shortcut that is also the start of longer ones (Space s). After Space,
--  a key that is no shortcut does nothing and says so.
--  Kept last: its triggers must be made after every other mapping.
-- ============================================================================
try('key hints', function()
  local ok, why = require('kit.clue').setup(P)
  if not ok then
    note('key hints: ' .. tostring(why) .. '; the hint window works, the extras (keys in the mode bar, "not a shortcut") are off')
  end
end)
-- ============================================================================
--  (end of KEY HINTS)
-- ============================================================================
