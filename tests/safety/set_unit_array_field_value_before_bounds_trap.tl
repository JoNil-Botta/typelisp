(defstruct Marker
  (empty unit)
  (value i64))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Marker) (__tl_make-array Marker 0)]
    (set!
      (array-ref a 0).empty
      (begin
        (shl (cast 1 : i64) -1)
        unit))
    0))