# Nim WASM Compiler

Compile and run **Nim 2.2.4** entirely in the browser — no server, no native
toolchain, and no JavaScript fallback. Your Nim source is compiled to C, then to
WebAssembly, then executed, all client-side using real `clang` and `lld` ported
to wasm.

```
your .nim code
   │  Nim 2.2.4 (compiled to wasm, runs in-browser)
   ▼
N × .c files
   │  clang.wasm  —  clang -cc1 -emit-obj -fno-common
   ▼
N × .o files
   │  lld.wasm  —  wasm-ld --no-threads --export-dynamic
   ▼
one .wasm module
   │  WebAssembly.instantiate
   ▼
program output
```

## Live demo

**[Open the demo →](https://ysm270oa9ksu.space.minimax.io/)**

Click **Build & Run** to watch your Nim code compile to wasm in the browser.
After a successful build, **Run Only** re-executes the cached `app.wasm`
instantly without recompiling.

The default example prints:

```
Hello, browser!
i = 0
i = 1
i = 2
i = 3
i = 4
sorted: @[1, 1, 2, 3, 4, 5, 6, 9]
5! = 120
```

## Status

| Stage                                | Status |
| ------------------------------------ | :----: |
| Nim 2.2.4 → C (`c` backend)          |   ✅   |
| C → object files (`clang.wasm`)      |   ✅   |
| Object files → wasm (`lld.wasm`)     |   ✅   |
| Instantiate and run in the browser   |   ✅   |
| Re-run from cache (**Run Only**)     |   ✅   |

## Running the demo

The `demo/` directory is a fully self-contained static site with no build step.

### Open directly

Open `demo/index.html` in any modern browser (Chrome, Edge, Firefox, Safari).
Some browsers restrict `file://` URLs; if you hit that, use a static server
instead.

### Serve as static files

```bash
cd demo
python3 -m http.server 8000   # then open http://localhost:8000
```

or `npx serve .`

### Deploy to GitHub Pages

Push the repo, then in **Settings → Pages** set the source to the `main` branch
and the `/demo` folder. Pages will serve the demo at
`https://<user>.github.io/<repo>/`.

### Local Flask dev server (full project)

```bash
cd src
python3 -m pip install -r requirements.txt
python3 app.py               # then open http://localhost:5000
```

## Repository layout

```
.
├── README.md                  Project overview (this file)
├── LICENSE                    MIT
├── docs/
│   └── ARCHITECTURE.md        How it works, build/deploy, and design history
├── demo/                      Self-contained static site (GitHub Pages ready)
│   ├── index.html
│   └── static/                wasm assets (Nim, clang, lld, sysroot)
└── src/                       Full project source
    ├── app.py                 Optional Flask dev server
    ├── requirements.txt
    ├── patch-clang-wasm.sh    Idempotent clang.js patcher
    ├── rebuild.sh             Full rebuild + archive + deploy
    ├── site/                  Deployable site (mirror of demo/)
    └── templates/             Flask templates
```

## How it works

The browser loads a chain of wasm modules and runs them in sequence:

1. **`nim.wasm` + `nim-bundle.js`** — Nim 2.2.4 compiled to wasm. Compiles your
   `.nim` source to C using the `c` backend with `-d:useMalloc`.
2. **`clang.wasm`** — the C compiler. Compiles each `.c` to a `.o` with
   `clang -cc1 -emit-obj -fno-common`. The `-fno-common` flag works around an
   LLVM 8.0.1 object-writer bug that traps on `common`-linkage globals.
3. **`lld.wasm`** — the linker. Links all objects with
   `wasm-ld --no-threads --export-dynamic` into one wasm module.
4. **`memfs.wasm`** — an in-memory filesystem holding the intermediate files.
5. The output is instantiated and executed via `WebAssembly.instantiate`.

For the full pipeline, the C-source preprocessing steps, the toolchain patches,
and the build/deploy guide, see **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## License

This project's glue code and patches are released under the [MIT License](LICENSE).
Bundled third-party artifacts retain their original licenses:

- `clang.wasm`, `lld.wasm`, `memfs.wasm`, `sysroot.tar` — © Andy Wingo, from the
  [`binji/clang.js`](https://github.com/binji/clang.js) project.
- `nim.wasm`, `nim-bundle.js`, `nimbase.h` — Nim 2.2.4, MIT.
