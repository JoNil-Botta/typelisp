;; compiler_package_surface_producer.tl - capture package frontend surfaces
;; from the checked compilation that also feeds runtime emission.
;;
;; The capture is armed by the package builder before lowering. The lowerer
;; publishes the post-expansion program, then completes the capture immediately
;; after the real whole-program typecheck while all AST pools and intern
;; identities are still live. Only relocatable encoded bytes escape that
;; boundary.
(import compiler_ast_types as ast)
(import compiler_intern_state as cis)
(import compiler_builtin_ids as cbi)
(import compiler_owned_view as owned_view)
(import compiler_prelude_surface_producer as prelude_surface)
(import compiler_surface_ast as surface_ast)
(import compiler_surface_facts as surface_facts)
(import compiler_surface_identity as surface_identity)
(import stdlib.arena)
(cfg test (import stdlib.io))
(import stdlib.string)
(import sym_i64_env)
(import tlci_core as tlci)

(defstruct PackageSurfacePayloads
  (identity (__tl_dyn-array u8))
  (ast (__tl_dyn-array u8))
  (facts (__tl_dyn-array u8)))

(defenum ResultPackageSurfacePayloads
  (Ok PackageSurfacePayloads)
  (Err String))

(defenum PackageSurfaceCaptureState
  (Inactive)
  (Pending surface_identity.SurfaceIdentityKey sym_i64_env.SymI64Env i64)
  (Expanded
    surface_identity.SurfaceIdentityKey
    cis.InternStructuralSessionHandle
    sym_i64_env.SymI64Env
    ast.AstProgram
    ast.AstDeclPathList
    ast.AstNodePoolContext
    i64
    i64)
  (Ready PackageSurfacePayloads)
  (Err String))

;; The carrier stays live across frontend retirement, including failed lower.
;; Its payloads still obey the capture lifetime: encoded bytes and diagnostics
;; belong to the caller's result arena; expanded AST references are consumed
;; before the frontend owner is released.
(define package-surface-capture-state : (__tl_dyn-array
    PackageSurfaceCaptureState)
  (__tl_make-array (Inactive)))
(define package-surface-capture-result-arena : i64
  0)

(define (package-surface-capture-state-shared-view) : PackageSurfaceCaptureState
  (owned_view.compiler-owned-array-element-shared-view
    package-surface-capture-state
    0))

(define (package-surface-capture-error! [message : String]) : unit
  (in-arena
    (arena.Arena package-surface-capture-result-arena)
    (set!
      (array-ref package-surface-capture-state 0)
      (PackageSurfaceCaptureState.Err (string.copy message)))))

(define (package-surface-identity-key
  [package-name : String]
  [paths : ast.AstDeclPathList]
  [source-digest : i64]
  [producer-identity : String]
  [configuration : String]) : surface_identity.SurfaceIdentityKey
  (let
    [all-modules : (__tl_dyn-array String)
      (prelude_surface.prelude-surface-module-set paths)]
    [count : i64 0]
    [index : i64 0]
    (while (< index (array-length all-modules))
      (if (>
        (string.string-length
          (owned_view.compiler-owned-array-element-shared-view
            all-modules
            index))
        0)
        (set! count (+ count 1))
        unit)
      (set! index (+ index 1)))
    (let
      [modules : (__tl_dyn-array String)
        (__tl_make-array
          String
          (if (= count 0)
            1
            count))]
      [source-index : i64 0]
      [dest-index : i64 0]
      (while (< source-index (array-length all-modules))
        (let
          [module-name : String
            (string.copy
              (owned_view.compiler-owned-array-element-shared-view
                all-modules
                source-index))]
          (when
            (> (string.string-length module-name) 0)
            (set! (array-ref modules dest-index) module-name)
            (set! dest-index (+ dest-index 1)))
          (set! source-index (+ source-index 1))))
      (if (= count 0)
        (set! (array-ref modules 0) (string.copy (& package-name)))
        unit)
      (surface_identity.SurfaceIdentityKey
        package-name
        modules
        (string.int->string source-digest)
        producer-identity
        configuration))))

(define (package-surface-capture-start!
  [key : surface_identity.SurfaceIdentityKey]
  [seen : sym_i64_env.SymI64Env]) : unit
  (surface_facts.surface-typecheck-facts-recording-abort!)
  (set! package-surface-capture-result-arena (arena.tl_arena_current))
  (set!
    (array-ref package-surface-capture-state 0)
    (Pending key seen (arena.tl_arena_current))))

