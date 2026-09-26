;: A shared fixed-array reference cannot have an element replaced.
(define (replace-shared [items : (& items (Array i64 1))]) : i64
  (replace! (array-ref items 0) 1))

(define (main) : i64
  42)