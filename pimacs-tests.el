;;; pimacs-tests --- This file contains automated tests for pimacs.el -*- lexical-binding: t; -*-

;;; Code:

;; Test setup:

(require 'ert)

;; development only packages, not declared as a package-dependency
(package-initialize)

(require 'undercover)
(undercover)

(require 'pimacs)

(ert-deftest pimacs-chat--transient-defaults-root-to-project-root ()
  (let ((prefix (transient-prefix :command 'pimacs-test)))
    (cl-letf (((symbol-function 'pimacs--project-root)
               (lambda () "/tmp/project/")))
      (pimacs-chat--transient-init-value prefix))
    (should (equal (oref prefix value) '("--root=/tmp/project/")))))

(ert-deftest pimacs-chat--start-uses-transient-name-and-root ()
  (let (arguments)
    (cl-letf (((symbol-function 'transient-args)
               (lambda (_prefix) '("--name=session" "--root=/tmp/root")))
              ((symbol-function 'pimacs-chat--create)
               (lambda (&rest args) (setq arguments args))))
      (pimacs-chat--start))
    (should (equal arguments '("session" "/tmp/root")))))

(ert-deftest pimacs--select-chat-appends-id-to-duplicate-names ()
  (let ((first (generate-new-buffer " *pimacs-session-1*"))
        (second (generate-new-buffer " *pimacs-session-2*"))
        (unnamed (generate-new-buffer " *pimacs-session-3*"))
        (unique (generate-new-buffer " *pimacs-session-4*"))
        labels selected)
    (unwind-protect
        (progn
          (with-current-buffer first
            (setq pimacs--header-line-state
                  '(:sessionName "shared" :sessionStats (:sessionId "00000000-11111111"))))
          (with-current-buffer second
            (setq pimacs--header-line-state
                  '(:sessionName "shared" :sessionStats (:sessionId "00000000-22222222"))))
          (with-current-buffer unnamed
            (setq pimacs--header-line-state
                  '(:sessionStats (:sessionId "00000000-33333333"))))
          (with-current-buffer unique
            (setq pimacs--header-line-state
                  '(:sessionName "unique" :sessionStats (:sessionId "00000000-44444444"))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt choices &rest _)
                       (setq labels (mapcar #'car choices))
                       "shared 22222222")))
            (setq selected
                  (pimacs--select-chat
                   `(("first" . ,first) ("second" . ,second)
                     ("unnamed" . ,unnamed) ("unique" . ,unique))
                   "Session: ")))
          (should (equal labels '("33333333" "shared 11111111" "shared 22222222" "unique")))
          (should (eq (cdr selected) second)))
      (dolist (buffer (list first second unnamed unique))
        (kill-buffer buffer)))))

(ert-deftest pimacs--parse-slash-command ()
  (should (equal (pimacs--parse-slash-command "/model") '(pimacs-select-model . nil)))
  (should (equal (pimacs--parse-slash-command "/new") '(pimacs-new-session . nil)))
  (should (equal (pimacs--parse-slash-command "/resume") '(pimacs-resume . nil)))
  (should (equal (pimacs--parse-slash-command "/compact") '(pimacs-compact . nil)))
  (should (equal (pimacs--parse-slash-command "/set-auto-compaction") '(pimacs-set-auto-compaction . nil)))
  (should (equal (pimacs--parse-slash-command "/set-auto-retry") '(pimacs-set-auto-retry . nil)))
  (let ((err (should-error (pimacs--parse-slash-command "/set-auto-compaction true"))))
    (should (equal "Slash command \"/set-auto-compaction\" does not accept arguments" (error-message-string err))))
  (should (equal (pimacs--parse-slash-command "/compact custom instructions") '(pimacs-compact . "custom instructions")))
  (should (equal (pimacs--parse-slash-command "  /model") '(pimacs-select-model . nil)))
  (should (equal (pimacs--parse-slash-command "/model ") '(pimacs-select-model . nil)))
  (should (null (pimacs--parse-slash-command "/unknown")))
  (should (null (pimacs--parse-slash-command "/modelx")))
  (should (null (pimacs--parse-slash-command "/")))
  (should (null (pimacs--parse-slash-command "/123")))
  (should (null (pimacs--parse-slash-command "not-a-slash /model")))
  (should (null (pimacs--parse-slash-command "")))
  (should (null (pimacs--parse-slash-command "line1\n/model")))
  (should (null (pimacs--parse-slash-command "line1\n  /model")))
  (should (null (pimacs--parse-slash-command "line1\n/unknown")))
  (should (equal (pimacs--parse-slash-command "\n/model") '(pimacs-select-model . nil)))
  (should (equal (pimacs--parse-slash-command "\n\n/model") '(pimacs-select-model . nil)))
  (let ((err (should-error (pimacs--parse-slash-command "/model arg"))))
    (should (equal "Slash command \"/model\" does not accept arguments" (error-message-string err)))))

(ert-deftest pimacs--parse-bang-command ()
  (should (equal (pimacs--parse-bang-command "!ls") "ls"))
  (should (equal (pimacs--parse-bang-command "!ls -la") "ls -la"))
  (should (equal (pimacs--parse-bang-command "  !ls") "ls"))
  (should (equal (pimacs--parse-bang-command "! cat!") " cat!"))
  (should (null (pimacs--parse-bang-command "!!ls")))
  (should (null (pimacs--parse-bang-command "!!")))
  (should (null (pimacs--parse-bang-command "!")))
  (should (null (pimacs--parse-bang-command "! ")))
  (should (null (pimacs--parse-bang-command "!!  ")))
  (should (null (pimacs--parse-bang-command "not-a-bang !ls")))
  (should (null (pimacs--parse-bang-command "")))
  (should (null (pimacs--parse-bang-command "line1\n!ls")))
  (should (null (pimacs--parse-bang-command "line1\n  !ls")))
  (should (null (pimacs--parse-bang-command "line1\n!ls -la")))
  (should (equal (pimacs--parse-bang-command "\n!ls") "ls"))
  (should (equal (pimacs--parse-bang-command "\n\n!ls") "ls")))

(ert-deftest pimacs--parse-double-bang-command ()
  (should (equal (pimacs--parse-double-bang-command "!!ls") "ls"))
  (should (equal (pimacs--parse-double-bang-command "!!ls -la") "ls -la"))
  (should (equal (pimacs--parse-double-bang-command "  !!ls") "ls"))
  (should (null (pimacs--parse-double-bang-command "!!")))
  (should (null (pimacs--parse-double-bang-command "!")))
  (should (null (pimacs--parse-double-bang-command "  !!")))
  (should (null (pimacs--parse-double-bang-command "!! ")))
  (should (null (pimacs--parse-double-bang-command "! ")))
  (should (null (pimacs--parse-double-bang-command "!ls")))
  (should (null (pimacs--parse-double-bang-command "not-a-bang !!ls")))
  (should (null (pimacs--parse-double-bang-command "")))
  (should (null (pimacs--parse-double-bang-command "line1\n!!ls")))
  (should (null (pimacs--parse-double-bang-command "line1\n  !!ls")))
  (should (null (pimacs--parse-double-bang-command "line1\n!!ls -la")))
  (should (equal (pimacs--parse-double-bang-command "\n!!ls") "ls"))
  (should (equal (pimacs--parse-double-bang-command "\n\n!!ls") "ls")))

(ert-deftest pimacs--extract-truncation-notice-more-lines ()
  (should (equal (pimacs--extract-truncation-notice
                  "line1\nline2\n[40 more lines in file. Use offset=61 to continue.]")
                 '("line1\nline2" . "[40 more lines in file. Use offset=61 to continue.]"))))

(ert-deftest pimacs--extract-truncation-notice-showing-lines ()
  (should (equal (pimacs--extract-truncation-notice
                  "line1\nline2\n[Showing lines 1-1648 of 6218 (50.0KB limit). Use offset=1649 to continue.]")
                 '("line1\nline2" . "[Showing lines 1-1648 of 6218 (50.0KB limit). Use offset=1649 to continue.]"))))

(ert-deftest pimacs--extract-truncation-notice-no-notice ()
  (should (equal (pimacs--extract-truncation-notice "line1\nline2\nline3")
                 '("line1\nline2\nline3" . nil))))

(ert-deftest pimacs--extract-truncation-notice-empty ()
  (should (equal (pimacs--extract-truncation-notice "")
                 '("" . nil))))

(ert-deftest pimacs--extract-truncation-notice-showing-lines-no-size ()
  (should (equal (pimacs--extract-truncation-notice
                  "line1\nline2\n[Showing lines 1-1648 of 6218. Use offset=1649 to continue.]")
                 '("line1\nline2" . "[Showing lines 1-1648 of 6218. Use offset=1649 to continue.]"))))

(ert-deftest pimacs--extract-truncation-notice-bash-fallback ()
  (should (equal (pimacs--extract-truncation-notice
                  "line1\nline2\n[Line 1 is 100KB, exceeds 50.0KB limit. Use bash: sed -n '1p' main.go | head -c 51200]")
                 '("line1\nline2" . "[Line 1 is 100KB, exceeds 50.0KB limit. Use bash: sed -n '1p' main.go | head -c 51200]"))))

(ert-deftest pimacs--join-test ()
  (should (equal (pimacs--join nil) ""))
  (should (equal (pimacs--join '()) ""))
  (should (equal (pimacs--join "hello") "hello"))
  (should (equal (pimacs--join '("a" "b" "c")) "a\nb\nc"))
  (should (equal (pimacs--join '("a" "b" "c") ",") "a,b,c"))
  (should (equal (pimacs--join '("key" . "value")) "value"))
  (should (equal (pimacs--join '(("k1" . "v1") ("k2" . "v2"))) "v1\nv2"))
  (should (equal (pimacs--join '(("k1" . "v1") ("k2" . "v2")) ",") "v1,v2"))
  (should (equal (pimacs--join '(("k1" . "a\nb") ("k2" . "c"))) "a\nb\nc")))

(ert-deftest pimacs--update-status-widget-joins-statuses-with-space ()
  (with-temp-buffer
    (setq pimacs--status-widget
          (widget-create 'pimacs-item :face 'pimacs-status-face pimacs--empty-widget-text))
    (setq pimacs--status-texts (make-hash-table :test 'equal))

    (pimacs--handle-set-status '(:statusKey "status-b" :statusText "Status B"))
    (pimacs--handle-set-status '(:statusKey "status-a" :statusText "Status\nA"))

    (should (equal (widget-value pimacs--status-widget) "Status\nA Status B\n"))

    (let ((pimacs-status-widget-hidden-keys '("status-a")))
      (pimacs--update-status-widget)
      (should (equal (widget-value pimacs--status-widget) "Status B\n"))
      (should (equal (gethash "status-a" pimacs--status-texts) "Status\nA")))))

(ert-deftest pimacs--handle-bash-execution-update-appends-deltas-by-request-id ()
  (with-temp-buffer
    (pimacs-section--create-root-section)
    (setq pimacs--prompt-widget
          (widget-create 'editable-field :format "%v" :value ""))
    (setq pimacs--bash-executions (make-hash-table :test 'equal))
    (widget-setup)
    (let ((first-call (pimacs-section--new-section 'tool-call pimacs-section--root-section))
          (second-call (pimacs-section--new-section 'tool-call pimacs-section--root-section)))
      (pimacs-section--insert-section first-call
        (insert "first"))
      (pimacs-section--insert-section second-call
        (insert "second"))
      (puthash "req-1" (make-pimacs-tool-call :call-section first-call)
               pimacs--bash-executions)
      (puthash "req-2" (make-pimacs-tool-call :call-section second-call)
               pimacs--bash-executions)
      (pimacs--handle-bash-execution-update '(:id "req-1" :delta "one\n"))
      (pimacs--handle-bash-execution-update '(:id "req-2" :delta "two\n"))
      (pimacs--handle-bash-execution-update '(:id "req-1" :delta "three\n"))
      (dolist (expected '(("req-1" . "one\nthree\n")
                          ("req-2" . "two\n")))
        (let* ((entry (gethash (car expected) pimacs--bash-executions))
               (section (pimacs-tool-call-result-section entry))
               (content (buffer-substring-no-properties
                         (pimacs-section-beginning section)
                         (pimacs-section-end section))))
          (should (equal content (cdr expected))))))))

(ert-deftest pimacs-bash-displays-direct-result-without-updates ()
  (with-temp-buffer
    (pimacs-section--create-root-section)
    (setq pimacs--prompt-widget
          (widget-create 'editable-field :format "%v" :value ""))
    (setq pimacs--spinner (spinner-create 'progress-bar))
    (setq pimacs--bash-executions (make-hash-table :test 'equal))
    (setq-local pimacs--project-key "test")
    (widget-setup)
    (let ((pimacs--chats (make-hash-table :test 'equal))
          callback)
      (puthash pimacs--project-key (current-buffer) pimacs--chats)
      (cl-letf (((symbol-function 'pimacs--send-command)
                 (lambda (_type _args fn)
                   (setq callback fn)
                   "req-1"))
                ((symbol-function 'pimacs--update-header-line)
                 (lambda () nil)))
        (pimacs-bash "printf result")
        (funcall callback '(:id "req-1" :success t :data (:output "result" :exitCode 0))))
      (should (string-match-p "result" (buffer-string)))
      (should (= (hash-table-count pimacs--bash-executions) 0)))))

(ert-deftest pimacs--handle-agent-state-formats-parallel-tools ()
  (with-temp-buffer
    (setq pimacs--spinner (spinner-create 'progress-bar))
    (pimacs-section--create-root-section)

    (pimacs--handle-agent-state '(:type "tool_execution_start" :toolName "read"))
    (should (equal (pimacs--format-state) "tool(read)"))
    (should (spinner--active-p pimacs--spinner))

    (pimacs--handle-agent-state '(:type "tool_execution_start" :toolName "grep"))
    (should (equal (pimacs--format-state) "tool(grep, read)"))
    (should (spinner--active-p pimacs--spinner))

    (pimacs--handle-agent-state '(:type "tool_execution_start" :toolName "bash"))
    (should (equal (pimacs--format-state) "tool(bash, grep + 1 more)"))
    (should (spinner--active-p pimacs--spinner))

    (pimacs--handle-agent-state '(:type "tool_execution_end" :toolName "bash"))
    (should (equal (pimacs--format-state) "tool(grep, read)"))
    (should (spinner--active-p pimacs--spinner))

    (pimacs--handle-agent-state '(:type "tool_execution_end" :toolName "grep"))
    (should (equal (pimacs--format-state) "tool(read)"))
    (should (spinner--active-p pimacs--spinner))

    (pimacs--handle-agent-state '(:type "tool_execution_end" :toolName "read"))
    (should (equal (pimacs--format-state) "thinking"))
    (should (spinner--active-p pimacs--spinner))

    (pimacs--handle-agent-state '(:type "agent_settled"))
    (should (equal (pimacs--format-state) "idle"))
    (should-not (spinner--active-p pimacs--spinner))))

(ert-deftest pimacs--handle-message-end-creates-section-without-deltas ()
  (with-temp-buffer
    (pimacs-section--create-root-section)
    (setq pimacs--content-sections (make-hash-table :test 'eql))
    (setq pimacs--prompt-widget
          (widget-create 'editable-field :format "%v" :value ""))
    (widget-setup)

    (pimacs--handle-message-end
     '(:message (:role "assistant"
                       :content ((:type "text" :text "Hello")))))

    (let ((section (car (pimacs-section-children pimacs-section--root-section))))
      (should (eq (pimacs-section-type section) 'assistant))
      (should (equal (pimacs-section-assistant-info-content
                      (pimacs-section-info section))
                     '((:type "text" :text "Hello"))))
      (should (string-match-p "assistant> Hello"
                              (buffer-substring-no-properties
                               (pimacs-section-beginning section)
                               (pimacs-section-end section)))))
    (should (= (hash-table-count pimacs--content-sections) 0))))

(ert-deftest pimacs-clear-ui-keeps-sections-before-prompt-widgets ()
  (with-temp-buffer
    (pimacs-section--create-root-section)
    (setq pimacs--tool-calls (make-hash-table :test 'equal))
    (setq pimacs--bash-executions (make-hash-table :test 'equal))
    (setq pimacs--content-sections (make-hash-table :test 'eql))
    (setq pimacs--prompt-before-widget
          (widget-create 'pimacs-item :face 'pimacs-widget-face pimacs--empty-widget-text))
    (setq pimacs--prompt-widget
          (widget-create 'editable-field :format "%[user>%] %v" :value ""))
    (setq pimacs--prompt-after-widget
          (widget-create 'pimacs-item :face 'pimacs-widget-face pimacs--empty-widget-text))
    (setq pimacs--prompt-widget-lines (make-hash-table :test 'equal))
    (setq pimacs--status-widget
          (widget-create 'pimacs-item :face 'pimacs-status-face pimacs--empty-widget-text))
    (setq pimacs--status-texts (make-hash-table :test 'equal))
    (widget-setup)

    (cl-labels ((insert-section ()
                  (let (section)
                    (pimacs--widget-save-excursion
                      (setq section
                            (pimacs-section--create-section 'info pimacs-section--root-section
                              (insert "sections"))))
                    section))
                (set-widgets ()
                  (pimacs--handle-set-widget '(:widgetKey "before"
                                                          :widgetLines ("before-widget")
                                                          :widgetPlacement "aboveEditor"))
                  (pimacs--handle-set-widget '(:widgetKey "after"
                                                          :widgetLines ("after-widget")
                                                          :widgetPlacement "belowEditor"))))
      (set-widgets)
      (let ((section (insert-section)))
        (should (< (marker-position (pimacs-section-beginning section))
                   (marker-position (widget-get pimacs--prompt-before-widget :from))
                   (marker-position (widget-get pimacs--prompt-widget :from))
                   (marker-position (widget-get pimacs--prompt-after-widget :from)))))

      (pimacs--widget-save-excursion
        (pimacs--clear-sections)
        (pimacs--clear-session-widgets))

      (set-widgets)
      (let ((section (insert-section)))
        (should (< (marker-position (pimacs-section-beginning section))
                   (marker-position (widget-get pimacs--prompt-before-widget :from))
                   (marker-position (widget-get pimacs--prompt-widget :from))
                   (marker-position (widget-get pimacs--prompt-after-widget :from))))))))

;;; pimacs-tests.el ends here

