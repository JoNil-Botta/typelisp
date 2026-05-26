;; lint_smoke.tl - Runnable smoke for lint_core.tl (#1163).
(import "lint_core.tl")

(define (main) : i64
  (compiler-lint-self-test))