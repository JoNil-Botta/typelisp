;; compiler_ir_types_smoke.tl - Runnable IR type/effect smoke.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.arena)
(import stdlib.string)
(import compiler_ir_types)
(import compiler_owned_view as owned_view)

(define (compiler-ir-types-smoke-instr-seq-prepend
  [instr : compiler_ir_types.CompilerIrInstr]
  [rest : compiler_ir_types.CompilerIrInstrSeq]) : compiler_ir_types.CompilerIrInstrSeq
  (let
    [builder : compiler_ir_types.CompilerIrInstrBuilder
      (compiler_ir_types.compiler-ir-instr-builder-with-capacity (+ rest.len 1))]
    (compiler_ir_types.compiler-ir-instr-builder-push! (&mut builder) instr)
    (compiler_ir_types.compiler-ir-instr-builder-append-seq-range!
      (&mut builder)
      rest
      0
      rest.len)
    (compiler_ir_types.compiler-ir-instr-builder-to-seq builder)))

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
      MemoryRead)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-stdin-eof-label
      MemoryRead)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-alloc
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-int-to-string
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-substring
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat3
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat4
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-string-concat5
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-region-reset
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-array-fill8
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-array-zero
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-mem-fill8
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-flush-stdout-label
      MemoryWrite)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-abort-label
      ControlFlow)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-oob-abort
      ControlFlow)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-div-abort
      ControlFlow)
    (compiler-ir-smoke-call-effect-id-is?
      cbi.compiler-builtin-id-tl-shift-abort
      ControlFlow)))

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
      (compiler-ir-smoke-call-effect-id-is? generated-alloc Unknown)
      (compiler-ir-smoke-call-effect-id-is? generated-abort Unknown)
      (compiler-ir-smoke-call-effect-id-is? unknown-extern Unknown))))

(define (compiler-ir-smoke-runtime-effect-reset-ok?) : bool
  (let
    [old-alloc : i64 cbi.compiler-builtin-id-tl-alloc]
    [old-stdin : i64 cbi.compiler-builtin-id-tl-stdin-eof-label]
    (ci.intern-reset!)
    (cbi.compiler-builtin-reset!)
    (ci.intern-source-slice "reset-prefix" 0 12)
    (cbi.compiler-builtin-initialize-for-parse!)
    (and
      (not (= old-alloc cbi.compiler-builtin-id-tl-alloc))
      (not (= old-stdin cbi.compiler-builtin-id-tl-stdin-eof-label))
      (compiler-ir-smoke-runtime-effect-ids-ok?)
      (compiler-ir-smoke-runtime-effect-identity-ok?))))

(define (compiler-ir-smoke-runtime-effect-self-test-ok?) : bool
  (ci.intern-reset!)
  (cbi.compiler-builtin-reset!)
  (cbi.compiler-builtin-initialize-for-parse!)
  (and
    (compiler-ir-smoke-runtime-effect-ids-ok?)
    (compiler-ir-smoke-runtime-effect-identity-ok?)
    (compiler-ir-smoke-runtime-effect-reset-ok?)))

(define (compiler-ir-smoke-function-seq-first-name?
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [want : String]) : bool
  (if (= functions.len 0)
    false
    (match (compiler_ir_types.compiler-ir-function-seq-ref functions 0)
      [(Function name _ _ _ _ _) (string.eq (ci.intern-str name) want)])))

(define (compiler-ir-smoke-function-seq-name-at?
  [functions : (& functions compiler_ir_types.CompilerIrFunctionSeq)]
  [index : i64]
  [want : String]) : bool
  (if (or (< index 0) (>= index functions.len))
    false
    (match (compiler_ir_types.compiler-ir-function-seq-ref functions index)
      [(Function name _ _ _ _ _) (string.eq (ci.intern-str name) want)])))

(define (compiler-ir-smoke-block-list-label-at?
  [blocks : (& blocks compiler_ir_types.CompilerIrBlockList)]
  [index : i64]
  [want : i64]) : bool
  (match blocks
    [(Array seq)
      (and
        (>= index 0)
        (< index (compiler_ir_types.compiler-ir-block-seq-count seq))
        (match (compiler_ir_types.compiler-ir-block-seq-ref seq index)
          [(Block label _) (= label want)]))]))

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
      [(Param name ty var)
        (and
          (string.eq name want-name)
          (= var want-var)
          (match ty
            [(I64) true]
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
      [(Param name ty var)
        (and
          (string.eq name want-name)
          (= var want-var)
          (match ty
            [(Bool) true]
            [_ false]))])))

(define (compiler-ir-smoke-dense-function-params-ok?) : bool
  (let
    [params : compiler_ir_types.CompilerIrParamSeq
      (compiler_ir_types.compiler-ir-param-seq-prepend
        (Param "value" (I64) 2)
        (compiler_ir_types.compiler-ir-param-seq-prepend
          (Param "flag" (Bool) 5)
          (compiler_ir_types.compiler-ir-param-seq-empty)))]
    [func : compiler_ir_types.CompilerIrFunction
      (Function
        (compiler-ir-smoke-symbol-id "with_params")
        params
        (Unit)
        6
        (compiler_ir_types.compiler-ir-block-list-empty)
        Ordinary)]
    [cloned : compiler_ir_types.CompilerIrFunction
      (compiler_ir_types.compiler-ir-clone-function
        (ast.ast-node-pool-reader-context-current)
        (compiler_ir_types.compiler-ir-global-shared-view func))]
    (and
      (match func
        [(Function _ stored _ _ _ _)
          (and
            (= (compiler_ir_types.compiler-ir-param-seq-count stored) 2)
            (compiler-ir-smoke-param-seq-entry-i64?
              (compiler_ir_types.compiler-ir-global-shared-view stored)
              0
              "value"
              2)
            (compiler-ir-smoke-param-seq-entry-bool? stored 1 "flag" 5))])
      (match cloned
        [(Function _ stored _ _ _ _)
          (and
            (= (compiler_ir_types.compiler-ir-param-seq-count stored) 2)
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
      [(Global name _ _) (string.eq (ci.intern-str name) want)])))

(define (compiler-ir-smoke-global-seq-two
  [first : compiler_ir_types.CompilerIrGlobal]
  [second : compiler_ir_types.CompilerIrGlobal]) : compiler_ir_types.CompilerIrGlobalSeq
  (let
    [builder : compiler_ir_types.CompilerIrGlobalBuilder
      (compiler_ir_types.compiler-ir-global-builder-with-capacity 2)]
    (compiler_ir_types.compiler-ir-global-builder-push! (&mut builder) first)
    (compiler_ir_types.compiler-ir-global-builder-push! (&mut builder) second)
    (compiler_ir_types.compiler-ir-global-builder-to-seq builder)))

(define (compiler-ir-smoke-extern-seq-name-at?
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [index : i64]
  [want : String]) : bool
  (if (or (< index 0) (>= index externs.len))
    false
    (match (compiler_ir_types.compiler-ir-extern-seq-ref externs index)
      [(Extern _ _ name _ _ _ _ _) (string.eq name want)])))

(define (compiler-ir-smoke-global-extern-seq-roundtrip-ok?) : bool
  (let
    [first-global : compiler_ir_types.CompilerIrGlobal
      (Global (compiler-ir-smoke-symbol-id "first-global") (I64) (I64 1))]
    [second-global : compiler_ir_types.CompilerIrGlobal
      (Global (compiler-ir-smoke-symbol-id "second-global") (Bool) (Bool true))]
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
        (I64))]
    [second-extern : compiler_ir_types.CompilerIrExtern
      (compiler_ir_types.compiler-ir-extern-default-id
        (compiler-ir-smoke-symbol-id "second-extern")
        "second-extern"
        (Bool))]
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
        (Program
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
        (Mov 1 (I64 10) (I64))
        (compiler-ir-types-smoke-instr-seq-prepend
          (Return (Some (Var 1)))
          (compiler_ir_types.compiler-ir-instr-seq-empty)))]
    [blocks : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-blocks
        (compiler_ir_types.CompilerIrBlock.Block
          (compiler_ir_types.compiler-ir-label "entry")
          entry-instrs))]
    [first : compiler_ir_types.CompilerIrFunction
      (Function
        (compiler-ir-smoke-symbol-id "first")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (I64)
        2
        (compiler_ir_types.compiler-ir-global-shared-view blocks)
        Ordinary)]
    [second : compiler_ir_types.CompilerIrFunction
      (Function
        (compiler-ir-smoke-symbol-id "second")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (I64)
        2
        blocks
        Ordinary)]
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
        (Program
          (compiler_ir_types.compiler-ir-global-seq-empty)
          (compiler_ir_types.compiler-ir-global-shared-view compact)
          (compiler_ir_types.compiler-ir-extern-seq-empty)))]
    (and
      (compiler-ir-smoke-function-seq-count-two? compact)
      (compiler-ir-smoke-function-seq-count-two? cloned)
      (= (compiler_ir_types.compiler-ir-function-seq-count compact) 2)
      (compiler-ir-smoke-function-seq-first-name?
        (compiler_ir_types.compiler-ir-global-shared-view compact)
        "first")
      (= (compiler_ir_types.compiler-ir-function-seq-block-count compact) 2)
      (=
        (compiler_ir_types.compiler-ir-function-seq-instruction-count compact)
        4)
      (= (compiler_ir_types.compiler-ir-summary-functions summary) 2)
      (= (compiler_ir_types.compiler-ir-summary-blocks summary) 2)
      (= (compiler_ir_types.compiler-ir-summary-instructions summary) 4))))

(define (compiler-ir-smoke-reversed-compaction-ok?) : bool
  (let
    [first-block : compiler_ir_types.CompilerIrBlock
      (Block
        (compiler_ir_types.compiler-ir-label "first")
        (compiler_ir_types.compiler-ir-instr-seq-empty))]
    [second-block : compiler_ir_types.CompilerIrBlock
      (Block
        (compiler_ir_types.compiler-ir-label "second")
        (compiler_ir_types.compiler-ir-instr-seq-empty))]
    [third-block : compiler_ir_types.CompilerIrBlock
      (Block
        (compiler_ir_types.compiler-ir-label "third")
        (compiler_ir_types.compiler-ir-instr-seq-empty))]
    [compact-blocks : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-blocks
        first-block
        second-block
        third-block)]
    [first-func : compiler_ir_types.CompilerIrFunction
      (Function
        (compiler-ir-smoke-symbol-id "first-func")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (Unit)
        0
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks)
        Ordinary)]
    [second-func : compiler_ir_types.CompilerIrFunction
      (Function
        (compiler-ir-smoke-symbol-id "second-func")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (Unit)
        0
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks)
        Ordinary)]
    [third-func : compiler_ir_types.CompilerIrFunction
      (Function
        (compiler-ir-smoke-symbol-id "third-func")
        (compiler_ir_types.compiler-ir-param-seq-empty)
        (Unit)
        0
        (compiler_ir_types.compiler-ir-global-shared-view compact-blocks)
        Ordinary)]
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
      (= (compiler_ir_types.compiler-ir-function-seq-count compact-functions) 3)
      (compiler-ir-smoke-function-seq-name-at? compact-functions 0 "first-func")
      (compiler-ir-smoke-function-seq-name-at?
        compact-functions
        1
        "second-func")
      (compiler-ir-smoke-function-seq-name-at? compact-functions 2 "third-func")
      (compiler-ir-smoke-function-seq-name-at?
        array-reversed-functions
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
    [(Var id) (Var (+ id delta))]
    [_ value]))

(define (compiler-ir-smoke-spmd-map-value
  [delta : i64]
  [class : compiler_ir_types.CompilerIrSpmdValueClass]
  [value : compiler_ir_types.CompilerIrValue]) : compiler_ir_types.CompilerIrValue
  (compiler-ir-smoke-map-value
    (+
      delta
      (match class
        [(Uniform) 0]
        [(Varying) 100]
        [(Mask) 200]))
    value))

(define (compiler-ir-smoke-value-code
  [value : (& value compiler_ir_types.CompilerIrValue)]) : i64
  (let
    [value : compiler_ir_types.CompilerIrValue
      (owned_view.compiler-owned-reference-shared-view value)]
    (match value
      [(Var id) id]
      [(I64 n) (+ 1000 n)]
      [(Bool b)
        (if b
          2001
          2000)]
      [_ (- 0 1)])))

(define (compiler-ir-smoke-record-value!
  [seen : (__tl_dyn-array i64)]
  [value : compiler_ir_types.CompilerIrValue]) : unit
  (let
    [count : i64 (array-ref seen 0)]
    (set! (array-ref seen (+ count 1)) (compiler-ir-smoke-value-code value))
    (set! (array-ref seen 0) (+ count 1))))

(define (compiler-ir-smoke-spmd-class-code
  [class : compiler_ir_types.CompilerIrSpmdValueClass]) : i64
  (match class
    [(Uniform) 10000]
    [(Varying) 20000]
    [(Mask) 30000]))

