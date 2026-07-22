;; compiler_surface_ast.tl - package-agnostic serialized frontend AST surface.
(import stdlib.arena)
(import stdlib.byte_buf_core)
(import "compiler_ast_types.tl")
(cfg compiler-surface-selftest (import compiler_intern as ci))
(cfg
  compiler-surface-selftest
  (import compiler_surface_identity as surface_identity))
(import "compiler_surface_ast_codec_core.tl")
(import "compiler_surface_ast_expr.tl")
(import sym_i64_env)

(defstruct SurfaceAstHydration
  (decls AstDeclList)
  (paths AstDeclPathList)
  (modules AstDeclModuleList)
  (seen sym_i64_env.SymI64Env)
  (pools AstNodePoolContext))

(defenum ResultSurfaceAstBytes
  (Ok (Array u8))
  (Err String))

(defenum ResultSurfaceAstHydration
  (Ok SurfaceAstHydration)
  (Err String))

(define surface-ast-magic : i64
  3544386045472754772)
(define surface-ast-schema-version : i64
  1)

(define (surface-ast-write-macro-type-kind-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [items : AstMacroTypeKindList]) : unit
  (let
    [cursor : AstMacroTypeKindList items]
    [done : bool false]
    (begin
      (while (not done)
        (match cursor
          [(AstMacroTypeKindList.Nil)
            (begin
              (surface-ast-write-i64! out 0)
              (set! done true))]
          [(AstMacroTypeKindList.Cons name rest)
            (begin
              (surface-ast-write-i64! out 1)
              (surface-ast-write-name! out context name)
              (set! cursor (box-get rest)))]))
      unit)))

(define (surface-ast-read-macro-type-kind-list! [reader : SurfaceAstReader]) : AstMacroTypeKindList
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstMacroTypeKindList.Nil]
      [(= tag 1)
        (AstMacroTypeKindList.Cons
          (surface-ast-read-name! reader)
          (box (surface-ast-read-macro-type-kind-list! reader)))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid macro type-kind list")
          AstMacroTypeKindList.Nil)])))

(define (surface-ast-write-macro-param-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [params : AstMacroParamList]) : unit
  (let
    [index : i64 0]
    [count : i64 (struct-get params len)]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (match (array-ref (struct-get params slots) index)
          [(AstMacroParam.Param name ty variadic type-kinds)
            (begin
              (surface-ast-write-name! out context name)
              (surface-ast-write-type! out context ty)
              (surface-ast-write-bool! out variadic)
              (surface-ast-write-macro-type-kind-list! out context type-kinds))])
        (set! index (+ index 1))))))

(define (surface-ast-read-macro-param-list! [reader : SurfaceAstReader]) : AstMacroParamList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array AstMacroParam) (make-array AstMacroParam count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            slots
            index
            (AstMacroParam.Param
              (surface-ast-read-name! reader)
              (surface-ast-read-type! reader)
              (surface-ast-read-bool! reader)
              (surface-ast-read-macro-type-kind-list! reader)))
          (set! index (+ index 1))))
      (AstMacroParamList slots count))))

(define (surface-ast-write-field-cleanup!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [cleanup : AstFieldCleanup]) : unit
  (match cleanup
    [(AstFieldCleanup.No) (surface-ast-write-i64! out 0)]
    [(AstFieldCleanup.Fn name)
      (begin
        (surface-ast-write-i64! out 1)
        (surface-ast-write-name! out context name))]
    [(AstFieldCleanup.Owned) (surface-ast-write-i64! out 2)]))

(define (surface-ast-read-field-cleanup! [reader : SurfaceAstReader]) : AstFieldCleanup
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstFieldCleanup.No]
      [(= tag 1) (AstFieldCleanup.Fn (surface-ast-read-name! reader))]
      [(= tag 2) AstFieldCleanup.Owned]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid field cleanup")
          AstFieldCleanup.No)])))

(define (surface-ast-write-field-def-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [fields : AstFieldDefList]) : unit
  (let
    [index : i64 0]
    [count : i64 (struct-get fields len)]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (match (array-ref (struct-get fields slots) index)
          [(AstFieldDef.Def name ty cleanup)
            (begin
              (surface-ast-write-name! out context name)
              (surface-ast-write-type! out context ty)
              (surface-ast-write-field-cleanup! out context cleanup))])
        (set! index (+ index 1))))))

(define (surface-ast-read-field-def-list! [reader : SurfaceAstReader]) : AstFieldDefList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array AstFieldDef) (make-array AstFieldDef count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            slots
            index
            (AstFieldDef.Def
              (surface-ast-read-name! reader)
              (surface-ast-read-type! reader)
              (surface-ast-read-field-cleanup! reader)))
          (set! index (+ index 1))))
      (AstFieldDefList slots count))))

(define (surface-ast-write-struct-repr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [repr : AstStructRepr]) : unit
  (surface-ast-write-i64!
    out
    (match repr
      [(AstStructRepr.Default) 0]
      [(AstStructRepr.C) 1])))

(define (surface-ast-read-struct-repr! [reader : SurfaceAstReader]) : AstStructRepr
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (if (= tag 0)
      AstStructRepr.Default
      (if (= tag 1)
        AstStructRepr.C
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid struct repr")
          AstStructRepr.Default)))))

(define (surface-ast-write-extern-abi!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [abi : AstExternAbi]) : unit
  (match abi
    [(AstExternAbi.C) (surface-ast-write-i64! out 0)]
    [(AstExternAbi.CVarargsOpen) (surface-ast-write-i64! out 1)]
    [(AstExternAbi.CVarargsTyped ty)
      (begin
        (surface-ast-write-i64! out 2)
        (surface-ast-write-type! out context ty))]))

(define (surface-ast-read-extern-abi! [reader : SurfaceAstReader]) : AstExternAbi
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstExternAbi.C]
      [(= tag 1) AstExternAbi.CVarargsOpen]
      [(= tag 2) (AstExternAbi.CVarargsTyped (surface-ast-read-type! reader))]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid extern abi")
          AstExternAbi.C)])))

