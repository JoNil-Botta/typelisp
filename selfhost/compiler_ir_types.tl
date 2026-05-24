;; compiler_ir_types.tl - Self-hosted compiler IR model (#446).
;;
;; This is the first selfhost IR shape for the real compiler pipeline. The
;; lowerer initially summarizes programs instead of emitting assembly, but the
;; data model is intentionally close to the Rust IR: functions contain blocks,
;; blocks contain typed instructions, and instructions use explicit vars/values.

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

(defenum CompilerIrValue
  (IrValueVar i64)
  (IrValueGlobal String)
  (IrValueI64 i64)
  (IrValueF64 f64)
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

(defenum CompilerIrInstr
  (IrInstrMov i64 CompilerIrValue AstType)
  (IrInstrBinOp i64 CompilerIrBinOp CompilerIrValue CompilerIrValue AstType)
  (IrInstrUnOp i64 CompilerIrUnOp CompilerIrValue AstType)
  (IrInstrCall i64 String CompilerIrValueList AstType)
  (IrInstrStore String CompilerIrValue AstType)
  (IrInstrJump String)
  (IrInstrBranch CompilerIrValue String String)
  (IrInstrReturn CompilerIrMaybeValue))

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
  (IrFunction String CompilerIrParamList AstType CompilerIrBlockList))

(defenum CompilerIrFunctionList
  (IrFunctionNil)
  (IrFunctionCons CompilerIrFunction CompilerIrFunctionList))

(defenum CompilerIrGlobal
  (IrGlobal String AstType CompilerIrValue))

(defenum CompilerIrGlobalList
  (IrGlobalNil)
  (IrGlobalCons CompilerIrGlobal CompilerIrGlobalList))

(defenum CompilerIrExtern
  (IrExtern String AstType))

(defenum CompilerIrExternList
  (IrExternNil)
  (IrExternCons CompilerIrExtern CompilerIrExternList))

(defenum CompilerIrProgram
  (IrProgram CompilerIrGlobalList CompilerIrFunctionList CompilerIrExternList))

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
     (+ globals
        (+ (* functions 10)
           (+ (* externs 100)
              (+ (* blocks 1000)
                 (+ (* instructions 10000)
                    (* vars 100000))))))]))
