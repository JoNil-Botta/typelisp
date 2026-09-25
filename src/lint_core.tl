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

;: Attach a rule-proved fix without inventing a second edit coordinate type.
(define (lint-finding-with-fix
  [finding : LintFinding]
  [fix : cdiag.CompilerDiagnosticFix]) : LintFinding
  (LintFinding
    finding.message
    finding.rule-id
    finding.depth
    finding.span
    (LintFixAvailable fix)))

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
    [(LintLevel.Allow) 0]
    [(LintLevel.Warn) 1]
    [(LintLevel.Deny) 2]
    [(LintLevel.Forbid) 3]))

(define (lint-level-eq?
  [left : (& left LintLevel)]
  [right : (& right LintLevel)]) : bool
  (= (lint-level-rank left) (lint-level-rank right)))

(define (lint-level-name [level : LintLevel]) : String
  (match level
    [(LintLevel.Allow) "allow"]
    [(LintLevel.Warn) "warn"]
    [(LintLevel.Deny) "deny"]
    [(LintLevel.Forbid) "forbid"]))

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
        LintLevel.Warn
        (bit-or lint-group-style-mask lint-group-complexity-mask))
      (LintRule
        (lint-rule-nested-let-id)
        (lint-rule-nested-let-message)
        (lint-rule-nested-let-suggestion)
        LintLevel.Warn
        (bit-or lint-group-style-mask lint-group-complexity-mask))
      (LintRule
        (lint-rule-single-begin-id)
        (lint-rule-single-begin-message)
        (lint-rule-single-begin-suggestion)
        LintLevel.Warn
        lint-group-style-mask)
      (LintRule
        (lint-rule-return-path-chain-id)
        (lint-rule-return-path-chain-message)
        (lint-rule-return-path-chain-suggestion)
        LintLevel.Warn
        (bit-or lint-group-style-mask lint-group-complexity-mask))
      (LintRule
        (lint-rule-unit-if-guard-id)
        (lint-rule-unit-if-guard-message)
        (lint-rule-unit-if-guard-suggestion)
        LintLevel.Warn
        lint-group-style-mask)
      (LintRule
        (lint-rule-no-effect-id)
        (lint-rule-no-effect-message)
        (lint-rule-no-effect-suggestion)
        LintLevel.Warn
        lint-group-correctness-mask)
      (LintRule
        (lint-rule-unreachable-code-id)
        (lint-rule-unreachable-code-message)
        (lint-rule-unreachable-code-suggestion)
        LintLevel.Warn
        lint-group-correctness-mask)
      (LintRule
        (lint-rule-redundant-divergence-padding-id)
        (lint-rule-redundant-divergence-padding-message)
        (lint-rule-redundant-divergence-padding-suggestion)
        LintLevel.Warn
        lint-group-correctness-mask)
      (LintRule
        (lint-rule-deprecated-string-concat-id)
        (lint-rule-deprecated-string-concat-message)
        (lint-rule-deprecated-string-concat-suggestion)
        LintLevel.Allow
        (bit-or
          lint-group-compatibility-mask
          lint-group-future-incompatibility-mask))
      (LintRule
        (lint-rule-nested-str-cat-id)
        (lint-rule-nested-str-cat-message)
        (lint-rule-nested-str-cat-suggestion)
        LintLevel.Warn
        (bit-or lint-group-style-mask lint-group-performance-mask))
      (LintRule
        (lint-rule-cascading-and-or-id)
        (lint-rule-cascading-and-or-message)
        (lint-rule-cascading-and-or-suggestion)
        LintLevel.Warn
        (bit-or lint-group-style-mask lint-group-complexity-mask))
      (LintRule
        (lint-rule-unused-import-id)
        (lint-rule-unused-import-message)
        (lint-rule-unused-import-suggestion)
        LintLevel.Warn
        (bit-or lint-group-correctness-mask lint-group-style-mask))
      (LintRule
        (lint-rule-redundant-import-alias-id)
        (lint-rule-redundant-import-alias-message)
        (lint-rule-redundant-import-alias-suggestion)
        LintLevel.Warn
        lint-group-style-mask)
      (LintRule
        (lint-rule-redundant-function-name-id)
        (lint-rule-redundant-function-name-message)
        (lint-rule-redundant-function-name-suggestion)
        LintLevel.Allow
        lint-group-style-mask)
      (LintRule
        (lint-rule-dead-code-id)
        (lint-rule-dead-code-message)
        (lint-rule-dead-code-suggestion)
        LintLevel.Warn
        lint-group-correctness-mask)
      (LintRule
        (lint-rule-unused-assignment-id)
        (lint-rule-unused-assignment-message)
        (lint-rule-unused-assignment-suggestion)
        LintLevel.Warn
        (bit-or lint-group-correctness-mask lint-group-performance-mask))
      (LintRule
        (lint-rule-copy-on-update-struct-id)
        (lint-rule-copy-on-update-struct-message)
        (lint-rule-copy-on-update-struct-suggestion)
        LintLevel.Warn
        lint-group-performance-mask)
      (LintRule
        (lint-rule-prefer-dynamic-array-literal-id)
        (lint-rule-prefer-dynamic-array-literal-message)
        (lint-rule-prefer-dynamic-array-literal-suggestion)
        LintLevel.Warn
        (bit-or lint-group-style-mask lint-group-performance-mask))
      (LintRule
        (lint-rule-single-element-array-cell-id)
        (lint-rule-single-element-array-cell-message)
        (lint-rule-single-element-array-cell-suggestion)
        LintLevel.Warn
        (bit-or lint-group-style-mask lint-group-performance-mask))
      (LintRule
        (lint-rule-unused-variable-id)
        (lint-rule-unused-variable-message)
        (lint-rule-unused-variable-suggestion)
        LintLevel.Warn
        (bit-or lint-group-correctness-mask lint-group-style-mask))
      (LintRule
        (lint-rule-unused-unsafe-id)
        (lint-rule-unused-unsafe-message)
        (lint-rule-unused-unsafe-suggestion)
        LintLevel.Warn
        lint-group-unsafe-mask)
      (LintRule
        (lint-rule-raw-arena-op-id)
        (lint-rule-raw-arena-op-message)
        (lint-rule-raw-arena-op-suggestion)
        LintLevel.Warn
        (bit-or lint-group-correctness-mask lint-group-unsafe-mask))
      (LintRule
        (lint-rule-transitional-core-macro-qualifier-id)
        (lint-rule-transitional-core-macro-qualifier-message)
        (lint-rule-transitional-core-macro-qualifier-suggestion)
        LintLevel.Warn
        (bit-or
          lint-group-compatibility-mask
          lint-group-future-incompatibility-mask))
      (LintRule
        (lint-rule-global-name-case-id)
        (lint-rule-global-name-case-message)
        (lint-rule-global-name-case-suggestion)
        LintLevel.Allow
        lint-group-style-mask)
      (LintRule
        (lint-rule-function-name-case-id)
        (lint-rule-function-name-case-message)
        (lint-rule-function-name-case-suggestion)
        LintLevel.Allow
        lint-group-style-mask)
      (LintRule
        (lint-rule-local-name-case-id)
        (lint-rule-local-name-case-message)
        (lint-rule-local-name-case-suggestion)
        LintLevel.Allow
        lint-group-style-mask)
      (LintRule
        (lint-rule-type-name-case-id)
        (lint-rule-type-name-case-message)
        (lint-rule-type-name-case-suggestion)
        LintLevel.Allow
        lint-group-style-mask))
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

