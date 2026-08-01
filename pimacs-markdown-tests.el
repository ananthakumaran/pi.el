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
  (directory-files pimacs-markdown-tests--directory t "\\.in\\.markdown\\'"))

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

(defun pimacs-markdown-tests--ast-text (text depth)
  (if (and (not (string-match-p "\n" text))
           (<= (length text) 60))
      (concat " " (prin1-to-string text))
    (concat " [\n"
            (mapconcat (lambda (line)
                         (concat (make-string depth ?\s)
                                 (if (string-empty-p line) "│" (concat "│ " line))))
                       (split-string text "\n" nil)
                       "\n")
            "\n"
            (make-string depth ?\s)
            "]")))

(defun pimacs-markdown-tests--ast-text-node (text depth)
  (concat (make-string depth ?\s)
          "text"
          (pimacs-markdown-tests--ast-text text depth)
          "\n"))

(defun pimacs-markdown-tests--ast-children (node depth inline-tree)
  (let ((children (pimacs--markdown-node-children node)))
    (if (and inline-tree
             (or children (string= (treesit-node-type node) "inline")))
        (let ((position (treesit-node-start node))
              output)
          (dolist (child children)
            (let ((start (treesit-node-start child)))
              (when (< position start)
                (push (pimacs-markdown-tests--ast-text-node
                       (buffer-substring-no-properties position start) depth)
                      output))
              (push (pimacs-markdown-tests--ast-node child depth t) output)
              (setq position (treesit-node-end child))))
          (when (< position (treesit-node-end node))
            (push (pimacs-markdown-tests--ast-text-node
                   (buffer-substring-no-properties position (treesit-node-end node)) depth)
                  output))
          (apply #'concat (nreverse output)))
      (mapconcat (lambda (child)
                   (pimacs-markdown-tests--ast-node child depth))
                 children
                 ""))))

(defun pimacs-markdown-tests--inline-children (node depth)
  (with-temp-buffer
    (insert (treesit-node-text node t))
    (pimacs-markdown-tests--ast-children
     (treesit-parser-root-node (treesit-parser-create 'markdown_inline)) depth t)))

(defun pimacs-markdown-tests--ast-node (node depth &optional inline-tree)
  (let* ((type (treesit-node-type node))
         (inline-node (and (not inline-tree) (string= type "inline")))
         (children (pimacs--markdown-node-children node))
         (indentation (make-string depth ?\s)))
    (concat indentation
            type
            (when (and (not (string-empty-p (treesit-node-text node t)))
                       (or inline-node
                           (string= type "code_fence_content")
                           (and (null children)
                                (not (and (string= type "inline")
                                          (= depth 0))))))
              (pimacs-markdown-tests--ast-text
               (treesit-node-text node t) depth))
            "\n"
            (if inline-node
                (pimacs-markdown-tests--inline-children node (1+ depth))
              (pimacs-markdown-tests--ast-children
               node (1+ depth) inline-tree)))))

(defun pimacs-markdown-tests--ast (input)
  (with-temp-buffer
    (insert input)
    (concat "markdown:\n"
            (pimacs-markdown-tests--ast-node
             (treesit-parser-root-node (treesit-parser-create 'markdown)) 0))))

(defun pimacs-markdown-tests--face-name (face)
  (string-remove-suffix "-face"
                        (string-remove-prefix "pimacs-markdown-"
                                              (symbol-name face))))

(defun pimacs-markdown-tests--format-tape (text)
  (let ((lines (split-string text "\n" nil))
        (final-newline (string-suffix-p "\n" text))
        output)
    (when final-newline
      (setq lines (butlast lines)))
    (dolist (line lines)
      (push (if (string-empty-p line)
                "│"
              (concat "│ " (substring-no-properties line)))
            output)
      (let (faces)
        (dotimes (position (length line))
          (dolist (face (reverse (ensure-list (get-text-property position 'face line))))
            (cl-pushnew face faces)))
        (dolist (face (nreverse faces))
          (let ((position 0))
            (while (< position (length line))
              (if (memq face (ensure-list (get-text-property position 'face line)))
                  (let ((start position))
                    (while (and (< position (length line))
                                (memq face (ensure-list (get-text-property position 'face line))))
                      (setq position (1+ position)))
                    (push (format "@ %s%s %s"
                                  (make-string start ?\s)
                                  (make-string (- position start) ?^)
                                  (pimacs-markdown-tests--face-name face))
                          output))
                (setq position (1+ position))))))))
    (unless final-newline
      (push "@ eof" output))
    (concat (mapconcat #'identity (nreverse output) "\n") "\n")))

(defun pimacs-markdown-tests--tapes ()
  (mapcar
   (lambda (input-file)
     (let* ((tape-prefix (string-remove-suffix ".in.markdown" input-file))
            (output-file (concat tape-prefix ".out.txt"))
            (ast-file (concat tape-prefix ".out.ast")))
       (unless (file-exists-p output-file)
         (error "Missing Markdown output tape: %s" output-file))
       (list input-file
             (pimacs-markdown-tests--read-file input-file)
             (pimacs-markdown-tests--read-file output-file)
             (and (file-exists-p ast-file)
                  (pimacs-markdown-tests--read-file ast-file)))))
   pimacs-markdown-tests--tape-files))

(ert-deftest pimacs-markdown-tape ()
  (dolist (tape (pimacs-markdown-tests--tapes))
    (pcase-let ((`(,input-file ,input ,expected ,expected-ast) tape))
      (ert-info ((format "Markdown tape: %s" input-file))
        (when expected-ast
          (should (equal expected-ast (pimacs-markdown-tests--ast input))))
        (should (equal expected
                       (pimacs-markdown-tests--format-tape
                        (pimacs-markdown-tests--render-complete input))))))))

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
