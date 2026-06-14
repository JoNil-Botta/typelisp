;# TypeLisp lint engine + source cleanup rules (#1163, #1177).
;#
;# A selfhost lint pass: walk the parsed AST, run registered rules, and collect
;# findings. The rules flag deeply-nested `if` ladders, body-only nested `let` forms,
;# nested success-path `if` return chains, unit-branch return guards, and
;# deprecated user-facing string concatenation primitives.
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

;: Stable rule id for the nested-`if`-ladder rule. Rule ids are the suppression
;: key (`;; lint-allow: <rule-id>`) and the registry key, so they must stay
;: stable across releases.
(define (lint-rule-nested-if-ladder-id) : String
  "nested-if-ladder")

;: Public message text for the nested-`if`-ladder rule. Kept separate from the
;: registry constructor so rule walkers and self-tests use the same metadata.
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

(define (lint-rule-deprecated-string-concat-id) : String
  "deprecated-string-concat")

(define (lint-rule-deprecated-string-concat-message) : String
  "deprecated string concatenation primitive: use str-cat for fixed arity or text_buf for incremental building")

(define (lint-rule-deprecated-string-concat-suggestion) : String
  "import stdlib/str_cat.tl and use str-cat, or use stdlib/text_buf.tl in accumulation loops")

(define (lint-rule-cascading-and-or-id) : String
  "cascading-and-or")

(define (lint-rule-cascading-and-or-message) : String
  "cascading and/or: prefer one flat n-ary macro call")

(define (lint-rule-cascading-and-or-suggestion) : String
  "flatten same-operator and/or operands, e.g. (and a b c)")

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

(define (lint-rule-deprecated-string-concat) : LintRule
  (LintRule
    (lint-rule-deprecated-string-concat-id)
    (lint-rule-deprecated-string-concat-message)
    (lint-rule-deprecated-string-concat-suggestion)))

(define (lint-rule-cascading-and-or) : LintRule
  (LintRule
    (lint-rule-cascading-and-or-id)
    (lint-rule-cascading-and-or-message)
    (lint-rule-cascading-and-or-suggestion)))

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
            (lint-rule-deprecated-string-concat)
            (lint-rule-cons (lint-rule-cascading-and-or) LintRuleNil)))))))

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
    (cond
      in-loop
      "deprecated string concatenation in loop: use text_buf for incremental building"
      in-chain
      "deprecated string concatenation chain: use one str-cat call for fixed arity"
      (lint-rule-message (lint-rule-deprecated-string-concat-id)))
    (lint-rule-deprecated-string-concat-id)
    (lint-deprecated-string-concat-depth in-loop in-chain)
    span))

(define (lint-and-or-op-name [name : String]) : String
  (cond
    (or (string-eq name "and") (string-eq name "core/and"))
    "and"
    (or (string-eq name "or") (string-eq name "core/or"))
    "or"
    ""))

(define (lint-and-or-func-op [func : AstExpr]) : String
  (match func
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lint-and-or-func-op inner))]
    [(AstExprVar name) (lint-and-or-op-name (intern-str name))]
    [_ ""]))

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
                  (= tag (tag-end))
                  (set! done true)
                  (= tag (tag-lparen))
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
                        unit)))
                  (= tag (tag-rparen))
                  (if (> depth 0)
                    (begin
                      (if (array-ref loop-stack depth)
                        (set! loop-depth (- loop-depth 1))
                        unit)
                      (if (array-ref concat-stack depth)
                        (set! concat-depth (- concat-depth 1))
                        unit)
                      (set! depth (- depth 1)))
                    unit)
                  unit))
              (set! i (+ i 1))))
          findings))]))

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
;: when unspanned): a maximal ladder of length >= `threshold` flags ONCE at
;: `span` and then descends the else-chain via `lint-walk-ladder` (so inner
;: rungs are not re-flagged); otherwise ordinary recursion into cond/then/else.
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
      (and
        then-unit
        (not else-unit)
        (or else-return (and cond-not else-side-effect)))
      (lint-walk-unit-if-guard-branch
        else-branch
        tail-return-path
        threshold
        (lint-findings-add
          (lint-unit-if-guard-finding true span)
          (lint-walk-expr cond threshold acc)))
      (and else-unit (not then-unit) then-return)
      (lint-walk-unit-if-guard-branch
        then-branch
        tail-return-path
        threshold
        (lint-findings-add
          (lint-unit-if-guard-finding false span)
          (lint-walk-expr cond threshold acc)))
      (and tail-return-path (>= return-chain threshold))
      (lint-walk-return-path-chain
        (AstExprIf
          (ast-node-push cond)
          (ast-node-push then-branch)
          (ast-node-push else-branch))
        threshold
        (lint-findings-add
          (lint-return-path-chain-finding return-chain span)
          acc))
      (>= ladder threshold)
      (lint-walk-ladder
        (AstExprIf
          (ast-node-push cond)
          (ast-node-push then-branch)
          (ast-node-push else-branch))
        threshold
        tail-return-path
        (lint-findings-add (lint-ladder-finding ladder span) acc))
      tail-return-path
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
          (lint-walk-expr cond threshold acc))))))

