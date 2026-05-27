;; compiler_ir_types.tl - Self-hosted compiler IR model (#446).
;;
;; This is the first selfhost IR shape for the real compiler pipeline. The data
;; model is intentionally close to the Rust IR: functions contain blocks, blocks
;; contain typed instructions, and instructions use explicit vars/values.
(import "compiler_ast_types.tl")

(defenum CompilerIrBinOp
  (IrBinAdd)
  (IrBinSub)
  (IrBinMul)
  (IrBinDiv)
  (IrBinMod)
  (IrBinEq)
  (IrBinNe)
  (IrBinLt)
  (IrBinLe)
  (IrBinGt)
  (IrBinGe)
  (IrBinAnd)
  (IrBinOr)
  (IrBinBitAnd)
  (IrBinBitOr)
  (IrBinBitXor)
  (IrBinShl)
  (IrBinShr))

(defenum CompilerIrUnOp
  (IrUnNeg)
  (IrUnNot)
  (IrUnBitNot))

(defenum CompilerIrMaskBinOp
  (IrMaskAnd)
  (IrMaskOr))

(defenum CompilerIrVectorReduceOp
  (IrVectorReduceSum)
  (IrVectorReduceMin)
  (IrVectorReduceMax))

(defenum CompilerIrMaskReduceOp
  (IrMaskReduceAll)
  (IrMaskReduceAny))

(defenum CompilerIrValue
  (IrValueVar i64)
  (IrValueGlobal String)
  (IrValueI64 i64)
  (IrValueF64 String)
  (IrValueBool bool)
  (IrValueChar char)
  (IrValueString String)
  (IrValueUnit))

(defenum CompilerIrMaybeValue
  (IrNoValue)
  (IrSomeValue CompilerIrValue))

(defenum CompilerIrValueList
  (IrValueNil)
  (IrValueCons CompilerIrValue CompilerIrValueList))

(defenum CompilerIrPhiInput
  (IrPhiInput CompilerIrValue String))

(defenum CompilerIrPhiInputList
  (IrPhiInputNil)
  (IrPhiInputCons CompilerIrPhiInput CompilerIrPhiInputList))

(defenum CompilerIrInstr
  (IrInstrMov i64 CompilerIrValue AstType)
  (IrInstrAlloc i64 AstType)
  (IrInstrAddrOf i64 i64)
  (IrInstrGep i64 CompilerIrValue CompilerIrValue AstType)
  (IrInstrLoad i64 CompilerIrValue AstType)
  (IrInstrStorePtr CompilerIrValue CompilerIrValue AstType)
  (IrInstrBoundsCheck CompilerIrValue CompilerIrValue String)
  (IrInstrCast i64 CompilerIrValue AstType AstType)
  (IrInstrBinOp i64 CompilerIrBinOp CompilerIrValue CompilerIrValue AstType)
  (IrInstrUnOp i64 CompilerIrUnOp CompilerIrValue AstType)
  (IrInstrLaneId i64 i64 AstType)
  (IrInstrSplat i64 CompilerIrValue i64 AstType)
  (IrInstrVectorBinOp
    i64
    CompilerIrBinOp
    CompilerIrValue
    CompilerIrValue
    i64
    AstType)
  (IrInstrVectorReduce i64 CompilerIrVectorReduceOp CompilerIrValue i64 AstType)
  (IrInstrVectorCompare
    i64
    CompilerIrBinOp
    CompilerIrValue
    CompilerIrValue
    i64
    AstType)
  (IrInstrMaskBinOp i64 CompilerIrMaskBinOp CompilerIrValue CompilerIrValue i64)
  (IrInstrMaskNot i64 CompilerIrValue i64)
  (IrInstrMaskReduce i64 CompilerIrMaskReduceOp CompilerIrValue i64)
  (IrInstrSelect
    i64
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    i64
    AstType)
  (IrInstrVectorLoad i64 CompilerIrValue CompilerIrValue i64 AstType)
  (IrInstrVectorStore
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    i64
    AstType)
  (IrInstrPredicatedStore
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    i64
    AstType)
  (IrInstrPredicatedLoad
    i64
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    i64
    AstType)
  (IrInstrTailMask i64 CompilerIrValue CompilerIrValue i64)
  (IrInstrCall i64 String CompilerIrValueList AstType)
  (IrInstrStore String CompilerIrValue AstType)
  (IrInstrJump String)
  (IrInstrBranch CompilerIrValue String String)
  (IrInstrReturn CompilerIrMaybeValue)
  (IrInstrPhi i64 CompilerIrPhiInputList AstType))

(defenum CompilerIrInstrList
  (IrInstrNil)
  (IrInstrCons CompilerIrInstr CompilerIrInstrList))

(defenum CompilerIrBlock
  (IrBlock String CompilerIrInstrList))

(defenum CompilerIrBlockList
  (IrBlockNil)
  (IrBlockCons CompilerIrBlock CompilerIrBlockList))

(defenum CompilerIrParam
  (IrParam String AstType i64))

(defenum CompilerIrParamList
  (IrParamNil)
  (IrParamCons CompilerIrParam CompilerIrParamList))

(defenum CompilerIrFunction
  (IrFunction String CompilerIrParamList AstType i64 CompilerIrBlockList))

(defenum CompilerIrFunctionList
  (IrFunctionNil)
  (IrFunctionCons CompilerIrFunction CompilerIrFunctionList))

(defenum CompilerIrGlobal
  (IrGlobal String AstType CompilerIrValue))

(defenum CompilerIrGlobalList
  (IrGlobalNil)
  (IrGlobalCons CompilerIrGlobal CompilerIrGlobalList))

(defenum CompilerIrExtern
  (IrExtern String AstType AstExternAbi String))

(defenum CompilerIrExternList
  (IrExternNil)
  (IrExternCons CompilerIrExtern CompilerIrExternList))

(defenum CompilerIrProgram
  (IrProgram CompilerIrGlobalList CompilerIrFunctionList CompilerIrExternList))

(define (compiler-ir-extern-default [name : String] [ty : AstType]) : CompilerIrExtern
  (IrExtern name ty (AstExternAbiC) name))

(defenum CompilerIrEffect
  (IrEffectPure)
  (IrEffectMemoryRead)
  (IrEffectMemoryWrite)
  (IrEffectControlFlow)
  (IrEffectUnknown))

(define (compiler-ir-effect-eq? [a : CompilerIrEffect] [b : CompilerIrEffect]) : bool
  (match a
    [(IrEffectPure)
      (match b
        [(IrEffectPure) true]
        [_ false])]
    [(IrEffectMemoryRead)
      (match b
        [(IrEffectMemoryRead) true]
        [_ false])]
    [(IrEffectMemoryWrite)
      (match b
        [(IrEffectMemoryWrite) true]
        [_ false])]
    [(IrEffectControlFlow)
      (match b
        [(IrEffectControlFlow) true]
        [_ false])]
    [(IrEffectUnknown)
      (match b
        [(IrEffectUnknown) true]
        [_ false])]))

(define (compiler-ir-effect-has-side-effect? [effect : CompilerIrEffect]) : bool
  (match effect
    [(IrEffectPure) false]
    [(IrEffectMemoryRead) false]
    [(IrEffectMemoryWrite) true]
    [(IrEffectControlFlow) true]
    [(IrEffectUnknown) true]))

(define (compiler-ir-effect-invalidates-cse? [effect : CompilerIrEffect]) : bool
  (match effect
    [(IrEffectPure) false]
    [_ true]))

(define (compiler-ir-runtime-memory-read? [name : String]) : bool
  (or
    (string-eq name "tl_string_eq")
    (or
      (string-eq name "tl_string_to_int")
      (or (string-eq name "tl_region_mark") (string-eq name ".L_tl_stdin_eof")))))

(define (compiler-ir-runtime-memory-write? [name : String]) : bool
  (or
    (string-eq name "tl_alloc")
    (or
      (string-eq name "tl_int_to_string")
      (or
        (string-eq name "tl_substring")
        (or
          (string-eq name "tl_string_concat")
          (or
            (string-eq name "tl_region_reset")
            (string-eq name ".L_tl_flush_stdout")))))))

(define (compiler-ir-runtime-control-flow? [name : String]) : bool
  (or
    (string-eq name ".L_tl_abort")
    (or
      (string-eq name "tl_oob_abort")
      (or (string-eq name "tl_div_abort") (string-eq name "tl_shift_abort")))))

(define (compiler-ir-direct-call-effect [name : String]) : CompilerIrEffect
  (if (compiler-ir-runtime-memory-read? name)
    IrEffectMemoryRead
    (if (compiler-ir-runtime-memory-write? name)
      IrEffectMemoryWrite
      (if (compiler-ir-runtime-control-flow? name)
        IrEffectControlFlow
        IrEffectUnknown))))

(define (compiler-ir-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (compiler-ir-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string-append a (string-append b (string-append c d))))

(define (compiler-ir-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string-append a (string-append b (string-append c (string-append d e)))))

(define (compiler-ir-display-var-render [id : i64]) : String
  (string-append "%" (int->string id)))

(define (compiler-ir-display-type-list-render-prefixed [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) ""]
    [(AstTypeCons head rest)
      (compiler-ir-cat3
        " "
        (compiler-ir-display-type-render head)
        (compiler-ir-display-type-list-render-prefixed rest))]))

(define (compiler-ir-display-type-render [ty : AstType]) : String
  (match ty
    [(AstTyI64) "i64"]
    [(AstTyI32) "i32"]
    [(AstTyI16) "i16"]
    [(AstTyI8) "i8"]
    [(AstTyU64) "u64"]
    [(AstTyU32) "u32"]
    [(AstTyU16) "u16"]
    [(AstTyU8) "u8"]
    [(AstTyF64) "f64"]
    [(AstTyF32) "f32"]
    [(AstTyBool) "bool"]
    [(AstTyChar) "char"]
    [(AstTyString) "String"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyFunc args ret)
      (compiler-ir-cat4
        "(->"
        (compiler-ir-display-type-list-render-prefixed args)
        " "
        (compiler-ir-cat3 (compiler-ir-display-type-render ret) ")" ""))]
    [(AstTyTuple elems)
      (compiler-ir-cat3
        "(Tuple"
        (compiler-ir-display-type-list-render-prefixed elems)
        ")")]
    [(AstTyArray elem len)
      (compiler-ir-cat5
        "(Array "
        (compiler-ir-display-type-render elem)
        " "
        (int->string len)
        ")")]
    [(AstTyDynArray elem)
      (compiler-ir-cat3 "(Array " (compiler-ir-display-type-render elem) ")")]
    [(AstTyRegion region inner)
      (compiler-ir-cat5
        "(in "
        region
        " "
        (compiler-ir-display-type-render inner)
        ")")]
    [(AstTyRef region inner)
      (compiler-ir-cat5
        "(& "
        region
        " "
        (compiler-ir-display-type-render inner)
        ")")]
    [(AstTyMutRef region inner)
      (compiler-ir-cat5
        "(&mut "
        region
        " "
        (compiler-ir-display-type-render inner)
        ")")]
    [(AstTyEnum name) name]
    [(AstTyStruct name) name]
    [(AstTyVar name) (compiler-ir-cat3 "'" name "'")]
    [(AstTyPtr inner)
      (compiler-ir-cat3 "(Ptr " (compiler-ir-display-type-render inner) ")")]
    [(AstTyMutPtr inner)
      (compiler-ir-cat3 "(MutPtr " (compiler-ir-display-type-render inner) ")")]))

