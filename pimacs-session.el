;;; pimacs-session.el --- Session management -*- lexical-binding: t; -*-

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

;; Session management for Pimacs.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'pimacs-core)
(require 'pimacs-agent)
(require 'pimacs-state-line)
(require 'pimacs-utils)

(defcustom pimacs-list-sessions-table
  '(("Session" . (:session_name face font-lock-type-face))
    ("Provider" . :provider)
    ("Model" . :model)
    ("State" . (:agent_state face font-lock-constant-face))
    ("Context" . (:context_usage face shadow))
    ("Messages" . :total_messages)
    ("Cost" . (:cost face shadow))
    ("Project" . (:project_root face shadow)))
  "Columns displayed by `pimacs-list-sessions'.

Each entry is (HEADER . COMPONENT).  COMPONENT uses the same format as an
entry in `pimacs-header-line-format'."
  :type `(repeat
          (cons (string :tag "Header")
                ,(cadr pimacs--state-line-format-type)))
  :group 'pimacs)

(defcustom pimacs-list-sessions-sort-key '("Session" . nil)
  "Initial sort order for `pimacs-list-sessions'.

The car is a header from `pimacs-list-sessions-table'.  A non-nil cdr sorts
in descending order."
  :type '(cons (string :tag "Column")
               (boolean :tag "Descending"))
  :group 'pimacs)

(defvar pimacs--chats (make-hash-table :test 'equal))

(defun pimacs--current-chat ()
  (gethash pimacs--project-key pimacs--chats))

(defun pimacs--active-chat-candidates ()
  (let (candidates)
    (maphash
     (lambda (key agent)
       (when-let ((chat (gethash key pimacs--chats)))
         (when (and (process-live-p agent)
                    (buffer-live-p chat))
           (push (cons key chat) candidates))))
     pimacs--agents)
    candidates))

(defun pimacs--relevant-chat-candidates ()
  (let ((path (expand-file-name (or buffer-file-name default-directory))))
    (seq-filter
     (lambda (candidate)
       (when-let* ((agent (gethash (car candidate) pimacs--agents))
                   (root (process-get agent 'project-root)))
         (file-in-directory-p path root)))
     (pimacs--active-chat-candidates))))

(defun pimacs--chat-session-choice-label (chat &optional include-id)
  (with-current-buffer chat
    (let* ((name (plist-get pimacs--header-line-state :sessionName))
           (session-id (pimacs--plist-get pimacs--header-line-state :sessionStats :sessionId))
           (short-id (pimacs--short-uuid session-id)))
      (if (and (stringp name) (not (string-empty-p name)))
          (if (and include-id short-id)
              (concat name " " short-id)
            name)
        (or short-id "unknown")))))

(defun pimacs--select-chat (candidates prompt)
  (cond
   ((null candidates) nil)
   ((null (cdr candidates)) (car candidates))
   (t
    (let* ((labels
            (mapcar (lambda (candidate)
                      (cons (pimacs--chat-session-choice-label (cdr candidate)) candidate))
                    candidates))
           (choices
            (sort
             (mapcar
              (lambda (label)
                (if (> (cl-count (car label) labels :key #'car :test #'equal) 1)
                    (cons (pimacs--chat-session-choice-label (cdr (cdr label)) t) (cdr label))
                  label))
              labels)
             (lambda (a b) (string< (car a) (car b)))))
           (annotation-function
            (lambda (label)
              (when-let* ((candidate (cdr (assoc label choices)))
                          (agent (gethash (car candidate) pimacs--agents))
                          (root (process-get agent 'project-root)))
                (concat "  " (propertize (expand-file-name root) 'face 'dired-directory)))))
           (completion-extra-properties
            `(:annotation-function ,annotation-function))
           (selected (completing-read prompt choices nil t)))
      (cdr (assoc selected choices))))))

(defun pimacs--select-relevant-chat ()
  (when-let ((candidate (pimacs--select-chat (pimacs--relevant-chat-candidates)
                                             "Pimacs session: ")))
    (setq-local pimacs--project-key (car candidate))
    (cdr candidate)))

(defvar-keymap pimacs-list-sessions-mode-map
  :doc "Keymap for `pimacs-list-sessions-mode'."
  :parent tabulated-list-mode-map
  "RET" #'pimacs-list-sessions-visit
  "g" #'pimacs-list-sessions-refresh)

(define-derived-mode pimacs-list-sessions-mode tabulated-list-mode "Pimacs Sessions"
  "Major mode for listing active Pimacs sessions."
  (setq tabulated-list-padding 0
        tabulated-list-sort-key (copy-tree pimacs-list-sessions-sort-key)))

(defun pimacs--list-sessions-entries ()
  (mapcar
   (lambda (candidate)
     (with-current-buffer (cdr candidate)
       (list candidate
             (vconcat
              (mapcar
               (lambda (column)
                 (pimacs--format-state-line-component
                  (pimacs--state-line-state) (cdr column)))
               pimacs-list-sessions-table)))))
   (pimacs--active-chat-candidates)))

(defun pimacs--list-sessions-format (entries)
  (vconcat
   (cl-loop for column in pimacs-list-sessions-table
            for index from 0
            collect
            (list (car column)
                  (max (+ 2 (string-width (car column)))
                       (or (cl-loop for entry in entries
                                    maximize (string-width
                                              (aref (cadr entry) index)))
                           0))
                  t))))

(defun pimacs-list-sessions-refresh ()
  "Refresh the Pimacs sessions list."
  (interactive)
  (let ((entries (pimacs--list-sessions-entries)))
    (setq tabulated-list-format (pimacs--list-sessions-format entries)
          tabulated-list-entries entries)
    (tabulated-list-init-header)
    (tabulated-list-print t)))

(defun pimacs-list-sessions-visit ()
  "Visit the Pimacs session on the current line."
  (interactive)
  (when-let ((candidate (tabulated-list-get-id)))
    (pop-to-buffer (cdr candidate))))

(defun pimacs-list-sessions ()
  "List active Pimacs sessions in a tabulated buffer."
  (interactive)
  (let ((buffer (get-buffer-create "*Pimacs Sessions*")))
    (with-current-buffer buffer
      (pimacs-list-sessions-mode)
      (pimacs-list-sessions-refresh))
    (pop-to-buffer buffer)))

(defun pimacs-switch-session ()
  "Switch to another active Pimacs chat session."
  (interactive)
  (if-let ((candidate (pimacs--select-chat (pimacs--active-chat-candidates)
                                           "Switch to Pimacs session: ")))
      (pop-to-buffer (cdr candidate))
    (user-error "No active Pimacs sessions")))
(provide 'pimacs-session)

;;; pimacs-session.el ends here
