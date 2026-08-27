;; compiler_load_lazy_smoke.tl - Lazy dotted import loader smokes.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_load)
(import compiler_cfg_core as cfg)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_parse_core as parser)
(import read as reader)
(import sym_i64_env)

(define (lazy-write-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (lazy-unused-dotted-import-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_dotted")
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_dotted/nested")
    (lazy-write-text
      "target/cl_lazy_dotted/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (lazy-write-text
      "target/cl_lazy_dotted/entry.tl"
      "(module lazy.dotted.entry)
(import nested.dep as dep)
;; dep.get in a comment must not demand the import.
(define (main) : i64
  (begin
    \"dep.get\"
    42))")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_dotted/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 1)
          (= (compiler_load.compiler-load-decl-list-count decls) 3)
          (compiler_load.compiler-load-decl-list-has-import-alias?
            decls
            "nested.dep"
            "dep")
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "lazy.dotted.entry")
          (not
            (compiler_load.compiler-load-test-seen-contains? seen "nested.dep")))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-used-dotted-import-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_dotted_used")
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_dotted_used/nested")
    (lazy-write-text
      "target/cl_lazy_dotted_used/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (lazy-write-text
      "target/cl_lazy_dotted_used/entry.tl"
      "(module lazy.dotted.used.entry)
(import nested.dep as dep)
(define (main) : i64 (dep.get))")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_dotted_used/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "lazy.dotted.used.entry")
          (compiler_load.compiler-load-test-seen-contains? seen "nested.dep"))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-used-stdlib-array-dotted-import-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_stdlib_array")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_stdlib_array/nested")
    (lazy-write-text
      "target/cl_lazy_stdlib_array/nested/user.tl"
      "(module nested.user)
(define (len-b) : i64 (array-length (__tl_make-array i64 2)))")
    (lazy-write-text
      "target/cl_lazy_stdlib_array/entry.tl"
      "(module lazy.stdlib.array.entry)
(import nested.user as user)
(define (len-a) : i64 (array-length (__tl_make-array i64 1)))
(define (main) : i64 (user.len-b))")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_stdlib_array/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
          (compiler_load.compiler-load-decl-list-has-import-alias?
            decls
            "stdlib.array"
            "array")
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "lazy.stdlib.array.entry")
          (compiler_load.compiler-load-test-seen-contains? seen "nested.user")
          (compiler_load.compiler-load-test-seen-contains? seen "stdlib.array"))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-canonical-stdlib-array-import-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_stdlib_array_canonical")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_stdlib_array_canonical/nested")
    (lazy-write-text
      "target/cl_lazy_stdlib_array_canonical/nested/user.tl"
      "(module nested.user)
(define (len-b) : i64
  (stdlib.array-length (stdlib.__tl_make-array i64 2)))")
    (lazy-write-text
      "target/cl_lazy_stdlib_array_canonical/entry.tl"
      "(module lazy.stdlib.array.canonical.entry)
(import nested.user as user)
(define (len-a) : i64
  (stdlib.array-length (stdlib.__tl_make-array i64 1)))
(define (main) : i64 (user.len-b))")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_stdlib_array_canonical/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 2)
          (= (compiler_load.compiler-load-decl-list-count decls) 9)
          (compiler_load.compiler-load-decl-list-has-import-alias?
            decls
            "stdlib.array"
            "array")
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "lazy.stdlib.array.canonical.entry")
          (compiler_load.compiler-load-test-seen-contains? seen "nested.user")
          (not
            (compiler_load.compiler-load-test-seen-contains?
              seen
              "stdlib.array")))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-stdlib-result-macro-import-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_stdlib_result")
    (lazy-write-text
      "target/cl_lazy_stdlib_result/entry.tl"
      "(module lazy.stdlib.result.entry)
(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (main) : i64 42)")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_stdlib_result/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
          (compiler_load.compiler-load-decl-list-has-import-alias?
            decls
            "stdlib.result"
            "result")
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "lazy.stdlib.result.entry")
          (compiler_load.compiler-load-test-seen-contains? seen "stdlib.result"))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-direct-module-macro-demand-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_module_macro")
    (lazy-write-text
      "target/cl_lazy_module_macro/entry.tl"
      "(module lazy.module.macro.entry)
(import stdlib.option)
(import (option.option i64) as option_i64)
(define (main) : i64 42)")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_module_macro/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "lazy.module.macro.entry")
          (compiler_load.compiler-load-test-seen-contains? seen "stdlib.option"))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-unused-module-macro-import-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_unused_module_macro")
    (lazy-write-text
      "target/cl_lazy_unused_module_macro/entry.tl"
      "(module lazy.unused.module.macro.entry)
(import stdlib.option)
(define (main) : i64 42)")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_unused_module_macro/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 1)
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "lazy.unused.module.macro.entry")
          (not
            (compiler_load.compiler-load-test-seen-contains?
              seen
              "stdlib.option")))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-aliased-module-macro-demand-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_aliased_module_macro")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_aliased_module_macro/generic")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_aliased_module_macro/generic/macro")
    (lazy-write-text
      "target/cl_lazy_aliased_module_macro/generic/macro/dep.tl"
      "(module generic.macro.dep)
(defmacro (make [T : type]) : Module (expr-unit))")
    (lazy-write-text
      "target/cl_lazy_aliased_module_macro/entry.tl"
      "(module lazy.aliased.module.macro.entry)
(import generic.macro.dep as api)
(import (make i64) as made)
(define (main) : i64 42)")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_aliased_module_macro/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "lazy.aliased.module.macro.entry")
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "generic.macro.dep"))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-qualified-module-macro-demand-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_qualified_module_macro")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_qualified_module_macro/generic")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_qualified_module_macro/generic/macro")
    (lazy-write-text
      "target/cl_lazy_qualified_module_macro/generic/macro/dep.tl"
      "(module generic.macro.dep)
(defmacro (make [T : type]) : Module (expr-unit))")
    (lazy-write-text
      "target/cl_lazy_qualified_module_macro/entry.tl"
      "(module lazy.qualified.module.macro.entry)
(import generic.macro.dep as api)
(import (generic.macro.dep.make i64) as made)
(define (main) : i64 42)")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_qualified_module_macro/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "lazy.qualified.module.macro.entry")
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "generic.macro.dep"))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-stdlib-vector-qualified-module-macro-demand-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_stdlib_vector_module_macro")
    (lazy-write-text
      "target/cl_lazy_stdlib_vector_module_macro/entry.tl"
      "(module lazy.stdlib.vector.module.macro.entry)
(import stdlib.vector)
(import (stdlib.vector.vector i64) as vec)
(define (main) : i64 42)")
    (let
      [cfgs : sym_i64_env.SymI64Env (cfg.compiler-cfg-empty)]
      (match (compiler_load.compiler-load-file-with-paths-and-roots-cfg
        "target/cl_lazy_stdlib_vector_module_macro/entry.tl"
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        cfgs)
        [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
          (and
            (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
            (compiler_load.compiler-load-test-seen-contains?
              seen
              "lazy.stdlib.vector.module.macro.entry")
            (compiler_load.compiler-load-test-seen-contains?
              seen
              "stdlib.vector"))]
        [(compiler_load.ResultCompilerLoadWithPaths.Err _) false]))))

