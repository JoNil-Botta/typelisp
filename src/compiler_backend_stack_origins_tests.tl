(import compiler_backend as backend)
(import compiler_backend_text_origins as origins)
(import compiler_regalloc as regalloc)
(import compiler_backend_home_origins as home_origins)
(import compiler_liveness as live)
(import compiler_ir_types as ir)
(import compiler_ir_text as ir_text)
(import compiler_ast_types as ast)
(import compiler_stack_traffic as traffic)
(import compiler_intern as ci)
(import compiler_abi as cabi)
(import compiler_builtin_ids as builtin_ids)
(import compiler_profile_state as profile_state)
(import compiler_diagnostic as diagnostic)
(import compiler_owned_view as owned_view)
(import stdlib.test)
(import stdlib.string)
(import stdlib.io)
(import stdlib.iterator)
(import stdlib.text_buf)

(define (backend-stack-origin-read
  [state : backend.CompilerBackendState]
  [homes : regalloc.CompilerRegAssignmentTable]
  [var : i64]) : String
  (match (backend.compiler-backend-vector-register-use
    homes
    (Var var)
    "fixture"
    "ymm"
    (& (ast.AstType.F32))
    "%ymm14"
    state)
    [(Err message) (io.panic message)]
    [(Ok use)
      (match use
        [(Use text _) text])]))

(define (backend-stack-origins-install-test-plan!
  [state : backend.CompilerBackendState]
  [color? : bool]
  [mask? : bool]) : unit
  (let
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    [block : i64
      (backend.compiler-backend-function-state-i64
        function-state
        backend.compiler-backend-function-i64-current-block-label)]
    [instructions : (__tl_dyn-array ir.CompilerIrInstr)
      (__tl_make-array ir.CompilerIrInstr 3)]
    [blocks : (__tl_dyn-array ir.CompilerIrBlock)
      (__tl_make-array ir.CompilerIrBlock 1)]
    [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
    (if mask?
      (begin
        (set! (array-ref instructions 0) (TailMask 7 (I64 0) (I64 64) 64))
        (set! (array-ref instructions 1) (TailMask 9 (I64 0) (I64 64) 64))
        (set! (array-ref instructions 2) (MaskBinOp 8 (And) (Var 7) (Var 9) 64)))
      (begin
        (set! (array-ref instructions 0) (Splat 7 (I64 1) 4 (I64)))
        (set! (array-ref instructions 1) (Splat 9 (I64 2) 4 (I64)))
        (set!
          (array-ref instructions 2)
          (VectorBinOp
            (box
              (ir.CompilerIrInstrVectorBinOpPayload
                8
                (Add)
                (Var 7)
                (Var 9)
                4
                (I64)))))))
    (set!
      (array-ref blocks 0)
      (Block block (ir.CompilerIrInstrSeq instructions 3)))
    (for [index (iterator.range 0 10)]
      (set! (array-ref map index) index))
    (when
      color?
      (set! (array-ref map 7) 1)
      (set! (array-ref map 8) 1)
      (set! (array-ref map 9) 2))
    (let
      [original : ir.CompilerIrBlockList
        (Array (ir.CompilerIrBlockSeq blocks 1))]
      [placed : ir.CompilerIrBlockList
        (regalloc.compiler-reg-remap-blocks (& map) (& original))]
      [input : home_origins.CompilerBackendHomePlanInput
        (home_origins.CompilerBackendHomePlanInput
          (backend.compiler-backend-function-scratch-i64
            function-state
            backend.compiler-backend-scratch-i64-current-source-function)
          10
          10
          (ir.compiler-ir-param-seq-empty)
          original
          placed
          (Remap map 10)
          (live.compiler-live-set-empty))]
      (match (home_origins.compiler-backend-home-plan-build (& input))
        [(Ok result)
          (backend.compiler-backend-stack-home-plan-install!
            function-state
            result)]
        [(Err message) (io.panic message)]))
    (backend.compiler-backend-function-state-set-emit-current-site!
      function-state
      2)))

(define (backend-stack-origins-colored-test) : unit
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    [home : regalloc.CompilerRegAssignment
      (regalloc.CompilerRegAssignment 1 (Spill -64))]
    [assignments : regalloc.CompilerRegAssignmentTable
      (regalloc.compiler-reg-assignments-prepend
        (& home)
        (regalloc.compiler-reg-assignment-table-empty))]
    (backend.compiler-backend-function-scratch-set-i64!
      function-state
      backend.compiler-backend-scratch-i64-current-source-function
      44)
    (backend.compiler-backend-function-state-set-i64!
      function-state
      backend.compiler-backend-function-i64-current-block-label
      10)
    (backend.compiler-backend-state-stack-origins-begin! state)
    (backend-stack-origins-install-test-plan! state true false)
    (let
      [read : String
        (backend-stack-origin-read
          state
          (owned_view.compiler-owned-shared-view assignments)
          1)]
      [write : String
        (backend.compiler-backend-vector-store-dst
          assignments
          1
          "ymm"
          (ast.AstType.F32)
          "%ymm14"
          state)]
      [accesses : origins.CompilerBackendStackAccessOriginList
        (backend.compiler-backend-state-stack-access-origins state)]
      (test.assert-string-eq
        read
        "    vmovups -64(%rbp), %ymm14\n"
        "colored read bytes")
      (test.assert-string-eq
        write
        "    vmovups %ymm14, -64(%rbp)\n"
        "colored write bytes")
      (test.assert-i64-eq accesses.len 2 "two accesses share the emitted color")
      (test.assert-i64-eq
        (array-ref accesses.slots 0).home
        7
        "original read home")
      (test.assert-i64-eq
        (array-ref accesses.slots 1).home
        8
        "original write home")
      (test.assert-i64-eq
        (array-ref accesses.slots 0).home-bytes
        32
        "original allocation capacity"))
    (backend.compiler-backend-clear-function-owned-state! state)
    (test.assert-i64-eq
      (backend.compiler-backend-function-scratch-i64
        function-state
        backend.compiler-backend-scratch-i64-stack-home-plan)
      0
      "cleanup clears scratch plan before retirement")
    (backend.compiler-backend-state-release-final-arenas! state)))

(test
  backend-stack-origins-retain-pre-color-identities
  (backend-stack-origins-colored-test))

(define (backend-stack-origins-mask-test) : unit
  (for [width (iterator.range 0 3)]
    (let
      [lanes : i64
        (if (= width 0)
          16
          (if (= width 1)
            32
            64))]
      [bytes : i64
        (if (= width 0)
          2
          (if (= width 1)
            4
            8))]
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
      [function-state : backend.CompilerBackendFunctionState
        (backend.compiler-backend-state-function-state state)]
      [assignment : regalloc.CompilerRegAssignment
        (regalloc.CompilerRegAssignment 1 (Spill -64))]
      [homes : regalloc.CompilerRegAssignmentTable
        (regalloc.compiler-reg-assignments-prepend
          (& assignment)
          (regalloc.compiler-reg-assignment-table-empty))]
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        10)
      (backend.compiler-backend-state-stack-origins-begin! state)
      (backend-stack-origins-install-test-plan! state true true)
      (let
        [read : String
          (match (backend.compiler-backend-avx512-mask-source-into-gpr
            (owned_view.compiler-owned-shared-view homes)
            (Var 1)
            "fixture"
            lanes
            (if (= width 2)
              "%rax"
              "%eax")
            state)
            [(Err message) (io.panic message)]
            [(Ok use)
              (match use
                [(Use text _) text])])]
        [write : String
          (backend.compiler-backend-avx512-mask-store-dst
            homes
            1
            lanes
            "%k7"
            state)]
        [capture : origins.CompilerBackendTextOrigins
          (backend.compiler-backend-state-stack-text-origins state)]
        [spelling : String
          (string.concat
            "kmov"
            (if (= width 0)
              "w"
              (if (= width 1)
                "d"
                "q")))]
        [accesses : origins.CompilerBackendStackAccessOriginList
          (backend.compiler-backend-state-stack-access-origins state)]
        (test.assert-string-eq
          read
          (string.concat5
            "    "
            (owned_view.compiler-owned-shared-view spelling)
            " -64(%rbp), %k7\n    "
            (owned_view.compiler-owned-shared-view spelling)
            (if (= width 2)
              " %k7, %rax\n"
              " %k7, %eax\n"))
          "captured compact mask load and parent bytes")
        (test.assert-string-eq
          write
          (string.concat3 "    " spelling " %k7, -64(%rbp)\n")
          "captured compact mask store bytes")
        (test.assert-i64-eq
          accesses.len
          2
          "both mask operands carry typed origins")
        (test.assert-i64-eq
          (array-ref accesses.slots 0).home
          7
          "pre-color mask read")
        (test.assert-i64-eq
          (array-ref accesses.slots 1).home
          8
          "pre-color mask write")
        (for [index (iterator.range 0 2)]
          (let
            [origin : (& accesses origins.CompilerBackendStackAccessOrigin)
              (& (array-ref accesses.slots index))]
            (test.assert-i64-eq origin.home-bytes 32 "planned mask reservation")
            (test.assert-i64-eq
              origin.access-bytes
              bytes
              "actual compact mask access")
            (test.assert-true
              (match (& origin.bank)
                [(Mask) true]
                [_ false])
              "typed mask bank")))
        (test.assert-i64-eq
          (array-length
            (origins.compiler-backend-text-origins-find capture (& read)))
          1
          "mask load identity survives GPR parent")
        (test.assert-i64-eq
          (array-length
            (origins.compiler-backend-text-origins-find capture (& write)))
          1
          "mask store identity survives renderer"))
      (backend.compiler-backend-state-release-final-arenas! state))))

(test
  backend-stack-origins-cover-compact-mask-homes
  (backend-stack-origins-mask-test))

(define (backend-stack-origins-splat-test) : unit
  (for [kind (iterator.range 0 10)]
    (let
      [ty : ast.AstType
        (match kind
          [0 (F64)]
          [1 (F32)]
          [2 (I32)]
          [3 (U32)]
          [4 (I16)]
          [5 (U16)]
          [6 (I8)]
          [7 (U8)]
          [8 (I64)]
          [_ (U64)])]
      [bytes : i64
        (cond
          [(< kind 1) 8]
          [(< kind 4) 4]
          [(< kind 6) 2]
          [(< kind 8) 1]
          [else 8])]
      [mnemonic : String
        (cond
          [(= kind 0) "vbroadcastsd"]
          [(= kind 1) "vbroadcastss"]
          [(< kind 4) "vpbroadcastd"]
          [(< kind 6) "vpbroadcastw"]
          [(< kind 8) "vpbroadcastb"]
          [else "vpbroadcastq"])]
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
      [function-state : backend.CompilerBackendFunctionState
        (backend.compiler-backend-state-function-state state)]
      [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
      [params : (__tl_dyn-array ir.CompilerIrParam)
        (__tl_make-array ir.CompilerIrParam 1)]
      [blocks : (__tl_dyn-array ir.CompilerIrBlock)
        (__tl_make-array ir.CompilerIrBlock 1)]
      [assignment : regalloc.CompilerRegAssignment
        (regalloc.CompilerRegAssignment 1 (Spill -64))]
      [homes : regalloc.CompilerRegAssignmentTable
        (regalloc.compiler-reg-assignments-prepend
          (& assignment)
          (regalloc.compiler-reg-assignment-table-empty))]
      (for [var (iterator.range 0 10)]
        (set! (array-ref map var) var))
      (set! (array-ref map 7) 1)
      (set! (array-ref map 8) 2)
      (set! (array-ref params 0) (Param "arg" (clone ty) 7))
      (set!
        (array-ref blocks 0)
        (Block 10 (ir.compiler-ir-instr-seq1 (Splat 8 (Var 7) 4 (clone ty)))))
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        10)
      (backend.compiler-backend-function-state-set-emit-current-site!
        function-state
        0)
      (backend.compiler-backend-state-stack-origins-begin! state)
      (let
        [original : ir.CompilerIrBlockList
          (Array (ir.CompilerIrBlockSeq blocks 1))]
        [placed : ir.CompilerIrBlockList
          (regalloc.compiler-reg-remap-blocks (& map) (& original))]
        [input : home_origins.CompilerBackendHomePlanInput
          (home_origins.CompilerBackendHomePlanInput
            44
            10
            10
            (ir.CompilerIrParamSeq params 1)
            original
            placed
            (Remap map 10)
            (live.compiler-live-set-empty))]
        (match (home_origins.compiler-backend-home-plan-build (& input))
          [(Ok result)
            (backend.compiler-backend-stack-home-plan-install!
              function-state
              result)]
          [(Err message) (io.panic message)]))
      (let
        [prefix : String
          (match (backend.compiler-backend-splat-memory-load
            (owned_view.compiler-owned-shared-view homes)
            (Var 1)
            (& ty)
            state)
            [(Some text) text]
            [_ (io.panic "scalar stack broadcast refused")])]
        [parent : String
          (match (backend.compiler-backend-avx2-vector-prefix-numeric-carry
            homes
            (Var 1)
            (clone ty)
            "%xmm2"
            state)
            [(Ok text) text]
            [(Err _) (io.panic "broadcast parent refused")])]
        [capture : origins.CompilerBackendTextOrigins
          (backend.compiler-backend-state-stack-text-origins state)]
        [accesses : origins.CompilerBackendStackAccessOriginList
          (backend.compiler-backend-state-stack-access-origins state)]
        (test.assert-string-eq
          prefix
          (string.concat3 "    " (clone mnemonic) " -64(%rbp), ")
          "scalar broadcast prefix bytes")
        (test.assert-string-eq
          parent
          (string.concat3 "    " mnemonic " -64(%rbp), %ymm2\n")
          "broadcast parent exact bytes")
        (test.assert-i64-eq
          accesses.len
          2
          "one scalar read per actual emitter call")
        (for [index (iterator.range 0 2)]
          (let
            [access : (& accesses origins.CompilerBackendStackAccessOrigin)
              (& (array-ref accesses.slots index))]
            (test.assert-i64-eq access.home 7 "scalar pre-color home")
            (test.assert-i64-eq
              access.home-bytes
              8
              "scalar allocation capacity")
            (test.assert-i64-eq
              access.access-bytes
              bytes
              "scalar memory read width")
            (test.assert-true
              (match (& access.access)
                [(Read) true]
                [_ false])
              "broadcast reads its home")
            (test.assert-true
              (match (& access.bank)
                [(Vector) (< kind 2)]
                [(General) (>= kind 2)]
                [_ false])
              "bank comes from scalar operand type")))
        (test.assert-i64-eq
          (array-length
            (origins.compiler-backend-text-origins-find capture (& prefix)))
          1
          "partial instruction preserves read identity")
        (test.assert-i64-eq
          (array-length
            (origins.compiler-backend-text-origins-find capture (& parent)))
          1
          "completed broadcast preserves read identity")
        (test.assert-true
          (match (backend.compiler-backend-splat-memory-load
            (regalloc.compiler-reg-assignment-table-empty)
            (I64 1)
            (& ty)
            state)
            [(No) true]
            [_ false])
          "literal is not a stack read")
        (test.assert-i64-eq
          (backend.compiler-backend-state-stack-access-origins state).len
          2
          "refused non-memory input publishes nothing"))
      (backend.compiler-backend-state-release-final-arenas! state))))

(test
  backend-stack-origins-cover-scalar-broadcasts
  (backend-stack-origins-splat-test))

(define (backend-stack-origins-install-scalar-plan!
  [state : backend.CompilerBackendState]
  [block : i64]
  [ty : ast.AstType]) : unit
  (let
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
    [params : (__tl_dyn-array ir.CompilerIrParam)
      (__tl_make-array ir.CompilerIrParam 3)]
    [blocks : (__tl_dyn-array ir.CompilerIrBlock)
      (__tl_make-array ir.CompilerIrBlock 3)]
    (for [var (iterator.range 0 10)]
      (set! (array-ref map var) var))
    (set! (array-ref map 7) 1)
    (set! (array-ref map 8) 1)
    (set! (array-ref params 0) (Param "arg" (clone ty) 7))
    (set!
      (array-ref blocks 0)
      (Block block (ir.compiler-ir-instr-seq1 (Mov 8 (Var 7) ty))))
    (let
      [original : ir.CompilerIrBlockList
        (Array (ir.CompilerIrBlockSeq blocks 1))]
      [placed : ir.CompilerIrBlockList
        (regalloc.compiler-reg-remap-blocks (& map) (& original))]
      [input : home_origins.CompilerBackendHomePlanInput
        (home_origins.CompilerBackendHomePlanInput
          (backend.compiler-backend-function-scratch-i64
            function-state
            backend.compiler-backend-scratch-i64-current-source-function)
          10
          10
          (ir.CompilerIrParamSeq params 1)
          original
          placed
          (Remap map 10)
          (live.compiler-live-set-empty))]
      (match (home_origins.compiler-backend-home-plan-build (& input))
        [(Ok result)
          (backend.compiler-backend-stack-home-plan-install!
            function-state
            result)]
        [(Err message) (io.panic message)]))))

(define (backend-stack-origins-parameter-test) : unit
  (let
    [plain : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    (test.assert-true
      (match (backend.compiler-backend-parameter-origins-begin! plain)
        [(None) true]
        [_ false])
      "inactive entry capture is empty")
    (test.assert-string-eq
      (backend.compiler-backend-incoming-stack-operand-origin
        plain
        "16(%rbp)"
        0
        (General)
        8)
      "16(%rbp)"
      "inactive incoming factory preserves bytes")
    (test.assert-true
      (not (backend.compiler-backend-state-function-state-active? plain))
      "inactive entry context does not allocate function state")
    (backend.compiler-backend-state-release-final-arenas! plain))
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    (backend.compiler-backend-function-scratch-set-i64!
      function-state
      backend.compiler-backend-scratch-i64-current-source-function
      44)
    (backend.compiler-backend-function-state-set-i64!
      function-state
      backend.compiler-backend-function-i64-current-block-label
      30)
    (backend.compiler-backend-function-state-set-emit-current-site!
      function-state
      0)
    (backend.compiler-backend-state-stack-origins-begin! state)
    (backend-stack-origins-install-scalar-plan! state 10 (I64))
    (let
      [entry : backend.CompilerBackendParameterOriginsContext
        (backend.compiler-backend-parameter-origins-begin! state)]
      [nested : backend.CompilerBackendParameterOriginsContext
        (backend.compiler-backend-parameter-origins-begin! state)]
      [entry-text : String
        (backend.compiler-backend-stack-operand-origin
          state
          "-64(%rbp)"
          (backend.CompilerBackendStackOperandRequest
            1
            8
            (General)
            (Write)
            (Whole)
            (Value)))]
      (backend.compiler-backend-parameter-origins-end! state nested)
      (test.assert-true
        (backend.compiler-backend-function-scratch-bool?
          function-state
          backend.compiler-backend-scratch-bool-parameter-origins)
        "nested entry restoration keeps outer authority")
      (backend.compiler-backend-parameter-origins-end! state entry)
      (test.assert-i64-eq
        (backend.compiler-backend-function-state-i64
          function-state
          backend.compiler-backend-function-i64-current-block-label)
        30
        "entry context restores prior block")
      (test.assert-true
        (not
          (backend.compiler-backend-function-scratch-bool?
            function-state
            backend.compiler-backend-scratch-bool-parameter-origins))
        "entry context restores body authority")
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        10)
      (let
        [body-text : String
          (backend.compiler-backend-stack-operand-origin
            state
            "-64(%rbp)"
            (backend.CompilerBackendStackOperandRequest
              1
              8
              (General)
              (Write)
              (Whole)
              (Value)))]
        [facts : origins.CompilerBackendStackAccessOriginList
          (backend.compiler-backend-state-stack-access-origins state)]
        (test.assert-string-eq
          entry-text
          body-text
          "same emitted parameter/body address")
        (test.assert-i64-eq facts.len 2 "two explicitly scoped writes")
        (test.assert-i64-eq
          (array-ref facts.slots 0).home
          7
          "incoming parameter identity")
        (test.assert-i64-eq
          (array-ref facts.slots 1).home
          8
          "body definition identity")
        (test.assert-i64-eq
          (match (& (array-ref facts.slots 0).anchor)
            [(SourceBlock block) block]
            [_ -1])
          10
          "entry block attribution")))
    (let
      [entry : backend.CompilerBackendParameterOriginsContext
        (backend.compiler-backend-parameter-origins-begin! state)]
      [incoming : String
        (backend.compiler-backend-incoming-stack-operand-origin
          state
          "16(%rbp)"
          0
          (General)
          8)]
      [facts : origins.CompilerBackendStackAccessOriginList
        (backend.compiler-backend-state-stack-access-origins state)]
      [fact : (& facts origins.CompilerBackendStackAccessOrigin)
        (& (array-ref facts.slots 2))]
      (test.assert-i64-eq facts.len 3 "source entry has a distinct ABI read")
      (test.assert-i64-eq fact.function.value 44 "source function authority")
      (test.assert-i64-eq
        fact.home
        30
        "incoming area cannot alias a colored local")
      (test.assert-true
        (match (& fact.anchor)
          [(FunctionParameters) true]
          [_ false])
        "source incoming area uses parameter authority")
      (test.assert-i64-eq
        (array-length
          (origins.compiler-backend-text-origins-find
            (backend.compiler-backend-state-stack-text-origins state)
            (& incoming)))
        1
        "source ABI operand retains its token")
      (backend.compiler-backend-parameter-origins-end! state entry))
    (backend.compiler-backend-state-release-final-arenas! state)))

(test
  backend-stack-origins-distinguish-entry-parameter-authority
  (backend-stack-origins-parameter-test))

