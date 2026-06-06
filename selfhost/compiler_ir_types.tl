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
  (IrValueGlobalAddr String)
  (IrValueFunction String)
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
  (IrValueCons CompilerIrValue (Box CompilerIrValueList)))

(defenum CompilerIrCallArgs
  (IrCallArgsNil)
  (IrCallArgsOne CompilerIrValue)
  (IrCallArgsTwo CompilerIrValue CompilerIrValue)
  (IrCallArgsArray (Array CompilerIrValue)))

(defenum CompilerIrPhiInputList
  (IrPhiInputNil)
  (IrPhiInputCons CompilerIrValue String (Box CompilerIrPhiInputList)))

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
  (IrInstrEntryArgc i64)
  (IrInstrEntryArgv i64)
  (IrInstrEntryEnvp i64)
  (IrInstrCpuId i64 CompilerIrValue CompilerIrValue i64)
  (IrInstrXgetbv i64 CompilerIrValue)
  (IrInstrCall i64 String CompilerIrCallArgs AstType)
  (IrInstrCallIndirect i64 CompilerIrValue CompilerIrCallArgs AstType)
  (IrInstrTailCall String CompilerIrCallArgs AstType)
  (IrInstrStore String CompilerIrValue AstType)
  (IrInstrJump String)
  (IrInstrBranch CompilerIrValue String String)
  (IrInstrReturn CompilerIrMaybeValue)
  (IrInstrPhi i64 CompilerIrPhiInputList AstType))

(defenum CompilerIrInstrList
  (IrInstrNil)
  (IrInstrCons CompilerIrInstr (Box CompilerIrInstrList)))

(defstruct CompilerIrInstrSeq
  (slots (Array CompilerIrInstr))
  (len i64))

(defenum CompilerIrBlock
  (IrBlock String CompilerIrInstrSeq))

(defenum CompilerIrBlockList
  (IrBlockNil)
  (IrBlockCons CompilerIrBlock (Box CompilerIrBlockList)))

(defenum CompilerIrParam
  (IrParam String AstType i64))

(defenum CompilerIrParamList
  (IrParamNil)
  (IrParamCons CompilerIrParam (Box CompilerIrParamList)))

(defenum CompilerIrFunction
  (IrFunction String CompilerIrParamList AstType i64 CompilerIrBlockList))

(defenum CompilerIrFunctionList
  (IrFunctionNil)
  (IrFunctionCons CompilerIrFunction (Box CompilerIrFunctionList)))

(defenum CompilerIrGlobal
  (IrGlobal String AstType CompilerIrValue))

(defenum CompilerIrGlobalList
  (IrGlobalNil)
  (IrGlobalCons CompilerIrGlobal (Box CompilerIrGlobalList)))

(defenum CompilerIrExtern
  (IrExtern String AstType AstExternAbi String AstExternLinkInputList))

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

(define (compiler-ir-instr-seq-ref [instrs : CompilerIrInstrSeq] [index : i64]) : CompilerIrInstr
  (array-ref (struct-get instrs slots) index))

(define (compiler-ir-block [label : String] [instrs : CompilerIrInstrList]) : CompilerIrBlock
  (IrBlock label (compiler-ir-instr-seq-from-list instrs)))

(define (compiler-ir-block-cons
  [block : CompilerIrBlock]
  [rest : CompilerIrBlockList]) : CompilerIrBlockList
  (IrBlockCons block (box rest)))

(define (compiler-ir-param-cons
  [param : CompilerIrParam]
  [rest : CompilerIrParamList]) : CompilerIrParamList
  (IrParamCons param (box rest)))

(define (compiler-ir-function-cons
  [func : CompilerIrFunction]
  [rest : CompilerIrFunctionList]) : CompilerIrFunctionList
  (IrFunctionCons func (box rest)))

(define (compiler-ir-global-cons
  [global : CompilerIrGlobal]
  [rest : CompilerIrGlobalList]) : CompilerIrGlobalList
  (IrGlobalCons global (box rest)))

(define (compiler-ir-extern-cons
  [extern : CompilerIrExtern]
  [rest : CompilerIrExternList]) : CompilerIrExternList
  (IrExternCons extern (box rest)))

