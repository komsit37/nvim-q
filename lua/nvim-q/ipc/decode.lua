-- nvim-q/ipc/decode.lua
-- Pure function: kdb+ IPC response bytes → Lua value.
-- No vim.* dependency — runs under bare LuaJIT / nvim -l.
-- Uses LuaJIT ffi.cast for typed reads.
--
-- Handles the limited type set needed by the .Q.s round-trip strategy:
--   10   char vector      → string
--   0    general list     → list (table) of Lua values (usually strings)
--   -11  symbol atom      → string
--   -7   long atom        → number
--   -128 error            → raises Lua error
--
-- Everything else raises "unsupported type N" so bugs are loud.

local ffi = require("ffi")
local bit = require("bit")

local M = {}

-- ── helpers ────────────────────────────────────────────────────────────────

-- Read a uint8 from a byte string at offset (1-based).
local function byte1(s, i) return s:byte(i) end

-- Read a little-endian uint32 from string s at 1-based offset i.
local function le32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 0x100 + c * 0x10000 + d * 0x1000000
end

-- Read a big-endian uint32.
local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return d + c * 0x100 + b * 0x10000 + a * 0x1000000
end

-- Read a little-endian int64 as a Lua number (may lose precision > 2^53).
local function le64_num(s, i)
  local lo = le32(s, i)
  local hi = le32(s, i + 4)
  -- hi can be negative in two's complement; handle sign
  if hi >= 0x80000000 then
    hi = hi - 0x100000000
  end
  return hi * 0x100000000 + lo
end

-- ── kdb LZ decompression ───────────────────────────────────────────────────
-- Algorithm: as documented in kdb+ IPC specification and cross-referenced
-- with michaelwittig/node-q, sv/kdbgo, and diamondrod/kdbplus.
--
-- Compressed message layout (after the 8-byte header):
--   bytes 0..3  : uncompressed_len  (uint32 LE) — total size of uncompressed payload
--   bytes 4..   : compressed data
--
-- The algorithm is an LZ77-family scheme using a 256-byte sliding window
-- indexed by a single byte (the "seed" for the hash). A control byte drives
-- 8 output decisions (one per bit, LSB first):
--   0 = literal byte  → copy next byte to output
--   1 = back-reference → (d, f) where d = source[i++], f = source[i++]
--         write (f - 2) bytes from output[d..] with overlap wrapping mod 256
-- The sliding window is addressed modulo 256: aa[d] = position in output.

local function decompress(data)
  -- data is the raw bytes AFTER the 8-byte message header
  -- The first 4 bytes are the uncompressed length (includes the header itself
  -- that we already stripped, so uncompressed payload len = ulen - 8).
  local ulen = le32(data, 1)  -- uncompressed total message length
  local payload_ulen = ulen - 8  -- we will return payload only (skip header copy)

  -- Build output buffer as a table of byte values for speed
  local out = {}
  local out_len = 0

  -- aa[i] = byte offset in `out` (0-based) where the last occurrence of
  -- a particular single-byte key was seen
  local aa = {}
  for i = 0, 255 do aa[i] = 0 end

  -- Compressed data starts at offset 5 (1-based), after the 4-byte ulen field
  local i = 5  -- source index (1-based into `data`)
  local src_len = #data

  -- We need to produce payload_ulen bytes of output
  -- But: the kdb compressed format actually encodes the *entire message*
  -- (header + payload) as uncompressed. We want just the payload bytes
  -- (everything after the 8-byte header). The typical approach: decompress
  -- the full ulen bytes, then return bytes [9..ulen].

  -- Let's decompress into `out` indexed from 1 (representing uncompressed bytes
  -- starting from the beginning of what would be the full uncompressed message).
  -- We track `n` = number of bytes output so far, target = ulen - 8 (payload).

  local n = 0          -- bytes written to out (0-based count)
  local f, s, p, d

  while n < ulen - 8 do
    if i > src_len then break end

    -- control byte: 8 bits, LSB first
    local ctrl = data:byte(i)
    i = i + 1

    for b = 0, 7 do
      if n >= ulen - 8 then break end
      if i > src_len then break end

      if bit.band(ctrl, bit.lshift(1, b)) == 0 then
        -- literal
        local byte_val = data:byte(i)
        i = i + 1
        n = n + 1
        out[n] = byte_val
        aa[byte_val] = n  -- remember last position (1-based)
      else
        -- back-reference: two bytes
        if i + 1 > src_len then break end
        d = data:byte(i)
        f = data:byte(i + 1)
        i = i + 2

        -- d = the key into aa; f = count+2
        local src_pos = aa[d]  -- 1-based position in out
        local count   = f - 2  -- number of bytes to copy

        if count < 0 then count = 0 end

        for _ = 1, count do
          if src_pos < 1 or src_pos > n then
            -- safety: shouldn't happen with valid data
            out[n + 1] = 0
          else
            out[n + 1] = out[src_pos]
          end
          src_pos = src_pos + 1
          n = n + 1
          -- update aa for last byte copied
          aa[out[n]] = n
        end

        -- update aa[d] to current position (matches kdb reference impl)
        aa[d] = n
      end
    end
  end

  -- Assemble output as a string
  local chars = {}
  for k = 1, n do
    chars[k] = string.char(out[k])
  end
  return table.concat(chars)
