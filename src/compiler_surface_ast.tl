;; compiler_surface_ast.tl - package-agnostic serialized frontend AST surface.
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import stdlib.arena))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import stdlib.byte_buf_core))
(import compiler_ast_types as ast)

;; lint-allow: unused-import -- used only by the cfg-gated surface codecs.
(import compiler_intern as ci)
(import compiler_intern_state as cis)

;; lint-allow: unused-import -- used only by the cfg-gated surface codecs.
(import compiler_surface_identity as surface_identity)
(import compiler_surface_ast_codec_core as codec)
(import compiler_surface_ast_expr as expr_codec)
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_owned_view as owned_view))
(import sym_i64_env)

(defstruct SurfaceAstHydration
  (decls ast.AstDeclList)
  (paths ast.AstDeclPathList)
  (modules ast.AstDeclModuleList)
  (seen sym_i64_env.SymI64Env)
  (pools ast.AstNodePoolContext))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (defenum ResultSurfaceAstBytes
    (Ok (__tl_dyn-array u8))
    (Err String)))

(defenum ResultSurfaceAstHydration
  (Ok SurfaceAstHydration)
  (Err String))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-invalid-identity-message
    [session : cis.InternStructuralSessionHandle]
    [name : i64]) : String
    (cond
      [(ci.intern-composite-pair-id? name)
        "surface ast: composite pair contains an identity outside the package table"]
      [(ci.intern-composite-triple-id? name)
        "surface ast: composite triple contains an identity outside the package table"]
      [(match (cis.intern-structural-session-template-source-record-for-raw
          session
          name)
          [(cis.InternMaybeTemplateSourceRecord.Some _) true]
          [(cis.InternMaybeTemplateSourceRecord.No) false])
        "surface ast: template-source identity is not portable"]
      [(match (cis.intern-structural-session-fresh-local-record-for-raw
          session
          name)
          [(cis.InternMaybeFreshLocalRecord.Some _) true]
          [(cis.InternMaybeFreshLocalRecord.No) false])
        "surface ast: fresh-local identity is not portable"]
      [(ci.intern-generated-id-active? name)
        "surface ast: generated identity is outside the captured package table"]
      [(ci.intern-renderable-id? name)
        "surface ast: source identity is outside the captured package table"]
      [else "surface ast: encountered an unknown non-portable identity"])))

(define surface-ast-magic : i64
  3544386045472754772)
(define surface-ast-schema-version : i64
  ;; 13: `AstStructRepr.C` carries the declared struct `(:align N)` value (0
  ;; when absent) and the per-field values up to the last declared one (#7445).
  ;;
  ;; 12: AstType tag 39 carries a lifetime-invalidating parameter (#6670).
  ;;
  ;; 11: AstExpr tags 87 and 88 add ForeachActive and LaneValue.
  ;;
  ;; 10: AstType tag 38 carries a C callable signature and nullability/effect mode.
  ;;
  ;; 9: AstDecl metadata carries aggregate marker flags.
  ;;
  ;; 8: AstDecl.Test carries boxed ignore/slow declaration metadata.
  ;;
  ;; 7: AstExpr tag 86 adds the boxed SpmdCompact payload.
  ;;
  ;; 6: identity references use surface-identity schema 2, whose template-source
  ;; and fresh-local records are capacity-independent portable components.
  ;;
  ;; Expression-span sidecars do not change schema 5.  The canonical and sparse
  ;; ReSpan records are generation-owned indexes derived deterministically while
  ;; the decoder replays the still-required tag-0 AstExpr.Spanned rows through
  ;; the destination pool's central push API.  They contain no additional wire
  ;; data; malformed node references continue to fail in the existing decoder
  ;; validation before a sidecar record can be observed.
  ;;
  ;; 5: declaration paths encode physical provenance separately from effective
  ;; module ownership so hydrated dependency macros retain their package key.
  ;;
  ;; 4: imports no longer encode the removed legacy string-path kind.
  ;;
  ;; 3: macro type-kind constraints use a count followed by dense ordered name
  ;; ids instead of recursive Nil/Cons wire tags.
  ;;
  ;; 2: eight AstExpr variants carry AstTypeIds instead of inline AstTypes, so
  ;; their wire tags now reference the serialized type pool. `Init` similarly
  ;; carries an AstMaybeTypeId sentinel. `Borrow` also narrowed in memory, but
  ;; its wire representation remains the portable AstBorrowLifetime encoding:
  ;; named lifetimes must not serialize producer-generation intern ids.
  ;;
  ;; The payload is git-hash keyed and fail-closed (`compiler_driver_core.tl`
  ;; requires TlciProducerIdentityAdmission.ExactMatch and degrades to re-parse),
  ;; so this is a deployment invariant rather than a format-compatibility one --
  ;; but the version still moves whenever the encoding shape does.
  13)

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-macro-type-kind-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [items : (& items ast.AstMacroTypeKindList)]) : unit
    (let
      [count : i64 (ast.ast-macro-type-kind-list-len items)]
      [index : i64 0]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (codec.surface-ast-write-name!
              out
              context
              (ast.ast-macro-type-kind-list-get items index 0))
            (set! index (+ index 1))))
        unit))))

(define (surface-ast-read-macro-type-kind-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstMacroTypeKindList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [out : ast.AstMacroTypeKindList
      (ast.ast-macro-type-kind-list-with-length count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (ast.ast-macro-type-kind-list-set!
            (&mut out)
            index
            (codec.surface-ast-read-name! reader))
          (set! index (+ index 1))))
      out)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-macro-param-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [params : ast.AstMacroParamList]) : unit
    (let
      [index : i64 0]
      [count : i64 params.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (ast.ast-array-shared-view params.slots index)
            [(ast.AstMacroParam.Param name ty variadic type-kinds)
              (begin
                (codec.surface-ast-write-name! out context name)
                (codec.surface-ast-write-type! out context ty)
                (codec.surface-ast-write-bool! out variadic)
                (surface-ast-write-macro-type-kind-list!
                  out
                  context
                  (& type-kinds)))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-macro-param-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstMacroParamList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstMacroParam)
      (__tl_make-array ast.AstMacroParam count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstMacroParam.Param
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-type! reader)
              (codec.surface-ast-read-bool! reader)
              (surface-ast-read-macro-type-kind-list! reader)))
          (set! index (+ index 1))))
      (ast.AstMacroParamList slots count))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-field-cleanup!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [cleanup : ast.AstFieldCleanup]) : unit
    (match cleanup
      [(ast.AstFieldCleanup.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstFieldCleanup.Fn name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name!
            out
            context
            (ci.intern-syntax-id-value name)))]
      [(ast.AstFieldCleanup.Owned) (codec.surface-ast-write-i64! out 2)])))

