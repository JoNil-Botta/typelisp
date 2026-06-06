;; clean.tl - Retained selfhost clean compatibility/coverage driver (#1643).
;;
;; The published entry point is `selfhost/cli.tl clean`. This thin wrapper stays
;; as a focused clean-command compile target for manifest coverage.
(import "../stdlib/io.tl")

(import "clean_cli_core.tl")

(define (main) : i64
  (clean-run-from 1 (arg-count)))