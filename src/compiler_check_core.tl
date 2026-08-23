;; compiler_check_core.tl - Shared selfhost check/typecheck helpers.
(cfg compile-profile (import stdlib.str_cat_runtime as str_cat))
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(cfg compile-profile (import stdlib.profile))
(import compiler_load)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_cfg_core as cfg_core)
(import compiler_diagnostic as cdiag)
(import compiler_symbols as csym)
(import compiler_typecheck_api)
(import compiler_typecheck_core as tc)
(import compiler_builtin_ids as cbi)
(import compiler_target_cfg_core as target_cfg)
(import sym_i64_env)

(defenum ResultCompilerCheck
  (Ok tc.CompilerTypecheckSummary)
  (Err (Box cdiag.CompilerDiagnosticList)))

(defenum ResultCompilerCheckWithPaths
  (Ok tc.CompilerTypecheckSummary ast.AstDeclPathList)
  (Err (Box cdiag.CompilerDiagnosticList)))

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
      (str_cat.str-cat
        "compile-profile|check."
        phase
        "|"
        (string.int->string
          (- (profile.now-ms) compiler-check-profile-start-ms))
        "|0|0|0\n"))))

(define (compiler-check-language-cfgs) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-cfgs
    target_cfg.CompilerTargetCfg.Linux
    (cfg_core.compiler-cfg-empty)))

(define (compiler-check-diagnostic-with-fallback-path
  [diag : cdiag.CompilerDiagnostic]
  [path : String]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-with-fallback-path diag path))

(define (compiler-check-diagnostics-with-fallback-path
  [diagnostics : cdiag.CompilerDiagnosticList]
  [path : String]) : cdiag.CompilerDiagnosticList
  (let
    [count : i64 (cdiag.compiler-diagnostic-list-count diagnostics)]
    [index : i64 0]
    [out : cdiag.CompilerDiagnosticList
      (cdiag.compiler-diagnostic-list-with-capacity count)]
    (begin
      (while (< index count)
        (begin
          (cdiag.compiler-diagnostic-list-push!
            (&mut out)
            (compiler-check-diagnostic-with-fallback-path
              (cdiag.compiler-diagnostic-list-get diagnostics index)
              path))
          (set! index (+ index 1))))
      out)))

(define (compiler-check-diagnostic-before?
  [left : (& left cdiag.CompilerDiagnostic)]
  [right : (& right cdiag.CompilerDiagnostic)]) : bool
  (let
    [left-primary : (& left cdiag.CompilerDiagnosticSpan) (& left.primary)]
    [right-primary : (& right cdiag.CompilerDiagnosticSpan) (& right.primary)]
    (if (string.eq (& left-primary.path) (& right-primary.path))
      (let
        [left-line : i64 left-primary.start-line]
        [right-line : i64 right-primary.start-line]
        (or
          (< left-line right-line)
          (and
            (= left-line right-line)
            (< left-primary.start-col right-primary.start-col))))
      false)))

(define (compiler-check-diagnostic-list-insert-source-order
  [diag : cdiag.CompilerDiagnostic]
  [sorted : (&mut sorted cdiag.CompilerDiagnosticList)]) : unit
  (let
    [count : i64 sorted.len]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (if (compiler-check-diagnostic-before?
          (& diag)
          (cdiag.compiler-diagnostic-list-ref sorted index))
          (set! found true)
          (set! index (+ index 1))))
      (cdiag.compiler-diagnostic-list-insert! sorted index diag))))

(define (compiler-check-diagnostic-list-insert-all-source-order
  [incoming : cdiag.CompilerDiagnosticList]
  [sorted : (&mut sorted cdiag.CompilerDiagnosticList)]) : unit
  (let
    [count : i64 (cdiag.compiler-diagnostic-list-count incoming)]
    [index : i64 0]
    (while (< index count)
      (begin
        (compiler-check-diagnostic-list-insert-source-order
          (cdiag.compiler-diagnostic-list-get incoming index)
          sorted)
        (set! index (+ index 1))))))

