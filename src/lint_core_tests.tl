;; lint_core_tests.tl - Lint self-test fixtures and entry split from
;; production lint_core.tl (simplify.md A1, #5169 pattern).
;;
;; Main-less companion imported by src/tests/lint_smoke.tl: it holds the
;; flat-AST lint-test-* fixture helpers, the lint-name-set smoke check, and
;; the compiler-lint-self-test entry. The production module keeps the lint
;; engine, the rule registry, and the source scan passes.
(import stdlib.str_cat_runtime as str_cat)
(import lint_core)
(import stdlib.io)
(import stdlib.string)
(import compiler_ast_types as ast)
(import compiler_intern as ci)

;: Self-test: the nested-`if`-ladder rule and the AST walk.
;: Flat-AST test helpers: the self-test builds exprs with i64-returning
;: constructors; lint-ladder-length / lint-walk-expr take AstExpr, so wrap.
(define (lint-test-ladder-length [e : i64]) : i64
  (lint_core.lint-ladder-length (ast.ast-node-get e)))

(define (lint-test-walk
  [e : i64]
  [threshold : i64]
  [acc : lint_core.LintFindings]) : lint_core.LintFindings
  (lint_core.lint-walk-expr (ast.ast-node-get e) threshold acc))

(define (lint-test-walk-tail
  [e : i64]
  [threshold : i64]
  [acc : lint_core.LintFindings]) : lint_core.LintFindings
  (lint_core.lint-walk-tail-expr (ast.ast-node-get e) threshold acc))

(define (lint-test-var [name : String]) : i64
  (ast.ast-node-push (ast.AstExpr.Var (ci.intern-generated-name name))))

(define (lint-test-expr-list2 [a : i64] [b : i64]) : ast.AstExprList
  (ast.ast-expr-cons a (ast.ast-expr-cons b (ast.ast-expr-list-new))))

(define (lint-test-expr-list3 [a : i64] [b : i64] [c : i64]) : ast.AstExprList
  (ast.ast-expr-cons
    a
    (ast.ast-expr-cons b (ast.ast-expr-cons c (ast.ast-expr-list-new)))))

(define (lint-name-set-smoke-ok?) : bool
  (let
    [empty : lint_core.LintNameSet (lint_core.lint-name-set-empty)]
    [one : lint_core.LintNameSet (lint_core.lint-name-set-add empty "one")]
    [duplicate : lint_core.LintNameSet (lint_core.lint-name-set-add one "one")]
    [two : lint_core.LintNameSet (lint_core.lint-name-set-add duplicate "two")]
    [many0 : lint_core.LintNameSet (lint_core.lint-name-set-add two "three")]
    [many1 : lint_core.LintNameSet (lint_core.lint-name-set-add many0 "four")]
    [many : lint_core.LintNameSet (lint_core.lint-name-set-add many1 "five")]
    (and
      (= (lint_core.lint-name-set-count empty) 0)
      (= (lint_core.lint-name-set-count one) 1)
      (= (lint_core.lint-name-set-count duplicate) 1)
      (= (lint_core.lint-name-set-count many) 5)
      (lint_core.lint-name-set-contains? many "one")
      (lint_core.lint-name-set-contains? many "five")
      (not (lint_core.lint-name-set-contains? many "missing"))
      (string.eq (lint_core.lint-name-set-get many 0) "one")
      (string.eq (lint_core.lint-name-set-get many 4) "five"))))

(define (lint-test-expect-registry-text
  [actual : String]
  [expected : String]
  [failure : String]) : unit
  (unless (string.eq actual expected) (io.panic failure)))

;; Registry metadata has no flat-AST fixture dependency. Keep its exhaustive
;; message/suggestion coverage separate from the expression-walk smoke below.
(define (lint-rule-registry-smoke) : unit
  (begin
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-nested-if-ladder-id))
      "prefer cond (value/guard ladders) or match (variant dispatch)"
      "lint: nested-if-ladder suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message (lint_core.lint-rule-nested-if-ladder-id))
      "nested if-ladder: chain of if/else-if; prefer cond (value/guard ladders) or match (variant dispatch)"
      "lint: nested-if-ladder message should be registered")
    (match (lint_core.lint-rule-find (lint_core.lint-rule-nested-if-ladder-id))
      [(lint_core.LintMaybeRule.Found rule)
        (unless
          (and
            (string.eq rule.rule-id (lint_core.lint-rule-nested-if-ladder-id))
            (string.eq
              rule.message
              (lint_core.lint-rule-nested-if-ladder-message))
            (string.eq
              rule.suggestion
              (lint_core.lint-rule-nested-if-ladder-suggestion)))
          (io.panic
            "lint: nested-if-ladder registry entry should match metadata"))]
      [(lint_core.LintMaybeRule.NotFound)
        (io.panic "lint: nested-if-ladder should be registered")])
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-nested-let-id))
      "merge the nested let bindings into one sequential let"
      "lint: nested-let suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-single-begin-id))
      "remove the begin wrapper"
      "lint: single-begin suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message (lint_core.lint-rule-single-begin-id))
      "single begin: begin with one expression is redundant"
      "lint: single-begin message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion
        (lint_core.lint-rule-return-path-chain-id))
      "prefer early return guards with (return ...)"
      "lint: return-path-chain suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-unit-if-guard-id))
      "prefer when/unless for unit guard branches"
      "lint: unit-if-guard suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-no-effect-id))
      "remove the expression or use its value"
      "lint: no-effect suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message (lint_core.lint-rule-no-effect-id))
      "no-effect expression: value is discarded"
      "lint: no-effect message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-unreachable-code-id))
      "remove the unreachable expression or move it before the terminal expression"
      "lint: unreachable-code suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message (lint_core.lint-rule-unreachable-code-id))
      "unreachable code: expression follows a terminal expression"
      "lint: unreachable-code message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion
        (lint_core.lint-rule-redundant-divergence-padding-id))
      "remove the trailing dead expression and the stale unreachable-code lint allow"
      "lint: redundant-divergence-padding suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message
        (lint_core.lint-rule-redundant-divergence-padding-id))
      "redundant divergence padding: trailing expressions after panic/error are dead"
      "lint: redundant-divergence-padding message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion
        (lint_core.lint-rule-deprecated-string-concat-id))
      "import stdlib/str_cat.tl and use str-cat, or use stdlib/text_buf.tl in accumulation loops"
      "lint: deprecated-string-concat suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-nested-str-cat-id))
      "flatten nested str-cat operands into the outer call"
      "lint: nested-str-cat suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-cascading-and-or-id))
      "flatten same-operator and/or operands, e.g. (and a b c)"
      "lint: cascading-and-or suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion
        (lint_core.lint-rule-transitional-core-macro-qualifier-id))
      (lint_core.lint-rule-transitional-core-macro-qualifier-suggestion)
      "lint: transitional-core-macro-qualifier suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message
        (lint_core.lint-rule-transitional-core-macro-qualifier-id))
      (lint_core.lint-rule-transitional-core-macro-qualifier-message)
      "lint: transitional-core-macro-qualifier message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-unused-import-id))
      "remove the import or prefix an intentionally unused alias with _"
      "lint: unused-import suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message (lint_core.lint-rule-unused-import-id))
      "unused import: imported module alias is never referenced"
      "lint: unused-import message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion
        (lint_core.lint-rule-redundant-import-alias-id))
      "remove the explicit as clause"
      "lint: redundant-import-alias suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message
        (lint_core.lint-rule-redundant-import-alias-id))
      "redundant import alias: dotted module import already binds that alias"
      "lint: redundant-import-alias message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-unused-variable-id))
      "remove the binding or prefix an intentionally unused name with _"
      "lint: unused-variable suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message (lint_core.lint-rule-unused-variable-id))
      "unused variable: parameter or local binding is never used"
      "lint: unused-variable message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion
        (lint_core.lint-rule-single-element-array-cell-id))
      "replace the one-element array cell with Box T, &mut, or an explicit returned value"
      "lint: single-element-array-cell suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message
        (lint_core.lint-rule-single-element-array-cell-id))
      "single-element array scalar cell: prefer Box T, &mut, or return-value refactoring"
      "lint: single-element-array-cell message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion
        (lint_core.lint-rule-prefer-dynamic-array-literal-id))
      "replace the allocation and consecutive array element assignments with a dynamic array literal"
      "lint: prefer-dynamic-array-literal suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message
        (lint_core.lint-rule-prefer-dynamic-array-literal-id))
      "hand-filled dynamic array: prefer (make-array v0 v1 ...)"
      "lint: prefer-dynamic-array-literal message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion (lint_core.lint-rule-unused-unsafe-id))
      "remove the unsafe wrapper"
      "lint: unused-unsafe suggestion should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message (lint_core.lint-rule-unused-unsafe-id))
      "unused unsafe block: body does not require unsafe context"
      "lint: unused-unsafe message should be registered")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-suggestion "unknown-rule")
      ""
      "lint: unknown rule should have no suggestion")
    (lint-test-expect-registry-text
      (lint_core.lint-rule-message "unknown-rule")
      ""
      "lint: unknown rule should have no message")
    (match (lint_core.lint-rule-find "unknown-rule")
      [(lint_core.LintMaybeRule.NotFound) unit]
      [(lint_core.LintMaybeRule.Found _)
        (io.panic "lint: unknown rule should not be found")])
    unit))

