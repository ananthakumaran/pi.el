;;; pimacs-markdown.el --- Incremental Markdown rendering -*- lexical-binding: t; -*-

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

;; Markdown is parsed by tree-sitter.  The block parser and the inline parser
;; are persistent parsers over a private buffer, so inserting a stream delta
;; reparses only tree-sitter's changed range.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'treesit)

(cl-defstruct pimacs-markdown-parser
  buffer
  block-parser
  inline-parser
  block-root
  inline-root
  blocks
  rendered
  operations)

(cl-defstruct pimacs-markdown-context
  parser
  content-begin
  content-end
  rendered-length)

(defun pimacs--markdown-parser-new ()
  (let ((buffer (generate-new-buffer " *pimacs-markdown*")))
    (condition-case error
        (with-current-buffer buffer
          (make-pimacs-markdown-parser
           :buffer buffer
           :block-parser (treesit-parser-create 'markdown)
           :inline-parser (treesit-parser-create 'markdown_inline)
           :rendered ""))
      (error
       (kill-buffer buffer)
       (user-error
        "Pimacs Markdown requires tree-sitter grammars `markdown' and `markdown_inline': %s"
        (error-message-string error))))))

(defun pimacs--markdown-node-children (node)
  (cl-loop for index below (treesit-node-child-count node t)
           collect (treesit-node-child node index t)))

(defun pimacs--markdown-node-child (node type)
  (cl-find type (pimacs--markdown-node-children node)
           :key #'treesit-node-type :test #'string=))

(defun pimacs--markdown-node-text (node)
  (treesit-node-text node t))

(defun pimacs--markdown-inline-ranges (node)
  (append
   (when (string= (treesit-node-type node) "inline")
     (list (cons (treesit-node-start node) (treesit-node-end node))))
   (cl-mapcan #'pimacs--markdown-inline-ranges
              (pimacs--markdown-node-children node))))

(defun pimacs--markdown-parser-update-trees (parser)
  (with-current-buffer (pimacs-markdown-parser-buffer parser)
    (let ((block-root (treesit-parser-root-node
                       (pimacs-markdown-parser-block-parser parser))))
      (setf (pimacs-markdown-parser-block-root parser) block-root))))

(defun pimacs--markdown-node-has-parent-p (node types)
  (while (and node (not (member (treesit-node-type node) types)))
    (setq node (treesit-node-parent node)))
  node)

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
                              "uri_autolink" "email_autolink" "latex_block"))
               (push node nodes))
              (t
               (mapc #'walk (pimacs--markdown-node-children node)))))))
      (walk root))
    (sort nodes (lambda (left right)
                  (< (treesit-node-start left) (treesit-node-start right))))))

