;; #5365: narrow masked shifts stage with a stable backend/type diagnostic.
(import stdlib.array)

(define (main) : i64
  (let
    [n : i64 17]
    [xs : (__tl_dyn-array i16) (array.make-array i16 n)]
    [out : (__tl_dyn-array i16) (array.make-array i16 n)]
    (begin
      (foreach
        ([i : i64 0 n])
        (let
          [x : i16 (array-ref xs i)]
          (set!
            (array-ref out i)
            (if (< x 0)
              (shr x 1)
              (shl x 1)))))
      42)))