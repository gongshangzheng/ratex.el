;;; ratex-tests.el --- Tests for ratex.el -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'ratex-core)
(require 'ratex-math-detect)

(ert-deftest ratex-detects-dollar-math ()
  (with-temp-buffer
    (insert "hello $x^2$ world")
    (goto-char 10)
    (let ((fragment (ratex-fragment-at-point)))
      (should (equal (plist-get fragment :content) "x^2")))))

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

(provide 'ratex-tests)

;;; ratex-tests.el ends here
