;; test.tl - Selfhost test CLI driver.
;;
;; The command logic lives in `test_cli_core.tl` so the unified `cli.tl`
;; dispatcher can share it without a duplicate `main`.
(import "../stdlib/io.tl")

(import "test_cli_core.tl")

(define (main) : i64
  (tltest-run-from 1 (arg-count)))