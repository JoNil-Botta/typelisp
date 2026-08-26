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
(import stdlib.str_cat_runtime as str_cat)
(import compiler_optimize_tests)
(import compiler_optimize as opt)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import stdlib.string)
(import stdlib.test)
(import stdlib.array)

(define (smoke-cfg-index-test-block [label : i64] [value : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    label
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.Return
        (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 value))))))

(define (smoke-cfg-index-block-return [block : opt.OptMaybeBlock]) : i64
  (match block
    [(opt.OptMaybeBlock.No) (- 0 1)]
    [(opt.OptMaybeBlock.Some found)
      (match found
        [(ir.CompilerIrBlock.Block _ instrs)
          (if (= (ir.compiler-ir-instr-seq-count instrs) 1)
            (match (ir.compiler-ir-instr-seq-ref instrs 0)
              [(ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 value)))
                value]
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
      (ir.compiler-ir-block-list-compact
        (ir.compiler-ir-block-cons
          (smoke-cfg-index-test-block label 11)
          (ir.compiler-ir-block-cons
            (smoke-cfg-index-test-block label 22)
            ir.CompilerIrBlockList.Nil)))]
    [index : opt.OptCfgIndex (opt.opt-cfg-index-build blocks)]
    [active-first : i64
      (smoke-cfg-index-block-return (opt.opt-cfg-index-find-block index label))]
    [replacement-blocks : ir.CompilerIrBlockList
      (ir.compiler-ir-block-list-compact
        (ir.compiler-ir-block-cons
          (smoke-cfg-index-test-block label 44)
          (ir.compiler-ir-block-cons
            (smoke-cfg-index-test-block label 55)
            ir.CompilerIrBlockList.Nil)))]
    [_refresh : unit
      (opt.opt-cfg-index-refresh-blocks! index replacement-blocks)]
    [dense-second : i64
      (smoke-cfg-index-block-return (opt.opt-cfg-index-block index 1))]
    [_newer-index : opt.OptCfgIndex
      (opt.opt-cfg-index-build
        (ir.compiler-ir-block-cons
          (smoke-cfg-index-test-block other-label 33)
          ir.CompilerIrBlockList.Nil))]
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
  [instrs : ir.CompilerIrInstrSeq]
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
          [(ir.CompilerIrInstr.Switch _ _ _ _) 1]
          [(ir.CompilerIrInstr.TotalEnumSwitch _ _ _ _ _) 1]
          [_ 0])))))

(define (opt-count-switch-instr-seq [instrs : ir.CompilerIrInstrSeq]) : i64
  (opt-count-switch-instr-seq-from instrs 0 0))

(define (opt-count-switch-blocks [blocks : ir.CompilerIrBlockList]) : i64
  (match blocks
    [(ir.CompilerIrBlockList.Nil) 0]
    [(ir.CompilerIrBlockList.Cons block rest)
      (match block
        [(ir.CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-switch-instr-seq instrs)
            (opt-count-switch-blocks (__tl-box-place rest)))])]
    [(ir.CompilerIrBlockList.Array seq)
      (opt-count-switch-blocks (ir.compiler-ir-block-seq-to-list seq))]))

(define (opt-switch-case-seq-count [cases : ir.CompilerIrSwitchCaseSeq]) : i64
  cases.len)

(define (opt-switch-entry-base [blocks : ir.CompilerIrBlockList]) : i64
  (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "entry"))
    [(opt.OptMaybeBlock.No) (- 0 1)]
    [(opt.OptMaybeBlock.Some block)
      (match block
        [(ir.CompilerIrBlock.Block _ instrs)
          (if (= (ir.compiler-ir-instr-seq-count instrs) 1)
            (match (ir.compiler-ir-instr-seq-ref instrs 0)
              [(ir.CompilerIrInstr.Switch _ base _ _) base]
              [(ir.CompilerIrInstr.TotalEnumSwitch _ base _ _ _) base]
              [_ (- 0 1)])
            (- 0 1))])]))

(define (opt-switch-entry-case-count [blocks : ir.CompilerIrBlockList]) : i64
  (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "entry"))
    [(opt.OptMaybeBlock.No) 0]
    [(opt.OptMaybeBlock.Some block)
      (match block
        [(ir.CompilerIrBlock.Block _ instrs)
          (if (= (ir.compiler-ir-instr-seq-count instrs) 1)
            (match (ir.compiler-ir-instr-seq-ref instrs 0)
              [(ir.CompilerIrInstr.Switch _ _ cases _)
                (opt-switch-case-seq-count cases)]
              [(ir.CompilerIrInstr.TotalEnumSwitch _ _ cases _ _)
                (opt-switch-case-seq-count cases)]
              [_ 0])
            0)])]))

(define (opt-switch-entry-default-label [blocks : ir.CompilerIrBlockList]) : i64
  (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "entry"))
    [(opt.OptMaybeBlock.No) (ir.compiler-ir-label-none)]
    [(opt.OptMaybeBlock.Some block)
      (match block
        [(ir.CompilerIrBlock.Block _ instrs)
          (if (= (ir.compiler-ir-instr-seq-count instrs) 1)
            (match (ir.compiler-ir-instr-seq-ref instrs 0)
              [(ir.CompilerIrInstr.Switch _ _ _ default-label) default-label]
              [(ir.CompilerIrInstr.TotalEnumSwitch _ _ _ default-label _)
                default-label]
              [_ (ir.compiler-ir-label-none)])
            (ir.compiler-ir-label-none))])]))

(define (opt-switch-test-params) : ir.CompilerIrParamList
  (ir.compiler-ir-param-cons
    (ir.CompilerIrParam.Param "tag" (ast.AstType.I64) 0)
    (ir.CompilerIrParamList.Nil)))

(define (opt-switch-test-function [blocks : ir.CompilerIrBlockList]) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (compiler_optimize_tests.opt-test-symbol "switch_form")
    (opt-switch-test-params)
    (ast.AstType.I64)
    16
    blocks))

(define (opt-switch-test-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    label
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        eq-var
        ir.CompilerIrBinOp.Eq
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.I64 tag)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var eq-var)
        arm-label
        next-label))))

(define (opt-switch-test-extra-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    label
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        eq-var
        ir.CompilerIrBinOp.Eq
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.I64 tag)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.Mov 9 (ir.CompilerIrValue.I64 99) (ast.AstType.I64))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var eq-var)
        arm-label
        next-label))))

(define (opt-switch-test-total-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    label
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        eq-var
        ir.CompilerIrBinOp.Eq
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.I64 tag)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.TotalEnumBranch
        (ir.CompilerIrValue.Var eq-var)
        arm-label
        next-label))))

(define (opt-switch-test-return-block [label : i64] [value : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    label
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.Return
        (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 value))))))

;; Head block whose compare+branch trails an unconditional prefix instruction:
;; the chain pass must keep the prefix ahead of the emitted Switch.
(define (opt-switch-test-prefix-compare-block
  [label : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    label
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.Mov 9 (ir.CompilerIrValue.Var 0) (ast.AstType.I64))
      (ir.CompilerIrInstr.BinOp
        eq-var
        ir.CompilerIrBinOp.Eq
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.I64 tag)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var eq-var)
        arm-label
        next-label))))

(define (opt-switch-test-block-tail-base [block : ir.CompilerIrBlock]) : i64
  (match block
    [(ir.CompilerIrBlock.Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1))
        [(ir.CompilerIrInstr.Switch _ base _ _) base]
        [(ir.CompilerIrInstr.TotalEnumSwitch _ base _ _ _) base]
        [_ (- 0 1)])]))

(define (opt-switch-test-block-tail-case-count [block : ir.CompilerIrBlock]) : i64
  (match block
    [(ir.CompilerIrBlock.Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1))
        [(ir.CompilerIrInstr.Switch _ _ cases _)
          (opt-switch-case-seq-count cases)]
        [(ir.CompilerIrInstr.TotalEnumSwitch _ _ cases _ _)
          (opt-switch-case-seq-count cases)]
        [_ 0])]))

(define (opt-switch-test-block-tail-default [block : ir.CompilerIrBlock]) : i64
  (match block
    [(ir.CompilerIrBlock.Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1))
        [(ir.CompilerIrInstr.Switch _ _ _ default-label) default-label]
        [(ir.CompilerIrInstr.TotalEnumSwitch _ _ _ default-label _)
          default-label]
        [_ (ir.compiler-ir-label-none)])]))

(define (opt-switch-test-block-tail-total? [block : ir.CompilerIrBlock]) : bool
  (match block
    [(ir.CompilerIrBlock.Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1))
        [(ir.CompilerIrInstr.TotalEnumSwitch _ _ _ _ _) true]
        [_ false])]))

(define (opt-switch-test-block-starts-with-mov? [block : ir.CompilerIrBlock]) : bool
  (match block
    [(ir.CompilerIrBlock.Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref instrs 0)
        [(ir.CompilerIrInstr.Mov _ _ _) true]
        [_ false])]))

(define (opt-switch-test-cases-have?
  [cases : ir.CompilerIrSwitchCaseSeq]
  [want-tag : i64]
  [want-label : i64]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index cases.len)
        (begin
          (match (ir.compiler-ir-switch-case-seq-ref cases index)
            [(ir.CompilerIrSwitchCase.Case tag label)
              (when (= tag want-tag) (return (= label want-label)))])
          (set! index (+ index 1))))
      false)))

(define (opt-switch-test-block-tail-has-case?
  [block : ir.CompilerIrBlock]
  [tag : i64]
  [label : i64]) : bool
  (match block
    [(ir.CompilerIrBlock.Block _ instrs)
      (match (ir.compiler-ir-instr-seq-ref
        instrs
        (- (ir.compiler-ir-instr-seq-count instrs) 1))
        [(ir.CompilerIrInstr.Switch _ _ cases _)
          (opt-switch-test-cases-have? cases tag label)]
        [(ir.CompilerIrInstr.TotalEnumSwitch _ _ cases _ _)
          (opt-switch-test-cases-have? cases tag label)]
        [_ false])]))

(define (opt-switch-test-total-trap-ok?
  [blocks : ir.CompilerIrBlockList]
  [label : i64]) : bool
  (match (opt.opt-cfg-find-block blocks label)
    [(opt.OptMaybeBlock.No) false]
    [(opt.OptMaybeBlock.Some block)
      (match block
        [(ir.CompilerIrBlock.Block _ instrs)
          (and
            (= (ir.compiler-ir-instr-seq-count instrs) 2)
            (match (ir.compiler-ir-instr-seq-ref instrs 0)
              [(ir.CompilerIrInstr.Call _ name _ _)
                (= name cbi.compiler-builtin-id-tl-oob-abort)]
              [_ false])
            (match (ir.compiler-ir-instr-seq-ref instrs 1)
              [(ir.CompilerIrInstr.Jump target) (= target label)]
              [_ false]))])]))

;; Chain block labels: compare `i` lives in "entry" (i = 0) or "cmp<i>", and
;; its accepting arm in "case<i>". Used by the tag-list chain builder below,
;; which the density-tier and chain-shape cases need at lengths the fixed
;; four-tag builders cannot express.
(define (opt-switch-test-chain-label [i : i64]) : i64
  (if (= i 0)
    (ir.compiler-ir-label "entry")
    (ir.compiler-ir-label (str_cat.str-cat "cmp" (string.int->string i) ""))))

(define (opt-switch-test-arm-label [i : i64]) : i64
  (ir.compiler-ir-label (str_cat.str-cat "case" (string.int->string i) "")))

(define (opt-switch-test-tag-array [count : i64] [first : i64] [last : i64]) : (__tl_dyn-array
    i64)
  ;; `first`, then 1-apart tags, then `last`: exactly `count` tags whose span is
  ;; whatever `last` makes it, so a case can name a span directly.
  (let
    [tags : (__tl_dyn-array i64) (array.make-array i64 count)]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set!
            (array-ref tags i)
            (if (= i (- count 1))
              last
              (+ first i)))
          (set! i (+ i 1))))
      tags)))

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
    (ir.compiler-ir-block-cons
      (opt-switch-test-compare-block
        (opt-switch-test-chain-label (+ start k))
        (array-ref tags k)
        (+ (+ start k) 1)
        (opt-switch-test-arm-label (+ start k))
        (if (= (+ k 1) count)
          next-label
          (opt-switch-test-chain-label (+ (+ start k) 1))))
      (ir.compiler-ir-block-cons
        (opt-switch-test-return-block
          (opt-switch-test-arm-label (+ start k))
          (+ 10 (+ start k)))
        (opt-switch-test-tag-chain-from
          tags
          start
          (+ k 1)
          count
          next-label
          tail)))))

;; A whole function body: `count` compares over the given span, then a
;; returning fallback.
(define (opt-switch-test-span-blocks [count : i64] [first : i64] [last : i64]) : ir.CompilerIrBlockList
  (opt-switch-test-tag-chain-from
    (opt-switch-test-tag-array count first last)
    0
    0
    count
    (ir.compiler-ir-label "fallback")
    (ir.compiler-ir-block-cons
      (opt-switch-test-return-block (ir.compiler-ir-label "fallback") 99)
      (ir.CompilerIrBlockList.Nil))))

(define (opt-switch-test-jump-block [label : i64] [target : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    label
    (compiler_optimize_tests.opt-test-instrs (ir.CompilerIrInstr.Jump target))))

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
    (ir.compiler-ir-block-cons
      (opt-switch-test-jump-block
        (ir.compiler-ir-label "hop")
        (ir.compiler-ir-label "cmp4"))
      (opt-switch-test-tag-chain-from
        (opt-switch-test-tag-array after resume (+ resume (- after 1)))
        4
        0
        after
        (ir.compiler-ir-label "fallback")
        (ir.compiler-ir-block-cons
          (opt-switch-test-return-block (ir.compiler-ir-label "fallback") 99)
          tail)))))

;; The same shape, but a second edge reaches the forwarding block, so the
;; rewrite may not delete it and the chain must stop in front of it.
(define (opt-switch-test-hop-shared-blocks) : ir.CompilerIrBlockList
  (opt-switch-test-hop-blocks
    2
    4
    (ir.compiler-ir-block-cons
      (opt-switch-test-jump-block
        (ir.compiler-ir-label "other")
        (ir.compiler-ir-label "hop"))
      (ir.CompilerIrBlockList.Nil))))

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
      (ir.compiler-ir-block-cons
        (opt-switch-test-return-block (ir.compiler-ir-label "fallback") 99)
        (ir.CompilerIrBlockList.Nil)))))

;; Four compares whose tag-2 arm only forwards to the real arm body. The table
;; entry can name the body directly; when the body opens with a phi it cannot,
;; because the phi has to name the edge it came in on.
(define (opt-switch-test-forwarded-arm-blocks [phi-body? : bool]) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "entry")
      0
      1
      (opt-switch-test-arm-label 0)
      (ir.compiler-ir-label "cmp1"))
    (ir.compiler-ir-block-cons
      (opt-switch-test-return-block (opt-switch-test-arm-label 0) 10)
      (ir.compiler-ir-block-cons
        (opt-switch-test-compare-block
          (ir.compiler-ir-label "cmp1")
          1
          2
          (opt-switch-test-arm-label 1)
          (ir.compiler-ir-label "cmp2"))
        (ir.compiler-ir-block-cons
          (opt-switch-test-return-block (opt-switch-test-arm-label 1) 11)
          (ir.compiler-ir-block-cons
            (opt-switch-test-compare-block
              (ir.compiler-ir-label "cmp2")
              2
              3
              (ir.compiler-ir-label "forward")
              (ir.compiler-ir-label "cmp3"))
            (ir.compiler-ir-block-cons
              (opt-switch-test-jump-block
                (ir.compiler-ir-label "forward")
                (ir.compiler-ir-label "body"))
              (ir.compiler-ir-block-cons
                (if phi-body?
                  (ir.CompilerIrBlock.Block
                    (ir.compiler-ir-label "body")
                    (compiler_optimize_tests.opt-test-instrs
                      (ir.CompilerIrInstr.Phi
                        12
                        (ir.compiler-ir-phi-input-cons
                          (ir.CompilerIrValue.I64 12)
                          (ir.compiler-ir-label "forward")
                          (ir.CompilerIrPhiInputList.Nil))
                        (ast.AstType.I64))
                      (ir.CompilerIrInstr.Return
                        (ir.CompilerIrMaybeValue.Some
                          (ir.CompilerIrValue.Var 12)))))
                  (opt-switch-test-return-block
                    (ir.compiler-ir-label "body")
                    12))
                (ir.compiler-ir-block-cons
                  (opt-switch-test-compare-block
                    (ir.compiler-ir-label "cmp3")
                    3
                    4
                    (opt-switch-test-arm-label 3)
                    (ir.compiler-ir-label "fallback"))
                  (ir.compiler-ir-block-cons
                    (opt-switch-test-return-block
                      (opt-switch-test-arm-label 3)
                      13)
                    (ir.compiler-ir-block-cons
                      (opt-switch-test-return-block
                        (ir.compiler-ir-label "fallback")
                        99)
                      (ir.CompilerIrBlockList.Nil))))))))))))

