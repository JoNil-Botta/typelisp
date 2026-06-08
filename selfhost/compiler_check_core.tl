;; compiler_check_core.tl - Shared selfhost check/typecheck helpers (#723).
(import "../stdlib/io.tl")

(import "../stdlib/string.tl")

(cfg compile-profile (import "../stdlib/profile.tl"))

(import "compiler_load.tl")

(import "compiler_typecheck.tl")

(defenum ResultCompilerCheck
  (OkCompilerCheck CompilerTypecheckSummary)
  (ErrCompilerCheck CompilerDiagnostic))

(cfg
  compile-profile
  (define compiler-check-profile-start-ms : i64
    0))

(cfg
  compile-profile
  (define (compiler-check-profile-start) : unit
    (set! compiler-check-profile-start-ms (profile-now-ms))))

(cfg
  compile-profile
  (define (compiler-check-profile-finish [phase : String]) : unit
    (print-error
      (string-append
        "compile-profile|check."
        (string-append
          phase
          (string-append
            "|"
            (string-append
              (int->string (- (profile-now-ms) compiler-check-profile-start-ms))
              "|0|0|0\n")))))))

(define (compiler-check-diagnostic-with-fallback-path
  [diag : CompilerDiagnostic]
  [path : String]) : CompilerDiagnostic
  (if (string-eq (compiler-diagnostic-path diag) "")
    (compiler-diagnostic-with-path diag path)
    diag))

(define (compiler-check-reset-pools!) : unit
  (begin
    (ast-node-pool-reset!)
    (ty-node-pool-reset!)))

(define (compiler-check-program-with-paths
  [path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultCompilerCheck
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (typecheck-compiler-program-with-paths (ast-program decls) paths)
      [(OkCompilerTypecheck summary)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (OkCompilerCheck summary))]
      [(ErrCompilerTypecheck diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ErrCompilerCheck
            (compiler-check-diagnostic-with-fallback-path diag path)))])))

(define (compiler-check-program [path : String] [decls : AstDeclList]) : ResultCompilerCheck
  (compiler-check-program-with-paths path decls AstDeclPathNil))

(define (compiler-check-loaded-with-prelude
  [path : String]
  [prelude-decls : AstDeclList]
  [prelude-paths : AstDeclPathList]
  [loaded : ResultCompilerLoadWithPaths]) : ResultCompilerCheck
  (match loaded
    [(OkCompilerLoadWithPaths entry-decls entry-paths _ _)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (compiler-check-program-with-paths
          path
          (compiler-load-decl-list-append prelude-decls entry-decls)
          (compiler-load-decl-path-list-append prelude-paths entry-paths)))]
    [(ErrCompilerLoadWithPaths diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ErrCompilerCheck diag))]))

(define (compiler-check-file-loaded-with-prelude
  [path : String]
  [stdlib-roots : StringVec]
  [prelude : ResultCompilerLoadWithPaths]) : ResultCompilerCheck
  (match prelude
    [(OkCompilerLoadWithPaths prelude-decls prelude-paths _ prelude-seen)
      (compiler-check-loaded-with-prelude
        path
        prelude-decls
        prelude-paths
        (compiler-load-file-with-paths-and-roots path prelude-seen stdlib-roots))]
    [(ErrCompilerLoadWithPaths diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ErrCompilerCheck diag))]))

(define (compiler-check-file [path : String]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-file-loaded-with-prelude
      path
      (string-vec-new)
      (compiler-load-core-macro-prelude-with-roots
        (sym-i64-empty)
        (string-vec-new)))))

(define (compiler-check-file-with-roots
  [path : String]
  [stdlib-roots : StringVec]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-file-loaded-with-prelude
      path
      stdlib-roots
      (compiler-load-core-macro-prelude-with-roots (sym-i64-empty) stdlib-roots))))

