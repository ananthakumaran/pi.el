;;; pimacs-markdown-table.el --- Markdown table rendering -*- lexical-binding: t; -*-

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

;; Markdown table rendering helpers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

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

(defun pimacs--markdown-table-header-face (text)
  (dotimes (index (length text))
    (unless (get-text-property index 'face text)
      (put-text-property index (1+ index) 'face 'pimacs-markdown-table-header-face text)))
  text)

(defun pimacs--markdown-table-propertize-face (text face)
  (when (> (length text) 0)
    (put-text-property 0 (length text) 'face face text))
  text)

(defun pimacs--markdown-table-space (width)
  (propertize " " 'display `(space :width (,width))))

(defun pimacs--markdown-table-pad (text width alignment)
  (let ((padding (max 0 (- width (string-pixel-width text)))))
    (pcase alignment
      ('right (concat (pimacs--markdown-table-space padding) text))
      ('center (let ((left (floor (/ padding 2))))
                 (concat (pimacs--markdown-table-space left)
                         text
                         (pimacs--markdown-table-space (- padding left)))))
      (_ (concat text (pimacs--markdown-table-space padding))))))

(defun pimacs--markdown-table-rule (width character)
  (let* ((character (pimacs--markdown-table-propertize-face
                     character 'pimacs-markdown-table-border-face))
         (character-width (string-pixel-width character))
         (count (floor (/ width character-width)))
         (remainder (- width (* count character-width))))
    (concat (apply #'concat (make-list count character))
            (pimacs--markdown-table-space remainder))))

(defun pimacs--markdown-table-max-word-width (line)
  (cl-loop for word in (split-string line "[[:space:]]+" t)
           maximize (string-pixel-width word)
           into width
           finally return (or width 0)))

(defun pimacs--markdown-table-width-in-columns (width)
  (max 1 (floor (/ width (string-pixel-width " ")))))

(defun pimacs--markdown-table-wrap-line (text width)
  (if (string-empty-p text)
      (list text)
    (split-string
     (string-fill text (pimacs--markdown-table-width-in-columns width))
     "\n")))

(defun pimacs--markdown-table-line-hard-minimum-width (line)
  (max 1
       (min (string-pixel-width line)
            (max (* 4 (string-pixel-width " "))
                 (pimacs--markdown-table-max-word-width line)))))

(defun pimacs--markdown-table-line-preferred-minimum-width (line)
  (max (pimacs--markdown-table-line-hard-minimum-width line)
       (min (* 20 (string-pixel-width " "))
            (pimacs--markdown-table-max-word-width line))))

(defun pimacs--markdown-table-wrap-cell (cell width)
  (apply #'append
         (mapcar (lambda (line)
                   (pimacs--markdown-table-wrap-line line width))
                 cell)))

(defun pimacs--markdown-table-wrap-row (row widths)
  (cl-loop for width in widths
           for cell = (or (pop row) '(""))
           collect (pimacs--markdown-table-wrap-cell cell width)))

(defun pimacs--markdown-table-fit-widths (widths minimums maximum)
  (let ((width-total (apply #'+ widths))
        (minimum-total (apply #'+ minimums)))
    (cond
     ((<= width-total maximum) (copy-sequence widths))
     ((<= maximum minimum-total) (copy-sequence minimums))
     (t
      (let ((extra (- maximum minimum-total))
            (flex-total (- width-total minimum-total))
            (cumulative-flex 0)
            (allocated 0))
        (cl-mapcar
         (lambda (width minimum)
           (setq cumulative-flex (+ cumulative-flex (- width minimum)))
           (let ((cumulative-allocation
                  (floor (/ (* extra cumulative-flex) flex-total))))
             (prog1 (+ minimum (- cumulative-allocation allocated))
               (setq allocated cumulative-allocation))))
         widths minimums))))))

(defun pimacs--markdown-table-render (header-data alignments row-data final-newline-p)
  (let* ((column-count (length header-data))
         (vertical (pimacs--markdown-table-propertize-face
                    (if pimacs-markdown-use-unicode-tables "│" "|")
                    'pimacs-markdown-table-border-face))
         (horizontal (if pimacs-markdown-use-unicode-tables "─" "-"))
         (intersection (pimacs--markdown-table-propertize-face
                        (if pimacs-markdown-use-unicode-tables "┼" "+")
                        'pimacs-markdown-table-border-face))
         (left (pimacs--markdown-table-propertize-face
                (if pimacs-markdown-use-unicode-tables "├" "+")
                'pimacs-markdown-table-border-face))
         (right (pimacs--markdown-table-propertize-face
                 (if pimacs-markdown-use-unicode-tables "┤" "+")
                 'pimacs-markdown-table-border-face))
         (margin-width (string-pixel-width " "))
         (margin (pimacs--markdown-table-space margin-width))
         (header-data (mapcar (lambda (cell)
                                (mapcar (lambda (line)
                                          (pimacs--markdown-table-header-face
                                           (copy-sequence line)))
                                        cell))
                              header-data))
         (all-rows (cons header-data row-data))
         (hard-minimums
          (cl-loop for column below column-count
                   collect (cl-loop for row in all-rows
                                    maximize
                                    (cl-loop for line in (or (nth column row) '(""))
                                             maximize
                                             (pimacs--markdown-table-line-hard-minimum-width
                                              line)))))
         (preferred-minimums
          (cl-loop for column below column-count
                   collect
                   (max
                    (cl-loop for line in (or (nth column header-data) '(""))
                             maximize
                             (min (* 20 (string-pixel-width " "))
                                  (string-pixel-width line)))
                    (or
                     (cl-loop for row in row-data
                              maximize
                              (cl-loop for line in (or (nth column row) '(""))
                                       maximize
                                       (pimacs--markdown-table-line-preferred-minimum-width
                                        line)))
                     0))))
         (widths
          (cl-loop for column below column-count
                   collect (cl-loop for row in all-rows
                                    maximize
                                    (cl-loop for line in (or (nth column row) '(""))
                                             maximize
                                             (string-pixel-width line)))))
         (horizontal-width
          (string-pixel-width
           (pimacs--markdown-table-propertize-face
            horizontal 'pimacs-markdown-table-border-face)))
         (hard-minimum-units
          (mapcar (lambda (width)
                    (ceiling (/ (+ width (* 2 margin-width)) horizontal-width)))
                  hard-minimums))
         (preferred-minimum-units
          (mapcar (lambda (width)
                    (ceiling (/ (+ width (* 2 margin-width)) horizontal-width)))
                  preferred-minimums))
         (width-units
          (mapcar (lambda (width)
                    (ceiling (/ (+ width (* 2 margin-width)) horizontal-width)))
                  widths))
         (available-units
          (floor (/ (- (floor (* 0.9 (window-width nil t)))
                       (* (1+ column-count) (string-pixel-width vertical)))
                    horizontal-width)))
         (width-units
          (if (<= (apply #'+ preferred-minimum-units) available-units)
              (pimacs--markdown-table-fit-widths
               width-units preferred-minimum-units available-units)
            (pimacs--markdown-table-fit-widths
             preferred-minimum-units hard-minimum-units available-units)))
         (widths
          (cl-mapcar (lambda (units minimum)
                       (max minimum
                            (- (* units horizontal-width) (* 2 margin-width))))
                     width-units hard-minimums))
         (wrapped-header-data (pimacs--markdown-table-wrap-row header-data widths))
         (wrapped-row-data (mapcar (lambda (row)
                                     (pimacs--markdown-table-wrap-row row widths))
                                   row-data))
         output)
    (cl-labels
        ((border ()
           (concat left
                   (mapconcat (lambda (width)
                                (pimacs--markdown-table-rule
                                 (+ width (* 2 margin-width)) horizontal))
                              widths intersection)
                   right))
         (render-row (row headerp)
           (let ((height (apply #'max (mapcar #'length row))))
             (cl-loop for line below height
                      collect
                      (let (chunks)
                        (dotimes (column column-count)
                          (let* ((cell (nth column row))
                                 (text (copy-sequence (or (nth line cell) "")))
                                 (padded (pimacs--markdown-table-pad
                                          text (nth column widths)
                                          (nth column alignments))))
                            (when headerp
                              (setq padded (pimacs--markdown-table-header-face padded)))
                            (push vertical chunks)
                            (push margin chunks)
                            (push padded chunks)
                            (push margin chunks)))
                        (push vertical chunks)
                        (apply #'concat (nreverse chunks)))))))
      (setq output (append (render-row wrapped-header-data t) (list (border))))
      (dolist (row wrapped-row-data)
        (setq output (append output (render-row row nil))))
      (concat (mapconcat #'identity output "\n")
              (if final-newline-p "\n" "")))))

(provide 'pimacs-markdown-table)

;;; pimacs-markdown-table.el ends here
