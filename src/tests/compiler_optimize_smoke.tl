;; compiler_optimize_smoke.tl - Inline tests for compiler_optimize.tl: the
;; `(test ...)` forms that run the self-tests of compiler_optimize_tests.tl, and
;; smoke-local fixtures (constant folding, dead-code elimination, common
;; subexpression elimination, copy propagation, strength reduction, typed
;; constant/cast folding, CFG simplification, bounds-check elimination,
;; CFG/dominance/SSA verification, opt-level policy, fixed-point iteration,
;; self-tail-recursion lowering, sparse conditional constant propagation,
;; aggregate stack promotion, global value numbering, loop-invariant code
;; motion, induction variables, scratch regions and the call graph).
(import stdlib.str_cat_runtime as str_cat)
(import compiler_optimize_tests as ot)
(import compiler_optimize as opt)
(import compiler_ir_types as ir)
(import compiler_ir_text as irt)
(import compiler_ast_types as ast)
(import compiler_owned_view as owned_view)
(import compiler_builtin_ids as cbi)
(import stdlib.string)
(import stdlib.test)

(define (smoke-cfg-index-test-block [label : i64] [value : i64]) : ir.CompilerIrBlock
  (Block
    label
    (ot.opt-test-instrs (ir.CompilerIrInstr.Return (Some (I64 value))))))

(define (smoke-cfg-index-block-return [block : opt.OptMaybeBlock]) : i64
  (match block
    [(No) (- 0 1)]
    [(Some found)
      (match found
        [(Block _ instrs)
          (if (= (ir.compiler-ir-instr-seq-count instrs) 1)
            (match (ir.compiler-ir-instr-seq-ref instrs 0)
              [(Return (Some (I64 value))) value]
              [_ (- 0 1)])
            (- 0 1))])]))

;; Indexed lookup must keep the old list scan's first-match and missing-label
;; semantics even for a malformed duplicate-label CFG. Building another index
;; deliberately makes the first index's generation stale, exercising its
;; label-array fallback as well as the active generation-table path.
(define (smoke-cfg-index-block-lookup-self-test) : i64
  (let
    [label : i64 (ir.compiler-ir-label "cfg_index_duplicate")]
    [other-label : i64 (ir.compiler-ir-label "cfg_index_other")]
    [missing-label : i64 (ir.compiler-ir-label "cfg_index_missing")]
    [blocks : ir.CompilerIrBlockList
      (ir.compiler-ir-blocks
        (smoke-cfg-index-test-block label 11)
        (smoke-cfg-index-test-block label 22))]
    [index : opt.OptCfgIndex (opt.opt-cfg-index-build blocks)]
    [active-first : i64
      (smoke-cfg-index-block-return (opt.opt-cfg-index-find-block index label))]
    [replacement-blocks : ir.CompilerIrBlockList
      (ir.compiler-ir-blocks
        (smoke-cfg-index-test-block label 44)
        (smoke-cfg-index-test-block label 55))]
    [_refresh : unit
      (opt.opt-cfg-index-refresh-blocks! index replacement-blocks)]
    [dense-second : i64
      (smoke-cfg-index-block-return (opt.opt-cfg-index-block index 1))]
    [_newer-index : opt.OptCfgIndex
      (opt.opt-cfg-index-build
        (ir.compiler-ir-blocks (smoke-cfg-index-test-block other-label 33)))]
    [stale-first : i64
      (smoke-cfg-index-block-return (opt.opt-cfg-index-find-block index label))]
    [missing : i64
      (smoke-cfg-index-block-return
        (opt.opt-cfg-index-find-block index missing-label))]
    (cond
      [(not (= active-first 11)) 1]
      [(not (= dense-second 55)) 2]
      [(not (= stale-first 44)) 3]
      [(not (= missing (- 0 1))) 4]
      [else 42])))

(define (opt-count-switch-instr-seq-from
  [instrs : (& instrs ir.CompilerIrInstrSeq)]
  [index : i64]
  [acc : i64]) : i64
  (if (>= index (ir.compiler-ir-instr-seq-count instrs))
    acc
    (opt-count-switch-instr-seq-from
      instrs
      (+ index 1)
      (+
        acc
        (match (ir.compiler-ir-instr-seq-ref instrs index)
          [(Switch _ _ _ _) 1]
          [(TotalEnumSwitch _ _ _ _ _) 1]
          [_ 0])))))

(define (opt-count-switch-instr-seq [instrs : ir.CompilerIrInstrSeq]) : i64
  (opt-count-switch-instr-seq-from instrs 0 0))

(define (opt-count-switch-blocks
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+ (opt-count-switch-instr-seq instrs) (opt-count-switch-blocks rest))])]))

(define (opt-switch-case-seq-count [cases : ir.CompilerIrSwitchCaseSeq]) : i64
  cases.len)

(define (opt-switch-entry-base [blocks : (& blocks ir.CompilerIrBlockList)]) : i64
  (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "entry"))
    [(No) (- 0 1)]
    [(Some block)
      (match block
        [(Block _ instrs)
          (if (= (ir.compiler-ir-instr-seq-count instrs) 1)
            (match (ir.compiler-ir-instr-seq-ref instrs 0)
              [(Switch _ base _ _) base]
              [(TotalEnumSwitch _ base _ _ _) base]
              [_ (- 0 1)])
            (- 0 1))])]))

(define (opt-switch-entry-case-count
  [blocks : (& blocks ir.CompilerIrBlockList)]) : i64
  (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "entry"))
    [(No) 0]
    [(Some block)
      (match block
        [(Block _ instrs)
          (if (= (ir.compiler-ir-instr-seq-count instrs) 1)
            (match (ir.compiler-ir-instr-seq-ref instrs 0)
              [(Switch _ _ cases _) (opt-switch-case-seq-count cases)]
              [(TotalEnumSwitch _ _ cases _ _)
                (opt-switch-case-seq-count cases)]
              [_ 0])
            0)])]))

(define (opt-switch-entry-default-label
  [blocks : (& blocks ir.CompilerIrBlockList)]) : i64
  (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "entry"))
    [(No) (ir.compiler-ir-label-none)]
    [(Some block)
      (match block
        [(Block _ instrs)
          (if (= (ir.compiler-ir-instr-seq-count instrs) 1)
            (match (ir.compiler-ir-instr-seq-ref instrs 0)
              [(Switch _ _ _ default-label) default-label]
              [(TotalEnumSwitch _ _ _ default-label _) default-label]
              [_ (ir.compiler-ir-label-none)])
            (ir.compiler-ir-label-none))])]))

(define (opt-switch-test-params) : ir.CompilerIrParamSeq
  (irt.params "tag=%0:i64"))

(define (opt-switch-test-function [blocks : ir.CompilerIrBlockList]) : ir.CompilerIrFunction
  (Function
    (ot.opt-test-symbol "switch_form")
    (opt-switch-test-params)
    (I64)
    16
    blocks
    Ordinary))

(define (opt-switch-test-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (Block
    label
    (ot.opt-test-instrs
      (ir.CompilerIrInstr.BinOp eq-var Eq (Var 0) (I64 tag) (I64))
      (ir.CompilerIrInstr.Branch (Var eq-var) arm-label next-label))))

(define (opt-switch-test-extra-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (Block
    label
    (ot.opt-test-instrs
      (ir.CompilerIrInstr.BinOp eq-var Eq (Var 0) (I64 tag) (I64))
      (ir.CompilerIrInstr.Mov 9 (I64 99) (I64))
      (ir.CompilerIrInstr.Branch (Var eq-var) arm-label next-label))))

(define (opt-switch-test-total-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (Block
    label
    (ot.opt-test-instrs
      (ir.CompilerIrInstr.BinOp eq-var Eq (Var 0) (I64 tag) (I64))
      (ir.CompilerIrInstr.TotalEnumBranch (Var eq-var) arm-label next-label))))

(define (opt-switch-test-return-block [label : i64] [value : i64]) : ir.CompilerIrBlock
  (Block
    label
    (ot.opt-test-instrs (ir.CompilerIrInstr.Return (Some (I64 value))))))

;; Head block whose compare+branch trails an unconditional prefix instruction:
;; the chain pass must keep the prefix ahead of the emitted Switch.
(define (opt-switch-test-prefix-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (Block
    label
    (ot.opt-test-instrs
      (ir.CompilerIrInstr.Mov 9 (Var 0) (I64))
      (ir.CompilerIrInstr.BinOp eq-var Eq (Var 0) (I64 tag) (I64))
      (ir.CompilerIrInstr.Branch (Var eq-var) arm-label next-label))))

(define (opt-switch-test-block-tail-base [block : (& block ir.CompilerIrBlock)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view block)
    [(Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1))
        [(Switch _ base _ _) base]
        [(TotalEnumSwitch _ base _ _ _) base]
        [_ (- 0 1)])]))

(define (opt-switch-test-block-tail-case-count
  [block : (& block ir.CompilerIrBlock)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view block)
    [(Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1))
        [(Switch _ _ cases _) (opt-switch-case-seq-count cases)]
        [(TotalEnumSwitch _ _ cases _ _) (opt-switch-case-seq-count cases)]
        [_ 0])]))

(define (opt-switch-test-block-tail-default
  [block : (& block ir.CompilerIrBlock)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view block)
    [(Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1))
        [(Switch _ _ _ default-label) default-label]
        [(TotalEnumSwitch _ _ _ default-label _) default-label]
        [_ (ir.compiler-ir-label-none)])]))

(define (opt-switch-test-block-tail-total?
  [block : (& block ir.CompilerIrBlock)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view block)
    [(Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1))
        [(TotalEnumSwitch _ _ _ _ _) true]
        [_ false])]))

(define (opt-switch-test-block-starts-with-mov? [block : ir.CompilerIrBlock]) : bool
  (match block
    [(Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref instrs 0)
        [(Mov _ _ _) true]
        [_ false])]))

(define (opt-switch-test-cases-have?
  [cases : ir.CompilerIrSwitchCaseSeq]
  [want-tag : i64]
  [want-label : i64]) : bool
  (let
    [index : i64 0]
    (while (< index cases.len)
      (match (ir.compiler-ir-switch-case-seq-ref cases index)
        [(Case tag label) (when (= tag want-tag) (return (= label want-label)))])
      (set! index (+ index 1)))
    false))

(define (opt-switch-test-block-tail-has-case?
  [block : (& block ir.CompilerIrBlock)]
  [tag : i64]
  [label : i64]) : bool
  (match (owned_view.compiler-owned-reference-shared-view block)
    [(Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1))
        [(Switch _ _ cases _) (opt-switch-test-cases-have? cases tag label)]
        [(TotalEnumSwitch _ _ cases _ _)
          (opt-switch-test-cases-have? cases tag label)]
        [_ false])]))

(define (opt-switch-test-total-trap-ok?
  [blocks : ir.CompilerIrBlockList]
  [label : i64]) : bool
  (match (opt.opt-cfg-find-block blocks label)
    [(No) false]
    [(Some block)
      (match block
        [(Block _ instrs)
          (and
            (= (ir.compiler-ir-instr-seq-count instrs) 2)
            (match (ir.compiler-ir-instr-seq-ref instrs 0)
              [(Call _ name _ _) (= name cbi.compiler-builtin-id-tl-oob-abort)]
              [_ false])
            (match (ir.compiler-ir-instr-seq-ref instrs 1)
              [(Jump target) (= target label)]
              [_ false]))])]))

;; Chain block labels: compare `i` lives in "entry" (i = 0) or "cmp<i>", and
;; its accepting arm in "case<i>". Used by the tag-list chain builder below,
;; which the density-tier and chain-shape cases need at lengths the fixed
;; four-tag builders cannot express.
(define (opt-switch-test-chain-label [i : i64]) : i64
  (if (= i 0)
    (ir.compiler-ir-label "entry")
    (ir.compiler-ir-label (& (str_cat.str-cat "cmp" (string.int->string i) "")))))

(define (opt-switch-test-arm-label [i : i64]) : i64
  (ir.compiler-ir-label (& (str_cat.str-cat "case" (string.int->string i) ""))))

(define (opt-switch-test-tag-array [count : i64] [first : i64] [last : i64]) : (__tl_dyn-array
    i64)
  ;; `first`, then 1-apart tags, then `last`: exactly `count` tags whose span is
  ;; whatever `last` makes it, so a case can name a span directly.
  (let
    [tags : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [i : i64 0]
    (while (< i count)
      (set!
        (array-ref tags i)
        (if (= i (- count 1))
          last
          (+ first i)))
      (set! i (+ i 1)))
    tags))

;; `tags[0..count)` as a compare chain over var 0, appended to `tail`. Chain
;; position `start + k` carries tag `tags[k]`, branches to its own returning
;; arm or on to position `start + k + 1`, and the last false edge leaves for
;; `next-label`; `start` lets one chain be built in two calls with a block of
;; the caller's choosing wedged between them.
(define (opt-switch-test-tag-chain-from
  [tags : (__tl_dyn-array i64)]
  [start : i64]
  [k : i64]
  [count : i64]
  [next-label : i64]
  [tail : ir.CompilerIrBlockList]) : ir.CompilerIrBlockList
  (if (>= k count)
    tail
    (ir.compiler-ir-blocks-with-tail
      (opt-switch-test-tag-chain-from tags start (+ k 1) count next-label tail)
      (opt-switch-test-compare-block
        (opt-switch-test-chain-label (+ start k))
        (array-ref tags k)
        (+ (+ start k) 1)
        (opt-switch-test-arm-label (+ start k))
        (if (= (+ k 1) count)
          next-label
          (opt-switch-test-chain-label (+ (+ start k) 1))))
      (opt-switch-test-return-block
        (opt-switch-test-arm-label (+ start k))
        (+ 10 (+ start k))))))

;; A whole function body: `count` compares over the given span, then a
;; returning fallback.
(define (opt-switch-test-span-blocks [count : i64] [first : i64] [last : i64]) : ir.CompilerIrBlockList
  (opt-switch-test-tag-chain-from
    (opt-switch-test-tag-array count first last)
    0
    0
    count
    (ir.compiler-ir-label "fallback")
    (ir.compiler-ir-blocks
      (opt-switch-test-return-block (ir.compiler-ir-label "fallback") 99))))

(define (opt-switch-test-jump-block [label : i64] [target : i64]) : ir.CompilerIrBlock
  (Block label (ot.opt-test-instrs (ir.CompilerIrInstr.Jump target))))

;; Four compares, an empty forwarding block, then `after` more compares whose
;; tags run from `resume`. The forwarding block is what an inlined classifier
;; leaves between two halves of one `cond` chain. `tail` is appended after the
;; returning fallback, for a case that needs an extra block somewhere other
;; than the front (the first block in the list is the function's entry).
(define (opt-switch-test-hop-blocks
  [after : i64]
  [resume : i64]
  [tail : ir.CompilerIrBlockList]) : ir.CompilerIrBlockList
  (opt-switch-test-tag-chain-from
    (opt-switch-test-tag-array 4 0 3)
    0
    0
    4
    (ir.compiler-ir-label "hop")
    (ir.compiler-ir-blocks-with-tail
      (opt-switch-test-tag-chain-from
        (opt-switch-test-tag-array after resume (+ resume (- after 1)))
        4
        0
        after
        (ir.compiler-ir-label "fallback")
        (ir.compiler-ir-blocks-with-tail
          tail
          (opt-switch-test-return-block (ir.compiler-ir-label "fallback") 99)))
      (opt-switch-test-jump-block
        (ir.compiler-ir-label "hop")
        (ir.compiler-ir-label "cmp4")))))

;; The same shape, but a second edge reaches the forwarding block, so the
;; rewrite may not delete it and the chain must stop in front of it.
(define (opt-switch-test-hop-shared-blocks) : ir.CompilerIrBlockList
  (opt-switch-test-hop-blocks
    2
    4
    (ir.compiler-ir-blocks
      (opt-switch-test-jump-block
        (ir.compiler-ir-label "other")
        (ir.compiler-ir-label "hop")))))

;; A chain whose fifth compare re-tests a tag the first four already routed:
;; that block cannot join the table, but the four in front of it still form
;; one.
(define (opt-switch-test-repeat-tag-blocks) : ir.CompilerIrBlockList
  (opt-switch-test-tag-chain-from
    (opt-switch-test-tag-array 4 0 3)
    0
    0
    4
    (ir.compiler-ir-label "cmp4")
    (opt-switch-test-tag-chain-from
      (opt-switch-test-tag-array 1 0 0)
      4
      0
      1
      (ir.compiler-ir-label "fallback")
      (ir.compiler-ir-blocks
        (opt-switch-test-return-block (ir.compiler-ir-label "fallback") 99)))))

;; Four compares whose tag-2 arm only forwards to the real arm body. The table
;; entry can name the body directly; when the body opens with a phi it cannot,
;; because the phi has to name the edge it came in on.
(define (opt-switch-test-forwarded-arm-blocks [phi-body? : bool]) : ir.CompilerIrBlockList
  (ir.compiler-ir-blocks
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "entry")
      0
      1
      (opt-switch-test-arm-label 0)
      (ir.compiler-ir-label "cmp1"))
    (opt-switch-test-return-block (opt-switch-test-arm-label 0) 10)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp1")
      1
      2
      (opt-switch-test-arm-label 1)
      (ir.compiler-ir-label "cmp2"))
    (opt-switch-test-return-block (opt-switch-test-arm-label 1) 11)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp2")
      2
      3
      (ir.compiler-ir-label "forward")
      (ir.compiler-ir-label "cmp3"))
    (opt-switch-test-jump-block
      (ir.compiler-ir-label "forward")
      (ir.compiler-ir-label "body"))
    (if phi-body?
      (irt.block
        "body:
                       %12 = phi [12, forward] : i64
                       return %12")
      (opt-switch-test-return-block (ir.compiler-ir-label "body") 12))
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp3")
      3
      4
      (opt-switch-test-arm-label 3)
      (ir.compiler-ir-label "fallback"))
    (opt-switch-test-return-block (opt-switch-test-arm-label 3) 13)
    (opt-switch-test-return-block (ir.compiler-ir-label "fallback") 99)))

