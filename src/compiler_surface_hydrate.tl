;; compiler_surface_hydrate.tl - package-agnostic frontend surface lookup and
;; hydration from TLCl auxiliary sections.
(import compiler_surface_ast as surface_ast)
(import compiler_surface_identity as surface_identity)
(import compiler_surface_facts as surface_facts)
(import compiler_ast_types as ast)
(import compiler_owned_view as owned_view)
(import tlci_core as tlci)
(cfg compiler-surface-selftest (import compiler_intern as ci))
(cfg compiler-surface-selftest (import sym_i64_env as sym_env))

(defstruct CompilerSurfaceHydration
  (ast surface_ast.SurfaceAstHydration)
  (facts surface_facts.SurfaceTypecheckFacts))

(defenum ResultCompilerSurfaceKey
  (Missing)
  (Ok surface_identity.SurfaceIdentityKey)
  (Err String))

(defenum ResultCompilerSurfaceHydration
  (Missing)
  (KeyMismatch String)
  (Ok CompilerSurfaceHydration)
  (Err String))

(cfg
  compiler-surface-selftest
  (defstruct CompilerSurfaceHydrateTestPayloads
    (identity-bytes (__tl_dyn-array u8))
    (ast-bytes (__tl_dyn-array u8))
    (fact-one-bytes (__tl_dyn-array u8))
    (fact-two-bytes (__tl_dyn-array u8))
    (key surface_identity.SurfaceIdentityKey)))

(cfg
  compiler-surface-selftest
  (defenum ResultCompilerSurfaceHydrateTestPayloads
    (Ok CompilerSurfaceHydrateTestPayloads)
    (Err String)))

(define (compiler-surface-identity-bytes [rodata : (__tl_dyn-array u8)]) : tlci.ResultTlciAuxLookup
  (tlci.tlci-aux-find rodata tlci.tlci-aux-kind-package-identity))

(define (compiler-surface-ast-bytes [rodata : (__tl_dyn-array u8)]) : tlci.ResultTlciAuxLookup
  (tlci.tlci-aux-find rodata tlci.tlci-aux-kind-frontend-ast))

(define (compiler-surface-fact-bytes [rodata : (__tl_dyn-array u8)]) : tlci.ResultTlciAuxLookup
  (tlci.tlci-aux-find rodata tlci.tlci-aux-kind-frontend-facts))

(define (compiler-surface-key [rodata : (__tl_dyn-array u8)]) : ResultCompilerSurfaceKey
  (match (compiler-surface-identity-bytes rodata)
    [(tlci.ResultTlciAuxLookup.Missing) ResultCompilerSurfaceKey.Missing]
    [(tlci.ResultTlciAuxLookup.Err message)
      (ResultCompilerSurfaceKey.Err message)]
    [(tlci.ResultTlciAuxLookup.Ok schema bytes)
      (if (not (= schema surface_identity.surface-identity-schema-version))
        (ResultCompilerSurfaceKey.Err
          "compiler surface: unsupported identity schema")
        (match (surface_identity.surface-identity-decode bytes)
          [(surface_identity.ResultSurfaceIdentityPayload.Err message)
            (ResultCompilerSurfaceKey.Err message)]
          [(surface_identity.ResultSurfaceIdentityPayload.Ok payload)
            (ResultCompilerSurfaceKey.Ok payload.key)]))]))

(define (compiler-surface-hydrate-payloads
  [identity-bytes : (__tl_dyn-array u8)]
  [ast-bytes : (__tl_dyn-array u8)]
  [fact-bytes : (__tl_dyn-array u8)]
  [expected-key : surface_identity.SurfaceIdentityKey]
  [pools : ast.AstNodePoolContext]) : ResultCompilerSurfaceHydration
  (match (surface_identity.surface-identity-hydrate identity-bytes expected-key)
    [(surface_identity.ResultSurfaceIdentityHydration.Err message)
      (ResultCompilerSurfaceHydration.Err message)]
    [(surface_identity.ResultSurfaceIdentityHydration.KeyMismatch message)
      (ResultCompilerSurfaceHydration.KeyMismatch message)]
    [(surface_identity.ResultSurfaceIdentityHydration.Ok identity)
      (match (surface_ast.surface-ast-decode
        ast-bytes
        (owned_view.compiler-owned-shared-view identity.remap)
        pools)
        [(surface_ast.ResultSurfaceAstHydration.Err message)
          (ResultCompilerSurfaceHydration.Err message)]
        [(surface_ast.ResultSurfaceAstHydration.Ok hydration)
          (match (surface_facts.surface-typecheck-facts-decode
            fact-bytes
            (owned_view.compiler-owned-shared-view identity.remap))
            [(surface_facts.ResultSurfaceTypecheckFacts.Err message)
              (ResultCompilerSurfaceHydration.Err message)]
            [(surface_facts.ResultSurfaceTypecheckFacts.Ok facts)
              (ResultCompilerSurfaceHydration.Ok
                (CompilerSurfaceHydration hydration facts))])])]))

