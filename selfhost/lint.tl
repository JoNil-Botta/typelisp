;; lint.tl - selfhost `typelisp lint` driver (#1163). Reads a TypeLisp file,
;; runs the lint_core rules over its program, and prints each
;; finding as `path:line:col: message` followed by a count summary. Warn-only by
;; default: exits 0 even with findings. Pass `--check` after the input path to
;; exit non-zero when findings remain. Load failures exit 1, and bad arguments
;; exit 2.
;;
;; The command logic lives in `lint_driver_core.tl` so the unified `cli.tl`
;; dispatcher can share it without a duplicate `main`.
;;
;; Run directly (until the public `typelisp lint` subcommand lands):
;;   typelisp run selfhost/lint.tl -- <file.tl> [--check] [--stdlib-root <dir>]...
(import "../stdlib/io.tl")

(import "lint_driver_core.tl")

(define (main) : i64
  (selfhost-lint-run-from 1 (arg-count)))