(define (compiler-check-result-with-parse-diagnostics
  [parse-diagnostics : cdiag.CompilerDiagnosticList]
  [result : ResultCompilerCheck]) : ResultCompilerCheck
  (if (= (cdiag.compiler-diagnostic-list-count parse-diagnostics) 0)
    result
    (let
      [count : i64 (cdiag.compiler-diagnostic-list-count parse-diagnostics)]
      [index : i64 0]
      [owned-parse : cdiag.CompilerDiagnosticList
        (cdiag.compiler-diagnostic-list-with-capacity count)]
      (begin
        (while (< index count)
          (begin
            (cdiag.compiler-diagnostic-list-push!
              (&mut owned-parse)
              (cdiag.compiler-diagnostic-list-get parse-diagnostics index))
            (set! index (+ index 1))))
        (match result
          [(ResultCompilerCheck.Ok _)
            (ResultCompilerCheck.Err (box owned-parse))]
          [(ResultCompilerCheck.Err semantic-diagnostics)
            (begin
              (compiler-check-diagnostic-list-insert-all-source-order
                (__tl-box-place semantic-diagnostics)
                (&mut owned-parse))
              (ResultCompilerCheck.Err (box owned-parse)))])))))

(define (compiler-check-reset-pools!) : unit
  (compiler_load.compiler-load-session-reset-pools!))

(define (compiler-check-reset-interns!) : unit
  (begin
    (compiler_load.compiler-load-session-reset-interns!)
    (tc.compiler-typecheck-reset-intern-owned-state!)))

(define (compiler-check-program-with-paths-cache-and-job-state
  [path : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler_typecheck_api.typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools
      (compiler_load.compiler-load-serial-test-session-state)
      (tc.tc-prefix-snapshot-serial-test-cache-state-shared-view)
      job-state
      (ast.ast-program decls)
      paths
      stdlib-roots
      cache-scope
      (ast.ast-node-pool-context-capture-active))
      [(tc.ResultCompilerTypecheck.Ok summary)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheck.Ok summary))]
      [(tc.ResultCompilerTypecheck.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheck.Err
            (box
              (compiler-check-diagnostics-with-fallback-path
                (__tl-box-place diag)
                path))))])))

