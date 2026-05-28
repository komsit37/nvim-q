-- nvim-q/health.lua
-- :checkhealth nvim-q support.
-- Reports: Neovim version, vim.uv availability, LuaJIT/bit availability,
-- configured connections, and a live ping of each.

local M = {}

function M.check()
  local health = vim.health

  health.start("nvim-q")

  -- ── Neovim version ──────────────────────────────────────────────────────
  local version = vim.version()
  local ver_str = string.format("%d.%d.%d", version.major, version.minor, version.patch)
  if version.major > 0 or version.minor >= 9 then
    health.ok("Neovim version: " .. ver_str .. " (>= 0.9 required)")
  else
    health.error(
      "Neovim version: " .. ver_str .. " — nvim-q requires >= 0.9",
      { "Upgrade Neovim to 0.9 or later." }
    )
  end

  -- ── vim.uv availability ─────────────────────────────────────────────────
  if vim.uv then
    health.ok("vim.uv is available (libuv networking enabled)")
  else
    health.error(
      "vim.uv is not available",
      { "Upgrade to Neovim 0.9+ which bundles vim.uv." }
    )
  end

  -- ── LuaJIT / bit library ────────────────────────────────────────────────
  local luajit_ok = (type(jit) == "table" and jit.version ~= nil)
  if luajit_ok then
    health.ok("LuaJIT: " .. (jit.version or "unknown"))
  else
    health.warn(
      "LuaJIT not detected — ffi and bit libraries may be unavailable",
      { "nvim-q requires LuaJIT (bundled with standard Neovim builds)." }
    )
  end

  local bit_ok = pcall(require, "bit")
  if bit_ok then
    health.ok("bit library: available")
  else
    health.error(
      "bit library not available",
      { "The `bit` LuaJIT extension is required for IPC encoding/decoding." }
    )
  end

  -- ── Configured connections ──────────────────────────────────────────────
  local ok_cfg, config = pcall(require, "nvim-q.config")
  if not ok_cfg then
    health.error("Could not load nvim-q.config — plugin may not be set up correctly.")
    return
  end

  local cfg = config.get()
  local connections = cfg.connections or {}

  if #connections == 0 then
    health.warn(
      "No connections configured",
      { "Add connections in your setup() call:",
        "  require('nvim-q').setup({ connections = { { name='local', host='localhost', port=5000 } } })" }
    )
  else
    health.ok(string.format("%d connection(s) configured", #connections))
  end

  -- ── Ping each configured connection ────────────────────────────────────
  local ok_client, client = pcall(require, "nvim-q.ipc.client")
  if not ok_client then
    health.error("Could not load nvim-q.ipc.client")
    return
  end

  for _, con in ipairs(connections) do
    local label = string.format(
      "%s (%s:%d)",
      con.name or "?",
      con.host or "localhost",
      con.port or 0
    )

    local reachable = client.ping(con.host or "localhost", con.port or 0)
    if reachable then
      health.ok("  " .. label .. " — reachable")
    else
      health.warn(
        "  " .. label .. " — unreachable",
        { "Ensure the q server is running and the host/port are correct." }
      )
    end
  end
end

return M
