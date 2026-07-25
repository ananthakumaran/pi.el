;;; pimacs-integration-tests --- This file contains automated integration tests for pimacs.el -*- lexical-binding: t; -*-

;;; Code:

;; Test setup:

(require 'cl-lib)
(require 'ert)

;; development only packages, not declared as a package-dependency
(package-initialize)

(require 'undercover)
(undercover)

(require 'pimacs)

(defun pimacs-project-try-project (dir)
  (let ((root (locate-dominating-file dir ".project")))
    (when root
      (cons 'transient root))))

(add-hook 'project-find-functions #'pimacs-project-try-project)

(defconst pimacs-integration-directory
  (file-name-directory
   (or (and load-file-name
            (file-truename load-file-name))
       (and buffer-file-name
            (file-truename buffer-file-name)))))

(defconst pimacs-tape-directory (expand-file-name "fixture/tapes" pimacs-integration-directory))
(defconst pimacs-project-directory (expand-file-name "project" pimacs-integration-directory))
(defconst pimacs-project-agent-directory (expand-file-name "project/agent" pimacs-integration-directory))

(defun pimacs-fixture-mode ()
  (or (getenv "FIXTURE_MODE") "replay"))

(defconst pimacs-silenced-integration-message-patterns
  '("^(.*) Starting pimacs version .+\.\.\.$"
    "^(.*) pimacs agent started successfully\.$"
    "^(.*) pimacs exits: killed\.$"
    "^Copied last assistant message to clipboard\.$"))

(defmacro pimacs-with-silenced-integration-messages (&rest body)
  (declare (indent 0))
  `(let* ((message-fn (symbol-function 'message))
          (settings-file (expand-file-name "settings.json" pimacs-project-agent-directory))
          (original-settings (with-temp-buffer
                               (insert-file-contents settings-file)
                               (buffer-string))))
     (unwind-protect
         (cl-letf (((symbol-function 'message)
                    (lambda (format-string &rest args)
                      (let ((text (apply #'format-message format-string args)))
                        (unless (cl-some (lambda (pattern)
                                           (string-match-p pattern text))
                                         pimacs-silenced-integration-message-patterns)
                          (funcall message-fn "%s" text))))))
           ,@body)
       ;; Restore settings file to original content
       (write-region original-settings nil settings-file nil 'silent))))

(defmacro pimacs-with-integration-project (scenario &rest body)
  (declare (indent 1))
  `(pimacs-with-silenced-integration-messages
     (let* ((default-directory pimacs-project-directory)
            (pimacs-process-environment (list
                                         (concat "FIXTURE_SCENARIO=" ,scenario)
                                         (concat "PI_CODING_AGENT_DIR=" pimacs-project-agent-directory)
                                         (concat "FIXTURE_MODE=" (pimacs-fixture-mode))))
            (pimacs-flags (list "--tools" "read,bash,edit,write,grep,find,ls" "--extension" (expand-file-name "fixture" pimacs-integration-directory))))
       (let ((sessions-dir (expand-file-name "sessions" pimacs-project-agent-directory)))
         (when (file-exists-p sessions-dir)
           (delete-directory sessions-dir t)
           (make-directory sessions-dir)))
       (pimacs-chat)
       (sleep-for 2)
       ,@body
       (pimacs-drain-process-output)
       (pimacs--with-chat-buffer
         (pimacs--force-update-header-line)
         (pimacs-check-tape ,scenario ".txt"
                            (buffer-substring (point-min) (point-max)))
         (pimacs-check-tape
          ,scenario "-header.txt"
          (replace-regexp-in-string
           "%%" "%"
           (pimacs--format-state-line pimacs-header-line-format)
           t t)))

       (pimacs-quit-chat))))

(defvar pimacs-settle-time (if (getenv "CI") 1 0.1))
(defvar pimacs-poll-interval (if (getenv "CI") 0.5 0.05))

(defun pimacs-drain-process-output (&optional timeout)
  (let* ((timeout (or timeout 120))
         (start (current-time))
         (buffer (pimacs--current-chat)))
    (sleep-for pimacs-settle-time)
    (when buffer
      (with-current-buffer buffer
        (while (and pimacs--agent-state
                    (< (time-to-seconds (time-subtract (current-time) start)) timeout))
          (accept-process-output nil pimacs-poll-interval))))
    (sleep-for pimacs-settle-time)))

(defmacro pimacs-with-editor-buffer (&rest body)
  (declare (indent 0))
  `(progn
     (pimacs-drain-process-output)
     (let ((buffer (get-buffer "*pimacs-edit*")))
       (when buffer
         (with-current-buffer buffer
           ,@body)))
     (pimacs-drain-process-output)))

(defun pimacs-normalize-buffer-text (text)
  (let ((session_dir (concat "--" (replace-regexp-in-string "/" "-"
                                                            (substring pimacs-project-directory 1))
                             "--")))
    (->> text
         (replace-regexp-in-string (regexp-quote pimacs-project-directory) "PROJECT_DIR")
         (replace-regexp-in-string (regexp-quote session_dir) "SESSION_DIR")
         (replace-regexp-in-string
          (concat (regexp-quote (file-name-as-directory temporary-file-directory))
                  "pimacs-parent-[^/]+/")
          "PARENT_DIR/")
         (replace-regexp-in-string "\\b[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}" "UUID")
         (replace-regexp-in-string "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}-[0-9]\\{2\\}-[0-9]\\{2\\}-[0-9]\\{3\\}Z" "TIMESTAMP"))))

(defun pimacs--force-update-header-line ()
  (let ((state-response (pimacs--send-command-sync "get_state" '()))
        (stats-response (pimacs--send-command-sync "get_session_stats" '())))
    (when (and (pimacs--response-success-p state-response)
               (pimacs--response-success-p stats-response))
      (pimacs--set-header-line-state (plist-get state-response :data)
                                     (plist-get stats-response :data)))))

(defun pimacs-check-tape (scenario suffix text)
  (let* ((tape-file (expand-file-name (concat scenario suffix) pimacs-tape-directory))
         (current-text (pimacs-normalize-buffer-text text))
         (fixture-mode (pimacs-fixture-mode)))
    (if (or (not (file-exists-p tape-file))
            (string= fixture-mode "record"))
        (write-region current-text nil tape-file nil 'silent)
      (let ((expected (pimacs-normalize-buffer-text
                       (with-temp-buffer
                         (insert-file-contents tape-file)
                         (buffer-string)))))
        (unless (string= current-text expected)
          (let ((temp-file (make-temp-file "pimacs-tape-")))
            (unwind-protect
                (progn
                  (write-region current-text nil temp-file nil 'silent)
                  (with-temp-buffer
                    (call-process "diff" nil (current-buffer) nil "-u" tape-file temp-file)
                    (message "Tape mismatch for %s:\n%s" scenario (buffer-string))
                    (ert-fail (format "Tape mismatch for %s" scenario))))
              (delete-file temp-file))))))))

(defun pimacs-send-prompt-and-wait (prompt)
  (pimacs-send-prompt prompt)
  (pimacs-drain-process-output))

(defun pimacs-assert-prompt (buffer expected)
  (with-current-buffer buffer
    (should (equal (widget-value pimacs--prompt-widget) expected))))

(defmacro pimacs-with-minibuffer-input (input &rest body)
  (declare (indent 1))
  `(let ((executing-kbd-macro t)
         (completion-styles '(flex))
         (unread-command-events
          (append (listify-key-sequence ,input)
                  unread-command-events)))
     ,@body))

(ert-deftest pimacs-basics ()
  (pimacs-with-integration-project "basics"
    (pimacs-send-prompt-and-wait "list files")
    (pimacs-send-prompt-and-wait "grep for sample")
    (pimacs-send-prompt-and-wait "create a new filed name test.txt")
    (pimacs-send-prompt-and-wait "delete test.txt")
    (pimacs-send-prompt-and-wait "find files with json extension")
    (pimacs-send-prompt-and-wait "read utils.py file")
    (pimacs-send-prompt-and-wait "create test.txt with some text")
    (pimacs-send-prompt-and-wait "remove the 3rd line using edit tool")
    (pimacs-send-prompt-and-wait "delete text.txt")
    (pimacs-send-prompt-and-wait "/export /tmp/pimacs-session.html")))

(ert-deftest pimacs-slash ()
  (pimacs-with-integration-project "slash"
    (setq-local pimacs-header-line-format
                '("model=" :model
                  " tools=" (lambda (state)
                              (format "%s" (pimacs--plist-get state :sessionStats :toolCalls)))
                  :spacer
                  "provider=" :provider))
    (pimacs-send-prompt-and-wait "/new")
    (pimacs-send-prompt-and-wait "/name session1")
    (pimacs-send-prompt-and-wait "/session")
    (pimacs-send-prompt-and-wait "hello")
    (pimacs-send-prompt-and-wait "/copy")
    (pimacs-with-minibuffer-input "n"
      (pimacs-send-prompt-and-wait "/set-auto-compaction"))
    (pimacs-with-minibuffer-input "y"
      (pimacs-send-prompt-and-wait "/set-auto-compaction"))
    (pimacs-with-minibuffer-input "(fixture) qwen3.5:0.8b"
      (pimacs-send-prompt-and-wait "/model"))
    (pimacs-with-minibuffer-input "minimal (Very brief reasoning ~1k tokens)"
      (pimacs-send-prompt-and-wait "/set-thinking-level"))
    (pimacs-send-prompt-and-wait "/cycle-thinking-level")
    (pimacs-with-minibuffer-input "n"
      (pimacs-send-prompt-and-wait "/set-auto-retry"))
    (pimacs-with-minibuffer-input "y"
      (pimacs-send-prompt-and-wait "/set-auto-retry"))
    (pimacs-with-minibuffer-input "One at a time"
      (pimacs-send-prompt-and-wait "/set-steering-mode"))
    (pimacs-with-minibuffer-input "All"
      (pimacs-send-prompt-and-wait "/set-follow-up-mode"))))

(ert-deftest pimacs-session ()
  (pimacs-with-integration-project "session"
    (setq-local pimacs-header-line-format
                '("session=" :session_name
                  " messages=" :message_count "/" :pending_message_count
                  :spacer
                  "total=" :total_messages))
    (pimacs-send-prompt-and-wait "/new")
    (pimacs-send-prompt-and-wait "/name test-session")
    (pimacs-send-prompt-and-wait "/session")
    (pimacs-send-prompt-and-wait "say hello")
    (pimacs-send-prompt-and-wait "/session")))

(ert-deftest pimacs-clone ()
  (pimacs-with-integration-project "clone"
    (setq-local pimacs-header-line-format
                '("tokens=" :input_tokens "/" :output_tokens
                  " cache=" :cache_read_tokens "/" :cache_write_tokens
                  " hit=" :cache_hit_percent
                  :spacer
                  "cost=" :cost))
    (pimacs-send-prompt-and-wait "/name clone-test")
    (pimacs-send-prompt-and-wait "say hello")
    (pimacs-send-prompt-and-wait "tell me a story, 100 words")
    (pimacs-send-prompt-and-wait "/compact")
    (pimacs-with-minibuffer-input "high (Deep reasoning ~16k tokens)"
      (pimacs-send-prompt-and-wait "/set-thinking-level"))
    (pimacs-send-prompt-and-wait "/clone")
    (pimacs-send-prompt-and-wait "cloned")))

(ert-deftest pimacs-fork ()
  (pimacs-with-integration-project "fork"
    (setq-local pimacs-header-line-format
                '("context=" :context_tokens "/" :context_window
                  :spacer
                  "tools=" :tool_calls "/" :tool_results))
    (pimacs-send-prompt-and-wait "hello")
    (pimacs-send-prompt-and-wait "hello again")
    (pimacs-with-minibuffer-input "hello again"
      (pimacs-send-prompt-and-wait "/fork"))
    (pimacs-send-prompt-and-wait "hello fork")))

(ert-deftest pimacs-resume ()
  (pimacs-with-integration-project "resume"
    (setq-local pimacs-header-line-format
                '("users=" :user_messages
                  " assistants=" :assistant_messages
                  :spacer
                  "total=" :total_messages))
    (pimacs-send-prompt-and-wait "/name sessionv1")
    (pimacs-send-prompt-and-wait "h1")
    (pimacs-send-prompt-and-wait "h2")
    (pimacs-send-prompt-and-wait "!ls -1 | LC_ALL=C sort")
    (pimacs-send-prompt-and-wait "/new")
    (pimacs-send-prompt-and-wait "/name sessionv2")
    (pimacs-with-minibuffer-input (kbd "sessionv1 TAB RET")
      (pimacs-send-prompt-and-wait "/resume"))
    (pimacs-send-prompt-and-wait "h3")))

(ert-deftest pimacs-compact ()
  (pimacs-with-integration-project "compact"
    (setq-local pimacs-header-line-format
                '("tokens=" :total_tokens " model=" :model))
    (pimacs-send-prompt-and-wait "hello")
    (pimacs-send-prompt-and-wait "tell me a story, 100 words")
    (pimacs-send-prompt-and-wait "/compact")
    (pimacs-send-prompt-and-wait "hello again")))

(ert-deftest pimacs-followup ()
  (pimacs-with-integration-project "followup"
    (setq-local pimacs-header-line-format
                '(:spacer
                  "agent=" :agent_state
                  " thinking=" :thinking_level))
    (pimacs-send-prompt "hello")
    (pimacs-send-prompt "follow up 1")
    (pimacs-send-prompt "follow up 2")
    (pimacs-drain-process-output)
    (pimacs-send-prompt-and-wait "hello again")))

(ert-deftest pimacs-steer ()
  (pimacs-with-integration-project "steer"
    (setq-local pimacs-header-line-format
                '("provider=" :provider
                  :spacer
                  "thinking=" :thinking_level))
    (pimacs-send-prompt "hello")
    (pimacs-send-prompt-alternate "hello 1")
    (pimacs-send-prompt-alternate "hello 2")
    (pimacs-drain-process-output)
    (pimacs-send-prompt-and-wait "hello again")))

(ert-deftest pimacs-send-region ()
  (pimacs-with-integration-project "insert-region"
    (setq-local pimacs-header-line-format
                '("messages=" :message_count
                  :spacer
                  "pending=" :pending_message_count))
    (pimacs-send-prompt-and-wait "say hello")
    (with-temp-buffer
      (insert "hello again")
      (let ((start (point-min))
            (end (point-max)))
        (pimacs-send-region start end)))
    (pimacs-send-prompt-and-wait (widget-value pimacs--prompt-widget))))

(ert-deftest pimacs-send-selects-enclosing-chat ()
  (pimacs-with-silenced-integration-messages
    (let* ((parent-root (file-name-as-directory (make-temp-file "pimacs-parent-" t)))
           (child-root (file-name-as-directory (expand-file-name "child" parent-root)))
           (child-file (expand-file-name "child-file.el" child-root))
           (parent-file (expand-file-name "parent-file.el" parent-root))
           (outside-file (make-temp-file "pimacs-outside-"))
           (default-directory parent-root)
           (pimacs-process-environment
            (list (concat "FIXTURE_SCENARIO=insert-region")
                  (concat "PI_CODING_AGENT_DIR=" pimacs-project-agent-directory)
                  (concat "FIXTURE_MODE=" (pimacs-fixture-mode))))
           (pimacs-flags
            (list "--tools" "read,bash,edit,write,grep,find,ls"
                  "--extension" (expand-file-name "fixture" pimacs-integration-directory)))
           (pimacs-send-pop-to-chat nil)
           parent-chat child-chat child-source parent-source outside-source sessions-list)
      (unwind-protect
          (progn
            (make-directory child-root)
            (with-temp-file child-file
              (insert "child region\n"))
            (with-temp-file parent-file
              (insert "parent region\n"))

            (pimacs-chat "parent" parent-root)
            (setq parent-chat (pimacs--current-chat))
            (pimacs-chat "child" child-root)
            (setq child-chat (pimacs--current-chat))
            (sleep-for 2)
            (with-current-buffer parent-chat
              (pimacs--force-update-header-line))
            (with-current-buffer child-chat
              (pimacs--force-update-header-line))

            (pimacs-list-sessions)
            (setq sessions-list (get-buffer "*Pimacs Sessions*"))
            (with-current-buffer sessions-list
              (should (eq major-mode 'pimacs-list-sessions-mode))
              (pimacs-check-tape "send-selects-enclosing-chat-sessions" ".txt"
                                 (buffer-substring (point-min) (point-max)))
              (pimacs-check-tape
               "send-selects-enclosing-chat-sessions" "-header.txt"
               (substring-no-properties
                (if (stringp header-line-format)
                    header-line-format
                  (nth 2 header-line-format)))))

            (setq child-source (find-file-noselect child-file))
            (with-current-buffer child-source
              (setq-local pimacs--project-key nil)
              (pimacs-with-minibuffer-input (kbd "child RET")
                (pimacs-send-filename))
              (should (eq pimacs--project-key
                          (buffer-local-value 'pimacs--project-key child-chat)))
              (goto-char (point-min))
              (pimacs-send-region (point-min) (line-end-position)))
            (pimacs-assert-prompt child-chat
                                  "@child-file.el\n@child-file.el#L1-1\nchild region")
            (pimacs-assert-prompt parent-chat "")

            (setq parent-source (find-file-noselect parent-file))
            (with-current-buffer parent-source
              (setq-local pimacs--project-key nil)
              (pimacs-send-filename)
              (should (eq pimacs--project-key
                          (buffer-local-value 'pimacs--project-key parent-chat))))
            (pimacs-assert-prompt parent-chat "@parent-file.el")

            (setq outside-source (find-file-noselect outside-file))
            (with-current-buffer outside-source
              (setq-local pimacs--project-key nil)
              (let ((err (should-error (pimacs-send-filename))))
                (should (string-match-p "Chat doesn.?t exist, start a new chat using M-x pimacs-chat"
                                        (error-message-string err))))))
        (dolist (source (list child-source parent-source outside-source))
          (when (buffer-live-p source)
            (kill-buffer source)))
        (when (buffer-live-p sessions-list)
          (kill-buffer sessions-list))
        (dolist (chat (list child-chat parent-chat))
          (when (buffer-live-p chat)
            (with-current-buffer chat
              (ignore-errors (pimacs-quit-chat)))))
        (when (file-exists-p outside-file)
          (delete-file outside-file))
        (when (file-exists-p parent-root)
          (delete-directory parent-root t))))))

(ert-deftest pimacs-reload ()
  (pimacs-with-integration-project "reload"
    (setq-local pimacs-header-line-format
                '("ctx=" :context_usage
                  :spacer
                  "compaction=" :compaction_mode))
    (pimacs-send-prompt-and-wait "hello")
    (let (chat-buffer)
      (pimacs--with-chat-buffer
        (setq chat-buffer (current-buffer)))
      (pimacs-send-prompt "/rpc-editor")
      (pimacs-drain-process-output)
      (should (get-buffer "*pimacs-edit*"))
      (with-current-buffer chat-buffer
        (pimacs-send-prompt "/reload"))
      (sleep-for 3)
      (should-not (get-buffer "*pimacs-edit*")))
    (pimacs-send-prompt-and-wait "hello")))

(ert-deftest pimacs-extension-ui ()
  (pimacs-with-integration-project "extension-ui"
    (setq-local pimacs-header-line-format
                '("cost=" :cost
                  :spacer
                  "model=" (:model face font-lock-function-name-face)))
    (pimacs-send-prompt-and-wait "/rpc-notify")

    (pimacs-with-minibuffer-input "test value"
      (pimacs-send-prompt-and-wait "/rpc-input"))

    (pimacs-with-minibuffer-input "y"
      (pimacs-send-prompt-and-wait "/rpc-confirm"))

    (pimacs-with-minibuffer-input "n"
      (pimacs-send-prompt-and-wait "/rpc-confirm"))

    (pimacs-with-minibuffer-input (kbd "C-g")
      (pimacs-send-prompt-and-wait "/rpc-confirm"))

    (pimacs-with-minibuffer-input "Option B"
      (pimacs-send-prompt-and-wait "/rpc-select"))

    (pimacs-with-minibuffer-input (kbd "C-g")
      (pimacs-send-prompt-and-wait "/rpc-select"))

    (pimacs-send-prompt-and-wait "/rpc-set-editor-text")

    (pimacs-send-prompt-and-wait (widget-value pimacs--prompt-widget))

    (pimacs-send-prompt "/rpc-editor")
    (pimacs-with-editor-buffer
      (goto-char (point-max))
      (insert "\nnew line")
      (pimacs-edit-finish))

    (pimacs-send-prompt "/rpc-editor")
    (pimacs-with-editor-buffer
      (pimacs-edit-cancel))

    (pimacs-send-prompt-and-wait "/rpc-set-widget")

    (pimacs-send-prompt-and-wait "/rpc-set-status")

    (pimacs-send-prompt-and-wait "/rpc-set-title")))

;;; pimacs-tests.el ends here
