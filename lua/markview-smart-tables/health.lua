--[[
`:checkhealth markview-smart-tables`.

Verifies the runtime preconditions the smart path needs (Neovim 0.11+,
markview installed) and the two things that silently route every table back to
markview's stock renderer if misconfigured: the `renderers.markdown_table`
hook not being wired up, and `linewise_hybrid_mode` being active.
]]
local M = {}

local start = vim.health.start
local ok = vim.health.ok
local warn = vim.health.warn
local error = vim.health.error
local info = vim.health.info

M.check = function()
  start("markview-smart-tables.nvim")

  --- Neovim version — `conceal_lines` (used to hide source rows) needs 0.11.
  if vim.fn.has("nvim-0.11") == 1 then
    ok("Neovim 0.11+ (`conceal_lines` available)")
  else
    error("Neovim < 0.11 — smart tables disabled, markview renders tables as usual", {
      "Upgrade to Neovim 0.11 or newer to enable smart tables.",
    })
  end

  --- markview must be installed; the plugin reuses several of its internals.
  local has_markview = pcall(require, "markview")

  if has_markview then
    ok("markview.nvim is installed")
  else
    error("markview.nvim not found", {
      "Install OXY2DEV/markview.nvim — it is a hard dependency.",
    })
    return
  end

  --- The hook must be registered, or `render()` is never reached and tables
  --- fall through to stock markview rendering.
  local spec_ok, spec = pcall(require, "markview.spec")
  local hook = spec_ok
    and spec.get
    and spec.get({ "renderers", "markdown_table" }, { fallback = nil })

  if type(hook) == "function" then
    ok("`renderers.markdown_table` hook is wired up")
  else
    warn("`renderers.markdown_table` is not set — smart tables will not run", {
      "Add the hook to your markview setup:",
      "  require('markview').setup({",
      "      renderers = {",
      "          markdown_table = function (buffer, item)",
      "              require('markview-smart-tables').render(buffer, item)",
      "          end,",
      "      },",
      "  })",
    })
  end

  --- `linewise_hybrid_mode` makes the smart path decline (its per-line clears
  --- would duplicate rows), so warn rather than fail.
  local linewise = spec_ok
    and spec.get
    and spec.get({ "preview", "linewise_hybrid_mode" }, { fallback = false, ignore_enable = true })
  local hybrid = spec_ok
    and spec.get
    and spec.get({ "preview", "hybrid_modes" }, { fallback = {}, ignore_enable = true })

  if linewise == true and type(hybrid) == "table" and #hybrid > 0 then
    warn(
      "`preview.linewise_hybrid_mode` is active — tables use stock rendering, not smart tables",
      {
        "Smart tables are all-or-nothing and cannot honour per-line reveals.",
        "Disable `preview.linewise_hybrid_mode` to enable smart tables.",
      }
    )
  else
    ok("hybrid mode is compatible with smart tables")
  end

  --- Plugin's own enable flag.
  local cfg_ok, mod = pcall(require, "markview-smart-tables")

  if cfg_ok and mod.config and mod.config.enable == false then
    info("`enable = false` — smart tables are off, stock markview rendering only")
  end
end

return M
