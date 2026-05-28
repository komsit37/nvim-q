# nvim-q — Plan

A Neovim port of [sublime-q](https://github.com/komsit37/sublime-q): connect to remote q/kdb+ sessions, send q statements from the editor, show results.

## Approach

- **Pure Lua**, no external runtime. No Python, no compiled C client.
- **Networking**: `vim.uv` (libuv, bundled with Neovim) for async TCP. No FFI sockets needed.
- **Binary decode**: LuaJIT `ffi.cast` to typed pointers for reading int32/int64/double from the kdb wire format. (Neovim ships LuaJIT, so `bit` + `ffi` are available; `string.unpack` is NOT — that's Lua 5.3.)
- **Distribution**: `git clone` / lazy.nvim with zero build step. That is the whole point of going pure Lua.

### Key simplification: lean on `.Q.s`

sublime-q wraps every query in `.Q.s` so q itself formats the result into a char vector. We do the same. **This means the v0.1 deserializer only has to handle a handful of types**, not the full kdb type system:

- `10`  char vector  → Lua string (the main one)
- `0`   general list → list of char vectors (multi-line / nested output)
- `-11` symbol atom  → string (status strings)
- `-7`  long atom    → number (memory `.Q.w`)
- `-128` error       → raise Lua error with message

Everything else (typed vectors, dicts, tables, temporals, GUIDs, compression on read) is deferred. The query path stays text-in / text-out. Full typed decode is a v0.2+ concern, only needed when we stop round-tripping through `.Q.s`.

### Writer is trivial

To send a query we serialize **one char vector** inside a sync message header (8-byte msg header + type byte + length + bytes). No need to serialize dicts/tables/atoms for v0.1.

## v0.1 scope (first cut)

IN:
- Pure-Lua IPC: handshake (capability byte), sync send, response decode (limited types above).
- Connection config via `setup({ connections = {...} })`; `:QConnect` picker using `vim.ui.select`. Per-buffer active connection.
- `:QSend` — send current line (normal mode) or visual selection (`'<,'>`).
- Output panel: a dedicated scratch split buffer (`filetype=q_output`), appended/replaced per query.
- Minimal status: result line via `vim.notify` or buffer-local statusline (status string + elapsed time).
- Filetype detection `*.q` → `q` (ship a minimal syntax file or reuse katusk/vim-qkdb-syntax; syntax is optional for v0.1).
- Default keymap (opt-in): `<CR>` in visual / `<leader>q` send line, mirroring `super+enter`.

OUT (deferred — see Backlog):
- Inline **popup** and **phantom** output (explicitly cut by request).
- **Browse table** (`.h.jx`, was shift+F2) — depended on phantom.
- **Charts** (F4 / shift+F4) — HTML/JS templates + browser launch.
- **JSON output** (`.j.j`, was cmd+j).
- **Custom routines** engine (whole subsystem; powerful, but v0.2).
- **Goto documentation** (F1) — separate web feature.
- **Autocomplete / completions** (`q_update_completions`).
- **HDB toggle** (port+1 convenience).
- Detailed status: memory delta + result dims (`.Q.w` diff, cols×rows). Keep only elapsed time in v0.1.
- Full typed deserialization, read-side decompression, async subscriptions, Windows support.

## Architecture

```
nvim-q/
├── PLAN.md
├── README.md
├── lua/nvim-q/
│   ├── init.lua        -- setup(), user commands, default keymaps
│   ├── config.lua      -- defaults + user opts merge
│   ├── connection.lua  -- QCon: host/port/user/pass, picker, per-buf active con
│   ├── ipc/
│   │   ├── client.lua  -- vim.uv TCP: connect, handshake, send, recv framing
│   │   ├── decode.lua  -- wire bytes -> Lua value (limited type set)
│   │   └── encode.lua  -- query string -> sync message bytes
│   ├── send.lua        -- gather line/selection, wrap in .Q.s, dispatch
│   └── output.lua      -- output panel buffer/window management
└── syntax/q.vim        -- optional, or depend on existing syntax plugin
```

### IPC protocol notes (the part to get right)

1. **Handshake**: after TCP connect, send `username:password\x03\x00` (the `\x03` = capability/protocol byte: supports compression + timestamp/timespan). Server replies with a single byte = its capability level. (No creds: send `\x03\x00`.)
2. **Message header** (8 bytes): `endian(1)` `msgtype(1: 0=async,1=sync,2=response)` `compressed(1)` `pad(1)` `total_len(4, little-endian on x86)`.
3. **Send query**: header(sync) + `0x0A`(char vector type) + `0x00`(attr) + `len(4)` + bytes.
4. **Read response**: read 8-byte header, get `total_len`, read remainder. If `compressed==1`, decompress (defer — but at least detect and error clearly; `.Q.s` text results are usually small/uncompressed for the sync path, but large ones CAN compress — note this risk).
5. **Decode** the payload per the limited type table.
6. **Endianness**: header byte 0 says big/little. On Linux/macOS x86/arm we emit little-endian and assume server matches; read the server's flag and `ffi.cast` accordingly.

**Risk to validate early**: compression on the read path. kdb compresses responses above a size threshold when client+server are on different hosts. If we hit it before implementing decompress, results silently break. Action: implement decompress in Phase 2, or cap via querying small results first and add a clear "compressed response not yet supported" error in Phase 1.

## Phases

**Phase 1 — protocol spike (de-risk first).**
Standalone Lua script (run via `nvim -l` or busted): connect to a local `q -p 5000`, handshake, send `.Q.s til 10`, decode the char-vector response, print it. No editor integration. Proves the wire format end to end. Reference: `michaelwittig/node-q` serializer/deserializer.

**Phase 2 — decode breadth + decompress.**
Handle general list (type 0) of char vectors, symbol/long atoms, error (-128). Implement read decompression. Unit-test against fixtures captured from a real q session.

**Phase 3 — editor integration.**
`setup()`, `connection.lua` + `:QConnect` picker, `send.lua` (line + visual), `output.lua` panel, `:QSend`, default keymaps. Wire status string + elapsed time.

**Phase 4 — polish.**
Filetype/syntax, README, error UX (connection refused, bad port), config docs, basic `:checkhealth`.

## Open questions

1. **Connection model**: per-buffer active connection (like sublime) vs. global? → Lean per-buffer, fallback to global default.
2. **Output panel UX**: append (REPL log, scrollback) vs. replace (latest only)? → Default append with a `clear` command; revisit.
3. **Decompression**: implement in Phase 2 or risk-accept for v0.1 local-only use? → Decide after Phase 1 spike shows how often it triggers.
4. **Syntax**: vendor a minimal `syntax/q.vim` or document depending on an existing plugin? → Document dependency for v0.1, vendor later.

## Backlog (post-v0.1, roughly in value order)

1. Custom routines (`{0}` word-under-cursor templating, named routines, keymaps) — high value, ~self-contained.
2. JSON output via `.j.j`.
3. Charts → write HTML to tmp, `vim.ui.open`.
4. Browse table `.h.jx` → render in a float with `]`/`[` paging keymaps.
5. Detailed status (mem delta, dims).
6. Inline output via extmark `virt_lines` (phantom analog) and floating window (popup analog).
7. Goto documentation (F1).
8. Completions.
9. Full typed deserialization (drop the `.Q.s` round-trip; return native Lua tables for programmatic use).
