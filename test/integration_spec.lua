-- test/integration_spec.lua
-- Real-q roundtrip tests. Skipped automatically if q is not available.
-- Also includes client.lua framing tests against the mock server.

package.path = (function()
  local src = debug.getinfo(1, "S").source:sub(2)
  local repo = src:match("^(.*)/test/") or "."
  return repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" ..
         repo .. "/test/?.lua;" .. package.path
end)()

local client     = require("nvim-q.ipc.client")
local mock_server = require("mock_server")

-- ── Mock-server tests (always run; no q license needed) ───────────────────

describe("client framing (mock server)", function()
  local server
  local PORT = 59100

  before_each(function()
    server = nil
  end)

  after_each(function()
    if server then server:stop() end
  end)

  it("connects and performs handshake", function()
    server = mock_server.start({
      port      = PORT,
      responses = { mock_server.char_vector_msg("ok") },
    })
    -- Give the server a moment to bind
    vim.wait(50, function() return false end)

    local c = client.connect("localhost", PORT)
    assert.is_not_nil(c)
    c:close()
  end)

  it("sends a query and receives a char vector response", function()
    server = mock_server.start({
      port      = PORT + 1,
      responses = { mock_server.char_vector_msg("hello from mock") },
    })
    vim.wait(50, function() return false end)

    local c = client.connect("localhost", PORT + 1)
    local result = c:query("ignored — mock replies with canned data")
    assert.equals("hello from mock", result)
    c:close()
  end)

  it("raises Lua error on q error response", function()
    server = mock_server.start({
      port      = PORT + 2,
      responses = { mock_server.error_msg("rank") },
    })
    vim.wait(50, function() return false end)

    local c = client.connect("localhost", PORT + 2)
    local ok, err = pcall(function()
      return c:query("something bad")
    end)
    assert.is_false(ok)
    assert.truthy(tostring(err):find("rank"), "error should mention 'rank'")
    c:close()
  end)

  it("handles multi-message exchange (sequential queries)", function()
    server = mock_server.start({
      port      = PORT + 3,
      responses = {
        mock_server.char_vector_msg("first"),
        mock_server.char_vector_msg("second"),
      },
    })
    vim.wait(50, function() return false end)

    local c = client.connect("localhost", PORT + 3)
    local r1 = c:query("query1")
    local r2 = c:query("query2")
    assert.equals("first",  r1)
    assert.equals("second", r2)
    c:close()
  end)

end)

-- ── Real-q tests (skip if q is absent) ────────────────────────────────────

-- Check multiple possible locations
local Q_BIN = "/home/pkomsit/q/l64/q"
local q_available = (vim.fn.executable("q") == 1) or
                    (vim.fn.executable(Q_BIN) == 1)

if not q_available then
  -- Try to ping the already-running server at port 5000
  q_available = client.ping("localhost", 5000)
end

if not q_available then
  print("integration_spec: skipping real-q tests (q not available)")
  return
end

describe("roundtrip (real q at port 5000)", function()

  -- Try to use the already-running server; if not available, spawn one
  local port = 5000
  local job  = nil

  before_each(function()
    if not client.ping("localhost", port) then
      -- Spawn our own instance on a random port
      port = 59200 + math.random(0, 99)
      local q_exec = vim.fn.executable("q") == 1 and "q" or Q_BIN
      job = vim.fn.jobstart({ q_exec, "-p", tostring(port) })
      -- Wait up to 3s for q to be ready
      vim.wait(3000, function()
        local ok = pcall(function() client.ping("localhost", port) end)
        return ok
      end, 50)
    end
  end)

  after_each(function()
    if job then
      vim.fn.jobstop(job)
      job = nil
    end
  end)

  it("decodes .Q.s til 3 → '0 1 2\\n'", function()
    local c = client.connect("localhost", port)
    local result = c:query(".Q.s til 3")
    assert.equals("0 1 2\n", result)
    c:close()
  end)

  it("decodes .Q.s til 10", function()
    local c = client.connect("localhost", port)
    local result = c:query(".Q.s til 10")
    assert.is_string(result)
    assert.truthy(result:find("9"), "should contain 9")
    c:close()
  end)

  it("raises Lua error on q type error (1+`a)", function()
    local c = client.connect("localhost", port)
    local ok, err = pcall(function() return c:query("1+`a") end)
    assert.is_false(ok)
    assert.truthy(tostring(err):find("type"), "should be 'type' error")
    c:close()
  end)

  it("decodes symbol atom `mysymbol", function()
    local c = client.connect("localhost", port)
    local result = c:query("`mysymbol")
    assert.is_string(result)
    assert.equals("mysymbol", result)
    c:close()
  end)

  it("decodes long atom 42j", function()
    local c = client.connect("localhost", port)
    local result = c:query("42j")
    assert.is_number(result)
    assert.equals(42, result)
    c:close()
  end)

  it("decodes general list of char vectors", function()
    local c = client.connect("localhost", port)
    local result = c:query("(\"hello\";\"world\")")
    assert.is_table(result)
    assert.equals(2, #result)
    assert.equals("hello", result[1])
    assert.equals("world", result[2])
    c:close()
  end)

  it("ping returns true for running server", function()
    assert.is_true(client.ping("localhost", port))
  end)

  it("ping returns false for closed port", function()
    assert.is_false(client.ping("localhost", 59999))
  end)

end)
