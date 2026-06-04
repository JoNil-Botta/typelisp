;; repl.tl - Standalone wrapper for the selfhost REPL CLI core (#591/#798).
;;
;; The command logic lives in `repl_cli_core.tl` so the unified `cli.tl`
;; dispatcher can share it without importing a duplicate `main`.
(import "../stdlib/io.tl")

(import "repl_cli_core.tl")

(define (main) : i64
  (repl-run-from 1 (arg-count)))