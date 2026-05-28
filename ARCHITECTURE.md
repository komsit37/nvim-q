# nvim-q — Architecture & Development

Companion to [PLAN.md](./PLAN.md) (which covers scope and phases). This doc covers how the
pieces fit together, how a keypress turns into output, how to wire it into a Neovim config,
and how to test each layer.

---

## 1. Design principles

1. **Pure Lua, zero build step.** Runs on `git clone` / lazy.nvim. No Python, no compiled
   C client, no platform binaries.
2. **Networking via `vim.uv`** (libuv, bundled with Neovim). No FFI sockets.
3. **Binary decode via LuaJIT `ffi.cast`** for reading int32/int64/double from the wire.
   (`bit` + `ffi` are available; `string.unpack` is Lua 5.3 — NOT available under LuaJIT.)
4. **Isolate IO from logic.** Encode/decode are pure functions over byte strings with no
   `vim.*` dependency. Only `client.lua` touches the socket. This is what makes the protocol
   unit-testable offline and the design easy to reason about.
5. **Lean on `.Q.s`.** Queries are wrapped so q formats results into a char vector. The v0.1
   decoder therefore handles only a handful of types, not the full kdb type system.

---

## 2. Module layout

```
nvim-q/
├── PLAN.md
├── ARCHITECTURE.md          -- this file
├── README.md
├── lua/nvim-q/
│   ├── init.lua             -- setup(), :commands, default keymaps
│   ├── config.lua           -- defaults + user-opts merge
│   ├── connection.lua       -- QCon model, picker, per-buffer active connection
│   ├── ipc/
│   │   ├── client.lua       -- vim.uv TCP: connect, handshake, send, recv framing (ONLY IO)
│   │   ├── decode.lua       -- bytes -> Lua value          (PURE, ffi ok, no vim.*)
│   │   └── encode.lua       -- query string -> sync bytes  (PURE, ffi ok, no vim.*)
│   ├── send.lua             -- gather line/selection, wrap in .Q.s, dispatch
│   └── output.lua           -- output panel buffer/window
├── syntax/q.vim             -- optional (or depend on an existing syntax plugin)
└── test/
    ├── minimal_init.lua     -- runtimepath: plenary + this repo
    ├── fixtures/*.bin       -- captured wire bytes
    ├── decode_spec.lua      -- pure
    ├── encode_spec.lua      -- pure
    ├── mock_server.lua      -- canned-bytes TCP server (no q needed)
    └── integration_spec.lua -- real q, skipped if q absent
```

### Module responsibilities

| Module | Responsibility | Depends on | Pure? |
|---|---|---|---|
| `config` | merge user opts over defaults | — | yes |
| `connection` | model a connection, pick/switch, store active per-buffer | `vim.b`, `vim.ui` | no |
| `ipc/encode` | query string → sync message bytes | `ffi` | **yes** |
| `ipc/decode` | response bytes → Lua value | `ffi` | **yes** |
| `ipc/client` | TCP connect, handshake, send/recv framing | `vim.uv`, encode, decode | no |
| `send` | read line/selection, wrap `.Q.s`, call client, route to output | `vim.api`, client, output | no |
| `output` | manage the scratch output buffer/window | `vim.api` | no |
| `init` | `setup()`, user commands, keymaps | all | no |

---

## 3. Data flow (wiring)

A send, end to end:

```
keymap / :QSend
      │
      ▼
send.collect()           -- normal: current line; visual: '<,'> selection
      │  raw q text
      ▼
send.wrap()              -- prefix ".Q.s " (and handle leading "\" like sublime-q)
      │  ".Q.s (til 10)"
      ▼
connection.active(buf)   -- per-buffer QCon; if none, run :QConnect picker first
      │
      ▼
client:query(text)       -- async over vim.uv; sync wrapper blocks via vim.wait()
   ├─ encode(text)       -- build sync message bytes
   ├─ uv.write(sock,…)
   ├─ uv.read_start …    -- accumulate until full message per header length
   └─ decode(payload)    -- bytes -> Lua string (or error)
      │  "0\n1\n2\n…"  +  status (elapsed time)
      ▼
output.show(result, status)   -- append/replace in scratch buffer; set status line
```

