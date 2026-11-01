;; An element read through a reference and returned as `(in p String)` is
;; still the element itself: returning it by value moves it out of the
;; referenced array.
(define (first [p : (& p (Array String 2))]) : (in p String)
  (array-ref p 0))

(define (main) : i64
  0)