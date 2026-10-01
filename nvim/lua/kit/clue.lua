-- Key hints: no more half-typed shortcuts running as edits. Set up from
-- init.lua (KEY HINTS) with the kit's Catppuccin palette, on top of the
-- vendored mini.clue (pack/kit/start/mini.clue).
--
--   * Space, g, z, [ and ], Ctrl w, and the first key of every other
--     shortcut longer than one key (orgmode's cit, << and >s in an org file,
--     vd / vw in the agenda, ...) start "waiting for the next key". Neovim
--     then waits as long as you like. Before, it gave up after a second and
--     ran what you had typed as plain keys: Space o, a pause, and o opened a
--     new line, so the rest of the shortcut was typed into the file.
--   * After 300 ms a small window in the bottom right corner lists the keys
--     that can come next and what they do; a + means more keys follow.
--     Esc cancels (nothing happens, the mode bar flashes), Backspace takes
--     back one key, Ctrl d / Ctrl u scroll a long list.
--   * After Space, a key that is not part of a shortcut does nothing and
--     says so, instead of running Space (cursor right) and then that key.
--   * Space s is a shortcut (replace the word) and also the start of Space
--     s v and friends: there, Enter runs it (the window has an Enter row).
--     Where Enter is itself the next key of a shortcut (Space Enter in an
--     org file) or of a Vim command (z Enter), it is typed as that key.
--   * The keys typed so far show in the mode bar ("Space o ...").
--   * In the agenda the window leaves out the keys that edit text there
--     (Space d, Space s, Space Space); arrows read "Down arrow", not
--     "<Down>".
--   * All of this also while a macro records (q then a letter), where
--     mini.clue alone would switch the hints off: Space o, a pause and Esc
--     then typed a new line into the file. The macro holds each key once.
--
-- How it works: mini.clue makes each first key a buffer-local <nowait>
-- mapping that then reads the next keys itself, so 'timeoutlen' no longer
-- matters. Its docs ask for two things, both done here: such a trigger has
-- to be the NEWEST buffer-local mapping for its key (orgmode sets its
-- mappings after the FileType event, so the triggers are made again after
-- that), and only buffers in the buffer list get triggers by default (the
-- agenda, a capture and the cheat sheet are not listed; here every buffer
-- gets them). For anything still not covered (text objects after d or v,
-- say), 'timeout' is off, so Neovim itself waits for the next key.
-- The mode bar, the "not a shortcut" check, Esc's flash, the Enter run of
-- Space s and the tidier orgmode and file tree names reach into mini.clue's
-- internals (the local table H, found through the debug library). If a
-- newer mini.clue changes them, those extras switch off and startup says
-- so; the hints themselves keep working.
local M = {}

local P -- the palette, from setup()
local H -- mini.clue's internals, when found (see hook())
local group = vim.api.nvim_create_augroup('kit_clue', { clear = true })

local DELAY = 300 -- ms before the window shows
local MAX_W = 60 -- widest the window gets (longer text ends in ...)

-- mini.clue's own trigger mappings carry this description
local TRIGGER_DESC = '^Query keys after '

-- the leader in <Key> notation ("<Space>")
local function leader()
  return vim.fn.keytrans(vim.g.mapleader or '\\')
end

-- triggers in every buffer. Others come from the mappings (see scan()).
local FIXED = {
  { mode = { 'n', 'x' }, keys = '<Leader>' },
  { mode = { 'n', 'x' }, keys = 'g' },
  { mode = { 'n', 'x' }, keys = 'z' },
  { mode = { 'n', 'x' }, keys = '[' },
  { mode = { 'n', 'x' }, keys = ']' },
  { mode = 'n', keys = '<C-w>' },
}