(define (backend-stack-origins-float-test) : unit
  (for [kind (iterator.range 0 2)]
    (for [fallback (iterator.range 0 2)]
      (let
        [ty : ast.AstType
          (if (= kind 0)
            (F32)
            (F64))]
        [mov : String
          (if (= kind 0)
            "movss"
            "movsd")]
        [bytes : i64
          (if (= kind 0)
            4
            8)]
        [address : String
          (if (= fallback 0)
            "-64(%rbp)"
            "-16(%rbp)")]
        [state : backend.CompilerBackendState
          (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
        [function-state : backend.CompilerBackendFunctionState
          (backend.compiler-backend-state-function-state state)]
        [assignment : regalloc.CompilerRegAssignment
          (regalloc.CompilerRegAssignment 1 (Spill -64))]
        [homes : regalloc.CompilerRegAssignmentTable
          (if (= fallback 0)
            (regalloc.compiler-reg-assignments-prepend
              (& assignment)
              (regalloc.compiler-reg-assignment-table-empty))
            (regalloc.compiler-reg-assignment-table-empty))]
        [plain-read : String
          (backend.compiler-backend-emit-load-float-var
            (owned_view.compiler-owned-shared-view homes)
            1
            (clone ty)
            "%xmm2"
            state)]
        [plain-write : String
          (backend.compiler-backend-emit-store-float-var
            (owned_view.compiler-owned-shared-view homes)
            1
            "%xmm2"
            (& ty)
            state)]
        [plain-folded : String
          (backend.compiler-backend-float-value-memory-operand
            (owned_view.compiler-owned-shared-view homes)
            (Var 1)
            (& ty)
            state)]
        (test.assert-i64-eq
          (backend.compiler-backend-state-stack-access-origins state).len
          0
          "inactive scalar emission needs no home plan or origin list")
        (backend.compiler-backend-function-scratch-set-i64!
          function-state
          backend.compiler-backend-scratch-i64-current-source-function
          44)
        (backend.compiler-backend-function-state-set-i64!
          function-state
          backend.compiler-backend-function-i64-current-block-label
          10)
        (backend.compiler-backend-function-state-set-emit-current-site!
          function-state
          0)
        (backend.compiler-backend-state-stack-origins-begin! state)
        (backend-stack-origins-install-scalar-plan! state 10 (clone ty))
        (let
          [read : String
            (backend.compiler-backend-emit-load-float-var
              (owned_view.compiler-owned-shared-view homes)
              1
              (clone ty)
              "%xmm2"
              state)]
          [write : String
            (backend.compiler-backend-emit-store-float-var
              (owned_view.compiler-owned-shared-view homes)
              1
              "%xmm2"
              (& ty)
              state)]
          [entry : backend.CompilerBackendParameterOriginsContext
            (backend.compiler-backend-parameter-origins-begin! state)]
          [entry-write : String
            (backend.compiler-backend-emit-store-float-var
              (owned_view.compiler-owned-shared-view homes)
              1
              "%xmm2"
              (& ty)
              state)]
          (backend.compiler-backend-parameter-origins-end! state entry)
          (let
            [folded : String
              (backend.compiler-backend-float-value-memory-operand
                homes
                (Var 1)
                (& ty)
                state)]
            [capture : origins.CompilerBackendTextOrigins
              (backend.compiler-backend-state-stack-text-origins state)]
            [facts : origins.CompilerBackendStackAccessOriginList
              (backend.compiler-backend-state-stack-access-origins state)]
            (test.assert-string-eq
              read
              plain-read
              "capture preserves scalar load")
            (test.assert-string-eq
              write
              plain-write
              "capture preserves scalar store")
            (test.assert-string-eq
              folded
              plain-folded
              "capture preserves folded scalar")
            (test.assert-string-eq
              read
              (string.concat5
                "    "
                (clone mov)
                " "
                (clone address)
                ", %xmm2\n")
              "scalar floating load exact bytes")
            (test.assert-string-eq
              write
              (string.concat5 "    " mov " %xmm2, " (clone address) "\n")
              "scalar floating store exact bytes")
            (test.assert-string-eq
              entry-write
              write
              "entry initialization exact bytes")
            (test.assert-string-eq
              folded
              address
              "folded scalar floating operand")
            (test.assert-i64-eq
              facts.len
              4
              "one typed record per actual operand")
            (for [index (iterator.range 0 4)]
              (let
                [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                  (& (array-ref facts.slots index))]
                (test.assert-i64-eq
                  fact.home
                  (if (= index 1)
                    8
                    7)
                  "entry and body use their own pre-color identities")
                (test.assert-i64-eq
                  fact.home-bytes
                  8
                  "scalar floating home capacity")
                (test.assert-i64-eq
                  fact.access-bytes
                  bytes
                  "actual floating access width")
                (test.assert-true
                  (match (& fact.bank)
                    [(Vector) true]
                    [_ false])
                  "floating allocation bank")))
            (test.assert-i64-eq
              (array-length
                (origins.compiler-backend-text-origins-find capture (& read)))
              1
              "scalar load retains identity")
            (test.assert-i64-eq
              (array-length
                (origins.compiler-backend-text-origins-find capture (& write)))
              1
              "scalar store retains identity")
            (test.assert-i64-eq
              (array-length
                (origins.compiler-backend-text-origins-find
                  capture
                  (& entry-write)))
              1
              "entry store retains identity")
            (test.assert-i64-eq
              (array-length
                (origins.compiler-backend-text-origins-find capture (& folded)))
              1
              "folded operand retains identity")))
        (backend.compiler-backend-state-release-final-arenas! state)))))

(test
  backend-stack-origins-cover-scalar-floating-homes
  (backend-stack-origins-float-test))

(define (backend-stack-origins-producer-test) : unit
  (let
    [intern : ci.InternCompatState (ci.intern-compat-state-new)]
    [function : i64
      (ci.intern-compat-state-intern (&mut intern) "stack_origins")]
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new
        (owned_view.compiler-owned-shared-view intern))]
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    [block : i64 (ir.compiler-ir-label "emitter_block")]
    [first : regalloc.CompilerRegAssignment
      (regalloc.CompilerRegAssignment 7 (Spill -64))]
    [second : regalloc.CompilerRegAssignment
      (regalloc.CompilerRegAssignment 8 (Spill -64))]
    [homes : regalloc.CompilerRegAssignmentTable
      (regalloc.compiler-reg-assignments-prepend
        (& first)
        (regalloc.compiler-reg-assignments-prepend
          (& second)
          (regalloc.compiler-reg-assignment-table-empty)))]
    (backend.compiler-backend-function-scratch-set-i64!
      function-state
      backend.compiler-backend-scratch-i64-current-source-function
      function)
    (backend.compiler-backend-function-state-set-i64!
      function-state
      backend.compiler-backend-function-i64-current-block-label
      block)
    (let
      [plain : String
        (backend-stack-origin-read
          state
          (owned_view.compiler-owned-shared-view homes)
          7)]
      (test.assert-string-eq
        plain
        "    vmovups -64(%rbp), %ymm14\n"
        "inactive emitter bytes"))
    (test.assert-i64-eq
      (backend.compiler-backend-state-stack-access-origins state).len
      0
      "ordinary emission allocates no origin list")
    (backend.compiler-backend-state-stack-origins-begin! state)
    (backend-stack-origins-install-test-plan! state false false)
    (let
      [capture : origins.CompilerBackendTextOrigins
        (backend.compiler-backend-state-stack-text-origins state)]
      [read : String
        (backend-stack-origin-read
          state
          (owned_view.compiler-owned-shared-view homes)
          7)]
      [write : String
        (backend.compiler-backend-vector-store-dst
          (owned_view.compiler-owned-shared-view homes)
          8
          "ymm"
          (ast.AstType.F32)
          "%ymm14"
          state)]
      [text : String
        (origins.compiler-backend-text-origins-cat capture read write)]
      [accesses : origins.CompilerBackendStackAccessOriginList
        (backend.compiler-backend-state-stack-access-origins state)]
      [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
        (origins.compiler-backend-text-origins-find capture (& text))]
      (test.assert-string-eq
        text
        "    vmovups -64(%rbp), %ymm14\n    vmovups %ymm14, -64(%rbp)\n"
        "capture preserves actual emitter bytes")
      (test.assert-i64-eq
        accesses.len
        2
        "one snapshot per actual typed memory operand")
      (test.assert-i64-eq
        (array-ref accesses.slots 0).home
        7
        "read logical home before coloring")
      (test.assert-i64-eq
        (array-ref accesses.slots 1).home
        8
        "equal offset does not merge the write home")
      (test.assert-i64-eq
        (array-ref accesses.slots 0).function.value
        function
        "actual emitted function")
      (test.assert-i64-eq
        (match (& (array-ref accesses.slots 0).anchor)
          [(SourceBlock source) source]
          [_ -1])
        block
        "actual IR block identity")
      (test.assert-i64-eq
        (array-ref accesses.slots 0).access-bytes
        32
        "emitter-selected access width")
      (test.assert-i64-eq
        (array-ref accesses.slots 0).home-bytes
        32
        "capacity comes from the original allocation plan")
      (test.assert-true
        (match (& (array-ref accesses.slots 0).access)
          [(Read) true]
          [_ false])
        "read authority")
      (test.assert-true
        (match (& (array-ref accesses.slots 1).access)
          [(Write) true]
          [_ false])
        "write authority")
      (test.assert-true
        (match (& (array-ref accesses.slots 0).owner)
          [(Allocator) true]
          [_ false])
        "owner comes from the emitter")
      (test.assert-i64-eq
        (array-length spans)
        2
        "origins survive text construction")
      (test.assert-i64-eq (array-ref spans 0).token 0 "read snapshot binding")
      (test.assert-i64-eq (array-ref spans 1).token 1 "write snapshot binding")
      (match (backend.compiler-backend-vector-memory-or-register-use
        (owned_view.compiler-owned-shared-view homes)
        (Var 7)
        "fixture"
        "ymm"
        (& (ast.AstType.F32))
        state)
        [(Err message) (io.panic message)]
        [(Ok use)
          (match use
            [(Use _ operand)
              (test.assert-string-eq operand "-64(%rbp)" "folded memory source")
              (test.assert-i64-eq
                (array-length
                  (origins.compiler-backend-text-origins-find
                    capture
                    (& operand)))
                1
                "folded source carries its read identity")])])
      (let
        [fallback : String
          (backend-stack-origin-read
            state
            (regalloc.compiler-reg-assignment-table-empty)
            9)]
        (test.assert-string-eq
          fallback
          "    vmovups -80(%rbp), %ymm14\n"
          "unassigned vector home")
        (test.assert-i64-eq
          (backend.compiler-backend-state-stack-access-origins state).len
          4
          "fallback retains a separate allocator identity"))
      (match (backend.compiler-backend-emit-vector-copy
        (owned_view.compiler-owned-shared-view homes)
        8
        (Var 7)
        "ymm"
        (ast.AstType.F32)
        state)
        [(Err _) (io.panic "vector copy refused")]
        [(Ok copy)
          (let
            [copy-spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
              (origins.compiler-backend-text-origins-find capture (& copy))]
            (test.assert-string-eq
              copy
              "    vmovups -64(%rbp), %ymm14\n    vmovups %ymm14, %ymm15\n    vmovups %ymm15, -64(%rbp)\n"
              "higher-level builder preserves emitted bytes")
            (test.assert-i64-eq
              (array-length copy-spans)
              2
              "higher-level text construction preserves both access identities")
            (test.assert-i64-eq
              (array-ref copy-spans 0).token
              4
              "copy read binding")
            (test.assert-i64-eq
              (array-ref copy-spans 1).token
              5
              "copy write binding")
            (let
              [buf : backend.CompilerBackendAsmBuf
                (backend.compiler-backend-asm-buf-with-capacity 16)]
              [late : String
                (backend-stack-origin-read
                  state
                  (owned_view.compiler-owned-shared-view homes)
                  7)]
              [late-spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
                (origins.compiler-backend-text-origins-find capture (& late))]
              (backend.compiler-backend-asm-buf-capture! (&mut buf) capture)
              (backend.compiler-backend-asm-append (&mut buf) "A")
              (backend.compiler-backend-asm-append2 (&mut buf) "B" "C")
              (backend.compiler-backend-asm-append4 (&mut buf) "D" "E" "F" "G")
              (backend.compiler-backend-asm-append5
                (&mut buf)
                "H"
                "I"
                "J"
                "K"
                "L")
              (backend.compiler-backend-asm-append
                (&mut buf)
                (owned_view.compiler-owned-shared-view copy))
              (backend.compiler-backend-asm-buf-insert-at!
                (&mut buf)
                12
                (owned_view.compiler-owned-shared-view late))
              (let
                [text : String
                  (backend.compiler-backend-asm-buf-finish (& buf))]
                [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
                  (origins.compiler-backend-text-origins-find capture (& text))]
                [expected : String
                  (string.concat3-borrowed "ABCDEFGHIJKL" (& late) (& copy))]
                (test.assert-string-eq
                  text
                  expected
                  "buffer growth/appends/insertion preserve bytes")
                (test.assert-i64-eq
                  (array-length spans)
                  3
                  "all actual operand identities survive the body buffer")
                (test.assert-i64-eq
                  (array-ref spans 0).token
                  6
                  "late-issued prefix comes first in final text")
                (test.assert-i64-eq
                  (array-ref spans 1).token
                  4
                  "original read follows inserted access")
                (test.assert-i64-eq
                  (array-ref spans 2).token
                  5
                  "original write follows original read")
                (test.assert-i64-eq
                  (array-ref spans 0).start
                  (+ 12 (array-ref late-spans 0).start)
                  "inserted byte coordinate")
                (test.assert-i64-eq
                  (array-ref spans 1).start
                  (+
                    12
                    (+
                      (string.string-length (& late))
                      (array-ref copy-spans 0).start))
                  "shifted original coordinate"))))]))
    (backend.compiler-backend-state-release-final-arenas! state)
    (test.assert-true
      (= (backend.compiler-backend-state-stack-text-origins state).storage 0)
      "one-shot cleanup clears capture before retiring its arena")
    (test.assert-i64-eq
      (backend.compiler-backend-state-stack-access-origins state).len
      0
      "cleanup unpublishes origin views")))

(test
  backend-stack-origins-are-emitter-owned
  (backend-stack-origins-producer-test))

(define (backend-stack-origins-rebase-test) : unit
  (let
    [intern : ci.InternCompatState (ci.intern-compat-state-new)]
    [function : i64
      (ci.intern-compat-state-intern (&mut intern) "frame_origins")]
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new
        (owned_view.compiler-owned-shared-view intern))]
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    [read-home : regalloc.CompilerRegAssignment
      (regalloc.CompilerRegAssignment 7 (Spill -64))]
    [write-home : regalloc.CompilerRegAssignment
      (regalloc.CompilerRegAssignment 8 (Spill -64))]
    [homes : regalloc.CompilerRegAssignmentTable
      (regalloc.compiler-reg-assignments-prepend
        (& read-home)
        (regalloc.compiler-reg-assignments-prepend
          (& write-home)
          (regalloc.compiler-reg-assignment-table-empty)))]
    [push-regs : (__tl_dyn-array String)
      (backend.compiler-backend-rsp-rebase-make-push-regs)]
    (backend.compiler-backend-function-scratch-set-i64!
      function-state
      backend.compiler-backend-scratch-i64-current-source-function
      function)
    (backend.compiler-backend-function-state-set-i64!
      function-state
      backend.compiler-backend-function-i64-current-block-label
      (ir.compiler-ir-label "frame_block"))
    (backend.compiler-backend-state-stack-origins-begin! state)
    (backend-stack-origins-install-test-plan! state false false)
    (let
      [capture : origins.CompilerBackendTextOrigins
        (backend.compiler-backend-state-stack-text-origins state)]
      [read : String
        (backend-stack-origin-read
          state
          (owned_view.compiler-owned-shared-view homes)
          7)]
      [write : String
        (backend.compiler-backend-vector-store-dst
          (owned_view.compiler-owned-shared-view homes)
          8
          "ymm"
          (ast.AstType.F32)
          "%ymm14"
          state)]
      [body : String
        (origins.compiler-backend-text-origins-cat
          capture
          "frame_block:\n\n"
          read
          write
          "    leave\n    ret")]
      [plain : String (string.copy (& body))]
      (for [mode (iterator.range 0 2)]
        (let
          [expected : backend.CompilerBackendRspRebaseResult
            (backend.compiler-backend-rsp-rebase-full-result
              (owned_view.compiler-owned-shared-view plain)
              64
              (= mode 1)
              (owned_view.compiler-owned-shared-view push-regs)
              0
              9
              state)]
          [actual : backend.CompilerBackendRspRebaseResult
            (backend.compiler-backend-rsp-rebase-full-result
              (owned_view.compiler-owned-shared-view body)
              64
              (= mode 1)
              (owned_view.compiler-owned-shared-view push-regs)
              0
              9
              state)]
          [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
            (origins.compiler-backend-text-origins-find capture (& actual.text))]
          (test.assert-true actual.ok "audited frame/FPO text")
          (test.assert-string-eq
            actual.text
            expected.text
            "capture preserves exact rebase bytes")
          (test.assert-i64-eq
            (array-length spans)
            2
            "both equal-offset logical homes survive")
          (for [index (iterator.range 0 2)]
            (test.assert-i64-eq
              (array-ref spans index).token
              index
              "retarget preserves distinct tokens")
            (test.assert-string-eq
              (string.copy
                (string.substring-view
                  (& actual.text)
                  (array-ref spans index).start
                  (- (array-ref spans index).end (array-ref spans index).start)))
              (string.concat
                (string.int->string
                  (-
                    (backend.compiler-backend-frame-bias-neg
                      state
                      (= mode 1)
                      64
                      0)
                    64))
                "(%rsp)")
              "new operand spelling is bound to its old token"))))
      (let
        [unsafe-body : String
          (origins.compiler-backend-text-origins-cat
            capture
            "    syscall\n"
            body)]
        [rejected : backend.CompilerBackendRspRebaseResult
          (backend.compiler-backend-rsp-rebase-full-result
            (owned_view.compiler-owned-shared-view unsafe-body)
            64
            true
            push-regs
            0
            9
            state)]
        (test.assert-true
          (not rejected.ok)
          "failed FPO audit keeps original text")
        (test.assert-string-eq
          rejected.text
          unsafe-body
          "failed audit is transactional")
        (test.assert-i64-eq
          (array-length
            (origins.compiler-backend-text-origins-find
              capture
              (& rejected.text)))
          2
          "failed audit preserves original identities")))
    (backend.compiler-backend-state-release-final-arenas! state)))

(test
  backend-stack-origins-survive-frame-rebase
  (backend-stack-origins-rebase-test))

(define (backend-stack-origins-final-render-test) : unit
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [stream : backend.CompilerBackendStreamState
      (backend.compiler-backend-state-stream-state state)]
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [cold-operand : String
      (backend.compiler-backend-origin-invariant-text
        (origins.compiler-backend-text-origins-mark capture "-8(%rsp)" 101))]
    [hot-operand : String
      (backend.compiler-backend-origin-invariant-text
        (origins.compiler-backend-text-origins-mark capture "-8(%rsp)" 102))]
    [cold : String
      (origins.compiler-backend-text-origins-cat
        capture
        "    vmovups %ymm14, "
        cold-operand
        "\n")]
    [hot : String
      (origins.compiler-backend-text-origins-cat
        capture
        "    vmovups "
        hot-operand
        ", %ymm14\n")]
    [body : String
      (origins.compiler-backend-text-origins-cat
        capture
        ".text\n.globl f\n    .type f,@function\nf:\n    cmpq %r9, %rdi\n    jb .Lf_ok\n"
        cold
        "    call tl_oob_abort\n.Lf_ok:\n"
        hot
        "    ret\n    .size f, . - f\n")]
    [records : backend.CompilerBackendPeepholeLineVec
      (backend.compiler-backend-peephole-asm-once-records
        state
        stream
        body
        false)]
    [plan : backend.CompilerBackendColdPlan
      (backend.compiler-backend-cold-plan records)]
    [expected : String
      (backend.compiler-backend-peephole-records-render
        (owned_view.compiler-owned-shared-view records)
        (origins.compiler-backend-text-origins-disabled))]
    [actual : String
      (backend.compiler-backend-peephole-records-render records capture)]
    [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
      (origins.compiler-backend-text-origins-find capture (& actual))]
    (test.assert-i64-eq plan.stubs 1 "actual cold movement planned")
    (test.assert-string-eq
      actual
      expected
      "captured cold rendering preserves bytes")
    (test.assert-i64-eq
      (array-length spans)
      2
      "both moved and retained operands")
    (test.assert-i64-eq
      (array-ref spans 0).token
      102
      "hot access comes first after movement")
    (test.assert-i64-eq
      (array-ref spans 1).token
      101
      "cold access follows hot return")
    (for [index (iterator.range 0 2)]
      (test.assert-string-eq
        (string.copy
          (string.substring-view
            (& actual)
            (array-ref spans index).start
            (- (array-ref spans index).end (array-ref spans index).start)))
        "-8(%rsp)"
        "full final byte coordinate"))
    (backend.compiler-backend-peephole-records-retire! stream)
    (let
      [source : String
        (origins.compiler-backend-text-origins-cat
          capture
          "plain:\n"
          cold
          hot
          "    ret\n")]
      [records : backend.CompilerBackendPeepholeLineVec
        (backend.compiler-backend-peephole-asm-once-records
          state
          stream
          source
          false)]
      [replacement : String
        (origins.compiler-backend-text-origins-cat
          capture
          "    vmovups "
          hot-operand
          ", %ymm13")]
      [owned : backend.CompilerBackendPeepholeLine
        (backend.compiler-backend-peephole-owned-line
          state
          stream
          replacement
          true)]
      (test.assert-i64-eq records.len 4 "label/two accesses/return fixture")
      (set! (array-ref records.live 1) 0)
      (set!
        (array-ref records.lines 2)
        (backend.compiler-backend-peephole-line-record owned))
      (let
        [actual : String
          (backend.compiler-backend-peephole-records-render records capture)]
        [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
          (origins.compiler-backend-text-origins-find capture (& actual))]
        (test.assert-string-eq
          actual
          "plain:\n    vmovups -8(%rsp), %ymm13\n    ret\n"
          "deletion and owned-line newline are exact")
        (test.assert-i64-eq
          (array-length spans)
          1
          "deleted access leaves no final event")
        (test.assert-i64-eq
          (array-ref spans 0).token
          102
          "owned line retains explicit token"))
      (backend.compiler-backend-peephole-records-retire! stream))
    (origins.compiler-backend-text-origins-release! (&mut capture))
    (backend.compiler-backend-state-release-final-arenas! state)))

(test
  backend-stack-origins-follow-final-record-order
  (backend-stack-origins-final-render-test))

(define (backend-stack-origins-splice-clone-test) : unit
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [assignment : regalloc.CompilerRegAssignment
      (regalloc.CompilerRegAssignment 0 (Register cabi.compiler-reg-id-r12))]
    [homes : regalloc.CompilerRegAssignmentTable
      (regalloc.compiler-reg-assignments-prepend
        (& assignment)
        (regalloc.compiler-reg-assignment-table-empty))]
    (backend.compiler-backend-function-state-set-bool!
      (backend.compiler-backend-state-function-state state)
      backend.compiler-backend-function-bool-current-fn-win64
      true)
    (backend.compiler-backend-state-stack-origins-begin! state)
    (let
      [capture : origins.CompilerBackendTextOrigins
        (backend.compiler-backend-state-stack-text-origins state)]
      [save : String
        (backend.compiler-backend-origin-invariant-text
          (origins.compiler-backend-text-origins-mark capture "-16(%rbp)" 111))]
      [read : String
        (backend.compiler-backend-origin-invariant-text
          (origins.compiler-backend-text-origins-mark capture "-64(%rbp)" 112))]
      [hot : String
        (origins.compiler-backend-text-origins-cat
          capture
          "    vmovups "
          read
          ", %ymm14\n")]
      [body : String
        (origins.compiler-backend-text-origins-cat
          capture
          "    movq %r12, "
          save
          "\n"
          hot)]
      [described : String
        (match (backend.compiler-backend-windows-framed-save-splice
          (& body)
          0
          ""
          (owned_view.compiler-owned-shared-view homes)
          1
          64
          "f"
          (diagnostic.compiler-diagnostic-at-start "" "")
          state)
          [(Ok text) text]
          [(Err _) (io.panic "valid captured Windows save rejected")])]
      [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
        (origins.compiler-backend-text-origins-find capture (& described))]
      (test.assert-string-eq
        described
        "    movq %r12, -16(%rbp)\n    .seh_savereg %r12, 48\n    .seh_endprologue\n    vmovups -64(%rbp), %ymm14\n"
        "SEH insertion preserves actual source save and body bytes")
      (test.assert-i64-eq
        (array-length spans)
        2
        "SEH keeps both source annotations")
      (test.assert-i64-eq
        (array-ref spans 0).token
        111
        "save identity comes from actual source range")
      (test.assert-i64-eq
        (array-ref spans 1).token
        112
        "body survives save insertion")
      (test.assert-true
        (match (backend.compiler-backend-windows-framed-save-splice
          (& hot)
          0
          ""
          homes
          1
          64
          "f"
          (diagnostic.compiler-diagnostic-at-start "" "")
          state)
          [(Err _) true]
          [(Ok _) false])
        "invalid save sequence remains an error")
      (let
        [source : String
          (origins.compiler-backend-text-origins-cat
            capture
            ".Le:\n    jl .Lt\n.Lt:\n"
            hot
            "    ret\n")]
        [start : i64
          (backend.compiler-backend-string-find-from (& source) "    vmovups" 0)]
        [sites : (__tl_dyn-array i64) (__tl_make-array i64 1)]
        [ok : (__tl_dyn-array i64) (__tl_make-array i64 1)]
        (set!
          (array-ref sites 0)
          (backend.compiler-backend-string-find-from (& source) "\n.Lt:" 0))
        (set! (array-ref ok 0) 1)
        (let
          [tail : String
            (backend.compiler-backend-swb-dup-tail-body
              (& source)
              (unsafe
                (string-data source))
              start
              (string.string-length source)
              ".Lreturn"
              (&mut ok)
              capture)]
          [clone : String
            (origins.compiler-backend-text-origins-cat
              capture
              ".Lt__swb_tail:\n"
              tail
              "    ret\n")]
          [expected : String
            (backend.compiler-backend-swb-apply-dup
              (& source)
              (owned_view.compiler-owned-shared-view sites)
              1
              (owned_view.compiler-owned-shared-view clone)
              (origins.compiler-backend-text-origins-disabled))]
          [actual : String
            (backend.compiler-backend-swb-apply-dup
              (& source)
              sites
              1
              clone
              capture)]
          [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
            (origins.compiler-backend-text-origins-find capture (& actual))]
          (test.assert-i64-eq (array-ref ok 0) 1 "tail clone admitted")
          (test.assert-string-eq
            actual
            expected
            "explicit cloned text has exact ordinary bytes")
          (test.assert-i64-eq
            (array-length spans)
            2
            "original and cloned access survive")
          (test.assert-i64-eq
            (array-ref spans 0).token
            112
            "original source identity")
          (test.assert-i64-eq
            (array-ref spans 1).token
            112
            "clone retains same source identity")
          (test.assert-true
            (< (array-ref spans 0).start (array-ref spans 1).start)
            "cloned access has a distinct final position"))))
    (backend.compiler-backend-state-release-final-arenas! state)))

(test
  backend-stack-origins-survive-seh-and-tail-clone
  (backend-stack-origins-splice-clone-test))

(define (backend-stack-origins-rmw-case [live? : bool]) : unit
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [plain-state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [stream : backend.CompilerBackendStreamState
      (backend.compiler-backend-state-stream-state state)]
    [plain-stream : backend.CompilerBackendStreamState
      (backend.compiler-backend-state-stream-state plain-state)]
    (backend.compiler-backend-state-stack-origins-begin! state)
    (let
      [capture : origins.CompilerBackendTextOrigins
        (backend.compiler-backend-state-stack-text-origins state)]
      [read : String
        (backend.compiler-backend-origin-invariant-text
          (origins.compiler-backend-text-origins-record
            capture
            (origins.CompilerBackendStackAccessOrigin
              (ir.compiler-ir-symbol-typed-id 0)
              (SourceBlock 2)
              7
              8
              (Allocator)
              (General)
              8
              (Read))
            "-8(%rsp)"))]
      [write : String
        (backend.compiler-backend-origin-invariant-text
          (origins.compiler-backend-text-origins-record
            capture
            (origins.CompilerBackendStackAccessOrigin
              (ir.compiler-ir-symbol-typed-id 0)
              (SourceBlock 2)
              8
              8
              (Allocator)
              (General)
              8
              (Write))
            "-8(%rsp)"))]
      [source : String
        (origins.compiler-backend-text-origins-cat
          capture
          "f:\n    movq "
          read
          ", %r10\n    addq $1, %r10\n    movq %r10, "
          write
          "\n"
          (if live?
            "    movq %r10, %rax\n    ret\n"
            "    xorq %r10, %r10\n    ret\n"))]
      [plain-records : backend.CompilerBackendPeepholeLineVec
        (backend.compiler-backend-peephole-asm-once-records
          plain-state
          plain-stream
          (string.copy (& source))
          false)]
      [_plain-fold : unit
        (backend.compiler-backend-peephole-rmw-fold-candidates!
          plain-state
          plain-stream
          (owned_view.compiler-owned-shared-view plain-records))]
      [expected : String
        (backend.compiler-backend-peephole-records-render
          plain-records
          (origins.compiler-backend-text-origins-disabled))]
      [records : backend.CompilerBackendPeepholeLineVec
        (backend.compiler-backend-peephole-asm-once-records
          state
          stream
          source
          false)]
      [_fold : unit
        (backend.compiler-backend-peephole-rmw-fold-candidates!
          state
          stream
          (owned_view.compiler-owned-shared-view records))]
      [actual : String
        (backend.compiler-backend-peephole-records-render records capture)]
      [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
        (origins.compiler-backend-text-origins-find capture (& actual))]
      [accesses : origins.CompilerBackendStackAccessOriginList
        (origins.compiler-backend-text-origins-accesses capture)]
      (test.assert-string-eq
        actual
        expected
        "RMW capture has exact ordinary output")
      (test.assert-i64-eq
        (backend.compiler-backend-string-count
          (& actual)
          "    addq $1, -8(%rsp)\n")
        1
        "actual fold occurred")
      (test.assert-i64-eq
        (array-length spans)
        (if live?
          3
          2)
        "folded read/write plus optional readback")
      (test.assert-i64-eq
        (array-ref spans 0).token
        0
        "fold retains original read token")
      (test.assert-i64-eq
        (array-ref spans 1).token
        1
        "fold retains distinct original store token")
      (test.assert-i64-eq
        (array-ref spans 0).start
        (array-ref spans 1).start
        "one operand retains two logical accesses")
      (test.assert-i64-eq
        (array-ref spans 0).end
        (array-ref spans 1).end
        "overlapping spans are exact")
      (test.assert-i64-eq
        (array-ref accesses.slots 0).home
        7
        "load home remains distinct")
      (test.assert-i64-eq
        (array-ref accesses.slots 1).home
        8
        "store home remains distinct")
      (test.assert-i64-eq
        accesses.len
        (if live?
          3
          2)
        "only actual generated reload publishes a new access")
      (when
        live?
        (test.assert-i64-eq
          (array-ref spans 2).token
          2
          "readback has a new final access token")
        (test.assert-i64-eq
          (array-ref accesses.slots 2).home
          8
          "readback reads store home rather than old load home")
        (test.assert-true
          (match (& (array-ref accesses.slots 2).access)
            [(Read) true]
            [_ false])
          "readback is a read")
        (test.assert-true
          (< (array-ref spans 1).end (array-ref spans 2).start)
          "readback follows folded write"))
      (test.assert-true
        (match (origins.compiler-backend-text-origins-readback
          capture
          (& read)
          "-8(%rsp)")
          [(Err _) true]
          [_ false])
        "read-only origin cannot authorize readback")
      (test.assert-true
        (match (origins.compiler-backend-text-origins-merge-accesses
          capture
          (owned_view.compiler-owned-shared-view write)
          (owned_view.compiler-owned-shared-view read)
          "-8(%rsp)")
          [(Err _) true]
          [_ false])
        "wrong read/write directions reject")
      (test.assert-true
        (match (origins.compiler-backend-text-origins-merge-accesses
          capture
          read
          write
          "-8(%rsp)")
          [(Ok _) true]
          [_ false])
        "correct ordered source pair remains reusable")
      (test.assert-i64-eq
        (origins.compiler-backend-text-origins-accesses capture).len
        accesses.len
        "refused metadata does not publish orphan accesses"))
    (backend.compiler-backend-peephole-records-retire! stream)
    (backend.compiler-backend-peephole-records-retire! plain-stream)
    (backend.compiler-backend-state-release-final-arenas! state)
    (backend.compiler-backend-state-release-final-arenas! plain-state)))

