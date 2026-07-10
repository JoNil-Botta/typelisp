;; comptime_mut_borrow_rvalue_reject.tl - a generated explicit mutable borrow
;; keeps the normal place-only diagnostic for a temporary receiver.
(import stdlib.comptime)

(defstruct Counter
  (value i64))

(define (assign-ref [target : (&mut owner Counter)] [next : i64]) : unit
  (set! target.value next))

(defmacro (assign! [place : comptime.Expr] [value : comptime.Expr]) : unit
  (comptime.expr-call
    (comptime.expr-var "assign-ref")
    (comptime.expr-list-cons
      (comptime.expr-mut-borrow place)
      (comptime.expr-list-cons value (comptime.expr-list-empty)))))

(define (main) : unit
  (assign! (Counter 0) 42))