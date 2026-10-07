;; A `for` item annotation is still checked against the borrowed element type
;; after it is unquoted (#8581).
(define (sum [arr : (& a (Array i64 4))]) : i64
  (let
    [total : i64 0]
    ; Must fail: the elements are i64, not i32.
    (for [x : (& a i32) arr] (set! total (+ total 1)))
    total))

(define (main) : i64
  0)