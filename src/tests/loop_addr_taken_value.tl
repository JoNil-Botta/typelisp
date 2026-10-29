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

;; The address-taken local each mode makes, or -1.
(define (mode-storage [mode : i64]) : i64
  (cond [(or (= mode 1) (= mode 3)) 3] [(= mode 2) 4] [(= mode 4) 12] [else -1]))

;; How many blocks read `var`. Guards name snapshots, never storage, so a
;; rewrite may not add a block that reads mutable storage.
(define (blocks-reading
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [var : i64]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (+
        (match block
          [(Block _ instrs)
            (if (opt.opt-used-contains
              (&
                (opt.opt-unroll-uses-before
                  (& instrs)
                  0
                  (ir.compiler-ir-instr-seq-count instrs)
                  (imap.with-capacity 8)))
              var)
              1
              0)])
        (blocks-reading rest var))]))

(define (storage-reads [func : (& func ir.CompilerIrFunction)] [var : i64]) : i64
  (let
    [blocks (opt.opt-function-blocks func)]
    (blocks-reading (ir.compiler-ir-block-list-view (& blocks)) var)))

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
    [storage (mode-storage mode)]
    [_storage
      (when
        (>= storage 0)
        (test.assert-i64-eq
          (storage-reads (& out) storage)
          (storage-reads (& func) storage)
          "a rewrite names the snapshot, never the storage"))]
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
        "a snapshot captured before the loop stays invariant")
      (when
        (< kind 2)
        (test.assert-true
          (not (rewritten? kind 4))
          "an address-taken index keeps its per-trip check")
        (test.assert-true
          (rewritten? kind 5)
          "an ordinary invariant index still hoists its check")))))

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
         %5 = mov %0 : i64
         %6 = cast %0 : i64 to u64
         %7 = cast %3 : i64 to u64
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
      (and
        (= (opt.opt-bce-mb-resolve (& blocks) 5 16) 5)
        (= (opt.opt-bce-version-resolve (& instrs) 0 instrs.len 5 16) 5)
        (= (opt.opt-unroll-resolve-copy (& instrs) 0 instrs.len 5 16) 5)
        (match (opt.opt-bce-mb-canon-value
          (& blocks)
          (& (ir.CompilerIrValue.Var 5)))
          [(Var id) (= id 5)]
          [_ false]))
      "a copy of mutable storage is its own read, not the storage")
    (test.assert-true
      (and
        (match (opt.opt-bce-mb-canon-value
          (& blocks)
          (& (ir.CompilerIrValue.Var 6)))
          [(Var id) (= id 6)]
          [_ false])
        (match (opt.opt-bce-mb-canon-value
          (& blocks)
          (& (ir.CompilerIrValue.Var 7)))
          [(Var id) (= id 1)]
          [_ false]))
      "a reinterpret cast of mutable storage is its own read")
    (test.assert-true
      (and
        (= (opt.opt-bce-version-resolve (& instrs) 0 instrs.len 6 16) 6)
        (= (opt.opt-bce-version-resolve (& instrs) 0 instrs.len 7 16) 1))
      "single-block resolution stops only at a cast of mutable storage")
    (test.assert-true
      (and
        (= (opt.opt-bce-version-resolve (& instrs) 0 instrs.len 3 16) 1)
        (= (opt.opt-unroll-resolve-copy (& instrs) 0 instrs.len 3 16) 1))
      "single-block resolution keeps ordinary copies")
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

;; Every rule that calls a var invariant because the loop does not define it
;; must also refuse an address-taken one. %0 has its own (mutable) definition,
;; %11 has none in the block, and %3 is a mutable twin of the ordinary %5.
(define (leaf-blocks) : ir.CompilerIrBlockList
  (irt.blocks
    "entry:
     %0 = mov %1 : i64
     %2 = addr_of %0
     %3 = add %1, 4 : i64
     %4 = addr_of %3
     %5 = add %1, 4 : i64
     %10 = addr_of %11
     %6 = gep %11, %9 : i64
     %7 = gep %1, %9 : i64
     store_ptr %2, 4 : i64
     return %0"))

(define (leaf-instrs) : ir.CompilerIrInstrSeq
  (let
    [blocks (leaf-blocks)]
    (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "entry"))
      [(Some (Block _ body)) body]
      [(No) (irt.instrs "")])))

