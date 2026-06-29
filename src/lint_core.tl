;# TypeLisp lint engine + source cleanup rules (#1163, #1177).
;#
;# A selfhost lint pass: walk the parsed AST, run registered rules, and collect
;# findings. The rules flag body-only nested `let` forms, single-expression
;# `begin` wrappers, nested success-path `if` return chains, unit-branch return
;# guards, no-effect expression statements, nested `str-cat` calls, and
;# deprecated user-facing string concatenation primitives.
;#
;# The `typelisp lint` CLI driver consumes the rule id attached to each finding
;# for suppression (`;; lint-allow: <rule-id>`). This module owns stable rule
;# metadata and the lint core verified by `compiler-lint-self-test` (driver:
;# `selfhost/lint_smoke.tl`).
(import stdlib.io)
(import stdlib.string)
(import "compiler_ast_types.tl")
(import token)
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

(define (lint-rule-single-begin-id) : String
  "single-begin")

(define (lint-rule-single-begin-message) : String
  "single begin: begin with one expression is redundant")

(define (lint-rule-single-begin-suggestion) : String
  "remove the begin wrapper")

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

(define (lint-rule-redundant-divergence-padding-id) : String
  "redundant-divergence-padding")

(define (lint-rule-redundant-divergence-padding-message) : String
  "redundant divergence padding: trailing expressions after panic/error are dead")

(define (lint-rule-redundant-divergence-padding-suggestion) : String
  "remove the trailing dead expression and the stale unreachable-code lint allow")

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

(define (lint-rule-redundant-import-alias-id) : String
  "redundant-import-alias")

(define (lint-rule-redundant-import-alias-message) : String
  "redundant import alias: dotted module import already binds that alias")

(define (lint-rule-redundant-import-alias-suggestion) : String
  "remove the explicit as clause")

(define (lint-rule-redundant-function-name-id) : String
  "redundant-function-name")

(define (lint-rule-redundant-function-name-message) : String
  "redundant function name: local function or macro repeats the module prefix")

(define (lint-rule-redundant-function-name-suggestion) : String
  "drop the module prefix from the local function or macro name")

(define (lint-rule-dead-code-id) : String
  "dead-code")

(define (lint-rule-dead-code-message) : String
  "dead code: top-level declaration is unreachable from package entry/test roots")

(define (lint-rule-dead-code-suggestion) : String
  "remove the declaration or reference it from package entry/test roots")

(define (lint-rule-unused-assignment-id) : String
  "unused-assignment")

(define (lint-rule-unused-assignment-message) : String
  "unused assignment: value is overwritten before it is read")

(define (lint-rule-unused-assignment-suggestion) : String
  "remove the assignment or read the value before overwriting it")

(define (lint-rule-copy-on-update-struct-id) : String
  "copy-on-update-struct")

(define (lint-rule-copy-on-update-struct-message) : String
  "copy-on-update struct mutation: prefer in-place field assignment")

(define (lint-rule-copy-on-update-struct-suggestion) : String
  "replace same-struct reassignment with (set! (struct-get value field) new-value)")

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
  (Nil)
  (Cons LintRule (Box LintRuleList)))

(defenum LintMaybeRule
  (NotFound)
  (Found LintRule))

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

(define (lint-rule-single-begin) : LintRule
  (LintRule
    (lint-rule-single-begin-id)
    (lint-rule-single-begin-message)
    (lint-rule-single-begin-suggestion)))

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

(define (lint-rule-redundant-divergence-padding) : LintRule
  (LintRule
    (lint-rule-redundant-divergence-padding-id)
    (lint-rule-redundant-divergence-padding-message)
    (lint-rule-redundant-divergence-padding-suggestion)))

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

(define (lint-rule-redundant-import-alias) : LintRule
  (LintRule
    (lint-rule-redundant-import-alias-id)
    (lint-rule-redundant-import-alias-message)
    (lint-rule-redundant-import-alias-suggestion)))

(define (lint-rule-redundant-function-name) : LintRule
  (LintRule
    (lint-rule-redundant-function-name-id)
    (lint-rule-redundant-function-name-message)
    (lint-rule-redundant-function-name-suggestion)))

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

(define (lint-rule-copy-on-update-struct) : LintRule
  (LintRule
    (lint-rule-copy-on-update-struct-id)
    (lint-rule-copy-on-update-struct-message)
    (lint-rule-copy-on-update-struct-suggestion)))

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
  (LintRuleList.Cons rule (box rest)))

;: Small registry for lint metadata. New rules plug into this list and the
;: shared lookup helpers without requiring public driver edits.
(define (lint-rule-registry) : LintRuleList
  (lint-rule-cons
    (lint-rule-nested-if-ladder)
    (lint-rule-cons
      (lint-rule-nested-let)
      (lint-rule-cons
        (lint-rule-single-begin)
        (lint-rule-cons
          (lint-rule-return-path-chain)
          (lint-rule-cons
            (lint-rule-unit-if-guard)
            (lint-rule-cons
              (lint-rule-no-effect)
              (lint-rule-cons
                (lint-rule-unreachable-code)
                (lint-rule-cons
                  (lint-rule-redundant-divergence-padding)
                  (lint-rule-cons
                    (lint-rule-deprecated-string-concat)
                    (lint-rule-cons
                      (lint-rule-nested-str-cat)
                      (lint-rule-cons
                        (lint-rule-cascading-and-or)
                        (lint-rule-cons
                          (lint-rule-unused-import)
                          (lint-rule-cons
                            (lint-rule-redundant-import-alias)
                            (lint-rule-cons
                              (lint-rule-redundant-function-name)
                              (lint-rule-cons
                                (lint-rule-dead-code)
                                (lint-rule-cons
                                  (lint-rule-unused-assignment)
                                  (lint-rule-cons
                                    (lint-rule-copy-on-update-struct)
                                    (lint-rule-cons
                                      (lint-rule-unused-variable)
                                      (lint-rule-cons
                                        (lint-rule-unused-unsafe)
                                        LintRuleList.Nil))))))))))))))))))))

(define (lint-rule-find-in [rules : LintRuleList] [rule-id : String]) : LintMaybeRule
  (match rules
    [(LintRuleList.Nil) LintMaybeRule.NotFound]
    [(LintRuleList.Cons rule rest)
      (if (string.string-eq (struct-get rule rule-id) rule-id)
        (LintMaybeRule.Found rule)
        (lint-rule-find-in (box-get rest) rule-id))]))

(define (lint-rule-find [rule-id : String]) : LintMaybeRule
  (lint-rule-find-in (lint-rule-registry) rule-id))

;: Rule registry message lookup. Unknown ids return the empty string.
(define (lint-rule-message [rule-id : String]) : String
  (match (lint-rule-find rule-id)
    [(LintMaybeRule.Found rule) (struct-get rule message)]
    [(LintMaybeRule.NotFound) ""]))

;: Rule registry suggestion lookup. Unknown ids return the empty string.
(define (lint-rule-suggestion [rule-id : String]) : String
  (match (lint-rule-find rule-id)
    [(LintMaybeRule.Found rule) (struct-get rule suggestion)]
    [(LintMaybeRule.NotFound) ""]))

;: Growable findings buffer. The backing array stores findings in discovery
;: order; the CLI renders from the end to preserve the historical output order.
(defstruct LintFindings
  (slots (Array LintFinding))
  (len i64))

(defenum LintMaybeFinding
  (No)
  (Some LintFinding))

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
    (LintMaybeFinding.Some (lint-findings-ref items index))
    (LintMaybeFinding.No)))

;: Default nested-`if`-ladder depth threshold (an else-chain of this many `if`s
;: or more is flagged).
(define (lint-default-ladder-threshold) : i64
  3)

;: Length of the `if`/else-`if` ladder headed by `expr`: 0 when `expr` is not an
;: `if`, otherwise 1 + the ladder length of its else-branch. Spans are
;: transparent.
(define (lint-ladder-length [expr : AstExpr]) : i64
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-ladder-length inner))]
    [(AstExpr.If _ _ else-branch-box)
      (let
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (+ 1 (lint-ladder-length else-branch)))]
    [_ 0]))

(define (lint-return-path-chain-length [expr : AstExpr]) : i64
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-return-path-chain-length inner))]
    [(AstExpr.If _ then-branch-box _)
      (let
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        (+ 1 (lint-return-path-chain-length then-branch)))]
    [_ 0]))

(define (lint-unit-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-unit-expr? inner))]
    [(AstExpr.Literal AstLitUnit) true]
    [_ false]))

(define (lint-single-arg-call? [args : AstExprList]) : bool
  (match args
    [(AstExprList.Cons _ rest)
      (let
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprList.Nil) true]
          [_ false]))]
    [_ false]))

(define (lint-not-call? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-not-call? inner))]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match func
          [(AstExpr.Var name)
            (and
              (string.string-eq (intern-str name) "not")
              (lint-single-arg-call? args))]
          [_ false]))]
    [(AstExpr.Unary (AstUnNot) _) true]
    [_ false]))

(define (lint-return-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-return-expr? inner))]
    [(AstExpr.Return _) true]
    [_ false]))

(define (lint-expr-list-has-return? [exprs : AstExprList]) : bool
  (match exprs
    [(AstExprList.Nil) false]
    [(AstExprList.Cons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if (lint-return-expr? head)
          true
          (lint-expr-list-has-return? rest)))]))

(define (lint-return-branch? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-return-branch? inner))]
    [(AstExpr.Return _) true]
    [(AstExpr.Begin exprs) (lint-expr-list-has-return? exprs)]
    [_ false]))

(define (lint-side-effect-branch? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-side-effect-branch? inner))]
    [(AstExpr.Set _ _) true]
    [(AstExpr.ArraySet _ _ _) true]
    [(AstExpr.ArrayPush _ _) true]
    [(AstExpr.StructSet _ _ _) true]
    [(AstExpr.Begin exprs) (lint-expr-list-has-side-effect? exprs)]
    [_ false]))

(define (lint-expr-list-has-side-effect? [exprs : AstExprList]) : bool
  (match exprs
    [(AstExprList.Nil) false]
    [(AstExprList.Cons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if (lint-side-effect-branch? head)
          true
          (lint-expr-list-has-side-effect? rest)))]))

;: Sentinel span for a finding whose AST node carried no source location (a
;: synthesized or in-memory expression). Parsed ladders carry the span from
;: their `AstExpr.Spanned` wrapper instead.
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

(define (lint-single-begin-finding [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-single-begin-id))
    (lint-rule-single-begin-id)
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

(define (lint-redundant-divergence-padding-finding [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-redundant-divergence-padding-id))
    (lint-rule-redundant-divergence-padding-id)
    0
    span))

(define (lint-dead-code-finding [name : String] [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (string.string-append
      "dead code: top-level declaration "
      (string.string-append
        name
        " is unreachable from package entry/test roots"))
    (lint-rule-dead-code-id)
    0
    span))

(define (lint-unused-assignment-finding [name : String] [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (string.string-append
      "unused assignment: value assigned to "
      (string.string-append name " is overwritten before it is read"))
    (lint-rule-unused-assignment-id)
    0
    span))

(define (lint-copy-on-update-struct-finding
  [name : String]
  [field : String]
  [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (string.string-append
      "copy-on-update struct mutation: "
      (string.string-append
        name
        (string.string-append
          " rebuilds the same struct to change field "
          (string.string-append field "; use in-place field assignment"))))
    (lint-rule-copy-on-update-struct-id)
    1
    span))

(define (lint-unused-variable-finding [name : String] [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (string.string-append
      "unused variable: "
      (string.string-append name " is never used"))
    (lint-rule-unused-variable-id)
    0
    span))

(define (lint-unused-unsafe-finding [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-unused-unsafe-id))
    (lint-rule-unused-unsafe-id)
    0
    span))

(define (lint-redundant-function-name-finding
  [module-name : String]
  [name : String]
  [span : AstSourceSpan]) : LintFinding
  (let
    [module-len : i64 (string.string-length module-name)]
    [name-len : i64 (string.string-length name)]
    [short-name : String
      (if (> name-len (+ module-len 1))
        (string.substring name (+ module-len 1) (- name-len (+ module-len 1)))
        name)]
    (LintFinding
      (string.string-append
        "redundant function name: "
        (string.string-append
          name
          (string.string-append
            " repeats module prefix "
            (string.string-append
              module-name
              (string.string-append "; use " short-name)))))
      (lint-rule-redundant-function-name-id)
      0
      span)))

(define (lint-no-effect-span [expr : AstExpr]) : AstSourceSpan
  (match expr
    [(AstExpr.Spanned _ span) span]
    [_ (lint-no-span)]))

(define (lint-terminal-callee-name? [text : String]) : bool
  (or
    (string.string-eq text "panic")
    (string.string-eq text "error")
    (string.string-eq text "io.panic")
    (string.string-eq text "io.error")
    (string.string-eq text "stdlib.io.panic")
    (string.string-eq text "stdlib.io.error")
    (string.string-eq text "stdlib/io.panic")
    (string.string-eq text "stdlib/io.error")))

(define (lint-terminal-callee? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-terminal-callee? inner))]
    [(AstExpr.Var name)
      (let
        [text : String (intern-str name)]
        (lint-terminal-callee-name? text))]
    [_ false]))

(define (lint-terminal-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(AstExpr.Ann inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(AstExpr.Cast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(AstExpr.Return _) true]
    [(AstExpr.Call func-box _)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lint-terminal-callee? func))]
    [_ false]))

(define (lint-diverging-call-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-diverging-call-expr? inner))]
    [(AstExpr.Ann inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-diverging-call-expr? inner))]
    [(AstExpr.Cast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-diverging-call-expr? inner))]
    [(AstExpr.Call func-box _)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lint-terminal-callee? func))]
    [_ false]))

(define (lint-add-redundant-divergence-padding
  [head : AstExpr]
  [rest : AstExprList]
  [acc : LintFindings]) : LintFindings
  (match rest
    [(AstExprList.Nil) acc]
    [_
      (if (lint-diverging-call-expr? head)
        (lint-findings-add
          (lint-redundant-divergence-padding-finding (lint-no-effect-span head))
          acc)
        acc)]))

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
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(AstExpr.Literal lit) (lint-no-effect-pure-literal? lit)]
    [(AstExpr.Var _) true]
    [(AstExpr.TypeLiteral _) true]
    [(AstExpr.Binary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (and
          (lint-no-effect-pure-binop? op)
          (lint-no-effect-pure-expr? left)
          (lint-no-effect-pure-expr? right)))]
    [(AstExpr.Unary _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(AstExpr.Ann inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(AstExpr.Cast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(AstExpr.PtrNull _) true]
    [_ false]))

(define (lint-deprecated-string-concat-name? [name : String]) : bool
  (or
    (string.string-eq name "string-append")
    (string.string-eq name "string.string-append")
    (string.string-eq name "string-concat")
    (string.string-eq name "string.string-concat")
    (string.string-eq name "string-concat3")
    (string.string-eq name "string.string-concat3")
    (string.string-eq name "string-concat4")
    (string.string-eq name "string.string-concat4")
    (string.string-eq name "string-concat5")
    (string.string-eq name "string.string-concat5")))

(define (lint-deprecated-string-concat-loop-form? [name : String]) : bool
  (or
    (string.string-eq name "while")
    (string.string-eq name "foreach")
    (string.string-eq name "spmd-reduce")
    (string.string-eq name "spmd-scan")
    (string.string-eq name "spmd-shuffle")))

(define (lint-token-name [tok : token.Token]) : String
  (if (= (token.tag tok) (token.tag-sym))
    (token.sym tok)
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
  (if (or
    (string.string-eq name "and")
    (string.string-eq name "core/and")
    (string.string-eq name "core.and")
    (string.string-eq name "stdlib.core_macros.and"))
    "and"
    (if (or
      (string.string-eq name "or")
      (string.string-eq name "core/or")
      (string.string-eq name "core.or")
      (string.string-eq name "stdlib.core_macros.or"))
      "or"
      "")))

(define (lint-and-or-func-op [func : AstExpr]) : String
  (match func
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-and-or-func-op inner))]
    [(AstExpr.Var name) (lint-and-or-op-name (intern-str name))]
    [_ ""]))

(define (lint-str-cat-func? [func : AstExpr]) : bool
  (match func
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-str-cat-func? inner))]
    [(AstExpr.Var name) (string.string-eq (intern-str name) "str-cat")]
    [_ false]))

(define (lint-literal-render [lit : AstLiteral]) : String
  (match lit
    [(AstLitInt value text)
      (if (> (string.string-length text) 0)
        text
        (string.int->string value))]
    [(AstLitFloat value) value]
    [(AstLitBool value)
      (if value
        "true"
        "false")]
    [(AstLitString value)
      (string.string-append "\"" (string.string-append value "\""))]
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
  (if (string.string-eq tail "")
    head
    (string.string-append head (string.string-append " " tail))))

(define (lint-expr-list-render [exprs : AstExprList]) : String
  (match exprs
    [(AstExprList.Nil) ""]
    [(AstExprList.Cons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (lint-render-args-join
          (lint-expr-render head-expr)
          (lint-expr-list-render rest)))]))

(define (lint-parenthesized-call-render [callee : String] [args : String]) : String
  (if (string.string-eq args "")
    (string.string-append "(" (string.string-append callee ")"))
    (string.string-append
      "("
      (string.string-append
        callee
        (string.string-append " " (string.string-append args ")"))))))

(define (lint-expr-render [expr : AstExpr]) : String
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-expr-render inner))]
    [(AstExpr.Var name) (intern-str name)]
    [(AstExpr.Literal lit) (lint-literal-render lit)]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lint-parenthesized-call-render
          (lint-expr-render func)
          (lint-expr-list-render args)))]
    [(AstExpr.Binary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (lint-parenthesized-call-render
          (lint-bin-op-render op)
          (lint-render-args-join
            (lint-expr-render left)
            (lint-expr-render right))))]
    [(AstExpr.Unary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-parenthesized-call-render
          (lint-un-op-render op)
          (lint-expr-render inner)))]
    [_ "<expr>"]))

(define (lint-and-or-call-kind? [op : String] [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-and-or-call-kind? op inner))]
    [(AstExpr.Call func-box _)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (string.string-eq (lint-and-or-func-op func) op))]
    [_ false]))

(define (lint-and-or-args-have-kind? [op : String] [args : AstExprList]) : bool
  (match args
    [(AstExprList.Nil) false]
    [(AstExprList.Cons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if (lint-and-or-call-kind? op head-expr)
          true
          (lint-and-or-args-have-kind? op rest)))]))

(define (lint-str-cat-call? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-str-cat-call? inner))]
    [(AstExpr.Call func-box _)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lint-str-cat-func? func))]
    [_ false]))

(define (lint-str-cat-args-have-nested? [args : AstExprList]) : bool
  (match args
    [(AstExprList.Nil) false]
    [(AstExprList.Cons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if (lint-str-cat-call? head-expr)
          true
          (lint-str-cat-args-have-nested? rest)))]))

(define (lint-cascading-and-or-flat-arg-render [op : String] [expr : AstExpr]) : String
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-cascading-and-or-flat-arg-render op inner))]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (if (string.string-eq (lint-and-or-func-op func) op)
          (lint-cascading-and-or-flat-args-render op args)
          (lint-expr-render expr)))]
    [_ (lint-expr-render expr)]))

(define (lint-cascading-and-or-flat-args-render
  [op : String]
  [args : AstExprList]) : String
  (match args
    [(AstExprList.Nil) ""]
    [(AstExprList.Cons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (lint-render-args-join
          (lint-cascading-and-or-flat-arg-render op head-expr)
          (lint-cascading-and-or-flat-args-render op rest)))]))

(define (lint-cascading-and-or-flat-arg-count [op : String] [expr : AstExpr]) : i64
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-cascading-and-or-flat-arg-count op inner))]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (if (string.string-eq (lint-and-or-func-op func) op)
          (lint-cascading-and-or-flat-arg-count-list op args)
          1))]
    [_ 1]))

