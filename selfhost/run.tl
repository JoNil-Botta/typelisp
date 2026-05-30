;; run.tl - Selfhost run CLI driver.
;;
;; The command logic lives in `run_cli_core.tl` so the unified `cli.tl`
;; dispatcher can share it without a duplicate `main`.
(import "run_cli_core.tl")

(define (main) : i64
  (run-run-from 1 (arg-count)))