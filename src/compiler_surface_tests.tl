;; compiler_surface_tests.tl - round-trip, rejection and hydration self-tests
;; for the frontend surface codecs (compiler_surface_identity, _ast, _facts
;; and _hydrate), kept out of the production modules. Built only with
;; `--cfg compiler-surface-selftest --cfg compiler-surface-producer` by
;; tools/compiler-surface-ast-smoke.tl, which scripts/verify-embedded-stdlib-tlci.sh
;; runs.
(cfg compiler-surface-selftest (import stdlib.arena))
(cfg compiler-surface-selftest (import compiler_ast_types as ast))
(cfg compiler-surface-selftest (import stdlib.byte_buf_core))
(cfg compiler-surface-selftest (import compiler_intern as ci))
(cfg compiler-surface-selftest (import compiler_intern_state as cis))
(cfg
  compiler-surface-selftest
  (import compiler_surface_ast_codec_core as codec))
(cfg compiler-surface-selftest (import compiler_owned_view as owned_view))
(cfg compiler-surface-selftest (import compiler_surface_ast as surface_ast))
(cfg compiler-surface-selftest (import compiler_surface_ast_expr as expr_codec))
(cfg compiler-surface-selftest (import compiler_surface_facts as surface_facts))
(cfg
  compiler-surface-selftest
  (import compiler_surface_hydrate as surface_hydrate))
(cfg
  compiler-surface-selftest
  (import compiler_surface_identity as surface_identity))
(cfg compiler-surface-selftest (import sym_i64_env))

(cfg
  compiler-surface-selftest
  (defmacro (surface-tests-shared-view [place : Expr]) : Expr
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-test-macro-global-id
    [session : cis.InternStructuralSessionHandle]
    [module-id : i64]
    [source-name-id : i64]
    [legacy : bool]) : i64
    (cis.intern-macro-global-identity-raw
      (cis.intern-structural-session-macro-global-identity
        session
        (if legacy
          Legacy
          Context)
        module-id
        source-name-id))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-test-macro-local-id
    [session : cis.InternStructuralSessionHandle]
    [module-id : i64]
    [macro-name-id : i64]
    [depth : i64]
    [source-name-id : i64]) : i64
    (let
      [definition : cis.InternMacroDefinitionIdentity
        (cis.intern-structural-session-macro-definition-identity
          session
          module-id
          macro-name-id)]
      (cis.intern-macro-local-identity-raw
        (cis.intern-structural-session-macro-local-identity
          session
          definition
          depth
          source-name-id)))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-test-copy-bytes [bytes : (__tl_dyn-array u8)]) : (__tl_dyn-array
      u8)
    (let
      [out : (__tl_dyn-array u8) (__tl_make-array u8 (array-length bytes))]
      [index : i64 0]
      (while (< index (array-length bytes))
        (set! (array-ref out index) (array-ref bytes index))
        (set! index (+ index 1)))
      out)))

(cfg
  compiler-surface-selftest
  (define (surface-identity-test-key) : surface_identity.SurfaceIdentityKey
    (let
      [modules : (__tl_dyn-array String) (__tl_make-array String 2)]
      (set! (array-ref modules 0) "pkg/a.tl")
      (set! (array-ref modules 1) "pkg/b.tl")
      (surface_identity.SurfaceIdentityKey
        "pkg"
        modules
        "source-hash"
        "compiler-build"
        "host"))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-remap-test-ok?
    [hydration : surface_identity.SurfaceIdentityHydration]
    [source-count : i64]
    [generated-count : i64]) : bool
    (let
      [remap : (__tl_dyn-array i64) hydration.remap]
      (and
        (= (array-length remap) (+ source-count generated-count))
        (= generated-count 4)
        (surface_identity.surface-identity-string-eq?
          (ci.intern-str (array-ref remap 0))
          "alpha")
        (surface_identity.surface-identity-string-eq?
          (ci.intern-str (array-ref remap 1))
          "module")
        (surface_identity.surface-identity-string-eq?
          (ci.intern-str (array-ref remap 2))
          "base")
        (ci.intern-qualified? (array-ref remap (+ source-count 1)))
        (ci.intern-dotted? (array-ref remap (+ source-count 2)))
        (ci.intern-generated-canonical-id? (array-ref remap (+ source-count 3)))))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-tests-ok?) : bool
    (let
      [_reset : unit (ci.intern-reset!)]
      [alpha : i64 (ci.intern "alpha")]
      [module-id : i64 (ci.intern "module")]
      [base-id : i64 (ci.intern "base")]
      [root-module-id : i64 (ci.intern "root/module")]
      [dotted-source : i64 (ci.intern "base.Item")]
      [_opaque : i64 (ci.intern-generated-name "opaque/local")]
      [_qualified : i64
        (ci.intern-generated-qualified-name "module/base" module-id base-id)]
      [_dotted : i64
        (ci.intern-generated-dotted-name
          "base.Item.Next"
          base-id
          dotted-source
          (ci.intern-dotted-tail-id dotted-source))]
      [_canonical : i64 (ci.intern-generated-canonical-name "canonical")]
      [key : surface_identity.SurfaceIdentityKey (surface-identity-test-key)]
      [payload : surface_identity.SurfaceIdentityPayload
        (surface_identity.surface-identity-capture
          (surface-tests-shared-view key))]
      [source-count : i64 (array-length payload.source-names)]
      [identity-count : i64 (+ source-count (array-length payload.generated))]
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [pair-id : i64 (ci.intern-composite-pair-id module-id base-id)]
      [triple-id : i64 (ci.intern-composite-triple-id module-id base-id alpha)]
      [template-id : i64
        (cis.intern-template-source-identity-raw
          (cis.intern-structural-session-template-source-identity session alpha))]
      [fresh-local-id : i64
        (cis.intern-fresh-local-identity-raw
          (cis.intern-structural-session-fresh-local-identity session 7 alpha))]
      [macro-global-id : i64
        (surface-identity-test-macro-global-id session module-id alpha false)]
      [macro-global-root-id : i64
        (surface-identity-test-macro-global-id
          session
          root-module-id
          base-id
          true)]
      [macro-local-id : i64
        (surface-identity-test-macro-local-id
          session
          module-id
          base-id
          1536
          alpha)]
      [portable-pair : i64
        (surface_identity.surface-identity-portable-id
          session
          pair-id
          source-count
          identity-count)]
      [portable-triple : i64
        (surface_identity.surface-identity-portable-id
          session
          triple-id
          source-count
          identity-count)]
      [portable-template : i64
        (surface_identity.surface-identity-portable-id
          session
          template-id
          source-count
          identity-count)]
      [portable-fresh-local : i64
        (surface_identity.surface-identity-portable-id
          session
          fresh-local-id
          source-count
          identity-count)]
      [portable-macro-global : i64
        (surface_identity.surface-identity-portable-id
          session
          macro-global-id
          source-count
          identity-count)]
      [portable-macro-global-root : i64
        (surface_identity.surface-identity-portable-id
          session
          macro-global-root-id
          source-count
          identity-count)]
      [portable-macro-local : i64
        (surface_identity.surface-identity-portable-id
          session
          macro-local-id
          source-count
          identity-count)]
      (if (not (= alpha 0))
        false
        (match (surface_identity.surface-identity-encode
          (surface-tests-shared-view payload))
          [(Err _) false]
          [(Ok bytes)
            (let
              [copy : (__tl_dyn-array u8)
                (surface-identity-test-copy-bytes
                  (surface-tests-shared-view bytes))]
              (ci.intern-reset!)
              (let
                [unrelated : i64 (ci.intern "unrelated")]
                (match (surface_identity.surface-identity-hydrate bytes key)
                  [(Err _) false]
                  [(KeyMismatch _) false]
                  [(Ok hydration)
                    (let
                      [remap : (__tl_dyn-array i64)
                        (surface-tests-shared-view hydration.remap)]
                      [mapped-module : i64 (array-ref remap 1)]
                      [mapped-base : i64 (array-ref remap 2)]
                      [mapped-alpha : i64 (array-ref remap 0)]
                      [mapped-root-module : i64 (array-ref remap 3)]
                      [hydrated-intern-state : ci.InternCompatState
                        (ci.intern-compat-state-capture-active)]
                      [hydrated-session : cis.InternStructuralSessionHandle
                        (cis.intern-structural-session-handle-from-source-names
                          (ci.intern-source-name-session-handle-from-state
                            hydrated-intern-state))]
                      (and
                        (= unrelated 0)
                        (surface-identity-remap-test-ok?
                          hydration
                          source-count
                          (array-length payload.generated))
                        (=
                          (surface_identity.surface-identity-resolve-portable-id
                            hydrated-session
                            portable-pair
                            remap)
                          (ci.intern-composite-pair-id
                            mapped-module
                            mapped-base))
                        (=
                          (surface_identity.surface-identity-resolve-portable-id
                            hydrated-session
                            portable-triple
                            remap)
                          (ci.intern-composite-triple-id
                            mapped-module
                            mapped-base
                            mapped-alpha))
                        (=
                          (surface_identity.surface-identity-resolve-portable-id
                            hydrated-session
                            portable-template
                            remap)
                          (cis.intern-template-source-identity-raw
                            (cis.intern-structural-session-template-source-identity
                              hydrated-session
                              mapped-alpha)))
                        (=
                          (surface_identity.surface-identity-resolve-portable-id
                            hydrated-session
                            portable-fresh-local
                            remap)
                          (cis.intern-fresh-local-identity-raw
                            (cis.intern-structural-session-fresh-local-identity
                              hydrated-session
                              7
                              mapped-alpha)))
                        (=
                          (surface_identity.surface-identity-resolve-portable-id
                            hydrated-session
                            portable-macro-global
                            remap)
                          (surface-identity-test-macro-global-id
                            hydrated-session
                            mapped-module
                            mapped-alpha
                            false))
                        (=
                          (surface_identity.surface-identity-resolve-portable-id
                            hydrated-session
                            portable-macro-global-root
                            remap)
                          (surface-identity-test-macro-global-id
                            hydrated-session
                            mapped-root-module
                            mapped-base
                            true))
                        (=
                          (surface_identity.surface-identity-resolve-portable-id
                            hydrated-session
                            portable-macro-local
                            remap)
                          (surface-identity-test-macro-local-id
                            hydrated-session
                            mapped-module
                            mapped-base
                            1536
                            mapped-alpha))
                        (match (surface_identity.surface-identity-decode copy)
                          [(Err _) false]
                          [(Ok decoded)
                            (surface_identity.surface-identity-key-eq?
                              decoded.key
                              key)])))])))])))))

