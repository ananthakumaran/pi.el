---
title: Pimacs User Manual v0.7.0-pre
---

# Introduction

Pimacs is an Emacs client for [Pi Coding Agent](https://pi.dev/). It
provides an interactive interface to the Pi Coding Agent directly from
Emacs.

# Setup

## Install the Pi Agent

First, install the Pi agent using npm:

    npm install -g --ignore-scripts @earendil-works/pi-coding-agent

Pimacs does not yet support authentication configuration. To configure
your provider, run `pi` in a terminal, then run `/login` in Pi.

## Install `pimacs.el`

Pimacs is available from [MELPA Stable](https://stable.melpa.org/),
which is recommended for installation. Add it to your package archives,
then install with `use-package`:

    (add-to-list 'package-archives
                 '("melpa-stable" . "https://stable.melpa.org/packages/") t)

    (use-package pimacs
      :ensure t)

# Doctor

Run `M-x pimacs-doctor` to display a dependency report. It checks that
Pi is available and meets the minimum supported version, and that
Tree-sitter and the Markdown grammars are installed. When Pi or either
grammar is missing, the report provides a button to install it.

# Usage

Run `M-x pimacs-chat` from any file in your project to start a Pimacs
chat session. Use a prefix argument (`C-u M-x pimacs-chat`) to open a
transient where you can set a session name and root directory. Setting a
root directory starts the chat there instead of using `project.el` to
find the project root. Run `M-x pimacs-switch-session` to switch between
any active chat sessions.

The chat buffer is read-only except for the prompt input area. Use `RET`
to submit a prompt and `C-j` to insert a newline. Press `i` from
anywhere in the chat buffer to move point to the prompt input area.

## Slash Commands

[Slash commands](https://pi.dev/docs/latest/usage#slash-commands)
support completion in the prompt buffer. Type `/` and press `C-M-i` (or
any key bound to completion) to see available commands.

In addition to the commands listed below, extension commands, prompt
templates, and skills registered with the Pi agent can also be invoked
via slash commands. These are fetched automatically from the agent and
included in the completion list.

Angle brackets `<>` denote required arguments, square brackets `[]`
denote optional arguments.

| Command                 | Arguments  | Description                                                              |
|-------------------------|------------|--------------------------------------------------------------------------|
| `/compact`              | `[prompt]` | Manually compact context, optionally with custom instructions.           |
| `/clear-queue`          |            | Discard all queued steering and follow-up messages.                      |
| `/edit-queue`           |            | Move queued steering and follow-up messages into the prompt for editing. |
| `/clone`                |            | Duplicate the current active branch into a new session.                  |
| `/copy`                 |            | Copy last assistant message to clipboard.                                |
| `/cycle-model`          |            | Cycle through available models.                                          |
| `/cycle-thinking-level` |            | Cycle through thinking levels.                                           |
| `/exit`                 |            | Quit pimacs.                                                             |
| `/export`               | `[file]`   | Export session to HTML.                                                  |
| `/fork`                 |            | Create a new session from a previous user message.                       |
| `/model`                |            | Switch models.                                                           |
| `/name`                 | `<name>`   | Set session display name.                                                |
| `/new`                  |            | Start a new session.                                                     |
| `/quit`                 |            | Quit pimacs.                                                             |
| `/reload`               |            | Reload extensions, skills and prompts.                                   |
| `/resume`               |            | Pick from previous sessions.                                             |
| `/session`              |            | Show session file, ID, messages, tokens, and cost.                       |
| `/set-auto-compaction`  |            | Set auto compaction.                                                     |
| `/set-auto-retry`       |            | Set auto retry.                                                          |
| `/set-follow-up-mode`   |            | Set follow-up mode.                                                      |
| `/set-steering-mode`    |            | Set steering mode.                                                       |
| `/set-thinking-level`   |            | Set thinking level.                                                      |

## File Name Completion

Type `@` followed by a partial file path to trigger file name completion
in the prompt buffer. The completion backend is controlled by
`pimacs-file-completion-backend`.

## Bash

Prefix a command with `!` to run it in Bash. Use `!!` to run a command
without adding it to the conversation context.

    ! echo "hello"

## Sending Context

You can send contextual information from any buffer to the Pimacs chat
prompt.

| Command                       | Description                                                                                                                           |
|-------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| `pimacs-send-region`          | Append the selected region to the prompt input.                                                                                       |
| `pimacs-send-filename`        | Append the current buffer’s filename (prefixed with `@`) to the prompt input.                                                         |
| `pimacs-send-flycheck-errors` | Append the Flycheck errors at point to the prompt input. Falls back to all current errors in the buffer when there are none at point. |

## Images

You can attach images to your prompt to provide visual context to the
agent. Images are displayed as thumbnail previews above the prompt input
area and are sent along with your message. The agent may also render
images inline in its responses, for example when using the `read` tool
on a file that contains images.

### Supported Formats

The following image formats are supported:

- PNG

- JPEG

- GIF

- WebP

Drag an image file from your file manager and drop it into the Pimacs
chat buffer, or paste a supported image from the clipboard via
`yank-media`. To remove an attached image, click on the thumbnail with
the mouse, or place point on it and press `backspace` or `delete`.

## State Lines

The header line displays session context and model information. The mode
line displays the current agent state. Customize them with the
`pimacs-header-line-format` and `pimacs-mode-line-format` defcustoms.
Both accept strings and state components; use `:spacer` to right-align
following components.

    (setq pimacs-header-line-format
          '(:context_usage :spacer
            (:model face font-lock-function-name-face)))

See `pimacs-header-line-format` for available components. A component
may also be a function that receives the current state plist.

Extension status text can be placed in either state line with a
`(:status STATUS-KEY ...)` component. STATUS-KEY is the key used by the
extension’s status update. Text properties after the key customize the
status at that placement.

    (setq pimacs-header-line-format
          '(:context_usage " " (:status "xyz-status" face font-lock-warning-face)
            :spacer :model))

By default, status text also appears beside the prompt. To display a
status only in a state line, add its key to
`pimacs-status-widget-hidden-keys`.

    (setq pimacs-status-widget-hidden-keys '("xyz-status"))

## Managing Sessions

Use `pimacs-switch-session` to switch between active Pimacs chat
sessions using completion. Use `pimacs-list-sessions` to display all
active chat sessions in a sortable tabulated list. Press `RET` to visit
the session on the current line and `g` to refresh the list. Select a
column header to sort by that column.

Customize the list’s columns and initial sort order with
`pimacs-list-sessions-table` and `pimacs-list-sessions-sort-key`.

## Section Visibility

Pimacs represents the chat as a hierarchy of sections. Every non-root
section has a type, a visibility state, and may have a parent or
children. Put point in a section and run `M-x pimacs-describe-section`
to open a Help buffer with these details. The report shows the section’s
`type`, visibility and user override state, automatic-hiding
eligibility, applied face, buffer positions, and metadata. Parent and
child section types are links; use `RET` to follow them. The `type`
value is the symbol to use when configuring section faces or automatic
hiding, such as `tool-call`.

Use `TAB` or `C-i` to toggle the section at point. Hiding a section
keeps its first line visible, so it can be shown again. On graphical
displays, the fringe indicator can also be selected with the mouse to
toggle visibility. Use `S-TAB` to cycle the visibility of the entire
chat, or `1`, `2`, and `3` to show progressively more of the tree around
point. `M-1`, `M-2`, and `M-3` do the same for every top-level section.
See [Keybindings](#Keybindings) for the complete list of visibility and
navigation commands.

As a conversation grows, Pimacs automatically hides older top-level
sections. `pimacs-section-autohide-count` sets how many eligible recent
sections remain visible; its default is 2, and `nil` disables automatic
hiding. Use `pimacs-section-autohide-filter` to select the eligible
section types. For example, the following keeps four eligible sections
visible while never automatically hiding user sections:

    (setq pimacs-section-autohide-count 4
          pimacs-section-autohide-filter '(:exclude user))

Automatic hiding does not override a section whose visibility you
explicitly toggled with `TAB` or `C-i`. Set
`pimacs-section-visibility-indicators` to `nil` to disable the fringe
indicators.

# UI Customization

Pimacs renders the chat as a sequence of sections. Each section type has
a face, so the chat can be styled without changing the Markdown
renderer. Customize `pimacs-section-type-faces` to select the face for a
section type, and customize the selected face with `M-x customize-face`.

The built-in section faces are listed in [Custom Faces](#Custom-Faces).

## Common Styling Effects

A section face supplies the base appearance for one kind of chat
content. Only the attributes that you set take effect; leave an
attribute unspecified when the Markdown or role styling should continue
to provide it.

For a coloured assistant card that preserves Markdown colours, set only
a background and `:extend t`:

    (set-face-attribute 'pimacs-section-assistant-face nil
                        :background "#18212b"
                        :extend t)

Set `:foreground` when every part of a section should use one colour.
Otherwise, leave it as `unspecified` to retain Markdown heading, link,
and syntax colours. Likewise, set `:height` or `:slant` to make a
section compact or italic, and leave `:weight` unspecified when Markdown
bold text should remain bold.

Role labels such as `assistant>` and tool names retain their own
recognizable colours by default. Configure their faces separately when
you want to change them.

## Cards and Padding

Section faces are also applied to `pimacs-section-padding`. Specify both
`:background` and `:extend t` for a full-width card background; the
background then also covers empty padding lines.

Thinking defaults to `shadow`. A compact, more subdued thinking card can
be configured as follows:

    (set-face-attribute 'pimacs-section-thinking-face nil
                        :foreground "#64707c"
                        :background "#131a21"
                        :height 0.9
                        :extend t)

## Choosing Section Faces

The type-to-face mapping is evaluated when a section is created. Change
one entry without replacing the other defaults with `alist-get`:

    (setf (alist-get 'tool-result pimacs-section-type-faces)
          'my-pimacs-tool-result-face)

Define a named face when several attributes belong together:

    (defface my-pimacs-tool-result-face
      '((t :inherit fixed-pitch
           :foreground "#c2cbd5"
           :background "#1a2027"
           :extend t))
      "My Pimacs tool result face.")

Changing a face updates already-displayed text immediately. Changing
`pimacs-section-type-faces` affects newly created sections; recreate the
chat contents to apply a new mapping to existing sections.

## Prompt Face

The editable portion of the prompt uses `pimacs-prompt-face` and can be
customized independently:

    (set-face-attribute 'pimacs-prompt-face nil
                        :foreground "#d7e0e8"
                        :background "#202936"
                        :extend t)

The `user>` prompt label uses `pimacs-chat-user-role-face`.

# Sandbox

To run Pi inside a sandbox, customize `pimacs-executable` and
`pimacs-flags`:

    (setq pimacs-executable "nono")
    (setq pimacs-flags '("run" "--silent" "--profile" "pi" "--allow-cwd" "--" "pi"
                     "--tools" "read,bash,edit,write,grep,find,ls"))

# How It Works

Emacs starts Pi in [RPC mode](https://pi.dev/docs/latest/rpc). In this
setup, Pi handles the agent logic while Emacs provides the user
interface. Some features, such as `/login` and `/logout`, are not
[supported](https://github.com/earendil-works/pi/issues/885) because
they are not currently exposed through the RPC API.

## Extension UI

Pimacs supports the RPC-compatible extension UI methods: notifications,
selection, confirmation, text input, editing text in an Emacs buffer,
setting the prompt text and chat title, prompt widgets, and status text.
Extension commands, tools, hooks, and custom messages are also
supported.

Pimacs does not support terminal-specific extension UI features,
including `ctx.ui.custom()` components, component factories, extension
keyboard shortcuts, or custom TUI rendering callbacks. Extensions should
use the supported UI methods when running in RPC mode. See the [Pi
extension documentation](https://pi.dev/docs/latest/extensions) for the
full extension API.

# Keybindings

## Chat Buffer Keybindings

| Key          | Command                             | Description                                                                                      |
|--------------|-------------------------------------|--------------------------------------------------------------------------------------------------|
| `RET`        | `pimacs-visit-item`                 | Jump to the source location at point; with a prefix argument, open in another window             |
| `C-g`        | `pimacs-abort`                      | Abort the current operation and restore queued messages to the prompt.                           |
| `e`          | `pimacs-edit-queue`                 | Move queued steering and follow-up messages into the prompt for editing                          |
| `k`          | `pimacs-clear-queue`                | Discard all queued steering and follow-up messages                                               |
| `TAB`, `C-i` | `pimacs-toggle-section`             | Toggle visibility of the section at point                                                        |
| `S-TAB`      | `pimacs-section-cycle-global`       | Cycle global section visibility, hiding all sections and then expanding one more level at a time |
| `1`          | `pimacs-section-show-level-1`       | Show the current section tree at the first level                                                 |
| `2`          | `pimacs-section-show-level-2`       | Show the current section tree through the second level                                           |
| `3`          | `pimacs-section-show-level-3`       | Show the current section tree through the third level                                            |
| `M-1`        | `pimacs-section-show-level-1-all`   | Show only headings of all root sections                                                          |
| `M-2`        | `pimacs-section-show-level-2-all`   | Show root sections and only headings of their children                                           |
| `M-3`        | `pimacs-section-show-level-3-all`   | Show sections through the second level and headings at the third                                 |
| `n`, `M-n`   | `pimacs-goto-next-section`          | Move to the next section                                                                         |
| `N`          | `pimacs-goto-next-user-message`     | Move to the next user message                                                                    |
| `p`, `M-p`   | `pimacs-goto-previous-section`      | Move to the previous section                                                                     |
| `P`          | `pimacs-goto-previous-user-message` | Move to the previous user message                                                                |
| `l`, `M-g l` | `pimacs-goto-last-section`          | Jump to the most recent section                                                                  |
| `i`          | `pimacs-focus-prompt`               | Focus the prompt input field                                                                     |
| `q`          | `pimacs-quit-chat`                  | Quit the chat buffer                                                                             |

## Prompt Input Keybindings

| Key       | Command                        | Description                                                             |
|-----------|--------------------------------|-------------------------------------------------------------------------|
| `C-g`     | `pimacs-abort`                 | Abort the current operation and restore queued messages to the prompt.  |
| `C-c C-e` | `pimacs-edit-queue`            | Move queued steering and follow-up messages into the prompt for editing |
| `C-c C-k` | `pimacs-clear-queue`           | Discard all queued steering and follow-up messages                      |
| `M-p`     | `pimacs-previous-prompt`       | Recall the previous prompt from history                                 |
| `M-n`     | `pimacs-next-prompt`           | Recall the next prompt from history                                     |
| `C-r`     | `pimacs-search-prompt`         | Search prompt history                                                   |
| `RET`     | `widget-field-activate`        | Send the current prompt                                                 |
| `M-RET`   | `pimacs-send-prompt-alternate` | Send the prompt using the alternate streaming behavior                  |
| `M-g l`   | `pimacs-goto-last-section`     | Jump to the most recent section                                         |
| `S-TAB`   | `pimacs-section-cycle-global`  | Cycle global section visibility                                         |

# Custom Variables

pimacs-status-widget-hidden-keys

User Option

:

pimacs-status-widget-hidden-keys

nil

> Status keys to hide from the default status widget.
>
> Hidden statuses remain available to `(:status STATUS-KEY ...)`
> components in `pimacs-header-line-format` and
> `pimacs-mode-line-format`. Hover over a status in the default widget
> to see its key.

pimacs-file-completion-backend

User Option

:

pimacs-file-completion-backend

'project

> Completion backend for prefixed file paths in prompts. `project` uses
> `project-files` to list files in the current project. `file` uses
> `file-name-all-completions` to list files under the project root.

pimacs-prompt-history-max-size

User Option

:

pimacs-prompt-history-max-size

500

> Maximum number of prompt history entries to keep.

pimacs-resume-max-sessions

User Option

:

pimacs-resume-max-sessions

100

> Maximum number of recent sessions to list when resuming a session.

pimacs-prompt-streaming-behavior

User Option

:

pimacs-prompt-streaming-behavior

'followUp

> Default streaming behavior for prompts.
>
> `steer`: Queue the message while the agent is running. It is delivered
> after the current assistant turn finishes executing its tool calls,
> before the next LLM call.
>
> `followUp`: Wait until the agent finishes. Message is delivered only
> when agent stops.

pimacs-markdown-renderer

User Option

:

pimacs-markdown-renderer

\#'pimacs--render-markdown

> Function used to render Markdown content.
>
> Pi calls it as `(RENDERER :create)`, `(RENDERER :stream STATE TEXT)`,
> `(RENDERER :final STATE TEXT)`, and `(RENDERER :destroy STATE)`.
> `:create` returns opaque renderer state. `:stream` and `:final` return
> `:append`, `:delete`, and `:replace-suffix` operations. `:destroy`
> releases resources.
>
> The default uses the incremental Tree-sitter Markdown renderer. It
> requires the Markdown and Markdown Inline Tree-sitter grammars.

pimacs-thinking-renderer

User Option

:

pimacs-thinking-renderer

\#'pimacs--render-markdown

> Function used to render assistant thinking content.
>
> It implements the same `:create`, `:stream`, `:final`, and `:destroy`
> renderer protocol as `pimacs-markdown-renderer`.
>
> The default uses the same incremental Tree-sitter Markdown renderer as
> regular assistant content. It falls back to plain-text rendering when
> the required grammars are unavailable.

pimacs-slash-commands

User Option

:

pimacs-slash-commands

>     '(("model" pimacs-select-model 0 "Switch models")
>       ("new" pimacs-new-session 0 "Start a new session")
>       ("reload" pimacs-reload 0 "Reload extensions, skills and prompts")
>       ("resume" pimacs-resume 0 "Pick from previous sessions")
>       ("compact" pimacs-compact 1 "Manually compact context, optionally with custom instructions")
>       ("set-auto-compaction" pimacs-set-auto-compaction 0 "Set auto compaction")
>       ("set-auto-retry" pimacs-set-auto-retry 0 "Set auto retry")
>       ("session" pimacs-session-stats 0 "Show session file, ID, messages, tokens, and cost")
>       ("name" pimacs-set-session-name 1 "Set session display name")
>       ("set-thinking-level" pimacs-set-thinking-level 0 "Set thinking level")
>       ("cycle-model" pimacs-cycle-model 0 "Cycle through available models")
>       ("cycle-thinking-level" pimacs-cycle-thinking-level 0 "Cycle through thinking levels")
>       ("set-steering-mode" pimacs-set-steering-mode 0 "Set steering mode")
>       ("set-follow-up-mode" pimacs-set-follow-up-mode 0 "Set follow-up mode")
>       ("clear-queue" pimacs-clear-queue 0 "Clear queued steering and follow-up messages")
>       ("edit-queue" pimacs-edit-queue 0 "Edit queued steering and follow-up messages")
>       ("fork" pimacs-fork 0 "Create a new session from a previous user message")
>       ("clone" pimacs-clone 0 "Duplicate the current active branch into a new session")
>       ("copy" pimacs-copy 0 "Copy last assistant message to clipboard")
>       ("export" pimacs-export 1 "Export session to HTML")
>       ("quit" pimacs-quit-chat 0 "Quit pimacs")
>       ("exit" pimacs-quit-chat 0 "Quit pimacs"))
>
> Alist mapping slash command names to command specs.
>
> Each entry is (NAME COMMAND MAX-ARGS DESCRIPTION) where NAME is the
> command string without the leading slash, COMMAND is a command symbol,
> MAX-ARGS is 0 or 1 indicating the number of optional string arguments
> the command accepts, and DESCRIPTION is a short description string.

pimacs-insert-tool-args-functions

User Option

:

pimacs-insert-tool-args-functions

>     '(("read" . pimacs--insert-read-args)
>       ("write" . pimacs--insert-write-args)
>       ("edit" . pimacs--insert-edit-args)
>       ("bash" . pimacs--insert-bash-args)
>       ("grep" . pimacs--insert-grep-args)
>       ("find" . pimacs--insert-find-args)
>       ("ls" . pimacs--insert-ls-args))
>
> Alist mapping tool names to inserter functions.
>
> Each entry is (TOOL-NAME . FUNCTION) where FUNCTION is called with
> ARGS plist to insert formatted tool call arguments.

pimacs-insert-tool-result-functions

User Option

:

pimacs-insert-tool-result-functions

>     '(("bash" . pimacs--insert-bash-result)
>       ("read" . pimacs--insert-read-result)
>       ("write" . pimacs--insert-write-result)
>       ("edit" . pimacs--insert-edit-result)
>       ("grep" . pimacs--insert-grep-result)
>       ("find" . pimacs--insert-find-result)
>       ("ls" . pimacs--insert-ls-result))
>
> Alist mapping tool names to result inserter functions.
>
> Each entry is (TOOL-NAME . FUNCTION) where FUNCTION is called with
> (CONTENT DETAILS ARGS) to insert the tool execution result. CONTENT is
> a list of content items. Use `pimacs--insert-content` to render it, or
> `pimacs--content-text` to extract text from content.

pimacs-visit-tool-result-functions

User Option

:

pimacs-visit-tool-result-functions

>     '(("read" . pimacs--visit-read-result)
>       ("write" . pimacs--visit-write-result)
>       ("edit" . pimacs--visit-edit-result)
>       ("grep" . pimacs--visit-grep-result))
>
> Alist mapping tool names to result visitor functions.
>
> Each entry is (TOOL-NAME . FUNCTION) where FUNCTION is called with
> (DETAILS ARGS) to visit the relevant location of the tool result.

pimacs-visit-tool-call-functions

User Option

:

pimacs-visit-tool-call-functions

>     '(("read" . pimacs--visit-read-call)
>       ("write" . pimacs--visit-write-call)
>       ("edit" . pimacs--visit-edit-call))
>
> Alist mapping tool names to call visitor functions.
>
> Each entry is (TOOL-NAME . FUNCTION) where FUNCTION is called with
> (ARGS) to visit the relevant location of the tool call.

pimacs-insert-custom-message-functions

User Option

:

pimacs-insert-custom-message-functions

'()

> Alist mapping custom message types to inserter functions.
>
> Each entry is (CUSTOM-TYPE . FUNCTION) where FUNCTION is called with
> the message plist to insert the custom message content.

pimacs-send-pop-to-chat

User Option

:

pimacs-send-pop-to-chat

t

> Whether to pop to the chat buffer after sending region, filename or
> errors.

pimacs-chat-keep-input-at-bottom

User Option

:

pimacs-chat-keep-input-at-bottom

t

> Whether to keep the input area at the bottom as new chat content is
> added.

pimacs-list-sessions-table

User Option

:

pimacs-list-sessions-table

>     '(("Session" . (:session_name face font-lock-type-face))
>       ("Provider" . :provider)
>       ("Model" . :model)
>       ("State" . (:agent_state face font-lock-constant-face))
>       ("Context" . (:context_usage face shadow))
>       ("Messages" . :total_messages)
>       ("Cost" . (:cost face shadow))
>       ("Project" . (:project_root face shadow)))
>
> Columns displayed by `pimacs-list-sessions`.
>
> Each entry is (HEADER . COMPONENT). COMPONENT uses the same format as
> an entry in `pimacs-header-line-format`.

pimacs-list-sessions-sort-key

User Option

:

pimacs-list-sessions-sort-key

'("Session" . nil)

> Initial sort order for `pimacs-list-sessions`.
>
> The car is a header from `pimacs-list-sessions-table`. A non-nil cdr
> sorts in descending order.

pimacs-sync-request-timeout

User Option

:

pimacs-sync-request-timeout

2

> The number of seconds to wait for a sync response.

pimacs-executable

User Option

:

pimacs-executable

"pi"

> Pi command executable name.

pimacs-process-environment

User Option

:

pimacs-process-environment

'()

> List of extra environment variables to use when starting pimacs.

pimacs-flags

User Option

:

pimacs-flags

'()

> List of additional flags to provide when starting pimacs.

pimacs-log-rpc

User Option

:

pimacs-log-rpc

nil

> When non-nil, log all RPC JSON to `pimacs-log-rpc-file`.

pimacs-log-rpc-file

User Option

:

pimacs-log-rpc-file

(expand-file-name "pimacs.el.log" (temporary-file-directory))

> File to write RPC JSON log entries to.

pimacs-use-ansi-colors

User Option

:

pimacs-use-ansi-colors

t

> Whether to render ANSI colors in widget and status output.

pimacs-header-line-format

User Option

:

pimacs-header-line-format

'(:context_usage " (" :compaction_mode ")" :spacer "(" :provider ") "
:model " • " :thinking_level)

> Format of the Pimacs chat header line.
>
> Strings are displayed literally. Functions are called with the state
> plist and their returned values are displayed. A keyword component can
> include text properties using `propertize` syntax. For example:
> "`(:model face font-lock-function-name-face)`". A status component has
> form `(:status STATUS-KEY PROPERTY VALUE...)`; it displays the text
> set by an extension with STATUS-KEY and accepts optional text
> properties. For example:
> `(:status "xyz-status" face font-lock-warning-face)`.
>
> The following keywords are replaced with state information.
>
> Session state keywords:
>
> `:model`  
> Model identifier.
>
> `:provider`  
> Model provider.
>
> `:thinking_level`  
> Thinking level.
>
> `:session_name`  
> Session name.
>
> `:project_root`  
> Project root directory.
>
> `:compaction_mode`  
> `auto` or `manual`.
>
> `:message_count`  
> Message count.
>
> `:pending_message_count`  
> Pending message count.
>
> Session statistics keywords:
>
> `:user_messages`  
> User message count.
>
> `:assistant_messages`  
> Assistant message count.
>
> `:tool_calls`  
> Tool call count.
>
> `:tool_results`  
> Tool result count.
>
> `:total_messages`  
> Total message count.
>
> `:input_tokens`  
> Input token count.
>
> `:output_tokens`  
> Output token count.
>
> `:cache_read_tokens`  
> Cache-read token count.
>
> `:cache_write_tokens`  
> Cache-write token count.
>
> `:cache_hit_percent`  
> Total cache hit percentage.
>
> `:total_tokens`  
> Total token count.
>
> `:cost`  
> Session cost.
>
> `:context_usage`  
> Context tokens and context window.
>
> `:context_tokens`  
> Context token count.
>
> `:context_window`  
> Context window size.
>
> UI keywords:
>
> `:agent_state`  
> Current agent state.
>
> `:spinner`  
> Active agent spinner.
>
> `:spacer`  
> Space that right-aligns all following entries.
>
> Status components: `(:status STATUS-KEY ...)` Extension status text
> for STATUS-KEY.
>
> Use at most one `:spacer`.

pimacs-mode-line-format

User Option

:

pimacs-mode-line-format

'(" Pimacs " :agent_state :spinner)

> Format of the Pimacs mode-line entry.
>
> See `pimacs-header-line-format` for available components.

pimacs-markdown-leading-newline-block-types

User Option

:

pimacs-markdown-leading-newline-block-types

>     '("pipe_table"
>       "fenced_code_block"
>       "indented_code_block"
>       "block_quote"
>       "list"
>       "thematic_break"
>       "html_block")
>
> List of Markdown block node types. Render these on a fresh line when
> the renderer starts mid-line.

