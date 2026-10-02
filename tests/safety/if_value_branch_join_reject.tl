;; Only a literal branch adopts the other branch's type (#8590): an `i32`
;; value and an `i64` value still do not join.
(define (narrow) : i32
  2)

(define (wide) : i64
  2)

(define (main) : i64
  (let
    [x
      (if false
        (narrow)
        (wide))]
    0))