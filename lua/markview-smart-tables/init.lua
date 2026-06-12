--[[
markview-smart-tables.nvim — auto-fit & word-wrap wide tables for markview.

Plugs into markview's custom-renderer mechanism(`:h markview.nvim-renderers`):

  require("markview").setup({
      renderers = {
          markdown_table = function (buffer, item)
              require("markview-smart-tables").render(buffer, item);
          end,
      },
  });

`render()` tries the smart(fully virtual, window-fitted) table first and
falls back to markview's stock table renderer whenever the smart path
declines — so everything markview normally does keeps working.
]]
local M = {}

---@class markview_smart_tables.config
---
---@field enable boolean Render smart tables(`false` -> stock markview rendering only).
---@field wrap_width number Max table width: a fraction `(0,1]` of the window, or an absolute column count `>1`.
---@field wrap_minwidth integer Smallest width(in cells) a column may shrink to; longer words are hard-broken.
M.config = {
  enable = true,
  wrap_width = 0.9,
  wrap_minwidth = 5,
}

---@param opts markview_smart_tables.config | nil
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--- Drop-in `renderers.markdown_table` implementation for markview.
---@param buffer integer
---@param item table Parsed table item(`markview.parsed.markdown.tables`).
M.render = function(buffer, item)
  local md = require("markview.renderers.markdown")

  if M.config.enable ~= false then
    local spec = require("markview.spec")

    --- markview's own table config supplies the visual parts(`parts`/`hl`)
    --- so smart tables match the user's markview theme; the fit options
    --- come from this plugin.
    local mv_config = spec.get(
      { "markdown", "tables" },
      { fallback = nil, eval_args = { buffer, item } }
    )

    if mv_config then
      local config = vim.tbl_extend("force", mv_config, {
        wrap_width = M.config.wrap_width,
        wrap_minwidth = M.config.wrap_minwidth,
      })

      if require("markview-smart-tables.table").render(buffer, item, config, md.ns) == true then
        return
      end
    end
  end

  --- Smart path declined(table fits under `'nowrap'`, malformed row,
  --- Neovim < 0.11, ...) — markview's stock renderer handles it.
  md.table(buffer, item)
end

return M
