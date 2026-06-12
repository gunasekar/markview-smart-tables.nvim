--[[
Tests for the treesitter-driven inline tokeniser, `markview-smart-tables.inline`.

These exercise the parts that depend only on the bundled `markdown_inline`
treesitter parser (styling, concealment, code chip, link label/URL handling).
markview-specific touches — entity/emoji/escape replacement and per-site link
icons — need markview at runtime and so are covered by render checks, not here;
without markview those paths degrade gracefully (the requires are guarded).
]]
return function(t)
  local inline = require("markview-smart-tables.inline")

  --- Concatenated display text of a cell's segments(NBSP padding -> space).
  local function text(raw)
    local parts = {}
    for _, s in ipairs(inline.segments(0, raw)) do
      parts[#parts + 1] = s.text
    end
    return (table.concat(parts):gsub("\194\160", " "))
  end

  --- Collapsed display text, so code/icon padding does not affect comparisons.
  local function squished(raw)
    return (text(raw):gsub("%s+", " "))
  end

  --- Whether any segment carries the highlight {want}(string or in a list).
  local function has_hl(raw, want)
    for _, s in ipairs(inline.segments(0, raw)) do
      if s.hl == want then
        return true
      end
      if type(s.hl) == "table" then
        for _, g in ipairs(s.hl) do
          if g == want then
            return true
          end
        end
      end
    end
    return false
  end

  t.it("plain text is one unstyled run", function()
    local segs = inline.segments(0, "hello world")
    t.eq(1, #segs)
    t.eq("hello world", segs[1].text)
    t.eq(nil, segs[1].hl)
  end)

  t.it("bold: delimiters concealed, text kept, @markup.strong applied", function()
    t.eq("a bold b", squished("a **bold** b"))
    t.eq(true, has_hl("a **bold** b", "@markup.strong"))
  end)

  t.it("italic: @markup.italic, asterisks gone", function()
    t.eq("a x b", squished("a *x* b"))
    t.eq(true, has_hl("a *x* b", "@markup.italic"))
  end)

  t.it("strikethrough: @markup.strikethrough, tildes gone", function()
    t.eq("a gone b", squished("a ~~gone~~ b"))
    t.eq(true, has_hl("a ~~gone~~ b", "@markup.strikethrough"))
  end)

  t.it("bold-italic carries both highlights", function()
    t.eq(true, has_hl("***x***", "@markup.strong"))
    t.eq(true, has_hl("***x***", "@markup.italic"))
  end)

  t.it("inline code: code highlight, backticks gone, text kept", function()
    t.eq(true, has_hl("run `x` now", "MarkviewInlineCode"))
    t.eq(true, squished("run `x` now"):find("x") ~= nil)
    t.eq(nil, text("run `x` now"):find("`"))
  end)

  t.it("link: label shown, URL concealed", function()
    local out = squished("see [label](https://example.com/page)")
    t.eq(true, out:find("label") ~= nil)
    t.eq(nil, out:find("example"))
    t.eq(nil, out:find("https"))
  end)

  t.it("two links in one cell: both labels shown, both URLs hidden", function()
    local out = squished("[alpha](https://a.test) and [beta](https://b.test)")
    t.eq(true, out:find("alpha") ~= nil)
    t.eq(true, out:find("beta") ~= nil)
    t.eq(nil, out:find("a%.test"))
    t.eq(nil, out:find("b%.test"))
  end)

  t.it("reference-style link does not error and keeps its label", function()
    local out = squished("see [label][ref] here")
    t.eq(true, out:find("label") ~= nil)
  end)

  t.it("empty and whitespace-only cells yield no segments", function()
    t.same({}, inline.segments(0, ""))
    t.same({}, inline.segments(0, "   "))
  end)

  t.it("mixed styling preserves order and text", function()
    t.eq("an important note", squished("an **important** note"))
  end)
end
