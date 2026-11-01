;; A slice of references is an ordinary shared referent.
(define (count-refs [refs : (& refs (Slice (& refs str)))]) : i64
  (array-length refs))

(define (main) : i64
  0)