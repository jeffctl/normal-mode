-- Which mode you are in, impossible to miss. VS Code has no modes, so in
-- Neovim it is easy to type into the wrong one without noticing. Set up from
-- init.lua (MODES) with the kit's Catppuccin palette.
--
--   * The bar at the bottom of each window starts with the mode in words on
--     a solid color: NORMAL blue, INSERT green, VISUAL mauve, REPLACE red,
--     COMMAND peach, TERMINAL teal. Then the file, [+] while it has changes
--     not saved yet, and Ln / Col on the right. Other windows show just their
--     file, dimmed, so the bright block also marks the window you are in.
--   * Keys typed on the way to a longer one (Space o, on the way to Space o
--     a d) show next to the mode, in words, until Neovim runs them. So does
--     a count (3), an operator waiting for its motion (d), and while
--     selecting, how much is selected.
--   * The cursor line turns green while you type and red in replace mode;
--     a selection is lavender. The cursor's line number takes the mode color.
--   * The cursor is a block in normal mode, a bar while typing and an
--     underline in replace mode (and after d, c, y: waiting for a motion).
--   * Esc when you are already in normal mode flashes the mode block, so a
--     press never goes unseen, and clears search highlight like Ctrl c.
--   * A floating window (a finder, the Space ? popup, the spare mini.files
--     explorer) has no bar. While you are in one, the bar of the window it
--     opened over shows the mode and names the float: FIND (peach) in a
--     finder or the popup, where typing narrows the list; the mode itself
--     elsewhere. Neovim's own "-- INSERT --" also shows at the bottom there,
--     and Esc shows NORMAL there for a moment.
--   * The file tree (nvim-tree, Space ee) is a plain split with a bar of its
--     own, called "File tree".
--
-- No plugins; the bar is one Lua function that only reads state.
local M = {}

-- mode() first letter -> words, palette color, cursor line tint
local MODES = {
  n = { 'NORMAL', 'blue' },
  v = { 'VISUAL', 'mauve', 'visual' },
  V = { 'V-LINE', 'mauve', 'visual' },
  ['\22'] = { 'V-BLOCK', 'mauve', 'visual' },
  s = { 'SELECT', 'mauve', 'visual' },
  S = { 'S-LINE', 'mauve', 'visual' },
  ['\19'] = { 'S-BLOCK', 'mauve', 'visual' },
  i = { 'INSERT', 'green', 'insert' },
  R = { 'REPLACE', 'red', 'replace' },
  c = { 'COMMAND', 'peach' },
  r = { 'PROMPT', 'peach' }, -- "Press ENTER", "-- More --", a yes / no question
  ['!'] = { 'SHELL', 'teal' },
  t = { 'TERMINAL', 'teal' },
}

-- put in front of a window's own bar (the cheat sheet's), see setup()
M.BLOCK = "%{%v:lua.require'kit.mode'.block()%}"

local P -- the palette, from setup()
local flashing = false
local group = vim.api.nvim_create_augroup('kit_mode', { clear = true })

local function info(mode)
  return MODES[mode:sub(1, 1)] or MODES.n
end

-- a over base, like a color at `alpha` opacity on the background
local function blend(color, alpha)
  local function rgb(hex)
    return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  end
  local r1, g1, b1 = rgb(color)
  local r2, g2, b2 = rgb(P.base)
  local function mix(x, y)
    return math.floor(x * alpha + y * (1 - alpha) + 0.5)
  end
  return ('#%02x%02x%02x'):format(mix(r1, r2), mix(g1, g2), mix(b1, b2))
end

-- ---------------------------------------------------------------------------
--  Colors
-- ---------------------------------------------------------------------------
local base_hl = {} -- CursorLine / CursorLineNr as the color scheme set them
local tinted -- which tint is on now ('insert', 'visual', 'replace' or nil)

