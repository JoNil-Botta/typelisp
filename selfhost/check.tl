;; check.tl - Retained selfhost typecheck compatibility/coverage driver.
;;
;; The published entry point is `selfhost/cli.tl check`. This thin wrapper stays
;; as the smaller frontend checker binary for stdlib-selfhost and safety-corpus
;; gates. The command logic lives in `check_cli_core.tl`, shared with the unified
;; dispatcher.
(import "../stdlib/io.tl")

(import "check_cli_core.tl")

(define (main) : i64
  (selfhost-check-run-from 1 (arg-count)))