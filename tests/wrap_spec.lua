--[[
Tests for the pure fit/word-wrap maths in `markview-smart-tables.wrap`.

No editor state is needed beyond `vim.fn` (display-width helpers), so these run
under `nvim -l tests/run.lua`. See `tests/run.lua` for the tiny harness.
]]
return function(t)
  local wrap = require("markview-smart-tables.wrap")

  ------------------------------------------------------------------------
  --- word_wrap
  ------------------------------------------------------------------------

  t.it("word_wrap: short text stays on one line", function()
    t.same({ "hello" }, wrap.word_wrap("hello", 10))
  end)

  t.it("word_wrap: breaks on whitespace at the width boundary", function()
    t.same({ "one two", "three" }, wrap.word_wrap("one two three", 7))
  end)

  t.it("word_wrap: collapses runs of whitespace to a single space", function()
    t.same({ "a b c" }, wrap.word_wrap("a   b\t c", 10))
  end)

  t.it("word_wrap: hard-breaks a word wider than the column", function()
    t.same({ "abcde", "fghij", "k" }, wrap.word_wrap("abcdefghijk", 5))
  end)

  t.it("word_wrap: flushes the current line before hard-breaking", function()
    --- "hi" fills nothing wide, then the long word breaks on its own lines.
    t.same({ "hi", "aaaaa", "aa" }, wrap.word_wrap("hi aaaaaaa", 5))
  end)

  t.it("word_wrap: empty text yields a single empty line", function()
    t.same({ "" }, wrap.word_wrap("", 5))
  end)

  t.it("word_wrap: whitespace-only text yields a single empty line", function()
    t.same({ "" }, wrap.word_wrap("    ", 5))
  end)

  t.it("word_wrap: width is floored at 1 even when asked for 0", function()
    t.same({ "a", "b" }, wrap.word_wrap("ab", 0))
  end)

  t.it("word_wrap: double-width glyphs respect display width, not byte/char count", function()
    --- Each CJK glyph is 2 cells wide, so only one fits in a width-3 column.
    t.same({ "你", "好" }, wrap.word_wrap("你好", 3))
  end)

  ------------------------------------------------------------------------
  --- style_wrap (highlight-aware word wrap)
  ------------------------------------------------------------------------

  --- Flattens a wrapped line(list of `{ text, hl }` chunks) to its text.
  local function line_text(line)
    local parts = {}
    for _, c in ipairs(line) do
      parts[#parts + 1] = c.text
    end
    return table.concat(parts)
  end

  t.it("style_wrap: joins words with a space and keeps them on one line", function()
    local lines = wrap.style_wrap({ { { text = "one" } }, { { text = "two" } } }, 10)
    t.eq(1, #lines)
    t.eq("one two", line_text(lines[1]))
  end)

  t.it("style_wrap: breaks on the width boundary like word_wrap", function()
    local lines =
      wrap.style_wrap({ { { text = "one" } }, { { text = "two" } }, { { text = "three" } } }, 7)
    t.eq(2, #lines)
    t.eq("one two", line_text(lines[1]))
    t.eq("three", line_text(lines[2]))
  end)

  t.it("style_wrap: preserves a code span's highlight as its own chunk", function()
    local lines = wrap.style_wrap({ { { text = "x", hl = "Code" } } }, 10)
    t.eq(1, #lines)
    t.eq("x", lines[1][1].text)
    t.eq("Code", lines[1][1].hl)
  end)

  t.it("style_wrap: keeps a mixed-highlight word (e.g. call(`x`)) as one word", function()
    --- call( + x[Code] + ) with no spaces stays a single word -> 3 chunks.
    local word = { { text = "call(" }, { text = "x", hl = "Code" }, { text = ")" } }
    local lines = wrap.style_wrap({ word }, 20)
    t.eq(1, #lines)
    t.eq("call(x)", line_text(lines[1]))
    t.eq("Code", lines[1][2].hl)
  end)

  t.it("style_wrap: hard-breaks a word wider than the column, keeping highlight", function()
    local lines = wrap.style_wrap({ { { text = "abcdefghij", hl = "Code" } } }, 4)
    t.eq(3, #lines)
    t.eq("abcd", line_text(lines[1]))
    t.eq("ij", line_text(lines[3]))
    t.eq("Code", lines[1][1].hl)
  end)

  t.it("style_wrap: empty input yields a single empty line", function()
    local lines = wrap.style_wrap({}, 5)
    t.eq(1, #lines)
    t.eq("", line_text(lines[1]))
  end)

  ------------------------------------------------------------------------
  --- fit_columns
  ------------------------------------------------------------------------

  t.it("fit_columns: returns natural widths unchanged when they fit", function()
    local fitted, shrunk = wrap.fit_columns({ 3, 4, 5 }, 100, 2)
    t.same({ 3, 4, 5 }, fitted)
    t.eq(false, shrunk)
  end)

  t.it("fit_columns: shrinks the widest column first", function()
    --- total 18, budget 15 → shave 3 off the widest (10 → 7).
    local fitted, shrunk = wrap.fit_columns({ 3, 5, 10 }, 15, 2)
    t.same({ 3, 5, 7 }, fitted)
    t.eq(true, shrunk)
    t.eq(15, fitted[1] + fitted[2] + fitted[3])
  end)

  t.it("fit_columns: never shrinks below min_col while the budget allows", function()
    local fitted = wrap.fit_columns({ 8, 8 }, 10, 5)
    --- 5 + 5 = 10 fits the budget; neither drops below the floor.
    t.same({ 5, 5 }, fitted)
  end)

  t.it("fit_columns: forces columns below min_col when even the floor overflows", function()
    --- 3 columns, floor 5 ⇒ 15 minimum > budget 6, so columns go below 5.
    local fitted = wrap.fit_columns({ 9, 9, 9 }, 6, 5)
    local total = fitted[1] + fitted[2] + fitted[3]
    t.eq(true, total <= 6)
    t.eq(true, fitted[1] >= 1 and fitted[2] >= 1 and fitted[3] >= 1)
  end)

  t.it("fit_columns: empty input is a no-op", function()
    local fitted, shrunk = wrap.fit_columns({}, 10, 2)
    t.same({}, fitted)
    t.eq(false, shrunk)
  end)

  ------------------------------------------------------------------------
  --- fit_target (needs a window; uses the current one)
  ------------------------------------------------------------------------

  t.it("fit_target: a fraction yields that share of the window width", function()
    local win = vim.api.nvim_get_current_win()
    local info = vim.fn.getwininfo(win)[1]
    local usable = vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
    t.eq(math.floor(usable * 0.5), wrap.fit_target(win, { wrap_width = 0.5 }))
  end)

  t.it("fit_target: an absolute count is clamped to the window width", function()
    local win = vim.api.nvim_get_current_win()
    local info = vim.fn.getwininfo(win)[1]
    local usable = vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
    t.eq(math.min(usable, 10), wrap.fit_target(win, { wrap_width = 10 }))
  end)

  t.it("fit_target: an invalid value defaults to 90% of the window", function()
    local win = vim.api.nvim_get_current_win()
    local info = vim.fn.getwininfo(win)[1]
    local usable = vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
    t.eq(math.floor(usable * 0.9), wrap.fit_target(win, { wrap_width = "nonsense" }))
  end)
end