;;; Walk a list of expressions where only the final expression is in tail
;;; position.
(define (lint-walk-tail-expr-list
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindings]) : LintFindings
  (match exprs
    [(AstExprNil) acc]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil) (lint-walk-tail-expr head threshold acc)]
          [_
            (lint-walk-tail-expr-list
              rest
              threshold
              (lint-walk-expr head threshold acc))]))]))

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
    [(AstExprBegin exprs) (lint-walk-tail-expr-list exprs threshold acc)]
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
    [(AstExprWithRegion _ body) (lint-walk-tail-expr-list body threshold acc)]
    [(AstExprInArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (lint-walk-tail-expr-list
          body
          threshold
          (lint-walk-expr arena threshold acc)))]
    [(AstExprWithResource bindings body)
      (lint-walk-tail-expr-list
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
      (lint-walk-expr-list args threshold (lint-walk-expr func threshold acc)))))

;: Walk `expr`, flagging each maximal nested-`if` ladder of length >=
;: `threshold` exactly once and recursing into all sub-expressions. A ladder
;: head's finding span comes from the enclosing `AstExprSpanned` wrapper.
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
    [(AstExprBegin exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExprUnsafe exprs) (lint-walk-expr-list exprs threshold acc)]
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
    [(AstExprWithRegion _ body) (lint-walk-expr-list body threshold acc)]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (lint-walk-expr-list
          body
          threshold
          (lint-walk-expr scratch threshold acc)))]
    [(AstExprInArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (lint-walk-expr-list
          body
          threshold
          (lint-walk-expr arena threshold acc)))]
    [(AstExprWithResource bindings body)
      (lint-walk-expr-list
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

;: Run all lint rules over `program`, returning the collected findings.
(define (lint-program [program : AstProgram] [threshold : i64]) : LintFindings
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (lint-walk-decl-list decls threshold (lint-findings-empty)))]))

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
          (lint-walk-decl-list decls threshold (lint-findings-empty))))]))

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
      ;; a 3-deep ladder is flagged at the default threshold (3)
      (if (=
        (lint-findings-count
          (lint-test-walk
            ladder3
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: 3-deep ladder should be flagged once"))
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
      ;; ... but IS flagged at threshold 2
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
        (panic "lint: ladder nested in begin should be found"))
      ;; ... and into let-binding initializers
      (if (=
        (lint-findings-count
          (lint-test-walk
            in-let
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: ladder in a let binding should be found"))
      ;; a ladder LONGER than the threshold is reported ONCE, not once per
      ;; over-threshold rung (maximal-ladder dedup, #1163).
      (if (=
        (lint-findings-count
          (lint-test-walk
            ladder4
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: a 4-deep ladder at threshold 3 should be flagged once"))
      ;; a spanned ladder head carries its wrapper's source span in the finding
      ;; (real parsed `if`s are `AstExprSpanned`-wrapped; the driver reports it).
      (match (lint-findings-get
        (lint-test-walk
          spanned
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (= (struct-get fspan start-line) 7)
              unit
              (panic
                "lint: spanned ladder finding should carry its head start-line")))]
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
        (lint-rule-suggestion (lint-rule-deprecated-string-concat-id))
        "import stdlib/str_cat.tl and use str-cat, or use stdlib/text_buf.tl in accumulation loops")
        unit
        (panic "lint: deprecated-string-concat suggestion should be registered"))
      (if (string-eq
        (lint-rule-suggestion (lint-rule-cascading-and-or-id))
        "flatten same-operator and/or operands, e.g. (and a b c)")
        unit
        (panic "lint: cascading-and-or suggestion should be registered"))
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