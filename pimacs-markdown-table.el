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
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

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

(defun pimacs--markdown-table-wrap-line (text width)
  (if (string-empty-p text)
      (list text)
    (let ((width (max 1 width))
          (length (length text))
          (start 0)
          lines)
      (while (< start length)
        (while (and (< start length)
                    (eq (char-syntax (aref text start)) ?\ ))
          (setq start (1+ start)))
        (when (< start length)
          (let ((end start)
                last-break)
            (while (and (< end length)
                        (<= (string-pixel-width (substring text start (1+ end))) width))
              (when (eq (char-syntax (aref text end)) ?\ )
                (setq last-break end))
              (setq end (1+ end)))
            (if (= end length)
                (progn
                  (push (substring text start end) lines)
                  (setq start end))
              (let ((break (or last-break end)))
                (when (= break start)
                  (setq break (1+ start)))
                (push (substring text start break) lines)
                (setq start break))))))
      (nreverse lines))))

(defun pimacs--markdown-table-line-minimum-width (line)
  (let ((width 1))
    (dotimes (index (length line))
      (setq width (max width
                       (string-pixel-width (substring line index (1+ index))))))
    width))

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
  (setq widths (copy-sequence widths))
  (while (and (> (apply #'+ widths) maximum)
              (cl-loop for width in widths
                       for minimum in minimums
                       thereis (> width minimum)))
    (let* ((largest (cl-loop for width in widths
                             for minimum in minimums
                             when (> width minimum)
                             maximize width))
           (indexes (cl-loop for width in widths
                             for minimum in minimums
                             for index from 0
                             when (and (= width largest) (> width minimum))
                             collect index))
           (excess (- (apply #'+ widths) maximum))
           (reduction (max 1 (ceiling (/ excess (length indexes))))))
      (dolist (index indexes)
        (setf (nth index widths)
              (max (nth index minimums)
                   (- (nth index widths) reduction))))))
  widths)

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
         (minimums (cl-loop for column below column-count
                            collect (cl-loop for row in all-rows
                                             maximize (cl-loop for line in (or (nth column row)
                                                                               '(""))
                                                               maximize (pimacs--markdown-table-line-minimum-width
                                                                         line)))))
         (widths (cl-loop for column below column-count
                          collect (cl-loop for row in all-rows
                                           maximize (cl-loop for line in (or (nth column row)
                                                                             '(""))
                                                             maximize (string-pixel-width line)))))
         (horizontal-width
          (string-pixel-width
           (pimacs--markdown-table-propertize-face
            horizontal 'pimacs-markdown-table-border-face)))
         (minimum-units (mapcar (lambda (width)
                                  (ceiling (/ (+ width (* 2 margin-width))
                                              horizontal-width)))
                                minimums))
         (width-units (mapcar (lambda (width)
                                (ceiling (/ (+ width (* 2 margin-width))
                                            horizontal-width)))
                              widths))
         (available-units
          (max (apply #'+ minimum-units)
               (floor (/ (- (floor (* 0.9 (window-width nil t)))
                            (* (1+ column-count)
                               (string-pixel-width vertical)))
                         horizontal-width))))
         (width-units (pimacs--markdown-table-fit-widths
                       width-units minimum-units available-units))
         (widths (cl-mapcar (lambda (units minimum)
                              (max minimum
                                   (- (* units horizontal-width)
                                      (* 2 margin-width))))
                            width-units minimums))
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