pimacs-markdown-incremental-render-debug

User Option

:

pimacs-markdown-incremental-render-debug

nil

> Whether to capture incremental Markdown rendering diagnostics.
>
> When non-nil, diagnostics are appended to the temporary buffer
> `*pimacs-markdown-incremental-debug*`.

pimacs-markdown-use-unicode-tables

User Option

:

pimacs-markdown-use-unicode-tables

t

> Whether to render Markdown tables with Unicode borders.

pimacs-section-autohide-count

User Option

:

pimacs-section-autohide-count

2

> Automatically hide older chat sections beyond this count. This helps
> reduce clutter by collapsing earlier responses when the conversation
> grows long. When nil, auto hiding is disabled and no sections are
> hidden automatically.

pimacs-section-autohide-filter

User Option

:

pimacs-section-autohide-filter

'all

> Filter controlling which sections are eligible for automatic hiding.
>
> When set to `all`, every top-level section is eligible.
>
> A value of `(:include TYPE...)` makes only the listed section types
> eligible. A value of `(:exclude TYPE...)` makes every section type
> except the listed types eligible. A function value is called with each
> top-level section and should return non-nil when that section is
> eligible. Non-eligible sections do not count toward
> `pimacs-section-autohide-count`.

pimacs-section-padding

User Option

