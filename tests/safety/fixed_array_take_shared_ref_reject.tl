;: Shared fixed-array references cannot be mutated by taking an element.
(define (take-shared [items : (& items (Array i64 1))]) : i64
  (array-take! items 0))

(define (main) : i64
  42)