(define (surface-ast-write-extern-kind!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [kind : AstExternKind]) : unit
  (surface-ast-write-i64!
    out
    (match kind
      [(AstExternKind.Value) 0]
      [(AstExternKind.Function) 1])))

(define (surface-ast-read-extern-kind! [reader : SurfaceAstReader]) : AstExternKind
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (if (= tag 0)
      AstExternKind.Value
      (if (= tag 1)
        AstExternKind.Function
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid extern kind")
          AstExternKind.Value)))))

(define (surface-ast-write-extern-link-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [links : AstExternLinkInputList]) : unit
  (let
    [index : i64 0]
    [count : i64 (struct-get links len)]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (match (array-ref (struct-get links slots) index)
          [(AstExternLinkInput.Lib text)
            (begin
              (surface-ast-write-i64! out 0)
              (surface-ast-write-string! out text))]
          [(AstExternLinkInput.Search text)
            (begin
              (surface-ast-write-i64! out 1)
              (surface-ast-write-string! out text))]
          [(AstExternLinkInput.Arg text)
            (begin
              (surface-ast-write-i64! out 2)
              (surface-ast-write-string! out text))])
        (set! index (+ index 1))))))

(define (surface-ast-read-extern-link-list! [reader : SurfaceAstReader]) : AstExternLinkInputList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array AstExternLinkInput) (make-array AstExternLinkInput count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [tag : i64 (surface-ast-read-i64! reader)]
          [text : String (surface-ast-read-string! reader)]
          (begin
            (array-set!
              slots
              index
              (cond
                [(= tag 0) (AstExternLinkInput.Lib text)]
                [(= tag 1) (AstExternLinkInput.Search text)]
                [(= tag 2) (AstExternLinkInput.Arg text)]
                [else
                  (begin
                    (surface-ast-reader-fail!
                      reader
                      "surface ast: invalid extern link input")
                    (AstExternLinkInput.Arg text))]))
            (set! index (+ index 1)))))
      (AstExternLinkInputList slots count))))

(define (surface-ast-write-spmd-param-class!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : AstSpmdParamClass]) : unit
  (surface-ast-write-i64!
    out
    (match value
      [(AstSpmdParamClass.Uniform) 0]
      [(AstSpmdParamClass.Varying) 1])))

(define (surface-ast-read-spmd-param-class! [reader : SurfaceAstReader]) : AstSpmdParamClass
  (if (= (surface-ast-read-i64! reader) 0)
    AstSpmdParamClass.Uniform
    AstSpmdParamClass.Varying))

(define (surface-ast-write-spmd-param-class-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [items : AstSpmdParamClassList]) : unit
  (let
    [index : i64 0]
    [count : i64 (struct-get items len)]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (begin
          (surface-ast-write-spmd-param-class!
            out
            (array-ref (struct-get items slots) index))
          (set! index (+ index 1)))))))

(define (surface-ast-read-spmd-param-class-list! [reader : SurfaceAstReader]) : AstSpmdParamClassList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array AstSpmdParamClass) (make-array AstSpmdParamClass count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! slots index (surface-ast-read-spmd-param-class! reader))
          (set! index (+ index 1))))
      (AstSpmdParamClassList slots count))))

(define (surface-ast-write-spmd-result-class!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : AstSpmdResultClass]) : unit
  (surface-ast-write-i64!
    out
    (match value
      [(AstSpmdResultClass.Unit) 0]
      [(AstSpmdResultClass.Uniform) 1]
      [(AstSpmdResultClass.Varying) 2])))

(define (surface-ast-read-spmd-result-class! [reader : SurfaceAstReader]) : AstSpmdResultClass
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstSpmdResultClass.Unit]
      [(= tag 1) AstSpmdResultClass.Uniform]
      [(= tag 2) AstSpmdResultClass.Varying]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid spmd result class")
          AstSpmdResultClass.Unit)])))

(define (surface-ast-write-spmd-specialization-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [items : AstSpmdSpecializationList]) : unit
  (let
    [index : i64 0]
    [count : i64 (struct-get items len)]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (let
          [item : AstSpmdSpecialization
            (array-ref (struct-get items slots) index)]
          (begin
            (surface-ast-write-i64! out (struct-get item lanes))
            (surface-ast-write-spmd-param-class-list!
              out
              (box-get (struct-get item args)))
            (surface-ast-write-spmd-result-class! out (struct-get item result))
            (surface-ast-write-i64! out (struct-get item index-param))
            (set! index (+ index 1)))))
      unit)))

(define (surface-ast-read-spmd-specialization-list! [reader : SurfaceAstReader]) : AstSpmdSpecializationList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array AstSpmdSpecialization)
      (make-array AstSpmdSpecialization count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            slots
            index
            (AstSpmdSpecialization
              (surface-ast-read-i64! reader)
              (box (surface-ast-read-spmd-param-class-list! reader))
              (surface-ast-read-spmd-result-class! reader)
              (surface-ast-read-i64! reader)))
          (set! index (+ index 1))))
      (AstSpmdSpecializationList slots count))))

(define (surface-ast-write-fn-metadata!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [metadata : AstFnMetadata]) : unit
  (match metadata
    [(AstFnMetadata.No) (surface-ast-write-i64! out 0)]
    [(AstFnMetadata.Export name)
      (begin
        (surface-ast-write-i64! out 1)
        (surface-ast-write-name! out context name))]
    [(AstFnMetadata.SpmdCallable items)
      (begin
        (surface-ast-write-i64! out 2)
        (surface-ast-write-spmd-specialization-list! out (box-get items)))]))

(define (surface-ast-read-fn-metadata! [reader : SurfaceAstReader]) : AstFnMetadata
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstFnMetadata.No]
      [(= tag 1) (AstFnMetadata.Export (surface-ast-read-name! reader))]
      [(= tag 2)
        (AstFnMetadata.SpmdCallable
          (box (surface-ast-read-spmd-specialization-list! reader)))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid function metadata")
          AstFnMetadata.No)])))

