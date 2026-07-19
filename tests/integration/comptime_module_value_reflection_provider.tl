(module reflection.signature.provider)

(define answer : i64
  42)

(define (make [value : i64]) : bool
  (> value 0))

(defstruct Token
  (value i64))

(define (observe [_token : (& caller Token)]) : i64
  1)

(define (update [_token : (&mut caller Token)]) : i64
  1)