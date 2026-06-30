;; compiler_check_core.tl - Shared selfhost check/typecheck helpers (#723).
(import stdlib.io)
(import stdlib.string)
(cfg compile-profile (import stdlib.profile))
(import "compiler_load.tl")
(import "compiler_typecheck.tl")
(import sym_i64_env)

(defenum ResultCompilerCheck
  (Ok CompilerTypecheckSummary)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCompilerCheckWithPaths
  (Ok CompilerTypecheckSummary AstDeclPathList)
  (Err (Box CompilerDiagnostic)))

(cfg
  compile-profile
  (define compiler-check-profile-start-ms : i64
    0))

(cfg
  compile-profile
  (define (compiler-check-profile-start) : unit
    (set! compiler-check-profile-start-ms (profile.now-ms))))

(cfg
  compile-profile
  (define (compiler-check-profile-finish [phase : String]) : unit
    (io.print-error
      (string.append
        "compile-profile|check."
        (string.append
          phase
          (string.append
            "|"
            (string.append
              (string.int->string
                (- (profile.now-ms) compiler-check-profile-start-ms))
              "|0|0|0\n")))))))

(define (compiler-check-language-cfgs) : sym_i64_env.SymI64Env
  (compiler-cfg-enable
    (compiler-cfg-enable
      (compiler-cfg-enable
        (compiler-cfg-enable
          (compiler-cfg-enable
            (compiler-cfg-enable
              (compiler-cfg-enable
                (compiler-cfg-enable (compiler-cfg-empty) "feature-ptr-addr-of")
                "feature-str-view")
              "feature-private-string-intrinsics")
            "feature-compiler-private-string-intrinsics")
          "array-helper-intrinsics")
        "feature-tl-memchr")
      "feature-plain-comptime-well-known")
    "feature-comptime-public-fields"))

(define (compiler-check-diagnostic-with-fallback-path
  [diag : CompilerDiagnostic]
  [path : String]) : CompilerDiagnostic
  (if (string.eq (compiler-diagnostic-path diag) "")
    (compiler-diagnostic-with-path diag path)
    diag))

(define (compiler-check-reset-pools!) : unit
  (compiler-load-session-reset-pools!))

(define (compiler-check-program-with-paths-cache
  [path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [stdlib-roots : vector.StringVec]
  [cache-scope : String]) : ResultCompilerCheck
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (typecheck-compiler-program-with-paths-cache
      (ast-program decls)
      paths
      stdlib-roots
      cache-scope)
      [(ResultCompilerTypecheck.Ok summary)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheck.Ok summary))]
      [(ResultCompilerTypecheck.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheck.Err
            (box
              (compiler-check-diagnostic-with-fallback-path (box-get diag) path))))])))

(define (compiler-check-program-with-paths
  [path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultCompilerCheck
  (compiler-check-program-with-paths-cache
    path
    decls
    paths
    (vector.string-vec-new)
    (tc-prefix-default-cache-scope)))

(define (compiler-check-program [path : String] [decls : AstDeclList]) : ResultCompilerCheck
  (compiler-check-program-with-paths path decls AstDeclPathList.Nil))

(define (compiler-check-loaded-with-prelude-cache
  [path : String]
  [prelude-decls : AstDeclList]
  [prelude-paths : AstDeclPathList]
  [loaded : ResultCompilerLoadWithPaths]
  [stdlib-roots : vector.StringVec]
  [cache-scope : String]) : ResultCompilerCheck
  (match loaded
    [(ResultCompilerLoadWithPaths.Ok entry-decls entry-paths _ _)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (compiler-check-program-with-paths-cache
          path
          (compiler-load-decl-list-append prelude-decls entry-decls)
          (compiler-load-decl-path-list-append prelude-paths entry-paths)
          stdlib-roots
          cache-scope))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err diag))]))

(define (compiler-check-loaded-cache-with-paths
  [path : String]
  [loaded : ResultCompilerLoadWithPaths]
  [stdlib-roots : vector.StringVec]
  [cache-scope : String]) : ResultCompilerCheckWithPaths
  (match loaded
    [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (match (compiler-check-program-with-paths-cache
          path
          decls
          paths
          stdlib-roots
          cache-scope)
          [(ResultCompilerCheck.Ok summary)
            (ResultCompilerCheckWithPaths.Ok summary paths)]
          [(ResultCompilerCheck.Err diag)
            (ResultCompilerCheckWithPaths.Err diag)]))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheckWithPaths.Err diag))]))