(define (opt-switch-test-chain-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "entry")
      tag0
      1
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (ir.compiler-ir-block-cons
      (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
      (ir.compiler-ir-block-cons
        (opt-switch-test-compare-block
          (ir.compiler-ir-label "cmp1")
          tag1
          2
          (ir.compiler-ir-label "case1")
          (ir.compiler-ir-label "cmp2"))
        (ir.compiler-ir-block-cons
          (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
          (ir.compiler-ir-block-cons
            (opt-switch-test-compare-block
              (ir.compiler-ir-label "cmp2")
              tag2
              3
              (ir.compiler-ir-label "case2")
              (ir.compiler-ir-label "cmp3"))
            (ir.compiler-ir-block-cons
              (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
              (ir.compiler-ir-block-cons
                (opt-switch-test-compare-block
                  (ir.compiler-ir-label "cmp3")
                  tag3
                  4
                  (ir.compiler-ir-label "case3")
                  default-label)
                (ir.compiler-ir-block-cons
                  (opt-switch-test-return-block
                    (ir.compiler-ir-label "case3")
                    13)
                  (ir.compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (ir.CompilerIrBlockList.Nil)))))))))))

(define (opt-switch-test-total-chain-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (opt-switch-test-total-compare-block
      (ir.compiler-ir-label "entry")
      tag0
      1
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (ir.compiler-ir-block-cons
      (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
      (ir.compiler-ir-block-cons
        (opt-switch-test-total-compare-block
          (ir.compiler-ir-label "cmp1")
          tag1
          2
          (ir.compiler-ir-label "case1")
          (ir.compiler-ir-label "cmp2"))
        (ir.compiler-ir-block-cons
          (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
          (ir.compiler-ir-block-cons
            (opt-switch-test-total-compare-block
              (ir.compiler-ir-label "cmp2")
              tag2
              3
              (ir.compiler-ir-label "case2")
              (ir.compiler-ir-label "cmp3"))
            (ir.compiler-ir-block-cons
              (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
              (ir.compiler-ir-block-cons
                (opt-switch-test-total-compare-block
                  (ir.compiler-ir-label "cmp3")
                  tag3
                  4
                  (ir.compiler-ir-label "case3")
                  default-label)
                (ir.compiler-ir-block-cons
                  (opt-switch-test-return-block
                    (ir.compiler-ir-label "case3")
                    13)
                  (ir.compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (ir.CompilerIrBlockList.Nil)))))))))))

(define (opt-switch-test-short-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (opt-switch-test-compare-block
      (ir.compiler-ir-label "entry")
      0
      1
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (ir.compiler-ir-block-cons
      (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
      (ir.compiler-ir-block-cons
        (opt-switch-test-compare-block
          (ir.compiler-ir-label "cmp1")
          1
          2
          (ir.compiler-ir-label "case1")
          (ir.compiler-ir-label "cmp2"))
        (ir.compiler-ir-block-cons
          (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
          (ir.compiler-ir-block-cons
            (opt-switch-test-compare-block
              (ir.compiler-ir-label "cmp2")
              2
              3
              (ir.compiler-ir-label "case2")
              (ir.compiler-ir-label "fallback"))
            (ir.compiler-ir-block-cons
              (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
              (ir.compiler-ir-block-cons
                (opt-switch-test-return-block
                  (ir.compiler-ir-label "fallback")
                  99)
                (ir.CompilerIrBlockList.Nil)))))))))

(define (opt-switch-test-extra-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (opt-switch-test-extra-compare-block
      (ir.compiler-ir-label "entry")
      0
      1
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (ir.compiler-ir-block-cons
      (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
      (ir.compiler-ir-block-cons
        (opt-switch-test-compare-block
          (ir.compiler-ir-label "cmp1")
          1
          2
          (ir.compiler-ir-label "case1")
          (ir.compiler-ir-label "cmp2"))
        (ir.compiler-ir-block-cons
          (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
          (ir.compiler-ir-block-cons
            (opt-switch-test-compare-block
              (ir.compiler-ir-label "cmp2")
              2
              3
              (ir.compiler-ir-label "case2")
              (ir.compiler-ir-label "cmp3"))
            (ir.compiler-ir-block-cons
              (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
              (ir.compiler-ir-block-cons
                (opt-switch-test-compare-block
                  (ir.compiler-ir-label "cmp3")
                  3
                  4
                  (ir.compiler-ir-label "case3")
                  (ir.compiler-ir-label "fallback"))
                (ir.compiler-ir-block-cons
                  (opt-switch-test-return-block
                    (ir.compiler-ir-label "case3")
                    13)
                  (ir.compiler-ir-block-cons
                    (opt-switch-test-return-block
                      (ir.compiler-ir-label "fallback")
                      99)
                    (ir.CompilerIrBlockList.Nil)))))))))))

(define (opt-switch-test-prefix-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (opt-switch-test-prefix-compare-block
      (ir.compiler-ir-label "entry")
      tag0
      1
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (ir.compiler-ir-block-cons
      (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
      (ir.compiler-ir-block-cons
        (opt-switch-test-compare-block
          (ir.compiler-ir-label "cmp1")
          tag1
          2
          (ir.compiler-ir-label "case1")
          (ir.compiler-ir-label "cmp2"))
        (ir.compiler-ir-block-cons
          (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
          (ir.compiler-ir-block-cons
            (opt-switch-test-compare-block
              (ir.compiler-ir-label "cmp2")
              tag2
              3
              (ir.compiler-ir-label "case2")
              (ir.compiler-ir-label "cmp3"))
            (ir.compiler-ir-block-cons
              (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
              (ir.compiler-ir-block-cons
                (opt-switch-test-compare-block
                  (ir.compiler-ir-label "cmp3")
                  tag3
                  4
                  (ir.compiler-ir-label "case3")
                  default-label)
                (ir.compiler-ir-block-cons
                  (opt-switch-test-return-block
                    (ir.compiler-ir-label "case3")
                    13)
                  (ir.compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (ir.CompilerIrBlockList.Nil)))))))))))

;; Head block whose dispatch is a bare zero-test branch (`Eq tag, 0` folded
;; onto the tag var), again trailing an unconditional prefix instruction.
(define (opt-switch-test-bare-branch-block
  [label : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    label
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.Mov 9 (ir.CompilerIrValue.Var 0) (ast.AstType.I64))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var 0)
        next-label
        arm-label))))

(define (opt-switch-test-bare-blocks [default-label : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (opt-switch-test-bare-branch-block
      (ir.compiler-ir-label "entry")
      (ir.compiler-ir-label "case0")
      (ir.compiler-ir-label "cmp1"))
    (ir.compiler-ir-block-cons
      (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
      (ir.compiler-ir-block-cons
        (opt-switch-test-compare-block
          (ir.compiler-ir-label "cmp1")
          1
          2
          (ir.compiler-ir-label "case1")
          (ir.compiler-ir-label "cmp2"))
        (ir.compiler-ir-block-cons
          (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
          (ir.compiler-ir-block-cons
            (opt-switch-test-compare-block
              (ir.compiler-ir-label "cmp2")
              2
              3
              (ir.compiler-ir-label "case2")
              (ir.compiler-ir-label "cmp3"))
            (ir.compiler-ir-block-cons
              (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
              (ir.compiler-ir-block-cons
                (opt-switch-test-compare-block
                  (ir.compiler-ir-label "cmp3")
                  3
                  4
                  (ir.compiler-ir-label "case3")
                  default-label)
                (ir.compiler-ir-block-cons
                  (opt-switch-test-return-block
                    (ir.compiler-ir-label "case3")
                    13)
                  (ir.compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (ir.CompilerIrBlockList.Nil)))))))))))

;; Compare block testing an explicit compare var (for copy-resolution tests).
(define (opt-switch-test-compare-block-var
  [label : i64]
  [cmp-var : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : i64]
  [next-label : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    label
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        eq-var
        ir.CompilerIrBinOp.Eq
        (ir.CompilerIrValue.Var cmp-var)
        (ir.CompilerIrValue.I64 tag)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var eq-var)
        arm-label
        next-label))))

;; The vm_run dispatch shape: the head compare reads the RAW tag var while the
;; middle compares read the match-scrutinee COPY (block-local copy propagation
;; rewrites same-block operands only). The chain must resolve both through the
;; head prefix's Mov to one logical index var.
(define (opt-switch-test-copy-head-blocks [default-label : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "entry")
      (compiler_optimize_tests.opt-test-instrs
        (ir.CompilerIrInstr.Mov 9 (ir.CompilerIrValue.Var 0) (ast.AstType.I64))
        (ir.CompilerIrInstr.BinOp
          1
          ir.CompilerIrBinOp.Eq
          (ir.CompilerIrValue.Var 0)
          (ir.CompilerIrValue.I64 0)
          (ast.AstType.I64))
        (ir.CompilerIrInstr.Branch
          (ir.CompilerIrValue.Var 1)
          (ir.compiler-ir-label "case0")
          (ir.compiler-ir-label "cmp1"))))
    (ir.compiler-ir-block-cons
      (opt-switch-test-return-block (ir.compiler-ir-label "case0") 10)
      (ir.compiler-ir-block-cons
        (opt-switch-test-compare-block-var
          (ir.compiler-ir-label "cmp1")
          9
          1
          2
          (ir.compiler-ir-label "case1")
          (ir.compiler-ir-label "cmp2"))
        (ir.compiler-ir-block-cons
          (opt-switch-test-return-block (ir.compiler-ir-label "case1") 11)
          (ir.compiler-ir-block-cons
            (opt-switch-test-compare-block-var
              (ir.compiler-ir-label "cmp2")
              9
              2
              3
              (ir.compiler-ir-label "case2")
              (ir.compiler-ir-label "cmp3"))
            (ir.compiler-ir-block-cons
              (opt-switch-test-return-block (ir.compiler-ir-label "case2") 12)
              (ir.compiler-ir-block-cons
                (opt-switch-test-compare-block-var
                  (ir.compiler-ir-label "cmp3")
                  9
                  3
                  4
                  (ir.compiler-ir-label "case3")
                  default-label)
                (ir.compiler-ir-block-cons
                  (opt-switch-test-return-block
                    (ir.compiler-ir-label "case3")
                    13)
                  (ir.compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (ir.CompilerIrBlockList.Nil)))))))))))

(define (compiler-optimize-switch-form-self-test) : i64
  (let
    [dense-source : ir.CompilerIrBlockList
      (opt-switch-test-chain-blocks 2 0 1 3 (ir.compiler-ir-label "fallback"))]
    [dense : ir.CompilerIrFunction
      (opt.opt-switch-form-function (opt-switch-test-function dense-source))]
    [dense-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks dense)]
    [short : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-short-blocks)))]
    ;; Gapped but above the density floor: tags 0,1,3,4 span five slots for four
    ;; compares, so the table forms and tag 2 takes the chain's fall-through.
    [sparse : ir.CompilerIrFunction
      (opt.opt-switch-form-function
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
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    ;; Below the density floor: four compares over a span of twenty-one would
    ;; pay seventeen dead table slots, so the chain stays a compare chain.
    [too-sparse : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks
            0
            1
            2
            20
            (ir.compiler-ir-label "fallback"))))]
    [duplicate : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks
            0
            1
            1
            2
            (ir.compiler-ir-label "fallback"))))]
    [extra : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-extra-blocks)))]
    [prefix : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-prefix-blocks
            2
            0
            1
            3
            (ir.compiler-ir-label "fallback"))))]
    [prefix-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks prefix)]
    [prefix-twice : ir.CompilerIrFunction (opt.opt-switch-form-function prefix)]
    [prefix-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        prefix-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    [bare : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-bare-blocks (ir.compiler-ir-label "fallback"))))]
    [bare-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks bare)]
    [bare-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block bare-blocks (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    [copy-head : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-copy-head-blocks (ir.compiler-ir-label "fallback"))))]
    [copy-head-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks copy-head)]
    [copy-head-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        copy-head-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    [total-final-label : i64
      (ir.compiler-ir-label "match_total_enum_default.4")]
    [total-trap-label : i64 (ir.compiler-ir-label "match_total_trap__entry")]
    [total : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-total-chain-blocks 0 1 2 3 total-final-label)))]
    [total-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks total)]
    [total-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        total-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    [total-late : ir.CompilerIrFunction
      (opt.opt-late-total-switch-function
        (ast.ast-node-pool-reader-type-segment-bases)
        total)]
    [total-late-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks total-late)]
    [total-late-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        total-late-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    [total-twice : ir.CompilerIrFunction
      (opt.opt-late-total-switch-function
        (ast.ast-node-pool-reader-type-segment-bases)
        total-late)]
    [cloned-total : ir.CompilerIrInstr
      (opt.opt-inline-clone-multiblock-instr
        (ir.CompilerIrInstr.TotalEnumSwitch
          (ir.CompilerIrValue.Var 9)
          0
          (ir.compiler-ir-switch-case-seq1
            (ir.CompilerIrSwitchCase.Case 0 (ir.compiler-ir-label "arm")))
          (ir.compiler-ir-label "default")
          (ir.compiler-ir-label "trap"))
        "cloned"
        (ir.CompilerIrCallArgs.Nil)
        0
        10)]
    [cloned-pending-total : ir.CompilerIrInstr
      (opt.opt-inline-clone-multiblock-instr
        (ir.CompilerIrInstr.TotalEnumSwitch
          (ir.CompilerIrValue.Var 9)
          0
          (ir.compiler-ir-switch-case-seq1
            (ir.CompilerIrSwitchCase.Case 0 (ir.compiler-ir-label "arm")))
          (ir.compiler-ir-label "default")
          (ir.compiler-ir-label-none))
        "pending"
        (ir.CompilerIrCallArgs.Nil)
        0
        10)]
    [preheader-forwarded-total : ir.CompilerIrInstr
      (opt.opt-loop-preheaders-retarget-instr
        (ir.CompilerIrInstr.TotalEnumSwitch
          (ir.CompilerIrValue.Var 9)
          0
          (ir.compiler-ir-switch-case-seq1
            (ir.CompilerIrSwitchCase.Case 0 (ir.compiler-ir-label "arm")))
          (ir.compiler-ir-label "trap")
          (ir.compiler-ir-label "trap"))
        (ir.compiler-ir-label "trap")
        (ir.compiler-ir-label "preheader"))]
    ;; Display spellings are deliberately identical to the old protocol. An
    ;; ordinary chain using them must remain an ordinary checked Switch.
    [spoofed : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks 0 1 2 3 total-final-label)))]
    [spoofed-late : ir.CompilerIrFunction
      (opt.opt-late-total-switch-function
        (ast.ast-node-pool-reader-type-segment-bases)
        spoofed)]
    [spoofed-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks spoofed-late)]
    [spoofed-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        spoofed-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    [marked-sparse-final-label : i64
      (ir.compiler-ir-label "match_total_enum_default.sparse")]
    [marked-sparse : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-total-chain-blocks 0 1 3 4 marked-sparse-final-label)))]
    [marked-sparse-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks marked-sparse)]
    [marked-sparse-late : ir.CompilerIrFunction
      (opt.opt-late-total-switch-function
        (ast.ast-node-pool-reader-type-segment-bases)
        marked-sparse)]
    [marked-sparse-late-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks marked-sparse-late)]
    [marked-sparse-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        marked-sparse-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    [level1 : ir.CompilerIrFunction
      (opt.optimize-function-with-level
        (ast.ast-node-pool-reader-context-current)
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt-switch-test-function dense-source)
        1)]
    [level2 : ir.CompilerIrFunction
      (opt.optimize-function-with-level
        (ast.ast-node-pool-reader-context-current)
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt-switch-test-function dense-source)
        2)]
    ;; Density tiers. Eight compares are enough that the walk dominates, so
    ;; they may span 66 slots (12%); one slot more, or one compare fewer at the
    ;; same shape, falls back to the 50% floor and stays a chain.
    [long-sparse : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-span-blocks 8 0 65)))]
    [long-sparse-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        (opt.opt-function-blocks long-sparse)
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    [long-too-sparse : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-span-blocks 8 0 66)))]
    [short-sparse : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-span-blocks 7 0 57)))]
    ;; An empty forwarding block between two halves of one chain: the table
    ;; spans both halves and the block is gone.
    [hop : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-hop-blocks 2 4 (ir.CompilerIrBlockList.Nil))))]
    [hop-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks hop)]
    [hop-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block hop-blocks (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    ;; Reaching across the forwarding block would push the span to 0..80 for
    ;; five compares, below the short-chain floor. The four in front of it
    ;; still form their table, and the forwarding block becomes its default.
    [hop-fallback : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-hop-blocks 1 80 (ir.CompilerIrBlockList.Nil))))]
    [hop-fallback-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks hop-fallback)]
    [hop-twice : ir.CompilerIrFunction (opt.opt-switch-form-function hop)]
    [hop-twice-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        (opt.opt-function-blocks hop-twice)
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    [hop-fallback-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        hop-fallback-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    ;; A second edge reaches the forwarding block, so it must survive and the
    ;; chain has to stop in front of it.
    [hop-shared : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-hop-shared-blocks)))]
    [hop-shared-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks hop-shared)]
    [hop-shared-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        hop-shared-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    ;; A repeated tag cannot join the table, but it may not cost the four
    ;; compares in front of it their table either.
    [repeat-tag : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-repeat-tag-blocks)))]
    [repeat-tag-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks repeat-tag)]
    [repeat-tag-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        repeat-tag-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    ;; An arm that only forwards: the table entry names the body it forwards
    ;; to, unless the body opens with a phi that has to name its edge.
    [forwarded-arm : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-forwarded-arm-blocks false)))]
    [forwarded-arm-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks forwarded-arm)]
    [forwarded-arm-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        forwarded-arm-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    [forwarded-phi-arm : ir.CompilerIrFunction
      (opt.opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-forwarded-arm-blocks true)))]
    [forwarded-phi-arm-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks forwarded-phi-arm)]
    [forwarded-phi-arm-entry : ir.CompilerIrBlock
      (match (opt.opt-cfg-find-block
        forwarded-phi-arm-blocks
        (ir.compiler-ir-label "entry"))
        [(opt.OptMaybeBlock.No)
          (opt-switch-test-return-block (ir.compiler-ir-label "missing") 0)]
        [(opt.OptMaybeBlock.Some block) block])]
    (cond
      [(not (= (opt-count-switch-blocks dense-blocks) 1)) 1]
      [(not (= (opt-switch-entry-base dense-blocks) 0)) 2]
      [(not (= (opt-switch-entry-case-count dense-blocks) 4)) 3]
      [(not
          (=
            (opt-switch-entry-default-label dense-blocks)
            (ir.compiler-ir-label "fallback")))
        4]
      [(compiler_optimize_tests.opt-block-list-has-label?
          dense-blocks
          (ir.compiler-ir-label "cmp1"))
        5]
      [(compiler_optimize_tests.opt-block-list-has-label?
          dense-blocks
          (ir.compiler-ir-label "cmp2"))
        6]
      [(compiler_optimize_tests.opt-block-list-has-label?
          dense-blocks
          (ir.compiler-ir-label "cmp3"))
        7]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function dense))) 8]
      [(not (= (opt-count-switch-blocks (opt.opt-function-blocks short)) 0)) 9]
      ;; A gap inside an admissible span becomes a table slot pointing at the
      ;; chain's own fall-through, which is where that tag went before.
      [(not (= (opt-count-switch-blocks sparse-blocks) 1)) 10]
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
          (= (opt-count-switch-blocks (opt.opt-function-blocks too-sparse)) 0))
        62]
      [(not (= (opt-count-switch-blocks (opt.opt-function-blocks duplicate)) 0))
        11]
      [(not (= (opt-count-switch-blocks (opt.opt-function-blocks extra)) 0)) 12]
      [(not (= (opt-count-switch-blocks (opt.opt-function-blocks level1)) 0))
        13]
      [(not (= (opt-count-switch-blocks (opt.opt-function-blocks level2)) 1))
        14]
      ;; A prefix head keeps its unconditional instructions ahead of the
      ;; Switch; the consumed middle compare blocks still disappear.
      [(not (= (opt-count-switch-blocks prefix-blocks) 1)) 15]
      [(not (= (opt-switch-test-block-tail-base prefix-entry) 0)) 16]
      [(not (= (opt-switch-test-block-tail-case-count prefix-entry) 4)) 17]
      [(not
          (=
            (opt-switch-test-block-tail-default prefix-entry)
            (ir.compiler-ir-label "fallback")))
        18]
      [(not (opt-switch-test-block-starts-with-mov? prefix-entry)) 19]
      [(compiler_optimize_tests.opt-block-list-has-label?
          prefix-blocks
          (ir.compiler-ir-label "cmp1"))
        20]
      [(compiler_optimize_tests.opt-block-list-has-label?
          prefix-blocks
          (ir.compiler-ir-label "cmp2"))
        21]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function prefix))) 22]
      ;; Idempotence: rerunning the pass must not rewrite the rewritten head.
      [(not
          (= (opt-count-switch-blocks (opt.opt-function-blocks prefix-twice)) 1))
        23]
      ;; A bare zero-test head (`Branch(tag, next, arm)`) is the folded
      ;; `Eq tag, 0` form and must join the chain as the tag-0 candidate.
      [(not (= (opt-count-switch-blocks bare-blocks) 1)) 24]
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
      [(not (= (opt-count-switch-blocks copy-head-blocks) 1)) 30]
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
      [(not (= (opt-count-switch-blocks total-blocks) 1)) 36]
      [(not (opt-switch-test-block-tail-total? total-entry)) 52]
      [(not (= (opt-switch-test-block-tail-base total-entry) 0)) 37]
      [(not (= (opt-switch-test-block-tail-case-count total-entry) 4)) 38]
      [(not
          (= (opt-switch-test-block-tail-default total-entry) total-final-label))
        39]
      [(compiler_optimize_tests.opt-block-list-has-label?
          total-blocks
          total-trap-label)
        40]
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
      [(not (opt.opt-verify-ok? (opt.opt-verify-function total-late))) 48]
      [(not
          (= (opt-count-switch-blocks (opt.opt-function-blocks total-twice)) 1))
        49]
      ;; Old display spellings are not authority without the explicit proof.
      [(opt-switch-test-block-tail-total? spoofed-entry) 53]
      [(not (= (opt-switch-test-block-tail-case-count spoofed-entry) 4)) 54]
      [(not
          (=
            (opt-switch-test-block-tail-default spoofed-entry)
            total-final-label))
        55]
      [(compiler_optimize_tests.opt-block-list-has-label?
          spoofed-blocks
          total-trap-label)
        56]
      ;; An explicit proof alone is not enough to drop the range check: a gapped
      ;; chain routes its gaps to the fall-through, so the proof's "fall-through
      ;; IS the final variant" reading no longer holds. The chain still forms a
      ;; table, but as an ordinary checked Switch, and the late total pass must
      ;; therefore add neither a final case nor a trap block.
      [(not (= (opt-count-switch-blocks marked-sparse-blocks) 1)) 50]
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
      [(compiler_optimize_tests.opt-block-list-has-label?
          marked-sparse-late-blocks
          (ir.compiler-ir-label "match_total_trap__entry"))
        51]
      ;; Multiblock inlining preserves the closed proof variant while
      ;; deliberately remapping every real label. The none trap sentinel on a
      ;; pending switch must remain a sentinel rather than becoming a label.
      [(not
          (match cloned-total
            [(ir.CompilerIrInstr.TotalEnumSwitch
                (ir.CompilerIrValue.Var value)
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
                  (ir.compiler-ir-label "cloned.arm"))
                (= default-label (ir.compiler-ir-label "cloned.default"))
                (= trap-label (ir.compiler-ir-label "cloned.trap")))]
            [_ false]))
        57]
      [(not
          (match cloned-pending-total
            [(ir.CompilerIrInstr.TotalEnumSwitch _ _ _ default-label trap-label)
              (and
                (= default-label (ir.compiler-ir-label "pending.default"))
                (= trap-label (ir.compiler-ir-label-none)))]
            [_ false]))
        58]
      [(not
          (match preheader-forwarded-total
            [(ir.CompilerIrInstr.TotalEnumSwitch _ _ _ default-label trap-label)
              (and
                (= default-label (ir.compiler-ir-label "preheader"))
                (= trap-label (ir.compiler-ir-label "trap")))]
            [_ false]))
        59]
      ;; Density tiers, two-sided. Eight compares afford a 66-slot span (12%);
      ;; a 67-slot span at eight compares, and a 58-slot span at seven, are
      ;; both back under the 50% floor and stay chains.
      [(not
          (= (opt-count-switch-blocks (opt.opt-function-blocks long-sparse)) 1))
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
            (opt-count-switch-blocks (opt.opt-function-blocks long-too-sparse))
            0))
        76]
      [(not
          (= (opt-count-switch-blocks (opt.opt-function-blocks short-sparse)) 0))
        77]
      ;; One empty forwarding block between the halves of one chain: six
      ;; compares, one table, and the forwarding block is gone with them.
      [(not (= (opt-count-switch-blocks hop-blocks) 1)) 78]
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
      [(compiler_optimize_tests.opt-block-list-has-label?
          hop-blocks
          (ir.compiler-ir-label "hop"))
        83]
      [(compiler_optimize_tests.opt-block-list-has-label?
          hop-blocks
          (ir.compiler-ir-label "cmp4"))
        84]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function hop))) 85]
      ;; Idempotence: the fused head is a Switch, not a compare, so a second
      ;; run finds nothing left to fuse.
      [(not (= (opt-count-switch-blocks (opt.opt-function-blocks hop-twice)) 1))
        109]
      [(not (= (opt-switch-test-block-tail-case-count hop-twice-entry) 6)) 110]
      ;; Reaching across it must never cost the chain the table it already had.
      [(not (= (opt-count-switch-blocks hop-fallback-blocks) 1)) 86]
      [(not (= (opt-switch-test-block-tail-case-count hop-fallback-entry) 4))
        87]
      [(not
          (=
            (opt-switch-test-block-tail-default hop-fallback-entry)
            (ir.compiler-ir-label "hop")))
        88]
      [(not
          (compiler_optimize_tests.opt-block-list-has-label?
            hop-fallback-blocks
            (ir.compiler-ir-label "hop")))
        89]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function hop-fallback))) 90]
      ;; A forwarding block something else also reaches cannot be deleted, so
      ;; the chain stops in front of it and it stays where it is.
      [(not (= (opt-count-switch-blocks hop-shared-blocks) 1)) 91]
      [(not (= (opt-switch-test-block-tail-case-count hop-shared-entry) 4)) 92]
      [(not
          (=
            (opt-switch-test-block-tail-default hop-shared-entry)
            (ir.compiler-ir-label "hop")))
        93]
      [(not
          (compiler_optimize_tests.opt-block-list-has-label?
            hop-shared-blocks
            (ir.compiler-ir-label "hop")))
        94]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function hop-shared))) 95]
      ;; A repeated tag stops the chain instead of refusing it.
      [(not (= (opt-count-switch-blocks repeat-tag-blocks) 1)) 96]
      [(not (= (opt-switch-test-block-tail-case-count repeat-tag-entry) 4)) 97]
      [(not
          (=
            (opt-switch-test-block-tail-default repeat-tag-entry)
            (ir.compiler-ir-label "cmp4")))
        98]
      [(not
          (compiler_optimize_tests.opt-block-list-has-label?
            repeat-tag-blocks
            (ir.compiler-ir-label "cmp4")))
        99]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function repeat-tag))) 100]
      ;; A forwarding arm is followed to the body it forwards to; the empty
      ;; block goes with the chain.
      [(not (= (opt-count-switch-blocks forwarded-arm-blocks) 1)) 101]
      [(not
          (opt-switch-test-block-tail-has-case?
            forwarded-arm-entry
            2
            (ir.compiler-ir-label "body")))
        102]
      [(compiler_optimize_tests.opt-block-list-has-label?
          forwarded-arm-blocks
          (ir.compiler-ir-label "forward"))
        103]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function forwarded-arm))) 104]
      ;; A phi in the body has to name the edge it came in on, so that
      ;; forwarding block stays and the case keeps naming it.
      [(not (= (opt-count-switch-blocks forwarded-phi-arm-blocks) 1)) 105]
      [(not
          (opt-switch-test-block-tail-has-case?
            forwarded-phi-arm-entry
            2
            (ir.compiler-ir-label "forward")))
        106]
      [(not
          (compiler_optimize_tests.opt-block-list-has-label?
            forwarded-phi-arm-blocks
            (ir.compiler-ir-label "forward")))
        107]
      [(not (opt.opt-verify-ok? (opt.opt-verify-function forwarded-phi-arm)))
        108]
      [else 42])))

