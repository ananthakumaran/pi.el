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

(ert-deftest pimacs--buffer-string-common-prefix-length ()
  (cl-labels ((common-prefix (buffer-text string)
                (with-temp-buffer
                  (insert buffer-text)
                  (pimacs--buffer-string-common-prefix-length
                   (current-buffer) (point-min) (point-max) string))))
    (should (= (common-prefix "" "") 0))
    (should (= (common-prefix "" "text") 0))
    (should (= (common-prefix "text" "") 0))
    (should (= (common-prefix "matching" "matching") 8))
    (with-temp-buffer
      (insert "ignoredmatching")
      (should (= (pimacs--buffer-string-common-prefix-length
                  (current-buffer) (+ (point-min) 7) (point-max) "matching")
                 8)))
    (should (= (common-prefix "shared" "sharing") 4))
    (should (= (common-prefix "prefix" "prefix-more") 6))
    (should (= (common-prefix "prefix-more" "prefix") 6))
    (let ((buffer-text (propertize "abcdef" 'face 'bold))
          (string (propertize "abcdef" 'face 'bold)))
      (should (= (common-prefix buffer-text string) 6)))
    (let ((buffer-text (copy-sequence "abcdef"))
          (string (copy-sequence "abcdef")))
      (put-text-property 2 6 'face 'bold buffer-text)
      (put-text-property 2 6 'face 'italic string)
      (should (= (common-prefix buffer-text string) 2)))
    (let ((buffer-text (copy-sequence "abcdef"))
          (string (copy-sequence "abcdef")))
      (put-text-property 1 5 'face 'bold buffer-text)
      (put-text-property 1 5 'face 'bold string)
      (put-text-property 3 6 'help-echo "Link" buffer-text)
      (put-text-property 3 6 'help-echo "Link" string)
      (should (= (common-prefix buffer-text string) 6)))
    (let ((buffer-text (copy-sequence "abcdef"))
          (string (copy-sequence "abcdef")))
      (put-text-property 1 5 'face 'bold buffer-text)
      (put-text-property 1 5 'face 'bold string)
      (put-text-property 3 6 'help-echo "First link" buffer-text)
      (put-text-property 3 6 'help-echo "Second link" string)
      (should (= (common-prefix buffer-text string) 3)))
    (let ((buffer-text (copy-sequence "abcdef"))
          (string (copy-sequence "abcdef")))
      (put-text-property 1 4 'face 'bold buffer-text)
      (put-text-property 1 5 'face 'bold string)
      (should (= (common-prefix buffer-text string) 4)))
    (let ((buffer-text (copy-sequence "abcdef"))
          (string (copy-sequence "abcdef")))
      (put-text-property 4 6 'pimacs-test-property 'one buffer-text)
      (put-text-property 4 6 'pimacs-test-property 'two string)
      (should (= (common-prefix buffer-text string) 4)))))

(ert-deftest pimacs--render-apply-operations-replaces-suffix ()
  (with-temp-buffer
    (let* ((context (pimacs--render-create-context))
           (initial (concat (propertize "prefix " 'face 'bold)
                            (propertize "old" 'face 'italic)))
           (replacement (concat (propertize "prefix " 'face 'bold)
                                (propertize "new" 'face 'italic)))
           changes)
      (pimacs--render-apply-operations context (list (list :append initial)))
      (add-hook 'before-change-functions
                (lambda (start end) (push (list start end) changes))
                nil t)
      (pimacs--render-apply-operations
       context (list (list :replace-suffix (length initial) replacement)))
      (should (equal (nreverse changes) '((8 11) (8 8))))
      (should (equal-including-properties
               (buffer-substring (pimacs-render-context-content-begin context)
                                 (pimacs-render-context-content-end context))
               replacement))
      (should (= (pimacs-render-context-rendered-length context)
                 (length replacement)))
      (setq changes nil)
      (pimacs--render-apply-operations
       context (list (list :replace-suffix (length replacement) replacement)))
      (should-not changes)
      (let ((shortened (propertize "prefix" 'face 'bold)))
        (pimacs--render-apply-operations
         context (list (list :replace-suffix (length replacement) shortened)))
        (should (equal (nreverse changes) '((7 11))))
        (should (equal-including-properties
                 (buffer-substring (pimacs-render-context-content-begin context)
                                   (pimacs-render-context-content-end context))
                 shortened))
        (should (= (pimacs-render-context-rendered-length context)
                   (length shortened)))))))

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
    (should (equal (get-text-property 0 'help-echo (widget-value pimacs--status-widget))
                   "status-a"))

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

(ert-deftest pimacs--insert-grep-result-preserves-backslashes-in-matches ()
  (let ((content
         (concat
          "autolink.in.markdown:7: http://one.example\\*literal\n"
          "document.in.markdown:116: [Reference-style link][ref-link]\n"
          "document.in.markdown:124: [ref-link]: https://reference-example.com \"Reference Link Title\"\n"
          "document.in.markdown:130: ![Reference-style link title tooltip\")\n"
          "document.in.markdown:132: ![Reference-style image][ref-image]\n"
          "document.in.markdown:134: [ref-image]: https://via.placeholder.com/200x100 \"Reference Image\"\n"
          "escapes.in.markdown:1: \\*literal\\* \\_literal\\_ \\`literal\\` \\[literal\\](url) \\\\ \\~literal\\~ \\a\n"
          "reference-link.out.txt:1: │ Full reference\n"
          "reference-link.in.markdown:1: [site]: https://example.com \"Pimacs website\"\n"
          "reference-link.in.markdown:3: [Full reference][site]\n"
          "reference-link.in.markdown:4: [site]\n"
          "document.out.txt:211: │ Reference-style link\n"
          "document.out.txt:230: │ ![Reference-style link title tooltip\")\n"
          "document.out.txt:232: │ Reference-style image")))
    (with-temp-buffer
      (pimacs--insert-grep-result
       (list (list :type "text" :text content))
       nil
       '(:pattern "reference|autolink|link title|\\\\\\*literal|site\\]"
                  :path "test/pimacs-markdown-tapes"
                  :glob "*"
                  :ignoreCase t
                  :limit 100))
      (should (equal (buffer-string) content))
      (goto-char (point-min))
      (search-forward "\\*literal")
      (should (eq (get-text-property (- (point) (length "\\*literal")) 'face)
                  'pimacs-grep-match-face)))))

(ert-deftest pimacs--insert-grep-result-does-not-fontify-adjacent-tool-call ()
  (with-temp-buffer
    (pimacs-section--create-root-section)
    (setq pimacs--prompt-widget
          (widget-create 'editable-field :format "%v" :value ""))
    (setq pimacs--tool-calls (make-hash-table :test 'equal))
    (widget-setup)
    (let ((pimacs-section-padding "\n"))
      (cl-letf (((symbol-function 'pimacs--project-root)
                 (lambda () default-directory)))
        (pimacs--insert-message
         '(:role "assistant"
                 :content ((:type "toolCall" :id "grep" :name "grep"
                                  :arguments (:pattern "foo" :path "src"))
                           (:type "toolCall" :id "read" :name "read"
                                  :arguments (:path "pimacs-agent.el" :offset 296 :limit 90)))))
        (pimacs--insert-message
         '(:role "toolResult" :toolCallId "grep" :toolName "grep"
                 :content ((:type "text" :text "reload.md-195- "))))
        (goto-char (point-min))
        (search-forward "read ")
        (should (equal (get-text-property (- (point) (length "read ")) 'face)
                       '(pimacs-tool-name-face pimacs-section-tool-call-face)))))))

(ert-deftest pimacs--insert-grep-args-treats-json-false-as-false ()
  (with-temp-buffer
    (pimacs--insert-grep-args
     '(:pattern "foo" :ignoreCase json-false :literal json-false))
    (should (equal (buffer-string) "/foo/"))))

(ert-deftest pimacs--insert-grep-result-fontifies-primary-and-context-lines ()
  (let ((content "dir:name.el:12: foo BAR\ndir:name.el-13-foo BAR"))
    (with-temp-buffer
      (pimacs--insert-grep-result
       (list (list :type "text" :text content)) nil '(:pattern "foo"))
      (should (equal (buffer-string) content))
      (should (eq (get-text-property (point-min) 'face) 'compilation-info))
      (goto-char (point-min))
      (search-forward "12")
      (should (eq (get-text-property (1- (point)) 'face) 'compilation-line-number))
      (search-forward "foo")
      (should (eq (get-text-property (- (point) 3) 'face) 'pimacs-grep-match-face))
      (search-forward "BAR")
      (should-not (get-text-property (- (point) 3) 'face))
      (forward-line 1)
      (should (eq (get-text-property (point) 'face) 'compilation-info))
      (search-forward "13")
      (should (eq (get-text-property (1- (point)) 'face) 'compilation-line-number))
      (search-forward "foo")
      (should-not (get-text-property (- (point) 3) 'face)))))

(ert-deftest pimacs--insert-grep-result-honors-literal-and-ignore-case ()
  (with-temp-buffer
    (pimacs--insert-grep-result
     '((:type "text" :text "a:1: A.B axb"))
     nil '(:pattern "a.b" :literal t :ignoreCase t))
    (goto-char (point-min))
    (search-forward "A.B")
    (should (eq (get-text-property (- (point) 3) 'face) 'pimacs-grep-match-face))
    (search-forward "axb")
    (should-not (get-text-property (- (point) 3) 'face)))
  (with-temp-buffer
    (pimacs--insert-grep-result
     '((:type "text" :text "a:1: FOO foo")) nil '(:pattern "foo"))
    (goto-char (point-min))
    (search-forward "FOO")
    (should-not (get-text-property (- (point) 3) 'face))
    (search-forward "foo")
    (should (eq (get-text-property (- (point) 3) 'face) 'pimacs-grep-match-face))))

(ert-deftest pimacs--insert-grep-result-narrows-match-to-content ()
  (with-temp-buffer
    (pimacs--insert-grep-result
     '((:type "text" :text "a:1: foo bar")) nil '(:pattern "^foo bar$"))
    (goto-char (point-min))
    (search-forward "foo bar")
    (should (eq (get-text-property (- (point) 7) 'face) 'pimacs-grep-match-face))
    (should (eq (get-text-property (1- (point)) 'face) 'pimacs-grep-match-face))
    (should (eq (get-text-property (point-min) 'face) 'compilation-info))))

(ert-deftest pimacs--insert-grep-result-handles-invalid-and-zero-width-patterns ()
  (with-temp-buffer
    (pimacs--insert-grep-result
     '((:type "text" :text "a:1: foo")) nil '(:pattern "["))
    (should (equal (buffer-string) "a:1: foo"))
    (should (eq (get-text-property (point-min) 'face) 'compilation-info))
    (goto-char (point-min))
    (search-forward "foo")
    (should-not (get-text-property (- (point) 3) 'face)))
  (with-temp-buffer
    (insert "foo")
    (pimacs--fontify-grep-matches (point-min) (point-max) "\\_<" nil)
    (should-not (get-text-property (point-min) 'face))))

(ert-deftest pimacs--insert-grep-result-preserves-newlines-and-translates-once ()
  (dolist (content '("" "a:1: foo" "a:1: foo\n" "a:1: foo\n\n"))
    (with-temp-buffer
      (pimacs--insert-grep-result
       (list (list :type "text" :text content)) nil '(:pattern "foo"))
      (should (equal (buffer-string) content))))
  (let ((translations 0)
        (original (symbol-function 'rxt-pcre-to-elisp)))
    (cl-letf (((symbol-function 'rxt-pcre-to-elisp)
               (lambda (pattern)
                 (cl-incf translations)
                 (funcall original pattern))))
      (with-temp-buffer
        (pimacs--insert-grep-result
         '((:type "text" :text "a:1: foo\nb:2: foo")) nil '(:pattern "foo"))))
    (should (= translations 1))))

(ert-deftest pimacs--text-visitors-report-character-offsets-as-columns ()
  (let ((source-line "\tfoo")
        (expected-column (length "\tf")))
    (with-temp-buffer
      (insert source-line)
      (goto-char (point-min))
      (search-forward "f")
      (cl-letf (((symbol-function 'pimacs-section--section-line) (lambda () 1))
                ((symbol-function 'pimacs--project-root) (lambda () "/project/")))
        (let ((read-result (pimacs--visit-read-result nil '(:path "file")))
              (write-result (pimacs--visit-write-call '(:path "file"))))
          (should (= (plist-get read-result :column) expected-column))
          (should (= (plist-get write-result :column) expected-column)))))))

(ert-deftest pimacs--visit-grep-result-reports-character-offset-after-tab ()
  (with-temp-buffer
    (insert "example.el:7: \tfoo")
    (goto-char (point-min))
    (search-forward "f")
    (should (equal (pimacs--visit-grep-result nil nil)
                   '(:file "example.el" :line 7 :column 2)))))

(ert-deftest pimacs--visit-file-treats-column-as-character-offset ()
  (let ((target (generate-new-buffer " *pimacs-visit-target*")))
    (unwind-protect
        (progn
          (with-current-buffer target
            (insert "\tfoo"))
          (cl-letf (((symbol-function 'find-file)
                     (lambda (_file) (set-buffer target))))
            (pimacs--visit-file '(:file "unused" :line 1 :column 2))
            (should (equal (buffer-substring (line-beginning-position) (point))
                           "\tf"))
            (should (looking-at "oo"))))
      (kill-buffer target))))

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

(ert-deftest pimacs--handle-message-update-batch-merges-compatible-deltas ()
  (let* ((first '(:assistantMessageEvent (:type "text_delta" :delta "a" :contentIndex 0)))
         (events (list first
                       '(:assistantMessageEvent (:type "text_delta" :delta "b" :contentIndex 0))
                       '(:assistantMessageEvent (:type "thinking_delta" :delta "c" :contentIndex 0))
                       '(:assistantMessageEvent (:type "thinking_delta" :delta "d" :contentIndex 0))
                       '(:assistantMessageEvent (:type "text_delta" :delta "e" :contentIndex 1))
                       '(:assistantMessageEvent (:type "text_delta" :delta "f" :contentIndex 1))))
         handled)
    (cl-letf (((symbol-function 'pimacs--handle-message-update)
               (lambda (event) (push event handled))))
      (pimacs--handle-message-update-batch events))
    (should (equal (mapcar (lambda (event)
                             (let ((assistant-message-event
                                    (plist-get event :assistantMessageEvent)))
                               (list (plist-get assistant-message-event :type)
                                     (plist-get assistant-message-event :contentIndex)
                                     (plist-get assistant-message-event :delta)
                                     "assistant")))
                           (nreverse handled))
                   '(("text_delta" 0 "ab" "assistant")
                     ("thinking_delta" 0 "cd" "assistant")
                     ("text_delta" 1 "ef" "assistant"))))
    (should (equal (plist-get (plist-get first :assistantMessageEvent) :delta) "a"))))

(ert-deftest pimacs--markdown-renderer-lifecycle ()
  (with-temp-buffer
    (pimacs-section--create-root-section)
    (setq pimacs--content-sections (make-hash-table :test 'eql))
    (setq pimacs--prompt-widget
          (widget-create 'editable-field :format "%v" :value ""))
    (widget-setup)

    (let* ((operations nil)
           (pimacs-markdown-renderer
            (lambda (operation &optional _state text)
              (push operation operations)
              (pcase operation
                (:create (list :renderer-state))
                (:stream (list (list :append (concat "stream: " text))))
                (:final (list (list :append (concat "full: " text))))
                (:destroy nil)))))
      (pimacs--handle-message-update
       '(:assistantMessageEvent (:type "text_delta" :delta "Hello" :contentIndex 0)
                                :message (:role "assistant")))
      (should (string-match-p "assistant> stream: Hello" (buffer-string)))
      (pimacs--handle-message-update
       '(:assistantMessageEvent (:type "text_delta" :delta " world" :contentIndex 0)
                                :message (:role "assistant")))
      (let ((section (pimacs-content-section-section
                      (gethash 0 pimacs--content-sections))))
        (should (string-match-p
                 "stream: Hello.*stream:  world"
                 (buffer-substring-no-properties
                  (pimacs-section-beginning section)
                  (pimacs-section-end section)))))

      (pimacs--handle-message-end
       '(:message (:role "assistant"
                         :content ((:type "text" :text "Hello world")))))
      (should (string-match-p "assistant> full: Hello world" (buffer-string)))
      (should-not (string-match-p "stream: Hello" (buffer-string)))
      (should (equal (nreverse operations)
                     '(:create :stream :stream :final :destroy))))))

(ert-deftest pimacs-section-applies-configured-face ()
  (with-temp-buffer
    (let ((pimacs-section-type-faces '((info . bold))))
      (pimacs-section--create-root-section)
      (pimacs-section--create-section 'info pimacs-section--root-section
        (pimacs-section--insert-chrome "chrome " 'italic)
        (insert (propertize "content" 'face 'underline)))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     (concat "chrome content" pimacs-section-padding)))
      (should (equal (get-text-property (point-min) 'face)
                     '(italic bold)))
      (should (equal (get-text-property (+ (point-min) (length "chrome ")) 'face)
                     '(bold underline)))
      (let ((face (get-text-property (1- (point-max)) 'face)))
        (should (eq (if (listp face) (car face) face) 'bold))))))

(ert-deftest pimacs-section-styles-appended-and-replaced-content ()
  (with-temp-buffer
    (let ((pimacs-section-type-faces '((info . bold))))
      (pimacs-section--create-root-section)
      (let ((section (pimacs-section--create-section 'info pimacs-section--root-section
                       (insert "one"))))
        (pimacs-section--append-section section
          (insert (propertize " two" 'face 'italic)))
        (save-excursion
          (goto-char (point-min))
          (search-forward "two")
          (should (equal (get-text-property (- (point) 3) 'face)
                         '(bold italic))))
        (pimacs-section--append-section section
          (delete-region (- (point) 2) (point))
          (insert (propertize "wo" 'face 'underline)))
        (save-excursion
          (goto-char (point-min))
          (search-forward "wo")
          (should (equal (get-text-property (- (point) 2) 'face)
                         '(bold underline))))
        (pimacs-section--replace-section section
          (insert (propertize "three" 'face 'underline)))
        (should (equal (get-text-property (point-min) 'face)
                       '(bold underline)))))))

(ert-deftest pimacs-section-child-face-does-not-inherit-parent-face ()
  (with-temp-buffer
    (let ((pimacs-section-type-faces
           '((assistant . bold) (tool-result . italic))))
      (pimacs-section--create-root-section)
      (let ((parent (pimacs-section--create-section 'assistant pimacs-section--root-section
                      (insert "parent"))))
        (pimacs-section--create-section 'tool-result parent
          (insert (propertize "child" 'face 'underline)))
        (save-excursion
          (goto-char (point-min))
          (search-forward "child")
          (should (equal (get-text-property (- (point) 5) 'face)
                         '(italic underline))))))))

(ert-deftest pimacs--thinking-markdown-renderer-applies-section-face ()
  (with-temp-buffer
    (pimacs-section--create-root-section)
    (let ((pimacs-thinking-renderer #'pimacs--render-thinking-markdown))
      (pimacs-section--create-section 'thinking pimacs-section--root-section
        (pimacs--thinking-insert
         "# Heading\n**bold** and *italic* ~~strike~~ `code` [link](https://example.com)" nil))
      (cl-labels ((property-at (text property)
                    (save-excursion
                      (goto-char (point-min))
                      (search-forward text)
                      (get-text-property (- (point) (length text)) property))))
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       (concat "Heading\nbold and italic strike code link"
                               pimacs-section-padding)))
        (should (equal (property-at "Heading" 'face)
                       '(pimacs-section-thinking-face pimacs-markdown-heading-face)))
        (should (equal (property-at "bold" 'face)
                       '(pimacs-section-thinking-face pimacs-markdown-bold-face)))
        (should (eq (property-at "and" 'face) 'pimacs-section-thinking-face))
        (should (equal (property-at "italic" 'face)
                       '(pimacs-section-thinking-face pimacs-markdown-italic-face)))
        (should (equal (property-at "strike" 'face)
                       '(pimacs-section-thinking-face pimacs-markdown-strike-through-face)))
        (should (equal (property-at "code" 'face)
                       '(pimacs-section-thinking-face pimacs-markdown-inline-code-face)))
        (should (equal (property-at "link" 'face)
                       '(pimacs-section-thinking-face pimacs-markdown-link-face)))
        (should (equal (property-at "link" 'help-echo) "https://example.com"))))))

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

(ert-deftest pimacs--history-split-entries-keeps-tool-call-with-result ()
  (let* ((prefix (cl-loop for index below 9
                          collect (list :type "session_info"
                                        :name (format "name-%d" index))))
         (call '(:type "message"
                       :message (:role "assistant"
                                       :content ((:type "toolCall" :id "call-1"
                                                        :name "read" :arguments (:path "README.md"))))))
         (result '(:type "message"
                         :message (:role "toolResult" :toolCallId "call-1"
                                         :toolName "read"
                                         :content ((:type "text" :text "result")))))
         (last '(:type "message" :message (:role "user" :content "last")))
         (chunks (pimacs--history-split-entries
                  (append prefix (list call result last)))))
    (should (equal (mapcar #'length chunks) '(11 1)))
    (should (eq (nth 9 (car chunks)) call))
    (should (eq (nth 10 (car chunks)) result))))

(ert-deftest pimacs--render-session-history-progressively-inserts-history ()
  (with-temp-buffer
    (pimacs-section--create-root-section)
    (setq pimacs--tool-calls (make-hash-table :test 'equal)
          pimacs--bash-executions (make-hash-table :test 'equal)
          pimacs--content-sections (make-hash-table :test 'eql)
          pimacs--history-render-generation 0)
    (setq pimacs--prompt-widget
          (widget-create 'editable-field :format "%v" :value ""))
    (widget-setup)
    (let ((entries (cl-loop for index below 12
                            collect (list :type "message"
                                          :message (list :role "user"
                                                         :content (format "message-%d" index)))))
          (pimacs-section-padding "|")
          (pimacs-section-autohide-count 5)
          scheduled)
      (cl-letf (((symbol-function 'pimacs--history-schedule-idle-render)
                 (lambda (buffer generation)
                   (setq scheduled (list buffer generation)))))
        (pimacs--widget-save-excursion
          (pimacs--render-session-history entries))
        (should (= (length (pimacs-section-children pimacs-section--root-section)) 3))
        (should (= (pimacs--history-pending-entry-count) 10))
        (should (string-match-p "Loading history: 10 entries pending"
                                (buffer-string)))
        (pimacs--history-render-idle (current-buffer) pimacs--history-render-generation))
      (let ((roots (pimacs-section-children pimacs-section--root-section)))
        (should (= (length roots) 12))
        (should-not pimacs--history-loading-section)
        (should-not pimacs--history-render-pending)
        (should (cl-every #'pimacs-section--hidden-p (seq-take roots 7)))
        (should (cl-every #'pimacs-section--visible-p (seq-drop roots 7)))
        (should (equal (buffer-string)
                       (concat "user> message-0|user> message-1|user> message-2|"
                               "user> message-3|user> message-4|user> message-5|"
                               "user> message-6|user> message-7|user> message-8|"
                               "user> message-9|user> message-10|user> message-11|\n")))
        (should (equal scheduled
                       (list (current-buffer) pimacs--history-render-generation)))))))

(ert-deftest pimacs--render-session-history-disables-lazy-autohide-with-nil-count ()
  (with-temp-buffer
    (pimacs-section--create-root-section)
    (setq pimacs--tool-calls (make-hash-table :test 'equal)
          pimacs--bash-executions (make-hash-table :test 'equal)
          pimacs--content-sections (make-hash-table :test 'eql)
          pimacs--history-render-generation 0)
    (setq pimacs--prompt-widget
          (widget-create 'editable-field :format "%v" :value ""))
    (widget-setup)
    (let ((entries (cl-loop for index below 12
                            collect (list :type "message"
                                          :message (list :role "user"
                                                         :content (format "message-%d" index)))))
          (pimacs-section-autohide-count nil))
      (cl-letf (((symbol-function 'pimacs--history-schedule-idle-render)
                 (lambda (_buffer _generation))))
        (pimacs--widget-save-excursion
          (pimacs--render-session-history entries))
        (pimacs--history-render-idle (current-buffer) pimacs--history-render-generation))
      (let ((roots (pimacs-section-children pimacs-section--root-section)))
        (should (= (length roots) 12))
        (should (cl-every #'pimacs-section--visible-p roots))))))


;;; pimacs-tests.el ends here

