# Architecture, Build & Design Notes

This document describes how the in-browser Nim → WebAssembly pipeline is
assembled, how to build and deploy it, and the root-cause analysis behind the
key toolchain patches.

## Contents

- [Pipeline overview](#pipeline-overview)
- [Component reference](#component-reference)
- [Toolchain patches](#toolchain-patches)
- [Building and deploying](#building-and-deploying)
- [Re-applying the clang.js patch](#re-applying-the-clangjs-patch)
- [Verification](#verification)
- [Design history](#design-history)

## Pipeline overview

Everything runs client-side. The browser loads a chain of wasm modules and
drives them in sequence:

```
your .nim code
   │  nim.wasm + nim-bundle.js  (Nim 2.2.4, compiled to wasm)
   ▼
N × .c files
   │  clang.wasm   clang -cc1 -emit-obj -fno-common
   ▼
N × .o files
   │  lld.wasm     wasm-ld --no-threads --export-dynamic
   ▼
one app.wasm
   │  WebAssembly.instantiate
   ▼
program output
```

There is no native toolchain, no server requirement, and no JavaScript
fallback — the actual `clang` and `lld` binaries run as wasm.

## Component reference

### `nim-build.html` — the page

1. Imports `static/nim/nim-bundle.js` (Nim's compiler frontend as JS, ~6.5 MB).
2. Loads `static/nim/nim.wasm` (Nim's compiler backend, ~4.6 MB).
3. Loads `static/nim/nimbase.h` so it can be inlined into every translation
   unit (TU).
4. **Runs the user code through Nim** with the `c` backend:

   ```
   c --hints:off -d:release -d:useMalloc \
     --path:/lib/pure --path:/lib/pure/collections --path:/lib/core \
     -o:/tmp/user /tmp/user.nim
   ```

   The `c` backend emits C (not C++, because the wasm-clang used here was built
   without exception support). `-d:useMalloc` is critical: it makes Nim use
   `lib/system/mm/malloc.nim` (a thin `c_malloc(size)`) instead of the
   mmap-based `osalloc.nim`. The wasi-emulated-mman shim is fragile and
   mmap-based page allocation fails through to `raiseOutOfMem()`; `-d:useMalloc`
   routes everything through wasi-libc's dlmalloc, which grows wasm linear
   memory incrementally.
5. Reads the generated `.c` files from Nim's in-memory filesystem.
6. Imports `static/clang/clang.js?v=34` (the patched compiler driver).
7. **Cleans each TU**: strips `#include "nimbase.h"` and a few `#define`s (they
   are inlined manually), and **rewrites `main(argc, args, env)` to
   `main(argc, argv)`** plus a NULL `env` local. The wasi `crt1.o` calls a
   2-arg `main`; the 3-arg form fails wasm validation.
8. **Prepends a hand-written header** to each TU containing:
   - `NIM_INTBITS 32` and `NIM_EmulateOverflowChecks`
   - `SIG_IGN / SIG_DFL / SIG_ERR` and a static `signal()` shim
   - `__attribute__((weak)) int raise(int)` — wasi-libc *declares* `raise()`
     but never implements it, and Nim's system module calls it
   - `jmp_buf / setjmp / longjmp` type shims
   - the full `nimbase.h` content
9. Hands the cleaned TUs to `clang.js`'s `compileEachLink(files, 'app.wasm')`.
   The output name is **relative** (no leading slash): a leading slash would
   write the file under `/app.wasm`, but the host `FindNode("/app.wasm")` lookup
   would miss it and `getFileContents` would trap.
10. Streams status and program output to the page log.

### `static/clang/clang.js` — the patched compiler driver

A bundled JavaScript file that embeds a base64-encoded web worker. The worker is
a small Emscripten host that loads:

- `clang.wasm` — the C compiler
- `lld.wasm` — the linker
- `memfs.wasm` — an in-memory filesystem
- `sysroot.tar` — the wasi C headers and libraries

The `compile-each-link` handler compiles each `.c` to its own `.o`, then links
them all:

```
wasm-ld --no-threads --export-dynamic -z stack-size=1048576 \
  -Llib/wasm32-wasi lib/wasm32-wasi/crt1.o <objs> \
  -lc -lcanvas -lwasi-emulated-mman -o app.wasm
```

### `static/clang/clang.wasm` — the compiler

**Untouched.** Pristine `binji/clang.wasm` with the default
`INITIAL_MEMORY = 99 pages`. No binary patches. (An earlier dlmalloc heap patch
was obsolete — see [Design history](#design-history).)

### `static/clang/lld.wasm` — the linker

Untouched `binji/lld.wasm`.

## Toolchain patches

All patches live in JavaScript (`clang.js` and `nim-build.html`); the wasm
binaries themselves are pristine upstream artifacts.

`clang.js`, versus upstream `binji/clang.js`:

1. **NUL-terminator in `addFile`** — `mem.write(GetPathBuf() + len, 0)` so memfs
   hashes the path correctly. Without it, the second-or-later file triggers
   `unreachable` inside `AddFileNode`.
2. **`ensureParentDir` in `compile`** — ensures parent directories exist before
   writing into memfs, so writes to deep paths (e.g. `nimcache/w0.c`) don't
   silently fail.
3. **`compile-each-link` message handler** — compiles each `.c` to a `.o`, links
   all objects with `lld.wasm`, then runs the result.
4. **`-fno-common` injected into `clang -cc1`** — the core fix. Clang 8 defaults
   to `-fcommon`, so C tentative definitions (`int x;` with no initializer)
   become `common`-linkage globals. LLVM 8.0.1's WebAssembly object writer
   (`WasmObjectWriter`) hits `llvm_unreachable` when serializing them.
   `-fno-common` emits them as ordinary `.bss` definitions and the writer stops
   trapping.
5. **`cache: "no-store"`** on the `clang.wasm` fetch so a browser refresh always
   loads the latest binary. `clang.js` itself is cache-busted via `?v=34`.

`nim-build.html` carries two further patches that must stay in sync manually:

- the **weak `raise()` stub** (part of the prepended header), and
- the **2-arg `main` rewrite** (part of the C-source cleaner).

## Building and deploying

The whole project is a static site. `app.py` and the Flask templates are
optional conveniences for local development. To deploy, you only need the
contents of `src/site/` (mirrored in `demo/`):

```
site/
├── index.html
├── nim-build.html        the Nim → wasm page
└── static/
    ├── clang/            clang.js, clang.wasm, lld.wasm, memfs.wasm, sysroot.tar
    └── nim/              nim-bundle.js, nim.wasm, nimbase.h
```

### Option A — redeploy the static site (no rebuild)

The `site/` directory is the entire deployable artifact. Zip it and host it on
any static file server (GitHub Pages, Netlify, S3, etc.).

### Option B — full rebuild from source

```bash
cd src
./rebuild.sh                 # rebuild archives + deploy
./rebuild.sh --no-deploy     # rebuild only
```

`rebuild.sh`:

1. Re-applies `-fno-common` to `clang.js` (idempotent).
2. Verifies `clang.wasm` is the pristine 99-page binary.
3. Builds the full and sources-only archives.
4. Optionally deploys.

### Option C — local Flask dev server

```bash
cd src
python3 -m pip install -r requirements.txt
python3 app.py               # open http://localhost:5000
```

`templates/nim-build.html` mirrors `site/nim-build.html`; keep them in sync, or
edit `site/nim-build.html` and let `rebuild.sh` mirror it.

### Rebuilding `nim.wasm` (rarely needed)

The prebuilt artifacts in `static/nim/` work out of the box. To rebuild from a
Nim checkout, the short version is:

```bash
nim c --cpu:wasm32 --os:any --define:danger --passC:"-s USE_ZLIB=1"
```

## Re-applying the clang.js patch

`patch-clang-wasm.sh` re-applies the `-fno-common` patch to one or more
`clang.js` files. It is idempotent.

```bash
cd src
./patch-clang-wasm.sh                 # patch the bundled clang.js copies
./patch-clang-wasm.sh path/to/x.js    # patch a specific file
```

The script extracts the base64-embedded worker blob, locates the compile-args
tuple, substitutes `"-Oz","-fno-common","-o",i,"-x","c"` for
`"-Oz","-o",i,"-x","c"`, re-encodes the base64, and writes the file back.

## Verification

The pipeline is verified end-to-end in the browser and in a faithful Node port
that uses the **same** `clang.wasm`, `lld.wasm`, sysroot, compile flags, and link
libraries:

| Stage                        | Result                                        |
| ---------------------------- | --------------------------------------------- |
| Nim → C                      | ✅ 8 `.c` files                               |
| clang compiles all TUs       | ✅ 8/8 (incl. 177 KB `system.nim.c`)          |
| lld link                     | ✅ exit 0                                      |
| Output is valid wasm         | ✅ `WebAssembly.compile` accepts the module   |
| Runs in browser              | ✅ prints expected output                      |

The linked module imports `wasi_unstable`; its exports include `_start`,
`main`, and `NimMain`.

## Design history

The pipeline aborted for a long time with `RuntimeError: unreachable` after Nim
emitted C and clang began compiling. Two early theories were investigated and
discarded:

- **dlmalloc heap exhaustion.** The trap was first blamed on dlmalloc's
  `expand_heap()` running out of room on the largest TU. A binary patch raised
  dlmalloc's `heap_end` from ~6.2 MB to 256 MB, and all TUs then "compiled" —
  but the link step still failed, and the OOM turned out to be a red herring.
- **An lld string-compare assertion.** The link failure was next attributed to
  an internal `unreachable` in lld; a naive nop-patch broke control flow.

**The real root cause** is a bug in LLVM 8.0.1's WebAssembly object writer
(`WasmObjectWriter`): it hits `llvm_unreachable` when serializing a
`common`-linkage global. It was isolated by stage:
`-fsyntax-only`, `-emit-llvm`, `-emit-llvm-bc`, and `-S` all succeed; only
`-emit-obj` traps — so the fault is in the object writer, not codegen.
Delta-debugging the IR for `system.nim.c` reduced the trap to a single line:

```
@threadId__system_u2938 = common hidden global i32 0
```

Even a bare `int x;` reproduces it; `-fno-common` makes it compile. Under
clang's default `-fcommon` (clang < 11), C file-scope tentative definitions
become `common`-linkage globals, and Nim's generated C contains several
(`threadId`, `allocator`, `roots`, …), so `clang -cc1 -emit-obj` trapped while
writing the object file.

The fix is therefore three small, source-level changes — `-fno-common`, the
weak `raise()` stub, and the 2-arg `main` rewrite — with **no binary patches to
`clang.wasm` or `lld.wasm`**. The obsolete dlmalloc heap patch was reverted.