(define (compiler-ir-extern-default [name : String] [ty : AstType]) : CompilerIrExtern
  (IrExtern name ty (AstExternAbiC) name AstExternLinkInputNil))

(define (compiler-ir-clone-value [value : CompilerIrValue]) : CompilerIrValue
  (match value
    [(IrValueVar id) (IrValueVar id)]
    [(IrValueGlobal name) (IrValueGlobal (clone name))]
    [(IrValueGlobalAddr name) (IrValueGlobalAddr (clone name))]
    [(IrValueFunction name) (IrValueFunction (clone name))]
    [(IrValueI64 n) (IrValueI64 n)]
    [(IrValueF64 n) (IrValueF64 (clone n))]
    [(IrValueBool b) (IrValueBool b)]
    [(IrValueChar c) (IrValueChar c)]
    [(IrValueString s) (IrValueString (clone s))]
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

(define (compiler-ir-clone-instr [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrMov dst src ty)
      (IrInstrMov dst (compiler-ir-clone-value src) (clone ty))]
    [(IrInstrAlloc dst ty) (IrInstrAlloc dst (clone ty))]
    [(IrInstrAddrOf dst src) (IrInstrAddrOf dst src)]
    [(IrInstrGep dst base offset ty)
      (IrInstrGep
        dst
        (compiler-ir-clone-value base)
        (compiler-ir-clone-value offset)
        (clone ty))]
    [(IrInstrLoad dst src ty)
      (IrInstrLoad dst (compiler-ir-clone-value src) (clone ty))]
    [(IrInstrStorePtr dst src ty)
      (IrInstrStorePtr
        (compiler-ir-clone-value dst)
        (compiler-ir-clone-value src)
        (clone ty))]
    [(IrInstrBoundsCheck index length label)
      (IrInstrBoundsCheck
        (compiler-ir-clone-value index)
        (compiler-ir-clone-value length)
        (clone label))]
    [(IrInstrCast dst src from-ty to-ty)
      (IrInstrCast
        dst
        (compiler-ir-clone-value src)
        (clone from-ty)
        (clone to-ty))]
    [(IrInstrBinOp dst op lhs rhs ty)
      (IrInstrBinOp
        dst
        op
        (compiler-ir-clone-value lhs)
        (compiler-ir-clone-value rhs)
        (clone ty))]
    [(IrInstrUnOp dst op src ty)
      (IrInstrUnOp dst op (compiler-ir-clone-value src) (clone ty))]
    [(IrInstrLaneId dst lane ty) (IrInstrLaneId dst lane (clone ty))]
    [(IrInstrSplat dst value lanes ty)
      (IrInstrSplat dst (compiler-ir-clone-value value) lanes (clone ty))]
    [(IrInstrVectorBinOp dst op lhs rhs lanes ty)
      (IrInstrVectorBinOp
        dst
        op
        (compiler-ir-clone-value lhs)
        (compiler-ir-clone-value rhs)
        lanes
        (clone ty))]
    [(IrInstrVectorReduce dst op src lanes ty)
      (IrInstrVectorReduce
        dst
        op
        (compiler-ir-clone-value src)
        lanes
        (clone ty))]
    [(IrInstrVectorCompare dst op lhs rhs lanes ty)
      (IrInstrVectorCompare
        dst
        op
        (compiler-ir-clone-value lhs)
        (compiler-ir-clone-value rhs)
        lanes
        (clone ty))]
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
    [(IrInstrSelect dst cond then-value else-value lanes ty)
      (IrInstrSelect
        dst
        (compiler-ir-clone-value cond)
        (compiler-ir-clone-value then-value)
        (compiler-ir-clone-value else-value)
        lanes
        (clone ty))]
    [(IrInstrVectorLoad dst base index lanes ty)
      (IrInstrVectorLoad
        dst
        (compiler-ir-clone-value base)
        (compiler-ir-clone-value index)
        lanes
        (clone ty))]
    [(IrInstrVectorStore base index value lanes ty)
      (IrInstrVectorStore
        (compiler-ir-clone-value base)
        (compiler-ir-clone-value index)
        (compiler-ir-clone-value value)
        lanes
        (clone ty))]
    [(IrInstrPredicatedStore base index value mask lanes ty)
      (IrInstrPredicatedStore
        (compiler-ir-clone-value base)
        (compiler-ir-clone-value index)
        (compiler-ir-clone-value value)
        (compiler-ir-clone-value mask)
        lanes
        (clone ty))]
    [(IrInstrPredicatedLoad dst base index mask lanes ty)
      (IrInstrPredicatedLoad
        dst
        (compiler-ir-clone-value base)
        (compiler-ir-clone-value index)
        (compiler-ir-clone-value mask)
        lanes
        (clone ty))]
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
    [(IrInstrCall dst name args ty)
      (IrInstrCall
        dst
        (clone name)
        (compiler-ir-clone-call-args args)
        (clone ty))]
    [(IrInstrCallIndirect dst callee args ty)
      (IrInstrCallIndirect
        dst
        (compiler-ir-clone-value callee)
        (compiler-ir-clone-call-args args)
        (clone ty))]
    [(IrInstrTailCall name args ty)
      (IrInstrTailCall
        (clone name)
        (compiler-ir-clone-call-args args)
        (clone ty))]
    [(IrInstrStore name value ty)
      (IrInstrStore (clone name) (compiler-ir-clone-value value) (clone ty))]
    [(IrInstrJump label) (IrInstrJump (clone label))]
    [(IrInstrBranch cond true-label false-label)
      (IrInstrBranch
        (compiler-ir-clone-value cond)
        (clone true-label)
        (clone false-label))]
    [(IrInstrReturn value)
      (IrInstrReturn (compiler-ir-clone-maybe-value value))]
    [(IrInstrPhi dst inputs ty)
      (IrInstrPhi dst (compiler-ir-clone-phi-input-list inputs) (clone ty))]))

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
        (compiler-ir-block-cons (compiler-ir-clone-block block) acc))]))

