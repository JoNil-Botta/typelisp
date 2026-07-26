;; compiler_ir_types_smoke.tl - Runnable IR type/effect smoke.
(import stdlib.string)
(import "../compiler_ir_types.tl")
(import compiler_intern as ci)
(import compiler_builtin_ids as cbi)

(define (compiler-ir-smoke-symbol-id [name : String]) : i64
  (ci.intern-generated-canonical-name name))

(define (compiler-ir-smoke-call-effect-id-is?
  [name : i64]
  [effect : CompilerIrEffect]) : bool
  (compiler-ir-effect-eq? (compiler-ir-direct-call-effect-id name) effect))

(define (compiler-ir-smoke-runtime-effect-ids-ok?) : bool
  (and
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-region-mark
      CompilerIrEffect.MemoryRead)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-stdin-eof-label
      CompilerIrEffect.MemoryRead)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-alloc
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-int-to-string
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-substring
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat3
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat4
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat5
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-region-reset
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-array-fill8
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-array-zero
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-flush-stdout-label
      CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-abort-label
      CompilerIrEffect.ControlFlow)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-oob-abort
      CompilerIrEffect.ControlFlow)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-div-abort
      CompilerIrEffect.ControlFlow)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-shift-abort
      CompilerIrEffect.ControlFlow)))

(define (compiler-ir-smoke-runtime-effect-identity-ok?) : bool
  (let
    [generated-alloc : i64 (ci.intern-generated-canonical-name "tl_alloc")]
    [generated-abort : i64 (ci.intern-generated-canonical-name ".L_tl_abort")]
    [unknown-extern : i64 (ci.intern-source-slice "user_or_extern_call" 0 19)]
    (and
      (not (= generated-alloc cbi.compiler-builtin-id-tl-alloc))
      (string.eq
        (compiler-ir-symbol-text generated-alloc)
        (compiler-ir-symbol-text cbi.compiler-builtin-id-tl-alloc))
      (compiler-ir-symbol-eq?
        cbi.compiler-builtin-id-tl-alloc
        cbi.compiler-builtin-id-tl-alloc)
      (not
        (compiler-ir-symbol-eq?
          generated-alloc
          cbi.compiler-builtin-id-tl-alloc))
      (compiler-ir-smoke-call-effect-id-is?
        generated-alloc
        CompilerIrEffect.Unknown)
      (compiler-ir-smoke-call-effect-id-is?
        generated-abort
        CompilerIrEffect.Unknown)
      (compiler-ir-smoke-call-effect-id-is?
        unknown-extern
        CompilerIrEffect.Unknown))))

(define (compiler-ir-smoke-runtime-effect-reset-ok?) : bool
  (let
    [old-alloc : i64 cbi.compiler-builtin-id-tl-alloc]
    [old-stdin : i64 cbi.compiler-builtin-id-tl-stdin-eof-label]
    (begin
      (ci.intern-reset!)
      (cbi.compiler-builtin-reset!)
      (ci.intern-source-slice "reset-prefix" 0 12)
      (cbi.compiler-builtin-initialize-for-parse!)
      (and
        (not (= old-alloc cbi.compiler-builtin-id-tl-alloc))
        (not (= old-stdin cbi.compiler-builtin-id-tl-stdin-eof-label))
        (compiler-ir-smoke-runtime-effect-ids-ok?)
        (compiler-ir-smoke-runtime-effect-identity-ok?)))))

(define (compiler-ir-smoke-runtime-effect-self-test-ok?) : bool
  (begin
    (ci.intern-reset!)
    (cbi.compiler-builtin-reset!)
    (cbi.compiler-builtin-initialize-for-parse!)
    (and
      (compiler-ir-smoke-runtime-effect-ids-ok?)
      (compiler-ir-smoke-runtime-effect-identity-ok?)
      (compiler-ir-smoke-runtime-effect-reset-ok?))))