(define (compiler-ir-smoke-record-spmd-value!
  [seen : (__tl_dyn-array i64)]
  [class : compiler_ir_types.CompilerIrSpmdValueClass]
  [value : compiler_ir_types.CompilerIrValue]) : unit
  (let
    [count : i64 (array-ref seen 0)]
    (set!
      (array-ref seen (+ count 1))
      (+
        (compiler-ir-smoke-spmd-class-code class)
        (compiler-ir-smoke-value-code value)))
    (set! (array-ref seen 0) (+ count 1))))

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
        (compiler_ir_types.CompilerIrCallArgs.One (Var 1))
        compiler-ir-smoke-map-value
        10)]
    [two-mapped : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.compiler-ir-call-args-map
        (compiler_ir_types.CompilerIrCallArgs.Two (I64 7) (Var 2))
        compiler-ir-smoke-map-value
        10)]
    [many : compiler_ir_types.CompilerIrCallArgs
      (Array (compiler_ir_types.compiler-ir-global-shared-view many-values))]
    [many-mapped : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.compiler-ir-call-args-map
        (compiler_ir_types.compiler-ir-global-shared-view many)
        compiler-ir-smoke-map-value
        10)]
    [sret : compiler_ir_types.CompilerIrCallArgs (Sret many-values 2)]
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
          (compiler_ir_types.CompilerIrCallArgs.One (Var 1))
          compiler-ir-smoke-record-value!
          (compiler_ir_types.compiler-ir-global-shared-view seen))
        (compiler_ir_types.compiler-ir-call-args-visit
          (compiler_ir_types.CompilerIrCallArgs.Two (Var 2) (I64 7))
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
        [(Nil) true]
        [_ false])
      (match one-mapped
        [(One (Var id)) (= id 11)]
        [_ false])
      (match two-mapped
        [(Two (I64 literal) (Var id)) (and (= literal 7) (= id 12))]
        [_ false])
      (match many-mapped
        [(Array values)
          (and
            (= (array-length values) 4)
            (= (compiler-ir-smoke-value-code (array-ref values 0)) 13)
            (= (compiler-ir-smoke-value-code (array-ref values 1)) 1009)
            (= (compiler-ir-smoke-value-code (array-ref values 2)) 14)
            (= (compiler-ir-smoke-value-code (array-ref values 3)) 2001))]
        [_ false])
      (match sret-mapped
        [(Sret values index)
          (and
            (= index 2)
            (= (array-length values) 4)
            (= (compiler-ir-smoke-value-code (array-ref values 0)) 13)
            (= (compiler-ir-smoke-value-code (array-ref values 1)) 1009)
            (= (compiler-ir-smoke-value-code (array-ref values 2)) 14)
            (= (compiler-ir-smoke-value-code (array-ref values 3)) 2001))]
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
      (= (compiler-ir-smoke-value-code (array-ref mapped.slots 0)) 15)
      (= (compiler-ir-smoke-value-code (array-ref mapped.slots 1)) 1011)
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
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg Uniform (Var 1) (I64)))
        (set!
          (array-ref slots 1)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg Varying (Var 2) (Bool)))
        (set!
          (array-ref slots 2)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg Mask (Var 3) (Char)))
        (set!
          (array-ref slots 3)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg Mask (I64 7) (String)))
        (set!
          (array-ref slots 4)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg Uniform (Var 99) (Unit)))
        (set!
          (array-ref slots 5)
          (compiler_ir_types.CompilerIrSpmdCallArg.Arg Uniform (Var 100) (Unit))))]
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
        [(Arg (Uniform) (Var id) (I64)) (= id 11)]
        [_ false])
      (match (compiler_ir_types.compiler-ir-array-shared-view mapped.slots 1)
        [(Arg (Varying) (Var id) (Bool)) (= id 112)]
        [_ false])
      (match (compiler_ir_types.compiler-ir-array-shared-view mapped.slots 2)
        [(Arg (Mask) (Var id) (Char)) (= id 213)]
        [_ false])
      (match (compiler_ir_types.compiler-ir-array-shared-view mapped.slots 3)
        [(Arg (Mask) (I64 literal) (String)) (= literal 7)]
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
    (compiler_ir_types.compiler-ir-spmd-call-arg-builder-push!
      (&mut builder)
      (compiler_ir_types.CompilerIrSpmdCallArg.Arg (Uniform) (Var 21) (I64)))
    (compiler_ir_types.compiler-ir-spmd-call-arg-builder-push!
      (&mut builder)
      (compiler_ir_types.CompilerIrSpmdCallArg.Arg (Varying) (Var 22) (I64)))
    (compiler_ir_types.compiler-ir-spmd-call-arg-builder-to-seq builder)))

(define (compiler-ir-smoke-spmd-call-shape-ok?) : bool
  (let
    [args : compiler_ir_types.CompilerIrSpmdCallArgSeq
      (compiler-ir-smoke-spmd-call-args)]
    [instr : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.compiler-ir-test-spmd-private-call
        (compiler-ir-smoke-symbol-id "helper")
        (Avx2)
        8
        (Var 20)
        args
        (Value 6 (Varying) (I64)))]
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
      (= (compiler_ir_types.compiler-ir-instr-dst instr) 6)
      (match (compiler_ir_types.compiler-ir-global-shared-view instr)
        [(SpmdCall payload-box)
          (let
            [stored-args
              (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                args)]
            (and (= stored-args.len 2) (= (array-length stored-args.slots) 2)))]
        [_ false])
      (compiler-ir-effect-is?
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        Unknown)
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
        [(Some found)
          (and
            (= (ast.ast-source-span-start-line found) 3)
            (= (ast.ast-source-span-end-col found) 9))]
        [(No) false]))))

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
        Avx512
        8
        (Var 20)
        args
        (Value 6 Varying (I64))
        (Imported (box selected)))]
    [cloned : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.compiler-ir-clone-instr
        (ast.ast-node-pool-reader-context-current)
        (compiler_ir_types.compiler-ir-global-shared-view call))]
    (and
      (match call
        [(SpmdCall payload-box)
          (string.eq
            (compiler_ir_types.compiler-ir-spmd-call-descriptor-error
              (deref payload-box))
            "")]
        [_ false])
      (match cloned
        [(SpmdCall payload-box)
          (match (compiler_ir_types.compiler-ir-box-field-shared-view
            payload-box
            origin)
            [(Imported origin-box)
              (let
                [origin : compiler_ir_types.CompilerIrImportedSpmdCall
                  (deref origin-box)]
                (and
                  (string.eq origin.package-owner "fixture")
                  (string.eq origin.package-version "1.0.0")
                  (string.eq origin.link-symbol "_tl_helper")))]
            [(Private _) false])]
        [_ false])
      (>
        (string.string-length
          (compiler_ir_types.compiler-ir-spmd-call-descriptor-error
            (compiler_ir_types.CompilerIrInstrSpmdCallPayload
              callee
              Scalar
              8
              (Var 20)
              (compiler-ir-smoke-spmd-call-args)
              (Value 6 Varying (I64))
              (Imported
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
          Avx512
          8
          (Var 20)
          (compiler-ir-smoke-spmd-call-args)
          (Value 6 Varying (I64))
          (Imported
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
        Avx512
        8
        (Var 20)
        (compiler-ir-smoke-spmd-call-args)
        (Value 6 Varying (I64))
        (Imported
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
      (StoreOwned (Var 4) (Var 3) (String))]
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
        MemoryWrite)
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
      (CallIndirect 9 (Var 1) Nil (I64))]
    [instrs : compiler_ir_types.CompilerIrInstrSeq
      (compiler-ir-types-smoke-instr-seq-prepend
        (Mov 7 (I64 10) (I64))
        (compiler-ir-types-smoke-instr-seq-prepend
          (BoundsCheck
            (Var 7)
            (I64 10)
            (compiler_ir_types.compiler-ir-label "ok"))
          (compiler-ir-types-smoke-instr-seq-prepend
            (BinOp 8 (Add) (Var 7) (I64 1) (I64))
            (compiler-ir-types-smoke-instr-seq-prepend
              (Return (Some (Var 8)))
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
      (not (compiler_ir_types.compiler-ir-instr-seq-phi? seq 0))
      (not
        (compiler-ir-instr-seq-return?
          (compiler_ir_types.compiler-ir-global-shared-view seq)
          0))
      (not (compiler_ir_types.compiler-ir-instr-seq-bounds-check? seq 0))
      (compiler_ir_types.compiler-ir-instr-seq-bounds-check? seq 1)
      (compiler-ir-instr-seq-return?
        (compiler_ir_types.compiler-ir-global-shared-view seq)
        3)
      (match (compiler_ir_types.compiler-ir-instr-seq-ref
        (compiler_ir_types.compiler-ir-global-shared-view seq)
        2)
        [(BinOp dst _ (Var lhs) _ _) (and (= dst 8) (= lhs 7))]
        [_ false]))))

(define (compiler-ir-smoke-slice-type-render-clone-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [lifetime : i64 (ci.intern "ir-slice")]
    [slice : ast.AstType (ast.ast-ty-slice-with-pools pools I64)]
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
        [(Ref cloned-lifetime cloned-inner)
          (and
            (= cloned-lifetime lifetime)
            (match (ast.ast-node-pool-context-type-get (& pools) cloned-inner)
              [(Slice cloned-elem)
                (match (ast.ast-node-pool-context-type-get
                  (& pools)
                  cloned-elem)
                  [(I64) true]
                  [_ false])]
              [_ false]))]
        [_ false]))))

(define (compiler-ir-smoke-type-variable-render-ok?
  [pools : ast.AstNodePoolContext]
  [session : cis.InternStructuralSessionHandle]
  [name : i64]
  [expected : String]) : bool
  (let
    [plain : ast.AstType (Var name)]
    [life : i64 (ci.intern "type-variable-life")]
    [args : ast.AstType
      (ast.ast-ty-var-args
        name
        (ast.ast-lifetime-cons life (ast.ast-lifetime-list-new)))]
    [nested : ast.AstType
      (ast.ast-ty-slice-with-pools
        pools
        (ast.ast-ty-ptr-with-pools pools (ast.ast-global-shared-view plain)))]
    [bases : i64 (ast.ast-node-pool-context-type-segment-bases pools)]
    (and
      (string.eq
        (compiler_ir_types.compiler-ir-type-render session bases plain)
        expected)
      (string.eq
        (compiler_ir_types.compiler-ir-type-render session bases args)
        (str_cat.str-cat "(" (string.copy (& expected)) " type-variable-life)"))
      (string.eq
        (compiler_ir_types.compiler-ir-type-render session bases nested)
        (str_cat.str-cat "(Slice (Ptr " (string.copy (& expected)) "))")))))

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
    [invalid-global : i64
      (cis.intern-macro-global-identity-raw
        (cis.intern-structural-session-macro-global-identity
          session
          Context
          module-id
          (ci.intern-capacity)))]
    [invalid-local : i64
      (cis.intern-macro-local-identity-raw
        (cis.intern-structural-session-macro-local-identity
          session
          definition
          9
          (ci.intern-capacity)))]
    [borrowed : ast.AstType (ast.ast-ty-ref-with-pools pools lifetime I64)]
    [arithmetic-borrowed : ast.AstType
      (ast.ast-ty-ref-with-pools
        pools
        (cis.intern-fresh-local-identity-raw
          (cis.intern-structural-session-fresh-local-identity session 8 source))
        I64)]
    [other-intern : ci.InternCompatState (ci.intern-compat-state-new)]
    [other-session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state (& other-intern)))]
    [invalid : ast.AstType
      (ast.ast-ty-ref-with-pools pools (ci.intern-capacity) I64)]
    [bases : i64 (ast.ast-node-pool-context-type-segment-bases (& pools))]
    (and
      (compiler-ir-smoke-type-variable-render-ok?
        pools
        session
        invalid-global
        (str_cat.str-cat "<id:" (string.int->string invalid-global) ">"))
      (compiler-ir-smoke-type-variable-render-ok?
        pools
        session
        invalid-local
        (str_cat.str-cat "<id:" (string.int->string invalid-local) ">"))
      (compiler-ir-smoke-type-variable-render-ok?
        pools
        session
        source
        "macro-local-life")
      (compiler-ir-smoke-type-variable-render-ok?
        pools
        session
        lifetime
        "macro-local-life")
      (compiler-ir-smoke-type-variable-render-ok?
        pools
        session
        (cis.intern-fresh-local-identity-raw
          (cis.intern-structural-session-fresh-local-identity session 8 source))
        "macro-local-life")
      (compiler-ir-smoke-type-variable-render-ok?
        pools
        other-session
        lifetime
        (str_cat.str-cat "<id:" (string.int->string lifetime) ">"))
      (compiler-ir-smoke-type-variable-render-ok?
        pools
        session
        (ci.intern-capacity)
        (str_cat.str-cat "<id:" (string.int->string (ci.intern-capacity)) ">"))
      (compiler-ir-smoke-type-variable-render-ok? pools session -1 "<id:-1>")
      (string.eq
        (compiler_ir_types.compiler-ir-type-name bases (Var source))
        "'macro-local-life'")
      (string.eq
        (compiler_ir_types.compiler-ir-type-name bases (Var lifetime))
        (str_cat.str-cat "'<id:" (string.int->string lifetime) ">'"))
      (string.eq
        (compiler_ir_types.compiler-ir-type-name bases (Var -1))
        "'<id:-1>'")
      (string.eq
        (compiler_ir_types.compiler-ir-type-name
          bases
          (ast.ast-ty-var-args lifetime (ast.ast-lifetime-list-new)))
        (str_cat.str-cat "(<id:" (string.int->string lifetime) "> )"))
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

;; The derived-symbol table exists because the fixed intern pool cannot hold
;; the generated ids of a whole-program self-compile (refs #6293), so what has
;; to hold is: one id per spelling and that spelling back unchanged, growth past
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
    ;; An existing canonical generated name remains a pooled identity and
    ;; does not consume an IR-owned slot.
    (unless (= canonical-symbol canonical-id) (set! ok false))
    ;; Equal spellings are one id; distinct spellings are distinct ids.
    (unless (= first first-again) (set! ok false))
    (unless (not (= first second)) (set! ok false))
    (unless
      (= (compiler_ir_types.compiler-ir-symbol-count-value) (+ count-before 2))
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
    (unless (= (compiler-ir-symbol-slot first) (- first base)) (set! ok false))
    (unless (compiler_ir_types.compiler-ir-symbol-owned? first) (set! ok false))
    (unless
      (compiler_ir_types.compiler-ir-symbol-domain? first)
      (set! ok false))
    (unless (not (ci.intern-renderable-id? first)) (set! ok false))
    ;; More than today's `intern-capacity` source handles -- including the old
    ;; 4*capacity collision point -- all fail ownership and slot decoding.
    ;; This deliberately uses raw u32-domain handles because today's fixed
    ;; pool cannot allocate the future values the namespace must reserve.
    (while (<= logical-source-handle capacity)
      (if (compiler_ir_types.compiler-ir-symbol-owned? logical-source-handle)
        (set! ok false)
        unit)
      (unless
        (= (compiler-ir-symbol-slot logical-source-handle) -1)
        (set! ok false))
      (set! logical-source-handle (+ logical-source-handle 1)))
    (unless (< old-collision-base compact-limit) (set! ok false))
    (unless
      (not (compiler_ir_types.compiler-ir-symbol-owned? old-collision-base))
      (set! ok false))
    (unless (= (compiler-ir-symbol-slot old-collision-base) -1) (set! ok false))
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
        (unless
          (compiler_ir_types.compiler-ir-symbol-domain? unallocated)
          (set! ok false))
        (if (compiler_ir_types.compiler-ir-symbol-owned? unallocated)
          (set! ok false)
          unit)
        (unless (= (compiler-ir-symbol-slot unallocated) -1) (set! ok false))
        (unless
          (string.eq (compiler_ir_types.compiler-ir-symbol-text unallocated) "")
          (set! ok false))
        (set! index (+ index 1))))
    ;; Adjacent identity domains, the compact-u32 limit, and sentinels also
    ;; fail closed rather than indexing or reaching intern-str.
    (unless
      (= (compiler-ir-symbol-slot (- compact-limit 1)) -1)
      (set! ok false))
    (unless (= (compiler-ir-symbol-slot cfg-base) -1) (set! ok false))
    (unless (= (compiler-ir-symbol-slot current-cfg-key) -1) (set! ok false))
    (unless (= (compiler-ir-symbol-slot structural-base) -1) (set! ok false))
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
      (string.eq (compiler_ir_types.compiler-ir-symbol-text structural-base) "")
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
      (set!
        last-grown
        (compiler_ir_types.compiler-ir-symbol
          (str_cat.str-cat "ir-smoke/grow-" (string.int->string index))))
      (set! index (+ index 1)))
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
    ok))

;; Arenas destroyed from here on are poisoned, so a read of a retired label
;; generation traps instead of passing silently.
(extern (tl_arena_poison_enable) : unit)

(define (compiler-ir-smoke-label-spelling [index : i64]) : String
  (str_cat.str-cat "ir-smoke-label-" (string.int->string index)))

;; The label table across at least three generation boundaries (#8409): ids stay
;; dense and in creation order, every spelling and every text view taken before
;; a growth survive the retired generations, re-interning returns the same id,
;; and `compiler-ir-label-existing` answers without creating an id.
(define (compiler-ir-smoke-label-table-growth-ok?) : bool
  (let
    [first : i64
      (compiler_ir_types.compiler-ir-label (compiler-ir-smoke-label-spelling 0))]
    [first-text : String (compiler_ir_types.compiler-ir-label-text first)]
    [base : i64 (- (compiler_ir_types.compiler-ir-label-count-value) 1)]
    [total : i64 5000]
    [index : i64 1]
    [ok : bool true]
    [past-end : String ""]
    (tl_arena_poison_enable)
    (while (< index total)
      (unless
        (=
          (compiler_ir_types.compiler-ir-label
            (compiler-ir-smoke-label-spelling index))
          (+ base index))
        (set! ok false))
      (set! index (+ index 1)))
    (unless (string.eq (& first-text) "ir-smoke-label-0") (set! ok false))
    (set! index 0)
    (while (< index total)
      (let
        [spelling : String (compiler-ir-smoke-label-spelling index)]
        [text : String
          (compiler_ir_types.compiler-ir-label-text (+ base index))]
        (unless (string.eq (& text) (& spelling)) (set! ok false))
        (unless
          (=
            (compiler_ir_types.compiler-ir-label-existing spelling)
            (+ base index))
          (set! ok false))
        (set! index (+ index 1))))
    (and
      ok
      (= (compiler_ir_types.compiler-ir-label-count-value) (+ base total))
      ;; Re-interning an existing spelling returns its id and adds nothing.
      (=
        (compiler_ir_types.compiler-ir-label
          (compiler-ir-smoke-label-spelling 4321))
        (+ base 4321))
      (=
        (compiler_ir_types.compiler-ir-label-existing
          "ir-smoke-label-never-created")
        -1)
      (= (compiler_ir_types.compiler-ir-label-count-value) (+ base total))
      (begin
        (set!
          past-end
          (compiler_ir_types.compiler-ir-label-text (+ base total)))
        (string.eq (& past-end) "")))))

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
    [instr-key : compiler_ir_types.CompilerSourceSpansInstrKey (Value first 12)]
    [store-key : compiler_ir_types.CompilerSourceSpansInstrKey
      (Store second 14)]
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
        [(Some (compiler_ir_types.CompilerSourceLocation path-id span))
          (and
            (= path-id 3)
            (= (ast.ast-source-span-start-line span) 10)
            (= (ast.ast-source-span-end-col span) 40))]
        [_ false])
      (match (compiler_ir_types.compiler-source-spans-lookup-location
        (compiler_ir_types.compiler-ir-global-shared-view escaped)
        second)
        [(Some (compiler_ir_types.CompilerSourceLocation path-id span))
          (and (= path-id 4) (= (ast.ast-source-span-start-line span) 50))]
        [_ false])
      (match escaped
        [(Spans _ instr-entries _)
          (and
            (match (compiler_ir_types.compiler-source-spans-instr-entry-list-lookup
              (compiler_ir_types.compiler-ir-global-shared-view instr-entries)
              instr-key)
              [(Some (compiler_ir_types.CompilerSourceLocation path-id span))
                (and
                  (= path-id 5)
                  (= (ast.ast-source-span-start-line span) 90)
                  (= (ast.ast-source-span-end-col span) 120))]
              [_ false])
            (match (compiler_ir_types.compiler-source-spans-instr-entry-list-lookup
              instr-entries
              store-key)
              [(Some (compiler_ir_types.CompilerSourceLocation path-id span))
                (and
                  (= path-id 6)
                  (= (ast.ast-source-span-start-line span) 130))]
              [_ false]))]))))

