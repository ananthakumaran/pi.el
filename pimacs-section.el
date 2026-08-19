;;; pimacs-section.el --- Section support -*- lexical-binding: t; -*-

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

;; A buffer in pimacs-mode is organized into hierarchical sections.
;; These sections are used for navigation and for hiding parts of the
;; buffer.

;;; Code:

(require 'cl-lib)
(require 'compat)
(require 'button)
(require 'pp)

(defcustom pimacs-section-autohide-count 2
  "Automatically hide older chat sections beyond this count.
This helps reduce clutter by collapsing earlier responses when the
conversation grows long.  When nil, auto hiding is disabled and no
sections are hidden automatically."
  :type '(choice (const :tag "Disable" nil)
                 integer)
  :group 'pimacs)

(defcustom pimacs-section-autohide-filter 'all
  "Filter controlling which sections are eligible for automatic hiding.

When set to `all', every top-level section is eligible.

A value of `(:include TYPE...)' makes only the listed section types eligible.
A value of `(:exclude TYPE...)' makes every section type except the listed
types eligible.  A function value is called with each top-level section and
should return non-nil when that section is eligible.  Non-eligible sections
do not count toward `pimacs-section-autohide-count'."
  :type '(choice
          (const :tag "All section types" all)
          (cons :tag "Only these section types"
                (const :include)
                (repeat symbol))
          (cons :tag "All except these section types"
                (const :exclude)
                (repeat symbol))
          (function :tag "Predicate function"))
  :group 'pimacs)

(defcustom pimacs-section-padding "\n\n"
  "String inserted between sections to control the visual gap.
Increase or decrease this value to adjust spacing between sections."
  :type 'string
  :group 'pimacs)

(defcustom pimacs-section-visibility-indicators
  '(pimacs-section-fringe-bitmap> . pimacs-section-fringe-bitmapv)
  "Fringe bitmaps used to indicate section visibility.

The car is used for hidden sections and the cdr for visible sections.
Set this to nil to disable fringe indicators."
  :type '(choice
          (const :tag "No indicators" nil)
          (cons :tag "Fringe indicators"
                (symbol :tag "Hidden section bitmap")
                (symbol :tag "Visible section bitmap")))
  :group 'pimacs)

(defvar pimacs-section--visibility-default :autoshow)
(defvar-local pimacs-section--root-section nil)
(defvar pimacs-section--insertion-parent nil)
(defvar pimacs-section--insertion-before nil)

(defmacro pimacs-section--with-insertion-before (parent boundary &rest body)
  (declare (indent 2)
           (debug (form form body)))
  `(let ((pimacs-section--insertion-parent ,parent)
         (pimacs-section--insertion-before ,boundary))
     ,@body))

(defface pimacs-section-root-face
  '((t))
  "Face applied to root sections."
  :group 'pimacs)

(defface pimacs-section-thinking-face
  '((t :inherit shadow))
  "Face applied to thinking sections."
  :group 'pimacs)

(defface pimacs-section-thinking-level-face
  '((t :inherit shadow))
  "Face applied to thinking-level sections."
  :group 'pimacs)

(defface pimacs-section-assistant-face
  '((t))
  "Face applied to assistant sections."
  :group 'pimacs)

(defface pimacs-section-user-face
  '((t :inherit highlight :extend t))
  "Face applied to user sections."
  :group 'pimacs)

(defface pimacs-section-tool-call-face
  '((t))
  "Face applied to tool call sections."
  :group 'pimacs)

(defface pimacs-section-tool-result-face
  '((t))
  "Face applied to tool result sections."
  :group 'pimacs)

(defface pimacs-section-error-face
  '((t :inherit pimacs-error-face))
  "Face applied to error sections."
  :group 'pimacs)

(defface pimacs-section-model-face
  '((t :inherit shadow))
  "Face applied to model sections."
  :group 'pimacs)

(defface pimacs-section-compact-face
  '((t :inherit shadow))
  "Face applied to compaction sections."
  :group 'pimacs)

(defface pimacs-section-info-face
  '((t :inherit shadow))
  "Face applied to information sections."
  :group 'pimacs)

(defface pimacs-section-custom-face
  '((t))
  "Face applied to custom sections."
  :group 'pimacs)

(defface pimacs-section-queue-face
  '((t :inherit shadow))
  "Face applied to queue sections."
  :group 'pimacs)

(defface pimacs-section-notify-face
  '((t))
  "Face applied to notification sections."
  :group 'pimacs)

(defface pimacs-section-select-face
  '((t :inherit shadow))
  "Face applied to selection sections."
  :group 'pimacs)

(defface pimacs-section-confirm-face
  '((t :inherit shadow))
  "Face applied to confirmation sections."
  :group 'pimacs)

(defface pimacs-section-input-face
  '((t :inherit shadow))
  "Face applied to input sections."
  :group 'pimacs)

(defface pimacs-section-session-face
  '((t :inherit shadow))
  "Face applied to session sections."
  :group 'pimacs)

(defcustom pimacs-section-type-faces
  '((root . pimacs-section-root-face)
    (thinking . pimacs-section-thinking-face)
    (thinking-level . pimacs-section-thinking-level-face)
    (assistant . pimacs-section-assistant-face)
    (user . pimacs-section-user-face)
    (tool-call . pimacs-section-tool-call-face)
    (tool-result . pimacs-section-tool-result-face)
    (error . pimacs-section-error-face)
    (model . pimacs-section-model-face)
    (compact . pimacs-section-compact-face)
    (info . pimacs-section-info-face)
    (custom . pimacs-section-custom-face)
    (queue . pimacs-section-queue-face)
    (notify . pimacs-section-notify-face)
    (select . pimacs-section-select-face)
    (confirm . pimacs-section-confirm-face)
    (input . pimacs-section-input-face)
    (session . pimacs-section-session-face))
  "Faces prepended to content in sections of each type."
  :type '(repeat (cons (symbol :tag "Section type")
                       (symbol :tag "Face")))
  :group 'pimacs)

(define-fringe-bitmap 'pimacs-section-fringe-bitmap>
  [#b01100000
   #b00110000
   #b00011000
   #b00001100
   #b00011000
   #b00110000
   #b01100000
   #b00000000])

(define-fringe-bitmap 'pimacs-section-fringe-bitmapv
  [#b00000000
   #b10000010
   #b11000110
   #b01101100
   #b00111000
   #b00010000
   #b00000000
   #b00000000])

(defun pimacs-section--visible-p (section)
  (memq (pimacs-section-visibility section) '(:autoshow :show)))

(defun pimacs-section--hidden-p (section)
  (memq (pimacs-section-visibility section) '(:autohide :hide)))

(defun pimacs-section--user-toggled-p (section)
  (not (null (memq (pimacs-section-visibility section) '(:show :hide)))))

(defun pimacs-section--prefix-p (prefix list)
  "Return non-nil if PREFIX is a prefix of LIST.
PREFIX and LIST should both be lists.

If the car of PREFIX is the symbol '*, then return non-nil if the cdr of PREFIX
is a sublist of LIST (as if '* matched zero or more arbitrary elements of LIST)"
  (or (null prefix)
      (if (eq (car prefix) '*)
          (or (pimacs-section--prefix-p (cdr prefix) list)
              (and list
                   (pimacs-section--prefix-p prefix (cdr list))))
        (and list
             (equal (car prefix) (car list))
             (pimacs-section--prefix-p (cdr prefix) (cdr list))))))

(cl-defstruct pimacs-section
  parent children beginning end type visibility info padding face)

(cl-defstruct pimacs-section-tool-call-info
  tool-name args header)

(cl-defstruct pimacs-section-tool-result-info
  tool-name details args)

(cl-defstruct pimacs-section-user-info
  header content)

(cl-defstruct pimacs-section-assistant-info
  header content type)

(defun pimacs-section--set-info (section info)
  (setf (pimacs-section-info section) info))

(defun pimacs-section--insert-chrome (text face)
  (insert (propertize text
                      'face face
                      'pimacs-section-face-order 'append)))

(defun pimacs-section--next-face-change (position end)
  (min (next-single-property-change
        position 'pimacs-section-face-order nil end)
       (next-single-property-change position 'pimacs-section nil end)))

(defun pimacs-section--apply-face (section beginning end)
  (when-let ((face (pimacs-section-face section)))
    (let ((position beginning))
      (while (< position end)
        (let* ((next (pimacs-section--next-face-change position end))
               (owner (get-text-property position 'pimacs-section))
               (appendp (eq (get-text-property
                             position 'pimacs-section-face-order)
                            'append)))
          (unless (and owner (not (eq owner section)))
            (add-face-text-property position next face appendp))
          (setq position next))))))

(defun pimacs-section--advance-pointer-maker (marker)
  (let ((m (copy-marker marker)))
    (set-marker-insertion-type m t)
    m))

(defun pimacs-section--add-child (parent child)
  (let ((children (pimacs-section-children parent)))
    (if (or (null pimacs-section--insertion-before)
            (not (eq parent pimacs-section--insertion-parent)))
        (setf (pimacs-section-children parent)
              (nconc children (list child)))
      (if (eq (car children) pimacs-section--insertion-before)
          (setf (pimacs-section-children parent) (cons child children))
        (let ((previous children))
          (while (and (cdr previous)
                      (not (eq (cadr previous)
                               pimacs-section--insertion-before)))
            (setq previous (cdr previous)))
          (if (cdr previous)
              (setcdr previous (cons child (cdr previous)))
            (setf (pimacs-section-children parent)
                  (nconc children (list child)))))))))

(defun pimacs-section--insertion-position (parent)
  (if (and (eq parent pimacs-section--insertion-parent)
           (memq pimacs-section--insertion-before
                 (pimacs-section-children parent)))
      (pimacs-section-beginning pimacs-section--insertion-before)
    (pimacs-section-end parent)))

(defun pimacs-section--new-section (type parent &rest args)
  (let* ((padding (or (plist-get args :padding) pimacs-section-padding))
         (face (or (plist-get args :face)
                   (alist-get type pimacs-section-type-faces)))
         (s (make-pimacs-section :parent parent
                                 :type type
                                 :face face
                                 :visibility pimacs-section--visibility-default
                                 :padding padding)))
    (when parent
      (pimacs-section--add-child parent s))
    s))

(defun pimacs-section--create-root-section ()
  (when pimacs-section--root-section
    (error "Root section already exists"))
  (let ((root (pimacs-section--new-section 'root nil)))
    (setf (pimacs-section-beginning root) (point-min))
    (setf (pimacs-section-end root) (point-min-marker))
    (setq pimacs-section--root-section root)
    root))

(defmacro pimacs-section--insert-section (section &rest body)
  (declare (indent 1)
           (debug (symbolp body)))
  (let ((s (make-symbol "*section*"))
        (body-beginning (make-symbol "*body-beginning*"))
        (padding-beginning (make-symbol "*padding-beginning*")))
    `(let* ((,s ,section))
       (goto-char (pimacs-section--insertion-position (pimacs-section-parent ,s)))
       (setf (pimacs-section-beginning ,s) (point-marker))
       (let ((,body-beginning (point)))
         ,@body
         (let ((,padding-beginning (point)))
           (insert (pimacs-section-padding ,s))
           (remove-text-properties ,padding-beginning (point)
                                   '(face nil pimacs-section-face-order nil)))
         (pimacs-section--apply-face ,s ,body-beginning (point)))
       (setf (pimacs-section-beginning ,s) (pimacs-section--advance-pointer-maker (pimacs-section-beginning ,s)))
       (pimacs-section--update-section-end ,s (point-marker))
       (pimacs-section--propertize-section ,s)
       (pimacs-section--update-visibility-indicator ,s)
       ,s)))

(defmacro pimacs-section--create-section (type parent &rest body)
  (declare (indent 2)
           (debug (form symbolp body)))
  (let ((s (make-symbol "*section*")))
    `(let* ((,s (pimacs-section--new-section ,type ,parent)))
       (pimacs-section--insert-section ,s
         ,@body)
       ,s)))

(defmacro pimacs-section--append-section (section &rest body)
  (declare (indent 1)
           (debug (symbolp body)))
  (let ((s (make-symbol "*section*"))
        (body-beginning (make-symbol "*body-beginning*"))
        (changed-beginning (make-symbol "*changed-beginning*"))
        (change-hook (make-symbol "*change-hook*")))
    `(let* ((,s ,section))
       (goto-char (pimacs-section-beginning ,s))
       (setf (pimacs-section-beginning ,s) (point-marker))
       (goto-char (- (pimacs-section-end ,s) (length (pimacs-section-padding ,s))))
       (let ((,body-beginning (point))
             (,changed-beginning nil)
             (,change-hook nil))
         (setq ,change-hook
               (lambda (beginning _end _old-length)
                 (setq ,changed-beginning
                       (if ,changed-beginning
                           (min beginning ,changed-beginning)
                         beginning))))
         (add-hook 'after-change-functions ,change-hook nil t)
         (unwind-protect
             (progn ,@body)
           (remove-hook 'after-change-functions ,change-hook t))
         (pimacs-section--apply-face ,s
                                     (or ,changed-beginning ,body-beginning)
                                     (point)))
       (forward-char (length (pimacs-section-padding ,s)))
       (setf (pimacs-section-beginning ,s) (pimacs-section--advance-pointer-maker (pimacs-section-beginning ,s)))
       (pimacs-section--update-section-end ,s (point-marker))
       (pimacs-section--propertize-section ,s)
       (pimacs-section--update-visibility-indicator ,s)
       ,s)))

(defmacro pimacs-section--replace-section (section &rest body)
  (declare (indent 1)
           (debug (symbolp body)))
  (let ((s (make-symbol "*section*"))
        (body-beginning (make-symbol "*body-beginning*"))
        (padding-beginning (make-symbol "*padding-beginning*")))
    `(let* ((,s ,section))
       (delete-region (pimacs-section-beginning ,s) (pimacs-section-end ,s))
       (setf (pimacs-section-children ,s) nil)
       (goto-char (pimacs-section-beginning ,s))
       (setf (pimacs-section-beginning ,s) (point-marker))
       (let ((,body-beginning (point)))
         ,@body
         (let ((,padding-beginning (point)))
           (insert (pimacs-section-padding ,s))
           (remove-text-properties ,padding-beginning (point)
                                   '(face nil pimacs-section-face-order nil)))
         (pimacs-section--apply-face ,s ,body-beginning (point)))
       (setf (pimacs-section-beginning ,s) (pimacs-section--advance-pointer-maker (pimacs-section-beginning ,s)))
       (pimacs-section--update-section-end ,s (point-marker))
       (pimacs-section--propertize-section ,s)
       (if (pimacs-section--hidden-p ,s)
           (pimacs-section--set-visibility ,s (pimacs-section-visibility ,s))
         (pimacs-section--update-visibility-indicator ,s))
       ,s)))

(defmacro pimacs-section--create-or-replace-section (section type parent &rest body)
  "Create or replace SECTION of TYPE under PARENT, inserting BODY."
  (declare (indent 3)
           (debug (symbolp symbolp symbolp body)))
  `(if ,section
       (pimacs-section--replace-section ,section ,@body)
     (pimacs-section--create-section ,type ,parent ,@body)))

(defun pimacs-section--delete-section (section)
  (let ((beg (pimacs-section-beginning section))
        (end (pimacs-section-end section))
        (parent (pimacs-section-parent section)))
    (delete-region beg end)
    (when parent
      (setf (pimacs-section-children parent)
            (delq section (pimacs-section-children parent)))
      (pimacs-section--update-section-end parent (copy-marker beg)))))

(defun pimacs-section--update-section-end (section end)
  (when section
    (let ((current-end (pimacs-section-end section)))
      (when (or (null current-end)
                (<= (marker-position current-end) (marker-position end)))
        (setf (pimacs-section-end section) end)
        ;; rebuild the overlay if the section is hidden
        (when (pimacs-section--hidden-p section)
          (pimacs-section--set-visibility section (pimacs-section-visibility section)))))
    (pimacs-section--update-section-end (pimacs-section-parent section) end)))

(defun pimacs-section--propertize-section (section)
  "Add text-property needed for SECTION."
  (put-text-property (pimacs-section-beginning section)
                     (pimacs-section-end section)
                     'pimacs-section section))

(defun pimacs-section--find-section (path top)
  "Find the section at the path PATH in subsection of section TOP."
  (if (null path)
      top
    (let ((secs (pimacs-section-children top)))
      (while (and secs (not (eq (car path)
                                (pimacs-section-type (car secs)))))
        (setq secs (cdr secs)))
      (and (car secs)
           (pimacs-section--find-section (cdr path) (car secs))))))

(defun pimacs-section--section-path (section)
  "Return the path of SECTION."
  (if (or (not section) (not (pimacs-section-parent section)))
      '()
    (append (pimacs-section--section-path (pimacs-section-parent section))
            (list (pimacs-section-type section)))))

(defun pimacs-section--current-section ()
  "Return the pimacs section at point."
  (pimacs-section--section-at (point)))

(defun pimacs-section--section-at (pos)
  "Return the pimacs section at position POS."
  (get-text-property pos 'pimacs-section))

(defun pimacs-section--find-section-after (pos secs)
  "Find the first section that begins after POS in the list SECS."
  (while (and secs
              (not (> (pimacs-section-beginning (car secs)) pos)))
    (setq secs (cdr secs)))
  (car secs))

(defun pimacs-section--find-section-before (pos secs)
  "Find the last section that begins before POS in the list SECS."
  (let ((prev nil))
    (while (and secs
                (not (> (pimacs-section-beginning (car secs)) pos)))
      (setq prev (car secs))
      (setq secs (cdr secs)))
    prev))

(defun pimacs-section--walk-sections (section step predicate)
  "Walk from SECTION using STEP until PREDICATE matches.
Return the first matching section, or nil if there is none."
  (setq section (and section (funcall step section)))
  (while (and section
              (not (funcall predicate section)))
    (setq section (funcall step section)))
  section)

(defun pimacs-section--navigable-children (section)
  "Return the child sections of SECTION that should be navigated."
  (and (pimacs-section--visible-p section)
       (pimacs-section-children section)))

(defun pimacs-section--next-after-subtree-step (section)
  "Return the first section after SECTION's subtree in tree order."
  (let ((parent (pimacs-section-parent section)))
    (if parent
        (let ((next (cadr (memq section
                                (pimacs-section-children parent)))))
          (or next
              (pimacs-section--next-after-subtree-step parent))))))

(defun pimacs-section--next-section-step (section)
  "Return the section immediately after SECTION in tree order."
  (or (car (pimacs-section--navigable-children section))
      (pimacs-section--next-after-subtree-step section)))

(defun pimacs-section--next-section (section)
  "Return the section that is after SECTION."
  (pimacs-section--walk-sections section #'pimacs-section--next-section-step #'always))

(defun pimacs-section--next-section-of-type (section type)
  "Return the first section after SECTION whose type is TYPE."
  (pimacs-section--walk-sections section #'pimacs-section--next-section-step
                                 (lambda (next)
                                   (eq (pimacs-section-type next) type))))
(defun pimacs-section--next-target-at-point ()
  "Return the section `pimacs-goto-next-section' would jump to from point."
  (let ((section (pimacs-section--current-section)))
    (and section
         (or (pimacs-section--find-section-after (point)
                                                 (pimacs-section--navigable-children section))
             (pimacs-section--next-after-subtree-step section)))))

(defun pimacs-section--goto-next-section-of-type (type)
  "Go to the next pimacs section whose type is TYPE."
  (let* ((target (pimacs-section--next-target-at-point))
         (next (and target
                    (if (eq (pimacs-section-type target) type)
                        target
                      (pimacs-section--next-section-of-type target type)))))
    (if next
        (goto-char (pimacs-section-beginning next))
      (message "No next %s section" type))))

(defun pimacs-goto-next-section ()
  "Go to the next pimacs section."
  (interactive)
  (if-let ((next (pimacs-section--next-target-at-point)))
      (goto-char (pimacs-section-beginning next))
    (message "No next section")))

(defun pimacs-section--prev-section-step (section)
  "Return the section immediately before SECTION in tree order."
  (when-let ((parent (pimacs-section-parent section)))
    (if-let ((prev (cadr (memq section
                               (reverse (pimacs-section-children parent))))))
        (progn
          (while (pimacs-section--navigable-children prev)
            (setq prev (car (last (pimacs-section--navigable-children prev)))))
          prev)
      (and (pimacs-section-parent parent)
           parent))))

(defun pimacs-section--prev-section (section)
  "Return the section that is before SECTION."
  (pimacs-section--walk-sections section #'pimacs-section--prev-section-step #'always))

(defun pimacs-section--prev-section-of-type (section type)
  "Return the first section before SECTION whose type is TYPE."
  (pimacs-section--walk-sections section #'pimacs-section--prev-section-step
                                 (lambda (prev)
                                   (eq (pimacs-section-type prev) type))))
(defun pimacs-section--previous-target-at-point ()
  "Return the section `pimacs-goto-previous-section' would jump to from point."
  (let ((section (pimacs-section--current-section)))
    (cond
     ((null section)
      (and pimacs-section--root-section
           (car (last (pimacs-section-children pimacs-section--root-section)))))
     ((= (point) (pimacs-section-beginning section))
      (pimacs-section--prev-section section))
     (t
      (or (pimacs-section--find-section-before (point)
                                               (pimacs-section--navigable-children section))
          section)))))

(defun pimacs-goto-previous-section ()
  "Goto the previous pimacs section."
  (interactive)
  (if-let ((prev (pimacs-section--previous-target-at-point)))
      (goto-char (pimacs-section-beginning prev))
    (message "No previous section")))

(defun pimacs-section--goto-previous-section-of-type (type)
  "Go to the previous pimacs section whose type is TYPE."
  (let* ((target (pimacs-section--previous-target-at-point))
         (prev (and target
                    (if (eq (pimacs-section-type target) type)
                        target
                      (pimacs-section--prev-section-of-type target type)))))
    (if prev
        (goto-char (pimacs-section-beginning prev))
      (message "No previous %s section" type))))

(defun pimacs-goto-last-section ()
  "Go to the last child section of `pimacs-section--root-section'."
  (interactive)
  (if (and pimacs-section--root-section
           (pimacs-section-children pimacs-section--root-section))
      (goto-char (pimacs-section-beginning
                  (car (last (pimacs-section-children pimacs-section--root-section)))))
    (message "No sections")))

(defun pimacs-section--isearch-open (ov)
  (when-let ((section
              (get-text-property (overlay-start ov) 'pimacs-section))
             (parent (pimacs-section-parent section)))
    (while (and parent (not (eq parent pimacs-section--root-section)))
      (setq section (pimacs-section-parent section))
      (setq parent (pimacs-section-parent section)))
    (pimacs-section--set-visibility section :show)))

(defun pimacs-section--isearch-open-temporary (ov restore)
  (if restore
      (progn
        (overlay-put ov 'invisible
                     (overlay-get ov 'pimacs-section-isearch-invisible))
        (overlay-put ov 'display
                     (overlay-get ov 'pimacs-section-isearch-display))
        (overlay-put ov 'pimacs-section-isearch-invisible nil)
        (overlay-put ov 'pimacs-section-isearch-display nil))
    (overlay-put ov 'pimacs-section-isearch-invisible
                 (overlay-get ov 'invisible))
    (overlay-put ov 'pimacs-section-isearch-display
                 (overlay-get ov 'display))
    (overlay-put ov 'invisible nil)
    (overlay-put ov 'display nil)))

(defun pimacs-section--visibility-indicator ()
  (and (display-graphic-p)
       pimacs-section-visibility-indicators))

(defun pimacs-section--ancestors-visible-p (section)
  (let ((parent (pimacs-section-parent section)))
    (or (null parent)
        (and (pimacs-section--visible-p parent)
             (pimacs-section--ancestors-visible-p parent)))))

(defun pimacs-section--update-visibility-indicator (section)
  (when (pimacs-section-parent section)
    (let ((beg (pimacs-section-beginning section))
          (eol (save-excursion
                 (goto-char (pimacs-section-beginning section))
                 (line-end-position))))
      (dolist (ov (overlays-in beg eol))
        (when (overlay-get ov 'pimacs-section-visibility-indicator)
          (delete-overlay ov)))
      (when (pimacs-section--ancestors-visible-p section)
        (when-let ((indicator (pimacs-section--visibility-indicator)))
          (let ((ov (make-overlay beg eol nil t))
                (bitmap (if (pimacs-section--hidden-p section)
                            (car indicator)
                          (cdr indicator))))
            (overlay-put ov 'evaporate t)
            (overlay-put ov 'pimacs-section-visibility-indicator t)
            (overlay-put ov 'before-string
                         (propertize "fringe" 'display
                                     `(left-fringe ,bitmap fringe)))))))))

(defun pimacs-section--update-descendant-visibility-indicators (section)
  (dolist (child (pimacs-section-children section))
    (pimacs-section--update-visibility-indicator child)
    (pimacs-section--update-descendant-visibility-indicators child)))

(defun pimacs-section--set-visibility (section visibility)
  "Set the visibility state of SECTION.

VISIBILITY can be one of:
- `:autoshow'  - visible, never toggled by user (initial state)
- `:autohide'  - hidden, auto-managed
- `:show'      - visible, user explicitly toggled
- `:hide'      - hidden, user explicitly toggled"
  (setf (pimacs-section-visibility section) visibility)
  (let ((inhibit-read-only t)
        (beg (save-excursion
               (goto-char (pimacs-section-beginning section))
               (forward-line)
               (point-marker)))
        (end (pimacs-section-end section)))

    ;; Remove any existing hide overlays.
    (remove-overlays beg end 'pimacs-section-hidden t)

    (when (and (pimacs-section--hidden-p section) (< beg end))
      (let ((ov (make-overlay beg end)))
        (overlay-put ov 'pimacs-section-hidden t)
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'invisible t)
        (overlay-put ov 'display "")
        (overlay-put ov 'isearch-open-invisible
                     #'pimacs-section--isearch-open)
        (overlay-put ov 'isearch-open-invisible-temporary
                     #'pimacs-section--isearch-open-temporary)))

    (pimacs-section--update-visibility-indicator section))

  (when (pimacs-section--visible-p section)
    (dolist (child (pimacs-section-children section))
      (pimacs-section--set-visibility child
                                      (pimacs-section-visibility child))))
  (pimacs-section--update-descendant-visibility-indicators section))

(defun pimacs-toggle-section ()
  "Toggle visibility of current section."
  (interactive)
  (when-let (section (pimacs-section--current-section))
    (when (pimacs-section-parent section)
      (goto-char (pimacs-section-beginning section))
      (if (pimacs-section--visible-p section)
          (pimacs-section--set-visibility section :hide)
        (pimacs-section--set-visibility section :show)))))

(defun pimacs-mouse-toggle-section (event)
  "Toggle visibility of the section clicked in the fringe.
EVENT is the mouse event that triggered the toggle."
  (interactive "e")
  (let* ((pos (event-start event))
         (section (pimacs-section--section-at (posn-point pos))))
    (when (and section (pimacs-section-parent section))
      (goto-char (pimacs-section-beginning section))
      (pimacs-toggle-section))))

(defun pimacs-section--autohide-eligible-p (section)
  (let ((filter pimacs-section-autohide-filter)
        (type (pimacs-section-type section)))
    (cond
     ((eq filter 'all) t)
     ((functionp filter) (funcall filter section))
     ((eq (car-safe filter) :include) (memq type (cdr filter)))
     ((eq (car-safe filter) :exclude) (not (memq type (cdr filter)))))))

(defun pimacs-section-autohide ()
  "Reconcile automatically managed section visibility."
  (interactive)
  (let* ((count pimacs-section-autohide-count)
         (children (pimacs-section-children pimacs-section--root-section))
         (eligible (and count
                        (seq-filter #'pimacs-section--autohide-eligible-p children)))
         (hide-count (if count (max 0 (- (length eligible) count)) 0))
         (hidden (make-hash-table :test 'eq)))
    (dolist (child (seq-take eligible hide-count))
      (puthash child t hidden))
    (dolist (child children)
      (unless (and (>= (point) (pimacs-section-beginning child))
                   (< (point) (pimacs-section-end child)))
        (let ((visibility (pimacs-section-visibility child))
              (hide-p (gethash child hidden)))
          (cond
           ((and hide-p (eq visibility :autoshow))
            (pimacs-section--set-visibility child :autohide))
           ((and (not hide-p) (eq visibility :autohide))
            (pimacs-section--set-visibility child :autoshow))))))))

(defun pimacs-section--all-sections (section)
  (cons section
        (apply #'append
               (mapcar #'pimacs-section--all-sections
                       (pimacs-section-children section)))))

(defun pimacs-section--set-visibility-level (sections depth level)
  (dolist (section sections)
    (pimacs-section--set-visibility
     section (if (<= depth level) :show :hide))
    (pimacs-section--set-visibility-level
     (pimacs-section-children section) (1+ depth) level)))

(defun pimacs-section--visible-level (children)
  (let ((level 0)
        (frontier children))
    (while (and frontier
                (cl-every (lambda (section)
                            (not (pimacs-section--hidden-p section)))
                          frontier))
      (setq level (1+ level)
            frontier (apply #'append
                            (mapcar #'pimacs-section-children frontier))))
    level))

(defun pimacs-section--cycle-global ()
  (when-let ((children (and pimacs-section--root-section
                            (pimacs-section-children pimacs-section--root-section))))
    (let* ((sections (apply #'append
                            (mapcar #'pimacs-section--all-sections children)))
           (all-visible (not (cl-some #'pimacs-section--hidden-p sections)))
           (level (if all-visible
                      0
                    (1+ (pimacs-section--visible-level children)))))
      (pimacs-section--set-visibility-level children 1 level))))

(defun pimacs-section--show-level-all (level)
  (when-let ((children (and pimacs-section--root-section
                            (pimacs-section-children pimacs-section--root-section))))
    (pimacs-section--set-visibility-level children 1 level)))

(defun pimacs-section-show-level-1-all ()
  "Show only headings of all root sections."
  (interactive)
  (pimacs-section--show-level-all 0))

(defun pimacs-section-show-level-2-all ()
  "Show root sections and only headings of their children."
  (interactive)
  (pimacs-section--show-level-all 1))

(defun pimacs-section-show-level-3-all ()
  "Show sections through the second level and headings at the third."
  (interactive)
  (pimacs-section--show-level-all 2))

(defun pimacs-section--show-level (section level)
  (let ((depth (length (pimacs-section--section-path section))))
    (while (> depth level)
      (setq section (pimacs-section-parent section)
            depth (1- depth)))
    (if (< depth level)
        (progn
          (pimacs-section--set-visibility section :show)
          (pimacs-section--set-visibility-level
           (pimacs-section-children section) 1 (- level depth 1)))
      (pimacs-section--set-visibility section :hide))
    (goto-char (pimacs-section-beginning section))))

(defun pimacs-section-show-level-1 ()
  "Show surrounding sections on the first level."
  (interactive)
  (when-let ((section (pimacs-section--current-section)))
    (pimacs-section--show-level section 1)))

(defun pimacs-section-show-level-2 ()
  "Show surrounding sections through the second level."
  (interactive)
  (when-let ((section (pimacs-section--current-section)))
    (pimacs-section--show-level section 2)))

(defun pimacs-section-show-level-3 ()
  "Show surrounding sections through the third level."
  (interactive)
  (when-let ((section (pimacs-section--current-section)))
    (pimacs-section--show-level section 3)))

(defmacro pimacs-section--section-case (&rest clauses)
  "Make different action depending of current section.

CLAUSES is a list of CLAUSE, each clause is (SECTION-TYPE &BODY)
where SECTION-TYPE describe section where BODY will be run.

This returns non-nil if some section matches.  If the
corresponding body return a non-nil value, it is returned,
otherwise it return t."

  (declare (indent 1)
           (debug (&rest (sexp body))))
  (let ((section (make-symbol "*section*"))
        (path (make-symbol "*path*")))
    `(let* ((,section (pimacs-section--current-section))
            (,path (pimacs-section--section-path ,section)))
       (cond ,@(mapcar (lambda (clause)
                         (let ((prefix (car clause))
                               (body (cdr clause)))
                           `(,(if (eq prefix t)
                                  `t
                                `(pimacs-section--prefix-p ',(reverse prefix) (reverse ,path)))
                             (or (progn ,@body)
                                 t))))
                       clauses)))))

(defvar-keymap pimacs-section-demo-mode-map
  :doc "Keymap for `pimacs-section-demo-mode'."
  :parent special-mode-map
  "TAB" #'pimacs-toggle-section
  "C-i" #'pimacs-toggle-section)

(define-derived-mode pimacs-section-demo-mode special-mode "Pimacs Section Demo"
  "Major mode for the Pimacs section demo."
  (setq-local buffer-read-only t))

(defun pimacs-section-demo ()
  "Create a demo buffer with nested Pimacs sections."
  (interactive)
  (let ((buf (get-buffer-create "*pimacs-section-demo*")))
    (with-current-buffer buf
      (pimacs-section-demo-mode)
      (setq buffer-read-only nil)
      (erase-buffer)
      (let* ((pimacs-section-padding "\n")
             (root (pimacs-section--create-root-section))
             (build (pimacs-section--new-section 'build root))
             (compile (pimacs-section--new-section 'compile build))
             (tests (pimacs-section--new-section 'test build))
             (unit-tests (pimacs-section--new-section 'test tests))
             (integration-tests (pimacs-section--new-section 'integration-tests tests))
             (logs (pimacs-section--new-section 'logs root))
             (server-log (pimacs-section--new-section 'server-log logs))
             (worker-log (pimacs-section--new-section 'worker-log logs))
             (deploy (pimacs-section--new-section 'deploy root))
             (deploy-result (pimacs-section--new-section 'deploy-result deploy)))
        (pimacs-section--insert-section build
          (insert "[-] Build"))
        (pimacs-section--insert-section compile
          (insert "  [-] Compile\n")
          (insert "      Compiling foo.c\n")
          (insert "      Compiling bar.c\n"))
        (pimacs-section--insert-section tests
          (insert "  [-] Tests"))
        (pimacs-section--insert-section unit-tests
          (insert "      [-] Unit Tests\n")
          (insert "          test-auth ... ok\n")
          (insert "          test-db ... ok\n"))
        (pimacs-section--insert-section integration-tests
          (insert "      [-] Integration Tests\n")
          (insert "          api-flow ... running\n"))
        (pimacs-section--insert-section logs
          (insert "[-] Logs"))
        (pimacs-section--insert-section server-log
          (insert "  [-] Server\n")
          (insert "      Listening on :8080\n")
          (insert "      Connected client #42\n"))
        (pimacs-section--insert-section worker-log
          (insert "  [-] Worker\n")
          (insert "      Job started\n")
          (insert "      Job completed\n"))
        (pimacs-section--insert-section deploy
          (insert "[-] Deploy"))
        (pimacs-section--insert-section deploy-result
          (insert "    Uploading artifacts...\n")
          (insert "    Restarting services...\n"))
        (pimacs-section--append-section server-log
          (insert "      Connected client #43\n")
          (insert "      Connected client #44\n")
          (insert "      Connected client #45\n"))
        (pimacs-section--replace-section worker-log
          (insert "  [-] Worker\n")
          (insert "      Restarted\n")
          (insert "      Processing queue...\n")
          (insert "      Queue drained\n"))
        (pimacs-section--append-section server-log
          (insert "      Connected client #46\n")
          (insert "      Connected client #47\n")
          (insert "      Connected client #48\n")))

      (setq buffer-read-only t)
      (goto-char (point-min)))

    (pop-to-buffer buf)))

(defun pimacs-section--info-sexp (info)
  (if (cl-struct-p info)
      (let ((type (type-of info)))
        (cons
         type
         (cl-loop for (slot) in (cdr (cl-struct-slot-info type))
                  append (list (intern (concat ":" (symbol-name slot)))
                               (cl-struct-slot-value type slot info)))))
    info))

(defun pimacs-section--fontify-info (info)
  (condition-case err
      (with-temp-buffer
        (emacs-lisp-mode)
        (let ((print-circle t)
              (print-level 10)
              (print-length 100))
          (insert (pp-to-string (pimacs-section--info-sexp info))))
        (font-lock-ensure)
        (buffer-string))
    (error
     (format "<Unable to display info: %s>" (error-message-string err)))))

(defun pimacs-section--insert-description-link (section)
  (insert-text-button
   (format "%s" (pimacs-section-type section))
   'action (lambda (_button) (pimacs-describe-section section))
   'follow-link t))

(defun pimacs-section--insert-description-field (field)
  (insert (propertize field 'face 'font-lock-keyword-face)))

(defun pimacs-describe-section (section)
  "Display information about SECTION in a Help buffer."
  (interactive
   (let ((section (pimacs-section--current-section)))
     (unless section
       (user-error "No section at point"))
     (list section)))
  (help-setup-xref (list #'pimacs-describe-section section)
                   (called-interactively-p 'interactive))
  (with-help-window (help-buffer)
    (let ((parent (pimacs-section-parent section)))
      (pimacs-section--insert-description-field "type:")
      (insert (format " %s\n" (pimacs-section-type section)))
      (when (and parent (pimacs-section-parent parent))
        (pimacs-section--insert-description-field "parent:")
        (insert " ")
        (pimacs-section--insert-description-link parent)
        (insert "\n"))
      (pimacs-section--insert-description-field "beginning:")
      (insert (format " %s\n" (pimacs-section-beginning section)))
      (pimacs-section--insert-description-field "end:")
      (insert (format " %s\n" (pimacs-section-end section)))
      (pimacs-section--insert-description-field "visibility:")
      (insert (format " %s\n" (pimacs-section-visibility section)))
      (pimacs-section--insert-description-field "visibility-user-overridden:")
      (insert (format " %s\n" (pimacs-section--user-toggled-p section)))
      (pimacs-section--insert-description-field "autohide-eligible:")
      (insert
       (format " %s\n"
               (if (and parent (not (pimacs-section-parent parent)))
                   (pimacs-section--autohide-eligible-p section)
                 "not applicable")))
      (pimacs-section--insert-description-field "face:")
      (insert (format " %s\n" (pimacs-section-face section)))
      (when-let ((children (pimacs-section-children section)))
        (pimacs-section--insert-description-field "Children:")
        (dolist (child children)
          (insert " ")
          (pimacs-section--insert-description-link child))
        (insert "\n"))
      (when-let ((info (pimacs-section-info section)))
        (pimacs-section--insert-description-field "info:")
        (insert "\n")
        (insert (pimacs-section--fontify-info info))))))

(defun pimacs-section--section-line ()
  "Return the 0-based line number of point within the current section.
Returns 0 if point is on the first line of the section or if there is
no current section."
  (if-let ((section (pimacs-section--current-section)))
      (- (line-number-at-pos (point))
         (line-number-at-pos (pimacs-section-beginning section)))
    0))

(provide 'pimacs-section)

;;; pimacs-section.el ends here
