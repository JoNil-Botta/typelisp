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
(import "../compiler_optimize.tl")
(import stdlib.string)
(import stdlib.test)

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
  (match (opt-cfg-find-block blocks "entry")
    [(OptMaybeBlock.No) (- 0 1)]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (= (compiler-ir-instr-seq-count instrs) 1)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Switch _ base _ _) base]
              [_ (- 0 1)])
            (- 0 1))])]))

(define (opt-switch-entry-case-count [blocks : CompilerIrBlockList]) : i64
  (match (opt-cfg-find-block blocks "entry")
    [(OptMaybeBlock.No) 0]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (= (compiler-ir-instr-seq-count instrs) 1)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Switch _ _ cases _)
                (opt-switch-case-list-count cases)]
              [_ 0])
            0)])]))

(define (opt-switch-entry-default-label [blocks : CompilerIrBlockList]) : String
  (match (opt-cfg-find-block blocks "entry")
    [(OptMaybeBlock.No) ""]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (= (compiler-ir-instr-seq-count instrs) 1)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Switch _ _ _ default-label) default-label]
              [_ ""])
            "")])]))

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
  [label : String]
  [tag : i64]
  [eq-var : i64]
  [arm-label : String]
  [next-label : String]) : CompilerIrBlock
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
  [label : String]
  [tag : i64]
  [eq-var : i64]
  [arm-label : String]
  [next-label : String]) : CompilerIrBlock
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

(define (opt-switch-test-return-block [label : String] [value : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return
        (CompilerIrMaybeValue.Some (CompilerIrValue.I64 value)))
      (CompilerIrInstrList.Nil))))

;; Head block whose compare+branch trails an unconditional prefix instruction:
;; the chain pass must keep the prefix ahead of the emitted Switch.
(define (opt-switch-test-prefix-compare-block
  [label : String]
  [tag : i64]
  [eq-var : i64]
  [arm-label : String]
  [next-label : String]) : CompilerIrBlock
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
        [_ (- 0 1)])]))

(define (opt-switch-test-block-tail-case-count [block : CompilerIrBlock]) : i64
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-ir-instr-seq-ref
        instrs
        (- (compiler-ir-instr-seq-count instrs) 1))
        [(CompilerIrInstr.Switch _ _ cases _)
          (opt-switch-case-list-count cases)]
        [_ 0])]))

(define (opt-switch-test-block-tail-default [block : CompilerIrBlock]) : String
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-ir-instr-seq-ref
        instrs
        (- (compiler-ir-instr-seq-count instrs) 1))
        [(CompilerIrInstr.Switch _ _ _ default-label) default-label]
        [_ ""])]))

(define (opt-switch-test-block-starts-with-mov? [block : CompilerIrBlock]) : bool
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-ir-instr-seq-ref instrs 0)
        [(CompilerIrInstr.Mov _ _ _) true]
        [_ false])]))

(define (opt-switch-test-chain-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : String]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-compare-block "entry" tag0 1 "case0" "cmp1")
    (compiler-ir-block-cons
      (opt-switch-test-return-block "case0" 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block "cmp1" tag1 2 "case1" "cmp2")
        (compiler-ir-block-cons
          (opt-switch-test-return-block "case1" 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block "cmp2" tag2 3 "case2" "cmp3")
            (compiler-ir-block-cons
              (opt-switch-test-return-block "case2" 12)
              (compiler-ir-block-cons
                (opt-switch-test-compare-block
                  "cmp3"
                  tag3
                  4
                  "case3"
                  default-label)
                (compiler-ir-block-cons
                  (opt-switch-test-return-block "case3" 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (CompilerIrBlockList.Nil)))))))))))

(define (opt-switch-test-short-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-compare-block "entry" 0 1 "case0" "cmp1")
    (compiler-ir-block-cons
      (opt-switch-test-return-block "case0" 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block "cmp1" 1 2 "case1" "cmp2")
        (compiler-ir-block-cons
          (opt-switch-test-return-block "case1" 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block "cmp2" 2 3 "case2" "fallback")
            (compiler-ir-block-cons
              (opt-switch-test-return-block "case2" 12)
              (compiler-ir-block-cons
                (opt-switch-test-return-block "fallback" 99)
                (CompilerIrBlockList.Nil)))))))))

