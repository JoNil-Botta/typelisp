;; build_cli_core_tests.tl - White-box tests for package builds: paths and
;; artifact status, direct objects, preflight routes, the package graph and
;; scheduler, TLCI callables, rollback and commit, and worker arguments.
(import compiler_owned_view as owned_view)
(cfg test (import stdlib.fs))
(cfg test (import stdlib.byte_buf))
(import stdlib.io)
(import stdlib.process)
(import stdlib.string)
(cfg test (import stdlib.str_cat_runtime as str_cat))
(import stdlib.hashmap)
(import stdlib.vector)
(cfg test (import compiler_builtin_ids as cbi))
(import (hashmap.hashmap String i64) as build_string_i64_map)
(import (vector.vector String) as cli_svec)
(import build_run_core)
(import build_run_core_tests as build_run_tests)
(import compiler_backend as backend)
(import compiler_ast_types as ast)
(import compiler_load as load)
(cfg test (import compiler_intern as ci))
(cfg test (import compiler_ir_types as ir))
(cfg test (import compiler_lower as lower))
(cfg test (import compiler_object as cobj))
(cfg test (import compiler_object_elf))
(import package_lock_core)
(import (vector.vector package_lock_core.PackageLockEntry core) as package_lock_entry_vec)
(cfg test (import compiler_parse_core))
(cfg test (import tlci_core as tlci))
(cfg test (import compiler_tlci_native_producer))
(import build_cli_core as build)
(cfg test (import compiler_object_elf))

(test
  build-package-profile-opt-level-smoke
  (unless
    (and
      (= (build.build-profile-default-opt-level (Release)) 2)
      (= (build.build-profile-default-opt-level (Dev)) 0)
      (= (build.build-package-default-opt-level) 2))
    (io.panic "build package profile opt-level smoke failed")))

(test
  build-package-path-layout-smoke
  (unless
    (and
      (string.eq
        (build.build-package-output-dir-profile "root/app" "pkg" (Release))
        "root/app/target/release")
      (string.eq
        (build.build-package-asm-path-profile "root/app" "pkg" (Dev))
        "root/app/target/dev/pkg.s")
      (string.eq
        (build.build-package-bin-path-profile
          "root/app"
          "pkg"
          (Release)
          (Windows))
        "root/app/target/release/pkg.exe")
      (string.eq
        (build.build-package-lib-path-profile
          "root/app"
          "pkg"
          (Release)
          (Linux))
        "root/app/target/release/libpkg.a")
      (string.eq
        (build.build-package-tlci-path-profile "root/app" "pkg" (Dev))
        "root/app/target/dev/pkg.tlci")
      (string.eq
        (build.build-package-host-tlci-artifact-path
          (build.build-package-artifact-paths
            "root/app"
            "pkg"
            (CompilerPkgKindBin)
            (Dev)
            (Windows)))
        "root/app/target/dev/pkg.tlci"))
    (io.panic "build package path layout smoke failed")))

(cfg
  test
  (define (build-package-artifact-status-smoke-ok?) : bool
    (and
      (not (build.build-package-artifact-state-dirty? (Clean)))
      (build.build-package-artifact-state-dirty? (Missing))
      (build.build-package-artifact-state-dirty? (Stale "metadata changed"))
      (string.eq
        (build.build-package-artifact-state-render (Stale "metadata changed"))
        "metadata changed"))))

(cfg
  test
  (test
    build-package-artifact-status-smoke
    (unless
      (build-package-artifact-status-smoke-ok?)
      (io.panic "build package artifact status smoke failed"))))

(cfg
  test
  (test
    build-package-linux-direct-object-render-parity
    (match (backend.compiler-backend-emit-source-object-image-for-target
      "(define (main) : i64 42)"
      (Linux))
      [(Err _) (io.panic "Linux object fixture failed")]
      [(Ok image)
        (unless
          (and
            (match (build.build-package-render-linux-direct-object
              (CompilerPkgKindBin)
              (owned_view.compiler-owned-shared-view image))
              [(Ok typed)
                (match (compiler_object_elf.compiler-object-elf-render image)
                  [(Ok serialized) (string.eq typed serialized)]
                  [_ false])]
              [_ false])
            (match (build.build-package-render-linux-direct-object
              (CompilerPkgKindLib)
              (owned_view.compiler-owned-shared-view image))
              [(Ok typed)
                (match (compiler_object_elf.compiler-object-elf-render image)
                  [(Ok serialized) (string.eq typed serialized)]
                  [_ false])]
              [_ false]))
          (io.panic "Linux package direct-object bytes changed"))])))

(cfg
  test
  (test
    build-package-linux-direct-object-missing-entry
    (match (build.build-package-render-linux-direct-object
      (CompilerPkgKindBin)
      (compiler_object_elf.compiler-object-elf-smoke-image))
      [(Fallback (MissingEntrySymbol)) unit]
      [_ (io.panic "Linux package missing-entry reason changed")])))

(cfg
  test
  (test
    build-package-linux-direct-object-source-fallback-parity
    (match (build_run_core.source-tool-render-linkable-linux-elf-object
      (compiler_object_elf.compiler-object-elf-smoke-image))
      [(Err message)
        (unless
          (string.eq
            message
            "linux direct object unavailable: missing-entry-symbol")
          (io.panic "Linux source object fallback lost its typed reason"))]
      [_ (io.panic "Linux source object accepted an image without entry")])))

(cfg
  test
  (define (build-package-linux-direct-object-with-relocation
    [reloc : cobj.CompilerObjectRelocation]) : build_run_core.ResultSourceToolLinuxDirectObject
    (let
      [fixture : cobj.CompilerObjectImage
        (compiler_object_elf.compiler-object-elf-smoke-image)]
      [relocations : cobj.CompilerObjectRelocationList
        (cobj.compiler-object-relocation-builder-finish
          (cobj.compiler-object-relocation-builder-push
            (cobj.compiler-object-relocation-builder-with-capacity 1)
            reloc))]
      (build.build-package-render-linux-direct-object
        (CompilerPkgKindLib)
        (cobj.CompilerObjectImage fixture.sections fixture.symbols relocations)))))

(cfg
  test
  (define (build-package-linux-direct-object-with-pdata) : build_run_core.ResultSourceToolLinuxDirectObject
    (let
      [fixture : cobj.CompilerObjectImage
        (compiler_object_elf.compiler-object-elf-smoke-image)]
      [sections : cobj.CompilerObjectSectionList
        (cobj.compiler-object-section-builder-finish
          (cobj.compiler-object-section-builder-push
            (cobj.compiler-object-section-builder-with-capacity 1)
            (Section
              (Pdata)
              (cobj.compiler-object-data-record-builder-finish
                (cobj.compiler-object-data-record-builder-with-capacity 1))
              (cobj.compiler-object-instr-builder-finish
                (cobj.compiler-object-instr-builder-with-capacity 1)))))]
      (build.build-package-render-linux-direct-object
        (CompilerPkgKindLib)
        (cobj.CompilerObjectImage sections fixture.symbols fixture.relocations)))))

(cfg
  test
  (test
    build-package-linux-direct-object-typed-serializer-fallbacks
    (unless
      (and
        (match (build-package-linux-direct-object-with-pdata)
          [(Fallback (ObjectEncoding)) true]
          [_ false])
        (match (build-package-linux-direct-object-with-relocation
          (Relocation (Text) "_tl_empty" (Abs64) "_tl_empty"))
          [(Fallback (ObjectRelocation)) true]
          [_ false])
        (match (build-package-linux-direct-object-with-relocation
          (Relocation (Text) "_tl_no_site" (Call) "_tl_empty"))
          [(Fallback (ObjectFixup)) true]
          [_ false]))
      (io.panic "Linux package serializer reasons changed"))))

