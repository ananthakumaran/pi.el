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

(add-to-list 'treesit-load-name-override-list
             '(markdown_inline "libtree-sitter-markdown-inline" "tree_sitter_markdown_inline"))

;;; Markdown Parser

(defun pimacs--markdown-node-children (node)
  (cl-loop for index below (treesit-node-child-count node t)
           collect (treesit-node-child node index t)))

(defun pimacs--markdown-node-child (node type)
  (cl-find type (pimacs--markdown-node-children node)
           :key #'treesit-node-type :test #'string=))

(defun pimacs--markdown-node-text (node)
  (treesit-node-text node t))


(defun pimacs--markdown-render-source (text)
  (let ((buffer (generate-new-buffer " *pimacs-markdown*")))
    (unwind-protect
        (condition-case error
            (with-current-buffer buffer
              (let ((parser (treesit-parser-create 'markdown)))
                (insert text)
                (pimacs--markdown-render-block-node
                 (treesit-parser-root-node parser))))
          (error
           (user-error
            "Pimacs Markdown requires tree-sitter grammars `markdown' and `markdown_inline': %s"
            (error-message-string error))))
      (kill-buffer buffer))))

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
                              "uri_autolink" "email_autolink" "latex_block"
                              "backslash_escape" "hard_line_break" "html_tag"))
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

(defun pimacs--markdown-propertize-blockquote-face (text)
  (dotimes (index (length text))
    (let ((existing (get-text-property index 'face text)))
      (unless (memq 'pimacs-markdown-code-block-face (ensure-list existing))
        (put-text-property index (1+ index) 'face
                           (if existing
                               (append (ensure-list existing)
                                       '(pimacs-markdown-blockquote-face))
                             'pimacs-markdown-blockquote-face)
                           text))))
  text)

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

(defun pimacs--markdown-render-inline-node (node)
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
          (pimacs--markdown-render-inline-range (+ start width) (- end width))
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
      ((or "backslash_escape" "hard_line_break")
       (string-remove-prefix "\\" source))
      ("html_tag"
       (if (member source '("<br>" "<br/>" "<br />")) "\n" source))
      ("latex_block"
       (pimacs--markdown-propertize-face
        (string-trim (string-trim source "\\$+" "\\$+"))
        'pimacs-markdown-equation-face))
      (_ source))))

(defun pimacs--markdown-html-tag-face (node)
  (pcase (pimacs--markdown-node-text node)
    ("<sup>" 'pimacs-markdown-superscript-face)
    ("<sub>" 'pimacs-markdown-subscript-face)))

(defun pimacs--markdown-render-inline-tree-range (root begin end)
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
                                finish (treesit-node-start closing-node))
                               face)
                              chunks)
                        (setq position (treesit-node-end closing-node))
                        (setq nodes remaining))
                    (push (pimacs--markdown-render-inline-node node) chunks)
                    (setq position finish)))
              (push (pimacs--markdown-render-inline-node node) chunks)
              (setq position finish))))))
    (push (buffer-substring-no-properties position end) chunks)
    (apply #'concat (nreverse chunks))))

(defun pimacs--markdown-render-inline-source (text)
  (let ((buffer (generate-new-buffer " *pimacs-markdown-inline*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert text)
          (let ((inline-parser (treesit-parser-create 'markdown_inline)))
            (pimacs--markdown-render-inline-tree-range
             (treesit-parser-root-node inline-parser) 1 (point-max))))
      (kill-buffer buffer))))

(defun pimacs--markdown-render-inline-range (begin end)
  (pimacs--markdown-render-inline-source
   (buffer-substring-no-properties begin end)))

(defun pimacs--markdown-render-inline (text)
  (pimacs--markdown-render-inline-source text))

(defun pimacs--markdown-render-block-children (node)
  (let ((position (treesit-node-start node))
        chunks)
    (dolist (child (pimacs--markdown-node-children node))
      (push (buffer-substring-no-properties position (treesit-node-start child)) chunks)
      (push (pimacs--markdown-render-block-node child) chunks)
      (setq position (treesit-node-end child)))
    (push (buffer-substring-no-properties position (treesit-node-end node)) chunks)
    (apply #'concat (nreverse chunks))))

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
             (pimacs--markdown-node-text-without-block-continuations content) language)
          source)))))

(defun pimacs--markdown-render-block-node (node)
  (let ((type (treesit-node-type node))
        (source (pimacs--markdown-node-text node)))
    (pcase type
      ((or "document" "section")
       (pimacs--markdown-render-block-children node))
      ("atx_heading"
       (let ((inline (pimacs--markdown-node-child node "inline"))
             (source (pimacs--markdown-node-text-without-block-continuations node)))
         (concat
          (if inline
              (pimacs--markdown-propertize-face
               (pimacs--markdown-render-inline
                (pimacs--markdown-node-text-without-block-continuations inline))
               'pimacs-markdown-heading-face)
            "")
          (if (string-suffix-p "\n" source) "\n" ""))))
      ("paragraph"
       (let ((inline (pimacs--markdown-node-child node "inline")))
         (if inline
             (pimacs--markdown-render-inline
              (pimacs--markdown-node-text-without-block-continuations node))
           source)))
      ("list"
       (apply #'concat (mapcar #'pimacs--markdown-render-block-node
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
            (pimacs--markdown-propertize-face
             (concat (string-trim (pimacs--markdown-node-text marker)) " ")
             'pimacs-markdown-list-marker-face))
           (t (pimacs--markdown-propertize-face "● " 'pimacs-markdown-list-marker-face)))
          (apply #'concat (mapcar #'pimacs--markdown-render-block-node children)))))
      ("block_quote"
       (pimacs--markdown-propertize-blockquote-face
        (apply #'concat
               (mapcar #'pimacs--markdown-render-block-node
                       (cl-remove-if (lambda (child)
                                       (string= (treesit-node-type child)
                                                "block_quote_marker"))
                                     (pimacs--markdown-node-children node))))))
      ((or "fenced_code_block" "indented_code_block")
       (pimacs--markdown-render-code-block node))
      ("thematic_break"
       (concat (pimacs--markdown-propertize-face
                (make-string (min 80 (window-width)) ?─)
                'pimacs-markdown-horizontal-rule-face)
               (if (string-suffix-p "\n" source) "\n" "")))
      ("link_reference_definition" "")
      ("pipe_table" (pimacs--markdown-render-table node))
      (_ source))))

(defun pimacs--markdown-table-header-face (text)
  (dotimes (index (length text))
    (unless (get-text-property index 'face text)
      (put-text-property index (1+ index) 'face 'pimacs-markdown-table-header-face text)))
  text)

(defun pimacs--markdown-table-cell-lines (cell)
  (or (split-string
       (pimacs--markdown-render-inline
        (string-trim (pimacs--markdown-node-text cell)))
       "\n" nil)
      '("")))

(defun pimacs--markdown-table-alignment (cell)
  (let ((delimiter (string-trim (pimacs--markdown-node-text cell))))
    (cond
     ((and (string-prefix-p ":" delimiter) (string-suffix-p ":" delimiter)) 'center)
     ((string-suffix-p ":" delimiter) 'right)
     (t 'left))))

(defun pimacs--markdown-table-pad (text width alignment)
  (let ((padding (- width (string-width text))))
    (pcase alignment
      ('right (concat (make-string padding ?\s) text))
      ('center (let ((left (/ padding 2)))
                 (concat (make-string left ?\s)
                         text
                         (make-string (- padding left) ?\s))))
      (_ (concat text (make-string padding ?\s))))))

(defun pimacs--markdown-render-table (node)
  (let* ((header (pimacs--markdown-node-child node "pipe_table_header"))
         (delimiter (pimacs--markdown-node-child node "pipe_table_delimiter_row"))
         (header-cells (and header (pimacs--markdown-node-children header)))
         (delimiter-cells (and delimiter (pimacs--markdown-node-children delimiter)))
         (rows (cl-remove-if-not (lambda (child)
                                   (string= (treesit-node-type child) "pipe_table_row"))
                                 (pimacs--markdown-node-children node))))
    (if (or (null header-cells) (null delimiter-cells))
        (pimacs--markdown-node-text node)
      (let* ((column-count (length header-cells))
             (alignments (mapcar #'pimacs--markdown-table-alignment delimiter-cells))
             (header-data (mapcar #'pimacs--markdown-table-cell-lines header-cells))
             (row-data (mapcar (lambda (row)
                                 (mapcar #'pimacs--markdown-table-cell-lines
                                         (pimacs--markdown-node-children row)))
                               rows))
             (all-rows (cons header-data row-data))
             (widths (cl-loop for column below column-count
                              collect (cl-loop for row in all-rows
                                              maximize (cl-loop for cell in row
                                                               for index from 0
                                                               when (= index column)
                                                               maximize (cl-loop for line in cell
                                                                                maximize (string-width line))))))
             (vertical (if pimacs-markdown-use-unicode-tables "│" "|"))
             (horizontal (if pimacs-markdown-use-unicode-tables ?─ ?-))
             (intersection (if pimacs-markdown-use-unicode-tables "┼" "+"))
             (left (if pimacs-markdown-use-unicode-tables "├" "+"))
             (right (if pimacs-markdown-use-unicode-tables "┤" "+"))
             output)
        (cl-labels
            ((border ()
               (pimacs--markdown-propertize-face
                (concat left
                        (mapconcat (lambda (width) (make-string (+ width 2) horizontal))
                                   widths intersection)
                        right)
                'pimacs-markdown-table-border-face))
             (render-row (row headerp)
               (let ((height (apply #'max (mapcar #'length row))))
                 (cl-loop for line below height
                          collect
                          (let (chunks)
                            (dotimes (column column-count)
                              (let* ((cell (nth column row))
                                     (text (or (nth line cell) ""))
                                     (padded (pimacs--markdown-table-pad
                                              text (nth column widths)
                                              (nth column alignments))))
                                (when headerp
                                  (setq padded (pimacs--markdown-table-header-face padded)))
                                (push (pimacs--markdown-propertize-face
                                       vertical 'pimacs-markdown-table-border-face)
                                      chunks)
                                (push " " chunks)
                                (push padded chunks)
                                (push " " chunks)))
                            (push (pimacs--markdown-propertize-face
                                   vertical 'pimacs-markdown-table-border-face)
                                  chunks)
                            (apply #'concat (nreverse chunks)))))))
          (setq output (append (render-row header-data t) (list (border))))
          (dolist (row row-data)
            (setq output (append output (render-row row nil))))
          (concat (mapconcat #'identity output "\n")
                  (if (string-suffix-p "\n" (pimacs--markdown-node-text node)) "\n" "")))))))

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

(defun pimacs--render-markdown-experimental (_context text streaming)
  (list (list :append
              (if streaming text (pimacs--markdown-render-source text)))))

(provide 'pimacs-markdown)

;;; pimacs-markdown.el ends here
