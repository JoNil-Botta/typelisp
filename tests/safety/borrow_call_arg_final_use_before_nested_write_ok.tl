;: Historical case ID: the earlier call argument keeps its loan until the
;: call itself, so a later argument cannot write the owner first.
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