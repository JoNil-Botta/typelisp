;; compiler_optimize_smoke.tl - Runnable smoke for compiler_optimize.tl
;; (constant folding, dead-code elimination, common subexpression elimination,
;; copy propagation, strength reduction, typed constant/cast folding, CFG
;; simplification, bounds-check elimination, CFG/dominance/SSA verification,
;; opt-level policy, fixed-point iteration, self-tail-recursion lowering,
;; sparse conditional constant propagation, aggregate stack promotion, global
;; value numbering/cross-block copy propagation, and conservative
;; loop-invariant code motion).
;;
;; Folds constant arithmetic and typed scalar operations into `Mov` literals,
;; reduces safe algebraic identities, eliminates an unused pure temporary,
;; eliminates a repeated pure expression, propagates block-local copies, removes
;; duplicate proven bounds checks, simplifies constant control flow, validates
;; CFG/dominance/SSA/natural-loop utility invariants, stack-promotes safe local
;; aggregate storage, selects optimization policies by level, reruns the pass
;; pipeline to a fixed point, and removes dominated repeated scalar expressions
;; across blocks, hoists safe scalar loop invariants into preheaders, and
;; reduces simple induction-derived loop offsets/addresses, eliminates local
;; redundant loads when alias facts prove no barrier intervened, reports
;; implicit scratch-region candidates/blockers, and validates
;; unused call-graph/SCC infrastructure for the next inliner phases; returns 42
;; only when every self-test passes.
(import "../compiler_optimize_tests.tl")
(import stdlib.string)
(import stdlib.test)

(define (smoke-cfg-index-test-block [label : i64] [value : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return
        (CompilerIrMaybeValue.Some (CompilerIrValue.I64 value)))
      CompilerIrInstrList.Nil)))

(define (smoke-cfg-index-block-return [block : OptMaybeBlock]) : i64
  (match block
    [(OptMaybeBlock.No) (- 0 1)]
    [(OptMaybeBlock.Some found)
      (match found
        [(CompilerIrBlock.Block _ instrs)
          (if (= (compiler-ir-instr-seq-count instrs) 1)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.I64 value)))
                value]
              [_ (- 0 1)])
            (- 0 1))])]))

;; Indexed lookup must keep the old list scan's first-match and missing-label
;; semantics even for a malformed duplicate-label CFG. Building another index
;; deliberately makes the first index's generation stale, exercising its
;; label-array fallback as well as the active generation-table path.
(define (smoke-cfg-index-block-lookup-self-test) : i64
  (let
    [label : i64 (compiler-ir-label "cfg_index_duplicate")]
    [other-label : i64 (compiler-ir-label "cfg_index_other")]
    [missing-label : i64 (compiler-ir-label "cfg_index_missing")]
    [blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact
        (compiler-ir-block-cons
          (smoke-cfg-index-test-block label 11)
          (compiler-ir-block-cons
            (smoke-cfg-index-test-block label 22)
            CompilerIrBlockList.Nil)))]
    [index : OptCfgIndex (opt-cfg-index-build blocks)]
    [active-first : i64
      (smoke-cfg-index-block-return (opt-cfg-index-find-block index label))]
    [replacement-blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact
        (compiler-ir-block-cons
          (smoke-cfg-index-test-block label 44)
          (compiler-ir-block-cons
            (smoke-cfg-index-test-block label 55)
            CompilerIrBlockList.Nil)))]
    [_refresh : unit (opt-cfg-index-refresh-blocks! index replacement-blocks)]
    [dense-second : i64
      (smoke-cfg-index-block-return (opt-cfg-index-block index 1))]
    [_newer-index : OptCfgIndex
      (opt-cfg-index-build
        (compiler-ir-block-cons
          (smoke-cfg-index-test-block other-label 33)
          CompilerIrBlockList.Nil))]
    [stale-first : i64
      (smoke-cfg-index-block-return (opt-cfg-index-find-block index label))]
    [missing : i64
      (smoke-cfg-index-block-return
        (opt-cfg-index-find-block index missing-label))]
    (cond
      [(not (= active-first 11)) 1]
      [(not (= dense-second 55)) 2]
      [(not (= stale-first 44)) 3]
      [(not (= missing (- 0 1))) 4]
      [else 42])))

(define (opt-count-switch-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [acc : i64]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    acc
    (opt-count-switch-instr-seq-from
      instrs
      (+ index 1)
      (+
        acc
        (match (compiler-ir-instr-seq-ref instrs index)
          [(CompilerIrInstr.Switch _ _ _ _) 1]
          [(CompilerIrInstr.TotalEnumSwitch _ _ _ _ _) 1]
          [_ 0])))))

(define (opt-count-switch-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-switch-instr-seq-from instrs 0 0))

(define (opt-count-switch-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-switch-instr-seq instrs)
            (opt-count-switch-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-switch-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-switch-case-list-count [cases : CompilerIrSwitchCaseList]) : i64
  (match cases
    [(CompilerIrSwitchCaseList.Nil) 0]
    [(CompilerIrSwitchCaseList.Cons _ rest)
      (+ 1 (opt-switch-case-list-count (box-get rest)))]
    [(CompilerIrSwitchCaseList.Array seq) (struct-get seq len)]))

(define (opt-switch-entry-base [blocks : CompilerIrBlockList]) : i64
  (match (opt-cfg-find-block blocks (compiler-ir-label "entry"))
    [(OptMaybeBlock.No) (- 0 1)]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (= (compiler-ir-instr-seq-count instrs) 1)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Switch _ base _ _) base]
              [(CompilerIrInstr.TotalEnumSwitch _ base _ _ _) base]
              [_ (- 0 1)])
            (- 0 1))])]))

(define (opt-switch-entry-case-count [blocks : CompilerIrBlockList]) : i64
  (match (opt-cfg-find-block blocks (compiler-ir-label "entry"))
    [(OptMaybeBlock.No) 0]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (= (compiler-ir-instr-seq-count instrs) 1)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Switch _ _ cases _)
                (opt-switch-case-list-count cases)]
              [(CompilerIrInstr.TotalEnumSwitch _ _ cases _ _)
                (opt-switch-case-list-count cases)]
              [_ 0])
            0)])]))

(define (opt-switch-entry-default-label [blocks : CompilerIrBlockList]) : i64
  (match (opt-cfg-find-block blocks (compiler-ir-label "entry"))
    [(OptMaybeBlock.No) (compiler-ir-label-none)]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (= (compiler-ir-instr-seq-count instrs) 1)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Switch _ _ _ default-label) default-label]
              [(CompilerIrInstr.TotalEnumSwitch _ _ _ default-label _)
                default-label]
              [_ (compiler-ir-label-none)])
            (compiler-ir-label-none))])]))

(define (opt-switch-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "tag" (AstType.I64) 0)
    (CompilerIrParamList.Nil)))

(define (opt-switch-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "switch_form")
    (opt-switch-test-params)
    (AstType.I64)
    16
    blocks))

(define (opt-switch-test-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        eq-var
        CompilerIrBinOp.Eq
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 tag)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var eq-var)
          arm-label
          next-label)
        (CompilerIrInstrList.Nil)))))

(define (opt-switch-test-extra-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        eq-var
        CompilerIrBinOp.Eq
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 tag)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 9 (CompilerIrValue.I64 99) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var eq-var)
            arm-label
            next-label)
          (CompilerIrInstrList.Nil))))))

(define (opt-switch-test-total-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        eq-var
        CompilerIrBinOp.Eq
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 tag)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.TotalEnumBranch
          (CompilerIrValue.Var eq-var)
          arm-label
          next-label)
        (CompilerIrInstrList.Nil)))))

(define (opt-switch-test-return-block [label : i64] [value : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return
        (CompilerIrMaybeValue.Some (CompilerIrValue.I64 value)))
      (CompilerIrInstrList.Nil))))

;; Head block whose compare+branch trails an unconditional prefix instruction:
;; the chain pass must keep the prefix ahead of the emitted Switch.
(define (opt-switch-test-prefix-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 9 (CompilerIrValue.Var 0) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          eq-var
          CompilerIrBinOp.Eq
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 tag)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var eq-var)
            arm-label
            next-label)
          (CompilerIrInstrList.Nil))))))

(define (opt-switch-test-block-tail-base [block : CompilerIrBlock]) : i64
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-ir-instr-seq-ref
        instrs
        (- (compiler-ir-instr-seq-count instrs) 1))
        [(CompilerIrInstr.Switch _ base _ _) base]
        [(CompilerIrInstr.TotalEnumSwitch _ base _ _ _) base]
        [_ (- 0 1)])]))

(define (opt-switch-test-block-tail-case-count [block : CompilerIrBlock]) : i64
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-ir-instr-seq-ref
        instrs
        (- (compiler-ir-instr-seq-count instrs) 1))
        [(CompilerIrInstr.Switch _ _ cases _)
          (opt-switch-case-list-count cases)]
        [(CompilerIrInstr.TotalEnumSwitch _ _ cases _ _)
          (opt-switch-case-list-count cases)]
        [_ 0])]))

(define (opt-switch-test-block-tail-default [block : CompilerIrBlock]) : i64
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-ir-instr-seq-ref
        instrs
        (- (compiler-ir-instr-seq-count instrs) 1))
        [(CompilerIrInstr.Switch _ _ _ default-label) default-label]
        [(CompilerIrInstr.TotalEnumSwitch _ _ _ default-label _) default-label]
        [_ (compiler-ir-label-none)])]))

(define (opt-switch-test-block-tail-total? [block : CompilerIrBlock]) : bool
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-ir-instr-seq-ref
        instrs
        (- (compiler-ir-instr-seq-count instrs) 1))
        [(CompilerIrInstr.TotalEnumSwitch _ _ _ _ _) true]
        [_ false])]))

(define (opt-switch-test-block-starts-with-mov? [block : CompilerIrBlock]) : bool
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-ir-instr-seq-ref instrs 0)
        [(CompilerIrInstr.Mov _ _ _) true]
        [_ false])]))

(define (opt-switch-test-cases-have?
  [cases : CompilerIrSwitchCaseList]
  [want-tag : i64]
  [want-label : i64]) : bool
  (match (compiler-ir-switch-case-list-force-cons cases)
    [(CompilerIrSwitchCaseList.Nil) false]
    [(CompilerIrSwitchCaseList.Cons case rest)
      (match case
        [(CompilerIrSwitchCase.Case tag label)
          (if (= tag want-tag)
            (= label want-label)
            (opt-switch-test-cases-have? (box-get rest) want-tag want-label))])]
    [(CompilerIrSwitchCaseList.Array seq)
      (opt-switch-test-cases-have?
        (compiler-ir-switch-case-seq-to-list seq)
        want-tag
        want-label)]))

(define (opt-switch-test-block-tail-has-case?
  [block : CompilerIrBlock]
  [tag : i64]
  [label : i64]) : bool
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-ir-instr-seq-ref
        instrs
        (- (compiler-ir-instr-seq-count instrs) 1))
        [(CompilerIrInstr.Switch _ _ cases _)
          (opt-switch-test-cases-have? cases tag label)]
        [(CompilerIrInstr.TotalEnumSwitch _ _ cases _ _)
          (opt-switch-test-cases-have? cases tag label)]
        [_ false])]))