(define (compiler-ir-smoke-representation-kind-group?
  [kind : compiler_ir_types.CompilerIrRepresentationKind]
  [count : i64]
  [mask : i64]) : bool
  (match kind
    [(RegisterGroup found-count found-mask)
      (and (= found-count count) (= found-mask mask))]
    [_ false]))

(define (compiler-ir-smoke-representation-kind-one?
  [kind : compiler_ir_types.CompilerIrRepresentationKind]) : bool
  (match kind
    [(KnownOneWord) true]
    [_ false]))

(define (compiler-ir-smoke-representation-kind-unknown?
  [kind : compiler_ir_types.CompilerIrRepresentationKind]) : bool
  (match kind
    [(Unknown) true]
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
    [group-ty : ast.AstType (Struct group-name)]
    [one-ty : ast.AstType (Enum one-name)]
    [conflict-ty : ast.AstType (Struct conflict-name)]
    [signature-ty : ast.AstType (Struct signature-name)]
    [private-ty : ast.AstType (Struct private-name)]
    [malformed-ty : ast.AstType (Struct malformed-name)]
    [group-id : i64
      (ast.ast-node-pool-context-type-push
        (ast.ast-node-pool-context-shared-view (& pools))
        (ast.ast-global-shared-view group-ty))]
    [region-ty : ast.AstType (Region 77 group-id)]
    [words-gp-sse : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.compiler-ir-value-seq-prepend
        (I64 1)
        (compiler_ir_types.compiler-ir-value-seq-prepend
          (F64 0)
          (compiler_ir_types.compiler-ir-value-seq-empty)))]
    [words-gp-gp : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.compiler-ir-value-seq-prepend
        (I64 1)
        (compiler_ir_types.compiler-ir-value-seq-prepend
          (I64 2)
          (compiler_ir_types.compiler-ir-value-seq-empty)))]
    [words-sse-gp : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.compiler-ir-value-seq-prepend
        (F64 0)
        (compiler_ir_types.compiler-ir-value-seq-prepend
          (I64 2)
          (compiler_ir_types.compiler-ir-value-seq-empty)))]
    [instrs : compiler_ir_types.CompilerIrInstrSeq
      (compiler-ir-types-smoke-instr-seq-prepend
        (Pack 1 words-gp-sse (ast.ast-global-shared-view group-ty))
        (compiler-ir-types-smoke-instr-seq-prepend
          (Mov 2 (I64 0) (ast.ast-global-shared-view one-ty))
          (compiler-ir-types-smoke-instr-seq-prepend
            (Pack 3 words-gp-gp (ast.ast-global-shared-view conflict-ty))
            (compiler-ir-types-smoke-instr-seq-prepend
              (Pack 4 words-sse-gp (ast.ast-global-shared-view conflict-ty))
              (compiler-ir-types-smoke-instr-seq-prepend
                (Mov 5 (I64 0) (ast.ast-global-shared-view private-ty))
                (compiler-ir-types-smoke-instr-seq-prepend
                  (Mov 6 (I64 0) (ast.ast-global-shared-view malformed-ty))
                  (compiler-ir-types-smoke-instr-seq-prepend
                    (compiler_ir_types.ir-instr-descriptor-pair-pack
                      7
                      (I64 0)
                      (I64 0)
                      (OwnedString))
                    (compiler_ir_types.compiler-ir-instr-seq-empty))))))))]
    [params : compiler_ir_types.CompilerIrParamSeq
      (compiler_ir_types.compiler-ir-param-seq-prepend
        (Param "group" (ast.ast-global-shared-view signature-ty) 0)
        (compiler_ir_types.compiler-ir-param-seq-empty))]
    [program : compiler_ir_types.CompilerIrProgram
      (Program
        (compiler_ir_types.compiler-ir-global-seq-empty)
        (compiler_ir_types.compiler-ir-function-seq-prepend
          (Function
            (ci.intern "representation_index")
            params
            (ast.ast-global-shared-view one-ty)
            8
            (compiler_ir_types.compiler-ir-blocks
              (compiler_ir_types.CompilerIrBlock.Block
                (compiler_ir_types.compiler-ir-label "entry")
                instrs))
            Ordinary)
          (compiler_ir_types.compiler-ir-function-seq-empty))
        (compiler_ir_types.compiler-ir-extern-seq-empty))]
    [bases : i64 (ast.ast-node-pool-context-type-segment-bases pools)]
    [index : compiler_ir_types.CompilerIrRepresentationIndex
      (compiler_ir_types.compiler-ir-representation-index-build bases program)]
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
          (Var 99)))
      (return 8))
    (unless
      (compiler-ir-smoke-representation-kind-unknown?
        (compiler_ir_types.compiler-ir-representation-index-kind
          bases
          index
          (String)))
      (return 9))
    0))

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
  (Param ordinal role ty))

(define (pabi-source
  [source : i64]
  [class : compiler_ir_types.CompilerIrSpmdValueClass]
  [ty : ast.AstType]) : compiler_ir_types.CompilerIrSpmdPrivateParamRole
  (Source source class ty))

;; Parameter `index` of parameter layout `variant`. Variant 0 is the base
;; layout; 10 drops the index base; the others each break one rule.
(define (pabi-param-at [variant : i64] [index : i64]) : compiler_ir_types.CompilerIrSpmdPrivateParam
  (cond
    [(= index 0)
      (cond
        [(= variant 3) (pabi-param 0 (pabi-source 0 (Varying) (I64)) (I64))]
        [(= variant 4) (pabi-param 0 (ActiveMask) (I64))]
        [else (pabi-param 0 (ActiveMask) (Bool))])]
    [(= index 1)
      (cond
        [(= variant 2) (pabi-param 1 (pabi-source 1 (Varying) (I64)) (I64))]
        [(= variant 5) (pabi-param 1 (IndexBase) (I64))]
        [(= variant 8) (pabi-param 1 (pabi-source 0 (Varying) (Bool)) (Bool))]
        [(= variant 9) (pabi-param 1 (ActiveMask) (Bool))]
        [else (pabi-param 1 (pabi-source 0 (Varying) (I64)) (I64))])]
    [(= index 2)
      (cond
        [(= variant 1) (pabi-param 5 (pabi-source 1 (Uniform) (I64)) (I64))]
        [(= variant 2) (pabi-param 2 (pabi-source 0 (Uniform) (I64)) (I64))]
        [(= variant 7) (pabi-param 2 (pabi-source 1 (Mask) (I64)) (I64))]
        [(= variant 11) (pabi-param 2 (pabi-source 1 (Uniform) (I64)) (U64))]
        [else (pabi-param 2 (pabi-source 1 (Uniform) (I64)) (I64))])]
    [else
      (pabi-param
        3
        (IndexBase)
        (if (= variant 6)
          (I32)
          (I64)))]))

