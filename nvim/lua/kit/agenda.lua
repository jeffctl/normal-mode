-- The kit's agenda look. orgmode works out what is due when; this decides how
-- it reads, after Emacs org-mode's agenda:
--
--   * every row has the same columns, so nothing floats:
--       when         state       pri  title
--       10:00        TODO        · A  Standup                (at a time)
--       due          TODO             Expense report         (deadline today)
--       29d ago      TODO             Pay the invoice        (deadline 29 days ago)
--       in 3d        TODO             Pool maintenance       (deadline in 3 days)
--       in 1d 10:00  TODO             Budget review          (starts tomorrow at 10:00)
--       12d          TODO             Tidy the shed          (started 12 days ago, dim)
--       day 2/3                       Conference             (a stretch of days)
--   * a day shows its hours (08:00 to 20:00) and a "now" line: things with no
--     time first, then the hours
--   * SCHEDULED is a START date, never a due date. Once it has passed the task
--     has started: it is never late and never under Overdue. With a DEADLINE,
--     the deadline says where it goes ("in 5d" under Coming up, however far
--     off, "due", or "3d ago" under Overdue once the deadline itself passed).
--     Without one, today lists it once under Started, oldest start first. A
--     missed repeating SCHEDULED counts as started too
--   * today pulls overdue, coming-up and started work out under their own
--     headings. A missed repeating DEADLINE counts from the date it was
--     missed, like Emacs org-mode does, instead of looking on time
--   * Coming up is what is 1 to 14 days ahead, the soonest first: deadlines
--     (orgmode warns for those), and the start dates (SCHEDULED) and
--     appointments (a plain date, Space o i .) of open tasks, which orgmode
--     shows on their own day only, so tomorrow's meeting was nowhere on
--     today. They read "in 3d", with the time when it fits ("in 3d 10:00").
--     A repeating appointment counts from its next time. A start date more
--     than 14 days ahead is not in the day view yet (the week, the month and
--     Space o a t show it)
--   * an open TODO whose plain date (Space o i .) has passed is overdue too;
--     orgmode alone only carries SCHEDULED and DEADLINE forward
--   * the day view (Space o a d) ends with Completed: what you closed in the
--     last 14 days, the newest close first ("today", "3d ago")
--   * a task with both a SCHEDULED and a DEADLINE shows once (Emacs org-mode's
--     skip-scheduled-if-deadline-is-shown; before its start day, the
--     deadline's "in 3d" warning waits, like skip-prewarning-if-scheduled,
--     and Coming up lists the task by its start date)
--   * a task has one row on today: a deadline row or a row of today itself
--     comes before an appointment still ahead, and that before Started
--   * a week or a month shows a scheduled task on its start day only, not
--     again on today
--   * a week runs Monday to Sunday, wherever you jump to, and keeps its empty
--     days
--   * the file / category column is gone, and a date at the front of a title
--     ("2026-06-22 QA ...", as some apps name things) is hidden: the row already
--     says when. The file keeps both.
--
-- Rows keep orgmode's own data, so every agenda key (t, +, Enter, Tab, /,
-- f / b, vw ...) works as before; only the text is new. To get there this
-- replaces a few functions inside orgmode, which ties it to the pinned orgmode
-- commit (the README). If a newer orgmode renames them, setup() returns the
-- reason, and if one of them errors while drawing, the originals go back in;
-- either way orgmode's own agenda shows instead.
local M = {}

-- the "To do" block with this header lists only tasks with no date at all;
-- dated ones already show on their day, as overdue, coming up or started
M.UNDATED = 'To do (no date)'

-- the header of the Done view (Space o a c): every task in a done state,
-- grouped by the day it was closed
M.DONE = 'Done, newest first'

local function is_done_view(view)
  return view.header == M.DONE
end

-- the last block of the day view (Space o a d): what you finished in the
-- last COMPLETED_DAYS days, the newest close first. Change the number here
-- to see further back; Space o a c has everything.
M.COMPLETED = 'Completed'
M.COMPLETED_DAYS = 14

local function is_completed_block(view)
  return view.header == M.COMPLETED
end

-- called if the look is switched off while running (init.lua renames the
-- "To do (no date)" block and the Done view then: their filter and order go
-- too)
M.on_fail = nil

local W_WHEN = 11 -- widest: "10:00-11:30", "until 12:00", "in 3d 10:00"
local W_PRI = 3 -- "· A"
local W_KW_MIN = 10 -- INPROGRESS; grows for longer keywords (render_all)
local W_KW = W_KW_MIN
local RULE_MAX = 24

-- open states that are not late whatever their date says
local NEVER_LATE = { SOMEDAY = true, DEFERRED = true }

local Date, AgendaItem, Line, Token, View, config
local TodoState, TodoKeyword, Calendar -- for bulk edits (M.bulk)

local function pad(s, w)
  local n = vim.api.nvim_strwidth(s)
  return n >= w and s or s .. string.rep(' ', w - n)
end

local function day_of_month(d)
  return tostring(tonumber(d:format('%d')))
end

-- ---------------------------------------------------------------------------
--  one row: when / state / priority / title
-- ---------------------------------------------------------------------------

-- What the title column shows, and how many bytes were cut off its front: a
-- leading date ("2026-06-22 QA ...") is hidden, the row says when. (A
-- priority cookie outside A-F, like "[#I]", stays in the title: orgmode does
-- not treat it as a priority, so + / - would add a second one.)
local function shown_title(headline)
  local title = headline:get_title()
  local rest = title:match('^%d%d%d%d%-%d%d%-%d%d%s+(%S.*)$')
  if rest then
    return rest, #title - #rest
  end
  return title, 0
end

local function title_token(text, cut, headline, hl)
  local token = Token:new({ content = text, hl_group = hl, add_markup_to_headline = headline })
  if cut > 0 then
    -- orgmode places bold / links / etc. by the full title; shift them left
    local get = token.get_highlights
    token.get_highlights = function(self)
      local out = {}
      for _, h in ipairs(get(self)) do
        if h.extmark then
          h.range.start_col = h.range.start_col - cut
          h.range.end_col = h.range.end_col - cut
          if h.range.start_col >= self.range.start_col then
            table.insert(out, h)
          end
        else
          table.insert(out, h)
        end
      end
      return out
    end
  end
  return token
end

local hl_map -- orgmode's TODO keyword colors, looked up once (it redefines them each call)
local function keyword_hl(headline)
  hl_map = hl_map or require('orgmode.colors.highlights').get_agenda_hl_map()
  local todo, _, kind = headline:get_todo()
  return todo, todo and (hl_map[todo] or hl_map[kind]) or nil
end

local function add_columns(line, headline, when, when_hl)
  local done = headline:is_done()
  line:add_token(Token:new({
    content = '  ' .. pad(when or '', W_WHEN),
    hl_group = done and 'KitAgendaDone' or when_hl,
    trim_for_hl = true,
  }))
  local todo, todo_hl = keyword_hl(headline)
  line:add_token(Token:new({ content = pad(todo or '', W_KW), hl_group = todo_hl, trim_for_hl = true }))
  local text, cut = shown_title(headline)
  local p, p_hl = headline:get_priority(), nil
  if p ~= '' then
    local entry = config:get_priorities()[p]
    p_hl = entry and entry.hl_group or nil
  else
    p = nil
  end
  line:add_token(Token:new({ content = p and ('· ' .. p) or pad('', W_PRI), hl_group = p_hl, trim_for_hl = true }))
  line:add_token(title_token(text, cut, headline, done and 'KitAgendaDone' or nil))
end

-- Which task a row is, as it was when the row was drawn: its file, the line
-- its heading was on, and that line's text. A bulk edit (V then t) finds
-- each task by these and checks the text before it changes anything.
local function task_id(headline)
  local ok, id = pcall(function()
    local line = headline:get_range().start_line
    return { file = headline.file.filename, line = line, text = headline.file.lines[line] }
  end)
  return ok and id or nil
end

