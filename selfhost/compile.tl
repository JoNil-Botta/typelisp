;; compile.tl - Required bootstrap selfhost compile driver (#565).
;;
;; A thin `main` wrapper over the main-free `compile_cli_core.tl`, kept as the
;; minimal bootstrap entry point: `scripts/check-bootstrap-fixpoint.sh` compiles
;; this file to produce each stage. The unified `cli.tl` dispatcher shares the
;; same core, so the compiler logic lives in one place (#1639).
(import "../stdlib/io.tl")

(import "compile_cli_core.tl")

(define (main) : i64
  (compile-cli-run (arg-count)))