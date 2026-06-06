;; format.tl - Retained selfhost formatter compatibility/coverage driver (#522).
;;
;; Public usage:
;;   typelisp fmt [input.tl...] [--check] [--manifest-path typelisp.pkg]
;;
;; The published selfhost entry point is `selfhost/cli.tl fmt`. This wrapper
;; stays as a focused formatter compile target for manifest coverage. The
;; command logic lives in `format_cli_core.tl`, shared with the unified
;; dispatcher.
(import "../stdlib/io.tl")

(import "format_cli_core.tl")

(define (main) : i64
  (fmt-run-from 1 (arg-count)))