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
  (IrInstrCast i64 CompilerIrValue AstType AstType)
  (IrInstrBinOp i64 CompilerIrBinOp CompilerIrValue CompilerIrValue AstType)
  (IrInstrUnOp i64 CompilerIrUnOp CompilerIrValue AstType)
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
  (IrExtern String AstType))

(defenum CompilerIrExternList
  (IrExternNil)
  (IrExternCons CompilerIrExtern CompilerIrExternList))

(defenum CompilerIrProgram
  (IrProgram CompilerIrGlobalList CompilerIrFunctionList CompilerIrExternList))

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