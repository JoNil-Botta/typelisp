(import compiler_typecheck_api as api)
(import compiler_typecheck_core as tc)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_diagnostic as diag)
(import compiler_owned_view as view)
(import stdlib.string)
(import stdlib.str_cat_runtime as cat)
(import stdlib.test)

(define (summary-snapshot [result : tc.ResultCompilerTypecheck]) : String
  (match result
    [(Ok (CompilerTypecheckSummary values functions externs))
      (cat.str-cat
        "ok:"
        (string.int->string values)
        ":"
        (string.int->string functions)
        ":"
        (string.int->string externs))]
    [(Err boxed)
      (let
        [diagnostics : diag.CompilerDiagnosticList
          (diag.compiler-diagnostic-list-box-shared-view boxed)]
        [out : String "error:"]
        [index : i64 0]
        (while (< index diagnostics.len)
          (set!
            out
            (cat.str-cat
              out
              (let
                [diag-arg (diag.compiler-diagnostic-list-get diagnostics index)]
                (diag.compiler-diagnostic-render diag-arg))
              "\n"))
          (set! index (+ index 1)))
        out)]))

(define (check-projection [source : String] [expected-kind : i64]) : unit
  (tc.compiler-typecheck-reset-file-state!)
  (tc.tc-prefix-snapshot-cache-clear!)
  (match (parser.parse-ast-source (string.copy source))
    [(Ok program)
      (let
        [before : i64 api.compiler-typecheck-pipeline-runs]
        [checked : tc.ResultCompilerTypecheckChecked
          (api.typecheck-compiler-program-with-paths-checked
            program
            (ast.ast-decl-path-list-new))]
        [kind : i64
          (match (view.compiler-owned-shared-view checked)
            [(Ok _ _ _ _) 0]
            [(Partial _ _ _ _) 1]
            [_ 2])]
        [projected : tc.ResultCompilerTypecheck
          (tc.tc-typecheck-checked-result-summary checked)]
        [expected : String (summary-snapshot projected)]
        (test.assert-i64-eq
          (- api.compiler-typecheck-pipeline-runs before)
          1
          "checked call runs one frontend")
        (test.assert-i64-eq
          kind
          expected-kind
          "fixture exercises the intended checked result")
        (tc.compiler-typecheck-reset-file-state!)
        (tc.tc-prefix-snapshot-cache-clear!)
        (match (parser.parse-ast-source source)
          [(Ok reparsed)
            (let
              [before : i64 api.compiler-typecheck-pipeline-runs]
              [actual : String
                (summary-snapshot (api.typecheck-compiler-program reparsed))]
              (test.assert-i64-eq
                (- api.compiler-typecheck-pipeline-runs before)
                1
                "summary call runs one frontend")
              (test.assert-true
                (string.eq actual expected)
                "summary projection preserves success or ordered diagnostics"))]
          [_ (test.assert-true false "fixture reparses")]))]
    [_ (test.assert-true false "fixture parses")]))

(test
  frontend-summary-projection
  (check-projection "(define (main) : i64 42)" 0)
  (check-projection "(define (a) : i64 true) (define (b) : bool 1)" 1)
  (check-projection "(define x : i64 1) (define x : i64 2)" 2)
  (check-projection
    "(defmacro (fail) : Expr (comptime-error \"projection macro failure\")) (define (main) : i64 (fail))"
    2)
  (check-projection
    "(define (bad [comptime T : type]) : i64 T) (define (main) : i64 (bad (type i64)))"
    2)
  (check-projection
    "(define (add [comptime n : i64] [x : i64]) : i64 (+ n x)) (define (main) : i64 (add 2 40))"
    0)
  (check-projection
    "(defmacro (emit) : Decls `(define (f) : i64 42)) (emit) (define (main) : i64 (f))"
    0))

(test
  frontend-parse-failure-skips-pipeline
  (let
    [before : i64 api.compiler-typecheck-pipeline-runs]
    [result : tc.ResultCompilerTypecheck (api.typecheck-compiler-source "(")]
    (test.assert-true
      (match result
        [(Err _) true]
        [_ false])
      "parse error remains an error")
    (test.assert-i64-eq
      api.compiler-typecheck-pipeline-runs
      before
      "parse failure does not enter the frontend")))