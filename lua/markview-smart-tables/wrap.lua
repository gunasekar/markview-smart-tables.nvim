--[[
Column-fit & word-wrap maths.

`word_wrap` and `fit_columns` are pure(display-width-aware, no editor state)
so they can be unit-tested in isolation; `fit_target` resolves the configured
`wrap_width` against a window.
]]
local M = {}

--- Takes the longest prefix of {str} whose display width is `≤ {width}`.
---
--- Unicode-aware(splits on character boundaries, accounts for wide glyphs).
--- Always consumes at least one character to avoid infinite loops.
---@param str string
---@param width integer
---@return string prefix
---@return string rest
local function take_prefix(str, width)
  local chars = vim.fn.split(str, "\\zs")
  local out, w, idx = "", 0, 0

  for i, ch in ipairs(chars) do
    local cw = vim.fn.strdisplaywidth(ch)

    if w + cw > width then
      break
    end

    out = out .. ch
    w = w + cw
    idx = i
  end

  if idx == 0 then
    --- A single character wider than {width}; take it anyway so we make
    --- progress.
    out = chars[1] or ""
    idx = 1
  end

  local rest = table.concat(vim.list_slice(chars, idx + 1), "")
  return out, rest
end

--- Word-wraps {text} into lines of display width `≤ {width}`.
---
--- Breaks on whitespace where possible and hard-breaks a single word that is
--- wider than {width}. Collapses runs of inter-word whitespace into a single
--- space(matching how the wrapped text is re-drawn).
---@param text string
---@param width integer
---@return string[]
M.word_wrap = function(text, width)
  width = math.max(1, width)

  local lines = {}
  local cur, cur_w = "", 0

  for word in string.gmatch(text, "%S+") do
    local ww = vim.fn.strdisplaywidth(word)

    if ww > width then
      --- Word is too long, flush the current line then hard-break the
      --- word across as many lines as needed.
      if cur ~= "" then
        table.insert(lines, cur)
      end

      local rest = word

      while vim.fn.strdisplaywidth(rest) > width do
        local pre, r = take_prefix(rest, width)
        table.insert(lines, pre)
        rest = r
      end

      cur, cur_w = rest, vim.fn.strdisplaywidth(rest)
    elseif cur_w == 0 then
      cur, cur_w = word, ww
    elseif cur_w + 1 + ww <= width then
      cur = cur .. " " .. word
      cur_w = cur_w + 1 + ww
    else
      table.insert(lines, cur)
      cur, cur_w = word, ww
    end
  end

  if cur ~= "" or #lines == 0 then
    table.insert(lines, cur)
  end

  return lines
end

--- Display width of a list of `{ text, hl }` segments.
---@param segs table[]
---@return integer
local function segs_width(segs)
  local w = 0
  for _, s in ipairs(segs) do
    w = w + vim.fn.strdisplaywidth(s.text)
  end
  return w
end

