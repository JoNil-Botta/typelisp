;; run.tl - Retained selfhost run compatibility/coverage driver.
;;
;; The published entry point is `selfhost/cli.tl run`. This thin wrapper stays
;; as a focused run-tool compile/run target for public-tool and Windows link
;; gates. The command logic lives in `run_cli_core.tl`, shared with the unified
;; dispatcher.
(import "../stdlib/io.tl")

(import "run_cli_core.tl")

(define (main) : i64
  (run-run-from 1 (arg-count)))