;;; pimacs-markdown-tests --- Markdown renderer tape tests -*- lexical-binding: t; -*-

;;; Code:

(require 'elp)
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

(defconst pimacs-markdown-tests--tape-files
  '("closed-fence.in.markdown"
    "heading.in.markdown"
    "image.in.markdown"
    "inline.in.markdown"
    "link.in.markdown"
    "lists.in.markdown"))

(defun pimacs-markdown-tests--face-only (text)
  (let ((result (substring-no-properties text))
        (index 0))
    (while (< index (length text))
      (when (and (not (eq (aref text index) ?\n))
                 (get-text-property index 'face text))
        (put-text-property index (1+ index) 'face
                           (get-text-property index 'face text) result))
      (setq index (1+ index)))
    result))

(defun pimacs-markdown-tests--render-complete (input)
  (with-temp-buffer
    (let ((context (pimacs--markdown-create-context)))
      (pimacs--markdown-apply-operations
       context
       (pimacs--render-markdown-experimental context input nil))
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
       ((string= line "│")
        (push "" output-lines))
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
            (let* ((end (+ start (nth 2 annotation)))
                   (face (nth 3 annotation))
                   (existing (get-text-property start 'face text)))
              (put-text-property start end 'face
                                 (if existing
                                     (cons face (if (listp existing)
                                                    existing
                                                  (list existing)))
                                   face)
                                 text)))))
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
   (mapcar (lambda (file)
             (expand-file-name file pimacs-markdown-tests--directory))
           pimacs-markdown-tests--tape-files)))

(ert-deftest pimacs-markdown-tape ()
  (dolist (tape (pimacs-markdown-tests--tapes))
    (pcase-let ((`(,input-file ,input ,expected) tape))
      (ert-info ((format "Markdown tape: %s" input-file))
        (should (equal expected
                       (pimacs-markdown-tests--render-complete input)))))))

(ert-deftest pimacs-markdown-streaming-appends-source-text ()
  (should (equal (pimacs--render-markdown-experimental nil "**Pimacs**" t)
                 '((:append "**Pimacs**")))))

(ert-deftest pimacs-markdown-image-label-has-image-url ()
  (with-temp-buffer
    (let ((context (pimacs--markdown-create-context)))
      (pimacs--markdown-apply-operations
       context
       (pimacs--render-markdown-experimental
        context "![Pimacs](https://example.com/pimacs.png)" nil))
      (let ((output (buffer-substring (pimacs-markdown-context-content-begin context)
                                      (pimacs-markdown-context-content-end context))))
        (should (equal (substring-no-properties output) "Pimacs"))
        (should (equal (get-text-property 0 'pimacs-markdown-image-url output)
                       "https://example.com/pimacs.png"))))))

(ert-deftest pimacs-markdown-links-use-url-link-widgets ()
  (with-temp-buffer
    (let ((context (pimacs--markdown-create-context)))
      (pimacs--markdown-apply-operations
       context
       (pimacs--render-markdown-experimental
        context "[Pimacs](https://example.com)" nil))
      (let ((widget (get-char-property
                     (pimacs-markdown-context-content-begin context) 'button)))
        (should (eq (car widget) 'url-link))
        (should (equal (widget-value widget) "https://example.com"))
        (should (eq (widget-get widget :action) 'widget-url-link-action))))))

(ert-deftest pimacs-markdown-relative-links-use-file-link-widgets ()
  (with-temp-buffer
    (let ((pimacs--project-root "/tmp/pimacs-markdown-project/")
          (context (pimacs--markdown-create-context)))
      (pimacs--markdown-apply-operations
       context
       (pimacs--render-markdown-experimental
        context "[Relative link](../README.md)" nil))
      (let ((widget (get-char-property
                     (pimacs-markdown-context-content-begin context) 'button)))
        (should (eq (car widget) 'file-link))
        (should (equal (widget-value widget) "/tmp/README.md"))
        (should (eq (widget-get widget :action) 'widget-file-link-action))))))

(ert-deftest pimacs-markdown-linked-image-preserves-both-urls ()
  (with-temp-buffer
    (let ((context (pimacs--markdown-create-context)))
      (pimacs--markdown-apply-operations
       context
       (pimacs--render-markdown-experimental
        context
        "[![Alt text](https://via.placeholder.com/100x50)](https://example.com)"
        nil))
      (let ((output (buffer-substring (pimacs-markdown-context-content-begin context)
                                      (pimacs-markdown-context-content-end context))))
        (should (equal (substring-no-properties output) "Alt text"))
        (should (equal (get-text-property 0 'pimacs-markdown-image-url output)
                       "https://via.placeholder.com/100x50"))
        (should (equal (get-text-property 0 'help-echo output)
                       "https://example.com"))))))


(defun pimacs-markdown-profile-run ()
  (elp-instrument-package "pimacs--markdown-")
  (let ((elp-use-standard-output t)
        stats)
    (unwind-protect
        (setq stats (ert-run-tests-batch "pimacs-markdown"))
      (elp-results)
      (elp-restore-all))
    (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1))))

;;; pimacs-markdown-tests.el ends here