(define (lint-cascading-and-or-flat-arg-count-list
  [op : String]
  [args : AstExprList]) : i64
  (match args
    [(AstExprList.Nil) 0]
    [(AstExprList.Cons head rest)
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
    (string.string-append
      "cascading "
      (string.string-append
        op
        (string.string-append
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
  [tok : token.SpannedToken]
  [name : String]) : AstSourceSpan
  (AstSourceSpan
    (token.spanned-token-line tok)
    (token.spanned-token-col tok)
    (token.spanned-token-line tok)
    (+ (token.spanned-token-col tok) (string.string-length name))))

(define (lint-deprecated-string-concat-scan
  [source : String]
  [acc : LintFindings]) : LintFindings
  (match (lex-spanned-result source)
    [(ResultSpannedTokens.Err _) acc]
    [(ResultSpannedTokens.Ok toks)
      (let
        [i : i64 0]
        [done : bool false]
        [depth : i64 0]
        [loop-depth : i64 0]
        [concat-depth : i64 0]
        [stack-cap : i64 (+ (string.string-length source) 2)]
        [loop-stack : (Array bool) (make-array bool stack-cap)]
        [concat-stack : (Array bool) (make-array bool stack-cap)]
        [findings : LintFindings acc]
        (begin
          (while (not done)
            (begin
              (let
                [spanned : token.SpannedToken (array-ref toks i)]
                [tok : token.Token (token.spanned-token-tok spanned)]
                [tag : i64 (token.tag tok)]
                (cond
                  [(= tag (token.tag-end)) (set! done true)]
                  [(= tag (token.tag-lparen))
                    (let
                      [head-spanned : token.SpannedToken
                        (array-ref toks (+ i 1))]
                      [head : token.Token
                        (token.spanned-token-tok head-spanned)]
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
                  [(= tag (token.tag-rparen))
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
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (if (> prefix-len text-len)
      false
      (let
        [idx : i64 0]
        [ok : bool true]
        (begin
          (while (and ok (< idx prefix-len))
            (if (= (string.string-ref text idx) (string.string-ref prefix idx))
              (set! idx (+ idx 1))
              (set! ok false)))
          ok)))))

(define (lint-name-qualified-by-separator?
  [name : String]
  [qualifier : String]
  [separator : char]) : bool
  (let
    [name-len : i64 (string.string-length name)]
    [qualifier-len : i64 (string.string-length qualifier)]
    (cond
      [(<= qualifier-len 0) false]
      [(<= name-len qualifier-len) false]
      [(not (lint-string-prefix? name qualifier)) false]
      [else (= (string.string-ref name qualifier-len) separator)])))

(define (lint-name-qualified-by? [name : String] [qualifier : String]) : bool
  (if (lint-name-qualified-by-separator? name qualifier '.')
    true
    (lint-name-qualified-by-separator? name qualifier '/')))

(define (lint-name-self-alias-import?
  [name : String]
  [alias : String]
  [module-name : String]) : bool
  (let
    [module-n : i64 (string.string-length module-name)]
    [alias-n : i64 (string.string-length alias)]
    [start : i64 (- module-n alias-n)]
    (and
      (string.string-eq name alias)
      (>= start 0)
      (string.string-eq (string.substring module-name start alias-n) alias)
      (or
        (= start 0)
        (string.char-eq (string.string-ref module-name (- start 1)) '.')))))

(define (lint-name-uses-import?
  [name : String]
  [alias : String]
  [module-name : String]) : bool
  (if (lint-name-qualified-by? name alias)
    true
    (if (lint-name-qualified-by? name module-name)
      true
      (lint-name-self-alias-import? name alias module-name))))

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
    [(AstMaybeType.No) false]
    [(AstMaybeType.Some ty) (lint-type-uses-import? ty alias module-name)]))

(define (lint-type-list-uses-import?
  [types : AstTypeList]
  [alias : String]
  [module-name : String]) : bool
  (match types
    [(AstTypeList.Nil) false]
    [(AstTypeList.Cons head rest)
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
    [(AstType.I64) false]
    [(AstType.I32) false]
    [(AstType.I16) false]
    [(AstType.I8) false]
    [(AstType.U64) false]
    [(AstType.U32) false]
    [(AstType.U16) false]
    [(AstType.U8) false]
    [(AstType.F64) false]
    [(AstType.F32) false]
    [(AstType.Bool) false]
    [(AstType.Char) false]
    [(AstType.String) false]
    [(AstType.Str) false]
    [(AstType.Bytes) false]
    [(AstType.Unit) false]
    [(AstType.Never) false]
    [(AstType.Expr) false]
    [(AstType.ExprList) false]
    [(AstType.Func args ret)
      (if (lint-type-list-uses-import? (box-get args) alias module-name)
        true
        (lint-type-id-uses-import? ret alias module-name))]
    [(AstType.Tuple items)
      (lint-type-list-uses-import? (box-get items) alias module-name)]
    [(AstType.Array elem _) (lint-type-id-uses-import? elem alias module-name)]
    [(AstType.DynArray elem) (lint-type-id-uses-import? elem alias module-name)]
    [(AstType.Box elem) (lint-type-id-uses-import? elem alias module-name)]
    [(AstType.Region _ inner)
      (lint-type-id-uses-import? inner alias module-name)]
    [(AstType.Ref _ inner) (lint-type-id-uses-import? inner alias module-name)]
    [(AstType.MutRef _ inner)
      (lint-type-id-uses-import? inner alias module-name)]
    [(AstType.Enum name) (lint-name-id-uses-import? name alias module-name)]
    [(AstType.EnumArgs name _)
      (lint-name-id-uses-import? name alias module-name)]
    [(AstType.Struct name) (lint-name-id-uses-import? name alias module-name)]
    [(AstType.StructArgs name _)
      (lint-name-id-uses-import? name alias module-name)]
    [(AstType.Var name) (lint-name-id-uses-import? name alias module-name)]
    [(AstType.VarArgs name _)
      (lint-name-id-uses-import? name alias module-name)]
    [(AstType.Ptr inner) (lint-type-id-uses-import? inner alias module-name)]
    [(AstType.MutPtr inner) (lint-type-id-uses-import? inner alias module-name)]))

(define (lint-param-list-uses-import?
  [params : AstParamList]
  [alias : String]
  [module-name : String]) : bool
  (match params
    [(AstParamList.Nil) false]
    [(AstParamList.Cons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam.Param _ ty _)
            (if (lint-type-uses-import? ty alias module-name)
              true
              (lint-param-list-uses-import? rest alias module-name))]))]))

(define (lint-macro-param-list-uses-import?
  [params : AstMacroParamList]
  [alias : String]
  [module-name : String]) : bool
  (match params
    [(AstMacroParamList.Nil) false]
    [(AstMacroParamList.Cons param rest)
      (let
        [rest : AstMacroParamList (box-get rest)]
        (match param
          [(AstMacroParam.Param _ ty _)
            (if (lint-type-uses-import? ty alias module-name)
              true
              (lint-macro-param-list-uses-import? rest alias module-name))]))]))

(define (lint-pattern-list-uses-import?
  [patterns : AstPatternList]
  [alias : String]
  [module-name : String]) : bool
  (match patterns
    [(AstPatternList.Nil) false]
    [(AstPatternList.Cons head rest)
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
    [(AstPattern.Var _ maybe-ty)
      (lint-maybe-type-uses-import? maybe-ty alias module-name)]
    [(AstPattern.Tuple items)
      (lint-pattern-list-uses-import? (box-get items) alias module-name)]
    [(AstPattern.Wildcard) false]
    [(AstPattern.Binding _) false]
    [(AstPattern.Variant name items)
      (if (lint-name-id-uses-import? name alias module-name)
        true
        (lint-pattern-list-uses-import? (box-get items) alias module-name))]
    [(AstPattern.Literal _) false]))

(define (lint-unused-unsafe-candidate-sentinel?
  [alias : String]
  [module-name : String]) : bool
  (and
    (string.string-eq alias "__tl_lint_unused_unsafe_candidate")
    (string.string-eq module-name "")))

(define (lint-requires-enclosing-unsafe-sentinel?
  [alias : String]
  [module-name : String]) : bool
  (and
    (string.string-eq alias "__tl_lint_requires_enclosing_unsafe")
    (string.string-eq module-name "")))

(define (lint-expr-list-requires-enclosing-unsafe? [exprs : AstExprList]) : bool
  (lint-expr-list-uses-import? exprs "__tl_lint_requires_enclosing_unsafe" ""))

(define (lint-expr-list-uses-import?
  [exprs : AstExprList]
  [alias : String]
  [module-name : String]) : bool
  (match exprs
    [(AstExprList.Nil) false]
    [(AstExprList.Cons head rest)
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
    [(AstLetBindingList.Nil) false]
    [(AstLetBindingList.Cons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding.Binding _ maybe-ty init)
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
    [(AstMatchArmList.Nil) false]
    [(AstMatchArmList.Cons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm.Arm pattern body)
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
    [(AstResourceBindingList.Nil) false]
    [(AstResourceBindingList.Cons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding.Binding _ init cleanup)
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
    [(AstExpr.Spanned inner-box _)
      (lint-expr-uses-import? (ast-node-get inner-box) alias module-name)]
    [(AstExpr.Literal _) false]
    [(AstExpr.Var name) (lint-name-id-uses-import? name alias module-name)]
    [(AstExpr.Binary _ left right)
      (if (lint-expr-uses-import? (ast-node-get left) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get right) alias module-name))]
    [(AstExpr.Unary _ inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.Call func args)
      (if (lint-expr-uses-import? (ast-node-get func) alias module-name)
        true
        (lint-expr-list-uses-import? args alias module-name))]
    [(AstExpr.If cond then-branch else-branch)
      (if (lint-expr-uses-import? (ast-node-get cond) alias module-name)
        true
        (if (lint-expr-uses-import?
          (ast-node-get then-branch)
          alias
          module-name)
          true
          (lint-expr-uses-import? (ast-node-get else-branch) alias module-name)))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body)
          (if (lint-let-bindings-use-import? bindings alias module-name)
            true
            (lint-expr-uses-import? (ast-node-get body) alias module-name))])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda params ret body)
          (if (lint-param-list-uses-import? params alias module-name)
            true
            (if (lint-maybe-type-uses-import? ret alias module-name)
              true
              (lint-expr-uses-import? (ast-node-get body) alias module-name)))])]
    [(AstExpr.Tuple exprs)
      (lint-expr-list-uses-import? exprs alias module-name)]
    [(AstExpr.TupleRef tuple _)
      (lint-expr-uses-import? (ast-node-get tuple) alias module-name)]
    [(AstExpr.Array exprs)
      (lint-expr-list-uses-import? exprs alias module-name)]
    [(AstExpr.MakeArray elem len)
      (if (lint-type-uses-import? elem alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get len) alias module-name))]
    [(AstExpr.ArrayRef array index)
      (if (lint-expr-uses-import? (ast-node-get array) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get index) alias module-name))]
    [(AstExpr.ArraySet array index value)
      (if (lint-expr-uses-import? (ast-node-get array) alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get index) alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get value) alias module-name)))]
    [(AstExpr.ArrayPush array value)
      (if (lint-expr-uses-import? (ast-node-get array) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get value) alias module-name))]
    [(AstExpr.StringRef text index)
      (if (lint-expr-uses-import? (ast-node-get text) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get index) alias module-name))]
    [(AstExpr.While cond body)
      (if (lint-expr-uses-import? (ast-node-get cond) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get body) alias module-name))]
    [(AstExpr.Begin exprs)
      (lint-expr-list-uses-import? exprs alias module-name)]
    [(AstExpr.Unsafe exprs)
      (cond
        [(lint-requires-enclosing-unsafe-sentinel? alias module-name) false]
        [(lint-unused-unsafe-candidate-sentinel? alias module-name)
          (if (lint-expr-list-requires-enclosing-unsafe? exprs)
            (lint-expr-list-uses-import? exprs alias module-name)
            true)]
        [else (lint-expr-list-uses-import? exprs alias module-name)])]
    [(AstExpr.Set target value)
      (if (lint-name-id-uses-import? target alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get value) alias module-name))]
    [(AstExpr.Ann inner ty)
      (if (lint-expr-uses-import? (ast-node-get inner) alias module-name)
        true
        (lint-type-uses-import? ty alias module-name))]
    [(AstExpr.Cast inner ty)
      (if (lint-expr-uses-import? (ast-node-get inner) alias module-name)
        true
        (lint-type-uses-import? ty alias module-name))]
    [(AstExpr.Borrow _ _ place)
      (lint-expr-uses-import? (ast-node-get place) alias module-name)]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (if (lint-expr-uses-import?
            (ast-node-get scrutinee)
            alias
            module-name)
            true
            (lint-match-arms-use-import? arms alias module-name))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach _ index-ty start end body)
          (cond
            [(lint-type-uses-import? index-ty alias module-name) true]
            [(lint-expr-uses-import? (ast-node-get start) alias module-name)
              true]
            [(lint-expr-uses-import? (ast-node-get end) alias module-name) true]
            [else
              (lint-expr-uses-import? (ast-node-get body) alias module-name)])])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce _ _ index-ty start end init value)
          (cond
            [(lint-type-uses-import? index-ty alias module-name) true]
            [(lint-expr-uses-import? (ast-node-get start) alias module-name)
              true]
            [(lint-expr-uses-import? (ast-node-get end) alias module-name) true]
            [(lint-expr-uses-import? (ast-node-get init) alias module-name)
              true]
            [else
              (lint-expr-uses-import? (ast-node-get value) alias module-name)])])]
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan _ _ index-ty start end _ prefix-ty init value body)
          (cond
            [(lint-type-uses-import? index-ty alias module-name) true]
            [(lint-type-uses-import? prefix-ty alias module-name) true]
            [(lint-expr-uses-import? (ast-node-get start) alias module-name)
              true]
            [(lint-expr-uses-import? (ast-node-get end) alias module-name) true]
            [(lint-expr-uses-import? (ast-node-get init) alias module-name)
              true]
            [(lint-expr-uses-import? (ast-node-get value) alias module-name)
              true]
            [else
              (lint-expr-uses-import? (ast-node-get body) alias module-name)])])]
    [(AstExpr.SpmdBroadcast value lane)
      (if (lint-expr-uses-import? (ast-node-get value) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get lane) alias module-name))]
    [(AstExpr.SpmdShuffle value lane)
      (if (lint-expr-uses-import? (ast-node-get value) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get lane) alias module-name))]
    [(AstExpr.StructGet receiver _)
      (lint-expr-uses-import? (ast-node-get receiver) alias module-name)]
    [(AstExpr.StructSet receiver _ value)
      (if (lint-expr-uses-import? (ast-node-get receiver) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get value) alias module-name))]
    [(AstExpr.WithRegion _ body)
      (lint-expr-list-uses-import? body alias module-name)]
    [(AstExpr.WithEscape scratch body)
      (if (lint-expr-uses-import? (ast-node-get scratch) alias module-name)
        true
        (lint-expr-list-uses-import? body alias module-name))]
    [(AstExpr.WithScratch body)
      (lint-expr-list-uses-import? body alias module-name)]
    [(AstExpr.InArena arena body)
      (if (lint-expr-uses-import? (ast-node-get arena) alias module-name)
        true
        (lint-expr-list-uses-import? body alias module-name))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (if (lint-resource-bindings-use-import? bindings alias module-name)
            true
            (lint-expr-list-uses-import? body alias module-name))])]
    [(AstExpr.Box inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.BoxGet inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.BoxTake inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.BoxSet inner value)
      (if (lint-expr-uses-import? (ast-node-get inner) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get value) alias module-name))]
    [(AstExpr.TypeLiteral ty) (lint-type-uses-import? ty alias module-name)]
    [(AstExpr.Init maybe-ty)
      (lint-maybe-type-uses-import? maybe-ty alias module-name)]
    [(AstExpr.Comptime inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.Quote inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.Quasiquote inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.Unquote inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.UnquoteSplicing inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.BracketClause items)
      (lint-expr-list-uses-import? items alias module-name)]
    [(AstExpr.Try inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.Return inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.PtrNull ty) (lint-type-uses-import? ty alias module-name)]
    [(AstExpr.PtrNullCheck inner)
      (lint-expr-uses-import? (ast-node-get inner) alias module-name)]
    [(AstExpr.PtrAddrOf place)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get place) alias module-name))]
    [(AstExpr.PtrRead ptr)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get ptr) alias module-name))]
    [(AstExpr.PtrWrite ptr value)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get ptr) alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get value) alias module-name)))]
    [(AstExpr.PtrOffset ptr offset)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get ptr) alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get offset) alias module-name)))]
    [(AstExpr.PtrCast ptr ty)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get ptr) alias module-name)
          true
          (lint-type-uses-import? ty alias module-name)))]
    [(AstExpr.PtrToInt ptr)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get ptr) alias module-name))]
    [(AstExpr.IntToPtr value ty)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get value) alias module-name)
          true
          (lint-type-uses-import? ty alias module-name)))]
    [(AstExpr.StringData inner)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get inner) alias module-name))]
    [(AstExpr.StringFromBytes ptr len)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (if (lint-expr-uses-import? (ast-node-get ptr) alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get len) alias module-name)))]
    [(AstExpr.ArrayData inner)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get inner) alias module-name))]
    [(AstExpr.BinaryData _) false]
    [(AstExpr.SpmdProgramIndex) false]
    [(AstExpr.SpmdProgramCount) false]
    [(AstExpr.ProgramArgc) false]
    [(AstExpr.ProgramArgv) false]
    [(AstExpr.ProgramEnvp) false]
    [(AstExpr.CpuIdEax leaf subleaf)
      (if (lint-expr-uses-import? (ast-node-get leaf) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get subleaf) alias module-name))]
    [(AstExpr.CpuIdEbx leaf subleaf)
      (if (lint-expr-uses-import? (ast-node-get leaf) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get subleaf) alias module-name))]
    [(AstExpr.CpuIdEcx leaf subleaf)
      (if (lint-expr-uses-import? (ast-node-get leaf) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get subleaf) alias module-name))]
    [(AstExpr.CpuIdEdx leaf subleaf)
      (if (lint-expr-uses-import? (ast-node-get leaf) alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get subleaf) alias module-name))]
    [(AstExpr.Xgetbv index)
      (lint-expr-uses-import? (ast-node-get index) alias module-name)]
    [(AstExpr.Syscall args)
      (if (lint-requires-enclosing-unsafe-sentinel? alias module-name)
        true
        (lint-expr-list-uses-import? args alias module-name))]))

(define (lint-extern-abi-uses-import?
  [abi : AstExternAbi]
  [alias : String]
  [module-name : String]) : bool
  (match abi
    [(AstExternAbi.C) false]
    [(AstExternAbi.CVarargsOpen) false]
    [(AstExternAbi.CVarargsTyped tail-ty)
      (lint-type-uses-import? tail-ty alias module-name)]))

(define (lint-extern-metadata-uses-import?
  [meta : AstExternMetadata]
  [alias : String]
  [module-name : String]) : bool
  (match meta
    [(AstExternMetadata.Metadata abi _ _ _)
      (lint-extern-abi-uses-import? abi alias module-name)]))

(define (lint-field-cleanup-uses-import?
  [cleanup : AstFieldCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(AstFieldCleanup.No) false]
    [(AstFieldCleanup.Fn name)
      (lint-name-id-uses-import? name alias module-name)]
    [(AstFieldCleanup.Owned) false]))

(define (lint-field-def-list-uses-import?
  [fields : AstFieldDefList]
  [alias : String]
  [module-name : String]) : bool
  (match fields
    [(AstFieldDefList.Nil) false]
    [(AstFieldDefList.Cons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef.Def _ ty cleanup)
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
    [(AstStructCleanup.No) false]
    [(AstStructCleanup.Fn name)
      (lint-name-id-uses-import? name alias module-name)]))

(define (lint-enum-cleanup-uses-import?
  [cleanup : AstEnumCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(AstEnumCleanup.No) false]
    [(AstEnumCleanup.Fn name)
      (lint-name-id-uses-import? name alias module-name)]))

(define (lint-variant-payload-cleanup-uses-import?
  [cleanup : AstVariantPayloadCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(AstVariantPayloadCleanup.No) false]
    [(AstVariantPayloadCleanup.Fn name)
      (lint-name-id-uses-import? name alias module-name)]
    [(AstVariantPayloadCleanup.Owned) false]))

(define (lint-variant-payload-cleanup-list-uses-import?
  [items : AstVariantPayloadCleanupList]
  [alias : String]
  [module-name : String]) : bool
  (match items
    [(AstVariantPayloadCleanupList.Nil) false]
    [(AstVariantPayloadCleanupList.Cons cleanup rest)
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
    [(AstVariantDefList.Nil) false]
    [(AstVariantDefList.Cons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef.Def _ payloads cleanups)
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
    [(AstDispatchVariantList.Nil) false]
    [(AstDispatchVariantList.Cons variant rest)
      (let
        [rest : AstDispatchVariantList (box-get rest)]
        (match variant
          [(AstDispatchVariant.Variant _ name)
            (if (lint-name-uses-import? name alias module-name)
              true
              (lint-dispatch-variant-list-uses-import? rest alias module-name))]))]))

(define (lint-generated-decl-meta-uses-import?
  [meta : AstGeneratedDeclMeta]
  [alias : String]
  [module-name : String]) : bool
  (match meta
    [(AstGeneratedDeclMeta.No) false]
    [(AstGeneratedDeclMeta.Some _ _ args _)
      (lint-expr-list-uses-import? args alias module-name)]))

(define (lint-decl-uses-import?
  [decl : AstDecl]
  [alias : String]
  [module-name : String]) : bool
  (match decl
    [(AstDecl.Module _) false]
    [(AstDecl.Def _ maybe-ty body)
      (if (lint-maybe-type-uses-import? maybe-ty alias module-name)
        true
        (lint-expr-uses-import? (ast-node-get body) alias module-name))]
    [(AstDecl.DefFn _ params ret body _)
      (if (lint-param-list-uses-import? params alias module-name)
        true
        (if (lint-type-uses-import? ret alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get body) alias module-name)))]
    [(AstDecl.DefMacro _ params ret body)
      (if (lint-macro-param-list-uses-import? params alias module-name)
        true
        (if (lint-type-uses-import? ret alias module-name)
          true
          (lint-expr-uses-import? (ast-node-get body) alias module-name)))]
    [(AstDecl.Extern _ _ meta ty)
      (if (lint-extern-metadata-uses-import? meta alias module-name)
        true
        (lint-type-uses-import? ty alias module-name))]
    [(AstDecl.DefEnum _ cleanup variants)
      (if (lint-enum-cleanup-uses-import? cleanup alias module-name)
        true
        (lint-variant-def-list-uses-import? variants alias module-name))]
    [(AstDecl.DefEnumLifetimes _ _ cleanup variants)
      (if (lint-enum-cleanup-uses-import? cleanup alias module-name)
        true
        (lint-variant-def-list-uses-import? variants alias module-name))]
    [(AstDecl.DefStruct _ _ cleanup fields)
      (if (lint-struct-cleanup-uses-import? cleanup alias module-name)
        true
        (lint-field-def-list-uses-import? fields alias module-name))]
    [(AstDecl.DefStructLifetimes _ _ _ cleanup fields)
      (if (lint-struct-cleanup-uses-import? cleanup alias module-name)
        true
        (lint-field-def-list-uses-import? fields alias module-name))]
    [(AstDecl.Import
        (AstImportSpec.Spec (AstImportKind.Macro call-expr _) _ _ _ _))
      (lint-expr-uses-import? (ast-node-get call-expr) alias module-name)]
    [(AstDecl.Import
        (AstImportSpec.Spec (AstImportKind.MacroDecls call-expr _) _ _ _ _))
      (lint-expr-uses-import? (ast-node-get call-expr) alias module-name)]
    [(AstDecl.Import _) false]
    [(AstDecl.IncludeStr _ _) false]
    [(AstDecl.IncludeBin _ _) false]
    [(AstDecl.DefDispatch _ variants)
      (lint-dispatch-variant-list-uses-import? variants alias module-name)]
    [(AstDecl.Test _ body _)
      (lint-expr-uses-import? (ast-node-get body) alias module-name)]
    [(AstDecl.Unsafe inner)
      (lint-decl-uses-import? (box-get inner) alias module-name)]
    [(AstDecl.ComptimeDecl meta inner)
      (if (lint-generated-decl-meta-uses-import? meta alias module-name)
        true
        (lint-decl-uses-import? (box-get inner) alias module-name))]))

(define (lint-decl-list-uses-import?
  [decls : AstDeclList]
  [alias : String]
  [module-name : String]) : bool
  (match decls
    [(AstDeclList.Nil) false]
    [(AstDeclList.Cons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (if (lint-decl-uses-import? decl alias module-name)
          true
          (lint-decl-list-uses-import? rest alias module-name)))]))

(define (lint-program-has-unused-unsafe-candidate? [program : AstProgram]) : bool
  (match program
    [(AstProgram.Program decls-box)
      (lint-decl-list-uses-import?
        (box-get decls-box)
        "__tl_lint_unused_unsafe_candidate"
        "")]))

(define (lint-underscore-prefixed? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (<= n 0)
      false
      (= (string.string-ref name 0) '_'))))

(define (lint-import-kind-lintable?
  [kind : AstImportKind]
  [expected : AstMaybeModuleName]) : bool
  (match kind
    [(AstImportKind.Module) true]
    ;; Legacy path imports with no explicit module alias still bring
    ;; unqualified names into scope, so skip them until #2453/#2454 remove that
    ;; transitional surface.
    [(AstImportKind.Path)
      (match expected
        [(AstMaybeModuleName.Some _) true]
        [(AstMaybeModuleName.No) false])]
    [(AstImportKind.Macro _ _) false]
    [(AstImportKind.MacroDecls _ _) false]))

(define (lint-unused-import-finding
  [module-name : String]
  [alias : String]
  [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (string.string-append
      "unused import: module alias "
      (string.string-append
        alias
        (string.string-append
          " from "
          (string.string-append module-name " is never referenced"))))
    (lint-rule-unused-import-id)
    0
    span))

(define (lint-redundant-import-alias-finding [span : AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-redundant-import-alias-message)
    (lint-rule-redundant-import-alias-id)
    0
    span))

(define (lint-module-default-alias [module-name : String]) : String
  (let
    [n : i64 (string.string-length module-name)]
    [i : i64 0]
    [start : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (or
            (= (string.string-ref module-name i) '.')
            (= (string.string-ref module-name i) '/'))
            (set! start (+ i 1))
            unit)
          (set! i (+ i 1))))
      (string.substring module-name start (- n start)))))