(define (opt-switch-test-chain-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-blocks
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "entry")
      tag0
      1
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp1")
      tag1
      2
      (ir.compiler-ir-label "case1")
      (ir.compiler-ir-label "cmp2"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp2")
      tag2
      3
      (ir.compiler-ir-label "case2")
      (ir.compiler-ir-label "cmp3"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp3")
      tag3
      4
      (ir.compiler-ir-label "case3")
      default-label)
    (opt-switch-test-return-block (ir.compiler-ir-label "case3") 13)
    (opt-switch-test-return-block default-label 99)))

(define (opt-switch-test-total-chain-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-blocks
    (opt-switch-test-total-compare-block
      (ir.compiler-ir-label "entry")
      tag0
      1
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
    (opt-switch-test-total-compare-block
      (ir.compiler-ir-label "cmp1")
      tag1
      2
      (ir.compiler-ir-label "case1")
      (ir.compiler-ir-label "cmp2"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
    (opt-switch-test-total-compare-block
      (ir.compiler-ir-label "cmp2")
      tag2
      3
      (ir.compiler-ir-label "case2")
      (ir.compiler-ir-label "cmp3"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
    (opt-switch-test-total-compare-block
      (ir.compiler-ir-label "cmp3")
      tag3
      4
      (ir.compiler-ir-label "case3")
      default-label)
    (opt-switch-test-return-block (ir.compiler-ir-label "case3") 13)
    (opt-switch-test-return-block default-label 99)))

(define (opt-switch-test-short-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-blocks
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "entry")
      0
      1
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp1")
      1
      2
      (ir.compiler-ir-label "case1")
      (ir.compiler-ir-label "cmp2"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp2")
      2
      3
      (ir.compiler-ir-label "case2")
      (ir.compiler-ir-label "fallback"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
    (opt-switch-test-return-block (ir.compiler-ir-label "fallback") 99)))

(define (opt-switch-test-extra-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-blocks
    (opt-switch-test-extra-compare-block
      (ir.compiler-ir-label "entry")
      0
      1
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp1")
      1
      2
      (ir.compiler-ir-label "case1")
      (ir.compiler-ir-label "cmp2"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp2")
      2
      3
      (ir.compiler-ir-label "case2")
      (ir.compiler-ir-label "cmp3"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp3")
      3
      4
      (ir.compiler-ir-label "case3")
      (ir.compiler-ir-label "fallback"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case3") 13)
    (opt-switch-test-return-block (ir.compiler-ir-label "fallback") 99)))

(define (opt-switch-test-prefix-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-blocks
    (opt-switch-test-prefix-compare-block
      (ir.compiler-ir-label "entry")
      tag0
      1
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp1")
      tag1
      2
      (ir.compiler-ir-label "case1")
      (ir.compiler-ir-label "cmp2"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp2")
      tag2
      3
      (ir.compiler-ir-label "case2")
      (ir.compiler-ir-label "cmp3"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp3")
      tag3
      4
      (ir.compiler-ir-label "case3")
      default-label)
    (opt-switch-test-return-block (ir.compiler-ir-label "case3") 13)
    (opt-switch-test-return-block default-label 99)))

;; Head block whose dispatch is a bare zero-test branch (`Eq tag, 0` folded
;; onto the tag var), again trailing an unconditional prefix instruction.
(define (opt-switch-test-bare-branch-block
  [label : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (Block
    label
    (ot.opt-test-instrs
      (ir.CompilerIrInstr.Mov 9 (Var 0) (I64))
      (ir.CompilerIrInstr.Branch (Var 0) next-label arm-label))))

(define (opt-switch-test-bare-blocks [default-label : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-blocks
    (opt-switch-test-bare-branch-block
      (ir.compiler-ir-label "entry")
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp1")
      1
      2
      (ir.compiler-ir-label "case1")
      (ir.compiler-ir-label "cmp2"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp2")
      2
      3
      (ir.compiler-ir-label "case2")
      (ir.compiler-ir-label "cmp3"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "cmp3")
      3
      4
      (ir.compiler-ir-label "case3")
      default-label)
    (opt-switch-test-return-block (ir.compiler-ir-label "case3") 13)
    (opt-switch-test-return-block default-label 99)))

;; Compare block testing an explicit compare var (for copy-resolution tests).
(define (opt-switch-test-compare-block-var
  [label : i64]
  [cmp-var : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (Block
    label
    (ot.opt-test-instrs
      (ir.CompilerIrInstr.BinOp eq-var Eq (Var cmp-var) (I64 tag) (I64))
      (ir.CompilerIrInstr.Branch (Var eq-var) arm-label next-label))))

;; The vm_run dispatch shape: the head compare reads the RAW tag var while the
;; middle compares read the match-scrutinee COPY (block-local copy propagation
;; rewrites same-block operands only). The chain must resolve both through the
;; head prefix's Mov to one logical index var.
(define (opt-switch-test-copy-head-blocks [default-label : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-blocks
    (irt.block
      "entry:
         %9 = mov %0 : i64
         %1 = eq %0, 0 : i64
         branch %1, case0, cmp1")
    (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
    (opt-switch-test-compare-block-var
      (ir.compiler-ir-label "cmp1")
      9
      1
      2
      (ir.compiler-ir-label "case1")
      (ir.compiler-ir-label "cmp2"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
    (opt-switch-test-compare-block-var
      (ir.compiler-ir-label "cmp2")
      9
      2
      3
      (ir.compiler-ir-label "case2")
      (ir.compiler-ir-label "cmp3"))
    (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
    (opt-switch-test-compare-block-var
      (ir.compiler-ir-label "cmp3")
      9
      3
      4
      (ir.compiler-ir-label "case3")
      default-label)
    (opt-switch-test-return-block (ir.compiler-ir-label "case3") 13)
    (opt-switch-test-return-block default-label 99)))

(define (compiler-optimize-switch-form-self-test) : i64
  (let
    [dense-source : ir.CompilerIrBlockList
      (opt-switch-test-chain-blocks 2 0 1 3 (ir.compiler-ir-label "fallback"))]
    [dense : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt.compiler-opt-global-shared-view dense-source)))]
    [dense-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks dense)]
    [short : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-short-blocks)))]
    ;; Gapped but above the density floor: tags 0,1,3,4 span five slots for four
    ;; compares, so the table forms and tag 2 takes the chain's fall-through.
    [sparse : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks
            0
            1
            3
            4
            (ir.compiler-ir-label "fallback"))))]
    [sparse-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks sparse)]
    [sparse-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        sparse-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    ;; Below the density floor: four compares over a span of twenty-one would
    ;; pay seventeen dead table slots, so the chain stays a compare chain.
    [too-sparse : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks
            0
            1
            2
            20
            (ir.compiler-ir-label "fallback"))))]
    [duplicate : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks
            0
            1
            1
            2
            (ir.compiler-ir-label "fallback"))))]
    [extra : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-extra-blocks)))]
    [prefix : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-prefix-blocks
            2
            0
            1
            3
            (ir.compiler-ir-label "fallback"))))]
    [prefix-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks prefix)]
    [prefix-twice : ir.CompilerIrFunction
      (ot.opt-switch-form-function (opt.compiler-opt-global-shared-view prefix))]
    [prefix-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        prefix-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    [bare : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-bare-blocks (ir.compiler-ir-label "fallback"))))]
    [bare-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks bare)]
    [bare-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block bare-blocks (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    [copy-head : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-copy-head-blocks (ir.compiler-ir-label "fallback"))))]
    [copy-head-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks copy-head)]
    [copy-head-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        copy-head-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    [total-final-label : i64
      (ir.compiler-ir-label "match_total_enum_default.4")]
    [total-trap-label : i64 (ir.compiler-ir-label "match_total_trap__entry")]
    [total : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-total-chain-blocks 0 1 2 3 total-final-label)))]
    [total-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks total)]
    [total-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        total-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    [total-late : ir.CompilerIrFunction
      (ot.opt-late-total-switch-function
        (ast.ast-node-pool-reader-type-segment-bases)
        total)]
    [total-late-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks total-late)]
    [total-late-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        total-late-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    [total-twice : ir.CompilerIrFunction
      (ot.opt-late-total-switch-function
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt.compiler-opt-global-shared-view total-late))]
    [cloned-total : ir.CompilerIrInstr
      (let
        [instr
          (ir.CompilerIrInstr.TotalEnumSwitch
            (Var 9)
            0
            (ir.compiler-ir-switch-case-seq1
              (Case 0 (ir.compiler-ir-label "arm")))
            (ir.compiler-ir-label "default")
            (ir.compiler-ir-label "trap"))]
        (opt.opt-inline-clone-multiblock-instr instr "cloned" (Nil) 0 10))]
    [cloned-pending-total : ir.CompilerIrInstr
      (let
        [instr
          (ir.CompilerIrInstr.TotalEnumSwitch
            (Var 9)
            0
            (ir.compiler-ir-switch-case-seq1
              (Case 0 (ir.compiler-ir-label "arm")))
            (ir.compiler-ir-label "default")
            (ir.compiler-ir-label-none))]
        (opt.opt-inline-clone-multiblock-instr instr "pending" (Nil) 0 10))]
    [preheader-forwarded-total : ir.CompilerIrInstr
      (opt.opt-loop-preheaders-retarget-instr
        (TotalEnumSwitch
          (Var 9)
          0
          (ir.compiler-ir-switch-case-seq1
            (Case 0 (ir.compiler-ir-label "arm")))
          (ir.compiler-ir-label "trap")
          (ir.compiler-ir-label "trap"))
        (ir.compiler-ir-label "trap")
        (ir.compiler-ir-label "preheader"))]
    ;; Display spellings are deliberately identical to the old protocol. An
    ;; ordinary chain using them must remain an ordinary checked Switch.
    [spoofed : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks 0 1 2 3 total-final-label)))]
    [spoofed-late : ir.CompilerIrFunction
      (ot.opt-late-total-switch-function
        (ast.ast-node-pool-reader-type-segment-bases)
        spoofed)]
    [spoofed-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks spoofed-late)]
    [spoofed-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        spoofed-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    [marked-sparse-final-label : i64
      (ir.compiler-ir-label "match_total_enum_default.sparse")]
    [marked-sparse : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-total-chain-blocks 0 1 3 4 marked-sparse-final-label)))]
    [marked-sparse-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks marked-sparse)]
    [marked-sparse-late : ir.CompilerIrFunction
      (ot.opt-late-total-switch-function
        (ast.ast-node-pool-reader-type-segment-bases)
        marked-sparse)]
    [marked-sparse-late-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks marked-sparse-late)]
    [marked-sparse-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        marked-sparse-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    [level1 : ir.CompilerIrFunction
      (ot.optimize-function-with-level
        (ast.ast-node-pool-reader-context-current)
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt-switch-test-function
          (opt.compiler-opt-global-shared-view dense-source))
        1)]
    [level2 : ir.CompilerIrFunction
      (ot.optimize-function-with-level
        (ast.ast-node-pool-reader-context-current)
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt-switch-test-function dense-source)
        2)]
    ;; Density tiers. Eight compares are enough that the walk dominates, so
    ;; they may span 66 slots (12%); one slot more, or one compare fewer at the
    ;; same shape, falls back to the 50% floor and stays a chain.
    [long-sparse : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-span-blocks 8 0 65)))]
    [long-sparse-entry : ir.CompilerIrBlock
      (match (let
        [blocks (opt.opt-function-blocks long-sparse)]
        (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "entry")))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    [long-too-sparse : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-span-blocks 8 0 66)))]
    [short-sparse : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-span-blocks 7 0 57)))]
    ;; An empty forwarding block between two halves of one chain: the table
    ;; spans both halves and the block is gone.
    [hop : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-hop-blocks 2 4 (ir.compiler-ir-block-list-empty))))]
    [hop-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks hop)]
    [hop-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block hop-blocks (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    ;; Reaching across the forwarding block would push the span to 0..80 for
    ;; five compares, below the short-chain floor. The four in front of it
    ;; still form their table, and the forwarding block becomes its default.
    [hop-fallback : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-hop-blocks 1 80 (ir.compiler-ir-block-list-empty))))]
    [hop-fallback-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks hop-fallback)]
    [hop-twice : ir.CompilerIrFunction
      (ot.opt-switch-form-function (opt.compiler-opt-global-shared-view hop))]
    [hop-twice-entry : ir.CompilerIrBlock
      (match (let
        [blocks (opt.opt-function-blocks hop-twice)]
        (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "entry")))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    [hop-fallback-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        hop-fallback-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    ;; A second edge reaches the forwarding block, so it must survive and the
    ;; chain has to stop in front of it.
    [hop-shared : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-hop-shared-blocks)))]
    [hop-shared-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks hop-shared)]
    [hop-shared-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        hop-shared-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    ;; A repeated tag cannot join the table, but it may not cost the four
    ;; compares in front of it their table either.
    [repeat-tag : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-repeat-tag-blocks)))]
    [repeat-tag-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks repeat-tag)]
    [repeat-tag-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        repeat-tag-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    ;; An arm that only forwards: the table entry names the body it forwards
    ;; to, unless the body opens with a phi that has to name its edge.
    [forwarded-arm : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-forwarded-arm-blocks false)))]
    [forwarded-arm-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks forwarded-arm)]
    [forwarded-arm-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        forwarded-arm-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    [forwarded-phi-arm : ir.CompilerIrFunction
      (ot.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-forwarded-arm-blocks true)))]
    [forwarded-phi-arm-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks forwarded-phi-arm)]
    [forwarded-phi-arm-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        forwarded-phi-arm-blocks
        (ir.compiler-ir-label "entry"))
        [(No) (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(Some block) block])]
    (cond
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view dense-blocks))
            1))
        1]
      [(not (= (opt-switch-entry-base dense-blocks) 0)) 2]
      [(not (= (opt-switch-entry-case-count dense-blocks) 4)) 3]
      [(not
          (=
            (opt-switch-entry-default-label dense-blocks)
            (ir.compiler-ir-label "fallback")))
        4]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view dense-blocks)
          (ir.compiler-ir-label "cmp1"))
        5]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view dense-blocks)
          (ir.compiler-ir-label "cmp2"))
        6]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view dense-blocks)
          (ir.compiler-ir-label "cmp3"))
        7]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function dense))) 8]
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks short)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            0))
        9]
      ;; A gap inside an admissible span becomes a table slot pointing at the
      ;; chain's own fall-through, which is where that tag went before.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view sparse-blocks))
            1))
        10]
      [(not (= (opt-switch-test-block-tail-case-count sparse-entry) 5)) 57]
      [(not (= (opt-switch-test-block-tail-base sparse-entry) 0)) 58]
      [(not
          (opt-switch-test-block-tail-has-case?
            sparse-entry
            2
            (ir.compiler-ir-label "fallback")))
        59]
      [(not
          (opt-switch-test-block-tail-has-case?
            sparse-entry
            3
            (ir.compiler-ir-label "case2")))
        60]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function sparse))) 61]
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks too-sparse)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            0))
        62]
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks duplicate)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            0))
        11]
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks extra)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            0))
        12]
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks level1)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            0))
        13]
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks level2)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            1))
        14]
      ;; A prefix head keeps its unconditional instructions ahead of the
      ;; Switch; the consumed middle compare blocks still disappear.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view prefix-blocks))
            1))
        15]
      [(not (= (opt-switch-test-block-tail-base prefix-entry) 0)) 16]
      [(not (= (opt-switch-test-block-tail-case-count prefix-entry) 4)) 17]
      [(not
          (=
            (opt-switch-test-block-tail-default prefix-entry)
            (ir.compiler-ir-label "fallback")))
        18]
      [(not (opt-switch-test-block-starts-with-mov? prefix-entry)) 19]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view prefix-blocks)
          (ir.compiler-ir-label "cmp1"))
        20]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view prefix-blocks)
          (ir.compiler-ir-label "cmp2"))
        21]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function prefix))) 22]
      ;; Idempotence: rerunning the pass must not rewrite the rewritten head.
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks prefix-twice)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            1))
        23]
      ;; A bare zero-test head (`Branch(tag, next, arm)`) is the folded
      ;; `Eq tag, 0` form and must join the chain as the tag-0 candidate.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view bare-blocks))
            1))
        24]
      [(not (= (opt-switch-test-block-tail-base bare-entry) 0)) 25]
      [(not (= (opt-switch-test-block-tail-case-count bare-entry) 4)) 26]
      [(not
          (=
            (opt-switch-test-block-tail-default bare-entry)
            (ir.compiler-ir-label "fallback")))
        27]
      [(not (opt-switch-test-block-starts-with-mov? bare-entry)) 28]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function bare))) 29]
      ;; The vm_run shape: head compare on the raw var, middle compares on
      ;; the prefix Mov's copy; resolution unifies them and the chain forms.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view copy-head-blocks))
            1))
        30]
      [(not (= (opt-switch-test-block-tail-base copy-head-entry) 0)) 31]
      [(not (= (opt-switch-test-block-tail-case-count copy-head-entry) 4)) 32]
      [(not
          (=
            (opt-switch-test-block-tail-default copy-head-entry)
            (ir.compiler-ir-label "fallback")))
        33]
      [(not (opt-switch-test-block-starts-with-mov? copy-head-entry)) 34]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function copy-head))) 35]
      ;; Switch formation carries an explicit pending total-enum proof with the
      ;; classic final fallthrough. Only the dedicated late pass consumes it,
      ;; adds the final table case, and installs the trap default.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view total-blocks))
            1))
        36]
      [(not (opt-switch-test-block-tail-total? total-entry)) 52]
      [(not (= (opt-switch-test-block-tail-base total-entry) 0)) 37]
      [(not (= (opt-switch-test-block-tail-case-count total-entry) 4)) 38]
      [(not
          (= (opt-switch-test-block-tail-default total-entry) total-final-label))
        39]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view total-blocks)
          total-trap-label)
        40]
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view total-late-blocks))
            1))
        41]
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
      [(not (opt.opt-verify-ok? (opt.opt-verify-function total-late))) 48]
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks total-twice)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            1))
        49]
      ;; Old display spellings are not authority without the explicit proof.
      [(opt-switch-test-block-tail-total? spoofed-entry) 53]
      [(not (= (opt-switch-test-block-tail-case-count spoofed-entry) 4)) 54]
      [(not
          (=
            (opt-switch-test-block-tail-default spoofed-entry)
            total-final-label))
        55]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view spoofed-blocks)
          total-trap-label)
        56]
      ;; An explicit proof alone is not enough to drop the range check: a gapped
      ;; chain routes its gaps to the fall-through, so the proof's "fall-through
      ;; IS the final variant" reading no longer holds. The chain still forms a
      ;; table, but as an ordinary checked Switch, and the late total pass must
      ;; therefore add neither a final case nor a trap block.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view marked-sparse-blocks))
            1))
        50]
      [(opt-switch-test-block-tail-total? marked-sparse-entry) 63]
      [(not (= (opt-switch-test-block-tail-case-count marked-sparse-entry) 5))
        64]
      [(not
          (opt-switch-test-block-tail-has-case?
            marked-sparse-entry
            2
            marked-sparse-final-label))
        65]
      [(not
          (=
            (opt-switch-test-block-tail-default marked-sparse-entry)
            marked-sparse-final-label))
        66]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view marked-sparse-late-blocks)
          (ir.compiler-ir-label "match_total_trap__entry"))
        51]
      ;; Multiblock inlining preserves the closed proof variant while
      ;; deliberately remapping every real label. The none trap sentinel on a
      ;; pending switch must remain a sentinel rather than becoming a label.
      [(not
          (match cloned-total
            [(TotalEnumSwitch (Var value) base cases default-label trap-label)
              (and
                (= value 19)
                (= base 0)
                (opt-switch-test-cases-have?
                  cases
                  0
                  (ir.compiler-ir-label "cloned.arm"))
                (= default-label (ir.compiler-ir-label "cloned.default"))
                (= trap-label (ir.compiler-ir-label "cloned.trap")))]
            [_ false]))
        57]
      [(not
          (match cloned-pending-total
            [(TotalEnumSwitch _ _ _ default-label trap-label)
              (and
                (= default-label (ir.compiler-ir-label "pending.default"))
                (= trap-label (ir.compiler-ir-label-none)))]
            [_ false]))
        58]
      [(not
          (match preheader-forwarded-total
            [(TotalEnumSwitch _ _ _ default-label trap-label)
              (and
                (= default-label (ir.compiler-ir-label "preheader"))
                (= trap-label (ir.compiler-ir-label "trap")))]
            [_ false]))
        59]
      ;; Density tiers, two-sided. Eight compares afford a 66-slot span (12%);
      ;; a 67-slot span at eight compares, and a 58-slot span at seven, are
      ;; both back under the 50% floor and stay chains.
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks long-sparse)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            1))
        70]
      [(not (= (opt-switch-test-block-tail-case-count long-sparse-entry) 66))
        71]
      [(not (= (opt-switch-test-block-tail-base long-sparse-entry) 0)) 72]
      [(not
          (opt-switch-test-block-tail-has-case?
            long-sparse-entry
            65
            (opt-switch-test-arm-label 7)))
        73]
      [(not
          (opt-switch-test-block-tail-has-case?
            long-sparse-entry
            9
            (ir.compiler-ir-label "fallback")))
        74]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function long-sparse))) 75]
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks long-too-sparse)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            0))
        76]
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks short-sparse)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            0))
        77]
      ;; One empty forwarding block between the halves of one chain: six
      ;; compares, one table, and the forwarding block is gone with them.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view hop-blocks))
            1))
        78]
      [(not (= (opt-switch-test-block-tail-case-count hop-entry) 6)) 79]
      [(not (= (opt-switch-test-block-tail-base hop-entry) 0)) 80]
      [(not
          (=
            (opt-switch-test-block-tail-default hop-entry)
            (ir.compiler-ir-label "fallback")))
        81]
      [(not
          (opt-switch-test-block-tail-has-case?
            hop-entry
            5
            (opt-switch-test-arm-label 5)))
        82]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view hop-blocks)
          (ir.compiler-ir-label "hop"))
        83]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view hop-blocks)
          (ir.compiler-ir-label "cmp4"))
        84]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function hop))) 85]
      ;; Idempotence: the fused head is a Switch, not a compare, so a second
      ;; run finds nothing left to fuse.
      [(not
          (=
            (let
              [walked-blocks : ir.CompilerIrBlockList
                (opt.opt-function-blocks hop-twice)]
              (opt-count-switch-blocks
                (ir.compiler-ir-block-list-view walked-blocks)))
            1))
        109]
      [(not (= (opt-switch-test-block-tail-case-count hop-twice-entry) 6)) 110]
      ;; Reaching across it must never cost the chain the table it already had.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view hop-fallback-blocks))
            1))
        86]
      [(not (= (opt-switch-test-block-tail-case-count hop-fallback-entry) 4))
        87]
      [(not
          (=
            (opt-switch-test-block-tail-default hop-fallback-entry)
            (ir.compiler-ir-label "hop")))
        88]
      [(not
          (ot.opt-block-list-has-label?
            (ir.compiler-ir-block-list-view hop-fallback-blocks)
            (ir.compiler-ir-label "hop")))
        89]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function hop-fallback))) 90]
      ;; A forwarding block something else also reaches cannot be deleted, so
      ;; the chain stops in front of it and it stays where it is.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view hop-shared-blocks))
            1))
        91]
      [(not (= (opt-switch-test-block-tail-case-count hop-shared-entry) 4)) 92]
      [(not
          (=
            (opt-switch-test-block-tail-default hop-shared-entry)
            (ir.compiler-ir-label "hop")))
        93]
      [(not
          (ot.opt-block-list-has-label?
            (ir.compiler-ir-block-list-view hop-shared-blocks)
            (ir.compiler-ir-label "hop")))
        94]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function hop-shared))) 95]
      ;; A repeated tag stops the chain instead of refusing it.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view repeat-tag-blocks))
            1))
        96]
      [(not (= (opt-switch-test-block-tail-case-count repeat-tag-entry) 4)) 97]
      [(not
          (=
            (opt-switch-test-block-tail-default repeat-tag-entry)
            (ir.compiler-ir-label "cmp4")))
        98]
      [(not
          (ot.opt-block-list-has-label?
            (ir.compiler-ir-block-list-view repeat-tag-blocks)
            (ir.compiler-ir-label "cmp4")))
        99]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function repeat-tag))) 100]
      ;; A forwarding arm is followed to the body it forwards to; the empty
      ;; block goes with the chain.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view forwarded-arm-blocks))
            1))
        101]
      [(not
          (opt-switch-test-block-tail-has-case?
            forwarded-arm-entry
            2
            (ir.compiler-ir-label "body")))
        102]
      [(ot.opt-block-list-has-label?
          (ir.compiler-ir-block-list-view forwarded-arm-blocks)
          (ir.compiler-ir-label "forward"))
        103]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function forwarded-arm))) 104]
      ;; A phi in the body has to name the edge it came in on, so that
      ;; forwarding block stays and the case keeps naming it.
      [(not
          (=
            (opt-count-switch-blocks
              (ir.compiler-ir-block-list-view forwarded-phi-arm-blocks))
            1))
        105]
      [(not
          (opt-switch-test-block-tail-has-case?
            forwarded-phi-arm-entry
            2
            (ir.compiler-ir-label "forward")))
        106]
      [(not
          (ot.opt-block-list-has-label?
            (ir.compiler-ir-block-list-view forwarded-phi-arm-blocks)
            (ir.compiler-ir-label "forward")))
        107]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function forwarded-phi-arm)))
        108]
      [else 42])))