;; Whether constant-trip check consolidation takes `var` as an invariant base,
;; and as an invariant length.
(define (const-guard-base? [var : i64]) : bool
  (let
    [instrs (leaf-instrs)]
    (match (opt.opt-unroll-const-guard-affine
      (& instrs)
      0
      instrs.len
      9
      (& (ir.CompilerIrValue.Var var))
      16)
      [(Some base scale offset) (and (= base var) (= scale 0) (= offset 0))]
      [(No) false])))

(define (const-guard-length? [var : i64]) : bool
  (let
    [instrs (leaf-instrs)]
    (match (opt.opt-unroll-const-guard-length-root
      (clone instrs)
      0
      instrs.len
      (ir.CompilerIrValue.Var var)
      16)
      [(Some _) true]
      [(No) false])))

(define (self-phi-input-fixed? [var : i64]) : bool
  (let
    [blocks (leaf-blocks)]
    [defs (imap.with-capacity 1)]
    [ok (__tl_make-array bool 1)]
    [_ok (set! (array-ref ok 0) true)]
    [_input
      (opt.opt-bce-mb-self-phi-input
        (& blocks)
        (& defs)
        99
        (& (ir.CompilerIrValue.Var var))
        (ir.CompilerIrMaybeValue.No)
        (&mut ok))]
    (array-ref ok 0)))

(define (descriptor-base-hoisted? [base-id : i64]) : bool
  (let
    [blocks (leaf-blocks)]
    [defs (imap.with-capacity 1)]
    [cell (__tl_make-array i64 4)]
    (match (opt.opt-bce-mb-descriptor-base
      (& defs)
      (& blocks)
      (& blocks)
      base-id
      (opt.OptBceMbHoists.Nil)
      (&mut cell)
      (opt.OptBceVersionGuardAcc.No))
      [(Some _ _ _) true]
      [(No) false])))

;; The guard every derivation starts from (`opt-bce-version-derive-start`).
(define (empty-guard) : opt.OptBceVersionGuardAcc
  (opt.OptBceVersionGuardAcc.Some
    (ir.compiler-ir-instr-builder-new)
    (ir.compiler-ir-value-seq-empty)
    false))

;; Whether single-block BCE hoists the check of `var`, an index the loop does
;; not define, against the ordinary length %5; and multi-block BCE below.
(define (single-block-index-hoisted? [var : i64]) : bool
  (let
    [instrs (leaf-instrs)]
    [defs (imap.with-capacity 1)]
    [cell (__tl_make-array i64 1)]
    [_cell (set! (array-ref cell 0) 12)]
    (match (opt.opt-bce-version-derive-index
      (clone instrs)
      0
      instrs.len
      (& defs)
      0
      0
      99
      (& (ir.CompilerIrValue.I64 0))
      (& (ir.CompilerIrValue.Var 1))
      (&mut cell)
      (& (ir.CompilerIrValue.Var var))
      (& (ir.CompilerIrValue.Var 5))
      true
      (opt.opt-bce-version-fan-new)
      (& (empty-guard)))
      [(Some _ _ _) true]
      [(No) false])))

