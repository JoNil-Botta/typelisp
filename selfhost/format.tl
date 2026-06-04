;; format.tl - Self-hosted formatter CLI driver (#522).
;;
;; Usage through the Rust CLI:
;;   typelisp fmt [--check] input.tl...
;;
;; The command logic lives in `format_cli_core.tl` so the unified `cli.tl`
;; dispatcher can share it without a duplicate `main`.
(import "../stdlib/io.tl")

(import "format_cli_core.tl")

(define (main) : i64
  (fmt-run-from 1 (arg-count)))