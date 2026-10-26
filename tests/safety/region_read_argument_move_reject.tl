;; A `(in p String)` parameter takes its argument by value: an element read
;; through the reference moves out of the referenced array.
(define (keep [p : (& p (Array String 2))] [_s : (in p String)]) : i64
  3)

(define (pass-first [p : (& p (Array String 2))]) : i64
  (keep p (array-ref p 0)))

(define (main) : i64
  0)