(define (smoke-mov-dst-var-type-from?
  [instrs : (& instrs ir.CompilerIrInstrSeq)]
  [index : i64]
  [dst : i64]
  [src : i64]
  [ty : ast.AstType]) : bool
  (if (>= index (ir.compiler-ir-instr-seq-count instrs))
    false
    (match (ir.compiler-ir-instr-seq-ref instrs index)
      [(Mov d (Var s) mov-ty)
        (if (= d dst)
          (and
            (= s src)
            (opt.opt-type-eq
              (ast.ast-node-pool-reader-type-segment-bases)
              mov-ty
              ty))
          (smoke-mov-dst-var-type-from? instrs (+ index 1) dst src ty))]
      [_ (smoke-mov-dst-var-type-from? instrs (+ index 1) dst src ty)])))

(define (smoke-mov-dst-var-type?
  [instrs : (& instrs ir.CompilerIrInstrSeq)]
  [dst : i64]
  [src : i64]
  [ty : ast.AstType]) : bool
  (smoke-mov-dst-var-type-from? instrs 0 dst src ty))

(define (smoke-cast-dst-var-types-from?
  [instrs : ir.CompilerIrInstrSeq]
  [index : i64]
  [dst : i64]
  [src : i64]
  [from-ty : ast.AstType]
  [to-ty : ast.AstType]) : bool
  (if (>= index (ir.compiler-ir-instr-seq-count instrs))
    false
    (match (ir.compiler-ir-instr-seq-ref instrs index)
      [(Cast d (Var s) cast-from cast-to)
        (if (= d dst)
          (and
            (= s src)
            (opt.opt-type-eq
              (ast.ast-node-pool-reader-type-segment-bases)
              cast-from
              from-ty)
            (opt.opt-type-eq
              (ast.ast-node-pool-reader-type-segment-bases)
              cast-to
              to-ty))
          (smoke-cast-dst-var-types-from?
            instrs
            (+ index 1)
            dst
            src
            from-ty
            to-ty))]
      [_
        (smoke-cast-dst-var-types-from?
          instrs
          (+ index 1)
          dst
          src
          from-ty
          to-ty)])))

(define (smoke-cast-dst-var-types?
  [instrs : ir.CompilerIrInstrSeq]
  [dst : i64]
  [src : i64]
  [from-ty : ast.AstType]
  [to-ty : ast.AstType]) : bool
  (smoke-cast-dst-var-types-from? instrs 0 dst src from-ty to-ty))

