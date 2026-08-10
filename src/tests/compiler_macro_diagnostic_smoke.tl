;; compiler_macro_diagnostic_smoke.tl - Macro expansion provenance diagnostics.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import stdlib.string)
(import stdlib.str_cat)
(import compiler_ast_types as ast)
(import compiler_diagnostic as diagnostic)
(import compiler_load as load)
(import compiler_parse_core as parser)
(import compiler_typecheck_api as tc_api)
(import compiler_typecheck_core as tc_core)
(import sym_i64_env)

(define (macro-diagnostic-write-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (macro-diagnostic-frame-at?
  [labels : diagnostic.CompilerDiagnosticLabelList]
  [index : i64]
  [path : String]
  [line : i64]
  [col : i64]
  [macro-name : String]) : bool
  (if (>= index (diagnostic.compiler-diagnostic-label-list-count labels))
    false
    (let
      [entry : diagnostic.CompilerDiagnosticLabel
        (diagnostic.compiler-diagnostic-label-list-get labels index)]
      [span : diagnostic.CompilerDiagnosticSpan (struct-get entry span)]
      [needle : String
        (str_cat.str-cat "in expansion of macro `" macro-name "` invoked here")]
      (and
        (string.eq (diagnostic.compiler-diagnostic-span-path (& span)) path)
        (= (diagnostic.compiler-diagnostic-span-start-line (& span)) line)
        (= (diagnostic.compiler-diagnostic-span-start-col (& span)) col)
        (match (struct-get entry label)
          [(CompilerDiagnosticSomeString text) (string.eq text needle)]
          [CompilerDiagnosticNoString false])))))

(define (macro-diagnostic-source-shape?
  [src : String]
  [primary-line : i64]
  [primary-col : i64]
  [frame-count : i64]
  [first-line : i64]
  [first-col : i64]
  [first-name : String]
  [second-line : i64]
  [second-col : i64]
  [second-name : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(tc_core.ResultCompilerTypecheck.Err diagnostics)
      (let
        [diag : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first (box-get diagnostics))]
        [labels : diagnostic.CompilerDiagnosticLabelList
          (diagnostic.compiler-diagnostic-secondary-spans diag)]
        (and
          (not
            (string.contains
              (diagnostic.compiler-diagnostic-message diag)
              "__tl_"))
          (string.eq (diagnostic.compiler-diagnostic-path diag) "")
          (= (diagnostic.compiler-diagnostic-line diag) primary-line)
          (= (diagnostic.compiler-diagnostic-col diag) primary-col)
          (=
            (diagnostic.compiler-diagnostic-label-list-count labels)
            frame-count)
          (macro-diagnostic-frame-at?
            labels
            0
            ""
            first-line
            first-col
            first-name)
          (if (= frame-count 1)
            true
            (macro-diagnostic-frame-at?
              labels
              1
              ""
              second-line
              second-col
              second-name))))]
    [(tc_core.ResultCompilerTypecheck.Ok _) false]))

(define (macro-diagnostic-generated-frame-ok?) : bool
  (macro-diagnostic-source-shape?
    "(defmacro (bad [value : Expr]) : Expr
  `(+ ,value true))
(define (main) : i64 (bad 1))"
    2
    14
    1
    3
    22
    "bad"
    0
    0
    ""))

(define (macro-diagnostic-caller-frame-ok?) : bool
  (macro-diagnostic-source-shape?
    "(defmacro (callerbad [value : Expr]) : Expr
  value)
(define (main) : i64 (callerbad missing))"
    3
    33
    1
    3
    22
    "callerbad"
    0
    0
    ""))

(define (macro-diagnostic-nested-frame-ok?) : bool
  (macro-diagnostic-source-shape?
    "(defmacro (outer [value : Expr]) : Expr
  `(inner ,value))
(defmacro (inner [value : Expr]) : Expr
  `(+ ,value true))
(define (main) : i64 (outer 1))"
    4
    14
    2
    5
    22
    "outer"
    2
    4
    "inner"))

(define (macro-diagnostic-recursive-frame-ok?) : bool
  (macro-diagnostic-source-shape?
    "(defmacro (again) : Expr `(again))
(define (main) : i64 (again))"
    1
    27
    2
    2
    23
    "again"
    1
    28
    "again"))