(define (compiler-check-package-file-with-roots
  [path : String]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym-i64-empty)
      stdlib-roots
      manifest-dir
      deps
      (compiler-cfg-empty))
      [(OkCompilerLoadWithPaths prelude-decls prelude-paths _ prelude-seen)
        (compiler-check-loaded-with-prelude
          path
          prelude-decls
          prelude-paths
          (compiler-load-package-file-with-paths-and-roots
            path
            prelude-seen
            stdlib-roots
            manifest-dir
            deps))]
      [(ErrCompilerLoadWithPaths diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ErrCompilerCheck diag))])))

(define (compiler-check-source [path : String] [source : String]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-core-macro-prelude-with-roots
      (sym-i64-empty)
      (string-vec-new))
      [(OkCompilerLoadWithPaths prelude-decls prelude-paths _ prelude-seen)
        (compiler-check-loaded-with-prelude
          path
          prelude-decls
          prelude-paths
          (compiler-load-source-with-paths-and-roots
            path
            source
            prelude-seen
            (string-vec-new)))]
      [(ErrCompilerLoadWithPaths diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ErrCompilerCheck diag))])))

(define (compiler-check-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : StringVec]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-core-macro-prelude-with-roots
      (sym-i64-empty)
      stdlib-roots)
      [(OkCompilerLoadWithPaths prelude-decls prelude-paths _ prelude-seen)
        (compiler-check-loaded-with-prelude
          path
          prelude-decls
          prelude-paths
          (compiler-load-source-with-paths-and-roots
            path
            source
            prelude-seen
            stdlib-roots))]
      [(ErrCompilerLoadWithPaths diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ErrCompilerCheck diag))])))

(define (compiler-check-source-ok? [path : String] [source : String]) : bool
  (match (compiler-check-source path source)
    [(OkCompilerCheck _) true]
    [(ErrCompilerCheck _) false]))

(define (compiler-check-source-error-ok?
  [path : String]
  [source : String]
  [want : String]) : bool
  (match (compiler-check-source path source)
    [(OkCompilerCheck _) false]
    [(ErrCompilerCheck diag)
      (string-eq (compiler-diagnostic-message diag) want)]))

