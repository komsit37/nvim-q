-- test/minimal_init.lua
-- Minimal Neovim runtime for plenary test runs.
-- Sets runtimepath to include only plenary.nvim and this repo.
-- Usage:
--   nvim --headless -c "PlenaryBustedDirectory test/ {minimal_init='test/minimal_init.lua', pattern='_spec'}" -c qa

local plenary_path = vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")
local repo_path    = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

-- Reset runtimepath to bare minimum then add plenary + this repo
vim.opt.runtimepath = {
  vim.env.VIMRUNTIME,
  plenary_path,
  repo_path,
}

-- Load plenary's test busted integration
vim.cmd("runtime plugin/plenary.vim")
