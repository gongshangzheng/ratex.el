# ratex.el

[简体中文](./README.zh-CN.md)

`ratex.el` is an Emacs-focused inline math preview package built on top of the
upstream [RaTeX](https://github.com/erweixin/RaTeX) engine.

It is designed to render LaTeX math fragments inside Emacs with a small async
backend, SVG output, and minimal setup.

## Demo

![ratex.el demo](./assets/demo.gif)

## Features

- Async inline math preview inside Emacs
- SVG rendering backed by RaTeX
- Automatic backend download on first use
- Lightweight in-buffer rendering flow
- Works with `latex-mode`, `LaTeX-mode`, `org-mode`, and `markdown-mode`

## Repository Layout

- `vendor/ratex-core`: upstream RaTeX git submodule
- `backend/`: Rust backend process used by Emacs
- `lisp/`: Emacs Lisp package files
- `bin/`: helper scripts
- `test/`: Emacs-side tests
- `docs/`: project notes and plans

## Requirements

- Emacs 29.1 or newer
- A checkout with submodules initialized

## Installation

Clone the repository with submodules:

```bash
git clone --recurse-submodules https://github.com/gongshangzheng/ratex.el.git
cd ratex.el
```

If you already cloned it without submodules:

```bash
git submodule update --init --recursive
```

## Emacs Setup

Add this repository to your `load-path`, then load `ratex`:

```elisp
(add-to-list 'load-path "/path/to/ratex.el/lisp")
(require 'ratex)
```

Or with `use-package` (recommended for straight.el users):

```elisp
(use-package ratex
  :config
  (global-ratex-mode 1))
```

Enable it manually in the current buffer:

```elisp
M-x ratex-mode
```

Or enable it automatically for common text/math modes:

```elisp
(require 'ratex)
(global-ratex-mode 1)
```

In Org files, you can also control RaTeX per file with a keyword:

```org
#+ratex: t
```

Use `#+ratex: nil` (or `off`) to disable it for a specific Org file, even when
`global-ratex-mode` is enabled.

Equivalent explicit hook setup:

```elisp
(add-hook 'latex-mode-hook #'ratex-mode)
(add-hook 'LaTeX-mode-hook #'ratex-mode)
(add-hook 'org-mode-hook #'ratex-mode)
(add-hook 'markdown-mode-hook #'ratex-mode)
```

## How It Works

When `ratex-mode` starts, it checks whether the backend binary exists at:

```text
backend/target/release/ratex-editor-backend
```

If the binary is missing, `ratex.el` automatically downloads the matching asset
from the latest GitHub Release:

```text
https://github.com/gongshangzheng/ratex.el/releases/latest
```

After that, Emacs launches the downloaded backend binary directly.

## Usage

The current interaction model is:

- when `ratex-mode` is enabled, only the formulas visible in the current window are rendered
- formulas that scroll into the window are rendered shortly after the scroll; already rendered ones are reused as-is
- when point enters a math fragment, preview is hidden
- while point stays inside that fragment, no continuous rendering is triggered
- when point leaves that fragment, only that fragment is rendered again
- `M-x ratex-render-buffer` renders the whole buffer in background chunks (cancellable)

In other words, `ratex.el` avoids full refresh on every command and uses a
"render once on open + hide while editing + rerender on leave" flow.

Supported delimiters in the current prototype:

- `\(...\)`
- `\[...\]`

This package currently does not support dollar-delimited math. Use
`\(...\)` and `\[...\]` instead; they are simpler and less error-prone in this
codebase. To convert existing dollar-delimited formulas, run:

```elisp
M-x ratex-convert-delimiters
```

This replaces `$$...$$` with `\[...\]` and `$...$` with `\(...\)`.

These cases are skipped by default and will not be rendered:

- formulas inside code blocks (for example Org src/example/verbatim blocks and
  Markdown fenced code blocks)
- escaped delimiters (for example `\$`, `\\(`, `\\[`)

You can also trigger a refresh manually (it re-renders the visible region):

```elisp
M-x ratex-refresh-previews
```

Rendering follows the window: formulas are rendered when they become visible,
scrolling renders only what newly entered the window, and formulas that are
already rendered are never rebuilt.  To render a whole buffer in the
background (cancellable), use:

```elisp
M-x ratex-render-buffer
M-x ratex-cancel-render-buffer
```

Failures are never silent: unparsable backend output, a missing or unusable
backend binary, and a configured-but-unavailable `posframe` preview all produce
a visible warning/error and an error overlay at the formula, instead of the mode
appearing to do nothing.

If needed, you can reinstall the backend manually with:

```elisp
M-x ratex-download-backend
```

## Example

In a LaTeX, Org, or Markdown buffer, place point inside:

```tex
\(\frac{1}{2}\)
```

or:

```tex
\[
\int_0^1 x^2\,dx
\]
```

`ratex.el` will ask the backend to render the fragment and show the SVG preview
through an overlay.

## Customization

Useful variables:

- `ratex-backend-root`: explicit repository root for backend discovery
- `ratex-backend-release-repo`: GitHub repository that hosts backend releases
- `ratex-font-dir`: directory containing KaTeX `.ttf` font files (defaults to `vendor/ratex-core/fonts` inside the repo)
- `ratex-font-size`: SVG font size sent to the backend
- `ratex-svg-padding`: SVG padding sent to the backend
- `ratex-dark-render-color` / `ratex-light-render-color`: theme-aware default formula colors selected from the current frame's `background-mode`
- `ratex-render-color`: explicit formula color override; when nil, the dark/light defaults above are used
- `ratex-edit-preview`: edit preview style (`nil`, `posframe`, or `minibuffer`)
- `ratex-dark-posframe-background-color` / `ratex-light-posframe-background-color`: theme-aware posframe background colors selected from the current frame's `background-mode`
- `ratex-posframe-background-color`: explicit posframe background override; when nil, the dark/light defaults above are used
- `ratex-theme-change-refresh-scope`: whether a theme change refreshes all `ratex-mode` buffers, only the current buffer, or none
- `ratex-render-cache-size`: how many rendered formulas are cached per buffer (LRU eviction)
- `ratex-visible-render-chunk`: how many formulas are rendered per idle turn
- `ratex-auto-download-backend`: whether to download automatically
- `ratex-backend-binary`: backend binary path

### Edit Preview

When `ratex-edit-preview` is set, a live preview is shown while editing a formula:

- `nil` — no preview while editing (default)
- `posframe` — floating popup near point; may occlude nearby text
- `minibuffer` — preview in the minibuffer; lightweight and does not obstruct the buffer

### Example Configuration

```elisp
(use-package ratex
  :config
  (setq ratex-backend-root "~/.emacs.d/straight/repos/ratex.el/")
  (setq ratex-dark-render-color "white")
  (setq ratex-light-render-color "black")
  (setq ratex-edit-preview 'minibuffer)
  (setq ratex-dark-posframe-background-color "black")
  (setq ratex-light-posframe-background-color "white")
  (global-ratex-mode 1))
```

If you want to force a single color regardless of the current theme, set the
override variables directly:

```elisp
(setq ratex-render-color "white")
(setq ratex-posframe-background-color "black")
```

To control what happens after switching themes:

```elisp
(setq ratex-theme-change-refresh-scope 'all)     ; default
;; or:
;; (setq ratex-theme-change-refresh-scope 'current)
;; (setq ratex-theme-change-refresh-scope nil)
```

If the backend cannot find KaTeX fonts (e.g. using a downloaded binary outside the
repo), set `ratex-font-dir` to the directory containing the `.ttf` files:

```elisp
(setq ratex-font-dir "/path/to/ratex.el/vendor/ratex-core/fonts")
```

If backend auto-discovery still fails in your setup, set `ratex-backend-root`
explicitly. You can inspect the current detection result with:

```elisp
M-x ratex-diagnose-backend
```

## Current Status

This is an early prototype. The core rendering path is working, but the package
still needs more polish in areas such as:

- mode-aware math detection
- better stale-response handling
- richer user-facing error reporting
- packaging for MELPA or other package managers

## License

This repository currently contains original `ratex.el` integration code plus the
vendored upstream `vendor/ratex-core` submodule, which keeps its own upstream
license and history.