(define (smoke-mov-dst-var-type-from?
  [instrs : ir.CompilerIrInstrSeq]
  [index : i64]
  [dst : i64]
  [src : i64]
  [ty : ast.AstType]) : bool
  (if (>= index (ir.compiler-ir-instr-seq-count instrs))
    false
    (match (ir.compiler-ir-instr-seq-ref instrs index)
      [(ir.CompilerIrInstr.Mov d (ir.CompilerIrValue.Var s) mov-ty)
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
  [instrs : ir.CompilerIrInstrSeq]
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
      [(ir.CompilerIrInstr.Cast d (ir.CompilerIrValue.Var s) cast-from cast-to)
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
  (compiler_optimize_tests.opt-test-instrs
    (ir.CompilerIrInstr.Cast
      50
      (ir.CompilerIrValue.Var 10)
      (ast.AstType.U8)
      (ast.AstType.Char))
    (ir.CompilerIrInstr.Cast
      51
      (ir.CompilerIrValue.Var 11)
      (ast.AstType.U16)
      (ast.AstType.U8))
    (ir.CompilerIrInstr.Cast
      52
      (ir.CompilerIrValue.Var 12)
      (ast.AstType.U16)
      (ast.AstType.Char))
    (ir.CompilerIrInstr.Cast
      53
      (ir.CompilerIrValue.Var 13)
      (ast.AstType.U8)
      (ast.AstType.I64))
    (ir.CompilerIrInstr.Cast
      54
      (ir.CompilerIrValue.Var 14)
      (ast.AstType.I16)
      (ast.AstType.U32))
    (ir.CompilerIrInstr.Cast
      55
      (ir.CompilerIrValue.Var 15)
      (ast.AstType.I64)
      (ast.AstType.U64))))

(define (smoke-noop-int-cast-mov-self-test) : i64
  (let
    [rewritten : ir.CompilerIrInstrSeq
      (compiler_optimize_tests.opt-test-fold-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt.OptConstEnv.Nil)
        (smoke-noop-int-cast-mov-instrs))]
    (begin
      (unless
        (= (compiler_optimize_tests.opt-count-cast-instr-seq rewritten) 3)
        (return 1))
      (unless
        (smoke-mov-dst-var-type? rewritten 50 10 (ast.AstType.Char))
        (return 2))
      (unless
        (smoke-mov-dst-var-type? rewritten 51 11 (ast.AstType.U8))
        (return 3))
      (unless
        (smoke-mov-dst-var-type? rewritten 52 12 (ast.AstType.Char))
        (return 4))
      (unless
        (smoke-cast-dst-var-types?
          rewritten
          55
          15
          (ast.AstType.I64)
          (ast.AstType.U64))
        (return 5))
      42)))

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
  (compiler_optimize_tests.opt-test-instrs-with-tail
    tail
    (ir.CompilerIrInstr.Gep ptr-var object offset slot-ty)
    (ir.CompilerIrInstr.Load
      length-var
      (ir.CompilerIrValue.Var ptr-var)
      (ast.AstType.I64))
    (ir.CompilerIrInstr.Cast
      cast-var
      (ir.CompilerIrValue.Var length-var)
      (ast.AstType.I64)
      (ast.AstType.U64))
    (ir.CompilerIrInstr.BoundsCheck
      index
      (ir.CompilerIrValue.Var cast-var)
      label)))

(define (smoke-bounds-object-pair
  [second-object : ir.CompilerIrValue]
  [offset : ir.CompilerIrValue]
  [slot-ty : ast.AstType]) : ir.CompilerIrInstrSeq
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (ir.CompilerIrValue.Var 1)
    offset
    slot-ty
    (ir.CompilerIrValue.Var 0)
    (ir.compiler-ir-label "bounds_ok.0")
    (smoke-bounds-object-length-check-fragment
      20
      21
      22
      second-object
      offset
      slot-ty
      (ir.CompilerIrValue.Var 0)
      (ir.compiler-ir-label "bounds_ok.1")
      (ir.compiler-ir-instr-seq-empty))))

(define (smoke-bounds-object-call-barrier) : ir.CompilerIrInstrSeq
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (ir.CompilerIrValue.Var 1)
    (ir.CompilerIrValue.I64 1)
    (ast.AstType.I64)
    (ir.CompilerIrValue.Var 0)
    (ir.compiler-ir-label "bounds_ok.0")
    (compiler_optimize_tests.opt-test-instrs-with-tail
      (smoke-bounds-object-length-check-fragment
        20
        21
        22
        (ir.CompilerIrValue.Var 1)
        (ir.CompilerIrValue.I64 1)
        (ast.AstType.I64)
        (ir.CompilerIrValue.Var 0)
        (ir.compiler-ir-label "bounds_ok.1")
        (ir.compiler-ir-instr-seq-empty))
      (ir.CompilerIrInstr.Call
        30
        (compiler_optimize_tests.opt-test-symbol "touch")
        (ir.CompilerIrCallArgs.Nil)
        (ast.AstType.Unit)))))

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
    (ir.CompilerIrValue.Var 1)
    (ir.CompilerIrValue.I64 1)
    (ast.AstType.I64)
    (ir.CompilerIrValue.Var 0)
    (ir.compiler-ir-label "bounds_ok.0")
    (compiler_optimize_tests.opt-test-instrs-with-tail
      (smoke-bounds-object-length-check-fragment
        20
        21
        22
        (ir.CompilerIrValue.Var 1)
        (ir.CompilerIrValue.I64 1)
        (ast.AstType.I64)
        (ir.CompilerIrValue.Var 0)
        (ir.compiler-ir-label "bounds_ok.1")
        (ir.compiler-ir-instr-seq-empty))
      (ir.CompilerIrInstr.StorePtr
        store-ptr
        (ir.CompilerIrValue.I64 7)
        (ast.AstType.I64)))))

(define (smoke-object-bounds-self-test) : i64
  (let
    [object-array : ir.CompilerIrInstrSeq
      (compiler_optimize_tests.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt.OptBoundsFacts.Nil)
        (opt.OptBoundsCastEnv.Empty)
        (smoke-bounds-object-pair
          (ir.CompilerIrValue.Var 1)
          (ir.CompilerIrValue.I64 1)
          (ast.AstType.I64)))]
    [object-string : ir.CompilerIrInstrSeq
      (compiler_optimize_tests.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt.OptBoundsFacts.Nil)
        (opt.OptBoundsCastEnv.Empty)
        (smoke-bounds-object-pair
          (ir.CompilerIrValue.Var 1)
          (ir.CompilerIrValue.I64 8)
          (ast.AstType.U8)))]
    [object-mismatch : ir.CompilerIrInstrSeq
      (compiler_optimize_tests.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt.OptBoundsFacts.Nil)
        (opt.OptBoundsCastEnv.Empty)
        (smoke-bounds-object-pair
          (ir.CompilerIrValue.Var 2)
          (ir.CompilerIrValue.I64 1)
          (ast.AstType.I64)))]
    [object-call : ir.CompilerIrInstrSeq
      (compiler_optimize_tests.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt.OptBoundsFacts.Nil)
        (opt.OptBoundsCastEnv.Empty)
        (smoke-bounds-object-call-barrier))]
    [object-store : ir.CompilerIrInstrSeq
      (compiler_optimize_tests.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt.OptBoundsFacts.Nil)
        (opt.OptBoundsCastEnv.Empty)
        (smoke-bounds-object-store-barrier (ir.CompilerIrValue.Var 10)))]
    [object-element-store : ir.CompilerIrInstrSeq
      (compiler_optimize_tests.opt-test-bounds-instrs
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt.OptBoundsFacts.Nil)
        (opt.OptBoundsCastEnv.Empty)
        (smoke-bounds-object-store-barrier (ir.CompilerIrValue.Var 99)))]
    (cond
      [(not
          (= (compiler_optimize_tests.opt-count-bounds-instrs object-array) 1))
        1]
      [(not
          (= (compiler_optimize_tests.opt-count-bounds-instrs object-string) 1))
        2]
      [(not
          (=
            (compiler_optimize_tests.opt-count-bounds-instrs object-mismatch)
            2))
        3]
      [(not (= (compiler_optimize_tests.opt-count-bounds-instrs object-call) 2))
        4]
      [(not
          (= (compiler_optimize_tests.opt-count-bounds-instrs object-store) 2))
        5]
      [(not
          (=
            (compiler_optimize_tests.opt-count-bounds-instrs
              object-element-store)
            1))
        6]
      [else 42])))

