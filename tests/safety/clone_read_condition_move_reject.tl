;; A `clone` read reaches only its operand's result positions: an `if`
;; condition is used as anywhere else, so an owned value passed by value there
;; is moved.
(defstruct Cell
  (items (__tl_dyn-array i64)))

(define (empty? [cell : Cell]) : bool
  (= (array-length cell.items) 0))

(define (copy [a : Cell] [b : Cell]) : i64
  (let
    [_copy : Cell
      (clone
        (if (empty? a)
          b
          b))]
    (array-length a.items)))

(define (main) : i64
  0)