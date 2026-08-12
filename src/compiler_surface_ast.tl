;; compiler_surface_ast.tl - package-agnostic serialized frontend AST surface.
(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (import stdlib.arena))
(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (import stdlib.byte_buf_core))
(import compiler_ast_types as ast)

;; lint-allow: unused-import -- used by compiler-surface-selftest builds.
(import compiler_intern as ci)

;; lint-allow: unused-import -- used by compiler-surface-selftest builds.
(import compiler_surface_identity as surface_identity)
(import compiler_surface_ast_codec_core as codec)
(import compiler_surface_ast_expr as expr_codec)
(import sym_i64_env)

(defstruct SurfaceAstHydration
  (decls ast.AstDeclList)
  (paths ast.AstDeclPathList)
  (modules ast.AstDeclModuleList)
  (seen sym_i64_env.SymI64Env)
  (pools ast.AstNodePoolContext))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (defenum ResultSurfaceAstBytes
    (Ok (__tl_dyn-array u8))
    (Err String)))

(defenum ResultSurfaceAstHydration
  (Ok SurfaceAstHydration)
  (Err String))

(define surface-ast-magic : i64
  3544386045472754772)
(define surface-ast-schema-version : i64
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
  4)

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-macro-type-kind-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
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
  [reader : codec.SurfaceAstReader]) : ast.AstMacroTypeKindList
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-macro-param-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [params : ast.AstMacroParamList]) : unit
    (let
      [index : i64 0]
      [count : i64 params.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (array-ref params.slots index)
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

(define (surface-ast-read-macro-param-list! [reader : codec.SurfaceAstReader]) : ast.AstMacroParamList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstMacroParam)
      (make-array ast.AstMacroParam count)]
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-field-cleanup!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [cleanup : ast.AstFieldCleanup]) : unit
    (match cleanup
      [(ast.AstFieldCleanup.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstFieldCleanup.Fn name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name))]
      [(ast.AstFieldCleanup.Owned) (codec.surface-ast-write-i64! out 2)])))

(define (surface-ast-read-field-cleanup! [reader : codec.SurfaceAstReader]) : ast.AstFieldCleanup
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstFieldCleanup.No]
      [(= tag 1) (ast.AstFieldCleanup.Fn (codec.surface-ast-read-name! reader))]
      [(= tag 2) ast.AstFieldCleanup.Owned]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid field cleanup")
          ast.AstFieldCleanup.No)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-field-def-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [fields : ast.AstFieldDefList]) : unit
    (let
      [index : i64 0]
      [count : i64 fields.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (array-ref fields.slots index)
            [(ast.AstFieldDef.Def name ty cleanup)
              (begin
                (codec.surface-ast-write-name! out context name)
                (codec.surface-ast-write-type! out context ty)
                (surface-ast-write-field-cleanup! out context cleanup))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-field-def-list! [reader : codec.SurfaceAstReader]) : ast.AstFieldDefList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstFieldDef)
      (make-array ast.AstFieldDef count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstFieldDef.Def
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-type! reader)
              (surface-ast-read-field-cleanup! reader)))
          (set! index (+ index 1))))
      (ast.AstFieldDefList slots count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-struct-repr!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [repr : ast.AstStructRepr]) : unit
    (codec.surface-ast-write-i64!
      out
      (match repr
        [(ast.AstStructRepr.Default) 0]
        [(ast.AstStructRepr.C) 1]))))

(define (surface-ast-read-struct-repr! [reader : codec.SurfaceAstReader]) : ast.AstStructRepr
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (if (= tag 0)
      ast.AstStructRepr.Default
      (if (= tag 1)
        ast.AstStructRepr.C
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid struct repr")
          ast.AstStructRepr.Default)))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-extern-abi!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [abi : ast.AstExternAbi]) : unit
    (match abi
      [(ast.AstExternAbi.C) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstExternAbi.CVarargsOpen) (codec.surface-ast-write-i64! out 1)]
      [(ast.AstExternAbi.CVarargsTyped ty)
        (begin
          (codec.surface-ast-write-i64! out 2)
          (codec.surface-ast-write-type! out context ty))])))

(define (surface-ast-read-extern-abi! [reader : codec.SurfaceAstReader]) : ast.AstExternAbi
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-extern-kind!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [kind : ast.AstExternKind]) : unit
    (codec.surface-ast-write-i64!
      out
      (match kind
        [(ast.AstExternKind.Value) 0]
        [(ast.AstExternKind.Function) 1]))))