(define (smoke-range-bce-entry [with-nonnegative : bool]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "entry")
    (compiler_optimize_tests.opt-test-instrs-with-tail
      (if with-nonnegative
        (compiler_optimize_tests.opt-test-instrs
          (ir.CompilerIrInstr.BinOp
            14
            (ir.CompilerIrBinOp.Ge)
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.I64 0)
            (ast.AstType.Bool))
          (ir.CompilerIrInstr.Branch
            (ir.CompilerIrValue.Var 14)
            (ir.compiler-ir-label "lt")
            (ir.compiler-ir-label "exit")))
        (compiler_optimize_tests.opt-test-instrs
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "lt"))))
      (ir.CompilerIrInstr.Gep
        3
        (ir.CompilerIrValue.Var 2)
        (ir.CompilerIrValue.I64 1)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.Load 1 (ir.CompilerIrValue.Var 3) (ast.AstType.I64))
      (ir.CompilerIrInstr.Mov 0 (ir.CompilerIrValue.I64 0) (ast.AstType.I64)))))

(define (smoke-range-bce-lt [op : ir.CompilerIrBinOp] [length-var : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "lt")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        15
        op
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.Var length-var)
        (ast.AstType.Bool))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var 15)
        (ir.compiler-ir-label "body")
        (ir.compiler-ir-label "exit")))))

(define (smoke-range-bce-body) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "body")
    (compiler_optimize_tests.opt-loop-bce-string-test-ref-instrs
      2
      30
      (compiler_optimize_tests.opt-test-instrs
        (ir.CompilerIrInstr.Return
          (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 37)))))))

(define (smoke-range-bce-redefined-body) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "body")
    (compiler_optimize_tests.opt-test-instrs-with-tail
      (compiler_optimize_tests.opt-loop-bce-string-test-ref-instrs
        2
        30
        (compiler_optimize_tests.opt-test-instrs
          (ir.CompilerIrInstr.Return
            (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 37)))))
      (ir.CompilerIrInstr.Mov
        0
        (ir.CompilerIrValue.I64 (- 0 1))
        (ast.AstType.I64)))))

(define (smoke-range-bce-blocks
  [with-nonnegative : bool]
  [op : ir.CompilerIrBinOp]
  [length-var : i64]) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (smoke-range-bce-entry with-nonnegative)
    (ir.compiler-ir-block-cons
      (smoke-range-bce-lt op length-var)
      (ir.compiler-ir-block-cons
        (smoke-range-bce-body)
        (ir.compiler-ir-block-cons
          (compiler_optimize_tests.opt-loop-bce-test-exit)
          (ir.CompilerIrBlockList.Nil))))))

(define (smoke-range-bce-redefined-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (smoke-range-bce-entry true)
    (ir.compiler-ir-block-cons
      (smoke-range-bce-lt (ir.CompilerIrBinOp.Lt) 1)
      (ir.compiler-ir-block-cons
        (smoke-range-bce-redefined-body)
        (ir.compiler-ir-block-cons
          (compiler_optimize_tests.opt-loop-bce-test-exit)
          (ir.CompilerIrBlockList.Nil))))))

(define (smoke-range-bce-count
  [with-nonnegative : bool]
  [op : ir.CompilerIrBinOp]
  [length-var : i64]) : i64
  (let
    [symbols : compiler_optimize_tests.OptLoopBceTestSymbols
      (compiler_optimize_tests.opt-loop-bce-test-symbols)]
    (opt.opt-count-bounds-blocks
      (opt.opt-loop-bce-blocks
        (ast.ast-node-pool-reader-type-segment-bases)
        (compiler_optimize_tests.opt-loop-bce-test-summaries
          symbols
          false
          false)
        (compiler_optimize_tests.opt-loop-bce-string-test-params)
        (smoke-range-bce-blocks with-nonnegative op length-var)))))

(define (smoke-range-bce-redefined-count) : i64
  (let
    [symbols : compiler_optimize_tests.OptLoopBceTestSymbols
      (compiler_optimize_tests.opt-loop-bce-test-symbols)]
    (opt.opt-count-bounds-blocks
      (opt.opt-loop-bce-blocks
        (ast.ast-node-pool-reader-type-segment-bases)
        (compiler_optimize_tests.opt-loop-bce-test-summaries
          symbols
          false
          false)
        (compiler_optimize_tests.opt-loop-bce-string-test-params)
        (smoke-range-bce-redefined-blocks)))))

(define (smoke-range-bce-self-test) : i64
  (let
    [positive : i64 (smoke-range-bce-count true (ir.CompilerIrBinOp.Lt) 1)]
    [missing-nonnegative : i64
      (smoke-range-bce-count false (ir.CompilerIrBinOp.Lt) 1)]
    [off-by-one : i64 (smoke-range-bce-count true (ir.CompilerIrBinOp.Le) 1)]
    [mismatched-length : i64
      (smoke-range-bce-count true (ir.CompilerIrBinOp.Lt) 20)]
    [redefined-index : i64 (smoke-range-bce-redefined-count)]
    (cond
      [(not (= positive 0)) 1]
      [(not (= missing-nonnegative 1)) 2]
      [(not (= off-by-one 1)) 3]
      [(not (= mismatched-length 1)) 4]
      [(not (= redefined-index 1)) 5]
      [else 42])))

(define (smoke-ssa-iv-bce-params) : ir.CompilerIrParamList
  (ir.compiler-ir-param-cons
    (ir.CompilerIrParam.Param "text" (ast.AstType.String) 2)
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "other" (ast.AstType.String) 20)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "start" (ast.AstType.I64) 30)
        (ir.CompilerIrParamList.Nil)))))

(define (smoke-ssa-iv-bce-entry) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "entry")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.Gep
        3
        (ir.CompilerIrValue.Var 2)
        (ir.CompilerIrValue.I64 1)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.Load 1 (ir.CompilerIrValue.Var 3) (ast.AstType.I64))
      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header")))))

(define (smoke-ssa-iv-bce-header
  [start : ir.CompilerIrValue]
  [next-var : i64]
  [op : ir.CompilerIrBinOp]
  [upper-var : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "header")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.Phi
        0
        (ir.compiler-ir-phi-input-cons
          start
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-phi-input-cons
            (ir.CompilerIrValue.Var next-var)
            (ir.compiler-ir-label "body")
            (ir.CompilerIrPhiInputList.Nil)))
        (ast.AstType.I64))
      (ir.CompilerIrInstr.BinOp
        4
        op
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.Var upper-var)
        (ast.AstType.Bool))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var 4)
        (ir.compiler-ir-label "body")
        (ir.compiler-ir-label "exit")))))

(define (smoke-ssa-iv-bce-body
  [symbols : compiler_optimize_tests.OptLoopBceTestSymbols]
  [object-var : i64]
  [step : i64]
  [next-var : i64]
  [with-call : bool]
  [redefine-index : bool]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "body")
    (let
      [tail : ir.CompilerIrInstrSeq
        (compiler_optimize_tests.opt-loop-bce-string-test-ref-instrs
          object-var
          40
          (compiler_optimize_tests.opt-test-instrs
            (ir.CompilerIrInstr.BinOp
              next-var
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 step)
              (ast.AstType.I64))
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))))]
      [after-call : ir.CompilerIrInstrSeq
        (if with-call
          (compiler_optimize_tests.opt-test-instrs-with-tail
            tail
            (ir.CompilerIrInstr.Call
              80
              symbols.touch
              (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.Var object-var))
              (ast.AstType.Unit)))
          tail)]
      (if redefine-index
        (compiler_optimize_tests.opt-test-instrs-with-tail
          after-call
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 (- 0 1))
            (ast.AstType.I64)))
        after-call))))

(define (smoke-ssa-iv-bce-blocks
  [symbols : compiler_optimize_tests.OptLoopBceTestSymbols]
  [start : ir.CompilerIrValue]
  [step : i64]
  [op : ir.CompilerIrBinOp]
  [upper-var : i64]
  [object-var : i64]
  [with-call : bool]
  [redefine-index : bool]) : ir.CompilerIrBlockList
  (let
    [next-var : i64 90]
    (ir.compiler-ir-block-cons
      (smoke-ssa-iv-bce-entry)
      (ir.compiler-ir-block-cons
        (smoke-ssa-iv-bce-header start next-var op upper-var)
        (ir.compiler-ir-block-cons
          (smoke-ssa-iv-bce-body
            symbols
            object-var
            step
            next-var
            with-call
            redefine-index)
          (ir.compiler-ir-block-cons
            (compiler_optimize_tests.opt-loop-bce-test-exit)
            (ir.CompilerIrBlockList.Nil)))))))

(define (smoke-ssa-iv-bce-count
  [start : ir.CompilerIrValue]
  [step : i64]
  [op : ir.CompilerIrBinOp]
  [upper-var : i64]
  [object-var : i64]
  [with-call : bool]
  [redefine-index : bool]) : i64
  (let
    [symbols : compiler_optimize_tests.OptLoopBceTestSymbols
      (compiler_optimize_tests.opt-loop-bce-test-symbols)]
    (opt.opt-count-bounds-blocks
      (opt.opt-loop-bce-blocks
        (ast.ast-node-pool-reader-type-segment-bases)
        (compiler_optimize_tests.opt-loop-bce-test-summaries
          symbols
          false
          false)
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
        (ir.CompilerIrValue.I64 0)
        1
        (ir.CompilerIrBinOp.Lt)
        1
        2
        false
        false)]
    [negative-start : i64
      (smoke-ssa-iv-bce-count
        (ir.CompilerIrValue.I64 (- 0 1))
        1
        (ir.CompilerIrBinOp.Lt)
        1
        2
        false
        false)]
    [unknown-start : i64
      (smoke-ssa-iv-bce-count
        (ir.CompilerIrValue.Var 30)
        1
        (ir.CompilerIrBinOp.Lt)
        1
        2
        false
        false)]
    [negative-step : i64
      (smoke-ssa-iv-bce-count
        (ir.CompilerIrValue.I64 0)
        (- 0 1)
        (ir.CompilerIrBinOp.Lt)
        1
        2
        false
        false)]
    [nonunit-unknown-bound : i64
      (smoke-ssa-iv-bce-count
        (ir.CompilerIrValue.I64 0)
        2
        (ir.CompilerIrBinOp.Lt)
        1
        2
        false
        false)]
    [inclusive-guard : i64
      (smoke-ssa-iv-bce-count
        (ir.CompilerIrValue.I64 0)
        1
        (ir.CompilerIrBinOp.Le)
        1
        2
        false
        false)]
    [mismatched-object : i64
      (smoke-ssa-iv-bce-count
        (ir.CompilerIrValue.I64 0)
        1
        (ir.CompilerIrBinOp.Lt)
        1
        20
        false
        false)]
    [call-clears-length : i64
      (smoke-ssa-iv-bce-count
        (ir.CompilerIrValue.I64 0)
        1
        (ir.CompilerIrBinOp.Lt)
        1
        2
        true
        false)]
    [redefined-index : i64
      (smoke-ssa-iv-bce-count
        (ir.CompilerIrValue.I64 0)
        1
        (ir.CompilerIrBinOp.Lt)
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

;; Rotated fixed-array loops enter the body with a literal seed, then guard each
;; backedge with the stepped value.  The first input does not need a separately
;; materialized comparison fact when the same literal bound proves it directly;
;; every nonliteral/backedge input still has to be discharged on its own edge.
(define (smoke-rotated-bce-params) : ir.CompilerIrParamList
  (ir.compiler-ir-param-cons
    (ir.CompilerIrParam.Param "backing-length" (ast.AstType.I64) 4)
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "other-length" (ast.AstType.I64) 5)
      (ir.CompilerIrParamList.Nil))))

(define (smoke-rotated-bce-entry
  [start : ir.CompilerIrValue]
  [bound : ir.CompilerIrValue]
  [op : ir.CompilerIrBinOp]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "entry")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp 1 op start bound (ast.AstType.I64))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var 1)
        (ir.compiler-ir-label "body")
        (ir.compiler-ir-label "exit")))))

(define (smoke-rotated-bce-body
  [start : ir.CompilerIrValue]
  [check-bound : ir.CompilerIrValue]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "body")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.Phi
        0
        (ir.compiler-ir-phi-input-cons
          start
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-phi-input-cons
            (ir.CompilerIrValue.Var 2)
            (ir.compiler-ir-label "latch")
            (ir.CompilerIrPhiInputList.Nil)))
        (ast.AstType.I64))
      (ir.CompilerIrInstr.BoundsCheck
        (ir.CompilerIrValue.Var 0)
        check-bound
        (ir.compiler-ir-label "bounds_ok"))
      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch")))))

(define (smoke-rotated-bce-latch
  [bound : ir.CompilerIrValue]
  [op : ir.CompilerIrBinOp]
  [both-edges-enter : bool]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "latch")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        2
        (ir.CompilerIrBinOp.Add)
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.I64 1)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.BinOp
        3
        op
        (ir.CompilerIrValue.Var 2)
        bound
        (ast.AstType.I64))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var 3)
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
  (ir.compiler-ir-block-cons
    (smoke-rotated-bce-entry start guard-bound op)
    (ir.compiler-ir-block-cons
      (smoke-rotated-bce-body start check-bound)
      (ir.compiler-ir-block-cons
        (smoke-rotated-bce-latch guard-bound op both-edges-enter)
        (ir.compiler-ir-block-cons
          (compiler_optimize_tests.opt-loop-bce-test-exit)
          (ir.CompilerIrBlockList.Nil))))))

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
    (opt.opt-count-bounds-blocks
      (opt.opt-bounds-dom-blocks-with-context
        (ast.ast-node-pool-reader-type-segment-bases)
        (opt.opt-cfg-context-build blocks)
        (smoke-rotated-bce-params)
        6
        blocks))))

(define (smoke-rotated-literal-bce-self-test) : i64
  (let
    [fixed : i64
      (smoke-rotated-bce-count
        (ir.CompilerIrValue.I64 0)
        (ir.CompilerIrValue.I64 9)
        (ir.CompilerIrValue.I64 9)
        (ir.CompilerIrBinOp.Lt)
        false)]
    ;; The dynamic form models a borrowed backing whose exact array-length SSA
    ;; value feeds both the loop guard and the access check. A Vec live length
    ;; is a distinct value (the mismatch case below) and proves nothing about
    ;; backing capacity.
    [borrowed-backing : i64
      (smoke-rotated-bce-count
        (ir.CompilerIrValue.I64 0)
        (ir.CompilerIrValue.Var 4)
        (ir.CompilerIrValue.Var 4)
        (ir.CompilerIrBinOp.Lt)
        false)]
    [negative-start : i64
      (smoke-rotated-bce-count
        (ir.CompilerIrValue.I64 (- 0 1))
        (ir.CompilerIrValue.I64 9)
        (ir.CompilerIrValue.I64 9)
        (ir.CompilerIrBinOp.Lt)
        false)]
    [different-upper : i64
      (smoke-rotated-bce-count
        (ir.CompilerIrValue.I64 0)
        (ir.CompilerIrValue.I64 8)
        (ir.CompilerIrValue.I64 9)
        (ir.CompilerIrBinOp.Lt)
        false)]
    [different-provenance : i64
      (smoke-rotated-bce-count
        (ir.CompilerIrValue.I64 0)
        (ir.CompilerIrValue.Var 4)
        (ir.CompilerIrValue.Var 5)
        (ir.CompilerIrBinOp.Lt)
        false)]
    [inclusive-upper : i64
      (smoke-rotated-bce-count
        (ir.CompilerIrValue.I64 0)
        (ir.CompilerIrValue.I64 9)
        (ir.CompilerIrValue.I64 9)
        (ir.CompilerIrBinOp.Le)
        false)]
    [nondominating-backedge : i64
      (smoke-rotated-bce-count
        (ir.CompilerIrValue.I64 0)
        (ir.CompilerIrValue.I64 9)
        (ir.CompilerIrValue.I64 9)
        (ir.CompilerIrBinOp.Lt)
        true)]
    (cond
      [(not (= fixed 0)) 1]
      [(not (= borrowed-backing 0)) 2]
      [(not (= negative-start 1)) 3]
      [(not (= different-upper 1)) 4]
      [(not (= different-provenance 1)) 5]
      [(not (= inclusive-upper 1)) 6]
      [(not (= nondominating-backedge 1)) 7]
      [else 42])))

(define (smoke-nonlength-guard-header [op : ir.CompilerIrBinOp]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "header")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        43
        op
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.Var 40)
        (ast.AstType.Bool))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var 43)
        (ir.compiler-ir-label "body")
        (ir.compiler-ir-label "exit")))))

