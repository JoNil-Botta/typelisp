;; doc.tl - Retained selfhost doc compatibility/coverage driver.
;;
;; The published entry point is `selfhost/cli.tl doc`. This thin wrapper stays
;; as a focused doc-tool compile/run target for public-tool and documentation
;; gates. The command logic lives in `doc_cli_core.tl`, shared with the unified
;; dispatcher.
(import "../stdlib/io.tl")

(import "doc_cli_core.tl")

(define (main) : i64
  (doc-run-from 1 (arg-count)))