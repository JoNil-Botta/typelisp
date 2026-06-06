;; lint.tl - Retained selfhost lint compatibility/coverage driver (#1163).
;;
;; Reads a TypeLisp file,
;; runs the lint_core rules over its program, and prints each
;; finding as `path:line:col: message` followed by a count summary. Warn-only by
;; default: exits 0 even with findings. Pass `--check` to exit non-zero when
;; findings remain. With no explicit file, the nearest package is linted. Load
;; failures exit 1, and bad arguments exit 2.
;;
;; The published entry point is `selfhost/cli.tl lint`. This wrapper stays as a
;; focused lint-driver compile target for manifest and driver-smoke coverage.
;; The command logic lives in `lint_driver_core.tl`, shared with the unified
;; dispatcher.
;;
;; Focused wrapper invocation:
;;   typelisp run selfhost/lint.tl -- [<file.tl>...] [--check] [--manifest-path typelisp.pkg] [--stdlib-root <dir>]...
(import "../stdlib/io.tl")

(import "lint_driver_core.tl")

(define (main) : i64
  (selfhost-lint-run-from 1 (arg-count)))