# markview-smart-tables.nvim

Auto-fit and word-wrap wide markdown tables in [markview.nvim](https://github.com/OXY2DEV/markview.nvim).

Markview renders tables beautifully — until one is wider than your window. With
`'wrap'` on, wide tables fall back to a degraded rendering; with `'wrap'` off
they run past the right edge. This plugin fits oversized tables to the window:
columns shrink (widest first), overflowing cells word-wrap across lines, and a
thin rule separates data rows so multi-line rows stay readable.

It plugs into markview's [custom renderer](https://github.com/OXY2DEV/markview.nvim)
mechanism — no fork, no patches. Tables that don't need fitting keep markview's
stock rendering.

**Stock markview** — a wide table soft-wraps into a broken layout:

<p align="center">
  <img src="assets/default.png" width="760"
       alt="A wide markdown table rendered by stock markview: borders break apart and cells run past the window edge as the lines soft-wrap.">
</p>

**With markview-smart-tables** — the same table is auto-fit and word-wrapped, with inline styling (bold, italic, code, links) preserved:

<p align="center">
  <img src="assets/smart.png" width="760"
       alt="The same table rendered by markview-smart-tables: columns shrunk to fit the window, cells word-wrapped onto multiple lines, borders intact, and inline bold/italic/code/link styling kept.">
</p>

## Requirements

- Neovim **0.11+** (`conceal_lines`); older versions transparently fall back to
  stock markview rendering
- [markview.nvim](https://github.com/OXY2DEV/markview.nvim)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "gunasekar/markview-smart-tables.nvim",
  dependencies = { "OXY2DEV/markview.nvim" },
  opts = {
    wrap_width = 0.9,    -- max table width: fraction of the window (0<n<=1)
                         -- or absolute column count (n>1)
    wrap_minwidth = 5,   -- smallest a column may shrink to before long
                         -- words are hard-broken
    per_line = false,    -- true = draw each source row on its own line, so the
                         -- cursor stays visible inside a fitted table
  },
},
```

Then wire it into markview's table rendering — this step is **required**; the
`opts` above do nothing on their own:

```lua
require("markview").setup({
  renderers = {
    markdown_table = function (buffer, item)
      require("markview-smart-tables").render(buffer, item)
    end,
  },
});
```

Run `:checkhealth markview-smart-tables` to verify the Neovim version, that
markview is installed, and that the renderer hook is wired up.

## How it behaves

- **`'wrap'` on** — every table is drawn fitted to the window (soft-wrap breaks
  markview's normal in-buffer table rendering, so the fitted form replaces the
  degraded fallback you'd otherwise get).
- **`'wrap'` off** — only tables that overflow the window are fitted; fitting
  tables keep markview's stock in-buffer rendering (real text, visible cursor).
- **Navigating** — by default the source lines are concealed to zero screen
  height, which leaves no row for the cursor to sit on: it is invisible while on
  a fitted table, in any mode. `per_line = true` gives each source row its own
  screen line back, so the cursor stays visible and `j`/`k` step one table row at
  a time.
- **Editing** — a fitted table never shows the raw `| a | b |` text, with or
  without `per_line`. markview's hybrid mode (`preview.hybrid_modes`) reveals it
  under the cursor. Both topics are covered in [Editing and navigating fitted
  tables](#editing-and-navigating-fitted-tables).
- **Inline styling** — bold, italic, strikethrough, inline code, and links
  inside cells are preserved through the word-wrap. Styling is read from
  treesitter (the same captures markview uses); code spans and links additionally
  reuse markview's own config (code padding/highlight, and the link icon +
  highlight resolved through markview's matcher — a github URL gets its github
  glyph). Text markview substitutes — entities (`&amp;` → `&`), emoji shortcodes,
  escapes (`\|` → `|`) — is applied too (via markview's `tostring`), so fitted
  cells match markview's stock tables.
- **Window resizes** (splits, sidebars, terminal) re-fit tables automatically,
  and so do the options that change the usable width — `'wrap'`, `'number'`,
  `'signcolumn'` and the rest of the gutter and soft-wrap options.
- Tables mid-edit (e.g. a row missing its leading `|`), tables markview can't
  place virtually, and Neovim < 0.11 all fall back to stock rendering — the
  plugin never hides content it can't redraw.

The table borders, separators, and highlights reuse your markview
`markdown.tables` `parts`/`hl` configuration, so fitted tables match your theme.

## Editing and navigating fitted tables

By default a fitted table is drawn as virtual text over its source lines, which
are concealed to **zero screen height** (`conceal_lines`) — that is what lets
cells wrap onto multiple lines. This has a trade-off: the cursor lives in that
hidden text, and a zero-height line has no screen row to draw a cursor on, so
**while the cursor is on a fitted table it is invisible**. A motion like `j`
walks through the rows, but the cursor appears pinned to the table's top line
until it leaves — in *any* mode, not just when editing.

### `per_line` — keep the cursor visible

Set `per_line = true` to draw each source row on its **own** line instead. The
render is identical; the difference is that every table row keeps its screen
height, so the cursor is visible and moves one table row per `j`/`k`:

```lua
require("markview-smart-tables").setup({ per_line = true })
```

Its caveats:

- **The row is tracked, not the cell.** The row's raw markdown is concealed in
  place, so all of its buffer columns on a given screen line collapse to that
  line's left edge. The cursor steps down through a row's screen lines as you
  move past each soft-wrap boundary, but it never points at the cell you are on.
  `cursorline` likewise highlights one screen line, not the whole row.
- **Not under an irregular soft-wrap.** Under `'wrap'`, a row's rendered lines
  are painted onto the screen rows its raw text occupies, which assumes lines
  break every window-width cells. `'linebreak'`, `'breakindent'` and
  `'showbreak'` move those break points, so tables fall back to the default
  placement in a window using any of them.

### Editing

To edit a table you still want the raw markdown back. Reveal it with markview's
**hybrid mode** by listing the modes you navigate/edit in under
`preview.hybrid_modes`. It is **empty by default**, so nothing reveals until you
set it:

```lua
require("markview").setup({
  preview = {
    -- Reveal the node under the cursor in these modes. Modes: "n" normal,
    -- "v"/"V" charwise/linewise visual, "i" insert.
    hybrid_modes = { "n", "v", "V", "i" },
  },
})
```

Now moving the cursor onto a table reveals its raw `| a | b |` rows (visible,
navigable, editable) and moving off re-fits it. The trade-off is that a wide
table shows raw (unfitted) *while the cursor is on it* — drop modes from the
list to limit when that happens (e.g. `{ "i" }` reveals only while editing).

## How it compares to stock markview rendering

Both produce the same box-drawing table on screen and share the same theme
configuration. They differ in *how* that table is drawn, which leads to
different trade-offs.

**Rendering model.** Stock markview decorates the buffer in place: the real
markdown line stays in the buffer and extmarks are layered on top — the `|`
characters are concealed and replaced with inline virtual border glyphs, cells
are padded with virtual spaces, and the outer borders are drawn as virtual
text/lines. The cell text on screen is the buffer's own text. Smart tables
instead hides the source lines (`conceal_lines`, zero screen height) and emits
the entire table — borders, headers, and every cell, including wrapped lines —
as virtual lines. The cell text on screen is a re-tokenized copy painted over
the concealed source. Under `per_line = true` the same rendered table is split
across the source rows instead of one block: each row's raw text is concealed in
place and its rendered lines painted over the screen rows that raw text
occupies, with borders and any surplus attached to that row as virtual lines.
The source rows keep their screen height, which is what makes the cursor
visible.

**Why the difference exists.** Inline virtual text is positioned by buffer
column, and Neovim computes soft-wrap break points from raw buffer columns
before virtual text is applied. So when a table line is wider than the window
and `'wrap'` is on, the in-place decorations break apart at the wrap point;
markview detects this and returns early, leaving the raw wrapped markdown. A
virtual-line block is not soft-wrapped mid-glyph and the concealed source has
zero height, so cell text can be laid out across multiple lines. Moving a cell's
text onto a second line is only possible in the virtual-line model, because the
in-place model has no second buffer line to place it on.

**Relation to a from-scratch CLI renderer.** Smart tables follows the pipeline a
standalone terminal table tool uses — tokenize cells, measure columns, fit to a
width budget, word-wrap, emit complete lines — and composes an independent
display list rather than annotating existing text. Stock markview's model is
editor-coupled: it relies on buffer-anchored conceal and inline virtual text to
augment text that remains in the buffer, which keeps that text real (the cursor
lands on it, edits apply directly) without composing a separate grid.

**Resource usage.** The in-place model emits a small, fixed number of extmarks
per line and reflows with the buffer. The virtual model does more per fitted
table: it runs a `markdown_inline` treesitter parse per cell to recover inline
styling, performs the fit/word-wrap computation, and emits a virtual line per
output line; because the layout is sized to the window, it also installs a
debounced resize autocmd (lazily, only once a fitted table is actually drawn).
Smart tables declines back to stock rendering when fitting isn't needed (table
already fits with `'wrap'` off, Neovim < 0.11, mid-edit rows, `linewise_hybrid_mode`,
no anchor line), so the extra cost applies only to tables it fits. `per_line`
trades the single virtual-line block for a handful of extmarks per source row,
and drops markview's own inline decorations on those rows (the fitted copy
renders that styling itself).

## Options

| Option          | Default | Description                                                              |
|-----------------|---------|--------------------------------------------------------------------------|
| `enable`        | `true`  | Render smart tables (`false` = stock markview rendering only)            |
| `wrap_width`    | `0.9`   | Max table width — window fraction (`0<n<=1`) or absolute columns (`n>1`) |
| `wrap_minwidth` | `5`     | Smallest column width before long words are hard-broken                  |
| `per_line`      | `false` | Draw each source row on its own line so the cursor stays visible         |

## Known limitations

- Inline cell styling needs treesitter (the `markdown_inline` parser, which
  markview requires anyway). Without it, cells fall back to markview's `tostring`
  — correct text, no per-span highlights.
- This plugin reaches into a few markview internals (see
  [ARCHITECTURE.md](ARCHITECTURE.md#markview-surface)); a major
  markview refactor may require a plugin update.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the rendering works
internally.

## Development

```sh
make lint     # luacheck + stylua --check (see .luacheckrc, stylua.toml)
make format   # apply stylua formatting in place
make test     # fit/word-wrap + inline-styling tests, via `nvim -l tests/run.lua`
make docs     # regenerate doc/tags from the vimdoc
```

CI runs lint/format checks and `test` (Neovim stable + nightly) on every push
and PR.
