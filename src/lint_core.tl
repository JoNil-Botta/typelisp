;# TypeLisp lint engine + source cleanup rules (#1163, #1177).
;#
;# A selfhost lint pass: walk the parsed AST, run registered rules, and collect
;# findings. The rules flag body-only nested `let` forms, nested success-path
;# `if` return chains, unit-branch return guards, no-effect expression
;# statements, nested `str-cat` calls, and deprecated user-facing string
;# concatenation primitives.
;#
;# The `typelisp lint` CLI driver consumes the rule id attached to each finding
;# for suppression (`;; lint-allow: <rule-id>`). This module owns stable rule
;# metadata and the lint core verified by `compiler-lint-self-test` (driver:
;# `selfhost/lint_smoke.tl`).
(import "../stdlib/io.tl")
(import "compiler_ast_types.tl")
(import "lex.tl")

;: A single lint finding: stable rule id, human-readable message, rule-specific
;: depth metadata, and the source span of the flagged node (the `lint-no-span`
;: sentinel when the node carried no location, e.g. a synthesized expression).
(defstruct LintFinding
  (message String)
  (rule-id String)
  (depth i64)
  (span AstSourceSpan))

;: Stable rule id for the dormant nested-`if`-ladder rule. Rule ids are the
;: suppression key (`;; lint-allow: <rule-id>`) and the registry key, so this
;: remains registered even while #2579 keeps bootstrap source on nested `if`.
(define (lint-rule-nested-if-ladder-id) : String
  "nested-if-ladder")

;: Public message text retained for compatibility with rule metadata lookups.
(define (lint-rule-nested-if-ladder-message) : String
  "nested if-ladder: chain of if/else-if; prefer cond (value/guard ladders) or match (variant dispatch)")

(define (lint-rule-nested-if-ladder-suggestion) : String
  "prefer cond (value/guard ladders) or match (variant dispatch)")

(define (lint-rule-nested-let-id) : String
  "nested-let")

(define (lint-rule-nested-let-message) : String
  "nested let: body is a single let; merge bindings into one sequential let")

(define (lint-rule-nested-let-suggestion) : String
  "merge the nested let bindings into one sequential let")

(define (lint-rule-return-path-chain-id) : String
  "return-path-chain")

(define (lint-rule-return-path-chain-message) : String
  "return-path chain: nested success-path ifs; prefer guard clauses with (return ...)")

(define (lint-rule-return-path-chain-suggestion) : String
  "prefer early return guards with (return ...)")

(define (lint-rule-unit-if-guard-id) : String
  "unit-if-guard")

(define (lint-rule-unit-if-guard-message) : String
  "unit guard if: prefer when/unless")

(define (lint-rule-unit-if-guard-suggestion) : String
  "prefer when/unless for unit guard branches")

(define (lint-rule-no-effect-id) : String
  "no-effect")

(define (lint-rule-no-effect-message) : String
  "no-effect expression: value is discarded")

(define (lint-rule-no-effect-suggestion) : String
  "remove the expression or use its value")

(define (lint-rule-unreachable-code-id) : String
  "unreachable-code")

(define (lint-rule-unreachable-code-message) : String
  "unreachable code: expression follows a terminal expression")

(define (lint-rule-unreachable-code-suggestion) : String
  "remove the unreachable expression or move it before the terminal expression")

(define (lint-rule-deprecated-string-concat-id) : String
  "deprecated-string-concat")

(define (lint-rule-deprecated-string-concat-message) : String
  "deprecated string concatenation primitive: use str-cat for fixed arity or text_buf for incremental building")

(define (lint-rule-deprecated-string-concat-suggestion) : String
  "import stdlib/str_cat.tl and use str-cat, or use stdlib/text_buf.tl in accumulation loops")

(define (lint-rule-nested-str-cat-id) : String
  "nested-str-cat")

(define (lint-rule-nested-str-cat-message) : String
  "nested str-cat: prefer one flat str-cat call")

(define (lint-rule-nested-str-cat-suggestion) : String
  "flatten nested str-cat operands into the outer call")

(define (lint-rule-cascading-and-or-id) : String
  "cascading-and-or")

(define (lint-rule-cascading-and-or-message) : String
  "cascading and/or: prefer one flat n-ary macro call")

(define (lint-rule-cascading-and-or-suggestion) : String
  "flatten same-operator and/or operands, e.g. (and a b c)")

(define (lint-rule-unused-import-id) : String
  "unused-import")

(define (lint-rule-unused-import-message) : String
  "unused import: imported module alias is never referenced")

(define (lint-rule-unused-import-suggestion) : String
  "remove the import or prefix an intentionally unused alias with _")

(define (lint-rule-dead-code-id) : String
  "dead-code")

(define (lint-rule-dead-code-message) : String
  "dead code: private top-level declaration is never referenced")

(define (lint-rule-dead-code-suggestion) : String
  "remove the declaration or export/reference it intentionally")

(define (lint-rule-unused-assignment-id) : String
  "unused-assignment")

(define (lint-rule-unused-assignment-message) : String
  "unused assignment: value is overwritten before it is read")

(define (lint-rule-unused-assignment-suggestion) : String
  "remove the assignment or read the value before overwriting it")

(define (lint-rule-unused-variable-id) : String
  "unused-variable")

(define (lint-rule-unused-variable-message) : String
  "unused variable: parameter or local binding is never used")

(define (lint-rule-unused-variable-suggestion) : String
  "remove the binding or prefix an intentionally unused name with _")

(define (lint-rule-unused-unsafe-id) : String
  "unused-unsafe")

(define (lint-rule-unused-unsafe-message) : String
  "unused unsafe block: body does not require unsafe context")

(define (lint-rule-unused-unsafe-suggestion) : String
  "remove the unsafe wrapper")

;: Metadata for one lint rule. Rule id is stable public API for suppressions;
;: message is the rendered finding text; suggestion is structured helper text
;: that drivers or tooling can render separately from the message.
(defstruct LintRule
  (rule-id String)
  (message String)
  (suggestion String))

;: Immutable list of registered rules.
(defenum LintRuleList
  (LintRuleNil)
  (LintRuleCons LintRule (Box LintRuleList)))

(defenum LintMaybeRule
  (LintRuleNotFound)
  (LintRuleFound LintRule))

(define (lint-rule-nested-if-ladder) : LintRule
  (LintRule
    (lint-rule-nested-if-ladder-id)
    (lint-rule-nested-if-ladder-message)
    (lint-rule-nested-if-ladder-suggestion)))

(define (lint-rule-nested-let) : LintRule
  (LintRule
    (lint-rule-nested-let-id)
    (lint-rule-nested-let-message)
    (lint-rule-nested-let-suggestion)))

(define (lint-rule-return-path-chain) : LintRule
  (LintRule
    (lint-rule-return-path-chain-id)
    (lint-rule-return-path-chain-message)
    (lint-rule-return-path-chain-suggestion)))

(define (lint-rule-unit-if-guard) : LintRule
  (LintRule
    (lint-rule-unit-if-guard-id)
    (lint-rule-unit-if-guard-message)
    (lint-rule-unit-if-guard-suggestion)))

(define (lint-rule-no-effect) : LintRule
  (LintRule
    (lint-rule-no-effect-id)
    (lint-rule-no-effect-message)
    (lint-rule-no-effect-suggestion)))

(define (lint-rule-unreachable-code) : LintRule
  (LintRule
    (lint-rule-unreachable-code-id)
    (lint-rule-unreachable-code-message)
    (lint-rule-unreachable-code-suggestion)))

(define (lint-rule-deprecated-string-concat) : LintRule
  (LintRule
    (lint-rule-deprecated-string-concat-id)
    (lint-rule-deprecated-string-concat-message)
    (lint-rule-deprecated-string-concat-suggestion)))

(define (lint-rule-nested-str-cat) : LintRule
  (LintRule
    (lint-rule-nested-str-cat-id)
    (lint-rule-nested-str-cat-message)
    (lint-rule-nested-str-cat-suggestion)))

(define (lint-rule-cascading-and-or) : LintRule
  (LintRule
    (lint-rule-cascading-and-or-id)
    (lint-rule-cascading-and-or-message)
    (lint-rule-cascading-and-or-suggestion)))

(define (lint-rule-unused-import) : LintRule
  (LintRule
    (lint-rule-unused-import-id)
    (lint-rule-unused-import-message)
    (lint-rule-unused-import-suggestion)))

(define (lint-rule-dead-code) : LintRule
  (LintRule
    (lint-rule-dead-code-id)
    (lint-rule-dead-code-message)
    (lint-rule-dead-code-suggestion)))

(define (lint-rule-unused-assignment) : LintRule
  (LintRule
    (lint-rule-unused-assignment-id)
    (lint-rule-unused-assignment-message)
    (lint-rule-unused-assignment-suggestion)))

(define (lint-rule-unused-variable) : LintRule
  (LintRule
    (lint-rule-unused-variable-id)
    (lint-rule-unused-variable-message)
    (lint-rule-unused-variable-suggestion)))

(define (lint-rule-unused-unsafe) : LintRule
  (LintRule
    (lint-rule-unused-unsafe-id)
    (lint-rule-unused-unsafe-message)
    (lint-rule-unused-unsafe-suggestion)))

(define (lint-rule-cons [rule : LintRule] [rest : LintRuleList]) : LintRuleList
  (LintRuleCons rule (box rest)))

;: Small registry for lint metadata. New rules plug into this list and the
;: shared lookup helpers without requiring public driver edits.
(define (lint-rule-registry) : LintRuleList
  (lint-rule-cons
    (lint-rule-nested-if-ladder)
    (lint-rule-cons
      (lint-rule-nested-let)
      (lint-rule-cons
        (lint-rule-return-path-chain)
        (lint-rule-cons
          (lint-rule-unit-if-guard)
          (lint-rule-cons
            (lint-rule-no-effect)
            (lint-rule-cons
              (lint-rule-unreachable-code)
              (lint-rule-cons
                (lint-rule-deprecated-string-concat)
                (lint-rule-cons
                  (lint-rule-nested-str-cat)
                  (lint-rule-cons
                    (lint-rule-cascading-and-or)
                    (lint-rule-cons
                      (lint-rule-unused-import)
                      (lint-rule-cons
                        (lint-rule-dead-code)
                        (lint-rule-cons
                          (lint-rule-unused-assignment)
                          (lint-rule-cons
                            (lint-rule-unused-variable)
                            (lint-rule-cons
                              (lint-rule-unused-unsafe)
                              LintRuleNil)))))))))))))))

(define (lint-rule-find-in [rules : LintRuleList] [rule-id : String]) : LintMaybeRule
  (match rules
    [(LintRuleNil) LintRuleNotFound]
    [(LintRuleCons rule rest)
      (if (string-eq (struct-get rule rule-id) rule-id)
        (LintRuleFound rule)
        (lint-rule-find-in (box-get rest) rule-id))]))

(define (lint-rule-find [rule-id : String]) : LintMaybeRule
  (lint-rule-find-in (lint-rule-registry) rule-id))

;: Rule registry message lookup. Unknown ids return the empty string.
(define (lint-rule-message [rule-id : String]) : String
  (match (lint-rule-find rule-id)
    [(LintRuleFound rule) (struct-get rule message)]
    [(LintRuleNotFound) ""]))

;: Rule registry suggestion lookup. Unknown ids return the empty string.
(define (lint-rule-suggestion [rule-id : String]) : String
  (match (lint-rule-find rule-id)
    [(LintRuleFound rule) (struct-get rule suggestion)]
    [(LintRuleNotFound) ""]))

;: Growable findings buffer. The backing array stores findings in discovery
;: order; the CLI renders from the end to preserve the historical output order.
(defstruct LintFindings
  (slots (Array LintFinding))
  (len i64))

(defenum LintMaybeFinding
  (LintNoFinding)
  (LintSomeFinding LintFinding))

(define (lint-findings-slots [items : LintFindings]) : (Array LintFinding)
  (struct-get items slots))

;: Number of live findings in `items`.
(define (lint-findings-count [items : LintFindings]) : i64
  (struct-get items len))

(define (lint-findings-capacity [items : LintFindings]) : i64
  (array-length (lint-findings-slots items)))

(define (lint-findings-with-capacity [capacity : i64]) : LintFindings
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (LintFindings (make-array LintFinding cap) 0)))

(define (lint-findings-empty) : LintFindings
  (lint-findings-with-capacity 4))

(define (lint-findings-copy-range
  [dst : (Array LintFinding)]
  [src : (Array LintFinding)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (lint-findings-copy-range dst src (+ index 1) count))))

(define (lint-findings-grow [items : LintFindings]) : LintFindings
  (let
    [n : i64 (lint-findings-count items)]
    [bigger : (Array LintFinding)
      (make-array LintFinding (* (lint-findings-capacity items) 2))]
    (begin
      (lint-findings-copy-range bigger (lint-findings-slots items) 0 n)
      (LintFindings bigger n))))

;: Append `finding` to the discoveries, growing the backing array as needed.
(define (lint-findings-add [finding : LintFinding] [items : LintFindings]) : LintFindings
  (if (< (lint-findings-count items) (lint-findings-capacity items))
    (let
      [slots : (Array LintFinding) (lint-findings-slots items)]
      [n : i64 (lint-findings-count items)]
      (begin
        (array-set! slots n finding)
        (LintFindings slots (+ n 1))))
    (lint-findings-add finding (lint-findings-grow items))))

(define (lint-findings-ref [items : LintFindings] [index : i64]) : LintFinding
  (array-ref (lint-findings-slots items) index))

(define (lint-findings-get [items : LintFindings] [index : i64]) : LintMaybeFinding
  (if (if (>= index 0)
    (< index (lint-findings-count items))
    false)
    (LintSomeFinding (lint-findings-ref items index))
    (LintNoFinding)))

;: Default nested-`if`-ladder depth threshold (an else-chain of this many `if`s
;: or more is flagged).
(define (lint-default-ladder-threshold) : i64
  3)

;: Length of the `if`/else-`if` ladder headed by `expr`: 0 when `expr` is not an
;: `if`, otherwise 1 + the ladder length of its else-branch. Spans are
;: transparent.
(define (lint-ladder-length [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-ladder-length inner))]
    [(AstExprIf _ _ else-branch-box)
      (let
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (+ 1 (lint-ladder-length else-branch)))]
    [_ 0]))

(define (lint-return-path-chain-length [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-return-path-chain-length inner))]
    [(AstExprIf _ then-branch-box _)
      (let
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        (+ 1 (lint-return-path-chain-length then-branch)))]
    [_ 0]))

(define (lint-unit-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-unit-expr? inner))]
    [(AstExprLiteral AstLitUnit) true]
    [_ false]))

(define (lint-single-arg-call? [args : AstExprList]) : bool
  (match args
    [(AstExprCons _ rest)
      (let
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil) true]
          [_ false]))]
    [_ false]))

(define (lint-not-call? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-not-call? inner))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match func
          [(AstExprVar name)
            (and
              (string-eq (intern-str name) "not")
              (lint-single-arg-call? args))]
          [_ false]))]
    [(AstExprUnary (AstUnNot) _) true]
    [_ false]))

(define (lint-return-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-return-expr? inner))]
    [(AstExprReturn _) true]
    [_ false]))

(define (lint-expr-list-has-return? [exprs : AstExprList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if (lint-return-expr? head)
          true
          (lint-expr-list-has-return? rest)))]))

(define (lint-return-branch? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-return-branch? inner))]
    [(AstExprReturn _) true]
    [(AstExprBegin exprs) (lint-expr-list-has-return? exprs)]
    [_ false]))

(define (lint-side-effect-branch? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-side-effect-branch? inner))]
    [(AstExprSet _ _) true]
    [(AstExprArraySet _ _ _) true]
    [(AstExprArrayPush _ _) true]
    [(AstExprStructSet _ _ _) true]
    [(AstExprBegin exprs) (lint-expr-list-has-side-effect? exprs)]
    [_ false]))

(define (lint-expr-list-has-side-effect? [exprs : AstExprList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if (lint-side-effect-branch? head)
          true
          (lint-expr-list-has-side-effect? rest)))]))

;: Sentinel span for a finding whose AST node carried no source location (a
;: synthesized or in-memory expression). Parsed ladders carry the span from
;: their `AstExprSpanned` wrapper instead.
(define (lint-no-span) : AstSourceSpan
  (AstSourceSpan 0 0 0 0))

;: Build the nested-`if`-ladder finding for a ladder of `depth` arms whose head
;: is at `span`.
(define (lint-ladder-finding [depth : i64] [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-nested-if-ladder-id))
    (lint-rule-nested-if-ladder-id)
    depth
    span))

(define (lint-nested-let-finding [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-nested-let-id))
    (lint-rule-nested-let-id)
    0
    span))

(define (lint-return-path-chain-finding [depth : i64] [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-return-path-chain-id))
    (lint-rule-return-path-chain-id)
    depth
    span))

(define (lint-unit-if-guard-finding [then-unit : bool] [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (if then-unit
      "unit guard if: unit then-branch; prefer when/unless"
      "unit guard if: unit else-branch; prefer when/unless")
    (lint-rule-unit-if-guard-id)
    1
    span))

(define (lint-no-effect-finding [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-no-effect-id))
    (lint-rule-no-effect-id)
    0
    span))

(define (lint-unreachable-code-finding [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-unreachable-code-id))
    (lint-rule-unreachable-code-id)
    0
    span))

(define (lint-dead-code-finding [name : String] [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (string-append
      "dead code: private top-level declaration "
      (string-append name " is never referenced"))
    (lint-rule-dead-code-id)
    0
    span))

(define (lint-unused-assignment-finding [name : String] [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (string-append
      "unused assignment: value assigned to "
      (string-append name " is overwritten before it is read"))
    (lint-rule-unused-assignment-id)
    0
    span))

(define (lint-unused-variable-finding [name : String] [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (string-append "unused variable: " (string-append name " is never used"))
    (lint-rule-unused-variable-id)
    0
    span))

(define (lint-unused-unsafe-finding [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-unused-unsafe-id))
    (lint-rule-unused-unsafe-id)
    0
    span))

(define (lint-no-effect-span [expr : AstExpr]) : AstSourceSpan
  (match expr
    [(AstExprSpanned _ span) span]
    [_ (lint-no-span)]))

(define (lint-terminal-callee? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-terminal-callee? inner))]
    [(AstExprVar name)
      (let
        [text : String (intern-str name)]
        (or (string-eq text "panic") (string-eq text "error")))]
    [_ false]))

(define (lint-terminal-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(AstExprReturn _) true]
    [(AstExprCall func-box _)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lint-terminal-callee? func))]
    [_ false]))

(define (lint-no-effect-pure-binop? [op : AstBinOp]) : bool
  (match op
    ;; These operators can intentionally trap, so keep the syntactic rule
    ;; conservative until typed/effect metadata can prove safety.
    [(AstBinDiv) false]
    [(AstBinMod) false]
    [(AstBinShl) false]
    [(AstBinShr) false]
    [_ true]))

(define (lint-no-effect-pure-literal? [lit : AstLiteral]) : bool
  (match lit
    [(AstLitUnit) false]
    [_ true]))

(define (lint-no-effect-pure-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(AstExprLiteral lit) (lint-no-effect-pure-literal? lit)]
    [(AstExprVar _) true]
    [(AstExprTypeLiteral _) true]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (and
          (lint-no-effect-pure-binop? op)
          (lint-no-effect-pure-expr? left)
          (lint-no-effect-pure-expr? right)))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(AstExprPtrNull _) true]
    [_ false]))

(define (lint-deprecated-string-concat-name? [name : String]) : bool
  (or
    (string-eq name "string-append")
    (string-eq name "string-concat")
    (string-eq name "string-concat3")
    (string-eq name "string-concat4")
    (string-eq name "string-concat5")))

(define (lint-deprecated-string-concat-loop-form? [name : String]) : bool
  (or
    (string-eq name "while")
    (string-eq name "foreach")
    (string-eq name "spmd-reduce")))

(define (lint-token-name [tok : Token]) : String
  (if (= (token-tag tok) (tag-sym))
    (token-sym tok)
    ""))

(define (lint-deprecated-string-concat-depth [in-loop : bool] [in-chain : bool]) : i64
  (if in-loop
    2
    (if in-chain
      1
      0)))