(define (pabi-params [variant : i64]) : compiler_ir_types.CompilerIrSpmdPrivateParamSeq
  (let
    [count : i64
      (if (= variant 10)
        3
        4)]
    [params : compiler_ir_types.CompilerIrSpmdPrivateParamSeq
      (compiler_ir_types.compiler-ir-spmd-private-param-seq-with-capacity count)]
    [index : i64 0]
    (while (< index count)
      (compiler_ir_types.compiler-ir-spmd-private-param-seq-push!
        (&mut params)
        (pabi-param-at variant index))
      (set! index (+ index 1)))
    params))

(define (pabi-result-varying-i64) : compiler_ir_types.CompilerIrSpmdPrivateResult
  (Value (Varying) (I64)))

(define (pabi
  [callee : String]
  [backend : compiler_ir_types.CompilerIrSpmdBackend]
  [lanes : i64]
  [variant : i64]
  [index : compiler_ir_types.CompilerIrSpmdPrivateIndex]
  [result : compiler_ir_types.CompilerIrSpmdPrivateResult]) : compiler_ir_types.CompilerIrSpmdPrivateAbi
  (compiler_ir_types.CompilerIrSpmdPrivateAbi
    (V1)
    (pabi-sym callee)
    backend
    lanes
    (pabi-params variant)
    index
    result))

(define (pabi-base) : compiler_ir_types.CompilerIrSpmdPrivateAbi
  (pabi "helper" (Avx512) 8 0 (Appended 3) (pabi-result-varying-i64)))

(define (pabi-with-params [variant : i64]) : compiler_ir_types.CompilerIrSpmdPrivateAbi
  (pabi "helper" (Avx512) 8 variant (Appended 3) (pabi-result-varying-i64)))

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
    (compiler_ir_types.compiler-ir-param-builder-push!
      (&mut builder)
      (compiler_ir_types.CompilerIrParam.Param "mask" (Bool) 0))
    (compiler_ir_types.compiler-ir-param-builder-push!
      (&mut builder)
      (compiler_ir_types.CompilerIrParam.Param "x" (I64) 1))
    (compiler_ir_types.compiler-ir-param-builder-push!
      (&mut builder)
      (compiler_ir_types.CompilerIrParam.Param
        "k"
        (if (= variant 2)
          (I32)
          (I64))
        2))
    (if (= variant 1)
      unit
      (compiler_ir_types.compiler-ir-param-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrParam.Param "base" (I64) 3)))
    (compiler_ir_types.compiler-ir-param-builder-to-seq builder)))

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
    (compiler_ir_types.compiler-ir-spmd-call-arg-builder-push!
      (&mut builder)
      (compiler_ir_types.CompilerIrSpmdCallArg.Arg
        (if (or (= variant 2) (= variant 4))
          (Uniform)
          (Varying))
        (Var 21)
        (if (= variant 3)
          (I32)
          (I64))))
    (compiler_ir_types.compiler-ir-spmd-call-arg-builder-push!
      (&mut builder)
      (compiler_ir_types.CompilerIrSpmdCallArg.Arg
        (if (= variant 4)
          (Varying)
          (Uniform))
        (Var 22)
        (I64)))
    (if (= variant 1)
      unit
      (compiler_ir_types.compiler-ir-spmd-call-arg-builder-push!
        (&mut builder)
        (compiler_ir_types.CompilerIrSpmdCallArg.Arg
          (if (= variant 5)
            (Varying)
            (Uniform))
          (Var 23)
          (I64))))
    (compiler_ir_types.compiler-ir-spmd-call-arg-builder-to-seq builder)))

(define (pabi-call-result [variant : i64]) : compiler_ir_types.CompilerIrSpmdCallResult
  (cond
    [(= variant 1) (Unit)]
    [(= variant 2) (Value 6 (Uniform) (I64))]
    [(= variant 3) (Value 6 (Varying) (I32))]
    [else (Value 6 (Varying) (I64))]))

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
    (Avx512)
    8
    (Var 20)
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
  (Function
    (pabi-sym name)
    (pabi-signature-params 0)
    (I64)
    4
    (compiler_ir_types.compiler-ir-blocks
      (compiler_ir_types.CompilerIrBlock.Block
        (compiler_ir_types.compiler-ir-label "entry")
        (compiler_ir_types.compiler-ir-instr-seq1 (Return (Some (Var 1))))))
    function-abi))

(define (pabi-caller-function
  [payload : compiler_ir_types.CompilerIrInstrSpmdCallPayload]) : compiler_ir_types.CompilerIrFunction
  (Function
    (pabi-sym "caller")
    (compiler_ir_types.compiler-ir-param-seq-empty)
    (Unit)
    30
    (compiler_ir_types.compiler-ir-blocks
      (compiler_ir_types.CompilerIrBlock.Block
        (compiler_ir_types.compiler-ir-label "entry")
        (compiler_ir_types.compiler-ir-instr-seq2
          (SpmdCall (box payload))
          (Return No))))
    Ordinary))

(define (pabi-program-error
  [helper : compiler_ir_types.CompilerIrFunction]
  [payload : compiler_ir_types.CompilerIrInstrSpmdCallPayload]) : String
  (let
    [builder : compiler_ir_types.CompilerIrFunctionBuilder
      (compiler_ir_types.compiler-ir-function-builder-new)]
    (compiler_ir_types.compiler-ir-function-builder-push!
      (&mut builder)
      (pabi-caller-function payload))
    (compiler_ir_types.compiler-ir-function-builder-push! (&mut builder) helper)
    (let
      [functions : compiler_ir_types.CompilerIrFunctionSeq
        (compiler_ir_types.compiler-ir-function-builder-to-seq builder)]
      (compiler_ir_types.compiler-ir-spmd-private-abi-program-error functions))))

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
  (match (compiler-ir-function-abi func)
    [(SpmdPrivate private-box) (deref private-box)]
    [(Ordinary) (pabi "ordinary" (Scalar) 1 10 (None) (Unit))]))

