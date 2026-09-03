# Final codec correctness fixes

Explicitly reject unsupported AT=01 and all TL error-injection metadata,
validate memory/config kind-format consistency, and retain route validation.
Chinese comments document SVT limitations. Static `git diff --check` passes.
