;# TypeLisp lint engine + source cleanup rules.
;#
;# A selfhost lint pass: walk the parsed AST, run registered rules, and collect
;# findings. The rules flag body-only nested `let` forms, single-expression
;# `begin` wrappers, nested success-path `if` return chains, unit-branch return
;# guards, no-effect expression statements, nested `str-cat` calls,
;# deprecated user-facing string concatenation primitives, and `begin` forms
;# that an enclosing body sequence makes redundant. It also identifies raw
;# arena-operation calls for the driver's audited-module boundary.
;#
;# The `typelisp lint` CLI driver consumes the rule id attached to each finding
;# for suppression (`;; lint-allow: <rule-id>`). This module owns stable rule
;# metadata and the lint core verified by `compiler-lint-self-test` in the
;# `lint_core_tests.tl` companion (driver: `src/tests/lint_smoke.tl`).
(import compiler_owned_view as owned_view)
(import compiler_diagnostic as cdiag)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import source_text_core as source_text)
(import stdlib.comptime)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import token)
(import lex as lexer)

;: A rule either supplies an ordinary shared diagnostic fix or records why its
;: suggestion is not safe to apply automatically. A finding without a proved
;: edit is never silently promoted to machine-applicable.
(defenum LintFixDecision
  (LintFixUnavailable String String)
  (LintFixAvailable cdiag.CompilerDiagnosticFix))

(define (lint-fix-unproven) : LintFixDecision
  (LintFixUnavailable
    "rule-safety-unproven"
    "This lint suggestion has no validated source edit"))

;: A single lint finding: stable rule id, message, rule-specific depth, span,
;: and an explicit fix/applicability decision. `lint-no-span` denotes generated
;: expressions with no editable source location.
(defstruct LintFinding
  (message String)
  (rule-id String)
  (depth i64)
  (span ast.AstSourceSpan)
  (fix LintFixDecision))

(define (lint-rule-nested-if-ladder-value-message) : String
  "nested if-ladder: value dispatch chain; prefer bracket-arm cond or match")

(define (lint-rule-nested-if-ladder-guard-message) : String
  "nested if-ladder: guard flow chain; prefer cond with guard arms or when/unless")

;: Stable lint severity ordered from disabled to non-overridable error.
(defenum LintLevel
  (Allow)
  (Warn)
  (Deny)
  (Forbid))

(define (lint-level-rank [level : (& level LintLevel)]) : i64
  (match level
    [(Allow) 0]
    [(Warn) 1]
    [(Deny) 2]
    [(Forbid) 3]))

(define lint-group-correctness-mask : i64
  1)
(define lint-group-style-mask : i64
  2)
(define lint-group-complexity-mask : i64
  4)
(define lint-group-performance-mask : i64
  8)
(define lint-group-unsafe-mask : i64
  16)
(define lint-group-compatibility-mask : i64
  32)
(define lint-group-future-incompatibility-mask : i64
  64)

(define (lint-group-correctness-name) : String
  "correctness")

(define (lint-group-style-name) : String
  "style")

(define (lint-group-complexity-name) : String
  "complexity")

(define (lint-group-performance-name) : String
  "performance")

(define (lint-group-unsafe-name) : String
  "unsafe")

(define (lint-group-compatibility-name) : String
  "compatibility")

(define (lint-group-future-incompatibility-name) : String
  "future-incompatibility")

;: Return the stable built-in group bit, or zero for a custom/unknown group.
(define (lint-built-in-group-mask [name : (& name str)]) : i64
  (cond
    [(string.eq name (lint-group-correctness-name)) lint-group-correctness-mask]
    [(string.eq name (lint-group-style-name)) lint-group-style-mask]
    [(string.eq name (lint-group-complexity-name)) lint-group-complexity-mask]
    [(string.eq name (lint-group-performance-name)) lint-group-performance-mask]
    [(string.eq name (lint-group-unsafe-name)) lint-group-unsafe-mask]
    [(string.eq name (lint-group-compatibility-name))
      lint-group-compatibility-mask]
    [(string.eq name (lint-group-future-incompatibility-name))
      lint-group-future-incompatibility-mask]
    [else 0]))

;: Metadata for one lint rule. Rule id is stable public API for suppressions;
;: message is the rendered finding text; suggestion is structured helper text
;: that drivers or tooling can render separately from the message. Defaults
;: preserve the pre-policy CLI, while `group-mask` declares deterministic
;: membership in the initial public rule groups.
(defstruct LintRule
  (rule-id String)
  (message String)
  (suggestion String)
  (default-level LintLevel)
  (group-mask i64))

;: Immutable contiguous registry of registered rules.
(defstruct LintRuleList
  (slots (__tl_dyn-array LintRule))
  (len i64))

(defenum LintMaybeRule
  (NotFound)
  (Found LintRule))

