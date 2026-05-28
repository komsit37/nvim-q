-- test/encode_spec.lua
-- Pure unit tests for ipc/encode.lua (no q, no socket, no vim.* needed).

package.path = (function()
  -- Support both: nvim -l (cwd=repo) and plenary (cwd varies)
  local src = debug.getinfo(1, "S").source:sub(2)
  local repo = src:match("^(.*)/test/") or "."
  return repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
end)()

local encode = require("nvim-q.ipc.encode")

-- ── helpers ────────────────────────────────────────────────────────────────

local function byte_at(s, i) return s:byte(i) end

local function le32_at(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

local function hex(s)
  local t = {}
  for i = 1, #s do t[i] = string.format("%02x", s:byte(i)) end
  return table.concat(t, " ")
end

-- ── busted-style tests (plenary) ───────────────────────────────────────────

describe("encode", function()
  describe("encode(query)", function()

    it("returns a string", function()
      local msg = encode.encode("1+1")
      assert.is_string(msg)
    end)

    it("has the correct total length", function()
      local q   = "til 10"
      local msg = encode.encode(q)
      -- total_len = 8 (header) + 1 (type) + 1 (attr) + 4 (len) + #q
      local expected_total = 8 + 6 + #q
      assert.equals(expected_total, #msg)
    end)

    it("header byte 0: endian = 0x01 (little-endian)", function()
      assert.equals(0x01, byte_at(encode.encode("x"), 1))
    end)

    it("header byte 1: msgtype = 0x01 (sync)", function()
      assert.equals(0x01, byte_at(encode.encode("x"), 2))
    end)

    it("header byte 2: compressed = 0x00", function()
      assert.equals(0x00, byte_at(encode.encode("x"), 3))
    end)

    it("header byte 3: pad = 0x00", function()
      assert.equals(0x00, byte_at(encode.encode("x"), 4))
    end)

    it("header bytes 4-7: total_len correct (LE uint32)", function()
      local q   = "1+1"
      local msg = encode.encode(q)
      local expected = 8 + 6 + #q
      assert.equals(expected, le32_at(msg, 5))
    end)

    it("payload byte 8: type = 0x0A (char vector)", function()
      assert.equals(0x0A, byte_at(encode.encode("x"), 9))
    end)

    it("payload byte 9: attr = 0x00", function()
      assert.equals(0x00, byte_at(encode.encode("x"), 10))
    end)

    it("payload bytes 10-13: vector length (LE uint32)", function()
      local q   = "hello"
      local msg = encode.encode(q)
      assert.equals(5, le32_at(msg, 11))
    end)

    it("payload bytes 14+: raw query bytes", function()
      local q   = "til 3"
      local msg = encode.encode(q)
      assert.equals(q, msg:sub(15, 15 + #q - 1))
    end)

    it("empty query string", function()
      local msg = encode.encode("")
      assert.equals(8 + 6, #msg)
      assert.equals(0, le32_at(msg, 11))
    end)

    it("encodes a unicode-free ASCII query correctly", function()
      local q = ".Q.s til 10"
      local msg = encode.encode(q)
      -- chars start at byte 15 (after 8 header + 1 type + 1 attr + 4 len)
      -- '.Q.s til 10': '.' at 15, 'Q' at 16, '.' at 17, 's' at 18
      assert.equals(string.byte("Q"), byte_at(msg, 16))
    end)

    it("total_len matches string length of message", function()
      local q   = "a very long query string that exercises the length field"
      local msg = encode.encode(q)
      assert.equals(#msg, le32_at(msg, 5))
    end)

  end)
end)
