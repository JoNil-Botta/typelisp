;; A reference pushed into an array of references keeps its loan in the
;; array: mutating the referent while the array is still used conflicts.
(define (bump [cell : (&mut cell i64)]) : unit
  (set! (deref cell) (+ (deref cell) 1)))

(define (main) : i64
  (let
    [value : i64 41]
    [refs : (__tl_dyn-array (& value i64))
      (init : (__tl_dyn-array (& value i64)))]
    (begin
      (__tl_array-push! refs (& value))
      (bump (&mut value))
      (array-length refs))))