;: Declare lint rule `name`'s stable id (the `lint-allow` suppression key and
;: registry key), finding message and structured suggestion as
;: `lint-rule-<name>-id`, `-message` and `-suggestion`. The generated
;: declarations hold only literals: inline-test harnesses keep imported
;: generated helpers without walking their references, so a level or group
;: mask global used there could be pruned. `lint-rule-registry` pairs each
;: rule with its default level and groups.
(defmacro (deflint-rule [name : Expr] [message : Expr] [suggestion : Expr]) : Decls
  (let
    [id : String
      (match name
        [(Expr.Var value) value]
        [_ (comptime-error "deflint-rule: the rule name must be a bare name")])]
    [prefix : String (comptime.string-append "lint-rule-" id)]
    `(begin
      (define (,(comptime.expr-var (comptime.string-append prefix "-id"))) : String
        ,(comptime.expr-string id))
      (define (,(comptime.expr-var (comptime.string-append prefix "-message"))) : String
        ,message)
      (define (,(comptime.expr-var
          (comptime.string-append prefix "-suggestion"))) : String
        ,suggestion))))

;; The dormant nested-`if`-ladder rule stays registered (its id is the
;; `lint-allow` suppression key) while bootstrap source stays on nested `if`.
;; Findings use the value/guard messages above; the registry message remains
;; for rule metadata lookups.
(deflint-rule
  nested-if-ladder
  "nested if-ladder: chain of if/else-if; prefer cond (value/guard ladders) or match (variant dispatch)"
  "prefer cond (value/guard ladders) or match (variant dispatch)")

(deflint-rule
  nested-let
  "nested let: body is a single let; merge bindings into one sequential let"
  "merge the nested let bindings into one sequential let")

(deflint-rule
  single-begin
  "single begin: begin with one expression is redundant"
  "remove the begin wrapper")

(deflint-rule
  return-path-chain
  "return-path chain: nested success-path ifs; prefer guard clauses with (return ...)"
  "prefer early return guards with (return ...)")

(deflint-rule
  unit-if-guard
  "unit guard if: prefer when/unless"
  "prefer when/unless for unit guard branches")

(deflint-rule
  no-effect
  "no-effect expression: value is discarded"
  "remove the expression or use its value")

(deflint-rule
  unreachable-code
  "unreachable code: expression follows a terminal expression"
  "remove the unreachable expression or move it before the terminal expression")

(deflint-rule
  redundant-divergence-padding
  "redundant divergence padding: trailing expressions after panic/error are dead"
  "remove the trailing dead expression and the stale unreachable-code lint allow")

(deflint-rule
  deprecated-string-concat
  "deprecated string concatenation primitive: use str-cat for fixed arity or text_buf for incremental building"
  "import stdlib/str_cat.tl and use str-cat, or use stdlib/text_buf.tl in accumulation loops")

(deflint-rule
  redundant-begin
  "redundant begin: the enclosing form already evaluates a body sequence"
  "splice the begin forms into the enclosing body")

(deflint-rule
  nested-str-cat
  "nested str-cat: prefer one flat str-cat call"
  "flatten nested str-cat operands into the outer call")

(deflint-rule
  cascading-and-or
  "cascading and/or: prefer one flat n-ary macro call"
  "flatten same-operator and/or operands, e.g. (and a b c)")

(deflint-rule
  transitional-core-macro-qualifier
  "transitional core macro qualifier: use the bare prelude macro spelling"
  "replace core.when/core.unless/core.and/core.or/core.cond with when/unless/and/or/cond")

(deflint-rule
  unused-import
  "unused import: imported module alias is never referenced"
  "remove the import or prefix an intentionally unused alias with _")

(deflint-rule
  redundant-import-alias
  "redundant import alias: dotted module import already binds that alias"
  "remove the explicit as clause")

(deflint-rule
  redundant-function-name
  "redundant function name: local function or macro repeats the module prefix"
  "drop the module prefix from the local function or macro name")

(deflint-rule
  dead-code
  "dead code: top-level declaration is unreachable from package entry/test roots"
  "remove the declaration or reference it from package entry/test roots")

(deflint-rule
  unused-assignment
  "unused assignment: value is overwritten before it is read"
  "remove the assignment or read the value before overwriting it")

(deflint-rule
  copy-on-update-struct
  "copy-on-update struct mutation: prefer in-place field assignment"
  "replace same-struct reassignment with (set! value.field new-value)")

(deflint-rule
  prefer-dynamic-array-literal
  "hand-filled private dynamic buffer: prefer (__tl_make-array v0 v1 ...)"
  "replace the allocation and consecutive array element assignments with a dynamic array literal")

(deflint-rule
  single-element-array-cell
  "single-element array scalar cell: prefer Box T, &mut, or return-value refactoring"
  "replace the one-element array cell with Box T, &mut, or an explicit returned value")

(deflint-rule
  unused-variable
  "unused variable: parameter or local binding is never used"
  "remove the binding or prefix an intentionally unused name with _")

(deflint-rule
  unused-unsafe
  "unused unsafe block: body does not require unsafe context"
  "remove the unsafe wrapper")

(deflint-rule
  raw-arena-op
  "raw arena operation: direct set/destroy/rewind is restricted to audited modules"
  "use in-arena, with-scratch, with-arena, rewind-safe!, or destroy-safe!")

(deflint-rule
  global-name-case
  "global name case: top-level value bindings use kebab-case"
  "rename the binding to kebab-case")

(deflint-rule
  function-name-case
  "function name case: functions, dispatch functions, and macros use kebab-case"
  "rename the declaration to kebab-case")

(deflint-rule
  local-name-case
  "local name case: parameters and local binders use kebab-case; one-letter type operands may use uppercase"
  "rename the parameter or local binding to its conventional case")

(deflint-rule
  type-name-case
  "type name case: struct and enum declarations use UpperCamelCase"
  "rename the type declaration to UpperCamelCase")

;: Small registry for lint metadata. New rules plug into this table and the
;: shared lookup helpers without requiring public driver edits.
(define (lint-rule-registry) : LintRuleList
  (LintRuleList
    (__tl_make-array
      (LintRule
        (lint-rule-nested-if-ladder-id)
        (lint-rule-nested-if-ladder-message)
        (lint-rule-nested-if-ladder-suggestion)
        Warn
        (bit-or lint-group-style-mask lint-group-complexity-mask))
      (LintRule
        (lint-rule-nested-let-id)
        (lint-rule-nested-let-message)
        (lint-rule-nested-let-suggestion)
        Warn
        (bit-or lint-group-style-mask lint-group-complexity-mask))
      (LintRule
        (lint-rule-single-begin-id)
        (lint-rule-single-begin-message)
        (lint-rule-single-begin-suggestion)
        Warn
        lint-group-style-mask)
      (LintRule
        (lint-rule-return-path-chain-id)
        (lint-rule-return-path-chain-message)
        (lint-rule-return-path-chain-suggestion)
        Warn
        (bit-or lint-group-style-mask lint-group-complexity-mask))
      (LintRule
        (lint-rule-unit-if-guard-id)
        (lint-rule-unit-if-guard-message)
        (lint-rule-unit-if-guard-suggestion)
        Warn
        lint-group-style-mask)
      (LintRule
        (lint-rule-no-effect-id)
        (lint-rule-no-effect-message)
        (lint-rule-no-effect-suggestion)
        Warn
        lint-group-correctness-mask)
      (LintRule
        (lint-rule-unreachable-code-id)
        (lint-rule-unreachable-code-message)
        (lint-rule-unreachable-code-suggestion)
        Warn
        lint-group-correctness-mask)
      (LintRule
        (lint-rule-redundant-divergence-padding-id)
        (lint-rule-redundant-divergence-padding-message)
        (lint-rule-redundant-divergence-padding-suggestion)
        Warn
        lint-group-correctness-mask)
      (LintRule
        (lint-rule-deprecated-string-concat-id)
        (lint-rule-deprecated-string-concat-message)
        (lint-rule-deprecated-string-concat-suggestion)
        Allow
        (bit-or
          lint-group-compatibility-mask
          lint-group-future-incompatibility-mask))
      (LintRule
        (lint-rule-redundant-begin-id)
        (lint-rule-redundant-begin-message)
        (lint-rule-redundant-begin-suggestion)
        Allow
        lint-group-style-mask)
      (LintRule
        (lint-rule-nested-str-cat-id)
        (lint-rule-nested-str-cat-message)
        (lint-rule-nested-str-cat-suggestion)
        Warn
        (bit-or lint-group-style-mask lint-group-performance-mask))
      (LintRule
        (lint-rule-cascading-and-or-id)
        (lint-rule-cascading-and-or-message)
        (lint-rule-cascading-and-or-suggestion)
        Warn
        (bit-or lint-group-style-mask lint-group-complexity-mask))
      (LintRule
        (lint-rule-unused-import-id)
        (lint-rule-unused-import-message)
        (lint-rule-unused-import-suggestion)
        Warn
        (bit-or lint-group-correctness-mask lint-group-style-mask))
      (LintRule
        (lint-rule-redundant-import-alias-id)
        (lint-rule-redundant-import-alias-message)
        (lint-rule-redundant-import-alias-suggestion)
        Warn
        lint-group-style-mask)
      (LintRule
        (lint-rule-redundant-function-name-id)
        (lint-rule-redundant-function-name-message)
        (lint-rule-redundant-function-name-suggestion)
        Allow
        lint-group-style-mask)
      (LintRule
        (lint-rule-dead-code-id)
        (lint-rule-dead-code-message)
        (lint-rule-dead-code-suggestion)
        Warn
        lint-group-correctness-mask)
      (LintRule
        (lint-rule-unused-assignment-id)
        (lint-rule-unused-assignment-message)
        (lint-rule-unused-assignment-suggestion)
        Warn
        (bit-or lint-group-correctness-mask lint-group-performance-mask))
      (LintRule
        (lint-rule-copy-on-update-struct-id)
        (lint-rule-copy-on-update-struct-message)
        (lint-rule-copy-on-update-struct-suggestion)
        Warn
        lint-group-performance-mask)
      (LintRule
        (lint-rule-prefer-dynamic-array-literal-id)
        (lint-rule-prefer-dynamic-array-literal-message)
        (lint-rule-prefer-dynamic-array-literal-suggestion)
        Warn
        (bit-or lint-group-style-mask lint-group-performance-mask))
      (LintRule
        (lint-rule-single-element-array-cell-id)
        (lint-rule-single-element-array-cell-message)
        (lint-rule-single-element-array-cell-suggestion)
        Warn
        (bit-or lint-group-style-mask lint-group-performance-mask))
      (LintRule
        (lint-rule-unused-variable-id)
        (lint-rule-unused-variable-message)
        (lint-rule-unused-variable-suggestion)
        Warn
        (bit-or lint-group-correctness-mask lint-group-style-mask))
      (LintRule
        (lint-rule-unused-unsafe-id)
        (lint-rule-unused-unsafe-message)
        (lint-rule-unused-unsafe-suggestion)
        Warn
        lint-group-unsafe-mask)
      (LintRule
        (lint-rule-raw-arena-op-id)
        (lint-rule-raw-arena-op-message)
        (lint-rule-raw-arena-op-suggestion)
        Warn
        (bit-or lint-group-correctness-mask lint-group-unsafe-mask))
      (LintRule
        (lint-rule-transitional-core-macro-qualifier-id)
        (lint-rule-transitional-core-macro-qualifier-message)
        (lint-rule-transitional-core-macro-qualifier-suggestion)
        Warn
        (bit-or
          lint-group-compatibility-mask
          lint-group-future-incompatibility-mask))
      (LintRule
        (lint-rule-global-name-case-id)
        (lint-rule-global-name-case-message)
        (lint-rule-global-name-case-suggestion)
        Allow
        lint-group-style-mask)
      (LintRule
        (lint-rule-function-name-case-id)
        (lint-rule-function-name-case-message)
        (lint-rule-function-name-case-suggestion)
        Allow
        lint-group-style-mask)
      (LintRule
        (lint-rule-local-name-case-id)
        (lint-rule-local-name-case-message)
        (lint-rule-local-name-case-suggestion)
        Allow
        lint-group-style-mask)
      (LintRule
        (lint-rule-type-name-case-id)
        (lint-rule-type-name-case-message)
        (lint-rule-type-name-case-suggestion)
        Allow
        lint-group-style-mask))
    28))

(define (lint-rule-find-at
  [rules : LintRuleList]
  [rule-id : String]
  [index : i64]) : LintMaybeRule
  (if (>= index rules.len)
    NotFound
    (let
      [rule : LintRule
        (owned_view.compiler-owned-array-element-shared-view rules.slots index)]
      (if (string.eq rule.rule-id rule-id)
        (Found rule)
        (lint-rule-find-at rules rule-id (+ index 1))))))

(define (lint-rule-find-in [rules : LintRuleList] [rule-id : String]) : LintMaybeRule
  (lint-rule-find-at rules rule-id 0))

(define (lint-rule-find [rule-id : String]) : LintMaybeRule
  (lint-rule-find-in (lint-rule-registry) rule-id))

(define (lint-rule-list-count [rules : (& rules LintRuleList)]) : i64
  rules.len)

(define (lint-rule-list-ref [rules : (& rules LintRuleList)] [index : i64]) : LintRule
  (owned_view.compiler-owned-array-element-shared-view rules.slots index))

;: True when `rule` belongs to the named initial built-in group. Unknown and
;: custom group names return false; policy resolution owns custom expansion.
(define (lint-rule-in-built-in-group?
  [rule : (& rule LintRule)]
  [group : (& group str)]) : bool
  (let
    [mask : i64 (lint-built-in-group-mask group)]
    (and (> mask 0) (not (= (bit-and rule.group-mask mask) 0)))))

;: Rule registry message lookup. Unknown ids return the empty string.
(define (lint-rule-message [rule-id : String]) : String
  (match (lint-rule-find rule-id)
    [(Found rule) rule.message]
    [(NotFound) ""]))

;: Rule registry suggestion lookup. Unknown ids return the empty string.
(define (lint-rule-suggestion [rule-id : String]) : String
  (match (lint-rule-find rule-id)
    [(Found rule) rule.suggestion]
    [(NotFound) ""]))

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
  [dst : (&mut dst (__tl_dyn-array LintFinding))]
  [src : (__tl_dyn-array LintFinding)]
  [index : i64]
  [count : i64]) : unit
  (unless
    (>= index count)
    (set! (array-ref dst index) (array-ref src index))
    (lint-findings-copy-range dst src (+ index 1) count)))

(define (lint-findings-grow [items : LintFindings]) : LintFindings
  (let
    [n : i64
      (lint-findings-count (owned_view.compiler-owned-shared-view items))]
    [bigger : (__tl_dyn-array LintFinding)
      (__tl_make-array
        LintFinding
        (*
          (lint-findings-capacity (owned_view.compiler-owned-shared-view items))
          2))]
    (lint-findings-copy-range (&mut bigger) (lint-findings-slots items) 0 n)
    (LintFindings bigger n)))

;: Append `finding` to the discoveries, growing the backing array as needed.
(define (lint-findings-add [finding : LintFinding] [items : LintFindings]) : LintFindings
  (if (<
    (lint-findings-count (owned_view.compiler-owned-shared-view items))
    (lint-findings-capacity (owned_view.compiler-owned-shared-view items)))
    (let
      [slots : (__tl_dyn-array LintFinding)
        (lint-findings-slots (owned_view.compiler-owned-shared-view items))]
      [n : i64 (lint-findings-count items)]
      (set! (array-ref slots n) finding)
      (LintFindings slots (+ n 1)))
    (lint-findings-add finding (lint-findings-grow items))))

(define (lint-findings-ref [items : (& items LintFindings)] [index : i64]) : LintFinding
  (let
    [items : LintFindings
      (owned_view.compiler-owned-reference-shared-view items)]
    (array-ref (lint-findings-slots items) index)))

;: Default nested-`if`-ladder depth threshold (an else-chain of this many `if`s
;: or more is flagged).
(define (lint-default-ladder-threshold) : i64
  3)

;: Length of the `if`/else-`if` ladder headed by `expr`: 0 when `expr` is not an
;: `if`, otherwise 1 + the ladder length of its else-branch. Spans are
;: transparent.
(define (lint-ladder-length [expr : ast.AstExpr]) : i64
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-ladder-length inner))]
    [(If _ _ else-branch-box)
      (let
        [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
        (+ 1 (lint-ladder-length else-branch)))]
    [_ 0]))

(define (lint-return-path-chain-length [expr : ast.AstExpr]) : i64
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-return-path-chain-length inner))]
    [(If _ then-branch-box _)
      (let
        [then-branch : ast.AstExpr (ast.ast-node-get then-branch-box)]
        (+ 1 (lint-return-path-chain-length then-branch)))]
    [_ 0]))

(define (lint-unit-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-unit-expr? inner))]
    [(Literal lit)
      (match lit
        [(Unit) true]
        [_ false])]
    [_ false]))

(define (lint-single-arg-call? [args : ast.AstExprList]) : bool
  (= args.len 1))

(define (lint-not-call? [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-not-call? inner))]
    [(Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (match func
          [(Var name)
            (and
              (string.eq (ci.intern-str name) "not")
              (lint-single-arg-call? args))]
          [_ false]))]
    [(Unary (Not) _) true]
    [_ false]))

(define (lint-return-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-return-expr? inner))]
    [(Return _) true]
    [(Break) true]
    [(Continue) true]
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
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-return-branch? inner))]
    [(Return _) true]
    [(Break) true]
    [(Continue) true]
    [(Begin exprs) (lint-expr-list-has-return? exprs)]
    [_ false]))

;: True when `expr` is the remainder of an else-`if` ladder whose then arms
;: and terminal else all exit via return, break, or continue.
(define (lint-all-exit-ladder-tail? [expr : ast.AstExpr]) : bool
  (match (owned_view.compiler-owned-shared-view expr)
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-all-exit-ladder-tail? inner))]
    [(If _ then-branch-box else-branch-box)
      (let
        [then-branch : ast.AstExpr (ast.ast-node-get then-branch-box)]
        [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
        (and
          (lint-return-branch? then-branch)
          (lint-all-exit-ladder-tail? else-branch)))]
    [_ (lint-return-branch? expr)]))

(define (lint-side-effect-branch? [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-side-effect-branch? inner))]
    [(Set _ _) true]
    [(ArraySet _ _ _) true]
    [(ArrayTake _ _ _) true]
    [(Replace _ _) true]
    [(ArrayPush _ _) true]
    [(StructSet _ _ _) true]
    [(Begin exprs) (lint-expr-list-has-side-effect? exprs)]
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
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-guard-ladder-branch? inner))]
    [(Literal lit)
      (match lit
        [(Unit) true]
        [_ false])]
    [(Return _) true]
    [(Break) true]
    [(Continue) true]
    [(Set _ _) true]
    [(ArraySet _ _ _) true]
    [(ArrayTake _ _ _) true]
    [(Replace _ _) true]
    [(ArrayPush _ _) true]
    [(StructSet _ _ _) true]
    [(Begin exprs) (lint-expr-list-last-guard-branch? exprs)]
    [(Unsafe exprs) (lint-expr-list-last-guard-branch? exprs)]
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
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-value-ladder-branch? inner))]
    [(Literal literal)
      (match literal
        [(Unit) false]
        [_ true])]
    [(Var _) true]
    [(Binary _ _ _) true]
    [(Unary _ _) true]
    [(Tuple _) true]
    [(TupleRef _ _) true]
    [(Array _) true]
    [(DynArray _) true]
    [(FixedMakeArray _ _) true]
    [(MakeArray _ _) true]
    [(ArrayRef _ _) true]
    [(StringRef _ _) true]
    [(StructGet _ _) true]
    [(Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-value-ladder-branch? inner))]
    [(Cast _ _) true]
    [(PtrNull _) true]
    [(PtrNullCheck _) true]
    [(PtrRead _) true]
    [(Box _) true]
    [(BoxGet _) true]
    [(BoxTake _) true]
    [(TypeLiteral _) true]
    [(Init _) true]
    [(Begin exprs) (lint-expr-list-last-value-branch? exprs)]
    [_ false]))

(define (lint-if-ladder-guard?
  [then-branch : ast.AstExpr]
  [else-branch : ast.AstExpr]) : bool
  (and
    (lint-guard-ladder-branch?
      (owned_view.compiler-owned-shared-view then-branch))
    (match (owned_view.compiler-owned-shared-view else-branch)
      [(Spanned inner-box _)
        (let
          [inner : ast.AstExpr (ast.ast-node-get inner-box)]
          (lint-if-ladder-guard? then-branch inner))]
      [(If _ nested-then-box nested-else-box)
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
      [(Spanned inner-box _)
        (let
          [inner : ast.AstExpr (ast.ast-node-get inner-box)]
          (lint-if-ladder-value? then-branch inner))]
      [(If _ nested-then-box nested-else-box)
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
    span
    (lint-fix-unproven)))

(define (lint-nested-let-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-nested-let-id))
    (lint-rule-nested-let-id)
    0
    span
    (lint-fix-unproven)))

(define (lint-single-begin-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-single-begin-id))
    (lint-rule-single-begin-id)
    0
    span
    (lint-fix-unproven)))

(define (lint-return-path-chain-finding
  [depth : i64]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-return-path-chain-id))
    (lint-rule-return-path-chain-id)
    depth
    span
    (lint-fix-unproven)))

(define (lint-unit-if-guard-finding
  [then-unit : bool]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (if then-unit
      "unit guard if: unit then-branch; prefer when/unless"
      "unit guard if: unit else-branch; prefer when/unless")
    (lint-rule-unit-if-guard-id)
    1
    span
    (lint-fix-unproven)))

(define (lint-no-effect-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-no-effect-id))
    (lint-rule-no-effect-id)
    0
    span
    (lint-fix-unproven)))

(define (lint-unreachable-code-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-unreachable-code-id))
    (lint-rule-unreachable-code-id)
    0
    span
    (lint-fix-unproven)))

(define (lint-redundant-divergence-padding-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-redundant-divergence-padding-id))
    (lint-rule-redundant-divergence-padding-id)
    0
    span
    (lint-fix-unproven)))

(define (lint-dead-code-finding [name : String] [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "dead code: top-level declaration "
      name
      " is unreachable from package entry/test roots")
    (lint-rule-dead-code-id)
    0
    span
    (lint-fix-unproven)))

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
    span
    (lint-fix-unproven)))

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
    span
    (lint-fix-unproven)))

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
    span
    (lint-fix-unproven)))

(define (lint-prefer-dynamic-array-literal-finding
  [name : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "hand-filled private dynamic buffer: "
      name
      " is initialized by consecutive array-set! calls; prefer (__tl_make-array v0 v1 ...)")
    (lint-rule-prefer-dynamic-array-literal-id)
    0
    span
    (lint-fix-unproven)))

(define (lint-unused-variable-finding
  [name : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat "unused variable: " name " is never used")
    (lint-rule-unused-variable-id)
    0
    span
    (lint-fix-unproven)))

(define (lint-unused-unsafe-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-unused-unsafe-id))
    (lint-rule-unused-unsafe-id)
    0
    span
    (lint-fix-unproven)))

(define (lint-raw-arena-op-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-message (lint-rule-raw-arena-op-id))
    (lint-rule-raw-arena-op-id)
    0
    span
    (lint-fix-unproven)))

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
        (owned_view.compiler-owned-shared-view name))]
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
      span
      (lint-fix-unproven))))

(define (lint-name-case-ascii-lower? [c : char]) : bool
  (and (>= c 'a') (<= c 'z')))

(define (lint-name-case-ascii-upper? [c : char]) : bool
  (and (>= c 'A') (<= c 'Z')))

(define (lint-name-case-ascii-letter? [c : char]) : bool
  (or (lint-name-case-ascii-lower? c) (lint-name-case-ascii-upper? c)))

(define (lint-name-case-ascii-digit? [c : char]) : bool
  (and (>= c '0') (<= c '9')))

(define (lint-name-case-has-ascii-letter? [name : (& name str)]) : bool
  (let
    [n : i64 (string.string-length name)]
    [index : i64 0]
    [found : bool false]
    (while (and (< index n) (not found))
      (if (lint-name-case-ascii-letter? (string.string-ref name index))
        (set! found true)
        (set! index (+ index 1))))
    found))

(define (lint-name-case-terminal-suffix-start [name : (& name str)]) : i64
  (let
    [n : i64 (string.string-length name)]
    (if (= n 0)
      0
      (let
        [last : char (string.string-ref name (- n 1))]
        (if (or (= last '?') (= last '!'))
          (- n 1)
          n)))))

(define (lint-name-case-kebab-range?
  [name : (& name str)]
  [start : i64]
  [end : i64]) : bool
  (let
    [index : i64 start]
    [segment-start : bool true]
    [ok : bool (< start end)]
    (while (and ok (< index end))
      (let
        [c : char (string.string-ref name index)]
        (cond
          [(lint-name-case-ascii-lower? c)
            (set! segment-start false)
            (set! index (+ index 1))]
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
    (and ok (not segment-start))))

;: True for project kebab-case. Predicate/mutator suffixes and the `->`
;: conversion separator are accepted. Names without ASCII letters are operator
;: spellings and are exempt.
(define (lint-name-case-kebab? [name : String]) : bool
  (if (not (lint-name-case-has-ascii-letter? name))
    true
    (lint-name-case-kebab-range?
      name
      0
      (lint-name-case-terminal-suffix-start name))))

;: Local names use kebab-case and may carry exactly one intentional-unused `_`
;: prefix. The wildcard `_` is not a named binding and is accepted here.
(define (lint-name-case-local-kebab? [name : String]) : bool
  (if (string.eq name "_")
    true
    (if (not (lint-name-case-has-ascii-letter? name))
      true
      (let
        [n : i64 (string.string-length name)]
        [start : i64
          (if (and (> n 0) (= (string.string-ref name 0) '_'))
            1
            0)]
        (lint-name-case-kebab-range?
          name
          start
          (lint-name-case-terminal-suffix-start name))))))

;: Struct and enum names use uppercase-initial CamelCase. Acronym runs remain
;: valid; separators and non-ASCII alphanumerics are rejected.
(define (lint-name-case-upper-camel? [name : String]) : bool
  (if (not (lint-name-case-has-ascii-letter? name))
    true
    (let
      [n : i64 (string.string-length name)]
      [index : i64 1]
      [ok : bool
        (and (> n 0) (lint-name-case-ascii-upper? (string.string-ref name 0)))]
      (while (and ok (< index n))
        (let
          [c : char (string.string-ref name index)]
          (if (or
            (lint-name-case-ascii-letter? c)
            (lint-name-case-ascii-digit? c))
            (set! index (+ index 1))
            (set! ok false))))
      ok)))

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
(define (lint-name-case-qualified-symbol? [name : (& name str)]) : bool
  (let
    [n : i64 (string.string-length name)]
    [index : i64 0]
    [found : bool false]
    (while (and (< index n) (not found))
      (if (= (string.string-ref name index) '.')
        (set! found true)
        (set! index (+ index 1))))
    found))

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
  [name : (& name str)]
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
            name
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
              name
              (+ index 1)
              end
              (str_cat.str-cat prefix lower)
              false))]
        [(lint-name-case-ascii-digit? c)
          (if at-word-start
            ""
            (lint-name-case-lower-suggestion-from
              name
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
    [end : i64 (lint-name-case-terminal-suffix-start name)]
    [body : String
      (lint-name-case-lower-suggestion-from name start end "" true)]
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
  [name : (& name str)]
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
              name
              (+ index 1)
              (str_cat.str-cat out piece)
              false))]
        [(lint-name-case-ascii-digit? c)
          (if (string.eq out "")
            ""
            (lint-name-case-upper-camel-suggestion-from
              name
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
    span
    (lint-fix-unproven)))

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

(define (lint-no-effect-span-id [id : i64]) : ast.AstSourceSpan
  (match (ast.ast-expr-view-span id)
    [(No) (lint-no-span)]
    [(Some span) span]))

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
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-terminal-callee? inner))]
    [(Var name)
      (let
        [text : String (ci.intern-str name)]
        (lint-terminal-callee-name? text))]
    [_ false]))

(define (lint-terminal-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(Cast inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-terminal-expr? inner))]
    [(Return _) true]
    [(Call func-box _)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (lint-terminal-callee? func))]
    [_ false]))

(define (lint-diverging-call-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-diverging-call-expr? inner))]
    [(Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-diverging-call-expr? inner))]
    [(Cast inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-diverging-call-expr? inner))]
    [(Call func-box _)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (lint-terminal-callee? func))]
    [_ false]))

(define (lint-add-redundant-divergence-padding
  [head-id : i64]
  [rest : (& rest ast.AstExprList)]
  [acc : LintFindings]) : LintFindings
  (let
    [head : ast.AstExpr (ast.ast-node-get head-id)]
    (if (= rest.len 0)
      acc
      (if (lint-diverging-call-expr? head)
        (lint-findings-add
          (lint-redundant-divergence-padding-finding
            (lint-no-effect-span-id head-id))
          acc)
        acc))))

(define (lint-no-effect-pure-binop? [op : ast.AstBinOp]) : bool
  (match op
    ;; These operators can intentionally trap, so keep the syntactic rule
    ;; conservative until typed/effect metadata can prove safety.
    [(Div) false]
    [(Mod) false]
    [(Shl) false]
    [(Shr) false]
    [_ true]))

(define (lint-no-effect-pure-literal? [lit : ast.AstLiteral]) : bool
  (match lit
    [(Unit) false]
    [_ true]))

(define (lint-no-effect-pure-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(Literal lit) (lint-no-effect-pure-literal? lit)]
    [(Var _) true]
    [(TypeLiteral _) true]
    [(Binary op left-box right-box)
      (let
        [left : ast.AstExpr (ast.ast-node-get left-box)]
        [right : ast.AstExpr (ast.ast-node-get right-box)]
        (and
          (lint-no-effect-pure-binop? op)
          (lint-no-effect-pure-expr? left)
          (lint-no-effect-pure-expr? right)))]
    [(Unary _ inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(Cast inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-no-effect-pure-expr? inner))]
    [(PtrNull _) true]
    [_ false]))

(define (lint-deprecated-string-concat-name? [name : (& name str)]) : bool
  (or
    (string.eq name "string-append")
    (string.eq name "string.append")
    (string.eq name "string-concat")
    (string.eq name "string.concat")
    (string.eq name "string.concat3")
    (string.eq name "string.concat4")
    (string.eq name "string.concat5")))

(define (lint-deprecated-string-concat-loop-form? [name : (& name str)]) : bool
  (or
    (string.eq name "while")
    (string.eq name "foreach")
    (string.eq name "foreach-active")
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
    span
    (lint-fix-unproven)))

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
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-and-or-func-op inner))]
    [(Var name) (lint-and-or-op-name (ci.intern-str name))]
    [_ ""]))

(define (lint-transitional-core-macro-bare-name [name : (& name str)]) : String
  (cond
    [(string.eq name "core.when") "when"]
    [(string.eq name "core.unless") "unless"]
    [(string.eq name "core.and") "and"]
    [(string.eq name "core.or") "or"]
    [(string.eq name "core.cond") "cond"]
    [else ""]))

(define (lint-transitional-core-macro-qualified-name [func : ast.AstExpr]) : String
  (match func
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-transitional-core-macro-qualified-name inner))]
    [(Var name)
      (let
        [text : String (ci.intern-str name)]
        (if (string.eq (lint-transitional-core-macro-bare-name text) "")
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
    span
    (lint-fix-unproven)))

(define (lint-transitional-core-macro-add
  [func : ast.AstExpr]
  [span : ast.AstSourceSpan]
  [acc : LintFindings]) : LintFindings
  (let
    [qualified : String (lint-transitional-core-macro-qualified-name func)]
    [bare : String (lint-transitional-core-macro-bare-name qualified)]
    (if (string.eq bare "")
      acc
      (lint-findings-add
        (lint-transitional-core-macro-finding qualified bare span)
        acc))))

(define (lint-str-cat-func? [func : ast.AstExpr]) : bool
  (match func
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-str-cat-func? inner))]
    [(Var name) (string.eq (ci.intern-str name) "str-cat")]
    [_ false]))

(define (lint-literal-render [lit : ast.AstLiteral]) : String
  (match lit
    [(Int value text)
      (if (> (string.string-length text) 0)
        text
        (string.int->string value))]
    [(Float value) value]
    [(Bool value)
      (if value
        "true"
        "false")]
    [(String string-id) (str_cat.str-cat "\"" (ci.intern-str string-id) "\"")]
    [(Unit) "unit"]
    [_ "<expr>"]))

(define (lint-bin-op-render [op : ast.AstBinOp]) : String
  (match op
    [(Add) "+"]
    [(Sub) "-"]
    [(Mul) "*"]
    [(Div) "/"]
    [(Mod) "%"]
    [(Eq) "="]
    [(Ne) "!="]
    [(Lt) "<"]
    [(Le) "<="]
    [(Gt) ">"]
    [(Ge) ">="]
    [(And) "and"]
    [(Or) "or"]
    [(BitAnd) "bit-and"]
    [(BitOr) "bit-or"]
    [(BitXor) "bit-xor"]
    [(Shl) "shl"]
    [(Shr) "shr"]))

(define (lint-un-op-render [op : ast.AstUnOp]) : String
  (match op
    [(Neg) "-"]
    [(Not) "not"]
    [(BitNot) "bit-not"]))

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
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-expr-render inner))]
    [(Var name) (ci.intern-str name)]
    [(Literal lit) (lint-literal-render lit)]
    [(Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (lint-parenthesized-call-render
          (lint-expr-render func)
          (lint-expr-list-render args)))]
    [(Binary op left-box right-box)
      (let
        [left : ast.AstExpr (ast.ast-node-get left-box)]
        [right : ast.AstExpr (ast.ast-node-get right-box)]
        (lint-parenthesized-call-render
          (lint-bin-op-render op)
          (lint-render-args-join
            (lint-expr-render left)
            (lint-expr-render right))))]
    [(Unary op inner-box)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-parenthesized-call-render
          (lint-un-op-render op)
          (lint-expr-render inner)))]
    [_ "<expr>"]))

(define (lint-and-or-call-kind? [op : (& op str)] [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-and-or-call-kind? op inner))]
    [(Call func-box _)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (string.eq (lint-and-or-func-op func) op))]
    [_ false]))

(define (lint-and-or-args-have-kind?
  [op : String]
  [args : (& args ast.AstExprList)]) : bool
  (lint-and-or-args-have-kind-at? op (& args) 0))

(define (lint-and-or-args-have-kind-at?
  [op : (& op str)]
  [args : (& args ast.AstExprList)]
  [index : i64]) : bool
  (if (>= index args.len)
    false
    (let
      [head-expr : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get args index 0))]
      (if (lint-and-or-call-kind? op head-expr)
        true
        (lint-and-or-args-have-kind-at? op args (+ index 1))))))

(define (lint-str-cat-call? [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-str-cat-call? inner))]
    [(Call func-box _)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (lint-str-cat-func? func))]
    [_ false]))

(define (lint-str-cat-args-have-nested? [args : (& args ast.AstExprList)]) : bool
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
  [op : (& op str)]
  [expr : ast.AstExpr]) : String
  (match (owned_view.compiler-owned-shared-view expr)
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-cascading-and-or-flat-arg-render op inner))]
    [(Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (if (string.eq (lint-and-or-func-op func) op)
          (lint-cascading-and-or-flat-args-render op args)
          (lint-expr-render expr)))]
    [_ (lint-expr-render expr)]))

(define (lint-cascading-and-or-flat-args-render
  [op : (& op str)]
  [args : (& args ast.AstExprList)]) : String
  (lint-cascading-and-or-flat-args-render-at op (& args) 0))

(define (lint-cascading-and-or-flat-args-render-at
  [op : (& op str)]
  [args : (& args ast.AstExprList)]
  [index : i64]) : String
  (if (>= index args.len)
    ""
    (let
      [head-expr : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get args index 0))]
      (lint-render-args-join
        (lint-cascading-and-or-flat-arg-render op head-expr)
        (lint-cascading-and-or-flat-args-render-at op args (+ index 1))))))

(define (lint-cascading-and-or-flat-arg-count
  [op : (& op str)]
  [expr : ast.AstExpr]) : i64
  (match expr
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-cascading-and-or-flat-arg-count op inner))]
    [(Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (if (string.eq (lint-and-or-func-op func) op)
          (lint-cascading-and-or-flat-arg-count-list op args)
          1))]
    [_ 1]))

(define (lint-cascading-and-or-flat-arg-count-list
  [op : (& op str)]
  [args : (& args ast.AstExprList)]) : i64
  (lint-cascading-and-or-flat-arg-count-list-at op (& args) 0))

(define (lint-cascading-and-or-flat-arg-count-list-at
  [op : (& op str)]
  [args : (& args ast.AstExprList)]
  [index : i64]) : i64
  (if (>= index args.len)
    0
    (let
      [head-expr : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get args index 0))]
      (+
        (lint-cascading-and-or-flat-arg-count op head-expr)
        (lint-cascading-and-or-flat-arg-count-list-at op args (+ index 1))))))

(define (lint-cascading-and-or-flat-call
  [callee : String]
  [op : (& op str)]
  [args : (& args ast.AstExprList)]) : String
  (lint-parenthesized-call-render
    callee
    (lint-cascading-and-or-flat-args-render op args)))

(define (lint-cascading-and-or-finding
  [op : String]
  [callee : String]
  [args : (& args ast.AstExprList)]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "cascading "
      (owned_view.compiler-owned-shared-view op)
      ": prefer flat n-ary form "
      (lint-cascading-and-or-flat-call callee op args))
    (lint-rule-cascading-and-or-id)
    (lint-cascading-and-or-flat-arg-count-list op args)
    span
    (lint-fix-unproven)))

(define (lint-nested-str-cat-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-nested-str-cat-message)
    (lint-rule-nested-str-cat-id)
    0
    span
    (lint-fix-unproven)))

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
    [(Err _) acc]
    [(Ok toks)
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
        (while (not done)
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
                    (lint-deprecated-string-concat-loop-form? name)]
                  [is-concat : bool (lint-deprecated-string-concat-name? name)]
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
                    unit))]
              [(= tag (token.tag-rparen))
                (when
                  (> depth 0)
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
                  (set! depth (- depth 1)))]
              [else unit]))
          (set! i (+ i 1)))
        findings)]))

;; ---- redundant-begin ----
;;
;; A `(begin ...)` of two or more forms written directly in a position that
;; already evaluates a body sequence (a let/define/lambda/while/... body, or a
;; match or cond arm body) can be spliced into that sequence. The rule reads
;; the token stream, so it sees exactly the source forms: a body sequence the
;; parser builds is never mistaken for a written `begin`. A begin under a quote
;; or directly behind a reader prefix, one with a bracket form or a `(cfg ...)`
;; form, and one projected with `.field` stay as written. A cfg form makes the
;; body depend on the configuration: spliced into a `let`, the body can shrink
;; to a lone `let` once cfg drops the rest, which `nested-let` rejects.
;;
;; `when`, `unless` and `while` check every body form as `unit`, while `begin`
;; discards its non-final values, and this rule has no types. Under them it
;; only reports a begin whose forms the splice exposes to that check (every
;; form but the last, through nested begins that may be spliced too) are
;; syntactically unit: `set!`, `while`, `when`, `unless`, `for`, `unit`, and
;; `begin`/`let`/`unsafe`/`if` ending in those.
;: Child position from which a form headed by `head` evaluates a body
;: sequence, or -1. `nested` is false for a top-level form, where `unsafe` and
;: `begin` wrap declarations and where alone `(test name body...)` is a test
;: rather than a call; `function` says whether a `define` declares a function.
(define (lint-redundant-begin-body-start
  [head : (& head str)]
  [nested : bool]
  [function : bool]) : i64
  (cond
    [(or
        (string.eq head "let")
        (string.eq head "for")
        (string.eq head "with-scratch"))
      1]
    [(or (string.eq head "unsafe") (string.eq head "begin"))
      (if nested
        1
        -1)]
    [(or
        (string.eq head "while")
        (string.eq head "when")
        (string.eq head "unless")
        (string.eq head "lambda")
        (string.eq head "defmacro")
        (string.eq head "in-arena")
        (string.eq head "with-arena")
        (string.eq head "with-escape")
        (string.eq head "with"))
      2]
    [(string.eq head "test")
      (if nested
        -1
        2)]
    [(string.eq head "define")
      (if function
        2
        -1)]
    [else -1]))

(define (lint-redundant-begin-unit-guard? [head : (& head str)]) : bool
  (or
    (string.eq head "when")
    (string.eq head "unless")
    (string.eq head "while")))

(define (lint-token-tag-at
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [index : i64]) : i64
  (token.tag-ref (token.spanned-token-token-ref (& (array-ref toks index)))))

(define (lint-token-name-at
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [index : i64]) : String
  (if (= (lint-token-tag-at toks index) (token.tag-sym))
    (ci.intern-id-str
      (token.sym-id (token.spanned-token-token-ref (& (array-ref toks index)))))
    ""))

(define (lint-token-line-at
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [index : i64]) : i64
  (token.spanned-token-line (& (array-ref toks index))))

(define (lint-token-col-at
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [index : i64]) : i64
  (token.spanned-token-col (& (array-ref toks index))))

(define (lint-token-prefix-tag? [tag : i64]) : bool
  (or
    (= tag (token.tag-quote))
    (= tag (token.tag-backtick))
    (= tag (token.tag-comma))
    (= tag (token.tag-comma-at))))

(define (lint-token-open-tag? [tag : i64]) : bool
  (or (= tag (token.tag-lparen)) (= tag (token.tag-lbracket))))

(define (lint-token-close-tag? [tag : i64]) : bool
  (or (= tag (token.tag-rparen)) (= tag (token.tag-rbracket))))

;: Matching close token of every open token, or -1 when it has none.
(define (lint-token-close-indexes
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [count : i64]) : (__tl_dyn-array i64)
  (let
    [close-of : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
    [stack : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
    [depth : i64 0]
    [index : i64 0]
    (while (<= index count)
      (let
        [tag : i64 (lint-token-tag-at toks index)]
        (set! (array-ref close-of index) -1)
        (cond
          [(lint-token-open-tag? tag)
            (set! (array-ref stack depth) index)
            (set! depth (+ depth 1))]
          [(and (lint-token-close-tag? tag) (> depth 0))
            (set! depth (- depth 1))
            (set! (array-ref close-of (array-ref stack depth)) index)]
          [else unit])
        (set! index (+ index 1))))
    close-of))

;: Index just past the form at `index`, reader prefixes included.
(define (lint-token-form-end
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [close-of : (& close-of (__tl_dyn-array i64))]
  [index : i64]) : i64
  (let
    [at : i64 index]
    (while (lint-token-prefix-tag? (lint-token-tag-at toks at))
      (set! at (+ at 1)))
    (cond
      [(and
          (lint-token-open-tag? (lint-token-tag-at toks at))
          (>= (array-ref close-of at) 0))
        (+ (array-ref close-of at) 1)]
      [(= (lint-token-tag-at toks at) (token.tag-end)) at]
      [else (+ at 1)])))

;: Start of the last child form of the list opened at `open`, or -1 when the
;: list has no form after its head.
(define (lint-token-last-child
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [close-of : (& close-of (__tl_dyn-array i64))]
  [open : i64]) : i64
  (let
    [close : i64 (array-ref close-of open)]
    [at : i64 (lint-token-form-end toks close-of (+ open 1))]
    [last : i64 -1]
    (while (< at close)
      (set! last at)
      (set! at (lint-token-form-end toks close-of at)))
    last))

(define (lint-token-paren-head
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [index : i64]) : String
  (if (= (lint-token-tag-at toks index) (token.tag-lparen))
    (lint-token-name-at toks (+ index 1))
    ""))

;: Whether the form at `index` is syntactically unit-valued.
(define (lint-redundant-begin-unit-form?
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [close-of : (& close-of (__tl_dyn-array i64))]
  [index : i64]) : bool
  (let
    [head : String (lint-token-paren-head toks index)]
    (cond
      [(= (lint-token-tag-at toks index) (token.tag-sym))
        (string.eq (lint-token-name-at toks index) "unit")]
      [(or
          (string.eq head "set!")
          (string.eq head "while")
          (string.eq head "when")
          (string.eq head "unless")
          (string.eq head "for"))
        true]
      [(or
          (string.eq head "begin")
          (string.eq head "let")
          (string.eq head "unsafe"))
        (let
          [last : i64 (lint-token-last-child toks close-of index)]
          (and (>= last 0) (lint-redundant-begin-unit-form? toks close-of last)))]
      [(string.eq head "if")
        (let
          [then-at : i64 (lint-token-form-end toks close-of (+ index 2))]
          [else-at : i64 (lint-token-form-end toks close-of then-at)]
          (and
            (=
              (lint-token-form-end toks close-of else-at)
              (array-ref close-of index))
            (lint-redundant-begin-unit-form? toks close-of then-at)
            (lint-redundant-begin-unit-form? toks close-of else-at)))]
      [else false])))

;: Under `when`/`unless`/`while`, splicing the begin at `open` (and any begin nested
;: directly in it) exposes its forms to the unit check: every form except the
;: very last must be syntactically unit, and none may carry a reader prefix.
(define (lint-redundant-begin-unit-safe?
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [close-of : (& close-of (__tl_dyn-array i64))]
  [open : i64]
  [final : bool]) : bool
  (let
    [close : i64 (array-ref close-of open)]
    [at : i64 (lint-token-form-end toks close-of (+ open 1))]
    [ok : bool true]
    (while (and ok (< at close))
      (let
        [next : i64 (lint-token-form-end toks close-of at)]
        [last : bool (and final (= next close))]
        (set!
          ok
          (cond
            [(lint-token-prefix-tag? (lint-token-tag-at toks at)) false]
            [(string.eq (lint-token-paren-head toks at) "begin")
              (lint-redundant-begin-unit-safe? toks close-of at last)]
            [last true]
            [else (lint-redundant-begin-unit-form? toks close-of at)]))
        (set! at next)))
    ok))

;: Whether the begin opened at `open` has at least two forms and no bracket
;: or `(cfg ...)` form among them.
(define (lint-redundant-begin-spliceable?
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [close-of : (& close-of (__tl_dyn-array i64))]
  [open : i64]) : bool
  (let
    [close : i64 (array-ref close-of open)]
    [at : i64 (lint-token-form-end toks close-of (+ open 1))]
    [count : i64 0]
    [ok : bool true]
    (while (and ok (< at close))
      (when
        (or
          (= (lint-token-tag-at toks at) (token.tag-lbracket))
          (string.eq (lint-token-paren-head toks at) "cfg"))
        (set! ok false))
      (set! count (+ count 1))
      (set! at (lint-token-form-end toks close-of at)))
    (and ok (>= count 2))))

;: A `.field` projection written directly after the close token at `close`.
(define (lint-token-projected?
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [close : i64]) : bool
  (let
    [name : String (lint-token-name-at toks (+ close 1))]
    (and
      (> (string.string-length name) 0)
      (= (string.string-ref name 0) '.')
      (= (lint-token-line-at toks (+ close 1)) (lint-token-line-at toks close))
      (=
        (lint-token-col-at toks (+ close 1))
        (+ (lint-token-col-at toks close) 1)))))

(define (lint-redundant-begin-delete
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : cdiag.CompilerDiagnosticTextEdit
  (cdiag.compiler-diagnostic-text-edit-new
    (cdiag.CompilerDiagnosticSpan "" start-line start-col end-line end-col)
    ""))

;: The machine-applicable fix deletes the matching `)` and `(begin` with the
;: blanks after it, or the whole line when `(begin` stands alone on it.
;: Re-indenting the result is left to `fmt`.
(define (lint-redundant-begin-finding
  [source : (& source str)]
  [line-starts : (& line-starts (__tl_dyn-array i64))]
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [open : i64]
  [close : i64]) : LintFinding
  (let
    [line : i64 (lint-token-line-at toks open)]
    [col : i64 (lint-token-col-at toks open)]
    [head-line : i64 (lint-token-line-at toks (+ open 1))]
    [head-end : i64 (+ (lint-token-col-at toks (+ open 1)) 5)]
    [source-len : i64 (string.string-length source)]
    [line-start : i64 (source_text.source-text-line-start line-starts line)]
    [after : i64
      (+
        (source_text.source-text-line-start line-starts head-line)
        (- head-end 1))]
    [blank-end : i64 after]
    [close-line : i64 (lint-token-line-at toks close)]
    [close-col : i64 (lint-token-col-at toks close)]
    [edits : (__tl_dyn-array cdiag.CompilerDiagnosticTextEdit)
      (__tl_make-array cdiag.CompilerDiagnosticTextEdit 2)]
    (while (and
      (< blank-end source-len)
      (or
        (= (string.string-ref source blank-end) ' ')
        (= (string.string-ref source blank-end) '\t')))
      (set! blank-end (+ blank-end 1)))
    (set!
      (array-ref edits 0)
      (if (and
        (= line head-line)
        (lint-source-blank-range? source line-start (+ line-start (- col 1)))
        (< blank-end source-len)
        (or
          (= (string.string-ref source blank-end) '\n')
          (and
            (= (string.string-ref source blank-end) '\r')
            (< (+ blank-end 1) source-len)
            (= (string.string-ref source (+ blank-end 1)) '\n'))))
        (lint-redundant-begin-delete line 1 (+ line 1) 1)
        (lint-redundant-begin-delete
          line
          col
          head-line
          (+ head-end (- blank-end after)))))
    (set!
      (array-ref edits 1)
      (lint-redundant-begin-delete
        close-line
        close-col
        close-line
        (+ close-col 1)))
    (LintFinding
      (lint-rule-redundant-begin-message)
      (lint-rule-redundant-begin-id)
      0
      (ast.ast-source-span line col head-line head-end)
      (LintFixAvailable
        (cdiag.compiler-diagnostic-fix-new
          "splice the begin forms into the enclosing body"
          CompilerDiagnosticMachineApplicable
          (cdiag.CompilerDiagnosticTextEditSeq edits 2))))))

(define (lint-source-blank-range?
  [source : (& source str)]
  [start : i64]
  [end : i64]) : bool
  (let
    [at : i64 start]
    (while (and
      (< at end)
      (or
        (= (string.string-ref source at) ' ')
        (= (string.string-ref source at) '\t')))
      (set! at (+ at 1)))
    (>= at end)))

;: Whether the begin opened at `open`, child `position` of the frame at
;: `depth`, sits in a body sequence that it can be spliced into.
(define (lint-redundant-begin-context?
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [close-of : (& close-of (__tl_dyn-array i64))]
  [open : i64]
  [position : i64]
  [depth : i64]
  [frame-open : (& frame-open (__tl_dyn-array i64))]
  [frame-head : (& frame-head (__tl_dyn-array String))]
  [frame-position : (& frame-position (__tl_dyn-array i64))]) : bool
  (let
    [parent : i64 (array-ref frame-open depth)]
    (and
      (lint-redundant-begin-spliceable? toks close-of open)
      (not (lint-token-projected? toks (array-ref close-of open)))
      (if (= (lint-token-tag-at toks parent) (token.tag-lbracket))
        (let
          [arm-of : String
            (if (> depth 1)
              (string.copy (& (array-ref frame-head (- depth 1))))
              "")]
          [arm-position : i64 (array-ref frame-position depth)]
          (and
            (>= position 1)
            (or
              (and (string.eq arm-of "match") (>= arm-position 2))
              (and (string.eq arm-of "cond") (>= arm-position 1)))))
        (let
          [head : String (string.copy (& (array-ref frame-head depth)))]
          [start : i64
            (lint-redundant-begin-body-start
              (& head)
              (> depth 1)
              (= (lint-token-tag-at toks (+ parent 2)) (token.tag-lparen)))]
          (and
            (>= start 0)
            (>= position start)
            (or
              (not (lint-redundant-begin-unit-guard? (& head)))
              (lint-redundant-begin-unit-safe? toks close-of open true))))))))

;: Report every redundant `(begin ...)` in `source`, as described above.
(define (lint-redundant-begin-scan [source : String] [acc : LintFindings]) : LintFindings
  (match (lexer.spanned-result (owned_view.compiler-owned-shared-view source))
    [(Err _) acc]
    [(Ok toks)
      (let
        [count : i64 0]
        (while (not (= (lint-token-tag-at (& toks) count) (token.tag-end)))
          (set! count (+ count 1)))
        (let
          [close-of : (__tl_dyn-array i64)
            (lint-token-close-indexes (& toks) count)]
          [line-starts : (__tl_dyn-array i64)
            (source_text.source-text-line-starts (& source))]
          [frames : i64 (+ count 2)]
          ;; Open frames: the open token, its head name, the children seen
          ;; so far, its child position in the enclosing frame, and whether
          ;; it is quoted data. Frame 0 is the top level.
          [frame-open : (__tl_dyn-array i64) (__tl_make-array i64 frames)]
          [frame-head : (__tl_dyn-array String) (__tl_make-array String frames)]
          [frame-count : (__tl_dyn-array i64) (__tl_make-array i64 frames)]
          [frame-position : (__tl_dyn-array i64) (__tl_make-array i64 frames)]
          [frame-quoted : (__tl_dyn-array bool) (__tl_make-array bool frames)]
          [depth : i64 0]
          [prefix : i64 0]
          [index : i64 0]
          [findings : LintFindings acc]
          (set! (array-ref frame-open 0) -1)
          (set! (array-ref frame-head 0) "")
          (set! (array-ref frame-count 0) 0)
          (set! (array-ref frame-position 0) 0)
          (set! (array-ref frame-quoted 0) false)
          (while (< index count)
            (let
              [tag : i64 (lint-token-tag-at (& toks) index)]
              (cond
                [(lint-token-prefix-tag? tag) (set! prefix tag)]
                [(and
                    (lint-token-open-tag? tag)
                    (>= (array-ref close-of index) 0))
                  (let
                    [position : i64 (array-ref frame-count depth)]
                    [head : String (lint-token-paren-head (& toks) index)]
                    [quoted : bool
                      (or
                        (array-ref frame-quoted depth)
                        (= prefix (token.tag-quote))
                        (string.eq head "quote"))]
                    (set! (array-ref frame-count depth) (+ position 1))
                    (when
                      (and
                        (string.eq head "begin")
                        (not quoted)
                        (= prefix 0)
                        (> depth 0)
                        (lint-redundant-begin-context?
                          (& toks)
                          (& close-of)
                          index
                          position
                          depth
                          (& frame-open)
                          (& frame-head)
                          (& frame-position)))
                      (set!
                        findings
                        (lint-findings-add
                          (lint-redundant-begin-finding
                            (& source)
                            (& line-starts)
                            (& toks)
                            index
                            (array-ref close-of index))
                          findings)))
                    (set! depth (+ depth 1))
                    (set! (array-ref frame-open depth) index)
                    (set! (array-ref frame-head depth) head)
                    (set! (array-ref frame-count depth) 0)
                    (set! (array-ref frame-position depth) position)
                    (set! (array-ref frame-quoted depth) quoted)
                    (set! prefix 0))]
                [(lint-token-close-tag? tag)
                  (when (> depth 0) (set! depth (- depth 1)))]
                [else
                  (set!
                    (array-ref frame-count depth)
                    (+ (array-ref frame-count depth) 1))
                  (set! prefix 0)])
              (set! index (+ index 1))))
          findings))]))

(define (lint-name-qualified-by-separator?
  [name : (& name str)]
  [qualifier : (& qualifier str)]
  [separator : char]) : bool
  (let
    [name-len : i64 (string.string-length name)]
    [qualifier-len : i64 (string.string-length qualifier)]
    (cond
      [(<= qualifier-len 0) false]
      [(<= name-len qualifier-len) false]
      [(not (source_text.starts-with? name qualifier)) false]
      [else (= (string.string-ref name qualifier-len) separator)])))

(define (lint-name-qualified-by?
  [name : (& name str)]
  [qualifier : (& qualifier str)]) : bool
  (if (lint-name-qualified-by-separator? name qualifier '.')
    true
    (lint-name-qualified-by-separator? name qualifier '/')))

;; The import the unused-import rule looks for. A reference uses it when it
;; is qualified by the import's alias or by its full module name. A selected
;; item (`bare`) is bound unqualified, so a bare reference to its alias is a
;; use too; a module alias is never a value, so its bare spelling is not.
(defstruct LintImportRef
  (alias String)
  (module-name String)
  (bare bool))

(define (lint-name-uses-import?
  [name : String]
  [import-ref : (& import-ref LintImportRef)]) : bool
  (or
    (and import-ref.bare (string.eq name import-ref.alias))
    (lint-name-qualified-by? name import-ref.alias)
    (lint-name-qualified-by? name import-ref.module-name)))

(define (lint-name-id-uses-import?
  [name : i64]
  [import-ref : (& import-ref LintImportRef)]) : bool
  (lint-name-uses-import? (ci.intern-str name) import-ref))

(define (lint-expr-list-requires-enclosing-unsafe?
  [exprs : (& exprs ast.AstExprList)]) : bool
  (__tl-project-field
    (lint-unsafe-scan-expr-list
      exprs
      (LintUnsafeScope (lint-name-set-empty) false))
    requires))

;; Unsafe operations with expression children; ProgramArgv and ProgramEnvp
;; also need an enclosing unsafe block but have none.
(define (lint-expr-unsafe-operation? [expr : (& expr ast.AstExpr)]) : bool
  (match expr
    [(PtrAddrOf _) true]
    [(PtrRead _) true]
    [(PtrWrite _ _) true]
    [(PtrOffset _ _) true]
    [(PtrCast _ _) true]
    [(PtrToInt _) true]
    [(IntToPtr _ _) true]
    [(StringData _) true]
    [(StringFromBytes _ _) true]
    [(ArrayData _) true]
    [(Syscall _) true]
    [_ false]))

;; --- Referenced names ---
;; The names that declarations, types and expressions reference, in walk order
;; and with repeats: nominal type names, variant patterns, variables, `set!`
;; targets, and the cleanup functions, dispatch variants and extern argument
;; types of declarations. The unused-import rule asks whether any name in a
;; file is qualified by an import. The dead-code scan (lint_driver_core)
;; resolves them to declarations and, with `dead-code?`, also counts variant
;; definition names, struct field names and the for-owned step slots.
(defstruct LintNames
  (ids (__tl_dyn-array i64))
  (len i64)
  (dead-code? bool))

(define (lint-names-empty [dead-code? : bool]) : LintNames
  (LintNames (__tl_make-array i64 0) 0 dead-code?))

(define (lint-names-add [names : LintNames] [name : i64]) : LintNames
  (let
    [dead-code? : bool names.dead-code?]
    [n : i64 names.len]
    [ids : (__tl_dyn-array i64) names.ids]
    (if (< n (array-length ids))
      unit
      (let
        [bigger : (__tl_dyn-array i64)
          (__tl_make-array i64 (lint-grown-capacity (array-length ids)))]
        [index : i64 0]
        (while (< index n)
          (set! (array-ref bigger index) (array-ref ids index))
          (set! index (+ index 1)))
        (set! ids bigger)))
    (set! (array-ref ids n) name)
    (LintNames ids (+ n 1) dead-code?)))

(define (lint-names-use-import?
  [names : (& names LintNames)]
  [import-ref : (& import-ref LintImportRef)]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index names.len))
      (set!
        found
        (lint-name-id-uses-import? (array-ref names.ids index) import-ref))
      (set! index (+ index 1)))
    found))

(define (lint-maybe-type-names
  [maybe-ty : ast.AstMaybeType]
  [names : LintNames]) : LintNames
  (match maybe-ty
    [(No) names]
    [(Some ty) (lint-type-names ty names)]))

(define (lint-type-list-names [types : ast.AstTypeList] [names : LintNames]) : LintNames
  (lint-type-list-names-at (& types) names 0))

(define (lint-type-list-names-at
  [types : (& types ast.AstTypeList)]
  [names : LintNames]
  [index : i64]) : LintNames
  (if (>= index (ast.ast-type-list-len types))
    names
    (lint-type-list-names-at
      types
      (lint-type-id-names
        (ast.ast-type-list-get types index (ast.ast-type-id-fallback))
        names)
      (+ index 1))))

(define (lint-type-id-names [ty : i64] [names : LintNames]) : LintNames
  (lint-type-names (ast.ty-node-get ty) names))

(define (lint-type-names [ty : ast.AstType] [names : LintNames]) : LintNames
  (match ty
    [(I64) names]
    [(I32) names]
    [(I16) names]
    [(I8) names]
    [(U64) names]
    [(U32) names]
    [(U16) names]
    [(U8) names]
    [(F64) names]
    [(F32) names]
    [(Bool) names]
    [(Char) names]
    [(String) names]
    [(Str) names]
    [(Bytes) names]
    [(Unit) names]
    [(Never) names]
    [(Expr) names]
    [(ExprList) names]
    [(Func args ret)
      (lint-type-id-names ret (lint-type-list-names (deref args) names))]
    [(CFunc signature _) (lint-type-id-names signature names)]
    [(Tuple items) (lint-type-list-names (deref items) names)]
    [(Array elem _) (lint-type-id-names elem names)]
    [(DynArray elem) (lint-type-id-names elem names)]
    [(Slice elem) (lint-type-id-names elem names)]
    [(Box elem) (lint-type-id-names elem names)]
    [(Region _ inner) (lint-type-id-names inner names)]
    [(Invalidate _ inner) (lint-type-id-names inner names)]
    [(Ref _ inner) (lint-type-id-names inner names)]
    [(MutRef _ inner) (lint-type-id-names inner names)]
    [(Enum name) (lint-names-add names name)]
    [(EnumArgs name _) (lint-names-add names name)]
    [(Struct name) (lint-names-add names name)]
    [(StructArgs name _) (lint-names-add names name)]
    [(Var name) (lint-names-add names name)]
    [(VarArgs name _) (lint-names-add names name)]
    [(Ptr inner) (lint-type-id-names inner names)]
    [(MutPtr inner) (lint-type-id-names inner names)]))

(define (lint-param-list-names [params : ast.AstParamList] [names : LintNames]) : LintNames
  (lint-param-list-names-at (& params) names 0))

(define (lint-param-list-names-at
  [params : (& params ast.AstParamList)]
  [names : LintNames]
  [index : i64]) : LintNames
  (if (>= index (ast.ast-param-list-len params))
    names
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(Param _ ty _)
        (lint-param-list-names-at params (lint-type-names ty names) (+ index 1))])))

(define (lint-macro-param-list-names
  [params : ast.AstMacroParamList]
  [names : LintNames]) : LintNames
  (lint-macro-param-list-names-at (& params) names 0))

(define (lint-macro-param-list-names-at
  [params : (& params ast.AstMacroParamList)]
  [names : LintNames]
  [index : i64]) : LintNames
  (if (>= index (ast.ast-macro-param-list-len params))
    names
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(Param _ ty _ _)
        (lint-macro-param-list-names-at
          params
          (lint-type-names ty names)
          (+ index 1))])))

(define (lint-pattern-list-names
  [patterns : ast.AstPatternList]
  [names : LintNames]) : LintNames
  (lint-pattern-list-names-at (& patterns) names 0))

(define (lint-pattern-list-names-at
  [patterns : (& patterns ast.AstPatternList)]
  [names : LintNames]
  [index : i64]) : LintNames
  (if (>= index patterns.len)
    names
    (lint-pattern-list-names-at
      patterns
      (lint-pattern-names
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
        names)
      (+ index 1))))

(define (lint-pattern-names [pattern : ast.AstPattern] [names : LintNames]) : LintNames
  (match pattern
    [(Var _ maybe-ty) (lint-maybe-type-names maybe-ty names)]
    [(Tuple items) (lint-pattern-list-names (deref items) names)]
    [(Array items) (lint-pattern-list-names (deref items) names)]
    [(Slice items _) (lint-pattern-list-names (deref items) names)]
    [(Wildcard) names]
    [(Binding _) names]
    [(Variant name items)
      (lint-pattern-list-names (deref items) (lint-names-add names name))]
    [(Literal _) names]))

(define (lint-expr-list-names [exprs : ast.AstExprList] [names : LintNames]) : LintNames
  (lint-expr-list-names-from (& exprs) names 0))

(define (lint-expr-list-names-from
  [exprs : (& exprs ast.AstExprList)]
  [names : LintNames]
  [index : i64]) : LintNames
  (if (>= index exprs.len)
    names
    (lint-expr-list-names-from
      exprs
      (lint-expr-names (ast.ast-expr-list-get exprs index 0) names)
      (+ index 1))))

(define (lint-expr-child-list-names-from
  [children : (& children ast.AstExprChildList)]
  [names : LintNames]
  [index : i64]) : LintNames
  (if (>= index children.len)
    names
    (lint-expr-child-list-names-from
      children
      (match (ast.ast-expr-child-list-get
        children
        index
        (ast.ast-expr-child-fallback))
        [(Expr id) (lint-expr-names id names)]
        [(TypeId id) (lint-type-id-names id names)]
        [(Type ty) (lint-type-names ty names)]
        [(Pattern pattern) (lint-pattern-names pattern names)])
      (+ index 1))))

(define (lint-expr-children-names [expr : ast.AstExpr] [names : LintNames]) : LintNames
  (let
    [children : ast.AstExprChildList (ast.ast-expr-children expr)]
    (lint-expr-child-list-names-from (& children) names 0)))

(define (lint-expr-names [expr-id : i64] [names : LintNames]) : LintNames
  ;; The arms below collect names, fields and the for-owned slots; every other
  ;; variant's children are collected through the AstExpr child list.
  (match (ast.ast-node-get expr-id)
    [(Var name) (lint-names-add names name)]
    [(ForOwnedState payload)
      (lint-expr-names
        (ast.ast-for-owned-state-body (& payload))
        (lint-expr-names (ast.ast-for-owned-state-source (& payload)) names))]
    [(ForOwnedStep payload)
      (let
        [dead-code? : bool names.dead-code?]
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        [before : LintNames
          (if dead-code?
            (lint-expr-names
              (ast.ast-for-owned-step-index-name (& payload))
              (lint-expr-names
                (ast.ast-for-owned-step-source-name (& payload))
                names))
            names)]
        [typed : LintNames
          (if (>= expected-type 0)
            (lint-expr-names expected-type before)
            before)]
        (lint-expr-names
          (ast.ast-for-owned-step-body (& payload))
          (if dead-code?
            (lint-expr-names
              (ast.ast-for-owned-step-done-name (& payload))
              typed)
            typed)))]
    [(Set target value) (lint-expr-names value (lint-names-add names target))]
    [(StructGet _ field)
      (let
        [dead-code? : bool names.dead-code?]
        [with-children : LintNames
          (lint-expr-children-names (ast.ast-node-get expr-id) names)]
        (if dead-code?
          (lint-names-add with-children field)
          with-children))]
    [(StructSet receiver field value)
      (let
        [dead-code? : bool names.dead-code?]
        [with-receiver : LintNames (lint-expr-names receiver names)]
        (lint-expr-names
          value
          (if dead-code?
            (lint-names-add with-receiver field)
            with-receiver)))]
    [_ (lint-expr-children-names (ast.ast-node-get expr-id) names)]))

(define (lint-extern-abi-names [abi : ast.AstExternAbi] [names : LintNames]) : LintNames
  (match abi
    [(C) names]
    [(CVarargsOpen) names]
    [(CVarargsTyped tail-ty) (lint-type-names tail-ty names)]
    [(TypeLisp) names]))

(define (lint-extern-metadata-names
  [meta : ast.AstExternMetadata]
  [names : LintNames]) : LintNames
  (match meta
    [(Metadata abi _ _ _ _) (lint-extern-abi-names abi names)]))

(define (lint-cleanup-name [name : ci.InternSyntaxId] [names : LintNames]) : LintNames
  (lint-names-add names (ci.intern-syntax-id-value name)))

(define (lint-field-cleanup-names
  [cleanup : ast.AstFieldCleanup]
  [names : LintNames]) : LintNames
  (match cleanup
    [(No) names]
    [(Fn name) (lint-cleanup-name name names)]
    [(Owned) names]))

(define (lint-field-def-list-names
  [fields : ast.AstFieldDefList]
  [names : LintNames]) : LintNames
  (lint-field-def-list-names-at (& fields) names 0))

(define (lint-field-def-list-names-at
  [fields : (& fields ast.AstFieldDefList)]
  [names : LintNames]
  [index : i64]) : LintNames
  (if (>= index fields.len)
    names
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(Def _ ty cleanup)
        (lint-field-def-list-names-at
          fields
          (lint-field-cleanup-names cleanup (lint-type-names ty names))
          (+ index 1))])))

(define (lint-struct-cleanup-names
  [cleanup : ast.AstStructCleanup]
  [names : LintNames]) : LintNames
  (match cleanup
    [(No) names]
    [(Fn name) (lint-cleanup-name name names)]))

(define (lint-enum-cleanup-names
  [cleanup : ast.AstEnumCleanup]
  [names : LintNames]) : LintNames
  (match cleanup
    [(No) names]
    [(Fn name) (lint-cleanup-name name names)]))

(define (lint-variant-payload-cleanup-list-names-at
  [items : (& items ast.AstVariantPayloadCleanupList)]
  [names : LintNames]
  [index : i64]) : LintNames
  (if (>= index items.len)
    names
    (lint-variant-payload-cleanup-list-names-at
      items
      (match (ast.ast-variant-payload-cleanup-list-get
        items
        index
        (ast.ast-variant-payload-cleanup-fallback))
        [(No) names]
        [(Fn name) (lint-cleanup-name name names)]
        [(Owned) names])
      (+ index 1))))

(define (lint-variant-def-list-names
  [variants : ast.AstVariantDefList]
  [names : LintNames]) : LintNames
  (lint-variant-def-list-names-at (& variants) names 0))

(define (lint-variant-def-list-names-at
  [variants : (& variants ast.AstVariantDefList)]
  [names : LintNames]
  [index : i64]) : LintNames
  (if (>= index variants.len)
    names
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(Def name payloads cleanups)
        (let
          [named : LintNames
            (if names.dead-code?
              (lint-names-add names name)
              names)]
          (lint-variant-def-list-names-at
            variants
            (lint-variant-payload-cleanup-list-names-at
              (& cleanups)
              (lint-type-list-names payloads named)
              0)
            (+ index 1)))])))

(define (lint-dispatch-variant-list-names-from
  [variants : (& variants ast.AstDispatchVariantList)]
  [names : LintNames]
  [index : i64]) : LintNames
  (if (>= index variants.len)
    names
    (match (ast.ast-dispatch-variant-list-get
      variants
      index
      (ast.ast-dispatch-variant-fallback))
      [(Variant _ name)
        (lint-dispatch-variant-list-names-from
          variants
          (lint-names-add names name)
          (+ index 1))])))

(define (lint-generated-meta-names
  [meta : ast.AstGeneratedDeclMeta]
  [names : LintNames]) : LintNames
  (match meta
    [(No) names]
    [(Some _ _ args _) (lint-expr-list-names args names)]))

;; The names a declaration's own parts reference, without its generated-decl
;; metadata; a module body or `unsafe` declaration contributes its members'.
(define (lint-decl-names [decl : ast.AstDecl] [names : LintNames]) : LintNames
  (match decl
    [(Module _) names]
    [(ModuleBody _ body)
      (lint-decl-list-names (ast.ast-decl-list-box-shared-view body) names)]
    [(Def _ _ maybe-ty body)
      (lint-expr-names body (lint-maybe-type-names maybe-ty names))]
    [(DefFn _ _ params ret body _)
      (lint-expr-names
        body
        (lint-type-names ret (lint-param-list-names params names)))]
    [(DefMacro _ _ params ret body)
      (lint-expr-names
        body
        (lint-type-names ret (lint-macro-param-list-names params names)))]
    [(Extern _ _ _ meta ty)
      (lint-type-names
        ty
        (lint-extern-metadata-names
          (ast.ast-extern-metadata-box-shared-view meta)
          names))]
    [(DefEnum _ _ cleanup variants)
      (lint-variant-def-list-names
        variants
        (lint-enum-cleanup-names cleanup names))]
    [(DefEnumLifetimes _ _ _ cleanup variants)
      (lint-variant-def-list-names
        variants
        (lint-enum-cleanup-names cleanup names))]
    [(DefStruct _ _ _ cleanup fields)
      (lint-field-def-list-names
        fields
        (lint-struct-cleanup-names cleanup names))]
    [(DefStructLifetimes _ _ _ _ cleanup fields)
      (lint-field-def-list-names
        fields
        (lint-struct-cleanup-names cleanup names))]
    [(Import _ (Spec (Macro call-expr _) _ _ _ _))
      (lint-expr-names call-expr names)]
    [(Import _ (Spec (MacroDecls call-expr _) _ _ _ _))
      (lint-expr-names call-expr names)]
    [(Import _ _) names]
    [(IncludeStr _ _) names]
    [(IncludeStrComptime _ _) names]
    [(IncludeStrLzss _ _) names]
    [(IncludeBin _ _) names]
    [(DefDispatch _ _ variants)
      (lint-dispatch-variant-list-names-from (& variants) names 0)]
    [(Test _ body _ _) (lint-expr-names body names)]
    [(Unsafe inner)
      (lint-decl-names-with-meta (ast.ast-decl-box-shared-view inner) names)]))

(define (lint-decl-names-with-meta [decl : ast.AstDecl] [names : LintNames]) : LintNames
  (let
    [with-meta : LintNames
      (lint-generated-meta-names (ast.ast-decl-generated-meta decl) names)]
    (lint-decl-names decl with-meta)))

(define (lint-decl-list-names [decls : ast.AstDeclList] [names : LintNames]) : LintNames
  (match (ast.ast-decl-list-step decls)
    [(Nil) names]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (lint-decl-list-names rest (lint-decl-names-with-meta decl names)))]))

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
  (set! lint-unused-unsafe-exact-names (lint-unused-unsafe-exact-names-empty))
  (set!
    lint-unused-unsafe-unknown-roots
    (lint-unused-unsafe-unknown-roots-empty))
  (set! lint-unused-unsafe-classified-required-count 0)
  (set! lint-unused-unsafe-classified-unused-count 0)
  (set! lint-unused-unsafe-classified-unknown-count 0)
  (set! lint-unused-unsafe-block-stack (lint-unused-unsafe-block-stack-empty))
  (set! lint-unused-unsafe-classifier-enabled false))

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
        (while (< index n)
          (set!
            (array-ref bigger index)
            (array-ref
              (__tl-project-field lint-unused-unsafe-exact-names slots)
              index))
          (set! index (+ index 1)))
        (set!
          (array-ref bigger n)
          (LintUnusedUnsafeExactName name requires-unsafe))
        (set!
          lint-unused-unsafe-exact-names
          (LintUnusedUnsafeExactNames bigger (+ n 1)))))))

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
        (while (< index n)
          (set!
            (array-ref bigger index)
            (array-ref
              (__tl-project-field lint-unused-unsafe-unknown-roots slots)
              index))
          (set! index (+ index 1)))
        (set! (array-ref bigger n) name)
        (set!
          lint-unused-unsafe-unknown-roots
          (LintUnusedUnsafeUnknownRoots bigger (+ n 1)))))))

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
          (while (< index n)
            (set!
              (array-ref bigger index)
              (array-ref
                (__tl-project-field lint-unused-unsafe-block-stack slots)
                index))
            (set! index (+ index 1)))
          (set!
            (array-ref bigger n)
            (LintUnusedUnsafeBlock span required false))
          (set!
            lint-unused-unsafe-block-stack
            (LintUnusedUnsafeBlockStack bigger (+ n 1))))))
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

;; A wildcard import binds every item of its module unqualified, and the
;; importing file alone does not say which of its bare names those are, so
;; the unused-import rule cannot attribute a use to it.
(define (lint-import-kind-lintable?
  [kind : ast.AstImportKind]
  [_ : ast.AstMaybeModuleName]) : bool
  (match kind
    [(Module) true]
    [(ModuleAll) false]
    [(ModuleItem _) true]
    [(Macro _ _) false]
    [(MacroDecls _ _) false]))

(define (lint-stdlib-string-module-name? [module-name : String]) : bool
  (or
    (string.eq module-name "stdlib.string")
    (string.eq module-name "stdlib/string")
    (string.eq module-name "stdlib/string.tl")
    (string.eq module-name "string")
    (string.eq module-name "string.tl")
    (source_text.ends-with? module-name "/stdlib/string.tl")
    (source_text.ends-with? module-name "\\stdlib\\string.tl")
    (source_text.ends-with? module-name "\\stdlib/string.tl")
    (source_text.ends-with? module-name "/stdlib\\string.tl")))

;; `subject` names what was imported: `module alias a`, `item x`, or
;; `item x as a` when a selected item is renamed.
(define (lint-unused-import-finding
  [module-name : String]
  [subject : String]
  [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (str_cat.str-cat
      "unused import: "
      subject
      " from "
      module-name
      " is never referenced")
    (lint-rule-unused-import-id)
    0
    span
    (lint-fix-unproven)))

(define (lint-redundant-import-alias-finding [span : ast.AstSourceSpan]) : LintFinding
  (LintFinding
    (lint-rule-redundant-import-alias-message)
    (lint-rule-redundant-import-alias-id)
    0
    span
    (lint-fix-unproven)))

(define (lint-module-default-alias [module-name : String]) : String
  (let
    [n : i64 (string.string-length module-name)]
    [i : i64 0]
    [start : i64 0]
    (while (< i n)
      (if (or
        (= (string.string-ref module-name i) '.')
        (= (string.string-ref module-name i) '/'))
        (set! start (+ i 1))
        unit)
      (set! i (+ i 1)))
    (string.substring module-name start (- n start))))

(define (lint-source-span-end-index
  [source : (& source str)]
  [span : ast.AstSourceSpan]) : i64
  (let
    [idx : i64
      (lint-source-span-start-index
        source
        (ast.ast-source-span
          (ast.ast-source-span-end-line span)
          (ast.ast-source-span-end-col span)
          (ast.ast-source-span-end-line span)
          (ast.ast-source-span-end-col span)))]
    (if (< idx 0)
      (string.string-length source)
      idx)))

(define (lint-source-name-in-range?
  [source : (& source str)]
  [name : String]
  [start : i64]
  [limit : i64]) : bool
  (let
    [found : i64 (lint-source-find-name-from source name start)]
    (and (>= found 0) (< found limit))))

(define (lint-import-span-has-explicit-alias?
  [source : (& source str)]
  [span : ast.AstSourceSpan]) : bool
  (let
    [start : i64 (lint-source-span-start-index source span)]
    [limit : i64 (lint-source-span-end-index source span)]
    (if (< start 0)
      false
      (or
        (lint-source-name-in-range? source "as" start limit)
        (lint-source-name-in-range? source ":as" start limit)))))

(define (lint-redundant-import-alias-add-if-needed
  [source : (& source str)]
  [spec : ast.AstImportSpec]
  [acc : LintFindings]) : LintFindings
  (match spec
    [(Spec kind _ expected maybe-alias span)
      (match kind
        [(Module)
          (match expected
            [(No) acc]
            [(Some module-name)
              (let
                [module-name : String (ci.intern-str module-name)]
                (match maybe-alias
                  [(No) acc]
                  [(Some alias)
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
        [(ModuleItem item)
          (match maybe-alias
            [(No) acc]
            [(Some alias)
              (if (and
                (string.eq (ci.intern-str alias) (ci.intern-str item))
                (lint-import-span-has-explicit-alias?
                  source
                  (__tl-box-place span)))
                (lint-findings-add
                  (lint-redundant-import-alias-finding (__tl-box-place span))
                  acc)
                acc)])]
        [_ acc])]))

(define (lint-unused-import-add-if-needed
  [source : (& source str)]
  [all-decls : ast.AstDeclList]
  [names : (& names LintNames)]
  [current-module-id : i64]
  [spec : ast.AstImportSpec]
  [acc : LintFindings]) : LintFindings
  (let
    [acc : LintFindings
      (lint-redundant-import-alias-add-if-needed
        source
        (owned_view.compiler-owned-shared-view spec)
        acc)]
    (match spec
      [(Spec kind _ expected maybe-alias span)
        (if (not (lint-import-kind-lintable? kind expected))
          acc
          (match expected
            [(No) acc]
            [(Some module-name)
              (match maybe-alias
                [(No) acc]
                [(Some alias)
                  (let
                    [item? : bool
                      (match kind
                        [(ModuleItem _) true]
                        [_ false])]
                    (if (lint-underscore-prefixed? (ci.intern-str alias))
                      acc
                      (let
                        [import-ref : LintImportRef
                          (LintImportRef
                            (ci.intern-str alias)
                            (ci.intern-str module-name)
                            item?)]
                        (if (or
                          (lint-names-use-import? names (& import-ref))
                          ;; The catalogued bare stdlib.string helpers come
                          ;; with the module import, not with a selected item.
                          (and
                            (not item?)
                            (lint-stdlib-string-module-name?
                              (ci.intern-str module-name))
                            (lint-decl-list-has-stdlib-string-bare-use?
                              all-decls
                              current-module-id)))
                          acc
                          (lint-findings-add
                            (lint-unused-import-finding
                              (ci.intern-str module-name)
                              (match kind
                                [(ModuleItem item)
                                  (if (string.eq
                                    (ci.intern-str item)
                                    (ci.intern-str alias))
                                    (str_cat.str-cat
                                      "item "
                                      (ci.intern-str alias))
                                    (str_cat.str-cat
                                      "item "
                                      (ci.intern-str item)
                                      " as "
                                      (ci.intern-str alias)))]
                                [_
                                  (str_cat.str-cat
                                    "module alias "
                                    (ci.intern-str alias))])
                              (__tl-box-place span))
                            acc)))))])]))])))

;; Every import is checked against the names of the whole file, collected once.
(define (lint-unused-imports-in-decl-list
  [source : (& source str)]
  [all-decls : ast.AstDeclList]
  [decls : ast.AstDeclList]
  [acc : LintFindings]) : LintFindings
  (let
    [names : LintNames
      (lint-decl-list-names
        (owned_view.compiler-owned-shared-view all-decls)
        (lint-names-empty false))]
    (lint-unused-imports-in-decl-list-at
      source
      all-decls
      (& names)
      decls
      cbi.compiler-builtin-id-fix-empty
      acc)))

(define (lint-unused-imports-in-decl-list-at
  [source : (& source str)]
  [all-decls : ast.AstDeclList]
  [names : (& names LintNames)]
  [decls : ast.AstDeclList]
  [current-module-id : i64]
  [acc : LintFindings]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(Nil) acc]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (lint-unused-imports-in-decl-list-at
          source
          (owned_view.compiler-owned-shared-view all-decls)
          names
          rest
          (match (owned_view.compiler-owned-shared-view decl)
            [(Module module-id) module-id]
            [_ current-module-id])
          (match decl
            [(Import decl-meta spec)
              (lint-unused-import-add-if-needed
                source
                all-decls
                names
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
  [items : (& items LintNameSet)]
  [name : String]
  [index : i64]) : bool
  (if (>= index items.len)
    false
    (if (string.eq (array-ref items.slots index) name)
      true
      (lint-name-set-contains-from? items name (+ index 1)))))

(define (lint-name-set-contains?
  [items : (& items LintNameSet)]
  [name : String]) : bool
  (lint-name-set-contains-from? items name 0))

(define (lint-name-set-add [items : LintNameSet] [name : String]) : LintNameSet
  (if (lint-name-set-contains?
    items
    (owned_view.compiler-owned-shared-view name))
    items
    (let
      [n : i64 items.len]
      [slots : (__tl_dyn-array String) items.slots]
      (if (< n (array-length slots))
        unit
        (let
          [bigger : (__tl_dyn-array String)
            (__tl_make-array String (lint-grown-capacity (array-length slots)))]
          [index : i64 0]
          (while (< index n)
            (set! (array-ref bigger index) (array-ref slots index))
            (set! index (+ index 1)))
          (set! slots bigger)))
      (set! (array-ref slots n) name)
      (LintNameSet slots (+ n 1)))))

(define (lint-name-set-count [items : (& items LintNameSet)]) : i64
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
      [(Param name _ _)
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
      [(Param name _ _ _)
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
    [(Var name _) (lint-unsafe-scope-add-id scope name)]
    [(Tuple items)
      (lint-unsafe-pattern-list-add-bindings (deref items) scope 0)]
    [(Array items)
      (lint-unsafe-pattern-list-add-bindings (deref items) scope 0)]
    [(Slice items _)
      (lint-unsafe-pattern-list-add-bindings (deref items) scope 0)]
    [(Wildcard) scope]
    [(Binding name) (lint-unsafe-scope-add-id scope name)]
    [(Variant _ items)
      (lint-unsafe-pattern-list-add-bindings (deref items) scope 0)]
    [(Literal _) scope]))

(define (lint-unsafe-pattern-list-add-bindings
  [patterns : (& patterns ast.AstPatternList)]
  [scope : LintUnsafeScope]
  [index : i64]) : LintUnsafeScope
  (if (>= index patterns.len)
    scope
    (lint-unsafe-pattern-list-add-bindings
      patterns
      (lint-unsafe-pattern-add-bindings
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
        scope)
      (+ index 1))))

(define (lint-unsafe-scope-name-unshadowed?
  [name-id : i64]
  [scope : (& scope LintUnsafeScope)]) : bool
  (and
    (not scope.ambiguous)
    (not (lint-name-set-contains? scope.shadowed (ci.intern-str name-id)))))

(define (lint-unsafe-call-unshadowed? [name-id : i64] [scope : LintUnsafeScope]) : bool
  (and
    (lint-unsafe-scope-name-unshadowed? name-id scope)
    (cbi.compiler-builtin-typecheck-syntactic-unsafe-call-id? name-id)))

(define (lint-stdlib-string-bare-call-unshadowed?
  [name-id : i64]
  [scope : (& scope LintUnsafeScope)]) : bool
  (and
    (lint-unsafe-scope-name-unshadowed? name-id scope)
    (cbi.compiler-builtin-typecheck-stdlib-string-bare-helper-id? name-id)))

(define (lint-unsafe-scan-two-nodes
  [left : i64]
  [right : i64]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (lint-unsafe-scan-combine
    (lint-unsafe-scan-node left scope)
    (lint-unsafe-scan-node right scope)))

(define (lint-unsafe-scan-three-nodes
  [first : i64]
  [second : i64]
  [third : i64]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (lint-unsafe-scan-combine
    (lint-unsafe-scan-node first scope)
    (lint-unsafe-scan-two-nodes second third scope)))

(define (lint-unsafe-scan-expr-list
  [exprs : (& exprs ast.AstExprList)]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (lint-unsafe-scan-expr-list-at (& exprs) scope 0))

(define (lint-unsafe-scan-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [scope : LintUnsafeScope]
  [index : i64]) : LintUnsafeScan
  (if (>= index exprs.len)
    (lint-unsafe-scan-empty)
    (lint-unsafe-scan-combine
      (lint-unsafe-scan-node (ast.ast-expr-list-get exprs index 0) scope)
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
      [(Binding name _ init)
        (lint-unsafe-scan-combine
          (lint-unsafe-scan-node init scope)
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
      [(Arm pattern body)
        (lint-unsafe-scan-combine
          (let
            [scope-arg
              (lint-unsafe-pattern-add-bindings
                pattern
                (owned_view.compiler-owned-shared-view scope))]
            (lint-unsafe-scan-node body scope-arg))
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
      [(Binding name init cleanup _)
        (let
          ;; Finish the ancestor scan before retaining a child snapshot. Dense
          ;; name sets may reuse an ancestor's spare slot for a nested scope.
          [init-scan : LintUnsafeScan (lint-unsafe-scan-node init scope)]
          [bound : LintUnsafeScope (lint-unsafe-scope-add-id scope name)]
          [cleanup-scan : LintUnsafeScan (lint-unsafe-scan-node cleanup bound)]
          [rest-scan : LintUnsafeScan
            (lint-unsafe-scan-resource-bindings bindings body bound (+ index 1))]
          (lint-unsafe-scan-combine
            init-scan
            (lint-unsafe-scan-combine cleanup-scan rest-scan)))])))

(define (lint-unsafe-scan-children
  [expr : ast.AstExpr]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (let
    [ids : ast.AstExprList (ast.ast-expr-child-ids expr)]
    (lint-unsafe-scan-expr-list (& ids) scope)))

(define (lint-unsafe-scan-node
  [node-id : i64]
  [scope : (& scope LintUnsafeScope)]) : LintUnsafeScan
  ;; The arms below bind names, mark unsafe calls and blocks, or scan the
  ;; for-owned forms; every other variant's children are scanned through the
  ;; AstExpr child list.
  (let
    [scope : LintUnsafeScope
      (owned_view.compiler-owned-reference-shared-view scope)]
    (match (ast.ast-node-get node-id)
      [(Call func _)
        (let
          [children : LintUnsafeScan
            (lint-unsafe-scan-children
              (ast.ast-node-get node-id)
              (owned_view.compiler-owned-shared-view scope))]
          (match (ast.ast-expr-unspan (ast.ast-node-get func))
            [(Var name)
              (let
                [with-string-use : LintUnsafeScan
                  (if (lint-stdlib-string-bare-call-unshadowed? name scope)
                    (lint-unsafe-scan-note-stdlib-string-bare-use children)
                    children)]
                (if (lint-unsafe-call-unshadowed? name scope)
                  (lint-unsafe-scan-require with-string-use)
                  with-string-use))]
            [_ children]))]
      [(Let let-box)
        (match (__tl-box-place let-box)
          [(Let bindings body)
            (lint-unsafe-scan-let-bindings bindings body scope 0)])]
      [(Lambda lambda-box)
        (match (__tl-box-place lambda-box)
          [(Lambda params _ body)
            (let
              [scope-arg (lint-unsafe-scope-add-params scope params)]
              (lint-unsafe-scan-node body scope-arg))])]
      [(ForOwnedState payload)
        (lint-unsafe-scan-two-nodes
          (ast.ast-for-owned-state-source (& payload))
          (ast.ast-for-owned-state-body (& payload))
          scope)]
      [(ForOwnedStep payload)
        (let
          [expected-type : i64
            (ast.ast-for-owned-step-expected-type (& payload))]
          [body : i64 (ast.ast-for-owned-step-body (& payload))]
          (if (>= expected-type 0)
            (lint-unsafe-scan-two-nodes expected-type body scope)
            (lint-unsafe-scan-node body scope)))]
      [(Unsafe items)
        (let
          [inside : LintUnsafeScan (lint-unsafe-scan-expr-list items scope)]
          (LintUnsafeScan
            false
            (or (not inside.requires) inside.candidate)
            inside.stdlib-string-bare-use))]
      [(Match match-box)
        (match (__tl-box-place match-box)
          [(Match scrutinee arms)
            (lint-unsafe-scan-combine
              (lint-unsafe-scan-node scrutinee scope)
              (lint-unsafe-scan-match-arms arms scope 0))])]
      [(Foreach foreach-box)
        (match (__tl-box-place foreach-box)
          [(Foreach index _ start end body)
            (lint-unsafe-scan-combine
              (lint-unsafe-scan-two-nodes
                start
                end
                (owned_view.compiler-owned-shared-view scope))
              (let
                [scope-arg (lint-unsafe-scope-add-id scope index)]
                (lint-unsafe-scan-node body scope-arg)))]
          [(Foreach2 outer _ a b inner _ c d body)
            (let
              [bounds : LintUnsafeScan
                (lint-unsafe-scan-combine
                  (lint-unsafe-scan-two-nodes
                    a
                    b
                    (owned_view.compiler-owned-shared-view scope))
                  (lint-unsafe-scan-two-nodes
                    c
                    d
                    (owned_view.compiler-owned-shared-view scope)))]
              [body-scope : LintUnsafeScope
                (lint-unsafe-scope-add-id
                  (lint-unsafe-scope-add-id scope outer)
                  inner)]
              (lint-unsafe-scan-combine
                bounds
                (lint-unsafe-scan-node body body-scope)))])]
      [(SpmdReduce reduce-box)
        (match (__tl-box-place reduce-box)
          [(Reduce _ index _ start end init value)
            (lint-unsafe-scan-combine
              (lint-unsafe-scan-three-nodes
                start
                end
                init
                (owned_view.compiler-owned-shared-view scope))
              (let
                [scope-arg (lint-unsafe-scope-add-id scope index)]
                (lint-unsafe-scan-node value scope-arg)))])]
      [(SpmdScan scan-box)
        (match (__tl-box-place scan-box)
          [(Scan _ index _ start end prefix _ init value body)
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
                (lint-unsafe-scan-node value index-scope)]
              [body-scope : LintUnsafeScope
                (lint-unsafe-scope-add-id index-scope prefix)]
              (lint-unsafe-scan-combine
                outer
                (lint-unsafe-scan-combine
                  value-scan
                  (lint-unsafe-scan-node body body-scope))))])]
      [(SpmdCompact compact-box)
        (match (__tl-box-place compact-box)
          [(Compact index _ start end slot _ init keep body)
            (let
              [outer : LintUnsafeScan
                (lint-unsafe-scan-three-nodes
                  start
                  end
                  init
                  (owned_view.compiler-owned-shared-view scope))]
              [index-scope : LintUnsafeScope
                (lint-unsafe-scope-add-id scope index)]
              [keep-scan : LintUnsafeScan
                (lint-unsafe-scan-node keep index-scope)]
              [body-scope : LintUnsafeScope
                (lint-unsafe-scope-add-id index-scope slot)]
              (lint-unsafe-scan-combine
                outer
                (lint-unsafe-scan-combine
                  keep-scan
                  (lint-unsafe-scan-node body body-scope))))])]
      [(WithResource resource-box)
        (match (__tl-box-place resource-box)
          [(WithResource bindings body)
            (lint-unsafe-scan-resource-bindings bindings body scope 0)])]
      [(ForeachActive lane body)
        (let
          [scope-arg (lint-unsafe-scope-add-id scope lane)]
          (lint-unsafe-scan-node body scope-arg))]
      [(ProgramArgv) (lint-unsafe-scan-require (lint-unsafe-scan-empty))]
      [(ProgramEnvp) (lint-unsafe-scan-require (lint-unsafe-scan-empty))]
      [_
        (let
          [expr : ast.AstExpr (ast.ast-node-get node-id)]
          [unsafe-operation : bool (lint-expr-unsafe-operation? (& expr))]
          [children : LintUnsafeScan (lint-unsafe-scan-children expr scope)]
          (if unsafe-operation
            (lint-unsafe-scan-require children)
            children))])))

(define (lint-unsafe-decl-add-global [decl : ast.AstDecl] [names : LintNameSet]) : LintNameSet
  (match decl
    [(Module name) (lint-name-set-add names (ci.intern-str name))]
    [(ModuleBody name _) (lint-name-set-add names (ci.intern-str name))]
    [(Def _ name _ _) (lint-name-set-add names (ci.intern-str name))]
    [(DefFn _ name _ _ _ _) (lint-name-set-add names (ci.intern-str name))]
    [(DefMacro _ name _ _ _) (lint-name-set-add names (ci.intern-str name))]
    [(Extern _ name _ _ _) (lint-name-set-add names (ci.intern-str name))]
    [(DefEnum _ name _ _) (lint-name-set-add names (ci.intern-str name))]
    [(DefEnumLifetimes _ name _ _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(DefStruct _ name _ _ _) (lint-name-set-add names (ci.intern-str name))]
    [(DefStructLifetimes _ name _ _ _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(Import _ _) names]
    [(IncludeStr name _) (lint-name-set-add names (ci.intern-str name))]
    [(IncludeStrComptime name _) (lint-name-set-add names (ci.intern-str name))]
    [(IncludeStrLzss name _) (lint-name-set-add names (ci.intern-str name))]
    [(IncludeBin name _) (lint-name-set-add names (ci.intern-str name))]
    [(DefDispatch _ name _) (lint-name-set-add names (ci.intern-str name))]
    [(Test name _ _ _) (lint-name-set-add names (ci.intern-str name))]
    [(Unsafe inner) (lint-unsafe-decl-add-global (deref inner) names)]))

(define (lint-unsafe-decl-list-globals
  [decls : ast.AstDeclList]
  [names : LintNameSet]) : LintNameSet
  (match (ast.ast-decl-list-step decls)
    [(Nil) names]
    [(Cons decl rest)
      (lint-unsafe-decl-list-globals
        rest
        (lint-unsafe-decl-add-global decl names))]))

(define (lint-unsafe-import-ambiguous? [_ : ast.AstImportSpec]) : bool
  false)

(define (lint-unsafe-decl-list-ambiguous? [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Nil) false]
    [(Cons decl rest)
      (if (match decl
        [(Import _ spec) (lint-unsafe-import-ambiguous? spec)]
        [(Unsafe inner)
          (match (__tl-box-place inner)
            [(Import _ spec) (lint-unsafe-import-ambiguous? spec)]
            [_ false])]
        [_ false])
        true
        (lint-unsafe-decl-list-ambiguous? rest))]))

(define (lint-unsafe-decl-generated? [decl : ast.AstDecl]) : bool
  (match (ast.ast-decl-generated-meta decl)
    [(No) false]
    [(Some _ _ _ _) true]))

(define (lint-unsafe-scan-decl [decl : ast.AstDecl] [scope : LintUnsafeScope]) : LintUnsafeScan
  (let
    [body-scope : LintUnsafeScope
      (if (lint-unsafe-decl-generated?
        (owned_view.compiler-owned-shared-view decl))
        (lint-unsafe-scope-with-ambiguous
          (owned_view.compiler-owned-shared-view scope))
        (owned_view.compiler-owned-shared-view scope))]
    (match decl
      [(Module _) (lint-unsafe-scan-empty)]
      [(ModuleBody _ body) (lint-unsafe-scan-decl-list (deref body))]
      [(Def _ _ _ body) (lint-unsafe-scan-node body body-scope)]
      [(DefFn _ _ params _ body _)
        (let
          [scope (lint-unsafe-scope-add-params body-scope params)]
          (lint-unsafe-scan-node body scope))]
      [(DefMacro _ _ params _ body)
        (let
          [scope (lint-unsafe-scope-add-macro-params body-scope params)]
          (lint-unsafe-scan-node body scope))]
      [(Extern _ _ _ _ _) (lint-unsafe-scan-empty)]
      [(DefEnum _ _ _ _) (lint-unsafe-scan-empty)]
      [(DefEnumLifetimes _ _ _ _ _) (lint-unsafe-scan-empty)]
      [(DefStruct _ _ _ _ _) (lint-unsafe-scan-empty)]
      [(DefStructLifetimes _ _ _ _ _ _) (lint-unsafe-scan-empty)]
      [(Import _ (Spec (Macro call _) _ _ _ _))
        (lint-unsafe-scan-node call body-scope)]
      [(Import _ (Spec (MacroDecls call _) _ _ _ _))
        (lint-unsafe-scan-node call body-scope)]
      [(Import _ _) (lint-unsafe-scan-empty)]
      [(IncludeStr _ _) (lint-unsafe-scan-empty)]
      [(IncludeStrComptime _ _) (lint-unsafe-scan-empty)]
      [(IncludeStrLzss _ _) (lint-unsafe-scan-empty)]
      [(IncludeBin _ _) (lint-unsafe-scan-empty)]
      [(DefDispatch _ _ _) (lint-unsafe-scan-empty)]
      [(Test _ body _ _) (lint-unsafe-scan-node body body-scope)]
      [(Unsafe inner) (lint-unsafe-scan-decl (deref inner) scope)])))

(define (lint-unsafe-scan-decls-with-scope
  [decls : ast.AstDeclList]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (match (ast.ast-decl-list-step decls)
    [(Nil) (lint-unsafe-scan-empty)]
    [(Cons decl rest)
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
    [(Program decls)
      (__tl-project-field (lint-unsafe-scan-decl-list (deref decls)) candidate)]))

(define (lint-stdlib-string-decl-list-globals-at
  [decls : ast.AstDeclList]
  [target-module-id : i64]
  [current-module-id : i64]
  [names : LintNameSet]) : LintNameSet
  (match (ast.ast-decl-list-step decls)
    [(Nil) names]
    [(Cons decl rest)
      (match (owned_view.compiler-owned-shared-view decl)
        [(Module module-id)
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
    [(Nil) (lint-unsafe-scan-empty)]
    [(Cons decl rest)
      (match (owned_view.compiler-owned-shared-view decl)
        [(Module module-id)
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
;; newest entry, so a later shape shadows an earlier one.
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
  [shapes : (& shapes LintCopyOnUpdateStructList)]
  [name : (& name str)]
  [index : i64]) : LintCopyOnUpdateMaybeStruct
  (if (< index 0)
    NoStruct
    (let
      [shape : LintCopyOnUpdateStructShape
        (owned_view.compiler-owned-array-element-shared-view shapes.slots index)]
      (if (string.eq shape.name name)
        (SomeStruct shape)
        (lint-copy-on-update-struct-find-at shapes name (- index 1))))))

(define (lint-copy-on-update-struct-find
  [shapes : (& shapes LintCopyOnUpdateStructList)]
  [name : (& name str)]) : LintCopyOnUpdateMaybeStruct
  (lint-copy-on-update-struct-find-at shapes name (- shapes.len 1)))

(define (lint-copy-on-update-struct-known-name
  [shapes : (& shapes LintCopyOnUpdateStructList)]
  [name-id : i64]) : String
  (let
    [name : String (ci.intern-str name-id)]
    (match (lint-copy-on-update-struct-find shapes name)
      [(NoStruct) ""]
      [(SomeStruct _) name])))

(define (lint-copy-on-update-struct-name-from-type
  [shapes : (& shapes LintCopyOnUpdateStructList)]
  [ty : ast.AstType]) : String
  (match ty
    [(Struct name) (lint-copy-on-update-struct-known-name shapes name)]
    [(StructArgs name _) (lint-copy-on-update-struct-known-name shapes name)]
    [(Var name) (lint-copy-on-update-struct-known-name shapes name)]
    [(VarArgs name _) (lint-copy-on-update-struct-known-name shapes name)]
    [_ ""]))

(define (lint-copy-on-update-struct-name-from-maybe-type
  [shapes : (& shapes LintCopyOnUpdateStructList)]
  [maybe-ty : ast.AstMaybeType]) : String
  (match maybe-ty
    [(No) ""]
    [(Some ty) (lint-copy-on-update-struct-name-from-type shapes ty)]))

(define (lint-copy-on-update-locals-empty) : LintCopyOnUpdateLocalList
  (LintCopyOnUpdateLocalList (__tl_make-array LintCopyOnUpdateLocal 0) 0))

(define (lint-copy-on-update-local-index
  [locals : (& locals LintCopyOnUpdateLocalList)]
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
    [found : i64 (lint-copy-on-update-local-index locals name 0)]
    (if (< found 0)
      locals
      (let
        [n : i64 (- locals.len 1)]
        [slots : (__tl_dyn-array LintCopyOnUpdateLocal)
          (__tl_make-array LintCopyOnUpdateLocal n)]
        [index : i64 0]
        (while (< index n)
          (set!
            (array-ref slots index)
            (array-ref
              locals.slots
              (if (< index found)
                index
                (+ index 1))))
          (set! index (+ index 1)))
        (LintCopyOnUpdateLocalList slots n)))))

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
        (while (< index n)
          (set! (array-ref slots index) (array-ref without.slots index))
          (set! index (+ index 1)))
        (set! (array-ref slots n) (LintCopyOnUpdateLocal name type-name))
        (LintCopyOnUpdateLocalList slots (+ n 1))))))

(define (lint-copy-on-update-local-type
  [locals : (& locals LintCopyOnUpdateLocalList)]
  [name : String]) : String
  (let
    [found : i64 (lint-copy-on-update-local-index locals name 0)]
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
  [shapes : (& shapes LintCopyOnUpdateStructList)]
  [locals : LintCopyOnUpdateLocalList]
  [index : i64]) : LintCopyOnUpdateLocalList
  (if (>= index (ast.ast-param-list-len params))
    locals
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(Param name ty _)
        (lint-copy-on-update-param-locals-at
          params
          shapes
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
  [shapes : (& shapes LintCopyOnUpdateStructList)]
  [locals : LintCopyOnUpdateLocalList]
  [index : i64]) : LintCopyOnUpdateLocalList
  (if (>= index (ast.ast-macro-param-list-len params))
    locals
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(Param name ty _ _)
        (lint-copy-on-update-macro-param-locals-at
          params
          shapes
          (lint-copy-on-update-local-add
            locals
            (ci.intern-str name)
            (lint-copy-on-update-struct-name-from-type shapes ty))
          (+ index 1))])))

(define (lint-copy-on-update-expr-var-name [expr : ast.AstExpr]) : String
  (match expr
    [(Spanned inner _)
      (lint-copy-on-update-expr-var-name (ast.ast-node-get inner))]
    [(Var name) (ci.intern-str name)]
    [_ ""]))

(define (lint-copy-on-update-copied-field?
  [target-name : String]
  [field-name : String]
  [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner _)
      (lint-copy-on-update-copied-field?
        target-name
        field-name
        (ast.ast-node-get inner))]
    [(StructGet receiver field)
      (and
        (string.eq
          (lint-copy-on-update-expr-var-name (ast.ast-node-get receiver))
          target-name)
        (string.eq (ci.intern-str field) field-name))]
    [(Var name)
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
  (if (>= index (lint-name-set-count fields))
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
        state.locals
        (owned_view.compiler-owned-shared-view target-name))]
    (if (or
      (string.eq type-name "")
      (lint-underscore-prefixed?
        (owned_view.compiler-owned-shared-view target-name)))
      state
      (match value
        [(Spanned inner _)
          (lint-copy-on-update-add-set-if-needed
            target
            (ast.ast-node-get inner)
            span
            state)]
        [(Ann inner _)
          (lint-copy-on-update-add-set-if-needed
            target
            (ast.ast-node-get inner)
            span
            state)]
        [(Cast inner _)
          (lint-copy-on-update-add-set-if-needed
            target
            (ast.ast-node-get inner)
            span
            state)]
        [(Call callee args)
          (let
            [callee-name : String
              (lint-copy-on-update-expr-var-name (ast.ast-node-get callee))]
            (if (not (string.eq callee-name type-name))
              state
              (match (lint-copy-on-update-struct-find state.shapes type-name)
                [(NoStruct) state]
                [(SomeStruct shape)
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
                        state
                        target-name
                        checked.changed-field
                        span)
                      state))])))]
        [_ state]))))

(define (lint-copy-on-update-init-type-name
  [state : (& state LintCopyOnUpdateState)]
  [expr : ast.AstExpr]) : String
  (match expr
    [(Spanned inner _)
      (lint-copy-on-update-init-type-name state (ast.ast-node-get inner))]
    [(Ann inner ty-id)
      (let
        [annotated : String
          (lint-copy-on-update-struct-name-from-type
            state.shapes
            (ast.ty-node-get ty-id))]
        (if (string.eq annotated "")
          (lint-copy-on-update-init-type-name state (ast.ast-node-get inner))
          annotated))]
    [(Cast inner ty-id)
      (let
        [casted : String
          (lint-copy-on-update-struct-name-from-type
            state.shapes
            (ast.ty-node-get ty-id))]
        (if (string.eq casted "")
          (lint-copy-on-update-init-type-name state (ast.ast-node-get inner))
          casted))]
    [(Call callee _)
      (let
        [callee-name : String
          (lint-copy-on-update-expr-var-name (ast.ast-node-get callee))]
        (match (lint-copy-on-update-struct-find state.shapes callee-name)
          [(NoStruct) ""]
          [(SomeStruct _) callee-name]))]
    [(Var name)
      (lint-copy-on-update-local-type state.locals (ci.intern-str name))]
    [_ ""]))

(define (lint-copy-on-update-local-type-from-binding
  [state : (& state LintCopyOnUpdateState)]
  [maybe-ty : ast.AstMaybeType]
  [init : i64]) : String
  (let
    [annotated : String
      (lint-copy-on-update-struct-name-from-maybe-type state.shapes maybe-ty)]
    (if (string.eq annotated "")
      (lint-copy-on-update-init-type-name state (ast.ast-node-get init))
      annotated)))

(define (lint-copy-on-update-expr-list
  [exprs : ast.AstExprList]
  [state : LintCopyOnUpdateState]) : LintCopyOnUpdateState
  (lint-copy-on-update-expr-list-at (& exprs) 0 state (lint-no-span)))

;; Walk `exprs` in order under `span`: no span for the items of a list form,
;; the enclosing span for the expression children of any other node.
(define (lint-copy-on-update-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [state : LintCopyOnUpdateState]
  [span : ast.AstSourceSpan]) : LintCopyOnUpdateState
  (if (>= index exprs.len)
    state
    (lint-copy-on-update-expr-list-at
      exprs
      (+ index 1)
      (lint-copy-on-update-expr
        (ast.ast-expr-list-get exprs index 0)
        state
        span)
      span)))

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
      [(Binding name maybe-ty init)
        (let
          [after-init : LintCopyOnUpdateState
            (lint-copy-on-update-expr init state (lint-no-effect-span-id init))]
          [type-name : String
            (lint-copy-on-update-local-type-from-binding
              after-init
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
  [body : i64]
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
      [(Arm _ body)
        (lint-copy-on-update-match-arms-at
          arms
          (lint-copy-on-update-expr body state (lint-no-span))
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
      [(Binding _ init cleanup _)
        (lint-copy-on-update-resource-bindings-at
          bindings
          (lint-copy-on-update-expr
            cleanup
            (lint-copy-on-update-expr init state (lint-no-effect-span-id init))
            (lint-no-effect-span-id cleanup))
          (+ index 1))])))

(define (lint-copy-on-update-expr
  [node-id : i64]
  [state : LintCopyOnUpdateState]
  [span : ast.AstSourceSpan]) : LintCopyOnUpdateState
  ;; The arms below track locals and set! targets, walk list items and match
  ;; arms without an enclosing span, and name the forms this rule does not
  ;; descend into; every other variant's expression children are walked
  ;; through the AstExpr child list.
  (match (ast.ast-node-get node-id)
    [(Spanned inner _)
      (lint-copy-on-update-expr inner state (lint-no-effect-span-id inner))]
    [(Call callee args)
      (lint-copy-on-update-expr-list
        args
        (lint-copy-on-update-expr callee state span))]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body) (lint-copy-on-update-let bindings body state span)])]
    [(Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(Lambda params _ body)
          (let
            [outer-locals : LintCopyOnUpdateLocalList state.locals]
            [with-params : LintCopyOnUpdateState
              (lint-copy-on-update-state-with
                (owned_view.compiler-owned-shared-view state)
                (lint-copy-on-update-param-locals
                  params
                  state.shapes
                  (owned_view.compiler-owned-shared-view outer-locals))
                state.findings)]
            [with-body : LintCopyOnUpdateState
              (lint-copy-on-update-expr body with-params span)]
            (lint-copy-on-update-state-with
              (owned_view.compiler-owned-shared-view with-body)
              outer-locals
              with-body.findings))])]
    [(Tuple exprs) (lint-copy-on-update-expr-list exprs state)]
    [(Array exprs) (lint-copy-on-update-expr-list exprs state)]
    [(DynArray exprs) (lint-copy-on-update-expr-list exprs state)]
    [(Begin exprs) (lint-copy-on-update-expr-list exprs state)]
    [(Unsafe exprs) (lint-copy-on-update-expr-list exprs state)]
    [(Set target value)
      (lint-copy-on-update-add-set-if-needed
        target
        (ast.ast-node-get value)
        span
        (lint-copy-on-update-expr value state span))]
    [(Match match-box)
      (match (__tl-box-place match-box)
        [(Match scrutinee arms)
          (lint-copy-on-update-match-arms
            arms
            (lint-copy-on-update-expr scrutinee state span))])]
    [(Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(Foreach name ty start end body)
          (let
            [after-range : LintCopyOnUpdateState
              (lint-copy-on-update-expr
                end
                (lint-copy-on-update-expr
                  start
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
              (lint-copy-on-update-expr body with-local span)]
            (lint-copy-on-update-state-with
              (owned_view.compiler-owned-shared-view with-body)
              outer-locals
              with-body.findings))]
        [(Foreach2 outer outer-ty a b inner inner-ty c d body)
          (let
            [after-range : LintCopyOnUpdateState
              (lint-copy-on-update-expr
                d
                (lint-copy-on-update-expr
                  c
                  (lint-copy-on-update-expr
                    b
                    (lint-copy-on-update-expr
                      a
                      (owned_view.compiler-owned-shared-view state)
                      span)
                    span)
                  span)
                span)]
            [outer-locals : LintCopyOnUpdateLocalList
              (owned_view.compiler-owned-shared-view after-range.locals)]
            [with-locals : LintCopyOnUpdateState
              (lint-copy-on-update-state-with
                (owned_view.compiler-owned-shared-view after-range)
                (lint-copy-on-update-local-add
                  (lint-copy-on-update-local-add
                    (owned_view.compiler-owned-shared-view outer-locals)
                    (ci.intern-str outer)
                    (lint-copy-on-update-struct-name-from-type
                      state.shapes
                      outer-ty))
                  (ci.intern-str inner)
                  (lint-copy-on-update-struct-name-from-type
                    state.shapes
                    inner-ty))
                after-range.findings)]
            [with-body : LintCopyOnUpdateState
              (lint-copy-on-update-expr body with-locals span)]
            (lint-copy-on-update-state-with
              (owned_view.compiler-owned-shared-view with-body)
              outer-locals
              with-body.findings))])]
    [(WithRegion _ body) (lint-copy-on-update-expr-list body state)]
    [(WithEscape scratch body)
      (lint-copy-on-update-expr-list
        body
        (lint-copy-on-update-expr scratch state span))]
    [(WithScratch body) (lint-copy-on-update-expr-list body state)]
    [(InArena arena body)
      (lint-copy-on-update-expr-list
        body
        (lint-copy-on-update-expr arena state span))]
    [(WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(WithResource bindings body)
          (lint-copy-on-update-expr-list
            body
            (lint-copy-on-update-resource-bindings bindings state))])]
    [(Quote _) state]
    [(Quasiquote _) state]
    [(BracketClause items) (lint-copy-on-update-expr-list items state)]
    [(MacroExpansion _ _ _) state]
    [(SpmdReduce _) state]
    [(SpmdScan _) state]
    [(SpmdCompact _) state]
    [(SpmdBroadcast _ _) state]
    [(SpmdShuffle _ _) state]
    [(PtrNullCheck _) state]
    [(PtrAddrOf _) state]
    [(PtrRead _) state]
    [(PtrWrite _ _) state]
    [(PtrOffset _ _) state]
    [(PtrCast _ _) state]
    [(PtrToInt _) state]
    [(IntToPtr _ _) state]
    [(StringData _) state]
    [(StringFromBytes _ _) state]
    [(ArrayData _) state]
    [(CpuIdEax _ _) state]
    [(CpuIdEbx _ _) state]
    [(CpuIdEcx _ _) state]
    [(CpuIdEdx _ _) state]
    [(Xgetbv _) state]
    [(Syscall _) state]
    [(ForOwnedState _) state]
    [(ForOwnedStep _) state]
    [(ForeachActive lane body)
      (let
        [outer-locals : LintCopyOnUpdateLocalList
          (owned_view.compiler-owned-shared-view state.locals)]
        [with-local : LintCopyOnUpdateState
          (lint-copy-on-update-state-with
            (owned_view.compiler-owned-shared-view state)
            (lint-copy-on-update-local-add
              (owned_view.compiler-owned-shared-view outer-locals)
              (ci.intern-str lane)
              (lint-copy-on-update-struct-name-from-type state.shapes (I64)))
            state.findings)]
        [with-body : LintCopyOnUpdateState
          (lint-copy-on-update-expr body with-local span)]
        (lint-copy-on-update-state-with
          (owned_view.compiler-owned-shared-view with-body)
          outer-locals
          with-body.findings))]
    [_
      (let
        [ids : ast.AstExprList
          (ast.ast-expr-child-ids (ast.ast-node-get node-id))]
        (lint-copy-on-update-expr-list-at (& ids) 0 state span))]))

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
      [(Def name _ _)
        (lint-copy-on-update-field-names-at
          fields
          (+ index 1)
          (lint-name-set-add
            names
            (ci.intern-str (ci.intern-syntax-id-value name))))])))

(define (lint-copy-on-update-add-struct
  [name : i64]
  [fields : ast.AstFieldDefList]
  [shapes : LintCopyOnUpdateStructList]) : LintCopyOnUpdateStructList
  (let
    [names : LintNameSet (lint-copy-on-update-field-names fields)]
    [n : i64 shapes.len]
    [slots : (__tl_dyn-array LintCopyOnUpdateStructShape) shapes.slots]
    (if (< n (array-length slots))
      unit
      (let
        [bigger : (__tl_dyn-array LintCopyOnUpdateStructShape)
          (__tl_make-array
            LintCopyOnUpdateStructShape
            (lint-grown-capacity (array-length slots)))]
        [index : i64 0]
        (while (< index n)
          (set! (array-ref bigger index) (array-ref slots index))
          (set! index (+ index 1)))
        (set! slots bigger)))
    (set!
      (array-ref slots n)
      (LintCopyOnUpdateStructShape
        (ci.intern-str name)
        (owned_view.compiler-owned-shared-view names)
        (lint-name-set-count names)))
    (LintCopyOnUpdateStructList slots (+ n 1))))

(define (lint-copy-on-update-collect-structs-in-decl
  [decl : ast.AstDecl]
  [shapes : LintCopyOnUpdateStructList]) : LintCopyOnUpdateStructList
  (match decl
    [(DefStruct decl-meta name _ _ fields)
      (lint-copy-on-update-add-struct name fields shapes)]
    [(DefStructLifetimes decl-meta name _ _ _ fields)
      (lint-copy-on-update-add-struct name fields shapes)]
    [(Unsafe inner)
      (lint-copy-on-update-collect-structs-in-decl (deref inner) shapes)]
    [_ shapes]))

(define (lint-copy-on-update-collect-structs
  [decls : ast.AstDeclList]
  [shapes : LintCopyOnUpdateStructList]) : LintCopyOnUpdateStructList
  (match (ast.ast-decl-list-step decls)
    [(Nil) shapes]
    [(Cons decl rest)
      (lint-copy-on-update-collect-structs
        rest
        (lint-copy-on-update-collect-structs-in-decl decl shapes))]))

(define (lint-copy-on-update-structs-in-decl
  [decl : ast.AstDecl]
  [shapes : LintCopyOnUpdateStructList]
  [acc : LintFindings]) : LintFindings
  (match decl
    [(Def decl-meta _ _ body)
      (__tl-project-field
        (lint-copy-on-update-expr
          body
          (LintCopyOnUpdateState shapes (lint-copy-on-update-locals-empty) acc)
          (lint-no-span))
        findings)]
    [(DefFn decl-meta _ params _ body _)
      (__tl-project-field
        (lint-copy-on-update-expr
          body
          (LintCopyOnUpdateState
            (owned_view.compiler-owned-shared-view shapes)
            (lint-copy-on-update-param-locals
              params
              shapes
              (lint-copy-on-update-locals-empty))
            acc)
          (lint-no-span))
        findings)]
    [(DefMacro decl-meta _ params _ body)
      (__tl-project-field
        (lint-copy-on-update-expr
          body
          (LintCopyOnUpdateState
            (owned_view.compiler-owned-shared-view shapes)
            (lint-copy-on-update-macro-param-locals
              params
              shapes
              (lint-copy-on-update-locals-empty))
            acc)
          (lint-no-span))
        findings)]
    [(Test _ body _ _)
      (__tl-project-field
        (lint-copy-on-update-expr
          body
          (LintCopyOnUpdateState shapes (lint-copy-on-update-locals-empty) acc)
          (lint-no-span))
        findings)]
    [(Unsafe inner)
      (lint-copy-on-update-structs-in-decl
        (ast.ast-decl-box-shared-view inner)
        shapes
        acc)]
    [_ acc]))

(define (lint-copy-on-update-structs-in-decl-list
  [decls : ast.AstDeclList]
  [shapes : LintCopyOnUpdateStructList]
  [acc : LintFindings]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(Nil) acc]
    [(Cons decl rest)
      (lint-copy-on-update-structs-in-decl-list
        rest
        (owned_view.compiler-owned-shared-view shapes)
        (lint-copy-on-update-structs-in-decl decl shapes acc))]))

(defstruct LintSingleElementArrayCandidate
  (name String)
  (span ast.AstSourceSpan)
  (valid bool)
  (used bool))

;; Tracked cells: the newest candidate is the last slot, and every walk counts
;; down from `slots[len - 1]`, newest first. Entries are unique by name and
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
  [items : (& items LintSingleElementArrayCandidateList)]
  [name : String]
  [index : i64]) : i64
  (if (>= index items.len)
    (- 0 1)
    (if (string.eq (__tl-project-field (array-ref items.slots index) name) name)
      index
      (lint-single-element-array-candidate-index items name (+ index 1)))))

(define (lint-single-element-array-candidate-tracked?
  [items : (& items LintSingleElementArrayCandidateList)]
  [name : String]) : bool
  (>= (lint-single-element-array-candidate-index items name 0) 0))

(define (lint-single-element-array-candidate-remove
  [items : LintSingleElementArrayCandidateList]
  [name : String]) : LintSingleElementArrayCandidateList
  (let
    [found : i64 (lint-single-element-array-candidate-index items name 0)]
    (if (< found 0)
      items
      (let
        [n : i64 (- items.len 1)]
        [slots : (__tl_dyn-array LintSingleElementArrayCandidate)
          (__tl_make-array LintSingleElementArrayCandidate n)]
        [index : i64 0]
        (while (< index n)
          (set!
            (array-ref slots index)
            (array-ref
              items.slots
              (if (< index found)
                index
                (+ index 1))))
          (set! index (+ index 1)))
        (LintSingleElementArrayCandidateList slots n)))))

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
    (while (< index n)
      (set! (array-ref slots index) (array-ref without.slots index))
      (set! index (+ index 1)))
    (set!
      (array-ref slots n)
      (LintSingleElementArrayCandidate name span true false))
    (LintSingleElementArrayCandidateList slots (+ n 1))))

(define (lint-single-element-array-candidate-replace
  [items : LintSingleElementArrayCandidateList]
  [found : i64]
  [item : LintSingleElementArrayCandidate]) : LintSingleElementArrayCandidateList
  (let
    [n : i64 items.len]
    [slots : (__tl_dyn-array LintSingleElementArrayCandidate)
      (__tl_make-array LintSingleElementArrayCandidate n)]
    [index : i64 0]
    (while (< index n)
      (set! (array-ref slots index) (array-ref items.slots index))
      (set! index (+ index 1)))
    (set! (array-ref slots found) item)
    (LintSingleElementArrayCandidateList slots n)))

(define (lint-single-element-array-candidate-mark-use
  [items : LintSingleElementArrayCandidateList]
  [name : String]) : LintSingleElementArrayCandidateList
  (let
    [found : i64 (lint-single-element-array-candidate-index items name 0)]
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
    [found : i64 (lint-single-element-array-candidate-index items name 0)]
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
    state.candidates
    (owned_view.compiler-owned-shared-view name))
    (lint-single-element-array-note-escape state name)
    state))

(define (lint-single-element-array-scalar-type? [ty : ast.AstType]) : bool
  (match ty
    [(I64) true]
    [(I32) true]
    [(I16) true]
    [(I8) true]
    [(U64) true]
    [(U32) true]
    [(U16) true]
    [(U8) true]
    [(F64) true]
    [(F32) true]
    [(Bool) true]
    [(Char) true]
    [(Ptr _) true]
    [(MutPtr _) true]
    [_ false]))

(define (lint-single-element-array-scalar-type-id? [ty-id : i64]) : bool
  (lint-single-element-array-scalar-type? (ast.ty-node-get ty-id)))

(define (lint-single-element-array-fixed-type? [ty : ast.AstType]) : bool
  (match ty
    [(Array elem count)
      (and (= count 1) (lint-single-element-array-scalar-type-id? elem))]
    [_ false]))

(define (lint-single-element-array-maybe-fixed-type?
  [maybe-ty : ast.AstMaybeType]) : bool
  (match maybe-ty
    [(Some ty) (lint-single-element-array-fixed-type? ty)]
    [(No) false]))

(define (lint-single-element-array-dynamic-element-scalar?
  [maybe-ty : ast.AstMaybeType]) : bool
  (match maybe-ty
    [(Some ty)
      (match ty
        [(DynArray elem) (lint-single-element-array-scalar-type-id? elem)]
        [_ false])]
    [(No) false]))

(define (lint-single-element-array-int-literal?
  [expr : ast.AstExpr]
  [value : i64]) : bool
  (match expr
    [(Spanned inner _)
      (lint-single-element-array-int-literal? (ast.ast-node-get inner) value)]
    [(Ann inner _)
      (lint-single-element-array-int-literal? (ast.ast-node-get inner) value)]
    [(Literal lit)
      (and
        (>
          (string.string-length
            (ast.ast-lit-int-text (owned_view.compiler-owned-shared-view lit)))
          0)
        (= (ast.ast-lit-int-value lit) value))]
    [_ false]))

(define (lint-single-element-array-expr-list-count
  [exprs : (& exprs ast.AstExprList)]) : i64
  exprs.len)

(define (lint-single-element-array-callee-name [expr : ast.AstExpr]) : String
  (match expr
    [(Spanned inner _)
      (lint-single-element-array-callee-name (ast.ast-node-get inner))]
    [(Var name) (ci.intern-str name)]
    [_ ""]))

(define (lint-single-element-array-var-name [expr : ast.AstExpr]) : String
  (match expr
    [(Spanned inner _)
      (lint-single-element-array-var-name (ast.ast-node-get inner))]
    [(Var name) (ci.intern-str name)]
    [_ ""]))

(define (lint-single-element-array-make-array-callee? [name : String]) : bool
  (string.eq name "__tl_make-array"))

(define (lint-single-element-array-ref-callee? [name : (& name str)]) : bool
  (or (string.eq name "array-ref") (string.eq name "__tl_array-ref")))

(define (lint-single-element-array-set-callee? [name : String]) : bool
  (or (string.eq name "array-set!") (string.eq name "__tl_array-set!")))

(define (lint-single-element-array-args-second-int?
  [args : (& args ast.AstExprList)]
  [value : i64]) : bool
  (if (> args.len 1)
    (lint-single-element-array-int-literal?
      (ast.ast-node-get (ast.ast-expr-list-get (& args) 1 0))
      value)
    false))

(define (lint-single-element-array-first-arg-name
  [args : (& args ast.AstExprList)]) : String
  (if (> args.len 0)
    (lint-single-element-array-var-name
      (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0)))
    ""))

(define (lint-single-element-array-make-array-one? [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner _)
      (lint-single-element-array-make-array-one? (ast.ast-node-get inner))]
    [(Ann inner _)
      (lint-single-element-array-make-array-one? (ast.ast-node-get inner))]
    [(MakeArray _ len)
      (lint-single-element-array-int-literal? (ast.ast-node-get len) 1)]
    [(Call func args)
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
  (lint-no-effect-span-id init))

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
      [(Param name ty _)
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
  [items : (& items LintSingleElementArrayCandidateList)]
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
  [items : (& items LintSingleElementArrayCandidateList)]
  [acc : LintFindings]) : LintFindings
  (lint-single-element-array-finalize-candidates-at items acc (- items.len 1)))

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
        (ast.ast-expr-list-get exprs index 0)
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
      [(Binding name maybe-ty init)
        (let
          [after-init : LintSingleElementArrayState
            (lint-single-element-array-expr init state)]
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
      [(Binding name init cleanup _)
        (let
          [after-init : LintSingleElementArrayState
            (lint-single-element-array-expr init state)]
          [after-cleanup : LintSingleElementArrayState
            (lint-single-element-array-expr cleanup after-init)]
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
    [name : String (lint-single-element-array-first-arg-name args)]
    (if (and
      (= (lint-single-element-array-expr-list-count args) 2)
      (lint-single-element-array-candidate-tracked?
        state.candidates
        (owned_view.compiler-owned-shared-view name))
      (lint-single-element-array-args-second-int? args 0))
      (lint-single-element-array-expr-list-after-two
        args
        (lint-single-element-array-note-use state name))
      (lint-single-element-array-expr-list args state))))

(define (lint-single-element-array-call-set
  [args : ast.AstExprList]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (let
    [name : String (lint-single-element-array-first-arg-name args)]
    (if (and
      (= (lint-single-element-array-expr-list-count args) 3)
      (lint-single-element-array-candidate-tracked?
        state.candidates
        (owned_view.compiler-owned-shared-view name))
      (lint-single-element-array-args-second-int? args 0))
      (lint-single-element-array-expr-list-after-two
        args
        (lint-single-element-array-note-use state name))
      (lint-single-element-array-expr-list args state))))

(define (lint-prefer-dynamic-array-literal-int-value [expr : ast.AstExpr]) : i64
  (match expr
    [(Spanned inner _)
      (lint-prefer-dynamic-array-literal-int-value (ast.ast-node-get inner))]
    [(Ann inner _)
      (lint-prefer-dynamic-array-literal-int-value (ast.ast-node-get inner))]
    [(Literal lit)
      (if (>
        (string.string-length
          (ast.ast-lit-int-text (owned_view.compiler-owned-shared-view lit)))
        0)
        (ast.ast-lit-int-value lit)
        -1)]
    [_ -1]))

(define (lint-prefer-dynamic-array-literal-allocation-length
  [expr : ast.AstExpr]) : i64
  (match expr
    [(Spanned inner _)
      (lint-prefer-dynamic-array-literal-allocation-length
        (ast.ast-node-get inner))]
    [(Ann inner _)
      (lint-prefer-dynamic-array-literal-allocation-length
        (ast.ast-node-get inner))]
    [(MakeArray _ length)
      (lint-prefer-dynamic-array-literal-int-value (ast.ast-node-get length))]
    [(Call func args)
      (if (and
        (lint-single-element-array-make-array-callee?
          (lint-single-element-array-callee-name (ast.ast-node-get func)))
        (= (lint-single-element-array-expr-list-count args) 2))
        (lint-prefer-dynamic-array-literal-int-value
          (ast.ast-node-get (ast.ast-expr-list-get (& args) 1 0)))
        -1)]
    [_ -1]))

(define (lint-prefer-dynamic-array-literal-var?
  [expr : ast.AstExpr]
  [name : String]) : bool
  (match expr
    [(Spanned inner _)
      (lint-prefer-dynamic-array-literal-var? (ast.ast-node-get inner) name)]
    [(Ann inner _)
      (lint-prefer-dynamic-array-literal-var? (ast.ast-node-get inner) name)]
    [(Var found) (string.eq (ci.intern-str found) name)]
    [_ false]))

(define (lint-prefer-dynamic-array-literal-final-value?
  [expr : ast.AstExpr]
  [name : String]) : bool
  (match (owned_view.compiler-owned-shared-view expr)
    [(Spanned inner _)
      (lint-prefer-dynamic-array-literal-final-value?
        (ast.ast-node-get inner)
        name)]
    [(Ann inner _)
      (lint-prefer-dynamic-array-literal-final-value?
        (ast.ast-node-get inner)
        name)]
    [(Return inner)
      (lint-prefer-dynamic-array-literal-var? (ast.ast-node-get inner) name)]
    [(Set target value)
      (and
        (not (string.eq (ci.intern-str target) name))
        (lint-prefer-dynamic-array-literal-var? (ast.ast-node-get value) name))]
    [_ (lint-prefer-dynamic-array-literal-var? expr name)]))

(define (lint-prefer-dynamic-array-literal-bare-var? [expr : ast.AstExpr]) : bool
  (match expr
    [(Spanned inner _)
      (lint-prefer-dynamic-array-literal-bare-var? (ast.ast-node-get inner))]
    [(Var _) true]
    [_ false]))

(define (lint-prefer-dynamic-array-literal-value-uses-name?
  [expr : i64]
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
    [items : LintSingleElementArrayCandidateList result.candidates]
    [top : i64 (- items.len 1)]
    (if (< top 0)
      false
      (let
        [item : LintSingleElementArrayCandidate
          (owned_view.compiler-owned-array-element-shared-view items.slots top)]
        (or item.used (not item.valid))))))

(define (lint-prefer-dynamic-array-literal-set-callee? [name : String]) : bool
  (lint-single-element-array-set-callee? name))

(define (lint-prefer-dynamic-array-literal-set-at?
  [expr : ast.AstExpr]
  [name : String]
  [index : i64]) : bool
  (match expr
    [(Spanned inner _)
      (lint-prefer-dynamic-array-literal-set-at?
        (ast.ast-node-get inner)
        name
        index)]
    [(Ann inner _)
      (lint-prefer-dynamic-array-literal-set-at?
        (ast.ast-node-get inner)
        name
        index)]
    [(ArraySet array actual-index value)
      (and
        (string.eq
          (lint-single-element-array-var-name (ast.ast-node-get array))
          name)
        (lint-single-element-array-int-literal?
          (ast.ast-node-get actual-index)
          index)
        (not (lint-prefer-dynamic-array-literal-value-uses-name? value name)))]
    [(Call func args)
      (and
        (lint-prefer-dynamic-array-literal-set-callee?
          (lint-single-element-array-callee-name (ast.ast-node-get func)))
        (= (lint-single-element-array-expr-list-count args) 3)
        (string.eq (lint-single-element-array-first-arg-name args) name)
        (lint-single-element-array-args-second-int? args index)
        (not
          (lint-prefer-dynamic-array-literal-value-uses-name?
            (ast.ast-expr-list-get (& args) 2 0)
            name)))]
    [_ false]))

(define (lint-prefer-dynamic-array-literal-first-write-bare-var?
  [expr : ast.AstExpr]
  [name : (& name str)]) : bool
  (match expr
    [(Spanned inner _)
      (lint-prefer-dynamic-array-literal-first-write-bare-var?
        (ast.ast-node-get inner)
        name)]
    [(Ann inner _)
      (lint-prefer-dynamic-array-literal-first-write-bare-var?
        (ast.ast-node-get inner)
        name)]
    [(ArraySet array index value)
      (and
        (string.eq
          (lint-single-element-array-var-name (ast.ast-node-get array))
          name)
        (lint-single-element-array-int-literal? (ast.ast-node-get index) 0)
        (lint-prefer-dynamic-array-literal-bare-var? (ast.ast-node-get value)))]
    [(Call func args)
      (and
        (lint-prefer-dynamic-array-literal-set-callee?
          (lint-single-element-array-callee-name (ast.ast-node-get func)))
        (= (lint-single-element-array-expr-list-count args) 3)
        (string.eq (lint-single-element-array-first-arg-name args) name)
        (lint-single-element-array-args-second-int? args 0)
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
      name)
    (and
      (lint-prefer-dynamic-array-literal-set-at?
        (ast.ast-node-get (ast.ast-expr-list-get (& exprs) index 0))
        (owned_view.compiler-owned-shared-view name)
        index)
      (lint-prefer-dynamic-array-literal-write-sequence?
        exprs
        name
        length
        (+ index 1)))))

(define (lint-prefer-dynamic-array-literal-body?
  [body : ast.AstExpr]
  [name : String]
  [length : i64]) : bool
  (match body
    [(Spanned inner _)
      (lint-prefer-dynamic-array-literal-body?
        (ast.ast-node-get inner)
        name
        length)]
    [(Ann inner _)
      (lint-prefer-dynamic-array-literal-body?
        (ast.ast-node-get inner)
        name
        length)]
    [(Begin exprs)
      (and
        (= (lint-single-element-array-expr-list-count exprs) (+ length 1))
        (not
          (and
            (= length 2)
            (lint-prefer-dynamic-array-literal-first-write-bare-var?
              (ast.ast-node-get (ast.ast-expr-list-get (& exprs) 0 0))
              name)))
        (lint-prefer-dynamic-array-literal-write-sequence? exprs name length 0))]
    [_ false]))

(define (lint-prefer-dynamic-array-literals-in-let-bindings
  [bindings : (& bindings ast.AstLetBindingList)]
  [body : ast.AstExpr]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (lint-prefer-dynamic-array-literals-in-let-bindings-at
    (& bindings)
    body
    state
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
      [(Binding name-id _ init)
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
                    name
                    (lint-no-effect-span-id init))
                  (owned_view.compiler-owned-shared-view state.findings)))
              state)]
          (lint-prefer-dynamic-array-literals-in-let-bindings-at
            bindings
            body
            next
            (+ index 1)))])))

(define (lint-single-element-array-children
  [node-id : i64]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (lint-single-element-array-expr-list
    (ast.ast-expr-child-ids (ast.ast-node-get node-id))
    state))

(define (lint-single-element-array-expr
  [node-id : i64]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  ;; The arms below track candidate cells and their uses, bind names and skip
  ;; quoted syntax; every other variant's children are walked through the
  ;; AstExpr child list.
  (match (ast.ast-node-get node-id)
    [(Var name) (lint-single-element-array-note-var state (ci.intern-str name))]
    [(Call func args)
      (let
        [callee : String
          (lint-single-element-array-callee-name (ast.ast-node-get func))]
        [after-func : LintSingleElementArrayState
          (lint-single-element-array-expr func state)]
        (cond
          [(lint-single-element-array-ref-callee? callee)
            (lint-single-element-array-call-ref args after-func)]
          [(lint-single-element-array-set-callee? callee)
            (lint-single-element-array-call-set args after-func)]
          [else (lint-single-element-array-expr-list args after-func)]))]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body)
          (let
            [with-dynamic-array-literals : LintSingleElementArrayState
              (lint-prefer-dynamic-array-literals-in-let-bindings
                bindings
                (ast.ast-node-get body)
                state)]
            (lint-single-element-array-expr
              body
              (lint-single-element-array-let-bindings
                bindings
                with-dynamic-array-literals)))])]
    [(ArrayRef array index)
      (let
        [name : String
          (lint-single-element-array-var-name (ast.ast-node-get array))]
        (if (and
          (lint-single-element-array-candidate-tracked?
            state.candidates
            (owned_view.compiler-owned-shared-view name))
          (lint-single-element-array-int-literal? (ast.ast-node-get index) 0))
          (lint-single-element-array-note-use state name)
          (lint-single-element-array-children node-id state)))]
    [(ArraySet array index value)
      (let
        [name : String
          (lint-single-element-array-var-name (ast.ast-node-get array))]
        (if (and
          (lint-single-element-array-candidate-tracked?
            state.candidates
            (owned_view.compiler-owned-shared-view name))
          (lint-single-element-array-int-literal? (ast.ast-node-get index) 0))
          (lint-single-element-array-expr
            value
            (lint-single-element-array-note-use state name))
          (lint-single-element-array-children node-id state)))]
    [(ArrayTake array live index)
      (let
        [name : String
          (lint-single-element-array-var-name (ast.ast-node-get array))]
        (if (and
          (lint-single-element-array-candidate-tracked?
            state.candidates
            (owned_view.compiler-owned-shared-view name))
          (lint-single-element-array-int-literal? (ast.ast-node-get index) 0))
          (lint-single-element-array-expr
            live
            (lint-single-element-array-note-use state name))
          (lint-single-element-array-children node-id state)))]
    [(ForOwnedState payload)
      (lint-single-element-array-expr
        (ast.ast-for-owned-state-body (& payload))
        (lint-single-element-array-expr
          (ast.ast-for-owned-state-source (& payload))
          state))]
    [(ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (lint-single-element-array-expr
          (ast.ast-for-owned-step-body (& payload))
          (if (>= expected-type 0)
            (lint-single-element-array-expr expected-type state)
            state)))]
    [(Set target value)
      (lint-single-element-array-expr
        value
        (lint-single-element-array-note-var state (ci.intern-str target)))]
    [(WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(WithResource bindings body)
          (lint-single-element-array-expr-list
            body
            (lint-single-element-array-resource-bindings bindings state))])]
    [(Quote _) state]
    [(Quasiquote _) state]
    [_ (lint-single-element-array-children node-id state)]))

(define (lint-single-element-array-cells-in-decl
  [decl : ast.AstDecl]
  [acc : LintFindings]) : LintFindings
  (match decl
    [(Def decl-meta _ _ body)
      (lint-single-element-array-finalize-state
        (lint-single-element-array-expr
          body
          (LintSingleElementArrayState
            (lint-single-element-array-candidates-empty)
            acc)))]
    [(DefFn decl-meta _ params _ body _)
      (let
        [body-span : ast.AstSourceSpan (lint-no-effect-span-id body)]
        [param-candidates : LintSingleElementArrayCandidateList
          (lint-single-element-array-param-candidates
            params
            body-span
            (lint-single-element-array-candidates-empty))]
        (lint-single-element-array-finalize-state
          (lint-single-element-array-expr
            body
            (LintSingleElementArrayState param-candidates acc))))]
    [(Test _ body _ _)
      (lint-single-element-array-finalize-state
        (lint-single-element-array-expr
          body
          (LintSingleElementArrayState
            (lint-single-element-array-candidates-empty)
            acc)))]
    [(Unsafe inner)
      (lint-single-element-array-cells-in-decl
        (ast.ast-decl-box-shared-view inner)
        acc)]
    [_ acc]))

(define (lint-single-element-array-cells-in-decl-list
  [decls : ast.AstDeclList]
  [acc : LintFindings]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(Nil) acc]
    [(Cons decl rest)
      (lint-single-element-array-cells-in-decl-list
        rest
        (lint-single-element-array-cells-in-decl decl acc))]))

(define (lint-pending-assignment-empty) : LintPendingAssignmentList
  (LintPendingAssignmentList (__tl_make-array LintPendingAssignment 0) 0))

(define (lint-pending-assignment-index
  [items : (& items LintPendingAssignmentList)]
  [name : String]
  [index : i64]) : i64
  (if (>= index items.len)
    (- 0 1)
    (if (string.eq (__tl-project-field (array-ref items.slots index) name) name)
      index
      (lint-pending-assignment-index items name (+ index 1)))))

(define (lint-pending-assignment-find
  [items : (& items LintPendingAssignmentList)]
  [name : String]) : LintMaybePendingAssignment
  (let
    [found : i64 (lint-pending-assignment-index items name 0)]
    (if (< found 0)
      No
      (Some
        (owned_view.compiler-owned-array-element-shared-view items.slots found)))))

(define (lint-pending-assignment-remove
  [items : LintPendingAssignmentList]
  [name : String]) : LintPendingAssignmentList
  (let
    [found : i64 (lint-pending-assignment-index items name 0)]
    (if (< found 0)
      items
      (let
        [n : i64 (- items.len 1)]
        [slots : (__tl_dyn-array LintPendingAssignment)
          (__tl_make-array LintPendingAssignment n)]
        [index : i64 0]
        (while (< index n)
          (set!
            (array-ref slots index)
            (array-ref
              items.slots
              (if (< index found)
                index
                (+ index 1))))
          (set! index (+ index 1)))
        (LintPendingAssignmentList slots n)))))

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
    (while (< index n)
      (set! (array-ref slots index) (array-ref without.slots index))
      (set! index (+ index 1)))
    (set! (array-ref slots n) (LintPendingAssignment name span))
    (LintPendingAssignmentList slots (+ n 1))))

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
            state.pending
            (owned_view.compiler-owned-shared-view name))]
        [next-findings : LintFindings
          (match found
            [(No) state.findings]
            [(Some pending)
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
  (let
    [next : LintUnusedAssignmentState state]
    (ast.ast-expr-list-fold
      exprs
      ast.ast-fold-seq
      unit
      lint-unused-assignment-child!
      next)
    next))

(define (lint-unused-assignment-note-reads-resource-bindings
  [bindings : ast.AstResourceBindingList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (let
    [next : LintUnusedAssignmentState state]
    (ast.ast-resource-binding-list-fold
      bindings
      ast.ast-fold-seq
      unit
      lint-unused-assignment-child!
      next)
    next))

;; List fold hook: note the reads of an expression, threading `state`.
(defmacro (lint-unused-assignment-child! [state : Expr] [child : Expr]) : Expr
  `(set! ,state (lint-unused-assignment-note-reads ,child ,state)))

;; Calls, branches, loops and binding forms end the straight-line stretch in
;; which a pending assignment can still be overwritten unread.
(define (lint-unused-assignment-clears-pending? [expr : (& expr ast.AstExpr)]) : bool
  (match expr
    [(Call _ _) true]
    [(If _ _ _) true]
    [(Let _) true]
    [(Lambda _) true]
    [(While _ _) true]
    [(Match _) true]
    [(Foreach _) true]
    [(SpmdReduce _) true]
    [(SpmdScan _) true]
    [(SpmdCompact _) true]
    [(ForeachActive _ _) true]
    [_ false]))

(define (lint-unused-assignment-note-reads
  [node-id : i64]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  ;; The arms below read names, skip quoted syntax and read only some
  ;; for-owned slots; every other variant reads its children through the
  ;; AstExpr child list.
  (match (ast.ast-node-get node-id)
    [(Var name) (lint-unused-assignment-read-id state name)]
    [(ForOwnedState payload)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast.ast-for-owned-state-body (& payload))
          (lint-unused-assignment-note-reads
            (ast.ast-for-owned-state-source (& payload))
            state)))]
    [(ForOwnedStep payload)
      (let
        [source : i64 (ast.ast-for-owned-step-source-name (& payload))]
        [index : i64 (ast.ast-for-owned-step-index-name (& payload))]
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        [done : i64 (ast.ast-for-owned-step-done-name (& payload))]
        [body : i64 (ast.ast-for-owned-step-body (& payload))]
        (lint-unused-assignment-note-reads
          body
          (lint-unused-assignment-note-reads
            done
            (if (>= expected-type 0)
              (lint-unused-assignment-note-reads
                expected-type
                (lint-unused-assignment-note-reads
                  index
                  (lint-unused-assignment-note-reads source state)))
              (lint-unused-assignment-note-reads
                index
                (lint-unused-assignment-note-reads source state))))))]
    [(Quote _) state]
    [(Quasiquote _) state]
    [_
      (let
        [expr : ast.AstExpr (ast.ast-node-get node-id)]
        [clears-pending : bool
          (lint-unused-assignment-clears-pending? (& expr))]
        [after-reads : LintUnusedAssignmentState
          (lint-unused-assignment-note-reads-list
            (ast.ast-expr-child-ids expr)
            state)]
        (if clears-pending
          (lint-unused-assignment-clear-pending after-reads)
          after-reads))]))

