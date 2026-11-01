(defstruct Pair
  (x i64)
  (y i64))

(defstruct Triple
  (first i64)
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (read-field [p : (& p i64)]) : i64
  (deref p))

(defmacro (read-y) : Expr
  `(read-field (& state.y)))

(define (main) : i64
  (let
    [state : Triple (Triple 10 20 30)]
    (unless (= state.y 30) (return 1))
    (read-y)))