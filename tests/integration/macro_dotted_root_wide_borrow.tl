(defstruct Wide
  (x i64)
  (y i64)
  (guard i64))

(defstruct Narrow
  (x u8)
  (y u8)
  (guard u8))

(define state : Wide
  (Wide 257 66051 131585))

(defmacro (read-y) : Expr
  `(cast (deref (& state.y)) : i64))

(define (identity [value : i64]) : i64
  value)

(define (control) : i64
  (read-y))

(define (nested [state : Narrow]) : i64
  (unless (= state.y 23) (return 1))
  (identity (read-y)))

(define (tail [state : Narrow]) : i64
  (unless (= state.y 23) (return 1))
  (read-y))

(define (main) : i64
  (unless (= (control) 66051) (return 1))
  (let
    [failures : i64 0]
    (unless (= (nested (Narrow 17 23 41)) 66051) (+= failures 2))
    (unless (= (tail (Narrow 17 23 41)) 66051) (+= failures 4))
    (if (= failures 0)
      42
      failures)))