(define (opt-switch-test-total-trap-ok?
  [blocks : CompilerIrBlockList]
  [label : i64]) : bool
  (match (opt-cfg-find-block blocks label)
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (and
            (= (compiler-ir-instr-seq-count instrs) 2)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Call _ name _ _)
                (= name cbi.compiler-builtin-id-tl-oob-abort)]
              [_ false])
            (match (compiler-ir-instr-seq-ref instrs 1)
              [(CompilerIrInstr.Jump target) (= target label)]
              [_ false]))])]))

(define (opt-switch-test-chain-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-compare-block
      (compiler-ir-label "entry")
      tag0
      1
      (compiler-ir-label "case0")
      (compiler-ir-label "cmp1"))
    (compiler-ir-block-cons
      (opt-switch-test-return-block (compiler-ir-label "case0") 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block
          (compiler-ir-label "cmp1")
          tag1
          2
          (compiler-ir-label "case1")
          (compiler-ir-label "cmp2"))
        (compiler-ir-block-cons
          (opt-switch-test-return-block (compiler-ir-label "case1") 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block
              (compiler-ir-label "cmp2")
              tag2
              3
              (compiler-ir-label "case2")
              (compiler-ir-label "cmp3"))
            (compiler-ir-block-cons
              (opt-switch-test-return-block (compiler-ir-label "case2") 12)
              (compiler-ir-block-cons
                (opt-switch-test-compare-block
                  (compiler-ir-label "cmp3")
                  tag3
                  4
                  (compiler-ir-label "case3")
                  default-label)
                (compiler-ir-block-cons
                  (opt-switch-test-return-block (compiler-ir-label "case3") 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (CompilerIrBlockList.Nil)))))))))))

(define (opt-switch-test-total-chain-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-total-compare-block
      (compiler-ir-label "entry")
      tag0
      1
      (compiler-ir-label "case0")
      (compiler-ir-label "cmp1"))
    (compiler-ir-block-cons
      (opt-switch-test-return-block (compiler-ir-label "case0") 10)
      (compiler-ir-block-cons
        (opt-switch-test-total-compare-block
          (compiler-ir-label "cmp1")
          tag1
          2
          (compiler-ir-label "case1")
          (compiler-ir-label "cmp2"))
        (compiler-ir-block-cons
          (opt-switch-test-return-block (compiler-ir-label "case1") 11)
          (compiler-ir-block-cons
            (opt-switch-test-total-compare-block
              (compiler-ir-label "cmp2")
              tag2
              3
              (compiler-ir-label "case2")
              (compiler-ir-label "cmp3"))
            (compiler-ir-block-cons
              (opt-switch-test-return-block (compiler-ir-label "case2") 12)
              (compiler-ir-block-cons
                (opt-switch-test-total-compare-block
                  (compiler-ir-label "cmp3")
                  tag3
                  4
                  (compiler-ir-label "case3")
                  default-label)
                (compiler-ir-block-cons
                  (opt-switch-test-return-block (compiler-ir-label "case3") 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (CompilerIrBlockList.Nil)))))))))))

(define (opt-switch-test-short-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-compare-block
      (compiler-ir-label "entry")
      0
      1
      (compiler-ir-label "case0")
      (compiler-ir-label "cmp1"))
    (compiler-ir-block-cons
      (opt-switch-test-return-block (compiler-ir-label "case0") 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block
          (compiler-ir-label "cmp1")
          1
          2
          (compiler-ir-label "case1")
          (compiler-ir-label "cmp2"))
        (compiler-ir-block-cons
          (opt-switch-test-return-block (compiler-ir-label "case1") 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block
              (compiler-ir-label "cmp2")
              2
              3
              (compiler-ir-label "case2")
              (compiler-ir-label "fallback"))
            (compiler-ir-block-cons
              (opt-switch-test-return-block (compiler-ir-label "case2") 12)
              (compiler-ir-block-cons
                (opt-switch-test-return-block (compiler-ir-label "fallback") 99)
                (CompilerIrBlockList.Nil)))))))))

(define (opt-switch-test-extra-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-extra-compare-block
      (compiler-ir-label "entry")
      0
      1
      (compiler-ir-label "case0")
      (compiler-ir-label "cmp1"))
    (compiler-ir-block-cons
      (opt-switch-test-return-block (compiler-ir-label "case0") 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block
          (compiler-ir-label "cmp1")
          1
          2
          (compiler-ir-label "case1")
          (compiler-ir-label "cmp2"))
        (compiler-ir-block-cons
          (opt-switch-test-return-block (compiler-ir-label "case1") 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block
              (compiler-ir-label "cmp2")
              2
              3
              (compiler-ir-label "case2")
              (compiler-ir-label "cmp3"))
            (compiler-ir-block-cons
              (opt-switch-test-return-block (compiler-ir-label "case2") 12)
              (compiler-ir-block-cons
                (opt-switch-test-compare-block
                  (compiler-ir-label "cmp3")
                  3
                  4
                  (compiler-ir-label "case3")
                  (compiler-ir-label "fallback"))
                (compiler-ir-block-cons
                  (opt-switch-test-return-block (compiler-ir-label "case3") 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block
                      (compiler-ir-label "fallback")
                      99)
                    (CompilerIrBlockList.Nil)))))))))))

(define (opt-switch-test-prefix-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-prefix-compare-block
      (compiler-ir-label "entry")
      tag0
      1
      (compiler-ir-label "case0")
      (compiler-ir-label "cmp1"))
    (compiler-ir-block-cons
      (opt-switch-test-return-block (compiler-ir-label "case0") 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block
          (compiler-ir-label "cmp1")
          tag1
          2
          (compiler-ir-label "case1")
          (compiler-ir-label "cmp2"))
        (compiler-ir-block-cons
          (opt-switch-test-return-block (compiler-ir-label "case1") 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block
              (compiler-ir-label "cmp2")
              tag2
              3
              (compiler-ir-label "case2")
              (compiler-ir-label "cmp3"))
            (compiler-ir-block-cons
              (opt-switch-test-return-block (compiler-ir-label "case2") 12)
              (compiler-ir-block-cons
                (opt-switch-test-compare-block
                  (compiler-ir-label "cmp3")
                  tag3
                  4
                  (compiler-ir-label "case3")
                  default-label)
                (compiler-ir-block-cons
                  (opt-switch-test-return-block (compiler-ir-label "case3") 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (CompilerIrBlockList.Nil)))))))))))

;; Head block whose dispatch is a bare zero-test branch (`Eq tag, 0` folded
;; onto the tag var), again trailing an unconditional prefix instruction.
(define (opt-switch-test-bare-branch-block
  [label : i64]
  [arm-label : i64]
  [next-label : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 9 (CompilerIrValue.Var 0) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch (CompilerIrValue.Var 0) next-label arm-label)
        (CompilerIrInstrList.Nil)))))

(define (opt-switch-test-bare-blocks [default-label : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-bare-branch-block
      (compiler-ir-label "entry")
      (compiler-ir-label "case0")
      (compiler-ir-label "cmp1"))
    (compiler-ir-block-cons
      (opt-switch-test-return-block (compiler-ir-label "case0") 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block
          (compiler-ir-label "cmp1")
          1
          2
          (compiler-ir-label "case1")
          (compiler-ir-label "cmp2"))
        (compiler-ir-block-cons
          (opt-switch-test-return-block (compiler-ir-label "case1") 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block
              (compiler-ir-label "cmp2")
              2
              3
              (compiler-ir-label "case2")
              (compiler-ir-label "cmp3"))
            (compiler-ir-block-cons
              (opt-switch-test-return-block (compiler-ir-label "case2") 12)
              (compiler-ir-block-cons
                (opt-switch-test-compare-block
                  (compiler-ir-label "cmp3")
                  3
                  4
                  (compiler-ir-label "case3")
                  default-label)
                (compiler-ir-block-cons
                  (opt-switch-test-return-block (compiler-ir-label "case3") 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (CompilerIrBlockList.Nil)))))))))))

;; Compare block testing an explicit compare var (for copy-resolution tests).
(define (opt-switch-test-compare-block-var
  [label : i64]
  [cmp-var : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        eq-var
        CompilerIrBinOp.Eq
        (CompilerIrValue.Var cmp-var)
        (CompilerIrValue.I64 tag)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var eq-var)
          arm-label
          next-label)
        (CompilerIrInstrList.Nil)))))

;; The vm_run dispatch shape: the head compare reads the RAW tag var while the
;; middle compares read the match-scrutinee COPY (block-local copy propagation
;; rewrites same-block operands only). The chain must resolve both through the
;; head prefix's Mov to one logical index var.
(define (opt-switch-test-copy-head-blocks [default-label : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 9 (CompilerIrValue.Var 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            1
            CompilerIrBinOp.Eq
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 0)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 1)
              (compiler-ir-label "case0")
              (compiler-ir-label "cmp1"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (opt-switch-test-return-block (compiler-ir-label "case0") 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block-var
          (compiler-ir-label "cmp1")
          9
          1
          2
          (compiler-ir-label "case1")
          (compiler-ir-label "cmp2"))
        (compiler-ir-block-cons
          (opt-switch-test-return-block (compiler-ir-label "case1") 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block-var
              (compiler-ir-label "cmp2")
              9
              2
              3
              (compiler-ir-label "case2")
              (compiler-ir-label "cmp3"))
            (compiler-ir-block-cons
              (opt-switch-test-return-block (compiler-ir-label "case2") 12)
              (compiler-ir-block-cons
                (opt-switch-test-compare-block-var
                  (compiler-ir-label "cmp3")
                  9
                  3
                  4
                  (compiler-ir-label "case3")
                  default-label)
                (compiler-ir-block-cons
                  (opt-switch-test-return-block (compiler-ir-label "case3") 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (CompilerIrBlockList.Nil)))))))))))

