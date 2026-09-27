;; compiler_ir_types_smoke.tl - Runnable IR type/effect smoke.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.arena)
(import stdlib.string)
(import compiler_ir_types)

(define (compiler-ir-types-smoke-instr-seq-prepend
  [instr : compiler_ir_types.CompilerIrInstr]
  [rest : compiler_ir_types.CompilerIrInstrSeq]) : compiler_ir_types.CompilerIrInstrSeq
  (let
    [builder : compiler_ir_types.CompilerIrInstrBuilder
      (compiler_ir_types.compiler-ir-instr-builder-with-capacity (+ rest.len 1))]
    (begin
      (compiler_ir_types.compiler-ir-instr-builder-push! (&mut builder) instr)
      (compiler_ir_types.compiler-ir-instr-builder-append-seq-range!
        (&mut builder)
        (compiler_ir_types.compiler-ir-global-shared-view rest)
        0
        rest.len)
      (compiler_ir_types.compiler-ir-instr-builder-to-seq builder))))

(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_builtin_ids as cbi)

(define (compiler-ir-smoke-symbol-id [name : String]) : i64
  (ci.intern-generated-canonical-name name))

(define (compiler-ir-smoke-call-effect-id-is?
  [name : i64]
  [effect : compiler_ir_types.CompilerIrEffect]) : bool
  (compiler_ir_types.compiler-ir-effect-eq?
    (compiler_ir_types.compiler-ir-direct-call-effect-id name)
    effect))

(define (compiler-ir-smoke-runtime-effect-ids-ok?) : bool
  (and
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-region-mark
      compiler_ir_types.CompilerIrEffect.MemoryRead)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-stdin-eof-label
      compiler_ir_types.CompilerIrEffect.MemoryRead)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-alloc
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-int-to-string
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-substring
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat3
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat4
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat5
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-region-reset
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-array-fill8
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-array-zero
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-mem-fill8
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-flush-stdout-label
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-abort-label
      compiler_ir_types.CompilerIrEffect.ControlFlow)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-oob-abort
      compiler_ir_types.CompilerIrEffect.ControlFlow)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-div-abort
      compiler_ir_types.CompilerIrEffect.ControlFlow)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-shift-abort
      compiler_ir_types.CompilerIrEffect.ControlFlow)))

(define (compiler-ir-smoke-runtime-effect-identity-ok?) : bool
  (let
    [generated-alloc : i64 (ci.intern-generated-canonical-name "tl_alloc")]
    [generated-abort : i64 (ci.intern-generated-canonical-name ".L_tl_abort")]
    [unknown-extern : i64 (ci.intern-source-slice "user_or_extern_call" 0 19)]
    (and
      (not (= generated-alloc cbi.compiler-builtin-id-tl-alloc))
      (string.eq
        (compiler_ir_types.compiler-ir-symbol-text generated-alloc)
        (compiler_ir_types.compiler-ir-symbol-text
          cbi.compiler-builtin-id-tl-alloc))
      (compiler_ir_types.compiler-ir-symbol-eq?
        cbi.compiler-builtin-id-tl-alloc
        cbi.compiler-builtin-id-tl-alloc)
      (not
        (compiler_ir_types.compiler-ir-symbol-eq?
          generated-alloc
          cbi.compiler-builtin-id-tl-alloc))
      (compiler-ir-smoke-call-effect-id-is?
        generated-alloc
        compiler_ir_types.CompilerIrEffect.Unknown)
      (compiler-ir-smoke-call-effect-id-is?
        generated-abort
        compiler_ir_types.CompilerIrEffect.Unknown)
      (compiler-ir-smoke-call-effect-id-is?
        unknown-extern
        compiler_ir_types.CompilerIrEffect.Unknown))))

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

(define (compiler-ir-smoke-function-seq-first-name?
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [want : String]) : bool
  (if (= functions.len 0)
    false
    (match (compiler_ir_types.compiler-ir-function-seq-ref functions 0)
      [(compiler_ir_types.CompilerIrFunction.Function name _ _ _ _ _)
        (string.eq (ci.intern-str name) want)])))

(define (compiler-ir-smoke-function-seq-name-at?
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [index : i64]
  [want : String]) : bool
  (if (or (< index 0) (>= index functions.len))
    false
    (match (compiler_ir_types.compiler-ir-function-seq-ref functions index)
      [(compiler_ir_types.CompilerIrFunction.Function name _ _ _ _ _)
        (string.eq (ci.intern-str name) want)])))

(define (compiler-ir-smoke-block-list-label-at?
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [index : i64]
  [want : i64]) : bool
  (match (compiler_ir_types.compiler-ir-block-list-force-cons blocks)
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (if (= index 0)
        (match block
          [(compiler_ir_types.CompilerIrBlock.Block label _) (= label want)])
        (compiler-ir-smoke-block-list-label-at? (deref rest) (- index 1) want))]
    [(compiler_ir_types.CompilerIrBlockList.Nil) false]
    [(compiler_ir_types.CompilerIrBlockList.Array _) false]))

(define (compiler-ir-smoke-param-seq-entry-i64?
  [seq : compiler_ir_types.CompilerIrParamSeq]
  [index : i64]
  [want-name : String]
  [want-var : i64]) : bool
  (if (or
    (< index 0)
    (>=
      index
      (compiler_ir_types.compiler-ir-param-seq-count
        (compiler_ir_types.compiler-ir-global-shared-view seq))))
    false
    (match (compiler_ir_types.compiler-ir-param-seq-ref seq index)
      [(compiler_ir_types.CompilerIrParam.Param name ty var)
        (and
          (string.eq name want-name)
          (= var want-var)
          (match ty
            [(ast.AstType.I64) true]
            [_ false]))])))

(define (compiler-ir-smoke-param-seq-entry-bool?
  [seq : compiler_ir_types.CompilerIrParamSeq]
  [index : i64]
  [want-name : String]
  [want-var : i64]) : bool
  (if (or
    (< index 0)
    (>=
      index
      (compiler_ir_types.compiler-ir-param-seq-count
        (compiler_ir_types.compiler-ir-global-shared-view seq))))
    false
    (match (compiler_ir_types.compiler-ir-param-seq-ref seq index)
      [(compiler_ir_types.CompilerIrParam.Param name ty var)
        (and
          (string.eq name want-name)
          (= var want-var)
          (match ty
            [(ast.AstType.Bool) true]
            [_ false]))])))

(define (compiler-ir-smoke-dense-function-params-ok?) : bool
  (let
    [params : compiler_ir_types.CompilerIrParamSeq
      (compiler_ir_types.compiler-ir-param-seq-prepend
        (compiler_ir_types.CompilerIrParam.Param "value" (ast.AstType.I64) 2)
        (compiler_ir_types.compiler-ir-param-seq-prepend
          (compiler_ir_types.CompilerIrParam.Param "flag" (ast.AstType.Bool) 5)
          (compiler_ir_types.compiler-ir-param-seq-empty)))]
    [func : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "with_params")
        params
        (ast.AstType.Unit)
        6
        compiler_ir_types.CompilerIrBlockList.Nil
        compiler_ir_types.CompilerIrFunctionAbi.Ordinary)]
    [cloned : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.compiler-ir-clone-function
        (ast.ast-node-pool-reader-context-current)
        (compiler_ir_types.compiler-ir-global-shared-view func))]
    (and
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ stored _ _ _ _)
          (and
            (=
              (compiler_ir_types.compiler-ir-param-seq-count
                (compiler_ir_types.compiler-ir-global-shared-view stored))
              2)
            (compiler-ir-smoke-param-seq-entry-i64?
              (compiler_ir_types.compiler-ir-global-shared-view stored)
              0
              "value"
              2)
            (compiler-ir-smoke-param-seq-entry-bool? stored 1 "flag" 5))])
      (match cloned
        [(compiler_ir_types.CompilerIrFunction.Function _ stored _ _ _ _)
          (and
            (=
              (compiler_ir_types.compiler-ir-param-seq-count
                (compiler_ir_types.compiler-ir-global-shared-view stored))
              2)
            (compiler-ir-smoke-param-seq-entry-i64?
              (compiler_ir_types.compiler-ir-global-shared-view stored)
              0
              "value"
              2)
            (compiler-ir-smoke-param-seq-entry-bool? stored 1 "flag" 5))]))))

(define (compiler-ir-smoke-function-seq-count-two?
  [functions : (& functions compiler_ir_types.CompilerIrFunctionSeq)]) : bool
  (= functions.len 2))

(define (compiler-ir-smoke-global-seq-count?
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [want : i64]) : bool
  (= (compiler_ir_types.compiler-ir-global-seq-count globals) want))

(define (compiler-ir-smoke-extern-seq-count?
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [want : i64]) : bool
  (= (compiler_ir_types.compiler-ir-extern-seq-count externs) want))

(define (compiler-ir-smoke-global-seq-name-at?
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [index : i64]
  [want : String]) : bool
  (if (or (< index 0) (>= index globals.len))
    false
    (match (compiler_ir_types.compiler-ir-global-seq-ref globals index)
      [(compiler_ir_types.CompilerIrGlobal.Global name _ _)
        (string.eq (ci.intern-str name) want)])))

(define (compiler-ir-smoke-global-seq-two
  [first : compiler_ir_types.CompilerIrGlobal]
  [second : compiler_ir_types.CompilerIrGlobal]) : compiler_ir_types.CompilerIrGlobalSeq
  (let
    [builder : compiler_ir_types.CompilerIrGlobalBuilder
      (compiler_ir_types.compiler-ir-global-builder-with-capacity 2)]
    (begin
      (compiler_ir_types.compiler-ir-global-builder-push! (&mut builder) first)
      (compiler_ir_types.compiler-ir-global-builder-push! (&mut builder) second)
      (compiler_ir_types.compiler-ir-global-builder-to-seq builder))))

(define (compiler-ir-smoke-extern-seq-name-at?
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [index : i64]
  [want : String]) : bool
  (if (or (< index 0) (>= index externs.len))
    false
    (match (compiler_ir_types.compiler-ir-extern-seq-ref externs index)
      [(compiler_ir_types.CompilerIrExtern.Extern _ _ name _ _ _ _ _)
        (string.eq name want)])))

(define (compiler-ir-smoke-global-extern-seq-roundtrip-ok?) : bool
  (let
    [first-global : compiler_ir_types.CompilerIrGlobal
      (compiler_ir_types.CompilerIrGlobal.Global
        (compiler-ir-smoke-symbol-id "first-global")
        (ast.AstType.I64)
        (compiler_ir_types.CompilerIrValue.I64 1))]
    [second-global : compiler_ir_types.CompilerIrGlobal
      (compiler_ir_types.CompilerIrGlobal.Global
        (compiler-ir-smoke-symbol-id "second-global")
        (ast.AstType.Bool)
        (compiler_ir_types.CompilerIrValue.Bool true))]
    [compact-globals : compiler_ir_types.CompilerIrGlobalSeq
      (compiler-ir-smoke-global-seq-two first-global second-global)]
    [cloned-globals : compiler_ir_types.CompilerIrGlobalSeq
      (compiler_ir_types.compiler-ir-clone-global-seq
        (ast.ast-node-pool-reader-context-current)
        (compiler_ir_types.compiler-ir-global-shared-view compact-globals))]
    [first-extern : compiler_ir_types.CompilerIrExtern
      (compiler_ir_types.compiler-ir-extern-default-id
        (compiler-ir-smoke-symbol-id "first-extern")
        "first-extern"
        (ast.AstType.I64))]
    [second-extern : compiler_ir_types.CompilerIrExtern
      (compiler_ir_types.compiler-ir-extern-default-id
        (compiler-ir-smoke-symbol-id "second-extern")
        "second-extern"
        (ast.AstType.Bool))]
    [extern-builder : compiler_ir_types.CompilerIrExternBuilder
      (compiler_ir_types.compiler-ir-extern-builder-with-capacity 1)]
    [_externs : unit
      (begin
        (compiler_ir_types.compiler-ir-extern-builder-push!
          (&mut extern-builder)
          first-extern)
        (compiler_ir_types.compiler-ir-extern-builder-push!
          (&mut extern-builder)
          second-extern))]
    [compact-externs : compiler_ir_types.CompilerIrExternSeq
      (compiler_ir_types.compiler-ir-extern-builder-snapshot-seq
        (& extern-builder))]
    [cloned-externs : compiler_ir_types.CompilerIrExternSeq
      (compiler_ir_types.compiler-ir-clone-extern-seq
        (ast.ast-node-pool-reader-context-current)
        (compiler_ir_types.compiler-ir-global-shared-view compact-externs))]
    [summary : compiler_ir_types.CompilerIrSummary
      (compiler_ir_types.compiler-ir-program-summary
        (compiler_ir_types.CompilerIrProgram.Program
          (compiler_ir_types.compiler-ir-global-shared-view compact-globals)
          (compiler_ir_types.compiler-ir-function-seq-empty)
          (compiler_ir_types.compiler-ir-global-shared-view compact-externs)))]
    (and
      (compiler-ir-smoke-global-seq-count?
        (compiler_ir_types.compiler-ir-global-shared-view compact-globals)
        2)
      (compiler-ir-smoke-global-seq-name-at?
        (compiler_ir_types.compiler-ir-global-shared-view compact-globals)
        0
        "first-global")
      (compiler-ir-smoke-global-seq-name-at? compact-globals 1 "second-global")
      (compiler-ir-smoke-global-seq-name-at? cloned-globals 0 "first-global")
      (compiler-ir-smoke-extern-seq-count?
        (compiler_ir_types.compiler-ir-global-shared-view compact-externs)
        2)
      (compiler-ir-smoke-extern-seq-name-at?
        (compiler_ir_types.compiler-ir-global-shared-view compact-externs)
        0
        "first-extern")
      (compiler-ir-smoke-extern-seq-name-at? compact-externs 1 "second-extern")
      (compiler-ir-smoke-extern-seq-name-at?
        (compiler_ir_types.compiler-ir-global-shared-view cloned-externs)
        0
        "first-extern")
      (compiler-ir-smoke-extern-seq-name-at? cloned-externs 1 "second-extern")
      (= (compiler_ir_types.compiler-ir-summary-globals summary) 2)
      (= (compiler_ir_types.compiler-ir-summary-functions summary) 0)
      (= (compiler_ir_types.compiler-ir-summary-externs summary) 2))))

(define (compiler-ir-smoke-function-seq-roundtrip-ok?) : bool
  (let
    [entry-instrs : compiler_ir_types.CompilerIrInstrSeq
      (compiler-ir-types-smoke-instr-seq-prepend
        (compiler_ir_types.CompilerIrInstr.Mov
          1
          (compiler_ir_types.CompilerIrValue.I64 10)
          (ast.AstType.I64))
        (compiler-ir-types-smoke-instr-seq-prepend
          (compiler_ir_types.CompilerIrInstr.Return
            (compiler_ir_types.CompilerIrMaybeValue.Some
              (compiler_ir_types.CompilerIrValue.Var 1)))
          (compiler_ir_types.compiler-ir-instr-seq-empty)))]
    [blocks : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-block-list-compact
        (compiler_ir_types.compiler-ir-block-cons
          (compiler_ir_types.CompilerIrBlock.Block
            (compiler_ir_types.compiler-ir-label "entry")
            entry-instrs)
          compiler_ir_types.CompilerIrBlockList.Nil))]
    [first : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "first")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (ast.AstType.I64)
        2
        (compiler_ir_types.compiler-ir-global-shared-view blocks)
        compiler_ir_types.CompilerIrFunctionAbi.Ordinary)]
    [second : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "second")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (ast.AstType.I64)
        2
        blocks
        compiler_ir_types.CompilerIrFunctionAbi.Ordinary)]
    [functions : compiler_ir_types.CompilerIrFunctionSeq
      (compiler_ir_types.compiler-ir-function-seq-prepend
        first
        (compiler_ir_types.compiler-ir-function-seq-prepend
          second
          (compiler_ir_types.compiler-ir-function-seq-empty)))]
    [compact : compiler_ir_types.CompilerIrFunctionSeq functions]
    [cloned : compiler_ir_types.CompilerIrFunctionSeq
      (compiler_ir_types.compiler-ir-clone-function-seq
        (ast.ast-node-pool-reader-context-current)
        (compiler_ir_types.compiler-ir-global-shared-view compact))]
    [summary : compiler_ir_types.CompilerIrSummary
      (compiler_ir_types.compiler-ir-program-summary
        (compiler_ir_types.CompilerIrProgram.Program
          (compiler_ir_types.compiler-ir-global-seq-empty)
          (compiler_ir_types.compiler-ir-global-shared-view compact)
          (compiler_ir_types.compiler-ir-extern-seq-empty)))]
    (and
      (compiler-ir-smoke-function-seq-count-two? compact)
      (compiler-ir-smoke-function-seq-count-two? cloned)
      (=
        (compiler_ir_types.compiler-ir-function-seq-count
          (compiler_ir_types.compiler-ir-global-shared-view compact))
        2)
      (compiler-ir-smoke-function-seq-first-name?
        (compiler_ir_types.compiler-ir-global-shared-view compact)
        "first")
      (=
        (compiler_ir_types.compiler-ir-function-seq-block-count
          compact)
        2)
      (=
        (compiler_ir_types.compiler-ir-function-seq-instruction-count compact)
        4)
      (= (compiler_ir_types.compiler-ir-summary-functions summary) 2)
      (= (compiler_ir_types.compiler-ir-summary-blocks summary) 2)
      (= (compiler_ir_types.compiler-ir-summary-instructions summary) 4))))

(define (compiler-ir-smoke-reversed-compaction-ok?) : bool
  (let
    [first-block : compiler_ir_types.CompilerIrBlock
      (compiler_ir_types.CompilerIrBlock.Block
        (compiler_ir_types.compiler-ir-label "first")
        (compiler_ir_types.compiler-ir-instr-seq-empty))]
    [second-block : compiler_ir_types.CompilerIrBlock
      (compiler_ir_types.CompilerIrBlock.Block
        (compiler_ir_types.compiler-ir-label "second")
        (compiler_ir_types.compiler-ir-instr-seq-empty))]
    [third-block : compiler_ir_types.CompilerIrBlock
      (compiler_ir_types.CompilerIrBlock.Block
        (compiler_ir_types.compiler-ir-label "third")
        (compiler_ir_types.compiler-ir-instr-seq-empty))]
    [reversed-blocks : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-block-cons
        third-block
        (compiler_ir_types.compiler-ir-block-cons
          second-block
          (compiler_ir_types.compiler-ir-block-cons
            first-block
            compiler_ir_types.CompilerIrBlockList.Nil)))]
    [compact-blocks : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-block-list-compact-reversed
        reversed-blocks)]
    [array-reversed-blocks : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-block-list-compact-reversed
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks))]
    [first-func : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "first-func")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (ast.AstType.Unit)
        0
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks)
        compiler_ir_types.CompilerIrFunctionAbi.Ordinary)]
    [second-func : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "second-func")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (ast.AstType.Unit)
        0
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks)
        compiler_ir_types.CompilerIrFunctionAbi.Ordinary)]
    [third-func : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "third-func")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (ast.AstType.Unit)
        0
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks)
        compiler_ir_types.CompilerIrFunctionAbi.Ordinary)]
    [reversed-functions : compiler_ir_types.CompilerIrFunctionSeq
      (compiler_ir_types.compiler-ir-function-seq-prepend
        (compiler_ir_types.compiler-ir-global-shared-view third-func)
        (compiler_ir_types.compiler-ir-function-seq-prepend
          (compiler_ir_types.compiler-ir-global-shared-view second-func)
          (compiler_ir_types.compiler-ir-function-seq-prepend
            (compiler_ir_types.compiler-ir-global-shared-view first-func)
            (compiler_ir_types.compiler-ir-function-seq-empty))))]
    [compact-functions : compiler_ir_types.CompilerIrFunctionSeq
      (compiler_ir_types.compiler-ir-function-seq-prepend
        first-func
        (compiler_ir_types.compiler-ir-function-seq-prepend
          second-func
          (compiler_ir_types.compiler-ir-function-seq-prepend
            third-func
            (compiler_ir_types.compiler-ir-function-seq-empty))))]
    [array-reversed-functions : compiler_ir_types.CompilerIrFunctionSeq
      reversed-functions]
    (and
      (=
        (compiler_ir_types.compiler-ir-block-list-count
          (compiler_ir_types.compiler-ir-global-shared-view compact-blocks))
        3)
      (compiler-ir-smoke-block-list-label-at?
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks)
        0
        (compiler_ir_types.compiler-ir-label "first"))
      (compiler-ir-smoke-block-list-label-at?
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks)
        1
        (compiler_ir_types.compiler-ir-label "second"))
      (compiler-ir-smoke-block-list-label-at?
        compact-blocks
        2
        (compiler_ir_types.compiler-ir-label "third"))
      (compiler-ir-smoke-block-list-label-at?
        (compiler_ir_types.compiler-ir-global-shared-view array-reversed-blocks)
        0
        (compiler_ir_types.compiler-ir-label "third"))
      (compiler-ir-smoke-block-list-label-at?
        array-reversed-blocks
        2
        (compiler_ir_types.compiler-ir-label "first"))
      (=
        (compiler_ir_types.compiler-ir-function-seq-count
          (compiler_ir_types.compiler-ir-global-shared-view compact-functions))
        3)
      (compiler-ir-smoke-function-seq-name-at?
        (compiler_ir_types.compiler-ir-global-shared-view compact-functions)
        0
        "first-func")
      (compiler-ir-smoke-function-seq-name-at?
        (compiler_ir_types.compiler-ir-global-shared-view compact-functions)
        1
        "second-func")
      (compiler-ir-smoke-function-seq-name-at? compact-functions 2 "third-func")
      (compiler-ir-smoke-function-seq-name-at?
        (compiler_ir_types.compiler-ir-global-shared-view
          array-reversed-functions)
        0
        "third-func")
      (compiler-ir-smoke-function-seq-name-at?
        array-reversed-functions
        2
        "first-func"))))

(define (compiler-ir-smoke-map-value
  [delta : i64]
  [value : compiler_ir_types.CompilerIrValue]) : compiler_ir_types.CompilerIrValue
  (match (compiler_ir_types.compiler-ir-global-shared-view value)
    [(compiler_ir_types.CompilerIrValue.Var id)
      (compiler_ir_types.CompilerIrValue.Var (+ id delta))]
    [_ value]))

(define (compiler-ir-smoke-spmd-map-value
  [delta : i64]
  [class : compiler_ir_types.CompilerIrSpmdValueClass]
  [value : compiler_ir_types.CompilerIrValue]) : compiler_ir_types.CompilerIrValue
  (compiler-ir-smoke-map-value
    (+
      delta
      (match class
        [(compiler_ir_types.CompilerIrSpmdValueClass.Uniform) 0]
        [(compiler_ir_types.CompilerIrSpmdValueClass.Varying) 100]
        [(compiler_ir_types.CompilerIrSpmdValueClass.Mask) 200]))
    value))

(define (compiler-ir-smoke-value-code
  [value : compiler_ir_types.CompilerIrValue]) : i64
  (match value
    [(compiler_ir_types.CompilerIrValue.Var id) id]
    [(compiler_ir_types.CompilerIrValue.I64 n) (+ 1000 n)]
    [(compiler_ir_types.CompilerIrValue.Bool b)
      (if b
        2001
        2000)]
    [_ (- 0 1)]))

(define (compiler-ir-smoke-record-value!
  [seen : (__tl_dyn-array i64)]
  [value : compiler_ir_types.CompilerIrValue]) : unit
  (let
    [count : i64 (array-ref seen 0)]
    (begin
      (set! (array-ref seen (+ count 1)) (compiler-ir-smoke-value-code value))
      (set! (array-ref seen 0) (+ count 1)))))

(define (compiler-ir-smoke-spmd-class-code
  [class : compiler_ir_types.CompilerIrSpmdValueClass]) : i64
  (match class
    [(compiler_ir_types.CompilerIrSpmdValueClass.Uniform) 10000]
    [(compiler_ir_types.CompilerIrSpmdValueClass.Varying) 20000]
    [(compiler_ir_types.CompilerIrSpmdValueClass.Mask) 30000]))

(define (compiler-ir-smoke-record-spmd-value!
  [seen : (__tl_dyn-array i64)]
  [class : compiler_ir_types.CompilerIrSpmdValueClass]
  [value : compiler_ir_types.CompilerIrValue]) : unit
  (let
    [count : i64 (array-ref seen 0)]
    (begin
      (set!
        (array-ref seen (+ count 1))
        (+
          (compiler-ir-smoke-spmd-class-code class)
          (compiler-ir-smoke-value-code value)))
      (set! (array-ref seen 0) (+ count 1)))))

