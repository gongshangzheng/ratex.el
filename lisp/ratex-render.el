;;; ratex-render.el --- Async rendering client -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ratex-core)
(require 'ratex-math-detect)
(require 'ratex-overlays)

(defvar ratex-mode)
(defvar-local ratex--render-cache nil)
(defvar-local ratex--inflight-requests nil)
(defvar-local ratex--last-error nil)
(defvar-local ratex--active-fragment nil)

(defun ratex-reset-buffer-state ()
  "Reset buffer-local rendering state."
  (setq-local ratex--render-cache (make-hash-table :test #'equal))
  (setq-local ratex--inflight-requests (make-hash-table :test #'equal))
  (setq-local ratex--last-error nil)
  (setq-local ratex--active-fragment nil))

(defun ratex-refresh-previews (&optional include-active)
  "Refresh math previews in current buffer.

When INCLUDE-ACTIVE is non-nil, render all formulas, including the one
currently under point."
  (interactive)
  (let* ((fragments (ratex-fragments-in-buffer))
         (active (ratex-fragment-at-point))
         (targets (if include-active
                      fragments
                    (ratex--fragments-to-render fragments active)))
         (target-keys (mapcar #'ratex--fragment-key targets)))
    (ratex--drop-stale-overlays target-keys)
    (dolist (fragment targets)
      (ratex--ensure-fragment-preview fragment))))

(defun ratex-initialize-previews ()
  "Render all formulas once and initialize point tracking."
  (ratex-refresh-previews t)
  (setq ratex--active-fragment (ratex-fragment-at-point))
  (when ratex--active-fragment
    (ratex-remove-overlay (ratex--fragment-key ratex--active-fragment))))

(defun ratex-handle-post-command ()
  "Update previews only when point enters/leaves math fragments."
  (when ratex-mode
    (let ((current (ratex-fragment-at-point))
          (previous ratex--active-fragment))
      (cond
       ((and previous current (ratex--same-active-context-p previous current))
        nil)
       ((and previous current)
        (ratex--ensure-fragment-preview previous)
        (ratex-remove-overlay (ratex--fragment-key current)))
       (current
        (ratex-remove-overlay (ratex--fragment-key current)))
       (previous
        (ratex--ensure-fragment-preview previous)))
      (setq ratex--active-fragment current))))

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

(defun ratex--same-active-context-p (a b)
  "Return non-nil when A and B are part of the same editing fragment."
  (or (ratex--same-fragment-p a b)
      (ratex--fragments-overlap-p a b)))

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

(defun ratex--fragment-valid-p (fragment)
  "Return non-nil when FRAGMENT still matches current buffer text."
  (let ((begin (plist-get fragment :begin))
        (end (plist-get fragment :end))
        (open (plist-get fragment :open))
        (content (plist-get fragment :content))
        (close (plist-get fragment :close)))
    (and (integer-or-marker-p begin)
         (integer-or-marker-p end)
         (<= (point-min) begin end (point-max))
         (string= (buffer-substring-no-properties begin end)
                  (concat open content close)))))

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
     ((not (ratex--fragment-valid-p fragment))
      (ratex-remove-overlay fragment-key))
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
  (let ((active (ratex-fragment-at-point)))
    (if (or (not (ratex--fragment-valid-p fragment))
            (and active (ratex--same-active-context-p fragment active)))
        (ratex-remove-overlay fragment-key)
      (ratex--display-response fragment-key fragment response))))

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
