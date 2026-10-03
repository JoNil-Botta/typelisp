;; Check-only: safe source cannot issue raw native resource authority.
(import stdlib.concurrency_registry as registry)

(define (main) : i64
  (match (registry.concurrency-register 1 0 0 0 0 0 0 0 0)
    [(ConcurrencyShareErr) 1]
    [(ConcurrencyShared _) 42]))