(define (compiler-optimize-switch-form-self-test) : i64
  (let
    [dense-source : CompilerIrBlockList
      (opt-switch-test-chain-blocks 2 0 1 3 (compiler-ir-label "fallback"))]
    [dense : CompilerIrFunction
      (opt-switch-form-function (opt-switch-test-function dense-source))]
    [dense-blocks : CompilerIrBlockList (opt-function-blocks dense)]
    [short : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-short-blocks)))]
    [sparse : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks 0 1 3 4 (compiler-ir-label "fallback"))))]
    [duplicate : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks 0 1 1 2 (compiler-ir-label "fallback"))))]
    [extra : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-extra-blocks)))]
    [prefix : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-prefix-blocks 2 0 1 3 (compiler-ir-label "fallback"))))]
    [prefix-blocks : CompilerIrBlockList (opt-function-blocks prefix)]
    [prefix-twice : CompilerIrFunction (opt-switch-form-function prefix)]
    [prefix-entry : CompilerIrBlock
      (match (opt-cfg-find-block prefix-blocks (compiler-ir-label "entry"))
        [(OptMaybeBlock.No)
          (opt-switch-test-return-block (compiler-ir-label "missing") 0)]
        [(OptMaybeBlock.Some block) block])]
    [bare : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-bare-blocks (compiler-ir-label "fallback"))))]
    [bare-blocks : CompilerIrBlockList (opt-function-blocks bare)]
    [bare-entry : CompilerIrBlock
      (match (opt-cfg-find-block bare-blocks (compiler-ir-label "entry"))
        [(OptMaybeBlock.No)
          (opt-switch-test-return-block (compiler-ir-label "missing") 0)]
        [(OptMaybeBlock.Some block) block])]
    [copy-head : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-copy-head-blocks (compiler-ir-label "fallback"))))]
    [copy-head-blocks : CompilerIrBlockList (opt-function-blocks copy-head)]
    [copy-head-entry : CompilerIrBlock
      (match (opt-cfg-find-block copy-head-blocks (compiler-ir-label "entry"))
        [(OptMaybeBlock.No)
          (opt-switch-test-return-block (compiler-ir-label "missing") 0)]
        [(OptMaybeBlock.Some block) block])]
    [total-final-label : i64 (compiler-ir-label "match_total_enum_default.4")]
    [total-trap-label : i64 (compiler-ir-label "match_total_trap__entry")]
    [total : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-total-chain-blocks 0 1 2 3 total-final-label)))]
    [total-blocks : CompilerIrBlockList (opt-function-blocks total)]
    [total-entry : CompilerIrBlock
      (match (opt-cfg-find-block total-blocks (compiler-ir-label "entry"))
        [(OptMaybeBlock.No)
          (opt-switch-test-return-block (compiler-ir-label "missing") 0)]
        [(OptMaybeBlock.Some block) block])]
    [total-late : CompilerIrFunction
      (opt-late-total-switch-function
        (ast-node-pool-reader-type-segment-bases)
        total)]
    [total-late-blocks : CompilerIrBlockList (opt-function-blocks total-late)]
    [total-late-entry : CompilerIrBlock
      (match (opt-cfg-find-block total-late-blocks (compiler-ir-label "entry"))
        [(OptMaybeBlock.No)
          (opt-switch-test-return-block (compiler-ir-label "missing") 0)]
        [(OptMaybeBlock.Some block) block])]
    [total-twice : CompilerIrFunction
      (opt-late-total-switch-function
        (ast-node-pool-reader-type-segment-bases)
        total-late)]
    [cloned-total : CompilerIrInstr
      (opt-inline-clone-multiblock-instr
        (CompilerIrInstr.TotalEnumSwitch
          (CompilerIrValue.Var 9)
          0
          (compiler-ir-switch-case-cons-linked
            0
            (compiler-ir-label "arm")
            CompilerIrSwitchCaseList.Nil)
          (compiler-ir-label "default")
          (compiler-ir-label "trap"))
        "cloned"
        (CompilerIrCallArgs.Nil)
        0
        10)]
    [cloned-pending-total : CompilerIrInstr
      (opt-inline-clone-multiblock-instr
        (CompilerIrInstr.TotalEnumSwitch
          (CompilerIrValue.Var 9)
          0
          (compiler-ir-switch-case-cons-linked
            0
            (compiler-ir-label "arm")
            CompilerIrSwitchCaseList.Nil)
          (compiler-ir-label "default")
          (compiler-ir-label-none))
        "pending"
        (CompilerIrCallArgs.Nil)
        0
        10)]
    [preheader-forwarded-total : CompilerIrInstr
      (opt-loop-preheaders-retarget-instr
        (CompilerIrInstr.TotalEnumSwitch
          (CompilerIrValue.Var 9)
          0
          (compiler-ir-switch-case-cons-linked
            0
            (compiler-ir-label "arm")
            CompilerIrSwitchCaseList.Nil)
          (compiler-ir-label "trap")
          (compiler-ir-label "trap"))
        (compiler-ir-label "trap")
        (compiler-ir-label "preheader"))]
    ;; Display spellings are deliberately identical to the old protocol. An
    ;; ordinary chain using them must remain an ordinary checked Switch.
    [spoofed : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks 0 1 2 3 total-final-label)))]
    [spoofed-late : CompilerIrFunction
      (opt-late-total-switch-function
        (ast-node-pool-reader-type-segment-bases)
        spoofed)]
    [spoofed-blocks : CompilerIrBlockList (opt-function-blocks spoofed-late)]
    [spoofed-entry : CompilerIrBlock
      (match (opt-cfg-find-block spoofed-blocks (compiler-ir-label "entry"))
        [(OptMaybeBlock.No)
          (opt-switch-test-return-block (compiler-ir-label "missing") 0)]
        [(OptMaybeBlock.Some block) block])]
    [marked-sparse-final-label : i64
      (compiler-ir-label "match_total_enum_default.sparse")]
    [marked-sparse : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-total-chain-blocks 0 1 3 4 marked-sparse-final-label)))]
    [marked-sparse-blocks : CompilerIrBlockList
      (opt-function-blocks marked-sparse)]
    [level1 : CompilerIrFunction
      (optimize-function-with-level
        (ast-node-pool-reader-context-current)
        (ast-node-pool-reader-type-segment-bases)
        (opt-switch-test-function dense-source)
        1)]
    [level2 : CompilerIrFunction
      (optimize-function-with-level
        (ast-node-pool-reader-context-current)
        (ast-node-pool-reader-type-segment-bases)
        (opt-switch-test-function dense-source)
        2)]
    (cond
      [(not (= (opt-count-switch-blocks dense-blocks) 1)) 1]
      [(not (= (opt-switch-entry-base dense-blocks) 0)) 2]
      [(not (= (opt-switch-entry-case-count dense-blocks) 4)) 3]
      [(not
          (=
            (opt-switch-entry-default-label dense-blocks)
            (compiler-ir-label "fallback")))
        4]
      [(opt-block-list-has-label? dense-blocks (compiler-ir-label "cmp1")) 5]
      [(opt-block-list-has-label? dense-blocks (compiler-ir-label "cmp2")) 6]
      [(opt-block-list-has-label? dense-blocks (compiler-ir-label "cmp3")) 7]
      [(not (opt-verify-ok? (opt-verify-function dense))) 8]
      [(not (= (opt-count-switch-blocks (opt-function-blocks short)) 0)) 9]
      [(not (= (opt-count-switch-blocks (opt-function-blocks sparse)) 0)) 10]
      [(not (= (opt-count-switch-blocks (opt-function-blocks duplicate)) 0)) 11]
      [(not (= (opt-count-switch-blocks (opt-function-blocks extra)) 0)) 12]
      [(not (= (opt-count-switch-blocks (opt-function-blocks level1)) 0)) 13]
      [(not (= (opt-count-switch-blocks (opt-function-blocks level2)) 1)) 14]
      ;; A prefix head keeps its unconditional instructions ahead of the
      ;; Switch; the consumed middle compare blocks still disappear.
      [(not (= (opt-count-switch-blocks prefix-blocks) 1)) 15]
      [(not (= (opt-switch-test-block-tail-base prefix-entry) 0)) 16]
      [(not (= (opt-switch-test-block-tail-case-count prefix-entry) 4)) 17]
      [(not
          (=
            (opt-switch-test-block-tail-default prefix-entry)
            (compiler-ir-label "fallback")))
        18]
      [(not (opt-switch-test-block-starts-with-mov? prefix-entry)) 19]
      [(opt-block-list-has-label? prefix-blocks (compiler-ir-label "cmp1")) 20]
      [(opt-block-list-has-label? prefix-blocks (compiler-ir-label "cmp2")) 21]
      [(not (opt-verify-ok? (opt-verify-function prefix))) 22]
      ;; Idempotence: rerunning the pass must not rewrite the rewritten head.
      [(not (= (opt-count-switch-blocks (opt-function-blocks prefix-twice)) 1))
        23]
      ;; A bare zero-test head (`Branch(tag, next, arm)`) is the folded
      ;; `Eq tag, 0` form and must join the chain as the tag-0 candidate.
      [(not (= (opt-count-switch-blocks bare-blocks) 1)) 24]
      [(not (= (opt-switch-test-block-tail-base bare-entry) 0)) 25]
      [(not (= (opt-switch-test-block-tail-case-count bare-entry) 4)) 26]
      [(not
          (=
            (opt-switch-test-block-tail-default bare-entry)
            (compiler-ir-label "fallback")))
        27]
      [(not (opt-switch-test-block-starts-with-mov? bare-entry)) 28]
      [(not (opt-verify-ok? (opt-verify-function bare))) 29]
      ;; The vm_run shape: head compare on the raw var, middle compares on
      ;; the prefix Mov's copy; resolution unifies them and the chain forms.
      [(not (= (opt-count-switch-blocks copy-head-blocks) 1)) 30]
      [(not (= (opt-switch-test-block-tail-base copy-head-entry) 0)) 31]
      [(not (= (opt-switch-test-block-tail-case-count copy-head-entry) 4)) 32]
      [(not
          (=
            (opt-switch-test-block-tail-default copy-head-entry)
            (compiler-ir-label "fallback")))
        33]
      [(not (opt-switch-test-block-starts-with-mov? copy-head-entry)) 34]
      [(not (opt-verify-ok? (opt-verify-function copy-head))) 35]
      ;; Switch formation carries an explicit pending total-enum proof with the
      ;; classic final fallthrough. Only the dedicated late pass consumes it,
      ;; adds the final table case, and installs the trap default.
      [(not (= (opt-count-switch-blocks total-blocks) 1)) 36]
      [(not (opt-switch-test-block-tail-total? total-entry)) 52]
      [(not (= (opt-switch-test-block-tail-base total-entry) 0)) 37]
      [(not (= (opt-switch-test-block-tail-case-count total-entry) 4)) 38]
      [(not
          (= (opt-switch-test-block-tail-default total-entry) total-final-label))
        39]
      [(opt-block-list-has-label? total-blocks total-trap-label) 40]
      [(not (= (opt-count-switch-blocks total-late-blocks) 1)) 41]
      [(not (= (opt-switch-test-block-tail-base total-late-entry) 0)) 43]
      [(not (= (opt-switch-test-block-tail-case-count total-late-entry) 5)) 44]
      [(not
          (opt-switch-test-block-tail-has-case?
            total-late-entry
            4
            total-final-label))
        45]
      [(not
          (=
            (opt-switch-test-block-tail-default total-late-entry)
            total-trap-label))
        46]
      [(not (opt-switch-test-total-trap-ok? total-late-blocks total-trap-label))
        47]
      [(not (opt-verify-ok? (opt-verify-function total-late))) 48]
      [(not (= (opt-count-switch-blocks (opt-function-blocks total-twice)) 1))
        49]
      ;; Old display spellings are not authority without the explicit proof.
      [(opt-switch-test-block-tail-total? spoofed-entry) 53]
      [(not (= (opt-switch-test-block-tail-case-count spoofed-entry) 4)) 54]
      [(not
          (=
            (opt-switch-test-block-tail-default spoofed-entry)
            total-final-label))
        55]
      [(opt-block-list-has-label? spoofed-blocks total-trap-label) 56]
      ;; An explicit proof alone is not enough: a sparse chain fails the
      ;; pre-existing density criterion, so neither Switch nor trap is added.
      [(not (= (opt-count-switch-blocks marked-sparse-blocks) 0)) 50]
      [(opt-block-list-has-label?
          marked-sparse-blocks
          (compiler-ir-label "match_total_trap__entry"))
        51]
      ;; Multiblock inlining preserves the closed proof variant while
      ;; deliberately remapping every real label. The none trap sentinel on a
      ;; pending switch must remain a sentinel rather than becoming a label.
      [(not
          (match cloned-total
            [(CompilerIrInstr.TotalEnumSwitch
                (CompilerIrValue.Var value)
                base
                cases
                default-label
                trap-label)
              (and
                (= value 19)
                (= base 0)
                (opt-switch-test-cases-have?
                  cases
                  0
                  (compiler-ir-label "cloned.arm"))
                (= default-label (compiler-ir-label "cloned.default"))
                (= trap-label (compiler-ir-label "cloned.trap")))]
            [_ false]))
        57]
      [(not
          (match cloned-pending-total
            [(CompilerIrInstr.TotalEnumSwitch _ _ _ default-label trap-label)
              (and
                (= default-label (compiler-ir-label "pending.default"))
                (= trap-label (compiler-ir-label-none)))]
            [_ false]))
        58]
      [(not
          (match preheader-forwarded-total
            [(CompilerIrInstr.TotalEnumSwitch _ _ _ default-label trap-label)
              (and
                (= default-label (compiler-ir-label "preheader"))
                (= trap-label (compiler-ir-label "trap")))]
            [_ false]))
        59]
      [else 42])))