(define (surface-ast-write-imported-spmd-specialization-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [items : AstImportedSpmdSpecializationList]) : unit
  (let
    [index : i64 0]
    [count : i64 (struct-get items len)]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (let
          [item : AstImportedSpmdSpecialization
            (array-ref (struct-get items slots) index)]
          (begin
            (surface-ast-write-name! out context (struct-get item abi))
            (surface-ast-write-name! out context (struct-get item backend))
            (surface-ast-write-i64! out (struct-get item lanes))
            (surface-ast-write-name! out context (struct-get item args))
            (surface-ast-write-name! out context (struct-get item result))
            (surface-ast-write-i64! out (struct-get item index-param))
            (surface-ast-write-name! out context (struct-get item symbol))
            (set! index (+ index 1)))))
      unit)))

(define (surface-ast-read-imported-spmd-specialization-list!
  [reader : SurfaceAstReader]) : AstImportedSpmdSpecializationList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array AstImportedSpmdSpecialization)
      (make-array AstImportedSpmdSpecialization count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            slots
            index
            (AstImportedSpmdSpecialization
              (surface-ast-read-name! reader)
              (surface-ast-read-name! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-name! reader)
              (surface-ast-read-name! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-name! reader)))
          (set! index (+ index 1))))
      (AstImportedSpmdSpecializationList slots count))))

(define (surface-ast-write-imported-spmd-callable-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [items : AstImportedSpmdCallableList]) : unit
  (let
    [index : i64 0]
    [count : i64 (struct-get items len)]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (let
          [item : AstImportedSpmdCallable
            (array-ref (struct-get items slots) index)]
          (begin
            (surface-ast-write-name! out context (struct-get item signature))
            (surface-ast-write-imported-spmd-specialization-list!
              out
              context
              (struct-get item specializations))
            (set! index (+ index 1)))))
      unit)))

(define (surface-ast-read-imported-spmd-callable-list!
  [reader : SurfaceAstReader]) : AstImportedSpmdCallableList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array AstImportedSpmdCallable)
      (make-array AstImportedSpmdCallable count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            slots
            index
            (AstImportedSpmdCallable
              (surface-ast-read-name! reader)
              (surface-ast-read-imported-spmd-specialization-list! reader)))
          (set! index (+ index 1))))
      (AstImportedSpmdCallableList slots count))))

(define (surface-ast-write-imported-spmd-metadata!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [metadata : AstImportedSpmdMetadata]) : unit
  (match metadata
    [(AstImportedSpmdMetadata.No) (surface-ast-write-i64! out 0)]
    [(AstImportedSpmdMetadata.Package name callables)
      (begin
        (surface-ast-write-i64! out 1)
        (surface-ast-write-name! out context name)
        (surface-ast-write-imported-spmd-callable-list!
          out
          context
          (box-get callables)))]))

(define (surface-ast-read-imported-spmd-metadata! [reader : SurfaceAstReader]) : AstImportedSpmdMetadata
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstImportedSpmdMetadata.No]
      [(= tag 1)
        (AstImportedSpmdMetadata.Package
          (surface-ast-read-name! reader)
          (box (surface-ast-read-imported-spmd-callable-list! reader)))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid imported spmd metadata")
          AstImportedSpmdMetadata.No)])))

(define (surface-ast-write-extern-metadata!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [metadata : AstExternMetadata]) : unit
  (match metadata
    [(AstExternMetadata.Metadata abi symbol links flags imported)
      (begin
        (surface-ast-write-extern-abi! out context abi)
        (surface-ast-write-name! out context symbol)
        (surface-ast-write-extern-link-list! out links)
        (surface-ast-write-i64! out flags)
        (surface-ast-write-imported-spmd-metadata! out context imported))]))

(define (surface-ast-read-extern-metadata! [reader : SurfaceAstReader]) : AstExternMetadata
  (AstExternMetadata.Metadata
    (surface-ast-read-extern-abi! reader)
    (surface-ast-read-name! reader)
    (surface-ast-read-extern-link-list! reader)
    (surface-ast-read-i64! reader)
    (surface-ast-read-imported-spmd-metadata! reader)))

(define (surface-ast-write-variant-cleanup!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [cleanup : AstVariantPayloadCleanup]) : unit
  (match cleanup
    [(AstVariantPayloadCleanup.No) (surface-ast-write-i64! out 0)]
    [(AstVariantPayloadCleanup.Fn name)
      (begin
        (surface-ast-write-i64! out 1)
        (surface-ast-write-name! out context name))]
    [(AstVariantPayloadCleanup.Owned) (surface-ast-write-i64! out 2)]))

(define (surface-ast-read-variant-cleanup! [reader : SurfaceAstReader]) : AstVariantPayloadCleanup
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstVariantPayloadCleanup.No]
      [(= tag 1) (AstVariantPayloadCleanup.Fn (surface-ast-read-name! reader))]
      [(= tag 2) AstVariantPayloadCleanup.Owned]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid variant cleanup")
          AstVariantPayloadCleanup.No)])))

(define (surface-ast-write-variant-def-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [variants : AstVariantDefList]) : unit
  (let
    [index : i64 0]
    [count : i64 (struct-get variants len)]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (match (array-ref (struct-get variants slots) index)
          [(AstVariantDef.Def name fields cleanups)
            (let
              [cleanup-index : i64 0]
              (begin
                (surface-ast-write-name! out context name)
                (surface-ast-write-type-list! out fields)
                (surface-ast-write-i64! out (struct-get cleanups len))
                (while (< cleanup-index (struct-get cleanups len))
                  (begin
                    (surface-ast-write-variant-cleanup!
                      out
                      context
                      (array-ref (struct-get cleanups slots) cleanup-index))
                    (set! cleanup-index (+ cleanup-index 1))))))])
        (set! index (+ index 1))))))

