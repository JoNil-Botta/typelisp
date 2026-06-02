;; build.tl - Selfhost build CLI driver (#622, #1339).
;;
;; The command logic lives in `build_cli_core.tl` so the unified `cli.tl`
;; dispatcher can share it without a duplicate `main`. The driver builds
;; in-process via stdlib fs/process helpers; `--direct` remains accepted for
;; compatibility with older scripts.
(import "build_cli_core.tl")

(define (main) : i64
  (build-run-from 1 (arg-count)))