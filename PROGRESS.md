# nvim-q — Implementation Progress

Tracks build progress against [PLAN.md](./PLAN.md) and [ARCHITECTURE.md](./ARCHITECTURE.md).
Update the status and notes for each item as work lands.

Status legend: ⬜ not started · 🟡 in progress · ✅ done · ⏭️ deferred (post-v0.1)

## Phase 1 — protocol spike (de-risk)

| Item | Status | Notes |
|---|---|---|
| `ipc/encode.lua` — query string → sync message bytes | ✅ | Pure Lua + `bit` for LE uint32; no `vim.*`. 8-byte header + char-vector payload. |
| `ipc/decode.lua` — char vector (type 10) → string | ✅ | All types in spec handled: 10, 0, -11, -7, -128. `ffi` not needed (pure Lua byte ops). |
| `ipc/client.lua` — connect, handshake, send, recv framing | ✅ | `vim.uv` TCP; blocking `client:query()` via `vim.wait()`; `connect()`, `ping()`, `close()`. Resolves `localhost`→`127.0.0.1`. |
| Spike: connect to local `q -p 5000`, `.Q.s til 10`, decode | ✅ | Output: `"0 1 2 3 4 5 6 7 8 9\n"`. Error path tested: `1+\`a` → `q error: type`. |
| Compression: detect `compressed==1`, error clearly | ✅ | Decompressor implemented (Phase 2 done); not just detection+error. See Phase 2 row. |

## Phase 2 — decode breadth + decompress

| Item | Status | Notes |
|---|---|---|
| Decode general list (type 0) of char vectors | ✅ | Recursive decoder handles nested types. Tested with `("hello";"world")`. |
| Decode symbol atom (-11), long atom (-7), error (-128) | ✅ | All working. `-128` raises Lua error with `"q error: <msg>"`. |
| Read-path LZ decompression | ✅ | kdb LZ (sliding window, 256-byte aa[] table, ctrl byte LSB-first). Validated with synthetic fixtures incl. full round-trip decode. **localhost never compresses** (kdb+ design); decompressor fires automatically when `compressed==1` in header. |
| Fixtures captured from real q + decode unit tests | ✅ | `til3.bin`, `error_type.bin`, `sym_atom.bin`, `long_atom.bin`, `general_list.bin`, `large_til.bin`. All used in `decode_spec.lua`. |

## Phase 3 — editor integration