(define (compiler-ir-display-vector-type-render [elem : AstType] [lanes : i64]) : String
  (compiler-ir-cat5
    "(Vector "
    (compiler-ir-display-type-render elem)
    " "
    (int->string lanes)
    ")"))

(define (compiler-ir-display-mask-type-render [lanes : i64]) : String
  (compiler-ir-cat3 "(Mask " (int->string lanes) ")"))

(define (compiler-ir-display-lanes-type-render [lanes : i64] [ty : AstType]) : String
  (compiler-ir-cat3
    (int->string lanes)
    " x "
    (compiler-ir-display-type-render ty)))

(define (compiler-ir-display-binop-render [op : CompilerIrBinOp]) : String
  (match op
    [(IrBinAdd) "add"]
    [(IrBinSub) "sub"]
    [(IrBinMul) "mul"]
    [(IrBinDiv) "div"]
    [(IrBinMod) "mod"]
    [(IrBinEq) "eq"]
    [(IrBinNe) "ne"]
    [(IrBinLt) "lt"]
    [(IrBinLe) "le"]
    [(IrBinGt) "gt"]
    [(IrBinGe) "ge"]
    [(IrBinAnd) "and"]
    [(IrBinOr) "or"]
    [(IrBinBitAnd) "bitand"]
    [(IrBinBitOr) "bitor"]
    [(IrBinBitXor) "bitxor"]
    [(IrBinShl) "shl"]
    [(IrBinShr) "shr"]))

