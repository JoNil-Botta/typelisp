;; CLI for the canonical dependency-boundary coordinator.
(import boundary_core as boundary)
(import stdlib.io)

(define (main) : i64
  (if (= (io.arg-count) 4)
    (boundary.check (io.arg 1) (io.arg 2) (io.arg 3))
    (begin
      (io.print-error "usage: dependency-check INSPECTOR ROOT POLICY.json\n")
      2)))