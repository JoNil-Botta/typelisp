;; compiler_ir_types_smoke.tl - Runnable IR type/effect smoke.
(import stdlib.string)
(import compiler_ir_types)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
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

(define (compiler-ir-smoke-function-list-first-name?
  [functions : compiler_ir_types.CompilerIrFunctionList]
  [want : String]) : bool
  (match (compiler_ir_types.compiler-ir-function-list-force-cons functions)
    [(compiler_ir_types.CompilerIrFunctionList.Cons func _)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function name _ _ _ _)
          (string.eq (ci.intern-str name) want)])]
    [(compiler_ir_types.CompilerIrFunctionList.Nil) false]
    [(compiler_ir_types.CompilerIrFunctionList.Array _) false]))

(define (compiler-ir-smoke-function-list-name-at?
  [functions : compiler_ir_types.CompilerIrFunctionList]
  [index : i64]
  [want : String]) : bool
  (match (compiler_ir_types.compiler-ir-function-list-force-cons functions)
    [(compiler_ir_types.CompilerIrFunctionList.Cons func rest)
      (if (= index 0)
        (match func
          [(compiler_ir_types.CompilerIrFunction.Function name _ _ _ _)
            (string.eq (ci.intern-str name) want)])
        (compiler-ir-smoke-function-list-name-at?
          (box-get rest)
          (- index 1)
          want))]
    [(compiler_ir_types.CompilerIrFunctionList.Nil) false]
    [(compiler_ir_types.CompilerIrFunctionList.Array _) false]))

(define (compiler-ir-smoke-block-list-label-at?
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [index : i64]
  [want : i64]) : bool
  (match (compiler_ir_types.compiler-ir-block-list-force-cons blocks)
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (if (= index 0)
        (match block
          [(compiler_ir_types.CompilerIrBlock.Block label _) (= label want)])
        (compiler-ir-smoke-block-list-label-at? (box-get rest) (- index 1) want))]
    [(compiler_ir_types.CompilerIrBlockList.Nil) false]
    [(compiler_ir_types.CompilerIrBlockList.Array _) false]))

(define (compiler-ir-smoke-param-seq-entry-i64?
  [seq : compiler_ir_types.CompilerIrParamSeq]
  [index : i64]
  [want-name : String]
  [want-var : i64]) : bool
  (if (or
    (< index 0)
    (>= index (compiler_ir_types.compiler-ir-param-seq-count seq)))
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
    (>= index (compiler_ir_types.compiler-ir-param-seq-count seq)))
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
    [params : compiler_ir_types.CompilerIrParamList
      (compiler_ir_types.compiler-ir-param-cons
        (compiler_ir_types.CompilerIrParam.Param "value" (ast.AstType.I64) 2)
        (compiler_ir_types.compiler-ir-param-cons
          (compiler_ir_types.CompilerIrParam.Param "flag" (ast.AstType.Bool) 5)
          compiler_ir_types.CompilerIrParamList.Nil))]
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
        func)]
    (and
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ stored _ _ _)
          (match stored
            [(compiler_ir_types.CompilerIrParamList.Array seq)
              (and
                (= (compiler_ir_types.compiler-ir-param-seq-count seq) 2)
                (compiler-ir-smoke-param-seq-entry-i64? seq 0 "value" 2)
                (compiler-ir-smoke-param-seq-entry-bool? seq 1 "flag" 5))]
            [_ false])])
      (match cloned
        [(compiler_ir_types.CompilerIrFunction.Function _ stored _ _ _)
          (match stored
            [(compiler_ir_types.CompilerIrParamList.Array seq)
              (and
                (= (compiler_ir_types.compiler-ir-param-seq-count seq) 2)
                (compiler-ir-smoke-param-seq-entry-i64? seq 0 "value" 2)
                (compiler-ir-smoke-param-seq-entry-bool? seq 1 "flag" 5))]
            [_ false])]))))

(define (compiler-ir-smoke-function-list-compact-kind?
  [functions : compiler_ir_types.CompilerIrFunctionList]) : bool
  (match functions
    [(compiler_ir_types.CompilerIrFunctionList.Array seq)
      (= (compiler_ir_types.compiler-ir-function-seq-count seq) 2)]
    [_ false]))

