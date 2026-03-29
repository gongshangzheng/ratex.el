;;; ratex.el --- Inline LaTeX previews via RaTeX -*- lexical-binding: t; -*-

;; Author: ratex.el contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tex, math, tools

;;; Commentary:

;; Minimal async inline math preview minor mode backed by RaTeX.

;;; Code:

(require 'ratex-core)
(require 'ratex-overlays)
(require 'ratex-render)

;;;###autoload
(define-minor-mode ratex-mode
  "Minor mode for inline math previews powered by RaTeX."
  :lighter " RaTeX"
  (if ratex-mode
      (progn
        (ratex-reset-buffer-state)
        (add-hook 'post-command-hook #'ratex-handle-post-command nil t)
        (add-hook 'buffer-list-update-hook #'ratex-handle-buffer-switch)
        (ratex-start-backend)
        (ratex-initialize-previews))
    (remove-hook 'post-command-hook #'ratex-handle-post-command t)
    (remove-hook 'buffer-list-update-hook #'ratex-handle-buffer-switch)
    (ratex-handle-buffer-switch)
    (ratex-clear-overlays)
    (ratex-reset-buffer-state)))

;;;###autoload
(defun ratex-build-backend-command ()
  "Build the RaTeX backend."
  (interactive)
  (ratex-build-backend))

;;;###autoload
(defun ratex-diagnose-backend-command ()
  "Display backend resolution information for ratex.el."
  (interactive)
  (ratex-diagnose-backend))

;;;###autoload
;;;###autoload
(defun ratex-toggle-preview-command ()
  "Toggle RaTeX preview at point."
  (interactive)
  (ratex-toggle-preview-at-point))

;;;###autoload
(defun ratex-setup ()
  "Enable `ratex-mode' in common text/math buffers."
  (interactive)
  (dolist (hook '(latex-mode-hook LaTeX-mode-hook org-mode-hook markdown-mode-hook))
    (add-hook hook #'ratex-mode)))

(provide 'ratex)

;;; ratex.el ends here