(define (lint-source-span-end-index [source : String] [span : AstSourceSpan]) : i64
  (let
    [idx : i64
      (lint-source-span-start-index
        source
        (AstSourceSpan
          (struct-get span end-line)
          (struct-get span end-col)
          (struct-get span end-line)
          (struct-get span end-col)))]
    (if (< idx 0)
      (string.string-length source)
      idx)))

(define (lint-source-name-in-range?
  [source : String]
  [name : String]
  [start : i64]
  [limit : i64]) : bool
  (let
    [found : i64 (lint-source-find-name-from source name start)]
    (and (>= found 0) (< found limit))))

(define (lint-import-span-has-explicit-alias?
  [source : String]
  [span : AstSourceSpan]) : bool
  (let
    [start : i64 (lint-source-span-start-index source span)]
    [limit : i64 (lint-source-span-end-index source span)]
    (if (< start 0)
      false
      (or
        (lint-source-name-in-range? source "as" start limit)
        (lint-source-name-in-range? source ":as" start limit)))))

(define (lint-redundant-import-alias-add-if-needed
  [source : String]
  [spec : AstImportSpec]
  [acc : LintFindings]) : LintFindings
  (match spec
    [(AstImportSpec.Spec kind _ expected maybe-alias span)
      (match kind
        [(AstImportKind.Module)
          (match expected
            [(AstMaybeModuleName.No) acc]
            [(AstMaybeModuleName.Some module-name)
              (match maybe-alias
                [(AstMaybeImportAlias.No) acc]
                [(AstMaybeImportAlias.Some alias)
                  (if (and
                    (string.string-eq
                      alias
                      (lint-module-default-alias module-name))
                    (lint-import-span-has-explicit-alias? source span))
                    (lint-findings-add
                      (lint-redundant-import-alias-finding span)
                      acc)
                    acc)])])]
        [_ acc])]))

(define (lint-unused-import-add-if-needed
  [source : String]
  [all-decls : AstDeclList]
  [spec : AstImportSpec]
  [acc : LintFindings]) : LintFindings
  (let
    [acc : LintFindings
      (lint-redundant-import-alias-add-if-needed source spec acc)]
    (match spec
      [(AstImportSpec.Spec kind _ expected maybe-alias span)
        (if (not (lint-import-kind-lintable? kind expected))
          acc
          (match expected
            [(AstMaybeModuleName.No) acc]
            [(AstMaybeModuleName.Some module-name)
              (match maybe-alias
                [(AstMaybeImportAlias.No) acc]
                [(AstMaybeImportAlias.Some alias)
                  (if (lint-underscore-prefixed? alias)
                    acc
                    (if (lint-decl-list-uses-import?
                      all-decls
                      alias
                      module-name)
                      acc
                      (lint-findings-add
                        (lint-unused-import-finding module-name alias span)
                        acc)))])]))])))

(define (lint-unused-imports-in-decl-list
  [source : String]
  [all-decls : AstDeclList]
  [decls : AstDeclList]
  [acc : LintFindings]) : LintFindings
  (match decls
    [(AstDeclList.Nil) acc]
    [(AstDeclList.Cons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (lint-unused-imports-in-decl-list
          source
          all-decls
          rest
          (match decl
            [(AstDecl.Import spec)
              (lint-unused-import-add-if-needed source all-decls spec acc)]
            [_ acc])))]))

(defenum LintNameList
  (Nil)
  (Cons String (Box LintNameList)))

(defstruct LintPendingAssignment
  (name String)
  (span AstSourceSpan))

(defenum LintPendingAssignmentList
  (Nil)
  (Cons LintPendingAssignment (Box LintPendingAssignmentList)))

(defenum LintMaybePendingAssignment
  (No)
  (Some LintPendingAssignment))

(defstruct LintUnusedAssignmentState
  (locals LintNameList)
  (pending LintPendingAssignmentList)
  (findings LintFindings))

(define (lint-name-list-contains? [items : LintNameList] [name : String]) : bool
  (match items
    [(LintNameList.Nil) false]
    [(LintNameList.Cons head rest)
      (if (string.string-eq head name)
        true
        (lint-name-list-contains? (box-get rest) name))]))

(define (lint-name-list-add [items : LintNameList] [name : String]) : LintNameList
  (if (lint-name-list-contains? items name)
    items
    (LintNameList.Cons name (box items))))

(define (lint-param-list-add-locals
  [params : AstParamList]
  [locals : LintNameList]) : LintNameList
  (match params
    [(AstParamList.Nil) locals]
    [(AstParamList.Cons param rest)
      (match param
        [(AstParam.Param name _ _)
          (lint-param-list-add-locals
            (box-get rest)
            (lint-name-list-add locals (intern-str name)))])]))

(define (lint-macro-param-list-add-locals
  [params : AstMacroParamList]
  [locals : LintNameList]) : LintNameList
  (match params
    [(AstMacroParamList.Nil) locals]
    [(AstMacroParamList.Cons param rest)
      (match param
        [(AstMacroParam.Param name _ _)
          (lint-macro-param-list-add-locals
            (box-get rest)
            (lint-name-list-add locals (intern-str name)))])]))

(define (lint-name-list-count [items : LintNameList]) : i64
  (match items
    [(LintNameList.Nil) 0]
    [(LintNameList.Cons _ rest) (+ 1 (lint-name-list-count (box-get rest)))]))

(defstruct LintCopyOnUpdateStructShape
  (name String)
  (fields LintNameList)
  (field-count i64))

(defenum LintCopyOnUpdateStructList
  (Nil)
  (Cons LintCopyOnUpdateStructShape (Box LintCopyOnUpdateStructList)))

(defenum LintCopyOnUpdateMaybeStruct
  (NoStruct)
  (SomeStruct LintCopyOnUpdateStructShape))

(defstruct LintCopyOnUpdateLocal
  (name String)
  (type-name String))

(defenum LintCopyOnUpdateLocalList
  (Nil)
  (Cons LintCopyOnUpdateLocal (Box LintCopyOnUpdateLocalList)))

(defstruct LintCopyOnUpdateArgCheck
  (valid bool)
  (copied i64)
  (changed i64)
  (changed-field String))

(defstruct LintCopyOnUpdateState
  (shapes LintCopyOnUpdateStructList)
  (locals LintCopyOnUpdateLocalList)
  (findings LintFindings))

(define (lint-copy-on-update-struct-find
  [shapes : LintCopyOnUpdateStructList]
  [name : String]) : LintCopyOnUpdateMaybeStruct
  (match shapes
    [(LintCopyOnUpdateStructList.Nil) LintCopyOnUpdateMaybeStruct.NoStruct]
    [(LintCopyOnUpdateStructList.Cons shape rest)
      (if (string.string-eq (struct-get shape name) name)
        (LintCopyOnUpdateMaybeStruct.SomeStruct shape)
        (lint-copy-on-update-struct-find (box-get rest) name))]))

(define (lint-copy-on-update-struct-known-name
  [shapes : LintCopyOnUpdateStructList]
  [name-id : i64]) : String
  (let
    [name : String (intern-str name-id)]
    (match (lint-copy-on-update-struct-find shapes name)
      [(LintCopyOnUpdateMaybeStruct.NoStruct) ""]
      [(LintCopyOnUpdateMaybeStruct.SomeStruct _) name])))

(define (lint-copy-on-update-struct-name-from-type
  [shapes : LintCopyOnUpdateStructList]
  [ty : AstType]) : String
  (match ty
    [(AstType.Struct name) (lint-copy-on-update-struct-known-name shapes name)]
    [(AstType.StructArgs name _)
      (lint-copy-on-update-struct-known-name shapes name)]
    [(AstType.Var name) (lint-copy-on-update-struct-known-name shapes name)]
    [(AstType.VarArgs name _)
      (lint-copy-on-update-struct-known-name shapes name)]
    [_ ""]))

(define (lint-copy-on-update-struct-name-from-maybe-type
  [shapes : LintCopyOnUpdateStructList]
  [maybe-ty : AstMaybeType]) : String
  (match maybe-ty
    [(AstMaybeType.No) ""]
    [(AstMaybeType.Some ty)
      (lint-copy-on-update-struct-name-from-type shapes ty)]))

(define (lint-copy-on-update-local-remove
  [locals : LintCopyOnUpdateLocalList]
  [name : String]) : LintCopyOnUpdateLocalList
  (match locals
    [(LintCopyOnUpdateLocalList.Nil) LintCopyOnUpdateLocalList.Nil]
    [(LintCopyOnUpdateLocalList.Cons local rest)
      (let
        [rest-locals : LintCopyOnUpdateLocalList (box-get rest)]
        (if (string.string-eq (struct-get local name) name)
          (lint-copy-on-update-local-remove rest-locals name)
          (LintCopyOnUpdateLocalList.Cons
            local
            (box (lint-copy-on-update-local-remove rest-locals name)))))]))

(define (lint-copy-on-update-local-add
  [locals : LintCopyOnUpdateLocalList]
  [name : String]
  [type-name : String]) : LintCopyOnUpdateLocalList
  (let
    [without : LintCopyOnUpdateLocalList
      (lint-copy-on-update-local-remove locals name)]
    (if (string.string-eq type-name "")
      without
      (LintCopyOnUpdateLocalList.Cons
        (LintCopyOnUpdateLocal name type-name)
        (box without)))))

(define (lint-copy-on-update-local-type
  [locals : LintCopyOnUpdateLocalList]
  [name : String]) : String
  (match locals
    [(LintCopyOnUpdateLocalList.Nil) ""]
    [(LintCopyOnUpdateLocalList.Cons local rest)
      (if (string.string-eq (struct-get local name) name)
        (struct-get local type-name)
        (lint-copy-on-update-local-type (box-get rest) name))]))

(define (lint-copy-on-update-param-locals
  [params : AstParamList]
  [shapes : LintCopyOnUpdateStructList]
  [locals : LintCopyOnUpdateLocalList]) : LintCopyOnUpdateLocalList
  (match params
    [(AstParamList.Nil) locals]
    [(AstParamList.Cons param rest)
      (match param
        [(AstParam.Param name ty _)
          (lint-copy-on-update-param-locals
            (box-get rest)
            shapes
            (lint-copy-on-update-local-add
              locals
              (intern-str name)
              (lint-copy-on-update-struct-name-from-type shapes ty)))])]))

(define (lint-copy-on-update-macro-param-locals
  [params : AstMacroParamList]
  [shapes : LintCopyOnUpdateStructList]
  [locals : LintCopyOnUpdateLocalList]) : LintCopyOnUpdateLocalList
  (match params
    [(AstMacroParamList.Nil) locals]
    [(AstMacroParamList.Cons param rest)
      (match param
        [(AstMacroParam.Param name ty _)
          (lint-copy-on-update-macro-param-locals
            (box-get rest)
            shapes
            (lint-copy-on-update-local-add
              locals
              (intern-str name)
              (lint-copy-on-update-struct-name-from-type shapes ty)))])]))

(define (lint-copy-on-update-expr-var-name [expr : AstExpr]) : String
  (match expr
    [(AstExpr.Spanned inner _)
      (lint-copy-on-update-expr-var-name (ast-node-get inner))]
    [(AstExpr.Var name) (intern-str name)]
    [_ ""]))

(define (lint-copy-on-update-copied-field?
  [target-name : String]
  [field-name : String]
  [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Spanned inner _)
      (lint-copy-on-update-copied-field?
        target-name
        field-name
        (ast-node-get inner))]
    [(AstExpr.StructGet receiver field)
      (and
        (string.string-eq
          (lint-copy-on-update-expr-var-name (ast-node-get receiver))
          target-name)
        (string.string-eq (intern-str field) field-name))]
    [(AstExpr.Var name)
      (string.string-eq
        (intern-str name)
        (string.string-append target-name (string.string-append "." field-name)))]
    [_ false]))

(define (lint-copy-on-update-arg-check-invalid) : LintCopyOnUpdateArgCheck
  (LintCopyOnUpdateArgCheck false 0 0 ""))

(define (lint-copy-on-update-check-args
  [fields : LintNameList]
  [args : AstExprList]
  [target-name : String]) : LintCopyOnUpdateArgCheck
  (match fields
    [(LintNameList.Nil)
      (match args
        [(AstExprList.Nil) (LintCopyOnUpdateArgCheck true 0 0 "")]
        [_ (lint-copy-on-update-arg-check-invalid)])]
    [(LintNameList.Cons field rest-fields)
      (match args
        [(AstExprList.Nil) (lint-copy-on-update-arg-check-invalid)]
        [(AstExprList.Cons arg rest-args)
          (let
            [tail : LintCopyOnUpdateArgCheck
              (lint-copy-on-update-check-args
                (box-get rest-fields)
                (box-get rest-args)
                target-name)]
            (if (not (struct-get tail valid))
              tail
              (if (lint-copy-on-update-copied-field?
                target-name
                field
                (ast-node-get arg))
                (LintCopyOnUpdateArgCheck
                  true
                  (+ (struct-get tail copied) 1)
                  (struct-get tail changed)
                  (struct-get tail changed-field))
                (LintCopyOnUpdateArgCheck
                  true
                  (struct-get tail copied)
                  (+ (struct-get tail changed) 1)
                  (if (= (struct-get tail changed) 0)
                    field
                    (struct-get tail changed-field))))))])]))

(define (lint-copy-on-update-state-with
  [state : LintCopyOnUpdateState]
  [locals : LintCopyOnUpdateLocalList]
  [findings : LintFindings]) : LintCopyOnUpdateState
  (LintCopyOnUpdateState (struct-get state shapes) locals findings))

(define (lint-copy-on-update-add-finding
  [state : LintCopyOnUpdateState]
  [name : String]
  [field : String]
  [span : AstSourceSpan]) : LintCopyOnUpdateState
  (lint-copy-on-update-state-with
    state
    (struct-get state locals)
    (lint-findings-add
      (lint-copy-on-update-struct-finding name field span)
      (struct-get state findings))))

