-- nvim-q/output.lua
-- Manage a dedicated scratch split buffer for q query results.
-- Filetype: q_output  buftype: nofile  unlisted.
-- show(result) appends result content (REPL scrollback).
-- status(str) echoes the connection/elapsed status to the message line.
-- clear() wipes content.
-- toggle() shows/hides the window.

local M = {}

-- Module-level buffer and window handles.
local _buf = nil
local _win = nil

-- Name used to identify our scratch buffer.
local BUF_NAME = "nvim-q://output"

-- ── Buffer management ─────────────────────────────────────────────────────

--- Return true if `bufnr` is a valid, loaded buffer.
local function buf_valid(bufnr)
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

--- Return true if `winid` is a valid, open window.
local function win_valid(winid)
  return winid ~= nil and vim.api.nvim_win_is_valid(winid)
end

--- Get or create the output scratch buffer.
--- @return number  bufnr
function M.get_or_create_buf()
  if buf_valid(_buf) then
    return _buf
  end

  -- Check if a buffer with our name already exists (e.g. after :bdelete then reopen).
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local ok, name = pcall(vim.api.nvim_buf_get_name, b)
    if ok and name == BUF_NAME and vim.api.nvim_buf_is_valid(b) then
      _buf = b
      return _buf
    end
  end

  -- Create a new scratch buffer.
  local buf = vim.api.nvim_create_buf(false, true)  -- listed=false, scratch=true
  vim.api.nvim_buf_set_name(buf, BUF_NAME)
  vim.bo[buf].buftype  = "nofile"
  vim.bo[buf].filetype = "q_output"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = true

  _buf = buf
  return _buf
end

-- ── Window management ─────────────────────────────────────────────────────

--- Open the output buffer in a split and return the window id.
--- Focuses back on the original window.
--- @return number  winid
function M.get_or_create_win()
  local buf = M.get_or_create_buf()

  if win_valid(_win) then
    -- Already open; make sure it's showing our buffer.
    local current = vim.api.nvim_win_get_buf(_win)
    if current ~= buf then
      vim.api.nvim_win_set_buf(_win, buf)
    end
    return _win
  end

  -- Find if any existing window already shows our buffer.
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      _win = w
      return _win
    end
  end

  -- Save current window so we can return focus.
  local origin_win = vim.api.nvim_get_current_win()

  -- Open a new split.
  local cfg = require("nvim-q.config").get()
  local height   = (cfg.output and cfg.output.height)   or 15
  local position = (cfg.output and cfg.output.position) or "botright"

  vim.cmd(position .. " " .. height .. "split")
  local new_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(new_win, buf)

  -- Set window-local options.
  vim.wo[new_win].wrap        = false
  vim.wo[new_win].number      = false
  vim.wo[new_win].relativenumber = false
  vim.wo[new_win].signcolumn  = "no"
  vim.wo[new_win].cursorline  = true

  _win = new_win

  -- Return focus to the original window.
  vim.api.nvim_set_current_win(origin_win)

  return _win
end

-- ── Content operations ────────────────────────────────────────────────────

--- Append `lines` (list of strings) to the output buffer, then scroll to bottom.
--- @param lines string[]
local function append_lines(lines)
  local buf = M.get_or_create_buf()
  vim.bo[buf].modifiable = true

  -- Remove the trailing empty line nvim inserts for new buffers before first append.
  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #current == 1 and current[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  end

  vim.bo[buf].modifiable = false

  -- Scroll the output window to the bottom if it's open.
  if win_valid(_win) then
    local line_count = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(_win, { line_count, 0 })
  end
end

--- Format a result value into a list of display lines.
--- Handles strings (char vectors) and tables (general lists of strings).
--- @param result any  Decoded q value.
--- @return string[]
local function format_result(result)
  if type(result) == "string" then
    -- Split on newlines; remove trailing empty entry from trailing \n.
    local lines = vim.split(result, "\n", { plain = true })
    if #lines > 0 and lines[#lines] == "" then
      lines[#lines] = nil
    end
    return lines
  elseif type(result) == "table" then
    local out = {}
    for _, item in ipairs(result) do
      if type(item) == "string" then
        local sub = vim.split(item, "\n", { plain = true })
        for _, l in ipairs(sub) do
          table.insert(out, l)
        end
      else
        table.insert(out, tostring(item))
      end
    end
    return out
  elseif result == nil then
    return { "(nil)" }
  else
    return { tostring(result) }
  end
end

--- Show a query result in the output panel (result content only).
--- @param result any  Decoded q value (string, table, number, …).
function M.show(result)
  -- Ensure the output window is open.
  M.get_or_create_win()

  local cfg = require("nvim-q.config").get()
  local do_append = (cfg.output and cfg.output.append ~= false)

  local buf = M.get_or_create_buf()
  vim.bo[buf].modifiable = true

  if not do_append then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  end

  append_lines(format_result(result))
end

--- Echo the query status (connection + elapsed time) to the message line.
--- @param status string  e.g. "local (localhost:5000)  2ms"
function M.status(status)
  if not status or status == "" then
    return
  end
  vim.api.nvim_echo({ { "-- " .. status, "Comment" } }, false, {})
end

--- Clear all content from the output buffer.
function M.clear()
  local buf = M.get_or_create_buf()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modifiable = false
end

--- Show the output window (create split if not open).
function M.open()
  M.get_or_create_win()
end

--- Hide the output window without destroying the buffer.
function M.close()
  if win_valid(_win) then
    vim.api.nvim_win_close(_win, false)
    _win = nil
  end
end

--- Toggle the output window open/closed.
function M.toggle()
  if win_valid(_win) then
    M.close()
  else
    M.open()
  end
end

return M
