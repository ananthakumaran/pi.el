# Markdown tapes

Each `NAME.in.markdown` is rendered and compared with `NAME.out.txt`.
Each nonempty output line begins with `│ `, which is not part of the expected
output.  An empty output line is written as `│`, with no trailing space.
A face annotation immediately following an output line has this form:

```text
│ A code example
@   ^^^^ inline-code
```

The two-character gutters align output columns and carets.  Spaces between
`@ ` and the carets are zero-based output columns; the carets mark the face
range.  Face names omit the `pimacs-markdown-` prefix and `-face` suffix.
Repeat annotation lines for multiple faces on one output line.  `@ eof` marks
output without a final newline.
