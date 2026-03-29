;;; ratex-tests.el --- Tests for ratex.el -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'json)
(require 'ratex)
(require 'ratex-core)
(require 'ratex-render)
(require 'ratex-math-detect)

(ert-deftest ratex-detects-dollar-math ()
  (with-temp-buffer
    (insert "hello $x^2$ world")
    (goto-char 10)
    (let ((fragment (ratex-fragment-at-point)))
      (should (equal (plist-get fragment :content) "x^2")))))

(ert-deftest ratex-does-not-detect-after-closing-delimiter ()
  (with-temp-buffer
    (insert "aa $x+1$ bb")
    (goto-char 9)
    (should-not (ratex-fragment-at-point))))

(ert-deftest ratex-detects-bracket-math ()
  (with-temp-buffer
    (insert "a \\[x+1\\] b")
    (goto-char 7)
    (let ((fragment (ratex-fragment-at-point)))
      (should (equal (plist-get fragment :content) "x+1")))))

(ert-deftest ratex-ignores-escaped-delimiters ()
  (with-temp-buffer
    (insert "price \\$5 and \\\\(x\\\\) and $y$")
    (let ((fragments (ratex-fragments-in-buffer)))
      (should (= (length fragments) 1))
      (should (equal (plist-get (car fragments) :content) "y")))))

(ert-deftest ratex-fragment-at-point-ignores-escaped-delimiters ()
  (with-temp-buffer
    (insert "a \\$x$ b")
    (goto-char 6)
    (should-not (ratex-fragment-at-point)))
  (with-temp-buffer
    (insert "a \\\\(x\\\\) b")
    (goto-char 6)
    (should-not (ratex-fragment-at-point))))

(ert-deftest ratex-skips-formulas-in-code-context ()
  (with-temp-buffer
    (insert "$x$ $y$")
    (cl-letf (((symbol-function 'ratex--code-context-at-p)
               (lambda (pos)
                 (<= pos 3))))
      (let ((fragments (ratex-fragments-in-buffer)))
        (should (= (length fragments) 1))
        (should (equal (plist-get (car fragments) :content) "y"))))))

(ert-deftest ratex-fragment-at-point-skips-code-context ()
  (with-temp-buffer
    (insert "$x$")
    (goto-char 2)
    (cl-letf (((symbol-function 'ratex--code-context-at-p)
               (lambda (_pos) t)))
      (should-not (ratex-fragment-at-point)))))

(ert-deftest ratex-backend-source-newer-detects-changes ()
  (let* ((root (make-temp-file "ratex-test" t))
         (backend-dir (expand-file-name "backend/src" root))
         (binary-dir (expand-file-name "backend/target/debug" root))
         (cargo-file (expand-file-name "backend/Cargo.toml" root))
         (source-file (expand-file-name "backend/src/main.rs" root))
         (lock-file (expand-file-name "backend/Cargo.lock" root))
         (binary-file (expand-file-name "backend/target/debug/ratex-editor-backend" root)))
    (make-directory backend-dir t)
    (make-directory binary-dir t)
    (dolist (file (list cargo-file source-file lock-file binary-file))
      (write-region "" nil file nil 'silent))
    (let ((old-time (seconds-to-time 1000))
          (new-time (seconds-to-time 2000)))
      (set-file-times binary-file old-time)
      (set-file-times cargo-file old-time)
      (set-file-times lock-file old-time)
      (set-file-times source-file new-time)
      (let ((default-directory root))
        (should (ratex--backend-source-newer-p binary-file))))))

(ert-deftest ratex-project-root-follows-library-location ()
  (let ((default-directory "/tmp/"))
    (let ((root (directory-file-name (ratex--project-root))))
      (should (file-directory-p root))
      (should (file-exists-p (expand-file-name "backend/Cargo.toml" root)))
      (should (file-directory-p (expand-file-name "lisp" root))))))

(ert-deftest ratex-backend-root-override-wins ()
  (let ((ratex-backend-root "/tmp/ratex-root/"))
    (should (equal (ratex-root) "/tmp/ratex-root/"))))

(ert-deftest ratex-json-response-uses-symbol-keys ()
  (let* ((json-object-type 'alist)
         (json-key-type 'symbol)
         (json-array-type 'list)
         (json-false :false)
         (payload (json-read-from-string
                   "{\"id\":1,\"ok\":true,\"height\":2.0,\"baseline\":1.0}")))
    (should (equal (alist-get 'id payload) 1))
    (should (equal (alist-get 'ok payload) t))
    (should (equal (alist-get 'height payload) 2.0))
    (should (equal (alist-get 'baseline payload) 1.0))))

(ert-deftest ratex-fragments-in-buffer-detects-multiple ()
  (with-temp-buffer
    (insert "a $x$ b \\[y+1\\] c")
    (let ((fragments (ratex-fragments-in-buffer)))
      (should (= (length fragments) 2))
      (should (equal (mapcar (lambda (f) (plist-get f :content)) fragments)
                     '("x" "y+1"))))))

(ert-deftest ratex-fragments-to-render-excludes-active ()
  (with-temp-buffer
    (insert "a $x$ b $y$ c")
    (goto-char 5)
    (let* ((fragments (ratex-fragments-in-buffer))
           (active (ratex-fragment-at-point))
           (targets (ratex--fragments-to-render fragments active)))
      (should (= (length fragments) 2))
      (should (= (length targets) 1))
      (should (equal (plist-get (car targets) :content) "y")))))

(ert-deftest ratex-refresh-previews-renders-all-non-active ()
  (with-temp-buffer
    (insert "a $x$ b $y$ c")
    (goto-char 5)
    (let (rendered)
      (cl-letf (((symbol-function 'ratex--ensure-fragment-preview)
                 (lambda (fragment)
                   (push (plist-get fragment :content) rendered)))
                ((symbol-function 'ratex--drop-stale-overlays)
                 (lambda (_keys) nil)))
        (ratex-refresh-previews)
        (should (equal rendered '("y")))))))

(ert-deftest ratex-refresh-previews-renders-all-with-include-active ()
  (with-temp-buffer
    (insert "a $x$ b $y$ c")
    (goto-char 5)
    (let (rendered)
      (cl-letf (((symbol-function 'ratex--ensure-fragment-preview)
                 (lambda (fragment)
                   (push (plist-get fragment :content) rendered)))
                ((symbol-function 'ratex--drop-stale-overlays)
                 (lambda (_keys) nil)))
        (ratex-refresh-previews t)
        (should (equal (sort rendered #'string<) '("x" "y")))))))

(ert-deftest ratex-initialize-previews-renders-all-then-hides-active ()
  (with-temp-buffer
    (insert "a $x$ b")
    (goto-char 4)
    (let (include-active removed-key)
      (cl-letf (((symbol-function 'ratex-refresh-previews)
                 (lambda (&optional include)
                   (setq include-active include)))
                ((symbol-function 'ratex-remove-overlay)
                 (lambda (key)
                   (setq removed-key key))))
        (ratex-initialize-previews)
        (should include-active)
        (should (equal removed-key "3:6:x"))
        (should (equal (plist-get ratex--active-fragment :content) "x"))))))

(ert-deftest ratex-post-command-hides-on-enter-and-renders-on-leave ()
  (with-temp-buffer
    (insert "a $x$ b")
    (let (removed ensured)
      (setq-local ratex-mode t)
      (setq-local ratex--active-fragment nil)
      (cl-letf (((symbol-function 'ratex-remove-overlay)
                 (lambda (key)
                   (push key removed)))
                ((symbol-function 'ratex--ensure-fragment-preview)
                 (lambda (fragment)
                   (push (plist-get fragment :content) ensured))))
        (goto-char 4)
        (ratex-handle-post-command)
        (should (equal removed '("3:6:x")))
        (should-not ensured)
        (setq removed nil)
        (goto-char 7)
        (ratex-handle-post-command)
        (should-not removed)
        (should (equal ensured '("x")))))))

(ert-deftest ratex-post-command-ignores-edits-inside-same-fragment ()
  (with-temp-buffer
    (insert "a $x$ b")
    (goto-char 4)
    (setq-local ratex-mode t)
    (setq-local ratex--active-fragment (ratex-fragment-at-point))
    (insert "y")
    (let (removed ensured)
      (cl-letf (((symbol-function 'ratex-remove-overlay)
                 (lambda (key)
                   (push key removed)))
                ((symbol-function 'ratex--ensure-fragment-preview)
                 (lambda (fragment)
                   (push (plist-get fragment :content) ensured))))
        (ratex-handle-post-command)
        (should-not removed)
        (should-not ensured)))))

(ert-deftest ratex-dispatches-responses-in-origin-buffer ()
  (let ((origin (generate-new-buffer " *ratex-origin*"))
        (process-buffer (generate-new-buffer " *ratex-process*")))
    (unwind-protect
        (with-current-buffer origin
          (clrhash ratex--pending)
          (let ((seen-buffer nil))
            (ratex-request
             '((type . "ping"))
             (lambda (_response)
               (setq seen-buffer (current-buffer))))
            (with-current-buffer process-buffer
              (ratex--dispatch-line "{\"id\":1,\"ok\":true}"))
            (should (eq seen-buffer origin))))
      (kill-buffer origin)
      (kill-buffer process-buffer)
      (clrhash ratex--pending))))

(provide 'ratex-tests)

;;; ratex-tests.el ends here