(define (smoke-noop-int-cast-mov-instrs) : ir.CompilerIrInstrSeq
  (irt.instrs
    "%50 = cast %10 : u8 to char
     %51 = cast %11 : u16 to u8
     %52 = cast %12 : u16 to char
     %53 = cast %13 : u8 to i64
     %54 = cast %14 : i16 to u32
     %55 = cast %15 : i64 to u64"))

(define (smoke-noop-int-cast-mov-self-test) : i64
  (let
    [rewritten : ir.CompilerIrInstrSeq
      (ot.opt-test-fold-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (Nil)
        (smoke-noop-int-cast-mov-instrs))]
    (unless (= (ot.opt-count-cast-instr-seq rewritten) 3) (return 1))
    (unless (smoke-mov-dst-var-type? rewritten 50 10 (Char)) (return 2))
    (unless (smoke-mov-dst-var-type? rewritten 51 11 (U8)) (return 3))
    (unless (smoke-mov-dst-var-type? rewritten 52 12 (Char)) (return 4))
    (unless (smoke-cast-dst-var-types? rewritten 55 15 (I64) (U64)) (return 5))
    42))

(define (smoke-bounds-object-length-check-fragment
  [ptr-var : i64]
  [length-var : i64]
  [cast-var : i64]
  [object : ir.CompilerIrValue]
  [offset : ir.CompilerIrValue]
  [slot-ty : ast.AstType]
  [index : ir.CompilerIrValue]
  [label : i64]
  [tail : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
  (ot.opt-test-instrs-with-tail
    tail
    (ir.CompilerIrInstr.Gep ptr-var object offset slot-ty)
    (ir.CompilerIrInstr.Load length-var (Var ptr-var) (I64))
    (ir.CompilerIrInstr.Cast cast-var (Var length-var) (I64) (U64))
    (ir.CompilerIrInstr.BoundsCheck index (Var cast-var) label)))

(define (smoke-bounds-object-pair
  [second-object : ir.CompilerIrValue]
  [offset : ir.CompilerIrValue]
  [slot-ty : ast.AstType]) : ir.CompilerIrInstrSeq
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (Var 1)
    (opt.compiler-opt-global-shared-view offset)
    (opt.compiler-opt-global-shared-view slot-ty)
    (Var 0)
    (ir.compiler-ir-label "bounds_ok.0")
    (smoke-bounds-object-length-check-fragment
      20
      21
      22
      second-object
      offset
      slot-ty
      (Var 0)
      (ir.compiler-ir-label "bounds_ok.1")
      (ir.compiler-ir-instr-seq-empty))))

(define (smoke-bounds-object-call-barrier) : ir.CompilerIrInstrSeq
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (Var 1)
    (I64 1)
    (I64)
    (Var 0)
    (ir.compiler-ir-label "bounds_ok.0")
    (ot.opt-test-instrs-with-tail
      (smoke-bounds-object-length-check-fragment
        20
        21
        22
        (Var 1)
        (I64 1)
        (I64)
        (Var 0)
        (ir.compiler-ir-label "bounds_ok.1")
        (ir.compiler-ir-instr-seq-empty))
      (irt.instr "%30 = call touch() : unit"))))

;; Element-store survival: a `StorePtr` whose target is the object's tracked
;; length-slot pointer (var 10) changes the length and must clear the facts (the
;; 2nd check survives -> count 2). A `StorePtr` to any other pointer (var 99, an
;; array element) cannot change the length, so the facts survive and the 2nd
;; check is removed (-> count 1).
(define (smoke-bounds-object-store-barrier [store-ptr : ir.CompilerIrValue]) : ir.CompilerIrInstrSeq
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (Var 1)
    (I64 1)
    (I64)
    (Var 0)
    (ir.compiler-ir-label "bounds_ok.0")
    (ot.opt-test-instrs-with-tail
      (smoke-bounds-object-length-check-fragment
        20
        21
        22
        (Var 1)
        (I64 1)
        (I64)
        (Var 0)
        (ir.compiler-ir-label "bounds_ok.1")
        (ir.compiler-ir-instr-seq-empty))
      (ir.CompilerIrInstr.StorePtr store-ptr (I64 7) (I64)))))

(define (smoke-object-bounds-self-test) : i64
  (let
    [object-array : ir.CompilerIrInstrSeq
      (ot.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (Nil)
        (Empty)
        (smoke-bounds-object-pair (Var 1) (I64 1) (I64)))]
    [object-string : ir.CompilerIrInstrSeq
      (ot.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (Nil)
        (Empty)
        (smoke-bounds-object-pair (Var 1) (I64 8) (U8)))]
    [object-mismatch : ir.CompilerIrInstrSeq
      (ot.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (Nil)
        (Empty)
        (smoke-bounds-object-pair (Var 2) (I64 1) (I64)))]
    [object-call : ir.CompilerIrInstrSeq
      (ot.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (Nil)
        (Empty)
        (smoke-bounds-object-call-barrier))]
    [object-store : ir.CompilerIrInstrSeq
      (ot.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (Nil)
        (Empty)
        (smoke-bounds-object-store-barrier (Var 10)))]
    [object-element-store : ir.CompilerIrInstrSeq
      (ot.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (Nil)
        (Empty)
        (smoke-bounds-object-store-barrier (Var 99)))]
    (cond
      [(not (= (ot.opt-count-bounds-instrs object-array) 1)) 1]
      [(not (= (ot.opt-count-bounds-instrs object-string) 1)) 2]
      [(not (= (ot.opt-count-bounds-instrs object-mismatch) 2)) 3]
      [(not (= (ot.opt-count-bounds-instrs object-call) 2)) 4]
      [(not (= (ot.opt-count-bounds-instrs object-store) 2)) 5]
      [(not (= (ot.opt-count-bounds-instrs object-element-store) 1)) 6]
      [else 42])))

;; Rotated fixed-array loops enter the body with a literal seed, then guard each
;; backedge with the stepped value.  The first input does not need a separately
;; materialized comparison fact when the same literal bound proves it directly;
;; every nonliteral/backedge input still has to be discharged on its own edge.
(define (smoke-rotated-bce-params) : ir.CompilerIrParamSeq
  (irt.params "backing-length=%4:i64, other-length=%5:i64"))

(define (smoke-rotated-bce-entry
  [start : ir.CompilerIrValue]
  [bound : ir.CompilerIrValue]
  [op : ir.CompilerIrBinOp]) : ir.CompilerIrBlock
  (Block
    (ir.compiler-ir-label "entry")
    (ot.opt-test-instrs
      (ir.CompilerIrInstr.BinOp 1 op start bound (I64))
      (irt.instr "branch %1, body, exit"))))

(define (smoke-rotated-bce-body
  [start : ir.CompilerIrValue]
  [check-bound : ir.CompilerIrValue]) : ir.CompilerIrBlock
  (Block
    (ir.compiler-ir-label "body")
    (ot.opt-test-instrs
      (ir.CompilerIrInstr.Phi
        0
        (ir.compiler-ir-phi-input-seq-prepend
          start
          (ir.compiler-ir-label "entry")
          (&
            (ir.compiler-ir-phi-input-seq-prepend
              (Var 2)
              (ir.compiler-ir-label "latch")
              (& (ir.compiler-ir-phi-input-seq-empty)))))
        (I64))
      (ir.CompilerIrInstr.BoundsCheck
        (Var 0)
        check-bound
        (ir.compiler-ir-label "bounds_ok"))
      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch")))))

(define (smoke-rotated-bce-latch
  [bound : ir.CompilerIrValue]
  [op : ir.CompilerIrBinOp]
  [both-edges-enter : bool]) : ir.CompilerIrBlock
  (Block
    (ir.compiler-ir-label "latch")
    (ot.opt-test-instrs
      (irt.instr "%2 = add %0, 1 : i64")
      (ir.CompilerIrInstr.BinOp 3 op (Var 2) bound (I64))
      (ir.CompilerIrInstr.Branch
        (Var 3)
        (ir.compiler-ir-label "body")
        (if both-edges-enter
          (ir.compiler-ir-label "body")
          (ir.compiler-ir-label "exit"))))))

(define (smoke-rotated-bce-blocks
  [start : ir.CompilerIrValue]
  [guard-bound : ir.CompilerIrValue]
  [check-bound : ir.CompilerIrValue]
  [op : ir.CompilerIrBinOp]
  [both-edges-enter : bool]) : ir.CompilerIrBlockList
  (ir.compiler-ir-blocks
    (smoke-rotated-bce-entry
      (opt.compiler-opt-global-shared-view start)
      (opt.compiler-opt-global-shared-view guard-bound)
      (opt.compiler-opt-global-shared-view op))
    (smoke-rotated-bce-body start check-bound)
    (smoke-rotated-bce-latch guard-bound op both-edges-enter)
    (irt.block "exit:
               return")))

(define (smoke-rotated-bce-count
  [start : ir.CompilerIrValue]
  [guard-bound : ir.CompilerIrValue]
  [check-bound : ir.CompilerIrValue]
  [op : ir.CompilerIrBinOp]
  [both-edges-enter : bool]) : i64
  (let
    [blocks : ir.CompilerIrBlockList
      (smoke-rotated-bce-blocks
        start
        guard-bound
        check-bound
        op
        both-edges-enter)]
    [walked-blocks : ir.CompilerIrBlockList
      (opt.opt-bounds-dom-blocks-with-context
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt.opt-cfg-context-build (opt.compiler-opt-global-shared-view blocks))
        (smoke-rotated-bce-params)
        6
        blocks)]
    (opt.opt-count-bounds-blocks (ir.compiler-ir-block-list-view walked-blocks))))

(define (smoke-rotated-literal-bce-self-test) : i64
  (let
    [fixed : i64 (smoke-rotated-bce-count (I64 0) (I64 9) (I64 9) (Lt) false)]
    ;; The dynamic form models a borrowed backing whose exact array-length SSA
    ;; value feeds both the loop guard and the access check. A Vec live length
    ;; is a distinct value (the mismatch case below) and proves nothing about
    ;; backing capacity.
    [borrowed-backing : i64
      (smoke-rotated-bce-count (I64 0) (Var 4) (Var 4) (Lt) false)]
    [negative-start : i64
      (smoke-rotated-bce-count (I64 (- 0 1)) (I64 9) (I64 9) (Lt) false)]
    [different-upper : i64
      (smoke-rotated-bce-count (I64 0) (I64 8) (I64 9) (Lt) false)]
    [different-provenance : i64
      (smoke-rotated-bce-count (I64 0) (Var 4) (Var 5) (Lt) false)]
    [inclusive-upper : i64
      (smoke-rotated-bce-count (I64 0) (I64 9) (I64 9) (Le) false)]
    [nondominating-backedge : i64
      (smoke-rotated-bce-count (I64 0) (I64 9) (I64 9) (Lt) true)]
    (cond
      [(not (= fixed 0)) 1]
      [(not (= borrowed-backing 0)) 2]
      [(not (= negative-start 1)) 3]
      ;; A check whose literal bound is merely IMPLIED by the guard's (`i < 8`
      ;; on every edge, checked against 9) is retired by the phi-inductive rule:
      ;; each incoming value is proved below 9 on its own edge -- the seed by
      ;; the literal comparison, the stepped value by the backedge's own `< 8`
      ;; read through the literal-implication masks. The guard and the check no
      ;; longer have to name the SAME bound, only ordered ones.
      [(not (= different-upper 0)) 4]
      [(not (= different-provenance 1)) 5]
      [(not (= inclusive-upper 1)) 6]
      [(not (= nondominating-backedge 1)) 7]
      [else 42])))

(define (smoke-heavy-pass-large-label [index : i64]) : i64
  (ir.compiler-ir-label (& (str_cat.str-cat "b" (string.int->string index)))))

(define (smoke-heavy-pass-large-jump-block [index : i64] [next : i64]) : ir.CompilerIrBlock
  (Block
    (smoke-heavy-pass-large-label index)
    (ot.opt-test-instrs (ir.CompilerIrInstr.Jump next))))

(define (smoke-heavy-pass-large-exit-block) : ir.CompilerIrBlock
  (irt.block "exit:
       %3 = add %0, %1 : i64
       return %3"))

(define (smoke-heavy-pass-large-tail-blocks!
  [out : (&mut out ir.CompilerIrBlockBuilder)]
  [index : i64]
  [last : i64]) : unit
  (if (> index last)
    (ir.compiler-ir-block-builder-push! out (smoke-heavy-pass-large-exit-block))
    (begin
      (ir.compiler-ir-block-builder-push!
        out
        (smoke-heavy-pass-large-jump-block
          index
          (if (= index last)
            (ir.compiler-ir-label "exit")
            (smoke-heavy-pass-large-label (+ index 1)))))
      (smoke-heavy-pass-large-tail-blocks! out (+ index 1) last))))

(define (smoke-heavy-pass-large-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-blocks-with-tail
    (opt.opt-blocks-collect smoke-heavy-pass-large-tail-blocks! 1 1024)
    (irt.block "entry:
         %2 = add %0, %1 : i64
         jump b1")))

(define (smoke-heavy-pass-large-function) : ir.CompilerIrFunction
  (Function
    (ot.opt-test-symbol "heavy_pass_large")
    (ot.opt-gvn-test-params)
    (I64)
    4
    (smoke-heavy-pass-large-blocks)
    Ordinary))

(define (smoke-heavy-pass-large-gvn-self-test) : i64
  (let
    [blocks : ir.CompilerIrBlockList (smoke-heavy-pass-large-blocks)]
    [optimized : ir.CompilerIrFunction
      (let
        [pools (ast.ast-node-pool-reader-context-current)]
        [type-segment-bases (ast.ast-node-pool-reader-type-segment-bases)]
        [func (smoke-heavy-pass-large-function)]
        (opt.optimize-function-once-with-summaries
          pools
          type-segment-bases
          func
          (opt.opt-program-summaries-empty)))]
    (unless (> (ir.compiler-ir-block-list-count blocks) 1024) (return 1))
    (unless
      (<=
        (ir.compiler-ir-block-list-count blocks)
        (opt.opt-heavy-pass-block-limit))
      (return 2))
    (match optimized
      [(Function _ _ _ _ optimized-blocks _)
        (if (=
          (ot.opt-gvn-count-binops-blocks
            (ir.compiler-ir-block-list-view optimized-blocks))
          1)
          42
          3)])))

(define (smoke-function-index-leaf-starts-self-test) : i64
  (let
    [qualified : String "module/path::tl_substring"]
    [plain : String "plain"]
    [index : opt.OptFunctionIndex
      (let
        [bound-arg-1
          (ir.compiler-ir-function-seq-prepend
            (&
              (ot.opt-test-function-named
                (string.copy qualified)
                (ir.compiler-ir-instr-seq-empty)))
            (&
              (ir.compiler-ir-function-seq-prepend
                (&
                  (ot.opt-test-function-named
                    (string.copy plain)
                    (ir.compiler-ir-instr-seq-empty)))
                (& (ir.compiler-ir-function-seq-empty)))))]
        (opt.opt-function-index-build bound-arg-1))]
    [starts : (__tl_dyn-array i64) index.leaf-starts]
    (cond
      [(not (= (array-length starts) 2)) 1]
      [(not (= (array-ref starts 0) (opt.opt-symbol-leaf-start qualified))) 2]
      [(not (= (array-ref starts 1) 0)) 3]
      [(not
          (opt.opt-symbol-leaf-matches-from?
            qualified
            (array-ref starts 0)
            "tl_substring"))
        4]
      [(opt.opt-symbol-leaf-matches-from?
          qualified
          (array-ref starts 0)
          "substring")
        5]
      [(not
          (opt.opt-symbol-leaf-matches-from? plain (array-ref starts 1) "plain"))
        6]
      [else 42])))

(define (smoke-optimizer-named-failure-message-ok?) : bool
  (string.eq
    (ot.compiler-optimize-self-test-failure-message "copy propagation" 7 42)
    "optimizer self-test failed: copy propagation (expected 42, got 7)"))

(define (smoke-inline-phi-header [latch-label : i64]) : ir.CompilerIrInstr
  (Phi
    1
    (ir.compiler-ir-phi-input-seq-prepend
      (I64 0)
      (ir.compiler-ir-label "entry")
      (&
        (ir.compiler-ir-phi-input-seq-prepend
          (Var 0)
          latch-label
          (& (ir.compiler-ir-phi-input-seq-empty)))))
    (I64)))

(define (smoke-inline-phi-exit [latch-label : i64]) : ir.CompilerIrInstr
  (Phi
    2
    (ir.compiler-ir-phi-input-seq-prepend
      (Var 1)
      (ir.compiler-ir-label "header")
      (&
        (ir.compiler-ir-phi-input-seq-prepend
          (Var 0)
          latch-label
          (& (ir.compiler-ir-phi-input-seq-empty)))))
    (I64)))

(define (smoke-inline-phi-caller-with-call
  [symbols : ot.OptInlineMultiTestSymbols]
  [call : ir.CompilerIrInstr]) : ir.CompilerIrFunction
  (Function
    symbols.main
    (ir.compiler-ir-param-seq-empty)
    (I64)
    3
    (ir.compiler-ir-blocks-with-tail
      (irt.blocks
        "exit:
               %2 = phi [%1, header], [%0, latch] : i64
               return %2")
      (irt.block "entry:
           jump header")
      (irt.block
        "header:
             %1 = phi [0, entry], [%0, latch] : i64
             branch true, latch, exit")
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "latch")
        (ot.opt-test-instrs call (irt.instr "branch true, header, exit"))))
    Ordinary))

(define (smoke-inline-phi-params) : ir.CompilerIrParamSeq
  (irt.params "a=%0:i64, b=%1:i64, c=%2:i64, d=%3:i64"))

(define (smoke-inline-phi-callee-mov) : ir.CompilerIrInstr
  (Mov 4 (I64 7) (I64)))

(define (smoke-inline-phi-callee [symbols : ot.OptInlineMultiTestSymbols]) : ir.CompilerIrFunction
  (Function
    symbols.inline-branch
    (smoke-inline-phi-params)
    (I64)
    5
    (ir.compiler-ir-blocks-with-tail
      (irt.blocks "exit:
           return %4")
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (ot.opt-test-instrs
          (smoke-inline-phi-callee-mov)
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "exit")))))
    Ordinary))

(define (smoke-inline-phi-call [symbols : ot.OptInlineMultiTestSymbols]) : ir.CompilerIrInstr
  (let
    [values : (__tl_dyn-array ir.CompilerIrValue)
      (__tl_make-array ir.CompilerIrValue 4)]
    (set! (array-ref values 0) (ir.CompilerIrValue.I64 1))
    (set! (array-ref values 1) (ir.CompilerIrValue.I64 2))
    (set! (array-ref values 2) (ir.CompilerIrValue.I64 3))
    (set! (array-ref values 3) (ir.CompilerIrValue.I64 4))
    (Call 0 symbols.inline-branch (Array values) (I64))))

(define (smoke-inline-phi-caller [symbols : ot.OptInlineMultiTestSymbols]) : ir.CompilerIrFunction
  (smoke-inline-phi-caller-with-call symbols (smoke-inline-phi-call symbols)))

(define (smoke-inline-phi-functions [symbols : ot.OptInlineMultiTestSymbols]) : ir.CompilerIrFunctionSeq
  (ir.compiler-ir-function-seq-prepend
    (& (smoke-inline-phi-caller symbols))
    (&
      (ir.compiler-ir-function-seq-prepend
        (& (smoke-inline-phi-callee symbols))
        (& (ir.compiler-ir-function-seq-empty))))))

(define (smoke-inline-phi-loop-repaired?
  [blocks : (& blocks ir.CompilerIrBlockList)]) : bool
  (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "header"))
    [(No) false]
    [(Some header)
      (match header
        [(Block _ instrs)
          (match (ir.compiler-ir-instr-seq-ref instrs 0)
            [(Phi _ inputs _)
              (if (opt.opt-phi-input-seq-eq
                inputs
                (match (irt.instr
                  "%1 = phi [0, entry], [%0, inl.latch.0.cont] : i64")
                  [(Phi _ expected _) expected]
                  [_ (ir.compiler-ir-phi-input-seq-empty)]))
                (match (opt.opt-cfg-find-block
                  blocks
                  (ir.compiler-ir-label "exit"))
                  [(No) false]
                  [(Some exit)
                    (match exit
                      [(Block _ exit-instrs)
                        (match (ir.compiler-ir-instr-seq-ref exit-instrs 0)
                          [(Phi _ exit-inputs _)
                            (opt.opt-phi-input-seq-eq
                              exit-inputs
                              (match (irt.instr
                                "%2 = phi [%1, header], [%0, inl.latch.0.cont] : i64")
                                [(Phi _ expected _) expected]
                                [_ (ir.compiler-ir-phi-input-seq-empty)]))]
                          [_ false])])])
                false)]
            [_ false])])]))

(define (smoke-inline-phi-positive-code) : i64
  (let
    [symbols : ot.OptInlineMultiTestSymbols (ot.opt-inline-multi-test-symbols)]
    [optimized : ir.CompilerIrFunctionSeq
      (ot.opt-test-inline-program-functions
        (ast.ast-node-pool-reader-type-segment-bases)
        (smoke-inline-phi-functions symbols)
        2)]
    (match (ot.opt-function-seq-find optimized "main")
      [(Some main)
        (let
          [blocks : ir.CompilerIrBlockList (opt.opt-function-blocks main)]
          (cond
            [(not
                (=
                  (ot.opt-count-direct-call-name-blocks
                    (ir.compiler-ir-block-list-view blocks)
                    "inline_branch")
                  0))
              11]
            [(not (= (ir.compiler-ir-block-list-count blocks) 7))
              (+ 20 (ir.compiler-ir-block-list-count blocks))]
            [(not
                (=
                  (ot.opt-count-phi-blocks
                    (ir.compiler-ir-block-list-view blocks))
                  2))
              (+
                40
                (ot.opt-count-phi-blocks
                  (ir.compiler-ir-block-list-view blocks)))]
            [(not (smoke-inline-phi-loop-repaired? blocks)) 61]
            [(not (opt.opt-inline-structure-ok? blocks)) 62]
            [else 42]))]
      [(No) 10])))

(define (smoke-inline-phi-spans?) : bool
  (let
    [symbols : ot.OptInlineMultiTestSymbols (ot.opt-inline-multi-test-symbols)]
    [call : ir.CompilerIrInstr (smoke-inline-phi-call symbols)]
    [header-phi : ir.CompilerIrInstr
      (smoke-inline-phi-header (ir.compiler-ir-label "latch"))]
    [exit-phi : ir.CompilerIrInstr
      (smoke-inline-phi-exit (ir.compiler-ir-label "latch"))]
    [main-symbol : ir.CompilerIrSymbolId
      (ir.compiler-ir-symbol-typed-id (ot.opt-test-symbol "main"))]
    [spans : ir.CompilerSourceSpans
      (ir.compiler-source-spans-insert-instr
        (ir.compiler-source-spans-insert-instr
          (ir.compiler-source-spans-insert-instr
            (ot.opt-spans-base)
            main-symbol
            (& call)
            (ot.opt-test-span 161 31))
          main-symbol
          (& header-phi)
          (ot.opt-test-span 162 33))
        main-symbol
        (& exit-phi)
        (ot.opt-test-span 163 35))]
    [result-mov : ir.CompilerIrInstr (Mov 0 (Var 3) (I64))]
    [repaired-header : ir.CompilerIrInstr
      (smoke-inline-phi-header (ir.compiler-ir-label "inl.latch.0.cont"))]
    [repaired-exit : ir.CompilerIrInstr
      (smoke-inline-phi-exit (ir.compiler-ir-label "inl.latch.0.cont"))]
    (match (ot.opt-test-inline-program-with-spans
      (ast.ast-node-pool-reader-context-current)
      (ast.ast-node-pool-reader-type-segment-bases)
      (smoke-inline-phi-functions symbols)
      2
      spans)
      [(Program optimized optimized-spans)
        (match (ot.opt-function-seq-find optimized "main")
          [(Some main)
            (let
              [blocks : ir.CompilerIrBlockList (opt.opt-function-blocks main)]
              (and
                (=
                  (ot.opt-count-direct-call-name-blocks
                    (ir.compiler-ir-block-list-view blocks)
                    "inline_branch")
                  0)
                (smoke-inline-phi-loop-repaired? blocks)
                (opt.opt-inline-structure-ok? blocks)
                (ot.opt-span-lookup-ok?
                  optimized-spans
                  (ot.opt-test-symbol "main")
                  result-mov
                  161
                  31)
                (ot.opt-span-lookup-ok?
                  optimized-spans
                  (ot.opt-test-symbol "main")
                  repaired-header
                  162
                  33)
                (ot.opt-span-lookup-ok?
                  optimized-spans
                  (ot.opt-test-symbol "main")
                  repaired-exit
                  163
                  35)))]
          [(No) false])])))

(define (smoke-inline-phi-refusal?) : bool
  (let
    [symbols : ot.OptInlineMultiTestSymbols (ot.opt-inline-multi-test-symbols)]
    [caller : ir.CompilerIrFunction (smoke-inline-phi-caller symbols)]
    [optimized : ir.CompilerIrFunctionSeq
      (ot.opt-test-inline-program-functions
        (ast.ast-node-pool-reader-type-segment-bases)
        (ir.compiler-ir-function-seq-prepend
          (& caller)
          (& (ir.compiler-ir-function-seq-empty)))
        2)]
    (match (ot.opt-function-seq-find optimized "main")
      [(Some main)
        (opt.opt-function-eq
          (ast.ast-node-pool-reader-type-segment-bases)
          main
          caller)]
      [(No) false])))

;; The nonleaf callee's one site sits in the latch of `main`'s loop, one
;; deciding branch below the header: the sole-call tier absorbs it (INL-13,
;; opt-inline-sole-call-loop-site-shallow?), so `main` loses the call and
;; gains the callee's own call to `external_helper`. The cost band still
;; refuses the body; the tier moves it because nothing else references it.
(define (smoke-inline-phi-nonleaf-cost?) : bool
  (let
    [symbols : ot.OptInlineMultiTestSymbols (ot.opt-inline-multi-test-symbols)]
    [caller : ir.CompilerIrFunction
      (smoke-inline-phi-caller-with-call
        symbols
        (Call 0 symbols.inline-nonleaf Nil (I64)))]
    [optimized : ir.CompilerIrFunctionSeq
      (ot.opt-test-inline-program-functions
        (ast.ast-node-pool-reader-type-segment-bases)
        (ir.compiler-ir-function-seq-prepend
          (& caller)
          (&
            (ir.compiler-ir-function-seq-prepend
              (& (ot.opt-inline-nonleaf-callee symbols))
              (& (ir.compiler-ir-function-seq-empty)))))
        2)]
    (match (ot.opt-function-seq-find optimized "main")
      [(Some main)
        (let
          [blocks : ir.CompilerIrBlockList (opt.opt-function-blocks main)]
          (and
            (=
              (ot.opt-count-direct-call-name-blocks
                (ir.compiler-ir-block-list-view blocks)
                "inline_nonleaf")
              0)
            (=
              (ot.opt-count-direct-call-name-blocks
                (ir.compiler-ir-block-list-view blocks)
                "external_helper")
              1)
            (opt.opt-inline-structure-ok? blocks)))]
      [(No) false])))

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
(define (smoke-c27-params) : ir.CompilerIrParamSeq
  (irt.params "cond=%0:bool, x=%1:i64"))

(define (smoke-c27-if-convert-function [computed-arm? : bool]) : ir.CompilerIrFunction
  (Function
    (ot.opt-test-symbol "c27_if_convert")
    (smoke-c27-params)
    (I64)
    8
    (ir.compiler-ir-blocks-with-tail
      (irt.blocks "exit:
                   return %4")
      (irt.block "entry:
           jump header")
      (irt.block
        "header:
             %2 = phi [0, entry], [%6, merge] : i64
             %5 = gt %1, 0 : i64
             branch %5, then, else")
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "then")
        (if computed-arm?
          (irt.instrs "%3 = add %1, 1 : i64
                 jump merge")
          (irt.instrs "jump merge")))
      (irt.block "else:
                 jump merge")
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "merge")
        (ot.opt-test-instrs
          (ir.CompilerIrInstr.Phi
            4
            (ir.compiler-ir-phi-input-seq-prepend
              (if computed-arm?
                (Var 3)
                (Var 1))
              (ir.compiler-ir-label "then")
              (&
                (ir.compiler-ir-phi-input-seq-prepend
                  (Var 1)
                  (ir.compiler-ir-label "else")
                  (& (ir.compiler-ir-phi-input-seq-empty)))))
            (I64))
          (irt.instr "%6 = add %2, 1 : i64")
          (irt.instr "%7 = lt %6, 2 : i64")
          (irt.instr "branch %7, header, exit"))))
    Ordinary))

(define (smoke-c27-count-scalar-selects-instrs
  [instrs : ir.CompilerIrInstrSeq]
  [index : i64]) : i64
  (if (>= index (ir.compiler-ir-instr-seq-count instrs))
    0
    (+
      (match (ir.compiler-ir-instr-seq-ref instrs index)
        [(Select payload-box)
          (let
            [lanes (__tl-project-field (__tl-box-place payload-box) lanes)]
            (if (= lanes 0)
              1
              0))]
        [_ 0])
      (smoke-c27-count-scalar-selects-instrs instrs (+ index 1)))))

(define (smoke-c27-count-scalar-selects
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (smoke-c27-count-scalar-selects-instrs instrs 0)
            (smoke-c27-count-scalar-selects rest))])]))

(define (smoke-c27-count-binop-instrs
  [instrs : ir.CompilerIrInstrSeq]
  [index : i64]
  [wanted : (& wanted ir.CompilerIrBinOp)]) : i64
  (if (>= index (ir.compiler-ir-instr-seq-count instrs))
    0
    (+
      (match (ir.compiler-ir-instr-seq-ref instrs index)
        [(BinOp _ op _ _ _)
          (if (= (opt.opt-binop-tag op) (opt.opt-binop-tag wanted))
            1
            0)]
        [_ 0])
      (smoke-c27-count-binop-instrs instrs (+ index 1) wanted))))

(define (smoke-c27-count-binop
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [wanted : ir.CompilerIrBinOp]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (smoke-c27-count-binop-instrs instrs 0 wanted)
            (smoke-c27-count-binop rest wanted))])]))

