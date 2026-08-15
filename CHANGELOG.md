# Changelog

## Unreleased

## v0.4.0 - 2026-08-15

### Added

- Customizable faces for chat sections, including separate faces for thinking
  levels and user messages.
- Syntax highlighting for arguments in custom tool calls.

### Changed

- Session history is rendered incrementally in chunks to keep large sessions
  responsive.
- Grep results are fontified in place for better performance and more accurate
  navigation.
- Tree-sitter Markdown rendering uses `ts-mode` when it is available.

### Fixed

- Incremental search now temporarily reveals collapsed text.
- Markdown code fences without a trailing newline are rendered correctly.
- Partial or incomplete diffs no longer prevent edit results from rendering.
- Grep result fontification now remains within the result region.

## v0.3.0 - 2026-08-06

### Added

- An opt-in Tree-sitter-based Markdown renderer with incremental streaming,
  rich Markdown syntax support, formatted tables, and link widgets.
- `pimacs-doctor` reports the status of Pi, Tree-sitter, and the Markdown
  grammars, with actions to install missing dependencies.
- Commands and keybindings to show section visibility at selected levels,
  apply visibility levels globally, and cycle global visibility.
- Batching and merging of streamed message updates to reduce redundant
  renders.

### Changed

- Thinking-level selection now uses Pi's `get_available_thinking_levels`
  command.
- Message handling no longer depends on the removed `partial` and `message`
  event fields, enabling compatibility with upcoming Pi versions.
- The minimum supported Emacs version is now 29.1.

### Fixed

- Grep result highlighting now handles regular-expression patterns correctly.

## v0.2.0 - 2026-07-25

### Added

- Bash command output is streamed while the command is running.
- Extension status text can be placed in header and mode lines with
  `(:status STATUS-KEY ...)`, including per-placement face customization.
  Status keys can be hidden from the prompt status widget with
  `pimacs-status-widget-hidden-keys`.
- `pimacs-list-sessions` displays active chats in a sortable tabulated list.
  Its columns and initial sort order are configurable with
  `pimacs-list-sessions-table` and `pimacs-list-sessions-sort-key`.
- The `:project_root` state-line component displays the project root directory.
- `pimacs-switch-session` switches between active chats.
- Send commands select an active chat by enclosing project root, prompting when ambiguous.
- Start chats from any directory using the `C-u` prefix for `pimacs-chat`,
  which opens a transient for selecting a session name and root
  directory.

## v0.1.0 - 2026-07-19

### Added

- Configurable header and mode-line status formats via
  `pimacs-header-line-format` and `pimacs-mode-line-format`.