(cfg
  compiler-surface-selftest
  (define (main) : i64
    (if (surface-identity-tests-ok?)
      42
      1)))

(cfg
  compiler-surface-selftest
  (define (surface-ast-decl-meta-roundtrip-ok?
    [meta : ast.AstDeclMeta]
    [comptime? : bool]
    [expected-markers : i64]) : bool
    (let
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [structural-session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [context : codec.SurfaceAstWriteContext
        (codec.surface-ast-write-context-new structural-session 0 0)]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (surface_ast.surface-ast-write-decl-meta! (&mut out) (&mut context) meta)
      (let
        [bytes : (__tl_dyn-array u8)
          (byte_buf_core.byte-buf-builder-finish-array (& out))]
        [byte-count : i64 (array-length bytes)]
        [reader : codec.SurfaceAstReader
          (codec.surface-ast-reader-new
            bytes
            structural-session
            (__tl_make-array i64 0))]
        [before : arena.ArenaMark (arena.mark)]
        [decoded : ast.AstDeclMeta
          (surface_ast.surface-ast-read-decl-meta! (&mut reader))]
        [after : arena.ArenaMark (arena.mark)]
        (and
          (codec.surface-ast-reader-valid? (& reader))
          (= (codec.surface-ast-reader-offset (& reader)) byte-count)
          (or comptime? (!= expected-markers 0) (arena.mark-eq? before after))
          (match (__tl-box-place decoded.value)
            [(Runtime markers)
              (and (= markers expected-markers) (not comptime?))]
            [(Comptime _ markers) (and (= markers expected-markers) comptime?)]))))))

;; `(slice 3 _ & _)` keeps its rest flag and its items through tag 7.
(cfg
  compiler-surface-selftest
  (define (surface-ast-slice-pattern-roundtrip-ok?) : bool
    (let
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [structural-session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [context : codec.SurfaceAstWriteContext
        (codec.surface-ast-write-context-new structural-session 0 0)]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      [items : ast.AstPatternList
        (ast.ast-pattern-cons
          (& (Literal (Int 3 "3")))
          (&
            (ast.ast-pattern-cons
              (& (Wildcard))
              (&
                (ast.ast-pattern-cons
                  (& (Wildcard))
                  (& (ast.ast-pattern-list-new)))))))]
      (expr_codec.surface-ast-write-pattern!
        (&mut out)
        (&mut context)
        (ast.ast-pat-slice items true))
      (let
        [bytes : (__tl_dyn-array u8)
          (byte_buf_core.byte-buf-builder-finish-array (& out))]
        [byte-count : i64 (array-length bytes)]
        [reader : codec.SurfaceAstReader
          (codec.surface-ast-reader-new
            bytes
            structural-session
            (__tl_make-array i64 0))]
        [decoded : ast.AstPattern
          (expr_codec.surface-ast-read-pattern! (&mut reader))]
        (and
          (codec.surface-ast-reader-valid? (& reader))
          (= (codec.surface-ast-reader-offset (& reader)) byte-count)
          (match decoded
            [(Slice decoded-items has-rest)
              (let
                [list : ast.AstPatternList (deref decoded-items)]
                (and
                  has-rest
                  (= list.len 3)
                  (match (ast.ast-pattern-list-get
                    (& list)
                    0
                    (ast.ast-pattern-fallback))
                    [(Literal (Int 3 _)) true]
                    [_ false])))]
            [_ false]))))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-decl-meta-invalid-flags-ok?) : bool
    (let
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [structural-session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (codec.surface-ast-write-i64! (&mut out) 0)
      (codec.surface-ast-write-i64! (&mut out) 4)
      (let
        [reader : codec.SurfaceAstReader
          (codec.surface-ast-reader-new
            (byte_buf_core.byte-buf-builder-finish-array (& out))
            structural-session
            (__tl_make-array i64 0))]
        (surface_ast.surface-ast-read-decl-meta! (&mut reader))
        (not (codec.surface-ast-reader-valid? (& reader)))))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-c-function-reference-decode-ok? [signature : i64]) : bool
    (let
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [context : codec.SurfaceAstWriteContext
        (codec.surface-ast-write-context-new session 0 0)]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (codec.surface-ast-write-i64! (&mut out) surface_ast.surface-ast-magic)
      (codec.surface-ast-write-i64!
        (&mut out)
        surface_ast.surface-ast-schema-version)
      (codec.surface-ast-write-i64! (&mut out) 0)
      (codec.surface-ast-write-i64! (&mut out) 3)
      (codec.surface-ast-write-i64! (&mut out) 0)
      (codec.surface-ast-write-type! (&mut out) (&mut context) I64)
      (codec.surface-ast-write-type!
        (&mut out)
        (&mut context)
        (Func (box (ast.ast-type-list-new)) 0))
      (codec.surface-ast-write-type!
        (&mut out)
        (&mut context)
        (CFunc signature NonNull))
      ;; Empty declaration, path, module, and seen lists.
      (codec.surface-ast-write-i64! (&mut out) 0)
      (codec.surface-ast-write-i64! (&mut out) 0)
      (codec.surface-ast-write-i64! (&mut out) 0)
      (codec.surface-ast-write-i64! (&mut out) 0)
      (match (surface_ast.surface-ast-decode
        (byte_buf_core.byte-buf-builder-finish-array (& out))
        session
        (__tl_make-array i64 0)
        (ast.ast-node-pool-context-new-with-capacities 4 1))
        [(Ok _) (= signature 1)]
        [(Err message)
          (and
            (not (= signature 1))
            (surface_identity.surface-identity-string-eq?
              message
              "surface ast: C function signature must reference a function type"))]))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-old-schema-rejected?) : bool
    (let
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [structural-session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (codec.surface-ast-write-i64! (&mut out) surface_ast.surface-ast-magic)
      (codec.surface-ast-write-i64! (&mut out) 9)
      (codec.surface-ast-write-i64! (&mut out) 0)
      (codec.surface-ast-write-i64! (&mut out) 0)
      (codec.surface-ast-write-i64! (&mut out) 0)
      (match (surface_ast.surface-ast-decode
        (byte_buf_core.byte-buf-builder-finish-array (& out))
        structural-session
        (__tl_make-array i64 0)
        (ast.ast-node-pool-context-new-with-capacities 1 1))
        [(Err _) true]
        [(Ok _) false]))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-struct-repr-roundtrip-ok? [repr : ast.AstStructRepr]) : bool
    (let
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [structural-session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (surface_ast.surface-ast-write-struct-repr!
        (&mut out)
        (ast.ast-global-shared-view repr))
      (let
        [reader : codec.SurfaceAstReader
          (codec.surface-ast-reader-new
            (byte_buf_core.byte-buf-builder-finish-array (& out))
            structural-session
            (__tl_make-array i64 0))]
        [decoded : ast.AstStructRepr
          (surface_ast.surface-ast-read-struct-repr! (&mut reader))]
        (and
          (codec.surface-ast-reader-valid? (& reader))
          (= (ast.ast-struct-repr-c? decoded) (ast.ast-struct-repr-c? repr))
          (=
            (ast.ast-struct-repr-declared-align decoded)
            (ast.ast-struct-repr-declared-align repr))
          (=
            (ast.ast-struct-repr-field-declared-align decoded 0)
            (ast.ast-struct-repr-field-declared-align repr 0))
          (=
            (ast.ast-struct-repr-field-declared-align decoded 2)
            (ast.ast-struct-repr-field-declared-align repr 2)))))))

;; Every extern ABI the codec writes reads back as itself, and consumes exactly
;; its bytes. `TypeLisp` (tag 3, #8485) is written whenever a package that has
;; dependencies is itself archived: its frontend AST holds the externs its
;; loader synthesized for them.
(cfg
  compiler-surface-selftest
  (define (surface-ast-extern-abi-roundtrip-ok? [abi : ast.AstExternAbi]) : bool
    (let
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [structural-session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [context : codec.SurfaceAstWriteContext
        (codec.surface-ast-write-context-new structural-session 0 0)]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (surface_ast.surface-ast-write-extern-abi!
        (&mut out)
        (&mut context)
        (ast.ast-global-shared-view abi))
      (let
        [bytes : (__tl_dyn-array u8)
          (byte_buf_core.byte-buf-builder-finish-array (& out))]
        [byte-count : i64 (array-length bytes)]
        [reader : codec.SurfaceAstReader
          (codec.surface-ast-reader-new
            bytes
            structural-session
            (__tl_make-array i64 0))]
        [decoded : ast.AstExternAbi
          (surface_ast.surface-ast-read-extern-abi! (&mut reader))]
        (and
          (codec.surface-ast-reader-valid? (& reader))
          (= (codec.surface-ast-reader-offset (& reader)) byte-count)
          (ast.ast-extern-abi-eq? (& decoded) (& abi)))))))

;; A tag past the last ABI fails the reader rather than decoding as any ABI.
(cfg
  compiler-surface-selftest
  (define (surface-ast-extern-abi-unknown-tag-rejected?) : bool
    (let
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [structural-session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (codec.surface-ast-write-i64! (&mut out) 4)
      (let
        [reader : codec.SurfaceAstReader
          (codec.surface-ast-reader-new
            (byte_buf_core.byte-buf-builder-finish-array (& out))
            structural-session
            (__tl_make-array i64 0))]
        [_decoded : ast.AstExternAbi
          (surface_ast.surface-ast-read-extern-abi! (&mut reader))]
        (not (codec.surface-ast-reader-valid? (& reader)))))))

;; A decoded declared alignment must be absent (0) or a power of two within
;; the parser's range, and a field list must end at a declared value; anything
;; else fails the reader instead of reaching layout.
(cfg
  compiler-surface-selftest
  (define (surface-ast-declared-align-rejected?
    [tag : i64]
    [align : i64]
    [field-count : i64]
    [field-align : i64]) : bool
    (let
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [structural-session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (when (>= tag 0) (codec.surface-ast-write-i64! (&mut out) tag))
      (codec.surface-ast-write-i64! (&mut out) align)
      (when
        (>= tag 0)
        (begin
          (codec.surface-ast-write-i64! (&mut out) field-count)
          (when
            (> field-count 0)
            (codec.surface-ast-write-i64! (&mut out) field-align))))
      (let
        [reader : codec.SurfaceAstReader
          (codec.surface-ast-reader-new
            (byte_buf_core.byte-buf-builder-finish-array (& out))
            structural-session
            (__tl_make-array i64 0))]
        (if (>= tag 0)
          (surface_ast.surface-ast-read-struct-repr! (&mut reader))
          (begin
            (surface_ast.surface-ast-read-declared-align! (&mut reader))
            ast.AstStructRepr.Default))
        (not (codec.surface-ast-reader-valid? (& reader)))))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-declared-align-tests-ok?) : bool
    (and
      (surface-ast-struct-repr-roundtrip-ok? Default)
      (surface-ast-struct-repr-roundtrip-ok? (ast.ast-struct-repr-c))
      (surface-ast-struct-repr-roundtrip-ok? (C 1 (ast.ast-no-field-aligns)))
      (surface-ast-struct-repr-roundtrip-ok? (C 4096 (ast.ast-no-field-aligns)))
      (surface-ast-struct-repr-roundtrip-ok?
        (ast.ast-struct-repr-with-field-align
          (C 32 (ast.ast-no-field-aligns))
          2
          16))
      (surface-ast-declared-align-rejected? 1 24 0 0)
      (surface-ast-declared-align-rejected? 1 8192 0 0)
      (surface-ast-declared-align-rejected? 1 -8 0 0)
      ;; A field value outside the range, and a list ending in an absent
      ;; entry, which the parser never produces.
      (surface-ast-declared-align-rejected? 1 0 1 3)
      (surface-ast-declared-align-rejected? 1 0 1 0)
      (surface-ast-declared-align-rejected? -1 3 0 0)
      (surface-ast-declared-align-rejected? -1 -1 0 0))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-while-body-roundtrip-ok?) : bool
    (let
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [context : codec.SurfaceAstWriteContext
        (codec.surface-ast-write-context-new session 0 0)]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      [body : ast.AstExprList
        (ast.ast-expr-cons
          4
          (& (ast.ast-expr-cons 5 (& (ast.ast-expr-list-new)))))]
      (expr_codec.surface-ast-write-expr!
        (&mut out)
        (&mut context)
        (ast.AstExpr.While 3 body))
      (let
        [bytes : (__tl_dyn-array u8)
          (byte_buf_core.byte-buf-builder-finish-array (& out))]
        [byte-count : i64 (array-length bytes)]
        [reader : codec.SurfaceAstReader
          (codec.surface-ast-reader-new bytes session (__tl_make-array i64 0))]
        [decoded : ast.AstExpr
          (expr_codec.surface-ast-read-expr! (&mut reader))]
        (and
          (codec.surface-ast-reader-valid? (& reader))
          (= (codec.surface-ast-reader-offset (& reader)) byte-count)
          (match decoded
            [(While condition forms)
              (and
                (= condition 3)
                (= forms.len 2)
                (= (ast.ast-expr-list-get (& forms) 0 -1) 4)
                (= (ast.ast-expr-list-get (& forms) 1 -1) 5))]
            [_ false]))))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-decl-meta-tests-ok?) : bool
    (and
      (surface-ast-while-body-roundtrip-ok?)
      (surface-ast-decl-meta-roundtrip-ok?
        (ast.ast-decl-meta-runtime-shared-view)
        false
        0)
      (surface-ast-decl-meta-roundtrip-ok?
        (ast.AstDeclMeta (box (ast.AstDeclMetaValue.Runtime 1)))
        false
        1)
      (surface-ast-decl-meta-roundtrip-ok?
        (ast.AstDeclMeta (box (ast.AstDeclMetaValue.Comptime No 1)))
        true
        1)
      (surface-ast-decl-meta-roundtrip-ok?
        (ast.AstDeclMeta (box (ast.AstDeclMetaValue.Runtime 2)))
        false
        2)
      (surface-ast-decl-meta-roundtrip-ok?
        (ast.AstDeclMeta (box (ast.AstDeclMetaValue.Comptime No 3)))
        true
        3)
      (surface-ast-decl-meta-invalid-flags-ok?)
      (surface-ast-extern-abi-roundtrip-ok? C)
      (surface-ast-extern-abi-roundtrip-ok? CVarargsOpen)
      (surface-ast-extern-abi-roundtrip-ok? TypeLisp)
      (surface-ast-extern-abi-unknown-tag-rejected?)
      (surface-ast-slice-pattern-roundtrip-ok?)
      (surface-ast-declared-align-tests-ok?)
      (surface-ast-old-schema-rejected?)
      (surface-ast-c-function-reference-decode-ok? 1)
      (surface-ast-c-function-reference-decode-ok? 0)
      (surface-ast-c-function-reference-decode-ok? 2)
      (surface-ast-c-function-reference-decode-ok? 3)
      (surface-ast-c-function-reference-decode-ok? 9223372036854775807))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-byte-array-eq?
    [left : (__tl_dyn-array u8)]
    [right : (__tl_dyn-array u8)]) : bool
    (let
      [count : i64 (array-length left)]
      [index : i64 0]
      (if (not (= count (array-length right)))
        false
        (begin
          (while (and
            (< index count)
            (= (array-ref left index) (array-ref right index)))
            (set! index (+ index 1)))
          (= index count))))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-encode-deterministic
    [structural-session : cis.InternStructuralSessionHandle]
    [decls : ast.AstDeclList]
    [paths : ast.AstDeclPathList]
    [modules : (& modules ast.AstDeclModuleList)]
    [seen : sym_i64_env.SymI64Env]
    [source-pools : ast.AstNodePoolContext]
    [source-count : i64]
    [identity-count : i64]) : surface_ast.ResultSurfaceAstBytes
    (let
      [first
        (try
          (surface_ast.surface-ast-encode
            structural-session
            (owned_view.compiler-owned-shared-view decls)
            (owned_view.compiler-owned-shared-view paths)
            modules
            seen
            source-pools
            source-count
            identity-count))]
      [second
        (try
          (surface_ast.surface-ast-encode
            structural-session
            decls
            paths
            modules
            seen
            source-pools
            source-count
            identity-count))]
      (if (surface-ast-byte-array-eq?
        (owned_view.compiler-owned-shared-view first)
        second)
        (Ok first)
        (Err "surface ast: repeated encoding mismatch")))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-borrowed-slice-type-ok?
    [pools : ast.AstNodePoolContext]
    [ty : ast.AstType]) : bool
    (match ty
      [(Ref region inner)
        (and
          (surface_identity.surface-identity-string-eq?
            (ci.intern-str region)
            "borrow-region")
          (match (ast.ast-node-pool-context-type-get pools inner)
            [(Slice elem)
              (match (ast.ast-node-pool-context-type-get pools elem)
                [(I64) true]
                [_ false])]
            [_ false]))]
      [_ false])))