(define (surface-ast-read-variant-def-list! [reader : SurfaceAstReader]) : AstVariantDefList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array AstVariantDef) (make-array AstVariantDef count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [name : i64 (surface-ast-read-name! reader)]
          [fields : AstTypeList (surface-ast-read-type-list! reader)]
          [cleanup-count : i64 (surface-ast-read-count! reader)]
          [cleanup-slots : (Array AstVariantPayloadCleanup)
            (make-array AstVariantPayloadCleanup cleanup-count)]
          [cleanup-index : i64 0]
          (begin
            (while (< cleanup-index cleanup-count)
              (begin
                (array-set!
                  cleanup-slots
                  cleanup-index
                  (surface-ast-read-variant-cleanup! reader))
                (set! cleanup-index (+ cleanup-index 1))))
            (array-set!
              slots
              index
              (AstVariantDef.Def
                name
                fields
                (AstVariantPayloadCleanupList cleanup-slots cleanup-count)))
            (set! index (+ index 1)))))
      (AstVariantDefList slots count))))

(define (surface-ast-write-struct-cleanup!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [cleanup : AstStructCleanup]) : unit
  (match cleanup
    [(AstStructCleanup.No) (surface-ast-write-i64! out 0)]
    [(AstStructCleanup.Fn name)
      (begin
        (surface-ast-write-i64! out 1)
        (surface-ast-write-name! out context name))]))

(define (surface-ast-read-struct-cleanup! [reader : SurfaceAstReader]) : AstStructCleanup
  (if (= (surface-ast-read-i64! reader) 0)
    AstStructCleanup.No
    (AstStructCleanup.Fn (surface-ast-read-name! reader))))

(define (surface-ast-write-enum-cleanup!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [cleanup : AstEnumCleanup]) : unit
  (match cleanup
    [(AstEnumCleanup.No) (surface-ast-write-i64! out 0)]
    [(AstEnumCleanup.Fn name)
      (begin
        (surface-ast-write-i64! out 1)
        (surface-ast-write-name! out context name))]))

(define (surface-ast-read-enum-cleanup! [reader : SurfaceAstReader]) : AstEnumCleanup
  (if (= (surface-ast-read-i64! reader) 0)
    AstEnumCleanup.No
    (AstEnumCleanup.Fn (surface-ast-read-name! reader))))

(define (surface-ast-write-maybe-module-name!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [value : AstMaybeModuleName]) : unit
  (match value
    [(AstMaybeModuleName.No) (surface-ast-write-i64! out 0)]
    [(AstMaybeModuleName.Some name)
      (begin
        (surface-ast-write-i64! out 1)
        (surface-ast-write-name! out context name))]))

(define (surface-ast-read-maybe-module-name! [reader : SurfaceAstReader]) : AstMaybeModuleName
  (if (= (surface-ast-read-i64! reader) 0)
    AstMaybeModuleName.No
    (AstMaybeModuleName.Some (surface-ast-read-name! reader))))

(define (surface-ast-write-maybe-import-alias!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [value : AstMaybeImportAlias]) : unit
  (match value
    [(AstMaybeImportAlias.No) (surface-ast-write-i64! out 0)]
    [(AstMaybeImportAlias.Some name)
      (begin
        (surface-ast-write-i64! out 1)
        (surface-ast-write-name! out context name))]))

(define (surface-ast-read-maybe-import-alias! [reader : SurfaceAstReader]) : AstMaybeImportAlias
  (if (= (surface-ast-read-i64! reader) 0)
    AstMaybeImportAlias.No
    (AstMaybeImportAlias.Some (surface-ast-read-name! reader))))

(define (surface-ast-write-import-kind!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [kind : AstImportKind]) : unit
  (match kind
    [(AstImportKind.Path) (surface-ast-write-i64! out 0)]
    [(AstImportKind.Module) (surface-ast-write-i64! out 1)]
    [(AstImportKind.Macro call module-name)
      (begin
        (surface-ast-write-i64! out 2)
        (surface-ast-write-i64! out call)
        (surface-ast-write-maybe-module-name! out context module-name))]
    [(AstImportKind.MacroDecls call module-name)
      (begin
        (surface-ast-write-i64! out 3)
        (surface-ast-write-i64! out call)
        (surface-ast-write-maybe-module-name! out context module-name))]))

(define (surface-ast-read-import-kind! [reader : SurfaceAstReader]) : AstImportKind
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstImportKind.Path]
      [(= tag 1) AstImportKind.Module]
      [(= tag 2)
        (AstImportKind.Macro
          (surface-ast-read-i64! reader)
          (surface-ast-read-maybe-module-name! reader))]
      [(= tag 3)
        (AstImportKind.MacroDecls
          (surface-ast-read-i64! reader)
          (surface-ast-read-maybe-module-name! reader))]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid import kind")
          AstImportKind.Path)])))

(define (surface-ast-write-import-spec!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [spec : AstImportSpec]) : unit
  (match spec
    [(AstImportSpec.Spec kind path module-name alias span)
      (begin
        (surface-ast-write-import-kind! out context kind)
        (surface-ast-write-string! out path)
        (surface-ast-write-maybe-module-name! out context module-name)
        (surface-ast-write-maybe-import-alias! out context alias)
        (surface-ast-write-span! out (box-get span)))]))

(define (surface-ast-read-import-spec! [reader : SurfaceAstReader]) : AstImportSpec
  (AstImportSpec.Spec
    (surface-ast-read-import-kind! reader)
    (surface-ast-read-string! reader)
    (surface-ast-read-maybe-module-name! reader)
    (surface-ast-read-maybe-import-alias! reader)
    (box (surface-ast-read-span! reader))))

(define (surface-ast-write-dispatch-variant-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [variants : AstDispatchVariantList]) : unit
  (let
    [index : i64 0]
    [count : i64 (struct-get variants len)]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (match (array-ref (struct-get variants slots) index)
          [(AstDispatchVariant.Variant isa name)
            (begin
              (surface-ast-write-i64!
                out
                (match isa
                  [(AstDispatchIsa.Scalar) 0]
                  [(AstDispatchIsa.Avx2) 1]
                  [(AstDispatchIsa.Avx512) 2]))
              (surface-ast-write-name! out context name))])
        (set! index (+ index 1))))))