(define (compiler-check-program-with-paths-cache
  [path : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : ResultCompilerCheck
  (compiler-check-program-with-paths-cache-and-job-state
    path
    decls
    paths
    stdlib-roots
    cache-scope
    (tc.tc-serial-job-state)))

(define (compiler-check-loaded-with-prelude-cache-and-job-state
  [path : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [loaded : compiler_load.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (match loaded
    [(compiler_load.ResultCompilerLoadWithPaths.Ok
        entry-decls
        entry-paths
        entry-modules
        _)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (compiler-check-program-with-paths-cache-and-job-state
          path
          (compiler_load.compiler-load-decl-list-append
            prelude-decls
            entry-decls)
          (compiler_load.compiler-load-decl-path-list-append
            prelude-paths
            (ast.ast-decl-path-list-with-modules entry-paths entry-modules))
          stdlib-roots
          cache-scope
          job-state))]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err
          (cdiag.compiler-diagnostic-list-box-single diag)))]))

(define (compiler-check-loaded-with-prelude-cache
  [path : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [loaded : compiler_load.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : ResultCompilerCheck
  (compiler-check-loaded-with-prelude-cache-and-job-state
    path
    prelude-decls
    prelude-paths
    loaded
    stdlib-roots
    cache-scope
    (tc.tc-serial-job-state)))

(define (compiler-check-source-with-prelude-recovery
  [path : String]
  [source : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [prelude-seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (match (parser.parse-ast-source-recovery-diagnostic-with-cfg path source cfgs)
    [(parser.ResultAstProgramRecovery.Fatal diagnostics)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err diagnostics))]
    [(parser.ResultAstProgramRecovery.Parsed program diagnostics)
      (let
        [parse-identity : compiler_load.CompilerLoadParseIdentity
          (compiler_load.compiler-load-parse-identity
            path
            (compiler_load.compiler-load-canonical-module-id-from-path path)
            ast.AstMaybeModuleName.No)]
        [loaded : compiler_load.ResultCompilerLoadWithPaths
          (compiler_load.compiler-load-program-with-paths-and-roots-expect-cfg
            path
            program
            prelude-seen
            stdlib-roots
            ast.AstMaybeModuleName.No
            cfgs
            parse-identity)]
        (compiler-check-result-with-parse-diagnostics
          (__tl-box-place diagnostics)
          (compiler-check-loaded-with-prelude-cache-and-job-state
            path
            prelude-decls
            prelude-paths
            loaded
            stdlib-roots
            cache-scope
            job-state)))]))

(define (compiler-check-loaded-cache-with-paths
  [path : String]
  [loaded : compiler_load.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : ResultCompilerCheckWithPaths
  (match loaded
    [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
      (let
        [owned-paths : ast.AstDeclPathList
          (ast.ast-decl-path-list-with-modules paths modules)]
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (match (compiler-check-program-with-paths-cache
            path
            decls
            owned-paths
            stdlib-roots
            cache-scope)
            [(ResultCompilerCheck.Ok summary)
              (ResultCompilerCheckWithPaths.Ok summary owned-paths)]
            [(ResultCompilerCheck.Err diag)
              (ResultCompilerCheckWithPaths.Err diag)])))]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheckWithPaths.Err
          (cdiag.compiler-diagnostic-list-box-single diag)))]))

(define (compiler-check-file-with-roots
  [path : String]
  [stdlib-roots : svec.Vec]) : ResultCompilerCheck
  (compiler-check-file-with-roots-and-cfg
    path
    stdlib-roots
    (compiler-check-language-cfgs)))

(define (compiler-check-file-with-roots-and-cfg
  [path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (compiler-check-source-with-roots-and-cfg
    path
    (compiler_load.compiler-load-read-file-text path)
    stdlib-roots
    cfgs))

(define (compiler-check-package-source-with-prelude-recovery
  [path : String]
  [source : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [prelude-seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (match (parser.parse-ast-source-recovery-diagnostic-with-cfg path source cfgs)
    [(parser.ResultAstProgramRecovery.Fatal diagnostics)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err diagnostics))]
    [(parser.ResultAstProgramRecovery.Parsed program diagnostics)
      (let
        [parse-identity : compiler_load.CompilerLoadParseIdentity
          (compiler_load.compiler-load-parse-identity
            path
            (compiler_load.compiler-load-canonical-module-id-from-path path)
            ast.AstMaybeModuleName.No)]
        [loaded : compiler_load.ResultCompilerLoadWithPaths
          (compiler_load.compiler-load-package-program-with-paths-and-roots-expect
            path
            program
            prelude-seen
            stdlib-roots
            ast.AstMaybeModuleName.No
            manifest-dir
            deps
            cfgs
            parse-identity)]
        (compiler-check-result-with-parse-diagnostics
          (__tl-box-place diagnostics)
          (compiler-check-loaded-with-prelude-cache
            path
            prelude-decls
            prelude-paths
            loaded
            stdlib-roots
            (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
              "typecheck-prefix-check"
              stdlib-roots
              cfgs))))]))

(define (compiler-check-package-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler_load.compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      manifest-dir
      deps
      cfgs)
      [(compiler_load.ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-package-source-with-prelude-recovery
          path
          source
          prelude-decls
          (ast.ast-decl-path-list-with-modules prelude-paths prelude-modules)
          prelude-seen
          stdlib-roots
          manifest-dir
          deps
          cfgs)]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err
            (cdiag.compiler-diagnostic-list-box-single diag)))])))

(define (compiler-check-package-entry-file-with-roots-and-cfg
  [path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheckWithPaths
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-loaded-cache-with-paths
      path
      (compiler_load.compiler-load-package-file-with-runtime-cfg
        path
        stdlib-roots
        manifest-dir
        deps
        emit-entry
        cfgs)
      stdlib-roots
      (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-check"
        stdlib-roots
        cfgs))))

(define (compiler-check-source [path : String] [source : String]) : ResultCompilerCheck
  (compiler-check-source-with-roots-and-cfg
    path
    source
    (svec.new)
    (compiler-check-language-cfgs)))

(define (compiler-check-source-with-roots-and-cfg-and-job-state
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler_load.compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      cfgs)
      [(compiler_load.ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-source-with-prelude-recovery
          path
          source
          prelude-decls
          (ast.ast-decl-path-list-with-modules prelude-paths prelude-modules)
          prelude-seen
          stdlib-roots
          cfgs
          (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-check"
            stdlib-roots
            cfgs)
          job-state)]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err
            (cdiag.compiler-diagnostic-list-box-single diag)))])))

