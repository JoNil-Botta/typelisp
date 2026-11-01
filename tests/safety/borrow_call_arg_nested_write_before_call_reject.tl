;: A reference passed as an earlier call argument stays live until the call
;: itself; a later argument cannot write its owner first (Rust E0506).
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