(define (compiler-ir-smoke-call-arg-map-visit-ok?) : bool
  (let
    [many-values : (__tl_dyn-array compiler_ir_types.CompilerIrValue)
      (__tl_make-array compiler_ir_types.CompilerIrValue 4)]
    [_many-init : unit
      (begin
        (set!
          (array-ref many-values 0)
          (compiler_ir_types.CompilerIrValue.Var 3))
        (set!
          (array-ref many-values 1)
          (compiler_ir_types.CompilerIrValue.I64 9))
        (set!
          (array-ref many-values 2)
          (compiler_ir_types.CompilerIrValue.Var 4))
        (set!
          (array-ref many-values 3)
          (compiler_ir_types.CompilerIrValue.Bool true)))]
    [nil-mapped : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.compiler-ir-call-args-map
        (compiler_ir_types.CompilerIrCallArgs.Nil)
        compiler-ir-smoke-map-value
        10)]
    [one-mapped : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.compiler-ir-call-args-map
        (compiler_ir_types.CompilerIrCallArgs.One
          (compiler_ir_types.CompilerIrValue.Var 1))
        compiler-ir-smoke-map-value
        10)]
    [two-mapped : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.compiler-ir-call-args-map
        (compiler_ir_types.CompilerIrCallArgs.Two
          (compiler_ir_types.CompilerIrValue.I64 7)
          (compiler_ir_types.CompilerIrValue.Var 2))
        compiler-ir-smoke-map-value
        10)]
    [many : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.CompilerIrCallArgs.Array
        (compiler_ir_types.compiler-ir-global-shared-view many-values))]
    [many-mapped : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.compiler-ir-call-args-map
        (compiler_ir_types.compiler-ir-global-shared-view many)
        compiler-ir-smoke-map-value
        10)]
    [sret : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.CompilerIrCallArgs.Sret many-values 2)]
    [sret-mapped : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.compiler-ir-call-args-map
        (compiler_ir_types.compiler-ir-global-shared-view sret)
        compiler-ir-smoke-map-value
        10)]
    [seen : (__tl_dyn-array i64) (__tl_make-array i64 12)]
    [_visited : unit
      (begin
        (compiler_ir_types.compiler-ir-call-args-visit
          (compiler_ir_types.CompilerIrCallArgs.Nil)
          compiler-ir-smoke-record-value!
          (compiler_ir_types.compiler-ir-global-shared-view seen))
        (compiler_ir_types.compiler-ir-call-args-visit
          (compiler_ir_types.CompilerIrCallArgs.One
            (compiler_ir_types.CompilerIrValue.Var 1))
          compiler-ir-smoke-record-value!
          (compiler_ir_types.compiler-ir-global-shared-view seen))
        (compiler_ir_types.compiler-ir-call-args-visit
          (compiler_ir_types.CompilerIrCallArgs.Two
            (compiler_ir_types.CompilerIrValue.Var 2)
            (compiler_ir_types.CompilerIrValue.I64 7))
          compiler-ir-smoke-record-value!
          (compiler_ir_types.compiler-ir-global-shared-view seen))
        (compiler_ir_types.compiler-ir-call-args-visit
          many
          compiler-ir-smoke-record-value!
          (compiler_ir_types.compiler-ir-global-shared-view seen))
        (compiler_ir_types.compiler-ir-call-args-visit
          sret
          compiler-ir-smoke-record-value!
          (compiler_ir_types.compiler-ir-global-shared-view seen)))]
    (and
      (match nil-mapped
        [(compiler_ir_types.CompilerIrCallArgs.Nil) true]
        [_ false])
      (match one-mapped
        [(compiler_ir_types.CompilerIrCallArgs.One
            (compiler_ir_types.CompilerIrValue.Var id))
          (= id 11)]
        [_ false])
      (match two-mapped
        [(compiler_ir_types.CompilerIrCallArgs.Two
            (compiler_ir_types.CompilerIrValue.I64 literal)
            (compiler_ir_types.CompilerIrValue.Var id))
          (and (= literal 7) (= id 12))]
        [_ false])
      (match many-mapped
        [(compiler_ir_types.CompilerIrCallArgs.Array values)
          (and
            (= (array-length values) 4)
            (=
              (compiler-ir-smoke-value-code
                (compiler_ir_types.compiler-ir-array-shared-view values 0))
              13)
            (=
              (compiler-ir-smoke-value-code
                (compiler_ir_types.compiler-ir-array-shared-view values 1))
              1009)
            (=
              (compiler-ir-smoke-value-code
                (compiler_ir_types.compiler-ir-array-shared-view values 2))
              14)
            (=
              (compiler-ir-smoke-value-code
                (compiler_ir_types.compiler-ir-array-shared-view values 3))
              2001))]
        [_ false])
      (match sret-mapped
        [(compiler_ir_types.CompilerIrCallArgs.Sret values index)
          (and
            (= index 2)
            (= (array-length values) 4)
            (=
              (compiler-ir-smoke-value-code
                (compiler_ir_types.compiler-ir-array-shared-view values 0))
              13)
            (=
              (compiler-ir-smoke-value-code
                (compiler_ir_types.compiler-ir-array-shared-view values 1))
              1009)
            (=
              (compiler-ir-smoke-value-code
                (compiler_ir_types.compiler-ir-array-shared-view values 2))
              14)
            (=
              (compiler-ir-smoke-value-code
                (compiler_ir_types.compiler-ir-array-shared-view values 3))
              2001))]
        [_ false])
      (= (array-ref seen 0) 11)
      (= (array-ref seen 1) 1)
      (= (array-ref seen 2) 2)
      (= (array-ref seen 3) 1007)
      (= (array-ref seen 4) 3)
      (= (array-ref seen 5) 1009)
      (= (array-ref seen 6) 4)
      (= (array-ref seen 7) 2001)
      (= (array-ref seen 8) 3)
      (= (array-ref seen 9) 1009)
      (= (array-ref seen 10) 4)
      (= (array-ref seen 11) 2001))))

(define (compiler-ir-smoke-value-seq-map-visit-ok?) : bool
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrValue)
      (__tl_make-array compiler_ir_types.CompilerIrValue 4)]
    [_slots-init : unit
      (begin
        (set! (array-ref slots 0) (compiler_ir_types.CompilerIrValue.Var 5))
        (set! (array-ref slots 1) (compiler_ir_types.CompilerIrValue.I64 11))
        (set! (array-ref slots 2) (compiler_ir_types.CompilerIrValue.Var 99))
        (set! (array-ref slots 3) (compiler_ir_types.CompilerIrValue.Var 100)))]
    [values : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.CompilerIrValueSeq slots 2)]
    [mapped : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.compiler-ir-value-seq-map
        (compiler_ir_types.compiler-ir-global-shared-view values)
        compiler-ir-smoke-map-value
        10)]
    [seen : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [_visited : unit
      (compiler_ir_types.compiler-ir-value-seq-visit
        values
        compiler-ir-smoke-record-value!
        (compiler_ir_types.compiler-ir-global-shared-view seen))]
    (and
      (= mapped.len 2)
      (= (array-length mapped.slots) 2)
      (=
        (compiler-ir-smoke-value-code
          (compiler_ir_types.compiler-ir-array-shared-view mapped.slots 0))
        15)
      (=
        (compiler-ir-smoke-value-code
          (compiler_ir_types.compiler-ir-array-shared-view mapped.slots 1))
        1011)
      (= (array-ref seen 0) 2)
      (= (array-ref seen 1) 5)
      (= (array-ref seen 2) 1011))))

(define (compiler-ir-smoke-spmd-map-visit-ok?) : bool
  (let
    ;; Six physical slots and four logical arguments make an accidental
    ;; capacity walk observable through both result size and visit count.
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrSpmdCallArg)
      (__tl_make-array compiler_ir_types.CompilerIrSpmdCallArg 6)]
    [_slots-init : unit
      (begin
        (set!
          (array-ref slots 0)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg
            compiler_ir_types.CompilerIrSpmdValueClass.Uniform
            (compiler_ir_types.CompilerIrValue.Var 1)
            (ast.AstType.I64)))
        (set!
          (array-ref slots 1)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg
            compiler_ir_types.CompilerIrSpmdValueClass.Varying
            (compiler_ir_types.CompilerIrValue.Var 2)
            (ast.AstType.Bool)))
        (set!
          (array-ref slots 2)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg
            compiler_ir_types.CompilerIrSpmdValueClass.Mask
            (compiler_ir_types.CompilerIrValue.Var 3)
            (ast.AstType.Char)))
        (set!
          (array-ref slots 3)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg
            compiler_ir_types.CompilerIrSpmdValueClass.Mask
            (compiler_ir_types.CompilerIrValue.I64 7)
            (ast.AstType.String)))
        (set!
          (array-ref slots 4)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg
            compiler_ir_types.CompilerIrSpmdValueClass.Uniform
            (compiler_ir_types.CompilerIrValue.Var 99)
            (ast.AstType.Unit)))
        (set!
          (array-ref slots 5)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg
            compiler_ir_types.CompilerIrSpmdValueClass.Uniform
            (compiler_ir_types.CompilerIrValue.Var 100)
            (ast.AstType.Unit))))]
    [args : compiler_ir_types.CompilerIrSpmdCallArgSeq
      (compiler_ir_types.CompilerIrSpmdCallArgSeq slots 4)]
    [mapped : compiler_ir_types.CompilerIrSpmdCallArgSeq
      (compiler_ir_types.compiler-ir-spmd-call-args-map
        (compiler_ir_types.compiler-ir-global-shared-view args)
        compiler-ir-smoke-spmd-map-value
        10)]
    [seen : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [_visited : unit
      (compiler_ir_types.compiler-ir-spmd-call-args-visit
        args
        compiler-ir-smoke-record-spmd-value!
        (compiler_ir_types.compiler-ir-global-shared-view seen))]
    (and
      (= mapped.len 4)
      (= (array-length mapped.slots) 4)
      (match (compiler_ir_types.compiler-ir-array-shared-view mapped.slots 0)
        [(compiler_ir_types.CompilerIrSpmdCallArg.Arg
            (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
            (compiler_ir_types.CompilerIrValue.Var id)
            (ast.AstType.I64))
          (= id 11)]
        [_ false])
      (match (compiler_ir_types.compiler-ir-array-shared-view mapped.slots 1)
        [(compiler_ir_types.CompilerIrSpmdCallArg.Arg
            (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
            (compiler_ir_types.CompilerIrValue.Var id)
            (ast.AstType.Bool))
          (= id 112)]
        [_ false])
      (match (compiler_ir_types.compiler-ir-array-shared-view mapped.slots 2)
        [(compiler_ir_types.CompilerIrSpmdCallArg.Arg
            (compiler_ir_types.CompilerIrSpmdValueClass.Mask)
            (compiler_ir_types.CompilerIrValue.Var id)
            (ast.AstType.Char))
          (= id 213)]
        [_ false])
      (match (compiler_ir_types.compiler-ir-array-shared-view mapped.slots 3)
        [(compiler_ir_types.CompilerIrSpmdCallArg.Arg
            (compiler_ir_types.CompilerIrSpmdValueClass.Mask)
            (compiler_ir_types.CompilerIrValue.I64 literal)
            (ast.AstType.String))
          (= literal 7)]
        [_ false])
      (= (array-ref seen 0) 4)
      (= (array-ref seen 1) 10001)
      (= (array-ref seen 2) 20002)
      (= (array-ref seen 3) 30003)
      (= (array-ref seen 4) 31007))))

(define (compiler-ir-smoke-spmd-call-args) : compiler_ir_types.CompilerIrSpmdCallArgSeq
  (let
    [builder : compiler_ir_types.CompilerIrSpmdCallArgBuilder
      (compiler_ir_types.compiler-ir-spmd-call-arg-builder-with-capacity 1)]
    (begin
      (compiler_ir_types.compiler-ir-spmd-call-arg-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrSpmdCallArg.Arg
          (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
          (compiler_ir_types.CompilerIrValue.Var 21)
          (ast.AstType.I64)))
      (compiler_ir_types.compiler-ir-spmd-call-arg-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrSpmdCallArg.Arg
          (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
          (compiler_ir_types.CompilerIrValue.Var 22)
          (ast.AstType.I64)))
      (compiler_ir_types.compiler-ir-spmd-call-arg-builder-to-seq builder))))

(define (compiler-ir-smoke-spmd-call-shape-ok?) : bool
  (let
    [args : compiler_ir_types.CompilerIrSpmdCallArgSeq
      (compiler-ir-smoke-spmd-call-args)]
    [instr : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.compiler-ir-test-spmd-private-call
        (compiler-ir-smoke-symbol-id "helper")
        (compiler_ir_types.CompilerIrSpmdBackend.Avx2)
        8
        (compiler_ir_types.CompilerIrValue.Var 20)
        args
        (compiler_ir_types.CompilerIrSpmdCallResult.Value
          6
          (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
          (ast.AstType.I64)))]
    [span : ast.AstSourceSpan (ast.ast-source-span 3 4 3 9)]
    [span-function : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id 7)]
    [spans : compiler_ir_types.CompilerSourceSpans
      (compiler_ir_types.compiler-source-spans-insert-instr
        (compiler_ir_types.compiler-source-spans-empty)
        span-function
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        span)]
    (and
      (string.eq
        (compiler_ir_types.compiler-ir-instr-render
          (cis.InternStructuralSessionHandle 0)
          (ast.ast-node-pool-reader-type-segment-bases)
          (compiler_ir_types.compiler-ir-global-shared-view instr))
        (str_cat.str-cat
          "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) : varying i64"
          " private spmd-private-v1 @helper avx2 lanes 8 [0 active-mask : bool,"
          " 1 source 0 uniform i64 : i64, 2 source 1 varying i64 : i64]"
          " index none result varying i64"))
      (=
        (compiler_ir_types.compiler-ir-instr-dst
          (compiler_ir_types.compiler-ir-global-shared-view instr))
        6)
      (match (compiler_ir_types.compiler-ir-global-shared-view instr)
        [(compiler_ir_types.CompilerIrInstr.SpmdCall payload-box)
          (let
            [stored-args
              (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                args)]
            (and (= stored-args.len 2) (= (array-length stored-args.slots) 2)))]
        [_ false])
      (compiler-ir-effect-is?
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        compiler_ir_types.CompilerIrEffect.Unknown)
      (=
        (compiler_ir_types.compiler-ir-instr-call-arg-count
          (compiler_ir_types.compiler-ir-global-shared-view instr))
        2)
      (string.eq
        (compiler_ir_types.compiler-ir-instr-render
          (cis.InternStructuralSessionHandle 0)
          (ast.ast-node-pool-reader-type-segment-bases)
          (compiler_ir_types.compiler-ir-clone-instr
            (ast.ast-node-pool-reader-context-current)
            (compiler_ir_types.compiler-ir-global-shared-view instr)))
        (compiler_ir_types.compiler-ir-instr-render
          (cis.InternStructuralSessionHandle 0)
          (ast.ast-node-pool-reader-type-segment-bases)
          (compiler_ir_types.compiler-ir-global-shared-view instr)))
      (match (compiler_ir_types.compiler-source-spans-lookup-instr
        spans
        span-function
        instr)
        [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
          (and
            (= (ast.ast-source-span-start-line found) 3)
            (= (ast.ast-source-span-end-col found) 9))]
        [(compiler_ir_types.CompilerMaybeSourceSpan.No) false]))))

(define (compiler-ir-smoke-spmd-catalog-origin-ok?) : bool
  (let
    [args : compiler_ir_types.CompilerIrSpmdCallArgSeq
      (compiler-ir-smoke-spmd-call-args)]
    [callee : i64 (compiler-ir-smoke-symbol-id "helper")]
    [selected : compiler_ir_types.CompilerIrImportedSpmdCall
      (compiler_ir_types.CompilerIrImportedSpmdCall
        "fixture"
        "1.0.0"
        "fixture/helper"
        "(-> i64 i64 i64)"
        "spmd-call-v1"
        "avx512"
        8
        "uv"
        "v"
        -1
        "_tl_helper")]
    [call : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.ir-instr-spmd-call-with-origin
        callee
        compiler_ir_types.CompilerIrSpmdBackend.Avx512
        8
        (compiler_ir_types.CompilerIrValue.Var 20)
        args
        (compiler_ir_types.CompilerIrSpmdCallResult.Value
          6
          compiler_ir_types.CompilerIrSpmdValueClass.Varying
          (ast.AstType.I64))
        (compiler_ir_types.CompilerIrSpmdCallOrigin.Imported (box selected)))]
    [cloned : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.compiler-ir-clone-instr
        (ast.ast-node-pool-reader-context-current)
        (compiler_ir_types.compiler-ir-global-shared-view call))]
    (and
      (match call
        [(compiler_ir_types.CompilerIrInstr.SpmdCall payload-box)
          (string.eq
            (compiler_ir_types.compiler-ir-spmd-call-descriptor-error
              (deref payload-box))
            "")]
        [_ false])
      (match cloned
        [(compiler_ir_types.CompilerIrInstr.SpmdCall payload-box)
          (match (compiler_ir_types.compiler-ir-box-field-shared-view
            payload-box
            origin)
            [(compiler_ir_types.CompilerIrSpmdCallOrigin.Imported origin-box)
              (let
                [origin : compiler_ir_types.CompilerIrImportedSpmdCall
                  (deref origin-box)]
                (and
                  (string.eq origin.package-owner "fixture")
                  (string.eq origin.package-version "1.0.0")
                  (string.eq origin.link-symbol "_tl_helper")))]
            [(compiler_ir_types.CompilerIrSpmdCallOrigin.Private _) false])]
        [_ false])
      (>
        (string.string-length
          (compiler_ir_types.compiler-ir-spmd-call-descriptor-error
            (compiler_ir_types.CompilerIrInstrSpmdCallPayload
              callee
              compiler_ir_types.CompilerIrSpmdBackend.Scalar
              8
              (compiler_ir_types.CompilerIrValue.Var 20)
              (compiler-ir-smoke-spmd-call-args)
              (compiler_ir_types.CompilerIrSpmdCallResult.Value
                6
                compiler_ir_types.CompilerIrSpmdValueClass.Varying
                (ast.AstType.I64))
              (compiler_ir_types.CompilerIrSpmdCallOrigin.Imported
                (box
                  (compiler_ir_types.CompilerIrImportedSpmdCall
                    "fixture"
                    "1.0.0"
                    "fixture/helper"
                    "(-> i64 i64 i64)"
                    "spmd-call-v1"
                    "avx512"
                    8
                    "uv"
                    "v"
                    -1
                    "_tl_helper"))))))
        0))))

(define (compiler-ir-smoke-spmd-catalog-invalid?
  [signature : String]
  [abi : String]
  [args-code : String]
  [result-code : String]
  [index-param : i64]
  [link-symbol : String]) : bool
  (>
    (string.string-length
      (compiler_ir_types.compiler-ir-spmd-call-descriptor-error
        (compiler_ir_types.CompilerIrInstrSpmdCallPayload
          (compiler-ir-smoke-symbol-id "helper")
          compiler_ir_types.CompilerIrSpmdBackend.Avx512
          8
          (compiler_ir_types.CompilerIrValue.Var 20)
          (compiler-ir-smoke-spmd-call-args)
          (compiler_ir_types.CompilerIrSpmdCallResult.Value
            6
            compiler_ir_types.CompilerIrSpmdValueClass.Varying
            (ast.AstType.I64))
          (compiler_ir_types.CompilerIrSpmdCallOrigin.Imported
            (box
              (compiler_ir_types.CompilerIrImportedSpmdCall
                "fixture"
                "1.0.0"
                "fixture/helper"
                signature
                abi
                "avx512"
                8
                args-code
                result-code
                index-param
                link-symbol))))))
    0))

(define (compiler-ir-smoke-spmd-catalog-varying-index-ok?) : bool
  (let
    [payload : compiler_ir_types.CompilerIrInstrSpmdCallPayload
      (compiler_ir_types.CompilerIrInstrSpmdCallPayload
        (compiler-ir-smoke-symbol-id "helper")
        compiler_ir_types.CompilerIrSpmdBackend.Avx512
        8
        (compiler_ir_types.CompilerIrValue.Var 20)
        (compiler-ir-smoke-spmd-call-args)
        (compiler_ir_types.CompilerIrSpmdCallResult.Value
          6
          compiler_ir_types.CompilerIrSpmdValueClass.Varying
          (ast.AstType.I64))
        (compiler_ir_types.CompilerIrSpmdCallOrigin.Imported
          (box
            (compiler_ir_types.CompilerIrImportedSpmdCall
              "fixture"
              "1.0.0"
              "fixture/helper"
              "(-> i64 i64 i64)"
              "spmd-call-v1"
              "avx512"
              8
              "uv"
              "v"
              1
              "_tl_helper"))))]
    (string.eq
      (compiler_ir_types.compiler-ir-spmd-call-descriptor-error payload)
      "")))

(define (compiler-ir-smoke-spmd-catalog-mismatches-ok?) : bool
  (and
    (compiler-ir-smoke-spmd-catalog-varying-index-ok?)
    (compiler-ir-smoke-spmd-catalog-invalid?
      "(-> i64 i64 i64)"
      "spmd-call-v1"
      "uv"
      "v"
      0
      "_tl_helper")
    (compiler-ir-smoke-spmd-catalog-invalid?
      "(-> i64 i64 u64)"
      "spmd-call-v1"
      "uv"
      "v"
      -1
      "_tl_helper")
    (compiler-ir-smoke-spmd-catalog-invalid?
      "(-> i64 i64 i64)"
      "spmd-call-v2"
      "uv"
      "v"
      -1
      "_tl_helper")
    (compiler-ir-smoke-spmd-catalog-invalid?
      "(-> i64 i64 i64)"
      "spmd-call-v1"
      "uu"
      "v"
      -1
      "_tl_helper")
    (compiler-ir-smoke-spmd-catalog-invalid?
      "(-> i64 i64 i64)"
      "spmd-call-v1"
      "uv"
      "u"
      -1
      "_tl_helper")
    (compiler-ir-smoke-spmd-catalog-invalid?
      "(-> i64 i64 i64)"
      "spmd-call-v1"
      "uv"
      "v"
      2
      "_tl_helper")
    (compiler-ir-smoke-spmd-catalog-invalid?
      "(-> i64 i64 i64)"
      "spmd-call-v1"
      "uv"
      "v"
      0
      "_tl_helper")
    (compiler-ir-smoke-spmd-catalog-invalid?
      "(-> i64 i64 i64)"
      "spmd-call-v1"
      "uv"
      "v"
      -1
      "_tl_other")
    (not
      (compiler-ir-smoke-spmd-catalog-invalid?
        "(-> i64 i64 i64)"
        "spmd-call-v1"
        "uv"
        "v"
        1
        "_tl_helper"))))

(define (compiler-ir-smoke-store-owned-ok?) : bool
  (let
    [store : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.CompilerIrInstr.StoreOwned
        (compiler_ir_types.CompilerIrValue.Var 4)
        (compiler_ir_types.CompilerIrValue.Var 3)
        (ast.AstType.String))]
    [session : cis.InternStructuralSessionHandle
      (cis.InternStructuralSessionHandle 0)]
    [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
    (and
      (string.eq
        (compiler_ir_types.compiler-ir-instr-render
          session
          bases
          (compiler_ir_types.compiler-ir-global-shared-view store))
        "  store_owned %3 -> %4 : String")
      (compiler-ir-effect-is?
        (compiler_ir_types.compiler-ir-global-shared-view store)
        compiler_ir_types.CompilerIrEffect.MemoryWrite)
      (string.eq
        (compiler_ir_types.compiler-ir-instr-render
          session
          bases
          (compiler_ir_types.compiler-ir-clone-instr
            (ast.ast-node-pool-reader-context-current)
            store))
        "  store_owned %3 -> %4 : String"))))

