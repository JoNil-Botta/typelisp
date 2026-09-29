;; The mutex substrate beneath the generated module is an unsafe adapter:
;; locking through it directly requires an unsafe context (#7755).
(import stdlib.sync)
(import stdlib.concurrency_registry as registry)

(define (main) : i64
  (with
    ([authority
        (registry.ConcurrencyAuthority (box 0))
        registry.cleanup-concurrency-authority])
    (let
      [_grant : (Box i64) (sync.i64-mutex-lock-grant (& authority))]
      0)))