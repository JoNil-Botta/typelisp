;; compiler_load_decl_run_smoke.tl - The loader's declaration walk folds runs of
;; ordinary declarations iteratively instead of recursing once per declaration.
;; The fixture mixes ordinary declarations with a module body and a macro-import
;; placeholder so both the iterative run path and the special-head arms run, and
;; pins the exact declaration/path/module lists and the threaded `seen` env the
;; per-declaration recursion produced.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_load)
(import compiler_ast_types as ast)
(import compiler_cfg_core as cfg)
(import compiler_intern as ci)
(import compiler_builtin_ids as cbi)
(import compiler_owned_view as owned_view)
(import compiler_parse_core as parser)
(import read as reader)
(import sym_i64_env)

(define (compiler-load-decl-run-name-id [text : String]) : i64
  (compiler_load.compiler-load-parse-context-name-id
    (owned_view.compiler-owned-shared-view text)))

(define (compiler-load-decl-run-def [name : String]) : ast.AstDecl
  (ast.ast-decl-def-id
    (compiler-load-decl-run-name-id name)
    (ast.AstMaybeType.No)
    0))

(define (compiler-load-decl-run-macro-import
  [path : String]
  [macro-name : String]) : ast.AstDecl
  (ast.AstDecl.Import
    (ast.ast-decl-meta-runtime-shared-view)
    (ast.AstImportSpec.Spec
      (ast.AstImportKind.Macro
        (compiler-load-decl-run-name-id macro-name)
        (ast.AstMaybeModuleName.No))
      path
      (ast.AstMaybeModuleName.No)
      (ast.AstMaybeImportAlias.No)
      (box (ast.ast-source-span 1 1 1 1)))))

;; Declarations in source order: two ordinary definitions, a module body holding
;; two more, another ordinary definition, a macro import (the Import arm that
;; needs no file on disk), two ordinary definitions around a module marker, and
;; a trailing ordinary definition. The first, third and fifth groups are the
;; maximal ordinary runs the walk now folds without recursing.
(define (compiler-load-decl-run-fixture) : ast.AstDeclList
  (ast.ast-decl-cons
    (compiler-load-decl-run-def "alpha")
    (ast.ast-decl-cons
      (compiler-load-decl-run-def "beta")
      (ast.ast-decl-cons
        (ast.ast-decl-module-body-id
          (compiler-load-decl-run-name-id "fixture.inner")
          (ast.ast-decl-cons
            (compiler-load-decl-run-def "inner-one")
            (ast.ast-decl-cons
              (compiler-load-decl-run-def "inner-two")
              (ast.ast-decl-list-new))))
        (ast.ast-decl-cons
          (compiler-load-decl-run-def "gamma")
          (ast.ast-decl-cons
            (compiler-load-decl-run-macro-import
              "fixture.macros"
              "fixture.macros")
            (ast.ast-decl-cons
              (compiler-load-decl-run-def "delta")
              (ast.ast-decl-cons
                (ast.ast-decl-module-id
                  (compiler-load-decl-run-name-id "fixture.epsilon"))
                (ast.ast-decl-cons
                  (compiler-load-decl-run-def "zeta")
                  (ast.ast-decl-list-new))))))))))

(define (compiler-load-decl-run-decl-text [decl : ast.AstDecl]) : String
  (match decl
    [(ast.AstDecl.Module name) (str_cat.str-cat "Module:" (ci.intern-str name))]
    [(ast.AstDecl.ModuleBody name _)
      (str_cat.str-cat "ModuleBody:" (ci.intern-str name))]
    [(ast.AstDecl.Def _ name _ _) (str_cat.str-cat "Def:" (ci.intern-str name))]
    [(ast.AstDecl.DefStruct _ name _ _ _)
      (str_cat.str-cat "DefStruct:" (ci.intern-str name))]
    [(ast.AstDecl.Import _ (ast.AstImportSpec.Spec _ path _ _ _))
      (str_cat.str-cat "Import:" path)]
    [_ "Other"]))

(define (compiler-load-decl-run-render-decls [decls : ast.AstDeclList]) : String
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    [out : String ""]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (compiler-load-decl-run-decl-text
                (ast.ast-decl-list-ref
                  (owned_view.compiler-owned-shared-view decls)
                  index))
              ";"))
          (set! index (+ index 1))))
      out)))

