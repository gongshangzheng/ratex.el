;;; ratex-render.el --- Async rendering client -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ratex-core)
(require 'ratex-math-detect)
(require 'ratex-overlays)
;; posframe is optional; load it dynamically when enabled.

(defvar ratex-mode)
(defvar text-scale-mode)
(defvar text-scale-mode-step)
(defvar text-scale-mode-amount)

(defgroup ratex nil
  "Inline maths rendering with RaTeX."
  :group 'tex)

(defcustom ratex-font-size 16.0
  "Default backend SVG font size."
  :type 'number)

(defcustom ratex-svg-padding 2.0
  "Default SVG padding sent to the backend."
  :type 'number)

(defcustom ratex-font-dir nil
  "Directory containing KaTeX .ttf font files."
  :type '(choice (const :tag "Auto detect" nil) directory))

(defcustom ratex-edit-preview nil
  "Preview style used while editing formulae."
  :type '(choice (const :tag "Disable" nil)
                 (const :tag "Posframe" posframe)
                 (const :tag "Minibuffer" minibuffer)))

(defcustom ratex-render-color nil
  "Override formula colour sent to backend rendering."
  :type '(choice (const :tag "Backend default" nil) string))

(defcustom ratex-dark-render-color "white"
  "Formula colour used when the current frame uses a dark background."
  :type '(choice (const :tag "Backend default" nil) string))

(defcustom ratex-light-render-color "black"
  "Formula colour used when the current frame uses a light background."
  :type '(choice (const :tag "Backend default" nil) string))

(defcustom ratex-posframe-background-color nil
  "Override background colour for RaTeX posframe preview."
  :type '(choice (const :tag "Theme aware default" nil) string))

(defcustom ratex-dark-posframe-background-color "black"
  "Posframe background colour used when the current frame uses a dark background."
  :type '(choice (const :tag "Theme default" nil) string))

(defcustom ratex-light-posframe-background-color "white"
  "Posframe background colour used when the current frame uses a light background."
  :type '(choice (const :tag "Theme default" nil) string))

(defcustom ratex-posframe-border-color "gray70"
  "Border colour for RaTeX posframe preview."
  :type 'string)

(defcustom ratex-posframe-poshandler
  'ratex-posframe-poshandler-point-bottom-left-corner-offset
  "Poshandler function used to place the RaTeX posframe preview."
  :type 'function)

(defcustom ratex-theme-change-refresh-scope 'all
  "How RaTeX refreshes previews after a theme change."
  :type '(choice (const :tag "Refresh all RaTeX buffers" all)
                 (const :tag "Refresh current buffer only" current)
                 (const :tag "Do not refresh automatically" nil)))
(defcustom ratex-render-cache-size 256
  "Maximum number of rendered formulas cached per buffer.
Least recently used entries are evicted beyond this bound."
  :type 'natnum)

(defcustom ratex-visible-render-chunk 12
  "Number of formulas rendered per idle turn.
Larger values make each idle turn longer but drain a screen faster."
  :type 'natnum)

(defvar-local ratex--render-cache nil
  "Hash table mapping render cache keys to successful backend responses.")
(defvar-local ratex--image-cache nil
  "Hash table mapping render cache keys to per-scale image objects.")
(defvar-local ratex--cache-order nil
  "Render cache keys ordered from most to least recently used.")
(defvar-local ratex--inflight-requests nil)
(defvar-local ratex--inflight-waiters nil)
(defvar-local ratex--last-error nil)
(defvar-local ratex--last-message nil)
(defvar-local ratex--active-fragment nil)
(defvar-local ratex--posframe-visible nil)
(defvar-local ratex--posframe-fragment nil)
(defvar-local ratex--minibuffer-visible nil)
(defvar-local ratex--minibuffer-fragment nil)
(defvar-local ratex--minibuffer-image nil)
(defvar-local ratex--preview-enabled nil)
(defvar-local ratex--refresh-timer nil)
(defvar-local ratex--refresh-continue-timer nil)
(defvar-local ratex--refresh-generation 0)
(defvar-local ratex--visible-queue nil)
(defvar-local ratex--pending-window nil)
(defvar-local ratex--last-rendered-range nil)
(defvar-local ratex--last-point nil)
(defvar-local ratex--last-window-start nil)
(defvar-local ratex--last-tick nil)
(defvar-local ratex--pruned-tick nil)
(defvar-local ratex--buffer-render-timer nil)
(defvar-local ratex--buffer-render-queue nil)
(defvar-local ratex--buffer-render-tick nil)
(defvar-local ratex--buffer-render-generation 0)
(defvar ratex--theme-refresh-timer nil)
(defvar ratex--posframe-warning-shown nil)
(defconst ratex--posframe-buffer " *ratex-preview*")
(defconst ratex--posframe-offset-y 5)

(defun ratex-reset-buffer-state ()
  "Reset buffer-local rendering state."
  (ratex-cancel-render-buffer t)
  (ratex--cancel-refresh-timers)
  (setq-local ratex--render-cache (make-hash-table :test #'equal))
  (setq-local ratex--image-cache (make-hash-table :test #'equal))
  (setq-local ratex--cache-order nil)
  (setq-local ratex--inflight-requests (make-hash-table :test #'equal))
  (setq-local ratex--inflight-waiters (make-hash-table :test #'equal))
  (setq-local ratex--last-error nil)
  (setq-local ratex--last-message nil)
  (setq-local ratex--active-fragment nil)
  (setq-local ratex--posframe-visible nil)
  (setq-local ratex--posframe-fragment nil)
  (setq-local ratex--minibuffer-visible nil)
  (setq-local ratex--minibuffer-fragment nil)
  (setq-local ratex--minibuffer-image nil)
  (setq-local ratex--preview-enabled nil)
  (setq-local ratex--visible-queue nil)
  (setq-local ratex--pending-window nil)
  (setq-local ratex--last-rendered-range nil)
  (setq-local ratex--last-point nil)
  (setq-local ratex--last-window-start nil)
  (setq-local ratex--last-tick nil)
  (setq-local ratex--pruned-tick nil)
  (setq-local ratex--refresh-generation 0)
  (setq-local ratex--buffer-render-generation 0))

(defun ratex-refresh-previews (&optional include-active)
  "Render the formulas visible in the selected window.

With INCLUDE-ACTIVE non-nil, also render the formula at point.  Formulas
outside the visible window are left alone; use `ratex-render-buffer' to
render the whole buffer."
  (interactive)
  (ratex--cancel-refresh-timers)
  (ratex--prune-invalid-overlays)
  (let* ((window (selected-window))
         (active (unless include-active (ratex--active-fragment-at-point)))
         (targets (cl-remove-if
                   (lambda (fragment)
                     (or (and active (ratex--context-equal-p fragment active))
                         (ratex--fragment-rendered-p fragment)))
                   (ratex--visible-fragments window))))
    (setq ratex--last-rendered-range (ratex--window-range window))
    (ratex--start-visible-queue targets)))

(defun ratex-initialize-previews ()
  "Render all formulas once and initialize point tracking."
  (ratex-refresh-previews t)
  (setq ratex--preview-enabled (and (ratex--preview-style) t))
  (setq ratex--active-fragment (ratex-fragment-at-point))
  (when ratex--active-fragment
    (ratex-remove-overlay (ratex--fragment-key ratex--active-fragment))))

(defun ratex-handle-post-command ()
  "Sync the edit preview and schedule rendering after a command.

Only commands that actually changed point, the window start or the buffer
text do any work, so repeated commands stay free."
  (when ratex-mode
    (let ((tick (buffer-chars-modified-tick))
          (start (window-start))
          (position (point)))
      (unless (and (eq tick ratex--last-tick)
                   (eq start ratex--last-window-start)
                   (eq position ratex--last-point))
        (setq ratex--last-tick tick)
        (setq ratex--last-window-start start)
        (setq ratex--last-point position)
        (when (and ratex--buffer-render-queue
                   (not (eq tick ratex--buffer-render-tick)))
          (ratex-cancel-render-buffer t))
        (ratex--sync-active-fragment)
        (ratex--schedule-visible-render)))))

(defun ratex--sync-active-fragment ()
  "Update the edit preview for the formula at point."
  (when (ratex--preview-enabled-p)
    (ratex--update-posframe-position))
  (let ((current (ratex--active-fragment-at-point))
        (previous ratex--active-fragment))
    (unless (and previous current (ratex--context-equal-p previous current))
      (when previous
        (ratex--ensure-fragment-preview previous))
      (when current
        (ratex-remove-overlay (ratex--fragment-key current))))
    (when (ratex--preview-enabled-p)
      (ratex--handle-preview-at-point current))
    (setq ratex--active-fragment current)))

(defun ratex--refresh-buffer-previews (buffer)
  "Refresh previews in BUFFER when `ratex-mode' is enabled there."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (bound-and-true-p ratex-mode)
        (ratex-refresh-previews t)))))

(defun ratex--run-theme-refresh (origin-buffer scope)
  "Refresh previews after a theme change from ORIGIN-BUFFER using SCOPE."
  (setq ratex--theme-refresh-timer nil)
  (pcase scope
    ('all
     (dolist (buffer (buffer-list))
       (ratex--refresh-buffer-previews buffer)))
    ('current
     (ratex--refresh-buffer-previews origin-buffer))))

(defun ratex--schedule-theme-refresh (&rest _args)
  "Schedule a RaTeX refresh after a theme change."
  (when (timerp ratex--theme-refresh-timer)
    (cancel-timer ratex--theme-refresh-timer))
  (when ratex-theme-change-refresh-scope
    (setq ratex--theme-refresh-timer
          (run-with-idle-timer
           0.1 nil
           #'ratex--run-theme-refresh
           (current-buffer)
           ratex-theme-change-refresh-scope))))

(defun ratex--window-range (window)
  "Return (START END TICK) describing WINDOW's visible region."
  (list (window-start window)
        (or (window-end window t) (point-max))
        (buffer-chars-modified-tick)))

(defun ratex--visible-fragments (&optional window)
  "Return the fragments visible in WINDOW (default: selected window)."
  (let* ((window (or window (selected-window)))
         (start (window-start window))
         (end (or (window-end window t) (point-max))))
    (ratex-fragments-in-buffer (max (point-min) start) (min (point-max) end))))

(defun ratex--fragment-rendered-p (fragment)
  "Return non-nil when FRAGMENT is displayed with the current render options.

The cache key covers font size, padding, colour and font directory, so a
theme or colour change makes already rendered overlays stale even though
the formula text is unchanged."
  (let* ((key (ratex--fragment-key fragment))
         (overlay (ratex-overlay-for-key key)))
    (and (overlayp overlay)
         (= (overlay-start overlay) (plist-get fragment :begin))
         (= (overlay-end overlay) (plist-get fragment :end))
         (equal (overlay-get overlay 'ratex-scale) ratex--scale)
         (equal (overlay-get overlay 'ratex-cache-key) (ratex--cache-key fragment))
         (overlay-get overlay 'ratex-image))))

(defun ratex--on-window-scroll (window _start)
  "Schedule a render pass after WINDOW scrolled.

`window-end' is not valid here, so this only signals the scheduler; the
range is computed once the idle job runs."
  (ratex--schedule-visible-render window))

(defun ratex--handle-window-buffer-change (window)
  "Hide the edit preview when this buffer stops being shown in WINDOW."
  (unless (eq (window-buffer window) (current-buffer))
    (ratex--hide-edit-preview)))

(defun ratex--schedule-visible-render (&optional window)
  "Schedule one visible-region render pass for WINDOW.

Repeated calls before the pass runs are no-ops, so it is safe to drive
this from more than one trigger."
  (setq ratex--pending-window (or window (selected-window)))
  (unless (timerp ratex--refresh-timer)
    (setq ratex--refresh-timer
          (run-with-idle-timer
           0.03 nil
           (lambda (buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (ratex--render-visible))))
           (current-buffer)))))

(defun ratex--render-visible ()
  "Render the formulas visible in the pending window.

This is the single rendering job of the mode.  It is idempotent: when the
visible range and the buffer text are unchanged since the last pass it
does nothing."
  (setq ratex--refresh-timer nil)
  (when ratex-mode
    (let* ((window (or ratex--pending-window (selected-window)))
           (range (ratex--window-range window)))
      (setq ratex--pending-window nil)
      (unless (equal range ratex--last-rendered-range)
        (setq ratex--last-rendered-range range)
        (let* ((active (ratex--active-fragment-at-point))
               (targets (cl-remove-if
                         (lambda (fragment)
                           (or (and active (ratex--context-equal-p fragment active))
                               (ratex--fragment-rendered-p fragment)))
                         (ratex--visible-fragments window))))
          (ratex--start-visible-queue targets))))))

(defun ratex--start-visible-queue (fragments)
  "Start rendering FRAGMENTS in bounded batches."
  (cl-incf ratex--refresh-generation)
  (setq ratex--visible-queue fragments)
  (ratex--drain-visible-queue ratex--refresh-generation))

(defun ratex--drain-visible-queue (generation)
  "Render one batch of the visible queue for GENERATION."
  (when (and ratex-mode
             (= generation ratex--refresh-generation)
             ratex--visible-queue)
    (let ((batch (seq-take ratex--visible-queue ratex-visible-render-chunk)))
      (setq ratex--visible-queue
            (nthcdr ratex-visible-render-chunk ratex--visible-queue))
      (dolist (fragment batch)
        (ratex--ensure-fragment-preview fragment))
      (when ratex--visible-queue
        (setq ratex--refresh-continue-timer
              (run-with-idle-timer
               0.02 nil
               (lambda (buffer)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq ratex--refresh-continue-timer nil)
                     (ratex--drain-visible-queue generation))))
               (current-buffer)))))))

(defun ratex--prune-invalid-overlays ()
  "Delete overlays whose source text no longer matches."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eq tick ratex--pruned-tick)
      (setq ratex--pruned-tick tick)
      (dolist (key (ratex-overlay-keys))
        (let ((overlay (ratex-overlay-for-key key)))
          (unless (and (overlayp overlay)
                       (ratex--fragment-valid-p
                        (overlay-get overlay 'ratex-fragment)))
            (ratex-remove-overlay key)))))))

(defun ratex--cancel-refresh-timers ()
  "Cancel pending visible-region timers and invalidate running batches."
  (dolist (timer (list ratex--refresh-timer ratex--refresh-continue-timer))
    (when (timerp timer)
      (cancel-timer timer)))
  (setq ratex--refresh-timer nil)
  (setq ratex--refresh-continue-timer nil)
  (setq ratex--visible-queue nil)
  (cl-incf ratex--refresh-generation))

(defun ratex-render-buffer ()
  "Render every formula in the current buffer in the background."
  (interactive)
  (unless ratex-mode
    (user-error "RaTeX mode is not enabled in this buffer"))
  (ratex-cancel-render-buffer t)
  (setq ratex--buffer-render-queue (ratex-fragments-in-buffer))
  (setq ratex--buffer-render-tick (buffer-chars-modified-tick))
  (cl-incf ratex--buffer-render-generation)
  (let ((generation ratex--buffer-render-generation)
        (count (length ratex--buffer-render-queue)))
    (if (zerop count)
        (message "RaTeX: no formulas in this buffer")
      (message "RaTeX: rendering %d formulas" count)
      (ratex--drain-buffer-render generation))))

(defun ratex--drain-buffer-render (generation)
  "Render one batch of the whole-buffer queue for GENERATION."
  (when (and ratex-mode
             (= generation ratex--buffer-render-generation)
             ratex--buffer-render-queue)
    (let ((active (ratex--active-fragment-at-point))
          (batch (seq-take ratex--buffer-render-queue
                           ratex-visible-render-chunk)))
      (setq ratex--buffer-render-queue
            (nthcdr ratex-visible-render-chunk ratex--buffer-render-queue))
      (dolist (fragment batch)
        (unless (and active (ratex--context-equal-p fragment active))
          (ratex--ensure-fragment-preview fragment)))
      (if ratex--buffer-render-queue
          (setq ratex--buffer-render-timer
                (run-with-idle-timer
                 0.02 nil
                 (lambda (buffer)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (setq ratex--buffer-render-timer nil)
                       (ratex--drain-buffer-render generation))))
                 (current-buffer)))
        (message "RaTeX: finished rendering buffer")))))

(defun ratex-cancel-render-buffer (&optional quiet)
  "Cancel a background `ratex-render-buffer' run."
  (interactive)
  (when (timerp ratex--buffer-render-timer)
    (cancel-timer ratex--buffer-render-timer))
  (cl-incf ratex--buffer-render-generation)
  (setq ratex--buffer-render-timer nil)
  (setq ratex--buffer-render-queue nil)
  (setq ratex--buffer-render-tick nil)
  (unless quiet
    (message "RaTeX: cancelled whole-buffer rendering")))

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
  "Build an image object from backend RESPONSE, including error responses."
  (if (ratex--response-ok-p response)
      (let* ((svg (alist-get 'svg response))
             (baseline (or (alist-get 'baseline response) 0.0))
             (height (max 0.001 (or (alist-get 'height response) 0.0))))
        (when svg
          (create-image
           svg
           'svg t
           :ascent (floor (* 100.0 (/ baseline height))))))
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
  "Return the editable fragment at point, including the rendered overlay."
  (or (ratex-fragment-at-point)
      (ratex-overlay-fragment-at-point)))

(defun ratex--fragment-contains-p (fragment position)
  "Return non-nil when POSITION lies inside FRAGMENT."
  (when fragment
    (let ((begin (plist-get fragment :begin))
          (end (plist-get fragment :end)))
      (and (integer-or-marker-p begin)
           (integer-or-marker-p end)
           (<= begin position)
           (< position end)))))

(defun ratex--fragments-to-render (fragments active)
  "Return FRAGMENTS excluding ACTIVE."
  (cl-remove-if
   (lambda (fragment)
     (and active (ratex--fragment-equal-p fragment active)))
   fragments))

(defun ratex--fragment-equal-p (a b)
  "Return non-nil when fragments A and B describe the same range and text."
  (and a b
       (= (plist-get a :begin) (plist-get b :begin))
       (= (plist-get a :end) (plist-get b :end))
       (equal (plist-get a :content) (plist-get b :content))))

(defun ratex--context-equal-p (a b)
  "Return non-nil when A and B belong to the same editing context."
  (and a b
       (or (ratex--fragment-equal-p a b)
           (ratex--fragments-overlap-p a b))))

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
        (ratex--effective-render-color)
        (ratex--normalized-font-dir)))

(defun ratex--normalize-color-value (value)
  "Return VALUE as a trimmed color string, or nil."
  (when (stringp value)
    (let ((trimmed (string-trim value)))
      (unless (string-empty-p trimmed)
        trimmed))))

(defun ratex--background-mode ()
  "Return the current frame background mode."
  (if (eq (frame-parameter nil 'background-mode) 'dark)
      'dark
    'light))

(defun ratex--effective-render-color ()
  "Return the effective render color string, or nil."
  (or (ratex--normalize-color-value ratex-render-color)
      (ratex--normalize-color-value
       (if (eq (ratex--background-mode) 'dark)
           ratex-dark-render-color
         ratex-light-render-color))))

(defun ratex--effective-posframe-background-color ()
  "Return the effective posframe background color string, or nil."
  (or (ratex--normalize-color-value ratex-posframe-background-color)
      (ratex--normalize-color-value
       (if (eq (ratex--background-mode) 'dark)
           ratex-dark-posframe-background-color
         ratex-light-posframe-background-color))))

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
  "Return non-nil when FRAGMENT still matches the buffer text.

Fragments carry the buffer tick they were scanned at; when the text has
not changed since, the substring comparison is skipped."
  (let ((begin (plist-get fragment :begin))
        (end (plist-get fragment :end))
        (open (plist-get fragment :open))
        (content (plist-get fragment :content))
        (close (plist-get fragment :close))
        (tick (plist-get fragment :tick)))
    (and (integer-or-marker-p begin)
         (integer-or-marker-p end)
         (<= (point-min) begin end (point-max))
         (or (and tick (eq tick (buffer-chars-modified-tick)))
             (string= (buffer-substring-no-properties begin end)
                      (concat open content close))))))

(defun ratex--render-payload (fragment)
  "Build the render request payload for FRAGMENT."
  (let ((payload `((type . "render")
                   (latex . ,(string-trim (plist-get fragment :content)))
                   (font_size . ,ratex-font-size)
                   (padding . ,ratex-svg-padding)
                   (color . ,(ratex--effective-render-color))
                   (embed_glyphs . t))))
    (when ratex-font-dir
      (nconc payload `((font_dir . ,(expand-file-name ratex-font-dir)))))
    payload))

(defun ratex--render-cache-table ()
  "Return the render cache table for the current buffer."
  (unless (hash-table-p ratex--render-cache)
    (setq-local ratex--render-cache (make-hash-table :test #'equal)))
  ratex--render-cache)

(defun ratex--image-cache-table ()
  "Return the image cache table for the current buffer."
  (unless (hash-table-p ratex--image-cache)
    (setq-local ratex--image-cache (make-hash-table :test #'equal)))
  ratex--image-cache)

(defun ratex--cache-store (cache-key response)
  "Store RESPONSE under CACHE-KEY, evicting the least recently used entry."
  (puthash cache-key response (ratex--render-cache-table))
  (ratex--cache-touch cache-key)
  (while (and (> (length ratex--cache-order) ratex-render-cache-size)
              ratex--cache-order)
    (let ((evicted (car (last ratex--cache-order))))
      (setq ratex--cache-order (nbutlast ratex--cache-order))
      (remhash evicted (ratex--render-cache-table))
      (remhash evicted (ratex--image-cache-table))
      (let ((waiters (ratex--inflight-waiters-table)))
        (remhash evicted waiters)))))

(defun ratex--cache-touch (cache-key)
  "Mark CACHE-KEY as the most recently used entry."
  (setq ratex--cache-order (cons cache-key (delete cache-key ratex--cache-order))))

(defun ratex--image-for-response (cache-key response)
  "Return the cached image for RESPONSE under CACHE-KEY at the current scale."
  (let ((table (ratex--image-cache-table)))
    (or (cdr (assoc ratex--scale (gethash cache-key table)))
        (let ((image (ratex--image-from-response response)))
          (when image
            (puthash cache-key
                     (cons (cons ratex--scale image) (gethash cache-key table))
                     table)
            image)))))

(defun ratex--notify-error (text)
  "Message TEXT once per distinct failure to avoid flooding the echo area."
  (unless (equal text ratex--last-message)
    (setq ratex--last-message text)
    (message "RaTeX: %s" text)))

(defun ratex--ensure-fragment-preview (fragment)
  "Ensure FRAGMENT preview is displayed or requested."
  (let* ((cache-key (ratex--cache-key fragment))
         (cached (gethash cache-key (ratex--render-cache-table)))
         (inflight (gethash cache-key (ratex--inflight-table))))
    (cond
     ((not (ratex--fragment-valid-p fragment))
      (ratex-remove-overlay (ratex--fragment-key fragment)))
     (cached
      (ratex--cache-touch cache-key)
      (ratex--show-fragment fragment cached))
     (inflight
      (ratex--enqueue-waiter cache-key (ratex--fragment-key fragment) fragment))
     (t
      (ratex--enqueue-waiter cache-key (ratex--fragment-key fragment) fragment)
      (puthash cache-key t (ratex--inflight-table))
      (ratex-request
       (ratex--render-payload fragment)
       (lambda (response)
         (remhash cache-key (ratex--inflight-table))
         (let ((waiters (gethash cache-key (ratex--inflight-waiters-table))))
           (remhash cache-key (ratex--inflight-waiters-table))
           (when (ratex--response-ok-p response)
             (ratex--cache-store cache-key response))
           (when ratex-mode
             (dolist (entry waiters)
               (ratex--display-if-visible
                (car entry)
                (cdr entry)
                response))))))))))

(defun ratex--display-if-visible (_fragment-key fragment response)
  "Display RESPONSE for FRAGMENT when it is still current."
  (when (buffer-live-p (current-buffer))
    (ratex--show-fragment fragment response)))

(defun ratex--show-fragment (fragment response)
  "Display RESPONSE for FRAGMENT according to the current preview state.

This is the only place that decides between inline rendering, the edit
preview surface, and removing the overlay."
  (let ((key (ratex--fragment-key fragment))
        (active (ratex--active-fragment-at-point)))
    (cond
     ((not (ratex--fragment-valid-p fragment))
      (ratex-remove-overlay key))
     ((and active (ratex--context-equal-p fragment active))
      (ratex-remove-overlay key)
      (when (ratex--preview-enabled-p)
        (unless (ratex--display-edit-preview fragment response)
          (ratex--display-inline fragment response))))
     (t
      (ratex--display-inline fragment response)))))

(defun ratex--display-response (fragment-key fragment response &optional _style)
  "Display backend RESPONSE for FRAGMENT identified by FRAGMENT-KEY."
  (when (and (stringp fragment-key)
             (overlayp (ratex-overlay-for-key fragment-key))
             (not (ratex--fragment-valid-p fragment)))
    (ratex-remove-overlay fragment-key))
  (ratex--show-fragment fragment response))

(defun ratex--display-inline (fragment response)
  "Show RESPONSE as an inline overlay for FRAGMENT."
  (let* ((key (ratex--fragment-key fragment))
         (begin (plist-get fragment :begin))
         (end (plist-get fragment :end))
         (ok (ratex--response-ok-p response)))
    (if ok
        (let* ((cache-key (ratex--cache-key fragment))
               (image (ratex--image-for-response cache-key response)))
          (setq ratex--last-error nil)
          (when image
            (let ((overlay (ratex-show-overlay
                            key begin end image
                            (format "RaTeX %s"
                                    (if (alist-get 'cached response) "cached" "rendered"))
                            fragment 'inline)))
              (when (overlayp overlay)
                (overlay-put overlay 'ratex-cache-key cache-key)))))
      (setq ratex--last-error (alist-get 'error response))
      (ratex--notify-error (format "render failed: %s" ratex--last-error))
      (ratex-show-overlay
       key begin end
       (ratex--error-image ratex--last-error)
       (format "RaTeX render failed: %s" ratex--last-error)
       fragment 'inline))))

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

(defun ratex--posframe-ready-p ()
  "Return non-nil when posframe can be displayed on this frame."
  (and (ratex--ensure-posframe-loaded)
       (featurep 'posframe)
       (fboundp 'posframe-workable-p)
       (posframe-workable-p)))

(defun ratex--warn-posframe-unavailable ()
  "Tell the user once that the configured posframe preview cannot be used."
  (unless ratex--posframe-warning-shown
    (setq ratex--posframe-warning-shown t)
    (display-warning
     'ratex
     (concat "posframe preview unavailable (posframe not installed or not usable "
             "on this frame); formulas render inline instead.")
     :warning)))

(defun ratex--display-posframe (fragment &optional response image)
  "Display IMAGE (or RESPONSE) in a posframe for FRAGMENT."
  (when (eq (ratex--preview-style) 'posframe)
    (if (not (ratex--posframe-ready-p))
        (progn
          (ratex--warn-posframe-unavailable)
          nil)
      (when (ratex--fragment-contains-p fragment (point))
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
             :background-color (ratex--effective-posframe-background-color))
            (setq ratex--posframe-visible t)
            (setq ratex--posframe-fragment fragment)
            t))))))

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
  (when (ratex--fragment-contains-p fragment (point))
    (let ((image (or image (and response (ratex--image-from-response response)))))
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
             (ratex--posframe-ready-p))
    (if (ratex--fragment-contains-p ratex--posframe-fragment (point))
        (posframe-show
         ratex--posframe-buffer
         :position (point)
         :poshandler (or ratex-posframe-poshandler
                         #'ratex-posframe-poshandler-point-bottom-left-corner-offset)
         :border-width 1
         :border-color ratex-posframe-border-color
         :background-color (ratex--effective-posframe-background-color))
      (ratex--hide-posframe))))

(defun ratex--update-scale ()
  "Record the current text scale and refresh what is on screen."
  (let ((scale (if (bound-and-true-p text-scale-mode)
                   (expt text-scale-mode-step text-scale-mode-amount)
                 1.0)))
    (setq-local ratex--scale scale)
    (when (hash-table-p ratex--image-cache)
      (clrhash ratex--image-cache))
    (setq ratex--last-rendered-range nil)
    (when (bound-and-true-p ratex-mode)
      (ratex-refresh-previews t))))

(defun ratex-toggle-preview-at-point ()
  "Toggle the RaTeX edit preview for the formula at point."
  (interactive)
  (unless (ratex--preview-style)
    (user-error "Set `ratex-edit-preview' to `posframe' or `minibuffer' first"))
  (setq ratex--preview-enabled (not ratex--preview-enabled))
  (if ratex--preview-enabled
      (ratex--handle-preview-at-point (ratex--active-fragment-at-point))
    (ratex--hide-edit-preview)
    (let ((fragment (ratex--active-fragment-at-point)))
      (when fragment
        (ratex--ensure-fragment-preview fragment)))))

(advice-add 'load-theme :after #'ratex--schedule-theme-refresh)
(advice-add 'enable-theme :after #'ratex--schedule-theme-refresh)
(advice-add 'disable-theme :after #'ratex--schedule-theme-refresh)

(provide 'ratex-render)

;;; ratex-render.el ends here
