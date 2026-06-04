;# TypeLisp lint engine + source cleanup rules (#1163, #1177).
;#
;# A selfhost lint pass: walk the parsed AST, run registered rules, and collect
;# findings. The rules flag deeply-nested `if` ladders, body-only nested `let` forms,
;# nested success-path `if` return chains, and unit-branch return guards.
;#
;# The `typelisp lint` CLI driver consumes the rule id attached to each finding
;# for suppression (`;; lint-allow: <rule-id>`). This module owns stable rule
;# metadata and the lint core verified by `compiler-lint-self-test` (driver:
;# `selfhost/lint_smoke.tl`).
(import "../stdlib/io.tl")

(import "compiler_ast_types.tl")

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
  "unit return guard if: prefer when/unless")

(define (lint-rule-unit-if-guard-suggestion) : String
  "prefer when/unless for unit guard branches")

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
  (LintRuleCons LintRule LintRuleList))

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

;: Small registry for lint metadata. New rules plug into this list and the
;: shared lookup helpers without requiring public driver edits.
(define (lint-rule-registry) : LintRuleList
  (LintRuleCons
    (lint-rule-nested-if-ladder)
    (LintRuleCons
      (lint-rule-nested-let)
      (LintRuleCons
        (lint-rule-return-path-chain)
        (LintRuleCons (lint-rule-unit-if-guard) LintRuleNil)))))

(define (lint-rule-find-in [rules : LintRuleList] [rule-id : String]) : LintMaybeRule
  (match rules
    [(LintRuleNil) LintRuleNotFound]
    [(LintRuleCons rule rest)
      (if (string-eq (struct-get rule rule-id) rule-id)
        (LintRuleFound rule)
        (lint-rule-find-in rest rule-id))]))

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

;: Immutable list of findings.
(defenum LintFindingList
  (LintFindingNil)
  (LintFindingCons LintFinding LintFindingList))

;: Number of findings in `items`.
(define (lint-finding-list-count [items : LintFindingList]) : i64
  (match items
    [(LintFindingNil) 0]
    [(LintFindingCons _ rest) (+ 1 (lint-finding-list-count rest))]))

;: Default nested-`if`-ladder depth threshold (an else-chain of this many `if`s
;: or more is flagged).
(define (lint-default-ladder-threshold) : i64
  3)

;: Length of the `if`/else-`if` ladder headed by `expr`: 0 when `expr` is not an
;: `if`, otherwise 1 + the ladder length of its else-branch. Spans are
;: transparent.
(define (lint-ladder-length [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned inner _) (lint-ladder-length inner)]
    [(AstExprIf _ _ else-branch) (+ 1 (lint-ladder-length else-branch))]
    [_ 0]))

(define (lint-return-path-chain-length [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned inner _) (lint-return-path-chain-length inner)]
    [(AstExprIf _ then-branch _)
      (+ 1 (lint-return-path-chain-length then-branch))]
    [_ 0]))

(define (lint-unit-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner _) (lint-unit-expr? inner)]
    [(AstExprLiteral AstLitUnit) true]
    [_ false]))

(define (lint-return-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner _) (lint-return-expr? inner)]
    [(AstExprReturn _) true]
    [_ false]))

(define (lint-expr-list-has-return? [exprs : AstExprList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons head rest)
      (if (lint-return-expr? head)
        true
        (lint-expr-list-has-return? rest))]))

(define (lint-return-branch? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner _) (lint-return-branch? inner)]
    [(AstExprReturn _) true]
    [(AstExprBegin exprs) (lint-expr-list-has-return? exprs)]
    [_ false]))

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
      "unit return guard if: unit then-branch; prefer unless"
      "unit return guard if: unit else-branch; prefer when")
    (lint-rule-unit-if-guard-id)
    1
    span))

;: Walk every expression in `exprs`, accumulating findings.
(define (lint-walk-expr-list
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match exprs
    [(AstExprNil) acc]
    [(AstExprCons head rest)
      (lint-walk-expr-list rest threshold (lint-walk-expr head threshold acc))]))

