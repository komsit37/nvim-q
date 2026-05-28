# nvim-q

A pure-Lua Neovim plugin for talking to [kdb+/q](https://kx.com) servers.
Send q expressions from the editor, see results in a dedicated output panel.
Inspired by [sublime-q](https://github.com/komsit37/sublime-q).

> **v0.1 scope** — text-in / text-out workflow using `.Q.s` for formatting.
> Full typed deserialization, inline output, charts, and completions are deferred to v0.2+.
> See [PLAN.md](./PLAN.md) for the backlog.

---

## Requirements

- Neovim >= 0.9 (provides `vim.uv` and LuaJIT)
- A running kdb+/q server

---

## Installation

### Local development (lazy.nvim `dir` spec — recommended while iterating)

```lua
-- ~/.config/nvim/lua/plugins/nvim-q.lua
return {
  {
    dir = "/path/to/nvim-q",
    name = "nvim-q",
    ft = "q",                    -- load lazily on q files; use lazy=false to always load
    opts = {
      connections = {
        { name = "local", host = "localhost", port = 5000 },
      },
    },
  },
}
```

### Published (komsit37/nvim-q)

```lua
{
  "komsit37/nvim-q",
  ft = "q",
  opts = {
    connections = {
      { name = "local",  host = "localhost", port = 5000 },
      { name = "remote", host = "kdb-server", port = 5010, user = "me", password = "secret" },
    },
    keymaps = true,      -- set false to bind your own keys
    timeout = 5000,      -- query / connect timeout in ms
    output = {
      height   = 15,         -- output split height
      position = "botright", -- split direction
      append   = true,       -- true = REPL scrollback; false = replace on each query
    },
  },
}
```

---

## Setup

```lua
require("nvim-q").setup({
  connections = {
    { name = "local", host = "localhost", port = 5000 },
    -- Additional connections:
    -- { name = "prod", host = "prod-kdb", port = 5000, user = "trader", password = "pw" },
  },
})
```

---

## Commands and keymaps

| Command | Default key | Description |
|---|---|---|
| `:QConnect` | `<leader>kc` | Pick / switch connection (`vim.ui.select`) |
| `:QSend` | `<leader>ks` (normal line / visual selection) | Send current line or visual selection |
| — | `<leader>kS` | Clear the output panel, then send line / selection |
| `:QOutputToggle` | `<leader>ko` | Show / hide the output panel |
| `:QOutputClear` | — | Clear all content from the output panel |

Set `keymaps = false` in `opts` to skip the defaults and bind your own.

---

## Behaviour notes

- Queries are wrapped in `.Q.s` automatically so q formats the result as text.
- Lines starting with `\` (e.g. `\l file.q`, `\t expr`) are sent raw — `.Q.s` is not applied.
- The output panel is a `nofile` scratch buffer (`filetype=q_output`) appended to by default (REPL scrollback). Use `:QOutputClear` to reset.
- Per-buffer active connection: `:QConnect` in buffer A does not affect buffer B. Falls back to the last-selected connection globally, then to the first configured connection.
- Connection refused / bad port → clean `vim.notify` ERROR — no Lua stack trace.

---

## Filetype and syntax

`*.q` files get `filetype=q` automatically (via `ftdetect/q.lua`). A minimal syntax file (`syntax/q.vim`) highlights keywords, comments, strings, symbols, and numbers.

For richer syntax highlighting see [katusk/vim-qkdb-syntax](https://github.com/katusk/vim-qkdb-syntax).

---

## Health check

```
:checkhealth nvim-q
```

Reports Neovim version, `vim.uv` / LuaJIT availability, configured connections, and a live ping of each.

---

## Architecture and development

See [PLAN.md](./PLAN.md) and [ARCHITECTURE.md](./ARCHITECTURE.md).

```
make test       # run the full plenary test suite
make spike      # quick real-q roundtrip (port 5000)
make fixtures   # re-capture test fixtures from real q
```