:

pimacs-section-padding

"\n\n"

> String inserted between sections to control the visual gap. Increase
> or decrease this value to adjust spacing between sections.

pimacs-section-visibility-indicators

User Option

:

pimacs-section-visibility-indicators

'(pimacs-section-fringe-bitmap\> . pimacs-section-fringe-bitmapv)

> Fringe bitmaps used to indicate section visibility.
>
> The car is used for hidden sections and the cdr for visible sections.
> Set this to nil to disable fringe indicators.

pimacs-section-type-faces

User Option

:

pimacs-section-type-faces

>     '((root . pimacs-section-root-face)
>       (thinking . pimacs-section-thinking-face)
>       (thinking-level . pimacs-section-thinking-level-face)
>       (assistant . pimacs-section-assistant-face)
>       (user . pimacs-section-user-face)
>       (tool-call . pimacs-section-tool-call-face)
>       (tool-result . pimacs-section-tool-result-face)
>       (error . pimacs-section-error-face)
>       (model . pimacs-section-model-face)
>       (compact . pimacs-section-compact-face)
>       (info . pimacs-section-info-face)
>       (custom . pimacs-section-custom-face)
>       (queue . pimacs-section-queue-face)
>       (notify . pimacs-section-notify-face)
>       (select . pimacs-section-select-face)
>       (confirm . pimacs-section-confirm-face)
>       (input . pimacs-section-input-face)
>       (session . pimacs-section-session-face))
>
> Faces prepended to content in sections of each type.

