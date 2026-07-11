;: Fixed-arity mutable call builders retain the ordinary place-only diagnostic.
(import stdlib.comptime)

(defstruct Counter
  (value i64))

(define (assign-ref! [target : (&mut owner Counter)] [next : i64]) : unit
  (set! target.value next))

(defmacro (assign! [place : comptime.Expr] [value : comptime.Expr]) : unit
  (expr-mut-call1 (expr-var "assign-ref!") place value))

(define (main) : unit
  (assign! (Counter 0) 42))