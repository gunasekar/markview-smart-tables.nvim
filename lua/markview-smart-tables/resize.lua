--[[
Re-render when the window layout changes.

Smart tables are fitted to the window at render time, so a geometry change
(sidebar toggle, split, terminal resize) must re-render the affected buffers —
without it tables keep the stale width(truncated/overflowing borders), and no
manual refresh short of an edit repairs them.

The same applies to the options that decide that geometry. `'wrap'` matters
most: under `per_line` a row is drawn as one overlay per screen row its raw
text occupies, so toggling `'wrap'` changes how many overlays the row needs and
leaves every one of them on the wrong line. The gutter options(`'number'`,
`'signcolumn'`, …) move the text width, and `'linebreak'`/`'breakindent'`/
`'showbreak'` move the soft-wrap break columns. markview re-renders on
`'wrap'`/`'linebreak'` itself, but not reliably and not for the rest, so this
covers them all.

`M.register()` is called on the first smart-table render(see `table.lua`), so
sessions that never render a smart table never get the autocmd.
]]
local M = {}

local spec = require("markview.spec")

---@diagnostic disable-next-line: undefined-field
local timer = vim.uv.new_timer()

---@param args vim.api.keyset.create_autocmd.callback_args
local function on_layout_change(args)
  local state = require("markview.state")

  if not state.enabled() then
    return
  end

  --- The plugin may have been disabled after this autocmd was registered;
  --- without it nothing is sized to the window.
  if require("markview-smart-tables").config.enable == false then
    return
  end

  --- `WinResized` reports the affected windows; `VimResized` and `OptionSet`
  --- do not, but both can affect the whole layout, so take every window.
  ---
  --- NOTE: `vim.v.event` is only valid *inside* the autocmd, so the buffer
  --- list must be resolved before deferring.
  ---@type integer[]
  local wins = (args.event == "WinResized" and vim.v.event and vim.v.event.windows)
    or vim.api.nvim_tabpage_list_wins(0)

  local bufs, seen = {}, {}

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)

      if not seen[buf] and state.buf_attached(buf) and buf ~= state.get_splitview_source() then
        local buf_state = state.get_buffer_state(buf, false)

        if buf_state and buf_state.enable then
          seen[buf] = true
          bufs[#bufs + 1] = buf
        end
      end
    end
  end

  if #bufs == 0 then
    return
  end

  --- `new_timer()` returns nil on failure(e.g. fd exhaustion). Without a timer
  --- to debounce through, render synchronously rather than indexing nil.
  if not timer then
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(require("markview.actions").render, buf)
      end
    end
    return
  end

  local delay = spec.get({ "preview", "debounce" }, { fallback = 25, ignore_enable = true })

  timer:stop()
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      local actions = require("markview.actions")

      if not actions.in_preview_mode() then
        return
      end

      for _, buf in ipairs(bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
          --- Guarded so a render error on one buffer doesn't abort the rest.
          pcall(actions.render, buf)
        end
      end
    end)
  )
end

local group

--- Registers the re-render autocmds(once).
M.register = function()
  if group then
    return
  end

  group = vim.api.nvim_create_augroup("markview.smart_table.resize", { clear = true })

  vim.api.nvim_create_autocmd({
    "WinResized",
    "VimResized",
  }, {
    group = group,
    callback = on_layout_change,
  })

  --- Options that move the text width or the soft-wrap break columns, which
  --- the fitted width and the per-line overlay anchors are both computed from.
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = {
      "wrap",
      "linebreak",
      "breakindent",
      "showbreak",
      "number",
      "relativenumber",
      "numberwidth",
      "signcolumn",
      "foldcolumn",
    },
    callback = on_layout_change,
  })
end

return M
