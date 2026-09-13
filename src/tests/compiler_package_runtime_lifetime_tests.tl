(import stdlib.arena)
(import stdlib.vector)
(import (vector.vector String) as roots_vec)
(import compiler_cfg_core as cfg_core)
(import stdlib.profile)
(import stdlib.io)
(import compiler_intern as ci)
(import compiler_load as load)
(import stdlib.string)
(import compiler_driver_core as driver)
(import compiler_ast_types as ast)
(import compiler_parse_core as parser)
(import compiler_backend as backend)
(import compiler_owned_view as owned_view)

(define (runtime-owner-smoke-for-route
  [source : String]
  [target : backend.CompilerBackendTarget]
  [level : i64]
  [direct-object : bool]) : String
  (let
    [home : arena.Arena (arena.current)]
    (with-scratch
      (let
        [job : arena.Arena (arena.current)]
        [scope : driver.CompilerDriverPackageRuntimeScope
          (driver.compiler-driver-package-runtime-scope-new home)]
        [program : parser.ResultAstProgram
          (in-arena
            (arena.Arena (array-ref scope.frontend-arena 0))
            (parser.parse-ast-source source))]
        [_capture : unit
          (driver.compiler-driver-package-runtime-capture-frontend!
            (owned_view.compiler-owned-shared-view scope))]
        [result : String
          (in-arena
            home
            (match program
              [(parser.ResultAstProgram.Err message)
                (in-arena home (string.copy message))]
              [(parser.ResultAstProgram.Ok parsed)
                (match parsed
                  [(ast.AstProgram.Program decls-box)
                    (let
                      [lowered : driver.ResultCompilerDriverLowered
                        (driver.compiler-driver-package-runtime-lower
                          (owned_view.compiler-owned-shared-view scope)
                          "owner_smoke"
                          target
                          (backend.CompilerBackendMode.Scalar)
                          (owned_view.compiler-owned-box-shared-view decls-box)
                          (ast.ast-decl-path-list-new))]
                      (match (if direct-object
                        (match (driver.compiler-driver-emit-lowered-result-package-runtime-with-level-mode-entry-and-crt
                          ""
                          lowered
                          target
                          (backend.CompilerBackendMode.Scalar)
                          level
                          true
                          false)
                          [(driver.ResultCompilerDriverPackageRuntime.Object
                              _
                              asm
                              advisories)
                            (driver.ResultCompilerDriver.Ok asm advisories)]
                          [(driver.ResultCompilerDriverPackageRuntime.Assembly
                              _
                              _
                              _)
                            (io.panic
                              "lifetime fixture requires direct object emission")]
                          [(driver.ResultCompilerDriverPackageRuntime.Err
                              diag
                              advisories)
                            (driver.ResultCompilerDriver.Err diag advisories)])
                        (driver.compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
                          ""
                          lowered
                          target
                          true
                          (backend.CompilerBackendMode.Scalar)
                          level
                          true
                          false))
                        [(driver.ResultCompilerDriver.Ok asm _)
                          (in-arena home (string.copy asm))]
                        [(driver.ResultCompilerDriver.Err diag _)
                          (in-arena
                            home
                            (driver.compiler-driver-render-source-diagnostic
                              (owned_view.compiler-owned-box-shared-view diag)))]))])]))]
        (begin
          (in-arena
            job
            (begin
              (driver.compiler-driver-package-runtime-scope-release!
                (owned_view.compiler-owned-shared-view scope))
              (driver.compiler-driver-package-runtime-scope-release! scope)))
          result)))))

(define (runtime-owner-smoke-for
  [source : String]
  [target : backend.CompilerBackendTarget]
  [level : i64]) : String
  (runtime-owner-smoke-for-route source target level false))

(define (runtime-owner-smoke [source : String]) : String
  (runtime-owner-smoke-for source (backend.CompilerBackendTarget.Linux) 0))

(test
  package-runtime-success-error-success-restores-parent
  (let
    [parent : load.CompilerLoadSessionState
      (load.compiler-load-active-session-state-shared-view)]
    [table-id : i64 (ci.intern-active-table-id)]
    [sentinel : i64 (ci.intern "runtime-parent-retained-name")]
    [first : String (runtime-owner-smoke "(define (main) : i64 (+ 40 2))")]
    [bad : String
      (runtime-owner-smoke "(define (main) : i64 missing_owner_name)")]
    [last : String (runtime-owner-smoke "(define (main) : i64 42)")]
    (unless
      (and
        (string.contains first "main:")
        (string.contains last "main:")
        (string.contains bad "unbound name missing_owner_name")
        (= table-id (ci.intern-active-table-id))
        (string.eq (ci.intern-str sentinel) "runtime-parent-retained-name")
        (=
          parent.shared-address
          (__tl-project-field
            (load.compiler-load-active-session-state-shared-view)
            shared-address)))
      (io.panic "package runtime scope did not preserve serial ownership"))))

(test
  package-runtime-parse-error-survives-next-job
  (let
    [bad : String (runtime-owner-smoke "(define (main) : i64")]
    [next : String (runtime-owner-smoke "(define (main) : i64 42)")]
    (unless
      (and
        (> (string.string-length bad) 0)
        (not (string.contains bad "main:"))
        (string.contains next "main:"))
      (io.panic "package parse error failed to release its unlowered scope"))))

(test
  package-runtime-local-macro-retirement
  (let
    [macro : String
      (runtime-owner-smoke
        "(defmacro (wrap [value : Expr]) : Expr `(+ ,value 2)) (define (main) : i64 (wrap 40))")]
    [next : String (runtime-owner-smoke "(define (main) : i64 42)")]
    (unless
      (and (string.contains macro "main:") (string.contains next "main:"))
      (io.panic "package macro frontend retirement failed"))))

