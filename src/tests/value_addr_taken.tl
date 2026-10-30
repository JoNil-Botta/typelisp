;; Refs #9420 sections 2-6: each pass gates its complete fact region.
(import compiler_optimize as opt)
(import compiler_ir_types as ir)
(import compiler_ir_text as irt)
(import compiler_ast_types as ast)
(import stdlib.iterator)
(import stdlib.str_cat_runtime as cat)
(import stdlib.test)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as imap)

(define (reset!) : unit
  (opt.opt-loop-taint-install! 0 (& (irt.blocks "entry:\nreturn"))))

(define (valid! [func : (& ir.CompilerIrFunction)]) : unit
  (test.assert-true
    (opt.opt-verify-ok? (& (opt.opt-verify-function func)))
    "fixture and transformed function verify"))

;; Count checked/unchecked division, shift, direct call, or multiplication.
(define (count-blocks [blocks : (& (Slice ir.CompilerIrBlock))] [kind : i64]) : i64
  (match blocks
    [(slice) 0]
    [(slice (Block _ instrs) & rest)
      (let
        [count : i64 0]
        (for [i (iterator.range 0 (ir.compiler-ir-instr-seq-count instrs))]
          (when
            (match (ir.compiler-ir-instr-seq-borrow instrs i)
              [(BinOp _ (Div) _ _ _) (= kind 0)]
              [(BinOp _ (SafeDiv) _ _ _) (= kind 1)]
              [(BinOp _ (Shl _) _ _ _) (= kind 2)]
              [(Call _ _ _ _) (= kind 3)]
              [(BinOp _ (Mul) _ _ _) (= kind 4)]
              [_ false])
            (+= count 1)))
        (+ count (count-blocks rest kind)))]))

(define (count [func : (& ir.CompilerIrFunction)] [kind : i64]) : i64
  (let
    [blocks (opt.opt-function-blocks func)]
    (count-blocks (ir.compiler-ir-block-list-view blocks) kind)))

