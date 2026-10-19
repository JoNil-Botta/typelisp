(import compiler_typecheck_api as api)
(import compiler_typecheck_core as tc)
(import compiler_ast_types as ast)
(import compiler_diagnostic as diag)
(import compiler_intern as ci)
(import stdlib.string)
(import stdlib.iterator)
(import stdlib.test)

(defstruct MacroDiagnosticCase
  (source String)
  (code String)
  (category String))

(define (expect-error [source : String] [code : String] [category : String]) : unit
  (match (api.typecheck-compiler-source (string.copy (& source)))
    [(Err errors)
      (let
        [first : diag.CompilerDiagnostic
          (diag.compiler-diagnostic-list-first (deref errors))]
        (test.assert-true
          (string.eq (diag.compiler-diagnostic-code-or-empty (& first)) code)
          (string.copy (& source)))
        (test.assert-true
          (match (diag.compiler-diagnostic-category (& first))
            [(CompilerDiagnosticSomeString found) (string.eq found category)]
            [CompilerDiagnosticNoString false])
          source)
        (test.assert-true
          (> (diag.compiler-diagnostic-line (& first)) 0)
          "located error"))]
    [(Ok _) (test.assert-true false source)]))

(test
  compiler-macro-diagnostic-codes
  (let
    [cases
      (array
        (MacroDiagnosticCase
          "(module provider)\n(module main)\n(import provider as p)\n(p.missing)\n(define (main) : i64 0)"
          "E0501"
          "macro")
        (MacroDiagnosticCase
          "(defmacro (same) : Expr (expr-int 1))\n(defmacro (same) : Expr (expr-int 2))\n(define (main) : i64 0)"
          "E0501"
          "macro")
        (MacroDiagnosticCase
          "(defmacro (take [arm : ExprClause]) : i64 (expr-int 0))\n(define (main) : i64 (take 42))"
          "E0502"
          "macro")
        (MacroDiagnosticCase
          "(defmacro (gen) : Module `(define (answer) : i64 42))\n(import (gen))\n(define (main) : i64 0)"
          "E0503"
          "macro")
        (MacroDiagnosticCase
          "(defmacro (again) : Expr `(again))\n(define (main) : i64 (again))"
          "E0504"
          "macro")
        (MacroDiagnosticCase
          "(defmacro (fail) : Expr (comptime-error \"reject this input\"))\n(define (main) : i64 (fail))"
          "E0505"
          "comptime")
        (MacroDiagnosticCase
          "(defmacro (fail) : Expr (comptime-error \"__tl_tc_kind:E0201:author data\"))\n(define (main) : i64 (fail))"
          "E0505"
          "comptime")
        (MacroDiagnosticCase
          "(defmacro (bad) : Expr (expr-int (/ 1 0)))\n(define (main) : i64 (bad))"
          "E0506"
          "comptime")
        (MacroDiagnosticCase
          "(defmacro (bad) : Expr (begin (string-ref \"x\" 1) (expr-int 0)))\n(define (main) : i64 (bad))"
          "E0506"
          "comptime")
        (MacroDiagnosticCase
          "(defmacro (bad) : Expr (expr-int (arg-count)))\n(define (main) : i64 (bad))"
          "E0506"
          "comptime")
        (MacroDiagnosticCase
          "(defmacro (spin) : Expr (begin (while true unit) (expr-int 0)))\n(define (main) : i64 (spin))"
          "E0507"
          "comptime")
        (MacroDiagnosticCase
          "(defmacro (bad) : Decls `(define (answer) : i64 (+ 1)))\n(bad)\n(define (main) : i64 0)"
          "E0103"
          "parse")
        (MacroDiagnosticCase
          "(defmacro (bad) : Expr `(+ true 1))\n(define (main) : i64 (bad))"
          "E0206"
          "typecheck")
        (MacroDiagnosticCase
          "(defmacro (bad) : Expr `unknown)\n(define (main) : i64 (bad))"
          "E0201"
          "typecheck")
        (MacroDiagnosticCase
          "(defmacro (bad) : Expr (comptime-error))\n(define (main) : i64 (bad))"
          "E0202"
          "typecheck")
        (MacroDiagnosticCase
          "(define (main) : i64 (comptime (type i64)))"
          "E0218"
          "typecheck"))]
    (for [index (iterator.range 0 (array-length cases))]
      (let
        [row (& (array-ref cases index))]
        (expect-error
          (string.copy (& row.source))
          (string.copy (& row.code))
          (string.copy (& row.category))))))
  (test.assert-true
    (match (api.typecheck-compiler-source
      "(defmacro (good) : Expr (if false (comptime-error \"untaken\") (expr-int 42))) (define (main) : i64 (good))")
      [(Ok _) true]
      [(Err _) false])
    "untaken author errors remain successful"))

(test
  compiler-macro-coded-frame-transport
  (let
    [primary : ast.AstSourceSpan (ast.AstSourceSpan 3 5 3 9)]
    [inner : ast.AstSourceSpan (ast.AstSourceSpan 7 2 7 12)]
    [outer : ast.AstSourceSpan (ast.AstSourceSpan 11 4 11 14)]
    [text : String
      (tc.tc-macro-framed-error
        (ci.intern "caller.tl")
        outer
        (ci.intern "middle.tl")
        (ci.intern "middle/outer")
        (tc.tc-macro-framed-error
          (ci.intern "middle.tl")
          inner
          (ci.intern "provider.tl")
          (ci.intern "provider/inner")
          (tc.tc-rich-error-one-secondary
            primary
            (diag.compiler-diagnostic-macro-tagged
              (ComptimeEvaluation)
              "changed wording")
            "inspect the operand"
            (ast.AstSourceSpan 2 1 2 8)
            "operand")))]
    [decoded : diag.CompilerDiagnostic (tc.tc-diag-at-start text)]
    [saved : diag.CompilerDiagnostic
      (tc.tc-canonical-diagnostic
        (diag.compiler-diagnostic-with-note
          decoded
          "generated identity: generated:probe"))]
    ;; A later job resets compiler state; the escaped diagnostic must retain
    ;; its owned strings and complete expansion provenance.
    (expect-error "(define (main) : i64 missing)" "E0201" "typecheck")
    (test.assert-true
      (string.eq (diag.compiler-diagnostic-code-or-empty (& saved)) "E0506")
      "frame code")
    (test.assert-true
      (string.eq (diag.compiler-diagnostic-path (& saved)) "provider.tl")
      "innermost origin path")
    (test.assert-i64-eq
      (diag.compiler-diagnostic-line (& saved))
      3
      "primary span")
    (let
      [rendered : String (diag.compiler-diagnostic-render saved)]
      (test.assert-true
        (match (diag.compiler-diagnostic-help (& saved))
          [(CompilerDiagnosticSomeString help)
            (string.eq help "inspect the operand")]
          [CompilerDiagnosticNoString false])
        "help survives")
      (test.assert-true
        (string.contains (& rendered) "caller.tl:11:4")
        "outer invocation")
      (test.assert-true
        (string.contains (& rendered) "middle.tl:7:2")
        "inner invocation")
      (test.assert-true
        (string.contains (& rendered) "operand")
        "original secondary")
      (test.assert-true
        (string.contains (& rendered) "generated identity: generated:probe")
        "generated note"))))