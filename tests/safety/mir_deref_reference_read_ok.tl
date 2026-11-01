;; Reading a Copy value through an evaluated reference copies it out; the
;; temporary borrow ends at the read.
(defstruct Cell
  (value i64))

(define (pick [left : (& left Cell)] [right : (& right Cell)] [first? : bool]) : i64
  (if first?
    (deref (& left.value))
    (deref (& right.value))))

(define (main) : i64
  (let
    [a : Cell (Cell 40)]
    [b : Cell (Cell 2)]
    (+ (pick (& a) (& b) true) (pick (& a) (& b) false))))