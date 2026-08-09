;;; pimacs-markdown-table-tests --- Markdown table fixture tests -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'subr-x)

(package-initialize)

(require 'pimacs-markdown)

(defvar pimacs-markdown-table-tests--directory
  (expand-file-name "pimacs-markdown-table-tapes"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun pimacs-markdown-table-tests--read-file (file)
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun pimacs-markdown-table-tests--read-trimmed-file (file)
  (string-trim (pimacs-markdown-table-tests--read-file file)))

(defconst pimacs-markdown-table-tests--pixel-width-file
  (expand-file-name "pimacs-markdown-table-pixel-widths.el"
                    pimacs-markdown-table-tests--directory))

(cl-defstruct (pimacs-markdown-table-tests--fixture
               (:constructor pimacs-markdown-table-tests--make-fixture))
  input-file input expected window-width unicode-tables)

(defun pimacs-markdown-table-tests-record-pixel-widths ()
  "Record GUI pixel widths used while rendering fixtures in the mapping file."
  (interactive)
  (let ((file pimacs-markdown-table-tests--pixel-width-file)
        (original (symbol-function 'string-pixel-width))
        widths)
    (cl-labels ((record (text)
                  (let* ((plain (substring-no-properties text))
                         (width (funcall original text)))
                    (setf (alist-get plain widths nil nil #'equal) width)
                    width)))
      (cl-letf (((symbol-function 'string-pixel-width) #'record))
        (dolist (fixture (pimacs-markdown-table-tests--fixtures))
          (pimacs-markdown-table-tests--render-fixture fixture))))
    (with-temp-file file
      (insert ";; Generated in a graphical Emacs.\n")
      (insert ";; String, pixel width.\n")
      (prin1 widths (current-buffer))
      (insert "\n"))
    file))

(defun pimacs-markdown-table-tests--display-width (display)
  (pcase display
    (`(space :width (,width)) width)))

(defun pimacs-markdown-table-tests--visible-text (text)
  (let ((position 0)
        output)
    (while (< position (length text))
      (let* ((next (next-single-property-change position 'display text (length text)))
             (display (get-text-property position 'display text))
             (width (pimacs-markdown-table-tests--display-width display)))
        (push (if width
                  (make-string (round (/ width (float (string-pixel-width " ")))) ?\s)
                (substring-no-properties text position next))
              output)
        (setq position next)))
    (apply #'concat (nreverse output))))

(defun pimacs-markdown-table-tests--call-with-settings
    (window-width unicode-tables function)
  (let ((original-window-width (symbol-function 'window-width))
        (pimacs-markdown-use-unicode-tables unicode-tables))
    (cl-letf (((symbol-function 'window-width)
               (lambda (&optional window pixelwise)
                 (if pixelwise
                     window-width
                   (funcall original-window-width window pixelwise)))))
      (funcall function))))

(defun pimacs-markdown-table-tests--window-width-pixels (columns)
  (* columns (string-pixel-width " ")))

(defun pimacs-markdown-table-tests--border-positions (line)
  (let ((border (if (string-search "│" line) "│" "|"))
        (position 0)
        positions)
    (while (setq position (string-search border line position))
      (push position positions)
      (setq position (1+ position)))
    (nreverse positions)))

(defun pimacs-markdown-table-tests--append-cell-widths (rendered &optional pixel-width-function)
  (let* ((pixel-width-function
          (or pixel-width-function
              #'pimacs-markdown-table-tests--mapped-pixel-width))
         (line-end (or (string-search "\n" rendered) (length rendered)))
         (line (substring rendered 0 line-end))
         (positions (pimacs-markdown-table-tests--border-positions line)))
    (if (< (length positions) 2)
        rendered
      (concat (replace-regexp-in-string "\n+\\'" "" rendered)
              "\n@"
              (cl-loop for start in positions
                       for end in (cdr positions)
                       concat
                       (let* ((field (substring line (1+ start) end))
                              (field-width
                               (round (/ (float
                                          (funcall pixel-width-function field))
                                         (funcall pixel-width-function " "))))
                              (width (max 0 (- field-width 2)))
                              (value (number-to-string width)))
                         (concat " " value
                                 (make-string
                                  (max 0 (- field-width 1 (length value))) ?\s)
                                 "|")))
              "\n"))))

(defconst pimacs-markdown-table-tests--pixel-widths
  (with-temp-buffer
    (insert-file-contents pimacs-markdown-table-tests--pixel-width-file)
    (read (current-buffer))))

(defun pimacs-markdown-table-tests--mapped-pixel-width (text)
  (or (pimacs--alist-get-equal (substring-no-properties text)
                               pimacs-markdown-table-tests--pixel-widths)
      (* (string-width text)
         (or (pimacs--alist-get-equal " " pimacs-markdown-table-tests--pixel-widths)
             1))))

(defun pimacs-markdown-table-tests--call-with-mapped-widths
    (window-width unicode-tables function)
  (cl-letf (((symbol-function 'string-pixel-width)
             #'pimacs-markdown-table-tests--mapped-pixel-width))
    (pimacs-markdown-table-tests--call-with-settings
     (* window-width
        (pimacs-markdown-table-tests--mapped-pixel-width " "))
     unicode-tables function)))

(defun pimacs-markdown-table-tests--call-with-fixture-settings
    (fixture function)
  (pimacs-markdown-table-tests--call-with-settings
   (pimacs-markdown-table-tests--window-width-pixels
    (pimacs-markdown-table-tests--fixture-window-width fixture))
   (pimacs-markdown-table-tests--fixture-unicode-tables fixture)
   function))

(defun pimacs-markdown-table-tests--render-fixture (fixture)
  (pimacs-markdown-table-tests--call-with-fixture-settings
   fixture
   (lambda ()
     (pimacs--markdown-render-source
      (pimacs-markdown-table-tests--fixture-input fixture)))))

(defun pimacs-markdown-table-tests--visible-fixture (fixture)
  (pimacs-markdown-table-tests--visible-text
   (pimacs-markdown-table-tests--render-fixture fixture)))

(defun pimacs-markdown-table-tests--render (fixture)
  (pimacs-markdown-table-tests--call-with-mapped-widths
   (pimacs-markdown-table-tests--fixture-window-width fixture)
   (pimacs-markdown-table-tests--fixture-unicode-tables fixture)
   (lambda ()
     (pimacs-markdown-table-tests--append-cell-widths
      (pimacs-markdown-table-tests--visible-text
       (pimacs--markdown-render-source
        (pimacs-markdown-table-tests--fixture-input fixture)))))))

(defun pimacs-markdown-table-tests--fixtures ()
  (mapcar
   (lambda (input-file)
     (let* ((prefix (string-remove-suffix ".in.markdown" input-file))
            (output-file (concat prefix ".out.txt"))
            (width-file (concat prefix ".window-width"))
            (border-style-file (concat prefix ".border-style"))
            (border-style
             (if (file-exists-p border-style-file)
                 (pimacs-markdown-table-tests--read-trimmed-file border-style-file)
               "unicode")))
       (unless (file-exists-p output-file)
         (error "Missing table output fixture: %s" output-file))
       (unless (file-exists-p width-file)
         (error "Missing table window-width fixture: %s" width-file))
       (unless (member border-style '("unicode" "ascii"))
         (error "Invalid table border style: %s" border-style-file))
       (pimacs-markdown-table-tests--make-fixture
        :input-file input-file
        :input (pimacs-markdown-table-tests--read-file input-file)
        :expected (pimacs-markdown-table-tests--read-file output-file)
        :window-width
        (string-to-number
         (pimacs-markdown-table-tests--read-trimmed-file width-file))
        :unicode-tables (string= border-style "unicode"))))
   (directory-files pimacs-markdown-table-tests--directory
                    t "\\.in\\.markdown\\'")))

(defun pimacs-markdown-table-tests--insert-fixture (fixture)
  (let* ((input-file (pimacs-markdown-table-tests--fixture-input-file fixture))
         (window-width (pimacs-markdown-table-tests--fixture-window-width fixture))
         (unicode-tables (pimacs-markdown-table-tests--fixture-unicode-tables fixture))
         (name (file-name-base
                (string-remove-suffix ".in" (file-name-nondirectory input-file))))
         (border-style (if unicode-tables "unicode" "ascii"))
         (rendered (pimacs-markdown-table-tests--render-fixture fixture))
         (visible (pimacs-markdown-table-tests--visible-text rendered)))
    (insert (format "%s\n" name))
    (insert (format "spec: window-width=%d columns (%dpx) border-style=%s\n\n"
                    window-width
                    (pimacs-markdown-table-tests--window-width-pixels window-width)
                    border-style))
    (let ((annotated
           (pimacs-markdown-table-tests--append-cell-widths visible)))
      (insert rendered)
      (when-let ((start (string-search "\n@" annotated)))
        (insert (substring annotated (1+ start)))))
    (unless (bolp)
      (insert "\n"))
    (insert "\n")))

(defun pimacs-markdown-table-tests-write-fixtures ()
  "Render all fixtures in the current GUI and write their output files."
  (interactive)
  (dolist (fixture (pimacs-markdown-table-tests--fixtures))
    (let ((output-file
           (concat (string-remove-suffix ".in.markdown"
                                         (pimacs-markdown-table-tests--fixture-input-file fixture))
                   ".out.txt"))
          (rendered (pimacs-markdown-table-tests--visible-fixture fixture)))
      (with-temp-file output-file
        (insert
         (pimacs-markdown-table-tests--append-cell-widths
          rendered #'string-pixel-width))))))

(defun pimacs-markdown-table-tests-render-fixtures ()
  "Render all Markdown table fixtures in a temporary buffer."
  (interactive)
  (let ((buffer (get-buffer-create "*pimacs markdown table fixtures*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (fixture (pimacs-markdown-table-tests--fixtures))
          (pimacs-markdown-table-tests--insert-fixture fixture)))
      (goto-char (point-min))
      (special-mode))
    (pop-to-buffer buffer)))

(defun pimacs-markdown-table-tests--stream-render (input)
  (let ((state (pimacs--render-markdown :create))
        (position 0)
        (chunk-size 1)
        (output ""))
    (unwind-protect
        (progn
          (while (< position (length input))
            (let ((end (min (length input) (+ position chunk-size))))
              (dolist (operation
                       (pimacs--render-markdown
                        :stream state (substring input position end)))
                (pcase operation
                  (`(:replace-suffix ,count ,text)
                   (setq output
                         (concat (substring output 0 (- count)) text)))))
              (setq position end)
              (setq chunk-size (1+ (% chunk-size 7)))))
          output)
      (pimacs--render-markdown :destroy state))))

(defun pimacs-markdown-table-tests--should-stream-render (fixture)
  (let ((expected (pimacs-markdown-table-tests--fixture-expected fixture))
        (input (pimacs-markdown-table-tests--fixture-input fixture)))
    (pimacs-markdown-table-tests--call-with-mapped-widths
     (pimacs-markdown-table-tests--fixture-window-width fixture)
     (pimacs-markdown-table-tests--fixture-unicode-tables fixture)
     (lambda ()
       (should
        (equal expected
               (pimacs-markdown-table-tests--append-cell-widths
                (pimacs-markdown-table-tests--visible-text
                 (pimacs-markdown-table-tests--stream-render input)))))))))

(ert-deftest pimacs-markdown-table-fixtures ()
  (dolist (fixture (pimacs-markdown-table-tests--fixtures))
    (let ((input-file (pimacs-markdown-table-tests--fixture-input-file fixture))
          (window-width (pimacs-markdown-table-tests--fixture-window-width fixture))
          (expected (pimacs-markdown-table-tests--fixture-expected fixture)))
      (ert-info ((format "Markdown table fixture: %s (%d columns)"
                         input-file window-width))
        (should (equal expected
                       (pimacs-markdown-table-tests--render fixture)))
        (ert-info ((format "Streaming Markdown table fixture: %s" input-file))
          (pimacs-markdown-table-tests--should-stream-render fixture))))))

;;; pimacs-markdown-table-tests.el ends here

