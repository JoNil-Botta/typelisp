;; A binding annotated `(in p String)` takes its initializer by value: an
;; element read through the reference moves out of the referenced array.
(define (first-length [p : (& p (Array String 2))]) : i64
  (let
    [moved : (in p String) (array-ref p 0)]
    0))

(define (main) : i64
  0)