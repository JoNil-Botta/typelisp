;; test.tl - Retained selfhost test compatibility/coverage driver.
;;
;; The published entry point is `selfhost/cli.tl test`. This thin wrapper stays
;; as a focused inline-test command compile target for manifest coverage. The
;; command logic lives in `test_cli_core.tl`, shared with the unified dispatcher.
(import "../stdlib/io.tl")

(import "test_cli_core.tl")

(define (main) : i64
  (tltest-run-from 1 (arg-count)))