local function new_line(headline, metadata)
  return Line:new({
    headline = headline,
    line_hl_group = headline:is_clocked_in() and 'Visual' or nil,
    -- (a copy: orgmode hands the old row's table in when it redraws one row)
    metadata = vim.tbl_extend('force', metadata or {}, { kit_task = task_id(headline) }),
  })
end

-- ---------------------------------------------------------------------------
--  what the "when" column says
-- ---------------------------------------------------------------------------

-- The last date an open task's plain dates reach, if they have all passed
-- (no SCHEDULED, no DEADLINE, no repeat): that task is overdue from then.
local function plain_passed(headline, day)
  local todo = headline:get_todo()
  if not todo or headline:is_done() or NEVER_LATE[todo] then
    return nil
  end
  local latest
  for _, d in ipairs(headline:get_valid_dates_for_agenda()) do
    if not d:is_none() or d:get_repeater() then
      return nil
    end
    local last = d.is_date_range_start and d.related_date or d
    if not last:is_before(day, 'day') then
      return nil
    end
    if not latest or last:is_after(latest, 'day') then
      latest = last
    end
  end
  return latest
end

-- A repeating SCHEDULED / DEADLINE that was not done on its date: orgmode
-- puts a copy on every later day, as if it were on time. A DEADLINE is late
-- from the date in the file (the one not done yet); a SCHEDULED one has
-- started then (started_row).
local function missed_repeat(item)
  local d = item.headline_date
  return item.repeats_on_date and (d:is_deadline() or d:is_scheduled()) and d:is_before(item.date, 'day')
    and not item.headline:is_done()
end

-- A SCHEDULED date is a start date. The row orgmode gives an open task on a
-- day after its start (the copy it carries forward onto today, or a missed
-- repeat falling on today) means "started then", never "late".
local function started_row(item)
  local d = item.headline_date
  return d:is_scheduled() and not item.headline:is_done() and d:is_before(item.date, 'day')
end

-- the quiet "when" of a started task: days since it started
local function started_text(days)
  return days .. 'd', 'KitAgendaStarted'
end

local function time_of(item)
  local d = item.repeats_on_date and item.real_date or item.headline_date
  local ok, t = pcall(item._format_time, item, d)
  return ok and t or d:format_time()
end

local function when_of(item)
  local d = item.headline_date
  if item.kit_started then
    return started_text(item.date:diff(d))
  end
  if item.kit_overdue then
    return item.date:diff(item.kit_overdue) .. 'd ago', 'KitAgendaLate'
  end
  if item.kit_missed then -- a missed repeating DEADLINE
    return item.date:diff(d) .. 'd ago', 'KitAgendaLate'
  end
  if item.kit_upcoming then
    -- a start date or appointment still ahead: the days, and the time it
    -- starts when that fits the column ("in 3d 10:00", but "in 12d")
    local at = item.kit_upcoming
    local text = 'in ' .. at:diff(item.date) .. 'd'
    local timed = text .. ' ' .. at:format('%H:%M')
    if at:has_time() and #timed <= W_WHEN then
      text = timed
    end
    return text, 'KitAgendaSoon'
  end
  local timed = item.is_same_day and d:has_time()
  if d:is_deadline() then
    if item.is_same_day then
      return timed and time_of(item) or 'due', 'KitAgendaDue'
    end
    local days = item.date:diff(d) -- above 0: the deadline has passed
    if days > 0 then
      return days .. 'd ago', 'KitAgendaLate'
    end
    return 'in ' .. -days .. 'd', 'KitAgendaSoon'
  end
  if d:is_scheduled() then
    if item.is_same_day then
      return timed and time_of(item) or '', 'KitAgendaTime'
    end
    local days = item.date:diff(d)
    if days > 0 then
      return started_text(days) -- a start date that passed: never late
    end
    return 'in ' .. -days .. 'd', 'KitAgendaSoon'
  end
  -- a plain date (an appointment), or a stretch of days <a>--<b>
  local first = d.is_date_range_start and item.date_range_days > 1
  if timed then
    if first then
      return 'from ' .. d:format_time(), 'KitAgendaTime'
    end
    if d.is_date_range_end then
      return 'until ' .. d:format_time(), 'KitAgendaTime'
    end
    return time_of(item), 'KitAgendaTime'
  end
  if first and item.is_in_date_range then
    return ('day %d/%d'):format(item.date:diff(d) + 1, item.date_range_days), 'KitAgendaTime'
  end
  if d.is_date_range_end then
    return ('day %d/%d'):format(item.date_range_days, item.date_range_days), 'KitAgendaTime'
  end
  return '', nil
end

-- the todo lists (In progress, To do, task lists) say the same as the day
-- view. Third value: the date that counts, for sorting (nil = no date).
local function short_date(d)
  return d:format('%a ') .. day_of_month(d) .. d:format(' %b')
end

local function when_of_task(headline)
  local today = Date.today()
  local dl, sc = headline:get_deadline_date(), headline:get_scheduled_date()
  if dl and today:diff(dl) > 0 then
    return today:diff(dl) .. 'd ago', 'KitAgendaLate', dl.timestamp
  end
  -- a deadline decides, started or not (as on the day view)
  if dl then
    local days = dl:diff(today)
    return days == 0 and 'due' or ('in ' .. days .. 'd'), days == 0 and 'KitAgendaDue' or 'KitAgendaSoon', dl.timestamp
  end
  if sc and sc.is_date_range_start and sc.related_date and today:diff(sc) > 0
    and not sc.related_date:is_before(today, 'day') then
    -- a scheduled stretch of days that is on now (some apps write these)
    return ('day %d/%d'):format(today:diff(sc) + 1, sc.related_date:diff(sc) + 1), 'KitAgendaTime', today.timestamp
  end
  if sc and today:diff(sc) > 0 then
    -- started, never late. Sorts after today's rows and before tomorrow's,
    -- the oldest start first
    local days = today:diff(sc)
    local text, hl = started_text(days)
    return text, hl, today:add({ day = 1 }).timestamp - 1 + 1 / (days + 1)
  end
  if sc then
    local today_ = today:diff(sc) == 0
    return today_ and 'today' or short_date(sc), today_ and 'KitAgendaTime' or 'KitAgendaSoon', sc.timestamp
  end
  local last = plain_passed(headline, today)
  if last then
    return today:diff(last) .. 'd ago', 'KitAgendaLate', last.timestamp
  end
  -- the next plain date (an appointment) still to come
  local next_
  for _, d in ipairs(headline:get_valid_dates_for_agenda()) do
    if d:is_none() and not d.is_date_range_end then
      if d:get_repeater() then
        d = d:apply_repeater_until(today)
      elseif d.is_date_range_start and d.related_date and d:is_before(today, 'day')
        and not d.related_date:is_before(today, 'day') then
        d = today -- a stretch of days that is on now
      end
      if not d:is_before(today, 'day') and (not next_ or d:is_before(next_, 'day')) then
        next_ = d
      end
    end
  end
  if next_ then
    local today_ = next_:is_same(today, 'day')
    return today_ and 'today' or short_date(next_), today_ and 'KitAgendaTime' or 'KitAgendaSoon', next_.timestamp
  end
  return '', nil, nil
end

-- ---------------------------------------------------------------------------
--  a day: sorted into groups
-- ---------------------------------------------------------------------------

-- 'allday' (no time), 'timed', 'overdue', 'soon' (a deadline, start date or
-- appointment ahead), 'started' (start date passed, no deadline)
local function kind_of(item)
  if item.kit_started then
    return 'started'
  end
  if item.kit_overdue or item.kit_missed then
    return 'overdue'
  end
  if item.kit_upcoming then
    return 'soon'
  end
  if item.is_same_day or item.is_in_date_range then
    return (item.is_same_day and item.headline_date:has_time()) and 'timed' or 'allday'
  end
  if item.headline_date:is_before(item.date, 'day') then
    -- a start date that passed is never overdue
    return item.headline_date:is_scheduled() and 'started' or 'overdue'
  end
  if item.headline_date:is_scheduled() then
    return 'allday' -- SCHEDULED <date -2d>: shows from 2 days before, "in 2d"
  end
  return 'soon'
end

local function prio(item)
  return item.headline:get_priority_sort_value()
end

-- sort keys are worked out once per row (_kit_late, _kit_ahead, _kit_since),
-- not per comparison
local order = {
  -- deadlines first, then by priority
  allday = function(a, b)
    local ta, tb = a.headline_date:get_type_sort_value(), b.headline_date:get_type_sort_value()
    if ta ~= tb then
      return ta < tb
    end
    if prio(a) ~= prio(b) then
      return prio(a) > prio(b)
    end
    return a.index < b.index
  end,
  timed = function(a, b)
    if a.real_date.timestamp ~= b.real_date.timestamp then
      return a.real_date.timestamp < b.real_date.timestamp
    end
    if prio(a) ~= prio(b) then
      return prio(a) > prio(b)
    end
    return a.index < b.index
  end,
  -- by priority, then the longest overdue first
  overdue = function(a, b)
    if prio(a) ~= prio(b) then
      return prio(a) > prio(b)
    end
    if a._kit_late ~= b._kit_late then
      return a._kit_late > b._kit_late
    end
    return a.index < b.index
  end,
  -- the soonest first
  soon = function(a, b)
    if a._kit_ahead ~= b._kit_ahead then
      return a._kit_ahead < b._kit_ahead
    end
    if prio(a) ~= prio(b) then
      return prio(a) > prio(b)
    end
    return a.index < b.index
  end,
  -- the oldest start first
  started = function(a, b)
    if a._kit_since ~= b._kit_since then
      return a._kit_since > b._kit_since
    end
    if prio(a) ~= prio(b) then
      return prio(a) > prio(b)
    end
    return a.index < b.index
  end,
}

local function plain_overdue(view, day)
  local out, n = {}, 0
  for _, file in ipairs(view.files:all()) do
    for _, headline in ipairs(file:get_opened_headlines()) do
      local latest = plain_passed(headline, day)
      if latest and view:_matches_filters(headline) then
        n = n + 1
        local item = AgendaItem:new(latest, headline, day, 100000 + n)
        item.is_valid = true
        item.kit_overdue = latest
        table.insert(out, item)
      end
    end
  end
  return out
end

-- The soonest start date (SCHEDULED) or appointment (a plain date,
-- Space o i .) of an open task that is 1 to 14 days ahead, the days a
-- deadline warns for: the date as the file has it, and when it falls (a
-- repeating appointment: its next time). A repeating start date that was
-- missed has started, so its next time does not count.
local function next_ahead(headline, day)
  if headline:is_done() then
    return nil
  end
  local first, first_at
  for _, d in ipairs(headline:get_valid_dates_for_agenda()) do
    if (d:is_scheduled() or d:is_none()) and not d.is_date_range_end then
      local at = d
      if d:is_none() and d:get_repeater() then
        at = d:apply_repeater_until(day)
      end
      local days = at:diff(day)
      if days >= 1 and days <= config.org_deadline_warning_days
        and (not first_at or at.timestamp < first_at.timestamp) then
        first, first_at = d, at
      end
    end
  end
  return first, first_at
end

-- orgmode shows a start date or an appointment on its own day only, so
-- tomorrow's meeting was nowhere on today. This adds its "in Nd" row
-- (Coming up), one per task.
local function upcoming(view, day)
  local out, n = {}, 0
  for _, file in ipairs(view.files:all()) do
    for _, headline in ipairs(file:get_opened_headlines()) do
      local d, at = next_ahead(headline, day)
      if d and view:_matches_filters(headline) then
        n = n + 1
        local item = AgendaItem:new(d, headline, day, 300000 + n)
        item.is_valid = true
        item.kit_upcoming = at
        table.insert(out, item)
      end
    end
  end
  return out
end

-- One row per task per day. A SCHEDULED row goes when the same task's
-- DEADLINE shows that day, a deadline's "in Nd" warning goes while the
-- task's start day is still ahead (or today), and a date range written on
-- SCHEDULED / DEADLINE (some apps write those) keeps only its "day N/M" row.
-- Left with more than one row, the task keeps its best: deadline, then a
-- time, then day N/M, then the rest, then a start date or appointment still
-- ahead, and "started" only when nothing else shows it today.
local function rank(item)
  local d = item.headline_date
  if item.kit_started then
    return 7
  end
  if item.kit_upcoming then
    return 6
  end
  if d:is_deadline() then
    return 1
  end
  if item.is_same_day and d:has_time() then
    return 2
  end
  if d:is_none() and (item.is_in_date_range or d.is_date_range_end) then
    return 3
  end
  if d:is_scheduled() then
    return 4
  end
  return 5
end

local function one_row_per_task(items)
  local out = {}
  for _, item in ipairs(items) do
    local d = item.headline_date
    local sc = kind_of(item) == 'soon' and not item.kit_upcoming and item.headline:get_scheduled_date()
    local warning = sc and not sc:is_before(item.date, 'day')
    local range_end = (d:is_scheduled() or d:is_deadline()) and d.is_date_range_end
    if not warning and not range_end then
      table.insert(out, item)
    end
  end
  local deadline_shown = {}
  for _, item in ipairs(out) do
    if item.headline_date:is_deadline() then
      deadline_shown[item.headline] = true
    end
  end
  out = vim.tbl_filter(function(item)
    return not (item.headline_date:is_scheduled() and deadline_shown[item.headline])
  end, out)
  local best = {}
  for _, item in ipairs(out) do
    local b = best[item.headline]
    if not b or rank(item) < rank(b) then
      best[item.headline] = item
    end
  end
  return vim.tbl_filter(function(item)
    return best[item.headline] == item
  end, out)
end

-- A started task with a DEADLINE is shown by its deadline. orgmode only
-- gives the deadline a row today when it is due, past, or inside its
-- warning days; further off, this adds its "in Nd" row (Coming up), so the
-- task does not drop off the day.
local function started_deadlines(items, day)
  local has = {}
  for _, item in ipairs(items) do
    if item.headline_date:is_deadline() then
      has[item.headline] = true
    end
  end
  local out, n = {}, 0
  for _, item in ipairs(items) do
    local h = item.headline
    if item.kit_started and not has[h] then
      has[h] = true
      local dl = h:get_deadline_date()
      if dl and dl.active and not dl.is_date_range_end then
        n = n + 1
        local row = AgendaItem:new(dl, h, day, 200000 + n)
        row.is_valid = true
        table.insert(out, row)
      end
    end
  end
  return out
end

local function grid_times()
  local out = {}
  for _, t in ipairs(vim.tbl_get(config, 'org_agenda_time_grid', 'times') or {}) do
    local s = tostring(t)
    table.insert(out, { hour = tonumber(s:sub(1, #s - 2)) or 0, min = tonumber(s:sub(-2)) or 0 })
  end
  return out
end

local function grid_line(date, is_now, day, rule)
  local hl = is_now and 'KitAgendaNow' or 'KitAgendaGrid'
  local line = Line:new({ metadata = { date = date, agenda_day = day } })
  line:add_token(Token:new({ content = '  ' .. pad(date:format_time(), W_WHEN), hl_group = hl, trim_for_hl = true }))
  line:add_token(Token:new({ content = (is_now and 'now ' or '') .. rule, hl_group = hl }))
  return line
end

-- a day's own line: a faint band across the window, so each day (an empty
-- one too) reads as its own row
local function day_line(parts, metadata, today)
  local line = Line:new({ metadata = metadata, line_hl_group = today and 'KitAgendaTodayBand' or 'KitAgendaBand' })
  for _, p in ipairs(parts) do
    line:add_token(Token:new({ content = p[1], hl_group = p[2] }))
  end
  return line
end

local function range_text(a, b)
  if a:format('%Y%m') == b:format('%Y%m') then
    return ('%s to %s %s'):format(day_of_month(a), day_of_month(b), b:format('%B %Y'))
  end
  if a:format('%Y') == b:format('%Y') then
    return ('%s %s to %s %s'):format(day_of_month(a), a:format('%B'), day_of_month(b), b:format('%B %Y'))
  end
  return ('%s %s to %s %s'):format(day_of_month(a), a:format('%B %Y'), day_of_month(b), b:format('%B %Y'))
end

local function title_of(self, last)
  if self.span == 'week' then
    return ('Week %d, %s'):format(tonumber(self.from:format('%V')), range_text(self.from, last))
  end
  if self.span == 'month' and self.from.day == 1 then
    return self.from:format('%B %Y')
  end
  if self.span == 'year' and self.from.day == 1 and self.from.month == 1 then
    return self.from:format('%Y')
  end
  return range_text(self.from, last)
end

-- A view left open past midnight: orgmode remembers "is this today" on its
-- first day, and the day block would go on calling yesterday Today. Forget
-- that, and move a view that showed today on to the new today.
local function follow_today(self)
  local today = Date.today()
  self.from.is_today_date = nil
  if self._kit_today and not self._kit_today:is_same(today, 'day') and self._kit_had_today then
    local anchor = today
    if self.span == 'month' or self.span == 'year' then
      anchor = today:start_of(self.span)
    end
    self:_set_date_range(anchor)
  end
  self._kit_today = today
  self._kit_had_today = today:is_same_or_after(self.from, 'day') and today:is_before(self.to, 'day')
end

-- "+1d" -> "every day", "++2w" -> "every 2 weeks" (a month lists a repeat once)
local function repeat_text(d)
  local n, unit = (d:get_repeater() or ''):match('^[%.%+]?%+(%d+)([hdwmy])')
  if not n then
    return nil
  end
  local names = { h = 'hour', d = 'day', w = 'week', m = 'month', y = 'year' }
  n = tonumber(n)
  return n == 1 and ('(every %s)'):format(names[unit]) or ('(every %d %ss)'):format(n, names[unit])
end

local function short_day(day, today)
  return (today and 'Today, ' or '') .. day:format('%a ') .. day_of_month(day) .. day:format(' %b')
end

-- A month opens with a small calendar. Each cell is the day number and up to
-- two markers, "12 ds": d = a deadline falls that day (peach), s = a task
-- starts (is scheduled) that day (sapphire). The number is bright when the
-- day has anything at all (an appointment too), dim when it is free; today
-- is boxed. A line under it says so. Each row carries its first day and its
-- cells, so vw / vd on a row open that week / the day under the cursor.
local CAL_LEFT = 6 -- "  W39 ", the week number in front of the cells
local CAL_PITCH = 6 -- a cell: a space, then "12 ds"

-- a line of { text, highlight } parts, written as they are (no gaps added),
-- blanks at the end left off
local function parts_line(parts, metadata)
  while #parts > 0 and parts[#parts][1]:match('^ *$') do
    table.remove(parts)
  end
  if #parts > 0 then
    parts[#parts][1] = parts[#parts][1]:gsub(' +$', '')
  end
  local line = Line:new({ separator = '', metadata = metadata })
  for _, part in ipairs(parts) do
    line:add_token(Token:new({ content = part[1], hl_group = part[2], trim_for_hl = true }))
  end
  return line
end

local function calendar(view, plan)
  -- each day name ends over the last digit of the day numbers below it
  local head = { { pad('', CAL_LEFT) } }
  for _, name in ipairs({ 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun' }) do
    table.insert(head, { pad(name, CAL_PITCH), 'KitAgendaWeek' })
  end
  view:add_line(parts_line(head))
  local row, first
  local function flush()
    if not row then
      return
    end
    local parts = { { pad('  W' .. tonumber(first:format('%V')), CAL_LEFT), 'KitAgendaWeek' } }
    for wd = 1, 7 do
      local cell = row[wd]
      if cell then
        table.insert(parts, { (' %2s '):format(day_of_month(cell.day)), cell.hl })
        local marks = 0
        for _, m in ipairs({ { cell.due, 'd', 'KitAgendaCalDue' }, { cell.starts, 's', 'KitAgendaCalStart' } }) do
          if m[1] then
            table.insert(parts, { m[2], m[3] })
            marks = marks + 1
          end
        end
        table.insert(parts, { string.rep(' ', 2 - marks) })
      else
        table.insert(parts, { string.rep(' ', CAL_PITCH) })
      end
    end
    view:add_line(parts_line(parts, { agenda_day = first, kit_cells = row }))
    row, first = nil, nil
  end
  for _, p in ipairs(plan) do
    local wd = p.day:get_isoweekday()
    if row and wd == 1 then
      flush()
    end
    row = row or {}
    first = first or p.day
    local hl = 'KitAgendaCalFree'
    if p.today then
      hl = 'KitAgendaCalToday'
    elseif p.count > 0 then
      hl = 'KitAgendaCalBusy'
    end
    row[wd] = { day = p.day, hl = hl, due = p.due, starts = p.starts }
  end
  flush()
  view:add_line(parts_line({
    { '  ' }, { 'd', 'KitAgendaCalDue' }, { ' due  ', 'KitAgendaSub' }, { 's', 'KitAgendaCalStart' },
    { ' starts  ', 'KitAgendaSub' }, { 'bright', 'KitAgendaCalBusy' }, { ' = something that day  ', 'KitAgendaSub' },
    { 'dim', 'KitAgendaCalFree' }, { ' = free', 'KitAgendaSub' },
  }))
end

-- Day: the hours, then Overdue, Coming up and Started under their own
-- headings.
-- Week: the days, no hours; today also lists what is overdue. A scheduled
-- task shows on its start day only.
-- Month: the calendar, then only the days that have something; today lists
-- what is overdue, and a repeating task shows once (a missed deadline on
-- today, else its next time), not on every day.
local function render(self, bufnr, current_line)
  self.bufnr = bufnr or 0
  follow_today(self)
  local jump_to_date = self.from
  local was_line_in_view = true
  if self.view then
    was_line_in_view = self.view:is_in_range(current_line)
  end
  if was_line_in_view then
    jump_to_date = self:_get_jump_to_date(current_line)
  end

  local days = self:_get_agenda_days()
  local mode = #days == 1 and 'day' or (#days <= 7 and 'week' or 'month')
  local single = mode == 'day'
  local last = days[#days] and days[#days].day or self.from
  local view = View:new({ bufnr = self.bufnr, highlighter = self.highlighter })
  local use_grid = config.org_agenda_use_time_grid ~= false
  local width = vim.api.nvim_win_get_width(0)
  local rule = string.rep('─', math.max(6, math.min(RULE_MAX, width - (2 + W_WHEN + 1) - 5)))
  local now_day = Date.today()

  -- an INPROGRESS task that has started shows once: under In progress,
  -- when a list of those follows this day (Space o a d), else under Started
  local in_progress_below = false
  if single then
    for _, v in ipairs(require('orgmode').agenda.views or {}) do
      if v ~= self and type(v.match_query) == 'string' and v.match_query:match('/.*INPROGRESS') then
        in_progress_below = true
      end
    end
  end

  -- sort every day's rows into groups first (a month needs all of them
  -- before it draws anything)
  local plan = {}
  for _, agenda_day in ipairs(days) do
    local day = agenda_day.day
    local today = day:is_today()
    local past = not today and day:is_before(now_day, 'day')
    local items = {}
    for _, item in ipairs(agenda_day.agenda_items) do
      if item.index then -- orgmode's own grid lines are switched off; skip any
        local started = today and started_row(item)
        if today and missed_repeat(item) and item.headline_date:is_deadline() then
          item.kit_missed = true
        end
        -- today's day view lists a started task once, under Started. A week
        -- or month shows it on its start day only: today keeps a repeat that
        -- falls on today, not the copy orgmode carries forward
        item.kit_started = started and single or nil
        local carried = started and not single and not item.is_same_day
        -- a missed repeat shows once, on today, not again on each day between
        local copy = past and missed_repeat(item)
        -- "in 3d" warnings are for the day view; longer views show the day
        local warning = not single and kind_of(item) == 'soon'
        if not copy and not warning and not carried then
          table.insert(items, item)
        end
      end
    end
    if today then
      vim.list_extend(items, plain_overdue(self, day))
      if single then
        vim.list_extend(items, started_deadlines(items, day))
        vim.list_extend(items, upcoming(self, day))
      end
    end
    local groups = { allday = {}, timed = {}, overdue = {}, soon = {}, started = {} }
    for _, item in ipairs(one_row_per_task(items)) do
      local kind = kind_of(item)
      if kind == 'overdue' then
        item._kit_late = item.date:diff(item.kit_overdue or item.headline_date)
      elseif kind == 'soon' then
        -- by its day; a start date or appointment with a time comes after
        -- that day's rows without one, the earliest first
        item._kit_ahead = (item.kit_upcoming or item.headline_date:start_of('day')).timestamp
      elseif kind == 'started' then
        item._kit_since = item.date:diff(item.headline_date)
      end
      item.kit_repeat = nil
      if not (kind == 'started' and in_progress_below and item.headline:get_todo() == 'INPROGRESS') then
        table.insert(groups[kind], item)
      end
    end
    table.insert(plan, { day = day, today = today, items = items, groups = groups, meta = { agenda_day = day } })
  end

  -- what each day holds, for the month calendar, before repeats collapse to
  -- one row: a weekly chore marks every day it falls on. Daily repeats do
  -- not count (they fall on every day, so they would say nothing).
  local function daily(item)
    local n, unit = (item.headline_date:get_repeater() or ''):match('^[%.%+]?%+(%d+)([hd])$')
    return unit == 'h' or (unit == 'd' and tonumber(n) <= 1)
  end
  for _, p in ipairs(plan) do
    p.count = 0
    for _, list in pairs(p.groups) do
      for _, item in ipairs(list) do
        if not daily(item) then
          p.count = p.count + 1
        end
      end
    end
    -- its markers: a deadline falls on it (d), a task starts on it (s). Read
    -- from every row of the day, before a task's rows merge into one, so a
    -- task that starts and is due the same day marks both
    for _, item in ipairs(p.items) do
      local d = item.headline_date
      if item.is_same_day and not daily(item) and not item.headline:is_done() and not d.is_date_range_end then
        p.due = p.due or d:is_deadline()
        p.starts = p.starts or d:is_scheduled()
      end
    end
  end

  if mode == 'month' then
    -- each repeating task once: its next time from today, else its first
    -- (per timestamp: a task with a repeating SCHEDULED and DEADLINE, or two
    -- repeating times, keeps one row for each)
    local keep = {}
    for _, p in ipairs(plan) do
      for _, kind in ipairs({ 'overdue', 'allday', 'timed' }) do
        for _, item in ipairs(p.groups[kind]) do
          if item.headline_date:get_repeater() then
            local k = keep[item.headline_date]
            local upcoming = not p.day:is_before(now_day, 'day')
            if not k or (upcoming and not k.upcoming) then
              keep[item.headline_date] = { item = item, upcoming = upcoming, day = p.day }
            end
          end
        end
      end
    end
    for _, p in ipairs(plan) do
      for _, kind in ipairs({ 'overdue', 'allday', 'timed' }) do
        p.groups[kind] = vim.tbl_filter(function(item)
          if not item.headline_date:get_repeater() then
            return true
          end
          local k = keep[item.headline_date]
          if k.item ~= item then
            return false
          end
          item.kit_repeat = repeat_text(item.headline_date)
          return true
        end, p.groups[kind])
      end
    end
  end

  for _, p in ipairs(plan) do
    p.shown = 0
    for kind, list in pairs(p.groups) do
      table.sort(list, order[kind])
      p.shown = p.shown + #list
    end
  end

  if self.header then
    view:add_line(Line:single_token({ content = self.header, hl_group = '@org.agenda.header' }))
  elseif not single then
    -- carries the first day, so vw / vm / vd pressed on it start from there
    view:add_line(Line:single_token(
      { content = title_of(self, last), hl_group = '@org.agenda.header' },
      { metadata = { agenda_day = self.from } }
    ))
  end
  if mode == 'month' and #days <= 31 then
    calendar(view, plan)
  end

  local function add_rows(items)
    for _, item in ipairs(items) do
      view:add_line(self:_build_line(item, { category_length = 0, label_length = 0 }))
    end
  end

  local shown_day -- the last day drawn: a gap below it belongs to it
  for i, p in ipairs(plan) do
    local day, today, groups, meta = p.day, p.today, p.groups, p.meta
    if mode ~= 'month' or p.shown > 0 then
      -- the day's own line
      if single then
        local text = (today and 'Today, ' or '') .. day:format('%A ') .. day_of_month(day) .. day:format(' %B %Y')
        view:add_line(day_line({
          { text, today and 'KitAgendaToday' or 'KitAgendaDay' },
          { ' W' .. tonumber(day:format('%V')), 'KitAgendaWeek' },
        }, meta, today))
      else
        if i > 1 or mode == 'month' then
          view:add_line(Line:single_token({ content = '' }, { metadata = { agenda_day = shown_day } }))
        end
        shown_day = day
        view:add_line(day_line({ { short_day(day, today), today and 'KitAgendaToday' or 'KitAgendaDay' } }, meta, today))
      end

      add_rows(groups.allday)

      -- the hours, on a day view only
      local timed = {}
      for _, item in ipairs(groups.timed) do
        table.insert(timed, { at = item.real_date.timestamp, rank = 1, item = item })
      end
      if use_grid and single then
        local taken = {}
        for _, row in ipairs(timed) do
          taken[row.at] = true
        end
        for _, t in ipairs(grid_times()) do
          local g = day:set({ hour = t.hour, min = t.min, date_only = false })
          if not taken[g.timestamp] then
            table.insert(timed, { at = g.timestamp, rank = 2, grid = g })
          end
        end
        if today then
          local now = Date.now()
          table.insert(timed, { at = now.timestamp, rank = 3, grid = now, now = true })
        end
      end
      table.sort(timed, function(a, b)
        if a.at ~= b.at then
          return a.at < b.at
        end
        if a.rank ~= b.rank then
          return a.rank < b.rank
        end
        return a.item and b.item and order.timed(a.item, b.item) or false
      end)
      for _, row in ipairs(timed) do
        if row.item then
          add_rows({ row.item })
        else
          view:add_line(grid_line(row.grid, row.now, day, rule))
        end
      end

      if single then
        -- today's overdue, coming-up and started work, under their own
        -- headings
        for _, s in ipairs({ { 'Overdue', groups.overdue }, { 'Coming up', groups.soon }, { 'Started', groups.started } }) do
          if #s[2] > 0 then
            view:add_line(Line:single_token({ content = '' }))
            view:add_line(Line:single_token({ content = s[1], hl_group = '@org.agenda.header' }, { metadata = meta }))
            add_rows(s[2])
          end
        end
      else
        add_rows(groups.overdue) -- the red "Nd ago" says it
      end
    end
  end

  if self.show_clock_report then
    self:_kit_clock_report(view)
  end

  self.view = view:render()
  if self.after_render then
    self.after_render()
    self.after_render = nil
  elseif was_line_in_view then
    self:_jump_to_date(jump_to_date)
  end
  return self.view
end

-- ---------------------------------------------------------------------------
--  Space o a c: what you finished. Every task in a done state (DONE,
--  DELEGATED, CANCELLED, or a file's own done words), grouped by the day on
--  its CLOSED: line, newest day first and the latest close first within a
--  day. The "when" column says the time it was closed. Tasks with no CLOSED
--  line (marked done by hand, or before the kit logged it) come last, under
--  "No close date".
-- ---------------------------------------------------------------------------
local function closed_when(headline)
  local c = headline:get_closed_date()
  if c and c:has_time() then
    return c:format_time(), 'KitAgendaDone'
  end
  return '', nil
end

local function render_done(self, bufnr)
  self.bufnr = bufnr or 0
  local headlines = self:_get_headlines()
  local view = View:new({ bufnr = self.bufnr, highlighter = self.highlighter })
  view:add_line(Line:single_token({ content = self:_get_header(), hl_group = '@org.agenda.header' }))

  local days, by_day, undated = {}, {}, {}
  for i, h in ipairs(headlines) do
    local c = h:get_closed_date()
    if c then
      local key = c:format('%Y-%m-%d')
      if not by_day[key] then
        by_day[key] = { day = c:start_of('day'), rows = {} }
        table.insert(days, by_day[key])
      end
      table.insert(by_day[key].rows, { headline = h, at = c.timestamp, i = i })
    else
      table.insert(undated, { headline = h })
    end
  end
  table.sort(days, function(a, b)
    return a.day.timestamp > b.day.timestamp
  end)

  local today = Date.today()
  local function group(text, hl, is_today, rows)
    if #view.lines > 1 then
      view:add_line(Line:single_token({ content = '' }))
    end
    view:add_line(day_line({ { text, hl } }, nil, is_today))
    for _, row in ipairs(rows) do
      view:add_line(self:_build_line(row.headline, { category_length = 0, label_length = 0 }))
    end
  end
  for _, d in ipairs(days) do
    table.sort(d.rows, function(a, b)
      if a.at ~= b.at then
        return a.at > b.at
      end
      return a.i < b.i
    end)
    local is_today = d.day:is_same(today, 'day')
    local text = short_day(d.day, is_today)
    if d.day.year ~= today.year then
      text = text .. ' ' .. d.day.year -- another year: "Tue 23 Sep 2025"
    end
    group(text, is_today and 'KitAgendaToday' or 'KitAgendaDay', is_today, d.rows)
  end
  if #undated > 0 then
    group('No close date', 'KitAgendaDay', false, undated)
  end
  if #headlines == 0 then
    local filtered = self.agenda_filter and self.agenda_filter:should_filter()
    view:add_line(Line:single_token({
      content = '  ' .. (filtered and 'Nothing done matches the filter' or 'Nothing done yet'),
      hl_group = 'KitAgendaSub',
    }))
  end

  self.view = view:render()
  return self.view
end

-- ---------------------------------------------------------------------------
--  Completed, the last block of Space o a d: the tasks closed in the last
--  COMPLETED_DAYS days, the newest close first. The "when" column says how
--  long ago ("today", "1d ago", "3d ago"). Older tasks, and done tasks with
--  no CLOSED: line, are counted on a last line that names Space o a c, the
--  view that lists them all. No done task at all: no block.
-- ---------------------------------------------------------------------------
local function completed_when(headline)
  local c = headline:get_closed_date()
  if not c then
    return '', nil
  end
  local days = Date.today():diff(c)
  return days <= 0 and 'today' or (days .. 'd ago'), 'KitAgendaDone'
end

local function render_completed(self, bufnr)
  self.bufnr = bufnr or 0
  local headlines = self:_get_headlines()
  local view = View:new({ bufnr = self.bufnr, highlighter = self.highlighter })

  local today = Date.today()
  local rows, older, undated = {}, 0, 0
  for i, h in ipairs(headlines) do
    local c = h:get_closed_date()
    if not c then
      undated = undated + 1
    elseif today:diff(c) > M.COMPLETED_DAYS then
      older = older + 1
    else
      table.insert(rows, { headline = h, at = c.timestamp, i = i })
    end
  end
  if #headlines == 0 then
    self.view = view:render()
    return self.view
  end
  table.sort(rows, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    return a.i < b.i
  end)

  view:add_line(Line:single_token({ content = self:_get_header(), hl_group = '@org.agenda.header' }))
  for _, row in ipairs(rows) do
    view:add_line(self:_build_line(row.headline, { category_length = 0, label_length = 0 }))
  end
  -- (every task is in rows, older or undated, so with no rows there is a rest)
  local rest = {}
  if older > 0 then
    table.insert(rest, older .. ' older')
  end
  if undated > 0 then
    table.insert(rest, undated .. ' with no close date')
  end
  if #rest > 0 then
    local text = table.concat(rest, ', ') .. ': Space o a c'
    if #rows == 0 then
      text = ('Nothing in the last %d days. '):format(M.COMPLETED_DAYS) .. text
    end
    view:add_line(Line:single_token({ content = '  ' .. text, hl_group = 'KitAgendaSub' }))
  end

  self.view = view:render()
  return self.view
end

-- orgmode's clock table (R in the agenda), unchanged
local function clock_report(self, view)
  local ClockReport = require('orgmode.clock.report')
  view:add_line(Line:single_token({ content = '' }))
  local report = ClockReport:new({ from = self.from, to = self.to, files = self.files })
    :get_table_report(view.lines[#view.lines].line_nr)
  for _, row in ipairs(report.rows) do
    local line = Line:new({ separator = '|' })
    for i, cell in ipairs(row.cells) do
      if i == 1 then
        line:add_token(Token:new({ content = '', hl_group = '@org.bold' }))
      end
      local hl_group = '@org.bold'
      if cell.reference then
        line.headline = cell.reference
        hl_group = '@org.hyperlink'
      end
      line:add_token(Token:new({ content = cell.content, hl_group = hl_group, trim_for_hl = true }))
    end
    line:add_token(Token:new({ content = '', hl_group = '@org.bold' }))
    view:add_line(line)
  end
end

-- ---------------------------------------------------------------------------
--  colors (Catppuccin Mocha; init.lua passes the palette)
-- ---------------------------------------------------------------------------
function M.colors(P)
  return {
    KitAgendaDay = { fg = P.sapphire, bold = true },
    KitAgendaToday = { fg = P.blue, bold = true },
    KitAgendaWeek = { fg = P.overlay1 },
    KitAgendaSub = { fg = P.overlay1 },
    KitAgendaTime = { fg = P.sapphire },
    KitAgendaDue = { fg = P.peach, bold = true },
    KitAgendaLate = { fg = P.red, bold = true },
    KitAgendaSoon = { fg = P.subtext0 },
    KitAgendaStarted = { fg = P.overlay1 },
    KitAgendaGrid = { fg = P.surface1 },
    KitAgendaNow = { fg = P.blue, bold = true },
    KitAgendaDone = { fg = P.overlay1 },
    -- day bands stay darker than the cursor row, so the row keys act on is
    -- always the brightest bar
    KitAgendaBand = { bg = P.mantle },
    KitAgendaTodayBand = { bg = '#2a2b3c' },
    KitAgendaCursor = { bg = P.surface0 },
    KitAgendaCalFree = { fg = P.overlay0 },
    KitAgendaCalBusy = { fg = P.text, bold = true },
    KitAgendaCalToday = { fg = P.base, bg = P.blue, bold = true },
    KitAgendaCalDue = { fg = P.peach, bold = true },
    KitAgendaCalStart = { fg = P.sapphire, bold = true },
    KitAgendaListHead = { fg = P.blue, bold = true },
    KitAgendaListCount = { fg = P.overlay1 },
    KitAgendaFolded = { bg = 'NONE' },
  }
end

-- without the theme, borrow colors from what any colorscheme has
local fallback = {
  KitAgendaDay = 'Title', KitAgendaToday = 'Title', KitAgendaWeek = 'Comment',
  KitAgendaSub = 'Comment', KitAgendaTime = 'Special', KitAgendaDue = 'WarningMsg',
  KitAgendaLate = 'ErrorMsg', KitAgendaSoon = 'Comment', KitAgendaStarted = 'Comment', KitAgendaGrid = 'NonText',
  KitAgendaNow = 'Title', KitAgendaDone = 'Comment', KitAgendaBand = 'CursorLine',
  KitAgendaTodayBand = 'CursorLine', KitAgendaCursor = 'CursorLine', KitAgendaCalFree = 'Comment',
  KitAgendaCalBusy = 'Normal', KitAgendaCalToday = 'Search', KitAgendaCalDue = 'WarningMsg',
  KitAgendaCalStart = 'Special', KitAgendaListHead = 'Title',
  KitAgendaListCount = 'Comment', KitAgendaFolded = 'Normal',
}

-- ---------------------------------------------------------------------------
--  Space o a t: your tasks, list by list (one per file), like a to-do app's
--  Tasks tab. Each list is a header with its counts and the tasks under it.
--  Lists start folded; Enter (or Tab) on a header opens / closes it, and a
--  list stays the way you left it.
--
--  Space o a p: the same lists, one per priority instead of one per file:
--  every file's open tasks in one place, each row saying which file it is
--  from. The priorities above the default (A to C) start open; the default
--  (D, which is also every task with no priority) and below start folded.
--  o in the lists flips between the two.
-- ---------------------------------------------------------------------------
M.open_lists = {} -- file name (or "priority#A" ...) -> true when unfolded
M.by = 'file' -- what the task lists are grouped by: 'file' or 'priority'
local list_ns

local function list_header(title, headlines)
  local late = 0
  for _, h in ipairs(headlines) do
    local _, hl = when_of_task(h)
    if hl == 'KitAgendaLate' then
      late = late + 1
    end
  end
  return ('▾ %s  %d task%s, %d overdue'):format(title, #headlines, #headlines == 1 and '' or 's', late)
end

-- a file's list goes by its #+TITLE, or the file name without .org
local function file_title(file)
  local title = vim.trim(file:get_title() or '')
  if title == '' then
    title = vim.fn.fnamemodify(file.filename, ':t:r')
  end
  return title
end

-- the list a task is in when grouped by file (the name its row shows when
-- grouped by priority)
local function list_of(headline)
  return file_title(headline.file)
end

-- a task's priority letter; no priority counts as the default (D)
local function priority_of(headline)
  local p = headline:get_priority()
  return p ~= '' and p or config.org_priority_default
end

-- one list per priority, highest first, each with every file's open tasks
local function priority_lists(agenda)
  local by_p, order_ = {}, {}
  for _, file in ipairs(agenda.files:all()) do
    for _, h in ipairs(file:get_unfinished_todo_entries()) do
      local p = priority_of(h)
      if not by_p[p] then
        by_p[p] = { value = h:get_priority_sort_value(), headlines = {} }
        table.insert(order_, p)
      end
      table.insert(by_p[p].headlines, h)
    end
  end
  table.sort(order_, function(a, b)
    return by_p[a].value > by_p[b].value
  end)
  local default = config.org_priority_default
  local lists = {}
  for _, p in ipairs(order_) do
    local key = 'priority#' .. p
    if M.open_lists[key] == nil then
      -- first look: above the default open, the default and below folded
      M.open_lists[key] = p < default
    end
    table.insert(lists, {
      key = key,
      title = p == default and ('Priority %s, or none'):format(p) or ('Priority %s'):format(p),
      headlines = by_p[p].headlines,
      match = function(h)
        return priority_of(h) == p
      end,
    })
  end
  return lists
end

-- One list per file, named by its #+TITLE (or file name). Grouped by
-- priority (M.by), one list per priority across every file.
local function task_lists(agenda)
  local TodoType = require('orgmode.agenda.types.todo')
  local by_priority = M.by == 'priority'
  local lists = by_priority and priority_lists(agenda) or {}
  for _, file in ipairs(by_priority and {} or agenda.files:all()) do
    local open = file:get_unfinished_todo_entries()
    if #open > 0 then
      table.insert(lists, { key = file.filename, title = file_title(file), file = file, headlines = open })
    end
  end
  if not by_priority then
    table.sort(lists, function(a, b)
      return a.title:lower() < b.title:lower()
    end)
  end
  if #lists == 0 then
    -- nothing open anywhere: say so, and keep being the lists view, so a
    -- task added later shows up on the next redraw
    local view = TodoType:new({
      files = agenda.files,
      agenda_filter = agenda.filters,
      highlighter = agenda.highlighter,
      header = 'No open tasks',
    })
    view.kit_list = ''
    view.get_file_headlines = function()
      return {}
    end
    return { view }
  end

  local views = {}
  for i, list in ipairs(lists) do
    local view = TodoType:new({
      files = agenda.files,
      agenda_filter = agenda.filters,
      highlighter = agenda.highlighter,
      header = list.title,
      id = 'kit_list_' .. i,
    })
    view.kit_list = list.key
    view.kit_by_priority = by_priority -- rows say which file they are from
    -- the counts are of the rows this list draws now (after a / filter too)
    view._get_header = function(self)
      return list_header(list.title, (self:_get_headlines()))
    end
    -- overdue first (most overdue on top), then by date, then the undated
    -- by priority: the same date the "when" column shows
    view._sort = function(_, todos)
      local key = {}
      for i, h in ipairs(todos) do
        local _, _, at = when_of_task(h)
        key[h] = { at = at or math.huge, prio = h:get_priority_sort_value(), i = i }
      end
      table.sort(todos, function(a, b)
        local ka, kb = key[a], key[b]
        if ka.at ~= kb.at then
          return ka.at < kb.at
        end
        if ka.prio ~= kb.prio then
          return ka.prio > kb.prio
        end
        return ka.i < kb.i
      end)
      return todos
    end
    view.get_file_headlines = function(_, f)
      if list.file and f.filename ~= list.file.filename then
        return {}
      end
      return f:get_unfinished_todo_entries()
    end
    table.insert(views, view)
  end
  return views
end

-- the header line of each list: title blue, counts dim, overdue red
local function color_list_headers(agenda, buf)
  list_ns = list_ns or vim.api.nvim_create_namespace('kit_lists')
  vim.api.nvim_buf_clear_namespace(buf, list_ns, 0, -1)
  for _, v in ipairs(agenda.views or {}) do
    local first = v.kit_list and v.view and v.view.lines[1]
    if first then
      local text = vim.api.nvim_buf_get_lines(buf, first.line_nr - 1, first.line_nr, false)[1] or ''
      local a = text:find('  %d+ tasks?, ')
      if a then
        vim.api.nvim_buf_set_extmark(buf, list_ns, first.line_nr - 1, a - 1,
          { end_col = #text, hl_group = 'KitAgendaListCount', priority = 5000 })
        local b, e = text:find('[1-9]%d* overdue$')
        if b then
          vim.api.nvim_buf_set_extmark(buf, list_ns, first.line_nr - 1, b - 1,
            { end_col = e, hl_group = 'KitAgendaLate', priority = 5001 })
        end
      end
    end
  end
end

-- remember which lists are open, however they were opened (Enter, za, zo, zR)
local function remember_lists(agenda, win)
  vim.api.nvim_win_call(win, function()
    for _, v in ipairs(agenda.views or {}) do
      local first = v.kit_list and v.view and v.view.lines and v.view.lines[1]
      if first and first.line_nr <= vim.fn.line('$') and vim.fn.foldlevel(first.line_nr) > 0 then
        M.open_lists[v.kit_list] = vim.fn.foldclosed(first.line_nr) == -1
      end
    end
  end)
end

-- one fold per list, closed unless you opened it; the cursor never stays
-- inside a closed list (a key there would act on a task you cannot see).
-- A list new since the last look (a first capture into an empty Inbox)
-- opens when every other list is open (Shift Tab opened them all).
local function fold_lists(agenda, win)
  local known, all_open = 0, true
  for _, v in ipairs(agenda.views or {}) do
    if v.kit_list and M.open_lists[v.kit_list] ~= nil then
      known = known + 1
      all_open = all_open and M.open_lists[v.kit_list]
    end
  end
  if known > 0 and all_open then
    for _, v in ipairs(agenda.views or {}) do
      if v.kit_list and v.kit_list ~= '' and M.open_lists[v.kit_list] == nil then
        M.open_lists[v.kit_list] = true
      end
    end
  end
  vim.api.nvim_win_call(win, function()
    vim.wo.foldmethod = 'manual'
    vim.cmd('silent! normal! zE')
    for _, v in ipairs(agenda.views or {}) do
      local lines = v.kit_list and v.view and v.view.lines
      if lines and #lines > 1 then
        local s, e = lines[1].line_nr, lines[#lines].line_nr
        vim.cmd(('%d,%dfold'):format(s, e))
        if M.open_lists[v.kit_list] then
          vim.cmd(('%d,%dfoldopen'):format(s, s))
        end
      end
    end
    local closed = vim.fn.foldclosed('.')
    if closed ~= -1 then
      vim.fn.cursor(closed, 1)
    end
  end)
end

local function is_lists(agenda)
  return agenda.views and agenda.views[1] and agenda.views[1].kit_list ~= nil
end

local function agenda_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == ''
      and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'orgagenda' then
      return win
    end
  end
end

-- note the lists' open / closed state before the lists go away (another
-- view replaces them, or q leaves the agenda)
function M.remember()
  local agenda = package.loaded['orgmode'] and require('orgmode').agenda
  local win = agenda and is_lists(agenda) and agenda_window()
  if win then
    remember_lists(agenda, win)
  end
end

-- run fn, then put the cursor of the window you were in back (orgmode moves
-- the current window's cursor to line 1 after drawing, even from a file split)
local function keep_cursor(fn)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.bo.filetype ~= 'orgagenda' and vim.api.nvim_win_get_cursor(win)
  local result = fn()
  if pos and result and result.next then
    result = result:next(function(...)
      -- (only when the file is still in that window; the agenda often opens
      -- in the same window, and it keeps its own cursor)
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        pcall(vim.api.nvim_win_set_cursor, win, pos)
      end
      return ...
    end)
  end
  return result
end

-- Files a sync tool or anything else changed since orgmode last read them.
-- :checktime reloads a changed file shown in a window, but not one open in
-- a hidden buffer, so a hidden, unedited buffer whose text differs from
-- disk is reloaded here.
local function refresh_buffers(files)
  pcall(vim.cmd, 'silent! checktime')
  pcall(function()
    for _, file in ipairs(files:all()) do
      local buf = vim.fn.bufnr(file.filename)
      if buf > -1 and vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified and vim.fn.bufwinid(buf) == -1 then
        local disk = vim.fn.readfile(file.filename)
        for i, l in ipairs(disk) do
          disk[i] = l:gsub('\r$', '')
        end
        if not vim.deep_equal(disk, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
          vim.api.nvim_buf_call(buf, function()
            vim.cmd('silent! edit!')
          end)
        end
      end
    end
  end)
end

-- A file new in the org folder (made in the file tree, or by a sync):
-- orgmode lists the folder once and keeps that list until r, so its tasks
-- stayed off every view. Opening a view lists the folder again (one glob,
-- as r does) and reads the whole set only when a file is new.
local function new_files(files)
  pcall(function()
    if files.load_state ~= 'loaded' then
      return -- (still reading the folder: that finds them)
    end
    for _, name in ipairs(files:_files(true)) do
      if not files.files[name] then
        files:load(true):wait(15000)
        return
      end
    end
  end)
end

local function stale(files)
  local ok, found = pcall(function()
    for _, file in ipairs(files:all()) do
      if file:is_modified() then
        return true
      end
    end
    return false
  end)
  return ok and found
end

-- Redraw now and wait for it (keys already typed wait too), re-reading
-- files a sync changed, then put the cursor back on the same row (by its
-- text: rows above it may have come or gone). Returns true when the row is
-- still there.
function M.refresh_now()
  local agenda = require('orgmode').agenda
  local win = agenda_window()
  if not win then
    return false
  end
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local row = vim.api.nvim_win_call(win, vim.api.nvim_get_current_line)
  refresh_buffers(agenda.files)
  pcall(function()
    agenda:redo('kit'):wait(15000)
  end)
  if not (vim.api.nvim_win_is_valid(win) and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'orgagenda') then
    return false
  end
  local found = false
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(view)
    if vim.trim(row) == '' then
      return
    end
    local best
    for lnum, text in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if text == row and (not best or math.abs(lnum - view.lnum) < math.abs(best - view.lnum)) then
        best = lnum
      end
    end
    if best then
      vim.fn.cursor(best, view.col + 1)
      found = true
    end
  end)
  return found
end

-- a closed list shows its header with a closed arrow
function M.foldtext()
  local text = vim.fn.getline(vim.v.foldstart)
  local title, counts = text:match('^▾ (.-)(  %d+ tasks?, .*)$')
  if not title then
    return text
  end
  local chunks = { { '▸ ' .. title, 'KitAgendaListHead' } }
  local before, n = counts:match('^(.-, )([1-9]%d* overdue)$')
  if before then
    table.insert(chunks, { before, 'KitAgendaListCount' })
    table.insert(chunks, { n, 'KitAgendaLate' })
  else
    table.insert(chunks, { counts, 'KitAgendaListCount' })
  end
  return chunks
end

-- Enter / Tab on a list header: open or close that list. False when the
-- cursor is not on a list (so the key does its usual thing).
function M.toggle_list()
  local lnum = vim.fn.line('.')
  if vim.bo.filetype ~= 'orgagenda' or vim.fn.foldlevel(lnum) == 0 then
    return false
  end
  vim.cmd('normal! za')
  for _, v in ipairs(require('orgmode').agenda.views or {}) do
    local lines = v.kit_list and v.view and v.view.lines
    if lines and lines[1] and lnum >= lines[1].line_nr and lnum <= lines[#lines].line_nr then
      M.open_lists[v.kit_list] = vim.fn.foldclosed(lnum) == -1
      vim.fn.cursor(lines[1].line_nr, 1) -- on the header, not a task in it
    end
  end
  return true
end

-- o in the task lists: grouped by file <-> grouped by priority. Anywhere
-- else in the agenda it changes nothing and says so.
function M.flip_lists()
  local agenda = require('orgmode').agenda
  if not is_lists(agenda) then
    vim.api.nvim_echo({ { 'o switches Space o a t / p between by file and by priority. Nothing done.' } }, false, {})
    return
  end
  return agenda:todos({ kit_by = M.by == 'priority' and 'file' or 'priority' })
end

-- ---------------------------------------------------------------------------
--  setup: swap the functions in, or say why not
-- ---------------------------------------------------------------------------
local originals = {} -- { table, key, function } to put back
local failed = false

local function replace(tbl, key, fn)
  table.insert(originals, { tbl, key, tbl[key] })
  tbl[key] = fn
end

local function restore(err)
  if failed then
    return
  end
  failed = true
  for i = #originals, 1, -1 do
    local o = originals[i]
    o[1][o[2]] = o[3]
  end
  if M.on_fail then
    pcall(M.on_fail)
  end
  vim.schedule(function()
    vim.notify(('nvim kit: agenda look failed (%s); showing orgmode\'s plain agenda'):format(tostring(err)),
      vim.log.levels.WARN)
  end)
end

-- run the kit's version; if it errors, put orgmode's back and use that
local function guarded(fn, key)
  return function(...)
    local ok, result = pcall(fn, ...)
    if ok then
      return result
    end
    restore(result)
    local self = ...
    return self[key](...)
  end
end

-- the widest TODO keyword in any agenda file (a file's own #+TODO line too)
local function measure_keywords(files)
  local w = W_KW_MIN
  for _, t in ipairs(config.org_todo_keywords or {}) do
    if type(t) == 'string' and t ~= '|' then
      w = math.max(w, vim.api.nvim_strwidth((t:gsub('%(.*%)$', ''))))
    end
  end
  local ok = pcall(function()
    for _, file in ipairs(files:all()) do
      for _, kw in ipairs(file:get_todo_keywords():all()) do
        w = math.max(w, vim.api.nvim_strwidth(kw.value or ''))
      end
    end
  end)
  W_KW = ok and w or W_KW
  M.title_col = 2 + W_WHEN + 1 + W_KW + 1 + W_PRI + 1
end

-- V then t / + / - / Space o i s / Space o i d / Space o $ in the agenda
-- (init.lua maps them): the selected rows, then out of visual mode, then the
-- change for every task in them (M._bulk, set up below)
function M.bulk(kind)
  local l1, l2 = vim.fn.line('v'), vim.fn.line('.')
  if l1 > l2 then
    l1, l2 = l2, l1
  end
  vim.cmd('normal! ' .. vim.keycode('<Esc>'))
  if failed or not M._bulk then
    vim.notify('nvim kit: changing several tasks at once needs the kit\'s agenda look, which did not load',
      vim.log.levels.WARN)
    return
  end
  local ok, err = pcall(M._bulk, kind, l1, l2)
  if not ok then
    vim.notify('nvim kit: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

-- Change the task under the agenda cursor: `run(task)` runs in the task's
-- file, the file is saved and the agenda redrawn before the next key runs.
-- True when it ran (false: not on a task, or the rows changed under it).
function M.edit(run)
  if failed or not M._edit then
    vim.notify('nvim kit: this key needs the kit\'s agenda look, which did not load (open the task with Tab)',
      vim.log.levels.WARN)
    return false
  end
  return M._edit(run)
end

-- ---------------------------------------------------------------------------
--  u / Ctrl r in the agenda (init.lua maps them): take back, or make again,
--  the last change made from the agenda: t, + / -, a start or due date,
--  tags, a property, and the same after V. One key is one step, however
--  many tasks it changed. Each file is set back with Neovim's own undo there
--  (:undo to the change before the step; undo history is kept across saves
--  and restarts), saved, and the agenda redrawn. Only while the file is
--  still just as that step left it: otherwise nothing is changed and you are
--  told to undo in the file. Archive, refile, clock and notes reach other
--  files or windows, so they clear the list.
-- ---------------------------------------------------------------------------
local undo_list, redo_list = {}, {}
local step -- the step being recorded: a list of { file =, before =, after = }

-- start the step for one key; false when one is already going (this is
-- part of it). `undoable` false: this key can not be undone from here.
local function step_start(undoable)
  if step then
    return false
  end
  step = { undoable = undoable }
  return true
end

local function step_stop(own)
  if not own then
    return
  end
  local s = step
  step = nil
  if not s.undoable then
    undo_list, redo_list = {}, {}
    return
  end
  -- (a date picker's edit lands in it later: see record)
  table.insert(undo_list, s)
end

-- one file's change in step `s`: undo changes before .. after
local function record(s, file, before, after)
  if s and s.undoable and before ~= after then
    table.insert(s, { file = file, before = before, after = after })
    redo_list = {}
  end
end

-- True when it changed something.
function M.undo(redo)
  if failed then
    vim.notify('nvim kit: undo from the agenda needs the kit\'s agenda look, which did not load (Tab to the task, then u)',
      vim.log.levels.WARN)
    return false
  end
  local from, to = undo_list, redo_list
  if redo then
    from, to = redo_list, undo_list
  end
  while from[#from] and #from[#from] == 0 do
    table.remove(from)
  end
  local s = table.remove(from)
  if not s then
    vim.notify(redo and 'Nothing to redo from the agenda'
      or 'Nothing to undo from the agenda. Other changes: Tab to the task, then u')
    return false
  end
  local agenda = require('orgmode').agenda
  refresh_buffers(agenda.files)
  -- each file once: the change it must be at now, and the one it goes to
  local files, order = {}, {}
  for _, e in ipairs(s) do
    if not files[e.file] then
      files[e.file] = { first = e.before, last = e.after }
      table.insert(order, e.file)
    end
    files[e.file].last = e.after
  end
  local plan = {}
  local function unload()
    for _, p in ipairs(plan) do
      if not p.was_loaded then
        pcall(vim.cmd, 'silent! bwipeout ' .. p.buf)
      end
    end
  end
  for _, name in ipairs(order) do
    local f = files[name]
    local buf = vim.fn.bufadd(name)
    local was_loaded = vim.api.nvim_buf_is_loaded(buf)
    if not was_loaded then
      pcall(vim.fn.bufload, buf)
    end
    table.insert(plan, { buf = buf, was_loaded = was_loaded, go = redo and f.last or f.first })
    local now = vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_call(buf, vim.fn.changenr)
    if now ~= (redo and f.first or f.last) or vim.bo[buf].modified then
      unload()
      vim.notify(('Not %s: %s changed since. Tab to the task, then u there'):format(
        redo and 'redone' or 'undone', vim.fn.fnamemodify(name, ':t')), vim.log.levels.WARN)
      return false
    end
  end
  for _, p in ipairs(plan) do
    vim.api.nvim_buf_call(p.buf, function()
      vim.cmd(('silent undo %d'):format(p.go))
      vim.cmd('silent update')
    end)
  end
  unload()
  table.insert(to, s)
  M.refresh_now()
  local names = vim.tbl_map(function(n)
    return vim.fn.fnamemodify(n, ':t')
  end, order)
  vim.notify(('%s in %s%s'):format(redo and 'Redone' or 'Undone', table.concat(names, ', '),
    redo and '' or ' (Ctrl r redoes it)'))
  return true
end

function M.setup()
  local ok, err = pcall(function()
    Date = require('orgmode.objects.date')
    AgendaItem = require('orgmode.agenda.agenda_item')
    Line = require('orgmode.agenda.view.line')
    Token = require('orgmode.agenda.view.token')
    View = require('orgmode.agenda.view.init')
    config = require('orgmode.config')
    TodoState = require('orgmode.objects.todo_state')
    TodoKeyword = require('orgmode.objects.todo_keywords.todo_keyword')
    Calendar = require('orgmode.objects.calendar')
  end)
  if not ok then
    return false, tostring(err)
  end
  local AgendaType = require('orgmode.agenda.types.agenda')
  local TodoType = require('orgmode.agenda.types.todo')
  local TagsType = require('orgmode.agenda.types.tags')
  local Agenda = require('orgmode.agenda')
  local AgendaFilter = require('orgmode.agenda.filter')

  -- everything this relies on; a newer orgmode that moved one of them gets
  -- orgmode's own agenda instead of a broken one
  local needs = {
    { AgendaType, { 'render', '_build_line', '_get_agenda_days', '_prepare_grid_lines', '_get_jump_to_date', 'change_span',
      '_jump_to_date', '_matches_filters', '_set_date_range', 'rerender_agenda_line' } },
    { TodoType, { 'render', '_build_line', 'rerender_agenda_line', '_get_headlines', '_get_header' } },
    { TagsType, { 'get_file_headlines' } },
    { AgendaFilter, { 'parse' } },
    { Agenda, { 'render', 'redo', '_remote_edit', '_get_headline', 'todos', 'open_view', 'prepare_and_render', '_get_headline',
      'get_headline_at_cursor', '_build_custom_commands' } },
    { AgendaItem, { 'new', '_format_time' } },
    { Line, { 'new', 'single_token', 'add_token' } },
    { Token, { 'new', 'get_highlights' } },
    { View, { 'new', 'add_line', 'render' } },
    { Date, { 'today', 'now', 'diff', 'is_before', 'get_repeater', 'format_time', 'get_type_sort_value',
      'set_isoweekday', 'start_of', 'add', 'apply_repeater_until' } },
    { TodoState, { 'new', 'open_fast_access', 'has_fast_access' } },
    { TodoKeyword, { 'empty' } },
    { Calendar, { 'new', 'open' } },
  }
  for _, need in ipairs(needs) do
    for _, fn in ipairs(need[2]) do
      if type(need[1][fn]) ~= 'function' then
        return false, 'orgmode has no ' .. fn .. '() any more'
      end
    end
  end
  M.title_col = 2 + W_WHEN + 1 + W_KW + 1 + W_PRI + 1

  for name, link in pairs(fallback) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end

  replace(AgendaType, '_prepare_grid_lines', function()
    return {} -- the hours are drawn by render() below
  end)
  AgendaType._kit_clock_report = clock_report
  replace(AgendaType, 'render', guarded(render, 'render'))
  replace(AgendaType, '_build_line', guarded(function(_, item, metadata)
    local line = new_line(item.headline, {
      agenda_item = item,
      category_length = metadata.category_length,
      label_length = metadata.label_length,
    })
    local when, hl = when_of(item)
    add_columns(line, item.headline, when, hl)
    if item.kit_repeat then
      line:add_token(Token:new({ content = item.kit_repeat, hl_group = 'KitAgendaSub' }))
    end
    return line
  end, '_build_line'))
  replace(TodoType, '_build_line', guarded(function(self, headline, metadata)
    local line = new_line(headline, metadata)
    local when, hl
    if is_done_view(self) then
      when, hl = closed_when(headline)
    elseif is_completed_block(self) then
      when, hl = completed_when(headline)
    else
      when, hl = when_of_task(headline)
    end
    add_columns(line, headline, when, hl)
    if self.kit_by_priority then
      -- (after the title, dim: which file the task is from)
      line:add_token(Token:new({ content = ' ' .. list_of(headline), hl_group = 'KitAgendaSub' }))
    end
    return line
  end, '_build_line'))
  -- the Done view (Space o a c) draws its own groups, and Completed in the
  -- day view its own order; other lists as before
  local todo_render = TodoType.render
  replace(TodoType, 'render', guarded(function(self, ...)
    if is_done_view(self) then
      return render_done(self, ...)
    end
    if is_completed_block(self) then
      return render_completed(self, ...)
    end
    return todo_render(self, ...)
  end, 'render'))

  -- a week always starts on Monday (org_agenda_start_on_weekday) and a month
  -- on the 1st, also after J or .; orgmode lines weeks up only for this week
  local set_range = AgendaType._set_date_range
  replace(AgendaType, '_set_date_range', function(self, from)
    set_range(self, from)
    local wd = self.start_on_weekday
    if self.span == 'week' and wd and self.from:get_isoweekday() ~= wd then
      self.from = self.from:set_isoweekday(wd)
      self.to = self.from:add({ week = 1 })
    elseif (self.span == 'month' or self.span == 'year') and not self.from:is_same(self.from:start_of(self.span), 'day') then
      -- a month (year) view starts on the 1st, also after . or J
      self.from = self.from:start_of(self.span)
      self.to = self.from:add({ [self.span] = 1 })
    end
  end)

  -- an edit on a clock table row (R) has no agenda item to redraw in place
  -- (orgmode errors there); redraw the whole agenda instead
  -- (and when the task has other rows on screen, e.g. its own day plus
  -- today's overdue list, redraw so every row shows the change)
  local function shown_twice(headline)
    local n, file, line = 0, headline.file.filename, headline:get_range().start_line
    for _, v in ipairs(require('orgmode').agenda.views or {}) do
      for _, l in ipairs(v.view and v.view.lines or {}) do
        local h = l.headline
        if h and h.file.filename == file and h:get_range().start_line == line then
          n = n + 1
        end
      end
    end
    return n > 1
  end
  -- Date views always redraw after an edit: a change of state can move the
  -- task in or out of today's overdue rows, the month calendar and other
  -- rows of the same task. Task lists redraw for their counts. The cursor
  -- then follows the task if it still shows in the same place (+ re-sorts
  -- rows), else lands on the row that was below it (t d moved it away), so
  -- the next key acts on the task you expect.
  -- before an edit from the agenda: where the cursor is, the row below it,
  -- and which task it is on. (A bulk edit looks for the row below its last
  -- selected row, `after`, and passes the tasks it changes as `skip`.)
  local pending
  local function capture(agenda, after, skip)
    local win = agenda_window()
    if not win then
      return nil
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- (nvim_win_call passes back one value, so both come in a table)
    local got = vim.api.nvim_win_call(win, function()
      local found
      for _, v in ipairs(agenda.views or {}) do
        local l = v.view and v:get_line(lnum)
        if l and l.metadata and l.metadata.agenda_item then
          found = l.metadata.agenda_item.date
        end
      end
      return { agenda:get_headline_at_cursor(), found }
    end)
    local h, day = got[1], got[2]
    -- the next task row below, skipping other rows of this same task (a
    -- repeat's next time), so the cursor never lands back on it
    local file, start = h and h.file.filename, h and h:get_range().start_line
    local task_at = {}
    for _, v in ipairs(agenda.views or {}) do
      for _, l in ipairs(v.view and v.view.lines or {}) do
        if l.headline then
          task_at[l.line_nr] = l.headline
        end
      end
    end
    local below
    for i = (after or lnum) + 1, #lines do
      local t = task_at[i]
      local t_start = t and t:get_range().start_line
      if t and not (t.file.filename == file and t_start == start)
        and not (skip and skip[t.file.filename .. '\n' .. t_start]) then
        below = lines[i]
        break
      end
    end
    return {
      win = win, buf = buf, lnum = lnum, below = below, day = day,
      when = (lines[lnum] or ''):sub(1, 2 + W_WHEN),
      file = h and h.file.filename, start = h and h:get_range().start_line,
    }
  end
  local function follow(agenda, c)
    if not (c and vim.api.nvim_win_is_valid(c.win) and vim.api.nvim_buf_is_valid(c.buf)) then
      return
    end
    local target, dist
    local function consider(n)
      if not target or math.abs(n - c.lnum) < dist then
        target, dist = n, math.abs(n - c.lnum)
      end
    end
    for _, v in ipairs(agenda.views or {}) do
      for _, l in ipairs(v.view and v.view.lines or {}) do
        local h = l.headline
        local item = l.metadata and l.metadata.agenda_item
        -- same task, same day (a repeat's next time on a later day does not count)
        local same_day = not c.day or (item and item.date:is_same(c.day, 'day'))
        if c.file and h and h.file.filename == c.file and h:get_range().start_line == c.start and same_day then
          local text = vim.api.nvim_buf_get_lines(c.buf, l.line_nr - 1, l.line_nr, false)[1] or ''
          if text:sub(1, 2 + W_WHEN) == c.when then
            consider(l.line_nr)
          end
        end
      end
    end
    if not target and c.below then
      for i, text in ipairs(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)) do
        if text == c.below then
          consider(i)
        end
      end
    end
    if target then
      pcall(vim.api.nvim_win_set_cursor, c.win, { target, 0 })
    end
  end
  -- An edit from the agenda (t, +, -, Space o i s, Space o $ ...). orgmode
  -- opens the task's file in a hidden window, makes the change there and
  -- closes it later, so keys typed meanwhile (j, r, x ...) ran inside the org
  -- file and were saved into it, and a quick second key hit a stale row.
  -- Here the whole edit, including the redraw after it, finishes before the
  -- next key runs (they wait in line). Only a prompt with its own window
  -- (the date picker) is left to take your keys; the edit finishes when you
  -- close it. And if a file changed since orgmode read it (a sync tool ran),
  -- the agenda is redrawn first; if the row you were on is gone, nothing is
  -- changed and you are told.
  local utils = require('orgmode.utils')
  local remote_edit = Agenda._remote_edit
  local function wait(p)
    if type(p) == 'table' and p.wait then
      return pcall(p.wait, p, 15000)
    end
    return true
  end
  -- One change to one task, start to finish: its file opened in a hidden
  -- window, `run` called there with the cursor on the task, the file saved
  -- and re-read. `after` (given the task as it is now) runs once the file is
  -- re-read. Returns the promise of all that, and whether the file changed
  -- (only known when no prompt window took over).
  local function edit_task(self, headline, run, after)
    local file = headline.file
    local edit = utils.edit_file(file.filename)
    edit.open()
    local edit_win = vim.api.nvim_get_current_win()
    local edit_buf = vim.api.nvim_get_current_buf()
    local tick = vim.api.nvim_buf_get_changedtick(edit_buf)
    -- for u in the agenda: this edit starts an undo step of its own in the
    -- file (setting 'undolevels' to itself closes the one before)
    local s = step
    vim.cmd('let &g:undolevels = &g:undolevels')
    local before = vim.fn.changenr()
    local function close()
      if vim.api.nvim_win_is_valid(edit_win) then
        vim.api.nvim_set_current_win(edit_win)
        edit.close()
      end
    end
    vim.fn.cursor({ headline:get_range().start_line, 1 })
    local ok, result = pcall(run)
    if not ok then
      pcall(close)
      vim.notify('nvim kit: ' .. tostring(result), vim.log.levels.ERROR)
      return
    end
    local changed = false
    local function finish()
      changed = vim.api.nvim_buf_is_valid(edit_buf) and vim.api.nvim_buf_get_changedtick(edit_buf) ~= tick
      if changed then
        record(s, file.filename, before, vim.api.nvim_buf_call(edit_buf, vim.fn.changenr))
      end
      local updated = self.files:get_closest_headline_or_nil()
      close()
      return file:reload():next(function()
        if after then
          return after(updated)
        end
      end)
    end
    local busy = type(result) == 'table' and result._state == 'pending' and result.next
    if busy and vim.api.nvim_get_current_win() ~= edit_win then
      -- a prompt window (the date picker) has your keys: finish after it
      return result:next(finish, function(err)
        pcall(close)
        return err
      end)
    end
    if busy and not wait(result) then
      pcall(close)
      return
    end
    local done = finish()
    wait(done)
    -- some actions (archive) run more steps later in orgmode's own hidden
    -- windows; wait until none is open, so no key lands in a file
    vim.wait(15000, function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local ok_, tmp = pcall(vim.api.nvim_buf_get_var, vim.api.nvim_win_get_buf(w), 'org_tmp_edit_window')
        if ok_ and tmp then
          return false
        end
      end
      return true
    end, 20)
    return done, changed
  end

  -- what u in the agenda can not take back: these reach other files or
  -- windows (the archive file, the refile target, a running clock, a note)
  local NOT_UNDOABLE = {
    ['org_mappings.archive'] = true,
    ['capture.refile_headline_to_destination'] = true,
    ['clock.org_clock_in'] = true,
    ['clock.org_clock_out'] = true,
    ['clock.org_clock_cancel'] = true,
    ['org_mappings.add_note'] = true,
  }
  local kit_remote_edit
  replace(Agenda, '_remote_edit', function(self, opts)
    local own = step_start(not NOT_UNDOABLE[(opts or {}).action])
    local ok_, res = pcall(kit_remote_edit, self, opts)
    step_stop(own)
    if not ok_ then
      error(res, 0)
    end
    return res
  end)
  kit_remote_edit = function(self, opts)
    opts = opts or {}
    if not opts.action then
      return
    end
    local getter = opts.getter or function()
      return self:_get_headline()
    end
    if stale(self.files) and vim.bo.filetype == 'orgagenda' then
      if not M.refresh_now() then
        vim.notify('nvim kit: the agenda changed under the cursor (a sync?). Nothing was changed; check the row and press the key again.',
          vim.log.levels.WARN)
        return
      end
    end
    local headline, agenda_line, view = getter()
    if not headline then
      return
    end
    pending = capture(self)
    -- (a kit action is a function, M.edit; orgmode's own are names)
    local own = type(opts.action) == 'function'
    if headline.file.filename == utils.current_file_path() and not own then
      return remote_edit(self, opts)
    end
    local old_range = headline:get_range()
    return (edit_task(self, headline, function()
      if own then
        return opts.action()
      end
      return require('orgmode').action(opts.action)
    end, function(updated)
      if opts.redo then
        return self:redo('remote_edit', true)
      end
      if not opts.update_in_place or not updated then
        return
      end
      if updated:get_range():is_same_line_range(old_range) and agenda_line and view then
        return view:rerender_agenda_line(agenda_line, updated)
      end
      return self:redo('remote_edit', true)
    end))
  end

  -- Space o p s / Space o p p in the agenda: `run` gets the task under the
  -- cursor, in its file, and changes it there, through the same edit path as
  -- t or +. True when it ran.
  M._edit = function(run)
    local ran = false
    local agenda = require('orgmode').agenda
    agenda:_remote_edit({
      update_in_place = true,
      action = function()
        run(require('orgmode').files:get_closest_headline())
        ran = true
      end,
    })
    return ran
  end

  -- -------------------------------------------------------------------------
  --  V then t / + / - / Space o i s / Space o i d / Space o $: one change for
  --  every task in the selected rows (orgmode has none of its own). The
  --  tasks are taken from the rows as they were drawn (file, heading line,
  --  its text) before anything changes; the keyword menu or the date picker
  --  opens once; then each task gets the same edit as its single key, one
  --  after the other, and the agenda redraws once at the end. A file is
  --  edited from its last selected task up, so an edit (a CLOSED line added,
  --  a heading archived) never moves a task still to come. Right before each
  --  edit the heading line is checked against the text drawn; a task whose
  --  line no longer matches (a sync changed it) is left alone and counted.
  --  Rows without a task (day lines, hours, headers) are skipped, and so are
  --  tasks inside a closed list. A task shown on two selected rows changes
  --  once.
  -- -------------------------------------------------------------------------
  -- a heading line as it compares: statistics cookies ([1/3], [50%]) left
  -- out (orgmode updates a parent's when a child changes), trailing blanks too
  local function same_line(a, b)
    local function norm(s)
      return ((s or ''):gsub('%s*%[%d*/%d*%]', ''):gsub('%s*%[%d*%%%]', ''):gsub('%s+$', ''))
    end
    return a ~= nil and norm(a) == norm(b)
  end

  -- the task a row was, in its file as it is now; nil when it is not there
  -- (or two headings read the same and it could be either)
  local function find_task(agenda, id)
    local ok, file = pcall(agenda.files.get, agenda.files, id.file)
    if not ok or not file then
      return nil
    end
    local line
    if same_line(file.lines[id.line], id.text) then
      line = id.line
    else
      for i, text in ipairs(file.lines) do
        if text:match('^%*+%s') and same_line(text, id.text) then
          if line then
            return nil
          end
          line = i
        end
      end
    end
    local h = line and file:get_closest_headline_or_nil({ line, 0 })
    if h and h:get_range().start_line == line then
      return h
    end
  end

  -- the tasks in agenda rows l1 to l2, each once, and the first row with one
  local function selected_tasks(agenda, l1, l2)
    local ids, seen, first = {}, {}, nil
    for lnum = l1, l2 do
      if vim.fn.foldclosed(lnum) == -1 then
        for _, v in ipairs(agenda.views or {}) do
          local l = v.view and v:get_line(lnum)
          local id = l and l.headline and l.metadata and l.metadata.kit_task
          if id and id.text then
            first = first or lnum
            local key = id.file .. '\n' .. id.line
            if not seen[key] then
              seen[key] = true
              table.insert(ids, id)
            end
          end
        end
      end
    end
    return ids, seen, first
  end

  -- Edit each task (`how` gives the change for a task, or nil when it is
  -- already so), then redraw once. Keys typed meanwhile wait their turn.
  -- (one step for u in the agenda: M._bulk says false for archive)
  local bulk_undoable = true
  local apply_all
  local function apply(agenda, ids, l2, seen, first, how)
    local own = step_start(bulk_undoable)
    local ok_, changed, same, missing = pcall(apply_all, agenda, ids, l2, seen, first, how)
    step_stop(own)
    if not ok_ then
      error(changed, 0)
    end
    return changed, same, missing
  end
  apply_all = function(agenda, ids, l2, seen, first, how)
    local win = agenda_window()
    if win and first then
      pcall(vim.api.nvim_win_set_cursor, win, { first, 0 })
    end
    local c = capture(agenda, l2, seen)
    refresh_buffers(agenda.files)
    table.sort(ids, function(a, b)
      if a.file ~= b.file then
        return a.file < b.file
      end
      return a.line > b.line
    end)
    local changed, same, missing = 0, 0, 0
    -- orgmode says "Archived to <file>" after each; one line at the end says it all
    local echo_info = utils.echo_info
    utils.echo_info = function() end
    local ok, err = pcall(function()
      for _, id in ipairs(ids) do
        local headline = find_task(agenda, id)
        local run = headline and how(headline)
        if not headline then
          missing = missing + 1
        elseif not run then
          same = same + 1
        else
          local _, did = edit_task(agenda, headline, run)
          if did then
            changed = changed + 1
          else
            same = same + 1
          end
        end
      end
    end)
    utils.echo_info = echo_info
    if not ok then
      vim.notify('nvim kit: ' .. tostring(err), vim.log.levels.ERROR)
    end
    -- one redraw; the cursor stays on the first task if it is still there,
    -- else goes to the row that was below the selection
    pending = c
    pcall(function()
      agenda:redo('kit_edit', true):wait(15000)
    end)
    pending = nil
    return changed, same, missing
  end

  local function report(what, changed, same, missing)
    local parts = { ('%s: %d task%s'):format(what, changed, changed == 1 and '' or 's') }
    if same > 0 then
      table.insert(parts, ('%d unchanged'):format(same))
    end
    if missing > 0 then
      -- the agenda has been redrawn by now: select them again
      table.insert(parts, ('%d skipped (file changed)'):format(missing))
    end
    vim.notify(table.concat(parts, ', '), missing > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
  end

  M._bulk = function(kind, l1, l2)
    bulk_undoable = kind ~= 'archive'
    local agenda = require('orgmode').agenda
    local ids, seen, first = selected_tasks(agenda, l1, l2)
    if #ids == 0 then
      vim.notify('No tasks in the selected rows')
      return
    end
    local n = #ids
    local action = ({ up = 'org_mappings.priority_up', down = 'org_mappings.priority_down', archive = 'org_mappings.archive' })[kind]
    if action then
      local what = ({ up = 'Priority up', down = 'Priority down', archive = 'Archived' })[kind]
      report(what, apply(agenda, ids, l2, seen, first, function()
        return function()
          return require('orgmode').action(action)
        end
      end))
      return
    end

    if kind == 'todo' then
      -- the keyword menu, once (the first task's file says which keywords)
      local ok, file = pcall(agenda.files.get, agenda.files, ids[1].file)
      local todos = ok and file and file:get_todo_keywords() or nil
      local choice = TodoState:new({ todos = todos }):open_fast_access()
      if not choice then
        return
      end
      local value = choice.value
      report(value ~= '' and ('Marked ' .. value) or 'Keyword removed', apply(agenda, ids, l2, seen, first, function(headline)
        local own = value == '' and TodoKeyword:empty() or headline.file:get_todo_keywords():find(value)
        if not own or (headline:get_todo() or '') == value then
          return nil -- already so, or its file has no such keyword
        end
        -- orgmode's own t, with the menu answered: CLOSED lines, repeats
        -- and their notes come out exactly as for one task
        return function()
          local has, open = TodoState.has_fast_access, TodoState.open_fast_access
          TodoState.has_fast_access = function()
            return true
          end
          TodoState.open_fast_access = function()
            return own
          end
          local ok_, result = pcall(require('orgmode').action, 'org_mappings.todo_next_state')
          TodoState.has_fast_access, TodoState.open_fast_access = has, open
          if not ok_ then
            error(result, 0)
          end
          return result
        end
      end))
      return
    end

    if kind == 'schedule' or kind == 'deadline' then
      -- the date picker, once, on the first task's day. It picks a day only:
      -- each task keeps its own time, repeat (+1w) and warning (-3d), so the
      -- first task's are never copied onto the others. A time set in the
      -- picker (t) goes to every task.
      local function own_date(task)
        if kind == 'schedule' then
          return task:get_scheduled_date()
        end
        return task:get_deadline_date()
      end
      local start = Date.today()
      local ok, h = pcall(find_task, agenda, ids[1])
      local first_date = ok and h and own_date(h)
      if first_date then
        start = start:set({ year = first_date.year, month = first_date.month, day = first_date.day })
      end
      local title = ('%s: %d task%s'):format(kind == 'schedule' and 'Set schedule' or 'Set deadline', n, n == 1 and '' or 's')
      return Calendar.new({ date = start, clearable = true, title = title }):open()
        :next(function(date, cleared)
          if not date and not cleared then
            return
          end
          local what = kind == 'schedule' and 'Start date' or 'Deadline'
          local ok_, err = pcall(function()
            report(cleared and (what .. ' removed') or (what .. ' set'), apply(agenda, ids, l2, seen, first, function()
              -- as orgmode's own Space o i s / d does it for one task
              return function()
                local task = require('orgmode').files:get_closest_headline()
                if cleared then
                  return kind == 'schedule' and task:remove_scheduled_date() or task:remove_deadline_date()
                end
                -- the picked day on this task's own date (time, repeat and
                -- warning kept); a task without one gets the day as picked
                local d = date
                local own = own_date(task)
                if own then
                  local set = { year = date.year, month = date.month, day = date.day }
                  if date:has_time() then
                    set.hour, set.min, set.date_only = date.hour, date.min, false
                  end
                  d = own:set(set)
                end
                task:remove_closed_date()
                if kind == 'schedule' then
                  task:set_scheduled_date(d)
                else
                  task:set_deadline_date(d)
                end
              end
            end))
          end)
          if not ok_ then
            vim.notify('nvim kit: ' .. tostring(err), vim.log.levels.ERROR)
          end
        end)
    end
  end

  -- r: re-read what a sync changed, and finish before the next key runs
  local redo = Agenda.redo
  replace(Agenda, 'redo', function(self, source, ...)
    refresh_buffers(self.files)
    local result = redo(self, source, ...)
    if (source == 'remote_edit' or source == 'kit_edit') and pending and result and result.next then
      local c = pending
      pending = nil
      result = result:next(function(...)
        follow(self, c)
        return ...
      end)
    end
    if source == 'mapping' and result and result.wait then
      pcall(result.wait, result, 15000)
    end
    return result
  end)
  local function redo_following()
    return require('orgmode').agenda:redo('kit_edit', true)
  end
  replace(AgendaType, 'rerender_agenda_line', function()
    return redo_following()
  end)
  local rerender_todo = TodoType.rerender_agenda_line
  replace(TodoType, 'rerender_agenda_line', function(self, agenda_line, headline)
    -- (the Done view: t reopens a task, and it leaves the list. A list by
    -- state, like In progress in Space o a d: t moves the task to another
    -- list or out of the view; redrawn in place it stayed, as DONE / TODO,
    -- under In progress until r.)
    if self.kit_list or is_done_view(self) or is_completed_block(self) or type(self.match_query) == 'string'
      or shown_twice(headline) then
      return redo_following()
    end
    return rerender_todo(self, agenda_line, headline)
  end)

  -- vd / vw on a calendar row open the day under the cursor (cells are
  -- CAL_PITCH columns wide, after the week number)
  local change_span = AgendaType.change_span
  replace(AgendaType, 'change_span', function(self, span)
    local line = self.view and self:get_line(vim.fn.line('.'))
    local cells = line and line.metadata and line.metadata.kit_cells
    if cells then
      local idx = math.max(1, math.min(7, math.floor((vim.fn.col('.') - 1 - CAL_LEFT) / CAL_PITCH) + 1))
      local cell = cells[idx]
      for off = 1, 6 do
        cell = cell or cells[idx + off] or cells[idx - off]
      end
      if cell then
        line.metadata.agenda_day = cell.day
      end
    end
    return change_span(self, span)
  end)

  local get_file_headlines = TagsType.get_file_headlines
  replace(TagsType, 'get_file_headlines', function(self, file)
    if is_done_view(self) or is_completed_block(self) then
      -- every done state, a file's own #+TODO done words too
      return vim.tbl_filter(function(headline)
        return headline:is_done()
      end, file:get_opened_headlines())
    end
    local headlines = get_file_headlines(self, file)
    if self.header ~= M.UNDATED then
      return headlines
    end
    return vim.tbl_filter(function(headline)
      return #headline:get_valid_dates_for_agenda() == 0
    end, headlines)
  end)

  -- nothing acts on a task hidden inside a closed list
  local function hidden()
    return vim.bo.filetype == 'orgagenda' and vim.fn.foldclosed('.') ~= -1
  end
  local get_headline = Agenda._get_headline
  replace(Agenda, '_get_headline', function(self, ...)
    if hidden() then
      return nil
    end
    return get_headline(self, ...)
  end)
  local at_cursor = Agenda.get_headline_at_cursor
  replace(Agenda, 'get_headline_at_cursor', function(self, ...)
    if hidden() then
      return nil
    end
    return at_cursor(self, ...)
  end)

  -- / in the agenda: a word that is no tag or category here (a file's name
  -- is its category) looks in the titles, as /word/ does. orgmode kept
  -- only the tags and categories it knew and dropped the rest, so a plain
  -- word filtered nothing, and said nothing. +tag, -tag, a category and
  -- /regexp/ work as before. The word is plain text (\V: "a.b" is a dot,
  -- "[x" no regexp error) and smartcase, as search is: all lower case
  -- matches any case, so "migrate" finds "Migrate the wiki". (orgmode
  -- matches with vim.regex, which ignores 'ignorecase'.)
  local parse = AgendaFilter.parse
  replace(AgendaFilter, 'parse', function(self, filter, skip_check)
    local text = vim.trim(filter or '')
    if not skip_check and text ~= '' and not text:find('[/+-]') and not (self.available_values or {})[text] then
      local term = (text:find('%u') and '' or '\\c') .. '\\V' .. text:gsub('\\', '\\\\')
      local result = parse(self, '/' .. term .. '/', skip_check)
      -- (the next / starts from the word as you typed it)
      self.value = text
      return result
    end
    return parse(self, filter, skip_check)
  end)

  -- Space o a d and the other custom views open unfiltered (a / filter set
  -- in another view would otherwise carry over with nothing saying so)
  local build_custom = Agenda._build_custom_commands
  replace(Agenda, '_build_custom_commands', function(self, ...)
    local commands = build_custom(self, ...)
    for _, c in ipairs(commands) do
      local action = c.action
      local args = nil
      -- a command with kit_lists = 'priority' (Space o a p) is the task lists
      local lists_by = (config.org_agenda_custom_commands[c.key] or {}).kit_lists
      if lists_by then
        action = function()
          return self:todos({ kit_by = lists_by })
        end
      end
      c.action = function(...)
        args = { ... }
        M.remember()
        new_files(self.files)
        self.filters:reset()
        return keep_cursor(function()
          return action(unpack(args))
        end)
      end
    end
    return commands
  end)

  -- Space o a t (the menu's "t") opens the task lists by file; Space o a p
  -- and o pass kit_by = 'priority'
  replace(Agenda, 'todos', function(self, opts)
    M.remember()
    M.by = opts and opts.kit_by or 'file'
    new_files(self.files)
    self.filters:reset()
    self.views = task_lists(self)
    return self:prepare_and_render():next(function()
      local win = agenda_window()
      if win then
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
      end
    end)
  end)
  local open_view = Agenda.open_view
  replace(Agenda, 'open_view', function(self, ...)
    M.remember()
    new_files(self.files)
    return open_view(self, ...)
  end)
  vim.api.nvim_create_autocmd('BufLeave', {
    group = vim.api.nvim_create_augroup('kit_agenda_lists', { clear = true }),
    callback = function()
      if vim.bo.filetype == 'orgagenda' then
        pcall(M.remember)
      end
    end,
  })

  -- Measure the columns first. Draw inside the agenda window when one is
  -- open: a redraw can finish after another window became current (orgmode
  -- redraws after its file reads), and drawing moves the cursor of the
  -- current window. Afterwards long titles wrap and hang under the title
  -- column (the clock table does not wrap: it is a table).
  local agenda_render = Agenda.render
  replace(Agenda, 'render', function(self, ...)
    if not failed then
      measure_keywords(self.files)
      -- a view opened (or moved with f / b) after a sync draws what is on
      -- disk now, not what orgmode read before
      if stale(self.files) then
        refresh_buffers(self.files)
        pcall(function()
          self.files:load(true):wait(15000)
        end)
      end
    end
    -- task lists: note which are open, then rebuild them, so a new file or
    -- synced-in list shows up on the next redraw
    if not failed and is_lists(self) then
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'orgagenda' and vim.api.nvim_win_get_config(win).relative == '' then
          remember_lists(self, win)
        end
      end
      local fresh = task_lists(self)
      if #fresh > 0 then
        self.views = fresh
      end
    end
    local agenda_win
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == ''
        and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'orgagenda' then
        agenda_win = win
      end
    end
    local result
    if agenda_win and agenda_win ~= vim.api.nvim_get_current_win() then
      local args = { ... }
      vim.api.nvim_win_call(agenda_win, function()
        result = agenda_render(self, unpack(args))
      end)
    else
      result = agenda_render(self, ...)
    end
    if failed then
      return result
    end
    local clock = false
    for _, v in ipairs(self.views or {}) do
      clock = clock or v.show_clock_report == true
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == 'orgagenda' and vim.api.nvim_win_get_config(win).relative == '' then
        for name, value in pairs({
          wrap = not clock, linebreak = true, breakindent = true,
          breakindentopt = 'column:' .. M.title_col .. ',min:10',
          cursorline = true, winhighlight = 'CursorLine:KitAgendaCursor,Folded:KitAgendaFolded',
          conceallevel = 2, concealcursor = 'nc', -- links read as their text
          foldtext = "v:lua.require'kit.agenda'.foldtext()", fillchars = 'fold: ', foldcolumn = '0',
          foldenable = true,
        }) do
          vim.api.nvim_set_option_value(name, value, { scope = 'local', win = win })
        end
        fold_lists(self, win)
        color_list_headers(self, buf)
      end
    end
    return result
  end)
  return true
end

return M
