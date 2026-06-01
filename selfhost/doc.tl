;; doc.tl - Selfhost doc CLI driver.
;;
;; The command logic lives in `doc_cli_core.tl` so the unified `cli.tl`
;; dispatcher can share it without a duplicate `main`.
(import "doc_cli_core.tl")

(define (main) : i64
  (doc-run-from 1 (arg-count)))