(define (compiler-load-decl-run-render-paths [paths : ast.AstDeclPathList]) : String
  (let
    [count : i64 (ast.ast-decl-path-list-len (& paths))]
    [index : i64 0]
    [out : String ""]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (ast.ast-decl-path-list-get (& paths) index "?")
              "@"
              (ci.intern-str
                (ast.ast-decl-path-list-owner-id (& paths) index -1))
              "/"
              (ci.intern-str
                (ast.ast-decl-path-list-provenance-id (& paths) index -1))
              ";"))
          (set! index (+ index 1))))
      out)))

(define (compiler-load-decl-run-render-modules
  [modules : ast.AstDeclModuleList]) : String
  (let
    [count : i64 (ast.ast-decl-module-list-len (& modules))]
    [index : i64 0]
    [out : String ""]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (ci.intern-str
                (ast.ast-decl-module-list-get-id (& modules) index -1))
              ";"))
          (set! index (+ index 1))))
      out)))

(define (compiler-load-decl-run-render-seen [seen : sym_i64_env.SymI64Env]) : String
  (let
    [cursor : sym_i64_env.SymI64Env seen]
    [out : String ""]
    [done : bool false]
    (begin
      (while (not done)
        (match (sym_i64_env.sym-i64-view
          (owned_view.compiler-owned-shared-view cursor))
          [(sym_i64_env.SymI64ViewNil) (set! done true)]
          [(sym_i64_env.SymI64ViewBind key value rest)
            (begin
              (set!
                out
                (str_cat.str-cat
                  out
                  (ci.intern-str key)
                  "="
                  (string.int->string value)
                  ";"))
              (set! cursor rest))]))
      out)))

(define (compiler-load-decl-run-shape) : String
  (let
    [outer-id : i64 (compiler-load-decl-run-name-id "fixture.outer")]
    [path-id : i64
      (compiler-load-decl-run-name-id
        "src/tests/compiler_load_decl_run_smoke.tl")]
    [seen : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        (sym_i64_env.sym-i64-empty)
        (compiler-load-decl-run-name-id "fixture.seeded")
        7)]
    (match (compiler_load.compiler-load-decls-with-module-and-roots-cfg-root
      (compiler-load-decl-run-fixture)
      "src/tests/compiler_load_decl_run_smoke.tl"
      path-id
      outer-id
      "fixture.outer"
      outer-id
      "fixture.outer"
      outer-id
      seen
      (svec.new)
      "src/tests"
      (cfg.compiler-cfg-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok
          decls
          paths
          modules
          out-seen)
        (str_cat.str-cat
          "decls["
          (compiler-load-decl-run-render-decls decls)
          "] paths["
          (compiler-load-decl-run-render-paths paths)
          "] modules["
          (compiler-load-decl-run-render-modules modules)
          "] seen["
          (compiler-load-decl-run-render-seen out-seen)
          "]")]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) "ERR"])))

(define (compiler-load-decl-run-expected-path [owner : String]) : String
  (str_cat.str-cat
    "src/tests/compiler_load_decl_run_smoke.tl@"
    owner
    "/src/tests/compiler_load_decl_run_smoke.tl;"))

;; Captured from the per-declaration recursion before the run-iteration landed.
(define (compiler-load-decl-run-expected-shape) : String
  (str_cat.str-cat
    "decls[Def:alpha;Def:beta;Module:fixture.inner;Def:inner-one;"
    "Def:inner-two;Module:fixture.outer;Def:gamma;Import:fixture.macros;"
    "Def:delta;Module:fixture.epsilon;Def:zeta;] paths["
    (compiler-load-decl-run-expected-path "fixture.outer")
    (compiler-load-decl-run-expected-path "fixture.outer")
    (compiler-load-decl-run-expected-path "fixture.inner")
    (compiler-load-decl-run-expected-path "fixture.inner")
    (compiler-load-decl-run-expected-path "fixture.inner")
    (compiler-load-decl-run-expected-path "fixture.outer")
    (compiler-load-decl-run-expected-path "fixture.outer")
    (compiler-load-decl-run-expected-path "fixture.outer")
    (compiler-load-decl-run-expected-path "fixture.outer")
    (compiler-load-decl-run-expected-path "fixture.outer")
    (compiler-load-decl-run-expected-path "fixture.outer")
    "] modules[fixture.outer;fixture.outer;fixture.inner;fixture.inner;"
    "fixture.inner;fixture.outer;fixture.outer;fixture.outer;"
    "fixture.outer;fixture.outer;fixture.outer;] seen[fixture.seeded=7;]"))

