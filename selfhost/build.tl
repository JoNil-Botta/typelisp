;; build.tl - Retained selfhost build compatibility/coverage driver (#622, #1339).
;;
;; The published entry point is `selfhost/cli.tl build`. This thin wrapper stays
;; as a focused build-tool compile/run target for public-tool, Windows link, and
;; assembly-size gates. The command logic lives in `build_cli_core.tl`, shared
;; with the unified dispatcher; `--direct` remains accepted for compatibility
;; with older scripts.
(import "../stdlib/io.tl")

(import "build_cli_core.tl")

(define (main) : i64
  (build-run-from 1 (arg-count)))