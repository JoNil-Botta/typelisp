;: #5215: globals keep ordinary NLL, many-shared, distinct-root, and
;: disjoint-projection behavior.
(defstruct Pair
  (left i64)
  (right i64))

(define global-pair : Pair
  (Pair 1 2))
(define other-pair : Pair
  (Pair 3 4))

(define (read-two [_left : (& left Pair)] [_right : (& right Pair)]) : unit
  unit)

(define (write-two [_left : (&mut left i64)] [_right : (&mut right i64)]) : unit
  unit)

(define (main) : unit
  (begin
    (read-two (& global-pair) (& global-pair))
    (set! global-pair.left 5)
    (write-two (&mut global-pair.left) (&mut global-pair.right))
    (write-two (&mut global-pair.left) (&mut other-pair.left))))