(define (smoke-mov-dst-var-type?
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [src : i64]
  [ty : AstType]) : bool
  (match instrs
    [(CompilerIrInstrList.Nil) false]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Mov d (CompilerIrValue.Var s) mov-ty)
          (if (= d dst)
            (and
              (= s src)
              (opt-type-eq (ast-node-pool-reader-type-segment-bases) mov-ty ty))
            (smoke-mov-dst-var-type? (box-get rest) dst src ty))]
        [_ (smoke-mov-dst-var-type? (box-get rest) dst src ty)])]))

(define (smoke-cast-dst-var-types?
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [src : i64]
  [from-ty : AstType]
  [to-ty : AstType]) : bool
  (match instrs
    [(CompilerIrInstrList.Nil) false]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Cast d (CompilerIrValue.Var s) cast-from cast-to)
          (if (= d dst)
            (and
              (= s src)
              (opt-type-eq
                (ast-node-pool-reader-type-segment-bases)
                cast-from
                from-ty)
              (opt-type-eq
                (ast-node-pool-reader-type-segment-bases)
                cast-to
                to-ty))
            (smoke-cast-dst-var-types? (box-get rest) dst src from-ty to-ty))]
        [_ (smoke-cast-dst-var-types? (box-get rest) dst src from-ty to-ty)])]))

(define (smoke-noop-int-cast-mov-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Cast
      50
      (CompilerIrValue.Var 10)
      (AstType.U8)
      (AstType.Char))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Cast
        51
        (CompilerIrValue.Var 11)
        (AstType.U16)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Cast
          52
          (CompilerIrValue.Var 12)
          (AstType.U16)
          (AstType.Char))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Cast
            53
            (CompilerIrValue.Var 13)
            (AstType.U8)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Cast
              54
              (CompilerIrValue.Var 14)
              (AstType.I16)
              (AstType.U32))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Cast
                55
                (CompilerIrValue.Var 15)
                (AstType.I64)
                (AstType.U64))
              (CompilerIrInstrList.Nil))))))))

(define (smoke-noop-int-cast-mov-self-test) : i64
  (let
    [rewritten : CompilerIrInstrList
      (opt-fold-instrs
        (ast-node-pool-reader-type-segment-bases)
        (OptConstEnv.Nil)
        (smoke-noop-int-cast-mov-instrs))]
    (begin
      (unless (= (opt-count-cast-instrs rewritten) 3) (return 1))
      (unless
        (smoke-mov-dst-var-type? rewritten 50 10 (AstType.Char))
        (return 2))
      (unless (smoke-mov-dst-var-type? rewritten 51 11 (AstType.U8)) (return 3))
      (unless
        (smoke-mov-dst-var-type? rewritten 52 12 (AstType.Char))
        (return 4))
      (unless
        (smoke-cast-dst-var-types? rewritten 55 15 (AstType.I64) (AstType.U64))
        (return 5))
      42)))

(define (smoke-bounds-object-length-check-fragment
  [ptr-var : i64]
  [length-var : i64]
  [cast-var : i64]
  [object : CompilerIrValue]
  [offset : CompilerIrValue]
  [slot-ty : AstType]
  [index : CompilerIrValue]
  [label : i64]
  [tail : CompilerIrInstrList]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep ptr-var object offset slot-ty)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load
        length-var
        (CompilerIrValue.Var ptr-var)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Cast
          cast-var
          (CompilerIrValue.Var length-var)
          (AstType.I64)
          (AstType.U64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            index
            (CompilerIrValue.Var cast-var)
            label)
          tail)))))

(define (smoke-bounds-object-pair
  [second-object : CompilerIrValue]
  [offset : CompilerIrValue]
  [slot-ty : AstType]) : CompilerIrInstrList
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (CompilerIrValue.Var 1)
    offset
    slot-ty
    (CompilerIrValue.Var 0)
    (compiler-ir-label "bounds_ok.0")
    (smoke-bounds-object-length-check-fragment
      20
      21
      22
      second-object
      offset
      slot-ty
      (CompilerIrValue.Var 0)
      (compiler-ir-label "bounds_ok.1")
      (CompilerIrInstrList.Nil))))

(define (smoke-bounds-object-call-barrier) : CompilerIrInstrList
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (CompilerIrValue.Var 1)
    (CompilerIrValue.I64 1)
    (AstType.I64)
    (CompilerIrValue.Var 0)
    (compiler-ir-label "bounds_ok.0")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        30
        (opt-test-symbol "touch")
        (CompilerIrCallArgs.Nil)
        (AstType.Unit))
      (smoke-bounds-object-length-check-fragment
        20
        21
        22
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64)
        (CompilerIrValue.Var 0)
        (compiler-ir-label "bounds_ok.1")
        (CompilerIrInstrList.Nil)))))

;; Element-store survival: a `StorePtr` whose target is the object's tracked
;; length-slot pointer (var 10) changes the length and must clear the facts (the
;; 2nd check survives -> count 2). A `StorePtr` to any other pointer (var 99, an
;; array element) cannot change the length, so the facts survive and the 2nd
;; check is removed (-> count 1).
(define (smoke-bounds-object-store-barrier [store-ptr : CompilerIrValue]) : CompilerIrInstrList
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (CompilerIrValue.Var 1)
    (CompilerIrValue.I64 1)
    (AstType.I64)
    (CompilerIrValue.Var 0)
    (compiler-ir-label "bounds_ok.0")
    (compiler-ir-instr-cons
      (CompilerIrInstr.StorePtr store-ptr (CompilerIrValue.I64 7) (AstType.I64))
      (smoke-bounds-object-length-check-fragment
        20
        21
        22
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64)
        (CompilerIrValue.Var 0)
        (compiler-ir-label "bounds_ok.1")
        (CompilerIrInstrList.Nil)))))

(define (smoke-object-bounds-self-test) : i64
  (let
    [object-array : CompilerIrInstrList
      (opt-bounds-instrs
        (ast-node-pool-reader-type-segment-bases)
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-pair
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 1)
          (AstType.I64)))]
    [object-string : CompilerIrInstrList
      (opt-bounds-instrs
        (ast-node-pool-reader-type-segment-bases)
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-pair
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 8)
          (AstType.U8)))]
    [object-mismatch : CompilerIrInstrList
      (opt-bounds-instrs
        (ast-node-pool-reader-type-segment-bases)
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-pair
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 1)
          (AstType.I64)))]
    [object-call : CompilerIrInstrList
      (opt-bounds-instrs
        (ast-node-pool-reader-type-segment-bases)
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-call-barrier))]
    [object-store : CompilerIrInstrList
      (opt-bounds-instrs
        (ast-node-pool-reader-type-segment-bases)
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-store-barrier (CompilerIrValue.Var 10)))]
    [object-element-store : CompilerIrInstrList
      (opt-bounds-instrs
        (ast-node-pool-reader-type-segment-bases)
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-store-barrier (CompilerIrValue.Var 99)))]
    (cond
      [(not (= (opt-count-bounds-instrs object-array) 1)) 1]
      [(not (= (opt-count-bounds-instrs object-string) 1)) 2]
      [(not (= (opt-count-bounds-instrs object-mismatch) 2)) 3]
      [(not (= (opt-count-bounds-instrs object-call) 2)) 4]
      [(not (= (opt-count-bounds-instrs object-store) 2)) 5]
      [(not (= (opt-count-bounds-instrs object-element-store) 1)) 6]
      [else 42])))

(define (smoke-range-bce-entry [with-nonnegative : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "entry")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        3
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 1 (CompilerIrValue.Var 3) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 0) (AstType.I64))
          (if with-nonnegative
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                14
                (CompilerIrBinOp.Ge)
                (CompilerIrValue.Var 0)
                (CompilerIrValue.I64 0)
                (AstType.Bool))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 14)
                  (compiler-ir-label "lt")
                  (compiler-ir-label "exit"))
                (CompilerIrInstrList.Nil)))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "lt"))
              (CompilerIrInstrList.Nil))))))))

(define (smoke-range-bce-lt [op : CompilerIrBinOp] [length-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "lt")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        15
        op
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var length-var)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 15)
          (compiler-ir-label "body")
          (compiler-ir-label "exit"))
        (CompilerIrInstrList.Nil)))))

(define (smoke-range-bce-body) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (opt-loop-bce-string-test-ref-instrs
      2
      30
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 37)))
        (CompilerIrInstrList.Nil)))))

(define (smoke-range-bce-redefined-body) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 (- 0 1)) (AstType.I64))
      (opt-loop-bce-string-test-ref-instrs
        2
        30
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 37)))
          (CompilerIrInstrList.Nil))))))

(define (smoke-range-bce-blocks
  [with-nonnegative : bool]
  [op : CompilerIrBinOp]
  [length-var : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (smoke-range-bce-entry with-nonnegative)
    (compiler-ir-block-cons
      (smoke-range-bce-lt op length-var)
      (compiler-ir-block-cons
        (smoke-range-bce-body)
        (compiler-ir-block-cons
          (opt-loop-bce-test-exit)
          (CompilerIrBlockList.Nil))))))

(define (smoke-range-bce-redefined-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (smoke-range-bce-entry true)
    (compiler-ir-block-cons
      (smoke-range-bce-lt (CompilerIrBinOp.Lt) 1)
      (compiler-ir-block-cons
        (smoke-range-bce-redefined-body)
        (compiler-ir-block-cons
          (opt-loop-bce-test-exit)
          (CompilerIrBlockList.Nil))))))

(define (smoke-range-bce-count
  [with-nonnegative : bool]
  [op : CompilerIrBinOp]
  [length-var : i64]) : i64
  (let
    [symbols : OptLoopBceTestSymbols (opt-loop-bce-test-symbols)]
    (opt-count-bounds-blocks
      (opt-loop-bce-blocks
        (ast-node-pool-reader-type-segment-bases)
        (opt-loop-bce-test-summaries symbols false false)
        (opt-loop-bce-string-test-params)
        (smoke-range-bce-blocks with-nonnegative op length-var)))))

(define (smoke-range-bce-redefined-count) : i64
  (let
    [symbols : OptLoopBceTestSymbols (opt-loop-bce-test-symbols)]
    (opt-count-bounds-blocks
      (opt-loop-bce-blocks
        (ast-node-pool-reader-type-segment-bases)
        (opt-loop-bce-test-summaries symbols false false)
        (opt-loop-bce-string-test-params)
        (smoke-range-bce-redefined-blocks)))))

(define (smoke-range-bce-self-test) : i64
  (let
    [positive : i64 (smoke-range-bce-count true (CompilerIrBinOp.Lt) 1)]
    [missing-nonnegative : i64
      (smoke-range-bce-count false (CompilerIrBinOp.Lt) 1)]
    [off-by-one : i64 (smoke-range-bce-count true (CompilerIrBinOp.Le) 1)]
    [mismatched-length : i64
      (smoke-range-bce-count true (CompilerIrBinOp.Lt) 20)]
    [redefined-index : i64 (smoke-range-bce-redefined-count)]
    (cond
      [(not (= positive 0)) 1]
      [(not (= missing-nonnegative 1)) 2]
      [(not (= off-by-one 1)) 3]
      [(not (= mismatched-length 1)) 4]
      [(not (= redefined-index 1)) 5]
      [else 42])))

(define (smoke-ssa-iv-bce-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "text" (AstType.String) 2)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "other" (AstType.String) 20)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "start" (AstType.I64) 30)
        (CompilerIrParamList.Nil)))))