(define (surface-ast-read-dispatch-variant-list! [reader : SurfaceAstReader]) : AstDispatchVariantList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array AstDispatchVariant) (make-array AstDispatchVariant count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [tag : i64 (surface-ast-read-i64! reader)]
          [isa : AstDispatchIsa
            (cond
              [(= tag 0) AstDispatchIsa.Scalar]
              [(= tag 1) AstDispatchIsa.Avx2]
              [(= tag 2) AstDispatchIsa.Avx512]
              [else
                (begin
                  (surface-ast-reader-fail!
                    reader
                    "surface ast: invalid dispatch isa")
                  AstDispatchIsa.Scalar)])]
          (begin
            (array-set!
              slots
              index
              (AstDispatchVariant.Variant isa (surface-ast-read-name! reader)))
            (set! index (+ index 1)))))
      (AstDispatchVariantList slots count))))

(define (surface-ast-write-decl-meta!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [_context : SurfaceAstWriteContext]
  [meta : AstDeclMeta]) : unit
  (match (box-get (struct-get meta value))
    [(AstDeclMetaValue.Runtime) (surface-ast-write-i64! out 0)]
    [(AstDeclMetaValue.Comptime generated)
      (begin
        (surface-ast-write-i64! out 1)
        (match generated
          [(AstGeneratedDeclMeta.No) (surface-ast-write-i64! out 0)]
          [(AstGeneratedDeclMeta.Some generator item args key)
            (begin
              (surface-ast-write-i64! out 1)
              (surface-ast-write-string! out generator)
              (surface-ast-write-string! out item)
              (surface-ast-write-expr-list! out args)
              (surface-ast-write-string! out key))]))]))

(define (surface-ast-read-decl-meta! [reader : SurfaceAstReader]) : AstDeclMeta
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (if (= tag 0)
      ast-decl-meta-runtime
      (if (= tag 1)
        (let
          [generated-tag : i64 (surface-ast-read-i64! reader)]
          [generated : AstGeneratedDeclMeta
            (if (= generated-tag 0)
              AstGeneratedDeclMeta.No
              (if (= generated-tag 1)
                (AstGeneratedDeclMeta.Some
                  (surface-ast-read-string! reader)
                  (surface-ast-read-string! reader)
                  (surface-ast-read-expr-list! reader)
                  (surface-ast-read-string! reader))
                (begin
                  (surface-ast-reader-fail!
                    reader
                    "surface ast: invalid generated declaration metadata")
                  AstGeneratedDeclMeta.No)))]
          (AstDeclMeta (box (AstDeclMetaValue.Comptime generated))))
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid declaration metadata")
          ast-decl-meta-runtime)))))

(define (surface-ast-write-decl!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [decl : AstDecl]) : unit
  (match decl
    [(AstDecl.Module name)
      (begin
        (surface-ast-write-i64! out 0)
        (surface-ast-write-name! out context name))]
    [(AstDecl.ModuleBody name body)
      (begin
        (surface-ast-write-i64! out 1)
        (surface-ast-write-name! out context name)
        (surface-ast-write-decl-list! out context (box-get body)))]
    [(AstDecl.Def meta name maybe-ty value)
      (begin
        (surface-ast-write-i64! out 2)
        (surface-ast-write-decl-meta! out context meta)
        (surface-ast-write-name! out context name)
        (surface-ast-write-maybe-type! out context maybe-ty)
        (surface-ast-write-i64! out value))]
    [(AstDecl.DefFn meta name params ret body metadata)
      (begin
        (surface-ast-write-i64! out 3)
        (surface-ast-write-decl-meta! out context meta)
        (surface-ast-write-name! out context name)
        (surface-ast-write-param-list! out context params)
        (surface-ast-write-type! out context ret)
        (surface-ast-write-i64! out body)
        (surface-ast-write-fn-metadata! out context metadata))]
    [(AstDecl.DefMacro meta name params ret body)
      (begin
        (surface-ast-write-i64! out 4)
        (surface-ast-write-decl-meta! out context meta)
        (surface-ast-write-name! out context name)
        (surface-ast-write-macro-param-list! out context params)
        (surface-ast-write-type! out context ret)
        (surface-ast-write-i64! out body))]
    [(AstDecl.Extern meta name kind metadata ty)
      (begin
        (surface-ast-write-i64! out 5)
        (surface-ast-write-decl-meta! out context meta)
        (surface-ast-write-name! out context name)
        (surface-ast-write-extern-kind! out kind)
        (surface-ast-write-extern-metadata! out context (box-get metadata))
        (surface-ast-write-type! out context ty))]
    [(AstDecl.DefEnum meta name cleanup variants)
      (begin
        (surface-ast-write-i64! out 6)
        (surface-ast-write-decl-meta! out context meta)
        (surface-ast-write-name! out context name)
        (surface-ast-write-enum-cleanup! out context cleanup)
        (surface-ast-write-variant-def-list! out context variants))]
    [(AstDecl.DefEnumLifetimes meta name lifetimes cleanup variants)
      (begin
        (surface-ast-write-i64! out 7)
        (surface-ast-write-decl-meta! out context meta)
        (surface-ast-write-name! out context name)
        (surface-ast-write-lifetime-list! out context lifetimes)
        (surface-ast-write-enum-cleanup! out context cleanup)
        (surface-ast-write-variant-def-list! out context variants))]
    [(AstDecl.DefStruct meta name repr cleanup fields)
      (begin
        (surface-ast-write-i64! out 8)
        (surface-ast-write-decl-meta! out context meta)
        (surface-ast-write-name! out context name)
        (surface-ast-write-struct-repr! out repr)
        (surface-ast-write-struct-cleanup! out context cleanup)
        (surface-ast-write-field-def-list! out context fields))]
    [(AstDecl.DefStructLifetimes meta name lifetimes repr cleanup fields)
      (begin
        (surface-ast-write-i64! out 9)
        (surface-ast-write-decl-meta! out context meta)
        (surface-ast-write-name! out context name)
        (surface-ast-write-lifetime-list! out context lifetimes)
        (surface-ast-write-struct-repr! out repr)
        (surface-ast-write-struct-cleanup! out context cleanup)
        (surface-ast-write-field-def-list! out context fields))]
    [(AstDecl.Import meta spec)
      (begin
        (surface-ast-write-i64! out 10)
        (surface-ast-write-decl-meta! out context meta)
        (surface-ast-write-import-spec! out context spec))]
    [(AstDecl.IncludeStr name path)
      (begin
        (surface-ast-write-i64! out 11)
        (surface-ast-write-name! out context name)
        (surface-ast-write-string! out path))]
    [(AstDecl.IncludeStrComptime name path)
      (begin
        (surface-ast-write-i64! out 12)
        (surface-ast-write-name! out context name)
        (surface-ast-write-string! out path))]
    [(AstDecl.IncludeStrLzss name path)
      (begin
        (surface-ast-write-i64! out 13)
        (surface-ast-write-name! out context name)
        (surface-ast-write-string! out path))]
    [(AstDecl.IncludeBin name path)
      (begin
        (surface-ast-write-i64! out 14)
        (surface-ast-write-name! out context name)
        (surface-ast-write-string! out path))]
    [(AstDecl.DefDispatch meta name variants)
      (begin
        (surface-ast-write-i64! out 15)
        (surface-ast-write-decl-meta! out context meta)
        (surface-ast-write-name! out context name)
        (surface-ast-write-dispatch-variant-list! out context variants))]
    [(AstDecl.Test name body span)
      (begin
        (surface-ast-write-i64! out 16)
        (surface-ast-write-name! out context name)
        (surface-ast-write-i64! out body)
        (surface-ast-write-span! out span))]
    [(AstDecl.Unsafe inner)
      (begin
        (surface-ast-write-i64! out 17)
        (surface-ast-write-decl! out context (box-get inner)))]))