;: Walk each binding initializer in `bindings`.
(define (lint-walk-let-bindings
  [bindings : AstLetBindingList]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match bindings
    [(AstLetBindingNil) acc]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding _ _ init)
          (lint-walk-let-bindings
            rest
            threshold
            (lint-walk-expr init threshold acc))])]))

(define (lint-let-bindings-contain-name?
  [bindings : AstLetBindingList]
  [name : String]) : bool
  (match bindings
    [(AstLetBindingNil) false]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding binding-name _ _)
          (if (string-eq binding-name name)
            true
            (lint-let-bindings-contain-name? rest name))])]))

(define (lint-let-bindings-shadow-outer?
  [outer : AstLetBindingList]
  [inner : AstLetBindingList]) : bool
  (match inner
    [(AstLetBindingNil) false]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name _ _)
          (if (lint-let-bindings-contain-name? outer name)
            true
            (lint-let-bindings-shadow-outer? outer rest))])]))

(define (lint-nested-let-body? [body : AstExpr]) : bool
  (match body
    [(AstExprSpanned inner _) (lint-nested-let-body? inner)]
    [(AstExprLet _ _) true]
    [_ false]))

(define (lint-nested-let-shadows? [outer : AstLetBindingList] [body : AstExpr]) : bool
  (match body
    [(AstExprSpanned inner _) (lint-nested-let-shadows? outer inner)]
    [(AstExprLet inner-bindings _)
      (lint-let-bindings-shadow-outer? outer inner-bindings)]
    [_ false]))

(define (lint-walk-let
  [bindings : AstLetBindingList]
  [body : AstExpr]
  [span : AstSourceSpan]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (let
    [next : LintFindingList
      (if (and
        (lint-nested-let-body? body)
        (not (lint-nested-let-shadows? bindings body)))
        (LintFindingCons (lint-nested-let-finding span) acc)
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
  [acc : LintFindingList]) : LintFindingList
  (let
    [next : LintFindingList
      (if (and
        (lint-nested-let-body? body)
        (not (lint-nested-let-shadows? bindings body)))
        (LintFindingCons (lint-nested-let-finding span) acc)
        acc)]
    (lint-walk-tail-expr
      body
      threshold
      (lint-walk-let-bindings bindings threshold next))))

;: Walk each resource initializer and cleanup expression in `bindings`.
(define (lint-walk-resource-bindings
  [bindings : AstResourceBindingList]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match bindings
    [(AstResourceBindingNil) acc]
    [(AstResourceBindingCons binding rest)
      (match binding
        [(AstResourceBinding _ init cleanup)
          (lint-walk-resource-bindings
            rest
            threshold
            (lint-walk-expr
              cleanup
              threshold
              (lint-walk-expr init threshold acc)))])]))

;: Walk each match-arm body in `arms`.
(define (lint-walk-match-arms
  [arms : AstMatchArmList]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match arms
    [(AstMatchArmNil) acc]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm _ body)
          (lint-walk-match-arms
            rest
            threshold
            (lint-walk-expr body threshold acc))])]))

;: Descend an if/else-`if` ladder whose head has already been flagged: walk
;: each rung's condition and then-branch as fresh sub-walks (so a ladder nested
;: inside one of those still flags), but follow the else-chain here WITHOUT
;: re-flagging the inner `if`s, and walk the final non-`if` else normally.
(define (lint-walk-ladder
  [expr : AstExpr]
  [threshold : i64]
  [tail-return-path : bool]
  [acc : LintFindingList]) : LintFindingList
  (match expr
    [(AstExprSpanned inner _)
      (lint-walk-ladder inner threshold tail-return-path acc)]
    [(AstExprIf cond then-branch else-branch)
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
            (lint-walk-expr cond threshold acc))))]
    [_
      (if tail-return-path
        (lint-walk-tail-expr expr threshold acc)
        (lint-walk-expr expr threshold acc))]))

