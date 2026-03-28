# Development Plan

## Goal

Build an Emacs package on top of RaTeX that provides fast inline math rendering
for LaTeX-related editing workflows.

The first version should optimize for:

- low latency
- simple installation
- asynchronous rendering
- clean integration with existing Emacs LaTeX workflows

It should not try to replace AUCTeX, CDLaTeX, or a full TeX toolchain in the
first iteration.

## Scope

### In scope for v0

- render individual math fragments inside Emacs
- support inline and display math delimiters
- async preview updates near point
- lightweight parse error reporting
- SVG-based rendering path
- local caching of repeated formulas

### Out of scope for v0

- full document compilation
- citation and bibliography workflows
- SyncTeX integration
- code completion and refactoring support
- project-wide semantic analysis
- user-defined macro systems beyond a minimal escape hatch

## Architecture

The project is split into two layers.

### 1. Rust editor backend

A dedicated editor-facing backend process lives in this repository and reuses
parse, layout, and SVG rendering from `vendor/ratex-core`.

Responsibilities:

- accept math snippets over stdin/stdout
- return standalone SVG plus dimensions
- surface structured parse errors
- cache repeated results safely

Recommended transport:

- JSON Lines over stdio

### 2. Emacs package

The Emacs side is a small async client that talks to the backend process.

Responsibilities:

- detect math fragments around point
- debounce updates after edits
- send render requests asynchronously
- attach SVG previews using overlays
- cache results by formula and render settings

## Recommended next implementation order

1. Keep the backend protocol stable and documented.
2. Improve fragment detection for mode-specific syntax.
3. Add better error surfacing and stale-request cancellation.
4. Add packaging and integration tests.

## Current prototype notes

- Emacs now auto-builds the backend on first use when the binary is missing or stale.
- The first startup path currently relies on Cargo being available in the user's environment.
- Further polish should focus on mode-aware math detection and startup UX around build failures.