# Custom Faces

pimacs-chat-role-face

Face

:

pimacs-chat-role-face

'((t :inherit font-lock-builtin-face))

> Face used for generic chat role labels.

pimacs-chat-user-role-face

Face

:

pimacs-chat-user-role-face

'((t :inherit font-lock-keyword-face))

> Face used for user chat message role labels.

pimacs-chat-assistant-role-face

Face

:

pimacs-chat-assistant-role-face

'((t :inherit font-lock-constant-face))

> Face used for assistant chat message role labels.

pimacs-chat-title-face

Face

:

pimacs-chat-title-face

'((t :inherit font-lock-builtin-face))

> Face used for titles.

pimacs-prompt-face

Face

:

pimacs-prompt-face

'((t :inherit widget-field))

> Face used for the Pimacs prompt input field.

pimacs-error-face

Face

:

pimacs-error-face

'((t :inherit error))

> Face used for Pimacs widget error messages.

pimacs-tool-name-face

Face

:

pimacs-tool-name-face

'((t :inherit font-lock-function-name-face))

> Face used for tool names in tool execution events.

pimacs-grep-match-face

Face

:

pimacs-grep-match-face

'((t :inherit match))

> Face used to highlight matching text in grep tool results.

pimacs-notify-info-face

Face

:

pimacs-notify-info-face

