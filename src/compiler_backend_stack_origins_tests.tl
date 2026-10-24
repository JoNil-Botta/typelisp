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
(import compiler_profile_state as profile_state)
(import compiler_diagnostic as diagnostic)
(import compiler_owned_view as owned_view)
(import stdlib.test)
(import stdlib.string)
(import stdlib.io)
(import stdlib.iterator)

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
          (array-ref facts.slots 0).block
          10
          "entry block attribution")))
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
        (array-ref accesses.slots 0).block
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
              2
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
              2
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
    [original : ir.CompilerIrBlockList
      (ir_text.blocks
        "entry:
  jump join
other:
  jump join
join:
  %7 = phi [%9, entry], [%10, other] : i64
  %8 = phi [%10, entry], [%9, other] : i64
  return %7
")]
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
    (for [var (iterator.range 7 11)]
      (set! groups (live.compiler-live-set-insert groups var)))
    (set! (array-ref map 7) 1)
    (set! (array-ref map 8) 2)
    (set! (array-ref map 9) 2)
    (set! (array-ref map 10) 1)
    (backend.compiler-backend-function-scratch-set-i64!
      function-state
      backend.compiler-backend-scratch-i64-current-source-function
      44)
    (backend.compiler-backend-group-vars-enable!
      state
      (live.compiler-live-set-insert (live.compiler-live-set1 1) 2)
      (live.compiler-live-set-empty))
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
          (I64)
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
        6
        "two old-destination saves plus four copy operands")
      (test.assert-i64-eq
        (array-length
          (origins.compiler-backend-text-origins-find capture (& text)))
        6
        "cycle prefix transports all original fragment tokens")
      (for [event (iterator.range 0 6)]
        (test.assert-i64-eq
          (array-ref facts.slots event).home
          (+
            (if (or (= event 2) (= event 3))
              30
              26)
            (% event 2))
          "save uses Phi definition, copy read uses exact incoming operand")))
    (test.assert-true
      (not
        (backend.compiler-backend-function-scratch-bool?
          function-state
          backend.compiler-backend-scratch-bool-phi-origins))
      "successful cycle restores caller Phi context")
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
      "controlled cycle error is retained")
    (test.assert-true
      (not
        (backend.compiler-backend-function-scratch-bool?
          function-state
          backend.compiler-backend-scratch-bool-phi-origins))
      "failed cycle restores caller Phi context")
    (backend.compiler-backend-state-release-final-arenas! state)))

(test
  backend-stack-origins-keep-group-phi-authorities
  (backend-stack-origins-group-phi-test))