(define (backend-stack-origins-rmw-test) : unit
  (backend-stack-origins-rmw-case false)
  (backend-stack-origins-rmw-case true))

(test
  backend-stack-origins-rmw-keeps-logical-homes
  (backend-stack-origins-rmw-test))

;; Invoke the production fused store, rather than expanding its local macro
;; across a module boundary.
(define (backend-stack-origins-site-context-test) : unit
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [index : backend.CompilerBackendProgramIndex
      (backend.compiler-backend-program-index-build-with-backend-state-and-profile-state
        state
        (ast.ast-node-pool-reader-type-segment-bases)
        (ir.compiler-ir-function-seq-empty)
        (ir.compiler-ir-extern-seq-empty)
        (profile_state.compiler-profile-state-new))]
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    [assignment : regalloc.CompilerRegAssignment
      (regalloc.CompilerRegAssignment
        0
        (Register (cabi.compiler-abi-register-id-from-spelling "%r12")))]
    [homes : regalloc.CompilerRegAssignmentTable
      (regalloc.compiler-reg-assignments-prepend
        (& assignment)
        (regalloc.compiler-reg-assignment-table-empty))]
    [plain : backend.ResultCompilerBackend
      (backend.compiler-backend-emit-store-to-gep
        (ast.ast-node-pool-reader-type-segment-bases)
        (owned_view.compiler-owned-shared-view homes)
        (Var 0)
        (I64 1)
        (F64)
        (& (Var 1))
        (& (F64))
        index
        0
        -1
        state)]
    (test.assert-true
      (match plain
        [(Ok _) true]
        [_ false])
      "disabled origin context needs no home plan")
    (backend.compiler-backend-state-stack-origins-begin! state)
    (backend.compiler-backend-function-scratch-set-i64!
      function-state
      backend.compiler-backend-scratch-i64-current-source-function
      44)
    (backend.compiler-backend-function-state-set-i64!
      function-state
      backend.compiler-backend-function-i64-current-block-label
      10)
    (backend-stack-origins-install-scalar-plan! state 10 (F64))
    (backend.compiler-backend-function-state-set-emit-current-site!
      function-state
      17)
    (for [kind (iterator.range 0 3)]
      (let
        [previous : i64
          (if (= kind 0)
            0
            1)]
        (backend.compiler-backend-function-scratch-set-i64!
          function-state
          backend.compiler-backend-scratch-i64-origin-site
          previous)
        (let
          [value : ir.CompilerIrValue
            (if (= kind 2)
              (Bool true)
              (Var 1))]
          [result : backend.ResultCompilerBackend
            (backend.compiler-backend-emit-store-to-gep
              (ast.ast-node-pool-reader-type-segment-bases)
              (owned_view.compiler-owned-shared-view homes)
              (Var 0)
              (I64 1)
              (F64)
              (& value)
              (& (F64))
              (owned_view.compiler-owned-shared-view index)
              0
              0
              state)]
          (test.assert-true
            (match result
              [(Ok text)
                (test.assert-i64-eq
                  (array-length
                    (origins.compiler-backend-text-origins-find
                      (backend.compiler-backend-state-stack-text-origins state)
                      (& text)))
                  1
                  "stored source origin survives the actual fused parent")
                (!= kind 2)]
              [(Err _) (= kind 2)])
            "exact operand site or controlled unsupported-value error")
          (test.assert-i64-eq
            (backend.compiler-backend-function-scratch-i64
              function-state
              backend.compiler-backend-scratch-i64-origin-site)
            previous
            "success and error restore outer provenance scope")
          (test.assert-i64-eq
            (backend.compiler-backend-function-state-emit-current-site
              function-state)
            17
            "label identity stays at the fusion head"))))
    (let
      [facts : origins.CompilerBackendStackAccessOriginList
        (backend.compiler-backend-state-stack-access-origins state)]
      (test.assert-i64-eq facts.len 2 "error publishes no operand record")
      (for [i (iterator.range 0 2)]
        (test.assert-i64-eq
          (array-ref facts.slots i).home
          7
          "scope selects the original stored value")))
    (backend.compiler-backend-state-release-final-arenas! state)))

(test
  backend-stack-origins-scope-consumed-instruction-site
  (backend-stack-origins-site-context-test))

(define (backend-stack-origins-general-test) : unit
  (for [fallback (iterator.range 0 2)]
    (let
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
      [function-state : backend.CompilerBackendFunctionState
        (backend.compiler-backend-state-function-state state)]
      [assignment : regalloc.CompilerRegAssignment
        (regalloc.CompilerRegAssignment 1 (Spill -64))]
      [homes : regalloc.CompilerRegAssignmentTable
        (if (= fallback 0)
          (regalloc.compiler-reg-assignments-prepend
            (& assignment)
            (regalloc.compiler-reg-assignment-table-empty))
          (regalloc.compiler-reg-assignment-table-empty))]
      [address : String
        (if (= fallback 0)
          "-64(%rbp)"
          "-16(%rbp)")]
      [plain : String
        (backend.compiler-backend-emit-store-var
          (owned_view.compiler-owned-shared-view homes)
          1
          "%r8"
          state)]
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        10)
      (backend.compiler-backend-state-stack-origins-begin! state)
      (backend-stack-origins-install-scalar-plan! state 10 (I64))
      (backend.compiler-backend-function-state-set-emit-current-site!
        function-state
        0)
      (let
        [read : String
          (match (backend.compiler-backend-emit-load-value
            (owned_view.compiler-owned-shared-view homes)
            (& (Var 1))
            "%r8"
            state)
            [(Ok text) text]
            [(Err _) (io.panic "scalar GP load refused")])]
        [write : String
          (backend.compiler-backend-emit-store-var
            (owned_view.compiler-owned-shared-view homes)
            1
            "%r8"
            state)]
        [entry : backend.CompilerBackendParameterOriginsContext
          (backend.compiler-backend-parameter-origins-begin! state)]
        [entry-write : String
          (backend.compiler-backend-emit-store-var homes 1 "%r8" state)]
        (backend.compiler-backend-parameter-origins-end! state entry)
        (test.assert-string-eq
          read
          (string.concat3 "    movq " (clone address) ", %r8\n")
          "actual scalar GP read bytes")
        (test.assert-string-eq
          write
          (string.concat3 "    movq %r8, " address "\n")
          "actual scalar GP write bytes")
        (test.assert-string-eq
          write
          plain
          "capture preserves ordinary scalar store")
        (test.assert-string-eq entry-write write "entry store bytes")
        (let
          [capture : origins.CompilerBackendTextOrigins
            (backend.compiler-backend-state-stack-text-origins state)]
          [facts : origins.CompilerBackendStackAccessOriginList
            (backend.compiler-backend-state-stack-access-origins state)]
          (test.assert-i64-eq facts.len 3 "one record per actual home access")
          (for [i (iterator.range 0 3)]
            (let
              [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                (& (array-ref facts.slots i))]
              (test.assert-i64-eq
                fact.home
                (if (= i 1)
                  8
                  7)
                "pre-color GP home")
              (test.assert-i64-eq fact.access-bytes 8 "actual GP access width")
              (test.assert-i64-eq fact.home-bytes 8 "scalar GP capacity")
              (test.assert-true
                (match (& fact.bank)
                  [(General) true]
                  [_ false])
                "GP bank")))
          (let
            [texts : (Array String 3) (array read write entry-write)]
            (for [i (iterator.range 0 3)]
              (test.assert-i64-eq
                (array-length
                  (origins.compiler-backend-text-origins-find
                    capture
                    (& (array-ref texts i))))
                1
                "fresh GP buffer preserves the operand")))))
      (backend.compiler-backend-state-release-final-arenas! state))))

(test
  backend-stack-origins-cover-scalar-general-homes
  (backend-stack-origins-general-test))

