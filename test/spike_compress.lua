-- Test compression: large char vector
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local encode = require("nvim-q.ipc.encode")
local decode = require("nvim-q.ipc.decode")

local function raw_query(query_str)
  local done = false
  local result = nil
  local errmsg = nil

  local tcp = vim.uv.new_tcp()
  vim.uv.tcp_connect(tcp, "127.0.0.1", 5000, function(err)
    if err then errmsg = tostring(err); done = true; return end
    vim.uv.write(tcp, "\x03\x00", function()
      local buf = ""
      local got_cap = false
      local all_done = false
      vim.uv.read_start(tcp, function(re, data)
        if all_done then return end
        if re then errmsg = tostring(re); all_done = true; done = true; return end
        if data then buf = buf .. data end
        if not got_cap and #buf >= 1 then
          got_cap = true
          buf = ""
          vim.uv.write(tcp, encode.encode(query_str))
        elseif got_cap and #buf >= 8 then
          local endian = buf:byte(1)
          local compressed = buf:byte(3)
          local b5,b6,b7,b8 = buf:byte(5,8)
          local tlen = b5 + b6*256 + b7*65536 + b8*16777216
          if endian ~= 1 then tlen = b8 + b7*256 + b6*65536 + b5*16777216 end
          if #buf >= tlen then
            all_done = true
            vim.uv.read_stop(tcp)
            vim.uv.close(tcp)
            result = {bytes=buf:sub(1,tlen), compressed=compressed, tlen=tlen}
            done = true
          end
        end
      end)
    end)
  end)
  vim.wait(15000, function() return done end, 10)
  if errmsg then error(errmsg) end
  return result
end

-- Try various sizes to find the compression threshold
local queries = {
  {"5000#\"x\"",   "5k char"},
  {"10000#\"x\"",  "10k char"},
  {"50000#\"x\"",  "50k char"},
  {"100000#\"x\"", "100k char"},
  {"500000#\"x\"", "500k char"},
}

print("=== Compression threshold testing ===")
for _, q in ipairs(queries) do
  local expr, label = q[1], q[2]
  local ok, r = pcall(raw_query, expr)
  if ok then
    print(string.format("  %-12s compressed=%d total_len=%d",
      label, r.compressed, r.tlen))
    if r.compressed == 1 then
      -- Try to decode
      local ok2, v = pcall(decode.decode, r.bytes)
      if ok2 then
        print(string.format("    Decompressed OK, decoded len=%s",
          type(v)=="string" and tostring(#v) or type(v)))
        -- Save as fixture
        local f = io.open("test/fixtures/compressed.bin", "wb")
        if f then f:write(r.bytes); f:close() end
        print("    Saved test/fixtures/compressed.bin")
        break
      else
        print("    Decompression/decode error: " .. tostring(v))
        break
      end
    end
  else
    print(string.format("  %-12s ERROR: %s", label, tostring(r)))
  end
end

print("=== Done ===")
