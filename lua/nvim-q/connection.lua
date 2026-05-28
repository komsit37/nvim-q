-- nvim-q/connection.lua
-- QCon model, picker (vim.ui.select), per-buffer active connection.
-- Lazily opens the socket via ipc/client and caches the live client per connection.

local config = require("nvim-q.config")
local client = require("nvim-q.ipc.client")

local M = {}

-- ── Live client cache ─────────────────────────────────────────────────────
-- Keyed by "host:port[:user]" so different users share different clients.
local _clients = {}

local function cache_key(con)
  local key = (con.host or "localhost") .. ":" .. tostring(con.port or 0)
  if con.user and con.user ~= "" then
    key = key .. ":" .. con.user
  end
  return key
end

--- Ensure we have a live, connected client for `con`.
--- Reconnects if the cached client's socket is closed.
--- Raises a Lua error on connection failure.
--- @param con table  { host, port, user?, password?, timeout? }
--- @return Client
function M.ensure_client(con)
  local key = cache_key(con)
  local c = _clients[key]

  -- Check whether the cached client is still alive.
  if c and c.sock then
    return c
  end

  -- (Re)connect.
  local cfg = config.get()
  local timeout = con.timeout or cfg.timeout or 5000

  local new_client = client.connect(con.host or "localhost", con.port, {
    user     = con.user,
    password = con.password,
    timeout  = timeout,
  })

  _clients[key] = new_client
  return new_client
end

--- Drop the cached client for `con` (called on explicit disconnect / error).
--- @param con table
function M.drop_client(con)
  local key = cache_key(con)
  local c = _clients[key]
  if c then
    pcall(function() c:close() end)
    _clients[key] = nil
  end
end

-- ── Per-buffer active connection ─────────────────────────────────────────
-- We store the connection *name* (string) in vim.b to keep things serialisable.
-- The actual client object lives in _clients[].

-- Module-level global default connection name.
local _global_default_name = nil

--- Return the list of configured connections from config.
--- @return table[]
function M.get_connections()
  return config.get().connections or {}
end

--- Find a connection definition by name.
--- @param name string
--- @return table|nil
function M.find_by_name(name)
  for _, con in ipairs(M.get_connections()) do
    if con.name == name then
      return con
    end
  end
  return nil
end

--- Store `con` as the active connection for `bufnr` (and as the global default).
--- @param bufnr number
--- @param con table
function M.set_active(bufnr, con)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.b[bufnr].nvimq_connection = con.name
  _global_default_name = con.name
end

--- Return the active connection definition for `bufnr`.
--- Falls back to the global default, then to the first configured connection.
--- Returns nil if no connections are configured.
--- @param bufnr number
--- @return table|nil
function M.get_active(bufnr)
  -- 1. Per-buffer
  local name = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    local ok, val = pcall(function() return vim.b[bufnr].nvimq_connection end)
    if ok and type(val) == "string" and val ~= "" then
      name = val
    end
  end

  -- 2. Global default
  if not name then
    name = _global_default_name
  end

  -- 3. Resolve by name
  if name then
    local con = M.find_by_name(name)
    if con then return con end
  end

  -- 4. First configured connection as implicit default
  local cons = M.get_connections()
  if #cons > 0 then
    return cons[1]
  end

  return nil
end

--- Open a vim.ui.select picker over configured connections.
--- Calls `callback(con)` with the chosen connection, or `callback(nil)` on cancel.
--- @param bufnr number
--- @param callback function(con|nil)
function M.pick(bufnr, callback)
  local cons = M.get_connections()
  if #cons == 0 then
    vim.notify(
      "nvim-q: no connections configured — add connections to setup()",
      vim.log.levels.WARN
    )
    callback(nil)
    return
  end

  -- Build display items.
  local items = {}
  for _, con in ipairs(cons) do
    table.insert(items, con)
  end

  -- Mark the currently active connection in the display.
  local active = M.get_active(bufnr)
  local active_name = active and active.name

  vim.ui.select(items, {
    prompt = "nvim-q: select connection",
    format_item = function(con)
      local label = string.format("%s  (%s:%d)", con.name, con.host or "localhost", con.port or 0)
      if con.name == active_name then
        label = label .. "  [active]"
      end
      return label
    end,
  }, function(chosen)
    if chosen then
      M.set_active(bufnr, chosen)
    end
    callback(chosen)
  end)
end

return M
