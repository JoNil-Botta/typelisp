(defstruct BoxHolder
  (b (Box i64)))

(defmacro (assign [place : Expr] [value : Expr]) : Expr
  `(unsafe
    (set! ,place ,value)))

;; The box place is template text of `store-through`, which opens no
;; `(unsafe ...)`; `assign`'s own `(unsafe ...)` must not cover it.
(defmacro (store-through [value : Expr]) : Expr
  `(assign (box-get (deref (int->ptr 8 : (MutPtr BoxHolder))).b) ,value))

(define (main) : i64
  (begin
    (store-through 42)
    0))