(define (compiler-ir-smoke-global-list-array-count?
  [globals : compiler_ir_types.CompilerIrGlobalList]
  [want : i64]) : bool
  (match globals
    [(compiler_ir_types.CompilerIrGlobalList.Array seq)
      (= (compiler_ir_types.compiler-ir-global-seq-count seq) want)]
    [_ false]))

(define (compiler-ir-smoke-extern-list-array-count?
  [externs : compiler_ir_types.CompilerIrExternList]
  [want : i64]) : bool
  (match externs
    [(compiler_ir_types.CompilerIrExternList.Array seq)
      (= (compiler_ir_types.compiler-ir-extern-seq-count seq) want)]
    [_ false]))

(define (compiler-ir-smoke-global-list-name-at?
  [globals : compiler_ir_types.CompilerIrGlobalList]
  [index : i64]
  [want : String]) : bool
  (match (match globals
    [(compiler_ir_types.CompilerIrGlobalList.Array seq)
      (compiler_ir_types.compiler-ir-global-seq-to-list seq)]
    [_ globals])
    [(compiler_ir_types.CompilerIrGlobalList.Cons global rest)
      (if (= index 0)
        (match global
          [(compiler_ir_types.CompilerIrGlobal.Global name _ _)
            (string.eq (ci.intern-str name) want)])
        (compiler-ir-smoke-global-list-name-at? (box-get rest) (- index 1) want))]
    [(compiler_ir_types.CompilerIrGlobalList.Nil) false]
    [(compiler_ir_types.CompilerIrGlobalList.Array _) false]))

(define (compiler-ir-smoke-extern-list-name-at?
  [externs : compiler_ir_types.CompilerIrExternList]
  [index : i64]
  [want : String]) : bool
  (match (match externs
    [(compiler_ir_types.CompilerIrExternList.Array seq)
      (compiler_ir_types.compiler-ir-extern-seq-to-list seq)]
    [_ externs])
    [(compiler_ir_types.CompilerIrExternList.Cons extern rest)
      (if (= index 0)
        (match extern
          [(compiler_ir_types.CompilerIrExtern.Extern _ _ name _ _ _ _ _)
            (string.eq name want)])
        (compiler-ir-smoke-extern-list-name-at? (box-get rest) (- index 1) want))]
    [(compiler_ir_types.CompilerIrExternList.Nil) false]
    [(compiler_ir_types.CompilerIrExternList.Array _) false]))

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
    [reversed-globals : compiler_ir_types.CompilerIrGlobalList
      (compiler_ir_types.compiler-ir-global-cons
        second-global
        (compiler_ir_types.compiler-ir-global-cons
          first-global
          compiler_ir_types.CompilerIrGlobalList.Nil))]
    [compact-globals : compiler_ir_types.CompilerIrGlobalList
      (compiler_ir_types.compiler-ir-global-list-compact-reversed
        reversed-globals)]
    [array-reversed-globals : compiler_ir_types.CompilerIrGlobalList
      (compiler_ir_types.compiler-ir-global-list-compact-reversed
        compact-globals)]
    [cloned-globals : compiler_ir_types.CompilerIrGlobalList
      (compiler_ir_types.compiler-ir-clone-global-list
        (ast.ast-node-pool-reader-context-current)
        compact-globals)]
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
    [reversed-externs : compiler_ir_types.CompilerIrExternList
      (compiler_ir_types.compiler-ir-extern-cons
        second-extern
        (compiler_ir_types.compiler-ir-extern-cons
          first-extern
          compiler_ir_types.CompilerIrExternList.Nil))]
    [compact-externs : compiler_ir_types.CompilerIrExternList
      (compiler_ir_types.compiler-ir-extern-list-compact-reversed
        reversed-externs)]
    [array-reversed-externs : compiler_ir_types.CompilerIrExternList
      (compiler_ir_types.compiler-ir-extern-list-compact-reversed
        compact-externs)]
    [cloned-externs : compiler_ir_types.CompilerIrExternList
      (compiler_ir_types.compiler-ir-clone-extern-list
        (ast.ast-node-pool-reader-context-current)
        compact-externs)]
    [summary : compiler_ir_types.CompilerIrSummary
      (compiler_ir_types.compiler-ir-program-summary
        (compiler_ir_types.CompilerIrProgram.Program
          compact-globals
          compiler_ir_types.CompilerIrFunctionList.Nil
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
      (= (compiler_ir_types.compiler-ir-summary-globals summary) 2)
      (= (compiler_ir_types.compiler-ir-summary-functions summary) 0)
      (= (compiler_ir_types.compiler-ir-summary-externs summary) 2))))