(define (compiler-ir-smoke-function-list-first-name?
  [functions : CompilerIrFunctionList]
  [want : String]) : bool
  (match (compiler-ir-function-list-force-cons functions)
    [(CompilerIrFunctionList.Cons func _)
      (match func
        [(CompilerIrFunction.Function name _ _ _ _)
          (string.eq (ci.intern-str name) want)])]
    [(CompilerIrFunctionList.Nil) false]
    [(CompilerIrFunctionList.Array _) false]))

(define (compiler-ir-smoke-function-list-name-at?
  [functions : CompilerIrFunctionList]
  [index : i64]
  [want : String]) : bool
  (match (compiler-ir-function-list-force-cons functions)
    [(CompilerIrFunctionList.Cons func rest)
      (if (= index 0)
        (match func
          [(CompilerIrFunction.Function name _ _ _ _)
            (string.eq (ci.intern-str name) want)])
        (compiler-ir-smoke-function-list-name-at?
          (box-get rest)
          (- index 1)
          want))]
    [(CompilerIrFunctionList.Nil) false]
    [(CompilerIrFunctionList.Array _) false]))

(define (compiler-ir-smoke-block-list-label-at?
  [blocks : CompilerIrBlockList]
  [index : i64]
  [want : i64]) : bool
  (match (compiler-ir-block-list-force-cons blocks)
    [(CompilerIrBlockList.Cons block rest)
      (if (= index 0)
        (match block
          [(CompilerIrBlock.Block label _) (= label want)])
        (compiler-ir-smoke-block-list-label-at? (box-get rest) (- index 1) want))]
    [(CompilerIrBlockList.Nil) false]
    [(CompilerIrBlockList.Array _) false]))

(define (compiler-ir-smoke-param-seq-entry-i64?
  [seq : CompilerIrParamSeq]
  [index : i64]
  [want-name : String]
  [want-var : i64]) : bool
  (if (or (< index 0) (>= index (compiler-ir-param-seq-count seq)))
    false
    (match (compiler-ir-param-seq-ref seq index)
      [(CompilerIrParam.Param name ty var)
        (and
          (string.eq name want-name)
          (= var want-var)
          (match ty
            [(AstType.I64) true]
            [_ false]))])))

(define (compiler-ir-smoke-param-seq-entry-bool?
  [seq : CompilerIrParamSeq]
  [index : i64]
  [want-name : String]
  [want-var : i64]) : bool
  (if (or (< index 0) (>= index (compiler-ir-param-seq-count seq)))
    false
    (match (compiler-ir-param-seq-ref seq index)
      [(CompilerIrParam.Param name ty var)
        (and
          (string.eq name want-name)
          (= var want-var)
          (match ty
            [(AstType.Bool) true]
            [_ false]))])))

(define (compiler-ir-smoke-dense-function-params-ok?) : bool
  (let
    [params : CompilerIrParamList
      (compiler-ir-param-cons
        (CompilerIrParam.Param "value" (AstType.I64) 2)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "flag" (AstType.Bool) 5)
          CompilerIrParamList.Nil))]
    [func : CompilerIrFunction
      (CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "with_params")
        params
        (AstType.Unit)
        6
        CompilerIrBlockList.Nil)]
    [cloned : CompilerIrFunction
      (compiler-ir-clone-function (ast-node-pool-reader-context-current) func)]
    (and
      (match func
        [(CompilerIrFunction.Function _ stored _ _ _)
          (match stored
            [(CompilerIrParamList.Array seq)
              (and
                (= (compiler-ir-param-seq-count seq) 2)
                (compiler-ir-smoke-param-seq-entry-i64? seq 0 "value" 2)
                (compiler-ir-smoke-param-seq-entry-bool? seq 1 "flag" 5))]
            [_ false])])
      (match cloned
        [(CompilerIrFunction.Function _ stored _ _ _)
          (match stored
            [(CompilerIrParamList.Array seq)
              (and
                (= (compiler-ir-param-seq-count seq) 2)
                (compiler-ir-smoke-param-seq-entry-i64? seq 0 "value" 2)
                (compiler-ir-smoke-param-seq-entry-bool? seq 1 "flag" 5))]
            [_ false])]))))

