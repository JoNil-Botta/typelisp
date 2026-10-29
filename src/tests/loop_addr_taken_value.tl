;; The loop transforms' address-taken gate (#9420): BCE versioning and its
;; hoist, unrolling, fill/copy-call recognition and LFTR refuse a loop that
;; reads or writes a value a store can change through a pointer -- an
;; address-taken local or a value computed from one -- and keep optimizing
;; every other loop. Each transform installs the set for its own function.
(import compiler_optimize as opt)
(import compiler_ir_types as ir)
(import compiler_ir_text as irt)
(import compiler_ast_types as ast)
(import stdlib.iterator)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.test)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as imap)

;; kind: checked self-loop, checked multi-block loop, unchecked unroll loop.
;; mode: unrelated store, mutable bound, mutable length, captured bound, mutable
;; invariant index, ordinary invariant index (checked kinds only).
(define (loop-function [kind : i64] [mode : i64]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @loop_storage(n=%0:i64, len=%1:i64, data=%2:u64) -> i64 vars 16 {
       entry:
       %3 = mov %0 : i64
       %4 = mov %1 : i64
       %12 = mov %1 : i64\n"
      (cond
        [(or (= mode 1) (= mode 3)) "%5 = addr_of %3\n"]
        [(= mode 2) "%5 = addr_of %4\n"]
        [(= mode 4) "%5 = addr_of %12\n"]
        [else "%5 = mov %2 : u64\n"])
      "%6 = mov %3 : i64
       jump loop
       loop:
       %7 = phi [0, entry], [%8, "
      (if (= kind 1)
        "latch"
        "loop")
      "] : i64\n"
      (if (= kind 1)
        (str_cat.str-cat
          "%11 = lt %7, "
          (if (= mode 3)
            "%6"
            "%3")
          " : bool
           branch %11, body, done
           body:\n")
        "")
      (cond
        [(= kind 2) ""]
        [(>= mode 4) "bounds_check %12, %4 message \"loop_storage_bounds\"\n"]
        [else "bounds_check %7, %4 message \"loop_storage_bounds\"\n"])
      "%9 = gep %2, %7 : i64
       %10 = load %9 : i64
       store_ptr %5, 4 : i64\n"
      (if (= kind 1)
        "jump latch\nlatch:\n"
        "")
      "%8 = add %7, 1 : i64\n"
      (if (= kind 1)
        "jump loop\n"
        (str_cat.str-cat
          "%11 = lt %8, "
          (if (= mode 3)
            "%6"
            "%3")
          " : bool
           branch %11, loop, done\n"))
      "done:
       return %7
       }")))

;; The address-taken local each mode makes, or -1 (mode 3 takes the address of
;; %3 and loops on its snapshot %6).
(define (mode-storage [mode : i64]) : i64
  (cond [(or (= mode 1) (= mode 3)) 3] [(= mode 2) 4] [(= mode 4) 12] [else -1]))

(define (lftr-function [mode : i64]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @lftr_storage(n=%0:i64, seed=%1:i64, data=%2:u64) -> i64 vars 16 {
       entry:\n"
      (if (>= mode 1)
        "%5 = addr_of %0\n"
        "%5 = mov %2 : u64\n")
      "%4 = mov %0 : i64
       %12 = add %1, 5 : i64
       jump loop
       loop:
       %3 = phi [0, entry], [%7, body] : i64
       %9 = phi [%12, entry], [%8, body] : i64
       %10 = gep %2, %9 : i64
       jump body
       body:
       store_ptr %5, 4 : i64
       %6 = add %3, 1 : i64
       %7 = mov %6 : i64
       %8 = add %9, 3 : i64
       %11 = lt %6, "
      (if (= mode 2)
        "%4"
        "%0")
      " : i64
       branch %11, loop, exit
       exit:
       return %9
       }")))

;; A snapshot %5 of the address-taken %3, then a store through %3's address.
;; mode 0 indexes from the snapshot (`%5 + i`, `%5 + i + 1`), mode 1 starts
;; the counter at it. kind 0: self-loop, kind 1: multi-block.
(define (snapshot-function [kind : i64] [mode : i64]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @snapshot(n=%0:i64, len=%1:i64, data=%2:u64) -> i64 vars 16 {
       entry:
       %3 = mov %0 : i64
       %4 = addr_of %3
       %5 = mov %3 : i64
       store_ptr %4, 0 : i64
       jump loop
       loop:
       %6 = phi ["
      (if (= mode 0)
        "0"
        "%5")
      ", entry], [%9, "
      (if (= kind 1)
        "latch"
        "loop")
      "] : i64\n"
      (if (= kind 1)
        "%10 = lt %6, %0 : bool
         branch %10, body, done
         body:\n"
        "")
      (if (= mode 0)
        "%7 = add %5, %6 : i64\n"
        "%7 = mov %6 : i64\n")
      "bounds_check %7, %1 message \"snapshot\"
       %8 = add %7, 1 : i64
       bounds_check %8, %1 message \"snapshot_next\"\n"
      (if (= kind 1)
        "jump latch\nlatch:\n"
        "")
      "%9 = add %6, 1 : i64\n"
      (if (= kind 1)
        "jump loop\n"
        "%10 = lt %9, %0 : bool
         branch %10, loop, done\n")
      "done:
       return %6
       }")))

;; Whether `func` has a block `label` that reads `var`.
(define (block-reads?
  [func : (& func ir.CompilerIrFunction)]
  [label : (& str)]
  [var : i64]) : bool
  (let
    [blocks (opt.opt-function-blocks func)]
    (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label label))
      [(Some (Block _ instrs))
        (opt.opt-used-contains
          (&
            (opt.opt-unroll-uses-before
              (& instrs)
              0
              (ir.compiler-ir-instr-seq-count instrs)
              (imap.with-capacity 8)))
          var)]
      [(No) false])))

;; Branches decide `n >= 0` (and, with `both`, `n < bound`) before the
;; preheader stores -1 through a pointer: through n's own address when
;; `mutable`, else into unrelated memory. The counter starts at n.
(define (entry-fact-function [both : bool] [mutable : bool]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @entry_fact(n=%0:i64, bound=%1:i64, len=%2:i64, data=%3:u64) -> i64 vars 16 {
       entry:\n"
      (if mutable
        "%4 = addr_of %0\n"
        "%4 = mov %3 : u64\n")
      "%5 = ge %0, 0 : i64\n"
      (if both
        "branch %5, entry_lt, done
         entry_lt:
         %6 = lt %0, %1 : i64
         branch %6, pre, done\n"
        "branch %5, pre, done\n")
      "pre:
       store_ptr %4, -1 : i64
       jump loop
       loop:
       %7 = phi [%0, pre], [%8, latch] : i64
       %9 = lt %7, %1 : i64
       branch %9, body, done
       body:
       bounds_check %7, %2 message \"entry_fact\"
       jump latch
       latch:
       %8 = add %7, 1 : i64
       jump loop
       done:
       return 0
       }")))

;; The fast clone's checks, or -1 when the loop was not versioned.
(define (fast-clone-checks [func : (& func ir.CompilerIrFunction)]) : i64
  (let
    [blocks (opt.opt-function-blocks func)]
    (match (opt.opt-cfg-find-block
      blocks
      (ir.compiler-ir-label "body__bce_fast"))
      [(Some (Block _ instrs)) (opt.opt-count-bounds-instr-seq (& instrs))]
      [(No) -1])))

;; LFTR retires the counter %3/%6/%7 and tests the pointer %9 (step %8) in its
;; place. `which` takes one var's address and stores through it after its
;; def: 0 none, 1 counter phi, 2 counter step, 3 counter copy, 4 pointer phi,
;; 5 pointer step, 6 pointer seed.
(define (lftr-iv-function [which : i64]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @lftr_iv(n=%0:i64, seed=%1:i64, data=%2:u64) -> i64 vars 16 {
       entry:
       %12 = add %1, 5 : i64\n"
      (if (= which 6)
        "%5 = addr_of %12\nstore_ptr %5, 100 : i64\n"
        "")
      "jump loop
       loop:
       %3 = phi [0, entry], [%7, body] : i64
       %9 = phi [%12, entry], [%8, body] : i64\n"
      (cond
        [(= which 1) "%5 = addr_of %3\nstore_ptr %5, 100 : i64\n"]
        [(= which 4) "%5 = addr_of %9\nstore_ptr %5, 100 : i64\n"]
        [else ""])
      "%10 = gep %2, %9 : i64
       jump body
       body:
       %6 = add %3, 1 : i64\n"
      (if (= which 2)
        "%5 = addr_of %6\nstore_ptr %5, 100 : i64\n"
        "")
      "%7 = mov %6 : i64\n"
      (if (= which 3)
        "%5 = addr_of %7\nstore_ptr %5, 100 : i64\n"
        "")
      "%8 = add %9, 3 : i64\n"
      (if (= which 5)
        "%5 = addr_of %8\nstore_ptr %5, 100 : i64\n"
        "")
      "%11 = lt %6, %0 : i64
       branch %11, loop, exit
       exit:
       return %9
       }")))

;; The inner loop's counter phi %7 (`which` 1) or step %8 (2) has its address
;; taken after the inner loop, and the next outer trip stores -5 through it
;; from inside the inner loop; 0 takes an unrelated local's address. kind:
;; checked self-loop, checked multi-block loop (its step's address cannot be
;; taken outside), unchecked unroll loop.
(define (nested-counter-function [kind : i64] [which : i64]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @nested(n=%0:i64, len=%1:i64, m=%2:i64, data=%9:u64) -> i64 vars 32 {
       entry:
       %3 = mov %0 : i64
       %25 = mov 0 : i64
       jump outer
       outer:
       %20 = phi [0, entry], [%21, outer_latch] : i64
       %22 = phi [%9, entry], [%5, outer_latch] : u64
       jump loop
       loop:
       %7 = phi [0, outer], [%8, "
      (if (= kind 1)
        "latch"
        "loop")
      "] : i64\n"
      (if (= kind 1)
        "%11 = lt %7, %3 : bool
         branch %11, body, outer_latch
         body:\n"
        "")
      (if (= kind 2)
        ""
        "bounds_check %7, %1 message \"nested\"\n")
      "%26 = gep %9, %7 : i64
       %27 = load %26 : i64
       store_ptr %22, -5 : i64\n"
      (if (= kind 1)
        "jump latch\nlatch:\n"
        "")
      "%8 = add %7, 1 : i64\n"
      (if (= kind 1)
        "jump loop\n"
        "%11 = lt %8, %3 : bool
         branch %11, loop, outer_latch\n")
      "outer_latch:\n"
      (cond
        [(= which 1) "%5 = addr_of %7\n"]
        [(= which 2) "%5 = addr_of %8\n"]
        [else "%5 = addr_of %25\n"])
      "%21 = add %20, 1 : i64
       %24 = lt %21, %2 : bool
       branch %24, outer, done
       done:
       return %20
       }")))

;; A self-loop bounded by a length-slot load: through the ordinary slot the
;; guard merges `0 <= seed < bound` into one unsigned compare, which needs
;; `bound >= 0`; through a slot redirected by a store to its address it states
;; both halves.
(define (length-slot-function [redirected : bool]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @length_slot(len=%1:i64, data=%2:u64, obj=%3:u64, seed=%4:i64) -> i64 vars 16 {
       entry:
       %5 = gep %3, 1 : i64\n"
      (if redirected
        "%6 = addr_of %5\nstore_ptr %6, %2 : u64\n"
        "")
      "%7 = load %5 : i64
       jump loop
       loop:
       %8 = phi [%4, entry], [%9, loop] : i64
       bounds_check %8, %1 message \"length_slot\"
       %10 = gep %2, %8 : i64
       %11 = load %10 : i64
       %9 = add %8, 1 : i64
       %12 = lt %9, %7 : bool
       branch %12, loop, done
       done:
       return %8
       }")))

;; Whether `func`'s guard block holds an unsigned `<`.
(define (guard-unsigned-lt? [func : (& func ir.CompilerIrFunction)]) : bool
  (let
    [blocks (opt.opt-function-blocks func)]
    (match (opt.opt-cfg-find-block
      blocks
      (ir.compiler-ir-label "loop__bce_guard"))
      [(Some (Block _ instrs))
        (for [index (iterator.range 0 (ir.compiler-ir-instr-seq-count instrs))]
          (match (ir.compiler-ir-instr-seq-borrow instrs index)
            [(BinOp _ (Lt) _ _ (U64)) (return true)]
            [_ unit]))
        false]
      [(No) false])))

(define (reset!) : unit
  (opt.opt-function-addr-taken-install! 0 (& (irt.blocks "empty:\nreturn"))))

(define (valid? [func : (& func ir.CompilerIrFunction)]) : bool
  (opt.opt-verify-ok? (& (opt.opt-verify-function func))))

;; BCE or unrolling on `func`, after a reset, with both sides verified.
(define (transform [unroll? : bool] [func : ir.CompilerIrFunction]) : ir.CompilerIrFunction
  (let
    [_reset (reset!)]
    [_valid (test.assert-true (valid? (& func)) "the fixture is valid IR")]
    [out
      (if unroll?
        (opt.opt-unroll-function
          (ast.ast-node-pool-reader-type-segment-bases)
          (& func))
        (opt.opt-bce-version-function (& func)))]
    [_valid-out
      (test.assert-true (valid? (& out)) "the transformed fixture is valid IR")]
    out))

;; Whether the transform left `out` alone: it allocated no var past `frame`.
(define (gate-refused? [out : (& out ir.CompilerIrFunction)] [frame : i64]) : bool
  (= (opt.opt-function-frame out) frame))

(test
  loop-addr-taken-gate-drivers
  (for [kind (iterator.range 0 3)]
    (for [mode
      (iterator.range
        0
        (if (= kind 2)
          4
          6))]
      (let
        [out (transform (= kind 2) (loop-function kind mode))]
        ;; The unchecked unroll loop never reads the length mode 2 makes
        ;; mutable, so nothing it reads is tainted.
        (test.assert-true
          (=
            (> (opt.opt-function-frame out) 16)
            (or (= mode 0) (= mode 5) (and (= kind 2) (= mode 2))))
          "only a loop free of address-taken values is transformed")))))

(test
  loop-addr-taken-gate-lftr
  (for [mode (iterator.range 0 3)]
    (let
      [func (lftr-function mode)]
      [_reset (reset!)]
      [out
        (opt.opt-lftr-function
          (ast.ast-node-pool-reader-type-segment-bases)
          (& func))]
      (test.assert-i64-eq
        (opt.opt-function-frame out)
        (if (= mode 0)
          19
          16)
        "LFTR keeps its test when the bound is, or copies, mutable storage")))
  (for [which (iterator.range 0 7)]
    (let
      [func (lftr-iv-function which)]
      [_reset (reset!)]
      [_valid
        (test.assert-true (valid? (& func)) "the LFTR fixture is valid IR")]
      [out
        (opt.opt-lftr-function
          (ast.ast-node-pool-reader-type-segment-bases)
          (& func))]
      (test.assert-i64-eq
        (opt.opt-function-frame out)
        (if (= which 0)
          19
          16)
        "LFTR keeps its test when an induction or seed is mutable storage"))))

(test
  loop-addr-taken-gate-snapshots
  (for [kind (iterator.range 0 2)]
    (for [mode (iterator.range 0 2)]
      (let
        [out (transform false (snapshot-function kind mode))]
        (test.assert-true
          (gate-refused? (& out) 16)
          "a loop on a snapshot of mutable storage is refused whole")))))

(define (fusion-function) : ir.CompilerIrFunction
  (irt.func
    "function @fusion(n=%0:i64, la=%1:i64, lb=%2:i64, data=%3:u64) -> i64 vars 16 {
     entry:
     %4 = mov 0 : i64
     %5 = addr_of %4
     jump loop
     loop:
     %6 = phi [0, entry], [%7, latch] : i64
     %8 = lt %6, %0 : bool
     branch %8, body, done
     body:
     bounds_check %6, %1 message \"counter\"
     bounds_check %4, %1 message \"anchor\"
     store_ptr %5, 8 : i64
     bounds_check %4, %2 message \"target\"
     %9 = gep %3, %4 : i64
     %10 = load %9 : i64
     store_ptr %5, 0 : i64
     jump latch
     latch:
     %7 = add %6, 1 : i64
     jump loop
     done:
     return %6
     }"))

(test
  loop-addr-taken-gate-fusion
  (test.assert-true
    (gate-refused? (& (transform false (fusion-function))) 16)
    "checks of a mutable index are neither fused nor versioned"))

(test
  loop-addr-taken-gate-entry-facts
  (for [both (iterator.range 0 2)]
    (test.assert-true
      (gate-refused?
        (& (transform false (entry-fact-function (= both 1) true)))
        16)
      "branch facts on a mutable seed decide nothing"))
  (let
    [out (transform false (entry-fact-function true false))]
    (test.assert-i64-eq
      (fast-clone-checks (& out))
      0
      "an ordinary seed's branch facts still version the loop")
    (test.assert-true
      (not (block-reads? (& out) "loop__bce_guard" 0))
      "the guard drops the conjuncts its dominating branches decide")))

;; The loop itself reads nothing tainted, but its entry branches carry stale
;; facts: mode 0 stores through the address of the branch condition %5 (so the
;; branch no longer tests `n >= 0`), mode 1 through the address of %13, the copy
;; of the bound that %6 compares the seed with.
(define (branch-fact-function [mode : i64]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @branch_fact(n=%0:i64, bound=%1:i64, len=%2:i64) -> i64 vars 16 {
       entry:
       %13 = mov %1 : i64
       %5 = ge %0, 0 : i64\n"
      (if (= mode 0)
        "%14 = addr_of %5\nstore_ptr %14, 1 : i64\n"
        "%14 = addr_of %13\nstore_ptr %14, 1000 : i64\n")
      "%6 = lt %0, %13 : i64
       branch %5, entry_lt, done
       entry_lt:
       branch %6, pre, done
       pre:
       jump loop
       loop:
       %7 = phi [%0, pre], [%8, latch] : i64
       %9 = lt %7, %1 : i64
       branch %9, body, done
       body:
       bounds_check %7, %2 message \"branch_fact\"
       jump latch
       latch:
       %8 = add %7, 1 : i64
       jump loop
       done:
       return 0
       }")))

(test
  loop-addr-taken-gate-branch-facts
  (for [mode (iterator.range 0 2)]
    (test.assert-true
      (gate-refused? (& (transform false (branch-fact-function mode))) 16)
      "a function that branches on a tainted value has no loop versioned")))

(test
  loop-addr-taken-gate-length-slot
  (for [redirected (iterator.range 0 2)]
    (let
      [out (transform false (length-slot-function (= redirected 1)))]
      (if (= redirected 1)
        (test.assert-true
          (gate-refused? (& out) 16)
          "a bound loaded through a redirected slot pointer is refused")
        (test.assert-true
          (guard-unsigned-lt? (& out))
          "an ordinary length slot still proves the bound nonnegative")))))

(test
  loop-addr-taken-gate-counters
  (for [kind (iterator.range 0 3)]
    (for [which
      (iterator.range
        0
        (if (= kind 1)
          2
          3))]
      (let
        [out (transform (= kind 2) (nested-counter-function kind which))]
        (test.assert-true
          (= (> (opt.opt-function-frame out) 32) (= which 0))
          "a counter whose phi or step is address-taken is not counted")))))

;; A descending inner loop the clone-free hoist would take: the counter %7's
;; address is taken after the inner loop, and the next outer trip stores 100
;; through it.
(define (descending-function) : ir.CompilerIrFunction
  (irt.func
    "function @descending(data=%9:u64) -> i64 vars 32 {
       entry:
       %25 = mov 0 : i64
       %23 = addr_of %25
       jump outer
       outer:
       %20 = phi [0, entry], [%21, outer_latch] : i64
       %22 = phi [%23, entry], [%5, outer_latch] : u64
       jump loop
       loop:
       %7 = phi [2, outer], [%8, latch] : i64
       %15 = phi [0, outer], [%16, latch] : i64
       bounds_check %7, 3 message \"descending\"
       store_ptr %22, 100 : i64
       %16 = add %15, 1 : i64
       %17 = lt %16, 2 : i64
       branch %17, latch, outer_latch
       latch:
       %8 = sub %7, 1 : i64
       %11 = ge %8, 0 : i64
       branch %11, loop, outer_latch
       outer_latch:
       %5 = addr_of %7
       %21 = add %20, 1 : i64
       %24 = lt %21, 2 : i64
       branch %24, outer, done
       done:
       return 0
       }"))

(define (loop-checks [func : (& func ir.CompilerIrFunction)]) : i64
  (let
    [blocks (opt.opt-function-blocks func)]
    (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "loop"))
      [(Some (Block _ instrs)) (opt.opt-count-bounds-instr-seq (& instrs))]
      [(No) -1])))

(test
  loop-addr-taken-gate-descending-hoist
  (test.assert-i64-eq
    (loop-checks (& (transform false (descending-function))))
    1
    "the clone-free hoist keeps the check of a mutable counter"))

;; Value flow decides taint: a bound computed from the address-taken %13 is
;; tainted (mode 0), a load through an `addr_of` result is a snapshot of
;; memory (1), and a loop that only stores through %13's address reads nothing
;; tainted (2).
(define (flow-function [mode : i64]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @flow(n=%0:i64, len=%1:i64, data=%2:u64) -> i64 vars 24 {
       entry:
       %13 = mov %0 : i64
       %14 = addr_of %13
       %15 = add %13, 1 : i64
       %16 = load %14 : i64
       jump loop
       loop:
       %7 = phi [0, entry], [%8, loop] : i64
       bounds_check %7, %1 message \"flow\"
       %9 = gep %2, %7 : i64
       %10 = load %9 : i64\n"
      (if (= mode 2)
        "store_ptr %14, 4 : i64\n"
        "")
      "%8 = add %7, 1 : i64
       %11 = lt %8, "
      (cond [(= mode 0) "%15"] [(= mode 1) "%16"] [else "%0"])
      " : bool
       branch %11, loop, done
       done:
       return %7
       }")))

;; An outer loop that calls out and runs an inner loop, so BCE's clone-free
;; bound tightening takes it: `mutable` stores 4 through the bound's address on
;; every trip, otherwise the store goes to unrelated memory.
(define (tighten-function [mutable : bool]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @tighten(data=%9:u64) -> i64 vars 32 {
       entry:
       %0 = mov 8 : i64\n"
      (if mutable
        "%1 = addr_of %0\n"
        "%1 = mov %9 : u64\n")
      "jump pre
       pre:
       jump header
       header:
       %3 = phi [0, pre], [%6, latch] : i64
       bounds_check %3, 8 message \"tighten\"
       store_ptr %1, 4 : i64
       %12 = call helper(%3) : i64
       jump inner
       inner:
       %30 = phi [0, header], [%31, inner_latch] : i64
       %29 = lt %30, %12 : i64
       branch %29, inner_latch, latch
       inner_latch:
       %31 = add %30, 1 : i64
       jump inner
       latch:
       %6 = add %3, 1 : i64
       %7 = lt %6, %0 : i64
       branch %7, header, exit
       exit:
       return %6
       }")))

(test
  loop-addr-taken-gate-tighten
  (for [mutable (iterator.range 0 2)]
    (let
      [out (transform false (tighten-function (= mutable 1)))]
      [blocks (opt.opt-function-blocks (& out))]
      (test.assert-true
        (=
          (match (opt.opt-cfg-find-block
            blocks
            (ir.compiler-ir-label "header__pred_exit"))
            [(Some _) true]
            [(No) false])
          (= mutable 0))
        "bound tightening refuses a loop on a mutable bound"))))

;; ubound's accepted loop: a guarded rotation whose latch compares against
;; the bound %0. `mutable` takes %0's address and stores 2 through it first.
(define (ubound-function [mutable : bool]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @ubound(n=%0:i64, buf=%1:i64) -> i64 vars 16 {
       entry:\n"
      (if mutable
        "%13 = addr_of %0\nstore_ptr %13, 2 : i64\n"
        "")
      "%2 = lt 0, %0 : i64
       branch %2, pre, exit
       pre:
       %3 = gep %1, 1 : i64
       %4 = load %3 : i64
       jump head
       head:
       %5 = phi [0, pre], [%9, latch] : i64
       bounds_check %5, %4 message \"head_ok\"
       %6 = eq %5, 3 : i64
       branch %6, arm_a, arm_b
       arm_a:
       %7 = add %5, 1 : i64
       jump latch
       arm_b:
       %8 = add %5, 5 : i64
       jump latch
       latch:
       %9 = phi [%7, arm_a], [%8, arm_b] : i64
       %10 = lt %9, %0 : i64
       branch %10, head, exit
       exit:
       %12 = phi [0, entry], [%9, latch] : i64
       return %12
       }")))

(test
  loop-addr-taken-gate-ubound
  (for [mutable (iterator.range 0 2)]
    (let
      [func (ubound-function (= mutable 1))]
      [_reset (reset!)]
      [_valid
        (test.assert-true (valid? (& func)) "the ubound fixture is valid IR")]
      (test.assert-true
        (=
          (match (opt.opt-ubound-function-pass 0 func)
            [(Result _ changed) changed])
          (= mutable 0))
        "ubound refuses a loop on a mutable bound"))))

(test
  loop-addr-taken-gate-value-flow
  (for [mode (iterator.range 0 3)]
    (let
      [out (transform false (flow-function mode))]
      (if (= mode 0)
        (test.assert-true
          (gate-refused? (& out) 24)
          "a value computed from mutable storage is tainted")
        (test.assert-true
          (> (opt.opt-function-frame out) 24)
          "an address, and a load through one, carry no taint")))))

;; A constant-trip byte-word loop (8 trips) whose length %2 is, with `mutable`,
;; address-taken and stored to before the loop.
(define (const-word-function [mutable : bool]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @const_word(data=%0:u64, base=%1:i64, len=%2:i64) -> i64 vars 40 {
       lc_entry:\n"
      (if mutable
        "%38 = addr_of %2\nstore_ptr %38, 3 : i64\n"
        "")
      "jump lc_body
       lc_body:
       %30 = phi [0, lc_entry], [%36, lc_body] : i64
       %28 = phi [7, lc_entry], [%37, lc_body] : i64
       %9 = shl %30, 8 : i64
       %10 = add %1, %28 : i64
       bounds_check %10, %2 message \"lc_bounds\"
       %18 = gep %0, %10 : u8
       %19 = load %18 : u8
       %20 = cast %19 : u8 to i64
       %21 = bit_or %9, %20 : i64
       %36 = mov %21 : i64
       %23 = sub %28, 1 : i64
       %37 = mov %23 : i64
       %39 = ge %23, 0 : i64
       branch %39, lc_body, lc_exit
       lc_exit:
       return %21
       }")))

(test
  loop-addr-taken-gate-const-trip
  (for [mutable (iterator.range 0 2)]
    (let
      [out (transform true (const-word-function (= mutable 1)))]
      (test.assert-true
        (= (> (opt.opt-function-frame out) 40) (= mutable 0))
        "constant-trip unrolling refuses a loop on a mutable length"))))

;; A loop that only writes an address-taken local still touches mutable
;; storage: a clone that renamed the write would leave the storage stale.
(test
  loop-addr-taken-gate-writes
  (let
    [blocks
      (irt.blocks
        "entry:
         %3 = mov %0 : i64
         %4 = addr_of %3
         return %3")]
    [_install (opt.opt-loop-taint-install! 8 (& blocks))]
    (test.assert-true
      (and
        (opt.opt-loop-instrs-tainted? (& (irt.instrs "%3 = mov 5 : i64")))
        (not (opt.opt-loop-instrs-tainted? (& (irt.instrs "%6 = mov 5 : i64")))))
      "a loop that writes mutable storage is tainted")))

(test
  loop-addr-taken-call-recognizer-installation
  (for [mode (iterator.range 0 3)]
    (let
      [func
        (irt.func
          (str_cat.str-cat
            "function @call_storage(n=%0:i64, data=%1:u64) -> i64 vars 16 {
             entry:\n"
            (cond
              [(= mode 1) "%2 = addr_of %0\njump loop__bce_fast\n"]
              [(= mode 2)
                "%2 = mov %1 : u64
                 %7 = lt 0, %0 : i64
                 %8 = addr_of %7
                 store_ptr %8, 1 : i64
                 branch %7, loop__bce_fast, exit\n"]
              [else "%2 = mov %1 : u64\njump loop__bce_fast\n"])
            "
             loop__bce_fast:
             %3 = phi [0, entry], [%4, loop__bce_fast] : i64
             %5 = gep %1, %3 : i64
             store_ptr %5, 7 : i64
             %4 = add %3, 1 : i64
             %6 = lt %4, %0 : i64
             branch %6, loop__bce_fast, exit
             exit:
             return %4
             }"))]
      [blocks (opt.opt-function-blocks func)]
      [context (opt.opt-cfg-context-build (clone blocks))]
      [state
        (opt.OptLoopCallRewriteState
          16
          false
          context.index
          (__tl_make-array opt.OptBoolBranchDef 0)
          false)]
      [_reset
        (opt.opt-function-addr-taken-install!
          0
          (& (irt.blocks "empty:\nreturn")))]
      [found?
        (match (opt.opt-cfg-find-block
          blocks
          (ir.compiler-ir-label "loop__bce_fast"))
          [(No) false]
          [(Some block)
            (match (opt.opt-loop-call-admitted-shape
              (& blocks)
              (ir.compiler-ir-label "entry")
              (& block)
              (&mut state))
              [(Some _) true]
              [(No) false])])]
      (test.assert-true
        state.taint-ready?
        "fill/copy-call recognition installs its own function at its first candidate")
      (test.assert-true
        (if (= mode 0)
          found?
          (not found?))
        "the shared call recognizer refuses a mutable bound or entry condition"))))

(test
  loop-addr-taken-simd-installation
  (for [mode (iterator.range 0 2)]
    (let
      [func
        (irt.func
          (str_cat.str-cat
            "function @simd_storage(n=%0:i64, data=%1:u64) -> i64 vars 16 {
             entry:\n"
            (if (= mode 1)
              "%2 = addr_of %0\n"
              "%2 = mov %1 : u64\n")
            "%3 = mov 0 : i64
             %4 = add %3, 4 : i64
             %5 = le %4, %0 : i64
             branch %5, body, exit
             body:
             %6 = vector_load %1, %3 lanes 4 : i64
             %7 = vector_add %6, %6 lanes 4 : i64
             %8 = vector_add %7, %6 lanes 4 : i64
             %3 = mov %4 : i64
             %4 = add %3, 4 : i64
             %5 = le %4, %0 : i64
             branch %5, body, exit
             exit:
             return 0
             }"))]
      [blocks (opt.opt-function-blocks func)]
      [_reset
        (opt.opt-function-addr-taken-install!
          0
          (& (irt.blocks "empty:\nreturn")))]
      [out
        (match (opt.opt-unroll-simd-function-with-context-result
          (ast.ast-node-pool-reader-type-segment-bases)
          (opt.opt-cfg-context-build blocks)
          func
          false)
          [(Result next _) next])]
      (test.assert-true
        (if (= mode 1)
          (= (opt.opt-function-frame out) 16)
          (> (opt.opt-function-frame out) 16))
        "the direct mutable-SIMD driver installs its own bound facts"))))