(define (compiler-surface-hydrate
  [rodata : (__tl_dyn-array u8)]
  [expected-key : surface_identity.SurfaceIdentityKey]
  [pools : ast.AstNodePoolContext]) : ResultCompilerSurfaceHydration
  (match (compiler-surface-identity-bytes
    (owned_view.compiler-owned-shared-view rodata))
    [(tlci.ResultTlciAuxLookup.Missing) ResultCompilerSurfaceHydration.Missing]
    [(tlci.ResultTlciAuxLookup.Err message)
      (ResultCompilerSurfaceHydration.Err message)]
    [(tlci.ResultTlciAuxLookup.Ok identity-schema identity-bytes)
      (if (not
        (= identity-schema surface_identity.surface-identity-schema-version))
        (ResultCompilerSurfaceHydration.Err
          "compiler surface: unsupported identity schema")
        (match (compiler-surface-ast-bytes
          (owned_view.compiler-owned-shared-view rodata))
          [(tlci.ResultTlciAuxLookup.Missing)
            ResultCompilerSurfaceHydration.Missing]
          [(tlci.ResultTlciAuxLookup.Err message)
            (ResultCompilerSurfaceHydration.Err message)]
          [(tlci.ResultTlciAuxLookup.Ok ast-schema ast-bytes)
            (if (not (= ast-schema surface_ast.surface-ast-schema-version))
              (ResultCompilerSurfaceHydration.Err
                "compiler surface: unsupported AST schema")
              (match (compiler-surface-fact-bytes
                (owned_view.compiler-owned-shared-view rodata))
                [(tlci.ResultTlciAuxLookup.Missing)
                  ResultCompilerSurfaceHydration.Missing]
                [(tlci.ResultTlciAuxLookup.Err message)
                  (ResultCompilerSurfaceHydration.Err message)]
                [(tlci.ResultTlciAuxLookup.Ok fact-schema fact-bytes)
                  (if (not
                    (=
                      fact-schema
                      surface_facts.surface-typecheck-facts-schema-version))
                    (ResultCompilerSurfaceHydration.Err
                      "compiler surface: unsupported fact schema")
                    (compiler-surface-hydrate-payloads
                      identity-bytes
                      ast-bytes
                      fact-bytes
                      expected-key
                      pools))]))]))]))