;: Registry default for one rule. Unknown ids fail closed to `allow`; callers
;: that accept user policy must also report the unknown id structurally.
(define (lint-rule-default-level [rule-id : String]) : LintLevel
  (match (lint-rule-find rule-id)
    [(LintMaybeRule.Found rule) rule.default-level]
    [(LintMaybeRule.NotFound) LintLevel.Allow]))

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
  [dst : (&mut dst (__tl_dyn-array LintFinding))]
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
      (__tl_make-array
        LintFinding
        (*
          (lint-findings-capacity (owned_view.compiler-owned-shared-view items))
          2))]
    (begin
      (lint-findings-copy-range (&mut bigger) (lint-findings-slots items) 0 n)
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
  (match expr
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
    [(ast.AstExpr.FixedMakeArray _ _) true]
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

(define (lint-name-case-has-ascii-letter? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
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
    [n : i64 (string.string-length name)]
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
              name
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
              name
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
    [(ast.AstMaybeSourceSpan.No) (lint-no-span)]
    [(ast.AstMaybeSourceSpan.Some span) span]))

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
    span
    (lint-fix-unproven)))

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

(define (lint-and-or-args-have-kind?
  [op : String]
  [args : (& args ast.AstExprList)]) : bool
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
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
        (lint-str-cat-call? inner))]
    [(ast.AstExpr.Call func-box _)
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
  [args : (& args ast.AstExprList)]) : String
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
  [args : (& args ast.AstExprList)]) : i64
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
      (lint-cascading-and-or-flat-call
        callee
        (owned_view.compiler-owned-shared-view op)
        args))
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
      [(not (source_text.starts-with? name qualifier)) false]
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
  (lint-name-uses-import? (ci.intern-str name) alias module-name))

(define (lint-maybe-type-uses-import?
  [maybe-ty : ast.AstMaybeType]
  [alias : String]
  [module-name : String]) : bool
  (match maybe-ty
    [(ast.AstMaybeType.No) false]
    [(ast.AstMaybeType.Some ty) (lint-type-uses-import? ty alias module-name)]))

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
  (lint-type-uses-import? (ast.ty-node-get ty) alias module-name))

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
        (deref args)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-type-id-uses-import? ret alias module-name))]
    [(ast.AstType.CFunc signature _)
      (lint-type-id-uses-import? signature alias module-name)]
    [(ast.AstType.Tuple items)
      (lint-type-list-uses-import? (deref items) alias module-name)]
    [(ast.AstType.Array elem _)
      (lint-type-id-uses-import? elem alias module-name)]
    [(ast.AstType.DynArray elem)
      (lint-type-id-uses-import? elem alias module-name)]
    [(ast.AstType.Slice elem)
      (lint-type-id-uses-import? elem alias module-name)]
    [(ast.AstType.Box elem) (lint-type-id-uses-import? elem alias module-name)]
    [(ast.AstType.Region _ inner)
      (lint-type-id-uses-import? inner alias module-name)]
    [(ast.AstType.Ref _ inner)
      (lint-type-id-uses-import? inner alias module-name)]
    [(ast.AstType.MutRef _ inner)
      (lint-type-id-uses-import? inner alias module-name)]
    [(ast.AstType.Enum name) (lint-name-id-uses-import? name alias module-name)]
    [(ast.AstType.EnumArgs name _)
      (lint-name-id-uses-import? name alias module-name)]
    [(ast.AstType.Struct name)
      (lint-name-id-uses-import? name alias module-name)]
    [(ast.AstType.StructArgs name _)
      (lint-name-id-uses-import? name alias module-name)]
    [(ast.AstType.Var name) (lint-name-id-uses-import? name alias module-name)]
    [(ast.AstType.VarArgs name _)
      (lint-name-id-uses-import? name alias module-name)]
    [(ast.AstType.Ptr inner)
      (lint-type-id-uses-import? inner alias module-name)]
    [(ast.AstType.MutPtr inner)
      (lint-type-id-uses-import? inner alias module-name)]))

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
      (lint-maybe-type-uses-import? maybe-ty alias module-name)]
    [(ast.AstPattern.Tuple items)
      (lint-pattern-list-uses-import? (deref items) alias module-name)]
    [(ast.AstPattern.Array items)
      (lint-pattern-list-uses-import? (deref items) alias module-name)]
    [(ast.AstPattern.Wildcard) false]
    [(ast.AstPattern.Binding _) false]
    [(ast.AstPattern.Variant name items)
      (if (lint-name-id-uses-import?
        name
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-pattern-list-uses-import? (deref items) alias module-name))]
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

(define (lint-expr-list-requires-enclosing-unsafe?
  [exprs : (& exprs ast.AstExprList)]) : bool
  (__tl-project-field
    (lint-unsafe-scan-expr-list
      exprs
      (LintUnsafeScope (lint-name-set-empty) false))
    requires))

(define (lint-expr-list-uses-import?
  [exprs : ast.AstExprList]
  [alias : String]
  [module-name : String]) : bool
  (ast.ast-expr-list-fold
    exprs
    ast.ast-fold-or
    false
    lint-child-expr-uses-import?
    alias
    module-name))

;; Unsafe operations with expression children; ProgramArgv and ProgramEnvp
;; also need an enclosing unsafe block but have none.
(define (lint-expr-unsafe-operation? [expr : (& expr ast.AstExpr)]) : bool
  (match expr
    [(ast.AstExpr.PtrAddrOf _) true]
    [(ast.AstExpr.PtrRead _) true]
    [(ast.AstExpr.PtrWrite _ _) true]
    [(ast.AstExpr.PtrOffset _ _) true]
    [(ast.AstExpr.PtrCast _ _) true]
    [(ast.AstExpr.PtrToInt _) true]
    [(ast.AstExpr.IntToPtr _ _) true]
    [(ast.AstExpr.StringData _) true]
    [(ast.AstExpr.StringFromBytes _ _) true]
    [(ast.AstExpr.ArrayData _) true]
    [(ast.AstExpr.Syscall _) true]
    [_ false]))

;; AstExpr child schema hooks take the walk's contexts first and the child last.
(defmacro (lint-child-expr-uses-import?
  [alias : Expr]
  [module-name : Expr]
  [expr-id : Expr]) : Expr
  `(lint-expr-uses-import?
    ,expr-id
    (owned_view.compiler-owned-shared-view ,alias)
    (owned_view.compiler-owned-shared-view ,module-name)))

(defmacro (lint-child-type-id-uses-import?
  [alias : Expr]
  [module-name : Expr]
  [ty-id : Expr]) : Expr
  `(lint-type-id-uses-import?
    ,ty-id
    (owned_view.compiler-owned-shared-view ,alias)
    (owned_view.compiler-owned-shared-view ,module-name)))

(defmacro (lint-child-type-uses-import?
  [alias : Expr]
  [module-name : Expr]
  [ty : Expr]) : Expr
  `(lint-type-uses-import?
    ,ty
    (owned_view.compiler-owned-shared-view ,alias)
    (owned_view.compiler-owned-shared-view ,module-name)))

(defmacro (lint-child-pattern-uses-import?
  [alias : Expr]
  [module-name : Expr]
  [pattern : Expr]) : Expr
  `(lint-pattern-uses-import?
    ,pattern
    (owned_view.compiler-owned-shared-view ,alias)
    (owned_view.compiler-owned-shared-view ,module-name)))