(define (surface-ast-write-decl-list!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [decls : AstDeclList]) : unit
  (let
    [count : i64 (struct-get decls len)]
    [index : i64 0]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (begin
          (surface-ast-write-decl!
            out
            context
            (array-ref
              (struct-get decls slots)
              (+ (struct-get decls offset) index)))
          (set! index (+ index 1)))))))

(define (surface-ast-read-decl! [reader : SurfaceAstReader]) : AstDecl
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) (AstDecl.Module (surface-ast-read-name! reader))]
      [(= tag 1)
        (AstDecl.ModuleBody
          (surface-ast-read-name! reader)
          (box (surface-ast-read-decl-list! reader)))]
      [(= tag 2)
        (AstDecl.Def
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-name! reader)
          (surface-ast-read-maybe-type! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 3)
        (AstDecl.DefFn
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-name! reader)
          (surface-ast-read-param-list! reader)
          (surface-ast-read-type! reader)
          (surface-ast-read-i64! reader)
          (surface-ast-read-fn-metadata! reader))]
      [(= tag 4)
        (AstDecl.DefMacro
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-name! reader)
          (surface-ast-read-macro-param-list! reader)
          (surface-ast-read-type! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 5)
        (AstDecl.Extern
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-name! reader)
          (surface-ast-read-extern-kind! reader)
          (box (surface-ast-read-extern-metadata! reader))
          (surface-ast-read-type! reader))]
      [(= tag 6)
        (AstDecl.DefEnum
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-name! reader)
          (surface-ast-read-enum-cleanup! reader)
          (surface-ast-read-variant-def-list! reader))]
      [(= tag 7)
        (AstDecl.DefEnumLifetimes
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-name! reader)
          (surface-ast-read-lifetime-list! reader)
          (surface-ast-read-enum-cleanup! reader)
          (surface-ast-read-variant-def-list! reader))]
      [(= tag 8)
        (AstDecl.DefStruct
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-name! reader)
          (surface-ast-read-struct-repr! reader)
          (surface-ast-read-struct-cleanup! reader)
          (surface-ast-read-field-def-list! reader))]
      [(= tag 9)
        (AstDecl.DefStructLifetimes
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-name! reader)
          (surface-ast-read-lifetime-list! reader)
          (surface-ast-read-struct-repr! reader)
          (surface-ast-read-struct-cleanup! reader)
          (surface-ast-read-field-def-list! reader))]
      [(= tag 10)
        (AstDecl.Import
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-import-spec! reader))]
      [(= tag 11)
        (AstDecl.IncludeStr
          (surface-ast-read-name! reader)
          (surface-ast-read-string! reader))]
      [(= tag 12)
        (AstDecl.IncludeStrComptime
          (surface-ast-read-name! reader)
          (surface-ast-read-string! reader))]
      [(= tag 13)
        (AstDecl.IncludeStrLzss
          (surface-ast-read-name! reader)
          (surface-ast-read-string! reader))]
      [(= tag 14)
        (AstDecl.IncludeBin
          (surface-ast-read-name! reader)
          (surface-ast-read-string! reader))]
      [(= tag 15)
        (AstDecl.DefDispatch
          (surface-ast-read-decl-meta! reader)
          (surface-ast-read-name! reader)
          (surface-ast-read-dispatch-variant-list! reader))]
      [(= tag 16)
        (AstDecl.Test
          (surface-ast-read-name! reader)
          (surface-ast-read-i64! reader)
          (surface-ast-read-span! reader))]
      [(= tag 17) (AstDecl.Unsafe (box (surface-ast-read-decl! reader)))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid declaration tag")
          (AstDecl.Module (surface-ast-read-name! reader)))])))

(define (surface-ast-read-decl-list! [reader : SurfaceAstReader]) : AstDeclList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array AstDecl) (make-array AstDecl count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! slots index (surface-ast-read-decl! reader))
          (set! index (+ index 1))))
      (AstDeclList slots 0 count true))))

(define (surface-ast-seen-count [seen : sym_i64_env.SymI64Env]) : i64
  (let
    [cursor : sym_i64_env.SymI64Env seen]
    [count : i64 0]
    (begin
      (while true
        (match cursor
          [(sym_i64_env.SymI64Nil) (return count)]
          [(sym_i64_env.SymI64Bind _ _ rest)
            (begin
              (set! count (+ count 1))
              (set! cursor (box-get rest)))]))
      count)))

