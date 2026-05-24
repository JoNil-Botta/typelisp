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

(define (compiler-ir-value-list-count [values : CompilerIrValueList]) : i64
  (match values
    [(IrValueNil) 0]
    [(IrValueCons _ rest) (+ 1 (compiler-ir-value-list-count rest))]))

(define (compiler-ir-instr-list-reverse-onto [instrs : CompilerIrInstrList] [out : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) out]
    [(IrInstrCons instr rest)
     (compiler-ir-instr-list-reverse-onto rest (IrInstrCons instr out))]))

(define (compiler-ir-instr-list-reverse [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (compiler-ir-instr-list-reverse-onto instrs IrInstrNil))

(define (compiler-ir-block-list-reverse-onto [blocks : CompilerIrBlockList] [out : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) out]
    [(IrBlockCons block rest)
     (compiler-ir-block-list-reverse-onto rest (IrBlockCons block out))]))

(define (compiler-ir-block-list-reverse [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (compiler-ir-block-list-reverse-onto blocks IrBlockNil))

(define (compiler-ir-global-list-count [globals : CompilerIrGlobalList]) : i64
  (match globals
    [(IrGlobalNil) 0]
    [(IrGlobalCons _ rest) (+ 1 (compiler-ir-global-list-count rest))]))

(define (compiler-ir-extern-list-count [externs : CompilerIrExternList]) : i64
  (match externs
    [(IrExternNil) 0]
    [(IrExternCons _ rest) (+ 1 (compiler-ir-extern-list-count rest))]))

(define (compiler-ir-function-list-count [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons _ rest) (+ 1 (compiler-ir-function-list-count rest))]))

(define (compiler-ir-instr-list-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons _ rest) (+ 1 (compiler-ir-instr-list-count rest))]))

(define (compiler-ir-block-instr-count [block : CompilerIrBlock]) : i64
  (match block
    [(IrBlock _ instrs) (compiler-ir-instr-list-count instrs)]))

(define (compiler-ir-block-list-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons _ rest) (+ 1 (compiler-ir-block-list-count rest))]))

(define (compiler-ir-block-list-instr-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
     (+ (compiler-ir-block-instr-count block)
        (compiler-ir-block-list-instr-count rest))]))

(define (compiler-ir-param-list-next-var [params : CompilerIrParamList] [next-var : i64]) : i64
  (match params
    [(IrParamNil) next-var]
    [(IrParamCons param rest)
     (match param
       [(IrParam _ _ id)
        (if (< next-var (+ id 1))
            (compiler-ir-param-list-next-var rest (+ id 1))
            (compiler-ir-param-list-next-var rest next-var))])]))

(define (compiler-ir-instr-next-var [instr : CompilerIrInstr] [next-var : i64]) : i64
  (match instr
    [(IrInstrMov id _ _)
     (if (< next-var (+ id 1)) (+ id 1) next-var)]
    [(IrInstrBinOp id _ _ _ _)
     (if (< next-var (+ id 1)) (+ id 1) next-var)]
    [(IrInstrUnOp id _ _ _)
     (if (< next-var (+ id 1)) (+ id 1) next-var)]
    [(IrInstrCall id _ _ _)
     (if (< next-var (+ id 1)) (+ id 1) next-var)]
    [_ next-var]))

(define (compiler-ir-instr-list-next-var [instrs : CompilerIrInstrList] [next-var : i64]) : i64
  (match instrs
    [(IrInstrNil) next-var]
    [(IrInstrCons instr rest)
     (compiler-ir-instr-list-next-var rest (compiler-ir-instr-next-var instr next-var))]))

(define (compiler-ir-block-next-var [block : CompilerIrBlock] [next-var : i64]) : i64
  (match block
    [(IrBlock _ instrs) (compiler-ir-instr-list-next-var instrs next-var)]))

(define (compiler-ir-block-list-next-var [blocks : CompilerIrBlockList] [next-var : i64]) : i64
  (match blocks
    [(IrBlockNil) next-var]
    [(IrBlockCons block rest)
     (compiler-ir-block-list-next-var rest (compiler-ir-block-next-var block next-var))]))

(define (compiler-ir-function-blocks [fn : CompilerIrFunction]) : i64
  (match fn
    [(IrFunction _ _ _ blocks) (compiler-ir-block-list-count blocks)]))

(define (compiler-ir-function-instructions [fn : CompilerIrFunction]) : i64
  (match fn
    [(IrFunction _ _ _ blocks) (compiler-ir-block-list-instr-count blocks)]))

(define (compiler-ir-function-vars [fn : CompilerIrFunction]) : i64
  (match fn
    [(IrFunction _ params _ blocks)
     (compiler-ir-block-list-next-var
       blocks
       (compiler-ir-param-list-next-var params 0))]))

(define (compiler-ir-function-list-blocks [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons fn rest)
     (+ (compiler-ir-function-blocks fn)
        (compiler-ir-function-list-blocks rest))]))

(define (compiler-ir-function-list-instructions [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons fn rest)
     (+ (compiler-ir-function-instructions fn)
        (compiler-ir-function-list-instructions rest))]))

(define (compiler-ir-function-list-vars [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons fn rest)
     (+ (compiler-ir-function-vars fn)
        (compiler-ir-function-list-vars rest))]))

(define (compiler-ir-program-summary [program : CompilerIrProgram]) : CompilerIrSummary
  (match program
    [(IrProgram globals functions externs)
     (CompilerIrSummary
       (compiler-ir-global-list-count globals)
       (compiler-ir-function-list-count functions)
       (compiler-ir-extern-list-count externs)
       (compiler-ir-function-list-blocks functions)
       (compiler-ir-function-list-instructions functions)
       (compiler-ir-function-list-vars functions))]))
