(defstruct Point
  (x i64)
  (y i64))

(define (fill
  [xs : (& xs (Slice i64))]
  [points : (&mut points (Slice Point))]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref points 0).x (array-ref xs i))))