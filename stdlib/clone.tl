;# Declaration-macro support for compiler-checked `(clone value)` roots.
;#
;# The compiler owns cloneability, reachable-root discovery, arena semantics,
;# and diagnostics. This module owns all named struct/enum helper declarations
;# requested by the typed lowering handoff.
(import stdlib.comptime)

;: Emit clone helper declarations for all requested reachable aggregates.
(defmacro (synthesize-helpers [types : comptime.Expr ...]) : Decls
  (let
    [type-index : i64 (comptime.expr-list-length types)]
    [out : comptime.ExprList (comptime.expr-list-empty)]
    (begin
      (while (> type-index 0)
        (begin
          (set! type-index (- type-index 1))
          (let
            [T : comptime.Expr (comptime.expr-list-type-nth types type-index)]
            (begin
              (set! type-index (- type-index 1))
              (let
                [module-name : comptime.Expr
                  (comptime.expr-var
                    (comptime.expr-string-value
                      (comptime.expr-list-nth types type-index)))]
                (set!
                  out
                  (comptime.expr-list-cons
                    `(module ,module-name)
                    (match (type-kind T)
                      ["struct"
                        (let
                          [type-name : String (type-nominal-name T)]
                          [helper-name : comptime.Expr
                            (comptime.expr-var
                              (comptime.string-append "clone$" type-name))]
                          [type-ctor : comptime.Expr
                            (comptime.expr-var type-name)]
                          [args : comptime.ExprList (comptime.expr-list-empty)]
                          [index : i64 (- (struct-field-count T) 1)]
                          (begin
                            (while (>= index 0)
                              (let
                                [field : comptime.Expr
                                  (comptime.expr-struct-get
                                    (comptime.expr-var "value")
                                    (struct-field-name T index))]
                                (begin
                                  (set!
                                    args
                                    (comptime.expr-list-cons
                                      `(clone ,field)
                                      args))
                                  (set! index (- index 1)))))
                            (let
                              [body : comptime.Expr
                                (comptime.expr-call type-ctor args)]
                              (comptime.expr-list-cons
                                `(define (,helper-name [value : ,T]) : ,T
                                  ,body)
                                out))))]
                      ["enum"
                        (let
                          [type-name : String (type-nominal-name T)]
                          [helper-text : String
                            (comptime.string-append "clone$" type-name)]
                          [helper-name : comptime.Expr
                            (comptime.expr-var helper-text)]
                          [variant-count : i64 (enum-variant-count T)]
                          [first-count : i64
                            (if (= variant-count 2)
                              (enum-variant-payload-count T 0)
                              -1)]
                          [nil-index : i64
                            (if (= first-count 0)
                              0
                              1)]
                          [cons-index : i64
                            (if (= first-count 0)
                              1
                              0)]
                          [list-candidate : bool
                            (if (= variant-count 2)
                              (if (= (enum-variant-payload-count T nil-index) 0)
                                (= (enum-variant-payload-count T cons-index) 2)
                                false)
                              false)]
                          [direct-self : bool false]
                          [boxed-self : bool false]
                          (begin
                            (if list-candidate
                              (let
                                [tail-type : comptime.Expr
                                  (enum-variant-payload-type T cons-index 1)]
                                (begin
                                  (set!
                                    direct-self
                                    (string-eq
                                      (type-key tail-type)
                                      (type-key T)))
                                  (if (string-eq (type-kind tail-type) "box")
                                    (set!
                                      boxed-self
                                      (string-eq
                                        (type-key
                                          (comptime.box-element-type tail-type))
                                        (type-key T)))
                                    unit)))
                              unit)
                            (if (if direct-self
                              true
                              boxed-self)
                              (let
                                [acc-name : comptime.Expr
                                  (comptime.expr-var
                                    (comptime.string-append helper-text "$acc"))]
                                [rev-name : comptime.Expr
                                  (comptime.expr-var
                                    (comptime.string-append helper-text "$rev"))]
                                [nil-name : comptime.Expr
                                  (comptime.expr-var
                                    (comptime.string-append
                                      (comptime.string-append type-name ".")
                                      (enum-variant-name T nil-index)))]
                                [cons-name : comptime.Expr
                                  (comptime.expr-var
                                    (comptime.string-append
                                      (comptime.string-append type-name ".")
                                      (enum-variant-name T cons-index)))]
                                [nil-pattern : comptime.Pattern
                                  (comptime.pattern-variant
                                    (match nil-name
                                      [(comptime.ExprVar name) name]
                                      [_ ""])
                                    (comptime.pattern-list-empty))]
                                [cons-pattern : comptime.Pattern
                                  (comptime.pattern-variant
                                    (match cons-name
                                      [(comptime.ExprVar name) name]
                                      [_ ""])
                                    (comptime.pattern-list-cons
                                      (comptime.pattern-binding "head")
                                      (comptime.pattern-list-cons
                                        (comptime.pattern-binding "tail")
                                        (comptime.pattern-list-empty))))]
                                [next-tail : comptime.Expr
                                  (if boxed-self
                                    `(box-get tail)
                                    `tail)]
                                [acc-tail : comptime.Expr
                                  (if boxed-self
                                    `(box acc)
                                    `acc)]
                                [acc-cons : comptime.Expr
                                  (comptime.expr-call
                                    cons-name
                                    (comptime.expr-list-cons
                                      `(clone head)
                                      (comptime.expr-list-cons
                                        acc-tail
                                        (comptime.expr-list-empty))))]
                                [rev-cons : comptime.Expr
                                  (comptime.expr-call
                                    cons-name
                                    (comptime.expr-list-cons
                                      `head
                                      (comptime.expr-list-cons
                                        acc-tail
                                        (comptime.expr-list-empty))))]
                                [acc-step : comptime.Expr
                                  (comptime.expr-call
                                    acc-name
                                    (comptime.expr-list-cons
                                      next-tail
                                      (comptime.expr-list-cons
                                        acc-cons
                                        (comptime.expr-list-empty))))]
                                [rev-step : comptime.Expr
                                  (comptime.expr-call
                                    rev-name
                                    (comptime.expr-list-cons
                                      next-tail
                                      (comptime.expr-list-cons
                                        rev-cons
                                        (comptime.expr-list-empty))))]
                                [acc-body : comptime.Expr
                                  (comptime.expr-match
                                    (comptime.expr-var "value")
                                    (comptime.match-arm-list-cons
                                      (comptime.match-arm
                                        nil-pattern
                                        (comptime.expr-var "acc"))
                                      (comptime.match-arm-list-cons
                                        (comptime.match-arm
                                          cons-pattern
                                          acc-step)
                                        (comptime.match-arm-list-empty))))]
                                [rev-body : comptime.Expr
                                  (comptime.expr-match
                                    (comptime.expr-var "value")
                                    (comptime.match-arm-list-cons
                                      (comptime.match-arm
                                        nil-pattern
                                        (comptime.expr-var "acc"))
                                      (comptime.match-arm-list-cons
                                        (comptime.match-arm
                                          cons-pattern
                                          rev-step)
                                        (comptime.match-arm-list-empty))))]
                                (comptime.expr-list-cons
                                  `(define (,helper-name [value : ,T]) : ,T
                                    (,rev-name
                                      (,acc-name value (,nil-name))
                                      (,nil-name)))
                                  (comptime.expr-list-cons
                                    `(define (,acc-name [value : ,T] [acc : ,T]) : ,T
                                      ,acc-body)
                                    (comptime.expr-list-cons
                                      `(define (,rev-name
                                        [value : ,T]
                                        [acc : ,T]) : ,T
                                        ,rev-body)
                                      out))))
                              (let
                                [arms : comptime.MatchArmList
                                  (comptime.match-arm-list-empty)]
                                [variant-index : i64 (- variant-count 1)]
                                (begin
                                  (while (>= variant-index 0)
                                    (let
                                      [variant-name : String
                                        (enum-variant-name T variant-index)]
                                      [qualified-variant : String
                                        (comptime.string-append
                                          (comptime.string-append type-name ".")
                                          variant-name)]
                                      [payload-count : i64
                                        (enum-variant-payload-count
                                          T
                                          variant-index)]
                                      [binding-prefix : String
                                        (comptime.string-append
                                          "__clone_payload_"
                                          (comptime.string-append
                                            (comptime.int->string variant-index)
                                            "_"))]
                                      [ctor-args : comptime.ExprList
                                        (comptime.expr-list-empty)]
                                      [payload-index : i64 (- payload-count 1)]
                                      (begin
                                        (while (>= payload-index 0)
                                          (let
                                            [binding : comptime.Expr
                                              (comptime.expr-var
                                                (comptime.string-append
                                                  binding-prefix
                                                  (comptime.int->string
                                                    payload-index)))]
                                            (begin
                                              (set!
                                                ctor-args
                                                (comptime.expr-list-cons
                                                  `(clone ,binding)
                                                  ctor-args))
                                              (set!
                                                payload-index
                                                (- payload-index 1)))))
                                        (let
                                          [pattern : comptime.Pattern
                                            (comptime.pattern-variant
                                              qualified-variant
                                              (comptime.pattern-list-bindings
                                                binding-prefix
                                                payload-count))]
                                          [body : comptime.Expr
                                            (comptime.expr-call
                                              (comptime.expr-var
                                                qualified-variant)
                                              ctor-args)]
                                          (begin
                                            (set!
                                              arms
                                              (comptime.match-arm-list-cons
                                                (comptime.match-arm
                                                  pattern
                                                  body)
                                                arms))
                                            (set!
                                              variant-index
                                              (- variant-index 1)))))))
                                  (let
                                    [body : comptime.Expr
                                      (comptime.expr-match
                                        (comptime.expr-var "value")
                                        arms)]
                                    (comptime.expr-list-cons
                                      `(define (,helper-name [value : ,T]) : ,T
                                        ,body)
                                      out)))))))]
                      [_
                        (comptime.comptime-error
                          (comptime.string-append
                            "clone: stdlib handoff expected a named aggregate, got "
                            (type-key T)))]))))))))
      (comptime.expr-call (comptime.expr-var "begin") out))))