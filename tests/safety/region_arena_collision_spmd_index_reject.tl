;; Inside SPMD code, a with-arena named like a visible SPMD index is rejected
;; at entry, as on every other checking path (#9593, D-C121).
(define (probe [out : (&mut (Slice i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    ; Must fail: rename the arena.
    (with-arena i (set! (array-ref out i) 0))))

(define (main) : i64
  0)