(define (compiler-ir-block-list-reverse-onto
  [blocks : CompilerIrBlockList]
  [acc : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) acc]
    [(IrBlockCons block rest)
      (compiler-ir-block-list-reverse-onto
        (box-get rest)
        (compiler-ir-block-cons block acc))]))

(define (compiler-ir-clone-block-list [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (compiler-ir-block-list-reverse-onto
    (compiler-ir-clone-block-list-acc blocks IrBlockNil)
    IrBlockNil))

(define (compiler-ir-clone-param [param : CompilerIrParam]) : CompilerIrParam
  (match param
    [(IrParam name ty id) (IrParam (clone name) (clone ty) id)]))

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
        (compiler-ir-clone-block-list blocks))]))

(define (compiler-ir-clone-function-list-acc
  [functions : CompilerIrFunctionList]
  [acc : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) acc]
    [(IrFunctionCons func rest)
      (compiler-ir-clone-function-list-acc
        (box-get rest)
        (compiler-ir-function-cons (compiler-ir-clone-function func) acc))]))

(define (compiler-ir-function-list-reverse-onto
  [functions : CompilerIrFunctionList]
  [acc : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) acc]
    [(IrFunctionCons func rest)
      (compiler-ir-function-list-reverse-onto
        (box-get rest)
        (compiler-ir-function-cons func acc))]))

(define (compiler-ir-clone-function-list [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (compiler-ir-function-list-reverse-onto
    (compiler-ir-clone-function-list-acc functions IrFunctionNil)
    IrFunctionNil))

(define (compiler-ir-clone-global [global : CompilerIrGlobal]) : CompilerIrGlobal
  (match global
    [(IrGlobal name ty value)
      (IrGlobal (clone name) (clone ty) (compiler-ir-clone-value value))]))

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
    [(IrExtern name ty abi symbol links)
      (IrExtern
        (clone name)
        (clone ty)
        (clone abi)
        (clone symbol)
        (clone links))]))

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

