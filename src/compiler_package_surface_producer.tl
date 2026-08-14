;; compiler_package_surface_producer.tl - capture package frontend surfaces
;; from the checked compilation that also feeds runtime emission.
;;
;; The capture is armed by the package builder before lowering. The lowerer
;; publishes the post-expansion program, then completes the capture immediately
;; after the real whole-program typecheck while all AST pools and intern
;; identities are still live. Only relocatable encoded bytes escape that
;; boundary.
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
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
    sym_i64_env.SymI64Env
    ast.AstProgram
    ast.AstDeclPathList
    ast.AstNodePoolContext
    i64
    i64)
  (Ready PackageSurfacePayloads)
  (Err String))

(define package-surface-capture-state : PackageSurfaceCaptureState
  (PackageSurfaceCaptureState.Inactive))

(define (package-surface-capture-state-shared-view) : PackageSurfaceCaptureState
  (cfg
    stage0-seed-bootstrap
    package-surface-capture-state
    (unsafe
      (ptr-read (ptr-addr-of package-surface-capture-state)))))

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
    (begin
      (while (< index (array-length all-modules))
        (begin
          (if (> (string.string-length (array-ref all-modules index)) 0)
            (set! count (+ count 1))
            unit)
          (set! index (+ index 1))))
      (let
        [modules : (__tl_dyn-array String)
          (make-array
            String
            (if (= count 0)
              1
              count))]
        [source-index : i64 0]
        [dest-index : i64 0]
        (begin
          (while (< source-index (array-length all-modules))
            (let
              [module-name : String (array-ref all-modules source-index)]
              (begin
                (if (> (string.string-length module-name) 0)
                  (begin
                    (set! (array-ref modules dest-index) module-name)
                    (set! dest-index (+ dest-index 1)))
                  unit)
                (set! source-index (+ source-index 1)))))
          (if (= count 0)
            (set! (array-ref modules 0) package-name)
            unit)
          (surface_identity.SurfaceIdentityKey
            package-name
            modules
            (string.int->string source-digest)
            producer-identity
            configuration))))))

(define (package-surface-capture-start!
  [key : surface_identity.SurfaceIdentityKey]
  [seen : sym_i64_env.SymI64Env]) : unit
  (begin
    (surface_facts.surface-typecheck-facts-recording-abort!)
    (set!
      package-surface-capture-state
      (PackageSurfaceCaptureState.Pending key seen (arena.tl_arena_current)))))

(define (package-surface-program-decl-count [program : ast.AstProgram]) : i64
  (match program
    [(ast.AstProgram.Program decls-box)
      (ast.ast-decl-list-len (& (__tl-box-place decls-box)))]))

(define (package-surface-modules [program : ast.AstProgram]) : ast.AstDeclModuleList
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        [count : i64 (ast.ast-decl-list-len (& decls))]
        [slots : (__tl_dyn-array i64) (make-array i64 count)]
        [module-id : i64 cbi.compiler-builtin-id-fix-empty]
        [index : i64 0]
        (begin
          (while (< index count)
            (begin
              (set! (array-ref slots index) module-id)
              (set!
                module-id
                (ast.ast-decl-list-module-id-at (& decls) index module-id))
              (set! index (+ index 1))))
          (ast.AstDeclModuleList slots 0 count true)))]))

(define (package-surface-capture-expanded!
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [pools : ast.AstNodePoolContext]) : unit
  (match (package-surface-capture-state-shared-view)
    [(PackageSurfaceCaptureState.Pending key seen result-arena)
      (begin
        (surface_facts.surface-typecheck-facts-recording-start! result-arena)
        (set!
          package-surface-capture-state
          (PackageSurfaceCaptureState.Expanded
            key
            seen
            program
            paths
            pools
            (package-surface-program-decl-count program)
            result-arena)))]
    [(PackageSurfaceCaptureState.Inactive) unit]
    [(PackageSurfaceCaptureState.Err _) unit]
    [_
      (begin
        (surface_facts.surface-typecheck-facts-recording-abort!)
        (set!
          package-surface-capture-state
          (PackageSurfaceCaptureState.Err
            "package surface: duplicate checked compilation capture")))]))

