;;;; TypeLisp lint engine + nested-if-ladder rule (#1163).
;;;;
;;;; A selfhost lint pass: walk the parsed AST, run rules, and collect findings.
;;;; This first slice ships the rule engine plus one rule — **deeply-nested `if`
;;;; ladders**. An `if` whose else-branch chains into further `if`s beyond a
;;;; configurable depth threshold is flagged with a suggestion to use `cond`
;;;; (value/guard ladders) or `match` (variant dispatch).
;;;;
;;;; The `typelisp lint` CLI driver, the multi-rule registry, suppression, and
;;;; corpus fixtures are tracked as follow-ups on #1163; this module is the
;;;; rule core that those build on. It is verified by `compiler-lint-self-test`
;;;; (driver: `selfhost/lint_smoke.tl`).
(import "compiler_ast_types.tl")

;;; A single lint finding: a human-readable message plus the ladder depth that
;;; triggered it.
(defstruct LintFinding
  (message String)
  (depth i64))

;;; Immutable list of findings.
(defenum LintFindingList
  (LintFindingNil)
  (LintFindingCons LintFinding LintFindingList))

;;; Number of findings in `items`.
(define (lint-finding-list-count [items : LintFindingList]) : i64
  (match items
    [(LintFindingNil) 0]
    [(LintFindingCons _ rest) (+ 1 (lint-finding-list-count rest))]))

;;; Default nested-`if`-ladder depth threshold (an else-chain of this many `if`s
;;; or more is flagged).
(define (lint-default-ladder-threshold) : i64
  3)

;;; Length of the `if`/else-`if` ladder headed by `expr`: 0 when `expr` is not an
;;; `if`, otherwise 1 + the ladder length of its else-branch. Spans are
;;; transparent.
(define (lint-ladder-length [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned inner _) (lint-ladder-length inner)]
    [(AstExprIf _ _ else-branch) (+ 1 (lint-ladder-length else-branch))]
    [_ 0]))

;;; Build the nested-`if`-ladder finding for a ladder of `depth` arms.
(define (lint-ladder-finding [depth : i64]) : LintFinding
  (LintFinding
    "nested if-ladder: chain of if/else-if; prefer cond (value/guard ladders) or match (variant dispatch)"
    depth))

;;; Walk every expression in `exprs`, accumulating findings.
(define (lint-walk-expr-list
  [exprs : AstExprList]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match exprs
    [(AstExprNil) acc]
    [(AstExprCons head rest)
      (lint-walk-expr-list rest threshold (lint-walk-expr head threshold acc))]))

;;; Walk each binding initializer in `bindings`.
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

;;; Walk each match-arm body in `arms`.
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

;;; Descend an if/else-`if` ladder whose head has already been flagged: walk
;;; each rung's condition and then-branch as fresh sub-walks (so a ladder nested
;;; inside one of those still flags), but follow the else-chain here WITHOUT
;;; re-flagging the inner `if`s, and walk the final non-`if` else normally.
(define (lint-walk-ladder
  [expr : AstExpr]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match expr
    [(AstExprSpanned inner _) (lint-walk-ladder inner threshold acc)]
    [(AstExprIf cond then-branch else-branch)
      (lint-walk-ladder
        else-branch
        threshold
        (lint-walk-expr
          then-branch
          threshold
          (lint-walk-expr cond threshold acc)))]
    [_ (lint-walk-expr expr threshold acc)]))

