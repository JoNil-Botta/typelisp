;; An array of references built from parameters is returned with their
;; lifetime.
(define (pick-refs [a : (& cell i64)] [b : (& cell i64)]) : (__tl_dyn-array
    (& cell i64))
  (let
    [refs : (__tl_dyn-array (& cell i64))
      (init : (__tl_dyn-array (& cell i64)))]
    (begin
      (__tl_array-push! refs a)
      refs)))

(define (main) : i64
  0)