'((t :inherit font-lock-comment-face))

> Face used for info notification messages.

pimacs-notify-warning-face

Face

:

pimacs-notify-warning-face

'((t :inherit warning))

> Face used for warning notification messages.

pimacs-notify-error-face

Face

:

pimacs-notify-error-face

'((t :inherit error))

> Face used for error notification messages.

pimacs-widget-face

Face

:

pimacs-widget-face

'((t :inherit shadow))

> Face used for extension widgets.

pimacs-status-face

Face

:

pimacs-status-face

'((t :inherit shadow))

> Face used for extension status.

pimacs-markdown-heading-face

Face

:

pimacs-markdown-heading-face

'((t :inherit font-lock-function-name-face :weight bold))

> Face used for Markdown headings.

pimacs-markdown-inline-code-face

Face

:

pimacs-markdown-inline-code-face

'((t :inherit (fixed-pitch font-lock-constant-face)))

> Face used for inline code.

pimacs-markdown-equation-face

Face

:

pimacs-markdown-equation-face

'((t :inherit (fixed-pitch font-lock-constant-face)))

> Face used for Markdown equations.

pimacs-markdown-bold-face

Face

:

pimacs-markdown-bold-face

'((t :inherit bold))

> Face used for bold text.

pimacs-markdown-italic-face

