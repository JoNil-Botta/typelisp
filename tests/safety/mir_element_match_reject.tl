;: A by-value match consumes its scrutinee, so matching a move-only element in
;: place moves it out of the array.
(import stdlib.string)

(defenum Shape
  (Named String)
  (Plain i64))

(define (count [xs : (& xs (__tl_dyn-array Shape))] [i : i64]) : i64
  (match (array-ref xs i)
    [(Shape.Named s) (string.string-length (& s))]
    [(Shape.Plain n) n]))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array Shape) (__tl_make-array Shape 1)]
    (begin
      (set! (array-ref xs 0) (Shape.Plain 42))
      (count (& xs) 0))))