(define (lint-unused-assignment-binding-span [init : i64]) : ast.AstSourceSpan
  (lint-no-effect-span-id init))

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
      [head : i64 (ast.ast-expr-list-get exprs index 0)]
      (lint-unused-assignment-expr-list-after-terminal-at
        exprs
        (+ index 1)
        (lint-unused-assignment-expr head state (lint-no-span))
        (lint-terminal-expr? (ast.ast-node-get head))))))

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
      [(Binding name _ init)
        (let
          [after-init : LintUnusedAssignmentState
            (lint-unused-assignment-expr
              init
              state
              (lint-unused-assignment-binding-span init))]
          [text : String (ci.intern-str name)]
          [binding-base : LintUnusedAssignmentState
            (if (lint-name-set-contains?
              after-init.locals
              (owned_view.compiler-owned-shared-view text))
              (lint-unused-assignment-state-with
                (owned_view.compiler-owned-shared-view after-init)
                (lint-pending-assignment-remove
                  (owned_view.compiler-owned-shared-view after-init.pending)
                  (owned_view.compiler-owned-shared-view text))
                (owned_view.compiler-owned-shared-view after-init.findings))
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
  [body : i64]
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
  [node-id : i64]
  [state : LintUnusedAssignmentState]
  [span : ast.AstSourceSpan]) : LintUnusedAssignmentState
  (match (ast.ast-node-get node-id)
    [(Spanned inner-box inner-span)
      (lint-unused-assignment-expr inner-box state inner-span)]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body)
          (lint-unused-assignment-let bindings body state span)])]
    [(Begin exprs) (lint-unused-assignment-expr-list exprs state)]
    [(Unsafe exprs) (lint-unused-assignment-expr-list exprs state)]
    [(WithRegion _ body) (lint-unused-assignment-expr-list body state)]
    [(WithScratch body) (lint-unused-assignment-expr-list body state)]
    [(WithEscape scratch body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads scratch state))]
    [(InArena arena body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads arena state))]
    [(WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(WithResource bindings body)
          (lint-unused-assignment-expr-list
            body
            (lint-unused-assignment-note-reads-resource-bindings bindings state))])]
    [(Set target value)
      (lint-unused-assignment-write-id
        (lint-unused-assignment-note-reads value state)
        target
        span)]
    [_ (lint-unused-assignment-note-reads node-id state)]))