(define (lint-expr-uses-import?
  [expr-id : i64]
  [alias : String]
  [module-name : String]) : bool
  ;; The arms below check names and the for-owned and unsafe forms; every other
  ;; variant's children are checked through the AstExpr child schema.
  (match (ast.ast-node-get expr-id)
    [(ast.AstExpr.Var name) (lint-name-id-uses-import? name alias module-name)]
    [(ast.AstExpr.ForOwnedState payload)
      (or
        (lint-expr-uses-import?
          (ast.ast-for-owned-state-source (& payload))
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
        (lint-expr-uses-import?
          (ast.ast-for-owned-state-body (& payload))
          alias
          module-name))]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (or
          (and
            (>= expected-type 0)
            (lint-expr-uses-import?
              expected-type
              (owned_view.compiler-owned-shared-view alias)
              (owned_view.compiler-owned-shared-view module-name)))
          (lint-expr-uses-import?
            (ast.ast-for-owned-step-body (& payload))
            alias
            module-name)))]
    [(ast.AstExpr.Unsafe exprs)
      (cond
        [(lint-requires-enclosing-unsafe-sentinel?
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
          false]
        [(lint-unused-unsafe-candidate-sentinel?
            (owned_view.compiler-owned-shared-view alias)
            (owned_view.compiler-owned-shared-view module-name))
          (if (lint-expr-list-requires-enclosing-unsafe? exprs)
            (lint-expr-list-uses-import? exprs alias module-name)
            true)]
        [else (lint-expr-list-uses-import? exprs alias module-name)])]
    [(ast.AstExpr.Set target value)
      (or
        (lint-name-id-uses-import?
          target
          (owned_view.compiler-owned-shared-view alias)
          (owned_view.compiler-owned-shared-view module-name))
        (lint-expr-uses-import? value alias module-name))]
    [_
      (let
        [expr : ast.AstExpr (ast.ast-node-get expr-id)]
        (or
          (and
            (lint-expr-unsafe-operation? (& expr))
            (lint-requires-enclosing-unsafe-sentinel?
              (owned_view.compiler-owned-shared-view alias)
              (owned_view.compiler-owned-shared-view module-name)))
          (ast.ast-expr-children-any?
            expr
            lint-child-expr-uses-import?
            lint-child-type-id-uses-import?
            lint-child-type-uses-import?
            lint-child-pattern-uses-import?
            alias
            module-name)))]))

(define (lint-extern-abi-uses-import?
  [abi : ast.AstExternAbi]
  [alias : String]
  [module-name : String]) : bool
  (match abi
    [(ast.AstExternAbi.C) false]
    [(ast.AstExternAbi.CVarargsOpen) false]
    [(ast.AstExternAbi.CVarargsTyped tail-ty)
      (lint-type-uses-import? tail-ty alias module-name)]))

(define (lint-extern-metadata-uses-import?
  [meta : ast.AstExternMetadata]
  [alias : String]
  [module-name : String]) : bool
  (match meta
    [(ast.AstExternMetadata.Metadata abi _ _ _ _)
      (lint-extern-abi-uses-import? abi alias module-name)]))

(define (lint-field-cleanup-uses-import?
  [cleanup : ast.AstFieldCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(ast.AstFieldCleanup.No) false]
    [(ast.AstFieldCleanup.Fn name)
      (lint-name-id-uses-import?
        (ci.intern-syntax-id-value name)
        alias
        module-name)]
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
        (ci.intern-syntax-id-value name)
        alias
        module-name)]))

(define (lint-enum-cleanup-uses-import?
  [cleanup : ast.AstEnumCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(ast.AstEnumCleanup.No) false]
    [(ast.AstEnumCleanup.Fn name)
      (lint-name-id-uses-import?
        (ci.intern-syntax-id-value name)
        alias
        module-name)]))

(define (lint-variant-payload-cleanup-uses-import?
  [cleanup : ast.AstVariantPayloadCleanup]
  [alias : String]
  [module-name : String]) : bool
  (match cleanup
    [(ast.AstVariantPayloadCleanup.No) false]
    [(ast.AstVariantPayloadCleanup.Fn name)
      (lint-name-id-uses-import?
        (ci.intern-syntax-id-value name)
        alias
        module-name)]
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
            alias
            module-name))])))

(define (lint-dispatch-variant-list-uses-import?
  [variants : ast.AstDispatchVariantList]
  [alias : String]
  [module-name : String]) : bool
  (lint-dispatch-variant-list-uses-import-from?
    (& variants)
    0
    alias
    module-name))

(define (lint-generated-decl-meta-uses-import?
  [meta : ast.AstGeneratedDeclMeta]
  [alias : String]
  [module-name : String]) : bool
  (match meta
    [(ast.AstGeneratedDeclMeta.No) false]
    [(ast.AstGeneratedDeclMeta.Some _ _ args _)
      (lint-expr-list-uses-import? args alias module-name)]))

(define (lint-decl-uses-import-inner?
  [decl : ast.AstDecl]
  [alias : String]
  [module-name : String]) : bool
  (match decl
    [(ast.AstDecl.Module _) false]
    [(ast.AstDecl.ModuleBody _ body)
      (lint-decl-list-uses-import?
        (ast.ast-decl-list-box-shared-view body)
        alias
        module-name)]
    [(ast.AstDecl.Def decl-meta _ maybe-ty body)
      (if (lint-maybe-type-uses-import?
        maybe-ty
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-expr-uses-import? body alias module-name))]
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
          (lint-expr-uses-import? body alias module-name)))]
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
          (lint-expr-uses-import? body alias module-name)))]
    [(ast.AstDecl.Extern decl-meta _ _ meta ty)
      (if (lint-extern-metadata-uses-import?
        (ast.ast-extern-metadata-box-shared-view meta)
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-type-uses-import? ty alias module-name))]
    [(ast.AstDecl.DefEnum decl-meta _ cleanup variants)
      (if (lint-enum-cleanup-uses-import?
        cleanup
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-variant-def-list-uses-import? variants alias module-name))]
    [(ast.AstDecl.DefEnumLifetimes decl-meta _ _ cleanup variants)
      (if (lint-enum-cleanup-uses-import?
        cleanup
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-variant-def-list-uses-import? variants alias module-name))]
    [(ast.AstDecl.DefStruct decl-meta _ _ cleanup fields)
      (if (lint-struct-cleanup-uses-import?
        cleanup
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-field-def-list-uses-import? fields alias module-name))]
    [(ast.AstDecl.DefStructLifetimes decl-meta _ _ _ cleanup fields)
      (if (lint-struct-cleanup-uses-import?
        cleanup
        (owned_view.compiler-owned-shared-view alias)
        (owned_view.compiler-owned-shared-view module-name))
        true
        (lint-field-def-list-uses-import? fields alias module-name))]
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec (ast.AstImportKind.Macro call-expr _) _ _ _ _))
      (lint-expr-uses-import? call-expr alias module-name)]
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec
          (ast.AstImportKind.MacroDecls call-expr _)
          _
          _
          _
          _))
      (lint-expr-uses-import? call-expr alias module-name)]
    [(ast.AstDecl.Import decl-meta _) false]
    [(ast.AstDecl.IncludeStr _ _) false]
    [(ast.AstDecl.IncludeStrComptime _ _) false]
    [(ast.AstDecl.IncludeStrLzss _ _) false]
    [(ast.AstDecl.IncludeBin _ _) false]
    [(ast.AstDecl.DefDispatch decl-meta _ variants)
      (lint-dispatch-variant-list-uses-import? variants alias module-name)]
    [(ast.AstDecl.Test _ body _ _)
      (lint-expr-uses-import? body alias module-name)]
    [(ast.AstDecl.Unsafe inner)
      (lint-decl-uses-import?
        (ast.ast-decl-box-shared-view inner)
        alias
        module-name)]))

(define (lint-decl-uses-import?
  [decl : ast.AstDecl]
  [alias : String]
  [module-name : String]) : bool
  (if (lint-generated-decl-meta-uses-import?
    (ast.ast-decl-generated-meta (owned_view.compiler-owned-shared-view decl))
    (owned_view.compiler-owned-shared-view alias)
    (owned_view.compiler-owned-shared-view module-name))
    true
    (lint-decl-uses-import-inner? decl alias module-name)))

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
          (lint-decl-list-uses-import? rest alias module-name)))]))

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
        source
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
                          all-decls
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
      (lint-unsafe-pattern-list-add-bindings (deref items) scope 0)]
    [(ast.AstPattern.Array items)
      (lint-unsafe-pattern-list-add-bindings (deref items) scope 0)]
    [(ast.AstPattern.Wildcard) scope]
    [(ast.AstPattern.Binding name) (lint-unsafe-scope-add-id scope name)]
    [(ast.AstPattern.Variant _ items)
      (lint-unsafe-pattern-list-add-bindings (deref items) scope 0)]
    [(ast.AstPattern.Literal _) scope]))

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