(define (lint-walk-return-path-chain
  [expr : AstExpr]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match expr
    [(AstExprSpanned inner _) (lint-walk-return-path-chain inner threshold acc)]
    [(AstExprIf cond then-branch else-branch)
      (lint-walk-return-path-chain
        then-branch
        threshold
        (lint-walk-expr
          else-branch
          threshold
          (lint-walk-expr cond threshold acc)))]
    [_ (lint-walk-tail-expr expr threshold acc)]))

(define (lint-walk-unit-if-guard-branch
  [branch : AstExpr]
  [tail-return-path : bool]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
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
  [acc : LintFindingList]) : LintFindingList
  (let
    [ladder : i64 (+ 1 (lint-ladder-length else-branch))]
    [return-chain : i64 (+ 1 (lint-return-path-chain-length then-branch))]
    [then-unit : bool (lint-unit-expr? then-branch)]
    [else-unit : bool (lint-unit-expr? else-branch)]
    [then-return : bool (lint-return-branch? then-branch)]
    [else-return : bool (lint-return-branch? else-branch)]
    (cond
      [(and then-unit (and (not else-unit) else-return))
        (lint-walk-unit-if-guard-branch
          else-branch
          tail-return-path
          threshold
          (LintFindingCons
            (lint-unit-if-guard-finding true span)
            (lint-walk-expr cond threshold acc)))]
      [(and else-unit (and (not then-unit) then-return))
        (lint-walk-unit-if-guard-branch
          then-branch
          tail-return-path
          threshold
          (LintFindingCons
            (lint-unit-if-guard-finding false span)
            (lint-walk-expr cond threshold acc)))]
      [(and tail-return-path (>= return-chain threshold))
        (lint-walk-return-path-chain
          (AstExprIf cond then-branch else-branch)
          threshold
          (LintFindingCons
            (lint-return-path-chain-finding return-chain span)
            acc))]
      [(>= ladder threshold)
        (lint-walk-ladder
          (AstExprIf cond then-branch else-branch)
          threshold
          tail-return-path
          (LintFindingCons (lint-ladder-finding ladder span) acc))]
      [tail-return-path
        (lint-walk-tail-expr
          else-branch
          threshold
          (lint-walk-tail-expr
            then-branch
            threshold
            (lint-walk-expr cond threshold acc)))]
      [else
        (lint-walk-expr
          else-branch
          threshold
          (lint-walk-expr
            then-branch
            threshold
            (lint-walk-expr cond threshold acc)))])))

;;; Walk a list of expressions where only the final expression is in tail
;;; position.
(define (lint-walk-tail-expr-list
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match exprs
    [(AstExprNil) acc]
    [(AstExprCons head rest)
      (match rest
        [(AstExprNil) (lint-walk-tail-expr head threshold acc)]
        [_
          (lint-walk-tail-expr-list
            rest
            threshold
            (lint-walk-expr head threshold acc))])]))

;;; Walk match arms whose bodies are in tail position.
(define (lint-walk-tail-match-arms
  [arms : AstMatchArmList]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match arms
    [(AstMatchArmNil) acc]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm _ body)
          (lint-walk-tail-match-arms
            rest
            threshold
            (lint-walk-tail-expr body threshold acc))])]))