(define (macro-diagnostic-eval-frame-ok?) : bool
  (macro-diagnostic-source-shape?
    "(defmacro (bad [values : Expr ...]) : Expr
  (expr-list-nth values 2))
(define (main) : i64 (bad 1))"
    1
    1
    1
    3
    23
    "bad"
    0
    0
    ""))

(define (macro-diagnostic-module-frame-ok?) : bool
  (macro-diagnostic-source-shape?
    "(defmacro (emit-module) : Module
  `(begin
    (module generated.bad)
    (define (bad) : i64 true)))
(import (emit-module) as bad)
(define (main) : i64 0)"
    4
    25
    1
    5
    1
    "emit-module"
    0
    0
    ""))

(define (macro-diagnostic-decls-frame-ok?) : bool
  (macro-diagnostic-source-shape?
    "(defmacro (emit-decls) : Decls
  `(define (bad) : i64 true))
(emit-decls)
(define (main) : i64 0)"
    2
    24
    1
    3
    1
    "emit-decls"
    0
    0
    ""))

(define (macro-diagnostic-loaded-shape?
  [entry-path : String]
  [roots : svec.Vec]
  [primary-path : String]
  [primary-line : i64]
  [primary-col : i64]
  [frame-line : i64]
  [frame-col : i64]
  [macro-name : String]) : bool
  (match (load.compiler-load-file-with-paths-and-roots-cfg
    entry-path
    (sym_i64_env.sym-i64-empty)
    roots
    (parser.compiler-cfg-empty))
    [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
      (match (tc_api.typecheck-compiler-program-with-paths
        (ast.ast-program decls)
        paths)
        [(tc_core.ResultCompilerTypecheck.Err diagnostics)
          (let
            [diag : diagnostic.CompilerDiagnostic
              (diagnostic.compiler-diagnostic-list-first (box-get diagnostics))]
            [labels : diagnostic.CompilerDiagnosticLabelList
              (diagnostic.compiler-diagnostic-secondary-spans diag)]
            [ok : bool
              (and
                (not
                  (string.contains
                    (diagnostic.compiler-diagnostic-message diag)
                    "__tl_"))
                (string.eq
                  (diagnostic.compiler-diagnostic-path diag)
                  primary-path)
                (= (diagnostic.compiler-diagnostic-line diag) primary-line)
                (= (diagnostic.compiler-diagnostic-col diag) primary-col)
                (= (diagnostic.compiler-diagnostic-label-list-count labels) 1)
                (macro-diagnostic-frame-at?
                  labels
                  0
                  entry-path
                  frame-line
                  frame-col
                  macro-name))]
            (if ok
              true
              (begin
                (io.print-error
                  (str_cat.str-cat
                    (diagnostic.compiler-diagnostic-render diag)
                    "\n"))
                false)))]
        [(tc_core.ResultCompilerTypecheck.Ok _) false])]
    [(load.ResultCompilerLoadWithPaths.Err _) false]))