(define (package-lazy-unused-dotted-import-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_pkg_lazy_dotted")
    (compiler_load.compiler-load-test-mkdir "target/cl_pkg_lazy_dotted/nested")
    (lazy-write-text
      "target/cl_pkg_lazy_dotted/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (lazy-write-text
      "target/cl_pkg_lazy_dotted/entry.tl"
      "(module pkg.lazy.dotted.entry)
(import nested.dep as dep)
(define (main) : i64 42)")
    (match (compiler_load.compiler-load-package-file-with-paths-and-roots
      "target/cl_pkg_lazy_dotted/entry.tl"
      (sym_i64_env.sym-i64-empty)
      (svec.new)
      "target/cl_pkg_lazy_dotted"
      (compiler_load.compiler-pkg-deps-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 1)
          (= (compiler_load.compiler-load-decl-list-count decls) 3)
          (compiler_load.compiler-load-decl-list-has-import-alias?
            decls
            "nested.dep"
            "dep")
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "pkg.lazy.dotted.entry")
          (not
            (compiler_load.compiler-load-test-seen-contains? seen "nested.dep")))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (package-lazy-used-dotted-import-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_pkg_lazy_dotted_used")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_pkg_lazy_dotted_used/nested")
    (lazy-write-text
      "target/cl_pkg_lazy_dotted_used/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (lazy-write-text
      "target/cl_pkg_lazy_dotted_used/entry.tl"
      "(module pkg.lazy.dotted.used.entry)
(import nested.dep as dep)
(define (main) : i64 (dep.get))")
    (match (compiler_load.compiler-load-package-file-with-paths-and-roots
      "target/cl_pkg_lazy_dotted_used/entry.tl"
      (sym_i64_env.sym-i64-empty)
      (svec.new)
      "target/cl_pkg_lazy_dotted_used"
      (compiler_load.compiler-pkg-deps-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "pkg.lazy.dotted.used.entry")
          (compiler_load.compiler-load-test-seen-contains? seen "nested.dep"))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-local-alias-does-not-demand-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_local_alias")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_local_alias/generic")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_local_alias/generic/local")
    (lazy-write-text
      "target/cl_lazy_local_alias/generic/local/dep.tl"
      "(module generic.local.dep)
(define (get) : i64 7)")
    (lazy-write-text
      "target/cl_lazy_local_alias/entry.tl"
      "(module generic.local.entry)
(import generic.local.dep as dep)
(define (main) : i64
  (let
    [dep : i64 42]
    dep))")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_local_alias/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 1)
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "generic.local.entry")
          (not
            (compiler_load.compiler-load-test-seen-contains?
              seen
              "generic.local.dep")))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-generic-qualified-surface-demand-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_generic_surface")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_generic_surface/generic")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_generic_surface/generic/surface")
    (lazy-write-text
      "target/cl_lazy_generic_surface/generic/surface/dep.tl"
      "(module generic.surface.dep)
(defenum Choice (Empty) (Full i64))
(define (get) : i64 7)
(defmacro (number) : Expr 5)")
    (lazy-write-text
      "target/cl_lazy_generic_surface/entry.tl"
      "(module generic.surface.entry)
(import generic.surface.dep as dep)
(define (score [value : dep.Choice]) : i64
  (match value
    [(dep.Choice.Empty) 0]
    [(dep.Choice.Full n) (+ n (dep.get))]))
(define (main) : i64 (dep.number))")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_generic_surface/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "generic.surface.entry")
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "generic.surface.dep"))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-generic-direct-surface-demand-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_generic_direct")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_generic_direct/generic")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_generic_direct/generic/direct")
    (lazy-write-text
      "target/cl_lazy_generic_direct/generic/direct/dep.tl"
      "(module generic.direct.dep)
(define (get) : i64 7)")
    (lazy-write-text
      "target/cl_lazy_generic_direct/entry.tl"
      "(module generic.direct.entry)
(import generic.direct.dep as dep)
(define (main) : i64 (get))")
    (match (compiler_load.compiler-load-file-with-paths
      "target/cl_lazy_generic_direct/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "generic.direct.entry")
          (compiler_load.compiler-load-test-seen-contains?
            seen
            "generic.direct.dep"))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-cfg-selected-surface-demand-ok?) : bool
  (begin
    (compiler_load.compiler-load-test-mkdir "target/cl_lazy_cfg_surface")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_cfg_surface/generic")
    (compiler_load.compiler-load-test-mkdir
      "target/cl_lazy_cfg_surface/generic/cfg")
    (lazy-write-text
      "target/cl_lazy_cfg_surface/generic/cfg/dep.tl"
      "(module generic.cfg.dep)
(cfg feature (define (get) : i64 7))")
    (lazy-write-text
      "target/cl_lazy_cfg_surface/entry.tl"
      "(module generic.cfg.entry)
(import generic.cfg.dep as dep)
(cfg feature (define (main) : i64 (dep.get)))")
    (let
      [cfgs : sym_i64_env.SymI64Env
        (cfg.compiler-cfg-enable (cfg.compiler-cfg-empty) "feature")]
      (match (compiler_load.compiler-load-file-with-paths-and-roots-cfg
        "target/cl_lazy_cfg_surface/entry.tl"
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        cfgs)
        [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ seen)
          (and
            (= (compiler_load.compiler-load-lazy-import-skip-count) 0)
            (compiler_load.compiler-load-test-seen-contains?
              seen
              "generic.cfg.entry")
            (compiler_load.compiler-load-test-seen-contains?
              seen
              "generic.cfg.dep"))]
        [(compiler_load.ResultCompilerLoadWithPaths.Err _) false]))))

(define (structural-member-demand-source [source : String] [alias : i64]) : compiler_load.CompilerLoadStructuralMemberDemand
  (match (compiler_load.compiler-load-parse-source-diagnostic-escaping
    "src/structural_member_demand.tl"
    source
    (cfg.compiler-cfg-empty))
    [(ResultAstProgramDiagnostic.Ok (ast.AstProgram.Program decls))
      (compiler_load.compiler-load-structural-member-demand
        (ast.ast-decl-list-box-shared-view decls)
        alias)]
    [(ResultAstProgramDiagnostic.Err _) (CompilerLoadStructuralFullDemand)]))

(define (structural-member-demand-no-use-ok?) : bool
  (match (structural-member-demand-source
    "(module demand.none)
(define (main) : i64 42)"
    cbi.compiler-builtin-id-fix-subject)
    [(CompilerLoadStructuralNoDemand) true]
    [_ false]))

(define (structural-member-demand-one-ok?) : bool
  (let
    [demand : compiler_load.CompilerLoadStructuralMemberDemand
      (structural-member-demand-source
        "(module demand.one)
(define (main) : i64 (subject.value))"
        cbi.compiler-builtin-id-fix-subject)]
    (and
      (= (compiler_load.compiler-load-structural-member-demand-count demand) 1)
      (compiler_load.compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-value))))

(define (structural-member-demand-union-ok?) : bool
  (let
    [demand : compiler_load.CompilerLoadStructuralMemberDemand
      (structural-member-demand-source
        "(module demand.union)
(define (main) : i64
  (begin
    (subject.left)
    (subject/right)
    (subject.left)))"
        cbi.compiler-builtin-id-fix-subject)]
    (and
      (= (compiler_load.compiler-load-structural-member-demand-count demand) 2)
      (compiler_load.compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-left)
      (compiler_load.compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-right))))

(define (structural-member-demand-shadowing-ok?) : bool
  (and
    (match (structural-member-demand-source
      "(module demand.local)
(define (main) : i64 (let [subject : i64 42] subject))"
      cbi.compiler-builtin-id-fix-subject)
      [(CompilerLoadStructuralNoDemand) true]
      [_ false])
    (match (structural-member-demand-source
      "(module demand.param)
(define (use [subject : i64]) : i64 subject)"
      cbi.compiler-builtin-id-fix-subject)
      [(CompilerLoadStructuralNoDemand) true]
      [_ false])
    (match (structural-member-demand-source
      "(module demand.pattern)
(define (main) : i64 (match 42 [subject subject]))"
      cbi.compiler-builtin-id-fix-subject)
      [(CompilerLoadStructuralNoDemand) true]
      [_ false])))

(define (structural-member-demand-nested-scope-ok?) : bool
  (let
    [demand : compiler_load.CompilerLoadStructuralMemberDemand
      (structural-member-demand-source
        "(module demand.nested)
(module local.scope
  (define (shadow [api : i64]) : i64 api))
(define (main) : i64
  (begin
    ((lambda ([subject : i64]) : i64 subject) 1)
    (subject.same)))"
        cbi.compiler-builtin-id-fix-subject)]
    (and
      (= (compiler_load.compiler-load-structural-member-demand-count demand) 1)
      (compiler_load.compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-same))))

(define (structural-member-demand-unknown-ok?) : bool
  (match (compiler_load.compiler-load-parse-source-diagnostic-escaping
    "src/structural_member_demand_unknown.tl"
    "(module demand.unknown)
(defstruct Aggregate (value i64))"
    (cfg.compiler-cfg-empty))
    [(ResultAstProgramDiagnostic.Ok (ast.AstProgram.Program decls))
      (match (compiler_load.compiler-load-structural-member-demand
        (ast.ast-decl-list-box-shared-view decls)
        cbi.compiler-builtin-id-fix-subject)
        [(CompilerLoadStructuralFullDemand) true]
        [_ false])]
    [(ResultAstProgramDiagnostic.Err _) false]))

(define (lazy-preload-observer-state-isolation-ok?) : bool
  (match (compiler_load.compiler-load-parse-source-diagnostic-escaping
    "src/lazy_preload_observer_state_isolation.tl"
    "(module demand.isolation)
(define (main) : i64 (subject.same))"
    (cfg.compiler-cfg-empty))
    [(ResultAstProgramDiagnostic.Ok (ast.AstProgram.Program decls))
      (let
        [previous-state : compiler_load.CompilerLoadSessionState
          (compiler_load.compiler-load-active-session-state-shared-view)]
        [state-a : compiler_load.CompilerLoadSessionState
          (compiler_load.compiler-load-session-state-new)]
        [state-b : compiler_load.CompilerLoadSessionState
          (compiler_load.compiler-load-session-state-new)]
        [alias : i64 cbi.compiler-builtin-id-fix-subject]
        [member : i64 cbi.compiler-builtin-id-fix-same]
        [pools : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        [_select-b : unit
          (compiler_load.compiler-load-session-state-use!
            (compiler_load.compiler-load-session-state-shared-view (& state-b)))]
        [_begin-a : unit
          (compiler_load.compiler-load-session-state-lazy-qualified-observer-begin-pair!
            (& state-a)
            alias
            cbi.compiler-builtin-id-fix-empty)]
        [_begin-b : unit
          (compiler_load.compiler-load-session-state-lazy-qualified-observer-begin-pair!
            (& state-b)
            alias
            cbi.compiler-builtin-id-fix-empty)]
        [demand : compiler_load.CompilerLoadLazyAliasDemand
          (compiler_load.compiler-load-session-state-lazy-import-preload-demand
            (compiler_load.compiler-load-session-state-shared-view (& state-a))
            true
            (ast.AstMaybeImportAlias.Some alias)
            (ast.ast-decl-list-box-shared-view decls)
            pools)]
        [observed-a : compiler_load.CompilerLoadLazyQualifiedObserverResult
          (compiler_load.compiler-load-session-state-lazy-qualified-observer-end-pair!
            (& state-a))]
        [b-still-active : bool
          (compiler_load.compiler-load-session-state-lazy-qualified-observer-active?
            (& state-b))]
        [observed-b : compiler_load.CompilerLoadLazyQualifiedObserverResult
          (compiler_load.compiler-load-session-state-lazy-qualified-observer-end-pair!
            (& state-b))]
        [ok : bool
          (and
            demand.qualified
            (not demand.unknown)
            (sym_i64_env.sym-i64-contains-id demand.members member)
            (sym_i64_env.sym-i64-contains-id observed-a.primary-members member)
            b-still-active
            (not
              (sym_i64_env.sym-i64-contains-id
                observed-b.primary-members
                member)))]
        (begin
          (compiler_load.compiler-load-session-state-use! previous-state)
          ok))]
    [(ResultAstProgramDiagnostic.Err _) false]))

(define (lazy-semantic-origin-same-defstruct-ok?
  [decls : (& decls ast.AstDeclList)]) : bool
  (match (parser.compiler-parse-semantic-origin-run decls 0)
    [(parser.CompilerParseMaybeSemanticOriginRun.Some run)
      (let
        [type-origin : parser.CompilerParseSemanticOrigin
          (parser.compiler-parse-semantic-origin-run-get
            (& run)
            0
            (parser.compiler-parse-semantic-origin-fallback))]
        [field-origin : parser.CompilerParseSemanticOrigin
          (parser.compiler-parse-semantic-origin-run-get
            (& run)
            1
            (parser.compiler-parse-semantic-origin-fallback))]
        [type-span : ast.AstSourceSpan type-origin.span]
        [field-span : ast.AstSourceSpan field-origin.span]
        (and
          (= (parser.compiler-parse-semantic-origin-run-len (& run)) 4)
          (string.eq
            (parser.compiler-parse-semantic-origin-kind-marker type-origin.kind)
            "__tl_semantic_origin_type_definition")
          (string.eq (ci.intern-str type-origin.written-name) "Same")
          (= (ast.ast-source-span-start-line type-span) 3)
          (= (ast.ast-source-span-start-col type-span) 12)
          (= (ast.ast-source-span-end-line type-span) 3)
          (= (ast.ast-source-span-end-col type-span) 16)
          (string.eq
            (parser.compiler-parse-semantic-origin-kind-marker
              field-origin.kind)
            "__tl_semantic_origin_struct_field_definition")
          (string.eq (ci.intern-str field-origin.written-name) "same-field")
          (= (ast.ast-source-span-start-line field-span) 3)
          (= (ast.ast-source-span-start-col field-span) 18)
          (= (ast.ast-source-span-end-line field-span) 3)
          (= (ast.ast-source-span-end-col field-span) 28)))]
    [(parser.CompilerParseMaybeSemanticOriginRun.None) false]))

(define (lazy-semantic-origin-same-count
  [decls : ast.AstDeclList]
  [count : i64]) : i64
  (match (ast.ast-decl-list-step (ast.ast-place-shared-view decls))
    [(ast.AstDeclListStep.Nil) count]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(ast.AstDecl.DefStruct _ name _ _ _)
            (if (string.eq (ci.intern-str name) "Same")
              (if (lazy-semantic-origin-same-defstruct-ok? (& decls))
                (lazy-semantic-origin-same-count rest (+ count 1))
                -100)
              (lazy-semantic-origin-same-count rest count))]
          [_ (lazy-semantic-origin-same-count rest count)]))]))

(define (lazy-semantic-origin-import-flatten-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool false]
    (begin
      (lazy-write-text
        "target/cl_semantic_origin_dep.tl"
        "(module cl_semantic_origin_dep)
(define dep-padding : i64 0)
(defstruct Same (same-field Shared.Type))")
      (lazy-write-text
        "target/cl_semantic_origin_entry.tl"
        "(module cl_semantic_origin_entry)
(import cl_semantic_origin_dep as dep)
(defstruct Same (same-field Shared.Type))")
      (match (compiler_load.compiler-load-file-with-paths
        "target/cl_semantic_origin_entry.tl"
        (sym_i64_env.sym-i64-empty))
        [(compiler_load.ResultCompilerLoadWithPaths.Ok decls _ _ _)
          (set! ok (= (lazy-semantic-origin-same-count decls 0) 2))]
        [(compiler_load.ResultCompilerLoadWithPaths.Err _) unit])
      (reader.sp-node-pool-truncate! mark)
      (parser.compiler-parse-decl-origin-cache-reset!)
      ok)))

(define (main) : i64
  (begin
    (unless
      (lazy-unused-dotted-import-ok?)
      (return (io.panic "lazy unused dotted import smoke mismatch")))
    (unless
      (lazy-used-dotted-import-ok?)
      (return (io.panic "lazy used dotted import smoke mismatch")))
    (unless
      (lazy-used-stdlib-array-dotted-import-ok?)
      (return (io.panic "lazy used stdlib.array dotted import smoke mismatch")))
    (unless
      (lazy-canonical-stdlib-array-import-ok?)
      (return (io.panic "lazy canonical stdlib.array import smoke mismatch")))
    (unless
      (lazy-stdlib-result-macro-import-ok?)
      (return (io.panic "lazy stdlib.result macro import smoke mismatch")))
    (unless
      (lazy-direct-module-macro-demand-ok?)
      (return (io.panic "lazy direct module macro demand smoke mismatch")))
    (unless
      (lazy-unused-module-macro-import-ok?)
      (return (io.panic "lazy unused module macro import smoke mismatch")))
    (unless
      (lazy-aliased-module-macro-demand-ok?)
      (return (io.panic "lazy aliased module macro demand smoke mismatch")))
    (unless
      (lazy-qualified-module-macro-demand-ok?)
      (return (io.panic "lazy qualified module macro demand smoke mismatch")))
    (unless
      (lazy-stdlib-vector-qualified-module-macro-demand-ok?)
      (return
        (io.panic
          "lazy stdlib.vector qualified module macro demand smoke mismatch")))
    (unless
      (package-lazy-unused-dotted-import-ok?)
      (return (io.panic "package lazy unused dotted import smoke mismatch")))
    (unless
      (package-lazy-used-dotted-import-ok?)
      (return (io.panic "package lazy used dotted import smoke mismatch")))
    (unless
      (lazy-local-alias-does-not-demand-ok?)
      (return (io.panic "lazy local alias demand smoke mismatch")))
    (unless
      (lazy-generic-qualified-surface-demand-ok?)
      (return (io.panic "lazy generic qualified surface demand smoke mismatch")))
    (unless
      (lazy-generic-direct-surface-demand-ok?)
      (return (io.panic "lazy generic direct surface demand smoke mismatch")))
    (unless
      (lazy-cfg-selected-surface-demand-ok?)
      (return (io.panic "lazy cfg-selected surface demand smoke mismatch")))
    (unless
      (structural-member-demand-no-use-ok?)
      (return (io.panic "structural member no-use demand mismatch")))
    (unless
      (structural-member-demand-one-ok?)
      (return (io.panic "structural member one demand mismatch")))
    (unless
      (structural-member-demand-union-ok?)
      (return (io.panic "structural member union demand mismatch")))
    (unless
      (structural-member-demand-shadowing-ok?)
      (return (io.panic "structural member shadowing demand mismatch")))
    (unless
      (structural-member-demand-nested-scope-ok?)
      (return (io.panic "structural member nested-scope demand mismatch")))
    (unless
      (structural-member-demand-unknown-ok?)
      (return (io.panic "structural member unknown demand mismatch")))
    (unless
      (lazy-preload-observer-state-isolation-ok?)
      (return (io.panic "lazy preload observer isolation smoke mismatch")))
    (unless
      (lazy-semantic-origin-import-flatten-ok?)
      (return (io.panic "lazy semantic origin import flatten smoke mismatch")))
    (unless
      (compiler_load.compiler-load-lazy-qualified-observer-dense-stack-ok?)
      (return (io.panic "lazy observer dense stack smoke mismatch")))
    42))