(define (surface-ast-read-field-cleanup!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstFieldCleanup
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstFieldCleanup.No]
      [(= tag 1)
        (ast.AstFieldCleanup.Fn
          (ci.intern-syntax-id-from-raw (codec.surface-ast-read-name! reader)))]
      [(= tag 2) ast.AstFieldCleanup.Owned]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid field cleanup")
          ast.AstFieldCleanup.No)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-field-def-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [fields : ast.AstFieldDefList]) : unit
    (let
      [index : i64 0]
      [count : i64 fields.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (ast.ast-array-shared-view fields.slots index)
            [(ast.AstFieldDef.Def name ty cleanup)
              (begin
                (codec.surface-ast-write-name!
                  out
                  context
                  (ci.intern-syntax-id-value name))
                (codec.surface-ast-write-type! out context ty)
                (surface-ast-write-field-cleanup! out context cleanup))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-field-def-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstFieldDefList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstFieldDef)
      (__tl_make-array ast.AstFieldDef count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstFieldDef.Def
              (ci.intern-syntax-id-from-raw
                (codec.surface-ast-read-name! reader))
              (codec.surface-ast-read-type! reader)
              (surface-ast-read-field-cleanup! reader)))
          (set! index (+ index 1))))
      (ast.AstFieldDefList slots count))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-struct-repr!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [repr : ast.AstStructRepr]) : unit
    (match repr
      [(ast.AstStructRepr.Default) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstStructRepr.C align fields)
        (let
          [index : i64 0]
          (begin
            (codec.surface-ast-write-i64! out 1)
            (codec.surface-ast-write-i64! out align)
            (codec.surface-ast-write-i64! out fields.len)
            (while (< index fields.len)
              (begin
                (codec.surface-ast-write-i64!
                  out
                  (ast.ast-field-align-list-get (& fields) index 0))
                (set! index (+ index 1))))))])))

;; A declared `(:align N)` value: 0 when absent, otherwise a power of two
;; within the parser's accepted range.
(define (surface-ast-read-declared-align!
  [reader : (&mut reader codec.SurfaceAstReader)]) : i64
  (let
    [align : i64 (codec.surface-ast-read-i64! reader)]
    (if (ast.ast-declared-align-encodable? align)
      align
      (begin
        (codec.surface-ast-reader-fail!
          reader
          "surface ast: invalid declared alignment")
        0))))

;; Field alignments name fields by index, so the list cannot outrun them.
(define (surface-ast-check-field-aligns!
  [reader : (&mut reader codec.SurfaceAstReader)]
  [repr : (& repr ast.AstStructRepr)]
  [fields : (& fields ast.AstFieldDefList)]) : unit
  (match repr
    [(ast.AstStructRepr.C _ aligns)
      (when
        (> aligns.len fields.len)
        (codec.surface-ast-reader-fail!
          reader
          "surface ast: field alignments exceed the struct's fields"))]
    [(ast.AstStructRepr.Default) unit]))

(define (surface-ast-read-struct-repr!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstStructRepr
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (if (= tag 0)
      ast.AstStructRepr.Default
      (if (= tag 1)
        (let
          [align : i64 (surface-ast-read-declared-align! reader)]
          [count : i64 (codec.surface-ast-read-count! reader)]
          [fields : ast.AstFieldAlignList
            (ast.ast-field-align-list-with-capacity count)]
          [index : i64 0]
          (begin
            (while (< index count)
              (begin
                (ast.ast-field-align-list-push
                  (&mut fields)
                  (surface-ast-read-declared-align! reader))
                (set! index (+ index 1))))
            ;; The parser ends the list at the last declared field alignment.
            (when
              (and
                (> count 0)
                (= (ast.ast-field-align-list-get (& fields) (- count 1) 0) 0))
              (codec.surface-ast-reader-fail!
                reader
                "surface ast: field alignment list ends in an absent entry"))
            (ast.AstStructRepr.C align fields)))
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid struct repr")
          ast.AstStructRepr.Default)))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-extern-abi!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [abi : ast.AstExternAbi]) : unit
    (match abi
      [(ast.AstExternAbi.C) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstExternAbi.CVarargsOpen) (codec.surface-ast-write-i64! out 1)]
      [(ast.AstExternAbi.CVarargsTyped ty)
        (begin
          (codec.surface-ast-write-i64! out 2)
          (codec.surface-ast-write-type! out context ty))])))

(define (surface-ast-read-extern-abi!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstExternAbi
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstExternAbi.C]
      [(= tag 1) ast.AstExternAbi.CVarargsOpen]
      [(= tag 2)
        (ast.AstExternAbi.CVarargsTyped (codec.surface-ast-read-type! reader))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid extern abi")
          ast.AstExternAbi.C)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-extern-kind!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [kind : ast.AstExternKind]) : unit
    (codec.surface-ast-write-i64!
      out
      (match kind
        [(ast.AstExternKind.Value) 0]
        [(ast.AstExternKind.Function) 1]))))

(define (surface-ast-read-extern-kind!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstExternKind
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (if (= tag 0)
      ast.AstExternKind.Value
      (if (= tag 1)
        ast.AstExternKind.Function
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid extern kind")
          ast.AstExternKind.Value)))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-extern-link-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [links : ast.AstExternLinkInputList]) : unit
    (let
      [index : i64 0]
      [count : i64 links.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (ast.ast-array-shared-view links.slots index)
            [(ast.AstExternLinkInput.Lib text)
              (begin
                (codec.surface-ast-write-i64! out 0)
                (codec.surface-ast-write-string! out text))]
            [(ast.AstExternLinkInput.Search text)
              (begin
                (codec.surface-ast-write-i64! out 1)
                (codec.surface-ast-write-string! out text))]
            [(ast.AstExternLinkInput.Arg text)
              (begin
                (codec.surface-ast-write-i64! out 2)
                (codec.surface-ast-write-string! out text))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-extern-link-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstExternLinkInputList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstExternLinkInput)
      (__tl_make-array ast.AstExternLinkInput count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [tag : i64 (codec.surface-ast-read-i64! reader)]
          [text : String (codec.surface-ast-read-string! reader)]
          (begin
            (set!
              (array-ref slots index)
              (cond
                [(= tag 0) (ast.AstExternLinkInput.Lib text)]
                [(= tag 1) (ast.AstExternLinkInput.Search text)]
                [(= tag 2) (ast.AstExternLinkInput.Arg text)]
                [else
                  (begin
                    (codec.surface-ast-reader-fail!
                      reader
                      "surface ast: invalid extern link input")
                    (ast.AstExternLinkInput.Arg text))]))
            (set! index (+ index 1)))))
      (ast.AstExternLinkInputList slots count))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-spmd-param-class!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [value : ast.AstSpmdParamClass]) : unit
    (codec.surface-ast-write-i64!
      out
      (match value
        [(ast.AstSpmdParamClass.Uniform) 0]
        [(ast.AstSpmdParamClass.Varying) 1]))))

