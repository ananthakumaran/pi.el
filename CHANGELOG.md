# Changelog

## Unreleased

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