(define (surface-ast-read-extern-kind! [reader : codec.SurfaceAstReader]) : ast.AstExternKind
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-extern-link-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [links : ast.AstExternLinkInputList]) : unit
    (let
      [index : i64 0]
      [count : i64 links.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (array-ref links.slots index)
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

(define (surface-ast-read-extern-link-list! [reader : codec.SurfaceAstReader]) : ast.AstExternLinkInputList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstExternLinkInput)
      (make-array ast.AstExternLinkInput count)]
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-spmd-param-class!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [value : ast.AstSpmdParamClass]) : unit
    (codec.surface-ast-write-i64!
      out
      (match value
        [(ast.AstSpmdParamClass.Uniform) 0]
        [(ast.AstSpmdParamClass.Varying) 1]))))

(define (surface-ast-read-spmd-param-class! [reader : codec.SurfaceAstReader]) : ast.AstSpmdParamClass
  (if (= (codec.surface-ast-read-i64! reader) 0)
    ast.AstSpmdParamClass.Uniform
    ast.AstSpmdParamClass.Varying))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
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
  [reader : codec.SurfaceAstReader]) : ast.AstSpmdParamClassList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstSpmdParamClass)
      (make-array ast.AstSpmdParamClass count)]
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-spmd-result-class!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [value : ast.AstSpmdResultClass]) : unit
    (codec.surface-ast-write-i64!
      out
      (match value
        [(ast.AstSpmdResultClass.Unit) 0]
        [(ast.AstSpmdResultClass.Uniform) 1]
        [(ast.AstSpmdResultClass.Varying) 2]))))

(define (surface-ast-read-spmd-result-class! [reader : codec.SurfaceAstReader]) : ast.AstSpmdResultClass
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
  (any compiler-surface-producer compiler-surface-selftest)
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
            [item : ast.AstSpmdSpecialization (array-ref items.slots index)]
            (begin
              (codec.surface-ast-write-i64! out item.lanes)
              (surface-ast-write-spmd-param-class-list!
                out
                (__tl-box-place item.args))
              (surface-ast-write-spmd-result-class! out item.result)
              (codec.surface-ast-write-i64! out item.index-param)
              (set! index (+ index 1)))))
        unit))))

(define (surface-ast-read-spmd-specialization-list!
  [reader : codec.SurfaceAstReader]) : ast.AstSpmdSpecializationList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstSpmdSpecialization)
      (make-array ast.AstSpmdSpecialization count)]
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-fn-metadata!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [metadata : ast.AstFnMetadata]) : unit
    (match metadata
      [(ast.AstFnMetadata.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstFnMetadata.Export name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name))]
      [(ast.AstFnMetadata.SpmdCallable items)
        (begin
          (codec.surface-ast-write-i64! out 2)
          (surface-ast-write-spmd-specialization-list!
            out
            (__tl-box-place items)))])))

(define (surface-ast-read-fn-metadata! [reader : codec.SurfaceAstReader]) : ast.AstFnMetadata
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstFnMetadata.No]
      [(= tag 1)
        (ast.AstFnMetadata.Export (codec.surface-ast-read-name! reader))]
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-imported-spmd-specialization-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [items : ast.AstImportedSpmdSpecializationList]) : unit
    (let
      [index : i64 0]
      [count : i64 items.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (let
            [item : ast.AstImportedSpmdSpecialization
              (array-ref items.slots index)]
            (begin
              (codec.surface-ast-write-name! out context item.abi)
              (codec.surface-ast-write-name! out context item.backend)
              (codec.surface-ast-write-i64! out item.lanes)
              (codec.surface-ast-write-name! out context item.args)
              (codec.surface-ast-write-name! out context item.result)
              (codec.surface-ast-write-i64! out item.index-param)
              (codec.surface-ast-write-name! out context item.symbol)
              (set! index (+ index 1)))))
        unit))))

(define (surface-ast-read-imported-spmd-specialization-list!
  [reader : codec.SurfaceAstReader]) : ast.AstImportedSpmdSpecializationList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstImportedSpmdSpecialization)
      (make-array ast.AstImportedSpmdSpecialization count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstImportedSpmdSpecialization
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-name! reader)))
          (set! index (+ index 1))))
      (ast.AstImportedSpmdSpecializationList slots count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-imported-spmd-callable-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [items : ast.AstImportedSpmdCallableList]) : unit
    (let
      [index : i64 0]
      [count : i64 items.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (let
            [item : ast.AstImportedSpmdCallable (array-ref items.slots index)]
            (begin
              (codec.surface-ast-write-name! out context item.signature)
              (surface-ast-write-imported-spmd-specialization-list!
                out
                context
                item.specializations)
              (set! index (+ index 1)))))
        unit))))

