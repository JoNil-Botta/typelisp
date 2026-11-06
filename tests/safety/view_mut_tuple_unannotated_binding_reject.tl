;; Non-Copy tuple elements through a reference cannot bind by value.
(define (take [r : (&mut r (Tuple String i64))]) : i64
  (let
    [text (tuple-ref r 0)]
    0))

(define (main) : i64
  (let
    [items : (Tuple String i64) (tuple "a" 1)]
    (take (&mut items))))