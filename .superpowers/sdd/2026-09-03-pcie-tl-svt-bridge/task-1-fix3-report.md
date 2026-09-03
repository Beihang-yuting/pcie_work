# Task 1 review fixes (third pass)

Decode now rejects malformed Config and Completion transactions that use
unsupported 4DW formats, with concise Chinese comments documenting the
format rule. `git diff --check` passes; full SVT compilation remains unavailable.