(define (opt-switch-test-extra-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-extra-compare-block "entry" 0 1 "case0" "cmp1")
    (compiler-ir-block-cons
      (opt-switch-test-return-block "case0" 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block "cmp1" 1 2 "case1" "cmp2")
        (compiler-ir-block-cons
          (opt-switch-test-return-block "case1" 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block "cmp2" 2 3 "case2" "cmp3")
            (compiler-ir-block-cons
              (opt-switch-test-return-block "case2" 12)
              (compiler-ir-block-cons
                (opt-switch-test-compare-block "cmp3" 3 4 "case3" "fallback")
                (compiler-ir-block-cons
                  (opt-switch-test-return-block "case3" 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block "fallback" 99)
                    (CompilerIrBlockList.Nil)))))))))))

(define (opt-switch-test-prefix-blocks
  [tag0 : i64]
  [tag1 : i64]
  [tag2 : i64]
  [tag3 : i64]
  [default-label : String]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-prefix-compare-block "entry" tag0 1 "case0" "cmp1")
    (compiler-ir-block-cons
      (opt-switch-test-return-block "case0" 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block "cmp1" tag1 2 "case1" "cmp2")
        (compiler-ir-block-cons
          (opt-switch-test-return-block "case1" 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block "cmp2" tag2 3 "case2" "cmp3")
            (compiler-ir-block-cons
              (opt-switch-test-return-block "case2" 12)
              (compiler-ir-block-cons
                (opt-switch-test-compare-block
                  "cmp3"
                  tag3
                  4
                  "case3"
                  default-label)
                (compiler-ir-block-cons
                  (opt-switch-test-return-block "case3" 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (CompilerIrBlockList.Nil)))))))))))

;; Head block whose dispatch is a bare zero-test branch (`Eq tag, 0` folded
;; onto the tag var), again trailing an unconditional prefix instruction.
(define (opt-switch-test-bare-branch-block
  [label : String]
  [arm-label : String]
  [next-label : String]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 9 (CompilerIrValue.Var 0) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch (CompilerIrValue.Var 0) next-label arm-label)
        (CompilerIrInstrList.Nil)))))

(define (opt-switch-test-bare-blocks [default-label : String]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-switch-test-bare-branch-block "entry" "case0" "cmp1")
    (compiler-ir-block-cons
      (opt-switch-test-return-block "case0" 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block "cmp1" 1 2 "case1" "cmp2")
        (compiler-ir-block-cons
          (opt-switch-test-return-block "case1" 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block "cmp2" 2 3 "case2" "cmp3")
            (compiler-ir-block-cons
              (opt-switch-test-return-block "case2" 12)
              (compiler-ir-block-cons
                (opt-switch-test-compare-block "cmp3" 3 4 "case3" default-label)
                (compiler-ir-block-cons
                  (opt-switch-test-return-block "case3" 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (CompilerIrBlockList.Nil)))))))))))

;; Compare block testing an explicit compare var (for copy-resolution tests).
(define (opt-switch-test-compare-block-var
  [label : String]
  [cmp-var : i64]
  [tag : i64]
  [eq-var : i64]
  [arm-label : String]
  [next-label : String]) : CompilerIrBlock
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
(define (opt-switch-test-copy-head-blocks [default-label : String]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
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
            (CompilerIrInstr.Branch (CompilerIrValue.Var 1) "case0" "cmp1")
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (opt-switch-test-return-block "case0" 10)
      (compiler-ir-block-cons
        (opt-switch-test-compare-block-var "cmp1" 9 1 2 "case1" "cmp2")
        (compiler-ir-block-cons
          (opt-switch-test-return-block "case1" 11)
          (compiler-ir-block-cons
            (opt-switch-test-compare-block-var "cmp2" 9 2 3 "case2" "cmp3")
            (compiler-ir-block-cons
              (opt-switch-test-return-block "case2" 12)
              (compiler-ir-block-cons
                (opt-switch-test-compare-block-var
                  "cmp3"
                  9
                  3
                  4
                  "case3"
                  default-label)
                (compiler-ir-block-cons
                  (opt-switch-test-return-block "case3" 13)
                  (compiler-ir-block-cons
                    (opt-switch-test-return-block default-label 99)
                    (CompilerIrBlockList.Nil)))))))))))