(define (surface-ast-read-spmd-param-class!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstSpmdParamClass
  (if (= (codec.surface-ast-read-i64! reader) 0)
    ast.AstSpmdParamClass.Uniform
    ast.AstSpmdParamClass.Varying))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-spmd-param-class-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [items : ast.AstSpmdParamClassList]) : unit
    (let
      [index : i64 0]
      [count : i64 items.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (surface-ast-write-spmd-param-class!
              out
              (array-ref items.slots index))
            (set! index (+ index 1))))))))

(define (surface-ast-read-spmd-param-class-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstSpmdParamClassList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstSpmdParamClass)
      (__tl_make-array ast.AstSpmdParamClass count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (surface-ast-read-spmd-param-class! reader))
          (set! index (+ index 1))))
      (ast.AstSpmdParamClassList slots count))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-spmd-result-class!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [value : ast.AstSpmdResultClass]) : unit
    (codec.surface-ast-write-i64!
      out
      (match value
        [(ast.AstSpmdResultClass.Unit) 0]
        [(ast.AstSpmdResultClass.Uniform) 1]
        [(ast.AstSpmdResultClass.Varying) 2]))))

(define (surface-ast-read-spmd-result-class!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstSpmdResultClass
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstSpmdResultClass.Unit]
      [(= tag 1) ast.AstSpmdResultClass.Uniform]
      [(= tag 2) ast.AstSpmdResultClass.Varying]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid spmd result class")
          ast.AstSpmdResultClass.Unit)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-spmd-specialization-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [items : ast.AstSpmdSpecializationList]) : unit
    (let
      [index : i64 0]
      [count : i64 items.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (let
            [item : ast.AstSpmdSpecialization
              (ast.ast-array-shared-view items.slots index)]
            (begin
              (codec.surface-ast-write-i64! out item.lanes)
              (surface-ast-write-spmd-param-class-list!
                out
                (owned_view.compiler-owned-box-shared-view item.args))
              (surface-ast-write-spmd-result-class! out item.result)
              (codec.surface-ast-write-i64! out item.index-param)
              (set! index (+ index 1)))))
        unit))))

(define (surface-ast-read-spmd-specialization-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstSpmdSpecializationList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstSpmdSpecialization)
      (__tl_make-array ast.AstSpmdSpecialization count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstSpmdSpecialization
              (codec.surface-ast-read-i64! reader)
              (box (surface-ast-read-spmd-param-class-list! reader))
              (surface-ast-read-spmd-result-class! reader)
              (codec.surface-ast-read-i64! reader)))
          (set! index (+ index 1))))
      (ast.AstSpmdSpecializationList slots count))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  ;; Surface AST names retain their existing i64 wire representation. Convert at
  ;; the codec edge so decoded linker/interface names are checked as renderable
  ;; before entering the nominal AST fields.
  (define (surface-ast-write-fn-metadata!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [metadata : ast.AstFnMetadata]) : unit
    (match metadata
      [(ast.AstFnMetadata.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstFnMetadata.Export name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context (ci.intern-id-value name)))]
      [(ast.AstFnMetadata.SpmdCallable items)
        (begin
          (codec.surface-ast-write-i64! out 2)
          (surface-ast-write-spmd-specialization-list! out (deref items)))])))

(define (surface-ast-read-fn-metadata!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstFnMetadata
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstFnMetadata.No]
      [(= tag 1)
        (ast.AstFnMetadata.Export
          (ci.intern-id-from-renderable (codec.surface-ast-read-name! reader)))]
      [(= tag 2)
        (ast.AstFnMetadata.SpmdCallable
          (box (surface-ast-read-spmd-specialization-list! reader)))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid function metadata")
          ast.AstFnMetadata.No)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-imported-spmd-specialization-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [items : ast.AstImportedSpmdSpecializationList]) : unit
    (let
      [index : i64 0]
      [count : i64 items.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (let
            [item : ast.AstImportedSpmdSpecialization
              (ast.ast-array-shared-view items.slots index)]
            (begin
              (codec.surface-ast-write-name!
                out
                context
                (ci.intern-id-value item.abi))
              (codec.surface-ast-write-name!
                out
                context
                (ci.intern-id-value item.backend))
              (codec.surface-ast-write-i64! out item.lanes)
              (codec.surface-ast-write-name!
                out
                context
                (ci.intern-id-value item.args))
              (codec.surface-ast-write-name!
                out
                context
                (ci.intern-id-value item.result))
              (codec.surface-ast-write-i64! out item.index-param)
              (codec.surface-ast-write-name!
                out
                context
                (ci.intern-id-value item.symbol))
              (set! index (+ index 1)))))
        unit))))

(define (surface-ast-read-imported-spmd-specialization-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstImportedSpmdSpecializationList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstImportedSpmdSpecialization)
      (__tl_make-array ast.AstImportedSpmdSpecialization count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstImportedSpmdSpecialization
              (ci.intern-id-from-renderable
                (codec.surface-ast-read-name! reader))
              (ci.intern-id-from-renderable
                (codec.surface-ast-read-name! reader))
              (codec.surface-ast-read-i64! reader)
              (ci.intern-id-from-renderable
                (codec.surface-ast-read-name! reader))
              (ci.intern-id-from-renderable
                (codec.surface-ast-read-name! reader))
              (codec.surface-ast-read-i64! reader)
              (ci.intern-id-from-renderable
                (codec.surface-ast-read-name! reader))))
          (set! index (+ index 1))))
      (ast.AstImportedSpmdSpecializationList slots count))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-imported-spmd-callable-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [items : ast.AstImportedSpmdCallableList]) : unit
    (let
      [index : i64 0]
      [count : i64 items.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (let
            [item : ast.AstImportedSpmdCallable
              (ast.ast-array-shared-view items.slots index)]
            (begin
              (codec.surface-ast-write-name!
                out
                context
                (ci.intern-id-value item.signature))
              (surface-ast-write-imported-spmd-specialization-list!
                out
                context
                item.specializations)
              (set! index (+ index 1)))))
        unit))))

(define (surface-ast-read-imported-spmd-callable-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstImportedSpmdCallableList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstImportedSpmdCallable)
      (__tl_make-array ast.AstImportedSpmdCallable count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstImportedSpmdCallable
              (ci.intern-id-from-renderable
                (codec.surface-ast-read-name! reader))
              (surface-ast-read-imported-spmd-specialization-list! reader)))
          (set! index (+ index 1))))
      (ast.AstImportedSpmdCallableList slots count))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-imported-spmd-metadata!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [metadata : ast.AstImportedSpmdMetadata]) : unit
    (match metadata
      [(ast.AstImportedSpmdMetadata.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstImportedSpmdMetadata.Package _ _ name callables)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context (ci.intern-id-value name))
          (surface-ast-write-imported-spmd-callable-list!
            out
            context
            (deref callables)))])))

