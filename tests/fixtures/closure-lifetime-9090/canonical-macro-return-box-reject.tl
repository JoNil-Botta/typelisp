(defmacro (write-field [receiver : Expr] [value : Expr]) : Expr
  (comptime.expr-struct-set receiver "value" value))
(defstruct RefBox (:lifetimes keep) (value (& keep i64)))
(define (make [b : (&mut holder (RefBox keep))]) : (Box (-> (& keep i64) unit))
  (box (lambda ([q : (& keep i64)]) : unit (write-field b q))))
(define (main) : i64 0)