(define (compiler-ir-display-mask-binop-render [op : CompilerIrMaskBinOp]) : String
  (match op
    [(IrMaskAnd) "mask_and"]
    [(IrMaskOr) "mask_or"]))

(define (compiler-ir-display-vector-reduce-op-render
  [op : CompilerIrVectorReduceOp]) : String
  (match op
    [(IrVectorReduceSum) "sum"]
    [(IrVectorReduceMin) "min"]
    [(IrVectorReduceMax) "max"]))

(define (compiler-ir-display-mask-reduce-op-render
  [op : CompilerIrMaskReduceOp]) : String
  (match op
    [(IrMaskReduceAll) "all"]
    [(IrMaskReduceAny) "any"]))

(define (compiler-ir-display-value-render [value : CompilerIrValue]) : String
  (match value
    [(IrValueVar id) (compiler-ir-display-var-render id)]
    [(IrValueGlobal name) (string-append "@" name)]
    [(IrValueI64 value) (int->string value)]
    [(IrValueF64 value) value]
    [(IrValueBool value)
      (if value
        "true"
        "false")]
    [(IrValueChar _) "<char>"]
    [(IrValueString value) (compiler-ir-cat3 "\"" value "\"")]
    [(IrValueUnit) "unit"]))

(define (compiler-ir-display-instr-render [instr : CompilerIrInstr]) : String
  (match instr
    [(IrInstrLaneId dst lanes ty)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = lane_id "
        (int->string lanes)
        (compiler-ir-cat3 " x " (compiler-ir-display-type-render ty) ""))]
    [(IrInstrSplat dst value lanes ty)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = splat "
        (compiler-ir-display-value-render value)
        (compiler-ir-cat3
          " : "
          (compiler-ir-display-lanes-type-render lanes ty)
          ""))]
    [(IrInstrVectorBinOp dst op lhs rhs lanes elem-ty)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = vector_"
        (compiler-ir-display-binop-render op)
        (compiler-ir-cat5
          " "
          (compiler-ir-display-value-render lhs)
          ", "
          (compiler-ir-display-value-render rhs)
          (compiler-ir-cat3
            " : "
            (compiler-ir-display-lanes-type-render lanes elem-ty)
            "")))]
    [(IrInstrVectorReduce dst op src lanes elem-ty)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = vector_reduce_"
        (compiler-ir-display-vector-reduce-op-render op)
        (compiler-ir-cat3
          " "
          (compiler-ir-display-value-render src)
          (compiler-ir-cat3
            " : "
            (compiler-ir-display-lanes-type-render lanes elem-ty)
            "")))]
    [(IrInstrVectorCompare dst op lhs rhs lanes elem-ty)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = vector_cmp_"
        (compiler-ir-display-binop-render op)
        (compiler-ir-cat5
          " "
          (compiler-ir-display-value-render lhs)
          ", "
          (compiler-ir-display-value-render rhs)
          (compiler-ir-cat3
            " : "
            (compiler-ir-display-lanes-type-render lanes elem-ty)
            "")))]
    [(IrInstrMaskBinOp dst op lhs rhs lanes)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = "
        (compiler-ir-display-mask-binop-render op)
        (compiler-ir-cat5
          " "
          (compiler-ir-display-value-render lhs)
          ", "
          (compiler-ir-display-value-render rhs)
          (compiler-ir-cat3 " : " (int->string lanes) "")))]
    [(IrInstrMaskNot dst src lanes)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = mask_not "
        (compiler-ir-display-value-render src)
        (compiler-ir-cat3 " : " (int->string lanes) ""))]
    [(IrInstrMaskReduce dst op src lanes)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = mask_reduce_"
        (compiler-ir-display-mask-reduce-op-render op)
        (compiler-ir-cat3
          " "
          (compiler-ir-display-value-render src)
          (compiler-ir-cat3 " : " (int->string lanes) "")))]
    [(IrInstrSelect dst mask on-true on-false lanes ty)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = select "
        (compiler-ir-display-value-render mask)
        (compiler-ir-cat5
          ", "
          (compiler-ir-display-value-render on-true)
          ", "
          (compiler-ir-display-value-render on-false)
          (compiler-ir-cat3
            " : "
            (compiler-ir-display-lanes-type-render lanes ty)
            "")))]
    [(IrInstrVectorLoad dst base index lanes elem-ty)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = vector_load "
        (compiler-ir-display-value-render base)
        (compiler-ir-cat5
          ", "
          (compiler-ir-display-value-render index)
          " : "
          (compiler-ir-display-lanes-type-render lanes elem-ty)
          ""))]
    [(IrInstrVectorStore base index value lanes elem-ty)
      (compiler-ir-cat5
        "  vector_store "
        (compiler-ir-display-value-render base)
        ", "
        (compiler-ir-display-value-render index)
        (compiler-ir-cat5
          ", "
          (compiler-ir-display-value-render value)
          " : "
          (compiler-ir-display-lanes-type-render lanes elem-ty)
          ""))]
    [(IrInstrPredicatedStore base index value mask lanes elem-ty)
      (compiler-ir-cat5
        "  predicated_store "
        (compiler-ir-display-value-render base)
        ", "
        (compiler-ir-display-value-render index)
        (compiler-ir-cat4
          ", "
          (compiler-ir-display-value-render value)
          ", "
          (compiler-ir-cat5
            (compiler-ir-display-value-render mask)
            " : "
            (compiler-ir-display-lanes-type-render lanes elem-ty)
            ""
            "")))]
    [(IrInstrPredicatedLoad dst base index mask lanes elem-ty)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = predicated_load "
        (compiler-ir-display-value-render base)
        (compiler-ir-cat5
          ", "
          (compiler-ir-display-value-render index)
          ", "
          (compiler-ir-display-value-render mask)
          (compiler-ir-cat3
            " : "
            (compiler-ir-display-lanes-type-render lanes elem-ty)
            "")))]
    [(IrInstrTailMask dst index len lanes)
      (compiler-ir-cat5
        "  "
        (compiler-ir-display-var-render dst)
        " = tail_mask "
        (compiler-ir-display-value-render index)
        (compiler-ir-cat5
          ", "
          (compiler-ir-display-value-render len)
          " : "
          (int->string lanes)
          ""))]
    [_ "  <ir-instr>"]))

