--[[
Inline-markup styling for table cells, via treesitter.

A fitted table is drawn as virtual lines, so the inline styling markview/
treesitter apply to in-buffer cell text(bold, italic, code, strikethrough,
links, …) is lost and must be reproduced. Rather than hand-roll a parser per
construct, `segments` parses the cell text as a standalone `markdown_inline`
string and replays treesitter's own highlight captures: each capture paints its
range with `@<capture>`, and `@conceal` ranges(the `**`, `` ` ``, `~~`, …
delimiters) are dropped — matching what treesitter shows in-buffer.

Two constructs are styled to match markview's stock tables rather than bare
treesitter: code spans use markview's `inline_codes` highlight + space padding
(treesitter's `@markup.raw` is foreground-only, with no padding), and links use
markview's `hyperlinks` icon + highlight (resolved via markview's own
`utils.match`, so a github URL gets its github glyph). Everything else uses its
treesitter group. When treesitter is unavailable the caller's `tostring`
fallback is used(plain, concealed text).
]]
local M = {}

--- A string config value, or {default}.
local function str(v, default)
  return (type(v) == "string" and v) or default
end

--- Replaces ASCII spaces with U+00A0 so markview's code padding / link icons
--- stay attached to their chip through the cell's word-wrap(which splits on
--- ASCII whitespace).
local function nbsp(s)
  return (s:gsub(" ", "\194\160"))
end

--- markview's inline-code styling: highlight + the space padding it draws each
--- side of a code span. Treesitter's own `@markup.raw` is foreground-only and
--- has no padding, so code is rendered with markview's group(default
--- `MarkviewInlineCode`, which carries the background) and padding instead, to
--- match markview's stock tables.
---@return string hl, string pad_left, string pad_right
local function inline_code_style()
  local ok, spec = pcall(require, "markview.spec")
  local cfg = (
    ok
    and spec.get
    and spec.get({ "markdown_inline", "inline_codes" }, { fallback = nil })
  ) or {}
  return str(cfg.hl, "MarkviewInlineCode"), str(cfg.padding_left, " "), str(cfg.padding_right, " ")
end

--- markview's hyperlink prefix(`corner_left`+`padding_left`+`icon`) and highlight
--- for {url}. Resolved through markview's own `utils.match`(priority/longest
--- pattern, merged with the `default` entry) so links match markview's stock
--- links exactly — e.g. a github glyph for github.com URLs.
---@param url string
---@return string prefix, string hl
local function link_style(url)
  local ok_u, utils = pcall(require, "markview.utils")
  local ok_s, spec = pcall(require, "markview.spec")
  local cfg = ok_s
    and spec.get
    and spec.get({ "markdown_inline", "hyperlinks" }, { fallback = nil })

  if not (ok_u and type(utils.match) == "function" and type(cfg) == "table") then
    return "", "MarkviewHyperlink"
  end

  local conf = utils.match(cfg, url, {}) or {}
  local prefix = str(conf.corner_left, "") .. str(conf.padding_left, "") .. str(conf.icon, "")
  return nbsp(prefix), str(conf.hl, "MarkviewHyperlink")
end

--- Captures that carry no visible highlight of their own.
local function ignored(name)
  return name == "conceal"
    or name == "nospell"
    or name == "spell"
    or name == "none"
    or name:sub(1, 1) == "_"
end

--- Byte length of the UTF-8 character starting at byte {i} of {s}.
local function char_len(s, i)
  local b = s:byte(i)
  if not b or b < 0x80 then
    return 1
  elseif b < 0xE0 then
    return 2
  elseif b < 0xF0 then
    return 3
  else
    return 4
  end
end

--- Content-keyed memo(cell text -> segments), bounded by `MEMO_MAX` and cleared
--- wholesale on overflow. Segments depend on the cell string and markview's
--- (global) config, so caching by text is safe and cheap on re-render/resize.
local memo, memo_n = {}, 0
local MEMO_MAX = 2048

--- Builds `{ text, hl }` display segments from {raw}'s `markdown_inline` tree, or
--- returns nil when treesitter is unavailable(parser/query missing). {buffer} is
--- used for markview's `tostring`(text replacements).
---@param buffer integer
---@param raw string
---@return table[]|nil
local function build(buffer, raw)
  local ok, parser = pcall(vim.treesitter.get_string_parser, raw, "markdown_inline")
  local query = ok and vim.treesitter.query.get("markdown_inline", "highlights") or nil

  if not ok or not query then
    return nil
  end

  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return nil
  end

  --- Collect captures, then apply widest-first so narrower(more specific)
  --- captures are layered on top(e.g. a link label over the whole link). A
  --- range is hidden when captured as `@conceal` or when its match sets an empty
  --- `conceal` metadata(e.g. a link's `[]()` and URL). A non-empty conceal is a
  --- replacement(e.g. an entity `&amp;` -> `&`); those stay visible and are
  --- resolved by `tostring` below, like markview does.
  local caps = {}
  for id, node, meta in query:iter_captures(tree:root(), raw, 0, -1) do
    local _, sc, _, ec = node:range()
    local name = query.captures[id]
    caps[#caps + 1] = {
      name = name,
      sc = sc,
      ec = ec,
      conceal = name == "conceal" or meta.conceal == "",
    }
  end
  table.sort(caps, function(a, b)
    return (a.ec - a.sc) > (b.ec - b.sc)
  end)

  local hide = {} ---@type table<integer, boolean>     byte(1-based) -> concealed
  local groups = {} ---@type table<integer, string[]>  byte(1-based) -> hl groups
  local prefix = {} ---@type table<integer, table>     byte -> { text, hl } drawn before it
  local code, code_pl, code_pr = inline_code_style()

  for _, c in ipairs(caps) do
    if c.conceal then
      for b = c.sc + 1, c.ec do
        hide[b] = true
      end
    elseif not ignored(c.name) and not c.name:match("^markup%.link") then
      --- Links are styled separately(icon + markview's hyperlink group) below;
      --- their `[]()`/URL are already concealed. Code uses markview's group, not
      --- the foreground-only treesitter `@markup.raw`.
      local group = c.name:match("^markup%.raw") and code or ("@" .. c.name)
      for b = c.sc + 1, c.ec do
        local list = groups[b]
        if not list then
          list = {}
          groups[b] = list
        end
        if list[#list] ~= group then
          list[#list + 1] = group
        end
      end
    end
  end

  --- Link pass: pair each label with the following URL(document order), resolve
  --- markview's icon + highlight from the URL, repaint the label, and queue the
  --- icon to be drawn just before it.
  local labels, urls = {}, {}
  for _, c in ipairs(caps) do
    if c.name == "markup.link.label" then
      labels[#labels + 1] = c
    elseif c.name == "markup.link.url" then
      urls[#urls + 1] = c
    end
  end
  table.sort(labels, function(a, b)
    return a.sc < b.sc
  end)
  table.sort(urls, function(a, b)
    return a.sc < b.sc
  end)
  local ui = 1
  for _, label in ipairs(labels) do
    --- The label's URL is the next one starting at/after its closing bracket;
    --- reference-style links(no inline URL) fall through to the default style.
    while urls[ui] and urls[ui].sc < label.ec do
      ui = ui + 1
    end

    local url_text = ""
    if urls[ui] and urls[ui].sc >= label.ec then
      url_text = raw:sub(urls[ui].sc + 1, urls[ui].ec)
      ui = ui + 1
    end

    local icon, hl = link_style(url_text)
    for b = label.sc + 1, label.ec do
      groups[b] = { hl }
    end
    if icon ~= "" then
      prefix[label.sc + 1] = { text = icon, hl = hl }
    end
  end

  --- Realises a run's raw text the way markview would: code is verbatim; other
  --- text goes through markview's `tostring`, which applies the replacements
  --- treesitter does not(entities `&amp;` -> `&`, emoji `:x:` -> glyph, escapes
  --- `\|` -> `|`). Surrounding whitespace is preserved(it separates words for the
  --- wrap), `tostring` is skipped when there is nothing to replace, and the text
  --- is returned unchanged if markview's `tostring` is unavailable.
  local function realise(text, hl)
    if hl == code or not text:find("[&:\\]") then
      return text
    end
    local got, md_tostring = pcall(require, "markview.renderers.markdown.tostring")
    if not got then
      return text
    end
    local lead, core, trail = text:match("^(%s*)(.-)(%s*)$")
    local realised, disp = pcall(md_tostring.tostring, buffer, core)
    return lead .. ((realised and disp) or core) .. trail
  end

  --- Collect runs of contiguous visible bytes sharing one highlight, realising
  --- each into a `{ text, hl }` chunk. Link icons(`prefix`) are emitted verbatim.
  local segs = {}
  local cur, cur_key

  local function push(text, hl)
    if text == "" then
      return
    end
    local key = (type(hl) == "table" and table.concat(hl, "|")) or hl or ""
    if cur and cur_key == key then
      cur.text = cur.text .. text
    else
      cur = { text = text, hl = hl }
      cur_key = key
      segs[#segs + 1] = cur
    end
  end

  local run_s, run_hl, run_key
  local function flush(run_e)
    if run_s then
      push(realise(raw:sub(run_s, run_e), run_hl), run_hl)
      run_s = nil
    end
  end

  local i, n = 1, #raw
  local last_vis = 0

  while i <= n do
    local clen = char_len(raw, i)

    if hide[i] then
      flush(last_vis)
    else
      local pre = prefix[i]
      if pre then
        flush(last_vis)
        push(pre.text, pre.hl)
      end

      local list = groups[i]
      local hl
      if list and #list > 0 then
        hl = #list == 1 and list[1] or list
      end
      local key = (type(hl) == "table" and table.concat(hl, "|")) or hl or ""

      if not (run_s and run_key == key) then
        flush(last_vis)
        run_s, run_hl, run_key = i, hl, key
      end
      last_vis = i + clen - 1
    end

    i = i + clen
  end
  flush(last_vis)

  --- Pad code chips like markview, keeping the chip atomic(NBSP) so it survives
  --- the cell's word-wrap.
  for _, s in ipairs(segs) do
    if s.hl == code then
      s.text = nbsp(code_pl .. s.text .. code_pr)
    end
  end

  return segs
end

--- Styled `{ text, hl }` segments for a cell. {hl} is an `@`-group string,
--- `MarkviewInlineCode` for code, a list for combined styles(bold-italic), or
--- nil for plain text. Falls back to markview's `tostring`(plain, concealed)
--- when treesitter cannot parse the cell.
---@param buffer integer
---@param raw string
---@return table[]
function M.segments(buffer, raw)
  raw = vim.trim(raw or "")
  if raw == "" then
    return {}
  end
  if memo[raw] then
    return memo[raw]
  end

  local segs = build(buffer, raw)

  if not segs then
    --- No treesitter: fall back to markview's concealed plain text(guarded, so a
    --- `tostring` error never escapes into the render loop).
    local ok, disp = pcall(function()
      return require("markview.renderers.markdown.tostring").tostring(buffer, raw)
    end)
    segs = (ok and type(disp) == "string" and disp ~= "") and { { text = disp } } or {}
  end

  if memo_n >= MEMO_MAX then
    memo, memo_n = {}, 0
  end
  memo[raw] = segs
  memo_n = memo_n + 1
  return segs
end

return M
