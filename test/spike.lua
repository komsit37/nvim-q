-- spike.lua: connect to q -p 5000, send .Q.s til 10, decode, print.
-- Run with:  nvim -l test/spike.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local client = require("nvim-q.ipc.client")

local function repr(v)
  if type(v) == "string" then
    return string.format("%q", v)
  elseif type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do parts[i] = repr(x) end
    return "{" .. table.concat(parts, ", ") .. "}"
  else
    return tostring(v)
  end
end

print("=== nvim-q spike ===")
print("Connecting to localhost:5000 ...")

local c = client.connect("localhost", 5000)
print("Connected OK")

-- Test 1: basic .Q.s til 10
local r1 = c:query(".Q.s til 10")
print("[Test 1] .Q.s til 10 ==> " .. repr(r1))
assert(type(r1) == "string" or type(r1) == "table", "expected string or table")

-- Test 2: error path
local ok2, err2 = pcall(function()
  return c:query("`sym")  -- bare symbol reference to trigger q 'type error or use bad expr
end)
if not ok2 then
  print("[Test 2] error path triggered: " .. tostring(err2))
else
  print("[Test 2] .Q.s `sym returned: " .. repr(err2))
end

-- Test 3: medium result
print("[Test 3] Sending .Q.s til 10000 ...")
local ok3, r3 = pcall(function() return c:query(".Q.s til 10000") end)
if ok3 then
  local sz = type(r3) == "string" and #r3 or "table"
  print(string.format("[Test 3] OK, result size=%s type=%s", tostring(sz), type(r3)))
else
  print("[Test 3] ERROR: " .. tostring(r3))
end

-- Test 4: large result to trigger compression
print("[Test 4] Sending .Q.s til 1000000 (large - may compress) ...")
local ok4, r4 = pcall(function() return c:query(".Q.s til 1000000") end)
if ok4 then
  local sz = type(r4) == "string" and #r4 or "table"
  print(string.format("[Test 4] OK, result size=%s type=%s", tostring(sz), type(r4)))
else
  print("[Test 4] ERROR: " .. tostring(r4))
end

-- Test 5: error response from q
print("[Test 5] Sending an expression that errors in q ...")
local ok5, err5 = pcall(function()
  return c:query("1+`a")  -- type error
end)
if not ok5 then
  print("[Test 5] q error correctly raised: " .. tostring(err5))
else
  print("[Test 5] Unexpected success: " .. repr(err5))
end

c:close()
print("=== Done ===")
