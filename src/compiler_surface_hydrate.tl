;; compiler_surface_hydrate.tl - package-agnostic frontend surface lookup and
;; hydration from TLCl auxiliary sections.
(import "compiler_surface_ast.tl")
(import "tlci_core.tl")

(defenum ResultCompilerSurfaceKey
  (Missing)
  (Ok surface_identity.SurfaceIdentityKey)
  (Err String))

(defenum ResultCompilerSurfaceHydration
  (Missing)
  (KeyMismatch String)
  (Ok SurfaceAstHydration)
  (Err String))

(define (compiler-surface-identity-bytes [rodata : (Array u8)]) : ResultTlciAuxLookup
  (tlci-aux-find rodata tlci-aux-kind-package-identity))

(define (compiler-surface-ast-bytes [rodata : (Array u8)]) : ResultTlciAuxLookup
  (tlci-aux-find rodata tlci-aux-kind-frontend-ast))

(define (compiler-surface-key [rodata : (Array u8)]) : ResultCompilerSurfaceKey
  (match (compiler-surface-identity-bytes rodata)
    [(ResultTlciAuxLookup.Missing) ResultCompilerSurfaceKey.Missing]
    [(ResultTlciAuxLookup.Err message) (ResultCompilerSurfaceKey.Err message)]
    [(ResultTlciAuxLookup.Ok schema bytes)
      (if (not (= schema surface_identity.surface-identity-schema-version))
        (ResultCompilerSurfaceKey.Err
          "compiler surface: unsupported identity schema")
        (match (surface_identity.surface-identity-decode bytes)
          [(surface_identity.ResultSurfaceIdentityPayload.Err message)
            (ResultCompilerSurfaceKey.Err message)]
          [(surface_identity.ResultSurfaceIdentityPayload.Ok payload)
            (ResultCompilerSurfaceKey.Ok (struct-get payload key))]))]))

(define (compiler-surface-hydrate-payloads
  [identity-bytes : (Array u8)]
  [ast-bytes : (Array u8)]
  [expected-key : surface_identity.SurfaceIdentityKey]
  [pools : AstNodePoolContext]) : ResultCompilerSurfaceHydration
  (match (surface_identity.surface-identity-hydrate identity-bytes expected-key)
    [(surface_identity.ResultSurfaceIdentityHydration.Err message)
      (ResultCompilerSurfaceHydration.Err message)]
    [(surface_identity.ResultSurfaceIdentityHydration.KeyMismatch message)
      (ResultCompilerSurfaceHydration.KeyMismatch message)]
    [(surface_identity.ResultSurfaceIdentityHydration.Ok identity)
      (match (surface-ast-decode ast-bytes (struct-get identity remap) pools)
        [(ResultSurfaceAstHydration.Err message)
          (ResultCompilerSurfaceHydration.Err message)]
        [(ResultSurfaceAstHydration.Ok hydration)
          (ResultCompilerSurfaceHydration.Ok hydration)])]))

(define (compiler-surface-hydrate
  [rodata : (Array u8)]
  [expected-key : surface_identity.SurfaceIdentityKey]
  [pools : AstNodePoolContext]) : ResultCompilerSurfaceHydration
  (match (compiler-surface-identity-bytes rodata)
    [(ResultTlciAuxLookup.Missing) ResultCompilerSurfaceHydration.Missing]
    [(ResultTlciAuxLookup.Err message)
      (ResultCompilerSurfaceHydration.Err message)]
    [(ResultTlciAuxLookup.Ok identity-schema identity-bytes)
      (if (not
        (= identity-schema surface_identity.surface-identity-schema-version))
        (ResultCompilerSurfaceHydration.Err
          "compiler surface: unsupported identity schema")
        (match (compiler-surface-ast-bytes rodata)
          [(ResultTlciAuxLookup.Missing) ResultCompilerSurfaceHydration.Missing]
          [(ResultTlciAuxLookup.Err message)
            (ResultCompilerSurfaceHydration.Err message)]
          [(ResultTlciAuxLookup.Ok ast-schema ast-bytes)
            (if (not (= ast-schema surface-ast-schema-version))
              (ResultCompilerSurfaceHydration.Err
                "compiler surface: unsupported AST schema")
              (compiler-surface-hydrate-payloads
                identity-bytes
                ast-bytes
                expected-key
                pools))]))]))