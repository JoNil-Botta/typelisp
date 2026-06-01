;; build.tl - Selfhost build CLI driver (#622, #1339).
;;
;; The command logic lives in `build_cli_core.tl` so the unified `cli.tl`
;; dispatcher can share it without a duplicate `main`. The driver supports the
;; `--direct` (in-process build via stdlib fs/process helpers), `--host-plan`
;; (emit a host-action plan for Rust), and bare (plan) modes.
(import "build_cli_core.tl")

(define (main) : i64
  (build-run-from 1 (arg-count)))