(define (lint-unused-assignment-state-empty
  [locals : LintNameSet]
  [acc : LintFindings]) : LintUnusedAssignmentState
  (LintUnusedAssignmentState locals (lint-pending-assignment-empty) acc))

(define (lint-unused-assignments-in-decl
  [decl : ast.AstDecl]
  [acc : LintFindings]) : LintFindings
  (match decl
    [(Def decl-meta _ _ body)
      (__tl-project-field
        (lint-unused-assignment-expr
          body
          (lint-unused-assignment-state-empty (lint-name-set-empty) acc)
          (lint-no-span))
        findings)]
    [(DefFn decl-meta _ params _ body _)
      (__tl-project-field
        (lint-unused-assignment-expr
          body
          (lint-unused-assignment-state-empty
            (lint-param-list-add-locals params (lint-name-set-empty))
            acc)
          (lint-no-span))
        findings)]
    [(DefMacro decl-meta _ params _ body)
      (__tl-project-field
        (lint-unused-assignment-expr
          body
          (lint-unused-assignment-state-empty
            (lint-macro-param-list-add-locals params (lint-name-set-empty))
            acc)
          (lint-no-span))
        findings)]
    [(Test _ body _ _)
      (__tl-project-field
        (lint-unused-assignment-expr
          body
          (lint-unused-assignment-state-empty (lint-name-set-empty) acc)
          (lint-no-span))
        findings)]
    [(Unsafe inner)
      (lint-unused-assignments-in-decl (ast.ast-decl-box-shared-view inner) acc)]
    [_ acc]))

