;;; ratex-render.el --- Async rendering client -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ratex-core)
(require 'ratex-math-detect)
(require 'ratex-overlays)

(defcustom ratex-idle-delay 0.25
  "Idle delay before rerendering the fragment at point."
  :type 'number)

(defvar-local ratex--idle-timer nil)
(defvar-local ratex--last-request-id nil)
(defvar-local ratex--render-cache (make-hash-table :test #'equal))
(defvar-local ratex--last-error nil)

(defun ratex-render-fragment-at-point ()
  "Render the math fragment at point."
  (interactive)
  (let ((fragment (ratex-fragment-at-point)))
    (if (not fragment)
        (ratex-clear-overlay)
      (ratex--render-fragment fragment))))

(defun ratex-schedule-render ()
  "Schedule an async render for the current buffer."
  (when (timerp ratex--idle-timer)
    (cancel-timer ratex--idle-timer))
  (setq ratex--idle-timer
        (run-with-idle-timer
         ratex-idle-delay nil
         (lambda (buffer)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when ratex-mode
                 (ratex-render-fragment-at-point)))))
         (current-buffer))))

(defun ratex--render-fragment (fragment)
  "Render FRAGMENT plist."
  (let* ((content (string-trim (plist-get fragment :content)))
         (cache-key (list content ratex-font-size ratex-svg-padding))
         (cached (gethash cache-key ratex--render-cache)))
    (if cached
        (ratex--display-response fragment cached)
      (setq ratex--last-request-id
            (ratex-request
             `((type . "render")
               (latex . ,content)
               (font_size . ,ratex-font-size)
               (padding . ,ratex-svg-padding)
               (embed_glyphs . t))
             (lambda (response)
               (when (equal (alist-get 'id response) ratex--last-request-id)
                 (when (alist-get 'ok response)
                   (puthash cache-key response ratex--render-cache))
                 (ratex--display-response fragment response))))))))

(defun ratex--display-response (fragment response)
  "Display backend RESPONSE for FRAGMENT."
  (if (not (alist-get 'ok response))
      (progn
        (setq ratex--last-error (alist-get 'error response))
        (ratex-clear-overlay)
        (when ratex--last-error
          (message "RaTeX render failed: %s" ratex--last-error)))
    (let ((image (create-image
                  (alist-get 'svg response)
                  'svg t
                  :ascent (floor (* 100.0
                                    (/ (alist-get 'baseline response)
                                       (max 0.001 (alist-get 'height response))))))))
      (setq ratex--last-error nil)
      (ratex-show-overlay
       (plist-get fragment :begin)
       (plist-get fragment :end)
       image
       (format "RaTeX %s" (if (alist-get 'cached response) "cached" "rendered"))))))

(provide 'ratex-render)

;;; ratex-render.el ends here
