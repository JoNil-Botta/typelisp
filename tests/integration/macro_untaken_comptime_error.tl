;; A macro's `comptime-error` arm reports only when an expansion takes it. The
;; definition-time body probe binds placeholder operands (a `Var` per ordinary
;; operand, an empty list per variadic), so every rejection below sits on the
;; path that probe takes while no call here takes it.
(import stdlib.comptime)

(defmacro (reject-var-first [value : comptime.Expr]) : comptime.Expr
  (match value
    [(comptime.Expr.Var _)
      (comptime.comptime-error "reject-var-first: identifier")]
    [_ value]))

(defmacro (int-or-reject [value : comptime.Expr]) : comptime.Expr
  (match value
    [(comptime.Expr.Int _) value]
    [_ (comptime.comptime-error "int-or-reject: not an integer literal")]))

(defmacro (first-operand [values : i64 ...]) : i64
  (if (= (comptime.expr-list-length values) 0)
    (comptime.comptime-error "first-operand: expects an operand")
    (comptime.expr-list-nth values 0)))

(defmacro (define-var-rejected [value : comptime.Expr]) : Decls
  (match value
    [(comptime.Expr.Var _)
      (comptime.comptime-error "define-var-rejected: identifier")]
    [_
      `(define (var-rejected-answer) : i64
        ,value)]))

(defmacro (define-int-accepted [value : comptime.Expr]) : Decls
  (match value
    [(comptime.Expr.Int _)
      `(define (int-accepted-answer) : i64
        ,value)]
    [_ (comptime.comptime-error "define-int-accepted: not an integer literal")]))

(define-var-rejected 13)

(define-int-accepted 14)

(define (main) : i64
  (if (and
    (= (reject-var-first 10) 10)
    (= (int-or-reject 11) 11)
    (= (first-operand 12 99) 12)
    (= (var-rejected-answer) 13)
    (= (int-accepted-answer) 14))
    42
    1))