(define (smoke-nonlength-guard-body [object-var : i64] [redefine-bound : bool]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "body")
    (let
      [tail : ir.CompilerIrInstrSeq
        (compiler_optimize_tests.opt-loop-bce-string-test-ref-instrs
          object-var
          50
          (compiler_optimize_tests.opt-test-instrs
            (ir.CompilerIrInstr.Return
              (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 57)))))]
      (if redefine-bound
        (compiler_optimize_tests.opt-test-instrs-with-tail
          tail
          (ir.CompilerIrInstr.Mov
            40
            (ir.CompilerIrValue.I64 0)
            (ast.AstType.I64)))
        tail))))

(define (smoke-nonlength-guard-blocks
  [with-upper : bool]
  [op : ir.CompilerIrBinOp]
  [object-var : i64]
  [redefine-bound : bool]) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (compiler_optimize_tests.opt-loop-bce-string-test-transitive-entry)
    (ir.compiler-ir-block-cons
      (compiler_optimize_tests.opt-loop-bce-string-test-transitive-upper
        with-upper)
      (ir.compiler-ir-block-cons
        (smoke-nonlength-guard-header op)
        (ir.compiler-ir-block-cons
          (smoke-nonlength-guard-body object-var redefine-bound)
          (ir.compiler-ir-block-cons
            (compiler_optimize_tests.opt-loop-bce-test-exit)
            (ir.CompilerIrBlockList.Nil)))))))

(define (smoke-nonlength-guard-count
  [with-upper : bool]
  [op : ir.CompilerIrBinOp]
  [object-var : i64]
  [redefine-bound : bool]) : i64
  (let
    [symbols : compiler_optimize_tests.OptLoopBceTestSymbols
      (compiler_optimize_tests.opt-loop-bce-test-symbols)]
    (compiler_optimize_tests.opt-loop-bce-string-test-count
      (smoke-nonlength-guard-blocks with-upper op object-var redefine-bound)
      (compiler_optimize_tests.opt-loop-bce-test-summaries symbols false false))))

(define (smoke-nonlength-guard-bce-self-test) : i64
  (let
    [positive : i64
      (smoke-nonlength-guard-count true (ir.CompilerIrBinOp.Lt) 2 false)]
    [missing-upper : i64
      (smoke-nonlength-guard-count false (ir.CompilerIrBinOp.Lt) 2 false)]
    [mismatched-object : i64
      (smoke-nonlength-guard-count true (ir.CompilerIrBinOp.Lt) 20 false)]
    [redefined-bound : i64
      (smoke-nonlength-guard-count true (ir.CompilerIrBinOp.Lt) 2 true)]
    [off-by-one : i64
      (smoke-nonlength-guard-count true (ir.CompilerIrBinOp.Le) 2 false)]
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
  [tail : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
  (compiler_optimize_tests.opt-test-instrs-with-tail
    tail
    (ir.CompilerIrInstr.Gep
      base
      (ir.CompilerIrValue.Var object-var)
      (ir.CompilerIrValue.I64 0)
      (ast.AstType.U8))
    (ir.CompilerIrInstr.Load
      (+ base 1)
      (ir.CompilerIrValue.Var base)
      (ast.AstType.U64))
    (ir.CompilerIrInstr.Gep
      (+ base 2)
      (ir.CompilerIrValue.Var object-var)
      (ir.CompilerIrValue.I64 8)
      (ast.AstType.U8))
    (ir.CompilerIrInstr.Load
      (+ base 3)
      (ir.CompilerIrValue.Var (+ base 2))
      (ast.AstType.I64))
    (ir.CompilerIrInstr.Cast
      (+ base 4)
      (ir.CompilerIrValue.Var (+ base 3))
      (ast.AstType.I64)
      (ast.AstType.U64))
    (ir.CompilerIrInstr.Cast
      (+ base 5)
      (ir.CompilerIrValue.Var index-var)
      (ast.AstType.I64)
      (ast.AstType.U64))
    (ir.CompilerIrInstr.BoundsCheck
      (ir.CompilerIrValue.Var (+ base 5))
      (ir.CompilerIrValue.Var (+ base 4))
      (ir.compiler-ir-label "str_bounds_ok"))
    (ir.CompilerIrInstr.Gep
      (+ base 6)
      (ir.CompilerIrValue.Var (+ base 1))
      (ir.CompilerIrValue.Var index-var)
      (ast.AstType.Char))
    (ir.CompilerIrInstr.Load
      (+ base 7)
      (ir.CompilerIrValue.Var (+ base 6))
      (ast.AstType.Char))))

(define (smoke-additive-entry [with-nonnegative : bool] [upper-offset : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "entry")
    (compiler_optimize_tests.opt-test-instrs-with-tail
      (if with-nonnegative
        (compiler_optimize_tests.opt-test-instrs
          (ir.CompilerIrInstr.BinOp
            42
            (ir.CompilerIrBinOp.Ge)
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.I64 0)
            (ast.AstType.Bool))
          (ir.CompilerIrInstr.Branch
            (ir.CompilerIrValue.Var 42)
            (ir.compiler-ir-label "header")
            (ir.compiler-ir-label "exit")))
        (compiler_optimize_tests.opt-test-instrs
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))))
      (ir.CompilerIrInstr.Gep
        3
        (ir.CompilerIrValue.Var 2)
        (ir.CompilerIrValue.I64 1)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.Load 1 (ir.CompilerIrValue.Var 3) (ast.AstType.I64))
      (ir.CompilerIrInstr.Mov 0 (ir.CompilerIrValue.I64 0) (ast.AstType.I64))
      (ir.CompilerIrInstr.BinOp
        40
        (ir.CompilerIrBinOp.Sub)
        (ir.CompilerIrValue.Var 1)
        (ir.CompilerIrValue.I64 upper-offset)
        (ast.AstType.I64)))))

(define (smoke-additive-header [op : ir.CompilerIrBinOp] [upper-var : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "header")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        43
        op
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.Var upper-var)
        (ast.AstType.Bool))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var 43)
        (ir.compiler-ir-label "body")
        (ir.compiler-ir-label "exit")))))

(define (smoke-additive-body [offset : i64] [redefine-index : bool]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "body")
    (let
      [tail : ir.CompilerIrInstrSeq
        (compiler_optimize_tests.opt-test-instrs-with-tail
          (smoke-additive-ref-index-instrs
            2
            50
            60
            (compiler_optimize_tests.opt-test-instrs
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 67)))))
          (ir.CompilerIrInstr.BinOp
            50
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.I64 offset)
            (ast.AstType.I64)))]
      (if redefine-index
        (compiler_optimize_tests.opt-test-instrs-with-tail
          tail
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 (- 0 1))
            (ast.AstType.I64)))
        tail))))

(define (smoke-additive-blocks
  [offset : i64]
  [upper-offset : i64]
  [with-nonnegative : bool]
  [op : ir.CompilerIrBinOp]
  [upper-var : i64]
  [redefine-index : bool]) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (smoke-additive-entry with-nonnegative upper-offset)
    (ir.compiler-ir-block-cons
      (smoke-additive-header op upper-var)
      (ir.compiler-ir-block-cons
        (smoke-additive-body offset redefine-index)
        (ir.compiler-ir-block-cons
          (compiler_optimize_tests.opt-loop-bce-test-exit)
          (ir.CompilerIrBlockList.Nil))))))

(define (smoke-additive-count
  [offset : i64]
  [upper-offset : i64]
  [with-nonnegative : bool]
  [op : ir.CompilerIrBinOp]
  [upper-var : i64]
  [redefine-index : bool]) : i64
  (let
    [symbols : compiler_optimize_tests.OptLoopBceTestSymbols
      (compiler_optimize_tests.opt-loop-bce-test-symbols)]
    (compiler_optimize_tests.opt-loop-bce-string-test-count
      (smoke-additive-blocks
        offset
        upper-offset
        with-nonnegative
        op
        upper-var
        redefine-index)
      (compiler_optimize_tests.opt-loop-bce-test-summaries symbols false false))))

(define (smoke-additive-wrap-risk-entry) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "entry")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.Call
        1
        (compiler_optimize_tests.opt-test-symbol "unknown_len")
        (ir.CompilerIrCallArgs.Nil)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.Mov 0 (ir.CompilerIrValue.I64 0) (ast.AstType.I64))
      (ir.CompilerIrInstr.BinOp
        40
        (ir.CompilerIrBinOp.Sub)
        (ir.CompilerIrValue.Var 1)
        (ir.CompilerIrValue.I64 1)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.BinOp
        42
        (ir.CompilerIrBinOp.Ge)
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.I64 0)
        (ast.AstType.Bool))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var 42)
        (ir.compiler-ir-label "header")
        (ir.compiler-ir-label "exit")))))

(define (smoke-additive-wrap-risk-header) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "header")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        43
        (ir.CompilerIrBinOp.Lt)
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.Var 40)
        (ast.AstType.Bool))
      (ir.CompilerIrInstr.Branch
        (ir.CompilerIrValue.Var 43)
        (ir.compiler-ir-label "body")
        (ir.compiler-ir-label "exit")))))

(define (smoke-additive-wrap-risk-body) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "body")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        50
        (ir.CompilerIrBinOp.Add)
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.I64 1)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.BoundsCheck
        (ir.CompilerIrValue.Var 50)
        (ir.CompilerIrValue.Var 1)
        (ir.compiler-ir-label "bounds_ok"))
      (ir.CompilerIrInstr.Return
        (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 50))))))

(define (smoke-additive-wrap-risk-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (smoke-additive-wrap-risk-entry)
    (ir.compiler-ir-block-cons
      (smoke-additive-wrap-risk-header)
      (ir.compiler-ir-block-cons
        (smoke-additive-wrap-risk-body)
        (ir.compiler-ir-block-cons
          (compiler_optimize_tests.opt-loop-bce-test-exit)
          (ir.CompilerIrBlockList.Nil))))))

(define (smoke-additive-bce-self-test) : i64
  (let
    [symbols : compiler_optimize_tests.OptLoopBceTestSymbols
      (compiler_optimize_tests.opt-loop-bce-test-symbols)]
    [plus1 : i64
      (smoke-additive-count 1 1 true (ir.CompilerIrBinOp.Lt) 40 false)]
    [plus3 : i64
      (smoke-additive-count 3 3 true (ir.CompilerIrBinOp.Lt) 40 false)]
    [missing-nonnegative : i64
      (smoke-additive-count 1 1 false (ir.CompilerIrBinOp.Lt) 40 false)]
    [missing-slack : i64
      (smoke-additive-count 1 1 true (ir.CompilerIrBinOp.Lt) 1 false)]
    [wrap-risk : i64
      (compiler_optimize_tests.opt-loop-bce-test-count
        (smoke-additive-wrap-risk-blocks)
        (compiler_optimize_tests.opt-loop-bce-test-summaries
          symbols
          false
          false))]
    [negative-offset : i64
      (smoke-additive-count (- 0 1) 0 true (ir.CompilerIrBinOp.Lt) 1 false)]
    [redefined-index : i64
      (smoke-additive-count 1 1 true (ir.CompilerIrBinOp.Lt) 40 true)]
    [off-by-one : i64
      (smoke-additive-count 1 1 true (ir.CompilerIrBinOp.Le) 40 false)]
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
  (ir.compiler-ir-label (str_cat.str-cat "b" (string.int->string index))))

(define (smoke-heavy-pass-large-jump-block [index : i64] [next : i64]) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (smoke-heavy-pass-large-label index)
    (compiler_optimize_tests.opt-test-instrs (ir.CompilerIrInstr.Jump next))))

(define (smoke-heavy-pass-large-exit-block) : ir.CompilerIrBlock
  (ir.CompilerIrBlock.Block
    (ir.compiler-ir-label "exit")
    (compiler_optimize_tests.opt-test-instrs
      (ir.CompilerIrInstr.BinOp
        3
        (ir.CompilerIrBinOp.Add)
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.Var 1)
        (ast.AstType.I64))
      (ir.CompilerIrInstr.Return
        (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3))))))

(define (smoke-heavy-pass-large-tail-blocks [index : i64] [last : i64]) : ir.CompilerIrBlockList
  (if (> index last)
    (ir.compiler-ir-block-cons
      (smoke-heavy-pass-large-exit-block)
      (ir.CompilerIrBlockList.Nil))
    (ir.compiler-ir-block-cons
      (smoke-heavy-pass-large-jump-block
        index
        (if (= index last)
          (ir.compiler-ir-label "exit")
          (smoke-heavy-pass-large-label (+ index 1))))
      (smoke-heavy-pass-large-tail-blocks (+ index 1) last))))

(define (smoke-heavy-pass-large-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "entry")
      (compiler_optimize_tests.opt-test-instrs
        (ir.CompilerIrInstr.BinOp
          2
          (ir.CompilerIrBinOp.Add)
          (ir.CompilerIrValue.Var 0)
          (ir.CompilerIrValue.Var 1)
          (ast.AstType.I64))
        (ir.CompilerIrInstr.Jump (smoke-heavy-pass-large-label 1))))
    (smoke-heavy-pass-large-tail-blocks 1 1024)))

(define (smoke-heavy-pass-large-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (compiler_optimize_tests.opt-test-symbol "heavy_pass_large")
    (compiler_optimize_tests.opt-gvn-test-params)
    (ast.AstType.I64)
    4
    (smoke-heavy-pass-large-blocks)))

(define (smoke-heavy-pass-large-gvn-self-test) : i64
  (let
    [blocks : ir.CompilerIrBlockList (smoke-heavy-pass-large-blocks)]
    [optimized : ir.CompilerIrFunction
      (opt.optimize-function-once
        (ast.ast-node-pool-reader-context-current)
        (ast.ast-node-pool-reader-type-segment-bases)
        (smoke-heavy-pass-large-function))]
    (begin
      (unless (> (ir.compiler-ir-block-list-count blocks) 1024) (return 1))
      (unless
        (<=
          (ir.compiler-ir-block-list-count blocks)
          (opt.opt-heavy-pass-block-limit))
        (return 2))
      (match optimized
        [(ir.CompilerIrFunction.Function _ _ _ _ optimized-blocks)
          (if (=
            (compiler_optimize_tests.opt-gvn-count-binops-blocks
              optimized-blocks)
            1)
            42
            3)]))))

(define (smoke-function-index-leaf-starts-self-test) : i64
  (let
    [qualified : String "module/path::tl_substring"]
    [plain : String "plain"]
    [index : opt.OptFunctionIndex
      (opt.opt-function-index-build
        (ir.compiler-ir-function-seq-prepend
          (compiler_optimize_tests.opt-test-function-named
            qualified
            (ir.compiler-ir-instr-seq-empty))
          (ir.compiler-ir-function-seq-prepend
            (compiler_optimize_tests.opt-test-function-named
              plain
              (ir.compiler-ir-instr-seq-empty))
            (ir.compiler-ir-function-seq-empty))))]
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
    (compiler_optimize_tests.compiler-optimize-self-test-failure-message
      "copy propagation"
      7
      42)
    "optimizer self-test failed: copy propagation (expected 42, got 7)"))