(define (surface-ast-read-imported-spmd-metadata!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstImportedSpmdMetadata
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstImportedSpmdMetadata.No]
      [(= tag 1)
        (let
          [name : ci.InternId
            (ci.intern-id-from-renderable (codec.surface-ast-read-name! reader))]
          [callables : ast.AstImportedSpmdCallableList
            (surface-ast-read-imported-spmd-callable-list! reader)]
          (begin
            ;; Schema 8 carries the callable rows but not the validated owner
            ;; and version. Re-parse this source rather than hydrate an origin
            ;; that cannot satisfy the imported IR descriptor contract.
            (codec.surface-ast-reader-fail!
              reader
              "surface ast: imported SPMD metadata needs source validation")
            (ast.AstImportedSpmdMetadata.Package "" "" name (box callables))))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid imported spmd metadata")
          ast.AstImportedSpmdMetadata.No)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-extern-metadata!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [metadata : ast.AstExternMetadata]) : unit
    (match metadata
      [(ast.AstExternMetadata.Metadata abi symbol links flags imported)
        (begin
          (surface-ast-write-extern-abi! out context abi)
          (codec.surface-ast-write-name!
            out
            context
            (ci.intern-id-value symbol))
          (surface-ast-write-extern-link-list! out links)
          (codec.surface-ast-write-i64! out flags)
          (surface-ast-write-imported-spmd-metadata! out context imported))])))

(define (surface-ast-read-extern-metadata!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstExternMetadata
  (ast.AstExternMetadata.Metadata
    (surface-ast-read-extern-abi! reader)
    (ci.intern-id-from-renderable (codec.surface-ast-read-name! reader))
    (surface-ast-read-extern-link-list! reader)
    (codec.surface-ast-read-i64! reader)
    (surface-ast-read-imported-spmd-metadata! reader)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-variant-cleanup!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [cleanup : ast.AstVariantPayloadCleanup]) : unit
    (match cleanup
      [(ast.AstVariantPayloadCleanup.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstVariantPayloadCleanup.Fn name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name!
            out
            context
            (ci.intern-syntax-id-value name)))]
      [(ast.AstVariantPayloadCleanup.Owned)
        (codec.surface-ast-write-i64! out 2)])))

(define (surface-ast-read-variant-cleanup!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstVariantPayloadCleanup
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstVariantPayloadCleanup.No]
      [(= tag 1)
        (ast.AstVariantPayloadCleanup.Fn
          (ci.intern-syntax-id-from-raw (codec.surface-ast-read-name! reader)))]
      [(= tag 2) ast.AstVariantPayloadCleanup.Owned]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid variant cleanup")
          ast.AstVariantPayloadCleanup.No)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-variant-def-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [variants : ast.AstVariantDefList]) : unit
    (let
      [index : i64 0]
      [count : i64 variants.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (ast.ast-array-shared-view variants.slots index)
            [(ast.AstVariantDef.Def name fields cleanups)
              (let
                [cleanup-index : i64 0]
                (begin
                  (codec.surface-ast-write-name! out context name)
                  (codec.surface-ast-write-type-list! out fields)
                  (codec.surface-ast-write-i64! out cleanups.len)
                  (while (< cleanup-index cleanups.len)
                    (begin
                      (surface-ast-write-variant-cleanup!
                        out
                        context
                        (array-ref cleanups.slots cleanup-index))
                      (set! cleanup-index (+ cleanup-index 1))))))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-variant-def-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstVariantDefList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstVariantDef)
      (__tl_make-array ast.AstVariantDef count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [name : i64 (codec.surface-ast-read-name! reader)]
          [fields : ast.AstTypeList (codec.surface-ast-read-type-list! reader)]
          [cleanup-count : i64 (codec.surface-ast-read-count! reader)]
          [cleanup-slots : (__tl_dyn-array ast.AstVariantPayloadCleanup)
            (__tl_make-array ast.AstVariantPayloadCleanup cleanup-count)]
          [cleanup-index : i64 0]
          (begin
            (while (< cleanup-index cleanup-count)
              (begin
                (set!
                  (array-ref cleanup-slots cleanup-index)
                  (surface-ast-read-variant-cleanup! reader))
                (set! cleanup-index (+ cleanup-index 1))))
            (set!
              (array-ref slots index)
              (ast.AstVariantDef.Def
                name
                fields
                (ast.AstVariantPayloadCleanupList cleanup-slots cleanup-count)))
            (set! index (+ index 1)))))
      (ast.AstVariantDefList slots count))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-struct-cleanup!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [cleanup : ast.AstStructCleanup]) : unit
    (match cleanup
      [(ast.AstStructCleanup.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstStructCleanup.Fn name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name!
            out
            context
            (ci.intern-syntax-id-value name)))])))

(define (surface-ast-read-struct-cleanup!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstStructCleanup
  (if (= (codec.surface-ast-read-i64! reader) 0)
    ast.AstStructCleanup.No
    (ast.AstStructCleanup.Fn
      (ci.intern-syntax-id-from-raw (codec.surface-ast-read-name! reader)))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-enum-cleanup!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [cleanup : ast.AstEnumCleanup]) : unit
    (match cleanup
      [(ast.AstEnumCleanup.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstEnumCleanup.Fn name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name!
            out
            context
            (ci.intern-syntax-id-value name)))])))

(define (surface-ast-read-enum-cleanup!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstEnumCleanup
  (if (= (codec.surface-ast-read-i64! reader) 0)
    ast.AstEnumCleanup.No
    (ast.AstEnumCleanup.Fn
      (ci.intern-syntax-id-from-raw (codec.surface-ast-read-name! reader)))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-maybe-module-name!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [value : ast.AstMaybeModuleName]) : unit
    (match value
      [(ast.AstMaybeModuleName.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstMaybeModuleName.Some name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name))])))

(define (surface-ast-read-maybe-module-name!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstMaybeModuleName
  (if (= (codec.surface-ast-read-i64! reader) 0)
    ast.AstMaybeModuleName.No
    (ast.AstMaybeModuleName.Some (codec.surface-ast-read-name! reader))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-maybe-import-alias!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [value : ast.AstMaybeImportAlias]) : unit
    (match value
      [(ast.AstMaybeImportAlias.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstMaybeImportAlias.Some name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name))])))

(define (surface-ast-read-maybe-import-alias!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstMaybeImportAlias
  (if (= (codec.surface-ast-read-i64! reader) 0)
    ast.AstMaybeImportAlias.No
    (ast.AstMaybeImportAlias.Some (codec.surface-ast-read-name! reader))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-import-kind!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [kind : ast.AstImportKind]) : unit
    (match kind
      [(ast.AstImportKind.Module) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstImportKind.ModuleAll) (codec.surface-ast-write-i64! out 3)]
      [(ast.AstImportKind.ModuleItem item)
        (begin
          (codec.surface-ast-write-i64! out 4)
          (codec.surface-ast-write-name! out context item))]
      [(ast.AstImportKind.Macro call module-name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-i64! out call)
          (surface-ast-write-maybe-module-name! out context module-name))]
      [(ast.AstImportKind.MacroDecls call module-name)
        (begin
          (codec.surface-ast-write-i64! out 2)
          (codec.surface-ast-write-i64! out call)
          (surface-ast-write-maybe-module-name! out context module-name))])))

