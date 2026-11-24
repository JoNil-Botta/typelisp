(defmacro (macro-b [x : Expr]) : Expr
  x)

(defmacro (macro-a [y : Expr]) : Expr
  `(unsafe
    (macro-b ,y)))

(defmacro (read-with-bonus [ptr : Expr] [bonus : Expr]) : Expr
  `(unsafe
    (+ (ptr-read ,ptr) (macro-b ,bonus))))

(define (main) : i64
  (let
    [x : i64 20]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    [a : i64
      (unsafe
        (macro-a (ptr-read p)))]
    [b : i64 (read-with-bonus p 2)]
    (+ a b)))