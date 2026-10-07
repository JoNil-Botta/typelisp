;: Fixed-arity mutable call builders follow the ordinary rule: a temporary
;: receiver is a borrowed call-argument temporary (SPEC section 3.10).
(import stdlib.comptime)

(defstruct Counter
  (value i64))

(define (assign-ref! [target : (&mut owner Counter)] [next : i64]) : unit
  (set! target.value next))

(defmacro (assign! [place : comptime.Expr] [value : comptime.Expr]) : unit
  (expr-mut-call1 (expr-var "assign-ref!") place value))

(define (main) : unit
  (assign! (Counter 0) 42))