(define (smoke-ssa-iv-bce-entry) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "entry")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        3
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 1 (CompilerIrValue.Var 3) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "header"))
          (CompilerIrInstrList.Nil))))))

(define (smoke-ssa-iv-bce-header
  [start : CompilerIrValue]
  [next-var : i64]
  [op : CompilerIrBinOp]
  [upper-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "header")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Phi
        0
        (compiler-ir-phi-input-cons
          start
          (compiler-ir-label "entry")
          (compiler-ir-phi-input-cons
            (CompilerIrValue.Var next-var)
            (compiler-ir-label "body")
            (CompilerIrPhiInputList.Nil)))
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          4
          op
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var upper-var)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 4)
            (compiler-ir-label "body")
            (compiler-ir-label "exit"))
          (CompilerIrInstrList.Nil))))))

(define (smoke-ssa-iv-bce-body
  [symbols : OptLoopBceTestSymbols]
  [object-var : i64]
  [step : i64]
  [next-var : i64]
  [with-call : bool]
  [redefine-index : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (let
      [tail : CompilerIrInstrList
        (opt-loop-bce-string-test-ref-instrs
          object-var
          40
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              next-var
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.I64 step)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "header"))
              (CompilerIrInstrList.Nil))))]
      [after-call : CompilerIrInstrList
        (if with-call
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              80
              (struct-get symbols touch)
              (CompilerIrCallArgs.One (CompilerIrValue.Var object-var))
              (AstType.Unit))
            tail)
          tail)]
      (if redefine-index
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 (- 0 1)) (AstType.I64))
          after-call)
        after-call))))

(define (smoke-ssa-iv-bce-blocks
  [symbols : OptLoopBceTestSymbols]
  [start : CompilerIrValue]
  [step : i64]
  [op : CompilerIrBinOp]
  [upper-var : i64]
  [object-var : i64]
  [with-call : bool]
  [redefine-index : bool]) : CompilerIrBlockList
  (let
    [next-var : i64 90]
    (compiler-ir-block-cons
      (smoke-ssa-iv-bce-entry)
      (compiler-ir-block-cons
        (smoke-ssa-iv-bce-header start next-var op upper-var)
        (compiler-ir-block-cons
          (smoke-ssa-iv-bce-body
            symbols
            object-var
            step
            next-var
            with-call
            redefine-index)
          (compiler-ir-block-cons
            (opt-loop-bce-test-exit)
            (CompilerIrBlockList.Nil)))))))

(define (smoke-ssa-iv-bce-count
  [start : CompilerIrValue]
  [step : i64]
  [op : CompilerIrBinOp]
  [upper-var : i64]
  [object-var : i64]
  [with-call : bool]
  [redefine-index : bool]) : i64
  (let
    [symbols : OptLoopBceTestSymbols (opt-loop-bce-test-symbols)]
    (opt-count-bounds-blocks
      (opt-loop-bce-blocks
        (ast-node-pool-reader-type-segment-bases)
        (opt-loop-bce-test-summaries symbols false false)
        (smoke-ssa-iv-bce-params)
        (smoke-ssa-iv-bce-blocks
          symbols
          start
          step
          op
          upper-var
          object-var
          with-call
          redefine-index)))))

(define (smoke-ssa-iv-bce-self-test) : i64
  (let
    [positive : i64
      (smoke-ssa-iv-bce-count
        (CompilerIrValue.I64 0)
        1
        (CompilerIrBinOp.Lt)
        1
        2
        false
        false)]
    [negative-start : i64
      (smoke-ssa-iv-bce-count
        (CompilerIrValue.I64 (- 0 1))
        1
        (CompilerIrBinOp.Lt)
        1
        2
        false
        false)]
    [unknown-start : i64
      (smoke-ssa-iv-bce-count
        (CompilerIrValue.Var 30)
        1
        (CompilerIrBinOp.Lt)
        1
        2
        false
        false)]
    [negative-step : i64
      (smoke-ssa-iv-bce-count
        (CompilerIrValue.I64 0)
        (- 0 1)
        (CompilerIrBinOp.Lt)
        1
        2
        false
        false)]
    [nonunit-unknown-bound : i64
      (smoke-ssa-iv-bce-count
        (CompilerIrValue.I64 0)
        2
        (CompilerIrBinOp.Lt)
        1
        2
        false
        false)]
    [inclusive-guard : i64
      (smoke-ssa-iv-bce-count
        (CompilerIrValue.I64 0)
        1
        (CompilerIrBinOp.Le)
        1
        2
        false
        false)]
    [mismatched-object : i64
      (smoke-ssa-iv-bce-count
        (CompilerIrValue.I64 0)
        1
        (CompilerIrBinOp.Lt)
        1
        20
        false
        false)]
    [call-clears-length : i64
      (smoke-ssa-iv-bce-count
        (CompilerIrValue.I64 0)
        1
        (CompilerIrBinOp.Lt)
        1
        2
        true
        false)]
    [redefined-index : i64
      (smoke-ssa-iv-bce-count
        (CompilerIrValue.I64 0)
        1
        (CompilerIrBinOp.Lt)
        1
        2
        false
        true)]
    (cond
      [(not (= positive 0)) 1]
      [(not (= negative-start 1)) 2]
      [(not (= unknown-start 1)) 3]
      [(not (= negative-step 1)) 4]
      [(not (= nonunit-unknown-bound 1)) 5]
      [(not (= inclusive-guard 1)) 6]
      [(not (= mismatched-object 1)) 7]
      [(not (= call-clears-length 1)) 8]
      [(not (= redefined-index 1)) 9]
      [else 42])))

(define (smoke-nonlength-guard-header [op : CompilerIrBinOp]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "header")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        43
        op
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 40)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 43)
          (compiler-ir-label "body")
          (compiler-ir-label "exit"))
        (CompilerIrInstrList.Nil)))))

(define (smoke-nonlength-guard-body [object-var : i64] [redefine-bound : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (let
      [tail : CompilerIrInstrList
        (opt-loop-bce-string-test-ref-instrs
          object-var
          50
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 57)))
            (CompilerIrInstrList.Nil)))]
      (if redefine-bound
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 40 (CompilerIrValue.I64 0) (AstType.I64))
          tail)
        tail))))

(define (smoke-nonlength-guard-blocks
  [with-upper : bool]
  [op : CompilerIrBinOp]
  [object-var : i64]
  [redefine-bound : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-loop-bce-string-test-transitive-entry)
    (compiler-ir-block-cons
      (opt-loop-bce-string-test-transitive-upper with-upper)
      (compiler-ir-block-cons
        (smoke-nonlength-guard-header op)
        (compiler-ir-block-cons
          (smoke-nonlength-guard-body object-var redefine-bound)
          (compiler-ir-block-cons
            (opt-loop-bce-test-exit)
            (CompilerIrBlockList.Nil)))))))

(define (smoke-nonlength-guard-count
  [with-upper : bool]
  [op : CompilerIrBinOp]
  [object-var : i64]
  [redefine-bound : bool]) : i64
  (let
    [symbols : OptLoopBceTestSymbols (opt-loop-bce-test-symbols)]
    (opt-loop-bce-string-test-count
      (smoke-nonlength-guard-blocks with-upper op object-var redefine-bound)
      (opt-loop-bce-test-summaries symbols false false))))

(define (smoke-nonlength-guard-bce-self-test) : i64
  (let
    [positive : i64
      (smoke-nonlength-guard-count true (CompilerIrBinOp.Lt) 2 false)]
    [missing-upper : i64
      (smoke-nonlength-guard-count false (CompilerIrBinOp.Lt) 2 false)]
    [mismatched-object : i64
      (smoke-nonlength-guard-count true (CompilerIrBinOp.Lt) 20 false)]
    [redefined-bound : i64
      (smoke-nonlength-guard-count true (CompilerIrBinOp.Lt) 2 true)]
    [off-by-one : i64
      (smoke-nonlength-guard-count true (CompilerIrBinOp.Le) 2 false)]
    (cond
      [(not (= positive 0)) 1]
      [(not (= missing-upper 1)) 2]
      [(not (= mismatched-object 1)) 3]
      [(not (= redefined-bound 1)) 4]
      [(not (= off-by-one 1)) 5]
      [else 42])))

(define (smoke-additive-ref-index-instrs
  [object-var : i64]
  [index-var : i64]
  [base : i64]
  [tail : CompilerIrInstrList]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      base
      (CompilerIrValue.Var object-var)
      (CompilerIrValue.I64 0)
      (AstType.U8))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load (+ base 1) (CompilerIrValue.Var base) (AstType.U64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          (+ base 2)
          (CompilerIrValue.Var object-var)
          (CompilerIrValue.I64 8)
          (AstType.U8))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load
            (+ base 3)
            (CompilerIrValue.Var (+ base 2))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Cast
              (+ base 4)
              (CompilerIrValue.Var (+ base 3))
              (AstType.I64)
              (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Cast
                (+ base 5)
                (CompilerIrValue.Var index-var)
                (AstType.I64)
                (AstType.U64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BoundsCheck
                  (CompilerIrValue.Var (+ base 5))
                  (CompilerIrValue.Var (+ base 4))
                  (compiler-ir-label "str_bounds_ok"))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Gep
                    (+ base 6)
                    (CompilerIrValue.Var (+ base 1))
                    (CompilerIrValue.Var index-var)
                    (AstType.Char))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Load
                      (+ base 7)
                      (CompilerIrValue.Var (+ base 6))
                      (AstType.Char))
                    tail))))))))))

(define (smoke-additive-entry [with-nonnegative : bool] [upper-offset : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "entry")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        3
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 1 (CompilerIrValue.Var 3) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              40
              (CompilerIrBinOp.Sub)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 upper-offset)
              (AstType.I64))
            (if with-nonnegative
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  42
                  (CompilerIrBinOp.Ge)
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.I64 0)
                  (AstType.Bool))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Branch
                    (CompilerIrValue.Var 42)
                    (compiler-ir-label "header")
                    (compiler-ir-label "exit"))
                  (CompilerIrInstrList.Nil)))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "header"))
                (CompilerIrInstrList.Nil)))))))))

(define (smoke-additive-header [op : CompilerIrBinOp] [upper-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "header")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        43
        op
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var upper-var)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 43)
          (compiler-ir-label "body")
          (compiler-ir-label "exit"))
        (CompilerIrInstrList.Nil)))))

(define (smoke-additive-body [offset : i64] [redefine-index : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (let
      [tail : CompilerIrInstrList
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            50
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 offset)
            (AstType.I64))
          (smoke-additive-ref-index-instrs
            2
            50
            60
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 67)))
              (CompilerIrInstrList.Nil))))]
      (if redefine-index
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 (- 0 1)) (AstType.I64))
          tail)
        tail))))

