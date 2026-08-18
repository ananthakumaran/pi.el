;;; pimacs-doctor.el --- Dependency checks for Pimacs -*- lexical-binding: t; -*-

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

;; Interactive dependency checks and installers for Pimacs.

;;; Code:

(require 'button)
(require 'subr-x)
(require 'treesit)
(require 'pimacs-agent)

(defconst pimacs-doctor--treesit-language-source-alist
  '((markdown
     "https://github.com/tree-sitter-grammars/tree-sitter-markdown"
     "v0.5.3" "tree-sitter-markdown/src")
    (markdown-inline
     "https://github.com/tree-sitter-grammars/tree-sitter-markdown"
     "v0.5.3" "tree-sitter-markdown-inline/src")))

(defvar-keymap pimacs-doctor-mode-map
  :doc "Keymap for `pimacs-doctor-mode'."
  :parent special-mode-map
  "g" #'pimacs-doctor-refresh)

(define-derived-mode pimacs-doctor-mode special-mode "Pimacs Doctor"
  "Major mode for the Pimacs dependency report."
  (setq-local revert-buffer-function (lambda (&rest _) (pimacs-doctor-refresh))))

(defun pimacs-doctor--executable ()
  (if (file-name-absolute-p pimacs-executable)
      (and (file-executable-p pimacs-executable) pimacs-executable)
    (executable-find pimacs-executable)))

(defun pimacs-doctor--treesit-ready-p (language)
  (condition-case nil
      (treesit-ready-p language t)
    (error nil)))

(defun pimacs-doctor--insert-status (ok text)
  (insert (propertize (if ok "  ✔ " "  ✖ ")
                      'face (if ok 'success 'error))
          text "\n"))

(defun pimacs-doctor--insert-pi-status ()
  (insert (propertize "Pi\n" 'face 'bold))
  (if-let ((executable (pimacs-doctor--executable)))
      (let ((pimacs-executable executable))
        (condition-case err
            (let* ((version (pimacs--agent-version))
                   (compatible (pimacs--agent-version-compatible-p version)))
              (pimacs-doctor--insert-status
               compatible
               (format "%s %s (minimum %s)"
                       executable version pimacs--minimum-version))
              (unless compatible
                (insert-text-button "Install or upgrade Pi"
                                    'action #'pimacs-doctor--install-pi)
                (insert "\n")))
          (error
           (pimacs-doctor--insert-status
            nil (format "%s is available, but its version could not be determined: %s"
                        executable (error-message-string err)))
           (insert-text-button "Install or upgrade Pi"
                               'action #'pimacs-doctor--install-pi)
           (insert "\n"))))
    (pimacs-doctor--insert-status nil (format "%s was not found" pimacs-executable))
    (insert-text-button "Install or upgrade Pi"
                        'action #'pimacs-doctor--install-pi)
    (insert "\n"))
  (insert "\n"))

(defun pimacs-doctor--insert-treesit-status ()
  (insert (propertize "Tree-sitter\n" 'face 'bold))
  (if (treesit-available-p)
      (progn
        (pimacs-doctor--insert-status t "Tree-sitter is available")
        (let ((markdown-ready (pimacs-doctor--treesit-ready-p 'markdown))
              (inline-ready (pimacs-doctor--treesit-ready-p 'markdown-inline)))
          (pimacs-doctor--insert-status
           markdown-ready
           (format "markdown grammar is %sinstalled" (if markdown-ready "" "not ")))
          (pimacs-doctor--insert-status
           inline-ready
           (format "markdown-inline grammar is %sinstalled" (if inline-ready "" "not ")))
          (unless (and markdown-ready inline-ready)
            (insert-text-button "Install Markdown grammars"
                                'action #'pimacs-doctor--install-grammars)
            (insert "\n"))))
    (pimacs-doctor--insert-status nil "Tree-sitter is not available"))
  (insert "\n"))

(defun pimacs-doctor--render ()
  (let ((inhibit-read-only t))
    (erase-buffer)
    (pimacs-doctor-mode)
    (insert (propertize "Pimacs Doctor\n\n" 'face 'bold))
    (pimacs-doctor--insert-pi-status)
    (pimacs-doctor--insert-treesit-status)
    (insert "Press g to refresh this report.\n")
    (goto-char (point-min))))

(defun pimacs-doctor--install-pi (&rest _)
  (async-shell-command
   "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
   "*Pimacs Install Pi*")
  (message "When installation finishes, press g in the Pimacs Doctor buffer to refresh."))

(defun pimacs-doctor--install-grammars (&rest _)
  (condition-case err
      (let ((treesit-language-source-alist
             (append pimacs-doctor--treesit-language-source-alist
                     treesit-language-source-alist)))
        (unless (treesit-available-p)
          (user-error "Tree-sitter is not available in this Emacs"))
        (dolist (language '(markdown markdown-inline))
          (unless (pimacs-doctor--treesit-ready-p language)
            (treesit-install-language-grammar language)))
        (pimacs-doctor-refresh)
        (message "Installed Markdown Tree-sitter grammars."))
    (error
     (pimacs-doctor-refresh)
     (message "Failed to install Markdown Tree-sitter grammars: %s"
              (error-message-string err)))))

(defun pimacs-doctor-refresh ()
  "Refresh the Pimacs Doctor buffer."
  (interactive)
  (pimacs-doctor--render))

;;;###autoload
(defun pimacs-doctor ()
  "Show the Pimacs dependency report."
  (interactive)
  (let ((buffer (get-buffer-create "*Pimacs Doctor*")))
    (with-current-buffer buffer
      (pimacs-doctor--render))
    (pop-to-buffer buffer)))

(provide 'pimacs-doctor)

;;; pimacs-doctor.el ends here
