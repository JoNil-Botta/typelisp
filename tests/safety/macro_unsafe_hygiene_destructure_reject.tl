(defmacro (unwrap-begin [e : Expr]) : Expr
  (match e
    [(comptime.Expr.Begin items)
      `(unsafe
        (begin
          ,@items))]
    [_
      `(unsafe
        ,e)]))

(define (main) : i64
  (let
    [x : i64 42]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (unwrap-begin
      (begin
        (ptr-read p)))))