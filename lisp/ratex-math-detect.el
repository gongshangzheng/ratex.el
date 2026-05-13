;;; ratex-math-detect.el --- Math fragment detection -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)

(defconst ratex--delimiter-pairs
  '(("\\[" . "\\]")
    ("\\(" . "\\)")))

(defun ratex-fragments-in-buffer (&optional beg end)
  "Return all math fragments between BEG and END.

When BEG and END are nil, scan the whole current buffer."
  (let ((beg (or beg (point-min)))
        (end (or end (point-max)))
        all)
    (dolist (pair ratex--delimiter-pairs)
      (setq all (nconc all (ratex--fragments-with-delimiters
                            (car pair) (cdr pair) beg end))))
    (ratex--select-non-overlapping-fragments all)))

(defun ratex-fragment-at-point ()
  "Return the math fragment around point as a plist.

The plist contains `:begin', `:end' and `:content' when a fragment is found."
  (unless (ratex--code-context-at-p (point))
    (cl-loop for (open . close) in ratex--delimiter-pairs
             for fragment = (ratex--fragment-with-delimiters open close)
             when fragment
             return fragment)))

(defun ratex--fragment-with-delimiters (open close)
  "Return fragment bounded by OPEN and CLOSE around point."
  (save-excursion
    (let ((pos (point))
          (open-len (length open))
          (close-len (length close))
          fragment)
      (while (and (not fragment) (search-backward open nil t))
        (let ((begin (point)))
          (if (or (ratex--escaped-at-p begin)
                  (ratex--code-context-at-p begin))
              (goto-char (max (point-min) (1- begin)))
            (let ((content-begin (+ begin open-len))
                  found-end
                  content-end)
              (goto-char content-begin)
              (while (and (not found-end) (search-forward close nil t))
                (let ((end-start (- (point) close-len)))
                  (unless (or (ratex--escaped-at-p end-start)
                              (ratex--code-context-at-p end-start))
                    (setq found-end (point))
                    (setq content-end end-start))))
              (if (and found-end
                       (<= content-begin pos)
                       (<= pos content-end))
                  (setq fragment
                        (list :begin begin
                              :end found-end
                              :content (buffer-substring-no-properties
                                        content-begin
                                        content-end)
                              :open open
                              :close close))
                (goto-char (max (point-min) (1- begin))))))))
      fragment)))

(defun ratex--fragments-with-delimiters (open close &optional beg end)
  "Return all OPEN..CLOSE fragments between BEG and END."
  (save-excursion
    (goto-char (or beg (point-min)))
    (let ((open-len (length open))
          (close-len (length close))
          (limit (copy-marker (or end (point-max))))
          fragments)
      (while (search-forward open limit t)
        (let ((begin (- (point) open-len)))
          (unless (or (ratex--escaped-at-p begin)
                      (ratex--code-context-at-p begin))
            (let ((content-begin (point))
                  found-end
                  content-end)
              (while (and (not found-end) (search-forward close limit t))
                (let ((end-start (- (point) close-len)))
                  (unless (or (ratex--escaped-at-p end-start)
                              (ratex--code-context-at-p end-start))
                    (setq found-end (point))
                    (setq content-end end-start))))
              (when (and found-end (<= content-begin content-end))
                (push (list :begin begin
                            :end found-end
                            :content (buffer-substring-no-properties content-begin content-end)
                            :open open
                            :close close)
                      fragments))))))
      (set-marker limit nil)
      (nreverse fragments))))

(defun ratex--select-non-overlapping-fragments (fragments)
  "Return FRAGMENTS sorted and without overlaps."
  (let ((sorted
         (sort (copy-sequence fragments)
               (lambda (a b)
                 (let ((ab (plist-get a :begin))
                       (bb (plist-get b :begin))
                       (ae (plist-get a :end))
                       (be (plist-get b :end)))
                   (if (= ab bb) (> ae be) (< ab bb))))))
        accepted
        last-end)
    (dolist (fragment sorted)
      (unless (and last-end (< (plist-get fragment :begin) last-end))
        (push fragment accepted)
        (setq last-end (max (or last-end (point-min))
                            (plist-get fragment :end)))))
    (nreverse accepted)))

(defun ratex--fragments-overlap-p (a b)
  "Return non-nil if fragment A overlaps fragment B."
  (let ((ab (plist-get a :begin))
        (ae (plist-get a :end))
        (bb (plist-get b :begin))
        (be (plist-get b :end)))
    (and (< ab be) (< bb ae))))

(defun ratex--escaped-at-p (pos)
  "Return non-nil if the token at POS is escaped by backslashes."
  (let ((count 0)
        (i (1- pos)))
    (while (and (>= i (point-min))
                (eq (char-after i) ?\\))
      (setq count (1+ count))
      (setq i (1- i)))
    (= 1 (% count 2))))

(defun ratex--code-context-at-p (pos)
  "Return non-nil when POS is in a code-like context."
  (save-excursion
    (goto-char pos)
    (or (nth 3 (syntax-ppss))
        (nth 4 (syntax-ppss))
        (ratex--mode-code-context-p))))

(defun ratex--mode-code-context-p ()
  "Return non-nil when point is in a mode-specific code block."
  (cond
   ((derived-mode-p 'org-mode)
    (or (and (fboundp 'org-in-src-block-p)
             (org-in-src-block-p t)
             (not (ratex--org-latex-src-block-p)))
        (and (fboundp 'org-in-block-p)
             (org-in-block-p '("example" "verbatim")))))
   ((derived-mode-p 'markdown-mode 'gfm-mode)
    (and (fboundp 'markdown-code-block-at-point-p)
         (markdown-code-block-at-point-p)))
   (t nil)))

(defun ratex--org-latex-src-block-p ()
  "Return non-nil when point is inside an Org latex src block."
  (and (fboundp 'org-element-at-point)
       (let ((element (org-element-at-point)))
         (and (eq (org-element-type element) 'src-block)
              (let ((language (org-element-property :language element)))
                (and language
                     (string-equal (downcase language) "latex")))))))

(provide 'ratex-math-detect)

;;; ratex-math-detect.el ends here
