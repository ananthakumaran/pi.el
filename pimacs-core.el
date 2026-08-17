;;; pimacs-core.el --- Core shared definitions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Anantha Kumaran.

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Core shared definitions used by both pimacs.el and pimacs-agent.el.

;;; Code:

(defgroup pimacs nil
  "Emacs client for Pi."
  :prefix "pimacs-"
  :group 'tools)

(require 'pimacs-utils)
(require 'project)
(require 'ansi-color)

(defcustom pimacs-use-ansi-colors t
  "Whether to render ANSI colors in widget and status output."
  :type 'boolean
  :group 'pimacs)

(defun pimacs--apply-ansi-colors (text)
  (if pimacs-use-ansi-colors
      (ansi-color-apply text)
    (ansi-color-filter-apply text)))

(pimacs--def-permanent-buffer-local pimacs--project-root nil)
(pimacs--def-permanent-buffer-local pimacs--project-key nil)
(pimacs--def-permanent-buffer-local pimacs--status-texts nil)

(defun pimacs--project-root ()
  (or
   pimacs--project-root
   (let ((project (project-current))
         (path default-directory))
     (if project
         (setq path (project-root project))
       (message "Couldn't find project root folder. Using '%s' as project root." default-directory))
     (let ((full-path (expand-file-name path)))
       (setq pimacs--project-root full-path)
       full-path))))

(defun pimacs--project-name ()
  (file-name-nondirectory (directory-file-name (pimacs--project-root))))

(defun pimacs--agent-buffer-name ()
  (format "*pimacs-agent:%s*" pimacs--project-key))

(provide 'pimacs-core)

;;; pimacs-core.el ends here
