--[[
Per-source-row placement for a fitted table, used when `per_line = true`.
See `table.lua` for the renderer that builds the groups and for the default
(single `virt_lines` block) placement.

`M.place(buffer, ns, win, range, groups)` draws each group on its own source
row: the raw markdown is `conceal`ed in place and the row's rendered lines are
painted over it as `overlay` virtual text, with the borders hanging off the same
row as `virt_lines`. The source rows keep their screen height, so the cursor
stays visible and lands on the row it is actually on.

{groups} is `table.lua`'s grouping, one entry per source line, and is plain
data — this module does not build it. Returns `false` without touching the
buffer when the table cannot be drawn this way, so the caller can fall back.
]]
local M = {}

local wrap = require("markview-smart-tables.wrap")

--- Moves {g}'s leading border line onto the row's own screen line, pushing the
--- row's content down into {cont}. `virt_lines_above` is not drawn when its
--- row is the window's topmost line, so a table on the first buffer line would
--- otherwise lose its top border.
---@param g markview_smart_tables.group
local function fold_top_border(g)
  if #g.above == 0 then
    return
  end

  local cont = { g.first }
  vim.list_extend(cont, g.cont)

  g.first = table.remove(g.above, 1)
  g.cont = cont
end

--- Drops markview's *other* decorations from the rows we own.
---
--- markview gives each language renderer its own namespace — `markview/inline`
--- (code-span padding, link icons), `markview/latex` (maths), `markview/html`,
--- and so on. They all decorate the **raw** cell text. Ours is {ns}, markview's
--- markdown namespace; every other `markview/*` namespace is foreign here.
---
--- Under `conceal_lines` those marks are invisible — the row has no height —
--- but a per-line row is only `conceal`ed, and virtual text inside a concealed
--- range is still drawn, so they stack on top of the fitted row. The fitted
--- copy renders that styling itself(`inline.lua`), so they are redundant.
---
--- Deferred because markview renders its languages in `pairs()` order: another
--- renderer may run after this one. {ids} are our conceal marks; a row is only
--- cleared while its mark is still alive, so a row that stopped being a table
--- keeps markview's own decorations.
---@param buffer integer
---@param ns integer
---@param ids integer[]
local function drop_foreign_marks(buffer, ns, ids)
  local foreign = {}

  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if id ~= ns and name:match("^markview/") then
      foreign[#foreign + 1] = id
    end
  end

  if #foreign == 0 then
    return
  end

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buffer) == false then
      return
    end

    for _, id in ipairs(ids) do
      local mark = vim.api.nvim_buf_get_extmark_by_id(buffer, ns, id, {})

      if mark[1] then
        for _, fns in ipairs(foreign) do
          pcall(vim.api.nvim_buf_clear_namespace, buffer, fns, mark[1], mark[1] + 1)
        end
      end
    end
  end)
end

--- True when {win}'s soft-wrap does not break lines at fixed multiples of the
--- window width, which is what `wrap.break_cols` assumes: `'linebreak'` breaks at
--- word boundaries, and `'breakindent'`/`'showbreak'` shift every continuation
--- row rightwards.
---@param win integer
---@return boolean
local function irregular_wrap(win)
  return vim.wo[win].linebreak == true
    or vim.wo[win].breakindent == true
    or vim.wo[win].showbreak ~= ""
end

--- Draws each {groups} entry on its own source row: the raw markdown is
--- `conceal`ed in place and the row's rendered lines are painted over it as
--- `overlay` virtual text, with borders hanging off the same row as
--- `virt_lines`.
---
--- Unlike `place`, the source rows keep their screen height, so the cursor
--- stays visible and lands on the row it is actually on. No anchor line is
--- needed — a table may span the whole buffer.
---
--- Keeping that height is also the complication. `conceal` hides characters
--- but does not shorten the line, so under `'wrap'` a source row still occupies
--- the screen rows its *raw* width needs. Painting only one line there would
--- leave the rest blank and tear the table apart, so the row's continuation
--- lines are painted onto those rows too — an overlay anchored at the byte
--- column where a soft-wrap row begins lands at its left edge. A row is padded
--- with empty cells when it renders to fewer lines than it occupies, and spills
--- the surplus into `virt_lines` when it renders to more.
---
---@param buffer integer
---@param ns integer
---@param win integer
---@param range table
---@param groups markview_smart_tables.group[]
---@return boolean placed
M.place = function(buffer, ns, win, range, groups)
  local first_row = range.row_start
  local lines = vim.api.nvim_buf_get_lines(buffer, first_row, first_row + #groups, false)

  --- The group count comes from markview's parse; if the buffer shrank before
  --- this render callback ran(rapid edits, async deletion), the source rows may
  --- no longer exist and `nvim_buf_set_extmark` below would throw "row value
  --- outside range". Decline so the caller falls back to `place`.
  if #lines < #groups then
    return false
  end

  --- Only soft-wrap puts a row on more than one screen row, and only a regular
  --- wrap has predictable break columns.
  local wrapped = vim.wo[win].wrap == true

  if wrapped and irregular_wrap(win) then
    return false
  end

  --- Past every decline, so a declined table is handed back unmodified.
  if range.row_start == 0 then
    fold_top_border(groups[1])
  end

  local width = wrapped and wrap.text_width(win) or 0
  local ids = {}

  for i, g in ipairs(groups) do
    local row, line = first_row + i - 1, lines[i]
    local anchors = wrapped and wrap.break_cols(line, width) or { 0 }

    ids[i] = vim.api.nvim_buf_set_extmark(buffer, ns, row, 0, {
      undo_restore = false,
      invalidate = true,
      end_row = row,
      end_col = #line,
      end_right_gravity = true,
      conceal = "",
    })

    local painted = { g.first }
    vim.list_extend(painted, g.cont)

    --- The row renders to fewer lines than it occupies: pad with empty cells so
    --- the leftover screen rows read as part of the row, not as a gap.
    for _ = #painted + 1, #anchors do
      painted[#painted + 1] = g.blank
    end

    --- `overlay`, not `inline`: inline virtual text is inserted into the line
    --- and counts towards soft-wrap, so it would push the row's own layout
    --- around. An overlay is painted over the(concealed) text instead.
    for k = 1, math.min(#painted, #anchors) do
      vim.api.nvim_buf_set_extmark(buffer, ns, row, anchors[k], {
        undo_restore = false,
        invalidate = true,
        virt_text = painted[k],
        virt_text_pos = "overlay",
      })
    end

    --- Whatever did not fit on the row's own screen rows, then its borders.
    local below = {}

    for k = #anchors + 1, #painted do
      below[#below + 1] = painted[k]
    end

    vim.list_extend(below, g.after)

    if #g.above > 0 then
      vim.api.nvim_buf_set_extmark(buffer, ns, row, 0, {
        undo_restore = false,
        invalidate = true,
        virt_lines = g.above,
        virt_lines_above = true,
      })
    end

    if #below > 0 then
      vim.api.nvim_buf_set_extmark(buffer, ns, row, 0, {
        undo_restore = false,
        invalidate = true,
        virt_lines = below,
      })
    end
  end

  drop_foreign_marks(buffer, ns, ids)
  return true
end

return M
