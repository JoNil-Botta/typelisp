;; check.tl - Short-lived selfhost typecheck CLI driver.
;;
;; The command logic lives in `check_cli_core.tl` so the unified `cli.tl`
;; dispatcher can share it without a duplicate `main`.
(import "check_cli_core.tl")

(define (main) : i64
  (selfhost-check-run-from 1 (arg-count)))