(define (smoke-additive-blocks
  [offset : i64]
  [upper-offset : i64]
  [with-nonnegative : bool]
  [op : CompilerIrBinOp]
  [upper-var : i64]
  [redefine-index : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (smoke-additive-entry with-nonnegative upper-offset)
    (compiler-ir-block-cons
      (smoke-additive-header op upper-var)
      (compiler-ir-block-cons
        (smoke-additive-body offset redefine-index)
        (compiler-ir-block-cons
          (opt-loop-bce-test-exit)
          (CompilerIrBlockList.Nil))))))

(define (smoke-additive-count
  [offset : i64]
  [upper-offset : i64]
  [with-nonnegative : bool]
  [op : CompilerIrBinOp]
  [upper-var : i64]
  [redefine-index : bool]) : i64
  (let
    [symbols : OptLoopBceTestSymbols (opt-loop-bce-test-symbols)]
    (opt-loop-bce-string-test-count
      (smoke-additive-blocks
        offset
        upper-offset
        with-nonnegative
        op
        upper-var
        redefine-index)
      (opt-loop-bce-test-summaries symbols false false))))

(define (smoke-additive-wrap-risk-entry) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "entry")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        1
        (opt-test-symbol "unknown_len")
        (CompilerIrCallArgs.Nil)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            40
            (CompilerIrBinOp.Sub)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              42
              (CompilerIrBinOp.Ge)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.I64 0)
              (AstType.Bool))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 42)
                (compiler-ir-label "header")
                (compiler-ir-label "exit"))
              (CompilerIrInstrList.Nil))))))))

(define (smoke-additive-wrap-risk-header) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "header")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        43
        (CompilerIrBinOp.Lt)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 40)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 43)
          (compiler-ir-label "body")
          (compiler-ir-label "exit"))
        (CompilerIrInstrList.Nil)))))

(define (smoke-additive-wrap-risk-body) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        50
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BoundsCheck
          (CompilerIrValue.Var 50)
          (CompilerIrValue.Var 1)
          (compiler-ir-label "bounds_ok"))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 50)))
          (CompilerIrInstrList.Nil))))))

(define (smoke-additive-wrap-risk-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (smoke-additive-wrap-risk-entry)
    (compiler-ir-block-cons
      (smoke-additive-wrap-risk-header)
      (compiler-ir-block-cons
        (smoke-additive-wrap-risk-body)
        (compiler-ir-block-cons
          (opt-loop-bce-test-exit)
          (CompilerIrBlockList.Nil))))))

(define (smoke-additive-bce-self-test) : i64
  (let
    [symbols : OptLoopBceTestSymbols (opt-loop-bce-test-symbols)]
    [plus1 : i64 (smoke-additive-count 1 1 true (CompilerIrBinOp.Lt) 40 false)]
    [plus3 : i64 (smoke-additive-count 3 3 true (CompilerIrBinOp.Lt) 40 false)]
    [missing-nonnegative : i64
      (smoke-additive-count 1 1 false (CompilerIrBinOp.Lt) 40 false)]
    [missing-slack : i64
      (smoke-additive-count 1 1 true (CompilerIrBinOp.Lt) 1 false)]
    [wrap-risk : i64
      (opt-loop-bce-test-count
        (smoke-additive-wrap-risk-blocks)
        (opt-loop-bce-test-summaries symbols false false))]
    [negative-offset : i64
      (smoke-additive-count (- 0 1) 0 true (CompilerIrBinOp.Lt) 1 false)]
    [redefined-index : i64
      (smoke-additive-count 1 1 true (CompilerIrBinOp.Lt) 40 true)]
    [off-by-one : i64
      (smoke-additive-count 1 1 true (CompilerIrBinOp.Le) 40 false)]
    (cond
      [(not (= plus1 0)) 1]
      [(not (= plus3 0)) 2]
      [(not (= missing-nonnegative 1)) 3]
      [(not (= missing-slack 1)) 4]
      [(not (= wrap-risk 1)) 5]
      [(not (= negative-offset 1)) 6]
      [(not (= redefined-index 1)) 7]
      [(not (= off-by-one 1)) 8]
      [else 42])))

(define (smoke-heavy-pass-large-label [index : i64]) : i64
  (compiler-ir-label (string.append "b" (string.int->string index))))

(define (smoke-heavy-pass-large-jump-block [index : i64] [next : i64]) : CompilerIrBlock
  (compiler-ir-block
    (smoke-heavy-pass-large-label index)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Jump next)
      (CompilerIrInstrList.Nil))))

(define (smoke-heavy-pass-large-exit-block) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "exit")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        3
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
        (CompilerIrInstrList.Nil)))))

(define (smoke-heavy-pass-large-tail-blocks [index : i64] [last : i64]) : CompilerIrBlockList
  (if (> index last)
    (compiler-ir-block-cons
      (smoke-heavy-pass-large-exit-block)
      (CompilerIrBlockList.Nil))
    (compiler-ir-block-cons
      (smoke-heavy-pass-large-jump-block
        index
        (if (= index last)
          (compiler-ir-label "exit")
          (smoke-heavy-pass-large-label (+ index 1))))
      (smoke-heavy-pass-large-tail-blocks (+ index 1) last))))

(define (smoke-heavy-pass-large-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (smoke-heavy-pass-large-label 1))
          (CompilerIrInstrList.Nil))))
    (smoke-heavy-pass-large-tail-blocks 1 1024)))

(define (smoke-heavy-pass-large-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "heavy_pass_large")
    (opt-gvn-test-params)
    (AstType.I64)
    4
    (smoke-heavy-pass-large-blocks)))

(define (smoke-heavy-pass-large-gvn-self-test) : i64
  (let
    [blocks : CompilerIrBlockList (smoke-heavy-pass-large-blocks)]
    [optimized : CompilerIrFunction
      (optimize-function-once
        (ast-node-pool-reader-context-current)
        (ast-node-pool-reader-type-segment-bases)
        (smoke-heavy-pass-large-function))]
    (begin
      (unless (> (compiler-ir-block-list-count blocks) 1024) (return 1))
      (unless
        (<= (compiler-ir-block-list-count blocks) (opt-heavy-pass-block-limit))
        (return 2))
      (match optimized
        [(CompilerIrFunction.Function _ _ _ _ optimized-blocks)
          (if (= (opt-gvn-count-binops-blocks optimized-blocks) 1)
            42
            3)]))))

(define (smoke-function-index-leaf-starts-self-test) : i64
  (let
    [qualified : String "module/path::tl_substring"]
    [plain : String "plain"]
    [index : OptFunctionIndex
      (opt-function-index-build
        (compiler-ir-function-cons
          (opt-test-function-named qualified (CompilerIrInstrList.Nil))
          (compiler-ir-function-cons
            (opt-test-function-named plain (CompilerIrInstrList.Nil))
            (CompilerIrFunctionList.Nil))))]
    [starts : (Array i64) (struct-get index leaf-starts)]
    (cond
      [(not (= (array-length starts) 2)) 1]
      [(not (= (array-ref starts 0) (opt-symbol-leaf-start qualified))) 2]
      [(not (= (array-ref starts 1) 0)) 3]
      [(not
          (opt-symbol-leaf-matches-from?
            qualified
            (array-ref starts 0)
            "tl_substring"))
        4]
      [(opt-symbol-leaf-matches-from?
          qualified
          (array-ref starts 0)
          "substring")
        5]
      [(not (opt-symbol-leaf-matches-from? plain (array-ref starts 1) "plain"))
        6]
      [else 42])))

(define (smoke-optimizer-named-failure-message-ok?) : bool
  (string.eq
    (compiler-optimize-self-test-failure-message "copy propagation" 7 42)
    "optimizer self-test failed: copy propagation (expected 42, got 7)"))