(define (smoke-c27-compare-function [extra-use? : bool]) : ir.CompilerIrFunction
  (Function
    (ot.opt-test-symbol "c27_bit_test")
    (irt.params "x=%0:i64")
    (I64)
    4
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (ot.opt-test-instrs-with-tail
          (if extra-use?
            (irt.instrs "%3 = add %1, %2 : i64
               return %3")
            (irt.instrs "return %2"))
          (irt.instr "%1 = bit_and %0, 1 : i64")
          (irt.instr "%2 = gt %1, 0 : i64"))))
    Ordinary))

(define (smoke-c27-if-convert-compare-self-test) : i64
  (let
    [converted : ir.CompilerIrFunction
      (ot.opt-if-convert-function
        (ast.ast-node-pool-reader-type-segment-bases)
        (smoke-c27-if-convert-function false))]
    [conditional : ir.CompilerIrFunction
      (ot.opt-if-convert-function
        (ast.ast-node-pool-reader-type-segment-bases)
        (smoke-c27-if-convert-function true))]
    [single-use : ir.CompilerIrFunction
      (match (smoke-c27-compare-function false)
        [(Function name params ret frame blocks function-abi)
          (Function
            name
            params
            ret
            frame
            (opt.opt-dce-block-list-array
              (opt.opt-collect-blocks-uses-array frame blocks)
              blocks)
            function-abi)])]
    [multi-use : ir.CompilerIrFunction
      (match (smoke-c27-compare-function true)
        [(Function name params ret frame blocks function-abi)
          (Function
            name
            params
            ret
            frame
            (opt.opt-dce-block-list-array
              (opt.opt-collect-blocks-uses-array frame blocks)
              blocks)
            function-abi)])]
    [converted-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks converted)]
    [conditional-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks conditional)]
    [single-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks single-use)]
    [multi-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks multi-use)]
    (cond
      [(not
          (=
            (smoke-c27-count-scalar-selects
              (ir.compiler-ir-block-list-view converted-blocks))
            1))
        1]
      [(not (= (ir.compiler-ir-block-list-count converted-blocks) 4)) 2]
      [(not
          (=
            (smoke-c27-count-scalar-selects
              (ir.compiler-ir-block-list-view conditional-blocks))
            0))
        3]
      [(not
          (=
            (smoke-c27-count-binop
              (ir.compiler-ir-block-list-view single-blocks)
              BitTestNe)
            1))
        4]
      [(not
          (=
            (smoke-c27-count-binop
              (ir.compiler-ir-block-list-view multi-blocks)
              BitTestNe)
            0))
        5]
      [(not
          (=
            (smoke-c27-count-binop
              (ir.compiler-ir-block-list-view multi-blocks)
              Gt)
            1))
        6]
      [else 42])))

;; `1 << 63` as an i64 payload. The single-bit admission guard reads the stored
;; comparison constant, and this one is stored negative.
(define (smoke-c27-i64-min) : i64
  (- (- 0 9223372036854775807) 1))

;; Mask-test admission fixture: `v2 = x & and-mask` immediately followed by
;; `v3 = v2 <cmp-op> cmp-const`, whose result is returned. `v2` has exactly one
;; use and the pair is adjacent, so the DCE walk's bookkeeping guards are both
;; satisfied and only the admission rule itself decides the outcome.
(define (smoke-c27-mask-compare-function
  [and-mask : ir.CompilerIrValue]
  [cmp-op : ir.CompilerIrBinOp]
  [cmp-const : i64]) : ir.CompilerIrFunction
  (Function
    (ot.opt-test-symbol "c27_mask_test")
    (irt.params "x=%0:i64, m=%1:i64")
    (I64)
    4
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (ot.opt-test-instrs
          (ir.CompilerIrInstr.BinOp 2 BitAnd (Var 0) and-mask (I64))
          (ir.CompilerIrInstr.BinOp 3 cmp-op (Var 2) (I64 cmp-const) (I64))
          (irt.instr "return %3"))))
    Ordinary))

(define (smoke-c27-mask-dce-blocks [fn : ir.CompilerIrFunction]) : ir.CompilerIrBlockList
  (let
    [func
      (match fn
        [(Function name params ret frame blocks function-abi)
          (ir.CompilerIrFunction.Function
            name
            params
            ret
            frame
            (opt.opt-dce-block-list-array
              (opt.opt-collect-blocks-uses-array frame blocks)
              blocks)
            function-abi)])]
    (opt.opt-function-blocks func)))

;; 1 when the pair collapsed to BitTestNe, 2 when it collapsed to BitTestEq,
;; 0 when the `and` survived (the rewrite was refused), -1 for anything else.
;; A surviving `and` is the refusal witness: admission retires its only use, so
;; the DCE sweep in the same pass deletes it.
(define (smoke-c27-mask-shape
  [and-mask : ir.CompilerIrValue]
  [cmp-op : ir.CompilerIrBinOp]
  [cmp-const : i64]) : i64
  (let
    [blocks : ir.CompilerIrBlockList
      (smoke-c27-mask-dce-blocks
        (smoke-c27-mask-compare-function and-mask cmp-op cmp-const))]
    [ne : i64
      (smoke-c27-count-binop (ir.compiler-ir-block-list-view blocks) BitTestNe)]
    [eq : i64
      (smoke-c27-count-binop (ir.compiler-ir-block-list-view blocks) BitTestEq)]
    [ands : i64
      (smoke-c27-count-binop (ir.compiler-ir-block-list-view blocks) BitAnd)]
    (cond
      [(and (= ne 1) (= eq 0) (= ands 0)) 1]
      [(and (= ne 0) (= eq 1) (= ands 0)) 2]
      [(and (= ne 0) (= eq 0) (= ands 1)) 0]
      [else (- 0 1)])))