;; AstExpr child schema hooks: scan an expression child, skip type and pattern
;; children.
(defmacro (lint-unsafe-scan-child [scope : Expr] [node-id : Expr]) : Expr
  `(lint-unsafe-scan-node
    ,node-id
    (owned_view.compiler-owned-shared-view ,scope)))

(defmacro (lint-unsafe-scan-skip [_ignored : Expr ...]) : Expr
  `(lint-unsafe-scan-empty))

(define (lint-unsafe-scan-children
  [expr : ast.AstExpr]
  [scope : LintUnsafeScope]) : LintUnsafeScan
  (ast.ast-expr-children-fold
    expr
    lint-unsafe-scan-combine
    (lint-unsafe-scan-empty)
    lint-unsafe-scan-child
    lint-unsafe-scan-skip
    lint-unsafe-scan-skip
    lint-unsafe-scan-skip
    scope))

(define (lint-unsafe-scan-node [node-id : i64] [scope : LintUnsafeScope]) : LintUnsafeScan
  ;; The arms below bind names, mark unsafe calls and blocks, or scan the
  ;; for-owned forms; every other variant's children are scanned through the
  ;; AstExpr child schema.
  (match (ast.ast-node-get node-id)
    [(ast.AstExpr.Call func _)
      (let
        [children : LintUnsafeScan
          (lint-unsafe-scan-children
            (ast.ast-node-get node-id)
            (owned_view.compiler-owned-shared-view scope))]
        (match (ast.ast-expr-unspan (ast.ast-node-get func))
          [(ast.AstExpr.Var name)
            (let
              [with-string-use : LintUnsafeScan
                (if (lint-stdlib-string-bare-call-unshadowed? name scope)
                  (lint-unsafe-scan-note-stdlib-string-bare-use children)
                  children)]
              (if (lint-unsafe-call-unshadowed? name scope)
                (lint-unsafe-scan-require with-string-use)
                with-string-use))]
          [_ children]))]
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
    [(ast.AstExpr.Unsafe items)
      (let
        [inside : LintUnsafeScan (lint-unsafe-scan-expr-list items scope)]
        (LintUnsafeScan
          false
          (or (not inside.requires) inside.candidate)
          inside.stdlib-string-bare-use))]
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
    [(ast.AstExpr.SpmdCompact compact-box)
      (match (__tl-box-place compact-box)
        [(ast.AstSpmdCompact.Compact index _ start end slot _ init keep body)
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
              (lint-unsafe-scan-node
                keep
                (owned_view.compiler-owned-shared-view index-scope))]
            [body-scope : LintUnsafeScope
              (lint-unsafe-scope-add-id index-scope slot)]
            (lint-unsafe-scan-combine
              outer
              (lint-unsafe-scan-combine
                keep-scan
                (lint-unsafe-scan-node body body-scope))))])]
    [(ast.AstExpr.WithResource resource-box)
      (match (__tl-box-place resource-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-unsafe-scan-resource-bindings bindings body scope 0)])]
    [(ast.AstExpr.ProgramArgv)
      (lint-unsafe-scan-require (lint-unsafe-scan-empty))]
    [(ast.AstExpr.ProgramEnvp)
      (lint-unsafe-scan-require (lint-unsafe-scan-empty))]
    [_
      (let
        [expr : ast.AstExpr (ast.ast-node-get node-id)]
        [unsafe-operation : bool (lint-expr-unsafe-operation? (& expr))]
        [children : LintUnsafeScan (lint-unsafe-scan-children expr scope)]
        (if unsafe-operation
          (lint-unsafe-scan-require children)
          children))]))

(define (lint-unsafe-decl-add-global [decl : ast.AstDecl] [names : LintNameSet]) : LintNameSet
  (match decl
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
    [(ast.AstDecl.Test name _ _ _)
      (lint-name-set-add names (ci.intern-str name))]
    [(ast.AstDecl.Unsafe inner)
      (lint-unsafe-decl-add-global (deref inner) names)]))

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
        (lint-unsafe-scan-decl-list (deref body))]
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
      [(ast.AstDecl.Test _ body _ _) (lint-unsafe-scan-node body body-scope)]
      [(ast.AstDecl.Unsafe inner) (lint-unsafe-scan-decl (deref inner) scope)])))

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
      (__tl-project-field (lint-unsafe-scan-decl-list (deref decls)) candidate)]))

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
        [(ast.AstExpr.Spanned inner _)
          (lint-copy-on-update-add-set-if-needed
            target
            (ast.ast-node-get inner)
            span
            state)]
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
                        state
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
          (lint-copy-on-update-init-type-name state (ast.ast-node-get inner))
          annotated))]
    [(ast.AstExpr.Cast inner ty-id)
      (let
        [casted : String
          (lint-copy-on-update-struct-name-from-type
            (owned_view.compiler-owned-shared-view state.shapes)
            (ast.ty-node-get ty-id))]
        (if (string.eq casted "")
          (lint-copy-on-update-init-type-name state (ast.ast-node-get inner))
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
      (lint-copy-on-update-init-type-name state (ast.ast-node-get init))
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
        (ast.ast-expr-list-get exprs index 0)
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
            (lint-copy-on-update-expr init state (lint-no-effect-span-id init))]
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
      [(ast.AstMatchArm.Arm _ body)
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
      [(ast.AstResourceBinding.Binding _ init cleanup _)
        (lint-copy-on-update-resource-bindings-at
          bindings
          (lint-copy-on-update-expr
            cleanup
            (lint-copy-on-update-expr init state (lint-no-effect-span-id init))
            (lint-no-effect-span-id cleanup))
          (+ index 1))])))