(define (compiler-ir-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (compiler-ir-type-list-render [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) ""]
    [(AstTypeCons head rest)
      (let
        [head : AstType (box-get head)]
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
  (compiler-ir-cat3
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
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyFunc args ret)
      (compiler-ir-cat3
        "(-> "
        (compiler-ir-type-list-render args)
        (string-append
          " "
          (string-append (compiler-ir-type-render (box-get ret)) ")")))]
    [(AstTyTuple elems)
      (compiler-ir-cat3 "(Tuple " (compiler-ir-type-list-render elems) ")")]
    [(AstTyArray elem count)
      (compiler-ir-cat3
        "(Array "
        (compiler-ir-type-render (box-get elem))
        (compiler-ir-cat3 " " (int->string count) ")"))]
    [(AstTyDynArray elem)
      (compiler-ir-cat3 "(Array " (compiler-ir-type-render (box-get elem)) ")")]
    [(AstTyBox elem)
      (compiler-ir-cat3 "(Box " (compiler-ir-type-render (box-get elem)) ")")]
    [(AstTyRegion region inner)
      (compiler-ir-cat3
        "(Region "
        region
        (string-append
          " "
          (string-append (compiler-ir-type-render (box-get inner)) ")")))]
    [(AstTyRef region inner)
      (compiler-ir-cat3
        "(& "
        region
        (string-append
          " "
          (string-append (compiler-ir-type-render (box-get inner)) ")")))]
    [(AstTyMutRef region inner)
      (compiler-ir-cat3
        "(&mut "
        region
        (string-append
          " "
          (string-append (compiler-ir-type-render (box-get inner)) ")")))]
    [(AstTyEnum name) name]
    [(AstTyEnumArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render name lifetimes)]
    [(AstTyStruct name) name]
    [(AstTyStructArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render name lifetimes)]
    [(AstTyVar name) name]
    [(AstTyVarArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render name lifetimes)]
    [(AstTyPtr elem)
      (compiler-ir-cat3 "(Ptr " (compiler-ir-type-render (box-get elem)) ")")]
    [(AstTyMutPtr elem)
      (compiler-ir-cat3 "(MutPtr " (compiler-ir-type-render (box-get elem)) ")")]))

(define (compiler-ir-value-render [value : CompilerIrValue]) : String
  (match value
    [(IrValueVar id) (string-append "%" (int->string id))]
    [(IrValueGlobal name) (string-append "@" name)]
    [(IrValueGlobalAddr name) (string-append "&@" name)]
    [(IrValueFunction name) (string-append "fn@" name)]
    [(IrValueI64 value) (int->string value)]
    [(IrValueF64 value) value]
    [(IrValueBool value)
      (if value
        "true"
        "false")]
    [(IrValueChar value) (int->string (cast value : i64))]
    [(IrValueString value) value]
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
      (compiler-ir-cat3
        (compiler-ir-value-render a)
        ", "
        (compiler-ir-value-render b))]
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
  (compiler-ir-cat3
    "  tailcall "
    name
    (compiler-ir-cat3
      "("
      (compiler-ir-call-args-render args)
      (compiler-ir-cat3 ") : " (compiler-ir-type-render ty) ""))))

(define (compiler-ir-instr-render [instr : CompilerIrInstr]) : String
  (match instr
    [(IrInstrTailCall name args ty) (compiler-ir-tail-call-render name args ty)]
    [_ "  <ir-instr>"]))

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
      (or
        (string-eq name "tl_hash_string")
        (or
          (string-eq name "tl_region_mark")
          (string-eq name ".L_tl_stdin_eof"))))))

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
            (string-eq name "tl_string_concat3")
            (or
              (string-eq name "tl_string_concat4")
              (or
                (string-eq name "tl_string_concat5")
                (or
                  (string-eq name "tl_region_reset")
                  (string-eq name ".L_tl_flush_stdout"))))))))))