(define (surface-ast-read-imported-spmd-callable-list!
  [reader : codec.SurfaceAstReader]) : ast.AstImportedSpmdCallableList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstImportedSpmdCallable)
      (make-array ast.AstImportedSpmdCallable count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstImportedSpmdCallable
              (codec.surface-ast-read-name! reader)
              (surface-ast-read-imported-spmd-specialization-list! reader)))
          (set! index (+ index 1))))
      (ast.AstImportedSpmdCallableList slots count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-imported-spmd-metadata!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [metadata : ast.AstImportedSpmdMetadata]) : unit
    (match metadata
      [(ast.AstImportedSpmdMetadata.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstImportedSpmdMetadata.Package name callables)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name)
          (surface-ast-write-imported-spmd-callable-list!
            out
            context
            (__tl-box-place callables)))])))

(define (surface-ast-read-imported-spmd-metadata!
  [reader : codec.SurfaceAstReader]) : ast.AstImportedSpmdMetadata
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstImportedSpmdMetadata.No]
      [(= tag 1)
        (ast.AstImportedSpmdMetadata.Package
          (codec.surface-ast-read-name! reader)
          (box (surface-ast-read-imported-spmd-callable-list! reader)))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid imported spmd metadata")
          ast.AstImportedSpmdMetadata.No)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-extern-metadata!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [metadata : ast.AstExternMetadata]) : unit
    (match metadata
      [(ast.AstExternMetadata.Metadata abi symbol links flags imported)
        (begin
          (surface-ast-write-extern-abi! out context abi)
          (codec.surface-ast-write-name! out context symbol)
          (surface-ast-write-extern-link-list! out links)
          (codec.surface-ast-write-i64! out flags)
          (surface-ast-write-imported-spmd-metadata! out context imported))])))

(define (surface-ast-read-extern-metadata! [reader : codec.SurfaceAstReader]) : ast.AstExternMetadata
  (ast.AstExternMetadata.Metadata
    (surface-ast-read-extern-abi! reader)
    (codec.surface-ast-read-name! reader)
    (surface-ast-read-extern-link-list! reader)
    (codec.surface-ast-read-i64! reader)
    (surface-ast-read-imported-spmd-metadata! reader)))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-variant-cleanup!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [cleanup : ast.AstVariantPayloadCleanup]) : unit
    (match cleanup
      [(ast.AstVariantPayloadCleanup.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstVariantPayloadCleanup.Fn name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name))]
      [(ast.AstVariantPayloadCleanup.Owned)
        (codec.surface-ast-write-i64! out 2)])))

(define (surface-ast-read-variant-cleanup! [reader : codec.SurfaceAstReader]) : ast.AstVariantPayloadCleanup
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstVariantPayloadCleanup.No]
      [(= tag 1)
        (ast.AstVariantPayloadCleanup.Fn (codec.surface-ast-read-name! reader))]
      [(= tag 2) ast.AstVariantPayloadCleanup.Owned]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid variant cleanup")
          ast.AstVariantPayloadCleanup.No)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-variant-def-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [variants : ast.AstVariantDefList]) : unit
    (let
      [index : i64 0]
      [count : i64 variants.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (array-ref variants.slots index)
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

(define (surface-ast-read-variant-def-list! [reader : codec.SurfaceAstReader]) : ast.AstVariantDefList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstVariantDef)
      (make-array ast.AstVariantDef count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [name : i64 (codec.surface-ast-read-name! reader)]
          [fields : ast.AstTypeList (codec.surface-ast-read-type-list! reader)]
          [cleanup-count : i64 (codec.surface-ast-read-count! reader)]
          [cleanup-slots : (__tl_dyn-array ast.AstVariantPayloadCleanup)
            (make-array ast.AstVariantPayloadCleanup cleanup-count)]
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-struct-cleanup!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [cleanup : ast.AstStructCleanup]) : unit
    (match cleanup
      [(ast.AstStructCleanup.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstStructCleanup.Fn name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name))])))

(define (surface-ast-read-struct-cleanup! [reader : codec.SurfaceAstReader]) : ast.AstStructCleanup
  (if (= (codec.surface-ast-read-i64! reader) 0)
    ast.AstStructCleanup.No
    (ast.AstStructCleanup.Fn (codec.surface-ast-read-name! reader))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-enum-cleanup!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [cleanup : ast.AstEnumCleanup]) : unit
    (match cleanup
      [(ast.AstEnumCleanup.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstEnumCleanup.Fn name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name))])))

