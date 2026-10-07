;; A borrow of a local cannot leave its scope as a `program` reference.
(define (leak) : (& program i64)
  (let
    [x : i64 42]
    (& x)))

(define (main) : i64
  (deref (leak)))