(define (package-surface-program-decl-count [program : ast.AstProgram]) : i64
  (match program
    [(Program decls-box) (ast.ast-decl-list-len (& (__tl-box-place decls-box)))]))

(define (package-surface-modules [program : ast.AstProgram]) : ast.AstDeclModuleList
  (match program
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        [count : i64 (ast.ast-decl-list-len (& decls))]
        [slots : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [module-id : i64 cbi.compiler-builtin-id-fix-empty]
        [index : i64 0]
        (while (< index count)
          (set! (array-ref slots index) module-id)
          (set!
            module-id
            (ast.ast-decl-list-module-id-at (& decls) index module-id))
          (set! index (+ index 1)))
        (ast.AstDeclModuleList slots 0 count true))]))

(define (package-surface-capture-expanded!
  [structural-session : cis.InternStructuralSessionHandle]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [pools : ast.AstNodePoolContext]) : unit
  (match (package-surface-capture-state-shared-view)
    [(Pending key seen result-arena)
      (let
        [macro-decl-count : i64
          (package-surface-program-decl-count
            (owned_view.compiler-owned-shared-view program))]
        (surface_facts.surface-typecheck-facts-recording-start! result-arena)
        (set!
          (array-ref package-surface-capture-state 0)
          (Expanded
            key
            structural-session
            seen
            program
            paths
            pools
            macro-decl-count
            result-arena)))]
    [(or (Inactive) (Err _)) unit]
    [_
      (surface_facts.surface-typecheck-facts-recording-abort!)
      (package-surface-capture-error!
        "package surface: duplicate checked compilation capture")]))

(define (package-surface-capture-store-encoded!
  [key : surface_identity.SurfaceIdentityKey]
  [structural-session : cis.InternStructuralSessionHandle]
  [seen : sym_i64_env.SymI64Env]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [pools : ast.AstNodePoolContext]
  [facts : surface_facts.SurfaceTypecheckFacts]) : unit
  (let
    [identity-payload : surface_identity.SurfaceIdentityPayload
      (surface_identity.surface-identity-capture key)]
    [source-count : i64 (array-length identity-payload.source-names)]
    [identity-count : i64
      (+ source-count (array-length identity-payload.generated))]
    [modules : ast.AstDeclModuleList
      (package-surface-modules (owned_view.compiler-owned-shared-view program))]
    (match (surface_identity.surface-identity-encode identity-payload)
      [(Err message) (package-surface-capture-error! message)]
      [(Ok identity-bytes)
        (match program
          [(Program decls-box)
            (match (surface_ast.surface-ast-encode
              structural-session
              (deref decls-box)
              paths
              modules
              seen
              pools
              source-count
              identity-count)
              [(Err message) (package-surface-capture-error! message)]
              [(Ok ast-bytes)
                (match (surface_facts.surface-typecheck-facts-encode
                  facts
                  structural-session
                  source-count
                  identity-count)
                  [(Err message) (package-surface-capture-error! message)]
                  [(Ok fact-bytes)
                    (set!
                      (array-ref package-surface-capture-state 0)
                      (Ready
                        (PackageSurfacePayloads
                          identity-bytes
                          ast-bytes
                          fact-bytes)))])])])])))

(define (package-surface-capture-finish!
  [prefix-decl-count : i64]
  [summary-values : i64]
  [summary-functions : i64]
  [summary-externs : i64]) : unit
  (match (package-surface-capture-state-shared-view)
    [(Expanded
        key
        structural-session
        seen
        program
        paths
        pools
        macro-decl-count
        result-arena)
      (in-arena
        (arena.Arena result-arena)
        (let
          [facts : surface_facts.SurfaceTypecheckFacts
            (surface_facts.surface-typecheck-facts-recording-finish
              macro-decl-count
              prefix-decl-count
              summary-values
              summary-functions
              summary-externs)]
          (package-surface-capture-store-encoded!
            key
            structural-session
            seen
            program
            paths
            pools
            facts)))]
    [(Inactive) unit]
    [_
      (surface_facts.surface-typecheck-facts-recording-abort!)
      (package-surface-capture-error!
        "package surface: checked frontend capture was not armed")]))

(define (package-surface-capture-abort! [message : String]) : unit
  (match (package-surface-capture-state-shared-view)
    [(Inactive) unit]
    [_
      (surface_facts.surface-typecheck-facts-recording-abort!)
      (package-surface-capture-error! message)]))

