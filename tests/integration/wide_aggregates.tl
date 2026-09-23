;; Macros that declare aggregates wider than the former 1000-member registry
;; stride (#7921) without committing thousands of generated lines. Shared by
;; the tests/safety wide-aggregate rejections and the wide_struct / wide_enum
;; integration programs.
;;
;; A count that is not an integer literal expands to a call of the unbound name
;; `wide-aggregates-count-must-be-an-integer-literal`, which typecheck reports.
(import stdlib.comptime)

;; `(wide-struct Name N)` declares `(defstruct Name (f0 i64) ... (fN-1 i64)
;; (tail i64))`: N numbered fields followed by one more.
(defmacro (wide-struct [name : comptime.Expr] [count-expr : comptime.Expr]) : Decls
  (match count-expr
    [(comptime.Expr.Int count)
      ;; The member type list is built once: every iteration costs compile-time
      ;; fuel, and 2500 members must fit the fixed CTFE budget.
      (let
        [items : comptime.ExprList (comptime.expr-list-empty)]
        [member-type : comptime.ExprList
          (comptime.expr-list-cons
            (comptime.expr-var "i64")
            (comptime.expr-list-empty))]
        [index : i64 count]
        (begin
          (while (> index 0)
            (begin
              (set! index (- index 1))
              (set!
                items
                (comptime.expr-list-cons
                  (comptime.expr-call
                    (comptime.expr-var
                      (comptime.string-append "f" (comptime.int->string index)))
                    member-type)
                  items))))
          `(defstruct ,name
            ,@items
            (tail i64))))]
    [_
      `(define (wide-aggregates-count-error) : i64
        (wide-aggregates-count-must-be-an-integer-literal))]))

;; `(wide-struct-value Name N)` constructs `(Name 1 2 ... N 0)`: field fK holds
;; K + 1 and `tail` holds 0.
(defmacro (wide-struct-value
  [name : comptime.Expr]
  [count-expr : comptime.Expr]) : comptime.Expr
  (match count-expr
    [(comptime.Expr.Int count)
      (let
        [items : comptime.ExprList
          (comptime.expr-list-cons
            (comptime.expr-int 0)
            (comptime.expr-list-empty))]
        [index : i64 count]
        (begin
          (while (> index 0)
            (begin
              (set!
                items
                (comptime.expr-list-cons (comptime.expr-int index) items))
              (set! index (- index 1))))
          `(,name ,@items)))]
    [_ `(wide-aggregates-count-must-be-an-integer-literal)]))

;; `(wide-enum Name N)` declares `(defenum Name (V0 i64) ... (VN-1 i64))`.
(defmacro (wide-enum [name : comptime.Expr] [count-expr : comptime.Expr]) : Decls
  (match count-expr
    [(comptime.Expr.Int count)
      ;; The member type list is built once: every iteration costs compile-time
      ;; fuel, and 2500 variants must fit the fixed CTFE budget.
      (let
        [items : comptime.ExprList (comptime.expr-list-empty)]
        [member-type : comptime.ExprList
          (comptime.expr-list-cons
            (comptime.expr-var "i64")
            (comptime.expr-list-empty))]
        [index : i64 count]
        (begin
          (while (> index 0)
            (begin
              (set! index (- index 1))
              (set!
                items
                (comptime.expr-list-cons
                  (comptime.expr-call
                    (comptime.expr-var
                      (comptime.string-append "V" (comptime.int->string index)))
                    member-type)
                  items))))
          `(defenum ,name
            ,@items)))]
    [_
      `(define (wide-aggregates-count-error) : i64
        (wide-aggregates-count-must-be-an-integer-literal))]))