(define (lint-copy-on-update-add-set-if-needed
  [target : i64]
  [value : AstExpr]
  [span : AstSourceSpan]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (let
    [target-name : String (intern-str target)]
    [type-name : String
      (lint-copy-on-update-local-type (struct-get state locals) target-name)]
    (if (or
      (string.string-eq type-name "")
      (lint-underscore-prefixed? target-name))
      state
      (match value
        [(AstExpr.Spanned inner _)
          (lint-copy-on-update-add-set-if-needed
            target
            (ast-node-get inner)
            span
            state)]
        [(AstExpr.Ann inner _)
          (lint-copy-on-update-add-set-if-needed
            target
            (ast-node-get inner)
            span
            state)]
        [(AstExpr.Cast inner _)
          (lint-copy-on-update-add-set-if-needed
            target
            (ast-node-get inner)
            span
            state)]
        [(AstExpr.Call callee args)
          (let
            [callee-name : String
              (lint-copy-on-update-expr-var-name (ast-node-get callee))]
            (if (not (string.string-eq callee-name type-name))
              state
              (match (lint-copy-on-update-struct-find
                (struct-get state shapes)
                type-name)
                [(LintCopyOnUpdateMaybeStruct.NoStruct) state]
                [(LintCopyOnUpdateMaybeStruct.SomeStruct shape)
                  (let
                    [checked : LintCopyOnUpdateArgCheck
                      (lint-copy-on-update-check-args
                        (struct-get shape fields)
                        args
                        target-name)]
                    (if (and
                      (struct-get checked valid)
                      (= (struct-get checked changed) 1)
                      (>= (struct-get checked copied) 1))
                      (lint-copy-on-update-add-finding
                        state
                        target-name
                        (struct-get checked changed-field)
                        span)
                      state))])))]
        [_ state]))))

(define (lint-copy-on-update-init-type-name
  [state : LintCopyOnUpdateState]
  [expr : AstExpr]) : String
  (match expr
    [(AstExpr.Spanned inner _)
      (lint-copy-on-update-init-type-name state (ast-node-get inner))]
    [(AstExpr.Ann inner ty)
      (let
        [annotated : String
          (lint-copy-on-update-struct-name-from-type
            (struct-get state shapes)
            ty)]
        (if (string.string-eq annotated "")
          (lint-copy-on-update-init-type-name state (ast-node-get inner))
          annotated))]
    [(AstExpr.Cast inner ty)
      (let
        [casted : String
          (lint-copy-on-update-struct-name-from-type
            (struct-get state shapes)
            ty)]
        (if (string.string-eq casted "")
          (lint-copy-on-update-init-type-name state (ast-node-get inner))
          casted))]
    [(AstExpr.Call callee _)
      (let
        [callee-name : String
          (lint-copy-on-update-expr-var-name (ast-node-get callee))]
        (match (lint-copy-on-update-struct-find
          (struct-get state shapes)
          callee-name)
          [(LintCopyOnUpdateMaybeStruct.NoStruct) ""]
          [(LintCopyOnUpdateMaybeStruct.SomeStruct _) callee-name]))]
    [(AstExpr.Var name)
      (lint-copy-on-update-local-type
        (struct-get state locals)
        (intern-str name))]
    [_ ""]))

(define (lint-copy-on-update-local-type-from-binding
  [state : LintCopyOnUpdateState]
  [maybe-ty : AstMaybeType]
  [init : i64]) : String
  (let
    [annotated : String
      (lint-copy-on-update-struct-name-from-maybe-type
        (struct-get state shapes)
        maybe-ty)]
    (if (string.string-eq annotated "")
      (lint-copy-on-update-init-type-name state (ast-node-get init))
      annotated)))

(define (lint-copy-on-update-expr-list
  [exprs : AstExprList]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (match exprs
    [(AstExprList.Nil) state]
    [(AstExprList.Cons head rest)
      (lint-copy-on-update-expr-list
        (box-get rest)
        (lint-copy-on-update-expr (ast-node-get head) state (lint-no-span)))]))

(define (lint-copy-on-update-let-bindings
  [bindings : AstLetBindingList]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (match bindings
    [(AstLetBindingList.Nil) state]
    [(AstLetBindingList.Cons binding rest)
      (match binding
        [(AstLetBinding.Binding name maybe-ty init)
          (let
            [after-init : LintCopyOnUpdateState
              (lint-copy-on-update-expr
                (ast-node-get init)
                state
                (lint-no-effect-span (ast-node-get init)))]
            [type-name : String
              (lint-copy-on-update-local-type-from-binding
                after-init
                maybe-ty
                init)]
            [with-local : LintCopyOnUpdateState
              (lint-copy-on-update-state-with
                after-init
                (lint-copy-on-update-local-add
                  (struct-get after-init locals)
                  (intern-str name)
                  type-name)
                (struct-get after-init findings))]
            (lint-copy-on-update-let-bindings (box-get rest) with-local))])]))

(define (lint-copy-on-update-let
  [bindings : AstLetBindingList]
  [body : AstExpr]
  [state : LintCopyOnUpdateState]
  [span : AstSourceSpan]) : LintCopyOnUpdateState
  (let
    [outer-locals : LintCopyOnUpdateLocalList (struct-get state locals)]
    [with-bindings : LintCopyOnUpdateState
      (lint-copy-on-update-let-bindings bindings state)]
    [with-body : LintCopyOnUpdateState
      (lint-copy-on-update-expr body with-bindings span)]
    (lint-copy-on-update-state-with
      with-body
      outer-locals
      (struct-get with-body findings))))

(define (lint-copy-on-update-match-arms
  [arms : AstMatchArmList]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (match arms
    [(AstMatchArmList.Nil) state]
    [(AstMatchArmList.Cons arm rest)
      (match arm
        [(AstMatchArm.Arm _ body)
          (lint-copy-on-update-match-arms
            (box-get rest)
            (lint-copy-on-update-expr (ast-node-get body) state (lint-no-span)))])]))

(define (lint-copy-on-update-resource-bindings
  [bindings : AstResourceBindingList]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (match bindings
    [(AstResourceBindingList.Nil) state]
    [(AstResourceBindingList.Cons binding rest)
      (match binding
        [(AstResourceBinding.Binding _ init cleanup)
          (lint-copy-on-update-resource-bindings
            (box-get rest)
            (lint-copy-on-update-expr
              (ast-node-get cleanup)
              (lint-copy-on-update-expr
                (ast-node-get init)
                state
                (lint-no-effect-span (ast-node-get init)))
              (lint-no-effect-span (ast-node-get cleanup))))])]))

(define (lint-copy-on-update-expr
  [expr : AstExpr]
  [state : LintCopyOnUpdateState]
  [span : AstSourceSpan]) : LintCopyOnUpdateState
  (match expr
    [(AstExpr.Spanned inner inner-span)
      (lint-copy-on-update-expr (ast-node-get inner) state inner-span)]
    [(AstExpr.Binary _ left right)
      (lint-copy-on-update-expr
        (ast-node-get right)
        (lint-copy-on-update-expr (ast-node-get left) state span)
        span)]
    [(AstExpr.Unary _ inner)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [(AstExpr.Call callee args)
      (lint-copy-on-update-expr-list
        args
        (lint-copy-on-update-expr (ast-node-get callee) state span))]
    [(AstExpr.If cond then-branch else-branch)
      (lint-copy-on-update-expr
        (ast-node-get else-branch)
        (lint-copy-on-update-expr
          (ast-node-get then-branch)
          (lint-copy-on-update-expr (ast-node-get cond) state span)
          span)
        span)]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body)
          (lint-copy-on-update-let bindings (ast-node-get body) state span)])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda params _ body)
          (let
            [outer-locals : LintCopyOnUpdateLocalList (struct-get state locals)]
            [with-params : LintCopyOnUpdateState
              (lint-copy-on-update-state-with
                state
                (lint-copy-on-update-param-locals
                  params
                  (struct-get state shapes)
                  outer-locals)
                (struct-get state findings))]
            [with-body : LintCopyOnUpdateState
              (lint-copy-on-update-expr (ast-node-get body) with-params span)]
            (lint-copy-on-update-state-with
              with-body
              outer-locals
              (struct-get with-body findings)))])]
    [(AstExpr.Tuple exprs) (lint-copy-on-update-expr-list exprs state)]
    [(AstExpr.TupleRef tuple _)
      (lint-copy-on-update-expr (ast-node-get tuple) state span)]
    [(AstExpr.Array exprs) (lint-copy-on-update-expr-list exprs state)]
    [(AstExpr.MakeArray _ len)
      (lint-copy-on-update-expr (ast-node-get len) state span)]
    [(AstExpr.ArrayRef array index)
      (lint-copy-on-update-expr
        (ast-node-get index)
        (lint-copy-on-update-expr (ast-node-get array) state span)
        span)]
    [(AstExpr.ArraySet array index value)
      (lint-copy-on-update-expr
        (ast-node-get value)
        (lint-copy-on-update-expr
          (ast-node-get index)
          (lint-copy-on-update-expr (ast-node-get array) state span)
          span)
        span)]
    [(AstExpr.ArrayPush array value)
      (lint-copy-on-update-expr
        (ast-node-get value)
        (lint-copy-on-update-expr (ast-node-get array) state span)
        span)]
    [(AstExpr.StringRef text index)
      (lint-copy-on-update-expr
        (ast-node-get index)
        (lint-copy-on-update-expr (ast-node-get text) state span)
        span)]
    [(AstExpr.While cond body)
      (lint-copy-on-update-expr
        (ast-node-get body)
        (lint-copy-on-update-expr (ast-node-get cond) state span)
        span)]
    [(AstExpr.Begin exprs) (lint-copy-on-update-expr-list exprs state)]
    [(AstExpr.Unsafe exprs) (lint-copy-on-update-expr-list exprs state)]
    [(AstExpr.Set target value)
      (lint-copy-on-update-add-set-if-needed
        target
        (ast-node-get value)
        span
        (lint-copy-on-update-expr (ast-node-get value) state span))]
    [(AstExpr.Ann inner _)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [(AstExpr.Cast inner _)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [(AstExpr.Borrow _ _ place)
      (lint-copy-on-update-expr (ast-node-get place) state span)]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (lint-copy-on-update-match-arms
            arms
            (lint-copy-on-update-expr (ast-node-get scrutinee) state span))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach name ty start end body)
          (let
            [after-range : LintCopyOnUpdateState
              (lint-copy-on-update-expr
                (ast-node-get end)
                (lint-copy-on-update-expr (ast-node-get start) state span)
                span)]
            [outer-locals : LintCopyOnUpdateLocalList
              (struct-get after-range locals)]
            [with-local : LintCopyOnUpdateState
              (lint-copy-on-update-state-with
                after-range
                (lint-copy-on-update-local-add
                  outer-locals
                  (intern-str name)
                  (lint-copy-on-update-struct-name-from-type
                    (struct-get state shapes)
                    ty))
                (struct-get after-range findings))]
            [with-body : LintCopyOnUpdateState
              (lint-copy-on-update-expr (ast-node-get body) with-local span)]
            (lint-copy-on-update-state-with
              with-body
              outer-locals
              (struct-get with-body findings)))])]
    [(AstExpr.StructGet receiver _)
      (lint-copy-on-update-expr (ast-node-get receiver) state span)]
    [(AstExpr.StructSet receiver _ value)
      (lint-copy-on-update-expr
        (ast-node-get value)
        (lint-copy-on-update-expr (ast-node-get receiver) state span)
        span)]
    [(AstExpr.WithRegion _ body) (lint-copy-on-update-expr-list body state)]
    [(AstExpr.WithEscape scratch body)
      (lint-copy-on-update-expr-list
        body
        (lint-copy-on-update-expr (ast-node-get scratch) state span))]
    [(AstExpr.WithScratch body) (lint-copy-on-update-expr-list body state)]
    [(AstExpr.InArena arena body)
      (lint-copy-on-update-expr-list
        body
        (lint-copy-on-update-expr (ast-node-get arena) state span))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (lint-copy-on-update-expr-list
            body
            (lint-copy-on-update-resource-bindings bindings state))])]
    [(AstExpr.Box inner)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [(AstExpr.BoxGet inner)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [(AstExpr.BoxTake inner)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [(AstExpr.BoxSet inner value)
      (lint-copy-on-update-expr
        (ast-node-get value)
        (lint-copy-on-update-expr (ast-node-get inner) state span)
        span)]
    [(AstExpr.Comptime inner)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [(AstExpr.Quote _) state]
    [(AstExpr.Quasiquote _) state]
    [(AstExpr.Unquote inner)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [(AstExpr.UnquoteSplicing inner)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [(AstExpr.BracketClause items) (lint-copy-on-update-expr-list items state)]
    [(AstExpr.Try inner)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [(AstExpr.Return inner)
      (lint-copy-on-update-expr (ast-node-get inner) state span)]
    [_ state]))

(define (lint-copy-on-update-field-names [fields : AstFieldDefList]) : LintNameList
  (match fields
    [(AstFieldDefList.Nil) LintNameList.Nil]
    [(AstFieldDefList.Cons field rest)
      (match field
        [(AstFieldDef.Def name _ _)
          (LintNameList.Cons
            (intern-str name)
            (box (lint-copy-on-update-field-names (box-get rest))))])]))

(define (lint-copy-on-update-add-struct
  [name : i64]
  [fields : AstFieldDefList]
  [shapes : LintCopyOnUpdateStructList]) : LintCopyOnUpdateStructList
  (let
    [names : LintNameList (lint-copy-on-update-field-names fields)]
    (LintCopyOnUpdateStructList.Cons
      (LintCopyOnUpdateStructShape
        (intern-str name)
        names
        (lint-name-list-count names))
      (box shapes))))

(define (lint-copy-on-update-collect-structs-in-decl
  [decl : AstDecl]
  [shapes : LintCopyOnUpdateStructList]) : LintCopyOnUpdateStructList
  (match decl
    [(AstDecl.DefStruct name _ _ fields)
      (lint-copy-on-update-add-struct name fields shapes)]
    [(AstDecl.DefStructLifetimes name _ _ _ fields)
      (lint-copy-on-update-add-struct name fields shapes)]
    [(AstDecl.Unsafe inner)
      (lint-copy-on-update-collect-structs-in-decl (box-get inner) shapes)]
    [(AstDecl.ComptimeDecl _ inner)
      (lint-copy-on-update-collect-structs-in-decl (box-get inner) shapes)]
    [_ shapes]))

(define (lint-copy-on-update-collect-structs
  [decls : AstDeclList]
  [shapes : LintCopyOnUpdateStructList]) : LintCopyOnUpdateStructList
  (match decls
    [(AstDeclList.Nil) shapes]
    [(AstDeclList.Cons decl rest)
      (lint-copy-on-update-collect-structs
        (box-get rest)
        (lint-copy-on-update-collect-structs-in-decl decl shapes))]))

(define (lint-copy-on-update-structs-in-decl
  [decl : AstDecl]
  [shapes : LintCopyOnUpdateStructList]
  [acc : LintFindings]) : LintFindings
  (match decl
    [(AstDecl.Def _ _ body)
      (struct-get
        (lint-copy-on-update-expr
          (ast-node-get body)
          (LintCopyOnUpdateState shapes LintCopyOnUpdateLocalList.Nil acc)
          (lint-no-span))
        findings)]
    [(AstDecl.DefFn _ params _ body _)
      (struct-get
        (lint-copy-on-update-expr
          (ast-node-get body)
          (LintCopyOnUpdateState
            shapes
            (lint-copy-on-update-param-locals
              params
              shapes
              LintCopyOnUpdateLocalList.Nil)
            acc)
          (lint-no-span))
        findings)]
    [(AstDecl.DefMacro _ params _ body)
      (struct-get
        (lint-copy-on-update-expr
          (ast-node-get body)
          (LintCopyOnUpdateState
            shapes
            (lint-copy-on-update-macro-param-locals
              params
              shapes
              LintCopyOnUpdateLocalList.Nil)
            acc)
          (lint-no-span))
        findings)]
    [(AstDecl.Test _ body _)
      (struct-get
        (lint-copy-on-update-expr
          (ast-node-get body)
          (LintCopyOnUpdateState shapes LintCopyOnUpdateLocalList.Nil acc)
          (lint-no-span))
        findings)]
    [(AstDecl.Unsafe inner)
      (lint-copy-on-update-structs-in-decl (box-get inner) shapes acc)]
    [(AstDecl.ComptimeDecl _ inner)
      (lint-copy-on-update-structs-in-decl (box-get inner) shapes acc)]
    [_ acc]))

(define (lint-copy-on-update-structs-in-decl-list
  [decls : AstDeclList]
  [shapes : LintCopyOnUpdateStructList]
  [acc : LintFindings]) : LintFindings
  (match decls
    [(AstDeclList.Nil) acc]
    [(AstDeclList.Cons decl rest)
      (lint-copy-on-update-structs-in-decl-list
        (box-get rest)
        shapes
        (lint-copy-on-update-structs-in-decl decl shapes acc))]))

(define (lint-pending-assignment-find
  [items : LintPendingAssignmentList]
  [name : String]) : LintMaybePendingAssignment
  (match items
    [(LintPendingAssignmentList.Nil) LintMaybePendingAssignment.No]
    [(LintPendingAssignmentList.Cons item rest)
      (if (string.string-eq (struct-get item name) name)
        (LintMaybePendingAssignment.Some item)
        (lint-pending-assignment-find (box-get rest) name))]))

(define (lint-pending-assignment-remove
  [items : LintPendingAssignmentList]
  [name : String]) : LintPendingAssignmentList
  (match items
    [(LintPendingAssignmentList.Nil) LintPendingAssignmentList.Nil]
    [(LintPendingAssignmentList.Cons item rest)
      (let
        [rest-items : LintPendingAssignmentList (box-get rest)]
        (if (string.string-eq (struct-get item name) name)
          (lint-pending-assignment-remove rest-items name)
          (LintPendingAssignmentList.Cons
            item
            (box (lint-pending-assignment-remove rest-items name)))))]))

(define (lint-pending-assignment-add
  [items : LintPendingAssignmentList]
  [name : String]
  [span : AstSourceSpan]) : LintPendingAssignmentList
  (LintPendingAssignmentList.Cons
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
            [(LintMaybePendingAssignment.No) (struct-get state findings)]
            [(LintMaybePendingAssignment.Some pending)
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
    LintPendingAssignmentList.Nil
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
    [(AstExprList.Nil) state]
    [(AstExprList.Cons head rest)
      (lint-unused-assignment-note-reads-list
        (box-get rest)
        (lint-unused-assignment-note-reads (ast-node-get head) state))]))

(define (lint-unused-assignment-note-reads-let-bindings
  [bindings : AstLetBindingList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match bindings
    [(AstLetBindingList.Nil) state]
    [(AstLetBindingList.Cons binding rest)
      (match binding
        [(AstLetBinding.Binding _ _ init)
          (lint-unused-assignment-note-reads-let-bindings
            (box-get rest)
            (lint-unused-assignment-note-reads (ast-node-get init) state))])]))

(define (lint-unused-assignment-note-reads-match-arms
  [arms : AstMatchArmList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match arms
    [(AstMatchArmList.Nil) state]
    [(AstMatchArmList.Cons arm rest)
      (match arm
        [(AstMatchArm.Arm _ body)
          (lint-unused-assignment-note-reads-match-arms
            (box-get rest)
            (lint-unused-assignment-note-reads (ast-node-get body) state))])]))

(define (lint-unused-assignment-note-reads-resource-bindings
  [bindings : AstResourceBindingList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match bindings
    [(AstResourceBindingList.Nil) state]
    [(AstResourceBindingList.Cons binding rest)
      (match binding
        [(AstResourceBinding.Binding _ init cleanup)
          (lint-unused-assignment-note-reads-resource-bindings
            (box-get rest)
            (lint-unused-assignment-note-reads
              (ast-node-get cleanup)
              (lint-unused-assignment-note-reads (ast-node-get init) state)))])]))

(define (lint-unused-assignment-note-reads
  [expr : AstExpr]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match expr
    [(AstExpr.Spanned inner-box _)
      (lint-unused-assignment-note-reads (ast-node-get inner-box) state)]
    [(AstExpr.Literal _) state]
    [(AstExpr.Var name) (lint-unused-assignment-read-id state name)]
    [(AstExpr.Binary _ left right)
      (lint-unused-assignment-note-reads
        (ast-node-get right)
        (lint-unused-assignment-note-reads (ast-node-get left) state))]
    [(AstExpr.Unary _ inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.Call func args)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads-list
          args
          (lint-unused-assignment-note-reads (ast-node-get func) state)))]
    [(AstExpr.If cond then-branch else-branch)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast-node-get else-branch)
          (lint-unused-assignment-note-reads
            (ast-node-get then-branch)
            (lint-unused-assignment-note-reads (ast-node-get cond) state))))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads
              (ast-node-get body)
              (lint-unused-assignment-note-reads-let-bindings bindings state)))])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda _ _ body)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads (ast-node-get body) state))])]
    [(AstExpr.Tuple exprs) (lint-unused-assignment-note-reads-list exprs state)]
    [(AstExpr.TupleRef tuple _)
      (lint-unused-assignment-note-reads (ast-node-get tuple) state)]
    [(AstExpr.Array exprs) (lint-unused-assignment-note-reads-list exprs state)]
    [(AstExpr.MakeArray _ len)
      (lint-unused-assignment-note-reads (ast-node-get len) state)]
    [(AstExpr.ArrayRef array index)
      (lint-unused-assignment-note-reads
        (ast-node-get index)
        (lint-unused-assignment-note-reads (ast-node-get array) state))]
    [(AstExpr.ArraySet array index value)
      (lint-unused-assignment-note-reads
        (ast-node-get value)
        (lint-unused-assignment-note-reads
          (ast-node-get index)
          (lint-unused-assignment-note-reads (ast-node-get array) state)))]
    [(AstExpr.ArrayPush array value)
      (lint-unused-assignment-note-reads
        (ast-node-get value)
        (lint-unused-assignment-note-reads (ast-node-get array) state))]
    [(AstExpr.StringRef text index)
      (lint-unused-assignment-note-reads
        (ast-node-get index)
        (lint-unused-assignment-note-reads (ast-node-get text) state))]
    [(AstExpr.While cond body)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast-node-get body)
          (lint-unused-assignment-note-reads (ast-node-get cond) state)))]
    [(AstExpr.Begin exprs) (lint-unused-assignment-note-reads-list exprs state)]
    [(AstExpr.Unsafe exprs)
      (lint-unused-assignment-note-reads-list exprs state)]
    [(AstExpr.Set _ value)
      (lint-unused-assignment-note-reads (ast-node-get value) state)]
    [(AstExpr.Ann inner _)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.Cast inner _)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.Borrow _ _ place)
      (lint-unused-assignment-note-reads (ast-node-get place) state)]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads-match-arms
              arms
              (lint-unused-assignment-note-reads (ast-node-get scrutinee) state)))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach _ _ start end body)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads
              (ast-node-get body)
              (lint-unused-assignment-note-reads
                (ast-node-get end)
                (lint-unused-assignment-note-reads (ast-node-get start) state))))])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce _ _ _ start end init value)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads
              (ast-node-get value)
              (lint-unused-assignment-note-reads
                (ast-node-get init)
                (lint-unused-assignment-note-reads
                  (ast-node-get end)
                  (lint-unused-assignment-note-reads (ast-node-get start) state)))))])]
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan _ _ _ start end _ _ init value body)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads
              (ast-node-get body)
              (lint-unused-assignment-note-reads
                (ast-node-get value)
                (lint-unused-assignment-note-reads
                  (ast-node-get init)
                  (lint-unused-assignment-note-reads
                    (ast-node-get end)
                    (lint-unused-assignment-note-reads
                      (ast-node-get start)
                      state))))))])]
    [(AstExpr.SpmdBroadcast value lane)
      (lint-unused-assignment-note-reads
        (ast-node-get lane)
        (lint-unused-assignment-note-reads (ast-node-get value) state))]
    [(AstExpr.SpmdShuffle value lane)
      (lint-unused-assignment-note-reads
        (ast-node-get lane)
        (lint-unused-assignment-note-reads (ast-node-get value) state))]
    [(AstExpr.StructGet receiver _)
      (lint-unused-assignment-note-reads (ast-node-get receiver) state)]
    [(AstExpr.StructSet receiver _ value)
      (lint-unused-assignment-note-reads
        (ast-node-get value)
        (lint-unused-assignment-note-reads (ast-node-get receiver) state))]
    [(AstExpr.WithRegion _ body)
      (lint-unused-assignment-note-reads-list body state)]
    [(AstExpr.WithEscape scratch body)
      (lint-unused-assignment-note-reads-list
        body
        (lint-unused-assignment-note-reads (ast-node-get scratch) state))]
    [(AstExpr.WithScratch body)
      (lint-unused-assignment-note-reads-list body state)]
    [(AstExpr.InArena arena body)
      (lint-unused-assignment-note-reads-list
        body
        (lint-unused-assignment-note-reads (ast-node-get arena) state))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (lint-unused-assignment-note-reads-list
            body
            (lint-unused-assignment-note-reads-resource-bindings bindings state))])]
    [(AstExpr.Box inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.BoxGet inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.BoxTake inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.BoxSet inner value)
      (lint-unused-assignment-note-reads
        (ast-node-get value)
        (lint-unused-assignment-note-reads (ast-node-get inner) state))]
    [(AstExpr.TypeLiteral _) state]
    [(AstExpr.Init _) state]
    [(AstExpr.Comptime inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.Quote _) state]
    [(AstExpr.Quasiquote _) state]
    [(AstExpr.Unquote inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.UnquoteSplicing inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.BracketClause items)
      (lint-unused-assignment-note-reads-list items state)]
    [(AstExpr.Try inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.Return inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.PtrNull _) state]
    [(AstExpr.PtrNullCheck inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.PtrAddrOf place)
      (lint-unused-assignment-note-reads (ast-node-get place) state)]
    [(AstExpr.PtrRead ptr)
      (lint-unused-assignment-note-reads (ast-node-get ptr) state)]
    [(AstExpr.PtrWrite ptr value)
      (lint-unused-assignment-note-reads
        (ast-node-get value)
        (lint-unused-assignment-note-reads (ast-node-get ptr) state))]
    [(AstExpr.PtrOffset ptr offset)
      (lint-unused-assignment-note-reads
        (ast-node-get offset)
        (lint-unused-assignment-note-reads (ast-node-get ptr) state))]
    [(AstExpr.PtrCast ptr _)
      (lint-unused-assignment-note-reads (ast-node-get ptr) state)]
    [(AstExpr.PtrToInt ptr)
      (lint-unused-assignment-note-reads (ast-node-get ptr) state)]
    [(AstExpr.IntToPtr value _)
      (lint-unused-assignment-note-reads (ast-node-get value) state)]
    [(AstExpr.StringData inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.StringFromBytes ptr len)
      (lint-unused-assignment-note-reads
        (ast-node-get len)
        (lint-unused-assignment-note-reads (ast-node-get ptr) state))]
    [(AstExpr.ArrayData inner)
      (lint-unused-assignment-note-reads (ast-node-get inner) state)]
    [(AstExpr.BinaryData _) state]
    [(AstExpr.SpmdProgramIndex) state]
    [(AstExpr.SpmdProgramCount) state]
    [(AstExpr.ProgramArgc) state]
    [(AstExpr.ProgramArgv) state]
    [(AstExpr.ProgramEnvp) state]
    [(AstExpr.CpuIdEax leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast-node-get leaf) state))]
    [(AstExpr.CpuIdEbx leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast-node-get leaf) state))]
    [(AstExpr.CpuIdEcx leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast-node-get leaf) state))]
    [(AstExpr.CpuIdEdx leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast-node-get leaf) state))]
    [(AstExpr.Xgetbv index)
      (lint-unused-assignment-note-reads (ast-node-get index) state)]
    [(AstExpr.Syscall args) (lint-unused-assignment-note-reads-list args state)]))

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
    [(AstExprList.Nil) state]
    [(AstExprList.Cons head rest)
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
    [(AstLetBindingList.Nil) state]
    [(AstLetBindingList.Cons binding rest)
      (match binding
        [(AstLetBinding.Binding name _ init)
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
      LintPendingAssignmentList.Nil
      (struct-get inner findings))))

(define (lint-unused-assignment-expr
  [expr : AstExpr]
  [state : LintUnusedAssignmentState]
  [span : AstSourceSpan]) : LintUnusedAssignmentState
  (match expr
    [(AstExpr.Spanned inner-box inner-span)
      (lint-unused-assignment-expr (ast-node-get inner-box) state inner-span)]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body)
          (lint-unused-assignment-let bindings (ast-node-get body) state span)])]
    [(AstExpr.Begin exprs) (lint-unused-assignment-expr-list exprs state)]
    [(AstExpr.Unsafe exprs) (lint-unused-assignment-expr-list exprs state)]
    [(AstExpr.WithRegion _ body) (lint-unused-assignment-expr-list body state)]
    [(AstExpr.WithScratch body) (lint-unused-assignment-expr-list body state)]
    [(AstExpr.WithEscape scratch body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads (ast-node-get scratch) state))]
    [(AstExpr.InArena arena body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads (ast-node-get arena) state))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (lint-unused-assignment-expr-list
            body
            (lint-unused-assignment-note-reads-resource-bindings bindings state))])]
    [(AstExpr.Set target value)
      (lint-unused-assignment-write-id
        (lint-unused-assignment-note-reads (ast-node-get value) state)
        target
        span)]
    [_ (lint-unused-assignment-note-reads expr state)]))