(define (compiler-ir-smoke-access-helpers-ok?) : bool
  (let
    [call-indirect : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.CompilerIrInstr.CallIndirect
        9
        (compiler_ir_types.CompilerIrValue.Var 1)
        compiler_ir_types.CompilerIrCallArgs.Nil
        (ast.AstType.I64))]
    [instrs : compiler_ir_types.CompilerIrInstrSeq
      (compiler-ir-types-smoke-instr-seq-prepend
        (compiler_ir_types.CompilerIrInstr.Mov
          7
          (compiler_ir_types.CompilerIrValue.I64 10)
          (ast.AstType.I64))
        (compiler-ir-types-smoke-instr-seq-prepend
          (compiler_ir_types.CompilerIrInstr.BoundsCheck
            (compiler_ir_types.CompilerIrValue.Var 7)
            (compiler_ir_types.CompilerIrValue.I64 10)
            (compiler_ir_types.compiler-ir-label "ok"))
          (compiler-ir-types-smoke-instr-seq-prepend
            (compiler_ir_types.CompilerIrInstr.BinOp
              8
              (compiler_ir_types.CompilerIrBinOp.Add)
              (compiler_ir_types.CompilerIrValue.Var 7)
              (compiler_ir_types.CompilerIrValue.I64 1)
              (ast.AstType.I64))
            (compiler-ir-types-smoke-instr-seq-prepend
              (compiler_ir_types.CompilerIrInstr.Return
                (compiler_ir_types.CompilerIrMaybeValue.Some
                  (compiler_ir_types.CompilerIrValue.Var 8)))
              (compiler_ir_types.compiler-ir-instr-seq-empty)))))]
    [seq : compiler_ir_types.CompilerIrInstrSeq instrs]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) seq.slots]
    (and
      (=
        (compiler_ir_types.compiler-ir-instr-loop-dst-or call-indirect (- 0 1))
        (- 0 1))
      (=
        (compiler_ir_types.compiler-ir-instr-array-loop-dst-or
          (compiler_ir_types.compiler-ir-global-shared-view slots)
          0
          (- 0 1))
        7)
      (=
        (compiler_ir_types.compiler-ir-instr-array-loop-dst-or slots 1 (- 0 1))
        (- 0 1))
      (=
        (compiler_ir_types.compiler-ir-instr-seq-loop-dst-or
          (compiler_ir_types.compiler-ir-global-shared-view seq)
          0
          (- 0 1))
        7)
      (=
        (compiler_ir_types.compiler-ir-instr-seq-loop-dst-or
          (compiler_ir_types.compiler-ir-global-shared-view seq)
          1
          (- 0 1))
        (- 0 1))
      (not
        (compiler_ir_types.compiler-ir-instr-seq-phi?
          (compiler_ir_types.compiler-ir-global-shared-view seq)
          0))
      (not
        (compiler_ir_types.compiler-ir-instr-seq-return?
          (compiler_ir_types.compiler-ir-global-shared-view seq)
          0))
      (not
        (compiler_ir_types.compiler-ir-instr-seq-bounds-check?
          (compiler_ir_types.compiler-ir-global-shared-view seq)
          0))
      (compiler_ir_types.compiler-ir-instr-seq-bounds-check?
        (compiler_ir_types.compiler-ir-global-shared-view seq)
        1)
      (compiler_ir_types.compiler-ir-instr-seq-return?
        (compiler_ir_types.compiler-ir-global-shared-view seq)
        3)
      (match (compiler_ir_types.compiler-ir-instr-seq-ref
        (compiler_ir_types.compiler-ir-global-shared-view seq)
        2)
        [(compiler_ir_types.CompilerIrInstr.BinOp
            dst
            _
            (compiler_ir_types.CompilerIrValue.Var lhs)
            _
            _)
          (and (= dst 8) (= lhs 7))]
        [_ false]))))

(define (compiler-ir-smoke-slice-type-render-clone-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [lifetime : i64 (ci.intern "ir-slice")]
    [slice : ast.AstType (ast.ast-ty-slice-with-pools pools ast.AstType.I64)]
    [borrowed : ast.AstType (ast.ast-ty-ref-with-pools pools lifetime slice)]
    [bases : i64 (ast.ast-node-pool-context-type-segment-bases (& pools))]
    [clone : ast.AstType
      (compiler_ir_types.compiler-ir-clone-type
        pools
        (compiler_ir_types.compiler-ir-global-shared-view borrowed))]
    [render-original : String
      (compiler_ir_types.compiler-ir-type-render
        (cis.InternStructuralSessionHandle 0)
        bases
        (compiler_ir_types.compiler-ir-global-shared-view borrowed))]
    [render-original-again : String
      (compiler_ir_types.compiler-ir-type-render
        (cis.InternStructuralSessionHandle 0)
        bases
        (compiler_ir_types.compiler-ir-global-shared-view borrowed))]
    [name-original : String
      (compiler_ir_types.compiler-ir-type-name
        bases
        (compiler_ir_types.compiler-ir-global-shared-view borrowed))]
    [name-original-again : String
      (compiler_ir_types.compiler-ir-type-name bases borrowed)]
    [render-clone : String
      (compiler_ir_types.compiler-ir-type-render
        (cis.InternStructuralSessionHandle 0)
        bases
        (compiler_ir_types.compiler-ir-global-shared-view clone))]
    [name-clone : String
      (compiler_ir_types.compiler-ir-type-name
        bases
        (compiler_ir_types.compiler-ir-global-shared-view clone))]
    (and
      (string.eq render-original "(& ir-slice (Slice i64))")
      (string.eq render-original-again render-original)
      (string.eq name-original "(& ir-slice (Slice i64))")
      (string.eq name-original-again name-original)
      (string.eq render-clone render-original)
      (string.eq name-clone name-original)
      (match clone
        [(ast.AstType.Ref cloned-lifetime cloned-inner)
          (and
            (= cloned-lifetime lifetime)
            (match (ast.ast-node-pool-context-type-get (& pools) cloned-inner)
              [(ast.AstType.Slice cloned-elem)
                (match (ast.ast-node-pool-context-type-get
                  (& pools)
                  cloned-elem)
                  [(ast.AstType.I64) true]
                  [_ false])]
              [_ false]))]
        [_ false]))))

(define (compiler-ir-smoke-structural-lifetime-render-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [source : i64 (ci.intern "macro-local-life")]
    [module-id : i64 (ci.intern "macro-local-module")]
    [macro-name-id : i64 (ci.intern "macro-local-definition")]
    [active-intern : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state (& active-intern)))]
    [definition : cis.InternMacroDefinitionIdentity
      (cis.intern-structural-session-macro-definition-identity
        session
        module-id
        macro-name-id)]
    [lifetime : i64
      (cis.intern-macro-local-identity-raw
        (cis.intern-structural-session-macro-local-identity
          session
          definition
          7
          source))]
    [borrowed : ast.AstType
      (ast.ast-ty-ref-with-pools pools lifetime ast.AstType.I64)]
    [arithmetic-borrowed : ast.AstType
      (ast.ast-ty-ref-with-pools
        pools
        (cis.intern-fresh-local-identity-raw
          (cis.intern-structural-session-fresh-local-identity session 8 source))
        ast.AstType.I64)]
    [other-intern : ci.InternCompatState (ci.intern-compat-state-new)]
    [other-session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state (& other-intern)))]
    [invalid : ast.AstType
      (ast.ast-ty-ref-with-pools pools (ci.intern-capacity) ast.AstType.I64)]
    [bases : i64 (ast.ast-node-pool-context-type-segment-bases (& pools))]
    (and
      (string.eq
        (compiler_ir_types.compiler-ir-type-render
          session
          bases
          (compiler_ir_types.compiler-ir-global-shared-view borrowed))
        "(& macro-local-life i64)")
      (string.eq
        (compiler_ir_types.compiler-ir-type-name bases arithmetic-borrowed)
        "(& macro-local-life i64)")
      ;; Equal-looking record indexes from another owner never decode this
      ;; compile's table-backed lifetime.
      (string.eq
        (compiler_ir_types.compiler-ir-type-render other-session bases borrowed)
        (str_cat.str-cat "(& <id:" (string.int->string lifetime) "> i64)"))
      (string.eq
        (compiler_ir_types.compiler-ir-type-render session bases invalid)
        (str_cat.str-cat
          "(& <id:"
          (string.int->string (ci.intern-capacity))
          "> i64)")))))

;; The derived-symbol table exists because the fixed intern pool ran out of
;; generated ids on a whole-program self-compile (refs #6293), so what has to
;; hold is: one id per spelling and that spelling back unchanged, growth past
;; the initial slab without losing earlier entries, a capacity-independent
;; one-word domain that cannot collide with any u32 source handle or neighboring
;; compiler identity, and no cost at all to the intern lanes -- the budget the
;; table exists to buy back.
(define (compiler-ir-smoke-derived-symbol-table-ok?) : bool
  (let
    [pool-id : i64 (ci.intern "ir-smoke-pool-name")]
    [canonical-id : i64
      (ci.intern-generated-canonical-name "ir-smoke/canonical")]
    [pool-before : i64 (ci.intern-pool-len)]
    [generated-before : i64 (ci.intern-generated-count)]
    [capacity : i64 (ci.intern-capacity)]
    [domain-width : i64 (ci.intern-compiler-identity-domain-width)]
    [compact-limit : i64 (ci.intern-compact-id-domain-limit)]
    [cfg-base : i64 (ci.intern-cfg-key-domain-base)]
    [base : i64 (compiler_ir_types.compiler-ir-symbol-base)]
    [domain-limit : i64 (ci.intern-ir-symbol-domain-limit)]
    [structural-base : i64 (ci.intern-structural-key-base)]
    [old-collision-base : i64 (* 4 capacity)]
    [current-cfg-key : i64 (+ capacity (- capacity 1))]
    [count-before : i64 (compiler_ir_types.compiler-ir-symbol-count-value)]
    [canonical-symbol : i64
      (compiler_ir_types.compiler-ir-symbol "ir-smoke/canonical")]
    [first : i64 (compiler_ir_types.compiler-ir-symbol "ir-smoke/one")]
    [second : i64 (compiler_ir_types.compiler-ir-symbol "ir-smoke/two")]
    [first-again : i64 (compiler_ir_types.compiler-ir-symbol "ir-smoke/one")]
    [last-grown : i64 0]
    [index : i64 0]
    [logical-source-handle : i64 0]
    [ok : bool true]
    (begin
      ;; An existing canonical generated name remains a pooled identity and
      ;; does not consume an IR-owned slot.
      (unless (= canonical-symbol canonical-id) (set! ok false))
      ;; Equal spellings are one id; distinct spellings are distinct ids.
      (unless (= first first-again) (set! ok false))
      (unless (not (= first second)) (set! ok false))
      (unless
        (=
          (compiler_ir_types.compiler-ir-symbol-count-value)
          (+ count-before 2))
        (set! ok false))
      ;; Round trip, through the raw render and through the typed handle.
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-text first)
          "ir-smoke/one")
        (set! ok false))
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-text second)
          "ir-smoke/two")
        (set! ok false))
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-id-text
            (compiler_ir_types.compiler-ir-symbol-typed-id second))
          "ir-smoke/two")
        (set! ok false))
      ;; The full namespace is capacity-independent: compact u32 ids, cfg,
      ;; IR-owned and session structural identities occupy disjoint domains.
      (unless (= compact-limit 4294967296) (set! ok false))
      (unless (= cfg-base domain-width) (set! ok false))
      (unless (= base (* 2 domain-width)) (set! ok false))
      (unless (= domain-limit (* 3 domain-width)) (set! ok false))
      (unless (= structural-base 4611686018427387904) (set! ok false))
      (unless (= compact-limit cfg-base) (set! ok false))
      (unless (< cfg-base base) (set! ok false))
      (unless (< domain-limit structural-base) (set! ok false))
      ;; Allocated IR ids remain dense inside their fixed tagged domain.
      (unless (= first (+ base count-before)) (set! ok false))
      (unless (= second (+ first 1)) (set! ok false))
      (unless (< second domain-limit) (set! ok false))
      (unless
        (= (compiler_ir_types.compiler-ir-symbol-slot first) (- first base))
        (set! ok false))
      (unless
        (compiler_ir_types.compiler-ir-symbol-owned? first)
        (set! ok false))
      (unless
        (compiler_ir_types.compiler-ir-symbol-domain? first)
        (set! ok false))
      (unless (not (ci.intern-renderable-id? first)) (set! ok false))
      ;; More than today's 131,072 possible source handles -- including the old
      ;; 4*capacity collision point -- all fail ownership and slot decoding.
      ;; This deliberately uses raw u32-domain handles because today's fixed
      ;; pool cannot allocate the future values the namespace must reserve.
      (while (<= logical-source-handle capacity)
        (begin
          (if (compiler_ir_types.compiler-ir-symbol-owned?
            logical-source-handle)
            (set! ok false)
            unit)
          (unless
            (=
              (compiler_ir_types.compiler-ir-symbol-slot logical-source-handle)
              -1)
            (set! ok false))
          (set! logical-source-handle (+ logical-source-handle 1))))
      (unless (< old-collision-base compact-limit) (set! ok false))
      (unless
        (not (compiler_ir_types.compiler-ir-symbol-owned? old-collision-base))
        (set! ok false))
      (unless
        (= (compiler_ir_types.compiler-ir-symbol-slot old-collision-base) -1)
        (set! ok false))
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-text old-collision-base)
          "")
        (set! ok false))
      ;; Tagged IR payloads around that old boundary stay in the IR domain but
      ;; are not table-owned until actually minted, so they cannot alias or
      ;; index either the source pool or the side table.
      (set! index (- old-collision-base 1))
      (while (<= index (+ old-collision-base 1))
        (let
          [unallocated : i64
            (compiler_ir_types.compiler-ir-symbol-domain-id-for-index index)]
          (begin
            (unless
              (compiler_ir_types.compiler-ir-symbol-domain? unallocated)
              (set! ok false))
            (if (compiler_ir_types.compiler-ir-symbol-owned? unallocated)
              (set! ok false)
              unit)
            (unless
              (= (compiler_ir_types.compiler-ir-symbol-slot unallocated) -1)
              (set! ok false))
            (unless
              (string.eq
                (compiler_ir_types.compiler-ir-symbol-text unallocated)
                "")
              (set! ok false))
            (set! index (+ index 1)))))
      ;; Adjacent identity domains, the compact-u32 limit, and sentinels also
      ;; fail closed rather than indexing or reaching intern-str.
      (unless
        (= (compiler_ir_types.compiler-ir-symbol-slot (- compact-limit 1)) -1)
        (set! ok false))
      (unless
        (= (compiler_ir_types.compiler-ir-symbol-slot cfg-base) -1)
        (set! ok false))
      (unless
        (= (compiler_ir_types.compiler-ir-symbol-slot current-cfg-key) -1)
        (set! ok false))
      (unless
        (= (compiler_ir_types.compiler-ir-symbol-slot structural-base) -1)
        (set! ok false))
      ;; Unminted ids in the IR domain, other tags, and the negative sentinel
      ;; render empty rather than aborting: diagnostics reach this path with
      ;; whatever the IR is holding.
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-text
            (+ base (compiler_ir_types.compiler-ir-symbol-count-value)))
          "")
        (set! ok false))
      (unless
        (string.eq (compiler_ir_types.compiler-ir-symbol-text cfg-base) "")
        (set! ok false))
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-text structural-base)
          "")
        (set! ok false))
      (unless
        (string.eq (compiler_ir_types.compiler-ir-symbol-text (- 0 1)) "")
        (set! ok false))
      ;; Pool ids still render from the pool through the same entry point.
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-text pool-id)
          "ir-smoke-pool-name")
        (set! ok false))
      ;; Growth: mint past the initial 1024-slot slab, then re-read the first
      ;; spelling, which the doubling copy has to have carried over.
      (set! index 0)
      (while (< index 2048)
        (begin
          (set!
            last-grown
            (compiler_ir_types.compiler-ir-symbol
              (str_cat.str-cat "ir-smoke/grow-" (string.int->string index))))
          (set! index (+ index 1))))
      (unless
        (=
          (compiler_ir_types.compiler-ir-symbol-count-value)
          (+ count-before 2050))
        (set! ok false))
      (unless (= last-grown (+ base (+ count-before 2049))) (set! ok false))
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-text first)
          "ir-smoke/one")
        (set! ok false))
      (unless
        (= (compiler_ir_types.compiler-ir-symbol "ir-smoke/one") first)
        (set! ok false))
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-text last-grown)
          "ir-smoke/grow-2047")
        (set! ok false))
      ;; The whole batch cost the intern pool nothing in either lane.
      (unless (= (ci.intern-generated-count) generated-before) (set! ok false))
      (unless (= (ci.intern-pool-len) pool-before) (set! ok false))
      ;; The table is its own spelling authority: resetting and reseeding the
      ;; front-end pool cannot change an answer it has already returned.
      (ci.intern-reset!)
      (cbi.compiler-builtin-reset!)
      (ci.intern-source-slice "ir-smoke-reset-prefix" 0 21)
      (cbi.compiler-builtin-initialize-for-parse!)
      (unless
        (= (compiler_ir_types.compiler-ir-symbol "ir-smoke/one") first)
        (set! ok false))
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-text first)
          "ir-smoke/one")
        (set! ok false))
      ok)))

;; Build a spans table entirely inside a throwaway arena, escape it into the
;; enclosing arena, then destroy the throwaway arena and read the escape. Every
;; lookup below dereferences the escaped slot arrays, so a shallow escape that
;; kept pointing at the destroyed arena's storage faults or reads garbage here.
;; This is the ownership boundary `optimize-program-with-spans-...` relies on
;; when it runs the inliner in its own arena.
(define (compiler-ir-smoke-source-spans-escape-ok?) : bool
  (let
    [enclosing : i64 (arena.tl_arena_current)]
    [scratch : i64 (arena.tl_arena_make)]
    [first : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id
        (compiler-ir-smoke-symbol-id "spans-escape-first"))]
    [second : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id
        (compiler-ir-smoke-symbol-id "spans-escape-second"))]
    [instr-key : compiler_ir_types.CompilerSourceSpansInstrKey
      (compiler_ir_types.CompilerSourceSpansInstrKey.Value first 12)]
    [store-key : compiler_ir_types.CompilerSourceSpansInstrKey
      (compiler_ir_types.CompilerSourceSpansInstrKey.Store second 14)]
    [_enter : unit
      (unsafe
        (arena.tl_arena_set scratch))]
    ;; The empty table starts with zero-length slot arrays, so the first append
    ;; on each side allocates the live storage inside `scratch`.
    [built : compiler_ir_types.CompilerSourceSpans
      (compiler_ir_types.compiler-source-spans-insert-instr-entry-located
        (compiler_ir_types.compiler-source-spans-insert-instr-entry-located
          (compiler_ir_types.compiler-source-spans-insert-located
            (compiler_ir_types.compiler-source-spans-insert-located
              (compiler_ir_types.compiler-source-spans-empty)
              first
              3
              (ast.ast-source-span 10 20 30 40))
            second
            4
            (ast.ast-source-span 50 60 70 80))
          instr-key
          5
          (ast.ast-source-span 90 100 110 120))
        store-key
        6
        (ast.ast-source-span 130 140 150 160))]
    [_leave : unit
      (unsafe
        (arena.tl_arena_set enclosing))]
    [escaped : compiler_ir_types.CompilerSourceSpans
      (compiler_ir_types.compiler-source-spans-escape built)]
    [_destroy : unit
      (unsafe
        (arena.tl_arena_destroy scratch))]
    (and
      (=
        (compiler_ir_types.compiler-source-spans-count
          (compiler_ir_types.compiler-ir-global-shared-view escaped))
        2)
      (=
        (compiler_ir_types.compiler-source-spans-instr-count
          (compiler_ir_types.compiler-ir-global-shared-view escaped))
        2)
      (match (compiler_ir_types.compiler-source-spans-lookup-location
        (compiler_ir_types.compiler-ir-global-shared-view escaped)
        first)
        [(compiler_ir_types.CompilerMaybeSourceLocation.Some
            (compiler_ir_types.CompilerSourceLocation path-id span))
          (and
            (= path-id 3)
            (= (ast.ast-source-span-start-line span) 10)
            (= (ast.ast-source-span-end-col span) 40))]
        [_ false])
      (match (compiler_ir_types.compiler-source-spans-lookup-location
        (compiler_ir_types.compiler-ir-global-shared-view escaped)
        second)
        [(compiler_ir_types.CompilerMaybeSourceLocation.Some
            (compiler_ir_types.CompilerSourceLocation path-id span))
          (and (= path-id 4) (= (ast.ast-source-span-start-line span) 50))]
        [_ false])
      (match escaped
        [(compiler_ir_types.CompilerSourceSpans.Spans _ instr-entries _)
          (and
            (match (compiler_ir_types.compiler-source-spans-instr-entry-list-lookup
              (compiler_ir_types.compiler-ir-global-shared-view instr-entries)
              instr-key)
              [(compiler_ir_types.CompilerMaybeSourceLocation.Some
                  (compiler_ir_types.CompilerSourceLocation path-id span))
                (and
                  (= path-id 5)
                  (= (ast.ast-source-span-start-line span) 90)
                  (= (ast.ast-source-span-end-col span) 120))]
              [_ false])
            (match (compiler_ir_types.compiler-source-spans-instr-entry-list-lookup
              instr-entries
              store-key)
              [(compiler_ir_types.CompilerMaybeSourceLocation.Some
                  (compiler_ir_types.CompilerSourceLocation path-id span))
                (and
                  (= path-id 6)
                  (= (ast.ast-source-span-start-line span) 130))]
              [_ false]))]))))

(define (compiler-ir-smoke-representation-kind-group?
  [kind : compiler_ir_types.CompilerIrRepresentationKind]
  [count : i64]
  [mask : i64]) : bool
  (match kind
    [(compiler_ir_types.CompilerIrRepresentationKind.RegisterGroup
        found-count
        found-mask)
      (and (= found-count count) (= found-mask mask))]
    [_ false]))

(define (compiler-ir-smoke-representation-kind-one?
  [kind : compiler_ir_types.CompilerIrRepresentationKind]) : bool
  (match kind
    [(compiler_ir_types.CompilerIrRepresentationKind.KnownOneWord) true]
    [_ false]))

(define (compiler-ir-smoke-representation-kind-unknown?
  [kind : compiler_ir_types.CompilerIrRepresentationKind]) : bool
  (match kind
    [(compiler_ir_types.CompilerIrRepresentationKind.Unknown) true]
    [_ false]))

(define (compiler-ir-smoke-representation-index-failure) : i64
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [group-name : i64 (ci.intern "RepresentationGroup")]
    [one-name : i64 (ci.intern "RepresentationOne")]
    [conflict-name : i64 (ci.intern "RepresentationConflict")]
    [signature-name : i64
      (compiler_ir_types.compiler-ir-symbol
        "__tl_internal_abi_group_m2__RepresentationSignature")]
    [private-name : i64
      (compiler_ir_types.compiler-ir-symbol
        "__tl_internal_abi_mem_s16__RepresentationPrivate")]
    [malformed-name : i64
      (compiler_ir_types.compiler-ir-symbol
        "__tl_internal_abi_group_m9__RepresentationMalformed")]
    [group-ty : ast.AstType (ast.AstType.Struct group-name)]
    [one-ty : ast.AstType (ast.AstType.Enum one-name)]
    [conflict-ty : ast.AstType (ast.AstType.Struct conflict-name)]
    [signature-ty : ast.AstType (ast.AstType.Struct signature-name)]
    [private-ty : ast.AstType (ast.AstType.Struct private-name)]
    [malformed-ty : ast.AstType (ast.AstType.Struct malformed-name)]
    [group-id : i64
      (ast.ast-node-pool-context-type-push
        (ast.ast-node-pool-context-shared-view (& pools))
        (ast.ast-global-shared-view group-ty))]
    [region-ty : ast.AstType (ast.AstType.Region 77 group-id)]
    [words-gp-sse : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.compiler-ir-value-seq-prepend
        (compiler_ir_types.CompilerIrValue.I64 1)
        (compiler_ir_types.compiler-ir-value-seq-prepend
          (compiler_ir_types.CompilerIrValue.F64 0)
          (compiler_ir_types.compiler-ir-value-seq-empty)))]
    [words-gp-gp : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.compiler-ir-value-seq-prepend
        (compiler_ir_types.CompilerIrValue.I64 1)
        (compiler_ir_types.compiler-ir-value-seq-prepend
          (compiler_ir_types.CompilerIrValue.I64 2)
          (compiler_ir_types.compiler-ir-value-seq-empty)))]
    [words-sse-gp : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.compiler-ir-value-seq-prepend
        (compiler_ir_types.CompilerIrValue.F64 0)
        (compiler_ir_types.compiler-ir-value-seq-prepend
          (compiler_ir_types.CompilerIrValue.I64 2)
          (compiler_ir_types.compiler-ir-value-seq-empty)))]
    [instrs : compiler_ir_types.CompilerIrInstrSeq
      (compiler-ir-types-smoke-instr-seq-prepend
        (compiler_ir_types.CompilerIrInstr.Pack
          1
          words-gp-sse
          (ast.ast-global-shared-view group-ty))
        (compiler-ir-types-smoke-instr-seq-prepend
          (compiler_ir_types.CompilerIrInstr.Mov
            2
            (compiler_ir_types.CompilerIrValue.I64 0)
            (ast.ast-global-shared-view one-ty))
          (compiler-ir-types-smoke-instr-seq-prepend
            (compiler_ir_types.CompilerIrInstr.Pack
              3
              words-gp-gp
              (ast.ast-global-shared-view conflict-ty))
            (compiler-ir-types-smoke-instr-seq-prepend
              (compiler_ir_types.CompilerIrInstr.Pack
                4
                words-sse-gp
                (ast.ast-global-shared-view conflict-ty))
              (compiler-ir-types-smoke-instr-seq-prepend
                (compiler_ir_types.CompilerIrInstr.Mov
                  5
                  (compiler_ir_types.CompilerIrValue.I64 0)
                  (ast.ast-global-shared-view private-ty))
                (compiler-ir-types-smoke-instr-seq-prepend
                  (compiler_ir_types.CompilerIrInstr.Mov
                    6
                    (compiler_ir_types.CompilerIrValue.I64 0)
                    (ast.ast-global-shared-view malformed-ty))
                  (compiler-ir-types-smoke-instr-seq-prepend
                    (compiler_ir_types.ir-instr-descriptor-pair-pack
                      7
                      (compiler_ir_types.CompilerIrValue.I64 0)
                      (compiler_ir_types.CompilerIrValue.I64 0)
                      (compiler_ir_types.CompilerIrDescriptorPairKind.OwnedString))
                    (compiler_ir_types.compiler-ir-instr-seq-empty))))))))]
    [params : compiler_ir_types.CompilerIrParamSeq
      (compiler_ir_types.compiler-ir-param-seq-prepend
        (compiler_ir_types.CompilerIrParam.Param
          "group"
          (ast.ast-global-shared-view signature-ty)
          0)
        (compiler_ir_types.compiler-ir-param-seq-empty))]
    [program : compiler_ir_types.CompilerIrProgram
      (compiler_ir_types.CompilerIrProgram.Program
        (compiler_ir_types.compiler-ir-global-seq-empty)
        (compiler_ir_types.compiler-ir-function-seq-prepend
          (compiler_ir_types.CompilerIrFunction.Function
            (ci.intern "representation_index")
            params
            (ast.ast-global-shared-view one-ty)
            8
            (compiler_ir_types.compiler-ir-block-cons
              (compiler_ir_types.CompilerIrBlock.Block
                (compiler_ir_types.compiler-ir-label "entry")
                instrs)
              compiler_ir_types.CompilerIrBlockList.Nil)
            compiler_ir_types.CompilerIrFunctionAbi.Ordinary)
          (compiler_ir_types.compiler-ir-function-seq-empty))
        (compiler_ir_types.compiler-ir-extern-seq-empty))]
    [bases : i64 (ast.ast-node-pool-context-type-segment-bases pools)]
    [index : compiler_ir_types.CompilerIrRepresentationIndex
      (compiler_ir_types.compiler-ir-representation-index-build bases program)]
    (begin
      (unless
        (compiler-ir-smoke-representation-kind-group?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            index
            group-ty)
          2
          2)
        (return 1))
      (unless
        (compiler-ir-smoke-representation-kind-group?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            index
            region-ty)
          2
          2)
        (return 2))
      (unless
        (compiler-ir-smoke-representation-kind-group?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            index
            signature-ty)
          2
          2)
        (return 3))
      (unless
        (compiler-ir-smoke-representation-kind-one?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            index
            one-ty))
        (return 4))
      (unless
        (compiler-ir-smoke-representation-kind-unknown?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            index
            conflict-ty))
        (return 5))
      (unless
        (compiler-ir-smoke-representation-kind-unknown?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            index
            private-ty))
        (return 6))
      (unless
        (compiler-ir-smoke-representation-kind-unknown?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            index
            malformed-ty))
        (return 7))
      (unless
        (compiler-ir-smoke-representation-kind-unknown?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            index
            (ast.AstType.Var 99)))
        (return 8))
      (unless
        (compiler-ir-smoke-representation-kind-unknown?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            index
            (ast.AstType.String)))
        (return 9))
      0)))

