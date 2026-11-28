;; Run the scalar-reference corpus against the active backend.
(import spmd_foreach_active as active)

(define (main) : i64
  (active.histogram)
  (active.accumulate)
  (active.masked)
  (active.lane-types)
  (active.atomics)
  (active.calls)
  42)