(define (compiler-ir-smoke-function-seq-roundtrip-ok?) : bool
  (let
    [entry-instrs : compiler_ir_types.CompilerIrInstrList
      (compiler_ir_types.compiler-ir-instr-cons
        (compiler_ir_types.CompilerIrInstr.Mov
          1
          (compiler_ir_types.CompilerIrValue.I64 10)
          (ast.AstType.I64))
        (compiler_ir_types.compiler-ir-instr-cons
          (compiler_ir_types.CompilerIrInstr.Return
            (compiler_ir_types.CompilerIrMaybeValue.Some
              (compiler_ir_types.CompilerIrValue.Var 1)))
          compiler_ir_types.CompilerIrInstrList.Nil))]
    [blocks : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-block-list-compact
        (compiler_ir_types.compiler-ir-block-cons
          (compiler_ir_types.compiler-ir-block
            (compiler_ir_types.compiler-ir-label "entry")
            entry-instrs)
          compiler_ir_types.CompilerIrBlockList.Nil))]
    [first : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "first")
        compiler_ir_types.CompilerIrParamList.Nil
        (ast.AstType.I64)
        2
        blocks)]
    [second : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "second")
        compiler_ir_types.CompilerIrParamList.Nil
        (ast.AstType.I64)
        2
        blocks)]
    [functions : compiler_ir_types.CompilerIrFunctionList
      (compiler_ir_types.compiler-ir-function-cons
        first
        (compiler_ir_types.compiler-ir-function-cons
          second
          compiler_ir_types.CompilerIrFunctionList.Nil))]
    [compact : compiler_ir_types.CompilerIrFunctionList
      (compiler_ir_types.compiler-ir-function-list-compact functions)]
    [cloned : compiler_ir_types.CompilerIrFunctionList
      (compiler_ir_types.compiler-ir-clone-function-list
        (ast.ast-node-pool-reader-context-current)
        compact)]
    [summary : compiler_ir_types.CompilerIrSummary
      (compiler_ir_types.compiler-ir-program-summary
        (compiler_ir_types.CompilerIrProgram.Program
          compiler_ir_types.CompilerIrGlobalList.Nil
          compact
          compiler_ir_types.CompilerIrExternList.Nil))]
    (and
      (compiler-ir-smoke-function-list-compact-kind? compact)
      (compiler-ir-smoke-function-list-compact-kind? cloned)
      (= (compiler_ir_types.compiler-ir-function-list-count compact) 2)
      (compiler-ir-smoke-function-list-first-name? compact "first")
      (= (compiler_ir_types.compiler-ir-function-list-block-count compact) 2)
      (=
        (compiler_ir_types.compiler-ir-function-list-instruction-count compact)
        4)
      (= (compiler_ir_types.compiler-ir-summary-functions summary) 2)
      (= (compiler_ir_types.compiler-ir-summary-blocks summary) 2)
      (= (compiler_ir_types.compiler-ir-summary-instructions summary) 4))))

