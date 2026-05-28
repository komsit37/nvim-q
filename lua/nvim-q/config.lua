-- nvim-q/config.lua
-- Defaults table and deep-merge of user opts.
-- Pure Lua, no vim.* dependency (other than vim.deepcopy which is always available).

local M = {}

M.defaults = {
  -- List of connection defs: { name, host, port, user?, password? }
  connections = {},

  -- Install default keymaps when true; set false to bind your own.
  keymaps = true,

  -- Socket / query timeout in milliseconds.
  timeout = 5000,

  -- Output panel options.
  output = {
    height   = 15,       -- split height in lines
    position = "botright", -- split direction
    append   = true,     -- true = REPL scrollback; false = replace on each send
  },
}

-- Module-level current config (nil until setup() is called).
local _config = nil

--- Deep-merge `src` into `dst` (in place). Only recurses into table values.
--- Non-table values in `src` overwrite `dst`.
local function deep_merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      deep_merge(dst[k], v)
    else
      dst[k] = v
    end
  end
end

--- Initialise config by merging user opts over defaults.
--- Safe to call multiple times (each call resets from defaults).
--- @param opts table  User-supplied options (partial or full).
function M.setup(opts)
  _config = vim.deepcopy(M.defaults)
  if opts then
    deep_merge(_config, opts)
  end
end

--- Return the current merged config.
--- Falls back to defaults if setup() was never called.
--- @return table
function M.get()
  return _config or vim.deepcopy(M.defaults)
end

return M