(define (surface-ast-read-enum-cleanup! [reader : codec.SurfaceAstReader]) : ast.AstEnumCleanup
  (if (= (codec.surface-ast-read-i64! reader) 0)
    ast.AstEnumCleanup.No
    (ast.AstEnumCleanup.Fn (codec.surface-ast-read-name! reader))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-maybe-module-name!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [value : ast.AstMaybeModuleName]) : unit
    (match value
      [(ast.AstMaybeModuleName.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstMaybeModuleName.Some name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name))])))

(define (surface-ast-read-maybe-module-name! [reader : codec.SurfaceAstReader]) : ast.AstMaybeModuleName
  (if (= (codec.surface-ast-read-i64! reader) 0)
    ast.AstMaybeModuleName.No
    (ast.AstMaybeModuleName.Some (codec.surface-ast-read-name! reader))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-maybe-import-alias!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [value : ast.AstMaybeImportAlias]) : unit
    (match value
      [(ast.AstMaybeImportAlias.No) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstMaybeImportAlias.Some name)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-name! out context name))])))

(define (surface-ast-read-maybe-import-alias! [reader : codec.SurfaceAstReader]) : ast.AstMaybeImportAlias
  (if (= (codec.surface-ast-read-i64! reader) 0)
    ast.AstMaybeImportAlias.No
    (ast.AstMaybeImportAlias.Some (codec.surface-ast-read-name! reader))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-import-kind!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [kind : ast.AstImportKind]) : unit
    (match kind
      [(ast.AstImportKind.Module) (codec.surface-ast-write-i64! out 0)]
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

(define (surface-ast-read-import-kind! [reader : codec.SurfaceAstReader]) : ast.AstImportKind
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
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid import kind")
          ast.AstImportKind.Module)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-import-spec!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [spec : ast.AstImportSpec]) : unit
    (match spec
      [(ast.AstImportSpec.Spec kind path module-name alias span)
        (begin
          (surface-ast-write-import-kind! out context kind)
          (codec.surface-ast-write-string! out path)
          (surface-ast-write-maybe-module-name! out context module-name)
          (surface-ast-write-maybe-import-alias! out context alias)
          (codec.surface-ast-write-span! out (__tl-box-place span)))])))

(define (surface-ast-read-import-spec! [reader : codec.SurfaceAstReader]) : ast.AstImportSpec
  (ast.AstImportSpec.Spec
    (surface-ast-read-import-kind! reader)
    (codec.surface-ast-read-string! reader)
    (surface-ast-read-maybe-module-name! reader)
    (surface-ast-read-maybe-import-alias! reader)
    (box (codec.surface-ast-read-span! reader))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-dispatch-variant-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [variants : ast.AstDispatchVariantList]) : unit
    (let
      [index : i64 0]
      [count : i64 variants.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (array-ref variants.slots index)
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
  [reader : codec.SurfaceAstReader]) : ast.AstDispatchVariantList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstDispatchVariant)
      (make-array ast.AstDispatchVariant count)]
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-decl-meta!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [_context : codec.SurfaceAstWriteContext]
    [meta : ast.AstDeclMeta]) : unit
    (match (__tl-box-place meta.value)
      [(ast.AstDeclMetaValue.Runtime) (codec.surface-ast-write-i64! out 0)]
      [(ast.AstDeclMetaValue.Comptime generated)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (match generated
            [(ast.AstGeneratedDeclMeta.No) (codec.surface-ast-write-i64! out 0)]
            [(ast.AstGeneratedDeclMeta.Some generator item args key)
              (begin
                (codec.surface-ast-write-i64! out 1)
                (codec.surface-ast-write-string! out generator)
                (codec.surface-ast-write-string! out item)
                (expr_codec.surface-ast-write-expr-list! out args)
                (codec.surface-ast-write-string! out key))]))])))