;; 0 when every case holds, else the number of the first failing case.
(define (compiler-ir-smoke-spmd-private-abi-failure) : i64
  (let
    [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-reader-context-current)]
    [i64-ty : ast.AstType (I64)]
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
            (pabi "helper" (Scalar) 8 10 (None) (pabi-result-varying-i64))
            "scalar descriptor has 8 lanes"))
        6]
      [(not
          (pabi-shape-rejects?
            (pabi "helper" (Avx512) 6 0 (Appended 3) (pabi-result-varying-i64))
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
            (pabi "helper" (Avx512) 8 0 (None) (pabi-result-varying-i64))
            "without an appended index mapping"))
        17]
      [(not
          (pabi-shape-rejects?
            (pabi "helper" (Avx512) 8 10 (Appended 2) (pabi-result-varying-i64))
            "appended index mapping without an index base parameter"))
        18]
      [(not
          (pabi-shape-rejects?
            (pabi "helper" (Avx512) 8 0 (Appended 2) (pabi-result-varying-i64))
            "not the last"))
        19]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (Avx512)
              8
              10
              (ReuseSource 1)
              (pabi-result-varying-i64))
            "reused index source parameter 1 is not varying"))
        20]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (Avx512)
              8
              10
              (ReuseSource 2)
              (pabi-result-varying-i64))
            "reused index source parameter 2 is out of range"))
        21]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (Avx512)
              8
              0
              (ReuseSource 0)
              (pabi-result-varying-i64))
            "index base parameter with a reused source index"))
        22]
      [(not
          (pabi-shape-rejects?
            (pabi
              "helper"
              (Scalar)
              1
              10
              (ReuseSource 0)
              (pabi-result-varying-i64))
            "scalar descriptor maps a logical index"))
        23]
      [(not
          (pabi-shape-rejects?
            (pabi "helper" (Avx512) 8 0 (Appended 3) (Value (Mask) (I64)))
            "mask result is not bool"))
        24]
      [(not
          (pabi-shape-rejects?
            (pabi "helper" (Avx512) 8 0 (Appended 3) (Value (Varying) (Bool)))
            "varying result is bool"))
        25]
      [(not
          (pabi-shape-rejects?
            (pabi "helper" (Avx512) 8 0 (Appended 3) (Value (Uniform) (Unit)))
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
            (I32)
            (pabi-base)
            "result type differs from the signature"))
        30]
      [(not
          (pabi-signature-rejects?
            "helper"
            0
            (clone i64-ty)
            (pabi "helper" (Avx512) 8 0 (Appended 3) (Unit))
            "unit result but the signature returns a value"))
        31]
      ;; Call side: the payload against the descriptor it carries.
      [(not
          (pabi-call-rejects?
            (pabi-call-payload
              "other"
              (Avx512)
              8
              (Var 20)
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
              (Avx2)
              8
              (Var 20)
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
              (Avx512)
              16
              (Var 20)
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
              (Avx512)
              8
              (I64 1)
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
            (pabi "helper" (Avx512) 8 0 (Appended 3) (Unit))
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
            (pabi-helper-function "helper" Ordinary)
            (pabi-base-payload 0 0)
            "in @caller: private SPMD call to @helper: the callee has the ordinary ABI"))
        46]
      [(not
          (pabi-program-rejects?
            (pabi-helper-function "elsewhere" Ordinary)
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
            (Function
              (pabi-sym "helper")
              (let
                [builder : compiler_ir_types.CompilerIrParamBuilder
                  (compiler_ir_types.compiler-ir-param-builder-with-capacity 4)]
                (compiler_ir_types.compiler-ir-param-builder-push!
                  (&mut builder)
                  (compiler_ir_types.CompilerIrParam.Param "mask" (Bool) 0))
                (compiler_ir_types.compiler-ir-param-builder-push!
                  (&mut builder)
                  (compiler_ir_types.CompilerIrParam.Param "x" (I64) 1))
                (compiler_ir_types.compiler-ir-param-builder-push!
                  (&mut builder)
                  (compiler_ir_types.CompilerIrParam.Param "k" (U64) 2))
                (compiler_ir_types.compiler-ir-param-builder-push!
                  (&mut builder)
                  (compiler_ir_types.CompilerIrParam.Param "base" (I64) 3))
                (compiler_ir_types.compiler-ir-param-builder-to-seq builder))
              (I64)
              4
              (compiler_ir_types.compiler-ir-block-list-empty)
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
              (Avx512)
              8
              (Var 20)
              0
              0
              (Imported
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
            (pabi-function-private-abi (pabi-private-helper))
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
          (pabi-render-function (pabi-helper-function "helper" Ordinary))
          " abi ")
        57]
      [(not
          (match (compiler_ir_types.compiler-ir-clone-instr
            pools
            (SpmdCall (box (pabi-base-payload 0 0))))
            [(SpmdCall payload-box)
              (match (compiler_ir_types.compiler-ir-box-field-shared-view
                payload-box
                origin)
                [(Private private-box)
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
  (Var id))

(define (compiler-ir-smoke-operand-origin) : compiler_ir_types.CompilerIrSpmdCallOrigin
  (Imported
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
    (set!
      (array-ref slots 0)
      (compiler_ir_types.CompilerIrCAbiReturnSlot.Slot (I64) 0))
    (compiler_ir_types.CompilerIrCAbiReturnSlotSeq slots 1)))

(define (compiler-ir-smoke-role-letter
  [role : compiler_ir_types.CompilerIrOperandRole]) : String
  (match role
    [(Scalar) "S"]
    [(Address) "A"]
    [(Vector) "V"]
    [(Mask) "M"]
    [(CallArg) "C"]
    [(PhiInput) "P"]
    [(Condition) "D"]))

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
      [(Var id) (string.int->string (+ id delta))]
      [_ "?"])))

(define (compiler-ir-smoke-uses-text
  [instr : (& instr compiler_ir_types.CompilerIrInstr)]
  [delta : i64]) : String
  (let
    [instr : compiler_ir_types.CompilerIrInstr
      (owned_view.compiler-owned-reference-shared-view instr)]
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
    (set! compiler-ir-smoke-operand-visits 0)
    (compiler_ir_types.compiler-ir-instr-visit-uses
      (compiler_ir_types.compiler-ir-global-shared-view instr)
      compiler-ir-smoke-count-use)
    (=
      compiler-ir-smoke-operand-visits
      (compiler_ir_types.compiler-ir-instr-fold-uses
        instr
        zero
        compiler-ir-smoke-count-fold))))

(define (compiler-ir-smoke-shift-use
  [delta : i64]
  [_role : compiler_ir_types.CompilerIrOperandRole]
  [value : compiler_ir_types.CompilerIrValue]) : compiler_ir_types.CompilerIrValue
  (match (compiler_ir_types.compiler-ir-global-shared-view value)
    [(Var id) (operand-var (+ id delta))]
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
  [instr : (& instr compiler_ir_types.CompilerIrInstr)]
  [delta : i64]) : String
  (let
    [instr : compiler_ir_types.CompilerIrInstr
      (owned_view.compiler-owned-reference-shared-view instr)]
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
    (compiler-ir-smoke-uses-text instr 0)
    " | dst "
    (string.int->string (compiler_ir_types.compiler-ir-instr-dst instr))
    " | succ"
    (compiler-ir-smoke-successor-text instr 0)
    (match (compiler_ir_types.compiler-ir-instr-dst-type instr)
      [(Some _) " | typed"]
      [(No) ""])))

(define (compiler-ir-smoke-value-eq
  [a : compiler_ir_types.CompilerIrValue]
  [b : compiler_ir_types.CompilerIrValue]) : bool
  (match a
    [(Var x)
      (match b
        [(Var y) (= x y)]
        [_ false])]
    [_ false]))

(define (compiler-ir-smoke-type-eq [a : ast.AstType] [b : ast.AstType]) : bool
  (match a
    [(I64)
      (match b
        [(I64) true]
        [_ false])]
    [_ false]))

(define (compiler-ir-smoke-zip-eq?
  [a : compiler_ir_types.CompilerIrInstr]
  [b : (& b compiler_ir_types.CompilerIrInstr)]) : bool
  (let
    [b : compiler_ir_types.CompilerIrInstr
      (owned_view.compiler-owned-reference-shared-view b)]
    (compiler_ir_types.compiler-ir-instr-zip-eq
      a
      b
      compiler-ir-smoke-value-eq
      compiler-ir-smoke-type-eq)))

;; 0, or the number of the failed check.
(define (compiler-ir-smoke-operand-failure
  [instr : compiler_ir_types.CompilerIrInstr]
  [expected : String]) : i64
  (let
    [dst : i64 (compiler_ir_types.compiler-ir-instr-dst instr)]
    [spmd? : bool
      (match (compiler_ir_types.compiler-ir-global-shared-view instr)
        [(SpmdCall _) true]
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
            (compiler-ir-smoke-uses-text mapped 0)
            (compiler-ir-smoke-uses-text instr 100)))
        3]
      [(not
          (=
            (compiler_ir_types.compiler-ir-instr-dst renamed)
            (if (< dst 0)
              dst
              (+ dst 1000))))
        4]
      [(not
          (string.eq
            (compiler-ir-smoke-successor-text renamed 0)
            (compiler-ir-smoke-successor-text instr 7)))
        5]
      [(not
          (=
            (compiler-ir-smoke-zip-eq?
              (compiler_ir_types.compiler-ir-global-shared-view instr)
              instr)
            (not spmd?)))
        6]
      [(and
          (not (string.eq (compiler-ir-smoke-uses-text instr 0) ""))
          (compiler-ir-smoke-zip-eq?
            (compiler_ir_types.compiler-ir-global-shared-view instr)
            mapped))
        7]
      [(and
          (not spmd?)
          (not
            (compiler-ir-smoke-zip-eq?
              (compiler_ir_types.compiler-ir-clone-instr
                (ast.ast-node-pool-reader-context-current)
                (compiler_ir_types.compiler-ir-global-shared-view instr))
              instr)))
        8]
      [(not
          (=
            (let
              [instr (compiler_ir_types.compiler-ir-instr-with-dst instr 5)]
              (compiler_ir_types.compiler-ir-instr-dst instr))
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
    (while (and (= failure 0) (<= index 54))
      (set!
        failure
        (compiler-ir-smoke-operand-failure
          (compiler-ir-smoke-operand-sample index)
          (compiler-ir-smoke-operand-expect index)))
      (set! index (+ index 1)))
    (if (= failure 0)
      0
      (+ (* (- index 1) 100) failure))))

(define (compiler-ir-smoke-operand-sample [index : i64]) : compiler_ir_types.CompilerIrInstr
  (cond
    [(= index 1) (Mov 1 (operand-var 10) (I64))]
    [(= index 2) (Alloc 1 (I64))]
    [(= index 3) (AddrOf 1 50)]
    [(= index 4) (Gep 1 (operand-var 10) (operand-var 11) (I64))]
    [(= index 5) (Load 1 (operand-var 10) (I64))]
    [(= index 6) (StoreOwned (operand-var 10) (operand-var 11) (I64))]
    [(= index 7) (StorePtr (operand-var 10) (operand-var 11) (I64))]
    [(= index 8) (CopyBytes (operand-var 10) (operand-var 11) 4)]
    [(= index 9) (BoundsCheck (operand-var 10) (operand-var 11) 70)]
    [(= index 10) (Cast 1 (operand-var 10) (I64) (I64))]
    [(= index 11) (Bitcast 1 (operand-var 10) (I64) (I64))]
    [(= index 12) (BinOp 1 (Add) (operand-var 10) (operand-var 11) (I64))]
    [(= index 13) (UnOp 1 (Neg) (operand-var 10) (I64))]
    [(= index 14) (LaneId 1 4 (I64))]
    [(= index 15) (Splat 1 (operand-var 10) 4 (I64))]
    [(= index 16)
      (compiler_ir_types.ir-instr-vector-bin-op
        1
        (Add)
        (operand-var 10)
        (operand-var 11)
        4
        (I64))]
    [(= index 17)
      (compiler_ir_types.ir-instr-vector-prefix
        1
        (Sum)
        (operand-var 10)
        (operand-var 11)
        4
        (I64))]
    [(= index 18) (VectorReduce 1 (Sum) (operand-var 10) 4 (I64))]
    [(= index 19)
      (compiler_ir_types.ir-instr-vector-compare
        1
        (Add)
        (operand-var 10)
        (operand-var 11)
        4
        (I64))]
    [(= index 20) (MaskBinOp 1 (And) (operand-var 10) (operand-var 11) 4)]
    [(= index 21) (MaskNot 1 (operand-var 10) 4)]
    [(= index 22) (MaskReduce 1 (Any) (operand-var 10) 4)]
    [(= index 23)
      (compiler_ir_types.ir-instr-select
        1
        (operand-var 10)
        (operand-var 11)
        (operand-var 12)
        4
        (I64))]
    [(= index 24) (VectorLoad 1 (operand-var 10) (operand-var 11) 4 (I64))]
    [(= index 25)
      (compiler_ir_types.ir-instr-vector-store
        (operand-var 10)
        (operand-var 11)
        (operand-var 12)
        4
        (I64))]
    [(= index 26)
      (compiler_ir_types.ir-instr-predicated-store
        (operand-var 10)
        (operand-var 11)
        (operand-var 12)
        (operand-var 13)
        4
        (I64))]
    [(= index 27)
      (compiler_ir_types.ir-instr-predicated-load
        1
        (operand-var 10)
        (operand-var 11)
        (operand-var 12)
        4
        (I64))]
    [(= index 28)
      (compiler_ir_types.ir-instr-gather-load
        1
        (operand-var 10)
        (operand-var 11)
        (operand-var 12)
        true
        4
        (I64))]
    [(= index 29)
      (compiler_ir_types.ir-instr-vector-shuffle
        1
        (operand-var 10)
        (operand-var 11)
        (Some (operand-var 12))
        (operand-var 13)
        4
        (I64))]
    [(= index 30) (TailMask 1 (operand-var 10) (operand-var 11) 4)]
    [(= index 31) (EntryArgc 1)]
    [(= index 32) (EntryArgv 1)]
    [(= index 33) (EntryEnvp 1)]
    [(= index 34) (CpuId 1 (operand-var 10) (operand-var 11) 4)]
    [(= index 35) (Xgetbv 1 (operand-var 10))]
    [(= index 36) (Syscall 1 (Two (operand-var 10) (operand-var 11)))]
    [(= index 37) (Call 1 0 (Two (operand-var 10) (operand-var 11)) (I64))]
    [(= index 38)
      (CallIndirect
        1
        (operand-var 10)
        (Two (operand-var 11) (operand-var 12))
        (I64))]
    [(= index 39)
      (CallIndirectC
        1
        (operand-var 10)
        (Two (operand-var 11) (operand-var 12))
        (I64))]
    [(= index 40)
      (compiler_ir_types.ir-instr-call-cabi-store-result
        (operand-var 10)
        0
        (Two (operand-var 11) (operand-var 12))
        (compiler-ir-smoke-operand-slots))]
    [(= index 41)
      (compiler_ir_types.ir-instr-call-indirect-cabi-store-result
        (operand-var 10)
        (operand-var 11)
        (Two (operand-var 12) (operand-var 13))
        (compiler-ir-smoke-operand-slots))]
    [(= index 42)
      (SpmdCall
        (box
          (compiler_ir_types.CompilerIrInstrSpmdCallPayload
            0
            (Avx2)
            4
            (operand-var 10)
            (compiler_ir_types.compiler-ir-spmd-call-arg-seq2
              (Arg (Uniform) (operand-var 11) (I64))
              (Arg (Varying) (operand-var 12) (I64)))
            (Value 1 (Varying) (I64))
            (compiler-ir-smoke-operand-origin))))]
    [(= index 43) (TailCall 0 (Two (operand-var 10) (operand-var 11)) (I64))]
    [(= index 44) (Store 0 (operand-var 10) (I64))]
    [(= index 45) (Jump 70)]
    [(= index 46) (Branch (operand-var 10) 70 71)]
    [(= index 47) (TotalEnumBranch (operand-var 10) 70 71)]
    [(= index 48) (Return (Some (operand-var 10)))]
    [(= index 49)
      (Phi
        1
        (compiler_ir_types.compiler-ir-phi-input-seq-prepend
          (operand-var 10)
          70
          (compiler_ir_types.compiler-ir-phi-input-seq-prepend
            (operand-var 11)
            71
            (compiler_ir_types.compiler-ir-phi-input-seq-empty)))
        (I64))]
    [(= index 50)
      (Pack
        1
        (compiler_ir_types.compiler-ir-value-seq2
          (operand-var 10)
          (operand-var 11))
        (I64))]
    [(= index 51) (Word 1 (operand-var 10) 4 (I64))]
    [(= index 52)
      (TailCallIndirect
        (operand-var 10)
        (Two (operand-var 11) (operand-var 12))
        (I64))]
    [(= index 53)
      (Switch
        (operand-var 10)
        4
        (compiler_ir_types.compiler-ir-switch-case-seq2 (Case 0 70) (Case 1 71))
        72)]
    [(= index 54)
      (TotalEnumSwitch
        (operand-var 10)
        4
        (compiler_ir_types.compiler-ir-switch-case-seq2 (Case 0 70) (Case 1 71))
        72
        73)]
    [else (Jump 0)]))

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

;; Dense index of a symbol this table minted, for callers keeping a side table;
;; malformed, foreign-domain and unallocated ids fail closed.
(define (compiler-ir-symbol-slot [symbol : i64]) : i64
  (if (compiler_ir_types.compiler-ir-symbol-owned? symbol)
    (compiler_ir_types.compiler-ir-symbol-slot-unchecked symbol)
    -1))

(define (compiler-ir-instr-seq-return?
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [index : i64]) : bool
  (match (& (array-ref instrs.slots index))
    [(Return _) true]
    [_ false]))

(define (compiler-ir-function-abi [func : compiler_ir_types.CompilerIrFunction]) : compiler_ir_types.CompilerIrFunctionAbi
  (match func
    [(Function _ _ _ _ _ function-abi) (clone function-abi)]))

(defenum CompilerIrMaybeDescriptorPairKind
  (No)
  (Some compiler_ir_types.CompilerIrDescriptorPairKind))

(define (compiler-ir-descriptor-pair-kind-for-handle-type [ty : ast.AstType]) : CompilerIrMaybeDescriptorPairKind
  (match ty
    [(String) (Some (OwnedString))]
    [(DynArray elem) (Some (DynamicArray elem))]
    [_ (No)]))

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
      (compiler_ir_types.compiler-ir-instr-seq-set!
        (&mut instrs)
        index
        (rewrite (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)))
      (set! index (+ index 1)))))

(define (compiler-ir-instr-seq-compact!
  [instrs : (&mut instrs compiler_ir_types.CompilerIrInstrSeq)]
  [keep? : (-> compiler_ir_types.CompilerIrInstr bool)]) : unit
  (let
    [read : i64 0]
    [write : i64 0]
    [count : i64 instrs.len]
    (while (< read count)
      (when
        (keep? (clone (array-ref instrs.slots read)))
        (if (not (= write read))
          (set!
            (array-ref instrs.slots write)
            (clone (array-ref instrs.slots read)))
          unit)
        (set! write (+ write 1)))
      (set! read (+ read 1)))
    (set! instrs.len write)))

(define (compiler-ir-value-var-eq?
  [value : compiler_ir_types.CompilerIrValue]
  [want : i64]) : bool
  (match value
    [(Var id) (= id want)]
    [_ false]))

(define (compiler-ir-effect-is?
  [instr : compiler_ir_types.CompilerIrInstr]
  [effect : compiler_ir_types.CompilerIrEffect]) : bool
  (compiler_ir_types.compiler-ir-effect-eq?
    (compiler_ir_types.compiler-ir-instr-effect instr)
    effect))

(define (compiler-ir-instruction-effects-ok?) : bool
  (and
    (compiler-ir-effect-is? (Mov 0 (I64 1) (I64)) Pure)
    (compiler-ir-effect-is? (AddrOf 1 0) Pure)
    (compiler-ir-effect-is? (Gep 2 (Var 1) (I64 0) (I64)) Pure)
    (compiler-ir-effect-is? (Cast 3 (Var 2) (I64) (I32)) Pure)
    (compiler-ir-effect-is? (BinOp 4 (Add) (Var 2) (I64 1) (I64)) Pure)
    (compiler-ir-effect-is? (UnOp 5 (Neg) (Var 4) (I64)) Pure)
    (compiler-ir-effect-is?
      (Phi
        6
        (compiler_ir_types.compiler-ir-phi-input-seq-prepend
          (I64 1)
          (compiler_ir_types.compiler-ir-label "entry")
          (compiler_ir_types.compiler-ir-phi-input-seq-empty))
        (I64))
      Pure)
    (compiler-ir-effect-is? (Load 7 (Var 1) (I64)) MemoryRead)
    (compiler-ir-effect-is? (Alloc 8 (I64)) MemoryWrite)
    (compiler-ir-effect-is? (StorePtr (Var 1) (I64 2) (I64)) MemoryWrite)
    (compiler-ir-effect-is? (CopyBytes (Var 1) (Var 2) 16) MemoryWrite)
    (compiler-ir-effect-is?
      (Store (compiler_ir_types.compiler-ir-test-symbol "global") (I64 3) (I64))
      MemoryWrite)
    (compiler-ir-effect-is?
      (Call 9 cbi.compiler-builtin-id-tl-region-mark (Nil) (I64))
      MemoryRead)
    (compiler-ir-effect-is? (CpuId 10 (I64 1) (I64 0) 0) CpuProbe)
    (compiler-ir-effect-is? (Xgetbv 11 (I64 0)) CpuProbe)
    (compiler-ir-effect-is?
      (BoundsCheck
        (Var 0)
        (Var 1)
        (compiler_ir_types.compiler-ir-label "bounds_ok"))
      ControlFlow)
    (compiler-ir-effect-is?
      (TailCall
        (compiler_ir_types.compiler-ir-test-symbol "fact_loop")
        (Two (Var 3) (I64 1))
        (I64))
      ControlFlow)
    (compiler-ir-effect-is?
      (Jump (compiler_ir_types.compiler-ir-label "done"))
      ControlFlow)
    (compiler-ir-effect-is?
      (Branch
        (Bool true)
        (compiler_ir_types.compiler-ir-label "then")
        (compiler_ir_types.compiler-ir-label "else"))
      ControlFlow)
    (compiler-ir-effect-is?
      (Switch
        (Var 0)
        1
        (compiler_ir_types.compiler-ir-switch-case-seq2
          (Case 1 (compiler_ir_types.compiler-ir-label "one"))
          (Case 2 (compiler_ir_types.compiler-ir-label "two")))
        (compiler_ir_types.compiler-ir-label "default"))
      ControlFlow)
    (compiler-ir-effect-is? (Return (Some (I64 0))) ControlFlow)))

(define (compiler-ir-vector-mask-effects-ok?) : bool
  (and
    (compiler-ir-effect-is? (LaneId 20 4 (I64)) Pure)
    (compiler-ir-effect-is? (Splat 21 (Var 0) 4 (I64)) Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-vector-bin-op
        22
        (Add)
        (Var 20)
        (Var 21)
        4
        (I64))
      Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-vector-prefix
        32
        (Sum)
        (Var 22)
        (I64 0)
        4
        (I64))
      Pure)
    (compiler-ir-effect-is? (VectorReduce 23 (Sum) (Var 22) 4 (I64)) Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-vector-compare
        24
        (Lt)
        (Var 20)
        (Var 21)
        4
        (I64))
      Pure)
    (compiler-ir-effect-is? (MaskBinOp 25 (And) (Var 24) (Var 24) 4) Pure)
    (compiler-ir-effect-is? (MaskNot 26 (Var 25) 4) Pure)
    (compiler-ir-effect-is? (MaskReduce 27 (Any) (Var 26) 4) Pure)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-select 28 (Var 24) (Var 20) (Var 21) 4 (I64))
      Pure)
    (compiler-ir-effect-is? (TailMask 29 (Var 0) (Var 1) 4) Pure)
    (compiler-ir-effect-is? (VectorLoad 30 (Var 2) (Var 0) 4 (I64)) MemoryRead)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-predicated-load
        31
        (Var 2)
        (Var 0)
        (Var 29)
        4
        (I64))
      MemoryRead)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-vector-store (Var 2) (Var 0) (Var 22) 4 (I64))
      MemoryWrite)
    (compiler-ir-effect-is?
      (compiler_ir_types.ir-instr-predicated-store
        (Var 2)
        (Var 0)
        (Var 22)
        (Var 29)
        4
        (I64))
      MemoryWrite)))

