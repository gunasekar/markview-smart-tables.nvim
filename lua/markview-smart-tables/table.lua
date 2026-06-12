--[[
Fully-virtual table renderer, drawn through `markview.nvim`'s custom-renderer
hook(`renderers.markdown_table`). See `init.lua` for the hook, `wrap.lua` for
the fit/word-wrap maths, and `resize.lua` for the re-render-on-resize autocmd
this module registers on first use.

`M.render(buffer, item, config, ns)` redraws the whole fitted table as
virtual lines over the hidden(`conceal_lines`) source rows. {config} is
markview's `markdown.tables` config(for `parts`/`hl`) merged with this
plugin's options; {ns} is markview's markdown namespace, so markview's own
clear cycle wipes these extmarks. Returns `false`(without rendering) when the
table should be handled by markview's stock renderer instead: always on
Neovim < 0.11, and under `'nowrap'` whenever the table already fits the
window(the in-buffer rendering is preferable — real text, visible cursor).
]]
local M = {}

local utils = require("markview.utils")
local spec = require("markview.spec")

local wrap = require("markview-smart-tables.wrap")
local resize = require("markview-smart-tables.resize")
local inline = require("markview-smart-tables.inline")

------------------------------------------------------------------------------
--- Virtual line builders
------------------------------------------------------------------------------

