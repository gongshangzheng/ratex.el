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
        (add-hook 'post-command-hook #'ratex-handle-post-command nil t)
        (ratex-start-backend)
        (ratex-refresh-previews))
    (remove-hook 'post-command-hook #'ratex-handle-post-command t)
    (ratex-clear-overlays)))

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
(defun ratex-setup ()
  "Enable `ratex-mode' in common text/math buffers."
  (interactive)
  (dolist (hook '(latex-mode-hook LaTeX-mode-hook org-mode-hook markdown-mode-hook))
    (add-hook hook #'ratex-mode)))

(provide 'ratex)

;;; ratex.el ends here
