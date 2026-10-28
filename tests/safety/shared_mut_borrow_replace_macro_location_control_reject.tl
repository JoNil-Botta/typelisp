(defstruct Pair
  (x i64)
  (y i64))

(defmacro (mut-view [place : Expr]) : Expr
  `(&mut ,place))

(define (probe [shared : (& shared Pair)]) : i64
  (replace! (deref (mut-view shared.x)) 5))

(define (main) : i64
  42)