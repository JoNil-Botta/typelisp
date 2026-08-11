;: Plain function types cannot retain a non-Copy closure environment fact.
(import stdlib.string)

(define (make-reader [owned : String]) : (-> i64)
  (lambda () : i64
    (string.string-length owned)))

(define (main) : i64
  ((make-reader "captured")))