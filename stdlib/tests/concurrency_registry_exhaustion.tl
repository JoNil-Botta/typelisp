;; Isolated process: poison every registry row to exercise fail-closed capacity.
(import stdlib.concurrency_registry as registry)

(define (registration-fails?) : bool
  (match (unsafe
    (registry.concurrency-register
      registry.concurrency-family-channel-i64
      2
      1
      2
      0
      0
      0
      0
      0))
    [(registry.ConcurrencyShareErr) true]
    [(registry.ConcurrencyShared _) false]))

(define (main) : i64
  (begin
    (unsafe
      (registry.concurrency-lock!))
    (let
      [slot : i64 0]
      (while (< slot registry.concurrency-authority-capacity)
        (begin
          (unsafe
            (registry.concurrency-set!
              registry.concurrency-authority-state
              slot
              2))
          (set! slot (+ slot 1)))))
    (unsafe
      (registry.concurrency-unlock!))
    (let
      [authority-full : bool (registration-fails?)]
      [after-authority : registry.ConcurrencyStats (registry.concurrency-stats)]
      (begin
        (unsafe
          (registry.concurrency-lock!))
        (let
          [slot : i64 0]
          (while (< slot registry.concurrency-resource-capacity)
            (begin
              (unsafe
                (registry.concurrency-set!
                  registry.concurrency-resource-state
                  slot
                  2))
              (set! slot (+ slot 1)))))
        (unsafe
          (registry.concurrency-unlock!))
        (let
          [after-resource : registry.ConcurrencyStats
            (registry.concurrency-stats)]
          (if (and
            authority-full
            (= after-authority.live-resources 0)
            (= after-authority.live-authorities 0)
            (registration-fails?)
            (=
              after-resource.retired-resources
              registry.concurrency-resource-capacity)
            (=
              after-resource.retired-authorities
              registry.concurrency-authority-capacity))
            42
            1))))))