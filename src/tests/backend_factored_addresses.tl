;; Exercise address factoring with real whole-function use counts and explicit
;; register homes. A second block keeps an otherwise adjacent offset live.
(import compiler_backend as backend)
(import compiler_backend_tests as fixtures)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_regalloc as reg)
(import compiler_abi as abi)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_diagnostic as diagnostic)
(import compiler_owned_view as view)
(import stdlib.arena)
(import stdlib.test)

(define (check-case [factor : i64] [mode : i64] [windows : bool]) : unit
  (let
    [b
      (backend.compiler-backend-state-new
        (ci.intern-compat-state-capture-active))]
    [p
      (backend.compiler-backend-program-index-build
        (ast.ast-node-pool-reader-type-segment-bases)
        (ir.compiler-ir-function-seq-empty)
        (ir.compiler-ir-extern-seq-empty))]
    [ty : ast.AstType
      (cond
        [(= mode 5) (ast.AstType.I32)]
        [(= mode 16) (ast.AstType.U64)]
        [else (ast.AstType.I64)])]
    [elem : ast.AstType
      (if (= mode 3)
        (ast.AstType.I64)
        (ast.AstType.U8))]
    [rhs : ir.CompilerIrValue
      (if (= mode 20)
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.I64 factor))]
    [slots : (__tl_dyn-array ir.CompilerIrInstr)
      (__tl_make-array ir.CompilerIrInstr 4)]
    [homes : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-empty)]
    [disps : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [kinds : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [scales : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [fuse : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    (begin
      (set!
        (array-ref homes 0)
        (if (= mode 10)
          abi.compiler-reg-id-rbp
          abi.compiler-reg-id-r12))
      (set!
        (array-ref homes 1)
        (if (= mode 11)
          abi.compiler-reg-id-rbp
          abi.compiler-reg-id-r13))
      (set!
        (array-ref homes 2)
        (cond
          [(= mode 12) abi.compiler-reg-id-r13]
          [(= mode 17) abi.compiler-reg-id-r12]
          [(= mode 23) abi.compiler-reg-id-rbp]
          [else abi.compiler-reg-id-r14]))
      (set!
        (array-ref homes 3)
        (cond
          [(= mode 18) abi.compiler-reg-id-r13]
          [(= mode 19) abi.compiler-reg-id-r14]
          [(= mode 22) abi.compiler-reg-id-r12]
          [else abi.compiler-reg-id-r15]))
      (let
        [i : i64 0]
        (while (< i 4)
          (begin
            ;; A missing assignment is a stack home.
            (unless
              (= mode (+ i 6))
              (set!
                assignments
                (reg.compiler-reg-assignments-prepend
                  (reg.CompilerRegAssignment
                    i
                    (reg.CompilerRegLocation.Register (array-ref homes i)))
                  assignments)))
            (set! i (+ i 1)))))
      (set!
        (array-ref slots 0)
        (ir.CompilerIrInstr.BinOp
          2
          (ir.CompilerIrBinOp.Mul)
          (ir.CompilerIrValue.Var 0)
          (view.compiler-owned-shared-view rhs)
          (view.compiler-owned-shared-view ty)))
      (set!
        (array-ref slots 1)
        (if (= mode 14)
          (ir.CompilerIrInstr.Mov
            3
            (ir.CompilerIrValue.Var 2)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.Gep
            3
            (ir.CompilerIrValue.Var 1)
            (ir.CompilerIrValue.Var
              (if (= mode 4)
                0
                2))
            (view.compiler-owned-shared-view elem))))
      (set!
        (array-ref slots 2)
        (ir.CompilerIrInstr.Mov 4 (ir.CompilerIrValue.Var 3) (ast.AstType.I64)))
      (set!
        (array-ref slots 3)
        (ir.CompilerIrInstr.Mov
          5
          (ir.CompilerIrValue.Var
            (if (= mode 2)
              0
              3))
          (ast.AstType.I64)))
      (set!
        (array-ref disps 0)
        (if (= mode 13)
          17
          0))
      (set! (array-ref disps 1) 32)
      (set! (array-ref kinds 0) 1)
      (set! (array-ref kinds 1) 1)
      (set!
        (array-ref scales 0)
        (if (= mode 3)
          8
          1))
      (set! (array-ref scales 1) 1)
      (backend.compiler-backend-test-set-compiler-backend-gep-fold-ready!
        b
        true)
      (backend.compiler-backend-test-set-compiler-backend-gep-fold-disp-table!
        b
        disps)
      (backend.compiler-backend-test-set-compiler-backend-gep-fold-kind-table!
        b
        kinds)
      (backend.compiler-backend-test-set-compiler-backend-gep-fold-scale-table!
        b
        scales)
      (backend.compiler-backend-test-set-compiler-backend-gep-fold-cursor! b 0)
      (when
        (= mode 15)
        (begin
          (set! (array-ref fuse 3) 2)
          (backend.compiler-backend-test-set-compiler-backend-fuse-need-ready!
            b
            true)
          (backend.compiler-backend-test-set-compiler-backend-fuse-use-counts!
            b
            (view.compiler-owned-shared-view fuse))
          (backend.compiler-backend-test-set-compiler-backend-fuse-free-counts!
            b
            fuse)))
      (let
        [instrs (ir.CompilerIrInstrSeq slots 4)]
        [blocks
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              0
              (view.compiler-owned-shared-view instrs))
            (if (= mode 1)
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  1
                  (fixtures.compiler-backend-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                    (ir.compiler-ir-instr-seq-empty)))
                (ir.CompilerIrBlockList.Nil))
              (ir.CompilerIrBlockList.Nil)))]
        [uses
          (backend.compiler-backend-function-use-counts
            6
            (view.compiler-owned-shared-view blocks))]
        [ctx
          (backend.CompilerBackendEmissionContext
            (ast.ast-node-pool-reader-type-segment-bases)
            (backend.compiler-backend-target-policy-new
              (if windows
                (backend.CompilerBackendTarget.Windows)
                (backend.CompilerBackendTarget.Linux)))
            "_tl_test"
            (ci.intern "test")
            blocks
            0
            assignments
            6
            (reg.compiler-reg-var-types-empty)
            (backend.CompilerBackendGlobalTypeTable.Empty)
            (ast.AstType.I64)
            (fixtures.compiler-backend-runtime-helper-full-plan)
            (ir.compiler-ir-function-seq-empty)
            (ir.compiler-ir-extern-seq-empty)
            p
            (ir.compiler-source-spans-empty)
            (backend.compiler-backend-source-span-index-build
              (ir.compiler-source-spans-empty))
            (diagnostic.compiler-diagnostic-at-start "" "")
            uses
            b
            (backend.compiler-backend-state-function-state b))]
        [accepted : bool
          (and
            (or
              (= mode 0)
              (= mode 16)
              (= mode 17)
              (= mode 18)
              (= mode 19)
              (= mode 22)
              (= mode 23))
            (or
              (= factor 6)
              (= factor 12)
              (= factor 24)
              (= factor 10)
              (= factor 20)
              (= factor 40)
              (= factor 18)
              (= factor 36)
              (= factor 72)))]
        [result
          (backend.compiler-backend-mul-gep-asm
            ctx
            2
            (ir.CompilerIrValue.Var 0)
            rhs
            ty
            instrs
            (if (= mode 21)
              4
              1))]
        (begin
          (test.assert-bool-eq
            accepted
            (match result
              [(backend.CompilerBackendMaybeAsm.Some text)
                (and
                  (backend.compiler-backend-string-contains?
                    (view.compiler-owned-shared-view text)
                    "    leaq (")
                  (not (backend.compiler-backend-string-contains? text "imul")))]
              [(backend.CompilerBackendMaybeAsm.No) false])
            "factoring admission")
          (test.assert-i64-eq
            (if accepted
              1
              0)
            (backend.compiler-backend-test-get-compiler-backend-gep-fold-cursor
              b)
            "probe cursor")
          (test.assert-bool-eq
            false
            (backend.compiler-backend-test-get-compiler-backend-gep-fold-drift
              b)
            "probe drift")
          (when
            accepted
            (begin
              (test.assert-i64-eq
                32
                (backend.compiler-backend-gep-fold-next!
                  (backend.compiler-backend-state-function-state b)
                  (ast.ast-node-pool-reader-type-segment-bases)
                  (ir.CompilerIrValue.Var 0)
                  (ast.AstType.U8))
                "following displacement")
              (test.assert-i64-eq
                2
                (backend.compiler-backend-test-get-compiler-backend-gep-fold-cursor
                  b)
                "following cursor"))))))))

(test
  factored_address_liveness_homes_and_ordinals
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [factor : i64 -1]
      (while (<= factor 73)
        (begin
          (let
            [mode : i64 0]
            (while (< mode 24)
              (begin
                (let
                  [scope (arena.make)]
                  (begin
                    (in-arena
                      scope
                      (begin
                        (check-case factor mode false)
                        (check-case factor mode true)))
                    (arena.destroy-safe! scope)))
                (set! mode (+ mode 1)))))
          (set! factor (+ factor 1)))))))