(define (compiler-ir-smoke-reversed-compaction-ok?) : bool
  (let
    [first-block : compiler_ir_types.CompilerIrBlock
      (compiler_ir_types.compiler-ir-block
        (compiler_ir_types.compiler-ir-label "first")
        compiler_ir_types.CompilerIrInstrList.Nil)]
    [second-block : compiler_ir_types.CompilerIrBlock
      (compiler_ir_types.compiler-ir-block
        (compiler_ir_types.compiler-ir-label "second")
        compiler_ir_types.CompilerIrInstrList.Nil)]
    [third-block : compiler_ir_types.CompilerIrBlock
      (compiler_ir_types.compiler-ir-block
        (compiler_ir_types.compiler-ir-label "third")
        compiler_ir_types.CompilerIrInstrList.Nil)]
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
      (compiler_ir_types.compiler-ir-block-list-compact-reversed compact-blocks)]
    [first-func : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "first-func")
        compiler_ir_types.CompilerIrParamList.Nil
        (ast.AstType.Unit)
        0
        compact-blocks)]
    [second-func : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "second-func")
        compiler_ir_types.CompilerIrParamList.Nil
        (ast.AstType.Unit)
        0
        compact-blocks)]
    [third-func : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.CompilerIrFunction.Function
        (compiler-ir-smoke-symbol-id "third-func")
        compiler_ir_types.CompilerIrParamList.Nil
        (ast.AstType.Unit)
        0
        compact-blocks)]
    [reversed-functions : compiler_ir_types.CompilerIrFunctionList
      (compiler_ir_types.compiler-ir-function-cons
        third-func
        (compiler_ir_types.compiler-ir-function-cons
          second-func
          (compiler_ir_types.compiler-ir-function-cons
            first-func
            compiler_ir_types.CompilerIrFunctionList.Nil)))]
    [compact-functions : compiler_ir_types.CompilerIrFunctionList
      (compiler_ir_types.compiler-ir-function-list-compact-reversed
        reversed-functions)]
    [array-reversed-functions : compiler_ir_types.CompilerIrFunctionList
      (compiler_ir_types.compiler-ir-function-list-compact-reversed
        compact-functions)]
    (and
      (= (compiler_ir_types.compiler-ir-block-list-count compact-blocks) 3)
      (compiler-ir-smoke-block-list-label-at?
        compact-blocks
        0
        (compiler_ir_types.compiler-ir-label "first"))
      (compiler-ir-smoke-block-list-label-at?
        compact-blocks
        1
        (compiler_ir_types.compiler-ir-label "second"))
      (compiler-ir-smoke-block-list-label-at?
        compact-blocks
        2
        (compiler_ir_types.compiler-ir-label "third"))
      (compiler-ir-smoke-block-list-label-at?
        array-reversed-blocks
        0
        (compiler_ir_types.compiler-ir-label "third"))
      (compiler-ir-smoke-block-list-label-at?
        array-reversed-blocks
        2
        (compiler_ir_types.compiler-ir-label "first"))
      (=
        (compiler_ir_types.compiler-ir-function-list-count compact-functions)
        3)
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
    [args : compiler_ir_types.CompilerIrSpmdCallArgList
      (compiler_ir_types.ir-spmd-call-arg-cons
        (compiler_ir_types.CompilerIrSpmdCallArg.Arg
          (compiler_ir_types.CompilerIrSpmdValueClass.Uniform)
          (compiler_ir_types.CompilerIrValue.Var 21)
          (ast.AstType.I64))
        (compiler_ir_types.ir-spmd-call-arg-cons
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg
            (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
            (compiler_ir_types.CompilerIrValue.Var 22)
            (ast.AstType.I64))
          compiler_ir_types.CompilerIrSpmdCallArgList.Nil))]
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
        instr
        span)]
    (and
      (string.eq
        (compiler_ir_types.compiler-ir-instr-render
          (ast.ast-node-pool-reader-type-segment-bases)
          instr)
        "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) : varying i64")
      (string.eq
        (compiler_ir_types.compiler-ir-instr-describe
          (ast.ast-node-pool-reader-type-segment-bases)
          instr)
        "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) -> %6 : varying i64")
      (match instr
        [(compiler_ir_types.CompilerIrInstr.SpmdCall payload-box)
          (let
            [stored-args (struct-get (box-get payload-box) args)]
            (match stored-args
              [(compiler_ir_types.CompilerIrSpmdCallArgList.Array seq)
                (= (struct-get seq len) 2)]
              [_ false]))]
        [_ false])
      (compiler_ir_types.compiler-ir-effect-is?
        instr
        compiler_ir_types.CompilerIrEffect.Unknown)
      (= (compiler_ir_types.compiler-ir-instr-call-arg-count instr) 2)
      (string.eq
        (compiler_ir_types.compiler-ir-instr-render
          (ast.ast-node-pool-reader-type-segment-bases)
          (compiler_ir_types.compiler-ir-clone-instr
            (ast.ast-node-pool-reader-context-current)
            instr))
        (compiler_ir_types.compiler-ir-instr-render
          (ast.ast-node-pool-reader-type-segment-bases)
          instr))
      (match (compiler_ir_types.compiler-source-spans-lookup-instr
        spans
        7
        instr)
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
    [instrs : compiler_ir_types.CompilerIrInstrList
      (compiler_ir_types.compiler-ir-instr-cons
        (compiler_ir_types.CompilerIrInstr.Mov
          7
          (compiler_ir_types.CompilerIrValue.I64 10)
          (ast.AstType.I64))
        (compiler_ir_types.compiler-ir-instr-cons
          (compiler_ir_types.CompilerIrInstr.BoundsCheck
            (compiler_ir_types.CompilerIrValue.Var 7)
            (compiler_ir_types.CompilerIrValue.I64 10)
            (compiler_ir_types.compiler-ir-label "ok"))
          (compiler_ir_types.compiler-ir-instr-cons
            (compiler_ir_types.CompilerIrInstr.BinOp
              8
              (compiler_ir_types.CompilerIrBinOp.Add)
              (compiler_ir_types.CompilerIrValue.Var 7)
              (compiler_ir_types.CompilerIrValue.I64 1)
              (ast.AstType.I64))
            (compiler_ir_types.compiler-ir-instr-cons
              (compiler_ir_types.CompilerIrInstr.Return
                (compiler_ir_types.CompilerIrMaybeValue.Some
                  (compiler_ir_types.CompilerIrValue.Var 8)))
              compiler_ir_types.CompilerIrInstrList.Nil))))]
    [seq : compiler_ir_types.CompilerIrInstrSeq
      (compiler_ir_types.compiler-ir-instr-seq-from-list instrs)]
    [slots : (Array compiler_ir_types.CompilerIrInstr) (struct-get seq slots)]
    (and
      (=
        (compiler_ir_types.compiler-ir-instr-loop-dst-or call-indirect (- 0 1))
        (- 0 1))
      (=
        (compiler_ir_types.compiler-ir-instr-array-loop-dst-or slots 0 (- 0 1))
        7)
      (=
        (compiler_ir_types.compiler-ir-instr-array-loop-dst-or slots 1 (- 0 1))
        (- 0 1))
      (= (compiler_ir_types.compiler-ir-instr-seq-loop-dst-or seq 0 (- 0 1)) 7)
      (=
        (compiler_ir_types.compiler-ir-instr-seq-loop-dst-or seq 1 (- 0 1))
        (- 0 1))
      (not (compiler_ir_types.compiler-ir-instr-seq-phi? seq 0))
      (not (compiler_ir_types.compiler-ir-instr-seq-return? seq 0))
      (not (compiler_ir_types.compiler-ir-instr-seq-bounds-check? seq 0))
      (compiler_ir_types.compiler-ir-instr-seq-bounds-check? seq 1)
      (compiler_ir_types.compiler-ir-instr-seq-return? seq 3)
      (match (compiler_ir_types.compiler-ir-instr-seq-ref seq 2)
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
    [bases : i64 (ast.ast-node-pool-context-type-segment-bases pools)]
    [clone : ast.AstType
      (compiler_ir_types.compiler-ir-clone-type pools borrowed)]
    [render-original : String
      (compiler_ir_types.compiler-ir-type-render bases borrowed)]
    [render-original-again : String
      (compiler_ir_types.compiler-ir-type-render bases borrowed)]
    [name-original : String
      (compiler_ir_types.compiler-ir-type-name bases borrowed)]
    [name-original-again : String
      (compiler_ir_types.compiler-ir-type-name bases borrowed)]
    [render-clone : String
      (compiler_ir_types.compiler-ir-type-render bases clone)]
    [name-clone : String (compiler_ir_types.compiler-ir-type-name bases clone)]
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
            (match (ast.ast-node-pool-context-type-get pools cloned-inner)
              [(ast.AstType.Slice cloned-elem)
                (match (ast.ast-node-pool-context-type-get pools cloned-elem)
                  [(ast.AstType.I64) true]
                  [_ false])]
              [_ false]))]
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
    (unless (compiler-ir-smoke-slice-type-render-clone-ok?) (return 8))
    (compiler_ir_types.compiler-ir-effect-self-test)))