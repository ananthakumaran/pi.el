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
(require 'pimacs-markdown)

(ert-deftest pimacs-markdown-missing-treesit-warns-once ()
  (let ((pimacs--markdown-treesit-warning-shown nil)
        warnings)
    (cl-letf (((symbol-function 'pimacs--markdown-available-p)
               (lambda () nil))
              ((symbol-function 'display-warning)
               (lambda (&rest args)
                 (push args warnings))))
      (should (equal (pimacs--render-markdown :stream nil "text")
                     '((:append "text"))))
      (should (equal (pimacs--render-markdown :final nil "more")
                     '((:append "more"))))
      (should (= (length warnings) 1)))))

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

(defun pimacs-markdown-tests--render-final (input)
  (let ((state (pimacs--render-markdown :create)))
    (unwind-protect
        (pimacs--render-markdown :final state input)
      (pimacs--render-markdown :destroy state))))

(defun pimacs-markdown-tests--render-final-at (prefix input)
  (with-temp-buffer
    (insert prefix)
    (let ((state (pimacs--render-markdown :create)))
      (unwind-protect
          (substring-no-properties
           (plist-get
            (car (pimacs--render-markdown :final state input))
            :append))
        (pimacs--render-markdown :destroy state)))))

(defun pimacs-markdown-tests--render-complete (input)
  (with-temp-buffer
    (let ((context (pimacs--render-create-context))
          (state (pimacs--render-markdown :create)))
      (pimacs--render-apply-operations
       context
       (pimacs--render-markdown :final state input))
      (pimacs-markdown-tests--face-only
       (buffer-substring (pimacs-render-context-content-begin context)
                         (pimacs-render-context-content-end context))))))

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
     (treesit-parser-root-node (treesit-parser-create 'markdown-inline)) depth t)))

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
    (insert (pimacs--markdown-normalize-source input))
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
       (unless (file-exists-p ast-file)
         (error "Missing Markdown AST tape: %s" ast-file))
       (list input-file
             (pimacs-markdown-tests--read-file input-file)
             (pimacs-markdown-tests--read-file output-file)
             (pimacs-markdown-tests--read-file ast-file))))
   pimacs-markdown-tests--tape-files))

(ert-deftest pimacs-markdown-tape ()
  (dolist (tape (pimacs-markdown-tests--tapes))
    (pcase-let ((`(,input-file ,input ,expected ,expected-ast) tape))
      (ert-info ((format "Markdown tape: %s" input-file))
        (should (equal expected-ast (pimacs-markdown-tests--ast input)))
        (should (equal expected
                       (pimacs-markdown-tests--format-tape
                        (pimacs-markdown-tests--render-complete input))))))))

(ert-deftest pimacs-markdown-streaming-fuzz-matches-full-render ()
  (let ((random-state (cl-make-random-state t)))
    (cl-labels ((next-chunk-size ()
                  (1+ (cl-random 64 random-state))))
      (dolist (tape (pimacs-markdown-tests--tapes))
        (pcase-let ((`(,input-file ,source . ,_) tape))
          (ert-info ((format "Markdown streaming fuzz: %s" input-file))
            (let ((stream-source (pimacs--markdown-normalize-source source))
                  (state (pimacs--render-markdown :create))
                  (position 0)
                  (output ""))
              (unwind-protect
                  (progn
                    (while (< position (length stream-source))
                      (let ((end (min (length stream-source)
                                      (+ position (next-chunk-size)))))
                        (dolist (operation
                                 (pimacs--render-markdown
                                  :stream state
                                  (substring stream-source position end)))
                          (pcase operation
                            (`(:replace-suffix ,count ,text)
                             (setq output
                                   (concat (substring output 0 (- count)) text)))))
                        (setq position end)))
                    (should (equal output
                                   (pimacs--markdown-render-source source)))
                    (let ((final
                           (car (pimacs--render-markdown :final state source))))
                      (should
                       (equal (plist-get final :append)
                              (pimacs--markdown-render-source source)))))
                (pimacs--render-markdown :destroy state)))))))))

(ert-deftest pimacs-markdown-streaming-renders-source ()
  (with-temp-buffer
    (let ((state (pimacs--render-markdown :create)))
      (unwind-protect
          (let ((operations
                 (pimacs--render-markdown :stream state "**Pimacs**")))
            (should (equal (car operations) '(:replace-suffix 0 "Pimacs")))
            (should (pimacs--markdown-render-session-parser state)))
        (pimacs--render-markdown :destroy state)))))

(ert-deftest pimacs-markdown-streaming-replaces-affected-suffix ()
  (with-temp-buffer
    (let ((context (pimacs--render-create-context))
          (state (pimacs--render-markdown :create)))
      (unwind-protect
          (progn
            (dolist (delta '("# Heading\n\nParagraph " "with **bold** text"))
              (pimacs--render-apply-operations
               context (pimacs--render-markdown :stream state delta)))
            (should (equal (buffer-substring-no-properties
                            (pimacs-render-context-content-begin context)
                            (pimacs-render-context-content-end context))
                           "Heading\n\nParagraph with bold text")))
        (pimacs--render-markdown :destroy state)))))

(ert-deftest pimacs-markdown-streaming-checkpoints-section-blocks ()
  (let ((state (pimacs--render-markdown :create)))
    (unwind-protect
        (progn
          (pimacs--render-markdown
           :stream state "# Section\n\nPrefix paragraph.\n\n> Final")
          (should (cl-find "block_quote"
                           (pimacs--markdown-render-session-checkpoints state)
                           :key #'pimacs--markdown-render-checkpoint-type
                           :test #'string=))
          (let ((operation
                 (car (pimacs--render-markdown
                       :stream state " blockquote"))))
            (should (= (cadr operation)
                       (length (pimacs--markdown-render-source "> Final"))))
            (should (equal (caddr operation)
                           (pimacs--markdown-render-source "> Final blockquote")))))
      (pimacs--render-markdown :destroy state))))

(ert-deftest pimacs-markdown-final-render-cleans-streaming-session ()
  (with-temp-buffer
    (let ((state (pimacs--render-markdown :create)))
      (pimacs--render-markdown :stream state "partial")
      (let ((operations
             (pimacs--render-markdown :final state "**final**")))
        (should (equal (substring-no-properties
                        (plist-get (car operations) :append))
                       "final"))
        (should-not (cdr operations))
        (should-not (pimacs--markdown-render-session-buffer state))))))

(ert-deftest pimacs-markdown-leading-newline-is-contextual ()
  (dolist (source '("| Name | Value |\n| --- | --- |\n| foo | bar |"
                    "```elisp\n(message \"hello\")\n```"
                    "    one\n    two"
                    "> quoted\n> text"
                    "- first\n- second"))
    (should (string-prefix-p
             "\n"
             (pimacs-markdown-tests--render-final-at
              "assistant> " source))))
  (should-not (string-prefix-p
               "\n"
               (pimacs-markdown-tests--render-final-at
                "" "| Name | Value |\n| --- | --- |\n| foo | bar |"))))

(ert-deftest pimacs-markdown-leading-newline-honors-custom-block-types ()
  (let ((pimacs-markdown-leading-newline-block-types '("paragraph")))
    (should (string-prefix-p
             "\n"
             (pimacs-markdown-tests--render-final-at
              "assistant> " "plain text")))))

(ert-deftest pimacs-markdown-leading-newline-streaming-reclassifies-source ()
  (with-temp-buffer
    (insert "assistant> ")
    (let ((context (pimacs--render-create-context))
          (state (pimacs--render-markdown :create))
          (source "| Name | Value |\n| --- | --- |\n| foo | bar |"))
      (unwind-protect
          (progn
            (pimacs--render-apply-operations
             context
             (pimacs--render-markdown :stream state "| Name | Value |\n"))
            (pimacs--render-apply-operations
             context
             (pimacs--render-markdown
              :stream state "| --- | --- |\n| foo | bar |"))
            (should (equal
                     (buffer-substring-no-properties
                      (pimacs-render-context-content-begin context)
                      (pimacs-render-context-content-end context))
                     (pimacs--markdown-render-source source t)))
            (should (pimacs--markdown-render-session-leading-newline-rendered
                     state)))
        (pimacs--render-markdown :destroy state)))))

(ert-deftest pimacs-markdown-image-label-has-image-url ()
  (with-temp-buffer
    (let ((context (pimacs--render-create-context)))
      (pimacs--render-apply-operations
       context
       (pimacs-markdown-tests--render-final
        "![Pimacs](https://example.com/pimacs.png)"))
      (let ((output (buffer-substring (pimacs-render-context-content-begin context)
                                      (pimacs-render-context-content-end context))))
        (should (equal (substring-no-properties output) "Pimacs"))
        (should (equal (get-text-property 0 'pimacs-markdown-image-url output)
                       "https://example.com/pimacs.png"))))))

(ert-deftest pimacs-markdown-links-use-url-link-widgets ()
  (with-temp-buffer
    (let ((context (pimacs--render-create-context)))
      (pimacs--render-apply-operations
       context
       (pimacs-markdown-tests--render-final
        "[Pimacs](https://example.com)"))
      (let ((widget (get-char-property
                     (pimacs-render-context-content-begin context) 'button)))
        (should (eq (car widget) 'url-link))
        (should (equal (widget-value widget) "https://example.com"))
        (should (eq (widget-get widget :action) 'widget-url-link-action))))))

(ert-deftest pimacs-markdown-relative-links-use-file-link-widgets ()
  (with-temp-buffer
    (let ((pimacs--project-root "/tmp/pimacs-markdown-project/")
          (context (pimacs--render-create-context)))
      (pimacs--render-apply-operations
       context
       (pimacs-markdown-tests--render-final
        "[Relative link](../README.md)"))
      (let ((widget (get-char-property
                     (pimacs-render-context-content-begin context) 'button)))
        (should (eq (car widget) 'file-link))
        (should (equal (widget-value widget) "/tmp/README.md"))
        (should (eq (widget-get widget :action) 'widget-file-link-action))))))

(ert-deftest pimacs-markdown-linked-image-preserves-both-urls ()
  (with-temp-buffer
    (let ((context (pimacs--render-create-context)))
      (pimacs--render-apply-operations
       context
       (pimacs-markdown-tests--render-final
        "[![Alt text](https://via.placeholder.com/100x50)](https://example.com)"))
      (let ((output (buffer-substring (pimacs-render-context-content-begin context)
                                      (pimacs-render-context-content-end context))))
        (should (equal (substring-no-properties output) "Alt text"))
        (should (equal (get-text-property 0 'pimacs-markdown-image-url output)
                       "https://via.placeholder.com/100x50"))
        (should (equal (get-text-property 0 'help-echo output)
                       "https://example.com"))))))


(defun pimacs-markdown-profile-results ()
  (let (results)
    (mapatoms
     (lambda (function)
       (when (elp--instrumented-p function)
         (let* ((info (get function elp-timer-info-property))
                (call-count (aref info 0))
                (elapsed-time (aref info 1)))
           (when (or (not (numberp elp-report-limit))
                     (>= call-count elp-report-limit))
             (push (vector call-count elapsed-time
                           (if (zerop call-count)
                               0.0
                             (/ (float elapsed-time) (float call-count)))
                           (symbol-name function))
                   results))))))
    (when elp-sort-by-function
      (setq results (sort results elp-sort-by-function)))
    (let* ((name-width (max (length "Function Name")
                            (cl-loop for result in results
                                     maximize (length (aref result 3)))))
           (row-format (format "%%-%ds  %%10s  %%14s  %%14s\n" name-width)))
      (princ (format row-format "Function Name" "Call Count" "Elapsed Time" "Average Time"))
      (princ (format row-format
                     (make-string name-width ?=)
                     (make-string 10 ?=)
                     (make-string 14 ?=)
                     (make-string 14 ?=)))
      (dolist (result results)
        (princ (format row-format
                       (aref result 3)
                       (number-to-string (aref result 0))
                       (format "%.10f" (aref result 1))
                       (format "%.10f" (aref result 2))))))))

(defun pimacs-markdown-profile-run ()
  (require 'pimacs-markdown)
  (elp-instrument-package "pimacs--markdown-")
  (let (stats)
    (unwind-protect
        (setq stats
              (ert-run-tests-batch
               '(or "pimacs-markdown"
                    pimacs-markdown-streaming-fuzz-matches-full-render)))
      (pimacs-markdown-profile-results)
      (elp-restore-all))
    (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1))))

;;; pimacs-markdown-tests.el ends here
