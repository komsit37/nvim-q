-- nvim-q/init.lua
-- Plugin entry point.
-- Wires config, registers user commands, and installs default keymaps.

local M = {}

--- Setup the nvim-q plugin.
--- @param opts table  User options (merged over defaults; see config.lua).
function M.setup(opts)
  local config     = require("nvim-q.config")
  local connection = require("nvim-q.connection")
  local send       = require("nvim-q.send")
  local output     = require("nvim-q.output")

  config.setup(opts)

  -- ── User commands ───────────────────────────────────────────────────────

  -- :QConnect — open the connection picker for the current buffer.
  vim.api.nvim_create_user_command("QConnect", function(_opts)
    local bufnr = vim.api.nvim_get_current_buf()
    connection.pick(bufnr, function(chosen)
      if chosen then
        vim.notify(
          string.format("nvim-q: connected to %s (%s:%d)",
            chosen.name or "?",
            chosen.host or "localhost",
            chosen.port or 0),
          vim.log.levels.INFO
        )
      end
    end)
  end, {
    desc  = "nvim-q: pick/switch the active connection",
    nargs = 0,
  })

  -- :QSend — send current line (normal) or visual selection.
  -- Works with visual range: :'<,'>QSend
  vim.api.nvim_create_user_command("QSend", function(opts)
    local bufnr = vim.api.nvim_get_current_buf()
    -- opts.range > 0 means a range was given (visual selection).
    local mode = (opts.range > 0) and "v" or "n"
    send.send(bufnr, mode)
  end, {
    desc  = "nvim-q: send current line or visual selection to q",
    range = true,
  })

  -- :QOutputToggle — show/hide the output panel.
  vim.api.nvim_create_user_command("QOutputToggle", function(_opts)
    output.toggle()
  end, {
    desc  = "nvim-q: toggle the output panel",
    nargs = 0,
  })

  -- :QOutputClear — wipe all content from the output panel.
  vim.api.nvim_create_user_command("QOutputClear", function(_opts)
    output.clear()
  end, {
    desc  = "nvim-q: clear the output panel",
    nargs = 0,
  })

  -- ── Default keymaps ─────────────────────────────────────────────────────

  local cfg = config.get()
  if cfg.keymaps ~= false then
    -- <leader>qc — QConnect
    vim.keymap.set("n", "<leader>qc", "<cmd>QConnect<CR>", {
      desc    = "nvim-q: pick connection",
      silent  = true,
    })

    -- <leader>q — send current line (normal mode)
    vim.keymap.set("n", "<leader>q", function()
      local bufnr = vim.api.nvim_get_current_buf()
      send.send(bufnr, "n")
    end, {
      desc   = "nvim-q: send current line",
      silent = true,
    })

    -- <CR> (visual mode) — send visual selection
    vim.keymap.set("v", "<CR>", function()
      -- Leave visual mode first so '< and '> marks are set.
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
        "x", false
      )
      local bufnr = vim.api.nvim_get_current_buf()
      send.send(bufnr, "v")
    end, {
      desc   = "nvim-q: send visual selection",
      silent = true,
    })

    -- <leader>qo — toggle output panel
    vim.keymap.set("n", "<leader>qo", "<cmd>QOutputToggle<CR>", {
      desc   = "nvim-q: toggle output panel",
      silent = true,
    })
  end
end

return M