(define (backend-stack-origins-fused-load-test) : unit
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    [original : ir.CompilerIrBlockList
      (ir_text.blocks
        "entry:
  %6 = gep %0, 0 : i64
  %7 = load %6 : i64
  %9 = gep %0, 1 : i64
  %8 = load %9 : i64
")]
    [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
    [base : regalloc.CompilerRegAssignment
      (regalloc.CompilerRegAssignment
        0
        (Register (cabi.compiler-abi-register-id-from-spelling "%r12")))]
    [first : regalloc.CompilerRegAssignment
      (regalloc.CompilerRegAssignment 1 (Spill -64))]
    [second : regalloc.CompilerRegAssignment
      (regalloc.CompilerRegAssignment 2 (Spill -72))]
    [homes : regalloc.CompilerRegAssignmentTable
      (regalloc.compiler-reg-assignments-prepend
        (& base)
        (regalloc.compiler-reg-assignments-prepend
          (& first)
          (regalloc.compiler-reg-assignments-prepend
            (& second)
            (regalloc.compiler-reg-assignment-table-empty))))]
    [plain : String
      (match (backend.compiler-backend-emit-load-from-gep-pair
        (ast.ast-node-pool-reader-type-segment-bases)
        (owned_view.compiler-owned-shared-view homes)
        (Var 0)
        (I64 0)
        (I64)
        1
        (I64)
        (I64 1)
        (I64)
        2
        (I64)
        -1
        -1
        state)
        [(Ok text) text]
        [(Err _) (io.panic "ordinary load pair refused")])]
    (for [i (iterator.range 0 10)]
      (set! (array-ref map i) i))
    (set! (array-ref map 6) 3)
    (set! (array-ref map 7) 1)
    (set! (array-ref map 8) 2)
    (set! (array-ref map 9) 4)
    (backend.compiler-backend-state-stack-origins-begin! state)
    (backend.compiler-backend-function-scratch-set-i64!
      function-state
      backend.compiler-backend-scratch-i64-current-source-function
      44)
    (let
      [input : home_origins.CompilerBackendHomePlanInput
        (home_origins.CompilerBackendHomePlanInput
          44
          10
          10
          (ir.compiler-ir-param-seq-empty)
          (owned_view.compiler-owned-shared-view original)
          (regalloc.compiler-reg-remap-blocks (& map) (& original))
          (Remap map 10)
          (live.compiler-live-set-empty))]
      [plan : home_origins.CompilerBackendHomePlan
        (match (home_origins.compiler-backend-home-plan-build (& input))
          [(Ok result) result]
          [(Err message) (io.panic message)])]
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        (array-ref plan.sites 0).block)
      (backend.compiler-backend-stack-home-plan-install! function-state plan))
    (backend.compiler-backend-function-state-set-emit-current-site!
      function-state
      0)
    (let
      [pair : String
        (match (backend.compiler-backend-emit-load-from-gep-pair
          (ast.ast-node-pool-reader-type-segment-bases)
          (owned_view.compiler-owned-shared-view homes)
          (Var 0)
          (I64 0)
          (I64)
          1
          (I64)
          (I64 1)
          (I64)
          2
          (I64)
          1
          3
          state)
          [(Ok text) text]
          [(Err _) (io.panic "captured load pair refused")])]
      [single : String
        (match (backend.compiler-backend-emit-load-from-gep
          (ast.ast-node-pool-reader-type-segment-bases)
          homes
          1
          (Var 0)
          (I64 0)
          (I64)
          (I64)
          0
          1
          state)
          [(Ok text) text]
          [(Err _) (io.panic "captured single load refused")])]
      [capture : origins.CompilerBackendTextOrigins
        (backend.compiler-backend-state-stack-text-origins state)]
      [facts : origins.CompilerBackendStackAccessOriginList
        (backend.compiler-backend-state-stack-access-origins state)]
      (test.assert-string-eq
        pair
        plain
        "pair capture preserves all emitted bytes")
      (test.assert-i64-eq
        (array-length
          (origins.compiler-backend-text-origins-find capture (& pair)))
        2
        "both pair destinations retain their consumed Load sites")
      (test.assert-i64-eq
        (array-length
          (origins.compiler-backend-text-origins-find capture (& single)))
        1
        "single destination retains its consumed Load site")
      (test.assert-i64-eq facts.len 3 "three actual destination writes")
      (for [i (iterator.range 0 3)]
        (test.assert-i64-eq
          (array-ref facts.slots i).home
          (if (= i 1)
            8
            7)
          "distinct original Load definitions"))
      (test.assert-i64-eq
        (backend.compiler-backend-function-state-emit-current-site
          function-state)
        0
        "pair does not change the fusion head"))
    (backend.compiler-backend-state-release-final-arenas! state)))

(test
  backend-stack-origins-bind-fused-load-destinations
  (backend-stack-origins-fused-load-test))

(define (backend-stack-origins-group-test) : unit
  (for [kind (iterator.range 0 3)]
    (let
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
      [function-state : backend.CompilerBackendFunctionState
        (backend.compiler-backend-state-function-state state)]
      [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
      [original : ir.CompilerIrBlockList
        (ir_text.blocks "entry:
  %8 = mov %7 : i64
  return %8
")]
      [assignment : regalloc.CompilerRegAssignment
        (regalloc.CompilerRegAssignment
          1
          (if (= kind 2)
            (RegisterPair
              (cabi.compiler-abi-register-id-from-spelling "%r12")
              (cabi.compiler-abi-register-id-from-spelling "%xmm4"))
            (Spill -64)))]
      [assignments : regalloc.CompilerRegAssignmentTable
        (if (= kind 0)
          (regalloc.compiler-reg-assignment-table-empty)
          (regalloc.compiler-reg-assignments-prepend
            (& assignment)
            (regalloc.compiler-reg-assignment-table-empty)))]
      (for [var (iterator.range 0 10)]
        (set! (array-ref map var) var))
      (set! (array-ref map 7) 1)
      (set! (array-ref map 8) 1)
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-emit-current-site!
        function-state
        0)
      (backend.compiler-backend-group-vars-enable!
        state
        (live.compiler-live-set1 1)
        (live.compiler-live-set-empty))
      (backend.compiler-backend-state-stack-origins-begin! state)
      (let
        [input : home_origins.CompilerBackendHomePlanInput
          (home_origins.CompilerBackendHomePlanInput
            44
            10
            10
            (ir.CompilerIrParamSeq
              (__tl_make-array (ir.CompilerIrParam.Param "arg" (I64) 7))
              1)
            (owned_view.compiler-owned-shared-view original)
            (regalloc.compiler-reg-remap-blocks (& map) (& original))
            (Remap map 10)
            (live.compiler-live-set-insert (live.compiler-live-set1 7) 8))]
        [plan : home_origins.CompilerBackendHomePlan
          (match (home_origins.compiler-backend-home-plan-build (& input))
            [(Ok result) result]
            [(Err message) (io.panic message)])]
        (backend.compiler-backend-function-state-set-i64!
          function-state
          backend.compiler-backend-function-i64-current-block-label
          (array-ref plan.sites 0).block)
        (backend.compiler-backend-stack-home-plan-install! function-state plan))
      (let
        [entry : backend.CompilerBackendParameterOriginsContext
          (backend.compiler-backend-parameter-origins-begin! state)]
        (for [word (iterator.range 0 2)]
          (test.assert-true
            (match (backend.compiler-backend-group-word-operand-with-backend-state
              assignments
              1
              word
              10
              (backend.CompilerBackendGroupWordOrigin.Write (General))
              state)
              [(Ok _) true]
              [_ false])
            "group parameter materialization"))
        (backend.compiler-backend-parameter-origins-end! state entry))
      (test.assert-true
        (match (backend.compiler-backend-group-word-operand-with-backend-state
          assignments
          1
          0
          10
          (backend.CompilerBackendGroupWordOrigin.Read (Mask))
          state)
          [(Err _) (!= kind 2)]
          [(Ok _) (= kind 2)])
        "a memory group never uses the mask bank")
      (for [word (iterator.range 0 2)]
        (let
          [bank : traffic.CompilerStackTrafficBank
            (if (= word 0)
              (General)
              (Vector))]
          [read : String
            (match (backend.compiler-backend-group-word-operand-with-backend-state
              assignments
              1
              word
              10
              (backend.CompilerBackendGroupWordOrigin.Read bank)
              state)
              [(Ok text) text]
              [(Err _) (io.panic "group read refused")])]
          [write : String
            (match (backend.compiler-backend-group-word-operand-with-backend-state
              assignments
              1
              word
              10
              (backend.CompilerBackendGroupWordOrigin.Write bank)
              state)
              [(Ok text) text]
              [(Err _) (io.panic "group write refused")])]
          [scratch : String
            (if (= word 0)
              "%r8"
              "%xmm2")]
          [load : String
            (backend.compiler-backend-emit-group-word-move
              read
              scratch
              (= word 1)
              state)]
          [store : String
            (backend.compiler-backend-emit-group-word-move
              scratch
              write
              (= word 1)
              state)]
          [capture : origins.CompilerBackendTextOrigins
            (backend.compiler-backend-state-stack-text-origins state)]
          [facts : origins.CompilerBackendStackAccessOriginList
            (backend.compiler-backend-state-stack-access-origins state)]
          (test.assert-string-eq
            read
            write
            "same physical operand, different logical homes")
          (test.assert-i64-eq
            (array-length
              (origins.compiler-backend-text-origins-find capture (& load)))
            (if (= kind 2)
              0
              1)
            "read token survives actual word move")
          (test.assert-i64-eq
            (array-length
              (origins.compiler-backend-text-origins-find capture (& store)))
            (if (= kind 2)
              0
              1)
            "write token survives actual word move")
          (test.assert-i64-eq
            facts.len
            (if (= kind 2)
              0
              (+ 2 (* 2 (+ word 1))))
            "only memory operands produce facts")
          (unless
            (= kind 2)
            (for [rw (iterator.range 0 2)]
              (let
                [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                  (& (array-ref facts.slots (+ 2 (+ (* 2 word) rw))))]
                (test.assert-i64-eq
                  fact.home
                  (+ 24 (+ (* 2 rw) word))
                  "logical group and word are independent")
                (test.assert-i64-eq fact.home-bytes 8 "fragment capacity")
                (test.assert-i64-eq fact.access-bytes 8 "whole word access")
                (test.assert-true
                  (match (& fact.bank)
                    [(General) (= word 0)]
                    [(Vector) (= word 1)]
                    [_ false])
                  "bank comes from consumer")
                (test.assert-true
                  (match (& fact.access)
                    [(Read) (= rw 0)]
                    [(Write) (= rw 1)]
                    [_ false])
                  "explicit read/write intent"))))))
      (unless
        (= kind 2)
        (let
          [facts : origins.CompilerBackendStackAccessOriginList
            (backend.compiler-backend-state-stack-access-origins state)]
          (for [word (iterator.range 0 2)]
            (test.assert-i64-eq
              (array-ref facts.slots word).home
              (+ 24 word)
              "parameter writes use original incoming group"))))
      (backend.compiler-backend-state-release-final-arenas! state))))

(test
  backend-stack-origins-keep-original-group-fragments
  (backend-stack-origins-group-test))

(define (backend-stack-origins-group-phi-test) : unit
  (for [kind (iterator.range 0 4)]
    (let
      [ty : ast.AstType
        (cond [(= kind 2) (F32)] [(= kind 3) (F64)] [else (I64)])]
      [type-name : String
        (cond [(= kind 2) "f32"] [(= kind 3) "f64"] [else "i64"])]
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
      [index : backend.CompilerBackendProgramIndex
        (backend.compiler-backend-program-index-build-with-backend-state-and-profile-state
          state
          (ast.ast-node-pool-reader-type-segment-bases)
          (ir.compiler-ir-function-seq-empty)
          (ir.compiler-ir-extern-seq-empty)
          (profile_state.compiler-profile-state-new))]
      [function-state : backend.CompilerBackendFunctionState
        (backend.compiler-backend-state-function-state state)]
      [original : ir.CompilerIrBlockList
        (ir_text.blocks
          (string.concat3
            "entry:\n  jump join\nother:\n  jump join\njoin:\n  %7 = phi [%9, entry], [%10, other] : "
            (clone type-name)
            (string.concat3
              "\n  %8 = phi [%10, entry], [%9, other] : "
              type-name
              "\n  return %7\n")))]
      [map : (__tl_dyn-array i64) (__tl_make-array i64 12)]
      [a : regalloc.CompilerRegAssignment
        (regalloc.CompilerRegAssignment 1 (Spill -64))]
      [b : regalloc.CompilerRegAssignment
        (regalloc.CompilerRegAssignment 2 (Spill -80))]
      [assignments : regalloc.CompilerRegAssignmentTable
        (regalloc.compiler-reg-assignments-prepend
          (& a)
          (regalloc.compiler-reg-assignments-prepend
            (& b)
            (regalloc.compiler-reg-assignment-table-empty)))]
      [groups : live.CompilerLiveI64Set (live.compiler-live-set-empty)]
      (for [var (iterator.range 0 12)]
        (set! (array-ref map var) var))
      (when
        (= kind 0)
        (for [var (iterator.range 7 11)]
          (set! groups (live.compiler-live-set-insert groups var))))
      (set! (array-ref map 7) 1)
      (set! (array-ref map 8) 2)
      (set! (array-ref map 9) 2)
      (set! (array-ref map 10) 1)
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (when
        (= kind 0)
        (backend.compiler-backend-group-vars-enable!
          state
          (live.compiler-live-set-insert (live.compiler-live-set1 1) 2)
          (live.compiler-live-set-empty)))
      (backend.compiler-backend-state-stack-origins-begin! state)
      (let
        [input : home_origins.CompilerBackendHomePlanInput
          (home_origins.CompilerBackendHomePlanInput
            44
            12
            12
            (ir.compiler-ir-param-seq-empty)
            (owned_view.compiler-owned-shared-view original)
            (regalloc.compiler-reg-remap-blocks (& map) (& original))
            (Remap map 12)
            groups)]
        [plan : home_origins.CompilerBackendHomePlan
          (match (home_origins.compiler-backend-home-plan-build (& input))
            [(Ok result) result]
            [(Err message) (io.panic message)])]
        (backend.compiler-backend-function-state-set-i64!
          function-state
          backend.compiler-backend-function-i64-current-block-label
          (array-ref plan.sites 0).block)
        (backend.compiler-backend-stack-home-plan-install! function-state plan))
      (backend.compiler-backend-function-state-set-current-phi-target-point!
        state
        4)
      (backend.compiler-backend-function-state-set-emit-current-site!
        function-state
        0)
      (let
        [text : String
          (match (backend.compiler-backend-emit-phi-cycle-prefix
            (ast.ast-node-pool-reader-type-segment-bases)
            assignments
            1
            (Value (Var 2))
            (clone ty)
            ""
            index
            12
            state)
            [(Ok text) text]
            [(Err _) (io.panic "group phi cycle refused")])]
        [facts : origins.CompilerBackendStackAccessOriginList
          (backend.compiler-backend-state-stack-access-origins state)]
        [capture : origins.CompilerBackendTextOrigins
          (backend.compiler-backend-state-stack-text-origins state)]
        (test.assert-i64-eq
          facts.len
          (if (= kind 0)
            8
            6)
          "old-destination reads, planned writes and four copy operands")
        (test.assert-i64-eq
          (array-length
            (origins.compiler-backend-text-origins-find capture (& text)))
          (if (= kind 0)
            8
            6)
          "cycle prefix transports allocator and planned fragment tokens")
        (let
          [expected : (Array i64 8)
            (if (= kind 0)
              (array 26 36 27 37 30 31 26 27)
              (array 7 36 9 7 37 37 0 0))]
          (for [event
            (iterator.range
              0
              (if (= kind 0)
                8
                6))]
            (test.assert-i64-eq
              (array-ref facts.slots event).home
              (array-ref expected event)
              "typed old destination, planned slot and exact incoming homes"))))
      (when
        (> kind 0)
        (let
          [facts : origins.CompilerBackendStackAccessOriginList
            (backend.compiler-backend-state-stack-access-origins state)]
          (for [event (iterator.range 4 6)]
            (let
              [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                (& (array-ref facts.slots event))]
              (test.assert-true
                (match (& fact.owner)
                  [(EmergencyScratch) (> kind 1)]
                  [(PlannedScratch) (= kind 1)]
                  [_ false])
                "float emergency and GP planned preservation stay distinct")
              (test.assert-i64-eq
                fact.home-bytes
                (if (= kind 1)
                  8
                  64)
                "preservation capacity comes from the actual resource")
              (test.assert-i64-eq
                fact.access-bytes
                (if (= kind 1)
                  8
                  16)
                "GP push/pop or scalar-mode full XMM preservation width")
              (test.assert-true
                (match (& fact.access)
                  [(Write) (= event 4)]
                  [(Read) (= event 5)]
                  [_ false])
                "one preservation save and one restore")))))
      (let
        [restored : String
          (match (backend.compiler-backend-emit-phi-copy-item
            (ast.ast-node-pool-reader-type-segment-bases)
            assignments
            (backend.CompilerBackendPhiCopy.Copy
              2
              (backend.CompilerBackendPhiSource.Temp
                cabi.compiler-reg-id-invalid)
              (clone ty))
            index
            12
            state)
            [(Ok text) text]
            [(Err _) (io.panic "planned Phi restore refused")])]
        [capture : origins.CompilerBackendTextOrigins
          (backend.compiler-backend-state-stack-text-origins state)]
        [facts : origins.CompilerBackendStackAccessOriginList
          (backend.compiler-backend-state-stack-access-origins state)]
        [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
          (origins.compiler-backend-text-origins-find capture (& restored))]
        [expected : (Array i64 4)
          (if (= kind 0)
            (array 37 29 36 28)
            (array 36 8 0 0))]
        (test.assert-i64-eq
          (array-length spans)
          (if (= kind 0)
            4
            2)
          "actual Phi temporary restore retains every operand")
        (for [event (iterator.range 0 (array-length spans))]
          (let
            [fact : (& facts origins.CompilerBackendStackAccessOrigin)
              (& (array-ref facts.slots (array-ref spans event).token))]
            (test.assert-i64-eq
              fact.home
              (array-ref expected event)
              "temporary read and selected Phi definition remain distinct")
            (test.assert-i64-eq
              fact.access-bytes
              (if (= kind 2)
                4
                8)
              "typed Phi scalar or word width"))))
      (test.assert-true
        (not
          (backend.compiler-backend-function-scratch-bool?
            function-state
            backend.compiler-backend-scratch-bool-phi-origins))
        "successful cycle restores caller Phi context")
      (when
        (= kind 0)
        (test.assert-true
          (match (backend.compiler-backend-emit-phi-cycle-prefix
            (ast.ast-node-pool-reader-type-segment-bases)
            assignments
            1
            (Value (Bool true))
            (I64)
            ""
            index
            12
            state)
            [(Err _) true]
            [_ false])
          "controlled cycle error is retained"))
      (test.assert-true
        (not
          (backend.compiler-backend-function-scratch-bool?
            function-state
            backend.compiler-backend-scratch-bool-phi-origins))
        "failed cycle restores caller Phi context")
      (backend.compiler-backend-state-release-final-arenas! state))))

(test
  backend-stack-origins-keep-group-phi-authorities
  (backend-stack-origins-group-phi-test))

(define (backend-stack-origin-boundary-emit
  [path : i64]
  [ctx : backend.CompilerBackendEmissionContext]
  [ty : ast.AstType]) : backend.ResultCompilerBackend
  (match path
    [0
      (backend.compiler-backend-emit-return-with-return-count
        ctx.type-segment-bases
        ctx.source-function
        1
        (Some (Var 1))
        ctx.assignments
        ctx.vars
        ty
        ctx.program-index)]
    [1
      (backend.compiler-backend-emit-call-result-store
        ctx.type-segment-bases
        ctx.assignments
        1
        ty
        ctx.vars
        ctx.program-index)]
    [3
      (Ok
        (backend.compiler-backend-emit-call-result-store-reg-normalize
          ctx.assignments
          1
          (if (backend.compiler-backend-float-type? ty)
            "%xmm0"
            "%rax")
          ty
          true
          ctx.backend-state))]
    [_
      (backend.compiler-backend-emit-instr
        ctx
        (No)
        (Store (ir.compiler-ir-symbol "origin_boundary_global") (Var 1) ty))]))

(define (backend-stack-origins-boundary-test) : unit
  (for [shape (iterator.range 0 14)]
    (for [path
      (iterator.range
        0
        (if (and (>= shape 2) (<= shape 4))
          3
          4))]
      (let
        [group? : bool (and (>= shape 2) (<= shape 4))]
        [ty : ast.AstType
          (match shape
            [0 (I64)]
            [1 (F64)]
            [2
              (Struct
                (ir.compiler-ir-symbol
                  "__tl_internal_abi_group_m0__origin_boundary"))]
            [3
              (Struct
                (ir.compiler-ir-symbol
                  "__tl_internal_abi_group_m2__origin_boundary"))]
            [4
              (Struct
                (ir.compiler-ir-symbol
                  "__tl_internal_abi_group_m3__origin_boundary"))]
            [5 (I8)]
            [6 (U8)]
            [7 (I16)]
            [8 (U16)]
            [9 (I32)]
            [10 (U32)]
            [11 (Bool)]
            [12 (F32)]
            [_ (U64)])]
        [state : backend.CompilerBackendState
          (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
        [function-state : backend.CompilerBackendFunctionState
          (backend.compiler-backend-state-function-state state)]
        [function : i64 (ir.compiler-ir-symbol "origin_boundary")]
        [label : i64 (ir.compiler-ir-label "entry")]
        [callee : i64 (ir.compiler-ir-symbol "origin_boundary_callee")]
        [global : i64 (ir.compiler-ir-symbol "origin_boundary_global")]
        [params : ir.CompilerIrParamSeq
          (ir.CompilerIrParamSeq
            (__tl_make-array (ir.CompilerIrParam.Param "arg" (clone ty) 7))
            1)]
        [instructions : (__tl_dyn-array ir.CompilerIrInstr)
          (__tl_make-array ir.CompilerIrInstr 4)]
        [blocks : (__tl_dyn-array ir.CompilerIrBlock)
          (__tl_make-array ir.CompilerIrBlock 1)]
        [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
        [assignment : regalloc.CompilerRegAssignment
          (regalloc.CompilerRegAssignment 1 (Spill -64))]
        [assignments : regalloc.CompilerRegAssignmentTable
          (regalloc.compiler-reg-assignments-prepend
            (& assignment)
            (regalloc.compiler-reg-assignment-table-empty))]
        (for [var (iterator.range 0 10)]
          (set! (array-ref map var) var))
        (set! (array-ref map 7) 1)
        (set! (array-ref map 8) 1)
        (set!
          (array-ref instructions 0)
          (if group?
            (Pack
              9
              (ir.compiler-ir-value-seq2
                (if (= shape 4)
                  (F64 0)
                  (I64 1))
                (if (>= shape 3)
                  (F64 0)
                  (I64 2)))
              (clone ty))
            (Mov 9 (I64 1) (I64))))
        (set! (array-ref instructions 1) (Call 8 callee (Nil) (clone ty)))
        (set! (array-ref instructions 2) (Store global (Var 7) (clone ty)))
        (set! (array-ref instructions 3) (Return (Some (Var 7))))
        (set!
          (array-ref blocks 0)
          (Block label (ir.CompilerIrInstrSeq instructions 4)))
        (let
          [original : ir.CompilerIrBlockList
            (Array (ir.CompilerIrBlockSeq blocks 1))]
          [index : backend.CompilerBackendProgramIndex
            (backend.compiler-backend-program-index-build-with-backend-state-and-profile-state
              state
              (ast.ast-node-pool-reader-type-segment-bases)
              (ir.CompilerIrFunctionSeq
                (__tl_make-array
                  (ir.CompilerIrFunction.Function
                    function
                    (clone params)
                    (clone ty)
                    10
                    (owned_view.compiler-owned-shared-view original)
                    Ordinary))
                1)
              (ir.compiler-ir-extern-seq-empty)
              (profile_state.compiler-profile-state-new))]
          [ctx : backend.CompilerBackendEmissionContext
            (backend.CompilerBackendEmissionContext
              (ast.ast-node-pool-reader-type-segment-bases)
              (backend.compiler-backend-target-policy-new
                backend.CompilerBackendTarget.Linux)
              "_tl_origin_boundary"
              function
              (owned_view.compiler-owned-shared-view original)
              label
              (owned_view.compiler-owned-shared-view assignments)
              10
              (regalloc.compiler-reg-var-types-empty)
              (Empty)
              (clone ty)
              (Plan
                false
                false
                false
                false
                false
                false
                false
                (backend.CompilerBackendRuntimeTailPlan false false false false))
              (ir.compiler-ir-function-seq-empty)
              (ir.compiler-ir-extern-seq-empty)
              index
              (ir.compiler-source-spans-empty)
              (backend.compiler-backend-source-span-index-build-with-backend-state
                state
                (ir.compiler-source-spans-empty))
              (diagnostic.compiler-diagnostic-at-start "" "")
              (__tl_make-array i64 0)
              state
              function-state)]
          [_group-homes : unit
            (when
              group?
              (backend.compiler-backend-group-vars-enable!
                state
                (live.compiler-live-set1 1)
                (live.compiler-live-set-empty)))]
          [plain : String
            (match (backend-stack-origin-boundary-emit
              path
              (owned_view.compiler-owned-shared-view ctx)
              (clone ty))
              [(Ok text) text]
              [(Err _) (io.panic "plain boundary emitter refused")])]
          (backend.compiler-backend-function-scratch-set-i64!
            function-state
            backend.compiler-backend-scratch-i64-current-source-function
            function)
          (backend.compiler-backend-function-state-set-i64!
            function-state
            backend.compiler-backend-function-i64-current-block-label
            label)
          (backend.compiler-backend-function-state-set-emit-current-site!
            function-state
            (match path
              [0 3]
              [1 1]
              [3 1]
              [_ 2]))
          (backend.compiler-backend-state-stack-origins-begin! state)
          (let
            [input : home_origins.CompilerBackendHomePlanInput
              (home_origins.CompilerBackendHomePlanInput
                function
                10
                10
                params
                (owned_view.compiler-owned-shared-view original)
                (regalloc.compiler-reg-remap-blocks (& map) (& original))
                (Remap map 10)
                (if group?
                  (live.compiler-live-set-insert
                    (live.compiler-live-set-insert
                      (live.compiler-live-set1 7)
                      8)
                    9)
                  (live.compiler-live-set-empty)))]
            [plan : home_origins.CompilerBackendHomePlan
              (match (home_origins.compiler-backend-home-plan-build (& input))
                [(Ok result) result]
                [(Err message) (io.panic message)])]
            (backend.compiler-backend-stack-home-plan-install!
              function-state
              plan))
          (let
            [text : String
              (match (backend-stack-origin-boundary-emit path ctx ty)
                [(Ok text) text]
                [(Err _) (io.panic "captured boundary emitter refused")])]
            [facts : origins.CompilerBackendStackAccessOriginList
              (backend.compiler-backend-state-stack-access-origins state)]
            [capture : origins.CompilerBackendTextOrigins
              (backend.compiler-backend-state-stack-text-origins state)]
            (test.assert-string-eq
              text
              plain
              "boundary capture preserves complete assembly")
            (test.assert-i64-eq
              facts.len
              (+
                (if group?
                  2
                  1)
                (if (= path 0)
                  1
                  0))
              "actual boundary operand facts")
            (test.assert-i64-eq
              (array-length
                (origins.compiler-backend-text-origins-find capture (& text)))
              facts.len
              "return/call/global parent retains every operand token")
            (when
              (= path 0)
              (let
                [frame : (& facts origins.CompilerBackendStackAccessOrigin)
                  (& (array-ref facts.slots (- facts.len 1)))]
                (test.assert-true
                  (match (& frame.owner)
                    [(CallAbi) true]
                    [_ false])
                  "return's leave belongs to its ABI frame")
                (test.assert-true
                  (match (& frame.anchor)
                    [(FunctionExit) true]
                    [_ false])
                  "leave has an explicit function-exit authority")
                (test.assert-true
                  (match (& frame.access)
                    [(Read) true]
                    [_ false])
                  "leave restores the frame pointer")
                (test.assert-i64-eq
                  frame.home-bytes
                  8
                  "saved frame-pointer capacity")
                (test.assert-i64-eq
                  frame.access-bytes
                  8
                  "leave reads exactly eight bytes")))
            (for [word
              (iterator.range
                0
                (if group?
                  2
                  1))]
              (let
                [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                  (& (array-ref facts.slots word))]
                (test.assert-i64-eq
                  fact.home
                  (if group?
                    (+
                      (if (or (= path 1) (= path 3))
                        26
                        24)
                      word)
                    (if (or (= path 1) (= path 3))
                      8
                      7))
                  "boundary logical home remains pre-color")
                (test.assert-i64-eq fact.home-bytes 8 "boundary home capacity")
                (test.assert-true
                  (let
                    [vector? : bool
                      (or
                        (= shape 1)
                        (= shape 12)
                        (= shape 4)
                        (and (= shape 3) (= word 1)))]
                    (match (& fact.bank)
                      [(Vector) vector?]
                      [(General) (not vector?)]
                      [_ false]))
                  "boundary bank is the actual typed access bank")
                (test.assert-i64-eq
                  fact.access-bytes
                  (if group?
                    8
                    (if (or (= shape 1) (= shape 12))
                      (if (= shape 12)
                        4
                        8)
                      (if (or (= path 1) (= path 3))
                        8
                        (match shape
                          [5 1]
                          [6 1]
                          [7 2]
                          [8 2]
                          [9 4]
                          [10 4]
                          [11 1]
                          [_ 8]))))
                  "actual typed access width")
                (test.assert-true
                  (match (& fact.access)
                    [(Write) (or (= path 1) (= path 3))]
                    [(Read) (and (!= path 1) (!= path 3))]
                    [_ false])
                  "only the call result writes the frame")))))
        (backend.compiler-backend-state-release-final-arenas! state)))))

(test
  backend-stack-origins-survive-return-call-global-parents
  (backend-stack-origins-boundary-test))

(define (backend-stack-origins-emergency-test) : unit
  (for [mode (iterator.range 0 3)]
    (let
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
      [function-state : backend.CompilerBackendFunctionState
        (backend.compiler-backend-state-function-state state)]
      [gp : i64 cabi.compiler-reg-id-r9]
      [vec : i64 (cabi.compiler-abi-xmm-register-id 2)]
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        10)
      (backend.compiler-backend-function-state-set-current-mode!
        function-state
        (cond [(= mode 0) (Scalar)] [(= mode 1) (Avx2)] [else (Avx512)]))
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-emergency-slot-offset
        -64)
      (backend.compiler-backend-emergency-add-id! function-state gp)
      (backend.compiler-backend-emergency-add-id! function-state vec)
      (backend.compiler-backend-emergency-commit-slot-form! function-state)
      (let
        [plain-save : String
          (backend.compiler-backend-emergency-save-asm function-state 0 2 state)]
        [plain-restore : String
          (backend.compiler-backend-emergency-restore-asm
            function-state
            1
            state)]
        (backend.compiler-backend-state-stack-origins-begin! state)
        (backend-stack-origins-install-test-plan! state true false)
        (let
          [capture : origins.CompilerBackendTextOrigins
            (backend.compiler-backend-state-stack-text-origins state)]
          [save : String
            (backend.compiler-backend-emergency-save-asm
              function-state
              0
              2
              state)]
          [restore : String
            (backend.compiler-backend-emergency-restore-asm
              function-state
              1
              state)]
          [text : String
            (origins.compiler-backend-text-origins-cat capture save restore)]
          [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
            (origins.compiler-backend-text-origins-find capture (& text))]
          [facts : origins.CompilerBackendStackAccessOriginList
            (backend.compiler-backend-state-stack-access-origins state)]
          (test.assert-string-eq
            save
            plain-save
            "emergency save bytes unchanged")
          (test.assert-string-eq
            restore
            plain-restore
            "emergency restore bytes unchanged")
          (test.assert-i64-eq
            facts.len
            4
            "two frame-backed saves and two restores")
          (test.assert-i64-eq
            (array-length spans)
            4
            "recursive emergency parents retain every operand")
          (for [index (iterator.range 0 4)]
            (let
              [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                (& (array-ref facts.slots index))]
              [vector? : bool (or (= index 1) (= index 2))]
              (test.assert-i64-eq
                fact.home
                (if vector?
                  31
                  30)
                "same site and register pairs save with restore")
              (test.assert-i64-eq
                fact.home-bytes
                64
                "frame preservation capacity")
              (test.assert-i64-eq
                fact.access-bytes
                (if vector?
                  (cond [(= mode 0) 16] [(= mode 1) 32] [else 64])
                  8)
                "actual GP or mode-selected vector access width")
              (test.assert-i64-eq
                (array-ref spans index).token
                index
                "final text binds original access ordinal")
              (test.assert-true
                (match (& fact.owner)
                  [(EmergencyScratch) true]
                  [_ false])
                "emergency preservation is never an allocator spill")
              (test.assert-true
                (match (& fact.bank)
                  [(General) (not vector?)]
                  [(Vector) vector?]
                  [_ false])
                "preservation bank comes from the borrowed register")
              (test.assert-true
                (match (& fact.access)
                  [(Write) (< index 2)]
                  [(Read) (>= index 2)]
                  [_ false])
                "save writes and restore reads")))
          (backend.compiler-backend-function-state-set-emit-current-site!
            function-state
            1)
          (let
            [later : String
              (backend.compiler-backend-emergency-reg-save-asm gp -64 state)]
            [next : origins.CompilerBackendStackAccessOriginList
              (backend.compiler-backend-state-stack-access-origins state)]
            (test.assert-i64-eq
              (array-ref next.slots 4).home
              32
              "another site cannot alias a reused physical preservation slot")
            (test.assert-i64-eq
              (array-length
                (origins.compiler-backend-text-origins-find capture (& later)))
              1
              "later save keeps its new token"))
          (let
            [locs : (__tl_dyn-array i64)
              (backend.compiler-backend-function-scratch-i64-array
                function-state
                backend.compiler-backend-scratch-i64-array-emergency-save-locs)]
            (for [kind (iterator.range 0 2)]
              (set!
                (array-ref locs 0)
                (if (= kind 0)
                  (cabi.compiler-abi-xmm-register-id 4)
                  backend.compiler-backend-emergency-loc-elided))
              (let
                [park-save : String
                  (backend.compiler-backend-emergency-entry-save-asm
                    function-state
                    0
                    state)]
                [park-restore : String
                  (backend.compiler-backend-emergency-entry-restore-asm
                    function-state
                    0
                    state)]
                (test.assert-i64-eq
                  (array-length
                    (origins.compiler-backend-text-origins-find
                      capture
                      (& park-save)))
                  0
                  "register parking/elision has no stack write")
                (test.assert-i64-eq
                  (array-length
                    (origins.compiler-backend-text-origins-find
                      capture
                      (& park-restore)))
                  0
                  "register parking/elision has no stack read"))))
          (test.assert-i64-eq
            (backend.compiler-backend-state-stack-access-origins state).len
            5
            "register-only preservation publishes no home access")
          (backend.compiler-backend-function-state-set-emit-current-site!
            function-state
            0)
          (for [reg
            (iterator.range
              cabi.compiler-reg-id-r8
              (+ cabi.compiler-reg-id-r15 1))]
            (with-scratch
              (let
                [saved : String
                  (backend.compiler-backend-emergency-reg-save-asm
                    reg
                    -64
                    state)]
                (test.assert-true
                  (> (string.string-length saved) 0)
                  "temporary emission creates a preservation resource"))))
          (for [reg
            (iterator.range
              cabi.compiler-reg-id-r8
              (+ cabi.compiler-reg-id-r15 1))]
            (let
              [restored : String
                (backend.compiler-backend-emergency-reg-restore-asm
                  reg
                  -64
                  state)]
              [all : origins.CompilerBackendStackAccessOriginList
                (backend.compiler-backend-state-stack-access-origins state)]
              [index : i64 (- reg cabi.compiler-reg-id-r8)]
              (test.assert-i64-eq
                (array-ref all.slots (+ 5 index)).home
                (array-ref all.slots (+ 13 index)).home
                "registry growth survives instruction scratch destruction")
              (test.assert-i64-eq
                (array-length
                  (origins.compiler-backend-text-origins-find
                    capture
                    (& restored)))
                1
                "restored operand retains its own issued token")))))
      (backend.compiler-backend-state-stack-origins-end! state)
      (test.assert-i64-eq
        (backend.compiler-backend-function-scratch-i64
          function-state
          backend.compiler-backend-scratch-i64-stack-home-plan)
        0
        "capture retirement unpublishes its registry owner")
      (backend.compiler-backend-state-stack-origins-begin! state)
      (backend-stack-origins-install-test-plan! state true false)
      (let
        [fresh : String
          (backend.compiler-backend-emergency-reg-save-asm gp -64 state)]
        [facts : origins.CompilerBackendStackAccessOriginList
          (backend.compiler-backend-state-stack-access-origins state)]
        (test.assert-true
          (> (string.string-length fresh) 0)
          "fresh capture emits save")
        (test.assert-i64-eq facts.len 1 "fresh capture has no retired accesses")
        (test.assert-i64-eq
          (array-ref facts.slots 0).home
          30
          "fresh function plan does not reuse a retired registry"))
      (backend.compiler-backend-state-release-final-arenas! state))))

(test
  backend-stack-origins-emergency-resources
  (backend-stack-origins-emergency-test))

(define (backend-stack-origins-parallel-emission
  [state : backend.CompilerBackendState]
  [kind : i64]
  [save? : bool]) : String
  (let
    [memory? : bool (or (= kind 1) (= kind 4) (= kind 5))]
    [float? : bool (and (>= kind 2) (<= kind 5))]
    [bytes : i64
      (if (or (= kind 2) (= kind 4))
        4
        8)]
    [ty : ast.AstType
      (if (= bytes 4)
        (F32)
        (F64))]
    [operand : String
      (if memory?
        (backend.compiler-backend-stack-operand-origin
          state
          "-64(%rbp)"
          (backend.CompilerBackendStackOperandRequest
            1
            bytes
            (if float?
              (Vector)
              (General))
            (if save?
              (Read)
              (Write))
            (Whole)
            (Value)))
        (if float?
          "%xmm2"
          "%r9"))]
    (cond
      [(< kind 2)
        (if save?
          (backend.compiler-backend-emit-phi-temp-slot-save-gp operand 0 state)
          (backend.compiler-backend-emit-phi-temp-slot-restore-gp
            operand
            0
            state))]
      [(< kind 6)
        (if save?
          (backend.compiler-backend-emit-phi-float-temp-save operand ty state)
          (backend.compiler-backend-emit-phi-float-temp-restore
            operand
            ty
            state))]
      [else
        (let
          [reg : i64
            (if (= kind 6)
              cabi.compiler-reg-id-r9
              (cabi.compiler-abi-xmm-register-id 2))]
          (if save?
            (backend.compiler-backend-emit-arg-cycle-temp-save reg state)
            (match (backend.compiler-backend-emit-arg-move
              (regalloc.compiler-reg-assignment-table-empty)
              (backend.CompilerBackendArgMove.BackendArgMove
                reg
                (backend.CompilerBackendArgMoveSource.BackendArgMoveStackPop))
              state)
              [(Ok text) text]
              [(Err _) (io.panic "parallel arg temp reload refused")])))])))

(define (backend-stack-origins-parallel-test) : unit
  (let
    [plain : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [reg : String
      (backend.compiler-backend-parallel-copy-register-operand
        plain
        "%r9"
        (Read))]
    (test.assert-string-eq reg "%r9" "inactive preservation keeps its operand")
    (test.assert-true
      (not (backend.compiler-backend-state-function-state-active? plain))
      "inactive preservation does not materialize metadata or function state")
    (backend.compiler-backend-state-release-final-arenas! plain))
  (for [kind (iterator.range 0 8)]
    (let
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
      [function-state : backend.CompilerBackendFunctionState
        (backend.compiler-backend-state-function-state state)]
      [plain-save : String
        (backend-stack-origins-parallel-emission state kind true)]
      [plain-restore : String
        (backend-stack-origins-parallel-emission state kind false)]
      [memory? : bool (or (= kind 1) (= kind 4) (= kind 5))]
      [bytes : i64
        (if (or (= kind 2) (= kind 4))
          4
          8)]
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        10)
      (backend.compiler-backend-function-state-set-emit-current-site!
        function-state
        0)
      (backend.compiler-backend-state-stack-origins-begin! state)
      (backend-stack-origins-install-scalar-plan!
        state
        10
        (cond [(< kind 2) (I64)] [(= bytes 4) (F32)] [else (F64)]))
      (let
        [capture : origins.CompilerBackendTextOrigins
          (backend.compiler-backend-state-stack-text-origins state)]
        [save : String
          (backend-stack-origins-parallel-emission state kind true)]
        [restore : String
          (backend-stack-origins-parallel-emission state kind false)]
        [text : String
          (origins.compiler-backend-text-origins-cat capture save restore)]
        [facts : origins.CompilerBackendStackAccessOriginList
          (backend.compiler-backend-state-stack-access-origins state)]
        [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
          (origins.compiler-backend-text-origins-find capture (& text))]
        (test.assert-string-eq
          save
          plain-save
          "parallel-copy save bytes unchanged")
        (test.assert-string-eq
          restore
          plain-restore
          "parallel-copy restore bytes unchanged")
        (test.assert-i64-eq
          facts.len
          (if memory?
            4
            2)
          "actual allocator and planned temp operands")
        (test.assert-i64-eq
          (array-length spans)
          facts.len
          "all temporary and allocator tokens survive final concatenation")
        (for [event (iterator.range 0 (array-length spans))]
          (let
            [fact : (& facts origins.CompilerBackendStackAccessOrigin)
              (& (array-ref facts.slots (array-ref spans event).token))]
            [temp? : bool (or (not memory?) (or (= event 1) (= event 2)))]
            (test.assert-i64-eq
              fact.home
              (if temp?
                30
                (if (= event 0)
                  7
                  8))
              "source, temporary, reload and destination remain distinct")
            (test.assert-i64-eq
              fact.access-bytes
              bytes
              "typed actual transfer width")
            (test.assert-i64-eq
              fact.home-bytes
              8
              "scalar or planned word capacity")
            (test.assert-true
              (match (& fact.owner)
                [(PlannedScratch) temp?]
                [(Allocator) (not temp?)]
                [_ false])
              "planned preservation is separate from allocator traffic")
            (when
              temp?
              (test.assert-true
                (match (& fact.bank)
                  [(Bytes) true]
                  [_ false])
                "parallel-copy temp is untyped bit storage"))
            (test.assert-true
              (match (& fact.access)
                [(Read)
                  (if memory?
                    (or (= event 0) (= event 2))
                    (= event 1))]
                [(Write)
                  (if memory?
                    (or (= event 1) (= event 3))
                    (= event 0))]
                [_ false])
              "final access order reflects actual data transfer"))))
      (backend.compiler-backend-state-release-final-arenas! state))))

(test
  backend-stack-origins-planned-parallel-resources
  (backend-stack-origins-parallel-test))

(define (backend-stack-origins-arg-cycle-test) : unit
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    [moves : backend.CompilerBackendArgMoveSeq
      (backend.compiler-backend-arg-move-seq-with-capacity 2)]
    [first : i64 (cabi.compiler-abi-xmm-register-id 0)]
    [second : i64 (cabi.compiler-abi-xmm-register-id 1)]
    (backend.compiler-backend-arg-move-push!
      (&mut moves)
      (backend.CompilerBackendArgMove.BackendArgMove
        first
        (backend.CompilerBackendArgMoveSource.BackendArgMoveReg second)))
    (backend.compiler-backend-arg-move-push!
      (&mut moves)
      (backend.CompilerBackendArgMove.BackendArgMove
        second
        (backend.CompilerBackendArgMoveSource.BackendArgMoveReg first)))
    (let
      [plain : String
        (match (backend.compiler-backend-emit-arg-move-list
          (regalloc.compiler-reg-assignment-table-empty)
          (clone moves)
          state)
          [(Ok text) text]
          [(Err _) (io.panic "plain arg cycle refused")])]
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        10)
      (backend.compiler-backend-function-state-set-emit-current-site!
        function-state
        0)
      (backend.compiler-backend-state-stack-origins-begin! state)
      (backend-stack-origins-install-scalar-plan! state 10 (F64))
      (let
        [text : String
          (match (backend.compiler-backend-emit-arg-move-list
            (regalloc.compiler-reg-assignment-table-empty)
            moves
            state)
            [(Ok text) text]
            [(Err _) (io.panic "captured arg cycle refused")])]
        [capture : origins.CompilerBackendTextOrigins
          (backend.compiler-backend-state-stack-text-origins state)]
        [facts : origins.CompilerBackendStackAccessOriginList
          (backend.compiler-backend-state-stack-access-origins state)]
        [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
          (origins.compiler-backend-text-origins-find capture (& text))]
        (test.assert-string-eq text plain "actual arg cycle bytes unchanged")
        (test.assert-i64-eq facts.len 2 "one planned save and one reload")
        (test.assert-i64-eq
          (array-length spans)
          2
          "recursive arg parents retain both accesses")
        (for [event (iterator.range 0 2)]
          (let
            [fact : (& facts origins.CompilerBackendStackAccessOrigin)
              (& (array-ref facts.slots (array-ref spans event).token))]
            (test.assert-i64-eq
              fact.home
              30
              "actual cycle uses one planned slot")
            (test.assert-true
              (match (& fact.owner)
                [(PlannedScratch) true]
                [_ false])
              "cycle break keeps planned owner")
            (test.assert-true
              (match (& fact.access)
                [(Write) (= event 0)]
                [(Read) (= event 1)]
                [_ false])
              "text order is save then reload despite recursive emission order"))))
      (backend.compiler-backend-state-release-final-arenas! state))))

(test
  backend-stack-origins-through-actual-arg-cycle
  (backend-stack-origins-arg-cycle-test))

(define (backend-stack-origins-lane-emission
  [state : backend.CompilerBackendState]
  [kind : i64]) : String
  (let
    [label : i64
      (backend.compiler-backend-function-state-i64
        (backend.compiler-backend-state-function-state state)
        backend.compiler-backend-function-i64-current-block-label)]
    [assignments : regalloc.CompilerRegAssignmentTable
      (regalloc.compiler-reg-assignment-table-empty)]
    [lanes : i64
      (cond
        [(= kind 0) 4]
        [(or (= kind 1) (= kind 6)) 8]
        [(or (= kind 2) (= kind 4) (= kind 7)) 16]
        [else 32])]
    [diag : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-at-start "" "")]
    (for [index (iterator.range 0 3)]
      (let
        [home : regalloc.CompilerRegAssignment
          (regalloc.CompilerRegAssignment
            index
            (Register
              (if (= index 0)
                cabi.compiler-reg-id-rdi
                (cabi.compiler-abi-vector-register-id (+ 5 index)))))]
        (set!
          assignments
          (regalloc.compiler-reg-assignments-prepend (& home) assignments))))
    (match (cond
      [(< kind 4)
        (backend.compiler-backend-emit-avx2-tail-mask
          (ast.ast-node-pool-reader-type-segment-bases)
          "lane_origin"
          label
          assignments
          1
          (I64 0)
          (I64 3)
          lanes
          diag
          state)]
      [(< kind 7)
        (backend.compiler-backend-emit-avx2-predicated-load
          (ast.ast-node-pool-reader-type-segment-bases)
          "lane_origin"
          label
          assignments
          1
          (Var 0)
          (I64 0)
          (Var 2)
          lanes
          (cond [(= kind 6) (Bool)] [(= lanes 16) (I16)] [else (I8)])
          diag
          state)]
      [else
        (backend.compiler-backend-emit-avx2-predicated-store
          (ast.ast-node-pool-reader-type-segment-bases)
          "lane_origin"
          label
          assignments
          (Var 0)
          (I64 0)
          (Var 1)
          (Var 2)
          lanes
          (if (= lanes 16)
            (I16)
            (I8))
          diag
          state)])
      [(Ok text) text]
      [(Err _) (io.panic "lane staging emitter refused fixture")])))

(define (backend-stack-origins-lane-test) : unit
  (for [invalid (iterator.range 0 6)]
    (test.assert-true
      (not
        (backend.compiler-backend-avx2-lane-stack-access-valid?
          (cond
            [(= invalid 0) -1]
            [(= invalid 1) 32]
            [(= invalid 2) 9223372036854775807]
            [else 0])
          (cond
            [(< invalid 3) 1]
            [(= invalid 3) 0]
            [(= invalid 4) 16]
            [else -1])))
      "invalid fixed lane extent rejects before address arithmetic"))
  (for [kind (iterator.range 0 9)]
    (let
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
      [function-state : backend.CompilerBackendFunctionState
        (backend.compiler-backend-state-function-state state)]
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        (ir.compiler-ir-label "lane_entry"))
      (backend.compiler-backend-function-state-set-current-mode!
        function-state
        (Avx2))
      (backend.compiler-backend-simd-scratch-plan! function-state 32 192)
      (let
        [plain : String (backend-stack-origins-lane-emission state kind)]
        (backend.compiler-backend-state-stack-origins-begin! state)
        (backend-stack-origins-install-test-plan! state true false)
        (let
          [text : String (backend-stack-origins-lane-emission state kind)]
          [capture : origins.CompilerBackendTextOrigins
            (backend.compiler-backend-state-stack-text-origins state)]
          [facts : origins.CompilerBackendStackAccessOriginList
            (backend.compiler-backend-state-stack-access-origins state)]
          [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
            (origins.compiler-backend-text-origins-find capture (& text))]
          [lanes : i64
            (cond
              [(= kind 0) 0]
              [(or (= kind 1) (= kind 6)) 8]
              [(or (= kind 2) (= kind 4) (= kind 7)) 16]
              [else 32])]
          [expected : i64
            (if (= kind 0)
              0
              (+
                lanes
                (if (< kind 7)
                  2
                  1)))]
          (test.assert-string-eq
            text
            plain
            "capturing fixed staging changes no bytes")
          (test.assert-i64-eq
            facts.len
            expected
            "every real lane-buffer access is issued")
          (test.assert-i64-eq
            (array-length spans)
            expected
            "recursive lane parents retain all final access tokens")
          (for [event (iterator.range 0 expected)]
            (let
              [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                (& (array-ref facts.slots (array-ref spans event).token))]
              [whole? : bool
                (or (= event 0) (and (< kind 7) (= event (- expected 1))))]
              (test.assert-i64-eq
                fact.home
                30
                "one typed site-local bit buffer")
              (test.assert-i64-eq
                fact.home-bytes
                32
                "fixed lane buffer capacity")
              (test.assert-i64-eq
                fact.access-bytes
                (if whole?
                  32
                  (/ 32 lanes))
                "actual whole or lane access width")
              (test.assert-true
                (match (& fact.owner)
                  [(FixedScratch) true]
                  [_ false])
                "lane staging is neither allocator nor emergency traffic")
              (test.assert-true
                (match (& fact.bank)
                  [(Bytes) true]
                  [_ false])
                "fixed staging preserves untyped vector bits")
              (test.assert-true
                (match (& fact.access)
                  [(Write)
                    (if (< kind 7)
                      (< event (- expected 1))
                      (= event 0))]
                  [(Read)
                    (if (< kind 7)
                      (= event (- expected 1))
                      (> event 0))]
                  [_ false])
                "final order binds initialization, conditional lanes and reload"))))
        (backend.compiler-backend-state-stack-origins-end! state))
      (backend.compiler-backend-state-release-final-arenas! state))))

