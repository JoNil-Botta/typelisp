;; Non-Copy array elements through a reference cannot bind by value.
(define (take [r : (&mut r (Array String 2))]) : i64
  (let
    [_text (array-ref r 0)]
    0))

(define (main) : i64
  (let
    [items : (Array String 2) (array "a" "b")]
    (take (&mut items))))