(define (lint-deprecated-string-concat-finding
  [in-loop : bool]
  [in-chain : bool]
  [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (if in-loop
      "deprecated string concatenation in loop: use text_buf for incremental building"
      (if in-chain
        "deprecated string concatenation chain: use one str-cat call for fixed arity"
        (lint-rule-message (lint-rule-deprecated-string-concat-id))))
    (lint-rule-deprecated-string-concat-id)
    (lint-deprecated-string-concat-depth in-loop in-chain)
    span))

(define (lint-and-or-op-name [name : String]) : String
  (if (or (string-eq name "and") (string-eq name "core/and"))
    "and"
    (if (or (string-eq name "or") (string-eq name "core/or"))
      "or"
      "")))

(define (lint-and-or-func-op [func : AstExpr]) : String
  (match func
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-and-or-func-op inner))]
    [(AstExprVar name) (lint-and-or-op-name (intern-str name))]
    [_ ""]))

(define (lint-str-cat-func? [func : AstExpr]) : bool
  (match func
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-str-cat-func? inner))]
    [(AstExprVar name) (string-eq (intern-str name) "str-cat")]
    [_ false]))

(define (lint-literal-render [lit : AstLiteral]) : String
  (match lit
    [(AstLitInt value) (int->string value)]
    [(AstLitFloat value) value]
    [(AstLitBool value)
      (if value
        "true"
        "false")]
    [(AstLitString value) (string-append "\"" (string-append value "\""))]
    [(AstLitUnit) "unit"]
    [_ "<expr>"]))

(define (lint-bin-op-render [op : AstBinOp]) : String
  (match op
    [(AstBinAdd) "+"]
    [(AstBinSub) "-"]
    [(AstBinMul) "*"]
    [(AstBinDiv) "/"]
    [(AstBinMod) "%"]
    [(AstBinEq) "="]
    [(AstBinNe) "!="]
    [(AstBinLt) "<"]
    [(AstBinLe) "<="]
    [(AstBinGt) ">"]
    [(AstBinGe) ">="]
    [(AstBinAnd) "and"]
    [(AstBinOr) "or"]
    [(AstBinBitAnd) "bit-and"]
    [(AstBinBitOr) "bit-or"]
    [(AstBinBitXor) "bit-xor"]
    [(AstBinShl) "shl"]
    [(AstBinShr) "shr"]))

(define (lint-un-op-render [op : AstUnOp]) : String
  (match op
    [(AstUnNeg) "-"]
    [(AstUnNot) "not"]
    [(AstUnBitNot) "bit-not"]))

(define (lint-render-args-join [head : String] [tail : String]) : String
  (if (string-eq tail "")
    head
    (string-append head (string-append " " tail))))

(define (lint-expr-list-render [exprs : AstExprList]) : String
  (match exprs
    [(AstExprNil) ""]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (lint-render-args-join
          (lint-expr-render head-expr)
          (lint-expr-list-render rest)))]))

(define (lint-parenthesized-call-render [callee : String] [args : String]) : String
  (if (string-eq args "")
    (string-append "(" (string-append callee ")"))
    (string-append
      "("
      (string-append callee (string-append " " (string-append args ")"))))))

(define (lint-expr-render [expr : AstExpr]) : String
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-expr-render inner))]
    [(AstExprVar name) (intern-str name)]
    [(AstExprLiteral lit) (lint-literal-render lit)]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lint-parenthesized-call-render
          (lint-expr-render func)
          (lint-expr-list-render args)))]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (lint-parenthesized-call-render
          (lint-bin-op-render op)
          (lint-render-args-join
            (lint-expr-render left)
            (lint-expr-render right))))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-parenthesized-call-render
          (lint-un-op-render op)
          (lint-expr-render inner)))]
    [_ "<expr>"]))

(define (lint-and-or-call-kind? [op : String] [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-and-or-call-kind? op inner))]
    [(AstExprCall func-box _)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (string-eq (lint-and-or-func-op func) op))]
    [_ false]))

(define (lint-and-or-args-have-kind? [op : String] [args : AstExprList]) : bool
  (match args
    [(AstExprNil) false]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if (lint-and-or-call-kind? op head-expr)
          true
          (lint-and-or-args-have-kind? op rest)))]))

(define (lint-str-cat-call? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-str-cat-call? inner))]
    [(AstExprCall func-box _)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lint-str-cat-func? func))]
    [_ false]))

(define (lint-str-cat-args-have-nested? [args : AstExprList]) : bool
  (match args
    [(AstExprNil) false]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if (lint-str-cat-call? head-expr)
          true
          (lint-str-cat-args-have-nested? rest)))]))

(define (lint-cascading-and-or-flat-arg-render [op : String] [expr : AstExpr]) : String
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-cascading-and-or-flat-arg-render op inner))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (if (string-eq (lint-and-or-func-op func) op)
          (lint-cascading-and-or-flat-args-render op args)
          (lint-expr-render expr)))]
    [_ (lint-expr-render expr)]))

(define (lint-cascading-and-or-flat-args-render
  [op : String]
  [args : AstExprList]) : String
  (match args
    [(AstExprNil) ""]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (lint-render-args-join
          (lint-cascading-and-or-flat-arg-render op head-expr)
          (lint-cascading-and-or-flat-args-render op rest)))]))

(define (lint-cascading-and-or-flat-arg-count [op : String] [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-cascading-and-or-flat-arg-count op inner))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (if (string-eq (lint-and-or-func-op func) op)
          (lint-cascading-and-or-flat-arg-count-list op args)
          1))]
    [_ 1]))

(define (lint-cascading-and-or-flat-arg-count-list
  [op : String]
  [args : AstExprList]) : i64
  (match args
    [(AstExprNil) 0]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (+
          (lint-cascading-and-or-flat-arg-count op head-expr)
          (lint-cascading-and-or-flat-arg-count-list op rest)))]))

(define (lint-cascading-and-or-flat-call
  [callee : String]
  [op : String]
  [args : AstExprList]) : String
  (lint-parenthesized-call-render
    callee
    (lint-cascading-and-or-flat-args-render op args)))

(define (lint-cascading-and-or-finding
  [op : String]
  [callee : String]
  [args : AstExprList]
  [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (string-append
      "cascading "
      (string-append
        op
        (string-append
          ": prefer flat n-ary form "
          (lint-cascading-and-or-flat-call callee op args))))
    (lint-rule-cascading-and-or-id)
    (lint-cascading-and-or-flat-arg-count-list op args)
    span))

(define (lint-nested-str-cat-finding [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-nested-str-cat-message)
    (lint-rule-nested-str-cat-id)
    0
    span))

(define (lint-deprecated-string-concat-token-span
  [tok : SpannedToken]
  [name : String]) : AstSourceSpan
  (AstSourceSpan
    (spanned-token-line tok)
    (spanned-token-col tok)
    (spanned-token-line tok)
    (+ (spanned-token-col tok) (string-length name))))

(define (lint-deprecated-string-concat-scan
  [source : String]
  [acc : LintFindings]) : LintFindings
  (match (lex-spanned-result source)
    [(ErrSpannedTokens _) acc]
    [(OkSpannedTokens toks)
      (let
        [i : i64 0]
        [done : bool false]
        [depth : i64 0]
        [loop-depth : i64 0]
        [concat-depth : i64 0]
        [stack-cap : i64 (+ (string-length source) 2)]
        [loop-stack : (Array bool) (make-array bool stack-cap)]
        [concat-stack : (Array bool) (make-array bool stack-cap)]
        [findings : LintFindings acc]
        (begin
          (while (not done)
            (begin
              (let
                [spanned : SpannedToken (array-ref toks i)]
                [tok : Token (spanned-token-tok spanned)]
                [tag : i64 (token-tag tok)]
                (cond
                  [(= tag (tag-end)) (set! done true)]
                  [(= tag (tag-lparen))
                    (let
                      [head-spanned : SpannedToken (array-ref toks (+ i 1))]
                      [head : Token (spanned-token-tok head-spanned)]
                      [name : String (lint-token-name head)]
                      [is-loop : bool
                        (lint-deprecated-string-concat-loop-form? name)]
                      [is-concat : bool
                        (lint-deprecated-string-concat-name? name)]
                      (begin
                        (set! depth (+ depth 1))
                        (array-set! loop-stack depth is-loop)
                        (array-set! concat-stack depth is-concat)
                        (if is-concat
                          (set!
                            findings
                            (lint-findings-add
                              (lint-deprecated-string-concat-finding
                                (> loop-depth 0)
                                (> concat-depth 0)
                                (lint-deprecated-string-concat-token-span
                                  head-spanned
                                  name))
                              findings))
                          unit)
                        (if is-loop
                          (set! loop-depth (+ loop-depth 1))
                          unit)
                        (if is-concat
                          (set! concat-depth (+ concat-depth 1))
                          unit)))]
                  [(= tag (tag-rparen))
                    (if (> depth 0)
                      (begin
                        (if (array-ref loop-stack depth)
                          (set! loop-depth (- loop-depth 1))
                          unit)
                        (if (array-ref concat-stack depth)
                          (set! concat-depth (- concat-depth 1))
                          unit)
                        (set! depth (- depth 1)))
                      unit)]
                  [else unit]))
              (set! i (+ i 1))))
          findings))]))

(define (lint-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (> prefix-len text-len)
      false
      (let
        [idx : i64 0]
        [ok : bool true]
        (begin
          (while (and ok (< idx prefix-len))
            (if (= (string-ref text idx) (string-ref prefix idx))
              (set! idx (+ idx 1))
              (set! ok false)))
          ok)))))

(define (lint-name-qualified-by-separator?
  [name : String]
  [qualifier : String]
  [separator : char]) : bool
  (let
    [name-len : i64 (string-length name)]
    [qualifier-len : i64 (string-length qualifier)]
    (cond
      [(<= qualifier-len 0) false]
      [(<= name-len qualifier-len) false]
      [(not (lint-string-prefix? name qualifier)) false]
      [else (= (string-ref name qualifier-len) separator)])))

(define (lint-name-qualified-by? [name : String] [qualifier : String]) : bool
  (if (lint-name-qualified-by-separator? name qualifier #.')
    true
    (lint-name-qualified-by-separator? name qualifier #/')))

(define (lint-name-uses-import?
  [name : String]
  [alias : String]
  [module-name : String]) : bool
  (if (lint-name-qualified-by? name alias)
    true
    (lint-name-qualified-by? name module-name)))

(define (lint-name-id-uses-import?
  [name : i64]
  [alias : String]
  [module-name : String]) : bool
  (lint-name-uses-import? (intern-str name) alias module-name))

(define (lint-maybe-type-uses-import?
  [maybe-ty : AstMaybeType]
  [alias : String]
  [module-name : String]) : bool
  (match maybe-ty
    [(AstNoType) false]
    [(AstSomeType ty) (lint-type-uses-import? ty alias module-name)]))

(define (lint-type-list-uses-import?
  [types : AstTypeList]
  [alias : String]
  [module-name : String]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons head rest)
      (let
        [head-ty : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (if (lint-type-uses-import? head-ty alias module-name)
          true
          (lint-type-list-uses-import? rest alias module-name)))]))

(define (lint-type-id-uses-import?
  [ty : i64]
  [alias : String]
  [module-name : String]) : bool
  (lint-type-uses-import? (ty-node-get ty) alias module-name))

(define (lint-type-uses-import?
  [ty : AstType]
  [alias : String]
  [module-name : String]) : bool
  (match ty
    [(AstTyI64) false]
    [(AstTyI32) false]
    [(AstTyI16) false]
    [(AstTyI8) false]
    [(AstTyU64) false]
    [(AstTyU32) false]
    [(AstTyU16) false]
    [(AstTyU8) false]
    [(AstTyF64) false]
    [(AstTyF32) false]
    [(AstTyBool) false]
    [(AstTyChar) false]
    [(AstTyString) false]
    [(AstTyStr) false]
    [(AstTyBytes) false]
    [(AstTyUnit) false]
    [(AstTyNever) false]
    [(AstTyExpr) false]
    [(AstTyExprList) false]
    [(AstTyFunc args ret)
      (if (lint-type-list-uses-import? args alias module-name)
        true
        (lint-type-id-uses-import? ret alias module-name))]
    [(AstTyTuple items) (lint-type-list-uses-import? items alias module-name)]
    [(AstTyArray elem _) (lint-type-id-uses-import? elem alias module-name)]
    [(AstTyDynArray elem) (lint-type-id-uses-import? elem alias module-name)]
    [(AstTyBox elem) (lint-type-id-uses-import? elem alias module-name)]
    [(AstTyRegion _ inner) (lint-type-id-uses-import? inner alias module-name)]
    [(AstTyRef _ inner) (lint-type-id-uses-import? inner alias module-name)]
    [(AstTyMutRef _ inner) (lint-type-id-uses-import? inner alias module-name)]
    [(AstTyEnum name) (lint-name-id-uses-import? name alias module-name)]
    [(AstTyEnumArgs name _) (lint-name-id-uses-import? name alias module-name)]
    [(AstTyStruct name) (lint-name-id-uses-import? name alias module-name)]
    [(AstTyStructArgs name _)
      (lint-name-id-uses-import? name alias module-name)]
    [(AstTyVar name) (lint-name-id-uses-import? name alias module-name)]
    [(AstTyVarArgs name _) (lint-name-id-uses-import? name alias module-name)]
    [(AstTyPtr inner) (lint-type-id-uses-import? inner alias module-name)]
    [(AstTyMutPtr inner) (lint-type-id-uses-import? inner alias module-name)]))

(define (lint-param-list-uses-import?
  [params : AstParamList]
  [alias : String]
  [module-name : String]) : bool
  (match params
    [(AstParamNil) false]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam _ ty _)
            (if (lint-type-uses-import? ty alias module-name)
              true
              (lint-param-list-uses-import? rest alias module-name))]))]))

(define (lint-macro-param-list-uses-import?
  [params : AstMacroParamList]
  [alias : String]
  [module-name : String]) : bool
  (match params
    [(AstMacroParamNil) false]
    [(AstMacroParamCons param rest)
      (let
        [rest : AstMacroParamList (box-get rest)]
        (match param
          [(AstMacroParam _ ty _)
            (if (lint-type-uses-import? ty alias module-name)
              true
              (lint-macro-param-list-uses-import? rest alias module-name))]))]))

(define (lint-pattern-list-uses-import?
  [patterns : AstPatternList]
  [alias : String]
  [module-name : String]) : bool
  (match patterns
    [(AstPatternNil) false]
    [(AstPatternCons head rest)
      (let
        [head : AstPattern (box-get head)]
        [rest : AstPatternList (box-get rest)]
        (if (lint-pattern-uses-import? head alias module-name)
          true
          (lint-pattern-list-uses-import? rest alias module-name)))]))

(define (lint-pattern-uses-import?
  [pattern : AstPattern]
  [alias : String]
  [module-name : String]) : bool
  (match pattern
    [(AstPatVar _ maybe-ty)
      (lint-maybe-type-uses-import? maybe-ty alias module-name)]
    [(AstPatTuple items)
      (lint-pattern-list-uses-import? (box-get items) alias module-name)]
    [(AstPatWildcard) false]
    [(AstPatBinding _) false]
    [(AstPatVariant name items)
      (if (lint-name-id-uses-import? name alias module-name)
        true
        (lint-pattern-list-uses-import? (box-get items) alias module-name))]
    [(AstPatLiteral _) false]))

(define (lint-unused-unsafe-candidate-sentinel?
  [alias : String]
  [module-name : String]) : bool
  (and
    (string-eq alias "__tl_lint_unused_unsafe_candidate")
    (string-eq module-name "")))

(define (lint-requires-enclosing-unsafe-sentinel?
  [alias : String]
  [module-name : String]) : bool
  (and
    (string-eq alias "__tl_lint_requires_enclosing_unsafe")
    (string-eq module-name "")))

(define (lint-expr-list-requires-enclosing-unsafe? [exprs : AstExprList]) : bool
  (lint-expr-list-uses-import? exprs "__tl_lint_requires_enclosing_unsafe" ""))

(define (lint-expr-list-uses-import?
  [exprs : AstExprList]
  [alias : String]
  [module-name : String]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if (lint-expr-uses-import? head alias module-name)
          true
          (lint-expr-list-uses-import? rest alias module-name)))]))

(define (lint-let-bindings-use-import?
  [bindings : AstLetBindingList]
  [alias : String]
  [module-name : String]) : bool
  (match bindings
    [(AstLetBindingNil) false]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding _ maybe-ty init)
            (if (lint-maybe-type-uses-import? maybe-ty alias module-name)
              true
              (if (lint-expr-uses-import? (ast-node-get init) alias module-name)
                true
                (lint-let-bindings-use-import? rest alias module-name)))]))]))

(define (lint-match-arms-use-import?
  [arms : AstMatchArmList]
  [alias : String]
  [module-name : String]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body)
            (if (lint-pattern-uses-import? pattern alias module-name)
              true
              (if (lint-expr-uses-import? (ast-node-get body) alias module-name)
                true
                (lint-match-arms-use-import? rest alias module-name)))]))]))

(define (lint-resource-bindings-use-import?
  [bindings : AstResourceBindingList]
  [alias : String]
  [module-name : String]) : bool
  (match bindings
    [(AstResourceBindingNil) false]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding _ init cleanup)
            (if (lint-expr-uses-import? (ast-node-get init) alias module-name)
              true
              (if (lint-expr-uses-import?
                (ast-node-get cleanup)
                alias
                module-name)
                true
                (lint-resource-bindings-use-import? rest alias module-name)))]))]))

