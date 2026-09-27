;; read_pool_arena_smoke.tl - Reader pool growth must outlive a scratch arena.
(import reader_tests)

(define (main) : i64
  ;; Force growth while a disposable arena is current, destroy it, then prove
  ;; the process-global reader pool remains usable.
  (reader_tests.sp-node-pool-arena-ownership-self-test))