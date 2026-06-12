.PHONY: all lint test docs format

all: lint test

# Lint (luacheck) + formatting check (stylua). CI runs this; it does not
# rewrite files — run `make format` to apply.
lint:
	luacheck lua/ tests/
	stylua --check lua/ tests/

# Apply stylua formatting in place.
format:
	stylua lua/ tests/

# Pure-function tests via the zero-dependency harness (see tests/run.lua).
test:
	nvim -l tests/run.lua

# Regenerate help tags from doc/ (the generated doc/tags is gitignored).
docs:
	nvim --headless -c "helptags doc" -c "qa"