(define (smoke-optimizer-core-self-tests) : i64
  (begin
    (compiler_optimize_tests.compiler-optimize-self-test-require!
      "named failure message renderer"
      (smoke-optimizer-named-failure-message-ok?))
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-self-test"
      (compiler_optimize_tests.compiler-optimize-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-dense-storage-self-test"
      (compiler_optimize_tests.compiler-optimize-dense-storage-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-typed-fold-self-test"
      (compiler_optimize_tests.compiler-optimize-typed-fold-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-noop-int-cast-mov-self-test"
      (smoke-noop-int-cast-mov-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-strength-self-test"
      (compiler_optimize_tests.compiler-optimize-strength-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-dce-self-test"
      (compiler_optimize_tests.compiler-optimize-dce-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-dce-mem-self-test"
      (compiler_optimize_tests.compiler-optimize-dce-mem-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-divrem-safety-self-test"
      (compiler_optimize_tests.compiler-optimize-divrem-safety-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-const-divisor-self-test"
      (compiler_optimize_tests.compiler-optimize-const-divisor-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-cse-self-test"
      (compiler_optimize_tests.compiler-optimize-cse-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-copy-self-test"
      (compiler_optimize_tests.compiler-optimize-copy-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bounds-self-test"
      (compiler_optimize_tests.compiler-optimize-bounds-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bounds-dom-self-test"
      (compiler_optimize_tests.compiler-optimize-bounds-dom-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bounds-dom-slice-word-self-test"
      (compiler_optimize_tests.compiler-optimize-bounds-dom-slice-word-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bounds-run-self-test"
      (compiler_optimize_tests.compiler-optimize-bounds-run-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-range-merge-self-test"
      (compiler_optimize_tests.compiler-optimize-range-merge-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-nonneg-globals-self-test"
      (compiler_optimize_tests.compiler-optimize-nonneg-globals-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-dom-cmp-rule-a-self-test"
      (compiler_optimize_tests.compiler-optimize-dom-cmp-rule-a-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-dom-cmp-rule-a-cfg-self-test"
      (compiler_optimize_tests.compiler-optimize-dom-cmp-rule-a-cfg-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-dom-cmp-phi-carried-self-test"
      (compiler_optimize_tests.compiler-optimize-dom-cmp-phi-carried-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-dom-cmp-branch-fold-self-test"
      (compiler_optimize_tests.compiler-optimize-dom-cmp-branch-fold-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-object-bounds-self-test"
      (smoke-object-bounds-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-range-bce-self-test"
      (smoke-range-bce-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-ssa-iv-bce-self-test"
      (smoke-ssa-iv-bce-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-rotated-literal-bce-self-test"
      (smoke-rotated-literal-bce-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-nonlength-guard-bce-self-test"
      (smoke-nonlength-guard-bce-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-additive-bce-self-test"
      (smoke-additive-bce-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-sccp-self-test"
      (compiler_optimize_tests.compiler-optimize-sccp-self-test)
      42)
    42))

(define (smoke-optimizer-loop-self-tests) : i64
  (begin
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-global-value-number-self-test"
      (compiler_optimize_tests.compiler-optimize-global-value-number-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-load-gvn-substitution-self-test"
      (compiler_optimize_tests.compiler-optimize-load-gvn-substitution-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-wide-literal-operand-self-test"
      (compiler_optimize_tests.compiler-optimize-wide-literal-operand-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-cfg-self-test"
      (compiler_optimize_tests.compiler-optimize-cfg-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-uniform-phi-self-test"
      (compiler_optimize_tests.compiler-optimize-uniform-phi-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-switch-form-self-test"
      (compiler-optimize-switch-form-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-natural-loop-self-test"
      (compiler_optimize_tests.compiler-optimize-natural-loop-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-loop-rotation-self-test"
      (compiler_optimize_tests.compiler-optimize-loop-rotation-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-rotate-ssa-self-test"
      (compiler_optimize_tests.compiler-optimize-rotate-ssa-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-self-test"
      (compiler_optimize_tests.compiler-optimize-licm-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-profitability-self-test"
      (compiler_optimize_tests.compiler-optimize-licm-profitability-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-word-self-test"
      (compiler_optimize_tests.compiler-optimize-licm-word-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-local-slot-self-test"
      (compiler_optimize_tests.compiler-optimize-licm-local-slot-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-global-mod-ref-self-test"
      (compiler_optimize_tests.compiler-optimize-licm-global-mod-ref-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-frozen-global-self-test"
      (compiler_optimize_tests.compiler-optimize-licm-frozen-global-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-global-cell-call-mod-ref-self-test"
      (compiler_optimize_tests.compiler-optimize-global-cell-call-mod-ref-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-unswitch-self-test"
      (compiler_optimize_tests.compiler-optimize-licm-unswitch-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-unswitch-chain-self-test"
      (compiler_optimize_tests.compiler-optimize-licm-unswitch-chain-self-test)
      42)
    (cfg
      test
      (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
        "compiler-optimize-licm-checked-root-self-test"
        (compiler_optimize_tests.compiler-optimize-licm-checked-root-self-test)
        42)
      unit)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-induction-self-test"
      (compiler_optimize_tests.compiler-optimize-induction-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-lftr-self-test"
      (compiler_optimize_tests.compiler-optimize-lftr-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-unroll-self-test"
      (compiler_optimize_tests.compiler-optimize-unroll-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-unroll-load-store-self-test"
      (compiler_optimize_tests.compiler-optimize-unroll-load-store-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-unroll-mb-self-test"
      (compiler_optimize_tests.compiler-optimize-unroll-mb-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-affine-self-test"
      (compiler_optimize_tests.compiler-optimize-affine-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-affine-pipeline-self-test"
      (compiler_optimize_tests.compiler-optimize-affine-pipeline-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-ssa-preexisting-phi-self-test"
      (compiler_optimize_tests.compiler-optimize-ssa-preexisting-phi-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-licm-multi-exit-self-test"
      (compiler_optimize_tests.compiler-optimize-licm-multi-exit-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-mask-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-mask-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-pipeline-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-pipeline-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-ssa-self-test"
      (compiler_optimize_tests.compiler-optimize-ssa-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-ssa-fixed-handle-self-test"
      (compiler_optimize_tests.compiler-optimize-ssa-fixed-handle-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-level-self-test"
      (compiler_optimize_tests.compiler-optimize-level-self-test)
      42)
    42))

(define (smoke-inline-phi-header [latch-label : i64]) : ir.CompilerIrInstr
  (ir.CompilerIrInstr.Phi
    1
    (ir.compiler-ir-phi-input-cons
      (ir.CompilerIrValue.I64 0)
      (ir.compiler-ir-label "entry")
      (ir.compiler-ir-phi-input-cons
        (ir.CompilerIrValue.Var 0)
        latch-label
        ir.CompilerIrPhiInputList.Nil))
    (ast.AstType.I64)))

(define (smoke-inline-phi-exit [latch-label : i64]) : ir.CompilerIrInstr
  (ir.CompilerIrInstr.Phi
    2
    (ir.compiler-ir-phi-input-cons
      (ir.CompilerIrValue.Var 1)
      (ir.compiler-ir-label "header")
      (ir.compiler-ir-phi-input-cons
        (ir.CompilerIrValue.Var 0)
        latch-label
        ir.CompilerIrPhiInputList.Nil))
    (ast.AstType.I64)))

(define (smoke-inline-phi-caller-with-call
  [symbols : compiler_optimize_tests.OptInlineMultiTestSymbols]
  [call : ir.CompilerIrInstr]) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    symbols.main
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler_optimize_tests.opt-test-instrs
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "header")
          (compiler_optimize_tests.opt-test-instrs
            (smoke-inline-phi-header (ir.compiler-ir-label "latch"))
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Bool true)
              (ir.compiler-ir-label "latch")
              (ir.compiler-ir-label "exit"))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "latch")
            (compiler_optimize_tests.opt-test-instrs
              call
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool true)
                (ir.compiler-ir-label "header")
                (ir.compiler-ir-label "exit"))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "exit")
              (compiler_optimize_tests.opt-test-instrs
                (smoke-inline-phi-exit (ir.compiler-ir-label "latch"))
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))))
            ir.CompilerIrBlockList.Nil))))))

(define (smoke-inline-phi-params) : ir.CompilerIrParamList
  (ir.compiler-ir-param-cons
    (ir.CompilerIrParam.Param "a" (ast.AstType.I64) 0)
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "b" (ast.AstType.I64) 1)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "c" (ast.AstType.I64) 2)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "d" (ast.AstType.I64) 3)
          ir.CompilerIrParamList.Nil)))))

(define (smoke-inline-phi-callee-mov) : ir.CompilerIrInstr
  (ir.CompilerIrInstr.Mov 4 (ir.CompilerIrValue.I64 7) (ast.AstType.I64)))

(define (smoke-inline-phi-callee
  [symbols : compiler_optimize_tests.OptInlineMultiTestSymbols]) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    symbols.inline-branch
    (smoke-inline-phi-params)
    (ast.AstType.I64)
    5
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler_optimize_tests.opt-test-instrs
          (smoke-inline-phi-callee-mov)
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "exit"))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "exit")
          (compiler_optimize_tests.opt-test-instrs
            (ir.CompilerIrInstr.Return
              (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 4)))))
        ir.CompilerIrBlockList.Nil))))

(define (smoke-inline-phi-call
  [symbols : compiler_optimize_tests.OptInlineMultiTestSymbols]) : ir.CompilerIrInstr
  (let
    [values : (__tl_dyn-array ir.CompilerIrValue)
      (array.make-array ir.CompilerIrValue 4)]
    (begin
      (set! (array-ref values 0) (ir.CompilerIrValue.I64 1))
      (set! (array-ref values 1) (ir.CompilerIrValue.I64 2))
      (set! (array-ref values 2) (ir.CompilerIrValue.I64 3))
      (set! (array-ref values 3) (ir.CompilerIrValue.I64 4))
      (ir.CompilerIrInstr.Call
        0
        symbols.inline-branch
        (ir.CompilerIrCallArgs.Array values)
        (ast.AstType.I64)))))

(define (smoke-inline-phi-caller
  [symbols : compiler_optimize_tests.OptInlineMultiTestSymbols]) : ir.CompilerIrFunction
  (smoke-inline-phi-caller-with-call symbols (smoke-inline-phi-call symbols)))

(define (smoke-inline-phi-functions
  [symbols : compiler_optimize_tests.OptInlineMultiTestSymbols]) : ir.CompilerIrFunctionSeq
  (ir.compiler-ir-function-seq-prepend
    (smoke-inline-phi-caller symbols)
    (ir.compiler-ir-function-seq-prepend
      (smoke-inline-phi-callee symbols)
      (ir.compiler-ir-function-seq-empty))))

(define (smoke-inline-phi-loop-repaired? [blocks : ir.CompilerIrBlockList]) : bool
  (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "header"))
    [(opt.OptMaybeBlock.No) false]
    [(opt.OptMaybeBlock.Some header)
      (match header
        [(ir.CompilerIrBlock.Block _ instrs)
          (match (ir.compiler-ir-instr-seq-ref instrs 0)
            [(ir.CompilerIrInstr.Phi _ inputs _)
              (if (opt.opt-phi-input-list-eq
                inputs
                (match (smoke-inline-phi-header
                  (ir.compiler-ir-label "inl.latch.0.cont"))
                  [(ir.CompilerIrInstr.Phi _ expected _) expected]
                  [_ ir.CompilerIrPhiInputList.Nil]))
                (match (opt.opt-cfg-find-block
                  blocks
                  (ir.compiler-ir-label "exit"))
                  [(opt.OptMaybeBlock.No) false]
                  [(opt.OptMaybeBlock.Some exit)
                    (match exit
                      [(ir.CompilerIrBlock.Block _ exit-instrs)
                        (match (ir.compiler-ir-instr-seq-ref exit-instrs 0)
                          [(ir.CompilerIrInstr.Phi _ exit-inputs _)
                            (opt.opt-phi-input-list-eq
                              exit-inputs
                              (match (smoke-inline-phi-exit
                                (ir.compiler-ir-label "inl.latch.0.cont"))
                                [(ir.CompilerIrInstr.Phi _ expected _) expected]
                                [_ ir.CompilerIrPhiInputList.Nil]))]
                          [_ false])])])
                false)]
            [_ false])])]))

(define (smoke-inline-phi-positive-code) : i64
  (let
    [symbols : compiler_optimize_tests.OptInlineMultiTestSymbols
      (compiler_optimize_tests.opt-inline-multi-test-symbols)]
    [optimized : ir.CompilerIrFunctionSeq
      (opt.opt-inline-program-functions
        (ast.ast-node-pool-reader-type-segment-bases)
        (smoke-inline-phi-functions symbols)
        2)]
    (match (opt.opt-function-seq-find optimized "main")
      [(opt.OptMaybeFunction.Some main)
        (let
          [blocks : ir.CompilerIrBlockList (opt.opt-function-blocks main)]
          (cond
            [(not
                (=
                  (compiler_optimize_tests.opt-count-direct-call-name-blocks
                    blocks
                    "inline_branch")
                  0))
              11]
            [(not (= (ir.compiler-ir-block-list-count blocks) 7))
              (+ 20 (ir.compiler-ir-block-list-count blocks))]
            [(not (= (compiler_optimize_tests.opt-count-phi-blocks blocks) 2))
              (+ 40 (compiler_optimize_tests.opt-count-phi-blocks blocks))]
            [(not (smoke-inline-phi-loop-repaired? blocks)) 61]
            [(not (opt.opt-inline-structure-ok? blocks)) 62]
            [else 42]))]
      [(opt.OptMaybeFunction.No) 10])))

(define (smoke-inline-phi-spans?) : bool
  (let
    [symbols : compiler_optimize_tests.OptInlineMultiTestSymbols
      (compiler_optimize_tests.opt-inline-multi-test-symbols)]
    [call : ir.CompilerIrInstr (smoke-inline-phi-call symbols)]
    [header-phi : ir.CompilerIrInstr
      (smoke-inline-phi-header (ir.compiler-ir-label "latch"))]
    [exit-phi : ir.CompilerIrInstr
      (smoke-inline-phi-exit (ir.compiler-ir-label "latch"))]
    [spans : ir.CompilerSourceSpans
      (ir.compiler-source-spans-insert-instr
        (ir.compiler-source-spans-insert-instr
          (ir.compiler-source-spans-insert-instr
            (compiler_optimize_tests.opt-spans-base)
            (compiler_optimize_tests.opt-test-symbol "main")
            call
            (compiler_optimize_tests.opt-test-span 161 31))
          (compiler_optimize_tests.opt-test-symbol "main")
          header-phi
          (compiler_optimize_tests.opt-test-span 162 33))
        (compiler_optimize_tests.opt-test-symbol "main")
        exit-phi
        (compiler_optimize_tests.opt-test-span 163 35))]
    [result-mov : ir.CompilerIrInstr
      (ir.CompilerIrInstr.Mov 0 (ir.CompilerIrValue.Var 3) (ast.AstType.I64))]
    [repaired-header : ir.CompilerIrInstr
      (smoke-inline-phi-header (ir.compiler-ir-label "inl.latch.0.cont"))]
    [repaired-exit : ir.CompilerIrInstr
      (smoke-inline-phi-exit (ir.compiler-ir-label "inl.latch.0.cont"))]
    (match (opt.opt-inline-program-functions-with-spans
      (ast.ast-node-pool-reader-type-segment-bases)
      (smoke-inline-phi-functions symbols)
      2
      spans)
      [(opt.OptInlineSpanProgram.Program optimized optimized-spans)
        (match (opt.opt-function-seq-find optimized "main")
          [(opt.OptMaybeFunction.Some main)
            (let
              [blocks : ir.CompilerIrBlockList (opt.opt-function-blocks main)]
              (and
                (=
                  (compiler_optimize_tests.opt-count-direct-call-name-blocks
                    blocks
                    "inline_branch")
                  0)
                (smoke-inline-phi-loop-repaired? blocks)
                (opt.opt-inline-structure-ok? blocks)
                (compiler_optimize_tests.opt-span-lookup-ok?
                  optimized-spans
                  (compiler_optimize_tests.opt-test-symbol "main")
                  result-mov
                  161
                  31)
                (compiler_optimize_tests.opt-span-lookup-ok?
                  optimized-spans
                  (compiler_optimize_tests.opt-test-symbol "main")
                  repaired-header
                  162
                  33)
                (compiler_optimize_tests.opt-span-lookup-ok?
                  optimized-spans
                  (compiler_optimize_tests.opt-test-symbol "main")
                  repaired-exit
                  163
                  35)))]
          [(opt.OptMaybeFunction.No) false])])))

(define (smoke-inline-phi-refusal?) : bool
  (let
    [symbols : compiler_optimize_tests.OptInlineMultiTestSymbols
      (compiler_optimize_tests.opt-inline-multi-test-symbols)]
    [caller : ir.CompilerIrFunction (smoke-inline-phi-caller symbols)]
    [optimized : ir.CompilerIrFunctionSeq
      (opt.opt-inline-program-functions
        (ast.ast-node-pool-reader-type-segment-bases)
        (ir.compiler-ir-function-seq-prepend
          caller
          (ir.compiler-ir-function-seq-empty))
        2)]
    (match (opt.opt-function-seq-find optimized "main")
      [(opt.OptMaybeFunction.Some main)
        (opt.opt-function-eq
          (ast.ast-node-pool-reader-type-segment-bases)
          main
          caller)]
      [(opt.OptMaybeFunction.No) false])))

(define (smoke-inline-phi-nonleaf-cost?) : bool
  (let
    [symbols : compiler_optimize_tests.OptInlineMultiTestSymbols
      (compiler_optimize_tests.opt-inline-multi-test-symbols)]
    [caller : ir.CompilerIrFunction
      (smoke-inline-phi-caller-with-call
        symbols
        (ir.CompilerIrInstr.Call
          0
          symbols.inline-nonleaf
          ir.CompilerIrCallArgs.Nil
          (ast.AstType.I64)))]
    [optimized : ir.CompilerIrFunctionSeq
      (opt.opt-inline-program-functions
        (ast.ast-node-pool-reader-type-segment-bases)
        (ir.compiler-ir-function-seq-prepend
          caller
          (ir.compiler-ir-function-seq-prepend
            (compiler_optimize_tests.opt-inline-nonleaf-callee symbols)
            (ir.compiler-ir-function-seq-empty)))
        2)]
    (match (opt.opt-function-seq-find optimized "main")
      [(opt.OptMaybeFunction.Some main)
        (opt.opt-function-eq
          (ast.ast-node-pool-reader-type-segment-bases)
          main
          caller)]
      [(opt.OptMaybeFunction.No) false])))

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
(define (smoke-c27-params) : ir.CompilerIrParamList
  (ir.compiler-ir-param-cons
    (ir.CompilerIrParam.Param "cond" (ast.AstType.Bool) 0)
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "x" (ast.AstType.I64) 1)
      (ir.CompilerIrParamList.Nil))))

(define (smoke-c27-if-convert-function [computed-arm? : bool]) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (compiler_optimize_tests.opt-test-symbol "c27_if_convert")
    (smoke-c27-params)
    (ast.AstType.I64)
    8
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler_optimize_tests.opt-test-instrs
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "header")
          (compiler_optimize_tests.opt-test-instrs
            (ir.CompilerIrInstr.Phi
              2
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.I64 0)
                (ir.compiler-ir-label "entry")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 6)
                  (ir.compiler-ir-label "merge")
                  (ir.CompilerIrPhiInputList.Nil)))
              (ast.AstType.I64))
            (ir.CompilerIrInstr.BinOp
              5
              ir.CompilerIrBinOp.Gt
              (ir.CompilerIrValue.Var 1)
              (ir.CompilerIrValue.I64 0)
              (ast.AstType.I64))
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Var 5)
              (ir.compiler-ir-label "then")
              (ir.compiler-ir-label "else"))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "then")
            (if computed-arm?
              (compiler_optimize_tests.opt-test-instrs
                (ir.CompilerIrInstr.BinOp
                  3
                  ir.CompilerIrBinOp.Add
                  (ir.CompilerIrValue.Var 1)
                  (ir.CompilerIrValue.I64 1)
                  (ast.AstType.I64))
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge")))
              (compiler_optimize_tests.opt-test-instrs
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge")))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "else")
              (compiler_optimize_tests.opt-test-instrs
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge"))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "merge")
                (compiler_optimize_tests.opt-test-instrs
                  (ir.CompilerIrInstr.Phi
                    4
                    (ir.compiler-ir-phi-input-cons
                      (if computed-arm?
                        (ir.CompilerIrValue.Var 3)
                        (ir.CompilerIrValue.Var 1))
                      (ir.compiler-ir-label "then")
                      (ir.compiler-ir-phi-input-cons
                        (ir.CompilerIrValue.Var 1)
                        (ir.compiler-ir-label "else")
                        (ir.CompilerIrPhiInputList.Nil)))
                    (ast.AstType.I64))
                  (ir.CompilerIrInstr.BinOp
                    6
                    ir.CompilerIrBinOp.Add
                    (ir.CompilerIrValue.Var 2)
                    (ir.CompilerIrValue.I64 1)
                    (ast.AstType.I64))
                  (ir.CompilerIrInstr.BinOp
                    7
                    ir.CompilerIrBinOp.Lt
                    (ir.CompilerIrValue.Var 6)
                    (ir.CompilerIrValue.I64 2)
                    (ast.AstType.I64))
                  (ir.CompilerIrInstr.Branch
                    (ir.CompilerIrValue.Var 7)
                    (ir.compiler-ir-label "header")
                    (ir.compiler-ir-label "exit"))))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "exit")
                  (compiler_optimize_tests.opt-test-instrs
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 4)))))
                (ir.CompilerIrBlockList.Nil)))))))))

(define (smoke-c27-count-scalar-selects-instrs
  [instrs : ir.CompilerIrInstrSeq]
  [index : i64]) : i64
  (if (>= index (ir.compiler-ir-instr-seq-count instrs))
    0
    (+
      (match (ir.compiler-ir-instr-seq-ref instrs index)
        [(ir.CompilerIrInstr.Select payload-box)
          (let
            [lanes (__tl-project-field (__tl-box-place payload-box) lanes)]
            (if (= lanes 0)
              1
              0))]
        [_ 0])
      (smoke-c27-count-scalar-selects-instrs instrs (+ index 1)))))

(define (smoke-c27-count-scalar-selects [blocks : ir.CompilerIrBlockList]) : i64
  (match (ir.compiler-ir-block-list-force-cons blocks)
    [(ir.CompilerIrBlockList.Nil) 0]
    [(ir.CompilerIrBlockList.Array seq)
      (smoke-c27-count-scalar-selects (ir.compiler-ir-block-seq-to-list seq))]
    [(ir.CompilerIrBlockList.Cons block rest)
      (match block
        [(ir.CompilerIrBlock.Block _ instrs)
          (+
            (smoke-c27-count-scalar-selects-instrs instrs 0)
            (smoke-c27-count-scalar-selects (__tl-box-place rest)))])]))

(define (smoke-c27-count-binop-instrs
  [instrs : ir.CompilerIrInstrSeq]
  [index : i64]
  [wanted : ir.CompilerIrBinOp]) : i64
  (if (>= index (ir.compiler-ir-instr-seq-count instrs))
    0
    (+
      (match (ir.compiler-ir-instr-seq-ref instrs index)
        [(ir.CompilerIrInstr.BinOp _ op _ _ _)
          (if (= (opt.opt-binop-tag op) (opt.opt-binop-tag wanted))
            1
            0)]
        [_ 0])
      (smoke-c27-count-binop-instrs instrs (+ index 1) wanted))))

(define (smoke-c27-count-binop
  [blocks : ir.CompilerIrBlockList]
  [wanted : ir.CompilerIrBinOp]) : i64
  (match (ir.compiler-ir-block-list-force-cons blocks)
    [(ir.CompilerIrBlockList.Nil) 0]
    [(ir.CompilerIrBlockList.Array seq)
      (smoke-c27-count-binop (ir.compiler-ir-block-seq-to-list seq) wanted)]
    [(ir.CompilerIrBlockList.Cons block rest)
      (match block
        [(ir.CompilerIrBlock.Block _ instrs)
          (+
            (smoke-c27-count-binop-instrs instrs 0 wanted)
            (smoke-c27-count-binop (__tl-box-place rest) wanted))])]))

(define (smoke-c27-compare-function [extra-use? : bool]) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (compiler_optimize_tests.opt-test-symbol "c27_bit_test")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "x" (ast.AstType.I64) 0)
      (ir.CompilerIrParamList.Nil))
    (ast.AstType.I64)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler_optimize_tests.opt-test-instrs-with-tail
          (if extra-use?
            (compiler_optimize_tests.opt-test-instrs
              (ir.CompilerIrInstr.BinOp
                3
                ir.CompilerIrBinOp.Add
                (ir.CompilerIrValue.Var 1)
                (ir.CompilerIrValue.Var 2)
                (ast.AstType.I64))
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3))))
            (compiler_optimize_tests.opt-test-instrs
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))))
          (ir.CompilerIrInstr.BinOp
            1
            ir.CompilerIrBinOp.BitAnd
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.I64 1)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.BinOp
            2
            ir.CompilerIrBinOp.Gt
            (ir.CompilerIrValue.Var 1)
            (ir.CompilerIrValue.I64 0)
            (ast.AstType.I64))))
      (ir.CompilerIrBlockList.Nil))))

