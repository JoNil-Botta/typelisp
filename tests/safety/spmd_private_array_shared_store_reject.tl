;; A private array holds a varying value after a varying write; storing it
;; through a uniform index of shared storage still collides.
(define (fill [out : (&mut out (Slice i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [scratch : (Array i64 2) (array 0 0)]
      (begin
        (set! (array-ref scratch 0) i)
        (set! (array-ref out 0) (array-ref scratch 0))))))