(define (lint-unused-assignments-in-decl-list
  [decls : ast.AstDeclList]
  [acc : LintFindings]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(Nil) acc]
    [(Cons decl rest)
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

(define (lint-source-line-index-build! [source : (& source str)]) : unit
  (set! lint-source-line-starts (source_text.source-text-line-starts source)))

(define (lint-source-line-start [line : i64]) : i64
  (source_text.source-text-line-start (& lint-source-line-starts) line))

(define (lint-source-index-line-index [target : i64]) : i64
  (source_text.source-text-line-index (& lint-source-line-starts) target))

(defstruct LintUnusedVariableBinding
  (name String)
  (span ast.AstSourceSpan)
  (used bool)
  (reportable bool)
  (type-operand bool))

;; Scope bindings and the scope stack: the newest entry is the last slot, and
;; every walk counts down from `len - 1`, newest first. Frames are pushed and
;; popped by a single threaded state and each frame owns its bindings array, so
;; appends reuse spare capacity instead of rebuilding.
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

;; Highest index of `bindings` naming `name`, or -1. Counting down finds the
;; innermost binding first.
(define (lint-unused-variable-binding-index
  [bindings : (& bindings LintUnusedVariableBindingList)]
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
  (>= (lint-unused-variable-binding-index bindings name (- bindings.len 1)) 0))

(define (lint-unused-unsafe-frame-list-contains-at?
  [frames : (& frames LintUnusedVariableFrameList)]
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
  [frames : (& frames LintUnusedVariableFrameList)]
  [name : String]) : bool
  (lint-unused-unsafe-frame-list-contains-at? frames name (- frames.len 1)))

(define (lint-unused-unsafe-first-separator [name : (& name str)]) : i64
  (let
    [len : i64 (string.string-length name)]
    [index : i64 0]
    [found : i64 (- 0 1)]
    (while (and (< found 0) (< index len))
      (let
        [ch : char (string.string-ref name index)]
        (if (or (= ch '.') (= ch '/'))
          (set! found index)
          (set! index (+ index 1)))))
    found))

(define (lint-unused-unsafe-name-root [name : String]) : String
  (let
    [separator : i64 (lint-unused-unsafe-first-separator name)]
    (if (> separator 0)
      (string.substring name 0 separator)
      name)))

(define (lint-unused-unsafe-unknown-root-at?
  [name : String]
  [roots : (& roots LintUnusedUnsafeUnknownRoots)]
  [index : i64]) : bool
  (if (>= index roots.len)
    false
    (or
      (string.eq (array-ref roots.slots index) name)
      (lint-unused-unsafe-unknown-root-at? name roots (+ index 1)))))

(define (lint-unused-unsafe-unknown-root?
  [name : String]
  [roots : (& roots LintUnusedUnsafeUnknownRoots)]) : bool
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
          (Unknown)
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
        (RequiresUnsafe)
        (Safe))
      (Unknown))))