(define (compiler-ir-instr-effect [instr : CompilerIrInstr]) : CompilerIrEffect
  (match instr
    [(IrInstrMov _ _ _) IrEffectPure]
    [(IrInstrAddrOf _ _) IrEffectPure]
    [(IrInstrGep _ _ _ _) IrEffectPure]
    [(IrInstrCast _ _ _ _) IrEffectPure]
    [(IrInstrBinOp _ _ _ _ _) IrEffectPure]
    [(IrInstrUnOp _ _ _ _) IrEffectPure]
    [(IrInstrPhi _ _ _) IrEffectPure]
    [(IrInstrLaneId _ _ _) IrEffectPure]
    [(IrInstrSplat _ _ _ _) IrEffectPure]
    [(IrInstrVectorBinOp _ _ _ _ _ _) IrEffectPure]
    [(IrInstrVectorReduce _ _ _ _ _) IrEffectPure]
    [(IrInstrVectorCompare _ _ _ _ _ _) IrEffectPure]
    [(IrInstrMaskBinOp _ _ _ _ _) IrEffectPure]
    [(IrInstrMaskNot _ _ _) IrEffectPure]
    [(IrInstrMaskReduce _ _ _ _) IrEffectPure]
    [(IrInstrSelect _ _ _ _ _ _) IrEffectPure]
    [(IrInstrTailMask _ _ _ _) IrEffectPure]
    [(IrInstrLoad _ _ _) IrEffectMemoryRead]
    [(IrInstrVectorLoad _ _ _ _ _) IrEffectMemoryRead]
    [(IrInstrPredicatedLoad _ _ _ _ _ _) IrEffectMemoryRead]
    [(IrInstrAlloc _ _) IrEffectMemoryWrite]
    [(IrInstrStorePtr _ _ _) IrEffectMemoryWrite]
    [(IrInstrStore _ _ _) IrEffectMemoryWrite]
    [(IrInstrVectorStore _ _ _ _ _) IrEffectMemoryWrite]
    [(IrInstrPredicatedStore _ _ _ _ _ _) IrEffectMemoryWrite]
    [(IrInstrCall _ name _ _) (compiler-ir-direct-call-effect name)]
    [(IrInstrBoundsCheck _ _ _) IrEffectControlFlow]
    [(IrInstrJump _) IrEffectControlFlow]
    [(IrInstrBranch _ _ _) IrEffectControlFlow]
    [(IrInstrReturn _) IrEffectControlFlow]))