(define (compiler-ir-smoke-function-list-compact-kind?
  [functions : CompilerIrFunctionList]) : bool
  (match functions
    [(CompilerIrFunctionList.Array seq)
      (= (compiler-ir-function-seq-count seq) 2)]
    [_ false]))

(define (compiler-ir-smoke-global-list-array-count?
  [globals : CompilerIrGlobalList]
  [want : i64]) : bool
  (match globals
    [(CompilerIrGlobalList.Array seq)
      (= (compiler-ir-global-seq-count seq) want)]
    [_ false]))

(define (compiler-ir-smoke-extern-list-array-count?
  [externs : CompilerIrExternList]
  [want : i64]) : bool
  (match externs
    [(CompilerIrExternList.Array seq)
      (= (compiler-ir-extern-seq-count seq) want)]
    [_ false]))

(define (compiler-ir-smoke-global-list-name-at?
  [globals : CompilerIrGlobalList]
  [index : i64]
  [want : String]) : bool
  (match (match globals
    [(CompilerIrGlobalList.Array seq) (compiler-ir-global-seq-to-list seq)]
    [_ globals])
    [(CompilerIrGlobalList.Cons global rest)
      (if (= index 0)
        (match global
          [(CompilerIrGlobal.Global name _ _)
            (string.eq (ci.intern-str name) want)])
        (compiler-ir-smoke-global-list-name-at? (box-get rest) (- index 1) want))]
    [(CompilerIrGlobalList.Nil) false]
    [(CompilerIrGlobalList.Array _) false]))

(define (compiler-ir-smoke-extern-list-name-at?
  [externs : CompilerIrExternList]
  [index : i64]
  [want : String]) : bool
  (match (match externs
    [(CompilerIrExternList.Array seq) (compiler-ir-extern-seq-to-list seq)]
    [_ externs])
    [(CompilerIrExternList.Cons extern rest)
      (if (= index 0)
        (match extern
          [(CompilerIrExtern.Extern _ _ name _ _ _ _ _) (string.eq name want)])
        (compiler-ir-smoke-extern-list-name-at? (box-get rest) (- index 1) want))]
    [(CompilerIrExternList.Nil) false]
    [(CompilerIrExternList.Array _) false]))