(define (lint-unused-unsafe-exact-name-lookup
  [state : (& state LintUnusedVariableState)]
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
        (lint-unused-unsafe-unknown-root? root lint-unused-unsafe-unknown-roots)))
      (Unknown)
      (lint-unused-unsafe-exact-name-lookup-from name facts false false 0))))

(define (lint-unused-unsafe-note-value-name!
  [state : (& state LintUnusedVariableState)]
  [name : String]) : unit
  (match (lint-unused-unsafe-exact-name-lookup
    state
    (owned_view.compiler-owned-shared-view name)
    (unsafe
      (ptr-read (ptr-addr-of lint-unused-unsafe-exact-names))))
    [(Unknown)
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
    [(Safe) unit]
    [(RequiresUnsafe) (lint-unused-unsafe-block-mark-required!)]))

(define (lint-unused-unsafe-note-call-target!
  [state : (& state LintUnusedVariableState)]
  [expr : ast.AstExpr]) : unit
  (match expr
    [(Spanned inner-box _)
      (lint-unused-unsafe-note-call-target! state (ast.ast-node-get inner-box))]
    [(Var name-id)
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
  [source : (& source str)]
  [start : i64]
  [needle : (& needle str)]) : bool
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
          (while (and ok (< idx needle-len))
            (if (=
              (string.string-ref source (+ start idx))
              (string.string-ref needle idx))
              (set! idx (+ idx 1))
              (set! ok false)))
          ok)))))

(define (lint-source-find-prefix-backward-from
  [source : (& source str)]
  [needle : (& needle str)]
  [idx : i64]) : i64
  (let
    [needle-len : i64 (string.string-length needle)]
    [last-start : i64 (- (string.string-length source) needle-len)]
    [cursor : i64
      (if (< idx last-start)
        idx
        last-start)]
    [found : i64 (- 0 1)]
    (while (and (< found 0) (>= cursor 0))
      (if (lint-source-prefix-at? source cursor needle)
        (set! found cursor)
        (set! cursor (- cursor 1))))
    found))

(define (lint-source-symbol-boundary? [source : (& source str)] [idx : i64]) : bool
  (let
    [source-len : i64 (string.string-length source)]
    (if (< idx 0)
      true
      (if (>= idx source-len)
        true
        (not (lexer.is-symbol-char (string.string-ref source idx)))))))

(define (lint-source-name-at?
  [source : (& source str)]
  [idx : i64]
  [name : (& name str)]) : bool
  (let
    [end : i64 (+ idx (string.string-length name))]
    (and
      (lint-source-prefix-at? source idx name)
      (lint-source-symbol-boundary? source (- idx 1))
      (lint-source-symbol-boundary? source end))))

(define (lint-source-find-name-from
  [source : (& source str)]
  [name : (& name str)]
  [idx : i64]) : i64
  (let
    [source-len : i64 (string.string-length source)]
    [found : i64 (- 0 1)]
    [i : i64 idx]
    (while (and (< found 0) (< i source-len))
      (if (lint-source-name-at? source i name)
        (set! found i)
        (set! i (+ i 1))))
    found))

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
  [source : (& source str)]
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
  [source : (& source str)]
  [name : (& name str)]
  [cursor : i64]
  [fallback : ast.AstSourceSpan]) : LintSourceNameSpan
  (let
    [found : i64 (lint-source-find-name-from source name cursor)]
    [width : i64 (string.string-length name)]
    (if (< found 0)
      (LintSourceNameSpan fallback cursor)
      (LintSourceNameSpan
        (lint-source-index-span found width fallback)
        (+ found width)))))

(define (lint-source-name-span-between
  [source : (& source str)]
  [name : (& name str)]
  [cursor : i64]
  [limit : i64]) : LintSourceNameSpan
  (let
    [found : i64 (lint-source-find-name-from source name cursor)]
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
      (lint-source-name-span-between state.source name cursor limit)]
    (LintNameCaseLocalScan
      (lint-unused-variable-add-local-name-case state name found.span)
      found.next-index)))

(define (lint-unused-variable-scan-form-local-name
  [state : LintUnusedVariableState]
  [name : String]
  [span : ast.AstSourceSpan]
  [form-head : String]) : LintNameCaseLocalScan
  (let
    [start : i64 (lint-source-span-start-index state.source span)]
    [limit : i64 (lint-source-span-end-index state.source span)]
    (if (or (< start 0) (< limit 0))
      (LintNameCaseLocalScan state 0)
      (lint-unused-variable-scan-local-name
        state
        name
        (+ start (string.string-length form-head))
        limit))))

(define (lint-name-case-pattern-add
  [source : (& source str)]
  [name : String]
  [cursor : i64]
  [limit : i64]
  [findings : LintFindings]
  [report : bool]) : LintNameCasePatternScan
  (let
    [found : LintSourceNameSpan
      (lint-source-name-span-between source name cursor limit)]
    [span : ast.AstSourceSpan found.span]
    [next : LintFindings
      (if (and
        report
        (lint-name-case-source-span? span)
        (not (lint-name-case-qualified-symbol? name))
        (not
          (lint-name-case-local-kebab?
            (owned_view.compiler-owned-shared-view name))))
        (lint-findings-add (lint-local-name-case-finding name span) findings)
        findings)]
    (LintNameCasePatternScan next found.next-index)))

(define (lint-name-case-pattern-list
  [patterns : ast.AstPatternList]
  [source : (& source str)]
  [cursor : i64]
  [limit : i64]
  [findings : LintFindings]) : LintNameCasePatternScan
  (lint-name-case-pattern-list-at (& patterns) source cursor limit findings 0))

(define (lint-name-case-pattern-list-at
  [patterns : (& patterns ast.AstPatternList)]
  [source : (& source str)]
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
          source
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
  [source : (& source str)]
  [cursor : i64]
  [limit : i64]
  [findings : LintFindings]) : LintNameCasePatternScan
  (match pattern
    [(Var name _)
      (lint-name-case-pattern-add
        source
        (ci.intern-str name)
        cursor
        limit
        findings
        true)]
    [(Binding name)
      (lint-name-case-pattern-add
        source
        (ci.intern-str name)
        cursor
        limit
        findings
        true)]
    [(Tuple items)
      (lint-name-case-pattern-list (deref items) source cursor limit findings)]
    [(Array items)
      (lint-name-case-pattern-list (deref items) source cursor limit findings)]
    [(Slice items _)
      (lint-name-case-pattern-list (deref items) source cursor limit findings)]
    [(Variant name items)
      (let
        [variant : LintNameCasePatternScan
          (lint-name-case-pattern-add
            source
            (ci.intern-str name)
            cursor
            limit
            findings
            false)]
        (lint-name-case-pattern-list
          (deref items)
          source
          variant.next-index
          limit
          variant.findings))]
    [(Wildcard) (LintNameCasePatternScan findings cursor)]
    [(Literal _) (LintNameCasePatternScan findings cursor)]))