(define (surface-ast-write-paths!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [paths : AstDeclPathList]) : unit
  (let
    [index : i64 0]
    [count : i64 (ast-decl-path-list-len (& paths))]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (begin
          (surface-ast-write-string!
            out
            (array-ref
              (struct-get paths slots)
              (+ (struct-get paths offset) index)))
          (surface-ast-write-name!
            out
            context
            (array-ref
              (struct-get paths owner-ids)
              (+ (struct-get paths offset) index)))
          (set! index (+ index 1)))))))

(define (surface-ast-read-paths! [reader : SurfaceAstReader]) : AstDeclPathList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array String) (make-array String count)]
    [owners : (Array i64) (make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! slots index (surface-ast-read-string! reader))
          (array-set! owners index (surface-ast-read-name! reader))
          (set! index (+ index 1))))
      (AstDeclPathList slots owners 0 count true))))

(define (surface-ast-write-modules!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [modules : AstDeclModuleList]) : unit
  (let
    [index : i64 0]
    [count : i64 (ast-decl-module-list-len (& modules))]
    (begin
      (surface-ast-write-i64! out count)
      (while (< index count)
        (begin
          (surface-ast-write-name!
            out
            context
            (array-ref
              (struct-get modules slots)
              (+ (struct-get modules offset) index)))
          (set! index (+ index 1)))))))

(define (surface-ast-read-modules! [reader : SurfaceAstReader]) : AstDeclModuleList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (Array i64) (make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! slots index (surface-ast-read-name! reader))
          (set! index (+ index 1))))
      (AstDeclModuleList slots 0 count true))))

(define (surface-ast-write-seen!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [seen : sym_i64_env.SymI64Env]) : unit
  (let
    [cursor : sym_i64_env.SymI64Env seen]
    (begin
      (while true
        (match cursor
          [(sym_i64_env.SymI64Nil)
            (begin
              (surface-ast-write-i64! out 0)
              (return unit))]
          [(sym_i64_env.SymI64Bind key value rest)
            (begin
              (surface-ast-write-i64! out 1)
              (surface-ast-write-name! out context key)
              (surface-ast-write-i64! out value)
              (set! cursor (box-get rest)))]))
      unit)))

(define (surface-ast-read-seen! [reader : SurfaceAstReader]) : sym_i64_env.SymI64Env
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) (sym_i64_env.sym-i64-empty)]
      [(= tag 1)
        (let
          [key : i64 (surface-ast-read-name! reader)]
          [value : i64 (surface-ast-read-i64! reader)]
          [rest : sym_i64_env.SymI64Env (surface-ast-read-seen! reader)]
          (sym_i64_env.sym-i64-bind-id rest key value))]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid seen-set list")
          (sym_i64_env.sym-i64-empty))])))

(define (surface-ast-write-compacted!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [context : SurfaceAstWriteContext]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : unit
  (let
    [type-count : i64 (ast-node-pool-context-type-len pools)]
    [expr-count : i64 (ast-node-pool-context-expr-len pools)]
    [index : i64 0]
    (begin
      (surface-ast-write-i64! out surface-ast-magic)
      (surface-ast-write-i64! out surface-ast-schema-version)
      (surface-ast-write-i64! out (struct-get context identity-count))
      (surface-ast-write-i64! out type-count)
      (surface-ast-write-i64! out expr-count)
      (while (< index type-count)
        (begin
          (surface-ast-write-type!
            out
            context
            (ast-node-pool-context-type-get pools index))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index expr-count)
        (begin
          (surface-ast-write-expr!
            out
            context
            (ast-node-pool-context-expr-get pools index))
          (set! index (+ index 1))))
      (match program
        [(AstProgram.Program decls)
          (surface-ast-write-decl-list! out context (box-get decls))])
      (surface-ast-write-paths! out context paths)
      (surface-ast-write-modules! out context modules)
      (surface-ast-write-seen! out context seen))))

(define (surface-ast-encode
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
  [source-pools : AstNodePoolContext]
  [source-identity-count : i64]
  [identity-count : i64]) : ResultSurfaceAstBytes
  (let
    [previous-arena : i64 (arena.tl_arena_current)]
    [surface-arena : i64 (arena.tl_arena_make)]
    [dest-pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        (ast-node-pool-context-expr-len source-pools)
        (ast-node-pool-context-type-len source-pools)
        surface-arena)]
    [compaction : AstProgramCompaction
      (ast-program-compact-with-pools
        source-pools
        dest-pools
        (ast-program decls))]
    [context : SurfaceAstWriteContext
      (surface-ast-write-context-new source-identity-count identity-count)]
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (begin
      (match compaction
        [(AstProgramCompaction compacted-program compacted-pools)
          (surface-ast-write-compacted!
            (&mut out)
            context
            compacted-program
            paths
            modules
            seen
            compacted-pools)])
      (let
        [bytes : (Array u8)
          (byte_buf_core.byte-buf-builder-finish-array (& out))]
        (begin
          (unsafe
            (arena.tl_arena_set previous-arena))
          (unsafe
            (arena.tl_arena_destroy
              (ast-node-pool-context-base-arena dest-pools)))
          (if (surface-ast-write-valid? context)
            (ResultSurfaceAstBytes.Ok bytes)
            (ResultSurfaceAstBytes.Err
              "surface ast: encountered an identity outside the package table")))))))

(define (surface-ast-decode-pools!
  [reader : SurfaceAstReader]
  [pools : AstNodePoolContext]
  [type-count : i64]
  [expr-count : i64]) : unit
  (let
    [index : i64 0]
    (begin
      (ast-node-pool-context-reset-to! pools 0 0)
      (while (< index type-count)
        (let
          [new-id : i64
            (ast-node-pool-context-type-push
              pools
              (surface-ast-read-type! reader))]
          (begin
            (if (= new-id index)
              unit
              (surface-ast-reader-fail!
                reader
                "surface ast: non-canonical serialized type pool"))
            (set! index (+ index 1)))))
      (set! index 0)
      (while (< index expr-count)
        (let
          [new-id : i64
            (ast-node-pool-context-expr-push
              pools
              (surface-ast-read-expr! reader))]
          (begin
            (if (= new-id index)
              unit
              (surface-ast-reader-fail!
                reader
                "surface ast: non-canonical serialized expression pool"))
            (set! index (+ index 1))))))))

