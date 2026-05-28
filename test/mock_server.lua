-- test/mock_server.lua
-- A minimal vim.uv TCP server that:
--   1. Accepts a connection
--   2. Sends the kdb+ handshake reply byte (capability = 3)
--   3. Reads the client's sync message (ignores payload)
--   4. Sends a canned response from the `responses` queue
-- Useful for testing client.lua framing/handshake without a real q license.
--
-- Usage (from a spec):
--   local mock = require("test.mock_server")
--   local server = mock.start({ port = 59001, responses = { bytes1, bytes2 } })
--   -- ... run client against port 59001 ...
--   server:stop()

local M = {}

--- Start a mock q server.
--- @param opts table  { port=number, responses=string[] }
--- @return table server  has :stop() method
function M.start(opts)
  opts = opts or {}
  local port      = opts.port or 59000
  local responses = opts.responses or {}
  local resp_idx  = 1

  local srv = vim.uv.new_tcp()
  vim.uv.tcp_bind(srv, "127.0.0.1", port)

  local client_handles = {}

  vim.uv.listen(srv, 4, function(listen_err)
    if listen_err then
      print("mock_server: listen error: " .. tostring(listen_err))
      return
    end

    local conn = vim.uv.new_tcp()
    vim.uv.accept(srv, conn)
    table.insert(client_handles, conn)

    -- Step 1: send capability byte (3)
    vim.uv.write(conn, "\x03")

    -- Step 2: read the client's handshake + query; then send canned response(s)
    local buf        = ""
    local got_hs     = false   -- consumed handshake bytes from client
    local expecting  = nil     -- expected message length once we have 8 bytes

    vim.uv.read_start(conn, function(read_err, data)
      if read_err or not data then
        -- connection closed or error
        return
      end
      buf = buf .. data

      if not got_hs then
        -- Handshake from client ends with \x00
        local null_pos = buf:find("\x00")
        if null_pos then
          got_hs = true
          buf = buf:sub(null_pos + 1)
        else
          return
        end
      end

      -- Now accumulate the query message
      while #buf >= 8 do
        if not expecting then
          local endian = buf:byte(1)
          local b5,b6,b7,b8 = buf:byte(5,8)
          if endian == 1 then
            expecting = b5 + b6*256 + b7*65536 + b8*16777216
          else
            expecting = b8 + b7*256 + b6*65536 + b5*16777216
          end
        end

        if expecting and #buf >= expecting then
          -- Consumed one full message; send the next canned response
          buf = buf:sub(expecting + 1)
          expecting = nil

          local resp = responses[resp_idx]
          if resp then
            resp_idx = resp_idx + 1
            vim.uv.write(conn, resp)
          else
            -- No more canned responses: send an error
            local err_msg = "out of responses"
            local function le32s(n)
              return string.char(
                bit.band(n, 0xFF), bit.band(bit.rshift(n,8), 0xFF),
                bit.band(bit.rshift(n,16), 0xFF), bit.band(bit.rshift(n,24), 0xFF))
            end
            local payload = "\x80" .. err_msg .. "\x00"
            local total   = 8 + #payload
            local fallback =
              "\x01\x02\x00\x00" .. le32s(total) .. payload
            vim.uv.write(conn, fallback)
          end
        else
          break
        end
      end
    end)
  end)

  local server = {
    port     = port,
    _srv     = srv,
    _clients = client_handles,
  }

  function server:stop()
    for _, c in ipairs(self._clients) do
      pcall(function()
        vim.uv.read_stop(c)
        vim.uv.close(c)
      end)
    end
    pcall(function() vim.uv.close(self._srv) end)
  end

  return server
end

--- Build a kdb+ response message for a char vector.
--- @param s string  The string payload.
--- @return string   Full message bytes (header + payload).
function M.char_vector_msg(s)
  local function le32s(n)
    return string.char(
      bit.band(n, 0xFF), bit.band(bit.rshift(n,8), 0xFF),
      bit.band(bit.rshift(n,16), 0xFF), bit.band(bit.rshift(n,24), 0xFF))
  end
  local payload = "\x0A\x00" .. le32s(#s) .. s
  local total   = 8 + #payload
  return "\x01\x02\x00\x00" .. le32s(total) .. payload
end

--- Build a kdb+ error response message.
--- @param msg string  Error message text.
--- @return string     Full message bytes.
function M.error_msg(msg)
  local function le32s(n)
    return string.char(
      bit.band(n, 0xFF), bit.band(bit.rshift(n,8), 0xFF),
      bit.band(bit.rshift(n,16), 0xFF), bit.band(bit.rshift(n,24), 0xFF))
  end
  local payload = "\x80" .. msg .. "\x00"
  local total   = 8 + #payload
  return "\x01\x02\x00\x00" .. le32s(total) .. payload
end

return M
