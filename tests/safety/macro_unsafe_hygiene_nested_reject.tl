(defmacro (macro-b [x : Expr]) : Expr
  x)

(defmacro (macro-a [y : Expr]) : Expr
  `(unsafe
    (macro-b ,y)))

(define (main) : i64
  (let
    [x : i64 42]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (macro-a (ptr-read p))))