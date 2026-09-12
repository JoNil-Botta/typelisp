;; Test-only helpers must not expose a safe resource-close route to programs.
(import stdlib.concurrency_registry as registry)

(define (main) : i64
  (with
    ([forged
        (registry.ConcurrencyAuthority (box 0))
        registry.cleanup-concurrency-authority])
    (if (registry.concurrency-test-close-ok (& forged))
      42
      1)))