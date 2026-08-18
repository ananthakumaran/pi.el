;;; pimacs-utils.el --- Utilities -*- lexical-binding: t; -*-

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

;; Utility helpers shared by pimacs.el.

;;; Code:

(require 'subr-x)
(require 'widget)
(require 'ffap)
(require 'diff-mode)

(defun pimacs--json-read-object ()
  (json-parse-buffer :object-type 'plist :null-object 'json-null :false-object 'json-false :array-type 'list))

(defun pimacs--json-encode (obj)
  "Encode OBJ into a JSON string.  JSON arrays must be represented with vectors."
  (json-serialize obj :null-object 'json-null :false-object 'json-false))

(defun pimacs--format-number-short (n)
  "Format number N into a short human-readable string with K/M/B suffixes."
  (cond
   ((not (numberp n)) "?")
   ((>= n 1000000000)
    (format "%.1fB" (/ n 1000000000.0)))
   ((>= n 1000000)
    (format "%.1fM" (/ n 1000000.0)))
   ((>= n 1000)
    (format "%.1fk" (/ n 1000.0)))
   (t
    (number-to-string n))))

(defun pimacs--format-number-fixed (number decimal-places)
  (string-trim-right
   (string-trim-right
    (format (format "%%.%df" decimal-places) number)
    "0+")
   "[.]"))

(defun pimacs--fill-string (string)
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (while (not (eobp))
      (fill-region (point) (line-end-position))
      (forward-line 1))
    (buffer-string)))

(defun pimacs--short-uuid (uuid)
  (when (stringp uuid)
    (substring uuid -8)))

(defun pimacs--buffer-string-common-prefix-length (buffer start end string)
  (with-current-buffer buffer
    (let ((buffer-position start)
          (string-position 0)
          (string-end (length string))
          done)
      (while (and (not done)
                  (< buffer-position end)
                  (< string-position string-end))
        (if (not (equal (text-properties-at buffer-position buffer)
                        (text-properties-at string-position string)))
            (setq done t)
          (let* ((buffer-property-end
                  (next-property-change buffer-position buffer end))
                 (string-property-end
                  (next-property-change string-position string string-end))
                 (span-end
                  (+ buffer-position
                     (min (- buffer-property-end buffer-position)
                          (- string-property-end string-position)))))
            (while (and (< buffer-position span-end) (not done))
              (if (= (char-after buffer-position) (aref string string-position))
                  (setq buffer-position (1+ buffer-position)
                        string-position (1+ string-position))
                (setq done t))))))
      (- buffer-position start))))

(defmacro pimacs--def-permanent-buffer-local (name &optional init-value)
  "Declare NAME as buffer local variable with optional INIT-VALUE."
  `(progn
     (defvar ,name ,init-value)
     (make-variable-buffer-local ',name)
     (put ',name 'permanent-local t)))

(defun pimacs--join (x &optional join-char)
  (let ((join-char (or join-char "\n")))
    (cond
     ((stringp x) x)
     ((proper-list-p x) (mapconcat (lambda (item) (pimacs--join item join-char)) x join-char))
     ((consp x) (pimacs--join (cdr x) join-char))
     (t ""))))

(defun pimacs--insert-error (text)
  "Insert TEXT with `pimacs-error-face'."
  (insert (propertize text 'face 'pimacs-error-face)))

(defun pimacs--insert-file-link (path &optional suffix)
  (widget-create 'file-link
                 :button-prefix ""
                 :button-suffix (or suffix "")
                 path))

(defun pimacs--keyword-name (keyword)
  "Return the name of KEYWORD as a string without the leading colon."
  (substring (symbol-name keyword) 1))


(defun pimacs--seconds-elapsed-since (time)
  (time-to-seconds (time-subtract (current-time) time)))

(defun pimacs--hash-remove-if (pred table)
  "Remove entries from TABLE for which PRED return non-nil.

PRED is called with KEY VALUE."
  (maphash
   (lambda (k v)
     (when (funcall pred k v)
       (remhash k table)))
   table))

(defun pimacs--file-at-point ()
  (let ((ffap-url-regexp nil))
    (when-let ((file (ffap-file-at-point)))
      (when (file-exists-p file)
        file))))

(defun pimacs--plist-merge (&rest plists)
  (let (result)
    (dolist (plist plists result)
      (while plist
        (setq result (plist-put result (car plist) (cadr plist))
              plist (cddr plist))))))

(defun pimacs--alist-get-equal (key alist)
  "Return the value for KEY in ALIST, comparing keys with `equal'."
  (alist-get key alist nil nil #'equal))

(defun pimacs--sort-entries-by-key (entries)
  (sort entries (lambda (a b) (string< (car a) (car b)))))

(defun pimacs--completing-read (prompt collection)
  (completing-read prompt
                   (lambda (string pred action)
                     (if (eq action 'metadata)
                         '(metadata (display-sort-function . identity))
                       (complete-with-action action collection string pred)))
                   nil t))

(defun pimacs--read-option (options current prompt)
  (let* ((items (mapcar (lambda (opt)
                          (cons (cdr opt) (car opt)))
                        options))
         (current-keyword (when current
                            (intern (concat ":" current))))
         (default-display (when current-keyword
                            (cdr (assoc current-keyword options))))
         (selected-display (completing-read
                            (format "%s (current: %s): " prompt (or current "?"))
                            (lambda (string pred action)
                              (if (eq action 'metadata)
                                  '(metadata (display-sort-function . identity))
                                (complete-with-action action items string pred)))
                            nil t nil nil default-display)))
    (when selected-display
      (let ((selected-keyword (pimacs--alist-get-equal selected-display items)))
        (cons (pimacs--keyword-name selected-keyword)
              (cdr (assoc selected-keyword options)))))))

(defun pimacs--get-line-contents (buffer line)
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (forward-line (1- line))
        (buffer-substring-no-properties
         (point)
         (line-end-position))))))


(defun pimacs--render-markdown-default (operation &optional _state text)
  (pcase operation
    (:create nil)
    (:stream (list (list :append text)))
    (:final (list (list :append text)))
    (:destroy nil)))

(defun pimacs--render-thinking-default (operation &optional _state text)
  (pcase operation
    (:create nil)
    (:stream
     (list (list :append text)))
    (:final
     (list (list :append (pimacs--fill-string text))))
    (:destroy nil)))

(defun pimacs--render-content (filename content &optional mode)
  (with-temp-buffer
    (when filename
      ;; Use a fake temp filename preserving extension only.
      (setq-local
       buffer-file-name
       (expand-file-name
        (concat "pimacs-fontify"
                (when-let ((ext (file-name-extension filename t)))
                  ext))
        temporary-file-directory)))

    (insert content)

    (let ((inhibit-message t)
          (message-log-max nil))
      (ignore-errors
        (delay-mode-hooks
          (let ((enable-local-variables nil)
                (enable-local-eval nil))
            (if mode
                (funcall mode)
              (set-auto-mode))
            (font-lock-ensure)))))

    ;; Prevent save prompts
    (set-buffer-modified-p nil)

    ;; Preserve text properties
    (buffer-string)))

(defun pimacs--section-header (text)
  "Extract a short header from TEXT for use as section info."
  (when-let ((header (car (split-string text "\n" t))))
    (truncate-string-to-width (string-trim header) 80 nil nil t)))

(defun pimacs--diff-overlay-to-text-properties ()
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (eq (overlay-get ov 'diff-mode) 'fine)
      (put-text-property
       (overlay-start ov)
       (overlay-end ov)
       'face
       (overlay-get ov 'face)))))

(defun pimacs--render-diff (diff)
  (with-temp-buffer
    (insert diff)
    (ignore-errors
      (delay-mode-hooks
        (diff-mode)
        (font-lock-ensure)
        (goto-char (point-min))
        (while (not (eobp))
          (diff-hunk-next)
          (diff-refine-hunk))
        (pimacs--diff-overlay-to-text-properties)))
    (set-buffer-modified-p nil)
    (buffer-string)))

(defun pimacs--plist-get (list &rest args)
  (cl-reduce
   (lambda (object key)
     (when object
       (plist-get object key)))
   args
   :initial-value list))

(provide 'pimacs-utils)
;;; pimacs-utils.el ends here
