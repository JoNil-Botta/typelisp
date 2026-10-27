(defstruct Pair
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (read-field [p : (& p i64)]) : i64
  (deref p))

(defmacro (read-y) : Expr
  `(read-field (& state.y)))

(define (read-with-shadow [state : (& s Pair)]) : i64
  (unless (= state.y 30) (return 1))
  (read-y))

(define (main) : i64
  (let
    [other : Pair (Pair 20 30)]
    (read-with-shadow (& other))))