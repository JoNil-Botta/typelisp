;; A helper called from an ordered scan body keeps scalar scan order, but a
;; parallel foreach inside it does not.
(define (spread [out : (&mut out (Slice i64))] [n : i64] [value : i64]) : unit
  (foreach ([j : i64 0 n]) (set! (array-ref out 0) (+ value j))))

(define (run [xs : (& xs (Slice i64))] [out : (&mut out (Slice i64))] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i64 0])
    (array-ref xs i)
    (spread out n prefix)))