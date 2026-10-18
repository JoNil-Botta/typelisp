(define text : String
  "global")

(defmacro (borrow-global) : Expr
  `(& text))

(define (read [_value : (& value str)]) : i64
  42)

(define (consume [_value : String]) : unit
  unit)

(define (main) : i64
  (let
    [text : String "local"]
    [local : (& text str) (& text)]
    (read (borrow-global))
    (consume text)
    (read local)))