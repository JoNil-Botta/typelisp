(defmacro (write-field [receiver : Expr] [value : Expr]) : Expr
  (comptime.expr-struct-set receiver "value" value))

(defstruct RefBox
  (:lifetimes keep)
  (value (& keep i64)))

(define (store [p : (& keep i64)] [b : (&mut holder (RefBox keep))]) : unit
  (let
    [outer
      (lambda () : unit
        (let
          [put
            (lambda ([q : (& keep i64)]) : unit
              (write-field b q))]
          (let
            [short : i64 5]
            (put (& short)))))]
    (outer)))

(define (main) : i64
  0)