--- Layout shared by the line builders. Each line is a `virt_lines` entry:
--- a list of `{ text, hl }` chunks.
---@class markview_smart_tables.layout
---
---@field indent string Leading spaces(the table's own indentation).
---@field ncols integer
---@field widths integer[] Fitted column widths.
---@field aligns string[] Per-column alignment(from the `:---:` markers).
---@field parts table markview's `markdown.tables.parts`(border glyphs).
---@field hls table markview's `markdown.tables.hl`(highlight groups).

local H = utils.set_hl

--- Resolves a chunk highlight(an `@`-group/markview-group string, a list of them
--- for combined styles, or nil) into the form a `virt_lines` chunk accepts.
---@param hl string|string[]|nil
---@return string|string[]|nil
local function apply_hl(hl)
  if type(hl) == "table" then
    local out = {}
    for _, g in ipairs(hl) do
      out[#out + 1] = H(g)
    end
    return out
  end
  return H(hl)
end

--- Horizontal rule: corner, fill, junction, …, corner. Draws the top/bottom
--- borders and the thin rule between data rows. {p}/{h} are a markview parts
--- entry and its highlights: `{ left, fill, right, junction }`.
---@param L markview_smart_tables.layout
---@param p? string[]
---@param h? string[]
---@return table[]
local function junction_line(L, p, h)
  p = p or {}
  h = h or {}

  --- Parts/highlights are positional: { left, fill, right, junction }.
  local left, fill, right, junc = p[1] or "", p[2] or "─", p[3] or "", p[4] or ""
  local left_hl, fill_hl, right_hl, junc_hl = h[1], h[2], h[3], h[4]

  local line = { { L.indent }, { left, H(left_hl) } }

  for i = 1, L.ncols do
    local last = i == L.ncols
    line[#line + 1] = { string.rep(fill, L.widths[i] + 2), H(fill_hl) }
    line[#line + 1] = { last and right or junc, H(last and right_hl or junc_hl) }
  end

  return line
end

--- The header/body separator row, with per-column alignment markers.
---@param L markview_smart_tables.layout
---@return table[]
local function separator_line(L)
  local p = L.parts.separator or {}
  local h = L.hls.separator or {}

  --- Parts/highlights are positional: { left, fill, right, junction }.
  local left, fill, right, junc = p[1] or "", p[2] or "─", p[3] or "", p[4] or ""
  local left_hl, fill_hl, right_hl, junc_hl = h[1], h[2], h[3], h[4]

  local line = { { L.indent }, { left, H(left_hl) } }

  for i = 1, L.ncols do
    local last = i == L.ncols
    local w = L.widths[i] + 2
    local mid

    if L.aligns[i] == "left" then
      mid = (L.parts.align_left or "") .. string.rep(fill, math.max(0, w - 1))
    elseif L.aligns[i] == "right" then
      mid = string.rep(fill, math.max(0, w - 1)) .. (L.parts.align_right or "")
    elseif L.aligns[i] == "center" then
      local ac = L.parts.align_center or { "", "" }
      mid = (ac[1] or "") .. string.rep(fill, math.max(0, w - 2)) .. (ac[2] or "")
    else
      mid = string.rep(fill, w)
    end

    line[#line + 1] = { mid, H(fill_hl) }
    line[#line + 1] = { last and right or junc, H(last and right_hl or junc_hl) }
  end

  return line
end

--- One screen line of a content row. {cells} holds the k-th wrapped line of
--- each column as a list of `{ text, hl }` chunks; {bars}/{bhl} are
--- `parts.header`/`parts.row` and their highlights `{ left, middle, right }`.
--- {center} centres each cell(header row); {default_hl} highlights cell text
--- that carries no inline highlight of its own(used to bold header text).
---@param L markview_smart_tables.layout
---@param cells table[][]
---@param bars? string[]
---@param bhl? string[]
---@param center? boolean
---@param default_hl? string
---@return table[]
local function content_line(L, cells, bars, bhl, center, default_hl)
  bars = bars or {}
  bhl = bhl or {}

  --- Parts/highlights are positional: { left, middle, right }.
  local left, middle, right = bars[1] or "│", bars[2] or "│", bars[3] or "│"
  local left_hl, middle_hl, right_hl = bhl[1], bhl[2], bhl[3]

  local line = { { L.indent }, { left, H(left_hl) } }

  for i = 1, L.ncols do
    local last = i == L.ncols
    local chunks = cells[i] or {}

    local seg_w = 0
    for _, c in ipairs(chunks) do
      seg_w = seg_w + vim.fn.strdisplaywidth(c.text)
    end

    local pad = math.max(0, L.widths[i] - seg_w)

    --- The header row is always centred; data rows follow the column's
    --- own alignment.
    local align = center and "center" or L.aligns[i]
    local lp, rp

    if align == "right" then
      lp, rp = pad, 0
    elseif align == "center" then
      lp = math.floor(pad / 2)
      rp = pad - lp
    else
      lp, rp = 0, pad
    end

    --- " " + left padding, then each cell chunk(inline highlight wins, else the
    --- row default), then right padding + " ".
    line[#line + 1] = { " " .. string.rep(" ", lp) }
    for _, c in ipairs(chunks) do
      line[#line + 1] = { c.text, apply_hl(c.hl or default_hl) }
    end
    line[#line + 1] = { string.rep(" ", rp) .. " " }
    line[#line + 1] = { last and right or middle, H(last and right_hl or middle_hl) }
  end

  return line
end

--- Appends the content lines for one logical row of tokenised {cells} to
--- {vlines}, style-wrapping each cell to its column width(tallest cell sets the
--- height).
---@param L markview_smart_tables.layout
---@param vlines table[]
---@param cells table[] List per column of `{ words, plain }`.
---@param bars? string[]
---@param bhl? string[]
---@param center? boolean
---@param default_hl? string
local function emit_row(L, vlines, cells, bars, bhl, center, default_hl)
  local wrapped, n = {}, 1

  for c = 1, L.ncols do
    wrapped[c] = wrap.style_wrap((cells[c] and cells[c].words) or {}, L.widths[c])
    n = math.max(n, #wrapped[c])
  end

  for k = 1, n do
    local row = {}
    for c = 1, L.ncols do
      row[c] = wrapped[c][k] or {}
    end
    vlines[#vlines + 1] = content_line(L, row, bars, bhl, center, default_hl)
  end
end

--- The whole virtual table: top border, centred header, separator, data rows
--- with a thin rule between them(separator glyphs in the border colour, so
--- wrapped multi-line rows stay readable), bottom border. Header cell text uses
--- markview's header highlight(`MarkviewTableHeader` -> `@markup.heading`, bold
--- in typical themes) so headers stand out.
---@param L markview_smart_tables.layout
---@param header table[]
---@param rows table[][]
---@return table[]
local function build_vlines(L, header, rows)
  local vlines = {}
  local header_hl = (L.hls.header or {})[1]

  vlines[#vlines + 1] = junction_line(L, L.parts.top, L.hls.top)
  emit_row(L, vlines, header, L.parts.header, L.hls.header, true, header_hl)
  vlines[#vlines + 1] = separator_line(L)

  for ri, r in ipairs(rows) do
    if ri > 1 then
      vlines[#vlines + 1] = junction_line(L, L.parts.separator, L.hls.bottom)
    end

    emit_row(L, vlines, r, L.parts.row, L.hls.row, false, nil)
  end

  vlines[#vlines + 1] = junction_line(L, L.parts.bottom, L.hls.bottom)
  return vlines
end

------------------------------------------------------------------------------
--- Cell extraction & placement
------------------------------------------------------------------------------

--- Tokenises one cell into `{ words, plain }`: {words} is a list of words(each a
--- list of `{ text, hl }` segments with no inter-word whitespace) for
--- `wrap.style_wrap`; {plain} is the cell's display string, for width measuring.
--- Inline styling(bold/italic/code/…) comes from `inline.segments`. Contiguous
--- non-space text keeps the same word even across a highlight change
--- (e.g. ``call(`x`)``), so inline markup inside a word stays attached.
---@param buffer integer
---@param raw string
---@return table
local function cell_tokens(buffer, raw)
  local segments = inline.segments(buffer, raw)

  local words, cur = {}, nil
  local plain = {}

  for _, seg in ipairs(segments) do
    plain[#plain + 1] = seg.text

    local t, pos = seg.text, 1

    while pos <= #t do
      local sp_s, sp_e = t:find("%s+", pos)

      if sp_s == pos then
        --- Whitespace boundary: finish the current word.
        if cur then
          words[#words + 1] = cur
          cur = nil
        end
        pos = sp_e + 1
      else
        local stop = (sp_s and sp_s - 1) or #t
        cur = cur or {}
        cur[#cur + 1] = { text = t:sub(pos, stop), hl = seg.hl }
        pos = stop + 1
      end
    end
  end

  if cur then
    words[#words + 1] = cur
  end

  return { words = words, plain = table.concat(plain) }
end

--- Tokenised(`cell_tokens`) `column` cells in {cells}.
---@param buffer integer
---@param cells table[]
---@return table[]
local function cell_cells(buffer, cells)
  local out = {}

  for _, col in ipairs(cells) do
    if col.class == "column" then
      out[#out + 1] = cell_tokens(buffer, col.text or "")
    end
  end

  return out
end

--- Hides the table's source lines(`conceal_lines` -> 0 screen height, immune
--- to soft-wrap) and attaches {vlines} to the nearest *visible* neighbour
--- (`virt_lines` on a concealed line are not drawn): the line above the table,
--- else the line after it.
---@param buffer integer
---@param ns integer
---@param range table
---@param nlines integer Number of source lines the table occupies.
---@param vlines table[]
---@return boolean placed `false` when there is no neighbour to anchor to(nothing is drawn).
local function place(buffer, ns, range, nlines, vlines)
  local anchor

  if range.row_start > 0 then
    anchor = { row = range.row_start - 1, above = false }
  elseif range.row_start + nlines <= vim.api.nvim_buf_line_count(buffer) - 1 then
    anchor = { row = range.row_start + nlines, above = true }
  else
    --- Table spans the whole buffer; concealing its lines would hide
    --- everything with no place left to draw the virtual copy.
    return false
  end

  for r = range.row_start, range.row_start + nlines - 1 do
    vim.api.nvim_buf_set_extmark(buffer, ns, r, 0, {
      undo_restore = false,
      invalidate = true,
      conceal_lines = "",
    })
  end

  vim.api.nvim_buf_set_extmark(buffer, ns, anchor.row, 0, {
    undo_restore = false,
    invalidate = true,
    virt_lines = vlines,
    virt_lines_above = anchor.above or nil,
  })

  return true
end

------------------------------------------------------------------------------
--- Renderer
------------------------------------------------------------------------------

--- Fully-virtual table renderer.
---
--- With `'wrap'` on this handles every table: soft-wrap computes break points
--- from raw buffer columns, which is fatal to the normal(inline `virt_text` +
--- `conceal`) rendering. With `'wrap'` off it only handles tables that
--- overflow the fit target(fitting tables return `false` -> stock renderer).
---
--- Editing is handled by markview's hybrid mode: when the cursor is on the
--- table the node is filtered out before rendering, so these decorations are
--- not drawn and the raw markdown shows through.
---@param buffer integer
---@param item table Parsed table(`markview.parsed.markdown.tables`).
---@param config table markview's `markdown.tables` config merged with this plugin's options.
---@param ns integer Markdown renderer namespace.
---@return boolean rendered `false` -> caller should fall back to the stock renderer.
M.render = function(buffer, item, config, ns)
  --- `conceal_lines`(used to hide the real rows) needs Neovim 0.11+. On
  --- older versions the extmark would error.
  if vim.fn.has("nvim-0.11") == 0 then
    return false
  end

  --- `linewise` hybrid mode clears decorations line-by-line around the
  --- cursor. That would strip some of this table's `conceal_lines` while the
  --- full virtual copy stays drawn — duplicating rows on screen. An
  --- all-or-nothing virtual table cannot honour per-line reveals.
  if
    spec.get({ "preview", "linewise_hybrid_mode" }, { fallback = false, ignore_enable = true })
      == true
    and #spec.get({ "preview", "hybrid_modes" }, { fallback = {}, ignore_enable = true }) > 0
  then
    return false
  end

  local range = item.range
  local win = utils.buf_getwin(buffer)
  local nlines = #(item.text or {})

  if type(win) ~= "number" or nlines == 0 then
    return false
  end

  --- Extract the rendered cell texts.
  ---
  --- A line the row-parser could not split into columns(e.g. mid-edit, text
  --- typed before the leading `|`) would be drawn as an *empty* row here —
  --- hiding real text, as every source line is concealed. The stock renderer
  --- keeps such lines visible, so let it handle the table instead.
  local header = cell_cells(buffer, item.header)

  if #header == 0 then
    return false
  end

  local rows = {}

  for _, r in ipairs(item.rows) do
    local cells = cell_cells(buffer, r)

    if #cells == 0 then
      return false
    end

    rows[#rows + 1] = cells
  end

  local ncols = #header

  for _, r in ipairs(rows) do
    ncols = math.max(ncols, #r)
  end

  --- Natural(unwrapped) column widths.
  local natural = {}
  for c = 1, ncols do
    natural[c] = 1
  end

  local function widen(cells)
    for c = 1, ncols do
      natural[c] = math.max(natural[c], vim.fn.strdisplaywidth((cells[c] and cells[c].plain) or ""))
    end
  end

  widen(header)
  for _, r in ipairs(rows) do
    widen(r)
  end

  --- Fit to `wrap_width`. Each column is drawn as `" " .. cell .. " "`
  --- (width + 2) with `ncols + 1` vertical borders.
  local min_col = type(config.wrap_minwidth) == "number" and config.wrap_minwidth or 5
  local budget = wrap.fit_target(win, config) - range.col_start - ((ncols + 1) + (2 * ncols))
  local widths, shrunk = wrap.fit_columns(natural, budget, min_col)

  --- With `'wrap'` off the stock in-buffer rendering works fine(real text,
  --- visible cursor) — only take over tables that actually overflow. With
  --- `'wrap'` on every table is virtualised, as soft-wrap breaks the
  --- in-buffer rendering.
  if vim.wo[win].wrap ~= true and shrunk ~= true then
    return false
  end

  --- Smart tables are sized to the window, so resizes must re-render.
  --- Registered here — not at module load, and only past every decline check
  --- — so the autocmd exists only once a smart table is actually rendered.
  resize.register()

  ---@type markview_smart_tables.layout
  local L = {
    indent = string.rep(" ", range.col_start),
    ncols = ncols,
    widths = widths,
    aligns = item.alignments or {},
    parts = config.parts or {},
    hls = config.hl or {},
  }

  return place(buffer, ns, range, nlines, build_vlines(L, header, rows))
end

return M
