;; compile.tl - Standalone selfhost compile driver (#565).
;;
;; A thin `main` wrapper over the main-free `compile_cli_core.tl`, kept as the
;; minimal bootstrap entry point: `scripts/check-bootstrap-fixpoint.sh` compiles
;; this file to produce each stage. The unified `cli.tl` dispatcher shares the
;; same core (it routes compile/tokenize/parse/debug into `compile-cli-run`), so
;; the compiler logic lives in one place (#1639).
(import "compile_cli_core.tl")

(define (main) : i64
  (compile-cli-run (arg-count)))