(define (compiler-check-loaded-with-prelude
  [path : String]
  [prelude-decls : AstDeclList]
  [prelude-paths : AstDeclPathList]
  [loaded : ResultCompilerLoadWithPaths]) : ResultCompilerCheck
  (compiler-check-loaded-with-prelude-cache
    path
    prelude-decls
    prelude-paths
    loaded
    (vector.string-vec-new)
    (tc-prefix-default-cache-scope)))

(define (compiler-check-file-loaded-with-prelude
  [path : String]
  [stdlib-roots : vector.StringVec]
  [prelude : ResultCompilerLoadWithPaths]) : ResultCompilerCheck
  (match prelude
    [(ResultCompilerLoadWithPaths.Ok prelude-decls prelude-paths _ prelude-seen)
      (compiler-check-loaded-with-prelude-cache
        path
        prelude-decls
        prelude-paths
        (compiler-load-file-with-paths-and-roots-cfg
          path
          prelude-seen
          stdlib-roots
          (compiler-check-language-cfgs))
        stdlib-roots
        (compiler-typecheck-prefix-cache-scope
          "typecheck-prefix-check"
          stdlib-roots
          (compiler-check-language-cfgs)))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err diag))]))

(define (compiler-check-file [path : String]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-file-loaded-with-prelude
      path
      (vector.string-vec-new)
      (compiler-load-core-macro-prelude-with-roots-cfg
        (sym_i64_env.sym-i64-empty)
        (vector.string-vec-new)
        (compiler-check-language-cfgs)))))

(define (compiler-check-file-with-roots
  [path : String]
  [stdlib-roots : vector.StringVec]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-file-loaded-with-prelude
      path
      stdlib-roots
      (compiler-load-core-macro-prelude-with-roots-cfg
        (sym_i64_env.sym-i64-empty)
        stdlib-roots
        (compiler-check-language-cfgs)))))

(define (compiler-check-package-file-with-roots
  [path : String]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      manifest-dir
      deps
      (compiler-check-language-cfgs))
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          _
          prelude-seen)
        (compiler-check-loaded-with-prelude-cache
          path
          prelude-decls
          prelude-paths
          (compiler-load-package-file-with-paths-and-roots-cfg
            path
            prelude-seen
            stdlib-roots
            manifest-dir
            deps
            (compiler-check-language-cfgs))
          stdlib-roots
          (compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-check"
            stdlib-roots
            (compiler-check-language-cfgs)))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err diag))])))

(define (compiler-check-package-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      manifest-dir
      deps
      (compiler-check-language-cfgs))
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          _
          prelude-seen)
        (match (compiler-load-parse-source-diagnostic-escaping
          path
          source
          (compiler-check-language-cfgs))
          [(ResultAstProgramDiagnostic.Ok program)
            (compiler-check-loaded-with-prelude-cache
              path
              prelude-decls
              prelude-paths
              (compiler-load-package-program-with-paths-and-roots-expect
                path
                program
                prelude-seen
                stdlib-roots
                AstMaybeModuleName.No
                manifest-dir
                deps
                (compiler-check-language-cfgs))
              stdlib-roots
              (compiler-typecheck-prefix-cache-scope
                "typecheck-prefix-check"
                stdlib-roots
                (compiler-check-language-cfgs)))]
          [(ResultAstProgramDiagnostic.Err diag)
            (begin
              (cfg compile-profile (compiler-check-profile-finish "load"))
              (ResultCompilerCheck.Err diag))])]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err diag))])))

(define (compiler-check-package-entry-file-with-roots
  [path : String]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]) : ResultCompilerCheckWithPaths
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-loaded-cache-with-paths
      path
      (compiler-load-package-file-with-runtime-cfg
        path
        stdlib-roots
        manifest-dir
        deps
        emit-entry
        (compiler-check-language-cfgs))
      stdlib-roots
      (compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-check"
        stdlib-roots
        (compiler-check-language-cfgs)))))

(define (compiler-check-source [path : String] [source : String]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (vector.string-vec-new)
      (compiler-check-language-cfgs))
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          _
          prelude-seen)
        (compiler-check-loaded-with-prelude-cache
          path
          prelude-decls
          prelude-paths
          (compiler-load-source-with-paths-and-roots-cfg
            path
            source
            prelude-seen
            (vector.string-vec-new)
            (compiler-check-language-cfgs))
          (vector.string-vec-new)
          (compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-check"
            (vector.string-vec-new)
            (compiler-check-language-cfgs)))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err diag))])))