end

-- ── message-level entry: strip header, optionally decompress ──────────────

--- Decompress a full kdb+ response message if needed.
--- Returns the raw payload bytes (without the 8-byte header).
--- @param msg string  Full message bytes (header + payload).
--- @return string payload, boolean was_compressed
local function unwrap_message(msg)
  assert(#msg >= 8, "decode: message too short")

  -- Header layout:
  --   [1] endian       0=big, 1=little
  --   [2] msgtype      0=async, 1=sync, 2=response
  --   [3] compressed   0 or 1
  --   [4] pad
  --   [5..8] total_len uint32 in server endian

  local endian     = byte1(msg, 1)
  local compressed = byte1(msg, 3)

  local total_len
  if endian == 1 then
    total_len = le32(msg, 5)
  else
    total_len = be32(msg, 5)
  end

  assert(#msg >= total_len, string.format(
    "decode: message truncated (have %d, need %d)", #msg, total_len))

  if compressed == 1 then
    -- The payload starting at byte 9 contains the compressed data.
    -- decompress() returns the uncompressed payload (without the 8-byte header copy).
    local compressed_payload = msg:sub(9)
    -- We need to pass the 4-byte ulen that is embedded in the compressed stream.
    -- Actually decompress() expects data starting with those 4 bytes.
    local payload = decompress(compressed_payload)
    return payload, true
  else
    -- Uncompressed: payload = everything after the 8-byte header
    return msg:sub(9), false
  end
end

-- ── type decoders (operate on payload, with 1-based offset) ──────────────

local decode_value  -- forward declaration for recursive general list

-- Decode a char vector (type 10) at offset `pos` in `payload`.
-- Returns: string, next_pos
local function decode_char_vector(payload, pos, is_little_endian)
  -- attr byte then 4-byte length
  -- pos is pointing at attr (byte after the type byte)
  local _attr = byte1(payload, pos)  -- usually 0
  pos = pos + 1

  local len
  if is_little_endian then
    len = le32(payload, pos)
  else
    len = be32(payload, pos)
  end
  pos = pos + 4

  local s = payload:sub(pos, pos + len - 1)
  return s, pos + len
end

-- Decode a symbol atom (type -11).
-- Payload cursor is right after the type byte.
-- Symbol is null-terminated.
local function decode_symbol_atom(payload, pos)
  local start = pos
  while pos <= #payload and byte1(payload, pos) ~= 0 do
    pos = pos + 1
  end
  local sym = payload:sub(start, pos - 1)
  return sym, pos + 1  -- skip null terminator
end

-- Decode a long atom (type -7): 8-byte int64 LE.
local function decode_long_atom(payload, pos, is_little_endian)
  local n = le64_num(payload, pos)
  return n, pos + 8
end

-- Decode an error (-128): null-terminated string, raise as Lua error.
local function decode_error(payload, pos)
  local start = pos
  while pos <= #payload and byte1(payload, pos) ~= 0 do
    pos = pos + 1
  end
  local msg = payload:sub(start, pos - 1)
  error("q error: " .. msg, 0)
end

-- Decode a general list (type 0).
-- Format: attr(1) + count(4) + [items...]
local function decode_general_list(payload, pos, is_little_endian)
  local _attr = byte1(payload, pos)
  pos = pos + 1

  local count
  if is_little_endian then
    count = le32(payload, pos)
  else
    count = be32(payload, pos)
  end
  pos = pos + 4

  local result = {}
  for i = 1, count do
    local val
    val, pos = decode_value(payload, pos, is_little_endian)
    result[i] = val
  end
  return result, pos
end

-- Main recursive value decoder. `pos` points at the type byte.
decode_value = function(payload, pos, is_little_endian)
  assert(pos <= #payload, "decode: unexpected end of payload at pos " .. pos)
  local t = byte1(payload, pos)
  pos = pos + 1

  -- Interpret as signed byte
  if t >= 128 then t = t - 256 end

  if t == 10 then
    return decode_char_vector(payload, pos, is_little_endian)
  elseif t == 0 then
    return decode_general_list(payload, pos, is_little_endian)
  elseif t == -11 then
    return decode_symbol_atom(payload, pos)
  elseif t == -7 then
    return decode_long_atom(payload, pos, is_little_endian)
  elseif t == -128 then
    decode_error(payload, pos)  -- raises, never returns
  else
    error(string.format("nvim-q: unsupported kdb type %d", t), 0)
  end
end

-- ── public API ─────────────────────────────────────────────────────────────

--- Decode a full kdb+ response message (header + payload) → Lua value.
--- Raises a Lua error on q errors or unsupported types.
--- @param msg string  Complete raw message bytes from the socket.
--- @return any        Decoded Lua value (string, number, table, …).
function M.decode(msg)
  local endian = byte1(msg, 1)
  local is_little_endian = (endian == 1)

  local payload, was_compressed = unwrap_message(msg)
  local value, _next = decode_value(payload, 1, is_little_endian)
  return value
end

--- Expose internals for unit testing.
M._le32        = le32
M._le64_num    = le64_num
M._decompress  = decompress
M._unwrap      = unwrap_message

return M
