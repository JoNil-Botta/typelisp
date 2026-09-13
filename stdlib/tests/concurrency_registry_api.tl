;; Native barrier test: close cannot detach a resource while two worker leases
;; are live, even if a separate checked authority races the owner.
(import stdlib.concurrency_registry as registry)
(import stdlib.thread)

(define registry-test-authority : registry.ConcurrencyAuthority
  (match (unsafe
    (registry.concurrency-register
      registry.concurrency-family-channel-i64
      2
      17
      29
      0
      0
      0
      0
      0))
    [(registry.ConcurrencyShared authority) authority]
    [(registry.ConcurrencyShareErr) (registry.ConcurrencyAuthority (box 0))]))
(define registry-test-ready : i64
  0)
(define registry-test-go : i64
  0)

(define (registry-test-ready-count) : i64
  (unsafe
    (atomic-load (ptr-cast (ptr-addr-of registry-test-ready) : (Ptr i64)))))

(define (registry-test-open-gate!) : unit
  (unsafe
    (atomic-store! (ptr-addr-of registry-test-go) 1)))

(define (registry-test-worker-with-authority
  [authority : (& authority registry.ConcurrencyAuthority)]) : i64
  (let
    [lease : registry.ConcurrencyLease
      (unsafe
        (registry.concurrency-acquire
          authority
          registry.concurrency-family-channel-i64
          2))]
    (begin
      (unsafe
        (atomic-fetch-add! (ptr-addr-of registry-test-ready) 1))
      (if (not lease.ok)
        1
        (begin
          (while (=
            (unsafe
              (atomic-load
                (ptr-cast (ptr-addr-of registry-test-go) : (Ptr i64))))
            0)
            unit)
          (if (unsafe
            (registry.concurrency-release lease))
            42
            2))))))

(define (registry-test-worker [_context : i64]) : i64
  (match (registry.concurrency-share
    (& registry-test-authority)
    registry.concurrency-family-channel-i64)
    [(registry.ConcurrencyShareErr)
      (begin
        (unsafe
          (atomic-fetch-add! (ptr-addr-of registry-test-ready) 1))
        1)]
    [(registry.ConcurrencyShared alias)
      (with
        ([held alias registry.cleanup-concurrency-authority])
        (registry-test-worker-with-authority (& held)))]))

(define (registry-test-join-code [worker : thread.Thread]) : i64
  (thread.join-result-value-or
    (unsafe
      (thread.join worker))
    -1))

(define (registry-test-concurrent-close) : i64
  (match (unsafe
    (thread.spawn registry-test-worker 0))
    [(thread.ThreadSpawnErr _) 1]
    [(thread.ThreadSpawnOk first)
      (match (unsafe
        (thread.spawn registry-test-worker 0))
        [(thread.ThreadSpawnErr _)
          (begin
            (registry-test-open-gate!)
            (registry-test-join-code first)
            2)]
        [(thread.ThreadSpawnOk second)
          (let
            [spins : i64 0]
            (begin
              (while (and (< spins 100000000) (< (registry-test-ready-count) 2))
                (set! spins (+ spins 1)))
              (let
                [ready : bool (= (registry-test-ready-count) 2)]
                [busy-close : registry.ConcurrencyClaim
                  (unsafe
                    (registry.concurrency-close
                      (& registry-test-authority)
                      registry.concurrency-family-channel-i64
                      2))]
                (begin
                  (registry-test-open-gate!)
                  (let
                    [first-code : i64 (registry-test-join-code first)]
                    [second-code : i64 (registry-test-join-code second)]
                    [closed : registry.ConcurrencyClaim
                      (unsafe
                        (registry.concurrency-close
                          (& registry-test-authority)
                          registry.concurrency-family-channel-i64
                          2))]
                    (if (and
                      ready
                      (not busy-close.ok)
                      (= first-code 42)
                      (= second-code 42)
                      closed.ok
                      (= closed.field0 17)
                      (= closed.field1 29))
                      42
                      3))))))])]))

(define (main) : i64
  (registry-test-concurrent-close))