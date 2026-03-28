;;; ratex-render.el --- Async rendering client -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ratex-core)
(require 'ratex-math-detect)
(require 'ratex-overlays)

(defvar-local ratex--render-cache (make-hash-table :test #'equal))
(defvar-local ratex--inflight-requests nil)
(defvar-local ratex--last-error nil)

(defun ratex-refresh-previews ()
  "Refresh math previews in current buffer.

All formulas are rendered except the one currently under point."
  (interactive)
  (let* ((fragments (ratex-fragments-in-buffer))
         (active (ratex-fragment-at-point))
         (targets (ratex--fragments-to-render fragments active))
         (target-keys (mapcar #'ratex--fragment-key targets)))
    (ratex--drop-stale-overlays target-keys)
    (dolist (fragment targets)
      (ratex--ensure-fragment-preview fragment))))

(defun ratex-handle-post-command ()
  "Update previews after each command."
  (when ratex-mode
    (ratex-refresh-previews)))

(defun ratex--fragments-to-render (fragments active)
  "Return FRAGMENTS excluding ACTIVE."
  (cl-remove-if
   (lambda (fragment)
     (and active (ratex--same-fragment-p fragment active)))
   fragments))

(defun ratex--same-fragment-p (a b)
  "Return non-nil when fragments A and B represent the same range."
  (and (= (plist-get a :begin) (plist-get b :begin))
       (= (plist-get a :end) (plist-get b :end))
       (equal (plist-get a :content) (plist-get b :content))))

(defun ratex--fragment-key (fragment)
  "Return stable overlay key for FRAGMENT."
  (format "%d:%d:%s"
          (plist-get fragment :begin)
          (plist-get fragment :end)
          (plist-get fragment :content)))

(defun ratex--cache-key (fragment)
  "Return render cache key for FRAGMENT."
  (list (string-trim (plist-get fragment :content))
        ratex-font-size
        ratex-svg-padding))

(defun ratex--inflight-table ()
  "Return request-tracking table for current buffer."
  (unless (hash-table-p ratex--inflight-requests)
    (setq-local ratex--inflight-requests (make-hash-table :test #'equal)))
  ratex--inflight-requests)

(defun ratex--drop-stale-overlays (target-keys)
  "Delete overlays not present in TARGET-KEYS."
  (let ((keep (make-hash-table :test #'equal)))
    (dolist (key target-keys)
      (puthash key t keep))
    (dolist (key (ratex-overlay-keys))
      (unless (gethash key keep)
        (ratex-remove-overlay key)))))

(defun ratex--ensure-fragment-preview (fragment)
  "Ensure FRAGMENT preview is displayed or requested."
  (let* ((fragment-key (ratex--fragment-key fragment))
         (cache-key (ratex--cache-key fragment))
         (cached (gethash cache-key ratex--render-cache))
         (inflight (gethash cache-key (ratex--inflight-table))))
    (cond
     (cached
      (ratex--display-response fragment-key fragment cached))
     (inflight nil)
     (t
      (puthash cache-key t (ratex--inflight-table))
      (ratex-request
       `((type . "render")
         (latex . ,(string-trim (plist-get fragment :content)))
         (font_size . ,ratex-font-size)
         (padding . ,ratex-svg-padding)
         (embed_glyphs . t))
       (lambda (response)
         (remhash cache-key (ratex--inflight-table))
         (when (alist-get 'ok response)
           (puthash cache-key response ratex--render-cache))
         (when ratex-mode
           (ratex--display-if-visible fragment-key fragment response))))))))

(defun ratex--display-if-visible (fragment-key fragment response)
  "Display RESPONSE for FRAGMENT-KEY if FRAGMENT should still be visible."
  (let* ((active (ratex-fragment-at-point))
         (fragments (ratex-fragments-in-buffer))
         (current (cl-find-if
                   (lambda (candidate)
                     (equal (ratex--fragment-key candidate) fragment-key))
                   fragments)))
    (if (or (not current)
            (and active (ratex--same-fragment-p current active)))
        (ratex-remove-overlay fragment-key)
      (ratex--display-response fragment-key current response))))

(defun ratex--display-response (fragment-key fragment response)
  "Display backend RESPONSE for FRAGMENT identified by FRAGMENT-KEY."
  (if (not (alist-get 'ok response))
      (progn
        (setq ratex--last-error (alist-get 'error response))
        (ratex-remove-overlay fragment-key)
        (when ratex--last-error
          (message "RaTeX render failed: %s" ratex--last-error)))
    (let* ((svg (alist-get 'svg response))
           (baseline (or (alist-get 'baseline response) 0.0))
           (height (max 0.001 (or (alist-get 'height response) 0.0)))
           (image (create-image
                   svg
                   'svg t
                   :ascent (floor (* 100.0 (/ baseline height))))))
      (setq ratex--last-error nil)
      (ratex-show-overlay
       fragment-key
       (plist-get fragment :begin)
       (plist-get fragment :end)
       image
       (format "RaTeX %s" (if (alist-get 'cached response) "cached" "rendered"))))))

(provide 'ratex-render)

;;; ratex-render.el ends here