(define (lint-expr-uses-import?
  [expr : AstExpr]
  [alias : String]
  [module-name : String]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (lint-expr-uses-import? (ast-node-get inner-box) alias module-name)]
    [(AstExprLiteral _) false]
    [(AstExprVar name) (lint-name-id-uses-import? name alias module-name)]
    [(AstExprBinary _ left right)
      (if (lint-expr-uses-import? (ast-node-get left) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get right) alias module-name))]
    [(AstExprUnary _ inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprCall func args)
      (if (lint-expr-uses-import? (ast-node-get func) alias module-name)
        true
        (lint-expr-list-uses-import? args alias module-name))]
    [(AstExprIf cond then-branch else-branch)
      (if (lint-expr-uses-import? (ast-node-get cond) alias module-name)
        true
        (if (lint-expr-uses-import?
          (ast-node-get then-branch)
          alias
          module-name)
          true
          (lint-expr-uses-import? (ast-node-get else-branch) alias module-name)))]
    [(AstExprLet bindings body)
      (if (lint-let-bindings-use-import? bindings alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get body) alias module-name))]
    [(AstExprLambda params ret body)
      (if (lint-param-list-uses-import? params alias module-name)
        true
        (if (lint-maybe-type-uses-import? ret alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get body) alias module-name)))]
    [(AstExprTuple exprs) (lint-expr-list-uses-import? exprs alias module-name)]
    [(AstExprTupleRef tuple _)
      (lint-expr-uses-import? (ast-node-get tuple) alias module-name)]
    [(AstExprArray exprs) (lint-expr-list-uses-import? exprs alias module-name)]
    [(AstExprMakeArray elem len)
      (if (lint-type-uses-import? elem alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get len) alias module-name))]
    [(AstExprArrayRef array index)
      (if (lint-expr-uses-import? (ast-node-get array) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get index) alias module-name))]
    [(AstExprArraySet array index value)
      (if (lint-expr-uses-import? (ast-node-get array) alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get index) alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get value) alias module-name)))]
    [(AstExprArrayPush array value)
      (if (lint-expr-uses-import? (ast-node-get array) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get value) alias module-name))]
    [(AstExprStringRef text index)
      (if (lint-expr-uses-import? (ast-node-get text) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get index) alias module-name))]
    [(AstExprWhile cond body)
      (if (lint-expr-uses-import? (ast-node-get cond) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get body) alias module-name))]
    [(AstExprBegin exprs) (lint-expr-list-uses-import? exprs alias module-name)]
    [(AstExprUnsafe exprs)
      (cond
        [(lint-requires-enclosing-unsafe-sentinel? alias module-name) false]
        [(lint-unused-unsafe-candidate-sentinel? alias module-name)
          (if (lint-expr-list-requires-enclosing-unsafe? exprs)
            (lint-expr-list-uses-import? exprs alias module-name)
            true)]
        [else (lint-expr-list-uses-import? exprs alias module-name)])]
    [(AstExprSet target value)
      (if (lint-name-id-uses-import? target alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get value) alias module-name))]
    [(AstExprAnn inner ty)
      (if (lint-expr-uses-import? (ast-node-get inner) alias module-name)
        true
        (lint-type-uses-import? ty alias module-name))]
    [(AstExprCast inner ty)
      (if (lint-expr-uses-import? (ast-node-get inner) alias module-name)
        true
        (lint-type-uses-import? ty alias module-name))]
    [(AstExprBorrow _ _ place)
      (lint-expr-uses-import? (ast-node-get place) alias module-name)]
    [(AstExprMatch scrutinee arms)
      (if (lint-expr-uses-import? (ast-node-get scrutinee) alias module-name)
        true
        (lint-match-arms-use-import? arms alias module-name))]
    [(AstExprForeach _ index-ty start end body)
      (cond
        [(lint-type-uses-import? index-ty alias module-name) true]
        [(lint-expr-uses-import? (ast-node-get start) alias module-name) true]
        [(lint-expr-uses-import? (ast-node-get end) alias module-name) true]
        [else (lint-expr-uses-import? (ast-node-get body) alias module-name)])]
    [(AstExprSpmdReduce _ _ index-ty start end init value)
      (cond
        [(lint-type-uses-import? index-ty alias module-name) true]
        [(lint-expr-uses-import? (ast-node-get start) alias module-name) true]
        [(lint-expr-uses-import? (ast-node-get end) alias module-name) true]
        [(lint-expr-uses-import? (ast-node-get init) alias module-name) true]
        [else (lint-expr-uses-import? (ast-node-get value) alias module-name)])]
    [(AstExprSpmdBroadcast value lane)
      (if (lint-expr-uses-import? (ast-node-get value) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get lane) alias module-name))]
    [(AstExprStructGet receiver _)
      (lint-expr-uses-import? (ast-node-get receiver) alias module-name)]
    [(AstExprStructSet receiver _ value)
      (if (lint-expr-uses-import? (ast-node-get receiver) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get value) alias module-name))]
    [(AstExprWithRegion _ body)
      (lint-expr-list-uses-import? body alias module-name)]
    [(AstExprWithEscape scratch body)
      (if (lint-expr-uses-import? (ast-node-get scratch) alias module-name)
        true
        (lint-expr-list-uses-import? body alias module-name))]
    [(AstExprWithScratch body)
      (lint-expr-list-uses-import? body alias module-name)]
    [(AstExprInArena arena body)
      (if (lint-expr-uses-import? (ast-node-get arena) alias module-name)
        true
        (lint-expr-list-uses-import? body alias module-name))]
    [(AstExprWithResource bindings body)
      (if (lint-resource-bindings-use-import? bindings alias module-name)
        true
        (lint-expr-list-uses-import? body alias module-name))]
    [(AstExprBox inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprBoxGet inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprBoxTake inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprBoxSet inner value)
      (if (lint-expr-uses-import? (ast-node-get inner) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get value) alias module-name))]
    [(AstExprTypeLiteral ty) (lint-type-uses-import? ty alias module-name)]
    [(AstExprInit maybe-ty)
      (lint-maybe-type-uses-import? maybe-ty alias module-name)]
    [(AstExprComptime inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprQuote inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprQuasiquote inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprUnquote inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprUnquoteSplicing inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprBracketClause items)
      (lint-expr-list-uses-import? items alias module-name)]
    [(AstExprTry inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprReturn inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprPtrNull ty) (lint-type-uses-import? ty alias module-name)]
    [(AstExprPtrNullCheck inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExprPtrAddrOf place)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get place) alias module-name))]
    [(AstExprPtrRead ptr)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get ptr) alias module-name))]
    [(AstExprPtrWrite ptr value)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get ptr) alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get value) alias module-name)))]
    [(AstExprPtrOffset ptr offset)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get ptr) alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get offset) alias module-name)))]
    [(AstExprPtrCast ptr ty)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get ptr) alias module-name)
          true
          (lint-type-uses-import? ty alias module-name)))]
    [(AstExprPtrToInt ptr)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get ptr) alias module-name))]
    [(AstExprIntToPtr value ty)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get value) alias module-name)
          true
          (lint-type-uses-import? ty alias module-name)))]
    [(AstExprStringData inner)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get inner) alias module-name))]
    [(AstExprStringFromBytes ptr len)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get ptr) alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get len) alias module-name)))]
    [(AstExprArrayData inner)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get inner) alias module-name))]
    [(AstExprBinaryData _) false]
    [(AstExprProgramArgc) false]
    [(AstExprProgramArgv) false]
    [(AstExprProgramEnvp) false]
    [(AstExprCpuIdEax leaf subleaf)
      (if (lint-expr-uses-import? (ast-node-get leaf) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get subleaf) alias module-name))]
    [(AstExprCpuIdEbx leaf subleaf)
      (if (lint-expr-uses-import? (ast-node-get leaf) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get subleaf) alias module-name))]
    [(AstExprCpuIdEcx leaf subleaf)
      (if (lint-expr-uses-import? (ast-node-get leaf) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get subleaf) alias module-name))]
    [(AstExprCpuIdEdx leaf subleaf)
      (if (lint-expr-uses-import? (ast-node-get leaf) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get subleaf) alias module-name))]
    [(AstExprXgetbv index)
      (lint-expr-uses-import? (ast-node-get index) alias module-name)]
    [(AstExprSyscall args)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-list-uses-import? args alias module-name))]))

(define (lint-extern-abi-uses-import?
  [abi : AstExternAbi]
  [alias : String]
  [module-name : String]) : bool
  (match abi
    [(AstExternAbiC) false]
    [(AstExternAbiCVarargsOpen) false]
    [(AstExternAbiCVarargsTyped tail-ty)
      (lint-type-uses-import? tail-ty alias module-name)]))

(define (lint-extern-metadata-uses-import?
  [meta : AstExternMetadata]
  [alias : String]
  [module-name : String]) : bool
  (match meta
    [(AstExternMetadata abi _ _ _)
      (lint-extern-abi-uses-import? abi alias module-name)]))

(define (lint-field-cleanup-uses-import?
  [cleanup : AstFieldCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(AstFieldNoCleanup) false]
    [(AstFieldCleanupFn name)
      (lint-name-id-uses-import? name alias module-name)]
    [(AstFieldOwnedCleanup) false]))

(define (lint-field-def-list-uses-import?
  [fields : AstFieldDefList]
  [alias : String]
  [module-name : String]) : bool
  (match fields
    [(AstFieldDefNil) false]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ ty cleanup)
            (if (lint-type-uses-import? ty alias module-name)
              true
              (if (lint-field-cleanup-uses-import? cleanup alias module-name)
                true
                (lint-field-def-list-uses-import? rest alias module-name)))]))]))

(define (lint-struct-cleanup-uses-import?
  [cleanup : AstStructCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(AstStructNoCleanup) false]
    [(AstStructCleanupFn name)
      (lint-name-id-uses-import? name alias module-name)]))

(define (lint-enum-cleanup-uses-import?
  [cleanup : AstEnumCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(AstEnumNoCleanup) false]
    [(AstEnumCleanupFn name) (lint-name-id-uses-import? name alias module-name)]))

(define (lint-variant-payload-cleanup-uses-import?
  [cleanup : AstVariantPayloadCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(AstVariantPayloadNoCleanup) false]
    [(AstVariantPayloadCleanupFn name)
      (lint-name-id-uses-import? name alias module-name)]
    [(AstVariantPayloadOwnedCleanup) false]))

(define (lint-variant-payload-cleanup-list-uses-import?
  [items : AstVariantPayloadCleanupList]
  [alias : String]
  [module-name : String]) : bool
  (match items
    [(AstVariantPayloadCleanupNil) false]
    [(AstVariantPayloadCleanupCons cleanup rest)
      (let
        [rest : AstVariantPayloadCleanupList (box-get rest)]
        (if (lint-variant-payload-cleanup-uses-import?
          cleanup
          alias
          module-name)
          true
          (lint-variant-payload-cleanup-list-uses-import?
            rest
            alias
            module-name)))]))

(define (lint-variant-def-list-uses-import?
  [variants : AstVariantDefList]
  [alias : String]
  [module-name : String]) : bool
  (match variants
    [(AstVariantDefNil) false]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef _ payloads cleanups)
            (if (lint-type-list-uses-import? payloads alias module-name)
              true
              (if (lint-variant-payload-cleanup-list-uses-import?
                cleanups
                alias
                module-name)
                true
                (lint-variant-def-list-uses-import? rest alias module-name)))]))]))

(define (lint-dispatch-variant-list-uses-import?
  [variants : AstDispatchVariantList]
  [alias : String]
  [module-name : String]) : bool
  (match variants
    [(AstDispatchVariantNil) false]
    [(AstDispatchVariantCons variant rest)
      (let
        [rest : AstDispatchVariantList (box-get rest)]
        (match variant
          [(AstDispatchVariant _ name)
            (if (lint-name-uses-import? name alias module-name)
              true
              (lint-dispatch-variant-list-uses-import? rest alias module-name))]))]))

(define (lint-export-item-uses-import?
  [item : AstExportItem]
  [alias : String]
  [module-name : String]) : bool
  (match item
    [(AstExportValue name) (lint-name-uses-import? name alias module-name)]
    [(AstExportType name) (lint-name-uses-import? name alias module-name)]
    [(AstExportMacro name) (lint-name-uses-import? name alias module-name)]
    [(AstExportConstructor name)
      (lint-name-uses-import? name alias module-name)]
    [(AstExportField type-name field-name)
      (if (lint-name-uses-import? type-name alias module-name)
        true
        (lint-name-uses-import? field-name alias module-name))]
    [(AstExportVariant name) (lint-name-uses-import? name alias module-name)]))

(define (lint-export-item-list-uses-import?
  [items : AstExportItemList]
  [alias : String]
  [module-name : String]) : bool
  (match items
    [(AstExportItemNil) false]
    [(AstExportItemCons item rest)
      (let
        [rest : AstExportItemList (box-get rest)]
        (if (lint-export-item-uses-import? item alias module-name)
          true
          (lint-export-item-list-uses-import? rest alias module-name)))]))

(define (lint-generated-decl-meta-uses-import?
  [meta : AstGeneratedDeclMeta]
  [alias : String]
  [module-name : String]) : bool
  (match meta
    [(AstNoGeneratedDeclMeta) false]
    [(AstSomeGeneratedDeclMeta _ _ args _)
      (lint-expr-list-uses-import? args alias module-name)]))

(define (lint-decl-uses-import?
  [decl : AstDecl]
  [alias : String]
  [module-name : String]) : bool
  (match decl
    [(AstDeclModule _) false]
    [(AstDeclDef _ maybe-ty body)
      (if (lint-maybe-type-uses-import? maybe-ty alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get body) alias module-name))]
    [(AstDeclDefFn _ params ret body _)
      (if (lint-param-list-uses-import? params alias module-name)
        true
        (if (lint-type-uses-import? ret alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get body) alias module-name)))]
    [(AstDeclDefMacro _ params ret body)
      (if (lint-macro-param-list-uses-import? params alias module-name)
        true
        (if (lint-type-uses-import? ret alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get body) alias module-name)))]
    [(AstDeclExtern _ _ meta ty)
      (if (lint-extern-metadata-uses-import? meta alias module-name)
        true
        (lint-type-uses-import? ty alias module-name))]
    [(AstDeclDefEnum _ cleanup variants)
      (if (lint-enum-cleanup-uses-import? cleanup alias module-name)
        true
        (lint-variant-def-list-uses-import? variants alias module-name))]
    [(AstDeclDefEnumLifetimes _ _ cleanup variants)
      (if (lint-enum-cleanup-uses-import? cleanup alias module-name)
        true
        (lint-variant-def-list-uses-import? variants alias module-name))]
    [(AstDeclDefStruct _ _ cleanup fields)
      (if (lint-struct-cleanup-uses-import? cleanup alias module-name)
        true
        (lint-field-def-list-uses-import? fields alias module-name))]
    [(AstDeclDefStructLifetimes _ _ _ cleanup fields)
      (if (lint-struct-cleanup-uses-import? cleanup alias module-name)
        true
        (lint-field-def-list-uses-import? fields alias module-name))]
    [(AstDeclImport (AstImportSpec (AstImportMacro call-expr) _ _ _ _))
      (lint-expr-uses-import? (ast-node-get call-expr) alias module-name)]
    [(AstDeclImport (AstImportSpec (AstImportMacroDecls call-expr) _ _ _ _))
      (lint-expr-uses-import? (ast-node-get call-expr) alias module-name)]
    [(AstDeclImport _) false]
    [(AstDeclIncludeStr _ _) false]
    [(AstDeclIncludeBin _ _) false]
    [(AstDeclExport items)
      (lint-export-item-list-uses-import? items alias module-name)]
    [(AstDeclDefDispatch _ variants)
      (lint-dispatch-variant-list-uses-import? variants alias module-name)]
    [(AstDeclTest _ body _)
      (lint-expr-uses-import? (ast-node-get body) alias module-name)]
    [(AstDeclUnsafe inner)
      (lint-decl-uses-import? (box-get inner) alias module-name)]
    [(AstDeclComptimeDecl meta inner)
      (if (lint-generated-decl-meta-uses-import? meta alias module-name)
        true
        (lint-decl-uses-import? (box-get inner) alias module-name))]))

(define (lint-decl-list-uses-import?
  [decls : AstDeclList]
  [alias : String]
  [module-name : String]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (if (lint-decl-uses-import? decl alias module-name)
          true
          (lint-decl-list-uses-import? rest alias module-name)))]))

(define (lint-program-has-unused-unsafe-candidate? [program : AstProgram]) : bool
  (match program
    [(AstProgram decls-box)
      (lint-decl-list-uses-import?
        (box-get decls-box)
        "__tl_lint_unused_unsafe_candidate"
        "")]))

(define (lint-underscore-prefixed? [name : String]) : bool
  (let
    [n : i64 (string-length name)]
    (if (<= n 0)
      false
      (= (string-ref name 0) #_'))))

(define (lint-import-kind-lintable?
  [kind : AstImportKind]
  [expected : AstMaybeModuleName]) : bool
  (match kind
    [(AstImportModule) true]
    ;; Legacy path imports with no explicit module alias still bring
    ;; unqualified names into scope, so skip them until #2453/#2454 remove that
    ;; transitional surface.
    [(AstImportPath)
      (match expected
        [(AstSomeModuleName _) true]
        [(AstNoModuleName) false])]
    [(AstImportMacro _) false]
    [(AstImportMacroDecls _) false]))

(define (lint-unused-import-finding
  [module-name : String]
  [alias : String]
  [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (string-append
      "unused import: module alias "
      (string-append
        alias
        (string-append
          " from "
          (string-append module-name " is never referenced"))))
    (lint-rule-unused-import-id)
    0
    span))

(define (lint-unused-import-add-if-needed
  [all-decls : AstDeclList]
  [spec : AstImportSpec]
  [acc : LintFindings]) : LintFindings
  (match spec
    [(AstImportSpec kind _ expected maybe-alias span)
      (if (not (lint-import-kind-lintable? kind expected))
        acc
        (match expected
          [(AstNoModuleName) acc]
          [(AstSomeModuleName module-name)
            (match maybe-alias
              [(AstNoImportAlias) acc]
              [(AstSomeImportAlias alias)
                (if (lint-underscore-prefixed? alias)
                  acc
                  (if (lint-decl-list-uses-import? all-decls alias module-name)
                    acc
                    (lint-findings-add
                      (lint-unused-import-finding module-name alias span)
                      acc)))])]))]))

(define (lint-unused-imports-in-decl-list
  [all-decls : AstDeclList]
  [decls : AstDeclList]
  [acc : LintFindings]) : LintFindings
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (lint-unused-imports-in-decl-list
          all-decls
          rest
          (match decl
            [(AstDeclImport spec)
              (lint-unused-import-add-if-needed all-decls spec acc)]
            [_ acc])))]))

(defenum LintNameList
  (LintNameNil)
  (LintNameCons String (Box LintNameList)))

(defstruct LintPendingAssignment
  (name String)
  (span AstSourceSpan))

(defenum LintPendingAssignmentList
  (LintPendingAssignmentNil)
  (LintPendingAssignmentCons
    LintPendingAssignment
    (Box LintPendingAssignmentList)))

(defenum LintMaybePendingAssignment
  (LintNoPendingAssignment)
  (LintSomePendingAssignment LintPendingAssignment))

(defstruct LintUnusedAssignmentState
  (locals LintNameList)
  (pending LintPendingAssignmentList)
  (findings LintFindings))

(define (lint-name-list-contains? [items : LintNameList] [name : String]) : bool
  (match items
    [(LintNameNil) false]
    [(LintNameCons head rest)
      (if (string-eq head name)
        true
        (lint-name-list-contains? (box-get rest) name))]))

(define (lint-name-list-add [items : LintNameList] [name : String]) : LintNameList
  (if (lint-name-list-contains? items name)
    items
    (LintNameCons name (box items))))

(define (lint-param-list-add-locals
  [params : AstParamList]
  [locals : LintNameList]) : LintNameList
  (match params
    [(AstParamNil) locals]
    [(AstParamCons param rest)
      (match param
        [(AstParam name _ _)
          (lint-param-list-add-locals
            (box-get rest)
            (lint-name-list-add locals (intern-str name)))])]))

(define (lint-macro-param-list-add-locals
  [params : AstMacroParamList]
  [locals : LintNameList]) : LintNameList
  (match params
    [(AstMacroParamNil) locals]
    [(AstMacroParamCons param rest)
      (match param
        [(AstMacroParam name _ _)
          (lint-macro-param-list-add-locals
            (box-get rest)
            (lint-name-list-add locals (intern-str name)))])]))

(define (lint-pending-assignment-find
  [items : LintPendingAssignmentList]
  [name : String]) : LintMaybePendingAssignment
  (match items
    [(LintPendingAssignmentNil) LintNoPendingAssignment]
    [(LintPendingAssignmentCons item rest)
      (if (string-eq (struct-get item name) name)
        (LintSomePendingAssignment item)
        (lint-pending-assignment-find (box-get rest) name))]))

(define (lint-pending-assignment-remove
  [items : LintPendingAssignmentList]
  [name : String]) : LintPendingAssignmentList
  (match items
    [(LintPendingAssignmentNil) LintPendingAssignmentNil]
    [(LintPendingAssignmentCons item rest)
      (let
        [rest-items : LintPendingAssignmentList (box-get rest)]
        (if (string-eq (struct-get item name) name)
          (lint-pending-assignment-remove rest-items name)
          (LintPendingAssignmentCons
            item
            (box (lint-pending-assignment-remove rest-items name)))))]))

(define (lint-pending-assignment-add
  [items : LintPendingAssignmentList]
  [name : String]
  [span : AstSourceSpan]) : LintPendingAssignmentList
  (LintPendingAssignmentCons
    (LintPendingAssignment name span)
    (box (lint-pending-assignment-remove items name))))

(define (lint-unused-assignment-state-with
  [state : LintUnusedAssignmentState]
  [pending : LintPendingAssignmentList]
  [findings : LintFindings]) : LintUnusedAssignmentState
  (LintUnusedAssignmentState (struct-get state locals) pending findings))

(define (lint-unused-assignment-read-name
  [state : LintUnusedAssignmentState]
  [name : String]) : LintUnusedAssignmentState
  (lint-unused-assignment-state-with
    state
    (lint-pending-assignment-remove (struct-get state pending) name)
    (struct-get state findings)))

(define (lint-unused-assignment-read-id
  [state : LintUnusedAssignmentState]
  [name : i64]) : LintUnusedAssignmentState
  (lint-unused-assignment-read-name state (intern-str name)))

(define (lint-unused-assignment-write-name
  [state : LintUnusedAssignmentState]
  [name : String]
  [span : AstSourceSpan]) : LintUnusedAssignmentState
  (if (not (lint-name-list-contains? (struct-get state locals) name))
    state
    (if (lint-underscore-prefixed? name)
      state
      (let
        [found : LintMaybePendingAssignment
          (lint-pending-assignment-find (struct-get state pending) name)]
        [next-findings : LintFindings
          (match found
            [(LintNoPendingAssignment) (struct-get state findings)]
            [(LintSomePendingAssignment pending)
              (lint-findings-add
                (lint-unused-assignment-finding name (struct-get pending span))
                (struct-get state findings))])]
        (lint-unused-assignment-state-with
          state
          (lint-pending-assignment-add (struct-get state pending) name span)
          next-findings)))))

(define (lint-unused-assignment-write-id
  [state : LintUnusedAssignmentState]
  [name : i64]
  [span : AstSourceSpan]) : LintUnusedAssignmentState
  (lint-unused-assignment-write-name state (intern-str name) span))

(define (lint-unused-assignment-clear-pending
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (lint-unused-assignment-state-with
    state
    LintPendingAssignmentNil
    (struct-get state findings)))

(define (lint-unused-assignment-with-locals
  [state : LintUnusedAssignmentState]
  [locals : LintNameList]) : LintUnusedAssignmentState
  (LintUnusedAssignmentState
    locals
    (struct-get state pending)
    (struct-get state findings)))

(define (lint-unused-assignment-note-reads-list
  [exprs : AstExprList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match exprs
    [(AstExprNil) state]
    [(AstExprCons head rest)
      (lint-unused-assignment-note-reads-list
        (box-get rest)
        (lint-unused-assignment-note-reads (ast-node-get head) state))]))

(define (lint-unused-assignment-note-reads-let-bindings
  [bindings : AstLetBindingList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match bindings
    [(AstLetBindingNil) state]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding _ _ init)
          (lint-unused-assignment-note-reads-let-bindings
            (box-get rest)
            (lint-unused-assignment-note-reads (ast-node-get init) state))])]))

(define (lint-unused-assignment-note-reads-match-arms
  [arms : AstMatchArmList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match arms
    [(AstMatchArmNil) state]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm _ body)
          (lint-unused-assignment-note-reads-match-arms
            (box-get rest)
            (lint-unused-assignment-note-reads (ast-node-get body) state))])]))