(define (compiler-optimize-switch-form-self-test) : i64
  (let
    [dense-source : CompilerIrBlockList
      (opt-switch-test-chain-blocks 2 0 1 3 "fallback")]
    [dense : CompilerIrFunction
      (opt-switch-form-function (opt-switch-test-function dense-source))]
    [dense-blocks : CompilerIrBlockList (opt-function-blocks dense)]
    [short : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-short-blocks)))]
    [sparse : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks 0 1 3 4 "fallback")))]
    [duplicate : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-chain-blocks 0 1 1 2 "fallback")))]
    [extra : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-extra-blocks)))]
    [prefix : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function
          (opt-switch-test-prefix-blocks 2 0 1 3 "fallback")))]
    [prefix-blocks : CompilerIrBlockList (opt-function-blocks prefix)]
    [prefix-twice : CompilerIrFunction (opt-switch-form-function prefix)]
    [prefix-entry : CompilerIrBlock
      (match (opt-cfg-find-block prefix-blocks "entry")
        [(OptMaybeBlock.No) (opt-switch-test-return-block "missing" 0)]
        [(OptMaybeBlock.Some block) block])]
    [bare : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-bare-blocks "fallback")))]
    [bare-blocks : CompilerIrBlockList (opt-function-blocks bare)]
    [bare-entry : CompilerIrBlock
      (match (opt-cfg-find-block bare-blocks "entry")
        [(OptMaybeBlock.No) (opt-switch-test-return-block "missing" 0)]
        [(OptMaybeBlock.Some block) block])]
    [copy-head : CompilerIrFunction
      (opt-switch-form-function
        (opt-switch-test-function (opt-switch-test-copy-head-blocks "fallback")))]
    [copy-head-blocks : CompilerIrBlockList (opt-function-blocks copy-head)]
    [copy-head-entry : CompilerIrBlock
      (match (opt-cfg-find-block copy-head-blocks "entry")
        [(OptMaybeBlock.No) (opt-switch-test-return-block "missing" 0)]
        [(OptMaybeBlock.Some block) block])]
    [level1 : CompilerIrFunction
      (optimize-function-with-level (opt-switch-test-function dense-source) 1)]
    [level2 : CompilerIrFunction
      (optimize-function-with-level (opt-switch-test-function dense-source) 2)]
    (cond
      [(not (= (opt-count-switch-blocks dense-blocks) 1)) 1]
      [(not (= (opt-switch-entry-base dense-blocks) 0)) 2]
      [(not (= (opt-switch-entry-case-count dense-blocks) 4)) 3]
      [(not
          (string.eq (opt-switch-entry-default-label dense-blocks) "fallback"))
        4]
      [(opt-block-list-has-label? dense-blocks "cmp1") 5]
      [(opt-block-list-has-label? dense-blocks "cmp2") 6]
      [(opt-block-list-has-label? dense-blocks "cmp3") 7]
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
          (string.eq
            (opt-switch-test-block-tail-default prefix-entry)
            "fallback"))
        18]
      [(not (opt-switch-test-block-starts-with-mov? prefix-entry)) 19]
      [(opt-block-list-has-label? prefix-blocks "cmp1") 20]
      [(opt-block-list-has-label? prefix-blocks "cmp2") 21]
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
          (string.eq (opt-switch-test-block-tail-default bare-entry) "fallback"))
        27]
      [(not (opt-switch-test-block-starts-with-mov? bare-entry)) 28]
      [(not (opt-verify-ok? (opt-verify-function bare))) 29]
      ;; The vm_run shape: head compare on the raw var, middle compares on
      ;; the prefix Mov's copy; resolution unifies them and the chain forms.
      [(not (= (opt-count-switch-blocks copy-head-blocks) 1)) 30]
      [(not (= (opt-switch-test-block-tail-base copy-head-entry) 0)) 31]
      [(not (= (opt-switch-test-block-tail-case-count copy-head-entry) 4)) 32]
      [(not
          (string.eq
            (opt-switch-test-block-tail-default copy-head-entry)
            "fallback"))
        33]
      [(not (opt-switch-test-block-starts-with-mov? copy-head-entry)) 34]
      [(not (opt-verify-ok? (opt-verify-function copy-head))) 35]
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
            (and (= s src) (opt-type-eq mov-ty ty))
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
              (opt-type-eq cast-from from-ty)
              (opt-type-eq cast-to to-ty))
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
      (opt-fold-instrs (OptConstEnv.Nil) (smoke-noop-int-cast-mov-instrs))]
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
  [label : String]
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
    "bounds_ok.0"
    (smoke-bounds-object-length-check-fragment
      20
      21
      22
      second-object
      offset
      slot-ty
      (CompilerIrValue.Var 0)
      "bounds_ok.1"
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
    "bounds_ok.0"
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
        "bounds_ok.1"
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
    "bounds_ok.0"
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
        "bounds_ok.1"
        (CompilerIrInstrList.Nil)))))

