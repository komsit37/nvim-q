-- test/decode_spec.lua
-- Pure unit tests for ipc/decode.lua (no q, no socket, no vim.* needed).
-- Uses fixtures captured from a real q session.

package.path = (function()
  local src = debug.getinfo(1, "S").source:sub(2)
  local repo = src:match("^(.*)/test/") or "."
  return repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
end)()

local decode = require("nvim-q.ipc.decode")

-- ── fixture loader ─────────────────────────────────────────────────────────

local function fixture_path(name)
  local src = debug.getinfo(1, "S").source:sub(2)
  local dir = src:match("^(.*)/test/") or "."
  return dir .. "/test/fixtures/" .. name
end

local function read_fixture(name)
  local path = fixture_path(name)
  local f, err = io.open(path, "rb")
  if not f then
    error("fixture not found: " .. path .. " (" .. tostring(err) .. ")")
  end
  local data = f:read("*a")
  f:close()
  return data
end

-- ── helpers ────────────────────────────────────────────────────────────────

local function le32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

local function build_msg(payload_bytes, compressed)
  -- Wrap payload bytes in a full message header for testing decode()
  compressed = compressed or 0
  local total = 8 + #payload_bytes
  local function le32s(n)
    return string.char(
      bit.band(n, 0xFF), bit.band(bit.rshift(n,8), 0xFF),
      bit.band(bit.rshift(n,16), 0xFF), bit.band(bit.rshift(n,24), 0xFF))
  end
  return string.char(0x01, 0x02, compressed, 0x00) .. le32s(total) .. payload_bytes
end

-- ── tests ──────────────────────────────────────────────────────────────────