(define (smoke-optimizer-core-self-tests) : i64
  (begin
    (compiler-optimize-self-test-require!
      "named failure message renderer"
      (smoke-optimizer-named-failure-message-ok?))
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-self-test"
      (compiler-optimize-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-dense-storage-self-test"
      (compiler-optimize-dense-storage-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-typed-fold-self-test"
      (compiler-optimize-typed-fold-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "smoke-noop-int-cast-mov-self-test"
      (smoke-noop-int-cast-mov-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-strength-self-test"
      (compiler-optimize-strength-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-dce-self-test"
      (compiler-optimize-dce-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-dce-mem-self-test"
      (compiler-optimize-dce-mem-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-divrem-safety-self-test"
      (compiler-optimize-divrem-safety-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-const-divisor-self-test"
      (compiler-optimize-const-divisor-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-cse-self-test"
      (compiler-optimize-cse-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-copy-self-test"
      (compiler-optimize-copy-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-bounds-self-test"
      (compiler-optimize-bounds-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-bounds-dom-self-test"
      (compiler-optimize-bounds-dom-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "smoke-object-bounds-self-test"
      (smoke-object-bounds-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "smoke-range-bce-self-test"
      (smoke-range-bce-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "smoke-ssa-iv-bce-self-test"
      (smoke-ssa-iv-bce-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "smoke-nonlength-guard-bce-self-test"
      (smoke-nonlength-guard-bce-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "smoke-additive-bce-self-test"
      (smoke-additive-bce-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-sccp-self-test"
      (compiler-optimize-sccp-self-test)
      42)
    42))

(define (smoke-optimizer-loop-self-tests) : i64
  (begin
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-global-value-number-self-test"
      (compiler-optimize-global-value-number-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-cfg-self-test"
      (compiler-optimize-cfg-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-switch-form-self-test"
      (compiler-optimize-switch-form-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-natural-loop-self-test"
      (compiler-optimize-natural-loop-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-loop-rotation-self-test"
      (compiler-optimize-loop-rotation-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-rotate-ssa-self-test"
      (compiler-optimize-rotate-ssa-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-self-test"
      (compiler-optimize-licm-self-test)
      42)
    (cfg
      test
      (compiler-optimize-self-test-require-i64!
        "compiler-optimize-licm-checked-root-self-test"
        (compiler-optimize-licm-checked-root-self-test)
        42)
      unit)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-induction-self-test"
      (compiler-optimize-induction-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-lftr-self-test"
      (compiler-optimize-lftr-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-unroll-self-test"
      (compiler-optimize-unroll-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-unroll-mb-self-test"
      (compiler-optimize-unroll-mb-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-affine-self-test"
      (compiler-optimize-affine-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-affine-pipeline-self-test"
      (compiler-optimize-affine-pipeline-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-ssa-preexisting-phi-self-test"
      (compiler-optimize-ssa-preexisting-phi-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-multi-exit-self-test"
      (compiler-optimize-licm-multi-exit-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-self-test"
      (compiler-optimize-bce-version-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-pipeline-self-test"
      (compiler-optimize-bce-version-pipeline-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-ssa-self-test"
      (compiler-optimize-ssa-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-level-self-test"
      (compiler-optimize-level-self-test)
      42)
    42))

(define (smoke-inline-phi-header [latch-label : i64]) : CompilerIrInstr
  (CompilerIrInstr.Phi
    1
    (compiler-ir-phi-input-cons
      (CompilerIrValue.I64 0)
      (compiler-ir-label "entry")
      (compiler-ir-phi-input-cons
        (CompilerIrValue.Var 0)
        latch-label
        CompilerIrPhiInputList.Nil))
    (AstType.I64)))

(define (smoke-inline-phi-exit [latch-label : i64]) : CompilerIrInstr
  (CompilerIrInstr.Phi
    2
    (compiler-ir-phi-input-cons
      (CompilerIrValue.Var 1)
      (compiler-ir-label "header")
      (compiler-ir-phi-input-cons
        (CompilerIrValue.Var 0)
        latch-label
        CompilerIrPhiInputList.Nil))
    (AstType.I64)))

(define (smoke-inline-phi-caller-with-call
  [symbols : OptInlineMultiTestSymbols]
  [call : CompilerIrInstr]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "header"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "header")
          (compiler-ir-instr-cons
            (smoke-inline-phi-header (compiler-ir-label "latch"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Bool true)
                (compiler-ir-label "latch")
                (compiler-ir-label "exit"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "latch")
            (compiler-ir-instr-cons
              call
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Bool true)
                  (compiler-ir-label "header")
                  (compiler-ir-label "exit"))
                CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "exit")
              (compiler-ir-instr-cons
                (smoke-inline-phi-exit (compiler-ir-label "latch"))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
                  CompilerIrInstrList.Nil)))
            CompilerIrBlockList.Nil))))))

(define (smoke-inline-phi-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "a" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "b" (AstType.I64) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "c" (AstType.I64) 2)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "d" (AstType.I64) 3)
          CompilerIrParamList.Nil)))))

(define (smoke-inline-phi-callee-mov) : CompilerIrInstr
  (CompilerIrInstr.Mov 4 (CompilerIrValue.I64 7) (AstType.I64)))

(define (smoke-inline-phi-callee [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-branch)
    (smoke-inline-phi-params)
    (AstType.I64)
    5
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (smoke-inline-phi-callee-mov)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "exit"))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

(define (smoke-inline-phi-call [symbols : OptInlineMultiTestSymbols]) : CompilerIrInstr
  (let
    [values : (Array CompilerIrValue) (array.make-array CompilerIrValue 4)]
    (begin
      (array-set! values 0 (CompilerIrValue.I64 1))
      (array-set! values 1 (CompilerIrValue.I64 2))
      (array-set! values 2 (CompilerIrValue.I64 3))
      (array-set! values 3 (CompilerIrValue.I64 4))
      (CompilerIrInstr.Call
        0
        (struct-get symbols inline-branch)
        (CompilerIrCallArgs.Array values)
        (AstType.I64)))))

(define (smoke-inline-phi-caller [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (smoke-inline-phi-caller-with-call symbols (smoke-inline-phi-call symbols)))

(define (smoke-inline-phi-functions [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (smoke-inline-phi-caller symbols)
    (compiler-ir-function-cons
      (smoke-inline-phi-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (smoke-inline-phi-loop-repaired? [blocks : CompilerIrBlockList]) : bool
  (match (opt-cfg-find-block blocks (compiler-ir-label "header"))
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some header)
      (match header
        [(CompilerIrBlock.Block _ instrs)
          (match (compiler-ir-instr-seq-ref instrs 0)
            [(CompilerIrInstr.Phi _ inputs _)
              (if (opt-phi-input-list-eq
                inputs
                (match (smoke-inline-phi-header
                  (compiler-ir-label "inl.latch.0.cont"))
                  [(CompilerIrInstr.Phi _ expected _) expected]
                  [_ CompilerIrPhiInputList.Nil]))
                (match (opt-cfg-find-block blocks (compiler-ir-label "exit"))
                  [(OptMaybeBlock.No) false]
                  [(OptMaybeBlock.Some exit)
                    (match exit
                      [(CompilerIrBlock.Block _ exit-instrs)
                        (match (compiler-ir-instr-seq-ref exit-instrs 0)
                          [(CompilerIrInstr.Phi _ exit-inputs _)
                            (opt-phi-input-list-eq
                              exit-inputs
                              (match (smoke-inline-phi-exit
                                (compiler-ir-label "inl.latch.0.cont"))
                                [(CompilerIrInstr.Phi _ expected _) expected]
                                [_ CompilerIrPhiInputList.Nil]))]
                          [_ false])])])
                false)]
            [_ false])])]))

(define (smoke-inline-phi-positive-code) : i64
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (ast-node-pool-reader-type-segment-bases)
        (smoke-inline-phi-functions symbols)
        2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (cond
            [(not
                (= (opt-count-direct-call-name-blocks blocks "inline_branch") 0))
              11]
            [(not (= (compiler-ir-block-list-count blocks) 7))
              (+ 20 (compiler-ir-block-list-count blocks))]
            [(not (= (opt-count-phi-blocks blocks) 2))
              (+ 40 (opt-count-phi-blocks blocks))]
            [(not (smoke-inline-phi-loop-repaired? blocks)) 61]
            [(not (opt-inline-structure-ok? blocks)) 62]
            [else 42]))]
      [(OptMaybeFunction.No) 10])))

(define (smoke-inline-phi-spans?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [call : CompilerIrInstr (smoke-inline-phi-call symbols)]
    [header-phi : CompilerIrInstr
      (smoke-inline-phi-header (compiler-ir-label "latch"))]
    [exit-phi : CompilerIrInstr
      (smoke-inline-phi-exit (compiler-ir-label "latch"))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert-instr
          (compiler-source-spans-insert-instr
            (opt-spans-base)
            (opt-test-symbol "main")
            call
            (opt-test-span 161 31))
          (opt-test-symbol "main")
          header-phi
          (opt-test-span 162 33))
        (opt-test-symbol "main")
        exit-phi
        (opt-test-span 163 35))]
    [result-mov : CompilerIrInstr
      (CompilerIrInstr.Mov 0 (CompilerIrValue.Var 3) (AstType.I64))]
    [repaired-header : CompilerIrInstr
      (smoke-inline-phi-header (compiler-ir-label "inl.latch.0.cont"))]
    [repaired-exit : CompilerIrInstr
      (smoke-inline-phi-exit (compiler-ir-label "inl.latch.0.cont"))]
    (match (opt-inline-program-functions-with-spans
      (ast-node-pool-reader-type-segment-bases)
      (smoke-inline-phi-functions symbols)
      2
      spans)
      [(OptInlineSpanProgram.Program optimized optimized-spans)
        (match (opt-function-list-find optimized "main")
          [(OptMaybeFunction.Some main)
            (let
              [blocks : CompilerIrBlockList (opt-function-blocks main)]
              (and
                (= (opt-count-direct-call-name-blocks blocks "inline_branch") 0)
                (smoke-inline-phi-loop-repaired? blocks)
                (opt-inline-structure-ok? blocks)
                (opt-span-lookup-ok?
                  optimized-spans
                  (opt-test-symbol "main")
                  result-mov
                  161
                  31)
                (opt-span-lookup-ok?
                  optimized-spans
                  (opt-test-symbol "main")
                  repaired-header
                  162
                  33)
                (opt-span-lookup-ok?
                  optimized-spans
                  (opt-test-symbol "main")
                  repaired-exit
                  163
                  35)))]
          [(OptMaybeFunction.No) false])])))

(define (smoke-inline-phi-refusal?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [caller : CompilerIrFunction (smoke-inline-phi-caller symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (ast-node-pool-reader-type-segment-bases)
        (compiler-ir-function-cons caller CompilerIrFunctionList.Nil)
        2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (opt-function-eq (ast-node-pool-reader-type-segment-bases) main caller)]
      [(OptMaybeFunction.No) false])))

(define (smoke-inline-phi-nonleaf-cost?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [caller : CompilerIrFunction
      (smoke-inline-phi-caller-with-call
        symbols
        (CompilerIrInstr.Call
          0
          (struct-get symbols inline-nonleaf)
          CompilerIrCallArgs.Nil
          (AstType.I64)))]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (ast-node-pool-reader-type-segment-bases)
        (compiler-ir-function-cons
          caller
          (compiler-ir-function-cons
            (opt-inline-nonleaf-callee symbols)
            CompilerIrFunctionList.Nil))
        2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (opt-function-eq (ast-node-pool-reader-type-segment-bases) main caller)]
      [(OptMaybeFunction.No) false])))

(define (smoke-inline-phi-predecessor-self-test) : i64
  (let
    [positive : i64 (smoke-inline-phi-positive-code)]
    (cond
      [(not (= positive 42)) positive]
      [(not (smoke-inline-phi-spans?)) 2]
      [(not (smoke-inline-phi-refusal?)) 3]
      [(not (smoke-inline-phi-nonleaf-cost?)) 4]
      [else 42])))

;; Cycle 27: keep if-conversion admission and masked-zero compare folding at
;; the target-neutral IR boundary.  These fixtures intentionally exercise the
;; positive existing-value diamond and the two most important refusal rules
;; (arm-local computation and a multiply-used And result).
(define (smoke-c27-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "x" (AstType.I64) 1)
      (CompilerIrParamList.Nil))))

(define (smoke-c27-if-convert-function [computed-arm? : bool]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "c27_if_convert")
    (smoke-c27-params)
    (AstType.I64)
    8
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "header"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "header")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              2
              (compiler-ir-phi-input-cons
                (CompilerIrValue.I64 0)
                (compiler-ir-label "entry")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 6)
                  (compiler-ir-label "merge")
                  (CompilerIrPhiInputList.Nil)))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                5
                CompilerIrBinOp.Gt
                (CompilerIrValue.Var 1)
                (CompilerIrValue.I64 0)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 5)
                  (compiler-ir-label "then")
                  (compiler-ir-label "else"))
                (CompilerIrInstrList.Nil)))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "then")
            (if computed-arm?
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  3
                  CompilerIrBinOp.Add
                  (CompilerIrValue.Var 1)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Jump (compiler-ir-label "merge"))
                  (CompilerIrInstrList.Nil)))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "merge"))
                (CompilerIrInstrList.Nil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "else")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "merge"))
                (CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "merge")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Phi
                    4
                    (compiler-ir-phi-input-cons
                      (if computed-arm?
                        (CompilerIrValue.Var 3)
                        (CompilerIrValue.Var 1))
                      (compiler-ir-label "then")
                      (compiler-ir-phi-input-cons
                        (CompilerIrValue.Var 1)
                        (compiler-ir-label "else")
                        (CompilerIrPhiInputList.Nil)))
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      6
                      CompilerIrBinOp.Add
                      (CompilerIrValue.Var 2)
                      (CompilerIrValue.I64 1)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.BinOp
                        7
                        CompilerIrBinOp.Lt
                        (CompilerIrValue.Var 6)
                        (CompilerIrValue.I64 2)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Branch
                          (CompilerIrValue.Var 7)
                          (compiler-ir-label "header")
                          (compiler-ir-label "exit"))
                        (CompilerIrInstrList.Nil))))))
              (compiler-ir-block-cons
                (compiler-ir-block
                  (compiler-ir-label "exit")
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                    (CompilerIrInstrList.Nil)))
                (CompilerIrBlockList.Nil)))))))))

(define (smoke-c27-count-scalar-selects-instrs
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    0
    (+
      (match (compiler-ir-instr-seq-ref instrs index)
        [(CompilerIrInstr.Select payload-box)
          (let
            [lanes (struct-get (box-get payload-box) lanes)]
            (if (= lanes 0)
              1
              0))]
        [_ 0])
      (smoke-c27-count-scalar-selects-instrs instrs (+ index 1)))))

(define (smoke-c27-count-scalar-selects [blocks : CompilerIrBlockList]) : i64
  (match (compiler-ir-block-list-force-cons blocks)
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Array seq)
      (smoke-c27-count-scalar-selects (compiler-ir-block-seq-to-list seq))]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (smoke-c27-count-scalar-selects-instrs instrs 0)
            (smoke-c27-count-scalar-selects (box-get rest)))])]))

(define (smoke-c27-count-binop-instrs
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [wanted : CompilerIrBinOp]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    0
    (+
      (match (compiler-ir-instr-seq-ref instrs index)
        [(CompilerIrInstr.BinOp _ op _ _ _)
          (if (= (opt-binop-tag op) (opt-binop-tag wanted))
            1
            0)]
        [_ 0])
      (smoke-c27-count-binop-instrs instrs (+ index 1) wanted))))