-- names for the groups after the leader, shown where the group has keys.
-- (s is also a shortcut of its own: Enter runs it.)
local GROUPS = {
  f = '+Find a file, copy path',
  e = '+File tree',
  p = '+Recent files',
  r = '+Restart',
  s = '+Splits (Enter: replace word)',
  t = '+Tabs',
  o = '+Org: agenda, capture, tasks',
  oi = '+Start date, deadline, ...',
  ox = '+Clock, effort',
  ol = '+Links',
  on = '+Notes',
  ob = '+Code blocks',
  od = '+Date type',
  op = '+Properties: START, any', -- in an org file, a capture, the agenda
}
-- better names for a few single shortcuts
local RENAME = {
  oa = 'Agenda: day, week, tasks, done...',
  oc = 'Capture: a task (dated too), a note',
  ok = 'Throw it away (no save)', -- in a capture or a note
}

-- In the agenda (it can not be edited) the hints leave out the leader keys
-- that edit text or run the file as code: Space d, Space s (replace the
-- word; Space s v and the other split keys stay) and Space Space. Pressed
-- there anyway, they say they are not a shortcut and do nothing.
local AGENDA_HIDE = { n = { 'd', 's', '<Leader>' }, x = { 'd' } }

-- "n<Space>d" and so on -> true, for this buffer
local function hidden_keys(buf)
  local hide = {}
  if vim.bo[buf].filetype == 'orgagenda' then
    local lead = leader()
    for mode, list in pairs(AGENDA_HIDE) do
      for _, k in ipairs(list) do
        hide[mode .. lead .. (k == '<Leader>' and lead or k)] = true
      end
    end
  end
  return hide
end

-- the hint's key column: arrows in words, not "<Down>"
local ARROWS = { ['<Down>'] = 'Down arrow', ['<Up>'] = 'Up arrow', ['<Left>'] = 'Left arrow', ['<Right>'] = 'Right arrow' }

-- ---------------------------------------------------------------------------
--  Keys as text
-- ---------------------------------------------------------------------------
-- "<Space>o<lt>" -> { "<Space>", "o", "<lt>" }
local function split_keys(s)
  local out, i = {}, 1
  while i <= #s do
    local k = s:match('^%b<>', i) or vim.fn.strcharpart(s:sub(i), 0, 1)
    if k == '' then
      break
    end
    table.insert(out, k)
    i = i + #k
  end
  return out
end

local NAMES = {
  ['<Space>'] = 'Space', ['<lt>'] = '<', ['<CR>'] = 'Enter', ['<Esc>'] = 'Esc',
  ['<BS>'] = 'Backspace', ['<Tab>'] = 'Tab', ['<Bslash>'] = '\\', ['<Bar>'] = '|',
}

