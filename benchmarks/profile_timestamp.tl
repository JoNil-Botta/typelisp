;; Microbenchmark for the allocation-free monotonic sampling path.
;; Build once, then time the executable; exit 0 proves the loop allocated
;; nothing and the sampled clock produced a positive value.
(import stdlib.profile)

(define (main) : i64
  (let
    [before : i64 (profile.alloc-total)]
    [index : i64 0]
    [last : i64 0]
    (begin
      (while (< index 2000000)
        (begin
          (set! last (profile.now-ticks))
          (set! index (+ index 1))))
      (if (and (> last 0) (= before (profile.alloc-total)))
        0
        1))))