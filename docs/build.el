;;; build.el --- Build Pimacs documentation -*- lexical-binding: t; -*-

(require 'subr-x)

(defun pimacs-doc--format-lisp (text)
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert text)
    (let ((inhibit-message t))
      (indent-region (point-min) (point-max)))
    (string-trim (buffer-string))))

(defun pimacs-doc--format-docstring (doc)
  (let ((doc (replace-regexp-in-string "`\\([^']*\\)'" "@code{\\1}" doc)))
    (replace-regexp-in-string
     "^@code{[^}\n]+}[ \t][ \t]+[^\n]*\n\\(?:@code{[^}\n]+}[ \t][ \t]+[^\n]*\n\\)+"
     (lambda (block)
       (save-match-data
         (with-temp-buffer
           (insert block)
           (goto-char (point-min))
           (while (re-search-forward "^@code{\\([^}\n]+\\)}[ \t][ \t]+\\([^\n]*\\)" nil t)
             (replace-match (format "@item %s\n%s"
                                    (match-string 1)
                                    (match-string 2))
                            t t))
           (concat "@table @code\n" (buffer-string) "@end table\n"))))
     doc)))

(defun pimacs-doc--defcustom-default (form-start)
  (save-excursion
    (goto-char form-start)
    (forward-comment (point-max))
    (forward-char 1)
    (forward-sexp 1)
    (forward-comment (point-max))
    (forward-sexp 1)
    (forward-comment (point-max))
    (let ((default-start (point)))
      (forward-sexp 1)
      (buffer-substring-no-properties default-start (point)))))

(defun pimacs-doc--emit-defcustom (form form-start)
  (let* ((name (cadr form))
         (raw-doc (cadddr form)))
    (unless (stringp raw-doc)
      (error "Documentation missing for defcustom %S" name))
    (let* ((default (pimacs-doc--format-lisp
                     (pimacs-doc--defcustom-default form-start)))
           (doc (pimacs-doc--format-docstring raw-doc)))
      (if (string-match-p "\n" default)
          (format "@defopt %s\n\n@lisp\n%s\n@end lisp\n\n%s\n@end defopt\n\n"
                  name default doc)
        (format "@defopt %s @code{%s}\n\n%s\n@end defopt\n\n"
                name default doc)))))

(defun pimacs-doc--emit-defface (form _form-start)
  (let* ((name (cadr form))
         (face-spec (string-trim (pp-to-string (caddr form))))
         (doc (cadddr form)))
    (unless (stringp doc)
      (error "Documentation missing for defface %S" name))
    (setq doc (pimacs-doc--format-docstring doc))
    (if (string-match-p "\n" face-spec)
        (format "@deffn Face %s\n\n@lisp\n%s\n@end lisp\n\n%s\n@end deffn\n\n"
                name face-spec doc)
      (format "@deffn Face %s @code{%s}\n\n%s\n@end deffn\n\n"
              name face-spec doc))))

(defun pimacs-doc--collect (sources type emitter)
  (let (entries)
    (dolist (source (reverse sources))
      (with-temp-buffer
        (insert-file-contents source)
        (goto-char (point-min))
        (condition-case nil
            (while t
              (let ((form-start (point))
                    (form (read (current-buffer))))
                (when (eq (car form) type)
                  (push (funcall emitter form form-start) entries))))
          (end-of-file nil))))
    (apply #'concat (nreverse entries))))

(defun pimacs-doc--replace-generated (text name generated)
  (let* ((start-marker (format "@c %s-start" name))
         (end-marker (format "@c %s-end" name))
         (start (string-match (regexp-quote start-marker) text)))
    (unless start
      (error "Missing %s" start-marker))
    (let ((end (string-match (regexp-quote end-marker) text
                             (+ start (length start-marker)))))
      (unless end
        (error "Missing %s" end-marker))
      (concat (substring text 0 (+ start (length start-marker)))
              "\n\n"
              generated
              end-marker
              (substring text (+ end (length end-marker)))))))

(let ((sources (split-string (or (getenv "PIMACS_DOC_SOURCES") "") "[ \t\n]+" t)))
  (unless sources
    (error "PIMACS_DOC_SOURCES is empty"))
  (if (equal (getenv "PIMACS_DOC_ACTION") "lint")
      (progn
        (require 'checkdoc)
        (dolist (source sources)
          (checkdoc-file source)))
    (let ((text (with-temp-buffer
                 (insert-file-contents "pimacs.texi")
                 (buffer-string))))
      (setq text
            (pimacs-doc--replace-generated
             text "custom-variables"
             (pimacs-doc--collect sources 'defcustom #'pimacs-doc--emit-defcustom)))
      (setq text
            (pimacs-doc--replace-generated
             text "custom-faces"
             (pimacs-doc--collect sources 'defface #'pimacs-doc--emit-defface)))
      (with-temp-file "pimacs.texi"
        (insert text)))))