(test backend-stack-origins-fixed-lane-buffer (backend-stack-origins-lane-test))

(define (backend-stack-origins-shift-emission
  [state : backend.CompilerBackendState]
  [kind : i64]) : String
  (let
    [shape : i64 (/ kind 4)]
    [signed? : bool (= (% kind 2) 0)]
    [ty : ast.AstType
      (if (= shape 0)
        (if signed?
          (I16)
          (U16))
        (if signed?
          (I8)
          (U8)))]
    [op : ir.CompilerIrBinOp
      (if (< (% kind 4) 2)
        (Shl (clone ty))
        (Shr (clone ty)))]
    [assignments : regalloc.CompilerRegAssignmentTable
      (regalloc.compiler-reg-assignment-table-empty)]
    [diag : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-at-start "" "")]
    (for [index (iterator.range 0 3)]
      (let
        [home : regalloc.CompilerRegAssignment
          (regalloc.CompilerRegAssignment
            index
            (Register (cabi.compiler-abi-vector-register-id (+ 6 index))))]
        (set!
          assignments
          (regalloc.compiler-reg-assignments-prepend (& home) assignments))))
    (match (if (= shape 0)
      (backend.compiler-backend-emit-avx2-word-vector-shift
        assignments
        2
        op
        (Var 0)
        (Var 1)
        ty
        diag
        state)
      (backend.compiler-backend-emit-byte-vector-shift
        assignments
        2
        op
        (Var 0)
        (Var 1)
        ty
        (if (= shape 2)
          "zmm"
          "ymm")
        diag
        state))
      [(Ok text) text]
      [(Err _) (io.panic "shift staging emitter refused fixture")])))

(define (backend-stack-origins-shift-test) : unit
  (for [invalid (iterator.range 0 8)]
    (let
      [request : backend.CompilerBackendFixedStagingOperandRequest
        (backend.CompilerBackendFixedStagingOperandRequest
          (Operand 0)
          (if (= invalid 0)
            16
            32)
          (cond
            [(= invalid 1) -1]
            [(= invalid 2) 9223372036854775807]
            [(= invalid 3) 120]
            [else 0])
          (cond
            [(= invalid 4) 0]
            [(= invalid 5) -1]
            [(= invalid 6) 64]
            [else 32])
          (Read))]
      (test.assert-true
        (not
          (backend.compiler-backend-fixed-staging-extent-valid?
            (if (= invalid 7)
              -1
              128)
            (& request)))
        "invalid capacity, width or planned offset rejects without overflow")))
  (for [kind (iterator.range 0 12)]
    (let
      [shape : i64 (/ kind 4)]
      [bytes : i64
        (if (= shape 2)
          64
          32)]
      [groups : i64
        (if (= shape 0)
          2
          4)]
      [group-bytes : i64 (/ bytes groups)]
      [expected : i64 (cond [(= shape 0) 10] [(= shape 1) 25] [else 27])]
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
      [function-state : backend.CompilerBackendFunctionState
        (backend.compiler-backend-state-function-state state)]
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        10)
      (backend.compiler-backend-function-state-set-current-mode!
        function-state
        (if (= shape 2)
          (Avx512)
          (Avx2)))
      (backend.compiler-backend-simd-scratch-plan!
        function-state
        (if (= shape 0)
          128
          (* bytes 7))
        192)
      (let
        [plain : String (backend-stack-origins-shift-emission state kind)]
        (backend.compiler-backend-state-stack-origins-begin! state)
        (backend-stack-origins-install-test-plan! state true false)
        (let
          [text : String (backend-stack-origins-shift-emission state kind)]
          [capture : origins.CompilerBackendTextOrigins
            (backend.compiler-backend-state-stack-text-origins state)]
          [facts : origins.CompilerBackendStackAccessOriginList
            (backend.compiler-backend-state-stack-access-origins state)]
          [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
            (origins.compiler-backend-text-origins-find capture (& text))]
          [packed-homes : (Array i64 8) (array 2 3 2 4 5 3 2 3)]
          (test.assert-string-eq
            text
            plain
            "fixed shift capture changes no assembly byte")
          (test.assert-i64-eq
            facts.len
            expected
            "all shift staging accesses are issued")
          (test.assert-i64-eq
            (array-length spans)
            expected
            "grouping and packing parents retain every token")
          (for [event (iterator.range 0 expected)]
            (let
              [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                (& (array-ref facts.slots (array-ref spans event).token))]
              [widening-end : i64 (+ 2 (* groups 3))]
              [post : i64 (- event widening-end)]
              [ordinal : i64
                (cond
                  [(< event 2) event]
                  [(< event widening-end)
                    (if (= (% (- event 2) 3) 2)
                      (+ 2 (/ (- event 2) 3))
                      (% (- event 2) 3))]
                  [(= shape 0) (+ 2 post)]
                  [(< post 8) (array-ref packed-homes post)]
                  [else 6])]
              [width : i64
                (cond
                  [(< event 2) bytes]
                  [(< event widening-end)
                    (if (= (% (- event 2) 3) 2)
                      bytes
                      group-bytes)]
                  [(or (= shape 0) (< post 8)) bytes]
                  [(= event (- expected 1)) group-bytes]
                  [else 4])]
              [write? : bool
                (cond
                  [(< event 2) true]
                  [(< event widening-end) (= (% (- event 2) 3) 2)]
                  [(= shape 0) false]
                  [(< post 8) (or (= post 2) (= post 5))]
                  [else (< event (- expected 1))])]
              (test.assert-i64-eq
                fact.home
                (+ 30 ordinal)
                "typed operand/result/permutation homes follow actual access order")
              (test.assert-i64-eq
                fact.home-bytes
                bytes
                "planned capacity survives narrow accesses")
              (test.assert-i64-eq
                fact.access-bytes
                width
                "actual widening, packing or index width")
              (test.assert-true
                (match (& fact.owner)
                  [(FixedScratch) true]
                  [_ false])
                "shift staging is distinct from allocator or emergency traffic")
              (test.assert-true
                (match (& fact.bank)
                  [(Bytes) true]
                  [_ false])
                "staged bits have no allocator register bank")
              (test.assert-true
                (match (& fact.access)
                  [(Write) write?]
                  [(Read) (not write?)]
                  [_ false])
                "save, widening, packing and permutation access directions"))))
        (backend.compiler-backend-state-stack-origins-end! state))
      (backend.compiler-backend-state-release-final-arenas! state))))

(test
  backend-stack-origins-fixed-shift-buffers
  (backend-stack-origins-shift-test))

(define (backend-stack-origins-fixed-state [wide? : bool] [planned : i64]) : backend.CompilerBackendState
  (builtin_ids.compiler-builtin-initialize-for-parse!)
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new
        (ci.intern-compat-state-capture-active))]
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    (backend.compiler-backend-function-scratch-set-i64!
      function-state
      backend.compiler-backend-scratch-i64-current-source-function
      44)
    (backend.compiler-backend-function-state-set-i64!
      function-state
      backend.compiler-backend-function-i64-current-block-label
      (ir.compiler-ir-label "fixed_buffer_entry"))
    (backend.compiler-backend-function-state-set-current-mode!
      function-state
      (if wide?
        (Avx512)
        (Avx2)))
    (backend.compiler-backend-simd-scratch-plan! function-state planned 192)
    state))

(define (backend-stack-origins-fixed-element [kind : i64]) : ast.AstType
  (match (% kind 6)
    [0 (I32)]
    [1 (U32)]
    [2 (F32)]
    [3 (I64)]
    [4 (U64)]
    [_ (F64)]))

(define (backend-stack-origins-gather-emission
  [state : backend.CompilerBackendState]
  [kind : i64]) : String
  (let
    [wide? : bool (>= kind 6)]
    [dword? : bool (< (% kind 6) 3)]
    [homes : regalloc.CompilerRegAssignmentTable
      (regalloc.compiler-reg-assignment-table-empty)]
    (for [index (iterator.range 0 3)]
      (let
        [home : regalloc.CompilerRegAssignment
          (regalloc.CompilerRegAssignment
            index
            (Register
              (cond
                [(= index 0) cabi.compiler-reg-id-rdi]
                [(= index 1) cabi.compiler-reg-id-rsi]
                [else (cabi.compiler-abi-vector-register-id 6)])))]
        (set! homes (regalloc.compiler-reg-assignments-prepend (& home) homes))))
    (match (backend.compiler-backend-emit-gather-load
      (ast.ast-node-pool-reader-type-segment-bases)
      homes
      2
      (Var 0)
      (Var 1)
      (I64 0)
      false
      (*
        (if wide?
          8
          4)
        (if dword?
          2
          1))
      (backend-stack-origins-fixed-element kind)
      (diagnostic.compiler-diagnostic-at-start "" "")
      state)
      [(Ok text) text]
      [(Err _) (io.panic "gather fixture refused")])))

(define (backend-stack-origins-gather-test) : unit
  (for [kind (iterator.range 0 12)]
    (let
      [wide? : bool (>= kind 6)]
      [dword? : bool (< (% kind 6) 3)]
      [expected : i64
        (if dword?
          (if wide?
            5
            7)
          (if wide?
            0
            2))]
      [bytes : i64
        (if wide?
          64
          32)]
      [state : backend.CompilerBackendState
        (backend-stack-origins-fixed-state
          wide?
          (if dword?
            128
            (if wide?
              0
              32)))]
      [plain : String (backend-stack-origins-gather-emission state kind)]
      (backend.compiler-backend-state-stack-origins-begin! state)
      (backend-stack-origins-install-test-plan! state true false)
      (let
        [text : String (backend-stack-origins-gather-emission state kind)]
        [capture : origins.CompilerBackendTextOrigins
          (backend.compiler-backend-state-stack-text-origins state)]
        [facts : origins.CompilerBackendStackAccessOriginList
          (backend.compiler-backend-state-stack-access-origins state)]
        [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
          (origins.compiler-backend-text-origins-find capture (& text))]
        (test.assert-string-eq
          text
          plain
          "gather capture preserves complete assembly")
        (test.assert-i64-eq
          facts.len
          expected
          "only actual staged gather accesses")
        (test.assert-i64-eq
          (array-length spans)
          expected
          "all gather parents retain their tokens")
        (for [event (iterator.range 0 expected)]
          (let
            [fact : (& facts origins.CompilerBackendStackAccessOrigin)
              (& (array-ref facts.slots (array-ref spans event).token))]
            [ordinal : i64
              (if (not dword?)
                0
                (if wide?
                  (if (or (= event 0) (= event 2))
                    0
                    1)
                  (cond
                    [(or (= event 0) (= event 6)) 0]
                    [(or (= event 1) (= event 3)) 1]
                    [else 2])))]
            [partial? : bool
              (and
                dword?
                (if wide?
                  (or (= event 1) (= event 3))
                  (or (= event 2) (= event 4))))]
            [write? : bool
              (if (not dword?)
                (= event 0)
                (if wide?
                  (or (< event 2) (= event 3))
                  (or (< event 3) (= event 4))))]
            (test.assert-i64-eq
              fact.home
              (+ 30 ordinal)
              "mask, index and tuple remain separate")
            (test.assert-i64-eq
              fact.home-bytes
              bytes
              "gather buffer capacity follows its mode")
            (test.assert-i64-eq
              fact.access-bytes
              (if partial?
                (/ bytes 2)
                bytes)
              "result half writes differ from complete tuple reload")
            (test.assert-true
              (match (& fact.owner)
                [(FixedScratch) true]
                [_ false])
              "gather staging is not allocator traffic")
            (test.assert-true
              (match (& fact.bank)
                [(Bytes) true]
                [_ false])
              "fixed gather bit storage")
            (test.assert-true
              (match (& fact.access)
                [(Write) write?]
                [(Read) (not write?)]
                [_ false])
              "actual gather store/read order"))))
      (backend.compiler-backend-state-release-final-arenas! state))))

(define (backend-stack-origins-shuffle-emission
  [state : backend.CompilerBackendState]
  [kind : i64]) : String
  (let
    [wide? : bool (>= kind 6)]
    [dword? : bool (< (% kind 6) 3)]
    [lanes : i64
      (*
        (if wide?
          8
          4)
        (if dword?
          2
          1))]
    [homes : regalloc.CompilerRegAssignmentTable
      (regalloc.compiler-reg-assignment-table-empty)]
    [index : backend.CompilerBackendProgramIndex
      (backend.compiler-backend-program-index-build-with-backend-state-and-profile-state
        state
        (ast.ast-node-pool-reader-type-segment-bases)
        (ir.compiler-ir-function-seq-empty)
        (ir.compiler-ir-extern-seq-empty)
        (profile_state.compiler-profile-state-new))]
    [plan : backend.CompilerBackendRuntimePlan
      (match (backend.compiler-backend-runtime-plan-with-backend-state
        state
        (Program
          (ir.compiler-ir-global-seq-empty)
          (ir.compiler-ir-function-seq-empty)
          (ir.compiler-ir-extern-seq-empty)))
        [(Ok result) result]
        [(Err _) (io.panic "empty runtime plan refused")])]
    (for [id (iterator.range 0 4)]
      (let
        [home : regalloc.CompilerRegAssignment
          (regalloc.CompilerRegAssignment
            id
            (Register (cabi.compiler-abi-vector-register-id (+ 6 id))))]
        (set! homes (regalloc.compiler-reg-assignments-prepend (& home) homes))))
    (match (backend.compiler-backend-emit-vector-shuffle
      (ast.ast-node-pool-reader-type-segment-bases)
      (Linux)
      "fixed_shuffle"
      (backend.compiler-backend-function-state-i64
        (backend.compiler-backend-state-function-state state)
        backend.compiler-backend-function-i64-current-block-label)
      homes
      3
      (Var 0)
      (Var 1)
      (if dword?
        (Some (Var 2))
        (No))
      (I64 lanes)
      lanes
      (backend-stack-origins-fixed-element kind)
      plan
      index
      (diagnostic.compiler-diagnostic-at-start "" ""))
      [(Ok text) text]
      [(Err _) (io.panic "shuffle fixture refused")])))

(define (backend-stack-origins-shuffle-test) : unit
  (for [kind (iterator.range 0 12)]
    (let
      [wide? : bool (>= kind 6)]
      [dword? : bool (< (% kind 6) 3)]
      [bytes : i64
        (if wide?
          64
          32)]
      [selector-count : i64
        (if dword?
          2
          1)]
      [selector-lanes : i64 (/ bytes 8)]
      [lanes : i64 (* selector-count selector-lanes)]
      [per-lane : i64
        (if (or dword? wide?)
          2
          3)]
      [lane-start : i64 (+ 2 (* 2 selector-count))]
      [lane-end : i64 (+ lane-start (* lanes per-lane))]
      [expected : i64 (+ lane-end 2)]
      [state : backend.CompilerBackendState
        (backend-stack-origins-fixed-state wide? (* bytes (+ selector-count 2)))]
      [plain : String (backend-stack-origins-shuffle-emission state kind)]
      (backend.compiler-backend-state-stack-origins-begin! state)
      (backend-stack-origins-install-test-plan! state true false)
      (let
        [text : String (backend-stack-origins-shuffle-emission state kind)]
        [capture : origins.CompilerBackendTextOrigins
          (backend.compiler-backend-state-stack-text-origins state)]
        [facts : origins.CompilerBackendStackAccessOriginList
          (backend.compiler-backend-state-stack-access-origins state)]
        [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
          (origins.compiler-backend-text-origins-find capture (& text))]
        (test.assert-string-eq
          text
          plain
          "shuffle capture preserves complete assembly")
        (test.assert-i64-eq
          facts.len
          expected
          "no speculative high-selector fact")
        (test.assert-i64-eq
          (array-length spans)
          expected
          "shuffle checks and recursion retain every operand")
        (let
          [source-home : i64
            (array-ref facts.slots (array-ref spans 0).token).home]
          [low-home : i64
            (array-ref facts.slots (array-ref spans 1).token).home]
          [high-home : i64
            (if dword?
              (array-ref facts.slots (array-ref spans 2).token).home
              -1)]
          [index-home : i64
            (array-ref facts.slots (array-ref spans (- lane-start 1)).token).home]
          (test.assert-true
            (and
              (!= source-home low-home)
              (!= source-home index-home)
              (!= low-home index-home)
              (or
                (not dword?)
                (and
                  (!= high-home source-home)
                  (!= high-home low-home)
                  (!= high-home index-home))))
            "fixed shuffle roles are disjoint")
          (for [event (iterator.range 0 expected)]
            (let
              [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                (& (array-ref facts.slots (array-ref spans event).token))]
              [lane? : bool (and (>= event lane-start) (< event lane-end))]
              [part : i64 (% (- event lane-start) per-lane)]
              [lane : i64 (/ (- event lane-start) per-lane)]
              [selector? : bool (and lane? (= part 0))]
              [home : i64
                (cond
                  [(or (= event 0) (= event (- expected 1))) source-home]
                  [(or (= event 1) (= event (+ selector-count 1))) low-home]
                  [(and dword? (or (= event 2) (= event 4))) high-home]
                  [selector?
                    (if (< lane selector-lanes)
                      low-home
                      high-home)]
                  [else index-home])]
              [width : i64
                (if lane?
                  (if selector?
                    8
                    (if (and wide? (not dword?))
                      8
                      4))
                  bytes)]
              [write? : bool
                (or
                  (<= event selector-count)
                  (= event (- lane-start 1))
                  (and lane? (not selector?)))]
              (test.assert-i64-eq
                fact.home
                home
                "actual selector/index/source access sequence")
              (test.assert-i64-eq
                fact.home-bytes
                bytes
                "fixed shuffle vector capacity")
              (test.assert-i64-eq
                fact.access-bytes
                width
                "actual selector and packed-index access width")
              (test.assert-true
                (match (& fact.owner)
                  [(FixedScratch) true]
                  [_ false])
                "shuffle fixed owner")
              (test.assert-true
                (match (& fact.bank)
                  [(Bytes) true]
                  [_ false])
                "shuffle bit storage")
              (test.assert-true
                (match (& fact.access)
                  [(Write) write?]
                  [(Read) (not write?)]
                  [_ false])
                "selector save/check and index initialization/copy/reload")))))
      (backend.compiler-backend-state-release-final-arenas! state))))

(test
  backend-stack-origins-fixed-gather-buffers
  (backend-stack-origins-gather-test))

(test
  backend-stack-origins-fixed-shuffle-buffers
  (backend-stack-origins-shuffle-test))

(define (backend-stack-origins-callee-emit
  [state : backend.CompilerBackendState]
  [homes : regalloc.CompilerRegAssignmentTable]
  [shape : i64]
  [windows? : bool]) : String
  (let
    [capture : origins.CompilerBackendTextOrigins
      (backend.compiler-backend-state-stack-text-origins state)]
    (if (< shape 2)
      (origins.compiler-backend-text-origins-cat
        capture
        (backend.compiler-backend-emit-save-callee-regs homes 10 state)
        (backend.compiler-backend-emit-restore-callee-regs homes 10 state))
      (if (= shape 2)
        (let
          [pushes : (__tl_dyn-array String)
            (backend.compiler-backend-rsp-rebase-make-push-regs)]
          (set! (array-ref pushes 0) "%r12")
          (set! (array-ref pushes 1) "%r13")
          (origins.compiler-backend-text-origins-cat
            capture
            (if windows?
              (backend.compiler-backend-emit-function-entry-fpo-windows
                (backend.compiler-backend-target-policy-new (Windows))
                state
                "fixture"
                128
                homes
                10
                (owned_view.compiler-owned-shared-view pushes)
                2)
              (backend.compiler-backend-emit-function-entry-fpo-push
                state
                "fixture"
                128
                (owned_view.compiler-owned-shared-view pushes)
                2))
            (backend.compiler-backend-rsp-rebase-pop-run pushes state)))
        (origins.compiler-backend-text-origins-cat
          capture
          (if (= shape 3)
            (backend.compiler-backend-emit-save-win64-xmm-callee-regs
              (if windows?
                (Windows)
                (Linux))
              homes
              10
              128
              state)
            (if windows?
              (backend.compiler-backend-emit-save-win64-xmm-callee-regs-fpo-at
                state
                homes
                10
                128
                0)
              ""))
          (if windows?
            (backend.compiler-backend-emit-win64-xmm-callee-regs-at
              homes
              10
              0
              9
              -1
              false
              state)
            ""))))))