(define (lint-unused-assignment-note-reads-resource-bindings
  [bindings : AstResourceBindingList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match bindings
    [(AstResourceBindingNil) state]
    [(AstResourceBindingCons binding rest)
      (match binding
        [(AstResourceBinding _ init cleanup)
          (lint-unused-assignment-note-reads-resource-bindings
            (box-get rest)
            (lint-unused-assignment-note-reads
              (ast-node-get cleanup)
              (lint-unused-assignment-note-reads (ast-node-get init) state)))])]))

(define (lint-unused-assignment-note-reads
  [expr : AstExpr]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match expr
    [(AstExprSpanned inner-box _)
      (lint-unused-assignment-note-reads (ast-node-get inner-box) state)]
    [(AstExprLiteral _) state]
    [(AstExprVar name) (lint-unused-assignment-read-id state name)]
    [(AstExprBinary _ left right)
      (lint-unused-assignment-note-reads
        (ast-node-get right)
        (lint-unused-assignment-note-reads (ast-node-get left) state))]
    [(AstExprUnary _ inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprCall func args)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads-list
          args
          (lint-unused-assignment-note-reads (ast-node-get func) state)))]
    [(AstExprIf cond then-branch else-branch)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast-node-get else-branch)
          (lint-unused-assignment-note-reads
            (ast-node-get then-branch)
            (lint-unused-assignment-note-reads (ast-node-get cond) state))))]
    [(AstExprLet bindings body)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast-node-get body)
          (lint-unused-assignment-note-reads-let-bindings bindings state)))]
    [(AstExprLambda _ _ body)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads (ast-node-get body) state))]
    [(AstExprTuple exprs) (lint-unused-assignment-note-reads-list exprs state)]
    [(AstExprTupleRef tuple _)
      (lint-unused-assignment-note-reads (ast-node-get tuple) state)]
    [(AstExprArray exprs) (lint-unused-assignment-note-reads-list exprs state)]
    [(AstExprMakeArray _ len)
      (lint-unused-assignment-note-reads (ast-node-get len) state)]
    [(AstExprArrayRef array index)
      (lint-unused-assignment-note-reads
        (ast-node-get index)
        (lint-unused-assignment-note-reads (ast-node-get array) state))]
    [(AstExprArraySet array index value)
      (lint-unused-assignment-note-reads
        (ast-node-get value)
        (lint-unused-assignment-note-reads
          (ast-node-get index)
          (lint-unused-assignment-note-reads (ast-node-get array) state)))]
    [(AstExprArrayPush array value)
      (lint-unused-assignment-note-reads
        (ast-node-get value)
        (lint-unused-assignment-note-reads (ast-node-get array) state))]
    [(AstExprStringRef text index)
      (lint-unused-assignment-note-reads
        (ast-node-get index)
        (lint-unused-assignment-note-reads (ast-node-get text) state))]
    [(AstExprWhile cond body)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast-node-get body)
          (lint-unused-assignment-note-reads (ast-node-get cond) state)))]
    [(AstExprBegin exprs) (lint-unused-assignment-note-reads-list exprs state)]
    [(AstExprUnsafe exprs) (lint-unused-assignment-note-reads-list exprs state)]
    [(AstExprSet _ value)
      (lint-unused-assignment-note-reads (ast-node-get value) state)]
    [(AstExprAnn inner _)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprCast inner _)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprBorrow _ _ place)
      (lint-unused-assignment-note-reads (ast-node-get place) state)]
    [(AstExprMatch scrutinee arms)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads-match-arms
          arms
          (lint-unused-assignment-note-reads (ast-node-get scrutinee) state)))]
    [(AstExprForeach _ _ start end body)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast-node-get body)
          (lint-unused-assignment-note-reads
            (ast-node-get end)
            (lint-unused-assignment-note-reads (ast-node-get start) state))))]
    [(AstExprSpmdReduce _ _ _ start end init value)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast-node-get value)
          (lint-unused-assignment-note-reads
            (ast-node-get init)
            (lint-unused-assignment-note-reads
              (ast-node-get end)
              (lint-unused-assignment-note-reads (ast-node-get start) state)))))]
    [(AstExprSpmdBroadcast value lane)
      (lint-unused-assignment-note-reads
        (ast-node-get lane)
        (lint-unused-assignment-note-reads (ast-node-get value) state))]
    [(AstExprStructGet receiver _)
      (lint-unused-assignment-note-reads (ast-node-get receiver) state)]
    [(AstExprStructSet receiver _ value)
      (lint-unused-assignment-note-reads
        (ast-node-get value)
        (lint-unused-assignment-note-reads (ast-node-get receiver) state))]
    [(AstExprWithRegion _ body)
      (lint-unused-assignment-note-reads-list body state)]
    [(AstExprWithEscape scratch body)
      (lint-unused-assignment-note-reads-list
        body
        (lint-unused-assignment-note-reads (ast-node-get scratch) state))]
    [(AstExprWithScratch body)
      (lint-unused-assignment-note-reads-list body state)]
    [(AstExprInArena arena body)
      (lint-unused-assignment-note-reads-list
        body
        (lint-unused-assignment-note-reads (ast-node-get arena) state))]
    [(AstExprWithResource bindings body)
      (lint-unused-assignment-note-reads-list
        body
        (lint-unused-assignment-note-reads-resource-bindings bindings state))]
    [(AstExprBox inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprBoxGet inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprBoxTake inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprBoxSet inner value)
      (lint-unused-assignment-note-reads
        (ast-node-get value)
        (lint-unused-assignment-note-reads (ast-node-get inner) state))]
    [(AstExprTypeLiteral _) state]
    [(AstExprInit _) state]
    [(AstExprComptime inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprQuote _) state]
    [(AstExprQuasiquote _) state]
    [(AstExprUnquote inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprUnquoteSplicing inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprBracketClause items)
      (lint-unused-assignment-note-reads-list items state)]
    [(AstExprTry inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprReturn inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprPtrNull _) state]
    [(AstExprPtrNullCheck inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprPtrAddrOf place)
      (lint-unused-assignment-note-reads (ast-node-get place) state)]
    [(AstExprPtrRead ptr)
      (lint-unused-assignment-note-reads (ast-node-get ptr) state)]
    [(AstExprPtrWrite ptr value)
      (lint-unused-assignment-note-reads
        (ast-node-get value)
        (lint-unused-assignment-note-reads (ast-node-get ptr) state))]
    [(AstExprPtrOffset ptr offset)
      (lint-unused-assignment-note-reads
        (ast-node-get offset)
        (lint-unused-assignment-note-reads (ast-node-get ptr) state))]
    [(AstExprPtrCast ptr _)
      (lint-unused-assignment-note-reads (ast-node-get ptr) state)]
    [(AstExprPtrToInt ptr)
      (lint-unused-assignment-note-reads (ast-node-get ptr) state)]
    [(AstExprIntToPtr value _)
      (lint-unused-assignment-note-reads (ast-node-get value) state)]
    [(AstExprStringData inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprStringFromBytes ptr len)
      (lint-unused-assignment-note-reads
        (ast-node-get len)
        (lint-unused-assignment-note-reads (ast-node-get ptr) state))]
    [(AstExprArrayData inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExprBinaryData _) state]
    [(AstExprProgramArgc) state]
    [(AstExprProgramArgv) state]
    [(AstExprProgramEnvp) state]
    [(AstExprCpuIdEax leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast-node-get leaf) state))]
    [(AstExprCpuIdEbx leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast-node-get leaf) state))]
    [(AstExprCpuIdEcx leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast-node-get leaf) state))]
    [(AstExprCpuIdEdx leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast-node-get leaf) state))]
    [(AstExprXgetbv index)
      (lint-unused-assignment-note-reads (ast-node-get index) state)]
    [(AstExprSyscall args) (lint-unused-assignment-note-reads-list args state)]))

(define (lint-unused-assignment-binding-span [init : i64]) : AstSourceSpan
  (lint-no-effect-span (ast-node-get init)))

(define (lint-unused-assignment-expr-list
  [exprs : AstExprList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (lint-unused-assignment-expr-list-after-terminal exprs state false))

(define (lint-unused-assignment-expr-list-after-terminal
  [exprs : AstExprList]
  [state : LintUnusedAssignmentState]
  [after-terminal : bool]) : LintUnusedAssignmentState
  (match exprs
    [(AstExprNil) state]
    [(AstExprCons head rest)
      (if after-terminal
        state
        (let
          [head-expr : AstExpr (ast-node-get head)]
          (lint-unused-assignment-expr-list-after-terminal
            (box-get rest)
            (lint-unused-assignment-expr head-expr state (lint-no-span))
            (lint-terminal-expr? head-expr))))]))

(define (lint-unused-assignment-let-bindings
  [bindings : AstLetBindingList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match bindings
    [(AstLetBindingNil) state]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name _ init)
          (let
            [after-init : LintUnusedAssignmentState
              (lint-unused-assignment-expr
                (ast-node-get init)
                state
                (lint-unused-assignment-binding-span init))]
            [text : String (intern-str name)]
            [binding-base : LintUnusedAssignmentState
              (if (lint-name-list-contains? (struct-get after-init locals) text)
                (lint-unused-assignment-state-with
                  after-init
                  (lint-pending-assignment-remove
                    (struct-get after-init pending)
                    text)
                  (struct-get after-init findings))
                after-init)]
            [with-local : LintUnusedAssignmentState
              (lint-unused-assignment-with-locals
                binding-base
                (lint-name-list-add (struct-get binding-base locals) text))]
            (lint-unused-assignment-let-bindings
              (box-get rest)
              (lint-unused-assignment-write-name
                with-local
                text
                (lint-unused-assignment-binding-span init))))])]))

(define (lint-unused-assignment-let
  [bindings : AstLetBindingList]
  [body : AstExpr]
  [state : LintUnusedAssignmentState]
  [span : AstSourceSpan]) : LintUnusedAssignmentState
  (let
    [inner : LintUnusedAssignmentState
      (lint-unused-assignment-expr
        body
        (lint-unused-assignment-let-bindings bindings state)
        span)]
    (LintUnusedAssignmentState
      (struct-get state locals)
      LintPendingAssignmentNil
      (struct-get inner findings))))

(define (lint-unused-assignment-expr
  [expr : AstExpr]
  [state : LintUnusedAssignmentState]
  [span : AstSourceSpan]) : LintUnusedAssignmentState
  (match expr
    [(AstExprSpanned inner-box inner-span)
      (lint-unused-assignment-expr (ast-node-get inner-box) state inner-span)]
    [(AstExprLet bindings body)
      (lint-unused-assignment-let bindings (ast-node-get body) state span)]
    [(AstExprBegin exprs) (lint-unused-assignment-expr-list exprs state)]
    [(AstExprUnsafe exprs) (lint-unused-assignment-expr-list exprs state)]
    [(AstExprWithRegion _ body) (lint-unused-assignment-expr-list body state)]
    [(AstExprWithScratch body) (lint-unused-assignment-expr-list body state)]
    [(AstExprWithEscape scratch body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads (ast-node-get scratch) state))]
    [(AstExprInArena arena body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads (ast-node-get arena) state))]
    [(AstExprWithResource bindings body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads-resource-bindings bindings state))]
    [(AstExprSet target value)
      (lint-unused-assignment-write-id
        (lint-unused-assignment-note-reads (ast-node-get value) state)
        target
        span)]
    [_ (lint-unused-assignment-note-reads expr state)]))

(define (lint-unused-assignment-state-empty
  [locals : LintNameList]
  [acc : LintFindings]) : LintUnusedAssignmentState
  (LintUnusedAssignmentState locals LintPendingAssignmentNil acc))

(define (lint-unused-assignments-in-decl [decl : AstDecl] [acc : LintFindings]) : LintFindings
  (match decl
    [(AstDeclDef _ _ body)
      (struct-get
        (lint-unused-assignment-expr
          (ast-node-get body)
          (lint-unused-assignment-state-empty LintNameNil acc)
          (lint-no-span))
        findings)]
    [(AstDeclDefFn _ params _ body _)
      (struct-get
        (lint-unused-assignment-expr
          (ast-node-get body)
          (lint-unused-assignment-state-empty
            (lint-param-list-add-locals params LintNameNil)
            acc)
          (lint-no-span))
        findings)]
    [(AstDeclDefMacro _ params _ body)
      (struct-get
        (lint-unused-assignment-expr
          (ast-node-get body)
          (lint-unused-assignment-state-empty
            (lint-macro-param-list-add-locals params LintNameNil)
            acc)
          (lint-no-span))
        findings)]
    [(AstDeclTest _ body _)
      (struct-get
        (lint-unused-assignment-expr
          (ast-node-get body)
          (lint-unused-assignment-state-empty LintNameNil acc)
          (lint-no-span))
        findings)]
    [(AstDeclUnsafe inner)
      (lint-unused-assignments-in-decl (box-get inner) acc)]
    [(AstDeclComptimeDecl _ inner)
      (lint-unused-assignments-in-decl (box-get inner) acc)]
    [_ acc]))

(define (lint-unused-assignments-in-decl-list
  [decls : AstDeclList]
  [acc : LintFindings]) : LintFindings
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (lint-unused-assignments-in-decl-list
        (box-get rest)
        (lint-unused-assignments-in-decl decl acc))]))

(defstruct LintSourceNameSpan
  (span AstSourceSpan)
  (next-index i64))

(defstruct LintUnusedVariableBinding
  (name String)
  (span AstSourceSpan)
  (used bool)
  (reportable bool))

(defenum LintUnusedVariableBindingList
  (LintUnusedVariableBindingNil)
  (LintUnusedVariableBindingCons
    LintUnusedVariableBinding
    (Box LintUnusedVariableBindingList)))

(defenum LintUnusedVariableFrameList
  (LintUnusedVariableFrameNil)
  (LintUnusedVariableFrameCons
    LintUnusedVariableBindingList
    (Box LintUnusedVariableFrameList)))

(defstruct LintUnusedVariableMarkBindingsResult
  (bindings LintUnusedVariableBindingList)
  (found bool))

(defstruct LintUnusedVariableMarkFramesResult
  (frames LintUnusedVariableFrameList)
  (found bool))

(defstruct LintUnusedVariableBindingBuild
  (bindings LintUnusedVariableBindingList)
  (next-index i64))

(defstruct LintUnusedVariableState
  (source String)
  (frames LintUnusedVariableFrameList)
  (findings LintFindings))

(define (lint-source-prefix-at?
  [source : String]
  [start : i64]
  [needle : String]) : bool
  (let
    [source-len : i64 (string-length source)]
    [needle-len : i64 (string-length needle)]
    (if (< start 0)
      false
      (if (> (+ start needle-len) source-len)
        false
        (let
          [ok : bool true]
          [idx : i64 0]
          (begin
            (while (and ok (< idx needle-len))
              (if (= (string-ref source (+ start idx)) (string-ref needle idx))
                (set! idx (+ idx 1))
                (set! ok false)))
            ok))))))

