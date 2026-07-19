(module reflection.signature.provider)

(define answer : i64
  42)

(define (make [value : i64]) : bool
  (> value 0))