;; Fault rows (#7274). The exhaustive matches already force a row for a new
;; instruction or operator; these tables pin what each row says, one letter per
;; entry: N none, O operands, K check, C call. The instruction table follows
;; `compiler-ir-smoke-operand-sample` 1..54; the operator table follows the
;; `CompilerIrBinOp` declaration order.
(define (compiler-ir-smoke-fault-letter
  [fault : compiler_ir_types.CompilerIrFault]) : String
  (match fault
    [(None) "N"]
    [(Operands) "O"]
    [(Check) "K"]
    [(Call) "C"]))

(define (compiler-ir-smoke-instr-fault-rows) : String
  (let
    [index : i64 1]
    [out : String ""]
    (while (<= index 54)
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-ir-smoke-fault-letter
            (compiler_ir_types.compiler-ir-instr-fault
              (compiler-ir-smoke-operand-sample index)))))
      (set! index (+ index 1)))
    out))

(define (compiler-ir-smoke-binop-fault-rows) : String
  (let
    [i64-ty : ast.AstType (I64)]
    [ops : (Array compiler_ir_types.CompilerIrBinOp 22)
      (array
        (compiler_ir_types.CompilerIrBinOp.Add)
        (compiler_ir_types.CompilerIrBinOp.Sub)
        (compiler_ir_types.CompilerIrBinOp.Mul)
        (compiler_ir_types.CompilerIrBinOp.Div)
        (compiler_ir_types.CompilerIrBinOp.Mod)
        (compiler_ir_types.CompilerIrBinOp.SafeDiv)
        (compiler_ir_types.CompilerIrBinOp.SafeMod)
        (compiler_ir_types.CompilerIrBinOp.Eq)
        (compiler_ir_types.CompilerIrBinOp.Ne)
        (compiler_ir_types.CompilerIrBinOp.Lt)
        (compiler_ir_types.CompilerIrBinOp.Le)
        (compiler_ir_types.CompilerIrBinOp.Gt)
        (compiler_ir_types.CompilerIrBinOp.Ge)
        (compiler_ir_types.CompilerIrBinOp.BitTestEq)
        (compiler_ir_types.CompilerIrBinOp.BitTestNe)
        (compiler_ir_types.CompilerIrBinOp.And)
        (compiler_ir_types.CompilerIrBinOp.Or)
        (compiler_ir_types.CompilerIrBinOp.BitAnd)
        (compiler_ir_types.CompilerIrBinOp.BitOr)
        (compiler_ir_types.CompilerIrBinOp.BitXor)
        (compiler_ir_types.CompilerIrBinOp.Shl (clone i64-ty))
        (compiler_ir_types.CompilerIrBinOp.Shr (clone i64-ty)))]
    [index : i64 0]
    [out : String ""]
    (while (< index 22)
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-ir-smoke-fault-letter
            (compiler_ir_types.compiler-ir-binop-fault
              (clone (array-ref ops index))))))
      (set! index (+ index 1)))
    out))

(define (compiler-ir-fault-rows-ok?) : bool
  (and
    (string.eq
      (compiler-ir-smoke-instr-fault-rows)
      "NNNNNNNNKNNNNNNNNNNNNNNNNNNNKNNNNNNCCCCCCCCNNNNNNNNCNN")
    (string.eq (compiler-ir-smoke-binop-fault-rows) "NNNOONNNNNNNNNNNNNNNOO")
    ;; A vector operator carries the scalar operator's row.
    (string.eq
      (compiler-ir-smoke-fault-letter
        (compiler_ir_types.compiler-ir-instr-fault
          (compiler_ir_types.ir-instr-vector-bin-op
            1
            (Div)
            (Var 10)
            (Var 11)
            4
            (I64))))
      "O")
    (compiler_ir_types.compiler-ir-binop-may-fault? (Mod))
    (not (compiler_ir_types.compiler-ir-binop-may-fault? (SafeMod)))))

(define (compiler-ir-effect-predicates-ok?) : bool
  (and
    (not (compiler_ir_types.compiler-ir-effect-has-side-effect? Pure))
    (not (compiler_ir_types.compiler-ir-effect-has-side-effect? MemoryRead))
    (compiler_ir_types.compiler-ir-effect-has-side-effect? CpuProbe)
    (compiler_ir_types.compiler-ir-effect-has-side-effect? MemoryWrite)
    (compiler_ir_types.compiler-ir-effect-has-side-effect? ControlFlow)
    (compiler_ir_types.compiler-ir-effect-has-side-effect? Unknown)
    (not (compiler_ir_types.compiler-ir-effect-invalidates-cse? Pure))
    (compiler_ir_types.compiler-ir-effect-invalidates-cse? MemoryRead)
    (compiler_ir_types.compiler-ir-effect-invalidates-cse? CpuProbe)
    (compiler_ir_types.compiler-ir-effect-invalidates-cse? MemoryWrite)
    (compiler_ir_types.compiler-ir-effect-invalidates-cse? ControlFlow)
    (compiler_ir_types.compiler-ir-effect-invalidates-cse? Unknown)))

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
      (VectorReduce 8 Sum (Var 2) 4 (I64))
      "  %8 = vector_reduce_sum %2 lanes 4 : i64")
    (compiler-ir-renders-as?
      (VectorReduce 8 Min (Var 2) 4 (I64))
      "  %8 = vector_reduce_min %2 lanes 4 : i64")
    (compiler-ir-renders-as?
      (VectorReduce 8 Max (Var 2) 4 (I64))
      "  %8 = vector_reduce_max %2 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-prefix 42 Sum (Var 7) (I64 -3) 4 (I64))
      "  %42 = vector_prefix_sum %7, carry -3 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-prefix 42 Max (Var 7) (I64 -3) 4 (I64))
      "  %42 = vector_prefix_max %7, carry -3 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-prefix 42 All (Var 7) (I64 -3) 4 (I64))
      "  %42 = vector_prefix_all %7, carry -3 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-prefix 42 Any (Var 7) (I64 -3) 4 (I64))
      "  %42 = vector_prefix_any %7, carry -3 lanes 4 : i64")
    (compiler-ir-renders-as?
      (MaskReduce 9 All (Var 5) 4)
      "  %9 = mask_reduce_all %5 lanes 4")
    (compiler-ir-renders-as?
      (MaskBinOp 4 And (Var 3) (Var 3) 4)
      "  %4 = mask_and %3, %3 lanes 4")))

(define (compiler-ir-display-instrs-ok?) : bool
  (and
    (compiler-ir-renders-as? (LaneId 0 4 (I64)) "  %0 = lane_id 4 : i64")
    (compiler-ir-renders-as?
      (Splat 1 (I64 7) 4 (I64))
      "  %1 = splat 7 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-bin-op 2 (Add) (Var 0) (Var 1) 4 (I64))
      "  %2 = vector_add %0, %1 lanes 4 : i64")
    (compiler-ir-renders-as?
      (VectorReduce 8 (Sum) (Var 2) 4 (I64))
      "  %8 = vector_reduce_sum %2 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-compare 3 (Lt) (Var 0) (Var 1) 4 (I64))
      "  %3 = vector_compare_lt %0, %1 lanes 4 : i64")
    (compiler-ir-renders-as?
      (MaskBinOp 4 (Or) (Var 3) (Var 3) 4)
      "  %4 = mask_or %3, %3 lanes 4")
    (compiler-ir-renders-as? (MaskNot 5 (Var 4) 4) "  %5 = mask_not %4 lanes 4")
    (compiler-ir-renders-as?
      (MaskReduce 9 (Any) (Var 5) 4)
      "  %9 = mask_reduce_any %5 lanes 4")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-select 6 (Var 5) (Var 2) (Var 1) 4 (I64))
      "  %6 = select %5, %2, %1 lanes 4 : i64")
    (compiler-ir-renders-as?
      (VectorLoad 7 (Var 10) (Var 11) 4 (I64))
      "  %7 = vector_load %10, %11 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-vector-store
        (Var 12)
        (Var 11)
        (Var 6)
        4
        (I64))
      "  vector_store %12, %11, %6 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-predicated-store
        (Var 12)
        (Var 11)
        (Var 6)
        (Var 5)
        4
        (I64))
      "  predicated_store %12, %11, %6 mask %5 lanes 4 : i64")
    (compiler-ir-renders-as?
      (compiler_ir_types.ir-instr-predicated-load
        10
        (Var 12)
        (Var 11)
        (Var 5)
        4
        (I64))
      "  %10 = predicated_load %12, %11 mask %5 lanes 4 : i64")))

