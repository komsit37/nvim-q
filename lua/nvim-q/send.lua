-- nvim-q/send.lua
-- Gather the current line or visual selection, wrap in .Q.s, resolve the active
-- connection (prompting a picker if none is set), call client:query, and route
-- the result to output.lua.
-- Error paths (connection refused, q errors) are caught here and surfaced via
-- vim.notify(ERROR) plus the output panel.

local config     = require("nvim-q.config")
local connection = require("nvim-q.connection")
local output     = require("nvim-q.output")

local M = {}

-- ── Text collection ───────────────────────────────────────────────────────

--- Collect the text to send.
--- `mode` = "n" → current line; "v" → visual selection ('< to '>).
--- Returns a single string (multi-line selection joined with "\n").
--- @param mode string  "n" or "v"
--- @param bufnr number
--- @return string
function M.collect(mode, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if mode == "v" or mode == "V" then
    -- Visual selection marks '<  and '> are set after leaving visual mode.
    local start_row = vim.fn.line("'<") - 1  -- 0-based
    local end_row   = vim.fn.line("'>") - 1  -- 0-based

    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)

    -- For char-wise visual, trim the start/end columns.
    -- For line-wise (V) we keep the whole lines.
    if mode == "v" then
      local start_col = vim.fn.col("'<") - 1
      local end_col   = vim.fn.col("'>")    -- exclusive

      if #lines == 1 then
        lines[1] = lines[1]:sub(start_col + 1, end_col)
      else
        lines[1] = lines[1]:sub(start_col + 1)
        lines[#lines] = lines[#lines]:sub(1, end_col)
      end
    end

    return table.concat(lines, "\n")
  else
    -- Normal mode: current line.
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-based
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    return line
  end
end

-- ── Query wrapping ────────────────────────────────────────────────────────

--- Wrap `text` for sending to q.
--- If the text starts with "\" it is a system command — send raw.
--- Otherwise prefix ".Q.s " so q formats the result as a char vector.
--- @param text string
--- @return string
function M.wrap(text)
  -- Strip leading/trailing whitespace for the check, but keep the original text.
  local trimmed = text:match("^%s*(.-)%s*$")

  if trimmed:sub(1, 1) == "\\" then
    -- System command (e.g. \l file.q, \t expr); send raw.
    return trimmed
  end

  return ".Q.s " .. text
end

-- ── Main send entry point ─────────────────────────────────────────────────

--- Send text to q and show the result.
--- `mode` is "n" (normal) or "v"/"V" (visual).
--- If no connection is active for this buffer, opens the picker first.
--- @param bufnr number
--- @param mode  string  "n" | "v" | "V"
function M.send(bufnr, mode)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Collect text.
  local text = M.collect(mode, bufnr)
  if not text or text:match("^%s*$") then
    vim.notify("nvim-q: nothing to send (empty selection)", vim.log.levels.WARN)
    return
  end

  local wrapped = M.wrap(text)

  -- Resolve the active connection; if none is set, open the picker first.
  local con = connection.get_active(bufnr)

  if not con then
    -- No connections configured at all.
    if #connection.get_connections() == 0 then
      vim.notify(
        "nvim-q: no connections configured. Call setup({ connections = {...} })",
        vim.log.levels.ERROR
      )
      return
    end

    -- Connections exist but none selected — pick one now, then send.
    connection.pick(bufnr, function(chosen)
      if chosen then
        M._do_send(bufnr, wrapped, text, chosen)
      else
        vim.notify("nvim-q: no connection selected", vim.log.levels.WARN)
      end
    end)
    return
  end

  M._do_send(bufnr, wrapped, text, con)
end

--- Internal: perform the actual query and display the result.
--- @param bufnr   number
--- @param wrapped string  The query string to send (possibly .Q.s-wrapped).
--- @param text    string  Original collected text (for display in status).
--- @param con     table   Connection definition.
function M._do_send(bufnr, wrapped, text, con)
  local t0 = vim.loop.hrtime()  -- nanoseconds

  -- Acquire a live client (may reconnect).
  local live_client
  local ok, connect_err = pcall(function()
    live_client = connection.ensure_client(con)
  end)

  if not ok or not live_client then
    local reason = tostring(connect_err or "unknown error")
    -- Strip leading "path/to/file.lua:N: " prefixes to keep the message clean.
    reason = reason:gsub("^.+%.lua:%d+: ", "")
    -- Strip the "nvim-q: connect failed: " prefix to avoid double-prefixing.
    reason = reason:gsub("^nvim%-q: connect failed: ", "")
    local msg = string.format(
      "nvim-q: cannot connect to %s:%d — %s",
      con.host or "localhost",
      con.port or 0,
      reason
    )
    vim.notify(msg, vim.log.levels.ERROR)
    output.show(nil, "ERROR: " .. msg)
    -- Drop dead client so next attempt reconnects cleanly.
    connection.drop_client(con)
    return
  end

  -- Run the query.
  local result
  local query_ok, query_err = pcall(function()
    result = live_client:query(wrapped)
  end)

  local elapsed_ms = math.floor((vim.loop.hrtime() - t0) / 1e6)
  local con_label  = string.format("%s (%s:%d)", con.name or "?", con.host or "localhost", con.port or 0)
  local status_str = string.format("%s  %dms", con_label, elapsed_ms)

  if not query_ok then
    local err = tostring(query_err)

    -- Connection was lost — drop from cache so the next send reconnects.
    if err:find("ECONNREFUSED") or err:find("EPIPE") or err:find("ECONNRESET") then
      connection.drop_client(con)
    end

    -- Surface a clean error message (no Lua stack trace).
    local clean = err:gsub("^.*: ", "")  -- strip "nvim-q: " prefix duplication
    local display = string.format("nvim-q: %s", clean)

    vim.notify(display, vim.log.levels.ERROR)
    output.show("ERROR: " .. clean, status_str)
    return
  end

  output.show(result, status_str)
end

return M
