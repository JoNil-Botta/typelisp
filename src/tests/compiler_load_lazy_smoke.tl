;; compiler_load_lazy_smoke.tl - Lazy dotted import loader smokes.
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import "../compiler_load.tl")
(import compiler_builtin_ids as cbi)
(import sym_i64_env)

(define (lazy-unused-dotted-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_dotted")
    (compiler-load-test-mkdir "target/cl_lazy_dotted/nested")
    (io.write-file
      "target/cl_lazy_dotted/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_lazy_dotted/entry.tl"
      "(module lazy.dotted.entry)
(import nested.dep as dep)
;; dep.get in a comment must not demand the import.
(define (main) : i64
  (begin
    \"dep.get\"
    42))")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_dotted/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 1)
          (= (compiler-load-decl-list-count decls) 3)
          (compiler-load-decl-list-has-import-alias? decls "nested.dep" "dep")
          (compiler-load-test-seen-contains? seen "lazy.dotted.entry")
          (not (compiler-load-test-seen-contains? seen "nested.dep")))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-used-dotted-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_dotted_used")
    (compiler-load-test-mkdir "target/cl_lazy_dotted_used/nested")
    (io.write-file
      "target/cl_lazy_dotted_used/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_lazy_dotted_used/entry.tl"
      "(module lazy.dotted.used.entry)
(import nested.dep as dep)
(define (main) : i64 (dep.get))")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_dotted_used/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (compiler-load-test-seen-contains? seen "lazy.dotted.used.entry")
          (compiler-load-test-seen-contains? seen "nested.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-used-stdlib-array-dotted-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_array")
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_array/nested")
    (io.write-file
      "target/cl_lazy_stdlib_array/nested/user.tl"
      "(module nested.user)
(import stdlib.array)
(define (len-b) : i64 (array.length (array.make-array i64 2)))")
    (io.write-file
      "target/cl_lazy_stdlib_array/entry.tl"
      "(module lazy.stdlib.array.entry)
(import stdlib.array)
(import nested.user as user)
(define (len-a) : i64 (array.length (array.make-array i64 1)))
(define (main) : i64 (user.len-b))")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_stdlib_array/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (compiler-load-decl-list-has-import-alias?
            decls
            "stdlib.array"
            "array")
          (compiler-load-test-seen-contains? seen "lazy.stdlib.array.entry")
          (compiler-load-test-seen-contains? seen "nested.user")
          (compiler-load-test-seen-contains? seen "stdlib.array"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-canonical-stdlib-array-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_array_canonical")
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_array_canonical/nested")
    (io.write-file
      "target/cl_lazy_stdlib_array_canonical/nested/user.tl"
      "(module nested.user)
(import stdlib.array)
(define (len-b) : i64
  (stdlib.array.length (stdlib.array.make-array i64 2)))")
    (io.write-file
      "target/cl_lazy_stdlib_array_canonical/entry.tl"
      "(module lazy.stdlib.array.canonical.entry)
(import stdlib.array)
(import nested.user as user)
(define (len-a) : i64
  (stdlib.array.length (stdlib.array.make-array i64 1)))
(define (main) : i64 (user.len-b))")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_stdlib_array_canonical/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 2)
          (= (compiler-load-decl-list-count decls) 9)
          (compiler-load-decl-list-has-import-alias?
            decls
            "stdlib.array"
            "array")
          (compiler-load-test-seen-contains?
            seen
            "lazy.stdlib.array.canonical.entry")
          (compiler-load-test-seen-contains? seen "nested.user")
          (not (compiler-load-test-seen-contains? seen "stdlib.array")))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-stdlib-result-macro-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_result")
    (io.write-file
      "target/cl_lazy_stdlib_result/entry.tl"
      "(module lazy.stdlib.result.entry)
(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (main) : i64 42)")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_stdlib_result/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (compiler-load-decl-list-has-import-alias?
            decls
            "stdlib.result"
            "result")
          (compiler-load-test-seen-contains? seen "lazy.stdlib.result.entry")
          (compiler-load-test-seen-contains? seen "stdlib.result"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-direct-module-macro-demand-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_module_macro")
    (io.write-file
      "target/cl_lazy_module_macro/entry.tl"
      "(module lazy.module.macro.entry)
(import stdlib.option)
(import (option.option i64) as option_i64)
(define (main) : i64 42)")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_module_macro/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (compiler-load-test-seen-contains? seen "lazy.module.macro.entry")
          (compiler-load-test-seen-contains? seen "stdlib.option"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-unused-module-macro-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_unused_module_macro")
    (io.write-file
      "target/cl_lazy_unused_module_macro/entry.tl"
      "(module lazy.unused.module.macro.entry)
(import stdlib.option)
(define (main) : i64 42)")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_unused_module_macro/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 1)
          (compiler-load-test-seen-contains?
            seen
            "lazy.unused.module.macro.entry")
          (not (compiler-load-test-seen-contains? seen "stdlib.option")))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-aliased-module-macro-demand-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_aliased_module_macro")
    (compiler-load-test-mkdir "target/cl_lazy_aliased_module_macro/generic")
    (compiler-load-test-mkdir
      "target/cl_lazy_aliased_module_macro/generic/macro")
    (io.write-file
      "target/cl_lazy_aliased_module_macro/generic/macro/dep.tl"
      "(module generic.macro.dep)
(defmacro (make [T : type]) : Module (expr-unit))")
    (io.write-file
      "target/cl_lazy_aliased_module_macro/entry.tl"
      "(module lazy.aliased.module.macro.entry)
(import generic.macro.dep as api)
(import (make i64) as made)
(define (main) : i64 42)")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_aliased_module_macro/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (compiler-load-test-seen-contains?
            seen
            "lazy.aliased.module.macro.entry")
          (compiler-load-test-seen-contains? seen "generic.macro.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-qualified-module-macro-demand-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_qualified_module_macro")
    (compiler-load-test-mkdir "target/cl_lazy_qualified_module_macro/generic")
    (compiler-load-test-mkdir
      "target/cl_lazy_qualified_module_macro/generic/macro")
    (io.write-file
      "target/cl_lazy_qualified_module_macro/generic/macro/dep.tl"
      "(module generic.macro.dep)
(defmacro (make [T : type]) : Module (expr-unit))")
    (io.write-file
      "target/cl_lazy_qualified_module_macro/entry.tl"
      "(module lazy.qualified.module.macro.entry)
(import generic.macro.dep as api)
(import (generic.macro.dep.make i64) as made)
(define (main) : i64 42)")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_qualified_module_macro/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (compiler-load-test-seen-contains?
            seen
            "lazy.qualified.module.macro.entry")
          (compiler-load-test-seen-contains? seen "generic.macro.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-stdlib-vector-qualified-module-macro-demand-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_vector_module_macro")
    (io.write-file
      "target/cl_lazy_stdlib_vector_module_macro/entry.tl"
      "(module lazy.stdlib.vector.module.macro.entry)
(import stdlib.vector)
(import (stdlib.vector.vector i64) as vec)
(define (main) : i64 42)")
    (let
      [cfgs : sym_i64_env.SymI64Env (compiler-cfg-empty)]
      (match (compiler-load-file-with-paths-and-roots-cfg
        "target/cl_lazy_stdlib_vector_module_macro/entry.tl"
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        cfgs)
        [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
          (and
            (= (compiler-load-lazy-import-skip-count) 0)
            (compiler-load-test-seen-contains?
              seen
              "lazy.stdlib.vector.module.macro.entry")
            (compiler-load-test-seen-contains? seen "stdlib.vector"))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (package-lazy-unused-dotted-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_pkg_lazy_dotted")
    (compiler-load-test-mkdir "target/cl_pkg_lazy_dotted/nested")
    (io.write-file
      "target/cl_pkg_lazy_dotted/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_pkg_lazy_dotted/entry.tl"
      "(module pkg.lazy.dotted.entry)
(import nested.dep as dep)
(define (main) : i64 42)")
    (match (compiler-load-package-file-with-paths-and-roots
      "target/cl_pkg_lazy_dotted/entry.tl"
      (sym_i64_env.sym-i64-empty)
      (svec.new)
      "target/cl_pkg_lazy_dotted"
      (compiler-pkg-deps-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 1)
          (= (compiler-load-decl-list-count decls) 3)
          (compiler-load-decl-list-has-import-alias? decls "nested.dep" "dep")
          (compiler-load-test-seen-contains? seen "pkg.lazy.dotted.entry")
          (not (compiler-load-test-seen-contains? seen "nested.dep")))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (package-lazy-used-dotted-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_pkg_lazy_dotted_used")
    (compiler-load-test-mkdir "target/cl_pkg_lazy_dotted_used/nested")
    (io.write-file
      "target/cl_pkg_lazy_dotted_used/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_pkg_lazy_dotted_used/entry.tl"
      "(module pkg.lazy.dotted.used.entry)
(import nested.dep as dep)
(define (main) : i64 (dep.get))")
    (match (compiler-load-package-file-with-paths-and-roots
      "target/cl_pkg_lazy_dotted_used/entry.tl"
      (sym_i64_env.sym-i64-empty)
      (svec.new)
      "target/cl_pkg_lazy_dotted_used"
      (compiler-pkg-deps-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (compiler-load-test-seen-contains? seen "pkg.lazy.dotted.used.entry")
          (compiler-load-test-seen-contains? seen "nested.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-local-alias-does-not-demand-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_local_alias")
    (compiler-load-test-mkdir "target/cl_lazy_local_alias/generic")
    (compiler-load-test-mkdir "target/cl_lazy_local_alias/generic/local")
    (io.write-file
      "target/cl_lazy_local_alias/generic/local/dep.tl"
      "(module generic.local.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_lazy_local_alias/entry.tl"
      "(module generic.local.entry)
(import generic.local.dep as dep)
(define (main) : i64
  (let
    [dep : i64 42]
    dep))")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_local_alias/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 1)
          (compiler-load-test-seen-contains? seen "generic.local.entry")
          (not (compiler-load-test-seen-contains? seen "generic.local.dep")))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-generic-qualified-surface-demand-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_generic_surface")
    (compiler-load-test-mkdir "target/cl_lazy_generic_surface/generic")
    (compiler-load-test-mkdir "target/cl_lazy_generic_surface/generic/surface")
    (io.write-file
      "target/cl_lazy_generic_surface/generic/surface/dep.tl"
      "(module generic.surface.dep)
(defenum Choice (Empty) (Full i64))
(define (get) : i64 7)
(defmacro (number) : Expr 5)")
    (io.write-file
      "target/cl_lazy_generic_surface/entry.tl"
      "(module generic.surface.entry)
(import generic.surface.dep as dep)
(define (score [value : dep.Choice]) : i64
  (match value
    [(dep.Choice.Empty) 0]
    [(dep.Choice.Full n) (+ n (dep.get))]))
(define (main) : i64 (dep.number))")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_generic_surface/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (compiler-load-test-seen-contains? seen "generic.surface.entry")
          (compiler-load-test-seen-contains? seen "generic.surface.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-generic-direct-surface-demand-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_generic_direct")
    (compiler-load-test-mkdir "target/cl_lazy_generic_direct/generic")
    (compiler-load-test-mkdir "target/cl_lazy_generic_direct/generic/direct")
    (io.write-file
      "target/cl_lazy_generic_direct/generic/direct/dep.tl"
      "(module generic.direct.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_lazy_generic_direct/entry.tl"
      "(module generic.direct.entry)
(import generic.direct.dep as dep)
(define (main) : i64 (get))")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_generic_direct/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (compiler-load-test-seen-contains? seen "generic.direct.entry")
          (compiler-load-test-seen-contains? seen "generic.direct.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-cfg-selected-surface-demand-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_cfg_surface")
    (compiler-load-test-mkdir "target/cl_lazy_cfg_surface/generic")
    (compiler-load-test-mkdir "target/cl_lazy_cfg_surface/generic/cfg")
    (io.write-file
      "target/cl_lazy_cfg_surface/generic/cfg/dep.tl"
      "(module generic.cfg.dep)
(cfg feature (define (get) : i64 7))")
    (io.write-file
      "target/cl_lazy_cfg_surface/entry.tl"
      "(module generic.cfg.entry)
(import generic.cfg.dep as dep)
(cfg feature (define (main) : i64 (dep.get)))")
    (let
      [cfgs : sym_i64_env.SymI64Env
        (compiler-cfg-enable (compiler-cfg-empty) "feature")]
      (match (compiler-load-file-with-paths-and-roots-cfg
        "target/cl_lazy_cfg_surface/entry.tl"
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        cfgs)
        [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
          (and
            (= (compiler-load-lazy-import-skip-count) 0)
            (compiler-load-test-seen-contains? seen "generic.cfg.entry")
            (compiler-load-test-seen-contains? seen "generic.cfg.dep"))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (structural-member-demand-source [source : String] [alias : i64]) : CompilerLoadStructuralMemberDemand
  (match (compiler-load-parse-source-diagnostic-escaping
    "src/structural_member_demand.tl"
    source
    (compiler-cfg-empty))
    [(ResultAstProgramDiagnostic.Ok (AstProgram.Program decls))
      (compiler-load-structural-member-demand (box-get decls) alias)]
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
    [demand : CompilerLoadStructuralMemberDemand
      (structural-member-demand-source
        "(module demand.one)
(define (main) : i64 (subject.value))"
        cbi.compiler-builtin-id-fix-subject)]
    (and
      (= (compiler-load-structural-member-demand-count demand) 1)
      (compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-value))))

(define (structural-member-demand-union-ok?) : bool
  (let
    [demand : CompilerLoadStructuralMemberDemand
      (structural-member-demand-source
        "(module demand.union)
(define (main) : i64
  (begin
    (subject.left)
    (subject/right)
    (subject.left)))"
        cbi.compiler-builtin-id-fix-subject)]
    (and
      (= (compiler-load-structural-member-demand-count demand) 2)
      (compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-left)
      (compiler-load-structural-member-demand-contains?
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
    [demand : CompilerLoadStructuralMemberDemand
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
      (= (compiler-load-structural-member-demand-count demand) 1)
      (compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-same))))

(define (structural-member-demand-unknown-ok?) : bool
  (match (compiler-load-parse-source-diagnostic-escaping
    "src/structural_member_demand_unknown.tl"
    "(module demand.unknown)
(defstruct Aggregate (value i64))"
    (compiler-cfg-empty))
    [(ResultAstProgramDiagnostic.Ok (AstProgram.Program decls))
      (match (compiler-load-structural-member-demand
        (box-get decls)
        cbi.compiler-builtin-id-fix-subject)
        [(CompilerLoadStructuralFullDemand) true]
        [_ false])]
    [(ResultAstProgramDiagnostic.Err _) false]))

(define (lazy-preload-observer-state-isolation-ok?) : bool
  (match (compiler-load-parse-source-diagnostic-escaping
    "src/lazy_preload_observer_state_isolation.tl"
    "(module demand.isolation)
(define (main) : i64 (subject.same))"
    (compiler-cfg-empty))
    [(ResultAstProgramDiagnostic.Ok (AstProgram.Program decls))
      (let
        [previous-state : CompilerLoadSessionState
          compiler-load-active-session-state]
        [state-a : CompilerLoadSessionState (compiler-load-session-state-new)]
        [state-b : CompilerLoadSessionState (compiler-load-session-state-new)]
        [alias : i64 cbi.compiler-builtin-id-fix-subject]
        [member : i64 cbi.compiler-builtin-id-fix-same]
        [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
        [_select-b : unit (compiler-load-session-state-use! state-b)]
        [_begin-a : unit
          (compiler-load-session-state-lazy-qualified-observer-begin-pair!
            state-a
            alias
            cbi.compiler-builtin-id-fix-empty)]
        [_begin-b : unit
          (compiler-load-session-state-lazy-qualified-observer-begin-pair!
            state-b
            alias
            cbi.compiler-builtin-id-fix-empty)]
        [demand : CompilerLoadLazyAliasDemand
          (compiler-load-session-state-lazy-import-preload-demand
            state-a
            true
            (AstMaybeImportAlias.Some alias)
            (box-get decls)
            pools)]
        [observed-a : CompilerLoadLazyQualifiedObserverResult
          (compiler-load-session-state-lazy-qualified-observer-end-pair!
            state-a)]
        [b-still-active : bool
          (compiler-load-session-state-lazy-qualified-observer-active? state-b)]
        [observed-b : CompilerLoadLazyQualifiedObserverResult
          (compiler-load-session-state-lazy-qualified-observer-end-pair!
            state-b)]
        [ok : bool
          (and
            (struct-get demand qualified)
            (not (struct-get demand unknown))
            (sym_i64_env.sym-i64-contains-id (struct-get demand members) member)
            (sym_i64_env.sym-i64-contains-id
              (struct-get observed-a primary-members)
              member)
            b-still-active
            (not
              (sym_i64_env.sym-i64-contains-id
                (struct-get observed-b primary-members)
                member)))]
        (begin
          (compiler-load-session-state-use! previous-state)
          ok))]
    [(ResultAstProgramDiagnostic.Err _) false]))

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
      (compiler-load-lazy-qualified-observer-dense-stack-ok?)
      (return (io.panic "lazy observer dense stack smoke mismatch")))
    42))