(cfg
  compiler-surface-selftest
  (define (surface-ast-int-node-value?
    [pools : (& pools ast.AstNodePoolContext)]
    [id : i64]
    [expected : i64]) : bool
    (match (ast.ast-node-pool-context-expr-get pools id)
      [(Literal (Int value _)) (= value expected)]
      [_ false])))

(cfg
  compiler-surface-selftest
  (define (surface-ast-hydrated-tuple-set-ok? [pools : ast.AstNodePoolContext]) : bool
    (let
      [id : i64 0]
      [ok : bool false]
      ;; Compaction may change ids when declarations reach nodes in a
      ;; different order from construction. Inspect the retained shape rather
      ;; than comparing producer-generation ids.
      (while (and (not ok) (< id (ast.ast-node-pool-context-expr-len pools)))
        (match (ast.ast-node-pool-context-expr-get pools id)
          [(StructSet target field value)
            (set!
              ok
              (and
                (ast.ast-tuple-set-field-id? field)
                (= (ast.ast-tuple-set-index-from-field-id field) 3)
                (surface-ast-int-node-value? pools target 20)
                (surface-ast-int-node-value? pools value 22)))]
          [_ unit])
        (set! id (+ id 1)))
      ok)))

(cfg
  compiler-surface-selftest
  (define (surface-ast-hydrated-spmd-compact-ok?
    [pools : ast.AstNodePoolContext]) : bool
    (let
      [id : i64 0]
      [ok : bool false]
      (while (and (not ok) (< id (ast.ast-node-pool-context-expr-len pools)))
        (match (ast.ast-node-pool-context-expr-get pools id)
          [(SpmdCompact compact-box)
            (match (deref compact-box)
              [(Compact index (I64) start end slot (I64) init keep body)
                (set!
                  ok
                  (and
                    (surface_identity.surface-identity-string-eq?
                      (ci.intern-str index)
                      "compact-index")
                    (surface_identity.surface-identity-string-eq?
                      (ci.intern-str slot)
                      "compact-slot")
                    (surface-ast-int-node-value? (& pools) start 20)
                    (surface-ast-int-node-value? (& pools) end 22)
                    (surface-ast-int-node-value? (& pools) init 20)
                    (match (ast.ast-node-pool-context-expr-get pools keep)
                      [(Literal (Bool true)) true]
                      [_ false])
                    (match (ast.ast-node-pool-context-expr-get pools body)
                      [(Literal (Unit)) true]
                      [_ false])))]
              [_ unit])]
          [_ unit])
        (set! id (+ id 1)))
      ok)))