(define (surface-ast-read-decl-meta! [reader : codec.SurfaceAstReader]) : ast.AstDeclMeta
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (if (= tag 0)
      (ast.ast-decl-meta-runtime-shared-view)
      (if (= tag 1)
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
          (ast.AstDeclMeta (box (ast.AstDeclMetaValue.Comptime generated))))
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid declaration metadata")
          (ast.ast-decl-meta-runtime-shared-view))))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-decl!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
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
          (surface-ast-write-decl-list! out context (__tl-box-place body)))]
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
          (surface-ast-write-extern-metadata!
            out
            context
            (__tl-box-place metadata))
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
      [(ast.AstDecl.Test name body span)
        (begin
          (codec.surface-ast-write-i64! out 16)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-i64! out body)
          (codec.surface-ast-write-span! out span))]
      [(ast.AstDecl.Unsafe inner)
        (begin
          (codec.surface-ast-write-i64! out 17)
          (surface-ast-write-decl! out context (__tl-box-place inner)))])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-decl-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
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
              (array-ref decls.slots (+ decls.offset index)))
            (set! index (+ index 1))))))))

(define (surface-ast-read-decl! [reader : codec.SurfaceAstReader]) : ast.AstDecl
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
        (ast.AstDecl.DefStruct
          (surface-ast-read-decl-meta! reader)
          (codec.surface-ast-read-name! reader)
          (surface-ast-read-struct-repr! reader)
          (surface-ast-read-struct-cleanup! reader)
          (surface-ast-read-field-def-list! reader))]
      [(= tag 9)
        (ast.AstDecl.DefStructLifetimes
          (surface-ast-read-decl-meta! reader)
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-lifetime-list! reader)
          (surface-ast-read-struct-repr! reader)
          (surface-ast-read-struct-cleanup! reader)
          (surface-ast-read-field-def-list! reader))]
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
          (codec.surface-ast-read-span! reader))]
      [(= tag 17) (ast.AstDecl.Unsafe (box (surface-ast-read-decl! reader)))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid declaration tag")
          (ast.AstDecl.Module (codec.surface-ast-read-name! reader)))])))

(define (surface-ast-read-decl-list! [reader : codec.SurfaceAstReader]) : ast.AstDeclList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstDecl) (make-array ast.AstDecl count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (surface-ast-read-decl! reader))
          (set! index (+ index 1))))
      (ast.AstDeclList slots 0 count true))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-seen-count [seen : sym_i64_env.SymI64Env]) : i64
    (let
      [cursor : sym_i64_env.SymI64Env seen]
      [count : i64 0]
      (begin
        (while true
          (match (sym_i64_env.sym-i64-view cursor)
            [(sym_i64_env.SymI64ViewNil) (return count)]
            [(sym_i64_env.SymI64ViewBind _ _ rest)
              (begin
                (set! count (+ count 1))
                (set! cursor rest))]))
        count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-paths!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
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
              (array-ref paths.slots (+ paths.offset index)))
            (codec.surface-ast-write-name!
              out
              context
              (array-ref paths.owner-ids (+ paths.offset index)))
            (set! index (+ index 1))))))))

(define (surface-ast-read-paths! [reader : codec.SurfaceAstReader]) : ast.AstDeclPathList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array String) (make-array String count)]
    [owners : (__tl_dyn-array i64) (make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (codec.surface-ast-read-string! reader))
          (set! (array-ref owners index) (codec.surface-ast-read-name! reader))
          (set! index (+ index 1))))
      (ast.AstDeclPathList slots owners 0 count true))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-modules!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [modules : ast.AstDeclModuleList]) : unit
    (let
      [index : i64 0]
      [count : i64 (ast.ast-decl-module-list-len (& modules))]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (codec.surface-ast-write-name!
              out
              context
              (array-ref modules.slots (+ modules.offset index)))
            (set! index (+ index 1))))))))

(define (surface-ast-read-modules! [reader : codec.SurfaceAstReader]) : ast.AstDeclModuleList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array i64) (make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (codec.surface-ast-read-name! reader))
          (set! index (+ index 1))))
      (ast.AstDeclModuleList slots 0 count true))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-seen!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
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

(define (surface-ast-read-seen! [reader : codec.SurfaceAstReader]) : sym_i64_env.SymI64Env
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
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-compacted!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : codec.SurfaceAstWriteContext]
    [program : ast.AstProgram]
    [paths : ast.AstDeclPathList]
    [modules : ast.AstDeclModuleList]
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
            (surface-ast-write-decl-list! out context (__tl-box-place decls))])
        (surface-ast-write-paths! out context paths)
        (surface-ast-write-modules! out context modules)
        (surface-ast-write-seen! out context seen)))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-encode
    [decls : ast.AstDeclList]
    [paths : ast.AstDeclPathList]
    [modules : ast.AstDeclModuleList]
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
          source-identity-count
          identity-count)]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (begin
        (match compaction
          [(ast.AstProgramCompaction compacted-program compacted-pools)
            (surface-ast-write-compacted!
              (&mut out)
              context
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
            (if (codec.surface-ast-write-valid? context)
              (ResultSurfaceAstBytes.Ok bytes)
              (ResultSurfaceAstBytes.Err
                "surface ast: encountered an identity outside the package table"))))))))

