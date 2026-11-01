;; A diverging operand (type Never) is an exit: the operations after it in its
;; form never run and the form itself is never performed, as a diverging
;; initializer ends its `let` (`never_let_initializer_ok`). Each function has a
;; diverging operand in another form: a call (direct, through a function value,
;; an immediately called lambda, a stdlib callee, a store receiver call), a
;; struct, variant, tuple, array or box construction, a unary operator, a
;; `set!` of a variable, field, element, tuple element, referent or box, a
;; `set!` and a read of an element whose index diverges, a `replace!`, a
;; `while` condition and a match scrutinee. Only the `return` and `break`
;; operands run here.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as vec)

(defstruct Point
  (x i64)
  (y i64))

(defstruct Token
  (id i64)
  (name String))

(defenum Shape
  (Empty)
  (Sized i64))

(define (take [b : bool]) : bool
  b)

(define (take2 [a : i64] [b : i64]) : i64
  (+ a b))

(define (consume [t : Token]) : i64
  t.id)

(define (call-arguments) : i64
  (+ (take2 1 (io.panic "second")) (take2 (io.panic "first") 1)))

(define (call-through-value) : bool
  (let
    [callee take]
    (callee (io.panic "callee"))))

(define (call-lambda) : bool
  ((lambda ([b : bool]) : bool
      b)
    (io.panic "lambda")))

(define (call-stdlib) : String
  (string.int->string (io.panic "stdlib")))

(define (store-receiver) : i64
  (let
    [values : vec.Vec (vec.new)]
    (begin
      (vec.push! values (io.panic "push"))
      (vec.len (& values)))))

(define (constructions) : i64
  (let
    [point : Point (Point 1 (io.panic "field"))]
    [shape : Shape (Shape.Sized (io.panic "payload"))]
    [pair : (Tuple i64 i64) (tuple point.x (io.panic "element"))]
    [items : (Array i64 2) (array 1 (io.panic "item"))]
    [boxed : (Box i64) (box (io.panic "box"))]
    (+ point.y (tuple-ref pair 0) (array-ref items 0))))

(define (unary) : bool
  (not (io.panic "operand")))

(define (assignments) : i64
  (let
    [v : i64 0]
    [point : Point (Point 1 2)]
    [items : (Array i64 2) (array 1 2)]
    [pair : (Tuple i64 i64) (tuple 1 2)]
    [boxed : (Box i64) (box 1)]
    (begin
      (set! v (io.panic "variable"))
      (set! point.x (io.panic "field"))
      (set! (array-ref items 0) (io.panic "element"))
      (set! (tuple-ref pair 0) (io.panic "tuple element"))
      (set! (deref boxed) (io.panic "box"))
      v)))

(define (assign-through [r : (&mut i64)]) : unit
  (set! (deref r) (io.panic "referent")))

(define (index-operands) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (begin
      (set! (array-ref items (io.panic "store index")) 3)
      (array-ref items (io.panic "read index")))))

(define (replacement) : i64
  (let
    [v : i64 0]
    (replace! v (io.panic "replacement"))))

(define (loop-condition) : i64
  (begin
    (while (io.panic "condition")
      unit)
    1))

(define (scrutinee [shapes : (Array Shape 2)]) : i64
  (+
    (match (Shape.Sized (io.panic "value"))
      [(Shape.Empty) 1]
      [(Shape.Sized n) n])
    (match (array-ref shapes (io.panic "place"))
      [(Shape.Empty) 1]
      [(Shape.Sized n) n])))

;; What follows the exit is typed but carries no ownership effect
;; (`mir_unreachable_tail_ok`).
(define (dead-operand [t : Token]) : i64
  (take2 (io.panic "exit") (+ (consume t) (consume t))))

(define (return-operand [x : i64]) : i64
  (take2 (return (+ x 1)) 100))

(define (set-return [x : i64]) : i64
  (let
    [v : i64 0]
    (begin
      (set! v (return x))
      v)))

(define (unary-return [x : bool]) : bool
  (not (return x)))

(define (break-operand [limit : i64]) : i64
  (let
    [n : i64 0]
    (begin
      (while (< n limit)
        (begin
          (take2 (break) 1)
          (set! n (+ n 1))))
      n)))

(define (select [mode : i64]) : i64
  (cond
    [(= mode 0) (call-arguments)]
    [(= mode 1)
      (if (call-through-value)
        1
        0)]
    [(= mode 2)
      (if (call-lambda)
        1
        0)]
    [(= mode 3)
      (let
        [text : String (call-stdlib)]
        (string.string-length (& text)))]
    [(= mode 4) (store-receiver)]
    [(= mode 5) (constructions)]
    [(= mode 6)
      (if (unary)
        1
        0)]
    [(= mode 7) (assignments)]
    [(= mode 8)
      (let
        [v : i64 0]
        (begin
          (assign-through (&mut v))
          v))]
    [(= mode 9) (index-operands)]
    [(= mode 10) (replacement)]
    [(= mode 11) (loop-condition)]
    [(= mode 12) (scrutinee (array (Shape.Empty) (Shape.Empty)))]
    [(= mode 13) (dead-operand (Token 1 "t"))]
    [else
      (+
        (return-operand 1)
        (break-operand 10)
        (set-return 30)
        (if (unary-return true)
          10
          0))]))

(define (main) : i64
  (select 14))