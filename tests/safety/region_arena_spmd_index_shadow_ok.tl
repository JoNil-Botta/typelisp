;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that SPMD index binders (foreach rank 1
;; and 2, spmd-scan, spmd-compact, spmd-reduce) named `r` check inside an arena.
(define (probe [p : (& r i64)] [out : (&mut (Slice i64))] [n : i64]) : i64
  (with-arena
    ar
    (foreach ([r : i64 0 n]) (set! (array-ref out r) r))
    (foreach
      ([r : i64 0 1] [q : i64 0 n])
      (set! (array-ref out (+ 0 (+ (* (- r 0) (- n 0)) (- q 0)))) r))
    (spmd-scan
      sum
      ([r : i64 0 n] [prefix : i64 0])
      r
      (set! (array-ref out r) prefix))
    (spmd-compact
      ([r : i64 0 n] [slot : i64 0])
      (> r 0)
      (set! (array-ref out slot) r))
    (spmd-reduce sum ([r : i64 0 n]) 0 r)))

(define (main) : i64
  0)