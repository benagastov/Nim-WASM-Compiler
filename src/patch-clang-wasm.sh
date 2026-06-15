#!/bin/bash
# =============================================================================
# patch-clang-wasm.sh  --  apply the v34 in-browser Nim->wasm pipeline fix
# =============================================================================
#
# CORRECTED ROOT CAUSE (supersedes the old v33c heap theory)
# ----------------------------------------------------------
# The "RuntimeError: unreachable" that aborted the pipeline was NOT an
# out-of-memory condition in dlmalloc, and NOT an lld assertion. It is a bug
# in LLVM 8.0.1's WebAssembly object writer (MC layer / WasmObjectWriter):
# it hits llvm_unreachable when serializing a `common`-linkage global.
#
# C file-scope tentative definitions (e.g. `int x;` with no initializer) are
# emitted by clang 8 as `common`-linkage globals, because clang < 11 defaults
# to -fcommon. Nim's generated C (system.nim.c and friends) contains several
# such tentative definitions (threadId, allocator, roots, ...). Compiling any
# of them with `clang -cc1 -emit-obj` therefore traps in the object writer.
#
# This was isolated by delta-debugging the LLVM IR down to a single line:
#     @threadId__system_u2938 = common hidden global i32 0
# which reproduces the exact same trap (wasm-function[17226]) as the full
# program. `-fsyntax-only`, `-emit-llvm`, and `-S` all succeed; only
# `-emit-obj` traps -- confirming the writer, not codegen, is at fault.
#
# THE FIX (three parts)
# ---------------------
# 1. Compile with -fno-common.  This makes clang's C frontend emit tentative
#    definitions as ordinary .bss definitions instead of `common` linkage,
#    side-stepping the writer bug. This is the core fix for the trap and is
#    what this script applies (to clang.js, NOT clang.wasm).
#
# 2. A weak raise() stub (added in nim-build.html's HEADER).  wasi-libc
#    *declares* raise() in <signal.h> but does not implement it (WASI has no
#    signals); Nim's system module calls raise() in its signal path. A weak
#    no-op definition resolves the link without duplicate-symbol errors.
#
# 3. A 2-arg main rewrite (added in nim-build.html's C-source cleaner).
#    wasi crt1.o calls main with signature (i32,i32)->i32, i.e. main(argc,argv).
#    Nim emits a 3-arg main(argc,args,env); the mismatch produces an INVALID
#    wasm module. The cleaner rewrites it to the 2-arg form and declares env
#    as a NULL local.
#
# Parts 2 and 3 live in templates/nim-build.html and site/nim-build.html.
# Part 1 (this script) edits clang.js, because the actual clang `-cc1`
# invocation is built inside the base64-embedded web worker in clang.js.
#
# NOTE: clang.wasm is NOT modified. The old v33c heap_end patch
# (6206896 -> 256MB) was chasing a non-existent OOM and is OBSOLETE; it had
# no effect on the real bug. clang.wasm is fetched with {cache:"no-store"},
# so it needs no cache-busting; clang.js is cache-busted via ?v=34 in the
# nim-build.html import.
#
# Run:  ./patch-clang-wasm.sh                 # patches the two clang.js copies
#       ./patch-clang-wasm.sh path/to/clang.js [more.js ...]
# Idempotent: re-running detects an already-patched file and does nothing.
# =============================================================================

set -euo pipefail

DEFAULT_TARGETS=(
  "static/clang/clang.js"
  "site/static/clang/clang.js"
)

if [ "$#" -ge 1 ]; then
  TARGETS=("$@")
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

for f in "${TARGETS[@]}"; do
  if [ ! -f "$f" ]; then
    echo "skip: $f not found"
    continue
  fi
  python3 - "$f" <<'PYEOF'
import sys, re, base64

path = sys.argv[1]
with open(path, encoding='utf8') as fh:
    s = fh.read()

# The compile command is built inside the base64-encoded worker blob:
#   var a,G,X,W=(a="<base64>",G=null,...)
m = re.search(r'\(a="([A-Za-z0-9+/=]+)",G=null', s)
if not m:
    print(f"  {path}: could not locate embedded worker blob; nothing patched")
    sys.exit(0)

b64 = m.group(1)
worker = base64.b64decode(b64).decode('utf8')

TARGET = '"-Oz","-o",i,"-x","c"'                 # original compile args
REPL   = '"-Oz","-fno-common","-o",i,"-x","c"'   # with -fno-common

if '"-fno-common"' in worker:
    print(f"  {path}: already patched (-fno-common present); no change")
    sys.exit(0)

n = worker.count(TARGET)
if n != 1:
    print(f"  {path}: expected exactly 1 compile-args site, found {n}; aborting to be safe")
    sys.exit(1)

worker2 = worker.replace(TARGET, REPL)
b64new = base64.b64encode(worker2.encode('utf8')).decode('ascii')
s2 = s.replace('(a="' + b64 + '",G=null', '(a="' + b64new + '",G=null')

with open(path, 'w', encoding='utf8') as fh:
    fh.write(s2)

chk = base64.b64decode(re.search(r'\(a="([A-Za-z0-9+/=]+)",G=null', s2).group(1)).decode('utf8')
ok = ('"-fno-common"' in chk) and (REPL in chk)
print(f"  {path}: -fno-common injected, round-trip {'OK' if ok else 'FAILED'}")
sys.exit(0 if ok else 2)
PYEOF
done

echo "Done. nim-build.html carries the weak raise() stub and the 2-arg main"
echo "rewrite, and imports clang.js as ?v=34 to bust the browser cache."