;; A second DCE pass over already-rewritten blocks must be a no-op: the slot
;; now holds a bit test, not a comparison against a literal.
(define (smoke-c27-mask-idempotent?) : bool
  (let
    [once : ir.CompilerIrBlockList
      (smoke-c27-mask-dce-blocks (smoke-c27-mask-compare-function (I64 1) Eq 1))]
    [twice : ir.CompilerIrBlockList
      (opt.opt-dce-block-list-array
        (opt.opt-collect-blocks-uses-array 4 once)
        once)]
    (and
      (=
        (smoke-c27-count-binop (ir.compiler-ir-block-list-view twice) BitTestNe)
        1)
      (=
        (smoke-c27-count-binop (ir.compiler-ir-block-list-view twice) BitAnd)
        0))))

;; Returns 42 only when single-bit mask-test admission fires on exactly the
;; admitted shapes, with the INVERTED mapping, and leaves every neighbouring
;; shape byte-for-byte alone.
(define (smoke-c27-mask-test-admission-self-test) : i64
  (cond
    ;; `(x & 1) == 1` is "bit set", which is ZF CLEAR -> BitTestNe.
    [(not (= (smoke-c27-mask-shape (I64 1) Eq 1) 1)) 1]
    ;; `(x & 8) != 8` is "bit clear", which is ZF SET -> BitTestEq.
    [(not (= (smoke-c27-mask-shape (I64 8) Ne 8) 2)) 2]
    ;; Boundary single-bit masks: the 32-bit edge and the highest bit the
    ;; `> 0` guard still admits.
    [(not (= (smoke-c27-mask-shape (I64 2147483648) Eq 2147483648) 1)) 3]
    [(not
        (=
          (smoke-c27-mask-shape
            (I64 4611686018427387904)
            Ne
            4611686018427387904)
          2))
      4]
    ;; `1 << 63` is stored negative, so the `> 0` guard refuses it.
    [(not
        (=
          (smoke-c27-mask-shape
            (I64 (smoke-c27-i64-min))
            Eq
            (smoke-c27-i64-min))
          0))
      5]
    ;; A multi-bit mask asks whether BOTH bits are set; `test` cannot answer.
    [(not (= (smoke-c27-mask-shape (I64 3) Eq 3) 0)) 6]
    ;; The comparison constant is not the mask.
    [(not (= (smoke-c27-mask-shape (I64 4) Eq 1) 0)) 7]
    ;; Ordered compares against the mask are a constant fold, not a bit test.
    [(not (= (smoke-c27-mask-shape (I64 1) Le 1) 0)) 8]
    [(not (= (smoke-c27-mask-shape (I64 1) Gt 1) 0)) 9]
    ;; A non-literal mask names no bit.
    [(not (= (smoke-c27-mask-shape (Var 1) Eq 1) 0)) 10]
    ;; The compare-against-zero mapping is untouched, in both directions and
    ;; with the multi-bit mask it still admits.
    [(not (= (smoke-c27-mask-shape (I64 1) Eq 0) 2)) 11]
    [(not (= (smoke-c27-mask-shape (I64 1) Ne 0) 1)) 12]
    [(not (= (smoke-c27-mask-shape (I64 3) Eq 0) 2)) 13]
    [(not (smoke-c27-mask-idempotent?)) 14]
    [else 42]))

(test
  load-cse-copybytes-forwarding
  (test.assert-i64-eq
    (ot.compiler-optimize-load-cse-self-test)
    44
    "load-cse copybytes forwarding"))

(test
  optimizer-alias-fact-model
  (test.assert-i64-eq
    (ot.compiler-optimize-alias-self-test)
    42
    "optimizer alias fact model"))

(test
  inline-multiblock-switch-absorbable
  (test.assert-true
    (ot.compiler-optimize-inline-multiblock-switch-ok?)
    "absorbable acyclic bounds+switch callee inlines with fresh CFG/phi labels"))

(test
  inline-multiblock-cyclic-bounds-switch-admission
  (test.assert-true
    (ot.compiler-optimize-inline-multiblock-cyclic-bounds-switch-admission-ok?)
    "a one-reference cyclic bounds+switch callee is taken in a loop-free caller, bounds check and cloned CFG intact"))

(test
  inline-vm-run-bounds-loop-exception
  (test.assert-true
    (ot.compiler-optimize-inline-vm-run-bounds-loop-ok?)
    "vm-run and the same-shaped qs-partition both inline at opt2 on shape, not on name; opt1 still refuses both"))

(test
  inline-bounds-loop-in-loop-site
  (test.assert-true
    (ot.compiler-optimize-inline-bounds-loop-in-loop-site-ok?)
    "small absorbable bounds loop leaf inlines at an in-loop call site"))

(test
  inline-bounds-loop-cold-site-admission
  (test.assert-true
    (ot.compiler-optimize-inline-bounds-loop-cold-site-admission-ok?)
    "the same leaf is taken at a straight-line site of a loop-free caller: no caller loop is there to tax"))

(test
  inline-checked-depth-weighting
  (test.assert-true
    (ot.compiler-optimize-inline-checked-depth-weighting-ok?)
    "the measured tier prices a body at the depth an inline would put it, and the weight ladder saturates"))

(test
  dominance-frontier-table-matches-scan
  (test.assert-true
    (ot.compiler-optimize-dominance-frontier-table-ok?)
    "the per-function dominance frontier table equals the per-label scan on random CFGs"))

(test
  inline-checked-versioned-loop-weighting
  (test.assert-true
    (ot.compiler-optimize-inline-checked-versioned-loop-weighting-ok?)
    "a versioned loop prices as one loop, and its guard runs once per entry: below the cap at its own depth, past it one rung below the cap"))

(test
  inline-checked-sret-copy
  (test.assert-true
    (ot.compiler-optimize-inline-checked-sret-copy-ok?)
    "an sret callee's boundary adds the result copy a free inline retires: a word per 8 bytes of the widest store through __sret, nothing without one"))

(test
  inline-checked-window
  (test.assert-true
    (ot.compiler-optimize-inline-checked-window-ok?)
    "the accept window is two-sided: the model must agree with a free inline within a factor of two"))

(test
  inline-checked-budget
  (test.assert-true
    (ot.compiler-optimize-inline-checked-budget-ok?)
    "the program budget counts verdicts and the tier arms and disarms"))

(test
  inline-checked-band-exclusion
  (test.assert-true
    (ot.compiler-optimize-inline-checked-band-exclusion-ok?)
    "a band-admitted site never reaches the check, so a banked program spends no budget"))

(test
  inline-checked-call-carrying-verdicts
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-checked-call-carrying-self-test)
    3000111
    "the tier prices call-carrying candidates the bands refuse, keeps the ones whose plan repays, and every function verifies"))

(test
  inline-checked-call-carrying-deep-verdicts
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-checked-call-carrying-deep-self-test)
    200
    "the tier keeps a call-carrying site one loop deeper too, and both callers verify"))

(test
  inline-rescan-loop-nest
  (test.assert-true
    (ot.compiler-optimize-inline-rescan-loop-nest-ok?)
    "the rescan clause is inert in generation one and separates a loop-bearing callee from the acyclic body of the same size"))

(test
  inline-multiblock-alloc-shape
  (test.assert-true
    (ot.compiler-optimize-inline-multiblock-alloc-shape-ok?)
    "the multiblock gate admits an aggregate-building body and names the clause that refuses each neighbour"))

(test
  thread-phi-chain
  (test.assert-i64-eq
    (ot.compiler-optimize-thread-phi-chain-self-test)
    42
    "a phi merge threads through the compare tree it feeds on the facts each edge carries, and collapses onto the exit that reads it"))

(test
  inline-one-block-shape
  (test.assert-true
    (ot.compiler-optimize-inline-one-block-shape-ok?)
    "a one-block body past the single-block cap is the checked tier's, and only a small one keeps there"))

(test
  inline-multiblock-alloc-splice
  (test.assert-true
    (ot.compiler-optimize-inline-multiblock-alloc-splice-ok?)
    "an aggregate-building sret body splices into a loop site once, and both storage runs keep the shape the allocator scans for"))

(test
  inline-multiblock-tail-site-indirect-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-multiblock-tail-site-indirect-refusal-ok?)
    "an indirect tail-call site is not a site: the multiblock path admits only the direct form"))

(test
  inline-checked-tail-site-verdicts
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-checked-tail-site-self-test)
    11
    "a tail call ends the function, so a tail site inside a loop is that loop's EXIT and runs once per invocation: at depth zero with the caller count as its whole frequency the frequency clause refuses both callers' sites before pricing, and both tail calls survive"))

(test
  inline-checked-tail-post-site-verdict
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-checked-tail-post-self-test)
    110
    "a tail site that is its loop's only exit post-dominates the entry: the hot caller's site clears the relaxed floor, is priced, and takes the call-free leaf, the callee's returns become the caller's, and the cold caller's site is refused on frequency and keeps its tail call"))

(test
  inline-checked-specialization
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-checked-specialization-self-test)
    42
    "a literal argument widens the cap's prediction by what it folds, never the floor; a forwarder is tail-only; the specialized copy pins exactly the literal parameters"))

(test
  inline-checked-tail-only-literal-site
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-checked-tail-only-self-test true)
    100
    "a forwarder -- every exit a tail call, no Return -- reaches a verdict at a hot site whose first argument is the temp a literal was materialized into, and the verdict takes it: no call to the forwarder survives"))

(test
  inline-checked-tail-only-unspecialized-site
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-checked-tail-only-self-test false)
    1
    "the same forwarder at the same site with a parameter passed through is refused by the tail-only clause before pricing: no verdict, the call survives"))

(test
  inline-checked-rescan-generations
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-checked-rescan-self-test)
    11001
    "a keep exposes its copy's own sites, the rescan generation prices them, and the third level stays out of line"))

(test
  inline-checked-absorb-rescan
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-checked-absorb-rescan-self-test)
    10001
    "a body the absorb band moved in is rescanned: the site it exposes inside the caller's loop gets a core verdict and is kept, and the level below stays out of line"))

(test
  inline-checked-generation-carry
  (test.assert-true
    (ot.compiler-optimize-inline-checked-generation-carry-ok?)
    "a rescan generation carries the caller's verdicts, accepted rows and callee lock, and retires the finished generation's site keys"))

(test
  inline-checked-generation-accept-cap
  (test.assert-true
    (ot.compiler-optimize-inline-checked-generation-accept-cap-ok?)
    "the per-caller accept cap is not refunded by a rescan: a site that would exceed it is refused there"))

(test
  inline-checked-call-carrying-revert
  (test.assert-true
    (ot.compiler-optimize-inline-checked-call-carrying-revert-ok?)
    "the same call-carrying callee reverts when its measured plan does not repay the boundary"))

(test
  inline-multiblock-call-clone-spans
  (test.assert-true
    (ot.compiler-optimize-spans-inline-multiblock-call-ok?)
    "the spans clone walk rebases a cloned call and re-keys its span under the caller"))

(test
  inline-multiblock-clone-abort-span
  (test.assert-true
    (ot.compiler-optimize-inline-clone-abort-span-ok?)
    "an abort inside a cloned call-carrying callee keeps the callee's span in a release build"))

(test
  inline-chain-second-import-call
  (test.assert-true
    (ot.compiler-optimize-inline-chain-second-import-call-ok?)
    "a chain absorbed bottom-up re-clones an already cloned call and leaves one call in the caller"))

(test
  inline-checked-sequence-two-sites
  (test.assert-true
    (ot.compiler-optimize-inline-checked-sequence-two-sites-ok?)
    "two sites of one callee are priced richest-first and both kept, each against the state before it"))

(test
  inline-checked-sequence-partial
  (test.assert-true
    (ot.compiler-optimize-inline-checked-sequence-partial-ok?)
    "a caller keeps its first site and reverts its second: the rollback is per site, not per caller"))

(test
  inline-checked-richness
  (test.assert-true
    (ot.compiler-optimize-inline-checked-richness-ok?)
    "sites are ordered by what a free inline is worth, per unit of the caller's growth budget it spends"))

(test
  inline-checked-caller-cap
  (test.assert-true
    (ot.compiler-optimize-inline-checked-caller-cap-ok?)
    "one caller cannot drain the program's verdict budget"))

(test
  inline-checked-one-callee
  (test.assert-true
    (ot.compiler-optimize-inline-checked-one-callee-ok?)
    "a caller's later sites are restricted to the callee its first accept named"))

(test
  inline-checked-depth-floor
  (test.assert-true
    (ot.compiler-optimize-inline-checked-depth-floor-ok?)
    "the site-depth floor relaxes to zero exactly where the composite frequency already carries the evidence"))

(test
  inline-checked-entry-equivalent
  (test.assert-true
    (ot.compiler-optimize-inline-checked-entry-equivalent-ok?)
    "a depth-0 site reads as entry-equivalent at the entry block, at a block that post-dominates it in a loop-free caller, at an arm of the entry branch whose sibling leaves the function in a wrapper-shaped caller, and at an arm of a DISPATCH whose spine only compares and branches"))

(test
  inline-checked-depth0-hot-site
  (test.assert-i64-eq
    (ot.opt-inline-checked-depth0-self-test 1)
    100
    "the recorded seven-parameter builder shape at a depth-0 entry site of a hot loop-holding caller is priced and taken: one verdict, no call left to the builder"))

(test
  inline-checked-depth0-cold-site
  (test.assert-i64-eq
    (ot.opt-inline-checked-depth0-self-test 0)
    1
    "the same depth-0 site under a caller nothing reaches through a loop never reaches a verdict"))

(test
  inline-checked-depth0-threaded-site
  (test.assert-i64-eq
    (ot.opt-inline-checked-depth0-self-test 2)
    100
    "moving the same site one unconditional jump off the entry block leaves it POST-DOMINATING the entry, so INL-4 reads it as entry-equivalent in this wrapper-shaped caller: the same verdict as the entry spelling, and it takes the body"))

(test
  inline-checked-depth0-guarded-site
  (test.assert-i64-eq
    (ot.opt-inline-checked-depth0-self-test 3)
    101
    "putting the same site below a guard whose other arm returns makes its block neither the entry's post-dominator nor an arm of the entry branch, and the floor stands exactly as it did before the widening: one verdict fewer, the call still there"))

(test
  inline-checked-inl8-post-multi-call-caller
  (test.assert-i64-eq
    (ot.opt-inline-checked-inl8-self-test 0)
    3000
    "a callee taken at a small wrapper and left out of line at a straight-line caller carrying calls of its own: INL-8 MEASURES the second caller's post-dominating site -- three verdicts, and neither caller keeps the call"))

(test
  inline-checked-inl8-post-multi-call-caller-loop
  (test.assert-i64-eq
    (ot.opt-inline-checked-inl8-self-test 1)
    1010
    "the same pair with a LOOP below the second caller's site, which is the reading the caller clause had before: the site never reaches a verdict -- `site-depth` with `pos` reading `none` -- so one verdict fewer and that caller keeps its call out of line"))

(test
  inline-checked-inl9-dispatch-arms
  (test.assert-i64-eq
    (ot.opt-inline-checked-inl9-self-test 0)
    3000
    "the three arms of a dispatch, each calling one acyclic call-free leaf: INL-9 reads every arm as entry-equivalent -- only the first is a successor of the entry branch, and the call count is one per arm by construction -- so the tier prices all three, keeps all three, and no arm is left holding the call"))

(test
  inline-checked-inl9-dispatch-cyclic-callee
  (test.assert-i64-eq
    (ot.opt-inline-checked-inl9-self-test 1)
    3
    "the same dispatch with a LOOP around the same leaf's chain: the dispatch reading's own clause is on the callee, so no arm reaches a verdict at all -- `site-depth` with `pos` reading `none` -- three verdicts fewer and all three calls still there (gvn_table +8,031,268 when they are not)"))

