;; clean.tl - Standalone selfhost clean driver (#1643).
(import "../stdlib/io.tl")

(import "clean_cli_core.tl")

(define (main) : i64
  (clean-run-from 1 (arg-count)))