;; Source provenance side table for the lowered IR (#605). Kept OUTSIDE
;;
;; `CompilerIrProgram` so the optimizer and liveness data model stay unchanged,
;;
;; mirroring the Rust pipeline's `SourceSpans`. It maps an IR function's name
;;
;; (including generated global-init functions) to the `AstSourceSpan` of the
;;
;; source construct that produced it, so backend diagnostics can report a real
;;
;; line/column instead of falling back to `path:1:1`.
;;
;; The table is a deterministic association list keyed by function name; the
;;
;; first binding for a name wins on lookup (entries are appended in lowering
;;
;; order).
(defenum CompilerSourceSpansEntry
  (CompilerSourceSpansEntry String AstSourceSpan))

(defenum CompilerSourceSpansEntryList
  (CompilerSourceSpansEntryNil)
  (CompilerSourceSpansEntryCons
    CompilerSourceSpansEntry
    CompilerSourceSpansEntryList))

(defenum CompilerSourceSpans
  (CompilerSourceSpans
    CompilerSourceSpansEntryList
    CompilerSourceSpansEntryList))

(defenum CompilerMaybeSourceSpan
  (CompilerNoSourceSpan)
  (CompilerSomeSourceSpan AstSourceSpan))

(define (compiler-source-spans-empty) : CompilerSourceSpans
  (CompilerSourceSpans
    (CompilerSourceSpansEntryNil)
    (CompilerSourceSpansEntryNil)))

(define (compiler-source-spans-clear-instrs [spans : CompilerSourceSpans]) : CompilerSourceSpans
  (match spans
    [(CompilerSourceSpans entries _)
      (CompilerSourceSpans entries (CompilerSourceSpansEntryNil))]))

(define (compiler-source-spans-entry-list-append
  [entries : CompilerSourceSpansEntryList]
  [entry : CompilerSourceSpansEntry]) : CompilerSourceSpansEntryList
  (match entries
    [(CompilerSourceSpansEntryNil)
      (CompilerSourceSpansEntryCons entry (CompilerSourceSpansEntryNil))]
    [(CompilerSourceSpansEntryCons head rest)
      (CompilerSourceSpansEntryCons
        head
        (compiler-source-spans-entry-list-append rest entry))]))

;; Record `name -> span`. Lowering appends in order; the first binding for a
;;
;; name wins on lookup, so re-recording a name is a no-op for diagnostics.
(define (compiler-source-spans-insert
  [spans : CompilerSourceSpans]
  [name : String]
  [span : AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(CompilerSourceSpans entries instr-entries)
      (CompilerSourceSpans
        (compiler-source-spans-entry-list-append
          entries
          (CompilerSourceSpansEntry name span))
        instr-entries)]))

(define (compiler-source-spans-entry-list-lookup
  [entries : CompilerSourceSpansEntryList]
  [name : String]) : CompilerMaybeSourceSpan
  (match entries
    [(CompilerSourceSpansEntryNil) (CompilerNoSourceSpan)]
    [(CompilerSourceSpansEntryCons entry rest)
      (match entry
        [(CompilerSourceSpansEntry entry-name span)
          (if (string-eq entry-name name)
            (CompilerSomeSourceSpan span)
            (compiler-source-spans-entry-list-lookup rest name))])]))

(define (compiler-source-spans-lookup
  [spans : CompilerSourceSpans]
  [name : String]) : CompilerMaybeSourceSpan
  (match spans
    [(CompilerSourceSpans entries _)
      (compiler-source-spans-entry-list-lookup entries name)]))

(define (compiler-source-spans-value-key [function : String] [var-id : i64]) : String
  (string-append
    (string-append "value:" function)
    (string-append ":" (int->string var-id))))

(define (compiler-source-spans-store-key [function : String] [name : String]) : String
  (string-append (string-append "store:" function) (string-append ":" name)))

(define (compiler-source-spans-insert-instr-entry
  [spans : CompilerSourceSpans]
  [key : String]
  [span : AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(CompilerSourceSpans entries instr-entries)
      (CompilerSourceSpans
        entries
        (compiler-source-spans-entry-list-append
          instr-entries
          (CompilerSourceSpansEntry key span)))]))

(define (compiler-source-spans-insert-instr
  [spans : CompilerSourceSpans]
  [function : String]
  [instr : CompilerIrInstr]
  [span : AstSourceSpan]) : CompilerSourceSpans
  (match instr
    [(IrInstrMov dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrAlloc dst _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrAddrOf dst _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrGep dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrLoad dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrCast dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrBinOp dst _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrUnOp dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrLaneId dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrSplat dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrVectorBinOp dst _ _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrVectorReduce dst _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrVectorCompare dst _ _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrMaskBinOp dst _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrMaskNot dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrMaskReduce dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrSelect dst _ _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrVectorLoad dst _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrTailMask dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrCall dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrStore name _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-store-key function name)
        span)]
    [(IrInstrPhi dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [_ spans]))

(define (compiler-source-spans-lookup-instr
  [spans : CompilerSourceSpans]
  [function : String]
  [instr : CompilerIrInstr]) : CompilerMaybeSourceSpan
  (match spans
    [(CompilerSourceSpans _ instr-entries)
      (match instr
        [(IrInstrMov dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrAlloc dst _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrAddrOf dst _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrGep dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrLoad dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrCast dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrBinOp dst _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrUnOp dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrLaneId dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrSplat dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrVectorBinOp dst _ _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrVectorReduce dst _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrVectorCompare dst _ _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrMaskBinOp dst _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrMaskNot dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrMaskReduce dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrSelect dst _ _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrVectorLoad dst _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrPredicatedLoad dst _ _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrTailMask dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrCall dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrStore name _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-store-key function name))]
        [(IrInstrPhi dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [_ (CompilerNoSourceSpan)])]))

;; Number of recorded entries; supports provenance smoke assertions (#605).
(define (compiler-source-spans-entry-list-count
  [entries : CompilerSourceSpansEntryList]) : i64
  (match entries
    [(CompilerSourceSpansEntryNil) 0]
    [(CompilerSourceSpansEntryCons _ rest)
      (+ 1 (compiler-source-spans-entry-list-count rest))]))

(define (compiler-source-spans-count [spans : CompilerSourceSpans]) : i64
  (match spans
    [(CompilerSourceSpans entries _)
      (compiler-source-spans-entry-list-count entries)]))

(define (compiler-source-spans-instr-count [spans : CompilerSourceSpans]) : i64
  (match spans
    [(CompilerSourceSpans _ instr-entries)
      (compiler-source-spans-entry-list-count instr-entries)]))

(defenum CompilerIrSummary
  (CompilerIrSummary i64 i64 i64 i64 i64 i64))

(define (compiler-ir-summary-globals [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary globals _ _ _ _ _) globals]))

(define (compiler-ir-summary-functions [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ functions _ _ _ _) functions]))

(define (compiler-ir-summary-externs [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ externs _ _ _) externs]))

(define (compiler-ir-summary-blocks [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ blocks _ _) blocks]))