(define (compiler-ir-smoke-global-extern-seq-roundtrip-ok?) : bool
  (let
    [first-global : CompilerIrGlobal
      (CompilerIrGlobal.Global
        (compiler-ir-smoke-symbol-id "first-global")
        (AstType.I64)
        (CompilerIrValue.I64 1))]
    [second-global : CompilerIrGlobal
      (CompilerIrGlobal.Global
        (compiler-ir-smoke-symbol-id "second-global")
        (AstType.Bool)
        (CompilerIrValue.Bool true))]
    [reversed-globals : CompilerIrGlobalList
      (compiler-ir-global-cons
        second-global
        (compiler-ir-global-cons first-global CompilerIrGlobalList.Nil))]
    [compact-globals : CompilerIrGlobalList
      (compiler-ir-global-list-compact-reversed reversed-globals)]
    [array-reversed-globals : CompilerIrGlobalList
      (compiler-ir-global-list-compact-reversed compact-globals)]
    [cloned-globals : CompilerIrGlobalList
      (compiler-ir-clone-global-list
        (ast-node-pool-reader-context-current)
        compact-globals)]
    [first-extern : CompilerIrExtern
      (compiler-ir-extern-default-id
        (compiler-ir-smoke-symbol-id "first-extern")
        "first-extern"
        (AstType.I64))]
    [second-extern : CompilerIrExtern
      (compiler-ir-extern-default-id
        (compiler-ir-smoke-symbol-id "second-extern")
        "second-extern"
        (AstType.Bool))]
    [reversed-externs : CompilerIrExternList
      (compiler-ir-extern-cons
        second-extern
        (compiler-ir-extern-cons first-extern CompilerIrExternList.Nil))]
    [compact-externs : CompilerIrExternList
      (compiler-ir-extern-list-compact-reversed reversed-externs)]
    [array-reversed-externs : CompilerIrExternList
      (compiler-ir-extern-list-compact-reversed compact-externs)]
    [cloned-externs : CompilerIrExternList
      (compiler-ir-clone-extern-list
        (ast-node-pool-reader-context-current)
        compact-externs)]
    [summary : CompilerIrSummary
      (compiler-ir-program-summary
        (CompilerIrProgram.Program
          compact-globals
          CompilerIrFunctionList.Nil
          compact-externs))]
    (and
      (compiler-ir-smoke-global-list-array-count? compact-globals 2)
      (compiler-ir-smoke-global-list-name-at? compact-globals 0 "first-global")
      (compiler-ir-smoke-global-list-name-at? compact-globals 1 "second-global")
      (compiler-ir-smoke-global-list-name-at?
        array-reversed-globals
        0
        "second-global")
      (compiler-ir-smoke-global-list-name-at? cloned-globals 0 "first-global")
      (compiler-ir-smoke-extern-list-array-count? compact-externs 2)
      (compiler-ir-smoke-extern-list-name-at? compact-externs 0 "first-extern")
      (compiler-ir-smoke-extern-list-name-at? compact-externs 1 "second-extern")
      (compiler-ir-smoke-extern-list-name-at?
        array-reversed-externs
        0
        "second-extern")
      (compiler-ir-smoke-extern-list-name-at? cloned-externs 0 "first-extern")
      (= (compiler-ir-summary-globals summary) 2)
      (= (compiler-ir-summary-functions summary) 0)
      (= (compiler-ir-summary-externs summary) 2))))

(define (compiler-ir-smoke-function-seq-roundtrip-ok?) : bool
  (let
    [entry-instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
          CompilerIrInstrList.Nil))]
    [blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact
        (compiler-ir-block-cons
          (compiler-ir-block (compiler-ir-label "entry") entry-instrs)
          CompilerIrBlockList.Nil))]
    [first : CompilerIrFunction
      (CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "first")
        CompilerIrParamList.Nil
        (AstType.I64)
        2
        blocks)]
    [second : CompilerIrFunction
      (CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "second")
        CompilerIrParamList.Nil
        (AstType.I64)
        2
        blocks)]
    [functions : CompilerIrFunctionList
      (compiler-ir-function-cons
        first
        (compiler-ir-function-cons second CompilerIrFunctionList.Nil))]
    [compact : CompilerIrFunctionList
      (compiler-ir-function-list-compact functions)]
    [cloned : CompilerIrFunctionList
      (compiler-ir-clone-function-list
        (ast-node-pool-reader-context-current)
        compact)]
    [summary : CompilerIrSummary
      (compiler-ir-program-summary
        (CompilerIrProgram.Program
          CompilerIrGlobalList.Nil
          compact
          CompilerIrExternList.Nil))]
    (and
      (compiler-ir-smoke-function-list-compact-kind? compact)
      (compiler-ir-smoke-function-list-compact-kind? cloned)
      (= (compiler-ir-function-list-count compact) 2)
      (compiler-ir-smoke-function-list-first-name? compact "first")
      (= (compiler-ir-function-list-block-count compact) 2)
      (= (compiler-ir-function-list-instruction-count compact) 4)
      (= (compiler-ir-summary-functions summary) 2)
      (= (compiler-ir-summary-blocks summary) 2)
      (= (compiler-ir-summary-instructions summary) 4))))