(define (lint-unused-assignment-state-empty
  [locals : LintNameList]
  [acc : LintFindings]) : LintUnusedAssignmentState
  (LintUnusedAssignmentState locals LintPendingAssignmentList.Nil acc))

(define (lint-unused-assignments-in-decl [decl : AstDecl] [acc : LintFindings]) : LintFindings
  (match decl
    [(AstDecl.Def _ _ body)
      (struct-get
        (lint-unused-assignment-expr
          (ast-node-get body)
          (lint-unused-assignment-state-empty LintNameList.Nil acc)
          (lint-no-span))
        findings)]
    [(AstDecl.DefFn _ params _ body _)
      (struct-get
        (lint-unused-assignment-expr
          (ast-node-get body)
          (lint-unused-assignment-state-empty
            (lint-param-list-add-locals params LintNameList.Nil)
            acc)
          (lint-no-span))
        findings)]
    [(AstDecl.DefMacro _ params _ body)
      (struct-get
        (lint-unused-assignment-expr
          (ast-node-get body)
          (lint-unused-assignment-state-empty
            (lint-macro-param-list-add-locals params LintNameList.Nil)
            acc)
          (lint-no-span))
        findings)]
    [(AstDecl.Test _ body _)
      (struct-get
        (lint-unused-assignment-expr
          (ast-node-get body)
          (lint-unused-assignment-state-empty LintNameList.Nil acc)
          (lint-no-span))
        findings)]
    [(AstDecl.Unsafe inner)
      (lint-unused-assignments-in-decl (box-get inner) acc)]
    [(AstDecl.ComptimeDecl _ inner)
      (lint-unused-assignments-in-decl (box-get inner) acc)]
    [_ acc]))

(define (lint-unused-assignments-in-decl-list
  [decls : AstDeclList]
  [acc : LintFindings]) : LintFindings
  (match decls
    [(AstDeclList.Nil) acc]
    [(AstDeclList.Cons decl rest)
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
  (Nil)
  (Cons LintUnusedVariableBinding (Box LintUnusedVariableBindingList)))

(defenum LintUnusedVariableFrameList
  (Nil)
  (Cons LintUnusedVariableBindingList (Box LintUnusedVariableFrameList)))

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
    [source-len : i64 (string.string-length source)]
    [needle-len : i64 (string.string-length needle)]
    (if (< start 0)
      false
      (if (> (+ start needle-len) source-len)
        false
        (let
          [ok : bool true]
          [idx : i64 0]
          (begin
            (while (and ok (< idx needle-len))
              (if (=
                (string.string-ref source (+ start idx))
                (string.string-ref needle idx))
                (set! idx (+ idx 1))
                (set! ok false)))
            ok))))))

(define (lint-source-find-prefix-from
  [source : String]
  [needle : String]
  [idx : i64]) : i64
  (let
    [source-len : i64 (string.string-length source)]
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
    [source-len : i64 (string.string-length source)]
    (if (< idx 0)
      true
      (if (>= idx source-len)
        true
        (not (is-symbol-char (string.string-ref source idx)))))))

(define (lint-source-name-at? [source : String] [idx : i64] [name : String]) : bool
  (let
    [end : i64 (+ idx (string.string-length name))]
    (and
      (lint-source-prefix-at? source idx name)
      (lint-source-symbol-boundary? source (- idx 1))
      (lint-source-symbol-boundary? source end))))

(define (lint-source-find-name-from
  [source : String]
  [name : String]
  [idx : i64]) : i64
  (let
    [source-len : i64 (string.string-length source)]
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
          (if (= (string.string-ref source i) '\n')
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
          (if (= (string.string-ref source i) '\n')
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
    [source-len : i64 (string.string-length source)]
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
              (if (= (string.string-ref source idx) '\n')
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
    [width : i64 (string.string-length name)]
    (if (< found 0)
      (LintSourceNameSpan fallback cursor)
      (LintSourceNameSpan
        (lint-source-index-span source found width fallback)
        (+ found width)))))

(defstruct LintRedundantFunctionNameState
  (source String)
  (module-name String)
  (cursor i64)
  (findings LintFindings))

(define (lint-redundant-function-name-state
  [source : String]
  [module-name : String]
  [cursor : i64]
  [findings : LintFindings]) : LintRedundantFunctionNameState
  (LintRedundantFunctionNameState source module-name cursor findings))

(define (lint-redundant-function-name-state-with-module
  [state : LintRedundantFunctionNameState]
  [module-name : String]) : LintRedundantFunctionNameState
  (lint-redundant-function-name-state
    (struct-get state source)
    module-name
    (struct-get state cursor)
    (struct-get state findings)))

(define (lint-redundant-function-name-state-with-results
  [state : LintRedundantFunctionNameState]
  [cursor : i64]
  [findings : LintFindings]) : LintRedundantFunctionNameState
  (lint-redundant-function-name-state
    (struct-get state source)
    (struct-get state module-name)
    cursor
    findings))

(define (lint-redundant-function-module-char-eq?
  [module-char : char]
  [name-char : char]) : bool
  (or (= module-char name-char) (and (= module-char '_') (= name-char '-'))))

(define (lint-redundant-function-module-prefix-at?
  [name : String]
  [module-name : String]
  [idx : i64]) : bool
  (let
    [module-len : i64 (string.string-length module-name)]
    (if (>= idx module-len)
      true
      (if (lint-redundant-function-module-char-eq?
        (string.string-ref module-name idx)
        (string.string-ref name idx))
        (lint-redundant-function-module-prefix-at? name module-name (+ idx 1))
        false))))

(define (lint-redundant-function-name? [module-name : String] [name : String]) : bool
  (let
    [module-len : i64 (string.string-length module-name)]
    [name-len : i64 (string.string-length name)]
    (and
      (> module-len 0)
      (> name-len (+ module-len 1))
      (lint-redundant-function-module-prefix-at? name module-name 0)
      (= (string.string-ref name module-len) '-'))))

(define (lint-redundant-function-name-add
  [state : LintRedundantFunctionNameState]
  [name : String]
  [fallback : AstSourceSpan]) : LintRedundantFunctionNameState
  (let
    [module-name : String (struct-get state module-name)]
    (if (lint-redundant-function-name? module-name name)
      (let
        [found : LintSourceNameSpan
          (lint-source-name-span-from
            (struct-get state source)
            name
            (struct-get state cursor)
            fallback)]
        (lint-redundant-function-name-state-with-results
          state
          (struct-get found next-index)
          (lint-findings-add
            (lint-redundant-function-name-finding
              module-name
              name
              (struct-get found span))
            (struct-get state findings))))
      state)))

(define (lint-redundant-function-name-callee [expr : AstExpr]) : String
  (match (ast-expr-unspan expr)
    [(AstExpr.Var name) (intern-str name)]
    [_ ""]))

(define (lint-redundant-function-name-generated-head [args : AstExprList]) : String
  (match args
    [(AstExprList.Nil) ""]
    [(AstExprList.Cons head _)
      (match (ast-expr-unspan (ast-node-get head))
        [(AstExpr.Call fn-head _)
          (lint-redundant-function-name-callee (ast-node-get fn-head))]
        [_ ""])]))

(define (lint-redundant-function-name-literal-module [args : AstExprList]) : String
  (match args
    [(AstExprList.Nil) ""]
    [(AstExprList.Cons head _)
      (match (ast-expr-unspan (ast-node-get head))
        [(AstExpr.Var name) (lint-module-default-alias (intern-str name))]
        [_ ""])]))

(define (lint-redundant-function-name-quoted-expr-list
  [exprs : AstExprList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match exprs
    [(AstExprList.Nil) state]
    [(AstExprList.Cons head rest)
      (lint-redundant-function-name-quoted-expr-list
        (box-get rest)
        (lint-redundant-function-name-quoted-expr (ast-node-get head) state))]))

(define (lint-redundant-function-name-macro-expr-list
  [exprs : AstExprList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match exprs
    [(AstExprList.Nil) state]
    [(AstExprList.Cons head rest)
      (lint-redundant-function-name-macro-expr-list
        (box-get rest)
        (lint-redundant-function-name-macro-expr (ast-node-get head) state))]))

(define (lint-redundant-function-name-quoted-call
  [callee : String]
  [args : AstExprList]
  [span : AstSourceSpan]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (cond
    [(string.string-eq callee "module")
      (let
        [module-name : String
          (lint-redundant-function-name-literal-module args)]
        (if (string.string-eq module-name "")
          (lint-redundant-function-name-quoted-expr-list args state)
          (lint-redundant-function-name-quoted-expr-list
            args
            (lint-redundant-function-name-state-with-module state module-name))))]
    [(or
        (string.string-eq callee "define")
        (string.string-eq callee "defmacro"))
      (lint-redundant-function-name-quoted-expr-list
        args
        (lint-redundant-function-name-add
          state
          (lint-redundant-function-name-generated-head args)
          span))]
    [else (lint-redundant-function-name-quoted-expr-list args state)]))

(define (lint-redundant-function-name-quoted-expr
  [expr : AstExpr]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match expr
    [(AstExpr.Spanned inner span)
      (match (ast-node-get inner)
        [(AstExpr.Call func args)
          (lint-redundant-function-name-quoted-call
            (lint-redundant-function-name-callee (ast-node-get func))
            args
            span
            state)]
        [_
          (lint-redundant-function-name-quoted-expr (ast-node-get inner) state)])]
    [(AstExpr.Call func args)
      (lint-redundant-function-name-quoted-call
        (lint-redundant-function-name-callee (ast-node-get func))
        args
        (lint-no-span)
        state)]
    [(AstExpr.Begin exprs)
      (lint-redundant-function-name-quoted-expr-list exprs state)]
    [(AstExpr.Unsafe exprs)
      (lint-redundant-function-name-quoted-expr-list exprs state)]
    [(AstExpr.If cond then-branch else-branch)
      (lint-redundant-function-name-quoted-expr
        (ast-node-get else-branch)
        (lint-redundant-function-name-quoted-expr
          (ast-node-get then-branch)
          (lint-redundant-function-name-quoted-expr (ast-node-get cond) state)))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let _ body)
          (lint-redundant-function-name-quoted-expr (ast-node-get body) state)])]
    [(AstExpr.Quote inner)
      (lint-redundant-function-name-quoted-expr (ast-node-get inner) state)]
    [(AstExpr.Quasiquote inner)
      (lint-redundant-function-name-quoted-expr (ast-node-get inner) state)]
    [(AstExpr.Unquote _) state]
    [(AstExpr.UnquoteSplicing _) state]
    [_ state]))

(define (lint-redundant-function-name-macro-expr
  [expr : AstExpr]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match expr
    [(AstExpr.Spanned inner _)
      (lint-redundant-function-name-macro-expr (ast-node-get inner) state)]
    [(AstExpr.Quote inner)
      (lint-redundant-function-name-quoted-expr (ast-node-get inner) state)]
    [(AstExpr.Quasiquote inner)
      (lint-redundant-function-name-quoted-expr (ast-node-get inner) state)]
    [(AstExpr.Call func args)
      (lint-redundant-function-name-macro-expr-list
        args
        (lint-redundant-function-name-macro-expr (ast-node-get func) state))]
    [(AstExpr.If cond then-branch else-branch)
      (lint-redundant-function-name-macro-expr
        (ast-node-get else-branch)
        (lint-redundant-function-name-macro-expr
          (ast-node-get then-branch)
          (lint-redundant-function-name-macro-expr (ast-node-get cond) state)))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body)
          (lint-redundant-function-name-macro-expr
            (ast-node-get body)
            (lint-redundant-function-name-macro-let-bindings bindings state))])]
    [(AstExpr.Begin exprs)
      (lint-redundant-function-name-macro-expr-list exprs state)]
    [(AstExpr.Unsafe exprs)
      (lint-redundant-function-name-macro-expr-list exprs state)]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (lint-redundant-function-name-macro-match-arms
            arms
            (lint-redundant-function-name-macro-expr
              (ast-node-get scrutinee)
              state))])]
    [_ state]))