;; --- private SPMD ABI integrity (#7405) ---------------------------------------
;;
;; The base fixture is an AVX-512 helper `@helper` with physical parameters
;; [active mask bool, source 0 varying i64, source 1 uniform i64, index base
;; i64], an appended index mapping, and a varying i64 result, plus a caller
;; `@caller` whose one `spmd_call` passes the three matching arguments. Each
;; case below changes one fact and names the check that must reject it.
(define (pabi-sym [name : String]) : i64
  (compiler-ir-smoke-symbol-id name))

(define (pabi-param
  [ordinal : i64]
  [role : compiler_ir_types.CompilerIrSpmdPrivateParamRole]
  [ty : ast.AstType]) : compiler_ir_types.CompilerIrSpmdPrivateParam
  (compiler_ir_types.CompilerIrSpmdPrivateParam.Param ordinal role ty))

(define (pabi-source
  [source : i64]
  [class : compiler_ir_types.CompilerIrSpmdValueClass]
  [ty : ast.AstType]) : compiler_ir_types.CompilerIrSpmdPrivateParamRole
  (compiler_ir_types.CompilerIrSpmdPrivateParamRole.Source source class ty))

;; Parameter `index` of parameter layout `variant`. Variant 0 is the base
;; layout; 10 drops the index base; the others each break one rule.
(define (pabi-param-at [variant : i64] [index : i64]) : compiler_ir_types.CompilerIrSpmdPrivateParam
  (cond
    [(= index 0)
      (cond
        [(= variant 3)
          (pabi-param
            0
            (pabi-source
              0
              (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
              (ast.AstType.I64))
            (ast.AstType.I64))]
        [(= variant 4)
          (pabi-param
            0
            (compiler_ir_types.CompilerIrSpmdPrivateParamRole.ActiveMask)
            (ast.AstType.I64))]
        [else
          (pabi-param
            0
            (compiler_ir_types.CompilerIrSpmdPrivateParamRole.ActiveMask)
            (ast.AstType.Bool))])]
    [(= index 1)
      (cond
        [(= variant 2)
          (pabi-param
            1
            (pabi-source
              1
              (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
              (ast.AstType.I64))
            (ast.AstType.I64))]
        [(= variant 5)
          (pabi-param
            1
            (compiler_ir_types.CompilerIrSpmdPrivateParamRole.IndexBase)
            (ast.AstType.I64))]
        [(= variant 8)
          (pabi-param
            1
            (pabi-source
              0
              (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
              (ast.AstType.Bool))
            (ast.AstType.Bool))]
        [(= variant 9)
          (pabi-param
            1
            (compiler_ir_types.CompilerIrSpmdPrivateParamRole.ActiveMask)
            (ast.AstType.Bool))]
        [else
          (pabi-param
            1
            (pabi-source
              0
              (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
              (ast.AstType.I64))
            (ast.AstType.I64))])]
    [(= index 2)
      (cond
        [(= variant 1)
          (pabi-param
            5
            (pabi-source
              1
              (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
              (ast.AstType.I64))
            (ast.AstType.I64))]
        [(= variant 2)
          (pabi-param
            2
            (pabi-source
              0
              (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
              (ast.AstType.I64))
            (ast.AstType.I64))]
        [(= variant 7)
          (pabi-param
            2
            (pabi-source
              1
              (compiler_ir_types.CompilerIrSpmdValueClass.Mask)
              (ast.AstType.I64))
            (ast.AstType.I64))]
        [(= variant 11)
          (pabi-param
            2
            (pabi-source
              1
              (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
              (ast.AstType.I64))
            (ast.AstType.U64))]
        [else
          (pabi-param
            2
            (pabi-source
              1
              (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
              (ast.AstType.I64))
            (ast.AstType.I64))])]
    [else
      (pabi-param
        3
        (compiler_ir_types.CompilerIrSpmdPrivateParamRole.IndexBase)
        (if (= variant 6)
          (ast.AstType.I32)
          (ast.AstType.I64)))]))

(define (pabi-params [variant : i64]) : compiler_ir_types.CompilerIrSpmdPrivateParamSeq
  (let
    [count : i64
      (if (= variant 10)
        3
        4)]
    [params : compiler_ir_types.CompilerIrSpmdPrivateParamSeq
      (compiler_ir_types.compiler-ir-spmd-private-param-seq-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler_ir_types.compiler-ir-spmd-private-param-seq-push!
            (&mut params)
            (pabi-param-at variant index))
          (set! index (+ index 1))))
      params)))

(define (pabi-result-varying-i64) : compiler_ir_types.CompilerIrSpmdPrivateResult
  (compiler_ir_types.CompilerIrSpmdPrivateResult.Value
    (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
    (ast.AstType.I64)))

(define (pabi
  [callee : String]
  [backend : compiler_ir_types.CompilerIrSpmdBackend]
  [lanes : i64]
  [variant : i64]
  [index : compiler_ir_types.CompilerIrSpmdPrivateIndex]
  [result : compiler_ir_types.CompilerIrSpmdPrivateResult]) : compiler_ir_types.CompilerIrSpmdPrivateAbi
  (compiler_ir_types.CompilerIrSpmdPrivateAbi
    (compiler_ir_types.CompilerIrSpmdPrivateAbiSchema.V1)
    (pabi-sym callee)
    backend
    lanes
    (pabi-params variant)
    index
    result))

(define (pabi-base) : compiler_ir_types.CompilerIrSpmdPrivateAbi
  (pabi
    "helper"
    (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
    8
    0
    (compiler_ir_types.CompilerIrSpmdPrivateIndex.Appended 3)
    (pabi-result-varying-i64)))

(define (pabi-with-params [variant : i64]) : compiler_ir_types.CompilerIrSpmdPrivateAbi
  (pabi
    "helper"
    (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
    8
    variant
    (compiler_ir_types.CompilerIrSpmdPrivateIndex.Appended 3)
    (pabi-result-varying-i64)))

(define (pabi-contains? [text : String] [fragment : String]) : bool
  (string.contains text fragment))

(define (pabi-shape-rejects?
  [abi : compiler_ir_types.CompilerIrSpmdPrivateAbi]
  [fragment : String]) : bool
  (pabi-contains?
    (compiler_ir_types.compiler-ir-spmd-private-abi-shape-error abi)
    fragment))

;; The helper's actual parameters for the base fixture; `variant` 1 drops the
;; index base and 2 retypes parameter 2 as i32.
(define (pabi-signature-params [variant : i64]) : compiler_ir_types.CompilerIrParamSeq
  (let
    [builder : compiler_ir_types.CompilerIrParamBuilder
      (compiler_ir_types.compiler-ir-param-builder-with-capacity 4)]
    (begin
      (compiler_ir_types.compiler-ir-param-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrParam.Param "mask" (ast.AstType.Bool) 0))
      (compiler_ir_types.compiler-ir-param-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrParam.Param "x" (ast.AstType.I64) 1))
      (compiler_ir_types.compiler-ir-param-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrParam.Param
          "k"
          (if (= variant 2)
            (ast.AstType.I32)
            (ast.AstType.I64))
          2))
      (if (= variant 1)
        unit
        (compiler_ir_types.compiler-ir-param-builder-push!
          (&mut builder)
          (compiler_ir_types.CompilerIrParam.Param "base" (ast.AstType.I64) 3)))
      (compiler_ir_types.compiler-ir-param-builder-to-seq builder))))

(define (pabi-signature-rejects?
  [name : String]
  [variant : i64]
  [ret : ast.AstType]
  [abi : compiler_ir_types.CompilerIrSpmdPrivateAbi]
  [fragment : String]) : bool
  (let
    [message : String
      (compiler_ir_types.compiler-ir-spmd-private-abi-signature-error
        (pabi-sym name)
        (pabi-signature-params variant)
        ret
        abi)]
    (and
      (pabi-contains? (clone message) "private SPMD ABI of @")
      (pabi-contains? message fragment))))

;; Call arguments for the base fixture; `variant` 1 drops the index base, 2
;; makes argument 0 uniform, 3 retypes argument 0 as i32, 4 swaps arguments
;; 0 and 1, 5 makes the index base varying.
(define (pabi-call-args [variant : i64]) : compiler_ir_types.CompilerIrSpmdCallArgSeq
  (let
    [builder : compiler_ir_types.CompilerIrSpmdCallArgBuilder
      (compiler_ir_types.compiler-ir-spmd-call-arg-builder-with-capacity 3)]
    (begin
      (compiler_ir_types.compiler-ir-spmd-call-arg-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrSpmdCallArg.Arg
          (if (or (= variant 2) (= variant 4))
            (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
            (compiler_ir_types.CompilerIrSpmdValueClass.Varying))
          (compiler_ir_types.CompilerIrValue.Var 21)
          (if (= variant 3)
            (ast.AstType.I32)
            (ast.AstType.I64))))
      (compiler_ir_types.compiler-ir-spmd-call-arg-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrSpmdCallArg.Arg
          (if (= variant 4)
            (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
            (compiler_ir_types.CompilerIrSpmdValueClass.Uniform))
          (compiler_ir_types.CompilerIrValue.Var 22)
          (ast.AstType.I64)))
      (if (= variant 1)
        unit
        (compiler_ir_types.compiler-ir-spmd-call-arg-builder-push!
          (&mut builder)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg
            (if (= variant 5)
              (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
              (compiler_ir_types.CompilerIrSpmdValueClass.Uniform))
            (compiler_ir_types.CompilerIrValue.Var 23)
            (ast.AstType.I64))))
      (compiler_ir_types.compiler-ir-spmd-call-arg-builder-to-seq builder))))

(define (pabi-call-result [variant : i64]) : compiler_ir_types.CompilerIrSpmdCallResult
  (cond
    [(= variant 1) (compiler_ir_types.CompilerIrSpmdCallResult.Unit)]
    [(= variant 2)
      (compiler_ir_types.CompilerIrSpmdCallResult.Value
        6
        (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
        (ast.AstType.I64))]
    [(= variant 3)
      (compiler_ir_types.CompilerIrSpmdCallResult.Value
        6
        (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
        (ast.AstType.I32))]
    [else
      (compiler_ir_types.CompilerIrSpmdCallResult.Value
        6
        (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
        (ast.AstType.I64))]))

(define (pabi-call-payload
  [callee : String]
  [backend : compiler_ir_types.CompilerIrSpmdBackend]
  [lanes : i64]
  [mask : compiler_ir_types.CompilerIrValue]
  [args-variant : i64]
  [result-variant : i64]
  [origin : compiler_ir_types.CompilerIrSpmdCallOrigin]) : compiler_ir_types.CompilerIrInstrSpmdCallPayload
  (compiler_ir_types.CompilerIrInstrSpmdCallPayload
    (pabi-sym callee)
    backend
    lanes
    mask
    (pabi-call-args args-variant)
    (pabi-call-result result-variant)
    origin))

(define (pabi-base-payload [args-variant : i64] [result-variant : i64]) : compiler_ir_types.CompilerIrInstrSpmdCallPayload
  (pabi-call-payload
    "helper"
    (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
    8
    (compiler_ir_types.CompilerIrValue.Var 20)
    args-variant
    result-variant
    (compiler_ir_types.compiler-ir-spmd-call-origin-private (pabi-base))))

(define (pabi-call-rejects?
  [payload : compiler_ir_types.CompilerIrInstrSpmdCallPayload]
  [abi : compiler_ir_types.CompilerIrSpmdPrivateAbi]
  [fragment : String]) : bool
  (let
    [message : String
      (compiler_ir_types.compiler-ir-spmd-private-call-error payload abi)]
    (and
      (pabi-contains? (clone message) "private SPMD call to @")
      (pabi-contains? message fragment))))

(define (pabi-helper-function
  [name : String]
  [function-abi : compiler_ir_types.CompilerIrFunctionAbi]) : compiler_ir_types.CompilerIrFunction
  (compiler_ir_types.CompilerIrFunction.Function
    (pabi-sym name)
    (pabi-signature-params 0)
    (ast.AstType.I64)
    4
    (compiler_ir_types.compiler-ir-block-cons
      (compiler_ir_types.CompilerIrBlock.Block
        (compiler_ir_types.compiler-ir-label "entry")
        (compiler_ir_types.compiler-ir-instr-seq1
          (compiler_ir_types.CompilerIrInstr.Return
            (compiler_ir_types.CompilerIrMaybeValue.Some
              (compiler_ir_types.CompilerIrValue.Var 1)))))
      compiler_ir_types.CompilerIrBlockList.Nil)
    function-abi))

(define (pabi-caller-function
  [payload : compiler_ir_types.CompilerIrInstrSpmdCallPayload]) : compiler_ir_types.CompilerIrFunction
  (compiler_ir_types.CompilerIrFunction.Function
    (pabi-sym "caller")
    (compiler_ir_types.compiler-ir-param-seq-empty)
    (ast.AstType.Unit)
    30
    (compiler_ir_types.compiler-ir-block-cons
      (compiler_ir_types.CompilerIrBlock.Block
        (compiler_ir_types.compiler-ir-label "entry")
        (compiler_ir_types.compiler-ir-instr-seq2
          (compiler_ir_types.CompilerIrInstr.SpmdCall (box payload))
          (compiler_ir_types.CompilerIrInstr.Return
            compiler_ir_types.CompilerIrMaybeValue.No)))
      compiler_ir_types.CompilerIrBlockList.Nil)
    compiler_ir_types.CompilerIrFunctionAbi.Ordinary))

(define (pabi-program-error
  [helper : compiler_ir_types.CompilerIrFunction]
  [payload : compiler_ir_types.CompilerIrInstrSpmdCallPayload]) : String
  (let
    [builder : compiler_ir_types.CompilerIrFunctionBuilder
      (compiler_ir_types.compiler-ir-function-builder-new)]
    (begin
      (compiler_ir_types.compiler-ir-function-builder-push!
        (&mut builder)
        (pabi-caller-function payload))
      (compiler_ir_types.compiler-ir-function-builder-push!
        (&mut builder)
        helper)
      (let
        [functions : compiler_ir_types.CompilerIrFunctionSeq
          (compiler_ir_types.compiler-ir-function-builder-to-seq builder)]
        (compiler_ir_types.compiler-ir-spmd-private-abi-program-error
          functions)))))

(define (pabi-program-rejects?
  [helper : compiler_ir_types.CompilerIrFunction]
  [payload : compiler_ir_types.CompilerIrInstrSpmdCallPayload]
  [fragment : String]) : bool
  (pabi-contains? (pabi-program-error helper payload) fragment))

(define (pabi-private-helper) : compiler_ir_types.CompilerIrFunction
  (pabi-helper-function
    "helper"
    (compiler_ir_types.compiler-ir-function-abi-private (pabi-base))))

(define (pabi-render-function [func : compiler_ir_types.CompilerIrFunction]) : String
  (compiler_ir_types.compiler-ir-function-render
    (cis.InternStructuralSessionHandle 0)
    (ast.ast-node-pool-reader-type-segment-bases)
    func))

(define (pabi-function-private-abi
  [func : compiler_ir_types.CompilerIrFunction]) : compiler_ir_types.CompilerIrSpmdPrivateAbi
  (match (compiler_ir_types.compiler-ir-function-abi func)
    [(compiler_ir_types.CompilerIrFunctionAbi.SpmdPrivate private-box)
      (deref private-box)]
    [(compiler_ir_types.CompilerIrFunctionAbi.Ordinary)
      (pabi
        "ordinary"
        (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
        1
        10
        (compiler_ir_types.CompilerIrSpmdPrivateIndex.None)
        (compiler_ir_types.CompilerIrSpmdPrivateResult.Unit))]))

;; 0 when every case holds, else the number of the first failing case.
(define (compiler-ir-smoke-spmd-private-abi-failure) : i64
  (let
    [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-reader-context-current)]
    [i64-ty : ast.AstType (ast.AstType.I64)]
    (cond
      ;; The base fixture is valid on every level.
      [(not
          (string.eq
            (compiler_ir_types.compiler-ir-spmd-private-abi-shape-error
              (pabi-base))
            ""))
        1]
      [(not
          (string.eq
            (compiler_ir_types.compiler-ir-spmd-private-abi-signature-error
              (pabi-sym "helper")
              (pabi-signature-params 0)
              (clone i64-ty)
              (pabi-base))
            ""))
        2]
      [(not
          (string.eq
            (compiler_ir_types.compiler-ir-spmd-private-call-error
              (pabi-base-payload 0 0)
              (pabi-base))
            ""))
        3]
      [(not
          (string.eq
            (pabi-program-error (pabi-private-helper) (pabi-base-payload 0 0))
            ""))
        4]
      [(not
          (string.eq
            (compiler_ir_types.compiler-ir-spmd-call-descriptor-error
              (pabi-base-payload 0 0))
            ""))
        5]
      ;; Descriptor shape: lanes, parameter roles and ordinals, index mapping,
      ;; and result class.
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
              8
              10
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.None)
              (pabi-result-varying-i64))
            "scalar descriptor has 8 lanes"))
        6]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              6
              0
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.Appended 3)
              (pabi-result-varying-i64))
            "not a power of two"))
        7]
      [(not (pabi-shape-rejects? (pabi-with-params 1) "records ordinal 5")) 8]
      [(not
          (pabi-shape-rejects?
            (pabi-with-params 2)
            "maps source parameter 1, not 0"))
        9]
      [(not
          (pabi-shape-rejects?
            (pabi-with-params 3)
            "physical parameter 0 is not the active mask"))
        10]
      [(not
          (pabi-shape-rejects?
            (pabi-with-params 4)
            "active mask parameter is not bool"))
        11]
      [(not
          (pabi-shape-rejects? (pabi-with-params 5) "is not the last parameter"))
        12]
      [(not
          (pabi-shape-rejects?
            (pabi-with-params 6)
            "index base parameter is not i64"))
        13]
      [(not
          (pabi-shape-rejects?
            (pabi-with-params 7)
            "mask source parameter 1 is not bool"))
        14]
      [(not
          (pabi-shape-rejects? (pabi-with-params 8) "a varying bool is a mask"))
        15]
      [(not
          (pabi-shape-rejects?
            (pabi-with-params 9)
            "active mask at physical parameter 1"))
        16]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              0
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.None)
              (pabi-result-varying-i64))
            "without an appended index mapping"))
        17]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              10
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.Appended 2)
              (pabi-result-varying-i64))
            "appended index mapping without an index base parameter"))
        18]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              0
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.Appended 2)
              (pabi-result-varying-i64))
            "not the last"))
        19]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              10
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.ReuseSource 1)
              (pabi-result-varying-i64))
            "reused index source parameter 1 is not varying"))
        20]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              10
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.ReuseSource 2)
              (pabi-result-varying-i64))
            "reused index source parameter 2 is out of range"))
        21]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              0
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.ReuseSource 0)
              (pabi-result-varying-i64))
            "index base parameter with a reused source index"))
        22]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
              1
              10
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.ReuseSource 0)
              (pabi-result-varying-i64))
            "scalar descriptor maps a logical index"))
        23]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              0
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.Appended 3)
              (compiler_ir_types.CompilerIrSpmdPrivateResult.Value
                (compiler_ir_types.CompilerIrSpmdValueClass.Mask)
                (ast.AstType.I64)))
            "mask result is not bool"))
        24]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              0
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.Appended 3)
              (compiler_ir_types.CompilerIrSpmdPrivateResult.Value
                (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
                (ast.AstType.Bool)))
            "varying result is bool"))
        25]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              0
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.Appended 3)
              (compiler_ir_types.CompilerIrSpmdPrivateResult.Value
                (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
                (ast.AstType.Unit)))
            "valued result has type unit"))
        26]
      ;; Helper side: the descriptor against the actual signature.
      [(not
          (pabi-signature-rejects?
            "other"
            0
            (clone i64-ty)
            (pabi-base)
            "descriptor names callee @helper"))
        27]
      [(not
          (pabi-signature-rejects?
            "helper"
            1
            (clone i64-ty)
            (pabi-base)
            "descriptor has 4 physical parameters, the signature has 3"))
        28]
      [(not
          (pabi-signature-rejects?
            "helper"
            2
            (clone i64-ty)
            (pabi-base)
            "physical parameter 2 type differs from the signature"))
        29]
      [(not
          (pabi-signature-rejects?
            "helper"
            0
            (ast.AstType.I32)
            (pabi-base)
            "result type differs from the signature"))
        30]
      [(not
          (pabi-signature-rejects?
            "helper"
            0
            (clone i64-ty)
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              0
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.Appended 3)
              (compiler_ir_types.CompilerIrSpmdPrivateResult.Unit))
            "unit result but the signature returns a value"))
        31]
      ;; Call side: the payload against the descriptor it carries.
      [(not
          (pabi-call-rejects?
            (pabi-call-payload
              "other"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              (compiler_ir_types.CompilerIrValue.Var 20)
              0
              0
              (compiler_ir_types.compiler-ir-spmd-call-origin-private
                (pabi-base)))
            (pabi-base)
            "the descriptor names callee @helper"))
        32]
      [(not
          (pabi-call-rejects?
            (pabi-call-payload
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx2)
              8
              (compiler_ir_types.CompilerIrValue.Var 20)
              0
              0
              (compiler_ir_types.compiler-ir-spmd-call-origin-private
                (pabi-base)))
            (pabi-base)
            "call backend avx2, the descriptor says avx512"))
        33]
      [(not
          (pabi-call-rejects?
            (pabi-call-payload
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              16
              (compiler_ir_types.CompilerIrValue.Var 20)
              0
              0
              (compiler_ir_types.compiler-ir-spmd-call-origin-private
                (pabi-base)))
            (pabi-base)
            "call has 16 lanes, the descriptor 8"))
        34]
      [(not
          (pabi-call-rejects?
            (pabi-call-payload
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              (compiler_ir_types.CompilerIrValue.I64 1)
              0
              0
              (compiler_ir_types.compiler-ir-spmd-call-origin-private
                (pabi-base)))
            (pabi-base)
            "active mask is not a bool value"))
        35]
      [(not
          (pabi-call-rejects?
            (pabi-base-payload 1 0)
            (pabi-base)
            "call has 2 arguments, the descriptor 3"))
        36]
      [(not
          (pabi-call-rejects?
            (pabi-base-payload 2 0)
            (pabi-base)
            "argument 0 is uniform, the descriptor says varying"))
        37]
      [(not
          (pabi-call-rejects?
            (pabi-base-payload 3 0)
            (pabi-base)
            "argument 0 type differs from the descriptor"))
        38]
      [(not
          (pabi-call-rejects?
            (pabi-base-payload 4 0)
            (pabi-base)
            "argument 0 is uniform, the descriptor says varying"))
        39]
      [(not
          (pabi-call-rejects?
            (pabi-base-payload 5 0)
            (pabi-base)
            "argument 2 is not the uniform i64 index base"))
        40]
      [(not
          (pabi-call-rejects?
            (pabi-base-payload 0 1)
            (pabi-base)
            "unit call of a valued helper"))
        41]
      [(not
          (pabi-call-rejects?
            (pabi-base-payload 0 2)
            (pabi-base)
            "result is uniform, the descriptor says varying"))
        42]
      [(not
          (pabi-call-rejects?
            (pabi-base-payload 0 3)
            (pabi-base)
            "result type differs from the descriptor"))
        43]
      [(not
          (pabi-call-rejects?
            (pabi-base-payload 0 0)
            (pabi
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              0
              (compiler_ir_types.CompilerIrSpmdPrivateIndex.Appended 3)
              (compiler_ir_types.CompilerIrSpmdPrivateResult.Unit))
            "valued call of a unit helper"))
        44]
      ;; The optimizer's per-call integrity check sees the same call-side error.
      [(not
          (pabi-contains?
            (compiler_ir_types.compiler-ir-spmd-call-descriptor-error
              (pabi-base-payload 2 0))
            "argument 0 is uniform"))
        45]
      ;; Whole program: the call's descriptor must be its callee's.
      [(not
          (pabi-program-rejects?
            (pabi-helper-function
              "helper"
              compiler_ir_types.CompilerIrFunctionAbi.Ordinary)
            (pabi-base-payload 0 0)
            "in @caller: private SPMD call to @helper: the callee has the ordinary ABI"))
        46]
      [(not
          (pabi-program-rejects?
            (pabi-helper-function
              "elsewhere"
              compiler_ir_types.CompilerIrFunctionAbi.Ordinary)
            (pabi-base-payload 0 0)
            "no same-program private helper has that name"))
        47]
      [(not
          (pabi-program-rejects?
            (pabi-helper-function
              "helper"
              (compiler_ir_types.compiler-ir-function-abi-private
                (pabi-with-params 11)))
            (pabi-base-payload 0 0)
            "private SPMD ABI of @helper: physical parameter 2 type differs from the signature"))
        48]
      [(not
          (pabi-program-rejects?
            (compiler_ir_types.CompilerIrFunction.Function
              (pabi-sym "helper")
              (let
                [builder : compiler_ir_types.CompilerIrParamBuilder
                  (compiler_ir_types.compiler-ir-param-builder-with-capacity 4)]
                (begin
                  (compiler_ir_types.compiler-ir-param-builder-push!
                    (&mut builder)
                    (compiler_ir_types.CompilerIrParam.Param
                      "mask"
                      (ast.AstType.Bool)
                      0))
                  (compiler_ir_types.compiler-ir-param-builder-push!
                    (&mut builder)
                    (compiler_ir_types.CompilerIrParam.Param
                      "x"
                      (ast.AstType.I64)
                      1))
                  (compiler_ir_types.compiler-ir-param-builder-push!
                    (&mut builder)
                    (compiler_ir_types.CompilerIrParam.Param
                      "k"
                      (ast.AstType.U64)
                      2))
                  (compiler_ir_types.compiler-ir-param-builder-push!
                    (&mut builder)
                    (compiler_ir_types.CompilerIrParam.Param
                      "base"
                      (ast.AstType.I64)
                      3))
                  (compiler_ir_types.compiler-ir-param-builder-to-seq builder)))
              (ast.AstType.I64)
              4
              compiler_ir_types.CompilerIrBlockList.Nil
              (compiler_ir_types.compiler-ir-function-abi-private
                (pabi-with-params 11)))
            (pabi-base-payload 0 0)
            "the call's descriptor differs from the helper's"))
        49]
      [(not
          (pabi-program-rejects?
            (pabi-private-helper)
            (pabi-call-payload
              "helper"
              (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
              8
              (compiler_ir_types.CompilerIrValue.Var 20)
              0
              0
              (compiler_ir_types.CompilerIrSpmdCallOrigin.Imported
                (box
                  (compiler_ir_types.CompilerIrImportedSpmdCall
                    "fixture"
                    "1.0.0"
                    "fixture/helper"
                    "(-> i64 i64 i64)"
                    "spmd-call-v1"
                    "avx512"
                    8
                    "vuu"
                    "v"
                    -1
                    "helper"))))
            "imported call targets a same-program private helper"))
        50]
      [(not
          (pabi-program-rejects?
            (pabi-private-helper)
            (pabi-base-payload 3 0)
            "in @caller: private SPMD call to @helper: argument 0 type differs"))
        51]
      ;; Round trips: clone, compaction, and rendering keep the exact record.
      [(not
          (compiler_ir_types.compiler-ir-spmd-private-abi-eq?
            bases
            (pabi-function-private-abi
              (compiler_ir_types.compiler-ir-clone-function
                pools
                (pabi-private-helper)))
            (pabi-base)))
        52]
      [(not
          (compiler_ir_types.compiler-ir-spmd-private-abi-eq?
            bases
            (pabi-function-private-abi
              (compiler_ir_types.compiler-ir-function-compact-blocks
                (pabi-private-helper)))
            (pabi-base)))
        53]
      [(compiler_ir_types.compiler-ir-spmd-private-abi-eq?
          bases
          (pabi-with-params 11)
          (pabi-base))
        54]
      [(not
          (string.eq
            (pabi-render-function
              (compiler_ir_types.compiler-ir-clone-function
                pools
                (pabi-private-helper)))
            (pabi-render-function (pabi-private-helper))))
        55]
      [(not
          (pabi-contains?
            (pabi-render-function (pabi-private-helper))
            (str_cat.str-cat
              "vars 4 abi spmd-private-v1 @helper avx512 lanes 8 [0 active-mask : bool,"
              " 1 source 0 varying i64 : i64, 2 source 1 uniform i64 : i64,"
              " 3 index-base : i64] index appended 3 result varying i64 {")))
        56]
      [(pabi-contains?
          (pabi-render-function
            (pabi-helper-function
              "helper"
              compiler_ir_types.CompilerIrFunctionAbi.Ordinary))
          " abi ")
        57]
      [(not
          (match (compiler_ir_types.compiler-ir-clone-instr
            pools
            (compiler_ir_types.CompilerIrInstr.SpmdCall
              (box (pabi-base-payload 0 0))))
            [(compiler_ir_types.CompilerIrInstr.SpmdCall payload-box)
              (match (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                origin)
                [(compiler_ir_types.CompilerIrSpmdCallOrigin.Private
                    private-box)
                  (compiler_ir_types.compiler-ir-spmd-private-abi-eq?
                    bases
                    (deref private-box)
                    (pabi-base))]
                [_ false])]
            [_ false]))
        58]
      [else 0])))