(define (compiler-check-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : vector.StringVec]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      (compiler-check-language-cfgs))
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          _
          prelude-seen)
        (compiler-check-loaded-with-prelude-cache
          path
          prelude-decls
          prelude-paths
          (compiler-load-source-with-paths-and-roots-cfg
            path
            source
            prelude-seen
            stdlib-roots
            (compiler-check-language-cfgs))
          stdlib-roots
          (compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-check"
            stdlib-roots
            (compiler-check-language-cfgs)))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err diag))])))

(define (compiler-check-source-ok? [path : String] [source : String]) : bool
  (match (compiler-check-source path source)
    [(ResultCompilerCheck.Ok _) true]
    [(ResultCompilerCheck.Err _) false]))

(define (compiler-check-source-error-ok?
  [path : String]
  [source : String]
  [want : String]) : bool
  (match (compiler-check-source path source)
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diag)
      (string.eq (compiler-diagnostic-message (box-get diag)) want)]))

(define (compiler-check-virtual-import-source) : String
  "(import \"compiler_ast_types.tl\")
(import \"compiler_ast_types.tl\")
(define selected : AstType (AstTyI64))
(define (main) : i64
  (match selected [(AstTyI64) 42] [_ 0]))")

(define (compiler-check-export-source) : String
  "(defstruct Pair (left i64))
(defenum Maybe (Present i64))
(define answer : i64 42)
(define (main) : i64 answer)")

(define (compiler-check-direct-source [path : String] [source : String]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (match (compiler-load-parse-source-diagnostic-escaping
      path
      source
      (compiler-check-language-cfgs))
      [(ResultAstProgramDiagnostic.Ok program)
        (match program
          [(AstProgram.Program decls-box)
            (compiler-check-program-with-paths-cache
              path
              (box-get decls-box)
              AstDeclPathList.Nil
              (vector.string-vec-new)
              (compiler-typecheck-prefix-cache-scope
                "typecheck-prefix-check"
                (vector.string-vec-new)
                (compiler-check-language-cfgs)))])]
      [(ResultAstProgramDiagnostic.Err diag) (ResultCompilerCheck.Err diag)])))

(define (compiler-check-direct-source-ok? [path : String] [source : String]) : bool
  (match (compiler-check-direct-source path source)
    [(ResultCompilerCheck.Ok _) true]
    [(ResultCompilerCheck.Err _) false]))

(define (compiler-check-direct-source-error-ok?
  [path : String]
  [source : String]
  [want : String]) : bool
  (match (compiler-check-direct-source path source)
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diag)
      (string.eq (compiler-diagnostic-message (box-get diag)) want)]))

(define (compiler-check-qualified-export-cache-exported-source) : String
  "(module a)
(define x : i64 1)
(module b)
(import a)
(define (main) : i64 a.x)")

(define (compiler-check-qualified-export-cache-private-source) : String
  "(module a)
(define x : i64 1)
(module b)
(import a)
(define (main) : i64 a.x)")

(define (compiler-check-implicit-core-prelude-source) : String
  "(import \"stdlib/array.tl\" module stdlib.array as arr)
(define (main) : i64
  (let
    [value : i64 0]
    [items : (Array i64) (arr.make-array i64 1)]
    (begin
      (when (and (> 5 3) (< 2 4) (= 1 1)) (set! value (+ value 10)))
      (unless (or false false false) (set! value (+ value 20)))
      (array-set! items 0 value)
      (arr.push! items 2)
      (+
        (arr.length items)
        (+ (arr.ref items 0) (arr.ref items 1))))))")

(define (compiler-check-runtime-stdlib-boundary-io-source) : String
  "(import stdlib.io)
(import stdlib.string)
(define (main [path : String]) : i64
  (begin
    (io.print-string \"\")
    (io.flush-stdout)
    (+ (string.string-length (io.read-file path))
       (io.file-open-status path 0))))")

(define (compiler-check-runtime-stdlib-boundary-env-source) : String
  "(import stdlib.env)
(import stdlib.string)
(define (main [name : String]) : i64
  (+ (if (env.var-exists? name) 1 0)
     (+ (string.string-length (env.var-value name))
        (string.string-length (env.path-separator)))))")

(define (compiler-check-runtime-stdlib-boundary-fs-source) : String
  "(import stdlib.fs)
(import stdlib.string)
(define (main [path : String]) : i64
  (+ (fs.process-id)
     (+ (fs.current-dir-status)
        (+ (string.string-length (fs.current-dir))
           (fs.file-size-status path)))))")

(define (compiler-check-runtime-stdlib-boundary-profile-source) : String
  "(import stdlib.profile)
(define (main) : i64
  (begin
    (profile.alloc-reset-peak)
    (+ (profile.now-ms)
       (+ (profile.alloc-total)
          (+ (profile.alloc-live) (profile.alloc-peak))))))")

(define (compiler-check-private-dynamic-buffer-vector-source) : String
  "(import stdlib.vector)
(import (vector.vector i64) as i64vec)
(define (main) : i64
  (let
    [items : i64vec.Vec (i64vec.with-capacity 2)]
    (begin
      (i64vec.push (&mut items) 41)
      (i64vec.push (&mut items) 1)
      (i64vec.len (& items)))))")

;; Compatibility alias fixture for #3772. The qualified stdlib.array path is
;; covered by compiler-check-implicit-core-prelude-source above.
(define (compiler-check-private-dynamic-buffer-public-source) : String
  "(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (array-length items)))")

(define (compiler-check-virtual-import-ok?) : bool
  (match (compiler-check-source
    "src/virtual_entry.tl"
    (compiler-check-virtual-import-source))
    [(ResultCompilerCheck.Ok summary)
      (> (compiler-typecheck-summary-score summary) 0)]
    [(ResultCompilerCheck.Err _) false]))

(define (compiler-check-inline-layout-name-ok?
  [ctx : TcContext]
  [name : String]) : bool
  (match (tc-inline-aggregate-layout-finite-ok ctx name)
    [(ResultTcUnit.Ok) true]
    [(ResultTcUnit.Err _) false]))

(define (compiler-check-virtual-import-inline-layout-ok?) : bool
  (match (compiler-load-source-with-paths
    "src/virtual_entry.tl"
    (compiler-check-virtual-import-source)
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
      (let
        [program : AstProgram (ast-program decls)]
        (match (build-compiler-symbols program)
          [(ResultCompilerSymbols.Ok symbols)
            (match (build-compiler-registries program)
              [(ResultCompilerRegistries.Ok registries)
                (let
                  [ctx : TcContext
                    (TcContext
                      program
                      symbols
                      registries
                      ""
                      (ast-node-pool-context-capture-active))]
                  (and
                    (compiler-check-inline-layout-name-ok? ctx "AstTypeList")
                    (compiler-check-inline-layout-name-ok? ctx "AstExprList")
                    (compiler-check-inline-layout-name-ok? ctx "AstPatternList")
                    (compiler-check-inline-layout-name-ok? ctx "AstDeclList")
                    (compiler-check-inline-layout-name-ok? ctx "AstParamList")
                    (compiler-check-inline-layout-name-ok?
                      ctx
                      "AstVariantDefList")))]
              [(ResultCompilerRegistries.Err _) false])]
          [(ResultCompilerSymbols.Err _) false]))]
    [(ResultCompilerLoadWithPaths.Err _) false]))

(define (compiler-check-export-ok?) : bool
  (match (compiler-check-source
    "src/export_entry.tl"
    (compiler-check-export-source))
    [(ResultCompilerCheck.Ok summary)
      (> (compiler-typecheck-summary-score summary) 0)]
    [(ResultCompilerCheck.Err _) false]))

(define (compiler-check-qualified-export-cache-reset-ok?) : bool
  (and
    (compiler-check-direct-source-ok?
      "tests/qualified_export_cache_exported.tl"
      (compiler-check-qualified-export-cache-exported-source))
    ;; There is no export list: values are reachable across modules through the
    ;; module symbol table, so this previously-private access type-checks.
    (compiler-check-direct-source-ok?
      "tests/qualified_export_cache_private.tl"
      (compiler-check-qualified-export-cache-private-source))))

(define (compiler-check-virtual-error-ok?) : bool
  (match (compiler-check-source
    "docs/examples/bad_type.tl"
    "(define (main) : i64 true)")
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diag)
      (if (string.eq
        (compiler-diagnostic-path (box-get diag))
        "docs/examples/bad_type.tl")
        (if (= (compiler-diagnostic-line (box-get diag)) 1)
          (string.eq
            (compiler-diagnostic-message (box-get diag))
            "typecheck: return type mismatch")
          false)
        false)]))

(define (compiler-check-runtime-stdlib-boundary-no-import-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_tl"
        "(define (main) : i64 (begin (flush-stdout) 0))"
        "typecheck: unbound name flush-stdout")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_file.tl"
        "(define (main [path : String]) : String (io.read-file path))"
        "typecheck: unknown qualified name io.read-file; import the module or use a visible dotted module alias")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_env.tl"
        "(define (main [name : String]) : String (var-value name))"
        "typecheck: unbound name var-value")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_fs.tl"
        "(define (main) : String (current-dir))"
        "typecheck: unbound name current-dir")
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
        "tests/runtime_boundary_tl"
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

(define (compiler-check-private-dynamic-buffer-vector-ok?) : bool
  (compiler-check-source-ok?
    "tests/private_dynamic_buffer_vector.tl"
    (compiler-check-private-dynamic-buffer-vector-source)))

(define (compiler-check-private-dynamic-buffer-public-rejected-ok?) : bool
  (compiler-check-source-error-ok?
    "tests/private_dynamic_buffer_public.tl"
    (compiler-check-private-dynamic-buffer-public-source)
    "parse: unknown type constructor __tl_dyn-array; TypeLisp has no source-level generic type constructors; use comptime-decl and comptime-generated concrete declarations instead (#893/#913/#970/#902)"))

(define (compiler-check-implicit-core-prelude-ok?) : bool
  (compiler-check-source-ok?
    "tests/implicit_core_prelude_check.tl"
    (compiler-check-implicit-core-prelude-source)))

(define (compiler-check-seen-root-ok?) : bool
  (match (compiler-load-source
    "src/already_loaded.tl"
    "(define answer : i64 1)"
    (sym_i64_env.sym-i64-bind
      (sym_i64_env.sym-i64-empty)
      "src.already_loaded"
      1))
    [(ResultCompilerLoad.Ok decls _)
      (match decls
        [(AstDeclList.Nil) true]
        [_ false])]
    [(ResultCompilerLoad.Err _) false]))

(define (compiler-check-pool-reset-ok?) : bool
  (let
    [source : String "(define (main) : i64 0)"]
    (begin
      (ty-node-pool-reset!)
      (match (compiler-check-source "tests/pool_reset_a.tl" source)
        [(ResultCompilerCheck.Ok _)
          (let
            [first-len : i64 (ty-node-pool-len)]
            (match (compiler-check-source "tests/pool_reset_b.tl" source)
              [(ResultCompilerCheck.Ok _)
                (let
                  [second-len : i64 (ty-node-pool-len)]
                  (and (> first-len 0) (= first-len second-len)))]
              [(ResultCompilerCheck.Err _) false]))]
        [(ResultCompilerCheck.Err _) false]))))

(define (compiler-check-self-test) : i64
  (begin
    (unless
      (= (compiler-load-self-test) 42)
      (return (io.panic "compiler-check: loader smoke mismatch")))
    (unless
      (compiler-check-virtual-import-ok?)
      (return (io.panic "compiler-check: virtual import smoke mismatch")))
    (unless
      (compiler-check-virtual-import-inline-layout-ok?)
      (return
        (io.panic "compiler-check: virtual import inline layout smoke mismatch")))
    (unless
      (compiler-check-export-ok?)
      (return (io.panic "compiler-check: export smoke mismatch")))
    (unless
      (compiler-check-qualified-export-cache-reset-ok?)
      (return
        (io.panic "compiler-check: qualified export cache reset smoke mismatch")))
    (unless
      (compiler-check-virtual-error-ok?)
      (return (io.panic "compiler-check: virtual diagnostic smoke mismatch")))
    (unless
      (compiler-check-runtime-stdlib-boundary-ok?)
      (return
        (io.panic "compiler-check: runtime stdlib boundary smoke mismatch")))
    (unless
      (compiler-check-private-dynamic-buffer-vector-ok?)
      (return
        (io.panic
          "compiler-check: private dynamic-buffer vector smoke mismatch")))
    (unless
      (compiler-check-private-dynamic-buffer-public-rejected-ok?)
      (return
        (io.panic
          "compiler-check: private dynamic-buffer public smoke mismatch")))
    (unless
      (compiler-check-implicit-core-prelude-ok?)
      (return (io.panic "compiler-check: implicit core prelude smoke mismatch")))
    (unless
      (compiler-check-seen-root-ok?)
      (return (io.panic "compiler-check: seen root smoke mismatch")))
    (unless
      (compiler-check-pool-reset-ok?)
      (return (io.panic "compiler-check: pool reset smoke mismatch")))
    42))