| Item | Status | Notes |
|---|---|---|
| `config.lua` — defaults + user opts merge | ✅ | Deep-merge over defaults; `M.setup(opts)` / `M.get()`. Defaults: connections=[], keymaps=true, timeout=5000, output={height=15, position="botright", append=true}. |
| `connection.lua` — QCon model, picker, per-buffer active | ✅ | `ensure_client()` lazily connects + caches by "host:port[:user]"; `get_active(bufnr)` falls back global→first configured; `drop_client()` on error. |
| `:QConnect` picker (`vim.ui.select`) | ✅ | `connection.pick(bufnr, callback)` over configured connections; marks active connection; sets per-buffer + global default. |
| `send.lua` — line + visual selection, wrap `.Q.s`, dispatch | ✅ | `collect()` handles normal + char-wise/line-wise visual; `wrap()` skips `.Q.s` for `\`-prefixed system commands; error surfaced via `vim.notify(ERROR)` + output panel. |
| `output.lua` — scratch output panel buffer/window | ✅ | `buftype=nofile, filetype=q_output, unlisted`; `show(result,status)` appends separator+status+content; `clear()`, `toggle()`, `open()`, `close()`. |
| `:QSend` command | ✅ | `range=true` — works from normal mode and `'<,'>` visual range. |
| `init.lua` — setup(), commands, default keymaps | ✅ | Wires all modules; commands: `:QConnect`, `:QSend`, `:QOutputToggle`, `:QOutputClear`; keymaps: `<leader>qc`, `<leader>q`, `<CR>` (visual), `<leader>qo`. |
| Status: status string + elapsed time | ✅ | Status line = `"name (host:port)  Nms"` shown as comment line in output panel above result. |

## Phase 4 — polish

| Item | Status | Notes |
|---|---|---|
| Filetype detection `*.q` → `q` | ✅ | `ftdetect/q.lua` using `vim.filetype.add()`; also maps `*.k` → `k`. |
| `syntax/q.vim` or documented dependency | ✅ | Minimal `syntax/q.vim` vendored: keywords, comments, strings, symbols, numbers, booleans, system commands, operators. |
| Error UX (connection refused, bad port) | ✅ | ECONNREFUSED → clean `vim.notify(ERROR, "cannot connect to host:port — ECONNREFUSED")`; no Lua stack traceback. `drop_client()` so next attempt reconnects. |
| README + config docs | ✅ | `README.md`: install (dir + published specs), setup example, commands/keymaps table, behaviour notes, v0.1 scope note. |
| `:checkhealth` support | ✅ | `lua/nvim-q/health.lua`: reports nvim version, vim.uv, LuaJIT/bit, configured connections, live ping of each. |

## Test infrastructure

| Item | Status | Notes |
|---|---|---|
| `test/minimal_init.lua` | ✅ | Sets rtp to plenary + repo only; loads `plugin/plenary.vim`. |
| `test/decode_spec.lua` (pure) | ✅ | 20 tests, all pass. Covers types 10/0/-11/-7/-128 + compressed + helpers. |
| `test/encode_spec.lua` (pure) | ✅ | 14 tests, all pass. Every header/payload field verified. |
| `test/mock_server.lua` + client IO test | ✅ | `vim.uv` TCP server; helper builders `char_vector_msg()`, `error_msg()`. 4 client framing tests. |
| `test/integration_spec.lua` (real q, skip if absent) | ✅ | 12 tests (4 mock + 8 real-q). Guarded: skips if q unreachable. Tested against port 5000. |
| `Makefile` (`test`, `spike`) | ✅ | `make test`, `make spike`, `make test-encode/decode/integration`, `make fixtures`. |

**Total: 46/46 tests passing** (Phase 1/2 protocol tests; Phase 3/4 validated via headless nvim `test/validate_editor.lua`).

## Decisions / open questions resolved

| Question | Decision |
|---|---|
| Does kdb+ compress localhost connections? | **No.** kdb+ never compresses loopback (127.0.0.1) connections regardless of payload size or `.z.C` setting. Confirmed experimentally: 500k char vector = 0 compressed. Decompressor is implemented and fires on `compressed==1` from remote servers. |
| `ffi` or pure Lua for byte reads? | Pure Lua byte ops (`string.byte`, `bit.band/rshift`) suffice — no `ffi.cast` needed for the supported type set. `ffi` was kept available but not required. |
| `localhost` hostname in `vim.uv.tcp_connect`? | `vim.uv` requires an IP string; resolved by mapping `"localhost"` → `"127.0.0.1"` in `client.connect()`. |
| Plenary headless runner: need `runtime plugin/plenary.vim`? | **Yes.** Must pass `--cmd "runtime plugin/plenary.vim"` before `-c "PlenaryBustedDirectory..."` in headless mode. Baked into Makefile. |
| Output default: append or replace? | **Append** (REPL scrollback). Each result adds a `─` separator + status comment line + content. `:QOutputClear` wipes. Can flip via `output.append=false` in config. |
| `\`-prefix handling? | Lines starting with `\` (system commands like `\l`, `\t`) are sent **raw** without `.Q.s ` wrapping. Leading whitespace before `\` is trimmed. |
| Connection cache key? | `"host:port[:user]"` — allows different users on the same host:port to have separate clients. |
| Per-buffer storage format? | Connection **name** string stored in `vim.b[bufnr].nvimq_connection`; the live client object stays in a module-level `_clients` table (not serialisable into vim.b). |