(test
  inline-checked-lock-bodies
  (test.assert-true
    (ot.compiler-optimize-inline-checked-lock-bodies-ok?)
    "the callee lock admits the ranked bodies up to its bound and refuses the one past it; a slim accept no longer refuses the next body by proxy"))

(test
  inline-checked-relaxed-rank
  (test.assert-true
    (ot.compiler-optimize-inline-checked-relaxed-rank-ok?)
    "a relaxed candidate is ranked behind every core one and charged to the relaxations' own reserve"))

(test
  inline-synth-chain
  (test.assert-true
    (ot.compiler-optimize-inline-synth-chain-ok?)
    "a leaf two straight-line wrappers below a loop reads one census weight on the propagated count and one on the census's own"))

(test
  inline-synth-recursive
  (test.assert-true
    (ot.compiler-optimize-inline-synth-recursive-ok?)
    "a recursive component carries its own repetition, reproducibly and inside the saturating cap"))

(test
  inline-synth-address-taken
  (test.assert-true
    (ot.compiler-optimize-inline-synth-address-taken-ok?)
    "an address-taken callee starts at the unknown-caller base of one; the ordinary callee beside it starts at zero"))

(test
  inline-synth-order
  (test.assert-true
    (ot.compiler-optimize-inline-synth-order-ok?)
    "the hotter candidate is armed first whatever order the caller's walk found the sites in"))

(test
  inline-checked-relaxed-reserve
  (test.assert-true
    (ot.compiler-optimize-inline-checked-relaxed-reserve-ok?)
    "the relaxations' reserve runs out without touching the budget the core candidates read"))

(test
  inline-checked-cheap-tier-claim
  (test.assert-i64-eq
    (ot.opt-inline-checked-cheap-tier-self-test)
    10000
    "one checked-tier verdict, and the cheap tiers' four inlines of a tiny leaf all still in place"))

(test
  inline-bounds-loop-cascade-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-bounds-loop-cascade-refusal-ok?)
    "import refused when it would cost a bounds-free single-site caller its own inline"))

(test
  inline-single-site-wide-absorb
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-wide-absorb-ok?)
    "a 220-instruction ten-parameter single-site callee absorbs whole at its one cold site"))

(test
  inline-single-site-wide-loop-site-absorb
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-wide-loop-site-absorb-ok?)
    "the same unbounded body absorbs at an in-loop site: the boundary retires per iteration"))

(test
  inline-single-site-narrow-small-caller-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-narrow-small-caller-refusal-ok?)
    "below the arity floor the body stays out of line even in a two-block caller"))

(test
  inline-single-site-narrow-large-caller-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-narrow-large-caller-refusal-ok?)
    "below the arity floor and past the narrow caller band, the body stays out of line"))

(test
  inline-single-site-narrow-loop-site-absorb
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-narrow-loop-site-absorb-ok?)
    "below the arity floor a small call-free body still moves at an in-loop site"))

(test
  inline-single-site-narrow-straight-site-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-narrow-straight-site-refusal-ok?)
    "the same body at a straight-line site stays out: below the floor there is no marshalling to retire"))

(test
  inline-single-site-narrow-oversize-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-narrow-oversize-refusal-ok?)
    "past the loop tier's size class the in-loop waiver stops admitting a below-floor boundary"))

(test
  inline-single-site-size-cap-absorb
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-size-cap-absorb-ok?)
    "a single-site callee at the pathological backstop still absorbs: no growth to bound"))

(test
  inline-sole-call-past-backstop-absorb
  (test.assert-true
    (ot.compiler-optimize-inline-sole-call-past-backstop-absorb-ok?)
    "one block past the backstop the acyclic body absorbs anyway: the sole-call tier has no block cap"))

(test
  inline-sole-call-narrow-absorb
  (test.assert-true
    (ot.compiler-optimize-inline-sole-call-narrow-absorb-ok?)
    "a three-parameter forty-block acyclic sole-call callee absorbs at its one straight-line site"))

(test
  inline-sole-call-cyclic-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-sole-call-cyclic-refusal-ok?)
    "the identical body with one back edge stays out: a loop-carrying body compounds the caller's pressure"))

(test
  inline-sole-call-loop-site-absorb
  (test.assert-true
    (ot.compiler-optimize-inline-sole-call-loop-site-absorb-ok?)
    "the same acyclic body absorbs at an in-loop site the loop runs every iteration: the boundary it retires is paid per iteration"))

(test
  inline-sole-call-loop-site-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-sole-call-loop-site-refusal-ok?)
    "the same body stays out at an in-loop site two deciding branches below the header: the import lands inside a region already priced, for a boundary the loop rarely retires"))

(test
  inline-sole-call-staged-args-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-sole-call-staged-args-refusal-ok?)
    "an sret callee stays out: the clone's staged path is fail-closed at this tier"))

(test
  inline-sole-call-two-reference-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-sole-call-two-reference-refusal-ok?)
    "two straight-line sites keep the body at both: the sole-call tier moves, it never copies"))

(test
  inline-sole-call-address-taken-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-sole-call-address-taken-refusal-ok?)
    "an address-taken callee is refused at one call site: the address is a second way in"))

(test
  inline-sole-call-self-recursive-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-sole-call-self-recursive-refusal-ok?)
    "a self-calling callee counts two references and never reaches the sole-call tier"))

(test
  inline-sole-call-extern-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-sole-call-extern-refusal-ok?)
    "a callee with no body in the function sequence -- an extern -- keeps its call"))

(test
  inline-sole-call-cascade-depth
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-sole-call-cascade-depth-code)
    0
    "A's only caller B absorbed into C in one pass, with the merged body's pred renames well formed"))

(test
  inline-single-site-absorb-keeps-block-fuel
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-absorb-keeps-block-fuel-ok?)
    "a moved body does not spend the shared growth budget the cost model draws on"))

(test
  inline-single-site-two-reference-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-two-reference-refusal-ok?)
    "two cold sites keep the body at both: this band moves, it never copies"))

(test
  inline-single-site-self-recursive-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-self-recursive-refusal-ok?)
    "a self-calling callee counts two references and is refused"))

(test
  inline-single-site-call-bearing-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-call-bearing-refusal-ok?)
    "a wide single-site callee that calls out stays out of line: the band cannot price its callee's calls"))

(test
  inline-single-site-loop-site-call-bearing-absorb
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-loop-site-call-bearing-absorb-ok?)
    "the same call-carrying callee absorbs at an in-loop site: its calls already ran per iteration"))

(test
  inline-single-site-cascade-site
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-cascade-site-ok?)
    "the cascade clause refuses at a straight-line site and comes off at an in-loop one"))

(test
  inline-single-site-address-taken-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-single-site-address-taken-refusal-ok?)
    "an address-taken callee is refused even at one call site"))

(test
  inline-single-site-cascade
  (test.assert-i64-eq
    (ot.compiler-optimize-inline-single-site-cascade-depth-code)
    0
    "a three-deep single-site chain collapses into one function in a single pass"))

(test
  inline-dup-two-site
  (test.assert-true
    (ot.compiler-optimize-inline-dup-two-site-ok?)
    "a two-reference call-free leaf is duplicated into both in-loop sites"))

(test
  inline-dup-cascade-per-caller
  (test.assert-true
    (ot.compiler-optimize-inline-dup-cascade-per-caller-ok?)
    "the cascade clause is asked per caller: the same duplicable leaf is refused at one site and admitted at the other"))

(test
  inline-dup-call-bearing-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-dup-call-bearing-refusal-ok?)
    "a two-reference leaf carrying a call stays out of line at both sites"))

(test
  inline-hot-loop-leaf-three-site
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-three-site-ok?)
    "a call-free cyclic leaf past the duplication ceiling is copied into every in-loop site"))

(test
  inline-hot-loop-leaf-call-bearing-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-call-bearing-refusal-ok?)
    "a multi-reference loop leaf carrying a call stays out of line at every site"))

(test
  inline-hot-loop-leaf-too-big-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-too-big-refusal-ok?)
    "a multi-reference loop leaf one instruction past the band stays out of line"))

(test
  inline-hot-loop-leaf-in-loop-small-caller
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-in-loop-small-caller-ok?)
    "a big-tier loop leaf is admitted at an in-loop site when the caller is small enough"))

(test
  inline-hot-loop-leaf-in-loop-big-caller-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-in-loop-big-caller-refusal-ok?)
    "the same leaf at in-loop sites of callers past the size cap stays out of line"))

(test
  inline-hot-loop-leaf-loop-free-site
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-loop-free-site-ok?)
    "a loop-free caller takes the loop leaf at a straight-line site: no caller loop is there to tax"))

(test
  inline-hot-loop-leaf-recursive-caller-admission
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-recursive-caller-admission-ok?)
    "the same leaf at the same sites of SELF-RECURSIVE callers is taken at every site: the tailrec rewrite runs before the inliner, so the caller's loop is there and the in-loop tier admits the leaf into it"))

(test
  inline-recursive-caller-loop-free
  (test.assert-true
    (ot.compiler-optimize-inline-recursive-caller-loop-free-ok?)
    "the loop-free clause separates a straight-line caller, a self-tail-recursive one and a looping one, and reports each as the band line's caller-rec field"))

(test
  inline-hot-loop-leaf-cold-site-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-cold-site-refusal-ok?)
    "a call in a looping caller's exit block stays out of line: neither repayment clause fires"))

(test
  inline-hot-loop-leaf-budget-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-budget-refusal-ok?)
    "five copies fit the per-caller block fuel; the sixth site keeps its call"))

(test
  inline-hot-loop-leaf-single-reference
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-single-reference-ok?)
    "a one-reference big-tier loop leaf is taken at its in-loop site: the band starts at one reference, not three"))

(test
  inline-hot-loop-leaf-single-reference-too-big-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-single-reference-too-big-refusal-ok?)
    "the size ceiling still binds at one reference: a leaf one instruction past the band keeps its call"))

(test
  inline-hot-loop-leaf-single-reference-call-bearing-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-hot-loop-leaf-single-reference-call-bearing-refusal-ok?)
    "the call-free pricing clause still binds at one reference: a big-tier leaf carrying a call keeps its boundary"))

(test
  inline-shared-accessor-floor
  (test.assert-true
    (ot.compiler-optimize-inline-shared-accessor-floor-ok?)
    "an acyclic accessor at the reference floor is taken at every in-loop site; one reference short stays out of line"))

(test
  inline-shared-accessor-call-free
  (test.assert-true
    (ot.compiler-optimize-inline-shared-accessor-call-free-ok?)
    "a shared accessor carrying a call stays out of line at every site"))

(test
  inline-shared-accessor-acyclic
  (test.assert-true
    (ot.compiler-optimize-inline-shared-accessor-acyclic-ok?)
    "a cyclic call-bearing body at the same shared sites stays out of line: both gates refuse it"))

(test
  inline-shared-accessor-in-loop-site
  (test.assert-true
    (ot.compiler-optimize-inline-shared-accessor-in-loop-site-ok?)
    "the same accessor at straight-line sites stays out of line"))

(test
  inline-shared-accessor-dominant-floor
  (test.assert-true
    (ot.compiler-optimize-inline-shared-accessor-dominant-floor-ok?)
    "an accessor at the dominant reference floor is taken at every straight-line site; one reference short keeps every call"))

(test
  inline-shared-accessor-dominant-call-free
  (test.assert-true
    (ot.compiler-optimize-inline-shared-accessor-dominant-call-free-ok?)
    "a call-bearing body at the dominant floor stays out of line at every straight-line site"))

(test
  inline-accessor-depth-weight
  (test.assert-true
    (ot.compiler-optimize-inline-accessor-depth-weight-ok?)
    "two nested-loop sites weigh 128 and take the accessor; the same two sites one loop shallower weigh 16 and keep both calls"))

(test
  inline-accessor-depth-oversize-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-accessor-depth-oversize-refusal-ok?)
    "a body past the accessor block ceiling stays out of line at the same nested-loop sites"))

(test
  inline-accessor-depth-bounds-admission
  (test.assert-true
    (ot.compiler-optimize-inline-accessor-depth-bounds-admission-ok?)
    "a bounds-carrying body is taken at two nested-loop sites and kept behind its call one loop shallower: the weight decides, not the bounds check"))

(test
  inline-depth-multiple-latches
  (test.assert-true
    (ot.compiler-optimize-inline-depth-multiple-latches-ok?)
    "multiple backedges to one loop header contribute one depth level"))

(test
  inline-branch-chain-site
  (test.assert-true
    (ot.compiler-optimize-inline-branch-chain-site-ok?)
    "a bounds-free acyclic decision chain past the block cap is taken at both in-loop sites"))

(test
  inline-branch-chain-merge-web
  (test.assert-true
    (ot.compiler-optimize-inline-branch-chain-merge-web-ok?)
    "the same block count with one working block stays out of line: the chain gate prices blocks, not shapes"))

(test
  inline-vm-run-bounds-loop-span-positive
  (test.assert-i64-eq
    (ot.opt-inline-switch-span-case-code "bench.tl::vm-run" true 2)
    15
    "span-aware inliner admits exact vm-run and preserves cloned spans"))

(test
  inline-qs-partition-bounds-loop-span-positive
  (test.assert-i64-eq
    (ot.opt-inline-switch-span-case-code "bench.tl::qs-partition" true 2)
    15
    "the similarly shaped qs-partition loop is admitted on its shape now, not on a name, and its cloned spans survive"))

(test
  inline-vm-run-bounds-loop-span-negative
  (test.assert-i64-eq
    (ot.opt-inline-switch-span-case-code "bench.tl::vm-run" false 1)
    15
    "below opt2 the multiblock inliner does not run: the call survives with its caller-side span intact"))

(test
  inline-multiblock-switch-cost-refusal
  (test.assert-true
    (ot.compiler-optimize-inline-multiblock-switch-cost-refusal-ok?)
    "multi-site switch callee above the weighted cost threshold stays uninlined"))

(cfg
  test
  (test
    licm-checked-root-disjointness
    (test.assert-i64-eq
      (ot.compiler-optimize-licm-checked-root-self-test)
      42
      "LICM checked-reference root disjointness")))

(test
  dead-store-overwrite
  (test.assert-i64-eq
    (ot.compiler-optimize-dead-store-self-test)
    42
    "dead-store overwrite"))

(test
  bce-version-multiblock-quicksort-shape
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-self-test)
    42
    "multi-block counted-loop bounds-check versioning"))

(test
  bce-version-multiblock-switch-cloning
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-switch-self-test)
    42
    "multi-block versioning remaps total-switch case and trap edges"))

(test
  bce-version-multiblock-second-exit
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-second-exit-self-test)
    42
    "multi-block versioning admits a second exiting branch on the guard chain"))

(test
  bce-version-multiblock-second-exit-boundaries
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-second-exit-refusal-self-test)
    42
    "guard-chain admission keeps chain checks and refuses diamonds and unproven far uses"))

(test
  bce-version-multiblock-far-phi-input
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-far-phi-input-self-test)
    42
    "a phi input out of a block the wire point dominates reads the merge phi"))

(test
  pure-call-dedupe
  (test.assert-i64-eq
    (ot.compiler-optimize-pure-call-dedupe-self-test)
    42
    "a repeated write-free direct call along single-predecessor blocks is a copy"))

(test
  bce-version-multiblock-merged-body
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-merged-body-self-test)
    42
    "multi-block versioning admits an absorbed body's exit join and clones it"))

(test
  bce-version-multiblock-merged-body-boundaries
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-merged-body-refusal-self-test)
    42
    "exit-join admission refuses loop-edge joins, checked joins and outside arms"))

(test
  bce-version-cross-array-fusion
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-fuse-self-test)
    42
    "cross-array fusion removes dominated checks, covered stores included"))

(test
  bce-version-multiblock-rejections
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-negative-self-test)
    42
    "multi-block versioning rejections"))

(test
  bce-version-guard-dominated-fold
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-fold-self-test)
    42
    "versioning guard facts fold dominated compares in the fast clone"))

(test
  bce-version-guard-dominated-fold-refusals
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-fold-refusal-self-test)
    42
    "guard-dominated compare folding refuses everything past its three rules"))

(test
  bce-version-multiblock-loop-nest
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-nest-self-test)
    42
    "multi-block versioning admits loop nests under the nest budget"))

(test
  bce-version-rejection-retires-one-loop
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-reject-skip-self-test)
    42
    "a refused versioning retires that loop, not the function's other loops"))

(test
  bce-version-multiblock-pipeline
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-pipeline-self-test)
    42
    "multi-block versioning full pipeline"))

