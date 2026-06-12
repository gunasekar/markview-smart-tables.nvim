-- luacheck configuration for markview-smart-tables.nvim
--
-- luacheck handles correctness/lint; stylua (see stylua.toml) handles
-- formatting. `make lint` runs both.

std = "luajit"

-- Neovim's global. Tests also use the `nvim -l` script environment.
read_globals = {
	"vim",
}

-- markview's style (and this plugin's) uses long, comment-rich lines.
max_line_length = false

-- Test specs intentionally shadow/redefine helpers across cases.
files["tests/"] = {
	globals = { "vim" },
}

exclude_files = {
	"lua_modules/",
	".luarocks/",
}
