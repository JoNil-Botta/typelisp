;; compiler_ir_types.tl - Self-hosted compiler IR model (#446).
;;
;; This is the first selfhost IR shape for the real compiler pipeline. The data
;; model is intentionally close to the Rust IR: functions contain blocks, blocks
;; contain typed instructions, and instructions use explicit vars/values.
(import stdlib.string)
(import stdlib.array)
(import "compiler_ast_types.tl")
(import stdlib.str_cat_runtime as str_cat)

(defenum CompilerIrBinOp
  (Add)
  (Sub)
  (Mul)
  (Div)
  (Mod)
  (SafeDiv)
  (SafeMod)
  (Eq)
  (Ne)
  (Lt)
  (Le)
  (Gt)
  (Ge)
  (And)
  (Or)
  (BitAnd)
  (BitOr)
  (BitXor)
  (Shl)
  (Shr))

(defenum CompilerIrUnOp
  (Neg)
  (Not)
  (BitNot))

(defenum CompilerIrMaskBinOp
  (And)
  (Or))

(defenum CompilerIrVectorReduceOp
  (Sum)
  (Min)
  (Max))

(defenum CompilerIrMaskReduceOp
  (All)
  (Any))

(defenum CompilerIrValue
  (Var i64)
  (Global String)
  (GlobalAddr String)
  (Function String)
  (I64 i64)
  (F64 u64)
  (Bool bool)
  (Char char)
  (String String)
  (Bytes String)
  (Unit))

(defenum CompilerIrMaybeValue
  (No)
  (Some CompilerIrValue))

(defenum CompilerIrValueList
  (IrValueNil)
  (IrValueCons CompilerIrValue (Box CompilerIrValueList)))

(defenum CompilerIrCallArgs
  (Nil)
  (One CompilerIrValue)
  (Two CompilerIrValue CompilerIrValue)
  (Array (Array CompilerIrValue)))

(defenum CompilerIrSpmdBackend
  (IrSpmdBackendScalar)
  (IrSpmdBackendAvx2)
  (IrSpmdBackendAvx512))

(defenum CompilerIrSpmdValueClass
  (IrSpmdValueUniform)
  (IrSpmdValueVarying)
  (IrSpmdValueMask))

(defenum CompilerIrSpmdCallArg
  (IrSpmdCallArg CompilerIrSpmdValueClass CompilerIrValue AstType))

(defenum CompilerIrSpmdCallArgList
  (IrSpmdCallArgNil)
  (IrSpmdCallArgCons CompilerIrSpmdCallArg (Box CompilerIrSpmdCallArgList)))

(defenum CompilerIrSpmdCallResult
  (IrSpmdCallResultUnit)
  (IrSpmdCallResultValue i64 CompilerIrSpmdValueClass AstType))

(defenum CompilerIrCAbiReturnSlot
  (Slot AstType i64))

(defenum CompilerIrCAbiReturnSlotList
  (IrCAbiReturnSlotNil)
  (IrCAbiReturnSlotCons
    CompilerIrCAbiReturnSlot
    (Box CompilerIrCAbiReturnSlotList)))

(defenum CompilerIrPhiInputList
  (Nil)
  (Cons CompilerIrValue String (Box CompilerIrPhiInputList)))

(defenum CompilerIrSwitchCase
  (Case i64 String))

(defenum CompilerIrSwitchCaseList
  (IrSwitchCaseNil)
  (IrSwitchCaseCons CompilerIrSwitchCase (Box CompilerIrSwitchCaseList)))

(defenum CompilerIrInstrVectorBinOpPayload
  (Payload i64 CompilerIrBinOp CompilerIrValue CompilerIrValue i64 AstType))

(defenum CompilerIrInstrVectorComparePayload
  (Payload i64 CompilerIrBinOp CompilerIrValue CompilerIrValue i64 AstType))

(defenum CompilerIrInstrSelectPayload
  (Payload i64 CompilerIrValue CompilerIrValue CompilerIrValue i64 AstType))

(defenum CompilerIrInstrVectorStorePayload
  (Payload CompilerIrValue CompilerIrValue CompilerIrValue i64 AstType))

(defenum CompilerIrInstrPredicatedStorePayload
  (Payload
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    CompilerIrValue
    i64
    AstType))

(defenum CompilerIrInstrPredicatedLoadPayload
  (Payload i64 CompilerIrValue CompilerIrValue CompilerIrValue i64 AstType))

(defenum CompilerIrInstrCallCAbiStoreResultPayload
  (Payload
    CompilerIrValue
    String
    CompilerIrCallArgs
    CompilerIrCAbiReturnSlotList))

(defenum CompilerIrInstrCallIndirectCAbiStoreResultPayload
  (Payload
    CompilerIrValue
    CompilerIrValue
    CompilerIrCallArgs
    CompilerIrCAbiReturnSlotList))

(defenum CompilerIrInstrSpmdCallPayload
  (CompilerIrInstrSpmdCallPayload
    String
    CompilerIrSpmdBackend
    i64
    CompilerIrValue
    CompilerIrSpmdCallArgList
    CompilerIrSpmdCallResult))

(defenum CompilerIrInstr
  (Mov i64 CompilerIrValue AstType)
  (Alloc i64 AstType)
  (AddrOf i64 i64)
  (Gep i64 CompilerIrValue CompilerIrValue AstType)
  (Load i64 CompilerIrValue AstType)
  (StorePtr CompilerIrValue CompilerIrValue AstType)
  (CopyBytes CompilerIrValue CompilerIrValue i64)
  (BoundsCheck CompilerIrValue CompilerIrValue String)
  (Cast i64 CompilerIrValue AstType AstType)
  (Bitcast i64 CompilerIrValue AstType AstType)
  (BinOp i64 CompilerIrBinOp CompilerIrValue CompilerIrValue AstType)
  (UnOp i64 CompilerIrUnOp CompilerIrValue AstType)
  (LaneId i64 i64 AstType)
  (Splat i64 CompilerIrValue i64 AstType)
  (VectorBinOp (Box CompilerIrInstrVectorBinOpPayload))
  (VectorReduce i64 CompilerIrVectorReduceOp CompilerIrValue i64 AstType)
  (VectorCompare (Box CompilerIrInstrVectorComparePayload))
  (MaskBinOp i64 CompilerIrMaskBinOp CompilerIrValue CompilerIrValue i64)
  (MaskNot i64 CompilerIrValue i64)
  (MaskReduce i64 CompilerIrMaskReduceOp CompilerIrValue i64)
  (Select (Box CompilerIrInstrSelectPayload))
  (VectorLoad i64 CompilerIrValue CompilerIrValue i64 AstType)
  (VectorStore (Box CompilerIrInstrVectorStorePayload))
  (PredicatedStore (Box CompilerIrInstrPredicatedStorePayload))
  (PredicatedLoad (Box CompilerIrInstrPredicatedLoadPayload))
  (TailMask i64 CompilerIrValue CompilerIrValue i64)
  (EntryArgc i64)
  (EntryArgv i64)
  (EntryEnvp i64)
  (CpuId i64 CompilerIrValue CompilerIrValue i64)
  (Xgetbv i64 CompilerIrValue)
  ;; Raw Linux x86_64 syscall: dst var plus the operands (number then up to six
  ;; arguments) carried as call-args. Lowers to a `syscall` instruction.
  (Syscall i64 CompilerIrCallArgs)
  (Call i64 String CompilerIrCallArgs AstType)
  (CallIndirect i64 CompilerIrValue CompilerIrCallArgs AstType)
  (CallIndirectC i64 CompilerIrValue CompilerIrCallArgs AstType)
  ;; System V C aggregate returns can arrive in two ABI result registers. These
  ;; instructions emit the call and immediately store those result slots into the
  ;; provided aggregate buffer, preserving the classifier's slot offsets.
  (CallCAbiStoreResult (Box CompilerIrInstrCallCAbiStoreResultPayload))
  (CallIndirectCAbiStoreResult
    (Box CompilerIrInstrCallIndirectCAbiStoreResultPayload))
  (IrInstrSpmdCall (Box CompilerIrInstrSpmdCallPayload))
  (TailCall String CompilerIrCallArgs AstType)
  (Store String CompilerIrValue AstType)
  (Jump String)
  (Branch CompilerIrValue String String)
  (Return CompilerIrMaybeValue)
  (Phi i64 CompilerIrPhiInputList AstType)
  ;; #2386 multi-word register-resident aggregates: a small (<=16 B) inline
  ;; struct/enum whose fields are all word-class can live in N general-purpose
  ;; registers (N = ceil(size/8)) instead of a memory slot. CompilerIrInstr.Pack forms
  ;; such a group var `dst` (typed `ty`, the aggregate type) from its N word
  ;; values (low word first, e.g. word0 = enum tag); CompilerIrInstr.Word extracts word
  ;; `index` of a group value into a scalar `dst`. The register allocator gives a
  ;; group var N adjacent home registers (or an N*8-byte spill slot); the backend
  ;; lowers Pack/Word as register/slot word moves -- the value never round-trips
  ;; through memory.
  (Pack i64 CompilerIrValueList AstType)
  (Word i64 CompilerIrValue i64 AstType)
  (TailCallIndirect CompilerIrValue CompilerIrCallArgs AstType)
  (Switch CompilerIrValue i64 CompilerIrSwitchCaseList String))

(define (ir-instr-vector-bin-op
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (CompilerIrInstr.VectorBinOp
    (box (CompilerIrInstrVectorBinOpPayload.Payload dst op lhs rhs lanes ty))))

(define (ir-instr-vector-compare
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (CompilerIrInstr.VectorCompare
    (box (CompilerIrInstrVectorComparePayload.Payload dst op lhs rhs lanes ty))))

(define (ir-instr-select
  [dst : i64]
  [mask : CompilerIrValue]
  [on-true : CompilerIrValue]
  [on-false : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (CompilerIrInstr.Select
    (box
      (CompilerIrInstrSelectPayload.Payload dst mask on-true on-false lanes ty))))

(define (ir-instr-vector-store
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (CompilerIrInstr.VectorStore
    (box (CompilerIrInstrVectorStorePayload.Payload base index value lanes ty))))

(define (ir-instr-predicated-store
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (CompilerIrInstr.PredicatedStore
    (box
      (CompilerIrInstrPredicatedStorePayload.Payload
        base
        index
        value
        mask
        lanes
        ty))))

(define (ir-instr-predicated-load
  [dst : i64]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [ty : AstType]) : CompilerIrInstr
  (CompilerIrInstr.PredicatedLoad
    (box
      (CompilerIrInstrPredicatedLoadPayload.Payload
        dst
        base
        index
        mask
        lanes
        ty))))

(define (ir-instr-call-cabi-store-result
  [base : CompilerIrValue]
  [name : String]
  [args : CompilerIrCallArgs]
  [slots : CompilerIrCAbiReturnSlotList]) : CompilerIrInstr
  (CompilerIrInstr.CallCAbiStoreResult
    (box
      (CompilerIrInstrCallCAbiStoreResultPayload.Payload base name args slots))))

(define (ir-instr-call-indirect-cabi-store-result
  [base : CompilerIrValue]
  [callee : CompilerIrValue]
  [args : CompilerIrCallArgs]
  [slots : CompilerIrCAbiReturnSlotList]) : CompilerIrInstr
  (CompilerIrInstr.CallIndirectCAbiStoreResult
    (box
      (CompilerIrInstrCallIndirectCAbiStoreResultPayload.Payload
        base
        callee
        args
        slots))))

(define (ir-spmd-call-arg-cons
  [arg : CompilerIrSpmdCallArg]
  [rest : CompilerIrSpmdCallArgList]) : CompilerIrSpmdCallArgList
  (IrSpmdCallArgCons arg (box rest)))

(define (ir-instr-spmd-call
  [callee : String]
  [backend : CompilerIrSpmdBackend]
  [lanes : i64]
  [active-mask : CompilerIrValue]
  [args : CompilerIrSpmdCallArgList]
  [result : CompilerIrSpmdCallResult]) : CompilerIrInstr
  (IrInstrSpmdCall
    (box
      (CompilerIrInstrSpmdCallPayload
        callee
        backend
        lanes
        active-mask
        args
        result))))

(defenum CompilerIrInstrList
  (Nil)
  (Cons CompilerIrInstr (Box CompilerIrInstrList)))

(defstruct CompilerIrInstrSeq
  (slots (Array CompilerIrInstr))
  (len i64))

(defenum CompilerIrBlock
  (Block String CompilerIrInstrSeq))

(defstruct CompilerIrBlockSeq
  (slots (Array CompilerIrBlock))
  (len i64))

(defenum CompilerIrBlockList
  (Nil)
  (Cons CompilerIrBlock (Box CompilerIrBlockList))
  (Array CompilerIrBlockSeq))

(defenum CompilerIrParam
  (Param String AstType i64))

(defenum CompilerIrParamList
  (IrParamNil)
  (IrParamCons CompilerIrParam (Box CompilerIrParamList)))

(defenum CompilerIrFunction
  (Function String CompilerIrParamList AstType i64 CompilerIrBlockList))

(defstruct CompilerIrFunctionSeq
  (slots (Array CompilerIrFunction))
  (len i64))

(defenum CompilerIrFunctionList
  (Nil)
  (Cons CompilerIrFunction (Box CompilerIrFunctionList))
  (Array CompilerIrFunctionSeq))

(defenum CompilerIrGlobal
  (Global String AstType CompilerIrValue))

(defenum CompilerIrGlobalList
  (Nil)
  (Cons CompilerIrGlobal (Box CompilerIrGlobalList)))

(defenum CompilerIrExtern
  (Extern String AstType AstExternAbi String AstExternLinkInputList bool))

(defenum CompilerIrExternList
  (Nil)
  (Cons CompilerIrExtern (Box CompilerIrExternList)))

(defenum CompilerIrProgram
  (Program CompilerIrGlobalList CompilerIrFunctionList CompilerIrExternList))

(define (compiler-ir-value-cons
  [value : CompilerIrValue]
  [rest : CompilerIrValueList]) : CompilerIrValueList
  (IrValueCons value (box rest)))

(define (compiler-ir-phi-input-cons
  [value : CompilerIrValue]
  [label : String]
  [rest : CompilerIrPhiInputList]) : CompilerIrPhiInputList
  (CompilerIrPhiInputList.Cons value label (box rest)))

(define (compiler-ir-switch-case-cons
  [tag : i64]
  [label : String]
  [rest : CompilerIrSwitchCaseList]) : CompilerIrSwitchCaseList
  (IrSwitchCaseCons (CompilerIrSwitchCase.Case tag label) (box rest)))

(define (compiler-ir-instr-cons
  [instr : CompilerIrInstr]
  [rest : CompilerIrInstrList]) : CompilerIrInstrList
  (CompilerIrInstrList.Cons instr (box rest)))

(define (compiler-ir-instr-list-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons _ rest)
      (+ 1 (compiler-ir-instr-list-count (box-get rest)))]))

(define (compiler-ir-instr-list-fill-array
  [instrs : CompilerIrInstrList]
  [slots : (Array CompilerIrInstr)]
  [index : i64]) : unit
  (match instrs
    [(CompilerIrInstrList.Nil) unit]
    [(CompilerIrInstrList.Cons instr rest)
      (begin
        (array-set! slots index instr)
        (compiler-ir-instr-list-fill-array (box-get rest) slots (+ index 1)))]))

(define (compiler-ir-instr-seq-from-list [instrs : CompilerIrInstrList]) : CompilerIrInstrSeq
  (let
    [count : i64 (compiler-ir-instr-list-count instrs)]
    [slots : (Array CompilerIrInstr) (array.make-array CompilerIrInstr count)]
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
          (set!
            out
            (CompilerIrInstrList.Cons (array-ref slots cursor) (box out)))
          (set! cursor (- cursor 1))))
      out)))

(define (compiler-ir-instr-seq-to-list [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (compiler-ir-instr-seq-to-list-rev
    (struct-get instrs slots)
    (- (struct-get instrs len) 1)
    CompilerIrInstrList.Nil))

(define (compiler-ir-instr-seq-count [instrs : CompilerIrInstrSeq]) : i64
  (struct-get instrs len))

(define (compiler-ir-instr-seq-empty? [instrs : CompilerIrInstrSeq]) : bool
  (= (struct-get instrs len) 0))

;; #2357: MUST stay on the checked array-ref path. `CompilerIrInstr` is an inline-by-value enum
;; (#1867), so the raw `(ptr-read (ptr-offset (ptr-cast (array-data ...) :
;; (Ptr CompilerIrInstr)) index))` form mis-scales the element stride and reads
;; garbage; the array macro lowers with the correct element size.
(define (compiler-ir-instr-seq-ref [instrs : CompilerIrInstrSeq] [index : i64]) : CompilerIrInstr
  (array-ref (struct-get instrs slots) index))

(define (compiler-ir-instr-seq-set!
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [instr : CompilerIrInstr]) : unit
  (array-set! (struct-get instrs slots) index instr))

(define (compiler-ir-instr-seq-rewrite!
  [instrs : CompilerIrInstrSeq]
  [rewrite : (-> CompilerIrInstr CompilerIrInstr)]) : unit
  (let
    [index : i64 0]
    [count : i64 (struct-get instrs len)]
    (while (< index count)
      (begin
        (compiler-ir-instr-seq-set!
          instrs
          index
          (rewrite (compiler-ir-instr-seq-ref instrs index)))
        (set! index (+ index 1))))))

(define (compiler-ir-instr-seq-compact!
  [instrs : CompilerIrInstrSeq]
  [keep? : (-> CompilerIrInstr bool)]) : unit
  (let
    [read : i64 0]
    [write : i64 0]
    [count : i64 (struct-get instrs len)]
    (begin
      (while (< read count)
        (begin
          (if (keep? (compiler-ir-instr-seq-ref instrs read))
            (begin
              (if (not (= write read))
                (compiler-ir-instr-seq-set!
                  instrs
                  write
                  (compiler-ir-instr-seq-ref instrs read))
                unit)
              (set! write (+ write 1)))
            unit)
          (set! read (+ read 1))))
      (set! (struct-get instrs len) write))))

(define (compiler-ir-block [label : String] [instrs : CompilerIrInstrList]) : CompilerIrBlock
  (CompilerIrBlock.Block label (compiler-ir-instr-seq-from-list instrs)))

(define (compiler-ir-block-cons
  [block : CompilerIrBlock]
  [rest : CompilerIrBlockList]) : CompilerIrBlockList
  (CompilerIrBlockList.Cons block (box rest)))

(define (compiler-ir-block-list-count-cons [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons _ rest)
      (+ 1 (compiler-ir-block-list-count-cons (box-get rest)))]
    [(CompilerIrBlockList.Array seq) (struct-get seq len)]))

(define (compiler-ir-block-list-fill-array
  [blocks : CompilerIrBlockList]
  [slots : (Array CompilerIrBlock)]
  [index : i64]) : unit
  (match blocks
    [(CompilerIrBlockList.Nil) unit]
    [(CompilerIrBlockList.Cons block rest)
      (begin
        (array-set! slots index block)
        (compiler-ir-block-list-fill-array (box-get rest) slots (+ index 1)))]
    [(CompilerIrBlockList.Array seq)
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
    [slots : (Array CompilerIrBlock) (array.make-array CompilerIrBlock count)]
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
    CompilerIrBlockList.Nil))

(define (compiler-ir-block-seq-count [blocks : CompilerIrBlockSeq]) : i64
  (struct-get blocks len))

;; #2357: MUST stay on the checked array-ref path (see compiler-ir-instr-seq-ref above).
(define (compiler-ir-block-seq-ref [blocks : CompilerIrBlockSeq] [index : i64]) : CompilerIrBlock
  (array-ref (struct-get blocks slots) index))

(define (compiler-ir-block-list-force-cons [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(CompilerIrBlockList.Array seq) (compiler-ir-block-seq-to-list seq)]
    [_ blocks]))

(define (compiler-ir-block-list-compact [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(CompilerIrBlockList.Array _) blocks]
    [_ (CompilerIrBlockList.Array (compiler-ir-block-seq-from-list blocks))]))

(define (compiler-ir-function-block-list [func : CompilerIrFunction]) : CompilerIrBlockList
  (match func
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (compiler-ir-block-list-force-cons blocks)]))

(define (compiler-ir-function-compact-blocks [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(CompilerIrFunction.Function name params ret vars blocks)
      (CompilerIrFunction.Function
        name
        params
        ret
        vars
        (compiler-ir-block-list-compact blocks))]))

(define (compiler-ir-param-cons
  [param : CompilerIrParam]
  [rest : CompilerIrParamList]) : CompilerIrParamList
  (IrParamCons param (box rest)))

(define (compiler-ir-function-cons
  [func : CompilerIrFunction]
  [rest : CompilerIrFunctionList]) : CompilerIrFunctionList
  (CompilerIrFunctionList.Cons func (box rest)))

(define (compiler-ir-function-list-count-cons
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons _ rest)
      (+ 1 (compiler-ir-function-list-count-cons (box-get rest)))]
    [(CompilerIrFunctionList.Array seq) (struct-get seq len)]))

(define (compiler-ir-function-list-fill-array
  [functions : CompilerIrFunctionList]
  [slots : (Array CompilerIrFunction)]
  [index : i64]) : unit
  (match functions
    [(CompilerIrFunctionList.Nil) unit]
    [(CompilerIrFunctionList.Cons func rest)
      (begin
        (array-set! slots index func)
        (compiler-ir-function-list-fill-array (box-get rest) slots (+ index 1)))]
    [(CompilerIrFunctionList.Array seq)
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
    [slots : (Array CompilerIrFunction)
      (array.make-array CompilerIrFunction count)]
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
    CompilerIrFunctionList.Nil))

(define (compiler-ir-function-seq-count [functions : CompilerIrFunctionSeq]) : i64
  (struct-get functions len))

;; Keep the checked array-ref path; aggregate enum array elements need the array macro,
;; as with instruction and block sequences.
(define (compiler-ir-function-seq-ref
  [functions : CompilerIrFunctionSeq]
  [index : i64]) : CompilerIrFunction
  (array-ref (struct-get functions slots) index))

(define (compiler-ir-function-list-force-cons
  [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(CompilerIrFunctionList.Array seq) (compiler-ir-function-seq-to-list seq)]
    [_ functions]))

(define (compiler-ir-function-list-compact [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(CompilerIrFunctionList.Array _) functions]
    [_
      (CompilerIrFunctionList.Array
        (compiler-ir-function-seq-from-list functions))]))

(define (compiler-ir-global-cons
  [global : CompilerIrGlobal]
  [rest : CompilerIrGlobalList]) : CompilerIrGlobalList
  (CompilerIrGlobalList.Cons global (box rest)))

(define (compiler-ir-extern-cons
  [extern : CompilerIrExtern]
  [rest : CompilerIrExternList]) : CompilerIrExternList
  (CompilerIrExternList.Cons extern (box rest)))

(define (compiler-ir-extern-default [name : String] [ty : AstType]) : CompilerIrExtern
  (CompilerIrExtern.Extern
    name
    ty
    (AstExternAbi.C)
    name
    AstExternLinkInputList.Nil
    false))

(define (compiler-ir-clone-value [value : CompilerIrValue]) : CompilerIrValue
  (match value
    [(CompilerIrValue.Var id) (CompilerIrValue.Var id)]
    [(CompilerIrValue.Global name) (CompilerIrValue.Global (clone name))]
    [(CompilerIrValue.GlobalAddr name)
      (CompilerIrValue.GlobalAddr (clone name))]
    [(CompilerIrValue.Function name) (CompilerIrValue.Function (clone name))]
    [(CompilerIrValue.I64 n) (CompilerIrValue.I64 n)]
    [(CompilerIrValue.F64 n) (CompilerIrValue.F64 n)]
    [(CompilerIrValue.Bool b) (CompilerIrValue.Bool b)]
    [(CompilerIrValue.Char c) (CompilerIrValue.Char c)]
    [(CompilerIrValue.String s) (CompilerIrValue.String (clone s))]
    [(CompilerIrValue.Bytes s) (CompilerIrValue.Bytes (clone s))]
    [(CompilerIrValue.Unit) (CompilerIrValue.Unit)]))

(define (compiler-ir-clone-maybe-value [value : CompilerIrMaybeValue]) : CompilerIrMaybeValue
  (match value
    [(CompilerIrMaybeValue.No) (CompilerIrMaybeValue.No)]
    [(CompilerIrMaybeValue.Some inner)
      (CompilerIrMaybeValue.Some (compiler-ir-clone-value inner))]))

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
    [(CompilerIrCallArgs.Nil) (CompilerIrCallArgs.Nil)]
    [(CompilerIrCallArgs.One a)
      (CompilerIrCallArgs.One (compiler-ir-clone-value a))]
    [(CompilerIrCallArgs.Two a b)
      (CompilerIrCallArgs.Two
        (compiler-ir-clone-value a)
        (compiler-ir-clone-value b))]
    [(CompilerIrCallArgs.Array values)
      (CompilerIrCallArgs.Array (clone values))]))

(define (compiler-ir-clone-spmd-backend [backend : CompilerIrSpmdBackend]) : CompilerIrSpmdBackend
  (match backend
    [(IrSpmdBackendScalar) (IrSpmdBackendScalar)]
    [(IrSpmdBackendAvx2) (IrSpmdBackendAvx2)]
    [(IrSpmdBackendAvx512) (IrSpmdBackendAvx512)]))

(define (compiler-ir-clone-spmd-value-class [class : CompilerIrSpmdValueClass]) : CompilerIrSpmdValueClass
  (match class
    [(IrSpmdValueUniform) (IrSpmdValueUniform)]
    [(IrSpmdValueVarying) (IrSpmdValueVarying)]
    [(IrSpmdValueMask) (IrSpmdValueMask)]))

(define (compiler-ir-clone-spmd-call-arg [arg : CompilerIrSpmdCallArg]) : CompilerIrSpmdCallArg
  (match arg
    [(IrSpmdCallArg class value ty)
      (IrSpmdCallArg
        (compiler-ir-clone-spmd-value-class class)
        (compiler-ir-clone-value value)
        (compiler-ir-clone-type ty))]))

(define (compiler-ir-clone-spmd-call-args [args : CompilerIrSpmdCallArgList]) : CompilerIrSpmdCallArgList
  (match args
    [(IrSpmdCallArgNil) (IrSpmdCallArgNil)]
    [(IrSpmdCallArgCons arg rest)
      (IrSpmdCallArgCons
        (compiler-ir-clone-spmd-call-arg arg)
        (box (compiler-ir-clone-spmd-call-args (box-get rest))))]))

(define (compiler-ir-clone-spmd-call-result [result : CompilerIrSpmdCallResult]) : CompilerIrSpmdCallResult
  (match result
    [(IrSpmdCallResultUnit) (IrSpmdCallResultUnit)]
    [(IrSpmdCallResultValue dst class ty)
      (IrSpmdCallResultValue
        dst
        (compiler-ir-clone-spmd-value-class class)
        (compiler-ir-clone-type ty))]))

(define (compiler-ir-clone-c-abi-return-slot [slot : CompilerIrCAbiReturnSlot]) : CompilerIrCAbiReturnSlot
  (match slot
    [(CompilerIrCAbiReturnSlot.Slot ty offset)
      (CompilerIrCAbiReturnSlot.Slot (compiler-ir-clone-type ty) offset)]))

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
    [(CompilerIrPhiInputList.Nil) acc]
    [(CompilerIrPhiInputList.Cons value label rest)
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
    [(CompilerIrPhiInputList.Nil) acc]
    [(CompilerIrPhiInputList.Cons value label rest)
      (compiler-ir-phi-input-list-reverse-onto
        (box-get rest)
        (compiler-ir-phi-input-cons value label acc))]))

(define (compiler-ir-clone-phi-input-list [inputs : CompilerIrPhiInputList]) : CompilerIrPhiInputList
  (compiler-ir-phi-input-list-reverse-onto
    (compiler-ir-clone-phi-input-list-acc inputs CompilerIrPhiInputList.Nil)
    CompilerIrPhiInputList.Nil))

(define (compiler-ir-clone-switch-case [case : CompilerIrSwitchCase]) : CompilerIrSwitchCase
  (match case
    [(CompilerIrSwitchCase.Case tag label)
      (CompilerIrSwitchCase.Case tag (clone label))]))

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
    [(AstType.Func args ret)
      (AstType.Func
        (box (compiler-ir-clone-type-list (box-get args)))
        (ast-node-pool-reader-type-push
          (compiler-ir-clone-type (ast-node-pool-reader-type-get ret))))]
    [(AstType.Tuple elems)
      (AstType.Tuple (box (compiler-ir-clone-type-list (box-get elems))))]
    [(AstType.Array elem len)
      (AstType.Array
        (ast-node-pool-reader-type-push
          (compiler-ir-clone-type (ast-node-pool-reader-type-get elem)))
        len)]
    [(AstType.DynArray elem)
      (AstType.DynArray
        (ast-node-pool-reader-type-push
          (compiler-ir-clone-type (ast-node-pool-reader-type-get elem))))]
    [(AstType.Box elem)
      (AstType.Box
        (ast-node-pool-reader-type-push
          (compiler-ir-clone-type (ast-node-pool-reader-type-get elem))))]
    [(AstType.Region region inner)
      (AstType.Region
        (clone region)
        (ast-node-pool-reader-type-push
          (compiler-ir-clone-type (ast-node-pool-reader-type-get inner))))]
    [(AstType.Ref region inner)
      (AstType.Ref
        (clone region)
        (ast-node-pool-reader-type-push
          (compiler-ir-clone-type (ast-node-pool-reader-type-get inner))))]
    [(AstType.MutRef region inner)
      (AstType.MutRef
        (clone region)
        (ast-node-pool-reader-type-push
          (compiler-ir-clone-type (ast-node-pool-reader-type-get inner))))]
    [(AstType.Ptr elem)
      (AstType.Ptr
        (ast-node-pool-reader-type-push
          (compiler-ir-clone-type (ast-node-pool-reader-type-get elem))))]
    [(AstType.MutPtr elem)
      (AstType.MutPtr
        (ast-node-pool-reader-type-push
          (compiler-ir-clone-type (ast-node-pool-reader-type-get elem))))]
    [_ (clone ty)]))

(define (compiler-ir-clone-type-list [tys : AstTypeList]) : AstTypeList
  (match tys
    [(AstTypeList.Nil) (AstTypeList.Nil)]
    [(AstTypeList.Cons head tail)
      (AstTypeList.Cons
        (ast-node-pool-reader-type-push
          (compiler-ir-clone-type (ast-node-pool-reader-type-get head)))
        (box (compiler-ir-clone-type-list (box-get tail))))]))

(define (compiler-ir-clone-instr [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(CompilerIrInstr.Mov dst src ty)
      (CompilerIrInstr.Mov
        dst
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.Alloc dst ty)
      (CompilerIrInstr.Alloc dst (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.AddrOf dst src) (CompilerIrInstr.AddrOf dst src)]
    [(CompilerIrInstr.Gep dst base offset ty)
      (CompilerIrInstr.Gep
        dst
        (compiler-ir-clone-value base)
        (compiler-ir-clone-value offset)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.Load dst src ty)
      (CompilerIrInstr.Load
        dst
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.StorePtr dst src ty)
      (CompilerIrInstr.StorePtr
        (compiler-ir-clone-value dst)
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.CopyBytes dst src size)
      (CompilerIrInstr.CopyBytes
        (compiler-ir-clone-value dst)
        (compiler-ir-clone-value src)
        size)]
    [(CompilerIrInstr.BoundsCheck index length label)
      (CompilerIrInstr.BoundsCheck
        (compiler-ir-clone-value index)
        (compiler-ir-clone-value length)
        (clone label))]
    [(CompilerIrInstr.Cast dst src from-ty to-ty)
      (CompilerIrInstr.Cast
        dst
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type from-ty)
        (compiler-ir-clone-type to-ty))]
    [(CompilerIrInstr.Bitcast dst src from-ty to-ty)
      (CompilerIrInstr.Bitcast
        dst
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type from-ty)
        (compiler-ir-clone-type to-ty))]
    [(CompilerIrInstr.BinOp dst op lhs rhs ty)
      (CompilerIrInstr.BinOp
        dst
        op
        (compiler-ir-clone-value lhs)
        (compiler-ir-clone-value rhs)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.UnOp dst op src ty)
      (CompilerIrInstr.UnOp
        dst
        op
        (compiler-ir-clone-value src)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.LaneId dst lane ty)
      (CompilerIrInstr.LaneId dst lane (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.Splat dst value lanes ty)
      (CompilerIrInstr.Splat
        dst
        (compiler-ir-clone-value value)
        lanes
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.VectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload.Payload dst op lhs rhs lanes ty)
          (ir-instr-vector-bin-op
            dst
            op
            (compiler-ir-clone-value lhs)
            (compiler-ir-clone-value rhs)
            lanes
            (compiler-ir-clone-type ty))])]
    [(CompilerIrInstr.VectorReduce dst op src lanes ty)
      (CompilerIrInstr.VectorReduce
        dst
        op
        (compiler-ir-clone-value src)
        lanes
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.VectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload.Payload dst op lhs rhs lanes ty)
          (ir-instr-vector-compare
            dst
            op
            (compiler-ir-clone-value lhs)
            (compiler-ir-clone-value rhs)
            lanes
            (compiler-ir-clone-type ty))])]
    [(CompilerIrInstr.MaskBinOp dst op lhs rhs lanes)
      (CompilerIrInstr.MaskBinOp
        dst
        op
        (compiler-ir-clone-value lhs)
        (compiler-ir-clone-value rhs)
        lanes)]
    [(CompilerIrInstr.MaskNot dst src lanes)
      (CompilerIrInstr.MaskNot dst (compiler-ir-clone-value src) lanes)]
    [(CompilerIrInstr.MaskReduce dst op src lanes)
      (CompilerIrInstr.MaskReduce dst op (compiler-ir-clone-value src) lanes)]
    [(CompilerIrInstr.Select payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload.Payload
            dst
            cond
            then-value
            else-value
            lanes
            ty)
          (ir-instr-select
            dst
            (compiler-ir-clone-value cond)
            (compiler-ir-clone-value then-value)
            (compiler-ir-clone-value else-value)
            lanes
            (compiler-ir-clone-type ty))])]
    [(CompilerIrInstr.VectorLoad dst base index lanes ty)
      (CompilerIrInstr.VectorLoad
        dst
        (compiler-ir-clone-value base)
        (compiler-ir-clone-value index)
        lanes
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.VectorStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorStorePayload.Payload base index value lanes ty)
          (ir-instr-vector-store
            (compiler-ir-clone-value base)
            (compiler-ir-clone-value index)
            (compiler-ir-clone-value value)
            lanes
            (compiler-ir-clone-type ty))])]
    [(CompilerIrInstr.PredicatedStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedStorePayload.Payload
            base
            index
            value
            mask
            lanes
            ty)
          (ir-instr-predicated-store
            (compiler-ir-clone-value base)
            (compiler-ir-clone-value index)
            (compiler-ir-clone-value value)
            (compiler-ir-clone-value mask)
            lanes
            (compiler-ir-clone-type ty))])]
    [(CompilerIrInstr.PredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload.Payload
            dst
            base
            index
            mask
            lanes
            ty)
          (ir-instr-predicated-load
            dst
            (compiler-ir-clone-value base)
            (compiler-ir-clone-value index)
            (compiler-ir-clone-value mask)
            lanes
            (compiler-ir-clone-type ty))])]
    [(CompilerIrInstr.TailMask dst index len lanes)
      (CompilerIrInstr.TailMask
        dst
        (compiler-ir-clone-value index)
        (compiler-ir-clone-value len)
        lanes)]
    [(CompilerIrInstr.EntryArgc dst) (CompilerIrInstr.EntryArgc dst)]
    [(CompilerIrInstr.EntryArgv dst) (CompilerIrInstr.EntryArgv dst)]
    [(CompilerIrInstr.EntryEnvp dst) (CompilerIrInstr.EntryEnvp dst)]
    [(CompilerIrInstr.CpuId dst leaf subleaf lanes)
      (CompilerIrInstr.CpuId
        dst
        (compiler-ir-clone-value leaf)
        (compiler-ir-clone-value subleaf)
        lanes)]
    [(CompilerIrInstr.Xgetbv dst index)
      (CompilerIrInstr.Xgetbv dst (compiler-ir-clone-value index))]
    [(CompilerIrInstr.Syscall dst args)
      (CompilerIrInstr.Syscall dst (compiler-ir-clone-call-args args))]
    [(CompilerIrInstr.Call dst name args ty)
      (CompilerIrInstr.Call
        dst
        (clone name)
        (compiler-ir-clone-call-args args)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.CallIndirect dst callee args ty)
      (CompilerIrInstr.CallIndirect
        dst
        (compiler-ir-clone-value callee)
        (compiler-ir-clone-call-args args)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.CallIndirectC dst callee args ty)
      (CompilerIrInstr.CallIndirectC
        dst
        (compiler-ir-clone-value callee)
        (compiler-ir-clone-call-args args)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.CallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload.Payload
            base
            name
            args
            slots)
          (ir-instr-call-cabi-store-result
            (compiler-ir-clone-value base)
            (clone name)
            (compiler-ir-clone-call-args args)
            (compiler-ir-clone-c-abi-return-slots slots))])]
    [(CompilerIrInstr.CallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload.Payload
            base
            callee
            args
            slots)
          (ir-instr-call-indirect-cabi-store-result
            (compiler-ir-clone-value base)
            (compiler-ir-clone-value callee)
            (compiler-ir-clone-call-args args)
            (compiler-ir-clone-c-abi-return-slots slots))])]
    [(IrInstrSpmdCall payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSpmdCallPayload
            callee
            backend
            lanes
            active-mask
            args
            result)
          (ir-instr-spmd-call
            (clone callee)
            (compiler-ir-clone-spmd-backend backend)
            lanes
            (compiler-ir-clone-value active-mask)
            (compiler-ir-clone-spmd-call-args args)
            (compiler-ir-clone-spmd-call-result result))])]
    [(CompilerIrInstr.TailCall name args ty)
      (CompilerIrInstr.TailCall
        (clone name)
        (compiler-ir-clone-call-args args)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.Store name value ty)
      (CompilerIrInstr.Store
        (clone name)
        (compiler-ir-clone-value value)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.Jump label) (CompilerIrInstr.Jump (clone label))]
    [(CompilerIrInstr.Branch cond true-label false-label)
      (CompilerIrInstr.Branch
        (compiler-ir-clone-value cond)
        (clone true-label)
        (clone false-label))]
    [(CompilerIrInstr.Return value)
      (CompilerIrInstr.Return (compiler-ir-clone-maybe-value value))]
    [(CompilerIrInstr.Phi dst inputs ty)
      (CompilerIrInstr.Phi
        dst
        (compiler-ir-clone-phi-input-list inputs)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.Pack dst words ty)
      (CompilerIrInstr.Pack
        dst
        (compiler-ir-clone-value-list words)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.Word dst src index ty)
      (CompilerIrInstr.Word
        dst
        (compiler-ir-clone-value src)
        index
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.TailCallIndirect callee args ty)
      (CompilerIrInstr.TailCallIndirect
        (compiler-ir-clone-value callee)
        (compiler-ir-clone-call-args args)
        (compiler-ir-clone-type ty))]
    [(CompilerIrInstr.Switch index base cases default-label)
      (CompilerIrInstr.Switch
        (compiler-ir-clone-value index)
        base
        (compiler-ir-clone-switch-case-list cases)
        (clone default-label))]))

(define (compiler-ir-clone-instr-list-acc
  [instrs : CompilerIrInstrList]
  [acc : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(CompilerIrInstrList.Nil) acc]
    [(CompilerIrInstrList.Cons instr rest)
      (compiler-ir-clone-instr-list-acc
        (box-get rest)
        (compiler-ir-instr-cons (compiler-ir-clone-instr instr) acc))]))

(define (compiler-ir-instr-list-reverse-onto
  [instrs : CompilerIrInstrList]
  [acc : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(CompilerIrInstrList.Nil) acc]
    [(CompilerIrInstrList.Cons instr rest)
      (compiler-ir-instr-list-reverse-onto
        (box-get rest)
        (compiler-ir-instr-cons instr acc))]))

(define (compiler-ir-clone-instr-list [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (compiler-ir-instr-list-reverse-onto
    (compiler-ir-clone-instr-list-acc instrs CompilerIrInstrList.Nil)
    CompilerIrInstrList.Nil))

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
    [dst : (Array CompilerIrInstr) (array.make-array CompilerIrInstr count)]
    (begin
      (compiler-ir-clone-instr-seq-fill src dst 0 count)
      (CompilerIrInstrSeq dst count))))

(define (compiler-ir-clone-block [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(CompilerIrBlock.Block label instrs)
      (CompilerIrBlock.Block (clone label) (compiler-ir-clone-instr-seq instrs))]))

(define (compiler-ir-clone-block-list-acc
  [blocks : CompilerIrBlockList]
  [acc : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(CompilerIrBlockList.Nil) acc]
    [(CompilerIrBlockList.Cons block rest)
      (compiler-ir-clone-block-list-acc
        (box-get rest)
        (compiler-ir-block-cons (compiler-ir-clone-block block) acc))]
    [(CompilerIrBlockList.Array seq)
      (compiler-ir-clone-block-list-acc (compiler-ir-block-seq-to-list seq) acc)]))

(define (compiler-ir-block-list-reverse-onto
  [blocks : CompilerIrBlockList]
  [acc : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(CompilerIrBlockList.Nil) acc]
    [(CompilerIrBlockList.Cons block rest)
      (compiler-ir-block-list-reverse-onto
        (box-get rest)
        (compiler-ir-block-cons block acc))]
    [(CompilerIrBlockList.Array seq)
      (compiler-ir-block-list-reverse-onto
        (compiler-ir-block-seq-to-list seq)
        acc)]))

(define (compiler-ir-clone-block-list [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (compiler-ir-block-list-reverse-onto
    (compiler-ir-clone-block-list-acc blocks CompilerIrBlockList.Nil)
    CompilerIrBlockList.Nil))

(define (compiler-ir-clone-param [param : CompilerIrParam]) : CompilerIrParam
  (match param
    [(CompilerIrParam.Param name ty id)
      (CompilerIrParam.Param (clone name) (compiler-ir-clone-type ty) id)]))

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
    [(CompilerIrFunction.Function name params ret vars blocks)
      (CompilerIrFunction.Function
        (clone name)
        (compiler-ir-clone-param-list params)
        (compiler-ir-clone-type ret)
        vars
        (compiler-ir-block-list-compact (compiler-ir-clone-block-list blocks)))]))

(define (compiler-ir-clone-function-list-acc
  [functions : CompilerIrFunctionList]
  [acc : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(CompilerIrFunctionList.Nil) acc]
    [(CompilerIrFunctionList.Cons func rest)
      (compiler-ir-clone-function-list-acc
        (box-get rest)
        (compiler-ir-function-cons (compiler-ir-clone-function func) acc))]
    [(CompilerIrFunctionList.Array seq)
      (compiler-ir-clone-function-list-acc
        (compiler-ir-function-seq-to-list seq)
        acc)]))

(define (compiler-ir-function-list-reverse-onto
  [functions : CompilerIrFunctionList]
  [acc : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(CompilerIrFunctionList.Nil) acc]
    [(CompilerIrFunctionList.Cons func rest)
      (compiler-ir-function-list-reverse-onto
        (box-get rest)
        (compiler-ir-function-cons func acc))]
    [(CompilerIrFunctionList.Array seq)
      (compiler-ir-function-list-reverse-onto
        (compiler-ir-function-seq-to-list seq)
        acc)]))

(define (compiler-ir-clone-function-list [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (compiler-ir-function-list-compact
    (compiler-ir-function-list-reverse-onto
      (compiler-ir-clone-function-list-acc functions CompilerIrFunctionList.Nil)
      CompilerIrFunctionList.Nil)))

(define (compiler-ir-clone-global [global : CompilerIrGlobal]) : CompilerIrGlobal
  (match global
    [(CompilerIrGlobal.Global name ty value)
      (CompilerIrGlobal.Global
        (clone name)
        (compiler-ir-clone-type ty)
        (compiler-ir-clone-value value))]))

(define (compiler-ir-clone-global-list-acc
  [globals : CompilerIrGlobalList]
  [acc : CompilerIrGlobalList]) : CompilerIrGlobalList
  (match globals
    [(CompilerIrGlobalList.Nil) acc]
    [(CompilerIrGlobalList.Cons global rest)
      (compiler-ir-clone-global-list-acc
        (box-get rest)
        (compiler-ir-global-cons (compiler-ir-clone-global global) acc))]))

(define (compiler-ir-global-list-reverse-onto
  [globals : CompilerIrGlobalList]
  [acc : CompilerIrGlobalList]) : CompilerIrGlobalList
  (match globals
    [(CompilerIrGlobalList.Nil) acc]
    [(CompilerIrGlobalList.Cons global rest)
      (compiler-ir-global-list-reverse-onto
        (box-get rest)
        (compiler-ir-global-cons global acc))]))

(define (compiler-ir-clone-global-list [globals : CompilerIrGlobalList]) : CompilerIrGlobalList
  (compiler-ir-global-list-reverse-onto
    (compiler-ir-clone-global-list-acc globals CompilerIrGlobalList.Nil)
    CompilerIrGlobalList.Nil))

(define (compiler-ir-clone-extern [extern : CompilerIrExtern]) : CompilerIrExtern
  (match extern
    [(CompilerIrExtern.Extern name ty abi symbol links provided)
      (CompilerIrExtern.Extern
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
    [(CompilerIrExternList.Nil) acc]
    [(CompilerIrExternList.Cons extern rest)
      (compiler-ir-clone-extern-list-acc
        (box-get rest)
        (compiler-ir-extern-cons (compiler-ir-clone-extern extern) acc))]))

(define (compiler-ir-extern-list-reverse-onto
  [externs : CompilerIrExternList]
  [acc : CompilerIrExternList]) : CompilerIrExternList
  (match externs
    [(CompilerIrExternList.Nil) acc]
    [(CompilerIrExternList.Cons extern rest)
      (compiler-ir-extern-list-reverse-onto
        (box-get rest)
        (compiler-ir-extern-cons extern acc))]))

(define (compiler-ir-clone-extern-list [externs : CompilerIrExternList]) : CompilerIrExternList
  (compiler-ir-extern-list-reverse-onto
    (compiler-ir-clone-extern-list-acc externs CompilerIrExternList.Nil)
    CompilerIrExternList.Nil))

(define (compiler-ir-clone-program [program : CompilerIrProgram]) : CompilerIrProgram
  (match program
    [(CompilerIrProgram.Program globals functions externs)
      (CompilerIrProgram.Program
        (compiler-ir-clone-global-list globals)
        (compiler-ir-clone-function-list functions)
        (compiler-ir-clone-extern-list externs))]))

(define (compiler-ir-type-list-render [types : AstTypeList]) : String
  (match types
    [(AstTypeList.Nil) ""]
    [(AstTypeList.Cons head rest)
      (let
        [head : AstType (ast-node-pool-reader-type-get head)]
        [rest : AstTypeList (box-get rest)]
        (str_cat.str-cat
          (compiler-ir-type-render head)
          (match rest
            [(AstTypeList.Nil) ""]
            [_ (str_cat.str-cat " " (compiler-ir-type-list-render rest))])))]))

(define (compiler-ir-lifetime-list-render [lifetimes : AstLifetimeList]) : String
  (match lifetimes
    [(AstLifetimeList.Nil) ""]
    [(AstLifetimeList.Cons head rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (str_cat.str-cat
          head
          (match rest
            [(AstLifetimeList.Nil) ""]
            [_ (str_cat.str-cat " " (compiler-ir-lifetime-list-render rest))])))]))

(define (compiler-ir-nominal-lifetime-render
  [name : String]
  [lifetimes : AstLifetimeList]) : String
  (str_cat.str-cat
    "("
    name
    " "
    (compiler-ir-lifetime-list-render lifetimes)
    ")"))

(define (compiler-ir-type-render [ty : AstType]) : String
  (match ty
    [(AstType.I64) "i64"]
    [(AstType.I32) "i32"]
    [(AstType.I16) "i16"]
    [(AstType.I8) "i8"]
    [(AstType.U64) "u64"]
    [(AstType.U32) "u32"]
    [(AstType.U16) "u16"]
    [(AstType.U8) "u8"]
    [(AstType.F64) "f64"]
    [(AstType.F32) "f32"]
    [(AstType.Bool) "bool"]
    [(AstType.Char) "char"]
    [(AstType.String) "String"]
    [(AstType.Str) "str"]
    [(AstType.Bytes) "bytes"]
    [(AstType.Unit) "unit"]
    [(AstType.Never) "never"]
    [(AstType.Expr) "Expr"]
    [(AstType.ExprList) "ExprList"]
    [(AstType.Func args ret)
      (str_cat.str-cat
        "(-> "
        (compiler-ir-type-list-render (box-get args))
        " "
        (compiler-ir-type-render (ast-node-pool-reader-type-get ret))
        ")")]
    [(AstType.Tuple elems)
      (str_cat.str-cat
        "(Tuple "
        (compiler-ir-type-list-render (box-get elems))
        ")")]
    [(AstType.Array elem count)
      (str_cat.str-cat
        "(Array "
        (compiler-ir-type-render (ast-node-pool-reader-type-get elem))
        " "
        (string.int->string count)
        ")")]
    [(AstType.DynArray elem)
      (str_cat.str-cat
        "(Array "
        (compiler-ir-type-render (ast-node-pool-reader-type-get elem))
        ")")]
    [(AstType.Box elem)
      (str_cat.str-cat
        "(Box "
        (compiler-ir-type-render (ast-node-pool-reader-type-get elem))
        ")")]
    [(AstType.Region region inner)
      (str_cat.str-cat
        "(Region "
        region
        " "
        (compiler-ir-type-render (ast-node-pool-reader-type-get inner))
        ")")]
    [(AstType.Ref region inner)
      (str_cat.str-cat
        "(& "
        region
        " "
        (compiler-ir-type-render (ast-node-pool-reader-type-get inner))
        ")")]
    [(AstType.MutRef region inner)
      (str_cat.str-cat
        "(&mut "
        region
        " "
        (compiler-ir-type-render (ast-node-pool-reader-type-get inner))
        ")")]
    [(AstType.Enum name) (intern-str name)]
    [(AstType.EnumArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstType.Struct name) (intern-str name)]
    [(AstType.StructArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstType.Var name) (intern-str name)]
    [(AstType.VarArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstType.Ptr elem)
      (str_cat.str-cat
        "(Ptr "
        (compiler-ir-type-render (ast-node-pool-reader-type-get elem))
        ")")]
    [(AstType.MutPtr elem)
      (str_cat.str-cat
        "(MutPtr "
        (compiler-ir-type-render (ast-node-pool-reader-type-get elem))
        ")")]))

(define (compiler-ir-u64-payload-render [value : u64]) : String
  (string.int->string (cast value : i64)))

(define (compiler-ir-value-render [value : CompilerIrValue]) : String
  (match value
    [(CompilerIrValue.Var id) (string.append "%" (string.int->string id))]
    [(CompilerIrValue.Global name) (string.append "@" name)]
    [(CompilerIrValue.GlobalAddr name) (string.append "&@" name)]
    [(CompilerIrValue.Function name) (string.append "fn@" name)]
    [(CompilerIrValue.I64 value) (string.int->string value)]
    [(CompilerIrValue.F64 value)
      (str_cat.str-cat "float-bits:" (compiler-ir-u64-payload-render value))]
    [(CompilerIrValue.Bool value)
      (if value
        "true"
        "false")]
    [(CompilerIrValue.Char value) (string.int->string (cast value : i64))]
    [(CompilerIrValue.String value) value]
    [(CompilerIrValue.Bytes value)
      (str_cat.str-cat
        "<bytes:"
        (string.int->string (string.string-length value))
        ">")]
    [(CompilerIrValue.Unit) "unit"]))

(define (compiler-ir-value-list-render [values : CompilerIrValueList]) : String
  (match values
    [(IrValueNil) ""]
    [(IrValueCons value rest)
      (str_cat.str-cat
        (compiler-ir-value-render value)
        (match (box-get rest)
          [(IrValueNil) ""]
          [_
            (str_cat.str-cat
              ", "
              (compiler-ir-value-list-render (box-get rest)))]))]))

(define (compiler-ir-switch-case-render [case : CompilerIrSwitchCase]) : String
  (match case
    [(CompilerIrSwitchCase.Case tag label)
      (str_cat.str-cat (string.int->string tag) ":" label)]))

(define (compiler-ir-switch-case-list-render [cases : CompilerIrSwitchCaseList]) : String
  (match cases
    [(IrSwitchCaseNil) ""]
    [(IrSwitchCaseCons case rest)
      (str_cat.str-cat
        (compiler-ir-switch-case-render case)
        (match (box-get rest)
          [(IrSwitchCaseNil) ""]
          [_
            (str_cat.str-cat
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
    [out : (Array CompilerIrValue) (array.make-array CompilerIrValue count)]
    (begin
      (compiler-ir-value-list-fill-array values out 0)
      (CompilerIrCallArgs.Array out))))

(define (compiler-ir-call-args-from-list [values : CompilerIrValueList]) : CompilerIrCallArgs
  (match values
    [(IrValueNil) (CompilerIrCallArgs.Nil)]
    [(IrValueCons a rest)
      (match (box-get rest)
        [(IrValueNil) (CompilerIrCallArgs.One a)]
        [(IrValueCons b tail)
          (match (box-get tail)
            [(IrValueNil) (CompilerIrCallArgs.Two a b)]
            [_ (compiler-ir-call-args-array values)])])]))

(define (compiler-ir-call-args-array-render
  [values : (Array CompilerIrValue)]
  [index : i64]) : String
  (if (>= index (array-length values))
    ""
    (str_cat.str-cat
      (compiler-ir-value-render (array-ref values index))
      (if (= (+ index 1) (array-length values))
        ""
        (str_cat.str-cat
          ", "
          (compiler-ir-call-args-array-render values (+ index 1)))))))

(define (compiler-ir-call-args-render [args : CompilerIrCallArgs]) : String
  (match args
    [(CompilerIrCallArgs.Nil) ""]
    [(CompilerIrCallArgs.One a) (compiler-ir-value-render a)]
    [(CompilerIrCallArgs.Two a b)
      (str_cat.str-cat
        (compiler-ir-value-render a)
        ", "
        (compiler-ir-value-render b))]
    [(CompilerIrCallArgs.Array values)
      (compiler-ir-call-args-array-render values 0)]))

(define (compiler-ir-call-args-count [args : CompilerIrCallArgs]) : i64
  (match args
    [(CompilerIrCallArgs.Nil) 0]
    [(CompilerIrCallArgs.One _) 1]
    [(CompilerIrCallArgs.Two _ _) 2]
    [(CompilerIrCallArgs.Array values) (array-length values)]))

(define (compiler-ir-spmd-backend-render [backend : CompilerIrSpmdBackend]) : String
  (match backend
    [(IrSpmdBackendScalar) "scalar"]
    [(IrSpmdBackendAvx2) "avx2"]
    [(IrSpmdBackendAvx512) "avx512"]))

(define (compiler-ir-spmd-value-class-render [class : CompilerIrSpmdValueClass]) : String
  (match class
    [(IrSpmdValueUniform) "uniform"]
    [(IrSpmdValueVarying) "varying"]
    [(IrSpmdValueMask) "mask"]))

(define (compiler-ir-spmd-call-arg-render [arg : CompilerIrSpmdCallArg]) : String
  (match arg
    [(IrSpmdCallArg class value ty)
      (str_cat.str-cat
        (compiler-ir-spmd-value-class-render class)
        " "
        (compiler-ir-value-render value)
        " : "
        (compiler-ir-type-render ty))]))

(define (compiler-ir-spmd-call-args-render [args : CompilerIrSpmdCallArgList]) : String
  (match args
    [(IrSpmdCallArgNil) ""]
    [(IrSpmdCallArgCons arg rest)
      (match (box-get rest)
        [(IrSpmdCallArgNil) (compiler-ir-spmd-call-arg-render arg)]
        [_
          (str_cat.str-cat
            (compiler-ir-spmd-call-arg-render arg)
            ", "
            (compiler-ir-spmd-call-args-render (box-get rest)))])]))

(define (compiler-ir-spmd-call-arg-count [args : CompilerIrSpmdCallArgList]) : i64
  (match args
    [(IrSpmdCallArgNil) 0]
    [(IrSpmdCallArgCons _ rest)
      (+ 1 (compiler-ir-spmd-call-arg-count (box-get rest)))]))

(define (compiler-ir-spmd-result-render [result : CompilerIrSpmdCallResult]) : String
  (match result
    [(IrSpmdCallResultUnit) "unit"]
    [(IrSpmdCallResultValue _ class ty)
      (str_cat.str-cat
        (compiler-ir-spmd-value-class-render class)
        " "
        (compiler-ir-type-render ty))]))

(define (compiler-ir-tail-call-render
  [name : String]
  [args : CompilerIrCallArgs]
  [ty : AstType]) : String
  (str_cat.str-cat
    "  tailcall "
    name
    "("
    (compiler-ir-call-args-render args)
    ") : "
    (compiler-ir-type-render ty)))

(define (compiler-ir-spmd-call-render
  [callee : String]
  [backend : CompilerIrSpmdBackend]
  [lanes : i64]
  [active-mask : CompilerIrValue]
  [args : CompilerIrSpmdCallArgList]
  [result : CompilerIrSpmdCallResult]) : String
  (str_cat.str-cat
    "  spmd_call "
    callee
    " backend "
    (compiler-ir-spmd-backend-render backend)
    " lanes "
    (string.int->string lanes)
    " mask "
    (compiler-ir-value-render active-mask)
    "("
    (compiler-ir-spmd-call-args-render args)
    ") : "
    (compiler-ir-spmd-result-render result)))

(define (compiler-ir-tail-call-indirect-render
  [callee : CompilerIrValue]
  [args : CompilerIrCallArgs]
  [ty : AstType]) : String
  (str_cat.str-cat
    "  tailcall* "
    (compiler-ir-value-render callee)
    "("
    (compiler-ir-call-args-render args)
    ") : "
    (compiler-ir-type-render ty)))

(define (compiler-ir-instr-render [instr : CompilerIrInstr]) : String
  (match instr
    [(CompilerIrInstr.TailCall name args ty)
      (compiler-ir-tail-call-render name args ty)]
    [(CompilerIrInstr.TailCallIndirect callee args ty)
      (compiler-ir-tail-call-indirect-render callee args ty)]
    [(IrInstrSpmdCall payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSpmdCallPayload
            callee
            backend
            lanes
            active-mask
            args
            result)
          (compiler-ir-spmd-call-render
            callee
            backend
            lanes
            active-mask
            args
            result)])]
    [(CompilerIrInstr.Switch index base cases default-label)
      (str_cat.str-cat
        "  switch "
        (compiler-ir-value-render index)
        " base "
        (string.int->string base)
        " ["
        (compiler-ir-switch-case-list-render cases)
        "] default "
        default-label)]
    [_ "  <ir-instr>"]))

(defenum CompilerIrEffect
  (Pure)
  (MemoryRead)
  (CpuProbe)
  (MemoryWrite)
  (ControlFlow)
  (Unknown))

(define (compiler-ir-effect-eq? [a : CompilerIrEffect] [b : CompilerIrEffect]) : bool
  (match a
    [(CompilerIrEffect.Pure)
      (match b
        [(CompilerIrEffect.Pure) true]
        [_ false])]
    [(CompilerIrEffect.MemoryRead)
      (match b
        [(CompilerIrEffect.MemoryRead) true]
        [_ false])]
    [(CompilerIrEffect.CpuProbe)
      (match b
        [(CompilerIrEffect.CpuProbe) true]
        [_ false])]
    [(CompilerIrEffect.MemoryWrite)
      (match b
        [(CompilerIrEffect.MemoryWrite) true]
        [_ false])]
    [(CompilerIrEffect.ControlFlow)
      (match b
        [(CompilerIrEffect.ControlFlow) true]
        [_ false])]
    [(CompilerIrEffect.Unknown)
      (match b
        [(CompilerIrEffect.Unknown) true]
        [_ false])]))

(define (compiler-ir-effect-has-side-effect? [effect : CompilerIrEffect]) : bool
  (match effect
    [(CompilerIrEffect.Pure) false]
    [(CompilerIrEffect.MemoryRead) false]
    [(CompilerIrEffect.CpuProbe) true]
    [(CompilerIrEffect.MemoryWrite) true]
    [(CompilerIrEffect.ControlFlow) true]
    [(CompilerIrEffect.Unknown) true]))

(define (compiler-ir-effect-invalidates-cse? [effect : CompilerIrEffect]) : bool
  (match effect
    [(CompilerIrEffect.Pure) false]
    [_ true]))

(define (compiler-ir-runtime-memory-read? [name : String]) : bool
  (or (string.eq name "tl_region_mark") (string.eq name ".L_tl_stdin_eof")))

(define (compiler-ir-runtime-memory-write? [name : String]) : bool
  (or
    (string.eq name "tl_alloc")
    (string.eq name "tl_int_to_string")
    (string.eq name "tl_substring")
    (string.eq name "tl_string_concat")
    (string.eq name "tl_string_concat3")
    (string.eq name "tl_string_concat4")
    (string.eq name "tl_string_concat5")
    (string.eq name "tl_region_reset")
    (string.eq name "tl_array_fill8")
    (string.eq name "tl_array_zero")
    (string.eq name ".L_tl_flush_stdout")))

(define (compiler-ir-runtime-control-flow? [name : String]) : bool
  (or
    (string.eq name ".L_tl_abort")
    (string.eq name "tl_oob_abort")
    (string.eq name "tl_div_abort")
    (string.eq name "tl_shift_abort")))

(define (compiler-ir-direct-call-effect [name : String]) : CompilerIrEffect
  (cond
    [(compiler-ir-runtime-memory-read? name) CompilerIrEffect.MemoryRead]
    [(compiler-ir-runtime-memory-write? name) CompilerIrEffect.MemoryWrite]
    [(compiler-ir-runtime-control-flow? name) CompilerIrEffect.ControlFlow]
    [else CompilerIrEffect.Unknown]))

(define (compiler-ir-instr-effect [instr : CompilerIrInstr]) : CompilerIrEffect
  (match instr
    [(CompilerIrInstr.Mov _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.AddrOf _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.Gep _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.Cast _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.Bitcast _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.BinOp _ _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.UnOp _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.Phi _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.LaneId _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.Splat _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.VectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload.Payload _ _ _ _ _ _)
          CompilerIrEffect.Pure])]
    [(CompilerIrInstr.VectorReduce _ _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.VectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload.Payload _ _ _ _ _ _)
          CompilerIrEffect.Pure])]
    [(CompilerIrInstr.MaskBinOp _ _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.MaskNot _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.MaskReduce _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.Select payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload.Payload _ _ _ _ _ _)
          CompilerIrEffect.Pure])]
    [(CompilerIrInstr.TailMask _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.Load _ _ _) CompilerIrEffect.MemoryRead]
    [(CompilerIrInstr.VectorLoad _ _ _ _ _) CompilerIrEffect.MemoryRead]
    [(CompilerIrInstr.PredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload.Payload _ _ _ _ _ _)
          CompilerIrEffect.MemoryRead])]
    [(CompilerIrInstr.EntryArgc _) CompilerIrEffect.MemoryRead]
    [(CompilerIrInstr.EntryArgv _) CompilerIrEffect.MemoryRead]
    [(CompilerIrInstr.EntryEnvp _) CompilerIrEffect.MemoryRead]
    [(CompilerIrInstr.CpuId _ _ _ _) CompilerIrEffect.CpuProbe]
    [(CompilerIrInstr.Xgetbv _ _) CompilerIrEffect.CpuProbe]
    [(CompilerIrInstr.Syscall _ _) CompilerIrEffect.Unknown]
    [(CompilerIrInstr.Alloc _ _) CompilerIrEffect.MemoryWrite]
    [(CompilerIrInstr.StorePtr _ _ _) CompilerIrEffect.MemoryWrite]
    [(CompilerIrInstr.CopyBytes _ _ _) CompilerIrEffect.MemoryWrite]
    [(CompilerIrInstr.Store _ _ _) CompilerIrEffect.MemoryWrite]
    [(CompilerIrInstr.VectorStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorStorePayload.Payload _ _ _ _ _)
          CompilerIrEffect.MemoryWrite])]
    [(CompilerIrInstr.PredicatedStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedStorePayload.Payload _ _ _ _ _ _)
          CompilerIrEffect.MemoryWrite])]
    [(CompilerIrInstr.Call _ name _ _) (compiler-ir-direct-call-effect name)]
    [(CompilerIrInstr.CallIndirect _ _ _ _) CompilerIrEffect.Unknown]
    [(CompilerIrInstr.CallIndirectC _ _ _ _) CompilerIrEffect.Unknown]
    [(CompilerIrInstr.CallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload.Payload _ _ _ _)
          CompilerIrEffect.Unknown])]
    [(CompilerIrInstr.CallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload.Payload _ _ _ _)
          CompilerIrEffect.Unknown])]
    [(IrInstrSpmdCall payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSpmdCallPayload _ _ _ _ _ _) CompilerIrEffect.Unknown])]
    [(CompilerIrInstr.BoundsCheck _ _ _) CompilerIrEffect.ControlFlow]
    [(CompilerIrInstr.TailCall _ _ _) CompilerIrEffect.ControlFlow]
    [(CompilerIrInstr.Jump _) CompilerIrEffect.ControlFlow]
    [(CompilerIrInstr.Branch _ _ _) CompilerIrEffect.ControlFlow]
    [(CompilerIrInstr.Return _) CompilerIrEffect.ControlFlow]
    [(CompilerIrInstr.Pack _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.Word _ _ _ _) CompilerIrEffect.Pure]
    [(CompilerIrInstr.TailCallIndirect _ _ _) CompilerIrEffect.ControlFlow]
    [(CompilerIrInstr.Switch _ _ _ _) CompilerIrEffect.ControlFlow]))

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
  (Entry String AstSourceSpan))

(defenum CompilerSourceSpansEntryList
  (Nil)
  (Cons CompilerSourceSpansEntry (Box CompilerSourceSpansEntryList)))

(defenum CompilerSourceSpans
  (Spans CompilerSourceSpansEntryList CompilerSourceSpansEntryList i64))

(defenum CompilerMaybeSourceSpan
  (No)
  (Some AstSourceSpan))

(define (compiler-source-spans-empty) : CompilerSourceSpans
  (CompilerSourceSpans.Spans
    (CompilerSourceSpansEntryList.Nil)
    (CompilerSourceSpansEntryList.Nil)
    0))

(define (compiler-source-spans-clear-instrs [spans : CompilerSourceSpans]) : CompilerSourceSpans
  (match spans
    [(CompilerSourceSpans.Spans entries _ _)
      (CompilerSourceSpans.Spans entries (CompilerSourceSpansEntryList.Nil) 0)]))

(define (compiler-source-spans-entry-list-append
  [entries : CompilerSourceSpansEntryList]
  [entry : CompilerSourceSpansEntry]) : CompilerSourceSpansEntryList
  (match entries
    [(CompilerSourceSpansEntryList.Nil)
      (CompilerSourceSpansEntryList.Cons
        entry
        (box (CompilerSourceSpansEntryList.Nil)))]
    [(CompilerSourceSpansEntryList.Cons head rest)
      (let
        [rest : CompilerSourceSpansEntryList (box-get rest)]
        (CompilerSourceSpansEntryList.Cons
          head
          (box (compiler-source-spans-entry-list-append rest entry))))]))

;; Record `name -> span`. Function names are unique in lowered programs, so a
;; prepend keeps diagnostics equivalent while avoiding O(n^2) provenance builds.
(define (compiler-source-spans-insert
  [spans : CompilerSourceSpans]
  [name : String]
  [span : AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(CompilerSourceSpans.Spans entries instr-entries instr-count)
      (CompilerSourceSpans.Spans
        (CompilerSourceSpansEntryList.Cons
          (CompilerSourceSpansEntry.Entry name span)
          (box entries))
        instr-entries
        instr-count)]))

(define (compiler-source-spans-entry-list-lookup
  [entries : CompilerSourceSpansEntryList]
  [name : String]) : CompilerMaybeSourceSpan
  (match entries
    [(CompilerSourceSpansEntryList.Nil) (CompilerMaybeSourceSpan.No)]
    [(CompilerSourceSpansEntryList.Cons entry rest)
      (let
        [rest : CompilerSourceSpansEntryList (box-get rest)]
        (match entry
          [(CompilerSourceSpansEntry.Entry entry-name span)
            (if (string.eq entry-name name)
              (CompilerMaybeSourceSpan.Some span)
              (compiler-source-spans-entry-list-lookup rest name))]))]))

(define (compiler-source-spans-lookup
  [spans : CompilerSourceSpans]
  [name : String]) : CompilerMaybeSourceSpan
  (match spans
    [(CompilerSourceSpans.Spans entries _ _)
      (compiler-source-spans-entry-list-lookup entries name)]))

(define (compiler-source-spans-value-key [function : String] [var-id : i64]) : String
  (str_cat.str-cat "value:" function ":" (string.int->string var-id)))

(define (compiler-source-spans-store-key [function : String] [name : String]) : String
  (str_cat.str-cat "store:" function ":" name))

(define (compiler-source-spans-insert-instr-entry
  [spans : CompilerSourceSpans]
  [key : String]
  [span : AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(CompilerSourceSpans.Spans entries instr-entries instr-count)
      (CompilerSourceSpans.Spans
        entries
        (CompilerSourceSpansEntryList.Cons
          (CompilerSourceSpansEntry.Entry key span)
          (box instr-entries))
        (+ instr-count 1))]))

(define (compiler-source-spans-insert-instr
  [spans : CompilerSourceSpans]
  [function : String]
  [instr : CompilerIrInstr]
  [span : AstSourceSpan]) : CompilerSourceSpans
  (match instr
    [(CompilerIrInstr.Mov dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Alloc dst _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.AddrOf dst _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Gep dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Load dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Cast dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Bitcast dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.BinOp dst _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.UnOp dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.LaneId dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Splat dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.VectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload.Payload dst _ _ _ _ _)
          (compiler-source-spans-insert-instr-entry
            spans
            (compiler-source-spans-value-key function dst)
            span)])]
    [(CompilerIrInstr.VectorReduce dst _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.VectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload.Payload dst _ _ _ _ _)
          (compiler-source-spans-insert-instr-entry
            spans
            (compiler-source-spans-value-key function dst)
            span)])]
    [(CompilerIrInstr.MaskBinOp dst _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.MaskNot dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.MaskReduce dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Select payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload.Payload dst _ _ _ _ _)
          (compiler-source-spans-insert-instr-entry
            spans
            (compiler-source-spans-value-key function dst)
            span)])]
    [(CompilerIrInstr.VectorLoad dst _ _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.PredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload.Payload dst _ _ _ _ _)
          (compiler-source-spans-insert-instr-entry
            spans
            (compiler-source-spans-value-key function dst)
            span)])]
    [(CompilerIrInstr.TailMask dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.EntryArgc dst)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.EntryArgv dst)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.EntryEnvp dst)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.CpuId dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Xgetbv dst _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Syscall dst _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Call dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.CallIndirect dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.CallIndirectC dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.CallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload.Payload _ _ _ _) spans])]
    [(CompilerIrInstr.CallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload.Payload _ _ _ _)
          spans])]
    [(IrInstrSpmdCall payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSpmdCallPayload _ _ _ _ _ result)
          (match result
            [(IrSpmdCallResultUnit) spans]
            [(IrSpmdCallResultValue dst _ _)
              (compiler-source-spans-insert-instr-entry
                spans
                (compiler-source-spans-value-key function dst)
                span)])])]
    [(CompilerIrInstr.Pack dst _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(CompilerIrInstr.Word dst _ _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    ;; Tail-indirect is control flow and does not define a destination value.
    [(CompilerIrInstr.TailCallIndirect _ _ _) spans]
    [(CompilerIrInstr.Store name _ _)
      (compiler-source-spans-insert-instr-entry
        spans
        (compiler-source-spans-store-key function name)
        span)]
    [(CompilerIrInstr.Phi dst _ _)
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
    [(CompilerSourceSpans.Spans _ instr-entries _)
      (match instr
        [(CompilerIrInstr.Mov dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Alloc dst _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.AddrOf dst _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Gep dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Load dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Cast dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Bitcast dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.BinOp dst _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.UnOp dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.LaneId dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Splat dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.VectorBinOp payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrVectorBinOpPayload.Payload dst _ _ _ _ _)
              (compiler-source-spans-entry-list-lookup
                instr-entries
                (compiler-source-spans-value-key function dst))])]
        [(CompilerIrInstr.VectorReduce dst _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.VectorCompare payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrVectorComparePayload.Payload dst _ _ _ _ _)
              (compiler-source-spans-entry-list-lookup
                instr-entries
                (compiler-source-spans-value-key function dst))])]
        [(CompilerIrInstr.MaskBinOp dst _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.MaskNot dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.MaskReduce dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Select payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrSelectPayload.Payload dst _ _ _ _ _)
              (compiler-source-spans-entry-list-lookup
                instr-entries
                (compiler-source-spans-value-key function dst))])]
        [(CompilerIrInstr.VectorLoad dst _ _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.PredicatedLoad payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrPredicatedLoadPayload.Payload dst _ _ _ _ _)
              (compiler-source-spans-entry-list-lookup
                instr-entries
                (compiler-source-spans-value-key function dst))])]
        [(CompilerIrInstr.TailMask dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.EntryArgc dst)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.EntryArgv dst)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.EntryEnvp dst)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.CpuId dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Xgetbv dst _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Syscall dst _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Call dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.CallIndirect dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.CallIndirectC dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.CallCAbiStoreResult payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrCallCAbiStoreResultPayload.Payload _ _ _ _)
              (CompilerMaybeSourceSpan.No)])]
        [(CompilerIrInstr.CallIndirectCAbiStoreResult payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrCallIndirectCAbiStoreResultPayload.Payload _ _ _ _)
              (CompilerMaybeSourceSpan.No)])]
        [(IrInstrSpmdCall payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrSpmdCallPayload _ _ _ _ _ result)
              (match result
                [(IrSpmdCallResultUnit) (CompilerMaybeSourceSpan.No)]
                [(IrSpmdCallResultValue dst _ _)
                  (compiler-source-spans-entry-list-lookup
                    instr-entries
                    (compiler-source-spans-value-key function dst))])])]
        [(CompilerIrInstr.Pack dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(CompilerIrInstr.Word dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        ;; Tail-indirect is control flow and does not define a destination value.
        [(CompilerIrInstr.TailCallIndirect _ _ _) (CompilerMaybeSourceSpan.No)]
        [(CompilerIrInstr.Store name _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-store-key function name))]
        [(CompilerIrInstr.Phi dst _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [_ (CompilerMaybeSourceSpan.No)])]))

;; Number of recorded entries; supports provenance smoke assertions (#605).
(define (compiler-source-spans-entry-list-count
  [entries : CompilerSourceSpansEntryList]) : i64
  (match entries
    [(CompilerSourceSpansEntryList.Nil) 0]
    [(CompilerSourceSpansEntryList.Cons _ rest)
      (let
        [rest : CompilerSourceSpansEntryList (box-get rest)]
        (+ 1 (compiler-source-spans-entry-list-count rest)))]))

(define (compiler-source-spans-count [spans : CompilerSourceSpans]) : i64
  (match spans
    [(CompilerSourceSpans.Spans entries _ _)
      (compiler-source-spans-entry-list-count entries)]))

(define (compiler-source-spans-instr-count [spans : CompilerSourceSpans]) : i64
  (match spans
    [(CompilerSourceSpans.Spans _ _ instr-count) instr-count]))

(define (compiler-source-spans-instr-count-at-least?
  [spans : CompilerSourceSpans]
  [minimum : i64]) : bool
  (match spans
    [(CompilerSourceSpans.Spans _ _ instr-count) (>= instr-count minimum)]))

(defenum CompilerIrSummary
  (Summary i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64))

(define (compiler-ir-summary-globals [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary globals _ _ _ _ _ _ _ _ _ _) globals]))

(define (compiler-ir-summary-functions [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary _ functions _ _ _ _ _ _ _ _ _) functions]))

(define (compiler-ir-summary-externs [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary _ _ externs _ _ _ _ _ _ _ _) externs]))

(define (compiler-ir-summary-blocks [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary _ _ _ blocks _ _ _ _ _ _ _) blocks]))

(define (compiler-ir-summary-instructions [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary _ _ _ _ instructions _ _ _ _ _ _) instructions]))

(define (compiler-ir-summary-vars [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary _ _ _ _ _ vars _ _ _ _ _) vars]))

(define (compiler-ir-summary-empty-blocks [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary _ _ _ _ _ _ empty-blocks _ _ _ _) empty-blocks]))

(define (compiler-ir-summary-max-instructions-function
  [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary _ _ _ _ _ _ _ max-instructions-function _ _ _)
      max-instructions-function]))

(define (compiler-ir-summary-max-instructions-block
  [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary _ _ _ _ _ _ _ _ max-instructions-block _ _)
      max-instructions-block]))

(define (compiler-ir-summary-call-arg-entries [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary _ _ _ _ _ _ _ _ _ call-arg-entries _)
      call-arg-entries]))

(define (compiler-ir-summary-phi-input-entries [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary _ _ _ _ _ _ _ _ _ _ phi-input-entries)
      phi-input-entries]))

(define (compiler-ir-summary-score [summary : CompilerIrSummary]) : i64
  (match summary
    [(CompilerIrSummary.Summary
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
    [(CompilerIrGlobalList.Nil) 0]
    [(CompilerIrGlobalList.Cons _ rest)
      (+ 1 (compiler-ir-global-list-count (box-get rest)))]))

(define (compiler-ir-extern-list-count [externs : CompilerIrExternList]) : i64
  (match externs
    [(CompilerIrExternList.Nil) 0]
    [(CompilerIrExternList.Cons _ rest)
      (+ 1 (compiler-ir-extern-list-count (box-get rest)))]))

(define (compiler-ir-max-i64 [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

(define (compiler-ir-phi-input-list-count [inputs : CompilerIrPhiInputList]) : i64
  (match inputs
    [(CompilerIrPhiInputList.Nil) 0]
    [(CompilerIrPhiInputList.Cons _ _ rest)
      (+ 1 (compiler-ir-phi-input-list-count (box-get rest)))]))

(define (compiler-ir-instr-call-arg-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Call _ _ args _) (compiler-ir-call-args-count args)]
    [(CompilerIrInstr.CallIndirect _ _ args _)
      (compiler-ir-call-args-count args)]
    [(CompilerIrInstr.CallIndirectC _ _ args _)
      (compiler-ir-call-args-count args)]
    [(CompilerIrInstr.CallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload.Payload _ _ args _)
          (compiler-ir-call-args-count args)])]
    [(CompilerIrInstr.CallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload.Payload _ _ args _)
          (compiler-ir-call-args-count args)])]
    [(IrInstrSpmdCall payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSpmdCallPayload _ _ _ _ args _)
          (compiler-ir-spmd-call-arg-count args)])]
    [(CompilerIrInstr.TailCall _ args _) (compiler-ir-call-args-count args)]
    [(CompilerIrInstr.TailCallIndirect _ args _)
      (compiler-ir-call-args-count args)]
    [_ 0]))

(define (compiler-ir-instr-phi-input-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Phi _ inputs _) (compiler-ir-phi-input-list-count inputs)]
    [_ 0]))

(define (compiler-ir-instr-list-call-arg-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
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
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
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
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons _ rest)
      (+ 1 (compiler-ir-block-list-count (box-get rest)))]
    [(CompilerIrBlockList.Array seq) (struct-get seq len)]))

(define (compiler-ir-block-list-empty-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (if (= (compiler-ir-instr-seq-count instrs) 0)
              1
              0)
            (compiler-ir-block-list-empty-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (compiler-ir-block-list-empty-count (compiler-ir-block-seq-to-list seq))]))

(define (compiler-ir-block-list-max-instruction-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (compiler-ir-max-i64
            (compiler-ir-instr-seq-count instrs)
            (compiler-ir-block-list-max-instruction-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (compiler-ir-block-list-max-instruction-count
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-ir-block-list-call-arg-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (compiler-ir-instr-seq-call-arg-count instrs)
            (compiler-ir-block-list-call-arg-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (compiler-ir-block-list-call-arg-count
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-ir-block-list-phi-input-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (compiler-ir-instr-seq-phi-input-count instrs)
            (compiler-ir-block-list-phi-input-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (compiler-ir-block-list-phi-input-count
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-ir-block-list-instruction-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (compiler-ir-instr-seq-count instrs)
            (compiler-ir-block-list-instruction-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (compiler-ir-block-list-instruction-count
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-ir-function-block-count [func : CompilerIrFunction]) : i64
  (match func
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (compiler-ir-block-list-count blocks)]))

(define (compiler-ir-function-instruction-count [func : CompilerIrFunction]) : i64
  (match func
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (compiler-ir-block-list-instruction-count blocks)]))

(define (compiler-ir-function-empty-block-count [func : CompilerIrFunction]) : i64
  (match func
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (compiler-ir-block-list-empty-count blocks)]))

(define (compiler-ir-function-max-instruction-count [func : CompilerIrFunction]) : i64
  (match func
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (compiler-ir-block-list-instruction-count blocks)]))

(define (compiler-ir-function-max-block-instruction-count
  [func : CompilerIrFunction]) : i64
  (match func
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (compiler-ir-block-list-max-instruction-count blocks)]))

(define (compiler-ir-function-call-arg-count [func : CompilerIrFunction]) : i64
  (match func
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (compiler-ir-block-list-call-arg-count blocks)]))

(define (compiler-ir-function-phi-input-count [func : CompilerIrFunction]) : i64
  (match func
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (compiler-ir-block-list-phi-input-count blocks)]))

(define (compiler-ir-function-var-count [func : CompilerIrFunction]) : i64
  (match func
    [(CompilerIrFunction.Function _ _ _ vars _) vars]))

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
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons _ rest)
      (+ 1 (compiler-ir-function-list-count (box-get rest)))]
    [(CompilerIrFunctionList.Array seq) (compiler-ir-function-seq-count seq)]))

(define (compiler-ir-function-list-block-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (+
        (compiler-ir-function-block-count func)
        (compiler-ir-function-list-block-count (box-get rest)))]
    [(CompilerIrFunctionList.Array seq)
      (compiler-ir-function-seq-block-count seq)]))

(define (compiler-ir-function-list-instruction-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (+
        (compiler-ir-function-instruction-count func)
        (compiler-ir-function-list-instruction-count (box-get rest)))]
    [(CompilerIrFunctionList.Array seq)
      (compiler-ir-function-seq-instruction-count seq)]))

(define (compiler-ir-function-list-empty-block-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (+
        (compiler-ir-function-empty-block-count func)
        (compiler-ir-function-list-empty-block-count (box-get rest)))]
    [(CompilerIrFunctionList.Array seq)
      (compiler-ir-function-seq-empty-block-count seq)]))

(define (compiler-ir-function-list-max-instruction-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (compiler-ir-max-i64
        (compiler-ir-function-max-instruction-count func)
        (compiler-ir-function-list-max-instruction-count (box-get rest)))]
    [(CompilerIrFunctionList.Array seq)
      (compiler-ir-function-seq-max-instruction-count seq)]))

(define (compiler-ir-function-list-max-block-instruction-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (compiler-ir-max-i64
        (compiler-ir-function-max-block-instruction-count func)
        (compiler-ir-function-list-max-block-instruction-count (box-get rest)))]
    [(CompilerIrFunctionList.Array seq)
      (compiler-ir-function-seq-max-block-instruction-count seq)]))

(define (compiler-ir-function-list-call-arg-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (+
        (compiler-ir-function-call-arg-count func)
        (compiler-ir-function-list-call-arg-count (box-get rest)))]
    [(CompilerIrFunctionList.Array seq)
      (compiler-ir-function-seq-call-arg-count seq)]))

(define (compiler-ir-function-list-phi-input-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (+
        (compiler-ir-function-phi-input-count func)
        (compiler-ir-function-list-phi-input-count (box-get rest)))]
    [(CompilerIrFunctionList.Array seq)
      (compiler-ir-function-seq-phi-input-count seq)]))

(define (compiler-ir-function-list-var-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (+
        (compiler-ir-function-var-count func)
        (compiler-ir-function-list-var-count (box-get rest)))]
    [(CompilerIrFunctionList.Array seq)
      (compiler-ir-function-seq-var-count seq)]))

(define (compiler-ir-program-summary [program : CompilerIrProgram]) : CompilerIrSummary
  (match program
    [(CompilerIrProgram.Program globals functions externs)
      (CompilerIrSummary.Summary
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
    [(AstTypeList.Nil) ""]
    [(AstTypeList.Cons head tail)
      (let
        [head : AstType (ast-node-pool-reader-type-get head)]
        [tail : AstTypeList (box-get tail)]
        (str_cat.str-cat
          " "
          (compiler-ir-type-name head)
          (compiler-ir-type-list-name tail)))]))

(define (compiler-ir-type-name [ty : AstType]) : String
  (match ty
    [(AstType.I64) "i64"]
    [(AstType.I32) "i32"]
    [(AstType.I16) "i16"]
    [(AstType.I8) "i8"]
    [(AstType.U64) "u64"]
    [(AstType.U32) "u32"]
    [(AstType.U16) "u16"]
    [(AstType.U8) "u8"]
    [(AstType.F64) "f64"]
    [(AstType.F32) "f32"]
    [(AstType.Bool) "bool"]
    [(AstType.Char) "char"]
    [(AstType.String) "String"]
    [(AstType.Str) "str"]
    [(AstType.Bytes) "bytes"]
    [(AstType.Unit) "unit"]
    [(AstType.Never) "never"]
    [(AstType.Expr) "Expr"]
    [(AstType.ExprList) "ExprList"]
    [(AstType.Func args ret)
      (str_cat.str-cat
        "(->"
        (compiler-ir-type-list-name (box-get args))
        " "
        (compiler-ir-type-name (ast-node-pool-reader-type-get ret))
        ")")]
    [(AstType.Tuple elems)
      (str_cat.str-cat
        "(Tuple"
        (compiler-ir-type-list-name (box-get elems))
        ")")]
    [(AstType.Array elem count)
      (str_cat.str-cat
        "(Array "
        (compiler-ir-type-name (ast-node-pool-reader-type-get elem))
        " "
        (string.int->string count)
        ")")]
    [(AstType.DynArray elem)
      (str_cat.str-cat
        "(Array "
        (compiler-ir-type-name (ast-node-pool-reader-type-get elem))
        ")")]
    [(AstType.Box elem)
      (str_cat.str-cat
        "(Box "
        (compiler-ir-type-name (ast-node-pool-reader-type-get elem))
        ")")]
    [(AstType.Region region inner)
      (str_cat.str-cat
        "(in "
        region
        " "
        (compiler-ir-type-name (ast-node-pool-reader-type-get inner))
        ")")]
    [(AstType.Ref region inner)
      (str_cat.str-cat
        "(& "
        region
        " "
        (compiler-ir-type-name (ast-node-pool-reader-type-get inner))
        ")")]
    [(AstType.MutRef region inner)
      (str_cat.str-cat
        "(&mut "
        region
        " "
        (compiler-ir-type-name (ast-node-pool-reader-type-get inner))
        ")")]
    [(AstType.Enum name) (intern-str name)]
    [(AstType.EnumArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstType.Struct name) (intern-str name)]
    [(AstType.StructArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstType.Var name) (str_cat.str-cat "'" (intern-str name) "'")]
    [(AstType.VarArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (intern-str name)
        (box-get lifetimes))]
    [(AstType.Ptr elem)
      (str_cat.str-cat
        "(Ptr "
        (compiler-ir-type-name (ast-node-pool-reader-type-get elem))
        ")")]
    [(AstType.MutPtr elem)
      (str_cat.str-cat
        "(MutPtr "
        (compiler-ir-type-name (ast-node-pool-reader-type-get elem))
        ")")]))

(define (compiler-ir-vector-type-name [elem : AstType] [lanes : i64]) : String
  (str_cat.str-cat
    "(Vector "
    (compiler-ir-type-name elem)
    " "
    (string.int->string lanes)
    ")"))

(define (compiler-ir-mask-type-name [lanes : i64]) : String
  (str_cat.str-cat "(Mask " (string.int->string lanes) ")"))

(define (compiler-ir-value-describe [value : CompilerIrValue]) : String
  (match value
    [(CompilerIrValue.Var id) (str_cat.str-cat "%" (string.int->string id) "")]
    [(CompilerIrValue.Global name) (str_cat.str-cat "@" name "")]
    [(CompilerIrValue.GlobalAddr name) (str_cat.str-cat "&@" name "")]
    [(CompilerIrValue.Function name) (str_cat.str-cat "fn@" name "")]
    [(CompilerIrValue.I64 n) (string.int->string n)]
    [(CompilerIrValue.F64 n)
      (str_cat.str-cat "float-bits:" (compiler-ir-u64-payload-render n))]
    [(CompilerIrValue.Bool b)
      (if b
        "true"
        "false")]
    [(CompilerIrValue.Char c) (string.int->string (cast c : i64))]
    [(CompilerIrValue.String s) s]
    [(CompilerIrValue.Bytes s)
      (str_cat.str-cat
        "<bytes:"
        (string.int->string (string.string-length s))
        ">")]
    [(CompilerIrValue.Unit) "unit"]))

(define (compiler-ir-value-list-describe [values : CompilerIrValueList]) : String
  (match values
    [(IrValueNil) ""]
    [(IrValueCons head tail)
      (match (box-get tail)
        [(IrValueNil) (compiler-ir-value-describe head)]
        [_
          (str_cat.str-cat
            (compiler-ir-value-describe head)
            ", "
            (compiler-ir-value-list-describe (box-get tail)))])]))

(define (compiler-ir-call-args-array-describe
  [values : (Array CompilerIrValue)]
  [index : i64]) : String
  (if (>= index (array-length values))
    ""
    (str_cat.str-cat
      (compiler-ir-value-describe (array-ref values index))
      (if (= (+ index 1) (array-length values))
        ""
        (str_cat.str-cat
          ", "
          (compiler-ir-call-args-array-describe values (+ index 1)))))))

(define (compiler-ir-call-args-describe [args : CompilerIrCallArgs]) : String
  (match args
    [(CompilerIrCallArgs.Nil) ""]
    [(CompilerIrCallArgs.One a) (compiler-ir-value-describe a)]
    [(CompilerIrCallArgs.Two a b)
      (str_cat.str-cat
        (compiler-ir-value-describe a)
        ", "
        (compiler-ir-value-describe b))]
    [(CompilerIrCallArgs.Array values)
      (compiler-ir-call-args-array-describe values 0)]))

(define (compiler-ir-spmd-call-arg-describe [arg : CompilerIrSpmdCallArg]) : String
  (match arg
    [(IrSpmdCallArg class value ty)
      (str_cat.str-cat
        (compiler-ir-spmd-value-class-render class)
        " "
        (compiler-ir-value-describe value)
        " : "
        (compiler-ir-type-name ty))]))

(define (compiler-ir-spmd-call-args-describe [args : CompilerIrSpmdCallArgList]) : String
  (match args
    [(IrSpmdCallArgNil) ""]
    [(IrSpmdCallArgCons arg rest)
      (match (box-get rest)
        [(IrSpmdCallArgNil) (compiler-ir-spmd-call-arg-describe arg)]
        [_
          (str_cat.str-cat
            (compiler-ir-spmd-call-arg-describe arg)
            ", "
            (compiler-ir-spmd-call-args-describe (box-get rest)))])]))

(define (compiler-ir-spmd-call-result-describe
  [result : CompilerIrSpmdCallResult]) : String
  (match result
    [(IrSpmdCallResultUnit) "unit"]
    [(IrSpmdCallResultValue dst class ty)
      (str_cat.str-cat
        (compiler-ir-value-describe (CompilerIrValue.Var dst))
        " : "
        (compiler-ir-spmd-value-class-render class)
        " "
        (compiler-ir-type-name ty))]))

(define (compiler-ir-binop-name [op : CompilerIrBinOp]) : String
  (match op
    [(CompilerIrBinOp.Add) "add"]
    [(CompilerIrBinOp.Sub) "sub"]
    [(CompilerIrBinOp.Mul) "mul"]
    [(CompilerIrBinOp.Div) "div"]
    [(CompilerIrBinOp.Mod) "mod"]
    [(CompilerIrBinOp.SafeDiv) "safe_div"]
    [(CompilerIrBinOp.SafeMod) "safe_mod"]
    [(CompilerIrBinOp.Eq) "eq"]
    [(CompilerIrBinOp.Ne) "ne"]
    [(CompilerIrBinOp.Lt) "lt"]
    [(CompilerIrBinOp.Le) "le"]
    [(CompilerIrBinOp.Gt) "gt"]
    [(CompilerIrBinOp.Ge) "ge"]
    [(CompilerIrBinOp.And) "and"]
    [(CompilerIrBinOp.Or) "or"]
    [(CompilerIrBinOp.BitAnd) "bitand"]
    [(CompilerIrBinOp.BitOr) "bitor"]
    [(CompilerIrBinOp.BitXor) "bitxor"]
    [(CompilerIrBinOp.Shl) "shl"]
    [(CompilerIrBinOp.Shr) "shr"]))

(define (compiler-ir-mask-binop-name [op : CompilerIrMaskBinOp]) : String
  (match op
    [(CompilerIrMaskBinOp.And) "mask_and"]
    [(CompilerIrMaskBinOp.Or) "mask_or"]))

(define (compiler-ir-vector-reduce-op-name [op : CompilerIrVectorReduceOp]) : String
  (match op
    [(CompilerIrVectorReduceOp.Sum) "sum"]
    [(CompilerIrVectorReduceOp.Min) "min"]
    [(CompilerIrVectorReduceOp.Max) "max"]))

(define (compiler-ir-mask-reduce-op-name [op : CompilerIrMaskReduceOp]) : String
  (match op
    [(CompilerIrMaskReduceOp.All) "all"]
    [(CompilerIrMaskReduceOp.Any) "any"]))

(define (compiler-ir-lane-type-name [lanes : i64] [elem : AstType]) : String
  (str_cat.str-cat
    (string.int->string lanes)
    " x "
    (compiler-ir-type-name elem)))

(define (compiler-ir-vector-suffix [lanes : i64] [elem : AstType]) : String
  (str_cat.str-cat " : " (compiler-ir-lane-type-name lanes elem) ""))

(define (compiler-ir-instr-describe [instr : CompilerIrInstr]) : String
  (match instr
    [(CompilerIrInstr.LaneId dst lanes ty)
      (str_cat.str-cat
        "  "
        (compiler-ir-value-describe (CompilerIrValue.Var dst))
        " = lane_id "
        (compiler-ir-lane-type-name lanes ty)
        "")]
    [(CompilerIrInstr.Splat dst value lanes ty)
      (str_cat.str-cat
        "  "
        (compiler-ir-value-describe (CompilerIrValue.Var dst))
        " = splat "
        (compiler-ir-value-describe value)
        (compiler-ir-vector-suffix lanes ty)
        "")]
    [(CompilerIrInstr.VectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload.Payload
            dst
            op
            lhs
            rhs
            lanes
            elem-ty)
          (str_cat.str-cat
            "  "
            (compiler-ir-value-describe (CompilerIrValue.Var dst))
            " = vector_"
            (compiler-ir-binop-name op)
            " "
            (compiler-ir-value-describe lhs)
            ", "
            (compiler-ir-value-describe rhs)
            (compiler-ir-vector-suffix lanes elem-ty))])]
    [(CompilerIrInstr.VectorReduce dst op src lanes elem-ty)
      (str_cat.str-cat
        "  "
        (compiler-ir-value-describe (CompilerIrValue.Var dst))
        " = vector_reduce_"
        (compiler-ir-vector-reduce-op-name op)
        " "
        (compiler-ir-value-describe src)
        (compiler-ir-vector-suffix lanes elem-ty))]
    [(CompilerIrInstr.VectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload.Payload
            dst
            op
            lhs
            rhs
            lanes
            elem-ty)
          (str_cat.str-cat
            "  "
            (compiler-ir-value-describe (CompilerIrValue.Var dst))
            " = vector_cmp_"
            (compiler-ir-binop-name op)
            " "
            (compiler-ir-value-describe lhs)
            ", "
            (compiler-ir-value-describe rhs)
            (compiler-ir-vector-suffix lanes elem-ty))])]
    [(CompilerIrInstr.MaskBinOp dst op lhs rhs lanes)
      (str_cat.str-cat
        "  "
        (compiler-ir-value-describe (CompilerIrValue.Var dst))
        " = "
        (compiler-ir-mask-binop-name op)
        " "
        (compiler-ir-value-describe lhs)
        ", "
        (compiler-ir-value-describe rhs)
        " : "
        (string.int->string lanes))]
    [(CompilerIrInstr.MaskNot dst src lanes)
      (str_cat.str-cat
        "  "
        (compiler-ir-value-describe (CompilerIrValue.Var dst))
        " = mask_not "
        (compiler-ir-value-describe src)
        " : "
        (string.int->string lanes))]
    [(CompilerIrInstr.MaskReduce dst op src lanes)
      (str_cat.str-cat
        "  "
        (compiler-ir-value-describe (CompilerIrValue.Var dst))
        " = mask_reduce_"
        (compiler-ir-mask-reduce-op-name op)
        " "
        (compiler-ir-value-describe src)
        " : "
        (string.int->string lanes))]
    [(CompilerIrInstr.Select payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload.Payload
            dst
            mask
            on-true
            on-false
            lanes
            ty)
          (str_cat.str-cat
            "  "
            (compiler-ir-value-describe (CompilerIrValue.Var dst))
            " = select "
            (compiler-ir-value-describe mask)
            ", "
            (compiler-ir-value-describe on-true)
            ", "
            (compiler-ir-value-describe on-false)
            (compiler-ir-vector-suffix lanes ty))])]
    [(CompilerIrInstr.VectorLoad dst base index lanes elem-ty)
      (str_cat.str-cat
        "  "
        (compiler-ir-value-describe (CompilerIrValue.Var dst))
        " = vector_load "
        (compiler-ir-value-describe base)
        ", "
        (compiler-ir-value-describe index)
        (compiler-ir-vector-suffix lanes elem-ty))]
    [(CompilerIrInstr.VectorStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorStorePayload.Payload
            base
            index
            value
            lanes
            elem-ty)
          (str_cat.str-cat
            "  vector_store "
            (compiler-ir-value-describe base)
            ", "
            (compiler-ir-value-describe index)
            ", "
            (compiler-ir-value-describe value)
            (compiler-ir-vector-suffix lanes elem-ty))])]
    [(CompilerIrInstr.PredicatedStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedStorePayload.Payload
            base
            index
            value
            mask
            lanes
            elem-ty)
          (str_cat.str-cat
            "  predicated_store "
            (compiler-ir-value-describe base)
            ", "
            (compiler-ir-value-describe index)
            ", "
            (compiler-ir-value-describe value)
            ", "
            (compiler-ir-value-describe mask)
            (compiler-ir-vector-suffix lanes elem-ty))])]
    [(CompilerIrInstr.PredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload.Payload
            dst
            base
            index
            mask
            lanes
            elem-ty)
          (str_cat.str-cat
            "  "
            (compiler-ir-value-describe (CompilerIrValue.Var dst))
            " = predicated_load "
            (compiler-ir-value-describe base)
            ", "
            (compiler-ir-value-describe index)
            ", "
            (compiler-ir-value-describe mask)
            (compiler-ir-vector-suffix lanes elem-ty))])]
    [(CompilerIrInstr.TailMask dst index len lanes)
      (str_cat.str-cat
        "  "
        (compiler-ir-value-describe (CompilerIrValue.Var dst))
        " = tail_mask "
        (compiler-ir-value-describe index)
        ", "
        (compiler-ir-value-describe len)
        " : "
        (string.int->string lanes))]
    [(IrInstrSpmdCall payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSpmdCallPayload
            callee
            backend
            lanes
            active-mask
            args
            result)
          (str_cat.str-cat
            "  spmd_call "
            callee
            " backend "
            (compiler-ir-spmd-backend-render backend)
            " lanes "
            (string.int->string lanes)
            " mask "
            (compiler-ir-value-describe active-mask)
            "("
            (compiler-ir-spmd-call-args-describe args)
            ") -> "
            (compiler-ir-spmd-call-result-describe result))])]
    [(CompilerIrInstr.Switch index base cases default-label)
      (str_cat.str-cat
        "  switch "
        (compiler-ir-value-describe index)
        " base "
        (string.int->string base)
        " ["
        (compiler-ir-switch-case-list-render cases)
        "] default "
        default-label)]
    [_ "non-vector-mask-instr"]))

(define (compiler-ir-value-var-eq? [value : CompilerIrValue] [want : i64]) : bool
  (match value
    [(CompilerIrValue.Var id) (= id want)]
    [_ false]))

(define (compiler-ir-effect-is?
  [instr : CompilerIrInstr]
  [effect : CompilerIrEffect]) : bool
  (compiler-ir-effect-eq? (compiler-ir-instr-effect instr) effect))

(define (compiler-ir-instruction-effects-ok?) : bool
  (and
    (compiler-ir-effect-is?
      (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 1) (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is? (CompilerIrInstr.AddrOf 1 0) CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Cast
        3
        (CompilerIrValue.Var 2)
        (AstType.I64)
        (AstType.I32))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.BinOp
        4
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.UnOp
        5
        (CompilerIrUnOp.Neg)
        (CompilerIrValue.Var 4)
        (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Phi
        6
        (compiler-ir-phi-input-cons
          (CompilerIrValue.I64 1)
          "entry"
          (CompilerIrPhiInputList.Nil))
        (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Load 7 (CompilerIrValue.Var 1) (AstType.I64))
      CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Alloc 8 (AstType.I64))
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-is?
      (CompilerIrInstr.StorePtr
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 2)
        (AstType.I64))
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-is?
      (CompilerIrInstr.CopyBytes
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 2)
        16)
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Store "global" (CompilerIrValue.I64 3) (AstType.I64))
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Call
        9
        "tl_region_mark"
        (CompilerIrCallArgs.Nil)
        (AstType.I64))
      CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-is?
      (CompilerIrInstr.CpuId
        10
        (CompilerIrValue.I64 1)
        (CompilerIrValue.I64 0)
        0)
      CompilerIrEffect.CpuProbe)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Xgetbv 11 (CompilerIrValue.I64 0))
      CompilerIrEffect.CpuProbe)
    (compiler-ir-effect-is?
      (CompilerIrInstr.BoundsCheck
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        "bounds_ok")
      CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-is?
      (CompilerIrInstr.TailCall
        "fact_loop"
        (CompilerIrCallArgs.Two (CompilerIrValue.Var 3) (CompilerIrValue.I64 1))
        (AstType.I64))
      CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Jump "done")
      CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Branch (CompilerIrValue.Bool true) "then" "else")
      CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Switch
        (CompilerIrValue.Var 0)
        1
        (compiler-ir-switch-case-cons
          1
          "one"
          (compiler-ir-switch-case-cons 2 "two" IrSwitchCaseNil))
        "default")
      CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Return
        (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
      CompilerIrEffect.ControlFlow)))

(define (compiler-ir-vector-mask-effects-ok?) : bool
  (and
    (compiler-ir-effect-is?
      (CompilerIrInstr.LaneId 20 4 (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.Splat 21 (CompilerIrValue.Var 0) 4 (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (ir-instr-vector-bin-op
        22
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 20)
        (CompilerIrValue.Var 21)
        4
        (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.VectorReduce
        23
        (CompilerIrVectorReduceOp.Sum)
        (CompilerIrValue.Var 22)
        4
        (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (ir-instr-vector-compare
        24
        (CompilerIrBinOp.Lt)
        (CompilerIrValue.Var 20)
        (CompilerIrValue.Var 21)
        4
        (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.MaskBinOp
        25
        (CompilerIrMaskBinOp.And)
        (CompilerIrValue.Var 24)
        (CompilerIrValue.Var 24)
        4)
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.MaskNot 26 (CompilerIrValue.Var 25) 4)
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.MaskReduce
        27
        (CompilerIrMaskReduceOp.Any)
        (CompilerIrValue.Var 26)
        4)
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (ir-instr-select
        28
        (CompilerIrValue.Var 24)
        (CompilerIrValue.Var 20)
        (CompilerIrValue.Var 21)
        4
        (AstType.I64))
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.TailMask
        29
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        4)
      CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (CompilerIrInstr.VectorLoad
        30
        (CompilerIrValue.Var 2)
        (CompilerIrValue.Var 0)
        4
        (AstType.I64))
      CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-is?
      (ir-instr-predicated-load
        31
        (CompilerIrValue.Var 2)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 29)
        4
        (AstType.I64))
      CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-is?
      (ir-instr-vector-store
        (CompilerIrValue.Var 2)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 22)
        4
        (AstType.I64))
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-is?
      (ir-instr-predicated-store
        (CompilerIrValue.Var 2)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 22)
        (CompilerIrValue.Var 29)
        4
        (AstType.I64))
      CompilerIrEffect.MemoryWrite)))

(define (compiler-ir-runtime-effects-ok?) : bool
  (and
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect "tl_region_mark")
      CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect ".L_tl_stdin_eof")
      CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect "tl_alloc")
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect ".L_tl_flush_stdout")
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect ".L_tl_abort")
      CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect "tl_shift_abort")
      CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect ".L_tl_arg_count")
      CompilerIrEffect.Unknown)
    (compiler-ir-effect-eq?
      (compiler-ir-direct-call-effect "user_or_extern_call")
      CompilerIrEffect.Unknown)))

(define (compiler-ir-effect-predicates-ok?) : bool
  (and
    (not (compiler-ir-effect-has-side-effect? CompilerIrEffect.Pure))
    (not (compiler-ir-effect-has-side-effect? CompilerIrEffect.MemoryRead))
    (compiler-ir-effect-has-side-effect? CompilerIrEffect.CpuProbe)
    (compiler-ir-effect-has-side-effect? CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-has-side-effect? CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-has-side-effect? CompilerIrEffect.Unknown)
    (not (compiler-ir-effect-invalidates-cse? CompilerIrEffect.Pure))
    (compiler-ir-effect-invalidates-cse? CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-invalidates-cse? CompilerIrEffect.CpuProbe)
    (compiler-ir-effect-invalidates-cse? CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-invalidates-cse? CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-invalidates-cse? CompilerIrEffect.Unknown)))

(define (compiler-ir-display-type-names-ok?) : bool
  (and
    (string.eq (compiler-ir-vector-type-name (AstType.I32) 8) "(Vector i32 8)")
    (string.eq (compiler-ir-mask-type-name 8) "(Mask 8)")))

(define (compiler-ir-display-op-names-ok?) : bool
  (and
    (string.eq
      (compiler-ir-vector-reduce-op-name CompilerIrVectorReduceOp.Sum)
      "sum")
    (string.eq
      (compiler-ir-vector-reduce-op-name CompilerIrVectorReduceOp.Min)
      "min")
    (string.eq
      (compiler-ir-vector-reduce-op-name CompilerIrVectorReduceOp.Max)
      "max")
    (string.eq
      (compiler-ir-mask-reduce-op-name CompilerIrMaskReduceOp.All)
      "all")
    (string.eq
      (compiler-ir-mask-reduce-op-name CompilerIrMaskReduceOp.Any)
      "any")
    (string.eq (compiler-ir-mask-binop-name CompilerIrMaskBinOp.And) "mask_and")
    (string.eq (compiler-ir-mask-binop-name CompilerIrMaskBinOp.Or) "mask_or")))

(define (compiler-ir-display-instrs-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (string.eq
        (compiler-ir-instr-describe (CompilerIrInstr.LaneId 0 4 (AstType.I64)))
        "  %0 = lane_id 4 x i64")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (CompilerIrInstr.Splat 1 (CompilerIrValue.I64 7) 4 (AstType.I64)))
        "  %1 = splat 7 : 4 x i64")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (ir-instr-vector-bin-op
            2
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            4
            (AstType.I64)))
        "  %2 = vector_add %0, %1 : 4 x i64")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (CompilerIrInstr.VectorReduce
            8
            (CompilerIrVectorReduceOp.Sum)
            (CompilerIrValue.Var 2)
            4
            (AstType.I64)))
        "  %8 = vector_reduce_sum %2 : 4 x i64")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (ir-instr-vector-compare
            3
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            4
            (AstType.I64)))
        "  %3 = vector_cmp_lt %0, %1 : 4 x i64")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (CompilerIrInstr.MaskBinOp
            4
            (CompilerIrMaskBinOp.Or)
            (CompilerIrValue.Var 3)
            (CompilerIrValue.Var 3)
            4))
        "  %4 = mask_or %3, %3 : 4")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (CompilerIrInstr.MaskNot 5 (CompilerIrValue.Var 4) 4))
        "  %5 = mask_not %4 : 4")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (CompilerIrInstr.MaskReduce
            9
            (CompilerIrMaskReduceOp.Any)
            (CompilerIrValue.Var 5)
            4))
        "  %9 = mask_reduce_any %5 : 4")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (ir-instr-select
            6
            (CompilerIrValue.Var 5)
            (CompilerIrValue.Var 2)
            (CompilerIrValue.Var 1)
            4
            (AstType.I64)))
        "  %6 = select %5, %2, %1 : 4 x i64")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (CompilerIrInstr.VectorLoad
            7
            (CompilerIrValue.Var 10)
            (CompilerIrValue.Var 11)
            4
            (AstType.I64)))
        "  %7 = vector_load %10, %11 : 4 x i64")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (ir-instr-vector-store
            (CompilerIrValue.Var 12)
            (CompilerIrValue.Var 11)
            (CompilerIrValue.Var 6)
            4
            (AstType.I64)))
        "  vector_store %12, %11, %6 : 4 x i64")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (ir-instr-predicated-store
            (CompilerIrValue.Var 12)
            (CompilerIrValue.Var 11)
            (CompilerIrValue.Var 6)
            (CompilerIrValue.Var 5)
            4
            (AstType.I64)))
        "  predicated_store %12, %11, %6, %5 : 4 x i64")
        unit
        (set! ok false))
      (if (string.eq
        (compiler-ir-instr-describe
          (ir-instr-predicated-load
            10
            (CompilerIrValue.Var 12)
            (CompilerIrValue.Var 11)
            (CompilerIrValue.Var 5)
            4
            (AstType.I64)))
        "  %10 = predicated_load %12, %11, %5 : 4 x i64")
        unit
        (set! ok false))
      ok)))

(define (compiler-ir-display-tail-mask-ok?) : bool
  (let
    [instr : CompilerIrInstr
      (CompilerIrInstr.TailMask
        9
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 2)
        8)]
    (and
      (string.eq
        (compiler-ir-instr-describe instr)
        "  %9 = tail_mask %1, %2 : 8")
      (compiler-ir-effect-is? instr CompilerIrEffect.Pure)
      (match instr
        [(CompilerIrInstr.TailMask dst index len lanes)
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
  (string.eq
    (compiler-ir-instr-render
      (CompilerIrInstr.TailCall
        "fact_loop"
        (CompilerIrCallArgs.Two (CompilerIrValue.Var 3) (CompilerIrValue.I64 1))
        (AstType.I64)))
    "  tailcall fact_loop(%3, 1) : i64"))

(define (compiler-ir-switch-render-ok?) : bool
  (let
    [cases : CompilerIrSwitchCaseList
      (compiler-ir-switch-case-cons
        4
        "four"
        (compiler-ir-switch-case-cons 5 "five" IrSwitchCaseNil))]
    [instr : CompilerIrInstr
      (CompilerIrInstr.Switch (CompilerIrValue.Var 9) 4 cases "other")]
    (and
      (string.eq
        (compiler-ir-instr-render instr)
        "  switch %9 base 4 [4:four, 5:five] default other")
      (string.eq
        (compiler-ir-instr-describe instr)
        "  switch %9 base 4 [4:four, 5:five] default other"))))

(define (compiler-ir-source-spans-boxed-list-ok?) : bool
  (let
    [span1 : AstSourceSpan (AstSourceSpan 1 2 1 3)]
    [span2 : AstSourceSpan (AstSourceSpan 4 5 4 8)]
    [entries : CompilerSourceSpansEntryList
      (compiler-source-spans-entry-list-append
        (compiler-source-spans-entry-list-append
          (CompilerSourceSpansEntryList.Nil)
          (CompilerSourceSpansEntry.Entry "first" span1))
        (CompilerSourceSpansEntry.Entry "second" span2))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert
        (compiler-source-spans-insert (compiler-source-spans-empty) "one" span1)
        "two"
        span2)]
    (and
      (= (compiler-source-spans-entry-list-count entries) 2)
      (= (compiler-source-spans-count spans) 2)
      (match (compiler-source-spans-entry-list-lookup entries "second")
        [(CompilerMaybeSourceSpan.Some found)
          (and
            (= (struct-get found start-line) 4)
            (= (struct-get found end-col) 8))]
        [(CompilerMaybeSourceSpan.No) false]))))

(define (compiler-ir-instr-list-first-mov-dst?
  [instrs : CompilerIrInstrList]
  [want : i64]) : bool
  (match instrs
    [(CompilerIrInstrList.Nil) false]
    [(CompilerIrInstrList.Cons instr _)
      (match instr
        [(CompilerIrInstr.Mov dst _ _) (= dst want)]
        [_ false])]))

(define (compiler-ir-instr-seq-mov-dst?
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [want : i64]) : bool
  (match (compiler-ir-instr-seq-ref instrs index)
    [(CompilerIrInstr.Mov dst _ _) (= dst want)]
    [_ false]))

(define (compiler-ir-instr-seq-return-var?
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [want : i64]) : bool
  (match (compiler-ir-instr-seq-ref instrs index)
    [(CompilerIrInstr.Return
        (CompilerIrMaybeValue.Some (CompilerIrValue.Var var)))
      (= var want)]
    [_ false]))

(define (compiler-ir-instr-seq-test-rewrite [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(CompilerIrInstr.Mov dst value ty)
      (CompilerIrInstr.Mov (+ dst 10) value ty)]
    [(CompilerIrInstr.Alloc dst ty) (CompilerIrInstr.Alloc dst ty)]
    [(CompilerIrInstr.Return value) (CompilerIrInstr.Return value)]
    [_ instr]))

(define (compiler-ir-instr-seq-test-keep-non-alloc? [instr : CompilerIrInstr]) : bool
  (match instr
    [(CompilerIrInstr.Alloc _ _) false]
    [_ true]))

(define (compiler-ir-instr-seq-mutable-rewrite-ok?) : bool
  (let
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 20) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
            CompilerIrInstrList.Nil)))]
    [seq : CompilerIrInstrSeq (compiler-ir-instr-seq-from-list instrs)]
    (begin
      (compiler-ir-instr-seq-rewrite! seq compiler-ir-instr-seq-test-rewrite)
      (and
        (= (compiler-ir-instr-seq-count seq) 3)
        (compiler-ir-instr-seq-mov-dst? seq 0 11)
        (compiler-ir-instr-seq-mov-dst? seq 1 12)
        (compiler-ir-instr-seq-return-var? seq 2 2)))))

(define (compiler-ir-instr-seq-mutable-compact-ok?) : bool
  (let
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Alloc 9 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 20) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
              CompilerIrInstrList.Nil))))]
    [seq : CompilerIrInstrSeq (compiler-ir-instr-seq-from-list instrs)]
    [roundtrip : CompilerIrInstrList CompilerIrInstrList.Nil]
    (begin
      (compiler-ir-instr-seq-compact!
        seq
        compiler-ir-instr-seq-test-keep-non-alloc?)
      (set! roundtrip (compiler-ir-instr-seq-to-list seq))
      (and
        (= (compiler-ir-instr-seq-count seq) 3)
        (= (compiler-ir-instr-list-count roundtrip) 3)
        (compiler-ir-instr-seq-mov-dst? seq 0 1)
        (compiler-ir-instr-seq-mov-dst? seq 1 2)
        (compiler-ir-instr-seq-return-var? seq 2 2)))))

(define (compiler-ir-block-list-first-label?
  [blocks : CompilerIrBlockList]
  [want : String]) : bool
  (match (compiler-ir-block-list-force-cons blocks)
    [(CompilerIrBlockList.Cons block _)
      (match block
        [(CompilerIrBlock.Block label _) (string.eq label want)])]
    [(CompilerIrBlockList.Nil) false]
    [(CompilerIrBlockList.Array _) false]))

(define (compiler-ir-instr-seq-roundtrip-ok?) : bool
  (let
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 20) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
            CompilerIrInstrList.Nil)))]
    [seq : CompilerIrInstrSeq (compiler-ir-instr-seq-from-list instrs)]
    [roundtrip : CompilerIrInstrList (compiler-ir-instr-seq-to-list seq)]
    [block-list : CompilerIrBlockList
      (compiler-ir-block-cons
        (compiler-ir-block "entry" instrs)
        CompilerIrBlockList.Nil)]
    [compact-blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact block-list)]
    (and
      (= (compiler-ir-instr-seq-count seq) 3)
      (not (compiler-ir-instr-seq-empty? seq))
      (match (compiler-ir-instr-seq-ref seq 2)
        [(CompilerIrInstr.Return _) true]
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
    (unless (compiler-ir-instr-seq-mutable-rewrite-ok?) (return 1))
    (unless (compiler-ir-instr-seq-mutable-compact-ok?) (return 1))
    42))