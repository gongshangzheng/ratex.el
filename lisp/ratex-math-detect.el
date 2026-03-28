;;; ratex-math-detect.el --- Math fragment detection -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)

(defconst ratex--delimiter-pairs
  '(("\\[" . "\\]")
    ("\\(" . "\\)")
    ("$$" . "$$")
    ("$" . "$")))

(defun ratex-fragment-at-point ()
  "Return the math fragment around point as a plist.

The plist contains `:begin', `:end' and `:content' when a fragment is found."
  (cl-loop for (open . close) in ratex--delimiter-pairs
           for fragment = (ratex--fragment-with-delimiters open close)
           when fragment
           return fragment))

(defun ratex--fragment-with-delimiters (open close)
  "Return fragment bounded by OPEN and CLOSE around point."
  (save-excursion
    (let ((pos (point))
          begin end content-begin content-end)
      (when (search-backward open nil t)
        (setq begin (point))
        (setq content-begin (+ begin (length open)))
        (goto-char content-begin)
        (when (search-forward close nil t)
          (setq end (point))
          (setq content-end (- end (length close)))
          (when (and (<= content-begin pos) (<= pos content-end))
            (list :begin begin
                  :end end
                  :content (buffer-substring-no-properties
                            content-begin
                            content-end)
                  :open open
                  :close close)))))))

(provide 'ratex-math-detect)

;;; ratex-math-detect.el ends here