(define (compiler-ir-runtime-control-flow? [name : String]) : bool
  (or
    (string-eq name ".L_tl_abort")
    (or
      (string-eq name "tl_oob_abort")
      (or (string-eq name "tl_div_abort") (string-eq name "tl_shift_abort")))))

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
    [(IrInstrEntryArgc _) IrEffectMemoryRead]
    [(IrInstrEntryArgv _) IrEffectMemoryRead]
    [(IrInstrEntryEnvp _) IrEffectMemoryRead]
    [(IrInstrCpuId _ _ _ _) IrEffectUnknown]
    [(IrInstrXgetbv _ _) IrEffectUnknown]
    [(IrInstrAlloc _ _) IrEffectMemoryWrite]
    [(IrInstrStorePtr _ _ _) IrEffectMemoryWrite]
    [(IrInstrStore _ _ _) IrEffectMemoryWrite]
    [(IrInstrVectorStore _ _ _ _ _) IrEffectMemoryWrite]
    [(IrInstrPredicatedStore _ _ _ _ _ _) IrEffectMemoryWrite]
    [(IrInstrCall _ name _ _) (compiler-ir-direct-call-effect name)]
    [(IrInstrCallIndirect _ _ _ _) IrEffectUnknown]
    [(IrInstrBoundsCheck _ _ _) IrEffectControlFlow]
    [(IrInstrTailCall _ _ _) IrEffectControlFlow]
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
        [(IrInstrCall dst _ _ _)
          (compiler-source-spans-entry-list-lookup
            instr-entries
            (compiler-source-spans-value-key function dst))]
        [(IrInstrCallIndirect dst _ _ _)
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
    [(IrInstrTailCall _ args _) (compiler-ir-call-args-count args)]
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
    [(IrBlockCons _ rest) (+ 1 (compiler-ir-block-list-count (box-get rest)))]))

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
            (compiler-ir-block-list-empty-count (box-get rest)))])]))

(define (compiler-ir-block-list-max-instruction-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-ir-max-i64
            (compiler-ir-instr-seq-count instrs)
            (compiler-ir-block-list-max-instruction-count (box-get rest)))])]))

(define (compiler-ir-block-list-call-arg-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (compiler-ir-instr-seq-call-arg-count instrs)
            (compiler-ir-block-list-call-arg-count (box-get rest)))])]))

(define (compiler-ir-block-list-phi-input-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (compiler-ir-instr-seq-phi-input-count instrs)
            (compiler-ir-block-list-phi-input-count (box-get rest)))])]))

(define (compiler-ir-block-list-instruction-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (compiler-ir-instr-seq-count instrs)
            (compiler-ir-block-list-instruction-count (box-get rest)))])]))

(define (compiler-ir-function-list-count [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons _ rest)
      (+ 1 (compiler-ir-function-list-count (box-get rest)))]))

(define (compiler-ir-function-list-block-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (compiler-ir-block-list-count blocks)
            (compiler-ir-function-list-block-count (box-get rest)))])]))

(define (compiler-ir-function-list-instruction-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (compiler-ir-block-list-instruction-count blocks)
            (compiler-ir-function-list-instruction-count (box-get rest)))])]))

(define (compiler-ir-function-list-empty-block-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (compiler-ir-block-list-empty-count blocks)
            (compiler-ir-function-list-empty-block-count (box-get rest)))])]))

(define (compiler-ir-function-list-max-instruction-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (compiler-ir-max-i64
            (compiler-ir-block-list-instruction-count blocks)
            (compiler-ir-function-list-max-instruction-count (box-get rest)))])]))

(define (compiler-ir-function-list-max-block-instruction-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (compiler-ir-max-i64
            (compiler-ir-block-list-max-instruction-count blocks)
            (compiler-ir-function-list-max-block-instruction-count
              (box-get rest)))])]))

(define (compiler-ir-function-list-call-arg-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (compiler-ir-block-list-call-arg-count blocks)
            (compiler-ir-function-list-call-arg-count (box-get rest)))])]))

(define (compiler-ir-function-list-phi-input-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (compiler-ir-block-list-phi-input-count blocks)
            (compiler-ir-function-list-phi-input-count (box-get rest)))])]))

(define (compiler-ir-function-list-var-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ vars _)
          (+ vars (compiler-ir-function-list-var-count (box-get rest)))])]))

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

(define (compiler-ir-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string-append a (string-append b (string-append c d))))

(define (compiler-ir-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string-append a (string-append b (string-append c (string-append d e)))))