;;; Walk `expr` in a function/lambda/test tail context. The return-path-chain
;;; rule is only valid here: in non-tail value contexts, introducing
;;; `(return ...)` would change the surrounding expression's behavior.
(define (lint-walk-tail-expr
  [expr : AstExpr]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match expr
    [(AstExprSpanned inner span)
      (match inner
        [(AstExprIf cond then-branch else-branch)
          (lint-walk-if cond then-branch else-branch span true threshold acc)]
        [(AstExprLet bindings body)
          (lint-walk-tail-let bindings body span threshold acc)]
        [_ (lint-walk-tail-expr inner threshold acc)])]
    [(AstExprIf cond then-branch else-branch)
      (lint-walk-if
        cond
        then-branch
        else-branch
        (lint-no-span)
        true
        threshold
        acc)]
    [(AstExprLet bindings body)
      (lint-walk-tail-let bindings body (lint-no-span) threshold acc)]
    [(AstExprLambda _ _ body) (lint-walk-tail-expr body threshold acc)]
    [(AstExprBegin exprs) (lint-walk-tail-expr-list exprs threshold acc)]
    [(AstExprUnsafe exprs) (lint-walk-tail-expr-list exprs threshold acc)]
    [(AstExprAnn inner _) (lint-walk-tail-expr inner threshold acc)]
    [(AstExprCast inner _) (lint-walk-tail-expr inner threshold acc)]
    [(AstExprMatch scrutinee arms)
      (lint-walk-tail-match-arms
        arms
        threshold
        (lint-walk-expr scrutinee threshold acc))]
    [(AstExprWithRegion _ body) (lint-walk-tail-expr-list body threshold acc)]
    [(AstExprWithResource bindings body)
      (lint-walk-tail-expr-list
        body
        threshold
        (lint-walk-resource-bindings bindings threshold acc))]
    [(AstExprTry inner) (lint-walk-tail-expr inner threshold acc)]
    [_ (lint-walk-expr expr threshold acc)]))

