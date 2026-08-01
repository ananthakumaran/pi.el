;;; pimacs-markdown.el --- Markdown rendering -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Anantha Kumaran.

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Markdown is parsed by tree-sitter after streaming has completed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'treesit)
(require 'pimacs-markdown-table)

(add-to-list 'treesit-load-name-override-list
             '(markdown_inline "libtree-sitter-markdown-inline" "tree_sitter_markdown_inline"))

;;; Markdown Parser

(defun pimacs--markdown-node-children (node)
  (cl-loop for index below (treesit-node-child-count node t)
           collect (treesit-node-child node index t)))

(defun pimacs--markdown-node-children-without-types (node types)
  (cl-remove-if (lambda (child)
                  (member (treesit-node-type child) types))
                (pimacs--markdown-node-children node)))

(defun pimacs--markdown-node-child (node type)
  (cl-find type (pimacs--markdown-node-children node)
           :key #'treesit-node-type :test #'string=))

(defun pimacs--markdown-node-text (node)
  (treesit-node-text node t))

(defun pimacs--markdown-reference-label (text)
  (downcase (string-trim text "\\[" "\\]")))

(defun pimacs--markdown-reference-definitions (root)
  (let (definitions)
    (cl-labels
        ((walk (node)
           (if (string= (treesit-node-type node) "link_reference_definition")
               (let ((label (pimacs--markdown-node-child node "link_label"))
                     (destination (pimacs--markdown-node-child node "link_destination"))
                     (title (pimacs--markdown-node-child node "link_title")))
                 (when (and label destination)
                   (push (cons (pimacs--markdown-reference-label
                                (pimacs--markdown-node-text label))
                               (list (string-trim
                                      (pimacs--markdown-node-text destination) "<" ">")
                                     (and title
                                          (string-trim
                                           (pimacs--markdown-node-text title) "\"'("
                                           "\"')"))))
                         definitions)))
             (mapc #'walk (pimacs--markdown-node-children node)))))
      (walk root))
    (nreverse definitions)))

(cl-defstruct pimacs--markdown-render-context
  reference-definitions
  list-depth
  list-index)

(defun pimacs--markdown-render-context-for-list-item (context list-index)
  (let ((context (copy-pimacs--markdown-render-context context)))
    (setf (pimacs--markdown-render-context-list-depth context)
          (1+ (pimacs--markdown-render-context-list-depth context)))
    (setf (pimacs--markdown-render-context-list-index context) list-index)
    context))

(defun pimacs--markdown-with-parser (text grammar function)
  (let ((buffer (generate-new-buffer " *pimacs-markdown*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert text)
          (let ((parser
                 (condition-case error
                     (treesit-parser-create grammar)
                   (error
                    (user-error
                     "Pimacs Markdown requires tree-sitter grammars `markdown' and `markdown_inline': %s"
                     (error-message-string error))))))
            (funcall function (treesit-parser-root-node parser))))
      (kill-buffer buffer))))

(defun pimacs--markdown-parse-source (text renderer)
  (pimacs--markdown-with-parser
   text 'markdown
   (lambda (root)
     (funcall
      renderer root
      (make-pimacs--markdown-render-context
       :reference-definitions
       (pimacs--markdown-reference-definitions root)
       :list-depth 0
       :list-index nil)))))

;;; Markdown Renderer

(cl-defstruct pimacs-markdown-context
  content-begin
  content-end
  rendered-length)

(defface pimacs-markdown-heading-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face used for Markdown headings."
  :group 'pimacs)

(defface pimacs-markdown-inline-code-face
  '((t :inherit (fixed-pitch font-lock-constant-face)))
  "Face used for inline code."
  :group 'pimacs)

(defface pimacs-markdown-equation-face
  '((t :inherit (fixed-pitch font-lock-constant-face)))
  "Face used for Markdown equations."
  :group 'pimacs)

(defface pimacs-markdown-bold-face
  '((t :inherit bold))
  "Face used for bold text."
  :group 'pimacs)

(defface pimacs-markdown-italic-face
  '((t :inherit italic))
  "Face used for italic text."
  :group 'pimacs)

(defface pimacs-markdown-strike-through-face
  '((t :strike-through t))
  "Face used for Markdown strike-through text."
  :group 'pimacs)

(defface pimacs-markdown-superscript-face
  '((t :height 0.8 :raise 0.3))
  "Face used for Markdown superscript text."
  :group 'pimacs)

(defface pimacs-markdown-subscript-face
  '((t :height 0.8 :raise -0.2))
  "Face used for Markdown subscript text."
  :group 'pimacs)

(defface pimacs-markdown-link-face
  '((t :inherit link))
  "Face used for provisional Markdown links."
  :group 'pimacs)

(defface pimacs-markdown-list-marker-face
  '((t :inherit shadow :slant normal :weight normal))
  "Face used for Markdown list markers."
  :group 'pimacs)

(defface pimacs-markdown-checkbox-face
  '((t :inherit font-lock-builtin-face))
  "Face used for Markdown task-list checkboxes."
  :group 'pimacs)

(defface pimacs-markdown-blockquote-face
  '((t :inherit font-lock-comment-face))
  "Face used for Markdown blockquotes."
  :group 'pimacs)

(defface pimacs-markdown-horizontal-rule-face
  '((t :inherit shadow))
  "Face used for Markdown horizontal rules."
  :group 'pimacs)

(defface pimacs-markdown-code-block-face
  '((t :inherit fixed-pitch))
  "Face used as the base face of Markdown code blocks."
  :group 'pimacs)

(defconst pimacs--markdown-list-bullets
  '("▪" "▫" "◇" "•" "○"))

(defun pimacs--markdown-propertize-face (text face)
  (when (> (length text) 0)
    (put-text-property 0 (length text) 'face face text))
  text)

(defun pimacs--markdown-propertize-face-runs (text face-function)
  (let ((position 0)
        (length (length text)))
    (while (< position length)
      (let* ((existing (get-text-property position 'face text))
             (end (or (next-single-property-change position 'face text)
                      length))
             (face (funcall face-function existing)))
        (when face
          (put-text-property position end 'face face text))
        (setq position end))))
  text)

(defun pimacs--markdown-propertize-outer-face (text face)
  (pimacs--markdown-propertize-face-runs
   text
   (lambda (existing)
     (let ((faces (ensure-list existing)))
       (if (memq face faces)
           existing
         (append faces (list face)))))))

(defun pimacs--markdown-propertize-blockquote-face (text)
  (pimacs--markdown-propertize-face-runs
   text
   (lambda (existing)
     (unless (memq 'pimacs-markdown-code-block-face (ensure-list existing))
       (if existing
           (append (ensure-list existing)
                   '(pimacs-markdown-blockquote-face))
         'pimacs-markdown-blockquote-face)))))

(defun pimacs--markdown-quote-lines (text)
  (let ((lines (split-string text "\n" nil))
        (newline (string-suffix-p "\n" text)))
    (concat (mapconcat (lambda (line)
                         (if (string-empty-p line)
                             "▎"
                           (concat "▎ " line)))
                       lines "\n")
            (if newline "\n" ""))))

(defun pimacs--markdown-node-text-without-block-continuations (node)
  (let ((position (treesit-node-start node))
        continuations
        chunks)
    (cl-labels ((walk (current)
                  (if (string= (treesit-node-type current) "block_continuation")
                      (push current continuations)
                    (mapc #'walk (pimacs--markdown-node-children current)))))
      (mapc #'walk (pimacs--markdown-node-children node)))
    (dolist (continuation (sort continuations (lambda (left right)
                                                (< (treesit-node-start left)
                                                   (treesit-node-start right)))))
      (push (buffer-substring-no-properties position
                                            (treesit-node-start continuation))
            chunks)
      (setq position (treesit-node-end continuation)))
    (push (buffer-substring-no-properties position (treesit-node-end node)) chunks)
    (apply #'concat (nreverse chunks))))

(defun pimacs--markdown-inline-special-nodes (root begin end)
  (let (nodes)
    (cl-labels
        ((walk (node)
           (let ((type (treesit-node-type node))
                 (start (treesit-node-start node))
                 (finish (treesit-node-end node)))
             (cond
              ((or (<= finish begin) (>= start end)))
              ((member type '("emphasis" "strong_emphasis" "strikethrough"
                              "code_span" "inline_link" "image"
                              "full_reference_link" "shortcut_link" "collapsed_reference_link"
                              "uri_autolink" "email_autolink" "latex_block"
                              "backslash_escape" "hard_line_break" "html_tag"))
               (push node nodes))
              (t
               (mapc #'walk (pimacs--markdown-node-children node)))))))
      (walk root))
    (sort nodes (lambda (left right)
                  (< (treesit-node-start left) (treesit-node-start right))))))

(defun pimacs--markdown-html-tag-face (node)
  (pcase (pimacs--markdown-node-text node)
    ("<sup>" 'pimacs-markdown-superscript-face)
    ("<sub>" 'pimacs-markdown-subscript-face)))

(defvar pimacs-markdown-language-aliases
  '(("ocaml" . tuareg-mode)
    ("elisp" . emacs-lisp-mode)
    ("ditaa" . artist-mode)
    ("asymptote" . asy-mode)
    ("dot" . fundamental-mode)
    ("sqlite" . sql-mode)
    ("calc" . fundamental-mode)
    ("C" . c-mode)
    ("cpp" . c++-mode)
    ("C++" . c++-mode)
    ("screen" . shell-script-mode)
    ("shell" . sh-mode)
    ("bash" . sh-mode))
  "Alist mapping Markdown fence language names to major modes.")

(defun pimacs--markdown-resolve-language-mode (language)
  (or (cdr (assoc-string (downcase (or language ""))
                         pimacs-markdown-language-aliases t))
      (let ((mode (intern-soft (concat (downcase (or language "")) "-mode"))))
        (and mode (fboundp mode) mode))
      #'fundamental-mode))

(defun pimacs--markdown-fontify-code (code language)
  (with-temp-buffer
    (insert code)
    (let ((inhibit-message t)
          (mode (pimacs--markdown-resolve-language-mode language)))
      (condition-case nil
          (progn (funcall mode) (font-lock-ensure))
        (error (fundamental-mode)))
      (let ((text (buffer-string)))
        (put-text-property 0 (length text) 'face 'pimacs-markdown-code-block-face text)
        text))))

(defun pimacs--markdown-autolink-label (url faces)
  (let ((label (copy-sequence url))
        (link-faces (delq nil (append faces '(pimacs-markdown-link-face)))))
    (put-text-property 0 (length label) 'face
                       (if (= (length link-faces) 1) (car link-faces) link-faces)
                       label)
    (put-text-property 0 (length label) 'pimacs-markdown-link-url url label)
    (put-text-property 0 (length label) 'mouse-face 'highlight label)
    (put-text-property 0 (length label) 'help-echo url label)
    label))

(defun pimacs--markdown-link-label (source faces url context &optional title)
  (let ((label (pimacs--markdown-render-inline-source source context)))
    (dotimes (index (length label))
      (let* ((existing (get-text-property index 'face label))
             (label-faces (delete-dups
                           (delq nil (append faces
                                             (if (listp existing) existing (list existing))
                                             '(pimacs-markdown-link-face))))))
        (put-text-property index (1+ index) 'face
                           (if (= (length label-faces) 1)
                               (car label-faces) label-faces)
                           label)))
    (put-text-property 0 (length label) 'pimacs-markdown-link-url url label)
    (put-text-property 0 (length label) 'mouse-face 'highlight label)
    (put-text-property 0 (length label) 'help-echo url label)
    (when title
      (put-text-property 0 (length label) 'pimacs-markdown-link-title title label))
    label))

(defun pimacs--markdown-image-label (source faces url context &optional title)
  (let ((label (pimacs--markdown-link-label source faces url context title)))
    (put-text-property 0 (length label) 'pimacs-markdown-image-url url label)
    label))

(defun pimacs--markdown-render-inline-node (node context)
  (let* ((type (treesit-node-type node))
         (start (treesit-node-start node))
         (end (treesit-node-end node))
         (source (pimacs--markdown-node-text node)))
    (pcase type
      ((or "emphasis" "strong_emphasis" "strikethrough")
       (let* ((width (let ((position (treesit-node-start node))
                           (width 0))
                       (dolist (child (pimacs--markdown-node-children node))
                         (when (and (string= (treesit-node-type child)
                                             "emphasis_delimiter")
                                    (= (treesit-node-start child) position))
                           (setq width (+ width
                                          (length (pimacs--markdown-node-text child))))
                           (setq position (treesit-node-end child))))
                       width))
              (face (pcase type
                      ("emphasis" 'pimacs-markdown-italic-face)
                      ("strong_emphasis" 'pimacs-markdown-bold-face)
                      (_ 'pimacs-markdown-strike-through-face))))
         (pimacs--markdown-propertize-outer-face
          (pimacs--markdown-render-inline-range (+ start width) (- end width) context)
          face)))
      ("code_span"
       (let* ((delimiter (pimacs--markdown-node-child node "code_span_delimiter"))
              (width (if delimiter (length (pimacs--markdown-node-text delimiter)) 0))
              (text (substring source width (- width))))
         (when (string-match-p "\\` .* \\'" text)
           (setq text (substring text 1 -1)))
         (pimacs--markdown-propertize-face text 'pimacs-markdown-inline-code-face)))
      ("inline_link"
       (let ((label (pimacs--markdown-node-child node "link_text"))
             (destination (pimacs--markdown-node-child node "link_destination"))
             (title (pimacs--markdown-node-child node "link_title")))
         (if (and label destination)
             (pimacs--markdown-link-label
              (pimacs--markdown-node-text label) nil
              (string-trim (pimacs--markdown-node-text destination) "<" ">")
              context
              (and title (string-trim (pimacs--markdown-node-text title) "\"'(" "\"')")))
           source)))
      ((or "full_reference_link" "shortcut_link" "collapsed_reference_link")
       (let* ((label (pimacs--markdown-node-child node "link_text"))
              (reference (if (string= type "full_reference_link")
                             (pimacs--markdown-node-child node "link_label")
                           label))
              (definition (and reference
                               (assoc-string
                                (pimacs--markdown-reference-label
                                 (pimacs--markdown-node-text reference))
                                (pimacs--markdown-render-context-reference-definitions
                                 context)
                                t))))
         (if (and label definition)
             (pimacs--markdown-link-label
              (pimacs--markdown-node-text label) nil
              (car definition) context (cadr definition))
           source)))
      ("image"
       (let ((label (or (pimacs--markdown-node-child node "image_description")
                        (pimacs--markdown-node-child node "link_text")))
             (destination (pimacs--markdown-node-child node "link_destination"))
             (title (pimacs--markdown-node-child node "link_title")))
         (if (and label destination)
             (pimacs--markdown-image-label
              (pimacs--markdown-node-text label) nil
              (string-trim (pimacs--markdown-node-text destination) "<" ">")
              context
              (and title (string-trim (pimacs--markdown-node-text title) "\"'(" "\"')")))
           source)))
      ((or "uri_autolink" "email_autolink")
       (pimacs--markdown-autolink-label (string-trim source "<" ">") nil))
      ((or "backslash_escape" "hard_line_break")
       (string-remove-prefix "\\" source))
      ("html_tag"
       (if (member source '("<br>" "<br/>" "<br />")) "\n" source))
      ("latex_block"
       (pimacs--markdown-propertize-face
        (string-trim (string-trim source "\\$+" "\\$+"))
        'pimacs-markdown-equation-face))
      (_ source))))

(defun pimacs--markdown-render-inline-tree-range (root begin end context)
  (let ((position begin)
        (nodes (pimacs--markdown-inline-special-nodes root begin end))
        chunks)
    (while nodes
      (let* ((node (pop nodes))
             (start (treesit-node-start node))
             (finish (treesit-node-end node)))
        (when (and (>= start position) (<= finish end))
          (push (buffer-substring-no-properties position start) chunks)
          (let ((face (and (string= (treesit-node-type node) "html_tag")
                           (pimacs--markdown-html-tag-face node))))
            (if face
                (let ((closing-tag (concat "</" (substring (pimacs--markdown-node-text node) 1 -1) ">"))
                      closing-node
                      remaining)
                  (setq remaining nodes)
                  (while (and remaining (not closing-node))
                    (when (and (string= (treesit-node-type (car remaining)) "html_tag")
                               (string= (pimacs--markdown-node-text (car remaining)) closing-tag))
                      (setq closing-node (car remaining)))
                    (setq remaining (cdr remaining)))
                  (if closing-node
                      (progn
                        (push (pimacs--markdown-propertize-face
                               (pimacs--markdown-render-inline-range
                                finish (treesit-node-start closing-node) context)
                               face)
                              chunks)
                        (setq position (treesit-node-end closing-node))
                        (setq nodes remaining))
                    (push (pimacs--markdown-render-inline-node node context) chunks)
                    (setq position finish)))
              (push (pimacs--markdown-render-inline-node node context) chunks)
              (setq position finish))))))
    (push (buffer-substring-no-properties position end) chunks)
    (apply #'concat (nreverse chunks))))

(defun pimacs--markdown-render-inline-source (text context)
  (pimacs--markdown-with-parser
   text 'markdown_inline
   (lambda (root)
     (pimacs--markdown-render-inline-tree-range
      root 1 (point-max) context))))

(defun pimacs--markdown-render-inline-range (begin end context)
  (pimacs--markdown-render-inline-source
   (buffer-substring-no-properties begin end) context))

(defun pimacs--markdown-render-table-node (node context)
  (let* ((header (pimacs--markdown-node-child node "pipe_table_header"))
         (delimiter (pimacs--markdown-node-child node "pipe_table_delimiter_row"))
         (header-cells (and header (pimacs--markdown-node-children header)))
         (delimiter-cells (and delimiter (pimacs--markdown-node-children delimiter)))
         (rows (cl-remove-if-not (lambda (child)
                                   (string= (treesit-node-type child) "pipe_table_row"))
                                 (pimacs--markdown-node-children node))))
    (if (or (null header-cells) (null delimiter-cells))
        (pimacs--markdown-node-text node)
      (pimacs--markdown-table-render
       (mapcar (lambda (cell)
                 (or (split-string
                      (pimacs--markdown-render-inline-source
                       (string-trim (pimacs--markdown-node-text cell)) context)
                      "\n" nil)
                     '("")))
               header-cells)
       (mapcar (lambda (cell)
                 (let ((delimiter (string-trim (pimacs--markdown-node-text cell))))
                   (cond
                    ((and (string-prefix-p ":" delimiter)
                          (string-suffix-p ":" delimiter))
                     'center)
                    ((string-suffix-p ":" delimiter) 'right)
                    (t 'left))))
               delimiter-cells)
       (mapcar (lambda (row)
                 (mapcar (lambda (cell)
                           (or (split-string
                                (pimacs--markdown-render-inline-source
                                 (string-trim (pimacs--markdown-node-text cell)) context)
                                "\n" nil)
                               '("")))
                         (pimacs--markdown-node-children row)))
               rows)
       (string-suffix-p "\n" (pimacs--markdown-node-text node))))))

(defun pimacs--markdown-render-indented-code-block (node)
  (pimacs--markdown-propertize-face
   (replace-regexp-in-string "^    " "" (pimacs--markdown-node-text node))
   'pimacs-markdown-code-block-face))

(defun pimacs--markdown-render-fenced-code-block (node)
  (let* ((source (pimacs--markdown-node-text node))
         (delimiter (pimacs--markdown-node-child node "fenced_code_block_delimiter"))
         (language-node (pimacs--markdown-node-child node "language"))
         (content (pimacs--markdown-node-child node "code_fence_content"))
         (language (and language-node (pimacs--markdown-node-text language-node))))
    (if (and delimiter content)
        (pimacs--markdown-fontify-code
         (pimacs--markdown-node-text-without-block-continuations content)
         language)
      source)))

(defun pimacs--markdown-render-block-children (node context)
  (let ((position (treesit-node-start node))
        chunks)
    (dolist (child (pimacs--markdown-node-children node))
      (push (buffer-substring-no-properties position (treesit-node-start child)) chunks)
      (push (pimacs--markdown-render-block-node child context) chunks)
      (setq position (treesit-node-end child)))
    (push (buffer-substring-no-properties position (treesit-node-end node)) chunks)
    (apply #'concat (nreverse chunks))))

(defun pimacs--markdown-render-heading-node (node context)
  (let ((inline (pimacs--markdown-node-child node "inline"))
        (source (pimacs--markdown-node-text-without-block-continuations node)))
    (concat
     (if inline
         (pimacs--markdown-propertize-face
          (pimacs--markdown-render-inline-source
           (pimacs--markdown-node-text-without-block-continuations inline)
           context)
          'pimacs-markdown-heading-face)
       "")
     (if (string-suffix-p "\n" source) "\n" ""))))

(defun pimacs--markdown-render-paragraph-node (node context)
  (let ((inline (pimacs--markdown-node-child node "inline"))
        (source (pimacs--markdown-node-text node)))
    (if inline
        (pimacs--markdown-render-inline-source
         (pimacs--markdown-node-text-without-block-continuations node)
         context)
      source)))

(defun pimacs--markdown-render-list-node (node context)
  (let* ((children (pimacs--markdown-node-children node))
         (first-marker (and children
                            (pimacs--markdown-node-child
                             (car children) "list_marker_dot")))
         (start (and first-marker
                     (string-match "[0-9]+"
                                   (pimacs--markdown-node-text first-marker))
                     (string-to-number (match-string 0
                                                     (pimacs--markdown-node-text first-marker)))))
         (position (treesit-node-start node))
         (number start)
         chunks)
    (dolist (child children)
      (let* ((gap (buffer-substring-no-properties
                   position (treesit-node-start child)))
             (marker (pimacs--markdown-node-child child "list_marker_dot"))
             (item-source (pimacs--markdown-node-text child))
             (gap-separated (string-match-p "\n[ \t]*\n" gap))
             (source-separated (string-match-p "\n[ \t]*\n\\'" item-source)))
        (when gap-separated
          (when chunks
            (push "\n" chunks))
          (setq number nil))
        (let ((item-number (or number
                               (and marker
                                    (string-match "[0-9]+"
                                                  (pimacs--markdown-node-text marker))
                                    (string-to-number
                                     (match-string 0
                                                   (pimacs--markdown-node-text marker)))))))
          (push (pimacs--markdown-render-block-node
                 child
                 (pimacs--markdown-render-context-for-list-item
                  context item-number))
                chunks)
          (setq number (and item-number (1+ item-number))))
        (when source-separated
          (push "\n" chunks)
          (setq number nil))
        (setq position (treesit-node-end child))))
    (apply #'concat (nreverse chunks))))

(defun pimacs--markdown-render-list-item-prefix (node context)
  (let* ((list-depth (pimacs--markdown-render-context-list-depth context))
         (list-index (pimacs--markdown-render-context-list-index context))
         (marker (cl-find-if (lambda (child)
                               (string-prefix-p "list_marker_"
                                                (treesit-node-type child)))
                             (pimacs--markdown-node-children node)))
         (checked-node (pimacs--markdown-node-child node "task_list_marker_checked"))
         (unchecked-node (pimacs--markdown-node-child node "task_list_marker_unchecked"))
         (checked (and checked-node
                       (string= (pimacs--markdown-node-text checked-node) "[x]")))
         (unchecked (and unchecked-node
                         (string= (pimacs--markdown-node-text unchecked-node) "[ ]")))
         (literal-marker (and (or checked-node unchecked-node)
                              (not (or checked unchecked)))))
    (concat
     (make-string (* 2 (1- (or list-depth 1))) ?\s)
     (pimacs--markdown-propertize-face
      (cond
       ((and marker (string-match-p "[.)]" (pimacs--markdown-node-text marker)))
        (if list-index
            (concat (number-to-string list-index)
                    (if (string-match-p ")" (pimacs--markdown-node-text marker)) ") " ". "))
          (concat (string-trim (pimacs--markdown-node-text marker)) " ")))
       (t (concat (nth (mod (1- (or list-depth 1))
                            (length pimacs--markdown-list-bullets))
                       pimacs--markdown-list-bullets)
                  " ")))
      'pimacs-markdown-list-marker-face)
     (cond
      (checked (concat (pimacs--markdown-propertize-face
                        "[x]" 'pimacs-markdown-checkbox-face)
                       " "))
      (unchecked (concat (pimacs--markdown-propertize-face
                          "[ ]" 'pimacs-markdown-checkbox-face)
                         " "))
      (literal-marker (concat (pimacs--markdown-node-text
                               (or checked-node unchecked-node))
                              " "))
      (t "")))))

(defun pimacs--markdown-render-list-item-child (child context)
  (let ((child-type (treesit-node-type child))
        (rendered (pimacs--markdown-render-block-node child context)))
    (when (string= child-type "list")
      (setq rendered (replace-regexp-in-string "[ \t]+\\'" "" rendered)))
    (when (string= child-type "paragraph")
      (setq rendered (string-trim-left rendered))
      (setq rendered
            (replace-regexp-in-string
             "\n\\([^ \n]\\)"
             (concat "\n"
                     (make-string
                      (* 2 (max 0 (- (or (pimacs--markdown-render-context-list-depth context) 1)
                                     2)))
                      ?\s)
                     "\\1")
             rendered)))
    (cons child-type rendered)))

(defun pimacs--markdown-render-list-item-children (node context)
  (let ((children (pimacs--markdown-node-children-without-types
                   node
                   '("list_marker_dot" "list_marker_minus"
                     "list_marker_parenthesis" "list_marker_plus"
                     "list_marker_star" "task_list_marker_checked"
                     "task_list_marker_unchecked"
                     "block_continuation")))
        chunks
        previous)
    (dolist (child children)
      (let* ((rendered-child (pimacs--markdown-render-list-item-child child context))
             (child-type (car rendered-child))
             (rendered (cdr rendered-child)))
        (when (and (string= child-type "paragraph")
                   (string= previous "list"))
          (push "\n" chunks))
        (push rendered chunks)
        (setq previous child-type)))
    (apply #'concat (nreverse chunks))))

(defun pimacs--markdown-render-list-item-node (node context)
  (concat (pimacs--markdown-render-list-item-prefix node context)
          (pimacs--markdown-render-list-item-children node context)))

(defun pimacs--markdown-render-block-quote-node (node context)
  (pimacs--markdown-propertize-blockquote-face
   (pimacs--markdown-quote-lines
    (apply #'concat
           (mapcar (lambda (child)
                     (pimacs--markdown-render-block-node child context))
                   (pimacs--markdown-node-children-without-types
                    node '("block_quote_marker" "block_continuation")))))))

(defun pimacs--markdown-render-thematic-break-node (node)
  (let ((source (pimacs--markdown-node-text node)))
    (concat (pimacs--markdown-propertize-face
             (make-string (min 80 (window-width)) ?─)
             'pimacs-markdown-horizontal-rule-face)
            (if (string-suffix-p "\n" source) "\n" ""))))

(defun pimacs--markdown-render-block-node (node context)
  (pcase (treesit-node-type node)
    ((or "document" "section")
     (pimacs--markdown-render-block-children node context))
    ("atx_heading"
     (pimacs--markdown-render-heading-node node context))
    ("paragraph"
     (pimacs--markdown-render-paragraph-node node context))
    ("list"
     (pimacs--markdown-render-list-node node context))
    ("list_item"
     (pimacs--markdown-render-list-item-node node context))
    ("block_quote"
     (pimacs--markdown-render-block-quote-node node context))
    ("fenced_code_block"
     (pimacs--markdown-render-fenced-code-block node))
    ("indented_code_block"
     (pimacs--markdown-render-indented-code-block node))
    ("thematic_break"
     (pimacs--markdown-render-thematic-break-node node))
    ("link_reference_definition"
     "")
    ("pipe_table"
     (pimacs--markdown-render-table-node node context))
    (_
     (pimacs--markdown-node-text node))))

(defun pimacs--markdown-render-source (text)
  (pimacs--markdown-parse-source text #'pimacs--markdown-render-block-node))

(defun pimacs--render-markdown-experimental (_context text streaming)
  (list (list :append
              (if streaming text (pimacs--markdown-render-source text)))))

(provide 'pimacs-markdown)

;;; pimacs-markdown.el ends here
