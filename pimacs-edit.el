;;; pimacs-edit.el --- Edit mode support -*- lexical-binding: t; -*-

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

;;; Code:

(require 'cl-lib)
(require 'compat)

(defvar-keymap pimacs-edit-mode-map
  "C-c C-c"                                #'pimacs-edit-finish
  "<remap> <server-edit>"                  #'pimacs-edit-finish
  "<remap> <evil-save-and-close>"          #'pimacs-edit-finish
  "<remap> <evil-save-modified-and-close>" #'pimacs-edit-finish
  "C-c C-k"                                #'pimacs-edit-cancel
  "<remap> <kill-buffer>"                  #'pimacs-edit-cancel
  "<remap> <ido-kill-buffer>"              #'pimacs-edit-cancel
  "<remap> <iswitchb-kill-buffer>"         #'pimacs-edit-cancel
  "<remap> <evil-quit>"                    #'pimacs-edit-cancel)

(defvar-local pimacs-edit--on-complete nil)
(defvar-local pimacs-edit--on-cancel nil)
(defvar-local pimacs-edit--original-text nil)
(defvar-local pimacs-edit--return-window nil)
(defvar-local pimacs-edit--chat-buffer nil)
(defvar-local pimacs-edit--buffers nil)

(define-derived-mode pimacs-edit-mode fundamental-mode "pimacs-edit"
  "Major mode for editing text via pimacs.

\\{pimacs-edit-mode-map}"
  (setq-local header-line-format
              (substitute-command-keys
               "Type \\[pimacs-edit-finish] to finish, \\[pimacs-edit-cancel] to cancel")))

(defun pimacs-edit-finish ()
  "Finish editing and pass the content to the callback."
  (interactive)
  (let ((text (buffer-string))
        (buffer (current-buffer))
        (callback pimacs-edit--on-complete)
        (window pimacs-edit--return-window))
    (kill-buffer buffer)
    (when (window-live-p window)
      (select-window window))
    (when callback
      (funcall callback text))))

(defun pimacs-edit-cancel ()
  "Cancel editing and discard the buffer."
  (interactive)
  (let ((buffer (current-buffer))
        (callback pimacs-edit--on-cancel)
        (window pimacs-edit--return-window))
    (kill-buffer buffer)
    (when (window-live-p window)
      (select-window window))
    (when callback
      (funcall callback))))

(defun pimacs-edit--unregister ()
  (let ((editor-buffer (current-buffer)))
    (when (buffer-live-p pimacs-edit--chat-buffer)
      (with-current-buffer pimacs-edit--chat-buffer
        (setq pimacs-edit--buffers
              (delq editor-buffer pimacs-edit--buffers))))))

(defun pimacs-edit--with-editor (on-complete on-cancel &optional text)
  (let ((buffer (generate-new-buffer "*pimacs-edit*"))
        (window (selected-window))
        (chat-buffer (current-buffer)))
    (with-current-buffer buffer
      (pimacs-edit-mode)
      (when text
        (insert text)
        (goto-char (point-min)))
      (setq pimacs-edit--on-complete on-complete
            pimacs-edit--on-cancel on-cancel
            pimacs-edit--return-window window
            pimacs-edit--chat-buffer chat-buffer)
      (add-hook 'kill-buffer-hook #'pimacs-edit--unregister nil t))
    (with-current-buffer chat-buffer
      (push buffer pimacs-edit--buffers))
    (pop-to-buffer buffer)))

(defun pimacs-edit--close-for-chat (chat-buffer)
  (let (buffers)
    (with-current-buffer chat-buffer
      (setq buffers pimacs-edit--buffers
            pimacs-edit--buffers nil))
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(provide 'pimacs-edit)

;;; pimacs-edit.el ends here