(define (lint-redundant-function-name-macro-let-bindings
  [bindings : AstLetBindingList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match bindings
    [(AstLetBindingList.Nil) state]
    [(AstLetBindingList.Cons binding rest)
      (match binding
        [(AstLetBinding.Binding _ _ init)
          (lint-redundant-function-name-macro-let-bindings
            (box-get rest)
            (lint-redundant-function-name-macro-expr (ast-node-get init) state))])]))

(define (lint-redundant-function-name-macro-match-arms
  [arms : AstMatchArmList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match arms
    [(AstMatchArmList.Nil) state]
    [(AstMatchArmList.Cons arm rest)
      (match arm
        [(AstMatchArm.Arm _ body)
          (lint-redundant-function-name-macro-match-arms
            (box-get rest)
            (lint-redundant-function-name-macro-expr (ast-node-get body) state))])]))

(define (lint-redundant-function-name-decl
  [decl : AstDecl]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match decl
    [(AstDecl.Module name)
      (lint-redundant-function-name-state-with-module
        state
        (lint-module-default-alias (intern-str name)))]
    [(AstDecl.DefFn name _ _ body _)
      (lint-redundant-function-name-add
        state
        (intern-qualified-base name)
        (lint-no-effect-span (ast-node-get body)))]
    [(AstDecl.DefMacro name _ _ body)
      (lint-redundant-function-name-macro-expr
        (ast-node-get body)
        (lint-redundant-function-name-add
          state
          (intern-qualified-base name)
          (lint-no-effect-span (ast-node-get body))))]
    [(AstDecl.Unsafe inner)
      (lint-redundant-function-name-decl (box-get inner) state)]
    [(AstDecl.ComptimeDecl _ inner)
      (lint-redundant-function-name-decl (box-get inner) state)]
    [_ state]))

(define (lint-redundant-function-names-in-decl-list-state
  [decls : AstDeclList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match decls
    [(AstDeclList.Nil) state]
    [(AstDeclList.Cons decl rest)
      (lint-redundant-function-names-in-decl-list-state
        (box-get rest)
        (lint-redundant-function-name-decl decl state))]))

(define (lint-redundant-function-names-in-decl-list
  [source : String]
  [decls : AstDeclList]
  [acc : LintFindings]) : LintFindings
  (struct-get
    (lint-redundant-function-names-in-decl-list-state
      decls
      (lint-redundant-function-name-state source "" 0 acc))
    findings))

(define (lint-redundant-function-names-in-program
  [source : String]
  [program : AstProgram]
  [acc : LintFindings]) : LintFindings
  (match program
    [(AstProgram.Program decls-box)
      (lint-redundant-function-names-in-decl-list
        source
        (box-get decls-box)
        acc)]))

(define (lint-unused-variable-binding
  [name : String]
  [span : AstSourceSpan]
  [reportable : bool]) : LintUnusedVariableBinding
  (LintUnusedVariableBinding name span false reportable))

(define (lint-unused-variable-binding-cons
  [head : LintUnusedVariableBinding]
  [rest : LintUnusedVariableBindingList]) : LintUnusedVariableBindingList
  (LintUnusedVariableBindingList.Cons head (box rest)))

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
    [(LintUnusedVariableBindingList.Nil)
      (LintUnusedVariableMarkBindingsResult
        LintUnusedVariableBindingList.Nil
        false)]
    [(LintUnusedVariableBindingList.Cons binding rest)
      (if (string.string-eq (struct-get binding name) name)
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
    [(LintUnusedVariableFrameList.Nil)
      (LintUnusedVariableMarkFramesResult LintUnusedVariableFrameList.Nil false)]
    [(LintUnusedVariableFrameList.Cons bindings rest)
      (let
        [marked-bindings : LintUnusedVariableMarkBindingsResult
          (lint-unused-variable-mark-bindings bindings name)]
        (if (struct-get marked-bindings found)
          (LintUnusedVariableMarkFramesResult
            (LintUnusedVariableFrameList.Cons
              (struct-get marked-bindings bindings)
              rest)
            true)
          (let
            [marked-rest : LintUnusedVariableMarkFramesResult
              (lint-unused-variable-mark-frames (box-get rest) name)]
            (LintUnusedVariableMarkFramesResult
              (LintUnusedVariableFrameList.Cons
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
    [n : i64 (string.string-length text)]
    [idx : i64 0]
    [found : i64 (- 0 1)]
    (begin
      (while (and (< found 0) (< idx n))
        (if (= (string.string-ref text idx) '.')
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
      (lint-unused-variable-read-name with-full (string.substring name 0 dot))
      with-full)))

(define (lint-unused-variable-read-var-id
  [state : LintUnusedVariableState]
  [name : i64]) : LintUnusedVariableState
  (lint-unused-variable-read-var-name state (intern-str name)))

(define (lint-unused-variable-add-to-current-frame
  [state : LintUnusedVariableState]
  [binding : LintUnusedVariableBinding]) : LintUnusedVariableState
  (match (struct-get state frames)
    [(LintUnusedVariableFrameList.Nil)
      (lint-unused-variable-state-with
        state
        (LintUnusedVariableFrameList.Cons
          (lint-unused-variable-binding-cons
            binding
            LintUnusedVariableBindingList.Nil)
          (box LintUnusedVariableFrameList.Nil))
        (struct-get state findings))]
    [(LintUnusedVariableFrameList.Cons bindings rest)
      (lint-unused-variable-state-with
        state
        (LintUnusedVariableFrameList.Cons
          (lint-unused-variable-binding-cons binding bindings)
          rest)
        (struct-get state findings))]))

(define (lint-unused-variable-push-frame
  [state : LintUnusedVariableState]
  [bindings : LintUnusedVariableBindingList]) : LintUnusedVariableState
  (lint-unused-variable-state-with
    state
    (LintUnusedVariableFrameList.Cons bindings (box (struct-get state frames)))
    (struct-get state findings)))

(define (lint-unused-variable-report-bindings
  [bindings : LintUnusedVariableBindingList]
  [findings : LintFindings]) : LintFindings
  (match bindings
    [(LintUnusedVariableBindingList.Nil) findings]
    [(LintUnusedVariableBindingList.Cons binding rest)
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
    [(LintUnusedVariableFrameList.Nil) state]
    [(LintUnusedVariableFrameList.Cons bindings rest)
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
    [(AstParamList.Nil)
      (LintUnusedVariableBindingBuild LintUnusedVariableBindingList.Nil cursor)]
    [(AstParamList.Cons param rest)
      (match param
        [(AstParam.Param name _ _)
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
    [(AstMacroParamList.Nil)
      (LintUnusedVariableBindingBuild LintUnusedVariableBindingList.Nil cursor)]
    [(AstMacroParamList.Cons param rest)
      (match param
        [(AstMacroParam.Param name _ _)
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
    [(AstPatternList.Nil) state]
    [(AstPatternList.Cons head rest)
      (lint-unused-variable-pattern-list-bindings
        (box-get rest)
        (lint-unused-variable-pattern-bindings (box-get head) state))]))

(define (lint-unused-variable-type-list
  [items : AstTypeList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match items
    [(AstTypeList.Nil) state]
    [(AstTypeList.Cons id rest)
      (lint-unused-variable-type-list
        (box-get rest)
        (lint-unused-variable-type (ty-node-get id) state))]))

(define (lint-unused-variable-lifetime-list
  [items : AstLifetimeList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match items
    [(AstLifetimeList.Nil) state]
    [(AstLifetimeList.Cons name rest)
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
    [(AstType.Func args ret)
      (lint-unused-variable-type
        (ty-node-get ret)
        (lint-unused-variable-type-list (box-get args) state))]
    [(AstType.Tuple items)
      (lint-unused-variable-type-list (box-get items) state)]
    [(AstType.Array elem _)
      (lint-unused-variable-type (ty-node-get elem) state)]
    [(AstType.DynArray elem)
      (lint-unused-variable-type (ty-node-get elem) state)]
    [(AstType.Box elem) (lint-unused-variable-type (ty-node-get elem) state)]
    [(AstType.Region name inner)
      (lint-unused-variable-type-lifetime name inner state)]
    [(AstType.Ref name inner)
      (lint-unused-variable-type-lifetime name inner state)]
    [(AstType.MutRef name inner)
      (lint-unused-variable-type-lifetime name inner state)]
    [(AstType.EnumArgs _ lifetimes)
      (lint-unused-variable-lifetime-list (box-get lifetimes) state)]
    [(AstType.StructArgs _ lifetimes)
      (lint-unused-variable-lifetime-list (box-get lifetimes) state)]
    [(AstType.Var name) (lint-unused-variable-read-id state name)]
    [(AstType.VarArgs name lifetimes)
      (lint-unused-variable-lifetime-list
        (box-get lifetimes)
        (lint-unused-variable-read-id state name))]
    [(AstType.Ptr elem) (lint-unused-variable-type (ty-node-get elem) state)]
    [(AstType.MutPtr elem) (lint-unused-variable-type (ty-node-get elem) state)]
    [_ state]))

(define (lint-unused-variable-maybe-type
  [maybe-ty : AstMaybeType]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match maybe-ty
    [(AstMaybeType.No) state]
    [(AstMaybeType.Some ty) (lint-unused-variable-type ty state)]))

(define (lint-unused-variable-param-types
  [params : AstParamList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match params
    [(AstParamList.Nil) state]
    [(AstParamList.Cons param rest)
      (match param
        [(AstParam.Param _ ty _)
          (lint-unused-variable-param-types
            (box-get rest)
            (lint-unused-variable-type ty state))])]))

(define (lint-unused-variable-macro-param-types
  [params : AstMacroParamList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match params
    [(AstMacroParamList.Nil) state]
    [(AstMacroParamList.Cons param rest)
      (match param
        [(AstMacroParam.Param _ ty _)
          (lint-unused-variable-macro-param-types
            (box-get rest)
            (lint-unused-variable-type ty state))])]))

(define (lint-unused-variable-borrow-lifetime
  [lifetime : AstBorrowLifetime]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match lifetime
    [(AstBorrowLifetime.Inferred) state]
    [(AstBorrowLifetime.Named name) (lint-unused-variable-read-name state name)]))

(define (lint-unused-variable-pattern-bindings
  [pattern : AstPattern]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match pattern
    [(AstPattern.Var name maybe-ty)
      (lint-unused-variable-add-to-current-frame
        (lint-unused-variable-maybe-type maybe-ty state)
        (lint-unused-variable-binding (intern-str name) (lint-no-span) false))]
    [(AstPattern.Tuple items)
      (lint-unused-variable-pattern-list-bindings (box-get items) state)]
    [(AstPattern.Wildcard) state]
    [(AstPattern.Binding name)
      (lint-unused-variable-add-to-current-frame
        state
        (lint-unused-variable-binding (intern-str name) (lint-no-span) false))]
    [(AstPattern.Variant _ items)
      (lint-unused-variable-pattern-list-bindings (box-get items) state)]
    [(AstPattern.Literal _) state]))

(define (lint-unused-variable-expr-list
  [exprs : AstExprList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match exprs
    [(AstExprList.Nil) state]
    [(AstExprList.Cons head rest)
      (lint-unused-variable-expr-list
        (box-get rest)
        (lint-unused-variable-expr (ast-node-get head) state (lint-no-span)))]))

(define (lint-unused-variable-quasiquote-expr-list
  [exprs : AstExprList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match exprs
    [(AstExprList.Nil) state]
    [(AstExprList.Cons head rest)
      (lint-unused-variable-quasiquote-expr-list
        (box-get rest)
        (lint-unused-variable-quasiquote-expr (ast-node-get head) state))]))

(define (lint-unused-variable-quasiquote-let-bindings
  [bindings : AstLetBindingList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match bindings
    [(AstLetBindingList.Nil) state]
    [(AstLetBindingList.Cons binding rest)
      (match binding
        [(AstLetBinding.Binding _ _ init)
          (lint-unused-variable-quasiquote-let-bindings
            (box-get rest)
            (lint-unused-variable-quasiquote-expr (ast-node-get init) state))])]))

(define (lint-unused-variable-quasiquote-match-arms
  [arms : AstMatchArmList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match arms
    [(AstMatchArmList.Nil) state]
    [(AstMatchArmList.Cons arm rest)
      (match arm
        [(AstMatchArm.Arm _ body)
          (lint-unused-variable-quasiquote-match-arms
            (box-get rest)
            (lint-unused-variable-quasiquote-expr (ast-node-get body) state))])]))

(define (lint-unused-variable-quasiquote-resource-bindings
  [bindings : AstResourceBindingList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match bindings
    [(AstResourceBindingList.Nil) state]
    [(AstResourceBindingList.Cons binding rest)
      (match binding
        [(AstResourceBinding.Binding _ init cleanup)
          (lint-unused-variable-quasiquote-resource-bindings
            (box-get rest)
            (lint-unused-variable-quasiquote-expr
              (ast-node-get cleanup)
              (lint-unused-variable-quasiquote-expr (ast-node-get init) state)))])]))

(define (lint-unused-variable-quasiquote-expr
  [expr : AstExpr]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match expr
    [(AstExpr.Spanned inner-box _)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner-box) state)]
    [(AstExpr.Unquote inner)
      (lint-unused-variable-expr
        (ast-node-get inner)
        state
        (lint-no-effect-span (ast-node-get inner)))]
    [(AstExpr.UnquoteSplicing inner)
      (lint-unused-variable-expr
        (ast-node-get inner)
        state
        (lint-no-effect-span (ast-node-get inner)))]
    [(AstExpr.Binary _ left right)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get right)
        (lint-unused-variable-quasiquote-expr (ast-node-get left) state))]
    [(AstExpr.Unary _ inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.Call func args)
      (lint-unused-variable-quasiquote-expr-list
        args
        (lint-unused-variable-quasiquote-expr (ast-node-get func) state))]
    [(AstExpr.If cond then-branch else-branch)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get else-branch)
        (lint-unused-variable-quasiquote-expr
          (ast-node-get then-branch)
          (lint-unused-variable-quasiquote-expr (ast-node-get cond) state)))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body)
          (lint-unused-variable-quasiquote-expr
            (ast-node-get body)
            (lint-unused-variable-quasiquote-let-bindings bindings state))])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda _ _ body)
          (lint-unused-variable-quasiquote-expr (ast-node-get body) state)])]
    [(AstExpr.Tuple exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(AstExpr.TupleRef tuple _)
      (lint-unused-variable-quasiquote-expr (ast-node-get tuple) state)]
    [(AstExpr.Array exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(AstExpr.MakeArray _ len)
      (lint-unused-variable-quasiquote-expr (ast-node-get len) state)]
    [(AstExpr.ArrayRef array index)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get index)
        (lint-unused-variable-quasiquote-expr (ast-node-get array) state))]
    [(AstExpr.ArraySet array index value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr
          (ast-node-get index)
          (lint-unused-variable-quasiquote-expr (ast-node-get array) state)))]
    [(AstExpr.ArrayPush array value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast-node-get array) state))]
    [(AstExpr.StringRef text index)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get index)
        (lint-unused-variable-quasiquote-expr (ast-node-get text) state))]
    [(AstExpr.While cond body)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get body)
        (lint-unused-variable-quasiquote-expr (ast-node-get cond) state))]
    [(AstExpr.Begin exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(AstExpr.Unsafe exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(AstExpr.Set _ value)
      (lint-unused-variable-quasiquote-expr (ast-node-get value) state)]
    [(AstExpr.Ann inner _)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.Cast inner _)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.Borrow _ _ place)
      (lint-unused-variable-quasiquote-expr (ast-node-get place) state)]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (lint-unused-variable-quasiquote-match-arms
            arms
            (lint-unused-variable-quasiquote-expr
              (ast-node-get scrutinee)
              state))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach _ _ start end body)
          (lint-unused-variable-quasiquote-expr
            (ast-node-get body)
            (lint-unused-variable-quasiquote-expr
              (ast-node-get end)
              (lint-unused-variable-quasiquote-expr (ast-node-get start) state)))])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce _ _ _ start end init value)
          (lint-unused-variable-quasiquote-expr
            (ast-node-get value)
            (lint-unused-variable-quasiquote-expr
              (ast-node-get init)
              (lint-unused-variable-quasiquote-expr
                (ast-node-get end)
                (lint-unused-variable-quasiquote-expr
                  (ast-node-get start)
                  state))))])]
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan _ _ _ start end _ _ init value body)
          (lint-unused-variable-quasiquote-expr
            (ast-node-get body)
            (lint-unused-variable-quasiquote-expr
              (ast-node-get value)
              (lint-unused-variable-quasiquote-expr
                (ast-node-get init)
                (lint-unused-variable-quasiquote-expr
                  (ast-node-get end)
                  (lint-unused-variable-quasiquote-expr
                    (ast-node-get start)
                    state)))))])]
    [(AstExpr.SpmdBroadcast value lane)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get lane)
        (lint-unused-variable-quasiquote-expr (ast-node-get value) state))]
    [(AstExpr.SpmdShuffle value lane)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get lane)
        (lint-unused-variable-quasiquote-expr (ast-node-get value) state))]
    [(AstExpr.StructGet receiver _)
      (lint-unused-variable-quasiquote-expr (ast-node-get receiver) state)]
    [(AstExpr.StructSet receiver _ value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast-node-get receiver) state))]
    [(AstExpr.WithRegion _ body)
      (lint-unused-variable-quasiquote-expr-list body state)]
    [(AstExpr.WithEscape scratch body)
      (lint-unused-variable-quasiquote-expr-list
        body
        (lint-unused-variable-quasiquote-expr (ast-node-get scratch) state))]
    [(AstExpr.WithScratch body)
      (lint-unused-variable-quasiquote-expr-list body state)]
    [(AstExpr.InArena arena body)
      (lint-unused-variable-quasiquote-expr-list
        body
        (lint-unused-variable-quasiquote-expr (ast-node-get arena) state))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (lint-unused-variable-quasiquote-expr-list
            body
            (lint-unused-variable-quasiquote-resource-bindings bindings state))])]
    [(AstExpr.Box inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.BoxGet inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.BoxTake inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.BoxSet inner value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast-node-get inner) state))]
    [(AstExpr.Comptime inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.Quasiquote _) state]
    [(AstExpr.BracketClause items)
      (lint-unused-variable-quasiquote-expr-list items state)]
    [(AstExpr.Try inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.Return inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.PtrNullCheck inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.PtrAddrOf place)
      (lint-unused-variable-quasiquote-expr (ast-node-get place) state)]
    [(AstExpr.PtrRead ptr)
      (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state)]
    [(AstExpr.PtrWrite ptr value)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state))]
    [(AstExpr.PtrOffset ptr offset)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get offset)
        (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state))]
    [(AstExpr.PtrCast ptr _)
      (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state)]
    [(AstExpr.PtrToInt ptr)
      (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state)]
    [(AstExpr.IntToPtr value _)
      (lint-unused-variable-quasiquote-expr (ast-node-get value) state)]
    [(AstExpr.StringData inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.StringFromBytes ptr len)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get len)
        (lint-unused-variable-quasiquote-expr (ast-node-get ptr) state))]
    [(AstExpr.ArrayData inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.CpuIdEax leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast-node-get leaf) state))]
    [(AstExpr.CpuIdEbx leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast-node-get leaf) state))]
    [(AstExpr.CpuIdEcx leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast-node-get leaf) state))]
    [(AstExpr.CpuIdEdx leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast-node-get leaf) state))]
    [(AstExpr.Xgetbv index)
      (lint-unused-variable-quasiquote-expr (ast-node-get index) state)]
    [(AstExpr.Syscall args)
      (lint-unused-variable-quasiquote-expr-list args state)]
    [_ state]))

(define (lint-unused-variable-let-bindings
  [bindings : AstLetBindingList]
  [state : LintUnusedVariableState]
  [cursor : i64]) : LintUnusedVariableState
  (match bindings
    [(AstLetBindingList.Nil) state]
    [(AstLetBindingList.Cons binding rest)
      (match binding
        [(AstLetBinding.Binding name maybe-ty init)
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
      (lint-unused-variable-push-frame state LintUnusedVariableBindingList.Nil)]
    [with-bindings : LintUnusedVariableState
      (lint-unused-variable-let-bindings bindings with-frame cursor)]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-bindings span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-resource-bindings
  [bindings : AstResourceBindingList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match bindings
    [(AstResourceBindingList.Nil) state]
    [(AstResourceBindingList.Cons binding rest)
      (match binding
        [(AstResourceBinding.Binding name init cleanup)
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
    [(AstMatchArmList.Nil) state]
    [(AstMatchArmList.Cons arm rest)
      (match arm
        [(AstMatchArm.Arm pattern body)
          (let
            [with-frame : LintUnusedVariableState
              (lint-unused-variable-push-frame
                state
                LintUnusedVariableBindingList.Nil)]
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
        (+ start (string.string-length "(lambda")))]
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
          LintUnusedVariableBindingList.Nil))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-frame span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-scan-body-scope
  [index : i64]
  [prefix : i64]
  [body : AstExpr]
  [state : LintUnusedVariableState]
  [span : AstSourceSpan]) : LintUnusedVariableState
  (let
    [with-frame : LintUnusedVariableState
      (lint-unused-variable-push-frame
        state
        (lint-unused-variable-binding-cons
          (lint-unused-variable-binding (intern-str index) span false)
          (lint-unused-variable-binding-cons
            (lint-unused-variable-binding (intern-str prefix) span false)
            LintUnusedVariableBindingList.Nil)))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-frame span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-expr
  [expr : AstExpr]
  [state : LintUnusedVariableState]
  [span : AstSourceSpan]) : LintUnusedVariableState
  (match expr
    [(AstExpr.Spanned inner-box inner-span)
      (lint-unused-variable-expr (ast-node-get inner-box) state inner-span)]
    [(AstExpr.Literal _) state]
    [(AstExpr.Var name) (lint-unused-variable-read-var-id state name)]
    [(AstExpr.Binary _ left right)
      (lint-unused-variable-expr
        (ast-node-get right)
        (lint-unused-variable-expr (ast-node-get left) state span)
        span)]
    [(AstExpr.Unary _ inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.Call func args)
      (lint-unused-variable-expr-list
        args
        (lint-unused-variable-expr (ast-node-get func) state span))]
    [(AstExpr.If cond then-branch else-branch)
      (lint-unused-variable-expr
        (ast-node-get else-branch)
        (lint-unused-variable-expr
          (ast-node-get then-branch)
          (lint-unused-variable-expr (ast-node-get cond) state span)
          span)
        span)]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body)
          (lint-unused-variable-let bindings (ast-node-get body) state span)])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda params ret body)
          (lint-unused-variable-lambda
            params
            ret
            (ast-node-get body)
            state
            span)])]
    [(AstExpr.Tuple exprs) (lint-unused-variable-expr-list exprs state)]
    [(AstExpr.TupleRef tuple _)
      (lint-unused-variable-expr (ast-node-get tuple) state span)]
    [(AstExpr.Array exprs) (lint-unused-variable-expr-list exprs state)]
    [(AstExpr.MakeArray ty len)
      (lint-unused-variable-expr
        (ast-node-get len)
        (lint-unused-variable-type ty state)
        span)]
    [(AstExpr.ArrayRef array index)
      (lint-unused-variable-expr
        (ast-node-get index)
        (lint-unused-variable-expr (ast-node-get array) state span)
        span)]
    [(AstExpr.ArraySet array index value)
      (lint-unused-variable-expr
        (ast-node-get value)
        (lint-unused-variable-expr
          (ast-node-get index)
          (lint-unused-variable-expr (ast-node-get array) state span)
          span)
        span)]
    [(AstExpr.ArrayPush array value)
      (lint-unused-variable-expr
        (ast-node-get value)
        (lint-unused-variable-expr (ast-node-get array) state span)
        span)]
    [(AstExpr.StringRef text index)
      (lint-unused-variable-expr
        (ast-node-get index)
        (lint-unused-variable-expr (ast-node-get text) state span)
        span)]
    [(AstExpr.While cond body)
      (lint-unused-variable-expr
        (ast-node-get body)
        (lint-unused-variable-expr (ast-node-get cond) state span)
        span)]
    [(AstExpr.Begin exprs) (lint-unused-variable-expr-list exprs state)]
    [(AstExpr.Unsafe exprs) (lint-unused-variable-expr-list exprs state)]
    [(AstExpr.Set _ value)
      (lint-unused-variable-expr (ast-node-get value) state span)]
    [(AstExpr.Ann inner ty)
      (lint-unused-variable-type
        ty
        (lint-unused-variable-expr (ast-node-get inner) state span))]
    [(AstExpr.Cast inner ty)
      (lint-unused-variable-type
        ty
        (lint-unused-variable-expr (ast-node-get inner) state span))]
    [(AstExpr.Borrow _ lifetime place)
      (lint-unused-variable-expr
        (ast-node-get place)
        (lint-unused-variable-borrow-lifetime lifetime state)
        span)]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (lint-unused-variable-match-arms
            arms
            (lint-unused-variable-expr (ast-node-get scrutinee) state span))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach index index-ty start end body)
          (lint-unused-variable-index-scope
            index
            (ast-node-get body)
            (lint-unused-variable-type
              index-ty
              (lint-unused-variable-expr
                (ast-node-get end)
                (lint-unused-variable-expr (ast-node-get start) state span)
                span))
            span)])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce _ index index-ty start end init value)
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
            span)])]
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan
            _
            index
            index-ty
            start
            end
            prefix
            prefix-ty
            init
            value
            body)
          (let
            [base-state : LintUnusedVariableState
              (lint-unused-variable-type
                prefix-ty
                (lint-unused-variable-type
                  index-ty
                  (lint-unused-variable-expr
                    (ast-node-get init)
                    (lint-unused-variable-expr
                      (ast-node-get end)
                      (lint-unused-variable-expr
                        (ast-node-get start)
                        state
                        span)
                      span)
                    span)))]
            [value-state : LintUnusedVariableState
              (lint-unused-variable-index-scope
                index
                (ast-node-get value)
                base-state
                span)]
            (lint-unused-variable-scan-body-scope
              index
              prefix
              (ast-node-get body)
              value-state
              span))])]
    [(AstExpr.SpmdBroadcast value lane)
      (lint-unused-variable-expr
        (ast-node-get lane)
        (lint-unused-variable-expr (ast-node-get value) state span)
        span)]
    [(AstExpr.SpmdShuffle value lane)
      (lint-unused-variable-expr
        (ast-node-get lane)
        (lint-unused-variable-expr (ast-node-get value) state span)
        span)]
    [(AstExpr.StructGet receiver _)
      (lint-unused-variable-expr (ast-node-get receiver) state span)]
    [(AstExpr.StructSet receiver _ value)
      (lint-unused-variable-expr
        (ast-node-get value)
        (lint-unused-variable-expr (ast-node-get receiver) state span)
        span)]
    [(AstExpr.WithRegion _ body) (lint-unused-variable-expr-list body state)]
    [(AstExpr.WithEscape scratch body)
      (lint-unused-variable-expr-list
        body
        (lint-unused-variable-expr (ast-node-get scratch) state span))]
    [(AstExpr.WithScratch body) (lint-unused-variable-expr-list body state)]
    [(AstExpr.InArena arena body)
      (lint-unused-variable-expr-list
        body
        (lint-unused-variable-expr (ast-node-get arena) state span))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (let
            [with-frame : LintUnusedVariableState
              (lint-unused-variable-push-frame
                state
                LintUnusedVariableBindingList.Nil)]
            [with-bindings : LintUnusedVariableState
              (lint-unused-variable-resource-bindings bindings with-frame)]
            [with-body : LintUnusedVariableState
              (lint-unused-variable-expr-list body with-bindings)]
            (lint-unused-variable-pop-frame with-body))])]
    [(AstExpr.Box inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.BoxGet inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.BoxTake inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.BoxSet inner value)
      (lint-unused-variable-expr
        (ast-node-get value)
        (lint-unused-variable-expr (ast-node-get inner) state span)
        span)]
    [(AstExpr.TypeLiteral ty) (lint-unused-variable-type ty state)]
    [(AstExpr.Init maybe-ty) (lint-unused-variable-maybe-type maybe-ty state)]
    [(AstExpr.Comptime inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.Quote _) state]
    [(AstExpr.Quasiquote inner)
      (lint-unused-variable-quasiquote-expr (ast-node-get inner) state)]
    [(AstExpr.Unquote inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.UnquoteSplicing inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.BracketClause items) (lint-unused-variable-expr-list items state)]
    [(AstExpr.Try inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.Return inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.PtrNull ty) (lint-unused-variable-type ty state)]
    [(AstExpr.PtrNullCheck inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.PtrAddrOf place)
      (lint-unused-variable-expr (ast-node-get place) state span)]
    [(AstExpr.PtrRead ptr)
      (lint-unused-variable-expr (ast-node-get ptr) state span)]
    [(AstExpr.PtrWrite ptr value)
      (lint-unused-variable-expr
        (ast-node-get value)
        (lint-unused-variable-expr (ast-node-get ptr) state span)
        span)]
    [(AstExpr.PtrOffset ptr offset)
      (lint-unused-variable-expr
        (ast-node-get offset)
        (lint-unused-variable-expr (ast-node-get ptr) state span)
        span)]
    [(AstExpr.PtrCast ptr ty)
      (lint-unused-variable-type
        ty
        (lint-unused-variable-expr (ast-node-get ptr) state span))]
    [(AstExpr.PtrToInt ptr)
      (lint-unused-variable-expr (ast-node-get ptr) state span)]
    [(AstExpr.IntToPtr value ty)
      (lint-unused-variable-type
        ty
        (lint-unused-variable-expr (ast-node-get value) state span))]
    [(AstExpr.StringData inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.StringFromBytes ptr len)
      (lint-unused-variable-expr
        (ast-node-get len)
        (lint-unused-variable-expr (ast-node-get ptr) state span)
        span)]
    [(AstExpr.ArrayData inner)
      (lint-unused-variable-expr (ast-node-get inner) state span)]
    [(AstExpr.BinaryData _) state]
    [(AstExpr.SpmdProgramIndex) state]
    [(AstExpr.SpmdProgramCount) state]
    [(AstExpr.ProgramArgc) state]
    [(AstExpr.ProgramArgv) state]
    [(AstExpr.ProgramEnvp) state]
    [(AstExpr.CpuIdEax leaf subleaf)
      (lint-unused-variable-expr
        (ast-node-get subleaf)
        (lint-unused-variable-expr (ast-node-get leaf) state span)
        span)]
    [(AstExpr.CpuIdEbx leaf subleaf)
      (lint-unused-variable-expr
        (ast-node-get subleaf)
        (lint-unused-variable-expr (ast-node-get leaf) state span)
        span)]
    [(AstExpr.CpuIdEcx leaf subleaf)
      (lint-unused-variable-expr
        (ast-node-get subleaf)
        (lint-unused-variable-expr (ast-node-get leaf) state span)
        span)]
    [(AstExpr.CpuIdEdx leaf subleaf)
      (lint-unused-variable-expr
        (ast-node-get subleaf)
        (lint-unused-variable-expr (ast-node-get leaf) state span)
        span)]
    [(AstExpr.Xgetbv index)
      (lint-unused-variable-expr (ast-node-get index) state span)]
    [(AstExpr.Syscall args) (lint-unused-variable-expr-list args state)]))

