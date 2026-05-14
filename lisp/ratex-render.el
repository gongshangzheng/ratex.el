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
(defvar ratex-edit-preview)
(defvar ratex-font-dir)
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
(defvar-local ratex--minibuffer-visible nil)
(defvar-local ratex--minibuffer-fragment nil)
(defvar-local ratex--minibuffer-image nil)
(defvar-local ratex--preview-enabled nil)
(defvar-local ratex--refresh-timer nil)
(defvar-local ratex--refresh-scan-timer nil)
(defvar-local ratex--refresh-queue nil)
(defvar-local ratex--refresh-generation 0)
(defconst ratex--posframe-buffer " *ratex-preview*")
(defconst ratex--posframe-offset-y 5)
(defconst ratex--refresh-batch-size 50)

(defun ratex-reset-buffer-state ()
  "Reset buffer-local rendering state."
  (setq-local ratex--render-cache (make-hash-table :test #'equal))
  (setq-local ratex--inflight-requests (make-hash-table :test #'equal))
  (setq-local ratex--inflight-waiters (make-hash-table :test #'equal))
  (setq-local ratex--last-error nil)
  (setq-local ratex--active-fragment nil)
  (setq-local ratex--posframe-visible nil)
  (setq-local ratex--posframe-fragment nil)
  (setq-local ratex--minibuffer-visible nil)
  (setq-local ratex--minibuffer-fragment nil)
  (setq-local ratex--minibuffer-image nil)
  (setq-local ratex--preview-enabled nil)
  (ratex--cancel-refresh-timer)
  (setq-local ratex--refresh-queue nil)
  (setq-local ratex--refresh-generation 0))

(defun ratex-refresh-previews (&optional include-active)
  "Refresh math previews in current buffer.

When INCLUDE-ACTIVE is non-nil, render all formulas, including the one
currently under point."
  (interactive)
  (ratex--cancel-refresh-timer)
  (cl-incf ratex--refresh-generation)
  (let* ((fragments (ratex--visible-fragments))
         (active (ratex-fragment-at-point))
         (targets (if include-active
                      fragments
                    (ratex--fragments-to-render fragments active))))
    (ratex--enqueue-refresh-targets targets)
    (ratex--schedule-full-refresh-scan include-active ratex--refresh-generation)))

(defun ratex-initialize-previews ()
  "Render all formulas once and initialize point tracking."
  (ratex-refresh-previews t)
  (setq ratex--preview-enabled (and (ratex--preview-style) t))
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

(defun ratex--visible-fragments ()
  "Return fragments in the visible portion of the selected window."
  (let* ((window (selected-window))
         (beg (max (point-min) (window-start window)))
         (end (min (point-max) (window-end window t))))
    (ratex-fragments-in-buffer beg end)))

(defun ratex--enqueue-refresh-targets (targets)
  "Render TARGETS in bounded batches."
  (let ((generation ratex--refresh-generation)
        (first-batch (seq-take targets ratex--refresh-batch-size))
        (rest (nthcdr ratex--refresh-batch-size targets)))
    (setq ratex--refresh-queue rest)
    (dolist (fragment first-batch)
      (ratex--ensure-fragment-preview fragment))
    (when ratex--refresh-queue
      (ratex--schedule-refresh-batch generation))))

(defun ratex--schedule-refresh-batch (generation)
  "Schedule the next refresh batch for GENERATION."
  (setq ratex--refresh-timer
        (run-with-idle-timer
         0.05 nil
         (lambda (buffer)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (ratex--run-refresh-batch generation))))
         (current-buffer))))

(defun ratex--schedule-full-refresh-scan (include-active generation)
  "Schedule a full-buffer scan for INCLUDE-ACTIVE and GENERATION."
  (setq ratex--refresh-scan-timer
        (run-with-idle-timer
         0.2 nil
         (lambda (buffer)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (ratex--run-full-refresh-scan include-active generation))))
         (current-buffer))))

(defun ratex--run-full-refresh-scan (include-active generation)
  "Scan the whole buffer and enqueue remaining previews."
  (setq ratex--refresh-scan-timer nil)
  (when (and ratex-mode (= generation ratex--refresh-generation))
    (let* ((fragments (ratex-fragments-in-buffer))
           (active (ratex-fragment-at-point))
           (targets (if include-active
                        fragments
                      (ratex--fragments-to-render fragments active)))
           (target-keys (mapcar #'ratex--fragment-key targets)))
      (ratex--drop-stale-overlays target-keys)
      (ratex--enqueue-refresh-targets targets))))

(defun ratex--run-refresh-batch (generation)
  "Render one queued refresh batch for GENERATION."
  (setq ratex--refresh-timer nil)
  (when (and ratex-mode
             (= generation ratex--refresh-generation)
             ratex--refresh-queue)
    (let ((batch (seq-take ratex--refresh-queue ratex--refresh-batch-size)))
      (setq ratex--refresh-queue (nthcdr ratex--refresh-batch-size ratex--refresh-queue))
      (dolist (fragment batch)
        (ratex--ensure-fragment-preview fragment))
      (when ratex--refresh-queue
        (ratex--schedule-refresh-batch generation)))))

(defun ratex--cancel-refresh-timer ()
  "Cancel the current refresh timer, if any."
  (when (timerp ratex--refresh-timer)
    (cancel-timer ratex--refresh-timer))
  (when (timerp ratex--refresh-scan-timer)
    (cancel-timer ratex--refresh-scan-timer))
  (setq ratex--refresh-timer nil)
  (setq ratex--refresh-scan-timer nil))

(defun ratex--handle-preview-at-point (fragment)
  "Show edit preview for FRAGMENT when enabled; otherwise hide it."
  (if (and fragment (ratex--preview-enabled-p))
      (let* ((image (ratex--overlay-image-for-fragment fragment))
             (cached (unless image (ratex--cached-response-for-fragment fragment)))
             (style (ratex--preview-style)))
        (ratex-remove-overlay (ratex--fragment-key fragment))
        (pcase style
          ('posframe
           (unless (ratex--display-posframe fragment cached image)
             (ratex--ensure-fragment-preview fragment))
           (ratex--update-posframe-position))
          ('minibuffer
           (unless (ratex--display-minibuffer fragment cached image)
             (ratex--redisplay-minibuffer-preview)
             (ratex--ensure-fragment-preview fragment)))
          (_
           (ratex--ensure-fragment-preview fragment))))
    (ratex--hide-edit-preview)))

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

(defun ratex--preview-image-from-response (response)
  "Build a preview image from backend RESPONSE, including errors."
  (if (ratex--response-ok-p response)
      (ratex--image-from-response response)
    (ratex--error-image (alist-get 'error response))))

(defun ratex--response-ok-p (response)
  "Return non-nil when backend RESPONSE is successful."
  (eq (alist-get 'ok response) t))

(defun ratex--escape-svg-text (text)
  "Escape TEXT for use inside SVG character data."
  (replace-regexp-in-string
   "[&<>\"]"
   (lambda (match)
     (pcase match
       ("&" "&amp;")
       ("<" "&lt;")
       (">" "&gt;")
       ("\"" "&quot;")))
   (or text "")
   t t))

(defun ratex--error-svg (error)
  "Return an SVG image that displays ERROR."
  (let* ((raw-text (or error "unknown error"))
         (font-size 13)
         (padding-x 8)
         (padding-y 5)
         (max-chars 96)
         (shown (if (> (length raw-text) max-chars)
                    (concat (substring raw-text 0 (- max-chars 3)) "...")
                  raw-text))
         (text (ratex--escape-svg-text shown))
         (width (+ (* 8 (max 1 (length shown))) (* 2 padding-x)))
         (height (+ font-size (* 2 padding-y))))
    (format
     "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\"><rect width=\"100%%\" height=\"100%%\" fill=\"#fff59d\"/><text x=\"%d\" y=\"%d\" fill=\"#c00000\" font-family=\"monospace\" font-size=\"%d\">%s</text></svg>"
     width height width height padding-x (+ padding-y font-size -2) font-size text)))

(defun ratex--error-image (error)
  "Build an image object that displays ERROR."
  (create-image (ratex--error-svg error) 'svg t :ascent 80))

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
        (ratex--normalized-render-color)
        (ratex--normalized-font-dir)))

(defun ratex--normalized-render-color ()
  "Return a normalized render color string, or nil."
  (let ((value ratex-render-color))
    (when (stringp value)
      (let ((trimmed (string-trim value)))
        (unless (string-empty-p trimmed)
          trimmed)))))

(defun ratex--normalized-font-dir ()
  "Return normalized font directory for cache keys, or nil."
  (when ratex-font-dir
    (expand-file-name ratex-font-dir)))

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

(defun ratex--render-payload (fragment)
  "Build the render request payload for FRAGMENT."
  (let ((payload `((type . "render")
                   (latex . ,(string-trim (plist-get fragment :content)))
                   (font_size . ,ratex-font-size)
                   (padding . ,ratex-svg-padding)
                   (color . ,(ratex--normalized-render-color))
                   (embed_glyphs . t))))
    (when ratex-font-dir
      (nconc payload `((font_dir . ,(expand-file-name ratex-font-dir)))))
    payload))

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
       (ratex--render-payload fragment)
       (lambda (response)
         (remhash cache-key (ratex--inflight-table))
         (let ((waiters (gethash cache-key (ratex--inflight-waiters-table))))
           (remhash cache-key (ratex--inflight-waiters-table))
           (when (ratex--response-ok-p response)
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
            (unless (ratex--display-edit-preview fragment response)
              (ratex--ensure-fragment-preview fragment)))
        (ratex-remove-overlay fragment-key)))
     (t
      (ratex--display-response fragment-key fragment response 'inline)))))

(defun ratex--display-response (fragment-key fragment response &optional style)
  "Display backend RESPONSE for FRAGMENT identified by FRAGMENT-KEY."
  (if (not (ratex--response-ok-p response))
      (progn
        (setq ratex--last-error (alist-get 'error response))
        (ratex-show-overlay
         fragment-key
         (plist-get fragment :begin)
         (plist-get fragment :end)
         (ratex--error-image ratex--last-error)
         (format "RaTeX render failed: %s" ratex--last-error)
         fragment
         (or style 'inline))
        (when ratex--last-error
          (message "RaTeX render failed: %s" ratex--last-error)))
    (let ((image (ratex--image-from-response response)))
      (setq ratex--last-error nil)
      (if (and (ratex--preview-enabled-p)
               (ratex--point-in-fragment-p fragment))
          (progn
            (ratex-remove-overlay fragment-key)
            (ratex--display-edit-preview fragment response image))
        (ratex-show-overlay
         fragment-key
         (plist-get fragment :begin)
         (plist-get fragment :end)
         image
         (format "RaTeX %s" (if (alist-get 'cached response) "cached" "rendered"))
         fragment
         (or style 'inline))))))

(defun ratex--display-edit-preview (fragment &optional response image)
  "Display RESPONSE or IMAGE using the active edit preview style for FRAGMENT."
  (pcase (ratex--preview-style)
    ('posframe
     (ratex--display-posframe fragment response image))
    ('minibuffer
     (ratex--display-minibuffer fragment response image))
    (_ nil)))



(defun ratex--preview-enabled-p ()
  "Return non-nil when the preview toggle and posframe are enabled."
  (and ratex--preview-enabled
       (ratex--preview-style)))

(defun ratex--preview-style ()
  "Return active edit preview style or nil."
  ratex-edit-preview)

(defun ratex--ensure-posframe-loaded ()
  "Return non-nil when posframe is available; load it if needed."
  (or (featurep 'posframe)
      (require 'posframe nil t)))

(defun ratex--display-posframe (fragment &optional response image)
  "Display IMAGE (or RESPONSE) in a posframe for FRAGMENT."
  (when (and (eq (ratex--preview-style) 'posframe)
             (ratex--ensure-posframe-loaded)
             (featurep 'posframe)
             (fboundp 'posframe-workable-p)
             (posframe-workable-p)
             (ratex--point-in-fragment-p fragment))
    (let ((image (or image (and response (ratex--preview-image-from-response response)))))
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

(defun ratex--display-minibuffer (fragment &optional response image)
  "Display IMAGE (or RESPONSE) in the minibuffer for FRAGMENT."
  (when (ratex--point-in-fragment-p fragment)
    (let ((image (or image (and response (ratex--preview-image-from-response response)))))
      (when image
        (ratex--replace-minibuffer-preview fragment image)
        t))))

(defun ratex--replace-minibuffer-preview (fragment image)
  "Replace the minibuffer preview for FRAGMENT with IMAGE."
  (message "%s" (propertize " " 'display image))
  (setq ratex--minibuffer-visible t)
  (setq ratex--minibuffer-fragment fragment)
  (setq ratex--minibuffer-image image)
  t)

(defun ratex--redisplay-minibuffer-preview ()
  "Redisplay the last minibuffer preview image, if any."
  (when (and ratex--minibuffer-visible ratex--minibuffer-image)
    (message "%s" (propertize " " 'display ratex--minibuffer-image))
    t))

(defun ratex--hide-minibuffer ()
  "Hide minibuffer preview if visible."
  (when ratex--minibuffer-visible
    (message nil)
    (setq ratex--minibuffer-visible nil)
    (setq ratex--minibuffer-fragment nil)
    (setq ratex--minibuffer-image nil)))

(defun ratex--hide-edit-preview ()
  "Hide whichever edit preview is active."
  (ratex--hide-posframe)
  (ratex--hide-minibuffer))

(defun ratex--update-posframe-position ()
  "Keep posframe aligned with point while editing."
  (when (and ratex--posframe-visible
             (eq (ratex--preview-style) 'posframe)
             (ratex--ensure-posframe-loaded)
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

(defun ratex--update-minibuffer-preview ()
  "Keep minibuffer preview visible while point stays inside fragment."
  (when ratex--minibuffer-visible
    (unless (ratex--point-in-fragment-p ratex--minibuffer-fragment)
      (ratex--hide-minibuffer))))

(defun ratex-toggle-preview-at-point ()
  "Toggle the RaTeX posframe preview for the formula at point."
  (interactive)
  (when (ratex--preview-style)
    (setq ratex--preview-enabled (not ratex--preview-enabled))
    (if ratex--preview-enabled
        (ratex--handle-preview-at-point (ratex--active-fragment-at-point))
      (ratex--hide-edit-preview)
      (let ((fragment (ratex--active-fragment-at-point)))
        (when fragment
          (ratex--ensure-fragment-preview fragment))))))

(defun ratex-handle-buffer-switch ()
  "Clear previews for all ratex buffers when switching buffers."
  (when (ratex--preview-style)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when ratex-mode
          (ratex--hide-edit-preview))))))

(provide 'ratex-render)

;;; ratex-render.el ends here
