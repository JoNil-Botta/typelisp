(defstruct Narrow
  (x u8)
  (y u8)
  (guard u8))

(defstruct Wide
  (x i64)
  (y i64)
  (guard i64))

(define state : Narrow
  (Narrow 17 23 41))

(defmacro (read-y) : Expr
  `(deref (& state.y)))

(define (control) : i64
  (cast (read-y) : i64))

(define (main) : i64
  (unless (= (control) 23) (return 1))
  (let
    [state : Wide (Wide 1000 2000 3000)]
    (unless (= (cast (read-y) : i64) 23) (return 2))
    (unless (= state.y 2000) (return 3))
    42))