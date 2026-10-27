(defstruct Pair
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (change! [field : (&mut field i64)]) : unit
  (set! (deref field) 5))

(defmacro (borrow-y!) : Expr
  `(change! (&mut state.y)))

(defmacro (write-y!) : Expr
  `(set! state.y 5))