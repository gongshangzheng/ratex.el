;;; ratex-core.el --- Process management for ratex.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: ratex.el contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0.24"))
;; Keywords: tex, math, tools

;;; Commentary:

;; Core backend process management for ratex.el.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup ratex nil
  "Inline math rendering with RaTeX."
  :group 'tex)

(defcustom ratex-backend-binary
  "backend/target/debug/ratex-editor-backend"
  "Path to the compiled backend binary.

If relative, it is resolved from `ratex-backend-root' when set, otherwise from
the discovered ratex.el installation root."
  :type 'string)

(defcustom ratex-backend-root nil
  "Absolute path to the ratex.el repository root.

Set this when auto-detection cannot reliably find the backend location."
  :type '(choice (const :tag "Auto detect" nil)
                 directory))

(defcustom ratex-auto-build-backend t
  "When non-nil, build the backend automatically if needed before startup."
  :type 'boolean)

(defcustom ratex-backend-build-command
  '("cargo" "build" "--manifest-path" "backend/Cargo.toml")
  "Command used to build the backend binary."
  :type '(repeat string))

(defcustom ratex-font-size 16.0
  "Default backend SVG font size."
  :type 'number)

(defcustom ratex-svg-padding 2.0
  "Default SVG padding sent to the backend."
  :type 'number)

(defcustom ratex-edit-preview nil
  "Preview style used while editing formulas.

Set to nil to disable edit previews, `posframe' to show a floating preview,
or `minibuffer' to show the preview in the minibuffer.
"
  :type '(choice (const :tag "Disable" nil)
                 (const :tag "Posframe" posframe)
                 (const :tag "Minibuffer" minibuffer)))

(defcustom ratex-render-color nil
  "Default formula color sent to backend rendering.

Use nil to keep backend defaults."
  :type '(choice (const :tag "Backend default" nil)
                 string))

(defcustom ratex-posframe-background-color "white"
  "Background color for RaTeX posframe preview."
  :type 'string)

(defcustom ratex-posframe-border-color "gray70"
  "Border color for RaTeX posframe preview."
  :type 'string)

(defcustom ratex-posframe-poshandler 'ratex-posframe-poshandler-point-bottom-left-corner-offset
  "Poshandler function used to place the RaTeX posframe preview."
  :type 'function)

(defvar ratex--process nil)
(defvar ratex--process-buffer " *ratex-backend*")
(defvar ratex--build-buffer " *ratex-backend-build*")
(defvar ratex--pending (make-hash-table :test #'eql))
(defvar ratex--next-id 0)
(defvar ratex--read-buffer "")
(defvar ratex--build-process nil)
(defvar ratex--startup-callbacks nil)
(defvar ratex--build-warned nil)

(defun ratex-root ()
  "Return the installed root directory of ratex.el."
  (or (and ratex-backend-root
           (file-name-as-directory (expand-file-name ratex-backend-root)))
      (ratex--discover-root)
      (error "Could not determine ratex.el root; set `ratex-backend-root'")))

(defun ratex-backend-live-p ()
  "Return non-nil when the backend process is alive."
  (and ratex--process (process-live-p ratex--process)))

(defun ratex-start-backend (&optional callback)
  "Start the backend process if needed.

When CALLBACK is non-nil, invoke it with the live process once startup succeeds."
  (cond
   ((ratex-backend-live-p)
    (when callback
      (funcall callback ratex--process))
    ratex--process)
   ((ratex--build-in-progress-p)
    (when callback
      (push callback ratex--startup-callbacks))
    nil)
   ((ratex--backend-ready-p)
    (ratex--launch-backend)
    (when callback
      (funcall callback ratex--process))
    ratex--process)
   (ratex-auto-build-backend
    (when callback
      (push callback ratex--startup-callbacks))
    (ratex-build-backend)
    nil)
   (t
    (ratex--warn "RaTeX backend binary is missing or stale. Run `M-x ratex-build-backend`.")
    nil)))

(defun ratex-stop-backend ()
  "Stop the backend process."
  (interactive)
  (when (ratex-backend-live-p)
    (delete-process ratex--process))
  (setq ratex--process nil))

(defun ratex-build-backend ()
  "Build the backend binary asynchronously."
  (interactive)
  (unless (ratex--build-in-progress-p)
    (let* ((root (ratex--project-root))
           (default-directory root)
           (program (car ratex-backend-build-command))
           (args (cdr ratex-backend-build-command)))
      (setq ratex--build-warned nil)
      (setq ratex--build-process
            (make-process
             :name "ratex-backend-build"
             :buffer ratex--build-buffer
             :command (cons program args)
             :coding 'utf-8-unix
             :connection-type 'pipe
             :noquery t
             :sentinel #'ratex--build-sentinel))
      (message "Building RaTeX backend in %s..." root))))

(defun ratex-request (payload callback)
  "Send PAYLOAD to backend and invoke CALLBACK with parsed response."
  (let ((id (cl-incf ratex--next-id))
        (origin-buffer (current-buffer))
        (data nil))
    (setq data (append (list (cons 'id id)) payload))
    (puthash
     id
     (lambda (response)
       (when (buffer-live-p origin-buffer)
         (with-current-buffer origin-buffer
           (funcall callback response))))
     ratex--pending)
    (ratex-start-backend
     (lambda (proc)
       (when (process-live-p proc)
         (process-send-string proc (concat (json-encode data) "\n")))))
    id))

(defun ratex-ping (callback)
  "Ping the backend and invoke CALLBACK with the response."
  (ratex-request '((type . "ping")) callback))

(defun ratex--process-filter (_proc chunk)
  "Process backend output CHUNK."
  (setq ratex--read-buffer (concat ratex--read-buffer chunk))
  (let (line)
    (while (string-match "\n" ratex--read-buffer)
      (setq line (substring ratex--read-buffer 0 (match-beginning 0)))
      (setq ratex--read-buffer (substring ratex--read-buffer (match-end 0)))
      (when (not (string-empty-p line))
        (ratex--dispatch-line line)))))

(defun ratex--dispatch-line (line)
  "Dispatch one backend output LINE."
  (let* ((json-object-type 'alist)
         (json-key-type 'symbol)
         (json-array-type 'list)
         (json-false :false)
         (data (ignore-errors (json-read-from-string line))))
    (when data
      (let* ((id (alist-get 'id data))
             (callback (gethash id ratex--pending)))
        (when callback
          (remhash id ratex--pending)
          (funcall callback data))))))

(defun ratex--process-sentinel (proc event)
  "Handle backend PROC EVENT."
  (unless (process-live-p proc)
    (maphash
     (lambda (_id callback)
       (funcall callback `((ok . :false) (error . ,(string-trim event)))))
     ratex--pending)
    (clrhash ratex--pending)
    (setq ratex--process nil)))

(defun ratex--launch-backend ()
  "Launch the compiled backend binary."
  (let* ((root (ratex--project-root))
         (default-directory root)
         (binary (ratex--backend-binary-path)))
    (setq ratex--read-buffer "")
    (setq ratex--process
          (make-process
           :name "ratex-backend"
           :buffer ratex--process-buffer
           :command (list binary)
           :coding 'utf-8-unix
           :connection-type 'pipe
           :noquery t
           :filter #'ratex--process-filter
           :sentinel #'ratex--process-sentinel))))

(defun ratex--backend-ready-p ()
  "Return non-nil if the backend binary exists and is newer than the sources."
  (let ((binary (ratex--backend-binary-path)))
    (and (file-exists-p binary)
         (not (ratex--backend-source-newer-p binary)))))

(defun ratex--backend-source-newer-p (binary)
  "Return non-nil if any backend source file is newer than BINARY."
  (let ((binary-time (file-attribute-modification-time (file-attributes binary)))
        (files (directory-files-recursively
                (expand-file-name "backend" (ratex--project-root))
                "\\(?:\\.rs\\|Cargo\\.toml\\|Cargo\\.lock\\)\\'")))
    (cl-some
     (lambda (file)
       (time-less-p binary-time
                    (file-attribute-modification-time (file-attributes file))))
     files)))

(defun ratex--build-in-progress-p ()
  "Return non-nil if a backend build is in progress."
  (and ratex--build-process (process-live-p ratex--build-process)))

(defun ratex--build-sentinel (proc event)
  "Handle backend build PROC EVENT."
  (unless (process-live-p proc)
    (let ((success (= (process-exit-status proc) 0))
          (callbacks (nreverse ratex--startup-callbacks)))
      (setq ratex--build-process nil)
      (setq ratex--startup-callbacks nil)
      (if success
          (progn
            (message "RaTeX backend build finished.")
            (ratex--launch-backend)
            (dolist (callback callbacks)
              (funcall callback ratex--process)))
        (ratex--warn
         (format "RaTeX backend build failed: %s" (string-trim event)))))))

(defun ratex--warn (message-text)
  "Show MESSAGE-TEXT once per startup failure burst."
  (unless ratex--build-warned
    (setq ratex--build-warned t)
    (display-warning 'ratex message-text :warning)))

(defun ratex-diagnose-backend ()
  "Show the current backend resolution state."
  (interactive)
  (let* ((root (condition-case err
                   (ratex--project-root)
                 (error (format "ERROR: %s" (error-message-string err)))))
         (binary (condition-case err
                     (ratex--backend-binary-path)
                   (error (format "ERROR: %s" (error-message-string err)))))
         (message-text
          (format
           (concat "ratex root: %s\n"
                   "backend binary: %s\n"
                   "binary exists: %s\n"
                   "auto build: %s\n"
                   "build command: %S")
           root
           binary
           (and (stringp binary) (file-exists-p binary))
           ratex-auto-build-backend
           ratex-backend-build-command)))
    (if (called-interactively-p 'interactive)
        (message "%s" message-text)
      message-text)))

(defun ratex--project-root ()
  "Return the root directory for ratex.el."
  (ratex-root))

(defun ratex--backend-binary-path ()
  "Return the absolute path of the backend binary."
  (let ((binary ratex-backend-binary))
    (if (file-name-absolute-p binary)
        binary
      (expand-file-name binary (ratex--project-root)))))

(defun ratex--discover-root ()
  "Discover the ratex.el root directory."
  (let ((candidates
         (delq nil
               (mapcar
                #'ratex--candidate-root
                (list load-file-name
                      (locate-library "ratex-core.el")
                      (locate-library "ratex.el")
                      (buffer-file-name))))))
    (seq-find #'ratex--valid-root-p candidates)))

(defun ratex--candidate-root (path)
  "Return a possible ratex root for PATH."
  (when path
    (let* ((full (expand-file-name path))
           (dir (file-name-directory full)))
      (cond
       ((not dir) nil)
       ((ratex--valid-root-p (ratex--straight-repo-root dir))
        (ratex--straight-repo-root dir))
       ((string-match-p "/lisp/?\\'" dir)
        (file-name-directory (directory-file-name dir)))
       ((file-directory-p full)
        full)
       (t
        (locate-dominating-file dir "backend/Cargo.toml"))))))

(defun ratex--straight-repo-root (path)
  "Return a straight.el repo root mapped from PATH, or nil."
  (when (string-match "\\(.*/straight\\)/build/\\([^/]+\\)/" path)
    (let* ((base (match-string 1 path))
           (pkg (match-string 2 path))
           (repos (expand-file-name "repos" base))
           (candidate-a (expand-file-name pkg repos))
           (candidate-b (expand-file-name (concat pkg ".el") repos)))
      (cond
       ((ratex--valid-root-p candidate-a) candidate-a)
       ((ratex--valid-root-p candidate-b) candidate-b)
       (t nil)))))

(defun ratex--valid-root-p (path)
  "Return non-nil when PATH looks like a valid ratex.el root."
  (and path
       (file-exists-p (expand-file-name "backend/Cargo.toml" path))
       (file-directory-p (expand-file-name "lisp" path))))

(provide 'ratex-core)

;;; ratex-core.el ends here
