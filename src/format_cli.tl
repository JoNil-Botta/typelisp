;; format_cli.tl - Lightweight native entry point for formatter-only tooling.
(import stdlib.io)
(import format_cli_core)

(define (main) : i64
  (format_cli_core.fmt-run-from 2 (io.arg-count)))
