" syntax/q.vim — minimal q/kdb+ syntax highlighting
" Covers: keywords, comments, strings, symbols, numbers.
" Full q syntax is out of scope for v0.1; this is a starter set.

if exists("b:current_syntax") | finish | endif
let b:current_syntax = "q"

" ── Comments ───────────────────────────────────────────────────────────────
" Line comment: / to end of line (when not inside a string or symbol)
syn match qComment /\/.*$/ contains=@Spell
" Block comment: a / on a line by itself starts a block, \ ends it.
" (simplified — we match single-line form only for safety)
hi def link qComment Comment

" ── Strings ────────────────────────────────────────────────────────────────
" Double-quoted char vectors: "..."
syn region qString start=/"/ skip=/\\./ end=/"/ contains=@Spell
hi def link qString String

" ── Symbols ────────────────────────────────────────────────────────────────
" Backtick symbols: `sym  `sym.nested  ` (empty symbol)
syn match qSymbol /`[a-zA-Z_.][a-zA-Z0-9_.:]*/
syn match qSymbol /`/
hi def link qSymbol Special

" ── Numbers ────────────────────────────────────────────────────────────────
" Integers, floats, longs (42j), shorts (42h), bytes (42i).
syn match qNumber /\<[0-9]\+[ijhefb]\?\>/
syn match qNumber /\<[0-9]\+\.[0-9]*\>/
syn match qNumber /\<0[Nn]\>/   " 0N  0n  nulls
syn match qNumber /\<0[Ww]\>/   " 0W  0w  infinities
hi def link qNumber Number

" ── Booleans ───────────────────────────────────────────────────────────────
syn match qBool /\<[01]b\>/
hi def link qBool Boolean

" ── Keywords ───────────────────────────────────────────────────────────────
" Built-in verbs and system words frequently used interactively.
syn keyword qKeyword
  \ abs acos and asin atan avg avgs bin binr
  \ ceiling cols cor cos count cross cut
  \ delete desc dev differ distinct div do
  \ each ej enlist eval except exec exit exp
  \ fby fills first flip floor from
  \ get group gsort
  \ hclose hcount hdel hopen hsym
  \ iasc idesc if in insert inter
  \ inv
  \ key keys
  \ last like load log lsq ltime ltrim
  \ mavg max maxs md5 med meta min mins mmax mmin mmu mod
  \ neg next not null
  \ or over
  \ parse pj prev prior prd prds
  \ rand rank raze read0 read1 reciprocal reval reverse
  \ rload rotate rsave rtrim
  \ save scan select set show signum sin sqrt ss ssr string sublist sum sums
  \ sv system
  \ tables tan tilll type
  \ uj union ungroup update upsert
  \ value var view views
  \ where within wj wj1 wsum wtavg
  \ xasc xbar xcol xcols xdesc xexp xgroup xkey xlog xprev xrank
hi def link qKeyword Keyword

" ── System commands ─────────────────────────────────────────────────────────
" Lines starting with \ followed by a letter are system commands.
syn match qSysCmd /^\\\w\+/
hi def link qSysCmd PreProc

" ── Operators ──────────────────────────────────────────────────────────────
" Basic operator characters (informational, not exhaustive).
syn match qOperator /[+\-*%!&#|<>~^@?$,.:]/
hi def link qOperator Operator

" ── q_output filetype (no extra highlighting needed — just inherit Normal) ──
" The q_output filetype is a plain scratch buffer; no syntax defined here.