Error paths (connection refused, q error `'sym`, bad port) surface as a Lua error from
`client:query`, caught in `send` and shown via `vim.notify` + the output panel.

### Sync wrapper over async IO

`vim.uv` is callback-based. v0.1 exposes a **blocking** `client:query()` that drives the
event loop until the response arrives:

```lua
function Client:query(text)
  local done, result, err = false, nil, nil
  self:query_async(text, function(res, e) done, result, err = true, res, e end)
  if not vim.wait(self.timeout or 5000, function() return done end) then
    error("nvim-q: query timed out")
  end
  if err then error(err) end
  return result
end
```

Simple, and it makes tests straightforward. An async/coroutine API can come later for
streaming or subscriptions.

---

## 4. IPC protocol (what `ipc/` implements)

Reference implementations to cross-check the wire format: `michaelwittig/node-q` (JS),
`sv/kdbgo` (Go), `diamondrod/kdbplus` (Rust).

1. **Handshake** — after TCP connect, send `username:password` + `\x03` (capability byte:
   compression + timestamp/timespan) + `\x00`. No creds → send `"\x03\x00"`. Server replies
   with **one byte** = negotiated capability level.
2. **Message header** (8 bytes): `endian(1)` `msgtype(1: 0=async,1=sync,2=response)`
   `compressed(1)` `pad(1)` `total_len(uint32)`. On x86/arm little-endian; read the server's
   endian byte and `ffi.cast` accordingly.
3. **Encode (send query)** — header(sync) + `0x0A` (char-vector type) + `0x00` (attr) +
   `len(uint32)` + raw bytes. The only thing v0.1 serializes is a char vector.
4. **Decode (read response)** — read 8-byte header → `total_len` → read remainder. Then
   decode payload by leading type byte:

   | type | meaning | → Lua |
   |---|---|---|
   | `10` | char vector | string |
   | `0`  | general list | list of char vectors (multi-line/nested) |
   | `-11`| symbol atom | string (status) |
   | `-7` | long atom | number (`.Q.w` memory) |
   | `-128`| error | raise Lua error with message |

   Everything else is deferred (typed vectors, dicts, tables, temporals, GUIDs). Because we
   round-trip through `.Q.s`, the result is almost always type `10` or `0`.

5. **Compression** ⚠️ — kdb compresses responses above a size threshold when client and
   server are on different hosts. If `compressed==1` and we haven't implemented the
   decompressor, results silently corrupt. **Action:** Phase 1 spike checks how often this
   fires for local use; Phase 2 implements LZ decompress. Until then, detect `compressed==1`
   and raise a clear "compressed response not yet supported" error rather than mis-decoding.

---

## 5. Neovim config integration (lazy.nvim / LazyVim)

The repo exposes `lua/nvim-q/init.lua` with `setup(opts)`.

### Local development — `dir` spec (recommended)

`~/.config/nvim/lua/plugins/nvim-q.lua`:

```lua
return {
  {
    dir = "/home/pkomsit/work/lab/nvim-q",
    name = "nvim-q",
    ft = "q",                      -- load on q files; drop + use lazy=false while iterating
    opts = {
      connections = {
        { name = "local", host = "localhost", port = 5000 },
      },
      keymaps = true,              -- install default <leader>k* maps
    },
    -- config = function(_, o) require("nvim-q").setup(o) end,  -- if opts default not used
  },
}
```

lazy.nvim reads straight from the local path — no symlink. Edits apply on next start or
`:Lazy reload nvim-q`.

### Alternative — `dev` mode (several local plugins under one root)

In `lua/config/lazy.lua`:

```lua
require("lazy").setup({ dev = { path = "/home/pkomsit/work/lab" }, ... })
```

Then any spec: `{ "komsit37/nvim-q", dev = true, ft = "q", opts = {...} }`. Flip `dev` to
switch between local copy and the published GitHub version.

### Published install (for users, later)

```lua
{ "komsit37/nvim-q", ft = "q", opts = { connections = { … } } }
```

### Default keymaps & commands (planned)

