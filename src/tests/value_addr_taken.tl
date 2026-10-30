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
              (opt.opt-bool-branch-clone-blocks (& blocks)))
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
          (opt.opt-bool-branch-clone-blocks (& blocks))
          (opt.opt-cfg-context-build
            (opt.opt-bool-branch-clone-blocks (& blocks)))
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

;; The other storage object must not turn off unrelated rewrites.
(test
  value-gate-mixed-function
  (reset!)
  (let
    [func
      (irt.func
        "function @mixed(n=%0:i64) -> i64 vars 16 {
       entry:
       %1 = mov 5 : i64
       %2 = addr_of %1
       %3 = mov @wide_power : i64
       %4 = mul %0, %3 : i64
       %5 = div %0, 2 : i64
       %6 = call sink(%0) : i64
       %7 = call sink(%0) : i64
       %8 = add %4, %5 : i64
       %9 = add %6, %7 : i64
       %10 = add %8, %9 : i64
       return %10
       }")]
    [_valid (valid! (& func))]
    [mul (opt.opt-const-global-mul-shift-final (& (constants)) func)]
    [div (div-run mul)]
    [out (opt.opt-pure-call-dedupe-function (& (call-memory)) (& div))]
    (valid! (& out))
    (test.assert-i64-eq
      (count (& out) 2)
      1
      "unrelated storage keeps multiply rewrite")
    (test.assert-i64-eq
      (count (& out) 1)
      1
      "unrelated storage keeps division rewrite")
    (test.assert-i64-eq
      (count (& out) 3)
      1
      "unrelated storage keeps call dedupe")))

;; Even a clean divisor cannot make a mutable operand/result a value fact.
(define (scalar-function [mul? : bool] [mode : i64]) : ir.CompilerIrFunction
  (irt.func
    (cat.str-cat
      "function @scalar(n=%0:i64) -> i64 vars 8 {
     entry:
     %1 = mov @wide_power : i64
     %3 = "
      (if mul?
        "mul %0, %1"
        "div %0, 2")
      " : i64\n"
      (cond
        [(= mode 1) "%2 = addr_of %0\n"]
        [(= mode 2) "%2 = addr_of %3\n"]
        [else ""])
      "return %3
     }")))

(test
  value-gate-scalar-operands-and-destination
  (for [kind (iterator.range 0 2)]
    (for [mode (iterator.range 0 3)]
      (reset!)
      (let
        [func (scalar-function (= kind 1) mode)]
        [_valid (valid! (& func))]
        [out
          (if (= kind 1)
            (opt.opt-const-global-mul-shift-final (& (constants)) func)
            (div-run func))]
        (valid! (& out))
        (test.assert-i64-eq
          (count
            (& out)
            (if (= kind 1)
              2
              1))
          (if (= mode 0)
            1
            0)
          "only untainted scalar reads and results rewrite")))))

;; A raw rewrite must not consume stale divisor facts, even independently of
;; the branch-rule backstop at the function entry.
(test
  value-gate-divrem-stale-fact-operand
  (let
    [func (scalar-function false 1)]
    [blocks (opt.opt-function-blocks func)]
    [_install (opt.opt-loop-taint-install! 8 (& blocks))]
    [facts : opt.OptDivRemFacts
      (Cons
        (opt.OptDivRemFact.Fact
          0
          (ast.AstType.I64)
          (opt.OptDivRemFactKind.NonZero))
        (box
          (Cons
            (opt.OptDivRemFact.Fact
              0
              (ast.AstType.I64)
              (opt.OptDivRemFactKind.NotNegOne))
            (box (Nil)))))]
    [out
      (opt.opt-divrem-rewrite-instr
        (ast.ast-node-pool-reader-type-segment-bases)
        (& facts)
        (irt.instr "%3 = div 10, %0 : i64"))]
    (test.assert-true
      (match out
        [(BinOp _ (Div) _ _ _) true]
        [_ false])
      "stale nonzero facts cannot justify an unchecked storage read")))

(test
  value-gate-mul-copy-fact-and-stale-rhs
  (let
    [func (mul-function true)]
    [blocks (opt.opt-function-blocks func)]
    [_install (opt.opt-loop-taint-install! 8 (& blocks))]
    [copies (imap.with-capacity 1)]
    [counts (imap.with-capacity 1)]
    [mov (irt.instr "%1 = mov @wide_power : i64")]
    (opt.opt-const-global-mul-shift-note! (&mut copies) (&mut counts) mov)
    (test.assert-i64-eq
      (imap.len (& copies))
      0
      "mutable global copy is not a constant fact")
    ;; Deliberately inject a stale fact to test the rewrite boundary as well.
    (match (irt.instr "%1 = mov @wide_power : i64")
      [(Mov _ (Global name) _)
        (imap.insert-ref! (&mut copies) 1 (ir.compiler-ir-symbol-id name))]
      [_ unit])
    (let
      [out
        (opt.opt-const-global-mul-shift-seq
          (& (constants))
          (& copies)
          (& counts)
          (irt.instrs "%3 = mul %0, %1 : i64"))]
      (test.assert-true
        (match (ir.compiler-ir-instr-seq-borrow out 0)
          [(BinOp _ (Mul) _ _ _) true]
          [_ false])
        "a stale multiplier fact cannot bypass the RHS gate"))))

(define (fact-function [mode : i64]) : ir.CompilerIrFunction
  (irt.func
    (cat.str-cat
      "function @fact(a=%0:i64, b=%1:i64) -> i64 vars 8 {
     entry:
     %3 = mov 77 : i64\n"
      (cond
        [(= mode 1) "%2 = addr_of %0\n"]
        [(= mode 2) "%2 = addr_of %1\n"]
        [(= mode 3) "%2 = addr_of %3\n"]
        [else ""])
      "return %3
     }")))

(test
  value-gate-pure-original-and-resolved-root
  (for [mode (iterator.range 0 3)]
    (let
      [func (fact-function mode)]
      [blocks (opt.opt-function-blocks func)]
      [_install (opt.opt-loop-taint-install! 8 (& blocks))]
      [defs : (__tl_dyn-array i64) (__tl_make-array i64 8)]
      [env (imap.with-capacity 1)]
      (for [id (iterator.range 0 8)]
        (set! (array-ref defs id) 1))
      ;; Old copy knowledge must not hide a mutable original or root.
      (imap.insert-ref! (&mut env) 0 1)
      (test.assert-true
        (=
          (opt.opt-pure-call-value-stable?
            (& defs)
            (& env)
            (& (ir.CompilerIrValue.Var 0)))
          (= mode 0))
        "both the original argument and its resolved root must be values"))))

(define (sink-symbol) : i64
  (match (irt.instr "%3 = call sink(%0) : i64")
    [(Call _ name _ _) name]
    [_ -1]))

(test
  value-gate-pure-seeded-arguments-and-result
  (for [mode (iterator.range 0 4)]
    (let
      [func (fact-function mode)]
      [blocks (opt.opt-function-blocks func)]
      [_install (opt.opt-loop-taint-install! 8 (& blocks))]
      [sites : opt.OptPureCallTable
        (Cons
          (opt.OptPureCallEntry
            (sink-symbol)
            (ir.CompilerIrCallArgs.One (Var 0))
            3)
          (box (Nil)))]
      [out (opt.opt-pure-call-sites-seed sites 3 (Nil))]
      (test.assert-true
        (= (opt.opt-pure-call-sites-empty? (& out)) (or (= mode 1) (= mode 3)))
        "seeded pre-inline arguments/results obey their own admission gate"))))

(test
  value-gate-pure-result-not-recorded
  (for [mode (iterator.range 0 2)]
    (let
      [func
        (fact-function
          (if (= mode 1)
            3
            0))]
      [blocks (opt.opt-function-blocks func)]
      [_install (opt.opt-loop-taint-install! 8 (& blocks))]
      [defs : (__tl_dyn-array i64) (__tl_make-array i64 8)]
      [env (imap.with-capacity 1)]
      [changed : (__tl_dyn-array i64) (__tl_make-array i64 1)]
      (for [id (iterator.range 0 8)]
        (set! (array-ref defs id) 1))
      (match (opt.opt-pure-call-block
        (& (call-memory))
        (& defs)
        (& (Nil))
        (&mut env)
        (Nil)
        (& (irt.instrs "%3 = call sink(%0) : i64"))
        (&mut changed))
        [(Out _ table)
          (test.assert-true
            (= (opt.opt-pure-call-sites-empty? (& table)) (= mode 1))
            "a cache entry never names mutable result storage")]))))

;; Inline-tier pre-SSA input deliberately redefines the storage local.
(test
  value-gate-pure-direct-storage-write-is-barrier
  (let
    [func
      (irt.func
        "function @write_storage(x=%0:i64) -> i64 vars 8 {
       entry:
       %1 = addr_of %0
       %2 = call sink(%1) : i64
       %0 = mov 3 : i64
       %3 = call sink(%1) : i64
       return %3
       }")]
    [out (opt.opt-pure-call-dedupe-function (& (call-memory)) (& func))]
    (test.assert-i64-eq
      (count (& out) 3)
      2
      "a direct storage write invalidates availability through its address")))

(test
  value-gate-seeded-argument-forms
  (for [mode (iterator.range 0 2)]
    (for [form (iterator.range 0 5)]
      (let
        [func (fact-function mode)]
        [blocks (opt.opt-function-blocks func)]
        [_install (opt.opt-loop-taint-install! 8 (& blocks))]
        [args : ir.CompilerIrCallArgs
          (cond
            [(= form 0) (Nil)]
            [(= form 1) (One (Var 0))]
            [(= form 2) (Two (Var 0) (Var 1))]
            [(= form 3) (Two (Var 1) (Var 0))]
            [else
              (let
                [xs : (__tl_dyn-array ir.CompilerIrValue)
                  (__tl_make-array ir.CompilerIrValue 3)]
                (set! (array-ref xs 0) (Var 1))
                (set! (array-ref xs 1) (Var 1))
                (set! (array-ref xs 2) (Var 0))
                (Array xs))])]
        [sites : opt.OptPureCallTable
          (Cons (opt.OptPureCallEntry (sink-symbol) args 3) (box (Nil)))]
        [out (opt.opt-pure-call-sites-seed sites 3 (Nil))]
        (test.assert-true
          (=
            (opt.opt-pure-call-sites-empty? (& out))
            (and (= mode 1) (!= form 0)))
          "every original argument position is checked before seeding")))))

(test
  value-gate-no-candidate-keeps-next-function-fresh
  (let
    [old (div-function true)]
    [old-blocks (opt.opt-function-blocks old)]
    [_old (opt.opt-loop-taint-install! 8 (& old-blocks))]
    [no-mul
      (opt.opt-const-global-mul-shift-final
        (& (constants))
        (scalar-function false 0))]
    (test.assert-i64-eq
      (count (& no-mul) 0)
      1
      "no Mul leaves the function unchanged")
    (let
      [clean
        (opt.opt-const-global-mul-shift-final
          (& (constants))
          (mul-function false))]
      (test.assert-i64-eq
        (count (& clean) 2)
        1
        "next Mul candidate installs its own set"))
    (opt.opt-loop-taint-install! 8 (& old-blocks))
    (let
      [func
        (irt.func
          "function @no_loop(p=%0:u64, x=%1:i64) -> i64 vars 8 {
         entry:
         %2 = addr_of %1
         %3 = gep %0, 0 : i64
         %4 = load %3 : i64
         return %4
         }")]
      [out (loop-run true func)]
      (valid! (& out))
      (test.assert-i64-eq
        (opt.opt-function-frame (& out))
        8
        "no loop adds no support"))
    (let
      [clean (loop-run true (gep-function 0 false))]
      (test.assert-i64-eq
        (opt.opt-function-frame (& clean))
        25
        "the next loop candidate installs its own set"))))

;; The mutation audit adds `%22 = mov %20` to the synthesized preheader and
;; changes the Add to read %22. %20 is mutable storage; %22 needs a fresh closure.
(define (refresh-function) : ir.CompilerIrFunction
  (irt.func
    "function @refresh(n=%0:i64, start=%1:i64, p=%2:u64) -> i64 vars 24 {
     entry:
     %20 = mov 9 : i64
     %3 = addr_of %20
     %21 = gt %0, 0 : i64
     branch %21, refresh_loop, refresh_exit
     refresh_loop:
     %5 = phi [0, entry], [%6, refresh_body] : i64
     %7 = lt %5, %0 : i64
     branch %7, refresh_body, refresh_exit
     refresh_body:
     %9 = add %1, %5 : i64
     %10 = gep %2, %9 : i64
     %11 = load %10 : i64
     store_ptr %3, 4 : i64
     %6 = add %5, 1 : i64
     jump refresh_loop
     refresh_exit:
     return 0
     }"))

(test
  value-gate-preheader-closure-is-current
  (reset!)
  (let
    [func (refresh-function)]
    [_valid (valid! (& func))]
    [blocks (opt.opt-function-blocks func)]
    [context
      (opt.opt-cfg-context-build (opt.opt-bool-branch-clone-blocks (& blocks)))]
    (match (opt.opt-gep-offset-prepare-preheaders
      (ast.ast-node-pool-reader-type-segment-bases)
      blocks
      context
      24
      8
      false)
      [(Result staged staged-context changed)
        (test.assert-true changed "the fixture synthesizes a preheader")
        (let
          [loops
            (opt.opt-cfg-natural-loops-with-context
              (opt.opt-bool-branch-clone-blocks (& staged))
              (& staged-context))]
          [loop (& (array-ref loops.slots 0))]
          [labels
            (opt.opt-label-add
              (opt.opt-natural-loop-body loop)
              (opt.opt-natural-loop-header loop))]
          [before
            (opt.opt-loop-tainted?
              (& staged)
              (opt.opt-label-add
                (opt.opt-natural-loop-body loop)
                (opt.opt-natural-loop-header loop)))]
          [_verify
            (valid!
              (&
                (opt.opt-function-with-frame-blocks
                  (& func)
                  24
                  (opt.opt-bool-branch-clone-blocks (& staged)))))]
          [_fresh (opt.opt-loop-taint-install! 24 (& staged))]
          [after (opt.opt-loop-tainted? (& staged) labels)]
          (test.assert-true
            (= before after)
            "the post-synthesis gate agrees with a freshly computed closure"))])))

;; An exit Gep can share the loop's candidate index. Its base must stay stable
;; until that outside use, because the derived Gep reads it in the preheader.
(define (outside-gep-function [mode : i64]) : ir.CompilerIrFunction
  (irt.func
    (cat.str-cat
      "function @gep_outside(n=%0:i64, start=%1:i64, p=%2:u64, q=%4:u64) -> i64 vars 24 {
     entry:
     %13 = mov %2 : u64
     %14 = mov %4 : u64\n"
      (cond
        [(= mode 2) "%3 = addr_of %13\n"]
        [(= mode 1) "%3 = addr_of %14\n"]
        [else "%3 = mov %4 : u64\n"])
      "%21 = gt %0, 0 : i64
     branch %21, pre, done
     pre:
     jump loop
     loop:
     %5 = phi [0, pre], [%6, loop] : i64
     %9 = add %1, %5 : i64
     store_ptr %3, %4 : u64
     %6 = add %5, 1 : i64
     %7 = lt %6, %0 : i64
     branch %7, loop, exit
     exit:
     %10 = gep %13, %9 : i64
     %11 = load %10 : i64
     return %11
     done:
     return 0
     }")))

(define (outside-gep-region-clean? [func : (& ir.CompilerIrFunction)]) : bool
  (let
    [blocks (opt.opt-function-blocks func)]
    [_install (opt.opt-loop-taint-install! 24 (& blocks))]
    [loops
      (opt.opt-cfg-natural-loops-with-context
        (opt.opt-bool-branch-clone-blocks (& blocks))
        (&
          (opt.opt-cfg-context-build
            (opt.opt-bool-branch-clone-blocks (& blocks)))))]
    [loop (& (array-ref loops.slots 0))]
    (not
      (opt.opt-loop-tainted?
        (& blocks)
        (opt.opt-label-add
          (opt.opt-natural-loop-body loop)
          (opt.opt-natural-loop-header loop))))))

(define (outside-gep-count-blocks
  [blocks : (& (Slice ir.CompilerIrBlock))]
  [derived? : bool]) : i64
  (match blocks
    [(slice) 0]
    [(slice (Block _ instrs) & rest)
      (let
        [count : i64 0]
        (for [i (iterator.range 0 (ir.compiler-ir-instr-seq-count instrs))]
          (when
            (match (ir.compiler-ir-instr-seq-borrow instrs i)
              [(Gep dst (Var 13) _ _)
                (if derived?
                  (!= dst 10)
                  (= dst 10))]
              [_ false])
            (+= count 1)))
        (+ count (outside-gep-count-blocks rest derived?)))]))

(define (outside-gep-count [func : (& ir.CompilerIrFunction)] [derived? : bool]) : i64
  (let
    [blocks (opt.opt-function-blocks func)]
    (outside-gep-count-blocks (ir.compiler-ir-block-list-view blocks) derived?)))

(test
  value-gate-gep-outside-loop-base
  (for [mode (iterator.range 0 3)]
    (reset!)
    (let
      [func (outside-gep-function mode)]
      [_valid (valid! (& func))]
      [_clean
        (test.assert-true
          (outside-gep-region-clean? (& func))
          "the loop region itself is clean in all three cases")]
      [out (loop-run true func)]
      (valid! (& out))
      (test.assert-i64-eq
        (opt.opt-function-frame (& out))
        (if (= mode 2)
          24
          25)
        "only a tainted outside base refuses the candidate")
      (test.assert-i64-eq
        (outside-gep-count (& out) true)
        (if (= mode 2)
          0
          1)
        "a mutable outside base must not be read in the preheader")
      (test.assert-i64-eq
        (outside-gep-count (& out) false)
        (if (= mode 2)
          1
          0)
        "the exit keeps reading the current mutable base"))))