;; Isolated process: a mutex create that cannot register fails closed and
;; leaves no registry row behind (#7755).
(import stdlib.sync)
(import stdlib.concurrency_registry as registry)
(import (sync.mutex i64) as mutex_i64)

(define (create-fails?) : bool
  (match (mutex_i64.create 1)
    [(mutex_i64.CreateErr _) true]
    [(mutex_i64.CreateOk _) false]))

(define (poison! [states : (MutPtr i64)] [capacity : i64]) : unit
  (begin
    (unsafe
      (registry.concurrency-lock!))
    (let
      [slot : i64 0]
      (while (< slot capacity)
        (begin
          (unsafe
            (registry.concurrency-set! states slot 2))
          (set! slot (+ slot 1)))))
    (unsafe
      (registry.concurrency-unlock!))))

(define (main) : i64
  (if (not (mutex_i64.create-initial-ok? 3))
    1
    (begin
      (poison!
        registry.concurrency-authority-state
        registry.concurrency-authority-capacity)
      (let
        [authority-full : bool (create-fails?)]
        [after-authority : registry.ConcurrencyStats
          (registry.concurrency-stats)]
        (begin
          (poison!
            registry.concurrency-resource-state
            registry.concurrency-resource-capacity)
          (let
            [resource-full : bool (create-fails?)]
            [after-resource : registry.ConcurrencyStats
              (registry.concurrency-stats)]
            (cond
              [(not authority-full) 2]
              [(not (= after-authority.live-resources 0)) 3]
              [(not (= after-authority.live-authorities 0)) 4]
              [(not resource-full) 5]
              [(not (= after-resource.live-resources 0)) 6]
              [else 42])))))))