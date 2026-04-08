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

(require 'url)

(defgroup ratex nil
  "Inline math rendering with RaTeX."
  :group 'tex)

(defcustom ratex-backend-binary
  (concat "backend/target/release/ratex-editor-backend"
          (if (eq system-type 'windows-nt) ".exe" ""))
  "Path to the backend binary managed by ratex.el.

If relative, it is resolved from `ratex-backend-root' when set, otherwise from
the discovered ratex.el installation root."
  :type 'string)

(defcustom ratex-backend-root nil
  "Absolute path to the ratex.el repository root.

Set this when auto-detection cannot reliably find the backend location."
  :type '(choice (const :tag "Auto detect" nil)
                 directory))

(defcustom ratex-auto-download-backend t
  "When non-nil, download the backend automatically if needed before startup."
  :type 'boolean)

(defcustom ratex-backend-release-repo "gongshangzheng/ratex.el"
  "GitHub repository that hosts backend release binaries."
  :type 'string)

(defcustom ratex-font-size 16.0
  "Default backend SVG font size."
  :type 'number)

(defcustom ratex-svg-padding 2.0
  "Default SVG padding sent to the backend."
  :type 'number)

(defcustom ratex-edit-preview nil
  "Preview style used while editing formulas.

Set to nil to disable edit previews, `posframe' to show a floating preview,
or `minibuffer' to show the preview in the minibuffer."
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

(defcustom ratex-posframe-poshandler
  'ratex-posframe-poshandler-point-bottom-left-corner-offset
  "Poshandler function used to place the RaTeX posframe preview."
  :type 'function)

(defvar ratex--process nil)
(defvar ratex--process-buffer " *ratex-backend*")
(defvar ratex--pending (make-hash-table :test #'eql))
(defvar ratex--next-id 0)
(defvar ratex--read-buffer "")
(defvar ratex--startup-warned nil)
(defvar ratex--startup-callbacks nil)
(defvar ratex--download-in-progress nil)

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
   (ratex--download-in-progress
    (when callback
      (push callback ratex--startup-callbacks))
    nil)
   ((ratex--backend-ready-p)
    (condition-case err
        (progn
          (ratex--launch-backend)
          (when callback
            (funcall callback ratex--process))
          ratex--process)
      (error
       (if ratex-auto-download-backend
           (progn
             (ratex--delete-backend-binary)
             (when callback
               (push callback ratex--startup-callbacks))
             (ratex--download-backend-async))
         (ratex--warn
          (format "RaTeX backend launch failed: %s"
                  (error-message-string err)))
         nil))))
   (ratex-auto-download-backend
    (when callback
      (push callback ratex--startup-callbacks))
    (ratex--download-backend-async)
    nil)
   (t
    (ratex--warn "RaTeX backend binary is missing. Run `M-x ratex-download-backend-command`.")
    nil)))

(defun ratex-stop-backend ()
  "Stop the backend process."
  (interactive)
  (when (ratex-backend-live-p)
    (delete-process ratex--process))
  (setq ratex--process nil))

(defun ratex-download-backend ()
  "Download the backend binary from GitHub Releases asynchronously."
  (interactive)
  (if ratex--download-in-progress
      (message "RaTeX backend download already in progress.")
    (ratex--download-backend-async)))

(defun ratex--download-backend-async ()
  "Start an asynchronous download of the backend binary."
  (let* ((binary (ratex--backend-binary-path))
         (directory (file-name-directory binary))
         (url (ratex--backend-download-url)))
    (setq ratex--startup-warned nil)
    (setq ratex--download-in-progress t)
    (make-directory directory t)
    (message "Downloading RaTeX backend from %s..." url)
    (url-retrieve
     url
     (lambda (status)
       (let ((callbacks (nreverse ratex--startup-callbacks))
             (temp-file (make-temp-file
                         "ratex-backend-"
                         nil
                         (if (eq system-type 'windows-nt) ".exe" ""))))
         (setq ratex--startup-callbacks nil)
         (setq ratex--download-in-progress nil)
         (unwind-protect
             (if (or (not status)
                     (plist-get status :error))
                 (let ((err (plist-get status :error)))
                   (ratex--warn
                    (format "RaTeX backend download failed: %s"
                            (if err (error-message-string err) "unknown error")))
                   (dolist (cb callbacks)
                     (funcall cb nil)))
               (goto-char (point-min))
               (re-search-forward "\r?\n\r?\n" nil t)
               (let ((body-start (point)))
                 (write-region body-start (point-max) temp-file nil 'silent))
               (ratex--validate-backend-file temp-file url)
               (rename-file temp-file binary t)
               (unless (eq system-type 'windows-nt)
                 (set-file-modes binary #o755))
               (message "RaTeX backend downloaded to %s" binary)
               (ratex--launch-backend)
               (dolist (cb callbacks)
                 (funcall cb ratex--process)))
           (when (file-exists-p temp-file)
             (delete-file temp-file)))))
     nil t)))

(defcustom ratex-backend-build-command
  '("cargo" "build" "--release" "--manifest-path" "backend/Cargo.toml")
  "Command used to build the backend binary locally.

The default matches the GitHub Actions release build."
  :type '(repeat string))

(defvar ratex--build-process nil)
(defvar ratex--build-buffer " *ratex-backend-build*")

(defun ratex-build-backend ()
  "Build the backend binary locally using cargo.
This is intended for developers who want to compile from source
instead of downloading a pre-built binary."
  (interactive)
  (when (ratex--build-in-progress-p)
    (error "A backend build is already in progress"))
  (let* ((root (ratex-root))
         (default-directory root)
         (program (car ratex-backend-build-command))
         (args (cdr ratex-backend-build-command)))
    (message "Building RaTeX backend...")
    (setq ratex--build-process
          (make-process
           :name "ratex-backend-build"
           :buffer ratex--build-buffer
           :command (cons program args)
           :coding 'utf-8-unix
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (_proc event)
             (unless (process-live-p ratex--build-process)
               (let ((success (= (process-exit-status ratex--build-process) 0)))
                 (setq ratex--build-process nil)
                 (if success
                     (message "RaTeX backend build finished.")
                   (ratex--warn "RaTeX backend build failed.")))))))))

(defun ratex--build-in-progress-p ()
  "Return non-nil if a backend build is in progress."
  (and ratex--build-process (process-live-p ratex--build-process)))

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
      (unless (string-empty-p line)
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
  "Launch the backend binary."
  (let ((binary (ratex--backend-binary-path))
        (default-directory (ratex-root)))
    (unless (file-exists-p binary)
      (error "RaTeX backend binary does not exist: %s" binary))
    (ratex--validate-backend-file binary)
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
  "Return non-nil if the backend binary exists and looks executable."
  (let ((binary (ratex--backend-binary-path)))
    (and (file-exists-p binary)
         (ratex--backend-file-valid-p binary))))

(defun ratex--delete-backend-binary ()
  "Delete the current backend binary when it exists."
  (let ((binary (ratex--backend-binary-path)))
    (when (file-exists-p binary)
      (delete-file binary))))

(defun ratex--warn (message-text)
  "Show MESSAGE-TEXT once per startup failure burst."
  (unless ratex--startup-warned
    (setq ratex--startup-warned t)
    (display-warning 'ratex message-text :warning)))

(defun ratex-diagnose-backend ()
  "Show the current backend resolution state."
  (interactive)
  (let* ((root (condition-case err
                   (ratex-root)
                 (error (format "ERROR: %s" (error-message-string err)))))
         (binary (condition-case err
                     (ratex--backend-binary-path)
                   (error (format "ERROR: %s" (error-message-string err)))))
         (download-url (condition-case err
                           (ratex--backend-download-url)
                         (error (format "ERROR: %s" (error-message-string err)))))
         (valid (condition-case err
                    (ratex--backend-file-valid-p binary)
                  (error (format "ERROR: %s" (error-message-string err)))))
         (message-text
          (format
           (concat "ratex root: %s\n"
                   "backend binary: %s\n"
                   "binary exists: %s\n"
                   "binary valid: %s\n"
                   "auto download: %s\n"
                   "release repo: %s\n"
                   "download url: %s")
           root
           binary
           (and (stringp binary) (file-exists-p binary))
           valid
           ratex-auto-download-backend
           ratex-backend-release-repo
           download-url)))
    (if (called-interactively-p 'interactive)
        (message "%s" message-text)
      message-text)))

(defun ratex--backend-binary-path ()
  "Return the absolute path of the backend binary."
  (let ((binary ratex-backend-binary))
    (if (file-name-absolute-p binary)
        binary
      (expand-file-name binary (ratex-root)))))

(defun ratex--backend-download-url ()
  "Return the GitHub Release URL for the current platform backend."
  (format "%s/%s"
          (format "https://github.com/%s/releases/latest/download"
                  ratex-backend-release-repo)
          (ratex--backend-asset-name)))

(defun ratex--backend-asset-name ()
  "Return the release asset name for the current platform."
  (cond
   ((eq system-type 'gnu/linux) "ratex-editor-backend-linux")
   ((eq system-type 'darwin) "ratex-editor-backend-macos")
   ((eq system-type 'windows-nt) "ratex-editor-backend-windows.exe")
   (t
    (error "Unsupported system type for RaTeX backend: %S" system-type))))

(defun ratex--backend-file-valid-p (path)
  "Return non-nil when PATH looks like a valid executable for this platform."
  (and (stringp path)
       (file-exists-p path)
       (not (file-directory-p path))
       (> (file-attribute-size (file-attributes path)) 2)
       (let ((coding-system-for-read 'no-conversion))
         (with-temp-buffer
           (set-buffer-multibyte nil)
           (insert-file-contents-literally path nil 0 4)
           (cond
            ((eq system-type 'windows-nt)
             (string-prefix-p "MZ" (buffer-string)))
            ((eq system-type 'gnu/linux)
             (equal (buffer-string) "\177ELF"))
            ((eq system-type 'darwin)
             (member (buffer-string)
                     '("\317\372\355\376"
                       "\316\372\355\376"
                       "\376\355\372\317"
                       "\376\355\372\316"
                       "\312\376\272\276")))
            (t nil))))))

(defun ratex--validate-backend-file (path &optional source-url)
  "Signal an error when PATH is not a valid backend executable.

When SOURCE-URL is non-nil, include it in the error message."
  (unless (ratex--backend-file-valid-p path)
    (let ((details (condition-case nil
                       (let ((coding-system-for-read 'utf-8-unix))
                         (with-temp-buffer
                           (insert-file-contents path nil 0 120)
                           (string-trim (buffer-string))))
                     (error nil))))
      (error
       (concat
        "Downloaded backend is not a valid "
        (pcase system-type
          ('windows-nt "Windows executable")
          ('gnu/linux "ELF executable")
          ('darwin "macOS executable")
          (_ "executable"))
        (when source-url
          (format " from %s" source-url))
        (when (and details (not (string-empty-p details)))
          (format "; file starts with: %S" details)))))))

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
        (or (locate-dominating-file dir "lisp/ratex.el")
            (locate-dominating-file dir "backend/Cargo.toml")))))))

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
       (file-exists-p (expand-file-name "lisp/ratex.el" path))
       (file-directory-p (expand-file-name "lisp" path))))

(provide 'ratex-core)

;;; ratex-core.el ends here
