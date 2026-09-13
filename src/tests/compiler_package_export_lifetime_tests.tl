;; Source-owned package export lifetime checks on both CI hosts.
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as strings)
(import build_cli_core as build)
(import compiler_ast_types as ast)
(import compiler_backend as backend)
(import compiler_builtin_ids as cbi)
(import compiler_driver_core as driver)
(import compiler_intern as ci)
(import compiler_load as load)
(import compiler_owned_view as owned_view)
(import compiler_parse_core as parse)
(import compiler_typecheck_core as tc)
(import compiler_tlci_native_producer as producer)
(import package_source_core as source_set)
(import tlci_core as tlci)

(define export-test-identity : String
  "1111111111111111111111111111111111111111")

(define (export-test-manifest) : load.CompilerPkgManifest
  (load.CompilerPkgManifest
    (string.copy "capture")
    (string.copy "0.1.0")
    (CompilerPkgKindLib)
    (string.copy "src/macros.tl")
    (load.compiler-pkg-deps-empty)
    (load.compiler-pkg-link-empty)))

(define (export-test-sources [manifest : load.CompilerPkgManifest]) : source_set.PackageSourceSet
  (let
    [sources : strings.Vec (strings.new)]
    (begin
      (strings.push-ref! (&mut sources) (string.copy "pkg/src/macros.tl"))
      (source_set.PackageSourceSet
        (string.copy "pkg/typelisp.pkg")
        (string.copy "pkg")
        manifest
        sources))))

(define (export-test-paths [decls : ast.AstDeclList]) : ast.AstDeclPathList
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) (ast.ast-decl-path-list-new)]
    [(ast.AstDeclListStep.Cons _ rest)
      (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
        (string.copy "pkg/src/macros.tl")
        -1
        -1
        (export-test-paths rest))]))

(define (export-test-capture [source : String]) : build.ResultBuildPackageTlciExports
  (let
    [home : arena.Arena (arena.current)]
    [home-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [home-interns : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [home-builtins : cbi.CompilerBuiltinIdsState (cbi.state-capture)]
    (with-scratch
      (let
        [pools : ast.AstNodePoolContext
          (ast.ast-node-pool-context-new-with-capacities-in-arena
            1
            1
            (arena.tl_arena_current))]
        [interns : ci.InternCompatState (ci.intern-compat-state-new)]
        [_install : unit
          (begin
            (ast.ast-node-pool-context-install! pools)
            (ci.intern-compat-state-install! interns)
            (tc.compiler-typecheck-reset-intern-owned-state!)
            (driver.compiler-driver-reset-analysis-state!))]
        [result : build.ResultBuildPackageTlciExports
          (match (parse.parse-ast-source source)
            [(parse.ResultAstProgram.Err _)
              (in-arena
                home
                (build.ResultBuildPackageTlciExports.Err
                  (string.copy "fixture parse failed")))]
            [(parse.ResultAstProgram.Ok program)
              (match program
                [(ast.AstProgram.Program decls-box)
                  (let
                    [decls : ast.AstDeclList
                      (owned_view.compiler-owned-box-shared-view decls-box)]
                    [manifest : load.CompilerPkgManifest (export-test-manifest)]
                    [sources : source_set.PackageSourceSet
                      (export-test-sources
                        (owned_view.compiler-owned-shared-view manifest))]
                    [paths : ast.AstDeclPathList
                      (export-test-paths
                        (owned_view.compiler-owned-shared-view decls))]
                    (in-arena
                      home
                      (build.build-package-tlci-capture-exports
                        manifest
                        (backend.CompilerBackendMode.Scalar)
                        decls
                        paths
                        sources)))])])]
        [retired-pools : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        [intern-arena : i64 (ci.intern-persistent-arena-handle)]
        (begin
          (load.compiler-load-session-reset-pools!)
          (load.compiler-load-transfer-frontend-handoff!)
          (in-arena
            home
            (begin
              (ci.intern-compat-state-install! home-interns)
              (ast.ast-node-pool-context-install! home-pools)
              (tc.compiler-typecheck-reset-intern-owned-state!)
              (driver.compiler-driver-reset-analysis-state!)
              (cbi.state-install! (& home-builtins))))
          (ast.ast-node-pool-context-destroy-storage! retired-pools)
          (unsafe
            ;; The opaque interner owns this arena; its active state has been
            ;; restored above. This test intentionally invalidates all of its
            ;; names, which must not be reachable from the retained export DTO.
            ;; lint-allow: raw-arena-op
            (arena.tl_arena_destroy intern-arena))
          result)))))

(define (export-test-reuse!) : unit
  (with-scratch
    (let
      [slots : (__tl_dyn-array i64) (__tl_make-array i64 1048576)]
      [index : i64 0]
      (while (< index (array-length slots))
        (begin
          (set! (array-ref slots index) 7797)
          (set! index (+ index 1)))))))

(define (export-test-emit-ok?
  [metadata : String]
  [names : (__tl_dyn-array String)]
  [source : String]
  [windows-target : bool]) : bool
  (match (producer.embedded-native-emit-package-source
    metadata
    (string.copy (& export-test-identity))
    windows-target
    (tlci.tlci-empty-bytes)
    names
    source)
    [(producer.ResultProducerBytes.Err _) false]
    [(producer.ResultProducerBytes.Ok bytes) (> (array-length bytes) 0)]))

(test
  package-export-metadata-survives-frontend-retirement
  (let
    [exports : build.ResultBuildPackageTlciExports
      (export-test-capture "(module capture.macros)\n(define answer : i64 42)")]
    (begin
      (export-test-reuse!)
      (match exports
        [(build.ResultBuildPackageTlciExports.Err message) (io.panic message)]
        [(build.ResultBuildPackageTlciExports.Ok metadata names source)
          (unless
            (and
              (= (array-length names) 0)
              (string.eq source "")
              (string.eq
                metadata
                (tlci.tlci-metadata-emit
                  (tlci.tlci-make-metadata "v1" "capture" "0.1.0"))))
            (io.panic "retired package metadata changed"))]))))

(test
  package-export-native-source-survives-frontend-retirement
  (let
    [exports : build.ResultBuildPackageTlciExports
      (export-test-capture
        "(module capture.macros)\n(defmacro (wrap [value : Expr]) : Expr `(identity ,value))\n(defmacro (unsupported [value : Expr]) : Expr (match value [(comptime.Expr.If c t e) c] [_ value]))")]
    (begin
      (export-test-reuse!)
      (match exports
        [(build.ResultBuildPackageTlciExports.Err message) (io.panic message)]
        [(build.ResultBuildPackageTlciExports.Ok metadata names source)
          (unless
            (and
              (= (array-length names) 2)
              (string.eq (array-ref names 0) "capture.macros/unsupported")
              (string.eq (array-ref names 1) "capture.macros/wrap")
              (export-test-emit-ok?
                (owned_view.compiler-owned-shared-view metadata)
                (owned_view.compiler-owned-shared-view names)
                (owned_view.compiler-owned-shared-view source)
                false)
              (export-test-emit-ok? metadata names source true))
            (io.panic "captured native source retained frontend references"))]))))