;# TypeLisp lint engine + source cleanup rules.
;#
;# A selfhost lint pass: walk the parsed AST, run registered rules, and collect
;# findings. The rules flag body-only nested `let` forms, single-expression
;# `begin` wrappers, nested success-path `if` return chains, unit-branch return
;# guards, no-effect expression statements, nested `str-cat` calls, and
;# deprecated user-facing string concatenation primitives. It also identifies
;# raw arena-operation calls for the driver's audited-module boundary.
;#
;# The `typelisp lint` CLI driver consumes the rule id attached to each finding
;# for suppression (`;; lint-allow: <rule-id>`). This module owns stable rule
;# metadata and the lint core verified by `compiler-lint-self-test` in the
;# `lint_core_tests.tl` companion (driver: `src/tests/lint_smoke.tl`).
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import token)
(import lex as lexer)

(defmacro (global-shared-view [place : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

;: A single lint finding: stable rule id, human-readable message, rule-specific
;: depth metadata, and the source span of the flagged node (the `lint-no-span`
;: sentinel when the node carried no location, e.g. a synthesized expression).
(defstruct LintFinding
  (message String)
  (rule-id String)
  (depth i64)
  (span ast.AstSourceSpan))

;: Stable rule id for the dormant nested-`if`-ladder rule. Rule ids are the
;: suppression key (`;; lint-allow: <rule-id>`) and the registry key, so this
;: remains registered even while bootstrap source stays on nested `if`.
(define (lint-rule-nested-if-ladder-id) : String
  "nested-if-ladder")

;: Public message text retained for compatibility with rule metadata lookups.
(define (lint-rule-nested-if-ladder-message) : String
  "nested if-ladder: chain of if/else-if; prefer cond (value/guard ladders) or match (variant dispatch)")

(define (lint-rule-nested-if-ladder-value-message) : String
  "nested if-ladder: value dispatch chain; prefer bracket-arm cond or match")

(define (lint-rule-nested-if-ladder-guard-message) : String
  "nested if-ladder: guard flow chain; prefer cond with guard arms or when/unless")

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

(define (lint-rule-transitional-core-macro-qualifier-id) : String
  "transitional-core-macro-qualifier")

(define (lint-rule-transitional-core-macro-qualifier-message) : String
  "transitional core macro qualifier: use the bare prelude macro spelling")

(define (lint-rule-transitional-core-macro-qualifier-suggestion) : String
  "replace core.when/core.unless/core.and/core.or/core.cond with when/unless/and/or/cond")

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
  "replace same-struct reassignment with (set! value.field new-value)")

(define (lint-rule-prefer-dynamic-array-literal-id) : String
  "prefer-dynamic-array-literal")

(define (lint-rule-prefer-dynamic-array-literal-message) : String
  "hand-filled dynamic array: prefer (make-array v0 v1 ...)")

(define (lint-rule-prefer-dynamic-array-literal-suggestion) : String
  "replace the allocation and consecutive array element assignments with a dynamic array literal")

(define (lint-rule-single-element-array-cell-id) : String
  "single-element-array-cell")

(define (lint-rule-single-element-array-cell-message) : String
  "single-element array scalar cell: prefer Box T, &mut, or return-value refactoring")

(define (lint-rule-single-element-array-cell-suggestion) : String
  "replace the one-element array cell with Box T, &mut, or an explicit returned value")

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

(define (lint-rule-raw-arena-op-id) : String
  "raw-arena-op")

(define (lint-rule-raw-arena-op-message) : String
  "raw arena operation: direct set/destroy/rewind is restricted to audited modules")

(define (lint-rule-raw-arena-op-suggestion) : String
  "use in-arena, with-scratch, with-arena, rewind-safe!, or destroy-safe!")

(define (lint-rule-global-name-case-id) : String
  "global-name-case")

(define (lint-rule-global-name-case-message) : String
  "global name case: top-level value bindings use kebab-case")

(define (lint-rule-global-name-case-suggestion) : String
  "rename the binding to kebab-case")

(define (lint-rule-function-name-case-id) : String
  "function-name-case")

(define (lint-rule-function-name-case-message) : String
  "function name case: functions, dispatch functions, and macros use kebab-case")

(define (lint-rule-function-name-case-suggestion) : String
  "rename the declaration to kebab-case")

(define (lint-rule-local-name-case-id) : String
  "local-name-case")

(define (lint-rule-local-name-case-message) : String
  "local name case: parameters and local binders use kebab-case; one-letter type operands may use uppercase")

(define (lint-rule-local-name-case-suggestion) : String
  "rename the parameter or local binding to its conventional case")

(define (lint-rule-type-name-case-id) : String
  "type-name-case")

(define (lint-rule-type-name-case-message) : String
  "type name case: struct and enum declarations use UpperCamelCase")

(define (lint-rule-type-name-case-suggestion) : String
  "rename the type declaration to UpperCamelCase")

;: Metadata for one lint rule. Rule id is stable public API for suppressions;
;: message is the rendered finding text; suggestion is structured helper text
;: that drivers or tooling can render separately from the message.
(defstruct LintRule
  (rule-id String)
  (message String)
  (suggestion String))

;: Immutable contiguous registry of registered rules.
(defstruct LintRuleList
  (slots (__tl_dyn-array LintRule))
  (len i64))

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

(define (lint-rule-transitional-core-macro-qualifier) : LintRule
  (LintRule
    (lint-rule-transitional-core-macro-qualifier-id)
    (lint-rule-transitional-core-macro-qualifier-message)
    (lint-rule-transitional-core-macro-qualifier-suggestion)))

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

(define (lint-rule-prefer-dynamic-array-literal) : LintRule
  (LintRule
    (lint-rule-prefer-dynamic-array-literal-id)
    (lint-rule-prefer-dynamic-array-literal-message)
    (lint-rule-prefer-dynamic-array-literal-suggestion)))

(define (lint-rule-single-element-array-cell) : LintRule
  (LintRule
    (lint-rule-single-element-array-cell-id)
    (lint-rule-single-element-array-cell-message)
    (lint-rule-single-element-array-cell-suggestion)))

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

(define (lint-rule-raw-arena-op) : LintRule
  (LintRule
    (lint-rule-raw-arena-op-id)
    (lint-rule-raw-arena-op-message)
    (lint-rule-raw-arena-op-suggestion)))

(define (lint-rule-global-name-case) : LintRule
  (LintRule
    (lint-rule-global-name-case-id)
    (lint-rule-global-name-case-message)
    (lint-rule-global-name-case-suggestion)))

(define (lint-rule-function-name-case) : LintRule
  (LintRule
    (lint-rule-function-name-case-id)
    (lint-rule-function-name-case-message)
    (lint-rule-function-name-case-suggestion)))

(define (lint-rule-local-name-case) : LintRule
  (LintRule
    (lint-rule-local-name-case-id)
    (lint-rule-local-name-case-message)
    (lint-rule-local-name-case-suggestion)))

(define (lint-rule-type-name-case) : LintRule
  (LintRule
    (lint-rule-type-name-case-id)
    (lint-rule-type-name-case-message)
    (lint-rule-type-name-case-suggestion)))

;: Small registry for lint metadata. New rules plug into this table and the
;: shared lookup helpers without requiring public driver edits.
(define (lint-rule-registry) : LintRuleList
  (LintRuleList
    (__tl_make-array
      (lint-rule-nested-if-ladder)
      (lint-rule-nested-let)
      (lint-rule-single-begin)
      (lint-rule-return-path-chain)
      (lint-rule-unit-if-guard)
      (lint-rule-no-effect)
      (lint-rule-unreachable-code)
      (lint-rule-redundant-divergence-padding)
      (lint-rule-deprecated-string-concat)
      (lint-rule-nested-str-cat)
      (lint-rule-cascading-and-or)
      (lint-rule-unused-import)
      (lint-rule-redundant-import-alias)
      (lint-rule-redundant-function-name)
      (lint-rule-dead-code)
      (lint-rule-unused-assignment)
      (lint-rule-copy-on-update-struct)
      (lint-rule-prefer-dynamic-array-literal)
      (lint-rule-single-element-array-cell)
      (lint-rule-unused-variable)
      (lint-rule-unused-unsafe)
      (lint-rule-raw-arena-op)
      (lint-rule-transitional-core-macro-qualifier)
      (lint-rule-global-name-case)
      (lint-rule-function-name-case)
      (lint-rule-local-name-case)
      (lint-rule-type-name-case))
    27))

(define (lint-rule-find-at
  [rules : LintRuleList]
  [rule-id : String]
  [index : i64]) : LintMaybeRule
  (if (>= index rules.len)
    LintMaybeRule.NotFound
    (let
      [rule : LintRule
        (owned_view.compiler-owned-array-element-shared-view rules.slots index)]
      (if (string.eq rule.rule-id rule-id)
        (LintMaybeRule.Found rule)
        (lint-rule-find-at rules rule-id (+ index 1))))))

(define (lint-rule-find-in [rules : LintRuleList] [rule-id : String]) : LintMaybeRule
  (lint-rule-find-at rules rule-id 0))

(define (lint-rule-find [rule-id : String]) : LintMaybeRule
  (lint-rule-find-in (lint-rule-registry) rule-id))

;: Rule registry message lookup. Unknown ids return the empty string.
(define (lint-rule-message [rule-id : String]) : String
  (match (lint-rule-find rule-id)
    [(LintMaybeRule.Found rule) rule.message]
    [(LintMaybeRule.NotFound) ""]))

;: Rule registry suggestion lookup. Unknown ids return the empty string.
(define (lint-rule-suggestion [rule-id : String]) : String
  (match (lint-rule-find rule-id)
    [(LintMaybeRule.Found rule) rule.suggestion]
    [(LintMaybeRule.NotFound) ""]))

;: Growable findings buffer. The backing array stores findings in discovery
;: order; the CLI renders from the end to preserve the historical output order.
(defstruct LintFindings
  (slots (__tl_dyn-array LintFinding))
  (len i64))

(defenum LintMaybeFinding
  (No)
  (Some LintFinding))

(define (lint-findings-slots [items : LintFindings]) : (__tl_dyn-array
    LintFinding)
  items.slots)

;: Number of live findings in `items`.
(define (lint-findings-count [items : LintFindings]) : i64
  items.len)

(define (lint-findings-capacity [items : LintFindings]) : i64
  (array-length (lint-findings-slots items)))

(define (lint-findings-with-capacity [capacity : i64]) : LintFindings
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (LintFindings (__tl_make-array LintFinding cap) 0)))

(define (lint-findings-empty) : LintFindings
  (lint-findings-with-capacity 4))

(define (lint-findings-copy-range
  [dst : (__tl_dyn-array LintFinding)]
  [src : (__tl_dyn-array LintFinding)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (lint-findings-copy-range dst src (+ index 1) count))))

(define (lint-findings-grow [items : LintFindings]) : LintFindings
  (let
    [n : i64
      (lint-findings-count (owned_view.compiler-owned-shared-view items))]
    [bigger : (__tl_dyn-array LintFinding)
      (make-array
        LintFinding
        (*
          (lint-findings-capacity (owned_view.compiler-owned-shared-view items))
          2))]
    (begin
      (lint-findings-copy-range
        (owned_view.compiler-owned-shared-view bigger)
        (lint-findings-slots items)
        0
        n)
      (LintFindings bigger n))))

;: Append `finding` to the discoveries, growing the backing array as needed.
(define (lint-findings-add [finding : LintFinding] [items : LintFindings]) : LintFindings
  (if (<
    (lint-findings-count (owned_view.compiler-owned-shared-view items))
    (lint-findings-capacity (owned_view.compiler-owned-shared-view items)))
    (let
      [slots : (__tl_dyn-array LintFinding)
        (lint-findings-slots (owned_view.compiler-owned-shared-view items))]
      [n : i64 (lint-findings-count items)]
      (begin
        (set! (array-ref slots n) finding)
        (LintFindings slots (+ n 1))))
    (lint-findings-add finding (lint-findings-grow items))))

(define (lint-findings-ref [items : LintFindings] [index : i64]) : LintFinding
  (array-ref (lint-findings-slots items) index))

(define (lint-findings-get [items : LintFindings] [index : i64]) : LintMaybeFinding
  (if (if (>= index 0)
    (<
      index
      (lint-findings-count (owned_view.compiler-owned-shared-view items)))
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
(define (lint-ladder-length [expr : ast.AstExpr]) : i64
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-ladder-length inner))]
    [(ast.AstExpr.If _ _ else-branch-box)
      (let
        [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
        (+ 1 (lint-ladder-length else-branch)))]
    [_ 0]))

(define (lint-return-path-chain-length [expr : ast.AstExpr]) : i64
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-return-path-chain-length inner))]
    [(ast.AstExpr.If _ then-branch-box _)
      (let
        [then-branch : ast.AstExpr (ast.ast-node-get then-branch-box)]
        (+ 1 (lint-return-path-chain-length then-branch)))]
    [_ 0]))

(define (lint-unit-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-unit-expr? inner))]
    [(ast.AstExpr.Literal lit)
      (match lit
        [(ast.AstLiteral.Unit) true]
        [_ false])]
    [_ false]))

(define (lint-single-arg-call? [args : ast.AstExprList]) : bool
  (= args.len 1))

(define (lint-not-call? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-not-call? inner))]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (match func
          [(ast.AstExpr.Var name)
            (and
              (string.eq (ci.intern-str name) "not")
              (lint-single-arg-call? args))]
          [_ false]))]
    [(ast.AstExpr.Unary (ast.AstUnOp.Not) _) true]
    [_ false]))

(define (lint-return-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-return-expr? inner))]
    [(ast.AstExpr.Return _) true]
    [(ast.AstExpr.Break) true]
    [(ast.AstExpr.Continue) true]
    [_ false]))

(define (lint-expr-list-has-return? [exprs : ast.AstExprList]) : bool
  (lint-expr-list-has-return-at? (& exprs) 0))

(define (lint-expr-list-has-return-at?
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]) : bool
  (if (>= index exprs.len)
    false
    (let
      [head : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))]
      (if (lint-return-expr? head)
        true
        (lint-expr-list-has-return-at? exprs (+ index 1))))))

(define (lint-return-branch? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-return-branch? inner))]
    [(ast.AstExpr.Return _) true]
    [(ast.AstExpr.Break) true]
    [(ast.AstExpr.Continue) true]
    [(ast.AstExpr.Begin exprs) (lint-expr-list-has-return? exprs)]
    [_ false]))

;: True when `expr` is the remainder of an else-`if` ladder whose then arms
;: and terminal else all exit via return, break, or continue.
(define (lint-all-exit-ladder-tail? [expr : ast.AstExpr]) : bool
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-all-exit-ladder-tail? inner))]
    [(ast.AstExpr.If _ then-branch-box else-branch-box)
      (let
        [then-branch : ast.AstExpr (ast.ast-node-get then-branch-box)]
        [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
        (and
          (lint-return-branch? then-branch)
          (lint-all-exit-ladder-tail? else-branch)))]
    [_ (lint-return-branch? expr)]))

(define (lint-side-effect-branch? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-side-effect-branch? inner))]
    [(ast.AstExpr.Set _ _) true]
    [(ast.AstExpr.ArraySet _ _ _) true]
    [(ast.AstExpr.ArrayTake _ _ _) true]
    [(ast.AstExpr.FixedArrayTake _ _) true]
    [(ast.AstExpr.Replace _ _) true]
    [(ast.AstExpr.ArrayPush _ _) true]
    [(ast.AstExpr.StructSet _ _ _) true]
    [(ast.AstExpr.Begin exprs) (lint-expr-list-has-side-effect? exprs)]
    [_ false]))

(define (lint-expr-list-has-side-effect? [exprs : ast.AstExprList]) : bool
  (lint-expr-list-has-side-effect-at? (& exprs) 0))

(define (lint-expr-list-has-side-effect-at?
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]) : bool
  (if (>= index exprs.len)
    false
    (let
      [head : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))]
      (if (lint-side-effect-branch? head)
        true
        (lint-expr-list-has-side-effect-at? exprs (+ index 1))))))

(define (lint-expr-list-last-guard-branch? [exprs : ast.AstExprList]) : bool
  (let
    [n : i64 exprs.len]
    (if (= n 0)
      true
      (lint-guard-ladder-branch?
        (ast.ast-node-get (ast.ast-expr-list-get (& exprs) (- n 1) 0))))))

(define (lint-guard-ladder-branch? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-guard-ladder-branch? inner))]
    [(ast.AstExpr.Literal lit)
      (match lit
        [(ast.AstLiteral.Unit) true]
        [_ false])]
    [(ast.AstExpr.Return _) true]
    [(ast.AstExpr.Break) true]
    [(ast.AstExpr.Continue) true]
    [(ast.AstExpr.Set _ _) true]
    [(ast.AstExpr.ArraySet _ _ _) true]
    [(ast.AstExpr.ArrayTake _ _ _) true]
    [(ast.AstExpr.FixedArrayTake _ _) true]
    [(ast.AstExpr.Replace _ _) true]
    [(ast.AstExpr.ArrayPush _ _) true]
    [(ast.AstExpr.StructSet _ _ _) true]
    [(ast.AstExpr.Begin exprs) (lint-expr-list-last-guard-branch? exprs)]
    [(ast.AstExpr.Unsafe exprs) (lint-expr-list-last-guard-branch? exprs)]
    [_ false]))

(define (lint-expr-list-last-value-branch? [exprs : ast.AstExprList]) : bool
  (let
    [n : i64 exprs.len]
    (if (= n 0)
      false
      (lint-value-ladder-branch?
        (ast.ast-node-get (ast.ast-expr-list-get (& exprs) (- n 1) 0))))))

(define (lint-value-ladder-branch? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-value-ladder-branch? inner))]
    [(ast.AstExpr.Literal literal)
      (match literal
        [(ast.AstLiteral.Unit) false]
        [_ true])]
    [(ast.AstExpr.Var _) true]
    [(ast.AstExpr.Binary _ _ _) true]
    [(ast.AstExpr.Unary _ _) true]
    [(ast.AstExpr.Tuple _) true]
    [(ast.AstExpr.TupleRef _ _) true]
    [(ast.AstExpr.Array _) true]
    [(ast.AstExpr.DynArray _) true]
    [(ast.AstExpr.MakeArray _ _) true]
    [(ast.AstExpr.ArrayRef _ _) true]
    [(ast.AstExpr.StringRef _ _) true]
    [(ast.AstExpr.StructGet _ _) true]
    [(ast.AstExpr.Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-value-ladder-branch? inner))]
    [(ast.AstExpr.Cast _ _) true]
    [(ast.AstExpr.PtrNull _) true]
    [(ast.AstExpr.PtrNullCheck _) true]
    [(ast.AstExpr.PtrRead _) true]
    [(ast.AstExpr.Box _) true]
    [(ast.AstExpr.BoxGet _) true]
    [(ast.AstExpr.BoxTake _) true]
    [(ast.AstExpr.TypeLiteral _) true]
    [(ast.AstExpr.Init _) true]
    [(ast.AstExpr.Begin exprs) (lint-expr-list-last-value-branch? exprs)]
    [_ false]))

(define (lint-if-ladder-guard?
  [then-branch : ast.AstExpr]
  [else-branch : ast.AstExpr]) : bool
  (and
    (lint-guard-ladder-branch?
      (owned_view.compiler-owned-shared-view then-branch))
    (match (owned_view.compiler-owned-shared-view else-branch)
      [(ast.AstExpr.Spanned inner-box _)
        (let
          [inner : ast.AstExpr (ast.ast-node-get inner-box)]
          (lint-if-ladder-guard? then-branch inner))]
      [(ast.AstExpr.If _ nested-then-box nested-else-box)
        (let
          [nested-then : ast.AstExpr (ast.ast-node-get nested-then-box)]
          [nested-else : ast.AstExpr (ast.ast-node-get nested-else-box)]
          (lint-if-ladder-guard? nested-then nested-else))]
      [_ (lint-guard-ladder-branch? else-branch)])))

(define (lint-if-ladder-value?
  [then-branch : ast.AstExpr]
  [else-branch : ast.AstExpr]) : bool
  (and
    (lint-value-ladder-branch?
      (owned_view.compiler-owned-shared-view then-branch))
    (match (owned_view.compiler-owned-shared-view else-branch)
      [(ast.AstExpr.Spanned inner-box _)
        (let
          [inner : ast.AstExpr (ast.ast-node-get inner-box)]
          (lint-if-ladder-value? then-branch inner))]
      [(ast.AstExpr.If _ nested-then-box nested-else-box)
        (let
          [nested-then : ast.AstExpr (ast.ast-node-get nested-then-box)]
          [nested-else : ast.AstExpr (ast.ast-node-get nested-else-box)]
          (lint-if-ladder-value? nested-then nested-else))]
      [_ (lint-value-ladder-branch? else-branch)])))

(define (lint-if-ladder-message
  [then-branch : ast.AstExpr]
  [else-branch : ast.AstExpr]) : String
  (if (lint-if-ladder-guard?
    (owned_view.compiler-owned-shared-view then-branch)
    (owned_view.compiler-owned-shared-view else-branch))
    (lint-rule-nested-if-ladder-guard-message)
    (if (lint-if-ladder-value? then-branch else-branch)
      (lint-rule-nested-if-ladder-value-message)
      (lint-rule-nested-if-ladder-message))))

;: Sentinel span for a finding whose AST node carried no source location (a
;: synthesized or in-memory expression). Parsed ladders carry the span from
;: their `AstExpr.Spanned` wrapper instead.
(define (lint-no-span) : ast.AstSourceSpan
  (ast.ast-source-span 0 0 0 0))

;: Build the nested-`if`-ladder finding for a ladder of `depth` arms whose head
;: is at `span`.
(define (lint-ladder-finding
  [then-branch : ast.AstExpr]
  [else-branch : ast.AstExpr]
  [depth : i64]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-if-ladder-message then-branch else-branch)
    (lint-rule-nested-if-ladder-id)
    depth
    span))

(define (lint-nested-let-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-nested-let-id))
    (lint-rule-nested-let-id)
    0
    span))

(define (lint-single-begin-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-single-begin-id))
    (lint-rule-single-begin-id)
    0
    span))

(define (lint-return-path-chain-finding
  [depth : i64]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-return-path-chain-id))
    (lint-rule-return-path-chain-id)
    depth
    span))

(define (lint-unit-if-guard-finding
  [then-unit : bool]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (if then-unit
      "unit guard if: unit then-branch; prefer when/unless"
      "unit guard if: unit else-branch; prefer when/unless")
    (lint-rule-unit-if-guard-id)
    1
    span))

(define (lint-no-effect-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-no-effect-id))
    (lint-rule-no-effect-id)
    0
    span))

(define (lint-unreachable-code-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-unreachable-code-id))
    (lint-rule-unreachable-code-id)
    0
    span))

(define (lint-redundant-divergence-padding-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-redundant-divergence-padding-id))
    (lint-rule-redundant-divergence-padding-id)
    0
    span))

(define (lint-dead-code-finding [name : String] [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "dead code: top-level declaration "
      name
      " is unreachable from package entry/test roots")
    (lint-rule-dead-code-id)
    0
    span))

(define (lint-unused-assignment-finding
  [name : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "unused assignment: value assigned to "
      name
      " is overwritten before it is read")
    (lint-rule-unused-assignment-id)
    0
    span))

(define (lint-copy-on-update-struct-finding
  [name : String]
  [field : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "copy-on-update struct mutation: "
      name
      " rebuilds the same struct to change field "
      field
      "; use in-place field assignment")
    (lint-rule-copy-on-update-struct-id)
    1
    span))

(define (lint-single-element-array-cell-finding
  [name : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "single-element array scalar cell: "
      name
      " is only read or written at index 0; prefer Box T, &mut, or returning the updated value")
    (lint-rule-single-element-array-cell-id)
    0
    span))

(define (lint-prefer-dynamic-array-literal-finding
  [name : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "hand-filled dynamic array: "
      name
      " is initialized by consecutive array-set! calls; prefer (make-array v0 v1 ...)")
    (lint-rule-prefer-dynamic-array-literal-id)
    0
    span))

(define (lint-unused-variable-finding
  [name : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat "unused variable: " name " is never used")
    (lint-rule-unused-variable-id)
    0
    span))

(define (lint-unused-unsafe-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-unused-unsafe-id))
    (lint-rule-unused-unsafe-id)
    0
    span))

(define (lint-raw-arena-op-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-raw-arena-op-id))
    (lint-rule-raw-arena-op-id)
    0
    span))

(define (lint-redundant-function-name-finding
  [module-name : String]
  [name : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (let
    [module-len : i64 (string.string-length module-name)]
    [name-len : i64 (string.string-length name)]
    [short-name : String
      (if (> name-len (+ module-len 1))
        (string.substring name (+ module-len 1) (- name-len (+ module-len 1)))
        name)]
    (LintFinding
      (str_cat.str-cat
        "redundant function name: "
        name
        " repeats module prefix "
        module-name
        "; use "
        short-name)
      (lint-rule-redundant-function-name-id)
      0
      span)))

(define (lint-name-case-ascii-lower? [c : char]) : bool
  (and (>= c 'a') (<= c 'z')))

(define (lint-name-case-ascii-upper? [c : char]) : bool
  (and (>= c 'A') (<= c 'Z')))

(define (lint-name-case-ascii-letter? [c : char]) : bool
  (or (lint-name-case-ascii-lower? c) (lint-name-case-ascii-upper? c)))

(define (lint-name-case-ascii-digit? [c : char]) : bool
  (and (>= c '0') (<= c '9')))

(define (lint-name-case-has-ascii-letter? [name : String]) : bool
  (let
    [n : i64
      (string.string-length (owned_view.compiler-owned-shared-view name))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (< index n) (not found))
        (if (lint-name-case-ascii-letter? (string.string-ref name index))
          (set! found true)
          (set! index (+ index 1))))
      found)))

(define (lint-name-case-terminal-suffix-start [name : String]) : i64
  (let
    [n : i64
      (string.string-length (owned_view.compiler-owned-shared-view name))]
    (if (= n 0)
      0
      (let
        [last : char (string.string-ref name (- n 1))]
        (if (or (= last '?') (= last '!'))
          (- n 1)
          n)))))

(define (lint-name-case-kebab-range? [name : String] [start : i64] [end : i64]) : bool
  (let
    [index : i64 start]
    [segment-start : bool true]
    [ok : bool (< start end)]
    (begin
      (while (and ok (< index end))
        (let
          [c : char (string.string-ref name index)]
          (cond
            [(lint-name-case-ascii-lower? c)
              (begin
                (set! segment-start false)
                (set! index (+ index 1)))]
            [(lint-name-case-ascii-digit? c)
              (if (= index start)
                (set! ok false)
                (begin
                  (set! segment-start false)
                  (set! index (+ index 1))))]
            [(= c '-')
              (if segment-start
                (set! ok false)
                (begin
                  (set! segment-start true)
                  (if (and
                    (< (+ index 1) end)
                    (= (string.string-ref name (+ index 1)) '>'))
                    (set! index (+ index 2))
                    (set! index (+ index 1)))))]
            [else (set! ok false)])))
      (and ok (not segment-start)))))

;: True for project kebab-case. Predicate/mutator suffixes and the `->`
;: conversion separator are accepted. Names without ASCII letters are operator
;: spellings and are exempt.
(define (lint-name-case-kebab? [name : String]) : bool
  (if (not
    (lint-name-case-has-ascii-letter?
      (owned_view.compiler-owned-shared-view name)))
    true
    (lint-name-case-kebab-range?
      (owned_view.compiler-owned-shared-view name)
      0
      (lint-name-case-terminal-suffix-start name))))

;: Local names use kebab-case and may carry exactly one intentional-unused `_`
;: prefix. The wildcard `_` is not a named binding and is accepted here.
(define (lint-name-case-local-kebab? [name : String]) : bool
  (if (string.eq name "_")
    true
    (if (not
      (lint-name-case-has-ascii-letter?
        (owned_view.compiler-owned-shared-view name)))
      true
      (let
        [n : i64 (string.string-length name)]
        [start : i64
          (if (and (> n 0) (= (string.string-ref name 0) '_'))
            1
            0)]
        (lint-name-case-kebab-range?
          (owned_view.compiler-owned-shared-view name)
          start
          (lint-name-case-terminal-suffix-start name))))))

;: Struct and enum names use uppercase-initial CamelCase. Acronym runs remain
;: valid; separators and non-ASCII alphanumerics are rejected.
(define (lint-name-case-upper-camel? [name : String]) : bool
  (if (not
    (lint-name-case-has-ascii-letter?
      (owned_view.compiler-owned-shared-view name)))
    true
    (let
      [n : i64 (string.string-length name)]
      [index : i64 1]
      [ok : bool
        (and (> n 0) (lint-name-case-ascii-upper? (string.string-ref name 0)))]
      (begin
        (while (and ok (< index n))
          (let
            [c : char (string.string-ref name index)]
            (if (or
              (lint-name-case-ascii-letter? c)
              (lint-name-case-ascii-digit? c))
              (set! index (+ index 1))
              (set! ok false))))
        ok))))

;: One-letter type operands conventionally use an uppercase type variable.
;: Descriptive operands continue to use normal local kebab-case.
(define (lint-name-case-type-operand? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    [start : i64
      (if (and (> n 1) (= (string.string-ref name 0) '_'))
        1
        0)]
    [body-len : i64 (- n start)]
    (or
      (lint-name-case-local-kebab? (owned_view.compiler-owned-shared-view name))
      (and
        (= body-len 1)
        (lint-name-case-ascii-upper? (string.string-ref name start))))))

;: Dotted symbols in match patterns are qualified nullary variants, not local
;: binders. The parser intentionally leaves that distinction to typechecking.
(define (lint-name-case-qualified-symbol? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (< index n) (not found))
        (if (= (string.string-ref name index) '.')
          (set! found true)
          (set! index (+ index 1))))
      found)))

(define (lint-name-case-lower-char-string [c : char]) : String
  (if (lint-name-case-ascii-upper? c)
    (string.substring
      "abcdefghijklmnopqrstuvwxyz"
      (- (cast c : i64) (cast 'A' : i64))
      1)
    (string.substring
      "abcdefghijklmnopqrstuvwxyz"
      (- (cast c : i64) (cast 'a' : i64))
      1)))

(define (lint-name-case-upper-char-string [c : char]) : String
  (if (lint-name-case-ascii-lower? c)
    (string.substring
      "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      (- (cast c : i64) (cast 'a' : i64))
      1)
    (string.substring
      "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      (- (cast c : i64) (cast 'A' : i64))
      1)))

(define (lint-name-case-lower-suggestion-from
  [name : String]
  [index : i64]
  [end : i64]
  [out : String]
  [at-word-start : bool]) : String
  (if (>= index end)
    out
    (let
      [c : char (string.string-ref name index)]
      (cond
        [(lint-name-case-ascii-lower? c)
          (lint-name-case-lower-suggestion-from
            (owned_view.compiler-owned-shared-view name)
            (+ index 1)
            end
            (str_cat.str-cat out (string.substring name index 1))
            false)]
        [(lint-name-case-ascii-upper? c)
          (let
            [prefix : String
              (if (or at-word-start (string.eq out ""))
                out
                (str_cat.str-cat out "-"))]
            [lower : String (lint-name-case-lower-char-string c)]
            (lint-name-case-lower-suggestion-from
              (owned_view.compiler-owned-shared-view name)
              (+ index 1)
              end
              (str_cat.str-cat prefix lower)
              false))]
        [(lint-name-case-ascii-digit? c)
          (if at-word-start
            ""
            (lint-name-case-lower-suggestion-from
              (owned_view.compiler-owned-shared-view name)
              (+ index 1)
              end
              (str_cat.str-cat out (string.substring name index 1))
              false))]
        [(or (= c '_') (= c '-'))
          (if (and
            (= c '-')
            (< (+ index 1) end)
            (= (string.string-ref name (+ index 1)) '>'))
            (if at-word-start
              ""
              (lint-name-case-lower-suggestion-from
                name
                (+ index 2)
                end
                (str_cat.str-cat out "->")
                true))
            (lint-name-case-lower-suggestion-from
              name
              (+ index 1)
              end
              (if at-word-start
                out
                (str_cat.str-cat out "-"))
              true))]
        [else ""]))))

(define (lint-name-case-kebab-suggestion [name : String] [allow-unused : bool]) : String
  (let
    [n : i64 (string.string-length name)]
    [unused : bool
      (and allow-unused (> n 1) (= (string.string-ref name 0) '_'))]
    [start : i64
      (if unused
        1
        0)]
    [end : i64
      (lint-name-case-terminal-suffix-start
        (owned_view.compiler-owned-shared-view name))]
    [body : String
      (lint-name-case-lower-suggestion-from
        (owned_view.compiler-owned-shared-view name)
        start
        end
        ""
        true)]
    [suffix : String
      (if (< end n)
        (string.substring name end 1)
        "")]
    (if (string.eq body "")
      ""
      (let
        [with-unused : String
          (if unused
            (str_cat.str-cat "_" body)
            body)]
        (str_cat.str-cat with-unused suffix)))))

(define (lint-name-case-upper-camel-suggestion-from
  [name : String]
  [index : i64]
  [out : String]
  [capitalize : bool]) : String
  (if (>= index (string.string-length name))
    out
    (let
      [c : char (string.string-ref name index)]
      (cond
        [(lint-name-case-ascii-letter? c)
          (let
            [piece : String
              (if capitalize
                (lint-name-case-upper-char-string c)
                (string.substring name index 1))]
            (lint-name-case-upper-camel-suggestion-from
              (owned_view.compiler-owned-shared-view name)
              (+ index 1)
              (str_cat.str-cat out piece)
              false))]
        [(lint-name-case-ascii-digit? c)
          (if (string.eq out "")
            ""
            (lint-name-case-upper-camel-suggestion-from
              (owned_view.compiler-owned-shared-view name)
              (+ index 1)
              (str_cat.str-cat out (string.substring name index 1))
              false))]
        [(or (= c '-') (= c '_'))
          (lint-name-case-upper-camel-suggestion-from name (+ index 1) out true)]
        [else ""]))))

(define (lint-name-case-upper-camel-suggestion [name : String]) : String
  (lint-name-case-upper-camel-suggestion-from name 0 "" true))

(define (lint-name-case-message
  [base : String]
  [name : String]
  [suggested : String]) : String
  (let
    [suffix : String
      (if (string.eq suggested "")
        "`"
        (let
          [closed : String (str_cat.str-cat suggested "`")]
          (str_cat.str-cat "`; consider `" closed)))]
    [with-name : String (str_cat.str-cat name suffix)]
    [detail : String (str_cat.str-cat ": `" with-name)]
    (str_cat.str-cat base detail)))

(define (lint-name-case-finding
  [name : String]
  [rule-id : String]
  [suggested : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-name-case-message
      (lint-rule-message (owned_view.compiler-owned-shared-view rule-id))
      name
      suggested)
    rule-id
    0
    span))

(define (lint-global-name-case-finding
  [name : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (lint-name-case-finding
    (owned_view.compiler-owned-shared-view name)
    (lint-rule-global-name-case-id)
    (lint-name-case-kebab-suggestion name false)
    span))

(define (lint-function-name-case-finding
  [name : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (lint-name-case-finding
    (owned_view.compiler-owned-shared-view name)
    (lint-rule-function-name-case-id)
    (lint-name-case-kebab-suggestion name false)
    span))

(define (lint-local-name-case-finding
  [name : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (lint-name-case-finding
    (owned_view.compiler-owned-shared-view name)
    (lint-rule-local-name-case-id)
    (lint-name-case-kebab-suggestion name true)
    span))

(define (lint-type-name-case-finding [name : String] [span : ast.AstSourceSpan]) : LintFinding
  (lint-name-case-finding
    (owned_view.compiler-owned-shared-view name)
    (lint-rule-type-name-case-id)
    (lint-name-case-upper-camel-suggestion name)
    span))

(define (lint-no-effect-span [expr : ast.AstExpr]) : ast.AstSourceSpan
  (match expr
    [(ast.AstExpr.Spanned _ span) span]
    [_ (lint-no-span)]))

(define (lint-terminal-callee-name? [text : String]) : bool
  (or
    (string.eq text "panic")
    (string.eq text "error")
    (string.eq text "io.panic")
    (string.eq text "io.error")
    (string.eq text "stdlib.io.panic")
    (string.eq text "stdlib.io.error")
    (string.eq text "stdlib/io.panic")
    (string.eq text "stdlib/io.error")))

(define (lint-terminal-callee? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-terminal-callee? inner))]
    [(ast.AstExpr.Var name)
      (let
        [text : String (ci.intern-str name)]
        (lint-terminal-callee-name? text))]
    [_ false]))

(define (lint-terminal-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(ast.AstExpr.Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(ast.AstExpr.Cast inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(ast.AstExpr.Return _) true]
    [(ast.AstExpr.Call func-box _)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (lint-terminal-callee? func))]
    [_ false]))

(define (lint-diverging-call-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-diverging-call-expr? inner))]
    [(ast.AstExpr.Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-diverging-call-expr? inner))]
    [(ast.AstExpr.Cast inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-diverging-call-expr? inner))]
    [(ast.AstExpr.Call func-box _)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (lint-terminal-callee? func))]
    [_ false]))

(define (lint-add-redundant-divergence-padding
  [head : ast.AstExpr]
  [rest : ast.AstExprList]
  [acc : LintFindings]) : LintFindings
  (if (= rest.len 0)
    acc
    (if (lint-diverging-call-expr? (owned_view.compiler-owned-shared-view head))
      (lint-findings-add
        (lint-redundant-divergence-padding-finding (lint-no-effect-span head))
        acc)
      acc)))

(define (lint-no-effect-pure-binop? [op : ast.AstBinOp]) : bool
  (match op
    ;; These operators can intentionally trap, so keep the syntactic rule
    ;; conservative until typed/effect metadata can prove safety.
    [(ast.AstBinOp.Div) false]
    [(ast.AstBinOp.Mod) false]
    [(ast.AstBinOp.Shl) false]
    [(ast.AstBinOp.Shr) false]
    [_ true]))

(define (lint-no-effect-pure-literal? [lit : ast.AstLiteral]) : bool
  (match lit
    [(ast.AstLiteral.Unit) false]
    [_ true]))

(define (lint-no-effect-pure-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(ast.AstExpr.Literal lit) (lint-no-effect-pure-literal? lit)]
    [(ast.AstExpr.Var _) true]
    [(ast.AstExpr.TypeLiteral _) true]
    [(ast.AstExpr.Binary op left-box right-box)
      (let
        [left : ast.AstExpr (ast.ast-node-get left-box)]
        [right : ast.AstExpr (ast.ast-node-get right-box)]
        (and
          (lint-no-effect-pure-binop? op)
          (lint-no-effect-pure-expr? left)
          (lint-no-effect-pure-expr? right)))]
    [(ast.AstExpr.Unary _ inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(ast.AstExpr.Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(ast.AstExpr.Cast inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(ast.AstExpr.PtrNull _) true]
    [_ false]))

(define (lint-deprecated-string-concat-name? [name : String]) : bool
  (or
    (string.eq name "string-append")
    (string.eq name "string.append")
    (string.eq name "string-concat")
    (string.eq name "string.concat")
    (string.eq name "string.concat3")
    (string.eq name "string.concat4")
    (string.eq name "string.concat5")))

(define (lint-deprecated-string-concat-loop-form? [name : String]) : bool
  (or
    (string.eq name "while")
    (string.eq name "foreach")
    (string.eq name "spmd-reduce")
    (string.eq name "spmd-scan")
    (string.eq name "spmd-shuffle")))

(define (lint-token-name [tok : token.Token]) : String
  (if (=
    (token.tag (owned_view.compiler-owned-shared-view tok))
    (token.tag-sym))
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
  [span : ast.AstSourceSpan]) : LintFinding
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
    (string.eq name "and")
    (string.eq name "core/and")
    (string.eq name "core.and")
    (string.eq name "stdlib.core_macros.and"))
    "and"
    (if (or
      (string.eq name "or")
      (string.eq name "core/or")
      (string.eq name "core.or")
      (string.eq name "stdlib.core_macros.or"))
      "or"
      "")))

(define (lint-and-or-func-op [func : ast.AstExpr]) : String
  (match func
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-and-or-func-op inner))]
    [(ast.AstExpr.Var name) (lint-and-or-op-name (ci.intern-str name))]
    [_ ""]))

(define (lint-transitional-core-macro-bare-name [name : String]) : String
  (cond
    [(string.eq name "core.when") "when"]
    [(string.eq name "core.unless") "unless"]
    [(string.eq name "core.and") "and"]
    [(string.eq name "core.or") "or"]
    [(string.eq name "core.cond") "cond"]
    [else ""]))

(define (lint-transitional-core-macro-qualified-name [func : ast.AstExpr]) : String
  (match func
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-transitional-core-macro-qualified-name inner))]
    [(ast.AstExpr.Var name)
      (let
        [text : String (ci.intern-str name)]
        (if (string.eq
          (lint-transitional-core-macro-bare-name
            (owned_view.compiler-owned-shared-view text))
          "")
          ""
          text))]
    [_ ""]))

(define (lint-transitional-core-macro-finding
  [qualified : String]
  [bare : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "transitional core macro qualifier: use "
      bare
      " instead of "
      qualified)
    (lint-rule-transitional-core-macro-qualifier-id)
    0
    span))

(define (lint-transitional-core-macro-add
  [func : ast.AstExpr]
  [span : ast.AstSourceSpan]
  [acc : LintFindings]) : LintFindings
  (let
    [qualified : String (lint-transitional-core-macro-qualified-name func)]
    [bare : String
      (lint-transitional-core-macro-bare-name
        (owned_view.compiler-owned-shared-view qualified))]
    (if (string.eq bare "")
      acc
      (lint-findings-add
        (lint-transitional-core-macro-finding qualified bare span)
        acc))))

(define (lint-str-cat-func? [func : ast.AstExpr]) : bool
  (match func
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-str-cat-func? inner))]
    [(ast.AstExpr.Var name) (string.eq (ci.intern-str name) "str-cat")]
    [_ false]))

(define (lint-literal-render [lit : ast.AstLiteral]) : String
  (match lit
    [(ast.AstLiteral.Int value text)
      (if (> (string.string-length text) 0)
        text
        (string.int->string value))]
    [(ast.AstLiteral.Float value) value]
    [(ast.AstLiteral.Bool value)
      (if value
        "true"
        "false")]
    [(ast.AstLiteral.String string-id)
      (str_cat.str-cat "\"" (ci.intern-str string-id) "\"")]
    [(ast.AstLiteral.Unit) "unit"]
    [_ "<expr>"]))

(define (lint-bin-op-render [op : ast.AstBinOp]) : String
  (match op
    [(ast.AstBinOp.Add) "+"]
    [(ast.AstBinOp.Sub) "-"]
    [(ast.AstBinOp.Mul) "*"]
    [(ast.AstBinOp.Div) "/"]
    [(ast.AstBinOp.Mod) "%"]
    [(ast.AstBinOp.Eq) "="]
    [(ast.AstBinOp.Ne) "!="]
    [(ast.AstBinOp.Lt) "<"]
    [(ast.AstBinOp.Le) "<="]
    [(ast.AstBinOp.Gt) ">"]
    [(ast.AstBinOp.Ge) ">="]
    [(ast.AstBinOp.And) "and"]
    [(ast.AstBinOp.Or) "or"]
    [(ast.AstBinOp.BitAnd) "bit-and"]
    [(ast.AstBinOp.BitOr) "bit-or"]
    [(ast.AstBinOp.BitXor) "bit-xor"]
    [(ast.AstBinOp.Shl) "shl"]
    [(ast.AstBinOp.Shr) "shr"]))

(define (lint-un-op-render [op : ast.AstUnOp]) : String
  (match op
    [(ast.AstUnOp.Neg) "-"]
    [(ast.AstUnOp.Not) "not"]
    [(ast.AstUnOp.BitNot) "bit-not"]))

(define (lint-render-args-join [head : String] [tail : String]) : String
  (if (string.eq tail "")
    head
    (str_cat.str-cat head " " tail)))

(define (lint-expr-list-render [exprs : ast.AstExprList]) : String
  (lint-expr-list-render-at (& exprs) 0))

(define (lint-expr-list-render-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]) : String
  (if (>= index exprs.len)
    ""
    (let
      [head-expr : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))]
      (lint-render-args-join
        (lint-expr-render head-expr)
        (lint-expr-list-render-at exprs (+ index 1))))))

(define (lint-parenthesized-call-render [callee : String] [args : String]) : String
  (if (string.eq args "")
    (str_cat.str-cat "(" callee ")")
    (str_cat.str-cat "(" callee " " args ")")))

(define (lint-expr-render [expr : ast.AstExpr]) : String
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-expr-render inner))]
    [(ast.AstExpr.Var name) (ci.intern-str name)]
    [(ast.AstExpr.Literal lit) (lint-literal-render lit)]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (lint-parenthesized-call-render
          (lint-expr-render func)
          (lint-expr-list-render args)))]
    [(ast.AstExpr.Binary op left-box right-box)
      (let
        [left : ast.AstExpr (ast.ast-node-get left-box)]
        [right : ast.AstExpr (ast.ast-node-get right-box)]
        (lint-parenthesized-call-render
          (lint-bin-op-render op)
          (lint-render-args-join
            (lint-expr-render left)
            (lint-expr-render right))))]
    [(ast.AstExpr.Unary op inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-parenthesized-call-render
          (lint-un-op-render op)
          (lint-expr-render inner)))]
    [_ "<expr>"]))

(define (lint-and-or-call-kind? [op : String] [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-and-or-call-kind? op inner))]
    [(ast.AstExpr.Call func-box _)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (string.eq (lint-and-or-func-op func) op))]
    [_ false]))

(define (lint-and-or-args-have-kind? [op : String] [args : ast.AstExprList]) : bool
  (lint-and-or-args-have-kind-at? op (& args) 0))

(define (lint-and-or-args-have-kind-at?
  [op : String]
  [args : (& args ast.AstExprList)]
  [index : i64]) : bool
  (if (>= index args.len)
    false
    (let
      [head-expr : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get args index 0))]
      (if (lint-and-or-call-kind?
        (owned_view.compiler-owned-shared-view op)
        head-expr)
        true
        (lint-and-or-args-have-kind-at? op args (+ index 1))))))

(define (lint-str-cat-call? [expr : ast.AstExpr]) : bool
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-str-cat-call? inner))]
    [(ast.AstExpr.Call func-box _)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (lint-str-cat-func? func))]
    [_ false]))

(define (lint-str-cat-args-have-nested? [args : ast.AstExprList]) : bool
  (lint-str-cat-args-have-nested-at? (& args) 0))

(define (lint-str-cat-args-have-nested-at?
  [args : (& args ast.AstExprList)]
  [index : i64]) : bool
  (if (>= index args.len)
    false
    (let
      [head-expr : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get args index 0))]
      (if (lint-str-cat-call? head-expr)
        true
        (lint-str-cat-args-have-nested-at? args (+ index 1))))))

(define (lint-cascading-and-or-flat-arg-render
  [op : String]
  [expr : ast.AstExpr]) : String
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-cascading-and-or-flat-arg-render op inner))]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (if (string.eq (lint-and-or-func-op func) op)
          (lint-cascading-and-or-flat-args-render op args)
          (lint-expr-render expr)))]
    [_ (lint-expr-render expr)]))

(define (lint-cascading-and-or-flat-args-render
  [op : String]
  [args : ast.AstExprList]) : String
  (lint-cascading-and-or-flat-args-render-at op (& args) 0))

(define (lint-cascading-and-or-flat-args-render-at
  [op : String]
  [args : (& args ast.AstExprList)]
  [index : i64]) : String
  (if (>= index args.len)
    ""
    (let
      [head-expr : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get args index 0))]
      (lint-render-args-join
        (lint-cascading-and-or-flat-arg-render
          (owned_view.compiler-owned-shared-view op)
          head-expr)
        (lint-cascading-and-or-flat-args-render-at op args (+ index 1))))))

(define (lint-cascading-and-or-flat-arg-count
  [op : String]
  [expr : ast.AstExpr]) : i64
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-cascading-and-or-flat-arg-count op inner))]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (if (string.eq (lint-and-or-func-op func) op)
          (lint-cascading-and-or-flat-arg-count-list op args)
          1))]
    [_ 1]))

(define (lint-cascading-and-or-flat-arg-count-list
  [op : String]
  [args : ast.AstExprList]) : i64
  (lint-cascading-and-or-flat-arg-count-list-at op (& args) 0))

(define (lint-cascading-and-or-flat-arg-count-list-at
  [op : String]
  [args : (& args ast.AstExprList)]
  [index : i64]) : i64
  (if (>= index args.len)
    0
    (let
      [head-expr : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get args index 0))]
      (+
        (lint-cascading-and-or-flat-arg-count
          (owned_view.compiler-owned-shared-view op)
          head-expr)
        (lint-cascading-and-or-flat-arg-count-list-at op args (+ index 1))))))

(define (lint-cascading-and-or-flat-call
  [callee : String]
  [op : String]
  [args : ast.AstExprList]) : String
  (lint-parenthesized-call-render
    callee
    (lint-cascading-and-or-flat-args-render op args)))

(define (lint-cascading-and-or-finding
  [op : String]
  [callee : String]
  [args : ast.AstExprList]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "cascading "
      (owned_view.compiler-owned-shared-view op)
      ": prefer flat n-ary form "
      (lint-cascading-and-or-flat-call
        callee
        (owned_view.compiler-owned-shared-view op)
        (owned_view.compiler-owned-shared-view args)))
    (lint-rule-cascading-and-or-id)
    (lint-cascading-and-or-flat-arg-count-list op args)
    span))

(define (lint-nested-str-cat-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-nested-str-cat-message)
    (lint-rule-nested-str-cat-id)
    0
    span))

(define (lint-deprecated-string-concat-token-span
  [tok : token.SpannedToken]
  [name : String]) : ast.AstSourceSpan
  (ast.ast-source-span
    (token.spanned-token-line tok)
    (token.spanned-token-col tok)
    (token.spanned-token-line tok)
    (+ (token.spanned-token-col tok) (string.string-length name))))

(define (lint-deprecated-string-concat-scan
  [source : String]
  [acc : LintFindings]) : LintFindings
  (match (lexer.spanned-result (owned_view.compiler-owned-shared-view source))
    [(lexer.ResultSpannedTokens.Err _) acc]
    [(lexer.ResultSpannedTokens.Ok toks)
      (let
        [i : i64 0]
        [done : bool false]
        [depth : i64 0]
        [loop-depth : i64 0]
        [concat-depth : i64 0]
        [stack-cap : i64 (+ (string.string-length source) 2)]
        [loop-stack : (__tl_dyn-array bool) (__tl_make-array bool stack-cap)]
        [concat-stack : (__tl_dyn-array bool) (__tl_make-array bool stack-cap)]
        [findings : LintFindings acc]
        (begin
          (while (not done)
            (begin
              (let
                [spanned : token.SpannedToken
                  (owned_view.compiler-owned-array-element-shared-view toks i)]
                [tok : token.Token (token.spanned-token-tok spanned)]
                [tag : i64 (token.tag tok)]
                (cond
                  [(= tag (token.tag-end)) (set! done true)]
                  [(= tag (token.tag-lparen))
                    (let
                      [head-spanned : token.SpannedToken
                        (owned_view.compiler-owned-array-element-shared-view
                          toks
                          (+ i 1))]
                      [head : token.Token
                        (token.spanned-token-tok
                          (owned_view.compiler-owned-shared-view head-spanned))]
                      [name : String (lint-token-name head)]
                      [is-loop : bool
                        (lint-deprecated-string-concat-loop-form?
                          (owned_view.compiler-owned-shared-view name))]
                      [is-concat : bool
                        (lint-deprecated-string-concat-name?
                          (owned_view.compiler-owned-shared-view name))]
                      (begin
                        (set! depth (+ depth 1))
                        (set! (array-ref loop-stack depth) is-loop)
                        (set! (array-ref concat-stack depth) is-concat)
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
                        (if (owned_view.compiler-owned-array-element-shared-view
                          loop-stack
                          depth)
                          (set! loop-depth (- loop-depth 1))
                          unit)
                        (if (owned_view.compiler-owned-array-element-shared-view
                          concat-stack
                          depth)
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
      [(not
          (lint-string-prefix?
            (owned_view.compiler-owned-shared-view name)
            qualifier))
        false]
      [else (= (string.string-ref name qualifier-len) separator)])))

(define (lint-name-qualified-by? [name : String] [qualifier : String]) : bool
  (if (lint-name-qualified-by-separator?
    (owned_view.compiler-owned-shared-view name)
    (owned_view.compiler-owned-shared-view qualifier)
    '.')
    true
    (lint-name-qualified-by-separator? name qualifier '/')))

(define (lint-name-uses-import?
  [name : String]
  [alias : String]
  [module-name : String]) : bool
  (if (lint-name-qualified-by?
    (owned_view.compiler-owned-shared-view name)
    alias)
    true
    (lint-name-qualified-by? name module-name)))

(define (lint-name-id-uses-import?
  [name : i64]
  [alias : String]
  [module-name : String]) : bool
  (lint-name-uses-import?
    (ci.intern-str name)
    (owned_view.compiler-owned-shared-view alias)
    (owned_view.compiler-owned-shared-view module-name)))

(define (lint-maybe-type-uses-import?
  [maybe-ty : ast.AstMaybeType]
  [alias : String]
  [module-name : String]) : bool
  (match maybe-ty
    [(ast.AstMaybeType.No) false]
    [(ast.AstMaybeType.Some ty)
      (lint-type-uses-import?
        ty
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]))

(define (lint-type-list-uses-import?
  [types : ast.AstTypeList]
  [alias : String]
  [module-name : String]) : bool
  (lint-type-list-uses-import-at? (& types) alias module-name 0))

(define (lint-type-list-uses-import-at?
  [types : (& types ast.AstTypeList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index (ast.ast-type-list-len types))
    false
    (if (lint-type-uses-import?
      (ast.ty-node-get
        (ast.ast-type-list-get types index (ast.ast-type-id-fallback)))
      (owned_view.compiler-owned-shared-view alias)
      (owned_view.compiler-owned-shared-view module-name))
      true
      (lint-type-list-uses-import-at? types alias module-name (+ index 1)))))

(define (lint-type-id-uses-import?
  [ty : i64]
  [alias : String]
  [module-name : String]) : bool
  (lint-type-uses-import?
    (ast.ty-node-get ty)
    (owned_view.compiler-owned-shared-view alias)
    (owned_view.compiler-owned-shared-view module-name)))

(define (lint-type-uses-import?
  [ty : ast.AstType]
  [alias : String]
  [module-name : String]) : bool
  (match ty
    [(ast.AstType.I64) false]
    [(ast.AstType.I32) false]
    [(ast.AstType.I16) false]
    [(ast.AstType.I8) false]
    [(ast.AstType.U64) false]
    [(ast.AstType.U32) false]
    [(ast.AstType.U16) false]
    [(ast.AstType.U8) false]
    [(ast.AstType.F64) false]
    [(ast.AstType.F32) false]
    [(ast.AstType.Bool) false]
    [(ast.AstType.Char) false]
    [(ast.AstType.String) false]
    [(ast.AstType.Str) false]
    [(ast.AstType.Bytes) false]
    [(ast.AstType.Unit) false]
    [(ast.AstType.Never) false]
    [(ast.AstType.Expr) false]
    [(ast.AstType.ExprList) false]
    [(ast.AstType.Func args ret)
      (if (lint-type-list-uses-import?
        (owned_view.compiler-owned-box-shared-view args)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-type-id-uses-import?
          ret
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstType.Tuple items)
      (lint-type-list-uses-import?
        (owned_view.compiler-owned-box-shared-view items)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.Array elem _)
      (lint-type-id-uses-import?
        elem
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.DynArray elem)
      (lint-type-id-uses-import?
        elem
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.Slice elem)
      (lint-type-id-uses-import?
        elem
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.Box elem)
      (lint-type-id-uses-import?
        elem
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.Region _ inner)
      (lint-type-id-uses-import?
        inner
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.Ref _ inner)
      (lint-type-id-uses-import?
        inner
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.MutRef _ inner)
      (lint-type-id-uses-import?
        inner
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.Enum name)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.EnumArgs name _)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.Struct name)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.StructArgs name _)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.Var name)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.VarArgs name _)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.Ptr inner)
      (lint-type-id-uses-import?
        inner
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstType.MutPtr inner)
      (lint-type-id-uses-import?
        inner
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]))

(define (lint-param-list-uses-import?
  [params : ast.AstParamList]
  [alias : String]
  [module-name : String]) : bool
  (lint-param-list-uses-import-at? (& params) alias module-name 0))

(define (lint-param-list-uses-import-at?
  [params : (& params ast.AstParamList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index (ast.ast-param-list-len params))
    false
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param _ ty _)
        (if (lint-type-uses-import?
          ty
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-param-list-uses-import-at? params alias module-name (+ index 1)))])))

(define (lint-macro-param-list-uses-import?
  [params : ast.AstMacroParamList]
  [alias : String]
  [module-name : String]) : bool
  (lint-macro-param-list-uses-import-at? (& params) alias module-name 0))

(define (lint-macro-param-list-uses-import-at?
  [params : (& params ast.AstMacroParamList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index (ast.ast-macro-param-list-len params))
    false
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(ast.AstMacroParam.Param _ ty _ _)
        (if (lint-type-uses-import?
          ty
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-macro-param-list-uses-import-at?
            params
            alias
            module-name
            (+ index 1)))])))

(define (lint-pattern-list-uses-import?
  [patterns : ast.AstPatternList]
  [alias : String]
  [module-name : String]) : bool
  (lint-pattern-list-uses-import-at? (& patterns) alias module-name 0))

(define (lint-pattern-list-uses-import-at?
  [patterns : (& patterns ast.AstPatternList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index patterns.len)
    false
    (if (lint-pattern-uses-import?
      (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
      (owned_view.compiler-owned-shared-view alias)
      (owned_view.compiler-owned-shared-view module-name))
      true
      (lint-pattern-list-uses-import-at? patterns alias module-name (+ index 1)))))

(define (lint-pattern-uses-import?
  [pattern : ast.AstPattern]
  [alias : String]
  [module-name : String]) : bool
  (match pattern
    [(ast.AstPattern.Var _ maybe-ty)
      (lint-maybe-type-uses-import?
        maybe-ty
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstPattern.Tuple items)
      (lint-pattern-list-uses-import?
        (owned_view.compiler-owned-box-shared-view items)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstPattern.Array items)
      (lint-pattern-list-uses-import?
        (owned_view.compiler-owned-box-shared-view items)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstPattern.Wildcard) false]
    [(ast.AstPattern.Binding _) false]
    [(ast.AstPattern.Variant name items)
      (if (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-pattern-list-uses-import?
          (owned_view.compiler-owned-box-shared-view items)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstPattern.Literal _) false]))

(define (lint-unused-unsafe-candidate-sentinel?
  [alias : String]
  [module-name : String]) : bool
  (and
    (string.eq alias "__tl_lint_unused_unsafe_candidate")
    (string.eq module-name "")))

(define (lint-requires-enclosing-unsafe-sentinel?
  [alias : String]
  [module-name : String]) : bool
  (and
    (string.eq alias "__tl_lint_requires_enclosing_unsafe")
    (string.eq module-name "")))

(define (lint-expr-list-requires-enclosing-unsafe? [exprs : ast.AstExprList]) : bool
  (__tl-project-field
    (lint-unsafe-scan-expr-list
      exprs
      (LintUnsafeScope (lint-name-set-empty) false))
    requires))

(define (lint-expr-list-uses-import?
  [exprs : ast.AstExprList]
  [alias : String]
  [module-name : String]) : bool
  (lint-expr-list-uses-import-at? (& exprs) alias module-name 0))

(define (lint-expr-list-uses-import-at?
  [exprs : (& exprs ast.AstExprList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index exprs.len)
    false
    (let
      [head : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))]
      (if (lint-expr-uses-import?
        head
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-list-uses-import-at? exprs alias module-name (+ index 1))))))

(define (lint-let-bindings-use-import?
  [bindings : ast.AstLetBindingList]
  [alias : String]
  [module-name : String]) : bool
  (lint-let-bindings-use-import-at? (& bindings) alias module-name 0))

(define (lint-let-bindings-use-import-at?
  [bindings : (& bindings ast.AstLetBindingList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index (ast.ast-let-binding-list-len bindings))
    false
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding _ maybe-ty init)
        (if (lint-maybe-type-uses-import?
          maybe-ty
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (if (lint-expr-uses-import?
            (ast.ast-node-get init)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
            true
            (lint-let-bindings-use-import-at?
              bindings
              alias
              module-name
              (+ index 1))))])))

(define (lint-match-arms-use-import?
  [arms : ast.AstMatchArmList]
  [alias : String]
  [module-name : String]) : bool
  (lint-match-arms-use-import-at? (& arms) alias module-name 0))

(define (lint-match-arms-use-import-at?
  [arms : (& arms ast.AstMatchArmList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index arms.len)
    false
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm pattern body)
        (if (lint-pattern-uses-import?
          pattern
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (if (lint-expr-uses-import?
            (ast.ast-node-get body)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
            true
            (lint-match-arms-use-import-at? arms alias module-name (+ index 1))))])))

(define (lint-resource-bindings-use-import?
  [bindings : ast.AstResourceBindingList]
  [alias : String]
  [module-name : String]) : bool
  (lint-resource-bindings-use-import-at? (& bindings) alias module-name 0))

(define (lint-resource-bindings-use-import-at?
  [bindings : (& bindings ast.AstResourceBindingList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index (ast.ast-resource-binding-list-len bindings))
    false
    (match (ast.ast-resource-binding-list-get
      bindings
      index
      (ast.ast-resource-binding-fallback))
      [(ast.AstResourceBinding.Binding _ init cleanup _)
        (if (lint-expr-uses-import?
          (ast.ast-node-get init)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (if (lint-expr-uses-import?
            (ast.ast-node-get cleanup)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
            true
            (lint-resource-bindings-use-import-at?
              bindings
              alias
              module-name
              (+ index 1))))])))

(define (lint-expr-uses-import?
  [expr : ast.AstExpr]
  [alias : String]
  [module-name : String]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (lint-expr-uses-import?
        (ast.ast-node-get inner-box)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.MacroExpansion inner-box _ _)
      (lint-expr-uses-import?
        (ast.ast-node-get inner-box)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Literal _) false]
    [(ast.AstExpr.Var name)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Binary _ left right)
      (if (lint-expr-uses-import?
        (ast.ast-node-get left)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get right)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.Unary _ inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Call func args)
      (if (lint-expr-uses-import?
        (ast.ast-node-get func)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-list-uses-import?
          args
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.If cond then-branch else-branch)
      (if (lint-expr-uses-import?
        (ast.ast-node-get cond)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (if (lint-expr-uses-import?
          (ast.ast-node-get then-branch)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-expr-uses-import?
            (ast.ast-node-get else-branch)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (if (lint-let-bindings-use-import?
            bindings
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
            true
            (lint-expr-uses-import?
              (ast.ast-node-get body)
              (owned_view.compiler-owned-shared-view alias)
              (owned_view.compiler-owned-shared-view module-name)))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda params ret body)
          (if (lint-param-list-uses-import?
            params
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
            true
            (if (lint-maybe-type-uses-import?
              ret
              (owned_view.compiler-owned-shared-view alias)
              (owned_view.compiler-owned-shared-view module-name))
              true
              (lint-expr-uses-import?
                (ast.ast-node-get body)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))))])]
    [(ast.AstExpr.Tuple exprs)
      (lint-expr-list-uses-import?
        exprs
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.TupleRef tuple _)
      (lint-expr-uses-import?
        (ast.ast-node-get tuple)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Array exprs)
      (lint-expr-list-uses-import?
        exprs
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.DynArray exprs)
      (lint-expr-list-uses-import?
        exprs
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.MakeArray elem-id len)
      (if (lint-type-uses-import?
        (ast.ty-node-get elem-id)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get len)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.ArrayRef array index)
      (if (lint-expr-uses-import?
        (ast.ast-node-get array)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get index)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.ArraySet array index value)
      (if (lint-expr-uses-import?
        (ast.ast-node-get array)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (if (lint-expr-uses-import?
          (ast.ast-node-get index)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-expr-uses-import?
            (ast.ast-node-get value)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstExpr.ArrayTake array live index)
      (if (lint-expr-uses-import?
        (ast.ast-node-get array)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (if (lint-expr-uses-import?
          (ast.ast-node-get live)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-expr-uses-import?
            (ast.ast-node-get index)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstExpr.FixedArrayTake array index)
      (if (lint-expr-uses-import?
        (ast.ast-node-get array)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get index)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.Replace place replacement)
      (if (lint-expr-uses-import?
        (ast.ast-node-get place)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get replacement)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.ArrayPush array value)
      (if (lint-expr-uses-import?
        (ast.ast-node-get array)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get value)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.StringRef text index)
      (if (lint-expr-uses-import?
        (ast.ast-node-get text)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get index)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.While cond body)
      (if (lint-expr-uses-import?
        (ast.ast-node-get cond)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get body)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.ForOwnedState payload)
      (if (lint-expr-uses-import?
        (ast.ast-node-get (ast.ast-for-owned-state-source (& payload)))
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get (ast.ast-for-owned-state-body (& payload)))
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (if (and
          (>= expected-type 0)
          (lint-expr-uses-import?
            (ast.ast-node-get expected-type)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name)))
          true
          (lint-expr-uses-import?
            (ast.ast-node-get (ast.ast-for-owned-step-body (& payload)))
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstExpr.Begin exprs)
      (lint-expr-list-uses-import?
        exprs
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Unsafe exprs)
      (cond
        [(lint-requires-enclosing-unsafe-sentinel?
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
          false]
        [(lint-unused-unsafe-candidate-sentinel?
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
          (if (lint-expr-list-requires-enclosing-unsafe?
            (owned_view.compiler-owned-shared-view exprs))
            (lint-expr-list-uses-import?
              (owned_view.compiler-owned-shared-view exprs)
              (owned_view.compiler-owned-shared-view alias)
              (owned_view.compiler-owned-shared-view module-name))
            true)]
        [else
          (lint-expr-list-uses-import?
            (owned_view.compiler-owned-shared-view exprs)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))])]
    [(ast.AstExpr.Set target value)
      (if (lint-name-id-uses-import?
        target
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get value)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.Ann inner ty-id)
      (if (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-type-uses-import?
          (ast.ty-node-get ty-id)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.Cast inner ty-id)
      (if (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-type-uses-import?
          (ast.ty-node-get ty-id)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.Borrow _ _ place)
      (lint-expr-uses-import?
        (ast.ast-node-get place)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (if (lint-expr-uses-import?
            (ast.ast-node-get scrutinee)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
            true
            (lint-match-arms-use-import?
              arms
              (owned_view.compiler-owned-shared-view alias)
              (owned_view.compiler-owned-shared-view module-name)))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach _ index-ty start end body)
          (cond
            [(lint-type-uses-import?
                index-ty
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [(lint-expr-uses-import?
                (ast.ast-node-get start)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [(lint-expr-uses-import?
                (ast.ast-node-get end)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [else
              (lint-expr-uses-import?
                (ast.ast-node-get body)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))])])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce _ _ index-ty start end init value)
          (cond
            [(lint-type-uses-import?
                index-ty
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [(lint-expr-uses-import?
                (ast.ast-node-get start)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [(lint-expr-uses-import?
                (ast.ast-node-get end)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [(lint-expr-uses-import?
                (ast.ast-node-get init)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [else
              (lint-expr-uses-import?
                (ast.ast-node-get value)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))])])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(ast.AstSpmdScan.Scan
            _
            _
            index-ty
            start
            end
            _
            prefix-ty
            init
            value
            body)
          (cond
            [(lint-type-uses-import?
                index-ty
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [(lint-type-uses-import?
                prefix-ty
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [(lint-expr-uses-import?
                (ast.ast-node-get start)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [(lint-expr-uses-import?
                (ast.ast-node-get end)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [(lint-expr-uses-import?
                (ast.ast-node-get init)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [(lint-expr-uses-import?
                (ast.ast-node-get value)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))
              true]
            [else
              (lint-expr-uses-import?
                (ast.ast-node-get body)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view module-name))])])]
    [(ast.AstExpr.SpmdBroadcast value lane)
      (if (lint-expr-uses-import?
        (ast.ast-node-get value)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get lane)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.SpmdShuffle value lane)
      (if (lint-expr-uses-import?
        (ast.ast-node-get value)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get lane)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.StructGet receiver _)
      (lint-expr-uses-import?
        (ast.ast-node-get receiver)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.StructSet receiver _ value)
      (if (lint-expr-uses-import?
        (ast.ast-node-get receiver)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get value)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.WithRegion _ body)
      (lint-expr-list-uses-import?
        body
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.WithEscape scratch body)
      (if (lint-expr-uses-import?
        (ast.ast-node-get scratch)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-list-uses-import?
          body
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.WithScratch body)
      (lint-expr-list-uses-import?
        body
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.InArena arena body)
      (if (lint-expr-uses-import?
        (ast.ast-node-get arena)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-list-uses-import?
          body
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (if (lint-resource-bindings-use-import?
            bindings
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
            true
            (lint-expr-list-uses-import?
              body
              (owned_view.compiler-owned-shared-view alias)
              (owned_view.compiler-owned-shared-view module-name)))])]
    [(ast.AstExpr.Box inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.BoxGet inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.BoxTake inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.BoxSet inner value)
      (if (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get value)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.TypeLiteral ty-id)
      (lint-type-uses-import?
        (ast.ty-node-get ty-id)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Init maybe-ty-id)
      (lint-maybe-type-uses-import?
        (ast.ast-maybe-type-from-id maybe-ty-id)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Comptime inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Quote inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Quasiquote inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Unquote inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.UnquoteSplicing inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.BracketClause items)
      (lint-expr-list-uses-import?
        items
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Try inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Return inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Break) false]
    [(ast.AstExpr.Continue) false]
    [(ast.AstExpr.PtrNull ty-id)
      (lint-type-uses-import?
        (ast.ty-node-get ty-id)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.PtrNullCheck inner)
      (lint-expr-uses-import?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.PtrAddrOf place)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get place)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.PtrRead ptr)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get ptr)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.PtrWrite ptr value)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (if (lint-expr-uses-import?
          (ast.ast-node-get ptr)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-expr-uses-import?
            (ast.ast-node-get value)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstExpr.PtrOffset ptr offset)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (if (lint-expr-uses-import?
          (ast.ast-node-get ptr)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-expr-uses-import?
            (ast.ast-node-get offset)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstExpr.PtrCast ptr ty-id)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (if (lint-expr-uses-import?
          (ast.ast-node-get ptr)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-type-uses-import?
            (ast.ty-node-get ty-id)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstExpr.PtrToInt ptr)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get ptr)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.IntToPtr value ty-id)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (if (lint-expr-uses-import?
          (ast.ast-node-get value)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-type-uses-import?
            (ast.ty-node-get ty-id)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstExpr.StringData inner)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get inner)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.StringFromBytes ptr len)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (if (lint-expr-uses-import?
          (ast.ast-node-get ptr)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-expr-uses-import?
            (ast.ast-node-get len)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstExpr.ArrayData inner)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get inner)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.BinaryData _) false]
    [(ast.AstExpr.SpmdProgramIndex) false]
    [(ast.AstExpr.SpmdProgramCount) false]
    [(ast.AstExpr.ProgramArgc) false]
    [(ast.AstExpr.ProgramArgv) false]
    [(ast.AstExpr.ProgramEnvp) false]
    [(ast.AstExpr.CpuIdEax leaf subleaf)
      (if (lint-expr-uses-import?
        (ast.ast-node-get leaf)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get subleaf)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.CpuIdEbx leaf subleaf)
      (if (lint-expr-uses-import?
        (ast.ast-node-get leaf)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get subleaf)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.CpuIdEcx leaf subleaf)
      (if (lint-expr-uses-import?
        (ast.ast-node-get leaf)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get subleaf)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.CpuIdEdx leaf subleaf)
      (if (lint-expr-uses-import?
        (ast.ast-node-get leaf)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get subleaf)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstExpr.Xgetbv index)
      (lint-expr-uses-import?
        (ast.ast-node-get index)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstExpr.Syscall args)
      (if (lint-requires-enclosing-unsafe-sentinel?
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-list-uses-import?
          args
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]))

(define (lint-extern-abi-uses-import?
  [abi : ast.AstExternAbi]
  [alias : String]
  [module-name : String]) : bool
  (match abi
    [(ast.AstExternAbi.C) false]
    [(ast.AstExternAbi.CVarargsOpen) false]
    [(ast.AstExternAbi.CVarargsTyped tail-ty)
      (lint-type-uses-import?
        tail-ty
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]))

(define (lint-extern-metadata-uses-import?
  [meta : ast.AstExternMetadata]
  [alias : String]
  [module-name : String]) : bool
  (match meta
    [(ast.AstExternMetadata.Metadata abi _ _ _ _)
      (lint-extern-abi-uses-import?
        abi
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]))

(define (lint-field-cleanup-uses-import?
  [cleanup : ast.AstFieldCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(ast.AstFieldCleanup.No) false]
    [(ast.AstFieldCleanup.Fn name)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstFieldCleanup.Owned) false]))

(define (lint-field-def-list-uses-import?
  [fields : ast.AstFieldDefList]
  [alias : String]
  [module-name : String]) : bool
  (lint-field-def-list-uses-import-at? (& fields) alias module-name 0))

(define (lint-field-def-list-uses-import-at?
  [fields : (& fields ast.AstFieldDefList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index fields.len)
    false
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def _ ty cleanup)
        (if (lint-type-uses-import?
          ty
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (if (lint-field-cleanup-uses-import?
            cleanup
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
            true
            (lint-field-def-list-uses-import-at?
              fields
              alias
              module-name
              (+ index 1))))])))

(define (lint-struct-cleanup-uses-import?
  [cleanup : ast.AstStructCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(ast.AstStructCleanup.No) false]
    [(ast.AstStructCleanup.Fn name)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]))

(define (lint-enum-cleanup-uses-import?
  [cleanup : ast.AstEnumCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(ast.AstEnumCleanup.No) false]
    [(ast.AstEnumCleanup.Fn name)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]))

(define (lint-variant-payload-cleanup-uses-import?
  [cleanup : ast.AstVariantPayloadCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(ast.AstVariantPayloadCleanup.No) false]
    [(ast.AstVariantPayloadCleanup.Fn name)
      (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstVariantPayloadCleanup.Owned) false]))

(define (lint-variant-payload-cleanup-list-uses-import?
  [items : ast.AstVariantPayloadCleanupList]
  [alias : String]
  [module-name : String]) : bool
  (lint-variant-payload-cleanup-list-uses-import-at?
    (& items)
    alias
    module-name
    0))

(define (lint-variant-payload-cleanup-list-uses-import-at?
  [items : (& items ast.AstVariantPayloadCleanupList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index items.len)
    false
    (if (lint-variant-payload-cleanup-uses-import?
      (ast.ast-variant-payload-cleanup-list-get
        items
        index
        (ast.ast-variant-payload-cleanup-fallback))
      (owned_view.compiler-owned-shared-view alias)
      (owned_view.compiler-owned-shared-view module-name))
      true
      (lint-variant-payload-cleanup-list-uses-import-at?
        items
        alias
        module-name
        (+ index 1)))))

(define (lint-variant-def-list-uses-import?
  [variants : ast.AstVariantDefList]
  [alias : String]
  [module-name : String]) : bool
  (lint-variant-def-list-uses-import-at? (& variants) alias module-name 0))

(define (lint-variant-def-list-uses-import-at?
  [variants : (& variants ast.AstVariantDefList)]
  [alias : String]
  [module-name : String]
  [index : i64]) : bool
  (if (>= index variants.len)
    false
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def _ payloads cleanups)
        (if (lint-type-list-uses-import?
          payloads
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (if (lint-variant-payload-cleanup-list-uses-import?
            cleanups
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
            true
            (lint-variant-def-list-uses-import-at?
              variants
              alias
              module-name
              (+ index 1))))])))

(define (lint-dispatch-variant-list-uses-import-from?
  [variants : (& variants ast.AstDispatchVariantList)]
  [index : i64]
  [alias : String]
  [module-name : String]) : bool
  (if (>= index variants.len)
    false
    (match (ast.ast-dispatch-variant-list-get
      variants
      index
      (ast.ast-dispatch-variant-fallback))
      [(ast.AstDispatchVariant.Variant _ name)
        (if (lint-name-id-uses-import?
          name
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-dispatch-variant-list-uses-import-from?
            variants
            (+ index 1)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name)))])))

(define (lint-dispatch-variant-list-uses-import?
  [variants : ast.AstDispatchVariantList]
  [alias : String]
  [module-name : String]) : bool
  (lint-dispatch-variant-list-uses-import-from?
    (& variants)
    0
    (owned_view.compiler-owned-shared-view alias)
    (owned_view.compiler-owned-shared-view module-name)))

(define (lint-generated-decl-meta-uses-import?
  [meta : ast.AstGeneratedDeclMeta]
  [alias : String]
  [module-name : String]) : bool
  (match meta
    [(ast.AstGeneratedDeclMeta.No) false]
    [(ast.AstGeneratedDeclMeta.Some _ _ args _)
      (lint-expr-list-uses-import?
        args
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]))

(define (lint-decl-uses-import-inner?
  [decl : ast.AstDecl]
  [alias : String]
  [module-name : String]) : bool
  (match (owned_view.compiler-owned-shared-view decl)
    [(ast.AstDecl.Module _) false]
    [(ast.AstDecl.ModuleBody _ body)
      (lint-decl-list-uses-import?
        (ast.ast-decl-list-box-shared-view body)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstDecl.Def decl-meta _ maybe-ty body)
      (if (lint-maybe-type-uses-import?
        maybe-ty
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import?
          (ast.ast-node-get body)
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstDecl.DefFn decl-meta _ params ret body _)
      (if (lint-param-list-uses-import?
        params
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (if (lint-type-uses-import?
          ret
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-expr-uses-import?
            (ast.ast-node-get body)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstDecl.DefMacro decl-meta _ params ret body)
      (if (lint-macro-param-list-uses-import?
        params
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (if (lint-type-uses-import?
          ret
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-expr-uses-import?
            (ast.ast-node-get body)
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]
    [(ast.AstDecl.Extern decl-meta _ _ meta ty)
      (if (lint-extern-metadata-uses-import?
        (ast.ast-extern-metadata-box-shared-view meta)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-type-uses-import?
          ty
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstDecl.DefEnum decl-meta _ cleanup variants)
      (if (lint-enum-cleanup-uses-import?
        cleanup
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-variant-def-list-uses-import?
          variants
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstDecl.DefEnumLifetimes decl-meta _ _ cleanup variants)
      (if (lint-enum-cleanup-uses-import?
        cleanup
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-variant-def-list-uses-import?
          variants
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstDecl.DefStruct decl-meta _ _ cleanup fields)
      (if (lint-struct-cleanup-uses-import?
        cleanup
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-field-def-list-uses-import?
          fields
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstDecl.DefStructLifetimes decl-meta _ _ _ cleanup fields)
      (if (lint-struct-cleanup-uses-import?
        cleanup
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-field-def-list-uses-import?
          fields
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name)))]
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec (ast.AstImportKind.Macro call-expr _) _ _ _ _))
      (lint-expr-uses-import?
        (ast.ast-node-get call-expr)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec
          (ast.AstImportKind.MacroDecls call-expr _)
          _
          _
          _
          _))
      (lint-expr-uses-import?
        (ast.ast-node-get call-expr)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstDecl.Import decl-meta _) false]
    [(ast.AstDecl.IncludeStr _ _) false]
    [(ast.AstDecl.IncludeStrComptime _ _) false]
    [(ast.AstDecl.IncludeStrLzss _ _) false]
    [(ast.AstDecl.IncludeBin _ _) false]
    [(ast.AstDecl.DefDispatch decl-meta _ variants)
      (lint-dispatch-variant-list-uses-import?
        variants
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstDecl.Test _ body _)
      (lint-expr-uses-import?
        (ast.ast-node-get body)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]
    [(ast.AstDecl.Unsafe inner)
      (lint-decl-uses-import?
        (ast.ast-decl-box-shared-view inner)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))]))

(define (lint-decl-uses-import?
  [decl : ast.AstDecl]
  [alias : String]
  [module-name : String]) : bool
  (if (lint-generated-decl-meta-uses-import?
    (ast.ast-decl-generated-meta (owned_view.compiler-owned-shared-view decl))
    (owned_view.compiler-owned-shared-view alias)
    (owned_view.compiler-owned-shared-view module-name))
    true
    (lint-decl-uses-import-inner?
      decl
      (owned_view.compiler-owned-shared-view alias)
      (owned_view.compiler-owned-shared-view module-name))))

(define (lint-decl-list-uses-import?
  [decls : ast.AstDeclList]
  [alias : String]
  [module-name : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (if (lint-decl-uses-import?
          decl
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
          true
          (lint-decl-list-uses-import?
            rest
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))))]))

(define (lint-program-has-unused-unsafe-candidate? [program : ast.AstProgram]) : bool
  (lint-unsafe-program-has-candidate? program))

(defstruct LintUnusedUnsafeExactName
  (name String)
  (requires-unsafe bool))

;; Append-only classifier tables. Both are single-owner globals reset once per
;; lint run, so a capacity-doubling append keeps every push O(1) amortized and
;; every lookup a contiguous scan.
(defstruct LintUnusedUnsafeExactNames
  (slots (__tl_dyn-array LintUnusedUnsafeExactName))
  (len i64))

(defenum LintUnusedUnsafeExactLookup
  (Unknown)
  (Safe)
  (RequiresUnsafe))

(defstruct LintUnusedUnsafeUnknownRoots
  (slots (__tl_dyn-array String))
  (len i64))

(define (lint-unused-unsafe-exact-names-empty) : LintUnusedUnsafeExactNames
  (LintUnusedUnsafeExactNames (__tl_make-array LintUnusedUnsafeExactName 0) 0))

(define (lint-unused-unsafe-unknown-roots-empty) : LintUnusedUnsafeUnknownRoots
  (LintUnusedUnsafeUnknownRoots (__tl_make-array String 0) 0))

(define lint-unused-unsafe-exact-names : LintUnusedUnsafeExactNames
  (lint-unused-unsafe-exact-names-empty))
(define lint-unused-unsafe-unknown-roots : LintUnusedUnsafeUnknownRoots
  (lint-unused-unsafe-unknown-roots-empty))
(define lint-unused-unsafe-classifier-enabled : bool
  false)
(define lint-unused-unsafe-classified-required-count : i64
  0)
(define lint-unused-unsafe-classified-unused-count : i64
  0)
(define lint-unused-unsafe-classified-unknown-count : i64
  0)

(defstruct LintUnusedUnsafeBlock
  (span ast.AstSourceSpan)
  (required bool)
  (unknown bool))

;; Strict push/mark-top/pop stack of the enclosing unsafe blocks: one global
;; owner, so the backing array is reused across sibling blocks.
(defstruct LintUnusedUnsafeBlockStack
  (slots (__tl_dyn-array LintUnusedUnsafeBlock))
  (len i64))

(define (lint-unused-unsafe-block-stack-empty) : LintUnusedUnsafeBlockStack
  (LintUnusedUnsafeBlockStack (__tl_make-array LintUnusedUnsafeBlock 0) 0))

(define lint-unused-unsafe-block-stack : LintUnusedUnsafeBlockStack
  (lint-unused-unsafe-block-stack-empty))

(define (lint-unused-unsafe-classifier-reset!) : unit
  (begin
    (set! lint-unused-unsafe-exact-names (lint-unused-unsafe-exact-names-empty))
    (set!
      lint-unused-unsafe-unknown-roots
      (lint-unused-unsafe-unknown-roots-empty))
    (set! lint-unused-unsafe-classified-required-count 0)
    (set! lint-unused-unsafe-classified-unused-count 0)
    (set! lint-unused-unsafe-classified-unknown-count 0)
    (set! lint-unused-unsafe-block-stack (lint-unused-unsafe-block-stack-empty))
    (set! lint-unused-unsafe-classifier-enabled false)))

(define (lint-unused-unsafe-classifier-enable!) : unit
  (set! lint-unused-unsafe-classifier-enabled true))

(define (lint-unused-unsafe-classifier-disable!) : unit
  (set! lint-unused-unsafe-classifier-enabled false))

;; Doubling growth for the append-only tables below: `len` is the live element
;; count and the array keeps spare capacity between appends.
(define (lint-grown-capacity [cap : i64]) : i64
  (if (< cap 4)
    4
    (* cap 2)))

(define (lint-unused-unsafe-classifier-add-exact-name!
  [name : String]
  [requires-unsafe : bool]) : unit
  (let
    [n : i64 (__tl-project-field lint-unused-unsafe-exact-names len)]
    (if (<
      n
      (array-length (__tl-project-field lint-unused-unsafe-exact-names slots)))
      (begin
        (set!
          (array-ref
            (__tl-project-field lint-unused-unsafe-exact-names slots)
            n)
          (LintUnusedUnsafeExactName name requires-unsafe))
        (__tl-project-set-field lint-unused-unsafe-exact-names len (+ n 1)))
      (let
        [bigger : (__tl_dyn-array LintUnusedUnsafeExactName)
          (__tl_make-array
            LintUnusedUnsafeExactName
            (lint-grown-capacity
              (array-length
                (__tl-project-field lint-unused-unsafe-exact-names slots))))]
        [index : i64 0]
        (begin
          (while (< index n)
            (begin
              (set!
                (array-ref bigger index)
                (array-ref
                  (__tl-project-field lint-unused-unsafe-exact-names slots)
                  index))
              (set! index (+ index 1))))
          (set!
            (array-ref bigger n)
            (LintUnusedUnsafeExactName name requires-unsafe))
          (set!
            lint-unused-unsafe-exact-names
            (LintUnusedUnsafeExactNames bigger (+ n 1))))))))

(define (lint-unused-unsafe-classifier-add-unknown-root! [name : String]) : unit
  (let
    [n : i64 (__tl-project-field lint-unused-unsafe-unknown-roots len)]
    (if (<
      n
      (array-length (__tl-project-field lint-unused-unsafe-unknown-roots slots)))
      (begin
        (set!
          (array-ref
            (__tl-project-field lint-unused-unsafe-unknown-roots slots)
            n)
          name)
        (__tl-project-set-field lint-unused-unsafe-unknown-roots len (+ n 1)))
      (let
        [bigger : (__tl_dyn-array String)
          (__tl_make-array
            String
            (lint-grown-capacity
              (array-length
                (__tl-project-field lint-unused-unsafe-unknown-roots slots))))]
        [index : i64 0]
        (begin
          (while (< index n)
            (begin
              (set!
                (array-ref bigger index)
                (array-ref
                  (__tl-project-field lint-unused-unsafe-unknown-roots slots)
                  index))
              (set! index (+ index 1))))
          (set! (array-ref bigger n) name)
          (set!
            lint-unused-unsafe-unknown-roots
            (LintUnusedUnsafeUnknownRoots bigger (+ n 1))))))))

(define (lint-unused-unsafe-classifier-unknown-count) : i64
  lint-unused-unsafe-classified-unknown-count)

(define (lint-unused-unsafe-classifier-required-count) : i64
  lint-unused-unsafe-classified-required-count)

(define (lint-unused-unsafe-classifier-unused-count) : i64
  lint-unused-unsafe-classified-unused-count)

(define (lint-unused-unsafe-block-push!
  [span : ast.AstSourceSpan]
  [required : bool]) : unit
  (if lint-unused-unsafe-classifier-enabled
    (let
      [n : i64 (__tl-project-field lint-unused-unsafe-block-stack len)]
      (if (<
        n
        (array-length (__tl-project-field lint-unused-unsafe-block-stack slots)))
        (begin
          (set!
            (array-ref
              (__tl-project-field lint-unused-unsafe-block-stack slots)
              n)
            (LintUnusedUnsafeBlock span required false))
          (__tl-project-set-field lint-unused-unsafe-block-stack len (+ n 1)))
        (let
          [bigger : (__tl_dyn-array LintUnusedUnsafeBlock)
            (__tl_make-array
              LintUnusedUnsafeBlock
              (lint-grown-capacity
                (array-length
                  (__tl-project-field lint-unused-unsafe-block-stack slots))))]
          [index : i64 0]
          (begin
            (while (< index n)
              (begin
                (set!
                  (array-ref bigger index)
                  (array-ref
                    (__tl-project-field lint-unused-unsafe-block-stack slots)
                    index))
                (set! index (+ index 1))))
            (set!
              (array-ref bigger n)
              (LintUnusedUnsafeBlock span required false))
            (set!
              lint-unused-unsafe-block-stack
              (LintUnusedUnsafeBlockStack bigger (+ n 1)))))))
    unit))

(define (lint-unused-unsafe-block-top-index) : i64
  (- (__tl-project-field lint-unused-unsafe-block-stack len) 1))

(define (lint-unused-unsafe-block-mark-required!) : unit
  (if lint-unused-unsafe-classifier-enabled
    (let
      [top : i64 (lint-unused-unsafe-block-top-index)]
      (if (< top 0)
        unit
        (set!
          (array-ref
            (__tl-project-field lint-unused-unsafe-block-stack slots)
            top)
          (LintUnusedUnsafeBlock
            (__tl-project-field
              (array-ref
                (__tl-project-field lint-unused-unsafe-block-stack slots)
                top)
              span)
            true
            false))))
    unit))

(define (lint-unused-unsafe-block-mark-unknown!) : unit
  (if lint-unused-unsafe-classifier-enabled
    (let
      [top : i64 (lint-unused-unsafe-block-top-index)]
      (if (< top 0)
        unit
        (if (__tl-project-field
          (array-ref
            (__tl-project-field lint-unused-unsafe-block-stack slots)
            top)
          required)
          unit
          (set!
            (array-ref
              (__tl-project-field lint-unused-unsafe-block-stack slots)
              top)
            (LintUnusedUnsafeBlock
              (__tl-project-field
                (array-ref
                  (__tl-project-field lint-unused-unsafe-block-stack slots)
                  top)
                span)
              false
              true)))))
    unit))

(define (lint-unused-unsafe-block-pop-findings [findings : LintFindings]) : LintFindings
  (if (not lint-unused-unsafe-classifier-enabled)
    findings
    (let
      [top : i64 (lint-unused-unsafe-block-top-index)]
      (if (< top 0)
        findings
        (begin
          (__tl-project-set-field lint-unused-unsafe-block-stack len top)
          (if (__tl-project-field
            (array-ref
              (__tl-project-field lint-unused-unsafe-block-stack slots)
              top)
            required)
            (begin
              (set!
                lint-unused-unsafe-classified-required-count
                (+ lint-unused-unsafe-classified-required-count 1))
              findings)
            (if (__tl-project-field
              (array-ref
                (__tl-project-field lint-unused-unsafe-block-stack slots)
                top)
              unknown)
              (begin
                (set!
                  lint-unused-unsafe-classified-unknown-count
                  (+ lint-unused-unsafe-classified-unknown-count 1))
                findings)
              (begin
                (set!
                  lint-unused-unsafe-classified-unused-count
                  (+ lint-unused-unsafe-classified-unused-count 1))
                (lint-findings-add
                  (lint-unused-unsafe-finding
                    (__tl-project-field
                      (array-ref
                        (__tl-project-field
                          lint-unused-unsafe-block-stack
                          slots)
                        top)
                      span))
                  findings)))))))))

(define (lint-underscore-prefixed? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (<= n 0)
      false
      (= (string.string-ref name 0) '_'))))

(define (lint-import-kind-lintable?
  [kind : ast.AstImportKind]
  [_ : ast.AstMaybeModuleName]) : bool
  (match kind
    [(ast.AstImportKind.Module) true]
    [(ast.AstImportKind.ModuleAll) true]
    [(ast.AstImportKind.ModuleItem _) true]
    [(ast.AstImportKind.Macro _ _) false]
    [(ast.AstImportKind.MacroDecls _ _) false]))

(define (lint-string-has-suffix-at?
  [text : String]
  [suffix : String]
  [base : i64]
  [index : i64]
  [n : i64]) : bool
  (if (>= index n)
    true
    (if (=
      (cast (string.string-ref text (+ base index)) : i64)
      (cast (string.string-ref suffix index) : i64))
      (lint-string-has-suffix-at? text suffix base (+ index 1) n)
      false)))

(define (lint-string-has-suffix? [text : String] [suffix : String]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [suffix-len : i64 (string.string-length suffix)]
    (if (< text-len suffix-len)
      false
      (lint-string-has-suffix-at?
        text
        suffix
        (- text-len suffix-len)
        0
        suffix-len))))

(define (lint-stdlib-string-module-name? [module-name : String]) : bool
  (or
    (string.eq module-name "stdlib.string")
    (string.eq module-name "stdlib/string")
    (string.eq module-name "stdlib/string.tl")
    (string.eq module-name "string")
    (string.eq module-name "string.tl")
    (lint-string-has-suffix?
      (owned_view.compiler-owned-shared-view module-name)
      "/stdlib/string.tl")
    (lint-string-has-suffix?
      (owned_view.compiler-owned-shared-view module-name)
      "\\stdlib\\string.tl")
    (lint-string-has-suffix?
      (owned_view.compiler-owned-shared-view module-name)
      "\\stdlib/string.tl")
    (lint-string-has-suffix? module-name "/stdlib\\string.tl")))

(define (lint-unused-import-finding
  [module-name : String]
  [alias : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "unused import: module alias "
      alias
      " from "
      module-name
      " is never referenced")
    (lint-rule-unused-import-id)
    0
    span))

(define (lint-redundant-import-alias-finding [span : ast.AstSourceSpan]) : LintFinding
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

(define (lint-source-span-end-index
  [source : String]
  [span : ast.AstSourceSpan]) : i64
  (let
    [idx : i64
      (lint-source-span-start-index
        (owned_view.compiler-owned-shared-view source)
        (ast.ast-source-span
          (ast.ast-source-span-end-line span)
          (ast.ast-source-span-end-col span)
          (ast.ast-source-span-end-line span)
          (ast.ast-source-span-end-col span)))]
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
  [span : ast.AstSourceSpan]) : bool
  (let
    [start : i64
      (lint-source-span-start-index
        (owned_view.compiler-owned-shared-view source)
        span)]
    [limit : i64
      (lint-source-span-end-index
        (owned_view.compiler-owned-shared-view source)
        span)]
    (if (< start 0)
      false
      (or
        (lint-source-name-in-range?
          (owned_view.compiler-owned-shared-view source)
          "as"
          start
          limit)
        (lint-source-name-in-range? source ":as" start limit)))))

(define (lint-redundant-import-alias-add-if-needed
  [source : String]
  [spec : ast.AstImportSpec]
  [acc : LintFindings]) : LintFindings
  (match spec
    [(ast.AstImportSpec.Spec kind _ expected maybe-alias span)
      (match kind
        [(ast.AstImportKind.Module)
          (match expected
            [(ast.AstMaybeModuleName.No) acc]
            [(ast.AstMaybeModuleName.Some module-name)
              (let
                [module-name : String (ci.intern-str module-name)]
                (match maybe-alias
                  [(ast.AstMaybeImportAlias.No) acc]
                  [(ast.AstMaybeImportAlias.Some alias)
                    (if (and
                      (string.eq
                        (ci.intern-str alias)
                        (lint-module-default-alias module-name))
                      (lint-import-span-has-explicit-alias?
                        source
                        (__tl-box-place span)))
                      (lint-findings-add
                        (lint-redundant-import-alias-finding
                          (__tl-box-place span))
                        acc)
                      acc)]))])]
        [_ acc])]))

(define (lint-unused-import-add-if-needed
  [source : String]
  [all-decls : ast.AstDeclList]
  [current-module-id : i64]
  [spec : ast.AstImportSpec]
  [acc : LintFindings]) : LintFindings
  (let
    [acc : LintFindings
      (lint-redundant-import-alias-add-if-needed
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view spec)
        acc)]
    (match spec
      [(ast.AstImportSpec.Spec kind _ expected maybe-alias span)
        (if (not (lint-import-kind-lintable? kind expected))
          acc
          (match expected
            [(ast.AstMaybeModuleName.No) acc]
            [(ast.AstMaybeModuleName.Some module-name)
              (match maybe-alias
                [(ast.AstMaybeImportAlias.No) acc]
                [(ast.AstMaybeImportAlias.Some alias)
                  (if (lint-underscore-prefixed? (ci.intern-str alias))
                    acc
                    (if (or
                      (lint-decl-list-uses-import?
                        (owned_view.compiler-owned-shared-view all-decls)
                        (ci.intern-str alias)
                        (ci.intern-str module-name))
                      (and
                        (lint-stdlib-string-module-name?
                          (ci.intern-str module-name))
                        (lint-decl-list-has-stdlib-string-bare-use?
                          (owned_view.compiler-owned-shared-view all-decls)
                          current-module-id)))
                      acc
                      (lint-findings-add
                        (lint-unused-import-finding
                          (ci.intern-str module-name)
                          (ci.intern-str alias)
                          (__tl-box-place span))
                        acc)))])]))])))

(define (lint-unused-imports-in-decl-list
  [source : String]
  [all-decls : ast.AstDeclList]
  [decls : ast.AstDeclList]
  [acc : LintFindings]) : LintFindings
  (lint-unused-imports-in-decl-list-at
    source
    all-decls
    decls
    cbi.compiler-builtin-id-fix-empty
    acc))

(define (lint-unused-imports-in-decl-list-at
  [source : String]
  [all-decls : ast.AstDeclList]
  [decls : ast.AstDeclList]
  [current-module-id : i64]
  [acc : LintFindings]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) acc]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (lint-unused-imports-in-decl-list-at
          (owned_view.compiler-owned-shared-view source)
          (owned_view.compiler-owned-shared-view all-decls)
          rest
          (match (owned_view.compiler-owned-shared-view decl)
            [(ast.AstDecl.Module module-id) module-id]
            [_ current-module-id])
          (match decl
            [(ast.AstDecl.Import decl-meta spec)
              (lint-unused-import-add-if-needed
                source
                all-decls
                current-module-id
                spec
                acc)]
            [_ acc])))]))

;; Ordered name set with amortized append. `len` is also a snapshot boundary:
;; older scopes ignore later values written into shared spare capacity, while
;; growth copies the live prefix and keeps those older snapshots valid.
(defstruct LintNameSet
  (slots (__tl_dyn-array String))
  (len i64))

(defstruct LintPendingAssignment
  (name String)
  (span ast.AstSourceSpan))

;; Name-keyed set of pending writes. Entries are unique by name, so scans and
;; removals are order-independent and every update copies into a right-sized
;; array: the walker keeps older `pending` values alive across branches.
(defstruct LintPendingAssignmentList
  (slots (__tl_dyn-array LintPendingAssignment))
  (len i64))

(defenum LintMaybePendingAssignment
  (No)
  (Some LintPendingAssignment))

(defstruct LintUnusedAssignmentState
  (locals LintNameSet)
  (pending LintPendingAssignmentList)
  (findings LintFindings))

(define (lint-name-set-empty) : LintNameSet
  (LintNameSet (__tl_make-array String 0) 0))

(define (lint-name-set-contains-from?
  [items : LintNameSet]
  [name : String]
  [index : i64]) : bool
  (if (>= index items.len)
    false
    (if (string.eq (array-ref items.slots index) name)
      true
      (lint-name-set-contains-from? items name (+ index 1)))))

(define (lint-name-set-contains? [items : LintNameSet] [name : String]) : bool
  (lint-name-set-contains-from? items name 0))

(define (lint-name-set-add [items : LintNameSet] [name : String]) : LintNameSet
  (if (lint-name-set-contains?
    (owned_view.compiler-owned-shared-view items)
    (owned_view.compiler-owned-shared-view name))
    items
    (let
      [n : i64 items.len]
      [slots : (__tl_dyn-array String) items.slots]
      (begin
        (if (< n (array-length slots))
          unit
          (let
            [bigger : (__tl_dyn-array String)
              (__tl_make-array
                String
                (lint-grown-capacity (array-length slots)))]
            [index : i64 0]
            (begin
              (while (< index n)
                (begin
                  (set! (array-ref bigger index) (array-ref slots index))
                  (set! index (+ index 1))))
              (set! slots bigger))))
        (set! (array-ref slots n) name)
        (LintNameSet slots (+ n 1))))))

(define (lint-name-set-count [items : LintNameSet]) : i64
  items.len)

(define (lint-name-set-get [items : LintNameSet] [index : i64]) : String
  (array-ref items.slots index))

(define (lint-param-list-add-locals
  [params : ast.AstParamList]
  [locals : LintNameSet]) : LintNameSet
  (lint-param-list-add-locals-at (& params) locals 0))

(define (lint-param-list-add-locals-at
  [params : (& params ast.AstParamList)]
  [locals : LintNameSet]
  [index : i64]) : LintNameSet
  (if (>= index (ast.ast-param-list-len params))
    locals
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param name _ _)
        (lint-param-list-add-locals-at
          params
          (lint-name-set-add locals (ci.intern-str name))
          (+ index 1))])))

(define (lint-macro-param-list-add-locals
  [params : ast.AstMacroParamList]
  [locals : LintNameSet]) : LintNameSet
  (lint-macro-param-list-add-locals-at (& params) locals 0))

(define (lint-macro-param-list-add-locals-at
  [params : (& params ast.AstMacroParamList)]
  [locals : LintNameSet]
  [index : i64]) : LintNameSet
  (if (>= index (ast.ast-macro-param-list-len params))
    locals
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(ast.AstMacroParam.Param name _ _ _)
        (lint-macro-param-list-add-locals-at
          params
          (lint-name-set-add locals (ci.intern-str name))
          (+ index 1))])))

;; Scope-aware syntax classification shared by unused `(unsafe ...)` blocks and
;; the narrow stdlib.string bare-helper import exception. `requires` belongs to
;; the nearest enclosing unsafe block; nested unsafe expressions do not
;; propagate it. `candidate` records a block that still needs the typed
;; fallback. `stdlib-string-bare-use` records only an unshadowed catalogued call
;; head, never an ordinary bare variable. Keeping the facts in one walk avoids
;; a second binding-aware AST traversal.
(defstruct LintUnsafeScan
  (requires bool)
  (candidate bool)
  (stdlib-string-bare-use bool))

(defstruct LintUnsafeScope
  (shadowed LintNameSet)
  (ambiguous bool))

(define (lint-unsafe-scan-empty) : LintUnsafeScan
  (LintUnsafeScan false false false))

(define (lint-unsafe-scan-combine
  [left : LintUnsafeScan]
  [right : LintUnsafeScan]) : LintUnsafeScan
  (LintUnsafeScan
    (or left.requires right.requires)
    (or left.candidate right.candidate)
    (or left.stdlib-string-bare-use right.stdlib-string-bare-use)))

(define (lint-unsafe-scan-require [children : LintUnsafeScan]) : LintUnsafeScan
  (LintUnsafeScan true children.candidate children.stdlib-string-bare-use))

(define (lint-unsafe-scan-note-stdlib-string-bare-use
  [children : LintUnsafeScan]) : LintUnsafeScan
  (LintUnsafeScan children.requires children.candidate true))

(define (lint-unsafe-scope-add-id [scope : LintUnsafeScope] [name-id : i64]) : LintUnsafeScope
  (LintUnsafeScope
    (lint-name-set-add scope.shadowed (ci.intern-str name-id))
    scope.ambiguous))

(define (lint-unsafe-scope-with-ambiguous [scope : LintUnsafeScope]) : LintUnsafeScope
  (LintUnsafeScope scope.shadowed true))

(define (lint-unsafe-scope-add-params
  [scope : LintUnsafeScope]
  [params : ast.AstParamList]) : LintUnsafeScope
  (LintUnsafeScope
    (lint-param-list-add-locals params scope.shadowed)
    scope.ambiguous))

(define (lint-unsafe-scope-add-macro-params
  [scope : LintUnsafeScope]
  [params : ast.AstMacroParamList]) : LintUnsafeScope
  (LintUnsafeScope
    (lint-macro-param-list-add-locals params scope.shadowed)
    scope.ambiguous))

(define (lint-unsafe-pattern-add-bindings
  [pattern : ast.AstPattern]
  [scope : LintUnsafeScope]) : LintUnsafeScope
  (match pattern
    [(ast.AstPattern.Var name _) (lint-unsafe-scope-add-id scope name)]
    [(ast.AstPattern.Tuple items)
      (lint-unsafe-pattern-list-add-bindings
        (owned_view.compiler-owned-box-shared-view items)
        scope
        0)]
    [(ast.AstPattern.Array items)
      (lint-unsafe-pattern-list-add-bindings
        (owned_view.compiler-owned-box-shared-view items)
        scope
        0)]
    [(ast.AstPattern.Wildcard) scope]
    [(ast.AstPattern.Binding name) (lint-unsafe-scope-add-id scope name)]
    [(ast.AstPattern.Variant _ items)
      (lint-unsafe-pattern-list-add-bindings
        (owned_view.compiler-owned-box-shared-view items)
        scope
        0)]
    [(ast.AstPattern.Literal _) scope]))

(define (lint-unsafe-pattern-list-add-bindings
  [patterns : ast.AstPatternList]
  [scope : LintUnsafeScope]
  [index : i64]) : LintUnsafeScope
  (if (>= index patterns.len)
    scope
    (lint-unsafe-pattern-list-add-bindings
      (owned_view.compiler-owned-shared-view patterns)
      (lint-unsafe-pattern-add-bindings
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
        scope)
      (+ index 1))))

(define (lint-unsafe-scope-name-unshadowed?
  [name-id : i64]
  [scope : LintUnsafeScope]) : bool
  (and
    (not scope.ambiguous)
    (not (lint-name-set-contains? scope.shadowed (ci.intern-str name-id)))))

(define (lint-unsafe-call-unshadowed? [name-id : i64] [scope : LintUnsafeScope]) : bool
  (and
    (lint-unsafe-scope-name-unshadowed? name-id scope)
    (cbi.compiler-builtin-typecheck-syntactic-unsafe-call-id? name-id)))

(define (lint-stdlib-string-bare-call-unshadowed?
  [name-id : i64]
  [scope : LintUnsafeScope]) : bool
  (and
    (lint-unsafe-scope-name-unshadowed? name-id scope)
    (cbi.compiler-builtin-typecheck-stdlib-string-bare-helper-id? name-id)))

(define (lint-unsafe-scan-node [node-id : i64] [scope : LintUnsafeScope]) : LintUnsafeScan
  (lint-unsafe-scan-expr (ast.ast-node-get node-id) scope))

(define (lint-unsafe-scan-two-nodes
  [left : i64]
  [right : i64]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (lint-unsafe-scan-combine
    (lint-unsafe-scan-node left (owned_view.compiler-owned-shared-view scope))
    (lint-unsafe-scan-node right scope)))

(define (lint-unsafe-scan-three-nodes
  [first : i64]
  [second : i64]
  [third : i64]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (lint-unsafe-scan-combine
    (lint-unsafe-scan-node first (owned_view.compiler-owned-shared-view scope))
    (lint-unsafe-scan-two-nodes second third scope)))

(define (lint-unsafe-scan-expr-list
  [exprs : ast.AstExprList]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (lint-unsafe-scan-expr-list-at (& exprs) scope 0))

(define (lint-unsafe-scan-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [scope : LintUnsafeScope]
  [index : i64]) : LintUnsafeScan
  (if (>= index exprs.len)
    (lint-unsafe-scan-empty)
    (lint-unsafe-scan-combine
      (lint-unsafe-scan-node
        (ast.ast-expr-list-get exprs index 0)
        (owned_view.compiler-owned-shared-view scope))
      (lint-unsafe-scan-expr-list-at exprs scope (+ index 1)))))

(define (lint-unsafe-scan-let-bindings
  [bindings : ast.AstLetBindingList]
  [body : i64]
  [scope : LintUnsafeScope]
  [index : i64]) : LintUnsafeScan
  (if (>= index (ast.ast-let-binding-list-len (& bindings)))
    (lint-unsafe-scan-node body scope)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name _ init)
        (lint-unsafe-scan-combine
          (lint-unsafe-scan-node
            init
            (owned_view.compiler-owned-shared-view scope))
          (lint-unsafe-scan-let-bindings
            bindings
            body
            (lint-unsafe-scope-add-id scope name)
            (+ index 1)))])))

(define (lint-unsafe-scan-match-arms
  [arms : ast.AstMatchArmList]
  [scope : LintUnsafeScope]
  [index : i64]) : LintUnsafeScan
  (if (>= index arms.len)
    (lint-unsafe-scan-empty)
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm pattern body)
        (lint-unsafe-scan-combine
          (lint-unsafe-scan-node
            body
            (lint-unsafe-pattern-add-bindings
              pattern
              (owned_view.compiler-owned-shared-view scope)))
          (lint-unsafe-scan-match-arms arms scope (+ index 1)))])))

(define (lint-unsafe-scan-resource-bindings
  [bindings : ast.AstResourceBindingList]
  [body : ast.AstExprList]
  [scope : LintUnsafeScope]
  [index : i64]) : LintUnsafeScan
  (if (>= index (ast.ast-resource-binding-list-len (& bindings)))
    (lint-unsafe-scan-expr-list body scope)
    (match (ast.ast-resource-binding-list-get
      bindings
      index
      (ast.ast-resource-binding-fallback))
      [(ast.AstResourceBinding.Binding name init cleanup _)
        (let
          ;; Finish the ancestor scan before retaining a child snapshot. Dense
          ;; name sets may reuse an ancestor's spare slot for a nested scope.
          [init-scan : LintUnsafeScan
            (lint-unsafe-scan-node
              init
              (owned_view.compiler-owned-shared-view scope))]
          [bound : LintUnsafeScope (lint-unsafe-scope-add-id scope name)]
          [cleanup-scan : LintUnsafeScan
            (lint-unsafe-scan-node
              cleanup
              (owned_view.compiler-owned-shared-view bound))]
          [rest-scan : LintUnsafeScan
            (lint-unsafe-scan-resource-bindings bindings body bound (+ index 1))]
          (lint-unsafe-scan-combine
            init-scan
            (lint-unsafe-scan-combine cleanup-scan rest-scan)))])))

(define (lint-unsafe-scan-expr [expr : ast.AstExpr] [scope : LintUnsafeScope]) : LintUnsafeScan
  (match expr
    [(ast.AstExpr.Spanned inner _) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.MacroExpansion inner _ _) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.Literal _) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.Var _) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.Binary _ left right)
      (lint-unsafe-scan-two-nodes left right scope)]
    [(ast.AstExpr.Unary _ inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.Call func args)
      (let
        [children : LintUnsafeScan
          (lint-unsafe-scan-combine
            (lint-unsafe-scan-node
              func
              (owned_view.compiler-owned-shared-view scope))
            (lint-unsafe-scan-expr-list
              args
              (owned_view.compiler-owned-shared-view scope)))]
        (match (ast.ast-expr-unspan (ast.ast-node-get func))
          [(ast.AstExpr.Var name)
            (let
              [with-string-use : LintUnsafeScan
                (if (lint-stdlib-string-bare-call-unshadowed?
                  name
                  (owned_view.compiler-owned-shared-view scope))
                  (lint-unsafe-scan-note-stdlib-string-bare-use children)
                  children)]
              (if (lint-unsafe-call-unshadowed? name scope)
                (lint-unsafe-scan-require with-string-use)
                with-string-use))]
          [_ children]))]
    [(ast.AstExpr.If cond then-branch else-branch)
      (lint-unsafe-scan-three-nodes cond then-branch else-branch scope)]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-unsafe-scan-let-bindings bindings body scope 0)])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda params _ body)
          (lint-unsafe-scan-node
            body
            (lint-unsafe-scope-add-params scope params))])]
    [(ast.AstExpr.Tuple items) (lint-unsafe-scan-expr-list items scope)]
    [(ast.AstExpr.TupleRef tuple _) (lint-unsafe-scan-node tuple scope)]
    [(ast.AstExpr.Array items) (lint-unsafe-scan-expr-list items scope)]
    [(ast.AstExpr.DynArray items) (lint-unsafe-scan-expr-list items scope)]
    [(ast.AstExpr.MakeArray _ len) (lint-unsafe-scan-node len scope)]
    [(ast.AstExpr.ArrayRef array index)
      (lint-unsafe-scan-two-nodes array index scope)]
    [(ast.AstExpr.ArraySet array index value)
      (lint-unsafe-scan-three-nodes array index value scope)]
    [(ast.AstExpr.ArrayTake array live index)
      (lint-unsafe-scan-three-nodes array live index scope)]
    [(ast.AstExpr.FixedArrayTake array index)
      (lint-unsafe-scan-two-nodes array index scope)]
    [(ast.AstExpr.Replace place replacement)
      (lint-unsafe-scan-two-nodes place replacement scope)]
    [(ast.AstExpr.ArrayPush array value)
      (lint-unsafe-scan-two-nodes array value scope)]
    [(ast.AstExpr.StringRef text index)
      (lint-unsafe-scan-two-nodes text index scope)]
    [(ast.AstExpr.While cond body) (lint-unsafe-scan-two-nodes cond body scope)]
    [(ast.AstExpr.ForOwnedState payload)
      (lint-unsafe-scan-two-nodes
        (ast.ast-for-owned-state-source (& payload))
        (ast.ast-for-owned-state-body (& payload))
        scope)]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        [body : i64 (ast.ast-for-owned-step-body (& payload))]
        (if (>= expected-type 0)
          (lint-unsafe-scan-two-nodes expected-type body scope)
          (lint-unsafe-scan-node body scope)))]
    [(ast.AstExpr.Begin items) (lint-unsafe-scan-expr-list items scope)]
    [(ast.AstExpr.Unsafe items)
      (let
        [inside : LintUnsafeScan (lint-unsafe-scan-expr-list items scope)]
        (LintUnsafeScan
          false
          (or (not inside.requires) inside.candidate)
          inside.stdlib-string-bare-use))]
    [(ast.AstExpr.Set _ value) (lint-unsafe-scan-node value scope)]
    [(ast.AstExpr.Ann inner _) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.Cast inner _) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.Borrow _ _ place) (lint-unsafe-scan-node place scope)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (lint-unsafe-scan-combine
            (lint-unsafe-scan-node
              scrutinee
              (owned_view.compiler-owned-shared-view scope))
            (lint-unsafe-scan-match-arms arms scope 0))])]
    [(ast.AstExpr.Foreach foreach-box)
      (match (__tl-box-place foreach-box)
        [(ast.AstForeach.Foreach index _ start end body)
          (lint-unsafe-scan-combine
            (lint-unsafe-scan-two-nodes
              start
              end
              (owned_view.compiler-owned-shared-view scope))
            (lint-unsafe-scan-node body (lint-unsafe-scope-add-id scope index)))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce _ index _ start end init value)
          (lint-unsafe-scan-combine
            (lint-unsafe-scan-three-nodes
              start
              end
              init
              (owned_view.compiler-owned-shared-view scope))
            (lint-unsafe-scan-node value (lint-unsafe-scope-add-id scope index)))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(ast.AstSpmdScan.Scan _ index _ start end prefix _ init value body)
          (let
            ;; Scan each ancestor before retaining descendants that share its
            ;; dense name-set capacity.
            [outer : LintUnsafeScan
              (lint-unsafe-scan-three-nodes
                start
                end
                init
                (owned_view.compiler-owned-shared-view scope))]
            [index-scope : LintUnsafeScope
              (lint-unsafe-scope-add-id scope index)]
            [value-scan : LintUnsafeScan
              (lint-unsafe-scan-node
                value
                (owned_view.compiler-owned-shared-view index-scope))]
            [body-scope : LintUnsafeScope
              (lint-unsafe-scope-add-id index-scope prefix)]
            (lint-unsafe-scan-combine
              outer
              (lint-unsafe-scan-combine
                value-scan
                (lint-unsafe-scan-node body body-scope))))])]
    [(ast.AstExpr.SpmdBroadcast value lane)
      (lint-unsafe-scan-two-nodes value lane scope)]
    [(ast.AstExpr.SpmdShuffle value lane)
      (lint-unsafe-scan-two-nodes value lane scope)]
    [(ast.AstExpr.SpmdProgramIndex) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.SpmdProgramCount) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.StructGet receiver _) (lint-unsafe-scan-node receiver scope)]
    [(ast.AstExpr.StructSet receiver _ value)
      (lint-unsafe-scan-two-nodes receiver value scope)]
    [(ast.AstExpr.WithRegion _ body) (lint-unsafe-scan-expr-list body scope)]
    [(ast.AstExpr.WithEscape scratch body)
      (lint-unsafe-scan-combine
        (lint-unsafe-scan-node
          scratch
          (owned_view.compiler-owned-shared-view scope))
        (lint-unsafe-scan-expr-list body scope))]
    [(ast.AstExpr.WithScratch body) (lint-unsafe-scan-expr-list body scope)]
    [(ast.AstExpr.InArena arena body)
      (lint-unsafe-scan-combine
        (lint-unsafe-scan-node
          arena
          (owned_view.compiler-owned-shared-view scope))
        (lint-unsafe-scan-expr-list body scope))]
    [(ast.AstExpr.WithResource resource-box)
      (match (__tl-box-place resource-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-unsafe-scan-resource-bindings bindings body scope 0)])]
    [(ast.AstExpr.Box inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.BoxGet inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.BoxTake inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.BoxSet inner value)
      (lint-unsafe-scan-two-nodes inner value scope)]
    [(ast.AstExpr.TypeLiteral _) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.Init _) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.Comptime inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.Quote inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.Quasiquote inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.Unquote inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.UnquoteSplicing inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.BracketClause items) (lint-unsafe-scan-expr-list items scope)]
    [(ast.AstExpr.Try inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.Return inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.Break) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.Continue) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.PtrNull _) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.PtrNullCheck inner) (lint-unsafe-scan-node inner scope)]
    [(ast.AstExpr.PtrAddrOf place)
      (lint-unsafe-scan-require (lint-unsafe-scan-node place scope))]
    [(ast.AstExpr.PtrRead ptr)
      (lint-unsafe-scan-require (lint-unsafe-scan-node ptr scope))]
    [(ast.AstExpr.PtrWrite ptr value)
      (lint-unsafe-scan-require (lint-unsafe-scan-two-nodes ptr value scope))]
    [(ast.AstExpr.PtrOffset ptr offset)
      (lint-unsafe-scan-require (lint-unsafe-scan-two-nodes ptr offset scope))]
    [(ast.AstExpr.PtrCast ptr _)
      (lint-unsafe-scan-require (lint-unsafe-scan-node ptr scope))]
    [(ast.AstExpr.PtrToInt ptr)
      (lint-unsafe-scan-require (lint-unsafe-scan-node ptr scope))]
    [(ast.AstExpr.IntToPtr value _)
      (lint-unsafe-scan-require (lint-unsafe-scan-node value scope))]
    [(ast.AstExpr.StringData inner)
      (lint-unsafe-scan-require (lint-unsafe-scan-node inner scope))]
    [(ast.AstExpr.StringFromBytes ptr len)
      (lint-unsafe-scan-require (lint-unsafe-scan-two-nodes ptr len scope))]
    [(ast.AstExpr.ArrayData inner)
      (lint-unsafe-scan-require (lint-unsafe-scan-node inner scope))]
    [(ast.AstExpr.BinaryData _) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.ProgramArgc) (lint-unsafe-scan-empty)]
    [(ast.AstExpr.ProgramArgv)
      (lint-unsafe-scan-require (lint-unsafe-scan-empty))]
    [(ast.AstExpr.ProgramEnvp)
      (lint-unsafe-scan-require (lint-unsafe-scan-empty))]
    [(ast.AstExpr.CpuIdEax leaf subleaf)
      (lint-unsafe-scan-two-nodes leaf subleaf scope)]
    [(ast.AstExpr.CpuIdEbx leaf subleaf)
      (lint-unsafe-scan-two-nodes leaf subleaf scope)]
    [(ast.AstExpr.CpuIdEcx leaf subleaf)
      (lint-unsafe-scan-two-nodes leaf subleaf scope)]
    [(ast.AstExpr.CpuIdEdx leaf subleaf)
      (lint-unsafe-scan-two-nodes leaf subleaf scope)]
    [(ast.AstExpr.Xgetbv index) (lint-unsafe-scan-node index scope)]
    [(ast.AstExpr.Syscall args)
      (lint-unsafe-scan-require (lint-unsafe-scan-expr-list args scope))]))

(define (lint-unsafe-decl-add-global [decl : ast.AstDecl] [names : LintNameSet]) : LintNameSet
  (match (owned_view.compiler-owned-shared-view decl)
    [(ast.AstDecl.Module name) (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.ModuleBody name _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.Def _ name _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.DefFn _ name _ _ _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.DefMacro _ name _ _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.Extern _ name _ _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.DefEnum _ name _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.DefEnumLifetimes _ name _ _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.DefStruct _ name _ _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.DefStructLifetimes _ name _ _ _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.Import _ _) names]
    [(ast.AstDecl.IncludeStr name _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.IncludeStrComptime name _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.IncludeStrLzss name _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.IncludeBin name _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.DefDispatch _ name _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.Test name _ _) (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.Unsafe inner)
      (lint-unsafe-decl-add-global
        (owned_view.compiler-owned-box-shared-view inner)
        names)]))

(define (lint-unsafe-decl-list-globals
  [decls : ast.AstDeclList]
  [names : LintNameSet]) : LintNameSet
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) names]
    [(ast.AstDeclListStep.Cons decl rest)
      (lint-unsafe-decl-list-globals
        rest
        (lint-unsafe-decl-add-global decl names))]))

(define (lint-unsafe-import-ambiguous? [_ : ast.AstImportSpec]) : bool
  false)

(define (lint-unsafe-decl-list-ambiguous? [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (if (match decl
        [(ast.AstDecl.Import _ spec) (lint-unsafe-import-ambiguous? spec)]
        [(ast.AstDecl.Unsafe inner)
          (match (__tl-box-place inner)
            [(ast.AstDecl.Import _ spec) (lint-unsafe-import-ambiguous? spec)]
            [_ false])]
        [_ false])
        true
        (lint-unsafe-decl-list-ambiguous? rest))]))

(define (lint-unsafe-decl-generated? [decl : ast.AstDecl]) : bool
  (match (ast.ast-decl-generated-meta decl)
    [(ast.AstGeneratedDeclMeta.No) false]
    [(ast.AstGeneratedDeclMeta.Some _ _ _ _) true]))

(define (lint-unsafe-scan-decl [decl : ast.AstDecl] [scope : LintUnsafeScope]) : LintUnsafeScan
  (let
    [body-scope : LintUnsafeScope
      (if (lint-unsafe-decl-generated?
        (owned_view.compiler-owned-shared-view decl))
        (lint-unsafe-scope-with-ambiguous
          (owned_view.compiler-owned-shared-view scope))
        scope)]
    (match decl
      [(ast.AstDecl.Module _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.ModuleBody _ body)
        (lint-unsafe-scan-decl-list
          (owned_view.compiler-owned-box-shared-view body))]
      [(ast.AstDecl.Def _ _ _ body) (lint-unsafe-scan-node body body-scope)]
      [(ast.AstDecl.DefFn _ _ params _ body _)
        (lint-unsafe-scan-node
          body
          (lint-unsafe-scope-add-params body-scope params))]
      [(ast.AstDecl.DefMacro _ _ params _ body)
        (lint-unsafe-scan-node
          body
          (lint-unsafe-scope-add-macro-params body-scope params))]
      [(ast.AstDecl.Extern _ _ _ _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.DefEnum _ _ _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.DefEnumLifetimes _ _ _ _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.DefStruct _ _ _ _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.DefStructLifetimes _ _ _ _ _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.Import
          _
          (ast.AstImportSpec.Spec (ast.AstImportKind.Macro call _) _ _ _ _))
        (lint-unsafe-scan-node call body-scope)]
      [(ast.AstDecl.Import
          _
          (ast.AstImportSpec.Spec (ast.AstImportKind.MacroDecls call _) _ _ _ _))
        (lint-unsafe-scan-node call body-scope)]
      [(ast.AstDecl.Import _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.IncludeStr _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.IncludeStrComptime _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.IncludeStrLzss _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.IncludeBin _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.DefDispatch _ _ _) (lint-unsafe-scan-empty)]
      [(ast.AstDecl.Test _ body _) (lint-unsafe-scan-node body body-scope)]
      [(ast.AstDecl.Unsafe inner)
        (lint-unsafe-scan-decl
          (owned_view.compiler-owned-box-shared-view inner)
          scope)])))

(define (lint-unsafe-scan-decls-with-scope
  [decls : ast.AstDeclList]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) (lint-unsafe-scan-empty)]
    [(ast.AstDeclListStep.Cons decl rest)
      (lint-unsafe-scan-combine
        (lint-unsafe-scan-decl
          decl
          (owned_view.compiler-owned-shared-view scope))
        (lint-unsafe-scan-decls-with-scope rest scope))]))

(define (lint-unsafe-scan-decl-list [decls : ast.AstDeclList]) : LintUnsafeScan
  (let
    [scope : LintUnsafeScope
      (LintUnsafeScope
        (lint-unsafe-decl-list-globals
          (owned_view.compiler-owned-shared-view decls)
          (lint-name-set-empty))
        (lint-unsafe-decl-list-ambiguous?
          (owned_view.compiler-owned-shared-view decls)))]
    (lint-unsafe-scan-decls-with-scope decls scope)))

(define (lint-unsafe-program-has-candidate? [program : ast.AstProgram]) : bool
  (match program
    [(ast.AstProgram.Program decls)
      (__tl-project-field
        (lint-unsafe-scan-decl-list
          (owned_view.compiler-owned-box-shared-view decls))
        candidate)]))

(define (lint-stdlib-string-decl-list-globals-at
  [decls : ast.AstDeclList]
  [target-module-id : i64]
  [current-module-id : i64]
  [names : LintNameSet]) : LintNameSet
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) names]
    [(ast.AstDeclListStep.Cons decl rest)
      (match (owned_view.compiler-owned-shared-view decl)
        [(ast.AstDecl.Module module-id)
          (lint-stdlib-string-decl-list-globals-at
            rest
            target-module-id
            module-id
            names)]
        [_
          (lint-stdlib-string-decl-list-globals-at
            rest
            target-module-id
            current-module-id
            (if (= current-module-id target-module-id)
              (lint-unsafe-decl-add-global decl names)
              names))])]))

(define (lint-stdlib-string-scan-decls-at
  [decls : ast.AstDeclList]
  [target-module-id : i64]
  [current-module-id : i64]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) (lint-unsafe-scan-empty)]
    [(ast.AstDeclListStep.Cons decl rest)
      (match (owned_view.compiler-owned-shared-view decl)
        [(ast.AstDecl.Module module-id)
          (lint-stdlib-string-scan-decls-at
            rest
            target-module-id
            module-id
            scope)]
        [_
          (lint-unsafe-scan-combine
            (if (= current-module-id target-module-id)
              (lint-unsafe-scan-decl
                decl
                (owned_view.compiler-owned-shared-view scope))
              (lint-unsafe-scan-empty))
            (lint-stdlib-string-scan-decls-at
              rest
              target-module-id
              current-module-id
              scope))])]))

(define (lint-decl-list-has-stdlib-string-bare-use?
  [decls : ast.AstDeclList]
  [target-module-id : i64]) : bool
  (let
    [scope : LintUnsafeScope
      (LintUnsafeScope
        (lint-stdlib-string-decl-list-globals-at
          (owned_view.compiler-owned-shared-view decls)
          target-module-id
          cbi.compiler-builtin-id-fix-empty
          (lint-name-set-empty))
        false)]
    (__tl-project-field
      (lint-stdlib-string-scan-decls-at
        decls
        target-module-id
        cbi.compiler-builtin-id-fix-empty
        scope)
      stdlib-string-bare-use)))

(defstruct LintCopyOnUpdateStructShape
  (name String)
  (fields LintNameSet)
  (field-count i64))

;; Program-wide struct shapes: collected once in declaration order through a
;; single owner, so the append reuses spare capacity. Lookups scan from the
;; newest entry to keep the shadowing order of the old prepend-built list.
(defstruct LintCopyOnUpdateStructList
  (slots (__tl_dyn-array LintCopyOnUpdateStructShape))
  (len i64))

(defenum LintCopyOnUpdateMaybeStruct
  (NoStruct)
  (SomeStruct LintCopyOnUpdateStructShape))

(defstruct LintCopyOnUpdateLocal
  (name String)
  (type-name String))

;; Name-keyed local types. Entries are unique by name and outer scopes keep
;; their shorter value live across the body walk, so updates copy into a
;; right-sized array instead of sharing a builder.
(defstruct LintCopyOnUpdateLocalList
  (slots (__tl_dyn-array LintCopyOnUpdateLocal))
  (len i64))

(defstruct LintCopyOnUpdateArgCheck
  (valid bool)
  (copied i64)
  (changed i64)
  (changed-field String))

(defstruct LintCopyOnUpdateState
  (shapes LintCopyOnUpdateStructList)
  (locals LintCopyOnUpdateLocalList)
  (findings LintFindings))

(define (lint-copy-on-update-structs-empty) : LintCopyOnUpdateStructList
  (LintCopyOnUpdateStructList (__tl_make-array LintCopyOnUpdateStructShape 0) 0))

(define (lint-copy-on-update-struct-find-at
  [shapes : LintCopyOnUpdateStructList]
  [name : String]
  [index : i64]) : LintCopyOnUpdateMaybeStruct
  (if (< index 0)
    LintCopyOnUpdateMaybeStruct.NoStruct
    (let
      [shape : LintCopyOnUpdateStructShape
        (owned_view.compiler-owned-array-element-shared-view shapes.slots index)]
      (if (string.eq shape.name name)
        (LintCopyOnUpdateMaybeStruct.SomeStruct shape)
        (lint-copy-on-update-struct-find-at shapes name (- index 1))))))

(define (lint-copy-on-update-struct-find
  [shapes : LintCopyOnUpdateStructList]
  [name : String]) : LintCopyOnUpdateMaybeStruct
  (lint-copy-on-update-struct-find-at
    (owned_view.compiler-owned-shared-view shapes)
    name
    (- shapes.len 1)))

(define (lint-copy-on-update-struct-known-name
  [shapes : LintCopyOnUpdateStructList]
  [name-id : i64]) : String
  (let
    [name : String (ci.intern-str name-id)]
    (match (lint-copy-on-update-struct-find
      shapes
      (owned_view.compiler-owned-shared-view name))
      [(LintCopyOnUpdateMaybeStruct.NoStruct) ""]
      [(LintCopyOnUpdateMaybeStruct.SomeStruct _) name])))

(define (lint-copy-on-update-struct-name-from-type
  [shapes : LintCopyOnUpdateStructList]
  [ty : ast.AstType]) : String
  (match ty
    [(ast.AstType.Struct name)
      (lint-copy-on-update-struct-known-name shapes name)]
    [(ast.AstType.StructArgs name _)
      (lint-copy-on-update-struct-known-name shapes name)]
    [(ast.AstType.Var name) (lint-copy-on-update-struct-known-name shapes name)]
    [(ast.AstType.VarArgs name _)
      (lint-copy-on-update-struct-known-name shapes name)]
    [_ ""]))

(define (lint-copy-on-update-struct-name-from-maybe-type
  [shapes : LintCopyOnUpdateStructList]
  [maybe-ty : ast.AstMaybeType]) : String
  (match maybe-ty
    [(ast.AstMaybeType.No) ""]
    [(ast.AstMaybeType.Some ty)
      (lint-copy-on-update-struct-name-from-type shapes ty)]))

(define (lint-copy-on-update-locals-empty) : LintCopyOnUpdateLocalList
  (LintCopyOnUpdateLocalList (__tl_make-array LintCopyOnUpdateLocal 0) 0))

(define (lint-copy-on-update-local-index
  [locals : LintCopyOnUpdateLocalList]
  [name : String]
  [index : i64]) : i64
  (if (>= index locals.len)
    (- 0 1)
    (if (string.eq
      (__tl-project-field (array-ref locals.slots index) name)
      name)
      index
      (lint-copy-on-update-local-index locals name (+ index 1)))))

(define (lint-copy-on-update-local-remove
  [locals : LintCopyOnUpdateLocalList]
  [name : String]) : LintCopyOnUpdateLocalList
  (let
    [found : i64
      (lint-copy-on-update-local-index
        (owned_view.compiler-owned-shared-view locals)
        name
        0)]
    (if (< found 0)
      locals
      (let
        [n : i64 (- locals.len 1)]
        [slots : (__tl_dyn-array LintCopyOnUpdateLocal)
          (__tl_make-array LintCopyOnUpdateLocal n)]
        [index : i64 0]
        (begin
          (while (< index n)
            (begin
              (set!
                (array-ref slots index)
                (array-ref
                  locals.slots
                  (if (< index found)
                    index
                    (+ index 1))))
              (set! index (+ index 1))))
          (LintCopyOnUpdateLocalList slots n))))))

(define (lint-copy-on-update-local-add
  [locals : LintCopyOnUpdateLocalList]
  [name : String]
  [type-name : String]) : LintCopyOnUpdateLocalList
  (let
    [without : LintCopyOnUpdateLocalList
      (lint-copy-on-update-local-remove
        locals
        (owned_view.compiler-owned-shared-view name))]
    (if (string.eq type-name "")
      without
      (let
        [n : i64 without.len]
        [slots : (__tl_dyn-array LintCopyOnUpdateLocal)
          (__tl_make-array LintCopyOnUpdateLocal (+ n 1))]
        [index : i64 0]
        (begin
          (while (< index n)
            (begin
              (set! (array-ref slots index) (array-ref without.slots index))
              (set! index (+ index 1))))
          (set! (array-ref slots n) (LintCopyOnUpdateLocal name type-name))
          (LintCopyOnUpdateLocalList slots (+ n 1)))))))

(define (lint-copy-on-update-local-type
  [locals : LintCopyOnUpdateLocalList]
  [name : String]) : String
  (let
    [found : i64
      (lint-copy-on-update-local-index
        (owned_view.compiler-owned-shared-view locals)
        name
        0)]
    (if (< found 0)
      ""
      (__tl-project-field (array-ref locals.slots found) type-name))))

(define (lint-copy-on-update-param-locals
  [params : ast.AstParamList]
  [shapes : LintCopyOnUpdateStructList]
  [locals : LintCopyOnUpdateLocalList]) : LintCopyOnUpdateLocalList
  (lint-copy-on-update-param-locals-at (& params) shapes locals 0))

(define (lint-copy-on-update-param-locals-at
  [params : (& params ast.AstParamList)]
  [shapes : LintCopyOnUpdateStructList]
  [locals : LintCopyOnUpdateLocalList]
  [index : i64]) : LintCopyOnUpdateLocalList
  (if (>= index (ast.ast-param-list-len params))
    locals
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param name ty _)
        (lint-copy-on-update-param-locals-at
          params
          (owned_view.compiler-owned-shared-view shapes)
          (lint-copy-on-update-local-add
            locals
            (ci.intern-str name)
            (lint-copy-on-update-struct-name-from-type shapes ty))
          (+ index 1))])))

(define (lint-copy-on-update-macro-param-locals
  [params : ast.AstMacroParamList]
  [shapes : LintCopyOnUpdateStructList]
  [locals : LintCopyOnUpdateLocalList]) : LintCopyOnUpdateLocalList
  (lint-copy-on-update-macro-param-locals-at (& params) shapes locals 0))

(define (lint-copy-on-update-macro-param-locals-at
  [params : (& params ast.AstMacroParamList)]
  [shapes : LintCopyOnUpdateStructList]
  [locals : LintCopyOnUpdateLocalList]
  [index : i64]) : LintCopyOnUpdateLocalList
  (if (>= index (ast.ast-macro-param-list-len params))
    locals
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(ast.AstMacroParam.Param name ty _ _)
        (lint-copy-on-update-macro-param-locals-at
          params
          (owned_view.compiler-owned-shared-view shapes)
          (lint-copy-on-update-local-add
            locals
            (ci.intern-str name)
            (lint-copy-on-update-struct-name-from-type shapes ty))
          (+ index 1))])))

(define (lint-copy-on-update-expr-var-name [expr : ast.AstExpr]) : String
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-copy-on-update-expr-var-name (ast.ast-node-get inner))]
    [(ast.AstExpr.Var name) (ci.intern-str name)]
    [_ ""]))

(define (lint-copy-on-update-copied-field?
  [target-name : String]
  [field-name : String]
  [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-copy-on-update-copied-field?
        target-name
        field-name
        (ast.ast-node-get inner))]
    [(ast.AstExpr.StructGet receiver field)
      (and
        (string.eq
          (lint-copy-on-update-expr-var-name (ast.ast-node-get receiver))
          target-name)
        (string.eq (ci.intern-str field) field-name))]
    [(ast.AstExpr.Var name)
      (string.eq
        (ci.intern-str name)
        (str_cat.str-cat target-name "." field-name))]
    [_ false]))

(define (lint-copy-on-update-arg-check-invalid) : LintCopyOnUpdateArgCheck
  (LintCopyOnUpdateArgCheck false 0 0 ""))

(define (lint-copy-on-update-check-args
  [fields : LintNameSet]
  [args : ast.AstExprList]
  [target-name : String]) : LintCopyOnUpdateArgCheck
  (lint-copy-on-update-check-args-at fields (& args) 0 target-name))

(define (lint-copy-on-update-check-args-at
  [fields : LintNameSet]
  [args : (& args ast.AstExprList)]
  [index : i64]
  [target-name : String]) : LintCopyOnUpdateArgCheck
  (if (>=
    index
    (lint-name-set-count (owned_view.compiler-owned-shared-view fields)))
    (if (= index args.len)
      (LintCopyOnUpdateArgCheck true 0 0 "")
      (lint-copy-on-update-arg-check-invalid))
    (if (>= index args.len)
      (lint-copy-on-update-arg-check-invalid)
      (let
        [field : String
          (lint-name-set-get
            (owned_view.compiler-owned-shared-view fields)
            index)]
        [arg : ast.AstExpr
          (ast.ast-node-get (ast.ast-expr-list-get args index 0))]
        [tail : LintCopyOnUpdateArgCheck
          (lint-copy-on-update-check-args-at
            fields
            args
            (+ index 1)
            (owned_view.compiler-owned-shared-view target-name))]
        (if (not tail.valid)
          tail
          (if (lint-copy-on-update-copied-field?
            target-name
            (owned_view.compiler-owned-shared-view field)
            arg)
            (LintCopyOnUpdateArgCheck
              true
              (+ tail.copied 1)
              tail.changed
              tail.changed-field)
            (LintCopyOnUpdateArgCheck
              true
              tail.copied
              (+ tail.changed 1)
              (if (= tail.changed 0)
                field
                tail.changed-field))))))))

(define (lint-copy-on-update-state-with
  [state : LintCopyOnUpdateState]
  [locals : LintCopyOnUpdateLocalList]
  [findings : LintFindings]) : LintCopyOnUpdateState
  (LintCopyOnUpdateState state.shapes locals findings))

(define (lint-copy-on-update-add-finding
  [state : LintCopyOnUpdateState]
  [name : String]
  [field : String]
  [span : ast.AstSourceSpan]) : LintCopyOnUpdateState
  (lint-copy-on-update-state-with
    (owned_view.compiler-owned-shared-view state)
    state.locals
    (lint-findings-add
      (lint-copy-on-update-struct-finding name field span)
      state.findings)))

(define (lint-copy-on-update-add-set-if-needed
  [target : i64]
  [value : ast.AstExpr]
  [span : ast.AstSourceSpan]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (let
    [target-name : String (ci.intern-str target)]
    [type-name : String
      (lint-copy-on-update-local-type
        (owned_view.compiler-owned-shared-view state.locals)
        (owned_view.compiler-owned-shared-view target-name))]
    (if (or
      (string.eq type-name "")
      (lint-underscore-prefixed?
        (owned_view.compiler-owned-shared-view target-name)))
      state
      (match value
        [(ast.AstExpr.Spanned inner _)
          (lint-copy-on-update-add-set-if-needed
            target
            (ast.ast-node-get inner)
            span
            (owned_view.compiler-owned-shared-view state))]
        [(ast.AstExpr.Ann inner _)
          (lint-copy-on-update-add-set-if-needed
            target
            (ast.ast-node-get inner)
            span
            state)]
        [(ast.AstExpr.Cast inner _)
          (lint-copy-on-update-add-set-if-needed
            target
            (ast.ast-node-get inner)
            span
            state)]
        [(ast.AstExpr.Call callee args)
          (let
            [callee-name : String
              (lint-copy-on-update-expr-var-name (ast.ast-node-get callee))]
            (if (not (string.eq callee-name type-name))
              state
              (match (lint-copy-on-update-struct-find
                (owned_view.compiler-owned-shared-view state.shapes)
                type-name)
                [(LintCopyOnUpdateMaybeStruct.NoStruct) state]
                [(LintCopyOnUpdateMaybeStruct.SomeStruct shape)
                  (let
                    [checked : LintCopyOnUpdateArgCheck
                      (lint-copy-on-update-check-args
                        shape.fields
                        args
                        (owned_view.compiler-owned-shared-view target-name))]
                    (if (and
                      checked.valid
                      (= checked.changed 1)
                      (>= checked.copied 1))
                      (lint-copy-on-update-add-finding
                        (owned_view.compiler-owned-shared-view state)
                        target-name
                        checked.changed-field
                        span)
                      state))])))]
        [_ state]))))

(define (lint-copy-on-update-init-type-name
  [state : LintCopyOnUpdateState]
  [expr : ast.AstExpr]) : String
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-copy-on-update-init-type-name state (ast.ast-node-get inner))]
    [(ast.AstExpr.Ann inner ty-id)
      (let
        [annotated : String
          (lint-copy-on-update-struct-name-from-type
            (owned_view.compiler-owned-shared-view state.shapes)
            (ast.ty-node-get ty-id))]
        (if (string.eq annotated "")
          (lint-copy-on-update-init-type-name
            (owned_view.compiler-owned-shared-view state)
            (ast.ast-node-get inner))
          annotated))]
    [(ast.AstExpr.Cast inner ty-id)
      (let
        [casted : String
          (lint-copy-on-update-struct-name-from-type
            (owned_view.compiler-owned-shared-view state.shapes)
            (ast.ty-node-get ty-id))]
        (if (string.eq casted "")
          (lint-copy-on-update-init-type-name
            (owned_view.compiler-owned-shared-view state)
            (ast.ast-node-get inner))
          casted))]
    [(ast.AstExpr.Call callee _)
      (let
        [callee-name : String
          (lint-copy-on-update-expr-var-name (ast.ast-node-get callee))]
        (match (lint-copy-on-update-struct-find
          state.shapes
          (owned_view.compiler-owned-shared-view callee-name))
          [(LintCopyOnUpdateMaybeStruct.NoStruct) ""]
          [(LintCopyOnUpdateMaybeStruct.SomeStruct _) callee-name]))]
    [(ast.AstExpr.Var name)
      (lint-copy-on-update-local-type state.locals (ci.intern-str name))]
    [_ ""]))

(define (lint-copy-on-update-local-type-from-binding
  [state : LintCopyOnUpdateState]
  [maybe-ty : ast.AstMaybeType]
  [init : i64]) : String
  (let
    [annotated : String
      (lint-copy-on-update-struct-name-from-maybe-type
        (owned_view.compiler-owned-shared-view state.shapes)
        maybe-ty)]
    (if (string.eq annotated "")
      (lint-copy-on-update-init-type-name
        (owned_view.compiler-owned-shared-view state)
        (ast.ast-node-get init))
      annotated)))

(define (lint-copy-on-update-expr-list
  [exprs : ast.AstExprList]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (lint-copy-on-update-expr-list-at (& exprs) 0 state))

(define (lint-copy-on-update-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (if (>= index exprs.len)
    state
    (lint-copy-on-update-expr-list-at
      exprs
      (+ index 1)
      (lint-copy-on-update-expr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))
        state
        (lint-no-span)))))

(define (lint-copy-on-update-let-bindings
  [bindings : ast.AstLetBindingList]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (lint-copy-on-update-let-bindings-at (& bindings) state 0))

(define (lint-copy-on-update-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [state : LintCopyOnUpdateState]
  [index : i64]) : LintCopyOnUpdateState
  (if (>= index (ast.ast-let-binding-list-len bindings))
    state
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name maybe-ty init)
        (let
          [after-init : LintCopyOnUpdateState
            (lint-copy-on-update-expr
              (ast.ast-node-get init)
              state
              (lint-no-effect-span (ast.ast-node-get init)))]
          [type-name : String
            (lint-copy-on-update-local-type-from-binding
              (owned_view.compiler-owned-shared-view after-init)
              maybe-ty
              init)]
          [with-local : LintCopyOnUpdateState
            (lint-copy-on-update-state-with
              (owned_view.compiler-owned-shared-view after-init)
              (lint-copy-on-update-local-add
                after-init.locals
                (ci.intern-str name)
                type-name)
              after-init.findings)]
          (lint-copy-on-update-let-bindings-at bindings with-local (+ index 1)))])))

(define (lint-copy-on-update-let
  [bindings : ast.AstLetBindingList]
  [body : ast.AstExpr]
  [state : LintCopyOnUpdateState]
  [span : ast.AstSourceSpan]) : LintCopyOnUpdateState
  (let
    [outer-locals : LintCopyOnUpdateLocalList state.locals]
    [with-bindings : LintCopyOnUpdateState
      (lint-copy-on-update-let-bindings
        bindings
        (owned_view.compiler-owned-shared-view state))]
    [with-body : LintCopyOnUpdateState
      (lint-copy-on-update-expr body with-bindings span)]
    (lint-copy-on-update-state-with
      (owned_view.compiler-owned-shared-view with-body)
      outer-locals
      with-body.findings)))

(define (lint-copy-on-update-match-arms
  [arms : ast.AstMatchArmList]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (lint-copy-on-update-match-arms-at (& arms) state 0))

(define (lint-copy-on-update-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [state : LintCopyOnUpdateState]
  [index : i64]) : LintCopyOnUpdateState
  (if (>= index arms.len)
    state
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm _ body)
        (lint-copy-on-update-match-arms-at
          arms
          (lint-copy-on-update-expr
            (ast.ast-node-get body)
            state
            (lint-no-span))
          (+ index 1))])))

(define (lint-copy-on-update-resource-bindings
  [bindings : ast.AstResourceBindingList]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (lint-copy-on-update-resource-bindings-at (& bindings) state 0))

(define (lint-copy-on-update-resource-bindings-at
  [bindings : (& bindings ast.AstResourceBindingList)]
  [state : LintCopyOnUpdateState]
  [index : i64]) : LintCopyOnUpdateState
  (if (>= index (ast.ast-resource-binding-list-len bindings))
    state
    (match (ast.ast-resource-binding-list-get
      bindings
      index
      (ast.ast-resource-binding-fallback))
      [(ast.AstResourceBinding.Binding _ init cleanup _)
        (lint-copy-on-update-resource-bindings-at
          bindings
          (lint-copy-on-update-expr
            (ast.ast-node-get cleanup)
            (lint-copy-on-update-expr
              (ast.ast-node-get init)
              state
              (lint-no-effect-span (ast.ast-node-get init)))
            (lint-no-effect-span (ast.ast-node-get cleanup)))
          (+ index 1))])))

(define (lint-copy-on-update-expr
  [expr : ast.AstExpr]
  [state : LintCopyOnUpdateState]
  [span : ast.AstSourceSpan]) : LintCopyOnUpdateState
  (match expr
    [(ast.AstExpr.Spanned inner inner-span)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state inner-span)]
    [(ast.AstExpr.Binary _ left right)
      (lint-copy-on-update-expr
        (ast.ast-node-get right)
        (lint-copy-on-update-expr (ast.ast-node-get left) state span)
        span)]
    [(ast.AstExpr.Unary _ inner)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.Call callee args)
      (lint-copy-on-update-expr-list
        args
        (lint-copy-on-update-expr (ast.ast-node-get callee) state span))]
    [(ast.AstExpr.If cond then-branch else-branch)
      (lint-copy-on-update-expr
        (ast.ast-node-get else-branch)
        (lint-copy-on-update-expr
          (ast.ast-node-get then-branch)
          (lint-copy-on-update-expr (ast.ast-node-get cond) state span)
          span)
        span)]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-copy-on-update-let bindings (ast.ast-node-get body) state span)])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda params _ body)
          (let
            [outer-locals : LintCopyOnUpdateLocalList
              (owned_view.compiler-owned-shared-view state.locals)]
            [with-params : LintCopyOnUpdateState
              (lint-copy-on-update-state-with
                (owned_view.compiler-owned-shared-view state)
                (lint-copy-on-update-param-locals
                  params
                  state.shapes
                  (owned_view.compiler-owned-shared-view outer-locals))
                state.findings)]
            [with-body : LintCopyOnUpdateState
              (lint-copy-on-update-expr
                (ast.ast-node-get body)
                with-params
                span)]
            (lint-copy-on-update-state-with
              (owned_view.compiler-owned-shared-view with-body)
              outer-locals
              with-body.findings))])]
    [(ast.AstExpr.Tuple exprs) (lint-copy-on-update-expr-list exprs state)]
    [(ast.AstExpr.TupleRef tuple _)
      (lint-copy-on-update-expr (ast.ast-node-get tuple) state span)]
    [(ast.AstExpr.Array exprs) (lint-copy-on-update-expr-list exprs state)]
    [(ast.AstExpr.DynArray exprs) (lint-copy-on-update-expr-list exprs state)]
    [(ast.AstExpr.MakeArray _ len)
      (lint-copy-on-update-expr (ast.ast-node-get len) state span)]
    [(ast.AstExpr.ArrayRef array index)
      (lint-copy-on-update-expr
        (ast.ast-node-get index)
        (lint-copy-on-update-expr (ast.ast-node-get array) state span)
        span)]
    [(ast.AstExpr.ArraySet array index value)
      (lint-copy-on-update-expr
        (ast.ast-node-get value)
        (lint-copy-on-update-expr
          (ast.ast-node-get index)
          (lint-copy-on-update-expr (ast.ast-node-get array) state span)
          span)
        span)]
    [(ast.AstExpr.ArrayTake array live index)
      (lint-copy-on-update-expr
        (ast.ast-node-get index)
        (lint-copy-on-update-expr
          (ast.ast-node-get live)
          (lint-copy-on-update-expr (ast.ast-node-get array) state span)
          span)
        span)]
    [(ast.AstExpr.FixedArrayTake array index)
      (lint-copy-on-update-expr
        (ast.ast-node-get index)
        (lint-copy-on-update-expr (ast.ast-node-get array) state span)
        span)]
    [(ast.AstExpr.Replace place replacement)
      (lint-copy-on-update-expr
        (ast.ast-node-get replacement)
        (lint-copy-on-update-expr (ast.ast-node-get place) state span)
        span)]
    [(ast.AstExpr.ArrayPush array value)
      (lint-copy-on-update-expr
        (ast.ast-node-get value)
        (lint-copy-on-update-expr (ast.ast-node-get array) state span)
        span)]
    [(ast.AstExpr.StringRef text index)
      (lint-copy-on-update-expr
        (ast.ast-node-get index)
        (lint-copy-on-update-expr (ast.ast-node-get text) state span)
        span)]
    [(ast.AstExpr.While cond body)
      (lint-copy-on-update-expr
        (ast.ast-node-get body)
        (lint-copy-on-update-expr (ast.ast-node-get cond) state span)
        span)]
    [(ast.AstExpr.Begin exprs) (lint-copy-on-update-expr-list exprs state)]
    [(ast.AstExpr.Unsafe exprs) (lint-copy-on-update-expr-list exprs state)]
    [(ast.AstExpr.Set target value)
      (lint-copy-on-update-add-set-if-needed
        target
        (ast.ast-node-get value)
        span
        (lint-copy-on-update-expr (ast.ast-node-get value) state span))]
    [(ast.AstExpr.Ann inner _)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.Cast inner _)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.Borrow _ _ place)
      (lint-copy-on-update-expr (ast.ast-node-get place) state span)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (lint-copy-on-update-match-arms
            arms
            (lint-copy-on-update-expr (ast.ast-node-get scrutinee) state span))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach name ty start end body)
          (let
            [after-range : LintCopyOnUpdateState
              (lint-copy-on-update-expr
                (ast.ast-node-get end)
                (lint-copy-on-update-expr
                  (ast.ast-node-get start)
                  (owned_view.compiler-owned-shared-view state)
                  span)
                span)]
            [outer-locals : LintCopyOnUpdateLocalList
              (owned_view.compiler-owned-shared-view after-range.locals)]
            [with-local : LintCopyOnUpdateState
              (lint-copy-on-update-state-with
                (owned_view.compiler-owned-shared-view after-range)
                (lint-copy-on-update-local-add
                  (owned_view.compiler-owned-shared-view outer-locals)
                  (ci.intern-str name)
                  (lint-copy-on-update-struct-name-from-type state.shapes ty))
                after-range.findings)]
            [with-body : LintCopyOnUpdateState
              (lint-copy-on-update-expr (ast.ast-node-get body) with-local span)]
            (lint-copy-on-update-state-with
              (owned_view.compiler-owned-shared-view with-body)
              (owned_view.compiler-owned-shared-view outer-locals)
              (owned_view.compiler-owned-shared-view with-body.findings)))])]
    [(ast.AstExpr.StructGet receiver _)
      (lint-copy-on-update-expr (ast.ast-node-get receiver) state span)]
    [(ast.AstExpr.StructSet receiver _ value)
      (lint-copy-on-update-expr
        (ast.ast-node-get value)
        (lint-copy-on-update-expr (ast.ast-node-get receiver) state span)
        span)]
    [(ast.AstExpr.WithRegion _ body) (lint-copy-on-update-expr-list body state)]
    [(ast.AstExpr.WithEscape scratch body)
      (lint-copy-on-update-expr-list
        body
        (lint-copy-on-update-expr (ast.ast-node-get scratch) state span))]
    [(ast.AstExpr.WithScratch body) (lint-copy-on-update-expr-list body state)]
    [(ast.AstExpr.InArena arena body)
      (lint-copy-on-update-expr-list
        body
        (lint-copy-on-update-expr (ast.ast-node-get arena) state span))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-copy-on-update-expr-list
            body
            (lint-copy-on-update-resource-bindings bindings state))])]
    [(ast.AstExpr.Box inner)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.BoxGet inner)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.BoxTake inner)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.BoxSet inner value)
      (lint-copy-on-update-expr
        (ast.ast-node-get value)
        (lint-copy-on-update-expr (ast.ast-node-get inner) state span)
        span)]
    [(ast.AstExpr.Comptime inner)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.Quote _) state]
    [(ast.AstExpr.Quasiquote _) state]
    [(ast.AstExpr.Unquote inner)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.UnquoteSplicing inner)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.BracketClause items)
      (lint-copy-on-update-expr-list items state)]
    [(ast.AstExpr.Try inner)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.Return inner)
      (lint-copy-on-update-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.Break) state]
    [(ast.AstExpr.Continue) state]
    [_ state]))

(define (lint-copy-on-update-field-names [fields : ast.AstFieldDefList]) : LintNameSet
  (lint-copy-on-update-field-names-at (& fields) 0 (lint-name-set-empty)))

(define (lint-copy-on-update-field-names-at
  [fields : (& fields ast.AstFieldDefList)]
  [index : i64]
  [names : LintNameSet]) : LintNameSet
  (if (>= index fields.len)
    names
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def name _ _)
        (lint-copy-on-update-field-names-at
          fields
          (+ index 1)
          (lint-name-set-add names (ci.intern-str name)))])))

(define (lint-copy-on-update-add-struct
  [name : i64]
  [fields : ast.AstFieldDefList]
  [shapes : LintCopyOnUpdateStructList]) : LintCopyOnUpdateStructList
  (let
    [names : LintNameSet (lint-copy-on-update-field-names fields)]
    [n : i64 shapes.len]
    [slots : (__tl_dyn-array LintCopyOnUpdateStructShape) shapes.slots]
    (begin
      (if (< n (array-length slots))
        unit
        (let
          [bigger : (__tl_dyn-array LintCopyOnUpdateStructShape)
            (__tl_make-array
              LintCopyOnUpdateStructShape
              (lint-grown-capacity (array-length slots)))]
          [index : i64 0]
          (begin
            (while (< index n)
              (begin
                (set! (array-ref bigger index) (array-ref slots index))
                (set! index (+ index 1))))
            (set! slots bigger))))
      (set!
        (array-ref slots n)
        (LintCopyOnUpdateStructShape
          (ci.intern-str name)
          (owned_view.compiler-owned-shared-view names)
          (lint-name-set-count names)))
      (LintCopyOnUpdateStructList slots (+ n 1)))))

(define (lint-copy-on-update-collect-structs-in-decl
  [decl : ast.AstDecl]
  [shapes : LintCopyOnUpdateStructList]) : LintCopyOnUpdateStructList
  (match decl
    [(ast.AstDecl.DefStruct decl-meta name _ _ fields)
      (lint-copy-on-update-add-struct name fields shapes)]
    [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ _ fields)
      (lint-copy-on-update-add-struct name fields shapes)]
    [(ast.AstDecl.Unsafe inner)
      (lint-copy-on-update-collect-structs-in-decl
        (owned_view.compiler-owned-box-shared-view inner)
        shapes)]
    [_ shapes]))

(define (lint-copy-on-update-collect-structs
  [decls : ast.AstDeclList]
  [shapes : LintCopyOnUpdateStructList]) : LintCopyOnUpdateStructList
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) shapes]
    [(ast.AstDeclListStep.Cons decl rest)
      (lint-copy-on-update-collect-structs
        rest
        (lint-copy-on-update-collect-structs-in-decl decl shapes))]))

(define (lint-copy-on-update-structs-in-decl
  [decl : ast.AstDecl]
  [shapes : LintCopyOnUpdateStructList]
  [acc : LintFindings]) : LintFindings
  (match (owned_view.compiler-owned-shared-view decl)
    [(ast.AstDecl.Def decl-meta _ _ body)
      (__tl-project-field
        (lint-copy-on-update-expr
          (ast.ast-node-get body)
          (LintCopyOnUpdateState
            (owned_view.compiler-owned-shared-view shapes)
            (lint-copy-on-update-locals-empty)
            acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.DefFn decl-meta _ params _ body _)
      (__tl-project-field
        (lint-copy-on-update-expr
          (ast.ast-node-get body)
          (LintCopyOnUpdateState
            (owned_view.compiler-owned-shared-view shapes)
            (lint-copy-on-update-param-locals
              params
              (owned_view.compiler-owned-shared-view shapes)
              (lint-copy-on-update-locals-empty))
            acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.DefMacro decl-meta _ params _ body)
      (__tl-project-field
        (lint-copy-on-update-expr
          (ast.ast-node-get body)
          (LintCopyOnUpdateState
            (owned_view.compiler-owned-shared-view shapes)
            (lint-copy-on-update-macro-param-locals
              params
              (owned_view.compiler-owned-shared-view shapes)
              (lint-copy-on-update-locals-empty))
            acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.Test _ body _)
      (__tl-project-field
        (lint-copy-on-update-expr
          (ast.ast-node-get body)
          (LintCopyOnUpdateState
            (owned_view.compiler-owned-shared-view shapes)
            (lint-copy-on-update-locals-empty)
            acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.Unsafe inner)
      (lint-copy-on-update-structs-in-decl
        (ast.ast-decl-box-shared-view inner)
        (owned_view.compiler-owned-shared-view shapes)
        acc)]
    [_ acc]))

(define (lint-copy-on-update-structs-in-decl-list
  [decls : ast.AstDeclList]
  [shapes : LintCopyOnUpdateStructList]
  [acc : LintFindings]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) acc]
    [(ast.AstDeclListStep.Cons decl rest)
      (lint-copy-on-update-structs-in-decl-list
        rest
        (owned_view.compiler-owned-shared-view shapes)
        (lint-copy-on-update-structs-in-decl
          decl
          (owned_view.compiler-owned-shared-view shapes)
          acc))]))

(defstruct LintSingleElementArrayCandidate
  (name String)
  (span ast.AstSourceSpan)
  (valid bool)
  (used bool))

;; Tracked cells in reverse discovery order: the newest candidate is the last
;; slot, so `slots[len - 1]` is the old list head and every walk that consumed
;; the cons list head-first now counts down. Entries are unique by name and
;; updates copy into a right-sized array so branches never share a slot.
(defstruct LintSingleElementArrayCandidateList
  (slots (__tl_dyn-array LintSingleElementArrayCandidate))
  (len i64))

(defstruct LintSingleElementArrayState
  (candidates LintSingleElementArrayCandidateList)
  (findings LintFindings))

(define (lint-single-element-array-state-with-candidates
  [state : LintSingleElementArrayState]
  [candidates : LintSingleElementArrayCandidateList]) : LintSingleElementArrayState
  (LintSingleElementArrayState candidates state.findings))

(define (lint-single-element-array-state-with-findings
  [state : LintSingleElementArrayState]
  [findings : LintFindings]) : LintSingleElementArrayState
  (LintSingleElementArrayState state.candidates findings))

(define (lint-single-element-array-candidates-empty) : LintSingleElementArrayCandidateList
  (LintSingleElementArrayCandidateList
    (__tl_make-array LintSingleElementArrayCandidate 0)
    0))

(define (lint-single-element-array-candidate-index
  [items : LintSingleElementArrayCandidateList]
  [name : String]
  [index : i64]) : i64
  (if (>= index items.len)
    (- 0 1)
    (if (string.eq (__tl-project-field (array-ref items.slots index) name) name)
      index
      (lint-single-element-array-candidate-index items name (+ index 1)))))

(define (lint-single-element-array-candidate-tracked?
  [items : LintSingleElementArrayCandidateList]
  [name : String]) : bool
  (>= (lint-single-element-array-candidate-index items name 0) 0))

(define (lint-single-element-array-candidate-remove
  [items : LintSingleElementArrayCandidateList]
  [name : String]) : LintSingleElementArrayCandidateList
  (let
    [found : i64
      (lint-single-element-array-candidate-index
        (owned_view.compiler-owned-shared-view items)
        name
        0)]
    (if (< found 0)
      items
      (let
        [n : i64 (- items.len 1)]
        [slots : (__tl_dyn-array LintSingleElementArrayCandidate)
          (__tl_make-array LintSingleElementArrayCandidate n)]
        [index : i64 0]
        (begin
          (while (< index n)
            (begin
              (set!
                (array-ref slots index)
                (array-ref
                  items.slots
                  (if (< index found)
                    index
                    (+ index 1))))
              (set! index (+ index 1))))
          (LintSingleElementArrayCandidateList slots n))))))

(define (lint-single-element-array-candidate-add
  [items : LintSingleElementArrayCandidateList]
  [name : String]
  [span : ast.AstSourceSpan]) : LintSingleElementArrayCandidateList
  (let
    [without : LintSingleElementArrayCandidateList
      (lint-single-element-array-candidate-remove
        items
        (owned_view.compiler-owned-shared-view name))]
    [n : i64 without.len]
    [slots : (__tl_dyn-array LintSingleElementArrayCandidate)
      (__tl_make-array LintSingleElementArrayCandidate (+ n 1))]
    [index : i64 0]
    (begin
      (while (< index n)
        (begin
          (set! (array-ref slots index) (array-ref without.slots index))
          (set! index (+ index 1))))
      (set!
        (array-ref slots n)
        (LintSingleElementArrayCandidate name span true false))
      (LintSingleElementArrayCandidateList slots (+ n 1)))))

(define (lint-single-element-array-candidate-replace
  [items : LintSingleElementArrayCandidateList]
  [found : i64]
  [item : LintSingleElementArrayCandidate]) : LintSingleElementArrayCandidateList
  (let
    [n : i64 items.len]
    [slots : (__tl_dyn-array LintSingleElementArrayCandidate)
      (__tl_make-array LintSingleElementArrayCandidate n)]
    [index : i64 0]
    (begin
      (while (< index n)
        (begin
          (set! (array-ref slots index) (array-ref items.slots index))
          (set! index (+ index 1))))
      (set! (array-ref slots found) item)
      (LintSingleElementArrayCandidateList slots n))))

(define (lint-single-element-array-candidate-mark-use
  [items : LintSingleElementArrayCandidateList]
  [name : String]) : LintSingleElementArrayCandidateList
  (let
    [found : i64
      (lint-single-element-array-candidate-index
        (owned_view.compiler-owned-shared-view items)
        name
        0)]
    (if (< found 0)
      items
      (let
        [item : LintSingleElementArrayCandidate
          (owned_view.compiler-owned-array-element-shared-view
            items.slots
            found)]
        (lint-single-element-array-candidate-replace
          items
          found
          (LintSingleElementArrayCandidate item.name item.span item.valid true))))))

(define (lint-single-element-array-candidate-invalidate
  [items : LintSingleElementArrayCandidateList]
  [name : String]) : LintSingleElementArrayCandidateList
  (let
    [found : i64
      (lint-single-element-array-candidate-index
        (owned_view.compiler-owned-shared-view items)
        name
        0)]
    (if (< found 0)
      items
      (let
        [item : LintSingleElementArrayCandidate
          (owned_view.compiler-owned-array-element-shared-view
            items.slots
            found)]
        (lint-single-element-array-candidate-replace
          items
          found
          (LintSingleElementArrayCandidate item.name item.span false item.used))))))

(define (lint-single-element-array-note-use
  [state : LintSingleElementArrayState]
  [name : String]) : LintSingleElementArrayState
  (lint-single-element-array-state-with-candidates
    (owned_view.compiler-owned-shared-view state)
    (lint-single-element-array-candidate-mark-use state.candidates name)))

(define (lint-single-element-array-note-escape
  [state : LintSingleElementArrayState]
  [name : String]) : LintSingleElementArrayState
  (lint-single-element-array-state-with-candidates
    (owned_view.compiler-owned-shared-view state)
    (lint-single-element-array-candidate-invalidate state.candidates name)))

(define (lint-single-element-array-note-var
  [state : LintSingleElementArrayState]
  [name : String]) : LintSingleElementArrayState
  (if (lint-single-element-array-candidate-tracked?
    (owned_view.compiler-owned-shared-view state.candidates)
    (owned_view.compiler-owned-shared-view name))
    (lint-single-element-array-note-escape
      (owned_view.compiler-owned-shared-view state)
      name)
    state))

(define (lint-single-element-array-scalar-type? [ty : ast.AstType]) : bool
  (match ty
    [(ast.AstType.I64) true]
    [(ast.AstType.I32) true]
    [(ast.AstType.I16) true]
    [(ast.AstType.I8) true]
    [(ast.AstType.U64) true]
    [(ast.AstType.U32) true]
    [(ast.AstType.U16) true]
    [(ast.AstType.U8) true]
    [(ast.AstType.F64) true]
    [(ast.AstType.F32) true]
    [(ast.AstType.Bool) true]
    [(ast.AstType.Char) true]
    [(ast.AstType.Ptr _) true]
    [(ast.AstType.MutPtr _) true]
    [_ false]))

(define (lint-single-element-array-scalar-type-id? [ty-id : i64]) : bool
  (lint-single-element-array-scalar-type? (ast.ty-node-get ty-id)))

(define (lint-single-element-array-fixed-type? [ty : ast.AstType]) : bool
  (match ty
    [(ast.AstType.Array elem count)
      (and (= count 1) (lint-single-element-array-scalar-type-id? elem))]
    [_ false]))

(define (lint-single-element-array-maybe-fixed-type?
  [maybe-ty : ast.AstMaybeType]) : bool
  (match maybe-ty
    [(ast.AstMaybeType.Some ty) (lint-single-element-array-fixed-type? ty)]
    [(ast.AstMaybeType.No) false]))

(define (lint-single-element-array-dynamic-element-scalar?
  [maybe-ty : ast.AstMaybeType]) : bool
  (match maybe-ty
    [(ast.AstMaybeType.Some ty)
      (match ty
        [(ast.AstType.DynArray elem)
          (lint-single-element-array-scalar-type-id? elem)]
        [_ false])]
    [(ast.AstMaybeType.No) false]))

(define (lint-single-element-array-int-literal?
  [expr : ast.AstExpr]
  [value : i64]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-single-element-array-int-literal? (ast.ast-node-get inner) value)]
    [(ast.AstExpr.Ann inner _)
      (lint-single-element-array-int-literal? (ast.ast-node-get inner) value)]
    [(ast.AstExpr.Literal lit)
      (and
        (>
          (string.string-length
            (ast.ast-lit-int-text (owned_view.compiler-owned-shared-view lit)))
          0)
        (= (ast.ast-lit-int-value lit) value))]
    [_ false]))

(define (lint-single-element-array-expr-list-count [exprs : ast.AstExprList]) : i64
  exprs.len)

(define (lint-single-element-array-callee-name [expr : ast.AstExpr]) : String
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-single-element-array-callee-name (ast.ast-node-get inner))]
    [(ast.AstExpr.Var name) (ci.intern-str name)]
    [_ ""]))

(define (lint-single-element-array-var-name [expr : ast.AstExpr]) : String
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-single-element-array-var-name (ast.ast-node-get inner))]
    [(ast.AstExpr.Var name) (ci.intern-str name)]
    [_ ""]))

(define (lint-single-element-array-make-array-callee? [name : String]) : bool
  (or
    (string.eq name "make-array")
    (string.eq name "__tl_make-array")
    (string.eq name "array.make-array")
    (string.eq name "array/make-array")
    (string.eq name "stdlib.array.make-array")))

(define (lint-single-element-array-ref-callee? [name : String]) : bool
  (or
    (string.eq name "array-ref")
    (string.eq name "__tl_array-ref")
    (string.eq name "array.ref")
    (string.eq name "array/ref")
    (string.eq name "stdlib.array.ref")))

(define (lint-single-element-array-set-callee? [name : String]) : bool
  (or (string.eq name "array-set!") (string.eq name "__tl_array-set!")))

(define (lint-single-element-array-args-second-int?
  [args : ast.AstExprList]
  [value : i64]) : bool
  (if (> args.len 1)
    (lint-single-element-array-int-literal?
      (ast.ast-node-get (ast.ast-expr-list-get (& args) 1 0))
      value)
    false))

(define (lint-single-element-array-first-arg-name [args : ast.AstExprList]) : String
  (if (> args.len 0)
    (lint-single-element-array-var-name
      (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0)))
    ""))

(define (lint-single-element-array-make-array-one? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-single-element-array-make-array-one? (ast.ast-node-get inner))]
    [(ast.AstExpr.Ann inner _)
      (lint-single-element-array-make-array-one? (ast.ast-node-get inner))]
    [(ast.AstExpr.MakeArray _ len)
      (lint-single-element-array-int-literal? (ast.ast-node-get len) 1)]
    [(ast.AstExpr.Call func args)
      (and
        (lint-single-element-array-make-array-callee?
          (lint-single-element-array-callee-name (ast.ast-node-get func)))
        (lint-single-element-array-args-second-int? args 1))]
    [_ false]))

(define (lint-single-element-array-local-candidate?
  [maybe-ty : ast.AstMaybeType]
  [init : i64]) : bool
  (or
    (lint-single-element-array-maybe-fixed-type?
      (owned_view.compiler-owned-shared-view maybe-ty))
    (and
      (lint-single-element-array-dynamic-element-scalar? maybe-ty)
      (lint-single-element-array-make-array-one? (ast.ast-node-get init)))))

(define (lint-single-element-array-binding-span [init : i64]) : ast.AstSourceSpan
  (lint-no-effect-span (ast.ast-node-get init)))

(define (lint-single-element-array-add-local-if-candidate
  [name-id : i64]
  [maybe-ty : ast.AstMaybeType]
  [init : i64]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (let
    [name : String (ci.intern-str name-id)]
    [base : LintSingleElementArrayState
      (lint-single-element-array-state-with-candidates
        (owned_view.compiler-owned-shared-view state)
        (lint-single-element-array-candidate-remove
          state.candidates
          (owned_view.compiler-owned-shared-view name)))]
    (if (lint-single-element-array-local-candidate? maybe-ty init)
      (lint-single-element-array-state-with-candidates
        (owned_view.compiler-owned-shared-view base)
        (lint-single-element-array-candidate-add
          base.candidates
          name
          (lint-single-element-array-binding-span init)))
      base)))

(define (lint-single-element-array-param-candidates
  [params : ast.AstParamList]
  [span : ast.AstSourceSpan]
  [items : LintSingleElementArrayCandidateList]) : LintSingleElementArrayCandidateList
  (lint-single-element-array-param-candidates-at (& params) span items 0))

(define (lint-single-element-array-param-candidates-at
  [params : (& params ast.AstParamList)]
  [span : ast.AstSourceSpan]
  [items : LintSingleElementArrayCandidateList]
  [index : i64]) : LintSingleElementArrayCandidateList
  (if (>= index (ast.ast-param-list-len params))
    items
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param name ty _)
        (let
          [text : String (ci.intern-str name)]
          [with-param : LintSingleElementArrayCandidateList
            (if (lint-single-element-array-fixed-type? ty)
              (lint-single-element-array-candidate-add items text span)
              items)]
          (lint-single-element-array-param-candidates-at
            params
            span
            with-param
            (+ index 1)))])))

(define (lint-single-element-array-finalize-candidates-at
  [items : LintSingleElementArrayCandidateList]
  [acc : LintFindings]
  [index : i64]) : LintFindings
  (if (< index 0)
    acc
    (let
      [item : LintSingleElementArrayCandidate
        (owned_view.compiler-owned-array-element-shared-view items.slots index)]
      [next : LintFindings
        (if (and
          item.valid
          item.used
          (not
            (lint-underscore-prefixed?
              (owned_view.compiler-owned-shared-view item.name))))
          (lint-findings-add
            (lint-single-element-array-cell-finding item.name item.span)
            acc)
          acc)]
      (lint-single-element-array-finalize-candidates-at items next (- index 1)))))

(define (lint-single-element-array-finalize-candidates
  [items : LintSingleElementArrayCandidateList]
  [acc : LintFindings]) : LintFindings
  (lint-single-element-array-finalize-candidates-at
    (owned_view.compiler-owned-shared-view items)
    acc
    (- items.len 1)))

(define (lint-single-element-array-finalize-state
  [state : LintSingleElementArrayState]) : LintFindings
  (lint-single-element-array-finalize-candidates
    state.candidates
    state.findings))

(define (lint-single-element-array-expr-list
  [exprs : ast.AstExprList]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (lint-single-element-array-expr-list-at (& exprs) 0 state))

(define (lint-single-element-array-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (if (>= index exprs.len)
    state
    (lint-single-element-array-expr-list-at
      exprs
      (+ index 1)
      (lint-single-element-array-expr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))
        state))))

(define (lint-single-element-array-expr-list-after-two
  [exprs : ast.AstExprList]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (lint-single-element-array-expr-list-at (& exprs) 2 state))

(define (lint-single-element-array-let-bindings
  [bindings : ast.AstLetBindingList]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (lint-single-element-array-let-bindings-at (& bindings) state 0))

(define (lint-single-element-array-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [state : LintSingleElementArrayState]
  [index : i64]) : LintSingleElementArrayState
  (if (>= index (ast.ast-let-binding-list-len bindings))
    state
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name maybe-ty init)
        (let
          [after-init : LintSingleElementArrayState
            (lint-single-element-array-expr (ast.ast-node-get init) state)]
          [after-binding : LintSingleElementArrayState
            (lint-single-element-array-add-local-if-candidate
              name
              maybe-ty
              init
              after-init)]
          (lint-single-element-array-let-bindings-at
            bindings
            after-binding
            (+ index 1)))])))

(define (lint-single-element-array-match-arms
  [arms : ast.AstMatchArmList]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (lint-single-element-array-match-arms-at (& arms) state 0))

(define (lint-single-element-array-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [state : LintSingleElementArrayState]
  [index : i64]) : LintSingleElementArrayState
  (if (>= index arms.len)
    state
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm _ body)
        (lint-single-element-array-match-arms-at
          arms
          (lint-single-element-array-expr (ast.ast-node-get body) state)
          (+ index 1))])))

(define (lint-single-element-array-resource-bindings
  [bindings : ast.AstResourceBindingList]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (lint-single-element-array-resource-bindings-at (& bindings) state 0))

(define (lint-single-element-array-resource-bindings-at
  [bindings : (& bindings ast.AstResourceBindingList)]
  [state : LintSingleElementArrayState]
  [index : i64]) : LintSingleElementArrayState
  (if (>= index (ast.ast-resource-binding-list-len bindings))
    state
    (match (ast.ast-resource-binding-list-get
      bindings
      index
      (ast.ast-resource-binding-fallback))
      [(ast.AstResourceBinding.Binding name init cleanup _)
        (let
          [after-init : LintSingleElementArrayState
            (lint-single-element-array-expr (ast.ast-node-get init) state)]
          [after-cleanup : LintSingleElementArrayState
            (lint-single-element-array-expr
              (ast.ast-node-get cleanup)
              after-init)]
          [after-shadow : LintSingleElementArrayState
            (lint-single-element-array-state-with-candidates
              (owned_view.compiler-owned-shared-view after-cleanup)
              (lint-single-element-array-candidate-remove
                after-cleanup.candidates
                (ci.intern-str name)))]
          (lint-single-element-array-resource-bindings-at
            bindings
            after-shadow
            (+ index 1)))])))

(define (lint-single-element-array-call-ref
  [args : ast.AstExprList]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (let
    [name : String
      (lint-single-element-array-first-arg-name
        (owned_view.compiler-owned-shared-view args))]
    (if (and
      (=
        (lint-single-element-array-expr-list-count
          (owned_view.compiler-owned-shared-view args))
        2)
      (lint-single-element-array-candidate-tracked?
        (owned_view.compiler-owned-shared-view state.candidates)
        (owned_view.compiler-owned-shared-view name))
      (lint-single-element-array-args-second-int?
        (owned_view.compiler-owned-shared-view args)
        0))
      (lint-single-element-array-expr-list-after-two
        args
        (lint-single-element-array-note-use
          (owned_view.compiler-owned-shared-view state)
          name))
      (lint-single-element-array-expr-list args state))))

(define (lint-single-element-array-call-set
  [args : ast.AstExprList]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (let
    [name : String
      (lint-single-element-array-first-arg-name
        (owned_view.compiler-owned-shared-view args))]
    (if (and
      (=
        (lint-single-element-array-expr-list-count
          (owned_view.compiler-owned-shared-view args))
        3)
      (lint-single-element-array-candidate-tracked?
        (owned_view.compiler-owned-shared-view state.candidates)
        (owned_view.compiler-owned-shared-view name))
      (lint-single-element-array-args-second-int?
        (owned_view.compiler-owned-shared-view args)
        0))
      (lint-single-element-array-expr-list-after-two
        args
        (lint-single-element-array-note-use
          (owned_view.compiler-owned-shared-view state)
          name))
      (lint-single-element-array-expr-list args state))))

(define (lint-prefer-dynamic-array-literal-int-value [expr : ast.AstExpr]) : i64
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-prefer-dynamic-array-literal-int-value (ast.ast-node-get inner))]
    [(ast.AstExpr.Ann inner _)
      (lint-prefer-dynamic-array-literal-int-value (ast.ast-node-get inner))]
    [(ast.AstExpr.Literal lit)
      (if (>
        (string.string-length
          (ast.ast-lit-int-text (owned_view.compiler-owned-shared-view lit)))
        0)
        (ast.ast-lit-int-value lit)
        -1)]
    [_ -1]))

(define (lint-prefer-dynamic-array-literal-allocation-length
  [expr : ast.AstExpr]) : i64
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner _)
      (lint-prefer-dynamic-array-literal-allocation-length
        (ast.ast-node-get inner))]
    [(ast.AstExpr.Ann inner _)
      (lint-prefer-dynamic-array-literal-allocation-length
        (ast.ast-node-get inner))]
    [(ast.AstExpr.MakeArray _ length)
      (lint-prefer-dynamic-array-literal-int-value (ast.ast-node-get length))]
    [(ast.AstExpr.Call func args)
      (if (and
        (lint-single-element-array-make-array-callee?
          (lint-single-element-array-callee-name (ast.ast-node-get func)))
        (=
          (lint-single-element-array-expr-list-count
            (owned_view.compiler-owned-shared-view args))
          2))
        (lint-prefer-dynamic-array-literal-int-value
          (ast.ast-node-get (ast.ast-expr-list-get (& args) 1 0)))
        -1)]
    [_ -1]))

(define (lint-prefer-dynamic-array-literal-var?
  [expr : ast.AstExpr]
  [name : String]) : bool
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner _)
      (lint-prefer-dynamic-array-literal-var? (ast.ast-node-get inner) name)]
    [(ast.AstExpr.Ann inner _)
      (lint-prefer-dynamic-array-literal-var? (ast.ast-node-get inner) name)]
    [(ast.AstExpr.Var found) (string.eq (ci.intern-str found) name)]
    [_ false]))

(define (lint-prefer-dynamic-array-literal-final-value?
  [expr : ast.AstExpr]
  [name : String]) : bool
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner _)
      (lint-prefer-dynamic-array-literal-final-value?
        (ast.ast-node-get inner)
        name)]
    [(ast.AstExpr.Ann inner _)
      (lint-prefer-dynamic-array-literal-final-value?
        (ast.ast-node-get inner)
        name)]
    [(ast.AstExpr.Return inner)
      (lint-prefer-dynamic-array-literal-var? (ast.ast-node-get inner) name)]
    [(ast.AstExpr.Set target value)
      (and
        (not (string.eq (ci.intern-str target) name))
        (lint-prefer-dynamic-array-literal-var? (ast.ast-node-get value) name))]
    [_ (lint-prefer-dynamic-array-literal-var? expr name)]))

(define (lint-prefer-dynamic-array-literal-bare-var? [expr : ast.AstExpr]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-prefer-dynamic-array-literal-bare-var? (ast.ast-node-get inner))]
    [(ast.AstExpr.Var _) true]
    [_ false]))

(define (lint-prefer-dynamic-array-literal-value-uses-name?
  [expr : ast.AstExpr]
  [name : String]) : bool
  (let
    [result : LintSingleElementArrayState
      (lint-single-element-array-expr
        expr
        (LintSingleElementArrayState
          (lint-single-element-array-candidate-add
            (lint-single-element-array-candidates-empty)
            name
            (lint-no-span))
          (lint-findings-empty)))]
    [items : LintSingleElementArrayCandidateList
      (owned_view.compiler-owned-shared-view result.candidates)]
    [top : i64 (- items.len 1)]
    (if (< top 0)
      false
      (let
        [item : LintSingleElementArrayCandidate
          (owned_view.compiler-owned-array-element-shared-view items.slots top)]
        (or item.used (not item.valid))))))

(define (lint-prefer-dynamic-array-literal-set-callee? [name : String]) : bool
  (or
    (lint-single-element-array-set-callee?
      (owned_view.compiler-owned-shared-view name))
    (string.eq name "array.set!")
    (string.eq name "array/set!")
    (string.eq name "stdlib.array.set!")))

(define (lint-prefer-dynamic-array-literal-set-at?
  [expr : ast.AstExpr]
  [name : String]
  [index : i64]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-prefer-dynamic-array-literal-set-at?
        (ast.ast-node-get inner)
        (owned_view.compiler-owned-shared-view name)
        index)]
    [(ast.AstExpr.Ann inner _)
      (lint-prefer-dynamic-array-literal-set-at?
        (ast.ast-node-get inner)
        name
        index)]
    [(ast.AstExpr.ArraySet array actual-index value)
      (and
        (string.eq
          (lint-single-element-array-var-name (ast.ast-node-get array))
          name)
        (lint-single-element-array-int-literal?
          (ast.ast-node-get actual-index)
          index)
        (not
          (lint-prefer-dynamic-array-literal-value-uses-name?
            (ast.ast-node-get value)
            name)))]
    [(ast.AstExpr.Call func args)
      (and
        (lint-prefer-dynamic-array-literal-set-callee?
          (lint-single-element-array-callee-name (ast.ast-node-get func)))
        (=
          (lint-single-element-array-expr-list-count
            (owned_view.compiler-owned-shared-view args))
          3)
        (string.eq
          (lint-single-element-array-first-arg-name
            (owned_view.compiler-owned-shared-view args))
          name)
        (lint-single-element-array-args-second-int?
          (owned_view.compiler-owned-shared-view args)
          index)
        (not
          (lint-prefer-dynamic-array-literal-value-uses-name?
            (ast.ast-node-get (ast.ast-expr-list-get (& args) 2 0))
            name)))]
    [_ false]))

(define (lint-prefer-dynamic-array-literal-first-write-bare-var?
  [expr : ast.AstExpr]
  [name : String]) : bool
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-prefer-dynamic-array-literal-first-write-bare-var?
        (ast.ast-node-get inner)
        name)]
    [(ast.AstExpr.Ann inner _)
      (lint-prefer-dynamic-array-literal-first-write-bare-var?
        (ast.ast-node-get inner)
        name)]
    [(ast.AstExpr.ArraySet array index value)
      (and
        (string.eq
          (lint-single-element-array-var-name (ast.ast-node-get array))
          name)
        (lint-single-element-array-int-literal? (ast.ast-node-get index) 0)
        (lint-prefer-dynamic-array-literal-bare-var? (ast.ast-node-get value)))]
    [(ast.AstExpr.Call func args)
      (and
        (lint-prefer-dynamic-array-literal-set-callee?
          (lint-single-element-array-callee-name (ast.ast-node-get func)))
        (=
          (lint-single-element-array-expr-list-count
            (owned_view.compiler-owned-shared-view args))
          3)
        (string.eq
          (lint-single-element-array-first-arg-name
            (owned_view.compiler-owned-shared-view args))
          name)
        (lint-single-element-array-args-second-int?
          (owned_view.compiler-owned-shared-view args)
          0)
        (lint-prefer-dynamic-array-literal-bare-var?
          (ast.ast-node-get (ast.ast-expr-list-get (& args) 2 0))))]
    [_ false]))

(define (lint-prefer-dynamic-array-literal-write-sequence?
  [exprs : ast.AstExprList]
  [name : String]
  [length : i64]
  [index : i64]) : bool
  (if (>= index length)
    (lint-prefer-dynamic-array-literal-final-value?
      (ast.ast-node-get (ast.ast-expr-list-get (& exprs) index 0))
      (owned_view.compiler-owned-shared-view name))
    (and
      (lint-prefer-dynamic-array-literal-set-at?
        (ast.ast-node-get (ast.ast-expr-list-get (& exprs) index 0))
        (owned_view.compiler-owned-shared-view name)
        index)
      (lint-prefer-dynamic-array-literal-write-sequence?
        (owned_view.compiler-owned-shared-view exprs)
        (owned_view.compiler-owned-shared-view name)
        length
        (+ index 1)))))

(define (lint-prefer-dynamic-array-literal-body?
  [body : ast.AstExpr]
  [name : String]
  [length : i64]) : bool
  (match body
    [(ast.AstExpr.Spanned inner _)
      (lint-prefer-dynamic-array-literal-body?
        (ast.ast-node-get inner)
        name
        length)]
    [(ast.AstExpr.Ann inner _)
      (lint-prefer-dynamic-array-literal-body?
        (ast.ast-node-get inner)
        name
        length)]
    [(ast.AstExpr.Begin exprs)
      (and
        (=
          (lint-single-element-array-expr-list-count
            (owned_view.compiler-owned-shared-view exprs))
          (+ length 1))
        (not
          (and
            (= length 2)
            (lint-prefer-dynamic-array-literal-first-write-bare-var?
              (ast.ast-node-get (ast.ast-expr-list-get (& exprs) 0 0))
              (owned_view.compiler-owned-shared-view name))))
        (lint-prefer-dynamic-array-literal-write-sequence?
          (owned_view.compiler-owned-shared-view exprs)
          name
          length
          0))]
    [_ false]))

(define (lint-prefer-dynamic-array-literals-in-let-bindings
  [bindings : ast.AstLetBindingList]
  [body : ast.AstExpr]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (lint-prefer-dynamic-array-literals-in-let-bindings-at
    (& bindings)
    body
    (owned_view.compiler-owned-shared-view state)
    0))

(define (lint-prefer-dynamic-array-literals-in-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [body : ast.AstExpr]
  [state : LintSingleElementArrayState]
  [index : i64]) : LintSingleElementArrayState
  (if (>= index (ast.ast-let-binding-list-len bindings))
    state
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name-id _ init)
        (let
          [name : String (ci.intern-str name-id)]
          [length : i64
            (lint-prefer-dynamic-array-literal-allocation-length
              (ast.ast-node-get init))]
          [next : LintSingleElementArrayState
            (if (and
              (> length 0)
              (not
                (lint-underscore-prefixed?
                  (owned_view.compiler-owned-shared-view name)))
              (lint-prefer-dynamic-array-literal-body?
                (owned_view.compiler-owned-shared-view body)
                (owned_view.compiler-owned-shared-view name)
                length))
              (lint-single-element-array-state-with-findings
                (owned_view.compiler-owned-shared-view state)
                (lint-findings-add
                  (lint-prefer-dynamic-array-literal-finding
                    (owned_view.compiler-owned-shared-view name)
                    (lint-no-effect-span (ast.ast-node-get init)))
                  (owned_view.compiler-owned-shared-view state.findings)))
              (owned_view.compiler-owned-shared-view state))]
          (lint-prefer-dynamic-array-literals-in-let-bindings-at
            bindings
            body
            next
            (+ index 1)))])))

(define (lint-single-element-array-expr
  [expr : ast.AstExpr]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.MacroExpansion inner _ _)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Literal _) state]
    [(ast.AstExpr.Var name)
      (lint-single-element-array-note-var state (ci.intern-str name))]
    [(ast.AstExpr.Binary _ left right)
      (lint-single-element-array-expr
        (ast.ast-node-get right)
        (lint-single-element-array-expr (ast.ast-node-get left) state))]
    [(ast.AstExpr.Unary _ inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Call func args)
      (let
        [callee : String
          (lint-single-element-array-callee-name (ast.ast-node-get func))]
        [after-func : LintSingleElementArrayState
          (lint-single-element-array-expr (ast.ast-node-get func) state)]
        (cond
          [(lint-single-element-array-ref-callee?
              (owned_view.compiler-owned-shared-view callee))
            (lint-single-element-array-call-ref args after-func)]
          [(lint-single-element-array-set-callee? callee)
            (lint-single-element-array-call-set args after-func)]
          [else (lint-single-element-array-expr-list args after-func)]))]
    [(ast.AstExpr.If cond then-branch else-branch)
      (lint-single-element-array-expr
        (ast.ast-node-get else-branch)
        (lint-single-element-array-expr
          (ast.ast-node-get then-branch)
          (lint-single-element-array-expr (ast.ast-node-get cond) state)))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (let
            [with-dynamic-array-literals : LintSingleElementArrayState
              (lint-prefer-dynamic-array-literals-in-let-bindings
                (owned_view.compiler-owned-shared-view bindings)
                (ast.ast-node-get body)
                state)]
            (lint-single-element-array-expr
              (ast.ast-node-get body)
              (lint-single-element-array-let-bindings
                bindings
                with-dynamic-array-literals)))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda _ _ body)
          (lint-single-element-array-expr (ast.ast-node-get body) state)])]
    [(ast.AstExpr.Tuple exprs)
      (lint-single-element-array-expr-list exprs state)]
    [(ast.AstExpr.TupleRef tuple _)
      (lint-single-element-array-expr (ast.ast-node-get tuple) state)]
    [(ast.AstExpr.Array exprs)
      (lint-single-element-array-expr-list exprs state)]
    [(ast.AstExpr.DynArray exprs)
      (lint-single-element-array-expr-list exprs state)]
    [(ast.AstExpr.MakeArray _ len)
      (lint-single-element-array-expr (ast.ast-node-get len) state)]
    [(ast.AstExpr.ArrayRef array index)
      (let
        [name : String
          (lint-single-element-array-var-name (ast.ast-node-get array))]
        (if (and
          (lint-single-element-array-candidate-tracked?
            (owned_view.compiler-owned-shared-view state.candidates)
            (owned_view.compiler-owned-shared-view name))
          (lint-single-element-array-int-literal? (ast.ast-node-get index) 0))
          (lint-single-element-array-note-use
            (owned_view.compiler-owned-shared-view state)
            name)
          (lint-single-element-array-expr
            (ast.ast-node-get index)
            (lint-single-element-array-expr (ast.ast-node-get array) state))))]
    [(ast.AstExpr.ArraySet array index value)
      (let
        [name : String
          (lint-single-element-array-var-name (ast.ast-node-get array))]
        (if (and
          (lint-single-element-array-candidate-tracked?
            (owned_view.compiler-owned-shared-view state.candidates)
            (owned_view.compiler-owned-shared-view name))
          (lint-single-element-array-int-literal? (ast.ast-node-get index) 0))
          (lint-single-element-array-expr
            (ast.ast-node-get value)
            (lint-single-element-array-note-use state name))
          (lint-single-element-array-expr
            (ast.ast-node-get value)
            (lint-single-element-array-expr
              (ast.ast-node-get index)
              (lint-single-element-array-expr (ast.ast-node-get array) state)))))]
    [(ast.AstExpr.ArrayTake array live index)
      (let
        [name : String
          (lint-single-element-array-var-name (ast.ast-node-get array))]
        (if (and
          (lint-single-element-array-candidate-tracked?
            (owned_view.compiler-owned-shared-view state.candidates)
            (owned_view.compiler-owned-shared-view name))
          (lint-single-element-array-int-literal? (ast.ast-node-get index) 0))
          (lint-single-element-array-expr
            (ast.ast-node-get live)
            (lint-single-element-array-note-use state name))
          (lint-single-element-array-expr
            (ast.ast-node-get index)
            (lint-single-element-array-expr
              (ast.ast-node-get live)
              (lint-single-element-array-expr (ast.ast-node-get array) state)))))]
    [(ast.AstExpr.FixedArrayTake array index)
      (let
        [name : String
          (lint-single-element-array-var-name (ast.ast-node-get array))]
        (if (and
          (lint-single-element-array-candidate-tracked?
            (owned_view.compiler-owned-shared-view state.candidates)
            (owned_view.compiler-owned-shared-view name))
          (lint-single-element-array-int-literal? (ast.ast-node-get index) 0))
          (lint-single-element-array-note-use
            (owned_view.compiler-owned-shared-view state)
            name)
          (lint-single-element-array-expr
            (ast.ast-node-get index)
            (lint-single-element-array-expr (ast.ast-node-get array) state))))]
    [(ast.AstExpr.Replace place replacement)
      (lint-single-element-array-expr
        (ast.ast-node-get replacement)
        (lint-single-element-array-expr (ast.ast-node-get place) state))]
    [(ast.AstExpr.ArrayPush array value)
      (lint-single-element-array-expr
        (ast.ast-node-get value)
        (lint-single-element-array-expr (ast.ast-node-get array) state))]
    [(ast.AstExpr.StringRef text index)
      (lint-single-element-array-expr
        (ast.ast-node-get index)
        (lint-single-element-array-expr (ast.ast-node-get text) state))]
    [(ast.AstExpr.While cond body)
      (lint-single-element-array-expr
        (ast.ast-node-get body)
        (lint-single-element-array-expr (ast.ast-node-get cond) state))]
    [(ast.AstExpr.ForOwnedState payload)
      (lint-single-element-array-expr
        (ast.ast-node-get (ast.ast-for-owned-state-body (& payload)))
        (lint-single-element-array-expr
          (ast.ast-node-get (ast.ast-for-owned-state-source (& payload)))
          state))]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (lint-single-element-array-expr
          (ast.ast-node-get (ast.ast-for-owned-step-body (& payload)))
          (if (>= expected-type 0)
            (lint-single-element-array-expr
              (ast.ast-node-get expected-type)
              state)
            state)))]
    [(ast.AstExpr.Begin exprs)
      (lint-single-element-array-expr-list exprs state)]
    [(ast.AstExpr.Unsafe exprs)
      (lint-single-element-array-expr-list exprs state)]
    [(ast.AstExpr.Set target value)
      (lint-single-element-array-expr
        (ast.ast-node-get value)
        (lint-single-element-array-note-var state (ci.intern-str target)))]
    [(ast.AstExpr.Ann inner _)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Cast inner _)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Borrow _ _ place)
      (lint-single-element-array-expr (ast.ast-node-get place) state)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (lint-single-element-array-match-arms
            arms
            (lint-single-element-array-expr (ast.ast-node-get scrutinee) state))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach _ _ start end body)
          (lint-single-element-array-expr
            (ast.ast-node-get body)
            (lint-single-element-array-expr
              (ast.ast-node-get end)
              (lint-single-element-array-expr (ast.ast-node-get start) state)))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce _ _ _ start end init value)
          (lint-single-element-array-expr
            (ast.ast-node-get value)
            (lint-single-element-array-expr
              (ast.ast-node-get init)
              (lint-single-element-array-expr
                (ast.ast-node-get end)
                (lint-single-element-array-expr (ast.ast-node-get start) state))))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(ast.AstSpmdScan.Scan _ _ _ start end _ _ init value body)
          (lint-single-element-array-expr
            (ast.ast-node-get body)
            (lint-single-element-array-expr
              (ast.ast-node-get value)
              (lint-single-element-array-expr
                (ast.ast-node-get init)
                (lint-single-element-array-expr
                  (ast.ast-node-get end)
                  (lint-single-element-array-expr
                    (ast.ast-node-get start)
                    state)))))])]
    [(ast.AstExpr.SpmdBroadcast value lane)
      (lint-single-element-array-expr
        (ast.ast-node-get lane)
        (lint-single-element-array-expr (ast.ast-node-get value) state))]
    [(ast.AstExpr.SpmdShuffle value lane)
      (lint-single-element-array-expr
        (ast.ast-node-get lane)
        (lint-single-element-array-expr (ast.ast-node-get value) state))]
    [(ast.AstExpr.StructGet receiver _)
      (lint-single-element-array-expr (ast.ast-node-get receiver) state)]
    [(ast.AstExpr.StructSet receiver _ value)
      (lint-single-element-array-expr
        (ast.ast-node-get value)
        (lint-single-element-array-expr (ast.ast-node-get receiver) state))]
    [(ast.AstExpr.WithRegion _ body)
      (lint-single-element-array-expr-list body state)]
    [(ast.AstExpr.WithEscape scratch body)
      (lint-single-element-array-expr-list
        body
        (lint-single-element-array-expr (ast.ast-node-get scratch) state))]
    [(ast.AstExpr.WithScratch body)
      (lint-single-element-array-expr-list body state)]
    [(ast.AstExpr.InArena arena body)
      (lint-single-element-array-expr-list
        body
        (lint-single-element-array-expr (ast.ast-node-get arena) state))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-single-element-array-expr-list
            body
            (lint-single-element-array-resource-bindings bindings state))])]
    [(ast.AstExpr.Box inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BoxGet inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BoxTake inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BoxSet inner value)
      (lint-single-element-array-expr
        (ast.ast-node-get value)
        (lint-single-element-array-expr (ast.ast-node-get inner) state))]
    [(ast.AstExpr.TypeLiteral _) state]
    [(ast.AstExpr.Init _) state]
    [(ast.AstExpr.Comptime inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Quote _) state]
    [(ast.AstExpr.Quasiquote _) state]
    [(ast.AstExpr.Unquote inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.UnquoteSplicing inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BracketClause items)
      (lint-single-element-array-expr-list items state)]
    [(ast.AstExpr.Try inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Return inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Break) state]
    [(ast.AstExpr.Continue) state]
    [(ast.AstExpr.PtrNull _) state]
    [(ast.AstExpr.PtrNullCheck inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.PtrAddrOf place)
      (lint-single-element-array-expr (ast.ast-node-get place) state)]
    [(ast.AstExpr.PtrRead ptr)
      (lint-single-element-array-expr (ast.ast-node-get ptr) state)]
    [(ast.AstExpr.PtrWrite ptr value)
      (lint-single-element-array-expr
        (ast.ast-node-get value)
        (lint-single-element-array-expr (ast.ast-node-get ptr) state))]
    [(ast.AstExpr.PtrOffset ptr offset)
      (lint-single-element-array-expr
        (ast.ast-node-get offset)
        (lint-single-element-array-expr (ast.ast-node-get ptr) state))]
    [(ast.AstExpr.PtrCast ptr _)
      (lint-single-element-array-expr (ast.ast-node-get ptr) state)]
    [(ast.AstExpr.PtrToInt ptr)
      (lint-single-element-array-expr (ast.ast-node-get ptr) state)]
    [(ast.AstExpr.IntToPtr value _)
      (lint-single-element-array-expr (ast.ast-node-get value) state)]
    [(ast.AstExpr.StringData inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.StringFromBytes ptr len)
      (lint-single-element-array-expr
        (ast.ast-node-get len)
        (lint-single-element-array-expr (ast.ast-node-get ptr) state))]
    [(ast.AstExpr.ArrayData inner)
      (lint-single-element-array-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BinaryData _) state]
    [(ast.AstExpr.SpmdProgramIndex) state]
    [(ast.AstExpr.SpmdProgramCount) state]
    [(ast.AstExpr.ProgramArgc) state]
    [(ast.AstExpr.ProgramArgv) state]
    [(ast.AstExpr.ProgramEnvp) state]
    [(ast.AstExpr.CpuIdEax leaf subleaf)
      (lint-single-element-array-expr
        (ast.ast-node-get subleaf)
        (lint-single-element-array-expr (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.CpuIdEbx leaf subleaf)
      (lint-single-element-array-expr
        (ast.ast-node-get subleaf)
        (lint-single-element-array-expr (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.CpuIdEcx leaf subleaf)
      (lint-single-element-array-expr
        (ast.ast-node-get subleaf)
        (lint-single-element-array-expr (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.CpuIdEdx leaf subleaf)
      (lint-single-element-array-expr
        (ast.ast-node-get subleaf)
        (lint-single-element-array-expr (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.Xgetbv index)
      (lint-single-element-array-expr (ast.ast-node-get index) state)]
    [(ast.AstExpr.Syscall args)
      (lint-single-element-array-expr-list args state)]))

(define (lint-single-element-array-cells-in-decl
  [decl : ast.AstDecl]
  [acc : LintFindings]) : LintFindings
  (match (owned_view.compiler-owned-shared-view decl)
    [(ast.AstDecl.Def decl-meta _ _ body)
      (lint-single-element-array-finalize-state
        (lint-single-element-array-expr
          (ast.ast-node-get body)
          (LintSingleElementArrayState
            (lint-single-element-array-candidates-empty)
            acc)))]
    [(ast.AstDecl.DefFn decl-meta _ params _ body _)
      (let
        [body-span : ast.AstSourceSpan
          (lint-no-effect-span (ast.ast-node-get body))]
        [param-candidates : LintSingleElementArrayCandidateList
          (lint-single-element-array-param-candidates
            params
            body-span
            (lint-single-element-array-candidates-empty))]
        (lint-single-element-array-finalize-state
          (lint-single-element-array-expr
            (ast.ast-node-get body)
            (LintSingleElementArrayState param-candidates acc))))]
    [(ast.AstDecl.Test _ body _)
      (lint-single-element-array-finalize-state
        (lint-single-element-array-expr
          (ast.ast-node-get body)
          (LintSingleElementArrayState
            (lint-single-element-array-candidates-empty)
            acc)))]
    [(ast.AstDecl.Unsafe inner)
      (lint-single-element-array-cells-in-decl
        (ast.ast-decl-box-shared-view inner)
        acc)]
    [_ acc]))

(define (lint-single-element-array-cells-in-decl-list
  [decls : ast.AstDeclList]
  [acc : LintFindings]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) acc]
    [(ast.AstDeclListStep.Cons decl rest)
      (lint-single-element-array-cells-in-decl-list
        rest
        (lint-single-element-array-cells-in-decl decl acc))]))

(define (lint-pending-assignment-empty) : LintPendingAssignmentList
  (LintPendingAssignmentList (__tl_make-array LintPendingAssignment 0) 0))

(define (lint-pending-assignment-index
  [items : LintPendingAssignmentList]
  [name : String]
  [index : i64]) : i64
  (if (>= index items.len)
    (- 0 1)
    (if (string.eq (__tl-project-field (array-ref items.slots index) name) name)
      index
      (lint-pending-assignment-index items name (+ index 1)))))

(define (lint-pending-assignment-find
  [items : LintPendingAssignmentList]
  [name : String]) : LintMaybePendingAssignment
  (let
    [found : i64
      (lint-pending-assignment-index
        (owned_view.compiler-owned-shared-view items)
        name
        0)]
    (if (< found 0)
      LintMaybePendingAssignment.No
      (LintMaybePendingAssignment.Some
        (owned_view.compiler-owned-array-element-shared-view items.slots found)))))

(define (lint-pending-assignment-remove
  [items : LintPendingAssignmentList]
  [name : String]) : LintPendingAssignmentList
  (let
    [found : i64
      (lint-pending-assignment-index
        (owned_view.compiler-owned-shared-view items)
        name
        0)]
    (if (< found 0)
      items
      (let
        [n : i64 (- items.len 1)]
        [slots : (__tl_dyn-array LintPendingAssignment)
          (__tl_make-array LintPendingAssignment n)]
        [index : i64 0]
        (begin
          (while (< index n)
            (begin
              (set!
                (array-ref slots index)
                (array-ref
                  items.slots
                  (if (< index found)
                    index
                    (+ index 1))))
              (set! index (+ index 1))))
          (LintPendingAssignmentList slots n))))))

(define (lint-pending-assignment-add
  [items : LintPendingAssignmentList]
  [name : String]
  [span : ast.AstSourceSpan]) : LintPendingAssignmentList
  (let
    [without : LintPendingAssignmentList
      (lint-pending-assignment-remove
        items
        (owned_view.compiler-owned-shared-view name))]
    [n : i64 without.len]
    [slots : (__tl_dyn-array LintPendingAssignment)
      (__tl_make-array LintPendingAssignment (+ n 1))]
    [index : i64 0]
    (begin
      (while (< index n)
        (begin
          (set! (array-ref slots index) (array-ref without.slots index))
          (set! index (+ index 1))))
      (set! (array-ref slots n) (LintPendingAssignment name span))
      (LintPendingAssignmentList slots (+ n 1)))))

(define (lint-unused-assignment-state-with
  [state : LintUnusedAssignmentState]
  [pending : LintPendingAssignmentList]
  [findings : LintFindings]) : LintUnusedAssignmentState
  (LintUnusedAssignmentState state.locals pending findings))

(define (lint-unused-assignment-read-name
  [state : LintUnusedAssignmentState]
  [name : String]) : LintUnusedAssignmentState
  (lint-unused-assignment-state-with
    (owned_view.compiler-owned-shared-view state)
    (lint-pending-assignment-remove state.pending name)
    state.findings))

(define (lint-unused-assignment-read-id
  [state : LintUnusedAssignmentState]
  [name : i64]) : LintUnusedAssignmentState
  (lint-unused-assignment-read-name state (ci.intern-str name)))

(define (lint-unused-assignment-write-name
  [state : LintUnusedAssignmentState]
  [name : String]
  [span : ast.AstSourceSpan]) : LintUnusedAssignmentState
  (if (not
    (lint-name-set-contains?
      state.locals
      (owned_view.compiler-owned-shared-view name)))
    state
    (if (lint-underscore-prefixed? (owned_view.compiler-owned-shared-view name))
      state
      (let
        [found : LintMaybePendingAssignment
          (lint-pending-assignment-find
            (owned_view.compiler-owned-shared-view state.pending)
            (owned_view.compiler-owned-shared-view name))]
        [next-findings : LintFindings
          (match found
            [(LintMaybePendingAssignment.No) state.findings]
            [(LintMaybePendingAssignment.Some pending)
              (lint-findings-add
                (lint-unused-assignment-finding
                  (owned_view.compiler-owned-shared-view name)
                  pending.span)
                (owned_view.compiler-owned-shared-view state.findings))])]
        (lint-unused-assignment-state-with
          (owned_view.compiler-owned-shared-view state)
          (lint-pending-assignment-add state.pending name span)
          next-findings)))))

(define (lint-unused-assignment-write-id
  [state : LintUnusedAssignmentState]
  [name : i64]
  [span : ast.AstSourceSpan]) : LintUnusedAssignmentState
  (lint-unused-assignment-write-name state (ci.intern-str name) span))

(define (lint-unused-assignment-clear-pending
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (lint-unused-assignment-state-with
    (owned_view.compiler-owned-shared-view state)
    (lint-pending-assignment-empty)
    state.findings))

(define (lint-unused-assignment-with-locals
  [state : LintUnusedAssignmentState]
  [locals : LintNameSet]) : LintUnusedAssignmentState
  (LintUnusedAssignmentState locals state.pending state.findings))

(define (lint-unused-assignment-note-reads-list
  [exprs : ast.AstExprList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (lint-unused-assignment-note-reads-list-at (& exprs) 0 state))

(define (lint-unused-assignment-note-reads-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (if (>= index exprs.len)
    state
    (lint-unused-assignment-note-reads-list-at
      exprs
      (+ index 1)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))
        state))))

(define (lint-unused-assignment-note-reads-let-bindings
  [bindings : ast.AstLetBindingList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (lint-unused-assignment-note-reads-let-bindings-at (& bindings) state 0))

(define (lint-unused-assignment-note-reads-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [state : LintUnusedAssignmentState]
  [index : i64]) : LintUnusedAssignmentState
  (if (>= index (ast.ast-let-binding-list-len bindings))
    state
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding _ _ init)
        (lint-unused-assignment-note-reads-let-bindings-at
          bindings
          (lint-unused-assignment-note-reads (ast.ast-node-get init) state)
          (+ index 1))])))

(define (lint-unused-assignment-note-reads-match-arms
  [arms : ast.AstMatchArmList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (lint-unused-assignment-note-reads-match-arms-at (& arms) state 0))

(define (lint-unused-assignment-note-reads-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [state : LintUnusedAssignmentState]
  [index : i64]) : LintUnusedAssignmentState
  (if (>= index arms.len)
    state
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm _ body)
        (lint-unused-assignment-note-reads-match-arms-at
          arms
          (lint-unused-assignment-note-reads (ast.ast-node-get body) state)
          (+ index 1))])))

(define (lint-unused-assignment-note-reads-resource-bindings
  [bindings : ast.AstResourceBindingList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (lint-unused-assignment-note-reads-resource-bindings-at (& bindings) state 0))

(define (lint-unused-assignment-note-reads-resource-bindings-at
  [bindings : (& bindings ast.AstResourceBindingList)]
  [state : LintUnusedAssignmentState]
  [index : i64]) : LintUnusedAssignmentState
  (if (>= index (ast.ast-resource-binding-list-len bindings))
    state
    (match (ast.ast-resource-binding-list-get
      bindings
      index
      (ast.ast-resource-binding-fallback))
      [(ast.AstResourceBinding.Binding _ init cleanup _)
        (lint-unused-assignment-note-reads-resource-bindings-at
          bindings
          (lint-unused-assignment-note-reads
            (ast.ast-node-get cleanup)
            (lint-unused-assignment-note-reads (ast.ast-node-get init) state))
          (+ index 1))])))

(define (lint-unused-assignment-note-reads
  [expr : ast.AstExpr]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner-box) state)]
    [(ast.AstExpr.MacroExpansion inner-box _ _)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner-box) state)]
    [(ast.AstExpr.Literal _) state]
    [(ast.AstExpr.Var name) (lint-unused-assignment-read-id state name)]
    [(ast.AstExpr.Binary _ left right)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get right)
        (lint-unused-assignment-note-reads (ast.ast-node-get left) state))]
    [(ast.AstExpr.Unary _ inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Call func args)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads-list
          args
          (lint-unused-assignment-note-reads (ast.ast-node-get func) state)))]
    [(ast.AstExpr.If cond then-branch else-branch)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast.ast-node-get else-branch)
          (lint-unused-assignment-note-reads
            (ast.ast-node-get then-branch)
            (lint-unused-assignment-note-reads (ast.ast-node-get cond) state))))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads
              (ast.ast-node-get body)
              (lint-unused-assignment-note-reads-let-bindings bindings state)))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda _ _ body)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads (ast.ast-node-get body) state))])]
    [(ast.AstExpr.Tuple exprs)
      (lint-unused-assignment-note-reads-list exprs state)]
    [(ast.AstExpr.TupleRef tuple _)
      (lint-unused-assignment-note-reads (ast.ast-node-get tuple) state)]
    [(ast.AstExpr.Array exprs)
      (lint-unused-assignment-note-reads-list exprs state)]
    [(ast.AstExpr.DynArray exprs)
      (lint-unused-assignment-note-reads-list exprs state)]
    [(ast.AstExpr.MakeArray _ len)
      (lint-unused-assignment-note-reads (ast.ast-node-get len) state)]
    [(ast.AstExpr.ArrayRef array index)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get index)
        (lint-unused-assignment-note-reads (ast.ast-node-get array) state))]
    [(ast.AstExpr.ArraySet array index value)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get value)
        (lint-unused-assignment-note-reads
          (ast.ast-node-get index)
          (lint-unused-assignment-note-reads (ast.ast-node-get array) state)))]
    [(ast.AstExpr.ArrayTake array live index)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get index)
        (lint-unused-assignment-note-reads
          (ast.ast-node-get live)
          (lint-unused-assignment-note-reads (ast.ast-node-get array) state)))]
    [(ast.AstExpr.FixedArrayTake array index)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get index)
        (lint-unused-assignment-note-reads (ast.ast-node-get array) state))]
    [(ast.AstExpr.Replace place replacement)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get replacement)
        (lint-unused-assignment-note-reads (ast.ast-node-get place) state))]
    [(ast.AstExpr.ArrayPush array value)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get value)
        (lint-unused-assignment-note-reads (ast.ast-node-get array) state))]
    [(ast.AstExpr.StringRef text index)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get index)
        (lint-unused-assignment-note-reads (ast.ast-node-get text) state))]
    [(ast.AstExpr.While cond body)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast.ast-node-get body)
          (lint-unused-assignment-note-reads (ast.ast-node-get cond) state)))]
    [(ast.AstExpr.ForOwnedState payload)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast.ast-node-get (ast.ast-for-owned-state-body (& payload)))
          (lint-unused-assignment-note-reads
            (ast.ast-node-get (ast.ast-for-owned-state-source (& payload)))
            state)))]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [source : i64 (ast.ast-for-owned-step-source-name (& payload))]
        [index : i64 (ast.ast-for-owned-step-index-name (& payload))]
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        [done : i64 (ast.ast-for-owned-step-done-name (& payload))]
        [body : i64 (ast.ast-for-owned-step-body (& payload))]
        (lint-unused-assignment-note-reads
          (ast.ast-node-get body)
          (lint-unused-assignment-note-reads
            (ast.ast-node-get done)
            (if (>= expected-type 0)
              (lint-unused-assignment-note-reads
                (ast.ast-node-get expected-type)
                (lint-unused-assignment-note-reads
                  (ast.ast-node-get index)
                  (lint-unused-assignment-note-reads
                    (ast.ast-node-get source)
                    state)))
              (lint-unused-assignment-note-reads
                (ast.ast-node-get index)
                (lint-unused-assignment-note-reads
                  (ast.ast-node-get source)
                  state))))))]
    [(ast.AstExpr.Begin exprs)
      (lint-unused-assignment-note-reads-list exprs state)]
    [(ast.AstExpr.Unsafe exprs)
      (lint-unused-assignment-note-reads-list exprs state)]
    [(ast.AstExpr.Set _ value)
      (lint-unused-assignment-note-reads (ast.ast-node-get value) state)]
    [(ast.AstExpr.Ann inner _)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Cast inner _)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Borrow _ _ place)
      (lint-unused-assignment-note-reads (ast.ast-node-get place) state)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads-match-arms
              arms
              (lint-unused-assignment-note-reads
                (ast.ast-node-get scrutinee)
                state)))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach _ _ start end body)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads
              (ast.ast-node-get body)
              (lint-unused-assignment-note-reads
                (ast.ast-node-get end)
                (lint-unused-assignment-note-reads
                  (ast.ast-node-get start)
                  state))))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce _ _ _ start end init value)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads
              (ast.ast-node-get value)
              (lint-unused-assignment-note-reads
                (ast.ast-node-get init)
                (lint-unused-assignment-note-reads
                  (ast.ast-node-get end)
                  (lint-unused-assignment-note-reads
                    (ast.ast-node-get start)
                    state)))))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(ast.AstSpmdScan.Scan _ _ _ start end _ _ init value body)
          (lint-unused-assignment-clear-pending
            (lint-unused-assignment-note-reads
              (ast.ast-node-get body)
              (lint-unused-assignment-note-reads
                (ast.ast-node-get value)
                (lint-unused-assignment-note-reads
                  (ast.ast-node-get init)
                  (lint-unused-assignment-note-reads
                    (ast.ast-node-get end)
                    (lint-unused-assignment-note-reads
                      (ast.ast-node-get start)
                      state))))))])]
    [(ast.AstExpr.SpmdBroadcast value lane)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get lane)
        (lint-unused-assignment-note-reads (ast.ast-node-get value) state))]
    [(ast.AstExpr.SpmdShuffle value lane)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get lane)
        (lint-unused-assignment-note-reads (ast.ast-node-get value) state))]
    [(ast.AstExpr.StructGet receiver _)
      (lint-unused-assignment-note-reads (ast.ast-node-get receiver) state)]
    [(ast.AstExpr.StructSet receiver _ value)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get value)
        (lint-unused-assignment-note-reads (ast.ast-node-get receiver) state))]
    [(ast.AstExpr.WithRegion _ body)
      (lint-unused-assignment-note-reads-list body state)]
    [(ast.AstExpr.WithEscape scratch body)
      (lint-unused-assignment-note-reads-list
        body
        (lint-unused-assignment-note-reads (ast.ast-node-get scratch) state))]
    [(ast.AstExpr.WithScratch body)
      (lint-unused-assignment-note-reads-list body state)]
    [(ast.AstExpr.InArena arena body)
      (lint-unused-assignment-note-reads-list
        body
        (lint-unused-assignment-note-reads (ast.ast-node-get arena) state))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-unused-assignment-note-reads-list
            body
            (lint-unused-assignment-note-reads-resource-bindings bindings state))])]
    [(ast.AstExpr.Box inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BoxGet inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BoxTake inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BoxSet inner value)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get value)
        (lint-unused-assignment-note-reads (ast.ast-node-get inner) state))]
    [(ast.AstExpr.TypeLiteral _) state]
    [(ast.AstExpr.Init _) state]
    [(ast.AstExpr.Comptime inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Quote _) state]
    [(ast.AstExpr.Quasiquote _) state]
    [(ast.AstExpr.Unquote inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.UnquoteSplicing inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BracketClause items)
      (lint-unused-assignment-note-reads-list items state)]
    [(ast.AstExpr.Try inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Return inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Break) state]
    [(ast.AstExpr.Continue) state]
    [(ast.AstExpr.PtrNull _) state]
    [(ast.AstExpr.PtrNullCheck inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.PtrAddrOf place)
      (lint-unused-assignment-note-reads (ast.ast-node-get place) state)]
    [(ast.AstExpr.PtrRead ptr)
      (lint-unused-assignment-note-reads (ast.ast-node-get ptr) state)]
    [(ast.AstExpr.PtrWrite ptr value)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get value)
        (lint-unused-assignment-note-reads (ast.ast-node-get ptr) state))]
    [(ast.AstExpr.PtrOffset ptr offset)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get offset)
        (lint-unused-assignment-note-reads (ast.ast-node-get ptr) state))]
    [(ast.AstExpr.PtrCast ptr _)
      (lint-unused-assignment-note-reads (ast.ast-node-get ptr) state)]
    [(ast.AstExpr.PtrToInt ptr)
      (lint-unused-assignment-note-reads (ast.ast-node-get ptr) state)]
    [(ast.AstExpr.IntToPtr value _)
      (lint-unused-assignment-note-reads (ast.ast-node-get value) state)]
    [(ast.AstExpr.StringData inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.StringFromBytes ptr len)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get len)
        (lint-unused-assignment-note-reads (ast.ast-node-get ptr) state))]
    [(ast.AstExpr.ArrayData inner)
      (lint-unused-assignment-note-reads (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BinaryData _) state]
    [(ast.AstExpr.SpmdProgramIndex) state]
    [(ast.AstExpr.SpmdProgramCount) state]
    [(ast.AstExpr.ProgramArgc) state]
    [(ast.AstExpr.ProgramArgv) state]
    [(ast.AstExpr.ProgramEnvp) state]
    [(ast.AstExpr.CpuIdEax leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.CpuIdEbx leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.CpuIdEcx leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.CpuIdEdx leaf subleaf)
      (lint-unused-assignment-note-reads
        (ast.ast-node-get subleaf)
        (lint-unused-assignment-note-reads (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.Xgetbv index)
      (lint-unused-assignment-note-reads (ast.ast-node-get index) state)]
    [(ast.AstExpr.Syscall args)
      (lint-unused-assignment-note-reads-list args state)]))

(define (lint-unused-assignment-binding-span [init : i64]) : ast.AstSourceSpan
  (lint-no-effect-span (ast.ast-node-get init)))

(define (lint-unused-assignment-expr-list
  [exprs : ast.AstExprList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (lint-unused-assignment-expr-list-after-terminal exprs state false))

(define (lint-unused-assignment-expr-list-after-terminal
  [exprs : ast.AstExprList]
  [state : LintUnusedAssignmentState]
  [after-terminal : bool]) : LintUnusedAssignmentState
  (lint-unused-assignment-expr-list-after-terminal-at
    (& exprs)
    0
    state
    after-terminal))

(define (lint-unused-assignment-expr-list-after-terminal-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [state : LintUnusedAssignmentState]
  [after-terminal : bool]) : LintUnusedAssignmentState
  (if (or after-terminal (>= index exprs.len))
    state
    (let
      [head-expr : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))]
      (lint-unused-assignment-expr-list-after-terminal-at
        exprs
        (+ index 1)
        (lint-unused-assignment-expr
          (owned_view.compiler-owned-shared-view head-expr)
          state
          (lint-no-span))
        (lint-terminal-expr? head-expr)))))

(define (lint-unused-assignment-let-bindings
  [bindings : ast.AstLetBindingList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (lint-unused-assignment-let-bindings-at (& bindings) state 0))

(define (lint-unused-assignment-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [state : LintUnusedAssignmentState]
  [index : i64]) : LintUnusedAssignmentState
  (if (>= index (ast.ast-let-binding-list-len bindings))
    state
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name _ init)
        (let
          [after-init : LintUnusedAssignmentState
            (lint-unused-assignment-expr
              (ast.ast-node-get init)
              state
              (lint-unused-assignment-binding-span init))]
          [text : String (ci.intern-str name)]
          [binding-base : LintUnusedAssignmentState
            (if (lint-name-set-contains?
              (owned_view.compiler-owned-shared-view after-init.locals)
              (owned_view.compiler-owned-shared-view text))
              (lint-unused-assignment-state-with
                (owned_view.compiler-owned-shared-view after-init)
                (lint-pending-assignment-remove
                  after-init.pending
                  (owned_view.compiler-owned-shared-view text))
                after-init.findings)
              after-init)]
          [with-local : LintUnusedAssignmentState
            (lint-unused-assignment-with-locals
              (owned_view.compiler-owned-shared-view binding-base)
              (lint-name-set-add
                binding-base.locals
                (owned_view.compiler-owned-shared-view text)))]
          (lint-unused-assignment-let-bindings-at
            bindings
            (lint-unused-assignment-write-name
              with-local
              text
              (lint-unused-assignment-binding-span init))
            (+ index 1)))])))

(define (lint-unused-assignment-let
  [bindings : ast.AstLetBindingList]
  [body : ast.AstExpr]
  [state : LintUnusedAssignmentState]
  [span : ast.AstSourceSpan]) : LintUnusedAssignmentState
  (let
    [inner : LintUnusedAssignmentState
      (lint-unused-assignment-expr
        body
        (lint-unused-assignment-let-bindings
          bindings
          (owned_view.compiler-owned-shared-view state))
        span)]
    (LintUnusedAssignmentState
      state.locals
      (lint-pending-assignment-empty)
      inner.findings)))

(define (lint-unused-assignment-expr
  [expr : ast.AstExpr]
  [state : LintUnusedAssignmentState]
  [span : ast.AstSourceSpan]) : LintUnusedAssignmentState
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box inner-span)
      (lint-unused-assignment-expr
        (ast.ast-node-get inner-box)
        state
        inner-span)]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-unused-assignment-let
            bindings
            (ast.ast-node-get body)
            state
            span)])]
    [(ast.AstExpr.Begin exprs) (lint-unused-assignment-expr-list exprs state)]
    [(ast.AstExpr.Unsafe exprs) (lint-unused-assignment-expr-list exprs state)]
    [(ast.AstExpr.WithRegion _ body)
      (lint-unused-assignment-expr-list body state)]
    [(ast.AstExpr.WithScratch body)
      (lint-unused-assignment-expr-list body state)]
    [(ast.AstExpr.WithEscape scratch body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads (ast.ast-node-get scratch) state))]
    [(ast.AstExpr.InArena arena body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads (ast.ast-node-get arena) state))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-unused-assignment-expr-list
            body
            (lint-unused-assignment-note-reads-resource-bindings bindings state))])]
    [(ast.AstExpr.Set target value)
      (lint-unused-assignment-write-id
        (lint-unused-assignment-note-reads (ast.ast-node-get value) state)
        target
        span)]
    [_ (lint-unused-assignment-note-reads expr state)]))

(define (lint-unused-assignment-state-empty
  [locals : LintNameSet]
  [acc : LintFindings]) : LintUnusedAssignmentState
  (LintUnusedAssignmentState locals (lint-pending-assignment-empty) acc))

(define (lint-unused-assignments-in-decl
  [decl : ast.AstDecl]
  [acc : LintFindings]) : LintFindings
  (match decl
    [(ast.AstDecl.Def decl-meta _ _ body)
      (__tl-project-field
        (lint-unused-assignment-expr
          (ast.ast-node-get body)
          (lint-unused-assignment-state-empty (lint-name-set-empty) acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.DefFn decl-meta _ params _ body _)
      (__tl-project-field
        (lint-unused-assignment-expr
          (ast.ast-node-get body)
          (lint-unused-assignment-state-empty
            (lint-param-list-add-locals params (lint-name-set-empty))
            acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.DefMacro decl-meta _ params _ body)
      (__tl-project-field
        (lint-unused-assignment-expr
          (ast.ast-node-get body)
          (lint-unused-assignment-state-empty
            (lint-macro-param-list-add-locals params (lint-name-set-empty))
            acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.Test _ body _)
      (__tl-project-field
        (lint-unused-assignment-expr
          (ast.ast-node-get body)
          (lint-unused-assignment-state-empty (lint-name-set-empty) acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.Unsafe inner)
      (lint-unused-assignments-in-decl
        (ast.ast-decl-box-shared-view
          (owned_view.compiler-owned-shared-view inner))
        acc)]
    [_ acc]))

(define (lint-unused-assignments-in-decl-list
  [decls : ast.AstDeclList]
  [acc : LintFindings]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) acc]
    [(ast.AstDeclListStep.Cons decl rest)
      (lint-unused-assignments-in-decl-list
        rest
        (lint-unused-assignments-in-decl decl acc))]))

(defstruct LintSourceNameSpan
  (span ast.AstSourceSpan)
  (next-index i64))

;; Source-coordinate lookups dominate lint time on large files when every
;; declaration and local binder scans from byte zero. Build one line-start
;; table for the active lint program, then use direct line lookup and binary
;; search for all span conversions. The array is rebuilt before every lint
;; walk, while the parsed file's scratch arena is active.
(define lint-source-line-starts : (__tl_dyn-array i64)
  (__tl_make-array i64 0))

(define (lint-source-line-index-build! [source : String]) : unit
  (let
    [source-len : i64 (string.string-length source)]
    [index : i64 0]
    [line-count : i64 1]
    (begin
      (while (< index source-len)
        (begin
          (if (= (string.string-ref source index) '\n')
            (set! line-count (+ line-count 1))
            unit)
          (set! index (+ index 1))))
      (let
        [starts : (__tl_dyn-array i64) (__tl_make-array i64 line-count)]
        [source-index : i64 0]
        [line-index : i64 1]
        (begin
          (set! (array-ref starts 0) 0)
          (while (< source-index source-len)
            (begin
              (if (= (string.string-ref source source-index) '\n')
                (begin
                  (set! (array-ref starts line-index) (+ source-index 1))
                  (set! line-index (+ line-index 1)))
                unit)
              (set! source-index (+ source-index 1))))
          (set! lint-source-line-starts starts))))))

(define (lint-source-line-start [line : i64]) : i64
  (if (or (<= line 0) (> line (array-length lint-source-line-starts)))
    (- 0 1)
    (array-ref lint-source-line-starts (- line 1))))

(define (lint-source-index-line-index [target : i64]) : i64
  (let
    [low : i64 0]
    [high : i64 (array-length lint-source-line-starts)]
    (begin
      (while (< low high)
        (let
          [mid : i64 (/ (+ low high) 2)]
          [start : i64 (array-ref lint-source-line-starts mid)]
          (if (<= start target)
            (set! low (+ mid 1))
            (set! high mid))))
      (- low 1))))

(defstruct LintUnusedVariableBinding
  (name String)
  (span ast.AstSourceSpan)
  (used bool)
  (reportable bool)
  (type-operand bool))

;; Scope bindings and the scope stack, both in reverse cons order: the newest
;; entry is the last slot, so every walk that consumed the old list head-first
;; counts down from `len - 1`. Frames are pushed and popped by a single
;; threaded state and each frame owns its bindings array, so appends reuse
;; spare capacity instead of rebuilding.
(defstruct LintUnusedVariableBindingList
  (slots (__tl_dyn-array LintUnusedVariableBinding))
  (len i64))

(defstruct LintUnusedVariableFrameList
  (slots (__tl_dyn-array LintUnusedVariableBindingList))
  (len i64))

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
  (findings LintFindings)
  (name-case bool)
  (report-unused bool))

(define (lint-unused-variable-bindings-empty) : LintUnusedVariableBindingList
  (LintUnusedVariableBindingList
    (__tl_make-array LintUnusedVariableBinding 0)
    0))

(define (lint-unused-variable-frames-empty) : LintUnusedVariableFrameList
  (LintUnusedVariableFrameList
    (__tl_make-array LintUnusedVariableBindingList 0)
    0))

;; Highest index of `bindings` naming `name`, or -1. Counting down keeps the
;; innermost-first order of the old cons walk.
(define (lint-unused-variable-binding-index
  [bindings : LintUnusedVariableBindingList]
  [name : String]
  [index : i64]) : i64
  (if (< index 0)
    (- 0 1)
    (if (string.eq
      (__tl-project-field (array-ref bindings.slots index) name)
      name)
      index
      (lint-unused-variable-binding-index bindings name (- index 1)))))

(define (lint-unused-unsafe-binding-list-contains?
  [bindings : LintUnusedVariableBindingList]
  [name : String]) : bool
  (>=
    (lint-unused-variable-binding-index
      (owned_view.compiler-owned-shared-view bindings)
      name
      (- bindings.len 1))
    0))

(define (lint-unused-unsafe-frame-list-contains-at?
  [frames : LintUnusedVariableFrameList]
  [name : String]
  [index : i64]) : bool
  (if (< index 0)
    false
    (or
      (lint-unused-unsafe-binding-list-contains?
        (owned_view.compiler-owned-array-element-shared-view frames.slots index)
        (owned_view.compiler-owned-shared-view name))
      (lint-unused-unsafe-frame-list-contains-at? frames name (- index 1)))))

(define (lint-unused-unsafe-frame-list-contains?
  [frames : LintUnusedVariableFrameList]
  [name : String]) : bool
  (lint-unused-unsafe-frame-list-contains-at?
    (owned_view.compiler-owned-shared-view frames)
    name
    (- frames.len 1)))

(define (lint-unused-unsafe-first-separator [name : String]) : i64
  (let
    [len : i64 (string.string-length name)]
    [index : i64 0]
    [found : i64 (- 0 1)]
    (begin
      (while (and (< found 0) (< index len))
        (let
          [ch : char (string.string-ref name index)]
          (if (or (= ch '.') (= ch '/'))
            (set! found index)
            (set! index (+ index 1)))))
      found)))

(define (lint-unused-unsafe-name-root [name : String]) : String
  (let
    [separator : i64
      (lint-unused-unsafe-first-separator
        (owned_view.compiler-owned-shared-view name))]
    (if (> separator 0)
      (string.substring name 0 separator)
      name)))

(define (lint-unused-unsafe-unknown-root-at?
  [name : String]
  [roots : LintUnusedUnsafeUnknownRoots]
  [index : i64]) : bool
  (if (>= index roots.len)
    false
    (or
      (string.eq (array-ref roots.slots index) name)
      (lint-unused-unsafe-unknown-root-at? name roots (+ index 1)))))

(define (lint-unused-unsafe-unknown-root?
  [name : String]
  [roots : LintUnusedUnsafeUnknownRoots]) : bool
  (lint-unused-unsafe-unknown-root-at? name roots 0))

(define (lint-unused-unsafe-exact-name-lookup-from
  [name : String]
  [facts : LintUnusedUnsafeExactNames]
  [found : bool]
  [requires-unsafe : bool]
  [index : i64]) : LintUnusedUnsafeExactLookup
  (if (< index facts.len)
    (let
      [fact : LintUnusedUnsafeExactName
        (owned_view.compiler-owned-array-element-shared-view facts.slots index)]
      (if (string.eq fact.name name)
        ;; A second declaration with the same visible name is conservatively
        ;; ambiguous even when both surfaces happen to have the same safety.
        (if found
          (LintUnusedUnsafeExactLookup.Unknown)
          (lint-unused-unsafe-exact-name-lookup-from
            name
            facts
            true
            fact.requires-unsafe
            (+ index 1)))
        (lint-unused-unsafe-exact-name-lookup-from
          name
          facts
          found
          requires-unsafe
          (+ index 1))))
    (if found
      (if requires-unsafe
        (LintUnusedUnsafeExactLookup.RequiresUnsafe)
        (LintUnusedUnsafeExactLookup.Safe))
      (LintUnusedUnsafeExactLookup.Unknown))))

(define (lint-unused-unsafe-exact-name-lookup
  [state : LintUnusedVariableState]
  [name : String]
  [facts : LintUnusedUnsafeExactNames]) : LintUnusedUnsafeExactLookup
  (let
    [root : String
      (lint-unused-unsafe-name-root
        (owned_view.compiler-owned-shared-view name))]
    [qualified : bool (not (string.eq root name))]
    (if (or
      (lint-unused-unsafe-frame-list-contains?
        state.frames
        (owned_view.compiler-owned-shared-view root))
      (and
        qualified
        (lint-unused-unsafe-unknown-root?
          root
          (global-shared-view lint-unused-unsafe-unknown-roots))))
      (LintUnusedUnsafeExactLookup.Unknown)
      (lint-unused-unsafe-exact-name-lookup-from name facts false false 0))))

(define (lint-unused-unsafe-note-value-name!
  [state : LintUnusedVariableState]
  [name : String]) : unit
  (match (lint-unused-unsafe-exact-name-lookup
    (owned_view.compiler-owned-shared-view state)
    (owned_view.compiler-owned-shared-view name)
    (global-shared-view lint-unused-unsafe-exact-names))
    [(LintUnusedUnsafeExactLookup.Unknown)
      (let
        [root : String
          (lint-unused-unsafe-name-root
            (owned_view.compiler-owned-shared-view name))]
        (if (and
          (string.eq root name)
          (lint-unused-unsafe-frame-list-contains? state.frames root))
          ;; Reading a lexical value cannot itself require unsafe. Calls through
          ;; lexical values are handled separately because their function type
          ;; is not represented in the compact declaration surface.
          unit
          (lint-unused-unsafe-block-mark-unknown!)))]
    [(LintUnusedUnsafeExactLookup.Safe) unit]
    [(LintUnusedUnsafeExactLookup.RequiresUnsafe)
      (lint-unused-unsafe-block-mark-required!)]))

(define (lint-unused-unsafe-note-call-target!
  [state : LintUnusedVariableState]
  [expr : ast.AstExpr]) : unit
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (lint-unused-unsafe-note-call-target! state (ast.ast-node-get inner-box))]
    [(ast.AstExpr.Var name-id)
      (let
        [name : String (ci.intern-str name-id)]
        [root : String
          (lint-unused-unsafe-name-root
            (owned_view.compiler-owned-shared-view name))]
        (if (and
          (string.eq root name)
          (lint-unused-unsafe-frame-list-contains? state.frames root))
          (lint-unused-unsafe-block-mark-unknown!)
          unit))]
    [_ unit]))

(define (lint-unused-unsafe-finish-state [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-state-with
    (owned_view.compiler-owned-shared-view state)
    state.frames
    (lint-unused-unsafe-block-pop-findings state.findings)))

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

(define (lint-source-find-prefix-backward-from
  [source : String]
  [needle : String]
  [idx : i64]) : i64
  (let
    [needle-len : i64 (string.string-length needle)]
    [last-start : i64 (- (string.string-length source) needle-len)]
    [cursor : i64
      (if (< idx last-start)
        idx
        last-start)]
    [found : i64 (- 0 1)]
    (begin
      (while (and (< found 0) (>= cursor 0))
        (if (lint-source-prefix-at?
          (owned_view.compiler-owned-shared-view source)
          cursor
          (owned_view.compiler-owned-shared-view needle))
          (set! found cursor)
          (set! cursor (- cursor 1))))
      found)))

(define (lint-source-symbol-boundary? [source : String] [idx : i64]) : bool
  (let
    [source-len : i64 (string.string-length source)]
    (if (< idx 0)
      true
      (if (>= idx source-len)
        true
        (not (lexer.is-symbol-char (string.string-ref source idx)))))))

(define (lint-source-name-at? [source : String] [idx : i64] [name : String]) : bool
  (let
    [end : i64 (+ idx (string.string-length name))]
    (and
      (lint-source-prefix-at?
        (owned_view.compiler-owned-shared-view source)
        idx
        name)
      (lint-source-symbol-boundary?
        (owned_view.compiler-owned-shared-view source)
        (- idx 1))
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
        (if (lint-source-name-at?
          (owned_view.compiler-owned-shared-view source)
          i
          (owned_view.compiler-owned-shared-view name))
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (lint-source-index-line [target : i64]) : i64
  (+ (lint-source-index-line-index target) 1))

(define (lint-source-index-col [target : i64]) : i64
  (let
    [line-index : i64 (lint-source-index-line-index target)]
    [start : i64 (array-ref lint-source-line-starts line-index)]
    (+ (- target start) 1)))

(define (lint-source-index-span
  [idx : i64]
  [width : i64]
  [fallback : ast.AstSourceSpan]) : ast.AstSourceSpan
  (if (< idx 0)
    fallback
    (let
      [line : i64 (lint-source-index-line idx)]
      [col : i64 (lint-source-index-col idx)]
      (ast.ast-source-span line col line (+ col width)))))

(define (lint-source-span-start-index
  [source : String]
  [span : ast.AstSourceSpan]) : i64
  (let
    [target-line : i64 (ast.ast-source-span-start-line span)]
    [target-col : i64 (ast.ast-source-span-start-col span)]
    [source-len : i64 (string.string-length source)]
    [line-start : i64 (lint-source-line-start target-line)]
    [next-line-start : i64 (lint-source-line-start (+ target-line 1))]
    [candidate : i64 (+ line-start (- target-col 1))]
    (if (or
      (< line-start 0)
      (<= target-col 0)
      (< candidate 0)
      (>= candidate source-len)
      (and (>= next-line-start 0) (>= candidate next-line-start)))
      (- 0 1)
      candidate)))

(define (lint-source-name-span-from
  [source : String]
  [name : String]
  [cursor : i64]
  [fallback : ast.AstSourceSpan]) : LintSourceNameSpan
  (let
    [found : i64
      (lint-source-find-name-from
        source
        (owned_view.compiler-owned-shared-view name)
        cursor)]
    [width : i64 (string.string-length name)]
    (if (< found 0)
      (LintSourceNameSpan fallback cursor)
      (LintSourceNameSpan
        (lint-source-index-span found width fallback)
        (+ found width)))))

(define (lint-source-name-span-between
  [source : String]
  [name : String]
  [cursor : i64]
  [limit : i64]) : LintSourceNameSpan
  (let
    [found : i64
      (lint-source-find-name-from
        source
        (owned_view.compiler-owned-shared-view name)
        cursor)]
    [width : i64 (string.string-length name)]
    (if (or (< found 0) (>= found limit))
      (LintSourceNameSpan (lint-no-span) cursor)
      (LintSourceNameSpan
        (lint-source-index-span found width (lint-no-span))
        (+ found width)))))

(defstruct LintNameCasePatternScan
  (findings LintFindings)
  (next-index i64))

(defstruct LintNameCaseLocalScan
  (state LintUnusedVariableState)
  (next-index i64))

(define (lint-unused-variable-scan-local-name
  [state : LintUnusedVariableState]
  [name : String]
  [cursor : i64]
  [limit : i64]) : LintNameCaseLocalScan
  (let
    [found : LintSourceNameSpan
      (lint-source-name-span-between
        (owned_view.compiler-owned-shared-view state.source)
        (owned_view.compiler-owned-shared-view name)
        cursor
        limit)]
    (LintNameCaseLocalScan
      (lint-unused-variable-add-local-name-case
        (owned_view.compiler-owned-shared-view state)
        name
        found.span)
      found.next-index)))

(define (lint-unused-variable-scan-form-local-name
  [state : LintUnusedVariableState]
  [name : String]
  [span : ast.AstSourceSpan]
  [form-head : String]) : LintNameCaseLocalScan
  (let
    [start : i64
      (lint-source-span-start-index
        (owned_view.compiler-owned-shared-view state.source)
        span)]
    [limit : i64
      (lint-source-span-end-index
        (owned_view.compiler-owned-shared-view state.source)
        span)]
    (if (or (< start 0) (< limit 0))
      (LintNameCaseLocalScan (owned_view.compiler-owned-shared-view state) 0)
      (lint-unused-variable-scan-local-name
        state
        name
        (+ start (string.string-length form-head))
        limit))))

(define (lint-name-case-pattern-add
  [source : String]
  [name : String]
  [cursor : i64]
  [limit : i64]
  [findings : LintFindings]
  [report : bool]) : LintNameCasePatternScan
  (let
    [found : LintSourceNameSpan
      (lint-source-name-span-between
        source
        (owned_view.compiler-owned-shared-view name)
        cursor
        limit)]
    [span : ast.AstSourceSpan found.span]
    [next : LintFindings
      (if (and
        report
        (lint-name-case-source-span? span)
        (not
          (lint-name-case-qualified-symbol?
            (owned_view.compiler-owned-shared-view name)))
        (not
          (lint-name-case-local-kebab?
            (owned_view.compiler-owned-shared-view name))))
        (lint-findings-add (lint-local-name-case-finding name span) findings)
        findings)]
    (LintNameCasePatternScan next found.next-index)))

(define (lint-name-case-pattern-list
  [patterns : ast.AstPatternList]
  [source : String]
  [cursor : i64]
  [limit : i64]
  [findings : LintFindings]) : LintNameCasePatternScan
  (lint-name-case-pattern-list-at (& patterns) source cursor limit findings 0))

(define (lint-name-case-pattern-list-at
  [patterns : (& patterns ast.AstPatternList)]
  [source : String]
  [cursor : i64]
  [limit : i64]
  [findings : LintFindings]
  [index : i64]) : LintNameCasePatternScan
  (if (>= index patterns.len)
    (LintNameCasePatternScan findings cursor)
    (let
      [scanned : LintNameCasePatternScan
        (lint-name-case-pattern
          (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
          (owned_view.compiler-owned-shared-view source)
          cursor
          limit
          findings)]
      (lint-name-case-pattern-list-at
        patterns
        source
        scanned.next-index
        limit
        scanned.findings
        (+ index 1)))))

(define (lint-name-case-pattern
  [pattern : ast.AstPattern]
  [source : String]
  [cursor : i64]
  [limit : i64]
  [findings : LintFindings]) : LintNameCasePatternScan
  (match pattern
    [(ast.AstPattern.Var name _)
      (lint-name-case-pattern-add
        source
        (ci.intern-str name)
        cursor
        limit
        findings
        true)]
    [(ast.AstPattern.Binding name)
      (lint-name-case-pattern-add
        source
        (ci.intern-str name)
        cursor
        limit
        findings
        true)]
    [(ast.AstPattern.Tuple items)
      (lint-name-case-pattern-list
        (owned_view.compiler-owned-box-shared-view items)
        source
        cursor
        limit
        findings)]
    [(ast.AstPattern.Array items)
      (lint-name-case-pattern-list
        (owned_view.compiler-owned-box-shared-view items)
        source
        cursor
        limit
        findings)]
    [(ast.AstPattern.Variant name items)
      (let
        [variant : LintNameCasePatternScan
          (lint-name-case-pattern-add
            (owned_view.compiler-owned-shared-view source)
            (ci.intern-str name)
            cursor
            limit
            findings
            false)]
        (lint-name-case-pattern-list
          (owned_view.compiler-owned-box-shared-view items)
          source
          variant.next-index
          limit
          variant.findings))]
    [(ast.AstPattern.Wildcard) (LintNameCasePatternScan findings cursor)]
    [(ast.AstPattern.Literal _) (LintNameCasePatternScan findings cursor)]))

;; A bare match-arm symbol is syntactically ambiguous until typechecking: it
;; may be a nullary enum variant. Skip that root spelling, while constructor
;; payload patterns and nested tuple positions remain definite binder slots.
(define (lint-name-case-match-pattern
  [pattern : ast.AstPattern]
  [source : String]
  [cursor : i64]
  [limit : i64]
  [findings : LintFindings]) : LintNameCasePatternScan
  (match (owned_view.compiler-owned-shared-view pattern)
    [(ast.AstPattern.Binding name)
      (lint-name-case-pattern-add
        source
        (ci.intern-str name)
        cursor
        limit
        findings
        false)]
    [_ (lint-name-case-pattern pattern source cursor limit findings)]))

(defstruct LintNameCaseDeclState
  (source String)
  (cursor i64)
  (findings LintFindings))

(define (lint-name-case-space? [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

(define (lint-name-case-skip-space-comments [source : String] [start : i64]) : i64
  (let
    [n : i64 (string.string-length source)]
    [index : i64 start]
    [again : bool true]
    (begin
      (while (and again (< index n))
        (begin
          (set! again false)
          (while (and
            (< index n)
            (lint-name-case-space? (string.string-ref source index)))
            (set! index (+ index 1)))
          (if (and (< index n) (= (string.string-ref source index) ';'))
            (begin
              (while (and
                (< index n)
                (not (= (string.string-ref source index) '\n')))
                (set! index (+ index 1)))
              (set! again true))
            unit)))
      index)))

(define (lint-name-case-skip-line [source : String] [start : i64]) : i64
  (let
    [n : i64 (string.string-length source)]
    [index : i64 start]
    (begin
      (while (and (< index n) (not (= (string.string-ref source index) '\n')))
        (set! index (+ index 1)))
      index)))

(define (lint-name-case-skip-quoted
  [source : String]
  [start : i64]
  [delimiter : char]) : i64
  (let
    [n : i64 (string.string-length source)]
    [index : i64 (+ start 1)]
    [done : bool false]
    (begin
      (while (and (< index n) (not done))
        (let
          [c : char (string.string-ref source index)]
          (cond
            [(= c '\\') (set! index (+ index 2))]
            [(= c delimiter)
              (begin
                (set! index (+ index 1))
                (set! done true))]
            [else (set! index (+ index 1))])))
      index)))

;; Find a form head in source code, excluding text in comments and literals.
(define (lint-name-case-find-code-prefix-from
  [source : String]
  [needle : String]
  [start : i64]) : i64
  (let
    [n : i64 (string.string-length source)]
    [index : i64 start]
    [found : i64 (- 0 1)]
    (begin
      (while (and (< found 0) (< index n))
        (let
          [c : char (string.string-ref source index)]
          (cond
            [(= c ';')
              (set!
                index
                (lint-name-case-skip-line
                  (owned_view.compiler-owned-shared-view source)
                  index))]
            [(= c '"')
              (set!
                index
                (lint-name-case-skip-quoted
                  (owned_view.compiler-owned-shared-view source)
                  index
                  '"'))]
            [(= c '\'')
              (set!
                index
                (lint-name-case-skip-quoted
                  (owned_view.compiler-owned-shared-view source)
                  index
                  '\''))]
            [(lint-source-prefix-at?
                (owned_view.compiler-owned-shared-view source)
                index
                (owned_view.compiler-owned-shared-view needle))
              (set! found index)]
            [else (set! index (+ index 1))])))
      found)))

(define (lint-name-case-find-decl-name-from
  [source : String]
  [cursor : i64]
  [form : String]
  [name : String]
  [function-head : bool]) : LintSourceNameSpan
  (let
    [needle : String (str_cat.str-cat "(" form)]
    [n : i64 (string.string-length source)]
    [search : i64 cursor]
    [found : i64 (- 0 1)]
    (begin
      (while (and (< found 0) (< search n))
        (let
          [form-index : i64
            (lint-name-case-find-code-prefix-from
              (owned_view.compiler-owned-shared-view source)
              (owned_view.compiler-owned-shared-view needle)
              search)]
          (if (< form-index 0)
            (set! search n)
            (let
              [after-form : i64
                (lint-name-case-skip-space-comments
                  (owned_view.compiler-owned-shared-view source)
                  (+ form-index (string.string-length needle)))]
              [name-index : i64
                (if function-head
                  (if (and
                    (< after-form n)
                    (= (string.string-ref source after-form) '('))
                    (lint-name-case-skip-space-comments
                      (owned_view.compiler-owned-shared-view source)
                      (+ after-form 1))
                    (- 0 1))
                  (if (and
                    (< after-form n)
                    (= (string.string-ref source after-form) '('))
                    (- 0 1)
                    after-form))]
              (if (and
                (>= name-index 0)
                (lint-source-name-at?
                  (owned_view.compiler-owned-shared-view source)
                  name-index
                  (owned_view.compiler-owned-shared-view name)))
                (set! found name-index)
                (set! search (+ form-index 1)))))))
      (if (< found 0)
        (LintSourceNameSpan (lint-no-span) cursor)
        (LintSourceNameSpan
          (lint-source-index-span
            found
            (string.string-length name)
            (lint-no-span))
          (+ found (string.string-length name)))))))

(define (lint-name-case-decl-state-add
  [state : LintNameCaseDeclState]
  [form : String]
  [name : String]
  [function-head : bool]
  [kind : i64]) : LintNameCaseDeclState
  (let
    [found : LintSourceNameSpan
      (lint-name-case-find-decl-name-from
        (owned_view.compiler-owned-shared-view state.source)
        state.cursor
        form
        (owned_view.compiler-owned-shared-view name)
        function-head)]
    [span : ast.AstSourceSpan found.span]
    [valid : bool
      (cond
        [(= kind 0)
          (lint-name-case-kebab? (owned_view.compiler-owned-shared-view name))]
        [(= kind 1)
          (lint-name-case-kebab? (owned_view.compiler-owned-shared-view name))]
        [else
          (lint-name-case-upper-camel?
            (owned_view.compiler-owned-shared-view name))])]
    [next : LintFindings
      (if (or (not (lint-name-case-source-span? span)) valid)
        state.findings
        (lint-findings-add
          (cond
            [(= kind 0) (lint-global-name-case-finding name span)]
            [(= kind 1) (lint-function-name-case-finding name span)]
            [else (lint-type-name-case-finding name span)])
          state.findings))]
    (LintNameCaseDeclState state.source found.next-index next)))

(define (lint-name-case-decl-state-after-body
  [state : LintNameCaseDeclState]
  [body : i64]) : LintNameCaseDeclState
  (let
    [end : i64
      (lint-source-span-end-index
        (owned_view.compiler-owned-shared-view state.source)
        (lint-no-effect-span (ast.ast-node-get body)))]
    (if (> end state.cursor)
      (LintNameCaseDeclState state.source end state.findings)
      state)))

(define (lint-name-case-in-decl
  [decl : ast.AstDecl]
  [state : LintNameCaseDeclState]) : LintNameCaseDeclState
  (match decl
    [(ast.AstDecl.Def decl-meta name _ body)
      (lint-name-case-decl-state-after-body
        (lint-name-case-decl-state-add
          state
          "define"
          (ci.intern-str name)
          false
          0)
        body)]
    [(ast.AstDecl.DefFn decl-meta name _ _ body _)
      (lint-name-case-decl-state-after-body
        (lint-name-case-decl-state-add
          state
          "define"
          (ci.intern-str name)
          true
          1)
        body)]
    [(ast.AstDecl.DefMacro decl-meta name _ _ body)
      (lint-name-case-decl-state-after-body
        (lint-name-case-decl-state-add
          state
          "defmacro"
          (ci.intern-str name)
          true
          1)
        body)]
    [(ast.AstDecl.DefDispatch decl-meta name _)
      (lint-name-case-decl-state-add
        state
        "defdispatch"
        (ci.intern-str name)
        false
        1)]
    [(ast.AstDecl.DefStruct decl-meta name _ _ _)
      (lint-name-case-decl-state-add
        state
        "defstruct"
        (ci.intern-str name)
        false
        2)]
    [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ _ _)
      (lint-name-case-decl-state-add
        state
        "defstruct"
        (ci.intern-str name)
        false
        2)]
    [(ast.AstDecl.DefEnum decl-meta name _ _)
      (lint-name-case-decl-state-add
        state
        "defenum"
        (ci.intern-str name)
        false
        2)]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name _ _ _)
      (lint-name-case-decl-state-add
        state
        "defenum"
        (ci.intern-str name)
        false
        2)]
    [(ast.AstDecl.ModuleBody _ body)
      (lint-name-case-in-decl-list
        (ast.ast-decl-list-box-shared-view
          (owned_view.compiler-owned-shared-view body))
        state)]
    [(ast.AstDecl.Unsafe inner)
      (lint-name-case-in-decl
        (ast.ast-decl-box-shared-view
          (owned_view.compiler-owned-shared-view inner))
        state)]
    [_ state]))

(define (lint-name-case-in-decl-list
  [decls : ast.AstDeclList]
  [state : LintNameCaseDeclState]) : LintNameCaseDeclState
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) state]
    [(ast.AstDeclListStep.Cons decl rest)
      (lint-name-case-in-decl-list rest (lint-name-case-in-decl decl state))]))

(define (lint-name-case-in-decls
  [source : String]
  [decls : ast.AstDeclList]
  [acc : LintFindings]) : LintFindings
  (__tl-project-field
    (lint-name-case-in-decl-list decls (LintNameCaseDeclState source 0 acc))
    findings))

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
    state.source
    module-name
    state.cursor
    state.findings))

(define (lint-redundant-function-name-state-with-results
  [state : LintRedundantFunctionNameState]
  [cursor : i64]
  [findings : LintFindings]) : LintRedundantFunctionNameState
  (lint-redundant-function-name-state
    state.source
    state.module-name
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
      (lint-redundant-function-module-prefix-at?
        (owned_view.compiler-owned-shared-view name)
        module-name
        0)
      (= (string.string-ref name module-len) '-'))))

(define (lint-redundant-function-name-add
  [state : LintRedundantFunctionNameState]
  [name : String]
  [fallback : ast.AstSourceSpan]) : LintRedundantFunctionNameState
  (let
    [module-name : String state.module-name]
    (if (lint-redundant-function-name?
      (owned_view.compiler-owned-shared-view module-name)
      (owned_view.compiler-owned-shared-view name))
      (let
        [found : LintSourceNameSpan
          (lint-source-name-span-from
            (owned_view.compiler-owned-shared-view state.source)
            (owned_view.compiler-owned-shared-view name)
            state.cursor
            fallback)]
        (lint-redundant-function-name-state-with-results
          (owned_view.compiler-owned-shared-view state)
          found.next-index
          (lint-findings-add
            (lint-redundant-function-name-finding module-name name found.span)
            state.findings)))
      state)))

(define (lint-redundant-function-name-callee [expr : ast.AstExpr]) : String
  (match (ast.ast-expr-unspan expr)
    [(ast.AstExpr.Var name) (ci.intern-str name)]
    [_ ""]))

(define (lint-redundant-function-name-generated-head [args : ast.AstExprList]) : String
  (if (= args.len 0)
    ""
    (match (ast.ast-expr-unspan
      (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0)))
      [(ast.AstExpr.Call fn-head _)
        (lint-redundant-function-name-callee (ast.ast-node-get fn-head))]
      [_ ""])))

(define (lint-redundant-function-name-literal-module [args : ast.AstExprList]) : String
  (if (= args.len 0)
    ""
    (match (ast.ast-expr-unspan
      (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0)))
      [(ast.AstExpr.Var name) (lint-module-default-alias (ci.intern-str name))]
      [_ ""])))

(define (lint-redundant-function-name-quoted-expr-list
  [exprs : ast.AstExprList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (lint-redundant-function-name-quoted-expr-list-at (& exprs) 0 state))

(define (lint-redundant-function-name-quoted-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (if (>= index exprs.len)
    state
    (lint-redundant-function-name-quoted-expr-list-at
      exprs
      (+ index 1)
      (lint-redundant-function-name-quoted-expr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))
        state))))

(define (lint-redundant-function-name-macro-expr-list
  [exprs : ast.AstExprList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (lint-redundant-function-name-macro-expr-list-at (& exprs) 0 state))

(define (lint-redundant-function-name-macro-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (if (>= index exprs.len)
    state
    (lint-redundant-function-name-macro-expr-list-at
      exprs
      (+ index 1)
      (lint-redundant-function-name-macro-expr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))
        state))))

(define (lint-redundant-function-name-quoted-call
  [callee : String]
  [args : ast.AstExprList]
  [span : ast.AstSourceSpan]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (cond
    [(string.eq callee "module")
      (let
        [module-name : String
          (lint-redundant-function-name-literal-module
            (owned_view.compiler-owned-shared-view args))]
        (if (string.eq module-name "")
          (lint-redundant-function-name-quoted-expr-list args state)
          (lint-redundant-function-name-quoted-expr-list
            args
            (lint-redundant-function-name-state-with-module state module-name))))]
    [(or (string.eq callee "define") (string.eq callee "defmacro"))
      (lint-redundant-function-name-quoted-expr-list
        (owned_view.compiler-owned-shared-view args)
        (lint-redundant-function-name-add
          state
          (lint-redundant-function-name-generated-head args)
          span))]
    [else (lint-redundant-function-name-quoted-expr-list args state)]))

(define (lint-redundant-function-name-quoted-expr
  [expr : ast.AstExpr]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match expr
    [(ast.AstExpr.Spanned inner span)
      (match (ast.ast-node-get inner)
        [(ast.AstExpr.Call func args)
          (lint-redundant-function-name-quoted-call
            (lint-redundant-function-name-callee (ast.ast-node-get func))
            args
            span
            state)]
        [_
          (lint-redundant-function-name-quoted-expr
            (ast.ast-node-get inner)
            state)])]
    [(ast.AstExpr.Call func args)
      (lint-redundant-function-name-quoted-call
        (lint-redundant-function-name-callee (ast.ast-node-get func))
        args
        (lint-no-span)
        state)]
    [(ast.AstExpr.Begin exprs)
      (lint-redundant-function-name-quoted-expr-list exprs state)]
    [(ast.AstExpr.Unsafe exprs)
      (lint-redundant-function-name-quoted-expr-list exprs state)]
    [(ast.AstExpr.If cond then-branch else-branch)
      (lint-redundant-function-name-quoted-expr
        (ast.ast-node-get else-branch)
        (lint-redundant-function-name-quoted-expr
          (ast.ast-node-get then-branch)
          (lint-redundant-function-name-quoted-expr
            (ast.ast-node-get cond)
            state)))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let _ body)
          (lint-redundant-function-name-quoted-expr
            (ast.ast-node-get body)
            state)])]
    [(ast.AstExpr.Quote inner)
      (lint-redundant-function-name-quoted-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Quasiquote inner)
      (lint-redundant-function-name-quoted-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Unquote _) state]
    [(ast.AstExpr.UnquoteSplicing _) state]
    [_ state]))

(define (lint-redundant-function-name-macro-expr
  [expr : ast.AstExpr]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (lint-redundant-function-name-macro-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Quote inner)
      (lint-redundant-function-name-quoted-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Quasiquote inner)
      (lint-redundant-function-name-quoted-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Call func args)
      (lint-redundant-function-name-macro-expr-list
        args
        (lint-redundant-function-name-macro-expr (ast.ast-node-get func) state))]
    [(ast.AstExpr.If cond then-branch else-branch)
      (lint-redundant-function-name-macro-expr
        (ast.ast-node-get else-branch)
        (lint-redundant-function-name-macro-expr
          (ast.ast-node-get then-branch)
          (lint-redundant-function-name-macro-expr
            (ast.ast-node-get cond)
            state)))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-redundant-function-name-macro-expr
            (ast.ast-node-get body)
            (lint-redundant-function-name-macro-let-bindings bindings state))])]
    [(ast.AstExpr.Begin exprs)
      (lint-redundant-function-name-macro-expr-list exprs state)]
    [(ast.AstExpr.Unsafe exprs)
      (lint-redundant-function-name-macro-expr-list exprs state)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (lint-redundant-function-name-macro-match-arms
            arms
            (lint-redundant-function-name-macro-expr
              (ast.ast-node-get scrutinee)
              state))])]
    [_ state]))

(define (lint-redundant-function-name-macro-let-bindings
  [bindings : ast.AstLetBindingList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (lint-redundant-function-name-macro-let-bindings-at (& bindings) state 0))

(define (lint-redundant-function-name-macro-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [state : LintRedundantFunctionNameState]
  [index : i64]) : LintRedundantFunctionNameState
  (if (>= index (ast.ast-let-binding-list-len bindings))
    state
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding _ _ init)
        (lint-redundant-function-name-macro-let-bindings-at
          bindings
          (lint-redundant-function-name-macro-expr
            (ast.ast-node-get init)
            state)
          (+ index 1))])))

(define (lint-redundant-function-name-macro-match-arms
  [arms : ast.AstMatchArmList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (lint-redundant-function-name-macro-match-arms-at (& arms) state 0))

(define (lint-redundant-function-name-macro-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [state : LintRedundantFunctionNameState]
  [index : i64]) : LintRedundantFunctionNameState
  (if (>= index arms.len)
    state
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm _ body)
        (lint-redundant-function-name-macro-match-arms-at
          arms
          (lint-redundant-function-name-macro-expr
            (ast.ast-node-get body)
            state)
          (+ index 1))])))

(define (lint-redundant-function-name-decl
  [decl : ast.AstDecl]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match decl
    [(ast.AstDecl.Module name)
      (lint-redundant-function-name-state-with-module
        state
        (lint-module-default-alias (ci.intern-str name)))]
    [(ast.AstDecl.DefFn decl-meta name _ _ body _)
      (lint-redundant-function-name-add
        state
        (ci.intern-qualified-base name)
        (lint-no-effect-span (ast.ast-node-get body)))]
    [(ast.AstDecl.DefMacro decl-meta name _ _ body)
      (lint-redundant-function-name-macro-expr
        (ast.ast-node-get body)
        (lint-redundant-function-name-add
          state
          (ci.intern-qualified-base name)
          (lint-no-effect-span (ast.ast-node-get body))))]
    [(ast.AstDecl.Unsafe inner)
      (lint-redundant-function-name-decl
        (owned_view.compiler-owned-box-shared-view inner)
        state)]
    [_ state]))

(define (lint-redundant-function-names-in-decl-list-state
  [decls : ast.AstDeclList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) state]
    [(ast.AstDeclListStep.Cons decl rest)
      (lint-redundant-function-names-in-decl-list-state
        rest
        (lint-redundant-function-name-decl decl state))]))

(define (lint-redundant-function-names-in-decl-list
  [source : String]
  [decls : ast.AstDeclList]
  [acc : LintFindings]) : LintFindings
  (__tl-project-field
    (lint-redundant-function-names-in-decl-list-state
      decls
      (lint-redundant-function-name-state source "" 0 acc))
    findings))

(define (lint-redundant-function-names-in-program
  [source : String]
  [program : ast.AstProgram]
  [acc : LintFindings]) : LintFindings
  (match program
    [(ast.AstProgram.Program decls-box)
      (lint-redundant-function-names-in-decl-list
        source
        (ast.ast-decl-list-box-shared-view
          (owned_view.compiler-owned-shared-view decls-box))
        acc)]))

(define (lint-unused-variable-binding
  [name : String]
  [span : ast.AstSourceSpan]
  [reportable : bool]
  [type-operand : bool]) : LintUnusedVariableBinding
  (LintUnusedVariableBinding name span false reportable type-operand))

(define (lint-unused-variable-binding-push
  [bindings : LintUnusedVariableBindingList]
  [binding : LintUnusedVariableBinding]) : LintUnusedVariableBindingList
  (let
    [n : i64 bindings.len]
    [slots : (__tl_dyn-array LintUnusedVariableBinding) bindings.slots]
    (begin
      (if (< n (array-length slots))
        unit
        (let
          [bigger : (__tl_dyn-array LintUnusedVariableBinding)
            (__tl_make-array
              LintUnusedVariableBinding
              (lint-grown-capacity (array-length slots)))]
          [index : i64 0]
          (begin
            (while (< index n)
              (begin
                (set! (array-ref bigger index) (array-ref slots index))
                (set! index (+ index 1))))
            (set! slots bigger))))
      (set! (array-ref slots n) binding)
      (LintUnusedVariableBindingList slots (+ n 1)))))

(define (lint-unused-variable-frame-push
  [frames : LintUnusedVariableFrameList]
  [bindings : LintUnusedVariableBindingList]) : LintUnusedVariableFrameList
  (let
    [n : i64 frames.len]
    [slots : (__tl_dyn-array LintUnusedVariableBindingList) frames.slots]
    (begin
      (if (< n (array-length slots))
        unit
        (let
          [bigger : (__tl_dyn-array LintUnusedVariableBindingList)
            (__tl_make-array
              LintUnusedVariableBindingList
              (lint-grown-capacity (array-length slots)))]
          [index : i64 0]
          (begin
            (while (< index n)
              (begin
                (set! (array-ref bigger index) (array-ref slots index))
                (set! index (+ index 1))))
            (set! slots bigger))))
      (set! (array-ref slots n) bindings)
      (LintUnusedVariableFrameList slots (+ n 1)))))

(define (lint-unused-variable-state-with
  [state : LintUnusedVariableState]
  [frames : LintUnusedVariableFrameList]
  [findings : LintFindings]) : LintUnusedVariableState
  (LintUnusedVariableState
    state.source
    frames
    findings
    state.name-case
    state.report-unused))

(define (lint-name-case-source-span? [span : ast.AstSourceSpan]) : bool
  (and
    (> (ast.ast-source-span-start-line span) 0)
    (> (ast.ast-source-span-start-col span) 0)))

(define (lint-unused-variable-add-local-name-case
  [state : LintUnusedVariableState]
  [name : String]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (if (and
    state.name-case
    (lint-name-case-source-span? span)
    (not
      (lint-name-case-local-kebab? (owned_view.compiler-owned-shared-view name))))
    (lint-unused-variable-state-with
      (owned_view.compiler-owned-shared-view state)
      state.frames
      (lint-findings-add
        (lint-local-name-case-finding name span)
        state.findings))
    state))

(define (lint-unused-variable-add-binding-name-case
  [state : LintUnusedVariableState]
  [binding : LintUnusedVariableBinding]) : LintUnusedVariableState
  (let
    [name : String binding.name]
    [type-operand : bool binding.type-operand]
    [valid : bool
      (if type-operand
        (lint-name-case-type-operand?
          (owned_view.compiler-owned-shared-view name))
        (lint-name-case-local-kebab?
          (owned_view.compiler-owned-shared-view name)))]
    (if (and
      state.name-case
      (lint-name-case-source-span? binding.span)
      (not valid))
      (lint-unused-variable-state-with
        (owned_view.compiler-owned-shared-view state)
        state.frames
        (lint-findings-add
          (lint-local-name-case-finding name binding.span)
          state.findings))
      state)))

(define (lint-unused-variable-add-binding-name-cases-at
  [state : LintUnusedVariableState]
  [bindings : LintUnusedVariableBindingList]
  [index : i64]) : LintUnusedVariableState
  (if (< index 0)
    state
    (let
      [binding : LintUnusedVariableBinding
        (owned_view.compiler-owned-array-element-shared-view
          bindings.slots
          index)]
      (lint-unused-variable-add-binding-name-cases-at
        (lint-unused-variable-add-binding-name-case state binding)
        bindings
        (- index 1)))))

(define (lint-unused-variable-add-binding-name-cases
  [state : LintUnusedVariableState]
  [bindings : LintUnusedVariableBindingList]) : LintUnusedVariableState
  (lint-unused-variable-add-binding-name-cases-at
    state
    (owned_view.compiler-owned-shared-view bindings)
    (- bindings.len 1)))

(define (lint-unused-variable-binding-mark-used
  [binding : LintUnusedVariableBinding]) : LintUnusedVariableBinding
  (LintUnusedVariableBinding
    binding.name
    binding.span
    true
    binding.reportable
    binding.type-operand))

(define (lint-unused-variable-mark-bindings
  [bindings : LintUnusedVariableBindingList]
  [name : String]) : LintUnusedVariableMarkBindingsResult
  (let
    [found : i64
      (lint-unused-variable-binding-index
        (owned_view.compiler-owned-shared-view bindings)
        name
        (- bindings.len 1))]
    (if (< found 0)
      (LintUnusedVariableMarkBindingsResult bindings false)
      (begin
        (set!
          (array-ref bindings.slots found)
          (lint-unused-variable-binding-mark-used
            (owned_view.compiler-owned-array-element-shared-view
              bindings.slots
              found)))
        (LintUnusedVariableMarkBindingsResult bindings true)))))

(define (lint-unused-variable-mark-frames-at
  [frames : LintUnusedVariableFrameList]
  [name : String]
  [index : i64]) : LintUnusedVariableMarkFramesResult
  (if (< index 0)
    (LintUnusedVariableMarkFramesResult frames false)
    (let
      [marked : LintUnusedVariableMarkBindingsResult
        (lint-unused-variable-mark-bindings
          (owned_view.compiler-owned-array-element-shared-view
            frames.slots
            index)
          (owned_view.compiler-owned-shared-view name))]
      (if marked.found
        (begin
          (set! (array-ref frames.slots index) marked.bindings)
          (LintUnusedVariableMarkFramesResult frames true))
        (lint-unused-variable-mark-frames-at frames name (- index 1))))))

(define (lint-unused-variable-mark-frames
  [frames : LintUnusedVariableFrameList]
  [name : String]) : LintUnusedVariableMarkFramesResult
  (lint-unused-variable-mark-frames-at
    (owned_view.compiler-owned-shared-view frames)
    name
    (- frames.len 1)))

(define (lint-unused-variable-read-name
  [state : LintUnusedVariableState]
  [name : String]) : LintUnusedVariableState
  (let
    [marked : LintUnusedVariableMarkFramesResult
      (lint-unused-variable-mark-frames
        (owned_view.compiler-owned-shared-view state.frames)
        name)]
    (if marked.found
      (lint-unused-variable-state-with
        (owned_view.compiler-owned-shared-view state)
        marked.frames
        state.findings)
      state)))

(define (lint-unused-variable-read-id
  [state : LintUnusedVariableState]
  [name : i64]) : LintUnusedVariableState
  (lint-unused-variable-read-name state (ci.intern-str name)))

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
      (lint-unused-variable-read-name
        state
        (owned_view.compiler-owned-shared-view name))]
    [dot : i64
      (lint-unused-variable-first-dot-index
        (owned_view.compiler-owned-shared-view name))]
    (if (> dot 0)
      (lint-unused-variable-read-name with-full (string.substring name 0 dot))
      with-full)))

(define (lint-unused-variable-read-var-id
  [state : LintUnusedVariableState]
  [name : i64]) : LintUnusedVariableState
  (lint-unused-variable-read-var-name state (ci.intern-str name)))

(define (lint-unused-variable-add-to-current-frame
  [state : LintUnusedVariableState]
  [binding : LintUnusedVariableBinding]) : LintUnusedVariableState
  (let
    [frames : LintUnusedVariableFrameList state.frames]
    [top : i64 (- frames.len 1)]
    (if (< top 0)
      (lint-unused-variable-push-frame
        (owned_view.compiler-owned-shared-view state)
        (lint-unused-variable-binding-push
          (lint-unused-variable-bindings-empty)
          binding))
      (begin
        (set!
          (array-ref frames.slots top)
          (lint-unused-variable-binding-push
            (owned_view.compiler-owned-array-element-shared-view
              frames.slots
              top)
            binding))
        state))))

(define (lint-unused-variable-push-frame
  [state : LintUnusedVariableState]
  [bindings : LintUnusedVariableBindingList]) : LintUnusedVariableState
  (lint-unused-variable-state-with
    (owned_view.compiler-owned-shared-view state)
    (lint-unused-variable-frame-push state.frames bindings)
    state.findings))

(define (lint-unused-variable-report-bindings-at
  [bindings : LintUnusedVariableBindingList]
  [findings : LintFindings]
  [index : i64]) : LintFindings
  (if (< index 0)
    findings
    (let
      [binding : LintUnusedVariableBinding
        (owned_view.compiler-owned-array-element-shared-view
          bindings.slots
          index)]
      [next : LintFindings
        (if (and
          binding.reportable
          (not binding.used)
          (not
            (lint-underscore-prefixed?
              (owned_view.compiler-owned-shared-view binding.name))))
          (lint-findings-add
            (lint-unused-variable-finding binding.name binding.span)
            findings)
          findings)]
      (lint-unused-variable-report-bindings-at bindings next (- index 1)))))

(define (lint-unused-variable-report-bindings
  [bindings : LintUnusedVariableBindingList]
  [findings : LintFindings]) : LintFindings
  (lint-unused-variable-report-bindings-at
    (owned_view.compiler-owned-shared-view bindings)
    findings
    (- bindings.len 1)))

(define (lint-unused-variable-pop-frame [state : LintUnusedVariableState]) : LintUnusedVariableState
  (let
    [frames : LintUnusedVariableFrameList
      (owned_view.compiler-owned-shared-view state.frames)]
    [top : i64 (- frames.len 1)]
    (if (< top 0)
      (owned_view.compiler-owned-shared-view state)
      (lint-unused-variable-state-with
        (owned_view.compiler-owned-shared-view state)
        (LintUnusedVariableFrameList
          (owned_view.compiler-owned-shared-view frames.slots)
          top)
        (if state.report-unused
          (lint-unused-variable-report-bindings
            (owned_view.compiler-owned-array-element-shared-view
              frames.slots
              top)
            state.findings)
          state.findings)))))

(define (lint-unused-variable-param-bindings
  [params : ast.AstParamList]
  [source : String]
  [cursor : i64]
  [fallback : ast.AstSourceSpan]
  [reportable : bool]) : LintUnusedVariableBindingBuild
  (lint-unused-variable-param-bindings-at
    (& params)
    source
    cursor
    fallback
    reportable
    (__tl_make-array
      LintUnusedVariableBinding
      (ast.ast-param-list-len (& params)))
    0))

;; Params are scanned in signature order so the source cursor advances, but the
;; slot order is reversed: the old cons list carried the first param at its
;; head, which is now the last slot.
(define (lint-unused-variable-param-bindings-at
  [params : (& params ast.AstParamList)]
  [source : String]
  [cursor : i64]
  [fallback : ast.AstSourceSpan]
  [reportable : bool]
  [slots : (__tl_dyn-array LintUnusedVariableBinding)]
  [index : i64]) : LintUnusedVariableBindingBuild
  (if (>= index (array-length slots))
    (LintUnusedVariableBindingBuild
      (LintUnusedVariableBindingList
        (owned_view.compiler-owned-shared-view slots)
        (array-length slots))
      cursor)
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param name ty is-comptime)
        (let
          [text : String (ci.intern-str name)]
          [found : LintSourceNameSpan
            (lint-source-name-span-from
              (owned_view.compiler-owned-shared-view source)
              (owned_view.compiler-owned-shared-view text)
              cursor
              fallback)]
          (begin
            (set!
              (array-ref slots (- (array-length slots) (+ index 1)))
              (lint-unused-variable-binding
                text
                found.span
                reportable
                (and
                  is-comptime
                  (match ty
                    [(ast.AstType.Var type-name)
                      (string.eq (ci.intern-str type-name) "type")]
                    [_ false]))))
            (lint-unused-variable-param-bindings-at
              params
              source
              found.next-index
              fallback
              reportable
              slots
              (+ index 1))))])))

(define (lint-unused-variable-macro-param-bindings
  [params : ast.AstMacroParamList]
  [source : String]
  [cursor : i64]
  [fallback : ast.AstSourceSpan]
  [reportable : bool]) : LintUnusedVariableBindingBuild
  (lint-unused-variable-macro-param-bindings-at
    (& params)
    source
    cursor
    fallback
    reportable
    (__tl_make-array
      LintUnusedVariableBinding
      (ast.ast-macro-param-list-len (& params)))
    0))

(define (lint-unused-variable-macro-param-bindings-at
  [params : (& params ast.AstMacroParamList)]
  [source : String]
  [cursor : i64]
  [fallback : ast.AstSourceSpan]
  [reportable : bool]
  [slots : (__tl_dyn-array LintUnusedVariableBinding)]
  [index : i64]) : LintUnusedVariableBindingBuild
  (if (>= index (array-length slots))
    (LintUnusedVariableBindingBuild
      (LintUnusedVariableBindingList
        (owned_view.compiler-owned-shared-view slots)
        (array-length slots))
      cursor)
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(ast.AstMacroParam.Param name ty _ _)
        (let
          [text : String (ci.intern-str name)]
          [found : LintSourceNameSpan
            (lint-source-name-span-from
              (owned_view.compiler-owned-shared-view source)
              (owned_view.compiler-owned-shared-view text)
              cursor
              fallback)]
          (begin
            (set!
              (array-ref slots (- (array-length slots) (+ index 1)))
              (lint-unused-variable-binding
                text
                found.span
                reportable
                (match ty
                  [(ast.AstType.Var type-name)
                    (string.eq (ci.intern-str type-name) "type")]
                  [_ false])))
            (lint-unused-variable-macro-param-bindings-at
              params
              source
              found.next-index
              fallback
              reportable
              slots
              (+ index 1))))])))

(define (lint-unused-variable-pattern-list-bindings
  [patterns : ast.AstPatternList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-pattern-list-bindings-at (& patterns) state 0))

(define (lint-unused-variable-pattern-list-bindings-at
  [patterns : (& patterns ast.AstPatternList)]
  [state : LintUnusedVariableState]
  [index : i64]) : LintUnusedVariableState
  (if (>= index patterns.len)
    state
    (lint-unused-variable-pattern-list-bindings-at
      patterns
      (lint-unused-variable-pattern-bindings
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
        state)
      (+ index 1))))

(define (lint-unused-variable-type-list
  [items : ast.AstTypeList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-type-list-at (& items) state 0))

(define (lint-unused-variable-type-list-at
  [items : (& items ast.AstTypeList)]
  [state : LintUnusedVariableState]
  [index : i64]) : LintUnusedVariableState
  (if (>= index (ast.ast-type-list-len items))
    state
    (lint-unused-variable-type-list-at
      items
      (lint-unused-variable-type
        (ast.ty-node-get
          (ast.ast-type-list-get items index (ast.ast-type-id-fallback)))
        state)
      (+ index 1))))

(define (lint-unused-variable-lifetime-list
  [items : ast.AstLifetimeList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-lifetime-list-at (& items) state 0))

(define (lint-unused-variable-lifetime-list-at
  [items : (& items ast.AstLifetimeList)]
  [state : LintUnusedVariableState]
  [index : i64]) : LintUnusedVariableState
  (if (>= index (ast.ast-lifetime-list-len items))
    state
    (lint-unused-variable-lifetime-list-at
      items
      (lint-unused-variable-read-id
        state
        (ast.ast-lifetime-list-get items index (ast.ast-lifetime-fallback)))
      (+ index 1))))

(define (lint-unused-variable-type-lifetime
  [name : i64]
  [inner : i64]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-type
    (ast.ty-node-get inner)
    (lint-unused-variable-read-id state name)))

(define (lint-unused-variable-type
  [ty : ast.AstType]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match ty
    [(ast.AstType.Func args ret)
      (lint-unused-variable-type
        (ast.ty-node-get ret)
        (lint-unused-variable-type-list
          (ast.ast-type-list-box-shared-view
            (owned_view.compiler-owned-shared-view args))
          state))]
    [(ast.AstType.Tuple items)
      (lint-unused-variable-type-list
        (ast.ast-type-list-box-shared-view
          (owned_view.compiler-owned-shared-view items))
        state)]
    [(ast.AstType.Array elem _)
      (lint-unused-variable-type (ast.ty-node-get elem) state)]
    [(ast.AstType.DynArray elem)
      (lint-unused-variable-type (ast.ty-node-get elem) state)]
    [(ast.AstType.Box elem)
      (lint-unused-variable-type (ast.ty-node-get elem) state)]
    [(ast.AstType.Region name inner)
      (lint-unused-variable-type-lifetime name inner state)]
    [(ast.AstType.Ref name inner)
      (lint-unused-variable-type-lifetime name inner state)]
    [(ast.AstType.MutRef name inner)
      (lint-unused-variable-type-lifetime name inner state)]
    [(ast.AstType.EnumArgs _ lifetimes)
      (lint-unused-variable-lifetime-list
        (ast.ast-lifetime-list-box-shared-view
          (owned_view.compiler-owned-shared-view lifetimes))
        state)]
    [(ast.AstType.StructArgs _ lifetimes)
      (lint-unused-variable-lifetime-list
        (ast.ast-lifetime-list-box-shared-view
          (owned_view.compiler-owned-shared-view lifetimes))
        state)]
    [(ast.AstType.Var name) (lint-unused-variable-read-id state name)]
    [(ast.AstType.VarArgs name lifetimes)
      (lint-unused-variable-lifetime-list
        (ast.ast-lifetime-list-box-shared-view
          (owned_view.compiler-owned-shared-view lifetimes))
        (lint-unused-variable-read-id state name))]
    [(ast.AstType.Ptr elem)
      (lint-unused-variable-type (ast.ty-node-get elem) state)]
    [(ast.AstType.MutPtr elem)
      (lint-unused-variable-type (ast.ty-node-get elem) state)]
    [_ state]))

(define (lint-unused-variable-maybe-type
  [maybe-ty : ast.AstMaybeType]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match maybe-ty
    [(ast.AstMaybeType.No) state]
    [(ast.AstMaybeType.Some ty) (lint-unused-variable-type ty state)]))

(define (lint-unused-variable-param-types
  [params : ast.AstParamList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-param-types-at (& params) state 0))

(define (lint-unused-variable-param-types-at
  [params : (& params ast.AstParamList)]
  [state : LintUnusedVariableState]
  [index : i64]) : LintUnusedVariableState
  (if (>= index (ast.ast-param-list-len params))
    state
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param _ ty _)
        (lint-unused-variable-param-types-at
          params
          (lint-unused-variable-type ty state)
          (+ index 1))])))

(define (lint-unused-variable-macro-param-types
  [params : ast.AstMacroParamList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-macro-param-types-at (& params) state 0))

(define (lint-unused-variable-macro-param-types-at
  [params : (& params ast.AstMacroParamList)]
  [state : LintUnusedVariableState]
  [index : i64]) : LintUnusedVariableState
  (if (>= index (ast.ast-macro-param-list-len params))
    state
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(ast.AstMacroParam.Param _ ty _ _)
        (lint-unused-variable-macro-param-types-at
          params
          (lint-unused-variable-type ty state)
          (+ index 1))])))

(define (lint-unused-variable-borrow-lifetime
  [lifetime : ast.AstBorrowLifetime]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match lifetime
    [(ast.AstBorrowLifetime.Inferred) state]
    [(ast.AstBorrowLifetime.Named name)
      (lint-unused-variable-read-id state name)]))

(define (lint-unused-variable-pattern-bindings
  [pattern : ast.AstPattern]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match pattern
    [(ast.AstPattern.Var name maybe-ty)
      (lint-unused-variable-add-to-current-frame
        (lint-unused-variable-maybe-type maybe-ty state)
        (lint-unused-variable-binding
          (ci.intern-str name)
          (lint-no-span)
          false
          false))]
    [(ast.AstPattern.Tuple items)
      (lint-unused-variable-pattern-list-bindings
        (ast.ast-pattern-list-box-shared-view items)
        state)]
    [(ast.AstPattern.Array items)
      (lint-unused-variable-pattern-list-bindings
        (ast.ast-pattern-list-box-shared-view items)
        state)]
    [(ast.AstPattern.Wildcard) state]
    [(ast.AstPattern.Binding name)
      (lint-unused-variable-add-to-current-frame
        state
        (lint-unused-variable-binding
          (ci.intern-str name)
          (lint-no-span)
          false
          false))]
    [(ast.AstPattern.Variant _ items)
      (lint-unused-variable-pattern-list-bindings
        (ast.ast-pattern-list-box-shared-view items)
        state)]
    [(ast.AstPattern.Literal _) state]))

(define (lint-unused-variable-expr-list
  [exprs : ast.AstExprList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-expr-list-at (& exprs) 0 state))

(define (lint-unused-variable-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (if (>= index exprs.len)
    state
    (lint-unused-variable-expr-list-at
      exprs
      (+ index 1)
      (lint-unused-variable-expr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))
        state
        (lint-no-span)))))

(define (lint-unused-variable-quasiquote-expr-list
  [exprs : ast.AstExprList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-quasiquote-expr-list-at (& exprs) 0 state))

(define (lint-unused-variable-quasiquote-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (if (>= index exprs.len)
    state
    (lint-unused-variable-quasiquote-expr-list-at
      exprs
      (+ index 1)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))
        state))))

(define (lint-unused-variable-quasiquote-let-bindings
  [bindings : ast.AstLetBindingList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-quasiquote-let-bindings-at (& bindings) state 0))

(define (lint-unused-variable-quasiquote-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [state : LintUnusedVariableState]
  [index : i64]) : LintUnusedVariableState
  (if (>= index (ast.ast-let-binding-list-len bindings))
    state
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding _ _ init)
        (lint-unused-variable-quasiquote-let-bindings-at
          bindings
          (lint-unused-variable-quasiquote-expr (ast.ast-node-get init) state)
          (+ index 1))])))

(define (lint-unused-variable-quasiquote-match-arms
  [arms : ast.AstMatchArmList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-quasiquote-match-arms-at (& arms) state 0))

(define (lint-unused-variable-quasiquote-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [state : LintUnusedVariableState]
  [index : i64]) : LintUnusedVariableState
  (if (>= index arms.len)
    state
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm _ body)
        (lint-unused-variable-quasiquote-match-arms-at
          arms
          (lint-unused-variable-quasiquote-expr (ast.ast-node-get body) state)
          (+ index 1))])))

(define (lint-unused-variable-quasiquote-resource-bindings
  [bindings : ast.AstResourceBindingList]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (lint-unused-variable-quasiquote-resource-bindings-at (& bindings) state 0))

(define (lint-unused-variable-quasiquote-resource-bindings-at
  [bindings : (& bindings ast.AstResourceBindingList)]
  [state : LintUnusedVariableState]
  [index : i64]) : LintUnusedVariableState
  (if (>= index (ast.ast-resource-binding-list-len bindings))
    state
    (match (ast.ast-resource-binding-list-get
      bindings
      index
      (ast.ast-resource-binding-fallback))
      [(ast.AstResourceBinding.Binding _ init cleanup _)
        (lint-unused-variable-quasiquote-resource-bindings-at
          bindings
          (lint-unused-variable-quasiquote-expr
            (ast.ast-node-get cleanup)
            (lint-unused-variable-quasiquote-expr (ast.ast-node-get init) state))
          (+ index 1))])))

(define (lint-unused-variable-quasiquote-expr
  [expr : ast.AstExpr]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner-box) state)]
    [(ast.AstExpr.Unquote inner)
      (lint-unused-variable-expr
        (ast.ast-node-get inner)
        state
        (lint-no-effect-span (ast.ast-node-get inner)))]
    [(ast.AstExpr.UnquoteSplicing inner)
      (lint-unused-variable-expr
        (ast.ast-node-get inner)
        state
        (lint-no-effect-span (ast.ast-node-get inner)))]
    [(ast.AstExpr.Binary _ left right)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get right)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get left) state))]
    [(ast.AstExpr.Unary _ inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Call func args)
      (lint-unused-variable-quasiquote-expr-list
        args
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get func) state))]
    [(ast.AstExpr.If cond then-branch else-branch)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get else-branch)
        (lint-unused-variable-quasiquote-expr
          (ast.ast-node-get then-branch)
          (lint-unused-variable-quasiquote-expr (ast.ast-node-get cond) state)))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-unused-variable-quasiquote-expr
            (ast.ast-node-get body)
            (lint-unused-variable-quasiquote-let-bindings bindings state))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda _ _ body)
          (lint-unused-variable-quasiquote-expr (ast.ast-node-get body) state)])]
    [(ast.AstExpr.Tuple exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(ast.AstExpr.TupleRef tuple _)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get tuple) state)]
    [(ast.AstExpr.Array exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(ast.AstExpr.DynArray exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(ast.AstExpr.MakeArray _ len)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get len) state)]
    [(ast.AstExpr.ArrayRef array index)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get index)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get array) state))]
    [(ast.AstExpr.ArraySet array index value)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get value)
        (lint-unused-variable-quasiquote-expr
          (ast.ast-node-get index)
          (lint-unused-variable-quasiquote-expr (ast.ast-node-get array) state)))]
    [(ast.AstExpr.ArrayTake array live index)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get index)
        (lint-unused-variable-quasiquote-expr
          (ast.ast-node-get live)
          (lint-unused-variable-quasiquote-expr (ast.ast-node-get array) state)))]
    [(ast.AstExpr.FixedArrayTake array index)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get index)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get array) state))]
    [(ast.AstExpr.Replace place replacement)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get replacement)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get place) state))]
    [(ast.AstExpr.ArrayPush array value)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get array) state))]
    [(ast.AstExpr.StringRef text index)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get index)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get text) state))]
    [(ast.AstExpr.While cond body)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get body)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get cond) state))]
    [(ast.AstExpr.Begin exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(ast.AstExpr.Unsafe exprs)
      (lint-unused-variable-quasiquote-expr-list exprs state)]
    [(ast.AstExpr.Set _ value)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get value) state)]
    [(ast.AstExpr.Ann inner _)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Cast inner _)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Borrow _ _ place)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get place) state)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (lint-unused-variable-quasiquote-match-arms
            arms
            (lint-unused-variable-quasiquote-expr
              (ast.ast-node-get scrutinee)
              state))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach _ _ start end body)
          (lint-unused-variable-quasiquote-expr
            (ast.ast-node-get body)
            (lint-unused-variable-quasiquote-expr
              (ast.ast-node-get end)
              (lint-unused-variable-quasiquote-expr
                (ast.ast-node-get start)
                state)))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce _ _ _ start end init value)
          (lint-unused-variable-quasiquote-expr
            (ast.ast-node-get value)
            (lint-unused-variable-quasiquote-expr
              (ast.ast-node-get init)
              (lint-unused-variable-quasiquote-expr
                (ast.ast-node-get end)
                (lint-unused-variable-quasiquote-expr
                  (ast.ast-node-get start)
                  state))))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(ast.AstSpmdScan.Scan _ _ _ start end _ _ init value body)
          (lint-unused-variable-quasiquote-expr
            (ast.ast-node-get body)
            (lint-unused-variable-quasiquote-expr
              (ast.ast-node-get value)
              (lint-unused-variable-quasiquote-expr
                (ast.ast-node-get init)
                (lint-unused-variable-quasiquote-expr
                  (ast.ast-node-get end)
                  (lint-unused-variable-quasiquote-expr
                    (ast.ast-node-get start)
                    state)))))])]
    [(ast.AstExpr.SpmdBroadcast value lane)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get lane)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get value) state))]
    [(ast.AstExpr.SpmdShuffle value lane)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get lane)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get value) state))]
    [(ast.AstExpr.StructGet receiver _)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get receiver) state)]
    [(ast.AstExpr.StructSet receiver _ value)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get receiver) state))]
    [(ast.AstExpr.WithRegion _ body)
      (lint-unused-variable-quasiquote-expr-list body state)]
    [(ast.AstExpr.WithEscape scratch body)
      (lint-unused-variable-quasiquote-expr-list
        body
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get scratch) state))]
    [(ast.AstExpr.WithScratch body)
      (lint-unused-variable-quasiquote-expr-list body state)]
    [(ast.AstExpr.InArena arena body)
      (lint-unused-variable-quasiquote-expr-list
        body
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get arena) state))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-unused-variable-quasiquote-expr-list
            body
            (lint-unused-variable-quasiquote-resource-bindings bindings state))])]
    [(ast.AstExpr.Box inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BoxGet inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BoxTake inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.BoxSet inner value)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state))]
    [(ast.AstExpr.Comptime inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Quasiquote _) state]
    [(ast.AstExpr.BracketClause items)
      (lint-unused-variable-quasiquote-expr-list items state)]
    [(ast.AstExpr.Try inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Return inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Break) state]
    [(ast.AstExpr.Continue) state]
    [(ast.AstExpr.PtrNullCheck inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.PtrAddrOf place)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get place) state)]
    [(ast.AstExpr.PtrRead ptr)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get ptr) state)]
    [(ast.AstExpr.PtrWrite ptr value)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get value)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get ptr) state))]
    [(ast.AstExpr.PtrOffset ptr offset)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get offset)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get ptr) state))]
    [(ast.AstExpr.PtrCast ptr _)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get ptr) state)]
    [(ast.AstExpr.PtrToInt ptr)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get ptr) state)]
    [(ast.AstExpr.IntToPtr value _)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get value) state)]
    [(ast.AstExpr.StringData inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.StringFromBytes ptr len)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get len)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get ptr) state))]
    [(ast.AstExpr.ArrayData inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.CpuIdEax leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.CpuIdEbx leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.CpuIdEcx leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.CpuIdEdx leaf subleaf)
      (lint-unused-variable-quasiquote-expr
        (ast.ast-node-get subleaf)
        (lint-unused-variable-quasiquote-expr (ast.ast-node-get leaf) state))]
    [(ast.AstExpr.Xgetbv index)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get index) state)]
    [(ast.AstExpr.Syscall args)
      (lint-unused-variable-quasiquote-expr-list args state)]
    [_ state]))

(define (lint-unused-variable-let-bindings
  [bindings : ast.AstLetBindingList]
  [state : LintUnusedVariableState]
  [cursor : i64]) : LintUnusedVariableState
  (lint-unused-variable-let-bindings-at (& bindings) state cursor 0))

(define (lint-unused-variable-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [state : LintUnusedVariableState]
  [cursor : i64]
  [index : i64]) : LintUnusedVariableState
  (if (>= index (ast.ast-let-binding-list-len bindings))
    state
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name maybe-ty init)
        (let
          [after-ty : LintUnusedVariableState
            (lint-unused-variable-maybe-type
              maybe-ty
              (owned_view.compiler-owned-shared-view state))]
          [after-init : LintUnusedVariableState
            (lint-unused-variable-expr
              (ast.ast-node-get init)
              after-ty
              (lint-no-effect-span (ast.ast-node-get init)))]
          [text : String (ci.intern-str name)]
          [found : LintSourceNameSpan
            (lint-source-name-span-from
              state.source
              (owned_view.compiler-owned-shared-view text)
              cursor
              (lint-no-effect-span (ast.ast-node-get init)))]
          [with-case : LintUnusedVariableState
            (lint-unused-variable-add-local-name-case
              after-init
              (owned_view.compiler-owned-shared-view text)
              found.span)]
          [with-binding : LintUnusedVariableState
            (lint-unused-variable-add-to-current-frame
              with-case
              (lint-unused-variable-binding text found.span true false))]
          (lint-unused-variable-let-bindings-at
            bindings
            with-binding
            found.next-index
            (+ index 1)))])))

(define (lint-unused-variable-let
  [bindings : ast.AstLetBindingList]
  [body : ast.AstExpr]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [cursor : i64
      (let
        [start : i64
          (lint-source-span-start-index
            (owned_view.compiler-owned-shared-view state.source)
            span)]
        (if (< start 0)
          0
          start))]
    [with-frame : LintUnusedVariableState
      (lint-unused-variable-push-frame
        (owned_view.compiler-owned-shared-view state)
        (lint-unused-variable-bindings-empty))]
    [with-bindings : LintUnusedVariableState
      (lint-unused-variable-let-bindings bindings with-frame cursor)]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-bindings span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-resource-bindings
  [bindings : ast.AstResourceBindingList]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [start : i64 (lint-source-span-start-index state.source span)]
    (lint-unused-variable-resource-bindings-at
      (& bindings)
      (owned_view.compiler-owned-shared-view state)
      (if (< start 0)
        0
        start)
      0)))

(define (lint-unused-variable-resource-bindings-at
  [bindings : (& bindings ast.AstResourceBindingList)]
  [state : LintUnusedVariableState]
  [cursor : i64]
  [index : i64]) : LintUnusedVariableState
  (if (>= index (ast.ast-resource-binding-list-len bindings))
    state
    (match (ast.ast-resource-binding-list-get
      bindings
      index
      (ast.ast-resource-binding-fallback))
      [(ast.AstResourceBinding.Binding name init cleanup _)
        (let
          [text : String (ci.intern-str name)]
          [init-expr : ast.AstExpr (ast.ast-node-get init)]
          [cleanup-expr : ast.AstExpr (ast.ast-node-get cleanup)]
          [init-span : ast.AstSourceSpan
            (lint-no-effect-span
              (owned_view.compiler-owned-shared-view init-expr))]
          [cleanup-span : ast.AstSourceSpan
            (lint-no-effect-span
              (owned_view.compiler-owned-shared-view cleanup-expr))]
          [init-start : i64
            (lint-source-span-start-index
              (owned_view.compiler-owned-shared-view state.source)
              init-span)]
          [found : LintSourceNameSpan
            (lint-source-name-span-between
              (owned_view.compiler-owned-shared-view state.source)
              (owned_view.compiler-owned-shared-view text)
              cursor
              (if (< init-start 0)
                (string.string-length state.source)
                init-start))]
          [with-case : LintUnusedVariableState
            (lint-unused-variable-add-local-name-case
              (owned_view.compiler-owned-shared-view state)
              (owned_view.compiler-owned-shared-view text)
              found.span)]
          [after-exprs : LintUnusedVariableState
            (lint-unused-variable-expr
              cleanup-expr
              (lint-unused-variable-expr init-expr with-case init-span)
              cleanup-span)]
          [with-binding : LintUnusedVariableState
            (lint-unused-variable-add-to-current-frame
              after-exprs
              (lint-unused-variable-binding text found.span false false))]
          [cleanup-end : i64
            (lint-source-span-end-index state.source cleanup-span)]
          (lint-unused-variable-resource-bindings-at
            bindings
            with-binding
            (if (< cleanup-end 0)
              found.next-index
              cleanup-end)
            (+ index 1)))])))

(define (lint-unused-variable-match-arms
  [arms : ast.AstMatchArmList]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [start : i64
      (lint-source-span-start-index
        (owned_view.compiler-owned-shared-view state.source)
        span)]
    (lint-unused-variable-match-arms-at
      (& arms)
      (owned_view.compiler-owned-shared-view state)
      (if (< start 0)
        0
        start)
      0)))

(define (lint-match-body-source-expr [body : ast.AstExpr]) : ast.AstExpr
  (match (owned_view.compiler-owned-shared-view body)
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (match (owned_view.compiler-owned-shared-view inner)
          [(ast.AstExpr.Spanned _ _) inner]
          [_ body]))]
    [_ body]))

(define (lint-unused-variable-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [state : LintUnusedVariableState]
  [cursor : i64]
  [index : i64]) : LintUnusedVariableState
  (if (>= index arms.len)
    state
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm pattern body)
        (let
          [body-expr : ast.AstExpr
            (lint-match-body-source-expr (ast.ast-node-get body))]
          [body-span : ast.AstSourceSpan
            (lint-no-effect-span
              (owned_view.compiler-owned-shared-view body-expr))]
          [body-start : i64
            (lint-source-span-start-index
              (owned_view.compiler-owned-shared-view state.source)
              body-span)]
          [scanned : LintNameCasePatternScan
            (if state.name-case
              (lint-name-case-match-pattern
                (owned_view.compiler-owned-shared-view pattern)
                (owned_view.compiler-owned-shared-view state.source)
                cursor
                (if (< body-start 0)
                  (string.string-length state.source)
                  body-start)
                state.findings)
              (LintNameCasePatternScan state.findings cursor))]
          [with-case-findings : LintUnusedVariableState
            (lint-unused-variable-state-with
              (owned_view.compiler-owned-shared-view state)
              state.frames
              scanned.findings)]
          [with-frame : LintUnusedVariableState
            (lint-unused-variable-push-frame
              with-case-findings
              (lint-unused-variable-bindings-empty))]
          [with-pattern : LintUnusedVariableState
            (lint-unused-variable-pattern-bindings
              (owned_view.compiler-owned-shared-view pattern)
              with-frame)]
          [with-body : LintUnusedVariableState
            (lint-unused-variable-expr
              (owned_view.compiler-owned-shared-view body-expr)
              with-pattern
              body-span)]
          [body-end : i64 (lint-source-span-end-index state.source body-span)]
          (lint-unused-variable-match-arms-at
            arms
            (lint-unused-variable-pop-frame with-body)
            (if (< body-end 0)
              scanned.next-index
              body-end)
            (+ index 1)))])))

(define (lint-unused-variable-lambda
  [params : ast.AstParamList]
  [ret : ast.AstMaybeType]
  [body : ast.AstExpr]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [start : i64
      (lint-source-span-start-index
        (owned_view.compiler-owned-shared-view state.source)
        span)]
    [cursor : i64
      (if (< start 0)
        0
        (+ start (string.string-length "(lambda")))]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-param-bindings
        (owned_view.compiler-owned-shared-view params)
        (owned_view.compiler-owned-shared-view state.source)
        cursor
        span
        true)]
    [with-cases : LintUnusedVariableState
      (lint-unused-variable-add-binding-name-cases
        (owned_view.compiler-owned-shared-view state)
        (owned_view.compiler-owned-shared-view built.bindings))]
    [with-frame : LintUnusedVariableState
      (lint-unused-variable-push-frame with-cases built.bindings)]
    [with-param-types : LintUnusedVariableState
      (lint-unused-variable-maybe-type
        ret
        (lint-unused-variable-param-types params with-frame))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-param-types span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-index-scope
  [name : i64]
  [body : ast.AstExpr]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [with-frame : LintUnusedVariableState
      (lint-unused-variable-push-frame
        (owned_view.compiler-owned-shared-view state)
        (lint-unused-variable-binding-push
          (lint-unused-variable-bindings-empty)
          (lint-unused-variable-binding (ci.intern-str name) span false false)))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-frame span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-scan-body-scope
  [index : i64]
  [prefix : i64]
  [body : ast.AstExpr]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [with-frame : LintUnusedVariableState
      (lint-unused-variable-push-frame
        state
        (lint-unused-variable-binding-push
          (lint-unused-variable-binding-push
            (lint-unused-variable-bindings-empty)
            (lint-unused-variable-binding
              (ci.intern-str prefix)
              span
              false
              false))
          (lint-unused-variable-binding (ci.intern-str index) span false false)))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-frame span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-expr
  [expr : ast.AstExpr]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box inner-span)
      (lint-unused-variable-expr (ast.ast-node-get inner-box) state inner-span)]
    [(ast.AstExpr.MacroExpansion inner-box _ _)
      (lint-unused-variable-expr (ast.ast-node-get inner-box) state span)]
    [(ast.AstExpr.Literal _) state]
    [(ast.AstExpr.Var name)
      (begin
        (lint-unused-unsafe-note-value-name!
          (owned_view.compiler-owned-shared-view state)
          (ci.intern-str name))
        (lint-unused-variable-read-var-id state name))]
    [(ast.AstExpr.Binary _ left right)
      (lint-unused-variable-expr
        (ast.ast-node-get right)
        (lint-unused-variable-expr (ast.ast-node-get left) state span)
        span)]
    [(ast.AstExpr.Unary _ inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.Call func args)
      (begin
        (lint-unused-unsafe-note-call-target!
          (owned_view.compiler-owned-shared-view state)
          (ast.ast-node-get func))
        (lint-unused-variable-expr-list
          args
          (lint-unused-variable-expr (ast.ast-node-get func) state span)))]
    [(ast.AstExpr.If cond then-branch else-branch)
      (lint-unused-variable-expr
        (ast.ast-node-get else-branch)
        (lint-unused-variable-expr
          (ast.ast-node-get then-branch)
          (lint-unused-variable-expr (ast.ast-node-get cond) state span)
          span)
        span)]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-unused-variable-let bindings (ast.ast-node-get body) state span)])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda params ret body)
          (lint-unused-variable-lambda
            params
            ret
            (ast.ast-node-get body)
            state
            span)])]
    [(ast.AstExpr.Tuple exprs) (lint-unused-variable-expr-list exprs state)]
    [(ast.AstExpr.TupleRef tuple _)
      (lint-unused-variable-expr (ast.ast-node-get tuple) state span)]
    [(ast.AstExpr.Array exprs) (lint-unused-variable-expr-list exprs state)]
    [(ast.AstExpr.DynArray exprs) (lint-unused-variable-expr-list exprs state)]
    [(ast.AstExpr.MakeArray ty-id len)
      (lint-unused-variable-expr
        (ast.ast-node-get len)
        (lint-unused-variable-type (ast.ty-node-get ty-id) state)
        span)]
    [(ast.AstExpr.ArrayRef array index)
      (lint-unused-variable-expr
        (ast.ast-node-get index)
        (lint-unused-variable-expr (ast.ast-node-get array) state span)
        span)]
    [(ast.AstExpr.ArraySet array index value)
      (lint-unused-variable-expr
        (ast.ast-node-get value)
        (lint-unused-variable-expr
          (ast.ast-node-get index)
          (lint-unused-variable-expr (ast.ast-node-get array) state span)
          span)
        span)]
    [(ast.AstExpr.ArrayTake array live index)
      (lint-unused-variable-expr
        (ast.ast-node-get index)
        (lint-unused-variable-expr
          (ast.ast-node-get live)
          (lint-unused-variable-expr (ast.ast-node-get array) state span)
          span)
        span)]
    [(ast.AstExpr.FixedArrayTake array index)
      (lint-unused-variable-expr
        (ast.ast-node-get index)
        (lint-unused-variable-expr (ast.ast-node-get array) state span)
        span)]
    [(ast.AstExpr.Replace place replacement)
      (lint-unused-variable-expr
        (ast.ast-node-get replacement)
        (lint-unused-variable-expr (ast.ast-node-get place) state span)
        span)]
    [(ast.AstExpr.ArrayPush array value)
      (lint-unused-variable-expr
        (ast.ast-node-get value)
        (lint-unused-variable-expr (ast.ast-node-get array) state span)
        span)]
    [(ast.AstExpr.StringRef text index)
      (lint-unused-variable-expr
        (ast.ast-node-get index)
        (lint-unused-variable-expr (ast.ast-node-get text) state span)
        span)]
    [(ast.AstExpr.While cond body)
      (lint-unused-variable-expr
        (ast.ast-node-get body)
        (lint-unused-variable-expr (ast.ast-node-get cond) state span)
        span)]
    [(ast.AstExpr.ForOwnedState payload)
      (lint-unused-variable-expr
        (ast.ast-node-get (ast.ast-for-owned-state-body (& payload)))
        (lint-unused-variable-expr
          (ast.ast-node-get (ast.ast-for-owned-state-source (& payload)))
          state
          span)
        span)]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [source : i64 (ast.ast-for-owned-step-source-name (& payload))]
        [index : i64 (ast.ast-for-owned-step-index-name (& payload))]
        [binding : i64 (ast.ast-for-owned-step-binding-name (& payload))]
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        [done : i64 (ast.ast-for-owned-step-done-name (& payload))]
        [body : i64 (ast.ast-for-owned-step-body (& payload))]
        [read-state : LintUnusedVariableState
          (lint-unused-variable-expr
            (ast.ast-node-get done)
            (if (>= expected-type 0)
              (lint-unused-variable-expr
                (ast.ast-node-get expected-type)
                (lint-unused-variable-expr
                  (ast.ast-node-get index)
                  (lint-unused-variable-expr
                    (ast.ast-node-get source)
                    state
                    span)
                  span)
                span)
              (lint-unused-variable-expr
                (ast.ast-node-get index)
                (lint-unused-variable-expr (ast.ast-node-get source) state span)
                span))
            span)]
        (match (ast.ast-expr-unspan (ast.ast-node-get binding))
          [(ast.AstExpr.Var name)
            (lint-unused-variable-index-scope
              name
              (ast.ast-node-get body)
              read-state
              span)]
          [_
            (lint-unused-variable-expr (ast.ast-node-get body) read-state span)]))]
    [(ast.AstExpr.Begin exprs) (lint-unused-variable-expr-list exprs state)]
    [(ast.AstExpr.Unsafe exprs)
      (begin
        (lint-unused-unsafe-block-push!
          span
          (lint-expr-list-requires-enclosing-unsafe?
            (owned_view.compiler-owned-shared-view exprs)))
        (lint-unused-unsafe-finish-state
          (lint-unused-variable-expr-list exprs state)))]
    [(ast.AstExpr.Set _ value)
      (lint-unused-variable-expr (ast.ast-node-get value) state span)]
    [(ast.AstExpr.Ann inner ty-id)
      (lint-unused-variable-type
        (ast.ty-node-get ty-id)
        (lint-unused-variable-expr (ast.ast-node-get inner) state span))]
    [(ast.AstExpr.Cast inner ty-id)
      (begin
        (lint-unused-unsafe-block-mark-unknown!)
        (lint-unused-variable-type
          (ast.ty-node-get ty-id)
          (lint-unused-variable-expr (ast.ast-node-get inner) state span)))]
    [(ast.AstExpr.Borrow _ lifetime-id place)
      (lint-unused-variable-expr
        (ast.ast-node-get place)
        (lint-unused-variable-borrow-lifetime
          (ast.ast-borrow-lifetime-from-id lifetime-id)
          state)
        span)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (lint-unused-variable-match-arms
            arms
            (lint-unused-variable-expr (ast.ast-node-get scrutinee) state span)
            span)])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach index index-ty start end body)
          (let
            [scanned : LintNameCaseLocalScan
              (if state.name-case
                (lint-unused-variable-scan-form-local-name
                  (owned_view.compiler-owned-shared-view state)
                  (ci.intern-str index)
                  span
                  "(foreach")
                (LintNameCaseLocalScan
                  (owned_view.compiler-owned-shared-view state)
                  0))]
            (lint-unused-variable-index-scope
              index
              (ast.ast-node-get body)
              (lint-unused-variable-type
                index-ty
                (lint-unused-variable-expr
                  (ast.ast-node-get end)
                  (lint-unused-variable-expr
                    (ast.ast-node-get start)
                    scanned.state
                    span)
                  span))
              span))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce _ index index-ty start end init value)
          (let
            [scanned : LintNameCaseLocalScan
              (if state.name-case
                (lint-unused-variable-scan-form-local-name
                  (owned_view.compiler-owned-shared-view state)
                  (ci.intern-str index)
                  span
                  "(spmd-reduce")
                (LintNameCaseLocalScan
                  (owned_view.compiler-owned-shared-view state)
                  0))]
            (lint-unused-variable-index-scope
              index
              (ast.ast-node-get value)
              (lint-unused-variable-type
                index-ty
                (lint-unused-variable-expr
                  (ast.ast-node-get init)
                  (lint-unused-variable-expr
                    (ast.ast-node-get end)
                    (lint-unused-variable-expr
                      (ast.ast-node-get start)
                      scanned.state
                      span)
                    span)
                  span))
              span))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(ast.AstSpmdScan.Scan
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
            [index-scan : LintNameCaseLocalScan
              (if state.name-case
                (lint-unused-variable-scan-form-local-name
                  (owned_view.compiler-owned-shared-view state)
                  (ci.intern-str index)
                  span
                  "(spmd-scan")
                (LintNameCaseLocalScan
                  (owned_view.compiler-owned-shared-view state)
                  0))]
            [prefix-scan : LintNameCaseLocalScan
              (if state.name-case
                (let
                  [limit : i64
                    (lint-source-span-end-index
                      (owned_view.compiler-owned-shared-view state.source)
                      span)]
                  (lint-unused-variable-scan-local-name
                    index-scan.state
                    (ci.intern-str prefix)
                    index-scan.next-index
                    (if (< limit 0)
                      (string.string-length
                        (owned_view.compiler-owned-shared-view state.source))
                      limit)))
                (LintNameCaseLocalScan index-scan.state 0))]
            [base-state : LintUnusedVariableState
              (lint-unused-variable-type
                prefix-ty
                (lint-unused-variable-type
                  index-ty
                  (lint-unused-variable-expr
                    (ast.ast-node-get init)
                    (lint-unused-variable-expr
                      (ast.ast-node-get end)
                      (lint-unused-variable-expr
                        (ast.ast-node-get start)
                        prefix-scan.state
                        span)
                      span)
                    span)))]
            [value-state : LintUnusedVariableState
              (lint-unused-variable-index-scope
                index
                (ast.ast-node-get value)
                base-state
                span)]
            (lint-unused-variable-scan-body-scope
              index
              prefix
              (ast.ast-node-get body)
              value-state
              span))])]
    [(ast.AstExpr.SpmdBroadcast value lane)
      (lint-unused-variable-expr
        (ast.ast-node-get lane)
        (lint-unused-variable-expr (ast.ast-node-get value) state span)
        span)]
    [(ast.AstExpr.SpmdShuffle value lane)
      (lint-unused-variable-expr
        (ast.ast-node-get lane)
        (lint-unused-variable-expr (ast.ast-node-get value) state span)
        span)]
    [(ast.AstExpr.StructGet receiver _)
      (lint-unused-variable-expr (ast.ast-node-get receiver) state span)]
    [(ast.AstExpr.StructSet receiver _ value)
      (lint-unused-variable-expr
        (ast.ast-node-get value)
        (lint-unused-variable-expr (ast.ast-node-get receiver) state span)
        span)]
    [(ast.AstExpr.WithRegion _ body)
      (lint-unused-variable-expr-list body state)]
    [(ast.AstExpr.WithEscape scratch body)
      (lint-unused-variable-expr-list
        body
        (lint-unused-variable-expr (ast.ast-node-get scratch) state span))]
    [(ast.AstExpr.WithScratch body) (lint-unused-variable-expr-list body state)]
    [(ast.AstExpr.InArena arena body)
      (lint-unused-variable-expr-list
        body
        (lint-unused-variable-expr (ast.ast-node-get arena) state span))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (let
            [with-frame : LintUnusedVariableState
              (lint-unused-variable-push-frame
                state
                (lint-unused-variable-bindings-empty))]
            [with-bindings : LintUnusedVariableState
              (lint-unused-variable-resource-bindings bindings with-frame span)]
            [with-body : LintUnusedVariableState
              (lint-unused-variable-expr-list body with-bindings)]
            (lint-unused-variable-pop-frame with-body))])]
    [(ast.AstExpr.Box inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.BoxGet inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.BoxTake inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.BoxSet inner value)
      (lint-unused-variable-expr
        (ast.ast-node-get value)
        (lint-unused-variable-expr (ast.ast-node-get inner) state span)
        span)]
    [(ast.AstExpr.TypeLiteral ty-id)
      (lint-unused-variable-type (ast.ty-node-get ty-id) state)]
    [(ast.AstExpr.Init maybe-ty-id)
      (lint-unused-variable-maybe-type
        (ast.ast-maybe-type-from-id maybe-ty-id)
        state)]
    [(ast.AstExpr.Comptime inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.Quote _) state]
    [(ast.AstExpr.Quasiquote inner)
      (lint-unused-variable-quasiquote-expr (ast.ast-node-get inner) state)]
    [(ast.AstExpr.Unquote inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.UnquoteSplicing inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.BracketClause items)
      (lint-unused-variable-expr-list items state)]
    [(ast.AstExpr.Try inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.Return inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.Break) state]
    [(ast.AstExpr.Continue) state]
    [(ast.AstExpr.PtrNull ty-id)
      (lint-unused-variable-type (ast.ty-node-get ty-id) state)]
    [(ast.AstExpr.PtrNullCheck inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.PtrAddrOf place)
      (lint-unused-variable-expr (ast.ast-node-get place) state span)]
    [(ast.AstExpr.PtrRead ptr)
      (lint-unused-variable-expr (ast.ast-node-get ptr) state span)]
    [(ast.AstExpr.PtrWrite ptr value)
      (lint-unused-variable-expr
        (ast.ast-node-get value)
        (lint-unused-variable-expr (ast.ast-node-get ptr) state span)
        span)]
    [(ast.AstExpr.PtrOffset ptr offset)
      (lint-unused-variable-expr
        (ast.ast-node-get offset)
        (lint-unused-variable-expr (ast.ast-node-get ptr) state span)
        span)]
    [(ast.AstExpr.PtrCast ptr ty-id)
      (lint-unused-variable-type
        (ast.ty-node-get ty-id)
        (lint-unused-variable-expr (ast.ast-node-get ptr) state span))]
    [(ast.AstExpr.PtrToInt ptr)
      (lint-unused-variable-expr (ast.ast-node-get ptr) state span)]
    [(ast.AstExpr.IntToPtr value ty-id)
      (lint-unused-variable-type
        (ast.ty-node-get ty-id)
        (lint-unused-variable-expr (ast.ast-node-get value) state span))]
    [(ast.AstExpr.StringData inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.StringFromBytes ptr len)
      (lint-unused-variable-expr
        (ast.ast-node-get len)
        (lint-unused-variable-expr (ast.ast-node-get ptr) state span)
        span)]
    [(ast.AstExpr.ArrayData inner)
      (lint-unused-variable-expr (ast.ast-node-get inner) state span)]
    [(ast.AstExpr.BinaryData _) state]
    [(ast.AstExpr.SpmdProgramIndex) state]
    [(ast.AstExpr.SpmdProgramCount) state]
    [(ast.AstExpr.ProgramArgc) state]
    [(ast.AstExpr.ProgramArgv)
      (begin
        (lint-unused-unsafe-block-mark-unknown!)
        state)]
    [(ast.AstExpr.ProgramEnvp)
      (begin
        (lint-unused-unsafe-block-mark-unknown!)
        state)]
    [(ast.AstExpr.CpuIdEax leaf subleaf)
      (lint-unused-variable-expr
        (ast.ast-node-get subleaf)
        (lint-unused-variable-expr (ast.ast-node-get leaf) state span)
        span)]
    [(ast.AstExpr.CpuIdEbx leaf subleaf)
      (lint-unused-variable-expr
        (ast.ast-node-get subleaf)
        (lint-unused-variable-expr (ast.ast-node-get leaf) state span)
        span)]
    [(ast.AstExpr.CpuIdEcx leaf subleaf)
      (lint-unused-variable-expr
        (ast.ast-node-get subleaf)
        (lint-unused-variable-expr (ast.ast-node-get leaf) state span)
        span)]
    [(ast.AstExpr.CpuIdEdx leaf subleaf)
      (lint-unused-variable-expr
        (ast.ast-node-get subleaf)
        (lint-unused-variable-expr (ast.ast-node-get leaf) state span)
        span)]
    [(ast.AstExpr.Xgetbv index)
      (lint-unused-variable-expr (ast.ast-node-get index) state span)]
    [(ast.AstExpr.Syscall args) (lint-unused-variable-expr-list args state)]))

(define (lint-unused-variable-decl-param-cursor
  [source : String]
  [prefix : String]
  [name : String]
  [fallback : ast.AstSourceSpan]) : i64
  (let
    [needle : String (str_cat.str-cat prefix name)]
    [fallback-start : i64
      (lint-source-span-start-index
        (owned_view.compiler-owned-shared-view source)
        fallback)]
    [found : i64 (- 0 1)]
    [cursor : i64 fallback-start]
    (begin
      ;; The body span is inside this declaration. Searching backward finds the
      ;; nearest declaration head in work proportional to its signature, while
      ;; the old forward scan restarted at byte zero for every declaration.
      (while (and (< found 0) (>= cursor 0))
        (let
          [candidate : i64
            (lint-source-find-prefix-backward-from
              (owned_view.compiler-owned-shared-view source)
              (owned_view.compiler-owned-shared-view needle)
              cursor)]
          (if (< candidate 0)
            (set! cursor (- 0 1))
            (let
              [end : i64 (+ candidate (string.string-length needle))]
              (if (lint-source-symbol-boundary?
                (owned_view.compiler-owned-shared-view source)
                end)
                (set! found candidate)
                (set! cursor (- candidate 1)))))))
      (if (< found 0)
        (if (< fallback-start 0)
          0
          fallback-start)
        (+ found (string.string-length needle))))))

(define (lint-unused-variable-decl-with-param-frame
  [source : String]
  [prefix : String]
  [name : i64]
  [params : ast.AstParamList]
  [ret : ast.AstType]
  [body : i64]
  [acc : LintFindings]
  [name-case : bool]
  [report-unused : bool]) : LintFindings
  (let
    [body-span : ast.AstSourceSpan
      (lint-no-effect-span (ast.ast-node-get body))]
    [cursor : i64
      (lint-unused-variable-decl-param-cursor
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view prefix)
        (ci.intern-str name)
        body-span)]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-param-bindings
        (owned_view.compiler-owned-shared-view params)
        (owned_view.compiler-owned-shared-view source)
        cursor
        body-span
        true)]
    [base-state : LintUnusedVariableState
      (LintUnusedVariableState
        source
        (lint-unused-variable-frames-empty)
        acc
        name-case
        report-unused)]
    [with-cases : LintUnusedVariableState
      (lint-unused-variable-add-binding-name-cases
        base-state
        (owned_view.compiler-owned-shared-view built.bindings))]
    [state : LintUnusedVariableState
      (lint-unused-variable-push-frame
        with-cases
        (owned_view.compiler-owned-shared-view built.bindings))]
    [with-param-types : LintUnusedVariableState
      (lint-unused-variable-type
        ret
        (lint-unused-variable-param-types params state))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr
        (ast.ast-node-get body)
        with-param-types
        body-span)]
    (__tl-project-field (lint-unused-variable-pop-frame with-body) findings)))

(define (lint-unused-variable-decl-with-macro-param-frame
  [source : String]
  [prefix : String]
  [name : i64]
  [params : ast.AstMacroParamList]
  [ret : ast.AstType]
  [body : i64]
  [acc : LintFindings]
  [name-case : bool]
  [report-unused : bool]) : LintFindings
  (let
    [body-span : ast.AstSourceSpan
      (lint-no-effect-span (ast.ast-node-get body))]
    [cursor : i64
      (lint-unused-variable-decl-param-cursor
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view prefix)
        (ci.intern-str name)
        body-span)]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-macro-param-bindings
        (owned_view.compiler-owned-shared-view params)
        (owned_view.compiler-owned-shared-view source)
        cursor
        body-span
        true)]
    [base-state : LintUnusedVariableState
      (LintUnusedVariableState
        source
        (lint-unused-variable-frames-empty)
        acc
        name-case
        report-unused)]
    [with-cases : LintUnusedVariableState
      (lint-unused-variable-add-binding-name-cases
        base-state
        (owned_view.compiler-owned-shared-view built.bindings))]
    [state : LintUnusedVariableState
      (lint-unused-variable-push-frame
        with-cases
        (owned_view.compiler-owned-shared-view built.bindings))]
    [with-param-types : LintUnusedVariableState
      (lint-unused-variable-type
        ret
        (lint-unused-variable-macro-param-types params state))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr
        (ast.ast-node-get body)
        with-param-types
        body-span)]
    (__tl-project-field (lint-unused-variable-pop-frame with-body) findings)))

(define (lint-unused-variables-in-decl
  [source : String]
  [decl : ast.AstDecl]
  [acc : LintFindings]
  [name-case : bool]
  [report-unused : bool]) : LintFindings
  (match decl
    [(ast.AstDecl.Def decl-meta _ maybe-ty body)
      (__tl-project-field
        (lint-unused-variable-expr
          (ast.ast-node-get body)
          (lint-unused-variable-maybe-type
            maybe-ty
            (LintUnusedVariableState
              source
              (lint-unused-variable-frames-empty)
              acc
              name-case
              report-unused))
          (lint-no-effect-span (ast.ast-node-get body)))
        findings)]
    [(ast.AstDecl.DefFn decl-meta name params ret body _)
      (lint-unused-variable-decl-with-param-frame
        source
        "(define ("
        name
        params
        ret
        body
        acc
        name-case
        report-unused)]
    [(ast.AstDecl.DefMacro decl-meta name params ret body)
      (lint-unused-variable-decl-with-macro-param-frame
        source
        "(defmacro ("
        name
        params
        ret
        body
        acc
        name-case
        report-unused)]
    [(ast.AstDecl.Test _ body _)
      (__tl-project-field
        (lint-unused-variable-expr
          (ast.ast-node-get body)
          (LintUnusedVariableState
            source
            (lint-unused-variable-frames-empty)
            acc
            name-case
            report-unused)
          (lint-no-effect-span (ast.ast-node-get body)))
        findings)]
    [(ast.AstDecl.Unsafe inner)
      (lint-unused-variables-in-decl
        source
        (ast.ast-decl-box-shared-view inner)
        acc
        name-case
        report-unused)]
    [(ast.AstDecl.ModuleBody _ body)
      (if name-case
        (lint-unused-variables-in-decl-list
          source
          (ast.ast-decl-list-box-shared-view body)
          acc
          true
          false)
        acc)]
    [_ acc]))

(define (lint-unused-variables-in-decl-list
  [source : String]
  [decls : ast.AstDeclList]
  [acc : LintFindings]
  [name-case : bool]
  [report-unused : bool]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) acc]
    [(ast.AstDeclListStep.Cons decl rest)
      (lint-unused-variables-in-decl-list
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view rest)
        (lint-unused-variables-in-decl source decl acc name-case report-unused)
        name-case
        report-unused)]))

;: Walk every expression in `exprs`, accumulating findings.
(define (lint-walk-expr-list
  [exprs : ast.AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-expr-list-at (& exprs) threshold acc 0))

(define (lint-walk-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [threshold : i64]
  [acc : LintFindings]
  [index : i64]) : LintFindings
  (if (>= index exprs.len)
    acc
    (let
      [head : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))]
      (lint-walk-expr-list-at
        exprs
        threshold
        (lint-walk-expr head threshold acc)
        (+ index 1)))))

(define (lint-walk-plain-sequence-expr-list
  [exprs : ast.AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-plain-sequence-expr-list-after-terminal exprs threshold acc false))

(define (lint-walk-plain-sequence-expr-list-after-terminal
  [exprs : ast.AstExprList]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]) : LintFindings
  (lint-walk-plain-sequence-expr-list-after-terminal-at
    (& exprs)
    threshold
    acc
    after-terminal
    0))

(define (lint-walk-plain-sequence-expr-list-after-terminal-at
  [exprs : (& exprs ast.AstExprList)]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]
  [index : i64]) : LintFindings
  (if (>= index exprs.len)
    acc
    (let
      [head : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))]
      [rest : ast.AstExprList
        (ast.ast-expr-list-tail-from-ref exprs (+ index 1))]
      (if after-terminal
        (lint-findings-add
          (lint-unreachable-code-finding (lint-no-effect-span head))
          acc)
        (lint-walk-plain-sequence-expr-list-after-terminal-at
          exprs
          threshold
          (lint-walk-expr
            (owned_view.compiler-owned-shared-view head)
            threshold
            (lint-add-redundant-divergence-padding
              (owned_view.compiler-owned-shared-view head)
              rest
              acc))
          (lint-terminal-expr? head)
          (+ index 1))))))

(define (lint-walk-discarded-nonsequence-expr
  [expr : ast.AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [walked : LintFindings
      (lint-walk-expr
        (owned_view.compiler-owned-shared-view expr)
        threshold
        acc)]
    (if (lint-no-effect-pure-expr? (owned_view.compiler-owned-shared-view expr))
      (lint-findings-add
        (lint-no-effect-finding (lint-no-effect-span expr))
        walked)
      walked)))

(define (lint-walk-discarded-expr
  [expr : ast.AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (match inner
          [(ast.AstExpr.Begin _) (lint-walk-expr expr threshold acc)]
          [(ast.AstExpr.WithRegion _ _) (lint-walk-expr expr threshold acc)]
          [(ast.AstExpr.WithEscape _ _) (lint-walk-expr expr threshold acc)]
          [(ast.AstExpr.WithScratch _) (lint-walk-expr expr threshold acc)]
          [(ast.AstExpr.InArena _ _) (lint-walk-expr expr threshold acc)]
          [(ast.AstExpr.WithResource _) (lint-walk-expr expr threshold acc)]
          [_ (lint-walk-discarded-nonsequence-expr expr threshold acc)]))]
    [(ast.AstExpr.Begin _) (lint-walk-expr expr threshold acc)]
    [(ast.AstExpr.WithRegion _ _) (lint-walk-expr expr threshold acc)]
    [(ast.AstExpr.WithEscape _ _) (lint-walk-expr expr threshold acc)]
    [(ast.AstExpr.WithScratch _) (lint-walk-expr expr threshold acc)]
    [(ast.AstExpr.InArena _ _) (lint-walk-expr expr threshold acc)]
    [(ast.AstExpr.WithResource _) (lint-walk-expr expr threshold acc)]
    [_ (lint-walk-discarded-nonsequence-expr expr threshold acc)]))

(define (lint-walk-value-sequence-expr-list
  [exprs : ast.AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-value-sequence-expr-list-after-terminal exprs threshold acc false))

(define (lint-walk-value-sequence-expr-list-after-terminal
  [exprs : ast.AstExprList]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]) : LintFindings
  (lint-walk-value-sequence-expr-list-after-terminal-at
    (& exprs)
    threshold
    acc
    after-terminal
    0))

(define (lint-walk-value-sequence-expr-list-after-terminal-at
  [exprs : (& exprs ast.AstExprList)]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]
  [index : i64]) : LintFindings
  (if (>= index exprs.len)
    acc
    (let
      [head : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))]
      [rest : ast.AstExprList
        (ast.ast-expr-list-tail-from-ref exprs (+ index 1))]
      (if after-terminal
        (lint-findings-add
          (lint-unreachable-code-finding (lint-no-effect-span head))
          acc)
        (let
          [with-padding : LintFindings
            (lint-add-redundant-divergence-padding
              (owned_view.compiler-owned-shared-view head)
              (owned_view.compiler-owned-shared-view rest)
              acc)]
          [walked : LintFindings
            (if (= rest.len 0)
              (lint-walk-expr
                (owned_view.compiler-owned-shared-view head)
                threshold
                with-padding)
              (lint-walk-discarded-expr
                (owned_view.compiler-owned-shared-view head)
                threshold
                with-padding))]
          (lint-walk-value-sequence-expr-list-after-terminal-at
            exprs
            threshold
            walked
            (lint-terminal-expr? head)
            (+ index 1)))))))

(define (lint-walk-tail-sequence-expr-list
  [exprs : ast.AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-tail-sequence-expr-list-after-terminal exprs threshold acc false))

(define (lint-expr-list-single? [exprs : ast.AstExprList]) : bool
  (= exprs.len 1))

(define (lint-add-single-begin
  [exprs : ast.AstExprList]
  [span : ast.AstSourceSpan]
  [acc : LintFindings]) : LintFindings
  (if (lint-expr-list-single? exprs)
    (lint-findings-add (lint-single-begin-finding span) acc)
    acc))

(define (lint-walk-tail-sequence-expr-list-after-terminal
  [exprs : ast.AstExprList]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]) : LintFindings
  (lint-walk-tail-sequence-expr-list-after-terminal-at
    (& exprs)
    threshold
    acc
    after-terminal
    0))

(define (lint-walk-tail-sequence-expr-list-after-terminal-at
  [exprs : (& exprs ast.AstExprList)]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]
  [index : i64]) : LintFindings
  (if (>= index exprs.len)
    acc
    (let
      [head : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))]
      [rest : ast.AstExprList
        (ast.ast-expr-list-tail-from-ref exprs (+ index 1))]
      (if after-terminal
        (lint-findings-add
          (lint-unreachable-code-finding (lint-no-effect-span head))
          acc)
        (let
          [with-padding : LintFindings
            (lint-add-redundant-divergence-padding
              (owned_view.compiler-owned-shared-view head)
              (owned_view.compiler-owned-shared-view rest)
              acc)]
          [walked : LintFindings
            (if (= rest.len 0)
              (lint-walk-tail-expr
                (owned_view.compiler-owned-shared-view head)
                threshold
                with-padding)
              (lint-walk-discarded-expr
                (owned_view.compiler-owned-shared-view head)
                threshold
                with-padding))]
          (lint-walk-tail-sequence-expr-list-after-terminal-at
            exprs
            threshold
            walked
            (lint-terminal-expr? head)
            (+ index 1)))))))

;: Walk each binding initializer in `bindings`.
(define (lint-walk-let-bindings
  [bindings : ast.AstLetBindingList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-let-bindings-at (& bindings) threshold acc 0))

(define (lint-walk-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [threshold : i64]
  [acc : LintFindings]
  [index : i64]) : LintFindings
  (if (>= index (ast.ast-let-binding-list-len bindings))
    acc
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding _ _ init-box)
        (let
          [init : ast.AstExpr (ast.ast-node-get init-box)]
          (lint-walk-let-bindings-at
            bindings
            threshold
            (lint-walk-expr init threshold acc)
            (+ index 1)))])))

(define (lint-let-bindings-contain-name-at?
  [bindings : (& bindings ast.AstLetBindingList)]
  [name : i64]
  [index : i64]) : bool
  (if (>= index (ast.ast-let-binding-list-len bindings))
    false
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding binding-name _ _)
        (if (= binding-name name)
          true
          (lint-let-bindings-contain-name-at? bindings name (+ index 1)))])))

(define (lint-let-bindings-shadow-outer?
  [outer : ast.AstLetBindingList]
  [inner : ast.AstLetBindingList]) : bool
  (lint-let-bindings-shadow-outer-at? (& outer) (& inner) 0))

(define (lint-let-bindings-shadow-outer-at?
  [outer : (& outer ast.AstLetBindingList)]
  [inner : (& inner ast.AstLetBindingList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-let-binding-list-len inner))
    false
    (match (ast.ast-let-binding-list-get
      inner
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name _ _)
        (if (lint-let-bindings-contain-name-at? outer name 0)
          true
          (lint-let-bindings-shadow-outer-at? outer inner (+ index 1)))])))

(define (lint-nested-let-body? [body : ast.AstExpr]) : bool
  (match body
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-nested-let-body? inner))]
    [(ast.AstExpr.Let _) true]
    [_ false]))

(define (lint-nested-let-shadows?
  [outer : ast.AstLetBindingList]
  [body : ast.AstExpr]) : bool
  (match body
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-nested-let-shadows? outer inner))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let inner-bindings _)
          (lint-let-bindings-shadow-outer? outer inner-bindings)])]
    [_ false]))

(define (lint-walk-let
  [bindings : ast.AstLetBindingList]
  [body : ast.AstExpr]
  [span : ast.AstSourceSpan]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [next : LintFindings
      (if (and
        (lint-nested-let-body? (owned_view.compiler-owned-shared-view body))
        (not
          (lint-nested-let-shadows?
            (owned_view.compiler-owned-shared-view bindings)
            (owned_view.compiler-owned-shared-view body))))
        (lint-findings-add (lint-nested-let-finding span) acc)
        acc)]
    (lint-walk-expr
      body
      threshold
      (lint-walk-let-bindings bindings threshold next))))

(define (lint-walk-tail-let
  [bindings : ast.AstLetBindingList]
  [body : ast.AstExpr]
  [span : ast.AstSourceSpan]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [next : LintFindings
      (if (and
        (lint-nested-let-body? (owned_view.compiler-owned-shared-view body))
        (not
          (lint-nested-let-shadows?
            (owned_view.compiler-owned-shared-view bindings)
            (owned_view.compiler-owned-shared-view body))))
        (lint-findings-add (lint-nested-let-finding span) acc)
        acc)]
    (lint-walk-tail-expr
      body
      threshold
      (lint-walk-let-bindings bindings threshold next))))

;: Walk each resource initializer and cleanup expression in `bindings`.
(define (lint-walk-resource-bindings
  [bindings : ast.AstResourceBindingList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-resource-bindings-at (& bindings) threshold acc 0))

(define (lint-walk-resource-bindings-at
  [bindings : (& bindings ast.AstResourceBindingList)]
  [threshold : i64]
  [acc : LintFindings]
  [index : i64]) : LintFindings
  (if (>= index (ast.ast-resource-binding-list-len bindings))
    acc
    (match (ast.ast-resource-binding-list-get
      bindings
      index
      (ast.ast-resource-binding-fallback))
      [(ast.AstResourceBinding.Binding _ init-box cleanup-box _)
        (let
          [init : ast.AstExpr (ast.ast-node-get init-box)]
          [cleanup : ast.AstExpr (ast.ast-node-get cleanup-box)]
          (lint-walk-resource-bindings-at
            bindings
            threshold
            (lint-walk-expr
              cleanup
              threshold
              (lint-walk-expr init threshold acc))
            (+ index 1)))])))

;: Walk each match-arm body in `arms`.
(define (lint-walk-match-arms
  [arms : ast.AstMatchArmList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-match-arms-at (& arms) threshold acc 0))

(define (lint-walk-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [threshold : i64]
  [acc : LintFindings]
  [index : i64]) : LintFindings
  (if (>= index arms.len)
    acc
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm _ body-box)
        (let
          [body : ast.AstExpr (ast.ast-node-get body-box)]
          (lint-walk-match-arms-at
            arms
            threshold
            (lint-walk-expr body threshold acc)
            (+ index 1)))])))

;: Descend an if/else-`if` ladder whose head has already been flagged: walk
;: each rung's condition and then-branch as fresh sub-walks (so a ladder nested
;: inside one of those still flags), but follow the else-chain here WITHOUT
;: re-flagging the inner `if`s, and walk the final non-`if` else normally.
(define (lint-walk-ladder
  [expr : ast.AstExpr]
  [threshold : i64]
  [tail-return-path : bool]
  [acc : LintFindings]) : LintFindings
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-ladder inner threshold tail-return-path acc))]
    [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : ast.AstExpr (ast.ast-node-get cond-box)]
        [then-branch : ast.AstExpr (ast.ast-node-get then-branch-box)]
        [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
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
  [expr : ast.AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-return-path-chain inner threshold acc))]
    [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : ast.AstExpr (ast.ast-node-get cond-box)]
        [then-branch : ast.AstExpr (ast.ast-node-get then-branch-box)]
        [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
        (lint-walk-return-path-chain
          then-branch
          threshold
          (lint-walk-expr
            else-branch
            threshold
            (lint-walk-expr cond threshold acc))))]
    [_ (lint-walk-tail-expr expr threshold acc)]))

(define (lint-walk-unit-if-guard-branch
  [branch : ast.AstExpr]
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
  [cond : ast.AstExpr]
  [then-branch : ast.AstExpr]
  [else-branch : ast.AstExpr]
  [span : ast.AstSourceSpan]
  [tail-return-path : bool]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [ladder : i64
      (+
        1
        (lint-ladder-length (owned_view.compiler-owned-shared-view else-branch)))]
    [return-chain : i64
      (+
        1
        (lint-return-path-chain-length
          (owned_view.compiler-owned-shared-view then-branch)))]
    [then-unit : bool
      (lint-unit-expr? (owned_view.compiler-owned-shared-view then-branch))]
    [else-unit : bool
      (lint-unit-expr? (owned_view.compiler-owned-shared-view else-branch))]
    [then-return : bool
      (lint-return-branch? (owned_view.compiler-owned-shared-view then-branch))]
    [else-return : bool
      (lint-return-branch? (owned_view.compiler-owned-shared-view else-branch))]
    [all-exit-ladder : bool
      (and
        then-return
        (lint-all-exit-ladder-tail?
          (owned_view.compiler-owned-shared-view else-branch)))]
    [cond-not : bool
      (lint-not-call? (owned_view.compiler-owned-shared-view cond))]
    [else-side-effect : bool
      (lint-side-effect-branch?
        (owned_view.compiler-owned-shared-view else-branch))]
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
          (ast.AstExpr.If
            (ast.ast-node-push cond)
            (ast.ast-node-push then-branch)
            (ast.ast-node-push else-branch))
          threshold
          (lint-findings-add
            (lint-return-path-chain-finding return-chain span)
            acc))]
      ;; A maximal else-`if` ladder of length >= threshold is flagged once
      ;; at its head, carrying the ladder depth; lint-walk-ladder then
      ;; descends the else-chain (walking each cond/then) without
      ;; re-emitting.
      [(and (>= ladder threshold) all-exit-ladder)
        (lint-walk-ladder
          (ast.AstExpr.If
            (ast.ast-node-push cond)
            (ast.ast-node-push then-branch)
            (ast.ast-node-push else-branch))
          threshold
          tail-return-path
          acc)]
      [(>= ladder threshold)
        (lint-walk-ladder
          (ast.AstExpr.If
            (ast.ast-node-push cond)
            (ast.ast-node-push
              (owned_view.compiler-owned-shared-view then-branch))
            (ast.ast-node-push
              (owned_view.compiler-owned-shared-view else-branch)))
          threshold
          tail-return-path
          (lint-findings-add
            (lint-ladder-finding then-branch else-branch ladder span)
            acc))]
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
  [exprs : ast.AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-tail-expr-list-after-terminal exprs threshold acc false))

(define (lint-walk-tail-expr-list-after-terminal
  [exprs : ast.AstExprList]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]) : LintFindings
  (lint-walk-tail-expr-list-after-terminal-at
    (& exprs)
    threshold
    acc
    after-terminal
    0))

(define (lint-walk-tail-expr-list-after-terminal-at
  [exprs : (& exprs ast.AstExprList)]
  [threshold : i64]
  [acc : LintFindings]
  [after-terminal : bool]
  [index : i64]) : LintFindings
  (if (>= index exprs.len)
    acc
    (let
      [head : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))]
      [rest : ast.AstExprList
        (ast.ast-expr-list-tail-from-ref exprs (+ index 1))]
      (if after-terminal
        (lint-findings-add
          (lint-unreachable-code-finding (lint-no-effect-span head))
          acc)
        (let
          [with-padding : LintFindings
            (lint-add-redundant-divergence-padding
              (owned_view.compiler-owned-shared-view head)
              (owned_view.compiler-owned-shared-view rest)
              acc)]
          [walked : LintFindings
            (if (= rest.len 0)
              (lint-walk-tail-expr
                (owned_view.compiler-owned-shared-view head)
                threshold
                with-padding)
              (lint-walk-expr
                (owned_view.compiler-owned-shared-view head)
                threshold
                with-padding))]
          (lint-walk-tail-expr-list-after-terminal-at
            exprs
            threshold
            walked
            (lint-terminal-expr? head)
            (+ index 1)))))))

;;; Walk match arms whose bodies are in tail position.
(define (lint-walk-tail-match-arms
  [arms : ast.AstMatchArmList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-tail-match-arms-at (& arms) threshold acc 0))

(define (lint-walk-tail-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [threshold : i64]
  [acc : LintFindings]
  [index : i64]) : LintFindings
  (if (>= index arms.len)
    acc
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm _ body-box)
        (let
          [body : ast.AstExpr (ast.ast-node-get body-box)]
          (lint-walk-tail-match-arms-at
            arms
            threshold
            (lint-walk-tail-expr body threshold acc)
            (+ index 1)))])))

;;; Walk `expr` in a function/lambda/test tail context. The return-path-chain
;;; rule is only valid here: in non-tail value contexts, introducing
;;; `(return ...)` would change the surrounding expression's behavior.
(define (lint-walk-tail-expr
  [expr : ast.AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box span)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (match (owned_view.compiler-owned-shared-view inner)
          [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
            (let
              [cond : ast.AstExpr (ast.ast-node-get cond-box)]
              [then-branch : ast.AstExpr (ast.ast-node-get then-branch-box)]
              [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
              (lint-walk-if
                cond
                then-branch
                else-branch
                span
                true
                threshold
                acc))]
          [(ast.AstExpr.Let let-box)
            (match (__tl-box-place let-box)
              [(ast.AstLet.Let bindings body-box)
                (let
                  [body : ast.AstExpr (ast.ast-node-get body-box)]
                  (lint-walk-tail-let bindings body span threshold acc))])]
          [(ast.AstExpr.Call func-box args)
            (let
              [func : ast.AstExpr (ast.ast-node-get func-box)]
              (lint-walk-call func args span threshold acc))]
          [(ast.AstExpr.Begin exprs)
            (lint-walk-tail-sequence-expr-list
              (owned_view.compiler-owned-shared-view exprs)
              threshold
              (lint-add-single-begin exprs span acc))]
          [_ (lint-walk-tail-expr inner threshold acc)]))]
    [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : ast.AstExpr (ast.ast-node-get cond-box)]
        [then-branch : ast.AstExpr (ast.ast-node-get then-branch-box)]
        [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
        (lint-walk-if
          cond
          then-branch
          else-branch
          (lint-no-span)
          true
          threshold
          acc))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body-box)
          (let
            [body : ast.AstExpr (ast.ast-node-get body-box)]
            (lint-walk-tail-let bindings body (lint-no-span) threshold acc))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda _ _ body-box)
          (let
            [body : ast.AstExpr (ast.ast-node-get body-box)]
            (lint-walk-tail-expr body threshold acc))])]
    [(ast.AstExpr.Begin exprs)
      (lint-walk-tail-sequence-expr-list
        (owned_view.compiler-owned-shared-view exprs)
        threshold
        (lint-add-single-begin exprs (lint-no-span) acc))]
    [(ast.AstExpr.Unsafe exprs) (lint-walk-tail-expr-list exprs threshold acc)]
    [(ast.AstExpr.Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-tail-expr inner threshold acc))]
    [(ast.AstExpr.Cast inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-tail-expr inner threshold acc))]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : ast.AstExpr (ast.ast-node-get scrutinee-box)]
            (lint-walk-tail-match-arms
              arms
              threshold
              (lint-walk-expr scrutinee threshold acc)))])]
    [(ast.AstExpr.WithRegion _ body)
      (lint-walk-tail-sequence-expr-list body threshold acc)]
    [(ast.AstExpr.WithEscape scratch-box body)
      (let
        [scratch : ast.AstExpr (ast.ast-node-get scratch-box)]
        (lint-walk-tail-sequence-expr-list
          body
          threshold
          (lint-walk-expr scratch threshold acc)))]
    [(ast.AstExpr.WithScratch body)
      (lint-walk-tail-sequence-expr-list body threshold acc)]
    [(ast.AstExpr.InArena arena-box body)
      (let
        [arena : ast.AstExpr (ast.ast-node-get arena-box)]
        (lint-walk-tail-sequence-expr-list
          body
          threshold
          (lint-walk-expr arena threshold acc)))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-walk-tail-sequence-expr-list
            body
            threshold
            (lint-walk-resource-bindings bindings threshold acc))])]
    [(ast.AstExpr.Try inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-tail-expr inner threshold acc))]
    [_ (lint-walk-expr expr threshold acc)]))

(define (lint-walk-and-or-skip-expr
  [op : String]
  [expr : ast.AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (if (lint-and-or-call-kind?
          (owned_view.compiler-owned-shared-view op)
          (owned_view.compiler-owned-shared-view inner))
          (lint-walk-and-or-skip-expr op inner threshold acc)
          (lint-walk-expr expr threshold acc)))]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (if (string.eq (lint-and-or-func-op func) op)
          (lint-walk-and-or-skip-args op args threshold acc)
          (lint-walk-expr expr threshold acc)))]
    [_ (lint-walk-expr expr threshold acc)]))

(define (lint-walk-and-or-skip-args
  [op : String]
  [args : ast.AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-and-or-skip-args-at op (& args) threshold acc 0))

(define (lint-walk-and-or-skip-args-at
  [op : String]
  [args : (& args ast.AstExprList)]
  [threshold : i64]
  [acc : LintFindings]
  [index : i64]) : LintFindings
  (if (>= index args.len)
    acc
    (let
      [head-expr : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get args index 0))]
      (lint-walk-and-or-skip-args-at
        (owned_view.compiler-owned-shared-view op)
        args
        threshold
        (lint-walk-and-or-skip-expr op head-expr threshold acc)
        (+ index 1)))))

(define (lint-raw-arena-op-name? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (= n 0)
      false
      (match (string.string-ref (owned_view.compiler-owned-shared-view name) 0)
        ['t'
          (or
            (string.eq
              (owned_view.compiler-owned-shared-view name)
              "tl_arena_set")
            (string.eq
              (owned_view.compiler-owned-shared-view name)
              "tl_arena_destroy")
            (string.eq
              (owned_view.compiler-owned-shared-view name)
              "tl_region_reset"))]
        ['a'
          (or
            (string.eq
              (owned_view.compiler-owned-shared-view name)
              "arena.tl_arena_set")
            (string.eq
              (owned_view.compiler-owned-shared-view name)
              "arena.tl_arena_destroy")
            (string.eq
              (owned_view.compiler-owned-shared-view name)
              "arena.tl_region_reset")
            (string.eq
              (owned_view.compiler-owned-shared-view name)
              "arena.set!")
            (string.eq
              (owned_view.compiler-owned-shared-view name)
              "arena.destroy")
            (string.eq
              (owned_view.compiler-owned-shared-view name)
              "arena.rewind"))]
        [_ false]))))

(define (lint-raw-arena-op-callee? [func : ast.AstExpr]) : bool
  (match func
    [(ast.AstExpr.Spanned inner-box _)
      (lint-raw-arena-op-callee? (ast.ast-node-get inner-box))]
    [(ast.AstExpr.Var name) (lint-raw-arena-op-name? (ci.intern-str name))]
    [_ false]))

(define (lint-raw-arena-op-add
  [func : ast.AstExpr]
  [span : ast.AstSourceSpan]
  [findings : LintFindings]) : LintFindings
  (if (lint-raw-arena-op-callee? func)
    (lint-findings-add (lint-raw-arena-op-finding span) findings)
    findings))

(define (lint-walk-call
  [func : ast.AstExpr]
  [args : ast.AstExprList]
  [span : ast.AstSourceSpan]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [op : String
      (lint-and-or-func-op (owned_view.compiler-owned-shared-view func))]
    [walked-func : LintFindings
      (lint-walk-expr
        (owned_view.compiler-owned-shared-view func)
        threshold
        acc)]
    [callee-findings : LintFindings
      (lint-raw-arena-op-add
        (owned_view.compiler-owned-shared-view func)
        span
        (lint-transitional-core-macro-add
          (owned_view.compiler-owned-shared-view func)
          span
          walked-func))]
    (if (and
      (not (string.eq op ""))
      (lint-and-or-args-have-kind?
        (owned_view.compiler-owned-shared-view op)
        (owned_view.compiler-owned-shared-view args)))
      (lint-walk-and-or-skip-args
        (owned_view.compiler-owned-shared-view op)
        (owned_view.compiler-owned-shared-view args)
        threshold
        (lint-findings-add
          (lint-cascading-and-or-finding op (lint-expr-render func) args span)
          callee-findings))
      (if (and
        (lint-str-cat-func? func)
        (lint-str-cat-args-have-nested?
          (owned_view.compiler-owned-shared-view args)))
        (lint-walk-expr-list
          args
          threshold
          (lint-findings-add (lint-nested-str-cat-finding span) callee-findings))
        (lint-walk-expr-list args threshold callee-findings)))))

;: Walk `expr`, collecting active lint findings while recursing into all
;: sub-expressions. Spanned expressions pass their wrapper span to rules that
;: need source locations.
(define (lint-walk-expr
  [expr : ast.AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match expr
    [(ast.AstExpr.MacroExpansion inner-box _ _)
      (lint-walk-expr (ast.ast-node-get inner-box) threshold acc)]
    [(ast.AstExpr.Spanned inner-box span)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (match (owned_view.compiler-owned-shared-view inner)
          [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
            (let
              [cond : ast.AstExpr (ast.ast-node-get cond-box)]
              [then-branch : ast.AstExpr (ast.ast-node-get then-branch-box)]
              [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
              (lint-walk-if
                cond
                then-branch
                else-branch
                span
                false
                threshold
                acc))]
          [(ast.AstExpr.Let let-box)
            (match (__tl-box-place let-box)
              [(ast.AstLet.Let bindings body-box)
                (let
                  [body : ast.AstExpr (ast.ast-node-get body-box)]
                  (lint-walk-let bindings body span threshold acc))])]
          [(ast.AstExpr.Call func-box args)
            (let
              [func : ast.AstExpr (ast.ast-node-get func-box)]
              (lint-walk-call func args span threshold acc))]
          [(ast.AstExpr.Begin exprs)
            (lint-walk-value-sequence-expr-list
              (owned_view.compiler-owned-shared-view exprs)
              threshold
              (lint-add-single-begin exprs span acc))]
          [_ (lint-walk-expr inner threshold acc)]))]
    [(ast.AstExpr.Literal _) acc]
    [(ast.AstExpr.Var _) acc]
    [(ast.AstExpr.TypeLiteral _) acc]
    [(ast.AstExpr.Init _) acc]
    [(ast.AstExpr.Binary _ left-box right-box)
      (let
        [left : ast.AstExpr (ast.ast-node-get left-box)]
        [right : ast.AstExpr (ast.ast-node-get right-box)]
        (lint-walk-expr right threshold (lint-walk-expr left threshold acc)))]
    [(ast.AstExpr.Unary _ inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (lint-walk-call func args (lint-no-span) threshold acc))]
    [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
      ;; A directly-reached (unspanned) `if`: no wrapper span, so the finding
      ;; gets the sentinel. Maximal-ladder dedup lives in lint-walk-if.
      (let
        [cond : ast.AstExpr (ast.ast-node-get cond-box)]
        [then-branch : ast.AstExpr (ast.ast-node-get then-branch-box)]
        [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
        (lint-walk-if
          cond
          then-branch
          else-branch
          (lint-no-span)
          false
          threshold
          acc))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body-box)
          (let
            [body : ast.AstExpr (ast.ast-node-get body-box)]
            (lint-walk-let bindings body (lint-no-span) threshold acc))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda _ _ body-box)
          (let
            [body : ast.AstExpr (ast.ast-node-get body-box)]
            (lint-walk-expr body threshold acc))])]
    [(ast.AstExpr.Tuple exprs) (lint-walk-expr-list exprs threshold acc)]
    [(ast.AstExpr.TupleRef tuple-box _)
      (let
        [tuple : ast.AstExpr (ast.ast-node-get tuple-box)]
        (lint-walk-expr tuple threshold acc))]
    [(ast.AstExpr.Array exprs) (lint-walk-expr-list exprs threshold acc)]
    [(ast.AstExpr.DynArray exprs) (lint-walk-expr-list exprs threshold acc)]
    [(ast.AstExpr.MakeArray _ len-box)
      (let
        [len : ast.AstExpr (ast.ast-node-get len-box)]
        (lint-walk-expr len threshold acc))]
    [(ast.AstExpr.ArrayRef array-box index-box)
      (let
        [array : ast.AstExpr (ast.ast-node-get array-box)]
        [index : ast.AstExpr (ast.ast-node-get index-box)]
        (lint-walk-expr index threshold (lint-walk-expr array threshold acc)))]
    [(ast.AstExpr.ArraySet array-box index-box value-box)
      (let
        [array : ast.AstExpr (ast.ast-node-get array-box)]
        [index : ast.AstExpr (ast.ast-node-get index-box)]
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        (lint-walk-expr
          value
          threshold
          (lint-walk-expr index threshold (lint-walk-expr array threshold acc))))]
    [(ast.AstExpr.ArrayTake array-box live-box index-box)
      (let
        [array : ast.AstExpr (ast.ast-node-get array-box)]
        [live : ast.AstExpr (ast.ast-node-get live-box)]
        [index : ast.AstExpr (ast.ast-node-get index-box)]
        (lint-walk-expr
          index
          threshold
          (lint-walk-expr live threshold (lint-walk-expr array threshold acc))))]
    [(ast.AstExpr.FixedArrayTake array-box index-box)
      (let
        [array : ast.AstExpr (ast.ast-node-get array-box)]
        [index : ast.AstExpr (ast.ast-node-get index-box)]
        (lint-walk-expr index threshold (lint-walk-expr array threshold acc)))]
    [(ast.AstExpr.Replace place-box replacement-box)
      (let
        [place : ast.AstExpr (ast.ast-node-get place-box)]
        [replacement : ast.AstExpr (ast.ast-node-get replacement-box)]
        (lint-walk-expr
          replacement
          threshold
          (lint-walk-expr place threshold acc)))]
    [(ast.AstExpr.ArrayPush array-box value-box)
      (let
        [array : ast.AstExpr (ast.ast-node-get array-box)]
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr array threshold acc)))]
    [(ast.AstExpr.StringRef str-box index-box)
      (let
        [str : ast.AstExpr (ast.ast-node-get str-box)]
        [index : ast.AstExpr (ast.ast-node-get index-box)]
        (lint-walk-expr index threshold (lint-walk-expr str threshold acc)))]
    [(ast.AstExpr.While cond-box body-box)
      (let
        [cond : ast.AstExpr (ast.ast-node-get cond-box)]
        [body : ast.AstExpr (ast.ast-node-get body-box)]
        (lint-walk-expr body threshold (lint-walk-expr cond threshold acc)))]
    [(ast.AstExpr.ForOwnedState payload)
      (lint-walk-expr
        (ast.ast-node-get (ast.ast-for-owned-state-body (& payload)))
        threshold
        (lint-walk-expr
          (ast.ast-node-get (ast.ast-for-owned-state-source (& payload)))
          threshold
          acc))]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (lint-walk-expr
          (ast.ast-node-get (ast.ast-for-owned-step-body (& payload)))
          threshold
          (if (>= expected-type 0)
            (lint-walk-expr (ast.ast-node-get expected-type) threshold acc)
            acc)))]
    [(ast.AstExpr.Begin exprs)
      (lint-walk-value-sequence-expr-list
        (owned_view.compiler-owned-shared-view exprs)
        threshold
        (lint-add-single-begin exprs (lint-no-span) acc))]
    [(ast.AstExpr.Unsafe exprs)
      (lint-walk-plain-sequence-expr-list exprs threshold acc)]
    [(ast.AstExpr.Set _ value-box)
      (let
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        (lint-walk-expr value threshold acc))]
    [(ast.AstExpr.Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.Cast inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.Borrow _ _ place-box)
      (let
        [place : ast.AstExpr (ast.ast-node-get place-box)]
        (lint-walk-expr place threshold acc))]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : ast.AstExpr (ast.ast-node-get scrutinee-box)]
            (lint-walk-match-arms
              arms
              threshold
              (lint-walk-expr scrutinee threshold acc)))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach _ _ start-box end-box body-box)
          (let
            [start : ast.AstExpr (ast.ast-node-get start-box)]
            [end : ast.AstExpr (ast.ast-node-get end-box)]
            [body : ast.AstExpr (ast.ast-node-get body-box)]
            (lint-walk-expr
              body
              threshold
              (lint-walk-expr
                end
                threshold
                (lint-walk-expr start threshold acc))))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce _ _ _ start-box end-box init-box value-box)
          (let
            [start : ast.AstExpr (ast.ast-node-get start-box)]
            [end : ast.AstExpr (ast.ast-node-get end-box)]
            [init : ast.AstExpr (ast.ast-node-get init-box)]
            [value : ast.AstExpr (ast.ast-node-get value-box)]
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
    [(ast.AstExpr.SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(ast.AstSpmdScan.Scan
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
            [start : ast.AstExpr (ast.ast-node-get start-box)]
            [end : ast.AstExpr (ast.ast-node-get end-box)]
            [init : ast.AstExpr (ast.ast-node-get init-box)]
            [value : ast.AstExpr (ast.ast-node-get value-box)]
            [body : ast.AstExpr (ast.ast-node-get body-box)]
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
    [(ast.AstExpr.SpmdBroadcast value-box lane-box)
      (let
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        [lane : ast.AstExpr (ast.ast-node-get lane-box)]
        (lint-walk-expr lane threshold (lint-walk-expr value threshold acc)))]
    [(ast.AstExpr.SpmdShuffle value-box lane-box)
      (let
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        [lane : ast.AstExpr (ast.ast-node-get lane-box)]
        (lint-walk-expr lane threshold (lint-walk-expr value threshold acc)))]
    [(ast.AstExpr.StructGet receiver-box _)
      (let
        [receiver : ast.AstExpr (ast.ast-node-get receiver-box)]
        (lint-walk-expr receiver threshold acc))]
    [(ast.AstExpr.StructSet receiver-box _ value-box)
      (let
        [receiver : ast.AstExpr (ast.ast-node-get receiver-box)]
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr receiver threshold acc)))]
    [(ast.AstExpr.WithRegion _ body)
      (lint-walk-value-sequence-expr-list body threshold acc)]
    [(ast.AstExpr.WithEscape scratch-box body)
      (let
        [scratch : ast.AstExpr (ast.ast-node-get scratch-box)]
        (lint-walk-value-sequence-expr-list
          body
          threshold
          (lint-walk-expr scratch threshold acc)))]
    [(ast.AstExpr.WithScratch body)
      (lint-walk-value-sequence-expr-list body threshold acc)]
    [(ast.AstExpr.InArena arena-box body)
      (let
        [arena : ast.AstExpr (ast.ast-node-get arena-box)]
        (lint-walk-value-sequence-expr-list
          body
          threshold
          (lint-walk-expr arena threshold acc)))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-walk-value-sequence-expr-list
            body
            threshold
            (lint-walk-resource-bindings bindings threshold acc))])]
    [(ast.AstExpr.Box inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.BoxGet inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.BoxTake inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.BoxSet inner-box value-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr inner threshold acc)))]
    [(ast.AstExpr.Comptime inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.Quote _) acc]
    [(ast.AstExpr.Quasiquote _) acc]
    [(ast.AstExpr.Unquote inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.BracketClause items)
      (lint-walk-expr-list items threshold acc)]
    [(ast.AstExpr.Try inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.Return inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.Break) acc]
    [(ast.AstExpr.Continue) acc]
    [(ast.AstExpr.PtrNull _) acc]
    [(ast.AstExpr.PtrNullCheck inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.PtrAddrOf place-box)
      (let
        [place : ast.AstExpr (ast.ast-node-get place-box)]
        (lint-walk-expr place threshold acc))]
    [(ast.AstExpr.PtrRead ptr-box)
      (let
        [ptr : ast.AstExpr (ast.ast-node-get ptr-box)]
        (lint-walk-expr ptr threshold acc))]
    [(ast.AstExpr.PtrWrite ptr-box value-box)
      (let
        [ptr : ast.AstExpr (ast.ast-node-get ptr-box)]
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        (lint-walk-expr value threshold (lint-walk-expr ptr threshold acc)))]
    [(ast.AstExpr.PtrOffset ptr-box offset-box)
      (let
        [ptr : ast.AstExpr (ast.ast-node-get ptr-box)]
        [offset : ast.AstExpr (ast.ast-node-get offset-box)]
        (lint-walk-expr offset threshold (lint-walk-expr ptr threshold acc)))]
    [(ast.AstExpr.PtrCast ptr-box _)
      (let
        [ptr : ast.AstExpr (ast.ast-node-get ptr-box)]
        (lint-walk-expr ptr threshold acc))]
    [(ast.AstExpr.PtrToInt ptr-box)
      (let
        [ptr : ast.AstExpr (ast.ast-node-get ptr-box)]
        (lint-walk-expr ptr threshold acc))]
    [(ast.AstExpr.IntToPtr value-box _)
      (let
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        (lint-walk-expr value threshold acc))]
    [(ast.AstExpr.StringData inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.StringFromBytes ptr-box len-box)
      (let
        [ptr : ast.AstExpr (ast.ast-node-get ptr-box)]
        [len : ast.AstExpr (ast.ast-node-get len-box)]
        (lint-walk-expr len threshold (lint-walk-expr ptr threshold acc)))]
    [(ast.AstExpr.ArrayData inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-expr inner threshold acc))]
    [(ast.AstExpr.BinaryData _) acc]
    [(ast.AstExpr.SpmdProgramIndex) acc]
    [(ast.AstExpr.SpmdProgramCount) acc]
    [(ast.AstExpr.ProgramArgc) acc]
    [(ast.AstExpr.ProgramArgv) acc]
    [(ast.AstExpr.ProgramEnvp) acc]
    [(ast.AstExpr.CpuIdEax leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (ast.ast-node-get leaf-box)]
        [subleaf : ast.AstExpr (ast.ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(ast.AstExpr.CpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (ast.ast-node-get leaf-box)]
        [subleaf : ast.AstExpr (ast.ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(ast.AstExpr.CpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (ast.ast-node-get leaf-box)]
        [subleaf : ast.AstExpr (ast.ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(ast.AstExpr.CpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (ast.ast-node-get leaf-box)]
        [subleaf : ast.AstExpr (ast.ast-node-get subleaf-box)]
        (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc)))]
    [(ast.AstExpr.Xgetbv index-box)
      (let
        [index : ast.AstExpr (ast.ast-node-get index-box)]
        (lint-walk-expr index threshold acc))]
    [(ast.AstExpr.Syscall args) (lint-walk-expr-list args threshold acc)]))

;: Walk the body expression(s) carried by a declaration, if any.
(define (lint-walk-decl
  [decl : ast.AstDecl]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match decl
    [(ast.AstDecl.Def decl-meta _ _ body-box)
      (let
        [body : ast.AstExpr (ast.ast-node-get body-box)]
        (lint-walk-expr body threshold acc))]
    [(ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
      (let
        [body : ast.AstExpr (ast.ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(ast.AstDecl.DefMacro decl-meta _ _ _ body-box)
      (let
        [body : ast.AstExpr (ast.ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(ast.AstDecl.Test _ body-box _)
      (let
        [body : ast.AstExpr (ast.ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (ast.ast-decl-box-shared-view inner-box)]
        (lint-walk-decl inner threshold acc))]
    [(ast.AstDecl.ModuleBody _ body-box)
      (lint-walk-decl-list
        (ast.ast-decl-list-box-shared-view body-box)
        threshold
        acc)]
    [(ast.AstDecl.Module _) acc]
    [(ast.AstDecl.Extern decl-meta _ _ _ _) acc]
    [(ast.AstDecl.DefEnum decl-meta _ _ _) acc]
    [(ast.AstDecl.DefEnumLifetimes decl-meta _ _ _ _) acc]
    [(ast.AstDecl.DefStruct decl-meta _ _ _ _) acc]
    [(ast.AstDecl.DefStructLifetimes decl-meta _ _ _ _ _) acc]
    [(ast.AstDecl.DefDispatch decl-meta _ _) acc]
    [(ast.AstDecl.IncludeStr _ _) acc]
    [(ast.AstDecl.IncludeStrComptime _ _) acc]
    [(ast.AstDecl.IncludeStrLzss _ _) acc]
    [(ast.AstDecl.IncludeBin _ _) acc]
    [(ast.AstDecl.Import decl-meta _) acc]))

;: Walk every declaration body in `decls`.
(define (lint-walk-decl-list
  [decls : ast.AstDeclList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) acc]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (lint-walk-decl-list rest threshold (lint-walk-decl decl threshold acc)))]))

(define (lint-program-with-source-options
  [source : String]
  [program : ast.AstProgram]
  [threshold : i64]
  [deprecated-string-concat : bool]
  [name-case : bool]) : LintFindings
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        [_line-index : unit
          (lint-source-line-index-build!
            (owned_view.compiler-owned-shared-view source))]
        [copy-on-update-shapes : LintCopyOnUpdateStructList
          (lint-copy-on-update-collect-structs
            (owned_view.compiler-owned-shared-view decls)
            (lint-copy-on-update-structs-empty))]
        [walked : LintFindings
          (lint-walk-decl-list
            (owned_view.compiler-owned-shared-view decls)
            threshold
            (lint-findings-empty))]
        [unused-assignments : LintFindings
          (lint-unused-assignments-in-decl-list
            (owned_view.compiler-owned-shared-view decls)
            walked)]
        [copy-on-update : LintFindings
          (lint-copy-on-update-structs-in-decl-list
            (owned_view.compiler-owned-shared-view decls)
            copy-on-update-shapes
            unused-assignments)]
        [single-element-array-cells : LintFindings
          (lint-single-element-array-cells-in-decl-list
            (owned_view.compiler-owned-shared-view decls)
            copy-on-update)]
        [unused-imports : LintFindings
          (lint-unused-imports-in-decl-list
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view decls)
            (owned_view.compiler-owned-shared-view decls)
            single-element-array-cells)]
        [with-locals : LintFindings
          (lint-unused-variables-in-decl-list
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view decls)
            unused-imports
            name-case
            true)]
        [with-decls : LintFindings
          (if name-case
            (lint-name-case-in-decls
              (owned_view.compiler-owned-shared-view source)
              (owned_view.compiler-owned-shared-view decls)
              with-locals)
            with-locals)]
        (if deprecated-string-concat
          (lint-deprecated-string-concat-scan source with-decls)
          with-decls))]))