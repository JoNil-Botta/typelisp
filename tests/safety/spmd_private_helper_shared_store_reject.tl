(define (through-scratch [x : i64]) : i64
  (let
    [scratch : (Array i64 2) (array 0 0)]
    (begin
      (set! (array-ref scratch 1) x)
      (array-ref scratch 1))))

(define (fill [out : (&mut out (Slice i64))] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out 0) (through-scratch i))))