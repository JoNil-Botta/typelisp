;; #9687: a nested macro reads a settled reflected name as text.
(import stdlib.comptime)
(import stdlib.string)

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
      (comptime.expr-call
        (comptime.expr-var "__tl_string_length")
        (comptime.expr-list-cons
          (comptime.expr-string i)
          (comptime.expr-list-empty)))]
    [_ (comptime.comptime-error "no")]))

(defmacro (m [X : type]) : Expr
  `(inner ,(comptime.expr-var (type-cleanup-function X))))

(define (main) : i64
  (+ 37 (cast (m Own) : i64)))