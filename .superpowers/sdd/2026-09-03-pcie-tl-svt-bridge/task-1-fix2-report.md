# Task 1 review fixes (second pass)

Added explicit comments documenting SVT's two-value AT limitation, restored
locked-memory `type_f`, and validated route completer/status metadata in both
directions. Strengthened the unit test with format, kind, requester/tag, and
payload assertions. `git diff --check` passes; native SVT compile unavailable.
