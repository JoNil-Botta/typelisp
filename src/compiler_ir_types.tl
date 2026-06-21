;; compiler_ir_types.tl - Self-hosted compiler IR model (#446).
;;
;; This is the first selfhost IR shape for the real compiler pipeline. The data
;; model is intentionally close to the Rust IR: functions contain blocks, blocks
;; contain typed instructions, and instructions use explicit vars/values.
(import "../stdlib/string.tl")
(import "compiler_ast_types.tl")
(import "../stdlib/str_cat.tl")

(defenum CompilerIrBinOp
  (IrBinAdd)
  (IrBinSub)
  (IrBinMul)
  (IrBinDiv)
  (IrBinMod)
  (IrBinSafeDiv)
  (IrBinSafeMod)
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
  (IrValueGlobalAddr String)
  (IrValueFunction String)
  (IrValueI64 i64)
  (IrValueF64 u64)
  (IrValueBool bool)
  (IrValueChar char)
  (IrValueString String)
  (IrValueBytes String)
  (IrValueUnit))

(defenum CompilerIrMaybeValue
  (IrNoValue)
  (IrSomeValue CompilerIrValue))

(defenum CompilerIrValueList
  (IrValueNil)
  (IrValueCons CompilerIrValue (Box CompilerIrValueList)))

(defenum CompilerIrCallArgs
  (IrCallArgsNil)
  (IrCallArgsOne CompilerIrValue)
  (IrCallArgsTwo CompilerIrValue CompilerIrValue)
  (IrCallArgsArray (Array CompilerIrValue)))

(defenum CompilerIrCAbiReturnSlot
  (IrCAbiReturnSlot AstType i64))

(defenum CompilerIrCAbiReturnSlotList
  (IrCAbiReturnSlotNil)
  (IrCAbiReturnSlotCons
    CompilerIrCAbiReturnSlot
    (Box CompilerIrCAbiReturnSlotList)))

(defenum CompilerIrPhiInputList
  (IrPhiInputNil)
  (IrPhiInputCons CompilerIrValue String (Box CompilerIrPhiInputList)))

(defenum CompilerIrSwitchCase
  (IrSwitchCase i64 String))

(defenum CompilerIrSwitchCaseList
  (IrSwitchCaseNil)
  (IrSwitchCaseCons CompilerIrSwitchCase (Box CompilerIrSwitchCaseList)))

(defenum CompilerIrInstrVectorBinOpPayload
  (CompilerIrInstrVectorBinOpPayload
    i64
    CompilerIrBinOp
    CompilerIrValue
    CompilerIrValue
    i64
    AstType))

(defenum CompilerIrInstrVectorComparePayload
  (CompilerIrInstrVectorComparePayload
    i64
    CompilerIrBinOp
    CompilerIrValue
    CompilerIrValue
    i64
    AstType))

(defenum CompilerIrInstrSelectPayload
  (CompilerIrInstrSelectPayload
    i64
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    i64
    AstType))

(defenum CompilerIrInstrVectorStorePayload
  (CompilerIrInstrVectorStorePayload
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    i64
    AstType))

(defenum CompilerIrInstrPredicatedStorePayload
  (CompilerIrInstrPredicatedStorePayload
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    i64
    AstType))

(defenum CompilerIrInstrPredicatedLoadPayload
  (CompilerIrInstrPredicatedLoadPayload
    i64
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    i64
    AstType))

(defenum CompilerIrInstrCallCAbiStoreResultPayload
  (CompilerIrInstrCallCAbiStoreResultPayload
    CompilerIrValue
    String
    CompilerIrCallArgs
    CompilerIrCAbiReturnSlotList))

(defenum CompilerIrInstrCallIndirectCAbiStoreResultPayload
  (CompilerIrInstrCallIndirectCAbiStoreResultPayload
    CompilerIrValue
    CompilerIrValue
    CompilerIrCallArgs
    CompilerIrCAbiReturnSlotList))

(defenum CompilerIrInstr
  (IrInstrMov i64 CompilerIrValue AstType)
  (IrInstrAlloc i64 AstType)
  (IrInstrAddrOf i64 i64)
  (IrInstrGep i64 CompilerIrValue CompilerIrValue AstType)
  (IrInstrLoad i64 CompilerIrValue AstType)
  (IrInstrStorePtr CompilerIrValue CompilerIrValue AstType)
  (IrInstrCopyBytes CompilerIrValue CompilerIrValue i64)
  (IrInstrBoundsCheck CompilerIrValue CompilerIrValue String)
  (IrInstrCast i64 CompilerIrValue AstType AstType)
  (IrInstrBitcast i64 CompilerIrValue AstType AstType)
  (IrInstrBinOp i64 CompilerIrBinOp CompilerIrValue CompilerIrValue AstType)
  (IrInstrUnOp i64 CompilerIrUnOp CompilerIrValue AstType)
  (IrInstrLaneId i64 i64 AstType)
  (IrInstrSplat i64 CompilerIrValue i64 AstType)
  (IrInstrVectorBinOp (Box CompilerIrInstrVectorBinOpPayload))
  (IrInstrVectorReduce i64 CompilerIrVectorReduceOp CompilerIrValue i64 AstType)
  (IrInstrVectorCompare (Box CompilerIrInstrVectorComparePayload))
  (IrInstrMaskBinOp i64 CompilerIrMaskBinOp CompilerIrValue CompilerIrValue i64)
  (IrInstrMaskNot i64 CompilerIrValue i64)
  (IrInstrMaskReduce i64 CompilerIrMaskReduceOp CompilerIrValue i64)
  (IrInstrSelect (Box CompilerIrInstrSelectPayload))
  (IrInstrVectorLoad i64 CompilerIrValue CompilerIrValue i64 AstType)
  (IrInstrVectorStore (Box CompilerIrInstrVectorStorePayload))
  (IrInstrPredicatedStore (Box CompilerIrInstrPredicatedStorePayload))
  (IrInstrPredicatedLoad (Box CompilerIrInstrPredicatedLoadPayload))
  (IrInstrTailMask i64 CompilerIrValue CompilerIrValue i64)
  (IrInstrEntryArgc i64)
  (IrInstrEntryArgv i64)
  (IrInstrEntryEnvp i64)
  (IrInstrCpuId i64 CompilerIrValue CompilerIrValue i64)
  (IrInstrXgetbv i64 CompilerIrValue)
  ;; Raw Linux x86_64 syscall: dst var plus the operands (number then up to six
  ;; arguments) carried as call-args. Lowers to a `syscall` instruction.
  (IrInstrSyscall i64 CompilerIrCallArgs)
  (IrInstrCall i64 String CompilerIrCallArgs AstType)
  (IrInstrCallIndirect i64 CompilerIrValue CompilerIrCallArgs AstType)
  (IrInstrCallIndirectC i64 CompilerIrValue CompilerIrCallArgs AstType)
  ;; System V C aggregate returns can arrive in two ABI result registers. These
  ;; instructions emit the call and immediately store those result slots into the
  ;; provided aggregate buffer, preserving the classifier's slot offsets.
  (IrInstrCallCAbiStoreResult (Box CompilerIrInstrCallCAbiStoreResultPayload))
  (IrInstrCallIndirectCAbiStoreResult
    (Box CompilerIrInstrCallIndirectCAbiStoreResultPayload))
  (IrInstrTailCall String CompilerIrCallArgs AstType)
  (IrInstrStore String CompilerIrValue AstType)
  (IrInstrJump String)
  (IrInstrBranch CompilerIrValue String String)
  (IrInstrReturn CompilerIrMaybeValue)
  (IrInstrPhi i64 CompilerIrPhiInputList AstType)
  ;; #2386 multi-word register-resident aggregates: a small (<=16 B) inline
  ;; struct/enum whose fields are all word-class can live in N general-purpose
  ;; registers (N = ceil(size/8)) instead of a memory slot. IrInstrPack forms
  ;; such a group var `dst` (typed `ty`, the aggregate type) from its N word
  ;; values (low word first, e.g. word0 = enum tag); IrInstrWord extracts word
  ;; `index` of a group value into a scalar `dst`. The register allocator gives a
  ;; group var N adjacent home registers (or an N*8-byte spill slot); the backend
  ;; lowers Pack/Word as register/slot word moves -- the value never round-trips
  ;; through memory.
  (IrInstrPack i64 CompilerIrValueList AstType)
  (IrInstrWord i64 CompilerIrValue i64 AstType)
  (IrInstrTailCallIndirect CompilerIrValue CompilerIrCallArgs AstType)
  (IrInstrSwitch CompilerIrValue i64 CompilerIrSwitchCaseList String))

(define (ir-instr-vector-bin-op
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (IrInstrVectorBinOp
    (box (CompilerIrInstrVectorBinOpPayload dst op lhs rhs lanes ty))))

(define (ir-instr-vector-compare
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (IrInstrVectorCompare
    (box (CompilerIrInstrVectorComparePayload dst op lhs rhs lanes ty))))

(define (ir-instr-select
  [dst : i64]
  [mask : CompilerIrValue]
  [on-true : CompilerIrValue]
  [on-false : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (IrInstrSelect
    (box (CompilerIrInstrSelectPayload dst mask on-true on-false lanes ty))))

(define (ir-instr-vector-store
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (IrInstrVectorStore
    (box (CompilerIrInstrVectorStorePayload base index value lanes ty))))

(define (ir-instr-predicated-store
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (IrInstrPredicatedStore
    (box (CompilerIrInstrPredicatedStorePayload base index value mask lanes ty))))

(define (ir-instr-predicated-load
  [dst : i64]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (IrInstrPredicatedLoad
    (box (CompilerIrInstrPredicatedLoadPayload dst base index mask lanes ty))))

(define (ir-instr-call-cabi-store-result
  [base : CompilerIrValue]
  [name : String]
  [args : CompilerIrCallArgs]
  [slots : CompilerIrCAbiReturnSlotList]) : CompilerIrInstr
  (IrInstrCallCAbiStoreResult
    (box (CompilerIrInstrCallCAbiStoreResultPayload base name args slots))))

(define (ir-instr-call-indirect-cabi-store-result
  [base : CompilerIrValue]
  [callee : CompilerIrValue]
  [args : CompilerIrCallArgs]
  [slots : CompilerIrCAbiReturnSlotList]) : CompilerIrInstr
  (IrInstrCallIndirectCAbiStoreResult
    (box
      (CompilerIrInstrCallIndirectCAbiStoreResultPayload base callee args slots))))

(defenum CompilerIrInstrList
  (IrInstrNil)
  (IrInstrCons CompilerIrInstr (Box CompilerIrInstrList)))

(defstruct CompilerIrInstrSeq
  (slots (Array CompilerIrInstr))
  (len i64))

(defenum CompilerIrBlock
  (IrBlock String CompilerIrInstrSeq))

(defstruct CompilerIrBlockSeq
  (slots (Array CompilerIrBlock))
  (len i64))

(defenum CompilerIrBlockList
  (IrBlockNil)
  (IrBlockCons CompilerIrBlock (Box CompilerIrBlockList))
  (IrBlockArray CompilerIrBlockSeq))

(defenum CompilerIrParam
  (IrParam String AstType i64))

(defenum CompilerIrParamList
  (IrParamNil)
  (IrParamCons CompilerIrParam (Box CompilerIrParamList)))

(defenum CompilerIrFunction
  (IrFunction String CompilerIrParamList AstType i64 CompilerIrBlockList))

(defstruct CompilerIrFunctionSeq
  (slots (Array CompilerIrFunction))
  (len i64))

(defenum CompilerIrFunctionList
  (IrFunctionNil)
  (IrFunctionCons CompilerIrFunction (Box CompilerIrFunctionList))
  (IrFunctionArray CompilerIrFunctionSeq))

(defenum CompilerIrGlobal
  (IrGlobal String AstType CompilerIrValue))

(defenum CompilerIrGlobalList
  (IrGlobalNil)
  (IrGlobalCons CompilerIrGlobal (Box CompilerIrGlobalList)))

(defenum CompilerIrExtern
  (IrExtern String AstType AstExternAbi String AstExternLinkInputList bool))

(defenum CompilerIrExternList
  (IrExternNil)
  (IrExternCons CompilerIrExtern (Box CompilerIrExternList)))

(defenum CompilerIrProgram
  (IrProgram CompilerIrGlobalList CompilerIrFunctionList CompilerIrExternList))

(define (compiler-ir-value-cons
  [value : CompilerIrValue]
  [rest : CompilerIrValueList]) : CompilerIrValueList
  (IrValueCons value (box rest)))

(define (compiler-ir-phi-input-cons
  [value : CompilerIrValue]
  [label : String]
  [rest : CompilerIrPhiInputList]) : CompilerIrPhiInputList
  (IrPhiInputCons value label (box rest)))

(define (compiler-ir-switch-case-cons
  [tag : i64]
  [label : String]
  [rest : CompilerIrSwitchCaseList]) : CompilerIrSwitchCaseList
  (IrSwitchCaseCons (IrSwitchCase tag label) (box rest)))

(define (compiler-ir-instr-cons
  [instr : CompilerIrInstr]
  [rest : CompilerIrInstrList]) : CompilerIrInstrList
  (IrInstrCons instr (box rest)))

(define (compiler-ir-instr-list-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons _ rest) (+ 1 (compiler-ir-instr-list-count (box-get rest)))]))

(define (compiler-ir-instr-list-fill-array
  [instrs : CompilerIrInstrList]
  [slots : (Array CompilerIrInstr)]
  [index : i64]) : unit
  (match instrs
    [(IrInstrNil) unit]
    [(IrInstrCons instr rest)
      (begin
        (array-set! slots index instr)
        (compiler-ir-instr-list-fill-array (box-get rest) slots (+ index 1)))]))

(define (compiler-ir-instr-seq-from-list [instrs : CompilerIrInstrList]) : CompilerIrInstrSeq
  (let
    [count : i64 (compiler-ir-instr-list-count instrs)]
    [slots : (Array CompilerIrInstr) (make-array CompilerIrInstr count)]
    (begin
      (compiler-ir-instr-list-fill-array instrs slots 0)
      (CompilerIrInstrSeq slots count))))

(define (compiler-ir-instr-seq-to-list-rev
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [acc : CompilerIrInstrList]) : CompilerIrInstrList
  (let
    [cursor : i64 index]
    [out : CompilerIrInstrList acc]
    (begin
      (while (>= cursor 0)
        (begin
          (set! out (IrInstrCons (array-ref slots cursor) (box out)))
          (set! cursor (- cursor 1))))
      out)))

(define (compiler-ir-instr-seq-to-list [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (compiler-ir-instr-seq-to-list-rev
    (struct-get instrs slots)
    (- (struct-get instrs len) 1)
    IrInstrNil))

(define (compiler-ir-instr-seq-count [instrs : CompilerIrInstrSeq]) : i64
  (struct-get instrs len))

(define (compiler-ir-instr-seq-empty? [instrs : CompilerIrInstrSeq]) : bool
  (= (struct-get instrs len) 0))

;; #2357: MUST stay `array-ref`. `CompilerIrInstr` is an inline-by-value enum
;; (#1867), so the raw `(ptr-read (ptr-offset (ptr-cast (array-data ...) :
;; (Ptr CompilerIrInstr)) index))` form mis-scales the element stride and reads
;; garbage; `array-ref` lowers with the correct element size.
(define (compiler-ir-instr-seq-ref [instrs : CompilerIrInstrSeq] [index : i64]) : CompilerIrInstr
  (array-ref (struct-get instrs slots) index))

(define (compiler-ir-block [label : String] [instrs : CompilerIrInstrList]) : CompilerIrBlock
  (IrBlock label (compiler-ir-instr-seq-from-list instrs)))

(define (compiler-ir-block-cons
  [block : CompilerIrBlock]
  [rest : CompilerIrBlockList]) : CompilerIrBlockList
  (IrBlockCons block (box rest)))

(define (compiler-ir-block-list-count-cons [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons _ rest)
      (+ 1 (compiler-ir-block-list-count-cons (box-get rest)))]
    [(IrBlockArray seq) (struct-get seq len)]))

(define (compiler-ir-block-list-fill-array
  [blocks : CompilerIrBlockList]
  [slots : (Array CompilerIrBlock)]
  [index : i64]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (begin
        (array-set! slots index block)
        (compiler-ir-block-list-fill-array (box-get rest) slots (+ index 1)))]
    [(IrBlockArray seq)
      (let
        [i : i64 0]
        [n : i64 (struct-get seq len)]
        (while (< i n)
          (begin
            (array-set! slots (+ index i) (array-ref (struct-get seq slots) i))
            (set! i (+ i 1)))))]))

(define (compiler-ir-block-seq-from-list [blocks : CompilerIrBlockList]) : CompilerIrBlockSeq
  (let
    [count : i64 (compiler-ir-block-list-count-cons blocks)]
    [slots : (Array CompilerIrBlock) (make-array CompilerIrBlock count)]
    (begin
      (compiler-ir-block-list-fill-array blocks slots 0)
      (CompilerIrBlockSeq slots count))))

(define (compiler-ir-block-seq-to-list-rev
  [slots : (Array CompilerIrBlock)]
  [index : i64]
  [acc : CompilerIrBlockList]) : CompilerIrBlockList
  (let
    [cursor : i64 index]
    [out : CompilerIrBlockList acc]
    (begin
      (while (>= cursor 0)
        (begin
          (set! out (compiler-ir-block-cons (array-ref slots cursor) out))
          (set! cursor (- cursor 1))))
      out)))

(define (compiler-ir-block-seq-to-list [blocks : CompilerIrBlockSeq]) : CompilerIrBlockList
  (compiler-ir-block-seq-to-list-rev
    (struct-get blocks slots)
    (- (struct-get blocks len) 1)
    IrBlockNil))

(define (compiler-ir-block-seq-count [blocks : CompilerIrBlockSeq]) : i64
  (struct-get blocks len))

;; #2357: MUST stay `array-ref` (see compiler-ir-instr-seq-ref above).
(define (compiler-ir-block-seq-ref [blocks : CompilerIrBlockSeq] [index : i64]) : CompilerIrBlock
  (array-ref (struct-get blocks slots) index))

(define (compiler-ir-block-list-force-cons [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockArray seq) (compiler-ir-block-seq-to-list seq)]
    [_ blocks]))

(define (compiler-ir-block-list-compact [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockArray _) blocks]
    [_ (IrBlockArray (compiler-ir-block-seq-from-list blocks))]))

(define (compiler-ir-function-block-list [func : CompilerIrFunction]) : CompilerIrBlockList
  (match func
    [(IrFunction _ _ _ _ blocks) (compiler-ir-block-list-force-cons blocks)]))

(define (compiler-ir-function-compact-blocks [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret vars blocks)
      (IrFunction name params ret vars (compiler-ir-block-list-compact blocks))]))

(define (compiler-ir-param-cons
  [param : CompilerIrParam]
  [rest : CompilerIrParamList]) : CompilerIrParamList
  (IrParamCons param (box rest)))

(define (compiler-ir-function-cons
  [func : CompilerIrFunction]
  [rest : CompilerIrFunctionList]) : CompilerIrFunctionList
  (IrFunctionCons func (box rest)))

(define (compiler-ir-function-list-count-cons
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons _ rest)
      (+ 1 (compiler-ir-function-list-count-cons (box-get rest)))]
    [(IrFunctionArray seq) (struct-get seq len)]))

(define (compiler-ir-function-list-fill-array
  [functions : CompilerIrFunctionList]
  [slots : (Array CompilerIrFunction)]
  [index : i64]) : unit
  (match functions
    [(IrFunctionNil) unit]
    [(IrFunctionCons func rest)
      (begin
        (array-set! slots index func)
        (compiler-ir-function-list-fill-array (box-get rest) slots (+ index 1)))]
    [(IrFunctionArray seq)
      (let
        [i : i64 0]
        [n : i64 (struct-get seq len)]
        [src : (Array CompilerIrFunction) (struct-get seq slots)]
        (while (< i n)
          (begin
            (array-set! slots (+ index i) (array-ref src i))
            (set! i (+ i 1)))))]))

(define (compiler-ir-function-seq-from-list
  [functions : CompilerIrFunctionList]) : CompilerIrFunctionSeq
  (let
    [count : i64 (compiler-ir-function-list-count-cons functions)]
    [slots : (Array CompilerIrFunction) (make-array CompilerIrFunction count)]
    (begin
      (compiler-ir-function-list-fill-array functions slots 0)
      (CompilerIrFunctionSeq slots count))))

(define (compiler-ir-function-seq-to-list-rev
  [slots : (Array CompilerIrFunction)]
  [index : i64]
  [acc : CompilerIrFunctionList]) : CompilerIrFunctionList
  (let
    [cursor : i64 index]
    [out : CompilerIrFunctionList acc]
    (begin
      (while (>= cursor 0)
        (begin
          (set! out (compiler-ir-function-cons (array-ref slots cursor) out))
          (set! cursor (- cursor 1))))
      out)))

(define (compiler-ir-function-seq-to-list [functions : CompilerIrFunctionSeq]) : CompilerIrFunctionList
  (compiler-ir-function-seq-to-list-rev
    (struct-get functions slots)
    (- (struct-get functions len) 1)
    IrFunctionNil))

(define (compiler-ir-function-seq-count [functions : CompilerIrFunctionSeq]) : i64
  (struct-get functions len))

;; Keep `array-ref`; aggregate enum array elements need the checked array path,
;; as with instruction and block sequences.
(define (compiler-ir-function-seq-ref
  [functions : CompilerIrFunctionSeq]
  [index : i64]) : CompilerIrFunction
  (array-ref (struct-get functions slots) index))

(define (compiler-ir-function-list-force-cons
  [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionArray seq) (compiler-ir-function-seq-to-list seq)]
    [_ functions]))

(define (compiler-ir-function-list-compact [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionArray _) functions]
    [_ (IrFunctionArray (compiler-ir-function-seq-from-list functions))]))

(define (compiler-ir-global-cons
  [global : CompilerIrGlobal]
  [rest : CompilerIrGlobalList]) : CompilerIrGlobalList
  (IrGlobalCons global (box rest)))

(define (compiler-ir-extern-cons
  [extern : CompilerIrExtern]
  [rest : CompilerIrExternList]) : CompilerIrExternList
  (IrExternCons extern (box rest)))

(define (compiler-ir-extern-default [name : String] [ty : AstType]) : CompilerIrExtern
  (IrExtern name ty (AstExternAbiC) name AstExternLinkInputNil false))

(define (compiler-ir-clone-value [value : CompilerIrValue]) : CompilerIrValue
  (match value
    [(IrValueVar id) (IrValueVar id)]
    [(IrValueGlobal name) (IrValueGlobal (clone name))]
    [(IrValueGlobalAddr name) (IrValueGlobalAddr (clone name))]
    [(IrValueFunction name) (IrValueFunction (clone name))]
    [(IrValueI64 n) (IrValueI64 n)]
    [(IrValueF64 n) (IrValueF64 n)]
    [(IrValueBool b) (IrValueBool b)]
    [(IrValueChar c) (IrValueChar c)]
    [(IrValueString s) (IrValueString (clone s))]
    [(IrValueBytes s) (IrValueBytes (clone s))]
    [(IrValueUnit) (IrValueUnit)]))

(define (compiler-ir-clone-maybe-value [value : CompilerIrMaybeValue]) : CompilerIrMaybeValue
  (match value
    [(IrNoValue) (IrNoValue)]
    [(IrSomeValue inner) (IrSomeValue (compiler-ir-clone-value inner))]))

(define (compiler-ir-clone-value-list-acc
  [values : CompilerIrValueList]
  [acc : CompilerIrValueList]) : CompilerIrValueList
  (match values
    [(IrValueNil) acc]
    [(IrValueCons value rest)
      (compiler-ir-clone-value-list-acc
        (box-get rest)
        (compiler-ir-value-cons (compiler-ir-clone-value value) acc))]))

(define (compiler-ir-value-list-reverse-onto
  [values : CompilerIrValueList]
  [acc : CompilerIrValueList]) : CompilerIrValueList
  (match values
    [(IrValueNil) acc]
    [(IrValueCons value rest)
      (compiler-ir-value-list-reverse-onto
        (box-get rest)
        (compiler-ir-value-cons value acc))]))

(define (compiler-ir-clone-value-list [values : CompilerIrValueList]) : CompilerIrValueList
  (compiler-ir-value-list-reverse-onto
    (compiler-ir-clone-value-list-acc values IrValueNil)
    IrValueNil))

(define (compiler-ir-clone-call-args [args : CompilerIrCallArgs]) : CompilerIrCallArgs
  (match args
    [(IrCallArgsNil) (IrCallArgsNil)]
    [(IrCallArgsOne a) (IrCallArgsOne (compiler-ir-clone-value a))]
    [(IrCallArgsTwo a b)
      (IrCallArgsTwo (compiler-ir-clone-value a) (compiler-ir-clone-value b))]
    [(IrCallArgsArray values) (IrCallArgsArray (clone values))]))

(define (compiler-ir-clone-c-abi-return-slot [slot : CompilerIrCAbiReturnSlot]) : CompilerIrCAbiReturnSlot
  (match slot
    [(IrCAbiReturnSlot ty offset)
      (IrCAbiReturnSlot (compiler-ir-clone-type ty) offset)]))

(define (compiler-ir-clone-c-abi-return-slots
  [slots : CompilerIrCAbiReturnSlotList]) : CompilerIrCAbiReturnSlotList
  (match slots
    [(IrCAbiReturnSlotNil) (IrCAbiReturnSlotNil)]
    [(IrCAbiReturnSlotCons slot rest)
      (IrCAbiReturnSlotCons
        (compiler-ir-clone-c-abi-return-slot slot)
        (box (compiler-ir-clone-c-abi-return-slots (box-get rest))))]))

(define (compiler-ir-clone-phi-input-list-acc
  [inputs : CompilerIrPhiInputList]
  [acc : CompilerIrPhiInputList]) : CompilerIrPhiInputList
  (match inputs
    [(IrPhiInputNil) acc]
    [(IrPhiInputCons value label rest)
      (compiler-ir-clone-phi-input-list-acc
        (box-get rest)
        (compiler-ir-phi-input-cons
          (compiler-ir-clone-value value)
          (clone label)
          acc))]))

(define (compiler-ir-phi-input-list-reverse-onto
  [inputs : CompilerIrPhiInputList]
  [acc : CompilerIrPhiInputList]) : CompilerIrPhiInputList
  (match inputs
    [(IrPhiInputNil) acc]
    [(IrPhiInputCons value label rest)
      (compiler-ir-phi-input-list-reverse-onto
        (box-get rest)
        (compiler-ir-phi-input-cons value label acc))]))

(define (compiler-ir-clone-phi-input-list [inputs : CompilerIrPhiInputList]) : CompilerIrPhiInputList
  (compiler-ir-phi-input-list-reverse-onto
    (compiler-ir-clone-phi-input-list-acc inputs IrPhiInputNil)
    IrPhiInputNil))

(define (compiler-ir-clone-switch-case [case : CompilerIrSwitchCase]) : CompilerIrSwitchCase
  (match case
    [(IrSwitchCase tag label) (IrSwitchCase tag (clone label))]))

(define (compiler-ir-clone-switch-case-list-acc
  [cases : CompilerIrSwitchCaseList]
  [acc : CompilerIrSwitchCaseList]) : CompilerIrSwitchCaseList
  (match cases
    [(IrSwitchCaseNil) acc]
    [(IrSwitchCaseCons case rest)
      (compiler-ir-clone-switch-case-list-acc
        (box-get rest)
        (IrSwitchCaseCons (compiler-ir-clone-switch-case case) (box acc)))]))

(define (compiler-ir-switch-case-list-reverse-onto
  [cases : CompilerIrSwitchCaseList]
  [acc : CompilerIrSwitchCaseList]) : CompilerIrSwitchCaseList
  (match cases
    [(IrSwitchCaseNil) acc]
    [(IrSwitchCaseCons case rest)
      (compiler-ir-switch-case-list-reverse-onto
        (box-get rest)
        (IrSwitchCaseCons case (box acc)))]))

(define (compiler-ir-clone-switch-case-list [cases : CompilerIrSwitchCaseList]) : CompilerIrSwitchCaseList
  (compiler-ir-switch-case-list-reverse-onto
    (compiler-ir-clone-switch-case-list-acc cases IrSwitchCaseNil)
    IrSwitchCaseNil))

;; Deep-clone a (flattened) AstType into the CURRENT arena. The builtin
;; clone$AstType copies the i64 ty-pool child ids verbatim, which only SHARES the
;; source's ty-pool nodes. That breaks the per-function optimizer arena escape
;; (#1633): a type pushed during optimization lives in the scratch arena, so a
;; shared id dangles once the scratch is rewound. Re-pushing each child here puts
;; the cloned subtree's nodes in the (enclosing) arena current during the escape
;; clone, so the escaped function owns valid type nodes after the rewind.
;; Variants without i64 children (nullary, and the String/lifetime-carrying named
;; types) have no ty-pool ids, so the builtin clone is correct for them.
(define (compiler-ir-clone-type [ty : AstType]) : AstType
  (match ty
    [(AstTyFunc args ret)
      (AstTyFunc
        (box (compiler-ir-clone-type-list (box-get args)))
        (ty-node-push (compiler-ir-clone-type (ty-node-get ret))))]
    [(AstTyTuple elems)
      (AstTyTuple (box (compiler-ir-clone-type-list (box-get elems))))]
    [(AstTyArray elem len)
      (AstTyArray
        (ty-node-push (compiler-ir-clone-type (ty-node-get elem)))
        len)]
    [(AstTyDynArray elem)
      (AstTyDynArray (ty-node-push (compiler-ir-clone-type (ty-node-get elem))))]
    [(AstTyBox elem)
      (AstTyBox (ty-node-push (compiler-ir-clone-type (ty-node-get elem))))]
    [(AstTyRegion region inner)
      (AstTyRegion
        (clone region)
        (ty-node-push (compiler-ir-clone-type (ty-node-get inner))))]
    [(AstTyRef region inner)
      (AstTyRef
        (clone region)
        (ty-node-push (compiler-ir-clone-type (ty-node-get inner))))]
    [(AstTyMutRef region inner)
      (AstTyMutRef
        (clone region)
        (ty-node-push (compiler-ir-clone-type (ty-node-get inner))))]
    [(AstTyPtr elem)
      (AstTyPtr (ty-node-push (compiler-ir-clone-type (ty-node-get elem))))]
    [(AstTyMutPtr elem)
      (AstTyMutPtr (ty-node-push (compiler-ir-clone-type (ty-node-get elem))))]
    [_ (clone ty)]))

(define (compiler-ir-clone-type-list [tys : AstTypeList]) : AstTypeList
  (match tys
    [(AstTypeNil) (AstTypeNil)]
    [(AstTypeCons head tail)
      (AstTypeCons
        (ty-node-push (compiler-ir-clone-type (ty-node-get head)))
        (box (compiler-ir-clone-type-list (box-get tail))))]))

(define (compiler-ir-clone-instr [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrMov dst src ty)
      (IrInstrMov dst (compiler-ir-clone-value src) (compiler-ir-clone-type ty))]
    [(IrInstrAlloc dst ty) (IrInstrAlloc dst (compiler-ir-clone-type ty))]
    [(IrInstrAddrOf dst src) (IrInstrAddrOf dst src)]
    [(IrInstrGep dst base offset ty)
      (IrInstrGep
        dst
        (compiler-ir-clone-value base)
        (compiler-ir-clone-value offset)
        (compiler-ir-clone-type ty))]
    [(IrInstrLoad dst src ty)
      (IrInstrLoad
        dst
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type ty))]
    [(IrInstrStorePtr dst src ty)
      (IrInstrStorePtr
        (compiler-ir-clone-value dst)
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type ty))]
    [(IrInstrCopyBytes dst src size)
      (IrInstrCopyBytes
        (compiler-ir-clone-value dst)
        (compiler-ir-clone-value src)
        size)]
    [(IrInstrBoundsCheck index length label)
      (IrInstrBoundsCheck
        (compiler-ir-clone-value index)
        (compiler-ir-clone-value length)
        (clone label))]
    [(IrInstrCast dst src from-ty to-ty)
      (IrInstrCast
        dst
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type from-ty)
        (compiler-ir-clone-type to-ty))]
    [(IrInstrBitcast dst src from-ty to-ty)
      (IrInstrBitcast
        dst
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type from-ty)
        (compiler-ir-clone-type to-ty))]
    [(IrInstrBinOp dst op lhs rhs ty)
      (IrInstrBinOp
        dst
        op
        (compiler-ir-clone-value lhs)
        (compiler-ir-clone-value rhs)
        (compiler-ir-clone-type ty))]
    [(IrInstrUnOp dst op src ty)
      (IrInstrUnOp
        dst
        op
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type ty))]
    [(IrInstrLaneId dst lane ty)
      (IrInstrLaneId dst lane (compiler-ir-clone-type ty))]
    [(IrInstrSplat dst value lanes ty)
      (IrInstrSplat
        dst
        (compiler-ir-clone-value value)
        lanes
        (compiler-ir-clone-type ty))]
    [(IrInstrVectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload dst op lhs rhs lanes ty)
          (ir-instr-vector-bin-op
            dst
            op
            (compiler-ir-clone-value lhs)
            (compiler-ir-clone-value rhs)
            lanes
            (compiler-ir-clone-type ty))])]
    [(IrInstrVectorReduce dst op src lanes ty)
      (IrInstrVectorReduce
        dst
        op
        (compiler-ir-clone-value src)
        lanes
        (compiler-ir-clone-type ty))]
    [(IrInstrVectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload dst op lhs rhs lanes ty)
          (ir-instr-vector-compare
            dst
            op
            (compiler-ir-clone-value lhs)
            (compiler-ir-clone-value rhs)
            lanes
            (compiler-ir-clone-type ty))])]
    [(IrInstrMaskBinOp dst op lhs rhs lanes)
      (IrInstrMaskBinOp
        dst
        op
        (compiler-ir-clone-value lhs)
        (compiler-ir-clone-value rhs)
        lanes)]
    [(IrInstrMaskNot dst src lanes)
      (IrInstrMaskNot dst (compiler-ir-clone-value src) lanes)]
    [(IrInstrMaskReduce dst op src lanes)
      (IrInstrMaskReduce dst op (compiler-ir-clone-value src) lanes)]
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload dst cond then-value else-value lanes ty)
          (ir-instr-select
            dst
            (compiler-ir-clone-value cond)
            (compiler-ir-clone-value then-value)
            (compiler-ir-clone-value else-value)
            lanes
            (compiler-ir-clone-type ty))])]
    [(IrInstrVectorLoad dst base index lanes ty)
      (IrInstrVectorLoad
        dst
        (compiler-ir-clone-value base)
        (compiler-ir-clone-value index)
        lanes
        (compiler-ir-clone-type ty))]
    [(IrInstrVectorStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorStorePayload base index value lanes ty)
          (ir-instr-vector-store
            (compiler-ir-clone-value base)
            (compiler-ir-clone-value index)
            (compiler-ir-clone-value value)
            lanes
            (compiler-ir-clone-type ty))])]
    [(IrInstrPredicatedStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedStorePayload base index value mask lanes ty)
          (ir-instr-predicated-store
            (compiler-ir-clone-value base)
            (compiler-ir-clone-value index)
            (compiler-ir-clone-value value)
            (compiler-ir-clone-value mask)
            lanes
            (compiler-ir-clone-type ty))])]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload dst base index mask lanes ty)
          (ir-instr-predicated-load
            dst
            (compiler-ir-clone-value base)
            (compiler-ir-clone-value index)
            (compiler-ir-clone-value mask)
            lanes
            (compiler-ir-clone-type ty))])]
    [(IrInstrTailMask dst index len lanes)
      (IrInstrTailMask
        dst
        (compiler-ir-clone-value index)
        (compiler-ir-clone-value len)
        lanes)]
    [(IrInstrEntryArgc dst) (IrInstrEntryArgc dst)]
    [(IrInstrEntryArgv dst) (IrInstrEntryArgv dst)]
    [(IrInstrEntryEnvp dst) (IrInstrEntryEnvp dst)]
    [(IrInstrCpuId dst leaf subleaf lanes)
      (IrInstrCpuId
        dst
        (compiler-ir-clone-value leaf)
        (compiler-ir-clone-value subleaf)
        lanes)]
    [(IrInstrXgetbv dst index)
      (IrInstrXgetbv dst (compiler-ir-clone-value index))]
    [(IrInstrSyscall dst args)
      (IrInstrSyscall dst (compiler-ir-clone-call-args args))]
    [(IrInstrCall dst name args ty)
      (IrInstrCall
        dst
        (clone name)
        (compiler-ir-clone-call-args args)
        (compiler-ir-clone-type ty))]
    [(IrInstrCallIndirect dst callee args ty)
      (IrInstrCallIndirect
        dst
        (compiler-ir-clone-value callee)
        (compiler-ir-clone-call-args args)
        (compiler-ir-clone-type ty))]
    [(IrInstrCallIndirectC dst callee args ty)
      (IrInstrCallIndirectC
        dst
        (compiler-ir-clone-value callee)
        (compiler-ir-clone-call-args args)
        (compiler-ir-clone-type ty))]
    [(IrInstrCallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload base name args slots)
          (ir-instr-call-cabi-store-result
            (compiler-ir-clone-value base)
            (clone name)
            (compiler-ir-clone-call-args args)
            (compiler-ir-clone-c-abi-return-slots slots))])]
    [(IrInstrCallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload
            base
            callee
            args
            slots)
          (ir-instr-call-indirect-cabi-store-result
            (compiler-ir-clone-value base)
            (compiler-ir-clone-value callee)
            (compiler-ir-clone-call-args args)
            (compiler-ir-clone-c-abi-return-slots slots))])]
    [(IrInstrTailCall name args ty)
      (IrInstrTailCall
        (clone name)
        (compiler-ir-clone-call-args args)
        (compiler-ir-clone-type ty))]
    [(IrInstrStore name value ty)
      (IrInstrStore
        (clone name)
        (compiler-ir-clone-value value)
        (compiler-ir-clone-type ty))]
    [(IrInstrJump label) (IrInstrJump (clone label))]
    [(IrInstrBranch cond true-label false-label)
      (IrInstrBranch
        (compiler-ir-clone-value cond)
        (clone true-label)
        (clone false-label))]
    [(IrInstrReturn value)
      (IrInstrReturn (compiler-ir-clone-maybe-value value))]
    [(IrInstrPhi dst inputs ty)
      (IrInstrPhi
        dst
        (compiler-ir-clone-phi-input-list inputs)
        (compiler-ir-clone-type ty))]
    [(IrInstrPack dst words ty)
      (IrInstrPack
        dst
        (compiler-ir-clone-value-list words)
        (compiler-ir-clone-type ty))]
    [(IrInstrWord dst src index ty)
      (IrInstrWord
        dst
        (compiler-ir-clone-value src)
        index
        (compiler-ir-clone-type ty))]
    [(IrInstrTailCallIndirect callee args ty)
      (IrInstrTailCallIndirect
        (compiler-ir-clone-value callee)
        (compiler-ir-clone-call-args args)
        (compiler-ir-clone-type ty))]
    [(IrInstrSwitch index base cases default-label)
      (IrInstrSwitch
        (compiler-ir-clone-value index)
        base
        (compiler-ir-clone-switch-case-list cases)
        (clone default-label))]))

(define (compiler-ir-clone-instr-list-acc
  [instrs : CompilerIrInstrList]
  [acc : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) acc]
    [(IrInstrCons instr rest)
      (compiler-ir-clone-instr-list-acc
        (box-get rest)
        (compiler-ir-instr-cons (compiler-ir-clone-instr instr) acc))]))

(define (compiler-ir-instr-list-reverse-onto
  [instrs : CompilerIrInstrList]
  [acc : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) acc]
    [(IrInstrCons instr rest)
      (compiler-ir-instr-list-reverse-onto
        (box-get rest)
        (compiler-ir-instr-cons instr acc))]))

(define (compiler-ir-clone-instr-list [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (compiler-ir-instr-list-reverse-onto
    (compiler-ir-clone-instr-list-acc instrs IrInstrNil)
    IrInstrNil))

(define (compiler-ir-clone-instr-seq-fill
  [src : (Array CompilerIrInstr)]
  [dst : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (compiler-ir-clone-instr (array-ref src index)))
      (compiler-ir-clone-instr-seq-fill src dst (+ index 1) count))))

(define (compiler-ir-clone-instr-seq [instrs : CompilerIrInstrSeq]) : CompilerIrInstrSeq
  (let
    [count : i64 (struct-get instrs len)]
    [src : (Array CompilerIrInstr) (struct-get instrs slots)]
    [dst : (Array CompilerIrInstr) (make-array CompilerIrInstr count)]
    (begin
      (compiler-ir-clone-instr-seq-fill src dst 0 count)
      (CompilerIrInstrSeq dst count))))

(define (compiler-ir-clone-block [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (IrBlock (clone label) (compiler-ir-clone-instr-seq instrs))]))

(define (compiler-ir-clone-block-list-acc
  [blocks : CompilerIrBlockList]
  [acc : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) acc]
    [(IrBlockCons block rest)
      (compiler-ir-clone-block-list-acc
        (box-get rest)
        (compiler-ir-block-cons (compiler-ir-clone-block block) acc))]
    [(IrBlockArray seq)
      (compiler-ir-clone-block-list-acc (compiler-ir-block-seq-to-list seq) acc)]))

(define (compiler-ir-block-list-reverse-onto
  [blocks : CompilerIrBlockList]
  [acc : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) acc]
    [(IrBlockCons block rest)
      (compiler-ir-block-list-reverse-onto
        (box-get rest)
        (compiler-ir-block-cons block acc))]
    [(IrBlockArray seq)
      (compiler-ir-block-list-reverse-onto
        (compiler-ir-block-seq-to-list seq)
        acc)]))

(define (compiler-ir-clone-block-list [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (compiler-ir-block-list-reverse-onto
    (compiler-ir-clone-block-list-acc blocks IrBlockNil)
    IrBlockNil))

(define (compiler-ir-clone-param [param : CompilerIrParam]) : CompilerIrParam
  (match param
    [(IrParam name ty id) (IrParam (clone name) (compiler-ir-clone-type ty) id)]))

(define (compiler-ir-clone-param-list-acc
  [params : CompilerIrParamList]
  [acc : CompilerIrParamList]) : CompilerIrParamList
  (match params
    [(IrParamNil) acc]
    [(IrParamCons param rest)
      (compiler-ir-clone-param-list-acc
        (box-get rest)
        (compiler-ir-param-cons (compiler-ir-clone-param param) acc))]))

(define (compiler-ir-param-list-reverse-onto
  [params : CompilerIrParamList]
  [acc : CompilerIrParamList]) : CompilerIrParamList
  (match params
    [(IrParamNil) acc]
    [(IrParamCons param rest)
      (compiler-ir-param-list-reverse-onto
        (box-get rest)
        (compiler-ir-param-cons param acc))]))

(define (compiler-ir-clone-param-list [params : CompilerIrParamList]) : CompilerIrParamList
  (compiler-ir-param-list-reverse-onto
    (compiler-ir-clone-param-list-acc params IrParamNil)
    IrParamNil))

(define (compiler-ir-clone-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret vars blocks)
      (IrFunction
        (clone name)
        (compiler-ir-clone-param-list params)
        (clone ret)
        vars
        (compiler-ir-block-list-compact (compiler-ir-clone-block-list blocks)))]))

(define (compiler-ir-clone-function-list-acc
  [functions : CompilerIrFunctionList]
  [acc : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) acc]
    [(IrFunctionCons func rest)
      (compiler-ir-clone-function-list-acc
        (box-get rest)
        (compiler-ir-function-cons (compiler-ir-clone-function func) acc))]
    [(IrFunctionArray seq)
      (compiler-ir-clone-function-list-acc
        (compiler-ir-function-seq-to-list seq)
        acc)]))

(define (compiler-ir-function-list-reverse-onto
  [functions : CompilerIrFunctionList]
  [acc : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) acc]
    [(IrFunctionCons func rest)
      (compiler-ir-function-list-reverse-onto
        (box-get rest)
        (compiler-ir-function-cons func acc))]
    [(IrFunctionArray seq)
      (compiler-ir-function-list-reverse-onto
        (compiler-ir-function-seq-to-list seq)
        acc)]))

(define (compiler-ir-clone-function-list [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (compiler-ir-function-list-compact
    (compiler-ir-function-list-reverse-onto
      (compiler-ir-clone-function-list-acc functions IrFunctionNil)
      IrFunctionNil)))

(define (compiler-ir-clone-global [global : CompilerIrGlobal]) : CompilerIrGlobal
  (match global
    [(IrGlobal name ty value)
      (IrGlobal
        (clone name)
        (compiler-ir-clone-type ty)
        (compiler-ir-clone-value value))]))

(define (compiler-ir-clone-global-list-acc
  [globals : CompilerIrGlobalList]
  [acc : CompilerIrGlobalList]) : CompilerIrGlobalList
  (match globals
    [(IrGlobalNil) acc]
    [(IrGlobalCons global rest)
      (compiler-ir-clone-global-list-acc
        (box-get rest)
        (compiler-ir-global-cons (compiler-ir-clone-global global) acc))]))

(define (compiler-ir-global-list-reverse-onto
  [globals : CompilerIrGlobalList]
  [acc : CompilerIrGlobalList]) : CompilerIrGlobalList
  (match globals
    [(IrGlobalNil) acc]
    [(IrGlobalCons global rest)
      (compiler-ir-global-list-reverse-onto
        (box-get rest)
        (compiler-ir-global-cons global acc))]))

(define (compiler-ir-clone-global-list [globals : CompilerIrGlobalList]) : CompilerIrGlobalList
  (compiler-ir-global-list-reverse-onto
    (compiler-ir-clone-global-list-acc globals IrGlobalNil)
    IrGlobalNil))

(define (compiler-ir-clone-extern [extern : CompilerIrExtern]) : CompilerIrExtern
  (match extern
    [(IrExtern name ty abi symbol links provided)
      (IrExtern
        (clone name)
        (compiler-ir-clone-type ty)
        (clone abi)
        (clone symbol)
        (clone links)
        provided)]))

(define (compiler-ir-clone-extern-list-acc
  [externs : CompilerIrExternList]
  [acc : CompilerIrExternList]) : CompilerIrExternList
  (match externs
    [(IrExternNil) acc]
    [(IrExternCons extern rest)
      (compiler-ir-clone-extern-list-acc
        (box-get rest)
        (compiler-ir-extern-cons (compiler-ir-clone-extern extern) acc))]))

(define (compiler-ir-extern-list-reverse-onto
  [externs : CompilerIrExternList]
  [acc : CompilerIrExternList]) : CompilerIrExternList
  (match externs
    [(IrExternNil) acc]
    [(IrExternCons extern rest)
      (compiler-ir-extern-list-reverse-onto
        (box-get rest)
        (compiler-ir-extern-cons extern acc))]))

(define (compiler-ir-clone-extern-list [externs : CompilerIrExternList]) : CompilerIrExternList
  (compiler-ir-extern-list-reverse-onto
    (compiler-ir-clone-extern-list-acc externs IrExternNil)
    IrExternNil))

(define (compiler-ir-clone-program [program : CompilerIrProgram]) : CompilerIrProgram
  (match program
    [(IrProgram globals functions externs)
      (IrProgram
        (compiler-ir-clone-global-list globals)
        (compiler-ir-clone-function-list functions)
        (compiler-ir-clone-extern-list externs))]))

(define (compiler-ir-type-list-render [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) ""]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (string-append
          (compiler-ir-type-render head)
          (match rest
            [(AstTypeNil) ""]
            [_ (string-append " " (compiler-ir-type-list-render rest))])))]))

(define (compiler-ir-lifetime-list-render [lifetimes : AstLifetimeList]) : String
  (match lifetimes
    [(AstLifetimeNil) ""]
    [(AstLifetimeCons head rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (string-append
          head
          (match rest
            [(AstLifetimeNil) ""]
            [_ (string-append " " (compiler-ir-lifetime-list-render rest))])))]))

(define (compiler-ir-nominal-lifetime-render
  [name : String]
  [lifetimes : AstLifetimeList]) : String
  (str-cat
    "("
    name
    (string-append
      " "
      (string-append (compiler-ir-lifetime-list-render lifetimes) ")"))))

(define (compiler-ir-type-render [ty : AstType]) : String
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
    [(AstTyStr) "str"]
    [(AstTyBytes) "bytes"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyFunc args ret)
      (str-cat
        "(-> "
        (compiler-ir-type-list-render (box-get args))
        (string-append
          " "
          (string-append (compiler-ir-type-render (ty-node-get ret)) ")")))]
    [(AstTyTuple elems)
      (str-cat "(Tuple " (compiler-ir-type-list-render (box-get elems)) ")")]
    [(AstTyArray elem count)
      (str-cat
        "(Array "
        (compiler-ir-type-render (ty-node-get elem))
        " "
        (int->string count)
        ")")]
    [(AstTyDynArray elem)
      (str-cat "(Array " (compiler-ir-type-render (ty-node-get elem)) ")")]
    [(AstTyBox elem)
      (str-cat "(Box " (compiler-ir-type-render (ty-node-get elem)) ")")]
    [(AstTyRegion region inner)
      (str-cat
        "(Region "
        region
        (string-append
          " "
          (string-append (compiler-ir-type-render (ty-node-get inner)) ")")))]
    [(AstTyRef region inner)
      (str-cat
        "(& "
        region
        (string-append
          " "
          (string-append (compiler-ir-type-render (ty-node-get inner)) ")")))]
    [(AstTyMutRef region inner)
      (str-cat
        "(&mut "
        region
        (string-append
          " "
          (string-append (compiler-ir-type-render (ty-node-get inner)) ")")))]
    [(AstTyEnum name) (intern-str name)]
    [(AstTyEnumArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstTyStruct name) (intern-str name)]
    [(AstTyStructArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstTyVar name) (intern-str name)]
    [(AstTyVarArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstTyPtr elem)
      (str-cat "(Ptr " (compiler-ir-type-render (ty-node-get elem)) ")")]
    [(AstTyMutPtr elem)
      (str-cat "(MutPtr " (compiler-ir-type-render (ty-node-get elem)) ")")]))

(define (compiler-ir-u64-payload-render [value : u64]) : String
  (int->string (cast value : i64)))

(define (compiler-ir-value-render [value : CompilerIrValue]) : String
  (match value
    [(IrValueVar id) (string-append "%" (int->string id))]
    [(IrValueGlobal name) (string-append "@" name)]
    [(IrValueGlobalAddr name) (string-append "&@" name)]
    [(IrValueFunction name) (string-append "fn@" name)]
    [(IrValueI64 value) (int->string value)]
    [(IrValueF64 value)
      (str-cat "float-bits:" (compiler-ir-u64-payload-render value))]
    [(IrValueBool value)
      (if value
        "true"
        "false")]
    [(IrValueChar value) (int->string (cast value : i64))]
    [(IrValueString value) value]
    [(IrValueBytes value)
      (str-cat "<bytes:" (int->string (string-length value)) ">")]
    [(IrValueUnit) "unit"]))

(define (compiler-ir-value-list-render [values : CompilerIrValueList]) : String
  (match values
    [(IrValueNil) ""]
    [(IrValueCons value rest)
      (string-append
        (compiler-ir-value-render value)
        (match (box-get rest)
          [(IrValueNil) ""]
          [_
            (string-append ", " (compiler-ir-value-list-render (box-get rest)))]))]))

(define (compiler-ir-switch-case-render [case : CompilerIrSwitchCase]) : String
  (match case
    [(IrSwitchCase tag label) (str-cat (int->string tag) ":" label)]))

(define (compiler-ir-switch-case-list-render [cases : CompilerIrSwitchCaseList]) : String
  (match cases
    [(IrSwitchCaseNil) ""]
    [(IrSwitchCaseCons case rest)
      (string-append
        (compiler-ir-switch-case-render case)
        (match (box-get rest)
          [(IrSwitchCaseNil) ""]
          [_
            (string-append
              ", "
              (compiler-ir-switch-case-list-render (box-get rest)))]))]))

(define (compiler-ir-value-list-count [values : CompilerIrValueList]) : i64
  (match values
    [(IrValueNil) 0]
    [(IrValueCons _ rest) (+ 1 (compiler-ir-value-list-count (box-get rest)))]))

(define (compiler-ir-value-list-fill-array
  [values : CompilerIrValueList]
  [out : (Array CompilerIrValue)]
  [index : i64]) : unit
  (match values
    [(IrValueNil) unit]
    [(IrValueCons value rest)
      (begin
        (array-set! out index value)
        (compiler-ir-value-list-fill-array (box-get rest) out (+ index 1)))]))

(define (compiler-ir-call-args-array [values : CompilerIrValueList]) : CompilerIrCallArgs
  (let
    [count : i64 (compiler-ir-value-list-count values)]
    [out : (Array CompilerIrValue) (make-array CompilerIrValue count)]
    (begin
      (compiler-ir-value-list-fill-array values out 0)
      (IrCallArgsArray out))))

(define (compiler-ir-call-args-from-list [values : CompilerIrValueList]) : CompilerIrCallArgs
  (match values
    [(IrValueNil) (IrCallArgsNil)]
    [(IrValueCons a rest)
      (match (box-get rest)
        [(IrValueNil) (IrCallArgsOne a)]
        [(IrValueCons b tail)
          (match (box-get tail)
            [(IrValueNil) (IrCallArgsTwo a b)]
            [_ (compiler-ir-call-args-array values)])])]))

(define (compiler-ir-call-args-array-render
  [values : (Array CompilerIrValue)]
  [index : i64]) : String
  (if (>= index (array-length values))
    ""
    (string-append
      (compiler-ir-value-render (array-ref values index))
      (if (= (+ index 1) (array-length values))
        ""
        (string-append
          ", "
          (compiler-ir-call-args-array-render values (+ index 1)))))))

(define (compiler-ir-call-args-render [args : CompilerIrCallArgs]) : String
  (match args
    [(IrCallArgsNil) ""]
    [(IrCallArgsOne a) (compiler-ir-value-render a)]
    [(IrCallArgsTwo a b)
      (str-cat (compiler-ir-value-render a) ", " (compiler-ir-value-render b))]
    [(IrCallArgsArray values) (compiler-ir-call-args-array-render values 0)]))

(define (compiler-ir-call-args-count [args : CompilerIrCallArgs]) : i64
  (match args
    [(IrCallArgsNil) 0]
    [(IrCallArgsOne _) 1]
    [(IrCallArgsTwo _ _) 2]
    [(IrCallArgsArray values) (array-length values)]))

(define (compiler-ir-tail-call-render
  [name : String]
  [args : CompilerIrCallArgs]
  [ty : AstType]) : String
  (str-cat
    "  tailcall "
    name
    "("
    (compiler-ir-call-args-render args)
    ") : "
    (compiler-ir-type-render ty)))

(define (compiler-ir-tail-call-indirect-render
  [callee : CompilerIrValue]
  [args : CompilerIrCallArgs]
  [ty : AstType]) : String
  (str-cat
    "  tailcall* "
    (compiler-ir-value-render callee)
    "("
    (compiler-ir-call-args-render args)
    ") : "
    (compiler-ir-type-render ty)))

(define (compiler-ir-instr-render [instr : CompilerIrInstr]) : String
  (match instr
    [(IrInstrTailCall name args ty) (compiler-ir-tail-call-render name args ty)]
    [(IrInstrTailCallIndirect callee args ty)
      (compiler-ir-tail-call-indirect-render callee args ty)]
    [(IrInstrSwitch index base cases default-label)
      (str-cat
        "  switch "
        (compiler-ir-value-render index)
        " base "
        (int->string base)
        " ["
        (compiler-ir-switch-case-list-render cases)
        "] default "
        default-label)]
    [_ "  <ir-instr>"]))

(defenum CompilerIrEffect
  (IrEffectPure)
  (IrEffectMemoryRead)
  (IrEffectCpuProbe)
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
    [(IrEffectCpuProbe)
      (match b
        [(IrEffectCpuProbe) true]
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
    [(IrEffectCpuProbe) true]
    [(IrEffectMemoryWrite) true]
    [(IrEffectControlFlow) true]
    [(IrEffectUnknown) true]))

(define (compiler-ir-effect-invalidates-cse? [effect : CompilerIrEffect]) : bool
  (match effect
    [(IrEffectPure) false]
    [_ true]))

(define (compiler-ir-runtime-memory-read? [name : String]) : bool
  (or (string-eq name "tl_region_mark") (string-eq name ".L_tl_stdin_eof")))

(define (compiler-ir-runtime-memory-write? [name : String]) : bool
  (or
    (string-eq name "tl_alloc")
    (string-eq name "tl_int_to_string")
    (string-eq name "tl_substring")
    (string-eq name "tl_string_concat")
    (string-eq name "tl_string_concat3")
    (string-eq name "tl_string_concat4")
    (string-eq name "tl_string_concat5")
    (string-eq name "tl_region_reset")
    (string-eq name "tl_array_fill8")
    (string-eq name "tl_array_zero")
    (string-eq name ".L_tl_flush_stdout")))

(define (compiler-ir-runtime-control-flow? [name : String]) : bool
  (or
    (string-eq name ".L_tl_abort")
    (string-eq name "tl_oob_abort")
    (string-eq name "tl_div_abort")
    (string-eq name "tl_shift_abort")))

(define (compiler-ir-direct-call-effect [name : String]) : CompilerIrEffect
  (cond
    [(compiler-ir-runtime-memory-read? name) IrEffectMemoryRead]
    [(compiler-ir-runtime-memory-write? name) IrEffectMemoryWrite]
    [(compiler-ir-runtime-control-flow? name) IrEffectControlFlow]
    [else IrEffectUnknown]))

(define (compiler-ir-instr-effect [instr : CompilerIrInstr]) : CompilerIrEffect
  (match instr
    [(IrInstrMov _ _ _) IrEffectPure]
    [(IrInstrAddrOf _ _) IrEffectPure]
    [(IrInstrGep _ _ _ _) IrEffectPure]
    [(IrInstrCast _ _ _ _) IrEffectPure]
    [(IrInstrBitcast _ _ _ _) IrEffectPure]
    [(IrInstrBinOp _ _ _ _ _) IrEffectPure]
    [(IrInstrUnOp _ _ _ _) IrEffectPure]
    [(IrInstrPhi _ _ _) IrEffectPure]
    [(IrInstrLaneId _ _ _) IrEffectPure]
    [(IrInstrSplat _ _ _ _) IrEffectPure]
    [(IrInstrVectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload _ _ _ _ _ _) IrEffectPure])]
    [(IrInstrVectorReduce _ _ _ _ _) IrEffectPure]
    [(IrInstrVectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload _ _ _ _ _ _) IrEffectPure])]
    [(IrInstrMaskBinOp _ _ _ _ _) IrEffectPure]
    [(IrInstrMaskNot _ _ _) IrEffectPure]
    [(IrInstrMaskReduce _ _ _ _) IrEffectPure]
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload _ _ _ _ _ _) IrEffectPure])]
    [(IrInstrTailMask _ _ _ _) IrEffectPure]
    [(IrInstrLoad _ _ _) IrEffectMemoryRead]
    [(IrInstrVectorLoad _ _ _ _ _) IrEffectMemoryRead]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload _ _ _ _ _ _) IrEffectMemoryRead])]
    [(IrInstrEntryArgc _) IrEffectMemoryRead]
    [(IrInstrEntryArgv _) IrEffectMemoryRead]
    [(IrInstrEntryEnvp _) IrEffectMemoryRead]
    [(IrInstrCpuId _ _ _ _) IrEffectCpuProbe]
    [(IrInstrXgetbv _ _) IrEffectCpuProbe]
    [(IrInstrSyscall _ _) IrEffectUnknown]
    [(IrInstrAlloc _ _) IrEffectMemoryWrite]
    [(IrInstrStorePtr _ _ _) IrEffectMemoryWrite]
    [(IrInstrCopyBytes _ _ _) IrEffectMemoryWrite]
    [(IrInstrStore _ _ _) IrEffectMemoryWrite]
    [(IrInstrVectorStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorStorePayload _ _ _ _ _) IrEffectMemoryWrite])]
    [(IrInstrPredicatedStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedStorePayload _ _ _ _ _ _)
          IrEffectMemoryWrite])]
    [(IrInstrCall _ name _ _) (compiler-ir-direct-call-effect name)]
    [(IrInstrCallIndirect _ _ _ _) IrEffectUnknown]
    [(IrInstrCallIndirectC _ _ _ _) IrEffectUnknown]
    [(IrInstrCallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload _ _ _ _) IrEffectUnknown])]
    [(IrInstrCallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload _ _ _ _)
          IrEffectUnknown])]
    [(IrInstrBoundsCheck _ _ _) IrEffectControlFlow]
    [(IrInstrTailCall _ _ _) IrEffectControlFlow]
    [(IrInstrJump _) IrEffectControlFlow]
    [(IrInstrBranch _ _ _) IrEffectControlFlow]
    [(IrInstrReturn _) IrEffectControlFlow]
    [(IrInstrPack _ _ _) IrEffectPure]
    [(IrInstrWord _ _ _ _) IrEffectPure]
    [(IrInstrTailCallIndirect _ _ _) IrEffectControlFlow]
    [(IrInstrSwitch _ _ _ _) IrEffectControlFlow]))

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
    (Box CompilerSourceSpansEntryList)))

(defenum CompilerSourceSpans
  (CompilerSourceSpans
    CompilerSourceSpansEntryList
    CompilerSourceSpansEntryList
    i64))

(defenum CompilerMaybeSourceSpan
  (CompilerNoSourceSpan)
  (CompilerSomeSourceSpan AstSourceSpan))

(define (compiler-source-spans-empty) : CompilerSourceSpans
  (CompilerSourceSpans
    (CompilerSourceSpansEntryNil)
    (CompilerSourceSpansEntryNil)
    0))

(define (compiler-source-spans-clear-instrs [spans : CompilerSourceSpans]) : CompilerSourceSpans
  (match spans
    [(CompilerSourceSpans entries _ _)
      (CompilerSourceSpans entries (CompilerSourceSpansEntryNil) 0)]))

(define (compiler-source-spans-entry-list-append
  [entries : CompilerSourceSpansEntryList]
  [entry : CompilerSourceSpansEntry]) : CompilerSourceSpansEntryList
  (match entries
    [(CompilerSourceSpansEntryNil)
      (CompilerSourceSpansEntryCons entry (box (CompilerSourceSpansEntryNil)))]
    [(CompilerSourceSpansEntryCons head rest)
      (let
        [rest : CompilerSourceSpansEntryList (box-get rest)]
        (CompilerSourceSpansEntryCons
          head
          (box (compiler-source-spans-entry-list-append rest entry))))]))

;; Record `name -> span`. Function names are unique in lowered programs, so a
;; prepend keeps diagnostics equivalent while avoiding O(n^2) provenance builds.
(define (compiler-source-spans-insert
  [spans : CompilerSourceSpans]
  [name : String]
  [span : AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(CompilerSourceSpans entries instr-entries instr-count)
      (CompilerSourceSpans
        (CompilerSourceSpansEntryCons
          (CompilerSourceSpansEntry name span)
          (box entries))
        instr-entries
        instr-count)]))

(define (compiler-source-spans-entry-list-lookup
  [entries : CompilerSourceSpansEntryList]
  [name : String]) : CompilerMaybeSourceSpan
  (match entries
    [(CompilerSourceSpansEntryNil) (CompilerNoSourceSpan)]
    [(CompilerSourceSpansEntryCons entry rest)
      (let
        [rest : CompilerSourceSpansEntryList (box-get rest)]
        (match entry
          [(CompilerSourceSpansEntry entry-name span)
            (if (string-eq entry-name name)
              (CompilerSomeSourceSpan span)
              (compiler-source-spans-entry-list-lookup rest name))]))]))

(define (compiler-source-spans-lookup
  [spans : CompilerSourceSpans]
  [name : String]) : CompilerMaybeSourceSpan
  (match spans
    [(CompilerSourceSpans entries _ _)
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
    [(CompilerSourceSpans entries instr-entries instr-count)
      (CompilerSourceSpans
        entries
        (CompilerSourceSpansEntryCons
          (CompilerSourceSpansEntry key span)
          (box instr-entries))
        (+ instr-count 1))]))

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
    [(IrInstrBitcast dst _ _ _)
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
    [(IrInstrVectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload dst _ _ _ _ _)
          (compiler-source-spans-insert-instr-entry
            spans
            (compiler-source-spans-value-key function dst)
            span)])]
    [(IrInstrVectorReduce dst _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrVectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload dst _ _ _ _ _)
          (compiler-source-spans-insert-instr-entry
            spans
            (compiler-source-spans-value-key function dst)
            span)])]
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
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload dst _ _ _ _ _)
          (compiler-source-spans-insert-instr-entry
            spans
            (compiler-source-spans-value-key function dst)
            span)])]
    [(IrInstrVectorLoad dst _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload dst _ _ _ _ _)
          (compiler-source-spans-insert-instr-entry
            spans
            (compiler-source-spans-value-key function dst)
            span)])]
    [(IrInstrTailMask dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrEntryArgc dst)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrEntryArgv dst)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrEntryEnvp dst)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrCpuId dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrXgetbv dst _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrSyscall dst _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrCall dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrCallIndirect dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrCallIndirectC dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrCallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload _ _ _ _) spans])]
    [(IrInstrCallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload _ _ _ _) spans])]
    [(IrInstrPack dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrWord dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    ;; Tail-indirect is control flow and does not define a destination value.
    [(IrInstrTailCallIndirect _ _ _) spans]
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
    [(CompilerSourceSpans _ instr-entries _)
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
        [(IrInstrBitcast dst _ _ _)
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
        [(IrInstrVectorBinOp payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrVectorBinOpPayload dst _ _ _ _ _)
              (compiler-source-spans-entry-list-lookup
                instr-entries
                (compiler-source-spans-value-key function dst))])]
        [(IrInstrVectorReduce dst _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrVectorCompare payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrVectorComparePayload dst _ _ _ _ _)
              (compiler-source-spans-entry-list-lookup
                instr-entries
                (compiler-source-spans-value-key function dst))])]
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
        [(IrInstrSelect payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrSelectPayload dst _ _ _ _ _)
              (compiler-source-spans-entry-list-lookup
                instr-entries
                (compiler-source-spans-value-key function dst))])]
        [(IrInstrVectorLoad dst _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrPredicatedLoad payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrPredicatedLoadPayload dst _ _ _ _ _)
              (compiler-source-spans-entry-list-lookup
                instr-entries
                (compiler-source-spans-value-key function dst))])]
        [(IrInstrTailMask dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrEntryArgc dst)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrEntryArgv dst)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrEntryEnvp dst)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrCpuId dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrXgetbv dst _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrSyscall dst _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrCall dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrCallIndirect dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrCallIndirectC dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrCallCAbiStoreResult payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrCallCAbiStoreResultPayload _ _ _ _)
              (CompilerNoSourceSpan)])]
        [(IrInstrCallIndirectCAbiStoreResult payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrCallIndirectCAbiStoreResultPayload _ _ _ _)
              (CompilerNoSourceSpan)])]
        [(IrInstrPack dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrWord dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        ;; Tail-indirect is control flow and does not define a destination value.
        [(IrInstrTailCallIndirect _ _ _) (CompilerNoSourceSpan)]
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
      (let
        [rest : CompilerSourceSpansEntryList (box-get rest)]
        (+ 1 (compiler-source-spans-entry-list-count rest)))]))

(define (compiler-source-spans-count [spans : CompilerSourceSpans]) : i64
  (match spans
    [(CompilerSourceSpans entries _ _)
      (compiler-source-spans-entry-list-count entries)]))

(define (compiler-source-spans-instr-count [spans : CompilerSourceSpans]) : i64
  (match spans
    [(CompilerSourceSpans _ _ instr-count) instr-count]))

(define (compiler-source-spans-instr-count-at-least?
  [spans : CompilerSourceSpans]
  [minimum : i64]) : bool
  (match spans
    [(CompilerSourceSpans _ _ instr-count) (>= instr-count minimum)]))

(defenum CompilerIrSummary
  (CompilerIrSummary i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64))

(define (compiler-ir-summary-globals [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary globals _ _ _ _ _ _ _ _ _ _) globals]))

(define (compiler-ir-summary-functions [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ functions _ _ _ _ _ _ _ _ _) functions]))

(define (compiler-ir-summary-externs [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ externs _ _ _ _ _ _ _ _) externs]))

(define (compiler-ir-summary-blocks [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ blocks _ _ _ _ _ _ _) blocks]))

(define (compiler-ir-summary-instructions [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ _ instructions _ _ _ _ _ _) instructions]))

(define (compiler-ir-summary-vars [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ _ _ vars _ _ _ _ _) vars]))

(define (compiler-ir-summary-empty-blocks [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ _ _ _ empty-blocks _ _ _ _) empty-blocks]))

(define (compiler-ir-summary-max-instructions-function
  [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ _ _ _ _ max-instructions-function _ _ _)
      max-instructions-function]))

(define (compiler-ir-summary-max-instructions-block
  [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ _ _ _ _ _ max-instructions-block _ _)
      max-instructions-block]))

(define (compiler-ir-summary-call-arg-entries [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ _ _ _ _ _ _ call-arg-entries _) call-arg-entries]))

(define (compiler-ir-summary-phi-input-entries [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary _ _ _ _ _ _ _ _ _ _ phi-input-entries)
      phi-input-entries]))

(define (compiler-ir-summary-score [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary
        globals
        functions
        externs
        blocks
        instructions
        vars
        _
        _
        _
        _
        _)
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
    [(IrGlobalCons _ rest) (+ 1 (compiler-ir-global-list-count (box-get rest)))]))

(define (compiler-ir-extern-list-count [externs : CompilerIrExternList]) : i64
  (match externs
    [(IrExternNil) 0]
    [(IrExternCons _ rest) (+ 1 (compiler-ir-extern-list-count (box-get rest)))]))

(define (compiler-ir-max-i64 [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

(define (compiler-ir-phi-input-list-count [inputs : CompilerIrPhiInputList]) : i64
  (match inputs
    [(IrPhiInputNil) 0]
    [(IrPhiInputCons _ _ rest)
      (+ 1 (compiler-ir-phi-input-list-count (box-get rest)))]))

(define (compiler-ir-instr-call-arg-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrCall _ _ args _) (compiler-ir-call-args-count args)]
    [(IrInstrCallIndirect _ _ args _) (compiler-ir-call-args-count args)]
    [(IrInstrCallIndirectC _ _ args _) (compiler-ir-call-args-count args)]
    [(IrInstrCallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload _ _ args _)
          (compiler-ir-call-args-count args)])]
    [(IrInstrCallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload _ _ args _)
          (compiler-ir-call-args-count args)])]
    [(IrInstrTailCall _ args _) (compiler-ir-call-args-count args)]
    [(IrInstrTailCallIndirect _ args _) (compiler-ir-call-args-count args)]
    [_ 0]))

(define (compiler-ir-instr-phi-input-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrPhi _ inputs _) (compiler-ir-phi-input-list-count inputs)]
    [_ 0]))

(define (compiler-ir-instr-list-call-arg-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (compiler-ir-instr-call-arg-count instr)
        (compiler-ir-instr-list-call-arg-count (box-get rest)))]))

(define (compiler-ir-instr-seq-call-arg-count-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (compiler-ir-instr-seq-call-arg-count-from
      slots
      (+ index 1)
      count
      (+ acc (compiler-ir-instr-call-arg-count (array-ref slots index))))))

(define (compiler-ir-instr-seq-call-arg-count [instrs : CompilerIrInstrSeq]) : i64
  (compiler-ir-instr-seq-call-arg-count-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (compiler-ir-instr-list-phi-input-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (compiler-ir-instr-phi-input-count instr)
        (compiler-ir-instr-list-phi-input-count (box-get rest)))]))

(define (compiler-ir-instr-seq-phi-input-count-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (compiler-ir-instr-seq-phi-input-count-from
      slots
      (+ index 1)
      count
      (+ acc (compiler-ir-instr-phi-input-count (array-ref slots index))))))

(define (compiler-ir-instr-seq-phi-input-count [instrs : CompilerIrInstrSeq]) : i64
  (compiler-ir-instr-seq-phi-input-count-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (compiler-ir-block-list-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons _ rest) (+ 1 (compiler-ir-block-list-count (box-get rest)))]
    [(IrBlockArray seq) (struct-get seq len)]))

(define (compiler-ir-block-list-empty-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (if (= (compiler-ir-instr-seq-count instrs) 0)
              1
              0)
            (compiler-ir-block-list-empty-count (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-ir-block-list-empty-count (compiler-ir-block-seq-to-list seq))]))

(define (compiler-ir-block-list-max-instruction-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-ir-max-i64
            (compiler-ir-instr-seq-count instrs)
            (compiler-ir-block-list-max-instruction-count (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-ir-block-list-max-instruction-count
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-ir-block-list-call-arg-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (compiler-ir-instr-seq-call-arg-count instrs)
            (compiler-ir-block-list-call-arg-count (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-ir-block-list-call-arg-count
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-ir-block-list-phi-input-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (compiler-ir-instr-seq-phi-input-count instrs)
            (compiler-ir-block-list-phi-input-count (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-ir-block-list-phi-input-count
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-ir-block-list-instruction-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (compiler-ir-instr-seq-count instrs)
            (compiler-ir-block-list-instruction-count (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-ir-block-list-instruction-count
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-ir-function-block-count [func : CompilerIrFunction]) : i64
  (match func
    [(IrFunction _ _ _ _ blocks) (compiler-ir-block-list-count blocks)]))

(define (compiler-ir-function-instruction-count [func : CompilerIrFunction]) : i64
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-ir-block-list-instruction-count blocks)]))

(define (compiler-ir-function-empty-block-count [func : CompilerIrFunction]) : i64
  (match func
    [(IrFunction _ _ _ _ blocks) (compiler-ir-block-list-empty-count blocks)]))

(define (compiler-ir-function-max-instruction-count [func : CompilerIrFunction]) : i64
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-ir-block-list-instruction-count blocks)]))

(define (compiler-ir-function-max-block-instruction-count
  [func : CompilerIrFunction]) : i64
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-ir-block-list-max-instruction-count blocks)]))

(define (compiler-ir-function-call-arg-count [func : CompilerIrFunction]) : i64
  (match func
    [(IrFunction _ _ _ _ blocks) (compiler-ir-block-list-call-arg-count blocks)]))

(define (compiler-ir-function-phi-input-count [func : CompilerIrFunction]) : i64
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-ir-block-list-phi-input-count blocks)]))

(define (compiler-ir-function-var-count [func : CompilerIrFunction]) : i64
  (match func
    [(IrFunction _ _ _ vars _) vars]))

(define (compiler-ir-function-seq-block-count
  [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (Array CompilerIrFunction) (struct-get functions slots)]
    [count : i64 (struct-get functions len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (compiler-ir-function-block-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (compiler-ir-function-seq-instruction-count
  [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (Array CompilerIrFunction) (struct-get functions slots)]
    [count : i64 (struct-get functions len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (compiler-ir-function-instruction-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (compiler-ir-function-seq-empty-block-count
  [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (Array CompilerIrFunction) (struct-get functions slots)]
    [count : i64 (struct-get functions len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (compiler-ir-function-empty-block-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (compiler-ir-function-seq-max-instruction-count
  [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (Array CompilerIrFunction) (struct-get functions slots)]
    [count : i64 (struct-get functions len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (compiler-ir-max-i64
              acc
              (compiler-ir-function-max-instruction-count
                (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (compiler-ir-function-seq-max-block-instruction-count
  [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (Array CompilerIrFunction) (struct-get functions slots)]
    [count : i64 (struct-get functions len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (compiler-ir-max-i64
              acc
              (compiler-ir-function-max-block-instruction-count
                (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (compiler-ir-function-seq-call-arg-count
  [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (Array CompilerIrFunction) (struct-get functions slots)]
    [count : i64 (struct-get functions len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (compiler-ir-function-call-arg-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (compiler-ir-function-seq-phi-input-count
  [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (Array CompilerIrFunction) (struct-get functions slots)]
    [count : i64 (struct-get functions len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (compiler-ir-function-phi-input-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (compiler-ir-function-seq-var-count [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (Array CompilerIrFunction) (struct-get functions slots)]
    [count : i64 (struct-get functions len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (compiler-ir-function-var-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (compiler-ir-function-list-count [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons _ rest)
      (+ 1 (compiler-ir-function-list-count (box-get rest)))]
    [(IrFunctionArray seq) (compiler-ir-function-seq-count seq)]))

(define (compiler-ir-function-list-block-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (+
        (compiler-ir-function-block-count func)
        (compiler-ir-function-list-block-count (box-get rest)))]
    [(IrFunctionArray seq) (compiler-ir-function-seq-block-count seq)]))

(define (compiler-ir-function-list-instruction-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (+
        (compiler-ir-function-instruction-count func)
        (compiler-ir-function-list-instruction-count (box-get rest)))]
    [(IrFunctionArray seq) (compiler-ir-function-seq-instruction-count seq)]))

(define (compiler-ir-function-list-empty-block-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (+
        (compiler-ir-function-empty-block-count func)
        (compiler-ir-function-list-empty-block-count (box-get rest)))]
    [(IrFunctionArray seq) (compiler-ir-function-seq-empty-block-count seq)]))

(define (compiler-ir-function-list-max-instruction-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (compiler-ir-max-i64
        (compiler-ir-function-max-instruction-count func)
        (compiler-ir-function-list-max-instruction-count (box-get rest)))]
    [(IrFunctionArray seq) (compiler-ir-function-seq-max-instruction-count seq)]))

(define (compiler-ir-function-list-max-block-instruction-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (compiler-ir-max-i64
        (compiler-ir-function-max-block-instruction-count func)
        (compiler-ir-function-list-max-block-instruction-count (box-get rest)))]
    [(IrFunctionArray seq)
      (compiler-ir-function-seq-max-block-instruction-count seq)]))

(define (compiler-ir-function-list-call-arg-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (+
        (compiler-ir-function-call-arg-count func)
        (compiler-ir-function-list-call-arg-count (box-get rest)))]
    [(IrFunctionArray seq) (compiler-ir-function-seq-call-arg-count seq)]))

(define (compiler-ir-function-list-phi-input-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (+
        (compiler-ir-function-phi-input-count func)
        (compiler-ir-function-list-phi-input-count (box-get rest)))]
    [(IrFunctionArray seq) (compiler-ir-function-seq-phi-input-count seq)]))

(define (compiler-ir-function-list-var-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (+
        (compiler-ir-function-var-count func)
        (compiler-ir-function-list-var-count (box-get rest)))]
    [(IrFunctionArray seq) (compiler-ir-function-seq-var-count seq)]))

(define (compiler-ir-program-summary [program : CompilerIrProgram]) : CompilerIrSummary
  (match program
    [(IrProgram globals functions externs)
      (CompilerIrSummary
        (compiler-ir-global-list-count globals)
        (compiler-ir-function-list-count functions)
        (compiler-ir-extern-list-count externs)
        (compiler-ir-function-list-block-count functions)
        (compiler-ir-function-list-instruction-count functions)
        (compiler-ir-function-list-var-count functions)
        (compiler-ir-function-list-empty-block-count functions)
        (compiler-ir-function-list-max-instruction-count functions)
        (compiler-ir-function-list-max-block-instruction-count functions)
        (compiler-ir-function-list-call-arg-count functions)
        (compiler-ir-function-list-phi-input-count functions))]))

(define (compiler-ir-type-list-name [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) ""]
    [(AstTypeCons head tail)
      (let
        [head : AstType (ty-node-get head)]
        [tail : AstTypeList (box-get tail)]
        (str-cat
          " "
          (compiler-ir-type-name head)
          (compiler-ir-type-list-name tail)))]))

(define (compiler-ir-type-name [ty : AstType]) : String
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
    [(AstTyStr) "str"]
    [(AstTyBytes) "bytes"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyFunc args ret)
      (str-cat
        "(->"
        (compiler-ir-type-list-name (box-get args))
        " "
        (compiler-ir-type-name (ty-node-get ret))
        ")")]
    [(AstTyTuple elems)
      (str-cat "(Tuple" (compiler-ir-type-list-name (box-get elems)) ")")]
    [(AstTyArray elem count)
      (str-cat
        "(Array "
        (compiler-ir-type-name (ty-node-get elem))
        " "
        (int->string count)
        ")")]
    [(AstTyDynArray elem)
      (str-cat "(Array " (compiler-ir-type-name (ty-node-get elem)) ")")]
    [(AstTyBox elem)
      (str-cat "(Box " (compiler-ir-type-name (ty-node-get elem)) ")")]
    [(AstTyRegion region inner)
      (str-cat
        "(in "
        region
        " "
        (compiler-ir-type-name (ty-node-get inner))
        ")")]
    [(AstTyRef region inner)
      (str-cat "(& " region " " (compiler-ir-type-name (ty-node-get inner)) ")")]
    [(AstTyMutRef region inner)
      (str-cat
        "(&mut "
        region
        " "
        (compiler-ir-type-name (ty-node-get inner))
        ")")]
    [(AstTyEnum name) (intern-str name)]
    [(AstTyEnumArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstTyStruct name) (intern-str name)]
    [(AstTyStructArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstTyVar name) (str-cat "'" (intern-str name) "'")]
    [(AstTyVarArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstTyPtr elem)
      (str-cat "(Ptr " (compiler-ir-type-name (ty-node-get elem)) ")")]
    [(AstTyMutPtr elem)
      (str-cat "(MutPtr " (compiler-ir-type-name (ty-node-get elem)) ")")]))

(define (compiler-ir-vector-type-name [elem : AstType] [lanes : i64]) : String
  (str-cat "(Vector " (compiler-ir-type-name elem) " " (int->string lanes) ")"))

(define (compiler-ir-mask-type-name [lanes : i64]) : String
  (str-cat "(Mask " (int->string lanes) ")"))

(define (compiler-ir-value-describe [value : CompilerIrValue]) : String
  (match value
    [(IrValueVar id) (str-cat "%" (int->string id) "")]
    [(IrValueGlobal name) (str-cat "@" name "")]
    [(IrValueGlobalAddr name) (str-cat "&@" name "")]
    [(IrValueFunction name) (str-cat "fn@" name "")]
    [(IrValueI64 n) (int->string n)]
    [(IrValueF64 n) (str-cat "float-bits:" (compiler-ir-u64-payload-render n))]
    [(IrValueBool b)
      (if b
        "true"
        "false")]
    [(IrValueChar c) (int->string (cast c : i64))]
    [(IrValueString s) s]
    [(IrValueBytes s) (str-cat "<bytes:" (int->string (string-length s)) ">")]
    [(IrValueUnit) "unit"]))

(define (compiler-ir-value-list-describe [values : CompilerIrValueList]) : String
  (match values
    [(IrValueNil) ""]
    [(IrValueCons head tail)
      (match (box-get tail)
        [(IrValueNil) (compiler-ir-value-describe head)]
        [_
          (str-cat
            (compiler-ir-value-describe head)
            ", "
            (compiler-ir-value-list-describe (box-get tail)))])]))

(define (compiler-ir-call-args-array-describe
  [values : (Array CompilerIrValue)]
  [index : i64]) : String
  (if (>= index (array-length values))
    ""
    (string-append
      (compiler-ir-value-describe (array-ref values index))
      (if (= (+ index 1) (array-length values))
        ""
        (string-append
          ", "
          (compiler-ir-call-args-array-describe values (+ index 1)))))))

(define (compiler-ir-call-args-describe [args : CompilerIrCallArgs]) : String
  (match args
    [(IrCallArgsNil) ""]
    [(IrCallArgsOne a) (compiler-ir-value-describe a)]
    [(IrCallArgsTwo a b)
      (str-cat
        (compiler-ir-value-describe a)
        ", "
        (compiler-ir-value-describe b))]
    [(IrCallArgsArray values) (compiler-ir-call-args-array-describe values 0)]))

(define (compiler-ir-binop-name [op : CompilerIrBinOp]) : String
  (match op
    [(IrBinAdd) "add"]
    [(IrBinSub) "sub"]
    [(IrBinMul) "mul"]
    [(IrBinDiv) "div"]
    [(IrBinMod) "mod"]
    [(IrBinSafeDiv) "safe_div"]
    [(IrBinSafeMod) "safe_mod"]
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

(define (compiler-ir-mask-binop-name [op : CompilerIrMaskBinOp]) : String
  (match op
    [(IrMaskAnd) "mask_and"]
    [(IrMaskOr) "mask_or"]))

(define (compiler-ir-vector-reduce-op-name [op : CompilerIrVectorReduceOp]) : String
  (match op
    [(IrVectorReduceSum) "sum"]
    [(IrVectorReduceMin) "min"]
    [(IrVectorReduceMax) "max"]))

(define (compiler-ir-mask-reduce-op-name [op : CompilerIrMaskReduceOp]) : String
  (match op
    [(IrMaskReduceAll) "all"]
    [(IrMaskReduceAny) "any"]))

(define (compiler-ir-lane-type-name [lanes : i64] [elem : AstType]) : String
  (str-cat (int->string lanes) " x " (compiler-ir-type-name elem)))

(define (compiler-ir-vector-suffix [lanes : i64] [elem : AstType]) : String
  (str-cat " : " (compiler-ir-lane-type-name lanes elem) ""))

(define (compiler-ir-instr-describe [instr : CompilerIrInstr]) : String
  (match instr
    [(IrInstrLaneId dst lanes ty)
      (str-cat
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = lane_id "
        (compiler-ir-lane-type-name lanes ty)
        "")]
    [(IrInstrSplat dst value lanes ty)
      (str-cat
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = splat "
        (compiler-ir-value-describe value)
        (compiler-ir-vector-suffix lanes ty)
        "")]
    [(IrInstrVectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload dst op lhs rhs lanes elem-ty)
          (str-cat
            "  "
            (compiler-ir-value-describe (IrValueVar dst))
            " = vector_"
            (compiler-ir-binop-name op)
            " "
            (compiler-ir-value-describe lhs)
            ", "
            (compiler-ir-value-describe rhs)
            (compiler-ir-vector-suffix lanes elem-ty))])]
    [(IrInstrVectorReduce dst op src lanes elem-ty)
      (str-cat
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = vector_reduce_"
        (compiler-ir-vector-reduce-op-name op)
        " "
        (compiler-ir-value-describe src)
        (compiler-ir-vector-suffix lanes elem-ty))]
    [(IrInstrVectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload dst op lhs rhs lanes elem-ty)
          (str-cat
            "  "
            (compiler-ir-value-describe (IrValueVar dst))
            " = vector_cmp_"
            (compiler-ir-binop-name op)
            " "
            (compiler-ir-value-describe lhs)
            ", "
            (compiler-ir-value-describe rhs)
            (compiler-ir-vector-suffix lanes elem-ty))])]
    [(IrInstrMaskBinOp dst op lhs rhs lanes)
      (str-cat
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = "
        (compiler-ir-mask-binop-name op)
        " "
        (compiler-ir-value-describe lhs)
        ", "
        (compiler-ir-value-describe rhs)
        " : "
        (int->string lanes))]
    [(IrInstrMaskNot dst src lanes)
      (str-cat
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = mask_not "
        (compiler-ir-value-describe src)
        " : "
        (int->string lanes))]
    [(IrInstrMaskReduce dst op src lanes)
      (str-cat
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = mask_reduce_"
        (compiler-ir-mask-reduce-op-name op)
        " "
        (compiler-ir-value-describe src)
        " : "
        (int->string lanes))]
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload dst mask on-true on-false lanes ty)
          (str-cat
            "  "
            (compiler-ir-value-describe (IrValueVar dst))
            " = select "
            (compiler-ir-value-describe mask)
            ", "
            (compiler-ir-value-describe on-true)
            ", "
            (compiler-ir-value-describe on-false)
            (compiler-ir-vector-suffix lanes ty))])]
    [(IrInstrVectorLoad dst base index lanes elem-ty)
      (str-cat
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = vector_load "
        (compiler-ir-value-describe base)
        ", "
        (compiler-ir-value-describe index)
        (compiler-ir-vector-suffix lanes elem-ty))]
    [(IrInstrVectorStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorStorePayload base index value lanes elem-ty)
          (str-cat
            "  vector_store "
            (compiler-ir-value-describe base)
            ", "
            (compiler-ir-value-describe index)
            ", "
            (compiler-ir-value-describe value)
            (compiler-ir-vector-suffix lanes elem-ty))])]
    [(IrInstrPredicatedStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedStorePayload
            base
            index
            value
            mask
            lanes
            elem-ty)
          (str-cat
            "  predicated_store "
            (compiler-ir-value-describe base)
            ", "
            (compiler-ir-value-describe index)
            ", "
            (compiler-ir-value-describe value)
            ", "
            (compiler-ir-value-describe mask)
            (compiler-ir-vector-suffix lanes elem-ty))])]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload
            dst
            base
            index
            mask
            lanes
            elem-ty)
          (str-cat
            "  "
            (compiler-ir-value-describe (IrValueVar dst))
            " = predicated_load "
            (compiler-ir-value-describe base)
            ", "
            (compiler-ir-value-describe index)
            ", "
            (compiler-ir-value-describe mask)
            (compiler-ir-vector-suffix lanes elem-ty))])]
    [(IrInstrTailMask dst index len lanes)
      (str-cat
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = tail_mask "
        (compiler-ir-value-describe index)
        ", "
        (compiler-ir-value-describe len)
        " : "
        (int->string lanes))]
    [(IrInstrSwitch index base cases default-label)
      (str-cat
        "  switch "
        (compiler-ir-value-describe index)
        " base "
        (int->string base)
        " ["
        (compiler-ir-switch-case-list-render cases)
        "] default "
        default-label)]
    [_ "non-vector-mask-instr"]))

(define (compiler-ir-value-var-eq? [value : CompilerIrValue] [want : i64]) : bool
  (match value
    [(IrValueVar id) (= id want)]
    [_ false]))

(define (compiler-ir-effect-is?
  [instr : CompilerIrInstr]
  [effect : CompilerIrEffect]) : bool
  (compiler-ir-effect-eq? (compiler-ir-instr-effect instr) effect))

(define (compiler-ir-instruction-effects-ok?) : bool
  (and
    (compiler-ir-effect-is?
      (IrInstrMov 0 (IrValueI64 1) (AstTyI64))
      IrEffectPure)
    (compiler-ir-effect-is? (IrInstrAddrOf 1 0) IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyI64))
      IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrCast 3 (IrValueVar 2) (AstTyI64) (AstTyI32))
      IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrBinOp 4 (IrBinAdd) (IrValueVar 2) (IrValueI64 1) (AstTyI64))
      IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrUnOp 5 (IrUnNeg) (IrValueVar 4) (AstTyI64))
      IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrPhi
        6
        (compiler-ir-phi-input-cons (IrValueI64 1) "entry" (IrPhiInputNil))
        (AstTyI64))
      IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrLoad 7 (IrValueVar 1) (AstTyI64))
      IrEffectMemoryRead)
    (compiler-ir-effect-is? (IrInstrAlloc 8 (AstTyI64)) IrEffectMemoryWrite)
    (compiler-ir-effect-is?
      (IrInstrStorePtr (IrValueVar 1) (IrValueI64 2) (AstTyI64))
      IrEffectMemoryWrite)
    (compiler-ir-effect-is?
      (IrInstrCopyBytes (IrValueVar 1) (IrValueVar 2) 16)
      IrEffectMemoryWrite)
    (compiler-ir-effect-is?
      (IrInstrStore "global" (IrValueI64 3) (AstTyI64))
      IrEffectMemoryWrite)
    (compiler-ir-effect-is?
      (IrInstrCall 9 "tl_region_mark" (IrCallArgsNil) (AstTyI64))
      IrEffectMemoryRead)
    (compiler-ir-effect-is?
      (IrInstrCpuId 10 (IrValueI64 1) (IrValueI64 0) 0)
      IrEffectCpuProbe)
    (compiler-ir-effect-is? (IrInstrXgetbv 11 (IrValueI64 0)) IrEffectCpuProbe)
    (compiler-ir-effect-is?
      (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok")
      IrEffectControlFlow)
    (compiler-ir-effect-is?
      (IrInstrTailCall
        "fact_loop"
        (IrCallArgsTwo (IrValueVar 3) (IrValueI64 1))
        (AstTyI64))
      IrEffectControlFlow)
    (compiler-ir-effect-is? (IrInstrJump "done") IrEffectControlFlow)
    (compiler-ir-effect-is?
      (IrInstrBranch (IrValueBool true) "then" "else")
      IrEffectControlFlow)
    (compiler-ir-effect-is?
      (IrInstrSwitch
        (IrValueVar 0)
        1
        (compiler-ir-switch-case-cons
          1
          "one"
          (compiler-ir-switch-case-cons 2 "two" IrSwitchCaseNil))
        "default")
      IrEffectControlFlow)
    (compiler-ir-effect-is?
      (IrInstrReturn (IrSomeValue (IrValueI64 0)))
      IrEffectControlFlow)))

(define (compiler-ir-vector-mask-effects-ok?) : bool
  (and
    (compiler-ir-effect-is? (IrInstrLaneId 20 4 (AstTyI64)) IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrSplat 21 (IrValueVar 0) 4 (AstTyI64))
      IrEffectPure)
    (compiler-ir-effect-is?
      (ir-instr-vector-bin-op
        22
        (IrBinAdd)
        (IrValueVar 20)
        (IrValueVar 21)
        4
        (AstTyI64))
      IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrVectorReduce 23 (IrVectorReduceSum) (IrValueVar 22) 4 (AstTyI64))
      IrEffectPure)
    (compiler-ir-effect-is?
      (ir-instr-vector-compare
        24
        (IrBinLt)
        (IrValueVar 20)
        (IrValueVar 21)
        4
        (AstTyI64))
      IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrMaskBinOp 25 (IrMaskAnd) (IrValueVar 24) (IrValueVar 24) 4)
      IrEffectPure)
    (compiler-ir-effect-is? (IrInstrMaskNot 26 (IrValueVar 25) 4) IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrMaskReduce 27 (IrMaskReduceAny) (IrValueVar 26) 4)
      IrEffectPure)
    (compiler-ir-effect-is?
      (ir-instr-select
        28
        (IrValueVar 24)
        (IrValueVar 20)
        (IrValueVar 21)
        4
        (AstTyI64))
      IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrTailMask 29 (IrValueVar 0) (IrValueVar 1) 4)
      IrEffectPure)
    (compiler-ir-effect-is?
      (IrInstrVectorLoad 30 (IrValueVar 2) (IrValueVar 0) 4 (AstTyI64))
      IrEffectMemoryRead)
    (compiler-ir-effect-is?
      (ir-instr-predicated-load
        31
        (IrValueVar 2)
        (IrValueVar 0)
        (IrValueVar 29)
        4
        (AstTyI64))
      IrEffectMemoryRead)
    (compiler-ir-effect-is?
      (ir-instr-vector-store
        (IrValueVar 2)
        (IrValueVar 0)
        (IrValueVar 22)
        4
        (AstTyI64))
      IrEffectMemoryWrite)
    (compiler-ir-effect-is?
      (ir-instr-predicated-store
        (IrValueVar 2)
        (IrValueVar 0)
        (IrValueVar 22)
        (IrValueVar 29)
        4
        (AstTyI64))
      IrEffectMemoryWrite)))

(define (compiler-ir-runtime-effects-ok?) : bool
  (and
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect "tl_region_mark")
      IrEffectMemoryRead)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect ".L_tl_stdin_eof")
      IrEffectMemoryRead)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect "tl_alloc")
      IrEffectMemoryWrite)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect ".L_tl_flush_stdout")
      IrEffectMemoryWrite)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect ".L_tl_abort")
      IrEffectControlFlow)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect "tl_shift_abort")
      IrEffectControlFlow)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect ".L_tl_arg_count")
      IrEffectUnknown)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect "user_or_extern_call")
      IrEffectUnknown)))

(define (compiler-ir-effect-predicates-ok?) : bool
  (and
    (not (compiler-ir-effect-has-side-effect? IrEffectPure))
    (not (compiler-ir-effect-has-side-effect? IrEffectMemoryRead))
    (compiler-ir-effect-has-side-effect? IrEffectCpuProbe)
    (compiler-ir-effect-has-side-effect? IrEffectMemoryWrite)
    (compiler-ir-effect-has-side-effect? IrEffectControlFlow)
    (compiler-ir-effect-has-side-effect? IrEffectUnknown)
    (not (compiler-ir-effect-invalidates-cse? IrEffectPure))
    (compiler-ir-effect-invalidates-cse? IrEffectMemoryRead)
    (compiler-ir-effect-invalidates-cse? IrEffectCpuProbe)
    (compiler-ir-effect-invalidates-cse? IrEffectMemoryWrite)
    (compiler-ir-effect-invalidates-cse? IrEffectControlFlow)
    (compiler-ir-effect-invalidates-cse? IrEffectUnknown)))

(define (compiler-ir-display-type-names-ok?) : bool
  (and
    (string-eq (compiler-ir-vector-type-name (AstTyI32) 8) "(Vector i32 8)")
    (string-eq (compiler-ir-mask-type-name 8) "(Mask 8)")))

(define (compiler-ir-display-op-names-ok?) : bool
  (and
    (string-eq (compiler-ir-vector-reduce-op-name IrVectorReduceSum) "sum")
    (string-eq (compiler-ir-vector-reduce-op-name IrVectorReduceMin) "min")
    (string-eq (compiler-ir-vector-reduce-op-name IrVectorReduceMax) "max")
    (string-eq (compiler-ir-mask-reduce-op-name IrMaskReduceAll) "all")
    (string-eq (compiler-ir-mask-reduce-op-name IrMaskReduceAny) "any")
    (string-eq (compiler-ir-mask-binop-name IrMaskAnd) "mask_and")
    (string-eq (compiler-ir-mask-binop-name IrMaskOr) "mask_or")))

(define (compiler-ir-display-instrs-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (string-eq
        (compiler-ir-instr-describe (IrInstrLaneId 0 4 (AstTyI64)))
        "  %0 = lane_id 4 x i64")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (IrInstrSplat 1 (IrValueI64 7) 4 (AstTyI64)))
        "  %1 = splat 7 : 4 x i64")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (ir-instr-vector-bin-op
            2
            (IrBinAdd)
            (IrValueVar 0)
            (IrValueVar 1)
            4
            (AstTyI64)))
        "  %2 = vector_add %0, %1 : 4 x i64")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (IrInstrVectorReduce
            8
            (IrVectorReduceSum)
            (IrValueVar 2)
            4
            (AstTyI64)))
        "  %8 = vector_reduce_sum %2 : 4 x i64")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (ir-instr-vector-compare
            3
            (IrBinLt)
            (IrValueVar 0)
            (IrValueVar 1)
            4
            (AstTyI64)))
        "  %3 = vector_cmp_lt %0, %1 : 4 x i64")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (IrInstrMaskBinOp 4 (IrMaskOr) (IrValueVar 3) (IrValueVar 3) 4))
        "  %4 = mask_or %3, %3 : 4")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe (IrInstrMaskNot 5 (IrValueVar 4) 4))
        "  %5 = mask_not %4 : 4")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (IrInstrMaskReduce 9 (IrMaskReduceAny) (IrValueVar 5) 4))
        "  %9 = mask_reduce_any %5 : 4")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (ir-instr-select
            6
            (IrValueVar 5)
            (IrValueVar 2)
            (IrValueVar 1)
            4
            (AstTyI64)))
        "  %6 = select %5, %2, %1 : 4 x i64")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (IrInstrVectorLoad 7 (IrValueVar 10) (IrValueVar 11) 4 (AstTyI64)))
        "  %7 = vector_load %10, %11 : 4 x i64")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (ir-instr-vector-store
            (IrValueVar 12)
            (IrValueVar 11)
            (IrValueVar 6)
            4
            (AstTyI64)))
        "  vector_store %12, %11, %6 : 4 x i64")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (ir-instr-predicated-store
            (IrValueVar 12)
            (IrValueVar 11)
            (IrValueVar 6)
            (IrValueVar 5)
            4
            (AstTyI64)))
        "  predicated_store %12, %11, %6, %5 : 4 x i64")
        unit
        (set! ok false))
      (if (string-eq
        (compiler-ir-instr-describe
          (ir-instr-predicated-load
            10
            (IrValueVar 12)
            (IrValueVar 11)
            (IrValueVar 5)
            4
            (AstTyI64)))
        "  %10 = predicated_load %12, %11, %5 : 4 x i64")
        unit
        (set! ok false))
      ok)))

(define (compiler-ir-display-tail-mask-ok?) : bool
  (let
    [instr : CompilerIrInstr
      (IrInstrTailMask 9 (IrValueVar 1) (IrValueVar 2) 8)]
    (and
      (string-eq
        (compiler-ir-instr-describe instr)
        "  %9 = tail_mask %1, %2 : 8")
      (compiler-ir-effect-is? instr IrEffectPure)
      (match instr
        [(IrInstrTailMask dst index len lanes)
          (and
            (= dst 9)
            (compiler-ir-value-var-eq? index 1)
            (compiler-ir-value-var-eq? len 2)
            (= lanes 8))]
        [_ false]))))

(define (compiler-ir-display-self-test-ok?) : bool
  (and
    (compiler-ir-display-type-names-ok?)
    (compiler-ir-display-op-names-ok?)
    (compiler-ir-display-instrs-ok?)
    (compiler-ir-display-tail-mask-ok?)))

(define (compiler-ir-tail-call-render-ok?) : bool
  (string-eq
    (compiler-ir-instr-render
      (IrInstrTailCall
        "fact_loop"
        (IrCallArgsTwo (IrValueVar 3) (IrValueI64 1))
        (AstTyI64)))
    "  tailcall fact_loop(%3, 1) : i64"))

(define (compiler-ir-switch-render-ok?) : bool
  (let
    [cases : CompilerIrSwitchCaseList
      (compiler-ir-switch-case-cons
        4
        "four"
        (compiler-ir-switch-case-cons 5 "five" IrSwitchCaseNil))]
    [instr : CompilerIrInstr (IrInstrSwitch (IrValueVar 9) 4 cases "other")]
    (and
      (string-eq
        (compiler-ir-instr-render instr)
        "  switch %9 base 4 [4:four, 5:five] default other")
      (string-eq
        (compiler-ir-instr-describe instr)
        "  switch %9 base 4 [4:four, 5:five] default other"))))

(define (compiler-ir-source-spans-boxed-list-ok?) : bool
  (let
    [span1 : AstSourceSpan (AstSourceSpan 1 2 1 3)]
    [span2 : AstSourceSpan (AstSourceSpan 4 5 4 8)]
    [entries : CompilerSourceSpansEntryList
      (compiler-source-spans-entry-list-append
        (compiler-source-spans-entry-list-append
          (CompilerSourceSpansEntryNil)
          (CompilerSourceSpansEntry "first" span1))
        (CompilerSourceSpansEntry "second" span2))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert
        (compiler-source-spans-insert (compiler-source-spans-empty) "one" span1)
        "two"
        span2)]
    (and
      (= (compiler-source-spans-entry-list-count entries) 2)
      (= (compiler-source-spans-count spans) 2)
      (match (compiler-source-spans-entry-list-lookup entries "second")
        [(CompilerSomeSourceSpan found)
          (and
            (= (struct-get found start-line) 4)
            (= (struct-get found end-col) 8))]
        [(CompilerNoSourceSpan) false]))))

(define (compiler-ir-instr-list-first-mov-dst?
  [instrs : CompilerIrInstrList]
  [want : i64]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr _)
      (match instr
        [(IrInstrMov dst _ _) (= dst want)]
        [_ false])]))

(define (compiler-ir-block-list-first-label?
  [blocks : CompilerIrBlockList]
  [want : String]) : bool
  (match (compiler-ir-block-list-force-cons blocks)
    [(IrBlockCons block _)
      (match block
        [(IrBlock label _) (string-eq label want)])]
    [(IrBlockNil) false]
    [(IrBlockArray _) false]))

(define (compiler-ir-instr-seq-roundtrip-ok?) : bool
  (let
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrMov 2 (IrValueI64 20) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 2)))
            IrInstrNil)))]
    [seq : CompilerIrInstrSeq (compiler-ir-instr-seq-from-list instrs)]
    [roundtrip : CompilerIrInstrList (compiler-ir-instr-seq-to-list seq)]
    [block-list : CompilerIrBlockList
      (compiler-ir-block-cons (compiler-ir-block "entry" instrs) IrBlockNil)]
    [compact-blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact block-list)]
    (and
      (= (compiler-ir-instr-seq-count seq) 3)
      (not (compiler-ir-instr-seq-empty? seq))
      (match (compiler-ir-instr-seq-ref seq 2)
        [(IrInstrReturn _) true]
        [_ false])
      (= (compiler-ir-instr-list-count roundtrip) 3)
      (= (compiler-ir-block-list-instruction-count block-list) 3)
      (= (compiler-ir-block-list-count compact-blocks) 1)
      (compiler-ir-block-list-first-label? compact-blocks "entry")
      (compiler-ir-instr-list-first-mov-dst? roundtrip 1))))

(define (compiler-ir-effect-self-test) : i64
  (begin
    (unless (compiler-ir-instruction-effects-ok?) (return 1))
    (unless (compiler-ir-vector-mask-effects-ok?) (return 1))
    (unless (compiler-ir-runtime-effects-ok?) (return 1))
    (unless (compiler-ir-effect-predicates-ok?) (return 1))
    (unless (compiler-ir-display-self-test-ok?) (return 1))
    (unless (compiler-ir-tail-call-render-ok?) (return 1))
    (unless (compiler-ir-switch-render-ok?) (return 1))
    (unless (compiler-ir-source-spans-boxed-list-ok?) (return 1))
    (unless (compiler-ir-instr-seq-roundtrip-ok?) (return 1))
    42))