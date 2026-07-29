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

;; The parser in this file deliberately owns no chat-buffer state.  It turns
;; each streamed delta into append/delete operations; pimacs.el applies them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'browse-url)

(defface pimacs-markdown-heading-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face used for Markdown headings."
  :group 'pimacs)

(defface pimacs-markdown-inline-code-face
  '((t :inherit (fixed-pitch font-lock-constant-face)))
  "Face used for inline code."
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

(defface pimacs-markdown-link-face
  '((t :inherit link))
  "Face used for provisional Markdown links."
  :group 'pimacs)

(defface pimacs-markdown-list-marker-face
  '((t :inherit shadow :slant normal :weight normal))
  "Face used for Markdown list markers."
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

(cl-defstruct pimacs-markdown-context
  parser
  content-begin
  content-end
  rendered-length)

(cl-defstruct pimacs-markdown-parser
  token
  tokens
  text
  pending
  spaces
  indent
  indent-length
  fence-start
  fence-end
  blockquote-index
  table-state
  provisional
  operations
  output-length
  line
  line-output-start
  line-kind
  prefix
  at-line-start
  fence)

(defun pimacs--markdown-parser-new ()
  (make-pimacs-markdown-parser
   :tokens nil :text "" :pending "" :spaces nil :indent 0 :indent-length 0
   :table-state nil :blockquote-index 0 :provisional nil :operations nil :output-length 0
   :line "" :line-output-start 0 :line-kind nil :prefix "" :at-line-start t))

(defun pimacs--markdown-link-keymap ()
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-2] #'browse-url-at-mouse)
    (define-key map (kbd "RET") #'browse-url-at-point)
    map))

(defvar pimacs--markdown-link-keymap (pimacs--markdown-link-keymap))

(defun pimacs--markdown-parser-emit (parser operation)
  (let ((operations (pimacs-markdown-parser-operations parser)))
    (if (and (eq (car operation) :append)
             operations
             (eq (caar (last operations)) :append))
        (setf (cadr (car (last operations)))
              (concat (cadr (car (last operations))) (cadr operation)))
      (setf (pimacs-markdown-parser-operations parser)
            (append operations (list operation)))))
  (pcase operation
    (`(:append ,text)
     (cl-incf (pimacs-markdown-parser-output-length parser) (length text)))
    (`(:delete ,count)
     (cl-decf (pimacs-markdown-parser-output-length parser) count))))

(defun pimacs--markdown-parser-faces (parser)
  (delq nil (mapcar (lambda (token) (plist-get token :face))
                    (reverse (pimacs-markdown-parser-tokens parser)))))

(defun pimacs--markdown-parser-append (parser text &optional properties)
  (when (not (string-empty-p text))
    (let ((faces (pimacs--markdown-parser-faces parser)))
      (when faces
        (setq text (propertize text 'face (if (= (length faces) 1)
                                              (car faces)
                                            faces))))
      (when properties
        (setq text (apply #'propertize text properties)))
      (pimacs--markdown-parser-emit parser (list :append text)))))

(defun pimacs--markdown-parser-delete (parser count)
  (when (> count 0)
    (pimacs--markdown-parser-emit parser (list :delete count))))

(defun pimacs--markdown-parser-add-token (parser kind &optional attributes)
  (let ((token (append (list :kind kind) attributes)))
    (push token (pimacs-markdown-parser-tokens parser))
    (setf (pimacs-markdown-parser-token parser) token)
    token))

(defun pimacs--markdown-parser-end-token (parser)
  (pop (pimacs-markdown-parser-tokens parser))
  (setf (pimacs-markdown-parser-token parser)
        (car (pimacs-markdown-parser-tokens parser))))

(defun pimacs--markdown-parser-set-attribute (_parser _key _value)
  ;; Attributes are applied by replacing a completed provisional link suffix.
  nil)

(defun pimacs--markdown-provisional-open (parser kind raw &optional attributes)
  (dolist (record (pimacs-markdown-parser-provisional parser))
    (setf (plist-get record :raw) (concat (plist-get record :raw) raw)))
  (let ((record (append (list :kind kind
                              :output-start (pimacs-markdown-parser-output-length parser)
                              :raw raw
                              :token-depth (length (pimacs-markdown-parser-tokens parser)))
                        attributes)))
    (push record (pimacs-markdown-parser-provisional parser))
    record))

(defun pimacs--markdown-provisional-current (parser)
  (car (pimacs-markdown-parser-provisional parser)))

(defun pimacs--markdown-provisional-put (parser key value)
  (setf (plist-get (car (pimacs-markdown-parser-provisional parser)) key) value))

(defun pimacs--markdown-provisional-add-raw (parser string)
  (dolist (record (pimacs-markdown-parser-provisional parser))
    (setf (plist-get record :raw) (concat (plist-get record :raw) string))))

(defun pimacs--markdown-provisional-close (parser)
  (pop (pimacs-markdown-parser-provisional parser)))

(defun pimacs--markdown-provisional-fail (parser)
  (let* ((record (pimacs--markdown-provisional-current parser))
         (start (plist-get record :output-start))
         (count (- (pimacs-markdown-parser-output-length parser) start)))
    (pimacs--markdown-parser-delete parser count)
    (while (> (length (pimacs-markdown-parser-tokens parser))
              (plist-get record :token-depth))
      (pimacs--markdown-parser-end-token parser))
    (pimacs--markdown-provisional-close parser)
    (pimacs--markdown-parser-append parser (plist-get record :raw))))

(defun pimacs--markdown-open-inline (parser kind raw face &optional attributes)
  (pimacs--markdown-provisional-open parser kind raw attributes)
  (pimacs--markdown-parser-add-token parser kind (list :face face)))

(defun pimacs--markdown-close-inline (parser)
  (pimacs--markdown-parser-end-token parser)
  (pimacs--markdown-provisional-close parser))

(defun pimacs--markdown-close-triple-emphasis (parser)
  (pimacs--markdown-provisional-add-raw parser "***")
  (pimacs--markdown-close-inline parser)
  (pimacs--markdown-close-inline parser))

(defun pimacs--markdown-eligible-bold-p (char)
  (and char (not (memq char '(?\s ?\t ?\n ?\r)))))

(defun pimacs--markdown-inline-char (parser char)
  (let ((candidate (pimacs--markdown-provisional-current parser)))
    (pcase (plist-get candidate :kind)
      ('code
       (cond
        ((eq char ?\n)
         (pimacs--markdown-provisional-fail parser)
         (pimacs--markdown-inline-char parser char))
        ((eq char ?`)
         (setf (pimacs-markdown-parser-pending parser)
               (concat (pimacs-markdown-parser-pending parser) (string char))))
        ((not (string-empty-p (pimacs-markdown-parser-pending parser)))
         (let ((pending (pimacs-markdown-parser-pending parser)))
           (setf (pimacs-markdown-parser-pending parser) "")
           (pimacs--markdown-provisional-add-raw parser pending)
           (if (= (length pending) (plist-get candidate :width))
               (pimacs--markdown-close-inline parser)
             (pimacs--markdown-provisional-fail parser))
           (pimacs--markdown-inline-char parser char)))
        (t
         (pimacs--markdown-provisional-add-raw parser (string char))
         (pimacs--markdown-parser-append parser (string char)))))
      ((or 'bold 'italic 'strike)
       (let ((delimiter (pcase (plist-get candidate :kind)
                          ('bold "**")
                          ('strike "~~")
                          (_ (plist-get candidate :delimiter)))))
         (cond
          ((eq char ?\n)
           (pimacs--markdown-provisional-fail parser)
           (pimacs--markdown-inline-char parser char))
          ((and (string-empty-p (pimacs-markdown-parser-pending parser))
                (memq char '(?` ?\[)))
           (if (eq char ?`)
               (pimacs--markdown-open-inline parser 'code "`"
                                             'pimacs-markdown-inline-code-face
                                             (list :width 1))
             (pimacs--markdown-open-inline parser 'link "["
                                           'pimacs-markdown-link-face
                                           (list :stage 'label :label "" :url ""))))
          ((eq char (aref delimiter 0))
           (setf (pimacs-markdown-parser-pending parser)
                 (concat (pimacs-markdown-parser-pending parser) (string char))))
          ((not (string-empty-p (pimacs-markdown-parser-pending parser)))
           (let ((pending (pimacs-markdown-parser-pending parser)))
             (setf (pimacs-markdown-parser-pending parser) "")
             (pimacs--markdown-provisional-add-raw parser pending)
             (if (string= pending delimiter)
                 (pimacs--markdown-close-inline parser)
               (pimacs--markdown-parser-append parser pending))
             (pimacs--markdown-inline-char parser char)))
          (t
           (pimacs--markdown-provisional-add-raw parser (string char))
           (pimacs--markdown-parser-append parser (string char))))))
      ('link
       (pcase (plist-get candidate :stage)
         ('label
          (cond
           ((eq char ?\])
            (pimacs--markdown-provisional-add-raw parser "]")
            (pimacs--markdown-provisional-put parser :stage 'after-label))
           ((eq char ?\n)
            (pimacs--markdown-provisional-fail parser)
            (pimacs--markdown-inline-char parser char))
           (t
            (pimacs--markdown-provisional-add-raw parser (string char))
            (pimacs--markdown-provisional-put
             parser :label (concat (plist-get candidate :label) (string char)))
            (pimacs--markdown-parser-append parser (string char)))))
         ('after-label
          (if (eq char ?\()
              (progn
                (pimacs--markdown-provisional-add-raw parser "(")
                (pimacs--markdown-provisional-put parser :stage 'url))
            (pimacs--markdown-provisional-fail parser)
            (pimacs--markdown-inline-char parser char)))
         ('url
          (cond
           ((eq char ?\))
            (let* ((start (plist-get candidate :output-start))
                   (count (- (pimacs-markdown-parser-output-length parser) start))
                   (label (plist-get candidate :label))
                   (url (plist-get candidate :url)))
              (pimacs--markdown-provisional-add-raw parser ")")
              (pimacs--markdown-parser-delete parser count)
              (pimacs--markdown-parser-end-token parser)
              (pimacs--markdown-provisional-close parser)
              (pimacs--markdown-parser-append
               parser label
               (list 'face (let ((faces (pimacs--markdown-parser-faces parser)))
                             (if faces
                                 (append faces '(pimacs-markdown-link-face))
                               'pimacs-markdown-link-face))
                     'keymap pimacs--markdown-link-keymap
                     'mouse-face 'highlight
                     'help-echo url
                     'follow-link t))))
           ((eq char ?\n)
            (pimacs--markdown-provisional-fail parser)
            (pimacs--markdown-inline-char parser char))
           (t
            (pimacs--markdown-provisional-add-raw parser (string char))
            (pimacs--markdown-provisional-put
             parser :url (concat (plist-get candidate :url) (string char))))))))
      (_
       (cond
        ((eq char ?\[)
         (pimacs--markdown-open-inline parser 'link "[" 'pimacs-markdown-link-face
                                       (list :stage 'label :label "" :url "")))
        ((memq char '(?` ?* ?_ ?~))
         (setf (pimacs-markdown-parser-pending parser)
               (concat (pimacs-markdown-parser-pending parser) (string char))))
        (t
         (pimacs--markdown-parser-append parser (string char))))))))

(defun pimacs--markdown-inline-flush-pending (parser &optional final)
  (let ((pending (pimacs-markdown-parser-pending parser))
        (candidate (pimacs--markdown-provisional-current parser)))
    (unless (string-empty-p pending)
      (setf (pimacs-markdown-parser-pending parser) "")
      (pcase (plist-get candidate :kind)
        ('code
         (pimacs--markdown-provisional-add-raw parser pending)
         (if (= (length pending) (plist-get candidate :width))
             (pimacs--markdown-close-inline parser)
           (pimacs--markdown-provisional-fail parser)))
        ((or 'bold 'italic 'strike)
         (let ((delimiter (pcase (plist-get candidate :kind)
                            ('bold "**")
                            ('strike "~~")
                            (_ (plist-get candidate :delimiter)))))
           (if (and (eq (plist-get candidate :kind) 'italic)
                    (string= pending "***")
                    (eq (plist-get (cadr (pimacs-markdown-parser-provisional parser))
                                   :kind)
                        'bold))
               (pimacs--markdown-close-triple-emphasis parser)
             (pimacs--markdown-provisional-add-raw parser pending)
             (if (string= pending delimiter)
                 (pimacs--markdown-close-inline parser)
               (pimacs--markdown-provisional-fail parser)))))
        (_
         (cond
          ((and (> (length pending) 0)
                (eq (aref pending 0) ?`))
           (pimacs--markdown-open-inline parser 'code pending
                                         'pimacs-markdown-inline-code-face
                                         (list :width (length pending))))
          ((member pending '("**" "*" "_" "~~"))
           (if final
               (pimacs--markdown-parser-append parser pending)
             (setf (pimacs-markdown-parser-pending parser) pending)))
          (t
           (pimacs--markdown-parser-append parser pending))))))))

(defun pimacs--markdown-inline-write (parser string)
  (dotimes (index (length string))
    (let* ((char (aref string index))
           (candidate (pimacs--markdown-provisional-current parser))
           (pending (pimacs-markdown-parser-pending parser)))
      (cond
       ((and candidate
             (not (string-empty-p pending))
             (eq char ?\n))
        (pimacs--markdown-inline-flush-pending parser)
        (pimacs--markdown-inline-char parser char))
       ((and (null candidate)
             (string= pending "**")
             (eq char ?*))
        (setf (pimacs-markdown-parser-pending parser) "")
        (pimacs--markdown-open-inline parser 'bold "**" 'pimacs-markdown-bold-face)
        (pimacs--markdown-open-inline parser 'italic "*" 'pimacs-markdown-italic-face
                                      (list :delimiter "*")))
       ((and (eq (plist-get candidate :kind) 'italic)
             (string= pending "**")
             (eq char ?*)
             (eq (plist-get (cadr (pimacs-markdown-parser-provisional parser)) :kind)
                 'bold))
        (setf (pimacs-markdown-parser-pending parser) "")
        (pimacs--markdown-close-triple-emphasis parser))
       ((and (eq (plist-get candidate :kind) 'italic)
             (string= pending "**")
             (not (eq char ?*))
             (pimacs--markdown-eligible-bold-p char))
        (setf (pimacs-markdown-parser-pending parser) "")
        (pimacs--markdown-open-inline parser 'bold "**" 'pimacs-markdown-bold-face)
        (pimacs--markdown-inline-char parser char))
       ((and (eq (plist-get candidate :kind) 'bold)
             (string= pending "*")
             (not (eq char ?*))
             (pimacs--markdown-eligible-bold-p char))
        (setf (pimacs-markdown-parser-pending parser) "")
        (pimacs--markdown-open-inline parser 'italic "*" 'pimacs-markdown-italic-face
                                      (list :delimiter "*"))
        (pimacs--markdown-inline-char parser char))
       (t
        (when (and (null candidate)
                   (not (string-empty-p pending))
                   (not (eq char (aref pending 0))))
          (pimacs--markdown-inline-flush-pending parser))
        (setq candidate (pimacs--markdown-provisional-current parser))
        (cond
         ((and (memq (plist-get candidate :kind) '(nil italic))
               (string= (pimacs-markdown-parser-pending parser) "**")
               (pimacs--markdown-eligible-bold-p char))
          (setf (pimacs-markdown-parser-pending parser) "")
          (pimacs--markdown-open-inline parser 'bold "**" 'pimacs-markdown-bold-face)
          (pimacs--markdown-inline-char parser char))
         ((and (memq (plist-get candidate :kind) '(nil bold))
               (member (pimacs-markdown-parser-pending parser) '("*" "_"))
               (not (eq char (aref (pimacs-markdown-parser-pending parser) 0)))
               (pimacs--markdown-eligible-bold-p char))
          (let ((delimiter (pimacs-markdown-parser-pending parser)))
            (setf (pimacs-markdown-parser-pending parser) "")
            (pimacs--markdown-open-inline
             parser 'italic delimiter 'pimacs-markdown-italic-face
             (list :delimiter delimiter))
            (pimacs--markdown-inline-char parser char)))
         ((and (null candidate)
               (string= (pimacs-markdown-parser-pending parser) "~~")
               (not (eq char ?~))
               (pimacs--markdown-eligible-bold-p char))
          (setf (pimacs-markdown-parser-pending parser) "")
          (pimacs--markdown-open-inline
           parser 'strike "~~" 'pimacs-markdown-strike-through-face)
          (pimacs--markdown-inline-char parser char))
         (t
          (pimacs--markdown-inline-char parser char))))))))

(defun pimacs--markdown-render-inline (text)
  (let ((parser (pimacs--markdown-parser-new)))
    (pimacs--markdown-inline-write parser text)
    (pimacs--markdown-inline-flush-pending parser t)
    (when (pimacs--markdown-provisional-current parser)
      (pimacs--markdown-close-inline parser))
    (pimacs--markdown-operations-string
     (pimacs-markdown-parser-operations parser))))

(defun pimacs--markdown-table-cell (cell width face)
  (let ((text (copy-sequence cell))
        (start 0)
        (end (length cell)))
    (when face
      (while (< start end)
        (let ((next (next-single-property-change start 'face text end)))
          (unless (get-text-property start 'face text)
            (put-text-property start next 'face face text))
          (setq start next))))
    (concat text
            (propertize (make-string (- width (string-width cell)) ? ) 'face face))))

(defun pimacs--markdown-table-cells (line)
  (let ((line (string-trim line)))
    (when (string-prefix-p "|" line)
      (setq line (substring line 1)))
    (when (string-suffix-p "|" line)
      (setq line (substring line 0 -1)))
    (mapcar #'string-trim (split-string line "|" nil))))

(defun pimacs--markdown-table-separator-p (cells count)
  (and (= (length cells) count)
       (cl-every (lambda (cell)
                   (string-match-p "\\`:?---+:?\\'" cell))
                 cells)))

(defun pimacs--markdown-table-render (state)
  (let* ((headers (plist-get state :headers))
         (rows (plist-get state :rows))
         (widths (mapcar (lambda (column)
                           (apply #'max 3 (mapcar #'string-width column)))
                         (apply #'cl-mapcar #'list headers rows)))
         (vertical (if pimacs-markdown-use-unicode-tables "│" "|"))
         (horizontal (if pimacs-markdown-use-unicode-tables ?─ ?-))
         (junction (if pimacs-markdown-use-unicode-tables "┼" "|"))
         (left (if pimacs-markdown-use-unicode-tables "├" "|"))
         (right (if pimacs-markdown-use-unicode-tables "┤" "|"))
         (border (concat left
                         (mapconcat (lambda (width) (make-string (+ width 2) horizontal))
                                    widths
                                    junction)
                         right)))
    (cl-labels ((row (cells face)
                  (concat
                   (propertize vertical 'face 'pimacs-markdown-table-border-face)
                   (mapconcat
                    #'identity
                    (cl-mapcar
                     (lambda (cell width)
                       (concat " " (pimacs--markdown-table-cell cell width face)
                               " "
                               (propertize vertical 'face 'pimacs-markdown-table-border-face)))
                     cells widths)
                    "")
                   "\n")))
      (concat (row headers 'pimacs-markdown-table-header-face)
              (propertize (concat border "\n") 'face 'pimacs-markdown-table-border-face)
              (mapconcat (lambda (cells) (row cells nil)) rows "")))))

(defun pimacs--markdown-resolve-language-mode (language)
  (or (cdr (assoc-string (downcase (or language "")) pimacs-markdown-language-aliases t))
      (let ((mode (intern-soft (concat (downcase (or language "")) "-mode"))))
        (and mode (fboundp mode) mode))
      #'fundamental-mode))

(defun pimacs--markdown-fontify-code (code language)
  (with-temp-buffer
    (insert code)
    (let ((inhibit-message t)
          (mode (pimacs--markdown-resolve-language-mode language)))
      (condition-case nil
          (progn
            (funcall mode)
            (font-lock-ensure))
        (error (fundamental-mode)))
      (let ((text (buffer-string)))
        (put-text-property 0 (length text) 'face 'pimacs-markdown-code-block-face text)
        text))))

(defun pimacs--markdown-reset-line (parser)
  (setf (pimacs-markdown-parser-line parser) ""
        (pimacs-markdown-parser-line-output-start parser)
        (pimacs-markdown-parser-output-length parser)
        (pimacs-markdown-parser-line-kind parser) nil
        (pimacs-markdown-parser-prefix parser) ""
        (pimacs-markdown-parser-at-line-start parser) t))

(defun pimacs--markdown-set-blockquote-depth (parser depth)
  (let ((current (pimacs-markdown-parser-blockquote-index parser)))
    (while (> current depth)
      (pimacs--markdown-parser-end-token parser)
      (setq current (1- current)))
    (while (< current depth)
      (pimacs--markdown-parser-add-token
       parser 'blockquote
       (when (zerop current)
         (list :face 'pimacs-markdown-blockquote-face)))
      (setq current (1+ current)))
    (setf (pimacs-markdown-parser-blockquote-index parser) depth)))

(defun pimacs--markdown-blockquote-prefix-p (prefix)
  (string-match-p "\\`[ \t]\\{0,3\\}\\(?:>[ \t]?\\)*\\'" prefix))

(defun pimacs--markdown-horizontal-rule-prefix-p (prefix)
  (when (string-match "\\`[ \t]*" prefix)
    (let ((start (match-end 0)))
      (and (<= start 3)
           (< start (length prefix))
           (let ((delimiter (aref prefix start)))
             (and (memq delimiter '(?* ?- ?_))
                  (cl-every (lambda (char)
                              (memq char (list delimiter ?\s ?\t)))
                            (substring prefix start))))))))

(defun pimacs--markdown-horizontal-rule-p (line)
  (and (pimacs--markdown-horizontal-rule-prefix-p line)
       (>= (cl-count (aref (string-trim-left line) 0) line) 3)))

(defun pimacs--markdown-render-horizontal-rule (parser terminated)
  (pimacs--markdown-parser-add-token
   parser 'horizontal-rule (list :face 'pimacs-markdown-horizontal-rule-face))
  (pimacs--markdown-parser-append
   parser
   (concat (make-string (min 80 (window-width)) ?─) (if terminated "\n" "")))
  (pimacs--markdown-parser-end-token parser))

(defun pimacs--markdown-activate-unordered-list-prefix (parser prefix)
  (when (string-match "\\`[ \t]*\\([-*]\\) " prefix)
    (let ((marker (match-string 1 prefix))
          (content (substring prefix (match-end 0))))
      (setf (pimacs-markdown-parser-prefix parser) ""
            (pimacs-markdown-parser-at-line-start parser) nil
            (pimacs-markdown-parser-line-kind parser) 'list)
      (pimacs--markdown-parser-add-token
       parser 'list (list :face 'pimacs-markdown-list-marker-face))
      (pimacs--markdown-parser-append parser marker)
      (pimacs--markdown-parser-append parser " ")
      (pimacs--markdown-parser-end-token parser)
      (pimacs--markdown-inline-write parser content)
      content)))

(defun pimacs--markdown-activate-blockquote-prefix (parser prefix)
  (when (string-match "\\`[ \t]\\{0,3\\}\\(\\(?:>[ \t]?\\)+\\)" prefix)
    (let* ((marker (match-string 1 prefix))
           (depth (cl-count ?> marker))
           (content (substring prefix (match-end 0)))
           (line (pimacs-markdown-parser-line parser))
           (line-end (- (length line) (if (string-suffix-p "\n" line) 1 0)))
           (line-start (- line-end (length prefix))))
      (setf (pimacs-markdown-parser-line parser)
            (concat (substring line 0 line-start) content (substring line line-end)))
      (pimacs--markdown-set-blockquote-depth parser depth)
      (setf (pimacs-markdown-parser-prefix parser) ""
            (pimacs-markdown-parser-at-line-start parser)
            (not (or (pimacs-markdown-parser-fence parser)
                     (pimacs-markdown-parser-table-state parser)
                     (eq (pimacs-markdown-parser-line-kind parser) 'table-candidate))))
      (dotimes (index (length content))
        (pimacs--markdown-root-char parser (aref content index) t))
      content)))

(defun pimacs--markdown-fence-closing-p (fence line)
  (let ((character (plist-get fence :character))
        (width (plist-get fence :width)))
    (string-match-p
     (format "\\`[ \t]\\{0,3\\}%c\\{%d,\\}[ \t]*\\'" character width)
     line)))

(defun pimacs--markdown-finish-table-line (parser line terminated)
  (let ((state (pimacs-markdown-parser-table-state parser)))
    (pcase (plist-get state :phase)
      ('separator
       (let ((headers (plist-get state :headers))
             (cells (pimacs--markdown-table-cells line)))
         (if (pimacs--markdown-table-separator-p cells (length headers))
             (let ((new-state (list :phase 'rows
                                    :headers (mapcar #'pimacs--markdown-render-inline headers)
                                    :rows nil
                                    :start (plist-get state :start))))
               (pimacs--markdown-parser-delete
                parser (- (pimacs-markdown-parser-output-length parser)
                          (plist-get state :start)))
               (setf (pimacs-markdown-parser-table-state parser) new-state)
               (pimacs--markdown-parser-append parser
                                               (pimacs--markdown-table-render new-state)))
           (setf (pimacs-markdown-parser-table-state parser) nil))))
      ('rows
       (let ((cells (pimacs--markdown-table-cells line)))
         (if (= (length cells) (length (plist-get state :headers)))
             (progn
               (setf (plist-get state :rows)
                     (append (plist-get state :rows)
                             (list (mapcar #'pimacs--markdown-render-inline cells))))
               (pimacs--markdown-parser-delete
                parser (- (pimacs-markdown-parser-output-length parser)
                          (plist-get state :start)))
               (pimacs--markdown-parser-append parser (pimacs--markdown-table-render state)))
           ;; The non-table line was appended literally.  Remove it and scan
           ;; it normally now that the preceding table has been closed.
           (let ((start (pimacs-markdown-parser-line-output-start parser))
                 (source (concat line (if terminated "\n" ""))))
             (pimacs--markdown-parser-delete
              parser (- (pimacs-markdown-parser-output-length parser) start))
             (setf (pimacs-markdown-parser-table-state parser) nil)
             (pimacs--markdown-reset-line parser)
             (pimacs--markdown-parser-write parser source))))))))

(defun pimacs--markdown-render-fence (parser)
  (let ((fence (pimacs-markdown-parser-fence parser)))
    (pimacs--markdown-parser-delete
     parser (- (pimacs-markdown-parser-output-length parser)
               (plist-get fence :start)))
    (pimacs--markdown-parser-append
     parser
     (pimacs--markdown-fontify-code (plist-get fence :body)
                                    (plist-get fence :language)))
    (setf (pimacs-markdown-parser-fence parser) nil)))

(defun pimacs--markdown-finish-fence-line (parser line)
  (let ((fence (pimacs-markdown-parser-fence parser)))
    (if (pimacs--markdown-fence-closing-p fence line)
        (pimacs--markdown-render-fence parser)
      (setf (plist-get fence :body)
            (concat (plist-get fence :body) line "\n")))))

(defun pimacs--markdown-root-char (parser char &optional reprocessing)
  (unless reprocessing
    (setf (pimacs-markdown-parser-line parser)
          (concat (pimacs-markdown-parser-line parser) (string char))))
  (let ((kind (pimacs-markdown-parser-line-kind parser))
        (state (pimacs-markdown-parser-table-state parser))
        (fence (pimacs-markdown-parser-fence parser)))
    (cond
     ((and (pimacs-markdown-parser-at-line-start parser)
           (> (pimacs-markdown-parser-blockquote-index parser) 0)
           (or fence state (eq kind 'table-candidate)))
      (pimacs--markdown-prefix-char parser char))
     (fence
      (pimacs--markdown-parser-append parser (string char))
      (when (eq char ?\n)
        (if (plist-get fence :opening)
            (progn
              (when (string-match "\\`[ \t]*[`~]+\\(?:[ \t]+\\([^ \t\n]+\\)\\)?"
                                  (pimacs-markdown-parser-line parser))
                (setf (plist-get fence :language) (match-string 1 (pimacs-markdown-parser-line parser))))
              (setf (plist-get fence :opening) nil)
              (pimacs--markdown-reset-line parser))
          (pimacs--markdown-finish-fence-line
           parser (string-remove-suffix "\n" (pimacs-markdown-parser-line parser)))
          (pimacs--markdown-reset-line parser))))
     ((and state (memq (plist-get state :phase) '(separator rows)))
      (pimacs--markdown-parser-append parser (string char))
      (when (eq char ?\n)
        (pimacs--markdown-finish-table-line
         parser (string-remove-suffix "\n" (pimacs-markdown-parser-line parser)) t)
        (when (pimacs-markdown-parser-at-line-start parser)
          (pimacs--markdown-reset-line parser))))
     ((eq kind 'table-candidate)
      (pimacs--markdown-parser-append parser (string char))
      (when (eq char ?\n)
        (setf (pimacs-markdown-parser-table-state parser)
              (list :phase 'separator
                    :headers (pimacs--markdown-table-cells
                              (string-remove-suffix "\n" (pimacs-markdown-parser-line parser)))
                    :start (pimacs-markdown-parser-line-output-start parser)))
        (pimacs--markdown-reset-line parser)))
     ((memq kind '(heading list))
      (pimacs--markdown-inline-write parser (string char))
      (when (eq char ?\n)
        (when (eq kind 'heading)
          (pimacs--markdown-parser-end-token parser))
        (pimacs--markdown-reset-line parser)))
     ((pimacs-markdown-parser-at-line-start parser)
      (pimacs--markdown-prefix-char parser char))
     (t
      (when (and (eq char ?|)
                 (null (pimacs--markdown-provisional-current parser)))
        (let ((start (pimacs-markdown-parser-line-output-start parser)))
          (pimacs--markdown-parser-delete
           parser (- (pimacs-markdown-parser-output-length parser) start))
          (pimacs--markdown-parser-append parser (pimacs-markdown-parser-line parser))
          (setf (pimacs-markdown-parser-line-kind parser) 'table-candidate)))
      (unless (eq (pimacs-markdown-parser-line-kind parser) 'table-candidate)
        (pimacs--markdown-inline-write parser (string char)))
      (when (eq char ?\n)
        (pimacs--markdown-reset-line parser))))))

(defun pimacs--markdown-prefix-flush (parser)
  (let ((prefix (pimacs-markdown-parser-prefix parser)))
    (setf (pimacs-markdown-parser-prefix parser) ""
          (pimacs-markdown-parser-at-line-start parser) nil)
    (if (or (pimacs-markdown-parser-fence parser)
            (pimacs-markdown-parser-table-state parser)
            (eq (pimacs-markdown-parser-line-kind parser) 'table-candidate))
        (dotimes (index (length prefix))
          (pimacs--markdown-root-char parser (aref prefix index) t))
      (pimacs--markdown-inline-write parser prefix))))

(defun pimacs--markdown-prefix-char (parser char)
  (let ((prefix (concat (pimacs-markdown-parser-prefix parser) (string char))))
    (setf (pimacs-markdown-parser-prefix parser) prefix)
    (cond
     ((eq char ?\n)
      (let ((line (string-remove-suffix "\n" prefix)))
        (cond
         ((pimacs--markdown-horizontal-rule-p line)
          (pimacs--markdown-render-horizontal-rule parser t)
          (pimacs--markdown-reset-line parser))
         ((let ((content (pimacs--markdown-activate-blockquote-prefix parser line)))
            (when content
              (if (string-empty-p content)
                  (progn
                    (pimacs--markdown-parser-append parser "\n")
                    (pimacs--markdown-reset-line parser))
                (pimacs--markdown-root-char parser char t))
              t)))
         ((let ((content (pimacs--markdown-activate-unordered-list-prefix parser line)))
            (when content
              (pimacs--markdown-root-char parser char t)
              t)))
         (t
          (when (string-match-p "\\`[ \t]*\\'" line)
            (pimacs--markdown-set-blockquote-depth parser 0))
          (pimacs--markdown-prefix-flush parser)
          (pimacs--markdown-reset-line parser)))))
     ((pimacs--markdown-horizontal-rule-prefix-p prefix))
     ((pimacs--markdown-blockquote-prefix-p prefix))
     ((pimacs--markdown-activate-blockquote-prefix parser prefix))
     ((pimacs--markdown-activate-unordered-list-prefix parser prefix))
     ((and (string-match-p "\\`[ \t]*\\'" prefix) (<= (length prefix) 3)))
     ((string-match "\\`[ \t]*\\(#+\\) " prefix)
      (let ((hashes (match-string 1 prefix)))
        (if (<= (length hashes) 6)
            (progn
              (setf (pimacs-markdown-parser-prefix parser) ""
                    (pimacs-markdown-parser-at-line-start parser) nil
                    (pimacs-markdown-parser-line-kind parser) 'heading)
              (pimacs--markdown-parser-add-token
               parser 'heading (list :face 'pimacs-markdown-heading-face)))
          (pimacs--markdown-prefix-flush parser))))
     ((string-match "\\`[ \t]*\\([-+*]\\) " prefix)
      (setf (pimacs-markdown-parser-prefix parser) ""
            (pimacs-markdown-parser-at-line-start parser) nil
            (pimacs-markdown-parser-line-kind parser) 'list)
      (pimacs--markdown-parser-add-token
       parser 'list (list :face 'pimacs-markdown-list-marker-face))
      (pimacs--markdown-parser-append parser (match-string 1 prefix))
      (pimacs--markdown-parser-append parser " ")
      (pimacs--markdown-parser-end-token parser))
     ((string-match "\\`[ \t]*\\([0-9]+\\)\\. " prefix)
      (setf (pimacs-markdown-parser-prefix parser) ""
            (pimacs-markdown-parser-at-line-start parser) nil
            (pimacs-markdown-parser-line-kind parser) 'list)
      (pimacs--markdown-parser-add-token
       parser 'list (list :face 'pimacs-markdown-list-marker-face))
      (pimacs--markdown-parser-append parser (concat (match-string 1 prefix) ". "))
      (pimacs--markdown-parser-end-token parser))
     ((string-match "\\`[ \t]*\\([`~]\\)\\1\\1" prefix)
      (let* ((run (match-string 0 prefix))
             (character (aref run (1- (length run))))
             (width (length (replace-regexp-in-string "\\`[ \t]*" "" run)))
             (start (pimacs-markdown-parser-line-output-start parser)))
        (setf (pimacs-markdown-parser-prefix parser) ""
              (pimacs-markdown-parser-at-line-start parser) nil
              (pimacs-markdown-parser-line-kind parser) 'fence-open
              (pimacs-markdown-parser-fence parser)
              (list :start start :character character :width width :language nil :body "" :opening t))
        (pimacs--markdown-parser-append parser prefix)))
     ((eq char ?\n)
      (pimacs--markdown-prefix-flush parser)
      (pimacs--markdown-reset-line parser))
     ((or (> (length prefix) 12)
          (and (> (length prefix) 3) (string-match-p "\\`[ \t]+" prefix))
          (and (string-match-p "\\`[ \t]*#+\\'" prefix) (> (length (string-trim prefix)) 6))
          (and (not (string-match-p "\\`[ \t]*[-+*0-9`~#]+\\'" prefix))
               (not (string-match-p "\\`[ \t]*\\'" prefix))))
      (pimacs--markdown-prefix-flush parser)))))

(defun pimacs--markdown-parser-write (parser delta)
  (dotimes (index (length delta))
    (pimacs--markdown-root-char parser (aref delta index))))

(defun pimacs--markdown-parser-finish (parser final-p)
  (when final-p
    (when-let ((fence (pimacs-markdown-parser-fence parser)))
      (when (not (string-empty-p (pimacs-markdown-parser-line parser)))
        (if (plist-get fence :opening)
            (progn
              (when (string-match "\\`[ \t]*[`~]+\\(?:[ \t]+\\([^ \t\n]+\\)\\)?"
                                  (pimacs-markdown-parser-line parser))
                (setf (plist-get fence :language)
                      (match-string 1 (pimacs-markdown-parser-line parser))))
              (setf (plist-get fence :opening) nil))
          (pimacs--markdown-finish-fence-line
           parser (pimacs-markdown-parser-line parser))))
      (when (pimacs-markdown-parser-fence parser)
        (pimacs--markdown-render-fence parser))
      (pimacs--markdown-reset-line parser))
    (when (and (pimacs-markdown-parser-table-state parser)
               (not (string-empty-p (pimacs-markdown-parser-line parser))))
      (pimacs--markdown-finish-table-line parser (pimacs-markdown-parser-line parser) nil)
      (pimacs--markdown-reset-line parser))
    (when (and (pimacs-markdown-parser-at-line-start parser)
               (not (string-empty-p (pimacs-markdown-parser-prefix parser))))
      (let ((prefix (pimacs-markdown-parser-prefix parser)))
        (cond
         ((pimacs--markdown-horizontal-rule-p prefix)
          (pimacs--markdown-render-horizontal-rule parser nil)
          (pimacs--markdown-reset-line parser))
         ((pimacs--markdown-activate-unordered-list-prefix parser prefix))
         (t
          (pimacs--markdown-prefix-flush parser)))))
    (pimacs--markdown-inline-flush-pending parser t)
    (when (pimacs--markdown-provisional-current parser)
      (pimacs--markdown-close-inline parser))
    (when (eq (pimacs-markdown-parser-line-kind parser) 'heading)
      (pimacs--markdown-parser-end-token parser))))

(defun pimacs--markdown-operations-string (operations)
  (let ((output ""))
    (dolist (operation operations output)
      (pcase operation
        (`(:append ,text) (setq output (concat output text)))
        (`(:delete ,count) (setq output (substring output 0 (- (length output) count))))))))

(defun pimacs--render-markdown-experimental (context text streaming)
  (if streaming
      (let ((parser (or (pimacs-markdown-context-parser context)
                        (pimacs--markdown-parser-new))))
        (setf (pimacs-markdown-context-parser context) parser)
        (pimacs--markdown-parser-write parser text)
        (prog1 (pimacs-markdown-parser-operations parser)
          (setf (pimacs-markdown-parser-operations parser) nil)))
    (let ((parser (pimacs--markdown-parser-new)))
      (pimacs--markdown-parser-write parser text)
      (pimacs--markdown-parser-finish parser t)
      (list (list :delete (pimacs-markdown-context-rendered-length context))
            (list :append
                  (pimacs--markdown-operations-string
                   (pimacs-markdown-parser-operations parser)))))))

(provide 'pimacs-markdown)

;;; pimacs-markdown.el ends here