(define (surface-ast-read-import-kind!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstImportKind
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstImportKind.Module]
      [(= tag 1)
        (ast.AstImportKind.Macro
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-maybe-module-name! reader))]
      [(= tag 2)
        (ast.AstImportKind.MacroDecls
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-maybe-module-name! reader))]
      [(= tag 3) ast.AstImportKind.ModuleAll]
      [(= tag 4)
        (ast.AstImportKind.ModuleItem (codec.surface-ast-read-name! reader))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid import kind")
          ast.AstImportKind.Module)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-import-spec!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [spec : ast.AstImportSpec]) : unit
    (match spec
      [(ast.AstImportSpec.Spec kind path module-name alias span)
        (begin
          (surface-ast-write-import-kind! out context kind)
          (codec.surface-ast-write-string! out path)
          (surface-ast-write-maybe-module-name! out context module-name)
          (surface-ast-write-maybe-import-alias! out context alias)
          (codec.surface-ast-write-span! out (deref span)))])))

(define (surface-ast-read-import-spec!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstImportSpec
  (ast.AstImportSpec.Spec
    (surface-ast-read-import-kind! reader)
    (codec.surface-ast-read-string! reader)
    (surface-ast-read-maybe-module-name! reader)
    (surface-ast-read-maybe-import-alias! reader)
    (box (codec.surface-ast-read-span! reader))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-dispatch-variant-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [variants : ast.AstDispatchVariantList]) : unit
    (let
      [index : i64 0]
      [count : i64 variants.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (ast.ast-array-shared-view variants.slots index)
            [(ast.AstDispatchVariant.Variant isa name)
              (begin
                (codec.surface-ast-write-i64!
                  out
                  (match isa
                    [(ast.AstDispatchIsa.Scalar) 0]
                    [(ast.AstDispatchIsa.Avx2) 1]
                    [(ast.AstDispatchIsa.Avx512) 2]))
                (codec.surface-ast-write-name! out context name))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-dispatch-variant-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstDispatchVariantList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstDispatchVariant)
      (__tl_make-array ast.AstDispatchVariant count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [tag : i64 (codec.surface-ast-read-i64! reader)]
          [isa : ast.AstDispatchIsa
            (cond
              [(= tag 0) ast.AstDispatchIsa.Scalar]
              [(= tag 1) ast.AstDispatchIsa.Avx2]
              [(= tag 2) ast.AstDispatchIsa.Avx512]
              [else
                (begin
                  (codec.surface-ast-reader-fail!
                    reader
                    "surface ast: invalid dispatch isa")
                  ast.AstDispatchIsa.Scalar)])]
          (begin
            (set!
              (array-ref slots index)
              (ast.AstDispatchVariant.Variant
                isa
                (codec.surface-ast-read-name! reader)))
            (set! index (+ index 1)))))
      (ast.AstDispatchVariantList slots count))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-decl-meta!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [_context : (&mut context codec.SurfaceAstWriteContext)]
    [meta : ast.AstDeclMeta]) : unit
    (match (deref meta.value)
      [(ast.AstDeclMetaValue.Runtime markers)
        (begin
          (codec.surface-ast-write-i64! out 0)
          (codec.surface-ast-write-i64! out markers))]
      [(ast.AstDeclMetaValue.Comptime generated markers)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-i64! out markers)
          (match generated
            [(ast.AstGeneratedDeclMeta.No) (codec.surface-ast-write-i64! out 0)]
            [(ast.AstGeneratedDeclMeta.Some generator item args key)
              (begin
                (codec.surface-ast-write-i64! out 1)
                (codec.surface-ast-write-string! out generator)
                (codec.surface-ast-write-string! out item)
                (expr_codec.surface-ast-write-expr-list! out args)
                (codec.surface-ast-write-string! out key))]))])))

(define (surface-ast-read-decl-meta!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstDeclMeta
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (if (or (= tag 0) (= tag 1))
      (let
        [markers : i64 (codec.surface-ast-read-i64! reader)]
        (if (or (= markers 0) (= markers 1))
          (if (= tag 0)
            (ast.ast-decl-meta-runtime-with-aggregate-markers markers)
            (surface-ast-read-comptime-decl-meta! reader markers))
          (begin
            (codec.surface-ast-reader-fail!
              reader
              "surface ast: invalid aggregate marker flags")
            (ast.ast-decl-meta-runtime-shared-view))))
      (begin
        (codec.surface-ast-reader-fail!
          reader
          "surface ast: invalid declaration metadata")
        (ast.ast-decl-meta-runtime-shared-view)))))

(define (surface-ast-read-comptime-decl-meta!
  [reader : (&mut reader codec.SurfaceAstReader)]
  [markers : i64]) : ast.AstDeclMeta
  (let
    [generated-tag : i64 (codec.surface-ast-read-i64! reader)]
    [generated : ast.AstGeneratedDeclMeta
      (if (= generated-tag 0)
        ast.AstGeneratedDeclMeta.No
        (if (= generated-tag 1)
          (ast.AstGeneratedDeclMeta.Some
            (codec.surface-ast-read-string! reader)
            (codec.surface-ast-read-string! reader)
            (expr_codec.surface-ast-read-expr-list! reader)
            (codec.surface-ast-read-string! reader))
          (begin
            (codec.surface-ast-reader-fail!
              reader
              "surface ast: invalid generated declaration metadata")
            ast.AstGeneratedDeclMeta.No)))]
    (ast.AstDeclMeta (box (ast.AstDeclMetaValue.Comptime generated markers)))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-test-metadata!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [metadata : ast.AstTestMetadata]) : unit
    (match (deref metadata.value)
      [(ast.AstTestMetadataValue.None) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstTestMetadataValue.Metadata ignore-reason slow)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (match ignore-reason
            [(ast.AstTestIgnoreReason.No) (codec.surface-ast-write-i64! out 0)]
            [(ast.AstTestIgnoreReason.Some reason)
              (begin
                (codec.surface-ast-write-i64! out 1)
                (codec.surface-ast-write-string! out reason))])
          (codec.surface-ast-write-i64!
            out
            (if slow
              1
              0)))])))

