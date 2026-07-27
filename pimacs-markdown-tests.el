;;; pimacs-markdown-tests --- Markdown renderer tape tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'subr-x)

;; development only packages, not declared as a package-dependency
(package-initialize)

(require 'undercover)
(undercover)

(require 'pimacs)

(defvar pimacs-markdown-tests--directory
  (expand-file-name "pimacs-markdown-tapes"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun pimacs-markdown-tests--chunks (input)
  (let* ((length (length input))
         (max-width (min length 16))
         (chunkings (list (list input))))
    (dotimes (cut (max 0 (1- length)))
      (push (list (substring input 0 (1+ cut))
                  (substring input (1+ cut)))
            chunkings))
    (dotimes (offset max-width)
      (let ((width (1+ offset))
            chunks)
        (dotimes (start (ceiling (/ (float length) width)))
          (let ((begin (* start width)))
            (push (substring input begin (min length (+ begin width))) chunks)))
        (push (nreverse chunks) chunkings)))
    (delete-dups (nreverse chunkings))))

(defun pimacs-markdown-tests--face-only (text)
  (let ((result (substring-no-properties text)))
    (dotimes (index (length text) result)
      (when (and (not (eq (aref text index) ?\n))
                 (get-text-property index 'face text))
        (put-text-property index (1+ index) 'face
                           (get-text-property index 'face text) result)))))

(defun pimacs-markdown-tests--render (input chunks &optional finalize)
  (with-temp-buffer
    (let ((context (pimacs--markdown-create-context)))
      (dolist (chunk chunks)
        (pimacs--markdown-apply-operations
         context
         (pimacs--render-markdown-experimental context chunk t)))
      (when finalize
        (pimacs--markdown-apply-operations
         context
         (pimacs--render-markdown-experimental context input nil)))
      (pimacs-markdown-tests--face-only
       (buffer-substring (pimacs-markdown-context-content-begin context)
                         (pimacs-markdown-context-content-end context))))))

(defun pimacs-markdown-tests--read-file (file)
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun pimacs-markdown-tests--read-tape (file)
  (let* ((contents (pimacs-markdown-tests--read-file file))
         (lines (split-string contents "\n" nil))
         (ends-with-newline (string-suffix-p "\n" contents))
         (output-lines nil)
         (annotations nil)
         (final-newline t))
    (when ends-with-newline
      (setq lines (butlast lines)))
    (dolist (line lines)
      (cond
       ((string= line "@ eof")
        (setq final-newline nil))
       ((string-match "\\`@ \\( *\\)\\(\\^+\\) \\(.+\\)\\'" line)
        (unless output-lines
          (error "Face annotation has no output line: %s" file))
        (push (list (1- (length output-lines))
                    (length (match-string 1 line))
                    (length (match-string 2 line))
                    (intern (concat "pimacs-markdown-"
                                    (match-string 3 line)
                                    "-face")))
              annotations))
       ((string-prefix-p "│ " line)
        (push (substring line 2) output-lines))
       (t
        (error "Output line is missing its gutter: %s" file))))
    (let ((text (mapconcat #'identity (nreverse output-lines) "\n")))
      (when (and final-newline output-lines)
        (setq text (concat text "\n")))
      (let ((line-starts (list 0))
            (position 0))
        (while (string-match "\n" text position)
          (setq position (match-end 0))
          (push position line-starts))
        (setq line-starts (nreverse line-starts))
        (dolist (annotation annotations)
          (let ((start (+ (nth (car annotation) line-starts)
                          (nth 1 annotation))))
            (put-text-property start (+ start (nth 2 annotation))
                               'face (nth 3 annotation) text))))
      text)))

(defun pimacs-markdown-tests--tapes ()
  (mapcar
   (lambda (input-file)
     (let ((output-file
            (concat (string-remove-suffix ".in.markdown" input-file) ".out.txt")))
       (unless (file-exists-p output-file)
         (error "Missing Markdown output tape: %s" output-file))
       (list input-file
             (pimacs-markdown-tests--read-file input-file)
             (pimacs-markdown-tests--read-tape output-file))))
   (directory-files pimacs-markdown-tests--directory t "\\.in\\.markdown\\'")))

(ert-deftest pimacs-markdown-tape ()
  (dolist (tape (pimacs-markdown-tests--tapes))
    (pcase-let ((`(,input-file ,input ,expected) tape))
      (ert-info ((format "%s: complete render" input-file))
        (should (equal expected
                       (pimacs-markdown-tests--render input nil t))))
      (dolist (chunks (pimacs-markdown-tests--chunks input))
        (ert-info ((format "%s: streaming chunks %S" input-file chunks))
          (should (equal expected
                         (pimacs-markdown-tests--render input chunks t))))))))

;;; pimacs-markdown-tests.el ends here
