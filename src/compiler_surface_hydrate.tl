;; compiler_surface_hydrate.tl - package-agnostic frontend surface lookup and
;; hydration from TLCl auxiliary sections.
(import compiler_surface_ast as surface_ast)
(import compiler_surface_identity as surface_identity)
(import compiler_surface_facts as surface_facts)
(import compiler_intern_state as cis)
(import compiler_ast_types as ast)
(import compiler_owned_view as owned_view)
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

(define (compiler-surface-identity-bytes
  [rodata : (& rodata (__tl_dyn-array u8))]) : tlci.ResultTlciAuxLookup
  (tlci.tlci-aux-find rodata tlci.tlci-aux-kind-package-identity))

(define (compiler-surface-ast-bytes [rodata : (& rodata (__tl_dyn-array u8))]) : tlci.ResultTlciAuxLookup
  (tlci.tlci-aux-find rodata tlci.tlci-aux-kind-frontend-ast))

(define (compiler-surface-fact-bytes [rodata : (__tl_dyn-array u8)]) : tlci.ResultTlciAuxLookup
  (tlci.tlci-aux-find rodata tlci.tlci-aux-kind-frontend-facts))

(define (compiler-surface-key [rodata : (__tl_dyn-array u8)]) : ResultCompilerSurfaceKey
  (match (compiler-surface-identity-bytes rodata)
    [(Missing) Missing]
    [(Err message) (Err message)]
    [(Ok schema bytes)
      (if (not (= schema surface_identity.surface-identity-schema-version))
        (Err "compiler surface: unsupported identity schema")
        (match (surface_identity.surface-identity-decode bytes)
          [(Err message) (Err message)]
          [(Ok payload) (Ok payload.key)]))]))

(define (compiler-surface-hydrate-payloads
  [identity-bytes : (__tl_dyn-array u8)]
  [ast-bytes : (__tl_dyn-array u8)]
  [fact-bytes : (__tl_dyn-array u8)]
  [expected-key : (& expected-key surface_identity.SurfaceIdentityKey)]
  [structural-session : cis.InternStructuralSessionHandle]
  [pools : ast.AstNodePoolContext]) : ResultCompilerSurfaceHydration
  (match (surface_identity.surface-identity-hydrate identity-bytes expected-key)
    [(Err message) (Err message)]
    [(KeyMismatch message) (KeyMismatch message)]
    [(Ok identity)
      (match (surface_ast.surface-ast-decode
        ast-bytes
        structural-session
        (owned_view.compiler-owned-place-shared-view identity.remap)
        pools)
        [(Err message) (Err message)]
        [(Ok hydration)
          (match (surface_facts.surface-typecheck-facts-decode
            fact-bytes
            structural-session
            identity.remap)
            [(Err message) (Err message)]
            [(Ok facts) (Ok (CompilerSurfaceHydration hydration facts))])])]))

(define (compiler-surface-hydrate
  [rodata : (__tl_dyn-array u8)]
  [expected-key : surface_identity.SurfaceIdentityKey]
  [structural-session : cis.InternStructuralSessionHandle]
  [pools : ast.AstNodePoolContext]) : ResultCompilerSurfaceHydration
  (match (compiler-surface-identity-bytes rodata)
    [(Missing) Missing]
    [(Err message) (Err message)]
    [(Ok identity-schema identity-bytes)
      (if (not
        (= identity-schema surface_identity.surface-identity-schema-version))
        (Err "compiler surface: unsupported identity schema")
        (match (compiler-surface-ast-bytes rodata)
          [(Missing) Missing]
          [(Err message) (Err message)]
          [(Ok ast-schema ast-bytes)
            (if (not (= ast-schema surface_ast.surface-ast-schema-version))
              (Err "compiler surface: unsupported AST schema")
              (match (compiler-surface-fact-bytes rodata)
                [(Missing) Missing]
                [(Err message) (Err message)]
                [(Ok fact-schema fact-bytes)
                  (if (not
                    (=
                      fact-schema
                      surface_facts.surface-typecheck-facts-schema-version))
                    (Err "compiler surface: unsupported fact schema")
                    (compiler-surface-hydrate-payloads
                      identity-bytes
                      ast-bytes
                      fact-bytes
                      expected-key
                      structural-session
                      pools))]))]))]))