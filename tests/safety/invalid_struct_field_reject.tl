;: SPEC safe-code contract: structs expose only declared fields.
(defstruct Point
  (x i64)
  (y i64))

(define (main [p : Point]) : i64
  (struct-get p z))