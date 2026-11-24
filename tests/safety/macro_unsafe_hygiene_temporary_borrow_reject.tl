(define (takes-ref [r : (& i64)]) : i64
  (deref r))

(defmacro (call-takes-ref [arg : Expr]) : Expr
  `(unsafe
    (takes-ref ,arg)))

(define (main) : i64
  (let
    [x : i64 42]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (call-takes-ref (& (ptr-read p)))))