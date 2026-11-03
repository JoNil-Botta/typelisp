(defmacro (nominal-dag [lifetime : Expr] [leaf : Expr]) : Decls
  (let
    [ty : Expr leaf]
    [level : i64 0]
    (while (< level 12)
      (set! ty `(Tuple ,ty ,ty))
      (set! level (+ level 1)))
    `(defstruct N
      (:lifetimes ,lifetime)
      (value ,ty))))

(nominal-dag r (& r i64))

(define (down [x : (& a (N b))]) : (N b)
  (deref x))

(define (main) : i64
  0)