(cfg
  compiler-surface-selftest
  (define (surface-ast-hydrated-foreach-active-ok?
    [pools : ast.AstNodePoolContext]) : bool
    (let
      [id : i64 0]
      [ok : bool false]
      (while (and (not ok) (< id (ast.ast-node-pool-context-expr-len pools)))
        (match (ast.ast-node-pool-context-expr-get pools id)
          [(ForeachActive lane body)
            (set!
              ok
              (and
                (surface_identity.surface-identity-string-eq?
                  (ci.intern-str lane)
                  "active-lane")
                (match (ast.ast-node-pool-context-expr-get pools body)
                  [(LaneValue value)
                    (surface-ast-int-node-value? (& pools) value 20)]
                  [_ false])))]
          [_ unit])
        (set! id (+ id 1)))
      ok)))

(cfg
  compiler-surface-selftest
  (define (surface-ast-push-int [pools : ast.AstNodePoolContext] [value : i64]) : i64
    (ast.ast-node-pool-context-expr-push
      pools
      (Literal (ast.ast-lit-int value)))))

;; A rank-2 domain keeps both coordinate names and all four bounds in binding
;; order through the codec.
(cfg
  compiler-surface-selftest
  (define (surface-ast-hydrated-foreach2-ok? [pools : ast.AstNodePoolContext]) : bool
    (let
      [id : i64 0]
      [ok : bool false]
      (while (and (not ok) (< id (ast.ast-node-pool-context-expr-len pools)))
        (match (ast.ast-node-pool-context-expr-get pools id)
          [(Foreach payload)
            (match (deref payload)
              [(Foreach2
                  outer
                  (I64)
                  outer-start
                  outer-end
                  inner
                  (I64)
                  inner-start
                  inner-end
                  body)
                (set!
                  ok
                  (and
                    (surface_identity.surface-identity-string-eq?
                      (ci.intern-str outer)
                      "domain-row")
                    (surface_identity.surface-identity-string-eq?
                      (ci.intern-str inner)
                      "domain-column")
                    (surface-ast-int-node-value? (& pools) outer-start 41)
                    (surface-ast-int-node-value? (& pools) outer-end 42)
                    (surface-ast-int-node-value? (& pools) inner-start 43)
                    (surface-ast-int-node-value? (& pools) inner-end 44)
                    (match (ast.ast-node-pool-context-expr-get pools body)
                      [(Literal (Unit)) true]
                      [_ false])))]
              [_ unit])]
          [_ unit])
        (set! id (+ id 1)))
      ok)))

(cfg
  compiler-surface-selftest
  (define (surface-ast-invalidate-param-ok?
    [pools : ast.AstNodePoolContext]
    [params : (& params ast.AstParamList)]
    [index : i64]) : bool
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(Param name (Invalidate lifetime inner) false)
        (and
          (surface_identity.surface-identity-string-eq?
            (ci.intern-str name)
            "invalidated-owner")
          (surface_identity.surface-identity-string-eq?
            (ci.intern-str lifetime)
            "invalidated-region")
          (match (ast.ast-node-pool-context-type-get pools inner)
            [(I64) true]
            [_ false]))]
      [_ false])))