-- <Key> notation in words: "<Space>oi" -> "Space o i", "<C-W>" -> "Ctrl w"
function M.words(s)
  local out = {}
  for _, k in ipairs(split_keys(s)) do
    local name = NAMES[k]
    if not name and k:match('^<.+>$') then
      name = k:sub(2, -2):gsub('^([CMAS])%-(.+)$', function(mod, key)
        local what = ({ C = 'Ctrl', M = 'Alt', A = 'Alt', S = 'Shift' })[mod]
        return what .. ' ' .. (#key == 1 and key:lower() or key)
      end)
    end
    table.insert(out, name or k)
  end
  return table.concat(out, ' ')
end

-- a mapping's keys in <Key> notation
local function lhs_of(m)
  return vim.fn.keytrans(m.lhsraw or vim.api.nvim_replace_termcodes(m.lhs, true, true, true))
end

-- ---------------------------------------------------------------------------
--  Which keys start a longer shortcut, per buffer
-- ---------------------------------------------------------------------------
local function fixed_keys(mode)
  local set = {}
  for _, t in ipairs(FIXED) do
    local modes = type(t.mode) == 'table' and t.mode or { t.mode }
    if vim.tbl_contains(modes, mode) then
      set[t.keys == '<Leader>' and leader() or vim.fn.keytrans(vim.keycode(t.keys))] = true
    end
  end
  return set
end

-- every mapping (global and this buffer's) in n and x mode, <Key> notation
-- -> description; mini.clue's own triggers and <Plug> names left out
local function mappings(buf, mode)
  local all = {}
  for _, list in ipairs({ vim.api.nvim_get_keymap(mode), vim.api.nvim_buf_get_keymap(buf, mode) }) do
    for _, m in ipairs(list) do
      local lhs = lhs_of(m)
      if not (m.desc or ''):match(TRIGGER_DESC) and not lhs:match('^<Plug>') and not lhs:match('^<SNR>') then
        all[lhs] = m.desc or ''
      end
    end
  end
  return all
end

-- this buffer's extra triggers, group names and Enter rows
local function scan(buf)
  local triggers, clues, groups = {}, {}, {}
  local lead = leader()
  local hide = hidden_keys(buf)
  for _, mode in ipairs({ 'n', 'x' }) do
    local maps = mappings(buf, mode)
    local fixed = fixed_keys(mode)
    -- text objects (vih, dah) are mapped for selecting and after d / c / y
    local objects = mode == 'x' and mappings(buf, 'o') or {}
    local seen = {}
    for lhs, desc in pairs(maps) do
      local keys = split_keys(lhs)
      local first = keys[1]
      -- the first key of a longer one. Not when that key is a shortcut by
      -- itself (a trigger would hide it), and not the start of a text object
      -- after v (i, a, O): Neovim waits for the rest of those anyway.
      if #keys > 1 and not fixed[first] and not seen[first] and maps[first] == nil
        and not (mode == 'x' and (first == 'i' or first == 'a' or objects[lhs])) then
        seen[first] = true
        table.insert(triggers, { mode = mode, keys = first })
      end
      -- a leader shortcut that also starts longer ones (Space s): Enter row
      if vim.startswith(lhs, lead) and not hide[mode .. lhs] then
        for other in pairs(maps) do
          if #other > #lhs and vim.startswith(other, lhs) then
            table.insert(clues, { mode = mode, keys = lhs .. '<CR>', desc = desc })
            break
          end
        end
      end
    end
    -- group names, where the group has keys here
    for suffix, name in pairs(GROUPS) do
      local prefix = lead .. suffix
      if hide[mode .. prefix] then
        name = name:gsub(' %(Enter: .-%)$', '') -- "+Splits" in the agenda
      end
      for other in pairs(maps) do
        if #other > #prefix and vim.startswith(other, prefix) then
          table.insert(clues, { mode = mode, keys = prefix, desc = name })
          groups[mode .. prefix] = name
          break
        end
      end
    end
    for suffix, name in pairs(RENAME) do
      if maps[lead .. suffix] then
        groups[mode .. lead .. suffix] = name
      end
    end
  end
  return triggers, clues, groups, hide
end

-- make (again) this buffer's triggers, after all its other mappings
local function ensure(buf)
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    return
  end
  -- (off when turned off by hand, or by mini.clue while a macro records
  -- if the kit could not keep them on then: see setup)
  if vim.g.miniclue_disable or vim.bo[buf].buftype == 'prompt' then
    return
  end
  local triggers, clues, groups, hide = scan(buf)
  -- off with the old list, on with the new one
  MiniClue.disable_buf_triggers(buf)
  vim.b[buf].miniclue_config = { triggers = triggers, clues = clues }
  vim.b[buf].kit_clue_groups = groups
  vim.b[buf].kit_clue_hide = hide
  MiniClue.enable_buf_triggers(buf)
end

local function ensure_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    pcall(ensure, buf)
  end
end

-- ---------------------------------------------------------------------------
--  The window
-- ---------------------------------------------------------------------------
local function define_highlights()
  local set = vim.api.nvim_set_hl
  -- solid: every part on the float background (mantle), no blending
  set(0, 'MiniClueBorder', { fg = P.blue, bg = P.mantle })
  set(0, 'MiniClueTitle', { fg = P.base, bg = P.blue, bold = true })
  set(0, 'MiniClueNextKey', { fg = P.sapphire, bg = P.mantle, bold = true })
  set(0, 'MiniClueNextKeyWithPostkeys', { fg = P.peach, bg = P.mantle, bold = true })
  set(0, 'MiniClueDescSingle', { fg = P.text, bg = P.mantle })
  set(0, 'MiniClueDescGroup', { fg = P.lavender, bg = P.mantle })
  set(0, 'MiniClueSeparator', { fg = P.surface1, bg = P.mantle })
end

-- keys typed so far, in words ("Space o"), while waiting for the next one
function M.pending()
  if not H or type(H.state) ~= 'table' or type(H.state.query) ~= 'table' or #H.state.query == 0 then
    return nil
  end
  return M.words(vim.fn.keytrans(table.concat(H.state.query)))
end

local FOOTER = ' Esc cancels '

-- as wide as its text (up to MAX_W), titled with the keys so far in words
local function window_config(buf)
  local title = M.pending()
  local width = #FOOTER + 2
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 1)
  end
  if title then
    width = math.max(width, vim.fn.strdisplaywidth(title) + 4)
  end
  local config = {
    width = math.min(width, MAX_W, vim.o.columns - 4),
    footer = FOOTER,
    footer_pos = 'right',
  }
  if title then
    config.title = ' ' .. title .. ' '
  end
  return config
end

-- ---------------------------------------------------------------------------
--  The extras that need mini.clue's internals
-- ---------------------------------------------------------------------------
local function redraw_bar()
  pcall(vim.cmd, 'redrawstatus')
end

local function flash_bar()
  local mode = package.loaded['kit.mode']
  if mode and mode.flash then
    pcall(mode.flash)
  end
end

local function say(text)
  vim.api.nvim_echo({ { text, 'WarningMsg' } }, false, {})
end

local CR = vim.keycode('<CR>') -- Enter, as mini.clue reads it

-- the mapping for these keys in this mode, or nil
local function mapping_for(keys, mode)
  local ok, m = pcall(vim.fn.maparg, vim.fn.keytrans(keys), mode, false, true)
  if ok and type(m) == 'table' and next(m) ~= nil and not (m.desc or ''):match(TRIGGER_DESC) then
    return m
  end
end

-- also the start of a longer mapping (Space s, and Space s v)?
local function starts_longer(keys, mode)
  local lhs = vim.fn.keytrans(keys)
  for other in pairs(mappings(vim.api.nvim_get_current_buf(), mode)) do
    if #other > #lhs and vim.startswith(other, lhs) then
      return true
    end
  end
  return false
end

local function hook()
  local ok, found = pcall(function()
    for i = 1, 60 do
      local name, value = debug.getupvalue(MiniClue.enable_buf_triggers, i)
      if name == nil then
        return nil
      end
      if name == 'H' then
        return value
      end
    end
  end)
  if not ok or type(found) ~= 'table' or type(found.state) ~= 'table' then
    return false, 'mini.clue internals not found'
  end
  for _, name in ipairs({ 'state_advance', 'state_reset', 'state_exec', 'clues_get_all', 'clues_to_buffer_content', 'getcharstr' }) do
    if type(found[name]) ~= 'function' then
      return false, 'mini.clue has no ' .. name
    end
  end
  H = found

  -- the mode bar shows the keys so far: redraw it as each key comes in
  -- (Neovim does not redraw while mini.clue waits for a key)
  local advance = H.state_advance
  H.state_advance = function(...)
    redraw_bar()
    return advance(...)
  end

  -- Esc (or Ctrl c) while waiting: nothing runs; flash the bar like Esc in
  -- normal mode, so the press is seen
  local cancelled = false
  local last_key -- the key just read, for Enter (see state_exec below)
  local getcharstr = H.getcharstr
  H.getcharstr = function(...)
    local key = getcharstr(...)
    cancelled = key == nil
    last_key = key
    return key
  end
  -- (not when the keys run: what they open, orgmode's agenda menu say,
  -- waits for a key, and a redraw then would wipe it off the screen. The
  -- keys running redraw the bar anyway.)
  local running = false
  local reset = H.state_reset
  H.state_reset = function(...)
    local was_waiting = #H.state.query > 0
    local res = reset(...)
    if was_waiting and not running then
      vim.schedule(redraw_bar)
      if cancelled then
        cancelled = false
        flash_bar()
      end
    end
    return res
  end

  -- While a macro records (q then a letter) the hints stay on (setup turns
  -- off mini.clue's rule that switches them off then). The macro gets the
  -- keys you press; what mini.clue then types for you (the same keys) goes
  -- in as not typed, so the macro holds them once, not twice. (Replaying a
  -- macro through the hints works: mini.clue's own note, Neovim 0.10+.)
  local function untyped_while_recording(fn, ...)
    if vim.fn.reg_recording() == '' then
      return fn(...)
    end
    local feedkeys = vim.api.nvim_feedkeys
    vim.api.nvim_feedkeys = function(keys, mode, escape_ks)
      return feedkeys(keys, ((mode or ''):gsub('t', '')), escape_ks)
    end
    local ok, res = pcall(fn, ...)
    vim.api.nvim_feedkeys = feedkeys
    if not ok then
      error(res, 0)
    end
    return res
  end

  -- run what was typed. After Space, only a real shortcut runs: anything
  -- else would be Space (cursor right) plus plain keys, often an edit.
  local exec = H.state_exec
  local redraw_queued = false
  local function run_keys(...)
    local trigger = H.state.trigger
    local keys = table.concat(H.state.query)
    local is_leader = trigger and vim.fn.keytrans(trigger.keys) == leader()
    -- Enter while waiting: mini.clue runs the keys so far and drops the
    -- Enter. Keep it when it belongs to the shortcut: Space Enter in an org
    -- file (new heading below, orgmode's <Leader><CR>), or a key Neovim
    -- itself reads with Enter after it (z Enter). Space s Enter still runs
    -- Space s: its Enter row is a hint, not a mapping.
    local enter = last_key == CR
    last_key = nil
    if enter and trigger and #keys > 0
      and (mapping_for(keys .. CR, trigger.mode) or (not is_leader and not mapping_for(keys, trigger.mode))) then
      table.insert(H.state.query, CR)
      keys = keys .. CR
    end
    if is_leader and #keys > 0 then
      local hidden = (vim.b.kit_clue_hide or {})[trigger.mode .. vim.fn.keytrans(keys)]
      if hidden or not mapping_for(keys, trigger.mode) then
        local more = false
        for k in pairs(H.state.clues or {}) do
          if #k > #keys then
            more = true
            break
          end
        end
        local typed = M.words(vim.fn.keytrans(keys))
        reset()
        vim.schedule(redraw_bar)
        say(more and (typed .. ' needs one more key. Nothing done.') or (typed .. ' is not a shortcut. Nothing done.'))
        return
      end
      -- Space s alone, when Space s v also exists: Neovim would wait for a
      -- key after it ('timeout' is off). <Ignore> right after it tells
      -- Neovim no more keys are coming; it is then dropped.
      if starts_longer(keys, trigger.mode) then
        vim.api.nvim_feedkeys(vim.keycode('<Ignore>'), 'mit', false)
      end
    end
    running = true
    local ok, res = pcall(exec, ...)
    running = false
    -- and once the keys have run, redraw the bar, whatever they did: one
    -- that ends in an error (Space s x on the last window, E444) redraws
    -- nothing, and the bar kept "Space s ...". SafeState comes when they
    -- are done, and not while what they opened waits for a key (orgmode's
    -- agenda menu: see above).
    if not redraw_queued then
      redraw_queued = true
      vim.api.nvim_create_autocmd('SafeState', {
        group = group,
        once = true,
        callback = function()
          redraw_queued = false
          redraw_bar()
        end,
      })
    end
    if not ok then
      error(res, 0)
    end
    return res
  end
  H.state_exec = function(...)
    return untyped_while_recording(run_keys, ...)
  end

  -- orgmode names its keys "org set tags" and so on: under Space o that
  -- "org" says nothing, so "Set tags". The file tree's keys all start
  -- "nvim-tree: " the same way, so "Copy Absolute Path". Group names win
  -- over a shortcut's own name (Space s: "+Splits (Enter: replace word)").
  local get_all = H.clues_get_all
  H.clues_get_all = function(mode)
    local res = get_all(mode)
    for _, data in pairs(res) do
      if type(data.desc) == 'string' and data.desc:match('^org ') then
        local rest = data.desc:sub(5)
        data.desc = rest:sub(1, 1):upper() .. rest:sub(2)
      elseif type(data.desc) == 'string' and data.desc:match('^nvim%-tree: ') then
        data.desc = data.desc:sub(12)
      end
    end
    for key, name in pairs(vim.b.kit_clue_groups or {}) do
      if key:sub(1, 1) == mode then
        local data = res[vim.keycode(key:sub(2))]
        if data then
          data.desc = name
        end
      end
    end
    -- (the agenda's edit-only keys: see AGENDA_HIDE. One that also names a
    -- group stays as that group: "+Splits")
    local groups = vim.b.kit_clue_groups or {}
    for key in pairs(vim.b.kit_clue_hide or {}) do
      if key:sub(1, 1) == mode and not groups[key] then
        res[vim.keycode(key:sub(2))] = nil
      end
    end
    return res
  end

  -- arrows in the key column in words ("Down arrow"), the column as wide
  -- as its widest key again
  local to_content = H.clues_to_buffer_content
  H.clues_to_buffer_content = function(...)
    local res = to_content(...)
    local width = 0
    for _, line in ipairs(res) do
      local key = line.next_key:gsub(' +$', '')
      line.next_key = ARROWS[key] or (key ~= '' and key) or line.next_key
      width = math.max(width, vim.fn.strchars(line.next_key))
    end
    for _, line in ipairs(res) do
      line.next_key = line.next_key .. string.rep(' ', width - vim.fn.strchars(line.next_key))
    end
    return res
  end
  return true
end

-- ---------------------------------------------------------------------------
function M.setup(palette)
  P = palette
  local clue = require('mini.clue')
  clue.setup({
    triggers = FIXED,
    clues = {
      clue.gen_clues.g(),
      clue.gen_clues.z(),
      clue.gen_clues.square_brackets(),
      clue.gen_clues.windows(),
    },
    window = { delay = DELAY, config = window_config, scroll_down = '<C-d>', scroll_up = '<C-u>' },
  })
  -- Neovim itself: wait for the next key of a mapping as long as it takes,
  -- for the few multi-key mappings no trigger covers (text objects after d
  -- or v). Key codes (Esc, Alt + a key) still use the short 'ttimeoutlen'.
  vim.o.timeout = false

  define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = define_highlights,
  })

  -- triggers again after each buffer's own mappings: those come with its
  -- file type (orgmode maps right after it), so a moment later
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'FileType' }, {
    group = group,
    callback = function(ev)
      vim.schedule(function()
        pcall(ensure, ev.buf)
      end)
    end,
  })
  ensure_all()

  local ok, why = hook()
  if ok then
    -- the hints stay on while a macro records: with them off, 'timeout' off
    -- made Neovim wait after Space o with no hint, and Esc then ran Space,
    -- o (a new line) and the rest as plain keys, into the file. The macro
    -- still records each key once (untyped_while_recording, in hook()).
    pcall(vim.api.nvim_clear_autocmds, { group = 'MiniClue', event = { 'RecordingEnter', 'RecordingLeave' } })
  else
    -- mini.clue's rule then stands: triggers off while a macro records, and
    -- back on after in listed buffers only; put them back everywhere
    vim.api.nvim_create_autocmd('RecordingLeave', {
      group = group,
      callback = function()
        vim.schedule(ensure_all)
      end,
    })
  end
  return ok, why
end

return M
