;; #9687: a type-compatible caller local takes `expr-var` of a reflected cleanup name.
(import stdlib.comptime)

(define hits : i64
  0)

(define (close-tok [_v : i64]) : unit
  (set! hits (+ hits 1)))

(defstruct Own
  (:cleanup clean)
  (v i64 (:cleanup close-tok)))

(define (other [o : Own]) : unit
  (set! hits 41)
  (clean o))

(defmacro (call-cleanup [X : type] [value : Expr]) : Expr
  (comptime.expr-call
    (comptime.expr-var (type-cleanup-function X))
    (comptime.expr-list-cons value (comptime.expr-list-empty))))

(define (main) : i64
  (let
    [clean : (-> Own unit) other]
    (call-cleanup Own (Own 1)))
  hits)