;;; pimacs-agent.el --- Agent (RPC) support -*- lexical-binding: t; -*-

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

;;; Commentary:

;; RPC client for communicating with the Pi coding agent process.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pimacs-utils)
(require 'pimacs-core)

(defvar pimacs--minimum-version "0.82.0"
  "The minimum supported Pi agent version.")

(defcustom pimacs-sync-request-timeout 2
  "The number of seconds to wait for a sync response."
  :type 'integer
  :group 'pimacs)

(defcustom pimacs-executable "pi"
  "Pi command executable name."
  :type 'string
  :group 'pimacs)

(defcustom pimacs-process-environment '()
  "List of extra environment variables to use when starting pimacs."
  :type '(repeat string)
  :group 'pimacs)

(defcustom pimacs-flags '()
  "List of additional flags to provide when starting pimacs."
  :type '(repeat string)
  :group 'pimacs)

(defcustom pimacs-log-rpc nil
  "When non-nil, log all RPC JSON to `pimacs-log-rpc-file'."
  :type 'boolean
  :group 'pimacs)

(defcustom pimacs-log-rpc-file (expand-file-name "pimacs.el.log" (temporary-file-directory))
  "File to write RPC JSON log entries to."
  :type 'file
  :group 'pimacs)

(defun pimacs--maybe-log-rpc (type json)
  (when pimacs-log-rpc
    (write-region (concat "{\"type\": \"" type "\", \"message\": " json "}\n") nil pimacs-log-rpc-file t 'inhibit-message)))

(defun pimacs--response-success-p (response)
  (and response
       (plist-get response :success)
       (not (eq (plist-get response :success) 'json-false))))

(defvar pimacs--agents (make-hash-table :test 'equal))
(defvar pimacs--response-callbacks (make-hash-table :test 'equal))

(cl-defstruct pimacs-response-callback
  process buffer function)

(defvar pimacs--event-listeners (make-hash-table :test 'equal))

(defvar pimacs--request-counter 0)

(defun pimacs--current-agent ()
  (gethash pimacs--project-key pimacs--agents))

(defun pimacs--next-request-id ()
  (number-to-string (cl-incf pimacs--request-counter)))

;;; Agent

(defun pimacs--dispatch-response (process response)
  (let* ((request-id (plist-get response :id))
         (callback (gethash request-id pimacs--response-callbacks)))
    (when (and callback
               (eq process (pimacs-response-callback-process callback)))
      (let ((buffer (pimacs-response-callback-buffer callback))
            (fn (pimacs-response-callback-function callback)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (funcall fn response))))
      (remhash request-id pimacs--response-callbacks))))

(defun pimacs--dispatch-event (event)
  (let ((key pimacs--project-key))
    (when-let (all-listener (gethash (cons key t) pimacs--event-listeners))
      (with-current-buffer (car all-listener)
        (apply (cdr all-listener) (list event))))
    (when-let (listener (gethash (cons key (plist-get event :type)) pimacs--event-listeners))
      (with-current-buffer (car listener)
        (apply (cdr listener) (list event))))))

(defun pimacs--set-event-listener (name listener)
  "Set event listener NAME for all events.  LISTENER is the callback."
  (puthash (cons pimacs--project-key name) (cons (current-buffer) listener) pimacs--event-listeners))

(defun pimacs--dispatch (process response)
  (cl-case (intern (plist-get response :type))
    ((response) (pimacs--dispatch-response process response))
    (t (pimacs--dispatch-event response))))

(defun pimacs--send-command (type args &optional callback)
  (let ((agent (pimacs--current-agent)))
    (unless agent
      (error "Agent does not exist.  Run M-x pimacs-restart-chat to start it again"))

    (let* ((request-id (pimacs--next-request-id))
           (command (pimacs--plist-merge (list :id request-id :type type) args))
           (encoded-command (pimacs--json-encode command))
           (payload (concat encoded-command "\n")))
      (pimacs--maybe-log-rpc "input" encoded-command)
      (process-send-string agent payload)
      (when callback
        (puthash request-id
                 (make-pimacs-response-callback :process agent
                                                :buffer (current-buffer)
                                                :function callback)
                 pimacs--response-callbacks))
      request-id)))

(defun pimacs--send-command-sync (name args)
  (let* ((start-time (current-time))
         (response nil))
    (pimacs--send-command name args (lambda (resp) (setq response resp)))
    (while (not response)
      (accept-process-output nil 0.01)
      (when (> (pimacs--seconds-elapsed-since start-time) pimacs-sync-request-timeout)
        (error "Sync request timed out %s" name)))
    response))

(defun pimacs--net-sentinel (process message)
  (let ((project-name (process-get process 'project-name)))
    (message "(%s) pimacs exits: %s." project-name (string-trim message))
    (ignore-errors
      (kill-buffer (process-buffer process)))
    (pimacs--cleanup-agent process)))

(defun pimacs--net-filter (process data)
  (with-current-buffer (process-buffer process)
    (goto-char (point-max))
    (insert (format "%s" data)))
  (pimacs--decode-response process))

(defun pimacs--enough-response-p ()
  (goto-char (point-min))
  (save-excursion
    (when (search-forward "{")
      (search-forward "\n" nil t))))

(defun pimacs--decode-response (process)
  (with-current-buffer (process-buffer process)
    (when (pimacs--enough-response-p)
      (search-forward "{")
      (backward-char 1)
      (let* ((raw-start (point))
             (response (pimacs--json-read-object)))
        (when pimacs-log-rpc
          (pimacs--maybe-log-rpc "output" (buffer-substring-no-properties raw-start (point))))
        (delete-region (point-min) (point))
        (when response
          (ignore-error quit
            (pimacs--dispatch process response))))
      (when (>= (buffer-size) 16)
        (pimacs--decode-response process)))))

(defun pimacs--agent-version ()
  (with-temp-buffer
    (let* ((process-arguments (append pimacs-flags '("--version")))
           (command-line (mapconcat #'shell-quote-argument (cons pimacs-executable process-arguments) " "))
           (exit-code (apply #'call-process pimacs-executable nil (current-buffer) nil process-arguments)))
      (if (zerop exit-code)
          (string-trim (buffer-string))
        (let ((output (buffer-string)))
          (with-current-buffer (get-buffer-create "*pimacs-version-error*")
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (format "Failed to run `%s`.\n" command-line))
              (insert (format "\nExit code: %d\n" exit-code))
              (insert (format "\nOutput:\n%s" output)))
            (special-mode)
            (goto-char (point-min))
            (pop-to-buffer (current-buffer)))
          (error "Failed to run `%s' (exit code %d)" command-line exit-code))))))

(defun pimacs--check-agent-version (version)
  (unless (version-list-<= (version-to-list pimacs--minimum-version)
                           (version-to-list version))
    (error "Pi agent version %s is older than minimum supported version %s"
           version pimacs--minimum-version)))

(defun pimacs--start-agent (key)
  (when (pimacs--current-agent)
    (error "Agent already exist"))

  (let* ((default-directory (pimacs--project-root))
         (version (pimacs--agent-version)))
    (pimacs--check-agent-version version)
    (message "(%s) Starting pimacs version %s..." (pimacs--project-name) version)
    (let* ((process-environment (append pimacs-process-environment process-environment))
           (buf (generate-new-buffer (pimacs--agent-buffer-name)))
           ;; Use a pipe to communicate with the subprocess. This fixes a hang
           ;; when a >1k message is sent on macOS.
           (process-connection-type nil)
           (process-arguments (append pimacs-flags '("--mode" "rpc")))
           (process
            (apply #'start-file-process "pi" buf pimacs-executable process-arguments)))
      (set-process-coding-system process 'utf-8-unix 'utf-8-unix)
      (set-process-filter process #'pimacs--net-filter)
      (set-process-sentinel process #'pimacs--net-sentinel)
      (set-process-query-on-exit-flag process nil)
      (with-current-buffer (process-buffer process)
        (buffer-disable-undo)
        (setq-local pimacs--project-key key))
      (process-put process 'project-key key)
      (process-put process 'project-root default-directory)
      (process-put process 'project-name (pimacs--project-name))
      (puthash key process pimacs--agents)
      (message "(%s) pimacs agent started successfully." (pimacs--project-name)))))

(defun pimacs--agent-add-cleanup (process fn)
  "Register FN as a cleanup callback for PROCESS.
Cleanup callbacks are run when the agent process exits."
  (push fn (process-get process 'pimacs--agent-cleanup-fns)))

(defun pimacs--agent-remove-cleanup (process fn)
  "Remove FN from the cleanup callbacks of PROCESS."
  (let ((cleanup-fns (process-get process 'pimacs--agent-cleanup-fns)))
    (process-put process 'pimacs--agent-cleanup-fns
                 (delq fn cleanup-fns))))

(defun pimacs--cleanup-agent (process)
  "Run cleanup callbacks registered on PROCESS and remove from agents table."
  (let ((project-key (process-get process 'project-key)))
    (pimacs--hash-remove-if
     (lambda (_ callback)
       (eq (pimacs-response-callback-process callback) process))
     pimacs--response-callbacks)
    (when (eq (gethash project-key pimacs--agents) process)
      (remhash project-key pimacs--agents))
    (dolist (fn (process-get process 'pimacs--agent-cleanup-fns))
      (ignore-errors (funcall fn)))
    (process-put process 'pimacs--agent-cleanup-fns nil)))

;;; Utility commands

(defun pimacs--kill-agent (&optional skip-cleanup-fn)
  "Kill the agent process.
When SKIP-CLEANUP-FN is non-nil, that cleanup callback is
removed before killing, so it won't run when the process exits."
  (when-let (agent (pimacs--current-agent))
    (when skip-cleanup-fn
      (pimacs--agent-remove-cleanup agent skip-cleanup-fn))
    (delete-process agent)))

(provide 'pimacs-agent)

;;; pimacs-agent.el ends here
