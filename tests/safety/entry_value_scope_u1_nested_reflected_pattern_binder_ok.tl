;; #9687: a nested macro binds a settled reflected name by its spelling.
(import stdlib.comptime)

(define hits : i64
  0)

(define (close-tok [_v : i64]) : unit
  (set! hits (+ hits 1)))

(defstruct Own
  (:cleanup clean)
  (v i64 (:cleanup close-tok)))

(defmacro (inner [e : Expr]) : Expr
  (match e
    [(comptime.Expr.Var i)
      (comptime.expr-match
        (comptime.expr-int 42)
        (comptime.match-arm-list-cons
          (comptime.match-arm
            (comptime.pattern-binding i)
            (comptime.expr-var i))
          (comptime.match-arm-list-empty)))]
    [_ (comptime.comptime-error "no")]))

(defmacro (m [X : type]) : Expr
  `(inner ,(comptime.expr-var (type-cleanup-function X))))

(define (main) : i64
  (cast (m Own) : i64))