(cfg
  compiler-surface-selftest
  (define (surface-ast-c-function-param-ok?
    [pools : ast.AstNodePoolContext]
    [params : (& params ast.AstParamList)]
    [index : i64]
    [mode : ast.AstCFunctionMode]) : bool
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(Param _ (CFunc signature actual-mode) false)
        (and
          (ast.ast-c-function-mode-eq? actual-mode mode)
          (match (ast.ast-node-pool-context-type-get pools signature)
            [(Func args result)
              (let
                [items : ast.AstTypeList (deref args)]
                (and
                  (= (ast.ast-type-list-len (& items)) 1)
                  (match (ast.ast-node-pool-context-type-get
                    pools
                    (ast.ast-type-list-get (& items) 0 -1))
                    [(I64) true]
                    [_ false])
                  (match (ast.ast-node-pool-context-type-get pools result)
                    [(Bool) true]
                    [_ false])))]
            [_ false]))]
      [_ false])))

(cfg
  compiler-surface-selftest
  (define (surface-ast-tests-ok?) : bool
    (let
      [_reset : unit (ci.intern-reset!)]
      [module-id : i64 (ci.intern "test.module")]
      [path-id : i64 (ci.intern "test.tl")]
      [fn-id : i64 (ci.intern "main")]
      [macro-id : i64 (ci.intern "catalog")]
      [test-id : i64 (ci.intern "metadata-test")]
      [struct-id : i64 (ci.intern "MarkedRecord")]
      [field-id : i64 (ci.intern "count")]
      [macro-param-id : i64 (ci.intern "T")]
      [macro-type-id : i64 (ci.intern "type")]
      [compact-index-id : i64 (ci.intern "compact-index")]
      [compact-slot-id : i64 (ci.intern "compact-slot")]
      [active-lane-id : i64 (ci.intern "active-lane")]
      [domain-row-id : i64 (ci.intern "domain-row")]
      [domain-column-id : i64 (ci.intern "domain-column")]
      [kind-i64-id : i64 (ci.intern "i64")]
      [kind-struct-id : i64 (ci.intern "struct")]
      [kind-type-var-id : i64 (ci.intern "type-var")]
      [source-pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 8 8)]
      [left : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (Literal (Int 20 "20")))]
      [right : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (Literal (Int 22 "22")))]
      [sum-inner : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (Binary Add left right))]
      [sum : i64
        (ast.ast-expr-spanned-with-pools
          source-pools
          sum-inner
          (ast.ast-source-span 4 2 4 9))]
      [sum-outer : i64
        (ast.ast-expr-spanned-with-pools
          source-pools
          sum
          (ast.ast-source-span 40 1 40 8))]
      [borrow-lifetime-id : i64 (ci.intern "borrow-region")]
      [view-param-id : i64 (ci.intern "view")]
      [nullable-param-id : i64 (ci.intern "nullable-entry")]
      [nonnull-param-id : i64 (ci.intern "nonnull-entry")]
      [unsafe-nullable-param-id : i64 (ci.intern "unsafe-nullable-entry")]
      [unsafe-nonnull-param-id : i64 (ci.intern "unsafe-nonnull-entry")]
      [invalidate-param-id : i64 (ci.intern "invalidated-owner")]
      [invalidate-lifetime-id : i64 (ci.intern "invalidated-region")]
      [c-signature : i64
        (ast.ast-node-pool-context-type-push
          source-pools
          (ast.ast-ty-func-with-pools
            source-pools
            (ast.ast-type-cons-with-pools
              source-pools
              (& (I64))
              (& (ast.ast-type-list-new)))
            (& (Bool))))]
      [slice-i64 : ast.AstType
        (ast.ast-ty-slice-with-pools source-pools (& (I64)))]
      [borrowed-slice : ast.AstType
        (ast.ast-ty-ref-with-pools
          source-pools
          borrow-lifetime-id
          (& slice-i64))]
      [body : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (Borrow
            false
            (ast.ast-borrow-lifetime-to-id (Named borrow-lifetime-id))
            sum))]
      [tuple-set : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (StructSet left (ast.ast-tuple-set-field-id-from-index 3) right))]
      [compact-keep : i64
        (ast.ast-node-pool-context-expr-push source-pools (Literal (Bool true)))]
      [compact-body : i64
        (ast.ast-node-pool-context-expr-push source-pools (Literal Unit))]
      [compact : i64
        (ast.ast-expr-spmd-compact-id-with-pools
          source-pools
          compact-index-id
          (I64)
          left
          right
          compact-slot-id
          (I64)
          left
          compact-keep
          compact-body)]
      [active : i64
        (ast.ast-expr-foreach-active-with-pools
          source-pools
          active-lane-id
          (ast.ast-expr-lane-value-with-pools source-pools left))]
      [domain : i64
        (ast.ast-expr-foreach2-id-with-pools
          source-pools
          domain-row-id
          (I64)
          (surface-ast-push-int source-pools 41)
          (surface-ast-push-int source-pools 42)
          domain-column-id
          (I64)
          (surface-ast-push-int source-pools 43)
          (surface-ast-push-int source-pools 44)
          (ast.ast-node-pool-context-expr-push source-pools (Literal Unit)))]
      [body-items : (__tl_dyn-array i64) (__tl_make-array i64 5)]
      [combined-body : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (Begin
            (ast.AstExprList
              (owned_view.compiler-owned-shared-view body-items)
              5)))]
      [macro-type-kinds : ast.AstMacroTypeKindList
        (ast.ast-macro-type-kind-list-with-length 3)]
      [macro-param-slots : (__tl_dyn-array ast.AstMacroParam)
        (__tl_make-array ast.AstMacroParam 1)]
      [view-param-slots : (__tl_dyn-array ast.AstParam)
        (__tl_make-array ast.AstParam 6)]
      [decl-slots : (__tl_dyn-array ast.AstDecl)
        (__tl_make-array ast.AstDecl 4)]
      [path-slots : (__tl_dyn-array String) (__tl_make-array String 4)]
      [owner-slots : (__tl_dyn-array i64) (__tl_make-array i64 8)]
      [module-slots : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      [key-modules : (__tl_dyn-array String) (__tl_make-array String 1)]
      (set! (array-ref body-items 0) body)
      (set! (array-ref body-items 1) tuple-set)
      (set! (array-ref body-items 2) compact)
      (set! (array-ref body-items 3) active)
      (set! (array-ref body-items 4) domain)
      (ast.ast-macro-type-kind-list-set! (&mut macro-type-kinds) 0 kind-i64-id)
      (ast.ast-macro-type-kind-list-set!
        (&mut macro-type-kinds)
        1
        kind-struct-id)
      (ast.ast-macro-type-kind-list-set!
        (&mut macro-type-kinds)
        2
        kind-type-var-id)
      (set!
        (array-ref macro-param-slots 0)
        (ast.AstMacroParam.Param
          macro-param-id
          (Var macro-type-id)
          false
          macro-type-kinds))
      (set!
        (array-ref view-param-slots 0)
        (ast.AstParam.Param
          view-param-id
          (owned_view.compiler-owned-shared-view borrowed-slice)
          false))
      (set!
        (array-ref view-param-slots 1)
        (ast.AstParam.Param
          nullable-param-id
          (CFunc c-signature Nullable)
          false))
      (set!
        (array-ref view-param-slots 2)
        (ast.AstParam.Param nonnull-param-id (CFunc c-signature NonNull) false))
      (set!
        (array-ref view-param-slots 3)
        (ast.AstParam.Param
          unsafe-nullable-param-id
          (CFunc c-signature UnsafeNullable)
          false))
      (set!
        (array-ref view-param-slots 4)
        (ast.AstParam.Param
          unsafe-nonnull-param-id
          (CFunc c-signature UnsafeNonNull)
          false))
      (set!
        (array-ref view-param-slots 5)
        (ast.AstParam.Param
          invalidate-param-id
          (ast.ast-ty-invalidate-with-pools
            source-pools
            invalidate-lifetime-id
            (& (I64)))
          false))
      (set!
        (array-ref decl-slots 0)
        (ast.AstDecl.DefFn
          (ast.ast-decl-meta-runtime-shared-view)
          fn-id
          (ast.AstParamList view-param-slots 6)
          borrowed-slice
          combined-body
          No))
      (set!
        (array-ref decl-slots 1)
        (ast.AstDecl.DefMacro
          (ast.ast-decl-meta-runtime-shared-view)
          macro-id
          (ast.AstMacroParamList macro-param-slots 1)
          Unit
          sum-outer))
      (set!
        (array-ref decl-slots 2)
        (ast.ast-decl-test-metadata-id
          test-id
          compact-body
          (ast.ast-test-metadata-new (Some "surface reason") true)
          (ast.ast-source-span 50 2 50 32)))
      (set!
        (array-ref decl-slots 3)
        (ast.ast-decl-with-aggregate-markers
          (ast.ast-decl-def-struct-id
            struct-id
            (ast.ast-struct-repr-with-field-align
              (C 16 (ast.ast-no-field-aligns))
              0
              8)
            No
            (ast.ast-field-def-cons
              (& (Def (ci.intern-syntax-id-from-raw field-id) I64 No))
              (& (ast.ast-field-def-list-new))))
          1))
      (set! (array-ref path-slots 0) "test.tl")
      (set! (array-ref path-slots 1) "test.tl")
      (set! (array-ref path-slots 2) "test.tl")
      (set! (array-ref path-slots 3) "test.tl")
      (set! (array-ref owner-slots 0) module-id)
      (set! (array-ref owner-slots 1) module-id)
      (set! (array-ref owner-slots 2) module-id)
      (set! (array-ref owner-slots 3) module-id)
      (set! (array-ref owner-slots 4) path-id)
      (set! (array-ref owner-slots 5) path-id)
      (set! (array-ref owner-slots 6) path-id)
      (set! (array-ref owner-slots 7) path-id)
      (set! (array-ref module-slots 0) module-id)
      (set! (array-ref module-slots 1) module-id)
      (set! (array-ref module-slots 2) module-id)
      (set! (array-ref module-slots 3) module-id)
      (set! (array-ref key-modules 0) "test.tl")
      (let
        [decls : ast.AstDeclList (ast.AstDeclList decl-slots 0 4 true)]
        [paths : ast.AstDeclPathList
          (ast.AstDeclPathList path-slots owner-slots 0 4 true)]
        [modules : ast.AstDeclModuleList
          (ast.AstDeclModuleList module-slots 0 4 true)]
        [seen : sym_i64_env.SymI64Env
          (sym_i64_env.sym-i64-bind-id (sym_i64_env.sym-i64-empty) path-id 1)]
        [key : surface_identity.SurfaceIdentityKey
          (surface_identity.SurfaceIdentityKey
            "test.package"
            key-modules
            "source-hash"
            "compiler-build"
            "host")]
        [identity-payload : surface_identity.SurfaceIdentityPayload
          (surface_identity.surface-identity-capture
            (owned_view.compiler-owned-shared-view key))]
        [source-count : i64 (array-length identity-payload.source-names)]
        [identity-count : i64
          (+ source-count (array-length identity-payload.generated))]
        [intern-state : ci.InternCompatState
          (ci.intern-compat-state-capture-active)]
        [structural-session : cis.InternStructuralSessionHandle
          (cis.intern-structural-session-handle-from-source-names
            (ci.intern-source-name-session-handle-from-state intern-state))]
        (match (surface_identity.surface-identity-encode identity-payload)
          [(Err _) false]
          [(Ok identity-bytes)
            (match (surface-ast-encode-deterministic
              structural-session
              decls
              paths
              modules
              seen
              source-pools
              source-count
              identity-count)
              [(Err _) false]
              [(Ok ast-bytes)
                (ci.intern-reset!)
                (let
                  [_unrelated : i64 (ci.intern "unrelated")]
                  (match (surface_identity.surface-identity-hydrate
                    identity-bytes
                    key)
                    [(Err _) false]
                    [(KeyMismatch _) false]
                    [(Ok identity-hydration)
                      (let
                        [dest-pools : ast.AstNodePoolContext
                          (ast.ast-node-pool-context-new-with-capacities 8 8)]
                        [hydrated-intern-state : ci.InternCompatState
                          (ci.intern-compat-state-capture-active)]
                        [hydrated-session : cis.InternStructuralSessionHandle
                          (cis.intern-structural-session-handle-from-source-names
                            (ci.intern-source-name-session-handle-from-state
                              hydrated-intern-state))]
                        (match (surface_ast.surface-ast-decode
                          ast-bytes
                          hydrated-session
                          identity-hydration.remap
                          dest-pools)
                          [(Err _) false]
                          [(Ok hydration)
                            (and
                              (=
                                (ast.ast-node-pool-context-expr-len
                                  hydration.pools)
                                19)
                              (ast.ast-node-pool-context-expr-span-oracle-ok?
                                hydration.pools)
                              (= (ast.ast-decl-list-len (& hydration.decls)) 4)
                              (surface_identity.surface-identity-string-eq?
                                (ci.intern-str
                                  (ast.ast-decl-path-list-owner-id
                                    (& hydration.paths)
                                    0
                                    -1))
                                "test.module")
                              (surface_identity.surface-identity-string-eq?
                                (ci.intern-str
                                  (ast.ast-decl-path-list-provenance-id
                                    (& hydration.paths)
                                    0
                                    -1))
                                "test.tl")
                              (match (owned_view.compiler-owned-array-element-shared-view
                                hydration.decls.slots
                                0)
                                [(DefFn
                                    _
                                    hydrated-name
                                    hydrated-params
                                    hydrated-ret
                                    hydrated-body
                                    _)
                                  (and
                                    (surface_identity.surface-identity-string-eq?
                                      (ci.intern-str hydrated-name)
                                      "main")
                                    (=
                                      (ast.ast-param-list-len
                                        (& hydrated-params))
                                      6)
                                    (surface-ast-invalidate-param-ok?
                                      (owned_view.compiler-owned-shared-view
                                        hydration.pools)
                                      (& hydrated-params)
                                      5)
                                    (surface-ast-c-function-param-ok?
                                      (owned_view.compiler-owned-shared-view
                                        hydration.pools)
                                      (& hydrated-params)
                                      1
                                      Nullable)
                                    (surface-ast-c-function-param-ok?
                                      (owned_view.compiler-owned-shared-view
                                        hydration.pools)
                                      (& hydrated-params)
                                      2
                                      NonNull)
                                    (surface-ast-c-function-param-ok?
                                      (owned_view.compiler-owned-shared-view
                                        hydration.pools)
                                      (& hydrated-params)
                                      3
                                      UnsafeNullable)
                                    (surface-ast-c-function-param-ok?
                                      (owned_view.compiler-owned-shared-view
                                        hydration.pools)
                                      (& hydrated-params)
                                      4
                                      UnsafeNonNull)
                                    (surface-ast-borrowed-slice-type-ok?
                                      (owned_view.compiler-owned-shared-view
                                        hydration.pools)
                                      hydrated-ret)
                                    (match (ast.ast-param-list-get
                                      (& hydrated-params)
                                      0
                                      (ast.ast-param-fallback))
                                      [(Param
                                          hydrated-param-name
                                          hydrated-param-ty
                                          false)
                                        (and
                                          (surface_identity.surface-identity-string-eq?
                                            (ci.intern-str hydrated-param-name)
                                            "view")
                                          (surface-ast-borrowed-slice-type-ok?
                                            (owned_view.compiler-owned-shared-view
                                              hydration.pools)
                                            hydrated-param-ty))]
                                      [_ false])
                                    (match (ast.ast-node-pool-context-expr-get
                                      hydration.pools
                                      hydrated-body)
                                      [(Begin hydrated-items)
                                        (match (ast.ast-node-pool-context-expr-get
                                          hydration.pools
                                          (ast.ast-expr-list-get
                                            hydrated-items
                                            0
                                            0))
                                          [(Borrow
                                              mutable
                                              lifetime-id
                                              hydrated-sum)
                                            (and
                                              (not mutable)
                                              (match (ast.ast-borrow-lifetime-from-id
                                                lifetime-id)
                                                [(Named name)
                                                  (surface_identity.surface-identity-string-eq?
                                                    (ci.intern-str name)
                                                    "borrow-region")]
                                                [_ false])
                                              (match (ast.ast-node-pool-context-expr-get
                                                hydration.pools
                                                hydrated-sum)
                                                [(Spanned
                                                    hydrated-inner
                                                    hydrated-span)
                                                  (and
                                                    (=
                                                      (ast.ast-source-span-start-line
                                                        hydrated-span)
                                                      4)
                                                    (match (ast.ast-node-pool-context-expr-span-oracle
                                                      hydration.pools
                                                      hydrated-sum)
                                                      [(CanonicalMatch) true]
                                                      [_ false])
                                                    (match (ast.ast-node-pool-context-expr-get
                                                      hydration.pools
                                                      hydrated-inner)
                                                      [(Binary op _ _)
                                                        (match op
                                                          [(Add) true]
                                                          [_ false])]
                                                      [_ false]))]
                                                [_ false]))]
                                          [_ false])]
                                      [_ false]))]
                                [_ false])
                              (match (owned_view.compiler-owned-array-element-shared-view
                                hydration.decls.slots
                                1)
                                [(DefMacro
                                    _
                                    hydrated-macro-name
                                    hydrated-params
                                    _
                                    hydrated-macro-body)
                                  (and
                                    (surface_identity.surface-identity-string-eq?
                                      (ci.intern-str hydrated-macro-name)
                                      "catalog")
                                    (=
                                      (ast.ast-macro-param-list-len
                                        (& hydrated-params))
                                      1)
                                    (match (ast.ast-node-pool-context-expr-span-oracle
                                      hydration.pools
                                      hydrated-macro-body)
                                      [(ReSpanMatch) true]
                                      [_ false])
                                    (match (ast.ast-node-pool-context-expr-view-span
                                      hydration.pools
                                      hydrated-macro-body)
                                      [(Some span)
                                        (=
                                          (ast.ast-source-span-start-line span)
                                          40)]
                                      [_ false])
                                    (match (ast.ast-macro-param-list-get
                                      (& hydrated-params)
                                      0
                                      (ast.ast-macro-param-fallback))
                                      [(Param
                                          hydrated-param-name
                                          (Var hydrated-type-name)
                                          false
                                          hydrated-kinds)
                                        (and
                                          (surface_identity.surface-identity-string-eq?
                                            (ci.intern-str hydrated-param-name)
                                            "T")
                                          (surface_identity.surface-identity-string-eq?
                                            (ci.intern-str hydrated-type-name)
                                            "type")
                                          (=
                                            (ast.ast-macro-type-kind-list-len
                                              (& hydrated-kinds))
                                            3)
                                          (surface_identity.surface-identity-string-eq?
                                            (ci.intern-str
                                              (ast.ast-macro-type-kind-list-get
                                                (& hydrated-kinds)
                                                0
                                                0))
                                            "i64")
                                          (surface_identity.surface-identity-string-eq?
                                            (ci.intern-str
                                              (ast.ast-macro-type-kind-list-get
                                                (& hydrated-kinds)
                                                1
                                                0))
                                            "struct")
                                          (surface_identity.surface-identity-string-eq?
                                            (ci.intern-str
                                              (ast.ast-macro-type-kind-list-get
                                                (& hydrated-kinds)
                                                2
                                                0))
                                            "type-var"))]
                                      [_ false]))]
                                [_ false])
                              (match (owned_view.compiler-owned-array-element-shared-view
                                hydration.decls.slots
                                2)
                                [(Test
                                    hydrated-test-name
                                    _
                                    hydrated-metadata
                                    hydrated-test-span)
                                  (and
                                    (surface_identity.surface-identity-string-eq?
                                      (ci.intern-str hydrated-test-name)
                                      "metadata-test")
                                    (=
                                      (ast.ast-source-span-start-line
                                        hydrated-test-span)
                                      50)
                                    (ast.ast-test-metadata-slow?
                                      hydrated-metadata)
                                    (match (ast.ast-test-metadata-ignore-reason
                                      hydrated-metadata)
                                      [(Some reason)
                                        (surface_identity.surface-identity-string-eq?
                                          reason
                                          "surface reason")]
                                      [_ false]))]
                                [_ false])
                              (let
                                [decl (ast.ast-decl-list-ref hydration.decls 3)]
                                (ast.ast-decl-must-use? decl))
                              (match (ast.ast-decl-list-ref hydration.decls 3)
                                [(DefStruct _ _ hydrated-repr _ _)
                                  (and
                                    (=
                                      (ast.ast-struct-repr-declared-align
                                        hydrated-repr)
                                      16)
                                    (=
                                      (ast.ast-struct-repr-field-declared-align
                                        hydrated-repr
                                        0)
                                      8))]
                                [_ false])
                              (surface-ast-hydrated-tuple-set-ok?
                                (owned_view.compiler-owned-shared-view
                                  hydration.pools))
                              (surface-ast-hydrated-spmd-compact-ok?
                                (owned_view.compiler-owned-shared-view
                                  hydration.pools))
                              (surface-ast-hydrated-foreach-active-ok?
                                (owned_view.compiler-owned-shared-view
                                  hydration.pools))
                              (surface-ast-hydrated-foreach2-ok?
                                hydration.pools))]))]))])])))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-selftest-main) : i64
    (if (and (surface-ast-decl-meta-tests-ok?) (surface-ast-tests-ok?))
      42
      1)))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-i64-array-eq?
    [left : (__tl_dyn-array i64)]
    [right : (__tl_dyn-array i64)]) : bool
    (let
      [index : i64 0]
      [ok : bool (= (array-length left) (array-length right))]
      (while (and ok (< index (array-length left)))
        (if (= (array-ref left index) (array-ref right index))
          (set! index (+ index 1))
          (set! ok false)))
      ok)))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-eq?
    [left : surface_facts.SurfaceTypecheckFacts]
    [right : surface_facts.SurfaceTypecheckFacts]) : bool
    (and
      (= left.macro-prefix-decl-count right.macro-prefix-decl-count)
      (= left.prefix-decl-count right.prefix-decl-count)
      (= left.summary-values right.summary-values)
      (= left.summary-functions right.summary-functions)
      (= left.summary-externs right.summary-externs)
      (surface-typecheck-facts-i64-array-eq?
        left.clone-decl-keys
        right.clone-decl-keys)
      (surface-typecheck-facts-i64-array-eq?
        left.clone-root-keys
        right.clone-root-keys)
      (surface-typecheck-facts-i64-array-eq?
        left.clone-call-indices
        right.clone-call-indices))))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-test-fragment-one) : surface_facts.SurfaceTypecheckFacts
    (surface_facts.SurfaceTypecheckFacts
      2
      3
      5
      7
      11
      (__tl_make-array 10 10 11)
      (__tl_make-array 20 21 22)
      (__tl_make-array 0 0 2))))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-test-fragment-two) : surface_facts.SurfaceTypecheckFacts
    (surface_facts.SurfaceTypecheckFacts
      4
      5
      13
      17
      19
      (__tl_make-array 30 31)
      (__tl_make-array 40 41)
      (__tl_make-array 0 1))))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-tests-ok?) : bool
    (let
      [first : surface_facts.SurfaceTypecheckFacts
        (surface-typecheck-facts-test-fragment-one)]
      [second : surface_facts.SurfaceTypecheckFacts
        (surface-typecheck-facts-test-fragment-two)]
      [bad-order : surface_facts.SurfaceTypecheckFacts
        (surface_facts.SurfaceTypecheckFacts
          1
          1
          0
          0
          0
          (__tl_make-array 50 50)
          (__tl_make-array 60 61)
          (__tl_make-array 1 0))]
      [bad-group : surface_facts.SurfaceTypecheckFacts
        (surface_facts.SurfaceTypecheckFacts
          1
          1
          0
          0
          0
          (__tl_make-array 50 51)
          (__tl_make-array 60 61)
          (__tl_make-array 0 0))]
      [builder : surface_facts.SurfaceTypecheckFactsBuilder
        (surface_facts.surface-typecheck-facts-builder-empty)]
      [ok : bool true]
      (if (or
        (not (surface_facts.surface-typecheck-facts-valid? first))
        (surface_facts.surface-typecheck-facts-valid? bad-order)
        (surface_facts.surface-typecheck-facts-valid? bad-group))
        (set! ok false)
        unit)
      (surface_facts.surface-typecheck-facts-clear!)
      (if (surface_facts.surface-typecheck-facts-publish!
        (surface_facts.surface-facts-shared-view first))
        unit
        (set! ok false))
      ;; Invalid publication is atomic: the active first fragment survives.
      (if (surface_facts.surface-typecheck-facts-publish!
        (surface_facts.surface-facts-shared-view bad-order))
        (set! ok false)
        unit)
      (if (and
        (surface_facts.surface-typecheck-facts-active?)
        (surface-typecheck-facts-eq?
          (surface_facts.surface-typecheck-facts-current)
          (surface_facts.surface-facts-shared-view first)))
        unit
        (set! ok false))
      (surface_facts.surface-typecheck-facts-clear!)
      (if (surface_facts.surface-typecheck-facts-active?)
        (set! ok false)
        unit)
      ;; A cleared publication can be reused without retaining stale facts.
      (if (surface_facts.surface-typecheck-facts-publish!
        (surface_facts.surface-facts-shared-view first))
        unit
        (set! ok false))
      (if (and
        (surface_facts.surface-typecheck-facts-active?)
        (surface-typecheck-facts-eq?
          (surface_facts.surface-typecheck-facts-current)
          (surface_facts.surface-facts-shared-view first)))
        unit
        (set! ok false))
      (surface_facts.surface-typecheck-facts-clear!)
      (match (surface_facts.surface-typecheck-facts-builder-append
        (surface_facts.surface-facts-shared-view builder)
        first)
        [(Err _) (set! ok false)]
        [(Ok next) (set! builder next)])
      ;; A rejected fragment leaves the completed prefix reusable.
      (match (surface_facts.surface-typecheck-facts-builder-append
        (surface_facts.surface-facts-shared-view builder)
        bad-order)
        [(Err _) unit]
        [(Ok _) (set! ok false)])
      (match (surface_facts.surface-typecheck-facts-builder-append
        (surface_facts.surface-facts-shared-view builder)
        second)
        [(Err _) (set! ok false)]
        [(Ok next) (set! builder next)])
      (match (surface_facts.surface-typecheck-facts-builder-finish builder)
        [(Err _) (set! ok false)]
        [(Ok composed)
          (if (and
            (= composed.macro-prefix-decl-count 6)
            (= composed.prefix-decl-count 8)
            (= composed.summary-values 18)
            (= composed.summary-functions 24)
            (= composed.summary-externs 30)
            (surface-typecheck-facts-i64-array-eq?
              (surface_facts.surface-facts-shared-view
                composed.clone-call-indices)
              (__tl_make-array 0 0 2 3 4)))
            unit
            (set! ok false))
          (if (surface_facts.surface-typecheck-facts-publish-composite!
            composed)
            unit
            (set! ok false))
          (if (and
            (surface_facts.surface-typecheck-facts-rebase-composite-macro-prefix!
              9)
            (surface_facts.surface-typecheck-facts-rebase-composite-typecheck-prefix!
              11
              20
              30
              40)
            (=
              (surface_facts.surface-typecheck-facts-current).macro-prefix-decl-count
              9)
            (=
              (surface_facts.surface-typecheck-facts-current).prefix-decl-count
              11)
            (=
              (surface_facts.surface-typecheck-facts-current).summary-values
              20)
            (surface_facts.surface-typecheck-facts-composite-active?))
            unit
            (set! ok false))])
      (surface_facts.surface-typecheck-facts-clear!)
      ok)))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-selftest-main) : i64
    (if (surface-typecheck-facts-tests-ok?)
      42
      1)))

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