(test
  package-runtime-repeated-checked-errors-release-pools
  (let
    [warm : String
      (runtime-owner-smoke "(define (main) : i64 missing_owner_name)")]
    [before : i64 (profile.alloc-live)]
    [index : i64 0]
    (begin
      (unless
        (string.contains warm "unbound name missing_owner_name")
        (io.panic "expected checked error before lifetime measurement"))
      (while (< index 8)
        (begin
          (unless
            (string.contains
              (runtime-owner-smoke "(define (main) : i64 missing_owner_name)")
              "unbound name missing_owner_name")
            (io.panic "repeated checked error changed diagnostic"))
          (set! index (+ index 1))))
      ;; Includes copied diagnostics and restored parent selectors. Leaking one
      ;; source/checked pool per error retained 29 MB for these eight jobs.
      (unless
        (< (- (profile.alloc-live) before) 1048576)
        (io.panic "checked errors retained retired AST pool generations")))))

(test
  package-runtime-target-and-optimization-retirement
  (let
    [level : i64 0]
    (while (< level 3)
      (begin
        (unless
          (and
            (string.contains
              (runtime-owner-smoke-for
                "(define (main) : i64 42)"
                (backend.CompilerBackendTarget.Linux)
                level)
              "main:")
            (string.contains
              (runtime-owner-smoke-for
                "(define (main) : i64 42)"
                (backend.CompilerBackendTarget.Windows)
                level)
              "main:"))
          (io.panic "target or optimization route lost owned runtime output"))
        (set! level (+ level 1))))))

(test
  package-runtime-macro-error-survives-next-job
  (let
    [bad : String
      (runtime-owner-smoke
        "(defmacro (bad) : Expr missing_macro_name) (define (main) : i64 (bad))")]
    [next : String (runtime-owner-smoke "(define (main) : i64 42)")]
    (unless
      (and
        (string.contains bad "missing_macro_name")
        (not (string.contains bad "main:"))
        (string.contains next "main:"))
      (io.panic "macro rollover error did not release its runtime scope"))))

(define (runtime-owner-load-message [path : String]) : String
  (let
    [home : arena.Arena (arena.current)]
    (with-scratch
      (let
        [scope : driver.CompilerDriverPackageRuntimeScope
          (driver.compiler-driver-package-runtime-scope-new home)]
        [message : String
          (in-arena
            home
            (match (driver.compiler-driver-package-runtime-load
              (owned_view.compiler-owned-shared-view scope)
              path
              (roots_vec.new)
              "target/exp/package-runtime-lifetime"
              (load.compiler-pkg-deps-empty)
              false
              (cfg_core.compiler-cfg-empty))
              [(load.ResultCompilerLoadWithPaths.Ok _ _ _ _) "loaded"]
              [(load.ResultCompilerLoadWithPaths.Err diag)
                (driver.compiler-driver-render-source-diagnostic
                  (owned_view.compiler-owned-box-shared-view diag))]))]
        (begin
          (driver.compiler-driver-package-runtime-scope-release! scope)
          message)))))

(test
  package-runtime-import-error-captures-live-loader-state
  (begin
    (load.compiler-load-test-mkdir "target/exp")
    (load.compiler-load-test-mkdir "target/exp/package-runtime-lifetime")
    (load.compiler-load-write-file-text
      "target/exp/package-runtime-lifetime/helper.tl"
      "(module helper) (define value : i64 42)")
    (load.compiler-load-write-file-text
      "target/exp/package-runtime-lifetime/good.tl"
      "(import helper as helper) (define (main) : i64 helper.value)")
    (load.compiler-load-write-file-text
      "target/exp/package-runtime-lifetime/bad.tl"
      "(import helper as helper) (import absent_runtime as absent) (define (main) : i64 helper.value)")
    (let
      [table : i64 (ci.intern-active-table-id)]
      [first : String
        (runtime-owner-load-message
          "target/exp/package-runtime-lifetime/good.tl")]
      [bad : String
        (runtime-owner-load-message
          "target/exp/package-runtime-lifetime/bad.tl")]
      [last : String
        (runtime-owner-load-message
          "target/exp/package-runtime-lifetime/good.tl")]
      (unless
        (and
          (string.eq first "loaded")
          (string.eq last "loaded")
          (string.contains bad "absent_runtime")
          (= table (ci.intern-active-table-id)))
        (io.panic "failed package import did not restore live loader ownership")))))

(test
  package-runtime-direct-object-releases-side-backend
  (let
    [source : String "(define (main) : i64 42)"]
    [warm : String
      (runtime-owner-smoke-for-route
        (string.copy source)
        backend.CompilerBackendTarget.Linux
        0
        true)]
    [before : i64 (profile.alloc-live)]
    [index : i64 0]
    (begin
      (unless
        (string.contains warm "main:")
        (io.panic "direct object side assembly must survive runtime cleanup"))
      (while (< index 8)
        (begin
          (unless
            (string.contains
              (runtime-owner-smoke-for-route
                (string.copy source)
                backend.CompilerBackendTarget.Linux
                0
                true)
              "main:")
            (io.panic "repeated direct object emission lost side assembly"))
          (set! index (+ index 1))))
      ;; Includes retained object images, assembly and restored parent state.
      ;; Eight unretired side-backend arenas pushed this fixture above 1 MiB.
      (unless
        (< (- (profile.alloc-live) before) 1048576)
        (io.panic "direct object jobs retained private side-backend arenas")))))