;; AstExpr child schema hook: walk an expression child under the enclosing
;; span, threading `state`.
(defmacro (lint-copy-on-update-child!
  [state : Expr]
  [span : Expr]
  [child : Expr]) : Expr
  `(set! ,state (lint-copy-on-update-expr ,child ,state ,span)))

(define (lint-copy-on-update-expr
  [node-id : i64]
  [state : LintCopyOnUpdateState]
  [span : ast.AstSourceSpan]) : LintCopyOnUpdateState
  ;; The arms below track locals and set! targets, walk list items and match
  ;; arms without an enclosing span, and name the forms this rule does not
  ;; descend into; every other variant's expression children are walked
  ;; through the AstExpr child list.
  (match (ast.ast-node-get node-id)
    [(ast.AstExpr.Spanned inner _)
      (lint-copy-on-update-expr inner state (lint-no-effect-span-id inner))]
    [(ast.AstExpr.Call callee args)
      (lint-copy-on-update-expr-list
        args
        (lint-copy-on-update-expr callee state span))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-copy-on-update-let bindings body state span)])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda params _ body)
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
    [(ast.AstExpr.Tuple exprs) (lint-copy-on-update-expr-list exprs state)]
    [(ast.AstExpr.Array exprs) (lint-copy-on-update-expr-list exprs state)]
    [(ast.AstExpr.DynArray exprs) (lint-copy-on-update-expr-list exprs state)]
    [(ast.AstExpr.Begin exprs) (lint-copy-on-update-expr-list exprs state)]
    [(ast.AstExpr.Unsafe exprs) (lint-copy-on-update-expr-list exprs state)]
    [(ast.AstExpr.Set target value)
      (lint-copy-on-update-add-set-if-needed
        target
        (ast.ast-node-get value)
        span
        (lint-copy-on-update-expr value state span))]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (lint-copy-on-update-match-arms
            arms
            (lint-copy-on-update-expr scrutinee state span))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach name ty start end body)
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
              with-body.findings))])]
    [(ast.AstExpr.WithRegion _ body) (lint-copy-on-update-expr-list body state)]
    [(ast.AstExpr.WithEscape scratch body)
      (lint-copy-on-update-expr-list
        body
        (lint-copy-on-update-expr scratch state span))]
    [(ast.AstExpr.WithScratch body) (lint-copy-on-update-expr-list body state)]
    [(ast.AstExpr.InArena arena body)
      (lint-copy-on-update-expr-list
        body
        (lint-copy-on-update-expr arena state span))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-copy-on-update-expr-list
            body
            (lint-copy-on-update-resource-bindings bindings state))])]
    [(ast.AstExpr.Quote _) state]
    [(ast.AstExpr.Quasiquote _) state]
    [(ast.AstExpr.BracketClause items)
      (lint-copy-on-update-expr-list items state)]
    [(ast.AstExpr.MacroExpansion _ _ _) state]
    [(ast.AstExpr.SpmdReduce _) state]
    [(ast.AstExpr.SpmdScan _) state]
    [(ast.AstExpr.SpmdCompact _) state]
    [(ast.AstExpr.SpmdBroadcast _ _) state]
    [(ast.AstExpr.SpmdShuffle _ _) state]
    [(ast.AstExpr.PtrNullCheck _) state]
    [(ast.AstExpr.PtrAddrOf _) state]
    [(ast.AstExpr.PtrRead _) state]
    [(ast.AstExpr.PtrWrite _ _) state]
    [(ast.AstExpr.PtrOffset _ _) state]
    [(ast.AstExpr.PtrCast _ _) state]
    [(ast.AstExpr.PtrToInt _) state]
    [(ast.AstExpr.IntToPtr _ _) state]
    [(ast.AstExpr.StringData _) state]
    [(ast.AstExpr.StringFromBytes _ _) state]
    [(ast.AstExpr.ArrayData _) state]
    [(ast.AstExpr.CpuIdEax _ _) state]
    [(ast.AstExpr.CpuIdEbx _ _) state]
    [(ast.AstExpr.CpuIdEcx _ _) state]
    [(ast.AstExpr.CpuIdEdx _ _) state]
    [(ast.AstExpr.Xgetbv _) state]
    [(ast.AstExpr.Syscall _) state]
    [(ast.AstExpr.ForOwnedState _) state]
    [(ast.AstExpr.ForOwnedStep _) state]
    [_
      (let
        [next : LintCopyOnUpdateState state]
        (begin
          (ast.ast-expr-children-for-each
            (ast.ast-node-get node-id)
            lint-copy-on-update-child!
            ast.ast-child-unit
            ast.ast-child-unit
            ast.ast-child-unit
            next
            span)
          next))]))

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
      (lint-copy-on-update-collect-structs-in-decl (deref inner) shapes)]
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
  (match decl
    [(ast.AstDecl.Def decl-meta _ _ body)
      (__tl-project-field
        (lint-copy-on-update-expr
          body
          (LintCopyOnUpdateState shapes (lint-copy-on-update-locals-empty) acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.DefFn decl-meta _ params _ body _)
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
    [(ast.AstDecl.DefMacro decl-meta _ params _ body)
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
    [(ast.AstDecl.Test _ body _ _)
      (__tl-project-field
        (lint-copy-on-update-expr
          body
          (LintCopyOnUpdateState shapes (lint-copy-on-update-locals-empty) acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.Unsafe inner)
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
    [(ast.AstDeclListStep.Nil) acc]
    [(ast.AstDeclListStep.Cons decl rest)
      (lint-copy-on-update-structs-in-decl-list
        rest
        (owned_view.compiler-owned-shared-view shapes)
        (lint-copy-on-update-structs-in-decl decl shapes acc))]))

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

(define (lint-single-element-array-expr-list-count
  [exprs : (& exprs ast.AstExprList)]) : i64
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
  (string.eq name "__tl_make-array"))

(define (lint-single-element-array-ref-callee? [name : String]) : bool
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
      [(ast.AstLetBinding.Binding name maybe-ty init)
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
      [(ast.AstResourceBinding.Binding name init cleanup _)
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
  (match expr
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
        (= (lint-single-element-array-expr-list-count args) 2))
        (lint-prefer-dynamic-array-literal-int-value
          (ast.ast-node-get (ast.ast-expr-list-get (& args) 1 0)))
        -1)]
    [_ -1]))

(define (lint-prefer-dynamic-array-literal-var?
  [expr : ast.AstExpr]
  [name : String]) : bool
  (match expr
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
    [(ast.AstExpr.Spanned inner _)
      (lint-prefer-dynamic-array-literal-set-at?
        (ast.ast-node-get inner)
        name
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
        (not (lint-prefer-dynamic-array-literal-value-uses-name? value name)))]
    [(ast.AstExpr.Call func args)
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
        (= (lint-single-element-array-expr-list-count exprs) (+ length 1))
        (not
          (and
            (= length 2)
            (lint-prefer-dynamic-array-literal-first-write-bare-var?
              (ast.ast-node-get (ast.ast-expr-list-get (& exprs) 0 0))
              (owned_view.compiler-owned-shared-view name))))
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
                    name
                    (lint-no-effect-span-id init))
                  state.findings))
              state)]
          (lint-prefer-dynamic-array-literals-in-let-bindings-at
            bindings
            body
            next
            (+ index 1)))])))

;; AstExpr child schema hook: walk an expression child, threading `state`.
(defmacro (lint-single-element-array-child! [state : Expr] [child : Expr]) : Expr
  `(set! ,state (lint-single-element-array-expr ,child ,state)))