(define (smoke-c27-if-convert-compare-self-test) : i64
  (let
    [converted : ir.CompilerIrFunction
      (opt.opt-if-convert-function
        (ast.ast-node-pool-reader-type-segment-bases)
        (smoke-c27-if-convert-function false))]
    [conditional : ir.CompilerIrFunction
      (opt.opt-if-convert-function
        (ast.ast-node-pool-reader-type-segment-bases)
        (smoke-c27-if-convert-function true))]
    [single-use : ir.CompilerIrFunction
      (match (smoke-c27-compare-function false)
        [(ir.CompilerIrFunction.Function name params ret frame blocks)
          (ir.CompilerIrFunction.Function
            name
            params
            ret
            frame
            (opt.opt-dce-block-list-array
              (opt.opt-collect-blocks-uses-array frame blocks)
              blocks))])]
    [multi-use : ir.CompilerIrFunction
      (match (smoke-c27-compare-function true)
        [(ir.CompilerIrFunction.Function name params ret frame blocks)
          (ir.CompilerIrFunction.Function
            name
            params
            ret
            frame
            (opt.opt-dce-block-list-array
              (opt.opt-collect-blocks-uses-array frame blocks)
              blocks))])]
    [converted-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks converted)]
    [conditional-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks conditional)]
    [single-blocks : ir.CompilerIrBlockList
      (opt.opt-function-blocks single-use)]
    [multi-blocks : ir.CompilerIrBlockList (opt.opt-function-blocks multi-use)]
    (cond
      [(not (= (smoke-c27-count-scalar-selects converted-blocks) 1)) 1]
      [(not (= (ir.compiler-ir-block-list-count converted-blocks) 4)) 2]
      [(not (= (smoke-c27-count-scalar-selects conditional-blocks) 0)) 3]
      [(not
          (=
            (smoke-c27-count-binop single-blocks ir.CompilerIrBinOp.BitTestNe)
            1))
        4]
      [(not
          (=
            (smoke-c27-count-binop multi-blocks ir.CompilerIrBinOp.BitTestNe)
            0))
        5]
      [(not (= (smoke-c27-count-binop multi-blocks ir.CompilerIrBinOp.Gt) 1)) 6]
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
  (ir.CompilerIrFunction.Function
    (compiler_optimize_tests.opt-test-symbol "c27_mask_test")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "x" (ast.AstType.I64) 0)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "m" (ast.AstType.I64) 1)
        (ir.CompilerIrParamList.Nil)))
    (ast.AstType.I64)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler_optimize_tests.opt-test-instrs
          (ir.CompilerIrInstr.BinOp
            2
            ir.CompilerIrBinOp.BitAnd
            (ir.CompilerIrValue.Var 0)
            and-mask
            (ast.AstType.I64))
          (ir.CompilerIrInstr.BinOp
            3
            cmp-op
            (ir.CompilerIrValue.Var 2)
            (ir.CompilerIrValue.I64 cmp-const)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.Return
            (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))))
      (ir.CompilerIrBlockList.Nil))))

(define (smoke-c27-mask-dce-blocks [fn : ir.CompilerIrFunction]) : ir.CompilerIrBlockList
  (opt.opt-function-blocks
    (match fn
      [(ir.CompilerIrFunction.Function name params ret frame blocks)
        (ir.CompilerIrFunction.Function
          name
          params
          ret
          frame
          (opt.opt-dce-block-list-array
            (opt.opt-collect-blocks-uses-array frame blocks)
            blocks))])))

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
    [ne : i64 (smoke-c27-count-binop blocks ir.CompilerIrBinOp.BitTestNe)]
    [eq : i64 (smoke-c27-count-binop blocks ir.CompilerIrBinOp.BitTestEq)]
    [ands : i64 (smoke-c27-count-binop blocks ir.CompilerIrBinOp.BitAnd)]
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
      (smoke-c27-mask-dce-blocks
        (smoke-c27-mask-compare-function
          (ir.CompilerIrValue.I64 1)
          ir.CompilerIrBinOp.Eq
          1))]
    [twice : ir.CompilerIrBlockList
      (opt.opt-dce-block-list-array
        (opt.opt-collect-blocks-uses-array 4 once)
        once)]
    (and
      (= (smoke-c27-count-binop twice ir.CompilerIrBinOp.BitTestNe) 1)
      (= (smoke-c27-count-binop twice ir.CompilerIrBinOp.BitAnd) 0))))

;; Returns 42 only when single-bit mask-test admission fires on exactly the
;; admitted shapes, with the INVERTED mapping, and leaves every neighbouring
;; shape byte-for-byte alone.
(define (smoke-c27-mask-test-admission-self-test) : i64
  (cond
    ;; `(x & 1) == 1` is "bit set", which is ZF CLEAR -> BitTestNe.
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 1)
            ir.CompilerIrBinOp.Eq
            1)
          1))
      1]
    ;; `(x & 8) != 8` is "bit clear", which is ZF SET -> BitTestEq.
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 8)
            ir.CompilerIrBinOp.Ne
            8)
          2))
      2]
    ;; Boundary single-bit masks: the 32-bit edge and the highest bit the
    ;; `> 0` guard still admits.
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 2147483648)
            ir.CompilerIrBinOp.Eq
            2147483648)
          1))
      3]
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 4611686018427387904)
            ir.CompilerIrBinOp.Ne
            4611686018427387904)
          2))
      4]
    ;; `1 << 63` is stored negative, so the `> 0` guard refuses it.
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 (smoke-c27-i64-min))
            ir.CompilerIrBinOp.Eq
            (smoke-c27-i64-min))
          0))
      5]
    ;; A multi-bit mask asks whether BOTH bits are set; `test` cannot answer.
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 3)
            ir.CompilerIrBinOp.Eq
            3)
          0))
      6]
    ;; The comparison constant is not the mask.
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 4)
            ir.CompilerIrBinOp.Eq
            1)
          0))
      7]
    ;; Ordered compares against the mask are a constant fold, not a bit test.
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 1)
            ir.CompilerIrBinOp.Le
            1)
          0))
      8]
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 1)
            ir.CompilerIrBinOp.Gt
            1)
          0))
      9]
    ;; A non-literal mask names no bit.
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.Var 1)
            ir.CompilerIrBinOp.Eq
            1)
          0))
      10]
    ;; The compare-against-zero mapping is untouched, in both directions and
    ;; with the multi-bit mask it still admits.
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 1)
            ir.CompilerIrBinOp.Eq
            0)
          2))
      11]
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 1)
            ir.CompilerIrBinOp.Ne
            0)
          1))
      12]
    [(not
        (=
          (smoke-c27-mask-shape
            (ir.CompilerIrValue.I64 3)
            ir.CompilerIrBinOp.Eq
            0)
          2))
      13]
    [(not (smoke-c27-mask-idempotent?)) 14]
    [else 42]))

(define (smoke-optimizer-late-self-tests) : i64
  (begin
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-callgraph-self-test"
      (compiler_optimize_tests.compiler-optimize-callgraph-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-scc-self-test"
      (compiler_optimize_tests.compiler-optimize-scc-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-inline-self-test"
      (compiler_optimize_tests.compiler-optimize-inline-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-inline-two-multiblock-self-test"
      (compiler_optimize_tests.compiler-optimize-inline-two-multiblock-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-inline-phi-predecessor-self-test"
      (smoke-inline-phi-predecessor-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-fixed-point-self-test"
      (compiler_optimize_tests.compiler-optimize-fixed-point-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-tailrec-self-test"
      (compiler_optimize_tests.compiler-optimize-tailrec-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-global-dce-self-test"
      (compiler_optimize_tests.compiler-optimize-global-dce-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-aggregate-candidate-self-test"
      (compiler_optimize_tests.compiler-optimize-aggregate-candidate-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-aggregate-promote-self-test"
      (compiler_optimize_tests.compiler-optimize-aggregate-promote-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-aggregate-sroa-self-test"
      (compiler_optimize_tests.compiler-optimize-aggregate-sroa-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-spans-self-test"
      (compiler_optimize_tests.compiler-optimize-spans-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-gvn-self-test"
      (compiler_optimize_tests.compiler-optimize-gvn-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-heavy-pass-large-gvn-self-test"
      (smoke-heavy-pass-large-gvn-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-load-cse-self-test"
      (compiler_optimize_tests.compiler-optimize-load-cse-self-test)
      44)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-dead-store-self-test"
      (compiler_optimize_tests.compiler-optimize-dead-store-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-scratch-region-self-test"
      (compiler_optimize_tests.compiler-optimize-scratch-region-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-function-index-leaf-starts-self-test"
      (smoke-function-index-leaf-starts-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-switch-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-switch-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-second-exit-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-second-exit-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-fuse-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-fuse-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-second-exit-refusal-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-second-exit-refusal-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-merged-body-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-merged-body-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-merged-body-refusal-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-merged-body-refusal-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-negative-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-negative-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-fold-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-fold-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-fold-refusal-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-fold-refusal-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-nest-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-nest-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-reject-skip-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-reject-skip-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-pipeline-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-pipeline-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-partial-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-partial-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-p5a-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-p5a-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-unroll-p5a-remainder-self-test"
      (compiler_optimize_tests.compiler-optimize-unroll-p5a-remainder-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bce-version-mb-paired-self-test"
      (compiler_optimize_tests.compiler-optimize-bce-version-mb-paired-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-debug-verifier-self-test"
      (compiler_optimize_tests.compiler-optimize-debug-verifier-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-gep-split-self-test"
      (compiler_optimize_tests.compiler-optimize-gep-split-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-flag-exit-self-test"
      (compiler_optimize_tests.compiler-optimize-flag-exit-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-flag-exit-general-self-test"
      (compiler_optimize_tests.compiler-optimize-flag-exit-general-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-dead-phi-self-test"
      (compiler_optimize_tests.compiler-optimize-dead-phi-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-dce-pack-self-test"
      (compiler_optimize_tests.compiler-optimize-dce-pack-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-cmp-sink-self-test"
      (compiler_optimize_tests.compiler-optimize-cmp-sink-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-load-sink-self-test"
      (compiler_optimize_tests.compiler-optimize-load-sink-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-cmp-dup-self-test"
      (compiler_optimize_tests.compiler-optimize-cmp-dup-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-ubound-self-test"
      (compiler_optimize_tests.compiler-optimize-ubound-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-ubound-refusal-self-test"
      (compiler_optimize_tests.compiler-optimize-ubound-refusal-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-ubound-tangled-self-test"
      (compiler_optimize_tests.compiler-optimize-ubound-tangled-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bounds-group-self-test"
      (compiler_optimize_tests.compiler-optimize-bounds-group-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bounds-group-offset-self-test"
      (compiler_optimize_tests.compiler-optimize-bounds-group-offset-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bounds-group-refusal-self-test"
      (compiler_optimize_tests.compiler-optimize-bounds-group-refusal-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-successor-sink-self-test"
      (compiler_optimize_tests.compiler-optimize-successor-sink-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-c27-if-convert-compare-self-test"
      (smoke-c27-if-convert-compare-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "smoke-c27-mask-test-admission-self-test"
      (smoke-c27-mask-test-admission-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bit-test-equality-self-test"
      (compiler_optimize_tests.compiler-optimize-bit-test-equality-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bit-test-range-self-test"
      (compiler_optimize_tests.compiler-optimize-bit-test-range-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bit-test-refusal-self-test"
      (compiler_optimize_tests.compiler-optimize-bit-test-refusal-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-bit-test-runtime-self-test"
      (compiler_optimize_tests.compiler-optimize-bit-test-runtime-self-test)
      42)
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-exit-split-label-freshness-self-test"
      (compiler_optimize_tests.compiler-optimize-exit-split-label-freshness-self-test)
      42)
    42))

(define (main) : i64
  (begin
    (compiler_optimize_tests.compiler-optimize-self-test-require-i64!
      "compiler-optimize-runtime-call-identity-self-test"
      (compiler_optimize_tests.compiler-optimize-runtime-call-identity-self-test)
      42)
    (smoke-optimizer-core-self-tests)
    (smoke-optimizer-loop-self-tests)
    (smoke-optimizer-late-self-tests)
    42))

(test
  load-cse-copybytes-forwarding
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-load-cse-self-test)
    44
    "load-cse copybytes forwarding"))

(test
  optimizer-alias-fact-model
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-alias-self-test)
    42
    "optimizer alias fact model"))

(test
  inline-multiblock-switch-absorbable
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-multiblock-switch-ok?)
    "absorbable acyclic bounds+switch callee inlines with fresh CFG/phi labels"))

(test
  inline-multiblock-cyclic-bounds-switch-admission
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-multiblock-cyclic-bounds-switch-admission-ok?)
    "a one-reference cyclic bounds+switch callee is taken in a loop-free caller, bounds check and cloned CFG intact"))

(test
  inline-vm-run-bounds-loop-exception
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-vm-run-bounds-loop-ok?)
    "vm-run and the same-shaped qs-partition both inline at opt2 on shape, not on name; opt1 still refuses both"))

(test
  inline-bounds-loop-in-loop-site
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-bounds-loop-in-loop-site-ok?)
    "small absorbable bounds loop leaf inlines at an in-loop call site"))

(test
  inline-bounds-loop-cold-site-admission
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-bounds-loop-cold-site-admission-ok?)
    "the same leaf is taken at a straight-line site of a loop-free caller: no caller loop is there to tax"))

(test
  inline-checked-depth-weighting
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-checked-depth-weighting-ok?)
    "the measured tier prices a body at the depth an inline would put it, and the weight ladder saturates"))

(test
  inline-checked-window
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-checked-window-ok?)
    "the accept window is two-sided: the model must agree with a free inline within a factor of two"))

(test
  inline-checked-budget
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-checked-budget-ok?)
    "the program budget counts verdicts and the tier arms and disarms"))

(test
  inline-checked-band-exclusion
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-checked-band-exclusion-ok?)
    "a band-admitted site never reaches the check, so a banked program spends no budget"))

(test
  inline-checked-call-carrying-verdicts
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-inline-checked-call-carrying-self-test)
    3000111
    "the tier prices call-carrying candidates the bands refuse, keeps the ones whose plan repays, and every function verifies"))

(test
  inline-checked-call-carrying-deep-verdicts
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-inline-checked-call-carrying-deep-self-test)
    200
    "the tier keeps a call-carrying site one loop deeper too, and both callers verify"))

(test
  inline-checked-call-carrying-revert
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-checked-call-carrying-revert-ok?)
    "the same call-carrying callee reverts when its measured plan does not repay the boundary"))

(test
  inline-multiblock-call-clone-spans
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-spans-inline-multiblock-call-ok?)
    "the spans clone walk rebases a cloned call and re-keys its span under the caller"))

(test
  inline-multiblock-clone-abort-span
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-clone-abort-span-ok?)
    "an abort inside a cloned call-carrying callee keeps the callee's span in a release build"))

(test
  inline-chain-second-import-call
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-chain-second-import-call-ok?)
    "a chain absorbed bottom-up re-clones an already cloned call and leaves one call in the caller"))

(test
  inline-checked-sequence-two-sites
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-checked-sequence-two-sites-ok?)
    "two sites of one callee are priced richest-first and both kept, each against the state before it"))

(test
  inline-checked-sequence-partial
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-checked-sequence-partial-ok?)
    "a caller keeps its first site and reverts its second: the rollback is per site, not per caller"))