local function define_highlights()
  local set = vim.api.nvim_set_hl
  for _, color in ipairs({ 'blue', 'mauve', 'green', 'red', 'peach', 'teal' }) do
    set(0, 'KitMode_' .. color, { fg = P.base, bg = P[color], bold = true })
  end
  set(0, 'KitModeFlash', { fg = P.base, bg = P.text, bold = true })
  set(0, 'KitStatusKeys', { fg = P.text, bg = P.surface1, bold = true })
  set(0, 'KitStatusFile', { fg = P.text, bg = P.mantle, bold = true })
  set(0, 'KitStatusMod', { fg = P.peach, bg = P.mantle, bold = true })
  set(0, 'KitStatusHint', { fg = P.overlay1, bg = P.mantle })
  set(0, 'KitStatusRec', { fg = P.peach, bg = P.mantle, bold = true })
  set(0, 'KitStatusPos', { fg = P.subtext0, bg = P.surface0 })
  set(0, 'KitStatusFileNC', { fg = P.overlay1, bg = P.mantle })
  set(0, 'KitStatusModNC', { fg = P.overlay1, bg = P.mantle })
  for _, name in ipairs({ 'CursorLine', 'CursorLineNr', 'Visual' }) do
    base_hl[name] = vim.api.nvim_get_hl(0, { name = name, link = false })
  end
end

-- the cursor line (and its number) in the mode's color; back to the color
-- scheme's in normal mode. The agenda keeps its own cursor bar (winhighlight).
-- While selecting, Neovim does not draw the cursor line at all (so the
-- selection stays clear), so there the selection itself turns lavender.
local function tint(mode)
  local m = info(mode)
  local want = m[3]
  if want == tinted then
    return
  end
  tinted = want
  local set = vim.api.nvim_set_hl
  for name, spec in pairs(base_hl) do
    set(0, name, spec)
  end
  if not want then
    return
  end
  if want == 'visual' then
    set(0, 'Visual', vim.tbl_extend('force', base_hl.Visual, { bg = blend(P.lavender, 0.30) }))
  else
    local color = want == 'insert' and P.green or P.red
    set(0, 'CursorLine', vim.tbl_extend('force', base_hl.CursorLine, { bg = blend(color, 0.16) }))
  end
  set(0, 'CursorLineNr', vim.tbl_extend('force', base_hl.CursorLineNr, { fg = P[m[2]], bold = true }))
end

-- ---------------------------------------------------------------------------
--  The bar
-- ---------------------------------------------------------------------------
local function esc(s)
  return (s:gsub('%%', '%%%%'))
end

-- in a finder or the Space ? popup (mini.pick) Neovim is in normal mode,
-- but what you type narrows the list: it says FIND, not NORMAL
local FIND = { 'FIND', 'peach' }

