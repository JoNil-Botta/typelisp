;; repl.tl - Retained selfhost REPL compatibility/coverage driver (#591/#798).
;;
;; The published entry point is `selfhost/cli.tl repl`. This thin wrapper stays
;; as a focused REPL compile/run target for manifest and public-tool smoke
;; coverage. The command logic lives in `repl_cli_core.tl`, shared with the
;; unified dispatcher.
(import "../stdlib/io.tl")

(import "repl_cli_core.tl")

(define (main) : i64
  (repl-run-from 1 (arg-count)))