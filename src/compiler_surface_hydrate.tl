;; compiler_surface_hydrate.tl - package-agnostic frontend surface lookup and
;; hydration from TLCl auxiliary sections.
(import compiler_surface_ast as surface_ast)
(import compiler_surface_identity as surface_identity)
(import compiler_surface_facts as surface_facts)
(import compiler_ast_types as ast)
(import tlci_core as tlci)

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
            (ResultCompilerSurfaceKey.Ok (struct-get payload key))]))]))

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
        (struct-get identity remap)
        pools)
        [(surface_ast.ResultSurfaceAstHydration.Err message)
          (ResultCompilerSurfaceHydration.Err message)]
        [(surface_ast.ResultSurfaceAstHydration.Ok hydration)
          (match (surface_facts.surface-typecheck-facts-decode
            fact-bytes
            (struct-get identity remap))
            [(surface_facts.ResultSurfaceTypecheckFacts.Err message)
              (ResultCompilerSurfaceHydration.Err message)]
            [(surface_facts.ResultSurfaceTypecheckFacts.Ok facts)
              (begin
                (surface_facts.surface-typecheck-facts-install! facts)
                (ResultCompilerSurfaceHydration.Ok
                  (CompilerSurfaceHydration hydration facts)))])])]))

(define (compiler-surface-hydrate
  [rodata : (__tl_dyn-array u8)]
  [expected-key : surface_identity.SurfaceIdentityKey]
  [pools : ast.AstNodePoolContext]) : ResultCompilerSurfaceHydration
  (begin
    (surface_facts.surface-typecheck-facts-clear!)
    (match (compiler-surface-identity-bytes rodata)
      [(tlci.ResultTlciAuxLookup.Missing)
        ResultCompilerSurfaceHydration.Missing]
      [(tlci.ResultTlciAuxLookup.Err message)
        (ResultCompilerSurfaceHydration.Err message)]
      [(tlci.ResultTlciAuxLookup.Ok identity-schema identity-bytes)
        (if (not
          (= identity-schema surface_identity.surface-identity-schema-version))
          (ResultCompilerSurfaceHydration.Err
            "compiler surface: unsupported identity schema")
          (match (compiler-surface-ast-bytes rodata)
            [(tlci.ResultTlciAuxLookup.Missing)
              ResultCompilerSurfaceHydration.Missing]
            [(tlci.ResultTlciAuxLookup.Err message)
              (ResultCompilerSurfaceHydration.Err message)]
            [(tlci.ResultTlciAuxLookup.Ok ast-schema ast-bytes)
              (if (not (= ast-schema surface_ast.surface-ast-schema-version))
                (ResultCompilerSurfaceHydration.Err
                  "compiler surface: unsupported AST schema")
                (match (compiler-surface-fact-bytes rodata)
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
                        pools))]))]))])))