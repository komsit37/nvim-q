-- nvim-q/ipc/encode.lua
-- Pure function: q query string → sync IPC message bytes.
-- No vim.* dependency — runs under bare LuaJIT / nvim -l.
-- Uses LuaJIT ffi for portable int32 writing (little-endian).

local ffi = require("ffi")

local M = {}

-- Write a uint32 as 4 little-endian bytes into a table of chars.
local function le32(n)
  n = n % 0x100000000  -- force unsigned 32-bit
  return string.char(
    bit.band(n, 0xFF),
    bit.band(bit.rshift(n, 8),  0xFF),
    bit.band(bit.rshift(n, 16), 0xFF),
    bit.band(bit.rshift(n, 24), 0xFF)
  )
end

--- Encode a query string into a kdb+ sync request message (IPC v3).
---
--- Wire layout:
---   [0]    endian    = 0x01  (little-endian)
---   [1]    msgtype   = 0x01  (sync = 1)
---   [2]    compressed= 0x00  (we never compress outgoing)
---   [3]    pad       = 0x00
---   [4..7] total_len = uint32 LE  (header 8 + payload)
---   [8]    type      = 0x0A  (char vector)
---   [9]    attr      = 0x00
---   [10..13] len     = uint32 LE  (number of chars)
---   [14..] raw bytes of the query string
---
--- @param query string  The q expression to send.
--- @return string       Raw bytes ready to write to the socket.
function M.encode(query)
  assert(type(query) == "string", "encode: query must be a string")

  local qlen     = #query
  -- payload = type(1) + attr(1) + len(4) + data(qlen)
  local payload  = 6 + qlen
  local total    = 8 + payload  -- header + payload

  local header = string.char(0x01, 0x01, 0x00, 0x00) .. le32(total)
  local vector = string.char(0x0A, 0x00) .. le32(qlen) .. query

  return header .. vector
end

return M