-- the mode block for the window you are in (`m`: { words, color } instead
-- of the mode's own)
local function mode_block(m)
  m = m or info(vim.api.nvim_get_mode().mode)
  local hl = flashing and 'KitModeFlash' or ('KitMode_' .. m[2])
  return ('%%#%s# %s %%*'):format(hl, m[1])
end

-- the last window you were in that is not a float (see setup())
local last_win

-- `cur` (the current window by default) when it is a float (a finder, the
-- Space ? popup, the spare explorer, the date picker), and the window it
-- opened over: the one it sits on, or else the last one you were in. nil
-- otherwise, and for orgmode's hidden one-cell window that an agenda key
-- (t, +, Space o i s) edits the task file in for a moment.
local function float_over(cur)
  cur = cur or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(cur) then
    return nil
  end
  local config = vim.api.nvim_win_get_config(cur)
  if config.relative == '' or vim.b[vim.api.nvim_win_get_buf(cur)].org_tmp_edit_window then
    return nil
  end
  local under = config.relative == 'win' and config.win or last_win
  if under and under ~= cur and vim.api.nvim_win_is_valid(under)
    and vim.api.nvim_win_get_config(under).relative == '' then
    return cur, under
  end
end

-- what a float is, for the bar under it, by file type or buffer name
local FLOAT_NAMES = {
  minipick = 'Finder', minifiles = 'File explorer', ['minifiles-help'] = 'File explorer help',
  orgcalendar = 'Date picker',
}

-- 'showcmd' text in words. Neovim writes Space as <20> and Ctrl w as ^W
-- there; this reads "Space o", "Ctrl w", "3 d".
local function words(s)
  local out = {}
  local i = 1
  while i <= #s do
    local rest = s:sub(i)
    local tok, len
    if rest:sub(1, 4) == '<20>' then
      tok, len = 'Space', 4
    elseif rest:match('^%^[%u@%[%]%^_\\]') then
      tok, len = 'Ctrl ' .. rest:sub(2, 2):lower(), 2
    elseif rest:match('^<%x%x>') then
      tok, len = rest:sub(1, 4), 4
    else
      tok = vim.fn.strcharpart(rest, 0, 1)
      len = math.max(#tok, 1)
    end
    if tok:match('^%d$') and out[#out] and out[#out]:match('^%d+$') then
      out[#out] = out[#out] .. tok -- 12j is a count of 12, not 1 then 2
    else
      table.insert(out, tok)
    end
    i = i + len
  end
  return table.concat(out, ' ')
end

-- how much is selected, VS Code style: "3 lines", "12 chars", "3 x 4 block"
local function selection(mode)
  local c = mode:sub(1, 1)
  local l1, l2 = vim.fn.line('v'), vim.fn.line('.')
  local lines = math.abs(l2 - l1) + 1
  if c == '\22' or c == '\19' then
    local w = math.abs(vim.fn.virtcol('.') - vim.fn.virtcol('v')) + 1
    return ('%d x %d block'):format(lines, w)
  end
  if (c == 'v' or c == 's') and lines == 1 then
    local n = math.abs(vim.fn.charcol('.') - vim.fn.charcol('v')) + 1
    return n == 1 and '1 char' or n .. ' chars'
  end
  return lines == 1 and '1 line' or lines .. ' lines'
end

-- keys Neovim is still waiting on (from 'showcmd', which with showcmdloc =
-- statusline also redraws the bar on every key of a half-typed shortcut).
-- Normal mode and selecting only: typing, : and a terminal leave stale
-- letters there. After Space, g, z and the like the key hints (kit/clue.lua)
-- read the next keys themselves, so those come from there.
local function pending(win, mode)
  local clue = package.loaded['kit.clue']
  local hinted = clue and clue.pending()
  if hinted then
    return hinted
  end
  local c = mode:sub(1, 1)
  local visual = c == 'v' or c == 'V' or c == '\22' or c == 's' or c == 'S' or c == '\19'
  if c ~= 'n' and not visual then
    return nil
  end
  local ok, res = pcall(vim.api.nvim_eval_statusline, '%S', { winid = win })
  local s = ok and res.str or ''
  -- a mapping's own inner keys (~@ and bytes), seen while it runs: not typed
  s = s:gsub('~@.*$', '')
  -- while selecting, showcmd holds the selection size (5, 12-14, 3x4)
  if visual and (s == '' or s:match('^%d+$') or s:match('^%d+%-%d+$') or s:match('^%d+x%d+$')) then
    return nil, selection(mode)
  end
  if s == '' then
    return nil
  end
  return words(s)
end

local function keys_chip(keys)
  return keys and ('%#KitStatusKeys# ' .. esc(keys) .. ' ... %*') or ''
end

-- what the bar calls a buffer, plus a hint for the special ones (in parts:
-- a narrow bar drops the last part first, see render())
local function name_of(buf)
  local bo = vim.bo[buf]
  local name = vim.api.nvim_buf_get_name(buf)
  if bo.filetype == 'orgagenda' then
    return 'Agenda'
  elseif bo.filetype == 'NvimTree' then
    return 'File tree'
  elseif vim.b[buf].org_capture then
    return 'Capture', { 'Ctrl c saves (twice if typing)', 'Space o k throws it away' }
  elseif bo.buftype == 'help' then
    return 'Help: ' .. vim.fn.fnamemodify(name, ':t:r')
  elseif bo.buftype == 'terminal' then
    return 'Terminal'
  elseif bo.buftype == 'quickfix' then
    return 'Quickfix list'
  elseif name == '' then
    -- the blank screen a plain launch shows while your day loads: no name
    local blank = not bo.modified and vim.api.nvim_buf_line_count(buf) == 1
      and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ''
    return blank and '' or 'Untitled'
  end
  return vim.fn.fnamemodify(name, ':~:.')
end

-- The bar of the window a float opened over, while you are in the float
-- (floats have no bar): the mode, FIND in a finder or the Space ? popup,
-- and what the float is.
local function float_bar(float)
  local buf = vim.api.nvim_win_get_buf(float)
  local ft = vim.bo[buf].filetype
  local out = {}
  if ft == 'minipick' then
    table.insert(out, mode_block(FIND))
  else
    table.insert(out, mode_block() .. keys_chip((pending(float, vim.api.nvim_get_mode().mode))))
  end
  local bufname = vim.api.nvim_buf_get_name(buf)
  local name = FLOAT_NAMES[ft] or FLOAT_NAMES[vim.fs.basename(bufname)] or (bufname ~= '' and name_of(buf)) or ''
  if name ~= '' then
    table.insert(out, '%<%#KitStatusFile# ' .. esc(name))
  end
  table.insert(out, '%#StatusLine#%=')
  return table.concat(out)
end

local function render()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local active = win == vim.api.nvim_get_current_win()
  local float, under = float_over()
  if float and under == win then
    return float_bar(float)
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local bo = vim.bo[buf]
  local name, hint = name_of(buf)
  local file_buf = bo.buftype == ''
  local out = {}

  local hint_at, fill_at -- where the hint and the gap (%=) are in `out`
  if active then
    local mode = vim.api.nvim_get_mode().mode
    local keys, sel = pending(win, mode)
    table.insert(out, mode_block() .. keys_chip(keys))
    -- a bar too narrow is cut at %<: the hint when there is one, so the
    -- name and [+] stay; else the name, so the mode stays
    table.insert(out, (hint and '' or '%<') .. '%#KitStatusFile# ' .. esc(name))
    if file_buf and bo.modified then
      table.insert(out, '%#KitStatusMod# [+]')
    elseif file_buf and (bo.readonly or not bo.modifiable) then
      table.insert(out, '%#KitStatusHint# [read-only]')
    end
    if hint then
      table.insert(out, '')
      hint_at = #out
    end
    table.insert(out, '%#StatusLine#%=')
    fill_at = #out
    local rec = vim.fn.reg_recording()
    if rec ~= '' then
      table.insert(out, '%#KitStatusRec#recording @' .. esc(rec) .. '  ')
    end
    if sel then
      table.insert(out, '%#KitStatusHint#' .. sel .. '  ')
    end
  else
    table.insert(out, '%<%#KitStatusFileNC# ' .. esc(name))
    if file_buf and bo.modified then
      table.insert(out, '%#KitStatusModNC# [+]')
    end
    table.insert(out, '%#StatusLineNC#%=')
  end
  if bo.filetype ~= 'orgagenda' and name ~= '' then
    table.insert(out, (active and '%#KitStatusPos#' or '%#StatusLineNC#') .. ' Ln %l, Col %v ')
  end
  -- as much of the hint as fits, whole parts first ("Ctrl c saves ..."
  -- without "Space o k ..." at 80 columns); %< cuts the rest
  -- (measured without the gap, which fills whatever width it is given)
  if hint_at then
    local width = vim.api.nvim_win_get_width(win)
    for n = #hint, 1, -1 do
      out[hint_at] = '%<%#KitStatusHint#   ' .. esc(table.concat(hint, '   ', 1, n))
      local measure = vim.list_slice(out)
      measure[fill_at] = ''
      local ok, res = pcall(vim.api.nvim_eval_statusline, table.concat(measure), { winid = win, maxwidth = 1000 })
      if n == 1 or (ok and res.width <= width) then
        break
      end
    end
  end
  return table.concat(out)
end

function M.statusline()
  local ok, s = pcall(render)
  return ok and s or ' %f %m%=Ln %l, Col %v '
end

-- the mode block (and keys being waited on) alone, for a window with a bar
-- of its own (the cheat sheet); empty when that window is not the one you
-- are in, or the one under the float you are in
function M.block()
  local win = vim.api.nvim_get_current_win() -- inside %{}: the bar's window
  local actual = tonumber(vim.g.actual_curwin or -1)
  local ok, s = pcall(function()
    if win == actual then
      return mode_block() .. keys_chip((pending(win, vim.api.nvim_get_mode().mode)))
    end
    -- in a float opened over this window (Space ? pressed here): its mode
    local float, under = float_over(actual)
    if float and under == win then
      return mode_block(vim.bo[vim.api.nvim_win_get_buf(float)].filetype == 'minipick' and FIND or nil)
    end
    return ''
  end)
  return ok and s or ''
end

-- ---------------------------------------------------------------------------
--  Esc in normal mode
-- ---------------------------------------------------------------------------
local flash_timer

local function in_float()
  return vim.api.nvim_win_get_config(0).relative ~= ''
end

local function flash()
  flashing = true
  -- a floating window has no bar: say it at the bottom instead
  local float = in_float()
  -- redraw once the Esc mapping has finished (drawn from inside it, the bar
  -- would show the mapping's own keys as half-typed ones)
  vim.schedule(function()
    pcall(vim.cmd.redrawstatus)
    if float then
      vim.api.nvim_echo({ { ' NORMAL ', 'KitModeFlash' } }, false, {})
    end
  end)
  flash_timer = flash_timer or vim.uv.new_timer()
  flash_timer:stop()
  flash_timer:start(250, 0, vim.schedule_wrap(function()
    flashing = false
    pcall(vim.cmd.redrawstatus)
    if float and in_float() and vim.api.nvim_get_mode().mode == 'n' then
      vim.api.nvim_echo({ { '' } }, false, {})
    end
  end))
end
M.flash = flash -- also when Esc cancels a key hint (kit/clue.lua)

-- ---------------------------------------------------------------------------
function M.setup(palette)
  P = palette
  define_highlights()

  local o = vim.o
  o.laststatus = 2 -- a bar under every window
  o.showmode = false -- the bar says it; no "-- INSERT --" below it too
  o.showcmd = true
  o.showcmdloc = 'statusline'
  -- block / bar while typing / underline in replace mode and while an
  -- operator waits for its motion. (Neovim's default, spelled out: the
  -- terminal draws it. Windows Terminal takes these DECSCUSR codes, and
  -- Neovim sends them there: see the MODES note in init.lua.)
  o.guicursor = 'n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20,t:block-blinkon500-blinkoff500-TermCursor'
  o.statusline = "%!v:lua.require'kit.mode'.statusline()"

  vim.keymap.set('n', '<Esc>', function()
    vim.cmd.nohlsearch()
    flash()
  end, { desc = 'Already in normal mode: flash the bar, clear search' })

  vim.api.nvim_create_autocmd('ModeChanged', {
    group = group,
    callback = function()
      tint(vim.v.event.new_mode or vim.api.nvim_get_mode().mode)
    end,
  })
  -- the window a float opens over, for its bar (float_over)
  last_win = vim.api.nvim_get_current_win()
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_config(win).relative == '' then
        last_win = win
      end
    end,
  })
  -- ...except in a floating window (a finder, the spare mini.files
  -- explorer): it has no bar (the bar under it says the mode, float_bar),
  -- so Neovim's own "-- INSERT --" shows too, next to where you type.
  -- Typing in the explorer renames and creates files once it syncs.
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufWinEnter', 'ModeChanged' }, {
    group = group,
    callback = function()
      local float = in_float()
      if vim.o.showmode ~= float then
        vim.o.showmode = float
      end
    end,
  })
  -- a color scheme loaded later wipes these; put them back over it
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      tinted = nil
      define_highlights()
      tint(vim.api.nvim_get_mode().mode)
    end,
  })
  -- "recording @q" (q starts a macro): the bar shows it, so redraw it when
  -- that starts and stops (still set during RecordingLeave, hence later)
  vim.api.nvim_create_autocmd({ 'RecordingEnter', 'RecordingLeave' }, {
    group = group,
    callback = function()
      vim.schedule(function() pcall(vim.cmd, 'redrawstatus!') end)
    end,
  })
  -- the cheat sheet brings its own bar ("keys  q closes ..."); put the mode
  -- block in front of it once it is set (right after the window opens)
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(ev)
      if vim.bo[ev.buf].filetype ~= 'kitcheat' then
        return
      end
      vim.schedule(function()
        for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
          local own = vim.api.nvim_get_option_value('statusline', { win = win, scope = 'local' })
          if own ~= '' and not own:find(M.BLOCK, 1, true) then
            vim.api.nvim_set_option_value('statusline', M.BLOCK .. own, { win = win, scope = 'local' })
          end
        end
      end)
    end,
  })
end

return M
