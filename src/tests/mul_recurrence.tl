;; The search has a fixed work budget and reusable storage; malformed or long
;; dependency paths may only make this optional cost transformation decline.
(import compiler_optimize as opt)
(import stdlib.test)
(import stdlib.arena)

(define (check-chain [n : i64] [duplicate : bool] [cut : bool]) : unit
  (let
    [left : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [right : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [seen : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [queue : (__tl_dyn-array i64) (__tl_make-array i64 257)]
    [i : i64 0]
    (begin
      (while (< i (- n 1))
        (begin
          (set!
            (array-ref left i)
            (if (and cut (= i (- n 2)))
              0
              (+ i 2)))
          (when duplicate (set! (array-ref right i) (array-ref left i)))
          (set! i (+ i 1))))
      (set! (array-ref left (- n 1)) 1)
      (test.assert-true
        (=
          (opt.opt-ml-cycle? left right seen queue 1 n)
          (and (<= n 128) (or (not cut) (= n 1))))
        "cycle search preserves its bound even with duplicate dependency edges"))))

(test
  multiply_recurrence_search_budget
  (let
    [n : i64 1]
    (while (<= n 260)
      (let
        [scope (arena.make)]
        (begin
          (in-arena
            scope
            (begin
              (check-chain n false false)
              (check-chain n true false)
              (check-chain n false true)
              (check-chain n true true)))
          (arena.destroy-safe! scope)
          (set! n (+ n 1)))))))

(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_owned_view as view)

(define (check-rewrite [mode : i64]) : unit
  (let
    [entry : i64 (ir.compiler-ir-label "entry")]
    [header : i64 (ir.compiler-ir-label "header")]
    [body : i64 (ir.compiler-ir-label "body")]
    [exit : i64 (ir.compiler-ir-label "exit")]
    [ty : ast.AstType
      (if (= mode 3)
        (ast.AstType.I32)
        (ast.AstType.I64))]
    [source : ir.CompilerIrValue
      (ir.CompilerIrValue.Var
        (if (= mode 2)
          2
          1))]
    [factor : ir.CompilerIrValue
      (ir.CompilerIrValue.I64
        (if (= mode 4)
          129
          33))]
    [head-instrs : ir.CompilerIrInstrSeq
      (ir.CompilerIrInstrSeq
        (__tl_make-array
          (ir.CompilerIrInstr.Phi
            1
            (ir.compiler-ir-phi-input-seq-prepend
              (ir.CompilerIrValue.Var 0)
              entry
              (ir.compiler-ir-phi-input-seq-prepend
                (ir.CompilerIrValue.Var 3)
                body
                (ir.compiler-ir-phi-input-seq-empty)))
            (view.compiler-owned-shared-view ty))
          (ir.CompilerIrInstr.Phi
            2
            (ir.compiler-ir-phi-input-seq-prepend
              (ir.CompilerIrValue.I64 0)
              entry
              (ir.compiler-ir-phi-input-seq-prepend
                (ir.CompilerIrValue.Var 5)
                body
                (ir.compiler-ir-phi-input-seq-empty)))
            (ast.AstType.I64))
          (ir.CompilerIrInstr.BinOp
            4
            (ir.CompilerIrBinOp.Lt)
            (ir.CompilerIrValue.Var 2)
            (ir.CompilerIrValue.Var 6)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.Branch (ir.CompilerIrValue.Var 4) body exit))
        4)]
    [body-instrs : ir.CompilerIrInstrSeq
      (ir.CompilerIrInstrSeq
        (__tl_make-array
          (ir.CompilerIrInstr.BinOp
            3
            (ir.CompilerIrBinOp.Mul)
            (if (= mode 1)
              (view.compiler-owned-shared-view factor)
              (view.compiler-owned-shared-view source))
            (if (= mode 1)
              source
              factor)
            (view.compiler-owned-shared-view ty))
          (ir.CompilerIrInstr.BinOp
            5
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.Var 2)
            (ir.CompilerIrValue.I64 1)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.Jump header))
        3)]
    [blocks : ir.CompilerIrBlockList
      (ir.CompilerIrBlockList.Array
        (ir.CompilerIrBlockSeq
          (__tl_make-array
            (ir.CompilerIrBlock.Block
              entry
              (ir.CompilerIrInstrSeq
                (__tl_make-array (ir.CompilerIrInstr.Jump header))
                1))
            (ir.CompilerIrBlock.Block header head-instrs)
            (ir.CompilerIrBlock.Block body body-instrs)
            (ir.CompilerIrBlock.Block
              exit
              (ir.CompilerIrInstrSeq
                (__tl_make-array
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1))))
                1)))
          4))]
    [func : ir.CompilerIrFunction
      (ir.CompilerIrFunction.Function
        (ci.intern "recurrence_test")
        (ir.CompilerIrParamSeq
          (__tl_make-array
            (ir.CompilerIrParam.Param
              "seed"
              (view.compiler-owned-shared-view ty)
              0)
            (ir.CompilerIrParam.Param "count" (ast.AstType.I64) 6))
          2)
        ty
        7
        blocks
        (ir.CompilerIrFunctionAbi.Ordinary))]
    [out : ir.CompilerIrFunction (opt.opt-mul-latency-function func)]
    (begin
      (test.assert-true
        (opt.opt-verify-ok?
          (opt.opt-verify-function (view.compiler-owned-shared-view out)))
        "rewriting retains a valid SSA control-flow graph")
      (test.assert-i64-eq
        (opt.opt-function-frame (view.compiler-owned-shared-view out))
        (if (< mode 2)
          8
          7)
        "only cycles over supported scalar multiply allocate a temporary")
      (match (opt.opt-function-blocks out)
        [(ir.CompilerIrBlockList.Array seq)
          (match (ir.compiler-ir-block-seq-ref seq 2)
            [(ir.CompilerIrBlock.Block _ instrs)
              (begin
                (test.assert-i64-eq
                  instrs.len
                  (if (< mode 2)
                    4
                    3)
                  "one shift and one add replace the recurrence multiply")
                (when
                  (< mode 2)
                  (begin
                    (test.assert-true
                      (match (ir.compiler-ir-instr-seq-ref
                        (view.compiler-owned-shared-view instrs)
                        0)
                        [(ir.CompilerIrInstr.BinOp
                            7
                            (ir.CompilerIrBinOp.Shl (ast.AstType.I64))
                            (ir.CompilerIrValue.Var 1)
                            (ir.CompilerIrValue.I64 5)
                            (ast.AstType.I64))
                          true]
                        [_ false])
                      "shift the recurrence source into the fresh temporary")
                    (test.assert-true
                      (match (ir.compiler-ir-instr-seq-ref instrs 1)
                        [(ir.CompilerIrInstr.BinOp
                            3
                            (ir.CompilerIrBinOp.Add)
                            (ir.CompilerIrValue.Var 7)
                            (ir.CompilerIrValue.Var 1)
                            (ast.AstType.I64))
                          true]
                        [_ false])
                      "add the original source into the original destination"))))])]
        [_ (test.assert-true false "dense blocks retained")]))))

(test
  multiply_recurrence_selection
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [mode : i64 0]
      (while (< mode 5)
        (let
          [scope (arena.make)]
          (begin
            (in-arena scope (check-rewrite mode))
            (arena.destroy-safe! scope)
            (set! mode (+ mode 1))))))))