(define (multi-block-index-hoisted? [var : i64]) : bool
  (let
    [blocks (leaf-blocks)]
    [defs (imap.with-capacity 1)]
    [cell (__tl_make-array i64 1)]
    [_cell (set! (array-ref cell 0) 12)]
    (match (opt.opt-bce-mb-derive-index
      (& blocks)
      (& blocks)
      (& defs)
      0
      0
      99
      true
      (& (ir.CompilerIrValue.I64 0))
      (& (ir.CompilerIrValue.Var 1))
      (&mut cell)
      (& (ir.CompilerIrValue.Var var))
      (& (ir.CompilerIrValue.Var 5))
      (opt.opt-bce-version-fan-new)
      (& (empty-guard)))
      [(Some _ _ _) true]
      [(No) false])))

(test
  loop-addr-taken-invariant-leaves
  (let
    [blocks (leaf-blocks)]
    [instrs (leaf-instrs)]
    [defs (imap.with-capacity 1)]
    [_install (opt.opt-function-addr-taken-install! 12 (& blocks))]
    (test.assert-true
      (and
        (not (const-guard-base? 0))
        (not (const-guard-base? 11))
        (const-guard-base? 1))
      "constant-trip guards take only ordinary storage as a base")
    (test.assert-true
      (and
        (not (const-guard-length? 0))
        (not (const-guard-length? 11))
        (const-guard-length? 1))
      "constant-trip guards take only ordinary storage as a length")
    (test.assert-true
      (and (not (self-phi-input-fixed? 11)) (self-phi-input-fixed? 1))
      "a self-phi input read from mutable storage is not one fixed value")
    (test.assert-true
      (match (opt.opt-bce-mb-preheader-equal-in-seq
        (& blocks)
        (& defs)
        (& (ir.CompilerIrBinOp.Add))
        (& (ir.CompilerIrValue.Var 1))
        (& (ir.CompilerIrValue.I64 4))
        (& instrs))
        [(Some (Var id)) (= id 5)]
        [_ false])
      "a preheader twin names the ordinary copy, not mutable storage")
    (test.assert-true
      (and (not (descriptor-base-hoisted? 11)) (descriptor-base-hoisted? 1))
      "a descriptor handle in mutable storage is not hoisted")
    (test.assert-true
      (and
        (match (opt.opt-fill-call-gep-of (& instrs) 0 instrs.len 6 9)
          [(No) true]
          [_ false])
        (match (opt.opt-fill-call-gep-of (& instrs) 0 instrs.len 7 9)
          [(Some _) true]
          [(No) false]))
      "fill-call recognition refuses only a mutable base")
    (test.assert-true
      (and
        (not (opt.opt-copy-call-gep-tracks? (& instrs) instrs.len 6 9 8))
        (opt.opt-copy-call-gep-tracks? (& instrs) instrs.len 7 9 8))
      "copy-call recognition refuses only a mutable base")
    (test.assert-true
      (and
        (not
          (opt.opt-copy-call-add-pair?
            (& (ir.CompilerIrValue.Var 9))
            (& (ir.CompilerIrValue.Var 11))
            9
            (& defs)))
        (opt.opt-copy-call-add-pair?
          (& (ir.CompilerIrValue.Var 9))
          (& (ir.CompilerIrValue.Var 1))
          9
          (& defs)))
      "copy-call offsets refuse only a mutable addend")
    ;; The backstops: guards and calls name snapshots, never storage.
    (test.assert-true
      (and
        (opt.opt-instrs-read-addr-taken?
          (& (irt.instrs "%13 = lt %0, %1 : bool")))
        (not
          (opt.opt-instrs-read-addr-taken?
            (& (irt.instrs "%13 = lt %5, %1 : bool")))))
      "a guard that reads mutable storage is refused")
    (test.assert-true
      (and
        (opt.opt-loop-call-reads-addr-taken?
          (& (ir.CompilerIrValue.Var 1))
          (& (ir.CompilerIrValue.Var 11))
          (& (ir.CompilerIrValue.I64 0)))
        (not
          (opt.opt-loop-call-reads-addr-taken?
            (& (ir.CompilerIrValue.Var 1))
            (& (ir.CompilerIrValue.Var 5))
            (& (ir.CompilerIrValue.I64 0)))))
      "a fill/copy call that reads mutable storage is refused")
    (test.assert-true
      (and
        (not (single-block-index-hoisted? 11))
        (single-block-index-hoisted? 1))
      "single-block BCE hoists only an ordinary invariant index")
    (test.assert-true
      (and (not (multi-block-index-hoisted? 11)) (multi-block-index-hoisted? 1))
      "multi-block BCE hoists only an ordinary invariant index")))