;;; Walk `expr`, flagging each maximal nested-`if` ladder of length >=
;;; `threshold` exactly once and recursing into all sub-expressions.
(define (lint-walk-expr
  [expr : AstExpr]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match expr
    [(AstExprSpanned inner _) (lint-walk-expr inner threshold acc)]
    [(AstExprLiteral _) acc]
    [(AstExprVar _) acc]
    [(AstExprTypeLiteral _) acc]
    [(AstExprBinary _ left right)
      (lint-walk-expr right threshold (lint-walk-expr left threshold acc))]
    [(AstExprUnary _ inner) (lint-walk-expr inner threshold acc)]
    [(AstExprCall func args)
      (lint-walk-expr-list args threshold (lint-walk-expr func threshold acc))]
    [(AstExprIf cond then-branch else-branch)
      (let
        [ladder : i64 (+ 1 (lint-ladder-length else-branch))]
        (if (>= ladder threshold)
          ;; Maximal ladder head: emit ONE finding, then descend the whole
          ;; else-chain via lint-walk-ladder so inner rungs are not re-flagged
          ;; (a length-L ladder yields exactly one finding, not L-threshold+1).
          (lint-walk-ladder
            expr
            threshold
            (LintFindingCons (lint-ladder-finding ladder) acc))
          ;; Below threshold: ordinary recursion (no rung downstream can reach
          ;; the threshold either, so the else-chain is walked normally).
          (lint-walk-expr
            else-branch
            threshold
            (lint-walk-expr
              then-branch
              threshold
              (lint-walk-expr cond threshold acc)))))]
    [(AstExprLet bindings body)
      (lint-walk-expr
        body
        threshold
        (lint-walk-let-bindings bindings threshold acc))]
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
    [(AstExprStringRef str index)
      (lint-walk-expr index threshold (lint-walk-expr str threshold acc))]
    [(AstExprWhile cond body)
      (lint-walk-expr body threshold (lint-walk-expr cond threshold acc))]
    [(AstExprBegin exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExprUnsafe exprs) (lint-walk-expr-list exprs threshold acc)]
    [(AstExprSet _ value) (lint-walk-expr value threshold acc)]
    [(AstExprAnn inner _) (lint-walk-expr inner threshold acc)]
    [(AstExprCast inner _) (lint-walk-expr inner threshold acc)]
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
    [(AstExprComptime inner) (lint-walk-expr inner threshold acc)]
    [(AstExprTry inner) (lint-walk-expr inner threshold acc)]
    [(AstExprPtrNull _) acc]
    [(AstExprPtrNullCheck inner) (lint-walk-expr inner threshold acc)]))

;;; Walk the body expression(s) carried by a declaration, if any.
(define (lint-walk-decl
  [decl : AstDecl]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match decl
    [(AstDeclDef _ _ body) (lint-walk-expr body threshold acc)]
    [(AstDeclDefFn _ _ _ body) (lint-walk-expr body threshold acc)]
    [(AstDeclTest _ body _) (lint-walk-expr body threshold acc)]
    [(AstDeclComptimeDecl inner) (lint-walk-decl inner threshold acc)]
    [(AstDeclModule _) acc]
    [(AstDeclExtern _ _) acc]
    [(AstDeclDefEnum _ _) acc]
    [(AstDeclDefStruct _ _ _) acc]
    [(AstDeclImport _) acc]))

;;; Walk every declaration body in `decls`.
(define (lint-walk-decl-list
  [decls : AstDeclList]
  [threshold : i64]
  [acc : LintFindingList]) : LintFindingList
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (lint-walk-decl-list rest threshold (lint-walk-decl decl threshold acc))]))

;;; Run all lint rules over `program`, returning the collected findings.
(define (lint-program [program : AstProgram] [threshold : i64]) : LintFindingList
  (match program
    [(AstProgram decls) (lint-walk-decl-list decls threshold (LintFindingNil))]))

;;; Self-test: the nested-`if`-ladder rule and the AST walk.
(define (compiler-lint-self-test) : i64
  (let
    [vx : AstExpr (AstExprVar "x")]
    [one : AstExpr (AstExprLiteral (AstLitInt 1))]
    [ladder3 : AstExpr
      (AstExprIf vx one (AstExprIf vx one (AstExprIf vx one one)))]
    [ladder2 : AstExpr (AstExprIf vx one (AstExprIf vx one one))]
    [ladder4 : AstExpr
      (AstExprIf
        vx
        one
        (AstExprIf vx one (AstExprIf vx one (AstExprIf vx one one))))]
    [nested : AstExpr (AstExprBegin (AstExprCons ladder3 (AstExprNil)))]
    [in-let : AstExpr
      (AstExprLet
        (AstLetBindingCons
          (AstLetBinding "y" (AstNoType) ladder3)
          (AstLetBindingNil))
        vx)]
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
      ;; the walk recurses into begin bodies
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
      42)))