describe("decode", function()

  -- ── char vector (type 10) ────────────────────────────────────────────────

  describe("char vector (type 10)", function()
    it("decodes fixture til3.bin to '0 1 2\\n'", function()
      local msg = read_fixture("til3.bin")
      local result = decode.decode(msg)
      assert.is_string(result)
      assert.equals("0 1 2\n", result)
    end)

    it("decodes inline message correctly", function()
      -- payload: type=10, attr=0, len=5, "hello"
      local payload = "\x0A\x00\x05\x00\x00\x00hello"
      local msg = build_msg(payload)
      assert.equals("hello", decode.decode(msg))
    end)

    it("decodes empty char vector", function()
      local payload = "\x0A\x00\x00\x00\x00\x00"
      local msg = build_msg(payload)
      assert.equals("", decode.decode(msg))
    end)

    it("decodes char vector with newlines", function()
      local payload = "\x0A\x00\x04\x00\x00\x00a\nb\n"
      local msg = build_msg(payload)
      assert.equals("a\nb\n", decode.decode(msg))
    end)
  end)

  -- ── symbol atom (type -11) ───────────────────────────────────────────────

  describe("symbol atom (type -11)", function()
    it("decodes fixture sym_atom.bin to 'mysymbol'", function()
      local msg = read_fixture("sym_atom.bin")
      local result = decode.decode(msg)
      assert.is_string(result)
      assert.equals("mysymbol", result)
    end)

    it("decodes inline symbol atom", function()
      -- type=-11 = 0xF5 (unsigned), null-terminated
      local payload = "\xF5hello\x00"
      local msg = build_msg(payload)
      assert.equals("hello", decode.decode(msg))
    end)

    it("decodes empty symbol", function()
      local payload = "\xF5\x00"
      local msg = build_msg(payload)
      assert.equals("", decode.decode(msg))
    end)
  end)

  -- ── long atom (type -7) ──────────────────────────────────────────────────

  describe("long atom (type -7)", function()
    it("decodes fixture long_atom.bin to 42", function()
      local msg = read_fixture("long_atom.bin")
      local result = decode.decode(msg)
      assert.is_number(result)
      assert.equals(42, result)
    end)

    it("decodes inline long atom 0", function()
      -- type=-7 = 0xF9 (unsigned), then 8 bytes LE int64
      local payload = "\xF9\x00\x00\x00\x00\x00\x00\x00\x00"
      local msg = build_msg(payload)
      assert.equals(0, decode.decode(msg))
    end)

    it("decodes inline long atom 1", function()
      local payload = "\xF9\x01\x00\x00\x00\x00\x00\x00\x00"
      local msg = build_msg(payload)
      assert.equals(1, decode.decode(msg))
    end)
  end)

  -- ── error (-128) ─────────────────────────────────────────────────────────

  describe("error (type -128)", function()
    it("raises Lua error for fixture error_type.bin", function()
      local msg = read_fixture("error_type.bin")
      local ok, err = pcall(decode.decode, msg)
      assert.is_false(ok)
      assert.truthy(err:find("type"), "error should mention 'type', got: " .. err)
    end)

    it("raises Lua error for inline error payload", function()
      -- type=-128 = 0x80 (unsigned), null-terminated message
      local payload = "\x80woops\x00"
      local msg = build_msg(payload)
      local ok, err = pcall(decode.decode, msg)
      assert.is_false(ok)
      assert.truthy(err:find("woops"), "should contain error text")
    end)

    it("error message includes 'q error:'", function()
      local payload = "\x80rank\x00"
      local msg = build_msg(payload)
      local ok, err = pcall(decode.decode, msg)
      assert.is_false(ok)
      assert.truthy(err:find("q error:"))
    end)
  end)

  -- ── general list (type 0) ────────────────────────────────────────────────

  describe("general list (type 0)", function()
    it("decodes fixture general_list.bin to {'hello','world'}", function()
      local msg = read_fixture("general_list.bin")
      local result = decode.decode(msg)
      assert.is_table(result)
      assert.equals(2, #result)
      assert.equals("hello", result[1])
      assert.equals("world", result[2])
    end)

    it("decodes inline general list of char vectors", function()
      -- type=0, attr=0, count=2, then two char vectors
      local cv1 = "\x0A\x00\x03\x00\x00\x00foo"
      local cv2 = "\x0A\x00\x03\x00\x00\x00bar"
      local payload = "\x00\x00\x02\x00\x00\x00" .. cv1 .. cv2
      local msg = build_msg(payload)
      local result = decode.decode(msg)
      assert.is_table(result)
      assert.equals("foo", result[1])
      assert.equals("bar", result[2])
    end)

    it("decodes empty general list", function()
      local payload = "\x00\x00\x00\x00\x00\x00"
      local msg = build_msg(payload)
      local result = decode.decode(msg)
      assert.is_table(result)
      assert.equals(0, #result)
    end)
  end)

  -- ── compressed messages ──────────────────────────────────────────────────

  describe("compressed message", function()
    it("decodes a synthetically compressed char vector 'hi'", function()
      local function le32s(n)
        return string.char(
          bit.band(n, 0xFF), bit.band(bit.rshift(n,8), 0xFF),
          bit.band(bit.rshift(n,16), 0xFF), bit.band(bit.rshift(n,24), 0xFF))
      end
      -- uncompressed payload: type(1)+attr(1)+len(4)+"hi"(2) = 8 bytes
      -- ulen = 8 (header) + 8 (payload) = 16
      -- compressed data: ctrl=0x00, then 8 literal payload bytes
      local payload_bytes = "\x0A\x00\x02\x00\x00\x00hi"
      local compressed_data = le32s(16) .. "\x00" .. payload_bytes
      local total = 8 + #compressed_data

      local full_msg =
        "\x01\x02\x01\x00" ..  -- endian=1, type=2 (response), compressed=1, pad=0
        le32s(total) ..
        compressed_data

      local result = decode.decode(full_msg)
      assert.equals("hi", result)
    end)
  end)

  -- ── helper internals ──────────────────────────────────────────────────────

  describe("_le32 helper", function()
    it("reads little-endian uint32", function()
      local s = "\x01\x02\x03\x04"
      assert.equals(0x04030201, decode._le32(s, 1))
    end)

    it("reads from offset", function()
      local s = "\x00\x00\x01\x00\x00\x00"
      assert.equals(1, decode._le32(s, 3))
    end)
  end)

  describe("_le64_num helper", function()
    it("reads 42 as int64", function()
      local s = "\x2A\x00\x00\x00\x00\x00\x00\x00"
      assert.equals(42, decode._le64_num(s, 1))
    end)
  end)

end)
