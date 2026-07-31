;;; pimacs-markdown-tests --- Markdown renderer tape tests -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
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

(defconst pimacs-markdown-tests--fixed-chunk-widths '(1 4 16))
(defconst pimacs-markdown-tests--large-tape-line-threshold 100)

(defun pimacs-markdown-tests--environment-natural-number (variable default)
  (if-let ((value (getenv variable)))
      (if (string-match-p "\\`[0-9]+\\'" value)
          (string-to-number value)
        (error "%s must be a natural number, got %S" variable value))
    default))

(defun pimacs-markdown-tests--seed ()
  (if (getenv "SEED")
      (pimacs-markdown-tests--environment-natural-number "SEED" 0)
    (random t)
    (random most-positive-fixnum)))

(defun pimacs-markdown-tests--chunks-of-width (input width)
  (let ((length (length input))
        chunks)
    (dotimes (start (ceiling (/ (float length) width)))
      (let ((begin (* start width)))
        (push (substring input begin (min length (+ begin width))) chunks)))
    (nreverse chunks)))

(defun pimacs-markdown-tests--random-chunks (input random-state)
  (let ((length (length input))
        (position 0)
        chunks)
    (while (< position length)
      (let ((width (1+ (cl-random (min 32 (- length position)) random-state))))
        (push (substring input position (+ position width)) chunks)
        (setq position (+ position width))))
    (nreverse chunks)))

(defun pimacs-markdown-tests--chunks (input random-state complexity)
  (let ((chunkings (list (list input))))
    (dolist (width pimacs-markdown-tests--fixed-chunk-widths)
      (when (<= width (length input))
        (push (pimacs-markdown-tests--chunks-of-width input width) chunkings)))
    (dotimes (_ complexity)
      (push (pimacs-markdown-tests--random-chunks input random-state) chunkings))
    (delete-dups (nreverse chunkings))))

(defun pimacs-markdown-tests--large-tape-p (input)
  (> (cl-count ?\n input) pimacs-markdown-tests--large-tape-line-threshold))

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

(defun pimacs-markdown-tests--render-streaming (input chunks &optional replace-with-complete)
  (with-temp-buffer
    (let ((context (pimacs--markdown-create-context)))
      (dolist (chunk chunks)
        (pimacs--markdown-apply-operations
         context
         (pimacs--render-markdown-experimental context chunk t)))
      (if replace-with-complete
          (pimacs--markdown-apply-operations
           context
           (pimacs--render-markdown-experimental context input nil))
        (let ((parser (pimacs-markdown-context-parser context)))
          (pimacs--markdown-parser-finish parser t)
          (pimacs--markdown-apply-operations
           context (pimacs-markdown-parser-operations parser))))
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
   (directory-files pimacs-markdown-tests--directory t "\\.in\\.markdown\\'")))

(ert-deftest pimacs-markdown-tape ()
  (let* ((seed (pimacs-markdown-tests--seed))
         (complexity
          (pimacs-markdown-tests--environment-natural-number
           "PIMACS_MARKDOWN_TEST_COMPLEXITY" 2))
         (random-state (cl-make-random-state seed)))
    (message "pimacs markdown fuzz seed: %d (complexity %d)" seed complexity)
    (ert-info ((format "seed=%d; rerun with SEED=%d (complexity %d)"
                       seed seed complexity))
      (dolist (tape (pimacs-markdown-tests--tapes))
        (pcase-let ((`(,input-file ,input ,expected) tape))
          (ert-info ((format "%s: complete render" input-file))
            (should (equal expected
                           (pimacs-markdown-tests--render-complete input))))
          (if (pimacs-markdown-tests--large-tape-p input)
              (let ((chunks (pimacs-markdown-tests--chunks-of-width input 16)))
                (ert-info ((format "%s: streaming chunks of width 16" input-file))
                  (should (equal expected
                                 (pimacs-markdown-tests--render-streaming input chunks)))))
            (dolist (chunks (pimacs-markdown-tests--chunks input random-state complexity))
              (ert-info ((format "%s: streaming chunks %S" input-file chunks))
                (should (equal expected
                               (pimacs-markdown-tests--render-streaming input chunks)))))
            (ert-info ((format "%s: final complete replacement" input-file))
              (should (equal expected
                             (pimacs-markdown-tests--render-streaming
                              input
                              (pimacs-markdown-tests--chunks-of-width input 1)
                              t))))))))))


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

(ert-deftest pimacs-markdown-link-title-is-preserved ()
  (with-temp-buffer
    (let ((context (pimacs--markdown-create-context)))
      (pimacs--markdown-apply-operations
       context
       (pimacs--render-markdown-experimental
        context
        "[Pimacs][site]\n[site]: https://example.com \"Pimacs website\"\n[Inline](https://example.org 'Inline title')"
        nil))
      (let ((output (buffer-substring (pimacs-markdown-context-content-begin context)
                                      (pimacs-markdown-context-content-end context))))
        (should (equal (substring-no-properties output) "Pimacs\nInline"))
        (should (equal (get-text-property 0 'pimacs-markdown-link-title output)
                       "Pimacs website"))
        (should (equal (get-text-property 7 'pimacs-markdown-link-title output)
                       "Inline title"))))))

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