;: Walk `expr`, flagging each maximal nested-`if` ladder of length >=
;: `threshold` exactly once and recursing into all sub-expressions. A ladder
;: head's finding span comes from the enclosing `AstExprSpanned` wrapper.
(define (lint-walk-expr
  [expr : AstExpr]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match expr
    [(AstExprSpanned inner span)
      (match inner
        [(AstExprIf cond then-branch else-branch)
          (lint-walk-if cond then-branch else-branch span false threshold acc)]
        [(AstExprLet bindings body)
          (lint-walk-let bindings body span threshold acc)]
        [_ (lint-walk-expr inner threshold acc)])]
    [(AstExprLiteral _) acc]
    [(AstExprVar _) acc]
    [(AstExprTypeLiteral _) acc]
    [(AstExprBinary _ left right)
      (lint-walk-expr right threshold (lint-walk-expr left threshold acc))]
    [(AstExprUnary _ inner) (lint-walk-expr inner threshold acc)]
    [(AstExprCall func args)
      (lint-walk-expr-list args threshold (lint-walk-expr func threshold acc))]
    [(AstExprIf cond then-branch else-branch)
      ;; A directly-reached (unspanned) `if`: no wrapper span, so the finding
      ;; gets the sentinel. Maximal-ladder dedup lives in lint-walk-if.
      (lint-walk-if
        cond
        then-branch
        else-branch
        (lint-no-span)
        false
        threshold
        acc)]
    [(AstExprLet bindings body)
      (lint-walk-let bindings body (lint-no-span) threshold acc)]
    [(AstExprLambda _ _ body) (lint-walk-expr body threshold acc)]
    [(AstExprTuple exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExprTupleRef tuple _) (lint-walk-expr tuple threshold acc)]
    [(AstExprArray exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExprMakeArray _ len) (lint-walk-expr len threshold acc)]
    [(AstExprArrayRef array index)
      (lint-walk-expr index threshold (lint-walk-expr array threshold acc))]
    [(AstExprArraySet array index value)
      (lint-walk-expr
        value
        threshold
        (lint-walk-expr index threshold (lint-walk-expr array threshold acc)))]
    [(AstExprArrayPush array value)
      (lint-walk-expr value threshold (lint-walk-expr array threshold acc))]
    [(AstExprStringRef str index)
      (lint-walk-expr index threshold (lint-walk-expr str threshold acc))]
    [(AstExprWhile cond body)
      (lint-walk-expr body threshold (lint-walk-expr cond threshold acc))]
    [(AstExprBegin exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExprUnsafe exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExprSet _ value) (lint-walk-expr value threshold acc)]
    [(AstExprAnn inner _) (lint-walk-expr inner threshold acc)]
    [(AstExprCast inner _) (lint-walk-expr inner threshold acc)]
    [(AstExprBorrow _ place) (lint-walk-expr place threshold acc)]
    [(AstExprMatch scrutinee arms)
      (lint-walk-match-arms
        arms
        threshold
        (lint-walk-expr scrutinee threshold acc))]
    [(AstExprForeach _ _ start end body)
      (lint-walk-expr
        body
        threshold
        (lint-walk-expr end threshold (lint-walk-expr start threshold acc)))]
    [(AstExprSpmdReduce _ _ _ start end init value)
      (lint-walk-expr
        value
        threshold
        (lint-walk-expr
          init
          threshold
          (lint-walk-expr end threshold (lint-walk-expr start threshold acc))))]
    [(AstExprStructGet receiver _) (lint-walk-expr receiver threshold acc)]
    [(AstExprWithRegion _ body) (lint-walk-expr-list body threshold acc)]
    [(AstExprWithEscape scratch body)
      (lint-walk-expr-list
        body
        threshold
        (lint-walk-expr scratch threshold acc))]
    [(AstExprWithResource bindings body)
      (lint-walk-expr-list
        body
        threshold
        (lint-walk-resource-bindings bindings threshold acc))]
    [(AstExprBox inner) (lint-walk-expr inner threshold acc)]
    [(AstExprBoxGet inner) (lint-walk-expr inner threshold acc)]
    [(AstExprComptime inner) (lint-walk-expr inner threshold acc)]
    [(AstExprQuote _) acc]
    [(AstExprQuasiquote _) acc]
    [(AstExprUnquote inner) (lint-walk-expr inner threshold acc)]
    [(AstExprUnquoteSplicing inner) (lint-walk-expr inner threshold acc)]
    [(AstExprTry inner) (lint-walk-expr inner threshold acc)]
    [(AstExprReturn inner) (lint-walk-expr inner threshold acc)]
    [(AstExprPtrNull _) acc]
    [(AstExprPtrNullCheck inner) (lint-walk-expr inner threshold acc)]
    [(AstExprPtrRead ptr) (lint-walk-expr ptr threshold acc)]
    [(AstExprPtrWrite ptr value)
      (lint-walk-expr value threshold (lint-walk-expr ptr threshold acc))]
    [(AstExprPtrOffset ptr offset)
      (lint-walk-expr offset threshold (lint-walk-expr ptr threshold acc))]
    [(AstExprPtrCast ptr _) (lint-walk-expr ptr threshold acc)]
    [(AstExprPtrToInt ptr) (lint-walk-expr ptr threshold acc)]
    [(AstExprIntToPtr value _) (lint-walk-expr value threshold acc)]
    [(AstExprStringData inner) (lint-walk-expr inner threshold acc)]
    [(AstExprStringFromBytes ptr len)
      (lint-walk-expr len threshold (lint-walk-expr ptr threshold acc))]
    [(AstExprArrayData inner) (lint-walk-expr inner threshold acc)]
    [(AstExprProgramArgc) acc]
    [(AstExprProgramArgv) acc]
    [(AstExprProgramEnvp) acc]
    [(AstExprCpuIdEax leaf subleaf)
      (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc))]
    [(AstExprCpuIdEbx leaf subleaf)
      (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc))]
    [(AstExprCpuIdEcx leaf subleaf)
      (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc))]
    [(AstExprCpuIdEdx leaf subleaf)
      (lint-walk-expr subleaf threshold (lint-walk-expr leaf threshold acc))]
    [(AstExprXgetbv index) (lint-walk-expr index threshold acc)]))

;: Walk the body expression(s) carried by a declaration, if any.
(define (lint-walk-decl
  [decl : AstDecl]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match decl
    [(AstDeclDef _ _ body) (lint-walk-expr body threshold acc)]
    [(AstDeclDefFn _ _ _ body) (lint-walk-tail-expr body threshold acc)]
    [(AstDeclDefMacro _ _ _ body) (lint-walk-tail-expr body threshold acc)]
    [(AstDeclTest _ body _) (lint-walk-tail-expr body threshold acc)]
    [(AstDeclUnsafe inner) (lint-walk-decl inner threshold acc)]
    [(AstDeclComptimeDecl inner) (lint-walk-decl inner threshold acc)]
    [(AstDeclModule _) acc]
    [(AstDeclExtern _ _ _) acc]
    [(AstDeclDefEnum _ _) acc]
    [(AstDeclDefStruct _ _ _ _) acc]
    [(AstDeclExport _) acc]
    [(AstDeclImport _) acc]))

