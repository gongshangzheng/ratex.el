;;; ratex-overlays.el --- Overlay helpers -*- lexical-binding: t; -*-

;;; Code:

(defvar-local ratex--overlays nil)

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
  "Show IMAGE for KEY at BEG..END with optional HELP-ECHO, FRAGMENT, and STYLE."
  (let ((table (ratex--overlay-table))
        (overlay nil))
    (ratex-remove-overlay key)
    (setq overlay (make-overlay beg end))
    (overlay-put overlay 'ratex-image image)
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'ratex-key key)
    (overlay-put overlay 'ratex-fragment fragment)
    (ratex--overlay-apply-style overlay (or style 'inline))
    (puthash key overlay table))
  (when help-echo
    (overlay-put (gethash key (ratex--overlay-table)) 'help-echo help-echo)))

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
  (let ((pos (point))
        found)
    (when (hash-table-p ratex--overlays)
      (maphash
       (lambda (key overlay)
         (when (and (not found)
                    (overlayp overlay)
                    (overlay-buffer overlay)
                    (<= (overlay-start overlay) pos)
                    (< pos (overlay-end overlay)))
           (setq found (cons key overlay))))
       ratex--overlays))
    found))

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

(defun ratex-set-overlay-style (key style)
  "Set STYLE for overlay KEY."
  (let ((overlay (ratex-overlay-for-key key)))
    (when (overlayp overlay)
      (ratex--overlay-apply-style overlay style))))

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

(provide 'ratex-overlays)

;;; ratex-overlays.el ends here