(define (compiler-check-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (compiler-check-source-with-roots-and-cfg-and-job-state
    path
    source
    stdlib-roots
    cfgs
    (tc.tc-serial-job-state)))

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
      (string.eq
        (cdiag.compiler-diagnostic-message
          (cdiag.compiler-diagnostic-list-first (__tl-box-place diag)))
        want)]))

(define (compiler-check-virtual-import-source) : String
  "(import compiler_ast_types as ast)
(import compiler_ast_types as ast)
(define selected : ast.AstType (ast.AstType.I64))
(define (main) : i64
  (match (unsafe (ptr-read (ptr-addr-of selected)))
    [(ast.AstType.I64) 42]
    [_ 0]))")

(define (compiler-check-export-source) : String
  "(defstruct Pair (left i64))
(defenum Maybe (Present i64))
(define answer : i64 42)
(define (main) : i64 answer)")

(define (compiler-check-direct-source [path : String] [source : String]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (match (parser.parse-ast-source-recovery-diagnostic-with-cfg
      path
      source
      (compiler-check-language-cfgs))
      [(parser.ResultAstProgramRecovery.Parsed program diagnostics)
        (compiler-check-result-with-parse-diagnostics
          (__tl-box-place diagnostics)
          (match program
            [(ast.AstProgram.Program decls-box)
              (compiler-check-program-with-paths-cache
                path
                (__tl-box-place decls-box)
                (ast.ast-decl-path-list-new)
                (svec.new)
                (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
                  "typecheck-prefix-check"
                  (svec.new)
                  (compiler-check-language-cfgs)))]))]
      [(parser.ResultAstProgramRecovery.Fatal diagnostics)
        (ResultCompilerCheck.Err diagnostics)])))

(define (compiler-check-direct-source-ok? [path : String] [source : String]) : bool
  (match (compiler-check-direct-source path source)
    [(ResultCompilerCheck.Ok _) true]
    [(ResultCompilerCheck.Err _) false]))

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

;; The qualified stdlib.array macro remains until #3992, but its backing type
;; is compiler-private now that public Array is fixed-size only.
(define (compiler-check-implicit-core-prelude-source) : String
  "(import stdlib.array as arr)
(define (main) : i64
  (let
    [value : i64 0]
    [items : (__tl_dyn-array i64) (arr.make-array i64 1)]
    (begin
      (when (and (> 5 3) (< 2 4) (= 1 1)) (set! value (+ value 10)))
      (unless (or false false false) (set! value (+ value 20)))
      (set! (array-ref items 0) value)
      (arr.push! items 2)
      (+
        (arr.length items)
        (+ (arr.ref items 0) (arr.ref items 1))))))")

(define (compiler-check-runtime-stdlib-boundary-io-source) : String
  "(import stdlib.io)
(import stdlib.byte_buf)
(define (main [path : String]) : i64
  (begin
    (io.print-format \"{}\" \"\")
    (io.flush-stdout)
    (+ (byte_buf.len (io.read-file path))
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
(import (vector.vector String) as svec)
(import (vector.vector i64) as i64vec)
(define (main) : i64
  (let
    [items : i64vec.Vec (i64vec.with-capacity 2)]
    (begin
      (i64vec.push-ref! (&mut items) 41)
      (i64vec.push-ref! (&mut items) 1)
      (i64vec.len (& items)))))")

;; Private dynamic-buffer parser coverage. The qualified stdlib.array path is
;; covered by compiler-check-implicit-core-prelude-source above.
(define (compiler-check-private-dynamic-buffer-source) : String
  "(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (array-length items)))")

(define (compiler-check-virtual-import-ok?) : bool
  (match (compiler-check-source
    "src/virtual_entry.tl"
    (compiler-check-virtual-import-source))
    [(ResultCompilerCheck.Ok summary)
      (> (compiler_typecheck_api.compiler-typecheck-summary-score summary) 0)]
    [(ResultCompilerCheck.Err _) false]))

(define (compiler-check-inline-layout-name-ok?
  [ctx : tc.TcContext]
  [name : String]) : bool
  (match (compiler_typecheck_api.compiler-typecheck-context-program ctx)
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        [index : i64 0]
        [name-id : i64 -1]
        (begin
          (while (and (< name-id 0) (< index decls.len))
            (let
              [decl : ast.AstDecl
                (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))]
              (begin
                (match decl
                  [(ast.AstDecl.DefStruct decl-meta candidate _ _ _)
                    (if (string.eq (tc.tc-env-key-name-text candidate) name)
                      (set! name-id candidate)
                      unit)]
                  [(ast.AstDecl.DefStructLifetimes decl-meta candidate _ _ _ _)
                    (if (string.eq (tc.tc-env-key-name-text candidate) name)
                      (set! name-id candidate)
                      unit)]
                  [(ast.AstDecl.DefEnum decl-meta candidate _ _)
                    (if (string.eq (tc.tc-env-key-name-text candidate) name)
                      (set! name-id candidate)
                      unit)]
                  [(ast.AstDecl.DefEnumLifetimes decl-meta candidate _ _ _)
                    (if (string.eq (tc.tc-env-key-name-text candidate) name)
                      (set! name-id candidate)
                      unit)]
                  [_ unit])
                (set! index (+ index 1)))))
          (if (< name-id 0)
            false
            (match (tc.tc-inline-aggregate-layout-finite-ok ctx name name-id)
              [(tc.ResultTcUnit.Ok) true]
              [(tc.ResultTcUnit.Err _) false]))))]))

(define (compiler-check-virtual-import-inline-layout-ok?) : bool
  (match (compiler_load.compiler-load-source-with-paths
    "src/virtual_entry.tl"
    (compiler-check-virtual-import-source)
    (sym_i64_env.sym-i64-empty))
    [(compiler_load.ResultCompilerLoadWithPaths.Ok decls _ _ _)
      (let
        [program : ast.AstProgram (ast.ast-program decls)]
        (match (csym.build-compiler-symbols program)
          [(csym.ResultCompilerSymbols.Ok symbols)
            (match (csym.build-compiler-registries program)
              [(csym.ResultCompilerRegistries.Ok registries)
                (let
                  [ctx : tc.TcContext
                    (tc.tc-context-new
                      program
                      symbols
                      registries
                      ""
                      cbi.compiler-builtin-id-fix-empty
                      (ast.ast-node-pool-context-capture-active))]
                  (and
                    (compiler-check-inline-layout-name-ok? ctx "AstTypeList")
                    (compiler-check-inline-layout-name-ok? ctx "AstExprList")
                    (compiler-check-inline-layout-name-ok? ctx "AstPatternList")
                    (compiler-check-inline-layout-name-ok? ctx "AstDeclList")
                    (compiler-check-inline-layout-name-ok? ctx "AstParamList")
                    (compiler-check-inline-layout-name-ok?
                      ctx
                      "AstVariantDefList")))]
              [(csym.ResultCompilerRegistries.Err _) false])]
          [(csym.ResultCompilerSymbols.Err _) false]))]
    [(compiler_load.ResultCompilerLoadWithPaths.Err _) false]))

(define (compiler-check-export-ok?) : bool
  (match (compiler-check-source
    "src/export_entry.tl"
    (compiler-check-export-source))
    [(ResultCompilerCheck.Ok summary)
      (> (compiler_typecheck_api.compiler-typecheck-summary-score summary) 0)]
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
        (cdiag.compiler-diagnostic-path
          (cdiag.compiler-diagnostic-list-first (__tl-box-place diag)))
        "docs/examples/bad_type.tl")
        (if (=
          (cdiag.compiler-diagnostic-line
            (cdiag.compiler-diagnostic-list-first (__tl-box-place diag)))
          1)
          (string.eq
            (cdiag.compiler-diagnostic-message
              (cdiag.compiler-diagnostic-list-first (__tl-box-place diag)))
            "typecheck: return type mismatch: expected i64, found bool")
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

(define (compiler-check-private-dynamic-buffer-accepted-ok?) : bool
  (compiler-check-source-ok?
    "tests/private_dynamic_buffer_public.tl"
    (compiler-check-private-dynamic-buffer-source)))

(define (compiler-check-implicit-core-prelude-ok?) : bool
  (compiler-check-source-ok?
    "tests/implicit_core_prelude_check.tl"
    (compiler-check-implicit-core-prelude-source)))

(define (compiler-check-seen-root-ok?) : bool
  (let
    [path : String "src/already_loaded.tl"]
    [source : String "(define answer : i64 1)"]
    (match (compiler_load.compiler-load-source
      path
      source
      (sym_i64_env.sym-i64-empty))
      [(compiler_load.ResultCompilerLoad.Ok _ seen)
        (match (compiler_load.compiler-load-source path source seen)
          [(compiler_load.ResultCompilerLoad.Ok decls _)
            (match (ast.ast-decl-list-step decls)
              [(ast.AstDeclListStep.Nil) true]
              [_ false])]
          [(compiler_load.ResultCompilerLoad.Err _) false])]
      [(compiler_load.ResultCompilerLoad.Err _) false])))

(define (compiler-check-pool-reset-ok?) : bool
  (let
    [source : String "(define (main) : i64 0)"]
    (begin
      (ast.ty-node-pool-reset!)
      (match (compiler-check-source "tests/pool_reset_a.tl" source)
        [(ResultCompilerCheck.Ok _)
          (let
            [first-len : i64 (ast.ty-node-pool-len)]
            (match (compiler-check-source "tests/pool_reset_b.tl" source)
              [(ResultCompilerCheck.Ok _)
                (let
                  [second-len : i64 (ast.ty-node-pool-len)]
                  (and (> first-len 0) (= first-len second-len)))]
              [(ResultCompilerCheck.Err _) false]))]
        [(ResultCompilerCheck.Err _) false]))))

(define (compiler-check-target-cfg-ok?) : bool
  (let
    [source : String
      "(cfg linux (define platform-value : i64 40))
(cfg windows (define platform-value : i64 40))
(cfg tooling-feature (define cfg-value : i64 2))
(define (main) : i64 (+ platform-value cfg-value))"]
    [names : svec.Vec (svec.new)]
    (begin
      (svec.push-ref! (&mut names) "tooling-feature")
      (and
        (match (compiler-check-source-with-roots-and-cfg
          "tests/check_cfg_linux.tl"
          source
          (svec.new)
          (target_cfg.compiler-target-cfgs-with-names
            target_cfg.CompilerTargetCfg.Linux
            names))
          [(ResultCompilerCheck.Ok _) true]
          [(ResultCompilerCheck.Err _) false])
        (match (compiler-check-source-with-roots-and-cfg
          "tests/check_cfg_windows.tl"
          source
          (svec.new)
          (target_cfg.compiler-target-cfgs-with-names
            target_cfg.CompilerTargetCfg.Windows
            names))
          [(ResultCompilerCheck.Ok _) true]
          [(ResultCompilerCheck.Err _) false])))))

(define (compiler-check-self-test) : i64
  (begin
    (unless
      (= (compiler_load.compiler-load-self-test) 42)
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
      (compiler-check-private-dynamic-buffer-accepted-ok?)
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
    (unless
      (compiler-check-target-cfg-ok?)
      (return (io.panic "compiler-check: target/cfg smoke mismatch")))
    42))