(define (lint-source-find-prefix-from
  [source : String]
  [needle : String]
  [idx : i64]) : i64
  (let
    [source-len : i64 (string-length source)]
    [found : i64 (- 0 1)]
    [i : i64 idx]
    (begin
      (while (and (< found 0) (< i source-len))
        (if (lint-source-prefix-at? source i needle)
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (lint-source-symbol-boundary? [source : String] [idx : i64]) : bool
  (let
    [source-len : i64 (string-length source)]
    (if (< idx 0)
      true
      (if (>= idx source-len)
        true
        (not (is-symbol-char (string-ref source idx)))))))

(define (lint-source-name-at? [source : String] [idx : i64] [name : String]) : bool
  (let
    [end : i64 (+ idx (string-length name))]
    (and
      (lint-source-prefix-at? source idx name)
      (lint-source-symbol-boundary? source (- idx 1))
      (lint-source-symbol-boundary? source end))))

(define (lint-source-find-name-from
  [source : String]
  [name : String]
  [idx : i64]) : i64
  (let
    [source-len : i64 (string-length source)]
    [found : i64 (- 0 1)]
    [i : i64 idx]
    (begin
      (while (and (< found 0) (< i source-len))
        (if (lint-source-name-at? source i name)
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (lint-source-index-line [source : String] [target : i64]) : i64
  (let
    [i : i64 0]
    [line : i64 1]
    (begin
      (while (< i target)
        (begin
          (if (= (string-ref source i) #\newline')
            (set! line (+ line 1))
            unit)
          (set! i (+ i 1))))
      line)))

(define (lint-source-index-col [source : String] [target : i64]) : i64
  (let
    [i : i64 0]
    [col : i64 1]
    (begin
      (while (< i target)
        (begin
          (if (= (string-ref source i) #\newline')
            (set! col 1)
            (set! col (+ col 1)))
          (set! i (+ i 1))))
      col)))

(define (lint-source-index-span
  [source : String]
  [idx : i64]
  [width : i64]
  [fallback : AstSourceSpan]) : AstSourceSpan
  (if (< idx 0)
    fallback
    (let
      [line : i64 (lint-source-index-line source idx)]
      [col : i64 (lint-source-index-col source idx)]
      (AstSourceSpan line col line (+ col width)))))

(define (lint-source-span-start-index [source : String] [span : AstSourceSpan]) : i64
  (let
    [target-line : i64 (struct-get span start-line)]
    [target-col : i64 (struct-get span start-col)]
    [source-len : i64 (string-length source)]
    [idx : i64 0]
    [line : i64 1]
    [col : i64 1]
    [found : i64 (- 0 1)]
    (begin
      (if (or (<= target-line 0) (<= target-col 0))
        (set! found (- 0 1))
        (while (and (< found 0) (< idx source-len))
          (if (and (= line target-line) (= col target-col))
            (set! found idx)
            (begin
              (if (= (string-ref source idx) #\newline')
                (begin
                  (set! line (+ line 1))
                  (set! col 1))
                (set! col (+ col 1)))
              (set! idx (+ idx 1))))))
      found)))

(define (lint-source-name-span-from
  [source : String]
  [name : String]
  [cursor : i64]
  [fallback : AstSourceSpan]) : LintSourceNameSpan
  (let
    [found : i64 (lint-source-find-name-from source name cursor)]
    [width : i64 (string-length name)]
    (if (< found 0)
      (LintSourceNameSpan fallback cursor)
      (LintSourceNameSpan
        (lint-source-index-span source found width fallback)
        (+ found width)))))

(define (lint-unused-variable-binding
  [name : String]
  [span : AstSourceSpan]
  [reportable : bool]) : LintUnusedVariableBinding
  (LintUnusedVariableBinding name span false reportable))

(define (lint-unused-variable-binding-cons
  [head : LintUnusedVariableBinding]
  [rest : LintUnusedVariableBindingList]) : LintUnusedVariableBindingList
  (LintUnusedVariableBindingCons head (box rest)))

(define (lint-unused-variable-state-with
  [state : LintUnusedVariableState]
  [frames : LintUnusedVariableFrameList]
  [findings : LintFindings]) : LintUnusedVariableState
  (LintUnusedVariableState (struct-get state source) frames findings))

(define (lint-unused-variable-binding-mark-used
  [binding : LintUnusedVariableBinding]) : LintUnusedVariableBinding
  (LintUnusedVariableBinding
    (struct-get binding name)
    (struct-get binding span)
    true
    (struct-get binding reportable)))

(define (lint-unused-variable-mark-bindings
  [bindings : LintUnusedVariableBindingList]
  [name : String]) : LintUnusedVariableMarkBindingsResult
  (match bindings
    [(LintUnusedVariableBindingNil)
      (LintUnusedVariableMarkBindingsResult LintUnusedVariableBindingNil false)]
    [(LintUnusedVariableBindingCons binding rest)
      (if (string-eq (struct-get binding name) name)
        (LintUnusedVariableMarkBindingsResult
          (lint-unused-variable-binding-cons
            (lint-unused-variable-binding-mark-used binding)
            (box-get rest))
          true)
        (let
          [marked : LintUnusedVariableMarkBindingsResult
            (lint-unused-variable-mark-bindings (box-get rest) name)]
          (LintUnusedVariableMarkBindingsResult
            (lint-unused-variable-binding-cons
              binding
              (struct-get marked bindings))
            (struct-get marked found))))]))

(define (lint-unused-variable-mark-frames
  [frames : LintUnusedVariableFrameList]
  [name : String]) : LintUnusedVariableMarkFramesResult
  (match frames
    [(LintUnusedVariableFrameNil)
      (LintUnusedVariableMarkFramesResult LintUnusedVariableFrameNil false)]
    [(LintUnusedVariableFrameCons bindings rest)
      (let
        [marked-bindings : LintUnusedVariableMarkBindingsResult
          (lint-unused-variable-mark-bindings bindings name)]
        (if (struct-get marked-bindings found)
          (LintUnusedVariableMarkFramesResult
            (LintUnusedVariableFrameCons
              (struct-get marked-bindings bindings)
              rest)
            true)
          (let
            [marked-rest : LintUnusedVariableMarkFramesResult
              (lint-unused-variable-mark-frames (box-get rest) name)]
            (LintUnusedVariableMarkFramesResult
              (LintUnusedVariableFrameCons
                bindings
                (box (struct-get marked-rest frames)))
              (struct-get marked-rest found)))))]))

(define (lint-unused-variable-read-name
  [state : LintUnusedVariableState]
  [name : String]) : LintUnusedVariableState
  (let
    [marked : LintUnusedVariableMarkFramesResult
      (lint-unused-variable-mark-frames (struct-get state frames) name)]
    (if (struct-get marked found)
      (lint-unused-variable-state-with
        state
        (struct-get marked frames)
        (struct-get state findings))
      state)))

(define (lint-unused-variable-read-id
  [state : LintUnusedVariableState]
  [name : i64]) : LintUnusedVariableState
  (lint-unused-variable-read-name state (intern-str name)))

(define (lint-unused-variable-first-dot-index [text : String]) : i64
  (let
    [n : i64 (string-length text)]
    [idx : i64 0]
    [found : i64 (- 0 1)]
    (begin
      (while (and (< found 0) (< idx n))
        (if (= (string-ref text idx) #.')
          (set! found idx)
          (set! idx (+ idx 1))))
      found)))

(define (lint-unused-variable-read-var-name
  [state : LintUnusedVariableState]
  [name : String]) : LintUnusedVariableState
  (let
    [with-full : LintUnusedVariableState
      (lint-unused-variable-read-name state name)]
    [dot : i64 (lint-unused-variable-first-dot-index name)]
    (if (> dot 0)
      (lint-unused-variable-read-name with-full (substring name 0 dot))
      with-full)))

(define (lint-unused-variable-read-var-id
  [state : LintUnusedVariableState]
  [name : i64]) : LintUnusedVariableState
  (lint-unused-variable-read-var-name state (intern-str name)))

(define (lint-unused-variable-add-to-current-frame
  [state : LintUnusedVariableState]
  [binding : LintUnusedVariableBinding]) : LintUnusedVariableState
  (match (struct-get state frames)
    [(LintUnusedVariableFrameNil)
      (lint-unused-variable-state-with
        state
        (LintUnusedVariableFrameCons
          (lint-unused-variable-binding-cons
            binding
            LintUnusedVariableBindingNil)
          (box LintUnusedVariableFrameNil))
        (struct-get state findings))]
    [(LintUnusedVariableFrameCons bindings rest)
      (lint-unused-variable-state-with
        state
        (LintUnusedVariableFrameCons
          (lint-unused-variable-binding-cons binding bindings)
          rest)
        (struct-get state findings))]))

(define (lint-unused-variable-push-frame
  [state : LintUnusedVariableState]
  [bindings : LintUnusedVariableBindingList]) : LintUnusedVariableState
  (lint-unused-variable-state-with
    state
    (LintUnusedVariableFrameCons bindings (box (struct-get state frames)))
    (struct-get state findings)))

(define (lint-unused-variable-report-bindings
  [bindings : LintUnusedVariableBindingList]
  [findings : LintFindings]) : LintFindings
  (match bindings
    [(LintUnusedVariableBindingNil) findings]
    [(LintUnusedVariableBindingCons binding rest)
      (let
        [next : LintFindings
          (if (and
            (struct-get binding reportable)
            (not (struct-get binding used))
            (not (lint-underscore-prefixed? (struct-get binding name))))
            (lint-findings-add
              (lint-unused-variable-finding
                (struct-get binding name)
                (struct-get binding span))
              findings)
            findings)]
        (lint-unused-variable-report-bindings (box-get rest) next))]))

(define (lint-unused-variable-pop-frame [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match (struct-get state frames)
    [(LintUnusedVariableFrameNil) state]
    [(LintUnusedVariableFrameCons bindings rest)
      (lint-unused-variable-state-with
        state
        (box-get rest)
        (lint-unused-variable-report-bindings
          bindings
          (struct-get state findings)))]))

(define (lint-unused-variable-param-bindings
  [params : AstParamList]
  [source : String]
  [cursor : i64]
  [fallback : AstSourceSpan]
  [reportable : bool]) : LintUnusedVariableBindingBuild
  (match params
    [(AstParamNil)
      (LintUnusedVariableBindingBuild LintUnusedVariableBindingNil cursor)]
    [(AstParamCons param rest)
      (match param
        [(AstParam name _ _)
          (let
            [text : String (intern-str name)]
            [found : LintSourceNameSpan
              (lint-source-name-span-from source text cursor fallback)]
            [tail : LintUnusedVariableBindingBuild
              (lint-unused-variable-param-bindings
                (box-get rest)
                source
                (struct-get found next-index)
                fallback
                reportable)]
            (LintUnusedVariableBindingBuild
              (lint-unused-variable-binding-cons
                (lint-unused-variable-binding
                  text
                  (struct-get found span)
                  reportable)
                (struct-get tail bindings))
              (struct-get tail next-index)))])]))

(define (lint-unused-variable-macro-param-bindings
  [params : AstMacroParamList]
  [source : String]
  [cursor : i64]
  [fallback : AstSourceSpan]
  [reportable : bool]) : LintUnusedVariableBindingBuild
  (match params
    [(AstMacroParamNil)
      (LintUnusedVariableBindingBuild LintUnusedVariableBindingNil cursor)]
    [(AstMacroParamCons param rest)
      (match param
        [(AstMacroParam name _ _)
          (let
            [text : String (intern-str name)]
            [found : LintSourceNameSpan
              (lint-source-name-span-from source text cursor fallback)]
            [tail : LintUnusedVariableBindingBuild
              (lint-unused-variable-macro-param-bindings
                (box-get rest)
                source
                (struct-get found next-index)
                fallback
                reportable)]
            (LintUnusedVariableBindingBuild
              (lint-unused-variable-binding-cons
                (lint-unused-variable-binding
                  text
                  (struct-get found span)
                  reportable)
                (struct-get tail bindings))
              (struct-get tail next-index)))])]))

(define (lint-unused-variable-pattern-list-bindings
  [patterns : AstPatternList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match patterns
    [(AstPatternNil) state]
    [(AstPatternCons head rest)
      (lint-unused-variable-pattern-list-bindings
        (box-get rest)
        (lint-unused-variable-pattern-bindings (box-get head) state))]))

(define (lint-unused-variable-type-list
  [items : AstTypeList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match items
    [(AstTypeNil) state]
    [(AstTypeCons id rest)
      (lint-unused-variable-type-list
        (box-get rest)
        (lint-unused-variable-type (ty-node-get id) state))]))

(define (lint-unused-variable-lifetime-list
  [items : AstLifetimeList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match items
    [(AstLifetimeNil) state]
    [(AstLifetimeCons name rest)
      (lint-unused-variable-lifetime-list
        (box-get rest)
        (lint-unused-variable-read-name state name))]))

(define (lint-unused-variable-type-lifetime
  [name : String]
  [inner : i64]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-type
    (ty-node-get inner)
    (lint-unused-variable-read-name state name)))

(define (lint-unused-variable-type
  [ty : AstType]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match ty
    [(AstTyFunc args ret)
      (lint-unused-variable-type
        (ty-node-get ret)
        (lint-unused-variable-type-list args state))]
    [(AstTyTuple items) (lint-unused-variable-type-list items state)]
    [(AstTyArray elem _) (lint-unused-variable-type (ty-node-get elem) state)]
    [(AstTyDynArray elem) (lint-unused-variable-type (ty-node-get elem) state)]
    [(AstTyBox elem) (lint-unused-variable-type (ty-node-get elem) state)]
    [(AstTyRegion name inner)
      (lint-unused-variable-type-lifetime name inner state)]
    [(AstTyRef name inner)
      (lint-unused-variable-type-lifetime name inner state)]
    [(AstTyMutRef name inner)
      (lint-unused-variable-type-lifetime name inner state)]
    [(AstTyEnumArgs _ lifetimes)
      (lint-unused-variable-lifetime-list lifetimes state)]
    [(AstTyStructArgs _ lifetimes)
      (lint-unused-variable-lifetime-list lifetimes state)]
    [(AstTyVar name) (lint-unused-variable-read-id state name)]
    [(AstTyVarArgs name lifetimes)
      (lint-unused-variable-lifetime-list
        lifetimes
        (lint-unused-variable-read-id state name))]
    [(AstTyPtr elem) (lint-unused-variable-type (ty-node-get elem) state)]
    [(AstTyMutPtr elem) (lint-unused-variable-type (ty-node-get elem) state)]
    [_ state]))

(define (lint-unused-variable-maybe-type
  [maybe-ty : AstMaybeType]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match maybe-ty
    [(AstNoType) state]
    [(AstSomeType ty) (lint-unused-variable-type ty state)]))

(define (lint-unused-variable-param-types
  [params : AstParamList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match params
    [(AstParamNil) state]
    [(AstParamCons param rest)
      (match param
        [(AstParam _ ty _)
          (lint-unused-variable-param-types
            (box-get rest)
            (lint-unused-variable-type ty state))])]))

(define (lint-unused-variable-macro-param-types
  [params : AstMacroParamList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match params
    [(AstMacroParamNil) state]
    [(AstMacroParamCons param rest)
      (match param
        [(AstMacroParam _ ty _)
          (lint-unused-variable-macro-param-types
            (box-get rest)
            (lint-unused-variable-type ty state))])]))

(define (lint-unused-variable-borrow-lifetime
  [lifetime : AstBorrowLifetime]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match lifetime
    [(AstBorrowLifetimeInferred) state]
    [(AstBorrowLifetimeNamed name) (lint-unused-variable-read-name state name)]))

(define (lint-unused-variable-pattern-bindings
  [pattern : AstPattern]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match pattern
    [(AstPatVar name maybe-ty)
      (lint-unused-variable-add-to-current-frame
        (lint-unused-variable-maybe-type maybe-ty state)
        (lint-unused-variable-binding (intern-str name) (lint-no-span) false))]
    [(AstPatTuple items)
      (lint-unused-variable-pattern-list-bindings (box-get items) state)]
    [(AstPatWildcard) state]
    [(AstPatBinding name)
      (lint-unused-variable-add-to-current-frame
        state
        (lint-unused-variable-binding (intern-str name) (lint-no-span) false))]
    [(AstPatVariant _ items)
      (lint-unused-variable-pattern-list-bindings (box-get items) state)]
    [(AstPatLiteral _) state]))

(define (lint-unused-variable-expr-list
  [exprs : AstExprList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match exprs
    [(AstExprNil) state]
    [(AstExprCons head rest)
      (lint-unused-variable-expr-list
        (box-get rest)
        (lint-unused-variable-expr (ast-node-get head) state (lint-no-span)))]))

(define (lint-unused-variable-quasiquote-expr-list
  [exprs : AstExprList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match exprs
    [(AstExprNil) state]
    [(AstExprCons head rest)
      (lint-unused-variable-quasiquote-expr-list
        (box-get rest)
        (lint-unused-variable-quasiquote-expr (ast-node-get head) state))]))

(define (lint-unused-variable-quasiquote-let-bindings
  [bindings : AstLetBindingList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match bindings
    [(AstLetBindingNil) state]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding _ _ init)
          (lint-unused-variable-quasiquote-let-bindings
            (box-get rest)
            (lint-unused-variable-quasiquote-expr (ast-node-get init) state))])]))

(define (lint-unused-variable-quasiquote-match-arms
  [arms : AstMatchArmList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match arms
    [(AstMatchArmNil) state]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm _ body)
          (lint-unused-variable-quasiquote-match-arms
            (box-get rest)
            (lint-unused-variable-quasiquote-expr (ast-node-get body) state))])]))

(define (lint-unused-variable-quasiquote-resource-bindings
  [bindings : AstResourceBindingList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match bindings
    [(AstResourceBindingNil) state]
    [(AstResourceBindingCons binding rest)
      (match binding
        [(AstResourceBinding _ init cleanup)
          (lint-unused-variable-quasiquote-resource-bindings
            (box-get rest)
            (lint-unused-variable-quasiquote-expr
              (ast-node-get cleanup)
              (lint-unused-variable-quasiquote-expr (ast-node-get init) state)))])]))

(define (lint-unused-variable-quasiquote-expr
  [expr : AstExpr]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match expr
    [(AstExprSpanned inner-box _)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner-box) state)]
    [(AstExprUnquote inner)
      (lint-unused-variable-expr
        (ast-node-get inner)
        state
        (lint-no-effect-span (ast-node-get inner)))]
    [(AstExprUnquoteSplicing inner)
      (lint-unused-variable-expr
        (ast-node-get inner)
        state
        (lint-no-effect-span (ast-node-get inner)))]
    [(AstExprBinary _ left right)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get right)
        (lint-unused-variable-quasiquote-expr (ast-node-get left) state))]
    [(AstExprUnary _ inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprCall func args)
      (lint-unused-variable-quasiquote-expr-list
        args
        (lint-unused-variable-quasiquote-expr (ast-node-get func) state))]
    [(AstExprIf cond then-branch else-branch)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get else-branch)
        (lint-unused-variable-quasiquote-expr
          (ast-node-get then-branch)
          (lint-unused-variable-quasiquote-expr (ast-node-get cond) state)))]
    [(AstExprLet bindings body)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get body)
        (lint-unused-variable-quasiquote-let-bindings bindings state))]
    [(AstExprLambda _ _ body)
      (lint-unused-variable-quasiquote-expr (ast-node-get body) state)]
    [(AstExprTuple exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(AstExprTupleRef tuple _)
      (lint-unused-variable-quasiquote-expr (ast-node-get tuple) state)]
    [(AstExprArray exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(AstExprMakeArray _ len)
      (lint-unused-variable-quasiquote-expr (ast-node-get len) state)]
    [(AstExprArrayRef array index)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get index)
        (lint-unused-variable-quasiquote-expr (ast-node-get array) state))]
    [(AstExprArraySet array index value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr
          (ast-node-get index)
          (lint-unused-variable-quasiquote-expr (ast-node-get array) state)))]
    [(AstExprArrayPush array value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast-node-get array) state))]
    [(AstExprStringRef text index)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get index)
        (lint-unused-variable-quasiquote-expr (ast-node-get text) state))]
    [(AstExprWhile cond body)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get body)
        (lint-unused-variable-quasiquote-expr (ast-node-get cond) state))]
    [(AstExprBegin exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(AstExprUnsafe exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(AstExprSet _ value)
      (lint-unused-variable-quasiquote-expr (ast-node-get value) state)]
    [(AstExprAnn inner _)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprCast inner _)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprBorrow _ _ place)
      (lint-unused-variable-quasiquote-expr (ast-node-get place) state)]
    [(AstExprMatch scrutinee arms)
      (lint-unused-variable-quasiquote-match-arms
        arms
        (lint-unused-variable-quasiquote-expr (ast-node-get scrutinee) state))]
    [(AstExprForeach _ _ start end body)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get body)
        (lint-unused-variable-quasiquote-expr
          (ast-node-get end)
          (lint-unused-variable-quasiquote-expr (ast-node-get start) state)))]
    [(AstExprSpmdReduce _ _ _ start end init value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr
          (ast-node-get init)
          (lint-unused-variable-quasiquote-expr
            (ast-node-get end)
            (lint-unused-variable-quasiquote-expr (ast-node-get start) state))))]
    [(AstExprSpmdBroadcast value lane)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get lane)
        (lint-unused-variable-quasiquote-expr (ast-node-get value) state))]
    [(AstExprStructGet receiver _)
      (lint-unused-variable-quasiquote-expr (ast-node-get receiver) state)]
    [(AstExprStructSet receiver _ value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast-node-get receiver) state))]
    [(AstExprWithRegion _ body)
      (lint-unused-variable-quasiquote-expr-list body state)]
    [(AstExprWithEscape scratch body)
      (lint-unused-variable-quasiquote-expr-list
        body
        (lint-unused-variable-quasiquote-expr (ast-node-get scratch) state))]
    [(AstExprWithScratch body)
      (lint-unused-variable-quasiquote-expr-list body state)]
    [(AstExprInArena arena body)
      (lint-unused-variable-quasiquote-expr-list
        body
        (lint-unused-variable-quasiquote-expr (ast-node-get arena) state))]
    [(AstExprWithResource bindings body)
      (lint-unused-variable-quasiquote-expr-list
        body
        (lint-unused-variable-quasiquote-resource-bindings bindings state))]
    [(AstExprBox inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprBoxGet inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprBoxTake inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprBoxSet inner value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast-node-get inner) state))]
    [(AstExprComptime inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprQuasiquote _) state]
    [(AstExprBracketClause items)
      (lint-unused-variable-quasiquote-expr-list items state)]
    [(AstExprTry inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprReturn inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprPtrNullCheck inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprPtrAddrOf place)
      (lint-unused-variable-quasiquote-expr (ast-node-get place) state)]
    [(AstExprPtrRead ptr)
      (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state)]
    [(AstExprPtrWrite ptr value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state))]
    [(AstExprPtrOffset ptr offset)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get offset)
        (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state))]
    [(AstExprPtrCast ptr _)
      (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state)]
    [(AstExprPtrToInt ptr)
      (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state)]
    [(AstExprIntToPtr value _)
      (lint-unused-variable-quasiquote-expr (ast-node-get value) state)]
    [(AstExprStringData inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprStringFromBytes ptr len)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get len)
        (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state))]
    [(AstExprArrayData inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprCpuIdEax leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast-node-get leaf) state))]
    [(AstExprCpuIdEbx leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast-node-get leaf) state))]
    [(AstExprCpuIdEcx leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast-node-get leaf) state))]
    [(AstExprCpuIdEdx leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast-node-get leaf) state))]
    [(AstExprXgetbv index)
      (lint-unused-variable-quasiquote-expr (ast-node-get index) state)]
    [(AstExprSyscall args)
      (lint-unused-variable-quasiquote-expr-list args state)]
    [_ state]))