(define (smoke-object-bounds-self-test) : i64
  (let
    [object-array : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-pair
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 1)
          (AstType.I64)))]
    [object-string : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-pair
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 8)
          (AstType.U8)))]
    [object-mismatch : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-pair
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 1)
          (AstType.I64)))]
    [object-call : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-call-barrier))]
    [object-store : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (smoke-bounds-object-store-barrier (CompilerIrValue.Var 10)))]
    [object-element-store : CompilerIrInstrList
      (opt-bounds-instrs
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
    "entry"
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
                (CompilerIrInstr.Branch (CompilerIrValue.Var 14) "lt" "exit")
                (CompilerIrInstrList.Nil)))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump "lt")
              (CompilerIrInstrList.Nil))))))))

(define (smoke-range-bce-lt [op : CompilerIrBinOp] [length-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    "lt"
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        15
        op
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var length-var)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch (CompilerIrValue.Var 15) "body" "exit")
        (CompilerIrInstrList.Nil)))))

(define (smoke-range-bce-body) : CompilerIrBlock
  (compiler-ir-block
    "body"
    (opt-loop-bce-string-test-ref-instrs
      2
      30
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 37)))
        (CompilerIrInstrList.Nil)))))

(define (smoke-range-bce-redefined-body) : CompilerIrBlock
  (compiler-ir-block
    "body"
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
        (opt-loop-bce-test-summaries symbols false false)
        (opt-loop-bce-string-test-params)
        (smoke-range-bce-blocks with-nonnegative op length-var)))))

(define (smoke-range-bce-redefined-count) : i64
  (let
    [symbols : OptLoopBceTestSymbols (opt-loop-bce-test-symbols)]
    (opt-count-bounds-blocks
      (opt-loop-bce-blocks
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
    "entry"
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        3
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 1 (CompilerIrValue.Var 3) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump "header")
          (CompilerIrInstrList.Nil))))))

(define (smoke-ssa-iv-bce-header
  [start : CompilerIrValue]
  [next-var : i64]
  [op : CompilerIrBinOp]
  [upper-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    "header"
    (compiler-ir-instr-cons
      (CompilerIrInstr.Phi
        0
        (compiler-ir-phi-input-cons
          start
          "entry"
          (compiler-ir-phi-input-cons
            (CompilerIrValue.Var next-var)
            "body"
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
          (CompilerIrInstr.Branch (CompilerIrValue.Var 4) "body" "exit")
          (CompilerIrInstrList.Nil))))))

(define (smoke-ssa-iv-bce-body
  [symbols : OptLoopBceTestSymbols]
  [object-var : i64]
  [step : i64]
  [next-var : i64]
  [with-call : bool]
  [redefine-index : bool]) : CompilerIrBlock
  (compiler-ir-block
    "body"
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
              (CompilerIrInstr.Jump "header")
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
    "header"
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        43
        op
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 40)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch (CompilerIrValue.Var 43) "body" "exit")
        (CompilerIrInstrList.Nil)))))

