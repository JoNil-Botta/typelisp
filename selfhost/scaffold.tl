;; scaffold.tl - Retained selfhost `new`/`init` compatibility/coverage driver.
;;
;; The published entry points are `selfhost/cli.tl new` and `selfhost/cli.tl
;; init`. This thin wrapper stays as a focused scaffold compile target for
;; manifest coverage. The command logic lives in `scaffold_cli_core.tl`, shared
;; with the unified dispatcher.
(import "../stdlib/io.tl")

(import "scaffold_cli_core.tl")

(define (main) : i64
  (scaffold-run-from 1 (arg-count)))