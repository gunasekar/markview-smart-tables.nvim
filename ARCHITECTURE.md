# Architecture

How markview-smart-tables works internally. For installation and usage, see the
[README](README.md).

## Entry point: markview's custom renderer hook

markview dispatches each parsed node to a renderer, checking the user-supplied
`renderers` config first (`:h markview.nvim-renderers`):

```lua
if custom[item.class] then
    custom[item.class](buffer, item)        -- us, for `markdown_table`
else
    markdown[item.class](buffer, item)      -- markview's stock renderer
end
```

`init.lua` registers as `renderers.markdown_table`. On every table render it
decides between two paths:

```
markview parse ──► renderers.markdown_table = M.render(buffer, item)
                        │
                        ├── smart path applies ──► table.lua M.render()
                        │                          (fitted, fully virtual)
                        └── declined ────────────► markview's stock
                                                   markdown.table()
```

One module per concern:

| Module       | Concern                                                       |
|--------------|---------------------------------------------------------------|
| `init.lua`   | setup + the markview hook (path decision above)               |
| `wrap.lua`   | pure fit/word-wrap maths (`fit_columns`, `word_wrap`, `style_wrap`) |
| `inline.lua` | per-cell inline styling from treesitter (`{ text, hl }` segments) |
| `table.lua`  | virtual line builders, cell extraction, placement, render     |
| `resize.lua` | re-render affected buffers on window resize                   |
| `health.lua` | `:checkhealth markview-smart-tables` preconditions            |

The smart path declines — returning control to stock markview — when:

- Neovim < 0.11 (`conceal_lines` unavailable)
- `'wrap'` is off and the table already fits the window
- the header or a row parses to zero columns (mid-edit, e.g. text typed before
  the leading `|`) — rendering it virtually would hide real text
- markview's `linewise_hybrid_mode` is active (its per-line clears would strip
  part of the virtual table's conceals, duplicating rows)
- there is no line to anchor the virtual table to (table spans the whole
  buffer)

## The fully virtual rendering

A fitted table cannot be drawn in-buffer: cell text must move between lines,
and inline `virt_text`/`conceal` cannot survive soft-wrap (Neovim computes
soft-wrap break points from raw buffer columns). So `table.lua` redraws the
table the way a CLI renderer would:

1. **Tokenise** every cell into `{ text, hl }` segments (`inline.lua`): the cell
   text is parsed as a standalone `markdown_inline` treesitter string and
   treesitter's own highlight captures are replayed — bold, italic,
   strikethrough, code, links — with `@conceal`/`conceal`-metadata ranges
   dropped (so `**`, `` ` ``, link `[]()`/URLs disappear, just as in-buffer).
   Two constructs reuse markview's config to match its stock tables: code spans
   use `inline_codes` highlight + space padding (treesitter's `@markup.raw` is
   foreground-only and unpadded), and links use the `hyperlinks` icon + highlight
   resolved through markview's own `utils.match` (so a github URL gets its github
   glyph). Padding/icons use a non-breaking space so they stay attached through
   the word-wrap. Each visible run's text is realised through markview's
   `tostring`, so the substitutions treesitter does not do are applied like
   markview (entities `&amp;` -> `&`, emoji `:x:` -> glyph, escapes `\|` -> `|`);
   code runs are kept verbatim. Each cell's *rendered* width is the concatenated
   segment text; when treesitter is unavailable the whole cell falls back to
   `tostring`.
2. **Fit** the natural column widths into the budget — `wrap_width` resolved
   against the window width minus `textoff`, borders, and padding. The widest
   column shrinks first (`wrap.lua` `fit_columns`), never below
   `wrap_minwidth`; in pathological cases (tiny window, many columns) columns
   are forced down to 1 so the table never overflows.
3. **Word-wrap** each overflowing cell to its column width, highlight-aware
   (`wrap.lua` `style_wrap`): cells wrap as a list of styled words so a span's
   highlight survives the break; words wider than the column are hard-broken
   with display-width-aware splitting (handles double-width glyphs).
4. **Emit** `virt_lines`: top border, centred header, separator with alignment
   markers, data rows with a thin rule between them (reusing markview's
   `parts.separator` glyphs in the border colour), bottom border. Cell
   alignment follows the column's `:---:` markers.
5. **Hide** every source line with a `conceal_lines` extmark (zero screen
   height — immune to soft-wrap) and attach the virtual table to the nearest
   visible neighbour line (`virt_lines` on a concealed line are not drawn:
   prefer the line above, else `virt_lines_above` on the line after).

All extmarks go into **markview's markdown namespace** (`markdown.ns`), so
markview's own clear/re-render cycle manages their lifetime — the plugin needs
no clearing logic of its own, and hybrid-mode reveals work unchanged (markview
filters the table node out before rendering; nothing is drawn and the raw
markdown shows through).

## Resize handling

The layout is sized to the window at render time, so a window width change
(sidebar toggle, split, terminal resize) would leave stale-width tables — and
no manual refresh short of an edit re-renders them. The first `M.render` call
that actually commits to drawing a smart table (i.e. past every decline check)
therefore registers `resize.lua`'s `WinResized`/`VimResized` autocmd (its own
augroup, `markview.smart_table.resize`) that re-renders affected,
markview-attached buffers, debounced with markview's `preview.debounce`.
Sessions that never render a smart table never get the autocmd.

## markview surface

Public / documented:

- `renderers.markdown_table` custom-renderer hook and its `(buffer, item)`
  contract (including the parsed table item shape)

Internal (no stability guarantee — the compatibility risk lives here):

- `markview.renderers.markdown` — `.table` (stock fallback) and `.ns`
  (shared namespace)
- `markview.renderers.markdown.tostring` — cell text/width fallback when
  treesitter is unavailable
- `markview.spec` — `markdown.tables` config (`parts`/`hl`),
  `markdown_inline.inline_codes` (cell code highlight + padding),
  `markdown_inline.hyperlinks` (cell link icon/highlight), `preview.debounce`,
  `preview.linewise_hybrid_mode`/`hybrid_modes`
- `markview.state` / `markview.actions` — enable/attach checks and `render()`
  for the resize autocmd
- `markview.utils` — `buf_getwin`, `set_hl`, and `match` (markview's hyperlink
  config resolution, reused for cell links)

Treesitter (via `vim.treesitter`):

- `get_string_parser` + the `markdown_inline` `highlights` query — replayed per
  cell for inline styling (`inline.lua`). Header cell text uses markview's
  configured header group (`markdown.tables.hl.header`, i.e. `MarkviewTableHeader`
  -> `@markup.heading`); which row is the header comes from the parsed item, not
  treesitter.

## Design decisions

**Implemented as a plugin hook, not a markview fork.** markview dispatches every
parsed node through a documented extension point first: the `renderers` config
key (`:h markview.nvim-renderers`). A function registered as
`renderers.markdown_table` fully replaces table rendering and can call the stock
renderer as its fallback. Building on that hook lets the plugin run against
**stock upstream markview** — no patched markview files, no rebase treadmill, no
waiting on upstream review.

Consequences:

- Users run stock markview; the plugin updates independently and can be shared
  without touching markview itself.
- The decline-to-stock fallback keeps every markview behaviour intact (fitting
  tables under `'nowrap'`, malformed mid-edit rows, Neovim < 0.11,
  `linewise_hybrid_mode`).
- The plugin depends on the few markview internals listed above, with no
  stability guarantee; a major markview refactor may break it until adapted.
  Accepted — markview pins protect against surprise breakage and the surface is
  small.
- If upstream ever ships the feature natively, this plugin retires.