(define (lint-unused-variable-let-bindings
  [bindings : AstLetBindingList]
  [state : LintUnusedVariableState]
  [cursor : i64]) : LintUnusedVariableState
  (match bindings
    [(AstLetBindingNil) state]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name maybe-ty init)
          (let
            [after-ty : LintUnusedVariableState
              (lint-unused-variable-maybe-type maybe-ty state)]
            [after-init : LintUnusedVariableState
              (lint-unused-variable-expr
                (ast-node-get init)
                after-ty
                (lint-no-effect-span (ast-node-get init)))]
            [text : String (intern-str name)]
            [found : LintSourceNameSpan
              (lint-source-name-span-from
                (struct-get state source)
                text
                cursor
                (lint-no-effect-span (ast-node-get init)))]
            [with-binding : LintUnusedVariableState
              (lint-unused-variable-add-to-current-frame
                after-init
                (lint-unused-variable-binding text (struct-get found span) true))]
            (lint-unused-variable-let-bindings
              (box-get rest)
              with-binding
              (struct-get found next-index)))])]))

(define (lint-unused-variable-let
  [bindings : AstLetBindingList]
  [body : AstExpr]
  [state : LintUnusedVariableState]
  [span : AstSourceSpan]) : LintUnusedVariableState
  (let
    [cursor : i64
      (let
        [start : i64
          (lint-source-span-start-index (struct-get state source) span)]
        (if (< start 0)
          0
          start))]
    [with-frame : LintUnusedVariableState
      (lint-unused-variable-push-frame state LintUnusedVariableBindingNil)]
    [with-bindings : LintUnusedVariableState
      (lint-unused-variable-let-bindings bindings with-frame cursor)]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-bindings span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-resource-bindings
  [bindings : AstResourceBindingList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match bindings
    [(AstResourceBindingNil) state]
    [(AstResourceBindingCons binding rest)
      (match binding
        [(AstResourceBinding name init cleanup)
          (lint-unused-variable-resource-bindings
            (box-get rest)
            (lint-unused-variable-add-to-current-frame
              (lint-unused-variable-expr
                (ast-node-get cleanup)
                (lint-unused-variable-expr
                  (ast-node-get init)
                  state
                  (lint-no-effect-span (ast-node-get init)))
                (lint-no-effect-span (ast-node-get cleanup)))
              (lint-unused-variable-binding
                (intern-str name)
                (lint-no-span)
                false)))])]))

(define (lint-unused-variable-match-arms
  [arms : AstMatchArmList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match arms
    [(AstMatchArmNil) state]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern body)
          (let
            [with-frame : LintUnusedVariableState
              (lint-unused-variable-push-frame
                state
                LintUnusedVariableBindingNil)]
            [with-pattern : LintUnusedVariableState
              (lint-unused-variable-pattern-bindings pattern with-frame)]
            [with-body : LintUnusedVariableState
              (lint-unused-variable-expr
                (ast-node-get body)
                with-pattern
                (lint-no-effect-span (ast-node-get body)))]
            (lint-unused-variable-match-arms
              (box-get rest)
              (lint-unused-variable-pop-frame with-body)))])]))

(define (lint-unused-variable-lambda
  [params : AstParamList]
  [ret : AstMaybeType]
  [body : AstExpr]
  [state : LintUnusedVariableState]
  [span : AstSourceSpan]) : LintUnusedVariableState
  (let
    [start : i64 (lint-source-span-start-index (struct-get state source) span)]
    [cursor : i64
      (if (< start 0)
        0
        (+ start (string-length "(lambda")))]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-param-bindings
        params
        (struct-get state source)
        cursor
        span
        true)]
    [with-frame : LintUnusedVariableState
      (lint-unused-variable-push-frame state (struct-get built bindings))]
    [with-param-types : LintUnusedVariableState
      (lint-unused-variable-maybe-type
        ret
        (lint-unused-variable-param-types params with-frame))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-param-types span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-index-scope
  [name : i64]
  [body : AstExpr]
  [state : LintUnusedVariableState]
  [span : AstSourceSpan]) : LintUnusedVariableState
  (let
    [with-frame : LintUnusedVariableState
      (lint-unused-variable-push-frame
        state
        (lint-unused-variable-binding-cons
          (lint-unused-variable-binding (intern-str name) span false)
          LintUnusedVariableBindingNil))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-frame span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-expr
  [expr : AstExpr]
  [state : LintUnusedVariableState]
  [span : AstSourceSpan]) : LintUnusedVariableState
  (match expr
    [(AstExprSpanned inner-box inner-span)
      (lint-unused-variable-expr (ast-node-get inner-box) state inner-span)]
    [(AstExprLiteral _) state]
    [(AstExprVar name) (lint-unused-variable-read-var-id state name)]
    [(AstExprBinary _ left right)
      (lint-unused-variable-expr
        (ast-node-get right)
        (lint-unused-variable-expr (ast-node-get left) state span)
        span)]
    [(AstExprUnary _ inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprCall func args)
      (lint-unused-variable-expr-list
        args
        (lint-unused-variable-expr (ast-node-get func) state span))]
    [(AstExprIf cond then-branch else-branch)
      (lint-unused-variable-expr
        (ast-node-get else-branch)
        (lint-unused-variable-expr
          (ast-node-get then-branch)
          (lint-unused-variable-expr (ast-node-get cond) state span)
          span)
        span)]
    [(AstExprLet bindings body)
      (lint-unused-variable-let bindings (ast-node-get body) state span)]
    [(AstExprLambda params ret body)
      (lint-unused-variable-lambda params ret (ast-node-get body) state span)]
    [(AstExprTuple exprs) (lint-unused-variable-expr-list exprs state)]
    [(AstExprTupleRef tuple _)
      (lint-unused-variable-expr (ast-node-get tuple) state span)]
    [(AstExprArray exprs) (lint-unused-variable-expr-list exprs state)]
    [(AstExprMakeArray ty len)
      (lint-unused-variable-expr
        (ast-node-get len)
        (lint-unused-variable-type ty state)
        span)]
    [(AstExprArrayRef array index)
      (lint-unused-variable-expr
        (ast-node-get index)
        (lint-unused-variable-expr (ast-node-get array) state span)
        span)]
    [(AstExprArraySet array index value)
      (lint-unused-variable-expr
        (ast-node-get value)
        (lint-unused-variable-expr
          (ast-node-get index)
          (lint-unused-variable-expr (ast-node-get array) state span)
          span)
        span)]
    [(AstExprArrayPush array value)
      (lint-unused-variable-expr
        (ast-node-get value)
        (lint-unused-variable-expr (ast-node-get array) state span)
        span)]
    [(AstExprStringRef text index)
      (lint-unused-variable-expr
        (ast-node-get index)
        (lint-unused-variable-expr (ast-node-get text) state span)
        span)]
    [(AstExprWhile cond body)
      (lint-unused-variable-expr
        (ast-node-get body)
        (lint-unused-variable-expr (ast-node-get cond) state span)
        span)]
    [(AstExprBegin exprs) (lint-unused-variable-expr-list exprs state)]
    [(AstExprUnsafe exprs) (lint-unused-variable-expr-list exprs state)]
    [(AstExprSet _ value)
      (lint-unused-variable-expr (ast-node-get value) state span)]
    [(AstExprAnn inner ty)
      (lint-unused-variable-type
        ty
        (lint-unused-variable-expr (ast-node-get inner) state span))]
    [(AstExprCast inner ty)
      (lint-unused-variable-type
        ty
        (lint-unused-variable-expr (ast-node-get inner) state span))]
    [(AstExprBorrow _ lifetime place)
      (lint-unused-variable-expr
        (ast-node-get place)
        (lint-unused-variable-borrow-lifetime lifetime state)
        span)]
    [(AstExprMatch scrutinee arms)
      (lint-unused-variable-match-arms
        arms
        (lint-unused-variable-expr (ast-node-get scrutinee) state span))]
    [(AstExprForeach index index-ty start end body)
      (lint-unused-variable-index-scope
        index
        (ast-node-get body)
        (lint-unused-variable-type
          index-ty
          (lint-unused-variable-expr
            (ast-node-get end)
            (lint-unused-variable-expr (ast-node-get start) state span)
            span))
        span)]
    [(AstExprSpmdReduce _ index index-ty start end init value)
      (lint-unused-variable-index-scope
        index
        (ast-node-get value)
        (lint-unused-variable-type
          index-ty
          (lint-unused-variable-expr
            (ast-node-get init)
            (lint-unused-variable-expr
              (ast-node-get end)
              (lint-unused-variable-expr (ast-node-get start) state span)
              span)
            span))
        span)]
    [(AstExprSpmdBroadcast value lane)
      (lint-unused-variable-expr
        (ast-node-get lane)
        (lint-unused-variable-expr (ast-node-get value) state span)
        span)]
    [(AstExprStructGet receiver _)
      (lint-unused-variable-expr (ast-node-get receiver) state span)]
    [(AstExprStructSet receiver _ value)
      (lint-unused-variable-expr
        (ast-node-get value)
        (lint-unused-variable-expr (ast-node-get receiver) state span)
        span)]
    [(AstExprWithRegion _ body) (lint-unused-variable-expr-list body state)]
    [(AstExprWithEscape scratch body)
      (lint-unused-variable-expr-list
        body
        (lint-unused-variable-expr (ast-node-get scratch) state span))]
    [(AstExprWithScratch body) (lint-unused-variable-expr-list body state)]
    [(AstExprInArena arena body)
      (lint-unused-variable-expr-list
        body
        (lint-unused-variable-expr (ast-node-get arena) state span))]
    [(AstExprWithResource bindings body)
      (let
        [with-frame : LintUnusedVariableState
          (lint-unused-variable-push-frame state LintUnusedVariableBindingNil)]
        [with-bindings : LintUnusedVariableState
          (lint-unused-variable-resource-bindings bindings with-frame)]
        [with-body : LintUnusedVariableState
          (lint-unused-variable-expr-list body with-bindings)]
        (lint-unused-variable-pop-frame with-body))]
    [(AstExprBox inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprBoxGet inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprBoxTake inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprBoxSet inner value)
      (lint-unused-variable-expr
        (ast-node-get value)
        (lint-unused-variable-expr (ast-node-get inner) state span)
        span)]
    [(AstExprTypeLiteral ty) (lint-unused-variable-type ty state)]
    [(AstExprInit maybe-ty) (lint-unused-variable-maybe-type maybe-ty state)]
    [(AstExprComptime inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprQuote _) state]
    [(AstExprQuasiquote inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExprUnquote inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprUnquoteSplicing inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprBracketClause items) (lint-unused-variable-expr-list items state)]
    [(AstExprTry inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprReturn inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprPtrNull ty) (lint-unused-variable-type ty state)]
    [(AstExprPtrNullCheck inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprPtrAddrOf place)
      (lint-unused-variable-expr (ast-node-get place) state span)]
    [(AstExprPtrRead ptr)
      (lint-unused-variable-expr (ast-node-get ptr) state span)]
    [(AstExprPtrWrite ptr value)
      (lint-unused-variable-expr
        (ast-node-get value)
        (lint-unused-variable-expr (ast-node-get ptr) state span)
        span)]
    [(AstExprPtrOffset ptr offset)
      (lint-unused-variable-expr
        (ast-node-get offset)
        (lint-unused-variable-expr (ast-node-get ptr) state span)
        span)]
    [(AstExprPtrCast ptr ty)
      (lint-unused-variable-type
        ty
        (lint-unused-variable-expr (ast-node-get ptr) state span))]
    [(AstExprPtrToInt ptr)
      (lint-unused-variable-expr (ast-node-get ptr) state span)]
    [(AstExprIntToPtr value ty)
      (lint-unused-variable-type
        ty
        (lint-unused-variable-expr (ast-node-get value) state span))]
    [(AstExprStringData inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprStringFromBytes ptr len)
      (lint-unused-variable-expr
        (ast-node-get len)
        (lint-unused-variable-expr (ast-node-get ptr) state span)
        span)]
    [(AstExprArrayData inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExprBinaryData _) state]
    [(AstExprProgramArgc) state]
    [(AstExprProgramArgv) state]
    [(AstExprProgramEnvp) state]
    [(AstExprCpuIdEax leaf subleaf)
      (lint-unused-variable-expr
        (ast-node-get subleaf)
        (lint-unused-variable-expr (ast-node-get leaf) state span)
        span)]
    [(AstExprCpuIdEbx leaf subleaf)
      (lint-unused-variable-expr
        (ast-node-get subleaf)
        (lint-unused-variable-expr (ast-node-get leaf) state span)
        span)]
    [(AstExprCpuIdEcx leaf subleaf)
      (lint-unused-variable-expr
        (ast-node-get subleaf)
        (lint-unused-variable-expr (ast-node-get leaf) state span)
        span)]
    [(AstExprCpuIdEdx leaf subleaf)
      (lint-unused-variable-expr
        (ast-node-get subleaf)
        (lint-unused-variable-expr (ast-node-get leaf) state span)
        span)]
    [(AstExprXgetbv index)
      (lint-unused-variable-expr (ast-node-get index) state span)]
    [(AstExprSyscall args) (lint-unused-variable-expr-list args state)]))

(define (lint-unused-variable-decl-param-cursor
  [source : String]
  [prefix : String]
  [name : String]
  [fallback : AstSourceSpan]) : i64
  (let
    [needle : String (string-append prefix name)]
    [source-len : i64 (string-length source)]
    [found : i64 (- 0 1)]
    [cursor : i64 0]
    (begin
      (while (and (< found 0) (< cursor source-len))
        (let
          [candidate : i64 (lint-source-find-prefix-from source needle cursor)]
          (if (< candidate 0)
            (set! cursor source-len)
            (let
              [end : i64 (+ candidate (string-length needle))]
              (if (lint-source-symbol-boundary? source end)
                (set! found candidate)
                (set! cursor (+ candidate 1)))))))
      (if (< found 0)
        (let
          [fallback-start : i64 (lint-source-span-start-index source fallback)]
          (if (< fallback-start 0)
            0
            fallback-start))
        (+ found (string-length needle))))))

(define (lint-unused-variable-decl-with-param-frame
  [source : String]
  [prefix : String]
  [name : i64]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [body-span : AstSourceSpan (lint-no-effect-span (ast-node-get body))]
    [cursor : i64
      (lint-unused-variable-decl-param-cursor
        source
        prefix
        (intern-str name)
        body-span)]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-param-bindings params source cursor body-span true)]
    [state : LintUnusedVariableState
      (lint-unused-variable-push-frame
        (LintUnusedVariableState source LintUnusedVariableFrameNil acc)
        (struct-get built bindings))]
    [with-param-types : LintUnusedVariableState
      (lint-unused-variable-type
        ret
        (lint-unused-variable-param-types params state))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr (ast-node-get body) with-param-types body-span)]
    (struct-get (lint-unused-variable-pop-frame with-body) findings)))

(define (lint-unused-variable-decl-with-macro-param-frame
  [source : String]
  [prefix : String]
  [name : i64]
  [params : AstMacroParamList]
  [ret : AstType]
  [body : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [body-span : AstSourceSpan (lint-no-effect-span (ast-node-get body))]
    [cursor : i64
      (lint-unused-variable-decl-param-cursor
        source
        prefix
        (intern-str name)
        body-span)]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-macro-param-bindings
        params
        source
        cursor
        body-span
        true)]
    [state : LintUnusedVariableState
      (lint-unused-variable-push-frame
        (LintUnusedVariableState source LintUnusedVariableFrameNil acc)
        (struct-get built bindings))]
    [with-param-types : LintUnusedVariableState
      (lint-unused-variable-type
        ret
        (lint-unused-variable-macro-param-types params state))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr (ast-node-get body) with-param-types body-span)]
    (struct-get (lint-unused-variable-pop-frame with-body) findings)))

(define (lint-unused-variables-in-decl
  [source : String]
  [decl : AstDecl]
  [acc : LintFindings]) : LintFindings
  (match decl
    [(AstDeclDef _ maybe-ty body)
      (struct-get
        (lint-unused-variable-expr
          (ast-node-get body)
          (lint-unused-variable-maybe-type
            maybe-ty
            (LintUnusedVariableState source LintUnusedVariableFrameNil acc))
          (lint-no-effect-span (ast-node-get body)))
        findings)]
    [(AstDeclDefFn name params ret body _)
      (lint-unused-variable-decl-with-param-frame
        source
        "(define ("
        name
        params
        ret
        body
        acc)]
    [(AstDeclDefMacro name params ret body)
      (lint-unused-variable-decl-with-macro-param-frame
        source
        "(defmacro ("
        name
        params
        ret
        body
        acc)]
    [(AstDeclTest _ body _)
      (struct-get
        (lint-unused-variable-expr
          (ast-node-get body)
          (LintUnusedVariableState source LintUnusedVariableFrameNil acc)
          (lint-no-effect-span (ast-node-get body)))
        findings)]
    [(AstDeclUnsafe inner)
      (lint-unused-variables-in-decl source (box-get inner) acc)]
    [(AstDeclComptimeDecl _ inner)
      (lint-unused-variables-in-decl source (box-get inner) acc)]
    [_ acc]))

(define (lint-unused-variables-in-decl-list
  [source : String]
  [decls : AstDeclList]
  [acc : LintFindings]) : LintFindings
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (lint-unused-variables-in-decl-list
        source
        (box-get rest)
        (lint-unused-variables-in-decl source decl acc))]))

;: Walk every expression in `exprs`, accumulating findings.
(define (lint-walk-expr-list
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match exprs
    [(AstExprNil) acc]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (lint-walk-expr-list rest threshold (lint-walk-expr head threshold acc)))]))

(define (lint-walk-plain-sequence-expr-list
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-plain-sequence-expr-list-after-terminal exprs threshold acc false))

(define (lint-walk-plain-sequence-expr-list-after-terminal
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]) : LintFindings
  (match exprs
    [(AstExprNil) acc]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if after-terminal
          (lint-findings-add
            (lint-unreachable-code-finding (lint-no-effect-span head))
            acc)
          (lint-walk-plain-sequence-expr-list-after-terminal
            rest
            threshold
            (lint-walk-expr head threshold acc)
            (lint-terminal-expr? head))))]))

(define (lint-walk-discarded-nonsequence-expr
  [expr : AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [walked : LintFindings (lint-walk-expr expr threshold acc)]
    (if (lint-no-effect-pure-expr? expr)
      (lint-findings-add
        (lint-no-effect-finding (lint-no-effect-span expr))
        walked)
      walked)))

(define (lint-walk-discarded-expr
  [expr : AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match inner
          [(AstExprBegin _) (lint-walk-expr expr threshold acc)]
          [(AstExprWithRegion _ _) (lint-walk-expr expr threshold acc)]
          [(AstExprWithEscape _ _) (lint-walk-expr expr threshold acc)]
          [(AstExprWithScratch _) (lint-walk-expr expr threshold acc)]
          [(AstExprInArena _ _) (lint-walk-expr expr threshold acc)]
          [(AstExprWithResource _ _) (lint-walk-expr expr threshold acc)]
          [_ (lint-walk-discarded-nonsequence-expr expr threshold acc)]))]
    [(AstExprBegin _) (lint-walk-expr expr threshold acc)]
    [(AstExprWithRegion _ _) (lint-walk-expr expr threshold acc)]
    [(AstExprWithEscape _ _) (lint-walk-expr expr threshold acc)]
    [(AstExprWithScratch _) (lint-walk-expr expr threshold acc)]
    [(AstExprInArena _ _) (lint-walk-expr expr threshold acc)]
    [(AstExprWithResource _ _) (lint-walk-expr expr threshold acc)]
    [_ (lint-walk-discarded-nonsequence-expr expr threshold acc)]))

