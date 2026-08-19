;;; pimacs.el --- Emacs Client for Pi -*- lexical-binding: t -*-

;; Copyright (C) 2026 Anantha Kumaran.

;; Author: Anantha kumaran <ananthakumaran@gmail.com>
;; URL: https://github.com/ananthakumaran/pimacs.el
;; Version: 0.5.0-pre
;; Keywords: convenience processes
;; Package-Requires: ((emacs "29.1") (compat "31.0") (timeout "2.1.7") (pcre2el "1.12") (spinner "1.7") (transient "0.3.7"))

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

;; This file is not part of GNU Emacs.

;;; Commentary:

;; pimacs.el provides an Emacs client for interacting with Pi, an AI coding agent.

;;; Code:

(require 'cl-lib)
(require 'compat)
(require 'project)
(require 'widget)
(require 'wid-edit)
(require 'ring)
(require 'subr-x)
(require 'parse-time)
(require 'timeout)
(require 'spinner)
(require 'pcre2el)
(require 'thingatpt)
(require 'ffap)
(require 'ansi-color)
(require 'diff-mode)
(require 'imenu)
(require 'seq)
(require 'mailcap)
(require 'transient)

(require 'pimacs-core)
(require 'pimacs-doctor)
(require 'pimacs-utils)
(autoload 'pimacs--render-markdown "pimacs-markdown")
(autoload 'pimacs--render-thinking-markdown "pimacs-markdown")
(require 'pimacs-section)
(require 'pimacs-edit)
(require 'pimacs-agent)
(require 'pimacs-state-line)
(require 'pimacs-session)

(defface pimacs-chat-role-face
  '((t :inherit font-lock-builtin-face))
  "Face used for generic chat role labels."
  :group 'pimacs)

(defface pimacs-chat-user-role-face
  '((t :inherit font-lock-keyword-face))
  "Face used for user chat message role labels."
  :group 'pimacs)

(defface pimacs-chat-assistant-role-face
  '((t :inherit font-lock-constant-face))
  "Face used for assistant chat message role labels."
  :group 'pimacs)

(defface pimacs-chat-title-face
  '((t :inherit font-lock-builtin-face))
  "Face used for titles."
  :group 'pimacs)

(defface pimacs-prompt-face
  '((t :inherit widget-field))
  "Face used for the Pimacs prompt input field."
  :group 'pimacs)

(defface pimacs-error-face
  '((t :inherit error))
  "Face used for Pimacs widget error messages."
  :group 'pimacs)

(defface pimacs-tool-name-face
  '((t :inherit font-lock-function-name-face))
  "Face used for tool names in tool execution events."
  :group 'pimacs)

(defface pimacs-grep-match-face
  '((t :inherit match))
  "Face used to highlight matching text in grep tool results."
  :group 'pimacs)

(defface pimacs-notify-info-face
  '((t :inherit font-lock-comment-face))
  "Face used for info notification messages."
  :group 'pimacs)

(defface pimacs-notify-warning-face
  '((t :inherit warning))
  "Face used for warning notification messages."
  :group 'pimacs)

(defface pimacs-notify-error-face
  '((t :inherit error))
  "Face used for error notification messages."
  :group 'pimacs)

(defface pimacs-widget-face
  '((t :inherit shadow))
  "Face used for extension widgets."
  :group 'pimacs)

(defface pimacs-status-face
  '((t :inherit shadow))
  "Face used for extension status."
  :group 'pimacs)

(defcustom pimacs-status-widget-hidden-keys nil
  "Status keys to hide from the default status widget.

Hidden statuses remain available to `(:status STATUS-KEY ...)' components
in `pimacs-header-line-format' and `pimacs-mode-line-format'.  Hover over a
status in the default widget to see its key."
  :type '(repeat string)
  :group 'pimacs)

(defcustom pimacs-file-completion-backend 'project
  "Completion backend for @-prefixed file paths in prompts.
`project' uses `project-files' to list files in the current project.
`file' uses `file-name-all-completions' to list files under the project root."
  :type '(choice (const :tag "Project files" project)
                 (const :tag "Default file system" file))
  :group 'pimacs)

(defcustom pimacs-prompt-history-max-size 500
  "Maximum number of prompt history entries to keep."
  :type 'integer
  :group 'pimacs)

(defcustom pimacs-resume-max-sessions 100
  "Maximum number of recent sessions to list when resuming a session."
  :type 'integer
  :group 'pimacs)

(defcustom pimacs-prompt-streaming-behavior 'followUp
  "Default streaming behavior for prompts.

`steer': Queue the message while the agent is running.  It is delivered
after the current assistant turn finishes executing its tool calls,
before the next LLM call.

`followUp': Wait until the agent finishes.  Message is delivered only
when agent stops."
  :type '(choice (const :tag "Follow up" followUp)
                 (const :tag "Steer" steer))
  :group 'pimacs)

(defcustom pimacs-markdown-renderer #'pimacs--render-markdown
  "Function used to render Markdown content.

Pi calls it as `(RENDERER :create)', `(RENDERER :stream STATE TEXT)',
`(RENDERER :final STATE TEXT)', and `(RENDERER :destroy STATE)'.  `:create'
returns opaque renderer state.  `:stream' and `:final' return `:append',
`:delete', and `:replace-suffix' operations.  `:destroy' releases resources.

The default uses the incremental Tree-sitter Markdown renderer.  It requires
the Markdown and Markdown Inline Tree-sitter grammars."
  :type 'function
  :group 'pimacs)

(defcustom pimacs-thinking-renderer #'pimacs--render-thinking-default
  "Function used to render assistant thinking content.

It implements the same `:create', `:stream', `:final', and `:destroy'
renderer protocol as `pimacs-markdown-renderer'.

The default preserves the legacy, dimmed plain-text rendering.  Set this to
`pimacs--render-thinking-markdown' to render thinking as Markdown."
  :type 'function
  :group 'pimacs)

(defcustom pimacs-slash-commands
  '(("model" pimacs-select-model 0 "Switch models")
    ("new" pimacs-new-session 0 "Start a new session")
    ("reload" pimacs-reload 0 "Reload extensions, skills and prompts")
    ("resume" pimacs-resume 0 "Pick from previous sessions")
    ("compact" pimacs-compact 1 "Manually compact context, optionally with custom instructions")
    ("set-auto-compaction" pimacs-set-auto-compaction 0 "Set auto compaction")
    ("set-auto-retry" pimacs-set-auto-retry 0 "Set auto retry")
    ("session" pimacs-session-stats 0 "Show session file, ID, messages, tokens, and cost")
    ("name" pimacs-set-session-name 1 "Set session display name")
    ("set-thinking-level" pimacs-set-thinking-level 0 "Set thinking level")
    ("cycle-model" pimacs-cycle-model 0 "Cycle through available models")
    ("cycle-thinking-level" pimacs-cycle-thinking-level 0 "Cycle through thinking levels")
    ("set-steering-mode" pimacs-set-steering-mode 0 "Set steering mode")
    ("set-follow-up-mode" pimacs-set-follow-up-mode 0 "Set follow-up mode")
    ("fork" pimacs-fork 0 "Create a new session from a previous user message")
    ("clone" pimacs-clone 0 "Duplicate the current active branch into a new session")
    ("copy" pimacs-copy 0 "Copy last assistant message to clipboard")
    ("export" pimacs-export 1 "Export session to HTML")
    ("quit" pimacs-quit-chat 0 "Quit pimacs")
    ("exit" pimacs-quit-chat 0 "Quit pimacs"))
  "Alist mapping slash command names to command specs.

Each entry is (NAME COMMAND MAX-ARGS DESCRIPTION) where NAME is the command
string without the leading slash, COMMAND is a command symbol,
MAX-ARGS is 0 or 1 indicating the number of optional string
arguments the command accepts, and DESCRIPTION is a short
description string."
  :type '(repeat (list string symbol integer string))
  :group 'pimacs)

(defcustom pimacs-insert-tool-args-functions
  '(("read" . pimacs--insert-read-args)
    ("write" . pimacs--insert-write-args)
    ("edit" . pimacs--insert-edit-args)
    ("bash" . pimacs--insert-bash-args)
    ("grep" . pimacs--insert-grep-args)
    ("find" . pimacs--insert-find-args)
    ("ls" . pimacs--insert-ls-args))
  "Alist mapping tool names to inserter functions.

Each entry is (TOOL-NAME . FUNCTION) where FUNCTION is called
with ARGS plist to insert formatted tool call arguments."
  :type '(alist :key-type string :value-type function)
  :group 'pimacs)

(defcustom pimacs-insert-tool-result-functions
  '(("bash" . pimacs--insert-bash-result)
    ("read" . pimacs--insert-read-result)
    ("write" . pimacs--insert-write-result)
    ("edit" . pimacs--insert-edit-result)
    ("grep" . pimacs--insert-grep-result)
    ("find" . pimacs--insert-find-result)
    ("ls" . pimacs--insert-ls-result))
  "Alist mapping tool names to result inserter functions.

Each entry is (TOOL-NAME . FUNCTION) where FUNCTION is called
with (CONTENT DETAILS ARGS) to insert the tool execution result.
CONTENT is a list of content items.  Use `pimacs--insert-content' to render
it, or `pimacs--content-text' to extract text from content."
  :type '(alist :key-type string :value-type function)
  :group 'pimacs)

(defcustom pimacs-visit-tool-result-functions
  '(("read" . pimacs--visit-read-result)
    ("write" . pimacs--visit-write-result)
    ("edit" . pimacs--visit-edit-result)
    ("grep" . pimacs--visit-grep-result))
  "Alist mapping tool names to result visitor functions.

Each entry is (TOOL-NAME . FUNCTION) where FUNCTION is called
with (DETAILS ARGS) to visit the relevant location of the tool result."
  :type '(alist :key-type string :value-type function)
  :group 'pimacs)

(defcustom pimacs-visit-tool-call-functions
  '(("read" . pimacs--visit-read-call)
    ("write" . pimacs--visit-write-call)
    ("edit" . pimacs--visit-edit-call))
  "Alist mapping tool names to call visitor functions.

Each entry is (TOOL-NAME . FUNCTION) where FUNCTION is called
with (ARGS) to visit the relevant location of the tool call."
  :type '(alist :key-type string :value-type function)
  :group 'pimacs)

(defcustom pimacs-insert-custom-message-functions '()
  "Alist mapping custom message types to inserter functions.

Each entry is (CUSTOM-TYPE . FUNCTION) where FUNCTION is called
with the message plist to insert the custom message content."
  :type '(alist :key-type string :value-type function)
  :group 'pimacs)

(defcustom pimacs-send-pop-to-chat t
  "Whether to pop to the chat buffer after sending region, filename or errors."
  :type 'boolean
  :group 'pimacs)

(defcustom pimacs-chat-keep-input-at-bottom t
  "Whether to keep the input area at the bottom as new chat content is added."
  :type 'boolean
  :group 'pimacs)

(defvar-local pimacs--project-file-cache nil)

(defun pimacs-clear-project-file-cache ()
  "Clear the project file cache."
  (interactive)
  (setq pimacs--project-file-cache nil))

;;; Widget

(defconst pimacs--empty-widget-text (propertize " " 'invisible t))

(defun pimacs--widget-item-value-create (widget)
  (let* ((raw-value (widget-get widget :value))
         (value (pimacs--apply-ansi-colors raw-value)))
    (if pimacs-use-ansi-colors
        (insert value)
      (insert (propertize value
                          'face
                          (widget-get widget :face))))))

(define-widget 'pimacs-item 'item
  "Item widget with font face support."
  :value-create #'pimacs--widget-item-value-create
  :format "%v")

(defun pimacs--widget-end-if-inside (widget)
  "Move to end of text field if point is inside WIDGET."
  (when (and (<= (widget-get widget :from) (point))
             (<= (point) (widget-get widget :to)))
    (goto-char (widget-field-text-end widget))
    (when-let (window (get-buffer-window (current-buffer) t))
      (set-window-point window (widget-field-text-end widget)))))

(defmacro pimacs--on-response-success (response &rest body)
  (declare (indent 1))
  (let ((resp-sym (gensym "resp")))
    `(let ((,resp-sym ,response))
       (if (pimacs--response-success-p ,resp-sym)
           (progn ,@body)
         (when-let (err (plist-get ,resp-sym :error))
           (pimacs--widget-save-excursion
             (pimacs-section--create-section 'error pimacs-section--root-section
               (pimacs--insert-error (format "%s" err))))
           nil)))))

(defmacro pimacs--on-response-success-callback (response &rest body)
  (declare (indent 1))
  `(lambda (,response)
     (pimacs--on-response-success ,response
       ,@body)))

(defmacro pimacs--unless-cancelled (resp operation &rest body)
  (declare (indent 2))
  `(let ((cancelled (plist-get (plist-get ,resp :data) :cancelled)))
     (if (eq cancelled t)
         (pimacs--widget-save-excursion
           (pimacs-section--create-section 'error pimacs-section--root-section
             (pimacs--insert-error (format "%s cancelled." ,operation))))
       ,@body)))

;;; State management

(cl-defstruct pimacs-tool-call
  call-section result-section prev-text tool-name args)

(cl-defstruct pimacs-content-section
  section content)

(cl-defstruct pimacs--renderer-session
  renderer
  state
  destroyed)

(cl-defstruct pimacs--rendered-content
  context
  renderer-session)

(defconst pimacs--history-chunk-size 10)
(defconst pimacs--history-idle-delay 0.5)

(cl-defstruct pimacs-render-context
  content-begin
  content-end
  rendered-length)

(defun pimacs--render-create-context ()
  (let ((content-begin (point-marker))
        (content-end (point-marker)))
    (make-pimacs-render-context
     :content-begin content-begin
     :content-end content-end
     :rendered-length 0)))

(defun pimacs--render-replace-suffix (context count text)
  (unless (and (integerp count) (>= count 0))
    (error "Renderer replace-suffix operation requires a non-negative integer: %S" count))
  (unless (stringp text)
    (error "Renderer replace-suffix operation requires a string: %S" text))
  (let* ((content-begin (pimacs-render-context-content-begin context))
         (content-end (pimacs-render-context-content-end context))
         (end-position (marker-position content-end)))
    (when (> count (- end-position (marker-position content-begin)))
      (error "Renderer replace-suffix operation exceeds the content range: %S" count))
    (let* ((start-position (- end-position count))
           (prefix-length
            (pimacs--buffer-string-common-prefix-length
             (current-buffer) start-position end-position text))
           (replacement-start (+ start-position prefix-length)))
      (delete-region replacement-start end-position)
      (goto-char replacement-start)
      (insert (substring text prefix-length))
      (set-marker content-end (point))
      (cl-incf (pimacs-render-context-rendered-length context)
               (- (length text) count)))))

(defun pimacs--render-apply-operations (context operations)
  (dolist (operation operations)
    (pcase operation
      (`(:append ,text . ,_)
       (unless (stringp text)
         (error "Renderer append operation requires a string: %S" operation))
       (goto-char (pimacs-render-context-content-end context))
       (let ((start (point))
             (buffer (current-buffer))
             (after-insert (plist-get (cddr operation) :after-insert))
             (data (plist-get (cddr operation) :data)))
         (insert text)
         (set-marker (pimacs-render-context-content-end context) (point))
         (cl-incf (pimacs-render-context-rendered-length context) (length text))
         (when after-insert
           (unless (and (symbolp after-insert) (fboundp after-insert))
             (error "Renderer after-insert hook must be a function symbol: %S" operation))
           (let ((size (buffer-size)))
             (with-current-buffer buffer
               (funcall after-insert start (point) data))
             (unless (= size (buffer-size))
               (error "Renderer after-insert hook modified the buffer: %S" operation))))))
      (`(:delete ,count)
       (unless (and (integerp count) (>= count 0))
         (error "Renderer delete operation requires a non-negative integer: %S" operation))
       (let* ((content-begin (pimacs-render-context-content-begin context))
              (content-end (pimacs-render-context-content-end context))
              (end-position (marker-position content-end)))
         (when (> count (- end-position (marker-position content-begin)))
           (error "Renderer delete operation exceeds the content range: %S" operation))
         (delete-region (- end-position count) end-position)
         (set-marker content-end (- end-position count))
         (cl-decf (pimacs-render-context-rendered-length context) count)))
      (`(:replace-suffix ,count ,text)
       (pimacs--render-replace-suffix context count text))
      (_
       (error "Unknown Markdown operation: %S" operation)))))

(defun pimacs--renderer-create (renderer)
  (make-pimacs--renderer-session
   :renderer renderer
   :state (funcall renderer :create)
   :destroyed nil))

(defun pimacs--renderer-destroy (session)
  (unless (pimacs--renderer-session-destroyed session)
    (unwind-protect
        (funcall (pimacs--renderer-session-renderer session)
                 :destroy (pimacs--renderer-session-state session))
      (setf (pimacs--renderer-session-state session) nil
            (pimacs--renderer-session-destroyed session) t))))

(defun pimacs--renderer-render (session text streaming)
  (when (pimacs--renderer-session-destroyed session)
    (error "Renderer session is already destroyed"))
  (if streaming
      (funcall (pimacs--renderer-session-renderer session)
               :stream (pimacs--renderer-session-state session) text)
    (unwind-protect
        (funcall (pimacs--renderer-session-renderer session)
                 :final (pimacs--renderer-session-state session) text)
      (pimacs--renderer-destroy session))))

(defun pimacs--render-create-content (renderer)
  (make-pimacs--rendered-content
   :context (pimacs--render-create-context)
   :renderer-session (pimacs--renderer-create renderer)))

(defun pimacs--render-insert (renderer text streaming)
  (let* ((content (pimacs--render-create-content renderer))
         (context (pimacs--rendered-content-context content)))
    (pimacs--render-apply-operations
     context
     (pimacs--renderer-render
      (pimacs--rendered-content-renderer-session content) text streaming))
    content))

(defun pimacs--render-clear-content (content)
  (pimacs--renderer-destroy (pimacs--rendered-content-renderer-session content))
  (let ((context (pimacs--rendered-content-context content)))
    (set-marker (pimacs-render-context-content-begin context) nil)
    (set-marker (pimacs-render-context-content-end context) nil)))

(defun pimacs--insert-rendered-content (operations)
  (let ((context (pimacs--render-create-context)))
    (unwind-protect
        (pimacs--render-apply-operations context operations)
      (set-marker (pimacs-render-context-content-begin context) nil)
      (set-marker (pimacs-render-context-content-end context) nil))))

(defun pimacs--render-content-update (content text streaming)
  (pimacs--renderer-render
   (pimacs--rendered-content-renderer-session content) text streaming))

(defun pimacs--thinking-insert (text streaming)
  (pimacs--render-insert pimacs-thinking-renderer text streaming))

(pimacs--def-permanent-buffer-local pimacs--prompt-widget nil)
(pimacs--def-permanent-buffer-local pimacs--attached-images (vector))
(pimacs--def-permanent-buffer-local pimacs--attached-images-widget nil)
(pimacs--def-permanent-buffer-local pimacs--prompt-before-widget nil)
(pimacs--def-permanent-buffer-local pimacs--prompt-after-widget nil)
(pimacs--def-permanent-buffer-local pimacs--prompt-widget-lines nil)
(pimacs--def-permanent-buffer-local pimacs--status-widget nil)
(pimacs--def-permanent-buffer-local pimacs--content-sections nil)
(pimacs--def-permanent-buffer-local pimacs--tool-calls nil)
(pimacs--def-permanent-buffer-local pimacs--bash-executions nil)
(pimacs--def-permanent-buffer-local pimacs--cleanup-callback-fn nil)
(pimacs--def-permanent-buffer-local pimacs--retry-in-progress nil)
(pimacs--def-permanent-buffer-local pimacs--commands nil)

(pimacs--def-permanent-buffer-local pimacs--history-render-pending nil)
(pimacs--def-permanent-buffer-local pimacs--history-render-timer nil)
(pimacs--def-permanent-buffer-local pimacs--history-render-generation 0)
(pimacs--def-permanent-buffer-local pimacs--history-loading-section nil)
(pimacs--def-permanent-buffer-local pimacs--history-render-boundary nil)

;;; History

(pimacs--def-permanent-buffer-local pimacs--prompt-history nil)
(pimacs--def-permanent-buffer-local pimacs--prompt-history-index 0)

(defun pimacs-previous-prompt ()
  "Navigate to the previous prompt in history."
  (interactive)
  (let ((len (ring-length pimacs--prompt-history)))
    (when (< pimacs--prompt-history-index len)
      (cl-incf pimacs--prompt-history-index)
      (widget-value-set pimacs--prompt-widget
                        (ring-ref pimacs--prompt-history (- pimacs--prompt-history-index 1))))))

(defun pimacs-next-prompt ()
  "Navigate to the next prompt in history."
  (interactive)
  (cond
   ((> pimacs--prompt-history-index 1)
    (cl-decf pimacs--prompt-history-index)
    (widget-value-set pimacs--prompt-widget
                      (ring-ref pimacs--prompt-history (1- pimacs--prompt-history-index))))
   ((= pimacs--prompt-history-index 1)
    (setq pimacs--prompt-history-index 0)
    (widget-value-set pimacs--prompt-widget ""))))

(defun pimacs-search-prompt ()
  "Search prompt history and select an entry."
  (interactive)
  (let ((items (ring-elements pimacs--prompt-history)))
    (if (null items)
        (message "No prompt history")
      (let ((selected (completing-read "Search prompt: " items nil t)))
        (widget-value-set pimacs--prompt-widget selected)
        (setq pimacs--prompt-history-index 0)
        (pimacs-focus-prompt)))))

(defun pimacs--chat-buffer-name (&optional title)
  (if title
      (format "*pimacs-chat:%s:%s*" (pimacs--project-name) title)
    (format "*pimacs-chat:%s*" (pimacs--project-name))))

(defun pimacs--recenter-chat ()
  (when-let ((window (and pimacs-chat-keep-input-at-bottom
                          (get-buffer-window (current-buffer) t))))
    (with-selected-window window
      (recenter (min -2
                     (- -1 scroll-margin
                        (pimacs--widget-lines pimacs--prompt-widget)
                        (pimacs--extra-widget-lines)))))))

(defun pimacs--point-in-prompt-p ()
  (when-let (window (get-buffer-window (current-buffer) t))
    (>= (window-point window)
        (widget-get pimacs--prompt-widget :from))))

(defmacro pimacs--widget-save-excursion (&rest body)
  "Insert before PROMPT-WIDGET and restore focus.  BODY is the content."
  (declare (indent 0))
  `(let* ((inhibit-read-only t)
          (follow-p (pimacs--point-in-prompt-p)))
     (save-excursion
       (goto-char (widget-get pimacs--prompt-widget :from))
       ,@body)
     (when follow-p
       (pimacs--recenter-chat))))

(defmacro pimacs--with-chat-buffer (&rest body)
  "Execute BODY in the current chat buffer."
  (declare (indent 0))
  `(let ((buffer (or (pimacs--current-chat)
                     (pimacs--select-relevant-chat))))
     (if buffer
         (with-current-buffer buffer
           (progn ,@body))
       (error "Chat doesn't exist, start a new chat using M-x pimacs-chat"))))

;;; Completion

(defun pimacs--project-file-completions (_prefix)
  (or pimacs--project-file-cache
      (when-let (project (project-current))
        (let ((default-directory (pimacs--project-root))
              (project-files-relative-names t))
          (setq pimacs--project-file-cache (project-files project))))))

(defun pimacs--native-file-completions (prefix)
  (let* ((dir (or (file-name-directory prefix) ""))
         (file (file-name-nondirectory prefix))
         (full-dir (expand-file-name dir (pimacs--project-root))))
    (when (file-directory-p full-dir)
      (let ((candidates (file-name-all-completions file full-dir)))
        (mapcar (lambda (c) (concat dir c)) candidates)))))

(defun pimacs--completion-at-point-file ()
  (let ((end (point)))
    (save-excursion
      (when (re-search-backward "@\\([^\t\n ]*\\)" (line-beginning-position) t)
        (let* ((start (match-beginning 1))
               (prefix (match-string 1))
               (completions
                (if (eq pimacs-file-completion-backend 'project)
                    (pimacs--project-file-completions prefix)
                  (pimacs--native-file-completions prefix))))
          (when completions
            (list start end completions :category 'file :company-prefix-length t)))))))

(defun pimacs--completion-at-point-slash ()
  (let ((end (point)))
    (save-excursion
      (when (re-search-backward "\\([ \t]*\\)/\\([-a-zA-Z0-9]*\\)" (line-beginning-position) t)
        (let* ((match-start (match-beginning 0))
               (cmd-start (match-beginning 2))
               (slash-names (mapcar #'car pimacs-slash-commands))
               (command-names (mapcar #'car pimacs--commands))
               (all-names (append slash-names command-names)))
          (when (string-match "^user>[ \t]*$" (buffer-substring-no-properties (widget-get pimacs--prompt-widget :from) match-start))
            (list cmd-start end all-names
                  :company-prefix-length t
                  :annotation-function
                  (lambda (c)
                    (cond
                     ((member c slash-names) "(emacs)")
                     (pimacs--commands
                      (when-let ((cmd (assoc c pimacs--commands #'string=)))
                        (format "(%s)" (plist-get (cdr cmd) :source))))))
                  :company-docsig
                  (lambda (c)
                    (cond
                     ((member c slash-names)
                      (when-let ((command (assoc c pimacs-slash-commands #'string=)))
                        (nth 3 command)))
                     (pimacs--commands
                      (when-let ((cmd (assoc c pimacs--commands #'string=)))
                        (plist-get (cdr cmd) :description))))))))))))

;;; Chat

(defun pimacs--message-role (message)
  (or (plist-get message :role) "unknown"))

(defun pimacs--content-text (content)
  (let ((content (pimacs--content-normalize content)))
    (mapconcat
     (lambda (item)
       (if (equal (plist-get item :type) "text")
           (or (plist-get item :text) "")
         ""))
     content
     "")))

(defun pimacs--content-normalize (content)
  (if (stringp content)
      (list (list :type "text" :text content))
    content))

(defmacro pimacs--docontent (spec &rest body)
  (declare (indent 1) (debug ((symbolp form) body)))
  (let ((content (make-symbol "content")))
    `(let ((,content ,(nth 1 spec)))
       (dolist (,(car spec) (pimacs--content-normalize ,content))
         ,@body))))

(defun pimacs--content-header (content)
  (let ((content (pimacs--content-normalize content)))
    (when-let ((item (cl-find-if (lambda (i)
                                   (member (plist-get i :type) '("text" "thinking")))
                                 content)))
      (pimacs--section-header (or (plist-get item :text)
                                  (plist-get item :thinking))))))

(defun pimacs--insert-content-item (item &optional markdown-p)
  (pcase (plist-get item :type)
    ("text"
     (if markdown-p
         (pimacs--render-insert pimacs-markdown-renderer (plist-get item :text) nil)
       (insert (plist-get item :text))))
    ("image"
     (when-let ((image (pimacs--create-image item)))
       (insert "\n")
       (insert-image image)
       (insert "\n")))
    ("thinking"
     (pimacs--thinking-insert (plist-get item :thinking) nil))
    (_
     (insert (prin1-to-string item)))))

(defun pimacs--insert-content (content &optional markdown-p)
  (pimacs--docontent (item content)
    (pimacs--insert-content-item item markdown-p)))

(defun pimacs--insert-user-message (content)
  (pimacs--widget-save-excursion
    (let ((section (pimacs-section--create-section 'user pimacs-section--root-section
                     (pimacs--insert-role-prefix "user")
                     (pimacs--insert-content content))))
      (pimacs-section--set-info section (make-pimacs-section-user-info
                                         :header (pimacs--content-header content)
                                         :content content)))))

(defvar pimacs--image-type-alist
  '(("image/png" . png)
    ("image/jpeg" . jpeg)
    ("image/gif" . gif)
    ("image/webp" . webp))
  "Alist mapping MIME type strings to image type symbols.")

(defun pimacs--create-image (item)
  (when (display-images-p)
    (when-let ((data (plist-get item :data))
               (mime-type (plist-get item :mimeType))
               (image-type (pimacs--alist-get-equal mime-type pimacs--image-type-alist))
               (raw-data (base64-decode-string data))
               (max-width (floor (* 0.9 (window-pixel-width))))
               (max-height (floor (* 0.9 (window-pixel-height)))))
      (create-image raw-data image-type t
                    :max-width max-width
                    :max-height max-height))))

(defun pimacs--role-face (role)
  (pcase role
    ("user" 'pimacs-chat-user-role-face)
    ("assistant" 'pimacs-chat-assistant-role-face)
    (_ 'pimacs-chat-role-face)))

(defun pimacs--insert-role-prefix (role)
  (pimacs-section--insert-chrome (format "%s> " role)
                                 (pimacs--role-face role)))

(defun pimacs--insert-tool-name (tool-name)
  (pimacs-section--insert-chrome (format "%s " tool-name)
                                 'pimacs-tool-name-face))

(defun pimacs--extract-truncation-notice (result-text)
  (if (string-match "\n\\(\\[[^]]* Use \\(?:offset=[^]]* to [Cc]ontinue\\|bash: [^]]*\\)\\.?\\]\\)$" result-text)
      (cons (replace-match "" nil nil result-text)
            (match-string 1 result-text))
    (cons result-text nil)))

(defun pimacs--insert-model-change (provider model-id)
  (pimacs-section--create-section 'model pimacs-section--root-section
    (insert (format "Switched to model: (%s) %s" provider model-id))))

(defun pimacs--insert-thinking-level-change (level)
  (pimacs-section--create-section 'thinking-level pimacs-section--root-section
    (insert (format "Thinking level set to: %s" level))))

(defun pimacs--insert-compaction (summary tokens-before)
  (let ((header (format "**Compacted from %s tokens**\n"
                        (pimacs--format-number-short tokens-before))))
    (pimacs-section--create-section 'compact pimacs-section--root-section
      (pimacs--insert-role-prefix "assistant")
      (pimacs--render-insert pimacs-markdown-renderer (concat header summary) nil))))

(defun pimacs--insert-session-info (name)
  (pimacs-section--create-section 'info pimacs-section--root-section
    (insert (format "Session renamed to: %s" name))))

(defun pimacs--insert-custom-message (message)
  (let ((display (plist-get message :display))
        (custom-type (plist-get message :customType)))
    (unless (eq display 'json-false)
      (if-let ((inserter (pimacs--alist-get-equal custom-type pimacs-insert-custom-message-functions)))
          (funcall inserter message)
        ;; Default rendering: use customType as role, render content
        (pimacs--widget-save-excursion
          (pimacs-section--create-section 'custom pimacs-section--root-section
            (pimacs--insert-role-prefix (or custom-type "custom"))
            (pimacs--insert-content (plist-get message :content) t)))))))

(defun pimacs--insert-message (message)
  (pcase (pimacs--message-role message)
    ("user"
     (pimacs--insert-user-message (plist-get message :content)))

    ("assistant"
     (pimacs--docontent (item (plist-get message :content))
       (pcase (plist-get item :type)
         ("thinking"
          (let ((content (list item)))
            (pimacs--widget-save-excursion
              (let ((section (pimacs-section--create-section 'thinking pimacs-section--root-section
                               (pimacs--insert-role-prefix "assistant")
                               (pimacs--insert-content content))))
                (pimacs-section--set-info section (make-pimacs-section-assistant-info
                                                   :header (pimacs--content-header content)
                                                   :content content
                                                   :type 'thinking))))))
         ("text"
          (let ((content (list item)))
            (pimacs--widget-save-excursion
              (let ((section (pimacs-section--create-section 'assistant pimacs-section--root-section
                               (pimacs--insert-role-prefix "assistant")
                               (pimacs--insert-content content t))))
                (pimacs-section--set-info section (make-pimacs-section-assistant-info
                                                   :header (pimacs--content-header content)
                                                   :content content
                                                   :type 'text))))))
         ("toolCall"
          (let ((tool-call-id (plist-get item :id))
                (tool-name (plist-get item :name))
                (args (plist-get item :arguments)))
            (pimacs--widget-save-excursion
              (let ((call-section (pimacs-section--new-section 'tool-call pimacs-section--root-section :padding "\n")))
                (pimacs--insert-tool-call call-section tool-name args)
                (let ((result-section (pimacs-section--new-section 'tool-result call-section)))
                  (pimacs-section--insert-section result-section)
                  (puthash tool-call-id
                           (make-pimacs-tool-call
                            :call-section call-section
                            :result-section result-section
                            :prev-text ""
                            :tool-name tool-name
                            :args args)
                           pimacs--tool-calls)))))))))
    ("toolResult"
     (let ((tool-call-id (plist-get message :toolCallId))
           (tool-name (plist-get message :toolName))
           (content (pimacs--content-normalize (plist-get message :content)))
           (is-error (plist-get message :isError))
           (details (plist-get message :details)))
       (when-let ((entry (gethash tool-call-id pimacs--tool-calls)))
         (let ((result-section (pimacs-tool-call-result-section entry))
               (args (pimacs-tool-call-args entry)))
           (pimacs--widget-save-excursion
             (pimacs-section--replace-section result-section
               (pimacs--insert-tool-result tool-name content is-error details args))
             (pimacs-section--set-info result-section (make-pimacs-section-tool-result-info :tool-name tool-name :details details :args args))))
         (remhash tool-call-id pimacs--tool-calls))))

    ("bashExecution"
     (let* ((args (list :command (plist-get message :command)))
            (content (pimacs--content-normalize (plist-get message :output))))
       (pimacs--widget-save-excursion
         (let* ((call-section (pimacs-section--new-section 'tool-call pimacs-section--root-section :padding "\n"))
                (result-section (pimacs-section--new-section 'tool-result call-section)))
           (pimacs--insert-tool-call call-section "bash" args)
           (pimacs-section--insert-section result-section
             (pimacs--insert-tool-result "bash" content nil message))
           (pimacs-section--set-info result-section (make-pimacs-section-tool-result-info :tool-name "bash" :details nil :args args))))))

    ("custom"
     (pimacs--insert-custom-message message))))

(defun pimacs--handle-message-update (event)
  (let* ((assistant-message-event (plist-get event :assistantMessageEvent))
         (event-type (plist-get assistant-message-event :type))
         (delta (plist-get assistant-message-event :delta))
         (content-index (plist-get assistant-message-event :contentIndex)))
    (pcase event-type
      ("thinking_delta"
       (unless (string-empty-p delta)
         (pimacs--widget-save-excursion
           (if-let ((content-section (gethash content-index pimacs--content-sections)))
               (pimacs-section--append-section (pimacs-content-section-section content-section)
                 (let ((content (pimacs-content-section-content content-section)))
                   (pimacs--render-apply-operations
                    (pimacs--rendered-content-context content)
                    (pimacs--render-content-update content delta t))))
             (let ((section (pimacs-section--new-section 'thinking pimacs-section--root-section))
                   content)
               (pimacs-section--insert-section section
                 (pimacs--insert-role-prefix "assistant")
                 (setq content (pimacs--thinking-insert delta t)))
               (puthash content-index
                        (make-pimacs-content-section
                         :section section
                         :content content)
                        pimacs--content-sections))))))
      ("text_delta"
       (unless (string-empty-p delta)
         (pimacs--widget-save-excursion
           (if-let ((content-section (gethash content-index pimacs--content-sections)))
               (pimacs-section--append-section (pimacs-content-section-section content-section)
                 (let ((content (pimacs-content-section-content content-section)))
                   (pimacs--render-apply-operations
                    (pimacs--rendered-content-context content)
                    (pimacs--render-content-update content delta t))))
             (let ((section (pimacs-section--new-section 'assistant pimacs-section--root-section))
                   content)
               (pimacs-section--insert-section section
                 (pimacs--insert-role-prefix "assistant")
                 (setq content (pimacs--render-insert pimacs-markdown-renderer delta t)))
               (puthash content-index
                        (make-pimacs-content-section
                         :section section
                         :content content)
                        pimacs--content-sections))))))
      ("toolcall_end"
       (let* ((tool-call (plist-get assistant-message-event :toolCall))
              (tool-call-id (plist-get tool-call :id))
              (tool-name (plist-get tool-call :name))
              (args (plist-get tool-call :arguments)))
         (pimacs--widget-save-excursion
           (let ((call-section (pimacs-section--new-section 'tool-call pimacs-section--root-section :padding "\n")))
             (pimacs--insert-tool-call call-section tool-name args)
             (let ((result-section (pimacs-section--new-section 'tool-result call-section)))
               (pimacs-section--insert-section result-section)
               (puthash tool-call-id
                        (make-pimacs-tool-call
                         :call-section call-section
                         :result-section result-section
                         :prev-text ""
                         :tool-name tool-name
                         :args args)
                        pimacs--tool-calls)))))))))

(defun pimacs--message-update-mergeable-p (first second)
  (let ((first-event (plist-get first :assistantMessageEvent))
        (second-event (plist-get second :assistantMessageEvent)))
    (and (member (plist-get first-event :type) '("thinking_delta" "text_delta"))
         (equal (plist-get first-event :type) (plist-get second-event :type))
         (equal (plist-get first-event :contentIndex) (plist-get second-event :contentIndex))
         (stringp (plist-get first-event :delta))
         (stringp (plist-get second-event :delta)))))

(defun pimacs--merge-message-updates (events)
  (let (merged-events)
    (dolist (event events)
      (if (and merged-events
               (pimacs--message-update-mergeable-p (car merged-events) event))
          (let* ((merged-event (copy-sequence (car merged-events)))
                 (assistant-message-event
                  (copy-sequence (plist-get merged-event :assistantMessageEvent))))
            (setf (plist-get assistant-message-event :delta)
                  (concat (plist-get assistant-message-event :delta)
                          (plist-get (plist-get event :assistantMessageEvent) :delta)))
            (setf (plist-get merged-event :assistantMessageEvent) assistant-message-event)
            (setcar merged-events merged-event))
        (push event merged-events)))
    (nreverse merged-events)))

(defun pimacs--handle-message-update-batch (events)
  (dolist (event (pimacs--merge-message-updates events))
    (pimacs--handle-message-update event)))

(defun pimacs--handle-message-end (event)
  (let* ((message (plist-get event :message))
         (error-message (plist-get message :errorMessage))
         (role (pimacs--message-role message)))
    (pcase role
      ("assistant"
       (let ((index 0))
         (pimacs--docontent (item (plist-get message :content))
           (pcase (plist-get item :type)
             ("thinking"
              (let* ((content (list item))
                     (content-section (gethash index pimacs--content-sections))
                     (rendered-content (and content-section
                                            (pimacs-content-section-content content-section)))
                     (operations (and rendered-content
                                      (pimacs--render-content-update
                                       rendered-content (plist-get item :thinking) nil))))
                (when rendered-content
                  (pimacs--render-clear-content rendered-content))
                (pimacs--widget-save-excursion
                  (let ((section
                         (pimacs-section--create-or-replace-section
                             (and content-section
                                  (pimacs-content-section-section content-section))
                             'thinking
                             pimacs-section--root-section
                           (pimacs--insert-role-prefix role)
                           (if rendered-content
                               (pimacs--insert-rendered-content operations)
                             (pimacs--insert-content content)))))
                    (pimacs-section--set-info section (make-pimacs-section-assistant-info
                                                       :header (pimacs--content-header content)
                                                       :content content
                                                       :type 'thinking))))))
             ("text"
              (let* ((content (list item))
                     (content-section (gethash index pimacs--content-sections))
                     (rendered-content (and content-section
                                            (pimacs-content-section-content content-section)))
                     (operations (and rendered-content
                                      (pimacs--render-content-update
                                       rendered-content (plist-get item :text) nil))))
                (when rendered-content
                  (pimacs--render-clear-content rendered-content))
                (pimacs--widget-save-excursion
                  (let ((section
                         (pimacs-section--create-or-replace-section
                             (and content-section
                                  (pimacs-content-section-section content-section))
                             'assistant
                             pimacs-section--root-section
                           (pimacs--insert-role-prefix role)
                           (if rendered-content
                               (pimacs--insert-rendered-content operations)
                             (pimacs--insert-content content t)))))
                    (pimacs-section--set-info section (make-pimacs-section-assistant-info
                                                       :header (pimacs--content-header content)
                                                       :content content
                                                       :type 'text)))))))
           (setq index (1+ index))))
       ;; Cleanup tracking state
       (clrhash pimacs--content-sections))
      ("user"
       (pimacs--insert-user-message (plist-get message :content)))
      ("custom"
       (pimacs--insert-custom-message message)))
    (when (and error-message (not (string-empty-p error-message)))
      (pimacs--widget-save-excursion
        (pimacs-section--create-section 'error pimacs-section--root-section
          (pimacs--insert-error error-message))))))

;; read
(defun pimacs--insert-read-args (args)
  (when-let ((path (plist-get args :path)))
    (let* ((offset (plist-get args :offset))
           (limit (plist-get args :limit))
           (start-line (or offset 1))
           (suffix (cond
                    ((and (null offset) (null limit)) "")
                    ((null limit) (format ":%d" start-line))
                    (t (let ((end-line (+ start-line limit -1)))
                         (format ":%d-%d" start-line end-line))))))
      (pimacs--insert-file-link (expand-file-name path (pimacs--project-root)) suffix))))

(defun pimacs--insert-read-result (content _details args)
  (when-let ((path (plist-get args :path)))
    (dolist (item content)
      (pcase (plist-get item :type)
        ("text"
         (let ((text (plist-get item :text)))
           (when (not (string-empty-p text))
             (pcase-let ((`(,clean-text . ,truncated-line) (pimacs--extract-truncation-notice text)))
               (insert (pimacs--render-content (expand-file-name path (pimacs--project-root)) clean-text))
               (when truncated-line
                 (insert truncated-line))))))
        ("image"
         (when-let ((image (pimacs--create-image item)))
           (insert "\n")
           (insert-image image)
           (insert "\n")))))))

(defun pimacs--visit-read-result (_details args)
  (when-let ((path (plist-get args :path)))
    (let ((section-line (pimacs-section--section-line)))
      (list :file (expand-file-name path (pimacs--project-root))
            :line (+ (or (plist-get args :offset) 1) section-line)
            :column (- (point) (line-beginning-position))))))

(defun pimacs--visit-read-call (args)
  (when-let ((path (plist-get args :path)))
    (list :file (expand-file-name path (pimacs--project-root))
          :line (or (plist-get args :offset) 1))))

;; write
(defun pimacs--insert-write-args (args)
  (when-let ((path (plist-get args :path))
             (content (plist-get args :content)))
    (pimacs--insert-file-link (expand-file-name path (pimacs--project-root)))
    (when (not (string-empty-p content))
      (insert "\n")
      (insert (pimacs--render-content path content)))))

(defun pimacs--insert-write-result (content _details _args)
  (pimacs--insert-content content))

(defun pimacs--visit-write-result (_details args)
  (when-let ((path (plist-get args :path)))
    (list :file (expand-file-name path (pimacs--project-root)))))

(defun pimacs--visit-write-call (args)
  (when-let ((path (plist-get args :path)))
    (let ((section-line (pimacs-section--section-line)))
      (list :file (expand-file-name path (pimacs--project-root))
            :line (max 1 section-line)
            :column (if (zerop section-line)
                        0
                      (- (point) (line-beginning-position)))))))

;; edit
(defun pimacs--insert-edit-args (args)
  (when-let ((path (plist-get args :path)))
    (pimacs--insert-file-link (expand-file-name path (pimacs--project-root)))))

(defun pimacs--insert-edit-result (content details _args)
  (when-let ((patch (or (plist-get details :patch)
                        (plist-get details :diff))))
    (insert (pimacs--render-diff patch)))
  (let ((text (pimacs--content-text content)))
    (when (not (string-empty-p text))
      (insert (format "\n\n%s" text)))))

(defun pimacs--visit-edit-call (args)
  (when-let ((path (plist-get args :path)))
    (list :file (expand-file-name path (pimacs--project-root)) :line 1)))

(defun pimacs--visit-edit-result (_details args)
  (when-let ((path (plist-get args :path)))
    (let* ((section (pimacs-section--current-section))
           (reverse (not (save-excursion (beginning-of-line) (looking-at "[-<]"))))
           (location
            (save-restriction
              (narrow-to-region (pimacs-section-beginning section)
                                (pimacs-section-end section))
              (condition-case nil
                  (pcase-let ((`(,buffer ,_line-offset ,pos ,src ,_dst ,_switched)
                               (diff-find-source-location nil reverse)))
                    (with-current-buffer buffer
                      (let ((visit-pos (+ (car pos) (cdr src))))
                        (save-excursion
                          (goto-char visit-pos)
                          (list :line (line-number-at-pos)
                                :column (- visit-pos (line-beginning-position)))))))
                (error nil)))))
      (list :file (expand-file-name path (pimacs--project-root))
            :line (or (plist-get location :line) 1)
            :column (plist-get location :column)))))

;; bash
(defun pimacs--insert-bash-args (args)
  (when-let ((command (plist-get args :command)))
    (insert (pimacs--render-content "tmp.sh" command))))

(defun pimacs--insert-bash-result (content details _args)
  (let* ((exit-code (plist-get details :exitCode))
         (cancelled (plist-get details :cancelled))
         (full-output-path (plist-get details :fullOutputPath))
         (text (pimacs--apply-ansi-colors (pimacs--content-text content))))
    (when (not (string-empty-p text))
      (insert (format "%s" text)))
    (when (eq cancelled t)
      (pimacs--insert-error "Cancelled"))
    (when (and (numberp exit-code) (not (zerop exit-code)))
      (pimacs--insert-error (format "Command exited with code %d" exit-code)))
    (when full-output-path
      (insert "Output truncated. See full output at: ")
      (pimacs--insert-file-link full-output-path))))

;; grep
(defun pimacs--insert-grep-args (args)
  (let ((pattern (plist-get args :pattern))
        (path (plist-get args :path))
        (glob (plist-get args :glob))
        (ignore-case (eq (plist-get args :ignoreCase) t))
        (literal (eq (plist-get args :literal) t))
        (context (plist-get args :context))
        (limit (plist-get args :limit)))
    (insert (propertize (format "/%s/" pattern) 'face 'font-lock-string-face))
    (when path
      (insert (format " in %s" path)))
    (when glob
      (insert (format " (%s)" glob)))
    (when ignore-case
      (insert " --ignore-case"))
    (when literal
      (insert " --literal"))
    (when context
      (insert (format " -C %d" context)))
    (when limit
      (insert (format " limit %d" limit)))))

(defun pimacs--grep-pattern-regexp (pattern literal)
  (if literal
      (regexp-quote pattern)
    (condition-case nil
        (rxt-pcre-to-elisp pattern)
      (error nil))))

(defun pimacs--fontify-grep-matches (begin end regexp ignore-case)
  (when regexp
    (let ((case-fold-search (if ignore-case t nil))
          (searching t))
      (save-restriction
        (narrow-to-region begin end)
        (goto-char (point-min))
        (while (and searching (re-search-forward regexp nil t))
          (if (= (match-beginning 0) (match-end 0))
              (if (< (point) (point-max))
                  (forward-char 1)
                (setq searching nil))
            (add-text-properties (match-beginning 0) (match-end 0)
                                 '(face pimacs-grep-match-face))))))))

(defconst pimacs--grep-line-regexp "^\\(.*\\):\\([0-9]+\\): \\(.*\\)$")
(defconst pimacs--grep-line-alt-regexp "^\\(.*\\)\\([-:]\\)\\([0-9]+\\)\\([-:] ?\\)\\(.*\\)$")

(defun pimacs--fontify-grep-line (regexp ignore-case)
  (cond
   ((looking-at pimacs--grep-line-regexp)
    (let ((file-begin (match-beginning 1))
          (file-end (match-end 1))
          (line-begin (match-beginning 2))
          (line-end (match-end 2))
          (content-begin (match-beginning 3))
          (content-end (match-end 3)))
      (add-text-properties file-begin file-end '(face compilation-info))
      (add-text-properties line-begin line-end '(face compilation-line-number))
      (pimacs--fontify-grep-matches content-begin content-end regexp ignore-case)))
   ((looking-at pimacs--grep-line-alt-regexp)
    (let ((file-begin (match-beginning 1))
          (file-end (match-end 1))
          (line-begin (match-beginning 3))
          (line-end (match-end 3)))
      (add-text-properties file-begin file-end '(face compilation-info))
      (add-text-properties line-begin line-end '(face compilation-line-number))))))

(defun pimacs--insert-grep-result (content _details args)
  (let* ((result-text (pimacs--content-text content))
         (pattern (plist-get args :pattern))
         (literal (eq (plist-get args :literal) t))
         (ignore-case (eq (plist-get args :ignoreCase) t))
         (fontify (and pattern (not (string-empty-p pattern))))
         (regexp (and fontify (pimacs--grep-pattern-regexp pattern literal)))
         (begin (point)))
    (insert result-text)
    (when fontify
      (let ((end (point)))
        (save-restriction
          (narrow-to-region begin end)
          (save-excursion
            (goto-char (point-min))
            (while (< (point) (point-max))
              (pimacs--fontify-grep-line regexp ignore-case)
              (forward-line 1))))))))

(defun pimacs--normalize-grep-file (file args)
  (if-let ((path (plist-get args :path)))
      (if (file-directory-p path)
          (expand-file-name file path)
        path)
    file))

(defun pimacs--visit-grep-match (args cursor-position file-group line-group content-group)
  (let* ((file (match-string file-group))
         (line (string-to-number (match-string line-group)))
         (content-begin (match-beginning content-group))
         (content-end (match-end content-group))
         (column (max 0 (min (- cursor-position content-begin)
                             (- content-end content-begin)))))
    (list :file (pimacs--normalize-grep-file file args)
          :line line
          :column column)))

(defun pimacs--visit-grep-result (_details args)
  (let ((cursor-position (point)))
    (save-excursion
      (beginning-of-line)
      (cond
       ((looking-at pimacs--grep-line-regexp)
        (pimacs--visit-grep-match args cursor-position 1 2 3))
       ((looking-at pimacs--grep-line-alt-regexp)
        (pimacs--visit-grep-match args cursor-position 1 3 5))))))

;; find
(defun pimacs--insert-find-args (args)
  (let ((pattern (plist-get args :pattern))
        (path (plist-get args :path))
        (limit (plist-get args :limit)))
    (insert (propertize (format "/%s/" pattern) 'face 'font-lock-string-face))
    (when path
      (insert (format " in %s" path)))
    (when limit
      (insert (format " limit %d" limit)))))

(defun pimacs--insert-find-result (content _details _args)
  (pimacs--insert-content content))

;; ls
(defun pimacs--insert-ls-args (args)
  (when-let ((path (plist-get args :path)))
    (insert path))
  (when-let ((limit (plist-get args :limit)))
    (insert (format " limit %d" limit))))

(defun pimacs--insert-ls-result (content _details _args)
  (pimacs--insert-content content))

(defun pimacs--format-tool-args (tool-name args)
  (with-temp-buffer
    (if-let ((inserter (pimacs--alist-get-equal tool-name pimacs-insert-tool-args-functions)))
        (funcall inserter args)
      (when args
        (insert (pimacs--render-content nil (format "%S" args)
                                        #'emacs-lisp-mode))))
    (buffer-string)))

(defun pimacs--insert-tool-call (section tool-name args)
  "Format and insert a tool call into SECTION for TOOL-NAME with ARGS."
  (let ((formatted-args (pimacs--format-tool-args tool-name args)))
    (pimacs--widget-save-excursion
      (pimacs-section--insert-section section
        (pimacs--insert-tool-name tool-name)
        (insert formatted-args))
      (pimacs-section--set-info section (make-pimacs-section-tool-call-info
                                         :tool-name tool-name
                                         :args args
                                         :header (pimacs--section-header (substring-no-properties formatted-args)))))))

(defun pimacs--insert-tool-result (tool-name content is-error &optional details args)
  (if (eq is-error t)
      (let ((text (pimacs--content-text content)))
        (when (not (string-empty-p text))
          (pimacs--insert-error (format "%s" text))))
    (if-let ((inserter (pimacs--alist-get-equal tool-name pimacs-insert-tool-result-functions)))
        (funcall inserter content details args)
      (pimacs--insert-content content))))

(defun pimacs--handle-tool-execution-update (event)
  (let* ((tool-call-id (plist-get event :toolCallId))
         (partial-result (plist-get event :partialResult))
         (new-text (pimacs--content-text (plist-get partial-result :content)))
         (entry (gethash tool-call-id pimacs--tool-calls)))
    (when (and entry new-text)
      (let ((prev-text (pimacs-tool-call-prev-text entry))
            (result-section (pimacs-tool-call-result-section entry)))
        (pimacs--widget-save-excursion
          (if (string-prefix-p prev-text new-text)
              (let ((diff (substring new-text (length prev-text))))
                (unless (string-empty-p diff)
                  (pimacs-section--append-section result-section
                    (insert diff))))
            (pimacs-section--replace-section result-section
              (insert new-text)))
          (setf (pimacs-tool-call-prev-text entry) new-text))))))

(defun pimacs--handle-bash-execution-update (event)
  (let* ((request-id (plist-get event :id))
         (delta (plist-get event :delta))
         (entry (gethash request-id pimacs--bash-executions)))
    (unless (string-empty-p delta)
      (let ((call-section (pimacs-tool-call-call-section entry))
            (result-section (pimacs-tool-call-result-section entry)))
        (pimacs--widget-save-excursion
          (if result-section
              (pimacs-section--append-section result-section
                (insert delta))
            (setf (pimacs-tool-call-result-section entry)
                  (pimacs-section--create-section 'tool-result call-section
                    (insert delta)))))))))

(defun pimacs--handle-tool-execution-end (event)
  (let* ((tool-call-id (plist-get event :toolCallId))
         (result (plist-get event :result))
         (content (pimacs--content-normalize (plist-get result :content)))
         (is-error (plist-get event :isError))
         (tool-name (plist-get event :toolName))
         (entry (gethash tool-call-id pimacs--tool-calls)))
    (when entry
      (let ((result-section (pimacs-tool-call-result-section entry))
            (details (plist-get result :details))
            (args (pimacs-tool-call-args entry)))
        (pimacs--widget-save-excursion
          (pimacs-section--replace-section result-section
            (pimacs--insert-tool-result tool-name content is-error
                                        details
                                        args)))
        (pimacs-section--set-info result-section (make-pimacs-section-tool-result-info :tool-name tool-name :details details :args args)))
      (remhash tool-call-id pimacs--tool-calls))))

(defun pimacs--handle-auto-retry-start (event)
  (setq pimacs--retry-in-progress t)
  (let ((attempt (plist-get event :attempt))
        (max-attempts (plist-get event :maxAttempts))
        (delay-ms (plist-get event :delayMs))
        (error-message (plist-get event :errorMessage)))
    (when (and error-message (not (string-empty-p error-message)))
      (pimacs--widget-save-excursion
        (pimacs-section--create-section 'error pimacs-section--root-section
          (pimacs--insert-error (format "Error: %s\n\n" error-message))
          (insert
           (format "Retrying %d/%d (waiting %ds)…" attempt max-attempts (/ delay-ms 1000))))))))

(defun pimacs--handle-auto-retry-end (event)
  (setq pimacs--retry-in-progress nil)
  (let ((attempt (plist-get event :attempt))
        (final-error (plist-get event :finalError)))
    (unless (pimacs--response-success-p event)
      (pimacs--widget-save-excursion
        (pimacs-section--create-section 'error pimacs-section--root-section
          (pimacs--insert-error
           (format "Error: Retry failed after %d attempts: %s" attempt final-error)))))))

(defun pimacs--handle-queue-update (event)
  (let* ((steering (plist-get event :steering))
         (follow-up (plist-get event :followUp))
         (has-content (or (consp steering)
                          (consp follow-up))))
    (when has-content
      (pimacs--widget-save-excursion
        (pimacs-section--create-section 'queue pimacs-section--root-section
          (insert (propertize "queue" 'face 'bold))
          (dolist (item steering)
            (insert (format "\n Steering: %s" item)))
          (dolist (item follow-up)
            (insert (format "\n Follow-up: %s" item))))))))

(defun pimacs--handle-compaction-end (event)
  (let* ((result (plist-get event :result))
         (error-message (plist-get event :errorMessage)))
    (cond
     (error-message
      (pimacs--widget-save-excursion
        (pimacs-section--create-section 'error pimacs-section--root-section
          (pimacs--insert-error error-message))))
     (result
      (let ((summary (plist-get result :summary))
            (tokens-before (plist-get result :tokensBefore)))
        (pimacs--widget-save-excursion
          (pimacs--insert-compaction summary tokens-before)))))))

(defun pimacs--notify (message &optional notify-type)
  (let ((face (pcase (or notify-type "info")
                ("warning" 'pimacs-notify-warning-face)
                ("error" 'pimacs-notify-error-face)
                (_ 'pimacs-notify-info-face))))
    (pimacs--widget-save-excursion
      (pimacs-section--create-section 'notify pimacs-section--root-section
        (insert (propertize message 'face face))))))

(defun pimacs--handle-notify (event)
  (pimacs--notify (plist-get event :message)
                  (plist-get event :notifyType)))

(defun pimacs--widget-lines (widget)
  (let ((text (widget-value widget)))
    (if (or (string-empty-p text)
            (equal text pimacs--empty-widget-text))
        0
      (cl-count ?\n text))))

(defun pimacs--extra-widget-lines ()
  (+ (pimacs--widget-lines pimacs--prompt-after-widget)
     (pimacs--widget-lines pimacs--status-widget)))

(defun pimacs--widget-ensure-trailing-newline (text &optional empty-text)
  (if (string-empty-p text)
      (or empty-text pimacs--empty-widget-text)
    (if (= (aref text (1- (length text))) ?\n)
        text
      (concat text "\n"))))

(defun pimacs--update-widget-by-entries (widget entries &optional empty-text)
  (widget-value-set widget
                    (pimacs--widget-ensure-trailing-newline
                     (pimacs--join (pimacs--sort-entries-by-key entries))
                     empty-text)))

(defun pimacs--update-prompt-widgets ()
  (let ((above '())
        (below '()))
    (when pimacs--prompt-widget-lines
      (maphash (lambda (key val)
                 (let ((lines (pimacs--join (car val)))
                       (placement (cdr val)))
                   (pcase placement
                     ("aboveEditor"
                      (push (cons key lines) above))
                     ("belowEditor"
                      (push (cons key lines) below)))))
               pimacs--prompt-widget-lines))
    (pimacs--update-widget-by-entries pimacs--prompt-before-widget above "\n")
    (pimacs--update-widget-by-entries pimacs--prompt-after-widget below)))

(defun pimacs--handle-set-widget (event)
  (let* ((widget-key (plist-get event :widgetKey))
         (widget-lines (plist-get event :widgetLines))
         (widget-placement (or (plist-get event :widgetPlacement) "aboveEditor")))
    (if (or (not widget-lines)
            (null widget-lines))
        (remhash widget-key pimacs--prompt-widget-lines)
      (puthash widget-key (cons widget-lines widget-placement) pimacs--prompt-widget-lines))
    (pimacs--update-prompt-widgets)))

(defun pimacs--update-status-widget ()
  (let (entries)
    (when pimacs--status-texts
      (maphash (lambda (key text)
                 (unless (member key pimacs-status-widget-hidden-keys)
                   (push (cons key
                               (propertize text
                                           'help-echo
                                           key))
                         entries)))
               pimacs--status-texts))
    (widget-value-set pimacs--status-widget
                      (pimacs--widget-ensure-trailing-newline
                       (pimacs--join (pimacs--sort-entries-by-key entries) " ")))
    (force-mode-line-update)))

(defun pimacs--handle-set-status (event)
  (let* ((status-key (plist-get event :statusKey))
         (status-text (plist-get event :statusText)))
    (if (or (not status-text) (string-empty-p status-text))
        (remhash status-key pimacs--status-texts)
      (puthash status-key status-text pimacs--status-texts))
    (pimacs--update-status-widget)))

(defun pimacs--handle-set-editor-text (event)
  (let ((text (plist-get event :text))
        (current (widget-value pimacs--prompt-widget)))
    (unless (string-empty-p current)
      (pimacs--clear-prompt current))
    (widget-value-set pimacs--prompt-widget text)))

(defun pimacs--handle-extension-ui-prompt (event prompt-fn)
  (let ((id (plist-get event :id)))
    (condition-case nil
        (funcall prompt-fn)
      (quit
       (pimacs--send-command "extension_ui_response"
                             (list :id id :cancelled t))))))

(defun pimacs--handle-select (event)
  (let* ((id (plist-get event :id))
         (title (plist-get event :title))
         (options (plist-get event :options)))
    (pimacs--widget-save-excursion
      (pimacs-section--create-section 'select pimacs-section--root-section
        (insert (propertize (format "%s:" title) 'face 'pimacs-chat-title-face))
        (dolist (option options)
          (insert "\n")
          (insert (propertize (format "  • %s" option) 'face 'pimacs-notify-info-face)))))
    (pimacs--handle-extension-ui-prompt
     event
     (lambda ()
       (let ((selected (completing-read (concat title ": ") options nil t)))
         (pimacs--send-command "extension_ui_response"
                               (list :id id :value selected)))))))

(defun pimacs--handle-confirm (event)
  (let* ((id (plist-get event :id))
         (title (plist-get event :title))
         (message (plist-get event :message)))
    (pimacs--widget-save-excursion
      (pimacs-section--create-section 'confirm pimacs-section--root-section
        (insert (propertize (format "%s:" title) 'face 'pimacs-chat-title-face))
        (insert "\n")
        (insert (propertize message 'face 'pimacs-notify-info-face))))
    (pimacs--handle-extension-ui-prompt
     event
     (lambda ()
       (let ((confirmed (y-or-n-p (concat message " "))))
         (pimacs--send-command "extension_ui_response"
                               (list :id id :confirmed (if confirmed t 'json-false))))))))

(defun pimacs--handle-input (event)
  (let* ((id (plist-get event :id))
         (title (plist-get event :title))
         (placeholder (plist-get event :placeholder)))
    (pimacs--widget-save-excursion
      (pimacs-section--create-section 'input pimacs-section--root-section
        (insert (propertize (format "%s:" title) 'face 'pimacs-chat-title-face))
        (when placeholder
          (insert "\n")
          (insert (propertize placeholder 'face 'pimacs-notify-info-face)))))
    (pimacs--handle-extension-ui-prompt
     event
     (lambda ()
       (let ((value (read-from-minibuffer
                     (concat title
                             (if placeholder (format " (%s) " placeholder) ": ")))))
         (pimacs--send-command "extension_ui_response"
                               (list :id id :value value)))))))

(defun pimacs--handle-editor (event)
  (let* ((id (plist-get event :id))
         (title (plist-get event :title))
         (prefill (plist-get event :prefill)))
    (pimacs--widget-save-excursion
      (pimacs-section--create-section 'input pimacs-section--root-section
        (insert (propertize (format "%s:" title) 'face 'pimacs-chat-title-face))))
    (pimacs--handle-extension-ui-prompt
     event
     (lambda ()
       (pimacs-edit--with-editor
        (lambda (value)
          (pimacs--send-command "extension_ui_response"
                                (list :id id :value value)))
        (lambda ()
          (pimacs--send-command "extension_ui_response"
                                (list :id id :cancelled t)))
        prefill)))))

(defun pimacs--handle-set-title (event)
  (let ((title (plist-get event :title)))
    (when title
      (rename-buffer (pimacs--chat-buffer-name title) t))))

(defun pimacs--handle-extension-ui-request (event)
  (pcase (plist-get event :method)
    ("notify" (pimacs--handle-notify event))
    ("select" (pimacs--handle-select event))
    ("confirm" (pimacs--handle-confirm event))
    ("input" (pimacs--handle-input event))
    ("editor" (pimacs--handle-editor event))
    ("set_editor_text" (pimacs--handle-set-editor-text event))
    ("setWidget" (pimacs--handle-set-widget event))
    ("setStatus" (pimacs--handle-set-status event))
    ("setTitle" (pimacs--handle-set-title event))))

(defun pimacs--register-event-listeners ()
  (pimacs--set-event-batch-listener "message_update" 'pimacs #'pimacs--handle-message-update-batch)
  (pimacs--set-event-listener "message_end" 'pimacs #'pimacs--handle-message-end)
  (pimacs--set-event-listener "bash_execution_update" 'pimacs #'pimacs--handle-bash-execution-update)

  (pimacs--set-event-listener "tool_execution_update" 'pimacs #'pimacs--handle-tool-execution-update)
  (pimacs--set-event-listener "tool_execution_end" 'pimacs #'pimacs--handle-tool-execution-end)

  (pimacs--set-event-listener "auto_retry_start" 'pimacs #'pimacs--handle-auto-retry-start)
  (pimacs--set-event-listener "auto_retry_end" 'pimacs #'pimacs--handle-auto-retry-end)

  (pimacs--set-event-listener "queue_update" 'pimacs #'pimacs--handle-queue-update)
  (pimacs--set-event-listener "compaction_end" 'pimacs #'pimacs--handle-compaction-end)
  (pimacs--set-event-listener "extension_ui_request" 'pimacs #'pimacs--handle-extension-ui-request)
  (pimacs--set-event-listener t 'pimacs #'pimacs--handle-agent-state))

(defun pimacs--register-agent-cleanup ()
  "Register a cleanup callback on the agent to kill the chat buffer on exit."
  (when-let (agent (pimacs--current-agent))
    (let* ((buf (current-buffer))
           (fn (lambda ()
                 (when (buffer-live-p buf)
                   (kill-buffer buf)))))
      (pimacs--agent-add-cleanup agent fn)
      (setq-local pimacs--cleanup-callback-fn fn))))

(defun pimacs-focus-prompt ()
  "Move point to the chat prompt input field."
  (interactive)
  (goto-char (widget-field-text-end pimacs--prompt-widget)))

(defun pimacs--update-agent-state (state)
  (setq pimacs--agent-state state)
  (setq imenu--index-alist nil)
  (if pimacs--agent-state
      (unless (spinner--active-p pimacs--spinner)
        (spinner-start pimacs--spinner))
    (spinner-stop pimacs--spinner)))

(defun pimacs--agent-state-tools ()
  (if (and (consp pimacs--agent-state)
           (eq (car pimacs--agent-state) 'tool))
      (cdr pimacs--agent-state)
    nil))

(defun pimacs--agent-state-add-tool (tool-name)
  (cons 'tool
        (cons tool-name (pimacs--agent-state-tools))))

(defun pimacs--agent-state-remove-tool (tool-name)
  (let ((tools (cl-remove tool-name (pimacs--agent-state-tools) :count 1 :test #'equal)))
    (if tools
        (cons 'tool tools)
      'thinking)))

(defun pimacs--handle-agent-state (event)
  (cl-case (intern (plist-get event :type))
    (agent_start (pimacs--update-agent-state 'thinking))
    (agent_settled (pimacs--update-agent-state nil)
                   (pimacs-clear-project-file-cache))
    (turn_start (pimacs--update-agent-state 'thinking))
    (tool_execution_start
     (pimacs--update-agent-state
      (pimacs--agent-state-add-tool (plist-get event :toolName))))
    (tool_execution_end
     (pimacs--update-agent-state
      (pimacs--agent-state-remove-tool (plist-get event :toolName))))
    (compaction_start (pimacs--update-agent-state 'compacting))
    (compaction_end (pimacs--update-agent-state nil))
    (auto_retry_start (pimacs--update-agent-state 'retrying))
    (auto_retry_end (pimacs--update-agent-state nil)))
  (when (string-suffix-p "_end" (plist-get event :type))
    (pimacs--autohide-sections))
  (pimacs--update-header-line))

(defun pimacs-section-cycle-global ()
  "Cycle visibility of all sections in the current chat buffer."
  (interactive)
  (pimacs-section--cycle-global)
  (pimacs--recenter-chat))

(defun pimacs--autohide-sections ()
  (when (pimacs--point-in-prompt-p)
    (pimacs-section-autohide)
    (pimacs--recenter-chat)))

(defun pimacs--cleanup-chat-buffer ()
  (let ((project-key pimacs--project-key))
    (remhash project-key pimacs--chats)
    (pimacs--hash-remove-if (lambda (k _v) (equal (car k) project-key)) pimacs--event-listeners)
    (pimacs--hash-remove-if (lambda (k _v) (equal (car k) project-key)) pimacs--event-batch-listeners)
    (ignore-errors
      (pimacs--kill-agent))))

;;; Commands

(defun pimacs--parse-slash-command (prompt)
  (when (string-match "\\`[ \t\n]*/\\([-a-zA-Z0-9]+\\)\\([ \t].*\\)?$" prompt)
    (let* ((name (match-string-no-properties 1 prompt))
           (raw (and (match-beginning 2)
                     (string-trim-left (match-string-no-properties 2 prompt))))
           (args (and (not (string-empty-p raw)) raw))
           (cell (assoc name pimacs-slash-commands #'string=)))
      (when cell
        (let ((cmd (cadr cell))
              (max-args (nth 2 cell)))
          (when (and args (not (eq max-args 1)))
            (error "Slash command \"/%s\" does not accept arguments" name))
          (cons cmd args))))))

(defun pimacs--parse-bang-command (prompt)
  (pimacs--parse-bang-command-with-regex prompt "\\`[ \t\n]*!\\([^!].*\\)$"))

(defun pimacs--parse-double-bang-command (prompt)
  (pimacs--parse-bang-command-with-regex prompt "\\`[ \t\n]*!!\\(.+\\)$"))

(defun pimacs--parse-bang-command-with-regex (prompt regex)
  (when (string-match regex prompt)
    (let ((result (match-string-no-properties 1 prompt)))
      (when (not (string-match-p "^[ \t]+$" result))
        result))))

(defun pimacs--clear-prompt (prompt)
  (let ((current (widget-value pimacs--prompt-widget)))
    (when (string= current prompt)
      (widget-value-set pimacs--prompt-widget "")))
  (unless (and (> (ring-length pimacs--prompt-history) 0)
               (equal prompt (ring-ref pimacs--prompt-history 0)))
    (ring-insert pimacs--prompt-history prompt))
  (setq pimacs--prompt-history-index 0)
  (setq pimacs--attached-images (vector))
  (pimacs--update-images-preview)
  (pimacs-section-autohide))

(defun pimacs-send-prompt (&optional prompt streaming-behavior)
  "Send PROMPT with optional STREAMING-BEHAVIOR to the agent."
  (interactive "sPrompt: ")
  (if (or (null prompt) (string-empty-p prompt))
      (message "No prompt to send")
    (let ((slash (pimacs--parse-slash-command prompt))
          (bang (pimacs--parse-bang-command prompt))
          (double-bang (pimacs--parse-double-bang-command prompt)))
      (pimacs--with-chat-buffer
        (cond
         (slash
          (let ((cmd (car slash))
                (args (cdr slash)))
            (if (null args)
                (call-interactively cmd)
              (apply cmd (list args)))
            (when (not (eq cmd 'pimacs-quit-chat))
              (pimacs--clear-prompt prompt))))
         (double-bang
          (pimacs-bash double-bang t)
          (pimacs--clear-prompt prompt))
         (bang
          (pimacs-bash bang)
          (pimacs--clear-prompt prompt))
         (t
          (let ((args (list :message prompt
                            :streamingBehavior (when-let (behavior (or streaming-behavior pimacs-prompt-streaming-behavior))
                                                 (symbol-name behavior)))))
            (unless (seq-empty-p pimacs--attached-images)
              (setq args (nconc args (list :images pimacs--attached-images))))
            (pimacs--send-command
             "prompt" args
             (pimacs--on-response-success-callback resp
               (pimacs--clear-prompt prompt))))))))))

(defun pimacs-send-prompt-alternate (&optional prompt)
  "Send PROMPT with the alternative streaming behavior.

If `pimacs-prompt-streaming-behavior' is `followUp', use `steer' and vice versa."
  (interactive)
  (let* ((alt-behavior (if (eq pimacs-prompt-streaming-behavior 'followUp)
                           'steer
                         'followUp))
         (prompt-text (or prompt (widget-value pimacs--prompt-widget))))
    (when (and prompt-text (not (string-empty-p prompt-text)))
      (pimacs-send-prompt prompt-text alt-behavior))))

(defun pimacs--add-attached-image (mime-type data)
  (pimacs--widget-save-excursion
    (let* ((data (if (multibyte-string-p data)
                     (encode-coding-string data 'raw-text-unix)
                   data))
           (base64-data (base64-encode-string data t))
           (image-plist (list :type "image" :data base64-data :mimeType (symbol-name mime-type))))
      (setq pimacs--attached-images (vconcat pimacs--attached-images (vector image-plist)))
      (pimacs--update-images-preview)))
  (pimacs-focus-prompt))

(defvar pimacs--image-remove-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'pimacs--image-remove-at-point)
    (define-key map [backspace] #'pimacs--image-remove-at-point)
    (define-key map [delete] #'pimacs--image-remove-at-point)
    map)
  "Keymap used for removing attached images.")

(defun pimacs--image-remove-at-point ()
  "Remove the attached image at point."
  (interactive)
  (let ((index (get-text-property (point) 'pimacs-image-index)))
    (if (null index)
        (user-error "No image at point")
      (let* ((before (cl-subseq pimacs--attached-images 0 index))
             (after (cl-subseq pimacs--attached-images (1+ index)))
             (images (append before after nil)))
        (setq pimacs--attached-images (vconcat images))
        (pimacs--update-images-preview)
        (pimacs-focus-prompt)))))

(defun pimacs--update-images-preview ()
  (let ((images pimacs--attached-images))
    (if (seq-empty-p images)
        (widget-value-set pimacs--attached-images-widget pimacs--empty-widget-text)
      (let ((preview "\n"))
        (dotimes (i (length images))
          (let* ((plist (aref images i))
                 (mime-type (plist-get plist :mimeType))
                 (base64-data (plist-get plist :data))
                 (image-type (pimacs--alist-get-equal mime-type pimacs--image-type-alist))
                 (image (ignore-errors
                          (create-image (base64-decode-string base64-data)
                                        image-type t
                                        :data-p t
                                        :max-width 200
                                        :max-height 100
                                        :margin '(4 . 4)
                                        :ascent 100))))
            (when image
              (setq preview (concat preview
                                    (propertize " " 'display image
                                                'keymap pimacs--image-remove-map
                                                'pimacs-image-index i
                                                'mouse-face 'highlight
                                                'help-echo (format "Remove image %d (backspace/delete)" (1+ i))))))))
        (unless (string-empty-p preview)
          (setq preview (concat preview "\n")))
        (widget-value-set pimacs--attached-images-widget preview)))))

(defun pimacs--check-image-type (mime-type)
  (unless (pimacs--alist-get-equal (symbol-name mime-type) pimacs--image-type-alist)
    (user-error "Unsupported image type: %s" mime-type)))

(defun pimacs--dnd-handler (url _action)
  (when-let ((file (dnd-get-local-file-name url t)))
    (let* ((mime-string (or (mailcap-extension-to-mime (file-name-extension file t))
                            (user-error "Can't determine MIME type for %s" file)))
           (mime-type (intern mime-string))
           (data (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally file)
                   (buffer-string))))
      (pimacs--check-image-type mime-type)
      (pimacs--add-attached-image mime-type data)))
  'private)

(defun pimacs--yank-media-handler (mime-type data)
  (pimacs--check-image-type mime-type)
  (pimacs--add-attached-image mime-type data))

(defun pimacs--prompt-append (text)
  (pimacs--with-chat-buffer
    (let ((current-value (widget-value pimacs--prompt-widget)))
      (pimacs--widget-save-excursion
        (if (string-empty-p current-value)
            (widget-value-set pimacs--prompt-widget text)
          (widget-value-set pimacs--prompt-widget
                            (concat current-value "\n" text))))
      (pimacs--widget-end-if-inside pimacs--prompt-widget))))

(defun pimacs--pop-to-chat ()
  (when pimacs-send-pop-to-chat
    (let ((buffer (pimacs--current-chat)))
      (when buffer (pop-to-buffer buffer)))))

(defun pimacs--project-relative-name (filename)
  (file-relative-name filename (pimacs--project-root)))

(defun pimacs-send-region (start end)
  "Append the region delimited by START and END to the pimacs prompt input."
  (interactive "r")
  (let ((filename buffer-file-name)
        (string (buffer-substring-no-properties start end))
        (line-start (line-number-at-pos start))
        (line-end (line-number-at-pos end)))
    (pimacs--with-chat-buffer
      (let* ((header (when filename
                       (format "@%s#L%d-%d\n"
                               (pimacs--project-relative-name filename)
                               line-start line-end)))
             (full-string (if header (concat header string) string)))
        (pimacs--prompt-append full-string)))
    (deactivate-mark)
    (pimacs--pop-to-chat)))

(defun pimacs-send-filename ()
  "Append the current buffer's filename to the pimacs prompt input."
  (interactive)
  (when-let ((filename buffer-file-name))
    (pimacs--with-chat-buffer
      (pimacs--prompt-append
       (format "@%s" (pimacs--project-relative-name filename))))
    (pimacs--pop-to-chat)))

(declare-function flycheck-overlay-errors-at "ext:flycheck")
(declare-function flycheck-error-line "ext:flycheck")
(declare-function flycheck-error-level "ext:flycheck")
(declare-function flycheck-error-message "ext:flycheck")
(declare-function flycheck-error-buffer "ext:flycheck")
(declare-function flycheck-error-format-position "ext:flycheck")
(defvar flycheck-current-errors)

(defun pimacs-send-flycheck-errors ()
  "Append flycheck errors at point to the pimacs prompt input."
  (interactive)
  (let ((errors (or (flycheck-overlay-errors-at (point))
                    flycheck-current-errors))
        (filename buffer-file-name))
    (when (and errors filename)
      (pimacs--with-chat-buffer
        (let* ((relative (pimacs--project-relative-name filename))
               (error-lines
                (mapconcat
                 (lambda (err)
                   (let* ((level (flycheck-error-level err))
                          (message (flycheck-error-message err))
                          (header (format "@%s#%s" relative (flycheck-error-format-position err)))
                          (line (pimacs--get-line-contents (flycheck-error-buffer err) (flycheck-error-line err))))
                     (format "%s\n%s\n%s: %s"
                             header
                             line
                             (capitalize (symbol-name level))
                             message)))
                 errors "\n")))
          (pimacs--prompt-append error-lines))))
    (pimacs--pop-to-chat)))

(defun pimacs-abort ()
  "Abort the current agent operation."
  (interactive)
  (pimacs--with-chat-buffer
    (when (or pimacs--retry-in-progress pimacs--agent-state)
      (pimacs--send-command
       (cond
        (pimacs--retry-in-progress "abort_retry")
        ((eq pimacs--agent-state 'bash) "abort_bash")
        (pimacs--agent-state "abort"))
       '()
       (pimacs--on-response-success-callback resp
         (pimacs--widget-save-excursion
           (pimacs-section--create-section 'error pimacs-section--root-section
             (pimacs--insert-error "Aborted")))))))
  (keyboard-quit))

(defun pimacs--insert-stats-section (header plist fields)
  "Insert a stats section with HEADER (bold), extracting integers from PLIST.
FIELDS is a list of (LABEL . KEY) where KEY is a plist key."
  (insert (propertize (concat header "\n") 'face 'bold))
  (pcase-dolist (`(,label . ,key) fields)
    (insert (format " %s: %d\n" label (plist-get plist key)))))

(defun pimacs-session-stats ()
  "Show current session statistics."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "get_session_stats" '()
     (pimacs--on-response-success-callback resp
       (let* ((data (plist-get resp :data))
              (tokens (plist-get data :tokens))
              (cost (plist-get data :cost)))
         (pimacs--widget-save-excursion
           (pimacs-section--create-section 'session pimacs-section--root-section
             (insert
              (propertize "Session Info\n" 'face 'bold))

             (insert " File: ")
             (pimacs--insert-file-link (plist-get data :sessionFile))
             (insert "\n")

             (insert
              (format " ID: %s\n\n"
                      (plist-get data :sessionId)))

             (pimacs--insert-stats-section
              "Messages"
              data
              '(("User" . :userMessages)
                ("Assistant" . :assistantMessages)
                ("Tool Calls" . :toolCalls)
                ("Tool Results" . :toolResults)
                ("Total" . :totalMessages)))

             (insert "\n")

             (pimacs--insert-stats-section
              "Tokens"
              tokens
              '(("Input" . :input)
                ("Output" . :output)
                ("Cache Read" . :cacheRead)
                ("Total" . :total)))

             (insert "\n")

             (insert
              (propertize "Cost\n" 'face 'bold))

             (insert
              (format " Total: %.4f\n" cost)))))))))

(defun pimacs-select-model ()
  "Select a different model for the session."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "get_available_models" '()
     (pimacs--on-response-success-callback resp
       (let* ((models (plist-get (plist-get resp :data) :models))
              (items
               (mapcar
                (lambda (m)
                  (cons (format "(%s) %s" (plist-get m :provider) (plist-get m :id))
                        m))
                models)))
         (if (null items)
             (message "No models available.")
           (let* ((selected (completing-read "Select model: " items nil t))
                  (model (pimacs--alist-get-equal selected items))
                  (provider (plist-get model :provider))
                  (model-id (plist-get model :id)))
             (pimacs--send-command
              "set_model" (list :provider provider :modelId model-id)
              (pimacs--on-response-success-callback resp
                (pimacs--update-header-line)
                (pimacs--widget-save-excursion
                  (pimacs--insert-model-change provider model-id)))))))))))

(defvar pimacs--thinking-level-descriptions
  '((:off     . "No reasoning")
    (:minimal . "Very brief reasoning ~1k tokens")
    (:low     . "Light reasoning ~2k tokens")
    (:medium  . "Moderate reasoning ~8k tokens")
    (:high    . "Deep reasoning ~16k tokens")
    (:xhigh   . "Extra high reasoning ~32k tokens")
    (:max     . "Maximum reasoning")))

(defvar pimacs--prompt-modes
  '((:one-at-a-time . "One at a time")
    (:all . "All")))

(defun pimacs-set-thinking-level ()
  "Set the thinking level for the agent."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "get_available_thinking_levels" '()
     (pimacs--on-response-success-callback resp
       (let ((supported-levels (pimacs--plist-get resp :data :levels))
             (current-level (plist-get pimacs--header-line-state :thinkingLevel)))
         (if (null supported-levels)
             (message "No thinking levels available for this model.")
           (let* ((options
                   (mapcar
                    (lambda (level)
                      (let* ((keyword (intern (concat ":" level)))
                             (desc (alist-get keyword pimacs--thinking-level-descriptions)))
                        (cons keyword
                              (if desc
                                  (format "%s (%s)" level desc)
                                level))))
                    supported-levels))
                  (choice (pimacs--read-option options current-level "Set thinking level")))
             (when choice
               (pimacs--send-command
                "set_thinking_level" (list :level (car choice))
                (pimacs--on-response-success-callback resp
                  (pimacs--update-header-line)
                  (pimacs--widget-save-excursion
                    (pimacs--insert-thinking-level-change (car choice)))))))))))))

(defun pimacs-cycle-model ()
  "Cycle to the next available model."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "cycle_model" '()
     (pimacs--on-response-success-callback resp
       (let ((data (plist-get resp :data)))
         (if (null data)
             (message "No more models to cycle through.")
           (let ((model (plist-get data :model))
                 (thinking-level (plist-get data :thinkingLevel))
                 (is-scoped (plist-get data :isScoped)))
             (pimacs--update-header-line)
             (pimacs--widget-save-excursion
               (pimacs-section--create-section 'model pimacs-section--root-section
                 (insert (format "Cycled to model: (%s) %s · thinking level: %s%s"
                                 (plist-get model :provider)
                                 (plist-get model :id)
                                 (or thinking-level "?")
                                 (if (eq is-scoped t) " (scoped)" ""))))))))))))

(defun pimacs-set-steering-mode ()
  "Switch to steering mode for prompt delivery."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "get_state" '()
     (pimacs--on-response-success-callback resp
       (let* ((data (plist-get resp :data))
              (current-mode (plist-get data :steeringMode))
              (choice (pimacs--read-option pimacs--prompt-modes current-mode "Set steering mode")))
         (when choice
           (pimacs--send-command
            "set_steering_mode" (list :mode (car choice))
            (pimacs--on-response-success-callback resp
              (pimacs--update-header-line)
              (pimacs--widget-save-excursion
                (pimacs-section--create-section 'info pimacs-section--root-section
                  (insert (format "Steering mode set to: %s" (cdr choice)))))))))))))

(defun pimacs-set-follow-up-mode ()
  "Switch to follow-up mode for prompt delivery."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "get_state" '()
     (pimacs--on-response-success-callback resp
       (let* ((data (plist-get resp :data))
              (current-mode (plist-get data :followUpMode))
              (choice (pimacs--read-option pimacs--prompt-modes current-mode "Set follow-up mode")))
         (when choice
           (pimacs--send-command
            "set_follow_up_mode" (list :mode (car choice))
            (pimacs--on-response-success-callback resp
              (pimacs--update-header-line)
              (pimacs--widget-save-excursion
                (pimacs-section--create-section 'info pimacs-section--root-section
                  (insert (format "Follow-up mode set to: %s" (cdr choice)))))))))))))

(defun pimacs-cycle-thinking-level ()
  "Cycle to the next thinking level."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "cycle_thinking_level" '()
     (pimacs--on-response-success-callback resp
       (let ((data (plist-get resp :data)))
         (if (null data)
             (message "No more thinking levels to cycle through.")
           (let ((level (plist-get data :level)))
             (pimacs--update-header-line)
             (pimacs--widget-save-excursion
               (pimacs-section--create-section 'thinking pimacs-section--root-section
                 (insert (format "Cycled thinking level to: %s" level)))))))))))

(cl-defstruct pimacs-session-choice
  id message timestamp cwd path parent-id name)

(defun pimacs--read-session-choice (filename)
  (with-temp-buffer
    (insert-file-contents filename nil 0 10000)
    (goto-char (point-min))
    (let ((id nil)
          (timestamp nil)
          (cwd nil)
          (parent-id nil)
          (first-text nil)
          (name nil)
          (lines-read 0))
      (while (and (< lines-read 20) (not (eobp)))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (unless (string-empty-p line)
            (condition-case nil
                (let ((json (json-parse-string line :object-type 'plist)))
                  (pcase (intern (plist-get json :type))
                    ('session
                     (setq id (plist-get json :id)
                           timestamp (plist-get json :timestamp)
                           cwd (plist-get json :cwd)
                           parent-id (when-let ((ps (plist-get json :parentSession)))
                                       (file-name-sans-extension
                                        (file-name-nondirectory ps))))
                     (when parent-id
                       (setq parent-id (car (last (split-string parent-id "_"))))))
                    ('session_info
                     (setq name (plist-get json :name)))
                    ('message
                     (unless first-text
                       (setq first-text (pimacs--content-header (plist-get (plist-get json :message) :content)))))))
              (error nil))))
        (forward-line 1)
        (cl-incf lines-read))
      (make-pimacs-session-choice :id id
                                  :path filename
                                  :timestamp (when timestamp
                                               (condition-case nil
                                                   (parse-iso8601-time-string timestamp)
                                                 (error nil)))
                                  :cwd cwd
                                  :parent-id parent-id
                                  :message first-text
                                  :name name))))

(defun pimacs-resume ()
  "Resume a previous session."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "get_state" '()
     (lambda (resp)
       (when (pimacs--response-success-p resp)
         (let* ((data (plist-get resp :data))
                (session-file (plist-get data :sessionFile))
                (session-dir (file-name-directory session-file))
                (files (when session-dir
                         (seq-take
                          (sort (directory-files session-dir t "\\.jsonl$")
                                #'string>)
                          pimacs-resume-max-sessions)))
                (sessions (mapcar #'pimacs--read-session-choice files)))
           (if (null sessions)
               (message "No session files found in %s" session-dir)
             (let* ((candidates
                     (mapcar
                      (lambda (s)
                        (let* ((ts (pimacs-session-choice-timestamp s))
                               (formatted-time (if ts
                                                   (format-time-string "%F %R" ts)
                                                 ""))
                               (short-id (pimacs--short-uuid (pimacs-session-choice-id s)))
                               (short-parent (pimacs--short-uuid (pimacs-session-choice-parent-id s))))
                          (cons (format "%s  %s  %s%s%s" short-id formatted-time
                                        (if (pimacs-session-choice-name s)
                                            (format "[%s] " (pimacs-session-choice-name s))
                                          "")
                                        (pimacs-session-choice-message s)
                                        (if short-parent (format " (parent: %s)" short-parent) ""))
                                s)))
                      sessions))
                    (selected (pimacs--completing-read "Resume session: " candidates))
                    (choice (pimacs--alist-get-equal selected candidates))
                    (session-path (pimacs-session-choice-path choice)))
               (pimacs--switch-session session-path "Resumed session")))))))))

(defun pimacs--clear-sections ()
  (pimacs--history-render-reset)
  (dolist (child (copy-sequence (pimacs-section-children pimacs-section--root-section)))
    (pimacs-section--delete-section child))
  (clrhash pimacs--content-sections)
  (clrhash pimacs--tool-calls)
  (clrhash pimacs--bash-executions))

(defun pimacs--clear-session-widgets ()
  (when pimacs--prompt-widget-lines
    (clrhash pimacs--prompt-widget-lines))
  (when pimacs--status-texts
    (clrhash pimacs--status-texts))
  (pimacs--update-prompt-widgets)
  (pimacs--update-status-widget))

(defun pimacs--render-session-entry (entry)
  (pcase (plist-get entry :type)
    ("message"
     (pimacs--insert-message (plist-get entry :message)))
    ("compaction"
     (pimacs--insert-compaction (plist-get entry :summary)
                                (plist-get entry :tokensBefore)))
    ("model_change"
     (pimacs--insert-model-change (plist-get entry :provider)
                                  (plist-get entry :modelId)))
    ("thinking_level_change"
     (pimacs--insert-thinking-level-change (plist-get entry :thinkingLevel)))
    ("custom_message"
     (pimacs--insert-custom-message entry))
    ("session_info"
     (when-let ((name (plist-get entry :name)))
       (pimacs--insert-session-info name)))
    (_ nil)))

(defun pimacs--render-session-entries (entries)
  (dolist (entry entries)
    (pimacs--render-session-entry entry)))

(defun pimacs--history-track-tool-calls (entry pending)
  (when (equal (plist-get entry :type) "message")
    (let ((message (plist-get entry :message)))
      (pcase (pimacs--message-role message)
        ("assistant"
         (dolist (item (pimacs--content-normalize (plist-get message :content)))
           (when (equal (plist-get item :type) "toolCall")
             (when-let ((id (plist-get item :id)))
               (puthash id t pending)))))
        ("toolResult"
         (when-let ((id (plist-get message :toolCallId)))
           (remhash id pending)))))))

(defun pimacs--history-split-entries (entries)
  (let ((pending (make-hash-table :test 'equal))
        current
        chunks)
    (dolist (entry entries)
      (push entry current)
      (pimacs--history-track-tool-calls entry pending)
      (when (and (>= (length current) pimacs--history-chunk-size)
                 (zerop (hash-table-count pending)))
        (push (nreverse current) chunks)
        (setq current nil)))
    (when current
      (push (nreverse current) chunks))
    (nreverse chunks)))

(defun pimacs--history-pending-entry-count (&optional chunks)
  (apply #'+ (mapcar #'length (or chunks pimacs--history-render-pending))))

(defun pimacs--history-create-loading-section (count)
  (let ((section (pimacs-section--new-section
                  'history pimacs-section--root-section :face nil)))
    (pimacs-section--insert-section section
      (insert (format "Loading history: %d entries pending" count)))
    (setq pimacs--history-loading-section section)
    section))

(defun pimacs--history-update-loading-section ()
  (let ((count (pimacs--history-pending-entry-count)))
    (if (> count 0)
        (when pimacs--history-loading-section
          (pimacs--widget-save-excursion
            (pimacs-section--replace-section pimacs--history-loading-section
              (insert (format "Loading history: %d entries pending" count)))))
      (when pimacs--history-loading-section
        (pimacs--widget-save-excursion
          (pimacs-section--delete-section pimacs--history-loading-section)))
      (setq pimacs--history-loading-section nil
            pimacs--history-render-boundary nil))))

(defun pimacs--history-render-chunk (chunk)
  (let ((pimacs--tool-calls (make-hash-table :test 'equal)))
    (pimacs-section--with-insertion-before
        pimacs-section--root-section pimacs--history-render-boundary
      (pimacs--widget-save-excursion
        (pimacs--render-session-entries chunk)))
    (pimacs-section-autohide)
    (setq pimacs--history-render-boundary
          (cadr (pimacs-section-children pimacs-section--root-section)))
    (pimacs--history-update-loading-section)))

(defun pimacs--history-render-reset ()
  (when (timerp pimacs--history-render-timer)
    (cancel-timer pimacs--history-render-timer))
  (setq pimacs--history-render-timer nil
        pimacs--history-render-pending nil
        pimacs--history-loading-section nil
        pimacs--history-render-boundary nil)
  (cl-incf pimacs--history-render-generation))

(defun pimacs--history-schedule-idle-render (buffer generation)
  (when pimacs--history-render-pending
    (setq pimacs--history-render-timer
          (run-with-idle-timer
           pimacs--history-idle-delay nil
           #'pimacs--history-render-idle buffer generation))))

(defun pimacs--history-render-idle (buffer generation)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation pimacs--history-render-generation)
        (setq pimacs--history-render-timer nil)
        (if-let ((chunk (pop pimacs--history-render-pending)))
            (progn
              (pimacs--history-render-chunk chunk)
              (pimacs--history-schedule-idle-render buffer generation))
          (pimacs--history-update-loading-section))))))

(defun pimacs--history-start-idle-render (chunks)
  (setq pimacs--history-render-pending (reverse (copy-sequence chunks)))
  (pimacs--history-update-loading-section)
  (pimacs--history-schedule-idle-render
   (current-buffer) pimacs--history-render-generation))

(defun pimacs--render-session-history (entries)
  (pimacs--history-render-reset)
  (let* ((chunks (pimacs--history-split-entries entries))
         (eager (car (last chunks)))
         (pending (butlast chunks)))
    (if (null pending)
        (pimacs--render-session-entries entries)
      (pimacs--history-create-loading-section
       (pimacs--history-pending-entry-count pending))
      (pimacs--render-session-entries eager)
      (setq pimacs--history-render-boundary
            (cadr (pimacs-section-children pimacs-section--root-section)))
      (pimacs--history-start-idle-render pending))))


(defun pimacs-refresh-session (&optional callback)
  "Refresh the current session state.
CALLBACK is called after a successful refresh."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "get_entries" '()
     (pimacs--on-response-success-callback resp
       (let ((entries (plist-get (plist-get resp :data) :entries)))
         (pimacs--widget-save-excursion
           (pimacs--clear-sections)
           (pimacs--render-session-history entries)))
       (pimacs-section-autohide)
       (when callback
         (funcall callback))))))

(defun pimacs-clone ()
  "Clone the current session."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--widget-save-excursion
      (pimacs--clear-session-widgets))
    (pimacs--send-command
     "clone" '()
     (pimacs--on-response-success-callback resp
       (pimacs--unless-cancelled resp "Clone"
         (pimacs-refresh-session
          (lambda ()
            (pimacs--update-header-line)
            (pimacs--notify "Cloned to new session"))))))))

(defun pimacs-new-session ()
  "Start a new session."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--widget-save-excursion
      (pimacs--clear-sections)
      (pimacs--clear-session-widgets))
    (pimacs--send-command
     "new_session" '()
     (pimacs--on-response-success-callback resp
       (pimacs--update-header-line)
       (pimacs--unless-cancelled resp "New session"
         (pimacs--notify "New session started."))))))

(defun pimacs-set-session-name (name)
  "Set the session name to NAME."
  (interactive "sSession name: ")
  (let ((trimmed (string-trim name)))
    (if (string-empty-p trimmed)
        (message "Session name cannot be empty")
      (pimacs--with-chat-buffer
        (pimacs--send-command
         "set_session_name" (list :name trimmed)
         (pimacs--on-response-success-callback resp
           (rename-buffer (pimacs--chat-buffer-name trimmed) t)
           (pimacs--update-header-line)
           (pimacs--widget-save-excursion
             (pimacs--insert-session-info trimmed))))))))

(defun pimacs-export (&optional output-path)
  "Export the current session to OUTPUT-PATH."
  (interactive
   (list (when current-prefix-arg
           (expand-file-name
            (read-file-name "Export to file: ")))))
  (pimacs--with-chat-buffer
    (let ((args (if (and output-path (not (string-empty-p output-path)))
                    (list :outputPath (expand-file-name output-path))
                  '())))
      (pimacs--send-command
       "export_html" args
       (pimacs--on-response-success-callback resp
         (pimacs--update-header-line)
         (let ((path (plist-get (plist-get resp :data) :path)))
           (pimacs--widget-save-excursion
             (pimacs-section--create-section 'info pimacs-section--root-section
               (insert "Session exported to: ")
               (pimacs--insert-file-link path)))))))))

(defun pimacs-copy ()
  "Copy the last assistant message to the clipboard."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "get_last_assistant_text" '()
     (pimacs--on-response-success-callback resp
       (let ((text (plist-get (plist-get resp :data) :text)))
         (if text
             (progn
               (kill-new text)
               (message "Copied last assistant message to clipboard."))
           (message "No assistant message available to copy.")))))))

(defun pimacs-fork ()
  "Fork the current session from this point."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "get_fork_messages" '()
     (pimacs--on-response-success-callback resp
       (let* ((messages (plist-get (plist-get resp :data) :messages))
              (items
               (mapcar
                (lambda (m)
                  (cons (truncate-string-to-width (plist-get m :text) 80 nil nil t) m))
                messages)))
         (if (null items)
             (message "No fork points available.")
           (let* ((selected (pimacs--completing-read "Fork at message: " (reverse items)))
                  (message (pimacs--alist-get-equal selected items))
                  (entry-id (plist-get message :entryId))
                  (message-text (plist-get message :text)))
             (pimacs--widget-save-excursion
               (pimacs--clear-session-widgets))
             (pimacs--send-command
              "fork" (list :entryId entry-id)
              (pimacs--on-response-success-callback resp
                (pimacs--unless-cancelled resp "Fork"
                  (pimacs-refresh-session
                   (lambda ()
                     (pimacs--widget-save-excursion
                       (widget-value-set pimacs--prompt-widget (or message-text "")))
                     (pimacs-focus-prompt)
                     (pimacs--notify "Forked to new session")))
                  (pimacs--update-header-line)))))))))))

(defun pimacs-compact (&optional custom-instructions)
  "Compact the current session to reduce context usage.

With prefix argument, prompt for CUSTOM-INSTRUCTIONS to guide the
summarization."
  (interactive
   (list (when current-prefix-arg
           (read-string "Custom instructions for compaction: "))))
  (pimacs--with-chat-buffer
    (let ((args (if custom-instructions
                    (list :customInstructions custom-instructions)
                  '())))
      (pimacs--send-command
       "compact"
       args
       (pimacs--on-response-success-callback resp
         (pimacs--update-header-line))))))

(defun pimacs-set-auto-compaction (enabled)
  "Toggle auto compaction with ENABLED."
  (interactive (list (y-or-n-p "Enable auto compaction? ")))
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "set_auto_compaction" (list :enabled (if enabled t 'json-false))
     (pimacs--on-response-success-callback resp
       (pimacs--update-header-line)
       (pimacs--widget-save-excursion
         (pimacs-section--create-section 'info pimacs-section--root-section
           (insert (format "Compaction set to: %s" (if enabled "auto" "manual")))))))))

(defun pimacs-set-auto-retry (enabled)
  "Toggle auto retry with ENABLED."
  (interactive (list (y-or-n-p "Enable auto retry? ")))
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "set_auto_retry" (list :enabled (if enabled t 'json-false))
     (pimacs--on-response-success-callback resp
       (pimacs--update-header-line)
       (pimacs--widget-save-excursion
         (pimacs-section--create-section 'info pimacs-section--root-section
           (insert (format "Auto retry set to: %s" (if enabled "enabled" "disabled")))))))))

(defun pimacs-bash (command &optional exclude-from-context)
  "Run a bash COMMAND with optional EXCLUDE-FROM-CONTEXT flag."
  (interactive "sBash command: ")
  (unless (string-empty-p (string-trim command))
    (pimacs--with-chat-buffer
      (pimacs--update-agent-state 'bash)
      (let ((args (list :command command))
            (call-section (pimacs-section--new-section 'tool-call pimacs-section--root-section :padding "\n")))
        (when exclude-from-context
          (setq args (nconc args (list :excludeFromContext t))))
        (pimacs--insert-tool-call call-section "bash" args)
        (let ((request-id
               (pimacs--send-command
                "bash" args
                (lambda (resp)
                  (let ((request-id (plist-get resp :id)))
                    (when-let ((entry (gethash request-id pimacs--bash-executions)))
                      (pimacs--on-response-success resp
                        (pimacs--update-header-line)
                        (let* ((data (plist-get resp :data))
                               (output (plist-get data :output))
                               (result-section (pimacs-tool-call-result-section entry))
                               (call-section (pimacs-tool-call-call-section entry)))
                          (pimacs--widget-save-excursion
                            (setf (pimacs-tool-call-result-section entry)
                                  (pimacs-section--create-or-replace-section
                                      result-section 'tool-result call-section
                                    (pimacs--insert-tool-result "bash" output nil data))))))
                      (remhash request-id pimacs--bash-executions))
                    (pimacs--update-agent-state
                     (and (> (hash-table-count pimacs--bash-executions) 0) 'bash)))))))
          (puthash request-id
                   (make-pimacs-tool-call :call-section call-section
                                          :tool-name "bash"
                                          :args args)
                   pimacs--bash-executions))))))

;;; Chat mode

(defun pimacs--fetch-commands ()
  (pimacs--send-command
   "get_commands" '()
   (pimacs--on-response-success-callback resp
     (setq pimacs--commands
           (mapcar (lambda (c) (cons (plist-get c :name) c))
                   (plist-get (plist-get resp :data) :commands))))))

(defun pimacs--visit-file (result &optional other-window)
  (let ((file (plist-get result :file))
        (line (plist-get result :line))
        (column (plist-get result :column))
        (find-file-func (if other-window #'find-file-other-window #'find-file)))
    (when file
      (funcall find-file-func file)
      (when line
        (goto-char (point-min))
        (forward-line (1- line)))
      (when column
        (forward-char (min column (- (line-end-position) (point))))))))

(defun pimacs--visit-file-at-point (other-window)
  (when-let (file (pimacs--file-at-point))
    (pimacs--visit-file (list :file file) other-window)))

(defun pimacs-visit-item (&optional other-window)
  "Visit current item.
With a prefix argument OTHER-WINDOW, visit in other window."
  (interactive (list current-prefix-arg))
  (pimacs-section--section-case
      ((tool-result)
       (if-let* ((info (pimacs-section-info (pimacs-section--current-section)))
                 (tool-name (pimacs-section-tool-result-info-tool-name info))
                 (visitor (pimacs--alist-get-equal tool-name pimacs-visit-tool-result-functions)))
           (let* ((details (pimacs-section-tool-result-info-details info))
                  (args (pimacs-section-tool-result-info-args info)))
             (pimacs--visit-file (funcall visitor details args) other-window))
         (pimacs--visit-file-at-point other-window)))
    ((tool-call)
     (if-let* ((info (pimacs-section-info (pimacs-section--current-section)))
               (tool-name (pimacs-section-tool-call-info-tool-name info))
               (visitor (pimacs--alist-get-equal tool-name pimacs-visit-tool-call-functions)))
         (let ((args (pimacs-section-tool-call-info-args info)))
           (pimacs--visit-file (funcall visitor args) other-window))
       (pimacs--visit-file-at-point other-window)))
    (t
     (pimacs--visit-file-at-point other-window))))

(defun pimacs-visit-item-other-window ()
  "Visit current item in other window."
  (interactive)
  (pimacs-visit-item t))

(defun pimacs-goto-next-user-message ()
  "Go to the next user message."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs-section--goto-next-section-of-type 'user)))

(defun pimacs-goto-previous-user-message ()
  "Go to the previous user message."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs-section--goto-previous-section-of-type 'user)))

(defvar-keymap pimacs-chat-mode-map
  :doc "Keymap for `pimacs-chat-mode'."
  :parent special-mode-map
  "<remap> <keyboard-quit>" #'pimacs-abort
  "<left-fringe> <mouse-1>" #'pimacs-mouse-toggle-section
  "<left-fringe> <mouse-2>" #'pimacs-mouse-toggle-section
  "RET" #'pimacs-visit-item
  "M-RET" #'pimacs-visit-item-other-window
  "TAB" #'pimacs-toggle-section
  "C-i" #'pimacs-toggle-section
  "<backtab>" #'pimacs-section-cycle-global
  "1" #'pimacs-section-show-level-1
  "2" #'pimacs-section-show-level-2
  "3" #'pimacs-section-show-level-3
  "M-1" #'pimacs-section-show-level-1-all
  "M-2" #'pimacs-section-show-level-2-all
  "M-3" #'pimacs-section-show-level-3-all
  "n" #'pimacs-goto-next-section
  "M-n" #'pimacs-goto-next-section
  "N" #'pimacs-goto-next-user-message
  "p" #'pimacs-goto-previous-section
  "M-p" #'pimacs-goto-previous-section
  "P" #'pimacs-goto-previous-user-message
  "M-g l" #'pimacs-goto-last-section
  "l" #'pimacs-goto-last-section
  "i" #'pimacs-focus-prompt
  "q" #'pimacs-quit-chat)

(defvar pimacs-chat-widget-field-keymap
  (let ((map (make-sparse-keymap)))
    (keymap-set map "<remap> <keyboard-quit>" #'pimacs-abort)
    (keymap-set map "M-p" #'pimacs-previous-prompt)
    (keymap-set map "M-n" #'pimacs-next-prompt)
    (keymap-set map "C-r" #'pimacs-search-prompt)
    (keymap-set map "M-RET" #'pimacs-send-prompt-alternate)
    (keymap-set map "M-g l" #'pimacs-goto-last-section)
    (keymap-set map "<backtab>" #'pimacs-section-cycle-global)
    (keymap-set map "C-k" #'widget-kill-line)
    (keymap-set map "C-e" #'widget-end-of-line)
    (keymap-set map "C-m" #'widget-field-activate)
    map))

(defun pimacs--imenu-create-index ()
  "Build an imenu index from the top-level chat sections."
  (let ((groups (make-hash-table :test 'equal))
        result)
    (dolist (section (pimacs-section-children pimacs-section--root-section))
      (when-let ((pair (pcase (pimacs-section-type section)
                         ('user
                          (when-let ((info (pimacs-section-info section)))
                            (cons "user" (pimacs-section-user-info-header info))))
                         ((or 'assistant 'thinking)
                          (when-let ((info (pimacs-section-info section)))
                            (cons "assistant" (pimacs-section-assistant-info-header info))))
                         ('tool-call
                          (when-let ((info (pimacs-section-info section)))
                            (cons (pimacs-section-tool-call-info-tool-name info)
                                  (pimacs-section-tool-call-info-header info)))))))
        (push (cons (cdr pair) (marker-position (pimacs-section-beginning section)))
              (gethash (car pair) groups))))
    (maphash (lambda (name entries)
               (push (cons name (nreverse entries)) result))
             groups)
    result))

(define-derived-mode pimacs-chat-mode nil "pimacs-chat"
  "Major mode for pimacs chat.

\\{pimacs-chat-mode-map}"
  (buffer-disable-undo)
  (setq header-line-format
        '(:eval (pimacs--format-state-line pimacs-header-line-format)))
  (setq pimacs--tool-calls (make-hash-table :test 'equal))
  (setq pimacs--bash-executions (make-hash-table :test 'equal))
  (setq pimacs--content-sections (make-hash-table :test 'eql))
  (pimacs-section--create-root-section)
  (setq imenu-create-index-function #'pimacs--imenu-create-index)
  (setq pimacs--prompt-history (make-ring pimacs-prompt-history-max-size))
  (setq-local completion-at-point-functions
              (append (list #'pimacs--completion-at-point-slash
                            #'pimacs--completion-at-point-file)
                      completion-at-point-functions))
  (setq pimacs--spinner (spinner-create 'progress-bar))
  (setq pimacs--prompt-before-widget (widget-create 'pimacs-item :face 'pimacs-widget-face "\n"))
  (setq pimacs--attached-images-widget (widget-create 'pimacs-item :face 'pimacs-widget-face pimacs--empty-widget-text))
  (setq pimacs--prompt-widget
        (widget-create 'editable-field
                       :keymap pimacs-chat-widget-field-keymap
                       :help-echo ""
                       :format "%[user>%] %v"
                       :value-face 'pimacs-prompt-face
                       :button-face 'pimacs-chat-user-role-face
                       :action (lambda (widget &optional _event)
                                 (pimacs-send-prompt (widget-value widget)))))
  (setq pimacs--prompt-after-widget (widget-create 'pimacs-item :face 'pimacs-widget-face pimacs--empty-widget-text))
  (setq pimacs--prompt-widget-lines (make-hash-table :test 'equal))
  (setq pimacs--status-widget (widget-create 'pimacs-item :face 'pimacs-status-face pimacs--empty-widget-text))
  (setq pimacs--status-texts (make-hash-table :test 'equal))
  (setq-local dnd-protocol-alist
              (cons '("^file:" . pimacs--dnd-handler)
                    dnd-protocol-alist))
  (add-hook 'kill-buffer-hook #'pimacs--history-render-reset nil t)
  (when (fboundp 'yank-media-handler)
    (yank-media-handler (mapcar (lambda (pair) (intern (car pair))) pimacs--image-type-alist)
                        #'pimacs--yank-media-handler))
  (widget-setup)
  (pimacs-focus-prompt)
  (add-hook 'kill-buffer-hook #'pimacs--cleanup-chat-buffer nil t)
  (pimacs--register-agent-cleanup)
  (pimacs--register-event-listeners)
  (setq-local mode-line-misc-info
              (append (list '(:eval (pimacs--format-state-line pimacs-mode-line-format)))
                      mode-line-misc-info))
  (pimacs--update-header-line)
  (pimacs--fetch-commands))

(defun pimacs-chat--read-root (prompt _initial-input _history)
  (read-directory-name prompt default-directory nil t))

(defun pimacs-chat--transient-init-value (obj)
  (oset obj value (list (concat "--root=" (pimacs--project-root)))))

(defun pimacs-chat--start ()
  "Start the chat configured by the active transient."
  (interactive)
  (let ((args (transient-args 'pimacs-chat--transient)))
    (pimacs-chat--create (transient-arg-value "--name=" args)
                         (transient-arg-value "--root=" args))))

(transient-define-prefix pimacs-chat--transient ()
  "Configure and start a Pimacs chat."
  :init-value #'pimacs-chat--transient-init-value
  [["Options"
    ("n" "Session name" "--name=")
    ("r" "Root directory" "--root=" :always-read t :reader pimacs-chat--read-root)]
   ["Actions"
    ("RET" "Start chat" pimacs-chat--start)]])

(defun pimacs-chat--create (name root)
  (let* ((explicit-root root)
         (root (if explicit-root
                   (file-name-as-directory (expand-file-name explicit-root))
                 (pimacs--project-root)))
         (key (md5 (concat root (or name "")))))
    (let ((pimacs--project-root root)
          (pimacs--project-key key))
      (unless (pimacs--current-agent)
        (pimacs--start-agent key))
      (let ((chat-buffer (or (pimacs--current-chat)
                             (let ((buffer (generate-new-buffer (pimacs--chat-buffer-name name))))
                               (with-current-buffer buffer
                                 (setq-local pimacs--project-key key)
                                 (setq-local pimacs--project-root root)
                                 (setq-local default-directory root)
                                 (puthash key buffer pimacs--chats)
                                 (pimacs-chat-mode)
                                 (when name
                                   (pimacs-set-session-name name)))
                               buffer))))
        (pop-to-buffer chat-buffer)))))

;;;###autoload
(defun pimacs-chat (&optional name root)
  "Start a chat window with optional session NAME at ROOT.

With a prefix argument, show a transient for setting NAME and ROOT."
  (interactive)
  (if current-prefix-arg
      (pimacs-chat--transient)
    (pimacs-chat--create name root)))

(defun pimacs-toggle-chat ()
  "Toggle chat window."
  (interactive)
  (if-let* ((chat-buffer (pimacs--current-chat))
            (chat-window (get-buffer-window chat-buffer t)))
      (with-selected-window chat-window
        (if (one-window-p)
            (bury-buffer)
          (delete-window chat-window)))
    (pimacs-chat)))

(defun pimacs-quit-chat ()
  "Quit the current chat window."
  (interactive)
  (if-let (agent (pimacs--current-agent))
      (pimacs--kill-agent)
    (when-let (buffer (pimacs--current-chat))
      (kill-buffer buffer))))

(defun pimacs--switch-session (session-file message &optional cb)
  "Switch to an existing session file and refresh.
SESSION-FILE is the path to the session file to switch to.
MESSAGE is shown as a notification when complete.
If non-nil, call CB after the session refresh finishes."
  (pimacs--widget-save-excursion
    (pimacs--clear-session-widgets))
  (pimacs--send-command
   "switch_session" (list :sessionPath session-file)
   (pimacs--on-response-success-callback resp
     (pimacs--update-header-line)
     (pimacs--unless-cancelled resp "Session switch"
       (pimacs-refresh-session (lambda ()
                                 (pimacs--notify message)
                                 (when cb
                                   (funcall cb))))))))

(defun pimacs-reload ()
  "Reload agent configuration by restarting the agent process."
  (interactive)
  (pimacs--with-chat-buffer
    (pimacs--send-command
     "get_state" '()
     (pimacs--on-response-success-callback resp
       (let* ((data (plist-get resp :data))
              (session-file (plist-get data :sessionFile))
              (project-key pimacs--project-key)
              (chat-buffer (current-buffer)))
         (run-at-time
          0 nil
          (lambda ()
            (when (buffer-live-p chat-buffer)
              (with-current-buffer chat-buffer
                (pimacs-edit--close-for-chat chat-buffer)
                (pimacs--kill-agent pimacs--cleanup-callback-fn)
                (setq pimacs--retry-in-progress nil
                      pimacs--header-line-state nil
                      pimacs--commands nil)
                (pimacs-clear-project-file-cache)
                (pimacs--update-agent-state nil)
                (force-mode-line-update)
                (pimacs--widget-save-excursion
                  (pimacs--clear-sections)
                  (pimacs--clear-session-widgets))
                (pimacs--start-agent project-key)
                (pimacs--register-agent-cleanup)
                (pimacs--switch-session
                 session-file
                 "Reloaded extensions, skills and prompts."
                 (lambda ()
                   (pimacs--fetch-commands))))))))))))

(defun pimacs-restart-chat ()
  "Exit the current chat and restart."
  (interactive)
  (let ((root default-directory))
    (pimacs-quit-chat)
    (let ((default-directory root))
      (pimacs-chat))))

(provide 'pimacs)

;;; pimacs.el ends here
