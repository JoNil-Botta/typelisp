(defstruct Pair
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (read-field [p : (& p i64)]) : i64
  (deref p))

(defmacro (read-y) : Expr
  `(read-field (& state.y)))

(define (read-y-inside) : i64
  (read-y))

(defstruct Outer
  (prefix i64)
  (inner Pair))

(define outer : Outer
  (Outer 3 (Pair 4 6)))

(defmacro (read-nested) : Expr
  'outer.inner.y)

(defmacro (read-y-value) : Expr
  'state.y)

(define (add-field! [p : (&mut p i64)] [amount : i64]) : unit
  (set! (deref p) (+ (deref p) amount)))

(defmacro (bump-y! [amount : i64]) : Expr
  `(add-field! (&mut state.y) ,amount))

(defmacro (write-y! [value : i64]) : Expr
  `(set! state.y ,value))

(define (write-y-inside! [value : i64]) : unit
  (write-y! value))

(define (bump-y-inside! [amount : i64]) : unit
  (bump-y! amount))

(defmacro (with-local [value : i64]) : Expr
  `(let
    [state : Pair (Pair 8 3)]
    (+ state.y ,value)))

(defmacro (caller-value [value : i64]) : Expr
  `(+ 0 ,value))