(define (compiler-ir-vector-prefix-display-clone-ok?) : bool
  (let
    [instr : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.ir-instr-vector-prefix
        42
        (Min)
        (Var 7)
        (I64 -3)
        4
        (I64))]
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
      (compiler-ir-effect-is? instr Pure)
      (match cloned
        [(VectorPrefix payload-box)
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
                [(Min) true]
                [_ false])
              (compiler-ir-value-var-eq? src 7)
              (match carry
                [(I64 value) (= value -3)]
                [_ false])
              (= lanes 4)
              (match ty
                [(I64) true]
                [_ false])))]
        [_ false]))))

(define (compiler-ir-display-tail-mask-ok?) : bool
  (let
    [instr : compiler_ir_types.CompilerIrInstr (TailMask 9 (Var 1) (Var 2) 8)]
    (and
      (compiler-ir-renders-as?
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        "  %9 = tail_mask %1, %2 lanes 8")
      (compiler-ir-effect-is?
        (compiler_ir_types.compiler-ir-global-shared-view instr)
        Pure)
      (match instr
        [(TailMask dst index len lanes)
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
      (TailCall
        (compiler_ir_types.compiler-ir-test-symbol "fact_loop")
        (Two (Var 3) (I64 1))
        (I64)))
    "  tailcall fact_loop(%3, 1) : i64"))

(define (compiler-ir-switch-render-ok?) : bool
  (let
    [cases : compiler_ir_types.CompilerIrSwitchCaseSeq
      (compiler_ir_types.compiler-ir-switch-case-seq2
        (Case 4 (compiler_ir_types.compiler-ir-label "four"))
        (Case 5 (compiler_ir_types.compiler-ir-label "five")))]
    [instr : compiler_ir_types.CompilerIrInstr
      (Switch (Var 9) 4 cases (compiler_ir_types.compiler-ir-label "other"))]
    (compiler-ir-renders-as?
      instr
      "  switch %9 base 4 [4:four, 5:five] default other")))

;; Span entries are flat records: an array slot holds exactly the fields, with
;; no outer variant tag (a function entry 32 bytes, an instruction entry 48).
(define (compiler-ir-source-spans-entry-strides-pinned?) : bool
  (let
    [entries : (__tl_dyn-array compiler_ir_types.CompilerSourceSpansEntry)
      (__tl_make-array compiler_ir_types.CompilerSourceSpansEntry 2)]
    [instr-entries : (__tl_dyn-array
      compiler_ir_types.CompilerSourceSpansInstrEntry)
      (__tl_make-array compiler_ir_types.CompilerSourceSpansInstrEntry 2)]
    (and
      (=
        (-
          (unsafe
            (ptr->int (ptr-offset (__tl_array-data entries) 1)))
          (unsafe
            (ptr->int (__tl_array-data entries))))
        32)
      (=
        (-
          (unsafe
            (ptr->int (ptr-offset (__tl_array-data instr-entries) 1)))
          (unsafe
            (ptr->int (__tl_array-data instr-entries))))
        48))))

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
          (compiler_ir_types.CompilerSourceSpansEntry first 0 span1))
        (compiler_ir_types.CompilerSourceSpansEntry second 0 span2))]
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
    [instr : compiler_ir_types.CompilerIrInstr (Mov 9 (I64 1) (I64))]
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
    (while (< i 6)
      (set!
        grown-entries
        (compiler_ir_types.compiler-source-spans-entry-list-append
          grown-entries
          (compiler_ir_types.CompilerSourceSpansEntry
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
      (set! i (+ i 1)))
    (and
      (= (compiler_ir_types.compiler-source-spans-entry-list-count entries) 2)
      (= (compiler_ir_types.compiler-source-spans-count spans) 2)
      (=
        (compiler_ir_types.compiler-source-spans-entry-list-count grown-entries)
        6)
      (= (array-length grown-entries.slots) 8)
      (match (compiler_ir_types.compiler-ir-global-shared-view
        grown-instr-spans)
        [(Spans _ grown-instr-entries grown-instr-count)
          (and
            (= grown-instr-count 6)
            (= grown-instr-entries.len 6)
            (= (array-length grown-instr-entries.slots) 8))])
      (match (compiler_ir_types.compiler-source-spans-entry-list-lookup
        entries
        second)
        [(Some found)
          (and
            (= (ast.ast-source-span-start-line found) 4)
            (= (ast.ast-source-span-end-col found) 8))]
        [(No) false])
      (match (compiler_ir_types.compiler-source-spans-entry-list-lookup
        grown-entries
        grow)
        [(Some found)
          (and
            (= (ast.ast-source-span-start-line found) 7)
            (= (ast.ast-source-span-end-col found) 12))]
        [(No) false])
      (match (compiler_ir_types.compiler-source-spans-lookup shadowed same)
        [(Some found)
          (and
            (= (ast.ast-source-span-start-line found) 7)
            (= (ast.ast-source-span-end-col found) 12))]
        [(No) false])
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
        [(Some found) (= (ast.ast-source-span-start-line found) 1)]
        [(No) false])
      (match (compiler_ir_types.compiler-source-spans-lookup
        same-spelling
        generated-provenance)
        [(Some found) (= (ast.ast-source-span-start-line found) 4)]
        [(No) false])
      (match (compiler_ir_types.compiler-source-spans-lookup-instr
        instr-spans
        instr-function
        (compiler_ir_types.compiler-ir-global-shared-view instr))
        [(Some found)
          (and
            (= (ast.ast-source-span-start-line found) 7)
            (= (ast.ast-source-span-end-col found) 12))]
        [(No) false])
      (match (compiler_ir_types.compiler-source-spans-lookup-instr
        grown-instr-spans
        instr-function
        (compiler_ir_types.compiler-ir-global-shared-view instr))
        [(Some found)
          (and
            (= (ast.ast-source-span-start-line found) 7)
            (= (ast.ast-source-span-end-col found) 12))]
        [(No) false])
      (match (compiler_ir_types.compiler-source-spans-lookup-instr
        (compiler_ir_types.compiler-ir-global-shared-view
          provenance-instr-spans)
        source-provenance
        (compiler_ir_types.compiler-ir-global-shared-view instr))
        [(Some found) (= (ast.ast-source-span-start-line found) 1)]
        [(No) false])
      (match (compiler_ir_types.compiler-source-spans-lookup-instr
        provenance-instr-spans
        generated-provenance
        instr)
        [(Some found) (= (ast.ast-source-span-start-line found) 4)]
        [(No) false]))))

(define (compiler-ir-instr-seq-mov-dst?
  [instrs : (& instrs compiler_ir_types.CompilerIrInstrSeq)]
  [index : i64]
  [want : i64]) : bool
  (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
    [(Mov dst _ _) (= dst want)]
    [_ false]))

(define (compiler-ir-instr-seq-return-var?
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [index : i64]
  [want : i64]) : bool
  (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
    [(Return (Some (Var var))) (= var want)]
    [_ false]))

(define (compiler-ir-instr-seq-test-rewrite
  [instr : compiler_ir_types.CompilerIrInstr]) : compiler_ir_types.CompilerIrInstr
  (match (compiler_ir_types.compiler-ir-global-shared-view instr)
    [(Mov dst value ty) (Mov (+ dst 10) value ty)]
    [(Alloc dst ty) (Alloc dst ty)]
    [(Return value) (Return value)]
    [_ instr]))

(define (compiler-ir-instr-seq-test-keep-non-alloc?
  [instr : compiler_ir_types.CompilerIrInstr]) : bool
  (match instr
    [(Alloc _ _) false]
    [_ true]))

(define (compiler-ir-instr-seq-mutable-rewrite-ok?) : bool
  (let
    [seq : compiler_ir_types.CompilerIrInstrSeq
      (compiler_ir_types.compiler-ir-instr-seq3
        (Mov 1 (I64 10) (I64))
        (Mov 2 (I64 20) (I64))
        (Return (Some (Var 2))))]
    (compiler-ir-instr-seq-rewrite!
      (compiler_ir_types.compiler-ir-global-shared-view seq)
      compiler-ir-instr-seq-test-rewrite)
    (and
      (= (compiler_ir_types.compiler-ir-instr-seq-count seq) 3)
      (compiler-ir-instr-seq-mov-dst? seq 0 11)
      (compiler-ir-instr-seq-mov-dst? seq 1 12)
      (compiler-ir-instr-seq-return-var? seq 2 2))))

(define (compiler-ir-instr-seq-mutable-compact-ok?) : bool
  (let
    [seq : compiler_ir_types.CompilerIrInstrSeq
      (compiler_ir_types.compiler-ir-instr-seq4
        (Mov 1 (I64 10) (I64))
        (Alloc 9 (I64))
        (Mov 2 (I64 20) (I64))
        (Return (Some (Var 2))))]
    (compiler-ir-instr-seq-compact!
      (&mut seq)
      compiler-ir-instr-seq-test-keep-non-alloc?)
    (and
      (= (compiler_ir_types.compiler-ir-instr-seq-count seq) 3)
      (compiler-ir-instr-seq-mov-dst? seq 0 1)
      (compiler-ir-instr-seq-mov-dst? seq 1 2)
      (compiler-ir-instr-seq-return-var? seq 2 2))))

(define (compiler-ir-block-list-first-label?
  [blocks : (& blocks (Slice compiler_ir_types.CompilerIrBlock))]
  [want : String]) : bool
  (match blocks
    [(slice block & _)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block label _)
          (string.eq (compiler_ir_types.compiler-ir-label-text label) want)])]
    [(slice) false]))

(define (compiler-ir-block-slice-label-at?
  [blocks : (& blocks (Slice compiler_ir_types.CompilerIrBlock))]
  [index : i64]
  [want : String]) : bool
  (match blocks
    [(slice) false]
    [(slice block & rest)
      (if (= index 0)
        (match (owned_view.compiler-owned-reference-shared-view block)
          [(Block label _)
            (string.eq (compiler_ir_types.compiler-ir-label-text label) want)])
        (compiler-ir-block-slice-label-at? rest (- index 1) want))]))

(define (compiler-ir-block-list-label-at?
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [index : i64]
  [want : String]) : bool
  (compiler-ir-block-slice-label-at?
    (compiler_ir_types.compiler-ir-block-list-view blocks)
    index
    want))

(define (compiler-ir-function-seq-name-at?
  [functions : (& functions compiler_ir_types.CompilerIrFunctionSeq)]
  [index : i64]
  [want : String]) : bool
  (if (or (< index 0) (>= index functions.len))
    false
    (match (array-ref functions.slots index)
      [(Function name _ _ _ _ _)
        (string.eq (compiler_ir_types.compiler-ir-symbol-text name) want)])))

(define (compiler-ir-test-function [name : String]) : compiler_ir_types.CompilerIrFunction
  (Function
    (compiler_ir_types.compiler-ir-test-symbol name)
    (compiler_ir_types.compiler-ir-param-seq-empty)
    (I64)
    1
    (compiler_ir_types.compiler-ir-block-list-empty)
    Ordinary))

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
      (compiler_ir_types.compiler-ir-block-list-empty)]
    [functions : compiler_ir_types.CompilerIrFunctionSeq
      (compiler_ir_types.compiler-ir-function-seq-empty)]
    (compiler_ir_types.compiler-ir-instr-builder-push!
      (&mut instr-builder)
      (compiler_ir_types.CompilerIrInstr.Mov 1 (I64 10) (I64)))
    (compiler_ir_types.compiler-ir-instr-builder-push!
      (&mut instr-builder)
      (compiler_ir_types.CompilerIrInstr.Mov 2 (I64 20) (I64)))
    (compiler_ir_types.compiler-ir-instr-builder-push!
      (&mut instr-builder)
      (compiler_ir_types.CompilerIrInstr.Return (Some (Var 2))))
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
      (compiler-ir-instr-seq-mov-dst? instrs 0 1)
      (compiler-ir-instr-seq-mov-dst? instrs 1 2)
      (compiler-ir-instr-seq-return-var? instrs 2 2)
      (= (compiler_ir_types.compiler-ir-block-list-count blocks) 3)
      (compiler-ir-block-list-label-at?
        (compiler_ir_types.compiler-ir-global-shared-view blocks)
        0
        "entry")
      (compiler-ir-block-list-label-at?
        (compiler_ir_types.compiler-ir-global-shared-view blocks)
        1
        "middle")
      (compiler-ir-block-list-label-at? blocks 2 "done")
      (= (compiler_ir_types.compiler-ir-function-seq-count functions) 3)
      (compiler-ir-function-seq-name-at? functions 0 "first")
      (compiler-ir-function-seq-name-at? functions 1 "second")
      (compiler-ir-function-seq-name-at? functions 2 "third"))))