(define (compiler-ir-cat6
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : String
  (string-append
    a
    (string-append b (string-append c (string-append d (string-append e f))))))

(define (compiler-ir-type-list-name [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) ""]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (compiler-ir-cat3
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
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyFunc args ret)
      (compiler-ir-cat4
        "(->"
        (compiler-ir-type-list-name args)
        " "
        (compiler-ir-cat3 (compiler-ir-type-name (box-get ret)) ")" ""))]
    [(AstTyTuple elems)
      (compiler-ir-cat3 "(Tuple" (compiler-ir-type-list-name elems) ")")]
    [(AstTyArray elem count)
      (compiler-ir-cat5
        "(Array "
        (compiler-ir-type-name (box-get elem))
        " "
        (int->string count)
        ")")]
    [(AstTyDynArray elem)
      (compiler-ir-cat3 "(Array " (compiler-ir-type-name (box-get elem)) ")")]
    [(AstTyBox elem)
      (compiler-ir-cat3 "(Box " (compiler-ir-type-name (box-get elem)) ")")]
    [(AstTyRegion region inner)
      (compiler-ir-cat5
        "(in "
        region
        " "
        (compiler-ir-type-name (box-get inner))
        ")")]
    [(AstTyRef region inner)
      (compiler-ir-cat5
        "(& "
        region
        " "
        (compiler-ir-type-name (box-get inner))
        ")")]
    [(AstTyMutRef region inner)
      (compiler-ir-cat5
        "(&mut "
        region
        " "
        (compiler-ir-type-name (box-get inner))
        ")")]
    [(AstTyEnum name) name]
    [(AstTyEnumArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render name lifetimes)]
    [(AstTyStruct name) name]
    [(AstTyStructArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render name lifetimes)]
    [(AstTyVar name) (compiler-ir-cat3 "'" name "'")]
    [(AstTyVarArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render name lifetimes)]
    [(AstTyPtr elem)
      (compiler-ir-cat3 "(Ptr " (compiler-ir-type-name (box-get elem)) ")")]
    [(AstTyMutPtr elem)
      (compiler-ir-cat3 "(MutPtr " (compiler-ir-type-name (box-get elem)) ")")]))

(define (compiler-ir-vector-type-name [elem : AstType] [lanes : i64]) : String
  (compiler-ir-cat5
    "(Vector "
    (compiler-ir-type-name elem)
    " "
    (int->string lanes)
    ")"))

(define (compiler-ir-mask-type-name [lanes : i64]) : String
  (compiler-ir-cat3 "(Mask " (int->string lanes) ")"))

(define (compiler-ir-value-describe [value : CompilerIrValue]) : String
  (match value
    [(IrValueVar id) (compiler-ir-cat3 "%" (int->string id) "")]
    [(IrValueGlobal name) (compiler-ir-cat3 "@" name "")]
    [(IrValueGlobalAddr name) (compiler-ir-cat3 "&@" name "")]
    [(IrValueFunction name) (compiler-ir-cat3 "fn@" name "")]
    [(IrValueI64 n) (int->string n)]
    [(IrValueF64 n) n]
    [(IrValueBool b)
      (if b
        "true"
        "false")]
    [(IrValueChar c) (int->string (cast c : i64))]
    [(IrValueString s) s]
    [(IrValueUnit) "unit"]))

