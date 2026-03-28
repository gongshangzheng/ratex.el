# ratex.el

An Emacs-focused project built around the upstream RaTeX engine.

## Repository layout

- `vendor/ratex-core`: upstream RaTeX repository, kept as a git submodule
- `backend/`: Rust backend process for editor integrations
- `docs/`: planning notes and project documentation
- `lisp/`: Emacs Lisp package sources
- `bin/`: helper scripts for local development
- `test/`: Emacs-side tests

## Current status

This repository now contains a minimal end-to-end prototype:

- a standalone JSONL backend that renders LaTeX fragments to SVG
- an Emacs minor mode with async inline previews
- basic math fragment detection and overlay display

## Getting started

Load [`ratex.el`](/Users/zhengxinyu/code/ratex.el/lisp/ratex.el) in Emacs and enable `ratex-mode`
in a supported buffer. On first use, the package will automatically run:

```bash
cargo build --manifest-path backend/Cargo.toml
```

if the backend binary is missing or older than the backend sources. After that,
Emacs launches the compiled binary directly from `backend/target/debug/`.

For manual local development, you can still start the backend yourself:

```bash
bin/dev-start-backend.sh
```
