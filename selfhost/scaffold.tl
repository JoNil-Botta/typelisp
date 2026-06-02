;; scaffold.tl - standalone selfhost `typelisp new` / `typelisp init` driver.
;;
;; The command logic lives in `scaffold_cli_core.tl` so the unified `cli.tl`
;; dispatcher can share it without a duplicate `main`.
(import "scaffold_cli_core.tl")

(define (main) : i64
  (scaffold-run-from 1 (arg-count)))