(define (lint-walk-value-sequence-expr-list
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-value-sequence-expr-list-after-terminal exprs threshold acc false))

(define (lint-walk-value-sequence-expr-list-after-terminal
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]) : LintFindings
  (match exprs
    [(AstExprNil) acc]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if after-terminal
          (lint-findings-add
            (lint-unreachable-code-finding (lint-no-effect-span head))
            acc)
          (let
            [walked : LintFindings
              (match rest
                [(AstExprNil) (lint-walk-expr head threshold acc)]
                [_ (lint-walk-discarded-expr head threshold acc)])]
            (lint-walk-value-sequence-expr-list-after-terminal
              rest
              threshold
              walked
              (lint-terminal-expr? head)))))]))

(define (lint-walk-tail-sequence-expr-list
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-tail-sequence-expr-list-after-terminal exprs threshold acc false))

(define (lint-walk-tail-sequence-expr-list-after-terminal
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]) : LintFindings
  (match exprs
    [(AstExprNil) acc]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if after-terminal
          (lint-findings-add
            (lint-unreachable-code-finding (lint-no-effect-span head))
            acc)
          (let
            [walked : LintFindings
              (match rest
                [(AstExprNil) (lint-walk-tail-expr head threshold acc)]
                [_ (lint-walk-discarded-expr head threshold acc)])]
            (lint-walk-tail-sequence-expr-list-after-terminal
              rest
              threshold
              walked
              (lint-terminal-expr? head)))))]))

;: Walk each binding initializer in `bindings`.
(define (lint-walk-let-bindings
  [bindings : AstLetBindingList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match bindings
    [(AstLetBindingNil) acc]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding _ _ init-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              (lint-walk-let-bindings
                rest
                threshold
                (lint-walk-expr init threshold acc)))]))]))

(define (lint-let-bindings-contain-name?
  [bindings : AstLetBindingList]
  [name : i64]) : bool
  (match bindings
    [(AstLetBindingNil) false]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding binding-name _ _)
            (if (= binding-name name)
              true
              (lint-let-bindings-contain-name? rest name))]))]))

(define (lint-let-bindings-shadow-outer?
  [outer : AstLetBindingList]
  [inner : AstLetBindingList]) : bool
  (match inner
    [(AstLetBindingNil) false]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name _ _)
            (if (lint-let-bindings-contain-name? outer name)
              true
              (lint-let-bindings-shadow-outer? outer rest))]))]))

(define (lint-nested-let-body? [body : AstExpr]) : bool
  (match body
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-nested-let-body? inner))]
    [(AstExprLet _ _) true]
    [_ false]))

(define (lint-nested-let-shadows? [outer : AstLetBindingList] [body : AstExpr]) : bool
  (match body
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-nested-let-shadows? outer inner))]
    [(AstExprLet inner-bindings _)
      (lint-let-bindings-shadow-outer? outer inner-bindings)]
    [_ false]))

(define (lint-walk-let
  [bindings : AstLetBindingList]
  [body : AstExpr]
  [span : AstSourceSpan]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [next : LintFindings
      (if (and
        (lint-nested-let-body? body)
        (not (lint-nested-let-shadows? bindings body)))
        (lint-findings-add (lint-nested-let-finding span) acc)
        acc)]
    (lint-walk-expr
      body
      threshold
      (lint-walk-let-bindings bindings threshold next))))

(define (lint-walk-tail-let
  [bindings : AstLetBindingList]
  [body : AstExpr]
  [span : AstSourceSpan]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [next : LintFindings
      (if (and
        (lint-nested-let-body? body)
        (not (lint-nested-let-shadows? bindings body)))
        (lint-findings-add (lint-nested-let-finding span) acc)
        acc)]
    (lint-walk-tail-expr
      body
      threshold
      (lint-walk-let-bindings bindings threshold next))))

;: Walk each resource initializer and cleanup expression in `bindings`.
(define (lint-walk-resource-bindings
  [bindings : AstResourceBindingList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match bindings
    [(AstResourceBindingNil) acc]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding _ init-box cleanup-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              [cleanup : AstExpr (ast-node-get cleanup-box)]
              (lint-walk-resource-bindings
                rest
                threshold
                (lint-walk-expr
                  cleanup
                  threshold
                  (lint-walk-expr init threshold acc))))]))]))

;: Walk each match-arm body in `arms`.
(define (lint-walk-match-arms
  [arms : AstMatchArmList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match arms
    [(AstMatchArmNil) acc]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm _ body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (lint-walk-match-arms
                rest
                threshold
                (lint-walk-expr body threshold acc)))]))]))

;: Descend an if/else-`if` ladder whose head has already been flagged: walk
;: each rung's condition and then-branch as fresh sub-walks (so a ladder nested
;: inside one of those still flags), but follow the else-chain here WITHOUT
;: re-flagging the inner `if`s, and walk the final non-`if` else normally.
(define (lint-walk-ladder
  [expr : AstExpr]
  [threshold : i64]
  [tail-return-path : bool]
  [acc : LintFindings]) : LintFindings
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-ladder inner threshold tail-return-path acc))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (lint-walk-ladder
          else-branch
          threshold
          tail-return-path
          (if tail-return-path
            (lint-walk-tail-expr
              then-branch
              threshold
              (lint-walk-expr cond threshold acc))
            (lint-walk-expr
              then-branch
              threshold
              (lint-walk-expr cond threshold acc)))))]
    [_
      (if tail-return-path
        (lint-walk-tail-expr expr threshold acc)
        (lint-walk-expr expr threshold acc))]))

(define (lint-walk-return-path-chain
  [expr : AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-return-path-chain inner threshold acc))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (lint-walk-return-path-chain
          then-branch
          threshold
          (lint-walk-expr
            else-branch
            threshold
            (lint-walk-expr cond threshold acc))))]
    [_ (lint-walk-tail-expr expr threshold acc)]))

(define (lint-walk-unit-if-guard-branch
  [branch : AstExpr]
  [tail-return-path : bool]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (if tail-return-path
    (lint-walk-tail-expr branch threshold acc)
    (lint-walk-expr branch threshold acc)))

;: Walk an `if`-headed expression whose source span is `span` (`lint-no-span`
;: when unspanned): while the nested-if-ladder rule is dormant, a maximal
;: ladder of length >= `threshold` descends through the else-chain without
;: emitting a ladder finding; otherwise this performs ordinary recursion into
;: cond/then/else.
(define (lint-walk-if
  [cond : AstExpr]
  [then-branch : AstExpr]
  [else-branch : AstExpr]
  [span : AstSourceSpan]
  [tail-return-path : bool]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [ladder : i64 (+ 1 (lint-ladder-length else-branch))]
    [return-chain : i64 (+ 1 (lint-return-path-chain-length then-branch))]
    [then-unit : bool (lint-unit-expr? then-branch)]
    [else-unit : bool (lint-unit-expr? else-branch)]
    [then-return : bool (lint-return-branch? then-branch)]
    [else-return : bool (lint-return-branch? else-branch)]
    [cond-not : bool (lint-not-call? cond)]
    [else-side-effect : bool (lint-side-effect-branch? else-branch)]
    (cond
      [(and
          then-unit
          (not else-unit)
          (or else-return (and cond-not else-side-effect)))
        (lint-walk-unit-if-guard-branch
          else-branch
          tail-return-path
          threshold
          (lint-findings-add
            (lint-unit-if-guard-finding true span)
            (lint-walk-expr cond threshold acc)))]
      [(and else-unit (not then-unit) then-return)
        (lint-walk-unit-if-guard-branch
          then-branch
          tail-return-path
          threshold
          (lint-findings-add
            (lint-unit-if-guard-finding false span)
            (lint-walk-expr cond threshold acc)))]
      [(and tail-return-path (>= return-chain threshold))
        (lint-walk-return-path-chain
          (AstExprIf
            (ast-node-push cond)
            (ast-node-push then-branch)
            (ast-node-push else-branch))
          threshold
          (lint-findings-add
            (lint-return-path-chain-finding return-chain span)
            acc))]
      ;; A maximal else-`if` ladder of length >= threshold is flagged once
      ;; at its head, carrying the ladder depth; lint-walk-ladder then
      ;; descends the else-chain (walking each cond/then) without
      ;; re-emitting. #2579's bracket-`cond` seed support has landed, so the
      ;; rule is active.
      [(>= ladder threshold)
        (lint-walk-ladder
          (AstExprIf
            (ast-node-push cond)
            (ast-node-push then-branch)
            (ast-node-push else-branch))
          threshold
          tail-return-path
          (lint-findings-add (lint-ladder-finding ladder span) acc))]
      [else
        (if tail-return-path
          (lint-walk-tail-expr
            else-branch
            threshold
            (lint-walk-tail-expr
              then-branch
              threshold
              (lint-walk-expr cond threshold acc)))
          (lint-walk-expr
            else-branch
            threshold
            (lint-walk-expr
              then-branch
              threshold
              (lint-walk-expr cond threshold acc))))])))

;;; Walk a list of expressions where only the final expression is in tail
;;; position.
(define (lint-walk-tail-expr-list
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-tail-expr-list-after-terminal exprs threshold acc false))

(define (lint-walk-tail-expr-list-after-terminal
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]) : LintFindings
  (match exprs
    [(AstExprNil) acc]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if after-terminal
          (lint-findings-add
            (lint-unreachable-code-finding (lint-no-effect-span head))
            acc)
          (let
            [walked : LintFindings
              (match rest
                [(AstExprNil) (lint-walk-tail-expr head threshold acc)]
                [_ (lint-walk-expr head threshold acc)])]
            (lint-walk-tail-expr-list-after-terminal
              rest
              threshold
              walked
              (lint-terminal-expr? head)))))]))

;;; Walk match arms whose bodies are in tail position.
(define (lint-walk-tail-match-arms
  [arms : AstMatchArmList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match arms
    [(AstMatchArmNil) acc]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm _ body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (lint-walk-tail-match-arms
                rest
                threshold
                (lint-walk-tail-expr body threshold acc)))]))]))

;;; Walk `expr` in a function/lambda/test tail context. The return-path-chain
;;; rule is only valid here: in non-tail value contexts, introducing
;;; `(return ...)` would change the surrounding expression's behavior.
(define (lint-walk-tail-expr
  [expr : AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match expr
    [(AstExprSpanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match inner
          [(AstExprIf cond-box then-branch-box else-branch-box)
            (let
              [cond : AstExpr (ast-node-get cond-box)]
              [then-branch : AstExpr (ast-node-get then-branch-box)]
              [else-branch : AstExpr (ast-node-get else-branch-box)]
              (lint-walk-if
                cond
                then-branch
                else-branch
                span
                true
                threshold
                acc))]
          [(AstExprLet bindings body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (lint-walk-tail-let bindings body span threshold acc))]
          [(AstExprCall func-box args)
            (let
              [func : AstExpr (ast-node-get func-box)]
              (lint-walk-call func args span threshold acc))]
          [_ (lint-walk-tail-expr inner threshold acc)]))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (lint-walk-if
          cond
          then-branch
          else-branch
          (lint-no-span)
          true
          threshold
          acc))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-tail-let bindings body (lint-no-span) threshold acc))]
    [(AstExprLambda _ _ body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(AstExprBegin exprs)
      (lint-walk-tail-sequence-expr-list exprs threshold acc)]
    [(AstExprUnsafe exprs) (lint-walk-tail-expr-list exprs threshold acc)]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-tail-expr inner threshold acc))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-tail-expr inner threshold acc))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (ast-node-get scrutinee-box)]
        (lint-walk-tail-match-arms
          arms
          threshold
          (lint-walk-expr scrutinee threshold acc)))]
    [(AstExprWithRegion _ body)
      (lint-walk-tail-sequence-expr-list body threshold acc)]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (lint-walk-tail-sequence-expr-list
          body
          threshold
          (lint-walk-expr scratch threshold acc)))]
    [(AstExprWithScratch body)
      (lint-walk-tail-sequence-expr-list body threshold acc)]
    [(AstExprInArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (lint-walk-tail-sequence-expr-list
          body
          threshold
          (lint-walk-expr arena threshold acc)))]
    [(AstExprWithResource bindings body)
      (lint-walk-tail-sequence-expr-list
        body
        threshold
        (lint-walk-resource-bindings bindings threshold acc))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-tail-expr inner threshold acc))]
    [_ (lint-walk-expr expr threshold acc)]))

(define (lint-walk-and-or-skip-expr
  [op : String]
  [expr : AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (if (lint-and-or-call-kind? op inner)
          (lint-walk-and-or-skip-expr op inner threshold acc)
          (lint-walk-expr expr threshold acc)))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (if (string-eq (lint-and-or-func-op func) op)
          (lint-walk-and-or-skip-args op args threshold acc)
          (lint-walk-expr expr threshold acc)))]
    [_ (lint-walk-expr expr threshold acc)]))

(define (lint-walk-and-or-skip-args
  [op : String]
  [args : AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match args
    [(AstExprNil) acc]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (lint-walk-and-or-skip-args
          op
          rest
          threshold
          (lint-walk-and-or-skip-expr op head-expr threshold acc)))]))

(define (lint-walk-call
  [func : AstExpr]
  [args : AstExprList]
  [span : AstSourceSpan]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [op : String (lint-and-or-func-op func)]
    (if (and (not (string-eq op "")) (lint-and-or-args-have-kind? op args))
      (lint-walk-and-or-skip-args
        op
        args
        threshold
        (lint-findings-add
          (lint-cascading-and-or-finding op (lint-expr-render func) args span)
          (lint-walk-expr func threshold acc)))
      (if (and (lint-str-cat-func? func) (lint-str-cat-args-have-nested? args))
        (lint-walk-expr-list
          args
          threshold
          (lint-findings-add
            (lint-nested-str-cat-finding span)
            (lint-walk-expr func threshold acc)))
        (lint-walk-expr-list args threshold (lint-walk-expr func threshold acc))))))

;: Walk `expr`, collecting active lint findings while recursing into all
;: sub-expressions. Spanned expressions pass their wrapper span to rules that
;: need source locations.
(define (lint-walk-expr [expr : AstExpr] [threshold : i64] [acc : LintFindings]) : LintFindings
  (match expr
    [(AstExprSpanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match inner
          [(AstExprIf cond-box then-branch-box else-branch-box)
            (let
              [cond : AstExpr (ast-node-get cond-box)]
              [then-branch : AstExpr (ast-node-get then-branch-box)]
              [else-branch : AstExpr (ast-node-get else-branch-box)]
              (lint-walk-if
                cond
                then-branch
                else-branch
                span
                false
                threshold
                acc))]
          [(AstExprLet bindings body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (lint-walk-let bindings body span threshold acc))]
          [(AstExprCall func-box args)
            (let
              [func : AstExpr (ast-node-get func-box)]
              (lint-walk-call func args span threshold acc))]
          [_ (lint-walk-expr inner threshold acc)]))]
    [(AstExprLiteral _) acc]
    [(AstExprVar _) acc]
    [(AstExprTypeLiteral _) acc]
    [(AstExprInit _) acc]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (lint-walk-expr right threshold (lint-walk-expr left threshold acc)))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lint-walk-call func args (lint-no-span) threshold acc))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      ;; A directly-reached (unspanned) `if`: no wrapper span, so the finding
      ;; gets the sentinel. Maximal-ladder dedup lives in lint-walk-if.
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (lint-walk-if
          cond
          then-branch
          else-branch
          (lint-no-span)
          false
          threshold
          acc))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-let bindings body (lint-no-span) threshold acc))]
    [(AstExprLambda _ _ body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-expr body threshold acc))]
    [(AstExprTuple exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExprTupleRef tuple-box _)
      (let
        [tuple : AstExpr (ast-node-get tuple-box)]
        (lint-walk-expr tuple threshold acc))]
    [(AstExprArray exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExprMakeArray _ len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (lint-walk-expr len threshold acc))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lint-walk-expr index threshold (lint-walk-expr array threshold acc)))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr
          value
          threshold
          (lint-walk-expr index threshold (lint-walk-expr array threshold acc))))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr array threshold acc)))]
    [(AstExprStringRef str-box index-box)
      (let
        [str : AstExpr (ast-node-get str-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lint-walk-expr index threshold (lint-walk-expr str threshold acc)))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-expr body threshold (lint-walk-expr cond threshold acc)))]
    [(AstExprBegin exprs)
      (lint-walk-value-sequence-expr-list exprs threshold acc)]
    [(AstExprUnsafe exprs)
      (lint-walk-plain-sequence-expr-list exprs threshold acc)]
    [(AstExprSet _ value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold acc))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprBorrow _ _ place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (lint-walk-expr place threshold acc))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (ast-node-get scrutinee-box)]
        (lint-walk-match-arms
          arms
          threshold
          (lint-walk-expr scrutinee threshold acc)))]
    [(AstExprForeach _ _ start-box end-box body-box)
      (let
        [start : AstExpr (ast-node-get start-box)]
        [end : AstExpr (ast-node-get end-box)]
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-expr
          body
          threshold
          (lint-walk-expr end threshold (lint-walk-expr start threshold acc))))]
    [(AstExprSpmdReduce _ _ _ start-box end-box init-box value-box)
      (let
        [start : AstExpr (ast-node-get start-box)]
        [end : AstExpr (ast-node-get end-box)]
        [init : AstExpr (ast-node-get init-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr
          value
          threshold
          (lint-walk-expr
            init
            threshold
            (lint-walk-expr end threshold (lint-walk-expr start threshold acc)))))]
    [(AstExprSpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (lint-walk-expr lane threshold (lint-walk-expr value threshold acc)))]
    [(AstExprStructGet receiver-box _)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (lint-walk-expr receiver threshold acc))]
    [(AstExprStructSet receiver-box _ value-box)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr receiver threshold acc)))]
    [(AstExprWithRegion _ body)
      (lint-walk-value-sequence-expr-list body threshold acc)]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (lint-walk-value-sequence-expr-list
          body
          threshold
          (lint-walk-expr scratch threshold acc)))]
    [(AstExprWithScratch body)
      (lint-walk-value-sequence-expr-list body threshold acc)]
    [(AstExprInArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (lint-walk-value-sequence-expr-list
          body
          threshold
          (lint-walk-expr arena threshold acc)))]
    [(AstExprWithResource bindings body)
      (lint-walk-value-sequence-expr-list
        body
        threshold
        (lint-walk-resource-bindings bindings threshold acc))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprBoxTake inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprBoxSet inner-box value-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr inner threshold acc)))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprQuote _) acc]
    [(AstExprQuasiquote _) acc]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprBracketClause items) (lint-walk-expr-list items threshold acc)]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprPtrNull _) acc]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprPtrAddrOf _) acc]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lint-walk-expr ptr threshold acc))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr ptr threshold acc)))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (lint-walk-expr offset threshold (lint-walk-expr ptr threshold acc)))]
    [(AstExprPtrCast ptr-box _)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lint-walk-expr ptr threshold acc))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lint-walk-expr ptr threshold acc))]
    [(AstExprIntToPtr value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold acc))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (lint-walk-expr len threshold (lint-walk-expr ptr threshold acc)))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExprBinaryData _) acc]
    [(AstExprProgramArgc) acc]
    [(AstExprProgramArgv) acc]
    [(AstExprProgramEnvp) acc]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (lint-walk-expr index threshold acc))]
    [(AstExprSyscall args) (lint-walk-expr-list args threshold acc)]))

;: Walk the body expression(s) carried by a declaration, if any.
(define (lint-walk-decl [decl : AstDecl] [threshold : i64] [acc : LintFindings]) : LintFindings
  (match decl
    [(AstDeclDef _ _ body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-expr body threshold acc))]
    [(AstDeclDefFn _ _ _ body-box _)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(AstDeclDefMacro _ _ _ body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(AstDeclTest _ body-box _)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lint-walk-decl inner threshold acc))]
    [(AstDeclComptimeDecl _ inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lint-walk-decl inner threshold acc))]
    [(AstDeclModule _) acc]
    [(AstDeclExtern _ _ _ _) acc]
    [(AstDeclDefEnum _ _ _) acc]
    [(AstDeclDefEnumLifetimes _ _ _ _) acc]
    [(AstDeclDefStruct _ _ _ _) acc]
    [(AstDeclDefStructLifetimes _ _ _ _ _) acc]
    [(AstDeclDefDispatch _ _) acc]
    [(AstDeclExport _) acc]
    [(AstDeclIncludeStr _ _) acc]
    [(AstDeclIncludeBin _ _) acc]
    [(AstDeclImport _) acc]))