(define (compiler-ir-smoke-reversed-compaction-ok?) : bool
  (let
    [first-block : CompilerIrBlock
      (compiler-ir-block (compiler-ir-label "first") CompilerIrInstrList.Nil)]
    [second-block : CompilerIrBlock
      (compiler-ir-block (compiler-ir-label "second") CompilerIrInstrList.Nil)]
    [third-block : CompilerIrBlock
      (compiler-ir-block (compiler-ir-label "third") CompilerIrInstrList.Nil)]
    [reversed-blocks : CompilerIrBlockList
      (compiler-ir-block-cons
        third-block
        (compiler-ir-block-cons
          second-block
          (compiler-ir-block-cons first-block CompilerIrBlockList.Nil)))]
    [compact-blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact-reversed reversed-blocks)]
    [array-reversed-blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact-reversed compact-blocks)]
    [first-func : CompilerIrFunction
      (CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "first-func")
        CompilerIrParamList.Nil
        (AstType.Unit)
        0
        compact-blocks)]
    [second-func : CompilerIrFunction
      (CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "second-func")
        CompilerIrParamList.Nil
        (AstType.Unit)
        0
        compact-blocks)]
    [third-func : CompilerIrFunction
      (CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "third-func")
        CompilerIrParamList.Nil
        (AstType.Unit)
        0
        compact-blocks)]
    [reversed-functions : CompilerIrFunctionList
      (compiler-ir-function-cons
        third-func
        (compiler-ir-function-cons
          second-func
          (compiler-ir-function-cons first-func CompilerIrFunctionList.Nil)))]
    [compact-functions : CompilerIrFunctionList
      (compiler-ir-function-list-compact-reversed reversed-functions)]
    [array-reversed-functions : CompilerIrFunctionList
      (compiler-ir-function-list-compact-reversed compact-functions)]
    (and
      (= (compiler-ir-block-list-count compact-blocks) 3)
      (compiler-ir-smoke-block-list-label-at?
        compact-blocks
        0
        (compiler-ir-label "first"))
      (compiler-ir-smoke-block-list-label-at?
        compact-blocks
        1
        (compiler-ir-label "second"))
      (compiler-ir-smoke-block-list-label-at?
        compact-blocks
        2
        (compiler-ir-label "third"))
      (compiler-ir-smoke-block-list-label-at?
        array-reversed-blocks
        0
        (compiler-ir-label "third"))
      (compiler-ir-smoke-block-list-label-at?
        array-reversed-blocks
        2
        (compiler-ir-label "first"))
      (= (compiler-ir-function-list-count compact-functions) 3)
      (compiler-ir-smoke-function-list-name-at?
        compact-functions
        0
        "first-func")
      (compiler-ir-smoke-function-list-name-at?
        compact-functions
        1
        "second-func")
      (compiler-ir-smoke-function-list-name-at?
        compact-functions
        2
        "third-func")
      (compiler-ir-smoke-function-list-name-at?
        array-reversed-functions
        0
        "third-func")
      (compiler-ir-smoke-function-list-name-at?
        array-reversed-functions
        2
        "first-func"))))