;; Operand API: one sample per instruction variant. Uses are numbered from 10
;; in constructor order, the def is 1 and labels count from 70. The expected
;; summary pins each variant's uses (role letter and var), def, successor
;; labels and whether it states a destination type; the remaining checks hold
;; the macros consistent with each other.
(define compiler-ir-smoke-operand-visits : i64
  0)
(define compiler-ir-smoke-operand-labels : String
  "")

(define (operand-var [id : i64]) : compiler_ir_types.CompilerIrValue
  (compiler_ir_types.CompilerIrValue.Var id))

(define (compiler-ir-smoke-operand-origin) : compiler_ir_types.CompilerIrSpmdCallOrigin
  (compiler_ir_types.CompilerIrSpmdCallOrigin.Imported
    (box
      (compiler_ir_types.CompilerIrImportedSpmdCall
        "pkg"
        "1.0.0"
        "helper"
        "sig"
        "spmd-call-v1"
        "avx2"
        4
        "args"
        "result"
        0
        "link"))))

(define (compiler-ir-smoke-operand-slots) : compiler_ir_types.CompilerIrCAbiReturnSlotSeq
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrCAbiReturnSlot)
      (__tl_make-array compiler_ir_types.CompilerIrCAbiReturnSlot 1)]
    (begin
      (set!
        (array-ref slots 0)
        (compiler_ir_types.CompilerIrCAbiReturnSlot.Slot (ast.AstType.I64) 0))
      (compiler_ir_types.CompilerIrCAbiReturnSlotSeq slots 1))))

(define (compiler-ir-smoke-role-letter
  [role : compiler_ir_types.CompilerIrOperandRole]) : String
  (match role
    [(compiler_ir_types.CompilerIrOperandRole.Scalar) "S"]
    [(compiler_ir_types.CompilerIrOperandRole.Address) "A"]
    [(compiler_ir_types.CompilerIrOperandRole.Vector) "V"]
    [(compiler_ir_types.CompilerIrOperandRole.Mask) "M"]
    [(compiler_ir_types.CompilerIrOperandRole.CallArg) "C"]
    [(compiler_ir_types.CompilerIrOperandRole.PhiInput) "P"]
    [(compiler_ir_types.CompilerIrOperandRole.Condition) "D"]))

(define (compiler-ir-smoke-use-text
  [delta : i64]
  [role : compiler_ir_types.CompilerIrOperandRole]
  [acc : String]
  [value : compiler_ir_types.CompilerIrValue]) : String
  (str_cat.str-cat
    acc
    " "
    (compiler-ir-smoke-role-letter role)
    (match value
      [(compiler_ir_types.CompilerIrValue.Var id)
        (string.int->string (+ id delta))]
      [_ "?"])))

(define (compiler-ir-smoke-uses-text
  [instr : compiler_ir_types.CompilerIrInstr]
  [delta : i64]) : String
  (let
    [empty : String ""]
    (compiler_ir_types.compiler-ir-instr-fold-uses
      instr
      empty
      compiler-ir-smoke-use-text
      delta)))

(define (compiler-ir-smoke-count-use
  [_role : compiler_ir_types.CompilerIrOperandRole]
  [_value : compiler_ir_types.CompilerIrValue]) : unit
  (set! compiler-ir-smoke-operand-visits (+ compiler-ir-smoke-operand-visits 1)))

(define (compiler-ir-smoke-count-fold
  [_role : compiler_ir_types.CompilerIrOperandRole]
  [acc : i64]
  [_value : compiler_ir_types.CompilerIrValue]) : i64
  (+ acc 1))

(define (compiler-ir-smoke-visits-match-fold?
  [instr : compiler_ir_types.CompilerIrInstr]) : bool
  (let
    [zero : i64 0]
    (begin
      (set! compiler-ir-smoke-operand-visits 0)
      (compiler_ir_types.compiler-ir-instr-visit-uses
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        compiler-ir-smoke-count-use)
      (=
        compiler-ir-smoke-operand-visits
        (compiler_ir_types.compiler-ir-instr-fold-uses
          instr
          zero
          compiler-ir-smoke-count-fold)))))

(define (compiler-ir-smoke-shift-use
  [delta : i64]
  [_role : compiler_ir_types.CompilerIrOperandRole]
  [value : compiler_ir_types.CompilerIrValue]) : compiler_ir_types.CompilerIrValue
  (match (compiler_ir_types.compiler-ir-global-shared-view value)
    [(compiler_ir_types.CompilerIrValue.Var id) (operand-var (+ id delta))]
    [_ value]))

(define (compiler-ir-smoke-shift-def [dst : i64]) : i64
  (+ dst 1000))

(define (compiler-ir-smoke-shift-label [label : i64]) : i64
  (+ label 7))

(define (compiler-ir-smoke-note-label [delta : i64] [label : i64]) : unit
  (set!
    compiler-ir-smoke-operand-labels
    (str_cat.str-cat
      (compiler_ir_types.compiler-ir-global-shared-view
        compiler-ir-smoke-operand-labels)
      " "
      (string.int->string (+ label delta)))))

(define (compiler-ir-smoke-successor-text
  [instr : compiler_ir_types.CompilerIrInstr]
  [delta : i64]) : String
  (begin
    (set! compiler-ir-smoke-operand-labels "")
    (compiler_ir_types.compiler-ir-instr-visit-successors
      instr
      compiler-ir-smoke-note-label
      delta)
    (compiler_ir_types.compiler-ir-global-shared-view
      compiler-ir-smoke-operand-labels)))

(define (compiler-ir-smoke-operand-summary
  [instr : compiler_ir_types.CompilerIrInstr]) : String
  (str_cat.str-cat
    (compiler-ir-smoke-uses-text
      (compiler_ir_types.compiler-ir-global-shared-view instr)
      0)
    " | dst "
    (string.int->string
      (compiler_ir_types.compiler-ir-instr-dst
        (compiler_ir_types.compiler-ir-global-shared-view instr)))
    " | succ"
    (compiler-ir-smoke-successor-text
      (compiler_ir_types.compiler-ir-global-shared-view instr)
      0)
    (match (compiler_ir_types.compiler-ir-instr-dst-type instr)
      [(ast.AstMaybeType.Some _) " | typed"]
      [(ast.AstMaybeType.No) ""])))

(define (compiler-ir-smoke-value-eq
  [a : compiler_ir_types.CompilerIrValue]
  [b : compiler_ir_types.CompilerIrValue]) : bool
  (match a
    [(compiler_ir_types.CompilerIrValue.Var x)
      (match b
        [(compiler_ir_types.CompilerIrValue.Var y) (= x y)]
        [_ false])]
    [_ false]))

(define (compiler-ir-smoke-type-eq [a : ast.AstType] [b : ast.AstType]) : bool
  (match a
    [(ast.AstType.I64)
      (match b
        [(ast.AstType.I64) true]
        [_ false])]
    [_ false]))

(define (compiler-ir-smoke-zip-eq?
  [a : compiler_ir_types.CompilerIrInstr]
  [b : compiler_ir_types.CompilerIrInstr]) : bool
  (compiler_ir_types.compiler-ir-instr-zip-eq
    a
    b
    compiler-ir-smoke-value-eq
    compiler-ir-smoke-type-eq))

;; 0, or the number of the failed check.
(define (compiler-ir-smoke-operand-failure
  [instr : compiler_ir_types.CompilerIrInstr]
  [expected : String]) : i64
  (let
    [dst : i64
      (compiler_ir_types.compiler-ir-instr-dst
        (compiler_ir_types.compiler-ir-global-shared-view instr))]
    [spmd? : bool
      (match (compiler_ir_types.compiler-ir-global-shared-view instr)
        [(compiler_ir_types.CompilerIrInstr.SpmdCall _) true]
        [_ false])]
    [mapped : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.compiler-ir-instr-map-uses
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        compiler-ir-smoke-shift-use
        100)]
    [renamed : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.compiler-ir-instr-map
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        _
        compiler-ir-smoke-shift-def
        _
        compiler-ir-smoke-shift-label)]
    (cond
      [(not
          (string.eq
            (compiler-ir-smoke-operand-summary
              (compiler_ir_types.compiler-ir-global-shared-view instr))
            expected))
        1]
      [(not
          (compiler-ir-smoke-visits-match-fold?
            (compiler_ir_types.compiler-ir-global-shared-view instr)))
        2]
      [(not
          (string.eq
            (compiler-ir-smoke-uses-text
              (compiler_ir_types.compiler-ir-global-shared-view mapped)
              0)
            (compiler-ir-smoke-uses-text
              (compiler_ir_types.compiler-ir-global-shared-view instr)
              100)))
        3]
      [(not
          (=
            (compiler_ir_types.compiler-ir-instr-dst
              (compiler_ir_types.compiler-ir-global-shared-view renamed))
            (if (< dst 0)
              dst
              (+ dst 1000))))
        4]
      [(not
          (string.eq
            (compiler-ir-smoke-successor-text
              (compiler_ir_types.compiler-ir-global-shared-view renamed)
              0)
            (compiler-ir-smoke-successor-text
              (compiler_ir_types.compiler-ir-global-shared-view instr)
              7)))
        5]
      [(not
          (=
            (compiler-ir-smoke-zip-eq?
              (compiler_ir_types.compiler-ir-global-shared-view instr)
              (compiler_ir_types.compiler-ir-global-shared-view instr))
            (not spmd?)))
        6]
      [(and
          (not
            (string.eq
              (compiler-ir-smoke-uses-text
                (compiler_ir_types.compiler-ir-global-shared-view instr)
                0)
              ""))
          (compiler-ir-smoke-zip-eq?
            (compiler_ir_types.compiler-ir-global-shared-view instr)
            (compiler_ir_types.compiler-ir-global-shared-view mapped)))
        7]
      [(and
          (not spmd?)
          (not
            (compiler-ir-smoke-zip-eq?
              (compiler_ir_types.compiler-ir-clone-instr
                (ast.ast-node-pool-reader-context-current)
                (compiler_ir_types.compiler-ir-global-shared-view instr))
              (compiler_ir_types.compiler-ir-global-shared-view instr))))
        8]
      [(not
          (=
            (compiler_ir_types.compiler-ir-instr-dst
              (compiler_ir_types.compiler-ir-instr-with-dst instr 5))
            (if (< dst 0)
              dst
              5)))
        9]
      [else 0])))

;; 0, or 100 * the sample index plus the failed check.
(define (compiler-ir-smoke-operand-api-failure) : i64
  (let
    [index : i64 1]
    [failure : i64 0]
    (begin
      (while (and (= failure 0) (<= index 54))
        (begin
          (set!
            failure
            (compiler-ir-smoke-operand-failure
              (compiler-ir-smoke-operand-sample index)
              (compiler-ir-smoke-operand-expect index)))
          (set! index (+ index 1))))
      (if (= failure 0)
        0
        (+ (* (- index 1) 100) failure)))))