;; A bare match-arm symbol is syntactically ambiguous until typechecking: it
;; may be a nullary enum variant. Skip that root spelling, while constructor
;; payload patterns and nested tuple positions remain definite binder slots.
(define (lint-name-case-match-pattern
  [pattern : ast.AstPattern]
  [source : (& source str)]
  [cursor : i64]
  [limit : i64]
  [findings : LintFindings]) : LintNameCasePatternScan
  (match (owned_view.compiler-owned-shared-view pattern)
    [(Binding name)
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

(define (lint-name-case-skip-space-comments
  [source : (& source str)]
  [start : i64]) : i64
  (let
    [n : i64 (string.string-length source)]
    [index : i64 start]
    [again : bool true]
    (while (and again (< index n))
      (set! again false)
      (while (and
        (< index n)
        (lint-name-case-space? (string.string-ref source index)))
        (set! index (+ index 1)))
      (when
        (and (< index n) (= (string.string-ref source index) ';'))
        (while (and (< index n) (not (= (string.string-ref source index) '\n')))
          (set! index (+ index 1)))
        (set! again true)))
    index))

(define (lint-name-case-skip-line [source : (& source str)] [start : i64]) : i64
  (let
    [n : i64 (string.string-length source)]
    [index : i64 start]
    (while (and (< index n) (not (= (string.string-ref source index) '\n')))
      (set! index (+ index 1)))
    index))

(define (lint-name-case-skip-quoted
  [source : (& source str)]
  [start : i64]
  [delimiter : char]) : i64
  (let
    [n : i64 (string.string-length source)]
    [index : i64 (+ start 1)]
    [done : bool false]
    (while (and (< index n) (not done))
      (let
        [c : char (string.string-ref source index)]
        (cond
          [(= c '\\') (set! index (+ index 2))]
          [(= c delimiter)
            (set! index (+ index 1))
            (set! done true)]
          [else (set! index (+ index 1))])))
    index))

;; Find a form head in source code, excluding text in comments and literals.
(define (lint-name-case-find-code-prefix-from
  [source : (& source str)]
  [needle : (& needle str)]
  [start : i64]) : i64
  (let
    [n : i64 (string.string-length source)]
    [index : i64 start]
    [found : i64 (- 0 1)]
    (while (and (< found 0) (< index n))
      (let
        [c : char (string.string-ref source index)]
        (cond
          [(= c ';') (set! index (lint-name-case-skip-line source index))]
          [(= c '"') (set! index (lint-name-case-skip-quoted source index '"'))]
          [(= c '\'')
            (set! index (lint-name-case-skip-quoted source index '\''))]
          [(lint-source-prefix-at? source index needle) (set! found index)]
          [else (set! index (+ index 1))])))
    found))

(define (lint-name-case-find-decl-name-from
  [source : (& source str)]
  [cursor : i64]
  [form : String]
  [name : (& name str)]
  [function-head : bool]) : LintSourceNameSpan
  (let
    [needle : String (str_cat.str-cat "(" form)]
    [n : i64 (string.string-length source)]
    [search : i64 cursor]
    [found : i64 (- 0 1)]
    (while (and (< found 0) (< search n))
      (let
        [form-index : i64
          (lint-name-case-find-code-prefix-from source needle search)]
        (if (< form-index 0)
          (set! search n)
          (let
            [after-form : i64
              (lint-name-case-skip-space-comments
                source
                (+ form-index (string.string-length needle)))]
            [name-index : i64
              (if function-head
                (if (and
                  (< after-form n)
                  (= (string.string-ref source after-form) '('))
                  (lint-name-case-skip-space-comments source (+ after-form 1))
                  (- 0 1))
                (if (and
                  (< after-form n)
                  (= (string.string-ref source after-form) '('))
                  (- 0 1)
                  after-form))]
            (if (and
              (>= name-index 0)
              (lint-source-name-at? source name-index name))
              (set! found name-index)
              (set! search (+ form-index 1)))))))
    (if (< found 0)
      (LintSourceNameSpan (lint-no-span) cursor)
      (LintSourceNameSpan
        (lint-source-index-span
          found
          (string.string-length name)
          (lint-no-span))
        (+ found (string.string-length name))))))

(define (lint-name-case-decl-state-add
  [state : LintNameCaseDeclState]
  [form : String]
  [name : String]
  [function-head : bool]
  [kind : i64]) : LintNameCaseDeclState
  (let
    [found : LintSourceNameSpan
      (lint-name-case-find-decl-name-from
        state.source
        state.cursor
        form
        name
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
          (owned_view.compiler-owned-shared-view state.findings)))]
    (LintNameCaseDeclState state.source found.next-index next)))

(define (lint-name-case-decl-state-after-body
  [state : LintNameCaseDeclState]
  [body : i64]) : LintNameCaseDeclState
  (let
    [end : i64
      (lint-source-span-end-index state.source (lint-no-effect-span-id body))]
    (if (> end state.cursor)
      (LintNameCaseDeclState state.source end state.findings)
      state)))

(define (lint-name-case-in-decl
  [decl : ast.AstDecl]
  [state : LintNameCaseDeclState]) : LintNameCaseDeclState
  (match decl
    [(Def decl-meta name _ body)
      (lint-name-case-decl-state-after-body
        (lint-name-case-decl-state-add
          state
          "define"
          (ci.intern-str name)
          false
          0)
        body)]
    [(DefFn decl-meta name _ _ body _)
      (lint-name-case-decl-state-after-body
        (lint-name-case-decl-state-add
          state
          "define"
          (ci.intern-str name)
          true
          1)
        body)]
    [(DefMacro decl-meta name _ _ body)
      (lint-name-case-decl-state-after-body
        (lint-name-case-decl-state-add
          state
          "defmacro"
          (ci.intern-str name)
          true
          1)
        body)]
    [(DefDispatch decl-meta name _)
      (lint-name-case-decl-state-add
        state
        "defdispatch"
        (ci.intern-str name)
        false
        1)]
    [(DefStruct decl-meta name _ _ _)
      (lint-name-case-decl-state-add
        state
        "defstruct"
        (ci.intern-str name)
        false
        2)]
    [(DefStructLifetimes decl-meta name _ _ _ _)
      (lint-name-case-decl-state-add
        state
        "defstruct"
        (ci.intern-str name)
        false
        2)]
    [(DefEnum decl-meta name _ _)
      (lint-name-case-decl-state-add
        state
        "defenum"
        (ci.intern-str name)
        false
        2)]
    [(DefEnumLifetimes decl-meta name _ _ _)
      (lint-name-case-decl-state-add
        state
        "defenum"
        (ci.intern-str name)
        false
        2)]
    [(ModuleBody _ body)
      (lint-name-case-in-decl-list
        (ast.ast-decl-list-box-shared-view body)
        state)]
    [(Unsafe inner)
      (lint-name-case-in-decl (ast.ast-decl-box-shared-view inner) state)]
    [_ state]))

(define (lint-name-case-in-decl-list
  [decls : ast.AstDeclList]
  [state : LintNameCaseDeclState]) : LintNameCaseDeclState
  (match (ast.ast-decl-list-step decls)
    [(Nil) state]
    [(Cons decl rest)
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
  [name : (& name str)]
  [module-name : (& module-name str)]
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

(define (lint-redundant-function-name?
  [module-name : (& module-name str)]
  [name : (& name str)]) : bool
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
  [fallback : ast.AstSourceSpan]) : LintRedundantFunctionNameState
  (let
    [module-name : String state.module-name]
    (if (lint-redundant-function-name? module-name name)
      (let
        [found : LintSourceNameSpan
          (lint-source-name-span-from state.source name state.cursor fallback)]
        (lint-redundant-function-name-state-with-results
          (owned_view.compiler-owned-shared-view state)
          found.next-index
          (lint-findings-add
            (lint-redundant-function-name-finding module-name name found.span)
            state.findings)))
      state)))

(define (lint-redundant-function-name-callee [expr : ast.AstExpr]) : String
  (match (ast.ast-expr-unspan expr)
    [(Var name) (ci.intern-str name)]
    [_ ""]))

(define (lint-redundant-function-name-generated-head
  [args : (& args ast.AstExprList)]) : String
  (if (= args.len 0)
    ""
    (match (ast.ast-expr-unspan
      (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0)))
      [(Call fn-head _)
        (lint-redundant-function-name-callee (ast.ast-node-get fn-head))]
      [_ ""])))

(define (lint-redundant-function-name-literal-module
  [args : (& args ast.AstExprList)]) : String
  (if (= args.len 0)
    ""
    (match (ast.ast-expr-unspan
      (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0)))
      [(Var name) (lint-module-default-alias (ci.intern-str name))]
      [_ ""])))

(define (lint-redundant-function-name-quoted-expr-list
  [exprs : (& exprs ast.AstExprList)]
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
          (lint-redundant-function-name-literal-module args)]
        (if (string.eq module-name "")
          (lint-redundant-function-name-quoted-expr-list args state)
          (lint-redundant-function-name-quoted-expr-list
            args
            (lint-redundant-function-name-state-with-module state module-name))))]
    [(or (string.eq callee "define") (string.eq callee "defmacro"))
      (lint-redundant-function-name-quoted-expr-list
        args
        (lint-redundant-function-name-add
          state
          (lint-redundant-function-name-generated-head args)
          span))]
    [else (lint-redundant-function-name-quoted-expr-list args state)]))

(define (lint-redundant-function-name-quoted-expr
  [expr : ast.AstExpr]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match expr
    [(Spanned inner span)
      (match (ast.ast-node-get inner)
        [(Call func args)
          (lint-redundant-function-name-quoted-call
            (lint-redundant-function-name-callee (ast.ast-node-get func))
            args
            span
            state)]
        [_
          (lint-redundant-function-name-quoted-expr
            (ast.ast-node-get inner)
            state)])]
    [(Call func args)
      (lint-redundant-function-name-quoted-call
        (lint-redundant-function-name-callee (ast.ast-node-get func))
        args
        (lint-no-span)
        state)]
    [(Begin exprs) (lint-redundant-function-name-quoted-expr-list exprs state)]
    [(Unsafe exprs) (lint-redundant-function-name-quoted-expr-list exprs state)]
    [(If cond then-branch else-branch)
      (lint-redundant-function-name-quoted-expr
        (ast.ast-node-get else-branch)
        (lint-redundant-function-name-quoted-expr
          (ast.ast-node-get then-branch)
          (lint-redundant-function-name-quoted-expr
            (ast.ast-node-get cond)
            state)))]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let _ body)
          (lint-redundant-function-name-quoted-expr
            (ast.ast-node-get body)
            state)])]
    [(Quote inner)
      (lint-redundant-function-name-quoted-expr (ast.ast-node-get inner) state)]
    [(Quasiquote inner)
      (lint-redundant-function-name-quoted-expr (ast.ast-node-get inner) state)]
    [(Unquote _) state]
    [(UnquoteSplicing _) state]
    [_ state]))

(define (lint-redundant-function-name-macro-expr
  [expr : ast.AstExpr]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match expr
    [(Spanned inner _)
      (lint-redundant-function-name-macro-expr (ast.ast-node-get inner) state)]
    [(Quote inner)
      (lint-redundant-function-name-quoted-expr (ast.ast-node-get inner) state)]
    [(Quasiquote inner)
      (lint-redundant-function-name-quoted-expr (ast.ast-node-get inner) state)]
    [(Call func args)
      (lint-redundant-function-name-macro-expr-list
        args
        (lint-redundant-function-name-macro-expr (ast.ast-node-get func) state))]
    [(If cond then-branch else-branch)
      (lint-redundant-function-name-macro-expr
        (ast.ast-node-get else-branch)
        (lint-redundant-function-name-macro-expr
          (ast.ast-node-get then-branch)
          (lint-redundant-function-name-macro-expr
            (ast.ast-node-get cond)
            state)))]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body)
          (lint-redundant-function-name-macro-expr
            (ast.ast-node-get body)
            (lint-redundant-function-name-macro-let-bindings bindings state))])]
    [(Begin exprs) (lint-redundant-function-name-macro-expr-list exprs state)]
    [(Unsafe exprs) (lint-redundant-function-name-macro-expr-list exprs state)]
    [(Match match-box)
      (match (__tl-box-place match-box)
        [(Match scrutinee arms)
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
      [(Binding _ _ init)
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
      [(Arm _ body)
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
    [(Module name)
      (lint-redundant-function-name-state-with-module
        state
        (lint-module-default-alias (ci.intern-str name)))]
    [(DefFn decl-meta name _ _ body _)
      (lint-redundant-function-name-add
        state
        (ci.intern-qualified-base name)
        (lint-no-effect-span-id body))]
    [(DefMacro decl-meta name _ _ body)
      (lint-redundant-function-name-macro-expr
        (ast.ast-node-get body)
        (lint-redundant-function-name-add
          state
          (ci.intern-qualified-base name)
          (lint-no-effect-span-id body)))]
    [(Unsafe inner) (lint-redundant-function-name-decl (deref inner) state)]
    [_ state]))

(define (lint-redundant-function-names-in-decl-list-state
  [decls : ast.AstDeclList]
  [state : LintRedundantFunctionNameState]) : LintRedundantFunctionNameState
  (match (ast.ast-decl-list-step decls)
    [(Nil) state]
    [(Cons decl rest)
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
    [(Program decls-box)
      (lint-redundant-function-names-in-decl-list
        source
        (ast.ast-decl-list-box-shared-view decls-box)
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
    (if (< n (array-length slots))
      unit
      (let
        [bigger : (__tl_dyn-array LintUnusedVariableBinding)
          (__tl_make-array
            LintUnusedVariableBinding
            (lint-grown-capacity (array-length slots)))]
        [index : i64 0]
        (while (< index n)
          (set! (array-ref bigger index) (array-ref slots index))
          (set! index (+ index 1)))
        (set! slots bigger)))
    (set! (array-ref slots n) binding)
    (LintUnusedVariableBindingList slots (+ n 1))))

(define (lint-unused-variable-frame-push
  [frames : LintUnusedVariableFrameList]
  [bindings : LintUnusedVariableBindingList]) : LintUnusedVariableFrameList
  (let
    [n : i64 frames.len]
    [slots : (__tl_dyn-array LintUnusedVariableBindingList) frames.slots]
    (if (< n (array-length slots))
      unit
      (let
        [bigger : (__tl_dyn-array LintUnusedVariableBindingList)
          (__tl_make-array
            LintUnusedVariableBindingList
            (lint-grown-capacity (array-length slots)))]
        [index : i64 0]
        (while (< index n)
          (set! (array-ref bigger index) (array-ref slots index))
          (set! index (+ index 1)))
        (set! slots bigger)))
    (set! (array-ref slots n) bindings)
    (LintUnusedVariableFrameList slots (+ n 1))))

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
  [bindings : (& bindings LintUnusedVariableBindingList)]
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
  [bindings : (& bindings LintUnusedVariableBindingList)]) : LintUnusedVariableState
  (lint-unused-variable-add-binding-name-cases-at
    state
    bindings
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
      (lint-unused-variable-binding-index bindings name (- bindings.len 1))]
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

(define (lint-unused-variable-first-dot-index [text : (& text str)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [idx : i64 0]
    [found : i64 (- 0 1)]
    (while (and (< found 0) (< idx n))
      (if (= (string.string-ref text idx) '.')
        (set! found idx)
        (set! idx (+ idx 1))))
    found))

(define (lint-unused-variable-read-var-name
  [state : LintUnusedVariableState]
  [name : String]) : LintUnusedVariableState
  (let
    [with-full : LintUnusedVariableState
      (lint-unused-variable-read-name
        state
        (owned_view.compiler-owned-shared-view name))]
    [dot : i64 (lint-unused-variable-first-dot-index name)]
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
  [bindings : (& bindings LintUnusedVariableBindingList)]
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
  (lint-unused-variable-report-bindings-at bindings findings (- bindings.len 1)))

(define (lint-unused-variable-pop-frame [state : LintUnusedVariableState]) : LintUnusedVariableState
  (let
    [frames : LintUnusedVariableFrameList
      (owned_view.compiler-owned-shared-view state.frames)]
    [top : i64 (- frames.len 1)]
    (if (< top 0)
      state
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
            (owned_view.compiler-owned-shared-view state.findings))
          state.findings)))))

(define (lint-unused-variable-param-bindings
  [params : (& params ast.AstParamList)]
  [source : (& source str)]
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
;; slot order is reversed: the first param ends up in the last slot, where the
;; counting-down walks see it first.
(define (lint-unused-variable-param-bindings-at
  [params : (& params ast.AstParamList)]
  [source : (& source str)]
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
      [(Param name ty is-comptime)
        (let
          [text : String (ci.intern-str name)]
          [found : LintSourceNameSpan
            (lint-source-name-span-from source text cursor fallback)]
          (set!
            (array-ref slots (- (array-length slots) (+ index 1)))
            (lint-unused-variable-binding
              text
              found.span
              reportable
              (and
                is-comptime
                (match ty
                  [(Var type-name) (string.eq (ci.intern-str type-name) "type")]
                  [_ false]))))
          (lint-unused-variable-param-bindings-at
            params
            source
            found.next-index
            fallback
            reportable
            slots
            (+ index 1)))])))

(define (lint-unused-variable-macro-param-bindings
  [params : (& params ast.AstMacroParamList)]
  [source : (& source str)]
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
  [source : (& source str)]
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
      [(Param name ty _ _)
        (let
          [text : String (ci.intern-str name)]
          [found : LintSourceNameSpan
            (lint-source-name-span-from source text cursor fallback)]
          (set!
            (array-ref slots (- (array-length slots) (+ index 1)))
            (lint-unused-variable-binding
              text
              found.span
              reportable
              (match ty
                [(Var type-name) (string.eq (ci.intern-str type-name) "type")]
                [_ false])))
          (lint-unused-variable-macro-param-bindings-at
            params
            source
            found.next-index
            fallback
            reportable
            slots
            (+ index 1)))])))

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
    [(Func args ret)
      (lint-unused-variable-type
        (ast.ty-node-get ret)
        (lint-unused-variable-type-list
          (ast.ast-type-list-box-shared-view args)
          state))]
    [(CFunc signature _)
      (lint-unused-variable-type (ast.ty-node-get signature) state)]
    [(Tuple items)
      (lint-unused-variable-type-list
        (ast.ast-type-list-box-shared-view items)
        state)]
    [(Array elem _) (lint-unused-variable-type (ast.ty-node-get elem) state)]
    [(DynArray elem) (lint-unused-variable-type (ast.ty-node-get elem) state)]
    [(Box elem) (lint-unused-variable-type (ast.ty-node-get elem) state)]
    [(Region name inner) (lint-unused-variable-type-lifetime name inner state)]
    [(Invalidate name inner)
      (lint-unused-variable-type-lifetime name inner state)]
    [(Ref name inner) (lint-unused-variable-type-lifetime name inner state)]
    [(MutRef name inner) (lint-unused-variable-type-lifetime name inner state)]
    [(EnumArgs _ lifetimes)
      (lint-unused-variable-lifetime-list
        (ast.ast-lifetime-list-box-shared-view lifetimes)
        state)]
    [(StructArgs _ lifetimes)
      (lint-unused-variable-lifetime-list
        (ast.ast-lifetime-list-box-shared-view lifetimes)
        state)]
    [(Var name) (lint-unused-variable-read-id state name)]
    [(VarArgs name lifetimes)
      (lint-unused-variable-lifetime-list
        (ast.ast-lifetime-list-box-shared-view lifetimes)
        (lint-unused-variable-read-id state name))]
    [(Ptr elem) (lint-unused-variable-type (ast.ty-node-get elem) state)]
    [(MutPtr elem) (lint-unused-variable-type (ast.ty-node-get elem) state)]
    [_ state]))

(define (lint-unused-variable-maybe-type
  [maybe-ty : ast.AstMaybeType]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match maybe-ty
    [(No) state]
    [(Some ty) (lint-unused-variable-type ty state)]))

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
      [(Param _ ty _)
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
      [(Param _ ty _ _)
        (lint-unused-variable-macro-param-types-at
          params
          (lint-unused-variable-type ty state)
          (+ index 1))])))

(define (lint-unused-variable-borrow-lifetime
  [lifetime : ast.AstBorrowLifetime]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match lifetime
    [(Inferred) state]
    [(Named name) (lint-unused-variable-read-id state name)]))

(define (lint-unused-variable-pattern-bindings
  [pattern : ast.AstPattern]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (match pattern
    [(Var name maybe-ty)
      (lint-unused-variable-add-to-current-frame
        (lint-unused-variable-maybe-type maybe-ty state)
        (lint-unused-variable-binding
          (ci.intern-str name)
          (lint-no-span)
          false
          false))]
    [(Tuple items)
      (lint-unused-variable-pattern-list-bindings
        (ast.ast-pattern-list-box-shared-view items)
        state)]
    [(Array items)
      (lint-unused-variable-pattern-list-bindings
        (ast.ast-pattern-list-box-shared-view items)
        state)]
    [(Slice items _)
      (lint-unused-variable-pattern-list-bindings
        (ast.ast-pattern-list-box-shared-view items)
        state)]
    [(Wildcard) state]
    [(Binding name)
      (lint-unused-variable-add-to-current-frame
        state
        (lint-unused-variable-binding
          (ci.intern-str name)
          (lint-no-span)
          false
          false))]
    [(Variant _ items)
      (lint-unused-variable-pattern-list-bindings
        (ast.ast-pattern-list-box-shared-view items)
        state)]
    [(Literal _) state]))

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
        (ast.ast-expr-list-get exprs index 0)
        state
        (lint-no-span)))))

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
      [(Binding _ maybe-ty init)
        (lint-unused-variable-quasiquote-let-bindings-at
          bindings
          (lint-unused-variable-quasiquote-expr
            init
            (lint-unused-variable-maybe-type maybe-ty state))
          (+ index 1))])))

;; Walk a template node's expression children as template syntax and its
;; type-id children for the type bindings they name, in payload order; its
;; inline type and pattern children are not walked.
(define (lint-unused-variable-quasiquote-children-at
  [children : (& children ast.AstExprChildList)]
  [index : i64]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  (if (>= index children.len)
    state
    (lint-unused-variable-quasiquote-children-at
      children
      (+ index 1)
      (match (ast.ast-expr-child-list-get
        children
        index
        (ast.ast-expr-child-fallback))
        [(Expr id) (lint-unused-variable-quasiquote-expr id state)]
        [(TypeId id) (lint-unused-variable-type (ast.ty-node-get id) state)]
        [_ state]))))

(define (lint-unused-variable-quasiquote-expr
  [node-id : i64]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  ;; The arms below walk unquoted code as code, skip nested quoted syntax and
  ;; walk a type operand before its expression; every other variant's
  ;; expression and type-id children are walked through the AstExpr child
  ;; list. Quoted type operands substitute type bindings during macro
  ;; expansion.
  (match (ast.ast-node-get node-id)
    [(Unquote inner)
      (lint-unused-variable-expr inner state (lint-no-effect-span-id inner))]
    [(UnquoteSplicing inner)
      (lint-unused-variable-expr inner state (lint-no-effect-span-id inner))]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body)
          (lint-unused-variable-quasiquote-expr
            body
            (lint-unused-variable-quasiquote-let-bindings bindings state))])]
    [(Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(Lambda params ret body)
          (lint-unused-variable-quasiquote-expr
            body
            (lint-unused-variable-maybe-type
              ret
              (lint-unused-variable-param-types params state)))])]
    [(Ann inner ty-id)
      (lint-unused-variable-quasiquote-expr
        inner
        (lint-unused-variable-type (ast.ty-node-get ty-id) state))]
    [(Cast inner ty-id)
      (lint-unused-variable-quasiquote-expr
        inner
        (lint-unused-variable-type (ast.ty-node-get ty-id) state))]
    [(PtrCast ptr ty-id)
      (lint-unused-variable-quasiquote-expr
        ptr
        (lint-unused-variable-type (ast.ty-node-get ty-id) state))]
    [(IntToPtr value ty-id)
      (lint-unused-variable-quasiquote-expr
        value
        (lint-unused-variable-type (ast.ty-node-get ty-id) state))]
    [(MacroExpansion _ _ _) state]
    [(Quote _) state]
    [(Quasiquote _) state]
    [(ForOwnedState _) state]
    [(ForOwnedStep _) state]
    [_
      (let
        [children : ast.AstExprChildList
          (ast.ast-expr-children (ast.ast-node-get node-id))]
        (lint-unused-variable-quasiquote-children-at (& children) 0 state))]))

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
      [(Binding name maybe-ty init)
        (let
          [after-ty : LintUnusedVariableState
            (lint-unused-variable-maybe-type
              maybe-ty
              (owned_view.compiler-owned-shared-view state))]
          [after-init : LintUnusedVariableState
            (lint-unused-variable-expr
              init
              after-ty
              (lint-no-effect-span-id init))]
          [text : String (ci.intern-str name)]
          [found : LintSourceNameSpan
            (lint-source-name-span-from
              state.source
              text
              cursor
              (lint-no-effect-span-id init))]
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
  [body : i64]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [cursor : i64
      (let
        [start : i64 (lint-source-span-start-index state.source span)]
        (if (< start 0)
          0
          start))]
    [with-frame : LintUnusedVariableState
      (lint-unused-variable-push-frame
        state
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
      [(Binding name init cleanup _)
        (let
          [text : String (ci.intern-str name)]
          [init-span : ast.AstSourceSpan (lint-no-effect-span-id init)]
          [cleanup-span : ast.AstSourceSpan (lint-no-effect-span-id cleanup)]
          [init-start : i64
            (lint-source-span-start-index state.source init-span)]
          [found : LintSourceNameSpan
            (lint-source-name-span-between
              state.source
              text
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
              cleanup
              (lint-unused-variable-expr init with-case init-span)
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
    [start : i64 (lint-source-span-start-index state.source span)]
    (lint-unused-variable-match-arms-at
      (& arms)
      state
      (if (< start 0)
        0
        start)
      0)))

(define (lint-match-body-source-id [body : i64]) : i64
  (match (ast.ast-node-get body)
    [(Spanned inner-box _)
      (match (ast.ast-node-get inner-box)
        [(Spanned _ _) inner-box]
        [_ body])]
    [_ body]))

(define (lint-unused-variable-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [state : LintUnusedVariableState]
  [cursor : i64]
  [index : i64]) : LintUnusedVariableState
  (if (>= index arms.len)
    state
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(Arm pattern body)
        (let
          [body-source-id : i64 (lint-match-body-source-id body)]
          [body-span : ast.AstSourceSpan
            (lint-no-effect-span-id body-source-id)]
          [body-start : i64
            (lint-source-span-start-index state.source body-span)]
          [scanned : LintNameCasePatternScan
            (if state.name-case
              (lint-name-case-match-pattern
                (owned_view.compiler-owned-shared-view pattern)
                state.source
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
            (lint-unused-variable-pattern-bindings pattern with-frame)]
          [with-body : LintUnusedVariableState
            (lint-unused-variable-expr body-source-id with-pattern body-span)]
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
  [body : i64]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [start : i64 (lint-source-span-start-index state.source span)]
    [cursor : i64
      (if (< start 0)
        0
        (+ start (string.string-length "(lambda")))]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-param-bindings params state.source cursor span true)]
    [with-cases : LintUnusedVariableState
      (lint-unused-variable-add-binding-name-cases state built.bindings)]
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
  [body : i64]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [with-frame : LintUnusedVariableState
      (lint-unused-variable-push-frame
        state
        (lint-unused-variable-binding-push
          (lint-unused-variable-bindings-empty)
          (lint-unused-variable-binding (ci.intern-str name) span false false)))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-frame span)]
    (lint-unused-variable-pop-frame with-body)))

(define (lint-unused-variable-scan-body-scope
  [index : i64]
  [prefix : i64]
  [body : i64]
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

(define (lint-unused-variable-compact-scope
  [index : i64]
  [slot : i64]
  [keep : i64]
  [body : i64]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [with-index : LintUnusedVariableState
      (lint-unused-variable-push-frame
        state
        (lint-unused-variable-binding-push
          (lint-unused-variable-bindings-empty)
          (lint-unused-variable-binding (ci.intern-str index) span false false)))]
    [with-keep : LintUnusedVariableState
      (lint-unused-variable-expr keep with-index span)]
    [with-slot : LintUnusedVariableState
      (lint-unused-variable-push-frame
        with-keep
        (lint-unused-variable-binding-push
          (lint-unused-variable-bindings-empty)
          (lint-unused-variable-binding (ci.intern-str slot) span false false)))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-slot span)]
    (lint-unused-variable-pop-frame (lint-unused-variable-pop-frame with-body))))

;; Walk a node's expression children under the enclosing span and its type-id
;; children, in payload order. The variants with inline type or pattern
;; children have their own arms.
(define (lint-unused-variable-children-at
  [children : (& children ast.AstExprChildList)]
  [index : i64]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (if (>= index children.len)
    state
    (lint-unused-variable-children-at
      children
      (+ index 1)
      (match (ast.ast-expr-child-list-get
        children
        index
        (ast.ast-expr-child-fallback))
        [(Expr id) (lint-unused-variable-expr id state span)]
        [(TypeId id) (lint-unused-variable-type (ast.ty-node-get id) state)]
        [_ state])
      span)))

(define (lint-unused-variable-children
  [node-id : i64]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [children : ast.AstExprChildList
      (ast.ast-expr-children (ast.ast-node-get node-id))]
    (lint-unused-variable-children-at (& children) 0 state span)))

(define (lint-unused-variable-expr
  [node-id : i64]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  ;; The arms below read names, open binding scopes, walk list items without
  ;; an enclosing span, track unsafe blocks and walk quoted syntax as a
  ;; template; every other variant's expression and type-id children are
  ;; walked through the AstExpr child list.
  (match (ast.ast-node-get node-id)
    [(Spanned inner inner-span)
      (lint-unused-variable-expr inner state inner-span)]
    [(Var name)
      (lint-unused-unsafe-note-value-name! state (ci.intern-str name))
      (lint-unused-variable-read-var-id state name)]
    [(Call func args)
      (lint-unused-unsafe-note-call-target! state (ast.ast-node-get func))
      (lint-unused-variable-expr-list
        args
        (lint-unused-variable-expr func state span))]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body)
          (lint-unused-variable-let bindings body state span)])]
    [(Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(Lambda params ret body)
          (lint-unused-variable-lambda params ret body state span)])]
    [(Tuple exprs) (lint-unused-variable-expr-list exprs state)]
    [(Array exprs) (lint-unused-variable-expr-list exprs state)]
    [(DynArray exprs) (lint-unused-variable-expr-list exprs state)]
    [(ForOwnedState payload)
      (lint-unused-variable-expr
        (ast.ast-for-owned-state-body (& payload))
        (lint-unused-variable-expr
          (ast.ast-for-owned-state-source (& payload))
          state
          span)
        span)]
    [(ForOwnedStep payload)
      (let
        [source : i64 (ast.ast-for-owned-step-source-name (& payload))]
        [index : i64 (ast.ast-for-owned-step-index-name (& payload))]
        [binding : i64 (ast.ast-for-owned-step-binding-name (& payload))]
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        [done : i64 (ast.ast-for-owned-step-done-name (& payload))]
        [body : i64 (ast.ast-for-owned-step-body (& payload))]
        [read-state : LintUnusedVariableState
          (lint-unused-variable-expr
            done
            (if (>= expected-type 0)
              (lint-unused-variable-expr
                expected-type
                (lint-unused-variable-expr
                  index
                  (lint-unused-variable-expr source state span)
                  span)
                span)
              (lint-unused-variable-expr
                index
                (lint-unused-variable-expr source state span)
                span))
            span)]
        (match (ast.ast-expr-unspan (ast.ast-node-get binding))
          [(Var name)
            (lint-unused-variable-index-scope name body read-state span)]
          [_ (lint-unused-variable-expr body read-state span)]))]
    [(Begin exprs) (lint-unused-variable-expr-list exprs state)]
    [(Unsafe exprs)
      (lint-unused-unsafe-block-push!
        span
        (lint-expr-list-requires-enclosing-unsafe? exprs))
      (lint-unused-unsafe-finish-state
        (lint-unused-variable-expr-list exprs state))]
    [(Cast _ _)
      (lint-unused-unsafe-block-mark-unknown!)
      (lint-unused-variable-children node-id state span)]
    ;; A `deref` needs unsafe only through a raw pointer, which takes types.
    [(BoxTake _)
      (lint-unused-unsafe-block-mark-unknown!)
      (lint-unused-variable-children node-id state span)]
    [(Borrow _ lifetime-id _)
      (lint-unused-variable-children
        node-id
        (lint-unused-variable-borrow-lifetime
          (ast.ast-borrow-lifetime-from-id lifetime-id)
          state)
        span)]
    [(Match match-box)
      (match (__tl-box-place match-box)
        [(Match scrutinee arms)
          (lint-unused-variable-match-arms
            arms
            (lint-unused-variable-expr scrutinee state span)
            span)])]
    [(Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(Foreach index index-ty start end body)
          (let
            [scanned : LintNameCaseLocalScan
              (if state.name-case
                (lint-unused-variable-scan-form-local-name
                  state
                  (ci.intern-str index)
                  span
                  "(foreach")
                (LintNameCaseLocalScan state 0))]
            (lint-unused-variable-index-scope
              index
              body
              (lint-unused-variable-type
                index-ty
                (lint-unused-variable-expr
                  end
                  (lint-unused-variable-expr start scanned.state span)
                  span))
              span))]
        [(Foreach2 outer outer-ty a b inner inner-ty c d body)
          (let
            [outer-scan : LintNameCaseLocalScan
              (if state.name-case
                (lint-unused-variable-scan-form-local-name
                  (owned_view.compiler-owned-shared-view state)
                  (ci.intern-str outer)
                  span
                  "(foreach")
                (LintNameCaseLocalScan
                  (owned_view.compiler-owned-shared-view state)
                  0))]
            [inner-scan : LintNameCaseLocalScan
              (if state.name-case
                (let
                  [limit : i64 (lint-source-span-end-index state.source span)]
                  (lint-unused-variable-scan-local-name
                    outer-scan.state
                    (ci.intern-str inner)
                    outer-scan.next-index
                    (if (< limit 0)
                      (string.string-length state.source)
                      limit)))
                (LintNameCaseLocalScan outer-scan.state 0))]
            (lint-unused-variable-scan-body-scope
              inner
              outer
              body
              (lint-unused-variable-type
                inner-ty
                (lint-unused-variable-type
                  outer-ty
                  (lint-unused-variable-expr
                    d
                    (lint-unused-variable-expr
                      c
                      (lint-unused-variable-expr
                        b
                        (lint-unused-variable-expr a inner-scan.state span)
                        span)
                      span)
                    span)))
              span))])]
    [(SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(Reduce _ index index-ty start end init value)
          (let
            [scanned : LintNameCaseLocalScan
              (if state.name-case
                (lint-unused-variable-scan-form-local-name
                  state
                  (ci.intern-str index)
                  span
                  "(spmd-reduce")
                (LintNameCaseLocalScan state 0))]
            (lint-unused-variable-index-scope
              index
              value
              (lint-unused-variable-type
                index-ty
                (lint-unused-variable-expr
                  init
                  (lint-unused-variable-expr
                    end
                    (lint-unused-variable-expr start scanned.state span)
                    span)
                  span))
              span))])]
    [(SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(Scan _ index index-ty start end prefix prefix-ty init value body)
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
                  [limit : i64 (lint-source-span-end-index state.source span)]
                  (lint-unused-variable-scan-local-name
                    index-scan.state
                    (ci.intern-str prefix)
                    index-scan.next-index
                    (if (< limit 0)
                      (string.string-length state.source)
                      limit)))
                (LintNameCaseLocalScan index-scan.state 0))]
            [base-state : LintUnusedVariableState
              (lint-unused-variable-type
                prefix-ty
                (lint-unused-variable-type
                  index-ty
                  (lint-unused-variable-expr
                    init
                    (lint-unused-variable-expr
                      end
                      (lint-unused-variable-expr start prefix-scan.state span)
                      span)
                    span)))]
            [value-state : LintUnusedVariableState
              (lint-unused-variable-index-scope index value base-state span)]
            (lint-unused-variable-scan-body-scope
              index
              prefix
              body
              value-state
              span))])]
    [(SpmdCompact compact-box)
      (match (__tl-box-place compact-box)
        [(Compact index index-ty start end slot slot-ty init keep body)
          (let
            [index-scan : LintNameCaseLocalScan
              (if state.name-case
                (lint-unused-variable-scan-form-local-name
                  (owned_view.compiler-owned-shared-view state)
                  (ci.intern-str index)
                  span
                  "(spmd-compact")
                (LintNameCaseLocalScan
                  (owned_view.compiler-owned-shared-view state)
                  0))]
            [slot-scan : LintNameCaseLocalScan
              (if state.name-case
                (let
                  [limit : i64 (lint-source-span-end-index state.source span)]
                  (lint-unused-variable-scan-local-name
                    index-scan.state
                    (ci.intern-str slot)
                    index-scan.next-index
                    (if (< limit 0)
                      (string.string-length state.source)
                      limit)))
                (LintNameCaseLocalScan index-scan.state 0))]
            [base-state : LintUnusedVariableState
              (lint-unused-variable-type
                slot-ty
                (lint-unused-variable-type
                  index-ty
                  (lint-unused-variable-expr
                    init
                    (lint-unused-variable-expr
                      end
                      (lint-unused-variable-expr start slot-scan.state span)
                      span)
                    span)))]
            (lint-unused-variable-compact-scope
              index
              slot
              keep
              body
              base-state
              span))])]
    [(WithRegion _ body) (lint-unused-variable-expr-list body state)]
    [(WithEscape scratch body)
      (lint-unused-variable-expr-list
        body
        (lint-unused-variable-expr scratch state span))]
    [(WithScratch body) (lint-unused-variable-expr-list body state)]
    [(InArena arena body)
      (lint-unused-variable-expr-list
        body
        (lint-unused-variable-expr arena state span))]
    [(WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(WithResource bindings body)
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
    [(Quote _) state]
    [(Quasiquote inner) (lint-unused-variable-quasiquote-expr inner state)]
    [(BracketClause items) (lint-unused-variable-expr-list items state)]
    [(ProgramArgv)
      (lint-unused-unsafe-block-mark-unknown!)
      state]
    [(ProgramEnvp)
      (lint-unused-unsafe-block-mark-unknown!)
      state]
    [(Syscall args) (lint-unused-variable-expr-list args state)]
    [(ForeachActive lane body)
      (let
        [scanned : LintNameCaseLocalScan
          (if state.name-case
            (lint-unused-variable-scan-form-local-name
              state
              (ci.intern-str lane)
              span
              "(foreach-active")
            (LintNameCaseLocalScan state 0))]
        (lint-unused-variable-index-scope lane body scanned.state span))]
    [_ (lint-unused-variable-children node-id state span)]))