(define (surface-ast-read-test-metadata!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstTestMetadata
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) (ast.ast-test-metadata-none-shared-view)]
      [(= tag 1)
        (let
          [ignore-tag : i64 (codec.surface-ast-read-i64! reader)]
          [ignore-reason : ast.AstTestIgnoreReason
            (cond
              [(= ignore-tag 0) ast.AstTestIgnoreReason.No]
              [(= ignore-tag 1)
                (let
                  [reason : String (codec.surface-ast-read-string! reader)]
                  (begin
                    (if (surface_identity.surface-identity-string-eq? reason "")
                      (codec.surface-ast-reader-fail!
                        reader
                        "surface ast: empty test ignore reason")
                      unit)
                    (ast.AstTestIgnoreReason.Some reason)))]
              [else
                (begin
                  (codec.surface-ast-reader-fail!
                    reader
                    "surface ast: invalid test ignore metadata")
                  ast.AstTestIgnoreReason.No)])]
          [slow-tag : i64 (codec.surface-ast-read-i64! reader)]
          [slow : bool
            (cond
              [(= slow-tag 0) false]
              [(= slow-tag 1) true]
              [else
                (begin
                  (codec.surface-ast-reader-fail!
                    reader
                    "surface ast: invalid test slow metadata")
                  false)])]
          (ast.ast-test-metadata-new ignore-reason slow))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid test metadata")
          (ast.ast-test-metadata-none-shared-view))])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-decl!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [decl : ast.AstDecl]) : unit
    (match decl
      [(ast.AstDecl.Module name)
        (begin
          (codec.surface-ast-write-i64! out 0)
          (codec.surface-ast-write-name! out context name))]
      [(ast.AstDecl.ModuleBody name body)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name)
          (surface-ast-write-decl-list! out context (deref body)))]
      [(ast.AstDecl.Def meta name maybe-ty value)
        (begin
          (codec.surface-ast-write-i64! out 2)
          (surface-ast-write-decl-meta! out context meta)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-maybe-type! out context maybe-ty)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstDecl.DefFn meta name params ret body metadata)
        (begin
          (codec.surface-ast-write-i64! out 3)
          (surface-ast-write-decl-meta! out context meta)
          (codec.surface-ast-write-name! out context name)
          (expr_codec.surface-ast-write-param-list! out context params)
          (codec.surface-ast-write-type! out context ret)
          (codec.surface-ast-write-i64! out body)
          (surface-ast-write-fn-metadata! out context metadata))]
      [(ast.AstDecl.DefMacro meta name params ret body)
        (begin
          (codec.surface-ast-write-i64! out 4)
          (surface-ast-write-decl-meta! out context meta)
          (codec.surface-ast-write-name! out context name)
          (surface-ast-write-macro-param-list! out context params)
          (codec.surface-ast-write-type! out context ret)
          (codec.surface-ast-write-i64! out body))]
      [(ast.AstDecl.Extern meta name kind metadata ty)
        (begin
          (codec.surface-ast-write-i64! out 5)
          (surface-ast-write-decl-meta! out context meta)
          (codec.surface-ast-write-name! out context name)
          (surface-ast-write-extern-kind! out kind)
          (surface-ast-write-extern-metadata! out context (deref metadata))
          (codec.surface-ast-write-type! out context ty))]
      [(ast.AstDecl.DefEnum meta name cleanup variants)
        (begin
          (codec.surface-ast-write-i64! out 6)
          (surface-ast-write-decl-meta! out context meta)
          (codec.surface-ast-write-name! out context name)
          (surface-ast-write-enum-cleanup! out context cleanup)
          (surface-ast-write-variant-def-list! out context variants))]
      [(ast.AstDecl.DefEnumLifetimes meta name lifetimes cleanup variants)
        (begin
          (codec.surface-ast-write-i64! out 7)
          (surface-ast-write-decl-meta! out context meta)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-lifetime-list! out context lifetimes)
          (surface-ast-write-enum-cleanup! out context cleanup)
          (surface-ast-write-variant-def-list! out context variants))]
      [(ast.AstDecl.DefStruct meta name repr cleanup fields)
        (begin
          (codec.surface-ast-write-i64! out 8)
          (surface-ast-write-decl-meta! out context meta)
          (codec.surface-ast-write-name! out context name)
          (surface-ast-write-struct-repr! out repr)
          (surface-ast-write-struct-cleanup! out context cleanup)
          (surface-ast-write-field-def-list! out context fields))]
      [(ast.AstDecl.DefStructLifetimes meta name lifetimes repr cleanup fields)
        (begin
          (codec.surface-ast-write-i64! out 9)
          (surface-ast-write-decl-meta! out context meta)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-lifetime-list! out context lifetimes)
          (surface-ast-write-struct-repr! out repr)
          (surface-ast-write-struct-cleanup! out context cleanup)
          (surface-ast-write-field-def-list! out context fields))]
      [(ast.AstDecl.Import meta spec)
        (begin
          (codec.surface-ast-write-i64! out 10)
          (surface-ast-write-decl-meta! out context meta)
          (surface-ast-write-import-spec! out context spec))]
      [(ast.AstDecl.IncludeStr name path)
        (begin
          (codec.surface-ast-write-i64! out 11)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-string! out path))]
      [(ast.AstDecl.IncludeStrComptime name path)
        (begin
          (codec.surface-ast-write-i64! out 12)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-string! out path))]
      [(ast.AstDecl.IncludeStrLzss name path)
        (begin
          (codec.surface-ast-write-i64! out 13)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-string! out path))]
      [(ast.AstDecl.IncludeBin name path)
        (begin
          (codec.surface-ast-write-i64! out 14)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-string! out path))]
      [(ast.AstDecl.DefDispatch meta name variants)
        (begin
          (codec.surface-ast-write-i64! out 15)
          (surface-ast-write-decl-meta! out context meta)
          (codec.surface-ast-write-name! out context name)
          (surface-ast-write-dispatch-variant-list! out context variants))]
      [(ast.AstDecl.Test name body metadata span)
        (begin
          (codec.surface-ast-write-i64! out 16)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-i64! out body)
          (surface-ast-write-test-metadata! out metadata)
          (codec.surface-ast-write-span! out span))]
      [(ast.AstDecl.Unsafe inner)
        (begin
          (codec.surface-ast-write-i64! out 17)
          (surface-ast-write-decl! out context (deref inner)))])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-decl-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [decls : ast.AstDeclList]) : unit
    (let
      [count : i64 decls.len]
      [index : i64 0]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (surface-ast-write-decl!
              out
              context
              (ast.ast-array-shared-view decls.slots (+ decls.offset index)))
            (set! index (+ index 1))))))))