(test
  compiler-load-decl-ordinary-run-shape
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [got : String (compiler-load-decl-run-shape)]
      (if (string.eq
        (owned_view.compiler-owned-shared-view got)
        (compiler-load-decl-run-expected-shape))
        unit
        (io.panic
          (string.copy
            (str_cat.str-cat
              "compiler-load: ordinary-run walk changed the loaded shape: "
              got)))))))

;; Per-position source attribution. Every flattened declaration carries a decl
;; origin alias back to the slot it was read from, and the semantic origin
;; sidecar is resolved through that chain. Folding a run without rebuilding each
;; position's own list view attributes every row to the run's head instead, which
;; the list shape above cannot see: this pins the attribution itself.
(define (compiler-load-decl-run-origin-source) : String
  "(module cl_decl_run_origin)
(defstruct Alpha (alpha-field Shared.Type))
(defstruct Beta (beta-field Shared.Type))
(defstruct Gamma (gamma-field Shared.Type))")

(define (compiler-load-decl-run-origin-text
  [decls : (& decls ast.AstDeclList)]
  [index : i64]) : String
  (match (parser.compiler-parse-semantic-origin-run decls index)
    [(parser.CompilerParseMaybeSemanticOriginRun.Some run)
      (let
        [origin : parser.CompilerParseSemanticOrigin
          (parser.compiler-parse-semantic-origin-run-get
            (& run)
            0
            (parser.compiler-parse-semantic-origin-fallback))]
        [span : ast.AstSourceSpan origin.span]
        (str_cat.str-cat
          (ci.intern-str origin.written-name)
          "@"
          (string.int->string (ast.ast-source-span-start-line span))))]
    [(parser.CompilerParseMaybeSemanticOriginRun.None) "none"]))

(define (compiler-load-decl-run-origin-shape) : String
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [source : String (compiler-load-decl-run-origin-source)]
    [out : String "ERR"]
    (begin
      (io.write-file
        "target/cl_decl_run_origin.tl"
        (byte_buf.str-as-bytes (& source)))
      (match (compiler_load.compiler-load-file-with-paths
        "target/cl_decl_run_origin.tl"
        (sym_i64_env.sym-i64-empty))
        [(compiler_load.ResultCompilerLoadWithPaths.Ok decls _ _ _)
          (let
            [count : i64 (ast.ast-decl-list-len (& decls))]
            [index : i64 0]
            [text : String ""]
            (begin
              (while (< index count)
                (begin
                  (set!
                    text
                    (str_cat.str-cat
                      text
                      (compiler-load-decl-run-decl-text
                        (ast.ast-decl-list-ref
                          (owned_view.compiler-owned-shared-view decls)
                          index))
                      "/"
                      (compiler-load-decl-run-origin-text (& decls) index)
                      ";"))
                  (set! index (+ index 1))))
              (set! out text)))]
        [(compiler_load.ResultCompilerLoadWithPaths.Err _) unit])
      (reader.sp-node-pool-truncate! mark)
      (parser.compiler-parse-decl-origin-cache-reset!)
      out)))

;; Captured from the per-declaration recursion before the run-iteration landed.
(define (compiler-load-decl-run-expected-origin-shape) : String
  (str_cat.str-cat
    "Module:cl_decl_run_origin/cl_decl_run_origin@1;"
    "DefStruct:Alpha/Alpha@2;"
    "DefStruct:Beta/Beta@3;"
    "DefStruct:Gamma/Gamma@4;"))

(test
  compiler-load-decl-ordinary-run-origin-attribution
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [got : String (compiler-load-decl-run-origin-shape)]
      (if (string.eq
        (owned_view.compiler-owned-shared-view got)
        (compiler-load-decl-run-expected-origin-shape))
        unit
        (io.panic
          (string.copy
            (str_cat.str-cat
              "compiler-load: ordinary-run walk changed source attribution: "
              got)))))))