Face

:

pimacs-markdown-italic-face

'((t :inherit italic))

> Face used for italic text.

pimacs-markdown-strike-through-face

Face

:

pimacs-markdown-strike-through-face

'((t :strike-through t))

> Face used for Markdown strike-through text.

pimacs-markdown-superscript-face

Face

:

pimacs-markdown-superscript-face

'((t :height 0.8 :raise 0.3))

> Face used for Markdown superscript text.

pimacs-markdown-subscript-face

Face

:

pimacs-markdown-subscript-face

'((t :height 0.8 :raise -0.2))

> Face used for Markdown subscript text.

pimacs-markdown-link-face

Face

:

pimacs-markdown-link-face

'((t :inherit link))

> Face used for provisional Markdown links.

pimacs-markdown-list-marker-face

Face

:

pimacs-markdown-list-marker-face

'((t :inherit shadow :slant normal :weight normal))

> Face used for Markdown list markers.

pimacs-markdown-checkbox-face

Face

:

pimacs-markdown-checkbox-face

'((t :inherit font-lock-builtin-face))

> Face used for Markdown task-list checkboxes.

pimacs-markdown-blockquote-face

Face

:

pimacs-markdown-blockquote-face

'((t :inherit font-lock-comment-face))

> Face used for Markdown blockquotes.