(define (div-function [mutable : bool]) : ir.CompilerIrFunction
  (irt.func
    (cat.str-cat
      "function @div_storage(d=%0:i64) -> i64 vars 8 {
     entry:\n"
      (if mutable
        "%1 = addr_of %0\n"
        "%1 = mov 0 : u64\n")
      "%2 = ne %0, 0 : i64
     branch %2, body, exit
     body:
     store_ptr %1, 0 : i64
     %3 = div 10, %0 : i64
     return %3
     exit:
     return 7
     }")))

(define (div-run [func : ir.CompilerIrFunction]) : ir.CompilerIrFunction
  (match func
    [(Function name params ret frame blocks abi)
      (let
        [next
          (opt.opt-divrem-safety-blocks-with-context
            frame
            (ast.ast-node-pool-reader-type-segment-bases)
            (& (ir.compiler-ir-representation-index-empty))
            (opt.opt-cfg-context-build
              (opt.compiler-opt-global-shared-view blocks))
            (& params)
            blocks)]
        (Function name params ret frame next abi))]))

(test
  value-gate-divrem
  (for [mode (iterator.range 0 2)]
    (reset!)
    (let
      [func (div-function (= mode 1))]
      (valid! (& func))
      (let
        [out (div-run func)]
        (valid! (& out))
        (test.assert-i64-eq
          (count (& out) 0)
          mode
          "mutable divisor keeps checked division")
        (test.assert-i64-eq
          (count (& out) 1)
          (- 1 mode)
          "ordinary divisor keeps nonzero optimization")))))

(define (constants) : imap.Map
  (let
    [table (imap.with-capacity 1)]
    [instr (irt.instr "%0 = mov @wide_power : i64")]
    (match instr
      [(Mov _ (Global name) _)
        (imap.insert-ref!
          (&mut table)
          (ir.compiler-ir-symbol-id name)
          4294967296)]
      [_ unit])
    table))

(define (mul-function [mutable : bool]) : ir.CompilerIrFunction
  (irt.func
    (cat.str-cat
      "function @mul_storage(n=%0:i64) -> i64 vars 8 {
     entry:
     %1 = mov @wide_power : i64\n"
      (if mutable
        "%2 = addr_of %1\n"
        "%2 = mov 0 : u64\n")
      "store_ptr %2, 3 : i64
     %3 = mul %0, %1 : i64
     return %3
     }")))

(test
  value-gate-mul-shift
  (for [mode (iterator.range 0 2)]
    (reset!)
    (let
      [func (mul-function (= mode 1))]
      [_valid (valid! (& func))]
      [out (opt.opt-const-global-mul-shift-final (& (constants)) func)]
      (valid! (& out))
      (test.assert-i64-eq
        (count (& out) 4)
        mode
        "mutable multiplier stays a multiply")
      (test.assert-i64-eq
        (count (& out) 2)
        (- 1 mode)
        "ordinary multiplier becomes a shift"))))

(define (call-memory) : imap.Map
  (let
    [table (imap.with-capacity 1)]
    (match (irt.instr "%0 = call sink(1) : i64")
      [(Call _ name _ _) (imap.insert-ref! (&mut table) name 0)]
      [_ unit])
    table))

(define (call-function [mutable : bool]) : ir.CompilerIrFunction
  (irt.func
    (cat.str-cat
      "function @call_storage(x=%0:i64) -> i64 vars 8 {
     entry:\n"
      (if mutable
        "%1 = addr_of %0\n"
        "%1 = mov 0 : u64\n")
      "%2 = mov %0 : i64
     store_ptr %1, 3 : i64
     %3 = call sink(%2) : i64
     %4 = call sink(%0) : i64
     %5 = add %3, %4 : i64
     return %5
     }")))

(test
  value-gate-pure-call
  (for [mode (iterator.range 0 2)]
    (reset!)
    (let
      [func (call-function (= mode 1))]
      [out (opt.opt-pure-call-dedupe-function (& (call-memory)) (& func))]
      (valid! (& func))
      (valid! (& out))
      (test.assert-i64-eq
        (count (& out) 3)
        (+ 1 mode)
        "mutable copy roots keep both calls"))))

;; mode 0: ordinary loop; 1: mutable base; 2: captured mutable base;
;; 3: unrelated mutable storage; 4: tainted entry branch, clean loop values.
(define (loop-function [mode : i64] [synthesize? : bool]) : ir.CompilerIrFunction
  (irt.func
    (cat.str-cat
      "function @loop_storage(n=%0:i64, start=%1:i64, p=%2:u64) -> i64 vars 24 {
     entry:\n"
      (cond
        [(or (= mode 1) (= mode 2)) "%3 = addr_of %1\n"]
        [(= mode 3) "%20 = mov 9 : i64\n%3 = addr_of %20\n"]
        [(= mode 4) "%3 = addr_of %0\n"]
        [else "%3 = mov 0 : u64\n"])
      "%4 = mov %1 : i64
     %21 = gt %0, 0 : i64\n"
      (if synthesize?
        "branch %21, loop, exit\n"
        "branch %21, pre, exit\npre:\njump loop\n")
      "loop:
     %5 = phi [0, "
      (if synthesize?
        "entry"
        "pre")
      "], [%6, body] : i64
     %7 = lt %5, 6 : i64
     branch %7, body, exit
     body:
     %8 = mul %5, 3 : i64
     %9 = add "
      (if (= mode 2)
        "%4"
        "%1")
      ", %8 : i64
     %10 = gep %2, %9 : i64
     %11 = load %10 : i64
     store_ptr %3, 4 : i64
     %6 = add %5, 1 : i64
     jump loop
     exit:
     return 0
     }")))

(define (loop-run [gep? : bool] [func : ir.CompilerIrFunction]) : ir.CompilerIrFunction
  (if gep?
    (match (opt.opt-gep-offset-function-with-context-result
      (ast.ast-node-pool-reader-type-segment-bases)
      (& (opt.opt-cfg-context-build (opt.opt-function-blocks func)))
      false
      (& func))
      [(Result next _) next])
    (opt.opt-induction-function
      (ast.ast-node-pool-reader-type-segment-bases)
      (& func))))

(test
  value-gate-induction
  (for [mode (iterator.range 0 5)]
    (reset!)
    (let
      [func (loop-function mode false)]
      (valid! (& func))
      (let
        [out (loop-run false func)]
        (valid! (& out))
        (test.assert-i64-eq
          (opt.opt-function-frame (& out))
          (if (or (= mode 0) (= mode 3))
            28
            24)
          "only clean loops receive derived induction support")))))

;; Gep splitting needs an unscaled counter as the variant Add operand.
(define (gep-function [mode : i64] [synthesize? : bool]) : ir.CompilerIrFunction
  (match (loop-function mode synthesize?)
    [(Function name params ret frame blocks abi)
      (Function name params ret frame (opt.opt-blocks-map blocks gep-block) abi)]))

(define (gep-block [block : ir.CompilerIrBlock]) : ir.CompilerIrBlock
  (match block
    [(Block label instrs)
      (let
        [out (ir.compiler-ir-instr-builder-new)]
        (for [i (iterator.range 0 (ir.compiler-ir-instr-seq-count instrs))]
          (let
            [instr (ir.compiler-ir-instr-seq-ref instrs i)]
            (ir.compiler-ir-instr-builder-push!
              (&mut out)
              (match instr
                [(BinOp 9 (Add) lhs _ ty) (BinOp 9 (Add) lhs (Var 5) ty)]
                [_ instr]))))
        (Block label (ir.compiler-ir-instr-builder-to-seq out)))]))

(test
  value-gate-gep-offset
  (for [mode (iterator.range 0 5)]
    (for [synthesis (iterator.range 0 2)]
      (reset!)
      (let
        [func (gep-function mode (= synthesis 1))]
        (valid! (& func))
        (let
          [out (loop-run true func)]
          (valid! (& out))
          (test.assert-i64-eq
            (opt.opt-function-frame (& out))
            (if (or (= mode 0) (= mode 3))
              25
              24)
            "only clean loops get a hoisted address base"))))))

(test
  value-gate-gep-preheader
  (for [mode (iterator.range 0 3)]
    (reset!)
    (let
      [func (gep-function mode true)]
      [blocks (opt.opt-function-blocks func)]
      [_install (opt.opt-loop-taint-install! 24 (& blocks))]
      [out
        (opt.opt-gep-offset-prepare-preheaders
          (ast.ast-node-pool-reader-type-segment-bases)
          (opt.compiler-opt-global-shared-view blocks)
          (opt.opt-cfg-context-build
            (opt.compiler-opt-global-shared-view blocks))
          24
          8
          false)]
      (match out
        [(Result _ _ changed)
          (test.assert-true
            (= changed (= mode 0))
            "mutable loop cannot acquire a preheader")]))))

(test
  value-gate-installs-clear-prior-function
  (let
    [tainted (loop-function 1 false)]
    [blocks (opt.opt-function-blocks tainted)]
    [_install (opt.opt-loop-taint-install! 24 (& blocks))]
    [out (div-run (div-function false))]
    (test.assert-i64-eq
      (count (& out) 1)
      1
      "divrem clears stale function taint")
    (opt.opt-loop-taint-install! 24 (& blocks))
    (let
      [out
        (opt.opt-const-global-mul-shift-final
          (& (constants))
          (mul-function false))]
      (test.assert-i64-eq
        (count (& out) 2)
        1
        "mul_shift clears stale function taint"))
    (opt.opt-loop-taint-install! 24 (& blocks))
    (let
      [func (call-function false)]
      [out (opt.opt-pure-call-dedupe-function (& (call-memory)) (& func))]
      (test.assert-i64-eq
        (count (& out) 3)
        1
        "pure-call clears stale function taint"))
    (for [kind (iterator.range 0 2)]
      (opt.opt-loop-taint-install! 24 (& blocks))
      (let
        [out
          (loop-run
            (= kind 1)
            (if (= kind 1)
              (gep-function 0 false)
              (loop-function 0 false)))]
        (test.assert-true
          (> (opt.opt-function-frame (& out)) 24)
          "loop pass clears stale function taint")))))