(define (compiler-ir-summary-instructions [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ _ instructions _) instructions]))

(define (compiler-ir-summary-vars [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ _ _ vars) vars]))

(define (compiler-ir-summary-score [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary globals functions externs blocks instructions vars)
      (+
        globals
        (+
          (* functions 10)
          (+
            (* externs 100)
            (+ (* blocks 1000) (+ (* instructions 10000) (* vars 100000))))))]))

(define (compiler-ir-global-list-count [globals : CompilerIrGlobalList]) : i64
  (match globals
    [(IrGlobalNil) 0]
    [(IrGlobalCons _ rest) (+ 1 (compiler-ir-global-list-count rest))]))

(define (compiler-ir-extern-list-count [externs : CompilerIrExternList]) : i64
  (match externs
    [(IrExternNil) 0]
    [(IrExternCons _ rest) (+ 1 (compiler-ir-extern-list-count rest))]))

(define (compiler-ir-instr-list-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons _ rest) (+ 1 (compiler-ir-instr-list-count rest))]))

(define (compiler-ir-block-list-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons _ rest) (+ 1 (compiler-ir-block-list-count rest))]))

(define (compiler-ir-block-list-instruction-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (compiler-ir-instr-list-count instrs)
            (compiler-ir-block-list-instruction-count rest))])]))

(define (compiler-ir-function-list-count [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons _ rest) (+ 1 (compiler-ir-function-list-count rest))]))

(define (compiler-ir-function-list-block-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (compiler-ir-block-list-count blocks)
            (compiler-ir-function-list-block-count rest))])]))

(define (compiler-ir-function-list-instruction-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (compiler-ir-block-list-instruction-count blocks)
            (compiler-ir-function-list-instruction-count rest))])]))

(define (compiler-ir-function-list-var-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ vars _)
          (+ vars (compiler-ir-function-list-var-count rest))])]))

(define (compiler-ir-program-summary [program : CompilerIrProgram]) : CompilerIrSummary
  (match program
    [(IrProgram globals functions externs)
      (CompilerIrSummary
        (compiler-ir-global-list-count globals)
        (compiler-ir-function-list-count functions)
        (compiler-ir-extern-list-count externs)
        (compiler-ir-function-list-block-count functions)
        (compiler-ir-function-list-instruction-count functions)
        (compiler-ir-function-list-var-count functions))]))

(define (compiler-ir-effect-is?
  [instr : CompilerIrInstr]
  [effect : CompilerIrEffect]) : bool
  (compiler-ir-effect-eq? (compiler-ir-instr-effect instr) effect))

(define (compiler-ir-instruction-effects-ok?) : bool
  (and
    (compiler-ir-effect-is?
      (IrInstrMov 0 (IrValueI64 1) (AstTyI64))
      IrEffectPure)
    (and
      (compiler-ir-effect-is? (IrInstrAddrOf 1 0) IrEffectPure)
      (and
        (compiler-ir-effect-is?
          (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyI64))
          IrEffectPure)
        (and
          (compiler-ir-effect-is?
            (IrInstrCast 3 (IrValueVar 2) (AstTyI64) (AstTyI32))
            IrEffectPure)
          (and
            (compiler-ir-effect-is?
              (IrInstrBinOp
                4
                (IrBinAdd)
                (IrValueVar 2)
                (IrValueI64 1)
                (AstTyI64))
              IrEffectPure)
            (and
              (compiler-ir-effect-is?
                (IrInstrUnOp 5 (IrUnNeg) (IrValueVar 4) (AstTyI64))
                IrEffectPure)
              (and
                (compiler-ir-effect-is?
                  (IrInstrPhi
                    6
                    (IrPhiInputCons
                      (IrPhiInput (IrValueI64 1) "entry")
                      (IrPhiInputNil))
                    (AstTyI64))
                  IrEffectPure)
                (and
                  (compiler-ir-effect-is?
                    (IrInstrLoad 7 (IrValueVar 1) (AstTyI64))
                    IrEffectMemoryRead)
                  (and
                    (compiler-ir-effect-is?
                      (IrInstrAlloc 8 (AstTyI64))
                      IrEffectMemoryWrite)
                    (and
                      (compiler-ir-effect-is?
                        (IrInstrStorePtr
                          (IrValueVar 1)
                          (IrValueI64 2)
                          (AstTyI64))
                        IrEffectMemoryWrite)
                      (and
                        (compiler-ir-effect-is?
                          (IrInstrStore "global" (IrValueI64 3) (AstTyI64))
                          IrEffectMemoryWrite)
                        (and
                          (compiler-ir-effect-is?
                            (IrInstrCall
                              9
                              "tl_string_eq"
                              IrValueNil
                              (AstTyBool))
                            IrEffectMemoryRead)
                          (and
                            (compiler-ir-effect-is?
                              (IrInstrBoundsCheck
                                (IrValueVar 0)
                                (IrValueVar 1)
                                "bounds_ok")
                              IrEffectControlFlow)
                            (and
                              (compiler-ir-effect-is?
                                (IrInstrJump "done")
                                IrEffectControlFlow)
                              (and
                                (compiler-ir-effect-is?
                                  (IrInstrBranch
                                    (IrValueBool true)
                                    "then"
                                    "else")
                                  IrEffectControlFlow)
                                (compiler-ir-effect-is?
                                  (IrInstrReturn (IrSomeValue (IrValueI64 0)))
                                  IrEffectControlFlow)))))))))))))))))