(define (build-package-direct-object-within-budget?
  [paths : (& paths ast.AstDeclPathList)]) : bool
  (<=
    (build.build-package-direct-object-owned-path-count paths)
    (build.build-package-direct-object-owned-path-budget)))

(cfg
  test
  (define (build-package-direct-object-test-paths
    [count : i64]
    [path : String]
    [out : ast.AstDeclPathList]) : ast.AstDeclPathList
    (if (<= count 0)
      out
      (build-package-direct-object-test-paths
        (- count 1)
        (string.copy (& path))
        (ast.ast-decl-path-list-prepend-builder-with-owner-id
          path
          cbi.compiler-builtin-id-fix-empty
          out)))))

(cfg
  test
  (define (build-package-direct-object-size-smoke-ok?) : bool
    (let
      [budget : i64 (build.build-package-direct-object-owned-path-budget)]
      [ordinary-decl : ast.AstDecl
        (ast.ast-decl-def-fn-id
          (ci.intern "direct-object-ordinary")
          (ast.ast-param-list-new)
          (I64)
          cbi.compiler-builtin-id-fix-empty)]
      [spmd-decl : ast.AstDecl
        (ast.ast-decl-def-fn-metadata-id
          (ci.intern "direct-object-spmd")
          (ast.ast-param-list-new)
          (I64)
          cbi.compiler-builtin-id-fix-empty
          (ast.ast-fn-metadata-full
            No
            (Callable (ast.ast-spmd-specialization-list-new))))]
      [within : ast.AstDeclPathList
        (build-package-direct-object-test-paths
          budget
          "pkg.tl"
          (ast.ast-decl-path-list-new))]
      [over : ast.AstDeclPathList
        (build-package-direct-object-test-paths
          (+ budget 1)
          "pkg.tl"
          (ast.ast-decl-path-list-new))]
      [mixed : ast.AstDeclPathList
        (ast.ast-decl-root-path-cons
          ""
          (ast.ast-decl-root-path-cons "pkg.tl" (ast.ast-decl-path-list-new)))]
      (and
        (not (build.build-package-decl-has-spmd-callable? ordinary-decl))
        (build.build-package-decl-has-spmd-callable?
          (owned_view.compiler-owned-shared-view spmd-decl))
        (build.build-package-decls-have-spmd-callable?
          (ast.ast-decl-cons spmd-decl (ast.ast-decl-list-new)))
        (= (build.build-package-direct-object-owned-path-count (& mixed)) 1)
        (build-package-direct-object-within-budget? (& within))
        (not (build-package-direct-object-within-budget? (& over)))))))

(cfg
  test
  (test
    build-package-direct-object-size-smoke
    (unless
      (build-package-direct-object-size-smoke-ok?)
      (io.panic "build package direct object size smoke failed"))))

(cfg
  test
  (define (build-package-preflight-category-is?
    [result : build.BuildPackageDirectObjectPreflight]
    [expected : String]) : bool
    (match result
      [(Eligible) (string.eq expected "")]
      [(Fallback reason)
        (string.eq
          (backend.compiler-direct-object-fallback-category reason)
          expected)])))