(define (lint-unused-variable-decl-param-cursor
  [source : String]
  [prefix : String]
  [name : String]
  [fallback : AstSourceSpan]) : i64
  (let
    [needle : String (string.string-append prefix name)]
    [source-len : i64 (string.string-length source)]
    [found : i64 (- 0 1)]
    [cursor : i64 0]
    (begin
      (while (and (< found 0) (< cursor source-len))
        (let
          [candidate : i64 (lint-source-find-prefix-from source needle cursor)]
          (if (< candidate 0)
            (set! cursor source-len)
            (let
              [end : i64 (+ candidate (string.string-length needle))]
              (if (lint-source-symbol-boundary? source end)
                (set! found candidate)
                (set! cursor (+ candidate 1)))))))
      (if (< found 0)
        (let
          [fallback-start : i64 (lint-source-span-start-index source fallback)]
          (if (< fallback-start 0)
            0
            fallback-start))
        (+ found (string.string-length needle))))))

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
        (LintUnusedVariableState source LintUnusedVariableFrameList.Nil acc)
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
        (LintUnusedVariableState source LintUnusedVariableFrameList.Nil acc)
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
    [(AstDecl.Def _ maybe-ty body)
      (struct-get
        (lint-unused-variable-expr
          (ast-node-get body)
          (lint-unused-variable-maybe-type
            maybe-ty
            (LintUnusedVariableState source LintUnusedVariableFrameList.Nil acc))
          (lint-no-effect-span (ast-node-get body)))
        findings)]
    [(AstDecl.DefFn name params ret body _)
      (lint-unused-variable-decl-with-param-frame
        source
        "(define ("
        name
        params
        ret
        body
        acc)]
    [(AstDecl.DefMacro name params ret body)
      (lint-unused-variable-decl-with-macro-param-frame
        source
        "(defmacro ("
        name
        params
        ret
        body
        acc)]
    [(AstDecl.Test _ body _)
      (struct-get
        (lint-unused-variable-expr
          (ast-node-get body)
          (LintUnusedVariableState source LintUnusedVariableFrameList.Nil acc)
          (lint-no-effect-span (ast-node-get body)))
        findings)]
    [(AstDecl.Unsafe inner)
      (lint-unused-variables-in-decl source (box-get inner) acc)]
    [(AstDecl.ComptimeDecl _ inner)
      (lint-unused-variables-in-decl source (box-get inner) acc)]
    [_ acc]))

(define (lint-unused-variables-in-decl-list
  [source : String]
  [decls : AstDeclList]
  [acc : LintFindings]) : LintFindings
  (match decls
    [(AstDeclList.Nil) acc]
    [(AstDeclList.Cons decl rest)
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
    [(AstExprList.Nil) acc]
    [(AstExprList.Cons head rest)
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
    [(AstExprList.Nil) acc]
    [(AstExprList.Cons head rest)
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
            (lint-walk-expr
              head
              threshold
              (lint-add-redundant-divergence-padding head rest acc))
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
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match inner
          [(AstExpr.Begin _) (lint-walk-expr expr threshold acc)]
          [(AstExpr.WithRegion _ _) (lint-walk-expr expr threshold acc)]
          [(AstExpr.WithEscape _ _) (lint-walk-expr expr threshold acc)]
          [(AstExpr.WithScratch _) (lint-walk-expr expr threshold acc)]
          [(AstExpr.InArena _ _) (lint-walk-expr expr threshold acc)]
          [(AstExpr.WithResource _) (lint-walk-expr expr threshold acc)]
          [_ (lint-walk-discarded-nonsequence-expr expr threshold acc)]))]
    [(AstExpr.Begin _) (lint-walk-expr expr threshold acc)]
    [(AstExpr.WithRegion _ _) (lint-walk-expr expr threshold acc)]
    [(AstExpr.WithEscape _ _) (lint-walk-expr expr threshold acc)]
    [(AstExpr.WithScratch _) (lint-walk-expr expr threshold acc)]
    [(AstExpr.InArena _ _) (lint-walk-expr expr threshold acc)]
    [(AstExpr.WithResource _) (lint-walk-expr expr threshold acc)]
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
    [(AstExprList.Nil) acc]
    [(AstExprList.Cons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if after-terminal
          (lint-findings-add
            (lint-unreachable-code-finding (lint-no-effect-span head))
            acc)
          (let
            [with-padding : LintFindings
              (lint-add-redundant-divergence-padding head rest acc)]
            [walked : LintFindings
              (match rest
                [(AstExprList.Nil) (lint-walk-expr head threshold with-padding)]
                [_ (lint-walk-discarded-expr head threshold with-padding)])]
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

(define (lint-expr-list-single? [exprs : AstExprList]) : bool
  (match exprs
    [(AstExprList.Nil) false]
    [(AstExprList.Cons _ rest)
      (match (box-get rest)
        [(AstExprList.Nil) true]
        [_ false])]))

(define (lint-add-single-begin
  [exprs : AstExprList]
  [span : AstSourceSpan]
  [acc : LintFindings]) : LintFindings
  (if (lint-expr-list-single? exprs)
    (lint-findings-add (lint-single-begin-finding span) acc)
    acc))

(define (lint-walk-tail-sequence-expr-list-after-terminal
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]) : LintFindings
  (match exprs
    [(AstExprList.Nil) acc]
    [(AstExprList.Cons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if after-terminal
          (lint-findings-add
            (lint-unreachable-code-finding (lint-no-effect-span head))
            acc)
          (let
            [with-padding : LintFindings
              (lint-add-redundant-divergence-padding head rest acc)]
            [walked : LintFindings
              (match rest
                [(AstExprList.Nil)
                  (lint-walk-tail-expr head threshold with-padding)]
                [_ (lint-walk-discarded-expr head threshold with-padding)])]
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
    [(AstLetBindingList.Nil) acc]
    [(AstLetBindingList.Cons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding.Binding _ _ init-box)
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
    [(AstLetBindingList.Nil) false]
    [(AstLetBindingList.Cons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding.Binding binding-name _ _)
            (if (= binding-name name)
              true
              (lint-let-bindings-contain-name? rest name))]))]))

(define (lint-let-bindings-shadow-outer?
  [outer : AstLetBindingList]
  [inner : AstLetBindingList]) : bool
  (match inner
    [(AstLetBindingList.Nil) false]
    [(AstLetBindingList.Cons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding.Binding name _ _)
            (if (lint-let-bindings-contain-name? outer name)
              true
              (lint-let-bindings-shadow-outer? outer rest))]))]))

(define (lint-nested-let-body? [body : AstExpr]) : bool
  (match body
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-nested-let-body? inner))]
    [(AstExpr.Let _) true]
    [_ false]))

(define (lint-nested-let-shadows? [outer : AstLetBindingList] [body : AstExpr]) : bool
  (match body
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-nested-let-shadows? outer inner))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let inner-bindings _)
          (lint-let-bindings-shadow-outer? outer inner-bindings)])]
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
    [(AstResourceBindingList.Nil) acc]
    [(AstResourceBindingList.Cons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding.Binding _ init-box cleanup-box)
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
    [(AstMatchArmList.Nil) acc]
    [(AstMatchArmList.Cons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm.Arm _ body-box)
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
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-ladder inner threshold tail-return-path acc))]
    [(AstExpr.If cond-box then-branch-box else-branch-box)
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
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-return-path-chain inner threshold acc))]
    [(AstExpr.If cond-box then-branch-box else-branch-box)
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
          (AstExpr.If
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
          (AstExpr.If
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
    [(AstExprList.Nil) acc]
    [(AstExprList.Cons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (if after-terminal
          (lint-findings-add
            (lint-unreachable-code-finding (lint-no-effect-span head))
            acc)
          (let
            [with-padding : LintFindings
              (lint-add-redundant-divergence-padding head rest acc)]
            [walked : LintFindings
              (match rest
                [(AstExprList.Nil)
                  (lint-walk-tail-expr head threshold with-padding)]
                [_ (lint-walk-expr head threshold with-padding)])]
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
    [(AstMatchArmList.Nil) acc]
    [(AstMatchArmList.Cons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm.Arm _ body-box)
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
    [(AstExpr.Spanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match inner
          [(AstExpr.If cond-box then-branch-box else-branch-box)
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
          [(AstExpr.Let let-box)
            (match (box-get let-box)
              [(AstLet.Let bindings body-box)
                (let
                  [body : AstExpr (ast-node-get body-box)]
                  (lint-walk-tail-let bindings body span threshold acc))])]
          [(AstExpr.Call func-box args)
            (let
              [func : AstExpr (ast-node-get func-box)]
              (lint-walk-call func args span threshold acc))]
          [(AstExpr.Begin exprs)
            (lint-walk-tail-sequence-expr-list
              exprs
              threshold
              (lint-add-single-begin exprs span acc))]
          [_ (lint-walk-tail-expr inner threshold acc)]))]
    [(AstExpr.If cond-box then-branch-box else-branch-box)
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
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (lint-walk-tail-let bindings body (lint-no-span) threshold acc))])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda _ _ body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (lint-walk-tail-expr body threshold acc))])]
    [(AstExpr.Begin exprs)
      (lint-walk-tail-sequence-expr-list
        exprs
        threshold
        (lint-add-single-begin exprs (lint-no-span) acc))]
    [(AstExpr.Unsafe exprs) (lint-walk-tail-expr-list exprs threshold acc)]
    [(AstExpr.Ann inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-tail-expr inner threshold acc))]
    [(AstExpr.Cast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-tail-expr inner threshold acc))]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ast-node-get scrutinee-box)]
            (lint-walk-tail-match-arms
              arms
              threshold
              (lint-walk-expr scrutinee threshold acc)))])]
    [(AstExpr.WithRegion _ body)
      (lint-walk-tail-sequence-expr-list body threshold acc)]
    [(AstExpr.WithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (lint-walk-tail-sequence-expr-list
          body
          threshold
          (lint-walk-expr scratch threshold acc)))]
    [(AstExpr.WithScratch body)
      (lint-walk-tail-sequence-expr-list body threshold acc)]
    [(AstExpr.InArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (lint-walk-tail-sequence-expr-list
          body
          threshold
          (lint-walk-expr arena threshold acc)))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (lint-walk-tail-sequence-expr-list
            body
            threshold
            (lint-walk-resource-bindings bindings threshold acc))])]
    [(AstExpr.Try inner-box)
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
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (if (lint-and-or-call-kind? op inner)
          (lint-walk-and-or-skip-expr op inner threshold acc)
          (lint-walk-expr expr threshold acc)))]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (if (string.string-eq (lint-and-or-func-op func) op)
          (lint-walk-and-or-skip-args op args threshold acc)
          (lint-walk-expr expr threshold acc)))]
    [_ (lint-walk-expr expr threshold acc)]))

(define (lint-walk-and-or-skip-args
  [op : String]
  [args : AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match args
    [(AstExprList.Nil) acc]
    [(AstExprList.Cons head rest)
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
    (if (and
      (not (string.string-eq op ""))
      (lint-and-or-args-have-kind? op args))
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
    [(AstExpr.Spanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match inner
          [(AstExpr.If cond-box then-branch-box else-branch-box)
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
          [(AstExpr.Let let-box)
            (match (box-get let-box)
              [(AstLet.Let bindings body-box)
                (let
                  [body : AstExpr (ast-node-get body-box)]
                  (lint-walk-let bindings body span threshold acc))])]
          [(AstExpr.Call func-box args)
            (let
              [func : AstExpr (ast-node-get func-box)]
              (lint-walk-call func args span threshold acc))]
          [(AstExpr.Begin exprs)
            (lint-walk-value-sequence-expr-list
              exprs
              threshold
              (lint-add-single-begin exprs span acc))]
          [_ (lint-walk-expr inner threshold acc)]))]
    [(AstExpr.Literal _) acc]
    [(AstExpr.Var _) acc]
    [(AstExpr.TypeLiteral _) acc]
    [(AstExpr.Init _) acc]
    [(AstExpr.Binary _ left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (lint-walk-expr right threshold (lint-walk-expr left threshold acc)))]
    [(AstExpr.Unary _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lint-walk-call func args (lint-no-span) threshold acc))]
    [(AstExpr.If cond-box then-branch-box else-branch-box)
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
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (lint-walk-let bindings body (lint-no-span) threshold acc))])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda _ _ body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (lint-walk-expr body threshold acc))])]
    [(AstExpr.Tuple exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExpr.TupleRef tuple-box _)
      (let
        [tuple : AstExpr (ast-node-get tuple-box)]
        (lint-walk-expr tuple threshold acc))]
    [(AstExpr.Array exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExpr.MakeArray _ len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (lint-walk-expr len threshold acc))]
    [(AstExpr.ArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lint-walk-expr index threshold (lint-walk-expr array threshold acc)))]
    [(AstExpr.ArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr
          value
          threshold
          (lint-walk-expr index threshold (lint-walk-expr array threshold acc))))]
    [(AstExpr.ArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr array threshold acc)))]
    [(AstExpr.StringRef str-box index-box)
      (let
        [str : AstExpr (ast-node-get str-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lint-walk-expr index threshold (lint-walk-expr str threshold acc)))]
    [(AstExpr.While cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-expr body threshold (lint-walk-expr cond threshold acc)))]
    [(AstExpr.Begin exprs)
      (lint-walk-value-sequence-expr-list
        exprs
        threshold
        (lint-add-single-begin exprs (lint-no-span) acc))]
    [(AstExpr.Unsafe exprs)
      (lint-walk-plain-sequence-expr-list exprs threshold acc)]
    [(AstExpr.Set _ value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold acc))]
    [(AstExpr.Ann inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.Cast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.Borrow _ _ place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (lint-walk-expr place threshold acc))]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ast-node-get scrutinee-box)]
            (lint-walk-match-arms
              arms
              threshold
              (lint-walk-expr scrutinee threshold acc)))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach _ _ start-box end-box body-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [body : AstExpr (ast-node-get body-box)]
            (lint-walk-expr
              body
              threshold
              (lint-walk-expr
                end
                threshold
                (lint-walk-expr start threshold acc))))])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce _ _ _ start-box end-box init-box value-box)
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
                (lint-walk-expr
                  end
                  threshold
                  (lint-walk-expr start threshold acc)))))])]
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan
            _
            _
            _
            start-box
            end-box
            _
            _
            init-box
            value-box
            body-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            [body : AstExpr (ast-node-get body-box)]
            (lint-walk-expr
              body
              threshold
              (lint-walk-expr
                value
                threshold
                (lint-walk-expr
                  init
                  threshold
                  (lint-walk-expr
                    end
                    threshold
                    (lint-walk-expr start threshold acc))))))])]
    [(AstExpr.SpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (lint-walk-expr lane threshold (lint-walk-expr value threshold acc)))]
    [(AstExpr.SpmdShuffle value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (lint-walk-expr lane threshold (lint-walk-expr value threshold acc)))]
    [(AstExpr.StructGet receiver-box _)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (lint-walk-expr receiver threshold acc))]
    [(AstExpr.StructSet receiver-box _ value-box)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr receiver threshold acc)))]
    [(AstExpr.WithRegion _ body)
      (lint-walk-value-sequence-expr-list body threshold acc)]
    [(AstExpr.WithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (lint-walk-value-sequence-expr-list
          body
          threshold
          (lint-walk-expr scratch threshold acc)))]
    [(AstExpr.WithScratch body)
      (lint-walk-value-sequence-expr-list body threshold acc)]
    [(AstExpr.InArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (lint-walk-value-sequence-expr-list
          body
          threshold
          (lint-walk-expr arena threshold acc)))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (lint-walk-value-sequence-expr-list
            body
            threshold
            (lint-walk-resource-bindings bindings threshold acc))])]
    [(AstExpr.Box inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.BoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.BoxTake inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.BoxSet inner-box value-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr inner threshold acc)))]
    [(AstExpr.Comptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.Quote _) acc]
    [(AstExpr.Quasiquote _) acc]
    [(AstExpr.Unquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.BracketClause items) (lint-walk-expr-list items threshold acc)]
    [(AstExpr.Try inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.Return inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.PtrNull _) acc]
    [(AstExpr.PtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.PtrAddrOf _) acc]
    [(AstExpr.PtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lint-walk-expr ptr threshold acc))]
    [(AstExpr.PtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr ptr threshold acc)))]
    [(AstExpr.PtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (lint-walk-expr offset threshold (lint-walk-expr ptr threshold acc)))]
    [(AstExpr.PtrCast ptr-box _)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lint-walk-expr ptr threshold acc))]
    [(AstExpr.PtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lint-walk-expr ptr threshold acc))]
    [(AstExpr.IntToPtr value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lint-walk-expr value threshold acc))]
    [(AstExpr.StringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.StringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (lint-walk-expr len threshold (lint-walk-expr ptr threshold acc)))]
    [(AstExpr.ArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(AstExpr.BinaryData _) acc]
    [(AstExpr.SpmdProgramIndex) acc]
    [(AstExpr.SpmdProgramCount) acc]
    [(AstExpr.ProgramArgc) acc]
    [(AstExpr.ProgramArgv) acc]
    [(AstExpr.ProgramEnvp) acc]
    [(AstExpr.CpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(AstExpr.CpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(AstExpr.CpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(AstExpr.CpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(AstExpr.Xgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (lint-walk-expr index threshold acc))]
    [(AstExpr.Syscall args) (lint-walk-expr-list args threshold acc)]))

;: Walk the body expression(s) carried by a declaration, if any.
(define (lint-walk-decl [decl : AstDecl] [threshold : i64] [acc : LintFindings]) : LintFindings
  (match decl
    [(AstDecl.Def _ _ body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-expr body threshold acc))]
    [(AstDecl.DefFn _ _ _ body-box _)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(AstDecl.DefMacro _ _ _ body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(AstDecl.Test _ body-box _)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lint-walk-decl inner threshold acc))]
    [(AstDecl.ComptimeDecl _ inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lint-walk-decl inner threshold acc))]
    [(AstDecl.Module _) acc]
    [(AstDecl.Extern _ _ _ _) acc]
    [(AstDecl.DefEnum _ _ _) acc]
    [(AstDecl.DefEnumLifetimes _ _ _ _) acc]
    [(AstDecl.DefStruct _ _ _ _) acc]
    [(AstDecl.DefStructLifetimes _ _ _ _ _) acc]
    [(AstDecl.DefDispatch _ _) acc]
    [(AstDecl.IncludeStr _ _) acc]
    [(AstDecl.IncludeBin _ _) acc]
    [(AstDecl.Import _) acc]))

