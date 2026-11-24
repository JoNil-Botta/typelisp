(defmacro (wrap [e : Expr]) : Expr
  `(unsafe
    ,e))

(define (main) : i64
  (let
    [x : i64 42]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (wrap (ptr-read p))))