(define (compiler-ir-smoke-operand-sample [index : i64]) : compiler_ir_types.CompilerIrInstr
  (cond
    [(= index 1)
      (compiler_ir_types.CompilerIrInstr.Mov
        1
        (operand-var 10)
        (ast.AstType.I64))]
    [(= index 2) (compiler_ir_types.CompilerIrInstr.Alloc 1 (ast.AstType.I64))]
    [(= index 3) (compiler_ir_types.CompilerIrInstr.AddrOf 1 50)]
    [(= index 4)
      (compiler_ir_types.CompilerIrInstr.Gep
        1
        (operand-var 10)
        (operand-var 11)
        (ast.AstType.I64))]
    [(= index 5)
      (compiler_ir_types.CompilerIrInstr.Load
        1
        (operand-var 10)
        (ast.AstType.I64))]
    [(= index 6)
      (compiler_ir_types.CompilerIrInstr.StoreOwned
        (operand-var 10)
        (operand-var 11)
        (ast.AstType.I64))]
    [(= index 7)
      (compiler_ir_types.CompilerIrInstr.StorePtr
        (operand-var 10)
        (operand-var 11)
        (ast.AstType.I64))]
    [(= index 8)
      (compiler_ir_types.CompilerIrInstr.CopyBytes
        (operand-var 10)
        (operand-var 11)
        4)]
    [(= index 9)
      (compiler_ir_types.CompilerIrInstr.BoundsCheck
        (operand-var 10)
        (operand-var 11)
        70)]
    [(= index 10)
      (compiler_ir_types.CompilerIrInstr.Cast
        1
        (operand-var 10)
        (ast.AstType.I64)
        (ast.AstType.I64))]
    [(= index 11)
      (compiler_ir_types.CompilerIrInstr.Bitcast
        1
        (operand-var 10)
        (ast.AstType.I64)
        (ast.AstType.I64))]
    [(= index 12)
      (compiler_ir_types.CompilerIrInstr.BinOp
        1
        (compiler_ir_types.CompilerIrBinOp.Add)
        (operand-var 10)
        (operand-var 11)
        (ast.AstType.I64))]
    [(= index 13)
      (compiler_ir_types.CompilerIrInstr.UnOp
        1
        (compiler_ir_types.CompilerIrUnOp.Neg)
        (operand-var 10)
        (ast.AstType.I64))]
    [(= index 14)
      (compiler_ir_types.CompilerIrInstr.LaneId 1 4 (ast.AstType.I64))]
    [(= index 15)
      (compiler_ir_types.CompilerIrInstr.Splat
        1
        (operand-var 10)
        4
        (ast.AstType.I64))]
    [(= index 16)
      (compiler_ir_types.ir-instr-vector-bin-op
        1
        (compiler_ir_types.CompilerIrBinOp.Add)
        (operand-var 10)
        (operand-var 11)
        4
        (ast.AstType.I64))]
    [(= index 17)
      (compiler_ir_types.ir-instr-vector-prefix
        1
        (compiler_ir_types.CompilerIrVectorPrefixOp.Sum)
        (operand-var 10)
        (operand-var 11)
        4
        (ast.AstType.I64))]
    [(= index 18)
      (compiler_ir_types.CompilerIrInstr.VectorReduce
        1
        (compiler_ir_types.CompilerIrVectorReduceOp.Sum)
        (operand-var 10)
        4
        (ast.AstType.I64))]
    [(= index 19)
      (compiler_ir_types.ir-instr-vector-compare
        1
        (compiler_ir_types.CompilerIrBinOp.Add)
        (operand-var 10)
        (operand-var 11)
        4
        (ast.AstType.I64))]
    [(= index 20)
      (compiler_ir_types.CompilerIrInstr.MaskBinOp
        1
        (compiler_ir_types.CompilerIrMaskBinOp.And)
        (operand-var 10)
        (operand-var 11)
        4)]
    [(= index 21)
      (compiler_ir_types.CompilerIrInstr.MaskNot 1 (operand-var 10) 4)]
    [(= index 22)
      (compiler_ir_types.CompilerIrInstr.MaskReduce
        1
        (compiler_ir_types.CompilerIrMaskReduceOp.Any)
        (operand-var 10)
        4)]
    [(= index 23)
      (compiler_ir_types.ir-instr-select
        1
        (operand-var 10)
        (operand-var 11)
        (operand-var 12)
        4
        (ast.AstType.I64))]
    [(= index 24)
      (compiler_ir_types.CompilerIrInstr.VectorLoad
        1
        (operand-var 10)
        (operand-var 11)
        4
        (ast.AstType.I64))]
    [(= index 25)
      (compiler_ir_types.ir-instr-vector-store
        (operand-var 10)
        (operand-var 11)
        (operand-var 12)
        4
        (ast.AstType.I64))]
    [(= index 26)
      (compiler_ir_types.ir-instr-predicated-store
        (operand-var 10)
        (operand-var 11)
        (operand-var 12)
        (operand-var 13)
        4
        (ast.AstType.I64))]
    [(= index 27)
      (compiler_ir_types.ir-instr-predicated-load
        1
        (operand-var 10)
        (operand-var 11)
        (operand-var 12)
        4
        (ast.AstType.I64))]
    [(= index 28)
      (compiler_ir_types.ir-instr-gather-load
        1
        (operand-var 10)
        (operand-var 11)
        (operand-var 12)
        true
        4
        (ast.AstType.I64))]
    [(= index 29)
      (compiler_ir_types.ir-instr-vector-shuffle
        1
        (operand-var 10)
        (operand-var 11)
        (compiler_ir_types.CompilerIrMaybeValue.Some (operand-var 12))
        (operand-var 13)
        4
        (ast.AstType.I64))]
    [(= index 30)
      (compiler_ir_types.CompilerIrInstr.TailMask
        1
        (operand-var 10)
        (operand-var 11)
        4)]
    [(= index 31) (compiler_ir_types.CompilerIrInstr.EntryArgc 1)]
    [(= index 32) (compiler_ir_types.CompilerIrInstr.EntryArgv 1)]
    [(= index 33) (compiler_ir_types.CompilerIrInstr.EntryEnvp 1)]
    [(= index 34)
      (compiler_ir_types.CompilerIrInstr.CpuId
        1
        (operand-var 10)
        (operand-var 11)
        4)]
    [(= index 35) (compiler_ir_types.CompilerIrInstr.Xgetbv 1 (operand-var 10))]
    [(= index 36)
      (compiler_ir_types.CompilerIrInstr.Syscall
        1
        (compiler_ir_types.CompilerIrCallArgs.Two
          (operand-var 10)
          (operand-var 11)))]
    [(= index 37)
      (compiler_ir_types.CompilerIrInstr.Call
        1
        0
        (compiler_ir_types.CompilerIrCallArgs.Two
          (operand-var 10)
          (operand-var 11))
        (ast.AstType.I64))]
    [(= index 38)
      (compiler_ir_types.CompilerIrInstr.CallIndirect
        1
        (operand-var 10)
        (compiler_ir_types.CompilerIrCallArgs.Two
          (operand-var 11)
          (operand-var 12))
        (ast.AstType.I64))]
    [(= index 39)
      (compiler_ir_types.CompilerIrInstr.CallIndirectC
        1
        (operand-var 10)
        (compiler_ir_types.CompilerIrCallArgs.Two
          (operand-var 11)
          (operand-var 12))
        (ast.AstType.I64))]
    [(= index 40)
      (compiler_ir_types.ir-instr-call-cabi-store-result
        (operand-var 10)
        0
        (compiler_ir_types.CompilerIrCallArgs.Two
          (operand-var 11)
          (operand-var 12))
        (compiler-ir-smoke-operand-slots))]
    [(= index 41)
      (compiler_ir_types.ir-instr-call-indirect-cabi-store-result
        (operand-var 10)
        (operand-var 11)
        (compiler_ir_types.CompilerIrCallArgs.Two
          (operand-var 12)
          (operand-var 13))
        (compiler-ir-smoke-operand-slots))]
    [(= index 42)
      (compiler_ir_types.CompilerIrInstr.SpmdCall
        (box
          (compiler_ir_types.CompilerIrInstrSpmdCallPayload
            0
            (compiler_ir_types.CompilerIrSpmdBackend.Avx2)
            4
            (operand-var 10)
            (compiler_ir_types.compiler-ir-spmd-call-arg-seq2
              (compiler_ir_types.CompilerIrSpmdCallArg.Arg
                (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
                (operand-var 11)
                (ast.AstType.I64))
              (compiler_ir_types.CompilerIrSpmdCallArg.Arg
                (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
                (operand-var 12)
                (ast.AstType.I64)))
            (compiler_ir_types.CompilerIrSpmdCallResult.Value
              1
              (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
              (ast.AstType.I64))
            (compiler-ir-smoke-operand-origin))))]
    [(= index 43)
      (compiler_ir_types.CompilerIrInstr.TailCall
        0
        (compiler_ir_types.CompilerIrCallArgs.Two
          (operand-var 10)
          (operand-var 11))
        (ast.AstType.I64))]
    [(= index 44)
      (compiler_ir_types.CompilerIrInstr.Store
        0
        (operand-var 10)
        (ast.AstType.I64))]
    [(= index 45) (compiler_ir_types.CompilerIrInstr.Jump 70)]
    [(= index 46)
      (compiler_ir_types.CompilerIrInstr.Branch (operand-var 10) 70 71)]
    [(= index 47)
      (compiler_ir_types.CompilerIrInstr.TotalEnumBranch (operand-var 10) 70 71)]
    [(= index 48)
      (compiler_ir_types.CompilerIrInstr.Return
        (compiler_ir_types.CompilerIrMaybeValue.Some (operand-var 10)))]
    [(= index 49)
      (compiler_ir_types.CompilerIrInstr.Phi
        1
        (compiler_ir_types.compiler-ir-phi-input-seq-prepend
          (operand-var 10)
          70
          (compiler_ir_types.compiler-ir-phi-input-seq-prepend
            (operand-var 11)
            71
            (compiler_ir_types.compiler-ir-phi-input-seq-empty)))
        (ast.AstType.I64))]
    [(= index 50)
      (compiler_ir_types.CompilerIrInstr.Pack
        1
        (compiler_ir_types.compiler-ir-value-seq2
          (operand-var 10)
          (operand-var 11))
        (ast.AstType.I64))]
    [(= index 51)
      (compiler_ir_types.CompilerIrInstr.Word
        1
        (operand-var 10)
        4
        (ast.AstType.I64))]
    [(= index 52)
      (compiler_ir_types.CompilerIrInstr.TailCallIndirect
        (operand-var 10)
        (compiler_ir_types.CompilerIrCallArgs.Two
          (operand-var 11)
          (operand-var 12))
        (ast.AstType.I64))]
    [(= index 53)
      (compiler_ir_types.CompilerIrInstr.Switch
        (operand-var 10)
        4
        (compiler_ir_types.compiler-ir-switch-case-seq2
          (compiler_ir_types.CompilerIrSwitchCase.Case 0 70)
          (compiler_ir_types.CompilerIrSwitchCase.Case 1 71))
        72)]
    [(= index 54)
      (compiler_ir_types.CompilerIrInstr.TotalEnumSwitch
        (operand-var 10)
        4
        (compiler_ir_types.compiler-ir-switch-case-seq2
          (compiler_ir_types.CompilerIrSwitchCase.Case 0 70)
          (compiler_ir_types.CompilerIrSwitchCase.Case 1 71))
        72
        73)]
    [else (compiler_ir_types.CompilerIrInstr.Jump 0)]))

(define (compiler-ir-smoke-operand-expect [index : i64]) : String
  (cond
    [(= index 1) " S10 | dst 1 | succ | typed"]
    [(= index 2) " | dst 1 | succ"]
    [(= index 3) " | dst 1 | succ"]
    [(= index 4) " A10 S11 | dst 1 | succ"]
    [(= index 5) " A10 | dst 1 | succ | typed"]
    [(= index 6) " A10 S11 | dst -1 | succ"]
    [(= index 7) " A10 S11 | dst -1 | succ"]
    [(= index 8) " A10 A11 | dst -1 | succ"]
    [(= index 9) " S10 S11 | dst -1 | succ"]
    [(= index 10) " S10 | dst 1 | succ | typed"]
    [(= index 11) " S10 | dst 1 | succ | typed"]
    [(= index 12) " S10 S11 | dst 1 | succ | typed"]
    [(= index 13) " S10 | dst 1 | succ | typed"]
    [(= index 14) " | dst 1 | succ"]
    [(= index 15) " S10 | dst 1 | succ"]
    [(= index 16) " V10 V11 | dst 1 | succ"]
    [(= index 17) " V10 S11 | dst 1 | succ"]
    [(= index 18) " V10 | dst 1 | succ | typed"]
    [(= index 19) " V10 V11 | dst 1 | succ"]
    [(= index 20) " M10 M11 | dst 1 | succ"]
    [(= index 21) " M10 | dst 1 | succ"]
    [(= index 22) " M10 | dst 1 | succ | typed"]
    [(= index 23) " M10 V11 V12 | dst 1 | succ"]
    [(= index 24) " A10 S11 | dst 1 | succ"]
    [(= index 25) " A10 S11 V12 | dst -1 | succ"]
    [(= index 26) " A10 S11 V12 M13 | dst -1 | succ"]
    [(= index 27) " A10 S11 M12 | dst 1 | succ"]
    [(= index 28) " A10 A11 S12 | dst 1 | succ"]
    [(= index 29) " V10 V11 V12 S13 | dst 1 | succ"]
    [(= index 30) " S10 S11 | dst 1 | succ"]
    [(= index 31) " | dst 1 | succ"]
    [(= index 32) " | dst 1 | succ"]
    [(= index 33) " | dst 1 | succ"]
    [(= index 34) " S10 S11 | dst 1 | succ"]
    [(= index 35) " S10 | dst 1 | succ"]
    [(= index 36) " C10 C11 | dst 1 | succ"]
    [(= index 37) " C10 C11 | dst 1 | succ | typed"]
    [(= index 38) " A10 C11 C12 | dst 1 | succ | typed"]
    [(= index 39) " A10 C11 C12 | dst 1 | succ | typed"]
    [(= index 40) " A10 C11 C12 | dst -1 | succ"]
    [(= index 41) " A10 A11 C12 C13 | dst -1 | succ"]
    [(= index 42) " M10 C11 V12 | dst 1 | succ | typed"]
    [(= index 43) " C10 C11 | dst -1 | succ"]
    [(= index 44) " S10 | dst -1 | succ"]
    [(= index 45) " | dst -1 | succ 70"]
    [(= index 46) " D10 | dst -1 | succ 70 71"]
    [(= index 47) " D10 | dst -1 | succ 70 71"]
    [(= index 48) " S10 | dst -1 | succ"]
    [(= index 49) " P10 P11 | dst 1 | succ | typed"]
    [(= index 50) " S10 S11 | dst 1 | succ | typed"]
    [(= index 51) " S10 | dst 1 | succ | typed"]
    [(= index 52) " A10 C11 C12 | dst -1 | succ"]
    [(= index 53) " D10 | dst -1 | succ 72 70 71"]
    [(= index 54) " D10 | dst -1 | succ 72 73 70 71"]
    [else ""]))

(defenum CompilerIrMaybeDescriptorPairKind
  (No)
  (Some compiler_ir_types.CompilerIrDescriptorPairKind))

(define (compiler-ir-descriptor-pair-kind-for-handle-type [ty : ast.AstType]) : CompilerIrMaybeDescriptorPairKind
  (match ty
    [(ast.AstType.String)
      (CompilerIrMaybeDescriptorPairKind.Some
        (compiler_ir_types.CompilerIrDescriptorPairKind.OwnedString))]
    [(ast.AstType.DynArray elem)
      (CompilerIrMaybeDescriptorPairKind.Some
        (compiler_ir_types.CompilerIrDescriptorPairKind.DynamicArray elem))]
    [_ (CompilerIrMaybeDescriptorPairKind.No)]))

(define (compiler-ir-switch-case-seq-empty) : compiler_ir_types.CompilerIrSwitchCaseSeq
  (compiler_ir_types.CompilerIrSwitchCaseSeq
    (__tl_make-array compiler_ir_types.CompilerIrSwitchCase 0)
    0))

(define (compiler-ir-instr-seq-rewrite!
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [rewrite
    : (-> compiler_ir_types.CompilerIrInstr compiler_ir_types.CompilerIrInstr)]) : unit
  (let
    [index : i64 0]
    [count : i64 instrs.len]
    (while (< index count)
      (begin
        (compiler_ir_types.compiler-ir-instr-seq-set!
          (compiler_ir_types.compiler-ir-global-shared-view instrs)
          index
          (rewrite (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)))
        (set! index (+ index 1))))))

(define (compiler-ir-instr-seq-compact!
  [instrs : (&mut instrs compiler_ir_types.CompilerIrInstrSeq)]
  [keep? : (-> compiler_ir_types.CompilerIrInstr bool)]) : unit
  (let
    [read : i64 0]
    [write : i64 0]
    [count : i64 instrs.len]
    (begin
      (while (< read count)
        (begin
          (if (keep? (clone (array-ref instrs.slots read)))
            (begin
              (if (not (= write read))
                (set!
                  (array-ref instrs.slots write)
                  (clone (array-ref instrs.slots read)))
                unit)
              (set! write (+ write 1)))
            unit)
          (set! read (+ read 1))))
      (set! instrs.len write))))

(define (compiler-ir-value-var-eq?
  [value : compiler_ir_types.CompilerIrValue]
  [want : i64]) : bool
  (match value
    [(compiler_ir_types.CompilerIrValue.Var id) (= id want)]
    [_ false]))

(define (compiler-ir-effect-is?
  [instr : compiler_ir_types.CompilerIrInstr]
  [effect : compiler_ir_types.CompilerIrEffect]) : bool
  (compiler_ir_types.compiler-ir-effect-eq?
    (compiler_ir_types.compiler-ir-instr-effect instr)
    effect))

(define (compiler-ir-instruction-effects-ok?) : bool
  (and
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Mov
        0
        (compiler_ir_types.CompilerIrValue.I64 1)
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.AddrOf 1 0)
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Gep
        2
        (compiler_ir_types.CompilerIrValue.Var 1)
        (compiler_ir_types.CompilerIrValue.I64 0)
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Cast
        3
        (compiler_ir_types.CompilerIrValue.Var 2)
        (ast.AstType.I64)
        (ast.AstType.I32))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.BinOp
        4
        (compiler_ir_types.CompilerIrBinOp.Add)
        (compiler_ir_types.CompilerIrValue.Var 2)
        (compiler_ir_types.CompilerIrValue.I64 1)
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.UnOp
        5
        (compiler_ir_types.CompilerIrUnOp.Neg)
        (compiler_ir_types.CompilerIrValue.Var 4)
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Phi
        6
        (compiler_ir_types.compiler-ir-phi-input-seq-prepend
          (compiler_ir_types.CompilerIrValue.I64 1)
          (compiler_ir_types.compiler-ir-label "entry")
          (compiler_ir_types.compiler-ir-phi-input-seq-empty))
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Load
        7
        (compiler_ir_types.CompilerIrValue.Var 1)
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Alloc 8 (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.StorePtr
        (compiler_ir_types.CompilerIrValue.Var 1)
        (compiler_ir_types.CompilerIrValue.I64 2)
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.CopyBytes
        (compiler_ir_types.CompilerIrValue.Var 1)
        (compiler_ir_types.CompilerIrValue.Var 2)
        16)
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Store
        (compiler_ir_types.compiler-ir-test-symbol "global")
        (compiler_ir_types.CompilerIrValue.I64 3)
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Call
        9
        cbi.compiler-builtin-id-tl-region-mark
        (compiler_ir_types.CompilerIrCallArgs.Nil)
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.CpuId
        10
        (compiler_ir_types.CompilerIrValue.I64 1)
        (compiler_ir_types.CompilerIrValue.I64 0)
        0)
      compiler_ir_types.CompilerIrEffect.CpuProbe)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Xgetbv
        11
        (compiler_ir_types.CompilerIrValue.I64 0))
      compiler_ir_types.CompilerIrEffect.CpuProbe)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.BoundsCheck
        (compiler_ir_types.CompilerIrValue.Var 0)
        (compiler_ir_types.CompilerIrValue.Var 1)
        (compiler_ir_types.compiler-ir-label "bounds_ok"))
      compiler_ir_types.CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.TailCall
        (compiler_ir_types.compiler-ir-test-symbol "fact_loop")
        (compiler_ir_types.CompilerIrCallArgs.Two
          (compiler_ir_types.CompilerIrValue.Var 3)
          (compiler_ir_types.CompilerIrValue.I64 1))
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Jump
        (compiler_ir_types.compiler-ir-label "done"))
      compiler_ir_types.CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Branch
        (compiler_ir_types.CompilerIrValue.Bool true)
        (compiler_ir_types.compiler-ir-label "then")
        (compiler_ir_types.compiler-ir-label "else"))
      compiler_ir_types.CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Switch
        (compiler_ir_types.CompilerIrValue.Var 0)
        1
        (compiler_ir_types.compiler-ir-switch-case-seq2
          (compiler_ir_types.CompilerIrSwitchCase.Case
            1
            (compiler_ir_types.compiler-ir-label "one"))
          (compiler_ir_types.CompilerIrSwitchCase.Case
            2
            (compiler_ir_types.compiler-ir-label "two")))
        (compiler_ir_types.compiler-ir-label "default"))
      compiler_ir_types.CompilerIrEffect.ControlFlow)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Return
        (compiler_ir_types.CompilerIrMaybeValue.Some
          (compiler_ir_types.CompilerIrValue.I64 0)))
      compiler_ir_types.CompilerIrEffect.ControlFlow)))

(define (compiler-ir-vector-mask-effects-ok?) : bool
  (and
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.LaneId 20 4 (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.Splat
        21
        (compiler_ir_types.CompilerIrValue.Var 0)
        4
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-vector-bin-op
        22
        (compiler_ir_types.CompilerIrBinOp.Add)
        (compiler_ir_types.CompilerIrValue.Var 20)
        (compiler_ir_types.CompilerIrValue.Var 21)
        4
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-vector-prefix
        32
        (compiler_ir_types.CompilerIrVectorPrefixOp.Sum)
        (compiler_ir_types.CompilerIrValue.Var 22)
        (compiler_ir_types.CompilerIrValue.I64 0)
        4
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.VectorReduce
        23
        (compiler_ir_types.CompilerIrVectorReduceOp.Sum)
        (compiler_ir_types.CompilerIrValue.Var 22)
        4
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-vector-compare
        24
        (compiler_ir_types.CompilerIrBinOp.Lt)
        (compiler_ir_types.CompilerIrValue.Var 20)
        (compiler_ir_types.CompilerIrValue.Var 21)
        4
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.MaskBinOp
        25
        (compiler_ir_types.CompilerIrMaskBinOp.And)
        (compiler_ir_types.CompilerIrValue.Var 24)
        (compiler_ir_types.CompilerIrValue.Var 24)
        4)
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.MaskNot
        26
        (compiler_ir_types.CompilerIrValue.Var 25)
        4)
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.MaskReduce
        27
        (compiler_ir_types.CompilerIrMaskReduceOp.Any)
        (compiler_ir_types.CompilerIrValue.Var 26)
        4)
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-select
        28
        (compiler_ir_types.CompilerIrValue.Var 24)
        (compiler_ir_types.CompilerIrValue.Var 20)
        (compiler_ir_types.CompilerIrValue.Var 21)
        4
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.TailMask
        29
        (compiler_ir_types.CompilerIrValue.Var 0)
        (compiler_ir_types.CompilerIrValue.Var 1)
        4)
      compiler_ir_types.CompilerIrEffect.Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.CompilerIrInstr.VectorLoad
        30
        (compiler_ir_types.CompilerIrValue.Var 2)
        (compiler_ir_types.CompilerIrValue.Var 0)
        4
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-predicated-load
        31
        (compiler_ir_types.CompilerIrValue.Var 2)
        (compiler_ir_types.CompilerIrValue.Var 0)
        (compiler_ir_types.CompilerIrValue.Var 29)
        4
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.MemoryRead)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-vector-store
        (compiler_ir_types.CompilerIrValue.Var 2)
        (compiler_ir_types.CompilerIrValue.Var 0)
        (compiler_ir_types.CompilerIrValue.Var 22)
        4
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-predicated-store
        (compiler_ir_types.CompilerIrValue.Var 2)
        (compiler_ir_types.CompilerIrValue.Var 0)
        (compiler_ir_types.CompilerIrValue.Var 22)
        (compiler_ir_types.CompilerIrValue.Var 29)
        4
        (ast.AstType.I64))
      compiler_ir_types.CompilerIrEffect.MemoryWrite)))

(define (compiler-ir-effect-predicates-ok?) : bool
  (and
    (not
      (compiler_ir_types.compiler-ir-effect-has-side-effect?
        compiler_ir_types.CompilerIrEffect.Pure))
    (not
      (compiler_ir_types.compiler-ir-effect-has-side-effect?
        compiler_ir_types.CompilerIrEffect.MemoryRead))
    (compiler_ir_types.compiler-ir-effect-has-side-effect?
      compiler_ir_types.CompilerIrEffect.CpuProbe)
    (compiler_ir_types.compiler-ir-effect-has-side-effect?
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler_ir_types.compiler-ir-effect-has-side-effect?
      compiler_ir_types.CompilerIrEffect.ControlFlow)
    (compiler_ir_types.compiler-ir-effect-has-side-effect?
      compiler_ir_types.CompilerIrEffect.Unknown)
    (not
      (compiler_ir_types.compiler-ir-effect-invalidates-cse?
        compiler_ir_types.CompilerIrEffect.Pure))
    (compiler_ir_types.compiler-ir-effect-invalidates-cse?
      compiler_ir_types.CompilerIrEffect.MemoryRead)
    (compiler_ir_types.compiler-ir-effect-invalidates-cse?
      compiler_ir_types.CompilerIrEffect.CpuProbe)
    (compiler_ir_types.compiler-ir-effect-invalidates-cse?
      compiler_ir_types.CompilerIrEffect.MemoryWrite)
    (compiler_ir_types.compiler-ir-effect-invalidates-cse?
      compiler_ir_types.CompilerIrEffect.ControlFlow)
    (compiler_ir_types.compiler-ir-effect-invalidates-cse?
      compiler_ir_types.CompilerIrEffect.Unknown)))

(define (compiler-ir-renders-as?
  [instr : compiler_ir_types.CompilerIrInstr]
  [want : String]) : bool
  (string.eq
    (compiler_ir_types.compiler-ir-instr-render
      (cis.InternStructuralSessionHandle 0)
      (ast.ast-node-pool-reader-type-segment-bases)
      instr)
    want))

(define (compiler-ir-display-op-names-ok?) : bool
  (and
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.VectorReduce
        8
        compiler_ir_types.CompilerIrVectorReduceOp.Sum
        (compiler_ir_types.CompilerIrValue.Var 2)
        4
        (ast.AstType.I64))
      "  %8 = vector_reduce_sum %2 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.VectorReduce
        8
        compiler_ir_types.CompilerIrVectorReduceOp.Min
        (compiler_ir_types.CompilerIrValue.Var 2)
        4
        (ast.AstType.I64))
      "  %8 = vector_reduce_min %2 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.VectorReduce
        8
        compiler_ir_types.CompilerIrVectorReduceOp.Max
        (compiler_ir_types.CompilerIrValue.Var 2)
        4
        (ast.AstType.I64))
      "  %8 = vector_reduce_max %2 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-prefix
        42
        compiler_ir_types.CompilerIrVectorPrefixOp.Sum
        (compiler_ir_types.CompilerIrValue.Var 7)
        (compiler_ir_types.CompilerIrValue.I64 -3)
        4
        (ast.AstType.I64))
      "  %42 = vector_prefix_sum %7, carry -3 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-prefix
        42
        compiler_ir_types.CompilerIrVectorPrefixOp.Max
        (compiler_ir_types.CompilerIrValue.Var 7)
        (compiler_ir_types.CompilerIrValue.I64 -3)
        4
        (ast.AstType.I64))
      "  %42 = vector_prefix_max %7, carry -3 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-prefix
        42
        compiler_ir_types.CompilerIrVectorPrefixOp.All
        (compiler_ir_types.CompilerIrValue.Var 7)
        (compiler_ir_types.CompilerIrValue.I64 -3)
        4
        (ast.AstType.I64))
      "  %42 = vector_prefix_all %7, carry -3 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-prefix
        42
        compiler_ir_types.CompilerIrVectorPrefixOp.Any
        (compiler_ir_types.CompilerIrValue.Var 7)
        (compiler_ir_types.CompilerIrValue.I64 -3)
        4
        (ast.AstType.I64))
      "  %42 = vector_prefix_any %7, carry -3 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.MaskReduce
        9
        compiler_ir_types.CompilerIrMaskReduceOp.All
        (compiler_ir_types.CompilerIrValue.Var 5)
        4)
      "  %9 = mask_reduce_all %5 lanes 4")
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.MaskBinOp
        4
        compiler_ir_types.CompilerIrMaskBinOp.And
        (compiler_ir_types.CompilerIrValue.Var 3)
        (compiler_ir_types.CompilerIrValue.Var 3)
        4)
      "  %4 = mask_and %3, %3 lanes 4")))

(define (compiler-ir-display-instrs-ok?) : bool
  (and
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.LaneId 0 4 (ast.AstType.I64))
      "  %0 = lane_id 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.Splat
        1
        (compiler_ir_types.CompilerIrValue.I64 7)
        4
        (ast.AstType.I64))
      "  %1 = splat 7 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-bin-op
        2
        (compiler_ir_types.CompilerIrBinOp.Add)
        (compiler_ir_types.CompilerIrValue.Var 0)
        (compiler_ir_types.CompilerIrValue.Var 1)
        4
        (ast.AstType.I64))
      "  %2 = vector_add %0, %1 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.VectorReduce
        8
        (compiler_ir_types.CompilerIrVectorReduceOp.Sum)
        (compiler_ir_types.CompilerIrValue.Var 2)
        4
        (ast.AstType.I64))
      "  %8 = vector_reduce_sum %2 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-compare
        3
        (compiler_ir_types.CompilerIrBinOp.Lt)
        (compiler_ir_types.CompilerIrValue.Var 0)
        (compiler_ir_types.CompilerIrValue.Var 1)
        4
        (ast.AstType.I64))
      "  %3 = vector_compare_lt %0, %1 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.MaskBinOp
        4
        (compiler_ir_types.CompilerIrMaskBinOp.Or)
        (compiler_ir_types.CompilerIrValue.Var 3)
        (compiler_ir_types.CompilerIrValue.Var 3)
        4)
      "  %4 = mask_or %3, %3 lanes 4")
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.MaskNot
        5
        (compiler_ir_types.CompilerIrValue.Var 4)
        4)
      "  %5 = mask_not %4 lanes 4")
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.MaskReduce
        9
        (compiler_ir_types.CompilerIrMaskReduceOp.Any)
        (compiler_ir_types.CompilerIrValue.Var 5)
        4)
      "  %9 = mask_reduce_any %5 lanes 4")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-select
        6
        (compiler_ir_types.CompilerIrValue.Var 5)
        (compiler_ir_types.CompilerIrValue.Var 2)
        (compiler_ir_types.CompilerIrValue.Var 1)
        4
        (ast.AstType.I64))
      "  %6 = select %5, %2, %1 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.CompilerIrInstr.VectorLoad
        7
        (compiler_ir_types.CompilerIrValue.Var 10)
        (compiler_ir_types.CompilerIrValue.Var 11)
        4
        (ast.AstType.I64))
      "  %7 = vector_load %10, %11 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-store
        (compiler_ir_types.CompilerIrValue.Var 12)
        (compiler_ir_types.CompilerIrValue.Var 11)
        (compiler_ir_types.CompilerIrValue.Var 6)
        4
        (ast.AstType.I64))
      "  vector_store %12, %11, %6 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-predicated-store
        (compiler_ir_types.CompilerIrValue.Var 12)
        (compiler_ir_types.CompilerIrValue.Var 11)
        (compiler_ir_types.CompilerIrValue.Var 6)
        (compiler_ir_types.CompilerIrValue.Var 5)
        4
        (ast.AstType.I64))
      "  predicated_store %12, %11, %6 mask %5 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-predicated-load
        10
        (compiler_ir_types.CompilerIrValue.Var 12)
        (compiler_ir_types.CompilerIrValue.Var 11)
        (compiler_ir_types.CompilerIrValue.Var 5)
        4
        (ast.AstType.I64))
      "  %10 = predicated_load %12, %11 mask %5 lanes 4 : i64")))

