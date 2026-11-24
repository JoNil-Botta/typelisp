(defstruct BoxHolder
  (b (Box i64)))

(defmacro (assign [place : Expr] [value : Expr]) : Expr
  `(unsafe
    (set! ,place ,value)))

(defmacro (store-through [value : Expr]) : Expr
  `(unsafe
    (assign (box-get (deref (int->ptr 8 : (MutPtr BoxHolder))).b) ,value)))

(define (main) : i64
  (begin
    (store-through 42)
    0))