;; Walks that substitute one value for another stop at a copy of storage: %3
;; is a snapshot of the address-taken %0, %4 reads its storage and %5 the
;; snapshot.
(test
  loop-addr-taken-value-walks
  (let
    [blocks
      (irt.blocks
        "entry:
         %0 = add %1, 2 : i64
         %2 = addr_of %0
         %3 = mov %0 : i64
         %4 = add %0, 1 : i64
         %5 = add %3, 1 : i64
         %6 = mov 9 : i64
         %7 = mov %6 : i64
         store_ptr %2, 4 : i64
         return %0")]
    [_install (opt.opt-function-addr-taken-install! 8 (& blocks))]
    (test.assert-true
      (and
        (match (opt.opt-bce-version-literal-of
          (& blocks)
          (& (ir.CompilerIrValue.Var 3))
          8)
          [(Var id) (= id 3)]
          [_ false])
        (match (opt.opt-bce-version-literal-of
          (& blocks)
          (& (ir.CompilerIrValue.Var 7))
          8)
          [(I64 k) (= k 9)]
          [_ false]))
      "the literal walk keeps a snapshot and folds ordinary copies")
    (test.assert-true
      (and
        (match (opt.opt-bce-version-shift-of
          (& blocks)
          (ir.CompilerIrValue.Var 4)
          -1
          8)
          [(No) true]
          [_ false])
        (match (opt.opt-bce-version-shift-of
          (& blocks)
          (ir.CompilerIrValue.Var 5)
          -1
          8)
          [(Some (Var id)) (= id 3)]
          [_ false]))
      "a shifted value names the snapshot, never the storage")
    ;; A copy is walked only with a nonzero shift, which the refused def of %0
    ;; would fail anyway; the stop keeps that a local fact.
    (test.assert-true
      (match (opt.opt-bce-version-shift-of
        (& blocks)
        (ir.CompilerIrValue.Var 3)
        -2
        8)
        [(No) true]
        [_ false])
      "a shift of a snapshot does not walk into its storage")))

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

(test
  loop-addr-taken-guard-reads-snapshot
  (for [kind (iterator.range 0 2)]
    (for [mode (iterator.range 0 2)]
      (opt.opt-function-addr-taken-install! 0 (& (irt.blocks "empty:\nreturn")))
      (let
        [func (snapshot-function kind mode)]
        [_valid
          (test.assert-true
            (opt.opt-verify-ok? (& (opt.opt-verify-function (& func))))
            "the snapshot fixture is valid IR")]
        [out (opt.opt-bce-version-function (& func))]
        [_valid-out
          (test.assert-true
            (opt.opt-verify-ok? (& (opt.opt-verify-function (& out))))
            "the versioned snapshot fixture is valid IR")]
        (test.assert-true
          (block-reads? (& out) "loop__bce_guard" 5)
          "the checks hoist into a guard on the snapshot")
        (test.assert-true
          (not (block-reads? (& out) "loop__bce_guard" 3))
          "the guard never reads the snapshot's storage")))))

;; Two checks of the address-taken index %4 against different lengths, with a
;; store through its address between them. The counter's check versions the
;; loop, and the fast clone keeps both checks of %4: each reads its storage
;; where it runs, so one cannot stand for the other.
(test
  loop-addr-taken-fusion
  (let
    [func
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
         }")]
    [_install
      (opt.opt-function-addr-taken-install! 0 (& (irt.blocks "empty:\nreturn")))]
    [_valid
      (test.assert-true
        (opt.opt-verify-ok? (& (opt.opt-verify-function (& func))))
        "the fusion fixture is valid IR")]
    [out (opt.opt-bce-version-function (& func))]
    [_valid-out
      (test.assert-true
        (opt.opt-verify-ok? (& (opt.opt-verify-function (& out))))
        "the versioned fusion fixture is valid IR")]
    [blocks (opt.opt-function-blocks (& out))]
    (test.assert-i64-eq
      (match (opt.opt-cfg-find-block
        blocks
        (ir.compiler-ir-label "body__bce_fast"))
        [(Some (Block _ instrs)) (opt.opt-count-bounds-instr-seq (& instrs))]
        [(No) -1])
      2
      "two checks of a mutable index are not fused")))

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

(test
  loop-addr-taken-entry-facts
  (for [both (iterator.range 0 2)]
    (opt.opt-function-addr-taken-install! 0 (& (irt.blocks "empty:\nreturn")))
    (let
      [func (entry-fact-function (= both 1) true)]
      [_valid
        (test.assert-true
          (opt.opt-verify-ok? (& (opt.opt-verify-function (& func))))
          "the entry-fact fixture is valid IR")]
      [out (opt.opt-bce-version-function (& func))]
      [_valid-out
        (test.assert-true
          (opt.opt-verify-ok? (& (opt.opt-verify-function (& out))))
          "the versioned entry-fact fixture is valid IR")]
      (test.assert-true
        (not (= (fast-clone-checks (& out)) 0))
        "a branch fact on mutable storage does not drop the index check")
      (test.assert-i64-eq
        (storage-reads (& out) 0)
        (storage-reads (& func) 0)
        "no guard reads the counter's mutable seed")))
  (let
    [func (entry-fact-function true false)]
    [out (opt.opt-bce-version-function (& func))]
    [_versioned
      (test.assert-i64-eq
        (fast-clone-checks (& out))
        0
        "an ordinary seed's branch facts still version the loop")]
    (test.assert-true
      (not (block-reads? (& out) "loop__bce_guard" 0))
      "the guard drops the conjuncts its dominating branches decide"))
  (let
    [blocks
      (irt.blocks
        "entry:
         %0 = mov %1 : i64
         %2 = addr_of %0
         %3 = ge %0, 0 : i64
         %4 = lt %5, %0 : i64
         %6 = ge %5, 0 : i64
         %7 = lt %8, %5 : i64
         return %0")]
    [_install (opt.opt-function-addr-taken-install! 9 (& blocks))]
    (test.assert-true
      (and
        (not
          (opt.opt-bce-mb-cond-decides?
            (& blocks)
            (& (ir.CompilerIrValue.Var 3))
            true
            (& (ir.CompilerIrBinOp.Ge))
            (& (ir.CompilerIrValue.Var 0))
            (& (ir.CompilerIrValue.I64 0))))
        (not
          (opt.opt-bce-mb-cond-decides?
            (& blocks)
            (& (ir.CompilerIrValue.Var 4))
            true
            (& (ir.CompilerIrBinOp.Lt))
            (& (ir.CompilerIrValue.Var 5))
            (& (ir.CompilerIrValue.Var 0)))))
      "a branch fact never decides a query on mutable storage")
    (test.assert-true
      (and
        (opt.opt-bce-mb-cond-decides?
          (& blocks)
          (& (ir.CompilerIrValue.Var 6))
          true
          (& (ir.CompilerIrBinOp.Ge))
          (& (ir.CompilerIrValue.Var 5))
          (& (ir.CompilerIrValue.I64 0)))
        (opt.opt-bce-mb-cond-decides?
          (& blocks)
          (& (ir.CompilerIrValue.Var 7))
          true
          (& (ir.CompilerIrBinOp.Lt))
          (& (ir.CompilerIrValue.Var 8))
          (& (ir.CompilerIrValue.Var 5))))
      "a branch fact still decides the same query on an ordinary local")))

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

(test
  loop-addr-taken-lftr-induction
  (for [which (iterator.range 0 7)]
    (opt.opt-function-addr-taken-install! 0 (& (irt.blocks "empty:\nreturn")))
    (let
      [func (lftr-iv-function which)]
      [_valid
        (test.assert-true
          (opt.opt-verify-ok? (& (opt.opt-verify-function (& func))))
          "the LFTR induction fixture is valid IR")]
      [out
        (opt.opt-lftr-function
          (ast.ast-node-pool-reader-type-segment-bases)
          (& func))]
      (test.assert-i64-eq
        (opt.opt-function-frame out)
        (if (or (= which 0) (= which 6))
          19
          16)
        "LFTR keeps its test unless both inductions are free of stores"))))

;; A length loaded from a container's length slot is nonnegative, unless a
;; store through the slot pointer's address can redirect the load: %4 loads
;; through the ordinary slot %3, %8 through %6 after a store to %7 = &%6.
(test
  loop-addr-taken-length-slot
  (let
    [blocks
      (irt.blocks
        "entry:
         %3 = gep %2, 1 : i64
         %4 = load %3 : i64
         %6 = gep %2, 1 : i64
         %7 = addr_of %6
         store_ptr %7, %1 : u64
         %8 = load %6 : i64
         return %4")]
    [_install (opt.opt-function-addr-taken-install! 9 (& blocks))]
    (test.assert-true
      (and
        (opt.opt-ubound-len-nonneg?
          (ast.ast-node-pool-reader-type-segment-bases)
          (& blocks)
          (& (ir.CompilerIrValue.Var 4))
          true)
        (not
          (opt.opt-ubound-len-nonneg?
            (ast.ast-node-pool-reader-type-segment-bases)
            (& blocks)
            (& (ir.CompilerIrValue.Var 8))
            true)))
      "BCE takes a length-slot load as nonnegative only through ordinary storage")
    (test.assert-true
      (opt.opt-ubound-len-nonneg?
        (ast.ast-node-pool-reader-type-segment-bases)
        (& blocks)
        (& (ir.CompilerIrValue.Var 8))
        false)
      "the ubound pass, which installs no set, keeps the raw lookup")))

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

(test
  loop-addr-taken-counters
  (for [kind (iterator.range 0 3)]
    (for [which
      (iterator.range
        0
        (if (= kind 1)
          2
          3))]
      (opt.opt-function-addr-taken-install! 0 (& (irt.blocks "empty:\nreturn")))
      (let
        [func (nested-counter-function kind which)]
        [_valid
          (test.assert-true
            (opt.opt-verify-ok? (& (opt.opt-verify-function (& func))))
            "the nested counter fixture is valid IR")]
        [out
          (if (= kind 2)
            (opt.opt-unroll-function
              (ast.ast-node-pool-reader-type-segment-bases)
              (& func))
            (opt.opt-bce-version-function (& func)))]
        (test.assert-true
          (= (> (opt.opt-function-frame out) 32) (= which 0))
          "a counter whose phi or step is address-taken is not counted")))))

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

(test
  loop-addr-taken-length-slot-guard
  (for [redirected (iterator.range 0 2)]
    (opt.opt-function-addr-taken-install! 0 (& (irt.blocks "empty:\nreturn")))
    (let
      [func (length-slot-function (= redirected 1))]
      [_valid
        (test.assert-true
          (opt.opt-verify-ok? (& (opt.opt-verify-function (& func))))
          "the length-slot fixture is valid IR")]
      [out (opt.opt-bce-version-function (& func))]
      [_versioned
        (test.assert-true
          (block-reads? (& out) "loop__bce_guard" 7)
          "a length-slot bound versions the loop")]
      (test.assert-true
        (= (guard-unsigned-lt? (& out)) (= redirected 0))
        "only an ordinary length slot proves the bound nonnegative"))))