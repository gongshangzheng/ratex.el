;;; ratex-tests.el --- Tests for ratex.el -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'json)
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
    (should (string-prefix-p
             "/Users/zhengxinyu/code/ratex.el"
             (directory-file-name (ratex--project-root))))))

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

(ert-deftest ratex-renders-only-after-leaving-fragment ()
  (with-temp-buffer
    (insert "aa $x+1$ bb")
    (goto-char 6)
    (let (rendered)
      (cl-letf (((symbol-function 'ratex--render-fragment)
                 (lambda (fragment)
                   (setq rendered fragment)))
                ((symbol-function 'ratex-clear-overlay)
                 (lambda () nil)))
        (ratex-render-fragment-at-point)
        (should (equal (plist-get ratex--active-fragment :content) "x+1"))
        (should-not rendered)
        (goto-char 9)
        (ratex-render-fragment-at-point)
        (should (equal (plist-get rendered :content) "x+1"))
        (should-not ratex--active-fragment)))))

(provide 'ratex-tests)

;;; ratex-tests.el ends here