(define (compiler-check-virtual-import-source) : String
  "(import \"compiler_ast_types.tl\")
(import \"compiler_ast_types.tl\")
(define selected : AstType (AstTyI64))
(define (main) : i64
  (match selected [(AstTyI64) 42] [_ 0]))")

(define (compiler-check-export-source) : String
  "(export
  (value answer)
  (type Pair)
  (constructor Pair)
  (field Pair left)
  (variant Present))
(defstruct Pair (left i64))
(defenum Maybe (Present i64))
(define answer : i64 42)
(define (main) : i64 answer)")

(define (compiler-check-implicit-core-prelude-source) : String
  "(define (main) : i64
  (let
    [value : i64 0]
    (begin
      (when (and (> 5 3) (< 2 4) (= 1 1)) (set! value (+ value 10)))
      (unless (or false false false) (set! value (+ value 20)))
      value)))")

(define (compiler-check-runtime-stdlib-boundary-io-source) : String
  "(import \"stdlib/io.tl\")
(define (main [path : String]) : i64
  (begin
    (print-string \"\")
    (flush-stdout)
    (+ (string-length (read-file path))
       (file-open-status path 0))))")

(define (compiler-check-runtime-stdlib-boundary-env-source) : String
  "(import \"stdlib/env.tl\")
(define (main [name : String]) : i64
  (+ (if (env-var-exists? name) 1 0)
     (+ (string-length (env-var-value name))
        (string-length (env-path-separator)))))")

(define (compiler-check-runtime-stdlib-boundary-fs-source) : String
  "(import \"stdlib/fs.tl\")
(define (main [path : String]) : i64
  (+ (fs-process-id)
     (+ (fs-current-dir-status)
        (+ (string-length (fs-current-dir))
           (fs-file-size-status path)))))")

(define (compiler-check-runtime-stdlib-boundary-profile-source) : String
  "(import \"stdlib/profile.tl\")
(define (main) : i64
  (begin
    (profile-alloc-reset-peak)
    (+ (profile-now-ms)
       (+ (profile-alloc-total)
          (+ (profile-alloc-live) (profile-alloc-peak))))))")

(define (compiler-check-virtual-import-ok?) : bool
  (match (compiler-check-source
    "selfhost/virtual_entry.tl"
    (compiler-check-virtual-import-source))
    [(OkCompilerCheck summary) (> (compiler-typecheck-summary-score summary) 0)]
    [(ErrCompilerCheck _) false]))

(define (compiler-check-inline-layout-name-ok?
  [ctx : TcContext]
  [name : String]) : bool
  (match (tc-inline-aggregate-layout-finite-ok ctx name)
    [(OkTcUnit) true]
    [(ErrTcUnit _) false]))

(define (compiler-check-virtual-import-inline-layout-ok?) : bool
  (match (compiler-load-source-with-paths
    "selfhost/virtual_entry.tl"
    (compiler-check-virtual-import-source)
    (sym-i64-empty))
    [(OkCompilerLoadWithPaths decls _ _ _)
      (let
        [program : AstProgram (ast-program decls)]
        (match (build-compiler-symbols program)
          [(OkCompilerSymbols symbols)
            (match (build-compiler-registries program)
              [(OkCompilerRegistries registries)
                (let
                  [ctx : TcContext (TcContext program symbols registries "")]
                  (and
                    (compiler-check-inline-layout-name-ok? ctx "AstTypeList")
                    (and
                      (compiler-check-inline-layout-name-ok? ctx "AstExprList")
                      (and
                        (compiler-check-inline-layout-name-ok?
                          ctx
                          "AstPatternList")
                        (and
                          (compiler-check-inline-layout-name-ok?
                            ctx
                            "AstDeclList")
                          (and
                            (compiler-check-inline-layout-name-ok?
                              ctx
                              "AstParamList")
                            (compiler-check-inline-layout-name-ok?
                              ctx
                              "AstVariantDefList")))))))]
              [(ErrCompilerRegistries _) false])]
          [(ErrCompilerSymbols _) false]))]
    [(ErrCompilerLoadWithPaths _) false]))

(define (compiler-check-export-ok?) : bool
  (match (compiler-check-source
    "selfhost/export_entry.tl"
    (compiler-check-export-source))
    [(OkCompilerCheck summary) (> (compiler-typecheck-summary-score summary) 0)]
    [(ErrCompilerCheck _) false]))

(define (compiler-check-virtual-error-ok?) : bool
  (match (compiler-check-source
    "docs/examples/bad_type.tl"
    "(define (main) : i64 true)")
    [(OkCompilerCheck _) false]
    [(ErrCompilerCheck diag)
      (if (string-eq
        (compiler-diagnostic-path diag)
        "docs/examples/bad_type.tl")
        (if (= (compiler-diagnostic-line diag) 1)
          (string-eq
            (compiler-diagnostic-message diag)
            "typecheck: return type mismatch")
          false)
        false)]))

(define (compiler-check-runtime-stdlib-boundary-no-import-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_io.tl"
        "(define (main) : i64 (begin (flush-stdout) 0))"
        "typecheck: unbound name flush-stdout")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_file.tl"
        "(define (main [path : String]) : String (read-file path))"
        "typecheck: unbound name read-file")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_env.tl"
        "(define (main [name : String]) : String (env-var-value name))"
        "typecheck: unbound name env-var-value")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_fs.tl"
        "(define (main) : String (fs-current-dir))"
        "typecheck: unbound name fs-current-dir")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_profile.tl"
        "(define (main) : i64 (profile-now-ms))"
        "typecheck: unbound name profile-now-ms")
        unit
        (set! ok false))
      ok)))