(define (compiler-ir-vector-mask-effects-ok?) : bool
  (and
    (compiler-ir-effect-is? (IrInstrLaneId 20 4 (AstTyI64)) IrEffectPure)
    (and
      (compiler-ir-effect-is?
        (IrInstrSplat 21 (IrValueVar 0) 4 (AstTyI64))
        IrEffectPure)
      (and
        (compiler-ir-effect-is?
          (IrInstrVectorBinOp
            22
            (IrBinAdd)
            (IrValueVar 20)
            (IrValueVar 21)
            4
            (AstTyI64))
          IrEffectPure)
        (and
          (compiler-ir-effect-is?
            (IrInstrVectorReduce
              23
              (IrVectorReduceSum)
              (IrValueVar 22)
              4
              (AstTyI64))
            IrEffectPure)
          (and
            (compiler-ir-effect-is?
              (IrInstrVectorCompare
                24
                (IrBinLt)
                (IrValueVar 20)
                (IrValueVar 21)
                4
                (AstTyI64))
              IrEffectPure)
            (and
              (compiler-ir-effect-is?
                (IrInstrMaskBinOp
                  25
                  (IrMaskAnd)
                  (IrValueVar 24)
                  (IrValueVar 24)
                  4)
                IrEffectPure)
              (and
                (compiler-ir-effect-is?
                  (IrInstrMaskNot 26 (IrValueVar 25) 4)
                  IrEffectPure)
                (and
                  (compiler-ir-effect-is?
                    (IrInstrMaskReduce 27 (IrMaskReduceAny) (IrValueVar 26) 4)
                    IrEffectPure)
                  (and
                    (compiler-ir-effect-is?
                      (IrInstrSelect
                        28
                        (IrValueVar 24)
                        (IrValueVar 20)
                        (IrValueVar 21)
                        4
                        (AstTyI64))
                      IrEffectPure)
                    (and
                      (compiler-ir-effect-is?
                        (IrInstrTailMask 29 (IrValueVar 0) (IrValueVar 1) 4)
                        IrEffectPure)
                      (and
                        (compiler-ir-effect-is?
                          (IrInstrVectorLoad
                            30
                            (IrValueVar 2)
                            (IrValueVar 0)
                            4
                            (AstTyI64))
                          IrEffectMemoryRead)
                        (and
                          (compiler-ir-effect-is?
                            (IrInstrPredicatedLoad
                              31
                              (IrValueVar 2)
                              (IrValueVar 0)
                              (IrValueVar 29)
                              4
                              (AstTyI64))
                            IrEffectMemoryRead)
                          (and
                            (compiler-ir-effect-is?
                              (IrInstrVectorStore
                                (IrValueVar 2)
                                (IrValueVar 0)
                                (IrValueVar 22)
                                4
                                (AstTyI64))
                              IrEffectMemoryWrite)
                            (compiler-ir-effect-is?
                              (IrInstrPredicatedStore
                                (IrValueVar 2)
                                (IrValueVar 0)
                                (IrValueVar 22)
                                (IrValueVar 29)
                                4
                                (AstTyI64))
                              IrEffectMemoryWrite)))))))))))))))

(define (compiler-ir-display-instr-render-is?
  [instr : CompilerIrInstr]
  [expected : String]) : bool
  (string-eq (compiler-ir-display-instr-render instr) expected))

(define (compiler-ir-vector-mask-type-render-ok?) : bool
  (and
    (string-eq
      (compiler-ir-display-vector-type-render (AstTyI32) 8)
      "(Vector i32 8)")
    (string-eq (compiler-ir-display-mask-type-render 8) "(Mask 8)")))

(define (compiler-ir-vector-mask-reduce-render-ok?) : bool
  (and
    (string-eq
      (compiler-ir-display-vector-reduce-op-render (IrVectorReduceSum))
      "sum")
    (and
      (string-eq
        (compiler-ir-display-vector-reduce-op-render (IrVectorReduceMin))
        "min")
      (and
        (string-eq
          (compiler-ir-display-vector-reduce-op-render (IrVectorReduceMax))
          "max")
        (and
          (string-eq
            (compiler-ir-display-mask-reduce-op-render (IrMaskReduceAll))
            "all")
          (string-eq
            (compiler-ir-display-mask-reduce-op-render (IrMaskReduceAny))
            "any"))))))