(define (compiler-ir-vector-prefix-display-clone-ok?) : bool
  (let
    [instr : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.ir-instr-vector-prefix
        42
        (compiler_ir_types.CompilerIrVectorPrefixOp.Min)
        (compiler_ir_types.CompilerIrValue.Var 7)
        (compiler_ir_types.CompilerIrValue.I64 -3)
        4
        (ast.AstType.I64))]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-reader-context-current)]
    [cloned : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.compiler-ir-clone-instr
        pools
        (compiler_ir_types.compiler-ir-global-shared-view instr))]
    (and
      (string.eq
        (compiler_ir_types.compiler-ir-instr-render
          (cis.InternStructuralSessionHandle 0)
          (ast.ast-node-pool-reader-type-segment-bases)
          (compiler_ir_types.compiler-ir-global-shared-view instr))
        "  %42 = vector_prefix_min %7, carry -3 lanes 4 : i64")
      (compiler-ir-effect-is? instr compiler_ir_types.CompilerIrEffect.Pure)
      (match cloned
        [(compiler_ir_types.CompilerIrInstr.VectorPrefix payload-box)
          (let
            [dst
              (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                dst)]
            [op
              (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                op)]
            [src
              (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                src)]
            [carry
              (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                carry)]
            [lanes
              (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                lanes)]
            [ty
              (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                ty)]
            (and
              (= dst 42)
              (match op
                [(compiler_ir_types.CompilerIrVectorPrefixOp.Min) true]
                [_ false])
              (compiler-ir-value-var-eq? src 7)
              (match carry
                [(compiler_ir_types.CompilerIrValue.I64 value) (= value -3)]
                [_ false])
              (= lanes 4)
              (match ty
                [(ast.AstType.I64) true]
                [_ false])))]
        [_ false]))))

(define (compiler-ir-display-tail-mask-ok?) : bool
  (let
    [instr : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.CompilerIrInstr.TailMask
        9
        (compiler_ir_types.CompilerIrValue.Var 1)
        (compiler_ir_types.CompilerIrValue.Var 2)
        8)]
    (and
      (compiler-ir-renders-as?
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        "  %9 = tail_mask %1, %2 lanes 8")
      (compiler-ir-effect-is?
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        compiler_ir_types.CompilerIrEffect.Pure)
      (match instr
        [(compiler_ir_types.CompilerIrInstr.TailMask dst index len lanes)
          (and
            (= dst 9)
            (compiler-ir-value-var-eq? index 1)
            (compiler-ir-value-var-eq? len 2)
            (= lanes 8))]
        [_ false]))))

(define (compiler-ir-display-self-test-ok?) : bool
  (and
    (compiler-ir-display-op-names-ok?)
    (compiler-ir-display-instrs-ok?)
    (compiler-ir-vector-prefix-display-clone-ok?)
    (compiler-ir-display-tail-mask-ok?)))

(define (compiler-ir-tail-call-render-ok?) : bool
  (string.eq
    (compiler_ir_types.compiler-ir-instr-render
      (cis.InternStructuralSessionHandle 0)
      (ast.ast-node-pool-reader-type-segment-bases)
      (compiler_ir_types.CompilerIrInstr.TailCall
        (compiler_ir_types.compiler-ir-test-symbol "fact_loop")
        (compiler_ir_types.CompilerIrCallArgs.Two
          (compiler_ir_types.CompilerIrValue.Var 3)
          (compiler_ir_types.CompilerIrValue.I64 1))
        (ast.AstType.I64)))
    "  tailcall fact_loop(%3, 1) : i64"))

(define (compiler-ir-switch-render-ok?) : bool
  (let
    [cases : compiler_ir_types.CompilerIrSwitchCaseSeq
      (compiler_ir_types.compiler-ir-switch-case-seq2
        (compiler_ir_types.CompilerIrSwitchCase.Case
          4
          (compiler_ir_types.compiler-ir-label "four"))
        (compiler_ir_types.CompilerIrSwitchCase.Case
          5
          (compiler_ir_types.compiler-ir-label "five")))]
    [instr : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.CompilerIrInstr.Switch
        (compiler_ir_types.CompilerIrValue.Var 9)
        4
        cases
        (compiler_ir_types.compiler-ir-label "other"))]
    (compiler-ir-renders-as?
      instr
      "  switch %9 base 4 [4:four, 5:five] default other")))

(define (compiler-ir-source-spans-entry-list-ok?) : bool
  (let
    [span1 : ast.AstSourceSpan (ast.ast-source-span 1 2 1 3)]
    [span2 : ast.AstSourceSpan (ast.ast-source-span 4 5 4 8)]
    [span3 : ast.AstSourceSpan (ast.ast-source-span 7 8 7 12)]
    [first : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id
        (ci.intern-generated-canonical-name "first"))]
    [second : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id
        (ci.intern-generated-canonical-name "second"))]
    [one : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id
        (ci.intern-generated-canonical-name "one"))]
    [two : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id
        (ci.intern-generated-canonical-name "two"))]
    [same : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id
        (ci.intern-generated-canonical-name "same"))]
    [source-provenance : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id
        (ci.intern-source-slice "span-same-provenance" 0 20))]
    [generated-provenance : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id
        (ci.intern-generated-name "span-same-provenance"))]
    [grow : compiler_ir_types.CompilerIrSymbolId
      (compiler_ir_types.compiler-ir-symbol-typed-id
        (ci.intern-generated-canonical-name "grow"))]
    [entries : compiler_ir_types.CompilerSourceSpansEntryList
      (compiler_ir_types.compiler-source-spans-entry-list-append
        (compiler_ir_types.compiler-source-spans-entry-list-append
          (compiler_ir_types.compiler-source-spans-entry-list-empty)
          (compiler_ir_types.CompilerSourceSpansEntry.Entry first 0 span1))
        (compiler_ir_types.CompilerSourceSpansEntry.Entry second 0 span2))]
    [spans : compiler_ir_types.CompilerSourceSpans
      (compiler_ir_types.compiler-source-spans-insert
        (compiler_ir_types.compiler-source-spans-insert
          (compiler_ir_types.compiler-source-spans-empty)
          one
          span1)
        two
        span2)]
    [shadowed : compiler_ir_types.CompilerSourceSpans
      (compiler_ir_types.compiler-source-spans-insert
        (compiler_ir_types.compiler-source-spans-insert
          (compiler_ir_types.compiler-source-spans-empty)
          same
          span1)
        same
        span3)]
    [same-spelling : compiler_ir_types.CompilerSourceSpans
      (compiler_ir_types.compiler-source-spans-insert
        (compiler_ir_types.compiler-source-spans-insert
          (compiler_ir_types.compiler-source-spans-empty)
          source-provenance
          span1)
        generated-provenance
        span2)]
    [instr : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.CompilerIrInstr.Mov
        9
        (compiler_ir_types.CompilerIrValue.I64 1)
        (ast.AstType.I64))]
    [instr-function : compiler_ir_types.CompilerIrSymbolId one]
    [instr-spans : compiler_ir_types.CompilerSourceSpans
      (compiler_ir_types.compiler-source-spans-insert-instr
        (compiler_ir_types.compiler-source-spans-insert-instr
          (compiler_ir_types.compiler-source-spans-empty)
          instr-function
          (compiler_ir_types.compiler-ir-global-shared-view instr)
          span1)
        instr-function
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        span3)]
    [provenance-instr-spans : compiler_ir_types.CompilerSourceSpans
      (compiler_ir_types.compiler-source-spans-insert-instr
        (compiler_ir_types.compiler-source-spans-insert-instr
          (compiler_ir_types.compiler-source-spans-empty)
          source-provenance
          (compiler_ir_types.compiler-ir-global-shared-view instr)
          span1)
        generated-provenance
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        span2)]
    [grown-entries : compiler_ir_types.CompilerSourceSpansEntryList
      (compiler_ir_types.compiler-source-spans-entry-list-empty)]
    [grown-instr-spans : compiler_ir_types.CompilerSourceSpans
      (compiler_ir_types.compiler-source-spans-empty)]
    [i : i64 0]
    (begin
      (while (< i 6)
        (begin
          (set!
            grown-entries
            (compiler_ir_types.compiler-source-spans-entry-list-append
              grown-entries
              (compiler_ir_types.CompilerSourceSpansEntry.Entry
                grow
                0
                (if (= i 5)
                  span3
                  span1))))
          (set!
            grown-instr-spans
            (compiler_ir_types.compiler-source-spans-insert-instr
              grown-instr-spans
              instr-function
              (compiler_ir_types.compiler-ir-global-shared-view instr)
              (if (= i 5)
                span3
                span1)))
          (set! i (+ i 1))))
      (and
        (= (compiler_ir_types.compiler-source-spans-entry-list-count entries) 2)
        (= (compiler_ir_types.compiler-source-spans-count spans) 2)
        (=
          (compiler_ir_types.compiler-source-spans-entry-list-count
            grown-entries)
          6)
        (= (array-length grown-entries.slots) 8)
        (match (compiler_ir_types.compiler-ir-global-shared-view
          grown-instr-spans)
          [(compiler_ir_types.CompilerSourceSpans.Spans
              _
              grown-instr-entries
              grown-instr-count)
            (and
              (= grown-instr-count 6)
              (= grown-instr-entries.len 6)
              (= (array-length grown-instr-entries.slots) 8))])
        (match (compiler_ir_types.compiler-source-spans-entry-list-lookup
          entries
          second)
          [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
            (and
              (= (ast.ast-source-span-start-line found) 4)
              (= (ast.ast-source-span-end-col found) 8))]
          [(compiler_ir_types.CompilerMaybeSourceSpan.No) false])
        (match (compiler_ir_types.compiler-source-spans-entry-list-lookup
          grown-entries
          grow)
          [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
            (and
              (= (ast.ast-source-span-start-line found) 7)
              (= (ast.ast-source-span-end-col found) 12))]
          [(compiler_ir_types.CompilerMaybeSourceSpan.No) false])
        (match (compiler_ir_types.compiler-source-spans-lookup shadowed same)
          [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
            (and
              (= (ast.ast-source-span-start-line found) 7)
              (= (ast.ast-source-span-end-col found) 12))]
          [(compiler_ir_types.CompilerMaybeSourceSpan.No) false])
        (not
          (compiler_ir_types.compiler-ir-symbol-id-eq?
            source-provenance
            generated-provenance))
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-id-text source-provenance)
          (compiler_ir_types.compiler-ir-symbol-id-text generated-provenance))
        (match (compiler_ir_types.compiler-source-spans-lookup
          (compiler_ir_types.compiler-ir-global-shared-view same-spelling)
          source-provenance)
          [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
            (= (ast.ast-source-span-start-line found) 1)]
          [(compiler_ir_types.CompilerMaybeSourceSpan.No) false])
        (match (compiler_ir_types.compiler-source-spans-lookup
          same-spelling
          generated-provenance)
          [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
            (= (ast.ast-source-span-start-line found) 4)]
          [(compiler_ir_types.CompilerMaybeSourceSpan.No) false])
        (match (compiler_ir_types.compiler-source-spans-lookup-instr
          instr-spans
          instr-function
          (compiler_ir_types.compiler-ir-global-shared-view instr))
          [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
            (and
              (= (ast.ast-source-span-start-line found) 7)
              (= (ast.ast-source-span-end-col found) 12))]
          [(compiler_ir_types.CompilerMaybeSourceSpan.No) false])
        (match (compiler_ir_types.compiler-source-spans-lookup-instr
          grown-instr-spans
          instr-function
          (compiler_ir_types.compiler-ir-global-shared-view instr))
          [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
            (and
              (= (ast.ast-source-span-start-line found) 7)
              (= (ast.ast-source-span-end-col found) 12))]
          [(compiler_ir_types.CompilerMaybeSourceSpan.No) false])
        (match (compiler_ir_types.compiler-source-spans-lookup-instr
          (compiler_ir_types.compiler-ir-global-shared-view
            provenance-instr-spans)
          source-provenance
          (compiler_ir_types.compiler-ir-global-shared-view instr))
          [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
            (= (ast.ast-source-span-start-line found) 1)]
          [(compiler_ir_types.CompilerMaybeSourceSpan.No) false])
        (match (compiler_ir_types.compiler-source-spans-lookup-instr
          provenance-instr-spans
          generated-provenance
          instr)
          [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
            (= (ast.ast-source-span-start-line found) 4)]
          [(compiler_ir_types.CompilerMaybeSourceSpan.No) false])))))

(define (compiler-ir-instr-seq-mov-dst?
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [index : i64]
  [want : i64]) : bool
  (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
    [(compiler_ir_types.CompilerIrInstr.Mov dst _ _) (= dst want)]
    [_ false]))

(define (compiler-ir-instr-seq-return-var?
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [index : i64]
  [want : i64]) : bool
  (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
    [(compiler_ir_types.CompilerIrInstr.Return
        (compiler_ir_types.CompilerIrMaybeValue.Some
          (compiler_ir_types.CompilerIrValue.Var var)))
      (= var want)]
    [_ false]))

(define (compiler-ir-instr-seq-test-rewrite
  [instr : compiler_ir_types.CompilerIrInstr]) : compiler_ir_types.CompilerIrInstr
  (match (compiler_ir_types.compiler-ir-global-shared-view instr)
    [(compiler_ir_types.CompilerIrInstr.Mov dst value ty)
      (compiler_ir_types.CompilerIrInstr.Mov (+ dst 10) value ty)]
    [(compiler_ir_types.CompilerIrInstr.Alloc dst ty)
      (compiler_ir_types.CompilerIrInstr.Alloc dst ty)]
    [(compiler_ir_types.CompilerIrInstr.Return value)
      (compiler_ir_types.CompilerIrInstr.Return value)]
    [_ instr]))

(define (compiler-ir-instr-seq-test-keep-non-alloc?
  [instr : compiler_ir_types.CompilerIrInstr]) : bool
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Alloc _ _) false]
    [_ true]))

(define (compiler-ir-instr-seq-mutable-rewrite-ok?) : bool
  (let
    [seq : compiler_ir_types.CompilerIrInstrSeq
      (compiler_ir_types.compiler-ir-instr-seq3
        (compiler_ir_types.CompilerIrInstr.Mov
          1
          (compiler_ir_types.CompilerIrValue.I64 10)
          (ast.AstType.I64))
        (compiler_ir_types.CompilerIrInstr.Mov
          2
          (compiler_ir_types.CompilerIrValue.I64 20)
          (ast.AstType.I64))
        (compiler_ir_types.CompilerIrInstr.Return
          (compiler_ir_types.CompilerIrMaybeValue.Some
            (compiler_ir_types.CompilerIrValue.Var 2))))]
    (begin
      (compiler-ir-instr-seq-rewrite!
        (compiler_ir_types.compiler-ir-global-shared-view seq)
        compiler-ir-instr-seq-test-rewrite)
      (and
        (= (compiler_ir_types.compiler-ir-instr-seq-count seq) 3)
        (compiler-ir-instr-seq-mov-dst?
          (compiler_ir_types.compiler-ir-global-shared-view seq)
          0
          11)
        (compiler-ir-instr-seq-mov-dst?
          (compiler_ir_types.compiler-ir-global-shared-view seq)
          1
          12)
        (compiler-ir-instr-seq-return-var? seq 2 2)))))

(define (compiler-ir-instr-seq-mutable-compact-ok?) : bool
  (let
    [seq : compiler_ir_types.CompilerIrInstrSeq
      (compiler_ir_types.compiler-ir-instr-seq4
        (compiler_ir_types.CompilerIrInstr.Mov
          1
          (compiler_ir_types.CompilerIrValue.I64 10)
          (ast.AstType.I64))
        (compiler_ir_types.CompilerIrInstr.Alloc 9 (ast.AstType.I64))
        (compiler_ir_types.CompilerIrInstr.Mov
          2
          (compiler_ir_types.CompilerIrValue.I64 20)
          (ast.AstType.I64))
        (compiler_ir_types.CompilerIrInstr.Return
          (compiler_ir_types.CompilerIrMaybeValue.Some
            (compiler_ir_types.CompilerIrValue.Var 2))))]
    (begin
      (compiler-ir-instr-seq-compact!
        (&mut seq)
        compiler-ir-instr-seq-test-keep-non-alloc?)
      (and
        (= (compiler_ir_types.compiler-ir-instr-seq-count seq) 3)
        (compiler-ir-instr-seq-mov-dst?
          (compiler_ir_types.compiler-ir-global-shared-view seq)
          0
          1)
        (compiler-ir-instr-seq-mov-dst?
          (compiler_ir_types.compiler-ir-global-shared-view seq)
          1
          2)
        (compiler-ir-instr-seq-return-var? seq 2 2)))))

(define (compiler-ir-block-list-first-label?
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [want : String]) : bool
  (match (compiler_ir_types.compiler-ir-block-list-force-cons blocks)
    [(compiler_ir_types.CompilerIrBlockList.Cons block _)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block label _)
          (string.eq (compiler_ir_types.compiler-ir-label-text label) want)])]
    [(compiler_ir_types.CompilerIrBlockList.Nil) false]
    [(compiler_ir_types.CompilerIrBlockList.Array _) false]))

(define (compiler-ir-block-list-label-at-cons?
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [index : i64]
  [want : String]) : bool
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) false]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (if (= index 0)
        (match block
          [(compiler_ir_types.CompilerIrBlock.Block label _)
            (string.eq (compiler_ir_types.compiler-ir-label-text label) want)])
        (compiler-ir-block-list-label-at-cons? (deref rest) (- index 1) want))]
    [(compiler_ir_types.CompilerIrBlockList.Array _) false]))

(define (compiler-ir-block-list-label-at?
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [index : i64]
  [want : String]) : bool
  (compiler-ir-block-list-label-at-cons?
    (compiler_ir_types.compiler-ir-block-list-force-cons blocks)
    index
    want))

(define (compiler-ir-function-seq-name-at?
  [functions : (& functions compiler_ir_types.CompilerIrFunctionSeq)]
  [index : i64]
  [want : String]) : bool
  (if (or (< index 0) (>= index functions.len))
    false
    (match (array-ref functions.slots index)
      [(compiler_ir_types.CompilerIrFunction.Function name _ _ _ _ _)
        (string.eq (compiler_ir_types.compiler-ir-symbol-text name) want)])))

(define (compiler-ir-test-function [name : String]) : compiler_ir_types.CompilerIrFunction
  (compiler_ir_types.CompilerIrFunction.Function
    (compiler_ir_types.compiler-ir-test-symbol name)
    (compiler_ir_types.compiler-ir-param-seq-empty)
    (ast.AstType.I64)
    1
    compiler_ir_types.CompilerIrBlockList.Nil
    compiler_ir_types.CompilerIrFunctionAbi.Ordinary))

(define (compiler-ir-dense-builders-order-ok?) : bool
  (let
    [instr-builder : compiler_ir_types.CompilerIrInstrBuilder
      (compiler_ir_types.compiler-ir-instr-builder-with-capacity 1)]
    [block-builder : compiler_ir_types.CompilerIrBlockBuilder
      (compiler_ir_types.compiler-ir-block-builder-with-capacity 1)]
    [function-builder : compiler_ir_types.CompilerIrFunctionBuilder
      (compiler_ir_types.compiler-ir-function-builder-with-capacity 1)]
    [instrs : compiler_ir_types.CompilerIrInstrSeq
      (compiler_ir_types.compiler-ir-instr-seq-empty)]
    [blocks : compiler_ir_types.CompilerIrBlockList
      compiler_ir_types.CompilerIrBlockList.Nil]
    [functions : compiler_ir_types.CompilerIrFunctionSeq
      (compiler_ir_types.compiler-ir-function-seq-empty)]
    (begin
      (compiler_ir_types.compiler-ir-instr-builder-push!
        (&mut instr-builder)
        (compiler_ir_types.CompilerIrInstr.Mov
          1
          (compiler_ir_types.CompilerIrValue.I64 10)
          (ast.AstType.I64)))
      (compiler_ir_types.compiler-ir-instr-builder-push!
        (&mut instr-builder)
        (compiler_ir_types.CompilerIrInstr.Mov
          2
          (compiler_ir_types.CompilerIrValue.I64 20)
          (ast.AstType.I64)))
      (compiler_ir_types.compiler-ir-instr-builder-push!
        (&mut instr-builder)
        (compiler_ir_types.CompilerIrInstr.Return
          (compiler_ir_types.CompilerIrMaybeValue.Some
            (compiler_ir_types.CompilerIrValue.Var 2))))
      (set!
        instrs
        (compiler_ir_types.compiler-ir-instr-builder-to-seq instr-builder))
      (compiler_ir_types.compiler-ir-block-builder-push!
        (&mut block-builder)
        (compiler_ir_types.CompilerIrBlock.Block
          (compiler_ir_types.compiler-ir-label "entry")
          (compiler_ir_types.compiler-ir-instr-seq-empty)))
      (compiler_ir_types.compiler-ir-block-builder-push!
        (&mut block-builder)
        (compiler_ir_types.CompilerIrBlock.Block
          (compiler_ir_types.compiler-ir-label "middle")
          (compiler_ir_types.compiler-ir-instr-seq-empty)))
      (compiler_ir_types.compiler-ir-block-builder-push!
        (&mut block-builder)
        (compiler_ir_types.CompilerIrBlock.Block
          (compiler_ir_types.compiler-ir-label "done")
          (compiler_ir_types.compiler-ir-instr-seq-empty)))
      (set!
        blocks
        (compiler_ir_types.compiler-ir-block-builder-to-list block-builder))
      (compiler_ir_types.compiler-ir-function-builder-push!
        (&mut function-builder)
        (compiler-ir-test-function "first"))
      (compiler_ir_types.compiler-ir-function-builder-push!
        (&mut function-builder)
        (compiler-ir-test-function "second"))
      (compiler_ir_types.compiler-ir-function-builder-push!
        (&mut function-builder)
        (compiler-ir-test-function "third"))
      (set!
        functions
        (compiler_ir_types.compiler-ir-function-builder-to-seq function-builder))
      (and
        (= (compiler_ir_types.compiler-ir-instr-seq-count instrs) 3)
        (compiler-ir-instr-seq-mov-dst?
          (compiler_ir_types.compiler-ir-global-shared-view instrs)
          0
          1)
        (compiler-ir-instr-seq-mov-dst?
          (compiler_ir_types.compiler-ir-global-shared-view instrs)
          1
          2)
        (compiler-ir-instr-seq-return-var? instrs 2 2)
        (=
          (compiler_ir_types.compiler-ir-block-list-count
            (compiler_ir_types.compiler-ir-global-shared-view blocks))
          3)
        (compiler-ir-block-list-label-at?
          (compiler_ir_types.compiler-ir-global-shared-view blocks)
          0
          "entry")
        (compiler-ir-block-list-label-at?
          (compiler_ir_types.compiler-ir-global-shared-view blocks)
          1
          "middle")
        (compiler-ir-block-list-label-at? blocks 2 "done")
        (=
          (compiler_ir_types.compiler-ir-function-seq-count
            (compiler_ir_types.compiler-ir-global-shared-view functions))
          3)
        (compiler-ir-function-seq-name-at? functions 0 "first")
        (compiler-ir-function-seq-name-at? functions 1 "second")
        (compiler-ir-function-seq-name-at? functions 2 "third")))))