(define (backend-stack-origins-callee-test) : unit
  (backend-stack-origins-callee-rebase-test)
  (for [mode (iterator.range 0 3)]
    (for [platform (iterator.range 0 2)]
      (for [shape (iterator.range 0 5)]
        (for [selection
          (iterator.range
            0
            (if (= shape 0)
              (if (= platform 1)
                8
                6)
              (if (and (>= shape 3) (= platform 1))
                10
                1)))]
          (let
            [state : backend.CompilerBackendState
              (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
            [function-state : backend.CompilerBackendFunctionState
              (backend.compiler-backend-state-function-state state)]
            [windows? : bool (= platform 1)]
            [assignment : regalloc.CompilerRegAssignment
              (regalloc.CompilerRegAssignment
                7
                (Register
                  (cond
                    [(= shape 0)
                      (backend.compiler-backend-callee-save-order-reg-id
                        selection)]
                    [(< shape 3) cabi.compiler-reg-id-r12]
                    [else (cabi.compiler-abi-xmm-register-id (+ 6 selection))])))]
            [second : regalloc.CompilerRegAssignment
              (regalloc.CompilerRegAssignment
                8
                (Register cabi.compiler-reg-id-r13))]
            [homes : regalloc.CompilerRegAssignmentTable
              (regalloc.compiler-reg-assignments-prepend
                (& assignment)
                (if (or (= shape 1) (= shape 2))
                  (regalloc.compiler-reg-assignments-prepend
                    (& second)
                    (regalloc.compiler-reg-assignment-table-empty))
                  (regalloc.compiler-reg-assignment-table-empty)))]
            (backend.compiler-backend-function-state-set-bool!
              function-state
              backend.compiler-backend-function-bool-current-fn-win64
              windows?)
            (backend.compiler-backend-function-state-set-current-mode!
              function-state
              (match mode
                [0 (Scalar)]
                [1 (Avx2)]
                [_ (Avx512)]))
            (backend.compiler-backend-function-scratch-set-i64!
              function-state
              backend.compiler-backend-scratch-i64-current-source-function
              44)
            (backend.compiler-backend-function-state-set-i64!
              function-state
              backend.compiler-backend-function-i64-current-block-label
              10)
            (let
              [plain : String
                (backend-stack-origins-callee-emit state homes shape windows?)]
              (backend.compiler-backend-state-stack-origins-begin! state)
              (backend-stack-origins-install-test-plan! state false false)
              ;; No nearest instruction or stale post-body block can own a CSR.
              (backend.compiler-backend-function-state-set-emit-current-site!
                function-state
                -123)
              (backend.compiler-backend-function-state-set-i64!
                function-state
                backend.compiler-backend-function-i64-current-block-label
                -1)
              (let
                [text : String
                  (backend-stack-origins-callee-emit state homes shape windows?)]
                [capture : origins.CompilerBackendTextOrigins
                  (backend.compiler-backend-state-stack-text-origins state)]
                [facts : origins.CompilerBackendStackAccessOriginList
                  (backend.compiler-backend-state-stack-access-origins state)]
                [expected : i64
                  (if (< shape 3)
                    (if (= shape 0)
                      2
                      4)
                    (if windows?
                      2
                      0))]
                (test.assert-string-eq
                  text
                  plain
                  "ABI capture preserves complete emitted bytes")
                (test.assert-i64-eq
                  facts.len
                  expected
                  "one fact per actual save and restore")
                (test.assert-i64-eq
                  (array-length
                    (origins.compiler-backend-text-origins-find
                      capture
                      (& text)))
                  expected
                  "all parent joins retain actual instruction tokens, not unwind rows")
                (for [index (iterator.range 0 expected)]
                  (let
                    [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                      (& (array-ref facts.slots index))]
                    [writes : i64 0]
                    [reads : i64 0]
                    (test.assert-true
                      (match (& fact.owner)
                        [(CallAbi) true]
                        [_ false])
                      "callee saves are ABI traffic, never allocator traffic")
                    (test.assert-i64-eq
                      fact.home-bytes
                      (if (< shape 3)
                        8
                        16)
                      "exact ABI capacity")
                    (test.assert-true
                      (if (< shape 3)
                        (match (& fact.bank)
                          [(General) true]
                          [_ false])
                        (match (& fact.bank)
                          [(Vector) true]
                          [_ false]))
                      "ABI semantic bank is independent of execution mode")
                    (test.assert-i64-eq
                      fact.access-bytes
                      fact.home-bytes
                      "full saved width in every mode")
                    (test.assert-true
                      (match (& fact.anchor)
                        [(FunctionEntry)
                          (match (& fact.access)
                            [(Write) true]
                            [_ false])]
                        [(FunctionExit)
                          (match (& fact.access)
                            [(Read) true]
                            [_ false])]
                        [_ false])
                      "function entry/exit authority survives invalid current IR site")
                    (for [other (iterator.range 0 expected)]
                      (let
                        [candidate : (&
                          facts
                          origins.CompilerBackendStackAccessOrigin)
                          (& (array-ref facts.slots other))]
                        (when
                          (= candidate.home fact.home)
                          (match (& candidate.access)
                            [(Write) (+= writes 1)]
                            [(Read) (+= reads 1)]
                            [_ (io.panic "unexpected ABI RMW")]))))
                    (test.assert-i64-eq
                      writes
                      1
                      "one save per logical ABI home")
                    (test.assert-i64-eq
                      reads
                      1
                      "one restore per logical ABI home"))))
              (backend.compiler-backend-state-stack-origins-end! state))
            (backend.compiler-backend-state-release-final-arenas! state)))))))

(test
  backend-stack-origins-use-function-callee-authority
  (backend-stack-origins-callee-test))

(define (backend-stack-origins-callee-rebased
  [state : backend.CompilerBackendState]
  [homes : regalloc.CompilerRegAssignmentTable]
  [windows? : bool]) : String
  (let
    [capture : origins.CompilerBackendTextOrigins
      (backend.compiler-backend-state-stack-text-origins state)]
    [pushes : (__tl_dyn-array String)
      (backend.compiler-backend-rsp-rebase-make-push-regs)]
    [body : String
      (origins.compiler-backend-text-origins-cat
        capture
        (backend.compiler-backend-emit-save-callee-regs homes 10 state)
        "    movq %r12, %rax\n"
        (backend.compiler-backend-emit-restore-callee-regs homes 10 state)
        "    leave\n    ret\n")]
    (set! (array-ref pushes 0) "%r12")
    (let
      [result : backend.CompilerBackendRspRebaseResult
        (backend.compiler-backend-rsp-rebase-full-result-with-saves
          body
          128
          true
          (owned_view.compiler-owned-shared-view pushes)
          1
          (owned_view.compiler-owned-shared-view pushes)
          1
          10
          state)]
      (unless result.ok (io.panic "callee origin FPO fixture refused"))
      (origins.compiler-backend-text-origins-cat
        capture
        (if windows?
          (backend.compiler-backend-emit-function-entry-fpo-windows
            (backend.compiler-backend-target-policy-new (Windows))
            state
            "fixture"
            128
            homes
            10
            pushes
            1)
          (backend.compiler-backend-emit-function-entry-fpo-push
            state
            "fixture"
            128
            pushes
            1))
        result.text))))

(define (backend-stack-origins-callee-rebase-test) : unit
  (for [platform (iterator.range 0 2)]
    (let
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
      [function-state : backend.CompilerBackendFunctionState
        (backend.compiler-backend-state-function-state state)]
      [assignment : regalloc.CompilerRegAssignment
        (regalloc.CompilerRegAssignment 7 (Register cabi.compiler-reg-id-r12))]
      [homes : regalloc.CompilerRegAssignmentTable
        (regalloc.compiler-reg-assignments-prepend
          (& assignment)
          (regalloc.compiler-reg-assignment-table-empty))]
      (backend.compiler-backend-function-scratch-set-i64!
        function-state
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-i64!
        function-state
        backend.compiler-backend-function-i64-current-block-label
        10)
      (backend.compiler-backend-function-state-set-bool!
        function-state
        backend.compiler-backend-function-bool-current-fn-win64
        (= platform 1))
      (let
        [plain : String
          (backend-stack-origins-callee-rebased state homes (= platform 1))]
        (backend.compiler-backend-state-stack-origins-begin! state)
        (backend-stack-origins-install-test-plan! state false false)
        (let
          [text : String
            (backend-stack-origins-callee-rebased state homes (= platform 1))]
          [capture : origins.CompilerBackendTextOrigins
            (backend.compiler-backend-state-stack-text-origins state)]
          [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
            (origins.compiler-backend-text-origins-find capture (& text))]
          [facts : origins.CompilerBackendStackAccessOriginList
            (backend.compiler-backend-state-stack-access-origins state)]
          (test.assert-string-eq
            text
            plain
            "actual FPO seam leaves machine bytes unchanged")
          (test.assert-i64-eq
            facts.len
            4
            "old moves plus newly synthesized push/pop are retained")
          (test.assert-i64-eq
            (array-length spans)
            2
            "only new push/pop have final events")
          (for [index (iterator.range 0 2)]
            (let
              [token : i64 (array-ref spans index).token]
              (test.assert-true
                (and (>= token 2) (< token 4))
                "deleted move token does not survive")
              (test.assert-i64-eq
                (array-ref facts.slots token).home
                (array-ref facts.slots 0).home
                "FPO transports the original function resource")))))
      (backend.compiler-backend-state-release-final-arenas! state))))

(define (backend-stack-origins-frame-emit
  [state : backend.CompilerBackendState]
  [homes : regalloc.CompilerRegAssignmentTable]
  [path : i64]
  [windows? : bool]) : String
  (let
    [capture : origins.CompilerBackendTextOrigins
      (backend.compiler-backend-state-stack-text-origins state)]
    [source-function : i64
      (backend.compiler-backend-function-scratch-i64
        (backend.compiler-backend-state-function-state state)
        backend.compiler-backend-scratch-i64-current-source-function)]
    (if (= path 4)
      (backend.compiler-backend-return-tail-for-return-count
        state
        source-function
        homes
        10
        1)
      (if (= path 3)
        (let
          [no-push : (__tl_dyn-array String)
            (backend.compiler-backend-rsp-rebase-make-push-regs)]
          [result : backend.CompilerBackendRspRebaseResult
            (backend.compiler-backend-rsp-rebase-full-result-with-saves
              (backend.compiler-backend-inline-return-tail homes 10 state)
              128
              true
              (owned_view.compiler-owned-shared-view no-push)
              0
              (owned_view.compiler-owned-shared-view no-push)
              0
              10
              state)]
          (unless result.ok (io.panic "frame pointer FPO fixture refused"))
          (origins.compiler-backend-text-origins-cat
            capture
            (if windows?
              (backend.compiler-backend-emit-function-entry-fpo-windows
                (backend.compiler-backend-target-policy-new (Windows))
                state
                "frame_fixture"
                128
                homes
                10
                no-push
                0)
              (backend.compiler-backend-emit-function-entry-fpo
                state
                "frame_fixture"
                128))
            result.text))
        (origins.compiler-backend-text-origins-cat
          capture
          (backend.compiler-backend-emit-function-entry
            (backend.compiler-backend-target-policy-new
              (if windows?
                (Windows)
                (Linux)))
            "frame_fixture"
            128
            homes
            10
            false
            state)
          (match path
            [0 (backend.compiler-backend-inline-return-tail homes 10 state)]
            [1 (backend.compiler-backend-tail-jump-tail homes 10 "next" state)]
            [_
              (origins.compiler-backend-text-origins-cat
                capture
                (backend.compiler-backend-emit-save-callee-regs homes 10 state)
                (backend.compiler-backend-return-epilogue
                  state
                  source-function
                  homes
                  10
                  (ir_text.blocks
                    "entry:
  branch %0, first, second
first:
  return 0
second:
  return 1
")))]))))))

(define (backend-stack-origins-frame-test) : unit
  (let
    [inactive : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    (test.assert-string-eq
      (backend.compiler-backend-frame-pointer-operand-origin
        inactive
        "%rbp"
        (Write))
      "%rbp"
      "inactive frame factory preserves ordinary text")
    (test.assert-i64-eq
      (backend.compiler-backend-state-function-state-address inactive)
      0
      "inactive frame factory does not allocate a function owner")
    (backend.compiler-backend-state-stack-origins-begin! inactive)
    (test.assert-true
      (match (backend.compiler-backend-frame-pointer-context-check inactive)
        [(Err _) true]
        [_ false])
      "capture without a source function rejects")
    (test.assert-i64-eq
      (backend.compiler-backend-state-function-state-address inactive)
      0
      "rejected context does not materialize an owner")
    (backend.compiler-backend-state-release-final-arenas! inactive))
  (let
    [previous-debug : bool (ir.compiler-debug-info-enabled?)]
    (for [mode (iterator.range 0 3)]
      (for [platform (iterator.range 0 2)]
        (for [debug (iterator.range 0 2)]
          (ir.compiler-debug-info-set-enabled! (= debug 1))
          (for [path (iterator.range 0 5)]
            (let
              [intern : ci.InternCompatState (ci.intern-compat-state-new)]
              [function : i64
                (ci.intern-compat-state-intern (&mut intern) "frame_fixture")]
              [state : backend.CompilerBackendState
                (backend.compiler-backend-state-new
                  (owned_view.compiler-owned-shared-view intern))]
              [function-state : backend.CompilerBackendFunctionState
                (backend.compiler-backend-state-function-state state)]
              [block : i64 (ir.compiler-ir-label "frame_fixture_body")]
              [assignment : regalloc.CompilerRegAssignment
                (regalloc.CompilerRegAssignment
                  7
                  (Register cabi.compiler-reg-id-r12))]
              [homes : regalloc.CompilerRegAssignmentTable
                (if (= path 2)
                  (regalloc.compiler-reg-assignments-prepend
                    (& assignment)
                    (regalloc.compiler-reg-assignment-table-empty))
                  (regalloc.compiler-reg-assignment-table-empty))]
              (backend.compiler-backend-function-state-set-bool!
                function-state
                backend.compiler-backend-function-bool-current-fn-win64
                (= platform 1))
              (backend.compiler-backend-function-state-set-current-mode!
                function-state
                (match mode
                  [0 (Scalar)]
                  [1 (Avx2)]
                  [_ (Avx512)]))
              (backend.compiler-backend-function-scratch-set-i64!
                function-state
                backend.compiler-backend-scratch-i64-current-source-function
                function)
              (backend.compiler-backend-function-state-set-i64!
                function-state
                backend.compiler-backend-function-i64-current-block-label
                block)
              (when
                (= path 4)
                (backend.compiler-backend-function-state-set-string!
                  function-state
                  backend.compiler-backend-function-string-shrinkwrap-bare-label
                  (ir.compiler-ir-label-text block)))
              (let
                [plain : String
                  (backend-stack-origins-frame-emit
                    state
                    homes
                    path
                    (= platform 1))]
                (backend.compiler-backend-state-stack-origins-begin! state)
                (test.assert-true
                  (match (backend.compiler-backend-frame-pointer-context-check
                    state)
                    [(Err _) true]
                    [_ false])
                  "a synthetic/empty function owner cannot inherit another frame")
                (unless
                  (= path 4)
                  (backend-stack-origins-install-test-plan! state false false)
                  (test.assert-true
                    (match (backend.compiler-backend-frame-pointer-context-check
                      state)
                      [(Ok) true]
                      [_ false])
                    "exact source-function frame plan is accepted")
                  (backend.compiler-backend-function-scratch-set-i64!
                    function-state
                    backend.compiler-backend-scratch-i64-current-source-function
                    (+ function 1))
                  (test.assert-true
                    (match (backend.compiler-backend-frame-pointer-context-check
                      state)
                      [(Err _) true]
                      [_ false])
                    "another source function cannot use this plan")
                  (backend.compiler-backend-function-scratch-set-i64!
                    function-state
                    backend.compiler-backend-scratch-i64-current-source-function
                    function))
                (let
                  [text : String
                    (backend-stack-origins-frame-emit
                      state
                      homes
                      path
                      (= platform 1))]
                  [capture : origins.CompilerBackendTextOrigins
                    (backend.compiler-backend-state-stack-text-origins state)]
                  [facts : origins.CompilerBackendStackAccessOriginList
                    (backend.compiler-backend-state-stack-access-origins state)]
                  [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
                    (origins.compiler-backend-text-origins-access-spans
                      capture
                      (& text))]
                  [expected : i64
                    (match path
                      [2 4]
                      [3 1]
                      [4 0]
                      [_ 2])]
                  (test.assert-string-eq
                    text
                    plain
                    "frame annotations preserve all machine/unwind bytes")
                  (test.assert-i64-eq
                    facts.len
                    expected
                    "actual frame and callee authorities")
                  (test.assert-i64-eq
                    (array-length spans)
                    (if (= path 3)
                      0
                      expected)
                    "FPO deletes its provisional leave token; CFI/SEH rows issue none")
                  (when
                    (= path 2)
                    (test.assert-true
                      (!=
                        (array-ref facts.slots 0).home
                        (array-ref facts.slots 1).home)
                      "shared frame and callee register are separate logical resources"))
                  (for [index (iterator.range 0 facts.len)]
                    (let
                      [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                        (& (array-ref facts.slots index))]
                      (test.assert-i64-eq
                        fact.function.value
                        function
                        "actual emitted source function")
                      (test.assert-i64-eq
                        fact.home-bytes
                        8
                        "function frame or GP home capacity")
                      (test.assert-i64-eq
                        fact.access-bytes
                        8
                        "one full pointer access")
                      (test.assert-true
                        (match (& fact.owner)
                          [(CallAbi) true]
                          [_ false])
                        "frame owner is ABI")
                      (test.assert-true
                        (match (& fact.bank)
                          [(General) true]
                          [_ false])
                        "frame bank is GP")
                      (test.assert-true
                        (match (& fact.anchor)
                          [(FunctionEntry)
                            (match (& fact.access)
                              [(Write) true]
                              [_ false])]
                          [(FunctionExit)
                            (match (& fact.access)
                              [(Read) true]
                              [_ false])]
                          [_ false])
                        "frame direction comes from its entry/exit authority")))
                  (when
                    (= path 4)
                    (test.assert-string-eq
                      text
                      "    ret\n"
                      "bare shrinkwrap bypass has no frame access")))
                (backend.compiler-backend-state-stack-origins-end! state))
              (backend.compiler-backend-state-release-final-arenas! state))))))
    (ir.compiler-debug-info-set-enabled! previous-debug)))

(test
  backend-stack-origins-frame-pointer-and-epilogues
  (backend-stack-origins-frame-test))

(define (backend-stack-origins-adapter-test) : unit
  (builtin_ids.compiler-builtin-initialize-for-parse!)
  (for [platform (iterator.range 0 2)]
    (for [mode (iterator.range 0 3)]
      (for [shape (iterator.range 0 4)]
        (for [nested (iterator.range 0 2)]
          (let
            [intern : ci.InternCompatState (ci.intern-compat-state-new)]
            [name : i64
              (ci.intern-compat-state-intern (&mut intern) "adapter_target")]
            [collision : i64
              (ci.intern-compat-state-intern
                (&mut intern)
                ".L_tl_fn_entry_adapter_target")]
            [state : backend.CompilerBackendState
              (backend.compiler-backend-state-new
                (owned_view.compiler-owned-shared-view intern))]
            [outer : backend.CompilerBackendFunctionState
              (if (= nested 1)
                (backend.compiler-backend-state-function-state state)
                (backend.compiler-backend-function-state-new))]
            [outer-address : i64
              (backend.compiler-backend-state-function-state-address state)]
            [target : backend.CompilerBackendTarget
              (if (= platform 0)
                (Linux)
                (Windows))]
            [types : ast.AstTypeList (ast.ast-type-list-with-capacity 9)]
            [ty : ast.AstType
              (match shape
                [1 (I64)]
                [2 (F32)]
                [_
                  (Struct
                    (ir.compiler-ir-symbol
                      "__tl_internal_abi_group_m0__adapter"))])]
            [index : backend.CompilerBackendProgramIndex
              (backend.compiler-backend-program-index-build-with-backend-state-and-profile-state
                state
                (ast.ast-node-pool-reader-type-segment-bases)
                (if (= shape 3)
                  (ir.CompilerIrFunctionSeq
                    (__tl_make-array
                      (ir.CompilerIrFunction.Function
                        name
                        (ir.compiler-ir-param-seq-empty)
                        (clone ty)
                        1
                        (ir.CompilerIrBlockList.Array
                          (ir.CompilerIrBlockSeq
                            (__tl_make-array
                              (ir.CompilerIrBlock.Block
                                (ir.compiler-ir-label "adapter_pack")
                                (ir.CompilerIrInstrSeq
                                  (__tl_make-array
                                    (ir.CompilerIrInstr.Pack
                                      0
                                      (ir.compiler-ir-value-seq2
                                        (I64 1)
                                        (I64 2))
                                      (clone ty))
                                    (ir.CompilerIrInstr.Return (Some (Var 0))))
                                  2)))
                            1))
                        Ordinary))
                    1)
                  (ir.compiler-ir-function-seq-empty))
                (ir.compiler-ir-extern-seq-empty)
                (profile_state.compiler-profile-state-new))]
            [runtime : backend.CompilerBackendRuntimePlan
              (match (backend.compiler-backend-runtime-plan-with-backend-state
                state
                (Program
                  (ir.compiler-ir-global-seq-empty)
                  (ir.compiler-ir-function-seq-empty)
                  (ir.compiler-ir-extern-seq-empty)))
                [(Ok result) result]
                [(Err _) (io.panic "adapter runtime refused")])]
            (backend.compiler-backend-state-set-emission-target-policy!
              state
              (backend.compiler-backend-target-policy-new target))
            (backend.compiler-backend-function-state-set-current-mode!
              outer
              (match mode
                [0 (Scalar)]
                [1 (Avx2)]
                [_ (Avx512)]))
            (backend.compiler-backend-function-scratch-set-i64!
              outer
              backend.compiler-backend-scratch-i64-current-source-function
              name)
            (backend.compiler-backend-function-state-set-i64!
              outer
              backend.compiler-backend-function-i64-current-block-label
              10)
            (for [param
              (iterator.range
                0
                (if (= shape 0)
                  0
                  9))]
              (ast.ast-type-list-push
                (&mut types)
                (ast.ast-node-pool-reader-type-push (& ty))))
            (let
              [plain : String
                (match (backend.compiler-backend-emit-closure-entry-adapter-owned
                  (ast.ast-node-pool-reader-type-segment-bases)
                  target
                  name
                  (owned_view.compiler-owned-shared-view types)
                  (I64)
                  runtime
                  (ir.compiler-ir-function-seq-empty)
                  (ir.compiler-ir-extern-seq-empty)
                  index)
                  [(Ok text) text]
                  [(Err _) (io.panic "ordinary adapter refused")])]
              (backend.compiler-backend-state-stack-origins-begin! state)
              (when
                (= nested 1)
                (backend-stack-origins-install-test-plan! state false false))
              (let
                [before : i64
                  (backend.compiler-backend-function-scratch-i64
                    outer
                    backend.compiler-backend-scratch-i64-stack-home-plan)]
                [text : String
                  (match (backend.compiler-backend-emit-closure-entry-adapter-owned
                    (ast.ast-node-pool-reader-type-segment-bases)
                    target
                    name
                    (owned_view.compiler-owned-shared-view types)
                    (I64)
                    runtime
                    (ir.compiler-ir-function-seq-empty)
                    (ir.compiler-ir-extern-seq-empty)
                    index)
                    [(Ok result) result]
                    [(Err _) (io.panic "captured adapter refused")])]
                [capture : origins.CompilerBackendTextOrigins
                  (backend.compiler-backend-state-stack-text-origins state)]
                [facts : origins.CompilerBackendStackAccessOriginList
                  (backend.compiler-backend-state-stack-access-origins state)]
                [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
                  (origins.compiler-backend-text-origins-access-spans
                    capture
                    (& text))]
                [frame-home : i64 -1]
                [synthetic : i64 -1]
                [writes : i64 0]
                [reads : i64 0]
                [frame : i64 0]
                [incoming : i64 0]
                [outgoing : i64 0]
                (test.assert-string-eq
                  text
                  plain
                  "adapter capture changes no assembly bytes")
                (let
                  [buffer : text_buf.TextBuf
                    (text_buf.append
                      (text_buf.append (text_buf.empty) ".text\n")
                      (owned_view.compiler-owned-shared-view text))]
                  [rendered : String
                    (backend.compiler-backend-render-assembly-buffer
                      state
                      buffer)]
                  (test.assert-string-eq
                    rendered
                    (string.concat3-borrowed ".text\n" (& text) "")
                    "final buffer render preserves actual adapter bytes")
                  (match (backend.compiler-backend-final-stack-functions
                    state
                    rendered)
                    [(Err message) (io.panic message)]
                    [(Ok functions)
                      (test.assert-i64-eq
                        (array-length functions)
                        1
                        "one actual generated adapter extent")
                      (test.assert-i64-eq
                        (array-length (array-ref functions 0).accesses)
                        (array-length spans)
                        "every retained adapter access belongs to its final emitted instruction")
                      (test.assert-i64-eq
                        (array-ref functions 0).function.value
                        (array-ref facts.slots 0).function.value
                        "the final reader uses generated identity rather than label spelling")]))
                (test.assert-i64-eq
                  (backend.compiler-backend-state-function-state-address state)
                  outer-address
                  "adapter restores actual caller owner")
                (test.assert-i64-eq
                  (backend.compiler-backend-function-scratch-i64
                    outer
                    backend.compiler-backend-scratch-i64-stack-home-plan)
                  before
                  "adapter cannot borrow or replace caller's plan")
                (test.assert-true
                  (> (array-length spans) 0)
                  "adapter retains final operand tokens")
                (for [i (iterator.range 0 (array-length spans))]
                  (let
                    [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                      (& (array-ref facts.slots (array-ref spans i).token))]
                    (when (< synthetic 0) (set! synthetic fact.function.value))
                    (test.assert-i64-eq
                      fact.function.value
                      synthetic
                      "one emitted adapter authority")
                    (test.assert-true
                      (and (!= synthetic name) (!= synthetic collision))
                      "adapter differs from target and equal-spelling source symbol")
                    (match (& fact.anchor)
                      [(FunctionEntry)
                        (set! frame-home fact.home)
                        (+= frame 1)]
                      [(FunctionExit)
                        (test.assert-i64-eq
                          fact.home
                          frame-home
                          "actual frame push/pop resource")
                        (+= frame 1)]
                      [(FunctionParameters)
                        (+= incoming 1)
                        (test.assert-i64-eq
                          fact.home-bytes
                          8
                          "ABI stack word capacity")
                        (test.assert-i64-eq
                          fact.access-bytes
                          (if (= shape 2)
                            4
                            8)
                          "actual incoming read width")
                        (test.assert-true
                          (match (& fact.access)
                            [(Read) true]
                            [_ false])
                          "incoming ABI area is read, not the local initialization")]
                      [(AdapterBody)
                        (when
                          (and
                            (>= fact.home 27)
                            (match (& fact.owner)
                              [(CallAbi) true]
                              [_ false]))
                          (+= outgoing 1)
                          (test.assert-true
                            (match (& fact.access)
                              [(Write) true]
                              [_ false])
                            "outgoing words are written"))
                        (when
                          (and
                            (< fact.home 27)
                            (match (& fact.owner)
                              [(CallAbi) true]
                              [_ false]))
                          (test.assert-i64-eq
                            fact.home-bytes
                            8
                            "one parameter word")
                          (match (& fact.access)
                            [(Write) (+= writes 1)]
                            [(Read) (+= reads 1)]
                            [_
                              (test.assert-true
                                false
                                "adapter parameter is not RMW")]))]
                      [_
                        (test.assert-true
                          false
                          "adapter cannot inherit a source block")])))
                (test.assert-i64-eq frame 2 "one real frame push and pop")
                (let
                  [abi : cabi.CompilerRegTargetAbi
                    (if (= platform 0)
                      (Linux)
                      (Windows))]
                  [words : i64 (cond [(= shape 0) 0] [(= shape 3) 18] [else 9])]
                  [registers : i64
                    (if (= shape 2)
                      (cabi.compiler-abi-float-arg-register-count
                        abi
                        (Internal))
                      (cabi.compiler-abi-gp-arg-register-count abi (Internal)))]
                  (test.assert-i64-eq
                    outgoing
                    (if (> words registers)
                      (- words registers)
                      0)
                    "forwarded call has no hidden closure argument"))
                (let
                  [abi : cabi.CompilerRegTargetAbi
                    (if (= platform 0)
                      (Linux)
                      (Windows))]
                  [words : i64 (cond [(= shape 0) 0] [(= shape 3) 18] [else 9])]
                  [registers : i64
                    (if (= shape 2)
                      (-
                        (cabi.compiler-abi-float-arg-register-count
                          abi
                          (Internal))
                        (if (= platform 1)
                          1
                          0))
                      (-
                        (cabi.compiler-abi-gp-arg-register-count abi (Internal))
                        1))]
                  ;; SysV admits an aggregate only when both words fit.
                  (when
                    (and (= shape 3) (= platform 0))
                    (set! registers (* 2 (/ registers 2))))
                  (test.assert-i64-eq
                    incoming
                    (if (> words registers)
                      (- words registers)
                      0)
                    "independent ABI register inventory predicts every stack read"))
                (test.assert-i64-eq
                  writes
                  (cond [(= shape 0) 0] [(= shape 3) 18] [else 9])
                  "explicit Pack representation authorizes both parameter words")
                (test.assert-i64-eq
                  reads
                  writes
                  "forwarding reads those same local words"))
              (backend.compiler-backend-state-stack-origins-end! state))
            (backend.compiler-backend-state-release-final-arenas! state)))))))

(test
  backend-stack-origins-synthetic-adapter-owner
  (backend-stack-origins-adapter-test))

(define (backend-stack-origins-tail-store-text
  [type-bases : i64]
  [target : backend.CompilerBackendTarget]
  [homes : regalloc.CompilerRegAssignmentTable]
  [value : ir.CompilerIrValue]
  [ty : ast.AstType]
  [parallel? : bool]
  [_slot : i64]
  [state : backend.CompilerBackendState]) : backend.ResultCompilerBackend
  (unless
    parallel?
    (return
      (backend.compiler-backend-emit-direct-tail-stack-call-arg
        type-bases
        target
        homes
        value
        (clone ty)
        (backend.compiler-backend-float-type? (& ty))
        0
        state)))
  (let
    [values : (__tl_dyn-array ir.CompilerIrValue)
      (__tl_make-array ir.CompilerIrValue 9)]
    [types : ast.AstTypeList (ast.ast-type-list-with-capacity 9)]
    [out : backend.CompilerBackendAsmBuf
      (backend.compiler-backend-asm-buf-with-capacity 2048)]
    (for [i (iterator.range 0 9)]
      (set! (array-ref values i) (Var 0))
      (ast.ast-type-list-push
        (&mut types)
        (ast.ast-node-pool-reader-type-push (& ty))))
    (backend.compiler-backend-asm-buf-capture!
      (&mut out)
      (backend.compiler-backend-state-stack-text-origins state))
    (let
      [seq : ir.CompilerIrValueSeq (ir.CompilerIrValueSeq values 9)]
      [args : ir.CompilerIrCallArgs (ir.compiler-ir-call-args-from-seq (& seq))]
      (match (backend.compiler-backend-emit-call-args-parallel-into
        (&mut out)
        (IncomingStackArgArea)
        type-bases
        target
        (Internal)
        homes
        (& args)
        (& types)
        0
        0
        0
        0
        state)
        [(Err message) (Err message)]
        [(Ok _) (Ok (backend.compiler-backend-asm-buf-finish (& out)))]))))

(define (backend-stack-origins-tail-slot-test) : unit
  (for [platform (iterator.range 0 2)]
    (for [kind (iterator.range 0 4)]
      (let
        [state : backend.CompilerBackendState
          (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
        [fn : backend.CompilerBackendFunctionState
          (backend.compiler-backend-state-function-state state)]
        [target : backend.CompilerBackendTarget
          (if (= platform 0)
            (Linux)
            (Windows))]
        [assignment : regalloc.CompilerRegAssignment
          (regalloc.CompilerRegAssignment
            0
            (Register (cabi.compiler-abi-xmm-register-id 0)))]
        [homes : regalloc.CompilerRegAssignmentTable
          (if (= kind 3)
            (regalloc.compiler-reg-assignments-prepend
              (& assignment)
              (regalloc.compiler-reg-assignment-table-empty))
            (regalloc.compiler-reg-assignment-table-empty))]
        [ty : ast.AstType
          (if (or (= kind 1) (= kind 3))
            (F32)
            (I64))]
        [value : ir.CompilerIrValue
          (cond [(= kind 0) (I64 42)] [(= kind 1) (F64 0)] [else (Var 0)])]
        [blocks : ir.CompilerIrBlockList
          (ir_text.blocks "entry:
  %1 = call tail_slot(%0) : i64
  return %1
")]
        (backend.compiler-backend-function-scratch-set-i64!
          fn
          backend.compiler-backend-scratch-i64-current-source-function
          44)
        (backend.compiler-backend-function-state-set-emit-current-site! fn 0)
        (let
          [plain : String
            (match (backend-stack-origins-tail-store-text
              (ast.ast-node-pool-reader-type-segment-bases)
              target
              (owned_view.compiler-owned-shared-view homes)
              (clone value)
              (clone ty)
              (= kind 3)
              0
              state)
              [(Ok text) text]
              [(Err _) (io.panic "plain tail store refused")])]
          (backend.compiler-backend-state-stack-origins-begin! state)
          (let
            [input : home_origins.CompilerBackendHomePlanInput
              (home_origins.CompilerBackendHomePlanInput
                44
                2
                2
                (ir.compiler-ir-param-seq-empty)
                (owned_view.compiler-owned-shared-view blocks)
                blocks
                (None)
                (live.compiler-live-set-empty))]
            [plan : home_origins.CompilerBackendHomePlan
              (match (home_origins.compiler-backend-home-plan-build (& input))
                [(Ok result) result]
                [(Err message) (io.panic message)])]
            (backend.compiler-backend-function-state-set-i64!
              fn
              backend.compiler-backend-function-i64-current-block-label
              plan.entry-block)
            (backend.compiler-backend-stack-home-plan-install! fn plan))
          (let
            [text : String
              (match (backend-stack-origins-tail-store-text
                (ast.ast-node-pool-reader-type-segment-bases)
                target
                homes
                value
                ty
                (= kind 3)
                0
                state)
                [(Ok result) result]
                [(Err _) (io.panic "captured tail store refused")])]
            [capture : origins.CompilerBackendTextOrigins
              (backend.compiler-backend-state-stack-text-origins state)]
            [facts : origins.CompilerBackendStackAccessOriginList
              (backend.compiler-backend-state-stack-access-origins state)]
            [writes : i64 0]
            (test.assert-string-eq
              text
              plain
              "tail stores preserve complete assembly")
            (test.assert-i64-eq
              (array-length
                (origins.compiler-backend-text-origins-find capture (& text)))
              (cond
                [(= kind 2) 2]
                [(= kind 3)
                  (if (= platform 0)
                    1
                    5)]
                [else 1])
              "tail composition transports read and write operands")
            (for [i (iterator.range 0 facts.len)]
              (let
                [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                  (& (array-ref facts.slots i))]
                (when
                  (match (& fact.owner)
                    [(CallAbi) true]
                    [_ false])
                  (+= writes 1)
                  (test.assert-i64-eq fact.home-bytes 8 "one tail ABI word")
                  (test.assert-i64-eq
                    fact.access-bytes
                    (if (or (= kind 1) (= kind 3))
                      4
                      8)
                    "actual tail store width")
                  (test.assert-true
                    (match (& fact.access)
                      [(Write) true]
                      [_ false])
                    "tail overwrites are writes"))))
            (test.assert-i64-eq
              writes
              (if (= kind 3)
                (if (= platform 0)
                  1
                  5)
                1)
              "tail-area resource writes"))
          (backend.compiler-backend-state-stack-origins-end! state))
        (backend.compiler-backend-state-release-final-arenas! state)))))

(test
  backend-stack-origins-tail-stack-slots
  (backend-stack-origins-tail-slot-test))

(define (backend-stack-origins-c-memory-plan!
  [state : backend.CompilerBackendState]) : unit
  (let
    [instructions : (__tl_dyn-array ir.CompilerIrInstr)
      (__tl_make-array ir.CompilerIrInstr 37)]
    [fn : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    [label : i64 (ir.compiler-ir-label "aggregate_copy_entry")]
    (for [i (iterator.range 0 36)]
      (set!
        (array-ref instructions i)
        (Call
          (+ i 1)
          (ir.compiler-ir-symbol "aggregate_copy_target")
          (ir.compiler-ir-call-args-from-seq
            (& (ir.compiler-ir-value-seq1 (Var 0))))
          (I64))))
    (set! (array-ref instructions 36) (Return (Some (I64 0))))
    (let
      [blocks : ir.CompilerIrBlockList
        (Array
          (ir.CompilerIrBlockSeq
            (__tl_make-array
              (ir.CompilerIrBlock.Block
                label
                (ir.CompilerIrInstrSeq instructions 37)))
            1))]
      [params : ir.CompilerIrParamSeq
        (ir.CompilerIrParamSeq
          (__tl_make-array (ir.CompilerIrParam.Param "pointer" (I64) 0))
          1)]
      [input : home_origins.CompilerBackendHomePlanInput
        (home_origins.CompilerBackendHomePlanInput
          44
          37
          37
          params
          (owned_view.compiler-owned-shared-view blocks)
          blocks
          (None)
          (live.compiler-live-set-empty))]
      [plan : home_origins.CompilerBackendHomePlan
        (match (home_origins.compiler-backend-home-plan-build (& input))
          [(Ok result) result]
          [(Err message) (io.panic message)])]
      (backend.compiler-backend-function-scratch-set-i64!
        fn
        backend.compiler-backend-scratch-i64-current-source-function
        44)
      (backend.compiler-backend-function-state-set-i64!
        fn
        backend.compiler-backend-function-i64-current-block-label
        label)
      (backend.compiler-backend-stack-home-plan-install! fn plan))))

(define (backend-stack-origins-c-memory-test) : unit
  (let
    [valid : backend.CompilerBackendCMemoryStackCopy
      (backend.CompilerBackendCMemoryStackCopy 2 24 16 "%r10" "%xmm2")]
    (for [invalid (iterator.range 0 10)]
      (let
        [bad : backend.CompilerBackendCMemoryStackCopy (clone valid)]
        (cond
          [(= invalid 0) (set! bad.stack-word -1)]
          [(= invalid 1) (set! bad.bytes -1)]
          [(= invalid 2) (set! bad.bytes 9223372036854775807)]
          [(= invalid 3) (set! bad.dst-offset -1)]
          [(= invalid 4) (set! bad.dst-offset 9223372036854775807)]
          [(= invalid 9) (set! bad.stack-word 1152921504606846975)]
          [else unit])
        (test.assert-true
          (match (backend.compiler-backend-c-memory-stack-copy-check
            (& bad)
            (cond [(= invalid 5) -1] [(= invalid 6) 25] [else 0])
            (cond [(= invalid 7) -1] [(= invalid 8) 23] [else 24]))
            [(Err _) true]
            [_ false])
          "malformed copy range rejects before tokens are published"))))
  (for [platform (iterator.range 0 2)]
    (for [mode (iterator.range 0 3)]
      (let
        [state : backend.CompilerBackendState
          (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
        [fn : backend.CompilerBackendFunctionState
          (backend.compiler-backend-state-function-state state)]
        [plain-state : backend.CompilerBackendState
          (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
        [plain-fn : backend.CompilerBackendFunctionState
          (backend.compiler-backend-state-function-state plain-state)]
        [assignment : regalloc.CompilerRegAssignment
          (regalloc.CompilerRegAssignment 0 (Register cabi.compiler-reg-id-r9))]
        [homes : regalloc.CompilerRegAssignmentTable
          (regalloc.compiler-reg-assignments-prepend
            (& assignment)
            (regalloc.compiler-reg-assignment-table-empty))]
        [target : backend.CompilerBackendTarget
          (if (= platform 0)
            (Linux)
            (Windows))]
        [last-home : i64 -1]
        (backend.compiler-backend-function-state-set-current-mode!
          fn
          (match mode
            [0 (Scalar)]
            [1 (Avx2)]
            [_ (Avx512)]))
        (backend.compiler-backend-function-state-set-current-mode!
          plain-fn
          (match mode
            [0 (Scalar)]
            [1 (Avx2)]
            [_ (Avx512)]))
        (for [size (iterator.range 0 36)]
          (let
            [plain : String
              (match (backend.compiler-backend-emit-c-memory-stack-arg
                (ast.ast-node-pool-reader-type-segment-bases)
                target
                (Platform)
                (owned_view.compiler-owned-shared-view homes)
                (Var 0)
                2
                size
                plain-state)
                [(Ok result) result]
                [(Err _) (io.panic "ordinary aggregate refused")])]
            (when
              (= size 0)
              (backend.compiler-backend-state-stack-origins-begin! state)
              (backend-stack-origins-c-memory-plan! state))
            (backend.compiler-backend-function-state-set-emit-current-site!
              fn
              size)
            (let
              [text : String
                (match (backend.compiler-backend-emit-c-memory-stack-arg
                  (ast.ast-node-pool-reader-type-segment-bases)
                  target
                  (Platform)
                  (owned_view.compiler-owned-shared-view homes)
                  (Var 0)
                  2
                  size
                  state)
                  [(Ok result) result]
                  [(Err _) (io.panic "captured aggregate refused")])]
              [capture : origins.CompilerBackendTextOrigins
                (backend.compiler-backend-state-stack-text-origins state)]
              [facts : origins.CompilerBackendStackAccessOriginList
                (backend.compiler-backend-state-stack-access-origins state)]
              [spans : (__tl_dyn-array origins.CompilerBackendTextOrigin)
                (origins.compiler-backend-text-origins-find capture (& text))]
              [offset : i64 0]
              [home : i64 -1]
              [wide : i64 (/ size 16)]
              [tail : i64 (% size 16)]
              [count : i64
                (+
                  wide
                  (+
                    (if (!= (bit-and tail 8) 0)
                      1
                      0)
                    (+
                      (if (!= (bit-and tail 4) 0)
                        1
                        0)
                      (+
                        (if (!= (bit-and tail 2) 0)
                          1
                          0)
                        (if (!= (bit-and tail 1) 0)
                          1
                          0)))))]
              (test.assert-string-eq
                text
                plain
                "all aggregate copy machine bytes preserved")
              (test.assert-i64-eq
                (array-length spans)
                count
                "binary tail decomposition counts actual stores")
              (for [i (iterator.range 0 (array-length spans))]
                (let
                  [span : (& spans origins.CompilerBackendTextOrigin)
                    (& (array-ref spans i))]
                  [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                    (& (array-ref facts.slots span.token))]
                  [width : i64
                    (if (< i wide)
                      16
                      0)]
                  (when
                    (= width 0)
                    (for [bit (iterator.range 0 4)]
                      (let
                        [value : i64 (shr 8 bit)]
                        (when
                          (and (= width 0) (!= (bit-and tail value) 0))
                          (set! width value)
                          (set! tail (- tail value))))))
                  (test.assert-i64-eq
                    fact.function.value
                    44
                    "actual source function")
                  (when (< home 0) (set! home fact.home))
                  (test.assert-i64-eq
                    fact.home
                    home
                    "one logical by-value aggregate")
                  (test.assert-i64-eq
                    fact.home-bytes
                    (* 8 (/ (+ size 7) 8))
                    "ABI word-rounded capacity")
                  (test.assert-i64-eq
                    fact.access-bytes
                    width
                    "exact store width")
                  (test.assert-true
                    (match (& fact.bank)
                      [(Vector) (>= width 4)]
                      [(General) (< width 4)]
                      [_ false])
                    "actual XMM or low GP sub-register bank")
                  (test.assert-true
                    (match (& fact.owner)
                      [(CallAbi) true]
                      [_ false])
                    "aggregate is ABI traffic")
                  (test.assert-true
                    (match (& fact.access)
                      [(Write) true]
                      [_ false])
                    "copy destination is written")
                  (let
                    [address : String
                      (string.int->string
                        (+
                          (if (= platform 0)
                            16
                            48)
                          offset))]
                    [expected : String (string.concat (& address) "(%rsp)")]
                    (test.assert-string-eq
                      span.expected
                      expected
                      "layout only renders the typed operand"))
                  (+= offset width)))
              (test.assert-i64-eq
                offset
                size
                "no overread-width store in one/two-byte tails")
              (when
                (> size 0)
                (test.assert-true
                  (!= home last-home)
                  "distinct source call sites stay distinct")
                (set! last-home home)))))
        (backend.compiler-backend-state-stack-origins-end! state)
        (backend.compiler-backend-state-release-final-arenas! state)
        (backend.compiler-backend-state-release-final-arenas! plain-state)))))

(test
  backend-stack-origins-c-memory-aggregate-copies
  (backend-stack-origins-c-memory-test))

(define (backend-stack-origins-local-emit
  [state : backend.CompilerBackendState]
  [homes : regalloc.CompilerRegAssignmentTable]
  [step : i64]
  [floating? : bool]) : String
  (let
    [ty : ast.AstType
      (if floating?
        (F32)
        (I64))]
    [value : ir.CompilerIrValue (Var 1)]
    (cond
      [(= step 1)
        (match (backend.compiler-backend-emit-addr-of homes 2 1 state)
          [(Ok text) text]
          [(Err _) (io.panic "local fixture emission refused")])]
      [(= step 2)
        (if floating?
          (backend.compiler-backend-emit-load-float-var
            homes
            1
            ty
            "%xmm3"
            state)
          (match (backend.compiler-backend-emit-load-value
            homes
            (& value)
            "%r10"
            state)
            [(Ok text) text]
            [(Err _) (io.panic "local fixture emission refused")]))]
      [else
        (let
          [var : i64
            (if (= step 0)
              1
              3)]
          (if floating?
            (backend.compiler-backend-emit-store-float-var
              homes
              var
              "%xmm3"
              (& ty)
              state)
            (backend.compiler-backend-emit-store-var homes var "%r10" state)))])))

(define (backend-stack-origins-local-test) : unit
  (for [platform (iterator.range 0 2)]
    (for [mode (iterator.range 0 3)]
      (for [assigned (iterator.range 0 2)]
        (for [shape (iterator.range 0 2)]
          (let
            [state : backend.CompilerBackendState
              (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
            [fn : backend.CompilerBackendFunctionState
              (backend.compiler-backend-state-function-state state)]
            [ty : ast.AstType
              (if (= shape 0)
                (I64)
                (F32))]
            [instructions : (__tl_dyn-array ir.CompilerIrInstr)
              (__tl_make-array ir.CompilerIrInstr 4)]
            [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
            [homes : regalloc.CompilerRegAssignmentTable
              (regalloc.compiler-reg-assignment-table-empty)]
            (backend.compiler-backend-function-state-set-current-mode!
              fn
              (match mode
                [0 (Scalar)]
                [1 (Avx2)]
                [_ (Avx512)]))
            (backend.compiler-backend-state-set-emission-target-policy!
              state
              (backend.compiler-backend-target-policy-new
                (if (= platform 0)
                  (Linux)
                  (Windows))))
            (set!
              (array-ref instructions 0)
              (Mov
                7
                (if (= shape 0)
                  (I64 1)
                  (F64 0))
                (clone ty)))
            (set! (array-ref instructions 1) (AddrOf 8 7))
            (set! (array-ref instructions 2) (Mov 9 (Var 7) (clone ty)))
            (set! (array-ref instructions 3) (Return (Some (Var 9))))
            (for [i (iterator.range 0 10)]
              (set! (array-ref map i) i))
            (set! (array-ref map 7) 1)
            (set! (array-ref map 8) 2)
            (set! (array-ref map 9) 3)
            (when
              (> assigned 0)
              (for [i (iterator.range 1 4)]
                (let
                  [assignment : regalloc.CompilerRegAssignment
                    (regalloc.CompilerRegAssignment i (Spill (- -48 (* 16 i))))]
                  (set!
                    homes
                    (regalloc.compiler-reg-assignments-prepend
                      (& assignment)
                      homes)))))
            (let
              [blocks : ir.CompilerIrBlockList
                (Array
                  (ir.CompilerIrBlockSeq
                    (__tl_make-array
                      (ir.CompilerIrBlock.Block
                        10
                        (ir.CompilerIrInstrSeq instructions 4)))
                    1))]
              [input : home_origins.CompilerBackendHomePlanInput
                (home_origins.CompilerBackendHomePlanInput
                  44
                  10
                  10
                  (ir.compiler-ir-param-seq-empty)
                  (owned_view.compiler-owned-shared-view blocks)
                  (regalloc.compiler-reg-remap-blocks (& map) (& blocks))
                  (Remap map 10)
                  (live.compiler-live-set-empty))]
              [plan : home_origins.CompilerBackendHomePlan
                (match (home_origins.compiler-backend-home-plan-build (& input))
                  [(Ok result) result]
                  [(Err message) (io.panic message)])]
              (backend.compiler-backend-function-scratch-set-i64!
                fn
                backend.compiler-backend-scratch-i64-current-source-function
                44)
              (backend.compiler-backend-function-state-set-i64!
                fn
                backend.compiler-backend-function-i64-current-block-label
                10)
              (let
                [plain : (__tl_dyn-array String) (__tl_make-array String 4)]
                (for [step (iterator.range 0 4)]
                  (backend.compiler-backend-function-state-set-emit-current-site!
                    fn
                    (if (= step 3)
                      2
                      step))
                  (set!
                    (array-ref plain step)
                    (backend-stack-origins-local-emit
                      state
                      (owned_view.compiler-owned-shared-view homes)
                      step
                      (> shape 0))))
                (backend.compiler-backend-state-stack-origins-begin! state)
                (backend.compiler-backend-stack-home-plan-install! fn plan)
                (for [step (iterator.range 0 4)]
                  (backend.compiler-backend-function-state-set-emit-current-site!
                    fn
                    (if (= step 3)
                      2
                      step))
                  (let
                    [text : String
                      (backend-stack-origins-local-emit
                        state
                        (owned_view.compiler-owned-shared-view homes)
                        step
                        (> shape 0))]
                    [capture : origins.CompilerBackendTextOrigins
                      (backend.compiler-backend-state-stack-text-origins state)]
                    (test.assert-string-eq
                      text
                      (array-ref plain step)
                      "local ownership does not change machine bytes")
                    (test.assert-i64-eq
                      (array-length
                        (origins.compiler-backend-text-origins-find
                          capture
                          (& text)))
                      1
                      "AddrOf carries only its pointer-home write; LEA is not a storage read")))
                (let
                  [facts : origins.CompilerBackendStackAccessOriginList
                    (backend.compiler-backend-state-stack-access-origins state)]
                  [expected : (Array i64 4) (array 7 8 7 9)]
                  (test.assert-i64-eq
                    facts.len
                    4
                    "each direct access attributed exactly once")
                  (for [i (iterator.range 0 4)]
                    (let
                      [fact : (& facts origins.CompilerBackendStackAccessOrigin)
                        (& (array-ref facts.slots i))]
                      (test.assert-i64-eq
                        fact.home
                        (array-ref expected i)
                        "storage and pointer keep distinct original homes")
                      (test.assert-i64-eq
                        fact.home-bytes
                        8
                        "local scalar allocation capacity")
                      (test.assert-i64-eq
                        fact.access-bytes
                        (if (and (> shape 0) (!= i 1))
                          4
                          8)
                        "actual memory width")
                      (test.assert-true
                        (match (& fact.owner)
                          [(UserLocal) (or (= i 0) (= i 2))]
                          [(Allocator) (or (= i 1) (= i 3))]
                          [_ false])
                        "addressed object is user storage; pointer and copied value stay allocator homes")
                      (test.assert-true
                        (match (& fact.bank)
                          [(Vector) (and (> shape 0) (!= i 1))]
                          [(General) (or (= shape 0) (= i 1))]
                          [_ false])
                        "actual bank independent of owner")
                      (test.assert-true
                        (match (& fact.access)
                          [(Read) (= i 2)]
                          [(Write) (!= i 2)]
                          [_ false])
                        "direct read/write order")))))
              (backend.compiler-backend-clear-function-owned-state! state)
              (backend.compiler-backend-state-release-final-arenas! state))))))))

(test
  backend-stack-origins-addressed-local-ownership
  (backend-stack-origins-local-test))

(define (backend-stack-origins-machine-partition-test) : unit
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [operand : String
      (backend.compiler-backend-origin-invariant-text
        (origins.compiler-backend-text-origins-record
          capture
          (origins.CompilerBackendStackAccessOrigin
            (ir.CompilerIrSymbolId 44)
            (SourceBlock 30)
            7
            8
            (UserLocal)
            (General)
            8
            (Read))
          "-8(%rsp)"))]
    [load : String
      (origins.compiler-backend-text-origins-cat
        capture
        "    movq "
        operand
        ", %rax\n")]
    [text : String
      (origins.compiler-backend-text-origins-cat
        capture
        ".text\n.globl f\nf:\n.Lalias:\n    # metadata\n\n    nop\n"
        load
        "    jz .Lcold\n    addq $1, %rax\n    jmp .Lexit\n.Lcold:\n"
        load
        "    call tl_oob_abort\n    nop\n.Lexit:\n    ret\n    ud2\n    nop")]
    (match (backend.compiler-backend-final-stack-partition
      state
      (backend.CompilerBackendFinalStackRequest
        (owned_view.compiler-owned-shared-view text)
        (ir.CompilerIrSymbolId 44)
        capture))
      [(Err message) (io.panic message)]
      [(Ok partition)
        (test.assert-i64-eq
          partition.blocks
          7
          "labels, branch, return, noreturn and trap boundaries; no empty alias block")
        (test.assert-i64-eq
          (array-length partition.operations)
          11
          "only actual instruction lines, including final line without newline")
        (let
          [blocks : (Array i64 11) (array 0 0 0 1 1 2 2 3 4 5 6)]
          (for [i (iterator.range 0 11)]
            (test.assert-i64-eq
              (array-ref partition.operations i).block
              (array-ref blocks i)
              "independent final leader inventory")))
        (test.assert-i64-eq
          (array-length partition.accesses)
          2
          "only two actual retained reads")
        (for [i (iterator.range 0 2)]
          (let
            [event : (& partition origins.CompilerBackendFinalAccess)
              (& (array-ref partition.accesses i))]
            (test.assert-i64-eq
              event.operation
              (if (= i 0)
                1
                5)
              "parser instruction ordinal binds the retained operand")
            (test.assert-i64-eq
              event.block
              (if (= i 0)
                0
                2)
              "final blocks follow machine text")
            (test.assert-true
              (match (& event.origin.anchor)
                [(SourceBlock b) (= b 30)]
                [_ false])
              "machine blocks do not replace source anchors")))])
    (let
      [terminals : (Array String 11)
        (array
          "jne .Lend"
          "jmp *%rax"
          "jrcxz .Lend"
          "ret"
          "retq"
          "ud2"
          "loop .Lend"
          "loope .Lend"
          "loopne .Lend"
          "call tl_oob_abort_at"
          "call normal_callee")]
      (for [i (iterator.range 0 11)]
        (let
          [body : String
            (origins.compiler-backend-text-origins-cat
              capture
              "    "
              (owned_view.compiler-owned-shared-view (array-ref terminals i))
              "\n    nop")]
          (match (backend.compiler-backend-final-stack-partition
            state
            (backend.CompilerBackendFinalStackRequest
              body
              (ir.CompilerIrSymbolId 44)
              capture))
            [(Err message) (io.panic message)]
            [(Ok partition)
              (test.assert-i64-eq
                (array-length partition.operations)
                2
                "control instruction and actual continuation")
              (test.assert-i64-eq
                partition.blocks
                (if (= i 10)
                  1
                  2)
                "returning call is not a control boundary")
              (test.assert-i64-eq
                (array-length partition.accesses)
                0
                "no fabricated call/return stack fact")]))))
    (for [invalid (iterator.range 0 2)]
      (test.assert-true
        (match (backend.compiler-backend-final-stack-partition
          state
          (backend.CompilerBackendFinalStackRequest
            (owned_view.compiler-owned-shared-view text)
            (ir.CompilerIrSymbolId
              (if (= invalid 0)
                45
                44))
            (if (= invalid 1)
              (origins.compiler-backend-text-origins-disabled)
              capture)))
          [(Err _) true]
          [_ false])
        "partition cannot bypass function/capture qualification"))
    (origins.compiler-backend-text-origins-release! (&mut capture))
    (backend.compiler-backend-state-release-final-arenas! state)))

(test
  backend-stack-origins-final-machine-boundaries
  (backend-stack-origins-machine-partition-test))

(define (backend-stack-origins-machine-graph-test) : unit
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [text : String
      "f:\n1:\n    jz 2f\n.Lalias:\n    nop\n    jmp 1f\n1:\n    loop 1b\n2:\n    ret\n.Ldead:\n    ud2"]
    (match (backend.compiler-backend-final-stack-graph
      state
      (backend.CompilerBackendFinalStackRequest
        text
        (ir.CompilerIrSymbolId 44)
        capture))
      [(Err message) (io.panic message)]
      [(Ok control)
        (test.assert-i64-eq
          control.partition.blocks
          5
          "aliases do not invent graph nodes")
        (test.assert-i64-eq
          (array-length control.partition.operations)
          6
          "actual final instruction count")
        (for [from (iterator.range 0 5)]
          (for [to (iterator.range 0 5)]
            (let
              [expected : bool
                (or
                  (and (= from 0) (or (= to 1) (= to 3)))
                  (and (= from 1) (= to 2))
                  (and (= from 2) (or (= to 2) (= to 3))))]
              [successors : live.CompilerLiveIndexVec
                (clone (array-ref control.graph.successors from))]
              [predecessors : live.CompilerLiveIndexVec
                (clone (array-ref control.graph.predecessors to))]
              [forward : bool false]
              [reverse : bool false]
              (for [i (iterator.range 0 (array-length successors.items))]
                (when (= (array-ref successors.items i) to) (set! forward true)))
              (for [i (iterator.range 0 (array-length predecessors.items))]
                (when
                  (= (array-ref predecessors.items i) from)
                  (set! reverse true)))
              (test.assert-true
                (= expected forward)
                "independent direct/numeric/fallthrough edge matrix")
              (test.assert-true
                (= expected reverse)
                "canonical builder's reverse edges agree"))))])
    (let
      [buffer : text_buf.TextBuf (text_buf.append (text_buf.empty) "f:\n")]
      (for [i (iterator.range 0 64)]
        (text_buf.append!
          buffer
          (string.concat3 ".Lalias" (string.int->string i) ":\n")))
      (text_buf.append! buffer "    ret\n")
      (match (backend.compiler-backend-final-stack-graph
        state
        (backend.CompilerBackendFinalStackRequest
          (text_buf.render buffer)
          (ir.CompilerIrSymbolId 44)
          capture))
        [(Err message) (io.panic message)]
        [(Ok control)
          (test.assert-i64-eq
            control.partition.blocks
            1
            "index growth and many aliases retain one actual block")
          (test.assert-i64-eq
            (array-length control.graph.successors)
            1
            "no phantom graph nodes from spare line capacity")]))
    (match (backend.compiler-backend-final-stack-graph
      state
      (backend.CompilerBackendFinalStackRequest
        "f:\n    jz .Lnext\n.Lnext:\n    ret\n"
        (ir.CompilerIrSymbolId 44)
        capture))
      [(Err message) (io.panic message)]
      [(Ok control)
        (test.assert-i64-eq
          (array-length (array-ref control.graph.successors 0).items)
          1
          "taken and fallthrough to one block form one canonical edge")])
    (let
      [invalid : (Array String 12)
        (array
          "f:\n    jmp external\n"
          "f:\n    jmp *%rax\n"
          "f:\n    jmp 1f\n"
          "f:\n    jmp 1b\n"
          "f:\n.Lx:\n    ret\n.Lx:\n    ret\n"
          "f:\n    jmp .Lend\n.Lend:\n"
          "f:\n    nop"
          "f:\n    junknown f\n    ret\n"
          "f:\n    .quad 0\n    ret\n"
          "f:\n    jz f\n"
          ""
          "f:\n01:\n    jmp 01b\n")]
      (for [i (iterator.range 0 12)]
        (test.assert-true
          (match (backend.compiler-backend-final-stack-graph
            state
            (backend.CompilerBackendFinalStackRequest
              (owned_view.compiler-owned-shared-view (array-ref invalid i))
              (ir.CompilerIrSymbolId 44)
              capture))
            [(Err _) true]
            [_ false])
          "external/indirect/unresolved/duplicate/data/falloff/unknown flow cannot become a closed graph")))
    (let
      [mnemonics : (Array String 4) (array "loopz" "loopnz" "jecxz" "jrcxz")]
      (for [i (iterator.range 0 4)]
        (let
          [body : String
            (origins.compiler-backend-text-origins-cat
              capture
              "f:\n    "
              (owned_view.compiler-owned-shared-view (array-ref mnemonics i))
              " f\n    ret\n")]
          (match (backend.compiler-backend-final-stack-graph
            state
            (backend.CompilerBackendFinalStackRequest
              body
              (ir.CompilerIrSymbolId 44)
              capture))
            [(Err message) (io.panic message)]
            [(Ok control)
              (test.assert-i64-eq
                control.partition.blocks
                2
                "count branches end their actual block")
              (test.assert-i64-eq
                (array-length (array-ref control.graph.successors 0).items)
                2
                "count branch has both exact local target and fallthrough")]))))
    (origins.compiler-backend-text-origins-release! (&mut capture))
    (backend.compiler-backend-state-release-final-arenas! state)))

(test
  backend-stack-origins-final-machine-graph
  (backend-stack-origins-machine-graph-test))

(define (backend-stack-origins-data-case [shared-object : bool]) : unit
  (let
    [state : backend.CompilerBackendState
      (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
    [function-state : backend.CompilerBackendFunctionState
      (backend.compiler-backend-state-function-state state)]
    (let
      [policy : backend.CompilerBackendTargetPolicy
        (backend.compiler-backend-state-emission-target-policy state)]
      (set! policy.shared-object shared-object)
      (backend.compiler-backend-state-set-emission-target-policy! state policy))
    (backend.compiler-backend-function-scratch-set-i64!
      function-state
      backend.compiler-backend-scratch-i64-current-source-function
      44)
    (let
      [plain : String
        (backend.compiler-backend-abort-site-descriptor-after-call
          state
          ".Ldata")]
      (backend.compiler-backend-state-stack-origins-begin! state)
      (let
        [capture : origins.CompilerBackendTextOrigins
          (backend.compiler-backend-state-stack-text-origins state)]
        [descriptor : String
          (backend.compiler-backend-abort-site-descriptor-after-call
            state
            ".Ldata")]
        [body : String
          (origins.compiler-backend-text-origins-cat
            capture
            (if shared-object
              "f:\n    nop\n"
              "f:\n    call tl_panic_at\n")
            descriptor
            "    ret\n")]
        [registered : String
          (backend.compiler-backend-origin-invariant-text
            (origins.compiler-backend-text-origins-function
              capture
              (origins.CompilerBackendFunctionOriginRequest
                (ir.CompilerIrSymbolId 44)
                "f"
                body)))]
        (test.assert-string-eq
          plain
          descriptor
          "data authority changes no actual descriptor bytes")
        (test.assert-i64-eq
          (array-length
            (origins.compiler-backend-text-origins-find capture (& descriptor)))
          (if shared-object
            8
            6)
          "alignment, actual label and four descriptor words have separate line witnesses")
        (test.assert-i64-eq
          (array-length
            (origins.compiler-backend-text-origins-access-spans
              capture
              (& registered)))
          0
          "descriptor data never creates a stack access")
        (test.assert-true
          (match (origins.compiler-backend-text-origins-function-ranges
            capture
            (& registered))
            [(Ok ranges) (= (array-length ranges) 1)]
            [_ false])
          "actual function registration retains data under its emitting identity")
        (match (backend.compiler-backend-final-stack-graph
          state
          (backend.CompilerBackendFinalStackRequest
            (owned_view.compiler-owned-shared-view registered)
            (ir.CompilerIrSymbolId 44)
            capture))
          [(Err message) (io.panic message)]
          [(Ok control)
            (test.assert-i64-eq
              control.partition.blocks
              (if shared-object
                1
                3)
              "noreturn, unreachable skip and continuation remain distinct")
            (test.assert-i64-eq
              (array-length (array-ref control.graph.successors 0).items)
              0
              "noreturn does not enter descriptor")
            (unless
              shared-object
              (test.assert-i64-eq
                (array-length (array-ref control.graph.successors 1).items)
                1
                "explicit skip bypasses every data line"))])
        (let
          [branch-to-data : String
            (origins.compiler-backend-text-origins-cat
              capture
              "f:\n    jmp .Ldata\n"
              descriptor
              "    ret\n")]
          (test.assert-true
            (match (backend.compiler-backend-final-stack-graph
              state
              (backend.CompilerBackendFinalStackRequest
                branch-to-data
                (ir.CompilerIrSymbolId 44)
                capture))
              [(Err _) true]
              [_ false])
            "a branch cannot enter either actual inline or relocated descriptor"))
        (let
          [invalid-relocated : (Array String 3)
            (array
              ".quad 0\n"
              "    .pushsection .text\n    .quad 0\n    .popsection\n"
              "    .pushsection .data.rel.ro,\"aw\",@progbits\n    .popsection\n    .quad 0\n    .popsection\n")]
          (for [i (iterator.range 0 3)]
            (let
              [bad : String
                (owned_view.compiler-owned-shared-view
                  (array-ref invalid-relocated i))]
              (test.assert-true
                (match (origins.compiler-backend-text-origins-data
                  capture
                  (origins.CompilerBackendDataOriginRequest
                    (ir.CompilerIrSymbolId 44)
                    (OtherSection)
                    (owned_view.compiler-owned-shared-view bad)
                    0
                    (string.string-length bad)))
                  [(Err _) true]
                  [_ false])
                "relocated authority cannot hide missing/wrong/nested section switches"))))
        (for [invalid (iterator.range 0 5)]
          (let
            [raw-data : String
              (if (= invalid 4)
                "    nop\n"
                ".Ldatum:\n    .quad 0\n")]
            [marked : String
              (backend.compiler-backend-origin-invariant-text
                (origins.compiler-backend-text-origins-data
                  capture
                  (origins.CompilerBackendDataOriginRequest
                    (ir.CompilerIrSymbolId
                      (if (= invalid 2)
                        45
                        44))
                    (InlineData)
                    (owned_view.compiler-owned-shared-view raw-data)
                    0
                    (string.string-length raw-data))))]
            [text : String
              (origins.compiler-backend-text-origins-cat
                capture
                (cond
                  [(= invalid 0) "f:\n    nop\n"]
                  [(= invalid 1) "f:\n    jmp .Ldatum\n"]
                  [else "f:\n    jmp .Ldone\n"])
                (if (= invalid 3)
                  (string.copy (& marked))
                  marked)
                ".Ldone:\n    ret\n")]
            (test.assert-true
              (match (backend.compiler-backend-final-stack-graph
                state
                (backend.CompilerBackendFinalStackRequest
                  text
                  (ir.CompilerIrSymbolId 44)
                  capture))
                [(Err _) true]
                [_ false])
              "fallthrough/branch into data, foreign ownership, lost marker and marked instruction reject")))
        (for [invalid (iterator.range 0 4)]
          (test.assert-true
            (match (origins.compiler-backend-text-origins-data
              capture
              (origins.CompilerBackendDataOriginRequest
                (ir.CompilerIrSymbolId 44)
                (InlineData)
                (if (= invalid 3)
                  "\n"
                  ".quad 0\n")
                (if (= invalid 0)
                  1
                  0)
                (cond
                  [(= invalid 1) 7]
                  [(= invalid 2) 99]
                  [(= invalid 3) 1]
                  [else 8])))
              [(Err _) true]
              [_ false])
            "partial lines, out-of-range and empty data reject without publishing facts"))
        (test.assert-i64-eq
          (backend.compiler-backend-state-stack-access-origins state).len
          0
          "all accepted and rejected data requests leave the memory fact census unchanged")))
    (backend.compiler-backend-state-release-final-arenas! state)))

(define (backend-stack-origins-data-test) : unit
  (backend-stack-origins-data-case false)
  (backend-stack-origins-data-case true))

(test
  backend-stack-origins-emitted-data-authority
  (backend-stack-origins-data-test))

(define (backend-stack-origins-tail-emit
  [state : backend.CompilerBackendState]
  [target : String]
  [fpo? : bool]) : String
  (let
    [text : String
      (backend.compiler-backend-tail-jump-tail
        (regalloc.compiler-reg-assignment-table-empty)
        10
        target
        state)]
    (if fpo?
      (let
        [empty : (__tl_dyn-array String)
          (backend.compiler-backend-rsp-rebase-make-push-regs)]
        [result : backend.CompilerBackendRspRebaseResult
          (backend.compiler-backend-rsp-rebase-full-result-with-saves
            text
            128
            true
            (owned_view.compiler-owned-shared-view empty)
            0
            (owned_view.compiler-owned-shared-view empty)
            0
            10
            state)]
        (unless result.ok (io.panic "tail FPO fixture refused"))
        result.text)
      text)))

(define (backend-stack-origins-tail-test) : unit
  (for [shape (iterator.range 0 3)]
    (for [fpo (iterator.range 0 2)]
      (let
        [state : backend.CompilerBackendState
          (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
        [function-state : backend.CompilerBackendFunctionState
          (backend.compiler-backend-state-function-state state)]
        [target : String
          (match shape
            [0 "external"]
            [1 "*(%r11)"]
            [_ "f"])]
        (backend.compiler-backend-function-scratch-set-i64!
          function-state
          backend.compiler-backend-scratch-i64-current-source-function
          44)
        (backend.compiler-backend-function-state-set-i64!
          function-state
          backend.compiler-backend-function-i64-current-block-label
          17)
        (let
          [plain : String
            (backend-stack-origins-tail-emit
              state
              (owned_view.compiler-owned-shared-view target)
              (= fpo 1))]
          (backend.compiler-backend-state-stack-origins-begin! state)
          (backend-stack-origins-install-test-plan! state false false)
          (let
            [capture : origins.CompilerBackendTextOrigins
              (backend.compiler-backend-state-stack-text-origins state)]
            [tail : String
              (backend-stack-origins-tail-emit state target (= fpo 1))]
            [body : String
              (origins.compiler-backend-text-origins-cat capture "f:\n" tail)]
            [registered : String
              (backend.compiler-backend-origin-invariant-text
                (origins.compiler-backend-text-origins-function
                  capture
                  (origins.CompilerBackendFunctionOriginRequest
                    (ir.CompilerIrSymbolId 44)
                    "f"
                    body)))]
            (test.assert-string-eq
              plain
              tail
              "typed tail and FPO preserve every ordinary byte")
            (test.assert-true
              (match (origins.compiler-backend-text-origins-function-ranges
                capture
                (& registered))
                [(Ok ranges) (= (array-length ranges) 1)]
                [_ false])
              "tail witness belongs to its registered emitted function")
            (match (backend.compiler-backend-final-stack-graph
              state
              (backend.CompilerBackendFinalStackRequest
                registered
                (ir.CompilerIrSymbolId 44)
                capture))
              [(Err message) (io.panic message)]
              [(Ok control)
                (test.assert-i64-eq
                  (array-length control.tail-exits)
                  1
                  "one actual tail operation")
                (test.assert-i64-eq
                  (array-length (array-ref control.graph.successors 0).items)
                  0
                  "emitter-proven direct, closure and recursive tails leave this function")
                (test.assert-i64-eq
                  (array-ref control.tail-exits 0).operation
                  (- (array-length control.partition.operations) 1)
                  "tail binds final instruction ordinal")
                (test.assert-i64-eq
                  (array-ref control.tail-exits 0).block
                  0
                  "tail binds actual final block")
                (test.assert-true
                  (match (& (array-ref control.tail-exits 0).anchor)
                    [(SourceBlock b) (= b 17)]
                    [_ false])
                  "source anchor survives FPO without becoming a machine block")])
            (when
              (and (= shape 0) (= fpo 0))
              (for [bad (iterator.range 0 6)]
                (test.assert-true
                  (match (origins.compiler-backend-text-origins-tail-exit
                    capture
                    (origins.CompilerBackendTailExitRequest
                      (ir.CompilerIrSymbolId
                        (if (= bad 0)
                          -1
                          44))
                      (cond
                        [(= bad 1) (SourceBlock -1)]
                        [(= bad 2) (FunctionEntry)]
                        [else (AdapterBody)])
                      (match bad
                        [3 "    call external"]
                        [4 "    jmp external\n"]
                        [5 "    jmp external; ret"]
                        [_ "    jmp external"])))
                    [(Err _) true]
                    [_ false])
                  "foreign identity, invalid anchor, wrong opcode and partial/multiple statements reject"))
              (let
                [leaf : String
                  (backend.compiler-backend-origin-invariant-text
                    (origins.compiler-backend-text-origins-tail-exit
                      capture
                      (origins.CompilerBackendTailExitRequest
                        (ir.CompilerIrSymbolId 44)
                        (AdapterBody)
                        "    jmp external")))]
                [cloned : String
                  (origins.compiler-backend-text-origins-cat
                    capture
                    "f:\n"
                    leaf
                    "\n"
                    leaf
                    "\n")]
                (match (backend.compiler-backend-final-stack-graph
                  state
                  (backend.CompilerBackendFinalStackRequest
                    cloned
                    (ir.CompilerIrSymbolId 44)
                    capture))
                  [(Err message) (io.panic message)]
                  [(Ok control)
                    (test.assert-i64-eq
                      (array-length control.partition.accesses)
                      0
                      "tails invent no memory access")
                    (test.assert-i64-eq
                      (array-length control.tail-exits)
                      2
                      "cloned tails each bind one actual instruction")
                    (for [i (iterator.range 0 2)]
                      (test.assert-i64-eq
                        (array-ref control.tail-exits i).operation
                        i
                        "clone order is final operation order")
                      (test.assert-true
                        (match (& (array-ref control.tail-exits i).anchor)
                          [(AdapterBody) true]
                          [_ false])
                        "adapter authority survives cloning"))])
                (test.assert-true
                  (match (origins.compiler-backend-text-origins-slice
                    capture
                    (& leaf)
                    1
                    (- (string.string-length leaf) 1))
                    [(Err _) true]
                    [_ false])
                  "a partial copied tail cannot inherit complete instruction authority")
                (for [bad (iterator.range 0 2)]
                  (test.assert-true
                    (match (backend.compiler-backend-final-stack-graph
                      state
                      (backend.CompilerBackendFinalStackRequest
                        (origins.compiler-backend-text-origins-cat
                          capture
                          "f:\n"
                          (if (= bad 0)
                            (string.copy (& leaf))
                            (owned_view.compiler-owned-shared-view leaf))
                          "\n")
                        (ir.CompilerIrSymbolId
                          (if (= bad 0)
                            44
                            45))
                        capture))
                      [(Err _) true]
                      [_ false])
                    "lost tail witness or wrong function cannot authorize an external transfer")))))
          (backend.compiler-backend-state-release-final-arenas! state))))))

(test
  backend-stack-origins-emitted-tail-authority
  (backend-stack-origins-tail-test))

(define (backend-stack-origins-bounds-data-test) : unit
  (builtin_ids.compiler-builtin-initialize-for-parse!)
  (for [platform (iterator.range 0 2)]
    (for [constant (iterator.range 0 2)]
      (let
        [state : backend.CompilerBackendState
          (backend.compiler-backend-state-new (ci.intern-compat-state-new))]
        [function-state : backend.CompilerBackendFunctionState
          (backend.compiler-backend-state-function-state state)]
        [index : backend.CompilerBackendProgramIndex
          (backend.compiler-backend-program-index-build-with-backend-state-and-profile-state
            state
            (ast.ast-node-pool-reader-type-segment-bases)
            (ir.compiler-ir-function-seq-empty)
            (ir.compiler-ir-extern-seq-empty)
            (profile_state.compiler-profile-state-new))]
        [call-space : i64
          (if (= platform 0)
            0
            32)]
        [runtime : backend.CompilerBackendRuntimePlan
          (match (backend.compiler-backend-runtime-plan-with-backend-state
            state
            (Program
              (ir.compiler-ir-global-seq-empty)
              (ir.compiler-ir-function-seq-empty)
              (ir.compiler-ir-extern-seq-empty)))
            [(Ok result) result]
            [(Err _) (io.panic "bounds fixture runtime refused")])]
        (backend.compiler-backend-state-set-emission-target-policy!
          state
          (backend.compiler-backend-target-policy-new
            (if (= platform 0)
              (Linux)
              (Windows))))
        (backend.compiler-backend-function-state-set-bool!
          function-state
          backend.compiler-backend-function-bool-current-fn-win64
          (= platform 1))
        (backend.compiler-backend-function-state-set-bool!
          function-state
          backend.compiler-backend-function-bool-abort-site-active
          true)
        (backend.compiler-backend-function-state-set-string!
          function-state
          backend.compiler-backend-function-string-abort-site-path
          "bounds_fixture")
        (backend.compiler-backend-function-scratch-set-i64!
          function-state
          backend.compiler-backend-scratch-i64-current-source-function
          44)
        (let
          [plain : String
            (if (= constant 0)
              (backend.compiler-backend-bounds-check-asm
                ""
                ""
                "%r9"
                "%r8"
                call-space
                ".Lok"
                runtime
                index)
              (backend.compiler-backend-bounds-check-const-index-asm
                ""
                "%r9"
                "$0"
                call-space
                ".Lok"
                runtime
                index))]
          ;; Both emitters must name the same original descriptor to compare
          ;; bytes; this resets only this fixture's ordinary/captured counter.
          (backend.compiler-backend-state-set-abort-site-counter! state 0)
          (backend.compiler-backend-state-stack-origins-begin! state)
          (let
            [capture : origins.CompilerBackendTextOrigins
              (backend.compiler-backend-state-stack-text-origins state)]
            [text : String
              (if (= constant 0)
                (backend.compiler-backend-bounds-check-asm
                  ""
                  ""
                  "%r9"
                  "%r8"
                  call-space
                  ".Lok"
                  runtime
                  index)
                (backend.compiler-backend-bounds-check-const-index-asm
                  ""
                  "%r9"
                  "$0"
                  call-space
                  ".Lok"
                  runtime
                  index))]
            [body : String
              (origins.compiler-backend-text-origins-cat
                capture
                "f:\n"
                text
                "    ret\n")]
            (test.assert-string-eq
              text
              plain
              "actual bounds parents preserve ordinary bytes on both targets")
            (test.assert-i64-eq
              (array-length
                (origins.compiler-backend-text-origins-find capture (& text)))
              6
              "all six actual descriptor line witnesses cross both bounds parents")
            (match (backend.compiler-backend-final-stack-graph
              state
              (backend.CompilerBackendFinalStackRequest
                body
                (ir.CompilerIrSymbolId 44)
                capture))
              [(Err message) (io.panic message)]
              [(Ok control)
                (test.assert-i64-eq
                  control.partition.blocks
                  4
                  "check, noreturn, data skip and continuation are exact blocks")
                (test.assert-i64-eq
                  (array-length control.partition.accesses)
                  0
                  "data witnesses are not memory access facts")])
            (test.assert-true
              (match (backend.compiler-backend-final-stack-graph
                state
                (backend.CompilerBackendFinalStackRequest
                  (string.concat3 "f:\n" (string.copy (& text)) "    ret\n")
                  (ir.CompilerIrSymbolId 44)
                  capture))
                [(Err _) true]
                [_ false])
              "the same unmarked descriptor bytes cannot acquire authority"))
          (backend.compiler-backend-state-release-final-arenas! state))))))

(test
  backend-stack-origins-bounds-data-transport
  (backend-stack-origins-bounds-data-test))