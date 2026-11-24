(defmacro (read-matched [place : Expr]) : Expr
  `(unsafe
    (match ,place
      [v v])))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 10 42)]
    [idx : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of idx))]
    (read-matched (array-ref items (ptr-read p)))))