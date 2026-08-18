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
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Markdown is parsed by tree-sitter after streaming has completed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'treesit)
(require 'warnings)
(require 'widget)
(require 'wid-edit)
(require 'pimacs-core)
(require 'pimacs-markdown-table)


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

(defconst pimacs--markdown-reference-definition-query
  (treesit-query-compile
   'markdown '((link_reference_definition) @definition)))

(defconst pimacs--markdown-block-continuation-query
  (treesit-query-compile
   'markdown '((block_continuation) @continuation)))

(defconst pimacs--markdown-inline-special-query
  (treesit-query-compile
   'markdown-inline
   '((emphasis) @special
     (strong_emphasis) @special
     (strikethrough) @special
     (code_span) @special
     (inline_link) @special
     (image) @special
     (full_reference_link) @special
     (shortcut_link) @special
     (collapsed_reference_link) @special
     (uri_autolink) @special
     (email_autolink) @special
     (latex_block) @special
     (backslash_escape) @special
     (hard_line_break) @special
     (html_tag) @special)))

(defun pimacs--markdown-reference-definitions (root)
  (let (definitions)
    (dolist (node (treesit-query-capture
                   root pimacs--markdown-reference-definition-query
                   nil nil t))
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
                definitions))))
    (nreverse definitions)))

(cl-defstruct pimacs--markdown-inline-parser-state
  pool
  depth)

(cl-defstruct pimacs--markdown-render-context
  reference-definitions
  list-depth
  list-index
  inline-parser-state
  fontify-code)

(defun pimacs--markdown-render-context-for-list-item (context list-index)
  (let ((context (copy-pimacs--markdown-render-context context)))
    (setf (pimacs--markdown-render-context-list-depth context)
          (1+ (pimacs--markdown-render-context-list-depth context)))
    (setf (pimacs--markdown-render-context-list-index context) list-index)
    context))

(defvar pimacs--markdown-treesit-warning-shown nil)

(defun pimacs--warn-missing-markdown-treesit ()
  (unless pimacs--markdown-treesit-warning-shown
    (setq pimacs--markdown-treesit-warning-shown t)
    (display-warning
     '(pimacs treesit)
     "Tree-sitter Markdown rendering is unavailable; falling back to plain text. Run M-x pimacs-doctor to install the required grammars."
     :warning)))

(defun pimacs--markdown-available-p ()
  (and (treesit-available-p)
       (treesit-language-available-p 'markdown)
       (treesit-language-available-p 'markdown-inline)))

(defun pimacs--markdown-create-parser (grammar)
  (when (treesit-language-available-p grammar)
    (treesit-parser-create grammar)))

(defun pimacs--markdown-with-parser (text grammar function)
  (let ((buffer (generate-new-buffer " *pimacs-markdown*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert text)
          (funcall function
                   (treesit-parser-root-node
                    (pimacs--markdown-create-parser grammar))))
      (kill-buffer buffer))))

(defun pimacs--markdown-with-inline-parser (text function state)
  (let* ((depth (pimacs--markdown-inline-parser-state-depth state))
         (pool (pimacs--markdown-inline-parser-state-pool state))
         (entry (nth depth pool)))
    (unless entry
      (let ((buffer (generate-new-buffer " *pimacs-markdown-inline*"))
            parser)
        (unwind-protect
            (with-current-buffer buffer
              (setq parser (pimacs--markdown-create-parser 'markdown-inline)))
          (unless parser
            (kill-buffer buffer)))
        (setq entry (cons buffer parser))
        (setf (pimacs--markdown-inline-parser-state-pool state)
              (if (= depth (length pool))
                  (append pool (list entry))
                (setf (nth depth pool) entry)))))
    (setf (pimacs--markdown-inline-parser-state-depth state) (1+ depth))
    (unwind-protect
        (with-current-buffer (car entry)
          (erase-buffer)
          (insert text)
          (funcall function (treesit-parser-root-node (cdr entry))))
      (setf (pimacs--markdown-inline-parser-state-depth state) depth))))

(defun pimacs--markdown-delete-inline-parser-pool (state)
  (dolist (entry (pimacs--markdown-inline-parser-state-pool state))
    (treesit-parser-delete (cdr entry))
    (kill-buffer (car entry))))

(defun pimacs--markdown-parse-source (text renderer)
  (pimacs--markdown-with-parser
   text 'markdown
   (lambda (root)
     (let* ((state (make-pimacs--markdown-inline-parser-state :depth 0))
            (context
             (make-pimacs--markdown-render-context
              :reference-definitions
              (pimacs--markdown-reference-definitions root)
              :list-depth 0
              :list-index nil
              :inline-parser-state state
              :fontify-code t)))
       (unwind-protect
           (funcall renderer root context)
         (pimacs--markdown-delete-inline-parser-pool state))))))

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

(defconst pimacs--markdown-incremental-debug-buffer-name
  "*pimacs-markdown-incremental-debug*")

(defconst pimacs--markdown-list-bullets
  '("▪" "▫" "◇" "•" "○"))

(defcustom pimacs-markdown-leading-newline-block-types
  '("pipe_table"
    "fenced_code_block"
    "indented_code_block"
    "block_quote"
    "list"
    "thematic_break"
    "html_block")
  "List of Markdown block node types.
Render these on a fresh line when the renderer starts mid-line."
  :type '(repeat string)
  :group 'pimacs)

(cl-defstruct pimacs--markdown-render-checkpoint
  marker
  output-offset
  type)

(cl-defstruct pimacs--markdown-render-session
  buffer
  parser
  checkpoints
  changed-ranges
  reference-definitions
  rendered-length
  update-number
  debug-output
  leading-newline-eligible
  leading-newline-rendered)

(defcustom pimacs-markdown-incremental-render-debug nil
  "Whether to capture incremental Markdown rendering diagnostics.

When non-nil, diagnostics are appended to the temporary buffer
`*pimacs-markdown-incremental-debug*'."
  :type 'boolean
  :group 'pimacs)

(defvar-local pimacs--markdown-render-session nil)

(defun pimacs--markdown-debug-checkpoints (session)
  (when pimacs-markdown-incremental-render-debug
    (mapcar
     (lambda (checkpoint)
       (list :source-position
             (marker-position (pimacs--markdown-render-checkpoint-marker checkpoint))
             :output-offset
             (pimacs--markdown-render-checkpoint-output-offset checkpoint)
             :type (pimacs--markdown-render-checkpoint-type checkpoint)))
     (pimacs--markdown-render-session-checkpoints session))))

(defun pimacs--markdown-debug-log (session &rest details)
  (when pimacs-markdown-incremental-render-debug
    (with-current-buffer
        (get-buffer-create pimacs--markdown-incremental-debug-buffer-name)
      (goto-char (point-max))
      (insert (format "Incremental Markdown update %d\n"
                      (pimacs--markdown-render-session-update-number session)))
      (while details
        (insert (format "  %-22s %S\n"
                        (substring (symbol-name (car details)) 1)
                        (cadr details)))
        (setq details (cddr details)))
      (insert "\n"))))

(defun pimacs--markdown-parser-notifier (ranges parser)
  (let ((buffer (treesit-parser-buffer parser)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when pimacs--markdown-render-session
          (setf (pimacs--markdown-render-session-changed-ranges
                 pimacs--markdown-render-session)
                ranges))))))

(defun pimacs--markdown-clear-checkpoints (checkpoints)
  (dolist (checkpoint checkpoints)
    (set-marker (pimacs--markdown-render-checkpoint-marker checkpoint) nil)))

(defun pimacs--markdown-cleanup-session (session)
  (when pimacs-markdown-incremental-render-debug
    (pimacs--markdown-debug-log
     session :event :destroy
     :checkpoints (pimacs--markdown-debug-checkpoints session)))
  (pimacs--markdown-clear-checkpoints
   (pimacs--markdown-render-session-checkpoints session))
  (setf (pimacs--markdown-render-session-checkpoints session) nil
        (pimacs--markdown-render-session-changed-ranges session) nil
        (pimacs--markdown-render-session-reference-definitions session) nil
        (pimacs--markdown-render-session-rendered-length session) 0
        (pimacs--markdown-render-session-update-number session) 0
        (pimacs--markdown-render-session-debug-output session) nil
        (pimacs--markdown-render-session-leading-newline-eligible session) nil
        (pimacs--markdown-render-session-leading-newline-rendered session) nil)
  (when-let ((parser (pimacs--markdown-render-session-parser session)))
    (ignore-errors
      (treesit-parser-remove-notifier parser #'pimacs--markdown-parser-notifier))
    (ignore-errors (treesit-parser-delete parser))
    (setf (pimacs--markdown-render-session-parser session) nil))
  (when-let ((buffer (pimacs--markdown-render-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq pimacs--markdown-render-session nil))
      (kill-buffer buffer))
    (setf (pimacs--markdown-render-session-buffer session) nil)))

(defun pimacs--markdown-initialize-render-session (session)
  (unless (pimacs--markdown-render-session-buffer session)
    (let ((buffer (generate-new-buffer " *pimacs-markdown-source*")))
      (setf (pimacs--markdown-render-session-buffer session) buffer)
      (condition-case error
          (with-current-buffer buffer
            (setq-local pimacs--markdown-render-session session)
            (let ((parser (pimacs--markdown-create-parser 'markdown)))
              (setf (pimacs--markdown-render-session-parser session) parser)
              (treesit-parser-add-notifier parser #'pimacs--markdown-parser-notifier)))
        (error
         (pimacs--markdown-cleanup-session session)
         (signal (car error) (cdr error))))))
  session)

(defun pimacs--markdown-coalesce-ranges (ranges)
  (let ((ranges (sort (cl-remove-if-not
                       (lambda (range)
                         (and (consp range) (integerp (car range))
                              (integerp (cdr range)) (<= (car range) (cdr range))))
                       (copy-sequence ranges))
                      (lambda (left right) (< (car left) (car right)))))
        result)
    (dolist (range ranges)
      (if (and result (<= (car range) (cdr (car result))))
          (setcdr (car result) (max (cdr (car result)) (cdr range)))
        (push (cons (car range) (cdr range)) result)))
    (nreverse result)))

(defun pimacs--markdown-safe-boundary (node document-start)
  (let (candidate)
    (while node
      (let ((type (treesit-node-type node))
            (parent (treesit-node-parent node)))
        (cond
         ((string= type "link_reference_definition")
          (setq candidate document-start node nil))
         ((member type '("pipe_table" "list" "block_quote" "fenced_code_block"))
          (setq candidate (treesit-node-start node) node nil))
         ((and (null candidate)
               (member type '("paragraph" "atx_heading" "section" "html_block"
                              "indented_code_block" "thematic_break")))
          (setq candidate (treesit-node-start node)))
         ((and (null candidate) parent
               (string= (treesit-node-type parent) "document"))
          (setq candidate (treesit-node-start node))))
        (setq node (and node (treesit-node-parent node)))))
    candidate))

(defun pimacs--markdown-range-boundary (range parser document-start)
  (let* ((start (max document-start (car range)))
         (end (max document-start (1- (cdr range))))
         (end (min (point-max) end))
         (start (min (point-max) start))
         (start-node (treesit-node-at start parser t))
         (end-node (treesit-node-at end parser t))
         (start-boundary (and start-node
                              (pimacs--markdown-safe-boundary start-node document-start)))
         (end-boundary (and end-node
                            (pimacs--markdown-safe-boundary end-node document-start))))
    (cond
     ((and start-boundary end-boundary) (min start-boundary end-boundary))
     (start-boundary start-boundary)
     (end-boundary end-boundary)
     (t document-start))))

(defun pimacs--markdown-checkpoint-before (session position)
  (let (result)
    (dolist (checkpoint (pimacs--markdown-render-session-checkpoints session))
      (let ((marker (pimacs--markdown-render-checkpoint-marker checkpoint)))
        (when (and (eq (marker-buffer marker)
                       (pimacs--markdown-render-session-buffer session))
                   (integerp (marker-position marker))
                   (<= (marker-position marker) position))
          (setq result checkpoint))))
    result))

(defun pimacs--markdown-checkpoint-markers-valid-p (session)
  (let ((length (pimacs--markdown-render-session-rendered-length session))
        (buffer (pimacs--markdown-render-session-buffer session))
        previous-position
        previous-offset)
    (cl-every (lambda (checkpoint)
                (let ((marker (pimacs--markdown-render-checkpoint-marker checkpoint))
                      (offset (pimacs--markdown-render-checkpoint-output-offset checkpoint)))
                  (and (eq (marker-buffer marker) buffer)
                       (integerp (marker-position marker))
                       (<= (point-min) (marker-position marker) (point-max))
                       (integerp offset)
                       (<= 0 offset length)
                       (or (null previous-position)
                           (<= previous-position (marker-position marker)))
                       (or (null previous-offset) (<= previous-offset offset))
                       (setq previous-position (marker-position marker)
                             previous-offset offset))))
              (pimacs--markdown-render-session-checkpoints session))))

(defun pimacs--markdown-checkpoint-valid-p (session root checkpoint)
  (let ((marker (pimacs--markdown-render-checkpoint-marker checkpoint))
        (offset (pimacs--markdown-render-checkpoint-output-offset checkpoint))
        (type (pimacs--markdown-render-checkpoint-type checkpoint)))
    (and (eq (marker-buffer marker) (pimacs--markdown-render-session-buffer session))
         (integerp (marker-position marker))
         (integerp offset)
         (<= 0 offset (pimacs--markdown-render-session-rendered-length session))
         (or (and (string= type "document")
                  (= (marker-position marker) (point-min)))
             (cl-find-if
              (lambda (node)
                (and (= (treesit-node-start node) (marker-position marker))
                     (string= (treesit-node-type node) type)))
              (pimacs--markdown-node-children root))
             (cl-loop for section in (pimacs--markdown-node-children root)
                      thereis
                      (and (string= (treesit-node-type section) "section")
                           (cl-find-if
                            (lambda (node)
                              (and (= (treesit-node-start node)
                                      (marker-position marker))
                                   (string= (treesit-node-type node) type)))
                            (pimacs--markdown-node-children section))))))))

(defun pimacs--markdown-make-render-checkpoint (node output-offset)
  (make-pimacs--markdown-render-checkpoint
   :marker (copy-marker (treesit-node-start node))
   :output-offset output-offset
   :type (treesit-node-type node)))

(defun pimacs--markdown-render-section-suffix (section start context output-offset)
  (let ((position (max start (treesit-node-start section)))
        (length 0)
        checkpoints
        chunks)
    (cl-labels ((append-text (text)
                  (push text chunks)
                  (cl-incf length (length text))))
      (dolist (child (pimacs--markdown-node-children section))
        (when (> (treesit-node-end child) start)
          (when (< (treesit-node-start child) start)
            (error "Markdown checkpoint is not at a section block boundary"))
          (append-text
           (buffer-substring-no-properties position (treesit-node-start child)))
          (unless (= (treesit-node-start child) (treesit-node-start section))
            (push (pimacs--markdown-make-render-checkpoint
                   child (+ output-offset length))
                  checkpoints))
          (append-text (pimacs--markdown-render-block-node child context))
          (setq position (treesit-node-end child))))
      (append-text
       (buffer-substring-no-properties position (treesit-node-end section)))
      (list (apply #'concat (nreverse chunks)) (nreverse checkpoints)))))

(defun pimacs--markdown-first-block-node (node)
  (if (member (treesit-node-type node) '("document" "section"))
      (cl-loop for child in (pimacs--markdown-node-children node)
               unless (string= (treesit-node-type child)
                               "link_reference_definition")
               return (pimacs--markdown-first-block-node child))
    (unless (string= (treesit-node-type node)
                     "link_reference_definition")
      node)))

(defun pimacs--markdown-leading-newline-needed-p (root eligible)
  (and eligible
       (when-let ((node (pimacs--markdown-first-block-node root)))
         (and (not (string-match-p
                    "\\n"
                    (buffer-substring-no-properties
                     (point-min) (treesit-node-start node))))
              (not (null (member (treesit-node-type node)
                                 pimacs-markdown-leading-newline-block-types)))))))

(defun pimacs--markdown-render-top-level (session root start output-offset &optional leading-newline-p)
  (let* ((inline-state (make-pimacs--markdown-inline-parser-state :depth 0))
         (context (make-pimacs--markdown-render-context
                   :reference-definitions
                   (pimacs--markdown-render-session-reference-definitions session)
                   :list-depth 0 :list-index nil
                   :inline-parser-state inline-state
                   :fontify-code nil))
         (position start)
         (length 0)
         checkpoints
         chunks)
    (cl-labels ((append-text (text)
                  (push text chunks)
                  (cl-incf length (length text)))
                (render-node (node)
                  (if (string= (treesit-node-type node) "section")
                      (pcase-let ((`(,rendered ,section-checkpoints)
                                   (pimacs--markdown-render-section-suffix
                                    node start context (+ output-offset length))))
                        (append-text rendered)
                        (dolist (checkpoint section-checkpoints)
                          (push checkpoint checkpoints)))
                    (append-text
                     (pimacs--markdown-render-block-node node context)))
                  (setq position (treesit-node-end node))))
      (unwind-protect
          (progn
            (when leading-newline-p
              (append-text "\n"))
            (dolist (node (pimacs--markdown-node-children root))
              (when (> (treesit-node-end node) start)
                (cond
                 ((>= (treesit-node-start node) start)
                  (append-text
                   (buffer-substring-no-properties position
                                                   (treesit-node-start node)))
                  (push (pimacs--markdown-make-render-checkpoint
                         node (+ output-offset length))
                        checkpoints)
                  (render-node node))
                 ((string= (treesit-node-type node) "section")
                  (render-node node))
                 (t
                  (error "Markdown checkpoint is not at a top-level block boundary")))))
            (append-text (buffer-substring-no-properties position (point-max)))
            (list (apply #'concat (nreverse chunks)) (nreverse checkpoints)))
        (pimacs--markdown-delete-inline-parser-pool inline-state)))))

(defun pimacs--markdown-replace-rendered-suffix (session root checkpoint)
  (let* ((start (marker-position
                 (pimacs--markdown-render-checkpoint-marker checkpoint)))
         (offset (pimacs--markdown-render-checkpoint-output-offset checkpoint))
         (old-length (pimacs--markdown-render-session-rendered-length session)))
    (unless (and start (<= 0 offset old-length))
      (error "Invalid Markdown render checkpoint"))
    (pcase-let ((`(,rendered ,checkpoints)
                 (pimacs--markdown-render-top-level session root start offset)))
      (let ((before (cl-remove-if
                     (lambda (item)
                       (>= (marker-position
                            (pimacs--markdown-render-checkpoint-marker item))
                           start))
                     (pimacs--markdown-render-session-checkpoints session))))
        (pimacs--markdown-clear-checkpoints
         (cl-set-difference (pimacs--markdown-render-session-checkpoints session)
                            before))
        (setf (pimacs--markdown-render-session-checkpoints session)
              (append before checkpoints)
              (pimacs--markdown-render-session-rendered-length session)
              (+ offset (length rendered)))
        (list (- old-length offset) rendered)))))

(defun pimacs--markdown-render-entire-session (session root)
  (let* ((old-length (pimacs--markdown-render-session-rendered-length session))
         (document-start (point-min))
         (leading-newline-p
          (pimacs--markdown-leading-newline-needed-p
           root
           (pimacs--markdown-render-session-leading-newline-eligible session)))
         (document-checkpoint
          (make-pimacs--markdown-render-checkpoint
           :marker (copy-marker document-start) :output-offset 0 :type "document")))
    (pcase-let ((`(,rendered ,checkpoints)
                 (pimacs--markdown-render-top-level
                  session root document-start 0 leading-newline-p)))
      (pimacs--markdown-clear-checkpoints
       (pimacs--markdown-render-session-checkpoints session))
      (setf (pimacs--markdown-render-session-checkpoints session)
            (cons document-checkpoint checkpoints)
            (pimacs--markdown-render-session-rendered-length session)
            (length rendered)
            (pimacs--markdown-render-session-leading-newline-rendered session)
            leading-newline-p)
      (list old-length rendered))))

(defun pimacs--markdown-operations (delete-length rendered)
  (unless (and (zerop delete-length) (string-empty-p rendered))
    (list (list :replace-suffix delete-length rendered))))

(defun pimacs--markdown-checkpoint-debug-details (checkpoint)
  (and checkpoint
       (list :source-position
             (marker-position
              (pimacs--markdown-render-checkpoint-marker checkpoint))
             :output-offset
             (pimacs--markdown-render-checkpoint-output-offset checkpoint)
             :type (pimacs--markdown-render-checkpoint-type checkpoint))))

(defun pimacs--markdown-incremental-render-plan (session root raw-ranges references-changed edit-position leading-newline-changed)
  (let* ((ranges (pimacs--markdown-coalesce-ranges raw-ranges))
         (boundary-positions
          (mapcar (lambda (range)
                    (pimacs--markdown-range-boundary range (pimacs--markdown-render-session-parser session)
                                                     (point-min)))
                  ranges))
         (restart (if references-changed
                      (point-min)
                    (if boundary-positions
                        (apply #'min boundary-positions)
                      edit-position)))
         (checkpoint (pimacs--markdown-checkpoint-before session restart))
         checkpoint-valid
         (fallback-reason
          (cond
           (leading-newline-changed :leading-newline-changed)
           (references-changed :reference-definitions-changed)
           ((null checkpoint) :no-checkpoint)
           ((= restart (point-min)) :document-start)
           ((not (pimacs--markdown-checkpoint-markers-valid-p session))
            :invalid-checkpoint-set)
           ((not (setq checkpoint-valid
                       (and checkpoint
                            (not (null
                                  (pimacs--markdown-checkpoint-valid-p
                                   session root checkpoint))))))
            :invalid-checkpoint)
           (t nil))))
    (list :ranges ranges
          :boundaries (cl-mapcar #'cons ranges boundary-positions)
          :restart restart
          :checkpoint checkpoint
          :checkpoint-valid checkpoint-valid
          :checkpoint-details
          (pimacs--markdown-checkpoint-debug-details checkpoint)
          :leading-newline-changed leading-newline-changed
          :fallback-reason fallback-reason
          :checkpoints-before (pimacs--markdown-debug-checkpoints session))))

(defun pimacs--markdown-update-debug-output (session replacement)
  (let* ((unoptimized-delete-length (nth 0 replacement))
         (rendered (nth 1 replacement))
         (unoptimized-append-length (length rendered))
         (previous-output (pimacs--markdown-render-session-debug-output session))
         (output-valid-p (and (stringp previous-output)
                              (<= unoptimized-delete-length
                                  (length previous-output))))
         (old-suffix (cond
                      (output-valid-p
                       (substring previous-output
                                  (- (length previous-output)
                                     unoptimized-delete-length)))
                      ((zerop unoptimized-delete-length) "")
                      (t nil)))
         (common-prefix-length
          (when old-suffix
            (with-temp-buffer
              (insert old-suffix)
              (pimacs--buffer-string-common-prefix-length
               (current-buffer) (point-min) (point-max) rendered))))
         (prefix (if output-valid-p
                     (substring previous-output 0
                                (- (length previous-output)
                                   unoptimized-delete-length))
                   ""))
         (delete-length (and common-prefix-length
                             (- unoptimized-delete-length common-prefix-length)))
         (append-length (and common-prefix-length
                             (- unoptimized-append-length common-prefix-length)))
         (deleted-text (if common-prefix-length
                           (substring-no-properties
                            (substring old-suffix common-prefix-length))
                         "<unavailable>"))
         (append-text (if common-prefix-length
                          (substring-no-properties
                           (substring rendered common-prefix-length))
                        "<unavailable>")))
    (setf (pimacs--markdown-render-session-debug-output session)
          (concat prefix rendered))
    (list :unoptimized-delete-length unoptimized-delete-length
          :unoptimized-append-length unoptimized-append-length
          :common-prefix-length (or common-prefix-length "<unavailable>")
          :delete-length (or delete-length "<unavailable>")
          :deleted-text deleted-text
          :append-length (or append-length "<unavailable>")
          :append-text append-text)))

(defun pimacs--markdown-log-stream-update (session text edit-position raw-ranges plan replacement)
  (when pimacs-markdown-incremental-render-debug
    (let* ((checkpoint (plist-get plan :checkpoint))
           (fallback-reason (plist-get plan :fallback-reason))
           (debug-output (pimacs--markdown-update-debug-output session replacement)))
      (apply #'pimacs--markdown-debug-log
             session
             (append
              (list :event :stream
                    :source-length (point-max)
                    :delta-length (length text)
                    :delta-text (substring-no-properties text)
                    :edit-position edit-position
                    :changed-ranges raw-ranges
                    :coalesced-ranges (plist-get plan :ranges)
                    :boundaries (plist-get plan :boundaries)
                    :restart-position (plist-get plan :restart)
                    :checkpoint (plist-get plan :checkpoint-details)
                    :checkpoint-valid (plist-get plan :checkpoint-valid)
                    :fallback-reason fallback-reason
                    :overwritten-level
                    (if fallback-reason
                        :document
                      (and checkpoint
                           (pimacs--markdown-render-checkpoint-type checkpoint))))
              debug-output
              (list :rendered-length
                    (pimacs--markdown-render-session-rendered-length session)
                    :checkpoints-before (plist-get plan :checkpoints-before)
                    :checkpoints-after (pimacs--markdown-debug-checkpoints session)))))))

(defun pimacs--markdown-render-streaming (session text)
  (let* ((session (pimacs--markdown-initialize-render-session session))
         (buffer (pimacs--markdown-render-session-buffer session))
         (parser (pimacs--markdown-render-session-parser session)))
    (condition-case error
        (with-current-buffer buffer
          (unless (and (buffer-live-p buffer) parser)
            (error "Markdown render session is no longer usable"))
          (when pimacs-markdown-incremental-render-debug
            (cl-incf (pimacs--markdown-render-session-update-number session)))
          (setf (pimacs--markdown-render-session-changed-ranges session) nil)
          (goto-char (point-max))
          (let ((edit-position (point)))
            (insert text)
            (let* ((root (treesit-parser-root-node parser))
                   (raw-ranges
                    (pimacs--markdown-render-session-changed-ranges session))
                   (definitions (pimacs--markdown-reference-definitions root))
                   (references-changed
                    (not (equal definitions
                                (pimacs--markdown-render-session-reference-definitions
                                 session))))
                   (leading-newline-needed
                    (pimacs--markdown-leading-newline-needed-p
                     root
                     (pimacs--markdown-render-session-leading-newline-eligible session)))
                   (leading-newline-changed
                    (not (eq leading-newline-needed
                             (pimacs--markdown-render-session-leading-newline-rendered
                              session))))
                   (plan (pimacs--markdown-incremental-render-plan
                          session root raw-ranges references-changed edit-position
                          leading-newline-changed)))
              (setf (pimacs--markdown-render-session-changed-ranges session) nil
                    (pimacs--markdown-render-session-reference-definitions session)
                    definitions)
              (let* ((fallback-reason (plist-get plan :fallback-reason))
                     (checkpoint (plist-get plan :checkpoint))
                     (replacement
                      (if fallback-reason
                          (pimacs--markdown-render-entire-session session root)
                        (pimacs--markdown-replace-rendered-suffix
                         session root checkpoint))))
                (pimacs--markdown-log-stream-update
                 session text edit-position raw-ranges plan replacement)
                (pimacs--markdown-operations
                 (nth 0 replacement) (nth 1 replacement))))))
      (error
       (pimacs--markdown-cleanup-session session)
       (signal (car error) (cdr error))))))

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
        (continuations
         (treesit-query-capture
          node pimacs--markdown-block-continuation-query
          nil nil t))
        chunks)
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
  (let* ((candidates
          (sort (treesit-query-capture
                 root pimacs--markdown-inline-special-query
                 begin end t)
                (lambda (left right)
                  (let ((left-start (treesit-node-start left))
                        (right-start (treesit-node-start right)))
                    (or (< left-start right-start)
                        (and (= left-start right-start)
                             (> (treesit-node-end left)
                                (treesit-node-end right))))))))
         nodes
         stack)
    (dolist (node candidates)
      (while (and stack
                  (<= (treesit-node-end (car stack))
                      (treesit-node-start node)))
        (pop stack))
      (unless stack
        (push node nodes)
        (push node stack)))
    (nreverse nodes)))

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
    ("cpp" . c++-mode)
    ("screen" . shell-script-mode)
    ("shell" . sh-mode)
    ("bash" . sh-mode))
  "Alist mapping Markdown fence language names to major modes.")

(defun pimacs--markdown-language-mode-p (mode)
  (and mode
       (fboundp mode)
       (or
        (not (string-match-p "ts-mode\\'" (symbol-name mode)))
        ;; Only use Tree-sitter modes when they are configured as modes.
        (cl-loop for pair in (bound-and-true-p major-mode-remap-alist)
                 for function = (cdr pair)
                 thereis (and (atom function) (eq mode function)))
        (cl-loop for pair in auto-mode-alist
                 for function = (cdr pair)
                 thereis (and (atom function) (eq mode function))))))

(defun pimacs--markdown-resolve-language-mode (language)
  (let* ((language (or language ""))
         (downcased (downcase language))
         (aliases (list (cdr (assoc language pimacs-markdown-language-aliases))
                        (cdr (assoc downcased pimacs-markdown-language-aliases))))
         (tree-sitter-modes
          (when (and (fboundp 'treesit-language-available-p)
                     (not (string-empty-p downcased)))
            (delq nil
                  (list
                   (and (treesit-language-available-p (intern language))
                        (intern (concat language "-ts-mode")))
                   (and (treesit-language-available-p (intern downcased))
                        (intern (concat downcased "-ts-mode")))))))
         (regular-modes (list (intern (concat language "-mode"))
                              (intern (concat downcased "-mode")))))
    (cl-find-if #'pimacs--markdown-language-mode-p
                (append tree-sitter-modes aliases regular-modes))))

(defun pimacs--markdown-fontify-code (code language)
  (if-let ((mode (pimacs--markdown-resolve-language-mode language)))
      (pimacs--render-content nil code mode)
    (pimacs--markdown-propertize-face
     code 'pimacs-markdown-code-block-face)))

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

(defun pimacs--markdown-render-emphasis-node (node context)
  (let* ((type (treesit-node-type node))
         (start (treesit-node-start node))
         (end (treesit-node-end node))
         (width (let ((position start)
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

(defun pimacs--markdown-render-code-span-node (node)
  (let* ((source (pimacs--markdown-node-text node))
         (delimiter (pimacs--markdown-node-child node "code_span_delimiter"))
         (width (if delimiter (length (pimacs--markdown-node-text delimiter)) 0))
         (text (substring source width (- width))))
    (when (string-match-p "\\` .* \\'" text)
      (setq text (substring text 1 -1)))
    (pimacs--markdown-propertize-face text 'pimacs-markdown-inline-code-face)))

(defun pimacs--markdown-render-inline-link-node (node context)
  (let ((label (pimacs--markdown-node-child node "link_text"))
        (destination (pimacs--markdown-node-child node "link_destination"))
        (title (pimacs--markdown-node-child node "link_title")))
    (if (and label destination)
        (pimacs--markdown-link-label
         (pimacs--markdown-node-text label) nil
         (string-trim (pimacs--markdown-node-text destination) "<" ">")
         context
         (and title (string-trim (pimacs--markdown-node-text title) "\"'(" "\"')")))
      (pimacs--markdown-node-text node))))

(defun pimacs--markdown-render-reference-link-node (node context)
  (let* ((label (pimacs--markdown-node-child node "link_text"))
         (reference (if (string= (treesit-node-type node) "full_reference_link")
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
      (pimacs--markdown-node-text node))))

(defun pimacs--markdown-render-image-node (node context)
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
      (pimacs--markdown-node-text node))))

(defun pimacs--markdown-render-autolink-node (node)
  (pimacs--markdown-autolink-label
   (string-trim (pimacs--markdown-node-text node) "<" ">") nil))

(defun pimacs--markdown-render-escaped-inline-node (node)
  (string-remove-prefix "\\" (pimacs--markdown-node-text node)))

(defun pimacs--markdown-render-html-tag-node (node)
  (let ((source (pimacs--markdown-node-text node)))
    (if (member source '("<br>" "<br/>" "<br />")) "\n" source)))

(defun pimacs--markdown-render-latex-node (node)
  (pimacs--markdown-propertize-face
   (string-trim
    (string-trim (pimacs--markdown-node-text node) "\\$+" "\\$+"))
   'pimacs-markdown-equation-face))

(defun pimacs--markdown-render-inline-node (node context)
  (pcase (treesit-node-type node)
    ((or "emphasis" "strong_emphasis" "strikethrough")
     (pimacs--markdown-render-emphasis-node node context))
    ("code_span"
     (pimacs--markdown-render-code-span-node node))
    ("inline_link"
     (pimacs--markdown-render-inline-link-node node context))
    ((or "full_reference_link" "shortcut_link" "collapsed_reference_link")
     (pimacs--markdown-render-reference-link-node node context))
    ("image"
     (pimacs--markdown-render-image-node node context))
    ((or "uri_autolink" "email_autolink")
     (pimacs--markdown-render-autolink-node node))
    ((or "backslash_escape" "hard_line_break")
     (pimacs--markdown-render-escaped-inline-node node))
    ("html_tag"
     (pimacs--markdown-render-html-tag-node node))
    ("latex_block"
     (pimacs--markdown-render-latex-node node))
    (_
     (pimacs--markdown-node-text node))))

(defun pimacs--markdown-render-inline-html-node (node nodes context)
  (let ((face (pimacs--markdown-html-tag-face node)))
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
              (list
               (pimacs--markdown-propertize-face
                (pimacs--markdown-render-inline-range
                 (treesit-node-end node)
                 (treesit-node-start closing-node)
                 context)
                face)
               (treesit-node-end closing-node)
               remaining)
            (list (pimacs--markdown-render-inline-node node context)
                  (treesit-node-end node)
                  nodes)))
      (list (pimacs--markdown-render-inline-node node context)
            (treesit-node-end node)
            nodes))))

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
          (let ((rendered (if (string= (treesit-node-type node) "html_tag")
                              (pimacs--markdown-render-inline-html-node
                               node nodes context)
                            (list (pimacs--markdown-render-inline-node node context)
                                  finish
                                  nodes))))
            (push (nth 0 rendered) chunks)
            (setq position (nth 1 rendered))
            (setq nodes (nth 2 rendered))))))
    (push (buffer-substring-no-properties position end) chunks)
    (apply #'concat (nreverse chunks))))

(defun pimacs--markdown-render-inline-source (text context)
  (let ((renderer (lambda (root)
                    (pimacs--markdown-render-inline-tree-range
                     root 1 (point-max) context)))
        (state (pimacs--markdown-render-context-inline-parser-state context)))
    (if state
        (pimacs--markdown-with-inline-parser text renderer state)
      (pimacs--markdown-with-parser text 'markdown-inline renderer))))

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

(defun pimacs--markdown-render-fenced-code-block (node context)
  (let* ((source (pimacs--markdown-node-text node))
         (delimiter (pimacs--markdown-node-child node "fenced_code_block_delimiter"))
         (info-string (pimacs--markdown-node-child node "info_string"))
         (language-node (and info-string
                             (pimacs--markdown-node-child info-string "language")))
         (content (pimacs--markdown-node-child node "code_fence_content"))
         (language (and language-node
                        (pimacs--markdown-node-text language-node))))
    (if (and delimiter content)
        (let ((code (pimacs--markdown-node-text-without-block-continuations content)))
          (if (pimacs--markdown-render-context-fontify-code context)
              (pimacs--markdown-fontify-code code language)
            (pimacs--markdown-propertize-face
             code 'pimacs-markdown-code-block-face)))
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
     (pimacs--markdown-render-fenced-code-block node context))
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

(defun pimacs--markdown-normalize-source (text)
  (if (and (not (string-suffix-p "\n" text))
           (string-match-p "\\(?:\\`\\|\n\\)[ \\t]*```+[ \\t]*\\'" text))
      (concat text "\n")
    text))

(defun pimacs--markdown-render-source (text &optional leading-newline-eligible)
  (pimacs--markdown-parse-source
   (pimacs--markdown-normalize-source text)
   (lambda (root context)
     (concat
      (if (pimacs--markdown-leading-newline-needed-p
           root leading-newline-eligible)
          "\n"
        "")
      (pimacs--markdown-render-block-node root context)))))

(defun pimacs--markdown-relative-link-p (url)
  (and (not (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" url))
       (not (string-prefix-p "//" url))
       (not (string-prefix-p "#" url))))

(defun pimacs--markdown-apply-url-widgets (start end _data)
  (let ((position start))
    (while (< position end)
      (let ((next (next-single-property-change
                   position 'pimacs-markdown-link-url nil end)))
        (when-let ((url (get-text-property position 'pimacs-markdown-link-url)))
          (let ((relative (pimacs--markdown-relative-link-p url)))
            (widget-convert-button (if relative 'file-link 'url-link) position next
                                   :value (if relative
                                              (expand-file-name url (pimacs--project-root))
                                            url)
                                   :suppress-face t
                                   :help-echo url)))
        (setq position next)))))

(defun pimacs--render-thinking-markdown (operation &optional state text)
  (if (pimacs--markdown-available-p)
      (pimacs--render-markdown operation state text)
    (pimacs--warn-missing-markdown-treesit)
    (pimacs--render-thinking-default operation state text)))

(defun pimacs--render-markdown (operation &optional state text)
  (if (pimacs--markdown-available-p)
      (pcase operation
        (:create
         (make-pimacs--markdown-render-session
          :checkpoints nil :changed-ranges nil :reference-definitions nil
          :rendered-length 0 :update-number 0
          :leading-newline-eligible (not (bolp))
          :leading-newline-rendered nil))
        (:stream
         (pimacs--markdown-render-streaming state text))
        (:final
         (unwind-protect
             (list (list :append
                         (pimacs--markdown-render-source
                          text
                          (pimacs--markdown-render-session-leading-newline-eligible
                           state))
                         :after-insert #'pimacs--markdown-apply-url-widgets))
           (pimacs--markdown-cleanup-session state)))
        (:destroy
         (pimacs--markdown-cleanup-session state)))
    (pimacs--warn-missing-markdown-treesit)
    (pimacs--render-markdown-default operation state text)))

(provide 'pimacs-markdown)

;;; pimacs-markdown.el ends here