pimacs-markdown-horizontal-rule-face

Face

:

pimacs-markdown-horizontal-rule-face

'((t :inherit shadow))

> Face used for Markdown horizontal rules.

pimacs-markdown-code-block-face

Face

:

pimacs-markdown-code-block-face

'((t :inherit fixed-pitch))

> Face used as the base face of Markdown code blocks.

pimacs-markdown-table-header-face

Face

:

pimacs-markdown-table-header-face

'((t :inherit fixed-pitch))

> Face used for Markdown table headers.

pimacs-markdown-table-border-face

Face

:

pimacs-markdown-table-border-face

'((t :inherit fixed-pitch))

> Face used for Markdown table borders.

pimacs-section-root-face

Face

:

pimacs-section-root-face

'((t))

> Face applied to root sections.

pimacs-section-thinking-face

Face

:

pimacs-section-thinking-face

'((t :inherit shadow))

> Face applied to thinking sections.

pimacs-section-thinking-level-face

Face

:

pimacs-section-thinking-level-face

'((t :inherit shadow))

> Face applied to thinking-level sections.

pimacs-section-assistant-face

Face

:

pimacs-section-assistant-face

'((t))

> Face applied to assistant sections.

pimacs-section-user-face

Face

:

pimacs-section-user-face

'((t :inherit highlight :extend t))

