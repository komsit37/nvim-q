-- capture_fixtures.lua: Capture wire bytes for test fixtures
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local encode = require("nvim-q.ipc.encode")
local decode = require("nvim-q.ipc.decode")

local function capture(query_str, filename, done_cb)
  local done = false
  local raw_msg = nil

  local tcp = vim.uv.new_tcp()
  vim.uv.tcp_connect(tcp, "127.0.0.1", 5000, function(err)
    if err then
      print("connect err: " .. tostring(err))
      done = true
      if done_cb then done_cb() end
      return
    end

    vim.uv.write(tcp, "\x03\x00", function(we)
      local buf = ""
      local got_cap = false
      local all_done = false

      vim.uv.read_start(tcp, function(re, data)
        if all_done then return end
        if re then
          print("read err: " .. tostring(re))
          all_done = true
          done = true
          if done_cb then done_cb() end
          return
        end
        if data then buf = buf .. data end

        if not got_cap and #buf >= 1 then
          got_cap = true
          buf = ""
          local encoded = encode.encode(query_str)
          vim.uv.write(tcp, encoded)
        elseif got_cap then
          if #buf >= 8 then
            local endian = buf:byte(1)
            local compressed = buf:byte(3)
            local b5,b6,b7,b8 = buf:byte(5,8)
            local tlen
            if endian == 1 then
              tlen = b5 + b6*256 + b7*65536 + b8*16777216
            else
              tlen = b8 + b7*256 + b6*65536 + b5*16777216
            end

            if #buf >= tlen then
              all_done = true
              vim.uv.read_stop(tcp)
              vim.uv.close(tcp)

              print(string.format("  [%s] endian=%d compressed=%d total_len=%d",
                filename, endian, compressed, tlen))

              local f = io.open("test/fixtures/" .. filename, "wb")
              if f then
                f:write(buf:sub(1, tlen))
                f:close()
                print(string.format("  Saved test/fixtures/%s (%d bytes)", filename, tlen))
              end

              local ok, v = pcall(decode.decode, buf:sub(1, tlen))
              if ok then
                local t = type(v)
                local preview
                if t == "string" then
                  preview = string.format("%q", v:sub(1, 80))
                  if #v > 80 then preview = preview .. "..." end
                elseif t == "table" then
                  preview = "table[" .. #v .. "]"
                elseif t == "number" then
                  preview = tostring(v)
                else
                  preview = t
                end
                print(string.format("  Decoded: type=%s preview=%s", t, preview))
              else
                print("  Decode error: " .. tostring(v))
              end

              raw_msg = buf:sub(1, tlen)
              done = true
              if done_cb then done_cb() end
            end
          end
        end
      end)
    end)
  end)

  vim.wait(15000, function() return done end, 10)
end

print("=== Capturing fixtures ===")

-- til3 (already done but redo cleanly)
capture(".Q.s til 3", "til3.bin")

-- error fixture: 1+`a  → error type
capture("1+`a", "error_type.bin")

-- symbol atom
capture("`mysymbol", "sym_atom.bin")

-- long atom
capture("42j", "long_atom.bin")

-- general list of char vectors
capture("(\"hello\";\"world\")", "general_list.bin")

-- large result to check compression
print("\n[large query] .Q.s til 1000000 ...")
capture(".Q.s til 1000000", "large_til.bin")

print("=== All done ===")