(cfg
  compiler-surface-selftest
  (define (compiler-surface-hydrate-test-payloads) : ResultCompilerSurfaceHydrateTestPayloads
    (let
      [_reset : unit (ci.intern-reset!)]
      [decl-id : i64 (ci.intern "decl")]
      [root-id : i64 (ci.intern "root")]
      [package-modules : (__tl_dyn-array String) (__tl_make-array String 1)]
      [source-names : (__tl_dyn-array String) (__tl_make-array String 2)]
      [key : surface_identity.SurfaceIdentityKey
        (begin
          (set! (array-ref package-modules 0) "pkg/main.tl")
          (set! (array-ref source-names 0) "decl")
          (set! (array-ref source-names 1) "root")
          (surface_identity.SurfaceIdentityKey
            "pkg"
            package-modules
            "source-hash"
            "compiler-build"
            "host"))]
      [identity-payload : surface_identity.SurfaceIdentityPayload
        (surface_identity.SurfaceIdentityPayload
          key
          source-names
          (__tl_make-array surface_identity.SurfaceGeneratedIdentity 0))]
      [source-pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 1 1)]
      [decls : ast.AstDeclList (ast.ast-decl-list-new)]
      [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
      [decl-modules : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
      [first : surface_facts.SurfaceTypecheckFacts
        (surface_facts.SurfaceTypecheckFacts
          1
          2
          3
          5
          7
          (__tl_make-array decl-id)
          (__tl_make-array root-id)
          (__tl_make-array 0))]
      [second : surface_facts.SurfaceTypecheckFacts
        (surface_facts.SurfaceTypecheckFacts
          11
          13
          17
          19
          23
          (__tl_make-array decl-id)
          (__tl_make-array root-id)
          (__tl_make-array 0))]
      (match (surface_identity.surface-identity-encode identity-payload)
        [(surface_identity.ResultSurfaceIdentityBytes.Err message)
          (ResultCompilerSurfaceHydrateTestPayloads.Err message)]
        [(surface_identity.ResultSurfaceIdentityBytes.Ok identity-bytes)
          (match (surface_ast.surface-ast-encode
            decls
            paths
            decl-modules
            (sym_env.sym-i64-empty)
            source-pools
            2
            2)
            [(surface_ast.ResultSurfaceAstBytes.Err message)
              (ResultCompilerSurfaceHydrateTestPayloads.Err message)]
            [(surface_ast.ResultSurfaceAstBytes.Ok ast-bytes)
              (match (surface_facts.surface-typecheck-facts-encode first 2 2)
                [(surface_facts.ResultSurfaceTypecheckFactBytes.Err message)
                  (ResultCompilerSurfaceHydrateTestPayloads.Err message)]
                [(surface_facts.ResultSurfaceTypecheckFactBytes.Ok
                    fact-one-bytes)
                  (match (surface_facts.surface-typecheck-facts-encode
                    second
                    2
                    2)
                    [(surface_facts.ResultSurfaceTypecheckFactBytes.Err message)
                      (ResultCompilerSurfaceHydrateTestPayloads.Err message)]
                    [(surface_facts.ResultSurfaceTypecheckFactBytes.Ok
                        fact-two-bytes)
                      (ResultCompilerSurfaceHydrateTestPayloads.Ok
                        (CompilerSurfaceHydrateTestPayloads
                          identity-bytes
                          ast-bytes
                          fact-one-bytes
                          fact-two-bytes
                          key))])])])]))))

(cfg
  compiler-surface-selftest
  (define (compiler-surface-hydrate-tests-ok?) : bool
    (match (compiler-surface-hydrate-test-payloads)
      [(ResultCompilerSurfaceHydrateTestPayloads.Err _) false]
      [(ResultCompilerSurfaceHydrateTestPayloads.Ok payloads)
        (let
          [prior : surface_facts.SurfaceTypecheckFacts
            (surface_facts.surface-typecheck-facts-test-fragment-one)]
          [first-hydrated : surface_facts.SurfaceTypecheckFacts
            (surface_facts.surface-typecheck-facts-empty)]
          [second-hydrated : surface_facts.SurfaceTypecheckFacts
            (surface_facts.surface-typecheck-facts-empty)]
          [pools : ast.AstNodePoolContext
            (ast.ast-node-pool-context-new-with-capacities 1 1)]
          [ok : bool true]
          (begin
            (surface_facts.surface-typecheck-facts-clear!)
            (if (surface_facts.surface-typecheck-facts-publish! prior)
              unit
              (set! ok false))
            (match (compiler-surface-hydrate-payloads
              payloads.identity-bytes
              payloads.ast-bytes
              payloads.fact-one-bytes
              payloads.key
              pools)
              [(ResultCompilerSurfaceHydration.Ok hydration)
                (set! first-hydrated hydration.facts)]
              [_ (set! ok false)])
            ;; A complete successful hydration is still pure: only the explicit
            ;; publisher may replace the previously active facts.
            (if (and
              (surface_facts.surface-typecheck-facts-active?)
              (surface_facts.surface-typecheck-facts-eq?
                (surface_facts.surface-typecheck-facts-current)
                prior))
              unit
              (set! ok false))
            (if (surface_facts.surface-typecheck-facts-publish! first-hydrated)
              unit
              (set! ok false))
            ;; Decode a malformed second fact payload after a valid first one.
            ;; The explicitly published first hydration must remain unchanged.
            (match (compiler-surface-hydrate-payloads
              payloads.identity-bytes
              payloads.ast-bytes
              (__tl_make-array u8 0)
              payloads.key
              pools)
              [(ResultCompilerSurfaceHydration.Err _) unit]
              [_ (set! ok false)])
            (if (and
              (surface_facts.surface-typecheck-facts-active?)
              (surface_facts.surface-typecheck-facts-eq?
                (surface_facts.surface-typecheck-facts-current)
                first-hydrated))
              unit
              (set! ok false))
            (match (compiler-surface-hydrate-payloads
              payloads.identity-bytes
              payloads.ast-bytes
              payloads.fact-two-bytes
              payloads.key
              pools)
              [(ResultCompilerSurfaceHydration.Ok hydration)
                (begin
                  (set! second-hydrated hydration.facts)
                  (if (surface_facts.surface-typecheck-facts-publish!
                    second-hydrated)
                    unit
                    (set! ok false)))]
              [_ (set! ok false)])
            (match (compiler-surface-hydrate
              (__tl_make-array u8 0)
              payloads.key
              pools)
              [(ResultCompilerSurfaceHydration.Missing) unit]
              [_ (set! ok false)])
            (if (and
              (surface_facts.surface-typecheck-facts-active?)
              (surface_facts.surface-typecheck-facts-eq?
                (surface_facts.surface-typecheck-facts-current)
                second-hydrated))
              unit
              (set! ok false))
            (surface_facts.surface-typecheck-facts-clear!)
            ok))])))

(cfg
  compiler-surface-selftest
  (define (compiler-surface-hydrate-selftest-main) : i64
    (if (compiler-surface-hydrate-tests-ok?)
      42
      1)))