(define (compiler-ir-value-list-describe [values : CompilerIrValueList]) : String
  (match values
    [(IrValueNil) ""]
    [(IrValueCons head tail)
      (match (box-get tail)
        [(IrValueNil) (compiler-ir-value-describe head)]
        [_
          (compiler-ir-cat3
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
      (compiler-ir-cat3
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
  (compiler-ir-cat3 (int->string lanes) " x " (compiler-ir-type-name elem)))

(define (compiler-ir-vector-suffix [lanes : i64] [elem : AstType]) : String
  (compiler-ir-cat3 " : " (compiler-ir-lane-type-name lanes elem) ""))

(define (compiler-ir-instr-describe [instr : CompilerIrInstr]) : String
  (match instr
    [(IrInstrLaneId dst lanes ty)
      (compiler-ir-cat5
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = lane_id "
        (compiler-ir-lane-type-name lanes ty)
        "")]
    [(IrInstrSplat dst value lanes ty)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = splat "
        (compiler-ir-value-describe value)
        (compiler-ir-vector-suffix lanes ty)
        "")]
    [(IrInstrVectorBinOp dst op lhs rhs lanes elem-ty)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        (compiler-ir-cat3 " = vector_" (compiler-ir-binop-name op) " ")
        (compiler-ir-value-describe lhs)
        (compiler-ir-cat3 ", " (compiler-ir-value-describe rhs) "")
        (compiler-ir-vector-suffix lanes elem-ty))]
    [(IrInstrVectorReduce dst op src lanes elem-ty)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        (compiler-ir-cat3
          " = vector_reduce_"
          (compiler-ir-vector-reduce-op-name op)
          " ")
        (compiler-ir-value-describe src)
        (compiler-ir-vector-suffix lanes elem-ty)
        "")]
    [(IrInstrVectorCompare dst op lhs rhs lanes elem-ty)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        (compiler-ir-cat3 " = vector_cmp_" (compiler-ir-binop-name op) " ")
        (compiler-ir-value-describe lhs)
        (compiler-ir-cat3 ", " (compiler-ir-value-describe rhs) "")
        (compiler-ir-vector-suffix lanes elem-ty))]
    [(IrInstrMaskBinOp dst op lhs rhs lanes)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        (compiler-ir-cat3 " = " (compiler-ir-mask-binop-name op) " ")
        (compiler-ir-value-describe lhs)
        (compiler-ir-cat3 ", " (compiler-ir-value-describe rhs) " : ")
        (int->string lanes))]
    [(IrInstrMaskNot dst src lanes)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = mask_not "
        (compiler-ir-value-describe src)
        " : "
        (int->string lanes))]
    [(IrInstrMaskReduce dst op src lanes)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        (compiler-ir-cat3
          " = mask_reduce_"
          (compiler-ir-mask-reduce-op-name op)
          " ")
        (compiler-ir-value-describe src)
        " : "
        (int->string lanes))]
    [(IrInstrSelect dst mask on-true on-false lanes ty)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = select "
        (compiler-ir-value-describe mask)
        (compiler-ir-cat5
          ", "
          (compiler-ir-value-describe on-true)
          ", "
          (compiler-ir-value-describe on-false)
          "")
        (compiler-ir-vector-suffix lanes ty))]
    [(IrInstrVectorLoad dst base index lanes elem-ty)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = vector_load "
        (compiler-ir-value-describe base)
        (compiler-ir-cat3 ", " (compiler-ir-value-describe index) "")
        (compiler-ir-vector-suffix lanes elem-ty))]
    [(IrInstrVectorStore base index value lanes elem-ty)
      (compiler-ir-cat6
        "  vector_store "
        (compiler-ir-value-describe base)
        (compiler-ir-cat3 ", " (compiler-ir-value-describe index) "")
        (compiler-ir-cat3 ", " (compiler-ir-value-describe value) "")
        (compiler-ir-vector-suffix lanes elem-ty)
        "")]
    [(IrInstrPredicatedStore base index value mask lanes elem-ty)
      (compiler-ir-cat6
        "  predicated_store "
        (compiler-ir-value-describe base)
        (compiler-ir-cat3 ", " (compiler-ir-value-describe index) "")
        (compiler-ir-cat5
          ", "
          (compiler-ir-value-describe value)
          ", "
          (compiler-ir-value-describe mask)
          "")
        (compiler-ir-vector-suffix lanes elem-ty)
        "")]
    [(IrInstrPredicatedLoad dst base index mask lanes elem-ty)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = predicated_load "
        (compiler-ir-value-describe base)
        (compiler-ir-cat5
          ", "
          (compiler-ir-value-describe index)
          ", "
          (compiler-ir-value-describe mask)
          "")
        (compiler-ir-vector-suffix lanes elem-ty))]
    [(IrInstrTailMask dst index len lanes)
      (compiler-ir-cat6
        "  "
        (compiler-ir-value-describe (IrValueVar dst))
        " = tail_mask "
        (compiler-ir-value-describe index)
        (compiler-ir-cat3 ", " (compiler-ir-value-describe len) " : ")
        (int->string lanes))]
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
                    (compiler-ir-phi-input-cons
                      (IrValueI64 1)
                      "entry"
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
                              (IrCallArgsNil)
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
                                (IrInstrTailCall
                                  "fact_loop"
                                  (IrCallArgsTwo (IrValueVar 3) (IrValueI64 1))
                                  (AstTyI64))
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
                                    IrEffectControlFlow))))))))))))))))))

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

