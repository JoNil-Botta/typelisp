(defmacro (nominal-dag [lifetime : Expr] [leaf : Expr]) : Decls
  (let
    [ty : Expr leaf]
    [level : i64 0]
    (while (< level 8)
      (set! ty `(Tuple ,ty ,ty))
      (set! level (+ level 1)))
    `(defstruct N
      (:lifetimes ,lifetime)
      (value ,ty))))

(nominal-dag r (& r i64))

(define (shorten [x : (N program)] [q : (& q i64)]) : (N q)
  x)

(define (main) : i64
  0)