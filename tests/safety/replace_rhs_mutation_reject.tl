;: The place reservation rejects a second mutation while evaluating the RHS.
(define (mutate [value : (&mut value i64)]) : i64
  (begin
    (set! (deref value) 2)
    3))

(define (main) : i64
  (let
    [value : i64 1]
    (replace! value (mutate (&mut value)))))