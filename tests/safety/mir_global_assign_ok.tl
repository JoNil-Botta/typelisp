;: A module value is assigned in its static place (Copy and move-only).
(define counter : i64
  0)
(define names : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

(define (bump) : unit
  (set! counter (+ counter 1)))

(define (reset-names) : unit
  (set! names (__tl_make-array i64 3)))

(define (main) : i64
  (begin
    (bump)
    (reset-names)
    (+ counter (array-length names) 38)))