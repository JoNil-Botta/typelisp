(defstruct Pair
  (x i64)
  (y i64))

(defstruct Triple
  (first i64)
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (add-field! [p : (&mut p i64)] [amount : i64]) : unit
  (+= (deref p) amount))

(define (add-pair! [p : (&mut p Pair)] [amount : i64]) : unit
  (+= p.y amount))

(define (global-y) : i64
  state.y)

(defmacro (bump-y!) : Expr
  `(add-field! (&mut state.y) 5))

(defmacro (bump-pair!) : Expr
  `(add-pair! (&mut state) 3))

(define (main) : i64
  (let
    [state : Triple (Triple 10 20 30)]
    (bump-y!)
    (unless (= (global-y) 7) (return 1))
    (bump-pair!)
    (unless (= (global-y) 10) (return 3))
    (unless (= state.y 30) (return 4))
    2))