(define (package-surface-capture-store-encoded!
  [key : surface_identity.SurfaceIdentityKey]
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
    (match (surface_identity.surface-identity-encode identity-payload)
      [(surface_identity.ResultSurfaceIdentityBytes.Err message)
        (set!
          package-surface-capture-state
          (PackageSurfaceCaptureState.Err message))]
      [(surface_identity.ResultSurfaceIdentityBytes.Ok identity-bytes)
        (match program
          [(ast.AstProgram.Program decls-box)
            (match (surface_ast.surface-ast-encode
              (__tl-box-place decls-box)
              paths
              (package-surface-modules program)
              seen
              pools
              source-count
              identity-count)
              [(surface_ast.ResultSurfaceAstBytes.Err message)
                (set!
                  package-surface-capture-state
                  (PackageSurfaceCaptureState.Err message))]
              [(surface_ast.ResultSurfaceAstBytes.Ok ast-bytes)
                (match (surface_facts.surface-typecheck-facts-encode
                  facts
                  source-count
                  identity-count)
                  [(surface_facts.ResultSurfaceTypecheckFactBytes.Err message)
                    (set!
                      package-surface-capture-state
                      (PackageSurfaceCaptureState.Err message))]
                  [(surface_facts.ResultSurfaceTypecheckFactBytes.Ok fact-bytes)
                    (set!
                      package-surface-capture-state
                      (PackageSurfaceCaptureState.Ready
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
    [(PackageSurfaceCaptureState.Expanded
        key
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
            seen
            program
            paths
            pools
            facts)))]
    [(PackageSurfaceCaptureState.Inactive) unit]
    [_
      (begin
        (surface_facts.surface-typecheck-facts-recording-abort!)
        (set!
          package-surface-capture-state
          (PackageSurfaceCaptureState.Err
            "package surface: checked frontend capture was not armed")))]))

(define (package-surface-capture-abort! [message : String]) : unit
  (match (package-surface-capture-state-shared-view)
    [(PackageSurfaceCaptureState.Inactive) unit]
    [_
      (begin
        (surface_facts.surface-typecheck-facts-recording-abort!)
        (set!
          package-surface-capture-state
          (PackageSurfaceCaptureState.Err message)))]))

(define (package-surface-capture-take) : ResultPackageSurfacePayloads
  (match (package-surface-capture-state-shared-view)
    [(PackageSurfaceCaptureState.Ready payload)
      (begin
        (set!
          package-surface-capture-state
          (PackageSurfaceCaptureState.Inactive))
        (ResultPackageSurfacePayloads.Ok payload))]
    [(PackageSurfaceCaptureState.Err message)
      (begin
        (set!
          package-surface-capture-state
          (PackageSurfaceCaptureState.Inactive))
        (ResultPackageSurfacePayloads.Err message))]
    [(PackageSurfaceCaptureState.Inactive)
      (ResultPackageSurfacePayloads.Err
        "package surface: no checked frontend capture was requested")]
    [_
      (begin
        (surface_facts.surface-typecheck-facts-recording-abort!)
        (set!
          package-surface-capture-state
          (PackageSurfaceCaptureState.Inactive))
        (ResultPackageSurfacePayloads.Err
          "package surface: checked frontend capture did not complete"))]))

(define (package-surface-pack
  [payload : PackageSurfacePayloads]
  [source-digest : i64]) : tlci.ResultTlciAuxBytes
  (let
    [sections : (__tl_dyn-array tlci.TlciAuxSection)
      (make-array tlci.TlciAuxSection 4)]
    (begin
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
      (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections))))

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
          [(tlci.ResultTlciAuxBytes.Err _) false]
          [(tlci.ResultTlciAuxBytes.Ok rodata)
            (and
              (match (tlci.tlci-aux-find
                rodata
                tlci.tlci-aux-kind-package-identity)
                [(tlci.ResultTlciAuxLookup.Ok schema bytes)
                  (and
                    (= schema surface_identity.surface-identity-schema-version)
                    (= (array-length bytes) 8))]
                [_ false])
              (match (tlci.tlci-aux-find rodata tlci.tlci-aux-kind-frontend-ast)
                [(tlci.ResultTlciAuxLookup.Ok schema bytes)
                  (and
                    (= schema surface_ast.surface-ast-schema-version)
                    (= (array-length bytes) 0))]
                [_ false])
              (match (tlci.tlci-aux-find
                rodata
                tlci.tlci-aux-kind-frontend-facts)
                [(tlci.ResultTlciAuxLookup.Ok schema bytes)
                  (and
                    (=
                      schema
                      surface_facts.surface-typecheck-facts-schema-version)
                    (= (array-length bytes) 5))]
                [_ false])
              (match (tlci.tlci-package-source-binding-read rodata)
                [(tlci.TlciPackageSourceBindingRead.Bound digest) (= digest 42)]
                [_ false]))])]
      (unless ok (io.panic "package surface section packing failed")))))