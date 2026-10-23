(import compiler_backend as backend)
(import compiler_backend_text_origins as origins)
(import compiler_regalloc as regalloc)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_stack_traffic as traffic)
(import compiler_intern as ci)
(import compiler_owned_view as owned_view)
(import stdlib.test)
(import stdlib.string)
(import stdlib.io)

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