;; A loop may keep a value snapshot, but cannot reuse the definition of storage
;; that an aliased store changes. Each driver must install its own function.
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
;; mode: unrelated store, mutable bound, mutable length, captured bound.
(define (loop-function [kind : i64] [mode : i64]) : ir.CompilerIrFunction
  (irt.func
    (str_cat.str-cat
      "function @loop_storage(n=%0:i64, len=%1:i64, data=%2:u64) -> i64 vars 16 {
       entry:
       %3 = mov %0 : i64
       %4 = mov %1 : i64\n"
      (cond
        [(or (= mode 1) (= mode 3)) "%5 = addr_of %3\n"]
        [(= mode 2) "%5 = addr_of %4\n"]
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
      (if (= kind 2)
        ""
        "bounds_check %7, %4 message \"loop_storage_bounds\"\n")
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

(define (rewritten? [kind : i64] [mode : i64]) : bool
  (let
    [func (loop-function kind mode)]
    [_valid
      (test.assert-true
        (opt.opt-verify-ok? (& (opt.opt-verify-function (& func))))
        "the storage/control fixture is valid IR")]
    [out
      (if (= kind 2)
        (opt.opt-unroll-function
          (ast.ast-node-pool-reader-type-segment-bases)
          (& func))
        (opt.opt-bce-version-function (& func)))]
    [_valid-out
      (test.assert-true
        (opt.opt-verify-ok? (& (opt.opt-verify-function (& out))))
        "the rewritten storage/control fixture is valid IR")]
    (> (opt.opt-function-frame out) 16)))

(test
  loop-addr-taken-drivers-and-snapshots
  (for [kind (iterator.range 0 3)]
    ;; Alternate colliding frame IDs so no driver can use a preceding pass's
    ;; marks. A store to unrelated memory must not disable the optimization.
    (for [repeat (iterator.range 0 2)]
      (opt.opt-function-addr-taken-install! 0 (& (irt.blocks "empty:\nreturn")))
      (test.assert-true
        (not (rewritten? kind 1))
        "an address-taken loop bound is not invariant")
      (test.assert-true
        (rewritten? kind 0)
        "an unrelated store preserves ordinary loop invariance")
      (when
        (< kind 2)
        (test.assert-true
          (not (rewritten? kind 2))
          "an address-taken length cannot prove a check for all trips"))
      (test.assert-true
        (rewritten? kind 3)
        "a snapshot captured before the loop stays invariant"))))

(test
  loop-addr-taken-value-proofs
  (let
    [blocks
      (irt.blocks
        "entry:
         %0 = mov %1 : i64
         %2 = addr_of %0
         %3 = mov %1 : i64
         store_ptr %2, 4 : i64
         return %0")]
    [instrs
      (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "entry"))
        [(Some (Block _ body)) body]
        [(No) (irt.instrs "")])]
    [defs (imap.with-capacity 1)]
    [_install (opt.opt-function-addr-taken-install! 4 (& blocks))]
    (test.assert-true
      (not
        (opt.opt-unroll-invariant-bound?
          (& defs)
          (& (ir.CompilerIrValue.Var 0))))
      "a memory read is not a loop bound value")
    (test.assert-i64-eq
      (opt.opt-unroll-def-index (& instrs.slots) 0 instrs.len 0)
      -1
      "single-block proofs cannot read a mutable local's direct definition")
    (test.assert-i64-eq
      (opt.opt-unroll-def-index (& instrs.slots) 0 instrs.len 3)
      2
      "single-block proofs retain ordinary definitions")
    (test.assert-i64-eq
      (opt.opt-bce-mb-resolve (& blocks) 0 16)
      0
      "multi-block proofs cannot forward through mutable storage")
    (test.assert-i64-eq
      (opt.opt-bce-mb-resolve (& blocks) 3 16)
      1
      "multi-block proofs keep ordinary copies")
    (test.assert-true
      (match (opt.opt-bce-version-invariant-operand
        (& instrs)
        0
        instrs.len
        (& defs)
        (& (ir.CompilerIrValue.Var 0)))
        [(No) true]
        [_ false])
      "single-block guard operands cannot resolve mutable storage")
    (test.assert-true
      (match (opt.opt-bce-mb-invariant-operand
        (& blocks)
        (& defs)
        (& (ir.CompilerIrValue.Var 0)))
        [(No) true]
        [_ false])
      "multi-block guard operands cannot resolve mutable storage")
    (test.assert-true
      (match (opt.opt-bce-fold-invariant-operand
        (& blocks)
        (& (ir.CompilerIrValue.Var 0)))
        [(No) true]
        [_ false])
      "guard-dominated folding cannot recover a mutable value fact")))

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

(test
  loop-addr-taken-lftr
  (for [repeat (iterator.range 0 2)]
    (for [mode (iterator.range 0 3)]
      (let
        [func (lftr-function mode)]
        [_valid
          (test.assert-true
            (opt.opt-verify-ok? (& (opt.opt-verify-function (& func))))
            "the LFTR storage/control fixture is valid IR")]
        [_reset
          (opt.opt-function-addr-taken-install!
            0
            (& (irt.blocks "empty:\nreturn")))]
        [out
          (opt.opt-lftr-function
            (ast.ast-node-pool-reader-type-segment-bases)
            (& func))]
        (test.assert-i64-eq
          (opt.opt-function-frame out)
          (if (= mode 1)
            16
            19)
          "LFTR refuses a mutable trip bound and retains ordinary/snapshot bounds")))))

(test
  loop-addr-taken-call-recognizer-installation
  (for [mode (iterator.range 0 2)]
    (let
      [func
        (irt.func
          (str_cat.str-cat
            "function @call_storage(n=%0:i64, data=%1:u64) -> i64 vars 16 {
             entry:\n"
            (if (= mode 1)
              "%2 = addr_of %0\n"
              "%2 = mov %1 : u64\n")
            "jump loop__bce_fast
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
          false
          context.index
          (__tl_make-array opt.OptBoolBranchDef 0))]
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
            (match (opt.opt-loop-call-shape
              (& blocks)
              (ir.compiler-ir-label "entry")
              (& block)
              (&mut state))
              [(Some _) true]
              [(No) false])])]
      (test.assert-true
        state.addr-taken-ready?
        "fill/copy-call recognition installs its own function at its first candidate")
      (test.assert-true
        (if (= mode 1)
          (not found?)
          found?)
        "the shared call recognizer refuses only the mutable bound"))))

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