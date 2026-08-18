;; compiler_load_identity_smoke.tl - Loader module identity stays interned.
(import stdlib.io)
(import compiler_load)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_builtin_ids as cbi)
(import compiler_owned_view as owned_view)

(define (compiler-load-identity-current-ok?) : bool
  (let
    [module-name : String "loader.identity.same"]
    [source-id : i64
      (compiler_load.compiler-load-parse-context-name-id
        (owned_view.compiler-owned-shared-view module-name))]
    [generated-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view module-name))]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons (ast.AstDecl.Module source-id) (ast.ast-decl-list-new))]
    [fallback-from-source : i64
      (compiler_load.compiler-load-module-fallback-id-for-parse
        (owned_view.compiler-owned-shared-view module-name)
        (ast.AstMaybeModuleName.Some source-id))]
    [fallback-from-generated : i64
      (compiler_load.compiler-load-module-fallback-id-for-parse
        (owned_view.compiler-owned-shared-view module-name)
        (ast.AstMaybeModuleName.Some generated-id))]
    (and
      (not (= source-id generated-id))
      (= fallback-from-source source-id)
      (= fallback-from-generated source-id)
      (compiler_load.compiler-load-decl-list-has-module-id?
        (owned_view.compiler-owned-shared-view decls)
        source-id)
      (not
        (compiler_load.compiler-load-decl-list-has-module-id?
          (owned_view.compiler-owned-shared-view decls)
          generated-id))
      (match (compiler_load.compiler-load-check-expected-module
        "src/loader_identity.tl"
        (ast.AstMaybeModuleName.Some source-id)
        (owned_view.compiler-owned-shared-view module-name)
        -1)
        [(compiler_load.ResultCompilerLoadModuleId.Ok _ checked-id)
          (= checked-id source-id)]
        [(compiler_load.ResultCompilerLoadModuleId.Err _) false])
      (match (compiler_load.compiler-load-check-expected-module
        "src/loader_identity.tl"
        (ast.AstMaybeModuleName.Some generated-id)
        (owned_view.compiler-owned-shared-view module-name)
        source-id)
        [(compiler_load.ResultCompilerLoadModuleId.Ok _ _) false]
        [(compiler_load.ResultCompilerLoadModuleId.Err _) true]))))

(define (compiler-load-identity-snapshot-ok?) : bool
  (let
    [home : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [_b-decoy : i64
      (ci.intern-compat-state-intern (&mut state-b) "loader.identity.decoy")]
    [source-a : i64 -1]
    [source-b : i64 -1]
    [restored-source-a : i64 -1]
    [a-ok : bool false]
    [b-ok : bool false]
    [restored-ok : bool false]
    (begin
      (ci.intern-compat-state-install!
        (owned_view.compiler-owned-shared-view state-a))
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      (set!
        source-a
        (compiler_load.compiler-load-parse-context-name-id
          "loader.identity.same"))
      (set! a-ok (compiler-load-identity-current-ok?))
      (ci.intern-compat-state-capture-from-globals! (&mut state-a))
      (ci.intern-compat-state-install!
        (owned_view.compiler-owned-shared-view state-b))
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      (set!
        source-b
        (compiler_load.compiler-load-parse-context-name-id
          "loader.identity.same"))
      (set! b-ok (compiler-load-identity-current-ok?))
      (ci.intern-compat-state-capture-from-globals! (&mut state-b))
      (ci.intern-compat-state-install!
        (owned_view.compiler-owned-shared-view state-a))
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      (set!
        restored-source-a
        (compiler_load.compiler-load-parse-context-name-id
          "loader.identity.same"))
      (set!
        restored-ok
        (and
          a-ok
          b-ok
          (not (= source-a source-b))
          (= restored-source-a source-a)
          (compiler-load-identity-current-ok?)))
      (ci.intern-compat-state-install!
        (owned_view.compiler-owned-shared-view home))
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      restored-ok)))

(test
  compiler-load-module-identity-ids
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (unless
      (compiler-load-identity-current-ok?)
      (io.panic "compiler-load: module identity ID provenance failed"))
    (ci.intern-reset!)
    (cbi.compiler-builtin-reset!)
    (cbi.compiler-builtin-initialize-for-parse!)
    (unless
      (compiler-load-identity-current-ok?)
      (io.panic "compiler-load: module identity ID reset failed"))
    (if (compiler-load-identity-snapshot-ok?)
      unit
      (io.panic "compiler-load: module identity ID snapshot failed"))))