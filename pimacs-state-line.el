;;; pimacs-state-line.el --- State line formatting -*- lexical-binding: t -*-

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

;; State line formatting for Pimacs.

;;; Code:

(require 'cl-lib)
(require 'ansi-color)
(require 'spinner)
(require 'timeout)
(require 'pimacs-utils)
(require 'pimacs-core)
(require 'pimacs-agent)

(defconst pimacs--state-line-format-type
  '(repeat (choice (string :tag "Literal text")
                   (function :tag "Formatter function")
                   (sexp :tag "Propertized or status component")
                   (const :tag "Model" :model)
                   (const :tag "Provider" :provider)
                   (const :tag "Thinking level" :thinking_level)
                   (const :tag "Session name" :session_name)
                   (const :tag "Project root" :project_root)
                   (const :tag "Compaction mode" :compaction_mode)
                   (const :tag "Message count" :message_count)
                   (const :tag "Pending message count" :pending_message_count)
                   (const :tag "User messages" :user_messages)
                   (const :tag "Assistant messages" :assistant_messages)
                   (const :tag "Tool calls" :tool_calls)
                   (const :tag "Tool results" :tool_results)
                   (const :tag "Total messages" :total_messages)
                   (const :tag "Input tokens" :input_tokens)
                   (const :tag "Output tokens" :output_tokens)
                   (const :tag "Cache-read tokens" :cache_read_tokens)
                   (const :tag "Cache-write tokens" :cache_write_tokens)
                   (const :tag "Total cache hit percent" :cache_hit_percent)
                   (const :tag "Total tokens" :total_tokens)
                   (const :tag "Session cost" :cost)
                   (const :tag "Context usage" :context_usage)
                   (const :tag "Context tokens" :context_tokens)
                   (const :tag "Context window" :context_window)
                   (const :tag "Agent state" :agent_state)
                   (const :tag "Spinner" :spinner)
                   (const :tag "Right-align remaining entries" :spacer)))
  "Custom type for Pimacs state-line formats.")

(defcustom pimacs-header-line-format
  '(:context_usage " (" :compaction_mode ")" :spacer "(" :provider ") " :model " • " :thinking_level)
  "Format of the Pimacs chat header line.

Strings are displayed literally.  Functions are called with the state
plist and their returned values are displayed.  A keyword component can
include text properties using `propertize' syntax.  For example:
\"`(:model face font-lock-function-name-face)'\".  A status component has
form `(:status STATUS-KEY PROPERTY VALUE...)'; it displays the text set
by an extension with STATUS-KEY and accepts optional text properties.
For example: `(:status \"xyz-status\" face font-lock-warning-face)'.

The following keywords are replaced with state information.

Session state keywords:
`:model'                    Model identifier.
`:provider'                 Model provider.
`:thinking_level'           Thinking level.
`:session_name'             Session name.
`:project_root'             Project root directory.
`:compaction_mode'          `auto' or `manual'.
`:message_count'            Message count.
`:pending_message_count'    Pending message count.

Session statistics keywords:
`:user_messages'            User message count.
`:assistant_messages'       Assistant message count.
`:tool_calls'               Tool call count.
`:tool_results'             Tool result count.
`:total_messages'           Total message count.
`:input_tokens'             Input token count.
`:output_tokens'            Output token count.
`:cache_read_tokens'        Cache-read token count.
`:cache_write_tokens'       Cache-write token count.
`:cache_hit_percent'        Total cache hit percentage.
`:total_tokens'             Total token count.
`:cost'                     Session cost.
`:context_usage'            Context tokens and context window.
`:context_tokens'           Context token count.
`:context_window'           Context window size.

UI keywords:
`:agent_state'              Current agent state.
`:spinner'                  Active agent spinner.
`:spacer'                   Space that right-aligns all following entries.

Status components:
`(:status STATUS-KEY ...)'  Extension status text for STATUS-KEY.

Use at most one `:spacer'."
  :type pimacs--state-line-format-type
  :group 'pimacs)

(defcustom pimacs-mode-line-format '(" Pimacs " :agent_state :spinner)
  "Format of the Pimacs mode-line entry.

See `pimacs-header-line-format' for available components."
  :type pimacs--state-line-format-type
  :group 'pimacs)

(pimacs--def-permanent-buffer-local pimacs--header-line-state nil)
(pimacs--def-permanent-buffer-local pimacs--agent-state nil)
(pimacs--def-permanent-buffer-local pimacs--spinner nil)

(defun pimacs--format-tool-state (tools)
  (pcase tools
    (`(,first ,second ,_ . ,rest)
     (format "%s, %s + %d more" first second (1+ (length rest))))
    (_
     (mapconcat #'identity tools ", "))))

(defun pimacs--format-agent-state (agent-state)
  (if agent-state
      (if (consp agent-state)
          (format "%s(%s)"
                  (car agent-state)
                  (pimacs--format-tool-state (cdr agent-state)))
        (format "%s" agent-state))
    "idle"))

(defun pimacs--format-state ()
  (pimacs--format-agent-state pimacs--agent-state))

(defun pimacs--state-line-state ()
  (append (list :spinner pimacs--spinner
                :agentState pimacs--agent-state
                :projectRoot pimacs--project-root
                :statusTexts pimacs--status-texts)
          pimacs--header-line-state))

(defun pimacs--format-state-line-value (value)
  (cond
   ((memq value '(nil json-null)) "?")
   (t (format "%s" value))))

(defun pimacs--format-state-line-model (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :model :id)))

(defun pimacs--format-state-line-provider (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :model :provider)))

(defun pimacs--format-state-line-thinking-level (state)
  (pimacs--format-state-line-value (plist-get state :thinkingLevel)))

(defun pimacs--format-state-line-session-name (state)
  (let ((name (plist-get state :sessionName)))
    (pimacs--format-state-line-value
     (if (and (stringp name) (not (string-empty-p name)))
         name
       (pimacs--short-uuid (pimacs--plist-get state :sessionStats :sessionId))))))

(defun pimacs--format-state-line-project-root (state)
  (pimacs--format-state-line-value (plist-get state :projectRoot)))

(defun pimacs--format-state-line-message-count (state)
  (pimacs--format-state-line-value (plist-get state :messageCount)))

(defun pimacs--format-state-line-pending-message-count (state)
  (pimacs--format-state-line-value (plist-get state :pendingMessageCount)))

(defun pimacs--format-state-line-context-usage (state)
  (format "%s/%s"
          (pimacs--format-number-short
           (pimacs--plist-get state :sessionStats :contextUsage :tokens))
          (pimacs--format-number-short
           (pimacs--plist-get state :sessionStats :contextUsage :contextWindow))))

(defun pimacs--format-state-line-context-tokens (state)
  (pimacs--format-state-line-value
   (pimacs--plist-get state :sessionStats :contextUsage :tokens)))

(defun pimacs--format-state-line-context-window (state)
  (pimacs--format-state-line-value
   (pimacs--plist-get state :sessionStats :contextUsage :contextWindow)))

(defun pimacs--format-state-line-compaction-mode (state)
  (if (eq (plist-get state :autoCompactionEnabled) t) "auto" "manual"))

(defun pimacs--format-state-line-user-messages (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :sessionStats :userMessages)))

(defun pimacs--format-state-line-assistant-messages (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :sessionStats :assistantMessages)))

(defun pimacs--format-state-line-tool-calls (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :sessionStats :toolCalls)))

(defun pimacs--format-state-line-tool-results (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :sessionStats :toolResults)))

(defun pimacs--format-state-line-total-messages (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :sessionStats :totalMessages)))

(defun pimacs--format-state-line-input-tokens (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :sessionStats :tokens :input)))

(defun pimacs--format-state-line-output-tokens (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :sessionStats :tokens :output)))

(defun pimacs--format-state-line-cache-read-tokens (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :sessionStats :tokens :cacheRead)))

(defun pimacs--format-state-line-cache-write-tokens (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :sessionStats :tokens :cacheWrite)))

(defun pimacs--format-state-line-cache-hit-percent (state)
  (let* ((input (pimacs--plist-get state :sessionStats :tokens :input))
         (cache-read (pimacs--plist-get state :sessionStats :tokens :cacheRead))
         (cache-write (pimacs--plist-get state :sessionStats :tokens :cacheWrite)))
    (if (and (numberp input) (numberp cache-read) (numberp cache-write))
        (let ((total (+ input cache-read cache-write)))
          (if (> total 0)
              (concat (pimacs--format-number-fixed
                       (* 100.0 (/ (float cache-read) total)) 1)
                      "%")
            "?"))
      "?")))

(defun pimacs--format-state-line-total-tokens (state)
  (pimacs--format-state-line-value (pimacs--plist-get state :sessionStats :tokens :total)))

(defun pimacs--format-state-line-cost (state)
  (let ((cost (pimacs--plist-get state :sessionStats :cost)))
    (if (numberp cost)
        (pimacs--format-number-fixed cost 6)
      (pimacs--format-state-line-value cost))))

(defun pimacs--format-state-line-agent-state (state)
  (pimacs--format-agent-state (plist-get state :agentState)))

(defun pimacs--format-state-line-spinner (state)
  "Return the spinner from STATE, prefixed with a space when active."
  (if-let ((spinner (plist-get state :spinner))
           (spinner-str (and (plist-get state :agentState)
                             (spinner-print spinner))))
      (concat " " spinner-str)
    ""))

(defun pimacs--format-state-line-status (state status-key)
  (when-let* ((status-texts (plist-get state :statusTexts))
              ((hash-table-p status-texts))
              ((stringp status-key))
              (text (gethash status-key status-texts)))
    (let ((text (replace-regexp-in-string "[\n\r]+" " " text)))
      (pimacs--apply-ansi-colors text))))

(defconst pimacs--state-line-formatters
  '((:model . pimacs--format-state-line-model)
    (:provider . pimacs--format-state-line-provider)
    (:thinking_level . pimacs--format-state-line-thinking-level)
    (:session_name . pimacs--format-state-line-session-name)
    (:project_root . pimacs--format-state-line-project-root)
    (:compaction_mode . pimacs--format-state-line-compaction-mode)
    (:message_count . pimacs--format-state-line-message-count)
    (:pending_message_count . pimacs--format-state-line-pending-message-count)
    (:context_usage . pimacs--format-state-line-context-usage)
    (:context_tokens . pimacs--format-state-line-context-tokens)
    (:context_window . pimacs--format-state-line-context-window)
    (:user_messages . pimacs--format-state-line-user-messages)
    (:assistant_messages . pimacs--format-state-line-assistant-messages)
    (:tool_calls . pimacs--format-state-line-tool-calls)
    (:tool_results . pimacs--format-state-line-tool-results)
    (:total_messages . pimacs--format-state-line-total-messages)
    (:input_tokens . pimacs--format-state-line-input-tokens)
    (:output_tokens . pimacs--format-state-line-output-tokens)
    (:cache_read_tokens . pimacs--format-state-line-cache-read-tokens)
    (:cache_write_tokens . pimacs--format-state-line-cache-write-tokens)
    (:cache_hit_percent . pimacs--format-state-line-cache-hit-percent)
    (:total_tokens . pimacs--format-state-line-total-tokens)
    (:cost . pimacs--format-state-line-cost)
    (:agent_state . pimacs--format-state-line-agent-state)
    (:spinner . pimacs--format-state-line-spinner))
  "Alist mapping state line keywords to formatter functions.")

(defun pimacs--format-state-line-component (state component)
  (cond
   ((stringp component) component)
   ((and (consp component) (eq (car component) :status))
    (let ((status-key (cadr component)))
      (unless (stringp status-key)
        (error "Pimacs status component requires a string status key: %S" component))
      (apply #'propertize
             (or (pimacs--format-state-line-status state status-key) "")
             (cddr component))))
   ((and (consp component) (keywordp (car component)))
    (apply #'propertize
           (pimacs--format-state-line-component state (car component))
           (cdr component)))
   ((keywordp component)
    (if-let ((formatter (alist-get component pimacs--state-line-formatters)))
        (funcall formatter state)
      (error "Unknown Pimacs state-line component: %S" component)))
   ((functionp component) (funcall component state))
   (t (error "Unknown Pimacs state-line component: %S" component))))

(defun pimacs--escape-mode-line-percent (text)
  "Escape percent characters in TEXT while preserving text properties.

Unlike `replace-regexp-in-string', this preserves TEXT's properties."
  (let ((start 0)
        parts)
    (while (string-match "%" text start)
      (push (substring text start (match-beginning 0)) parts)
      (let ((percent (substring text (match-beginning 0) (match-end 0))))
        (push percent parts)
        (push percent parts))
      (setq start (match-end 0)))
    (push (substring text start) parts)
    (apply #'concat (nreverse parts))))

(defun pimacs--format-state-line (format)
  "Format the current state according to FORMAT."
  (let ((state (pimacs--state-line-state))
        (spacer-position (cl-position :spacer format)))
    (when (and spacer-position
               (cl-position :spacer format :start (1+ spacer-position)))
      (error "State line format may contain only one `:spacer'"))
    (let* ((left-components (if spacer-position
                                (cl-subseq format 0 spacer-position)
                              format))
           (right-components (and spacer-position
                                  (cl-subseq format (1+ spacer-position))))
           (format-component
            (apply-partially #'pimacs--format-state-line-component state))
           (left (mapconcat format-component left-components ""))
           (right (mapconcat format-component right-components "")))
      (pimacs--escape-mode-line-percent
       (if spacer-position
           (concat left
                   (make-string (max 1 (- (window-width)
                                          (length left)
                                          (length right)))
                                ?\s)
                   right)
         left)))))

(defun pimacs--set-header-line-state (state stats)
  (setq pimacs--header-line-state
        (plist-put state :sessionStats stats))
  (force-mode-line-update))

(defun pimacs--update-header-line ()
  (let* ((state-result nil)
         (stats-result nil)
         (try-update
          (lambda ()
            (when (and state-result stats-result)
              (pimacs--set-header-line-state state-result stats-result)))))
    (pimacs--send-command
     "get_state" '()
     (lambda (resp)
       (when (pimacs--response-success-p resp)
         (setq state-result (plist-get resp :data))
         (funcall try-update))))
    (pimacs--send-command
     "get_session_stats" '()
     (lambda (resp)
       (when (pimacs--response-success-p resp)
         (setq stats-result (plist-get resp :data))
         (funcall try-update))))))

(timeout-debounce 'pimacs--update-header-line 1)

(provide 'pimacs-state-line)
;;; pimacs-state-line.el ends here
