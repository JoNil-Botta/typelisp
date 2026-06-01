;; lint.tl - selfhost `typelisp lint` driver (#1163). Reads a TypeLisp file,
;; runs the lint_core nested-if-ladder rule over its program, and prints each
;; finding as `path:line:col: message` followed by a count summary. Warn-only:
;; exits 0 even with findings (CI enforcement is layered on per #1164); a load
;; failure exits 1, and bad arguments exit 2.
;;
;; The command logic lives in `lint_driver_core.tl` so the unified `cli.tl`
;; dispatcher can share it without a duplicate `main`.
;;
;; Run directly (until the public `typelisp lint` subcommand lands):
;;   typelisp run selfhost/lint.tl -- <file.tl> [--stdlib-root <dir>]...
(import "lint_driver_core.tl")

(define (main) : i64
  (selfhost-lint-run-from 1 (arg-count)))