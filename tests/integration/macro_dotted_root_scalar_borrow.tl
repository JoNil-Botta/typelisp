(defstruct Wide
  (x i64)
  (y i64)
  (guard i64))

(define state : Wide
  (Wide 257 66051 131585))

(defmacro (read-y) : Expr
  `(deref (& state.y)))

(define (identity [value : i64]) : i64
  value)

(define (control) : i64
  (identity (read-y)))

(define (scalar [state : i64]) : i64
  (unless (= state 17) (return 1))
  (identity (read-y)))

(define (boolean [state : bool]) : i64
  (unless state (return 1))
  (identity (read-y)))

(define (main) : i64
  (unless (= (control) 66051) (return 1))
  (unless (= (scalar 17) 66051) (return 2))
  (unless (= (boolean true) 66051) (return 3))
  42)