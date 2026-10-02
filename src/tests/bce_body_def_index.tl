;; Compare the bounded sparse-query path and dense linear path with the
;; original instruction walk, including duplicate defs and unused spare slots.
(import compiler_optimize as opt)
(import compiler_ir_types as ir)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as imap)
(import stdlib.test)
(import stdlib.arena)

(define (make-instr [kind : i64] [v : i64]) : ir.CompilerIrInstr
  (if (= kind 0)
    (Mov v (I64 7) (I64))
    (StorePtr (Var v) (I64 7) (I64))))

(define (make-blocks [n : i64] [kind : i64] [duplicate : bool]) : ir.CompilerIrBlockList
  (let
    [slots : (__tl_dyn-array ir.CompilerIrBlock)
      (__tl_make-array ir.CompilerIrBlock n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [is : (__tl_dyn-array ir.CompilerIrInstr)
            (__tl_make-array ir.CompilerIrInstr 3)]
          [dst : i64
            (if duplicate
              (% (* i 13) 5)
              (* i 13))]
          (begin
            (set! (array-ref is 0) (make-instr kind dst))
            (set!
              (array-ref is 1)
              (ir.CompilerIrInstr.Mov (+ dst 7) (I64 i) (I64)))
            (set!
              (array-ref is 2)
              (ir.CompilerIrInstr.Mov 999999 (I64 0) (I64)))
            (set!
              (array-ref slots i)
              (ir.CompilerIrBlock.Block i (ir.CompilerIrInstrSeq is 2)))
            (set! i (+ i 1)))))
      (Array (ir.CompilerIrBlockSeq slots n)))))

(define (seed) : opt.OptBceMbVarList
  (opt.opt-bce-mb-var-list-prepend
    (opt.opt-bce-mb-var-list-prepend (opt.opt-bce-mb-var-list-new) 0)
    999999))

(define (check [n : i64] [kind : i64] [duplicate : bool] [pattern : i64]) : unit
  (let
    [bs (make-blocks n kind duplicate)]
    [defs (opt.opt-bce-mb-body-defs (opt.compiler-opt-global-shared-view bs))]
    [uses (imap.with-capacity 16)]
    [i : i64 0]
    (begin
      (while (< i (+ (* n 13) 8))
        (begin
          (when
            (or
              (= pattern 1)
              (and (>= pattern 2) (<= pattern 3) (= (% i pattern) 0))
              (and
                (>= pattern 4)
                (<= pattern 6)
                (= (% i 13) 0)
                (< (/ i 13) (+ pattern 27)))
              (and (= pattern 7) (= i 0)))
            (imap.insert-ref! (&mut uses) i 1))
          (set! i (+ i 1))))
      (when
        (and (> pattern 0) (or (< pattern 4) (= pattern 7)))
        (begin
          (imap.insert-ref! (&mut uses) -1 1)
          (imap.insert-ref! (&mut uses) 999999 1)))
      (let
        [old
          (opt.opt-bce-mb-wire-vars-blocks
            (ir.compiler-ir-block-list-view bs)
            uses
            (seed))]
        [new (opt.opt-bce-mb-body-defs-used defs bs uses (seed))]
        [i : i64 0]
        (begin
          (test.assert-i64-eq
            (opt.opt-bce-mb-var-list-count old)
            (opt.opt-bce-mb-var-list-count new)
            "def count")
          (while (< i (opt.opt-bce-mb-var-list-count old))
            (begin
              (test.assert-i64-eq
                (opt.opt-bce-mb-var-list-ref old i)
                (opt.opt-bce-mb-var-list-ref new i)
                "def order")
              (set! i (+ i 1)))))))))

(test
  bce-body-def-index-preserves-walk-order
  (let
    [kind : i64 0]
    (while (< kind 2)
      (let
        [size : i64 0]
        (begin
          (while (< size 10)
            (let
              [n : i64
                (cond
                  [(< size 3) size]
                  [(= size 3) 15]
                  [(= size 4) 16]
                  [(= size 5) 17]
                  [(= size 6) 31]
                  [(= size 7) 32]
                  [(= size 8) 33]
                  [else 257])]
              [pattern : i64 0]
              (begin
                (while (< pattern 8)
                  (let
                    [scope (arena.make)]
                    (begin
                      (in-arena
                        scope
                        (begin
                          (check n kind false pattern)
                          (check n kind true pattern)))
                      (arena.destroy-safe! scope)
                      (set! pattern (+ pattern 1)))))
                (set! size (+ size 1)))))
          (set! kind (+ kind 1)))))))