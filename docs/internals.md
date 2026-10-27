# Internals

Implementation notes for `ratex.el`. Everything here is about *how* it works;
for what the package does and how to use it, see the [README](../README.md).

## Repository layout

- `vendor/ratex-core`: upstream RaTeX git submodule (parser, layout, SVG output)
- `backend/`: the Rust process Emacs talks to (`backend/src/main.rs`)
- `lisp/`: the Emacs package
  - `ratex-core.el`: backend process management, download, diagnostics
  - `ratex-math-detect.el`: fragment detection
  - `ratex-overlays.el`: overlays and display styles
  - `ratex-render.el`: rendering client, scheduling, previews
  - `ratex.el`: minor mode and hooks
- `bin/`: helper scripts
- `test/`: Emacs-side tests (`emacs -Q --batch -L lisp -l test/ratex-tests.el -f ert-run-tests-batch-and-exit`)
- `docs/`: this file and the development plan

## Backend binary

The backend is a single Rust binary that speaks JSONL over stdin/stdout: one
request per line, one response per line, rendered synchronously, one formula at
a time. `ratex.el` keeps one long-lived process and multiplexes requests by `id`.

Binary resolution order (`lisp/ratex-core.el`):

1. `ratex-backend-binary` — absolute path, or relative to `ratex-backend-root`
2. `ratex-backend-root`, when set
3. auto-discovery from `load-file-name` / `locate-library`, including straight.el
   build directories (`straight/build/<pkg>` → `straight/repos/<pkg>`)

If no usable binary is found, the matching asset of the latest GitHub Release is
downloaded to `backend/target/release/ratex-editor-backend`
(`ratex-backend-release-repo`, `ratex-auto-download-backend`). Downloaded files
are validated by magic bytes before they are made executable; a failed download
or launch fails all pending requests instead of leaving them hanging.

Building from source instead of downloading:

```bash
git clone --recurse-submodules https://github.com/gongshangzheng/ratex.el.git
cd ratex.el
cargo build --release --manifest-path backend/Cargo.toml
```

`M-x ratex-build-backend` runs the same command
(`ratex-backend-build-command`).

## Rendering schedule

Rendering is driven by window visibility, not by a whole-buffer sweep:

- `post-command-hook` compares `point`, `window-start` and
  `buffer-chars-modified-tick`; any change schedules the render job.
- `window-scroll-functions` schedules the same job for programmatic scrolling
  (timers, `follow-mode`, restoring a saved window start). It cannot compute the
  visible range there — `window-end` is not valid inside that hook.
- The job (`ratex--render-visible`) is idempotent: it returns immediately when
  the visible range and the buffer tick are unchanged. It renders at most
  `ratex-visible-render-chunk` formulas per idle turn and continues in later
  idle turns.
- Formulas are considered already rendered when the overlay still covers the
  same range, still carries the current text scale and the current render cache
  key (font size, padding, colour, font directory). Otherwise they are rebuilt.
- `M-x ratex-render-buffer` runs the same pipeline over the whole buffer in
  chunks; it is cancelled by any edit or by `ratex-cancel-render-buffer`.

Backend requests are deduplicated per render cache key: identical formulas share
one request and all waiters are displayed when the response arrives. Cache
entries are bounded by `ratex-render-cache-size` (LRU; default 256) together with
their images.

## Fragment detection

Sources of truth are `\(...\)` and `\[...\]`. For the fragment at point the
search walks back to the nearest opening delimiter and pairs it with the first
following closing delimiter; if that pair ends before point (or the opening has
no closing delimiter), no earlier opening can contain point, so the lookup stops.
This keeps the cost independent of how many formulas precede point. Detection
skips escaped delimiters and code contexts (Org `src`/`example`/`verbatim`,
Markdown fenced blocks).

## Rendering input vs. document text

`ratex-render-strip-patterns` (default: `\label`) is applied when building the
request payload *and* the render cache key, so a formula keeps rendering the same
way when only a label changes. The fragment content, the buffer text and any
exported LaTeX are never modified. A fragment that becomes empty after stripping
is not sent to the backend at all.

## Other internal knobs

- `ratex-visible-render-chunk`: formulas rendered per idle turn (default 12)
- `ratex-render-cache-size`: LRU size for rendered responses and images (default 256)
- `ratex-posframe-poshandler`: placement function for the posframe preview
- `ratex-theme-change-refresh-scope`: `all` / `current` / `nil`