(test
  inline-checked-richness
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-checked-richness-ok?)
    "sites are ordered by what a free inline is worth, per unit of the caller's growth budget it spends"))

(test
  inline-checked-caller-cap
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-checked-caller-cap-ok?)
    "one caller cannot drain the program's verdict budget"))

(test
  inline-checked-one-callee
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-checked-one-callee-ok?)
    "a caller's later sites are restricted to the callee its first accept named"))

(test
  inline-bounds-loop-cascade-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-bounds-loop-cascade-refusal-ok?)
    "import refused when it would cost a bounds-free single-site caller its own inline"))

(test
  inline-single-site-wide-absorb
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-wide-absorb-ok?)
    "a 220-instruction ten-parameter single-site callee absorbs whole at its one cold site"))

(test
  inline-single-site-wide-loop-site-absorb
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-wide-loop-site-absorb-ok?)
    "the same unbounded body absorbs at an in-loop site: the boundary retires per iteration"))

(test
  inline-single-site-narrow-small-caller-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-narrow-small-caller-refusal-ok?)
    "below the arity floor the body stays out of line even in a two-block caller"))

(test
  inline-single-site-narrow-large-caller-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-narrow-large-caller-refusal-ok?)
    "below the arity floor and past the narrow caller band, the body stays out of line"))

(test
  inline-single-site-narrow-loop-site-absorb
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-narrow-loop-site-absorb-ok?)
    "below the arity floor a small call-free body still moves at an in-loop site"))

(test
  inline-single-site-narrow-straight-site-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-narrow-straight-site-refusal-ok?)
    "the same body at a straight-line site stays out: below the floor there is no marshalling to retire"))

(test
  inline-single-site-narrow-oversize-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-narrow-oversize-refusal-ok?)
    "past the loop tier's size class the in-loop waiver stops admitting a below-floor boundary"))

(test
  inline-single-site-size-cap-absorb
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-size-cap-absorb-ok?)
    "a single-site callee at the pathological backstop still absorbs: no growth to bound"))

(test
  inline-single-site-size-cap-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-size-cap-refusal-ok?)
    "one block past the backstop the same body stays out of line"))

(test
  inline-single-site-absorb-keeps-block-fuel
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-absorb-keeps-block-fuel-ok?)
    "a moved body does not spend the shared growth budget the cost model draws on"))

(test
  inline-single-site-two-reference-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-two-reference-refusal-ok?)
    "two cold sites keep the body at both: this band moves, it never copies"))

(test
  inline-single-site-self-recursive-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-self-recursive-refusal-ok?)
    "a self-calling callee counts two references and is refused"))

(test
  inline-single-site-call-bearing-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-call-bearing-refusal-ok?)
    "a wide single-site callee that calls out stays out of line: the band cannot price its callee's calls"))

(test
  inline-single-site-loop-site-call-bearing-absorb
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-loop-site-call-bearing-absorb-ok?)
    "the same call-carrying callee absorbs at an in-loop site: its calls already ran per iteration"))

(test
  inline-single-site-cascade-site
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-cascade-site-ok?)
    "the cascade clause refuses at a straight-line site and comes off at an in-loop one"))

(test
  inline-single-site-address-taken-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-single-site-address-taken-refusal-ok?)
    "an address-taken callee is refused even at one call site"))

(test
  inline-single-site-cascade
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-inline-single-site-cascade-depth-code)
    0
    "a three-deep single-site chain collapses into one function in a single pass"))

(test
  inline-dup-two-site
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-dup-two-site-ok?)
    "a two-reference call-free leaf is duplicated into both in-loop sites"))

(test
  inline-dup-cascade-per-caller
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-dup-cascade-per-caller-ok?)
    "the cascade clause is asked per caller: the same duplicable leaf is refused at one site and admitted at the other"))

(test
  inline-dup-call-bearing-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-dup-call-bearing-refusal-ok?)
    "a two-reference leaf carrying a call stays out of line at both sites"))

(test
  inline-hot-loop-leaf-three-site
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-three-site-ok?)
    "a call-free cyclic leaf past the duplication ceiling is copied into every in-loop site"))

(test
  inline-hot-loop-leaf-call-bearing-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-call-bearing-refusal-ok?)
    "a multi-reference loop leaf carrying a call stays out of line at every site"))

(test
  inline-hot-loop-leaf-too-big-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-too-big-refusal-ok?)
    "a multi-reference loop leaf one instruction past the band stays out of line"))

(test
  inline-hot-loop-leaf-in-loop-small-caller
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-in-loop-small-caller-ok?)
    "a big-tier loop leaf is admitted at an in-loop site when the caller is small enough"))

(test
  inline-hot-loop-leaf-in-loop-big-caller-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-in-loop-big-caller-refusal-ok?)
    "the same leaf at in-loop sites of callers past the size cap stays out of line"))

(test
  inline-hot-loop-leaf-loop-free-site
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-loop-free-site-ok?)
    "a loop-free caller takes the loop leaf at a straight-line site: no caller loop is there to tax"))

(test
  inline-hot-loop-leaf-cold-site-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-cold-site-refusal-ok?)
    "a call in a looping caller's exit block stays out of line: neither repayment clause fires"))

(test
  inline-hot-loop-leaf-budget-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-budget-refusal-ok?)
    "five copies fit the per-caller block fuel; the sixth site keeps its call"))

(test
  inline-hot-loop-leaf-single-reference
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-single-reference-ok?)
    "a one-reference big-tier loop leaf is taken at its in-loop site: the band starts at one reference, not three"))

(test
  inline-hot-loop-leaf-single-reference-too-big-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-single-reference-too-big-refusal-ok?)
    "the size ceiling still binds at one reference: a leaf one instruction past the band keeps its call"))

(test
  inline-hot-loop-leaf-single-reference-call-bearing-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-hot-loop-leaf-single-reference-call-bearing-refusal-ok?)
    "the call-free pricing clause still binds at one reference: a big-tier leaf carrying a call keeps its boundary"))

(test
  inline-shared-accessor-floor
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-shared-accessor-floor-ok?)
    "an acyclic accessor at the reference floor is taken at every in-loop site; one reference short stays out of line"))

(test
  inline-shared-accessor-call-free
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-shared-accessor-call-free-ok?)
    "a shared accessor carrying a call stays out of line at every site"))

(test
  inline-shared-accessor-acyclic
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-shared-accessor-acyclic-ok?)
    "a cyclic call-bearing body at the same shared sites stays out of line: both gates refuse it"))

(test
  inline-shared-accessor-in-loop-site
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-shared-accessor-in-loop-site-ok?)
    "the same accessor at straight-line sites stays out of line"))

(test
  inline-shared-accessor-dominant-floor
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-shared-accessor-dominant-floor-ok?)
    "an accessor at the dominant reference floor is taken at every straight-line site; one reference short keeps every call"))

(test
  inline-shared-accessor-dominant-call-free
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-shared-accessor-dominant-call-free-ok?)
    "a call-bearing body at the dominant floor stays out of line at every straight-line site"))

(test
  inline-accessor-depth-weight
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-accessor-depth-weight-ok?)
    "two nested-loop sites weigh 128 and take the accessor; the same two sites one loop shallower weigh 16 and keep both calls"))

(test
  inline-accessor-depth-oversize-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-accessor-depth-oversize-refusal-ok?)
    "a body past the accessor block ceiling stays out of line at the same nested-loop sites"))

(test
  inline-accessor-depth-bounds-admission
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-accessor-depth-bounds-admission-ok?)
    "a bounds-carrying body is taken at two nested-loop sites and kept behind its call one loop shallower: the weight decides, not the bounds check"))

(test
  inline-depth-multiple-latches
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-depth-multiple-latches-ok?)
    "multiple backedges to one loop header contribute one depth level"))

(test
  inline-branch-chain-site
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-branch-chain-site-ok?)
    "a bounds-free acyclic decision chain past the block cap is taken at both in-loop sites"))

(test
  inline-branch-chain-merge-web
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-branch-chain-merge-web-ok?)
    "the same block count with one working block stays out of line: the chain gate prices blocks, not shapes"))

(test
  inline-vm-run-bounds-loop-span-positive
  (test.assert-i64-eq
    (compiler_optimize_tests.opt-inline-switch-span-case-code
      "bench.tl::vm-run"
      true
      2)
    15
    "span-aware inliner admits exact vm-run and preserves cloned spans"))

(test
  inline-qs-partition-bounds-loop-span-positive
  (test.assert-i64-eq
    (compiler_optimize_tests.opt-inline-switch-span-case-code
      "bench.tl::qs-partition"
      true
      2)
    15
    "the similarly shaped qs-partition loop is admitted on its shape now, not on a name, and its cloned spans survive"))

(test
  inline-vm-run-bounds-loop-span-negative
  (test.assert-i64-eq
    (compiler_optimize_tests.opt-inline-switch-span-case-code
      "bench.tl::vm-run"
      false
      1)
    15
    "below opt2 the multiblock inliner does not run: the call survives with its caller-side span intact"))

(test
  inline-multiblock-switch-cost-refusal
  (test.assert-true
    (compiler_optimize_tests.compiler-optimize-inline-multiblock-switch-cost-refusal-ok?)
    "multi-site switch callee above the weighted cost threshold stays uninlined"))

(cfg
  test
  (test
    licm-checked-root-disjointness
    (test.assert-i64-eq
      (compiler_optimize_tests.compiler-optimize-licm-checked-root-self-test)
      42
      "LICM checked-reference root disjointness")))

(test
  dead-store-overwrite
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-dead-store-self-test)
    42
    "dead-store overwrite"))

(test
  bce-version-multiblock-quicksort-shape
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-self-test)
    42
    "multi-block counted-loop bounds-check versioning"))

(test
  bce-version-multiblock-switch-cloning
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-switch-self-test)
    42
    "multi-block versioning remaps total-switch case and trap edges"))

(test
  bce-version-multiblock-second-exit
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-second-exit-self-test)
    42
    "multi-block versioning admits a second exiting branch on the guard chain"))

(test
  bce-version-multiblock-second-exit-boundaries
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-second-exit-refusal-self-test)
    42
    "guard-chain admission keeps chain checks and refuses diamonds and unproven far uses"))

(test
  bce-version-multiblock-merged-body
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-merged-body-self-test)
    42
    "multi-block versioning admits an absorbed body's exit join and clones it"))

(test
  bce-version-multiblock-merged-body-boundaries
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-merged-body-refusal-self-test)
    42
    "exit-join admission refuses loop-edge joins, checked joins and outside arms"))

(test
  bce-version-cross-array-fusion
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-fuse-self-test)
    42
    "cross-array fusion removes dominated checks, covered stores included"))

(test
  bce-version-multiblock-rejections
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-negative-self-test)
    42
    "multi-block versioning rejections"))

(test
  bce-version-guard-dominated-fold
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-fold-self-test)
    42
    "versioning guard facts fold dominated compares in the fast clone"))

(test
  bce-version-guard-dominated-fold-refusals
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-fold-refusal-self-test)
    42
    "guard-dominated compare folding refuses everything past its three rules"))

(test
  bce-version-multiblock-loop-nest
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-nest-self-test)
    42
    "multi-block versioning admits loop nests under the nest budget"))

(test
  bce-version-rejection-retires-one-loop
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-reject-skip-self-test)
    42
    "a refused versioning retires that loop, not the function's other loops"))

(test
  bce-version-multiblock-pipeline
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-pipeline-self-test)
    42
    "multi-block versioning full pipeline"))

(test
  unroll-store-free-simd-body
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-unroll-self-test)
    42
    "16x unrolling remaps every admitted store-free SIMD instruction"))

(test
  unroll-load-store-body-two-copies
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-unroll-load-store-self-test)
    42
    "a load-and-store counted loop unrolls twice while a store-only body keeps sixteen"))

(test
  unroll-versioned-multiblock-quicksort-shape
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-unroll-mb-self-test)
    42
    "2x unrolling of the check-free versioned conditional diamond"))

(test
  bce-version-multiblock-partial
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-partial-self-test)
    42
    "multi-block versioning keeps underivable checks in the fast clone"))

(test
  bce-version-p5a-shifted-limits
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-p5a-self-test)
    42
    "shifted-limit compares, counter+K indices and the minimized guard version"))

(test
  bce-version-multiblock-paired-checks
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bce-version-mb-paired-self-test)
    42
    "late in-place pairing combines adjacent affine bounds checks"))

(test
  optimizer-debug-verifier-identity
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-debug-verifier-self-test)
    42
    "IR verifier failures include function, block, and instruction identity"))

(test
  gep-use-splitting
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-gep-split-self-test)
    42
    "Gep use-splitting clones multi-use address Geps per memory use"))

(test
  dce-pack-retirement
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-dce-pack-self-test)
    42
    "Pipeline DCE retires a Pack whose extractions all folded"))

(test
  cmp-sink-to-branch
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-cmp-sink-self-test)
    42
    "Sinking a loop-closing compare next to its branch"))

(test
  load-sink-to-alu-consumer
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-load-sink-self-test)
    42
    "Sinking single-use gep;load pairs next to their consuming ALU ops"))

(test
  cmp-dup-per-branch-copies
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-cmp-dup-self-test)
    42
    "Late compare duplication gives each branch its own fusable compare"))

(test
  single-predecessor-successor-sink
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-successor-sink-self-test)
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
    (compiler_optimize_tests.compiler-optimize-bit-test-equality-self-test)
    42
    "A six-way equality classifier chain becomes one windowed mask test"))

(test
  bit-test-range-chain
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bit-test-range-self-test)
    42
    "Closed ranges and equalities share one mask over a subtracted base"))

(test
  bit-test-refusals
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bit-test-refusal-self-test)
    42
    "Mixed values, impure links, wide windows, short chains and unsigned compares are refused"))

(test
  bit-test-runtime-boundaries
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bit-test-runtime-self-test)
    42
    "The source-level classifier preserves hits, gaps, window edges and out-of-window values"))

(test
  exit-split-sink-label-freshness
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-exit-split-label-freshness-self-test)
    42
    "Sunk exit checks keep the legacy name when free, step generation when taken, and emit one block per predecessor"))

(test
  dom-cmp-phi-carried-compare
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-dom-cmp-phi-carried-self-test)
    42
    "a rotated loop's header test folds when both joining edges decide it, and is refused when they disagree or one decides nothing"))

(test
  ubound-narrowed-loop-test
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-ubound-self-test)
    42
    "a multi-path advance loop drops its header check for one unsigned test against min(bound, length), and the rewrite is idempotent"))

(test
  ubound-refusals
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-ubound-refusal-self-test)
    42
    "a missing entry guard, an opaque length, an instruction ahead of the check, a second reader of the loop compare and a negative seed are refused"))

(test
  bounds-group-coalescing
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bounds-group-self-test)
    42
    "a parallel-array body drops one of its two checks for a single unsigned filter over the smaller length, with the originals kept on a slow arm"))

(test
  bounds-group-offset-coalescing
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bounds-group-offset-self-test)
    42
    "i and i+1 against one length collapse to one saturating bound"))

(test
  bounds-group-coalescing-refusals
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-bounds-group-refusal-self-test)
    42
    "a body-defined length, a loopless block and an already-split block are refused"))

(test
  ubound-tangled-phi-web
  (test.assert-i64-eq
    (compiler_optimize_tests.compiler-optimize-ubound-tangled-self-test)
    42
    "mutually dependent header phis and a three-edge phi terminate the search and are refused"))