(define (compiler-ir-display-type-names-ok?) : bool
  (and
    (string-eq (compiler-ir-vector-type-name (AstTyI32) 8) "(Vector i32 8)")
    (string-eq (compiler-ir-mask-type-name 8) "(Mask 8)")))

(define (compiler-ir-display-op-names-ok?) : bool
  (and
    (string-eq (compiler-ir-vector-reduce-op-name IrVectorReduceSum) "sum")
    (and
      (string-eq (compiler-ir-vector-reduce-op-name IrVectorReduceMin) "min")
      (and
        (string-eq (compiler-ir-vector-reduce-op-name IrVectorReduceMax) "max")
        (and
          (string-eq (compiler-ir-mask-reduce-op-name IrMaskReduceAll) "all")
          (and
            (string-eq (compiler-ir-mask-reduce-op-name IrMaskReduceAny) "any")
            (and
              (string-eq (compiler-ir-mask-binop-name IrMaskAnd) "mask_and")
              (string-eq (compiler-ir-mask-binop-name IrMaskOr) "mask_or"))))))))

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
          (IrInstrVectorBinOp
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
          (IrInstrVectorCompare
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
          (IrInstrSelect
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
          (IrInstrVectorStore
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
          (IrInstrPredicatedStore
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
          (IrInstrPredicatedLoad
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
      (and
        (compiler-ir-effect-is? instr IrEffectPure)
        (match instr
          [(IrInstrTailMask dst index len lanes)
            (and
              (= dst 9)
              (and
                (compiler-ir-value-var-eq? index 1)
                (and (compiler-ir-value-var-eq? len 2) (= lanes 8))))]
          [_ false])))))

(define (compiler-ir-display-self-test-ok?) : bool
  (and
    (compiler-ir-display-type-names-ok?)
    (and
      (compiler-ir-display-op-names-ok?)
      (and (compiler-ir-display-instrs-ok?) (compiler-ir-display-tail-mask-ok?)))))

(define (compiler-ir-tail-call-render-ok?) : bool
  (string-eq
    (compiler-ir-instr-render
      (IrInstrTailCall
        "fact_loop"
        (IrCallArgsTwo (IrValueVar 3) (IrValueI64 1))
        (AstTyI64)))
    "  tailcall fact_loop(%3, 1) : i64"))

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
      (and
        (= (compiler-source-spans-count spans) 2)
        (match (compiler-source-spans-entry-list-lookup entries "second")
          [(CompilerSomeSourceSpan found)
            (and
              (= (struct-get found start-line) 4)
              (= (struct-get found end-col) 8))]
          [(CompilerNoSourceSpan) false])))))

(define (compiler-ir-instr-list-first-mov-dst?
  [instrs : CompilerIrInstrList]
  [want : i64]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr _)
      (match instr
        [(IrInstrMov dst _ _) (= dst want)]
        [_ false])]))

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
    (and
      (= (compiler-ir-instr-seq-count seq) 3)
      (and
        (and
          (not (compiler-ir-instr-seq-empty? seq))
          (match (compiler-ir-instr-seq-ref seq 2)
            [(IrInstrReturn _) true]
            [_ false]))
        (and
          (= (compiler-ir-instr-list-count roundtrip) 3)
          (and
            (= (compiler-ir-block-list-instruction-count block-list) 3)
            (compiler-ir-instr-list-first-mov-dst? roundtrip 1)))))))

(define (compiler-ir-effect-self-test) : i64
  (begin
    (unless (compiler-ir-instruction-effects-ok?) (return 1))
    (unless (compiler-ir-vector-mask-effects-ok?) (return 1))
    (unless (compiler-ir-runtime-effects-ok?) (return 1))
    (unless (compiler-ir-effect-predicates-ok?) (return 1))
    (unless (compiler-ir-display-self-test-ok?) (return 1))
    (unless (compiler-ir-tail-call-render-ok?) (return 1))
    (unless (compiler-ir-source-spans-boxed-list-ok?) (return 1))
    (unless (compiler-ir-instr-seq-roundtrip-ok?) (return 1))
    42))