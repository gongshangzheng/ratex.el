# ratex.el

[简体中文](./README.zh-CN.md)

Inline LaTeX math preview for Emacs, powered by the upstream
[RaTeX](https://github.com/erweixin/RaTeX) engine. You type `\(\frac{1}{2}\)`
and see the formula — no TeX installation, no document compilation.

## Demo

![ratex.el demo](./assets/demo.gif)

## Features

- Inline previews in `latex-mode`, `LaTeX-mode`, `org-mode` and `markdown-mode`
- Rendering follows the window: only what you can see is rendered, scrolling
  fills in the rest, and formulas already on screen are never re-rendered
- What you are editing stays editable source; optionally show a live preview of
  it in a posframe or in the minibuffer
- Rendering happens asynchronously in a small background process, so typing and
  scrolling stay responsive even in documents with thousands of formulas
- The backend binary is downloaded automatically on first use

## Requirements

- Emacs 29.1 or newer
- Network access on first use, to fetch the backend binary

## Installation

Put `lisp/` on your `load-path` and require the package:

```elisp
(add-to-list 'load-path "/path/to/ratex.el/lisp")
(require 'ratex)
(global-ratex-mode 1)
```

With `use-package`:

```elisp
(use-package ratex
  :load-path "/path/to/ratex.el/lisp"
  :config
  (global-ratex-mode 1))
```

Enable it in a single buffer with `M-x ratex-mode`.

## Usage

By default `global-ratex-mode` turns previews on for LaTeX, Org and Markdown
buffers. If you prefer explicit control:

```elisp
(add-hook 'org-mode-hook #'ratex-mode)
(add-hook 'markdown-mode-hook #'ratex-mode)
(add-hook 'latex-mode-hook #'ratex-mode)
```

In Org files a keyword can override the global setting for that file:

```org
#+ratex: t      # force on
#+ratex: nil    # force off
```

Write math with the LaTeX delimiters `\(...\)` or `\[...\]`:

```tex
The identity \(e^{i\pi} + 1 = 0\) is famous.

\[
\int_0^1 x^2\,dx = \frac{1}{3}
\]
```

Dollar delimiters (`$...$`, `$$...$$`) are not supported. To convert formulas
that already use them, run `M-x ratex-convert-delimiters`.

What you can expect while editing:

- formulas in the window are rendered; scrolling renders whatever scrolls into
  view and reuses everything that is already rendered
- the formula under point is shown as source while you edit it (with
  `ratex-edit-preview` set, a live preview appears in a posframe or in the
  minibuffer instead), and it is re-rendered once you leave it
- formulas inside code blocks (Org `src` / `example` / `verbatim`, Markdown
  fenced code) and escaped delimiters such as `\\(` are left untouched

Labels are fine: `\label{eq:...}` has no visible output, so the formula is
previewed without it while your buffer — and the LaTeX produced by
`org-export` — keeps the label. References (`\ref`, `\eqref`) still show as
render errors, because a single formula has no document context to resolve
them.

## Commands

| Command | What it does |
|---|---|
| `M-x ratex-mode` | Toggle previews in the current buffer |
| `M-x global-ratex-mode` | Toggle previews in all supported buffers |
| `M-x ratex-refresh-previews` | Re-render the visible formulas |
| `M-x ratex-render-buffer` | Render the whole buffer in background chunks |
| `M-x ratex-cancel-render-buffer` | Cancel that background run |
| `M-x ratex-convert-delimiters` | Convert `$...$` / `$$...$$` to `\(...\)` / `\[...\]` |
| `M-x ratex-download-backend` | Re-download the backend binary |
| `M-x ratex-diagnose-backend` | Show how the backend binary was resolved |

## Customization

Colours and theme behavior:

- `ratex-dark-render-color` / `ratex-light-render-color`: formula colour chosen
  from the current frame's background mode (defaults: `"white"` / `"black"`)
- `ratex-render-color`: explicit colour override, ignoring the theme
- `ratex-dark-posframe-background-color` /
  `ratex-light-posframe-background-color` / `ratex-posframe-background-color`:
  the same idea for the posframe preview background
- `ratex-theme-change-refresh-scope`: `all` (default), `current` or `nil`

Editing and rendering:

- `ratex-edit-preview`: `nil` (default, formula at point stays source),
  `posframe`, or `minibuffer`
- `ratex-font-size` (default `16.0`) and `ratex-svg-padding` (default `2.0`)
- `ratex-render-strip-patterns`: LaTeX commands removed before rendering,
  because they have no visible output; defaults to `\label` only

A configuration that follows the theme and previews in the minibuffer:

```elisp
(use-package ratex
  :config
  (setq ratex-edit-preview 'minibuffer)
  (setq ratex-dark-render-color "white")
  (setq ratex-light-render-color "black")
  (global-ratex-mode 1))
```

## Troubleshooting

- **Nothing renders and you see warnings** — the backend is probably missing.
  `M-x ratex-diagnose-backend` shows what was found; `M-x ratex-download-backend`
  fetches it again.
- **Formulas look garbled or use wrong glyphs** — the KaTeX fonts were not
  found. Point `ratex-font-dir` at the `fonts` directory that ships with the
  repository.
- **The backend cannot be located** — set `ratex-backend-root` to the checkout
  explicitly.

Implementation notes (backend binary, release assets, rendering schedule,
internal knobs) live in [`docs/internals.md`](./docs/internals.md).

## Current Status

An early but usable prototype. Preview rendering, scrolling performance and
error reporting are in place; packaging for MELPA-style installation and
broader math-detection coverage are not done yet.

## License

This repository contains original `ratex.el` integration code plus the vendored
upstream `vendor/ratex-core` submodule, which keeps its own upstream license and
history.
