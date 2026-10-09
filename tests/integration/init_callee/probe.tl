;; Test macros for comptime_init_callee: each expands to the identity
;; `comptime.expr-binding-clause-init-callee` reports for its binding clauses.
(import stdlib.comptime)

;; The callee identity of the first clause's initializer.
(defmacro (callee-of [clauses : ExprBindingClause ...]) : String
  (comptime.expr-string
    (comptime.expr-binding-clause-init-callee
      (comptime.expr-binding-clause-list-nth clauses 0))))

;; The callee identities of every clause, each followed by `;`.
(defmacro (callees-of [clauses : ExprBindingClause ...]) : String
  (let
    [count : i64 (comptime.expr-binding-clause-list-length clauses)]
    [index : i64 0]
    [text : String ""]
    (while (< index count)
      (set!
        text
        (comptime.string-append
          text
          (comptime.string-append
            (comptime.expr-binding-clause-init-callee
              (comptime.expr-binding-clause-list-nth clauses index))
            ";")))
      (set! index (+ index 1)))
    (comptime.expr-string text)))