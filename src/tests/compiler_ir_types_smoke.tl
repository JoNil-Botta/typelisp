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
    (match (compiler_ir_types.compiler-ir-function-seq-ref
      (compiler_ir_types.compiler-ir-global-shared-view functions)
      0)
      [(compiler_ir_types.CompilerIrFunction.Function name _ _ _ _)
        (string.eq (ci.intern-str name) want)])))

(define (compiler-ir-smoke-function-seq-name-at?
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [index : i64]
  [want : String]) : bool
  (if (or (< index 0) (>= index functions.len))
    false
    (match (compiler_ir_types.compiler-ir-function-seq-ref
      (compiler_ir_types.compiler-ir-global-shared-view functions)
      index)
      [(compiler_ir_types.CompilerIrFunction.Function name _ _ _ _)
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
        (compiler-ir-smoke-block-list-label-at?
          (compiler_ir_types.compiler-ir-block-list-box-shared-view rest)
          (- index 1)
          want))]
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
    (match (compiler_ir_types.compiler-ir-param-seq-ref
      (compiler_ir_types.compiler-ir-global-shared-view seq)
      index)
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
    (match (compiler_ir_types.compiler-ir-param-seq-ref
      (compiler_ir_types.compiler-ir-global-shared-view seq)
      index)
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
        compiler_ir_types.CompilerIrBlockList.Nil)]
    [cloned : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.compiler-ir-clone-function
        (ast.ast-node-pool-reader-context-current)
        (compiler_ir_types.compiler-ir-global-shared-view func))]
    (and
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ stored _ _ _)
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
        [(compiler_ir_types.CompilerIrFunction.Function _ stored _ _ _)
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
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : bool
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
      (compiler-ir-smoke-global-seq-name-at?
        (compiler_ir_types.compiler-ir-global-shared-view compact-globals)
        1
        "second-global")
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
      (=
        (compiler_ir_types.compiler-ir-summary-globals
          (compiler_ir_types.compiler-ir-global-shared-view summary))
        2)
      (=
        (compiler_ir_types.compiler-ir-summary-functions
          (compiler_ir_types.compiler-ir-global-shared-view summary))
        0)
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
        (compiler_ir_types.compiler-ir-global-shared-view blocks))]
    [second : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "second")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (ast.AstType.I64)
        2
        blocks)]
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
      (compiler-ir-smoke-function-seq-count-two?
        (compiler_ir_types.compiler-ir-global-shared-view compact))
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
          (compiler_ir_types.compiler-ir-global-shared-view compact))
        2)
      (=
        (compiler_ir_types.compiler-ir-function-seq-instruction-count compact)
        4)
      (=
        (compiler_ir_types.compiler-ir-summary-functions
          (compiler_ir_types.compiler-ir-global-shared-view summary))
        2)
      (=
        (compiler_ir_types.compiler-ir-summary-blocks
          (compiler_ir_types.compiler-ir-global-shared-view summary))
        2)
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
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks))]
    [second-func : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "second-func")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (ast.AstType.Unit)
        0
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks))]
    [third-func : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "third-func")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (ast.AstType.Unit)
        0
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks))]
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
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks)
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
      (compiler-ir-smoke-function-seq-name-at?
        (compiler_ir_types.compiler-ir-global-shared-view compact-functions)
        2
        "third-func")
      (compiler-ir-smoke-function-seq-name-at?
        (compiler_ir_types.compiler-ir-global-shared-view
          array-reversed-functions)
        0
        "third-func")
      (compiler-ir-smoke-function-seq-name-at?
        array-reversed-functions
        2
        "first-func"))))

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
      (compiler_ir_types.ir-instr-spmd-call
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
    [spans : compiler_ir_types.CompilerSourceSpans
      (compiler_ir_types.compiler-source-spans-insert-instr
        (compiler_ir_types.compiler-source-spans-empty)
        7
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        span)]
    (and
      (string.eq
        (compiler_ir_types.compiler-ir-instr-render
          (cis.InternStructuralSessionHandle 0)
          (ast.ast-node-pool-reader-type-segment-bases)
          (compiler_ir_types.compiler-ir-global-shared-view instr))
        "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) : varying i64")
      (string.eq
        (compiler_ir_types.compiler-ir-instr-describe
          (ast.ast-node-pool-reader-type-segment-bases)
          (compiler_ir_types.compiler-ir-global-shared-view instr))
        "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) -> %6 : varying i64")
      (match (compiler_ir_types.compiler-ir-global-shared-view instr)
        [(compiler_ir_types.CompilerIrInstr.SpmdCall payload-box)
          (let
            [stored-args
              (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                args)]
            (and (= stored-args.len 2) (= (array-length stored-args.slots) 2)))]
        [_ false])
      (compiler_ir_types.compiler-ir-effect-is?
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
        (compiler_ir_types.compiler-ir-global-shared-view spans)
        7
        (compiler_ir_types.compiler-ir-global-shared-view instr))
        [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
          (and
            (= (ast.ast-source-span-start-line found) 3)
            (= (ast.ast-source-span-end-col found) 9))]
        [(compiler_ir_types.CompilerMaybeSourceSpan.No) false]))))

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
        (compiler_ir_types.compiler-ir-instr-array-loop-dst-or
          (compiler_ir_types.compiler-ir-global-shared-view slots)
          1
          (- 0 1))
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
    [slice : ast.AstType
      (ast.ast-ty-slice-with-pools
        (compiler_ir_types.compiler-ir-global-shared-view pools)
        ast.AstType.I64)]
    [borrowed : ast.AstType
      (ast.ast-ty-ref-with-pools
        (compiler_ir_types.compiler-ir-global-shared-view pools)
        lifetime
        slice)]
    [bases : i64 (ast.ast-node-pool-context-type-segment-bases (& pools))]
    [clone : ast.AstType
      (compiler_ir_types.compiler-ir-clone-type
        (compiler_ir_types.compiler-ir-global-shared-view pools)
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
      (compiler_ir_types.compiler-ir-type-name
        bases
        (compiler_ir_types.compiler-ir-global-shared-view borrowed))]
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
      (match (compiler_ir_types.compiler-ir-global-shared-view clone)
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
      (ast.ast-ty-ref-with-pools
        (compiler_ir_types.compiler-ir-global-shared-view pools)
        lifetime
        ast.AstType.I64)]
    [arithmetic-borrowed : ast.AstType
      (ast.ast-ty-ref-with-pools
        (compiler_ir_types.compiler-ir-global-shared-view pools)
        (ci.intern-structural-local-id 8 source)
        ast.AstType.I64)]
    [other-intern : ci.InternCompatState (ci.intern-compat-state-new)]
    [other-session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state (& other-intern)))]
    [invalid : ast.AstType
      (ast.ast-ty-ref-with-pools
        (compiler_ir_types.compiler-ir-global-shared-view pools)
        (ci.intern-capacity)
        ast.AstType.I64)]
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
        (compiler_ir_types.compiler-ir-type-render
          other-session
          bases
          (compiler_ir_types.compiler-ir-global-shared-view borrowed))
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
;; the initial slab without losing earlier entries, ids inside the free window
;; the interner's own budget self-tests pin, and no cost at all to the intern
;; lanes -- the budget the table exists to buy back.
(define (compiler-ir-smoke-derived-symbol-table-ok?) : bool
  (let
    [pool-id : i64 (ci.intern "ir-smoke-pool-name")]
    [pool-before : i64 (ci.intern-pool-len)]
    [generated-before : i64 (ci.intern-generated-count)]
    [capacity : i64 (ci.intern-capacity)]
    [base : i64 (compiler_ir_types.compiler-ir-symbol-base)]
    [count-before : i64 (compiler_ir_types.compiler-ir-symbol-count-value)]
    [first : i64 (compiler_ir_types.compiler-ir-symbol "ir-smoke/one")]
    [second : i64 (compiler_ir_types.compiler-ir-symbol "ir-smoke/two")]
    [first-again : i64 (compiler_ir_types.compiler-ir-symbol "ir-smoke/one")]
    [last-grown : i64 0]
    [index : i64 0]
    [ok : bool true]
    (begin
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
      ;; Ids are dense in the free window [4*capacity, capacity^2) ...
      (unless (= base (* 4 capacity)) (set! ok false))
      (unless (= first (+ base count-before)) (set! ok false))
      (unless (= second (+ first 1)) (set! ok false))
      (unless (< second (* capacity capacity)) (set! ok false))
      (unless
        (= (compiler_ir_types.compiler-ir-symbol-slot first) (- first base))
        (set! ok false))
      (unless
        (compiler_ir_types.compiler-ir-symbol-owned? first)
        (set! ok false))
      ;; ... which neither a pool id nor a cfg key id reaches, and which no pool
      ;; render API claims.
      (unless
        (not (compiler_ir_types.compiler-ir-symbol-owned? (- capacity 1)))
        (set! ok false))
      (unless
        (not
          (compiler_ir_types.compiler-ir-symbol-owned?
            (+ capacity (- capacity 1))))
        (set! ok false))
      (unless (not (ci.intern-renderable-id? first)) (set! ok false))
      ;; Unminted ids in the window, and the negative sentinel, render empty
      ;; rather than aborting: diagnostics reach this path with whatever the IR
      ;; is holding.
      (unless
        (string.eq
          (compiler_ir_types.compiler-ir-symbol-text
            (+ base (compiler_ir_types.compiler-ir-symbol-count-value)))
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
      (compiler_ir_types.CompilerSourceSpansInstrKey.Value 11 12)]
    [store-key : compiler_ir_types.CompilerSourceSpansInstrKey
      (compiler_ir_types.CompilerSourceSpansInstrKey.Store 13 14)]
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
      (match (compiler_ir_types.compiler-ir-global-shared-view escaped)
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
              compiler_ir_types.CompilerIrBlockList.Nil))
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
            (compiler_ir_types.compiler-ir-global-shared-view index)
            (ast.ast-global-shared-view group-ty))
          2
          2)
        (return 1))
      (unless
        (compiler-ir-smoke-representation-kind-group?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            (compiler_ir_types.compiler-ir-global-shared-view index)
            (ast.ast-global-shared-view region-ty))
          2
          2)
        (return 2))
      (unless
        (compiler-ir-smoke-representation-kind-group?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            (compiler_ir_types.compiler-ir-global-shared-view index)
            (ast.ast-global-shared-view signature-ty))
          2
          2)
        (return 3))
      (unless
        (compiler-ir-smoke-representation-kind-one?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            (compiler_ir_types.compiler-ir-global-shared-view index)
            (ast.ast-global-shared-view one-ty)))
        (return 4))
      (unless
        (compiler-ir-smoke-representation-kind-unknown?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            (compiler_ir_types.compiler-ir-global-shared-view index)
            (ast.ast-global-shared-view conflict-ty)))
        (return 5))
      (unless
        (compiler-ir-smoke-representation-kind-unknown?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            (compiler_ir_types.compiler-ir-global-shared-view index)
            (ast.ast-global-shared-view private-ty)))
        (return 6))
      (unless
        (compiler-ir-smoke-representation-kind-unknown?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            (compiler_ir_types.compiler-ir-global-shared-view index)
            (ast.ast-global-shared-view malformed-ty)))
        (return 7))
      (unless
        (compiler-ir-smoke-representation-kind-unknown?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            (compiler_ir_types.compiler-ir-global-shared-view index)
            (ast.AstType.Var 99)))
        (return 8))
      (unless
        (compiler-ir-smoke-representation-kind-unknown?
          (compiler_ir_types.compiler-ir-representation-index-kind
            bases
            (compiler_ir_types.compiler-ir-global-shared-view index)
            (ast.AstType.String)))
        (return 9))
      0)))

(define (main) : i64
  (begin
    (unless (compiler-ir-smoke-function-seq-roundtrip-ok?) (return 1))
    (unless (compiler-ir-smoke-reversed-compaction-ok?) (return 2))
    (unless (compiler-ir-smoke-spmd-call-shape-ok?) (return 3))
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
    (compiler_ir_types.compiler-ir-effect-self-test)))