(define (compiler-check-runtime-stdlib-boundary-import-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-check-source-ok?
        "tests/runtime_boundary_io.tl"
        (compiler-check-runtime-stdlib-boundary-io-source))
        unit
        (set! ok false))
      (if (compiler-check-source-ok?
        "tests/runtime_boundary_env.tl"
        (compiler-check-runtime-stdlib-boundary-env-source))
        unit
        (set! ok false))
      (if (compiler-check-source-ok?
        "tests/runtime_boundary_fs.tl"
        (compiler-check-runtime-stdlib-boundary-fs-source))
        unit
        (set! ok false))
      (if (compiler-check-source-ok?
        "tests/runtime_boundary_profile.tl"
        (compiler-check-runtime-stdlib-boundary-profile-source))
        unit
        (set! ok false))
      ok)))

(define (compiler-check-runtime-stdlib-boundary-ok?) : bool
  (and
    (compiler-check-runtime-stdlib-boundary-no-import-ok?)
    (compiler-check-runtime-stdlib-boundary-import-ok?)))

(define (compiler-check-implicit-core-prelude-ok?) : bool
  (compiler-check-source-ok?
    "tests/implicit_core_prelude_check.tl"
    (compiler-check-implicit-core-prelude-source)))

(define (compiler-check-seen-root-ok?) : bool
  (match (compiler-load-source
    "selfhost/already_loaded.tl"
    "(define answer : i64 1)"
    (sym-i64-bind (sym-i64-empty) "selfhost/already_loaded.tl" 1))
    [(OkCompilerLoad decls _)
      (match decls
        [(AstDeclNil) true]
        [_ false])]
    [(ErrCompilerLoad _) false]))

(define (compiler-check-pool-reset-ok?) : bool
  (let
    [source : String "(define (main) : i64 0)"]
    (begin
      (ty-node-pool-reset!)
      (match (compiler-check-source "tests/pool_reset_a.tl" source)
        [(OkCompilerCheck _)
          (let
            [first-len : i64 (ty-node-pool-len)]
            (match (compiler-check-source "tests/pool_reset_b.tl" source)
              [(OkCompilerCheck _)
                (let
                  [second-len : i64 (ty-node-pool-len)]
                  (and (> first-len 0) (= first-len second-len)))]
              [(ErrCompilerCheck _) false]))]
        [(ErrCompilerCheck _) false]))))

(define (compiler-check-self-test) : i64
  (begin
    (unless
      (= (compiler-load-self-test) 42)
      (return
        (begin
          (panic "compiler-check: loader smoke mismatch")
          0)))
    (unless
      (compiler-check-virtual-import-ok?)
      (return
        (begin
          (panic "compiler-check: virtual import smoke mismatch")
          0)))
    (unless
      (compiler-check-virtual-import-inline-layout-ok?)
      (return
        (begin
          (panic "compiler-check: virtual import inline layout smoke mismatch")
          0)))
    (unless
      (compiler-check-export-ok?)
      (return
        (begin
          (panic "compiler-check: export smoke mismatch")
          0)))
    (unless
      (compiler-check-virtual-error-ok?)
      (return
        (begin
          (panic "compiler-check: virtual diagnostic smoke mismatch")
          0)))
    (unless
      (compiler-check-runtime-stdlib-boundary-ok?)
      (return
        (begin
          (panic "compiler-check: runtime stdlib boundary smoke mismatch")
          0)))
    (unless
      (compiler-check-implicit-core-prelude-ok?)
      (return
        (begin
          (panic "compiler-check: implicit core prelude smoke mismatch")
          0)))
    (unless
      (compiler-check-seen-root-ok?)
      (return
        (begin
          (panic "compiler-check: seen root smoke mismatch")
          0)))
    (unless
      (compiler-check-pool-reset-ok?)
      (return
        (begin
          (panic "compiler-check: pool reset smoke mismatch")
          0)))
    42))