(defmacro (write-field [receiver : Expr] [value : Expr]) : Expr
  (comptime.expr-struct-set receiver "value" value))

(defstruct RefBox
  (:lifetimes keep)
  (value (& keep i64)))

(define (store [p : (& keep i64)] [b : (&mut holder (RefBox keep))]) : unit
  (let
    [put
      (lambda ([q : (& keep i64)]) : unit
        (write-field b q))]
    (let
      [alias put]
      (alias p))))

(define (main) : i64
  (let
    [value : i64 42]
    [cell (RefBox (& value))]
    (store (& value) (&mut cell))
    (deref cell.value)))