(define (compiler-lint-self-test) : i64
  (let
    [vx : i64 (lint-test-var "x")]
    [vy : i64 (lint-test-var "y")]
    [vz : i64 (lint-test-var "z")]
    [one : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 1)))]
    [unit-expr : i64
      (ast.ast-node-push (ast.AstExpr.Literal ast.AstLiteral.Unit))]
    [ladder3 : i64
      (ast.ast-expr-if
        vx
        one
        (ast.ast-expr-if vx one (ast.ast-expr-if vx one one)))]
    [ladder2 : i64 (ast.ast-expr-if vx one (ast.ast-expr-if vx one one))]
    [ladder4 : i64
      (ast.ast-expr-if
        vx
        one
        (ast.ast-expr-if
          vx
          one
          (ast.ast-expr-if vx one (ast.ast-expr-if vx one one))))]
    [return-chain3 : i64
      (ast.ast-expr-if
        vx
        (ast.ast-expr-if vx (ast.ast-expr-if vx one one) one)
        one)]
    [return-one : i64 (ast.ast-expr-return one)]
    [break-expr : i64 (ast.ast-expr-break)]
    [continue-expr : i64 (ast.ast-expr-continue)]
    [all-return-ladder3 : i64
      (ast.ast-expr-if
        vx
        return-one
        (ast.ast-expr-if
          vx
          return-one
          (ast.ast-expr-if vx return-one return-one)))]
    [all-loop-exit-ladder3 : i64
      (ast.ast-expr-if
        vx
        break-expr
        (ast.ast-expr-if
          vx
          continue-expr
          (ast.ast-expr-if vx break-expr continue-expr)))]
    [guard-ladder3 : i64
      (ast.ast-expr-if
        vx
        return-one
        (ast.ast-expr-if
          vx
          return-one
          (ast.ast-expr-if vx return-one unit-expr)))]
    [ambiguous-ladder3 : i64
      (ast.ast-expr-if
        vx
        return-one
        (ast.ast-expr-if vx one (ast.ast-expr-if vx one one)))]
    [not-vx : i64 (ast.ast-expr-unary (ast.AstUnOp.Not) vx)]
    [set-ok-false : i64
      (ast.ast-expr-set-id
        (ci.intern-generated-name "ok")
        (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Bool false))))]
    [unit-then-guard : i64 (ast.ast-expr-if vx unit-expr return-one)]
    [unit-else-guard : i64 (ast.ast-expr-if vx return-one unit-expr)]
    [unit-value-guard : i64 (ast.ast-expr-if vx one unit-expr)]
    [unit-not-set-guard : i64 (ast.ast-expr-if not-vx unit-expr set-ok-false)]
    [nested : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            unit-expr
            (ast.ast-expr-cons ladder3 (ast.ast-expr-list-new)))))]
    [in-let : i64
      (ast.ast-expr-let
        (ast.ast-let-binding-cons
          (ast.ast-let-binding-id
            (ci.intern-generated-name "y")
            (ast.AstMaybeType.No)
            ladder3)
          (ast.ast-let-binding-list-new))
        vx)]
    [nested-a-id : i64 (ci.intern-generated-name "a")]
    [outer-let-bindings : ast.AstLetBindingList
      (ast.ast-let-binding-cons
        (ast.ast-let-binding-id nested-a-id (ast.AstMaybeType.No) one)
        (ast.ast-let-binding-list-new))]
    [inner-let-bindings : ast.AstLetBindingList
      (ast.ast-let-binding-cons
        (ast.ast-let-binding-id
          (ci.intern-generated-name "b")
          (ast.AstMaybeType.No)
          vx)
        (ast.ast-let-binding-list-new))]
    [shadowing-let-bindings : ast.AstLetBindingList
      (ast.ast-let-binding-cons
        (ast.ast-let-binding-id nested-a-id (ast.AstMaybeType.No) one)
        (ast.ast-let-binding-list-new))]
    [nested-let : i64
      (ast.ast-expr-let
        outer-let-bindings
        (ast.ast-expr-let inner-let-bindings vx))]
    [shadowing-nested-let : i64
      (ast.ast-expr-let
        outer-let-bindings
        (ast.ast-expr-let shadowing-let-bindings vx))]
    [begin-inner-let : i64
      (ast.ast-expr-let
        outer-let-bindings
        (ast.ast-node-push
          (ast.AstExpr.Begin
            (ast.ast-expr-cons
              (ast.ast-expr-let inner-let-bindings vx)
              (ast.ast-expr-cons vx (ast.ast-expr-list-new))))))]
    [spanned : i64 (ast.ast-expr-spanned ladder3 (ast.ast-source-span 7 3 9 4))]
    [spanned-nested-let : i64
      (ast.ast-expr-spanned nested-let (ast.ast-source-span 11 5 15 6))]
    [and-callee : i64 (lint-test-var "and")]
    [or-callee : i64 (lint-test-var "or")]
    [core-and-callee : i64 (lint-test-var "core/and")]
    [core-cond-dotted-callee : i64 (lint-test-var "core.cond")]
    [and-yz : i64 (ast.ast-expr-call and-callee (lint-test-expr-list2 vy vz))]
    [and-xy : i64 (ast.ast-expr-call and-callee (lint-test-expr-list2 vx vy))]
    [or-yz : i64 (ast.ast-expr-call or-callee (lint-test-expr-list2 vy vz))]
    [or-xy : i64 (ast.ast-expr-call or-callee (lint-test-expr-list2 vx vy))]
    [and-cascade : i64
      (ast.ast-expr-call and-callee (lint-test-expr-list2 vx and-yz))]
    [or-cascade : i64
      (ast.ast-expr-call or-callee (lint-test-expr-list2 or-xy vz))]
    [flat-and : i64
      (ast.ast-expr-call and-callee (lint-test-expr-list3 vx vy vz))]
    [mixed-and-or : i64
      (ast.ast-expr-call and-callee (lint-test-expr-list2 vx or-yz))]
    [core-and-cascade : i64
      (ast.ast-expr-call core-and-callee (lint-test-expr-list2 vx and-yz))]
    [core-cond-dotted-call : i64
      (ast.ast-expr-call core-cond-dotted-callee (ast.ast-expr-list-new))]
    [spanned-core-cond-dotted-call : i64
      (ast.ast-expr-spanned
        core-cond-dotted-call
        (ast.ast-source-span 22 7 22 18))]
    [double-and-cascade : i64
      (ast.ast-expr-call and-callee (lint-test-expr-list2 and-xy and-yz))]
    [spanned-and-cascade : i64
      (ast.ast-expr-spanned and-cascade (ast.ast-source-span 21 7 21 30))]
    [discarded-add : i64 (ast.ast-expr-binary (ast.AstBinOp.Add) one vx)]
    [discarded-cast : i64 (ast.ast-expr-cast one (ast.AstType.I64))]
    [discarded-call : i64
      (ast.ast-expr-call (lint-test-var "side-effect?") (ast.ast-expr-list-new))]
    [no-effect-literal-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons one (ast.ast-expr-cons vx (ast.ast-expr-list-new)))))]
    [no-effect-var-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons vx (ast.ast-expr-cons one (ast.ast-expr-list-new)))))]
    [no-effect-add-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            discarded-add
            (ast.ast-expr-cons vx (ast.ast-expr-list-new)))))]
    [no-effect-cast-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            discarded-cast
            (ast.ast-expr-cons vx (ast.ast-expr-list-new)))))]
    [no-effect-tail-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            unit-expr
            (ast.ast-expr-cons one (ast.ast-expr-list-new)))))]
    [no-effect-clean-call-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            discarded-call
            (ast.ast-expr-cons vx (ast.ast-expr-list-new)))))]
    [no-effect-clean-mutation-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            set-ok-false
            (ast.ast-expr-cons vx (ast.ast-expr-list-new)))))]
    [no-effect-unsafe-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Unsafe
          (ast.ast-expr-cons one (ast.ast-expr-cons vx (ast.ast-expr-list-new)))))]
    [spanned-no-effect-var : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            (ast.ast-expr-spanned vx (ast.ast-source-span 31 9 31 10))
            (ast.ast-expr-cons one (ast.ast-expr-list-new)))))]
    [spanned-unreachable-var : i64
      (ast.ast-expr-spanned vx (ast.ast-source-span 41 9 41 10))]
    [unreachable-return-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            return-one
            (ast.ast-expr-cons
              spanned-unreachable-var
              (ast.ast-expr-cons vy (ast.ast-expr-list-new))))))]
    [panic-call : i64
      (ast.ast-expr-call
        (lint-test-var "panic")
        (ast.ast-expr-cons one (ast.ast-expr-list-new)))]
    [spanned-panic-call : i64
      (ast.ast-expr-spanned panic-call (ast.ast-source-span 43 9 43 24))]
    [qualified-panic-call : i64
      (ast.ast-expr-call
        (lint-test-var "io.panic")
        (ast.ast-expr-cons one (ast.ast-expr-list-new)))]
    [spanned-qualified-panic-call : i64
      (ast.ast-expr-spanned
        qualified-panic-call
        (ast.ast-source-span 44 9 44 27))]
    [redundant-padding-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            spanned-panic-call
            (ast.ast-expr-cons vx (ast.ast-expr-list-new)))))]
    [qualified-padding-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            spanned-qualified-panic-call
            (ast.ast-expr-cons vx (ast.ast-expr-list-new)))))]
    [clean-panic-tail-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            unit-expr
            (ast.ast-expr-cons spanned-panic-call (ast.ast-expr-list-new)))))]
    [unreachable-panic-unsafe : i64
      (ast.ast-node-push
        (ast.AstExpr.Unsafe
          (ast.ast-expr-cons
            panic-call
            (ast.ast-expr-cons vx (ast.ast-expr-list-new)))))]
    [branch-local-return-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            (ast.ast-expr-if vx return-one return-one)
            (ast.ast-expr-cons vx (ast.ast-expr-list-new)))))]
    [single-begin : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin (ast.ast-expr-cons vx (ast.ast-expr-list-new))))]
    [spanned-single-begin : i64
      (ast.ast-expr-spanned single-begin (ast.ast-source-span 51 3 51 13))]
    [empty-begin : i64
      (ast.ast-node-push (ast.AstExpr.Begin (ast.ast-expr-list-new)))]
    (begin
      (unless
        (lint-name-set-smoke-ok?)
        (io.panic "lint: dense name set empty/one/many/duplicate smoke failed"))
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
        (lint_core.lint-findings-count
          (lint-test-walk
            ladder3
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: 3-deep ladder should be flagged once"))
      (match (lint_core.lint-findings-get
        (lint-test-walk
          ladder3
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (if (and
            (= finding.depth 3)
            (string.eq
              finding.rule-id
              (lint_core.lint-rule-nested-if-ladder-id))
            (string.eq
              finding.message
              (lint_core.lint-rule-nested-if-ladder-value-message)))
            unit
            (io.panic "lint: 3-deep value ladder finding metadata mismatch"))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: 3-deep ladder should produce a finding")])
      (match (lint_core.lint-findings-get
        (lint-test-walk
          guard-ladder3
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (if (and
            (= finding.depth 3)
            (string.eq
              finding.rule-id
              (lint_core.lint-rule-nested-if-ladder-id))
            (string.eq
              finding.message
              (lint_core.lint-rule-nested-if-ladder-guard-message)))
            unit
            (io.panic "lint: guard ladder finding metadata mismatch"))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: guard ladder should produce a finding")])
      (match (lint_core.lint-findings-get
        (lint-test-walk
          ambiguous-ladder3
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (if (and
            (= finding.depth 3)
            (string.eq
              finding.rule-id
              (lint_core.lint-rule-nested-if-ladder-id))
            (string.eq
              finding.message
              (lint_core.lint-rule-nested-if-ladder-message)))
            unit
            (io.panic "lint: ambiguous ladder should keep generic message"))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: ambiguous ladder should produce a finding")])
      ;; a 2-deep ladder is NOT flagged at threshold 3
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            ladder2
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: 2-deep ladder should not be flagged at threshold 3"))
      ;; ... and is flagged at threshold 2, where its length meets the bound.
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk ladder2 2 (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: 2-deep ladder should be flagged at threshold 2"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            all-return-ladder3
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: all-return ladder should not be ladder-flagged"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            all-loop-exit-ladder3
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: break/continue ladder should not be ladder-flagged"))
      ;; return-path chains are only reported in tail contexts, where replacing
      ;; nested failure values with `(return ...)` preserves semantics.
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            return-chain3
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: return-path chain should not flag in a value context"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            return-chain3
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: return-path chain should be flagged once"))
      (match (lint_core.lint-findings-get
        (lint-test-walk-tail
          return-chain3
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (if (string.eq
            finding.rule-id
            (lint_core.lint-rule-return-path-chain-id))
            unit
            (io.panic "lint: return-path chain should report its rule id"))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: return-path chain should produce a finding")])
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            unit-then-guard
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: unit then-branch should be flagged once"))
      (match (lint_core.lint-findings-get
        (lint-test-walk
          unit-else-guard
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (if (string.eq finding.rule-id (lint_core.lint-rule-unit-if-guard-id))
            unit
            (io.panic "lint: unit-if guard should report its rule id"))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: unit-if guard should produce a finding")])
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            unit-value-guard
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: unit-if guard should skip value branches"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            unit-not-set-guard
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: inverted unit set! guard should be flagged"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            nested
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: ladder nested in begin should be flagged once"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            single-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: single begin should be flagged once"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            single-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: tail single begin should be flagged once"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            empty-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: empty begin should not be flagged as single begin"))
      (match (lint_core.lint-findings-get
        (lint-test-walk
          spanned-single-begin
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (let
            [fspan : ast.AstSourceSpan finding.span]
            (if (and
              (= (ast.ast-source-span-start-line fspan) 51)
              (string.eq finding.rule-id (lint_core.lint-rule-single-begin-id)))
              unit
              (io.panic
                "lint: single-begin finding should carry rule id and span")))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: spanned single begin should produce a finding")])
      ;; ... and into let-binding initializers
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            in-let
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: ladder in a let binding should be flagged once"))
      ;; Longer ladders are flagged once at the head with their full depth.
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            ladder4
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: 4-deep ladder should be flagged once"))
      ;; A spanned ladder carries its head wrapper span on the finding.
      (match (lint_core.lint-findings-get
        (lint-test-walk
          spanned
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (let
            [fspan : ast.AstSourceSpan finding.span]
            (if (and
              (= (ast.ast-source-span-start-line fspan) 7)
              (string.eq
                finding.rule-id
                (lint_core.lint-rule-nested-if-ladder-id)))
              unit
              (io.panic
                "lint: spanned ladder finding should carry rule id and span")))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: spanned ladder should produce a finding")])
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            nested-let
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: body-only nested let should be flagged once"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            shadowing-nested-let
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: shadowing nested let should not be flagged"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            begin-inner-let
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: let with nontrivial begin body should not be flagged"))
      (match (lint_core.lint-findings-get
        (lint-test-walk
          spanned-nested-let
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (let
            [fspan : ast.AstSourceSpan finding.span]
            (if (and
              (= (ast.ast-source-span-start-line fspan) 11)
              (string.eq finding.rule-id (lint_core.lint-rule-nested-let-id)))
              unit
              (io.panic
                "lint: nested-let finding should carry rule id and span")))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: spanned nested let should produce a finding")])
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            and-cascade
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: nested and should be flagged once"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            or-cascade
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: nested or should be flagged once"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            flat-and
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: flat and should not be flagged"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            mixed-and-or
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: mixed and/or should not be flagged"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk
            double-and-cascade
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: one maximal and cascade should produce one finding"))
      (match (lint_core.lint-findings-get
        (lint-test-walk
          spanned-and-cascade
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (let
            [fspan : ast.AstSourceSpan finding.span]
            (if (and
              (= (ast.ast-source-span-start-line fspan) 21)
              (= finding.depth 3)
              (string.eq
                finding.rule-id
                (lint_core.lint-rule-cascading-and-or-id))
              (string.eq
                finding.message
                "cascading and: prefer flat n-ary form (and x y z)"))
              unit
              (io.panic "lint: cascading-and-or finding metadata mismatch")))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: spanned and cascade should produce a finding")])
      (match (lint_core.lint-findings-get
        (lint-test-walk
          core-and-cascade
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (if (string.eq
            finding.message
            (str_cat.str-cat
              "cascading and: prefer flat n-ary form ("
              "core/and"
              " x y z)"))
            unit
            (io.panic "lint: core/and cascade should preserve callee spelling"))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: core/and cascade should produce a finding")])
      (match (lint_core.lint-findings-get
        (lint-test-walk
          spanned-core-cond-dotted-call
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (let
            [fspan : ast.AstSourceSpan finding.span]
            (if (and
              (=
                (lint_core.lint-findings-count
                  (lint-test-walk
                    spanned-core-cond-dotted-call
                    (lint_core.lint-default-ladder-threshold)
                    (lint_core.lint-findings-empty)))
                1)
              (= (ast.ast-source-span-start-line fspan) 22)
              (string.eq
                finding.rule-id
                (lint_core.lint-rule-transitional-core-macro-qualifier-id))
              (string.eq
                finding.message
                "transitional core macro qualifier: use cond instead of core.cond"))
              unit
              (io.panic
                "lint: transitional core macro finding metadata mismatch")))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic
            "lint: core.cond call should produce transitional qualifier finding")])
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            no-effect-literal-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: discarded literal should be flagged"))
      (match (lint_core.lint-findings-get
        (lint-test-walk-tail
          spanned-no-effect-var
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (let
            [fspan : ast.AstSourceSpan finding.span]
            (if (and
              (= (ast.ast-source-span-start-line fspan) 31)
              (string.eq finding.rule-id (lint_core.lint-rule-no-effect-id)))
              unit
              (io.panic "lint: no-effect finding should carry rule id and span")))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic
            "lint: discarded variable should produce a no-effect finding")])
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            no-effect-var-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: discarded variable should be flagged"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            no-effect-add-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: discarded arithmetic should be flagged"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            no-effect-cast-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: discarded cast should be flagged"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            no-effect-tail-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: tail expression should not be flagged as no-effect"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            no-effect-clean-call-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: discarded call should not be flagged as no-effect"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            no-effect-clean-mutation-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: discarded mutation should not be flagged as no-effect"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            no-effect-unsafe-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: unsafe block should not be flagged as no-effect"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            unreachable-return-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic
          "lint: return should flag following unreachable expression once"))
      (match (lint_core.lint-findings-get
        (lint-test-walk-tail
          unreachable-return-begin
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (let
            [fspan : ast.AstSourceSpan finding.span]
            (if (and
              (= (ast.ast-source-span-start-line fspan) 41)
              (string.eq
                finding.rule-id
                (lint_core.lint-rule-unreachable-code-id)))
              unit
              (io.panic
                "lint: unreachable-code finding should carry rule id and span")))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: unreachable-code should produce a finding")])
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            unreachable-panic-unsafe
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        2)
        unit
        (io.panic "lint: panic in unsafe should flag unreachable and padding"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            redundant-padding-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        2)
        unit
        (io.panic
          "lint: redundant divergence padding should flag with unreachable"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            qualified-padding-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        2)
        unit
        (io.panic "lint: qualified panic padding should flag with unreachable"))
      (match (lint_core.lint-findings-get
        (lint-test-walk-tail
          redundant-padding-begin
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (let
            [fspan : ast.AstSourceSpan finding.span]
            (if (and
              (= (ast.ast-source-span-start-line fspan) 43)
              (string.eq
                finding.rule-id
                (lint_core.lint-rule-redundant-divergence-padding-id)))
              unit
              (io.panic
                "lint: redundant divergence padding finding should carry rule id and span")))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic
            "lint: redundant divergence padding should produce a finding")])
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            clean-panic-tail-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic "lint: tail panic without padding should stay clean"))
      (if (=
        (lint_core.lint-findings-count
          (lint-test-walk-tail
            branch-local-return-begin
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        unit
        (io.panic
          "lint: branch-local return should not make following code unreachable"))
      (lint-rule-registry-smoke)
      42)))