(define (surface-ast-decode
  [bytes : (Array u8)]
  [identity-remap : (Array i64)]
  [pools : AstNodePoolContext]) : ResultSurfaceAstHydration
  (let
    [reader : SurfaceAstReader (surface-ast-reader-new bytes identity-remap)]
    [magic : i64 (surface-ast-read-i64! reader)]
    [schema : i64 (surface-ast-read-i64! reader)]
    [identity-count : i64 (surface-ast-read-i64! reader)]
    [type-count : i64 (surface-ast-read-count! reader)]
    [expr-count : i64 (surface-ast-read-count! reader)]
    (if (or
      (not (= magic surface-ast-magic))
      (not (= schema surface-ast-schema-version))
      (not (= identity-count (array-length identity-remap))))
      (ResultSurfaceAstHydration.Err
        "surface ast: bad magic, schema, or identity binding")
      (begin
        (surface-ast-decode-pools! reader pools type-count expr-count)
        (let
          [decls : AstDeclList (surface-ast-read-decl-list! reader)]
          [paths : AstDeclPathList (surface-ast-read-paths! reader)]
          [modules : AstDeclModuleList (surface-ast-read-modules! reader)]
          [seen : sym_i64_env.SymI64Env (surface-ast-read-seen! reader)]
          (cond
            [(not (surface-ast-reader-valid? reader))
              (ResultSurfaceAstHydration.Err
                (surface-ast-reader-message reader))]
            [(not (= (surface-ast-reader-offset reader) (array-length bytes)))
              (ResultSurfaceAstHydration.Err
                "surface ast: trailing payload bytes")]
            [(or
                (not
                  (=
                    (ast-decl-list-len (& decls))
                    (ast-decl-path-list-len (& paths))))
                (not
                  (=
                    (ast-decl-list-len (& decls))
                    (ast-decl-module-list-len (& modules)))))
              (ResultSurfaceAstHydration.Err
                "surface ast: declaration provenance lists are misaligned")]
            [else
              (ResultSurfaceAstHydration.Ok
                (SurfaceAstHydration decls paths modules seen pools))]))))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-tests-ok?) : bool
    (let
      [_reset : unit (ci.intern-reset!)]
      [module-id : i64 (ci.intern "test.module")]
      [path-id : i64 (ci.intern "test.tl")]
      [fn-id : i64 (ci.intern "main")]
      [source-pools : AstNodePoolContext
        (ast-node-pool-context-new-with-capacities 8 8)]
      [left : i64
        (ast-node-pool-context-expr-push
          source-pools
          (AstExpr.Literal (AstLiteral.Int 20 "20")))]
      [right : i64
        (ast-node-pool-context-expr-push
          source-pools
          (AstExpr.Literal (AstLiteral.Int 22 "22")))]
      [body : i64
        (ast-node-pool-context-expr-push
          source-pools
          (AstExpr.Binary AstBinOp.Add left right))]
      [decl-slots : (Array AstDecl) (make-array AstDecl 1)]
      [path-slots : (Array String) (make-array String 1)]
      [owner-slots : (Array i64) (make-array i64 1)]
      [module-slots : (Array i64) (make-array i64 1)]
      [key-modules : (Array String) (make-array String 1)]
      (begin
        (array-set!
          decl-slots
          0
          (AstDecl.DefFn
            ast-decl-meta-runtime
            fn-id
            (AstParamList (make-array AstParam 0) 0)
            AstType.I64
            body
            AstFnMetadata.No))
        (array-set! path-slots 0 "test.tl")
        (array-set! owner-slots 0 module-id)
        (array-set! module-slots 0 module-id)
        (array-set! key-modules 0 "test.tl")
        (let
          [decls : AstDeclList (AstDeclList decl-slots 0 1 true)]
          [paths : AstDeclPathList
            (AstDeclPathList path-slots owner-slots 0 1 true)]
          [modules : AstDeclModuleList
            (AstDeclModuleList module-slots 0 1 true)]
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
          [source-count : i64
            (array-length (struct-get identity-payload source-names))]
          [identity-count : i64
            (+
              source-count
              (array-length (struct-get identity-payload generated)))]
          (match (surface_identity.surface-identity-encode identity-payload)
            [(surface_identity.ResultSurfaceIdentityBytes.Err _) false]
            [(surface_identity.ResultSurfaceIdentityBytes.Ok identity-bytes)
              (match (surface-ast-encode
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
                            [dest-pools : AstNodePoolContext
                              (ast-node-pool-context-new-with-capacities 8 8)]
                            (match (surface-ast-decode
                              ast-bytes
                              (struct-get identity-hydration remap)
                              dest-pools)
                              [(ResultSurfaceAstHydration.Err _) false]
                              [(ResultSurfaceAstHydration.Ok hydration)
                                (and
                                  (=
                                    (ast-node-pool-context-expr-len
                                      (struct-get hydration pools))
                                    3)
                                  (=
                                    (ast-decl-list-len
                                      (& (struct-get hydration decls)))
                                    1)
                                  (match (array-ref
                                    (struct-get
                                      (struct-get hydration decls)
                                      slots)
                                    0)
                                    [(AstDecl.DefFn
                                        _
                                        hydrated-name
                                        _
                                        _
                                        hydrated-body
                                        _)
                                      (and
                                        (surface_identity.surface-identity-string-eq?
                                          (ci.intern-str hydrated-name)
                                          "main")
                                        (match (ast-node-pool-context-expr-get
                                          (struct-get hydration pools)
                                          hydrated-body)
                                          [(AstExpr.Binary op _ _)
                                            (match op
                                              [(AstBinOp.Add) true]
                                              [_ false])]
                                          [_ false]))]
                                    [_ false]))]))])))])]))))))

(cfg
  compiler-surface-selftest
  (define (surface-ast-selftest-main) : i64
    (if (surface-ast-tests-ok?)
      42
      1)))