(define (macro-diagnostic-import-frames-ok?) : bool
  (let
    [dir : String "target/tc_macro_diagnostic_frames"]
    [provider : String
      (load.compiler-load-join-root-path dir "tc_macro_diagnostic_provider.tl")]
    [generated-entry : String
      (load.compiler-load-join-root-path dir "generated_entry.tl")]
    [caller-entry : String
      (load.compiler-load-join-root-path dir "caller_entry.tl")]
    [binding-entry : String
      (load.compiler-load-join-root-path dir "binding_entry.tl")]
    [native-entry : String
      (load.compiler-load-join-root-path dir "native_entry.tl")]
    [roots : svec.Vec (svec.new)]
    (begin
      (load.compiler-load-test-mkdir dir)
      (macro-diagnostic-write-text
        provider
        "(module tc_macro_diagnostic_provider)
(defmacro (bad [value : Expr]) : Expr
  `(+ ,value true))
(defmacro (callerbad [value : Expr]) : Expr
  value)
(defmacro (bindingbad [binding : ExprBindingClause]) : Expr
  (comptime.expr-binding-clause-init binding))")
      (macro-diagnostic-write-text
        generated-entry
        "(import tc_macro_diagnostic_provider as dep)
(define (main) : i64 (dep.bad 1))")
      (macro-diagnostic-write-text
        caller-entry
        "(import tc_macro_diagnostic_provider as dep)
(define (main) : i64 (dep.callerbad missing))")
      (macro-diagnostic-write-text
        binding-entry
        "(import tc_macro_diagnostic_provider as dep)
(define (main) : i64 (dep.bindingbad [item missing]))")
      (macro-diagnostic-write-text
        native-entry
        "(import stdlib.core_macros)
(import stdlib.fs as fs)
(define (main) : String (fs.path-join-many missing))")
      (tc_api.compiler-typecheck-reset-load-session!)
      (let
        [generated-ok : bool
          (macro-diagnostic-loaded-shape?
            generated-entry
            roots
            provider
            3
            14
            2
            22
            "tc_macro_diagnostic_provider/bad")]
        (begin
          (unless
            generated-ok
            (io.panic "typecheck: imported generated macro frame smoke failed"))
          (tc_api.compiler-typecheck-reset-load-session!)
          (let
            [caller-ok : bool
              (macro-diagnostic-loaded-shape?
                caller-entry
                roots
                caller-entry
                2
                37
                2
                22
                "tc_macro_diagnostic_provider/callerbad")]
            (begin
              (unless
                caller-ok
                (io.panic "typecheck: imported caller macro frame smoke failed"))
              (tc_api.compiler-typecheck-reset-load-session!)
              (let
                [binding-ok : bool
                  (macro-diagnostic-loaded-shape?
                    binding-entry
                    roots
                    binding-entry
                    2
                    44
                    2
                    22
                    "tc_macro_diagnostic_provider/bindingbad")]
                (begin
                  (unless
                    binding-ok
                    (io.panic
                      "typecheck: imported binding-clause macro frame smoke failed"))
                  (tc_api.compiler-typecheck-reset-load-session!)
                  (let
                    [native-ok : bool
                      (macro-diagnostic-loaded-shape?
                        native-entry
                        roots
                        native-entry
                        3
                        44
                        3
                        26
                        "stdlib.fs/path-join-many")]
                    (begin
                      (unless
                        native-ok
                        (io.panic
                          "typecheck: native stdlib macro frame smoke failed"))
                      (tc_api.compiler-typecheck-reset-load-session!)
                      true)))))))))))

(define (main) : i64
  (unless
    (macro-diagnostic-generated-frame-ok?)
    (io.panic "typecheck: generated macro diagnostic frame smoke failed"))
  (unless
    (macro-diagnostic-caller-frame-ok?)
    (io.panic "typecheck: caller macro diagnostic frame smoke failed"))
  (unless
    (macro-diagnostic-nested-frame-ok?)
    (io.panic "typecheck: nested macro diagnostic frame smoke failed"))
  (unless
    (macro-diagnostic-recursive-frame-ok?)
    (io.panic "typecheck: recursive macro diagnostic frame smoke failed"))
  (unless
    (macro-diagnostic-eval-frame-ok?)
    (io.panic "typecheck: eval macro diagnostic frame smoke failed"))
  (unless
    (macro-diagnostic-module-frame-ok?)
    (io.panic "typecheck: module macro diagnostic frame smoke failed"))
  (unless
    (macro-diagnostic-decls-frame-ok?)
    (io.panic "typecheck: decl macro diagnostic frame smoke failed"))
  (unless
    (macro-diagnostic-import-frames-ok?)
    (io.panic "typecheck: imported macro diagnostic frame smoke failed"))
  42)