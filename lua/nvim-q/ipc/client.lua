-- nvim-q/ipc/client.lua
-- The ONLY module that touches network IO.
-- Uses vim.uv (libuv) for async TCP; exposes a synchronous client:query()
-- via vim.wait() so callers can use it like a blocking call.

local encode = require("nvim-q.ipc.encode")
local decode = require("nvim-q.ipc.decode")

local M = {}

-- ── Client object ──────────────────────────────────────────────────────────

local Client = {}
Client.__index = Client

--- Internal: perform handshake after TCP connection is established.
--- Sends capability byte, reads server's reply byte.
--- @param sock uv_tcp_t
--- @param opts table  { user=string, password=string }
--- @param callback function(err)
local function do_handshake(sock, opts, callback)
  local creds = ""
  if opts.user and opts.user ~= "" then
    creds = opts.user .. ":" .. (opts.password or "")
  end
  -- Capability byte 0x03: supports compression + timestamp/timespan
  local hs_msg = creds .. "\x03\x00"

  local cap_buf = ""
  local done = false

  local function on_read(err, data)
    if done then return end
    if err then
      done = true
      vim.uv.read_stop(sock)
      callback(err)
      return
    end
    if data then
      cap_buf = cap_buf .. data
    end
    -- Server replies with exactly one byte
    if #cap_buf >= 1 then
      done = true
      vim.uv.read_stop(sock)
      -- cap_buf:byte(1) is the server capability level — we don't need to store it
      callback(nil)
    end
  end

  vim.uv.write(sock, hs_msg, function(write_err)
    if write_err then
      callback(write_err)
      return
    end
    vim.uv.read_start(sock, on_read)
  end)
end

--- Internal: send an encoded message and receive the full response.
--- Calls callback(err, raw_msg_bytes) when complete.
local function send_recv(sock, encoded, callback)
  local buf = ""
  local expected = nil   -- total_len from header
  local header_done = false

  local function on_read(err, data)
    if err then
      vim.uv.read_stop(sock)
      callback(err, nil)
      return
    end

    if data then
      buf = buf .. data
    end

    -- Parse header once we have 8 bytes
    if not header_done and #buf >= 8 then
      header_done = true
      local endian = buf:byte(1)
      local b5, b6, b7, b8 = buf:byte(5, 8)
      if endian == 1 then
        -- little-endian
        expected = b5 + b6 * 0x100 + b7 * 0x10000 + b8 * 0x1000000
      else
        -- big-endian
        expected = b8 + b7 * 0x100 + b6 * 0x10000 + b5 * 0x1000000
      end
    end

    -- Check if we have the complete message
    if header_done and expected and #buf >= expected then
      vim.uv.read_stop(sock)
      callback(nil, buf:sub(1, expected))
    end
  end

  vim.uv.read_start(sock, on_read)
  vim.uv.write(sock, encoded, function(write_err)
    if write_err then
      vim.uv.read_stop(sock)
      callback(write_err, nil)
    end
    -- read continues in on_read
  end)
end

--- Async query: calls callback(result, err) when done.
--- @param self Client
--- @param text string   q expression
--- @param callback function(result, err)
function Client:query_async(text, callback)
  if not self.sock then
    callback(nil, "nvim-q: not connected")
    return
  end

  local encoded = encode.encode(text)

  send_recv(self.sock, encoded, function(err, raw_msg)
    if err then
      callback(nil, tostring(err))
      return
    end

    local ok, result = pcall(decode.decode, raw_msg)
    if not ok then
      callback(nil, tostring(result))
    else
      callback(result, nil)
    end
  end)
end

--- Blocking query using vim.wait().
--- @param self Client
--- @param text string   q expression
--- @return any  decoded result (raises on error)
function Client:query(text)
  local done, result, err = false, nil, nil

  self:query_async(text, function(res, e)
    done   = true
    result = res
    err    = e
  end)

  local timeout = self.timeout or 10000
  local ok = vim.wait(timeout, function() return done end, 10)
  if not ok then
    error("nvim-q: query timed out after " .. timeout .. "ms")
  end
  if err then
    error(err)
  end
  return result
end

--- Close the connection.
function Client:close()
  if self.sock then
    local s = self.sock
    self.sock = nil
    pcall(function()
      vim.uv.read_stop(s)
      vim.uv.shutdown(s, function()
        vim.uv.close(s)
      end)
    end)
  end
end

-- ── Module-level connect / ping ────────────────────────────────────────────

--- Connect to a q server and return a Client object.
--- Blocks until connected and handshake done.
--- @param host string
--- @param port number
--- @param opts? table  { user=string, password=string, timeout=number }
--- @return Client
function M.connect(host, port, opts)
  opts = opts or {}

  local done  = false
  local sock  = nil
  local conn_err = nil

  local tcp = vim.uv.new_tcp()
  if not tcp then
    error("nvim-q: failed to create TCP handle")
  end

  -- vim.uv.tcp_connect requires an IP address string, not a hostname.
  -- Resolve hostname first if needed.
  local connect_ip = host
  if host == "localhost" then connect_ip = "127.0.0.1" end

  vim.uv.tcp_connect(tcp, connect_ip, port, function(err)
    if err then
      conn_err = err
      done = true
      return
    end

    do_handshake(tcp, opts, function(hs_err)
      conn_err = hs_err
      sock     = tcp
      done     = true
    end)
  end)

  local timeout = opts.timeout or 5000
  local ok = vim.wait(timeout, function() return done end, 10)
  if not ok then
    pcall(vim.uv.close, tcp)
    error(string.format("nvim-q: connect to %s:%d timed out", host, port))
  end
  if conn_err then
    pcall(vim.uv.close, tcp)
    error(string.format("nvim-q: connect failed: %s", tostring(conn_err)))
  end

  local client = setmetatable({
    sock    = sock,
    host    = host,
    port    = port,
    timeout = opts.timeout or 10000,
  }, Client)

  return client
end

--- Ping: returns true if a q server is reachable and handshake succeeds.
--- @param host string
--- @param port number
--- @return boolean
function M.ping(host, port)
  local ok, err = pcall(function()
    local c = M.connect(host, port, { timeout = 2000 })
    c:close()
  end)
  return ok
end

return M
