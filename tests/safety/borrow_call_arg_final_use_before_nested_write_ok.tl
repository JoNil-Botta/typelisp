;: A lending reference used by an earlier call argument ends before a later
;: nested argument writes its owner.
(define (use-two [_ref : (& n i64)] [value : i64]) : i64
  value)

(define (main [n : i64]) : i64
  (let
    [ref : (& n i64) (& n)]
    (use-two
      ref
      (begin
        (begin
          (set! n 2))
        42))))