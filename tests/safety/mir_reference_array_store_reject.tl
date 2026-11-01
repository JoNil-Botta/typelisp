;; A reference stored into an element of an array of references keeps its
;; loan in the array, as a pushed one does.
(defstruct Pair
  (a i64)
  (b i64))

(define (bump [cell : (&mut cell Pair)]) : unit
  (set! cell.b (+ cell.b 1)))

(define (main) : i64
  (let
    [pair : Pair (Pair 1 41)]
    [refs : (__tl_dyn-array (& pair i64))
      (init : (__tl_dyn-array (& pair i64)))]
    (begin
      (__tl_array-push! refs (& pair.a))
      (set! (array-ref refs 0) (& pair.b))
      (bump (&mut pair))
      (array-length refs))))