(test
  unroll-store-free-simd-body
  (test.assert-i64-eq
    (ot.compiler-optimize-unroll-self-test)
    42
    "16x unrolling remaps every admitted store-free SIMD instruction"))

(test
  unroll-descending-shift-two-copies
  (test.assert-i64-eq
    (ot.compiler-optimize-unroll-descending-self-test)
    42
    "descending shift unrolls with a mirrored guard and program-order copies"))

(test
  unroll-load-store-body-two-copies
  (test.assert-i64-eq
    (ot.compiler-optimize-unroll-load-store-self-test)
    42
    "a load-and-store counted loop unrolls twice while a store-only body keeps sixteen"))

(test
  unroll-versioned-multiblock-quicksort-shape
  (test.assert-i64-eq
    (ot.compiler-optimize-unroll-mb-self-test)
    42
    "2x unrolling of the check-free versioned conditional diamond"))

(test
  bce-version-multiblock-partial
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-mb-partial-self-test)
    42
    "multi-block versioning keeps underivable checks in the fast clone"))

(test
  bce-version-p5a-shifted-limits
  (test.assert-i64-eq
    (ot.compiler-optimize-bce-version-p5a-self-test)
    42
    "shifted-limit compares, counter+K indices and the minimized guard version"))

(test
  optimizer-debug-verifier-identity
  (test.assert-i64-eq
    (ot.compiler-optimize-debug-verifier-self-test)
    42
    "IR verifier failures include function, block, and instruction identity"))

(test
  gep-use-splitting
  (test.assert-i64-eq
    (ot.compiler-optimize-gep-split-self-test)
    42
    "Gep use-splitting clones multi-use address Geps per memory use"))

(test
  dce-pack-retirement
  (test.assert-i64-eq
    (ot.compiler-optimize-dce-pack-self-test)
    42
    "Pipeline DCE retires a Pack whose extractions all folded"))

(test
  cmp-sink-to-branch
  (test.assert-i64-eq
    (ot.compiler-optimize-cmp-sink-self-test)
    42
    "Sinking a loop-closing compare next to its branch"))

(test
  load-sink-to-alu-consumer
  (test.assert-i64-eq
    (ot.compiler-optimize-load-sink-self-test)
    42
    "Sinking single-use gep;load pairs next to their consuming ALU ops"))

(test
  cmp-dup-per-branch-copies
  (test.assert-i64-eq
    (ot.compiler-optimize-cmp-dup-self-test)
    42
    "Late compare duplication gives each branch its own fusable compare"))

(test
  single-predecessor-successor-sink
  (test.assert-i64-eq
    (ot.compiler-optimize-successor-sink-self-test)
    42
    "Successor sinking moves pure chains and rejects unsafe CFG/memory/trap cases"))

(test
  if-convert-and-compare-lowering
  (test.assert-i64-eq
    (smoke-c27-if-convert-compare-self-test)
    42
    "IR-only scalar if-conversion and single-use masked-zero lowering"))

(test
  single-bit-mask-test-admission
  (test.assert-i64-eq
    (smoke-c27-mask-test-admission-self-test)
    42
    "Comparing a single-bit mask against itself becomes one inverted bit test"))

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

(test
  bit-test-equality-chain
  (test.assert-i64-eq
    (ot.compiler-optimize-bit-test-equality-self-test)
    42
    "A six-way equality classifier chain becomes one windowed mask test"))

(test
  bit-test-range-chain
  (test.assert-i64-eq
    (ot.compiler-optimize-bit-test-range-self-test)
    42
    "Closed ranges and equalities share one mask over a subtracted base"))

(test
  bit-test-full-window
  (test.assert-i64-eq
    (ot.compiler-optimize-bit-test-full-window-self-test)
    42
    "An equality chain over every value of its window becomes the window guard alone"))

(test
  bit-test-refusals
  (test.assert-i64-eq
    (ot.compiler-optimize-bit-test-refusal-self-test)
    42
    "Mixed values, impure links, wide windows, short chains and unsigned compares are refused"))

(test
  bit-test-runtime-boundaries
  (test.assert-i64-eq
    (ot.compiler-optimize-bit-test-runtime-self-test)
    42
    "The source-level classifier preserves hits, gaps, window edges and out-of-window values"))

(test
  dom-cmp-phi-carried-compare
  (test.assert-i64-eq
    (ot.compiler-optimize-dom-cmp-phi-carried-self-test)
    42
    "a rotated loop's header test folds when both joining edges decide it, and is refused when they disagree or one decides nothing"))

(test
  ubound-narrowed-loop-test
  (test.assert-i64-eq
    (ot.compiler-optimize-ubound-self-test)
    42
    "a multi-path advance loop drops its header check for one unsigned test against min(bound, length), and the rewrite is idempotent"))

(test
  ubound-refusals
  (test.assert-i64-eq
    (ot.compiler-optimize-ubound-refusal-self-test)
    42
    "a missing entry guard, an opaque length, an instruction ahead of the check, a second reader of the loop compare and a negative seed are refused"))

(test
  bounds-group-coalescing
  (test.assert-i64-eq
    (ot.compiler-optimize-bounds-group-self-test)
    42
    "a parallel-array body drops one of its two checks for a single unsigned filter over the smaller length, with the originals kept on a slow arm"))

(test
  bounds-group-offset-coalescing
  (test.assert-i64-eq
    (ot.compiler-optimize-bounds-group-offset-self-test)
    42
    "i and i+1 against one length collapse to one saturating bound"))

(test
  bounds-group-coalescing-refusals
  (test.assert-i64-eq
    (ot.compiler-optimize-bounds-group-refusal-self-test)
    42
    "a body-defined length, a loopless block and an already-split block are refused"))

(test
  bounds-group-negative-literal-coalescing
  (test.assert-i64-eq
    (ot.compiler-optimize-bounds-group-literal-self-test)
    42
    "stack pairs rebase on their smallest offset and literal lengths fold the bound, outside loops and in nested ones"))

(test
  bounds-group-negative-literal-refusals
  (test.assert-i64-eq
    (ot.compiler-optimize-bounds-group-literal-refusal-self-test)
    42
    "a store, call or division between members, an over-cap span and a zero bound are refused"))

(test
  ubound-tangled-phi-web
  (test.assert-i64-eq
    (ot.compiler-optimize-ubound-tangled-self-test)
    42
    "mutually dependent header phis and a three-edge phi terminate the search and are refused"))

(test
  inline-multiblock-bounds-clone-keeps-callee-location
  (test.assert-true
    (ot.compiler-optimize-spans-inline-multiblock-bounds-located-ok?)
    "a BoundsCheck the multiblock with-spans path copies out of a callee keeps the CALLEE's located span -- path id included -- under the clone's freshened ok-label, in an ordinary build as well as under -g, so an abort raised inside an inlined body still names the load in the callee"))

;; A module self-test returns 42 when every check it makes passes; the test
;; name says which one failed.
(define (smoke-require-42 [status : i64]) : unit
  (test.assert-i64-eq status 42 "self-test status"))

(test
  runtime-call-identity
  (smoke-require-42 (ot.compiler-optimize-runtime-call-identity-self-test)))

(test
  thread-facts-merge
  (smoke-require-42 (ot.compiler-optimize-thread-facts-merge-self-test)))

(test
  named-failure-message-renderer
  (test.assert-true
    (smoke-optimizer-named-failure-message-ok?)
    "named failure message renderer"))

(test self-test (smoke-require-42 (ot.compiler-optimize-self-test)))

(test
  dense-storage
  (smoke-require-42 (ot.compiler-optimize-dense-storage-self-test)))

(test noop-int-cast-mov (smoke-require-42 (smoke-noop-int-cast-mov-self-test)))

(test strength (smoke-require-42 (ot.compiler-optimize-strength-self-test)))

(test dce (smoke-require-42 (ot.compiler-optimize-dce-self-test)))

(test dce-mem (smoke-require-42 (ot.compiler-optimize-dce-mem-self-test)))

(test
  divrem-safety
  (smoke-require-42 (ot.compiler-optimize-divrem-safety-self-test)))

(test bit-length (smoke-require-42 (ot.compiler-optimize-bit-length-self-test)))

(test
  const-divisor
  (smoke-require-42 (ot.compiler-optimize-const-divisor-self-test)))

(test copy (smoke-require-42 (ot.compiler-optimize-copy-self-test)))

(test bounds (smoke-require-42 (ot.compiler-optimize-bounds-self-test)))

(test bounds-dom (smoke-require-42 (ot.compiler-optimize-bounds-dom-self-test)))

(test
  bounds-dom-slice-word
  (smoke-require-42 (ot.compiler-optimize-bounds-dom-slice-word-self-test)))

(test
  bounds-dom-addr-taken
  (smoke-require-42 (ot.compiler-optimize-bounds-dom-addr-taken-self-test)))

(test
  range-merge
  (smoke-require-42 (ot.compiler-optimize-range-merge-self-test)))

(test
  nonneg-globals
  (smoke-require-42 (ot.compiler-optimize-nonneg-globals-self-test)))

(test
  dom-cmp-rule-a
  (smoke-require-42 (ot.compiler-optimize-dom-cmp-rule-a-self-test)))

(test
  dom-cmp-rule-a-cfg
  (smoke-require-42 (ot.compiler-optimize-dom-cmp-rule-a-cfg-self-test)))

(test
  dom-cmp-branch-fold
  (smoke-require-42 (ot.compiler-optimize-dom-cmp-branch-fold-self-test)))

(test object-bounds (smoke-require-42 (smoke-object-bounds-self-test)))

(test
  rotated-literal-bce
  (smoke-require-42 (smoke-rotated-literal-bce-self-test)))

(test sccp (smoke-require-42 (ot.compiler-optimize-sccp-self-test)))

(test
  addr-taken-forwarding
  (smoke-require-42 (ot.compiler-optimize-addr-taken-forwarding-self-test)))

(test
  global-value-number
  (smoke-require-42 (ot.compiler-optimize-global-value-number-self-test)))

(test
  load-gvn-substitution
  (smoke-require-42 (ot.compiler-optimize-load-gvn-substitution-self-test)))

(test
  wide-literal-operand
  (smoke-require-42 (ot.compiler-optimize-wide-literal-operand-self-test)))

(test cfg (smoke-require-42 (ot.compiler-optimize-cfg-self-test)))

(test switch-form (smoke-require-42 (compiler-optimize-switch-form-self-test)))

(test
  natural-loop
  (smoke-require-42 (ot.compiler-optimize-natural-loop-self-test)))

(test
  preheader-synthesis
  (smoke-require-42 (ot.compiler-optimize-preheader-synthesis-self-test)))

(test
  bce-shape-clause-order
  (smoke-require-42 (ot.compiler-optimize-bce-shape-clause-order-self-test)))

(test
  bce-masked-capacity
  (smoke-require-42 (ot.compiler-optimize-bce-masked-capacity-self-test)))

(test
  bce-guard-price
  (smoke-require-42 (ot.compiler-optimize-bce-guard-price-self-test)))

(test
  loop-rotation
  (smoke-require-42 (ot.compiler-optimize-loop-rotation-self-test)))

(test rotate-ssa (smoke-require-42 (ot.compiler-optimize-rotate-ssa-self-test)))

(test licm (smoke-require-42 (ot.compiler-optimize-licm-self-test)))

(test
  licm-profitability
  (smoke-require-42 (ot.compiler-optimize-licm-profitability-self-test)))

(test licm-simd (smoke-require-42 (ot.compiler-optimize-licm-simd-self-test)))

(test licm-word (smoke-require-42 (ot.compiler-optimize-licm-word-self-test)))

(test
  licm-local-slot
  (smoke-require-42 (ot.compiler-optimize-licm-local-slot-self-test)))

(test
  licm-unswitch
  (smoke-require-42 (ot.compiler-optimize-licm-unswitch-self-test)))

(test
  licm-unswitch-chain
  (smoke-require-42 (ot.compiler-optimize-licm-unswitch-chain-self-test)))

(test
  licm-unswitch-general
  (smoke-require-42 (ot.compiler-optimize-licm-unswitch-general-self-test)))

(test
  licm-predicate-hoist
  (smoke-require-42 (ot.compiler-optimize-licm-predicate-hoist-self-test)))

(test
  licm-checked-root
  (smoke-require-42 (ot.compiler-optimize-licm-checked-root-self-test)))

(test
  call-memory-frame-roots
  (smoke-require-42 (ot.compiler-optimize-call-memory-frame-roots-self-test)))

(test
  licm-frame-call
  (smoke-require-42 (ot.compiler-optimize-licm-frame-call-self-test)))

(test induction (smoke-require-42 (ot.compiler-optimize-induction-self-test)))

(test
  induction-add-inv
  (smoke-require-42 (ot.compiler-optimize-induction-add-inv-self-test)))

(test lftr (smoke-require-42 (ot.compiler-optimize-lftr-self-test)))

(test lftr-sum (smoke-require-42 (ot.compiler-optimize-lftr-sum-self-test)))

(test
  inline-converted-leaf
  (smoke-require-42 (ot.compiler-optimize-inline-converted-leaf-self-test)))

(test
  affine-env-reference-2
  (smoke-require-42 (ot.compiler-optimize-affine-env-reference-self-test)))

(test
  affine-env-boundary
  (smoke-require-42 (ot.compiler-optimize-affine-env-boundary-self-test)))

(test
  affine-storage-integration-2
  (smoke-require-42 (ot.compiler-optimize-affine-storage-integration-self-test)))

(test affine (smoke-require-42 (ot.compiler-optimize-affine-self-test)))

(test
  affine-pipeline
  (smoke-require-42 (ot.compiler-optimize-affine-pipeline-self-test)))

(test
  ssa-preexisting-phi
  (smoke-require-42 (ot.compiler-optimize-ssa-preexisting-phi-self-test)))

(test
  licm-multi-exit
  (smoke-require-42 (ot.compiler-optimize-licm-multi-exit-self-test)))

(test
  licm-element-bound
  (smoke-require-42 (ot.compiler-optimize-licm-element-bound-self-test)))

(test licm-deref (smoke-require-42 (ot.compiler-optimize-licm-deref-self-test)))

(test
  licm-payload
  (smoke-require-42 (ot.compiler-optimize-licm-payload-self-test)))

(test licm-guard (smoke-require-42 (ot.compiler-optimize-licm-guard-self-test)))

(test
  bce-version
  (smoke-require-42 (ot.compiler-optimize-bce-version-self-test)))

(test
  bce-version-pipeline
  (smoke-require-42 (ot.compiler-optimize-bce-version-pipeline-self-test)))

(test ssa (smoke-require-42 (ot.compiler-optimize-ssa-self-test)))

(test
  ssa-fixed-handle
  (smoke-require-42 (ot.compiler-optimize-ssa-fixed-handle-self-test)))

(test level (smoke-require-42 (ot.compiler-optimize-level-self-test)))

(test callgraph (smoke-require-42 (ot.compiler-optimize-callgraph-self-test)))

(test scc (smoke-require-42 (ot.compiler-optimize-scc-self-test)))

(test inline (smoke-require-42 (ot.compiler-optimize-inline-self-test)))

(test
  fixed-point
  (smoke-require-42 (ot.compiler-optimize-fixed-point-self-test)))

(test tailrec (smoke-require-42 (ot.compiler-optimize-tailrec-self-test)))

(test global-dce (smoke-require-42 (ot.compiler-optimize-global-dce-self-test)))

(test
  aggregate-candidate
  (smoke-require-42 (ot.compiler-optimize-aggregate-candidate-self-test)))

(test
  aggregate-promote
  (smoke-require-42 (ot.compiler-optimize-aggregate-promote-self-test)))

(test
  aggregate-split
  (smoke-require-42 (ot.compiler-optimize-aggregate-split-self-test)))

(test
  group-split
  (smoke-require-42 (ot.compiler-optimize-group-split-self-test)))

(test spans (smoke-require-42 (ot.compiler-optimize-spans-self-test)))

(test gvn (smoke-require-42 (ot.compiler-optimize-gvn-self-test)))

(test
  heavy-pass-large-gvn
  (smoke-require-42 (smoke-heavy-pass-large-gvn-self-test)))

(test
  scratch-region
  (smoke-require-42 (ot.compiler-optimize-scratch-region-self-test)))

(test
  function-index-leaf-starts
  (smoke-require-42 (smoke-function-index-leaf-starts-self-test)))