(define (compiler-ir-vector-mask-instr-render-ok?) : bool
  (and
    (compiler-ir-display-instr-render-is?
      (IrInstrLaneId 0 4 (AstTyI64))
      "  %0 = lane_id 4 x i64")
    (and
      (compiler-ir-display-instr-render-is?
        (IrInstrSplat 1 (IrValueI64 7) 4 (AstTyI64))
        "  %1 = splat 7 : 4 x i64")
      (and
        (compiler-ir-display-instr-render-is?
          (IrInstrVectorBinOp
            2
            (IrBinAdd)
            (IrValueVar 0)
            (IrValueVar 1)
            4
            (AstTyI64))
          "  %2 = vector_add %0, %1 : 4 x i64")
        (and
          (compiler-ir-display-instr-render-is?
            (IrInstrVectorReduce
              8
              (IrVectorReduceSum)
              (IrValueVar 2)
              4
              (AstTyI64))
            "  %8 = vector_reduce_sum %2 : 4 x i64")
          (and
            (compiler-ir-display-instr-render-is?
              (IrInstrVectorCompare
                3
                (IrBinLt)
                (IrValueVar 0)
                (IrValueVar 1)
                4
                (AstTyI64))
              "  %3 = vector_cmp_lt %0, %1 : 4 x i64")
            (and
              (compiler-ir-display-instr-render-is?
                (IrInstrMaskBinOp 4 (IrMaskOr) (IrValueVar 3) (IrValueVar 3) 4)
                "  %4 = mask_or %3, %3 : 4")
              (and
                (compiler-ir-display-instr-render-is?
                  (IrInstrMaskNot 5 (IrValueVar 4) 4)
                  "  %5 = mask_not %4 : 4")
                (and
                  (compiler-ir-display-instr-render-is?
                    (IrInstrMaskReduce 9 (IrMaskReduceAny) (IrValueVar 5) 4)
                    "  %9 = mask_reduce_any %5 : 4")
                  (and
                    (compiler-ir-display-instr-render-is?
                      (IrInstrSelect
                        6
                        (IrValueVar 5)
                        (IrValueVar 2)
                        (IrValueVar 1)
                        4
                        (AstTyI64))
                      "  %6 = select %5, %2, %1 : 4 x i64")
                    (and
                      (compiler-ir-display-instr-render-is?
                        (IrInstrVectorLoad
                          7
                          (IrValueVar 10)
                          (IrValueVar 11)
                          4
                          (AstTyI64))
                        "  %7 = vector_load %10, %11 : 4 x i64")
                      (and
                        (compiler-ir-display-instr-render-is?
                          (IrInstrVectorStore
                            (IrValueVar 12)
                            (IrValueVar 11)
                            (IrValueVar 6)
                            4
                            (AstTyI64))
                          "  vector_store %12, %11, %6 : 4 x i64")
                        (and
                          (compiler-ir-display-instr-render-is?
                            (IrInstrPredicatedStore
                              (IrValueVar 12)
                              (IrValueVar 11)
                              (IrValueVar 6)
                              (IrValueVar 5)
                              4
                              (AstTyI64))
                            "  predicated_store %12, %11, %6, %5 : 4 x i64")
                          (compiler-ir-display-instr-render-is?
                            (IrInstrPredicatedLoad
                              10
                              (IrValueVar 12)
                              (IrValueVar 11)
                              (IrValueVar 5)
                              4
                              (AstTyI64))
                            "  %10 = predicated_load %12, %11, %5 : 4 x i64"))))))))))))))

(define (compiler-ir-tail-mask-render-ok?) : bool
  (and
    (compiler-ir-display-instr-render-is?
      (IrInstrTailMask 9 (IrValueVar 1) (IrValueVar 2) 8)
      "  %9 = tail_mask %1, %2 : 8")
    (compiler-ir-effect-is?
      (IrInstrTailMask 9 (IrValueVar 1) (IrValueVar 2) 8)
      IrEffectPure)))

(define (compiler-ir-vector-mask-display-ok?) : bool
  (and
    (compiler-ir-vector-mask-type-render-ok?)
    (and
      (compiler-ir-vector-mask-reduce-render-ok?)
      (and
        (compiler-ir-vector-mask-instr-render-ok?)
        (compiler-ir-tail-mask-render-ok?)))))

(define (compiler-ir-runtime-effects-ok?) : bool
  (and
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect "tl_region_mark")
      IrEffectMemoryRead)
    (and
      (compiler-ir-effect-eq?
        (compiler-ir-direct-call-effect ".L_tl_stdin_eof")
        IrEffectMemoryRead)
      (and
        (compiler-ir-effect-eq?
          (compiler-ir-direct-call-effect "tl_alloc")
          IrEffectMemoryWrite)
        (and
          (compiler-ir-effect-eq?
            (compiler-ir-direct-call-effect ".L_tl_flush_stdout")
            IrEffectMemoryWrite)
          (and
            (compiler-ir-effect-eq?
              (compiler-ir-direct-call-effect ".L_tl_abort")
              IrEffectControlFlow)
            (and
              (compiler-ir-effect-eq?
                (compiler-ir-direct-call-effect "tl_shift_abort")
                IrEffectControlFlow)
              (and
                (compiler-ir-effect-eq?
                  (compiler-ir-direct-call-effect ".L_tl_arg_count")
                  IrEffectUnknown)
                (compiler-ir-effect-eq?
                  (compiler-ir-direct-call-effect "user_or_extern_call")
                  IrEffectUnknown)))))))))

(define (compiler-ir-effect-predicates-ok?) : bool
  (and
    (not (compiler-ir-effect-has-side-effect? IrEffectPure))
    (and
      (not (compiler-ir-effect-has-side-effect? IrEffectMemoryRead))
      (and
        (compiler-ir-effect-has-side-effect? IrEffectMemoryWrite)
        (and
          (compiler-ir-effect-has-side-effect? IrEffectControlFlow)
          (and
            (compiler-ir-effect-has-side-effect? IrEffectUnknown)
            (and
              (not (compiler-ir-effect-invalidates-cse? IrEffectPure))
              (and
                (compiler-ir-effect-invalidates-cse? IrEffectMemoryRead)
                (and
                  (compiler-ir-effect-invalidates-cse? IrEffectMemoryWrite)
                  (and
                    (compiler-ir-effect-invalidates-cse? IrEffectControlFlow)
                    (compiler-ir-effect-invalidates-cse? IrEffectUnknown)))))))))))

(define (compiler-ir-effect-self-test) : i64
  (if (compiler-ir-instruction-effects-ok?)
    (if (compiler-ir-vector-mask-effects-ok?)
      (if (compiler-ir-runtime-effects-ok?)
        (if (compiler-ir-effect-predicates-ok?)
          (if (compiler-ir-vector-mask-display-ok?)
            42
            1)
          1)
        1)
      1)
    1))