(define (smoke-nonlength-guard-body [object-var : i64] [redefine-bound : bool]) : CompilerIrBlock
  (compiler-ir-block
    "body"
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
                  "str_bounds_ok")
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
    "entry"
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
                    "header"
                    "exit")
                  (CompilerIrInstrList.Nil)))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump "header")
                (CompilerIrInstrList.Nil)))))))))

(define (smoke-additive-header [op : CompilerIrBinOp] [upper-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    "header"
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        43
        op
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var upper-var)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch (CompilerIrValue.Var 43) "body" "exit")
        (CompilerIrInstrList.Nil)))))

(define (smoke-additive-body [offset : i64] [redefine-index : bool]) : CompilerIrBlock
  (compiler-ir-block
    "body"
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
    "entry"
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
              (CompilerIrInstr.Branch (CompilerIrValue.Var 42) "header" "exit")
              (CompilerIrInstrList.Nil))))))))

(define (smoke-additive-wrap-risk-header) : CompilerIrBlock
  (compiler-ir-block
    "header"
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        43
        (CompilerIrBinOp.Lt)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 40)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch (CompilerIrValue.Var 43) "body" "exit")
        (CompilerIrInstrList.Nil)))))

(define (smoke-additive-wrap-risk-body) : CompilerIrBlock
  (compiler-ir-block
    "body"
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
          "bounds_ok")
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

(define (smoke-heavy-pass-large-label [index : i64]) : String
  (string.append "b" (string.int->string index)))

(define (smoke-heavy-pass-large-jump-block [index : i64] [next : String]) : CompilerIrBlock
  (compiler-ir-block
    (smoke-heavy-pass-large-label index)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Jump next)
      (CompilerIrInstrList.Nil))))

(define (smoke-heavy-pass-large-exit-block) : CompilerIrBlock
  (compiler-ir-block
    "exit"
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
          "exit"
          (smoke-heavy-pass-large-label (+ index 1))))
      (smoke-heavy-pass-large-tail-blocks (+ index 1) last))))