(define (lint-single-element-array-children
  [node-id : i64]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  (let
    [next : LintSingleElementArrayState state]
    (begin
      (ast.ast-expr-children-for-each
        (ast.ast-node-get node-id)
        lint-single-element-array-child!
        ast.ast-child-unit
        ast.ast-child-unit
        ast.ast-child-unit
        next)
      next)))

(define (lint-single-element-array-expr
  [node-id : i64]
  [state : LintSingleElementArrayState]) : LintSingleElementArrayState
  ;; The arms below track candidate cells and their uses, bind names and skip
  ;; quoted syntax; every other variant's children are walked through the
  ;; AstExpr child schema.
  (match (ast.ast-node-get node-id)
    [(ast.AstExpr.Var name)
      (lint-single-element-array-note-var state (ci.intern-str name))]
    [(ast.AstExpr.Call func args)
      (let
        [callee : String
          (lint-single-element-array-callee-name (ast.ast-node-get func))]
        [after-func : LintSingleElementArrayState
          (lint-single-element-array-expr func state)]
        (cond
          [(lint-single-element-array-ref-callee?
              (owned_view.compiler-owned-shared-view callee))
            (lint-single-element-array-call-ref args after-func)]
          [(lint-single-element-array-set-callee? callee)
            (lint-single-element-array-call-set args after-func)]
          [else (lint-single-element-array-expr-list args after-func)]))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
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
    [(ast.AstExpr.ArrayRef array index)
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
    [(ast.AstExpr.ArraySet array index value)
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
    [(ast.AstExpr.ArrayTake array live index)
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
    [(ast.AstExpr.FixedArrayTake array index)
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
    [(ast.AstExpr.ForOwnedState payload)
      (lint-single-element-array-expr
        (ast.ast-for-owned-state-body (& payload))
        (lint-single-element-array-expr
          (ast.ast-for-owned-state-source (& payload))
          state))]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (lint-single-element-array-expr
          (ast.ast-for-owned-step-body (& payload))
          (if (>= expected-type 0)
            (lint-single-element-array-expr expected-type state)
            state)))]
    [(ast.AstExpr.Set target value)
      (lint-single-element-array-expr
        value
        (lint-single-element-array-note-var state (ci.intern-str target)))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-single-element-array-expr-list
            body
            (lint-single-element-array-resource-bindings bindings state))])]
    [(ast.AstExpr.Quote _) state]
    [(ast.AstExpr.Quasiquote _) state]
    [_ (lint-single-element-array-children node-id state)]))

(define (lint-single-element-array-cells-in-decl
  [decl : ast.AstDecl]
  [acc : LintFindings]) : LintFindings
  (match decl
    [(ast.AstDecl.Def decl-meta _ _ body)
      (lint-single-element-array-finalize-state
        (lint-single-element-array-expr
          body
          (LintSingleElementArrayState
            (lint-single-element-array-candidates-empty)
            acc)))]
    [(ast.AstDecl.DefFn decl-meta _ params _ body _)
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
    [(ast.AstDecl.Test _ body _ _)
      (lint-single-element-array-finalize-state
        (lint-single-element-array-expr
          body
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
  [items : (& items LintPendingAssignmentList)]
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
    [found : i64 (lint-pending-assignment-index items name 0)]
    (if (< found 0)
      LintMaybePendingAssignment.No
      (LintMaybePendingAssignment.Some
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
  (let
    [next : LintUnusedAssignmentState state]
    (begin
      (ast.ast-expr-list-fold
        exprs
        ast.ast-fold-seq
        unit
        lint-unused-assignment-child!
        next)
      next)))

(define (lint-unused-assignment-note-reads-resource-bindings
  [bindings : ast.AstResourceBindingList]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (let
    [next : LintUnusedAssignmentState state]
    (begin
      (ast.ast-resource-binding-list-fold
        bindings
        ast.ast-fold-seq
        unit
        lint-unused-assignment-child!
        next)
      next)))

;; AstExpr child schema hook: note the reads of an expression child, threading
;; `state`.
(defmacro (lint-unused-assignment-child! [state : Expr] [child : Expr]) : Expr
  `(set! ,state (lint-unused-assignment-note-reads ,child ,state)))

(define (lint-unused-assignment-note-reads-children
  [expr : ast.AstExpr]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  (let
    [next : LintUnusedAssignmentState state]
    (begin
      (ast.ast-expr-children-for-each
        expr
        lint-unused-assignment-child!
        ast.ast-child-unit
        ast.ast-child-unit
        ast.ast-child-unit
        next)
      next)))

;; Calls, branches, loops and binding forms end the straight-line stretch in
;; which a pending assignment can still be overwritten unread.
(define (lint-unused-assignment-clears-pending? [expr : (& expr ast.AstExpr)]) : bool
  (match expr
    [(ast.AstExpr.Call _ _) true]
    [(ast.AstExpr.If _ _ _) true]
    [(ast.AstExpr.Let _) true]
    [(ast.AstExpr.Lambda _) true]
    [(ast.AstExpr.While _ _) true]
    [(ast.AstExpr.Match _) true]
    [(ast.AstExpr.Foreach _) true]
    [(ast.AstExpr.SpmdReduce _) true]
    [(ast.AstExpr.SpmdScan _) true]
    [(ast.AstExpr.SpmdCompact _) true]
    [_ false]))

(define (lint-unused-assignment-note-reads
  [node-id : i64]
  [state : LintUnusedAssignmentState]) : LintUnusedAssignmentState
  ;; The arms below read names, skip quoted syntax and read only some
  ;; for-owned slots; every other variant reads its children through the
  ;; AstExpr child schema.
  (match (ast.ast-node-get node-id)
    [(ast.AstExpr.Var name) (lint-unused-assignment-read-id state name)]
    [(ast.AstExpr.ForOwnedState payload)
      (lint-unused-assignment-clear-pending
        (lint-unused-assignment-note-reads
          (ast.ast-for-owned-state-body (& payload))
          (lint-unused-assignment-note-reads
            (ast.ast-for-owned-state-source (& payload))
            state)))]
    [(ast.AstExpr.ForOwnedStep payload)
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
    [(ast.AstExpr.Quote _) state]
    [(ast.AstExpr.Quasiquote _) state]
    [_
      (let
        [expr : ast.AstExpr (ast.ast-node-get node-id)]
        [clears-pending : bool
          (lint-unused-assignment-clears-pending? (& expr))]
        [after-reads : LintUnusedAssignmentState
          (lint-unused-assignment-note-reads-children expr state)]
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
      [(ast.AstLetBinding.Binding name _ init)
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
    [(ast.AstExpr.Spanned inner-box inner-span)
      (lint-unused-assignment-expr inner-box state inner-span)]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-unused-assignment-let bindings body state span)])]
    [(ast.AstExpr.Begin exprs) (lint-unused-assignment-expr-list exprs state)]
    [(ast.AstExpr.Unsafe exprs) (lint-unused-assignment-expr-list exprs state)]
    [(ast.AstExpr.WithRegion _ body)
      (lint-unused-assignment-expr-list body state)]
    [(ast.AstExpr.WithScratch body)
      (lint-unused-assignment-expr-list body state)]
    [(ast.AstExpr.WithEscape scratch body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads scratch state))]
    [(ast.AstExpr.InArena arena body)
      (lint-unused-assignment-expr-list
        body
        (lint-unused-assignment-note-reads arena state))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (lint-unused-assignment-expr-list
            body
            (lint-unused-assignment-note-reads-resource-bindings bindings state))])]
    [(ast.AstExpr.Set target value)
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
    [(ast.AstDecl.Def decl-meta _ _ body)
      (__tl-project-field
        (lint-unused-assignment-expr
          body
          (lint-unused-assignment-state-empty (lint-name-set-empty) acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.DefFn decl-meta _ params _ body _)
      (__tl-project-field
        (lint-unused-assignment-expr
          body
          (lint-unused-assignment-state-empty
            (lint-param-list-add-locals params (lint-name-set-empty))
            acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.DefMacro decl-meta _ params _ body)
      (__tl-project-field
        (lint-unused-assignment-expr
          body
          (lint-unused-assignment-state-empty
            (lint-macro-param-list-add-locals params (lint-name-set-empty))
            acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.Test _ body _ _)
      (__tl-project-field
        (lint-unused-assignment-expr
          body
          (lint-unused-assignment-state-empty (lint-name-set-empty) acc)
          (lint-no-span))
        findings)]
    [(ast.AstDecl.Unsafe inner)
      (lint-unused-assignments-in-decl (ast.ast-decl-box-shared-view inner) acc)]
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
        (lint-unused-unsafe-unknown-root? root lint-unused-unsafe-unknown-roots)))
      (LintUnusedUnsafeExactLookup.Unknown)
      (lint-unused-unsafe-exact-name-lookup-from name facts false false 0))))

(define (lint-unused-unsafe-note-value-name!
  [state : LintUnusedVariableState]
  [name : String]) : unit
  (match (lint-unused-unsafe-exact-name-lookup
    (owned_view.compiler-owned-shared-view state)
    (owned_view.compiler-owned-shared-view name)
    (unsafe
      (ptr-read (ptr-addr-of lint-unused-unsafe-exact-names))))
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
      (lint-unused-variable-add-local-name-case state name found.span)
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
      (LintNameCaseLocalScan state 0)
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
      (lint-name-case-pattern-list (deref items) source cursor limit findings)]
    [(ast.AstPattern.Array items)
      (lint-name-case-pattern-list (deref items) source cursor limit findings)]
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
          (deref items)
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
        (lint-no-effect-span-id body))]
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
        (ast.ast-decl-list-box-shared-view body)
        state)]
    [(ast.AstDecl.Unsafe inner)
      (lint-name-case-in-decl (ast.ast-decl-box-shared-view inner) state)]
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

(define (lint-redundant-function-name-generated-head
  [args : (& args ast.AstExprList)]) : String
  (if (= args.len 0)
    ""
    (match (ast.ast-expr-unspan
      (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0)))
      [(ast.AstExpr.Call fn-head _)
        (lint-redundant-function-name-callee (ast.ast-node-get fn-head))]
      [_ ""])))

(define (lint-redundant-function-name-literal-module
  [args : (& args ast.AstExprList)]) : String
  (if (= args.len 0)
    ""
    (match (ast.ast-expr-unspan
      (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0)))
      [(ast.AstExpr.Var name) (lint-module-default-alias (ci.intern-str name))]
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
        (lint-no-effect-span-id body))]
    [(ast.AstDecl.DefMacro decl-meta name _ _ body)
      (lint-redundant-function-name-macro-expr
        (ast.ast-node-get body)
        (lint-redundant-function-name-add
          state
          (ci.intern-qualified-base name)
          (lint-no-effect-span-id body)))]
    [(ast.AstDecl.Unsafe inner)
      (lint-redundant-function-name-decl (deref inner) state)]
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
            state.findings)
          state.findings)))))

(define (lint-unused-variable-param-bindings
  [params : (& params ast.AstParamList)]
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
  [params : (& params ast.AstMacroParamList)]
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
          (ast.ast-type-list-box-shared-view args)
          state))]
    [(ast.AstType.CFunc signature _)
      (lint-unused-variable-type (ast.ty-node-get signature) state)]
    [(ast.AstType.Tuple items)
      (lint-unused-variable-type-list
        (ast.ast-type-list-box-shared-view items)
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
        (ast.ast-lifetime-list-box-shared-view lifetimes)
        state)]
    [(ast.AstType.StructArgs _ lifetimes)
      (lint-unused-variable-lifetime-list
        (ast.ast-lifetime-list-box-shared-view lifetimes)
        state)]
    [(ast.AstType.Var name) (lint-unused-variable-read-id state name)]
    [(ast.AstType.VarArgs name lifetimes)
      (lint-unused-variable-lifetime-list
        (ast.ast-lifetime-list-box-shared-view lifetimes)
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
      [(ast.AstLetBinding.Binding _ maybe-ty init)
        (lint-unused-variable-quasiquote-let-bindings-at
          bindings
          (lint-unused-variable-quasiquote-expr
            init
            (lint-unused-variable-maybe-type maybe-ty state))
          (+ index 1))])))

;; AstExpr child schema hooks for template syntax: walk an expression child as
;; template syntax and a type child for the type bindings it names, threading
;; `state`.
(defmacro (lint-unused-variable-quasiquote-child! [state : Expr] [child : Expr]) : Expr
  `(set! ,state (lint-unused-variable-quasiquote-expr ,child ,state)))

(defmacro (lint-unused-variable-quasiquote-type-id-child!
  [state : Expr]
  [ty-id : Expr]) : Expr
  `(set! ,state (lint-unused-variable-type (ast.ty-node-get ,ty-id) ,state)))

(define (lint-unused-variable-quasiquote-expr
  [node-id : i64]
  [state : LintUnusedVariableState]) : LintUnusedVariableState
  ;; The arms below walk unquoted code as code, skip nested quoted syntax and
  ;; walk a type operand before its expression; every other variant's
  ;; expression and type-id children are walked through the AstExpr child
  ;; schema. Quoted type operands substitute type bindings during macro
  ;; expansion.
  (match (ast.ast-node-get node-id)
    [(ast.AstExpr.Unquote inner)
      (lint-unused-variable-expr inner state (lint-no-effect-span-id inner))]
    [(ast.AstExpr.UnquoteSplicing inner)
      (lint-unused-variable-expr inner state (lint-no-effect-span-id inner))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-unused-variable-quasiquote-expr
            body
            (lint-unused-variable-quasiquote-let-bindings bindings state))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda params ret body)
          (lint-unused-variable-quasiquote-expr
            body
            (lint-unused-variable-maybe-type
              ret
              (lint-unused-variable-param-types params state)))])]
    [(ast.AstExpr.Ann inner ty-id)
      (lint-unused-variable-quasiquote-expr
        inner
        (lint-unused-variable-type (ast.ty-node-get ty-id) state))]
    [(ast.AstExpr.Cast inner ty-id)
      (lint-unused-variable-quasiquote-expr
        inner
        (lint-unused-variable-type (ast.ty-node-get ty-id) state))]
    [(ast.AstExpr.PtrCast ptr ty-id)
      (lint-unused-variable-quasiquote-expr
        ptr
        (lint-unused-variable-type (ast.ty-node-get ty-id) state))]
    [(ast.AstExpr.IntToPtr value ty-id)
      (lint-unused-variable-quasiquote-expr
        value
        (lint-unused-variable-type (ast.ty-node-get ty-id) state))]
    [(ast.AstExpr.MacroExpansion _ _ _) state]
    [(ast.AstExpr.Quote _) state]
    [(ast.AstExpr.Quasiquote _) state]
    [(ast.AstExpr.ForOwnedState _) state]
    [(ast.AstExpr.ForOwnedStep _) state]
    [_
      (let
        [next : LintUnusedVariableState state]
        (begin
          (ast.ast-expr-children-for-each
            (ast.ast-node-get node-id)
            lint-unused-variable-quasiquote-child!
            lint-unused-variable-quasiquote-type-id-child!
            ast.ast-child-unit
            ast.ast-child-unit
            next)
          next))]))

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
              init
              after-ty
              (lint-no-effect-span-id init))]
          [text : String (ci.intern-str name)]
          [found : LintSourceNameSpan
            (lint-source-name-span-from
              state.source
              (owned_view.compiler-owned-shared-view text)
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
        [start : i64
          (lint-source-span-start-index
            (owned_view.compiler-owned-shared-view state.source)
            span)]
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
      [(ast.AstResourceBinding.Binding name init cleanup _)
        (let
          [text : String (ci.intern-str name)]
          [init-span : ast.AstSourceSpan (lint-no-effect-span-id init)]
          [cleanup-span : ast.AstSourceSpan (lint-no-effect-span-id cleanup)]
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
    [start : i64
      (lint-source-span-start-index
        (owned_view.compiler-owned-shared-view state.source)
        span)]
    (lint-unused-variable-match-arms-at
      (& arms)
      state
      (if (< start 0)
        0
        start)
      0)))

(define (lint-match-body-source-id [body : i64]) : i64
  (match (ast.ast-node-get body)
    [(ast.AstExpr.Spanned inner-box _)
      (match (ast.ast-node-get inner-box)
        [(ast.AstExpr.Spanned _ _) inner-box]
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
      [(ast.AstMatchArm.Arm pattern body)
        (let
          [body-source-id : i64 (lint-match-body-source-id body)]
          [body-span : ast.AstSourceSpan
            (lint-no-effect-span-id body-source-id)]
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
        params
        (owned_view.compiler-owned-shared-view state.source)
        cursor
        span
        true)]
    [with-cases : LintUnusedVariableState
      (lint-unused-variable-add-binding-name-cases
        state
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

;; AstExpr child schema hooks: walk an expression child under the enclosing
;; span and a type-id child, threading `state`.
(defmacro (lint-unused-variable-child!
  [state : Expr]
  [span : Expr]
  [child : Expr]) : Expr
  `(set! ,state (lint-unused-variable-expr ,child ,state ,span)))

(defmacro (lint-unused-variable-type-id-child!
  [state : Expr]
  [_span : Expr]
  [ty-id : Expr]) : Expr
  `(set! ,state (lint-unused-variable-type (ast.ty-node-get ,ty-id) ,state)))

(define (lint-unused-variable-children
  [node-id : i64]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  (let
    [next : LintUnusedVariableState state]
    (begin
      (ast.ast-expr-children-for-each
        (ast.ast-node-get node-id)
        lint-unused-variable-child!
        lint-unused-variable-type-id-child!
        ast.ast-child-unit
        ast.ast-child-unit
        next
        span)
      next)))

(define (lint-unused-variable-expr
  [node-id : i64]
  [state : LintUnusedVariableState]
  [span : ast.AstSourceSpan]) : LintUnusedVariableState
  ;; The arms below read names, open binding scopes, walk list items without
  ;; an enclosing span, track unsafe blocks and walk quoted syntax as a
  ;; template; every other variant's expression and type-id children are
  ;; walked through the AstExpr child schema.
  (match (ast.ast-node-get node-id)
    [(ast.AstExpr.Spanned inner inner-span)
      (lint-unused-variable-expr inner state inner-span)]
    [(ast.AstExpr.Var name)
      (begin
        (lint-unused-unsafe-note-value-name!
          (owned_view.compiler-owned-shared-view state)
          (ci.intern-str name))
        (lint-unused-variable-read-var-id state name))]
    [(ast.AstExpr.Call func args)
      (begin
        (lint-unused-unsafe-note-call-target!
          (owned_view.compiler-owned-shared-view state)
          (ast.ast-node-get func))
        (lint-unused-variable-expr-list
          args
          (lint-unused-variable-expr func state span)))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (lint-unused-variable-let bindings body state span)])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda params ret body)
          (lint-unused-variable-lambda params ret body state span)])]
    [(ast.AstExpr.Tuple exprs) (lint-unused-variable-expr-list exprs state)]
    [(ast.AstExpr.Array exprs) (lint-unused-variable-expr-list exprs state)]
    [(ast.AstExpr.DynArray exprs) (lint-unused-variable-expr-list exprs state)]
    [(ast.AstExpr.ForOwnedState payload)
      (lint-unused-variable-expr
        (ast.ast-for-owned-state-body (& payload))
        (lint-unused-variable-expr
          (ast.ast-for-owned-state-source (& payload))
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
          [(ast.AstExpr.Var name)
            (lint-unused-variable-index-scope name body read-state span)]
          [_ (lint-unused-variable-expr body read-state span)]))]
    [(ast.AstExpr.Begin exprs) (lint-unused-variable-expr-list exprs state)]
    [(ast.AstExpr.Unsafe exprs)
      (begin
        (lint-unused-unsafe-block-push!
          span
          (lint-expr-list-requires-enclosing-unsafe? exprs))
        (lint-unused-unsafe-finish-state
          (lint-unused-variable-expr-list exprs state)))]
    [(ast.AstExpr.Cast _ _)
      (begin
        (lint-unused-unsafe-block-mark-unknown!)
        (lint-unused-variable-children node-id state span))]
    [(ast.AstExpr.Borrow _ lifetime-id _)
      (lint-unused-variable-children
        node-id
        (lint-unused-variable-borrow-lifetime
          (ast.ast-borrow-lifetime-from-id lifetime-id)
          state)
        span)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (lint-unused-variable-match-arms
            arms
            (lint-unused-variable-expr scrutinee state span)
            span)])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach index index-ty start end body)
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
              span))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce _ index index-ty start end init value)
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
    [(ast.AstExpr.SpmdCompact compact-box)
      (match (__tl-box-place compact-box)
        [(ast.AstSpmdCompact.Compact
            index
            index-ty
            start
            end
            slot
            slot-ty
            init
            keep
            body)
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
                  [limit : i64
                    (lint-source-span-end-index
                      (owned_view.compiler-owned-shared-view state.source)
                      span)]
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
    [(ast.AstExpr.WithRegion _ body)
      (lint-unused-variable-expr-list body state)]
    [(ast.AstExpr.WithEscape scratch body)
      (lint-unused-variable-expr-list
        body
        (lint-unused-variable-expr scratch state span))]
    [(ast.AstExpr.WithScratch body) (lint-unused-variable-expr-list body state)]
    [(ast.AstExpr.InArena arena body)
      (lint-unused-variable-expr-list
        body
        (lint-unused-variable-expr arena state span))]
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
    [(ast.AstExpr.Quote _) state]
    [(ast.AstExpr.Quasiquote inner)
      (lint-unused-variable-quasiquote-expr inner state)]
    [(ast.AstExpr.BracketClause items)
      (lint-unused-variable-expr-list items state)]
    [(ast.AstExpr.ProgramArgv)
      (begin
        (lint-unused-unsafe-block-mark-unknown!)
        state)]
    [(ast.AstExpr.ProgramEnvp)
      (begin
        (lint-unused-unsafe-block-mark-unknown!)
        state)]
    [(ast.AstExpr.Syscall args) (lint-unused-variable-expr-list args state)]
    [_ (lint-unused-variable-children node-id state span)]))

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
    [body-span : ast.AstSourceSpan (lint-no-effect-span-id body)]
    [cursor : i64
      (lint-unused-variable-decl-param-cursor
        (owned_view.compiler-owned-shared-view source)
        prefix
        (ci.intern-str name)
        body-span)]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-param-bindings
        params
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
        (owned_view.compiler-owned-shared-view source)
        prefix
        (ci.intern-str name)
        body-span)]
    [built : LintUnusedVariableBindingBuild
      (lint-unused-variable-macro-param-bindings
        params
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
    [(ast.AstDecl.Def decl-meta _ maybe-ty body)
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
    [(ast.AstDecl.Test _ body _ _)
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
            [_ (lint-walk-discarded-nonsequence-expr expr-id threshold acc)]))]
      [(ast.AstExpr.Begin _) (lint-walk-expr expr threshold acc)]
      [(ast.AstExpr.WithRegion _ _) (lint-walk-expr expr threshold acc)]
      [(ast.AstExpr.WithEscape _ _) (lint-walk-expr expr threshold acc)]
      [(ast.AstExpr.WithScratch _) (lint-walk-expr expr threshold acc)]
      [(ast.AstExpr.InArena _ _) (lint-walk-expr expr threshold acc)]
      [(ast.AstExpr.WithResource _) (lint-walk-expr expr threshold acc)]
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
  [outer : (& outer ast.AstLetBindingList)]
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
              exprs
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
        exprs
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

;; AstExpr child schema hook: walk an expression child, threading `acc`.
(defmacro (lint-walk-child! [threshold : Expr] [acc : Expr] [child : Expr]) : Expr
  `(set! ,acc (lint-walk-expr (ast.ast-node-get ,child) ,threshold ,acc)))

;: Walk `expr`, collecting active lint findings while recursing into all
;: sub-expressions. Spanned expressions pass their wrapper span to rules that
;: need source locations.
(define (lint-walk-expr
  [expr : ast.AstExpr]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  ;; The arms below apply the rules and walk sequences and quoted syntax;
  ;; every other variant's children are walked through the AstExpr child
  ;; schema.
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
              exprs
              threshold
              (lint-add-single-begin exprs span acc))]
          [_ (lint-walk-expr inner threshold acc)]))]
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
        exprs
        threshold
        (lint-add-single-begin exprs (lint-no-span) acc))]
    [(ast.AstExpr.Unsafe exprs)
      (lint-walk-plain-sequence-expr-list exprs threshold acc)]
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
    [(ast.AstExpr.Quote _) acc]
    [(ast.AstExpr.Quasiquote _) acc]
    [_
      (let
        [next : LintFindings acc]
        (begin
          (ast.ast-expr-children-for-each
            expr
            lint-walk-child!
            ast.ast-child-unit
            ast.ast-child-unit
            ast.ast-child-unit
            threshold
            next)
          next))]))

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
    [(ast.AstDecl.Test _ body-box _ _)
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
              decls
              with-locals)
            with-locals)]
        (if deprecated-string-concat
          (lint-deprecated-string-concat-scan source with-decls)
          with-decls))]))