(define (smoke-c27-count-binop
  [blocks : CompilerIrBlockList]
  [wanted : CompilerIrBinOp]) : i64
  (match (compiler-ir-block-list-force-cons blocks)
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Array seq)
      (smoke-c27-count-binop (compiler-ir-block-seq-to-list seq) wanted)]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (smoke-c27-count-binop-instrs instrs 0 wanted)
            (smoke-c27-count-binop (box-get rest) wanted))])]))

(define (smoke-c27-compare-function [extra-use? : bool]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "c27_bit_test")
    (compiler-ir-param-cons
      (CompilerIrParam.Param "x" (AstType.I64) 0)
      (CompilerIrParamList.Nil))
    (AstType.I64)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            1
            CompilerIrBinOp.BitAnd
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              2
              CompilerIrBinOp.Gt
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 0)
              (AstType.I64))
            (if extra-use?
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  3
                  CompilerIrBinOp.Add
                  (CompilerIrValue.Var 1)
                  (CompilerIrValue.Var 2)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                  (CompilerIrInstrList.Nil)))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
                (CompilerIrInstrList.Nil))))))
      (CompilerIrBlockList.Nil))))

(define (smoke-c27-if-convert-compare-self-test) : i64
  (let
    [converted : CompilerIrFunction
      (opt-if-convert-function
        (ast-node-pool-reader-type-segment-bases)
        (smoke-c27-if-convert-function false))]
    [conditional : CompilerIrFunction
      (opt-if-convert-function
        (ast-node-pool-reader-type-segment-bases)
        (smoke-c27-if-convert-function true))]
    [single-use : CompilerIrFunction
      (match (smoke-c27-compare-function false)
        [(CompilerIrFunction.Function name params ret frame blocks)
          (CompilerIrFunction.Function
            name
            params
            ret
            frame
            (opt-dce-block-list-array
              (opt-collect-blocks-uses-array frame blocks)
              blocks))])]
    [multi-use : CompilerIrFunction
      (match (smoke-c27-compare-function true)
        [(CompilerIrFunction.Function name params ret frame blocks)
          (CompilerIrFunction.Function
            name
            params
            ret
            frame
            (opt-dce-block-list-array
              (opt-collect-blocks-uses-array frame blocks)
              blocks))])]
    [converted-blocks : CompilerIrBlockList (opt-function-blocks converted)]
    [conditional-blocks : CompilerIrBlockList (opt-function-blocks conditional)]
    [single-blocks : CompilerIrBlockList (opt-function-blocks single-use)]
    [multi-blocks : CompilerIrBlockList (opt-function-blocks multi-use)]
    (cond
      [(not (= (smoke-c27-count-scalar-selects converted-blocks) 1)) 1]
      [(not (= (compiler-ir-block-list-count converted-blocks) 4)) 2]
      [(not (= (smoke-c27-count-scalar-selects conditional-blocks) 0)) 3]
      [(not
          (= (smoke-c27-count-binop single-blocks CompilerIrBinOp.BitTestNe) 1))
        4]
      [(not
          (= (smoke-c27-count-binop multi-blocks CompilerIrBinOp.BitTestNe) 0))
        5]
      [(not (= (smoke-c27-count-binop multi-blocks CompilerIrBinOp.Gt) 1)) 6]
      [else 42])))

(define (smoke-optimizer-late-self-tests) : i64
  (begin
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-callgraph-self-test"
      (compiler-optimize-callgraph-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-scc-self-test"
      (compiler-optimize-scc-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-inline-self-test"
      (compiler-optimize-inline-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "smoke-inline-phi-predecessor-self-test"
      (smoke-inline-phi-predecessor-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-fixed-point-self-test"
      (compiler-optimize-fixed-point-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-tailrec-self-test"
      (compiler-optimize-tailrec-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-global-dce-self-test"
      (compiler-optimize-global-dce-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-aggregate-candidate-self-test"
      (compiler-optimize-aggregate-candidate-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-aggregate-promote-self-test"
      (compiler-optimize-aggregate-promote-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-aggregate-sroa-self-test"
      (compiler-optimize-aggregate-sroa-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-spans-self-test"
      (compiler-optimize-spans-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-gvn-self-test"
      (compiler-optimize-gvn-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "smoke-heavy-pass-large-gvn-self-test"
      (smoke-heavy-pass-large-gvn-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-load-cse-self-test"
      (compiler-optimize-load-cse-self-test)
      44)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-dead-store-self-test"
      (compiler-optimize-dead-store-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-scratch-region-self-test"
      (compiler-optimize-scratch-region-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "smoke-function-index-leaf-starts-self-test"
      (smoke-function-index-leaf-starts-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-self-test"
      (compiler-optimize-bce-version-mb-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-switch-self-test"
      (compiler-optimize-bce-version-mb-switch-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-negative-self-test"
      (compiler-optimize-bce-version-mb-negative-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-pipeline-self-test"
      (compiler-optimize-bce-version-mb-pipeline-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-partial-self-test"
      (compiler-optimize-bce-version-mb-partial-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-paired-self-test"
      (compiler-optimize-bce-version-mb-paired-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-debug-verifier-self-test"
      (compiler-optimize-debug-verifier-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-gep-split-self-test"
      (compiler-optimize-gep-split-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-dce-pack-self-test"
      (compiler-optimize-dce-pack-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-cmp-sink-self-test"
      (compiler-optimize-cmp-sink-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-successor-sink-self-test"
      (compiler-optimize-successor-sink-self-test)
      42)
    (compiler-optimize-self-test-require-i64!
      "smoke-c27-if-convert-compare-self-test"
      (smoke-c27-if-convert-compare-self-test)
      42)
    42))

(define (main) : i64
  (begin
    (compiler-optimize-self-test-require-i64!
      "compiler-optimize-runtime-call-identity-self-test"
      (compiler-optimize-runtime-call-identity-self-test)
      42)
    (smoke-optimizer-core-self-tests)
    (smoke-optimizer-loop-self-tests)
    (smoke-optimizer-late-self-tests)
    42))

(test
  load-cse-copybytes-forwarding
  (test.assert-i64-eq
    (compiler-optimize-load-cse-self-test)
    44
    "load-cse copybytes forwarding"))

(test
  optimizer-alias-fact-model
  (test.assert-i64-eq
    (compiler-optimize-alias-self-test)
    42
    "optimizer alias fact model"))

(test
  inline-multiblock-switch-absorbable
  (test.assert-true
    (compiler-optimize-inline-multiblock-switch-ok?)
    "absorbable acyclic bounds+switch callee inlines with fresh CFG/phi labels"))

(test
  inline-multiblock-cyclic-bounds-switch-refusal
  (test.assert-true
    (compiler-optimize-inline-multiblock-cyclic-bounds-switch-refusal-ok?)
    "cyclic bounds+switch callee remains behind the acyclic admission gate"))

(test
  inline-vm-run-bounds-loop-exception
  (test.assert-true
    (compiler-optimize-inline-vm-run-bounds-loop-ok?)
    "only exact vm-run bounds loop inlines at opt2; qs-partition and opt1 stay refused"))

(test
  inline-vm-run-bounds-loop-span-positive
  (test.assert-i64-eq
    (opt-inline-switch-span-case-code "bench.tl::vm-run" true)
    15
    "span-aware inliner admits exact vm-run and preserves cloned spans"))

(test
  inline-vm-run-bounds-loop-span-negative
  (test.assert-i64-eq
    (opt-inline-switch-span-case-code "bench.tl::qs-partition" false)
    15
    "span-aware inliner refuses the similarly shaped qs-partition loop"))

(test
  inline-multiblock-switch-cost-refusal
  (test.assert-true
    (compiler-optimize-inline-multiblock-switch-cost-refusal-ok?)
    "multi-site switch callee above the weighted cost threshold stays uninlined"))

(cfg
  test
  (test
    licm-checked-root-disjointness
    (test.assert-i64-eq
      (compiler-optimize-licm-checked-root-self-test)
      42
      "LICM checked-reference root disjointness")))

(test
  dead-store-overwrite
  (test.assert-i64-eq
    (compiler-optimize-dead-store-self-test)
    42
    "dead-store overwrite"))

(test
  bce-version-multiblock-quicksort-shape
  (test.assert-i64-eq
    (compiler-optimize-bce-version-mb-self-test)
    42
    "multi-block counted-loop bounds-check versioning"))

(test
  bce-version-multiblock-switch-cloning
  (test.assert-i64-eq
    (compiler-optimize-bce-version-mb-switch-self-test)
    42
    "multi-block versioning remaps total-switch case and trap edges"))

(test
  bce-version-multiblock-rejections
  (test.assert-i64-eq
    (compiler-optimize-bce-version-mb-negative-self-test)
    42
    "multi-block versioning rejections"))

(test
  bce-version-multiblock-pipeline
  (test.assert-i64-eq
    (compiler-optimize-bce-version-mb-pipeline-self-test)
    42
    "multi-block versioning full pipeline"))

(test
  unroll-store-free-simd-body
  (test.assert-i64-eq
    (compiler-optimize-unroll-self-test)
    42
    "16x unrolling remaps every admitted store-free SIMD instruction"))

(test
  unroll-versioned-multiblock-quicksort-shape
  (test.assert-i64-eq
    (compiler-optimize-unroll-mb-self-test)
    42
    "2x unrolling of the check-free versioned conditional diamond"))

(test
  bce-version-multiblock-partial
  (test.assert-i64-eq
    (compiler-optimize-bce-version-mb-partial-self-test)
    42
    "multi-block versioning keeps underivable checks in the fast clone"))

(test
  bce-version-multiblock-paired-checks
  (test.assert-i64-eq
    (compiler-optimize-bce-version-mb-paired-self-test)
    42
    "late in-place pairing combines adjacent affine bounds checks"))

(test
  optimizer-debug-verifier-identity
  (test.assert-i64-eq
    (compiler-optimize-debug-verifier-self-test)
    42
    "IR verifier failures include function, block, and instruction identity"))

(test
  gep-use-splitting
  (test.assert-i64-eq
    (compiler-optimize-gep-split-self-test)
    42
    "Gep use-splitting clones multi-use address Geps per memory use"))

(test
  dce-pack-retirement
  (test.assert-i64-eq
    (compiler-optimize-dce-pack-self-test)
    42
    "Pipeline DCE retires a Pack whose extractions all folded"))

(test
  cmp-sink-to-branch
  (test.assert-i64-eq
    (compiler-optimize-cmp-sink-self-test)
    42
    "Sinking a loop-closing compare next to its branch"))

(test
  single-predecessor-successor-sink
  (test.assert-i64-eq
    (compiler-optimize-successor-sink-self-test)
    42
    "Successor sinking moves pure chains and rejects unsafe CFG/memory/trap cases"))

(test
  if-convert-and-compare-lowering
  (test.assert-i64-eq
    (smoke-c27-if-convert-compare-self-test)
    42
    "IR-only scalar if-conversion and single-use masked-zero lowering"))

(test
  inline-multiblock-phi-predecessor
  (test.assert-i64-eq
    (smoke-inline-phi-predecessor-self-test)
    42
    "multiblock inline repairs loop phi predecessors and source spans"))

(test
  cfg-index-block-lookup
  (test.assert-i64-eq
    (smoke-cfg-index-block-lookup-self-test)
    42
    "CFG block lookup is dense, first-match, missing-safe, and stale-index-safe"))