(defun pimacs--markdown-propertize-face (text face)
  (when (> (length text) 0)
    (put-text-property 0 (length text) 'face face text))
  text)

(defun pimacs--markdown-render-inline-node (parser node)
  (let* ((type (treesit-node-type node))
         (start (treesit-node-start node))
         (end (treesit-node-end node))
         (source (pimacs--markdown-node-text node)))
    (pcase type
      ((or "emphasis" "strong_emphasis" "strikethrough")
       (let* ((width (if (string-match "\\`[*_~]+" source)
                         (length (match-string 0 source))
                       0))
              (face (pcase type
                      ("emphasis" 'pimacs-markdown-italic-face)
                      ("strong_emphasis" 'pimacs-markdown-bold-face)
                      (_ 'pimacs-markdown-strike-through-face))))
         (pimacs--markdown-propertize-face
          (pimacs--markdown-render-inline-range parser (+ start width) (- end width))
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
              (and title (string-trim (pimacs--markdown-node-text title) "\"'(" "\"')")))
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
              (and title (string-trim (pimacs--markdown-node-text title) "\"'(" "\"')")))
           source)))
      ((or "uri_autolink" "email_autolink")
       (pimacs--markdown-autolink-label (string-trim source "<" ">") nil))
      ("latex_block"
       (pimacs--markdown-propertize-face
        (string-trim source "$") 'pimacs-markdown-equation-face))
      (_ source))))

(defun pimacs--markdown-render-inline-tree-range (parser begin end)
  (let ((position begin)
        (root (pimacs-markdown-parser-inline-root parser))
        chunks)
    (dolist (node (pimacs--markdown-inline-special-nodes root begin end))
      (let ((start (treesit-node-start node))
            (finish (treesit-node-end node)))
        (when (and (>= start position) (<= finish end))
          (push (buffer-substring-no-properties position start) chunks)
          (push (pimacs--markdown-render-inline-node parser node) chunks)
          (setq position finish))))
    (push (buffer-substring-no-properties position end) chunks)
    (apply #'concat (nreverse chunks))))

(defun pimacs--markdown-render-inline-source (text)
  (let ((buffer (generate-new-buffer " *pimacs-markdown-inline*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert text)
          (let* ((inline-parser (treesit-parser-create 'markdown_inline))
                 (parser (make-pimacs-markdown-parser
                          :buffer buffer :inline-parser inline-parser
                          :inline-root (treesit-parser-root-node inline-parser))))
            (pimacs--markdown-render-inline-tree-range parser 1 (point-max))))
      (kill-buffer buffer))))

(defun pimacs--markdown-render-inline-range (_parser begin end)
  (pimacs--markdown-render-inline-source
   (buffer-substring-no-properties begin end)))

(defun pimacs--markdown-render-inline (text)
  (pimacs--markdown-render-inline-source text))

(defun pimacs--markdown-render-code-block (node)
  (let ((source (pimacs--markdown-node-text node)))
    (if (string= (treesit-node-type node) "indented_code_block")
        (pimacs--markdown-propertize-face
         (replace-regexp-in-string "^    " "" source)
         'pimacs-markdown-code-block-face)
      (let* ((delimiter (pimacs--markdown-node-child node "fenced_code_block_delimiter"))
             (language-node (pimacs--markdown-node-child node "language"))
             (content (pimacs--markdown-node-child node "code_fence_content"))
             (language (and language-node (pimacs--markdown-node-text language-node))))
        (if (and delimiter content)
            (pimacs--markdown-fontify-code
             (pimacs--markdown-node-text content) language)
          source)))))

(defun pimacs--markdown-render-block-node (parser node)
  (let ((type (treesit-node-type node))
        (source (pimacs--markdown-node-text node)))
    (pcase type
      ((or "document" "section")
       (apply #'concat (mapcar (lambda (child)
                                 (pimacs--markdown-render-block-node parser child))
                               (pimacs--markdown-node-children node))))
      ("atx_heading"
       (let ((inline (pimacs--markdown-node-child node "inline")))
         (concat
          (if inline
              (pimacs--markdown-propertize-face
               (pimacs--markdown-render-inline-range
                parser (treesit-node-start inline) (treesit-node-end inline))
               'pimacs-markdown-heading-face)
            "")
          (if (string-suffix-p "\n" source) "\n" ""))))
      ("paragraph"
       (let ((inline (pimacs--markdown-node-child node "inline")))
         (if inline
             (concat
              (pimacs--markdown-render-inline-range
               parser (treesit-node-start inline) (treesit-node-end inline))
              (substring source (- (treesit-node-end inline)
                                   (treesit-node-start node))))
           source)))
      ("list"
       (apply #'concat (mapcar (lambda (child)
                                 (pimacs--markdown-render-block-node parser child))
                               (pimacs--markdown-node-children node))))
      ("list_item"
       (let* ((marker (cl-find-if (lambda (child)
                                    (string-prefix-p "list_marker_"
                                                     (treesit-node-type child)))
                                  (pimacs--markdown-node-children node)))
              (checked (pimacs--markdown-node-child node "task_list_marker_checked"))
              (unchecked (pimacs--markdown-node-child node "task_list_marker_unchecked"))
              (children (cl-remove-if
                         (lambda (child)
                           (member (treesit-node-type child)
                                   '("list_marker_dot" "list_marker_minus"
                                     "list_marker_parenthesis" "list_marker_plus"
                                     "list_marker_star" "task_list_marker_checked"
                                     "task_list_marker_unchecked")))
                         (pimacs--markdown-node-children node))))
         (concat
          (cond
           (checked (pimacs--markdown-propertize-face "☑ " 'pimacs-markdown-checkbox-face))
           (unchecked (pimacs--markdown-propertize-face "☐ " 'pimacs-markdown-checkbox-face))
           ((and marker (string-match-p "[.)]" (pimacs--markdown-node-text marker)))
            (concat (string-trim (pimacs--markdown-node-text marker)) " "))
           (t (pimacs--markdown-propertize-face "● " 'pimacs-markdown-list-marker-face)))
          (apply #'concat (mapcar (lambda (child)
                                    (pimacs--markdown-render-block-node parser child))
                                  children)))))
      ("block_quote"
       (pimacs--markdown-propertize-face
        (apply #'concat (mapcar (lambda (child)
                                  (pimacs--markdown-render-block-node parser child))
                                (cl-remove-if (lambda (child)
                                                (string= (treesit-node-type child)
                                                         "block_quote_marker"))
                                              (pimacs--markdown-node-children node))))
        'pimacs-markdown-blockquote-face))
      ((or "fenced_code_block" "indented_code_block")
       (pimacs--markdown-render-code-block node))
      ("thematic_break"
       (concat (pimacs--markdown-propertize-face
                (make-string (min 80 (window-width)) ?─)
                'pimacs-markdown-horizontal-rule-face)
               (if (string-suffix-p "\n" source) "\n" "")))
      ("link_reference_definition" "")
      (_ source))))

(defun pimacs--markdown-parser-block-nodes (node)
  (if (member (treesit-node-type node) '("document" "section"))
      (cl-mapcan #'pimacs--markdown-parser-block-nodes
                 (pimacs--markdown-node-children node))
    (list node)))

(defun pimacs--markdown-parser-block-record (node rendered)
  (list :start (treesit-node-start node)
        :end (treesit-node-end node)
        :type (treesit-node-type node)
        :rendered rendered))

(defun pimacs--markdown-parser-same-block-p (record node)
  (and (= (plist-get record :start) (treesit-node-start node))
       (= (plist-get record :end) (treesit-node-end node))
       (string= (plist-get record :type) (treesit-node-type node))))

(defun pimacs--markdown-parser-render (parser)
  (with-current-buffer (pimacs-markdown-parser-buffer parser)
    (pimacs--markdown-parser-update-trees parser)
    (let* ((old-rendered (pimacs-markdown-parser-rendered parser))
           (nodes (pimacs--markdown-parser-block-nodes
                   (pimacs-markdown-parser-block-root parser)))
           (previous (pimacs-markdown-parser-blocks parser))
           (stable nil))
      (while (and previous nodes
                  (pimacs--markdown-parser-same-block-p (car previous)
                                                        (car nodes)))
        (push (pop previous) stable)
        (pop nodes))
      (setq stable (nreverse stable))
      (let* ((prefix (apply #'+ 0 (mapcar (lambda (record)
                                            (length (plist-get record :rendered)))
                                          stable)))
             (tail-records
              (mapcar (lambda (node)
                        (pimacs--markdown-parser-block-record
                         node (pimacs--markdown-render-block-node parser node)))
                      nodes))
             (tail (apply #'concat (mapcar (lambda (record)
                                             (plist-get record :rendered))
                                           tail-records)))
             (rendered (concat (apply #'concat (mapcar (lambda (record)
                                                         (plist-get record :rendered))
                                                       stable))
                               tail)))
        (let (operations)
          (when (> (length old-rendered) prefix)
            (push (list :delete (- (length old-rendered) prefix)) operations))
          (when (> (length tail) 0)
            (push (list :append tail) operations))
          (setf (pimacs-markdown-parser-blocks parser) (append stable tail-records)
                (pimacs-markdown-parser-rendered parser) rendered
                (pimacs-markdown-parser-operations parser) (nreverse operations)))))))

(defconst pimacs--markdown-special-regexp
  (regexp-opt '("\n" "`" "*" "_" "~" "!" "$" "<" "[" "]")))

(defun pimacs--markdown-parser-plain-tail-p (parser delta)
  (and (not (string-match-p pimacs--markdown-special-regexp delta))
       (with-current-buffer (pimacs-markdown-parser-buffer parser)
         (let ((end (point-max)))
           (not (string-match-p pimacs--markdown-special-regexp
                                (buffer-substring-no-properties
                                 (line-beginning-position) end)))))))

(defun pimacs--markdown-parser-write (parser delta)
  (with-current-buffer (pimacs-markdown-parser-buffer parser)
    (goto-char (point-max))
    (insert delta))
  (if (pimacs--markdown-parser-plain-tail-p parser delta)
      (setf (pimacs-markdown-parser-rendered parser)
            (concat (pimacs-markdown-parser-rendered parser) delta)
            (pimacs-markdown-parser-operations parser) (list (list :append delta)))
    (pimacs--markdown-parser-render parser)))

(defun pimacs--markdown-parser-finish (parser _final-p)
  (pimacs--markdown-parser-render parser))

;;; Markdown Renderer

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

(defface pimacs-markdown-highlight-face
  '((t :inherit highlight))
  "Face used for Markdown highlighted text."
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

(defface pimacs-markdown-table-header-face
  '((t :inherit fixed-pitch))
  "Face used for Markdown table headers."
  :group 'pimacs)

(defface pimacs-markdown-table-border-face
  '((t :inherit fixed-pitch))
  "Face used for Markdown table borders."
  :group 'pimacs)

(defcustom pimacs-markdown-use-unicode-tables t
  "Whether to render Markdown tables with Unicode borders."
  :type 'boolean
  :group 'pimacs)

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

(defun pimacs--markdown-link-label (source faces url &optional title)
  (let ((label (pimacs--markdown-render-inline source)))
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

(defun pimacs--markdown-image-label (source faces url &optional title)
  (let ((label (pimacs--markdown-link-label source faces url title)))
    (put-text-property 0 (length label) 'pimacs-markdown-image-url url label)
    label))

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

(defun pimacs--render-markdown-experimental (context text streaming)
  (if streaming
      (let ((parser (or (pimacs-markdown-context-parser context)
                        (pimacs--markdown-parser-new))))
        (setf (pimacs-markdown-context-parser context) parser)
        (pimacs--markdown-parser-write parser text)
        (prog1 (pimacs-markdown-parser-operations parser)
          (setf (pimacs-markdown-parser-operations parser) nil)))
    (let ((streaming-parser (pimacs-markdown-context-parser context))
          (parser (pimacs--markdown-parser-new)))
      (unwind-protect
          (progn
            (pimacs--markdown-parser-write parser text)
            (list (list :delete (pimacs-markdown-context-rendered-length context))
                  (list :append (pimacs-markdown-parser-rendered parser))))
        (kill-buffer (pimacs-markdown-parser-buffer parser))
        (when streaming-parser
          (kill-buffer (pimacs-markdown-parser-buffer streaming-parser))
          (setf (pimacs-markdown-context-parser context) nil))))))

(provide 'pimacs-markdown)

;;; pimacs-markdown.el ends here
