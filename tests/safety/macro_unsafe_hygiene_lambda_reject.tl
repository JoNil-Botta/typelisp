(defmacro (make-thunk [e : Expr]) : Expr
  `(lambda () : i64
    ,e))

(define (main) : i64
  (let
    [x : i64 42]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    [f : (-> i64)
      (unsafe
        (make-thunk (ptr-read p)))]
    (f)))