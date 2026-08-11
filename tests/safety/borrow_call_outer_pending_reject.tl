;: A call's local argument horizon cannot erase an outer pending reference use.
(define (use-two [_ref : (& n i64)] [value : i64]) : i64
  value)

(define (take [_ref : (& n i64)]) : i64
  1)

(define (main [n : i64]) : i64
  (let
    [ref : (& n i64) (& n)]
    (begin
      (use-two
        ref
        (begin
          (set! n 2)
          0))
      (take ref))))