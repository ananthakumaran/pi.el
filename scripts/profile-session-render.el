;;; profile-session-render.el --- Profile session rendering -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'profiler)
(require 'pimacs)
(require 'pimacs-markdown)

(defconst pimacs-render-profile--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun pimacs-render-profile--read-entries (session-file)
  (with-temp-buffer
    (let ((status (call-process (expand-file-name "get_entries" pimacs-render-profile--directory)
                                nil t nil session-file)))
      (unless (zerop status)
        (error "get_entries failed for %s: %s" session-file (buffer-string))))
    (goto-char (point-min))
    (plist-get (plist-get (pimacs--json-read-object) :data) :entries)))

(defun pimacs-render-profile--create-buffer (index)
  (let ((buffer (generate-new-buffer (format " *pimacs-render-profile-%d*" index))))
    (with-current-buffer buffer
      (setq-local pimacs--project-key (format "pimacs-render-profile-%d" index)
                  pimacs--project-root default-directory)
      (cl-letf (((symbol-function 'pimacs--fetch-commands) #'ignore)
                ((symbol-function 'pimacs--register-agent-cleanup) #'ignore)
                ((symbol-function 'pimacs--register-event-listeners) #'ignore)
                ((symbol-function 'pimacs--update-header-line) #'ignore))
        (pimacs-chat-mode)))
    buffer))

(defun pimacs-render-profile--render (entries)
  (pimacs--widget-save-excursion
    (pimacs--render-session-entries entries)))

(defun pimacs-render-profile--print-report ()
  (profiler-report)
  (when-let ((buffer (seq-find (lambda (buffer)
                                 (string-prefix-p "*CPU-Profiler-Report" (buffer-name buffer)))
                               (buffer-list))))
    (let (report)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-min))
          (while (not (eobp))
            (when (get-text-property (point) 'calltree)
              (profiler-report-expand-entry t))
            (forward-line 1)))
        (setq report (buffer-substring-no-properties (point-min) (point-max))))
      (princ "CPU profile (selected functions):\n")
      (dolist (line (seq-filter (lambda (line)
                                  (and (string-match-p "pimacs\\|font-lock\\|markdown\\|Automatic GC\\|parse-partial-sexp" line)
                                       (string-match "^[[:space:]]*[0-9]+[[:space:]]+\\([0-9]+\\)%" line)
                                       (>= (string-to-number (match-string 1 line)) 1)))
                                (split-string report "\n" t)))
        (princ (concat line "\n")))
      (kill-buffer buffer))))

(defun pimacs-render-profile--measure-render (entries)
  (let ((buffer (pimacs-render-profile--create-buffer 0)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((start (current-time)))
            (pimacs-render-profile--render entries)
            (float-time (time-subtract (current-time) start))))
      (kill-buffer buffer))))

(defun pimacs-render-profile--profile-entries (session-file entries)
  (let* ((runs 10)
         (warmup-buffer (pimacs-render-profile--create-buffer 0))
         (buffers (cl-loop for index from 1 to runs
                           collect (pimacs-render-profile--create-buffer index)))
         times)
    (unwind-protect
        (progn
          (with-current-buffer warmup-buffer
            (pimacs-render-profile--render entries))
          (profiler-start 'cpu)
          (unwind-protect
              (dolist (buffer buffers)
                (with-current-buffer buffer
                  (let ((start (current-time)))
                    (pimacs-render-profile--render entries)
                    (push (float-time (time-subtract (current-time) start)) times))))
            (profiler-stop))
          (setq times (nreverse times))
          (princ (format "Session: %s\nEntries: %d\nRuns: %d\n" session-file (length entries) runs))
          (princ (format "Markdown renderer: %S\nTree-sitter: available=%s markdown=%s markdown-inline=%s\n"
                         pimacs-markdown-renderer
                         (treesit-available-p)
                         (treesit-language-available-p 'markdown)
                         (treesit-language-available-p 'markdown-inline)))
          (princ (format "Render time: min %.3fs, max %.3fs, average %.3fs\n\n"
                         (apply #'min times)
                         (apply #'max times)
                         (/ (apply #'+ times) runs)))
          (pimacs-render-profile--print-report))
      (dolist (buffer (cons warmup-buffer buffers))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(defun pimacs-render-profile--run-file (session-file)
  (pimacs-render-profile--profile-entries
   session-file
   (pimacs-render-profile--read-entries session-file)))

(defun pimacs-render-profile--run-directory (directory)
  (let (results errors)
    (dolist (session-file (sort (directory-files directory t "\\.jsonl\\'") #'string<))
      (condition-case err
          (let ((entries (pimacs-render-profile--read-entries session-file)))
            (push (list session-file
                        (length entries)
                        (pimacs-render-profile--measure-render entries))
                  results))
        (error
         (push (cons session-file (error-message-string err)) errors))))
    (setq results (sort results (lambda (a b) (> (nth 2 a) (nth 2 b)))))
    (when (null results)
      (error "No renderable session files found in %s" directory))
    (let ((times (mapcar (lambda (result) (nth 2 result)) results))
          (entry-count (apply #'+ (mapcar (lambda (result) (nth 1 result)) results))))
      (princ (format "Directory: %s\nSessions: %d\nEntries: %d\n" directory (length results) entry-count))
      (princ (format "Render time: min %.3fs, max %.3fs, average %.3fs\n\n"
                     (apply #'min times)
                     (apply #'max times)
                     (/ (apply #'+ times) (length times)))))
    (dolist (result (seq-take results 10))
      (princ (format "%.3fs  %6d entries  %s\n"
                     (nth 2 result)
                     (nth 1 result)
                     (file-name-nondirectory (car result)))))
    (when errors
      (princ (format "\nSkipped %d session files\n" (length errors))))
    (princ "\nCPU profile for the slowest session:\n\n")
    (pimacs-render-profile--run-file (caar results))))

(defun pimacs-render-profile--run (session-path)
  (cond
   ((file-regular-p session-path)
    (pimacs-render-profile--run-file session-path))
   ((file-directory-p session-path)
    (pimacs-render-profile--run-directory session-path))
   (t
    (error "Not a session file or directory: %s" session-path))))

(defun pimacs-render-profile--command-line ()
  (if-let ((session-path (getenv "PIMACS_RENDER_PROFILE_SESSION_FILE")))
      (let ((pimacs-markdown-renderer #'pimacs--render-markdown)
            (pimacs-thinking-renderer #'pimacs--render-thinking-markdown))
        (unless (pimacs--markdown-available-p)
          (error "Tree-sitter Markdown and Markdown Inline grammars are required"))
        (pimacs-render-profile--run (expand-file-name session-path)))
    (error "PIMACS_RENDER_PROFILE_SESSION_FILE is required")))

;;; profile-session-render.el ends here
