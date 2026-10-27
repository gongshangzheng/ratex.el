;;; ratex-overlays.el --- Overlay helpers -*- lexical-binding: t; -*-

;;; Code:

(defvar-local ratex--overlays nil)

(defvar-local ratex--scale 1.0
  "Text scale currently applied to rendered images in this buffer.")

(defun ratex--overlay-table ()
  "Return the overlay table for the current buffer."
  (unless (hash-table-p ratex--overlays)
    (setq-local ratex--overlays (make-hash-table :test #'equal)))
  ratex--overlays)

(defun ratex-clear-overlays ()
  "Delete all RaTeX overlays in the current buffer."
  (when (hash-table-p ratex--overlays)
    (maphash (lambda (_key overlay)
               (when (overlayp overlay)
                 (delete-overlay overlay)))
             ratex--overlays)
    (clrhash ratex--overlays)))

(defun ratex-remove-overlay (key)
  "Delete the RaTeX overlay identified by KEY."
  (let* ((table (ratex--overlay-table))
         (overlay (gethash key table)))
    (when (overlayp overlay)
      (delete-overlay overlay))
    (remhash key table)))

(defun ratex-show-overlay (key beg end image &optional help-echo fragment style)
  "Show IMAGE for KEY at BEG..END with optional HELP-ECHO, FRAGMENT, and STYLE.

When the overlay already covers BEG..END with the same IMAGE and STYLE it
is reused instead of being rebuilt, which is what keeps repeated display
of an unchanged formula cheap."
  (let* ((table (ratex--overlay-table))
         (style (or style 'inline))
         (existing (gethash key table))
         (reuse (and (overlayp existing)
                     (= beg (overlay-start existing))
                     (= end (overlay-end existing))
                     (eq style (overlay-get existing 'ratex-render-style))
                     (equal image (overlay-get existing 'ratex-image))))
         (overlay existing))
    (if reuse
        (progn
          (overlay-put existing 'ratex-fragment fragment)
          (overlay-put existing 'ratex-scale ratex--scale)
          (when help-echo
            (overlay-put existing 'help-echo help-echo))
          existing)
      (when (overlayp existing)
        (delete-overlay existing))
      (setq overlay (make-overlay beg end))
      (overlay-put overlay 'ratex-image image)
      (overlay-put overlay 'evaporate t)
      (overlay-put overlay 'ratex-key key)
      (overlay-put overlay 'ratex-fragment fragment)
      (overlay-put overlay 'ratex-scale ratex--scale)
      (ratex--overlay-apply-style overlay style)
      (when help-echo
        (overlay-put overlay 'help-echo help-echo))
      (puthash key overlay table)
      overlay)))

(defun ratex-overlay-keys ()
  "Return overlay keys currently shown in the current buffer."
  (let (keys)
    (when (hash-table-p ratex--overlays)
      (maphash (lambda (key _overlay)
                 (push key keys))
               ratex--overlays))
    keys))

(defun ratex--overlay-entry-at-point ()
  "Return (KEY . OVERLAY) for a visible RaTeX overlay at point, or nil."
  (let (found)
    (dolist (overlay (overlays-at (point)) found)
      (let ((key (overlay-get overlay 'ratex-key)))
        (when (and key
                   (not found)
                   (hash-table-p ratex--overlays)
                   (eq overlay (gethash key ratex--overlays)))
          (setq found (cons key overlay)))))))

(defun ratex-rendered-overlay-at-point-p ()
  "Return non-nil when point is inside a visible RaTeX rendered overlay."
  (and (ratex--overlay-entry-at-point) t))

(defun ratex-overlay-fragment-at-point ()
  "Return fragment metadata from the RaTeX overlay at point, or nil."
  (let ((entry (ratex--overlay-entry-at-point)))
    (when entry
      (overlay-get (cdr entry) 'ratex-fragment))))

(defun ratex-overlay-for-key (key)
  "Return the overlay for KEY, or nil."
  (let ((table (ratex--overlay-table)))
    (when (hash-table-p table)
      (gethash key table))))

(defun ratex-overlay-image-for-key (key)
  "Return the rendered image for overlay KEY, or nil."
  (let ((overlay (ratex-overlay-for-key key)))
    (when (overlayp overlay)
      (overlay-get overlay 'ratex-image))))

(defun ratex--overlay-apply-style (overlay style)
  "Apply STYLE to OVERLAY using its stored image."
  (let ((image (overlay-get overlay 'ratex-image)))
    (cond
     ((eq style 'below)
      (overlay-put overlay 'display nil)
      (overlay-put overlay 'after-string
                   (concat "\n" (propertize " " 'display image) "\n")))
     (t
      (overlay-put overlay 'after-string nil)
      (overlay-put overlay 'display image))))
  (overlay-put overlay 'ratex-render-style style))

(declare-function ratex--update-scale "ratex-render")

(defun ratex-update-overlay-scale ()
  "Apply the current text scale to previews in the current buffer.

Only the formulas that are displayed get re-rendered immediately; the
rest pick up the new scale when they become visible."
  (when (fboundp 'ratex--update-scale)
    (ratex--update-scale)))

(add-hook 'text-scale-mode-hook #'ratex-update-overlay-scale)

(provide 'ratex-overlays)

;;; ratex-overlays.el ends here