| Command | Default key | Action |
|---|---|---|
| `:QConnect` | `<leader>kc` | pick/switch connection (`vim.ui.select`) |
| `:QSend` | `<leader>ks` (line / visual selection) | send selection/line, show in output panel |
| — | `<leader>kS` | clear output panel, then send |
| `:QOutputToggle` | `<leader>ko` | show/hide output panel |

`keymaps = false` in opts disables defaults so users can bind their own.

---

## 6. Testing

Three layers. Layer 1 catches ~90% of protocol bugs offline; Layer 3 is the end-to-end net.
You have `q` at `/home/pkomsit/q/l64/q` and `plenary.nvim` installed.

> You do **not** need the Neovim editor for pure tests — you need a LuaJIT interpreter.
> `nvim -l` is just the LuaJIT you already have; it runs a bare script (no config/plugins/UI,
> few-ms startup) and also exposes `vim.uv`/`ffi`, so the same runner covers every layer.
> A standalone `luajit`+`busted` toolchain also works for Layer 1 **only if** the code under
> test stays free of `vim.*` — which `encode`/`decode` are, by design.

### Layer 1 — pure encode/decode (no q, no socket)

Fastest inner loop with `nvim -l`:

```bash
cd /home/pkomsit/work/lab/nvim-q
nvim -l test/decode_spec.lua
```

```lua
-- test/decode_spec.lua  (bare-script form)
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local decode = require("nvim-q.ipc.decode")
local bytes  = assert(io.open("test/fixtures/til3.bin", "rb")):read("*a")
assert(decode(bytes) == "0\n1\n2\n", "decode mismatch")
print("ok")
```

Or busted-style via plenary (assertions, grouping):

```lua
describe("decode", function()
  it("char vector", function()
    assert.equals("0\n1\n2\n", require("nvim-q.ipc.decode")(read_fixture("til3.bin")))
  end)
end)
```

**Fixtures:** capture raw response bytes once from real q (a throwaway script using
`client.lua`), dump to `test/fixtures/*.bin`, commit them. Decode tests then run fully
offline and deterministic.

### Layer 2 — client IO against a mock q server (no license, CI-safe)

A ~30-line `vim.uv` TCP server that performs the handshake byte then replays canned response
bytes. Exercises `client.lua` framing/handshake/recv-loop without needing q — ideal for CI
where q may be absent.

### Layer 3 — real-q roundtrip (local; skip if q absent)

```lua
-- test/integration_spec.lua
local Q = "/home/pkomsit/q/l64/q"
describe("roundtrip", function()
  local port, job
  before_each(function()
    port = 5000 + math.random(0, 999)
    job  = vim.fn.jobstart({ Q, "-p", tostring(port) })
    vim.wait(1000, function()
      return pcall(function() require("nvim-q.ipc.client").ping("localhost", port) end)
    end)
  end)
  after_each(function() vim.fn.jobstop(job) end)

  it("evaluates til 3", function()
    local c = require("nvim-q.ipc.client").connect("localhost", port)
    assert.equals("0\n1\n2\n", c:query(".Q.s til 3"))
    c:close()
  end)
end)
```

Guard with `if vim.fn.executable("q") == 0 then return end` so the suite passes on machines
without a kdb license.

### Runner

```make
# Makefile
test:             # all specs inside nvim (vim.uv/ffi available)
	nvim --headless -c "PlenaryBustedDirectory test/ {minimal_init='test/minimal_init.lua', pattern='_spec'}" -c qa

spike:            # quickest single-file run during dev
	nvim -l test/decode_spec.lua
```

`test/minimal_init.lua` sets `runtimepath` to include plenary and this repo, and nothing
else — keeps tests isolated from the user's full config.

---

## 7. Dev loop

1. `q -p 5000` in a terminal (test server).
2. Open a `.q` file in Neovim with the `dir` spec loaded.
3. Edit Lua → `:Lazy reload nvim-q` (or restart; Lua caches modules, so restart is the
   reliable reset). Run `:QSend`.
4. Errors: `:messages`, `:Lazy log`. `vim.notify` output also lands in `:messages`.
5. Iterate protocol changes against `make spike` / `make test` without touching the editor.