> Face applied to user sections.

pimacs-section-tool-call-face

Face

:

pimacs-section-tool-call-face

'((t))

> Face applied to tool call sections.

pimacs-section-tool-result-face

Face

:

pimacs-section-tool-result-face

'((t))

> Face applied to tool result sections.

pimacs-section-error-face

Face

:

pimacs-section-error-face

'((t :inherit pimacs-error-face))

> Face applied to error sections.

pimacs-section-model-face

Face

:

pimacs-section-model-face

'((t :inherit shadow))

> Face applied to model sections.

pimacs-section-compact-face

Face

:

pimacs-section-compact-face

'((t :inherit shadow))

> Face applied to compaction sections.

pimacs-section-info-face

Face

:

pimacs-section-info-face

'((t :inherit shadow))

> Face applied to information sections.

pimacs-section-custom-face

Face

:

pimacs-section-custom-face

'((t))

> Face applied to custom sections.

pimacs-section-queue-face

Face

:

pimacs-section-queue-face

'((t :inherit shadow))

> Face applied to queue sections.

pimacs-section-notify-face

Face

:

pimacs-section-notify-face

'((t))

> Face applied to notification sections.

pimacs-section-select-face

Face

:

pimacs-section-select-face

'((t :inherit shadow))

> Face applied to selection sections.

pimacs-section-confirm-face

Face

:

pimacs-section-confirm-face

'((t :inherit shadow))

> Face applied to confirmation sections.

pimacs-section-input-face

Face

:

pimacs-section-input-face

'((t :inherit shadow))

> Face applied to input sections.

pimacs-section-session-face

Face

:

pimacs-section-session-face

'((t :inherit shadow))

> Face applied to session sections.