(define (smoke-heavy-pass-large-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
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
      (optimize-function-once (smoke-heavy-pass-large-function))]
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

(define (smoke-optimizer-core-self-tests) : i64
  (cond
    [(not (= (compiler-optimize-self-test) 42)) 1]
    [(not (= (compiler-optimize-typed-fold-self-test) 42)) 2]
    [(not (= (smoke-noop-int-cast-mov-self-test) 42)) 3]
    [(not (= (compiler-optimize-strength-self-test) 42)) 4]
    [(not (= (compiler-optimize-dce-self-test) 42)) 5]
    [(not (= (compiler-optimize-dce-mem-self-test) 42)) 6]
    [(not (= (compiler-optimize-divrem-safety-self-test) 42)) 7]
    [(not (= (compiler-optimize-const-divisor-self-test) 42)) 8]
    [(not (= (compiler-optimize-cse-self-test) 42)) 9]
    [(not (= (compiler-optimize-copy-self-test) 42)) 10]
    [(not (= (compiler-optimize-bounds-self-test) 42)) 11]
    [(not (= (compiler-optimize-bounds-dom-self-test) 42)) 12]
    [(not (= (smoke-object-bounds-self-test) 42)) 13]
    [(not (= (smoke-range-bce-self-test) 42)) 14]
    [(not (= (smoke-ssa-iv-bce-self-test) 42)) 15]
    [(not (= (smoke-nonlength-guard-bce-self-test) 42)) 16]
    [(not (= (smoke-additive-bce-self-test) 42)) 17]
    [(not (= (compiler-optimize-sccp-self-test) 42)) 18]
    [else 42]))

(define (smoke-optimizer-loop-self-tests) : i64
  (cond
    [(not (= (compiler-optimize-global-value-number-self-test) 42)) 19]
    [(not (= (compiler-optimize-cfg-self-test) 42)) 20]
    [(not (= (compiler-optimize-switch-form-self-test) 42)) 21]
    [(not (= (compiler-optimize-natural-loop-self-test) 42)) 22]
    [(not (= (compiler-optimize-loop-rotation-self-test) 42)) 23]
    [(not (= (compiler-optimize-rotate-ssa-self-test) 42)) 24]
    [(not (= (compiler-optimize-licm-self-test) 42)) 25]
    [(not (= (compiler-optimize-induction-self-test) 42)) 26]
    [(not (= (compiler-optimize-unroll-self-test) 42)) 27]
    [(not (= (compiler-optimize-affine-self-test) 42)) 28]
    [(not (= (compiler-optimize-affine-pipeline-self-test) 42)) 29]
    [(not (= (compiler-optimize-ssa-preexisting-phi-self-test) 42)) 30]
    [(not (= (compiler-optimize-licm-multi-exit-self-test) 42)) 31]
    [(not (= (compiler-optimize-bce-version-self-test) 42)) 32]
    [(not (= (compiler-optimize-bce-version-pipeline-self-test) 42)) 33]
    [(not (= (compiler-optimize-ssa-self-test) 42)) 34]
    [(not (= (compiler-optimize-level-self-test) 42)) 35]
    [else 42]))

(define (smoke-optimizer-late-self-tests) : i64
  (cond
    [(not (= (compiler-optimize-callgraph-self-test) 42)) 36]
    [(not (= (compiler-optimize-scc-self-test) 42)) 37]
    [(not (= (compiler-optimize-inline-self-test) 42)) 38]
    [(not (= (compiler-optimize-fixed-point-self-test) 42)) 39]
    [(not (= (compiler-optimize-tailrec-self-test) 42)) 40]
    [(not (= (compiler-optimize-global-dce-self-test) 42)) 41]
    [(not (= (compiler-optimize-aggregate-candidate-self-test) 42)) 42]
    [(not (= (compiler-optimize-aggregate-promote-self-test) 42)) 43]
    [(not (= (compiler-optimize-aggregate-sroa-self-test) 42)) 44]
    [(not (= (compiler-optimize-spans-self-test) 42)) 45]
    [(not (= (compiler-optimize-gvn-self-test) 42)) 46]
    [(not (= (smoke-heavy-pass-large-gvn-self-test) 42)) 47]
    [(not (= (compiler-optimize-load-cse-self-test) 44)) 48]
    [(not (= (compiler-optimize-dead-store-self-test) 42)) 49]
    [(not (= (compiler-optimize-scratch-region-self-test) 42)) 50]
    [(not (= (smoke-function-index-leaf-starts-self-test) 42)) 51]
    [(not (= (compiler-optimize-bce-version-mb-self-test) 42)) 52]
    [(not (= (compiler-optimize-bce-version-mb-negative-self-test) 42)) 53]
    [(not (= (compiler-optimize-bce-version-mb-pipeline-self-test) 42)) 54]
    [(not (= (compiler-optimize-bce-version-mb-partial-self-test) 42)) 55]
    [(not (= (compiler-optimize-debug-verifier-self-test) 42)) 56]
    [else 42]))

(define (main) : i64
  (let
    [core : i64 (smoke-optimizer-core-self-tests)]
    (if (not (= core 42))
      core
      (let
        [loops : i64 (smoke-optimizer-loop-self-tests)]
        (if (not (= loops 42))
          loops
          (smoke-optimizer-late-self-tests))))))

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
  bce-version-multiblock-partial
  (test.assert-i64-eq
    (compiler-optimize-bce-version-mb-partial-self-test)
    42
    "multi-block versioning keeps underivable checks in the fast clone"))

(test
  optimizer-debug-verifier-identity
  (test.assert-i64-eq
    (compiler-optimize-debug-verifier-self-test)
    42
    "IR verifier failures include function, block, and instruction identity"))