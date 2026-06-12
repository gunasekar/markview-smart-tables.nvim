--[[
Minimal zero-dependency test harness, run with:

    nvim -l tests/run.lua

Each `tests/*_spec.lua` returns `function (t)` and registers cases via
`t.it(name, fn)`. The `t` table also carries the assertions (`eq`, `same`).
Exits non-zero if any case fails, so CI can gate on it.
]]

--- Make the plugin requireable when run from the repo root.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local passed, failed = 0, 0
local failures = {}

--- `it` runs a case immediately and records the outcome; assertions raise, so
--- a pcall around the body turns a failed assertion into a recorded failure.
local t = {}

t.it = function(name, fn)
  local ok, err = pcall(fn)

  if ok then
    passed = passed + 1
    io.write("  ok   " .. name .. "\n")
  else
    failed = failed + 1
    failures[#failures + 1] = { name = name, err = err }
    io.write("  FAIL " .. name .. "\n")
  end
end

t.eq = function(expected, got)
  if expected ~= got then
    error(string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(got)), 2)
  end
end

--- Deep equality for the list/table results the wrap functions return.
t.same = function(expected, got)
  if not vim.deep_equal(expected, got) then
    error(string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(got)), 2)
  end
end

local specs = vim.fn.glob("./tests/*_spec.lua", true, true)
table.sort(specs)

for _, spec in ipairs(specs) do
  io.write(spec .. "\n")
  local chunk = assert(loadfile(spec))
  chunk()(t)
end

io.write(string.format("\n%d passed, %d failed\n", passed, failed))

if failed > 0 then
  io.write("\nFailures:\n")

  for _, f in ipairs(failures) do
    io.write("  " .. f.name .. "\n    " .. tostring(f.err) .. "\n")
  end

  os.exit(1)
end
