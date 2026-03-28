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

(defun ratex-show-overlay (key beg end image &optional help-echo)
  "Show IMAGE for KEY at BEG..END with optional HELP-ECHO."
  (let ((table (ratex--overlay-table))
        (overlay nil))
    (ratex-remove-overlay key)
    (setq overlay (make-overlay beg end))
    (overlay-put overlay 'display image)
    (overlay-put overlay 'evaporate t)
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

(provide 'ratex-overlays)

;;; ratex-overlays.el ends here