(define (surface-ast-read-decl! [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstDecl
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) (ast.AstDecl.Module (codec.surface-ast-read-name! reader))]
      [(= tag 1)
        (ast.AstDecl.ModuleBody
          (codec.surface-ast-read-name! reader)
          (box (surface-ast-read-decl-list! reader)))]
      [(= tag 2)
        (ast.AstDecl.Def
          (surface-ast-read-decl-meta! reader)
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-maybe-type! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 3)
        (ast.AstDecl.DefFn
          (surface-ast-read-decl-meta! reader)
          (codec.surface-ast-read-name! reader)
          (expr_codec.surface-ast-read-param-list! reader)
          (codec.surface-ast-read-type! reader)
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-fn-metadata! reader))]
      [(= tag 4)
        (ast.AstDecl.DefMacro
          (surface-ast-read-decl-meta! reader)
          (codec.surface-ast-read-name! reader)
          (surface-ast-read-macro-param-list! reader)
          (codec.surface-ast-read-type! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 5)
        (ast.AstDecl.Extern
          (surface-ast-read-decl-meta! reader)
          (codec.surface-ast-read-name! reader)
          (surface-ast-read-extern-kind! reader)
          (box (surface-ast-read-extern-metadata! reader))
          (codec.surface-ast-read-type! reader))]
      [(= tag 6)
        (ast.AstDecl.DefEnum
          (surface-ast-read-decl-meta! reader)
          (codec.surface-ast-read-name! reader)
          (surface-ast-read-enum-cleanup! reader)
          (surface-ast-read-variant-def-list! reader))]
      [(= tag 7)
        (ast.AstDecl.DefEnumLifetimes
          (surface-ast-read-decl-meta! reader)
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-lifetime-list! reader)
          (surface-ast-read-enum-cleanup! reader)
          (surface-ast-read-variant-def-list! reader))]
      [(= tag 8)
        (let
          [meta : ast.AstDeclMeta (surface-ast-read-decl-meta! reader)]
          [name : i64 (codec.surface-ast-read-name! reader)]
          [repr : ast.AstStructRepr (surface-ast-read-struct-repr! reader)]
          [cleanup : ast.AstStructCleanup
            (surface-ast-read-struct-cleanup! reader)]
          [fields : ast.AstFieldDefList
            (surface-ast-read-field-def-list! reader)]
          (begin
            (surface-ast-check-field-aligns! reader (& repr) (& fields))
            (ast.AstDecl.DefStruct meta name repr cleanup fields)))]
      [(= tag 9)
        (let
          [meta : ast.AstDeclMeta (surface-ast-read-decl-meta! reader)]
          [name : i64 (codec.surface-ast-read-name! reader)]
          [lifetimes : ast.AstLifetimeList
            (codec.surface-ast-read-lifetime-list! reader)]
          [repr : ast.AstStructRepr (surface-ast-read-struct-repr! reader)]
          [cleanup : ast.AstStructCleanup
            (surface-ast-read-struct-cleanup! reader)]
          [fields : ast.AstFieldDefList
            (surface-ast-read-field-def-list! reader)]
          (begin
            (surface-ast-check-field-aligns! reader (& repr) (& fields))
            (ast.AstDecl.DefStructLifetimes
              meta
              name
              lifetimes
              repr
              cleanup
              fields)))]
      [(= tag 10)
        (ast.AstDecl.Import
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-import-spec! reader))]
      [(= tag 11)
        (ast.AstDecl.IncludeStr
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-string! reader))]
      [(= tag 12)
        (ast.AstDecl.IncludeStrComptime
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-string! reader))]
      [(= tag 13)
        (ast.AstDecl.IncludeStrLzss
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-string! reader))]
      [(= tag 14)
        (ast.AstDecl.IncludeBin
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-string! reader))]
      [(= tag 15)
        (ast.AstDecl.DefDispatch
          (surface-ast-read-decl-meta! reader)
          (codec.surface-ast-read-name! reader)
          (surface-ast-read-dispatch-variant-list! reader))]
      [(= tag 16)
        (ast.AstDecl.Test
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-test-metadata! reader)
          (codec.surface-ast-read-span! reader))]
      [(= tag 17) (ast.AstDecl.Unsafe (box (surface-ast-read-decl! reader)))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid declaration tag")
          (ast.AstDecl.Module (codec.surface-ast-read-name! reader)))])))

(define (surface-ast-read-decl-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstDeclList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstDecl) (__tl_make-array ast.AstDecl count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (surface-ast-read-decl! reader))
          (set! index (+ index 1))))
      (ast.AstDeclList slots 0 count true))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-paths!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [paths : ast.AstDeclPathList]) : unit
    (let
      [index : i64 0]
      [count : i64 (ast.ast-decl-path-list-len (& paths))]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (codec.surface-ast-write-string!
              out
              (ast.ast-array-shared-view paths.slots (+ paths.offset index)))
            (codec.surface-ast-write-name!
              out
              context
              (array-ref paths.owner-ids (+ paths.offset index)))
            (codec.surface-ast-write-name!
              out
              context
              (ast.ast-decl-path-list-provenance-id (& paths) index 0))
            (set! index (+ index 1))))))))

(define (surface-ast-read-paths!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstDeclPathList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array String) (__tl_make-array String count)]
    [owners : (__tl_dyn-array i64) (__tl_make-array i64 (* count 2))]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (codec.surface-ast-read-string! reader))
          (set! (array-ref owners index) (codec.surface-ast-read-name! reader))
          (set!
            (array-ref owners (+ count index))
            (codec.surface-ast-read-name! reader))
          (set! index (+ index 1))))
      (ast.AstDeclPathList slots owners 0 count true))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-modules!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [modules : (& modules ast.AstDeclModuleList)]) : unit
    (let
      [index : i64 0]
      [count : i64 (ast.ast-decl-module-list-len modules)]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (codec.surface-ast-write-name!
              out
              context
              (array-ref modules.slots (+ modules.offset index)))
            (set! index (+ index 1))))))))

(define (surface-ast-read-modules!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstDeclModuleList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (codec.surface-ast-read-name! reader))
          (set! index (+ index 1))))
      (ast.AstDeclModuleList slots 0 count true))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-seen!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [seen : sym_i64_env.SymI64Env]) : unit
    (let
      [cursor : sym_i64_env.SymI64Env seen]
      (begin
        (while true
          (match (sym_i64_env.sym-i64-view cursor)
            [(sym_i64_env.SymI64ViewNil)
              (begin
                (codec.surface-ast-write-i64! out 0)
                (return unit))]
            [(sym_i64_env.SymI64ViewBind key value rest)
              (begin
                (codec.surface-ast-write-i64! out 1)
                (codec.surface-ast-write-name! out context key)
                (codec.surface-ast-write-i64! out value)
                (set! cursor rest))]))
        unit))))