(define (compiler-ir-param-seq-entry-i64?
  [seq : compiler_ir_types.CompilerIrParamSeq]
  [index : i64]
  [want-name : String]
  [want-var : i64]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (match (compiler_ir_types.compiler-ir-array-shared-view seq.slots index)
      [(compiler_ir_types.CompilerIrParam.Param name ty var)
        (and
          (string.eq name want-name)
          (= var want-var)
          (match ty
            [(ast.AstType.I64) true]
            [_ false]))])))

(define (compiler-ir-param-seq-entry-bool?
  [seq : compiler_ir_types.CompilerIrParamSeq]
  [index : i64]
  [want-name : String]
  [want-var : i64]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (match (array-ref seq.slots index)
      [(compiler_ir_types.CompilerIrParam.Param name ty var)
        (and
          (string.eq name want-name)
          (= var want-var)
          (match ty
            [(ast.AstType.Bool) true]
            [_ false]))])))

(define (compiler-ir-param-seq-dense-order-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-reader-context-current)]
    [builder : compiler_ir_types.CompilerIrParamBuilder
      (compiler_ir_types.compiler-ir-param-builder-with-capacity 1)]
    [snapshot : compiler_ir_types.CompilerIrParamSeq
      (compiler_ir_types.compiler-ir-param-seq-empty)]
    [params : compiler_ir_types.CompilerIrParamSeq
      (compiler_ir_types.compiler-ir-param-seq-empty)]
    [cloned : compiler_ir_types.CompilerIrParamSeq
      (compiler_ir_types.compiler-ir-param-seq-empty)]
    [func : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler_ir_types.compiler-ir-test-symbol "dense_params")
        params
        (ast.AstType.Unit)
        8
        compiler_ir_types.CompilerIrBlockList.Nil
        compiler_ir_types.CompilerIrFunctionAbi.Ordinary)]
    [cloned-func : compiler_ir_types.CompilerIrFunction func]
    (begin
      (compiler_ir_types.compiler-ir-param-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrParam.Param "value" (ast.AstType.I64) 3))
      (set!
        snapshot
        (compiler_ir_types.compiler-ir-param-builder-snapshot (& builder)))
      (compiler_ir_types.compiler-ir-param-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrParam.Param "flag" (ast.AstType.Bool) 7))
      (set! params (compiler_ir_types.compiler-ir-param-builder-to-seq builder))
      (set!
        cloned
        (compiler_ir_types.compiler-ir-clone-param-seq
          pools
          (compiler_ir_types.compiler-ir-global-shared-view params)))
      (set!
        func
        (compiler_ir_types.CompilerIrFunction.Function
          (compiler_ir_types.compiler-ir-test-symbol "dense_params")
          (compiler_ir_types.compiler-ir-global-shared-view params)
          (ast.AstType.Unit)
          8
          compiler_ir_types.CompilerIrBlockList.Nil
          compiler_ir_types.CompilerIrFunctionAbi.Ordinary))
      (set!
        cloned-func
        (compiler_ir_types.compiler-ir-clone-function pools func))
      (and
        (=
          (compiler_ir_types.compiler-ir-param-seq-count
            (compiler_ir_types.compiler-ir-global-shared-view snapshot))
          1)
        (compiler-ir-param-seq-entry-i64? snapshot 0 "value" 3)
        (=
          (compiler_ir_types.compiler-ir-param-seq-count
            (compiler_ir_types.compiler-ir-global-shared-view params))
          2)
        (compiler-ir-param-seq-entry-i64?
          (compiler_ir_types.compiler-ir-global-shared-view params)
          0
          "value"
          3)
        (compiler-ir-param-seq-entry-bool? params 1 "flag" 7)
        (=
          (compiler_ir_types.compiler-ir-param-seq-count
            (compiler_ir_types.compiler-ir-global-shared-view cloned))
          2)
        (compiler-ir-param-seq-entry-i64?
          (compiler_ir_types.compiler-ir-global-shared-view cloned)
          0
          "value"
          3)
        (compiler-ir-param-seq-entry-bool? cloned 1 "flag" 7)
        (match cloned-func
          [(compiler_ir_types.CompilerIrFunction.Function
              _
              cloned-params
              _
              _
              _
              _)
            (and
              (=
                (compiler_ir_types.compiler-ir-param-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view
                    cloned-params))
                2)
              (compiler-ir-param-seq-entry-i64?
                (compiler_ir_types.compiler-ir-global-shared-view cloned-params)
                0
                "value"
                3)
              (compiler-ir-param-seq-entry-bool? cloned-params 1 "flag" 7))])))))

(define (compiler-ir-c-abi-return-slot-seq-entry-i64-offset?
  [seq : (& seq compiler_ir_types.CompilerIrCAbiReturnSlotSeq)]
  [index : i64]
  [want-offset : i64]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (match (array-ref seq.slots index)
      [(compiler_ir_types.CompilerIrCAbiReturnSlot.Slot ty offset)
        (and
          (= offset want-offset)
          (match ty
            [(ast.AstType.I64) true]
            [_ false]))])))

(define (compiler-ir-c-abi-return-slot-seq-entry-f64-offset?
  [seq : compiler_ir_types.CompilerIrCAbiReturnSlotSeq]
  [index : i64]
  [want-offset : i64]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (match (array-ref seq.slots index)
      [(compiler_ir_types.CompilerIrCAbiReturnSlot.Slot ty offset)
        (and
          (= offset want-offset)
          (match ty
            [(ast.AstType.F64) true]
            [_ false]))])))

(define (compiler-ir-c-abi-return-slot-dense-order-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-reader-context-current)]
    [slot-data : (__tl_dyn-array compiler_ir_types.CompilerIrCAbiReturnSlot)
      (__tl_make-array compiler_ir_types.CompilerIrCAbiReturnSlot 2)]
    [_fill : unit
      (begin
        (set!
          (array-ref slot-data 0)
          (compiler_ir_types.CompilerIrCAbiReturnSlot.Slot (ast.AstType.I64) 0))
        (set!
          (array-ref slot-data 1)
          (compiler_ir_types.CompilerIrCAbiReturnSlot.Slot (ast.AstType.F64) 8)))]
    [slots : compiler_ir_types.CompilerIrCAbiReturnSlotSeq
      (compiler_ir_types.CompilerIrCAbiReturnSlotSeq slot-data 2)]
    [cloned : compiler_ir_types.CompilerIrCAbiReturnSlotSeq
      (match (compiler_ir_types.compiler-ir-clone-instr
        pools
        (compiler_ir_types.ir-instr-call-cabi-store-result
          (compiler_ir_types.CompilerIrValue.Var 0)
          0
          (compiler_ir_types.CompilerIrCallArgs.Nil)
          (compiler_ir_types.compiler-ir-global-shared-view slots)))
        [(compiler_ir_types.CompilerIrInstr.CallCAbiStoreResult payload-box)
          (compiler_ir_types.compiler-ir-box-field-shared-view
            payload-box
            slots)]
        [_
          (compiler_ir_types.CompilerIrCAbiReturnSlotSeq
            (__tl_make-array compiler_ir_types.CompilerIrCAbiReturnSlot 0)
            0)])]
    (and
      (= slots.len 2)
      (compiler-ir-c-abi-return-slot-seq-entry-i64-offset? slots 0 0)
      (compiler-ir-c-abi-return-slot-seq-entry-f64-offset? slots 1 8)
      (= cloned.len 2)
      (compiler-ir-c-abi-return-slot-seq-entry-i64-offset? cloned 0 0)
      (compiler-ir-c-abi-return-slot-seq-entry-f64-offset? cloned 1 8))))

(define (compiler-ir-value-seq-entry-var?
  [seq : (& seq compiler_ir_types.CompilerIrValueSeq)]
  [index : i64]
  [want : i64]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (match (array-ref seq.slots index)
      [(compiler_ir_types.CompilerIrValue.Var id) (= id want)]
      [_ false])))

(define (compiler-ir-pack-value-seq-dense-order-ok?) : bool
  (let
    [builder : compiler_ir_types.CompilerIrValueBuilder
      (compiler_ir_types.compiler-ir-value-builder-with-capacity 1)]
    [_first-two : unit
      (begin
        (compiler_ir_types.compiler-ir-value-builder-push!
          (&mut builder)
          (compiler_ir_types.CompilerIrValue.Var 10))
        (compiler_ir_types.compiler-ir-value-builder-push!
          (&mut builder)
          (compiler_ir_types.CompilerIrValue.Var 20)))]
    [snapshot : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.compiler-ir-value-builder-snapshot (& builder))]
    [_third : unit
      (compiler_ir_types.compiler-ir-value-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrValue.Var 30))]
    [words : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.compiler-ir-value-builder-to-seq builder)]
    [cloned : compiler_ir_types.CompilerIrValueSeq
      (match (compiler_ir_types.compiler-ir-clone-instr
        (ast.ast-node-pool-reader-context-current)
        (compiler_ir_types.CompilerIrInstr.Pack
          40
          (compiler_ir_types.compiler-ir-global-shared-view words)
          (ast.AstType.I64)))
        [(compiler_ir_types.CompilerIrInstr.Pack _ cloned-words _) cloned-words]
        [_ (compiler_ir_types.compiler-ir-value-seq-empty)])]
    [instr : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.CompilerIrInstr.Pack
        40
        (compiler_ir_types.compiler-ir-global-shared-view words)
        (ast.AstType.Struct (ci.intern "Triple")))]
    (and
      (= snapshot.len 2)
      (= (array-length snapshot.slots) 2)
      (compiler-ir-value-seq-entry-var? snapshot 0 10)
      (compiler-ir-value-seq-entry-var? snapshot 1 20)
      (match instr
        [(compiler_ir_types.CompilerIrInstr.Pack _ packed _)
          (and
            (= packed.len 3)
            (= (array-length packed.slots) 3)
            (compiler-ir-value-seq-entry-var? packed 0 10)
            (compiler-ir-value-seq-entry-var? packed 1 20)
            (compiler-ir-value-seq-entry-var? packed 2 30))]
        [_ false])
      (= cloned.len 3)
      (compiler-ir-value-seq-entry-var? cloned 0 10)
      (compiler-ir-value-seq-entry-var? cloned 1 20)
      (compiler-ir-value-seq-entry-var? cloned 2 30)
      (string.eq
        (compiler_ir_types.compiler-ir-value-seq-render
          (compiler_ir_types.compiler-ir-global-shared-view words))
        "%10, %20, %30"))))

(define (compiler-ir-descriptor-pair-capability-ok?) : bool
  (let
    [string-kind : compiler_ir_types.CompilerIrDescriptorPairKind
      (compiler_ir_types.CompilerIrDescriptorPairKind.OwnedString)]
    [array-kind : compiler_ir_types.CompilerIrDescriptorPairKind
      (compiler_ir_types.CompilerIrDescriptorPairKind.DynamicArray 77)]
    [pack : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.ir-instr-descriptor-pair-pack
        30
        (compiler_ir_types.CompilerIrValue.Var 10)
        (compiler_ir_types.CompilerIrValue.Var 20)
        string-kind)]
    [data : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.ir-instr-descriptor-pair-data
        31
        (compiler_ir_types.CompilerIrValue.Var 30))]
    [length : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.ir-instr-descriptor-pair-length
        32
        (compiler_ir_types.CompilerIrValue.Var 30))]
    (and
      (match (compiler-ir-descriptor-pair-kind-for-handle-type
        (ast.AstType.String))
        [(CompilerIrMaybeDescriptorPairKind.Some kind)
          (match kind
            [(compiler_ir_types.CompilerIrDescriptorPairKind.OwnedString) true]
            [_ false])]
        [(CompilerIrMaybeDescriptorPairKind.No) false])
      (match (compiler-ir-descriptor-pair-kind-for-handle-type
        (ast.AstType.DynArray 77))
        [(CompilerIrMaybeDescriptorPairKind.Some kind)
          (match kind
            [(compiler_ir_types.CompilerIrDescriptorPairKind.DynamicArray elem)
              (= elem 77)]
            [_ false])]
        [(CompilerIrMaybeDescriptorPairKind.No) false])
      (match (compiler-ir-descriptor-pair-kind-for-handle-type
        (ast.AstType.Array 77 4))
        [(CompilerIrMaybeDescriptorPairKind.No) true]
        [_ false])
      (match (compiler-ir-descriptor-pair-kind-for-handle-type
        (ast.AstType.Str))
        [(CompilerIrMaybeDescriptorPairKind.No) true]
        [_ false])
      (match (compiler_ir_types.compiler-ir-descriptor-pair-handle-type
        array-kind)
        [(ast.AstType.DynArray elem) (= elem 77)]
        [_ false])
      (match pack
        [(compiler_ir_types.CompilerIrInstr.Pack dst words ty)
          (and
            (= dst 30)
            (match ty
              [(ast.AstType.String) true]
              [_ false])
            (= words.len 2)
            (compiler-ir-value-seq-entry-var? words 0 10)
            (compiler-ir-value-seq-entry-var? words 1 20))]
        [_ false])
      (match data
        [(compiler_ir_types.CompilerIrInstr.Word
            dst
            (compiler_ir_types.CompilerIrValue.Var src)
            index
            ty)
          (and
            (= dst 31)
            (= src 30)
            (= index 0)
            (match ty
              [(ast.AstType.U64) true]
              [_ false]))]
        [_ false])
      (match length
        [(compiler_ir_types.CompilerIrInstr.Word
            dst
            (compiler_ir_types.CompilerIrValue.Var src)
            index
            ty)
          (and
            (= dst 32)
            (= src 30)
            (= index 1)
            (match ty
              [(ast.AstType.I64) true]
              [_ false]))]
        [_ false]))))

(define (compiler-ir-phi-input-seq-entry-var-label?
  [seq : compiler_ir_types.CompilerIrPhiInputSeq]
  [index : i64]
  [want-var : i64]
  [want-label : String]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (let
      [input : compiler_ir_types.CompilerIrPhiInput
        (compiler_ir_types.compiler-ir-phi-input-seq-ref seq index)]
      (and
        (string.eq
          (compiler_ir_types.compiler-ir-label-text input.label)
          want-label)
        (match input.value
          [(compiler_ir_types.CompilerIrValue.Var id) (= id want-var)]
          [_ false])))))

(define (compiler-ir-phi-input-dense-order-ok?) : bool
  (let
    [inputs : compiler_ir_types.CompilerIrPhiInputSeq
      (compiler_ir_types.compiler-ir-phi-input-seq-prepend
        (compiler_ir_types.CompilerIrValue.Var 10)
        (compiler_ir_types.compiler-ir-label "entry")
        (compiler_ir_types.compiler-ir-phi-input-seq-prepend
          (compiler_ir_types.CompilerIrValue.Var 20)
          (compiler_ir_types.compiler-ir-label "loop")
          (compiler_ir_types.compiler-ir-phi-input-seq-empty)))]
    [cloned : compiler_ir_types.CompilerIrPhiInputSeq
      (match (compiler_ir_types.compiler-ir-clone-instr
        (ast.ast-node-pool-reader-context-current)
        (compiler_ir_types.CompilerIrInstr.Phi
          1
          (compiler_ir_types.compiler-ir-global-shared-view inputs)
          (ast.AstType.I64)))
        [(compiler_ir_types.CompilerIrInstr.Phi _ cloned-inputs _)
          cloned-inputs]
        [_ (compiler_ir_types.compiler-ir-phi-input-seq-empty)])]
    [tail : compiler_ir_types.CompilerIrPhiInputSeq
      (let
        [phi-inputs-at-9678-7 : compiler_ir_types.CompilerIrPhiInputSeq
          (compiler_ir_types.compiler-ir-global-shared-view inputs)]
        (if (<= phi-inputs-at-9678-7.len 0)
          (compiler_ir_types.compiler-ir-phi-input-seq-empty)
          (let
            [rest : compiler_ir_types.CompilerIrPhiInputSeq
              (compiler_ir_types.CompilerIrPhiInputSeq
                phi-inputs-at-9678-7.slots
                (+ phi-inputs-at-9678-7.start 1)
                (- phi-inputs-at-9678-7.len 1))]
            rest)))]
    [reversed : compiler_ir_types.CompilerIrPhiInputSeq
      (compiler_ir_types.compiler-ir-phi-input-seq-reverse-onto
        (compiler_ir_types.compiler-ir-global-shared-view inputs)
        (compiler_ir_types.compiler-ir-phi-input-seq-empty))]
    (and
      (=
        (compiler_ir_types.compiler-ir-phi-input-seq-count
          (compiler_ir_types.compiler-ir-global-shared-view inputs))
        2)
      (compiler-ir-phi-input-seq-entry-var-label?
        (compiler_ir_types.compiler-ir-global-shared-view inputs)
        0
        10
        "entry")
      (compiler-ir-phi-input-seq-entry-var-label? inputs 1 20 "loop")
      (compiler-ir-phi-input-seq-entry-var-label? cloned 0 10 "entry")
      (=
        (compiler_ir_types.compiler-ir-phi-input-seq-count
          (compiler_ir_types.compiler-ir-global-shared-view tail))
        1)
      (compiler-ir-phi-input-seq-entry-var-label? tail 0 20 "loop")
      (compiler-ir-phi-input-seq-entry-var-label?
        (compiler_ir_types.compiler-ir-global-shared-view reversed)
        0
        20
        "loop")
      (compiler-ir-phi-input-seq-entry-var-label? reversed 1 10 "entry"))))

(define (compiler-ir-switch-case-seq-entry-tag-label?
  [seq : (& seq compiler_ir_types.CompilerIrSwitchCaseSeq)]
  [index : i64]
  [want-tag : i64]
  [want-label : String]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (match (array-ref seq.slots index)
      [(compiler_ir_types.CompilerIrSwitchCase.Case tag label)
        (and
          (= tag want-tag)
          (string.eq
            (compiler_ir_types.compiler-ir-label-text label)
            want-label))])))

(define (compiler-ir-switch-case-dense-order-ok?) : bool
  (let
    [builder : compiler_ir_types.CompilerIrSwitchCaseBuilder
      (compiler_ir_types.compiler-ir-switch-case-builder-with-capacity 1)]
    (begin
      (compiler_ir_types.compiler-ir-switch-case-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrSwitchCase.Case
          4
          (compiler_ir_types.compiler-ir-label "four")))
      (compiler_ir_types.compiler-ir-switch-case-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrSwitchCase.Case
          5
          (compiler_ir_types.compiler-ir-label "five")))
      (let
        [cases : compiler_ir_types.CompilerIrSwitchCaseSeq
          (compiler_ir_types.compiler-ir-switch-case-builder-to-seq builder)]
        [cloned : compiler_ir_types.CompilerIrSwitchCaseSeq
          (match (compiler_ir_types.compiler-ir-clone-instr
            (ast.ast-node-pool-reader-context-current)
            (compiler_ir_types.CompilerIrInstr.Switch
              (compiler_ir_types.CompilerIrValue.I64 0)
              0
              (compiler_ir_types.compiler-ir-global-shared-view cases)
              (compiler_ir_types.compiler-ir-label "default")))
            [(compiler_ir_types.CompilerIrInstr.Switch _ _ cloned-cases _)
              cloned-cases]
            [_ (compiler-ir-switch-case-seq-empty)])]
        (and
          (= (compiler_ir_types.compiler-ir-switch-case-seq-count cases) 2)
          (string.eq
            (compiler_ir_types.compiler-ir-switch-case-seq-render cases)
            "4:four, 5:five")
          (compiler-ir-switch-case-seq-entry-tag-label? cases 0 4 "four")
          (compiler-ir-switch-case-seq-entry-tag-label? cases 1 5 "five")
          (compiler-ir-switch-case-seq-entry-tag-label? cloned 0 4 "four")
          (compiler-ir-switch-case-seq-entry-tag-label? cloned 1 5 "five"))))))

(define (compiler-ir-instr-seq-dense-construction-ok?) : bool
  (let
    [seq : compiler_ir_types.CompilerIrInstrSeq
      (compiler_ir_types.compiler-ir-instr-seq3
        (compiler_ir_types.CompilerIrInstr.Mov
          1
          (compiler_ir_types.CompilerIrValue.I64 10)
          (ast.AstType.I64))
        (compiler_ir_types.CompilerIrInstr.Mov
          2
          (compiler_ir_types.CompilerIrValue.I64 20)
          (ast.AstType.I64))
        (compiler_ir_types.CompilerIrInstr.Return
          (compiler_ir_types.CompilerIrMaybeValue.Some
            (compiler_ir_types.CompilerIrValue.Var 2))))]
    [block-list : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-block-cons
        (compiler_ir_types.compiler-ir-block
          (compiler_ir_types.compiler-ir-label "entry")
          (compiler_ir_types.compiler-ir-global-shared-view seq))
        compiler_ir_types.CompilerIrBlockList.Nil)]
    [compact-blocks : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-block-list-compact
        (compiler_ir_types.compiler-ir-global-shared-view block-list))]
    (and
      (= (compiler_ir_types.compiler-ir-instr-seq-count seq) 3)
      (not (compiler_ir_types.compiler-ir-instr-seq-empty? seq))
      (match (compiler_ir_types.compiler-ir-instr-seq-ref seq 2)
        [(compiler_ir_types.CompilerIrInstr.Return _) true]
        [_ false])
      (=
        (compiler_ir_types.compiler-ir-block-list-instruction-count block-list)
        3)
      (=
        (compiler_ir_types.compiler-ir-block-list-count
          (compiler_ir_types.compiler-ir-global-shared-view compact-blocks))
        1)
      (compiler-ir-block-list-first-label? compact-blocks "entry")
      (compiler-ir-instr-seq-mov-dst? seq 0 1))))

(define (compiler-ir-effect-self-test) : i64
  (begin
    (unless (compiler-ir-instruction-effects-ok?) (return 1))
    (unless (compiler-ir-vector-mask-effects-ok?) (return 1))
    (unless (compiler-ir-effect-predicates-ok?) (return 1))
    (unless (compiler-ir-display-self-test-ok?) (return 1))
    (unless (compiler-ir-tail-call-render-ok?) (return 1))
    (unless (compiler-ir-switch-render-ok?) (return 1))
    (unless (compiler-ir-source-spans-entry-list-ok?) (return 1))
    (unless (compiler-ir-instr-seq-dense-construction-ok?) (return 1))
    (unless (compiler-ir-instr-seq-mutable-rewrite-ok?) (return 1))
    (unless (compiler-ir-instr-seq-mutable-compact-ok?) (return 1))
    (unless (compiler-ir-dense-builders-order-ok?) (return 1))
    (unless (compiler-ir-param-seq-dense-order-ok?) (return 1))
    (unless (compiler-ir-c-abi-return-slot-dense-order-ok?) (return 1))
    (unless (compiler-ir-pack-value-seq-dense-order-ok?) (return 1))
    (unless (compiler-ir-descriptor-pair-capability-ok?) (return 1))
    (unless (compiler-ir-phi-input-dense-order-ok?) (return 1))
    (unless (compiler-ir-switch-case-dense-order-ok?) (return 1))
    42))

(define (main) : i64
  (begin
    (unless (compiler-ir-smoke-function-seq-roundtrip-ok?) (return 1))
    (unless (compiler-ir-smoke-reversed-compaction-ok?) (return 2))
    (unless (compiler-ir-smoke-spmd-call-shape-ok?) (return 3))
    (unless (compiler-ir-smoke-spmd-catalog-origin-ok?) (return 22))
    (unless (compiler-ir-smoke-spmd-catalog-mismatches-ok?) (return 23))
    (unless (compiler-ir-smoke-dense-function-params-ok?) (return 4))
    (unless (compiler-ir-smoke-global-extern-seq-roundtrip-ok?) (return 5))
    (unless (compiler-ir-smoke-access-helpers-ok?) (return 6))
    (unless (compiler-ir-smoke-runtime-effect-self-test-ok?) (return 7))
    (unless (compiler-ir-smoke-slice-type-render-clone-ok?) (return 8))
    (unless (compiler-ir-smoke-derived-symbol-table-ok?) (return 9))
    (unless (compiler-ir-smoke-structural-lifetime-render-ok?) (return 10))
    (unless (compiler-ir-smoke-source-spans-escape-ok?) (return 11))
    (let
      [representation-failure : i64
        (compiler-ir-smoke-representation-index-failure)]
      (unless
        (= representation-failure 0)
        (return (+ 11 representation-failure))))
    (unless (compiler-ir-smoke-store-owned-ok?) (return 21))
    (unless (compiler-ir-smoke-call-arg-map-visit-ok?) (return 22))
    (unless (compiler-ir-smoke-spmd-map-visit-ok?) (return 23))
    (unless (compiler-ir-smoke-value-seq-map-visit-ok?) (return 24))
    (unless (= (compiler-ir-smoke-operand-api-failure) 0) (return 25))
    (let
      [private-abi-failure : i64 (compiler-ir-smoke-spmd-private-abi-failure)]
      (unless (= private-abi-failure 0) (return (+ 100 private-abi-failure))))
    (compiler-ir-effect-self-test)))