;: Walk every declaration body in `decls`.
(define (lint-walk-decl-list
  [decls : AstDeclList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match decls
    [(AstDeclList.Nil) acc]
    [(AstDeclList.Cons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (lint-walk-decl-list rest threshold (lint-walk-decl decl threshold acc)))]))

(define (lint-program-with-source
  [source : String]
  [program : AstProgram]
  [threshold : i64]) : LintFindings
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [copy-on-update-shapes : LintCopyOnUpdateStructList
          (lint-copy-on-update-collect-structs
            decls
            LintCopyOnUpdateStructList.Nil)]
        [walked : LintFindings
          (lint-walk-decl-list decls threshold (lint-findings-empty))]
        [unused-assignments : LintFindings
          (lint-unused-assignments-in-decl-list decls walked)]
        [copy-on-update : LintFindings
          (lint-copy-on-update-structs-in-decl-list
            decls
            copy-on-update-shapes
            unused-assignments)]
        [unused-imports : LintFindings
          (lint-unused-imports-in-decl-list source decls decls copy-on-update)]
        (lint-unused-variables-in-decl-list source decls unused-imports))]))

;: Run all lint rules over `program`, returning the collected findings.
(define (lint-program [program : AstProgram] [threshold : i64]) : LintFindings
  (lint-program-with-source "" program threshold))

(define (lint-program-with-deprecated-string-concat
  [source : String]
  [program : AstProgram]
  [threshold : i64]) : LintFindings
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [copy-on-update-shapes : LintCopyOnUpdateStructList
          (lint-copy-on-update-collect-structs
            decls
            LintCopyOnUpdateStructList.Nil)]
        [walked : LintFindings
          (lint-walk-decl-list decls threshold (lint-findings-empty))]
        [unused-assignments : LintFindings
          (lint-unused-assignments-in-decl-list decls walked)]
        [copy-on-update : LintFindings
          (lint-copy-on-update-structs-in-decl-list
            decls
            copy-on-update-shapes
            unused-assignments)]
        [unused-imports : LintFindings
          (lint-unused-imports-in-decl-list source decls decls copy-on-update)]
        (lint-deprecated-string-concat-scan
          source
          (lint-unused-variables-in-decl-list source decls unused-imports)))]))

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
  (ast-node-push (AstExpr.Var (intern name))))

(define (lint-test-expr-list2 [a : i64] [b : i64]) : AstExprList
  (ast-expr-cons a (ast-expr-cons b AstExprList.Nil)))

(define (lint-test-expr-list3 [a : i64] [b : i64] [c : i64]) : AstExprList
  (ast-expr-cons a (ast-expr-cons b (ast-expr-cons c AstExprList.Nil))))

(define (compiler-lint-self-test) : i64
  (let
    [vx : i64 (lint-test-var "x")]
    [vy : i64 (lint-test-var "y")]
    [vz : i64 (lint-test-var "z")]
    [one : i64 (ast-node-push (AstExpr.Literal (ast-lit-int 1)))]
    [unit-expr : i64 (ast-node-push (AstExpr.Literal AstLitUnit))]
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
      (ast-expr-set "ok" (ast-node-push (AstExpr.Literal (AstLitBool false))))]
    [unit-then-guard : i64 (ast-expr-if vx unit-expr return-one)]
    [unit-else-guard : i64 (ast-expr-if vx return-one unit-expr)]
    [unit-value-guard : i64 (ast-expr-if vx one unit-expr)]
    [unit-not-set-guard : i64 (ast-expr-if not-vx unit-expr set-ok-false)]
    [nested : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons unit-expr (ast-expr-cons ladder3 AstExprList.Nil))))]
    [in-let : i64
      (ast-expr-let
        (ast-let-binding-cons
          (ast-let-binding "y" (AstMaybeType.No) ladder3)
          (AstLetBindingList.Nil))
        vx)]
    [outer-let-bindings : AstLetBindingList
      (ast-let-binding-cons
        (ast-let-binding "a" (AstMaybeType.No) one)
        (AstLetBindingList.Nil))]
    [inner-let-bindings : AstLetBindingList
      (ast-let-binding-cons
        (ast-let-binding "b" (AstMaybeType.No) vx)
        (AstLetBindingList.Nil))]
    [shadowing-let-bindings : AstLetBindingList
      (ast-let-binding-cons
        (ast-let-binding "a" (AstMaybeType.No) one)
        (AstLetBindingList.Nil))]
    [nested-let : i64
      (ast-expr-let outer-let-bindings (ast-expr-let inner-let-bindings vx))]
    [shadowing-nested-let : i64
      (ast-expr-let outer-let-bindings (ast-expr-let shadowing-let-bindings vx))]
    [begin-inner-let : i64
      (ast-expr-let
        outer-let-bindings
        (ast-node-push
          (AstExpr.Begin
            (ast-expr-cons
              (ast-expr-let inner-let-bindings vx)
              (ast-expr-cons vx (AstExprList.Nil))))))]
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
    [discarded-cast : i64 (ast-expr-cast one (AstType.I64))]
    [discarded-call : i64
      (ast-expr-call (lint-test-var "side-effect?") AstExprList.Nil)]
    [no-effect-literal-begin : i64
      (ast-node-push
        (AstExpr.Begin (ast-expr-cons one (ast-expr-cons vx AstExprList.Nil))))]
    [no-effect-var-begin : i64
      (ast-node-push
        (AstExpr.Begin (ast-expr-cons vx (ast-expr-cons one AstExprList.Nil))))]
    [no-effect-add-begin : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons discarded-add (ast-expr-cons vx AstExprList.Nil))))]
    [no-effect-cast-begin : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons discarded-cast (ast-expr-cons vx AstExprList.Nil))))]
    [no-effect-tail-begin : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons unit-expr (ast-expr-cons one AstExprList.Nil))))]
    [no-effect-clean-call-begin : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons discarded-call (ast-expr-cons vx AstExprList.Nil))))]
    [no-effect-clean-mutation-begin : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons set-ok-false (ast-expr-cons vx AstExprList.Nil))))]
    [no-effect-unsafe-begin : i64
      (ast-node-push
        (AstExpr.Unsafe (ast-expr-cons one (ast-expr-cons vx AstExprList.Nil))))]
    [spanned-no-effect-var : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons
            (ast-expr-spanned vx (AstSourceSpan 31 9 31 10))
            (ast-expr-cons one AstExprList.Nil))))]
    [spanned-unreachable-var : i64
      (ast-expr-spanned vx (AstSourceSpan 41 9 41 10))]
    [unreachable-return-begin : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons
            return-one
            (ast-expr-cons
              spanned-unreachable-var
              (ast-expr-cons vy AstExprList.Nil)))))]
    [panic-call : i64
      (ast-expr-call
        (lint-test-var "panic")
        (ast-expr-cons one AstExprList.Nil))]
    [spanned-panic-call : i64
      (ast-expr-spanned panic-call (AstSourceSpan 43 9 43 24))]
    [qualified-panic-call : i64
      (ast-expr-call
        (lint-test-var "io.panic")
        (ast-expr-cons one AstExprList.Nil))]
    [spanned-qualified-panic-call : i64
      (ast-expr-spanned qualified-panic-call (AstSourceSpan 44 9 44 27))]
    [redundant-padding-begin : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons spanned-panic-call (ast-expr-cons vx AstExprList.Nil))))]
    [qualified-padding-begin : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons
            spanned-qualified-panic-call
            (ast-expr-cons vx AstExprList.Nil))))]
    [clean-panic-tail-begin : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons
            unit-expr
            (ast-expr-cons spanned-panic-call AstExprList.Nil))))]
    [unreachable-panic-unsafe : i64
      (ast-node-push
        (AstExpr.Unsafe
          (ast-expr-cons panic-call (ast-expr-cons vx AstExprList.Nil))))]
    [branch-local-return-begin : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons
            (ast-expr-if vx return-one return-one)
            (ast-expr-cons vx AstExprList.Nil))))]
    [single-begin : i64
      (ast-node-push (AstExpr.Begin (ast-expr-cons vx AstExprList.Nil)))]
    [spanned-single-begin : i64
      (ast-expr-spanned single-begin (AstSourceSpan 51 3 51 13))]
    [empty-begin : i64 (ast-node-push (AstExpr.Begin AstExprList.Nil))]
    (begin
      ;; ladder length math
      (if (= (lint-test-ladder-length ladder3) 3)
        unit
        (io.panic "lint: ladder3 length should be 3"))
      (if (= (lint-test-ladder-length ladder2) 2)
        unit
        (io.panic "lint: ladder2 length should be 2"))
      (if (= (lint-test-ladder-length vx) 0)
        unit
        (io.panic "lint: non-if ladder length should be 0"))
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
        (io.panic "lint: 3-deep ladder should be flagged once"))
      (match (lint-findings-get
        (lint-test-walk
          ladder3
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (if (and
            (= (struct-get finding depth) 3)
            (string.string-eq
              (struct-get finding rule-id)
              (lint-rule-nested-if-ladder-id)))
            unit
            (io.panic
              "lint: 3-deep ladder finding should carry rule id and depth"))]
        [(LintMaybeFinding.No)
          (io.panic "lint: 3-deep ladder should produce a finding")])
      ;; a 2-deep ladder is NOT flagged at threshold 3
      (if (=
        (lint-findings-count
          (lint-test-walk
            ladder2
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: 2-deep ladder should not be flagged at threshold 3"))
      ;; ... and is flagged at threshold 2, where its length meets the bound.
      (if (=
        (lint-findings-count (lint-test-walk ladder2 2 (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: 2-deep ladder should be flagged at threshold 2"))
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
        (io.panic "lint: return-path chain should not flag in a value context"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            return-chain3
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: return-path chain should be flagged once"))
      (match (lint-findings-get
        (lint-test-walk-tail
          return-chain3
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (if (string.string-eq
            (struct-get finding rule-id)
            (lint-rule-return-path-chain-id))
            unit
            (io.panic "lint: return-path chain should report its rule id"))]
        [(LintMaybeFinding.No)
          (io.panic "lint: return-path chain should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk
            unit-then-guard
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: unit then-branch should be flagged once"))
      (match (lint-findings-get
        (lint-test-walk
          unit-else-guard
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (if (string.string-eq
            (struct-get finding rule-id)
            (lint-rule-unit-if-guard-id))
            unit
            (io.panic "lint: unit-if guard should report its rule id"))]
        [(LintMaybeFinding.No)
          (io.panic "lint: unit-if guard should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk
            unit-value-guard
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: unit-if guard should skip value branches"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            unit-not-set-guard
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: inverted unit set! guard should be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            nested
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: ladder nested in begin should be flagged once"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            single-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: single begin should be flagged once"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            single-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: tail single begin should be flagged once"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            empty-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: empty begin should not be flagged as single begin"))
      (match (lint-findings-get
        (lint-test-walk
          spanned-single-begin
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 51)
              (string.string-eq
                (struct-get finding rule-id)
                (lint-rule-single-begin-id)))
              unit
              (io.panic
                "lint: single-begin finding should carry rule id and span")))]
        [(LintMaybeFinding.No)
          (io.panic "lint: spanned single begin should produce a finding")])
      ;; ... and into let-binding initializers
      (if (=
        (lint-findings-count
          (lint-test-walk
            in-let
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: ladder in a let binding should be flagged once"))
      ;; Longer ladders are flagged once at the head with their full depth.
      (if (=
        (lint-findings-count
          (lint-test-walk
            ladder4
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: 4-deep ladder should be flagged once"))
      ;; A spanned ladder carries its head wrapper span on the finding.
      (match (lint-findings-get
        (lint-test-walk
          spanned
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 7)
              (string.string-eq
                (struct-get finding rule-id)
                (lint-rule-nested-if-ladder-id)))
              unit
              (io.panic
                "lint: spanned ladder finding should carry rule id and span")))]
        [(LintMaybeFinding.No)
          (io.panic "lint: spanned ladder should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk
            nested-let
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: body-only nested let should be flagged once"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            shadowing-nested-let
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: shadowing nested let should not be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            begin-inner-let
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: let with nontrivial begin body should not be flagged"))
      (match (lint-findings-get
        (lint-test-walk
          spanned-nested-let
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 11)
              (string.string-eq
                (struct-get finding rule-id)
                (lint-rule-nested-let-id)))
              unit
              (io.panic
                "lint: nested-let finding should carry rule id and span")))]
        [(LintMaybeFinding.No)
          (io.panic "lint: spanned nested let should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk
            and-cascade
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: nested and should be flagged once"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            or-cascade
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: nested or should be flagged once"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            flat-and
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: flat and should not be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            mixed-and-or
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: mixed and/or should not be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk
            double-and-cascade
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: one maximal and cascade should produce one finding"))
      (match (lint-findings-get
        (lint-test-walk
          spanned-and-cascade
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 21)
              (= (struct-get finding depth) 3)
              (string.string-eq
                (struct-get finding rule-id)
                (lint-rule-cascading-and-or-id))
              (string.string-eq
                (struct-get finding message)
                "cascading and: prefer flat n-ary form (and x y z)"))
              unit
              (io.panic "lint: cascading-and-or finding metadata mismatch")))]
        [(LintMaybeFinding.No)
          (io.panic "lint: spanned and cascade should produce a finding")])
      (match (lint-findings-get
        (lint-test-walk
          core-and-cascade
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (if (string.string-eq
            (struct-get finding message)
            (string.string-append
              "cascading and: prefer flat n-ary form ("
              (string.string-append "core/and" " x y z)")))
            unit
            (io.panic "lint: core/and cascade should preserve callee spelling"))]
        [(LintMaybeFinding.No)
          (io.panic "lint: core/and cascade should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-literal-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: discarded literal should be flagged"))
      (match (lint-findings-get
        (lint-test-walk-tail
          spanned-no-effect-var
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 31)
              (string.string-eq
                (struct-get finding rule-id)
                (lint-rule-no-effect-id)))
              unit
              (io.panic "lint: no-effect finding should carry rule id and span")))]
        [(LintMaybeFinding.No)
          (io.panic
            "lint: discarded variable should produce a no-effect finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-var-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: discarded variable should be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-add-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: discarded arithmetic should be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-cast-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic "lint: discarded cast should be flagged"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-tail-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: tail expression should not be flagged as no-effect"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-clean-call-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: discarded call should not be flagged as no-effect"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-clean-mutation-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: discarded mutation should not be flagged as no-effect"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            no-effect-unsafe-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: unsafe block should not be flagged as no-effect"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            unreachable-return-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (io.panic
          "lint: return should flag following unreachable expression once"))
      (match (lint-findings-get
        (lint-test-walk-tail
          unreachable-return-begin
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 41)
              (string.string-eq
                (struct-get finding rule-id)
                (lint-rule-unreachable-code-id)))
              unit
              (io.panic
                "lint: unreachable-code finding should carry rule id and span")))]
        [(LintMaybeFinding.No)
          (io.panic "lint: unreachable-code should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            unreachable-panic-unsafe
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        2)
        unit
        (io.panic "lint: panic in unsafe should flag unreachable and padding"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            redundant-padding-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        2)
        unit
        (io.panic
          "lint: redundant divergence padding should flag with unreachable"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            qualified-padding-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        2)
        unit
        (io.panic "lint: qualified panic padding should flag with unreachable"))
      (match (lint-findings-get
        (lint-test-walk-tail
          redundant-padding-begin
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintMaybeFinding.Some finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 43)
              (string.string-eq
                (struct-get finding rule-id)
                (lint-rule-redundant-divergence-padding-id)))
              unit
              (io.panic
                "lint: redundant divergence padding finding should carry rule id and span")))]
        [(LintMaybeFinding.No)
          (io.panic
            "lint: redundant divergence padding should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            clean-panic-tail-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic "lint: tail panic without padding should stay clean"))
      (if (=
        (lint-findings-count
          (lint-test-walk-tail
            branch-local-return-begin
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        unit
        (io.panic
          "lint: branch-local return should not make following code unreachable"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-nested-if-ladder-id))
        "prefer cond (value/guard ladders) or match (variant dispatch)")
        unit
        (io.panic "lint: nested-if-ladder suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-message (lint-rule-nested-if-ladder-id))
        "nested if-ladder: chain of if/else-if; prefer cond (value/guard ladders) or match (variant dispatch)")
        unit
        (io.panic "lint: nested-if-ladder message should be registered"))
      (match (lint-rule-find (lint-rule-nested-if-ladder-id))
        [(LintMaybeRule.Found rule)
          (if (and
            (string.string-eq
              (struct-get rule rule-id)
              (lint-rule-nested-if-ladder-id))
            (string.string-eq
              (struct-get rule message)
              (lint-rule-nested-if-ladder-message))
            (string.string-eq
              (struct-get rule suggestion)
              (lint-rule-nested-if-ladder-suggestion)))
            unit
            (io.panic
              "lint: nested-if-ladder registry entry should match metadata"))]
        [(LintMaybeRule.NotFound)
          (io.panic "lint: nested-if-ladder should be registered")])
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-nested-let-id))
        "merge the nested let bindings into one sequential let")
        unit
        (io.panic "lint: nested-let suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-single-begin-id))
        "remove the begin wrapper")
        unit
        (io.panic "lint: single-begin suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-message (lint-rule-single-begin-id))
        "single begin: begin with one expression is redundant")
        unit
        (io.panic "lint: single-begin message should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-return-path-chain-id))
        "prefer early return guards with (return ...)")
        unit
        (io.panic "lint: return-path-chain suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-unit-if-guard-id))
        "prefer when/unless for unit guard branches")
        unit
        (io.panic "lint: unit-if-guard suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-no-effect-id))
        "remove the expression or use its value")
        unit
        (io.panic "lint: no-effect suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-message (lint-rule-no-effect-id))
        "no-effect expression: value is discarded")
        unit
        (io.panic "lint: no-effect message should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-unreachable-code-id))
        "remove the unreachable expression or move it before the terminal expression")
        unit
        (io.panic "lint: unreachable-code suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-message (lint-rule-unreachable-code-id))
        "unreachable code: expression follows a terminal expression")
        unit
        (io.panic "lint: unreachable-code message should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-redundant-divergence-padding-id))
        "remove the trailing dead expression and the stale unreachable-code lint allow")
        unit
        (io.panic
          "lint: redundant-divergence-padding suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-message (lint-rule-redundant-divergence-padding-id))
        "redundant divergence padding: trailing expressions after panic/error are dead")
        unit
        (io.panic
          "lint: redundant-divergence-padding message should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-deprecated-string-concat-id))
        "import stdlib/str_cat.tl and use str-cat, or use stdlib/text_buf.tl in accumulation loops")
        unit
        (io.panic
          "lint: deprecated-string-concat suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-nested-str-cat-id))
        "flatten nested str-cat operands into the outer call")
        unit
        (io.panic "lint: nested-str-cat suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-cascading-and-or-id))
        "flatten same-operator and/or operands, e.g. (and a b c)")
        unit
        (io.panic "lint: cascading-and-or suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-unused-import-id))
        "remove the import or prefix an intentionally unused alias with _")
        unit
        (io.panic "lint: unused-import suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-message (lint-rule-unused-import-id))
        "unused import: imported module alias is never referenced")
        unit
        (io.panic "lint: unused-import message should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-redundant-import-alias-id))
        "remove the explicit as clause")
        unit
        (io.panic
          "lint: redundant-import-alias suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-message (lint-rule-redundant-import-alias-id))
        "redundant import alias: dotted module import already binds that alias")
        unit
        (io.panic "lint: redundant-import-alias message should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-unused-variable-id))
        "remove the binding or prefix an intentionally unused name with _")
        unit
        (io.panic "lint: unused-variable suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-message (lint-rule-unused-variable-id))
        "unused variable: parameter or local binding is never used")
        unit
        (io.panic "lint: unused-variable message should be registered"))
      (if (string.string-eq
        (lint-rule-suggestion (lint-rule-unused-unsafe-id))
        "remove the unsafe wrapper")
        unit
        (io.panic "lint: unused-unsafe suggestion should be registered"))
      (if (string.string-eq
        (lint-rule-message (lint-rule-unused-unsafe-id))
        "unused unsafe block: body does not require unsafe context")
        unit
        (io.panic "lint: unused-unsafe message should be registered"))
      (if (string.string-eq (lint-rule-suggestion "unknown-rule") "")
        unit
        (io.panic "lint: unknown rule should have no suggestion"))
      (if (string.string-eq (lint-rule-message "unknown-rule") "")
        unit
        (io.panic "lint: unknown rule should have no message"))
      (match (lint-rule-find "unknown-rule")
        [(LintMaybeRule.NotFound) unit]
        [(LintMaybeRule.Found _)
          (io.panic "lint: unknown rule should not be found")])
      42)))