(define (surface-ast-read-seen! [reader : (&mut reader codec.SurfaceAstReader)]) : sym_i64_env.SymI64Env
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) (sym_i64_env.sym-i64-empty)]
      [(= tag 1)
        (let
          [key : i64 (codec.surface-ast-read-name! reader)]
          [value : i64 (codec.surface-ast-read-i64! reader)]
          [rest : sym_i64_env.SymI64Env (surface-ast-read-seen! reader)]
          (sym_i64_env.sym-i64-bind-id rest key value))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid seen-set list")
          (sym_i64_env.sym-i64-empty))])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-compacted!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [program : ast.AstProgram]
    [paths : ast.AstDeclPathList]
    [modules : (& modules ast.AstDeclModuleList)]
    [seen : sym_i64_env.SymI64Env]
    [pools : ast.AstNodePoolContext]) : unit
    (let
      [type-count : i64 (ast.ast-node-pool-context-type-len pools)]
      [expr-count : i64 (ast.ast-node-pool-context-expr-len pools)]
      [index : i64 0]
      (begin
        (codec.surface-ast-write-i64! out surface-ast-magic)
        (codec.surface-ast-write-i64! out surface-ast-schema-version)
        (codec.surface-ast-write-i64! out context.identity-count)
        (codec.surface-ast-write-i64! out type-count)
        (codec.surface-ast-write-i64! out expr-count)
        (while (< index type-count)
          (begin
            (codec.surface-ast-write-type!
              out
              context
              (ast.ast-node-pool-context-type-get pools index))
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index expr-count)
          (begin
            (expr_codec.surface-ast-write-expr!
              out
              context
              (ast.ast-node-pool-context-expr-get pools index))
            (set! index (+ index 1))))
        (match program
          [(ast.AstProgram.Program decls)
            (surface-ast-write-decl-list! out context (deref decls))])
        (surface-ast-write-paths! out context paths)
        (surface-ast-write-modules! out context modules)
        (surface-ast-write-seen! out context seen)))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-encode
    [structural-session : cis.InternStructuralSessionHandle]
    [decls : ast.AstDeclList]
    [paths : ast.AstDeclPathList]
    [modules : (& modules ast.AstDeclModuleList)]
    [seen : sym_i64_env.SymI64Env]
    [source-pools : ast.AstNodePoolContext]
    [source-identity-count : i64]
    [identity-count : i64]) : ResultSurfaceAstBytes
    (let
      [surface-arena : arena.Arena (arena.make)]
      [dest-pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities-in-arena
          (ast.ast-node-pool-context-expr-len source-pools)
          (ast.ast-node-pool-context-type-len source-pools)
          (arena.raw-handle surface-arena))]
      [compaction : ast.AstProgramCompaction
        (ast.ast-program-compact-with-pools
          source-pools
          dest-pools
          (ast.ast-program decls))]
      [context : codec.SurfaceAstWriteContext
        (codec.surface-ast-write-context-new
          structural-session
          source-identity-count
          identity-count)]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (begin
        (match compaction
          [(ast.AstProgramCompaction compacted-program compacted-pools)
            (surface-ast-write-compacted!
              (&mut out)
              (&mut context)
              compacted-program
              paths
              modules
              seen
              compacted-pools)])
        (let
          [bytes : (__tl_dyn-array u8)
            (byte_buf_core.byte-buf-builder-finish-array (& out))]
          (begin
            (arena.destroy-safe! surface-arena)
            (if (codec.surface-ast-write-valid? (& context))
              (ResultSurfaceAstBytes.Ok bytes)
              (ResultSurfaceAstBytes.Err
                (surface-ast-invalid-identity-message
                  structural-session
                  (codec.surface-ast-write-invalid-name context))))))))))

(define (surface-ast-decode-pools!
  [reader : (&mut reader codec.SurfaceAstReader)]
  [pools : ast.AstNodePoolContext]
  [type-count : i64]
  [expr-count : i64]) : unit
  (let
    [index : i64 0]
    (begin
      (ast.ast-node-pool-context-reset-to! pools 0 0)
      (while (< index type-count)
        (let
          [new-id : i64
            (ast.ast-node-pool-context-type-push
              pools
              (codec.surface-ast-read-type! reader))]
          (begin
            (if (= new-id index)
              unit
              (codec.surface-ast-reader-fail!
                reader
                "surface ast: non-canonical serialized type pool"))
            (set! index (+ index 1)))))
      (set! index 0)
      (while (< index expr-count)
        (let
          [new-id : i64
            (ast.ast-node-pool-context-expr-push
              pools
              (expr_codec.surface-ast-read-expr! reader))]
          (begin
            (if (= new-id index)
              unit
              (codec.surface-ast-reader-fail!
                reader
                "surface ast: non-canonical serialized expression pool"))
            (set! index (+ index 1))))))))

(define (surface-ast-decode
  [bytes : (__tl_dyn-array u8)]
  [structural-session : cis.InternStructuralSessionHandle]
  [identity-remap : (__tl_dyn-array i64)]
  [pools : ast.AstNodePoolContext]) : ResultSurfaceAstHydration
  (let
    [byte-count : i64 (array-length bytes)]
    [expected-identity-count : i64 (array-length identity-remap)]
    [reader : codec.SurfaceAstReader
      (codec.surface-ast-reader-new bytes structural-session identity-remap)]
    [magic : i64 (codec.surface-ast-read-i64! (&mut reader))]
    [schema : i64 (codec.surface-ast-read-i64! (&mut reader))]
    [identity-count : i64 (codec.surface-ast-read-i64! (&mut reader))]
    [type-count : i64 (codec.surface-ast-read-count! (&mut reader))]
    [expr-count : i64 (codec.surface-ast-read-count! (&mut reader))]
    (if (or
      (not (= magic surface-ast-magic))
      (not (= schema surface-ast-schema-version))
      (not (= identity-count expected-identity-count)))
      (ResultSurfaceAstHydration.Err
        "surface ast: bad magic, schema, or identity binding")
      (begin
        (surface-ast-decode-pools! (&mut reader) pools type-count expr-count)
        (let
          [decls : ast.AstDeclList (surface-ast-read-decl-list! (&mut reader))]
          [paths : ast.AstDeclPathList (surface-ast-read-paths! (&mut reader))]
          [modules : ast.AstDeclModuleList
            (surface-ast-read-modules! (&mut reader))]
          [seen : sym_i64_env.SymI64Env (surface-ast-read-seen! (&mut reader))]
          [_c-signatures : unit
            (codec.surface-ast-validate-c-function-signatures!
              (&mut reader)
              pools)]
          (cond
            [(not (codec.surface-ast-reader-valid? (& reader)))
              (ResultSurfaceAstHydration.Err
                (codec.surface-ast-reader-message (& reader)))]
            [(not (= (codec.surface-ast-reader-offset (& reader)) byte-count))
              (ResultSurfaceAstHydration.Err
                "surface ast: trailing payload bytes")]
            [(or
                (not
                  (=
                    (ast.ast-decl-list-len (& decls))
                    (ast.ast-decl-path-list-len (& paths))))
                (not
                  (=
                    (ast.ast-decl-list-len (& decls))
                    (ast.ast-decl-module-list-len (& modules)))))
              (ResultSurfaceAstHydration.Err
                "surface ast: declaration provenance lists are misaligned")]
            [else
              (ResultSurfaceAstHydration.Ok
                (SurfaceAstHydration decls paths modules seen pools))]))))))