;: Walk every declaration body in `decls`.
(define (lint-walk-decl-list
  [decls : AstDeclList]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (lint-walk-decl-list rest threshold (lint-walk-decl decl threshold acc))]))

;: Run all lint rules over `program`, returning the collected findings.
(define (lint-program [program : AstProgram] [threshold : i64]) : LintFindingList
  (match program
    [(AstProgram decls) (lint-walk-decl-list decls threshold (LintFindingNil))]))

;: Self-test: the nested-`if`-ladder rule and the AST walk.
(define (compiler-lint-self-test) : i64
  (let
    [vx : AstExpr (AstExprVar "x")]
    [one : AstExpr (AstExprLiteral (AstLitInt 1))]
    [unit-expr : AstExpr (AstExprLiteral AstLitUnit)]
    [ladder3 : AstExpr
      (AstExprIf vx one (AstExprIf vx one (AstExprIf vx one one)))]
    [ladder2 : AstExpr (AstExprIf vx one (AstExprIf vx one one))]
    [ladder4 : AstExpr
      (AstExprIf
        vx
        one
        (AstExprIf vx one (AstExprIf vx one (AstExprIf vx one one))))]
    [return-chain3 : AstExpr
      (AstExprIf vx (AstExprIf vx (AstExprIf vx one one) one) one)]
    [return-one : AstExpr (AstExprReturn one)]
    [unit-then-guard : AstExpr (AstExprIf vx unit-expr return-one)]
    [unit-else-guard : AstExpr (AstExprIf vx return-one unit-expr)]
    [unit-value-guard : AstExpr (AstExprIf vx one unit-expr)]
    [nested : AstExpr (AstExprBegin (AstExprCons ladder3 (AstExprNil)))]
    [in-let : AstExpr
      (AstExprLet
        (AstLetBindingCons
          (AstLetBinding "y" (AstNoType) ladder3)
          (AstLetBindingNil))
        vx)]
    [outer-let-bindings : AstLetBindingList
      (AstLetBindingCons (AstLetBinding "a" (AstNoType) one) (AstLetBindingNil))]
    [inner-let-bindings : AstLetBindingList
      (AstLetBindingCons (AstLetBinding "b" (AstNoType) vx) (AstLetBindingNil))]
    [shadowing-let-bindings : AstLetBindingList
      (AstLetBindingCons (AstLetBinding "a" (AstNoType) one) (AstLetBindingNil))]
    [nested-let : AstExpr
      (AstExprLet outer-let-bindings (AstExprLet inner-let-bindings vx))]
    [shadowing-nested-let : AstExpr
      (AstExprLet outer-let-bindings (AstExprLet shadowing-let-bindings vx))]
    [begin-inner-let : AstExpr
      (AstExprLet
        outer-let-bindings
        (AstExprBegin
          (AstExprCons
            (AstExprLet inner-let-bindings vx)
            (AstExprCons vx (AstExprNil)))))]
    [spanned : AstExpr (AstExprSpanned ladder3 (AstSourceSpan 7 3 9 4))]
    [spanned-nested-let : AstExpr
      (AstExprSpanned nested-let (AstSourceSpan 11 5 15 6))]
    (begin
      ;; ladder length math
      (if (= (lint-ladder-length ladder3) 3)
        unit
        (panic "lint: ladder3 length should be 3"))
      (if (= (lint-ladder-length ladder2) 2)
        unit
        (panic "lint: ladder2 length should be 2"))
      (if (= (lint-ladder-length vx) 0)
        unit
        (panic "lint: non-if ladder length should be 0"))
      ;; a 3-deep ladder is flagged at the default threshold (3)
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            ladder3
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        1)
        unit
        (panic "lint: 3-deep ladder should be flagged once"))
      ;; a 2-deep ladder is NOT flagged at threshold 3
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            ladder2
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        0)
        unit
        (panic "lint: 2-deep ladder should not be flagged at threshold 3"))
      ;; ... but IS flagged at threshold 2
      (if (=
        (lint-finding-list-count (lint-walk-expr ladder2 2 (LintFindingNil)))
        1)
        unit
        (panic "lint: 2-deep ladder should be flagged at threshold 2"))
      ;; return-path chains are only reported in tail contexts, where replacing
      ;; nested failure values with `(return ...)` preserves semantics.
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            return-chain3
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        0)
        unit
        (panic "lint: return-path chain should not flag in a value context"))
      (if (=
        (lint-finding-list-count
          (lint-walk-tail-expr
            return-chain3
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        1)
        unit
        (panic "lint: return-path chain should be flagged once"))
      (match (lint-walk-tail-expr
        return-chain3
        (lint-default-ladder-threshold)
        (LintFindingNil))
        [(LintFindingCons finding _)
          (if (string-eq
            (struct-get finding rule-id)
            (lint-rule-return-path-chain-id))
            unit
            (panic "lint: return-path chain should report its rule id"))]
        [(LintFindingNil)
          (panic "lint: return-path chain should produce a finding")])
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            unit-then-guard
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        1)
        unit
        (panic "lint: unit then-branch should be flagged once"))
      (match (lint-walk-expr
        unit-else-guard
        (lint-default-ladder-threshold)
        (LintFindingNil))
        [(LintFindingCons finding _)
          (if (string-eq
            (struct-get finding rule-id)
            (lint-rule-unit-if-guard-id))
            unit
            (panic "lint: unit-if guard should report its rule id"))]
        [(LintFindingNil)
          (panic "lint: unit-if guard should produce a finding")])
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            unit-value-guard
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        0)
        unit
        (panic "lint: unit-if guard should only flag return guards"))
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            nested
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        1)
        unit
        (panic "lint: ladder nested in begin should be found"))
      ;; ... and into let-binding initializers
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            in-let
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        1)
        unit
        (panic "lint: ladder in a let binding should be found"))
      ;; a ladder LONGER than the threshold is reported ONCE, not once per
      ;; over-threshold rung (maximal-ladder dedup, #1163).
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            ladder4
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        1)
        unit
        (panic "lint: a 4-deep ladder at threshold 3 should be flagged once"))
      ;; a spanned ladder head carries its wrapper's source span in the finding
      ;; (real parsed `if`s are `AstExprSpanned`-wrapped; the driver reports it).
      (match (lint-walk-expr
        spanned
        (lint-default-ladder-threshold)
        (LintFindingNil))
        [(LintFindingCons finding _)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (= (struct-get fspan start-line) 7)
              unit
              (panic
                "lint: spanned ladder finding should carry its head start-line")))]
        [(LintFindingNil)
          (panic "lint: spanned ladder should produce a finding")])
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            nested-let
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        1)
        unit
        (panic "lint: body-only nested let should be flagged once"))
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            shadowing-nested-let
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        0)
        unit
        (panic "lint: shadowing nested let should not be flagged"))
      (if (=
        (lint-finding-list-count
          (lint-walk-expr
            begin-inner-let
            (lint-default-ladder-threshold)
            (LintFindingNil)))
        0)
        unit
        (panic "lint: let with nontrivial begin body should not be flagged"))
      (match (lint-walk-expr
        spanned-nested-let
        (lint-default-ladder-threshold)
        (LintFindingNil))
        [(LintFindingCons finding _)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (and
              (= (struct-get fspan start-line) 11)
              (string-eq (struct-get finding rule-id) (lint-rule-nested-let-id)))
              unit
              (panic "lint: nested-let finding should carry rule id and span")))]
        [(LintFindingNil)
          (panic "lint: spanned nested let should produce a finding")])
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
            (and
              (string-eq
                (struct-get rule message)
                (lint-rule-nested-if-ladder-message))
              (string-eq
                (struct-get rule suggestion)
                (lint-rule-nested-if-ladder-suggestion))))
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