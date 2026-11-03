;; SPMD index binders (foreach rank 1 and 2, spmd-scan, spmd-compact,
;; spmd-reduce) spelled like a colliding with-arena region shadow the arena in
;; their bodies. SPMD bodies reject references to and allocation of varying
;; values, so this pins only that the shadowed bodies still check (#9593).
(define (probe [p : (& r i64)] [out : (&mut (Slice i64))] [n : i64]) : i64
  (with-arena
    r
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