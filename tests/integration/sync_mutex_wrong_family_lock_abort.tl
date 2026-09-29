;; A genuine registry authority of another family, wrapped as a mutex handle in
;; safe code, names no mutex: lock aborts (134) before touching the foreign
;; resource's fields (#7755).
(import stdlib.sync)
(import stdlib.concurrency_registry as registry)
(import (sync.mutex i64) as mutex_i64)

(define (main) : i64
  (match (unsafe
    (registry.concurrency-register
      registry.concurrency-family-channel-i64
      2
      11
      22
      0
      0
      0
      0
      0))
    [(registry.ConcurrencyShareErr) 9]
    [(registry.ConcurrencyShared authority)
      (with
        ([mutex (mutex_i64.Mutex authority) mutex_i64.release])
        (with
          ([guard (mutex_i64.lock (& mutex)) mutex_i64.unlock])
          (mutex_i64.get guard)))]))