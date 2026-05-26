;; lint_driver_smoke.tl - Runnable smoke for lint_driver_core.tl (#1163): drives
;; the full load -> lint -> render path on an embedded source and returns 42.
(import "lint_driver_core.tl")

(define (main) : i64
  (compiler-lint-driver-self-test))