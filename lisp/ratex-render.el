;;; ratex-render.el --- Async rendering client -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ratex-core)
(require 'ratex-math-detect)
(require 'ratex-overlays)
;; posframe is optional; load it dynamically when enabled.

(defvar ratex-mode)
(defvar ratex-render-color)
(defvar ratex-edit-preview-posframe)
(defvar ratex-posframe-background-color)
(defvar ratex-posframe-border-color)
(defvar ratex-posframe-poshandler)
(defvar-local ratex--render-cache nil)
(defvar-local ratex--inflight-requests nil)
(defvar-local ratex--inflight-waiters nil)
(defvar-local ratex--last-error nil)
(defvar-local ratex--active-fragment nil)
(defvar-local ratex--posframe-visible nil)
(defvar-local ratex--posframe-fragment nil)
(defvar-local ratex--preview-enabled nil)
(defconst ratex--posframe-buffer " *ratex-preview*")
(defconst ratex--posframe-offset-y 5)

(defun ratex-reset-buffer-state ()
  "Reset buffer-local rendering state."
  (setq-local ratex--render-cache (make-hash-table :test #'equal))
  (setq-local ratex--inflight-requests (make-hash-table :test #'equal))
  (setq-local ratex--inflight-waiters (make-hash-table :test #'equal))
  (setq-local ratex--last-error nil)
  (setq-local ratex--active-fragment nil)
  (setq-local ratex--posframe-visible nil)
  (setq-local ratex--posframe-fragment nil)
  (setq-local ratex--preview-enabled nil))

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
  (setq ratex--preview-enabled (and ratex-edit-preview-posframe t))
  (setq ratex--active-fragment (ratex-fragment-at-point))
  (when ratex--active-fragment
    (ratex-remove-overlay (ratex--fragment-key ratex--active-fragment))))

(defun ratex-handle-post-command ()
  "Update previews only when point enters/leaves math fragments."
  (when ratex-mode
    (when (ratex--preview-enabled-p)
      (ratex--update-posframe-position))
    (let ((current (ratex--active-fragment-at-point))
          (previous ratex--active-fragment))
      (unless (and previous current
                   (ratex--same-active-context-p previous current))
        (when previous
          (ratex--ensure-fragment-preview previous)))
      (when current
        (ratex-remove-overlay (ratex--fragment-key current)))
      (when (ratex--preview-enabled-p)
        (ratex--handle-preview-at-point current))
      (setq ratex--active-fragment current))))

(defun ratex--handle-preview-at-point (fragment)
  "Show posframe preview for FRAGMENT when enabled; otherwise hide it."
  (if (and fragment (ratex--preview-enabled-p))
      (let* ((image (ratex--overlay-image-for-fragment fragment))
             (cached (unless image (ratex--cached-response-for-fragment fragment))))
        (ratex-remove-overlay (ratex--fragment-key fragment))
        (unless (ratex--display-posframe fragment cached image)
          (ratex--ensure-fragment-preview fragment))
        (ratex--update-posframe-position))
    (ratex--hide-posframe)))

(defun ratex--overlay-image-for-fragment (fragment)
  "Return cached overlay image for FRAGMENT, or nil."
  (let ((key (ratex--fragment-key fragment)))
    (ratex-overlay-image-for-key key)))

(defun ratex--cached-response-for-fragment (fragment)
  "Return cached backend response for FRAGMENT, or nil."
  (let ((cache-key (ratex--cache-key fragment)))
    (when (hash-table-p ratex--render-cache)
      (gethash cache-key ratex--render-cache))))

(defun ratex--image-from-response (response)
  "Build an image object from backend RESPONSE."
  (let* ((svg (alist-get 'svg response))
         (baseline (or (alist-get 'baseline response) 0.0))
         (height (max 0.001 (or (alist-get 'height response) 0.0))))
    (when svg
      (create-image
       svg
       'svg t
       :ascent (floor (* 100.0 (/ baseline height)))))))

(defun ratex--active-fragment-at-point ()
  "Return editable fragment at point, including rendered overlay fallback."
  (or (ratex-fragment-at-point)
      (ratex-overlay-fragment-at-point)
      (when (ratex--point-in-fragment-p ratex--active-fragment)
        ratex--active-fragment)))

(defun ratex--point-in-fragment-p (fragment)
  "Return non-nil if point is within FRAGMENT."
  (when fragment
    (let ((begin (plist-get fragment :begin))
          (end (plist-get fragment :end)))
      (and (integer-or-marker-p begin)
           (integer-or-marker-p end)
           (<= begin (point))
           (< (point) end)))))


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
        ratex-svg-padding
        (ratex--normalized-render-color)))

(defun ratex--normalized-render-color ()
  "Return a normalized render color string, or nil."
  (let ((value ratex-render-color))
    (when (stringp value)
      (let ((trimmed (string-trim value)))
        (unless (string-empty-p trimmed)
          trimmed)))))

(defun ratex--inflight-table ()
  "Return request-tracking table for current buffer."
  (unless (hash-table-p ratex--inflight-requests)
    (setq-local ratex--inflight-requests (make-hash-table :test #'equal)))
  ratex--inflight-requests)

(defun ratex--inflight-waiters-table ()
  "Return waiter table for in-flight requests in current buffer."
  (unless (hash-table-p ratex--inflight-waiters)
    (setq-local ratex--inflight-waiters (make-hash-table :test #'equal)))
  ratex--inflight-waiters)

(defun ratex--enqueue-waiter (cache-key fragment-key fragment)
  "Track FRAGMENT for CACHE-KEY while backend render is in flight."
  (let* ((table (ratex--inflight-waiters-table))
         (waiters (gethash cache-key table)))
    (unless (assoc fragment-key waiters)
      (puthash cache-key
               (cons (cons fragment-key fragment) waiters)
               table))))

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
     (inflight
      (ratex--enqueue-waiter cache-key fragment-key fragment))
     (t
      (ratex--enqueue-waiter cache-key fragment-key fragment)
      (puthash cache-key t (ratex--inflight-table))
      (ratex-request
       `((type . "render")
         (latex . ,(string-trim (plist-get fragment :content)))
         (font_size . ,ratex-font-size)
         (padding . ,ratex-svg-padding)
         (color . ,(ratex--normalized-render-color))
         (embed_glyphs . t))
       (lambda (response)
         (remhash cache-key (ratex--inflight-table))
         (let ((waiters (gethash cache-key (ratex--inflight-waiters-table))))
           (remhash cache-key (ratex--inflight-waiters-table))
      (when (alist-get 'ok response)
        (puthash cache-key response ratex--render-cache))
           (when ratex-mode
             (dolist (entry waiters)
               (ratex--display-if-visible
                (car entry)
                (cdr entry)
                response))))))))))

(defun ratex--display-if-visible (fragment-key fragment response)
  "Display RESPONSE for FRAGMENT-KEY if FRAGMENT should still be visible."
  (let ((active (ratex--active-fragment-at-point)))
    (cond
     ((not (ratex--fragment-valid-p fragment))
      (ratex-remove-overlay fragment-key))
     ((and active (ratex--same-active-context-p fragment active))
      (if (ratex--preview-enabled-p)
          (progn
            (ratex-remove-overlay fragment-key)
            (unless (ratex--display-posframe fragment response)
              (ratex--ensure-fragment-preview fragment)))
        (ratex-remove-overlay fragment-key)))
     (t
      (ratex--display-response fragment-key fragment response 'inline)))))

(defun ratex--display-response (fragment-key fragment response &optional style)
  "Display backend RESPONSE for FRAGMENT identified by FRAGMENT-KEY."
  (if (not (alist-get 'ok response))
      (progn
        (setq ratex--last-error (alist-get 'error response))
        (ratex-remove-overlay fragment-key)
        (when ratex--last-error
          (message "RaTeX render failed: %s" ratex--last-error)))
    (let ((image (ratex--image-from-response response)))
      (setq ratex--last-error nil)
      (if (and (ratex--preview-enabled-p)
               (ratex--point-in-fragment-p fragment))
          (progn
            (ratex-remove-overlay fragment-key)
            (ratex--display-posframe fragment response image))
        (ratex-show-overlay
         fragment-key
         (plist-get fragment :begin)
         (plist-get fragment :end)
         image
         (format "RaTeX %s" (if (alist-get 'cached response) "cached" "rendered"))
         fragment
         (or style 'inline))))))

(defun ratex-edit-preview-posframe-enabled-p ()
  "Return non-nil when posframe previews are enabled."
  (and ratex-edit-preview-posframe
       (ratex--ensure-posframe-loaded)))

(defun ratex--preview-enabled-p ()
  "Return non-nil when the preview toggle and posframe are enabled."
  (and ratex--preview-enabled
       (ratex-edit-preview-posframe-enabled-p)))

(defun ratex--ensure-posframe-loaded ()
  "Return non-nil when posframe is available; load it if needed."
  (or (featurep 'posframe)
      (require 'posframe nil t)))

(defun ratex--display-posframe (fragment &optional response image)
  "Display IMAGE (or RESPONSE) in a posframe for FRAGMENT."
  (when (and (ratex-edit-preview-posframe-enabled-p)
             (featurep 'posframe)
             (fboundp 'posframe-workable-p)
             (posframe-workable-p)
             (ratex--point-in-fragment-p fragment))
    (let ((image (or image (and response (ratex--image-from-response response)))))
      (when image
        (with-current-buffer (get-buffer-create ratex--posframe-buffer)
          (erase-buffer)
          (insert (propertize " " 'display image)))
        (posframe-show
         ratex--posframe-buffer
         :position (point)
         :poshandler (or ratex-posframe-poshandler
                         #'ratex-posframe-poshandler-point-bottom-left-corner-offset)
         :border-width 1
         :border-color ratex-posframe-border-color
         :background-color ratex-posframe-background-color)
        (setq ratex--posframe-visible t)
        (setq ratex--posframe-fragment fragment)
        t))))

(defun ratex-posframe-poshandler-point-bottom-left-corner-offset (info)
  "Position posframe 5px below `posframe-poshandler-point-bottom-left-corner`."
  (let* ((base (posframe-poshandler-point-bottom-left-corner info))
         (x (car base))
         (y (cdr base)))
    (cons x (+ y ratex--posframe-offset-y))))

(defun ratex--hide-posframe ()
  "Hide the posframe preview."
  (when (featurep 'posframe)
    (when ratex--posframe-visible
      (posframe-hide ratex--posframe-buffer))
    (setq ratex--posframe-visible nil)
    (setq ratex--posframe-fragment nil)))

(defun ratex--update-posframe-position ()
  "Keep posframe aligned with point while editing."
  (when (and ratex--posframe-visible
             (ratex-edit-preview-posframe-enabled-p)
             (featurep 'posframe)
             (fboundp 'posframe-workable-p)
             (posframe-workable-p))
    (if (ratex--point-in-fragment-p ratex--posframe-fragment)
        (posframe-show
         ratex--posframe-buffer
         :position (point)
         :poshandler (or ratex-posframe-poshandler
                         #'ratex-posframe-poshandler-point-bottom-left-corner-offset)
         :border-width 1
         :border-color ratex-posframe-border-color
         :background-color ratex-posframe-background-color)
      (ratex--hide-posframe))))

(defun ratex-toggle-preview-at-point ()
  "Toggle the RaTeX posframe preview for the formula at point."
  (interactive)
  (when (ratex-edit-preview-posframe-enabled-p)
    (setq ratex--preview-enabled (not ratex--preview-enabled))
    (if ratex--preview-enabled
        (ratex--handle-preview-at-point (ratex--active-fragment-at-point))
      (ratex--hide-posframe)
      (let ((fragment (ratex--active-fragment-at-point)))
        (when fragment
          (ratex--ensure-fragment-preview fragment))))))

(defun ratex-handle-buffer-switch ()
  "Clear previews for all ratex buffers when switching buffers."
  (when ratex-edit-preview-posframe
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when ratex-mode
          (ratex--hide-posframe))))))

(provide 'ratex-render)

;;; ratex-render.el ends here