(define (compiler-ir-param-seq-entry-i64?
  [seq : (& seq compiler_ir_types.CompilerIrParamSeq)]
  [index : i64]
  [want-name : String]
  [want-var : i64]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (match (compiler_ir_types.compiler-ir-array-shared-view seq.slots index)
      [(Param name ty var)
        (and
          (string.eq name want-name)
          (= var want-var)
          (match ty
            [(I64) true]
            [_ false]))])))

(define (compiler-ir-param-seq-entry-bool?
  [seq : compiler_ir_types.CompilerIrParamSeq]
  [index : i64]
  [want-name : String]
  [want-var : i64]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (match (array-ref seq.slots index)
      [(Param name ty var)
        (and
          (string.eq name want-name)
          (= var want-var)
          (match ty
            [(Bool) true]
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
      (Function
        (compiler_ir_types.compiler-ir-test-symbol "dense_params")
        params
        (Unit)
        8
        (compiler_ir_types.compiler-ir-block-list-empty)
        Ordinary)]
    [cloned-func : compiler_ir_types.CompilerIrFunction func]
    (compiler_ir_types.compiler-ir-param-builder-push!
      (&mut builder)
      (compiler_ir_types.CompilerIrParam.Param "value" (I64) 3))
    (set!
      snapshot
      (compiler_ir_types.compiler-ir-param-builder-snapshot (& builder)))
    (compiler_ir_types.compiler-ir-param-builder-push!
      (&mut builder)
      (compiler_ir_types.CompilerIrParam.Param "flag" (Bool) 7))
    (set! params (compiler_ir_types.compiler-ir-param-builder-to-seq builder))
    (set!
      cloned
      (compiler_ir_types.compiler-ir-clone-param-seq
        pools
        (compiler_ir_types.compiler-ir-global-shared-view params)))
    (set!
      func
      (Function
        (compiler_ir_types.compiler-ir-test-symbol "dense_params")
        (compiler_ir_types.compiler-ir-global-shared-view params)
        (Unit)
        8
        (compiler_ir_types.compiler-ir-block-list-empty)
        Ordinary))
    (set! cloned-func (compiler_ir_types.compiler-ir-clone-function pools func))
    (and
      (= (compiler_ir_types.compiler-ir-param-seq-count snapshot) 1)
      (compiler-ir-param-seq-entry-i64? snapshot 0 "value" 3)
      (= (compiler_ir_types.compiler-ir-param-seq-count params) 2)
      (compiler-ir-param-seq-entry-i64? params 0 "value" 3)
      (compiler-ir-param-seq-entry-bool? params 1 "flag" 7)
      (= (compiler_ir_types.compiler-ir-param-seq-count cloned) 2)
      (compiler-ir-param-seq-entry-i64? cloned 0 "value" 3)
      (compiler-ir-param-seq-entry-bool? cloned 1 "flag" 7)
      (match cloned-func
        [(Function _ cloned-params _ _ _ _)
          (and
            (= (compiler_ir_types.compiler-ir-param-seq-count cloned-params) 2)
            (compiler-ir-param-seq-entry-i64? cloned-params 0 "value" 3)
            (compiler-ir-param-seq-entry-bool? cloned-params 1 "flag" 7))]))))

(define (compiler-ir-c-abi-return-slot-seq-entry-i64-offset?
  [seq : (& seq compiler_ir_types.CompilerIrCAbiReturnSlotSeq)]
  [index : i64]
  [want-offset : i64]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (match (array-ref seq.slots index)
      [(Slot ty offset)
        (and
          (= offset want-offset)
          (match ty
            [(I64) true]
            [_ false]))])))

(define (compiler-ir-c-abi-return-slot-seq-entry-f64-offset?
  [seq : compiler_ir_types.CompilerIrCAbiReturnSlotSeq]
  [index : i64]
  [want-offset : i64]) : bool
  (if (or (< index 0) (>= index seq.len))
    false
    (match (array-ref seq.slots index)
      [(Slot ty offset)
        (and
          (= offset want-offset)
          (match ty
            [(F64) true]
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
          (compiler_ir_types.CompilerIrCAbiReturnSlot.Slot (I64) 0))
        (set!
          (array-ref slot-data 1)
          (compiler_ir_types.CompilerIrCAbiReturnSlot.Slot (F64) 8)))]
    [slots : compiler_ir_types.CompilerIrCAbiReturnSlotSeq
      (compiler_ir_types.CompilerIrCAbiReturnSlotSeq slot-data 2)]
    [cloned : compiler_ir_types.CompilerIrCAbiReturnSlotSeq
      (match (compiler_ir_types.compiler-ir-clone-instr
        pools
        (compiler_ir_types.ir-instr-call-cabi-store-result
          (Var 0)
          0
          (Nil)
          (compiler_ir_types.compiler-ir-global-shared-view slots)))
        [(CallCAbiStoreResult payload-box)
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
      [(Var id) (= id want)]
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
        (Pack 40 (compiler_ir_types.compiler-ir-global-shared-view words) (I64)))
        [(Pack _ cloned-words _) cloned-words]
        [_ (compiler_ir_types.compiler-ir-value-seq-empty)])]
    [instr : compiler_ir_types.CompilerIrInstr
      (Pack
        40
        (compiler_ir_types.compiler-ir-global-shared-view words)
        (Struct (ci.intern "Triple")))]
    (and
      (= snapshot.len 2)
      (= (array-length snapshot.slots) 2)
      (compiler-ir-value-seq-entry-var? snapshot 0 10)
      (compiler-ir-value-seq-entry-var? snapshot 1 20)
      (match instr
        [(Pack _ packed _)
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
    [string-kind : compiler_ir_types.CompilerIrDescriptorPairKind (OwnedString)]
    [array-kind : compiler_ir_types.CompilerIrDescriptorPairKind
      (DynamicArray 77)]
    [pack : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.ir-instr-descriptor-pair-pack
        30
        (Var 10)
        (Var 20)
        string-kind)]
    [data : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.ir-instr-descriptor-pair-data 31 (Var 30))]
    [length : compiler_ir_types.CompilerIrInstr
      (compiler_ir_types.ir-instr-descriptor-pair-length 32 (Var 30))]
    (and
      (match (compiler-ir-descriptor-pair-kind-for-handle-type (String))
        [(Some kind)
          (match kind
            [(OwnedString) true]
            [_ false])]
        [(No) false])
      (match (compiler-ir-descriptor-pair-kind-for-handle-type (DynArray 77))
        [(Some kind)
          (match kind
            [(DynamicArray elem) (= elem 77)]
            [_ false])]
        [(No) false])
      (match (compiler-ir-descriptor-pair-kind-for-handle-type (Array 77 4))
        [(No) true]
        [_ false])
      (match (compiler-ir-descriptor-pair-kind-for-handle-type (Str))
        [(No) true]
        [_ false])
      (match (compiler_ir_types.compiler-ir-descriptor-pair-handle-type
        array-kind)
        [(DynArray elem) (= elem 77)]
        [_ false])
      (match pack
        [(Pack dst words ty)
          (and
            (= dst 30)
            (match ty
              [(String) true]
              [_ false])
            (= words.len 2)
            (compiler-ir-value-seq-entry-var? words 0 10)
            (compiler-ir-value-seq-entry-var? words 1 20))]
        [_ false])
      (match data
        [(Word dst (Var src) index ty)
          (and
            (= dst 31)
            (= src 30)
            (= index 0)
            (match ty
              [(U64) true]
              [_ false]))]
        [_ false])
      (match length
        [(Word dst (Var src) index ty)
          (and
            (= dst 32)
            (= src 30)
            (= index 1)
            (match ty
              [(I64) true]
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
          [(Var id) (= id want-var)]
          [_ false])))))

(define (compiler-ir-phi-input-dense-order-ok?) : bool
  (let
    [inputs : compiler_ir_types.CompilerIrPhiInputSeq
      (compiler_ir_types.compiler-ir-phi-input-seq-prepend
        (Var 10)
        (compiler_ir_types.compiler-ir-label "entry")
        (compiler_ir_types.compiler-ir-phi-input-seq-prepend
          (Var 20)
          (compiler_ir_types.compiler-ir-label "loop")
          (compiler_ir_types.compiler-ir-phi-input-seq-empty)))]
    [cloned : compiler_ir_types.CompilerIrPhiInputSeq
      (match (compiler_ir_types.compiler-ir-clone-instr
        (ast.ast-node-pool-reader-context-current)
        (Phi 1 (compiler_ir_types.compiler-ir-global-shared-view inputs) (I64)))
        [(Phi _ cloned-inputs _) cloned-inputs]
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
      (= (compiler_ir_types.compiler-ir-phi-input-seq-count inputs) 2)
      (compiler-ir-phi-input-seq-entry-var-label?
        (compiler_ir_types.compiler-ir-global-shared-view inputs)
        0
        10
        "entry")
      (compiler-ir-phi-input-seq-entry-var-label? inputs 1 20 "loop")
      (compiler-ir-phi-input-seq-entry-var-label? cloned 0 10 "entry")
      (= (compiler_ir_types.compiler-ir-phi-input-seq-count tail) 1)
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
      [(Case tag label)
        (and
          (= tag want-tag)
          (string.eq
            (compiler_ir_types.compiler-ir-label-text label)
            want-label))])))

(define (compiler-ir-switch-case-dense-order-ok?) : bool
  (let
    [builder : compiler_ir_types.CompilerIrSwitchCaseBuilder
      (compiler_ir_types.compiler-ir-switch-case-builder-with-capacity 1)]
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
          (Switch
            (I64 0)
            0
            (compiler_ir_types.compiler-ir-global-shared-view cases)
            (compiler_ir_types.compiler-ir-label "default")))
          [(Switch _ _ cloned-cases _) cloned-cases]
          [_ (compiler-ir-switch-case-seq-empty)])]
      (and
        (= (compiler_ir_types.compiler-ir-switch-case-seq-count cases) 2)
        (string.eq
          (compiler_ir_types.compiler-ir-switch-case-seq-render cases)
          "4:four, 5:five")
        (compiler-ir-switch-case-seq-entry-tag-label? cases 0 4 "four")
        (compiler-ir-switch-case-seq-entry-tag-label? cases 1 5 "five")
        (compiler-ir-switch-case-seq-entry-tag-label? cloned 0 4 "four")
        (compiler-ir-switch-case-seq-entry-tag-label? cloned 1 5 "five")))))

(define (compiler-ir-instr-seq-dense-construction-ok?) : bool
  (let
    [seq : compiler_ir_types.CompilerIrInstrSeq
      (compiler_ir_types.compiler-ir-instr-seq3
        (Mov 1 (I64 10) (I64))
        (Mov 2 (I64 20) (I64))
        (Return (Some (Var 2))))]
    [block-list : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-blocks
        (compiler_ir_types.compiler-ir-block
          (compiler_ir_types.compiler-ir-label "entry")
          (compiler_ir_types.compiler-ir-global-shared-view seq)))]
    [compact-blocks : compiler_ir_types.CompilerIrBlockList
      (compiler_ir_types.compiler-ir-global-shared-view block-list)]
    (and
      (= (compiler_ir_types.compiler-ir-instr-seq-count seq) 3)
      (not (compiler_ir_types.compiler-ir-instr-seq-empty? seq))
      (match (compiler_ir_types.compiler-ir-instr-seq-ref seq 2)
        [(Return _) true]
        [_ false])
      (=
        (compiler_ir_types.compiler-ir-block-list-instruction-count block-list)
        3)
      (= (compiler_ir_types.compiler-ir-block-list-count compact-blocks) 1)
      (compiler-ir-block-list-first-label?
        (compiler_ir_types.compiler-ir-block-list-view compact-blocks)
        "entry")
      (compiler-ir-instr-seq-mov-dst? seq 0 1))))

(define (compiler-ir-effect-self-test) : i64
  (unless (compiler-ir-instruction-effects-ok?) (return 1))
  (unless (compiler-ir-vector-mask-effects-ok?) (return 1))
  (unless (compiler-ir-effect-predicates-ok?) (return 1))
  (unless (compiler-ir-fault-rows-ok?) (return 1))
  (unless (compiler-ir-display-self-test-ok?) (return 1))
  (unless (compiler-ir-tail-call-render-ok?) (return 1))
  (unless (compiler-ir-switch-render-ok?) (return 1))
  (unless (compiler-ir-source-spans-entry-list-ok?) (return 1))
  (unless (compiler-ir-source-spans-entry-strides-pinned?) (return 1))
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
  42)

(define (main) : i64
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
  (unless (compiler-ir-smoke-label-table-growth-ok?) (return 28))
  (let
    [representation-failure : i64
      (compiler-ir-smoke-representation-index-failure)]
    (unless (= representation-failure 0) (return (+ 11 representation-failure))))
  (unless (compiler-ir-smoke-store-owned-ok?) (return 21))
  (unless (compiler-ir-smoke-call-arg-map-visit-ok?) (return 22))
  (unless (compiler-ir-smoke-spmd-map-visit-ok?) (return 23))
  (unless (compiler-ir-smoke-value-seq-map-visit-ok?) (return 24))
  (unless (= (compiler-ir-smoke-operand-api-failure) 0) (return 25))
  (let
    [private-abi-failure : i64 (compiler-ir-smoke-spmd-private-abi-failure)]
    (unless (= private-abi-failure 0) (return (+ 100 private-abi-failure))))
  (compiler-ir-effect-self-test))