(define (surface-ast-decode-pools!
  [reader : codec.SurfaceAstReader]
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
  [identity-remap : (__tl_dyn-array i64)]
  [pools : ast.AstNodePoolContext]) : ResultSurfaceAstHydration
  (let
    [reader : codec.SurfaceAstReader
      (codec.surface-ast-reader-new bytes identity-remap)]
    [magic : i64 (codec.surface-ast-read-i64! reader)]
    [schema : i64 (codec.surface-ast-read-i64! reader)]
    [identity-count : i64 (codec.surface-ast-read-i64! reader)]
    [type-count : i64 (codec.surface-ast-read-count! reader)]
    [expr-count : i64 (codec.surface-ast-read-count! reader)]
    (if (or
      (not (= magic surface-ast-magic))
      (not (= schema surface-ast-schema-version))
      (not (= identity-count (array-length identity-remap))))
      (ResultSurfaceAstHydration.Err
        "surface ast: bad magic, schema, or identity binding")
      (begin
        (surface-ast-decode-pools! reader pools type-count expr-count)
        (let
          [decls : ast.AstDeclList (surface-ast-read-decl-list! reader)]
          [paths : ast.AstDeclPathList (surface-ast-read-paths! reader)]
          [modules : ast.AstDeclModuleList (surface-ast-read-modules! reader)]
          [seen : sym_i64_env.SymI64Env (surface-ast-read-seen! reader)]
          (cond
            [(not (codec.surface-ast-reader-valid? reader))
              (ResultSurfaceAstHydration.Err
                (codec.surface-ast-reader-message reader))]
            [(not
                (=
                  (codec.surface-ast-reader-offset reader)
                  (array-length bytes)))
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
    [decls : ast.AstDeclList]
    [paths : ast.AstDeclPathList]
    [modules : ast.AstDeclModuleList]
    [seen : sym_i64_env.SymI64Env]
    [source-pools : ast.AstNodePoolContext]
    [source-count : i64]
    [identity-count : i64]) : ResultSurfaceAstBytes
    (match (surface-ast-encode
      decls
      paths
      modules
      seen
      source-pools
      source-count
      identity-count)
      [(ResultSurfaceAstBytes.Err message) (ResultSurfaceAstBytes.Err message)]
      [(ResultSurfaceAstBytes.Ok first)
        (match (surface-ast-encode
          decls
          paths
          modules
          seen
          source-pools
          source-count
          identity-count)
          [(ResultSurfaceAstBytes.Err message)
            (ResultSurfaceAstBytes.Err message)]
          [(ResultSurfaceAstBytes.Ok second)
            (if (surface-ast-byte-array-eq? first second)
              (ResultSurfaceAstBytes.Ok first)
              (ResultSurfaceAstBytes.Err
                "surface ast: repeated encoding mismatch"))])])))

(cfg
  compiler-surface-selftest
  (define (surface-ast-borrowed-slice-type-ok?
    [pools : ast.AstNodePoolContext]
    [ty : ast.AstType]) : bool
    (match ty
      [(ast.AstType.Ref region inner)
        (and
          (surface_identity.surface-identity-string-eq?
            (ci.intern-str region)
            "borrow-region")
          (match (ast.ast-node-pool-context-type-get pools inner)
            [(ast.AstType.Slice elem)
              (match (ast.ast-node-pool-context-type-get pools elem)
                [(ast.AstType.I64) true]
                [_ false])]
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
      [macro-param-id : i64 (ci.intern "T")]
      [macro-type-id : i64 (ci.intern "type")]
      [kind-i64-id : i64 (ci.intern "i64")]
      [kind-struct-id : i64 (ci.intern "struct")]
      [kind-type-var-id : i64 (ci.intern "type-var")]
      [source-pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 8 8)]
      [left : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (ast.AstExpr.Literal (ast.AstLiteral.Int 20 "20")))]
      [right : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (ast.AstExpr.Literal (ast.AstLiteral.Int 22 "22")))]
      [sum : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (ast.AstExpr.Binary ast.AstBinOp.Add left right))]
      [borrow-lifetime-id : i64 (ci.intern "borrow-region")]
      [view-param-id : i64 (ci.intern "view")]
      [slice-i64 : ast.AstType
        (ast.ast-ty-slice-with-pools source-pools ast.AstType.I64)]
      [borrowed-slice : ast.AstType
        (ast.ast-ty-ref-with-pools source-pools borrow-lifetime-id slice-i64)]
      [body : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (ast.AstExpr.Borrow
            false
            (ast.ast-borrow-lifetime-to-id
              (ast.AstBorrowLifetime.Named borrow-lifetime-id))
            sum))]
      [tuple-set : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (ast.AstExpr.StructSet
            left
            (ast.ast-tuple-set-field-id-from-index 3)
            right))]
      [body-items : (__tl_dyn-array i64) (make-array i64 2)]
      [combined-body : i64
        (ast.ast-node-pool-context-expr-push
          source-pools
          (ast.AstExpr.Begin (ast.AstExprList body-items 2)))]
      [macro-type-kinds : ast.AstMacroTypeKindList
        (ast.ast-macro-type-kind-list-with-length 3)]
      [macro-param-slots : (__tl_dyn-array ast.AstMacroParam)
        (make-array ast.AstMacroParam 1)]
      [view-param-slots : (__tl_dyn-array ast.AstParam)
        (make-array ast.AstParam 1)]
      [decl-slots : (__tl_dyn-array ast.AstDecl) (make-array ast.AstDecl 2)]
      [path-slots : (__tl_dyn-array String) (make-array String 2)]
      [owner-slots : (__tl_dyn-array i64) (make-array i64 2)]
      [module-slots : (__tl_dyn-array i64) (make-array i64 2)]
      [key-modules : (__tl_dyn-array String) (make-array String 1)]
      (begin
        (set! (array-ref body-items 0) body)
        (set! (array-ref body-items 1) tuple-set)
        (ast.ast-macro-type-kind-list-set!
          (&mut macro-type-kinds)
          0
          kind-i64-id)
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
            (ast.AstType.Var macro-type-id)
            false
            macro-type-kinds))
        (set!
          (array-ref view-param-slots 0)
          (ast.AstParam.Param view-param-id borrowed-slice false false))
        (set!
          (array-ref decl-slots 0)
          (ast.AstDecl.DefFn
            (ast.ast-decl-meta-runtime-shared-view)
            fn-id
            (ast.AstParamList view-param-slots 1)
            borrowed-slice
            combined-body
            ast.AstFnMetadata.No))
        (set!
          (array-ref decl-slots 1)
          (ast.AstDecl.DefMacro
            (ast.ast-decl-meta-runtime-shared-view)
            macro-id
            (ast.AstMacroParamList macro-param-slots 1)
            ast.AstType.Unit
            sum))
        (set! (array-ref path-slots 0) "test.tl")
        (set! (array-ref path-slots 1) "test.tl")
        (set! (array-ref owner-slots 0) module-id)
        (set! (array-ref owner-slots 1) module-id)
        (set! (array-ref module-slots 0) module-id)
        (set! (array-ref module-slots 1) module-id)
        (set! (array-ref key-modules 0) "test.tl")
        (let
          [decls : ast.AstDeclList (ast.AstDeclList decl-slots 0 2 true)]
          [paths : ast.AstDeclPathList
            (ast.AstDeclPathList path-slots owner-slots 0 2 true)]
          [modules : ast.AstDeclModuleList
            (ast.AstDeclModuleList module-slots 0 2 true)]
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
            (surface_identity.surface-identity-capture key)]
          [source-count : i64 (array-length identity-payload.source-names)]
          [identity-count : i64
            (+ source-count (array-length identity-payload.generated))]
          (match (surface_identity.surface-identity-encode identity-payload)
            [(surface_identity.ResultSurfaceIdentityBytes.Err _) false]
            [(surface_identity.ResultSurfaceIdentityBytes.Ok identity-bytes)
              (match (surface-ast-encode-deterministic
                decls
                paths
                modules
                seen
                source-pools
                source-count
                identity-count)
                [(ResultSurfaceAstBytes.Err _) false]
                [(ResultSurfaceAstBytes.Ok ast-bytes)
                  (begin
                    (ci.intern-reset!)
                    (let
                      [_unrelated : i64 (ci.intern "unrelated")]
                      (match (surface_identity.surface-identity-hydrate
                        identity-bytes
                        key)
                        [(surface_identity.ResultSurfaceIdentityHydration.Err _)
                          false]
                        [(surface_identity.ResultSurfaceIdentityHydration.KeyMismatch
                            _)
                          false]
                        [(surface_identity.ResultSurfaceIdentityHydration.Ok
                            identity-hydration)
                          (let
                            [dest-pools : ast.AstNodePoolContext
                              (ast.ast-node-pool-context-new-with-capacities
                                8
                                8)]
                            (match (surface-ast-decode
                              ast-bytes
                              identity-hydration.remap
                              dest-pools)
                              [(ResultSurfaceAstHydration.Err _) false]
                              [(ResultSurfaceAstHydration.Ok hydration)
                                (and
                                  (=
                                    (ast.ast-node-pool-context-expr-len
                                      hydration.pools)
                                    6)
                                  (=
                                    (ast.ast-decl-list-len (& hydration.decls))
                                    2)
                                  (match (array-ref hydration.decls.slots 0)
                                    [(ast.AstDecl.DefFn
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
                                          1)
                                        (surface-ast-borrowed-slice-type-ok?
                                          hydration.pools
                                          hydrated-ret)
                                        (match (ast.ast-param-list-get
                                          (& hydrated-params)
                                          0
                                          (ast.ast-param-fallback))
                                          [(ast.AstParam.Param
                                              hydrated-param-name
                                              hydrated-param-ty
                                              false
                                              false)
                                            (and
                                              (surface_identity.surface-identity-string-eq?
                                                (ci.intern-str
                                                  hydrated-param-name)
                                                "view")
                                              (surface-ast-borrowed-slice-type-ok?
                                                hydration.pools
                                                hydrated-param-ty))]
                                          [_ false])
                                        (match (ast.ast-node-pool-context-expr-get
                                          hydration.pools
                                          hydrated-body)
                                          [(ast.AstExpr.Begin hydrated-items)
                                            (match (ast.ast-node-pool-context-expr-get
                                              hydration.pools
                                              (ast.ast-expr-list-get
                                                hydrated-items
                                                0
                                                0))
                                              [(ast.AstExpr.Borrow
                                                  mutable
                                                  lifetime-id
                                                  hydrated-sum)
                                                (and
                                                  (not mutable)
                                                  (match (ast.ast-borrow-lifetime-from-id
                                                    lifetime-id)
                                                    [(ast.AstBorrowLifetime.Named
                                                        name)
                                                      (surface_identity.surface-identity-string-eq?
                                                        (ci.intern-str name)
                                                        "borrow-region")]
                                                    [_ false])
                                                  (match (ast.ast-node-pool-context-expr-get
                                                    hydration.pools
                                                    hydrated-sum)
                                                    [(ast.AstExpr.Binary op _ _)
                                                      (match op
                                                        [(ast.AstBinOp.Add)
                                                          true]
                                                        [_ false])]
                                                    [_ false]))]
                                              [_ false])]
                                          [_ false]))]
                                    [_ false])
                                  (match (array-ref hydration.decls.slots 1)
                                    [(ast.AstDecl.DefMacro
                                        _
                                        hydrated-macro-name
                                        hydrated-params
                                        _
                                        _)
                                      (and
                                        (surface_identity.surface-identity-string-eq?
                                          (ci.intern-str hydrated-macro-name)
                                          "catalog")
                                        (=
                                          (ast.ast-macro-param-list-len
                                            (& hydrated-params))
                                          1)
                                        (match (ast.ast-macro-param-list-get
                                          (& hydrated-params)
                                          0
                                          (ast.ast-macro-param-fallback))
                                          [(ast.AstMacroParam.Param
                                              hydrated-param-name
                                              (ast.AstType.Var
                                                hydrated-type-name)
                                              false
                                              hydrated-kinds)
                                            (and
                                              (surface_identity.surface-identity-string-eq?
                                                (ci.intern-str
                                                  hydrated-param-name)
                                                "T")
                                              (surface_identity.surface-identity-string-eq?
                                                (ci.intern-str
                                                  hydrated-type-name)
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
                                  (match (ast.ast-node-pool-context-expr-get
                                    hydration.pools
                                    tuple-set)
                                    [(ast.AstExpr.StructSet
                                        hydrated-target
                                        hydrated-field
                                        hydrated-value)
                                      (and
                                        (= hydrated-target left)
                                        (ast.ast-tuple-set-field-id?
                                          hydrated-field)
                                        (=
                                          (ast.ast-tuple-set-index-from-field-id
                                            hydrated-field)
                                          3)
                                        (= hydrated-value right))]
                                    [_ false]))]))])))])]))))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-selftest-main) : i64
    (if (surface-ast-tests-ok?)
      42
      1)))