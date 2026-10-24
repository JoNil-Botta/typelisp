(import compiler_backend as backend)
(import compiler_backend_text_origins as origins)
(import compiler_regalloc as regalloc)
(import compiler_backend_home_origins as home_origins)
(import compiler_liveness as live)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_stack_traffic as traffic)
(import compiler_intern as ci)
(import compiler_abi as cabi)
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
  [color? : bool]) : unit
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
    (set! (array-ref instructions 0) (Splat 7 (I64 1) 4 (I64)))
    (set! (array-ref instructions 1) (Splat 9 (I64 2) 4 (I64)))
    (set!
      (array-ref instructions 2)
      (VectorBinOp
        (box
          (ir.CompilerIrInstrVectorBinOpPayload 8 (Add) (Var 7) (Var 9) 4 (I64)))))
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
    (backend-stack-origins-install-test-plan! state true)
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
    (backend-stack-origins-install-test-plan! state false)
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
    (backend-stack-origins-install-test-plan! state false)
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