;: Walk every declaration body in `decls`.
(define (lint-walk-decl-list
  [decls : AstDeclList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (lint-walk-decl-list rest threshold (lint-walk-decl decl threshold acc)))]))

(define (lint-program-with-source
  [source : String]
  [program : AstProgram]
  [threshold : i64]) : LintFindings
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (lint-unused-variables-in-decl-list
          source
          decls
          (lint-unused-imports-in-decl-list
            decls
            decls
            (lint-unused-assignments-in-decl-list
              decls
              (lint-walk-decl-list decls threshold (lint-findings-empty))))))]))

;: Run all lint rules over `program`, returning the collected findings.
(define (lint-program [program : AstProgram] [threshold : i64]) : LintFindings
  (lint-program-with-source "" program threshold))

(define (lint-program-with-deprecated-string-concat
  [source : String]
  [program : AstProgram]
  [threshold : i64]) : LintFindings
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (lint-deprecated-string-concat-scan
          source
          (lint-unused-variables-in-decl-list
            source
            decls
            (lint-unused-imports-in-decl-list
              decls
              decls
              (lint-unused-assignments-in-decl-list
                decls
                (lint-walk-decl-list decls threshold (lint-findings-empty)))))))]))

;: Self-test: the nested-`if`-ladder rule and the AST walk.
;: Flat-AST test helpers: the self-test builds exprs with i64-returning
;: constructors; lint-ladder-length / lint-walk-expr take AstExpr, so wrap.
(define (lint-test-ladder-length [e : i64]) : i64
  (lint-ladder-length (ast-node-get e)))

(define (lint-test-walk [e : i64] [threshold : i64] [acc : LintFindings]) : LintFindings
  (lint-walk-expr (ast-node-get e) threshold acc))

(define (lint-test-walk-tail [e : i64] [threshold : i64] [acc : LintFindings]) : LintFindings
  (lint-walk-tail-expr (ast-node-get e) threshold acc))

(define (lint-test-var [name : String]) : i64
  (ast-node-push (AstExprVar (intern name))))

(define (lint-test-expr-list2 [a : i64] [b : i64]) : AstExprList
  (ast-expr-cons a (ast-expr-cons b AstExprNil)))

(define (lint-test-expr-list3 [a : i64] [b : i64] [c : i64]) : AstExprList
  (ast-expr-cons a (ast-expr-cons b (ast-expr-cons c AstExprNil))))

(define (compiler-lint-self-test) : i64
  (let
    [vx : i64 (lint-test-var "x")]
    [vy : i64 (lint-test-var "y")]
    [vz : i64 (lint-test-var "z")]
    [one : i64 (ast-node-push (AstExprLiteral (AstLitInt 1)))]
    [unit-expr : i64 (ast-node-push (AstExprLiteral AstLitUnit))]
    [ladder3 : i64
      (ast-expr-if vx one (ast-expr-if vx one (ast-expr-if vx one one)))]
    [ladder2 : i64 (ast-expr-if vx one (ast-expr-if vx one one))]
    [ladder4 : i64
      (ast-expr-if
        vx
        one
        (ast-expr-if vx one (ast-expr-if vx one (ast-expr-if vx one one))))]
    [return-chain3 : i64
      (ast-expr-if vx (ast-expr-if vx (ast-expr-if vx one one) one) one)]
    [return-one : i64 (ast-expr-return one)]
    [not-vx : i64 (ast-expr-unary (AstUnNot) vx)]
    [set-ok-false : i64
      (ast-expr-set "ok" (ast-node-push (AstExprLiteral (AstLitBool false))))]
    [unit-then-guard : i64 (ast-expr-if vx unit-expr return-one)]
    [unit-else-guard : i64 (ast-expr-if vx return-one unit-expr)]
    [unit-value-guard : i64 (ast-expr-if vx one unit-expr)]
    [unit-not-set-guard : i64 (ast-expr-if not-vx unit-expr set-ok-false)]
    [nested : i64
      (ast-node-push (AstExprBegin (ast-expr-cons ladder3 (AstExprNil))))]
    [in-let : i64
      (ast-expr-let
        (ast-let-binding-cons
          (ast-let-binding "y" (AstNoType) ladder3)
          (AstLetBindingNil))
        vx)]
    [outer-let-bindings : AstLetBindingList
      (ast-let-binding-cons
        (ast-let-binding "a" (AstNoType) one)
        (AstLetBindingNil))]
    [inner-let-bindings : AstLetBindingList
      (ast-let-binding-cons
        (ast-let-binding "b" (AstNoType) vx)
        (AstLetBindingNil))]
    [shadowing-let-bindings : AstLetBindingList
      (ast-let-binding-cons
        (ast-let-binding "a" (AstNoType) one)
        (AstLetBindingNil))]
    [nested-let : i64
      (ast-expr-let outer-let-bindings (ast-expr-let inner-let-bindings vx))]
    [shadowing-nested-let : i64
      (ast-expr-let outer-let-bindings (ast-expr-let shadowing-let-bindings vx))]
    [begin-inner-let : i64
      (ast-expr-let
        outer-let-bindings
        (ast-node-push
          (AstExprBegin
            (ast-expr-cons
              (ast-expr-let inner-let-bindings vx)
              (ast-expr-cons vx (AstExprNil))))))]
    [spanned : i64 (ast-expr-spanned ladder3 (AstSourceSpan 7 3 9 4))]
    [spanned-nested-let : i64
      (ast-expr-spanned nested-let (AstSourceSpan 11 5 15 6))]
    [and-callee : i64 (lint-test-var "and")]
    [or-callee : i64 (lint-test-var "or")]
    [core-and-callee : i64 (lint-test-var "core/and")]
    [and-yz : i64 (ast-expr-call and-callee (lint-test-expr-list2 vy vz))]
    [and-xy : i64 (ast-expr-call and-callee (lint-test-expr-list2 vx vy))]
    [or-yz : i64 (ast-expr-call or-callee (lint-test-expr-list2 vy vz))]
    [or-xy : i64 (ast-expr-call or-callee (lint-test-expr-list2 vx vy))]
    [and-cascade : i64
      (ast-expr-call and-callee (lint-test-expr-list2 vx and-yz))]
    [or-cascade : i64 (ast-expr-call or-callee (lint-test-expr-list2 or-xy vz))]
    [flat-and : i64 (ast-expr-call and-callee (lint-test-expr-list3 vx vy vz))]
    [mixed-and-or : i64
      (ast-expr-call and-callee (lint-test-expr-list2 vx or-yz))]
    [core-and-cascade : i64
      (ast-expr-call core-and-callee (lint-test-expr-list2 vx and-yz))]
    [double-and-cascade : i64
      (ast-expr-call and-callee (lint-test-expr-list2 and-xy and-yz))]
    [spanned-and-cascade : i64
      (ast-expr-spanned and-cascade (AstSourceSpan 21 7 21 30))]
    [discarded-add : i64 (ast-expr-binary (AstBinAdd) one vx)]
    [discarded-cast : i64 (ast-expr-cast one (AstTyI64))]
    [discarded-call : i64
      (ast-expr-call (lint-test-var "side-effect?") AstExprNil)]
    [no-effect-literal-begin : i64
      (ast-node-push
        (AstExprBegin (ast-expr-cons one (ast-expr-cons vx AstExprNil))))]
    [no-effect-var-begin : i64
      (ast-node-push
        (AstExprBegin (ast-expr-cons vx (ast-expr-cons one AstExprNil))))]
    [no-effect-add-begin : i64
      (ast-node-push
        (AstExprBegin
          (ast-expr-cons discarded-add (ast-expr-cons vx AstExprNil))))]
    [no-effect-cast-begin : i64
      (ast-node-push
        (AstExprBegin
          (ast-expr-cons discarded-cast (ast-expr-cons vx AstExprNil))))]
    [no-effect-tail-begin : i64
      (ast-node-push (AstExprBegin (ast-expr-cons one AstExprNil)))]
    [no-effect-clean-call-begin : i64
      (ast-node-push
        (AstExprBegin
          (ast-expr-cons discarded-call (ast-expr-cons vx AstExprNil))))]
    [no-effect-clean-mutation-begin : i64
      (ast-node-push
        (AstExprBegin
          (ast-expr-cons set-ok-false (ast-expr-cons vx AstExprNil))))]
    [no-effect-unsafe-begin : i64
      (ast-node-push
        (AstExprUnsafe (ast-expr-cons one (ast-expr-cons vx AstExprNil))))]
    [spanned-no-effect-var : i64
      (ast-node-push
        (AstExprBegin
          (ast-expr-cons
            (ast-expr-spanned vx (AstSourceSpan 31 9 31 10))
            (ast-expr-cons one AstExprNil))))]
    [spanned-unreachable-var : i64
      (ast-expr-spanned vx (AstSourceSpan 41 9 41 10))]
    [unreachable-return-begin : i64
      (ast-node-push
        (AstExprBegin
          (ast-expr-cons
            return-one
            (ast-expr-cons
              spanned-unreachable-var
              (ast-expr-cons vy AstExprNil)))))]
    [panic-call : i64
      (ast-expr-call (lint-test-var "panic") (ast-expr-cons one AstExprNil))]
    [unreachable-panic-unsafe : i64
      (ast-node-push
        (AstExprUnsafe (ast-expr-cons panic-call (ast-expr-cons vx AstExprNil))))]
    [branch-local-return-begin : i64
      (ast-node-push
        (AstExprBegin
          (ast-expr-cons
            (ast-expr-if vx return-one return-one)
            (ast-expr-cons vx AstExprNil))))]
    (begin
      ;; ladder length math
      (if (= (lint-test-ladder-length ladder3) 3)
        unit
        (panic "lint: ladder3 length should be 3"))
      (if (= (lint-test-ladder-length ladder2) 2)
        unit
        (panic "lint: ladder2 length should be 2"))
      (if (= (lint-test-ladder-length vx) 0)
        unit
        (panic "lint: non-if ladder length should be 0"))
      ;; The nested-if-ladder rule flags a maximal else-`if` ladder of length
      ;; >= threshold once, at its head, carrying the ladder depth.
      (if (=
        (lint-findings-count
          (lint-test-walk
            ladder3
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: 3-deep ladder should be flagged once"))
      (match (lint-findings-get
        (lint-test-walk
          ladder3
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (if (and
            (= (struct-get finding depth) 3)
            (string-eq
              (struct-get finding rule-id)
              (lint-rule-nested-if-ladder-id)))
            unit
            (panic "lint: 3-deep ladder finding should carry rule id and depth"))]
        [(LintNoFinding) (panic "lint: 3-deep ladder should produce a finding")])
      ;; a 2-deep ladder is NOT flagged at threshold 3
      (if (=
        (lint-findings-count
          (lint-test-walk
            ladder2
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: 2-deep ladder should not be flagged at threshold 3"))
      ;; ... and is flagged at threshold 2, where its length meets the bound.
      (if (=
        (lint-findings-count (lint-test-walk ladder2 2 (lint-findings-empty)))
        1)
        unit
        (panic "lint: 2-deep ladder should be flagged at threshold 2"))
      ;; return-path chains are only reported in tail contexts, where replacing
      ;; nested failure values with `(return ...)` preserves semantics.
      (if (=
        (lint-findings-count
          (lint-test-walk
            return-chain3
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: return-path chain should not flag in a value context"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            return-chain3
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: return-path chain should be flagged once"))
      (match (lint-findings-get
        (lint-test-walk-tail
          return-chain3
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (if (string-eq
            (struct-get finding rule-id)
            (lint-rule-return-path-chain-id))
            unit
            (panic "lint: return-path chain should report its rule id"))]
        [(LintNoFinding)
          (panic "lint: return-path chain should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk
            unit-then-guard
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: unit then-branch should be flagged once"))
      (match (lint-findings-get
        (lint-test-walk
          unit-else-guard
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (if (string-eq
            (struct-get finding rule-id)
            (lint-rule-unit-if-guard-id))
            unit
            (panic "lint: unit-if guard should report its rule id"))]
        [(LintNoFinding) (panic "lint: unit-if guard should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk
            unit-value-guard
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: unit-if guard should skip value branches"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            unit-not-set-guard
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: inverted unit set! guard should be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            nested
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: ladder nested in begin should be flagged once"))
      ;; ... and into let-binding initializers
      (if (=
        (lint-findings-count
          (lint-test-walk
            in-let
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: ladder in a let binding should be flagged once"))
      ;; Longer ladders are flagged once at the head with their full depth.
      (if (=
        (lint-findings-count
          (lint-test-walk
            ladder4
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: 4-deep ladder should be flagged once"))
      ;; A spanned ladder carries its head wrapper span on the finding.
      (match (lint-findings-get
        (lint-test-walk
          spanned
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 7)
              (string-eq
                (struct-get finding rule-id)
                (lint-rule-nested-if-ladder-id)))
              unit
              (panic
                "lint: spanned ladder finding should carry rule id and span")))]
        [(LintNoFinding)
          (panic "lint: spanned ladder should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk
            nested-let
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: body-only nested let should be flagged once"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            shadowing-nested-let
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: shadowing nested let should not be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            begin-inner-let
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: let with nontrivial begin body should not be flagged"))
      (match (lint-findings-get
        (lint-test-walk
          spanned-nested-let
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 11)
              (string-eq (struct-get finding rule-id) (lint-rule-nested-let-id)))
              unit
              (panic "lint: nested-let finding should carry rule id and span")))]
        [(LintNoFinding)
          (panic "lint: spanned nested let should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk
            and-cascade
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: nested and should be flagged once"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            or-cascade
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: nested or should be flagged once"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            flat-and
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: flat and should not be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            mixed-and-or
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: mixed and/or should not be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            double-and-cascade
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: one maximal and cascade should produce one finding"))
      (match (lint-findings-get
        (lint-test-walk
          spanned-and-cascade
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 21)
              (= (struct-get finding depth) 3)
              (string-eq
                (struct-get finding rule-id)
                (lint-rule-cascading-and-or-id))
              (string-eq
                (struct-get finding message)
                "cascading and: prefer flat n-ary form (and x y z)"))
              unit
              (panic "lint: cascading-and-or finding metadata mismatch")))]
        [(LintNoFinding)
          (panic "lint: spanned and cascade should produce a finding")])
      (match (lint-findings-get
        (lint-test-walk
          core-and-cascade
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (if (string-eq
            (struct-get finding message)
            (string-append
              "cascading and: prefer flat n-ary form ("
              (string-append "core/and" " x y z)")))
            unit
            (panic "lint: core/and cascade should preserve callee spelling"))]
        [(LintNoFinding)
          (panic "lint: core/and cascade should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-literal-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: discarded literal should be flagged"))
      (match (lint-findings-get
        (lint-test-walk-tail
          spanned-no-effect-var
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 31)
              (string-eq (struct-get finding rule-id) (lint-rule-no-effect-id)))
              unit
              (panic "lint: no-effect finding should carry rule id and span")))]
        [(LintNoFinding)
          (panic "lint: discarded variable should produce a no-effect finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-var-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: discarded variable should be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-add-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: discarded arithmetic should be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-cast-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: discarded cast should be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-tail-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: tail expression should not be flagged as no-effect"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-clean-call-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: discarded call should not be flagged as no-effect"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-clean-mutation-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: discarded mutation should not be flagged as no-effect"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-unsafe-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic "lint: unsafe block should not be flagged as no-effect"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            unreachable-return-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: return should flag following unreachable expression once"))
      (match (lint-findings-get
        (lint-test-walk-tail
          unreachable-return-begin
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 41)
              (string-eq
                (struct-get finding rule-id)
                (lint-rule-unreachable-code-id)))
              unit
              (panic
                "lint: unreachable-code finding should carry rule id and span")))]
        [(LintNoFinding)
          (panic "lint: unreachable-code should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            unreachable-panic-unsafe
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: panic in unsafe should flag following unreachable code"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            branch-local-return-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (panic
          "lint: branch-local return should not make following code unreachable"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-nested-if-ladder-id))
        "prefer cond (value/guard ladders) or match (variant dispatch)")
        unit
        (panic "lint: nested-if-ladder suggestion should be registered"))
      (if (string-eq
        (lint-rule-message (lint-rule-nested-if-ladder-id))
        "nested if-ladder: chain of if/else-if; prefer cond (value/guard ladders) or match (variant dispatch)")
        unit
        (panic "lint: nested-if-ladder message should be registered"))
      (match (lint-rule-find (lint-rule-nested-if-ladder-id))
        [(LintRuleFound rule)
          (if (and
            (string-eq
              (struct-get rule rule-id)
              (lint-rule-nested-if-ladder-id))
            (string-eq
              (struct-get rule message)
              (lint-rule-nested-if-ladder-message))
            (string-eq
              (struct-get rule suggestion)
              (lint-rule-nested-if-ladder-suggestion)))
            unit
            (panic
              "lint: nested-if-ladder registry entry should match metadata"))]
        [(LintRuleNotFound)
          (panic "lint: nested-if-ladder should be registered")])
      (if (string-eq
        (lint-rule-suggestion (lint-rule-nested-let-id))
        "merge the nested let bindings into one sequential let")
        unit
        (panic "lint: nested-let suggestion should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-return-path-chain-id))
        "prefer early return guards with (return ...)")
        unit
        (panic "lint: return-path-chain suggestion should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-unit-if-guard-id))
        "prefer when/unless for unit guard branches")
        unit
        (panic "lint: unit-if-guard suggestion should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-no-effect-id))
        "remove the expression or use its value")
        unit
        (panic "lint: no-effect suggestion should be registered"))
      (if (string-eq
        (lint-rule-message (lint-rule-no-effect-id))
        "no-effect expression: value is discarded")
        unit
        (panic "lint: no-effect message should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-unreachable-code-id))
        "remove the unreachable expression or move it before the terminal expression")
        unit
        (panic "lint: unreachable-code suggestion should be registered"))
      (if (string-eq
        (lint-rule-message (lint-rule-unreachable-code-id))
        "unreachable code: expression follows a terminal expression")
        unit
        (panic "lint: unreachable-code message should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-deprecated-string-concat-id))
        "import stdlib/str_cat.tl and use str-cat, or use stdlib/text_buf.tl in accumulation loops")
        unit
        (panic "lint: deprecated-string-concat suggestion should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-nested-str-cat-id))
        "flatten nested str-cat operands into the outer call")
        unit
        (panic "lint: nested-str-cat suggestion should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-cascading-and-or-id))
        "flatten same-operator and/or operands, e.g. (and a b c)")
        unit
        (panic "lint: cascading-and-or suggestion should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-unused-import-id))
        "remove the import or prefix an intentionally unused alias with _")
        unit
        (panic "lint: unused-import suggestion should be registered"))
      (if (string-eq
        (lint-rule-message (lint-rule-unused-import-id))
        "unused import: imported module alias is never referenced")
        unit
        (panic "lint: unused-import message should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-unused-variable-id))
        "remove the binding or prefix an intentionally unused name with _")
        unit
        (panic "lint: unused-variable suggestion should be registered"))
      (if (string-eq
        (lint-rule-message (lint-rule-unused-variable-id))
        "unused variable: parameter or local binding is never used")
        unit
        (panic "lint: unused-variable message should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-unused-unsafe-id))
        "remove the unsafe wrapper")
        unit
        (panic "lint: unused-unsafe suggestion should be registered"))
      (if (string-eq
        (lint-rule-message (lint-rule-unused-unsafe-id))
        "unused unsafe block: body does not require unsafe context")
        unit
        (panic "lint: unused-unsafe message should be registered"))
      (if (string-eq (lint-rule-suggestion "unknown-rule") "")
        unit
        (panic "lint: unknown rule should have no suggestion"))
      (if (string-eq (lint-rule-message "unknown-rule") "")
        unit
        (panic "lint: unknown rule should have no message"))
      (match (lint-rule-find "unknown-rule")
        [(LintRuleNotFound) unit]
        [(LintRuleFound _) (panic "lint: unknown rule should not be found")])
      42)))