(define (package-surface-capture-take) : ResultPackageSurfacePayloads
  (match (package-surface-capture-state-shared-view)
    [(Ready payload)
      (let
        [result : ResultPackageSurfacePayloads (Ok payload)]
        (set! (array-ref package-surface-capture-state 0) (Inactive))
        result)]
    [(Err message)
      (let
        [result : ResultPackageSurfacePayloads (Err message)]
        (set! (array-ref package-surface-capture-state 0) (Inactive))
        result)]
    [(Inactive)
      (Err "package surface: no checked frontend capture was requested")]
    [_
      (surface_facts.surface-typecheck-facts-recording-abort!)
      (set! (array-ref package-surface-capture-state 0) (Inactive))
      (Err "package surface: checked frontend capture did not complete")]))

(define (package-surface-pack
  [payload : PackageSurfacePayloads]
  [source-digest : i64]) : tlci.ResultTlciAuxBytes
  (let
    [sections : (__tl_dyn-array tlci.TlciAuxSection)
      (__tl_make-array tlci.TlciAuxSection 4)]
    (set!
      (array-ref sections 0)
      (tlci.TlciAuxSection
        tlci.tlci-aux-kind-package-identity
        surface_identity.surface-identity-schema-version
        payload.identity))
    (set!
      (array-ref sections 1)
      (tlci.TlciAuxSection
        tlci.tlci-aux-kind-frontend-ast
        surface_ast.surface-ast-schema-version
        payload.ast))
    (set!
      (array-ref sections 2)
      (tlci.TlciAuxSection
        tlci.tlci-aux-kind-frontend-facts
        surface_facts.surface-typecheck-facts-schema-version
        payload.facts))
    (set!
      (array-ref sections 3)
      (tlci.tlci-package-source-binding-section source-digest))
    (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)))

(cfg
  (all
    test
    (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci))
  (test
    package-surface-abort-survives-scratch-retirement
    (let
      [round : i64 0]
      (while (< round 8)
        (with-scratch
          (package-surface-capture-start!
            (surface_identity.SurfaceIdentityKey
              "capture"
              (__tl_make-array "capture")
              "source"
              "compiler"
              "linux-x86_64")
            (sym_i64_env.sym-i64-empty))
          (with-scratch
            (package-surface-capture-abort! (string.copy "retained diagnostic")))
          (unless
            (match (package-surface-capture-take)
              [(Err message) (string.eq message "retained diagnostic")]
              [_ false])
            (io.panic "package capture lost its retired error")))
        ;; The inactive carrier must also survive its former result arena.
        (package-surface-capture-abort! "inactive abort")
        (unless
          (match (package-surface-capture-take)
            [(Err message)
              (string.eq
                message
                "package surface: no checked frontend capture was requested")]
            [_ false])
          (io.panic "package capture retained a retired active state"))
        (set! round (+ round 1))))))

(cfg
  test
  (test
    package-surface-pack-sections
    (let
      [payload : PackageSurfacePayloads
        (PackageSurfacePayloads
          (tlci.tlci-string->bytes "identity")
          (tlci.tlci-empty-bytes)
          (tlci.tlci-string->bytes "facts"))]
      [ok : bool
        (match (package-surface-pack payload 42)
          [(Err _) false]
          [(Ok rodata)
            (and
              (match (tlci.tlci-aux-find
                rodata
                tlci.tlci-aux-kind-package-identity)
                [(Ok schema bytes)
                  (and
                    (= schema surface_identity.surface-identity-schema-version)
                    (= (array-length bytes) 8))]
                [_ false])
              (match (tlci.tlci-aux-find rodata tlci.tlci-aux-kind-frontend-ast)
                [(Ok schema bytes)
                  (and
                    (= schema surface_ast.surface-ast-schema-version)
                    (= (array-length bytes) 0))]
                [_ false])
              (match (tlci.tlci-aux-find
                rodata
                tlci.tlci-aux-kind-frontend-facts)
                [(Ok schema bytes)
                  (and
                    (=
                      schema
                      surface_facts.surface-typecheck-facts-schema-version)
                    (= (array-length bytes) 5))]
                [_ false])
              (match (tlci.tlci-package-source-binding-read rodata)
                [(Bound digest) (= digest 42)]
                [_ false]))])]
      (unless ok (io.panic "package surface section packing failed")))))