--- Flattens a word(list of segments) to per-character `{ ch, hl }` entries.
---@param word table[]
---@return table[]
local function word_chars(word)
  local out = {}
  for _, s in ipairs(word) do
    for _, ch in ipairs(vim.fn.split(s.text, "\\zs")) do
      out[#out + 1] = { ch = ch, hl = s.hl }
    end
  end
  return out
end

--- Coalesces a `{ ch, hl }` character run back into `{ text, hl }` segments.
---@param chars table[]
---@return table[]
local function coalesce(chars)
  local segs, cur = {}, nil
  for _, c in ipairs(chars) do
    if cur and cur.hl == c.hl then
      cur.text = cur.text .. c.ch
    else
      cur = { text = c.ch, hl = c.hl }
      segs[#segs + 1] = cur
    end
  end
  return segs
end

--- Hard-breaks a word wider than {width} into segment-lines, each `≤ {width}`
--- display cells, keeping each character's highlight. Always makes progress.
---@param word table[]
---@param width integer
---@return table[][]
local function break_word(word, width)
  local lines = {}
  local cur, cur_w = {}, 0

  for _, c in ipairs(word_chars(word)) do
    local cw = vim.fn.strdisplaywidth(c.ch)
    if cur_w + cw > width and #cur > 0 then
      lines[#lines + 1] = coalesce(cur)
      cur, cur_w = {}, 0
    end
    cur[#cur + 1] = c
    cur_w = cur_w + cw
  end

  if #cur > 0 then
    lines[#lines + 1] = coalesce(cur)
  end

  return lines
end

--- Highlight-aware counterpart of `word_wrap`. Wraps a {words} list(each word a
--- list of `{ text, hl }` segments, no inter-word whitespace) into lines of
--- display width `≤ {width}`, carrying every segment's highlight through so a
--- cell can show inline markup(e.g. code spans). Words are joined by a plain
--- space.
---
--- Returns a list of lines; each line is a list of `{ text, hl }` chunks ready
--- to drop into a `virt_lines` entry.
---@param words table[][]
---@param width integer
---@return table[][]
M.style_wrap = function(words, width)
  width = math.max(1, width)

  local lines = {}
  local cur, cur_w = nil, 0

  --- Shallow-copies a word's segments into standalone chunks.
  local function chunks_of(segs)
    local out = {}
    for _, s in ipairs(segs) do
      out[#out + 1] = { text = s.text, hl = s.hl }
    end
    return out
  end

  for _, word in ipairs(words) do
    local ww = segs_width(word)

    if ww > width then
      --- Too wide: flush the current line, then hard-break the word. {cur}/
      --- {cur_w} are reassigned from the last piece below, so no reset here.
      if cur then
        lines[#lines + 1] = cur
      end

      local pieces = break_word(word, width)
      for i = 1, #pieces - 1 do
        lines[#lines + 1] = chunks_of(pieces[i])
      end
      cur = chunks_of(pieces[#pieces])
      cur_w = segs_width(pieces[#pieces])
    elseif not cur then
      cur, cur_w = chunks_of(word), ww
    elseif cur_w + 1 + ww <= width then
      cur[#cur + 1] = { text = " " }
      for _, s in ipairs(word) do
        cur[#cur + 1] = { text = s.text, hl = s.hl }
      end
      cur_w = cur_w + 1 + ww
    else
      lines[#lines + 1] = cur
      cur, cur_w = chunks_of(word), ww
    end
  end

  if cur or #lines == 0 then
    lines[#lines + 1] = cur or {}
  end

  return lines
end

--- Shrinks {natural} column widths so that the rendered table fits inside
--- {budget} display columns.
---
--- Columns wider than the rest are shrunk first(so narrow columns keep their
--- content) but never below {min_col}. If everything already fits, the natural
--- widths are returned unchanged.
---@param natural integer[]
---@param budget integer Display columns available for cell content(borders excluded).
---@param min_col integer Smallest width a column may shrink to.
---@return integer[] fitted
---@return boolean shrunk Whether any column was actually narrowed.
M.fit_columns = function(natural, budget, min_col)
  local fitted = {}
  local total = 0

  for i, w in ipairs(natural) do
    fitted[i] = w
    total = total + w
  end

  if #fitted == 0 or total <= budget then
    return fitted, false
  end

  local shrunk = false
  local guard = 0

  --- Shave one cell off the widest column wider than {floor}, repeatedly,
  --- until the table fits the budget or no column can shrink further. Tables
  --- are small, so this stays cheap; the guard is only a runaway safety net.
  local function shrink_to(floor)
    while total > budget and guard < 200000 do
      guard = guard + 1

      local widest, wi = -1, nil

      for i, w in ipairs(fitted) do
        if w > floor and w > widest then
          widest = w
          wi = i
        end
      end

      if not wi then
        break
      end

      fitted[wi] = fitted[wi] - 1
      total = total - 1
      shrunk = true
    end
  end

  --- First honour `min_col`. If the budget is so tight that even every column
  --- at `min_col` still overflows(very narrow window + many columns), force
  --- columns below it down to 1 so the table never exceeds the budget —
  --- readability yields to fitting at extreme widths.
  shrink_to(min_col)

  if total > budget then
    shrink_to(1)
  end

  return fitted, shrunk
end

--- Target width(in cells) the rendered table must fit in, from `wrap_width`:
---   * a fraction in `(0, 1]` — that share of the window width(`0.9` ⇒ 90%).
---   * an integer `> 1`       — an absolute column count(clamped to the window).
---   * anything else          — defaults to 90% of the window.
---@param win integer
---@param config table Config with a `wrap_width` field.
---@return integer
M.fit_target = function(win, config)
  local info = vim.fn.getwininfo(win)[1]
  local textoff = info and info.textoff or 0
  local win_width = vim.api.nvim_win_get_width(win) - textoff

  local ww = config.wrap_width

  if type(ww) == "number" and ww > 0 and ww <= 1 then
    return math.floor(win_width * ww)
  elseif type(ww) == "number" and ww > 1 then
    return math.min(win_width, math.floor(ww))
  else
    return math.floor(win_width * 0.9)
  end
end

return M