(define (lint-unused-variable-decl-param-cursor
  [source : (& source str)]
  [prefix : String]
  [name : String]
  [fallback : ast.AstSourceSpan]) : i64
  (let
    [needle : String (str_cat.str-cat prefix name)]
    [fallback-start : i64 (lint-source-span-start-index source fallback)]
    [found : i64 (- 0 1)]
    [cursor : i64 fallback-start]
    ;; The body span is inside this declaration. Searching backward finds the
    ;; nearest declaration head in work proportional to its signature; a
    ;; forward scan would restart at byte zero for every declaration.
    (while (and (< found 0) (>= cursor 0))
      (let
        [candidate : i64
          (lint-source-find-prefix-backward-from source needle cursor)]
        (if (< candidate 0)
          (set! cursor (- 0 1))
          (let
            [end : i64 (+ candidate (string.string-length needle))]
            (if (lint-source-symbol-boundary? source end)
              (set! found candidate)
              (set! cursor (- candidate 1)))))))
    (if (< found 0)
      (if (< fallback-start 0)
        0
        fallback-start)
      (+ found (string.string-length needle)))))

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
    [body-span : ast.AstSourceSpan (lint-no-effect-span-id body)]
    [cursor : i64
      (lint-unused-variable-decl-param-cursor
        source
        prefix
        (ci.intern-str name)
        body-span)]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-param-bindings params source cursor body-span true)]
    [base-state : LintUnusedVariableState
      (LintUnusedVariableState
        source
        (lint-unused-variable-frames-empty)
        acc
        name-case
        report-unused)]
    [with-cases : LintUnusedVariableState
      (lint-unused-variable-add-binding-name-cases base-state built.bindings)]
    [state : LintUnusedVariableState
      (lint-unused-variable-push-frame with-cases built.bindings)]
    [with-param-types : LintUnusedVariableState
      (lint-unused-variable-type
        ret
        (lint-unused-variable-param-types params state))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-param-types body-span)]
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
    [body-span : ast.AstSourceSpan (lint-no-effect-span-id body)]
    [cursor : i64
      (lint-unused-variable-decl-param-cursor
        source
        prefix
        (ci.intern-str name)
        body-span)]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-macro-param-bindings
        params
        source
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
      (lint-unused-variable-add-binding-name-cases base-state built.bindings)]
    [state : LintUnusedVariableState
      (lint-unused-variable-push-frame with-cases built.bindings)]
    [with-param-types : LintUnusedVariableState
      (lint-unused-variable-type
        ret
        (lint-unused-variable-macro-param-types params state))]
    [with-body : LintUnusedVariableState
      (lint-unused-variable-expr body with-param-types body-span)]
    (__tl-project-field (lint-unused-variable-pop-frame with-body) findings)))

(define (lint-unused-variables-in-decl
  [source : String]
  [decl : ast.AstDecl]
  [acc : LintFindings]
  [name-case : bool]
  [report-unused : bool]) : LintFindings
  (match decl
    [(Def decl-meta _ maybe-ty body)
      (__tl-project-field
        (lint-unused-variable-expr
          body
          (lint-unused-variable-maybe-type
            maybe-ty
            (LintUnusedVariableState
              source
              (lint-unused-variable-frames-empty)
              acc
              name-case
              report-unused))
          (lint-no-effect-span-id body))
        findings)]
    [(DefFn decl-meta name params ret body _)
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
    [(DefMacro decl-meta name params ret body)
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
    [(Test _ body _ _)
      (__tl-project-field
        (lint-unused-variable-expr
          body
          (LintUnusedVariableState
            source
            (lint-unused-variable-frames-empty)
            acc
            name-case
            report-unused)
          (lint-no-effect-span-id body))
        findings)]
    [(Unsafe inner)
      (lint-unused-variables-in-decl
        source
        (ast.ast-decl-box-shared-view inner)
        acc
        name-case
        report-unused)]
    [(ModuleBody _ body)
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
    [(Nil) acc]
    [(Cons decl rest)
      (lint-unused-variables-in-decl-list
        (owned_view.compiler-owned-shared-view source)
        rest
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
      [head-id : i64 (ast.ast-expr-list-get exprs index 0)]
      [head : ast.AstExpr (ast.ast-node-get head-id)]
      [rest : ast.AstExprList
        (ast.ast-expr-list-tail-from-ref exprs (+ index 1))]
      (if after-terminal
        (lint-findings-add
          (lint-unreachable-code-finding (lint-no-effect-span-id head-id))
          acc)
        (lint-walk-plain-sequence-expr-list-after-terminal-at
          exprs
          threshold
          (lint-walk-expr
            (owned_view.compiler-owned-shared-view head)
            threshold
            (lint-add-redundant-divergence-padding head-id rest acc))
          (lint-terminal-expr? head)
          (+ index 1))))))

(define (lint-walk-discarded-nonsequence-expr
  [expr-id : i64]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [expr : ast.AstExpr (ast.ast-node-get expr-id)]
    [walked : LintFindings
      (lint-walk-expr
        (owned_view.compiler-owned-shared-view expr)
        threshold
        acc)]
    (if (lint-no-effect-pure-expr? expr)
      (lint-findings-add
        (lint-no-effect-finding (lint-no-effect-span-id expr-id))
        walked)
      walked)))

(define (lint-walk-discarded-expr
  [expr-id : i64]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (let
    [expr : ast.AstExpr (ast.ast-node-get expr-id)]
    (match (owned_view.compiler-owned-shared-view expr)
      [(Spanned inner-box _)
        (let
          [inner : ast.AstExpr (ast.ast-node-get inner-box)]
          (match inner
            [(Begin _) (lint-walk-expr expr threshold acc)]
            [(WithRegion _ _) (lint-walk-expr expr threshold acc)]
            [(WithEscape _ _) (lint-walk-expr expr threshold acc)]
            [(WithScratch _) (lint-walk-expr expr threshold acc)]
            [(InArena _ _) (lint-walk-expr expr threshold acc)]
            [(WithResource _) (lint-walk-expr expr threshold acc)]
            [_ (lint-walk-discarded-nonsequence-expr expr-id threshold acc)]))]
      [(Begin _) (lint-walk-expr expr threshold acc)]
      [(WithRegion _ _) (lint-walk-expr expr threshold acc)]
      [(WithEscape _ _) (lint-walk-expr expr threshold acc)]
      [(WithScratch _) (lint-walk-expr expr threshold acc)]
      [(InArena _ _) (lint-walk-expr expr threshold acc)]
      [(WithResource _) (lint-walk-expr expr threshold acc)]
      [_ (lint-walk-discarded-nonsequence-expr expr-id threshold acc)])))

(define (lint-walk-value-sequence-expr-list
  [exprs : (& exprs ast.AstExprList)]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-value-sequence-expr-list-after-terminal exprs threshold acc false))

(define (lint-walk-value-sequence-expr-list-after-terminal
  [exprs : (& exprs ast.AstExprList)]
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
      [head-id : i64 (ast.ast-expr-list-get exprs index 0)]
      [head : ast.AstExpr (ast.ast-node-get head-id)]
      [rest : ast.AstExprList
        (ast.ast-expr-list-tail-from-ref exprs (+ index 1))]
      (if after-terminal
        (lint-findings-add
          (lint-unreachable-code-finding (lint-no-effect-span-id head-id))
          acc)
        (let
          [with-padding : LintFindings
            (lint-add-redundant-divergence-padding head-id rest acc)]
          [walked : LintFindings
            (if (= rest.len 0)
              (lint-walk-expr
                (owned_view.compiler-owned-shared-view head)
                threshold
                with-padding)
              (lint-walk-discarded-expr head-id threshold with-padding))]
          (lint-walk-value-sequence-expr-list-after-terminal-at
            exprs
            threshold
            walked
            (lint-terminal-expr? head)
            (+ index 1)))))))

(define (lint-walk-tail-sequence-expr-list
  [exprs : (& exprs ast.AstExprList)]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (lint-walk-tail-sequence-expr-list-after-terminal exprs threshold acc false))

(define (lint-expr-list-single? [exprs : (& exprs ast.AstExprList)]) : bool
  (= exprs.len 1))

(define (lint-add-single-begin
  [exprs : (& exprs ast.AstExprList)]
  [span : ast.AstSourceSpan]
  [acc : LintFindings]) : LintFindings
  (if (lint-expr-list-single? exprs)
    (lint-findings-add (lint-single-begin-finding span) acc)
    acc))

(define (lint-walk-tail-sequence-expr-list-after-terminal
  [exprs : (& exprs ast.AstExprList)]
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
      [head-id : i64 (ast.ast-expr-list-get exprs index 0)]
      [head : ast.AstExpr (ast.ast-node-get head-id)]
      [rest : ast.AstExprList
        (ast.ast-expr-list-tail-from-ref exprs (+ index 1))]
      (if after-terminal
        (lint-findings-add
          (lint-unreachable-code-finding (lint-no-effect-span-id head-id))
          acc)
        (let
          [with-padding : LintFindings
            (lint-add-redundant-divergence-padding head-id rest acc)]
          [walked : LintFindings
            (if (= rest.len 0)
              (lint-walk-tail-expr
                (owned_view.compiler-owned-shared-view head)
                threshold
                with-padding)
              (lint-walk-discarded-expr head-id threshold with-padding))]
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
      [(Binding _ _ init-box)
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
      [(Binding binding-name _ _)
        (if (= binding-name name)
          true
          (lint-let-bindings-contain-name-at? bindings name (+ index 1)))])))

(define (lint-let-bindings-shadow-outer?
  [outer : (& outer ast.AstLetBindingList)]
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
      [(Binding name _ _)
        (if (lint-let-bindings-contain-name-at? outer name 0)
          true
          (lint-let-bindings-shadow-outer-at? outer inner (+ index 1)))])))

(define (lint-nested-let-body? [body : ast.AstExpr]) : bool
  (match body
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-nested-let-body? inner))]
    [(Let _) true]
    [_ false]))

(define (lint-nested-let-shadows?
  [outer : (& outer ast.AstLetBindingList)]
  [body : ast.AstExpr]) : bool
  (match body
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-nested-let-shadows? outer inner))]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let inner-bindings _)
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
            bindings
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
            bindings
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
      [(Binding _ init-box cleanup-box _)
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
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-ladder inner threshold tail-return-path acc))]
    [(If cond-box then-branch-box else-branch-box)
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
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-return-path-chain inner threshold acc))]
    [(If cond-box then-branch-box else-branch-box)
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
          (If
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
          (If
            (ast.ast-node-push cond)
            (ast.ast-node-push then-branch)
            (ast.ast-node-push else-branch))
          threshold
          tail-return-path
          acc)]
      [(>= ladder threshold)
        (lint-walk-ladder
          (If
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
      [head-id : i64 (ast.ast-expr-list-get exprs index 0)]
      [head : ast.AstExpr (ast.ast-node-get head-id)]
      [rest : ast.AstExprList
        (ast.ast-expr-list-tail-from-ref exprs (+ index 1))]
      (if after-terminal
        (lint-findings-add
          (lint-unreachable-code-finding (lint-no-effect-span-id head-id))
          acc)
        (let
          [with-padding : LintFindings
            (lint-add-redundant-divergence-padding head-id rest acc)]
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
      [(Arm _ body-box)
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
    [(Spanned inner-box span)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (match (owned_view.compiler-owned-shared-view inner)
          [(If cond-box then-branch-box else-branch-box)
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
          [(Let let-box)
            (match (__tl-box-place let-box)
              [(Let bindings body-box)
                (let
                  [body : ast.AstExpr (ast.ast-node-get body-box)]
                  (lint-walk-tail-let bindings body span threshold acc))])]
          [(Call func-box args)
            (let
              [func : ast.AstExpr (ast.ast-node-get func-box)]
              (lint-walk-call func args span threshold acc))]
          [(Begin exprs)
            (lint-walk-tail-sequence-expr-list
              exprs
              threshold
              (lint-add-single-begin exprs span acc))]
          [_ (lint-walk-tail-expr inner threshold acc)]))]
    [(If cond-box then-branch-box else-branch-box)
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
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body-box)
          (let
            [body : ast.AstExpr (ast.ast-node-get body-box)]
            (lint-walk-tail-let bindings body (lint-no-span) threshold acc))])]
    [(Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(Lambda _ _ body-box)
          (let
            [body : ast.AstExpr (ast.ast-node-get body-box)]
            (lint-walk-tail-expr body threshold acc))])]
    [(Begin exprs)
      (lint-walk-tail-sequence-expr-list
        exprs
        threshold
        (lint-add-single-begin exprs (lint-no-span) acc))]
    [(Unsafe exprs) (lint-walk-tail-expr-list exprs threshold acc)]
    [(Ann inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-tail-expr inner threshold acc))]
    [(Cast inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-walk-tail-expr inner threshold acc))]
    [(Match match-box)
      (match (__tl-box-place match-box)
        [(Match scrutinee-box arms)
          (let
            [scrutinee : ast.AstExpr (ast.ast-node-get scrutinee-box)]
            (lint-walk-tail-match-arms
              arms
              threshold
              (lint-walk-expr scrutinee threshold acc)))])]
    [(WithRegion _ body) (lint-walk-tail-sequence-expr-list body threshold acc)]
    [(WithEscape scratch-box body)
      (let
        [scratch : ast.AstExpr (ast.ast-node-get scratch-box)]
        (lint-walk-tail-sequence-expr-list
          body
          threshold
          (lint-walk-expr scratch threshold acc)))]
    [(WithScratch body) (lint-walk-tail-sequence-expr-list body threshold acc)]
    [(InArena arena-box body)
      (let
        [arena : ast.AstExpr (ast.ast-node-get arena-box)]
        (lint-walk-tail-sequence-expr-list
          body
          threshold
          (lint-walk-expr arena threshold acc)))]
    [(WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(WithResource bindings body)
          (lint-walk-tail-sequence-expr-list
            body
            threshold
            (lint-walk-resource-bindings bindings threshold acc))])]
    [(Try inner-box)
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
    [(Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (if (lint-and-or-call-kind?
          op
          (owned_view.compiler-owned-shared-view inner))
          (lint-walk-and-or-skip-expr op inner threshold acc)
          (lint-walk-expr expr threshold acc)))]
    [(Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (if (string.eq (lint-and-or-func-op func) op)
          (lint-walk-and-or-skip-args op args threshold acc)
          (lint-walk-expr expr threshold acc)))]
    [_ (lint-walk-expr expr threshold acc)]))

(define (lint-walk-and-or-skip-args
  [op : String]
  [args : (& args ast.AstExprList)]
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
      (match (string.string-ref name 0)
        ['t'
          (or
            (string.eq name "tl_arena_set")
            (string.eq name "tl_arena_destroy")
            (string.eq name "tl_region_reset"))]
        ['a'
          (or
            (string.eq name "arena.tl_arena_set")
            (string.eq name "arena.tl_arena_destroy")
            (string.eq name "arena.tl_region_reset")
            (string.eq name "arena.set!")
            (string.eq name "arena.destroy")
            (string.eq name "arena.rewind"))]
        [_ false]))))

(define (lint-raw-arena-op-callee? [func : ast.AstExpr]) : bool
  (match func
    [(Spanned inner-box _)
      (lint-raw-arena-op-callee? (ast.ast-node-get inner-box))]
    [(Var name) (lint-raw-arena-op-name? (ci.intern-str name))]
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
        args))
      (lint-walk-and-or-skip-args
        (owned_view.compiler-owned-shared-view op)
        args
        threshold
        (lint-findings-add
          (lint-cascading-and-or-finding op (lint-expr-render func) args span)
          callee-findings))
      (if (and (lint-str-cat-func? func) (lint-str-cat-args-have-nested? args))
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
  ;; The arms below apply the rules and walk sequences and quoted syntax;
  ;; every other variant's children are walked through the AstExpr child
  ;; list.
  (match (owned_view.compiler-owned-shared-view expr)
    [(Spanned inner-box span)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (match (owned_view.compiler-owned-shared-view inner)
          [(If cond-box then-branch-box else-branch-box)
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
          [(Let let-box)
            (match (__tl-box-place let-box)
              [(Let bindings body-box)
                (let
                  [body : ast.AstExpr (ast.ast-node-get body-box)]
                  (lint-walk-let bindings body span threshold acc))])]
          [(Call func-box args)
            (let
              [func : ast.AstExpr (ast.ast-node-get func-box)]
              (lint-walk-call func args span threshold acc))]
          [(Begin exprs)
            (lint-walk-value-sequence-expr-list
              exprs
              threshold
              (lint-add-single-begin exprs span acc))]
          [_ (lint-walk-expr inner threshold acc)]))]
    [(Call func-box args)
      (let
        [func : ast.AstExpr (ast.ast-node-get func-box)]
        (lint-walk-call func args (lint-no-span) threshold acc))]
    [(If cond-box then-branch-box else-branch-box)
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
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body-box)
          (let
            [body : ast.AstExpr (ast.ast-node-get body-box)]
            (lint-walk-let bindings body (lint-no-span) threshold acc))])]
    [(ForOwnedState payload)
      (lint-walk-expr
        (ast.ast-node-get (ast.ast-for-owned-state-body (& payload)))
        threshold
        (lint-walk-expr
          (ast.ast-node-get (ast.ast-for-owned-state-source (& payload)))
          threshold
          acc))]
    [(ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (lint-walk-expr
          (ast.ast-node-get (ast.ast-for-owned-step-body (& payload)))
          threshold
          (if (>= expected-type 0)
            (lint-walk-expr (ast.ast-node-get expected-type) threshold acc)
            acc)))]
    [(Begin exprs)
      (lint-walk-value-sequence-expr-list
        exprs
        threshold
        (lint-add-single-begin exprs (lint-no-span) acc))]
    [(Unsafe exprs) (lint-walk-plain-sequence-expr-list exprs threshold acc)]
    [(WithRegion _ body)
      (lint-walk-value-sequence-expr-list body threshold acc)]
    [(WithEscape scratch-box body)
      (let
        [scratch : ast.AstExpr (ast.ast-node-get scratch-box)]
        (lint-walk-value-sequence-expr-list
          body
          threshold
          (lint-walk-expr scratch threshold acc)))]
    [(WithScratch body) (lint-walk-value-sequence-expr-list body threshold acc)]
    [(InArena arena-box body)
      (let
        [arena : ast.AstExpr (ast.ast-node-get arena-box)]
        (lint-walk-value-sequence-expr-list
          body
          threshold
          (lint-walk-expr arena threshold acc)))]
    [(WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(WithResource bindings body)
          (lint-walk-value-sequence-expr-list
            body
            threshold
            (lint-walk-resource-bindings bindings threshold acc))])]
    [(Quote _) acc]
    [(Quasiquote _) acc]
    [_ (lint-walk-expr-list (ast.ast-expr-child-ids expr) threshold acc)]))

;: Walk the body expression(s) carried by a declaration, if any.
(define (lint-walk-decl
  [decl : ast.AstDecl]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match decl
    [(Def decl-meta _ _ body-box)
      (let
        [body : ast.AstExpr (ast.ast-node-get body-box)]
        (lint-walk-expr body threshold acc))]
    [(DefFn decl-meta _ _ _ body-box _)
      (let
        [body : ast.AstExpr (ast.ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(DefMacro decl-meta _ _ _ body-box)
      (let
        [body : ast.AstExpr (ast.ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(Test _ body-box _ _)
      (let
        [body : ast.AstExpr (ast.ast-node-get body-box)]
        (lint-walk-tail-expr body threshold acc))]
    [(Unsafe inner-box)
      (let
        [inner : ast.AstDecl (ast.ast-decl-box-shared-view inner-box)]
        (lint-walk-decl inner threshold acc))]
    [(ModuleBody _ body-box)
      (lint-walk-decl-list
        (ast.ast-decl-list-box-shared-view body-box)
        threshold
        acc)]
    [(Module _) acc]
    [(Extern decl-meta _ _ _ _) acc]
    [(DefEnum decl-meta _ _ _) acc]
    [(DefEnumLifetimes decl-meta _ _ _ _) acc]
    [(DefStruct decl-meta _ _ _ _) acc]
    [(DefStructLifetimes decl-meta _ _ _ _ _) acc]
    [(DefDispatch decl-meta _ _) acc]
    [(IncludeStr _ _) acc]
    [(IncludeStrComptime _ _) acc]
    [(IncludeStrLzss _ _) acc]
    [(IncludeBin _ _) acc]
    [(Import decl-meta _) acc]))

;: Walk every declaration body in `decls`.
(define (lint-walk-decl-list
  [decls : ast.AstDeclList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match (ast.ast-decl-list-step decls)
    [(Nil) acc]
    [(Cons decl rest)
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
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        [_line-index : unit (lint-source-line-index-build! source)]
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
            source
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
              decls
              with-locals)
            with-locals)]
        (if deprecated-string-concat
          (lint-deprecated-string-concat-scan source with-decls)
          with-decls))]))