(cfg
  test
  (test
    build-package-direct-object-typed-route
    (let
      [empty-decls : ast.AstDeclList (ast.ast-decl-list-new)]
      [empty-paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
      [one-path : ast.AstDeclPathList
        (build-package-direct-object-test-paths
          1
          "pkg.tl"
          (ast.ast-decl-path-list-new))]
      [spmd-decl : ast.AstDecl
        (ast.ast-decl-def-fn-metadata-id
          (ci.intern "typed-route-spmd")
          (ast.ast-param-list-new)
          (I64)
          cbi.compiler-builtin-id-fix-empty
          (ast.ast-fn-metadata-full
            No
            (Callable (ast.ast-spmd-specialization-list-new))))]
      [spmd-decls : ast.AstDeclList
        (ast.ast-decl-cons spmd-decl (ast.ast-decl-list-new))]
      (unless
        (and
          (build-package-preflight-category-is?
            (build.build-package-direct-object-preflight
              (CompilerPkgKindLib)
              (Windows)
              (Scalar)
              false
              512
              false
              (owned_view.compiler-owned-shared-view empty-decls)
              (& empty-paths))
            "artifact-kind-unavailable")
          (build-package-preflight-category-is?
            (build.build-package-direct-object-preflight
              (CompilerPkgKindBin)
              (Windows)
              (Scalar)
              true
              512
              false
              (owned_view.compiler-owned-shared-view empty-decls)
              (& empty-paths))
            "debug-metadata")
          (build-package-preflight-category-is?
            (build.build-package-direct-object-preflight
              (CompilerPkgKindBin)
              (Windows)
              (Avx2)
              false
              512
              false
              (owned_view.compiler-owned-shared-view empty-decls)
              (& empty-paths))
            "backend-mode")
          (build-package-preflight-category-is?
            (build.build-package-direct-object-preflight
              (CompilerPkgKindBin)
              (Windows)
              (Scalar)
              false
              512
              false
              spmd-decls
              (& empty-paths))
            "private-spmd-abi")
          (build-package-preflight-category-is?
            (build.build-package-direct-object-preflight
              (CompilerPkgKindBin)
              (Windows)
              (Scalar)
              false
              0
              false
              (owned_view.compiler-owned-shared-view empty-decls)
              (& one-path))
            "resource-budget")
          (match (build.build-package-direct-object-preflight
            (CompilerPkgKindBin)
            (Windows)
            (Scalar)
            false
            1
            false
            empty-decls
            (& one-path))
            [(Eligible) true]
            [_ false]))
        (io.panic "typed package direct-object route failed")))))

(cfg
  test
  (define (build-package-typed-route-table-from [index : i64]) : bool
    (if (>= index 192)
      true
      (let
        [target-index : i64 (% index 2)]
        [kind-index : i64 (% (/ index 2) 2)]
        [debug-index : i64 (% (/ index 4) 2)]
        [mode-index : i64 (% (/ index 8) 3)]
        [spmd-index : i64 (% (/ index 24) 2)]
        [size-index : i64 (% (/ index 48) 2)]
        [override-index : i64 (% (/ index 96) 2)]
        [target : backend.CompilerBackendTarget
          (if (= target-index 0)
            (Linux)
            (Windows))]
        [kind : load.CompilerPkgKind
          (if (= kind-index 0)
            (CompilerPkgKindBin)
            (CompilerPkgKindLib))]
        [mode : backend.CompilerBackendMode
          (cond
            [(= mode-index 0) (Scalar)]
            [(= mode-index 1) (Avx2)]
            [else (Avx512)])]
        [decls : ast.AstDeclList
          (if (= spmd-index 0)
            (ast.ast-decl-list-new)
            (ast.ast-decl-cons
              (ast.ast-decl-def-fn-metadata-id
                (ci.intern "typed-route-table-spmd")
                (ast.ast-param-list-new)
                (I64)
                cbi.compiler-builtin-id-fix-empty
                (ast.ast-fn-metadata-full
                  No
                  (Callable (ast.ast-spmd-specialization-list-new))))
              (ast.ast-decl-list-new)))]
        [paths : ast.AstDeclPathList
          (build-package-direct-object-test-paths
            size-index
            "pkg.tl"
            (ast.ast-decl-path-list-new))]
        [expected : String
          (cond
            [(and (= target-index 1) (= kind-index 1))
              "artifact-kind-unavailable"]
            [(= debug-index 1) "debug-metadata"]
            [(> mode-index 0) "backend-mode"]
            [(= spmd-index 1) "private-spmd-abi"]
            [(and (= size-index 1) (or (= target-index 1) (= override-index 0)))
              "resource-budget"]
            [else ""])]
        (and
          (build-package-preflight-category-is?
            (build.build-package-direct-object-preflight
              kind
              target
              mode
              (= debug-index 1)
              0
              (= override-index 1)
              decls
              (& paths))
            expected)
          (build-package-typed-route-table-from (+ index 1)))))))

(cfg
  test
  (test
    build-package-direct-object-route-table
    (unless
      (build-package-typed-route-table-from 0)
      (io.panic "typed package direct-object route table failed"))))

(define (build-package-graph-node-tlci-path
  [node : build.BuildPackageGraphNode]
  [profile : build.BuildProfile]) : String
  (let
    [manifest-path : String node.manifest-path]
    [manifest : load.CompilerPkgManifest node.manifest]
    [manifest-dir : String (load.compiler-load-dirname manifest-path)]
    (build.build-package-tlci-path-profile manifest-dir manifest.name profile)))

(define (build-package-graph-tlci-paths
  [nodes : build.BuildPackageGraphNodeVec]
  [profile : build.BuildProfile]) : process.ProcessStringList
  (let
    [index : i64 0]
    [count : i64 (build.build-package-graph-node-vec-len nodes)]
    [paths : process.ProcessStringList (process.args-empty)]
    (while (< index count)
      (set!
        paths
        (process.args-append
          paths
          (process.args-single
            (build-package-graph-node-tlci-path
              (build.build-package-graph-node-vec-at nodes index)
              profile))))
      (set! index (+ index 1)))
    paths))

(define (build-package-graph-test-manifest [name : String]) : load.CompilerPkgManifest
  (load.CompilerPkgManifest
    name
    "0.1.0"
    (CompilerPkgKindLib)
    "src/lib.tl"
    (load.compiler-pkg-deps-empty)
    (load.compiler-pkg-link-empty)))

(define (build-package-graph-test-manifest-with-deps
  [name : String]
  [deps : load.CompilerPkgDepList]) : load.CompilerPkgManifest
  (load.CompilerPkgManifest
    name
    "0.1.0"
    (CompilerPkgKindLib)
    "src/lib.tl"
    (load.compiler-pkg-deps-from-list deps)
    (load.compiler-pkg-link-empty)))

(define (build-package-graph-test-node [manifest-path : String] [name : String]) : build.BuildPackageGraphNode
  (build.BuildPackageGraphNode
    manifest-path
    (build-package-graph-test-manifest name)
    (Local)))

(define (build-package-graph-test-link-arg-target
  [node : build.BuildPackageGraphNode]
  [target : backend.CompilerBackendTarget]) : process.ProcessStringList
  (process.args-single
    (build.build-package-graph-node-artifact-path node (Release) target)))

(define (build-package-graph-test-link-arg
  [node : (& node build.BuildPackageGraphNode)]) : process.ProcessStringList
  (let
    [node : build.BuildPackageGraphNode
      (owned_view.compiler-owned-reference-shared-view node)]
    (build-package-graph-test-link-arg-target node (Linux))))

;; The dependency archives of `nodes`' link inputs for `target`.
(define (build-package-graph-test-archives
  [nodes : build.BuildPackageGraphNodeVec]
  [target : backend.CompilerBackendTarget]) : process.ProcessStringList
  (match (build.build-package-graph-link-inputs nodes (Release) target)
    [(Ok inputs) (build_run_core.source-tool-link-inputs-archives inputs)]
    [(Err _) (process.args-single "error")]))

(define (build-package-graph-test-tlci-arg
  [node : (& node build.BuildPackageGraphNode)]) : process.ProcessStringList
  (let
    [node : build.BuildPackageGraphNode
      (owned_view.compiler-owned-reference-shared-view node)]
    (process.args-single (build-package-graph-node-tlci-path node (Release)))))

(cfg
  test
  (define (build-package-graph-artifact-paths-smoke-ok?) : bool
    (let
      [bin-manifest : load.CompilerPkgManifest
        (load.CompilerPkgManifest
          "app"
          "0.1.0"
          (CompilerPkgKindBin)
          "src/main.tl"
          (load.compiler-pkg-deps-empty)
          (load.compiler-pkg-link-empty))]
      [bin-node : build.BuildPackageGraphNode
        (build.BuildPackageGraphNode
          "root/app/typelisp.pkg"
          bin-manifest
          (Local))]
      [dep-node : build.BuildPackageGraphNode
        (build-package-graph-test-node "root/dep/typelisp.pkg" "dep")]
      [bin-artifacts : build.BuildPackageArtifactPaths
        (build.build-package-graph-node-artifact-paths bin-node (Dev) (Windows))]
      [dep-artifacts : build.BuildPackageArtifactPaths
        (build.build-package-graph-node-artifact-paths
          dep-node
          (Release)
          (Linux))]
      (and
        (string.eq
          (build.build-package-runtime-artifact-path
            (owned_view.compiler-owned-shared-view bin-artifacts))
          "root/app/target/dev/app.exe")
        (string.eq
          (build.build-package-host-tlci-artifact-path bin-artifacts)
          "root/app/target/dev/app.tlci")
        (string.eq
          (build.build-package-runtime-artifact-path
            (owned_view.compiler-owned-shared-view dep-artifacts))
          "root/dep/target/release/libdep.a")
        (string.eq
          (build.build-package-host-tlci-artifact-path dep-artifacts)
          "root/dep/target/release/dep.tlci")))))

(test
  build-package-graph-vector-smoke
  (unless
    (and
      (let
        [first : build.BuildPackageGraphNode
          (build-package-graph-test-node "root/first/typelisp.pkg" "first")]
        [second : build.BuildPackageGraphNode
          (build-package-graph-test-node "root/second/typelisp.pkg" "second")]
        [third : build.BuildPackageGraphNode
          (build-package-graph-test-node "root/third/typelisp.pkg" "third")]
        [nodes : build.BuildPackageGraphNodeVec
          (build.build-package-graph-node-vec-push
            (build.build-package-graph-node-vec-push
              (build.build-package-graph-node-vec-push
                (build.build-package-graph-node-vec-with-capacity 1)
                (owned_view.compiler-owned-shared-view first))
              (owned_view.compiler-owned-shared-view second))
            (owned_view.compiler-owned-shared-view third))]
        [libs : process.ProcessStringList
          (build-package-graph-test-archives
            (owned_view.compiler-owned-shared-view nodes)
            (Linux))]
        [windows-libs : process.ProcessStringList
          (build-package-graph-test-archives
            (owned_view.compiler-owned-shared-view nodes)
            (Windows))]
        [tlcis : process.ProcessStringList
          (build-package-graph-tlci-paths
            (owned_view.compiler-owned-shared-view nodes)
            (Release))]
        [catalog-deps : load.CompilerPkgDepList
          (build.build-package-graph-catalog-deps
            (owned_view.compiler-owned-shared-view nodes)
            "root"
            (load.compiler-pkg-dep-list-empty))]
        [direct-catalog-deps : load.CompilerPkgDepList
          (load.compiler-pkg-dep-list-push
            (load.compiler-pkg-dep-list-push
              (load.compiler-pkg-dep-list-empty)
              (load.CompilerPkgDep "first-a" "first"))
            (load.CompilerPkgDep "first-b" "first/."))]
        [merged-catalog-deps : load.CompilerPkgDepList
          (build.build-package-graph-catalog-deps
            (owned_view.compiler-owned-shared-view nodes)
            "root"
            direct-catalog-deps)]
        [expected : process.ProcessStringList
          (process.args-append
            (process.args-append
              (build-package-graph-test-link-arg third)
              (build-package-graph-test-link-arg second))
            (build-package-graph-test-link-arg first))]
        [expected-tlcis : process.ProcessStringList
          (process.args-append
            (process.args-append
              (build-package-graph-test-tlci-arg first)
              (build-package-graph-test-tlci-arg second))
            (build-package-graph-test-tlci-arg third))]
        [expected-windows : process.ProcessStringList
          (process.args-append
            (process.args-append
              (build-package-graph-test-link-arg-target third (Windows))
              (build-package-graph-test-link-arg-target second (Windows)))
            (build-package-graph-test-link-arg-target first (Windows)))]
        (and
          (= (build.build-package-graph-node-vec-len nodes) 3)
          (string.eq
            (__tl-project-field
              (build.build-package-graph-node-vec-at nodes 0)
              manifest-path)
            "root/first/typelisp.pkg")
          (build_run_tests.source-tool-string-list-eq? libs expected)
          (build_run_tests.source-tool-string-list-eq?
            windows-libs
            expected-windows)
          (build_run_tests.source-tool-string-list-eq? tlcis expected-tlcis)
          (= (load.compiler-pkg-dep-list-count catalog-deps) 3)
          (string.eq
            (load.compiler-pkg-dep-list-at catalog-deps 0).alias
            "first")
          (load.compiler-load-absolute-path?
            (load.compiler-pkg-dep-list-at catalog-deps 0).path)
          (= (load.compiler-pkg-dep-list-count merged-catalog-deps) 4)
          (string.eq
            (load.compiler-pkg-dep-list-at merged-catalog-deps 0).alias
            "first-a")
          (string.eq
            (load.compiler-pkg-dep-list-at merged-catalog-deps 1).alias
            "first-b")
          (string.eq
            (load.compiler-pkg-dep-list-at merged-catalog-deps 2).alias
            "second")))
      (let
        [dep : load.CompilerPkgDep (load.CompilerPkgDep "dep" "../dep")]
        [deps : load.CompilerPkgDepList
          (load.compiler-pkg-dep-list-push
            (load.compiler-pkg-dep-list-empty)
            dep)]
        [node : build.BuildPackageGraphNode
          (build.BuildPackageGraphNode
            "root/app/typelisp.pkg"
            (build-package-graph-test-manifest-with-deps "app" deps)
            (Local))]
        [nodes : build.BuildPackageGraphNodeVec
          (build.build-package-graph-node-vec-push
            (build.build-package-graph-node-vec-new)
            node)]
        (match (build.build-package-schedule-pass
          nodes
          (build_string_i64_map.with-capacity 4)
          (build_string_i64_map.with-capacity 4)
          (Linux)
          0
          (Release)
          (Scalar)
          (Default)
          (cli_svec.new))
          [(Err _) false]
          [(Ok pass)
            (and
              (build.build-package-graph-worker-list-empty? (& pass.workers))
              (not
                (build.build-package-node-scheduled?
                  pass.scheduled
                  "root/app/typelisp.pkg")))]))
      (let
        [dep : load.CompilerPkgDep (load.CompilerPkgDep "runtime" "../runtime")]
        [deps : load.CompilerPkgDepList
          (load.compiler-pkg-dep-list-push
            (load.compiler-pkg-dep-list-empty)
            dep)]
        [resolve-manifest : load.CompilerPkgManifest
          (build-package-graph-test-manifest-with-deps "layer" (clone deps))]
        [graph-node : build.BuildPackageGraphNode
          (build.BuildPackageGraphNode
            "acquired/layer/typelisp.pkg"
            (build-package-graph-test-manifest-with-deps "layer" deps)
            (Local))]
        [state : build.BuildPackageGraphState
          (build.BuildPackageGraphState
            (build_string_i64_map.with-capacity 4)
            (build.build-package-graph-node-vec-new))]
        (and
          (match (build.build-package-resolve-manifest-deps
            "unreadable/typelisp.pkg"
            resolve-manifest
            (Locked))
            [(Err message)
              (string.eq
                message
                "build: library package `layer` cannot declare normal dependency `runtime`; declare `runtime` directly in the consuming application, remove or combine the library dependency, or use `link` for native libraries")]
            [(Ok _) false])
          (match (build.build-package-graph-add-node graph-node state)
            [(Err message)
              (string.eq
                message
                "build: acquired manifest at acquired/layer/typelisp.pkg: library package `layer` cannot declare normal dependency `runtime`; declare `runtime` directly in the consuming application, remove or combine the library dependency, or use `link` for native libraries")]
            [(Ok _) false]))))
    (io.panic "build package graph vector smoke failed")))

(cfg
  test
  (test
    build-package-graph-artifact-paths-smoke
    (unless
      (build-package-graph-artifact-paths-smoke-ok?)
      (io.panic "build package graph artifact paths smoke failed"))))

(cfg
  test
  (define (build-package-tlci-callable-smoke-ok?) : bool
    (let
      [first-classes : ast.AstSpmdParamClassList
        (ast.ast-spmd-param-class-list-new)]
      [second-classes : ast.AstSpmdParamClassList
        (ast.ast-spmd-param-class-list-new)]
      [specializations : ast.AstSpmdSpecializationList
        (ast.ast-spmd-specialization-list-new)]
      [helper-id : i64 (ci.intern-generated-canonical-name "helper")]
      [x-id : i64 (ci.intern-generated-canonical-name "x")]
      [scale-id : i64 (ci.intern-generated-canonical-name "scale")]
      (ast.ast-spmd-param-class-list-push (&mut first-classes) Varying)
      (ast.ast-spmd-param-class-list-push (&mut first-classes) Uniform)
      (ast.ast-spmd-param-class-list-push (&mut second-classes) Uniform)
      (ast.ast-spmd-param-class-list-push (&mut second-classes) Varying)
      (ast.ast-spmd-specialization-list-push
        (&mut specializations)
        (ast.AstSpmdSpecialization 8 (box first-classes) Varying 0))
      (ast.ast-spmd-specialization-list-push
        (&mut specializations)
        (ast.AstSpmdSpecialization 8 (box second-classes) Varying 1))
      (let
        [callable : tlci.TlciSpmdCallable
          (build.build-package-tlci-callable
            (ast.ast-node-pool-reader-type-segment-bases)
            "pkg"
            "pkg"
            helper-id
            (ast.ast-param-cons
              (ast.ast-param-id x-id (I64) false)
              (ast.ast-param-cons
                (ast.ast-param-id scale-id (I64) false)
                (ast.ast-param-list-new)))
            (I64)
            specializations
            (Scalar))]
        [ordinary-metadata : tlci.TlciMetadata
          (build.build-package-tlci-metadata
            (build-package-graph-test-manifest "pkg")
            (tlci.tlci-spmd-callables-empty))]
        [emitted : tlci.TlciSpmdSpecializations callable.specializations]
        (and
          (string.eq ordinary-metadata.version "v1")
          (= (tlci.tlci-spmd-callables-len ordinary-metadata.spmd-callables) 0)
          (string.eq callable.name "pkg/helper")
          (string.eq callable.signature "(-> i64 i64 i64)")
          (= (tlci.tlci-spmd-specializations-len emitted) 2)
          (let
            [item : tlci.TlciSpmdSpecialization
              (tlci.tlci-spmd-specializations-ref emitted 0)]
            [next : tlci.TlciSpmdSpecialization
              (tlci.tlci-spmd-specializations-ref emitted 1)]
            (and
              (string.eq item.abi "spmd-call-v1")
              (string.eq item.backend "scalar")
              (= item.lanes 1)
              (string.eq item.args "uv")
              (string.eq item.result "v")
              (= item.index-param 1)
              (string.eq
                item.symbol
                (backend.compiler-backend-user-symbol-uncached
                  (ci.intern-str
                    (ci.intern-generated-canonical-name
                      (lower.lower-spmd-package-symbol
                        (ast.ast-node-pool-reader-type-segment-bases)
                        "pkg"
                        "pkg/helper"
                        "(-> i64 i64 i64)"
                        (I64)
                        Scalar
                        1
                        "uv"
                        "v"
                        1)))))
              (string.eq next.args "vu")
              (= next.index-param 0))))))))

(cfg
  test
  (define (build-package-tlci-scalar-collapse-smoke-ok?) : bool
    (let
      [first-classes : ast.AstSpmdParamClassList
        (ast.ast-spmd-param-class-list-new)]
      [second-classes : ast.AstSpmdParamClassList
        (ast.ast-spmd-param-class-list-new)]
      [specializations : ast.AstSpmdSpecializationList
        (ast.ast-spmd-specialization-list-new)]
      [helper-id : i64 (ci.intern-generated-canonical-name "helper")]
      [x-id : i64 (ci.intern-generated-canonical-name "x")]
      (ast.ast-spmd-param-class-list-push (&mut first-classes) Uniform)
      (ast.ast-spmd-param-class-list-push (&mut second-classes) Uniform)
      (ast.ast-spmd-specialization-list-push
        (&mut specializations)
        (ast.AstSpmdSpecialization 8 (box first-classes) Uniform -1))
      (ast.ast-spmd-specialization-list-push
        (&mut specializations)
        (ast.AstSpmdSpecialization 16 (box second-classes) Uniform -1))
      (let
        [callable : tlci.TlciSpmdCallable
          (build.build-package-tlci-callable
            (ast.ast-node-pool-reader-type-segment-bases)
            "pkg"
            "pkg"
            helper-id
            (ast.ast-param-cons
              (ast.ast-param-id x-id (I64) false)
              (ast.ast-param-list-new))
            (I64)
            specializations
            (Scalar))]
        [emitted : tlci.TlciSpmdSpecializations callable.specializations]
        (and
          (= (tlci.tlci-spmd-specializations-len emitted) 1)
          (let
            [item : tlci.TlciSpmdSpecialization
              (tlci.tlci-spmd-specializations-ref emitted 0)]
            (and
              (= item.lanes 1)
              (string.eq item.args "u")
              (string.eq item.result "u")
              (= item.index-param -1))))))))

(cfg
  test
  (test
    build-package-tlci-callable-smoke
    (unless
      (and
        (build-package-tlci-callable-smoke-ok?)
        (build-package-tlci-scalar-collapse-smoke-ok?))
      (io.panic "build package TLCI callable smoke failed"))))

(cfg
  test
  (define (build-package-tlci-macro-capture-smoke-ok?) : bool
    (let
      [source : String
        "(module z.macros)\n(defmacro (wrap [value : Expr]) : Expr `(identity ,value))\n(module dep.macros)\n(defmacro (foreign [value : Expr]) : Expr `(foreign ,value))\n(module a.macros)\n(defmacro (fold [items : Expr ...]) : bool (comptime.expr-list-fold-if items (comptime.expr-bool true) (comptime.expr-bool false) true))\n"]
      (match (compiler_parse_core.parse-ast-source source)
        [(Err _) false]
        [(Ok program)
          (match program
            [(Program decls-box)
              (let
                [decls : ast.AstDeclList (deref decls-box)]
                [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
                [owned-sources : build_string_i64_map.Map
                  (build_string_i64_map.with-capacity 4)]
                [names : cli_svec.Vec (cli_svec.new)]
                [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures
                  (compiler_tlci_native_producer.tlci-native-macro-captures-new)]
                (build_string_i64_map.insert-ref!
                  (&mut owned-sources)
                  (load.compiler-load-normalize-path "pkg/src/macros.tl")
                  1)
                (ast.ast-decl-path-list-push-with-owner-id
                  (&mut paths)
                  "pkg/src/macros.tl"
                  cbi.compiler-builtin-id-fix-empty)
                (ast.ast-decl-path-list-push-with-owner-id
                  (&mut paths)
                  "pkg/src/macros.tl"
                  cbi.compiler-builtin-id-fix-empty)
                (ast.ast-decl-path-list-push-with-owner-id
                  (&mut paths)
                  "dep/src/lib.tl"
                  cbi.compiler-builtin-id-fix-empty)
                (ast.ast-decl-path-list-push-with-owner-id
                  (&mut paths)
                  "dep/src/lib.tl"
                  cbi.compiler-builtin-id-fix-empty)
                (ast.ast-decl-path-list-push-with-owner-id
                  (&mut paths)
                  "pkg/src/macros.tl"
                  cbi.compiler-builtin-id-fix-empty)
                (ast.ast-decl-path-list-push-with-owner-id
                  (&mut paths)
                  "pkg/src/macros.tl"
                  cbi.compiler-builtin-id-fix-empty)
                (build.build-package-tlci-collect-macros-into!
                  decls
                  paths
                  ""
                  ""
                  "pkg"
                  owned-sources
                  (&mut names)
                  (&mut captures))
                (let
                  [collector : build.BuildPackageTlciMacroCollector
                    (build.build-package-tlci-finish-macro-collector
                      (&mut names)
                      captures)]
                  [catalog : (__tl_dyn-array String) collector.names]
                  [_source : String
                    (compiler_tlci_native_producer.embedded-native-source
                      (owned_view.compiler-owned-shared-view catalog)
                      (& collector.captures))]
                  (and
                    (= (array-length catalog) 2)
                    (string.eq (array-ref catalog 0) "a.macros/fold")
                    (string.eq (array-ref catalog 1) "z.macros/wrap")
                    (= collector.captures.len 2)
                    (>=
                      (compiler_tlci_native_producer.tlci-native-macro-capture-slot
                        (& collector.captures)
                        "a.macros/fold")
                      0)
                    (>=
                      (compiler_tlci_native_producer.tlci-native-macro-capture-slot
                        (& collector.captures)
                        "z.macros/wrap")
                      0)
                    (<
                      (compiler_tlci_native_producer.tlci-native-macro-capture-slot
                        (& collector.captures)
                        "dep.macros/foreign")
                      0)
                    (=
                      (array-ref
                        compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-count
                        0)
                      2))))])]))))

(cfg
  test
  (test
    build-package-tlci-macro-capture
    (unless
      (build-package-tlci-macro-capture-smoke-ok?)
      (io.panic "build package tlci macro capture smoke failed"))))

(cfg
  test
  (define (build-package-rollback-test-expect-ok
    [result : io.ResultIoUnit]
    [context : String]) : unit
    (match result
      [(OkIoUnit) unit]
      [(ErrIoUnit error)
        (io.panic (str_cat.str-cat context ": " (io.error-message error)))])))

(cfg
  test
  (define (build-package-rollback-test-temp [label : String]) : String
    (match (fs.try-create-temp-dir (& label))
      [(OkIoString path) path]
      [(ErrIoString error)
        (io.panic
          (str_cat.str-cat
            "build package rollback test temp: "
            (io.error-message error)))])))

(cfg
  test
  (define (build-package-rollback-test-path
    [root : (& root str)]
    [name : String]) : String
    (fs.path-join root (& name))))

(cfg
  test
  (define (build-package-rollback-test-stage [root : (& root str)]) : build.BuildPackageStagePaths
    (let
      [name : String "stage"]
      [dir : String (fs.path-join root (& name))]
      (build-package-rollback-test-expect-ok
        (fs.try-mkdir (& dir))
        "build package rollback test mkdir stage")
      (build.BuildPackageStagePaths
        (owned_view.compiler-owned-shared-view dir)
        (build-package-rollback-test-path dir "a")
        (build-package-rollback-test-path dir "o")
        (build-package-rollback-test-path dir "r")
        (build-package-rollback-test-path dir "f")
        (build-package-rollback-test-path dir "t")))))

(cfg
  test
  (define (build-package-rollback-test-write
    [path : (& path str)]
    [text : String]) : unit
    (build-package-rollback-test-expect-ok
      (io.try-write-file path (byte_buf.str-as-bytes (& text)))
      "build package rollback test write")))

(cfg
  test
  (define (build-package-rollback-test-path-exists? [path : (& path str)]) : bool
    (match (io.try-file-exists? path)
      [(OkIoBool exists) exists]
      [(ErrIoBool _) false])))

(cfg
  test
  (define (build-package-rollback-test-restored-at?
    [rollback : (& rollback build.BuildPackageRollbackDisposition)]
    [index : i64]
    [backup-path : (& backup-path str)]
    [final-path : (& final-path str)]) : bool
    (if (>= index rollback.len)
      false
      (match (owned_view.compiler-owned-array-element-shared-view
        rollback.backups
        index)
        [(Restored backup final)
          (and (string.eq backup backup-path) (string.eq final final-path))]
        [_ false]))))

(cfg
  test
  (define (build-package-rollback-test-retained-at?
    [rollback : (& rollback build.BuildPackageRollbackDisposition)]
    [index : i64]
    [backup-path : (& backup-path str)]
    [final-path : (& final-path str)]) : bool
    (if (>= index rollback.len)
      false
      (match (owned_view.compiler-owned-array-element-shared-view
        rollback.backups
        index)
        [(Retained backup final error)
          (and
            (string.eq backup backup-path)
            (string.eq final final-path)
            (> (string.string-length error) 0))]
        [_ false]))))

(cfg
  test
  (define (build-package-rollback-test-clean
    [root : String]
    [stage : build.BuildPackageStagePaths]
    [final-a : String]
    [final-b : String]) : unit
    (build.build-package-clean-stage
      (owned_view.compiler-owned-shared-view stage))
    (fs.try-remove-file-if-exists (& final-a))
    (fs.try-remove-file-if-exists (& final-b))
    (fs.try-remove-dir-if-exists (& final-a))
    (fs.try-remove-dir-if-exists (& final-b))
    (let
      [stage-dir : String stage.dir]
      (fs.try-remove-dir-if-exists (& stage-dir)))
    (fs.try-remove-dir-if-exists (& root))
    unit))

(cfg
  test
  (define (build-package-rollback-partial-restore-test-ok?) : bool
    (let
      [root : String
        (build-package-rollback-test-temp "typelisp build rollback partial")]
      [stage : build.BuildPackageStagePaths
        (build-package-rollback-test-stage root)]
      [final-a : String (build-package-rollback-test-path root "final-a")]
      [final-b : String (build-package-rollback-test-path root "final-b")]
      [backup-a : String
        (str_cat.str-cat
          (owned_view.compiler-owned-shared-view stage.asm)
          ".previous")]
      [backup-b : String
        (str_cat.str-cat
          (owned_view.compiler-owned-shared-view stage.obj)
          ".previous")]
      [plan : build.BuildPackageCommitPlan
        (build.build-package-commit-plan-add
          (build.build-package-commit-plan-add
            (build.build-package-commit-plan-new)
            (owned_view.compiler-owned-shared-view final-a)
            (owned_view.compiler-owned-shared-view stage.asm))
          (owned_view.compiler-owned-shared-view final-b)
          (owned_view.compiler-owned-shared-view stage.obj))]
      (build-package-rollback-test-write backup-a "old-a")
      (build-package-rollback-test-write backup-b "old-b")
      (build-package-rollback-test-expect-ok
        (fs.try-mkdir (& final-b))
        "build package rollback test mkdir restore collision")
      (build.build-package-commit-plan-set-had-old!
        (owned_view.compiler-owned-shared-view plan)
        0)
      (build.build-package-commit-plan-set-had-old!
        (owned_view.compiler-owned-shared-view plan)
        1)
      (let
        [rollback : build.BuildPackageRollbackDisposition
          (build.build-package-commit-plan-rollback plan 0 2)]
        [diagnostic : String
          (build.build-package-commit-error-message
            "primary commit error"
            (owned_view.compiler-owned-shared-view rollback)
            (owned_view.compiler-owned-shared-view stage.dir))]
        (build.build-package-clean-stage-after-rollback
          stage
          (owned_view.compiler-owned-shared-view rollback))
        (build.build-package-clean-stage-after-rollback
          stage
          (owned_view.compiler-owned-shared-view rollback))
        (let
          [primary-needle : String "primary commit error"]
          [restore-needle : String
            "rollback failed to restore previous package artifact"]
          [stage-needle : String "retained package artifact recovery stage"]
          [ok : bool
            (and
              (= rollback.len 2)
              (build-package-rollback-test-retained-at?
                rollback
                0
                backup-b
                final-b)
              (build-package-rollback-test-restored-at?
                rollback
                1
                backup-a
                final-a)
              (build.build-package-rollback-recovery-required? rollback)
              (build.build-package-file-text-eq?
                (owned_view.compiler-owned-shared-view final-a)
                "old-a")
              (build.build-package-file-text-eq? backup-b "old-b")
              (build-package-rollback-test-path-exists? stage.dir)
              (string.eq
                (string.substring
                  (& diagnostic)
                  0
                  (string.string-length primary-needle))
                primary-needle)
              (string.contains (& diagnostic) (& restore-needle))
              (string.contains (& diagnostic) (& stage-needle)))]
          (build-package-rollback-test-clean root stage final-a final-b)
          ok)))))

(cfg
  test
  (define (build-package-rollback-complete-test-ok?) : bool
    (let
      [root : String
        (build-package-rollback-test-temp "typelisp build rollback complete")]
      [stage : build.BuildPackageStagePaths
        (build-package-rollback-test-stage root)]
      [final : String (build-package-rollback-test-path root "final")]
      [unused : String (build-package-rollback-test-path root "unused")]
      [backup : String
        (str_cat.str-cat
          (owned_view.compiler-owned-shared-view stage.asm)
          ".previous")]
      [plan : build.BuildPackageCommitPlan
        (build.build-package-commit-plan-add
          (build.build-package-commit-plan-new)
          (owned_view.compiler-owned-shared-view final)
          (owned_view.compiler-owned-shared-view stage.asm))]
      (build-package-rollback-test-write final "new")
      (build-package-rollback-test-write backup "old")
      (build.build-package-commit-plan-set-had-old!
        (owned_view.compiler-owned-shared-view plan)
        0)
      (let
        [rollback : build.BuildPackageRollbackDisposition
          (build.build-package-commit-plan-rollback plan 1 1)]
        (build.build-package-clean-stage-after-rollback
          stage
          (owned_view.compiler-owned-shared-view rollback))
        (let
          [ok : bool
            (and
              (= rollback.len 1)
              (= (string.string-length rollback.errors) 0)
              (not
                (build.build-package-rollback-recovery-required?
                  (owned_view.compiler-owned-shared-view rollback)))
              (build-package-rollback-test-restored-at? rollback 0 backup final)
              (build.build-package-file-text-eq?
                (owned_view.compiler-owned-shared-view final)
                "old")
              (not (build-package-rollback-test-path-exists? backup))
              (not (build-package-rollback-test-path-exists? stage.dir)))]
          (build-package-rollback-test-clean root stage final unused)
          ok)))))

(cfg
  test
  (define (build-package-rollback-remove-failure-test-ok?) : bool
    (let
      [root : String
        (build-package-rollback-test-temp "typelisp build rollback remove")]
      [stage : build.BuildPackageStagePaths
        (build-package-rollback-test-stage root)]
      ;; Empty paths are explicitly invalid on both hosts, so this injects a
      ;; deterministic removal failure without relying on directory unlink
      ;; differences between Linux and Windows.
      [final : String ""]
      [unused : String (build-package-rollback-test-path root "unused")]
      [plan : build.BuildPackageCommitPlan
        (build.build-package-commit-plan-add
          (build.build-package-commit-plan-new)
          (owned_view.compiler-owned-shared-view final)
          (owned_view.compiler-owned-shared-view stage.asm))]
      [rollback : build.BuildPackageRollbackDisposition
        (build.build-package-commit-plan-rollback plan 1 0)]
      (build.build-package-clean-stage-after-rollback
        stage
        (owned_view.compiler-owned-shared-view rollback))
      (let
        [needle : String "rollback failed to remove installed package artifact"]
        [invalid-needle : String "io: invalid path"]
        [ok : bool
          (and
            (= rollback.len 0)
            (> (string.string-length rollback.errors) 0)
            (string.contains (& rollback.errors) (& needle))
            (string.contains (& rollback.errors) (& invalid-needle))
            (not (build.build-package-rollback-recovery-required? rollback))
            (not (build-package-rollback-test-path-exists? stage.dir)))]
        (build-package-rollback-test-clean root stage final unused)
        ok))))

(cfg
  test
  (define (build-package-commit-preflight-test-ok?) : bool
    (let
      [root : String
        (build-package-rollback-test-temp "typelisp build commit preflight")]
      [stage : build.BuildPackageStagePaths
        (build-package-rollback-test-stage root)]
      [final : String (build-package-rollback-test-path root "final")]
      [unused : String (build-package-rollback-test-path root "unused")]
      [plan : build.BuildPackageCommitPlan
        (build.build-package-commit-plan-add
          (build.build-package-commit-plan-new)
          (owned_view.compiler-owned-shared-view final)
          (owned_view.compiler-owned-shared-view stage.asm))]
      (match (build.build-package-commit-plan-run plan)
        [(Ok)
          (build-package-rollback-test-clean root stage final unused)
          false]
        [(Err message rollback)
          (build.build-package-clean-stage-after-rollback
            stage
            (owned_view.compiler-owned-shared-view rollback))
          (let
            [needle : String
              "staged package artifact is missing or non-regular"]
            [ok : bool
              (and
                (= rollback.len 0)
                (= (string.string-length rollback.errors) 0)
                (string.contains (& message) (& needle))
                (not (build-package-rollback-test-path-exists? stage.dir)))]
            (build-package-rollback-test-clean root stage final unused)
            ok)]))))

(cfg
  test
  (define (build-package-commit-success-cleanup-test-ok?) : bool
    (let
      [root : String
        (build-package-rollback-test-temp "typelisp build commit success")]
      [stage : build.BuildPackageStagePaths
        (build-package-rollback-test-stage root)]
      [final : String (build-package-rollback-test-path root "final")]
      [unused : String (build-package-rollback-test-path root "unused")]
      [backup : String
        (str_cat.str-cat
          (owned_view.compiler-owned-shared-view stage.asm)
          ".previous")]
      [plan : build.BuildPackageCommitPlan
        (build.build-package-commit-plan-add
          (build.build-package-commit-plan-new)
          (owned_view.compiler-owned-shared-view final)
          (owned_view.compiler-owned-shared-view stage.asm))]
      (build-package-rollback-test-write final "old")
      (build-package-rollback-test-write stage.asm "new")
      (match (build.build-package-commit-plan-run plan)
        [(Err _ rollback)
          (build.build-package-clean-stage-after-rollback stage rollback)
          (build-package-rollback-test-clean root stage final unused)
          false]
        [(Ok)
          (build.build-package-clean-stage
            (owned_view.compiler-owned-shared-view stage))
          (let
            [ok : bool
              (and
                (build.build-package-file-text-eq?
                  (owned_view.compiler-owned-shared-view final)
                  "new")
                (not (build-package-rollback-test-path-exists? backup))
                (not (build-package-rollback-test-path-exists? stage.dir)))]
            (build-package-rollback-test-clean root stage final unused)
            ok)]))))

(cfg
  test
  (test
    build-package-commit-rollback-recovery
    (unless
      (build-package-rollback-partial-restore-test-ok?)
      (io.panic "build package rollback partial restore test failed"))
    (unless
      (build-package-rollback-complete-test-ok?)
      (io.panic "build package rollback complete test failed"))
    (unless
      (build-package-rollback-remove-failure-test-ok?)
      (io.panic "build package rollback removal failure test failed"))
    (unless
      (build-package-commit-preflight-test-ok?)
      (io.panic "build package commit preflight test failed"))
    (unless
      (build-package-commit-success-cleanup-test-ok?)
      (io.panic "build package commit success cleanup test failed"))))

(cfg
  test
  (test
    build-package-require-direct-object-typed-fallback
    (unless
      (and
        (string.eq
          (backend.compiler-direct-object-fallback-transcript
            (ArtifactKindUnavailable (Windows) StaticLib))
          "artifact-kind-unavailable|target=windows-x86_64|kind=staticlib")
        (match (build.build-package-require-direct-object
          (Assembly "assembly" (ResourceBudget 513 512)))
          [(Err message)
            (string.eq
              message
              "build: direct object required: resource-budget|owned-paths=513|limit=512")]
          [_ false])
        (match (build.build-package-require-direct-object
          (DirectObject "object" "side assembly"))
          [(DirectObject object assembly)
            (and
              (string.eq object "object")
              (string.eq assembly "side assembly"))]
          [_ false])
        (match (build.build-package-require-direct-object (Err "diagnostic"))
          [(Err message) (string.eq message "diagnostic")]
          [_ false]))
      (io.panic "strict direct-object route failed"))))

(test
  build-package-worker-resolved-deps-args-smoke
  (unless
    (let
      [remote : load.CompilerPkgDep
        (load.CompilerPkgDep "remote" "target/typelisp/git-deps/remote")]
      [local : load.CompilerPkgDep (load.CompilerPkgDep "local" "../local")]
      [deps : load.CompilerPkgDepList
        (load.compiler-pkg-dep-list-push
          (load.compiler-pkg-dep-list-push
            (load.compiler-pkg-dep-list-empty)
            remote)
          local)]
      [actual : process.ProcessStringList
        (build.build-package-worker-append-resolved-deps
          (process.args-empty)
          deps
          0)]
      [expected0 : process.ProcessStringList
        (build_run_core.source-tool-args-append
          (process.args-empty)
          "--resolved-dep")]
      [expected1 : process.ProcessStringList
        (build_run_core.source-tool-args-append expected0 "remote")]
      [expected2 : process.ProcessStringList
        (build_run_core.source-tool-args-append
          expected1
          "target/typelisp/git-deps/remote")]
      [expected3 : process.ProcessStringList
        (build_run_core.source-tool-args-append expected2 "--resolved-dep")]
      [expected4 : process.ProcessStringList
        (build_run_core.source-tool-args-append expected3 "local")]
      [expected : process.ProcessStringList
        (build_run_core.source-tool-args-append expected4 "../local")]
      (build_run_tests.source-tool-string-list-eq? actual expected))
    (io.panic "build package worker resolved deps args smoke failed")))

;; A `(link ...)` scope with at most one value per field ("" omits it).
(cfg
  test
  (define (build-package-graph-test-link-set
    [library : String]
    [search-path : String]
    [arg : String]) : load.CompilerPkgLinkSet
    (let
      [libraries : fs.FsStringVector (fs.string-vector-new)]
      [search-paths : fs.FsStringVector (fs.string-vector-new)]
      [args : fs.FsStringVector (fs.string-vector-new)]
      (if (> (string.string-length library) 0)
        (fs.string-vector-push! (&mut libraries) library)
        unit)
      (if (> (string.string-length search-path) 0)
        (fs.string-vector-push! (&mut search-paths) search-path)
        unit)
      (if (> (string.string-length arg) 0)
        (fs.string-vector-push! (&mut args) arg)
        unit)
      (load.CompilerPkgLinkSet libraries search-paths args))))

(cfg
  test
  (define (build-package-graph-test-link-node
    [manifest-path : String]
    [name : String]
    [link : load.CompilerPkgLink]
    [provenance : build.BuildPackageSourceProvenance]) : build.BuildPackageGraphNode
    (build.BuildPackageGraphNode
      manifest-path
      (load.CompilerPkgManifest
        name
        "0.1.0"
        (CompilerPkgKindLib)
        "src/lib.tl"
        (load.compiler-pkg-deps-empty)
        link)
      provenance)))

;; wa and wb each export `m` for every target, their own vendored library and
;; search path, and one raw argument.
(cfg
  test
  (define (build-package-graph-test-wrapper
    [dir : String]
    [name : String]
    [linux-library : String]
    [windows-library : String]) : build.BuildPackageGraphNode
    (build-package-graph-test-link-node
      (str_cat.str-cat dir "/typelisp.pkg")
      name
      (load.CompilerPkgLink
        (build-package-graph-test-link-set "m" "vendor" "-Wl,--as-needed")
        (build-package-graph-test-link-set linux-library "" "")
        (build-package-graph-test-link-set windows-library "" ""))
      (Local))))

(cfg
  test
  (define (build-package-graph-test-link-inputs
    [nodes : build.BuildPackageGraphNodeVec]
    [target : backend.CompilerBackendTarget]) : build_run_core.SourceToolLinkInputs
    (match (build.build-package-graph-link-inputs nodes (Release) target)
      [(Ok inputs) inputs]
      [(Err _)
        (build_run_core.source-tool-link-inputs-add-lib
          (build_run_core.source-tool-link-inputs-empty)
          "error")])))

(cfg
  test
  (define (build-package-graph-test-link-error
    [node : build.BuildPackageGraphNode]) : String
    (match (build.build-package-graph-link-inputs
      (build.build-package-graph-node-vec-push
        (build.build-package-graph-node-vec-with-capacity 1)
        node)
      (Release)
      (Linux))
      [(Ok _) ""]
      [(Err message) message])))

(cfg
  test
  (define (build-package-graph-test-fetched-wrapper
    [linux-search-path : String]) : build.BuildPackageGraphNode
    (build-package-graph-test-link-node
      (str_cat.str-cat (fs.current-dir) "/typelisp.pkg")
      "fetched"
      (load.CompilerPkgLink
        (build-package-graph-test-link-set "" "" "")
        (build-package-graph-test-link-set "" linux-search-path "")
        (build-package-graph-test-link-set "" "" ""))
      (Fetched "fetched" (fs.current-dir)))))

;; A direct dependency's `(link ...)` section reaches the binary's link (#6982):
;; archives, then libraries and search paths merged once across wrappers, raw
;; arguments kept per wrapper, the target's scope only, relative search paths
;; anchored at the declaring manifest, and every declaration's origin.
(test
  build-package-graph-link-propagation
  (let
    [nodes : build.BuildPackageGraphNodeVec
      (build.build-package-graph-node-vec-push
        (build.build-package-graph-node-vec-push
          (build.build-package-graph-node-vec-with-capacity 2)
          (build-package-graph-test-wrapper "root/wa" "wa" "a1" "a1win"))
        (build-package-graph-test-wrapper "root/wb" "wb" "b1" ""))]
    [linux : build_run_core.SourceToolLinkInputs
      (build-package-graph-test-link-inputs
        (owned_view.compiler-owned-shared-view nodes)
        (Linux))]
    [windows : build_run_core.SourceToolLinkInputs
      (build-package-graph-test-link-inputs
        (owned_view.compiler-owned-shared-view nodes)
        (Windows))]
    [origins : build_run_core.SourceToolLinkOrigins
      (build_run_core.source-tool-link-inputs-origins (& linux))]
    [expected-libs : process.ProcessStringList
      (process.args-cons
        "m"
        (process.args-cons "b1" (process.args-single "a1")))]
    (unless
      (and
        (build_run_tests.source-tool-string-list-eq?
          (build_run_core.source-tool-link-inputs-libs (& linux))
          expected-libs)
        (build_run_tests.source-tool-string-list-eq?
          (build_run_core.source-tool-link-inputs-search-dirs (& linux))
          (process.args-cons
            "root/wb/vendor"
            (process.args-single "root/wa/vendor")))
        (build_run_tests.source-tool-string-list-eq?
          (build_run_core.source-tool-link-inputs-raw-args (& linux))
          (process.args-cons
            "-Wl,--as-needed"
            (process.args-single "-Wl,--as-needed")))
        (build_run_tests.source-tool-string-list-eq?
          (build_run_core.source-tool-link-inputs-archives (& linux))
          (process.args-cons
            "root/wb/target/release/libwb.a"
            (process.args-single "root/wa/target/release/libwa.a")))
        (build_run_tests.source-tool-string-list-eq?
          (build_run_core.source-tool-link-inputs-libs (& windows))
          (process.args-cons "m" (process.args-single "a1win")))
        (= (process.args-count origins.kinds) 10)
        (string.eq (process.args-ref origins.kinds 0) "archive")
        (string.eq
          (process.args-ref origins.declared-by 0)
          "package `wb` (root/wb/typelisp.pkg)")
        (string.eq (process.args-ref origins.values 4) "b1")
        (string.eq
          (process.args-ref origins.declared-by 4)
          "package `wb` (root/wb/typelisp.pkg) field `linux-libraries`")
        (string.eq (process.args-ref origins.values 2) "root/wb/vendor"))
      (io.panic "build: dependency link propagation smoke failed"))))

;; A fetched dependency's relative search path must exist inside its locked
;; checkout; an absolute search path is a system location, used as written.
(test
  build-package-graph-link-fetched-confinement
  (let
    [escaping : String
      (build-package-graph-test-link-error
        (build-package-graph-test-fetched-wrapper "../outside"))]
    [missing : String
      (build-package-graph-test-link-error
        (build-package-graph-test-fetched-wrapper "no-such-vendor-dir"))]
    (unless
      (and
        (string.contains
          (& escaping)
          "field `linux-search-paths` path `../outside` is not confined to locked checkout")
        (string.contains
          (& missing)
          "path `no-such-vendor-dir` is not confined")
        (string.eq
          (build-package-graph-test-link-error
            (build-package-graph-test-fetched-wrapper "/usr/lib"))
          ""))
      (io.panic "build: fetched dependency link confinement smoke failed"))))