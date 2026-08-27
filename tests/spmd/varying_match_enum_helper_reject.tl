;; Enum matches whose varying source is not a contiguous array lane must use
;; the documented SIMD diagnostic instead of silently selecting scalar foreach.

(defenum Choice
  (Zero)
  (One))

(defstruct ChoiceReader
  (:lifetimes source)
  (items (& source (__tl_dyn-array Choice))))

(define (read-choice [reader : (ChoiceReader source)] [i : i64]) : Choice
  (array-ref reader.items i))

(define (main) : i64
  (let
    [items : (__tl_dyn-array Choice) (__tl_make-array Choice 2)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items 0) Zero)
      (set! (array-ref items 1) One)
      (let
        [reader : (ChoiceReader items) (ChoiceReader (& items))]
        (foreach
          ([i : i64 0 2])
          (set!
            (array-ref out i)
            (match (read-choice reader i)
              [Zero 11]
              [One 31]))))
      (if (and (= (array-ref out 0) 11) (= (array-ref out 1) 31))
        42
        1))))