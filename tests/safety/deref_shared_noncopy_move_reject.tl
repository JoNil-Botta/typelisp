(define (take [value : (& source (Box i64))]) : i64
  (let
    [owned : (Box i64) (deref value)]
    (deref owned)))

(define (main) : i64
  0)