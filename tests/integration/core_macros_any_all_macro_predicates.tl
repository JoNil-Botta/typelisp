;; An `any?` / `all?` predicate, or a binding-prefix body, may use a macro
;; with typed operands (`or`, `and`, `when`) on the clause binder, as a plain
;; `for` body can (#8748). `main` returns 42 only when every answer is right.
(import stdlib.iterator)

(defstruct Seq
  (slots (__tl_dyn-array i64))
  (len i64))

;; The issue's user macro: the same signature as `any?`, forwarding the
;; caller's clauses into `for` with their syntax kept.
(defmacro (my-any? [bindings : ExprBindingClause ...] [predicate : Expr ...]) : bool
  (let
    [clauses : ExprList (comptime.expr-binding-clause-list->expr-list bindings)]
    [test : Expr (comptime.expr-list-nth predicate 0)]
    `(let
      [found false]
      (for ,@clauses
        (when ,test (set! found true)))
      found)))

(define (main) : i64
  (let
    [fixed : (Array i64 4) (array 1 3 4 5)]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [hits : i64 0]
    (begin
      (set! (array-ref slots 0) 2)
      (set! (array-ref slots 1) 4)
      (set! (array-ref slots 2) 7)
      (let
        [seq : Seq (Seq slots 3)]
        [any-or : bool
          (any? [i (iterator.range 0 4)]
            (or (> i 2) false))]
        [any-or-none : bool
          (any? [i (iterator.range 0 4)]
            (or (> i 5) (< i 0)))]
        [all-and : bool
          (all? [i (iterator.range 0 4)]
            (and (>= i 0) (< i 4)))]
        [all-and-fails : bool
          (all? [i (iterator.range 0 4)]
            (and (>= i 0) (< i 3)))]
        [any-array : bool
          (any? [x (& fixed)]
            (and (> (deref x) 3) (< (deref x) 5)))]
        [all-slots : bool
          (all? [x (& seq)]
            (or (< (deref x) 5) (= (deref x) 7)))]
        [any-when : bool
          (any? [i (iterator.range 0 4)]
            (begin
              (when (> i 1) (set! hits (+ hits 1)))
              (= i 3)))]
        ;; Nested: an `all?` predicate holding an `any?` over its own binder,
        ;; with `or` / `and` at both levels.
        [nested : bool
          (all? [row (iterator.range 1 4)]
            (and
              (> row 0)
              (any? [col (iterator.range 0 4)]
                (or (= (* row col) 6) (and (= row 1) (= col 3))))))]
        [nested-fails : bool
          (all? [row (iterator.range 1 5)]
            (any? [col (iterator.range 0 4)]
              (or (= (* row col) 6) (= row 1))))]
        [user-any : bool (my-any? [i (iterator.range 0 4)] (or (> i 2) false))]
        [user-any-none : bool
          (my-any? [i (& fixed)] (and (> (deref i) 4) false))]
        (cond
          [(not any-or) 1]
          [any-or-none 2]
          [(not all-and) 3]
          [all-and-fails 4]
          [(not any-array) 5]
          [(not all-slots) 6]
          [(not any-when) 7]
          ;; i = 2 and i = 3 run the `when` body before the first true item.
          [(not (= hits 2)) 8]
          [(not nested) 9]
          ;; row 4 has no col with 4 * col = 6
          [nested-fails 10]
          [(not user-any) 11]
          [user-any-none 12]
          [else 42])))))