(define (compiler-ir-smoke-spmd-call-shape-ok?) : bool
  (let
    [args : CompilerIrSpmdCallArgList
      (ir-spmd-call-arg-cons
        (CompilerIrSpmdCallArg.Arg
          (CompilerIrSpmdValueClass.Uniform)
          (CompilerIrValue.Var 21)
          (AstType.I64))
        (ir-spmd-call-arg-cons
          (CompilerIrSpmdCallArg.Arg
            (CompilerIrSpmdValueClass.Varying)
            (CompilerIrValue.Var 22)
            (AstType.I64))
          CompilerIrSpmdCallArgList.Nil))]
    [instr : CompilerIrInstr
      (ir-instr-spmd-call
        (compiler-ir-smoke-symbol-id "helper")
        (CompilerIrSpmdBackend.Avx2)
        8
        (CompilerIrValue.Var 20)
        args
        (CompilerIrSpmdCallResult.Value
          6
          (CompilerIrSpmdValueClass.Varying)
          (AstType.I64)))]
    [span : AstSourceSpan (ast-source-span 3 4 3 9)]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-empty)
        7
        instr
        span)]
    (and
      (string.eq
        (compiler-ir-instr-render
          (ast-node-pool-reader-type-segment-bases)
          instr)
        "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) : varying i64")
      (string.eq
        (compiler-ir-instr-describe
          (ast-node-pool-reader-type-segment-bases)
          instr)
        "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) -> %6 : varying i64")
      (match instr
        [(CompilerIrInstr.SpmdCall payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrSpmdCallPayload.Payload _ _ _ _ stored-args _)
              (match stored-args
                [(CompilerIrSpmdCallArgList.Array seq)
                  (= (struct-get seq len) 2)]
                [_ false])])]
        [_ false])
      (compiler-ir-effect-is? instr CompilerIrEffect.Unknown)
      (= (compiler-ir-instr-call-arg-count instr) 2)
      (string.eq
        (compiler-ir-instr-render
          (ast-node-pool-reader-type-segment-bases)
          (compiler-ir-clone-instr (ast-node-pool-reader-context-current) instr))
        (compiler-ir-instr-render
          (ast-node-pool-reader-type-segment-bases)
          instr))
      (match (compiler-source-spans-lookup-instr spans 7 instr)
        [(CompilerMaybeSourceSpan.Some found)
          (and
            (= (ast-source-span-start-line found) 3)
            (= (ast-source-span-end-col found) 9))]
        [(CompilerMaybeSourceSpan.No) false]))))

(define (compiler-ir-smoke-access-helpers-ok?) : bool
  (let
    [call-indirect : CompilerIrInstr
      (CompilerIrInstr.CallIndirect
        9
        (CompilerIrValue.Var 1)
        CompilerIrCallArgs.Nil
        (AstType.I64))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 7 (CompilerIrValue.I64 10) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 7)
            (CompilerIrValue.I64 10)
            (compiler-ir-label "ok"))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              8
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 7)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 8)))
              CompilerIrInstrList.Nil))))]
    [seq : CompilerIrInstrSeq (compiler-ir-instr-seq-from-list instrs)]
    [slots : (Array CompilerIrInstr) (struct-get seq slots)]
    (and
      (= (compiler-ir-instr-loop-dst-or call-indirect (- 0 1)) (- 0 1))
      (= (compiler-ir-instr-array-loop-dst-or slots 0 (- 0 1)) 7)
      (= (compiler-ir-instr-array-loop-dst-or slots 1 (- 0 1)) (- 0 1))
      (= (compiler-ir-instr-seq-loop-dst-or seq 0 (- 0 1)) 7)
      (= (compiler-ir-instr-seq-loop-dst-or seq 1 (- 0 1)) (- 0 1))
      (not (compiler-ir-instr-seq-phi? seq 0))
      (not (compiler-ir-instr-seq-return? seq 0))
      (not (compiler-ir-instr-seq-bounds-check? seq 0))
      (compiler-ir-instr-seq-bounds-check? seq 1)
      (compiler-ir-instr-seq-return? seq 3)
      (match (compiler-ir-instr-seq-ref seq 2)
        [(CompilerIrInstr.BinOp dst _ (CompilerIrValue.Var lhs) _ _)
          (and (= dst 8) (= lhs 7))]
        [_ false]))))

(define (main) : i64
  (begin
    (unless (compiler-ir-smoke-function-seq-roundtrip-ok?) (return 1))
    (unless (compiler-ir-smoke-reversed-compaction-ok?) (return 2))
    (unless (compiler-ir-smoke-spmd-call-shape-ok?) (return 3))
    (unless (compiler-ir-smoke-dense-function-params-ok?) (return 4))
    (unless (compiler-ir-smoke-global-extern-seq-roundtrip-ok?) (return 5))
    (unless (compiler-ir-smoke-access-helpers-ok?) (return 6))
    (unless (compiler-ir-smoke-runtime-effect-self-test-ok?) (return 7))
    (compiler-ir-effect-self-test)))