(cfg
  compiler-surface-selftest
  (define (compiler-surface-hydrate-test-payloads) : ResultCompilerSurfaceHydrateTestPayloads
    (let
      [_reset : unit (ci.intern-reset!)]
      [decl-id : i64 (ci.intern "decl")]
      [root-id : i64 (ci.intern "root")]
      [package-modules : (__tl_dyn-array String) (__tl_make-array String 1)]
      [source-names : (__tl_dyn-array String) (__tl_make-array String 2)]
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [structural-session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
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
          (owned_view.compiler-owned-shared-view key)
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
      [identity-bytes
        (try (surface_identity.surface-identity-encode identity-payload))]
      [ast-bytes
        (try
          (surface_ast.surface-ast-encode
            structural-session
            decls
            paths
            decl-modules
            (sym_i64_env.sym-i64-empty)
            source-pools
            2
            2))]
      [fact-one-bytes
        (try
          (surface_facts.surface-typecheck-facts-encode
            first
            structural-session
            2
            2))]
      [fact-two-bytes
        (try
          (surface_facts.surface-typecheck-facts-encode
            second
            structural-session
            2
            2))]
      (Ok
        (CompilerSurfaceHydrateTestPayloads
          identity-bytes
          ast-bytes
          fact-one-bytes
          fact-two-bytes
          key)))))

(cfg
  compiler-surface-selftest
  (define (compiler-surface-hydrate-tests-ok?) : bool
    (match (compiler-surface-hydrate-test-payloads)
      [(Err _) false]
      [(Ok payloads)
        (let
          [prior : surface_facts.SurfaceTypecheckFacts
            (surface-typecheck-facts-test-fragment-one)]
          [first-hydrated : surface_facts.SurfaceTypecheckFacts
            (surface_facts.surface-typecheck-facts-empty)]
          [second-hydrated : surface_facts.SurfaceTypecheckFacts
            (surface_facts.surface-typecheck-facts-empty)]
          [pools : ast.AstNodePoolContext
            (ast.ast-node-pool-context-new-with-capacities 1 1)]
          [intern-state : ci.InternCompatState
            (ci.intern-compat-state-capture-active)]
          [structural-session : cis.InternStructuralSessionHandle
            (cis.intern-structural-session-handle-from-source-names
              (ci.intern-source-name-session-handle-from-state intern-state))]
          [ok : bool true]
          (surface_facts.surface-typecheck-facts-clear!)
          (if (surface_facts.surface-typecheck-facts-publish!
            (owned_view.compiler-owned-shared-view prior))
            unit
            (set! ok false))
          (match (surface_hydrate.compiler-surface-hydrate-payloads
            (owned_view.compiler-owned-shared-view payloads.identity-bytes)
            (owned_view.compiler-owned-shared-view payloads.ast-bytes)
            payloads.fact-one-bytes
            payloads.key
            structural-session
            pools)
            [(Ok hydration) (set! first-hydrated hydration.facts)]
            [_ (set! ok false)])
          ;; A complete successful hydration is still pure: only the explicit
          ;; publisher may replace the previously active facts.
          (if (and
            (surface_facts.surface-typecheck-facts-active?)
            (surface-typecheck-facts-eq?
              (surface_facts.surface-typecheck-facts-current)
              prior))
            unit
            (set! ok false))
          (if (surface_facts.surface-typecheck-facts-publish!
            (owned_view.compiler-owned-shared-view first-hydrated))
            unit
            (set! ok false))
          ;; Decode a malformed second fact payload after a valid first one.
          ;; The explicitly published first hydration must remain unchanged.
          (match (surface_hydrate.compiler-surface-hydrate-payloads
            (owned_view.compiler-owned-shared-view payloads.identity-bytes)
            (owned_view.compiler-owned-shared-view payloads.ast-bytes)
            (__tl_make-array u8 0)
            payloads.key
            structural-session
            pools)
            [(Err _) unit]
            [_ (set! ok false)])
          (if (and
            (surface_facts.surface-typecheck-facts-active?)
            (surface-typecheck-facts-eq?
              (surface_facts.surface-typecheck-facts-current)
              first-hydrated))
            unit
            (set! ok false))
          (match (surface_hydrate.compiler-surface-hydrate-payloads
            payloads.identity-bytes
            payloads.ast-bytes
            payloads.fact-two-bytes
            payloads.key
            structural-session
            pools)
            [(Ok hydration)
              (set! second-hydrated hydration.facts)
              (if (surface_facts.surface-typecheck-facts-publish!
                (owned_view.compiler-owned-shared-view second-hydrated))
                unit
                (set! ok false))]
            [_ (set! ok false)])
          (match (surface_hydrate.compiler-surface-hydrate
            (__tl_make-array u8 0)
            payloads.key
            structural-session
            pools)
            [(Missing) unit]
            [_ (set! ok false)])
          (if (and
            (surface_facts.surface-typecheck-facts-active?)
            (surface-typecheck-facts-eq?
              (surface_facts.surface-typecheck-facts-current)
              second-hydrated))
            unit
            (set! ok false))
          (surface_facts.surface-typecheck-facts-clear!)
          ok)])))

(cfg
  compiler-surface-selftest
  (define (compiler-surface-hydrate-selftest-main) : i64
    (if (compiler-surface-hydrate-tests-ok?)
      42
      1)))