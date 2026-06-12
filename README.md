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
- **Editing** — a fitted table is drawn over its hidden source lines. Enter
  insert mode (or use markview's hybrid mode, `preview.hybrid_modes`) to reveal
  and edit the raw markdown.
- **Inline styling** — bold, italic, strikethrough, inline code, and links
  inside cells are preserved through the word-wrap. Styling is read from
  treesitter (the same captures markview uses); code spans and links additionally
  reuse markview's own config (code padding/highlight, and the link icon +
  highlight resolved through markview's matcher — a github URL gets its github
  glyph). Text markview substitutes — entities (`&amp;` → `&`), emoji shortcodes,
  escapes (`\|` → `|`) — is applied too (via markview's `tostring`), so fitted
  cells match markview's stock tables.
- **Window resizes** (splits, sidebars, terminal) re-fit tables automatically.
- Tables mid-edit (e.g. a row missing its leading `|`), tables markview can't
  place virtually, and Neovim < 0.11 all fall back to stock rendering — the
  plugin never hides content it can't redraw.

The table borders, separators, and highlights reuse your markview
`markdown.tables` `parts`/`hl` configuration, so fitted tables match your theme.

## Options

| Option          | Default | Description                                                              |
|-----------------|---------|--------------------------------------------------------------------------|
| `enable`        | `true`  | Render smart tables (`false` = stock markview rendering only)            |
| `wrap_width`    | `0.9`   | Max table width — window fraction (`0<n<=1`) or absolute columns (`n>1`) |
| `wrap_minwidth` | `5`     | Smallest column width before long words are hard-broken                  |

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
