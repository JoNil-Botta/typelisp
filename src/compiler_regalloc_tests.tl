;; compiler_regalloc_tests.tl - Selfhost register-allocator fixtures split
;; from production (#5169).
;;
;; Only blocks gated on exactly `test` moved. The regalloc-census blocks and
;; the `(any regalloc-census test)` ones stay in the production module: they
;; compile into instrumentation builds, so they are not self-test code.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_regalloc as reg)
(import compiler_profile_state as profile_state)
(import compiler_abi as cabi)
(import compiler_liveness as live)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import stdlib.io)
(cfg test (import stdlib.string))
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as reg_string_i64_map)
(import (hashmap.hashmap i64 i64) as reg_i64_i64_map)
(cfg test (import stdlib.test))

;; Fixture-side dense prepend. Each result owns fresh backing storage, so
;; independently built fixtures never share mutable instruction slots.
(define (compiler-reg-test-instr-seq-prepend
  [instr : ir.CompilerIrInstr]
  [rest : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
  (let
    [builder : ir.CompilerIrInstrBuilder
      (ir.compiler-ir-instr-builder-with-capacity (+ rest.len 1))]
    (begin
      (ir.compiler-ir-instr-builder-push! (&mut builder) instr)
      (ir.compiler-ir-instr-builder-append-seq-range!
        (&mut builder)
        rest
        0
        rest.len)
      (ir.compiler-ir-instr-builder-to-seq builder))))

(cfg
  test
  (define (compiler-reg-low-bit-index32-powers-ok? [bit : i64] [value : i64]) : bool
    (if (= bit 32)
      (and
        (= (reg.compiler-reg-low-bit-index32 0) 31)
        (= (reg.compiler-reg-low-bit-index32 0x100000000) 31))
      (and
        (= (reg.compiler-reg-low-bit-index32 value) bit)
        (compiler-reg-low-bit-index32-powers-ok? (+ bit 1) (* value 2))))))

(cfg
  test
  (define (compiler-reg-call-word-range-case [index : i64]) : i64
    (if (= index 0)
      0
      (if (= index 1)
        1
        (if (= index 2)
          2
          (if (= index 3)
            0x80000000
            (if (= index 4)
              0xffffffff
              (if (= index 5)
                0x100000000
                (if (= index 6)
                  0x100000001
                  (if (= index 7)
                    0x300000000
                    0x80000001))))))))))

(cfg
  test
  (define (compiler-reg-call-word-range-base [index : i64]) : i64
    (if (= index 0)
      0
      (if (= index 1)
        1
        (if (= index 2)
          25
          31)))))

;; Differential oracle for the mask rewrite of `compiler-reg-call-word-in-range?`.
;; `compiler-reg-call-word-count-in-range` still has the original shape -- walk
;; the set bits through `compiler-reg-low-bit-index32` and range-test each one --
;; so "any bit in range" must equal "the walk counted more than zero" for every
;; input. A disagreement is a miscompile in interference testing, not a slow
;; compile.
;;
;; The bases reach 31 and the ranges pass 40 on purpose: that is the only way to
;; exercise the edge case the rewrite folds in, where a word carrying bits above
;; position 31 reports position 31 because `compiler-reg-low-bit-index32` masks
;; to `0xffffffff` and answers 31 for an empty low word.
(cfg
  test
  (define (compiler-reg-call-word-in-range-matches-walk?) : bool
    (let
      [ok : bool true]
      [case-index : i64 0]
      (begin
        (while (< case-index 9)
          (let
            [bits : i64 (compiler-reg-call-word-range-case case-index)]
            [base-index : i64 0]
            (begin
              (while (< base-index 4)
                (let
                  [base : i64 (compiler-reg-call-word-range-base base-index)]
                  [start : i64 -2]
                  (begin
                    (while (< start 34)
                      (let
                        [end : i64 start]
                        (begin
                          (while (< end 42)
                            (begin
                              (if (=
                                (reg.compiler-reg-call-word-in-range?
                                  bits
                                  base
                                  start
                                  end)
                                (>
                                  (reg.compiler-reg-call-word-count-in-range
                                    bits
                                    base
                                    start
                                    end)
                                  0))
                                unit
                                (set! ok false))
                              (set! end (+ end 1))))
                          (set! start (+ start 1)))))
                    (set! base-index (+ base-index 1)))))
              (set! case-index (+ case-index 1)))))
        ok))))

(define (compiler-reg-remat-defn-with-invariant-loads?
  [instr : ir.CompilerIrInstr]
  [allow-invariant-loads : bool]) : bool
  (match instr
    [(ir.CompilerIrInstr.Mov _ value _)
      (reg.compiler-reg-remat-mov-value? value allow-invariant-loads)]
    [(ir.CompilerIrInstr.Gep _ base offset _)
      (reg.compiler-reg-remat-gep? base offset)]
    [(ir.CompilerIrInstr.Load _ src _)
      (reg.compiler-reg-remat-load? src allow-invariant-loads)]
    [_ false]))

(define (compiler-reg-remat-defn? [instr : ir.CompilerIrInstr]) : bool
  (compiler-reg-remat-defn-with-invariant-loads? instr false))

(define (compiler-reg-function-ref-counts [func : ir.CompilerIrFunction]) : (__tl_dyn-array
    i64)
  (match func
    [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
      (let
        [counts : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
        (begin
          (reg.compiler-reg-fill-i64-array counts 0)
          (reg.compiler-reg-ref-counts-blocks! counts blocks)
          counts))]))

(define (compiler-reg-function-spill-weights-remat
  [func : ir.CompilerIrFunction]
  [coalesce : reg.CompilerRegCoalesceMap]) : (__tl_dyn-array i64)
  (match func
    [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
      (let
        [counts : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
        [def-status : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
        [rebates : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
        [depths : (__tl_dyn-array i64)
          (reg.compiler-reg-function-loop-depths blocks)]
        [allow-invariant-loads : bool
          (reg.compiler-reg-remat-invariant-loads-ok? func)]
        (begin
          (reg.compiler-reg-fill-i64-array counts 0)
          (reg.compiler-reg-fill-i64-array def-status 0)
          (reg.compiler-reg-fill-i64-array rebates 0)
          (reg.compiler-reg-ref-counts-blocks-weighted-remat!
            counts
            def-status
            rebates
            blocks
            depths
            0
            allow-invariant-loads)
          (reg.compiler-reg-remat-discount-single-def-spill-weights!
            counts
            def-status
            coalesce)
          counts))]))

;; One-pass spill weights for the scalar-opt2 greedy: the remat walk accumulates
;; the exact raw use/def counts the plain spill-weights walk computes (same
;; adds, plus the def-status tracking), so the two per-function walks collapse
;; into one. Returns the same combined array as
;; (combine (merge (remat-discounted weights)) (merge (raw weights))).
(define (compiler-reg-edge-copy-plan-for-region
  [func : ir.CompilerIrFunction]
  [region-labels : reg.CompilerRegLabelSeq]
  [stack-var : i64]
  [region-var : i64]
  [ty : ast.AstType]) : reg.CompilerRegEdgeCopyPlan
  ;; Per-var (read-only / non-phi self-loop) planning: empty member set selects
  ;; the existing per-var liveness test in boundary-one (byte-identical).
  (reg.compiler-reg-edge-copy-plan-for-region-members
    func
    region-labels
    stack-var
    region-var
    ty
    (live.compiler-live-set-empty)))

;; Group-aware planning for the SplitKit phi-carried homing: `members` is the
;; coalesce group's bitset; boundary edges are tested against any-member liveness.
(define (compiler-reg-plan-function-avx2 [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
  (reg.compiler-reg-plan-function-avx2-for-abi
    cabi.CompilerRegTargetAbi.Linux
    func))

;; Scalar register plan (#perf, opt level 2): full dataflow live intervals for
;; ALL functions, structural ineligibility that keeps call-spanning
;; integers/handles in callee-saved registers and applies ABI XMM clobber
;; constraints to float candidates.
;;
;; The precise (segmented, hole-aware) interval builder feeds
;; compiler-reg-vars-interfere-segmented-index?, whose exact segment-overlap test
;; only fires when BOTH values carry segments; otherwise it falls back to the
;; coarse whole-[start,end] overlap, which manufactures phantom conflicts between
;; values whose live ranges are actually disjoint. The cheap block-level builder
;; (compiler-reg-block-intervals) leaves segments empty, so every function on it
;; is stuck with that conservative fallback.
;;
;; History (M-D): precise intervals were once limited to 2-10-block functions,
;; then extended to >= 100 blocks (#regalloc: -90 net static stack reloads in
;; the self-host's huge walkers, full-liveness compile cost negligible). The
;; 11-99-block band and single-block functions were deliberately kept coarse
;; because a measurement AT THAT TIME showed precise intervals in the medium
;; band perturbed the greedy spill-victim/eviction heuristics non-monotonically
;; and net-regressed reloads. That measurement predates params-as-greedy-
;; candidates (M-A) and dead result-store elision (M-B), which reshaped the
;; interference/pressure landscape; re-measured after M-B, precise intervals
;; everywhere are a net win, so every scalar-mode function now gets the precise
;; builder (single-block functions included: multi-def vars with disjoint
;; single-block ranges suffer the same phantom conflicts under the coarse
;; fallback, and the M-A param entry-extension below runs on the interval
;; index regardless of builder). This predicate also gates the loop-split
;; rescue passes, which require the precise index; they now run for every
;; function shape. The coarse compiler-reg-block-intervals branch in
;; compiler-reg-plan-function-scalar-for-abi is kept as the fallback: flipping
;; this predicate is the single switch back should a pathological shape appear.
;;
;; NOTE: enabling this detonated a LATENT BACKEND BUG, fixed together with it:
;; precise mid-band plans saturate the register pool, so the backend's
;; EMERGENCY scavenge (all pool regs occupied) started firing in fused
;; destructure emitters, where its candidate pick ignored the sibling load's
;; register home and the emergency-wrap restore overwrote the just-loaded
;; result (false OOB abort in lex-parse-based-int). See the M-D clobber fix in
;; compiler-backend-emit-load-from-gep-pair / compiler-backend-emit-load-load.
(cfg
  test
  (define (compiler-reg-early-exit-general-test-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "early_exit_general")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "n" (ast.AstType.I64) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "limit" (ast.AstType.I64) 1)
          ir.CompilerIrParamList.Nil))
      (ast.AstType.I64)
      5
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              2
              (ir.CompilerIrBinOp.Le)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 0)
              (ast.AstType.I64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 2)
                (ir.compiler-ir-label "zero")
                (ir.compiler-ir-label "guard_limit"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "zero")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 0)))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "guard_limit")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  3
                  (ir.CompilerIrBinOp.Gt)
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.Var 1)
                  (ast.AstType.I64))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Branch
                    (ir.CompilerIrValue.Var 3)
                    (ir.compiler-ir-label "one")
                    (ir.compiler-ir-label "body"))
                  (ir.compiler-ir-instr-seq-empty))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "one")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 1)))
                  (ir.compiler-ir-instr-seq-empty)))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "body")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Call
                      4
                      (ir.compiler-ir-test-symbol "work")
                      ir.CompilerIrCallArgs.Nil
                      (ast.AstType.I64))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "entry"))
                      (ir.compiler-ir-instr-seq-empty))))
                ir.CompilerIrBlockList.Nil))))))))

(cfg
  test
  (define (compiler-reg-early-exit-general-ok?) : bool
    (match (reg.compiler-reg-early-exit-shrinkwrap-function
      (compiler-reg-early-exit-general-test-function))
      [(ir.CompilerIrFunction.Function _ params ret-ty _ blocks)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [body : ir.CompilerIrInstrSeq
            (match (ir.compiler-ir-block-seq-ref seq 5)
              [(ir.CompilerIrBlock.Block _ instrs) instrs])]
          (and
            (= (ir.compiler-ir-param-list-count params) 2)
            (match ret-ty
              [(ast.AstType.I64) true]
              [_ false])
            (= (ir.compiler-ir-block-seq-count seq) 10)
            (= reg.compiler-reg-early-exit-prefix-count 4)
            (=
              reg.compiler-reg-early-exit-saving-label
              (ir.compiler-ir-label "entry__shrinkwrap_save"))
            (string.eq
              (reg.compiler-reg-early-exit-bare-label-current)
              "entry__shrinkwrap_bare")
            (match (ir.compiler-ir-block-seq-ref seq 0)
              [(ir.CompilerIrBlock.Block label instrs)
                (and
                  (= label (ir.compiler-ir-label "entry"))
                  (match (ir.compiler-ir-instr-seq-ref instrs 1)
                    [(ir.CompilerIrInstr.Branch _ yes no)
                      (and
                        (= yes (ir.compiler-ir-label "entry__shrinkwrap_bare0"))
                        (= no (ir.compiler-ir-label "guard_limit")))]
                    [_ false]))])
            (match (ir.compiler-ir-block-seq-ref seq 1)
              [(ir.CompilerIrBlock.Block label instrs)
                (and
                  (= label (ir.compiler-ir-label "guard_limit"))
                  (match (ir.compiler-ir-instr-seq-ref instrs 1)
                    [(ir.CompilerIrInstr.Branch _ yes no)
                      (and
                        (= yes (ir.compiler-ir-label "entry__shrinkwrap_bare1"))
                        (= no (ir.compiler-ir-label "entry__shrinkwrap_save")))]
                    [_ false]))])
            (match (ir.compiler-ir-instr-seq-ref body 1)
              [(ir.CompilerIrInstr.Jump target)
                (= target (ir.compiler-ir-label "entry__shrinkwrap_framed"))]
              [_ false])
            (match (ir.compiler-ir-block-seq-ref seq 7)
              [(ir.CompilerIrBlock.Block label _)
                (=
                  label
                  (ir.compiler-ir-label "guard_limit__shrinkwrap_framed"))])))])))

(cfg
  test
  (define (compiler-reg-early-exit-float-guard-test-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "early_exit_float_guard")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "actual" (ast.AstType.F64) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "expected" (ast.AstType.F64) 1)
          ir.CompilerIrParamList.Nil))
      (ast.AstType.Unit)
      4
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              2
              (ir.CompilerIrBinOp.Eq)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 1)
              (ast.AstType.F64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 2)
                (ir.compiler-ir-label "equal")
                (ir.compiler-ir-label "failure"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "equal")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "failure")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Call
                  3
                  (ir.compiler-ir-test-symbol "report_float_failure")
                  ir.CompilerIrCallArgs.Nil
                  (ast.AstType.Unit))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  (ir.compiler-ir-instr-seq-empty))))
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-early-exit-float-guard-refused-ok?) : bool
    (match (reg.compiler-reg-early-exit-shrinkwrap-function
      (compiler-reg-early-exit-float-guard-test-function))
      [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
        (and
          (=
            (ir.compiler-ir-block-seq-count
              (live.compiler-live-ir-block-list-to-seq blocks))
            3)
          (= reg.compiler-reg-early-exit-prefix-count 0)
          (not
            (ir.compiler-ir-label-some?
              reg.compiler-reg-early-exit-saving-label))
          (string.eq (reg.compiler-reg-early-exit-bare-label-current) ""))])))

(cfg
  test
  (define (compiler-reg-cold-call-test-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "cold_call_split")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "map" (compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "key" (compiler-reg-i64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "value" (compiler-reg-i64-ty) 2)
            ir.CompilerIrParamList.Nil)))
      (ast.AstType.I64)
      6
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Bool false)
              (ir.compiler-ir-label "cold")
              (ir.compiler-ir-label "bypass"))
            (ir.compiler-ir-instr-seq-empty)))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "cold")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                3
                (ir.compiler-ir-test-symbol "grow")
                (ir.CompilerIrCallArgs.Nil)
                (ast.AstType.Unit))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "bypass")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "join")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.BinOp
                    4
                    (ir.CompilerIrBinOp.Add)
                    (ir.CompilerIrValue.Var 0)
                    (ir.CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.BinOp
                      5
                      (ir.CompilerIrBinOp.Add)
                      (ir.CompilerIrValue.Var 4)
                      (ir.CompilerIrValue.Var 2)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                      (ir.compiler-ir-instr-seq-empty)))))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "loop")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Branch
                      (ir.CompilerIrValue.Bool false)
                      (ir.compiler-ir-label "loop")
                      (ir.compiler-ir-label "exit"))
                    (ir.compiler-ir-instr-seq-empty)))
                (ir.compiler-ir-block-cons
                  (ir.CompilerIrBlock.Block
                    (ir.compiler-ir-label "exit")
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Return
                        (ir.CompilerIrMaybeValue.Some
                          (ir.CompilerIrValue.Var 5)))
                      (ir.compiler-ir-instr-seq-empty)))
                  ir.CompilerIrBlockList.Nil)))))))))

(cfg
  test
  (define (compiler-reg-cold-call-test-mov?
    [instr : ir.CompilerIrInstr]
    [dst : i64]
    [src : i64]) : bool
    (match instr
      [(ir.CompilerIrInstr.Mov found-dst (ir.CompilerIrValue.Var found-src) _)
        (and (= found-dst dst) (= found-src src))]
      [_ false])))

(cfg
  test
  (define (compiler-reg-cold-call-split-ok?) : bool
    (let
      [rewrite : reg.CompilerRegColdCallRewrite
        (reg.compiler-reg-cold-call-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          (compiler-reg-cold-call-test-function))]
      [rewritten : ir.CompilerIrFunction
        (reg.compiler-reg-cold-call-rewrite-function-value rewrite)]
      [temp-start : i64 (reg.compiler-reg-cold-call-rewrite-temp-start rewrite)]
      (match rewritten
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [seq : ir.CompilerIrBlockSeq
              (live.compiler-live-ir-block-list-to-seq blocks)]
            [instrs : ir.CompilerIrInstrSeq
              (match (ir.compiler-ir-block-seq-ref seq 1)
                [(ir.CompilerIrBlock.Block _ found) found])]
            [plan : reg.CompilerRegPlan
              (reg.compiler-reg-plan-function-scalar-cold-for-abi
                cabi.CompilerRegTargetAbi.Linux
                rewritten
                temp-start)]
            (and
              (= temp-start 6)
              (= vars 9)
              (= (ir.compiler-ir-instr-seq-count instrs) 8)
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 0)
                6
                0)
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 1)
                7
                1)
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 2)
                8
                2)
              (match (ir.compiler-ir-instr-seq-ref instrs 3)
                [(ir.CompilerIrInstr.Call _ _ _ _) true]
                [_ false])
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 4)
                0
                6)
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 5)
                1
                7)
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 6)
                2
                8)
              (match (ir.compiler-ir-instr-seq-ref instrs 7)
                [(ir.CompilerIrInstr.Jump target)
                  (= target (ir.compiler-ir-label "join"))]
                [_ false])
              (reg.compiler-reg-location-register?
                (match plan
                  [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
                    (reg.compiler-reg-assignment-lookup assignments 0)])
                cabi.compiler-reg-id-rdi)
              (reg.compiler-reg-location-register?
                (match plan
                  [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
                    (reg.compiler-reg-assignment-lookup assignments 1)])
                cabi.compiler-reg-id-rsi)
              (reg.compiler-reg-location-register?
                (match plan
                  [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
                    (reg.compiler-reg-assignment-lookup assignments 2)])
                cabi.compiler-reg-id-rdx)
              (reg.compiler-reg-cold-call-carriers-stack? plan temp-start vars)))]))))

;; --- P3 call-hole split ------------------------------------------------------
;; The block weight this round uses, and the "exit path" property it depends on:
;; a block inside a natural loop from which the loop's latch is unreachable runs
;; at most once per entry of the loop and must be charged at the loop's PARENT
;; depth. The nest builder already delivers that -- its member set is exactly the
;; blocks that reach a latch without passing the header -- and this fixture pins
;; it: `miss` sits between `body` and `exit`, is laid out INSIDE the loop's block
;; range, and returns, so it must weigh 1 while `header`, `body` and `latch`
;; weigh 8.
(cfg
  test
  (define (compiler-reg-call-hole-loop-shape-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "call_hole_loop_shape")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
            (ir.compiler-ir-instr-seq-empty)))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "header")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Branch
                  (ir.CompilerIrValue.Bool false)
                  (ir.compiler-ir-label "latch")
                  (ir.compiler-ir-label "miss"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "latch")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                  (ir.compiler-ir-instr-seq-empty)))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "miss")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 1)))
                    (ir.compiler-ir-instr-seq-empty)))
                (ir.compiler-ir-block-cons
                  (ir.CompilerIrBlock.Block
                    (ir.compiler-ir-label "exit")
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Return
                        (ir.CompilerIrMaybeValue.Some
                          (ir.CompilerIrValue.I64 0)))
                      (ir.compiler-ir-instr-seq-empty)))
                  ir.CompilerIrBlockList.Nil)))))))))

(cfg
  test
  (define (compiler-reg-call-hole-weights-ok?) : bool
    (match (compiler-reg-call-hole-loop-shape-function)
      [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
        (let
          [weights : (__tl_dyn-array i64)
            (reg.compiler-reg-call-hole-block-weights
              (reg.compiler-reg-function-loop-depths blocks))]
          (and
            ;; The ladder itself: 4 * 8^depth, capped at 8^4. The x4 scale is
            ;; what leaves the cold-arm quarter an integer at depth 0.
            (= (reg.compiler-reg-call-hole-block-weight 0) 4)
            (= (reg.compiler-reg-call-hole-block-weight 1) 32)
            (= (reg.compiler-reg-call-hole-block-weight 2) 256)
            (= (reg.compiler-reg-call-hole-block-weight 3) 2048)
            (= (reg.compiler-reg-call-hole-block-weight 4) 16384)
            (= (reg.compiler-reg-call-hole-block-weight 9) 16384)
            (= (reg.compiler-reg-call-hole-cold-arm-weight 4) 1)
            (= (reg.compiler-reg-call-hole-cold-arm-weight 32) 8)
            (= (reg.compiler-reg-call-hole-cold-arm-weight 1) 1)
            (= (array-length weights) 6)
            (= (array-ref weights 0) 4)
            (= (array-ref weights 1) 32)
            (= (array-ref weights 2) 32)
            (= (array-ref weights 3) 32)
            ;; the exit-only arm, laid out inside the loop
            (= (array-ref weights 4) 4)
            (= (array-ref weights 5) 4)))])))

;; --- P7 cold-arm discount ---------------------------------------------------
;; The PRED_CALL discount and the two things that bound it. `cold` is a depth-0
;; side arm with a call, bypassed by an empty edge: the function can reach its
;; `Return` without it and the bypass does no work it skips, so it is discounted
;; to a quarter and marked `cold`. `body` and `arm` both call from INSIDE the
;; loop and are separated by the in-loop rule instead: `body` sits on EVERY
;; header->latch path and keeps its full depth weight, while `arm` is bypassed
;; by `body -> latch` and is halved -- and neither is marked `cold`, so the csr
;; class still reads both crossings at full price. Blocks with no call are never
;; discounted, and neither is the entry block itself (it post-dominates itself).
(cfg
  test
  (define (compiler-reg-call-hole-cold-arm-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "call_hole_cold_arm")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      3
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Bool false)
              (ir.compiler-ir-label "cold")
              (ir.compiler-ir-label "join"))
            (ir.compiler-ir-instr-seq-empty)))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "cold")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                0
                (ir.compiler-ir-test-symbol "f")
                (ir.CompilerIrCallArgs.Nil)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "join")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "header")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Branch
                    (ir.CompilerIrValue.Bool false)
                    (ir.compiler-ir-label "body")
                    (ir.compiler-ir-label "exit"))
                  (ir.compiler-ir-instr-seq-empty)))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "body")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Call
                      1
                      (ir.compiler-ir-test-symbol "g")
                      (ir.CompilerIrCallArgs.Nil)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Branch
                        (ir.CompilerIrValue.Bool false)
                        (ir.compiler-ir-label "arm")
                        (ir.compiler-ir-label "latch"))
                      (ir.compiler-ir-instr-seq-empty))))
                (ir.compiler-ir-block-cons
                  (ir.CompilerIrBlock.Block
                    (ir.compiler-ir-label "arm")
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Call
                        2
                        (ir.compiler-ir-test-symbol "h")
                        (ir.CompilerIrCallArgs.Nil)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                        (ir.compiler-ir-instr-seq-empty))))
                  (ir.compiler-ir-block-cons
                    (ir.CompilerIrBlock.Block
                      (ir.compiler-ir-label "latch")
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Jump
                          (ir.compiler-ir-label "header"))
                        (ir.compiler-ir-instr-seq-empty)))
                    (ir.compiler-ir-block-cons
                      (ir.CompilerIrBlock.Block
                        (ir.compiler-ir-label "exit")
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.Return
                            (ir.CompilerIrMaybeValue.Some
                              (ir.CompilerIrValue.I64 0)))
                          (ir.compiler-ir-instr-seq-empty)))
                      ir.CompilerIrBlockList.Nil)))))))))))

(cfg
  test
  (define (compiler-reg-call-hole-cold-arm-weight-ok?) : bool
    (match (compiler-reg-call-hole-cold-arm-function)
      [(ir.CompilerIrFunction.Function self-name _ _ _ blocks)
        (let
          [arms : reg.CompilerRegCallHoleWeights
            (reg.compiler-reg-call-hole-cold-arm-weights
              (ast.ast-node-pool-reader-type-segment-bases)
              self-name
              (live.compiler-live-ir-block-list-to-seq blocks))]
          [weights : (__tl_dyn-array i64) arms.weights]
          [cold : (__tl_dyn-array bool) arms.cold]
          (and
            (= (array-length weights) 8)
            ;; entry / join: depth 0, no call
            (= (array-ref weights 0) 4)
            (not (array-ref cold 0))
            (= (array-ref weights 2) 4)
            (not (array-ref cold 2))
            ;; cold: a depth-0 side arm that calls
            (= (array-ref weights 1) 1)
            (array-ref cold 1)
            ;; header / latch: depth 1, no call
            (= (array-ref weights 3) 32)
            (not (array-ref cold 3))
            (= (array-ref weights 6) 32)
            (not (array-ref cold 6))
            ;; body: an in-loop call on every header->latch path, full weight
            (= (array-ref weights 4) 32)
            (not (array-ref cold 4))
            ;; arm: an in-loop call arm the body bypasses, halved, never `cold`
            (= (array-ref weights 5) 16)
            (not (array-ref cold 5))
            ;; exit: depth 0, no call
            (= (array-ref weights 7) 4)
            (not (array-ref cold 7))
            (= (reg.compiler-reg-call-hole-loop-arm-weight 32) 16)
            (= (reg.compiler-reg-call-hole-loop-arm-weight 1) 1)
            (compiler-reg-call-hole-bypass-loop-ok?)))])))

;; The second bound: a depth-0 call arm whose BYPASS runs a loop the arm skips
;; is not a detour and is not discounted. `fast` is the shape that matters --
;; the bounds-check-eliminated arm of a versioned region, a bulk call bypassed
;; by the scalar loop it replaces -- and it is taken essentially always, so
;; predicting it cold is how a once-called helper loses instructions it never
;; gets back.
(cfg
  test
  (define (compiler-reg-call-hole-bypass-loop-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "call_hole_bypass_loop")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Bool false)
              (ir.compiler-ir-label "fast")
              (ir.compiler-ir-label "slow"))
            (ir.compiler-ir-instr-seq-empty)))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "fast")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                0
                (ir.compiler-ir-test-symbol "bulk")
                (ir.CompilerIrCallArgs.Nil)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "slow")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Branch
                  (ir.CompilerIrValue.Bool false)
                  (ir.compiler-ir-label "slow")
                  (ir.compiler-ir-label "join"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "join")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 0)))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-call-hole-bypass-loop-ok?) : bool
    (match (compiler-reg-call-hole-bypass-loop-function)
      [(ir.CompilerIrFunction.Function self-name _ _ _ blocks)
        (let
          [arms : reg.CompilerRegCallHoleWeights
            (reg.compiler-reg-call-hole-cold-arm-weights
              (ast.ast-node-pool-reader-type-segment-bases)
              self-name
              (live.compiler-live-ir-block-list-to-seq blocks))]
          (and
            (= (array-length arms.weights) 4)
            ;; `slow` is the loop, so `fast` keeps its full depth-0 weight
            (= (array-ref arms.weights 1) 4)
            (not (array-ref arms.cold 1))
            (= (array-ref arms.weights 2) 32)
            (= (array-ref arms.weights 3) 4)))])))

;; --- P30 in-loop arm discount ------------------------------------------------
;; The versioned-region exclusion, moved inside a loop. `fast` is an in-loop arm
;; that calls, and `body -> slow -> join -> latch` bypasses it -- but that bypass
;; RUNS the inner loop `slow`, which `fast` skips, so `fast` is the cheap arm of
;; a versioned region and not a detour. It keeps its full depth weight.
;;
;; Note what makes the question answerable at all inside a loop: the from-arm
;; set stops AT the header, so "the work this iteration still does after the
;; arm" is `join`/`latch` and not, via the back edge, every block of the loop.
(cfg
  test
  (define (compiler-reg-call-hole-loop-arm-bypass-loop-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "call_hole_loop_arm_bypass_loop")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
            (ir.compiler-ir-instr-seq-empty)))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "header")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Branch
                  (ir.CompilerIrValue.Bool false)
                  (ir.compiler-ir-label "fast")
                  (ir.compiler-ir-label "slow"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "fast")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Call
                    0
                    (ir.compiler-ir-test-symbol "bulk")
                    (ir.CompilerIrCallArgs.Nil)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))
                    (ir.compiler-ir-instr-seq-empty))))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "slow")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Branch
                      (ir.CompilerIrValue.Bool false)
                      (ir.compiler-ir-label "slow")
                      (ir.compiler-ir-label "join"))
                    (ir.compiler-ir-instr-seq-empty)))
                (ir.compiler-ir-block-cons
                  (ir.CompilerIrBlock.Block
                    (ir.compiler-ir-label "join")
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                      (ir.compiler-ir-instr-seq-empty)))
                  (ir.compiler-ir-block-cons
                    (ir.CompilerIrBlock.Block
                      (ir.compiler-ir-label "latch")
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Jump
                          (ir.compiler-ir-label "header"))
                        (ir.compiler-ir-instr-seq-empty)))
                    (ir.compiler-ir-block-cons
                      (ir.CompilerIrBlock.Block
                        (ir.compiler-ir-label "exit")
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.Return
                            (ir.CompilerIrMaybeValue.Some
                              (ir.CompilerIrValue.I64 0)))
                          (ir.compiler-ir-instr-seq-empty)))
                      ir.CompilerIrBlockList.Nil)))))))))))

;; What the in-loop discount is FOR: a memory-class value whose references sit
;; on the loop body and whose only crossing sits on a halved arm now satisfies
;; "crossings colder than references" and is relocated, while the SAME numbers
;; in the csr class are refused -- the arm is not `cold`, so the crossing is
;; priced at the halved in-loop weight and a store plus a reload there cannot be
;; bought back by one push/pop pair at the entry weight.
(cfg
  test
  (define (compiler-reg-call-hole-loop-arm-weight-ok?) : bool
    (match (compiler-reg-call-hole-loop-arm-bypass-loop-function)
      [(ir.CompilerIrFunction.Function self-name _ _ _ blocks)
        (let
          [arms : reg.CompilerRegCallHoleWeights
            (reg.compiler-reg-call-hole-cold-arm-weights
              (ast.ast-node-pool-reader-type-segment-bases)
              self-name
              (live.compiler-live-ir-block-list-to-seq blocks))]
          [vars : i64 2]
          [flags : (__tl_dyn-array bool) (__tl_make-array bool vars)]
          [csr : (__tl_dyn-array bool) (__tl_make-array bool vars)]
          [dropped : (__tl_dyn-array bool) (__tl_make-array bool vars)]
          [benefit : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [cost : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [max-ref : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [max-clobber : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [max-clobber-hot : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [scores : reg.CompilerRegCallHoleScores
            (reg.CompilerRegCallHoleScores
              flags
              csr
              dropped
              benefit
              cost
              max-ref
              max-clobber
              max-clobber-hot
              8)]
          (begin
            ;; 0: memory class, refs on the body (32), one crossing on a halved
            ;;    arm (16). 1: the same crossing in the csr class.
            (set! (array-ref flags 0) true)
            (set! (array-ref flags 1) true)
            (set! (array-ref csr 1) true)
            (set! (array-ref benefit 0) 64)
            (set! (array-ref cost 0) 32)
            (set! (array-ref max-ref 0) 32)
            (set! (array-ref max-clobber 0) 16)
            (set! (array-ref benefit 1) 64)
            (set! (array-ref cost 1) 32)
            (set! (array-ref max-ref 1) 32)
            (set! (array-ref max-clobber 1) 16)
            (set! (array-ref max-clobber-hot 1) 16)
            (and
              (= (array-length arms.weights) 8)
              ;; entry / exit: depth 0
              (= (array-ref arms.weights 0) 4)
              (= (array-ref arms.weights 7) 4)
              ;; header / body / join / latch: depth 1, no call
              (= (array-ref arms.weights 1) 32)
              (= (array-ref arms.weights 2) 32)
              (= (array-ref arms.weights 5) 32)
              (= (array-ref arms.weights 6) 32)
              ;; `slow` is the inner loop, so `fast` -- the arm that skips it --
              ;; keeps its full depth-1 weight
              (= (array-ref arms.weights 4) 256)
              (= (array-ref arms.weights 3) 32)
              (not (array-ref arms.cold 3))
              (reg.compiler-reg-call-hole-qualifies? scores 0)
              (not (reg.compiler-reg-call-hole-qualifies? scores 1)))))])))

;; Candidate selection. The three refusals are independent: an ineligible value
;; (no flag), a value the previous round dropped, and a value whose cost is not
;; strictly below its benefit. The fourth -- a crossing at least as hot as the
;; hottest reference -- is the one that keeps the round a downhill relocation.
(cfg
  test
  (define (compiler-reg-call-hole-select-ok?) : bool
    (let
      [vars : i64 6]
      [flags : (__tl_dyn-array bool) (__tl_make-array bool vars)]
      [dropped : (__tl_dyn-array bool) (__tl_make-array bool vars)]
      [benefit : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [cost : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [max-ref : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [max-clobber : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [max-clobber-hot : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [csr : (__tl_dyn-array bool) (__tl_make-array bool vars)]
      [picked : (__tl_dyn-array bool) (__tl_make-array bool vars)]
      [selected : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [scores : reg.CompilerRegCallHoleScores
        (reg.CompilerRegCallHoleScores
          flags
          csr
          dropped
          benefit
          cost
          max-ref
          max-clobber
          max-clobber-hot
          8)]
      [first : i64 0]
      [after-drop : i64 0]
      (begin
        ;; 0: hot refs, cold crossing -> selected.
        ;; 1: benefit equals cost -> refused (the test is strict).
        ;; 2: benefit below cost -> refused.
        ;; 3: profitable, but its crossing is as hot as its hottest ref.
        ;; 4: profitable and cold-crossing, but never eligible.
        ;; 5: profitable and cold-crossing, but crosses nothing at all.
        (set! (array-ref flags 0) true)
        (set! (array-ref flags 1) true)
        (set! (array-ref flags 2) true)
        (set! (array-ref flags 3) true)
        (set! (array-ref flags 5) true)
        (set! (array-ref benefit 0) 80)
        (set! (array-ref cost 0) 2)
        (set! (array-ref max-ref 0) 8)
        (set! (array-ref max-clobber 0) 1)
        (set! (array-ref benefit 1) 16)
        (set! (array-ref cost 1) 16)
        (set! (array-ref max-ref 1) 8)
        (set! (array-ref max-clobber 1) 1)
        (set! (array-ref benefit 2) 4)
        (set! (array-ref cost 2) 16)
        (set! (array-ref max-ref 2) 8)
        (set! (array-ref max-clobber 2) 1)
        (set! (array-ref benefit 3) 80)
        (set! (array-ref cost 3) 16)
        (set! (array-ref max-ref 3) 8)
        (set! (array-ref max-clobber 3) 8)
        (set! (array-ref benefit 4) 80)
        (set! (array-ref cost 4) 2)
        (set! (array-ref max-ref 4) 8)
        (set! (array-ref max-clobber 4) 1)
        (set! (array-ref benefit 5) 80)
        (set! (array-ref cost 5) 0)
        (set! (array-ref max-ref 5) 8)
        (set! (array-ref max-clobber 5) 0)
        (set!
          first
          (reg.compiler-reg-call-hole-select! vars scores picked selected))
        (set! (array-ref dropped 0) true)
        (set!
          after-drop
          (reg.compiler-reg-call-hole-select! vars scores picked selected))
        (and (= first 1) (= (array-ref selected 0) 0) (= after-drop 0))))))

;; The csr class reads the same arrays through a DIFFERENT rule: the crossings
;; that have to be colder than the hottest reference are only the ones in blocks
;; the cold-arm discount did NOT reach (`max-clobber-hot`), and the carriers have
;; to cost strictly less than the push/pop pair a callee-saved home costs
;; (`csr-cost`). Values 0 and 3 carry the SAME numbers in the two classes and
;; land on opposite sides: the csr rule admits 0, because every one of its
;; crossings is on a cold arm and the carriers cost less than the pair, while
;; the memory rule refuses 3, because its benefit does not exceed its cost.
;; Value 1 is the refusal the CSR term exists for -- a value crossing so many
;; cold arms that carrying it is dearer than the pair.
(cfg
  test
  (define (compiler-reg-call-hole-csr-qualify-ok?) : bool
    (let
      [vars : i64 4]
      [flags : (__tl_dyn-array bool) (__tl_make-array bool vars)]
      [csr : (__tl_dyn-array bool) (__tl_make-array bool vars)]
      [dropped : (__tl_dyn-array bool) (__tl_make-array bool vars)]
      [benefit : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [cost : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [max-ref : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [max-clobber : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [max-clobber-hot : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [scores : reg.CompilerRegCallHoleScores
        (reg.CompilerRegCallHoleScores
          flags
          csr
          dropped
          benefit
          cost
          max-ref
          max-clobber
          max-clobber-hot
          8)]
      (begin
        ;; 0: csr, all crossings cold, carriers below the pair -> admitted.
        ;; 1: the same value crossing more cold calls -> refused, strictly.
        ;; 2: csr, but one crossing is in an UNDISCOUNTED block as hot as its
        ;;    hottest reference -> refused.
        ;; 3: the same numbers as 0 but in the MEMORY class, where benefit must
        ;;    exceed cost and the undiscounted maximum is what is compared.
        (set! (array-ref flags 0) true)
        (set! (array-ref flags 1) true)
        (set! (array-ref flags 2) true)
        (set! (array-ref flags 3) true)
        (set! (array-ref csr 0) true)
        (set! (array-ref csr 1) true)
        (set! (array-ref csr 2) true)
        (set! (array-ref benefit 0) 4)
        (set! (array-ref cost 0) 7)
        (set! (array-ref max-ref 0) 4)
        (set! (array-ref max-clobber 0) 1)
        (set! (array-ref benefit 1) 4)
        (set! (array-ref cost 1) 8)
        (set! (array-ref max-ref 1) 4)
        (set! (array-ref max-clobber 1) 1)
        (set! (array-ref benefit 2) 4)
        (set! (array-ref cost 2) 2)
        (set! (array-ref max-ref 2) 4)
        (set! (array-ref max-clobber 2) 4)
        (set! (array-ref max-clobber-hot 2) 4)
        (set! (array-ref benefit 3) 4)
        (set! (array-ref cost 3) 7)
        (set! (array-ref max-ref 3) 4)
        (set! (array-ref max-clobber 3) 1)
        (and
          (reg.compiler-reg-call-hole-qualifies? scores 0)
          (not (reg.compiler-reg-call-hole-qualifies? scores 1))
          (not (reg.compiler-reg-call-hole-qualifies? scores 2))
          (not (reg.compiler-reg-call-hole-qualifies? scores 3)))))))

;; --- E-1 carrier store and reload placement ---------------------------------
;; The single-block fixture: three calls and one spilled value `%0`. The first
;; crossing stores the carrier and the third stores it again because `%0` is
;; redefined in between; the second crossing's store is elided because the
;; carrier already holds the value on this path.
;;
;; The reload after `call f` is DEAD -- nothing reads `%0` before `call g`
;; restores it -- and after E-1 that is decided for BOTH candidate classes, so
;; the run costs two stores and two reloads rather than two stores and three.
;; It used to be a csr-only relaxation gated on the `csr` flags array; the flow
;; answers the same question exactly, and the class no longer enters into it.
(cfg
  test
  (define (compiler-reg-call-hole-rewrite-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "call_hole_rewrite")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      6
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                1
                (ir.compiler-ir-test-symbol "f")
                (ir.CompilerIrCallArgs.Nil)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Call
                  2
                  (ir.compiler-ir-test-symbol "g")
                  (ir.CompilerIrCallArgs.Nil)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.BinOp
                    3
                    (ir.CompilerIrBinOp.Mul)
                    (ir.CompilerIrValue.Var 0)
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Mov
                      0
                      (ir.CompilerIrValue.I64 9)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Call
                        4
                        (ir.compiler-ir-test-symbol "h")
                        (ir.CompilerIrCallArgs.Nil)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.BinOp
                          5
                          (ir.CompilerIrBinOp.Add)
                          (ir.CompilerIrValue.Var 3)
                          (ir.CompilerIrValue.Var 0)
                          (compiler-reg-i64-ty))
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.Return
                            (ir.CompilerIrMaybeValue.Some
                              (ir.CompilerIrValue.Var 5)))
                          (ir.compiler-ir-instr-seq-empty))))))))))
        ir.CompilerIrBlockList.Nil))))

;; Run the rewrite over a whole function with `%0..%(selected-count-1)` carried,
;; building the flow the same way `compiler-reg-call-hole-split-round` does.
(cfg
  test
  (define (compiler-reg-call-hole-test-rewrite
    [func : ir.CompilerIrFunction]
    [selected : (__tl_dyn-array i64)]
    [selected-count : i64]) : ir.CompilerIrBlockSeq
    (match func
      [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
        (let
          [width : i64 (+ vars selected-count)]
          [carrier : (__tl_dyn-array i64) (__tl_make-array i64 width)]
          [valid : (__tl_dyn-array bool) (__tl_make-array bool width)]
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [liveness : live.CompilerFunctionLiveness
            (live.compiler-live-analyze-function-edge-precise func)]
          [index : i64 0]
          (begin
            (reg.compiler-reg-fill-i64-array carrier (- 0 1))
            (while (< index selected-count)
              (begin
                (set!
                  (array-ref carrier (array-ref selected index))
                  (+ vars index))
                (set! index (+ index 1))))
            (live.compiler-live-ir-block-list-to-seq
              (reg.compiler-reg-call-hole-rewrite-blocks
                (ast.ast-node-pool-reader-type-segment-bases)
                seq
                liveness
                (reg.compiler-reg-function-var-types func)
                carrier
                selected
                selected-count
                (reg.compiler-reg-call-hole-flow-build
                  (ast.ast-node-pool-reader-type-segment-bases)
                  seq
                  liveness
                  selected
                  selected-count)
                (reg.compiler-reg-call-hole-flow-full selected-count)
                valid))))])))

(cfg
  test
  (define (compiler-reg-call-hole-test-block
    [seq : ir.CompilerIrBlockSeq]
    [index : i64]) : ir.CompilerIrInstrSeq
    (match (ir.compiler-ir-block-seq-ref seq index)
      [(ir.CompilerIrBlock.Block _ found) found])))

(cfg
  test
  (define (compiler-reg-call-hole-test-selection [var : i64]) : (__tl_dyn-array
      i64)
    (let
      [selected : (__tl_dyn-array i64) (__tl_make-array i64 1)]
      (begin
        (set! (array-ref selected 0) var)
        selected))))

(cfg
  test
  (define (compiler-reg-call-hole-rewrite-shape-ok?) : bool
    (let
      [instrs : ir.CompilerIrInstrSeq
        (compiler-reg-call-hole-test-block
          (compiler-reg-call-hole-test-rewrite
            (compiler-reg-call-hole-rewrite-function)
            (compiler-reg-call-hole-test-selection 0)
            1)
          0)]
      (and
        ;; 8 original + 2 stores + 2 reloads
        (= (ir.compiler-ir-instr-seq-count instrs) 12)
        (compiler-reg-call-hole-mov-const?
          (ir.compiler-ir-instr-seq-ref instrs 0)
          0)
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref instrs 1)
          6
          0)
        (compiler-reg-call-hole-call? (ir.compiler-ir-instr-seq-ref instrs 2))
        ;; the reload after `call f` is DEAD and is not emitted
        (compiler-reg-call-hole-call? (ir.compiler-ir-instr-seq-ref instrs 3))
        ;; `call g` re-uses the carrier the first crossing filled: no store
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref instrs 4)
          0
          6)
        (compiler-reg-call-hole-binop?
          (ir.compiler-ir-instr-seq-ref instrs 5)
          3)
        ;; the redefinition invalidates the carrier ...
        (compiler-reg-call-hole-mov-const?
          (ir.compiler-ir-instr-seq-ref instrs 6)
          0)
        ;; ... so `call h` stores again
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref instrs 7)
          6
          0)
        (compiler-reg-call-hole-call? (ir.compiler-ir-instr-seq-ref instrs 8))
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref instrs 9)
          0
          6)
        (compiler-reg-call-hole-binop?
          (ir.compiler-ir-instr-seq-ref instrs 10)
          5)
        (compiler-reg-call-hole-return?
          (ir.compiler-ir-instr-seq-ref instrs 11))))))

;; --- E-1 across the CFG ------------------------------------------------------
;; `entry` stores the carrier at `call f` and both successors inherit it, so
;; neither `call g` nor `call h` stores again: the store elision is available
;; expressions over the carrier stores and the meet is an intersection, which
;; holds here because EVERY path into `then` and `else` runs entry's store.
;;
;; Two reload facts sit in the same fixture. Nothing reads `%0` before `call g`
;; on the `then` path or before `call h` on the `else` path, so entry's reload
;; is not emitted at all -- the live-through-with-no-use crossing that
;; `SplitEditor::splitLiveThroughBlock` gives neither store nor reload. And
;; inside `then`, `call g` is followed by `call k` with no read between, so its
;; reload is dropped too, while `call k`'s reload survives because the
;; multiplication reads `%0` immediately.
(cfg
  test
  (define (compiler-reg-call-hole-cross-block-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "call_hole_cross_block")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      7
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-seq3
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (ir.CompilerIrInstr.Call
              1
              (ir.compiler-ir-test-symbol "f")
              (ir.CompilerIrCallArgs.Nil)
              (compiler-reg-i64-ty))
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Bool false)
              (ir.compiler-ir-label "then")
              (ir.compiler-ir-label "else"))))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "then")
            (ir.compiler-ir-instr-seq4
              (ir.CompilerIrInstr.Call
                2
                (ir.compiler-ir-test-symbol "g")
                (ir.CompilerIrCallArgs.Nil)
                (compiler-reg-i64-ty))
              (ir.CompilerIrInstr.Call
                6
                (ir.compiler-ir-test-symbol "k")
                (ir.CompilerIrCallArgs.Nil)
                (compiler-reg-i64-ty))
              (ir.CompilerIrInstr.BinOp
                3
                (ir.CompilerIrBinOp.Mul)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "else")
              (ir.compiler-ir-instr-seq3
                (ir.CompilerIrInstr.Call
                  4
                  (ir.compiler-ir-test-symbol "h")
                  (ir.CompilerIrCallArgs.Nil)
                  (compiler-reg-i64-ty))
                (ir.CompilerIrInstr.BinOp
                  5
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 5)))))
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-call-hole-cross-block-ok?) : bool
    (let
      [seq : ir.CompilerIrBlockSeq
        (compiler-reg-call-hole-test-rewrite
          (compiler-reg-call-hole-cross-block-function)
          (compiler-reg-call-hole-test-selection 0)
          1)]
      [entry : ir.CompilerIrInstrSeq (compiler-reg-call-hole-test-block seq 0)]
      [then-block : ir.CompilerIrInstrSeq
        (compiler-reg-call-hole-test-block seq 1)]
      [else-block : ir.CompilerIrInstrSeq
        (compiler-reg-call-hole-test-block seq 2)]
      (and
        ;; entry: def, store, call, branch -- and NO reload
        (= (ir.compiler-ir-instr-seq-count entry) 4)
        (compiler-reg-call-hole-mov-const?
          (ir.compiler-ir-instr-seq-ref entry 0)
          0)
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref entry 1)
          7
          0)
        (compiler-reg-call-hole-call? (ir.compiler-ir-instr-seq-ref entry 2))
        (compiler-reg-call-hole-branch? (ir.compiler-ir-instr-seq-ref entry 3))
        ;; then: call g (no store, no reload), call k (no store), reload, mul
        (= (ir.compiler-ir-instr-seq-count then-block) 5)
        (compiler-reg-call-hole-call?
          (ir.compiler-ir-instr-seq-ref then-block 0))
        (compiler-reg-call-hole-call?
          (ir.compiler-ir-instr-seq-ref then-block 1))
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref then-block 2)
          0
          7)
        (compiler-reg-call-hole-binop?
          (ir.compiler-ir-instr-seq-ref then-block 3)
          3)
        (compiler-reg-call-hole-return?
          (ir.compiler-ir-instr-seq-ref then-block 4))
        ;; else: call h (no store), reload, add
        (= (ir.compiler-ir-instr-seq-count else-block) 4)
        (compiler-reg-call-hole-call?
          (ir.compiler-ir-instr-seq-ref else-block 0))
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref else-block 1)
          0
          7)
        (compiler-reg-call-hole-binop?
          (ir.compiler-ir-instr-seq-ref else-block 2)
          5)
        (compiler-reg-call-hole-return?
          (ir.compiler-ir-instr-seq-ref else-block 3))))))

;; --- E-1, the two negative cases --------------------------------------------
;; `a` reaches `join` having stored the carrier; `b` reaches it having only
;; redefined `%0`. The meet is an intersection, so `join` may NOT claim the
;; carrier holds `%0` and `call g` stores it again.
;;
;; The same fixture pins the fact whose absence is a MISCOMPILE rather than a
;; missed elision: the reload after `call f` in `a` is KEPT, because the store
;; `join` emits READS `%0`'s register. A reload rule that only looked for
;; ordinary uses would elide it and `join` would spill whatever the register
;; happened to hold after the call.
(cfg
  test
  (define (compiler-reg-call-hole-join-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "call_hole_join")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      4
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-seq1
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Bool false)
              (ir.compiler-ir-label "a")
              (ir.compiler-ir-label "b"))))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "a")
            (ir.compiler-ir-instr-seq3
              (ir.CompilerIrInstr.Mov
                0
                (ir.CompilerIrValue.I64 7)
                (compiler-reg-i64-ty))
              (ir.CompilerIrInstr.Call
                1
                (ir.compiler-ir-test-symbol "f")
                (ir.CompilerIrCallArgs.Nil)
                (compiler-reg-i64-ty))
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "b")
              (ir.compiler-ir-instr-seq2
                (ir.CompilerIrInstr.Mov
                  0
                  (ir.CompilerIrValue.I64 8)
                  (compiler-reg-i64-ty))
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "join")
                (ir.compiler-ir-instr-seq3
                  (ir.CompilerIrInstr.Call
                    2
                    (ir.compiler-ir-test-symbol "g")
                    (ir.CompilerIrCallArgs.Nil)
                    (compiler-reg-i64-ty))
                  (ir.CompilerIrInstr.BinOp
                    3
                    (ir.CompilerIrBinOp.Mul)
                    (ir.CompilerIrValue.Var 0)
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-call-hole-join-ok?) : bool
    (let
      [seq : ir.CompilerIrBlockSeq
        (compiler-reg-call-hole-test-rewrite
          (compiler-reg-call-hole-join-function)
          (compiler-reg-call-hole-test-selection 0)
          1)]
      [a-block : ir.CompilerIrInstrSeq
        (compiler-reg-call-hole-test-block seq 1)]
      [b-block : ir.CompilerIrInstrSeq
        (compiler-reg-call-hole-test-block seq 2)]
      [join : ir.CompilerIrInstrSeq (compiler-reg-call-hole-test-block seq 3)]
      (and
        ;; a: def, store, call, RELOAD, jump -- the reload survives because the
        ;; store `join` emits reads the register
        (= (ir.compiler-ir-instr-seq-count a-block) 5)
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref a-block 1)
          4
          0)
        (compiler-reg-call-hole-call? (ir.compiler-ir-instr-seq-ref a-block 2))
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref a-block 3)
          0
          4)
        ;; b: untouched -- it crosses nothing
        (= (ir.compiler-ir-instr-seq-count b-block) 2)
        ;; join: the store is EMITTED, because `b` reaches it without one
        (= (ir.compiler-ir-instr-seq-count join) 5)
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref join 0)
          4
          0)
        (compiler-reg-call-hole-call? (ir.compiler-ir-instr-seq-ref join 1))
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref join 2)
          0
          4)
        (compiler-reg-call-hole-binop? (ir.compiler-ir-instr-seq-ref join 3) 3)
        (compiler-reg-call-hole-return? (ir.compiler-ir-instr-seq-ref join 4))))))

;; A redefinition of the value between two crossings takes the carrier's claim
;; away even though the two crossings sit in different blocks, so the second
;; crossing stores again. The multiplication at the head of `next` is what keeps
;; `%0` live out of `entry` at all, and it is also what keeps entry's reload.
(cfg
  test
  (define (compiler-reg-call-hole-redef-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "call_hole_redef")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      5
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-seq3
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (ir.CompilerIrInstr.Call
              1
              (ir.compiler-ir-test-symbol "f")
              (ir.CompilerIrCallArgs.Nil)
              (compiler-reg-i64-ty))
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "next"))))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "next")
            (ir.compiler-ir-instr-seq5
              (ir.CompilerIrInstr.BinOp
                3
                (ir.CompilerIrBinOp.Mul)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (ir.CompilerIrInstr.Mov
                0
                (ir.CompilerIrValue.I64 9)
                (compiler-reg-i64-ty))
              (ir.CompilerIrInstr.Call
                2
                (ir.compiler-ir-test-symbol "g")
                (ir.CompilerIrCallArgs.Nil)
                (compiler-reg-i64-ty))
              (ir.CompilerIrInstr.BinOp
                4
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 3)
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 4)))))
          ir.CompilerIrBlockList.Nil)))))

(cfg
  test
  (define (compiler-reg-call-hole-redef-ok?) : bool
    (let
      [seq : ir.CompilerIrBlockSeq
        (compiler-reg-call-hole-test-rewrite
          (compiler-reg-call-hole-redef-function)
          (compiler-reg-call-hole-test-selection 0)
          1)]
      [entry : ir.CompilerIrInstrSeq (compiler-reg-call-hole-test-block seq 0)]
      [next : ir.CompilerIrInstrSeq (compiler-reg-call-hole-test-block seq 1)]
      (and
        ;; entry: def, store, call, reload, jump
        (= (ir.compiler-ir-instr-seq-count entry) 5)
        (compiler-reg-call-hole-mov-const?
          (ir.compiler-ir-instr-seq-ref entry 0)
          0)
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref entry 1)
          5
          0)
        (compiler-reg-call-hole-call? (ir.compiler-ir-instr-seq-ref entry 2))
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref entry 3)
          0
          5)
        ;; next: mul, redef, STORE again, call, reload, add, return
        (= (ir.compiler-ir-instr-seq-count next) 7)
        (compiler-reg-call-hole-binop? (ir.compiler-ir-instr-seq-ref next 0) 3)
        (compiler-reg-call-hole-mov-const?
          (ir.compiler-ir-instr-seq-ref next 1)
          0)
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref next 2)
          5
          0)
        (compiler-reg-call-hole-call? (ir.compiler-ir-instr-seq-ref next 3))
        (compiler-reg-cold-call-test-mov?
          (ir.compiler-ir-instr-seq-ref next 4)
          0
          5)
        (compiler-reg-call-hole-binop? (ir.compiler-ir-instr-seq-ref next 5) 4)
        (compiler-reg-call-hole-return? (ir.compiler-ir-instr-seq-ref next 6))))))

;; Absence of information reads as "no carrier is available" and "every value
;; may be read", never the other way round -- the rule
;; `compiler-reg-call-region-stat-exit` states as "an extra dead store is safe;
;; a missing live store is a miscompile". A selection the mask cannot represent
;; and a block index the flow does not have both answer conservatively, and that
;; degenerate answer is exactly the per-block behaviour E-1 generalises.
(cfg
  test
  (define (compiler-reg-call-hole-flow-conservative-ok?) : bool
    (match (compiler-reg-call-hole-cross-block-function)
      [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
        (let
          [func : ir.CompilerIrFunction
            (compiler-reg-call-hole-cross-block-function)]
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [selected : (__tl_dyn-array i64)
            (compiler-reg-call-hole-test-selection 0)]
          [empty : reg.CompilerRegCallHoleFlow
            (reg.compiler-reg-call-hole-flow-build
              (ast.ast-node-pool-reader-type-segment-bases)
              seq
              (live.compiler-live-analyze-function-edge-precise func)
              selected
              0)]
          [built : reg.CompilerRegCallHoleFlow
            (reg.compiler-reg-call-hole-flow-build
              (ast.ast-node-pool-reader-type-segment-bases)
              seq
              (live.compiler-live-analyze-function-edge-precise func)
              selected
              1)]
          (and
            ;; the mask itself, and its refusal above the selection cap
            (= (reg.compiler-reg-call-hole-flow-full 1) 1)
            (= (reg.compiler-reg-call-hole-flow-full 3) 7)
            (= (reg.compiler-reg-call-hole-flow-full 0) 0)
            (=
              (reg.compiler-reg-call-hole-flow-full
                (+ (reg.compiler-reg-call-hole-max-selected) 1))
              0)
            ;; an empty selection is the degenerate flow
            (= (reg.compiler-reg-call-hole-flow-store-in empty 1) 0)
            (= (reg.compiler-reg-call-hole-flow-reload-out empty 1 1) 1)
            ;; out of range asks conservatively too
            (= (reg.compiler-reg-call-hole-flow-store-in built 99) 0)
            (= (reg.compiler-reg-call-hole-flow-reload-out built 99 1) 1)
            ;; and the real answers this fixture is built to have: entry starts
            ;; with nothing available and needs no reload on the way out, while
            ;; both successors inherit the carrier
            (= (reg.compiler-reg-call-hole-flow-store-in built 0) 0)
            (= (reg.compiler-reg-call-hole-flow-reload-out built 0 1) 0)
            (= (reg.compiler-reg-call-hole-flow-store-in built 1) 1)
            (= (reg.compiler-reg-call-hole-flow-store-in built 2) 1)))])))

(cfg
  test
  (define (compiler-reg-call-hole-branch? [instr : ir.CompilerIrInstr]) : bool
    (match instr
      [(ir.CompilerIrInstr.Branch _ _ _) true]
      [_ false])))

(cfg
  test
  (define (compiler-reg-call-hole-mov-const?
    [instr : ir.CompilerIrInstr]
    [dst : i64]) : bool
    (match instr
      [(ir.CompilerIrInstr.Mov found-dst (ir.CompilerIrValue.I64 _) _)
        (= found-dst dst)]
      [_ false])))

(cfg
  test
  (define (compiler-reg-call-hole-call? [instr : ir.CompilerIrInstr]) : bool
    (match instr
      [(ir.CompilerIrInstr.Call _ _ _ _) true]
      [_ false])))

(cfg
  test
  (define (compiler-reg-call-hole-binop?
    [instr : ir.CompilerIrInstr]
    [dst : i64]) : bool
    (match instr
      [(ir.CompilerIrInstr.BinOp found-dst _ _ _ _) (= found-dst dst)]
      [_ false])))

(cfg
  test
  (define (compiler-reg-call-hole-return? [instr : ir.CompilerIrInstr]) : bool
    (match instr
      [(ir.CompilerIrInstr.Return _) true]
      [_ false])))

;; The verify path, one row per class: a MEMORY selection the replan still
;; homes in memory is dropped and one it registerised is kept, while a CSR
;; selection is dropped unless the replan moved it OUT of the callee-saved set
;; -- a csr candidate the replan homes callee-saved again has gained nothing and
;; its carriers would be pure overhead, exactly like a still-spilled one. The
;; next round then rewrites without the dropped ones.
(cfg
  test
  (define (compiler-reg-call-hole-drop-ok?) : bool
    (let
      [plan : reg.CompilerRegPlan
        (reg.CompilerRegPlan.Plan
          (reg.compiler-reg-assignments-prepend
            (reg.CompilerRegAssignment
              0
              (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment
                1
                (reg.CompilerRegLocation.Spill
                  (reg.compiler-reg-stack-slot-offset 1)))
              (reg.compiler-reg-assignments-prepend
                (reg.CompilerRegAssignment
                  2
                  (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r13))
                (reg.compiler-reg-assignments-prepend
                  (reg.CompilerRegAssignment
                    3
                    (reg.CompilerRegLocation.Register cabi.compiler-reg-id-rdi))
                  (reg.compiler-reg-assignment-table-empty)))))
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-empty)
          (reg.compiler-reg-var-types-empty)
          (reg.compiler-reg-call-split-empty)
          (reg.compiler-reg-split-plan-empty))]
      [selected : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      [dropped : (__tl_dyn-array bool) (__tl_make-array bool 4)]
      [csr : (__tl_dyn-array bool) (__tl_make-array bool 4)]
      (begin
        (set! (array-ref selected 0) 0)
        (set! (array-ref selected 1) 1)
        (set! (array-ref selected 2) 2)
        (set! (array-ref selected 3) 3)
        (set! (array-ref csr 2) true)
        (set! (array-ref csr 3) true)
        (and
          (=
            (reg.compiler-reg-call-hole-drop-unimproved!
              cabi.CompilerRegTargetAbi.Linux
              plan
              csr
              selected
              4
              dropped)
            2)
          (not (array-ref dropped 0))
          (array-ref dropped 1)
          (array-ref dropped 2)
          (not (array-ref dropped 3)))))))

;; End to end. Ten values are computed in the entry block, held live across ONE
;; call there, and used inside the loop as a multiply's LHS -- a position the
;; backend cannot serve from a stack slot. Ten call-spanning values against six
;; callee-saved registers is what makes the initial plan spill, and the loop
;; refs against the entry crossing are what make the relocation downhill.
(cfg
  test
  (define (compiler-reg-call-hole-round-values) : i64
    10))

(cfg
  test
  (define (compiler-reg-call-hole-round-vars) : i64
    ;; param, `count` values, call result/accumulator, counter, condition,
    ;; and one product temp per value.
    (+ (* 2 (compiler-reg-call-hole-round-values)) 4)))

(cfg
  test
  (define (compiler-reg-call-hole-round-entry) : ir.CompilerIrInstrSeq
    (let
      [count : i64 (compiler-reg-call-hole-round-values)]
      [builder : ir.CompilerIrInstrBuilder
        (ir.compiler-ir-instr-builder-with-capacity (+ count 3))]
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            (ir.compiler-ir-instr-builder-push!
              (&mut builder)
              (ir.CompilerIrInstr.BinOp
                (+ index 1)
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.I64 (+ index 1))
                (compiler-reg-i64-ty)))
            (set! index (+ index 1))))
        (ir.compiler-ir-instr-builder-push!
          (&mut builder)
          (ir.CompilerIrInstr.Call
            (+ count 1)
            (ir.compiler-ir-test-symbol "call_hole_sink")
            (ir.CompilerIrCallArgs.Nil)
            (compiler-reg-i64-ty)))
        (ir.compiler-ir-instr-builder-push!
          (&mut builder)
          (ir.CompilerIrInstr.Mov
            (+ count 2)
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty)))
        (ir.compiler-ir-instr-builder-push!
          (&mut builder)
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop")))
        (ir.compiler-ir-instr-builder-to-seq builder)))))

(cfg
  test
  (define (compiler-reg-call-hole-round-body) : ir.CompilerIrInstrSeq
    (let
      [count : i64 (compiler-reg-call-hole-round-values)]
      [acc : i64 (+ count 1)]
      [counter : i64 (+ count 2)]
      [builder : ir.CompilerIrInstrBuilder
        (ir.compiler-ir-instr-builder-with-capacity (+ (* 2 count) 2))]
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            ;; The value is the multiply's LHS: a spilled operand there is a
            ;; real reload, unlike an `add`'s RHS.
            (ir.compiler-ir-instr-builder-push!
              (&mut builder)
              (ir.CompilerIrInstr.BinOp
                (+ (+ count 4) index)
                (ir.CompilerIrBinOp.Mul)
                (ir.CompilerIrValue.Var (+ index 1))
                (ir.CompilerIrValue.Var counter)
                (compiler-reg-i64-ty)))
            (ir.compiler-ir-instr-builder-push!
              (&mut builder)
              (ir.CompilerIrInstr.BinOp
                acc
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var acc)
                (ir.CompilerIrValue.Var (+ (+ count 4) index))
                (compiler-reg-i64-ty)))
            (set! index (+ index 1))))
        (ir.compiler-ir-instr-builder-push!
          (&mut builder)
          (ir.CompilerIrInstr.BinOp
            counter
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.Var counter)
            (ir.CompilerIrValue.I64 1)
            (compiler-reg-i64-ty)))
        (ir.compiler-ir-instr-builder-push!
          (&mut builder)
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop")))
        (ir.compiler-ir-instr-builder-to-seq builder)))))

(cfg
  test
  (define (compiler-reg-call-hole-round-function) : ir.CompilerIrFunction
    (let
      [count : i64 (compiler-reg-call-hole-round-values)]
      [acc : i64 (+ count 1)]
      [counter : i64 (+ count 2)]
      [cond-var : i64 (+ count 3)]
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "call_hole_round")
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "bound" (compiler-reg-i64-ty) 0)
          ir.CompilerIrParamList.Nil)
        (ast.AstType.I64)
        (compiler-reg-call-hole-round-vars)
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "entry")
            (compiler-reg-call-hole-round-entry))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "loop")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  cond-var
                  (ir.CompilerIrBinOp.Lt)
                  (ir.CompilerIrValue.Var counter)
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Branch
                    (ir.CompilerIrValue.Var cond-var)
                    (ir.compiler-ir-label "body")
                    (ir.compiler-ir-label "exit"))
                  (ir.compiler-ir-instr-seq-empty))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "body")
                (compiler-reg-call-hole-round-body))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "exit")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some
                        (ir.CompilerIrValue.Var acc)))
                    (ir.compiler-ir-instr-seq-empty)))
                ir.CompilerIrBlockList.Nil))))))))

(cfg
  test
  (define (compiler-reg-call-hole-spilled-value-count
    [plan : reg.CompilerRegPlan]
    [count : i64]) : i64
    (let
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-plan-assignments plan)]
      [index : i64 0]
      [total : i64 0]
      (begin
        (while (< index count)
          (begin
            (if (reg.compiler-reg-call-hole-register-homed?
              assignments
              (+ index 1))
              unit
              (set! total (+ total 1)))
            (set! index (+ index 1))))
        total))))

(cfg
  test
  (define (compiler-reg-call-hole-round-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-call-hole-round-function)]
      [count : i64 (compiler-reg-call-hole-round-values)]
      [vars : i64 (compiler-reg-call-hole-round-vars)]
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [plan : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-cold-for-abi
          cabi.CompilerRegTargetAbi.Linux
          func
          (- 0 1))]
      [split : reg.CompilerRegCallHoleSplit
        (reg.compiler-reg-call-hole-split-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          cabi.CompilerRegTargetAbi.Linux
          func
          type-info
          plan
          (- 0 1))]
      [split-vars : i64 (reg.compiler-reg-call-hole-split-vars split)]
      [split-plan : reg.CompilerRegPlan
        (reg.compiler-reg-call-hole-split-plan split)]
      (and
        ;; the initial plan really did spill call-spanning values ...
        (> (compiler-reg-call-hole-spilled-value-count plan count) 0)
        ;; ... the round fired, minting one carrier per selection ...
        (> split-vars vars)
        (<= split-vars (+ vars count))
        ;; ... the carriers start at the old watermark and are the threshold ...
        (= (reg.compiler-reg-call-hole-split-temp-start split) vars)
        ;; ... every carrier is stack-homed, never a register ...
        (reg.compiler-reg-cold-call-carriers-stack? split-plan vars split-vars)
        ;; ... and no selected value is left in memory (the verify path drops
        ;; any that were, so a surviving rewrite has none).
        (= (compiler-reg-call-hole-spilled-value-count split-plan count) 0)))))

;; A function whose only loop contains no call at all presents no crossing, so
;; the round returns its input untouched -- same watermark, same threshold, and
;; the plan it was handed.
(cfg
  test
  (define (compiler-reg-call-hole-declines-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-leaf-csr-split-function)]
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [plan : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-cold-for-abi
          cabi.CompilerRegTargetAbi.Linux
          func
          (- 0 1))]
      [split : reg.CompilerRegCallHoleSplit
        (reg.compiler-reg-call-hole-split-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          cabi.CompilerRegTargetAbi.Linux
          func
          type-info
          plan
          (- 0 1))]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars _)
          (and
            (= (reg.compiler-reg-call-hole-split-vars split) vars)
            (= (reg.compiler-reg-call-hole-split-temp-start split) (- 0 1)))]))))

;; --- P7 the csr class, end to end -------------------------------------------
;; The merged-kernel shape the inliner produces: a hot straight path that uses
;; all three parameters and no call, plus a cold side arm that calls twice. The
;; parameters are live through those calls, so the ABI-pin gate refuses their
;; incoming registers and the greedy's `is-param -> csr-only` rule gives each of
;; them a callee-saved home -- three pushes and three pops on EVERY call of the
;; function, for an arm that runs almost never. Nothing in the memory-reference
;; cost model can see that, because a callee-saved home costs no reference.
;;
;; After the round the crossings are carried in the cold arm, the pin walk hands
;; each parameter its incoming register back, and the plan uses no callee-saved
;; register at all.
(cfg
  test
  (define (compiler-reg-call-hole-csr-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "call_hole_csr")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "b" (compiler-reg-i64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "c" (compiler-reg-i64-ty) 2)
            ir.CompilerIrParamList.Nil)))
      (ast.AstType.I64)
      8
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              3
              (ir.CompilerIrBinOp.Lt)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 1)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 3)
                (ir.compiler-ir-label "grow")
                (ir.compiler-ir-label "hot"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "grow")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                4
                (ir.compiler-ir-test-symbol "f")
                (ir.CompilerIrCallArgs.Nil)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Call
                  5
                  (ir.compiler-ir-test-symbol "g")
                  (ir.CompilerIrCallArgs.Nil)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "hot"))
                  (ir.compiler-ir-instr-seq-empty)))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "hot")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  6
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.Var 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.BinOp
                    7
                    (ir.CompilerIrBinOp.Add)
                    (ir.CompilerIrValue.Var 6)
                    (ir.CompilerIrValue.Var 2)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 7)))
                    (ir.compiler-ir-instr-seq-empty)))))
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-call-hole-plan-register?
    [plan : reg.CompilerRegPlan]
    [var : i64]
    [want : i64]) : bool
    (reg.compiler-reg-location-register?
      (reg.compiler-reg-assignment-lookup
        (reg.compiler-reg-plan-assignments plan)
        var)
      want)))

(cfg
  test
  (define (compiler-reg-call-hole-csr-split-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-call-hole-csr-function)]
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [plan : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-cold-for-abi
          cabi.CompilerRegTargetAbi.Linux
          func
          (- 0 1))]
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-plan-assignments plan)]
      [split : reg.CompilerRegCallHoleSplit
        (reg.compiler-reg-call-hole-split-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          cabi.CompilerRegTargetAbi.Linux
          func
          type-info
          plan
          (- 0 1))]
      [split-vars : i64 (reg.compiler-reg-call-hole-split-vars split)]
      [split-plan : reg.CompilerRegPlan
        (reg.compiler-reg-call-hole-split-plan split)]
      (and
        ;; The defect: no spill anywhere, but all three parameters homed in
        ;; callee-saved registers because they cross the cold arm's calls.
        (not (reg.compiler-reg-assignment-table-has-spill? assignments))
        (reg.compiler-reg-call-hole-csr-home?
          cabi.CompilerRegTargetAbi.Linux
          assignments
          0)
        (reg.compiler-reg-call-hole-csr-home?
          cabi.CompilerRegTargetAbi.Linux
          assignments
          1)
        (reg.compiler-reg-call-hole-csr-home?
          cabi.CompilerRegTargetAbi.Linux
          assignments
          2)
        (=
          (reg.compiler-reg-call-hole-plan-csr-count
            cabi.CompilerRegTargetAbi.Linux
            8
            plan)
          3)
        ;; One carrier per parameter, minted at the old watermark.
        (= split-vars 11)
        (= (reg.compiler-reg-call-hole-split-temp-start split) 8)
        (reg.compiler-reg-cold-call-carriers-stack? split-plan 8 split-vars)
        ;; Every parameter is back in its incoming ABI register ...
        (compiler-reg-call-hole-plan-register?
          split-plan
          0
          cabi.compiler-reg-id-rdi)
        (compiler-reg-call-hole-plan-register?
          split-plan
          1
          cabi.compiler-reg-id-rsi)
        (compiler-reg-call-hole-plan-register?
          split-plan
          2
          cabi.compiler-reg-id-rdx)
        ;; ... so the prologue saves nothing at all.
        (=
          (reg.compiler-reg-call-hole-plan-csr-count
            cabi.CompilerRegTargetAbi.Linux
            split-vars
            split-plan)
          0)))))

;; The CSR term is what makes the comparison strict, and it cuts both ways. One
;; parameter is live across `arms` cold side arms, each with one call. A carrier
;; is stored once per arm (the elision claim is per block and every arm is its
;; own block) and reloaded once, so the trade is 2 per arm at the discounted
;; cold-arm weight of 1, against the 2 instructions a push and a pop cost at the
;; entry weight of 4. Three arms (6) buy the pair back; four (8) do not, and the
;; round declines outright and returns its input untouched.
(cfg
  test
  (define (compiler-reg-call-hole-arm-label [prefix : String] [index : i64]) : String
    (str_cat.str-cat prefix (string.int->string index))))

(cfg
  test
  (define (compiler-reg-call-hole-guard-label [index : i64]) : String
    (if (= index 0)
      "entry"
      (compiler-reg-call-hole-arm-label "guard" index))))

(cfg
  test
  (define (compiler-reg-call-hole-join-label [index : i64] [arms : i64]) : String
    (if (>= index arms)
      "hot"
      (compiler-reg-call-hole-guard-label index))))

;; guard_k / cold_k for k in [index, arms), then the hot tail.
(cfg
  test
  (define (compiler-reg-call-hole-cold-arms-name) : i64
    (ir.compiler-ir-test-symbol "call_hole_cold_arms")))

(cfg
  test
  (define (compiler-reg-call-hole-cold-arms-chain
    [index : i64]
    [arms : i64]
    [callee : i64]) : ir.CompilerIrBlockList
    (if (>= index arms)
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "hot")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              (+ arms 1)
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 1)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some
                  (ir.CompilerIrValue.Var (+ arms 1))))
              (ir.compiler-ir-instr-seq-empty))))
        ir.CompilerIrBlockList.Nil)
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label (compiler-reg-call-hole-guard-label index))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Bool false)
              (ir.compiler-ir-label
                (compiler-reg-call-hole-arm-label "cold" index))
              (ir.compiler-ir-label
                (compiler-reg-call-hole-join-label (+ index 1) arms)))
            (ir.compiler-ir-instr-seq-empty)))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label
              (compiler-reg-call-hole-arm-label "cold" index))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                (+ index 1)
                callee
                (ir.CompilerIrCallArgs.Nil)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump
                  (ir.compiler-ir-label
                    (compiler-reg-call-hole-join-label (+ index 1) arms)))
                (ir.compiler-ir-instr-seq-empty))))
          (compiler-reg-call-hole-cold-arms-chain (+ index 1) arms callee))))))

(cfg
  test
  (define (compiler-reg-call-hole-cold-arms-function
    [arms : i64]
    [callee : i64]) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (compiler-reg-call-hole-cold-arms-name)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.I64)
      (+ arms 2)
      (compiler-reg-call-hole-cold-arms-chain 0 arms callee))))

(cfg
  test
  (define (compiler-reg-call-hole-cold-arms-split [arms : i64] [callee : i64]) : reg.CompilerRegCallHoleSplit
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-call-hole-cold-arms-function arms callee)]
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [plan : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-cold-for-abi
          cabi.CompilerRegTargetAbi.Linux
          func
          (- 0 1))]
      (reg.compiler-reg-call-hole-split-rewrite-function
        (ast.ast-node-pool-reader-type-segment-bases)
        cabi.CompilerRegTargetAbi.Linux
        func
        type-info
        plan
        (- 0 1)))))

(cfg
  test
  (define (compiler-reg-call-hole-csr-cost-strict-ok?) : bool
    (let
      [three : reg.CompilerRegCallHoleSplit
        (compiler-reg-call-hole-cold-arms-split
          3
          (ir.compiler-ir-test-symbol "f"))]
      [four : reg.CompilerRegCallHoleSplit
        (compiler-reg-call-hole-cold-arms-split
          4
          (ir.compiler-ir-test-symbol "f"))]
      (and
        ;; 3 arms: one carrier minted above the 5 original vars, and the
        ;; parameter is pinned back into %rdi.
        (= (reg.compiler-reg-call-hole-split-vars three) 6)
        (= (reg.compiler-reg-call-hole-split-temp-start three) 5)
        (compiler-reg-call-hole-plan-register?
          (reg.compiler-reg-call-hole-split-plan three)
          0
          cabi.compiler-reg-id-rdi)
        (=
          (reg.compiler-reg-call-hole-plan-csr-count
            cabi.CompilerRegTargetAbi.Linux
            6
            (reg.compiler-reg-call-hole-split-plan three))
          0)
        ;; 4 arms: the carriers now cost exactly what the pair costs, and the
        ;; rule is strictly-below, so nothing is selected and the round returns
        ;; its input untouched.
        (= (reg.compiler-reg-call-hole-split-vars four) 6)
        (= (reg.compiler-reg-call-hole-split-temp-start four) (- 0 1))))))

;; --- P7b the recursion exclusion --------------------------------------------
;; PRED_CALL's recursion exclusion on the same fixture the discount is measured
;; with: the two functions below differ in ONE symbol, the callee inside the
;; arm, so everything the classification and the cost model see is otherwise
;; identical and the arm's SHAPE cannot be what separates them.
;;
;; With a foreign callee the arm is a depth-0 side arm that calls: discounted to
;; a quarter, and one arm's carriers (2 x 1) buy back the parameter's push and
;; pop (2 x 4), so the round fires and the pin walk hands %rdi back. With the
;; self-call the arm keeps its full depth-0 weight, because for a self-recursive
;; function the arm runs on every activation but the last; the carriers now cost
;; 2 x 4 against the pair's 2 x 4, the comparison is strictly-below, and the
;; round declines and returns its input untouched. That is `deeprec`'s arithmetic
;; in tests/integration/csr_push_prologue.tl with one value instead of four
;; (4 x 2 x 4 against four pairs = 32 against 32), and it is why its push
;; prologue and shrink-wrapped base case survive.
(cfg
  test
  (define (compiler-reg-call-hole-recursive-arm-weights [callee : i64]) : reg.CompilerRegCallHoleWeights
    (match (compiler-reg-call-hole-cold-arms-function 1 callee)
      [(ir.CompilerIrFunction.Function self-name _ _ _ blocks)
        (reg.compiler-reg-call-hole-cold-arm-weights
          (ast.ast-node-pool-reader-type-segment-bases)
          self-name
          (live.compiler-live-ir-block-list-to-seq blocks))])))

(cfg
  test
  (define (compiler-reg-call-hole-recursive-arm-ok?) : bool
    (let
      [self : i64 (compiler-reg-call-hole-cold-arms-name)]
      [foreign-name : i64 (ir.compiler-ir-test-symbol "f")]
      [foreign : reg.CompilerRegCallHoleWeights
        (compiler-reg-call-hole-recursive-arm-weights foreign-name)]
      [recursive : reg.CompilerRegCallHoleWeights
        (compiler-reg-call-hole-recursive-arm-weights self)]
      [foreign-split : reg.CompilerRegCallHoleSplit
        (compiler-reg-call-hole-cold-arms-split 1 foreign-name)]
      [recursive-split : reg.CompilerRegCallHoleSplit
        (compiler-reg-call-hole-cold-arms-split 1 self)]
      (and
        ;; entry / hot call nothing and are never discounted, either way.
        (= (array-length foreign.weights) 3)
        (= (array-ref foreign.weights 0) 4)
        (not (array-ref foreign.cold 0))
        (= (array-ref foreign.weights 2) 4)
        (not (array-ref foreign.cold 2))
        ;; the foreign arm IS a cold arm ...
        (= (array-ref foreign.weights 1) 1)
        (array-ref foreign.cold 1)
        ;; ... and the self-recursive one, same block, same shape, is not.
        (= (array-length recursive.weights) 3)
        (= (array-ref recursive.weights 0) 4)
        (= (array-ref recursive.weights 1) 4)
        (not (array-ref recursive.cold 1))
        (= (array-ref recursive.weights 2) 4)
        ;; The round follows the weights. Foreign: one carrier minted above the
        ;; three original vars, and the parameter is back in %rdi.
        (= (reg.compiler-reg-call-hole-split-vars foreign-split) 4)
        (= (reg.compiler-reg-call-hole-split-temp-start foreign-split) 3)
        (compiler-reg-call-hole-plan-register?
          (reg.compiler-reg-call-hole-split-plan foreign-split)
          0
          cabi.compiler-reg-id-rdi)
        ;; Recursive: nothing selected, input returned untouched.
        (= (reg.compiler-reg-call-hole-split-vars recursive-split) 3)
        (=
          (reg.compiler-reg-call-hole-split-temp-start recursive-split)
          (- 0 1))))))

;; --- P3c loop-boundary parking ----------------------------------------------
;; Two fixtures carry the whole round.
;;
;; `loop_park_direct` is the plain shape: a dedicated preheader, a natural loop
;; whose single exit target has no other predecessor, one value live ACROSS the
;; loop and used after it (%1, the through value), one value referenced INSIDE
;; it (%2, a resident) and one referenced in it only as a header-phi INPUT (%8,
;; defined in the preheader) -- the case the edge-precise `-nophi!` use list
;; would miss and admit as a through value.
;;
;; `loop_park_splice` adds the placements that need a spliced block: the exit
;; target has a predecessor from outside the loop and opens with a phi whose
;; loop-side input is a value the reload has to restore first, and a second exit
;; leaves the loop for a `Return` block, where nothing the round parks is live.
(cfg
  test
  (define (compiler-reg-loop-park-direct-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_park_direct")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "bound" (compiler-reg-i64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.I64)
      9
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 100)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.I64 200)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "preheader"))
                (ir.compiler-ir-instr-seq-empty)))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "preheader")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                8
                (ir.CompilerIrValue.I64 7)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "header")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Phi
                  3
                  (ir.compiler-ir-phi-input-cons
                    (ir.CompilerIrValue.Var 8)
                    (ir.compiler-ir-label "preheader")
                    (ir.compiler-ir-phi-input-cons
                      (ir.CompilerIrValue.Var 6)
                      (ir.compiler-ir-label "latch")
                      ir.CompilerIrPhiInputList.Nil))
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.BinOp
                    5
                    (ir.CompilerIrBinOp.Lt)
                    (ir.CompilerIrValue.Var 3)
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Branch
                      (ir.CompilerIrValue.Var 5)
                      (ir.compiler-ir-label "body")
                      (ir.compiler-ir-label "exit"))
                    (ir.compiler-ir-instr-seq-empty)))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "body")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.BinOp
                    4
                    (ir.CompilerIrBinOp.Add)
                    (ir.CompilerIrValue.Var 3)
                    (ir.CompilerIrValue.Var 2)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                    (ir.compiler-ir-instr-seq-empty))))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "latch")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.BinOp
                      6
                      (ir.CompilerIrBinOp.Add)
                      (ir.CompilerIrValue.Var 3)
                      (ir.CompilerIrValue.I64 1)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                      (ir.compiler-ir-instr-seq-empty))))
                (ir.compiler-ir-block-cons
                  (ir.CompilerIrBlock.Block
                    (ir.compiler-ir-label "exit")
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.BinOp
                        7
                        (ir.CompilerIrBinOp.Add)
                        (ir.CompilerIrValue.Var 1)
                        (ir.CompilerIrValue.Var 3)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Return
                          (ir.CompilerIrMaybeValue.Some
                            (ir.CompilerIrValue.Var 7)))
                        (ir.compiler-ir-instr-seq-empty))))
                  ir.CompilerIrBlockList.Nil)))))))))

(cfg
  test
  (define (compiler-reg-loop-park-splice-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_park_splice")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "bound" (compiler-reg-i64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.I64)
      11
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 100)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.I64 200)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  10
                  (ir.CompilerIrBinOp.Lt)
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.I64 5)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Branch
                    (ir.CompilerIrValue.Var 10)
                    (ir.compiler-ir-label "preheader")
                    (ir.compiler-ir-label "other"))
                  (ir.compiler-ir-instr-seq-empty))))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "other")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                8
                (ir.CompilerIrValue.I64 9)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "exit"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "preheader")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "header")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Phi
                    3
                    (ir.compiler-ir-phi-input-cons
                      (ir.CompilerIrValue.I64 0)
                      (ir.compiler-ir-label "preheader")
                      (ir.compiler-ir-phi-input-cons
                        (ir.CompilerIrValue.Var 6)
                        (ir.compiler-ir-label "latch")
                        ir.CompilerIrPhiInputList.Nil))
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.BinOp
                      5
                      (ir.CompilerIrBinOp.Lt)
                      (ir.CompilerIrValue.Var 3)
                      (ir.CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Branch
                        (ir.CompilerIrValue.Var 5)
                        (ir.compiler-ir-label "body")
                        (ir.compiler-ir-label "exit"))
                      (ir.compiler-ir-instr-seq-empty)))))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "body")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.BinOp
                      4
                      (ir.CompilerIrBinOp.Add)
                      (ir.CompilerIrValue.Var 3)
                      (ir.CompilerIrValue.Var 2)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                      (ir.compiler-ir-instr-seq-empty))))
                (ir.compiler-ir-block-cons
                  (ir.CompilerIrBlock.Block
                    (ir.compiler-ir-label "latch")
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.BinOp
                        6
                        (ir.CompilerIrBinOp.Add)
                        (ir.CompilerIrValue.Var 3)
                        (ir.CompilerIrValue.I64 1)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Branch
                          (ir.CompilerIrValue.Var 5)
                          (ir.compiler-ir-label "header")
                          (ir.compiler-ir-label "ret_blk"))
                        (ir.compiler-ir-instr-seq-empty))))
                  (ir.compiler-ir-block-cons
                    (ir.CompilerIrBlock.Block
                      (ir.compiler-ir-label "ret_blk")
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Return
                          (ir.CompilerIrMaybeValue.Some
                            (ir.CompilerIrValue.Var 4)))
                        (ir.compiler-ir-instr-seq-empty)))
                    (ir.compiler-ir-block-cons
                      (ir.CompilerIrBlock.Block
                        (ir.compiler-ir-label "exit")
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.Phi
                            7
                            (ir.compiler-ir-phi-input-cons
                              (ir.CompilerIrValue.Var 3)
                              (ir.compiler-ir-label "header")
                              (ir.compiler-ir-phi-input-cons
                                (ir.CompilerIrValue.Var 8)
                                (ir.compiler-ir-label "other")
                                ir.CompilerIrPhiInputList.Nil))
                            (compiler-reg-i64-ty))
                          (compiler-reg-test-instr-seq-prepend
                            (ir.CompilerIrInstr.BinOp
                              9
                              (ir.CompilerIrBinOp.Add)
                              (ir.CompilerIrValue.Var 1)
                              (ir.CompilerIrValue.Var 7)
                              (compiler-reg-i64-ty))
                            (compiler-reg-test-instr-seq-prepend
                              (ir.CompilerIrInstr.Return
                                (ir.CompilerIrMaybeValue.Some
                                  (ir.CompilerIrValue.Var 9)))
                              (ir.compiler-ir-instr-seq-empty)))))
                      ir.CompilerIrBlockList.Nil)))))))))))

(cfg
  test
  (define (compiler-reg-loop-park-block-index
    [seq : ir.CompilerIrBlockSeq]
    [name : String]) : i64
    (let
      [want : i64 (ir.compiler-ir-label name)]
      [count : i64 (ir.compiler-ir-block-seq-count seq)]
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            (when
              (= (reg.compiler-reg-loop-park-block-label seq index) want)
              (return index))
            (set! index (+ index 1))))
        (- 0 1)))))

;; Loop structure and residency. The through value is the one the loop never
;; mentions; a value used in the loop, a value that is only a header-phi INPUT
;; there, and the loop's own phi result are all residents.
(cfg
  test
  (define (compiler-reg-loop-park-detect-ok?) : bool
    (match (compiler-reg-loop-park-direct-function)
      [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [count : i64 (ir.compiler-ir-block-seq-count seq)]
          [nest : reg.CompilerRegLoopNest
            (reg.compiler-reg-loop-nest-build-seq seq)]
          [header : i64 (compiler-reg-loop-park-block-index seq "header")]
          [entry : i64 (compiler-reg-loop-park-block-index seq "entry")]
          [pre : i64 (compiler-reg-loop-park-block-index seq "preheader")]
          [total : i64
            (reg.compiler-reg-loop-nest-header-members! nest header 1)]
          [depths : (__tl_dyn-array i64) (__tl_make-array i64 count)]
          [weights : (__tl_dyn-array i64) (__tl_make-array i64 count)]
          [stamp : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [refs : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [residents : (__tl_dyn-array i64) (__tl_make-array i64 32)]
          [cursor : (__tl_dyn-array i64) (__tl_make-array i64 2)]
          [index : i64 0]
          (begin
            (while (< index count)
              (begin
                (set! (array-ref weights index) 1)
                (set! index (+ index 1))))
            (reg.compiler-reg-loop-park-mark-residents!
              seq
              nest
              header
              total
              1
              weights
              vars
              stamp
              refs
              residents
              cursor)
            (and
              ;; the loop is {header, body, latch}, entered only at the header
              (= total 2)
              (= (reg.compiler-reg-loop-nest-outside-pred nest header 1) pre)
              (reg.compiler-reg-loop-park-dedicated-preheader?
                seq
                pre
                (reg.compiler-reg-loop-park-block-label seq header))
              ;; the entry block jumps to the preheader, not to the header
              (not
                (reg.compiler-reg-loop-park-dedicated-preheader?
                  seq
                  entry
                  (reg.compiler-reg-loop-park-block-label seq header)))
              (reg.compiler-reg-loop-park-single-entry? nest header total 1)
              ;; residents: used in the loop (%2), phi result (%3), phi INPUT
              ;; whose def is outside the loop (%8), and the bound (%0)
              (= (array-ref stamp 2) 1)
              (= (array-ref stamp 3) 1)
              (= (array-ref stamp 8) 1)
              (= (array-ref stamp 0) 1)
              ;; through: live across the loop, never mentioned in it
              (not (= (array-ref stamp 1) 1))
              ;; and defined after it, so not live into it either
              (not (= (array-ref stamp 7) 1))
              (> (array-ref cursor 1) 0))))])))

;; Through-value eligibility: a REGISTER home admits, a spill home declines (it
;; has no register to give up), a missing home declines, and the planner's
;; ineligible set declines even a register-homed value.
(cfg
  test
  (define (compiler-reg-loop-park-eligible-ok?) : bool
    (let
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignments-prepend
          (reg.CompilerRegAssignment
            0
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))
          (reg.compiler-reg-assignments-prepend
            (reg.CompilerRegAssignment
              1
              (reg.CompilerRegLocation.Spill
                (reg.compiler-reg-stack-slot-offset 1)))
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment
                3
                (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r13))
              (reg.compiler-reg-assignment-table-empty))))]
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types
          (compiler-reg-loop-park-direct-function))]
      [ineligible : live.CompilerLiveI64Set
        (live.compiler-live-set-insert (live.compiler-live-set-empty) 3)]
      [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
      (and
        (reg.compiler-reg-loop-park-through-eligible?
          bases
          type-info
          assignments
          (live.compiler-live-set-empty)
          0)
        (not
          (reg.compiler-reg-loop-park-through-eligible?
            bases
            type-info
            assignments
            (live.compiler-live-set-empty)
            1))
        (not
          (reg.compiler-reg-loop-park-through-eligible?
            bases
            type-info
            assignments
            (live.compiler-live-set-empty)
            2))
        (not
          (reg.compiler-reg-loop-park-through-eligible?
            bases
            type-info
            assignments
            ineligible
            3))))))

;; Reload SITES. The plain fixture's single exit target has no predecessor
;; outside the loop and no phi, so the reload goes at its head; the splice
;; fixture's does, so its edge is spliced, and its second exit -- a `Return`
;; block -- is a site at which nothing the round parks is live.
(cfg
  test
  (define (compiler-reg-loop-park-sites-ok?) : bool
    (let
      [direct-func : ir.CompilerIrFunction
        (compiler-reg-loop-park-direct-function)]
      [splice-func : ir.CompilerIrFunction
        (compiler-reg-loop-park-splice-function)]
      [direct-seq : ir.CompilerIrBlockSeq
        (live.compiler-live-ir-block-list-to-seq
          (match direct-func
            [(ir.CompilerIrFunction.Function _ _ _ _ blocks) blocks]))]
      [splice-seq : ir.CompilerIrBlockSeq
        (live.compiler-live-ir-block-list-to-seq
          (match splice-func
            [(ir.CompilerIrFunction.Function _ _ _ _ blocks) blocks]))]
      [direct-nest : reg.CompilerRegLoopNest
        (reg.compiler-reg-loop-nest-build-seq direct-seq)]
      [splice-nest : reg.CompilerRegLoopNest
        (reg.compiler-reg-loop-nest-build-seq splice-seq)]
      [direct-live : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function-edge-precise direct-func)]
      [splice-live : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function-edge-precise splice-func)]
      [weights : (__tl_dyn-array i64) (__tl_make-array i64 16)]
      [from : (__tl_dyn-array i64) (__tl_make-array i64 8)]
      [to : (__tl_dyn-array i64) (__tl_make-array i64 8)]
      [kind : (__tl_dyn-array i64) (__tl_make-array i64 8)]
      [weight : (__tl_dyn-array i64) (__tl_make-array i64 8)]
      [scratch : (__tl_dyn-array i64) (__tl_make-array i64 2)]
      [dh : i64 (compiler-reg-loop-park-block-index direct-seq "header")]
      [de : i64 (compiler-reg-loop-park-block-index direct-seq "exit")]
      [sh : i64 (compiler-reg-loop-park-block-index splice-seq "header")]
      [sl : i64 (compiler-reg-loop-park-block-index splice-seq "latch")]
      [se : i64 (compiler-reg-loop-park-block-index splice-seq "exit")]
      [sr : i64 (compiler-reg-loop-park-block-index splice-seq "ret_blk")]
      [direct-total : i64
        (reg.compiler-reg-loop-nest-header-members! direct-nest dh 1)]
      [direct-count : i64
        (reg.compiler-reg-loop-park-collect-sites!
          direct-seq
          direct-nest
          direct-live
          dh
          direct-total
          1
          weights
          from
          to
          kind
          weight
          scratch)]
      [direct-kind : i64 (array-ref kind 0)]
      [direct-to : i64 (array-ref to 0)]
      [splice-total : i64
        (reg.compiler-reg-loop-nest-header-members! splice-nest sh 1)]
      [splice-count : i64
        (reg.compiler-reg-loop-park-collect-sites!
          splice-seq
          splice-nest
          splice-live
          sh
          splice-total
          1
          weights
          from
          to
          kind
          weight
          scratch)]
      (and
        ;; one exit, served at the head of its target
        (= direct-count 1)
        (= direct-kind (reg.compiler-reg-loop-park-site-direct))
        (= direct-to de)
        ;; the through value is live at that target and the in-loop value is not
        (reg.compiler-reg-loop-park-needs-reload?
          direct-seq
          direct-live
          (reg.compiler-reg-loop-park-site-direct)
          dh
          de
          1)
        (not
          (reg.compiler-reg-loop-park-needs-reload?
            direct-seq
            direct-live
            (reg.compiler-reg-loop-park-site-direct)
            dh
            de
            2))
        ;; two exits: the phi-headed merge is spliced, the Return block is not
        (= splice-count 2)
        (= (array-ref kind 0) (reg.compiler-reg-loop-park-site-splice))
        (= (array-ref from 0) sh)
        (= (array-ref to 0) se)
        (= (array-ref kind 1) (reg.compiler-reg-loop-park-site-direct))
        (= (array-ref to 1) sr)
        ;; %3 is not live-in at the merge -- it is an EDGE use, the phi's
        ;; loop-side input -- and still needs the reload
        (reg.compiler-reg-loop-park-needs-reload?
          splice-seq
          splice-live
          (reg.compiler-reg-loop-park-site-splice)
          sh
          se
          3)
        ;; nothing but the returned value is live into the Return block, so the
        ;; through value needs no reload there
        (not
          (reg.compiler-reg-loop-park-needs-reload?
            splice-seq
            splice-live
            (reg.compiler-reg-loop-park-site-direct)
            sl
            sr
            1))
        (reg.compiler-reg-loop-park-needs-reload?
          splice-seq
          splice-live
          (reg.compiler-reg-loop-park-site-splice)
          sh
          se
          1)))))

;; The rewrite shape, driven from a hand-built decision so the assertions are
;; about the emitter and not about the planner.
(cfg
  test
  (define (compiler-reg-loop-park-mov?
    [instr : ir.CompilerIrInstr]
    [dst : i64]
    [src : i64]) : bool
    (match instr
      [(ir.CompilerIrInstr.Mov d value _)
        (and
          (= d dst)
          (match value
            [(ir.CompilerIrValue.Var v) (= v src)]
            [_ false]))]
      [_ false])))

(cfg
  test
  (define (compiler-reg-loop-park-phi-keyed-on?
    [instr : ir.CompilerIrInstr]
    [var : i64]
    [label : i64]) : bool
    (match instr
      [(ir.CompilerIrInstr.Phi _ inputs _)
        (reg.compiler-reg-loop-park-phi-input-on-edge? inputs label var)]
      [_ false])))

(cfg
  test
  (define (compiler-reg-loop-park-branch-false [instr : ir.CompilerIrInstr]) : i64
    (match instr
      [(ir.CompilerIrInstr.Branch _ _ f) f]
      [_ (- 0 1)])))

(cfg
  test
  (define (compiler-reg-loop-park-direct-rewrite-ok?) : bool
    (match (compiler-reg-loop-park-direct-function)
      [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [count : i64 (ir.compiler-ir-block-seq-count seq)]
          [type-info : reg.CompilerRegVarTypes
            (reg.compiler-reg-function-var-types
              (compiler-reg-loop-park-direct-function))]
          [pre : i64 (compiler-reg-loop-park-block-index seq "preheader")]
          [exit : i64 (compiler-reg-loop-park-block-index seq "exit")]
          [pk : reg.CompilerRegLoopParkPlan
            (reg.compiler-reg-loop-park-plan-make count vars)]
          (begin
            (reg.compiler-reg-loop-park-plan-reset! pk)
            (set! (array-ref pk.park-var 0) 1)
            (set! (array-ref pk.park-carrier 0) vars)
            (set! (array-ref pk.park-loop 0) 0)
            (set! (array-ref pk.park-pre 0) pre)
            (set!
              (array-ref pk.park-store-at 0)
              (reg.compiler-reg-loop-park-store-position seq pre 1))
            (set! (array-ref pk.pre-mask pre) 1)
            (set! (array-ref pk.direct-mask exit) 1)
            (set! (array-ref pk.site-from 0) (- 0 1))
            (set! (array-ref pk.site-to 0) exit)
            (set!
              (array-ref pk.site-kind 0)
              (reg.compiler-reg-loop-park-site-direct))
            (set! (array-ref pk.site-mask 0) 1)
            (set! (array-ref pk.site-label 0) (ir.compiler-ir-label-none))
            (set! (array-ref pk.site-weight 0) 1)
            (set! (array-ref pk.loop-header 0) 0)
            (set! (array-ref pk.counts 0) 1)
            (set! (array-ref pk.counts 1) 1)
            (set! (array-ref pk.counts 2) 1)
            (let
              [out : ir.CompilerIrBlockSeq
                (live.compiler-live-ir-block-list-to-seq
                  (reg.compiler-reg-loop-park-rewrite-blocks pk seq type-info))]
              (and
                ;; a direct reload adds no block
                (= (ir.compiler-ir-block-seq-count out) count)
                ;; the store is the preheader FIRST instruction: as early as the
                ;; block allows, so the register it gives up is free for the
                ;; values defined below it
                (= (array-ref pk.park-store-at 0) 0)
                (compiler-reg-loop-park-mov?
                  (ir.compiler-ir-instr-seq-ref
                    (reg.compiler-reg-loop-park-block-instrs out pre)
                    0)
                  vars
                  1)
                (=
                  (ir.compiler-ir-instr-seq-count
                    (reg.compiler-reg-loop-park-block-instrs out pre))
                  3)
                ;; the reload is the exit target first instruction
                (compiler-reg-loop-park-mov?
                  (ir.compiler-ir-instr-seq-ref
                    (reg.compiler-reg-loop-park-block-instrs out exit)
                    0)
                  1
                  vars)
                (=
                  (ir.compiler-ir-instr-seq-count
                    (reg.compiler-reg-loop-park-block-instrs out exit))
                  3)))))])))

(cfg
  test
  (define (compiler-reg-loop-park-splice-rewrite-ok?) : bool
    (match (compiler-reg-loop-park-splice-function)
      [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [count : i64 (ir.compiler-ir-block-seq-count seq)]
          [type-info : reg.CompilerRegVarTypes
            (reg.compiler-reg-function-var-types
              (compiler-reg-loop-park-splice-function))]
          [pre : i64 (compiler-reg-loop-park-block-index seq "preheader")]
          [header : i64 (compiler-reg-loop-park-block-index seq "header")]
          [exit : i64 (compiler-reg-loop-park-block-index seq "exit")]
          [splice-label : i64
            (reg.compiler-reg-loop-park-splice-label seq header 0)]
          [pk : reg.CompilerRegLoopParkPlan
            (reg.compiler-reg-loop-park-plan-make count vars)]
          (begin
            (reg.compiler-reg-loop-park-plan-reset! pk)
            (set! (array-ref pk.park-var 0) 1)
            (set! (array-ref pk.park-carrier 0) vars)
            (set! (array-ref pk.park-loop 0) 0)
            (set! (array-ref pk.park-pre 0) pre)
            (set!
              (array-ref pk.park-store-at 0)
              (reg.compiler-reg-loop-park-store-position seq pre 1))
            (set! (array-ref pk.pre-mask pre) 1)
            (set! (array-ref pk.site-from 0) header)
            (set! (array-ref pk.site-to 0) exit)
            (set!
              (array-ref pk.site-kind 0)
              (reg.compiler-reg-loop-park-site-splice))
            (set! (array-ref pk.site-mask 0) 1)
            (set! (array-ref pk.site-label 0) splice-label)
            (set! (array-ref pk.site-weight 0) 1)
            (set! (array-ref pk.loop-header 0) 0)
            (set! (array-ref pk.counts 0) 1)
            (set! (array-ref pk.counts 1) 1)
            (set! (array-ref pk.counts 2) 1)
            (let
              [out : ir.CompilerIrBlockSeq
                (live.compiler-live-ir-block-list-to-seq
                  (reg.compiler-reg-loop-park-rewrite-blocks pk seq type-info))]
              [spliced : i64
                (compiler-reg-loop-park-block-index
                  out
                  (ir.compiler-ir-label-text splice-label))]
              (and
                ;; exactly one block is added, and it is APPENDED, so every
                ;; existing block keeps its layout position
                (= (ir.compiler-ir-block-seq-count out) (+ count 1))
                (= spliced count)
                ;; store in the preheader
                (compiler-reg-loop-park-mov?
                  (ir.compiler-ir-instr-seq-ref
                    (reg.compiler-reg-loop-park-block-instrs out pre)
                    0)
                  vars
                  1)
                ;; the spliced block reloads, then jumps to the original target
                (compiler-reg-loop-park-mov?
                  (ir.compiler-ir-instr-seq-ref
                    (reg.compiler-reg-loop-park-block-instrs out spliced)
                    0)
                  1
                  vars)
                (=
                  (ir.compiler-ir-instr-seq-count
                    (reg.compiler-reg-loop-park-block-instrs out spliced))
                  2)
                ;; the loop exit edge now goes through it ...
                (=
                  (compiler-reg-loop-park-branch-false
                    (ir.compiler-ir-instr-seq-ref
                      (reg.compiler-reg-loop-park-block-instrs out header)
                      2))
                  splice-label)
                ;; ... and the merge phi loop-side input is re-keyed to it, so
                ;; it reads the value the reload has just restored
                (compiler-reg-loop-park-phi-keyed-on?
                  (ir.compiler-ir-instr-seq-ref
                    (reg.compiler-reg-loop-park-block-instrs out exit)
                    0)
                  3
                  splice-label)
                (not
                  (compiler-reg-loop-park-phi-keyed-on?
                    (ir.compiler-ir-instr-seq-ref
                      (reg.compiler-reg-loop-park-block-instrs out exit)
                      0)
                    3
                    (reg.compiler-reg-loop-park-block-label seq header)))
                ;; the other predecessor input is untouched
                (compiler-reg-loop-park-phi-keyed-on?
                  (ir.compiler-ir-instr-seq-ref
                    (reg.compiler-reg-loop-park-block-instrs out exit)
                    0)
                  8
                  (ir.compiler-ir-label "other"))))))])))

;; The verify side: a parked loop whose previously spilled residents the replan
;; left in memory is dropped and its header recorded, while one that rescued a
;; resident survives.
(cfg
  test
  (define (compiler-reg-loop-park-verify-ok?) : bool
    (let
      [pk : reg.CompilerRegLoopParkPlan
        (reg.compiler-reg-loop-park-plan-make 8 6)]
      [plan : reg.CompilerRegPlan
        (reg.CompilerRegPlan.Plan
          (reg.compiler-reg-assignments-prepend
            (reg.CompilerRegAssignment
              2
              (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment
                4
                (reg.CompilerRegLocation.Spill
                  (reg.compiler-reg-stack-slot-offset 1)))
              (reg.compiler-reg-assignment-table-empty)))
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-empty)
          (reg.compiler-reg-var-types-empty)
          (reg.compiler-reg-call-split-empty)
          (reg.compiler-reg-split-plan-empty))]
      [dropped : (__tl_dyn-array bool) (__tl_make-array bool 8)]
      (begin
        (reg.compiler-reg-loop-park-plan-reset! pk)
        ;; loop 0 targets var 2, which the replan registerised; loop 1 targets
        ;; var 4, which it did not
        (set! (array-ref pk.resident-mask 2) 1)
        (set! (array-ref pk.resident-mask 4) 2)
        (set! (array-ref pk.loop-header 0) 3)
        (set! (array-ref pk.loop-header 1) 5)
        (set! (array-ref pk.counts 2) 2)
        (and
          (= (reg.compiler-reg-loop-park-drop-failed! pk plan 6 dropped) 1)
          (not (array-ref dropped 3))
          (array-ref dropped 5))))))

;; End to end. The round is handed a plan that homes the through value in a
;; register and leaves the loop's resident in memory, which is exactly the shape
;; it exists for: it parks the through value, replans, finds the estimate lower
;; and keeps the rewrite -- one carrier, minted at the old watermark, forced to
;; the stack.
(cfg
  test
  (define (compiler-reg-loop-park-round-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-loop-park-direct-function)]
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [plan : reg.CompilerRegPlan
        (reg.CompilerRegPlan.Plan
          (reg.compiler-reg-assignments-prepend
            (reg.CompilerRegAssignment
              1
              (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment
                2
                (reg.CompilerRegLocation.Spill
                  (reg.compiler-reg-stack-slot-offset 1)))
              (reg.compiler-reg-assignment-table-empty)))
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-empty)
          (reg.compiler-reg-var-types-empty)
          (reg.compiler-reg-call-split-empty)
          (reg.compiler-reg-split-plan-empty))]
      [split : reg.CompilerRegCallHoleSplit
        (reg.compiler-reg-loop-park-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          cabi.CompilerRegTargetAbi.Linux
          func
          type-info
          plan
          (- 0 1)
          false)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars _)
          (and
            (= (reg.compiler-reg-call-hole-split-vars split) (+ vars 1))
            (= (reg.compiler-reg-call-hole-split-temp-start split) vars)
            (reg.compiler-reg-cold-call-carriers-stack?
              (reg.compiler-reg-call-hole-split-plan split)
              vars
              (+ vars 1)))]))))

;; And the revert: a plan with nothing in memory presents no rescue, so the
;; round hands back its input -- same watermark, same threshold.
(cfg
  test
  (define (compiler-reg-loop-park-declines-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-loop-park-direct-function)]
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [plan : reg.CompilerRegPlan
        (reg.CompilerRegPlan.Plan
          (reg.compiler-reg-assignments-prepend
            (reg.CompilerRegAssignment
              1
              (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))
            (reg.compiler-reg-assignment-table-empty))
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-empty)
          (reg.compiler-reg-var-types-empty)
          (reg.compiler-reg-call-split-empty)
          (reg.compiler-reg-split-plan-empty))]
      [split : reg.CompilerRegCallHoleSplit
        (reg.compiler-reg-loop-park-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          cabi.CompilerRegTargetAbi.Linux
          func
          type-info
          plan
          (- 0 1)
          false)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars _)
          (and
            (= (reg.compiler-reg-call-hole-split-vars split) vars)
            (= (reg.compiler-reg-call-hole-split-temp-start split) (- 0 1)))]))))

;; --- P12: the merged-kernel shape, and the two ladders that decide it --------
;; A hand-inlined kernel puts its hottest loop DEEP. `it-intern-slice` inlined
;; into its driver leaves the byte compare at loop depth 5, inside a depth-4
;; probe loop, inside the per-symbol / per-pass / per-round loops. Two frequency
;; ladders used to flatten at depth 4, and both of them then decided that loop
;; against itself:
;;
;;   * P3c's parking cost model (`compiler-reg-loop-park-block-weight`). The
;;     round prices "park a value the loop never touches" as W(preheader) plus
;;     one W(exit) per live exit, against W(body) per reference an L-resident
;;     makes. On a ladder that flattens, a depth-5 body and a depth-4 boundary
;;     weigh the SAME, so the boundary costs at least twice one resident
;;     reference and `compiler-reg-loop-park-pair!` can never accept -- however
;;     hot the loop actually is.
;;
;;   * the greedy's spill weight (`compiler-reg-loop-depth-weight`). A reference
;;     at depth 5 scored exactly as much as one at depth 4, so the byte loop's
;;     own base pointer ranked level with the hoisted Vec headers the loop never
;;     touches, and lost the tie on var id.
;;
;; `loop_park_deep_nest` is that shape reduced to its skeleton: four plain outer
;; loops around a ROTATED inner loop in the versioner's `__bce_fast` form -- a
;; landing block that is the dedicated preheader, a header that opens with the
;; induction phi, the trip test at the bottom -- whose body reads TWO base
;; pointers defined one level out, with three values live across the whole nest
;; that the inner loop never mentions.
(cfg
  test
  (define (compiler-reg-park-nest-levels) : i64
    4))

(cfg
  test
  (define (compiler-reg-park-nest-label [prefix : String] [level : i64]) : i64
    (ir.compiler-ir-label (str_cat.str-cat prefix (string.int->string level)))))

;; Per-level var ids: counter, trip condition, increment.
(cfg
  test
  (define (compiler-reg-park-nest-ctr [level : i64]) : i64
    (+ 20 (* 3 level))))

(cfg
  test
  (define (compiler-reg-park-nest-cond [level : i64]) : i64
    (+ 21 (* 3 level))))

(cfg
  test
  (define (compiler-reg-park-nest-next [level : i64]) : i64
    (+ 22 (* 3 level))))

(cfg
  test
  (define (compiler-reg-park-nest-binop
    [dst : i64]
    [op : ir.CompilerIrBinOp]
    [lhs : ir.CompilerIrValue]
    [rhs : ir.CompilerIrValue]) : ir.CompilerIrInstr
    (ir.CompilerIrInstr.BinOp dst op lhs rhs (compiler-reg-i64-ty))))

;; entry: mint the three through values, then descend into the nest.
(cfg
  test
  (define (compiler-reg-park-nest-entry-block) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "entry")
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.Mov
          10
          (ir.CompilerIrValue.I64 11)
          (compiler-reg-i64-ty))
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            11
            (ir.CompilerIrValue.I64 12)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              12
              (ir.CompilerIrValue.I64 13)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (compiler-reg-park-nest-label "pre." 0))
              (ir.compiler-ir-instr-seq-empty))))))))

(cfg
  test
  (define (compiler-reg-park-nest-pre-block [level : i64]) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (compiler-reg-park-nest-label "pre." level)
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.Jump (compiler-reg-park-nest-label "hdr." level))
        (ir.compiler-ir-instr-seq-empty)))))

(cfg
  test
  (define (compiler-reg-park-nest-hdr-block [level : i64]) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (compiler-reg-park-nest-label "hdr." level)
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.Phi
          (compiler-reg-park-nest-ctr level)
          (ir.compiler-ir-phi-input-cons
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-park-nest-label "pre." level)
            (ir.compiler-ir-phi-input-cons
              (ir.CompilerIrValue.Var (compiler-reg-park-nest-next level))
              (compiler-reg-park-nest-label "lat." level)
              ir.CompilerIrPhiInputList.Nil))
          (compiler-reg-i64-ty))
        (compiler-reg-test-instr-seq-prepend
          (compiler-reg-park-nest-binop
            (compiler-reg-park-nest-cond level)
            (ir.CompilerIrBinOp.Lt)
            (ir.CompilerIrValue.Var (compiler-reg-park-nest-ctr level))
            (ir.CompilerIrValue.Var 0))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Var (compiler-reg-park-nest-cond level))
              (compiler-reg-park-nest-label "body." level)
              (compiler-reg-park-nest-label "exit." level))
            (ir.compiler-ir-instr-seq-empty)))))))

;; The innermost level's body is where the two base pointers are computed: once
;; per entry into the inner loop, one level OUT from the references that read
;; them, which is the merged kernel's own shape.
(cfg
  test
  (define (compiler-reg-park-nest-body-block [level : i64] [levels : i64]) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (compiler-reg-park-nest-label "body." level)
      (if (< level (- levels 1))
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Jump
            (compiler-reg-park-nest-label "pre." (+ level 1)))
          (ir.compiler-ir-instr-seq-empty))
        (compiler-reg-test-instr-seq-prepend
          (compiler-reg-park-nest-binop
            1
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.Var (compiler-reg-park-nest-ctr level)))
          (compiler-reg-test-instr-seq-prepend
            (compiler-reg-park-nest-binop
              2
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var (compiler-reg-park-nest-ctr level))
              (ir.CompilerIrValue.Var 0))
            (compiler-reg-test-instr-seq-prepend
              (compiler-reg-park-nest-binop
                67
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 10)
                (ir.CompilerIrValue.Var 11))
              (compiler-reg-test-instr-seq-prepend
                (compiler-reg-park-nest-binop
                  68
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 67)
                  (ir.CompilerIrValue.Var 12))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "land"))
                  (ir.compiler-ir-instr-seq-empty))))))))))

(cfg
  test
  (define (compiler-reg-park-nest-lat-block [level : i64] [levels : i64]) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (compiler-reg-park-nest-label "lat." level)
      (if (= level (- levels 1))
        (compiler-reg-test-instr-seq-prepend
          (compiler-reg-park-nest-binop
            69
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.Var 66)
            (ir.CompilerIrValue.Var 68))
          (compiler-reg-test-instr-seq-prepend
            (compiler-reg-park-nest-binop
              (compiler-reg-park-nest-next level)
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var (compiler-reg-park-nest-ctr level))
              (ir.CompilerIrValue.Var 69))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump
                (compiler-reg-park-nest-label "hdr." level))
              (ir.compiler-ir-instr-seq-empty))))
        (compiler-reg-test-instr-seq-prepend
          (compiler-reg-park-nest-binop
            (compiler-reg-park-nest-next level)
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.Var (compiler-reg-park-nest-ctr level))
            (ir.CompilerIrValue.I64 1))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump
              (compiler-reg-park-nest-label "hdr." level))
            (ir.compiler-ir-instr-seq-empty)))))))

;; The outermost exit is the only place the three through values are read, so
;; each of them is live across every loop of the nest and mentioned in none.
(cfg
  test
  (define (compiler-reg-park-nest-exit-block [level : i64]) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (compiler-reg-park-nest-label "exit." level)
      (if (> level 0)
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Jump
            (compiler-reg-park-nest-label "lat." (- level 1)))
          (ir.compiler-ir-instr-seq-empty))
        (compiler-reg-test-instr-seq-prepend
          (compiler-reg-park-nest-binop
            70
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.Var 10)
            (ir.CompilerIrValue.Var 11))
          (compiler-reg-test-instr-seq-prepend
            (compiler-reg-park-nest-binop
              71
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 70)
              (ir.CompilerIrValue.Var 12))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 71)))
              (ir.compiler-ir-instr-seq-empty))))))))

;; The rotated inner loop, in the versioner's `__bce_fast` form: `land` is the
;; rotate landing block and the loop's dedicated preheader, `ihdr` opens with
;; the induction phi, and the trip test lives at the bottom in `imerge`. Both
;; exits leave for a block that opens with a phi, so both are SPLICED sites.
(cfg
  test
  (define (compiler-reg-park-nest-land-block) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "land")
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "ihdr"))
        (ir.compiler-ir-instr-seq-empty)))))

(cfg
  test
  (define (compiler-reg-park-nest-ihdr-block) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "ihdr")
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.Phi
          60
          (ir.compiler-ir-phi-input-cons
            (ir.CompilerIrValue.I64 0)
            (ir.compiler-ir-label "land")
            (ir.compiler-ir-phi-input-cons
              (ir.CompilerIrValue.Var 64)
              (ir.compiler-ir-label "imerge")
              ir.CompilerIrPhiInputList.Nil))
          (compiler-reg-i64-ty))
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "ibody"))
          (ir.compiler-ir-instr-seq-empty))))))

(cfg
  test
  (define (compiler-reg-park-nest-ibody-block) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "ibody")
      (compiler-reg-test-instr-seq-prepend
        (compiler-reg-park-nest-binop
          61
          (ir.CompilerIrBinOp.Add)
          (ir.CompilerIrValue.Var 1)
          (ir.CompilerIrValue.Var 60))
        (compiler-reg-test-instr-seq-prepend
          (compiler-reg-park-nest-binop
            62
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.Var 2)
            (ir.CompilerIrValue.Var 60))
          (compiler-reg-test-instr-seq-prepend
            (compiler-reg-park-nest-binop
              63
              (ir.CompilerIrBinOp.Lt)
              (ir.CompilerIrValue.Var 61)
              (ir.CompilerIrValue.Var 62))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 63)
                (ir.compiler-ir-label "imerge")
                (ir.compiler-ir-label "iexit"))
              (ir.compiler-ir-instr-seq-empty))))))))

(cfg
  test
  (define (compiler-reg-park-nest-imerge-block) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "imerge")
      (compiler-reg-test-instr-seq-prepend
        (compiler-reg-park-nest-binop
          64
          (ir.CompilerIrBinOp.Add)
          (ir.CompilerIrValue.Var 60)
          (ir.CompilerIrValue.I64 1))
        (compiler-reg-test-instr-seq-prepend
          (compiler-reg-park-nest-binop
            65
            (ir.CompilerIrBinOp.Lt)
            (ir.CompilerIrValue.Var 64)
            (ir.CompilerIrValue.Var 0))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Var 65)
              (ir.compiler-ir-label "ihdr")
              (ir.compiler-ir-label "iexit"))
            (ir.compiler-ir-instr-seq-empty)))))))

(cfg
  test
  (define (compiler-reg-park-nest-iexit-block [levels : i64]) : ir.CompilerIrBlock
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "iexit")
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.Phi
          66
          (ir.compiler-ir-phi-input-cons
            (ir.CompilerIrValue.I64 0)
            (ir.compiler-ir-label "ibody")
            (ir.compiler-ir-phi-input-cons
              (ir.CompilerIrValue.I64 1)
              (ir.compiler-ir-label "imerge")
              ir.CompilerIrPhiInputList.Nil))
          (compiler-reg-i64-ty))
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Jump
            (compiler-reg-park-nest-label "lat." (- levels 1)))
          (ir.compiler-ir-instr-seq-empty))))))

(cfg
  test
  (define (compiler-reg-loop-park-deep-nest-function) : ir.CompilerIrFunction
    (let
      [levels : i64 (compiler-reg-park-nest-levels)]
      [blocks : (__tl_dyn-array ir.CompilerIrBlock)
        (__tl_make-array ir.CompilerIrBlock (+ 6 (* 5 levels)))]
      [write : i64 0]
      [level : i64 0]
      (begin
        (set! (array-ref blocks write) (compiler-reg-park-nest-entry-block))
        (set! write (+ write 1))
        (while (< level levels)
          (begin
            (set!
              (array-ref blocks write)
              (compiler-reg-park-nest-pre-block level))
            (set!
              (array-ref blocks (+ write 1))
              (compiler-reg-park-nest-hdr-block level))
            (set!
              (array-ref blocks (+ write 2))
              (compiler-reg-park-nest-body-block level levels))
            (set! write (+ write 3))
            (set! level (+ level 1))))
        (set! (array-ref blocks write) (compiler-reg-park-nest-land-block))
        (set!
          (array-ref blocks (+ write 1))
          (compiler-reg-park-nest-ihdr-block))
        (set!
          (array-ref blocks (+ write 2))
          (compiler-reg-park-nest-ibody-block))
        (set!
          (array-ref blocks (+ write 3))
          (compiler-reg-park-nest-imerge-block))
        (set!
          (array-ref blocks (+ write 4))
          (compiler-reg-park-nest-iexit-block levels))
        (set! write (+ write 5))
        (set! level (- levels 1))
        (while (>= level 0)
          (begin
            (set!
              (array-ref blocks write)
              (compiler-reg-park-nest-lat-block level levels))
            (set!
              (array-ref blocks (+ write 1))
              (compiler-reg-park-nest-exit-block level))
            (set! write (+ write 2))
            (set! level (- level 1))))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "loop_park_deep_nest")
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "bound" (compiler-reg-i64-ty) 0)
            ir.CompilerIrParamList.Nil)
          (ast.AstType.I64)
          80
          (ir.CompilerIrBlockList.Array (ir.CompilerIrBlockSeq blocks write)))))))

;; Two small builders for a hand-written plan, so the fixture can say exactly
;; which values the greedy is imagined to have homed.
(cfg
  test
  (define (compiler-reg-park-nest-reg
    [var : i64]
    [id : i64]
    [rest : reg.CompilerRegAssignmentTable]) : reg.CompilerRegAssignmentTable
    (reg.compiler-reg-assignments-prepend
      (reg.CompilerRegAssignment var (reg.CompilerRegLocation.Register id))
      rest)))

(cfg
  test
  (define (compiler-reg-park-nest-spill
    [var : i64]
    [slot : i64]
    [rest : reg.CompilerRegAssignmentTable]) : reg.CompilerRegAssignmentTable
    (reg.compiler-reg-assignments-prepend
      (reg.CompilerRegAssignment
        var
        (reg.CompilerRegLocation.Spill
          (reg.compiler-reg-stack-slot-offset slot)))
      rest)))

;; The plan the round is handed. Every OTHER resident of the inner loop already
;; holds a register, so the two base pointers are its only spilled residents and
;; the pairing it has to make is exactly base <-> through value -- one register
;; freed over the loop per base that needs one.
;;
;; With `bases-homed` true the two bases hold registers and a through value is
;; in memory instead: the function still HAS a spill, the loop still has values
;; live across it, and there is still nothing a parked register could rescue.
(cfg
  test
  (define (compiler-reg-loop-park-deep-nest-plan [bases-homed : bool]) : reg.CompilerRegPlan
    (reg.CompilerRegPlan.Plan
      (compiler-reg-park-nest-reg
        0
        cabi.compiler-reg-id-rax
        (compiler-reg-park-nest-reg
          60
          cabi.compiler-reg-id-rcx
          (compiler-reg-park-nest-reg
            61
            cabi.compiler-reg-id-rdx
            (compiler-reg-park-nest-reg
              62
              cabi.compiler-reg-id-rsi
              (compiler-reg-park-nest-reg
                63
                cabi.compiler-reg-id-rdi
                (compiler-reg-park-nest-reg
                  64
                  cabi.compiler-reg-id-r8
                  (compiler-reg-park-nest-reg
                    65
                    cabi.compiler-reg-id-r9
                    (compiler-reg-park-nest-reg
                      10
                      cabi.compiler-reg-id-r12
                      (compiler-reg-park-nest-reg
                        11
                        cabi.compiler-reg-id-r13
                        (if bases-homed
                          (compiler-reg-park-nest-spill
                            12
                            3
                            (compiler-reg-park-nest-reg
                              1
                              cabi.compiler-reg-id-rbx
                              (compiler-reg-park-nest-reg
                                2
                                cabi.compiler-reg-id-r15
                                (reg.compiler-reg-assignment-table-empty))))
                          (compiler-reg-park-nest-reg
                            12
                            cabi.compiler-reg-id-r14
                            (compiler-reg-park-nest-spill
                              1
                              1
                              (compiler-reg-park-nest-spill
                                2
                                2
                                (reg.compiler-reg-assignment-table-empty))))))))))))))
      (live.compiler-live-set-empty)
      (reg.compiler-reg-interval-seq-empty)
      (reg.compiler-reg-var-types-empty)
      (reg.compiler-reg-call-split-empty)
      (reg.compiler-reg-split-plan-empty))))

(cfg
  test
  (define (compiler-reg-loop-park-deep-nest-split [bases-homed : bool]) : reg.CompilerRegCallHoleSplit
    (let
      [func : ir.CompilerIrFunction (compiler-reg-loop-park-deep-nest-function)]
      (reg.compiler-reg-loop-park-rewrite-function
        (ast.ast-node-pool-reader-type-segment-bases)
        cabi.CompilerRegTargetAbi.Linux
        func
        (reg.compiler-reg-function-var-types func)
        (compiler-reg-loop-park-deep-nest-plan bases-homed)
        (- 0 1)
        false))))

;; (1) The rotated inner-loop shape PARKS. Two base pointers are in memory and
;; the loop has three values live across it that it never mentions, so the round
;; parks one per base -- the trade the flattened cost ladder made arithmetically
;; impossible at this depth, whatever the trip count.
(cfg
  test
  (define (compiler-reg-loop-park-deep-parks-ok?) : bool
    (let
      [split : reg.CompilerRegCallHoleSplit
        (compiler-reg-loop-park-deep-nest-split false)]
      (match (compiler-reg-loop-park-deep-nest-function)
        [(ir.CompilerIrFunction.Function _ _ _ vars _)
          (and
            ;; one park per base: a parked value frees ONE register over the
            ;; loop and the loop has two operands that each need one
            (= (reg.compiler-reg-call-hole-split-vars split) (+ vars 2))
            (= (reg.compiler-reg-call-hole-split-temp-start split) vars)
            ;; every carrier is forced to the stack, so the boundary movs pay
            ;; for themselves inside the round's own estimate
            (reg.compiler-reg-cold-call-carriers-stack?
              (reg.compiler-reg-call-hole-split-plan split)
              vars
              (+ vars 2)))]))))

;; (2) BOTH bases of the two-base inner loop come out of the round in registers.
;; One park frees one register over the loop and the loop has two operands that
;; need one, so a round that rescues only the first leaves the byte compare
;; reloading one base through the emergency scavenge on every iteration.
(cfg
  test
  (define (compiler-reg-loop-park-deep-two-bases-homed-ok?) : bool
    (let
      [split : reg.CompilerRegCallHoleSplit
        (compiler-reg-loop-park-deep-nest-split false)]
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-plan-assignments
          (reg.compiler-reg-call-hole-split-plan split))]
      (and
        (reg.compiler-reg-call-hole-register-homed? assignments 1)
        (reg.compiler-reg-call-hole-register-homed? assignments 2)))))

;; (3) The negative. With both bases already in registers the inner loop has no
;; spilled resident, so no parked register could rescue anything and the round
;; hands back its input untouched -- same watermark, same threshold -- even
;; though the function still has a spilled value elsewhere and the loop still
;; has through values it could otherwise have parked.
(cfg
  test
  (define (compiler-reg-loop-park-deep-declines-ok?) : bool
    (let
      [split : reg.CompilerRegCallHoleSplit
        (compiler-reg-loop-park-deep-nest-split true)]
      (match (compiler-reg-loop-park-deep-nest-function)
        [(ir.CompilerIrFunction.Function _ _ _ vars _)
          (and
            (= (reg.compiler-reg-call-hole-split-vars split) vars)
            (= (reg.compiler-reg-call-hole-split-temp-start split) (- 0 1)))]))))

;; And the ranking side of the same fixture, read straight off the greedy's own
;; spill weights. Base pointer %1 has one reference INSIDE the inner loop plus
;; its definition one level out; %67 is a value the inner loop never touches
;; with two references at that outer level. Flattened at depth 4 the two score
;; identically, and an exact tie is broken by var id rather than by frequency --
;; which is how a 15.2M-execution reference lost its register to a 2.5M one.
;; Continued to the nest cap, the loop's own operand wins on frequency.
(cfg
  test
  (define (compiler-reg-loop-park-deep-ranking-ok?) : bool
    (let
      [weights : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights
          (compiler-reg-loop-park-deep-nest-function))]
      (and
        (> (array-ref weights 1) (array-ref weights 67))
        (> (array-ref weights 2) (array-ref weights 67))))))

;; The invariant both ladders now keep, stated as arithmetic. P3c's cost model
;; is only meaningful while one loop level is a FIXED factor: the preheader
;; store and each exit reload have to stay 1/8 of one in-loop reference, and one
;; loop level deeper has to stay worth 2 in the greedy's ranking. A ladder that
;; saturates breaks both claims at the saturation point, and does it silently.
;; Block depths themselves saturate at `compiler-reg-loop-depth-max`, so that is
;; where the ladders may -- and do -- stop.
(cfg
  test
  (define (compiler-reg-park-ladder-step-ok? [depth : i64]) : bool
    (if (>= depth (reg.compiler-reg-loop-depth-max))
      true
      (and
        (=
          (reg.compiler-reg-loop-park-block-weight (+ depth 1))
          (* 8 (reg.compiler-reg-loop-park-block-weight depth)))
        (=
          (reg.compiler-reg-loop-depth-weight (+ depth 1))
          (* 2 (reg.compiler-reg-loop-depth-weight depth)))
        (compiler-reg-park-ladder-step-ok? (+ depth 1))))))

(cfg
  test
  (define (compiler-reg-park-ladder-ok?) : bool
    (and
      (compiler-reg-park-ladder-step-ok? 0)
      ;; and the parking ladder still agrees with P3's on every depth P3 itself
      ;; resolves, so the two rounds price a shallow function identically
      (=
        (reg.compiler-reg-loop-park-block-weight 0)
        (reg.compiler-reg-call-hole-block-weight 0))
      (=
        (reg.compiler-reg-loop-park-block-weight 4)
        (reg.compiler-reg-call-hole-block-weight 4)))))

;; --- P3d scavenge occupancy: segmented liveness, not the coarse hull ---------
;; The backend's scratch picker asks "which registers carry a live value at this
;; instruction" through an occupancy table built from these intervals. Built from
;; each var's coarse HULL that answer saturates in a merged body: the allocator
;; homes two values in one register exactly when their SEGMENTS are disjoint, and
;; the union of their hulls then covers the hole between them, so every register
;; reads occupied everywhere and every spilled-base reload -- which needs a real
;; register and cannot become a memory operand -- falls to the emergency
;; save/reload/restore tier.
;;
;; Two properties the backend depends on are pinned here.
;;
;; (1) With the block-entry live-in bridge OFF, the coarse starts/ends are
;;     BIT-IDENTICAL to `compiler-reg-live-intervals`, so nothing that reads the
;;     hull arrays (divmod own-src election, value-live-after queries) changes;
;;     and a var dead across a middle block gets more than one segment, with no
;;     segment covering that block -- the hole the occupancy table must expose.
;; (2) The bridge itself still does its job when it is ON. It exists so a hull
;;     start is not mistaken for the value's own definition under a block layout
;;     that puts a flow-in block ahead of the defining one (see
;;     compiler-reg-live-in-block-point), and it must stay OFF for the scavenge
;;     table because the point one below a block belongs to the PREVIOUS block in
;;     emission order. The rotated fixture below is exactly that layout: `latch`
;;     reads var 1 and is laid out before `body`, which defines it.
(cfg
  test
  (define (compiler-reg-scavenge-hole-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "scavenge_segment_hole")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      4
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (ast.AstType.I64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.Var 0)
                (ast.AstType.I64))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "middle"))
                (ir.compiler-ir-instr-seq-empty)))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "middle")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                2
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 1)
                (ir.CompilerIrValue.I64 1)
                (ast.AstType.I64))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "tail"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "tail")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  0
                  (ir.CompilerIrValue.I64 9)
                  (ast.AstType.I64))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.BinOp
                    3
                    (ir.CompilerIrBinOp.Add)
                    (ir.CompilerIrValue.Var 0)
                    (ir.CompilerIrValue.Var 2)
                    (ast.AstType.I64))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))
                    (ir.compiler-ir-instr-seq-empty)))))
            ir.CompilerIrBlockList.Nil))))))

;; Rotated layout: entry -> body -> latch -> {body, exit}. Var 1 is READ in
;; `latch` (laid out second) and DEFINED in `body` (laid out third).
(cfg
  test
  (define (compiler-reg-scavenge-rotated-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "scavenge_segment_rotated")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      3
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "body"))
            (ir.compiler-ir-instr-seq-empty)))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "latch")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                2
                (ir.CompilerIrBinOp.Lt)
                (ir.CompilerIrValue.Var 1)
                (ir.CompilerIrValue.I64 10)
                (ast.AstType.I64))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Branch
                  (ir.CompilerIrValue.Var 2)
                  (ir.compiler-ir-label "body")
                  (ir.compiler-ir-label "exit"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  1
                  (ir.CompilerIrValue.I64 7)
                  (ast.AstType.I64))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                  (ir.compiler-ir-instr-seq-empty))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-scavenge-hull-arrays-eq?
    [left : reg.CompilerRegIntervalIndex]
    [right : reg.CompilerRegIntervalIndex]
    [vars : i64]
    [var : i64]) : bool
    (if (>= var vars)
      true
      (and
        (= (array-ref left.starts var) (array-ref right.starts var))
        (= (array-ref left.ends var) (array-ref right.ends var))
        (compiler-reg-scavenge-hull-arrays-eq? left right vars (+ var 1))))))

(cfg
  test
  (define (compiler-reg-scavenge-segments-cover?
    [segments : reg.CompilerRegIntervalSeq]
    [point : i64]
    [index : i64]) : bool
    (if (>= index (reg.compiler-reg-interval-seq-count segments))
      false
      (let
        [row : reg.CompilerRegInterval
          (reg.compiler-reg-interval-seq-ref segments index)]
        (or
          (and (<= row.start point) (<= point row.end))
          (compiler-reg-scavenge-segments-cover? segments point (+ index 1)))))))

(cfg
  test
  (define (compiler-reg-scavenge-segment-hulls-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-scavenge-hole-function)]
      [liveness : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function func)]
      [hull-only : reg.CompilerRegIntervalIndex
        (reg.compiler-reg-interval-index-build
          (reg.compiler-reg-live-intervals func liveness)
          4)]
      [unseeded : reg.CompilerRegIntervalSelection
        (reg.compiler-reg-live-interval-selection-with-live-in
          func
          liveness
          false)]
      [rotated : ir.CompilerIrFunction (compiler-reg-scavenge-rotated-function)]
      [rotated-liveness : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function rotated)]
      [rotated-unseeded : reg.CompilerRegIntervalSelection
        (reg.compiler-reg-live-interval-selection-with-live-in
          rotated
          rotated-liveness
          false)]
      [rotated-seeded : reg.CompilerRegIntervalSelection
        (reg.compiler-reg-live-interval-selection rotated rotated-liveness)]
      (match unseeded
        [(reg.CompilerRegIntervalSelection.Selection _ index)
          (match rotated-unseeded
            [(reg.CompilerRegIntervalSelection.Selection _ rotated-index)
              (match rotated-seeded
                [(reg.CompilerRegIntervalSelection.Selection
                    _
                    rotated-seeded-index)
                  (and
                    ;; (1a) the coarse arrays are the hull builder's, unchanged
                    (compiler-reg-scavenge-hull-arrays-eq? hull-only index 4 0)
                    ;; (1b) var 0 is defined and consumed in `entry`, untouched
                    ;; in `middle`, then redefined and consumed in `tail`
                    (>=
                      (reg.compiler-reg-interval-seq-count
                        (array-ref index.segments 0))
                      2)
                    ;; ... and the hole is real: `middle`'s two instructions sit
                    ;; at points 6 and 8, inside var 0's hull [0, 12]
                    (= (array-ref index.starts 0) 0)
                    (= (array-ref index.ends 0) 12)
                    (compiler-reg-scavenge-segments-cover?
                      (array-ref index.segments 0)
                      0
                      0)
                    (compiler-reg-scavenge-segments-cover?
                      (array-ref index.segments 0)
                      10
                      0)
                    (not
                      (compiler-reg-scavenge-segments-cover?
                        (array-ref index.segments 0)
                        6
                        0))
                    (not
                      (compiler-reg-scavenge-segments-cover?
                        (array-ref index.segments 0)
                        8
                        0))
                    ;; (2) the bridge is what the flag switches: var 1 flows into
                    ;; `latch` (block point 2) from the later-laid-out `body`, so
                    ;; with the bridge on its interval opens at 1 instead of 2
                    (= (array-ref rotated-index.starts 1) 2)
                    (= (array-ref rotated-seeded-index.starts 1) 1))])])]))))

;; Fast scalar backend plan: keep type discovery for emission decisions, but
;; leave values in their stack slots instead of spending compile time on liveness
;; and register assignment. AVX/vector backend modes still use full regalloc.
(cfg
  test
  (define (compiler-reg-param-register-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_registers")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "b" (compiler-reg-i64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "c" (compiler-reg-i64-ty) 2)
            ir.CompilerIrParamList.Nil)))
      (ast.AstType.Unit)
      3
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "pa")
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "pb")
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "pc")
                  (ir.CompilerIrValue.Var 2)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  (ir.compiler-ir-instr-seq-empty))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-float-param-register-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "float_param_registers")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-f64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "b" (compiler-reg-f64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "c" (compiler-reg-f64-ty) 2)
            ir.CompilerIrParamList.Nil)))
      (ast.AstType.Unit)
      3
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "fa")
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-f64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "fb")
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-f64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "fc")
                  (ir.CompilerIrValue.Var 2)
                  (compiler-reg-f64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  (ir.compiler-ir-instr-seq-empty))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-low-xmm-splat-boundary-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "low_xmm_splat_boundary")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "value" (compiler-reg-f64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Splat
              1
              (ir.CompilerIrValue.I64 7)
              4
              (ast.AstType.I64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "low_xmm_splat_sink")
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-f64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                (ir.compiler-ir-instr-seq-empty)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-low-xmm-vector-clobber-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "low_xmm_vector_clobber")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "value" (compiler-reg-f64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.Unit)
      4
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Splat
              1
              (ir.CompilerIrValue.I64 3)
              4
              (ast.AstType.I64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Splat
                2
                (ir.CompilerIrValue.I64 5)
                4
                (ast.AstType.I64))
              (compiler-reg-test-instr-seq-prepend
                (ir.ir-instr-vector-bin-op
                  3
                  (ir.CompilerIrBinOp.Mul)
                  (ir.CompilerIrValue.Var 1)
                  (ir.CompilerIrValue.Var 2)
                  4
                  (ast.AstType.I64))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "low_xmm_vector_sink")
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-f64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                    (ir.compiler-ir-instr-seq-empty)))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-low-xmm-vector-boundaries-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar
      (compiler-reg-low-xmm-splat-boundary-function))
      [(reg.CompilerRegPlan.Plan splat-assignments _ _ _ _ _)
        (match (reg.compiler-reg-plan-function-scalar
          (compiler-reg-low-xmm-vector-clobber-function))
          [(reg.CompilerRegPlan.Plan clobber-assignments _ _ _ _ _)
            (and
              (cfg
                scratch-vreg
                (reg.compiler-reg-location-register?
                  (reg.compiler-reg-assignment-lookup splat-assignments 0)
                  (cabi.compiler-abi-xmm-register-id 0))
                (not
                  (compiler-reg-location-any-register?
                    (reg.compiler-reg-assignment-lookup splat-assignments 0))))
              (not
                (reg.compiler-reg-location-register?
                  (reg.compiler-reg-assignment-lookup clobber-assignments 0)
                  (cabi.compiler-abi-xmm-register-id 0)))
              (not
                (reg.compiler-reg-location-register?
                  (reg.compiler-reg-assignment-lookup clobber-assignments 0)
                  (cabi.compiler-abi-xmm-register-id 1))))])])))

(cfg
  test
  (define (compiler-reg-mixed-float-call-arg-function) : ir.CompilerIrFunction
    (let
      [args : (__tl_dyn-array ir.CompilerIrValue)
        (__tl_make-array ir.CompilerIrValue 4)]
      (begin
        (set! (array-ref args 0) (ir.CompilerIrValue.Var 0))
        (set! (array-ref args 1) (ir.CompilerIrValue.Var 1))
        (set! (array-ref args 2) (ir.CompilerIrValue.Var 2))
        (set! (array-ref args 3) (ir.CompilerIrValue.Var 3))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "mixed_float_call_args")
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "i" (compiler-reg-i64-ty) 0)
            (ir.compiler-ir-param-cons
              (ir.CompilerIrParam.Param "a" (compiler-reg-f64-ty) 1)
              (ir.compiler-ir-param-cons
                (ir.CompilerIrParam.Param "b" (compiler-reg-f64-ty) 2)
                (ir.compiler-ir-param-cons
                  (ir.CompilerIrParam.Param "c" (compiler-reg-f64-ty) 3)
                  ir.CompilerIrParamList.Nil))))
          (ast.AstType.Unit)
          5
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "entry")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Call
                  4
                  (ir.compiler-ir-test-symbol "mixed_float_callee")
                  (ir.CompilerIrCallArgs.Array args)
                  (ast.AstType.Unit))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  (ir.compiler-ir-instr-seq-empty))))
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-win64-rsi-rdi-pressure-function) : ir.CompilerIrFunction
    (let
      [instrs : ir.CompilerIrInstrSeq (ir.compiler-ir-instr-seq-empty)]
      [params : ir.CompilerIrParamList ir.CompilerIrParamList.Nil]
      [i : i64 6]
      (begin
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
            instrs))
        (while (>= i 0)
          (begin
            (set!
              instrs
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "g")
                  (ir.CompilerIrValue.Var i)
                  (compiler-reg-i64-ty))
                instrs))
            (set! i (- i 1))))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Call
              7
              (ir.compiler-ir-test-symbol "side_effect")
              (ir.CompilerIrCallArgs.Nil)
              (ast.AstType.Unit))
            instrs))
        (set! i 6)
        (while (>= i 0)
          (begin
            (set!
              params
              (ir.compiler-ir-param-cons
                (ir.CompilerIrParam.Param
                  (str_cat.str-cat "p" (string.int->string i))
                  (compiler-reg-i64-ty)
                  i)
                params))
            (set! i (- i 1))))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "win64_rsi_rdi_pressure")
          params
          (ast.AstType.Unit)
          8
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block (ir.compiler-ir-label "entry") instrs)
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-zero-call-param-conflict-function) : ir.CompilerIrFunction
    (let
      [instrs : ir.CompilerIrInstrSeq (ir.compiler-ir-instr-seq-empty)]
      (begin
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "p5")
              (ir.CompilerIrValue.Var 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g12")
              (ir.CompilerIrValue.Var 12)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g11")
              (ir.CompilerIrValue.Var 11)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g10")
              (ir.CompilerIrValue.Var 10)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g9")
              (ir.CompilerIrValue.Var 9)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g8")
              (ir.CompilerIrValue.Var 8)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g7")
              (ir.CompilerIrValue.Var 7)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g6")
              (ir.CompilerIrValue.Var 6)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              12
              (ir.CompilerIrValue.I64 12)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              11
              (ir.CompilerIrValue.I64 11)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              10
              (ir.CompilerIrValue.I64 10)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              9
              (ir.CompilerIrValue.I64 9)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              8
              (ir.CompilerIrValue.I64 8)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              7
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              6
              (ir.CompilerIrValue.I64 6)
              (compiler-reg-i64-ty))
            instrs))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "zero_call_param_conflict")
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
            (ir.compiler-ir-param-cons
              (ir.CompilerIrParam.Param "b" (compiler-reg-i64-ty) 1)
              (ir.compiler-ir-param-cons
                (ir.CompilerIrParam.Param "c" (compiler-reg-i64-ty) 2)
                (ir.compiler-ir-param-cons
                  (ir.CompilerIrParam.Param "d" (compiler-reg-i64-ty) 3)
                  (ir.compiler-ir-param-cons
                    (ir.CompilerIrParam.Param "e" (compiler-reg-i64-ty) 4)
                    (ir.compiler-ir-param-cons
                      (ir.CompilerIrParam.Param "f" (compiler-reg-i64-ty) 5)
                      ir.CompilerIrParamList.Nil))))))
          (ast.AstType.Unit)
          13
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block (ir.compiler-ir-label "entry") instrs)
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-param-clobber-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_clobber")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "arg" (compiler-reg-i64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.I64)
      2
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Call
              1
              (ir.compiler-ir-test-symbol "side_effect")
              (ir.CompilerIrCallArgs.Nil)
              (ast.AstType.Unit))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              (ir.compiler-ir-instr-seq-empty))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-param-aggregate-function) : ir.CompilerIrFunction
    (let
      [ty : ast.AstType (ast.AstType.Struct (ci.intern "ParamAggregate"))]
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "param_aggregate")
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "state" ty 0)
          ir.CompilerIrParamList.Nil)
        (ast.AstType.Unit)
        2
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "entry")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov 1 (ir.CompilerIrValue.Var 0) ty)
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                (ir.compiler-ir-instr-seq-empty))))
          ir.CompilerIrBlockList.Nil)))))

(cfg
  test
  ;; GAP3a: zero-call function whose only would-be clobber is a shift by an
  ;; in-range CONSTANT (emitted as `shrq $3` -- no %rcx/%cl use). Params keep
  ;; their ABI pins.
  (define (compiler-reg-param-const-shift-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_const_shift")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "n" (compiler-reg-i64-ty) 1)
          ir.CompilerIrParamList.Nil))
      (ast.AstType.I64)
      3
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              2
              (ir.CompilerIrBinOp.Shr (ast.AstType.I64))
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                2
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 2)
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  ;; GAP3a counterpart: a VARIABLE-count shift stays a clobber point (the
  ;; backend moves the count into %rcx and shifts by %cl). `a` (var 0) is live
  ;; across the shift: t = a >> n; return t + a.
  (define (compiler-reg-param-var-shift-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_var_shift")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "n" (compiler-reg-i64-ty) 1)
          ir.CompilerIrParamList.Nil))
      (ast.AstType.I64)
      3
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              2
              (ir.CompilerIrBinOp.Shr (ast.AstType.I64))
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 1)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                2
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 2)
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  ;; GAP3a: constant in-range shifts are not clobber points, so the pin gate
  ;; sees a clobber-free function and both params keep their incoming ABI
  ;; registers (%rdi/%rsi) -- the crc_update shape.
  (define (compiler-reg-scalar-param-const-shift-pin-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-const-shift-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi))])))

(cfg
  test
  ;; GAP3c: a variable-count shift clobbers only %rcx, so per-register pin
  ;; gating keeps BOTH pins here: a (%rdi) spans the shift but %rdi is not
  ;; shift-clobbered, and n (%rsi, the count) is last-used AT the shift so it
  ;; does not span it. (Pre-GAP3c the function-global gate revoked both ->
  ;; greedy CSR homes; the %rcx narrowing is asserted by
  ;; compiler-reg-scalar-param-rcx-shift-span-ok? below.)
  (define (compiler-reg-scalar-param-var-shift-pin-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-var-shift-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi))])))

(cfg
  test
  ;; GAP3c: params fully consumed BEFORE the first clobber point keep their
  ;; ABI pins even though the function has a call. t = a + a; call; return
  ;; t + t -- a (var 0) ends at point 0, the call is at point 2, so %rdi stays
  ;; pinned while the call-spanning t (var 1) takes a callee-saved home.
  (define (compiler-reg-param-dead-before-call-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_dead_before_call")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.I64)
      4
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              1
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                2
                (ir.compiler-ir-test-symbol "side_effect")
                (ir.CompilerIrCallArgs.Nil)
                (ast.AstType.Unit))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  3
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 1)
                  (ir.CompilerIrValue.Var 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))
                  (ir.compiler-ir-instr-seq-empty))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-dead-before-call-pin-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-dead-before-call-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3c div spanning: v3 = v0 + v0; v4 = v3 / v1; v5 = v4 + v2; return v5.
  ;; A div bans EVERY pin it is spanned by (%rax:%rdx hardwiring + the canned
  ;; divmod expansion's scratch hunger), so the %rdx param v2 -- live across
  ;; it (last use point 4) -- must NOT keep its pin (greedy CSR home instead),
  ;; while v0 (%rdi, ends point 0) and v1 (%rsi, the divisor, last-used AT
  ;; the div = read before the clobber) keep theirs.
  (define (compiler-reg-param-rdx-div-span-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_rdx_div_span")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "b" (compiler-reg-i64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "c" (compiler-reg-i64-ty) 2)
            ir.CompilerIrParamList.Nil)))
      (ast.AstType.I64)
      6
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              3
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                4
                (ir.CompilerIrBinOp.Div)
                (ir.CompilerIrValue.Var 3)
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  5
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 4)
                  (ir.CompilerIrValue.Var 2)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 5)))
                  (ir.compiler-ir-instr-seq-empty))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-rdx-div-span-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-rdx-div-span-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            cabi.compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3c per-register narrowing, shift: v4 = v0 + v0; v5 = v4 << v1;
  ;; v6 = v5 + v2; v7 = v6 + v3; return v7. The variable shift (point 2)
  ;; hardwires only %rcx, so the %rcx param v3 -- live across it (last use
  ;; point 6) -- must NOT keep its pin, while v2 (%rdx) ALSO spans the shift
  ;; and keeps its pin (%rdx is not shift-clobbered), and v0/v1 end at/before
  ;; the shift and keep theirs.
  (define (compiler-reg-param-rcx-shift-span-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_rcx_shift_span")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "n" (compiler-reg-i64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "c" (compiler-reg-i64-ty) 2)
            (ir.compiler-ir-param-cons
              (ir.CompilerIrParam.Param "d" (compiler-reg-i64-ty) 3)
              ir.CompilerIrParamList.Nil))))
      (ast.AstType.I64)
      8
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              4
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                5
                (ir.CompilerIrBinOp.Shl (ast.AstType.I64))
                (ir.CompilerIrValue.Var 4)
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  6
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 5)
                  (ir.CompilerIrValue.Var 2)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.BinOp
                    7
                    (ir.CompilerIrBinOp.Add)
                    (ir.CompilerIrValue.Var 6)
                    (ir.CompilerIrValue.Var 3)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 7)))
                    (ir.compiler-ir-instr-seq-empty)))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-rcx-shift-span-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-rcx-shift-span-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 3))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            cabi.compiler-reg-id-rdx)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 3)
            cabi.compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3c coalesce-hull demotion (the soundness net for per-interval pins):
  ;; v3 = v0 + v0; Mov v1 <- v0 (v0's last use, boundary touch -> v1
  ;; disjoint-coalesces with the param); call; store v1. The walk pins v0 on
  ;; its own clobber-free interval [0,2], but the class {v0,v1} hull [0,6]
  ;; spans the call -- a kept pin would make the post-call store read a
  ;; clobbered %rdi. compiler-reg-param-pins-demote! must revoke the pin and
  ;; the class must land on ONE callee-saved home instead.
  (define (compiler-reg-param-pin-coalesce-demote-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_pin_coalesce_demote")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.Unit)
      4
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              3
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Call
                  2
                  (ir.compiler-ir-test-symbol "side_effect")
                  (ir.CompilerIrCallArgs.Nil)
                  (ast.AstType.Unit))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "g")
                    (ir.CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                    (ir.compiler-ir-instr-seq-empty)))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-pin-coalesce-demote-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-pin-coalesce-demote-function))
      [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
        (and
          (not
            (reg.compiler-reg-location-register?
              (reg.compiler-reg-assignment-lookup assignments 0)
              cabi.compiler-reg-id-rdi))
          (compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 0))
          (compiler-reg-same-location? assignments 0 1))])))

(define (compiler-reg-self-loop-exit-live-phi-mask-ok?) : bool
  (let
    [loop-first : ir.CompilerIrFunction
      (compiler-reg-self-loop-exit-live-phi-function true)]
    [exit-first : ir.CompilerIrFunction
      (compiler-reg-self-loop-exit-live-phi-function false)]
    [loop-first-mask : (__tl_dyn-array i64)
      (reg.compiler-reg-function-phi-touched-safe
        loop-first
        (live.compiler-live-analyze-function-edge-precise loop-first))]
    [exit-first-mask : (__tl_dyn-array i64)
      (reg.compiler-reg-function-phi-touched-safe
        exit-first
        (live.compiler-live-analyze-function-edge-precise exit-first))]
    [fixed-register-mask : (__tl_dyn-array i64)
      (reg.compiler-reg-function-phi-touched-safe-mode
        loop-first
        (live.compiler-live-analyze-function-edge-precise loop-first)
        false)]
    (and
      (compiler-reg-self-loop-exit-live-phi-mask-shape-ok? loop-first-mask)
      (compiler-reg-self-loop-exit-live-phi-mask-shape-ok? exit-first-mask)
      (= (array-ref fixed-register-mask 0) 0)
      (= (array-ref fixed-register-mask 1) 0)
      (= (array-ref fixed-register-mask 3) 0)
      (= (array-ref fixed-register-mask 4) 0))))

;; The counter web of the same self-loop must reach ONE home end to end: with
;; v1/v4 coalesced the back edge carries no phi copy at all, which is what turns
;; `lea ; cmp ; jge exit ; mov ; jmp top` into `add ; cmp ; jl top`. The
;; accumulator web (v0/v3) keeps the home it already had.
(define (compiler-reg-self-loop-counter-coalesce-plan-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar-for-abi
    cabi.CompilerRegTargetAbi.Linux
    (compiler-reg-self-loop-exit-live-phi-function true))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      (and
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 1))
        (compiler-reg-same-location? assignments 1 4)
        (compiler-reg-same-location? assignments 0 3)
        (compiler-reg-different-location? assignments 1 0))]))

;; Negative 1: the counter PHI RESULT is read on the exit edge. One register
;; cannot hold both -- the increment would overwrite the value the exit reads --
;; so the web stays excluded and the back edge keeps its copy.
;; Negative 2: the counter PHI RESULT is read again INSIDE the block, after the
;; increment that feeds the back edge. Same conclusion, different witness.
(define (compiler-reg-self-loop-counter-negative-masks-ok?) : bool
  (let
    [exit-read : ir.CompilerIrFunction
      (compiler-reg-self-loop-counter-exit-read-function)]
    [late-read : ir.CompilerIrFunction
      (compiler-reg-self-loop-counter-late-read-function)]
    [exit-read-mask : (__tl_dyn-array i64)
      (reg.compiler-reg-function-phi-touched-safe
        exit-read
        (live.compiler-live-analyze-function-edge-precise exit-read))]
    [late-read-mask : (__tl_dyn-array i64)
      (reg.compiler-reg-function-phi-touched-safe
        late-read
        (live.compiler-live-analyze-function-edge-precise late-read))]
    (and
      (= (array-ref exit-read-mask 0) 0)
      (= (array-ref exit-read-mask 1) 0)
      (= (array-ref late-read-mask 0) 0)
      (= (array-ref late-read-mask 1) 0)
      (match (reg.compiler-reg-plan-function-scalar-for-abi
        cabi.CompilerRegTargetAbi.Linux
        exit-read)
        [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
          (compiler-reg-different-location? assignments 0 1)])
      (match (reg.compiler-reg-plan-function-scalar-for-abi
        cabi.CompilerRegTargetAbi.Linux
        late-read)
        [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
          (compiler-reg-different-location? assignments 0 1)]))))

(cfg
  test
  (define (compiler-reg-indirect-call-arg-prefs-ok?) : bool
    (let
      [pool : reg.CompilerRegIdSeq
        (reg.compiler-reg-greedy-integer-pool-for-abi
          cabi.CompilerRegTargetAbi.Linux)]
      [prefs : (__tl_dyn-array i64)
        (reg.compiler-reg-function-arg-prefs
          cabi.CompilerRegTargetAbi.Linux
          (compiler-reg-indirect-call-arg-function)
          (compiler-reg-test-identity-coalesce 4)
          4)]
      (and
        (= (array-ref prefs 0) -1)
        (=
          (array-ref prefs 1)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rsi 0))
        (=
          (array-ref prefs 2)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rdx 0))))))

(cfg
  test
  (define (compiler-reg-scalar-linux-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-register-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            cabi.compiler-reg-id-rdx))])))

(cfg
  test
  ;; Win64 zero-clobber pins: params 0/1 keep %rcx/%rdx. Param 2's incoming
  ;; register (%r8) is excluded from the legacy pin set, but M-A (RC1) makes it
  ;; a greedy candidate: it takes the first callee-saved home instead of being
  ;; stack-homed.
  (define (compiler-reg-scalar-windows-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Windows
      (compiler-reg-param-register-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rcx)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rdx)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            cabi.compiler-reg-id-r12))])))

(cfg
  test
  (define (compiler-reg-scalar-float-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-float-param-register-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (cfg
            scratch-vreg
            (and
              (reg.compiler-reg-location-register?
                (reg.compiler-reg-assignment-lookup assignments 0)
                (cabi.compiler-abi-xmm-register-id 0))
              (reg.compiler-reg-location-register?
                (reg.compiler-reg-assignment-lookup assignments 1)
                (cabi.compiler-abi-xmm-register-id 1)))
            (and
              (not
                (compiler-reg-location-any-register?
                  (reg.compiler-reg-assignment-lookup assignments 0)))
              (not
                (compiler-reg-location-any-register?
                  (reg.compiler-reg-assignment-lookup assignments 1)))))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            (cabi.compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-win64-float-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Windows
      (compiler-reg-float-param-register-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            (cfg
              scratch-vreg
              (cabi.compiler-abi-xmm-register-id 0)
              (cabi.compiler-abi-xmm-register-id 6)))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            (cfg
              scratch-vreg
              (cabi.compiler-abi-xmm-register-id 1)
              (cabi.compiler-abi-xmm-register-id 7)))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            (cabi.compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-mixed-float-call-args-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-mixed-float-call-arg-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (live.compiler-live-set-contains? ineligible 0)
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (not (live.compiler-live-set-contains? ineligible 3))
          (compiler-reg-unassigned? assignments 0)
          (cfg
            scratch-vreg
            (and
              (reg.compiler-reg-location-register?
                (reg.compiler-reg-assignment-lookup assignments 1)
                (cabi.compiler-abi-xmm-register-id 0))
              (reg.compiler-reg-location-register?
                (reg.compiler-reg-assignment-lookup assignments 2)
                (cabi.compiler-abi-xmm-register-id 1)))
            (and
              (compiler-reg-unassigned? assignments 1)
              (compiler-reg-unassigned? assignments 2)))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 3)
            (cabi.compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-win64-mixed-float-call-args-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Windows
      (compiler-reg-mixed-float-call-arg-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (live.compiler-live-set-contains? ineligible 0)
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (not (live.compiler-live-set-contains? ineligible 3))
          (compiler-reg-unassigned? assignments 0)
          (cfg
            scratch-vreg
            (reg.compiler-reg-location-register?
              (reg.compiler-reg-assignment-lookup assignments 1)
              (cabi.compiler-abi-xmm-register-id 1))
            (compiler-reg-unassigned? assignments 1))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            (cabi.compiler-abi-xmm-register-id 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 3)
            (cabi.compiler-abi-xmm-register-id 3)))])))

(cfg
  test
  (define (compiler-reg-scalar-windows-rsi-rdi-pool-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Windows
      (compiler-reg-win64-rsi-rdi-pressure-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 6))
          (reg.compiler-reg-assignments-use-register?
            assignments
            cabi.compiler-reg-id-rsi)
          (reg.compiler-reg-assignments-use-register?
            assignments
            cabi.compiler-reg-id-rdi))])))

(cfg
  test
  (define (compiler-reg-test-identity-coalesce [n : i64]) : reg.CompilerRegCoalesceMap
    (let
      [parents : (__tl_dyn-array i64) (__tl_make-array i64 n)]
      [sizes : (__tl_dyn-array i64) (__tl_make-array i64 n)]
      (begin
        (reg.compiler-reg-coalesce-map-init! parents sizes 0)
        (reg.CompilerRegCoalesceMap parents)))))

(cfg
  test
  (define (compiler-reg-win64-arg-result-pref-function) : ir.CompilerIrFunction
    (let
      [args : (__tl_dyn-array ir.CompilerIrValue)
        (__tl_make-array ir.CompilerIrValue 5)]
      (begin
        (set! (array-ref args 0) (ir.CompilerIrValue.Var 0))
        (set! (array-ref args 1) (ir.CompilerIrValue.Var 1))
        (set! (array-ref args 2) (ir.CompilerIrValue.Var 2))
        (set! (array-ref args 3) (ir.CompilerIrValue.Var 3))
        (set! (array-ref args 4) (ir.CompilerIrValue.Var 4))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "win64_arg_result_pref")
          ir.CompilerIrParamList.Nil
          (ast.AstType.I64)
          6
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "entry")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Call
                  5
                  (ir.compiler-ir-test-symbol "callee")
                  (ir.CompilerIrCallArgs.Array args)
                  (ast.AstType.I64))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 5)))
                  (ir.compiler-ir-instr-seq-empty))))
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-win64-arg-result-prefs-ok?) : bool
    (let
      [pool : reg.CompilerRegIdSeq
        (reg.compiler-reg-greedy-integer-pool-for-abi
          cabi.CompilerRegTargetAbi.Windows)]
      [prefs : (__tl_dyn-array i64)
        (reg.compiler-reg-function-arg-prefs
          cabi.CompilerRegTargetAbi.Windows
          (compiler-reg-win64-arg-result-pref-function)
          (compiler-reg-test-identity-coalesce 6)
          6)]
      (and
        (=
          (array-ref prefs 0)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rcx 0))
        (=
          (array-ref prefs 1)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rdx 0))
        (=
          (array-ref prefs 2)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-r8 0))
        (=
          (array-ref prefs 3)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-r9 0))
        (= (array-ref prefs 4) -1)
        (=
          (array-ref prefs 5)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rax 0))))))

(cfg
  test
  ;; M-A (RC1): a clobber-point function no longer stack-homes its params. The
  ;; scalar param cannot keep its ABI pin (the call clobbers %rdi) but becomes
  ;; an ordinary greedy candidate restricted to callee-saved homes: it wins the
  ;; first callee-saved register and is copied there once at entry instead of
  ;; being reloaded from the stack at every use.
  (define (compiler-reg-scalar-param-clobber-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-clobber-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3b: an aggregate-HANDLE param (8-byte struct descriptor) is
  ;; pin-eligible exactly like a scalar (integer-param-type? widened to
  ;; register-eligible), so in this zero-clobber function it keeps its
  ;; incoming %rdi instead of the M-A-era greedy callee-saved home.
  (define (compiler-reg-scalar-aggregate-param-pinned-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-aggregate-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi))])))

;; M-A (RC1): a used param's interval is force-extended to the function's first
;; point (the entry copy writes its home register in the prologue), so the
;; live-in gap param now spans [0,4] instead of the precise builder's [1,4].
(cfg
  test
  ;; Zero-call function with six scalar params, only `f` (var 5) used. The
  ;; unused params 0-4 have no interval, so they can be neither pinned nor
  ;; greedy-allocated (before AND after M-A); var 5 keeps its %r9 ABI pin. The
  ;; zero-call locals 6..12 then fill the caller-saved pool head in candidate
  ;; order -- %rax/%rsi/%rdi with the current pool ordering -- skipping the
  ;; pinned %r9; nothing spills.
  (define (compiler-reg-scalar-zero-call-param-conflict-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-zero-call-param-conflict-function))
      [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
        (and
          (= (reg.compiler-reg-spill-count assignments) 0)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 5)
            cabi.compiler-reg-id-r9)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 6)
            cabi.compiler-reg-id-rax)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 7)
            cabi.compiler-reg-id-rsi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 8)
            cabi.compiler-reg-id-rdi))])))

(cfg
  test
  (define (compiler-reg-remat-weight-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_weight")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                1
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.I64 1)
                (ir.CompilerIrValue.I64 2)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "use1")
                  (ir.CompilerIrValue.Var 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "use0a")
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "use0b")
                      (ir.CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                      (ir.compiler-ir-instr-seq-empty))))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-multi-def-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_multi_def")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                0
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.I64 1)
                (ir.CompilerIrValue.I64 2)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                (ir.compiler-ir-instr-seq-empty)))))
        ir.CompilerIrBlockList.Nil))))

;; ---------------------------------------------------------------------------
;; R5: invariant-load facts.
;;
;; The shape is cfg-build-csr's, reduced: a `&Vec` parameter, the slots handle
;; read out of it, the handle's `len` and `data` words, and an ELEMENT store
;; through the data pointer. Every descriptor word here must stay invariant
;; across that store -- the handle by the typed-word rule (a handle word is
;; class 6, the store is class 1), `len`/`data` because their base is a
;; descriptor handle and a descriptor is outside every payload buffer.
(cfg
  test
  (define (compiler-reg-invariant-descriptor-function
    [extra : ir.CompilerIrInstrSeq]) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "invariant_descriptor")
      (ir.CompilerIrParamList.Cons
        (ir.CompilerIrParam.Param "v" (ast.AstType.Ref 0 0) 0)
        (box ir.CompilerIrParamList.Nil))
      (ast.AstType.Unit)
      9
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Gep
              1
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 0)
              (ast.AstType.U8))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Load
                2
                (ir.CompilerIrValue.Var 1)
                (ast.AstType.DynArray 0))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Gep
                  3
                  (ir.CompilerIrValue.Var 2)
                  (ir.CompilerIrValue.I64 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Load
                    4
                    (ir.CompilerIrValue.Var 3)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Gep
                      5
                      (ir.CompilerIrValue.Var 2)
                      (ir.CompilerIrValue.I64 0)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Load
                        6
                        (ir.CompilerIrValue.Var 5)
                        (ast.AstType.U64))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Gep
                          7
                          (ir.CompilerIrValue.Var 6)
                          (ir.CompilerIrValue.Var 4)
                          (compiler-reg-i64-ty))
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.StorePtr
                            (ir.CompilerIrValue.Var 7)
                            (ir.CompilerIrValue.I64 0)
                            (compiler-reg-i64-ty))
                          extra)))))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-invariant-return-seq) : ir.CompilerIrInstrSeq
    (compiler-reg-test-instr-seq-prepend
      (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
      (ir.compiler-ir-instr-seq-empty))))

(cfg
  test
  (define (compiler-reg-invariant-facts-for [extra : ir.CompilerIrInstrSeq]) : reg.CompilerRegInvariantFacts
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-invariant-descriptor-function extra)]
      (reg.compiler-reg-invariant-facts-build
        func
        (reg.compiler-reg-function-var-types func)))))

(cfg
  test
  (define (compiler-reg-invariant-word-load-admitted-ok?) : bool
    (let
      [facts : reg.CompilerRegInvariantFacts
        (compiler-reg-invariant-facts-for (compiler-reg-invariant-return-seq))]
      (and
        ;; the handle read off the `&Vec` parameter, and both descriptor words
        (reg.compiler-reg-invariant-facts-word-load? facts 2)
        (reg.compiler-reg-invariant-facts-word-load? facts 4)
        (reg.compiler-reg-invariant-facts-word-load? facts 6)
        ;; recorded against the base the recompute has to re-read
        (= (array-ref facts.bases 2) 0)
        (= (array-ref facts.bases 4) 2)
        (= (array-ref facts.bases 6) 2)
        (= (array-ref facts.indexes 4) 1)
        (= (array-ref facts.indexes 6) 0)
        ;; an element store cannot write a named global cell either
        facts.cells-clean
        ;; the ELEMENT address itself is not a descriptor word
        (not (reg.compiler-reg-invariant-facts-word-load? facts 7))))))

;; A FIELD store -- one whose address is a descriptor word rather than an
;; element of a payload buffer -- may write any of these words, so the whole
;; function falls back to "nothing is invariant".
(cfg
  test
  (define (compiler-reg-invariant-field-store-refused-ok?) : bool
    (let
      [facts : reg.CompilerRegInvariantFacts
        (compiler-reg-invariant-facts-for
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.StorePtr
              (ir.CompilerIrValue.Var 3)
              (ir.CompilerIrValue.I64 0)
              (compiler-reg-i64-ty))
            (compiler-reg-invariant-return-seq)))]
      (and
        (not (reg.compiler-reg-invariant-facts-word-load? facts 2))
        (not (reg.compiler-reg-invariant-facts-word-load? facts 4))
        (not (reg.compiler-reg-invariant-facts-word-load? facts 6))
        (not facts.cells-clean)))))

;; A CALL that may write memory is the `&mut`-parameter case: the callee can
;; push through the reference and move `data`/`len`, so no descriptor word of
;; this function is invariant any more (LLVM refuses the same way through
;; `isDereferenceableInvariantLoad`'s mod/ref query).
(cfg
  test
  (define (compiler-reg-invariant-call-refused-ok?) : bool
    (let
      [facts : reg.CompilerRegInvariantFacts
        (compiler-reg-invariant-facts-for
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Call
              8
              (ir.compiler-ir-test-symbol "vec_push")
              ir.CompilerIrCallArgs.Nil
              (ast.AstType.Unit))
            (compiler-reg-invariant-return-seq)))]
      (and
        (not (reg.compiler-reg-invariant-facts-word-load? facts 2))
        (not (reg.compiler-reg-invariant-facts-word-load? facts 4))
        (not (reg.compiler-reg-invariant-facts-word-load? facts 6))
        (not facts.cells-clean)))))

;; The recipe itself: an invariant descriptor word recomputes as the same
;; `gep`+`load` pair the function already ran (which the backend's gep fusion
;; cluster folds into one memory operand), and a zero index needs no address
;; instruction at all.
(cfg
  test
  (define (compiler-reg-invariant-recipe-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-invariant-descriptor-function
          (compiler-reg-invariant-return-seq))]
      [table : reg.CompilerRegRematTable
        (reg.compiler-reg-remat-table-build
          func
          (reg.compiler-reg-function-var-types func))]
      (and
        (= (array-ref table.wide 4) 1)
        (= (array-ref table.kinds 4) (reg.compiler-reg-remat-kind-word-load))
        (not (reg.compiler-reg-remat-zero-offset? table 4))
        (reg.compiler-reg-remat-zero-offset? table 6)
        (match (reg.compiler-reg-remat-address-instr table 20 4)
          [(ir.CompilerIrInstr.Gep dst base offset _)
            (and
              (= dst 20)
              (match base
                [(ir.CompilerIrValue.Var b) (= b 2)]
                [_ false])
              (match offset
                [(ir.CompilerIrValue.I64 k) (= k 1)]
                [_ false]))]
          [_ false])
        (match (reg.compiler-reg-remat-value-instr table 21 20 1 4)
          [(ir.CompilerIrInstr.Load dst src _)
            (and
              (= dst 21)
              (match src
                [(ir.CompilerIrValue.Var a) (= a 20)]
                [_ false]))]
          [_ false])
        ;; index 0: the base IS the address, so one instruction serves
        (match (reg.compiler-reg-remat-value-instr table 22 22 0 6)
          [(ir.CompilerIrInstr.Load dst src _)
            (and
              (= dst 22)
              (match src
                [(ir.CompilerIrValue.Var b) (= b 2)]
                [_ false]))]
          [_ false])))))

;; LLVM's `allUsesAvailableAt`: a recompute may only run where its base operand
;; is still in a register and still carries that value. A spilled base fails.
(cfg
  test
  (define (compiler-reg-invariant-base-availability-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-invariant-descriptor-function
          (compiler-reg-invariant-return-seq))]
      [table : reg.CompilerRegRematTable
        (reg.compiler-reg-remat-table-build
          func
          (reg.compiler-reg-function-var-types func))]
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-make 9)]
      [liveness : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function func)]
      (begin
        (reg.compiler-reg-assignment-table-insert
          assignments
          2
          (reg.CompilerRegLocation.Spill 0))
        (match (reg.compiler-reg-live-interval-selection func liveness)
          [(reg.CompilerRegIntervalSelection.Selection _ index)
            (and
              ;; base spilled -> refused everywhere
              (not
                (reg.compiler-reg-remat-base-available?
                  table
                  assignments
                  index
                  6
                  4))
              ;; a value with no register operand at all is always available
              (reg.compiler-reg-remat-base-available?
                table
                assignments
                index
                6
                0))])))))

(cfg
  test
  (define (compiler-reg-remat-classifier-ok?) : bool
    (and
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          10
          (ir.CompilerIrValue.I64 1)
          (compiler-reg-i64-ty)))
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          11
          (ir.CompilerIrValue.Bool true)
          (ast.AstType.Bool)))
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          12
          (ir.CompilerIrValue.Char 'x')
          (ast.AstType.Char)))
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          13
          (ir.CompilerIrValue.F64 0x3ff0000000000000)
          (compiler-reg-f64-ty)))
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          14
          (ir.CompilerIrValue.GlobalAddr (ir.compiler-ir-test-symbol "global"))
          (ast.AstType.U64)))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Mov
            15
            (ir.CompilerIrValue.Global (ir.compiler-ir-test-symbol "global"))
            (compiler-reg-i64-ty))))
      (compiler-reg-remat-defn-with-invariant-loads?
        (ir.CompilerIrInstr.Mov
          16
          (ir.CompilerIrValue.Global (ir.compiler-ir-test-symbol "global"))
          (compiler-reg-i64-ty))
        true)
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Gep
          17
          (ir.CompilerIrValue.GlobalAddr (ir.compiler-ir-test-symbol "global"))
          (ir.CompilerIrValue.I64 2)
          (compiler-reg-i64-ty)))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Gep
            18
            (ir.CompilerIrValue.GlobalAddr
              (ir.compiler-ir-test-symbol "global"))
            (ir.CompilerIrValue.Var 0)
            (compiler-reg-i64-ty))))
      ;; R5: `gep BASE, K` with a REGISTER base and a constant offset is one
      ;; `leaq K*w(%base), %r` -- exactly the cost of the reload it replaces --
      ;; so the shape is admitted here; whether the base is really in a register
      ;; and live at a given use is the rewrite's per-use question.
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Gep
          19
          (ir.CompilerIrValue.Var 0)
          (ir.CompilerIrValue.I64 2)
          (compiler-reg-i64-ty)))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Gep
            27
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.Var 1)
            (compiler-reg-i64-ty))))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Load
            20
            (ir.CompilerIrValue.GlobalAddr
              (ir.compiler-ir-test-symbol "global"))
            (compiler-reg-i64-ty))))
      (compiler-reg-remat-defn-with-invariant-loads?
        (ir.CompilerIrInstr.Load
          21
          (ir.CompilerIrValue.GlobalAddr (ir.compiler-ir-test-symbol "global"))
          (compiler-reg-i64-ty))
        true)
      (not
        (compiler-reg-remat-defn-with-invariant-loads?
          (ir.CompilerIrInstr.Load
            22
            (ir.CompilerIrValue.Var 0)
            (compiler-reg-i64-ty))
          true))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Mov
            23
            (ir.CompilerIrValue.Var 0)
            (compiler-reg-i64-ty))))
      ;; W3: a String/Function/Bytes mov materialises as one
      ;; `leaq label(%rip)` and IS rematerialisable, so the spill-weight
      ;; discount must see it as a candidate (it was missing before).
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          24
          (ir.CompilerIrValue.String "heap")
          (ast.AstType.String)))
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          26
          (ir.CompilerIrValue.Function (ir.compiler-ir-test-symbol "fn"))
          (ast.AstType.U64)))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.BinOp
            25
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.I64 1)
            (ir.CompilerIrValue.I64 2)
            (compiler-reg-i64-ty)))))))

(cfg
  test
  (define (compiler-reg-remat-recompute-classifier-ok?) : bool
    (and
      ;; Static address materialisations: admitted at any word type, unchanged.
      (reg.compiler-reg-remat-recompute-value?
        (ir.CompilerIrValue.GlobalAddr (ir.compiler-ir-test-symbol "global"))
        (ast.AstType.U64)
        false)
      (reg.compiler-reg-remat-recompute-value?
        (ir.CompilerIrValue.Function (ir.compiler-ir-test-symbol "fn"))
        (ast.AstType.U64)
        false)
      (reg.compiler-reg-remat-recompute-value?
        (ir.CompilerIrValue.String "s")
        (ast.AstType.String)
        false)
      ;; W3 step (a): integer/bool/char literals at a type whose reload is
      ;; bit-identical to the immediate materialisation.
      (reg.compiler-reg-remat-recompute-value?
        (ir.CompilerIrValue.I64 7)
        (compiler-reg-i64-ty)
        false)
      (reg.compiler-reg-remat-recompute-value?
        (ir.CompilerIrValue.I64 0)
        (ast.AstType.U64)
        false)
      (reg.compiler-reg-remat-recompute-value?
        (ir.CompilerIrValue.I64 -1)
        (compiler-reg-i64-ty)
        false)
      (reg.compiler-reg-remat-recompute-value?
        (ir.CompilerIrValue.Bool false)
        (ast.AstType.Bool)
        false)
      (reg.compiler-reg-remat-recompute-value?
        (ir.CompilerIrValue.Bool true)
        (compiler-reg-i64-ty)
        false)
      (reg.compiler-reg-remat-recompute-value?
        (ir.CompilerIrValue.Char 'x')
        (ast.AstType.Char)
        false)
      ;; NEGATIVE GATE. A narrow var reloads sign/zero-EXTENDED from its slot
      ;; (movslq / movzbq), so an i64 literal homed there is not reproduced by
      ;; `movl $K` and must be refused.
      (not
        (reg.compiler-reg-remat-recompute-value?
          (ir.CompilerIrValue.I64 7)
          (ast.AstType.I32)
          false))
      (not
        (reg.compiler-reg-remat-recompute-value?
          (ir.CompilerIrValue.I64 7)
          (ast.AstType.U8)
          false))
      (not
        (reg.compiler-reg-remat-recompute-value?
          (ir.CompilerIrValue.Char 'x')
          (ast.AstType.U8)
          false))
      ;; NEGATIVE GATE. A literal in a register-GROUP / handle type is refused:
      ;; the backend errors on a rematerialised group var.
      (not
        (reg.compiler-reg-remat-recompute-value?
          (ir.CompilerIrValue.I64 0)
          (ast.AstType.String)
          false))
      ;; NEGATIVE GATE. No scalar backend materialisation for f64, and a LOAD
      ;; of a global cell is not a static value.
      (not
        (reg.compiler-reg-remat-recompute-value?
          (ir.CompilerIrValue.F64 0x3ff0000000000000)
          (compiler-reg-f64-ty)
          false))
      (not
        (reg.compiler-reg-remat-recompute-value?
          (ir.CompilerIrValue.Global (ir.compiler-ir-test-symbol "global"))
          (compiler-reg-i64-ty)
          false))
      (not
        (reg.compiler-reg-remat-recompute-value?
          (ir.CompilerIrValue.Var 0)
          (compiler-reg-i64-ty)
          false)))))

;; End-to-end for the assignment-level rewrite: a SPILLED single-def literal
;; becomes CompilerRegLocation.Remat (so its def store dies and every use
;; recomputes), a MULTI-def one does not, and an address-taken one does not.
(cfg
  test
  (define (compiler-reg-remat-assignment-spill-location
    [func : ir.CompilerIrFunction]
    [vars : i64]
    [var : i64]) : reg.CompilerRegLocation
    (let
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-make vars)]
      [empty-coalesce : reg.CompilerRegCoalesceMap
        (reg.CompilerRegCoalesceMap (__tl_make-array i64 0))]
      (begin
        (reg.compiler-reg-assignment-table-insert
          assignments
          var
          (reg.CompilerRegLocation.Spill 0))
        (let
          [rewritten : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-rewrite-remat-assignments
              assignments
              func
              empty-coalesce
              (live.compiler-live-set-empty)
              false
              vars)]
          (match (reg.compiler-reg-assignment-table-lookup rewritten var)
            [(reg.CompilerRegMaybeLocation.Some location) location]
            [(reg.CompilerRegMaybeLocation.No)
              (reg.CompilerRegLocation.Spill -1)]))))))

(cfg
  test
  (define (compiler-reg-remat-literal-assignment-ok?) : bool
    (and
      ;; NON-VACUITY: var0 is `mov v0 <- 7 : i64`, single-def and spilled, so
      ;; the widened recompute set must turn it into a Remat. Reverting step
      ;; (a) fails here.
      (compiler-reg-location-remat?
        (compiler-reg-remat-assignment-spill-location
          (compiler-reg-remat-weight-function)
          2
          0))
      ;; A multi-def var keeps its slot: recomputing at a use would drop the
      ;; other definition's value.
      (not
        (compiler-reg-location-remat?
          (compiler-reg-remat-assignment-spill-location
            (compiler-reg-remat-multi-def-function)
            1
            0)))
      ;; An address-taken var keeps its slot: a remat has no stable storage.
      (not
        (compiler-reg-location-remat?
          (compiler-reg-remat-assignment-spill-location
            (compiler-reg-remat-addr-taken-literal-function)
            2
            0))))))

(cfg
  test
  (define (compiler-reg-remat-addr-taken-literal-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_addr_taken")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-seq3
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (ir.CompilerIrInstr.AddrOf 1 0)
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-frozen-global-function [load-shape? : bool]) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_frozen_global")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-seq3
            (if load-shape?
              (ir.CompilerIrInstr.Load
                0
                (ir.CompilerIrValue.GlobalAddr
                  (ir.compiler-ir-test-symbol "frozen"))
                (compiler-reg-i64-ty))
              (ir.CompilerIrInstr.Mov
                0
                (ir.CompilerIrValue.Global
                  (ir.compiler-ir-test-symbol "frozen"))
                (compiler-reg-i64-ty)))
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "sink")
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)))
        ir.CompilerIrBlockList.Nil))))

;; W3 step (c). The frozen-global answer is a PROGRAM fact the backend seeds, so
;; the gates are: unseeded (the default) refuses; seeded-and-not-a-cell-writer
;; admits; a global the seeding walk saw written or address-taken refuses; and a
;; narrow var type refuses (the cell read is always a full word, a narrow slot
;; reloads extended). Both spellings of the read -- `mov %v <- Global g` and
;; `load %v, @g` -- must reach the same Remat payload.
(cfg
  test
  (define (compiler-reg-remat-frozen-global-ok?) : bool
    (let
      [frozen : i64
        (ir.compiler-ir-symbol-id (ir.compiler-ir-test-symbol "frozen"))]
      [cell : ir.CompilerIrValue
        (ir.CompilerIrValue.Global (ir.compiler-ir-test-symbol "frozen"))]
      [unseeded? : bool
        (not
          (reg.compiler-reg-remat-recompute-value?
            cell
            (compiler-reg-i64-ty)
            false))]
      (begin
        (reg.compiler-reg-frozen-globals-begin!)
        (reg.compiler-reg-frozen-globals-finish!)
        (let
          [seeded? : bool
            (reg.compiler-reg-remat-recompute-value?
              cell
              (compiler-reg-i64-ty)
              false)]
          [narrow-refused? : bool
            (not
              (reg.compiler-reg-remat-recompute-value?
                cell
                (ast.AstType.I32)
                false))]
          [mov-remat? : bool
            (compiler-reg-location-remat?
              (compiler-reg-remat-assignment-spill-location
                (compiler-reg-remat-frozen-global-function false)
                1
                0))]
          [load-remat? : bool
            (compiler-reg-location-remat?
              (compiler-reg-remat-assignment-spill-location
                (compiler-reg-remat-frozen-global-function true)
                1
                0))]
          (begin
            (reg.compiler-reg-add-nonfrozen-global! frozen)
            (let
              [written-refused? : bool
                (not
                  (reg.compiler-reg-remat-recompute-value?
                    cell
                    (compiler-reg-i64-ty)
                    false))]
              [written-load-refused? : bool
                (not
                  (compiler-reg-location-remat?
                    (compiler-reg-remat-assignment-spill-location
                      (compiler-reg-remat-frozen-global-function true)
                      1
                      0)))]
              (begin
                ;; Leave the process-wide fact as the allocator's default so no
                ;; later fixture inherits a seeded answer.
                (reg.compiler-reg-frozen-globals-begin!)
                (and
                  unseeded?
                  seeded?
                  narrow-refused?
                  mov-remat?
                  load-remat?
                  written-refused?
                  written-load-refused?)))))))))

(cfg
  test
  (define (compiler-reg-remat-discount-weights-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-weight-function)]
      [empty-coalesce : reg.CompilerRegCoalesceMap
        (reg.CompilerRegCoalesceMap (__tl_make-array i64 0))]
      [raw : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights func)]
      [discounted : (__tl_dyn-array i64)
        (compiler-reg-function-spill-weights-remat func empty-coalesce)]
      [multi-raw : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights
          (compiler-reg-remat-multi-def-function))]
      [multi-discounted : (__tl_dyn-array i64)
        (compiler-reg-function-spill-weights-remat
          (compiler-reg-remat-multi-def-function)
          empty-coalesce)]
      [parents : (__tl_dyn-array i64) (__tl_make-array i64 2)]
      (begin
        (set! (array-ref parents 0) 0)
        (set! (array-ref parents 1) 0)
        (let
          [coalesced : (__tl_dyn-array i64)
            (compiler-reg-function-spill-weights-remat
              func
              (reg.CompilerRegCoalesceMap parents))]
          (and
            (= (array-ref raw 0) 3)
            (= (array-ref raw 1) 2)
            (= (array-ref discounted 0) 1)
            (= (array-ref discounted 1) 2)
            (= (array-ref coalesced 0) 3)
            (= (array-ref coalesced 1) 2)
            (= (array-ref multi-raw 0) 2)
            (= (array-ref multi-discounted 0) 2)))))))

(cfg
  test
  (define (compiler-reg-remat-spill-weight-eviction-function) : ir.CompilerIrFunction
    (let
      [instrs : ir.CompilerIrInstrSeq (ir.compiler-ir-instr-seq-empty)]
      (begin
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "hot0b")
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "hot0a")
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "cold1")
              (ir.CompilerIrValue.Var 1)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use5")
              (ir.CompilerIrValue.Var 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use4")
              (ir.CompilerIrValue.Var 4)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use3")
              (ir.CompilerIrValue.Var 3)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use2")
              (ir.CompilerIrValue.Var 2)
              (compiler-reg-i64-ty))
            instrs))
        ;; #perf: syscall after the uses so every value crosses it (call-spanning)
        ;; -- the partition gates off and the 6 candidates oversubscribe the 5
        ;; callee-saved registers. var1 is the only non-remat value, so the remat
        ;; discount keeps it in a register and a rematerialisable value is the
        ;; victim; among the remat values the cheapest (1-use var5, one recompute)
        ;; is spilled rather than the 2-use var0 (two recomputes).
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Syscall
              6
              (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.I64 39)))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              5
              (ir.CompilerIrValue.I64 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              4
              (ir.CompilerIrValue.I64 4)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              3
              (ir.CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              2
              (ir.CompilerIrValue.I64 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              1
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.I64 1)
              (ir.CompilerIrValue.I64 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 0)
              (compiler-reg-i64-ty))
            instrs))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "remat_spill_weight_eviction")
          ir.CompilerIrParamList.Nil
          (ast.AstType.Unit)
          7
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block (ir.compiler-ir-label "entry") instrs)
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-remat-spill-weight-eviction-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-remat-spill-weight-eviction-function)]
      [empty-coalesce : reg.CompilerRegCoalesceMap
        (reg.CompilerRegCoalesceMap (__tl_make-array i64 0))]
      [raw : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights func)]
      [discounted : (__tl_dyn-array i64)
        (compiler-reg-function-spill-weights-remat func empty-coalesce)]
      (match (reg.compiler-reg-plan-function-scalar func)
        [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
          (and
            (> (array-ref raw 0) (array-ref raw 1))
            (< (array-ref discounted 0) (array-ref discounted 1))
            ;; The non-remat var1 is KEPT in a register: the remat discount ranks
            ;; the rematerialisable values (var0, var2-5) below it, so a remat
            ;; value -- never the costly-to-spill non-remat one -- is the victim.
            (compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 1))
            ;; Among the remat values the GREEDY spills the genuinely cheapest:
            ;; var0 has 2 uses (spilling it costs 2 recomputes) while var5 has 1
            ;; use (1 recompute), so var0 is KEPT and the 1-use var5 is the victim.
            ;; The combined discounted+raw priority key breaks the discount's
            ;; use-count collapse by raw use density, spilling the least-used
            ;; rematerialisable value rather than the most-used one.
            (compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 0))
            ;; W3 step (a): var5's def is an i64 literal, so the victim keeps no
            ;; frame slot at all -- it is rematerialised at its one use (was: a
            ;; Spill at stack slot 5).
            (compiler-reg-maybe-location-remat?
              (reg.compiler-reg-assignment-lookup assignments 5)))]))))

(cfg
  test
  (define (compiler-reg-spill-weight-eviction-function) : ir.CompilerIrFunction
    ;; #perf: every value crosses the syscall (call-spanning), so the call-
    ;; spanning-aware partition is gated off and the 6 candidates genuinely
    ;; oversubscribe the 5 callee-saved registers. var0 is hot (3 uses), vars 2-5
    ;; are medium (2 uses), var1 is the unique coldest (1 use) and is the
    ;; spill-weight eviction victim.
    (let
      [instrs : ir.CompilerIrInstrSeq (ir.compiler-ir-instr-seq-empty)]
      (begin
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "hot0c")
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "hot0b")
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "hot0a")
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "cold1")
              (ir.CompilerIrValue.Var 1)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use5b")
              (ir.CompilerIrValue.Var 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use5a")
              (ir.CompilerIrValue.Var 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use4b")
              (ir.CompilerIrValue.Var 4)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use4a")
              (ir.CompilerIrValue.Var 4)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use3b")
              (ir.CompilerIrValue.Var 3)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use3a")
              (ir.CompilerIrValue.Var 3)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use2b")
              (ir.CompilerIrValue.Var 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use2a")
              (ir.CompilerIrValue.Var 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Syscall
              6
              (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.I64 39)))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              5
              (ir.CompilerIrValue.I64 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              4
              (ir.CompilerIrValue.I64 4)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              3
              (ir.CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              2
              (ir.CompilerIrValue.I64 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 1)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 0)
              (compiler-reg-i64-ty))
            instrs))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "spill_weight_eviction")
          ir.CompilerIrParamList.Nil
          (ast.AstType.Unit)
          7
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block (ir.compiler-ir-label "entry") instrs)
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-spill-weight-eviction-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar
      (compiler-reg-spill-weight-eviction-function))
      [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
        (and
          (compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 0))
          ;; W3 step (a): the victim's def is an i64 literal, so it leaves no
          ;; frame slot behind (was: a Spill at stack slot 1).
          (compiler-reg-maybe-location-remat?
            (reg.compiler-reg-assignment-lookup assignments 1))
          (compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 5)))])))

(cfg
  test
  (define (compiler-reg-loop-spill-weight-eviction-function) : ir.CompilerIrFunction
    ;; #perf: all six values cross the entry syscall (call-spanning) so the
    ;; partition gates off. var0 and vars 2-5 are used inside the loop (loop-depth
    ;; weighted) while var1 is the single cold exit value -- the unique
    ;; spill-weight eviction victim despite var0/var1 sharing one static use each.
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_spill_weight_eviction")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      7
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  2
                  (ir.CompilerIrValue.I64 2)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    3
                    (ir.CompilerIrValue.I64 3)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Mov
                      4
                      (ir.CompilerIrValue.I64 4)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Mov
                        5
                        (ir.CompilerIrValue.I64 5)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Syscall
                          6
                          (ir.CompilerIrCallArgs.One
                            (ir.CompilerIrValue.I64 39)))
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.Jump
                            (ir.compiler-ir-label "loop"))
                          (ir.compiler-ir-instr-seq-empty))))))))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "loop")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "hot0")
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot2")
                  (ir.CompilerIrValue.Var 2)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot3")
                    (ir.CompilerIrValue.Var 3)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "hot4")
                      (ir.CompilerIrValue.Var 4)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Store
                        (ir.compiler-ir-test-symbol "hot5")
                        (ir.CompilerIrValue.Var 5)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Branch
                          (ir.CompilerIrValue.Bool false)
                          (ir.compiler-ir-label "body")
                          (ir.compiler-ir-label "exit"))
                        (ir.compiler-ir-instr-seq-empty))))))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "cold1")
                    (ir.CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                    (ir.compiler-ir-instr-seq-empty))))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-spill-weight-eviction-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-loop-spill-weight-eviction-function)]
      [static-counts : (__tl_dyn-array i64)
        (compiler-reg-function-ref-counts func)]
      [weighted-counts : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights func)]
      (match (reg.compiler-reg-plan-function-scalar func)
        [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
          (and
            (= (array-ref static-counts 0) (array-ref static-counts 1))
            (> (array-ref weighted-counts 0) (array-ref weighted-counts 1))
            (compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 0))
            ;; W3 step (a): the victim's def is an i64 literal (was: a Spill at
            ;; stack slot 1).
            (compiler-reg-maybe-location-remat?
              (reg.compiler-reg-assignment-lookup assignments 1))
            (compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 5)))]))))

;; ---------------------------------------------------------------------------
;; Memory-operand foldability rebate (compiler-reg-function-foldable-rebates).
;;
;; The fixture below is a three-level loop nest under call-spanning pressure.
;; The counter (var 0) is read and written once per trip of the OUTER loop
;; (ladder depth 1, weight 2 per mention); the five candidates (vars 1-5) are
;; each mentioned exactly ONCE, in the innermost block (ladder depth 3, weight
;; 8). The raw ladder therefore ranks every candidate above the counter and
;; makes the counter the eviction victim -- the inversion this rebate exists to
;; fix.
;;
;; `fold?` selects the position of that single mention:
;;   true  -> the candidate is the bounds check's LENGTH, which the backend
;;            spells straight out of the home slot (`cmpq $0, LEN(%rsp)`), so
;;            the spilled form costs no instruction and the rebate applies;
;;   false -> the candidate is the bounds check's INDEX, which both arms of
;;            compiler-backend-emit-bounds-check load into a register, so the
;;            mention is a genuine reload and must NOT be rebated.
(cfg
  test
  (define (compiler-reg-foldable-rebate-checks
    [var : i64]
    [fold? : bool]
    [tail : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
    (if (< var 1)
      tail
      (compiler-reg-foldable-rebate-checks
        (- var 1)
        fold?
        (compiler-reg-test-instr-seq-prepend
          (if fold?
            (ir.CompilerIrInstr.BoundsCheck
              (ir.CompilerIrValue.I64 0)
              (ir.CompilerIrValue.Var var)
              (ir.compiler-ir-label "ok"))
            (ir.CompilerIrInstr.BoundsCheck
              (ir.CompilerIrValue.Var var)
              (ir.CompilerIrValue.I64 64)
              (ir.compiler-ir-label "ok")))
          tail)))))

;; Each candidate gets TWO definitions. A single-def Mov of a constant is a
;; remat candidate and would have its weight halved by
;; compiler-reg-remat-discount-single-def-spill-weights!, which would confound
;; the comparison: the test must measure the foldability rebate and nothing
;; else. The counter is already multi-def (its Mov plus the loop's BinOp).
(cfg
  test
  (define (compiler-reg-foldable-rebate-defs
    [var : i64]
    [tail : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
    (if (< var 0)
      tail
      (compiler-reg-foldable-rebate-defs
        (- var 1)
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            var
            (ir.CompilerIrValue.I64 (+ var 1))
            (compiler-reg-i64-ty))
          (if (< var 1)
            tail
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                var
                (ir.CompilerIrValue.I64 (+ var 100))
                (compiler-reg-i64-ty))
              tail)))))))

(cfg
  test
  (define (compiler-reg-foldable-rebate-function [fold? : bool]) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "foldable_rebate_pressure")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      7
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-foldable-rebate-defs
            5
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Syscall
                6
                (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.I64 39)))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "l1"))
                (ir.compiler-ir-instr-seq-empty)))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "l1")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                0
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.I64 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Branch
                  (ir.CompilerIrValue.Bool false)
                  (ir.compiler-ir-label "l2")
                  (ir.compiler-ir-label "exit"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "l2")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Branch
                  (ir.CompilerIrValue.Bool false)
                  (ir.compiler-ir-label "l3")
                  (ir.compiler-ir-label "l1latch"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "l3")
                (compiler-reg-foldable-rebate-checks
                  5
                  fold?
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Branch
                      (ir.CompilerIrValue.Bool false)
                      (ir.compiler-ir-label "l3latch")
                      (ir.compiler-ir-label "l2latch"))
                    (ir.compiler-ir-instr-seq-empty))))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "l3latch")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "l3"))
                    (ir.compiler-ir-instr-seq-empty)))
                (ir.compiler-ir-block-cons
                  (ir.CompilerIrBlock.Block
                    (ir.compiler-ir-label "l2latch")
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "l2"))
                      (ir.compiler-ir-instr-seq-empty)))
                  (ir.compiler-ir-block-cons
                    (ir.CompilerIrBlock.Block
                      (ir.compiler-ir-label "l1latch")
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "l1"))
                        (ir.compiler-ir-instr-seq-empty)))
                    (ir.compiler-ir-block-cons
                      (ir.CompilerIrBlock.Block
                        (ir.compiler-ir-label "exit")
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                          (ir.compiler-ir-instr-seq-empty)))
                      ir.CompilerIrBlockList.Nil)))))))))))

(cfg
  test
  (define (compiler-reg-foldable-rebate-array [func : ir.CompilerIrFunction]) : (__tl_dyn-array
      i64)
    (match func
      [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
        (reg.compiler-reg-function-foldable-rebates
          blocks
          (reg.compiler-reg-function-loop-depths blocks)
          vars)])))

(cfg
  test
  (define (compiler-reg-foldable-rebate-combined [func : ir.CompilerIrFunction]) : (__tl_dyn-array
      i64)
    (match func
      [(ir.CompilerIrFunction.Function _ _ _ vars _)
        (reg.compiler-reg-function-spill-weights-combined
          func
          (reg.CompilerRegCoalesceMap (__tl_make-array i64 0))
          vars)])))

(cfg
  test
  (define (compiler-reg-foldable-rebate-any-spilled?
    [assignments : reg.CompilerRegAssignmentTable]
    [var : i64]) : bool
    (if (< var 1)
      false
      (if (compiler-reg-location-spill-offset?
        (reg.compiler-reg-assignment-lookup assignments var)
        (reg.compiler-reg-stack-slot-offset var))
        true
        (compiler-reg-foldable-rebate-any-spilled? assignments (- var 1))))))

;; (c) Classification against the backend's fold table: only the LENGTH operand
;; of a bounds check is credited, and it is credited exactly the difference
;; between the block's ladder weight (depth 3 -> 8) and the flat foldable rate
;; (1). Constant operands are never credited (they were never scored), and the
;; counter, whose mentions are a BinOp def and use, is never credited.
(cfg
  test
  (define (compiler-reg-foldable-rebate-classification-ok?) : bool
    (let
      [fold-rebates : (__tl_dyn-array i64)
        (compiler-reg-foldable-rebate-array
          (compiler-reg-foldable-rebate-function true))]
      [index-rebates : (__tl_dyn-array i64)
        (compiler-reg-foldable-rebate-array
          (compiler-reg-foldable-rebate-function false))]
      [raw : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights
          (compiler-reg-foldable-rebate-function true))]
      [combined : (__tl_dyn-array i64)
        (compiler-reg-foldable-rebate-combined
          (compiler-reg-foldable-rebate-function true))]
      [index-combined : (__tl_dyn-array i64)
        (compiler-reg-foldable-rebate-combined
          (compiler-reg-foldable-rebate-function false))]
      (and
        ;; The ladder ranks a single depth-3 foldable mention above the
        ;; counter's per-trip def+use at depth 1.
        (= (array-ref raw 0) 5)
        (= (array-ref raw 1) 10)
        (= (array-ref raw 5) 10)
        ;; Only the length position is credited, and only by weight - 1.
        (= (array-ref fold-rebates 0) 0)
        (= (array-ref fold-rebates 1) 7)
        (= (array-ref fold-rebates 5) 7)
        (= (array-ref fold-rebates 6) 0)
        ;; The index position is a genuine reload: nothing is credited.
        (= (array-ref index-rebates 0) 0)
        (= (array-ref index-rebates 1) 0)
        (= (array-ref index-rebates 5) 0)
        ;; ... and the rebate flips the greedy's priority order, while the
        ;; index fixture keeps the raw order exactly.
        (> (array-ref combined 0) (array-ref combined 1))
        (> (array-ref combined 0) (array-ref combined 5))
        (< (array-ref index-combined 0) (array-ref index-combined 1))
        (< (array-ref index-combined 0) (array-ref index-combined 5))))))

;; (a) The forcing fixture: under call-spanning pressure exactly one of the six
;; values must give up its register. With the fold-only candidates repriced the
;; counter keeps one and a candidate spills.
(cfg
  test
  (define (compiler-reg-foldable-rebate-keeps-counter-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-foldable-rebate-function true)]
      (match (reg.compiler-reg-plan-function-scalar func)
        [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
          (and
            (compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 0))
            (compiler-reg-foldable-rebate-any-spilled? assignments 5))]))))

;; (b) The negative: the same shape with the candidates in the non-foldable
;; INDEX position is left exactly as the ladder priced it -- the hot-by-depth
;; candidates keep the registers and the counter is the victim. A rebate that
;; leaked into non-foldable positions would flip this too.
(cfg
  test
  (define (compiler-reg-foldable-rebate-index-not-discounted-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-foldable-rebate-function false)]
      (match (reg.compiler-reg-plan-function-scalar func)
        [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
          (and
            (compiler-reg-location-spill-offset?
              (reg.compiler-reg-assignment-lookup assignments 0)
              (reg.compiler-reg-stack-slot-offset 0))
            (compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 1))
            (compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 5)))]))))

(cfg
  test
  (define (compiler-reg-foldable-rebate-arrays-equal?
    [left : (__tl_dyn-array i64)]
    [right : (__tl_dyn-array i64)]
    [index : i64]) : bool
    (if (< index 0)
      true
      (if (= (array-ref left index) (array-ref right index))
        (compiler-reg-foldable-rebate-arrays-equal? left right (- index 1))
        false))))

;; (d) Idempotence: the rebate is a pure function of the IR, so recomputing the
;; weights (and replanning) yields identical results -- the walk must not
;; accumulate into, or otherwise mutate, anything the next call reads.
(cfg
  test
  (define (compiler-reg-foldable-rebate-idempotent-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-foldable-rebate-function true)]
      [first-rebates : (__tl_dyn-array i64)
        (compiler-reg-foldable-rebate-array func)]
      [second-rebates : (__tl_dyn-array i64)
        (compiler-reg-foldable-rebate-array func)]
      [first-combined : (__tl_dyn-array i64)
        (compiler-reg-foldable-rebate-combined func)]
      [second-combined : (__tl_dyn-array i64)
        (compiler-reg-foldable-rebate-combined func)]
      (and
        (compiler-reg-foldable-rebate-arrays-equal?
          first-rebates
          second-rebates
          6)
        (compiler-reg-foldable-rebate-arrays-equal?
          first-combined
          second-combined
          6)))))

;; Dense instruction queries used by rewrite assertions. The old fixtures
;; recursively unpacked compatibility cons lists; the query loop now reads the
;; same instruction storage consumed by regalloc.
(cfg
  test
  (defenum CompilerRegTestInstrQuery
    (MovI64 i64 i64)
    (MovVar i64 i64)
    (MovGlobal i64 String)
    (LoadGlobalAddr i64 String)
    (GepGlobalI64 i64 String i64 ast.AstType)
    (StoreVar String i64)
    (AddrOf i64 i64)
    (CallIndirectVar i64)
    (ReturnVar i64)))

(cfg
  test
  (define (compiler-reg-test-instr-matches-query?
    [instr : ir.CompilerIrInstr]
    [query : CompilerRegTestInstrQuery]) : bool
    (match query
      [(CompilerRegTestInstrQuery.MovI64 dst value)
        (match instr
          [(ir.CompilerIrInstr.Mov found-dst found-value _)
            (match found-value
              [(ir.CompilerIrValue.I64 found)
                (and (= found-dst dst) (= found value))]
              [_ false])]
          [_ false])]
      [(CompilerRegTestInstrQuery.MovVar dst src)
        (match instr
          [(ir.CompilerIrInstr.Mov found-dst found-value _)
            (match found-value
              [(ir.CompilerIrValue.Var found-src)
                (and (= found-dst dst) (= found-src src))]
              [_ false])]
          [_ false])]
      [(CompilerRegTestInstrQuery.MovGlobal dst name)
        (match instr
          [(ir.CompilerIrInstr.Mov found-dst found-value _)
            (match found-value
              [(ir.CompilerIrValue.Global found-name)
                (and
                  (= found-dst dst)
                  (string.eq (ir.compiler-ir-symbol-text found-name) name))]
              [_ false])]
          [_ false])]
      [(CompilerRegTestInstrQuery.LoadGlobalAddr dst name)
        (match instr
          [(ir.CompilerIrInstr.Load found-dst found-src _)
            (match found-src
              [(ir.CompilerIrValue.GlobalAddr found-name)
                (and
                  (= found-dst dst)
                  (string.eq (ir.compiler-ir-symbol-text found-name) name))]
              [_ false])]
          [_ false])]
      [(CompilerRegTestInstrQuery.GepGlobalI64 dst name offset ty)
        (match instr
          [(ir.CompilerIrInstr.Gep found-dst found-base found-offset found-ty)
            (match found-base
              [(ir.CompilerIrValue.GlobalAddr found-name)
                (match found-offset
                  [(ir.CompilerIrValue.I64 found-offset-value)
                    (and
                      (= found-dst dst)
                      (and
                        (string.eq (ir.compiler-ir-symbol-text found-name) name)
                        (and
                          (= found-offset-value offset)
                          (ast.ast-type-eq? found-ty ty))))]
                  [_ false])]
              [_ false])]
          [_ false])]
      [(CompilerRegTestInstrQuery.StoreVar name src)
        (match instr
          [(ir.CompilerIrInstr.Store found-name found-value _)
            (match found-value
              [(ir.CompilerIrValue.Var found-src)
                (and
                  (string.eq (ir.compiler-ir-symbol-text found-name) name)
                  (= found-src src))]
              [_ false])]
          [_ false])]
      [(CompilerRegTestInstrQuery.AddrOf dst src)
        (match instr
          [(ir.CompilerIrInstr.AddrOf found-dst found-src)
            (and (= found-dst dst) (= found-src src))]
          [_ false])]
      [(CompilerRegTestInstrQuery.CallIndirectVar callee)
        (match instr
          [(ir.CompilerIrInstr.CallIndirect _ found-callee _ _)
            (match found-callee
              [(ir.CompilerIrValue.Var found) (= found callee)]
              [_ false])]
          [_ false])]
      [(CompilerRegTestInstrQuery.ReturnVar src)
        (match instr
          [(ir.CompilerIrInstr.Return maybe)
            (match maybe
              [(ir.CompilerIrMaybeValue.Some value)
                (match value
                  [(ir.CompilerIrValue.Var found) (= found src)]
                  [_ false])]
              [_ false])]
          [_ false])])))

(cfg
  test
  (define (compiler-reg-instr-seq-has-query?
    [instrs : ir.CompilerIrInstrSeq]
    [query : CompilerRegTestInstrQuery]) : bool
    (let
      [index : i64 0]
      [found : bool false]
      (begin
        (while (and (< index instrs.len) (not found))
          (begin
            (if (compiler-reg-test-instr-matches-query?
              (ir.compiler-ir-instr-seq-ref instrs index)
              query)
              (set! found true)
              unit)
            (set! index (+ index 1))))
        found))))

(cfg
  test
  (define (compiler-reg-instr-seq-has-mov-i64?
    [instrs : ir.CompilerIrInstrSeq]
    [dst : i64]
    [value : i64]) : bool
    (compiler-reg-instr-seq-has-query?
      instrs
      (CompilerRegTestInstrQuery.MovI64 dst value))))

(cfg
  test
  (define (compiler-reg-instr-seq-has-mov-var?
    [instrs : ir.CompilerIrInstrSeq]
    [dst : i64]
    [src : i64]) : bool
    (compiler-reg-instr-seq-has-query?
      instrs
      (CompilerRegTestInstrQuery.MovVar dst src))))

(cfg
  test
  (define (compiler-reg-instr-seq-has-mov-global?
    [instrs : ir.CompilerIrInstrSeq]
    [dst : i64]
    [name : String]) : bool
    (compiler-reg-instr-seq-has-query?
      instrs
      (CompilerRegTestInstrQuery.MovGlobal dst name))))

(cfg
  test
  (define (compiler-reg-instr-seq-has-load-global-addr?
    [instrs : ir.CompilerIrInstrSeq]
    [dst : i64]
    [name : String]) : bool
    (compiler-reg-instr-seq-has-query?
      instrs
      (CompilerRegTestInstrQuery.LoadGlobalAddr dst name))))

(cfg
  test
  (define (compiler-reg-instr-seq-has-gep-global-i64?
    [instrs : ir.CompilerIrInstrSeq]
    [dst : i64]
    [name : String]
    [offset : i64]
    [ty : ast.AstType]) : bool
    (compiler-reg-instr-seq-has-query?
      instrs
      (CompilerRegTestInstrQuery.GepGlobalI64 dst name offset ty))))

(cfg
  test
  (define (compiler-reg-instr-seq-has-store-var?
    [instrs : ir.CompilerIrInstrSeq]
    [name : String]
    [src : i64]) : bool
    (compiler-reg-instr-seq-has-query?
      instrs
      (CompilerRegTestInstrQuery.StoreVar name src))))

(cfg
  test
  (define (compiler-reg-instr-seq-has-addr-of?
    [instrs : ir.CompilerIrInstrSeq]
    [dst : i64]
    [src : i64]) : bool
    (compiler-reg-instr-seq-has-query?
      instrs
      (CompilerRegTestInstrQuery.AddrOf dst src))))

(cfg
  test
  (define (compiler-reg-instr-seq-has-call-indirect-var?
    [instrs : ir.CompilerIrInstrSeq]
    [callee : i64]) : bool
    (compiler-reg-instr-seq-has-query?
      instrs
      (CompilerRegTestInstrQuery.CallIndirectVar callee))))

(cfg
  test
  (define (compiler-reg-instr-seq-has-return-var?
    [instrs : ir.CompilerIrInstrSeq]
    [src : i64]) : bool
    (compiler-reg-instr-seq-has-query?
      instrs
      (CompilerRegTestInstrQuery.ReturnVar src))))

(cfg
  test
  (define (compiler-reg-block-instr-seq
    [blocks : ir.CompilerIrBlockList]
    [want-label : i64]) : ir.CompilerIrInstrSeq
    (match blocks
      [(ir.CompilerIrBlockList.Cons block rest)
        (match block
          [(ir.CompilerIrBlock.Block label instrs)
            (if (= label want-label)
              instrs
              (compiler-reg-block-instr-seq (__tl-box-place rest) want-label))])]
      [(ir.CompilerIrBlockList.Array seq)
        (let
          [index : i64 0]
          [out : ir.CompilerIrInstrSeq (ir.compiler-ir-instr-seq-empty)]
          [found : bool false]
          (begin
            (while (and (< index seq.len) (not found))
              (begin
                (match (ir.compiler-ir-block-seq-ref seq index)
                  [(ir.CompilerIrBlock.Block label instrs)
                    (if (= label want-label)
                      (begin
                        (set! out instrs)
                        (set! found true))
                      unit)])
                (set! index (+ index 1))))
            out))]
      [(ir.CompilerIrBlockList.Nil) (ir.compiler-ir-instr-seq-empty)])))

(cfg
  test
  (define (compiler-reg-remat-rewrite-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_rewrite")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "use0a")
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "use0b")
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  (ir.compiler-ir-instr-seq-empty))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-conflict-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_conflict")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 9)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "use0")
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "keep1")
                    (ir.CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                    (ir.compiler-ir-instr-seq-empty)))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-caller-clobber-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_caller_clobber")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.GlobalAddr
                (ir.compiler-ir-test-symbol "callee"))
              (ast.AstType.U64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.CallIndirect
                1
                (ir.CompilerIrValue.Var 0)
                ir.CompilerIrCallArgs.Nil
                (ast.AstType.Unit))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                (ir.compiler-ir-instr-seq-empty)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-addr-of-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_addr_of")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.AddrOf 1 0)
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "addr")
                  (ir.CompilerIrValue.Var 1)
                  (reg.compiler-reg-addr-of-result-type))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  (ir.compiler-ir-instr-seq-empty))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-mov-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_global_mov")
      ir.CompilerIrParamList.Nil
      (compiler-reg-i64-ty)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.Global
                (ir.compiler-ir-test-symbol "global_value"))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              (ir.compiler-ir-instr-seq-empty))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-load-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_global_load")
      ir.CompilerIrParamList.Nil
      (compiler-reg-i64-ty)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Load
              0
              (ir.CompilerIrValue.GlobalAddr
                (ir.compiler-ir-test-symbol "global_value"))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              (ir.compiler-ir-instr-seq-empty))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-gep-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_global_gep")
      ir.CompilerIrParamList.Nil
      (reg.compiler-reg-addr-of-result-type)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Gep
              0
              (ir.CompilerIrValue.GlobalAddr
                (ir.compiler-ir-test-symbol "global_value"))
              (ir.CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              (ir.compiler-ir-instr-seq-empty))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-mutating-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_global_mutating")
      ir.CompilerIrParamList.Nil
      (compiler-reg-i64-ty)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.Global
                (ir.compiler-ir-test-symbol "global_value"))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "global_value")
                (ir.CompilerIrValue.I64 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                (ir.compiler-ir-instr-seq-empty)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-single-spill-plan [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
    (reg.CompilerRegPlan.Plan
      (reg.compiler-reg-assignments-prepend
        (reg.CompilerRegAssignment
          0
          (reg.CompilerRegLocation.Spill (reg.compiler-reg-stack-slot-offset 0)))
        (reg.compiler-reg-assignment-table-empty))
      (live.compiler-live-set-empty)
      (reg.compiler-reg-interval-seq-empty)
      (reg.compiler-reg-function-var-types func)
      (reg.compiler-reg-call-split-empty)
      (reg.compiler-reg-split-plan-empty))))

(cfg
  test
  (define (compiler-reg-remat-conflict-plan [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
    (reg.CompilerRegPlan.Plan
      (reg.compiler-reg-assignments-prepend
        (reg.CompilerRegAssignment
          0
          (reg.CompilerRegLocation.Spill (reg.compiler-reg-stack-slot-offset 0)))
        (reg.compiler-reg-assignments-prepend
          (reg.CompilerRegAssignment
            1
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r9))
          (reg.compiler-reg-assignment-table-empty)))
      (live.compiler-live-set-empty)
      (reg.compiler-reg-interval-seq-empty)
      (reg.compiler-reg-function-var-types func)
      (reg.compiler-reg-call-split-empty)
      (reg.compiler-reg-split-plan-empty))))

(cfg
  test
  (define (compiler-reg-remat-rewrite-shape-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-rewrite-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                extra-types)
              (let
                [items : ir.CompilerIrInstrSeq
                  (compiler-reg-block-instr-seq
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                [rewritten-plan : reg.CompilerRegPlan
                  (reg.compiler-reg-plan-with-call-save-rewrite
                    plan
                    (reg.CompilerRegCallSaveRewrite.Rewrite
                      rewritten
                      vars
                      out-vars
                      extra-assignments
                      extra-types))]
                [rewritten-assignments : reg.CompilerRegAssignmentTable
                  (reg.compiler-reg-plan-assignments rewritten-plan)]
                [rewritten-types : reg.CompilerRegVarTypes
                  (reg.compiler-reg-plan-types rewritten-plan)]
                (and
                  (= out-vars (+ vars 2))
                  (= (reg.compiler-reg-assignment-count extra-assignments) 2)
                  (reg.compiler-reg-location-register?
                    (reg.compiler-reg-assignment-lookup
                      rewritten-assignments
                      vars)
                    cabi.compiler-reg-id-r9)
                  (reg.compiler-reg-location-register?
                    (reg.compiler-reg-assignment-lookup
                      rewritten-assignments
                      (+ vars 1))
                    cabi.compiler-reg-id-r9)
                  (compiler-reg-instr-seq-has-mov-i64? items vars 7)
                  (compiler-reg-instr-seq-has-mov-i64? items (+ vars 1) 7)
                  (compiler-reg-instr-seq-has-store-var? items "use0a" vars)
                  (compiler-reg-instr-seq-has-store-var?
                    items
                    "use0b"
                    (+ vars 1))
                  (match (reg.compiler-reg-var-types-lookup
                    rewritten-types
                    vars)
                    [(reg.CompilerRegMaybeType.Some ty)
                      (match ty
                        [(ast.AstType.I64) true]
                        [_ false])]
                    [(reg.CompilerRegMaybeType.No) false])
                  (match (reg.compiler-reg-var-types-lookup
                    rewritten-types
                    (+ vars 1))
                    [(reg.CompilerRegMaybeType.Some ty)
                      (match ty
                        [(ast.AstType.I64) true]
                        [_ false])]
                    [(reg.CompilerRegMaybeType.No) false])
                  (not (compiler-reg-instr-seq-has-store-var? items "use0a" 0))
                  (not (compiler-reg-instr-seq-has-store-var? items "use0b" 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-register-conflict-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-conflict-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-conflict-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrSeq
                  (compiler-reg-block-instr-seq
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (reg.compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-seq-has-store-var? items "use0" 0)))])]))))

(cfg
  test
  (define (compiler-reg-remat-caller-clobber-refusal-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-remat-caller-clobber-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrSeq
                  (compiler-reg-block-instr-seq
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (reg.compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-seq-has-call-indirect-var? items 0)))])]))))

(cfg
  test
  (define (compiler-reg-remat-addr-of-source-refusal-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-addr-of-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrSeq
                  (compiler-reg-block-instr-seq
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (reg.compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-seq-has-addr-of? items 1 0)
                  (not (compiler-reg-instr-seq-has-addr-of? items 1 vars))))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-mov-rewrite-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-global-mov-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrSeq
                  (compiler-reg-block-instr-seq
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars (+ vars 1))
                  (= (reg.compiler-reg-assignment-count extra-assignments) 1)
                  (compiler-reg-instr-seq-has-mov-global?
                    items
                    vars
                    "global_value")
                  (compiler-reg-instr-seq-has-return-var? items vars)
                  (not (compiler-reg-instr-seq-has-return-var? items 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-load-rewrite-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-global-load-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrSeq
                  (compiler-reg-block-instr-seq
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars (+ vars 1))
                  (= (reg.compiler-reg-assignment-count extra-assignments) 1)
                  (compiler-reg-instr-seq-has-load-global-addr?
                    items
                    vars
                    "global_value")
                  (compiler-reg-instr-seq-has-return-var? items vars)
                  (not (compiler-reg-instr-seq-has-return-var? items 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-gep-rewrite-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-global-gep-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrSeq
                  (compiler-reg-block-instr-seq
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars (+ vars 1))
                  (= (reg.compiler-reg-assignment-count extra-assignments) 1)
                  (compiler-reg-instr-seq-has-gep-global-i64?
                    items
                    vars
                    "global_value"
                    3
                    (compiler-reg-i64-ty))
                  (compiler-reg-instr-seq-has-return-var? items vars)
                  (not (compiler-reg-instr-seq-has-return-var? items 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-mutation-refusal-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-remat-global-mutating-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrSeq
                  (compiler-reg-block-instr-seq
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (reg.compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-seq-has-return-var? items 0)
                  (not
                    (compiler-reg-instr-seq-has-mov-global?
                      items
                      vars
                      "global_value"))))])]))))

(cfg
  test
  (define (compiler-reg-call-spanning-post-call-stores
    [tail : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
    (compiler-reg-test-instr-seq-prepend
      (ir.CompilerIrInstr.Store
        (ir.compiler-ir-test-symbol "g0")
        (ir.CompilerIrValue.Var 0)
        (compiler-reg-i64-ty))
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.Store
          (ir.compiler-ir-test-symbol "g1")
          (ir.CompilerIrValue.Var 1)
          (compiler-reg-i64-ty))
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g2")
            (ir.CompilerIrValue.Var 2)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g3")
              (ir.CompilerIrValue.Var 3)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "g4")
                (ir.CompilerIrValue.Var 4)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "g5")
                  (ir.CompilerIrValue.Var 5)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "g6")
                    (ir.CompilerIrValue.Var 6)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "g5b")
                      (ir.CompilerIrValue.Var 5)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Store
                        (ir.compiler-ir-test-symbol "g5c")
                        (ir.CompilerIrValue.Var 5)
                        (compiler-reg-i64-ty))
                      tail)))))))))))

(cfg
  test
  (define (compiler-reg-call-spanning-defs-before
    [tail : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
    (compiler-reg-test-instr-seq-prepend
      (ir.CompilerIrInstr.Mov
        0
        (ir.CompilerIrValue.I64 0)
        (compiler-reg-i64-ty))
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.Mov
          1
          (ir.CompilerIrValue.I64 1)
          (compiler-reg-i64-ty))
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            2
            (ir.CompilerIrValue.I64 2)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              3
              (ir.CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                4
                (ir.CompilerIrValue.I64 4)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  5
                  (ir.CompilerIrValue.I64 5)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    6
                    (ir.CompilerIrValue.I64 6)
                    (compiler-reg-i64-ty))
                  tail)))))))))

(cfg
  test
  (define (compiler-reg-call-spanning-call-before
    [tail : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
    (compiler-reg-test-instr-seq-prepend
      (ir.CompilerIrInstr.Call
        7
        (ir.compiler-ir-test-symbol "side_effect")
        (ir.CompilerIrCallArgs.Nil)
        (ast.AstType.Unit))
      tail)))

(cfg
  test
  (define (compiler-reg-call-spanning-multiblock-local-function) : ir.CompilerIrFunction
    (let
      [body-tail : ir.CompilerIrInstrSeq
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "exit"))
          (ir.compiler-ir-instr-seq-empty))]
      [body : ir.CompilerIrInstrSeq
        (compiler-reg-call-spanning-defs-before
          (compiler-reg-call-spanning-call-before
            (compiler-reg-call-spanning-post-call-stores body-tail)))]
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "call_spanning_multiblock_local")
        ir.CompilerIrParamList.Nil
        (ast.AstType.Unit)
        8
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "entry")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "body"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block (ir.compiler-ir-label "body") body)
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-call-spanning-multiblock-boundary-function) : ir.CompilerIrFunction
    (let
      [entry : ir.CompilerIrInstrSeq
        (compiler-reg-call-spanning-defs-before
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "body"))
            (ir.compiler-ir-instr-seq-empty)))]
      [body-tail : ir.CompilerIrInstrSeq
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "exit"))
          (ir.compiler-ir-instr-seq-empty))]
      [body : ir.CompilerIrInstrSeq
        (compiler-reg-call-spanning-call-before
          (compiler-reg-call-spanning-post-call-stores body-tail))]
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "call_spanning_multiblock_boundary")
        ir.CompilerIrParamList.Nil
        (ast.AstType.Unit)
        8
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block (ir.compiler-ir-label "entry") entry)
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block (ir.compiler-ir-label "body") body)
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-scalar-call-spanning-multiblock-local-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-call-spanning-multiblock-local-function)]
      [plan : reg.CompilerRegPlan (reg.compiler-reg-plan-function-scalar func)]
      (match plan
        [(reg.CompilerRegPlan.Plan assignments _ _ _ split-vars _)
          (and
            ;; Same capacity story as the single-block fixture: the greedy
            ;; register-homes the hot call-spanning value (spill-weight priority)
            ;; and the single-use overflow (var 6) takes no register. W3 step
            ;; (a): both overflows are i64 literals, so they rematerialise
            ;; instead of taking frame slots (was: 2 spills, var 6 at slot 6).
            (= (reg.compiler-reg-spill-count assignments) 0)
            (compiler-reg-maybe-location-remat?
              (reg.compiler-reg-assignment-lookup assignments 6))
            (not
              (live.compiler-live-set-contains?
                (reg.compiler-reg-call-split-shadows split-vars)
                5))
            (not
              (live.compiler-live-set-contains?
                (reg.compiler-reg-call-split-shadows split-vars)
                6)))]))))

(cfg
  test
  (define (compiler-reg-scalar-call-spanning-multiblock-boundary-ok?) : bool
    (let
      [plan : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar
          (compiler-reg-call-spanning-multiblock-boundary-function))]
      (match plan
        [(reg.CompilerRegPlan.Plan _ _ _ _ split-vars _)
          (and
            (not
              (live.compiler-live-set-contains?
                (reg.compiler-reg-call-split-shadows split-vars)
                5))
            (not
              (live.compiler-live-set-contains?
                (reg.compiler-reg-call-split-shadows split-vars)
                6)))]))))

;; ---------------------------------------------------------------------------
;; P11b loop-scoped rescue regions.
;;
;; Three-block layout, which is the whole admitted shape in miniature:
;;   0 "entry": defines the invariant, jumps to the loop
;;   1 "loop" : reads the invariant, branches back to itself (self-loop) or out
;;   2 "exit" : returns
;; The header's predecessors are exactly {entry, itself}, so entry is the sole
;; preheader and its terminator (point 4) is the region anchor; the region runs
;; to the loop's last instruction (point 10) so the BACK EDGE stays inside it.
;; ---------------------------------------------------------------------------
(cfg
  test
  (define (compiler-reg-loop-region-fixture
    [define-in-loop? : bool]
    [call-in-loop? : bool]) : ir.CompilerIrFunction
    (let
      [loop-tail : ir.CompilerIrInstrSeq
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.BinOp
            2
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.Var 1)
            (ir.CompilerIrValue.Var 0)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.Var 2)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 2)
                (ir.compiler-ir-label "loop")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty))))]
      [loop-body : ir.CompilerIrInstrSeq
        (if define-in-loop?
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 9)
              (compiler-reg-i64-ty))
            loop-tail)
          (if call-in-loop?
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                3
                (ir.compiler-ir-test-symbol "side_effect")
                (ir.CompilerIrCallArgs.Nil)
                (ast.AstType.Unit))
              loop-tail)
            loop-tail))]
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "loop_region_fixture")
        ir.CompilerIrParamList.Nil
        (ast.AstType.Unit)
        4
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "entry")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                0
                (ir.CompilerIrValue.I64 7)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  1
                  (ir.CompilerIrValue.I64 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                  (ir.compiler-ir-instr-seq-empty)))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block (ir.compiler-ir-label "loop") loop-body)
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

;; Collect loop rows for var 0 (marked a full-grade candidate) and return the
;; bucket the collector filled.
(cfg
  test
  (define (compiler-reg-loop-region-rows-for
    [define-in-loop? : bool]
    [call-in-loop? : bool]) : reg.CompilerRegCallRegionStatSeq
    (match (compiler-reg-loop-region-fixture define-in-loop? call-in-loop?)
      [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
        (let
          [cand : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [order : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [buckets : (__tl_dyn-array reg.CompilerRegCallRegionStatSeq)
            (__tl_make-array reg.CompilerRegCallRegionStatSeq vars)]
          [bi : i64 0]
          (begin
            (while (< bi vars)
              (begin
                (set!
                  (array-ref buckets bi)
                  (reg.compiler-reg-call-region-stat-seq-empty))
                (set! bi (+ bi 1))))
            (set! (array-ref cand 0) (reg.compiler-reg-call-region-cand-full))
            (set! (array-ref order 0) 0)
            (reg.compiler-reg-call-region-loop-rows!
              (ast.ast-node-pool-reader-type-segment-bases)
              blocks
              (reg.compiler-reg-function-loop-depths blocks)
              cand
              order
              1
              vars
              buckets)
            (array-ref buckets 0)))])))

;; (a) A read-only loop invariant gets ONE loop row anchored in the preheader.
(cfg
  test
  (define (compiler-reg-loop-region-invariant-ok?) : bool
    (let
      [rows : reg.CompilerRegCallRegionStatSeq
        (compiler-reg-loop-region-rows-for false false)]
      (and
        (= rows.len 1)
        (match (array-ref rows.slots 0)
          [(reg.CompilerRegCallRegionStat
              var
              lo
              hi
              uses
              defs
              firstdef
              depth
              kind)
            (and
              (= var 0)
              ;; anchor = the preheader's terminator, NOT the loop header: the
              ;; entry reload has to run once per loop entry, not per iteration
              (= lo 4)
              ;; ... and the region runs to the loop's last instruction so the
              ;; back edge is covered and the shadow survives the iteration
              (= hi 10)
              (= uses 1)
              (= defs 0)
              (= firstdef 0)
              (= depth 1)
              (= kind (reg.compiler-reg-call-region-kind-loop)))])))))

;; (c) A root DEFINED inside the region is not loop-invariant: refuse it. The
;; shadow would go stale against its own home slot on the next iteration.
(cfg
  test
  (define (compiler-reg-loop-region-defined-in-loop-refused?) : bool
    (= (compiler-reg-loop-region-rows-for true false).len 0)))

;; (b) A call in the loop body kills the whole region -- the shadow cannot
;; survive a kind-0 clobber, so no loop-wide row is offered and the invariant
;; falls back to the per-inter-call-range block rows the walk already emits.
(cfg
  test
  (define (compiler-reg-loop-region-call-refused?) : bool
    (= (compiler-reg-loop-region-rows-for false true).len 0)))

;; Predecessor-range fixture: block 1 is the header under test, block 0 the
;; layout preheader, block 2 the exit.
(cfg
  test
  (define (compiler-reg-loop-region-ranges [header-lo : i64] [header-hi : i64]) : (__tl_dyn-array
      i64)
    (let
      [ranges : (__tl_dyn-array i64) (__tl_make-array i64 6)]
      (begin
        (set! (array-ref ranges 0) 3)
        (set! (array-ref ranges 1) (- 0 1))
        (set! (array-ref ranges 2) header-lo)
        (set! (array-ref ranges 3) header-hi)
        (set! (array-ref ranges 4) 1)
        (set! (array-ref ranges 5) 1)
        ranges))))

(cfg
  test
  (define (compiler-reg-loop-region-depths [header-depth : i64]) : (__tl_dyn-array
      i64)
    (let
      [depths : (__tl_dyn-array i64) (__tl_make-array i64 3)]
      (begin
        (set! (array-ref depths 0) 0)
        (set! (array-ref depths 1) header-depth)
        (set! (array-ref depths 2) 0)
        depths))))

(cfg
  test
  (define (compiler-reg-loop-region-rotated-ranges) : (__tl_dyn-array i64)
    (let
      [ranges : (__tl_dyn-array i64) (__tl_make-array i64 6)]
      (begin
        ;; block 0: the preheader, no predecessors
        (set! (array-ref ranges 0) 3)
        (set! (array-ref ranges 1) (- 0 1))
        ;; block 1: the body, entered only from the header at block 2
        (set! (array-ref ranges 2) 2)
        (set! (array-ref ranges 3) 2)
        ;; block 2: the header, entered from the preheader and over the back
        ;; edge from the body
        (set! (array-ref ranges 4) 0)
        (set! (array-ref ranges 5) 1)
        ranges))))

(cfg
  test
  (define (compiler-reg-loop-region-rotated-depths) : (__tl_dyn-array i64)
    (let
      [depths : (__tl_dyn-array i64) (__tl_make-array i64 3)]
      (begin
        (set! (array-ref depths 0) 0)
        (set! (array-ref depths 1) 1)
        (set! (array-ref depths 2) 1)
        depths))))

;; (e) Single-entry admission. The header may be entered ONLY from its layout
;; predecessor and from inside the region; any other edge in means the anchor
;; does not dominate the remapped uses.
(cfg
  test
  (define (compiler-reg-loop-region-admit-ok?) : bool
    (and
      ;; preds {entry, self}: the admitted self-loop shape
      (reg.compiler-reg-call-region-loop-admit?
        (compiler-reg-loop-region-ranges 0 1)
        (compiler-reg-loop-region-depths 1)
        3
        1
        1
        1)
      ;; a later block also jumps into the header -> refuse
      (not
        (reg.compiler-reg-call-region-loop-admit?
          (compiler-reg-loop-region-ranges 0 2)
          (compiler-reg-loop-region-depths 1)
          3
          1
          1
          1))
      ;; no edge from the layout predecessor -> there is no preheader to anchor
      (not
        (reg.compiler-reg-call-region-loop-admit?
          (compiler-reg-loop-region-ranges 1 1)
          (compiler-reg-loop-region-depths 1)
          3
          1
          1
          1))
      ;; not a loop at all
      (not
        (reg.compiler-reg-call-region-loop-admit?
          (compiler-reg-loop-region-ranges 0 1)
          (compiler-reg-loop-region-depths 0)
          3
          1
          1
          1))
      ;; the header is block 0: no layout predecessor exists
      (not
        (reg.compiler-reg-call-region-loop-admit?
          (compiler-reg-loop-region-ranges 0 1)
          (compiler-reg-loop-region-depths 1)
          3
          0
          0
          0))
      ;; ROTATED: the span is [1..2] and the header is its LAST block, entered
      ;; from block 0 (the preheader, directly above the span) and from block 1
      ;; (the body, over the back edge that falls through into it). The anchor
      ;; is the span's layout predecessor, so admission holds with the header
      ;; in the middle of the region rather than at its start.
      (reg.compiler-reg-call-region-loop-admit?
        (compiler-reg-loop-region-rotated-ranges)
        (compiler-reg-loop-region-rotated-depths)
        3
        2
        1
        2))))

;; (d) Scoring. A block row charges its entry reload against refs that run at
;; the same frequency; a loop row's reload has LEFT the loop, so its uses take
;; the depth weight alone. One use per iteration is worth nothing under the
;; block formula and is exactly what the loop formula is for.
(cfg
  test
  (define (compiler-reg-loop-region-score-ok?) : bool
    (let
      [ends : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      [one-use-block : reg.CompilerRegCallRegionStat
        (reg.CompilerRegCallRegionStat
          0
          4
          10
          1
          0
          0
          1
          (reg.compiler-reg-call-region-kind-block))]
      [one-use-loop : reg.CompilerRegCallRegionStat
        (reg.CompilerRegCallRegionStat
          0
          4
          10
          1
          0
          0
          1
          (reg.compiler-reg-call-region-kind-loop))]
      [deep-loop : reg.CompilerRegCallRegionStat
        (reg.CompilerRegCallRegionStat
          0
          4
          10
          2
          0
          0
          3
          (reg.compiler-reg-call-region-kind-loop))]
      (begin
        (reg.compiler-reg-fill-i64-array ends 1073741824)
        (and
          ;; one use, one entry mov: no static win, so the block row is refused
          (not (reg.compiler-reg-call-region-stat-eligible? one-use-block ends))
          ;; The same shape as a loop row pays weight(1) * T - 1 reloads. The
          ;; trip factor entered here with P11b phase 3: admission proves the
          ;; anchor block is the loop's sole preheader, so the body sits exactly
          ;; one loop level below the entry mov and the ladder's trip-2
          ;; assumption is the wrong absolute frequency. Block rows are NOT
          ;; amplified -- both of their sides sit at the same point.
          (reg.compiler-reg-call-region-stat-eligible? one-use-loop ends)
          (= (reg.compiler-reg-call-region-stat-score one-use-loop ends) 15)
          ;; depth 3, two uses: 2 * 8 * T - 1
          (= (reg.compiler-reg-call-region-stat-score deep-loop ends) 127)
          ;; the block row's score is untouched by the trip factor
          (=
            (reg.compiler-reg-call-region-stat-score
              (reg.CompilerRegCallRegionStat
                0
                4
                10
                3
                0
                0
                1
                (reg.compiler-reg-call-region-kind-block))
              ends)
            4)
          ;; a loop row outside any loop is not a loop row
          (not
            (reg.compiler-reg-call-region-stat-eligible?
              (reg.CompilerRegCallRegionStat
                0
                4
                10
                1
                0
                0
                0
                (reg.compiler-reg-call-region-kind-loop))
              ends)))))))

;; Picked-row exclusion is an OVERLAP test now: a loop row spans the block rows
;; nested inside it, and one root can only hold one shadow at a time.
(cfg
  test
  (define (compiler-reg-loop-region-overlap-ok?) : bool
    (let
      [lo : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      [hi : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      (begin
        (set! (array-ref lo 0) 100)
        (set! (array-ref hi 0) 200)
        (and
          ;; strictly inside
          (reg.compiler-reg-call-region-picked? lo hi 1 120 140)
          ;; touching at either end still overlaps
          (reg.compiler-reg-call-region-picked? lo hi 1 200 260)
          (reg.compiler-reg-call-region-picked? lo hi 1 40 100)
          ;; disjoint on both sides
          (not (reg.compiler-reg-call-region-picked? lo hi 1 40 98))
          (not (reg.compiler-reg-call-region-picked? lo hi 1 202 260))
          ;; nothing picked yet
          (not (reg.compiler-reg-call-region-picked? lo hi 0 120 140)))))))

;; ---------------------------------------------------------------------------
;; P11b phase 3: loop-scope EVICTION of a parked occupant.
;;
;; One fixture, four blocks' worth of points:
;;   0 "entry": v0 = 7 (the spilled invariant), v3 = 11 (the pool-register
;;              occupant), v1 = 0, jump -> loop     [the jump is the ANCHOR, p6]
;;   1 "loop" : v2 = v1 + v0, v5 = v2 + <t>, v6 = v5 + v0, v1 = v6,
;;              branch v6 -> loop | exit            [region hi = p16]
;;   2 "exit" : v4 = v3 -- the occupant's read AFTER the loop, which is what
;;              makes the reload obligatory -- then return    [head at p18]
;;
;; <t> selects the two populations the search has to separate: v0 leaves the
;; occupant PARKED across the region, v3 makes it BUSY inside it.
;; ---------------------------------------------------------------------------
(cfg
  test
  (define (compiler-reg-evict-fixture [victim-in-loop? : bool]) : ir.CompilerIrFunction
    (let
      [mid : ir.CompilerIrValue
        (if victim-in-loop?
          (ir.CompilerIrValue.Var 3)
          (ir.CompilerIrValue.Var 0))]
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "evict_fixture")
        ir.CompilerIrParamList.Nil
        (ast.AstType.Unit)
        7
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "entry")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                0
                (ir.CompilerIrValue.I64 7)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  3
                  (ir.CompilerIrValue.I64 11)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    1
                    (ir.CompilerIrValue.I64 0)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                    (ir.compiler-ir-instr-seq-empty))))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "loop")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  2
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 1)
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.BinOp
                    5
                    (ir.CompilerIrBinOp.Add)
                    (ir.CompilerIrValue.Var 2)
                    mid
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.BinOp
                      6
                      (ir.CompilerIrBinOp.Add)
                      (ir.CompilerIrValue.Var 5)
                      (ir.CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Mov
                        1
                        (ir.CompilerIrValue.Var 6)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Branch
                          (ir.CompilerIrValue.Var 6)
                          (ir.compiler-ir-label "loop")
                          (ir.compiler-ir-label "exit"))
                        (ir.compiler-ir-instr-seq-empty)))))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    4
                    (ir.CompilerIrValue.Var 3)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                    (ir.compiler-ir-instr-seq-empty))))
              ir.CompilerIrBlockList.Nil)))))))

;; r12/r13: two callee-saved homes that clear the loop-pool hazard filter.
(cfg
  test
  (define (compiler-reg-evict-test-pool) : (__tl_dyn-array i64)
    (__tl_make-array
      (cast cabi.compiler-reg-id-r12 : i64)
      cabi.compiler-reg-id-r13)))

(cfg
  test
  (define (compiler-reg-evict-test-parents) : (__tl_dyn-array i64)
    (let
      [parents : (__tl_dyn-array i64) (__tl_make-array i64 7)]
      [i : i64 0]
      (begin
        (while (< i 7)
          (begin
            (set! (array-ref parents i) i)
            (set! i (+ i 1))))
        parents))))

;; v3 spans the region and is read after it (`victim-end` 18); v5 is defined and
;; consumed strictly inside the loop, which is what a BUSY co-occupant looks
;; like to the interval index.
(cfg
  test
  (define (compiler-reg-evict-test-index [victim-end : i64]) : reg.CompilerRegIntervalIndex
    (let
      [starts : (__tl_dyn-array i64) (__tl_make-array i64 7)]
      [ends : (__tl_dyn-array i64) (__tl_make-array i64 7)]
      (begin
        (reg.compiler-reg-fill-i64-array starts (- 0 1))
        (reg.compiler-reg-fill-i64-array ends (- 0 1))
        (set! (array-ref starts 3) 2)
        (set! (array-ref ends 3) victim-end)
        (set! (array-ref starts 5) 12)
        (set! (array-ref ends 5) 14)
        (reg.CompilerRegIntervalIndex
          starts
          ends
          (__tl_make-array reg.CompilerRegIntervalSeq 0))))))

(cfg
  test
  (define (compiler-reg-evict-test-assignments) : reg.CompilerRegAssignmentTable
    (let
      [table : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-empty)]
      [with-victim : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-insert
          table
          3
          (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
      (reg.compiler-reg-assignment-table-insert
        with-victim
        5
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r13)))))

;; One attempt against the fixture. `occupants` 1 indexes only v3 (on r12);
;; 2 also indexes v5 (on r13), the busy co-occupant.
(cfg
  test
  (define (compiler-reg-evict-attempt
    [victim-in-loop? : bool]
    [victim-end : i64]
    [uses : i64]
    [already-evicted? : bool]
    [occupants : i64]
    [coalesced? : bool]
    [out-points : (__tl_dyn-array i64)]
    [out-saves : (__tl_dyn-array i64)]) : reg.CompilerRegCallEvictPick
    (match (compiler-reg-evict-fixture victim-in-loop?)
      [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
        (let
          [occ-var : (__tl_dyn-array i64) (__tl_make-array i64 4)]
          [occ-reg : (__tl_dyn-array i64) (__tl_make-array i64 4)]
          [occ-kind : (__tl_dyn-array i64) (__tl_make-array i64 4)]
          [evicted : (__tl_dyn-array i64) (__tl_make-array i64 7)]
          [weights : (__tl_dyn-array i64) (__tl_make-array i64 7)]
          [parents : (__tl_dyn-array i64) (compiler-reg-evict-test-parents)]
          [metrics : profile_state.CompilerProfileMetrics
            (profile_state.compiler-profile-state-metrics
              (profile_state.compiler-profile-state-new))]
          (begin
            (set! (array-ref occ-var 0) 3)
            (set! (array-ref occ-reg 0) 0)
            (set!
              (array-ref occ-kind 0)
              (reg.compiler-reg-call-region-occ-kind-scalar))
            (set! (array-ref occ-var 1) 5)
            (set! (array-ref occ-reg 1) 1)
            (set!
              (array-ref occ-kind 1)
              (reg.compiler-reg-call-region-occ-kind-scalar))
            (set! (array-ref weights 3) 5)
            (set! (array-ref weights 5) 9)
            (when already-evicted? (set! (array-ref evicted 3) 1))
            (when coalesced? (set! (array-ref parents 5) 3))
            (reg.compiler-reg-call-region-evict-try
              metrics
              blocks
              (reg.compiler-reg-function-loop-depths blocks)
              weights
              (compiler-reg-evict-test-index victim-end)
              parents
              (compiler-reg-evict-test-assignments)
              (compiler-reg-evict-test-pool)
              2
              occ-var
              occ-reg
              occ-kind
              occupants
              evicted
              0
              uses
              6
              16
              7
              out-points
              out-saves)))])))

(cfg
  test
  (define (compiler-reg-evict-picked?
    [pick : reg.CompilerRegCallEvictPick]
    [pix : i64]
    [victim : i64]
    [exits : i64]
    [save : i64]) : bool
    (match pick
      [(reg.CompilerRegCallEvictPick.CompilerRegCallEvictNoPick) false]
      [(reg.CompilerRegCallEvictPick.CompilerRegCallEvictSomePick p v e s)
        (and (= p pix) (= v victim) (= e exits) (= s save))])))

(cfg
  test
  (define (compiler-reg-evict-no-pick? [pick : reg.CompilerRegCallEvictPick]) : bool
    (match pick
      [(reg.CompilerRegCallEvictPick.CompilerRegCallEvictNoPick) true]
      [(reg.CompilerRegCallEvictPick.CompilerRegCallEvictSomePick _ _ _ _)
        false])))

;; (a) The pool is exhausted, but r12's occupant is parked across the region:
;; lend r12 to the invariant, mirror the occupant into a slot right after its
;; definition (p2 -> save at p4) and reload it at the loop's one exit target
;; (p18, the head of "exit"). Nothing lands inside the loop.
(cfg
  test
  (define (compiler-reg-evict-parked-ok?) : bool
    (let
      [points : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      [saves : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      (and
        (compiler-reg-evict-picked?
          (compiler-reg-evict-attempt false 18 3 false 1 false points saves)
          0
          3
          1
          1)
        (= (array-ref points 0) 18)
        (= (array-ref saves 0) 4)))))

;; (b) The same occupant, read once inside the loop: refuse. Lending the
;; register would need reloads INSIDE the region, which is the comparative-cost
;; problem this pass does not model.
(cfg
  test
  (define (compiler-reg-evict-busy-victim-refused?) : bool
    (compiler-reg-evict-no-pick?
      (compiler-reg-evict-attempt
        true
        18
        3
        false
        1
        false
        (__tl_make-array i64 4)
        (__tl_make-array i64 4)))))

;; (c) BOTH pool registers busy in the region (v3 read inside it, v5 defined
;; and consumed inside it): no parked victim exists, refuse cleanly.
(cfg
  test
  (define (compiler-reg-evict-all-busy-refused?) : bool
    (compiler-reg-evict-no-pick?
      (compiler-reg-evict-attempt
        true
        18
        3
        false
        2
        false
        (__tl_make-array i64 4)
        (__tl_make-array i64 4)))))

;; (d) The occupant dies with the region (interval ends at p16, before the exit
;; head at p18): the exit is dead, so no reload is emitted at all.
(cfg
  test
  (define (compiler-reg-evict-dead-exit-ok?) : bool
    (compiler-reg-evict-picked?
      (compiler-reg-evict-attempt
        false
        16
        3
        false
        1
        false
        (__tl_make-array i64 4)
        (__tl_make-array i64 4))
      0
      3
      0
      1)))

;; (e) PRICING, in its final shape: a trip-amplified benefit, a 2x margin, and a
;; two-use floor.
;;
;; The fixture's ONE in-region use is refused by the floor -- and that is the
;; case that regressed the flagship row when the trip factor landed without it.
;; The victim's save sits at its definition, which for a parameter is the
;; function entry, so it runs on every CALL while the benefit needs the loop to
;; be entered; no depth model sees that asymmetry. Two uses in the same fixture
;; pay: 2*2*8 = 32 >= 2*(2*1 + 1).
(cfg
  test
  (define (compiler-reg-evict-price-refused?) : bool
    (and
      ;; one in-region use: under the floor, refused
      (compiler-reg-evict-no-pick?
        (compiler-reg-evict-attempt
          false
          18
          1
          false
          1
          false
          (__tl_make-array i64 4)
          (__tl_make-array i64 4)))
      ;; two: accepted
      (compiler-reg-evict-picked?
        (compiler-reg-evict-attempt
          false
          18
          2
          false
          1
          false
          (__tl_make-array i64 4)
          (__tl_make-array i64 4))
        0
        3
        1
        1)
      ;; The bar itself, independent of the fixture. Arguments are
      ;; (uses body-depth entry-depth def-weight exits); the 4th is the summed
      ;; WEIGHT of the victim's save stores.
      ;;
      ;; the floor holds at every depth
      (not (reg.compiler-reg-call-region-evict-price-ok? 1 3 0 1 1))
      ;; delta 0: the use runs no more often than the anchor, so no trip
      ;; amplification applies and two uses cannot pay -- 4 < 2*(2+1)
      (not (reg.compiler-reg-call-region-evict-price-ok? 2 1 1 1 1))
      ;; delta 1: the same two uses, amplified -- 2*2*8 = 32 >= 2*(1+1)
      (reg.compiler-reg-call-region-evict-price-ok? 2 1 0 1 1)
      ;; the trip factor saturates at two levels, so a deep nest cannot
      ;; manufacture an unbounded benefit
      (=
        (reg.compiler-reg-call-region-trip-multiplier 2)
        (reg.compiler-reg-call-region-trip-multiplier 9))
      (= (reg.compiler-reg-call-region-trip-multiplier 0) 1)
      ;; a victim REDEFINED inside an enclosing loop: the store costs what the
      ;; reloads it replaces would have, and the bar refuses -- 32 < 2*(2+32)
      (not (reg.compiler-reg-call-region-evict-price-ok? 2 1 0 32 1))
      ;; ... and three exits at the anchor's own frequency still refuse when the
      ;; body barely runs more often than the anchor: 4 < 2*(4*1+1)
      (not (reg.compiler-reg-call-region-evict-price-ok? 2 1 1 1 3)))))

;; (f) DOUBLE LENDING. A victim already lent to an earlier root is off the
;; table: one save/reload protocol per parked value per function.
(cfg
  test
  (define (compiler-reg-evict-double-lend-refused?) : bool
    (compiler-reg-evict-no-pick?
      (compiler-reg-evict-attempt
        false
        18
        3
        true
        1
        false
        (__tl_make-array i64 4)
        (__tl_make-array i64 4)))))

;; A victim sharing storage with a sibling is refused outright: the reload
;; placement argument ("a live victim owns its register alone") does not hold
;; for a class whose members are distinct values at disjoint times.
(cfg
  test
  (define (compiler-reg-evict-coalesced-victim-refused?) : bool
    (compiler-reg-evict-no-pick?
      (compiler-reg-evict-attempt
        false
        18
        3
        false
        1
        true
        (__tl_make-array i64 4)
        (__tl_make-array i64 4)))))

;; Occupant identity is the coalesce ROOT. Two entries of one class are one
;; value (lendable); two distinct classes, a pair half, or an accepted shadow
;; are not.
(cfg
  test
  (define (compiler-reg-evict-sole-occupant-ok?) : bool
    (let
      [occ-var : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      [occ-reg : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      [occ-kind : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      [index : reg.CompilerRegIntervalIndex (compiler-reg-evict-test-index 18)]
      [parents : (__tl_dyn-array i64) (compiler-reg-evict-test-parents)]
      [class-parents : (__tl_dyn-array i64) (compiler-reg-evict-test-parents)]
      (begin
        (set! (array-ref occ-var 0) 3)
        (set! (array-ref occ-reg 0) 0)
        (set!
          (array-ref occ-kind 0)
          (reg.compiler-reg-call-region-occ-kind-scalar))
        (set! (array-ref occ-var 1) 5)
        (set! (array-ref occ-reg 1) 0)
        (set!
          (array-ref occ-kind 1)
          (reg.compiler-reg-call-region-occ-kind-scalar))
        ;; v5 joins v3's storage class
        (set! (array-ref class-parents 5) 3)
        (and
          ;; one entry, one value
          (=
            (reg.compiler-reg-call-region-evict-sole-occupant
              occ-var
              occ-reg
              occ-kind
              1
              index
              parents
              7
              0
              6
              16)
            3)
          ;; two entries, two distinct classes -> not lendable
          (<
            (reg.compiler-reg-call-region-evict-sole-occupant
              occ-var
              occ-reg
              occ-kind
              2
              index
              parents
              7
              0
              6
              16)
            0)
          ;; the same two entries as ONE storage class -> lendable again
          (=
            (reg.compiler-reg-call-region-evict-sole-occupant
              occ-var
              occ-reg
              occ-kind
              2
              index
              class-parents
              7
              0
              6
              16)
            3)
          ;; an accepted shadow already owns the register
          (begin
            (set!
              (array-ref occ-kind 0)
              (reg.compiler-reg-call-region-occ-kind-shadow))
            (<
              (reg.compiler-reg-call-region-evict-sole-occupant
                occ-var
                occ-reg
                occ-kind
                1
                index
                parents
                7
                0
                6
                16)
              0))
          ;; ... and a register pair half is not a lendable scalar either
          (begin
            (set!
              (array-ref occ-kind 0)
              (reg.compiler-reg-call-region-occ-kind-pair))
            (<
              (reg.compiler-reg-call-region-evict-sole-occupant
                occ-var
                occ-reg
                occ-kind
                1
                index
                parents
                7
                0
                6
                16)
              0)))))))

;; A sibling's read is the class's read: with v5 (used inside the loop) coalesced
;; onto v3, v3 is no longer parked and the verifier says so. This is the exact
;; shape that made the first cut of this pass miscompile -- the root's hull
;; covered the region BECAUSE a member was read inside it.
(cfg
  test
  (define (compiler-reg-evict-class-mention-ok?) : bool
    (match (compiler-reg-evict-fixture false)
      [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [bslots : (__tl_dyn-array ir.CompilerIrBlock) seq.slots]
          [points : (__tl_dyn-array i64)
            (reg.compiler-reg-loop-phi-mb-block-points bslots)]
          [parents : (__tl_dyn-array i64) (compiler-reg-evict-test-parents)]
          [class-parents : (__tl_dyn-array i64)
            (compiler-reg-evict-test-parents)]
          (begin
            (set! (array-ref class-parents 5) 3)
            (and
              ;; the anchor's point is the preheader's terminator
              (= (- (array-ref points 1) 2) 6)
              (= (- (array-ref points 2) 2) 16)
              ;; v3 alone: parked
              (not
                (reg.compiler-reg-call-region-evict-var-mentioned?
                  bslots
                  points
                  0
                  1
                  6
                  parents
                  7
                  3))
              ;; v3 with v5 in its class: busy
              (reg.compiler-reg-call-region-evict-var-mentioned?
                bslots
                points
                0
                1
                6
                class-parents
                7
                3)
              ;; v0 is read three times in the loop under any parenting
              (reg.compiler-reg-call-region-evict-var-mentioned?
                bslots
                points
                0
                1
                6
                parents
                7
                0))))])))

;; (g) PLAN SHAPE. The rewrite realizes exactly three movs for the accepted
;; eviction above: the victim's store right after its definition, the shadow's
;; load at the region anchor, and the victim's reload at the head of the exit
;; block. The loop body gains NOTHING; its reads of v0 are remapped to the
;; shadow var.
(cfg
  test
  (define (compiler-reg-evict-rewrite-shape-ok?) : bool
    (match (compiler-reg-evict-fixture false)
      [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
        (let
          [shadow-regs : (__tl_dyn-array i64) (__tl_make-array i64 7)]
          [split : reg.CompilerRegCallSplit
            (begin
              (reg.compiler-reg-fill-i64-array
                shadow-regs
                cabi.compiler-reg-id-invalid)
              (set! (array-ref shadow-regs 0) cabi.compiler-reg-id-r12)
              (reg.CompilerRegCallSplit
                (live.compiler-live-set1 0)
                shadow-regs
                (reg.compiler-reg-call-region-seq-push
                  (reg.compiler-reg-call-region-seq-empty)
                  (reg.CompilerRegCallRegion 0 6 16 1 0))
                (reg.compiler-reg-call-evict-seq-push
                  (reg.compiler-reg-call-evict-seq-push
                    (reg.compiler-reg-call-evict-seq-empty)
                    (reg.CompilerRegCallEvict
                      3
                      4
                      (reg.compiler-reg-call-evict-kind-save)))
                  (reg.CompilerRegCallEvict
                    3
                    18
                    (reg.compiler-reg-call-evict-kind-restore)))))]
          [plan : reg.CompilerRegPlan
            (reg.CompilerRegPlan.Plan
              (reg.compiler-reg-assignment-table-empty)
              (live.compiler-live-set-empty)
              (reg.compiler-reg-interval-seq-empty)
              (reg.compiler-reg-var-types-empty)
              split
              (reg.compiler-reg-split-plan-empty))]
          (match (reg.compiler-reg-caller-save-rewrite-blocks
            blocks
            vars
            (reg.compiler-reg-var-types-empty)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite out _ next-vars _ _)
              (let
                [oseq : ir.CompilerIrBlockSeq
                  (live.compiler-live-ir-block-list-to-seq out)]
                [oslots : (__tl_dyn-array ir.CompilerIrBlock) oseq.slots]
                (and
                  (= oseq.len 3)
                  ;; two minted vars: the victim's slot and the shadow
                  (= next-vars 9)
                  ;; entry: 4 originals, the save right after v3's def (index 2)
                  ;; and the shadow load right before the terminator (index 4)
                  (= (compiler-reg-evict-block-len (array-ref oslots 0)) 6)
                  (compiler-reg-evict-block-mov? (array-ref oslots 0) 2 7 3)
                  (compiler-reg-evict-block-mov? (array-ref oslots 0) 4 8 0)
                  ;; loop body untouched in COUNT: no reload lands inside it
                  (= (compiler-reg-evict-block-len (array-ref oslots 1)) 5)
                  ;; exit: the reload, then the two originals
                  (= (compiler-reg-evict-block-len (array-ref oslots 2)) 3)
                  (compiler-reg-evict-block-mov? (array-ref oslots 2) 0 3 7)))]))])))

(cfg
  test
  (define (compiler-reg-evict-block-len [block : ir.CompilerIrBlock]) : i64
    (match block
      [(ir.CompilerIrBlock.Block _ instrs)
        (ir.compiler-ir-instr-seq-count instrs)])))

(cfg
  test
  (define (compiler-reg-evict-block-mov?
    [block : ir.CompilerIrBlock]
    [index : i64]
    [dst : i64]
    [src : i64]) : bool
    (match block
      [(ir.CompilerIrBlock.Block _ instrs)
        (if (>= index (ir.compiler-ir-instr-seq-count instrs))
          false
          (match (ir.compiler-ir-instr-seq-ref instrs index)
            [(ir.CompilerIrInstr.Mov d value _)
              (match value
                [(ir.CompilerIrValue.Var s) (and (= d dst) (= s src))]
                [_ false])]
            [_ false]))])))

(cfg
  test
  (define (compiler-reg-edge-copy-list-has?
    [copies : reg.CompilerRegEdgeCopySeq]
    [from-label : i64]
    [to-label : i64]
    [src : i64]
    [dst : i64]
    [want-pred-end : bool]) : bool
    (let
      [slots : (__tl_dyn-array reg.CompilerRegEdgeCopy) copies.slots]
      [count : i64 copies.len]
      [index : i64 0]
      [found : bool false]
      (begin
        (while (and (< index count) (not found))
          (begin
            (match (array-ref slots index)
              [(reg.CompilerRegEdgeCopy.Copy
                  found-from
                  found-to
                  found-src
                  found-dst
                  _
                  _
                  placement)
                (if (and
                  (= found-from from-label)
                  (= found-to to-label)
                  (= found-src src)
                  (= found-dst dst)
                  (match placement
                    [(reg.CompilerRegEdgeCopyPlacement.PredEnd) want-pred-end]
                    [(reg.CompilerRegEdgeCopyPlacement.SuccEntry)
                      (not want-pred-end)]))
                  (set! found true)
                  unit)])
            (set! index (+ index 1))))
        found))))

(cfg
  test
  (define (compiler-reg-edge-copy-linear-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "edge_copy_linear")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "hot"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "hot")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              (ir.compiler-ir-instr-seq-empty)))
          ir.CompilerIrBlockList.Nil)))))

(cfg
  test
  (define (compiler-reg-edge-copy-linear-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-edge-copy-linear-function)]
      [region : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-prepend
          (ir.compiler-ir-label "hot")
          (reg.compiler-reg-label-seq-empty))]
      (match (compiler-reg-edge-copy-plan-for-region
        func
        region
        0
        10
        (compiler-reg-i64-ty))
        [(reg.CompilerRegEdgeCopyPlan.Plan copies)
          (and
            (= (reg.compiler-reg-edge-copy-list-count copies) 1)
            (compiler-reg-edge-copy-list-has?
              copies
              (ir.compiler-ir-label "entry")
              (ir.compiler-ir-label "hot")
              0
              10
              true)
            (match func
              [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
                (match (reg.compiler-reg-edge-copy-apply blocks copies)
                  [(reg.CompilerRegEdgeCopyRewrite.Rewrite rewritten)
                    (compiler-reg-instr-seq-has-mov-var?
                      (compiler-reg-block-instr-seq
                        rewritten
                        (ir.compiler-ir-label "entry"))
                      10
                      0)]
                  [(reg.CompilerRegEdgeCopyRewrite.Refused _) false])]))]
        [(reg.CompilerRegEdgeCopyPlan.Refused _) false]))))

(cfg
  test
  (define (compiler-reg-edge-copy-backedge-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "edge_copy_backedge")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "loop")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "sink")
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                  (ir.compiler-ir-instr-seq-empty))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-edge-copy-backedge-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-edge-copy-backedge-function)]
      [region : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-prepend
          (ir.compiler-ir-label "body")
          (reg.compiler-reg-label-seq-empty))]
      (match (compiler-reg-edge-copy-plan-for-region
        func
        region
        0
        10
        (compiler-reg-i64-ty))
        [(reg.CompilerRegEdgeCopyPlan.Plan copies)
          (and
            (= (reg.compiler-reg-edge-copy-list-count copies) 2)
            (compiler-reg-edge-copy-list-has?
              copies
              (ir.compiler-ir-label "loop")
              (ir.compiler-ir-label "body")
              0
              10
              false)
            (compiler-reg-edge-copy-list-has?
              copies
              (ir.compiler-ir-label "body")
              (ir.compiler-ir-label "loop")
              10
              0
              true)
            (match func
              [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
                (match (reg.compiler-reg-edge-copy-apply blocks copies)
                  [(reg.CompilerRegEdgeCopyRewrite.Rewrite rewritten)
                    (let
                      [body : ir.CompilerIrInstrSeq
                        (compiler-reg-block-instr-seq
                          rewritten
                          (ir.compiler-ir-label "body"))]
                      (and
                        (compiler-reg-instr-seq-has-mov-var? body 10 0)
                        (compiler-reg-instr-seq-has-mov-var? body 0 10)))]
                  [(reg.CompilerRegEdgeCopyRewrite.Refused _) false])]))]
        [(reg.CompilerRegEdgeCopyPlan.Refused _) false]))))

(cfg
  test
  (define (compiler-reg-edge-copy-critical-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "edge_copy_critical")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "hot")
                (ir.compiler-ir-label "cold"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "other")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "hot"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "hot")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "cold")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 0)))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-edge-copy-critical-refusal-ok?) : bool
    (let
      [region : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-prepend
          (ir.compiler-ir-label "hot")
          (reg.compiler-reg-label-seq-empty))]
      (match (compiler-reg-edge-copy-plan-for-region
        (compiler-reg-edge-copy-critical-function)
        region
        0
        10
        (compiler-reg-i64-ty))
        [(reg.CompilerRegEdgeCopyPlan.Plan _) false]
        [(reg.CompilerRegEdgeCopyPlan.Refused _) true]))))

(cfg
  test
  (define (compiler-reg-loop-split-plan [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
    (let
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [liveness : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function func)]
      (match (reg.compiler-reg-live-interval-selection func liveness)
        [(reg.CompilerRegIntervalSelection.Selection intervals _)
          (reg.CompilerRegPlan.Plan
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment
                0
                (reg.CompilerRegLocation.Spill
                  (reg.compiler-reg-stack-slot-offset 0)))
              (reg.compiler-reg-assignment-table-empty))
            (live.compiler-live-set-empty)
            intervals
            type-info
            (reg.compiler-reg-call-split-empty)
            (reg.compiler-reg-split-plan-empty))]))))

(cfg
  test
  (define (compiler-reg-loop-split-two-plan [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
    (let
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [liveness : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function func)]
      (match (reg.compiler-reg-live-interval-selection func liveness)
        [(reg.CompilerRegIntervalSelection.Selection intervals _)
          (reg.CompilerRegPlan.Plan
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment
                0
                (reg.CompilerRegLocation.Spill
                  (reg.compiler-reg-stack-slot-offset 0)))
              (reg.compiler-reg-assignments-prepend
                (reg.CompilerRegAssignment
                  1
                  (reg.CompilerRegLocation.Spill
                    (reg.compiler-reg-stack-slot-offset 1)))
                (reg.compiler-reg-assignment-table-empty)))
            (live.compiler-live-set-empty)
            intervals
            type-info
            (reg.compiler-reg-call-split-empty)
            (reg.compiler-reg-split-plan-empty))]))))

(cfg
  test
  (define (compiler-reg-leaf-csr-split-plan [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
    (let
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [liveness : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function func)]
      (match (reg.compiler-reg-live-interval-selection func liveness)
        [(reg.CompilerRegIntervalSelection.Selection intervals _)
          (reg.CompilerRegPlan.Plan
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment
                0
                (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))
              (reg.compiler-reg-assignments-prepend
                (reg.CompilerRegAssignment
                  1
                  (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r8))
                (reg.compiler-reg-assignment-table-empty)))
            (live.compiler-live-set-empty)
            intervals
            type-info
            (reg.compiler-reg-call-split-empty)
            (reg.compiler-reg-split-plan-empty))]))))

(cfg
  test
  (define (compiler-reg-leaf-csr-split-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "leaf_csr_split")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      2
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "loop")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                1
                (ir.CompilerIrBinOp.Eq)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.I64 7)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Branch
                  (ir.CompilerIrValue.Var 1)
                  (ir.compiler-ir-label "body")
                  (ir.compiler-ir-label "exit"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot0")
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot1")
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                    (ir.compiler-ir-instr-seq-empty)))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 0)))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-leaf-csr-split-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-leaf-csr-split-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-leaf-csr-split-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [rewrite : reg.CompilerRegCallSaveRewrite
              (reg.compiler-reg-leaf-csr-split-rewrite-one
                (ast.ast-node-pool-reader-type-segment-bases)
                cabi.CompilerRegTargetAbi.Linux
                func
                blocks
                vars
                (reg.compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(reg.CompilerRegCallSaveRewrite.Rewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [rewritten-func : ir.CompilerIrFunction
                    (ir.CompilerIrFunction.Function
                      (ir.compiler-ir-test-symbol "leaf_csr_split")
                      ir.CompilerIrParamList.Nil
                      (ast.AstType.I64)
                      out-vars
                      rewritten)]
                  [rewritten-types : reg.CompilerRegVarTypes
                    (reg.compiler-reg-function-var-types rewritten-func)]
                  [raw-plan : reg.CompilerRegPlan
                    (reg.compiler-reg-plan-function-scalar-cold-with-type-segment-bases-for-abi-with-types-and-preassignments
                      (ast.ast-node-pool-reader-type-segment-bases)
                      cabi.CompilerRegTargetAbi.Linux
                      rewritten-func
                      (- 0 1)
                      rewritten-types
                      extra-assignments)]
                  [rewritten-plan : reg.CompilerRegPlan
                    (reg.compiler-reg-plan-hide-leaf-csr-phantoms
                      raw-plan
                      extra-assignments
                      vars)]
                  [assignments : reg.CompilerRegAssignmentTable
                    (reg.compiler-reg-plan-assignments rewritten-plan)]
                  [body : ir.CompilerIrInstrSeq
                    (compiler-reg-block-instr-seq
                      rewritten
                      (ir.compiler-ir-label "body"))]
                  (and
                    (= out-vars (+ vars 2))
                    (= (reg.compiler-reg-assignment-count extra-assignments) 2)
                    (reg.compiler-reg-leaf-csr-fuse-safe? func 1)
                    (not
                      (reg.compiler-reg-assignments-use-register?
                        assignments
                        cabi.compiler-reg-id-r12))
                    (not
                      (compiler-reg-location-any-register?
                        (reg.compiler-reg-assignment-lookup assignments 0)))
                    (compiler-reg-location-any-register?
                      (reg.compiler-reg-assignment-lookup assignments vars))
                    (compiler-reg-location-any-register?
                      (reg.compiler-reg-assignment-lookup
                        assignments
                        (+ vars 1)))
                    (not
                      (compiler-reg-same-location? assignments vars (+ vars 1)))
                    (compiler-reg-instr-seq-has-store-var?
                      body
                      "hot0"
                      (+ vars 1))
                    (compiler-reg-instr-seq-has-store-var?
                      body
                      "hot1"
                      (+ vars 1))
                    (not (compiler-reg-instr-seq-has-store-var? body "hot0" 0))))]))]))))

(cfg
  test
  (define (compiler-reg-loop-split-rewrite-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_rewrite")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "loop")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot0")
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot1")
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                    (ir.compiler-ir-instr-seq-empty)))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-two-rewrite-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_two_rewrite")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      2
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 11)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                (ir.compiler-ir-instr-seq-empty)))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "loop")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot0")
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot1")
                    (ir.CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "hot2")
                      (ir.CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Store
                        (ir.compiler-ir-test-symbol "hot3")
                        (ir.CompilerIrValue.Var 1)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                        (ir.compiler-ir-instr-seq-empty)))))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-low-benefit-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_low_benefit")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "loop")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot0")
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                  (ir.compiler-ir-instr-seq-empty))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-phi-region-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_phi_region")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      2
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "loop")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Phi
                  1
                  (ir.compiler-ir-phi-input-cons
                    (ir.CompilerIrValue.Var 0)
                    (ir.compiler-ir-label "loop")
                    ir.CompilerIrPhiInputList.Nil)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot0")
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "hot1")
                      (ir.CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                      (ir.compiler-ir-instr-seq-empty))))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-rewrite-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-loop-split-rewrite-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [rewrite : reg.CompilerRegCallSaveRewrite
              (reg.compiler-reg-loop-split-rewrite-blocks
                (ast.ast-node-pool-reader-type-segment-bases)
                func
                blocks
                vars
                (reg.compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(reg.CompilerRegCallSaveRewrite.Rewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [body : ir.CompilerIrInstrSeq
                    (compiler-reg-block-instr-seq
                      rewritten
                      (ir.compiler-ir-label "body"))]
                  [rewritten-plan : reg.CompilerRegPlan
                    (reg.compiler-reg-plan-with-call-save-rewrite plan rewrite)]
                  [rewritten-assignments : reg.CompilerRegAssignmentTable
                    (reg.compiler-reg-plan-assignments rewritten-plan)]
                  (and
                    (= out-vars (+ vars 1))
                    (= (reg.compiler-reg-assignment-count extra-assignments) 1)
                    ;; The region is clobber-free (no call/syscall), so the
                    ;; candidate list offers the caller-saved %r8/%r9/%rsi/%rdi
                    ;; before the callee-saved set and the split var takes %r8.
                    ;; (Stale %r12 expectation predated the clobber-free
                    ;; caller-saved widening; only --cfg test builds run this.)
                    (reg.compiler-reg-location-register?
                      (reg.compiler-reg-assignment-lookup
                        rewritten-assignments
                        vars)
                      cabi.compiler-reg-id-r8)
                    (compiler-reg-instr-seq-has-mov-var? body vars 0)
                    (compiler-reg-instr-seq-has-mov-var? body 0 vars)
                    (compiler-reg-instr-seq-has-store-var? body "hot0" vars)
                    (compiler-reg-instr-seq-has-store-var? body "hot1" vars)
                    (not (compiler-reg-instr-seq-has-store-var? body "hot0" 0))))]))]))))

(cfg
  test
  (define (compiler-reg-loop-split-multiple-rewrite-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-loop-split-two-rewrite-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-loop-split-two-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [rewrite : reg.CompilerRegCallSaveRewrite
              (reg.compiler-reg-loop-split-rewrite-blocks
                (ast.ast-node-pool-reader-type-segment-bases)
                func
                blocks
                vars
                (reg.compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(reg.CompilerRegCallSaveRewrite.Rewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [body : ir.CompilerIrInstrSeq
                    (compiler-reg-block-instr-seq
                      rewritten
                      (ir.compiler-ir-label "body"))]
                  [rewritten-plan : reg.CompilerRegPlan
                    (reg.compiler-reg-plan-with-call-save-rewrite plan rewrite)]
                  [rewritten-assignments : reg.CompilerRegAssignmentTable
                    (reg.compiler-reg-plan-assignments rewritten-plan)]
                  [split0 : i64 vars]
                  [split1 : i64 (+ vars 1)]
                  (and
                    (= out-vars (+ vars 2))
                    (= (reg.compiler-reg-assignment-count extra-assignments) 2)
                    ;; Clobber-free region -> caller-saved candidates first:
                    ;; the two split vars take %r8 and %r9 (see
                    ;; compiler-reg-loop-split-candidate-regs).
                    (reg.compiler-reg-location-register?
                      (reg.compiler-reg-assignment-lookup
                        rewritten-assignments
                        split0)
                      cabi.compiler-reg-id-r8)
                    (reg.compiler-reg-location-register?
                      (reg.compiler-reg-assignment-lookup
                        rewritten-assignments
                        split1)
                      cabi.compiler-reg-id-r9)
                    (compiler-reg-instr-seq-has-store-var? body "hot0" split0)
                    (compiler-reg-instr-seq-has-store-var? body "hot1" split1)
                    (compiler-reg-instr-seq-has-store-var? body "hot2" split0)
                    (compiler-reg-instr-seq-has-store-var? body "hot3" split1)
                    (not (compiler-reg-instr-seq-has-store-var? body "hot0" 0))
                    (not (compiler-reg-instr-seq-has-store-var? body "hot1" 1))))]))]))))

(cfg
  test
  (define (compiler-reg-loop-split-noop-for? [func : ir.CompilerIrFunction]) : bool
    (let
      [plan : reg.CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-loop-split-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                _
                _
                out-vars
                extra-assignments
                _)
              (and
                (= out-vars vars)
                (= (reg.compiler-reg-assignment-count extra-assignments) 0))])]))))

(cfg
  test
  (define (compiler-reg-loop-split-low-benefit-ok?) : bool
    (compiler-reg-loop-split-noop-for?
      (compiler-reg-loop-split-low-benefit-function))))

(cfg
  test
  ;; Historical name: this fixture's phi-header region used to be REFUSED
  ;; (critical entry edge). The on-demand per-header preheader split
  ;; (compiler-reg-preheader-*) now inserts a dedicated preheader for exactly
  ;; this shape, so the hot spilled var IS homed: one split var, one extra
  ;; assignment. (Stale noop expectation predated the preheader machinery;
  ;; only --cfg test builds run this.)
  (define (compiler-reg-loop-split-phi-region-refusal-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-loop-split-phi-region-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-loop-split-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                _
                _
                out-vars
                extra-assignments
                _)
              (and
                (= out-vars (+ vars 1))
                (= (reg.compiler-reg-assignment-count extra-assignments) 1))])]))))

(cfg
  test
  ;; N-BLOCK loop-invariant region (SplitKit step 1 lifted past the 2-block
  ;; bound). `loop` is the header, `body1`+`body2` the body, so the natural loop
  ;; spans THREE blocks; every use of var 0 sits in `body1` while the back-edge
  ;; block `body2` mentions nothing, so no SINGLE block is a profitable region
  ;; and only the multi-block region can home it. Every body block is entered
  ;; from inside the region, so the region is single-entry at `loop`.
  (define (compiler-reg-loop-split-nblock-invariant-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_nblock_invariant")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "loop")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body1")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "body1")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot0")
                  (ir.CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot1")
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "body2"))
                    (ir.compiler-ir-instr-seq-empty)))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "body2")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                  (ir.compiler-ir-instr-seq-empty)))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "exit")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                    (ir.compiler-ir-instr-seq-empty)))
                ir.CompilerIrBlockList.Nil))))))))

(cfg
  test
  ;; Same natural loop, but `side` branches from OUTSIDE the region straight into
  ;; the body block `body2`. The region is then multi-entry, its entry edge is not
  ;; the header edge, and the INTO copy could land after a phi that already read
  ;; the region register -- so the single-entry gate must refuse it and the whole
  ;; loop-split rewrite must be a no-op.
  (define (compiler-reg-loop-split-nblock-outside-entry-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_nblock_outside_entry")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "loop")
                (ir.compiler-ir-label "side"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "side")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "body2"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "loop")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Branch
                  (ir.CompilerIrValue.Bool false)
                  (ir.compiler-ir-label "body1")
                  (ir.compiler-ir-label "exit"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "body1")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot0")
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "hot1")
                      (ir.CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "body2"))
                      (ir.compiler-ir-instr-seq-empty)))))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "body2")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                    (ir.compiler-ir-instr-seq-empty)))
                (ir.compiler-ir-block-cons
                  (ir.CompilerIrBlock.Block
                    (ir.compiler-ir-label "exit")
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Return
                        (ir.CompilerIrMaybeValue.Some
                          (ir.CompilerIrValue.Var 0)))
                      (ir.compiler-ir-instr-seq-empty)))
                  ir.CompilerIrBlockList.Nil)))))))))

(cfg
  test
  ;; The N-block region is admitted, homed in the first clobber-free candidate
  ;; (%r8 -- the region has no call), and the boundary copies land on the right
  ;; EDGES: the IN copy in the preheader `entry` (PredEnd, its only successor is
  ;; the header) and the OUT copy at the top of `exit` (SuccEntry, its only
  ;; predecessor is the header). Both body blocks read the homed register, and
  ;; no use of the original spilled var 0 survives inside the region.
  (define (compiler-reg-loop-split-nblock-invariant-rewrite-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-loop-split-nblock-invariant-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [rewrite : reg.CompilerRegCallSaveRewrite
              (reg.compiler-reg-loop-split-rewrite-blocks
                (ast.ast-node-pool-reader-type-segment-bases)
                func
                blocks
                vars
                (reg.compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(reg.CompilerRegCallSaveRewrite.Rewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [entry-instrs : ir.CompilerIrInstrSeq
                    (compiler-reg-block-instr-seq
                      rewritten
                      (ir.compiler-ir-label "entry"))]
                  [body1 : ir.CompilerIrInstrSeq
                    (compiler-reg-block-instr-seq
                      rewritten
                      (ir.compiler-ir-label "body1"))]
                  [exit-instrs : ir.CompilerIrInstrSeq
                    (compiler-reg-block-instr-seq
                      rewritten
                      (ir.compiler-ir-label "exit"))]
                  [rewritten-assignments : reg.CompilerRegAssignmentTable
                    (reg.compiler-reg-plan-assignments
                      (reg.compiler-reg-plan-with-call-save-rewrite
                        plan
                        rewrite))]
                  (and
                    (= out-vars (+ vars 1))
                    (= (reg.compiler-reg-assignment-count extra-assignments) 1)
                    (reg.compiler-reg-location-register?
                      (reg.compiler-reg-assignment-lookup
                        rewritten-assignments
                        vars)
                      cabi.compiler-reg-id-r8)
                    ;; IN copy on the loop-entry edge, in the preheader.
                    (compiler-reg-instr-seq-has-mov-var? entry-instrs vars 0)
                    ;; OUT copy on the live loop-exit edge, at the exit block top.
                    (compiler-reg-instr-seq-has-mov-var? exit-instrs 0 vars)
                    ;; Region uses read the homed register, not the slot.
                    (compiler-reg-instr-seq-has-store-var? body1 "hot0" vars)
                    (compiler-reg-instr-seq-has-store-var? body1 "hot1" vars)
                    (not (compiler-reg-instr-seq-has-store-var? body1 "hot0" 0))
                    (not (compiler-reg-instr-seq-has-store-var? body1 "hot1" 0))))]))]))))

(cfg
  test
  (define (compiler-reg-loop-split-nblock-outside-entry-refused-ok?) : bool
    (compiler-reg-loop-split-noop-for?
      (compiler-reg-loop-split-nblock-outside-entry-function))))

(cfg
  test
  (define (compiler-reg-loop-split-clobber-scan-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_clobber_scan")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      5
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "loop")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 3)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  2
                  (ir.CompilerIrBinOp.Shl (ast.AstType.I64))
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.Var 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.BinOp
                    3
                    (ir.CompilerIrBinOp.Div)
                    (ir.CompilerIrValue.Var 0)
                    (ir.CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.BinOp
                      4
                      (ir.CompilerIrBinOp.Mul)
                      (ir.CompilerIrValue.Var 0)
                      (ir.CompilerIrValue.Var 1)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                      (ir.compiler-ir-instr-seq-empty))))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-loop-split-rcx-rdx-candidates-ok?) : bool
    (let
      [safe : reg.CompilerRegIdSeq
        (reg.compiler-reg-loop-split-candidate-regs true true true)]
      [unsafe : reg.CompilerRegIdSeq
        (reg.compiler-reg-loop-split-candidate-regs true false false)]
      [call-region : reg.CompilerRegIdSeq
        (reg.compiler-reg-loop-split-candidate-regs false true true)]
      (and
        (reg.compiler-reg-id-seq-contains? safe cabi.compiler-reg-id-rcx)
        (reg.compiler-reg-id-seq-contains? safe cabi.compiler-reg-id-rdx)
        (not
          (reg.compiler-reg-id-seq-contains? unsafe cabi.compiler-reg-id-rcx))
        (not
          (reg.compiler-reg-id-seq-contains? unsafe cabi.compiler-reg-id-rdx))
        (reg.compiler-reg-id-seq-contains? unsafe cabi.compiler-reg-id-r8)
        (reg.compiler-reg-id-seq-contains? unsafe cabi.compiler-reg-id-rdi)
        (not
          (reg.compiler-reg-id-seq-contains?
            call-region
            cabi.compiler-reg-id-r8))
        (not
          (reg.compiler-reg-id-seq-contains?
            call-region
            cabi.compiler-reg-id-rcx))
        (not
          (reg.compiler-reg-id-seq-contains?
            call-region
            cabi.compiler-reg-id-rdx))))))

(cfg
  test
  (define (compiler-reg-loop-split-fixed-clobber-scan-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-loop-split-clobber-scan-function)]
      [full-window : reg.CompilerRegIdSeq
        (reg.compiler-reg-loop-split-candidate-regs
          true
          (reg.compiler-reg-loop-split-region-rcx-safe?
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            0
            12)
          (reg.compiler-reg-loop-split-region-rdx-safe?
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            0
            12))]
      (and
        ;; Point 4 is the variable shift; inclusive-start makes [4,6) unsafe.
        (reg.compiler-reg-loop-split-region-crosses-kind?
          (ast.ast-node-pool-reader-type-segment-bases)
          func
          2
          4
          6)
        ;; Points 6 and 8 are the div and mul %rdx fixed-use sites.
        (reg.compiler-reg-loop-split-region-crosses-kind?
          (ast.ast-node-pool-reader-type-segment-bases)
          func
          4
          6
          8)
        (reg.compiler-reg-loop-split-region-crosses-kind?
          (ast.ast-node-pool-reader-type-segment-bases)
          func
          4
          8
          10)
        ;; The half-open end still excludes a clobber exactly at end.
        (not
          (reg.compiler-reg-loop-split-region-crosses-kind?
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            2
            0
            4))
        (not
          (reg.compiler-reg-id-seq-contains?
            full-window
            cabi.compiler-reg-id-rcx))
        (not
          (reg.compiler-reg-id-seq-contains?
            full-window
            cabi.compiler-reg-id-rdx))
        (reg.compiler-reg-id-seq-contains? full-window cabi.compiler-reg-id-r8)
        (reg.compiler-reg-id-seq-contains? full-window cabi.compiler-reg-id-rdi)))))

(cfg
  test
  (define (compiler-reg-many-call-live-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "many_call_live")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      6
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 9)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                1
                (ir.compiler-ir-test-symbol "side_effect_a")
                (ir.CompilerIrCallArgs.Nil)
                (ast.AstType.Unit))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Call
                  2
                  (ir.compiler-ir-test-symbol "side_effect_b")
                  (ir.CompilerIrCallArgs.Nil)
                  (ast.AstType.Unit))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Call
                    3
                    (ir.compiler-ir-test-symbol "side_effect_c")
                    (ir.CompilerIrCallArgs.Nil)
                    (ast.AstType.Unit))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Call
                      4
                      (ir.compiler-ir-test-symbol "side_effect_d")
                      (ir.CompilerIrCallArgs.Nil)
                      (ast.AstType.Unit))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Mov
                        5
                        (ir.CompilerIrValue.Var 0)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Return
                          (ir.CompilerIrMaybeValue.Some
                            (ir.CompilerIrValue.Var 5)))
                        (ir.compiler-ir-instr-seq-empty)))))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-call-span-counts-ok?) : bool
    (let
      [points : live.CompilerLiveI64Set (live.compiler-live-set4 2 4 6 8)]
      (and
        (= (reg.compiler-reg-call-set-count-in-range points 0 2) 0)
        (= (reg.compiler-reg-call-set-count-in-range points 0 3) 1)
        (= (reg.compiler-reg-call-set-count-in-range points 0 7) 3)
        (= (reg.compiler-reg-call-set-count-in-range points 0 9) 4)
        (= (reg.compiler-reg-call-set-count-in-range points 2 8) 2)))))

(cfg
  test
  (define (compiler-reg-call-span-census-count?
    [census : reg.CompilerRegCallSpanCensus]
    [bucket : i64]
    [outcome : i64]
    [want : i64]) : bool
    (= (reg.compiler-reg-call-span-census-count census bucket outcome) want)))

(cfg
  test
  (define (compiler-reg-call-span-census-ok?) : bool
    (let
      [zero-census : reg.CompilerRegCallSpanCensus
        (reg.compiler-reg-plan-call-span-census
          (compiler-reg-overlap-function)
          (reg.compiler-reg-plan-function-scalar
            (compiler-reg-overlap-function)))]
      [one-census : reg.CompilerRegCallSpanCensus
        (reg.compiler-reg-plan-call-span-census
          (compiler-reg-call-live-function)
          (reg.compiler-reg-plan-function-scalar
            (compiler-reg-call-live-function)))]
      [many-census : reg.CompilerRegCallSpanCensus
        (reg.compiler-reg-plan-call-span-census
          (compiler-reg-many-call-live-function)
          (reg.compiler-reg-plan-function-scalar
            (compiler-reg-many-call-live-function)))]
      (and
        (compiler-reg-call-span-census-count?
          zero-census
          0
          (reg.compiler-reg-call-span-outcome-register)
          7)
        (compiler-reg-call-span-census-count?
          zero-census
          0
          (reg.compiler-reg-call-span-outcome-spill)
          0)
        (compiler-reg-call-span-census-count?
          one-census
          1
          (reg.compiler-reg-call-span-outcome-register)
          1)
        (compiler-reg-call-span-census-count?
          one-census
          0
          (reg.compiler-reg-call-span-outcome-register)
          1)
        (compiler-reg-call-span-census-count?
          many-census
          3
          (reg.compiler-reg-call-span-outcome-register)
          1)
        (compiler-reg-call-span-census-count?
          many-census
          0
          (reg.compiler-reg-call-span-outcome-register)
          1)))))

(cfg
  test
  (define (compiler-reg-xmm-ownership-fixed-home
    [preassigned-reg : i64]
    [intervals : reg.CompilerRegIntervalSeq]
    [candidate-start : i64]
    [candidate-end : i64]
    [regs : reg.CompilerRegIdSeq]) : i64
    (let
      [index : reg.CompilerRegIntervalIndex
        (reg.compiler-reg-interval-index-build intervals 2)]
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-insert
          (reg.compiler-reg-assignment-table-make 2)
          0
          (reg.CompilerRegLocation.Register preassigned-reg))]
      [candidates : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 candidate-start candidate-end)
          (reg.compiler-reg-interval-seq-empty))]
      (match (reg.compiler-reg-assign-fixed-candidates
        candidates
        regs
        (reg.compiler-reg-active-seq-empty)
        assignments
        (__tl_make-array i64 0)
        index)
        [(reg.CompilerRegAssignState.State _ out)
          (match (reg.compiler-reg-assignment-table-lookup out 1)
            [(reg.CompilerRegMaybeLocation.Some location)
              (reg.compiler-reg-location-primary-register location)]
            [(reg.CompilerRegMaybeLocation.No) cabi.compiler-reg-id-invalid])]))))

(cfg
  test
  (define (compiler-reg-register-id-range-roundtrips?
    [reg-id : i64]
    [end : i64]) : bool
    (if (>= reg-id end)
      true
      (and
        (=
          (cabi.compiler-abi-register-id-from-spelling
            (cabi.compiler-abi-register-spelling reg-id))
          reg-id)
        (compiler-reg-register-id-range-roundtrips? (+ reg-id 1) end)))))

(cfg
  test
  (define (compiler-reg-canonical-register-ids-ok?) : bool
    (and
      ;; Every canonical ID round-trips through the cold spelling boundary.
      (compiler-reg-register-id-range-roundtrips?
        cabi.compiler-reg-id-rax
        (+ cabi.compiler-reg-id-r15 1))
      (compiler-reg-register-id-range-roundtrips?
        cabi.compiler-reg-id-xmm-base
        (+ cabi.compiler-reg-id-xmm-base cabi.compiler-reg-id-family-count))
      (compiler-reg-register-id-range-roundtrips?
        cabi.compiler-reg-id-vec-base
        (+ cabi.compiler-reg-id-vec-base cabi.compiler-reg-id-family-count))
      (compiler-reg-register-id-range-roundtrips?
        cabi.compiler-reg-id-mask-base
        (+ cabi.compiler-reg-id-mask-base cabi.compiler-reg-id-mask-count))
      ;; Constructors reject values outside their compact domains.
      (= (cabi.compiler-abi-xmm-register-id -1) cabi.compiler-reg-id-invalid)
      (= (cabi.compiler-abi-xmm-register-id 32) cabi.compiler-reg-id-invalid)
      (= (cabi.compiler-abi-vector-register-id -1) cabi.compiler-reg-id-invalid)
      (= (cabi.compiler-abi-vector-register-id 32) cabi.compiler-reg-id-invalid)
      (= (cabi.compiler-abi-mask-register-id -1) cabi.compiler-reg-id-invalid)
      (= (cabi.compiler-abi-mask-register-id 8) cabi.compiler-reg-id-invalid)
      ;; Width-specific vector spellings share ownership without losing class.
      (=
        (cabi.compiler-abi-register-id-from-spelling "%ymm31")
        (cabi.compiler-abi-vector-register-id 31))
      (=
        (cabi.compiler-abi-register-id-from-spelling "%zmm31")
        (cabi.compiler-abi-vector-register-id 31))
      (cabi.compiler-abi-registers-overlap?
        (cabi.compiler-abi-xmm-register-id 31)
        (cabi.compiler-abi-vector-register-id 31))
      (=
        (cabi.compiler-abi-register-with-vector-class
          (cabi.compiler-abi-xmm-register-id 31)
          true)
        (cabi.compiler-abi-vector-register-id 31))
      ;; ABI tables return canonical IDs, including their invalid boundaries.
      (=
        (cabi.compiler-abi-gp-arg-register-id
          (cabi.CompilerRegTargetAbi.Linux)
          0)
        cabi.compiler-reg-id-rdi)
      (=
        (cabi.compiler-abi-gp-arg-register-id
          (cabi.CompilerRegTargetAbi.Windows)
          3)
        cabi.compiler-reg-id-r9)
      (=
        (cabi.compiler-abi-float-arg-register-id
          (cabi.CompilerRegTargetAbi.Linux)
          7)
        (cabi.compiler-abi-xmm-register-id 7))
      (=
        (cabi.compiler-abi-callee-saved-xmm-register-id
          (cabi.CompilerRegTargetAbi.Windows)
          9)
        (cabi.compiler-abi-xmm-register-id 15))
      (=
        (cabi.compiler-abi-gp-arg-register-id
          (cabi.CompilerRegTargetAbi.Windows)
          4)
        cabi.compiler-reg-id-invalid)
      (=
        (cabi.compiler-abi-caller-saved-xmm-register-id
          (cabi.CompilerRegTargetAbi.Windows)
          6)
        cabi.compiler-reg-id-invalid))))

(cfg
  test
  (define (compiler-reg-xmm-ownership-intervals
    [pre-start : i64]
    [pre-end : i64]
    [candidate-start : i64]
    [candidate-end : i64]) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 pre-start pre-end)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 candidate-start candidate-end)
        (reg.compiler-reg-interval-seq-empty)))))

(cfg
  test
  (define (compiler-reg-xmm-ownership-segment-hole-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 0 2)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 3 5)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 0 6 8)
          (reg.compiler-reg-interval-seq-empty))))))

(cfg
  test
  (define (compiler-reg-xmm-physical-ownership-ok?) : bool
    (let
      [vector-pool : reg.CompilerRegIdSeq
        (reg.compiler-reg-id-seq-prepend
          (cabi.compiler-abi-vector-register-id 6)
          (reg.compiler-reg-id-seq-prepend
            (cabi.compiler-abi-vector-register-id 7)
            (reg.compiler-reg-id-seq-empty)))]
      [scalar-spelled-pool : reg.CompilerRegIdSeq
        (reg.compiler-reg-id-seq-prepend
          (cabi.compiler-abi-xmm-register-id 6)
          (reg.compiler-reg-id-seq-prepend
            (cabi.compiler-abi-xmm-register-id 7)
            (reg.compiler-reg-id-seq-empty)))]
      [overlap : reg.CompilerRegIntervalSeq
        (compiler-reg-xmm-ownership-intervals 0 8 2 6)]
      [boundary-reuse : reg.CompilerRegIntervalSeq
        (compiler-reg-xmm-ownership-intervals 0 2 2 6)]
      (and
        ;; AVX2/AVX-512 spellings and the width-neutral allocator home all own
        ;; the same physical register as an f32/f64 scalar XMM spelling.
        (reg.compiler-reg-registers-overlap?
          (cabi.compiler-abi-xmm-register-id 6)
          (cabi.compiler-abi-vector-register-id 6))
        (reg.compiler-reg-registers-overlap?
          (cabi.compiler-abi-xmm-register-id 6)
          (cabi.compiler-abi-register-id-from-spelling "%ymm6"))
        (reg.compiler-reg-registers-overlap?
          (cabi.compiler-abi-xmm-register-id 6)
          (cabi.compiler-abi-register-id-from-spelling "%zmm6"))
        (not
          (reg.compiler-reg-registers-overlap?
            (cabi.compiler-abi-xmm-register-id 6)
            (cabi.compiler-abi-vector-register-id 7)))
        (not
          (reg.compiler-reg-registers-overlap?
            (cabi.compiler-abi-xmm-register-id 6)
            (cabi.compiler-abi-mask-register-id 6)))
        (=
          (reg.compiler-reg-xmm-family-index
            (cabi.compiler-abi-xmm-register-id 13))
          13)
        (=
          (reg.compiler-reg-xmm-family-index
            (cabi.compiler-abi-register-id-from-spelling "%ymm13"))
          13)
        (=
          (reg.compiler-reg-xmm-family-index
            (cabi.compiler-abi-register-id-from-spelling "%zmm13"))
          13)
        (=
          (reg.compiler-reg-xmm-family-index
            (cabi.compiler-abi-vector-register-id 13))
          13)
        (=
          (reg.compiler-reg-xmm-family-index
            (cabi.compiler-abi-register-id-from-spelling "%xmm06"))
          -1)
        ;; Deliberate f32/f64-vs-vector collisions reject physical index 6 at
        ;; every emitted width and select the next vector home.
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-xmm-register-id 6)
            overlap
            2
            6
            vector-pool)
          (cabi.compiler-abi-vector-register-id 7))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-vector-register-id 6)
            overlap
            2
            6
            vector-pool)
          (cabi.compiler-abi-vector-register-id 7))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-vector-register-id 6)
            overlap
            2
            6
            vector-pool)
          (cabi.compiler-abi-vector-register-id 7))
        ;; Mask-on-vector allocation uses the same ownership query even when
        ;; the preassignment and candidate pools use opposite class spellings.
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-vector-register-id 6)
            overlap
            2
            6
            scalar-spelled-pool)
          (cabi.compiler-abi-xmm-register-id 7))
        ;; Touching ranges and a segmented phi/liveness hole may safely reuse
        ;; the physical register; real segment overlap still rejects it.
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-xmm-register-id 6)
            boundary-reuse
            2
            6
            vector-pool)
          (cabi.compiler-abi-vector-register-id 6))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-xmm-register-id 6)
            (compiler-reg-xmm-ownership-segment-hole-intervals)
            3
            5
            vector-pool)
          (cabi.compiler-abi-vector-register-id 6))))))

(cfg
  test
  (define (compiler-reg-dense-mask-on-vector-homes-ok?) : bool
    (let
      [list-func : ir.CompilerIrFunction (compiler-reg-mask-home-function)]
      [dense-func : ir.CompilerIrFunction
        (ir.compiler-ir-function-compact-blocks list-func)]
      [list-block-assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-plan-assignments
          (compiler-reg-plan-function-avx2 list-func))]
      [dense-assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-plan-assignments
          (compiler-reg-plan-function-avx2 dense-func))]
      (and
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup list-block-assignments 0)
          (cabi.compiler-abi-vector-register-id 6))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup list-block-assignments 1)
          (cabi.compiler-abi-vector-register-id 7))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup dense-assignments 0)
          (cabi.compiler-abi-vector-register-id 6))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup dense-assignments 1)
          (cabi.compiler-abi-vector-register-id 7))))))

(cfg
  test
  (define (compiler-reg-liveness-handle-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-edge-copy-linear-function)]
      [profile : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [metrics : profile_state.CompilerProfileMetrics
        (profile_state.compiler-profile-state-metrics profile)]
      [region : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-prepend
          (ir.compiler-ir-label "hot")
          (reg.compiler-reg-label-seq-empty))]
      (begin
        (reg.compiler-reg-liveness-census-reset! metrics)
        (let
          [handle : reg.CompilerRegLivenessHandle
            (reg.compiler-reg-liveness-handle-make func true metrics)]
          [liveness : live.CompilerFunctionLiveness handle.baseline]
          (and
            (match (reg.compiler-reg-edge-copy-plan-for-region-with-liveness
              liveness
              region
              0
              10
              (compiler-reg-i64-ty))
              [(reg.CompilerRegEdgeCopyPlan.Plan _) true]
              [(reg.CompilerRegEdgeCopyPlan.Refused _) false])
            (match (reg.compiler-reg-edge-copy-plan-for-region-with-liveness
              liveness
              region
              0
              11
              (compiler-reg-i64-ty))
              [(reg.CompilerRegEdgeCopyPlan.Plan _) true]
              [(reg.CompilerRegEdgeCopyPlan.Refused _) false])
            (= (reg.compiler-reg-liveness-census-baseline-count metrics) 1)
            ;; The linear fixture is phi-free, so the edge-precise analysis is
            ;; the baseline itself and no second fixpoint is computed.
            (= (reg.compiler-reg-liveness-census-edge-precise-count metrics) 0)))))))

(cfg
  test
  (define (compiler-reg-liveness-handle-phi-fixture) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "liveness_handle_phi")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      2
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "loop")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Phi
                1
                (ir.CompilerIrPhiInputList.Cons
                  (ir.CompilerIrValue.Var 0)
                  (ir.compiler-ir-label "entry")
                  (box
                    (ir.CompilerIrPhiInputList.Cons
                      (ir.CompilerIrValue.Var 1)
                      (ir.compiler-ir-label "loop")
                      (box ir.CompilerIrPhiInputList.Nil))))
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
                (ir.compiler-ir-instr-seq-empty))))
          ir.CompilerIrBlockList.Nil)))))

(cfg
  test
  (define (compiler-reg-liveness-handle-phi-ok?) : bool
    (let
      [profile : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [metrics : profile_state.CompilerProfileMetrics
        (profile_state.compiler-profile-state-metrics profile)]
      (begin
        (reg.compiler-reg-liveness-census-reset! metrics)
        (let
          [_handle : reg.CompilerRegLivenessHandle
            (reg.compiler-reg-liveness-handle-make
              (compiler-reg-liveness-handle-phi-fixture)
              true
              metrics)]
          (and
            (= (reg.compiler-reg-liveness-census-baseline-count metrics) 1)
            ;; Phi present: the second, edge-precise fixpoint is computed.
            (= (reg.compiler-reg-liveness-census-edge-precise-count metrics) 1)))))))

(cfg
  test
  (test
    compiler-reg-liveness-metrics-job-isolation
    (let
      [left-profile : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [right-profile : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [left : profile_state.CompilerProfileMetrics
        (profile_state.compiler-profile-state-metrics left-profile)]
      [right : profile_state.CompilerProfileMetrics
        (profile_state.compiler-profile-state-metrics right-profile)]
      (begin
        (reg.compiler-reg-liveness-census-reset! left)
        (reg.compiler-reg-liveness-census-reset! right)
        (let
          [_left : reg.CompilerRegLivenessHandle
            (reg.compiler-reg-liveness-handle-make
              (compiler-reg-liveness-handle-phi-fixture)
              true
              left)]
          [_right : reg.CompilerRegLivenessHandle
            (reg.compiler-reg-liveness-handle-make
              (compiler-reg-edge-copy-linear-function)
              true
              right)]
          (begin
            (test.assert-i64-eq
              (reg.compiler-reg-liveness-census-edge-precise-count left)
              1
              "left owner records edge-precise liveness")
            (test.assert-i64-eq
              (reg.compiler-reg-liveness-census-edge-precise-count right)
              0
              "right owner retains its serial result")
            (reg.compiler-reg-liveness-census-reset! left)
            (test.assert-i64-eq
              (reg.compiler-reg-liveness-census-baseline-count left)
              0
              "left reset clears only left baseline")
            (test.assert-i64-eq
              (reg.compiler-reg-liveness-census-baseline-count right)
              1
              "left reset leaves right baseline intact")))))))

(cfg
  test
  (define (compiler-reg-group-pair-test-fill-homes!
    [assignments : reg.CompilerRegAssignmentTable]
    [var : i64]
    [vars : i64]) : unit
    (if (or (>= var vars) (>= var 6))
      unit
      (let
        [_inserted : reg.CompilerRegAssignmentTable
          (reg.compiler-reg-assignment-table-insert
            assignments
            var
            (reg.CompilerRegLocation.Register
              (reg.compiler-reg-group-pair-csr (- var 1))))]
        (compiler-reg-group-pair-test-fill-homes! assignments (+ var 1) vars)))))

;; Keep the late pair pass honest without depending on an incidental whole
;; program's pressure shape. Cold scalars occupy every CSR so a call-spanning
;; component must evict two of them, while a clobber-free component keeps the
;; r8:r9 pair. A cold scalar in r8 proves caller-pair eviction, while a
;; synthetic call-save shadow reserves r8 over the same range. A normal-call
;; group argument stays eligible for a CSR pair, but not the caller pair,
;; until the multiword ABI marshaller can use the pair parallel-move solver.
(cfg
  test
  (define (compiler-reg-group-pair-widening-ok?) : bool
    (let
      [vars : i64 10]
      [interval-index : reg.CompilerRegIntervalIndex
        (reg.compiler-reg-interval-index-build
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 0 0 10)
            (reg.compiler-reg-interval-seq-prepend
              (reg.CompilerRegInterval 1 0 10)
              (reg.compiler-reg-interval-seq-prepend
                (reg.CompilerRegInterval 2 0 10)
                (reg.compiler-reg-interval-seq-prepend
                  (reg.CompilerRegInterval 3 0 10)
                  (reg.compiler-reg-interval-seq-prepend
                    (reg.CompilerRegInterval 4 0 10)
                    (reg.compiler-reg-interval-seq-prepend
                      (reg.CompilerRegInterval 5 0 10)
                      (reg.compiler-reg-interval-seq-prepend
                        (reg.CompilerRegInterval 6 0 10)
                        (reg.compiler-reg-interval-seq-prepend
                          (reg.CompilerRegInterval 7 0 10)
                          (reg.compiler-reg-interval-seq-prepend
                            (reg.CompilerRegInterval 8 0 10)
                            (reg.compiler-reg-interval-seq-prepend
                              (reg.CompilerRegInterval 9 0 10)
                              (reg.compiler-reg-interval-seq-empty)))))))))))
          vars)]
      [members : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [parents : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [poisoned : (__tl_dyn-array bool) (__tl_make-array bool vars)]
      [weights : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-make vars)]
      [csr-assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-make vars)]
      [caller-occupied : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-make vars)]
      [nonoccupying : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-make vars)]
      [shadow-regs : (__tl_dyn-array i64) (__tl_make-array i64 2)]
      (begin
        (reg.compiler-reg-fill-i64-array
          shadow-regs
          cabi.compiler-reg-id-invalid)
        (set! (array-ref members 0) 0)
        ;; Greedy worklist keys, not bare weights: the pair pass reads them
        ;; through compiler-reg-group-pair-weight, which strips the priority band
        ;; (compiler-reg-priority-keys!). Weights 1 and 10 on that scale.
        (reg.compiler-reg-fill-i64-array
          weights
          (reg.compiler-reg-priority-band-span))
        (set!
          (array-ref weights 0)
          (* 10 (reg.compiler-reg-priority-band-span)))
        (let
          [v : i64 0]
          (while (< v vars)
            (begin
              (set! (array-ref parents v) v)
              (set! (array-ref poisoned v) false)
              (set! v (+ v 1)))))
        (set! (array-ref shadow-regs 1) cabi.compiler-reg-id-r8)
        (compiler-reg-group-pair-test-fill-homes! assignments 1 vars)
        (compiler-reg-group-pair-test-fill-homes! csr-assignments 1 vars)
        (compiler-reg-group-pair-test-fill-homes! caller-occupied 1 vars)
        (let
          [_nonoccupying-spill : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-assignment-table-insert
              nonoccupying
              1
              (reg.CompilerRegLocation.Spill
                (reg.compiler-reg-stack-slot-offset 1)))]
          [_nonoccupying-pair : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-assignment-table-insert
              nonoccupying
              2
              (reg.CompilerRegLocation.RegisterPair
                cabi.compiler-reg-id-r12
                cabi.compiler-reg-id-r13))]
          [_caller-occupied-r8 : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-assignment-table-insert
              caller-occupied
              1
              (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r8))]
          [_caller-occupied-r12 : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-assignment-table-insert
              caller-occupied
              6
              (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
          [empty-split : reg.CompilerRegCallSplit
            (reg.compiler-reg-call-split-empty)]
          [shadow-split : reg.CompilerRegCallSplit
            (reg.CompilerRegCallSplit
              (live.compiler-live-set-empty)
              shadow-regs
              (reg.compiler-reg-call-region-seq-push
                (reg.compiler-reg-call-region-seq-empty)
                (reg.CompilerRegCallRegion 1 0 10 0 0))
              (reg.compiler-reg-call-evict-seq-empty))]
          [phi-excluded : live.CompilerLiveI64Set
            (reg.compiler-reg-group-pair-excluded-instr
              (live.compiler-live-set-empty)
              (ir.CompilerIrInstr.Phi
                0
                ir.CompilerIrPhiInputList.Nil
                (ast.AstType.Struct (ci.intern "Pair")))
              (live.compiler-live-set1 0))]
          [call-caller-unsafe : live.CompilerLiveI64Set
            (reg.compiler-reg-group-pair-caller-unsafe-instr
              (live.compiler-live-set-empty)
              (ir.CompilerIrInstr.Call
                1
                (ir.compiler-ir-test-symbol "callee")
                (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.Var 0))
                (ast.AstType.I64)))]
          [indirect-call-caller-unsafe : live.CompilerLiveI64Set
            (reg.compiler-reg-group-pair-caller-unsafe-instr
              (live.compiler-live-set-empty)
              (ir.CompilerIrInstr.CallIndirect
                1
                (ir.CompilerIrValue.Var 2)
                (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.Var 0))
                (ast.AstType.I64)))]
          [indirect-c-call-caller-unsafe : live.CompilerLiveI64Set
            (reg.compiler-reg-group-pair-caller-unsafe-instr
              (live.compiler-live-set-empty)
              (ir.CompilerIrInstr.CallIndirectC
                1
                (ir.CompilerIrValue.Var 2)
                (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.Var 0))
                (ast.AstType.I64)))]
          [pair-conflicts : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [pair-conflict-count : i64
            (reg.compiler-reg-group-pair-conflict-vars!
              interval-index
              members
              1
              vars
              pair-conflicts)]
          [shadow-cost : i64
            (reg.compiler-reg-group-pair-component-register-cost
              assignments
              interval-index
              members
              1
              pair-conflicts
              pair-conflict-count
              weights
              10
              true
              shadow-split
              cabi.compiler-reg-id-r8)]
          [free-r8-cost : i64
            (reg.compiler-reg-group-pair-component-register-cost
              nonoccupying
              interval-index
              members
              1
              pair-conflicts
              pair-conflict-count
              weights
              10
              true
              empty-split
              cabi.compiler-reg-id-r8)]
          [occupied-r8-cost : i64
            (reg.compiler-reg-group-pair-component-register-cost
              caller-occupied
              interval-index
              members
              1
              pair-conflicts
              pair-conflict-count
              weights
              10
              true
              empty-split
              cabi.compiler-reg-id-r8)]
          [csr-evict-cost : i64
            (reg.compiler-reg-group-pair-component-register-cost
              assignments
              interval-index
              members
              1
              pair-conflicts
              pair-conflict-count
              weights
              10
              false
              empty-split
              cabi.compiler-reg-id-r12)]
          [blocked-r12-cost : i64
            (reg.compiler-reg-group-pair-component-register-cost
              nonoccupying
              interval-index
              members
              1
              pair-conflicts
              pair-conflict-count
              weights
              10
              false
              empty-split
              cabi.compiler-reg-id-r12)]
          (let
            [_caller-placed : unit
              (reg.compiler-reg-assign-group-pair-component
                (ast.ast-node-pool-reader-type-segment-bases)
                0
                vars
                (compiler-reg-coalesce-test-i64-types vars)
                (live.compiler-live-set1 0)
                (live.compiler-live-set-empty)
                (live.compiler-live-set-empty)
                interval-index.starts
                interval-index.ends
                poisoned
                parents
                members
                interval-index
                caller-occupied
                weights
                (live.compiler-live-set-empty)
                empty-split)]
            [_csr-placed : unit
              (reg.compiler-reg-assign-group-pair-component
                (ast.ast-node-pool-reader-type-segment-bases)
                0
                vars
                (compiler-reg-coalesce-test-i64-types vars)
                (live.compiler-live-set1 0)
                (live.compiler-live-set-empty)
                (live.compiler-live-set1 0)
                interval-index.starts
                interval-index.ends
                poisoned
                parents
                members
                interval-index
                csr-assignments
                weights
                (live.compiler-live-set-empty)
                empty-split)]
            [_placed : unit
              (reg.compiler-reg-assign-group-pair-component
                (ast.ast-node-pool-reader-type-segment-bases)
                0
                vars
                (compiler-reg-coalesce-test-i64-types vars)
                (live.compiler-live-set1 0)
                (live.compiler-live-set-empty)
                (live.compiler-live-set-empty)
                interval-index.starts
                interval-index.ends
                poisoned
                parents
                members
                interval-index
                assignments
                weights
                (live.compiler-live-set-empty)
                empty-split)]
            (and
              (= (reg.compiler-reg-group-pair-candidate-count true) 7)
              (=
                (reg.compiler-reg-group-pair-candidate true 0)
                cabi.compiler-reg-id-r8)
              (=
                (reg.compiler-reg-group-pair-candidate true 1)
                cabi.compiler-reg-id-r9)
              (=
                (reg.compiler-reg-group-pair-candidate true 2)
                cabi.compiler-reg-id-r12)
              (= (reg.compiler-reg-group-pair-candidate-count false) 5)
              (=
                (reg.compiler-reg-group-pair-candidate false 0)
                cabi.compiler-reg-id-r12)
              (reg.compiler-reg-group-pair-component-clobber-free?
                interval-index
                (live.compiler-live-set-empty)
                members
                1)
              (not
                (reg.compiler-reg-group-pair-component-clobber-free?
                  interval-index
                  (live.compiler-live-set1 5)
                  members
                  1))
              (not (live.compiler-live-set-contains? phi-excluded 0))
              (live.compiler-live-set-contains? call-caller-unsafe 0)
              (live.compiler-live-set-contains? indirect-call-caller-unsafe 0)
              (live.compiler-live-set-contains? indirect-c-call-caller-unsafe 0)
              (reg.compiler-reg-group-pair-component-contains?
                call-caller-unsafe
                members
                1)
              (= shadow-cost (- 0 1))
              (= free-r8-cost 0)
              (> occupied-r8-cost 0)
              (> csr-evict-cost 0)
              (= blocked-r12-cost (- 0 1))
              (match (reg.compiler-reg-assignment-table-lookup assignments 0)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.RegisterPair first second)
                      (and
                        (= first cabi.compiler-reg-id-r8)
                        (= second cabi.compiler-reg-id-r9))]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup assignments 1)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.Register reg)
                      (= reg cabi.compiler-reg-id-r12)]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup
                caller-occupied
                0)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.RegisterPair first second)
                      (and
                        (= first cabi.compiler-reg-id-r8)
                        (= second cabi.compiler-reg-id-r9))]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup
                caller-occupied
                1)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.Spill _) true]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup
                csr-assignments
                0)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.RegisterPair first second)
                      (and
                        (= first cabi.compiler-reg-id-r12)
                        (= second cabi.compiler-reg-id-r13))]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup
                csr-assignments
                1)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.Spill _) true]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup
                csr-assignments
                2)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.Spill _) true]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false]))))))))

(cfg
  test
  (define (compiler-reg-test-interval-shape?
    [items : reg.CompilerRegIntervalSeq]
    [index : i64]
    [var : i64]
    [start : i64]
    [end : i64]) : bool
    (let
      [got : reg.CompilerRegInterval
        (reg.compiler-reg-interval-seq-ref items index)]
      (and (= got.var var) (= got.start start) (= got.end end)))))

(cfg
  test
  (define (compiler-reg-dense-interval-seq-ok?) : bool
    (let
      [appended : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [prepended : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [inserted : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [separated-left : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [separated-right : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [late-overlap-right : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [zero-left : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [zero-right : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [i : i64 0]
      (begin
        ;; Cross several capacity boundaries in both construction directions.
        (while (< i 10)
          (begin
            (set!
              appended
              (reg.compiler-reg-interval-seq-append
                appended
                (reg.CompilerRegInterval i (* i 2) (+ (* i 2) 1))))
            (set!
              prepended
              (reg.compiler-reg-interval-seq-prepend
                (reg.CompilerRegInterval i (* i 2) (+ (* i 2) 1))
                prepended))
            (set! i (+ i 1))))
        (set!
          inserted
          (reg.compiler-reg-interval-seq-append
            inserted
            (reg.CompilerRegInterval 0 0 1)))
        (set!
          inserted
          (reg.compiler-reg-interval-seq-append
            inserted
            (reg.CompilerRegInterval 2 4 5)))
        (set!
          inserted
          (reg.compiler-reg-interval-seq-append
            inserted
            (reg.CompilerRegInterval 1 2 3)))
        (set! inserted (reg.compiler-reg-candidate-sort inserted))
        (set!
          separated-left
          (reg.compiler-reg-interval-seq-append
            separated-left
            (reg.CompilerRegInterval 0 1 2)))
        (set!
          separated-left
          (reg.compiler-reg-interval-seq-append
            separated-left
            (reg.CompilerRegInterval 0 6 8)))
        (set!
          separated-left
          (reg.compiler-reg-interval-seq-append
            separated-left
            (reg.CompilerRegInterval 0 12 15)))
        (set!
          separated-right
          (reg.compiler-reg-interval-seq-append
            separated-right
            (reg.CompilerRegInterval 1 2 4)))
        (set!
          separated-right
          (reg.compiler-reg-interval-seq-append
            separated-right
            (reg.CompilerRegInterval 1 8 10)))
        (set!
          separated-right
          (reg.compiler-reg-interval-seq-append
            separated-right
            (reg.CompilerRegInterval 1 15 18)))
        (set!
          late-overlap-right
          (reg.compiler-reg-interval-seq-append
            late-overlap-right
            (reg.CompilerRegInterval 1 2 4)))
        (set!
          late-overlap-right
          (reg.compiler-reg-interval-seq-append
            late-overlap-right
            (reg.CompilerRegInterval 1 8 10)))
        (set!
          late-overlap-right
          (reg.compiler-reg-interval-seq-append
            late-overlap-right
            (reg.CompilerRegInterval 1 14 18)))
        (set!
          zero-left
          (reg.compiler-reg-interval-seq-append
            zero-left
            (reg.CompilerRegInterval 0 0 0)))
        (set!
          zero-right
          (reg.compiler-reg-interval-seq-append
            zero-right
            (reg.CompilerRegInterval 1 0 2)))
        (and
          (= (reg.compiler-reg-interval-seq-count appended) 10)
          (compiler-reg-test-interval-shape? appended 0 0 0 1)
          (compiler-reg-test-interval-shape? appended 9 9 18 19)
          (= (reg.compiler-reg-interval-seq-count prepended) 10)
          (compiler-reg-test-interval-shape? prepended 0 9 18 19)
          (compiler-reg-test-interval-shape? prepended 9 0 0 1)
          (= (reg.compiler-reg-interval-seq-count inserted) 3)
          (compiler-reg-test-interval-shape? inserted 0 0 0 1)
          (compiler-reg-test-interval-shape? inserted 1 1 2 3)
          (compiler-reg-test-interval-shape? inserted 2 2 4 5)
          ;; Touching boundaries after point zero remain non-overlapping.
          (not
            (reg.compiler-reg-interval-seq-overlaps?
              separated-left
              separated-right))
          ;; The ordered scan must continue far enough to find a late overlap.
          (reg.compiler-reg-interval-seq-overlaps?
            separated-left
            late-overlap-right)
          (not
            (reg.compiler-reg-interval-seq-overlaps-one?
              separated-left
              (reg.CompilerRegInterval 2 4 6)))
          ;; Entry-point touches preserve the prologue-home exception.
          (reg.compiler-reg-interval-seq-overlaps? zero-left zero-right))))))

(cfg
  test
  (test
    regalloc-dense-interval-sequence
    (test.assert-true
      (compiler-reg-dense-interval-seq-ok?)
      "dense interval growth preserves order and merge overlap boundaries")))

(cfg
  test
  (define (compiler-reg-dense-id-label-seqs-ok?) : bool
    (let
      [ids : reg.CompilerRegIdSeq (reg.compiler-reg-id-seq-with-capacity 4)]
      [id-snapshot : reg.CompilerRegIdSeq (reg.compiler-reg-id-seq-empty)]
      [id-prepended : reg.CompilerRegIdSeq (reg.compiler-reg-id-seq-empty)]
      [labels : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-with-capacity 4)]
      [label-snapshot : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-empty)]
      [entry-label : i64 (ir.compiler-ir-label "dense_seq_entry")]
      [body-label : i64 (ir.compiler-ir-label "dense_seq_body")]
      (begin
        (set! ids (reg.compiler-reg-id-seq-push ids cabi.compiler-reg-id-r12))
        (set! ids (reg.compiler-reg-id-seq-push ids cabi.compiler-reg-id-r13))
        ;; A retained snapshot has an exact logical length and prefix even while
        ;; the continuing builder fills its spare suffix.
        (set! id-snapshot (clone ids))
        (set! ids (reg.compiler-reg-id-seq-push ids cabi.compiler-reg-id-r12))
        (set!
          id-prepended
          (reg.compiler-reg-id-seq-prepend cabi.compiler-reg-id-rbx id-snapshot))
        (set! labels (reg.compiler-reg-label-seq-push labels entry-label))
        (set! labels (reg.compiler-reg-label-seq-push labels body-label))
        (set! label-snapshot (clone labels))
        (set! labels (reg.compiler-reg-label-seq-push labels entry-label))
        (and
          (= (reg.compiler-reg-id-seq-count id-snapshot) 2)
          (=
            (reg.compiler-reg-id-seq-ref id-snapshot 0)
            cabi.compiler-reg-id-r12)
          (=
            (reg.compiler-reg-id-seq-ref id-snapshot 1)
            cabi.compiler-reg-id-r13)
          (= (reg.compiler-reg-id-seq-count ids) 3)
          ;; Duplicate register IDs remain ordered rather than being setified.
          (= (reg.compiler-reg-id-seq-ref ids 2) cabi.compiler-reg-id-r12)
          (reg.compiler-reg-id-seq-contains? ids cabi.compiler-reg-id-r13)
          (= (reg.compiler-reg-id-seq-count id-prepended) 3)
          (=
            (reg.compiler-reg-id-seq-ref id-prepended 0)
            cabi.compiler-reg-id-rbx)
          (=
            (reg.compiler-reg-id-seq-ref id-prepended 1)
            cabi.compiler-reg-id-r12)
          (=
            (reg.compiler-reg-id-seq-ref id-prepended 2)
            cabi.compiler-reg-id-r13)
          (= (reg.compiler-reg-label-seq-count label-snapshot) 2)
          (= (reg.compiler-reg-label-seq-ref label-snapshot 0) entry-label)
          (= (reg.compiler-reg-label-seq-ref label-snapshot 1) body-label)
          (= (reg.compiler-reg-label-seq-count labels) 3)
          (= (reg.compiler-reg-label-seq-ref labels 2) entry-label)
          (reg.compiler-reg-label-seq-contains? labels body-label))))))

(cfg
  test
  (test
    regalloc-dense-register-and-label-sequences
    (test.assert-true
      (compiler-reg-dense-id-label-seqs-ok?)
      "dense register and label sequences preserve snapshots, order, and duplicates")))

(cfg
  test
  (define (compiler-reg-dense-var-types-ok?) : bool
    (let
      [base : reg.CompilerRegVarTypes
        (reg.compiler-reg-var-types-insert
          (reg.compiler-reg-var-types-insert
            (reg.compiler-reg-var-types-empty)
            2
            (ast.AstType.I64))
          5
          (ast.AstType.U64))]
      [extra : reg.CompilerRegVarTypes
        (reg.compiler-reg-var-types-insert
          (reg.compiler-reg-var-types-empty)
          5
          (ast.AstType.Bool))]
      [merged : reg.CompilerRegVarTypes
        (reg.compiler-reg-var-types-merge extra base)]
      (and
        (= (array-ref base.present 2) 1)
        (= (array-ref base.present 3) 0)
        (match (reg.compiler-reg-var-types-lookup base 2)
          [(reg.CompilerRegMaybeType.Some (ast.AstType.I64)) true]
          [_ false])
        (match (reg.compiler-reg-var-types-lookup base 3)
          [(reg.CompilerRegMaybeType.No) true]
          [_ false])
        ;; Merge overrides a present extra entry without mutating the published
        ;; base view retained by retry paths.
        (match (reg.compiler-reg-var-types-lookup base 5)
          [(reg.CompilerRegMaybeType.Some (ast.AstType.U64)) true]
          [_ false])
        (match (reg.compiler-reg-var-types-lookup merged 5)
          [(reg.CompilerRegMaybeType.Some (ast.AstType.Bool)) true]
          [_ false])))))

(cfg
  test
  (test
    regalloc-dense-var-types
    (test.assert-true
      (compiler-reg-dense-var-types-ok?)
      "dense var types preserve holes, exact types, growth, and merge isolation")))

(cfg
  test
  (test
    regalloc-call-word-in-range-matches-walk
    (test.assert-true
      (compiler-reg-call-word-in-range-matches-walk?)
      "mask range test agrees with the bit walk it replaced, high bits included")))

(cfg
  test
  (test
    regalloc-canonical-register-ids
    (test.assert-true
      (compiler-reg-canonical-register-ids-ok?)
      "canonical GP/vector/mask IDs round-trip, alias, and follow both ABIs")))

(cfg
  test
  (test
    regalloc-xmm-physical-ownership
    (test.assert-true
      (compiler-reg-xmm-physical-ownership-ok?)
      "XMM-family physical ownership rejects overlap and permits liveness holes")))

(cfg
  test
  (test
    regalloc-xmm-dense-mask-on-vector
    (test.assert-true
      (compiler-reg-dense-mask-on-vector-homes-ok?)
      "dense/list mask-on-vector allocation keeps canonical XMM ownership")))

(cfg
  test
  (test
    regalloc-xmm-abi-pools
    (test.assert-true
      (and
        (compiler-reg-xmm-clobbers-ok?)
        (compiler-reg-low-xmm-vector-boundaries-ok?))
      "ABI pools admit scalar XMM0/XMM1 while vector scratch boundaries stay explicit")))

(cfg
  test
  (test
    regalloc-xmm-abi-call-constraints
    (test.assert-true
      (and
        (compiler-reg-xmm-abi-call-constraints-ok?)
        (compiler-reg-xmm-shared-greedy-bank-ok?)
        (compiler-reg-xmm-vector-class-reset-ok?))
      "ABI XMM pools enforce SysV volatile and Win64 nonvolatile call homes")))

(cfg
  test
  (test
    regalloc-vector-mask-homes
    (test.assert-true
      (and
        (compiler-reg-vector-mask-homes-ok?)
        (compiler-reg-mask-pressure-spill-home-ok?))
      "expanded vector/mask pools preserve homes and spill excess k-mask pressure")))

(cfg
  test
  (test
    regalloc-self-loop-exit-live-phi
    (test.assert-true
      (and
        (compiler-reg-self-loop-exit-live-phi-mask-ok?)
        (compiler-reg-self-loop-counter-coalesce-plan-ok?)
        (compiler-reg-self-loop-counter-negative-masks-ok?))
      "self-loop safety admits accumulator and counter webs, refuses a phi result read past its increment, and ignores successor order")))

(cfg
  test
  (test
    regalloc-destructive-chain
    (test.assert-true
      (compiler-reg-destructive-chain-ok?)
      "bounded destructive ties coalesce lhs/rhs chains and refuse clobber/noncomm-rhs/div")))

(cfg
  test
  (test
    regalloc-alu-load-lhs-tie
    (test.assert-true
      (compiler-reg-alu-load-lhs-tie-ok?)
      "a commutative binop with a single-use fused load on the lhs ties its dst to the rhs, and double-use/non-commutative/pair shapes keep the lhs tie")))

(cfg
  test
  (test
    regalloc-scalar-web-merge
    (test.assert-true
      (compiler-reg-color-web-merge-ok?)
      "order-independent webs merge a disjoint carry chain into one slot and still refuse an overlap")))

(cfg
  test
  (test
    regalloc-scalar-web-carry-priority
    (test.assert-true
      (compiler-reg-color-carry-priority-ok?)
      "a phi dst joins the loop carry's web rather than an interfering computed source")))

(cfg
  test
  (test
    regalloc-scalar-web-step-witness
    (test.assert-true
      (compiler-reg-color-step-witness-ok?)
      "an induction step joins its counter's web on the same witness a Mov gets, and a counter that outlives the step is refused")))

(cfg
  test
  (test
    regalloc-scalar-web-witness-chain
    (test.assert-true
      (compiler-reg-color-witness-chain-ok?)
      "a chain of witnessed touches collapses into one slot, and a step that outlives its copy is refused")))

;; M-B2 scalar phi-web slot sharing. Both cases hand the colorer the SAME plan
;; intervals -- deliberately overlapping, which is what the conservative model
;; produces for a phi and its input, because it counts the input as live AT the
;; phi block -- so only the block shape decides. `entry` defines the input and
;; `merge`'s phi consumes it: with the input dead after the phi the two
;; edge-precise hulls are strictly ordered and one slot serves both; with the
;; input still live past the phi they genuinely interfere and keep two slots.
(cfg
  test
  (define (compiler-reg-color-phi-web-blocks [live-after-phi : bool]) : ir.CompilerIrBlockList
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            1
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge"))
            (ir.compiler-ir-instr-seq-empty))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "merge")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.Var 1)
                (ir.compiler-ir-label "entry")
                ir.CompilerIrPhiInputList.Nil)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some
                  (ir.CompilerIrValue.Var
                    (if live-after-phi
                      1
                      0))))
              (ir.compiler-ir-instr-seq-empty))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-color-phi-web-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 1 0 6)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 4 6)
        (reg.compiler-reg-interval-seq-empty)))))

(cfg
  test
  (define (compiler-reg-color-phi-web-coloring [live-after-phi : bool]) : reg.CompilerRegColoring
    (reg.compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (reg.CompilerRegPlan.Plan
        (compiler-reg-color-spill-sharing-assignments 2)
        (live.compiler-live-set-empty)
        (compiler-reg-color-phi-web-intervals)
        (compiler-reg-color-spill-sharing-types 2)
        (reg.compiler-reg-call-split-empty)
        (reg.compiler-reg-split-plan-empty))
      (live.compiler-live-set-empty)
      ir.CompilerIrParamList.Nil
      (compiler-reg-color-phi-web-blocks live-after-phi)
      2
      2
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-phi-web-slot-sharing-ok?) : bool
    (match (compiler-reg-color-phi-web-coloring false)
      [(reg.CompilerRegColoring.Remap share-remap share-slots)
        (match (compiler-reg-color-phi-web-coloring true)
          [(reg.CompilerRegColoring.Remap live-remap live-slots)
            (and
              (= share-slots 1)
              (= (array-ref share-remap 0) (array-ref share-remap 1))
              (= live-slots 2)
              (not (= (array-ref live-remap 0) (array-ref live-remap 1))))]
          [(reg.CompilerRegColoring.None) false])]
      [(reg.CompilerRegColoring.None) false])))

;; M-B3 order-independent web construction. The loop below is the shape every
;; spilled loop carry in intern_table's it-intern-slice has: a header phi (%0)
;; fed by an entry constant (%3) and by a latch phi (%2), with a third phi (%1)
;; on the path between them. All four EP hulls are pairwise disjoint --
;; %3 dies in `entry`, %0 in `body`, %1 in `merge`, %2 in `latch` -- so ONE slot
;; serves the whole chain.
;;
;; The pre-M-B3 monotone rule could not see that. Visiting `header` first it
;; joined %2 to %0 (the only pair whose hulls are ordered the way the rule
;; wanted), which pushed the web's running end out to %2's; %3 and %1 both start
;; before that end and were refused even though neither overlaps anything in the
;; web, and %1's own web could never be joined to a second web anyway. Result: 3
;; slots and two surviving slot-to-slot phi copies per iteration. With all-pairs
;; disjointness plus web-to-web merging the chain collapses to 1 slot.
;;
;; `overlap` injects a genuine interference to prove the test still refuses: the
;; exit returns %1, so %1 stays live from `merge` past `latch` and really does
;; overlap %2. %1 must then keep its own slot.
(cfg
  test
  (define (compiler-reg-color-web-merge-blocks [overlap : bool]) : ir.CompilerIrBlockList
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            3
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
            (ir.compiler-ir-instr-seq-empty))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "header")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.Var 2)
                (ir.compiler-ir-label "latch")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 3)
                  (ir.compiler-ir-label "entry")
                  ir.CompilerIrPhiInputList.Nil))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 0)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "body")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "merge")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Phi
                  1
                  (ir.compiler-ir-phi-input-cons
                    (ir.CompilerIrValue.Var 0)
                    (ir.compiler-ir-label "body")
                    ir.CompilerIrPhiInputList.Nil)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                  (ir.compiler-ir-instr-seq-empty))))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "latch")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Phi
                    2
                    (ir.compiler-ir-phi-input-cons
                      (ir.CompilerIrValue.Var 1)
                      (ir.compiler-ir-label "merge")
                      ir.CompilerIrPhiInputList.Nil)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                    (ir.compiler-ir-instr-seq-empty))))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "exit")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some
                        (if overlap
                          (ir.CompilerIrValue.Var 1)
                          (ir.CompilerIrValue.I64 0))))
                    (ir.compiler-ir-instr-seq-empty)))
                ir.CompilerIrBlockList.Nil))))))))

;; Deliberately overlapping conservative intervals, as in the M-B2 fixture above:
;; the ordinary disjoint-interval walk can share nothing, so every merge in the
;; result is the web logic's doing.
(cfg
  test
  (define (compiler-reg-color-web-merge-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 0 9)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 1 9)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 2 2 9)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 3 3 9)
            (reg.compiler-reg-interval-seq-empty)))))))

(cfg
  test
  (define (compiler-reg-color-web-merge-coloring [overlap : bool]) : reg.CompilerRegColoring
    (reg.compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (reg.CompilerRegPlan.Plan
        (compiler-reg-color-spill-sharing-assignments 4)
        (live.compiler-live-set-empty)
        (compiler-reg-color-web-merge-intervals)
        (compiler-reg-color-spill-sharing-types 4)
        (reg.compiler-reg-call-split-empty)
        (reg.compiler-reg-split-plan-empty))
      (live.compiler-live-set-empty)
      ir.CompilerIrParamList.Nil
      (compiler-reg-color-web-merge-blocks overlap)
      4
      4
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-web-merge-ok?) : bool
    (match (compiler-reg-color-web-merge-coloring false)
      [(reg.CompilerRegColoring.Remap merged-remap merged-slots)
        (match (compiler-reg-color-web-merge-coloring true)
          [(reg.CompilerRegColoring.Remap overlap-remap overlap-slots)
            (and
              ;; Disjoint chain: entry constant, header phi, mid phi and latch
              ;; phi all share ONE slot.
              (= merged-slots 1)
              (= (array-ref merged-remap 0) (array-ref merged-remap 1))
              (= (array-ref merged-remap 0) (array-ref merged-remap 2))
              (= (array-ref merged-remap 0) (array-ref merged-remap 3))
              ;; Genuine interference still refuses: %1 outlives %2's definition.
              (> overlap-slots 1)
              (not (= (array-ref overlap-remap 1) (array-ref overlap-remap 2))))]
          [(reg.CompilerRegColoring.None) false])]
      [(reg.CompilerRegColoring.None) false])))

;; The induction-step witness. Same fixture idea as the web-merge case above, cut
;; down to the counter itself: `%0 = phi(%2 entry, %1 latch)` with the back-edge
;; value produced by `%1 = %0 + 1` -- a BinOp, which is what every counted loop
;; writes and what the Mov-only witness could not see. The two hulls TOUCH at the
;; step (the counter's last event and the step's definition are the same
;; instruction), so the all-pairs disjointness rule refuses them and the pair used
;; to cost a second slot plus a slot-to-slot phi copy on the back edge.
;;
;; `outlives` is the negative: `exit` returns the COUNTER, so %0's hull runs past
;; the step into a later block and the equality that carries the witness no longer
;; holds. The step must then keep its own slot -- exactly the case where sharing
;; one home would clobber a value still to be read.
(cfg
  test
  (define (compiler-reg-color-step-witness-blocks [outlives : bool]) : ir.CompilerIrBlockList
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            2
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
            (ir.compiler-ir-instr-seq-empty))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "header")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.Var 1)
                (ir.compiler-ir-label "latch")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 2)
                  (ir.compiler-ir-label "entry")
                  ir.CompilerIrPhiInputList.Nil))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 0)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "body")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                1
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.I64 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "latch")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some
                      (if outlives
                        (ir.CompilerIrValue.Var 0)
                        (ir.CompilerIrValue.I64 0))))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

;; Deliberately overlapping conservative intervals again: the ordinary
;; disjoint-interval walk can share nothing, so any sharing is the web logic's.
(cfg
  test
  (define (compiler-reg-color-step-witness-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 0 9)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 1 9)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 2 2 9)
          (reg.compiler-reg-interval-seq-empty))))))

(cfg
  test
  (define (compiler-reg-color-step-witness-coloring [outlives : bool]) : reg.CompilerRegColoring
    (reg.compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (reg.CompilerRegPlan.Plan
        (compiler-reg-color-spill-sharing-assignments 3)
        (live.compiler-live-set-empty)
        (compiler-reg-color-step-witness-intervals)
        (compiler-reg-color-spill-sharing-types 3)
        (reg.compiler-reg-call-split-empty)
        (reg.compiler-reg-split-plan-empty))
      (live.compiler-live-set-empty)
      ir.CompilerIrParamList.Nil
      (compiler-reg-color-step-witness-blocks outlives)
      3
      3
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-step-witness-ok?) : bool
    (match (compiler-reg-color-step-witness-coloring false)
      [(reg.CompilerRegColoring.Remap step-remap step-slots)
        (match (compiler-reg-color-step-witness-coloring true)
          [(reg.CompilerRegColoring.Remap live-remap live-slots)
            (and
              ;; Counter, its step and the entry seed all share ONE slot, so the
              ;; back-edge phi copy is a same-home no-op.
              (= step-slots 1)
              (= (array-ref step-remap 0) (array-ref step-remap 1))
              (= (array-ref step-remap 0) (array-ref step-remap 2))
              ;; A counter still live past its step keeps its own home.
              (> live-slots 1)
              (not (= (array-ref live-remap 0) (array-ref live-remap 1))))]
          [(reg.CompilerRegColoring.None) false])]
      [(reg.CompilerRegColoring.None) false])))

;; R4-C: the witness RELATION, not a single witnessed pair. Modelled on
;; intern_table's it-bench accumulator block:
;;
;;   header: %0 = phi [%3 latch], [%4 entry]     the carry
;;   body:   %1 = mul %0, 3                      witness (%0 -> %1)
;;           %2 = add %1, 5                      witness (%1 -> %2)
;;           %3 = mov %2                         witness (%2 -> %3)
;;
;; The phi visit joins %3 to the carry first, so when %2 is offered through the
;; ADD witness the all-pairs walk meets the %2/%3 touch -- a pair with a witness
;; of its own, but not the one being offered. The old single-pair rule refused
;; it there, and offering %2 again through the MOV witness met the %1/%2 touch
;; and refused it again, so the add's result took a second slot and the block
;; stored one register to two slots every iteration.
;;
;; `outlives` is the negative: `exit` returns %2, so %2 is still live where %3
;; is defined, the endpoint equality that carries the witness no longer holds,
;; and %2 must keep its own home.
(cfg
  test
  (define (compiler-reg-color-witness-chain-blocks [outlives : bool]) : ir.CompilerIrBlockList
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            4
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
            (ir.compiler-ir-instr-seq-empty))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "header")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.Var 3)
                (ir.compiler-ir-label "latch")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 4)
                  (ir.compiler-ir-label "entry")
                  ir.CompilerIrPhiInputList.Nil))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 0)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "body")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                1
                (ir.CompilerIrBinOp.Mul)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.I64 3)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  2
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 1)
                  (ir.CompilerIrValue.I64 5)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    3
                    (ir.CompilerIrValue.Var 2)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                    (ir.compiler-ir-instr-seq-empty))))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "latch")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "exit")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some
                      (if outlives
                        (ir.CompilerIrValue.Var 2)
                        (ir.CompilerIrValue.I64 0))))
                  (ir.compiler-ir-instr-seq-empty)))
              ir.CompilerIrBlockList.Nil)))))))

;; Deliberately overlapping conservative intervals, as in the fixtures above:
;; the ordinary disjoint-interval walk can share nothing, so every merge in the
;; result is the web logic's doing.
(cfg
  test
  (define (compiler-reg-color-witness-chain-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 0 20)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 1 20)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 2 2 20)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 3 3 20)
            (reg.compiler-reg-interval-seq-prepend
              (reg.CompilerRegInterval 4 4 20)
              (reg.compiler-reg-interval-seq-empty))))))))

(cfg
  test
  (define (compiler-reg-color-witness-chain-coloring [outlives : bool]) : reg.CompilerRegColoring
    (reg.compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (reg.CompilerRegPlan.Plan
        (compiler-reg-color-spill-sharing-assignments 5)
        (live.compiler-live-set-empty)
        (compiler-reg-color-witness-chain-intervals)
        (compiler-reg-color-spill-sharing-types 5)
        (reg.compiler-reg-call-split-empty)
        (reg.compiler-reg-split-plan-empty))
      (live.compiler-live-set-empty)
      ir.CompilerIrParamList.Nil
      (compiler-reg-color-witness-chain-blocks outlives)
      5
      5
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-witness-chain-ok?) : bool
    (match (compiler-reg-color-witness-chain-coloring false)
      [(reg.CompilerRegColoring.Remap chain-remap chain-slots)
        (match (compiler-reg-color-witness-chain-coloring true)
          [(reg.CompilerRegColoring.Remap live-remap live-slots)
            (and
              ;; Seed, carry, both steps and the back-edge copy share ONE slot.
              (= chain-slots 1)
              (= (array-ref chain-remap 0) (array-ref chain-remap 1))
              (= (array-ref chain-remap 0) (array-ref chain-remap 2))
              (= (array-ref chain-remap 0) (array-ref chain-remap 3))
              (= (array-ref chain-remap 0) (array-ref chain-remap 4))
              ;; A step still live where the copy is defined keeps its own home.
              (> live-slots 1)
              (not (= (array-ref live-remap 2) (array-ref live-remap 3))))]
          [(reg.CompilerRegColoring.None) false])]
      [(reg.CompilerRegColoring.None) false])))

;; M-B3 loop-carry priority. `merge`'s phi (%2) sits in the MIDDLE of the carry
;; chain -- `header`'s phi (%0) is fed by the latch phi (%3), not by %2 -- so when
;; `merge` is visited %2 is still a fresh singleton and both of its sources are
;; live candidates. It can join the web of either, but not both: the carry %0 is
;; live through `right` to feed %2 while the computed %1 is defined in `left`, so
;; %0 and %1 overlap. The input list names the COMPUTED source first, so a single
;; in-order pass takes %1 -- and the carry then pays a slot-to-slot copy on the
;; `right` edge, on the latch edge and on the back edge. Offering phi-defined
;; sources first puts %2 in the CARRY's web instead, collapsing the whole chain.
;; Exactly the `%208 = phi [%187, if_else.36], [%210, if_then.35]` decision in
;; it-intern-slice, where %187 is an `add` that overlaps the carry %210.
(cfg
  test
  (define (compiler-reg-color-carry-priority-blocks) : ir.CompilerIrBlockList
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            4
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
            (ir.compiler-ir-instr-seq-empty))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "header")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.Var 3)
                (ir.compiler-ir-label "latch")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 4)
                  (ir.compiler-ir-label "entry")
                  ir.CompilerIrPhiInputList.Nil))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 0)
                (ir.compiler-ir-label "left")
                (ir.compiler-ir-label "right"))
              (ir.compiler-ir-instr-seq-empty))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "left")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 9)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge"))
                (ir.compiler-ir-instr-seq-empty))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "right")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge"))
                (ir.compiler-ir-instr-seq-empty)))
            (ir.compiler-ir-block-cons
              (ir.CompilerIrBlock.Block
                (ir.compiler-ir-label "merge")
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Phi
                    2
                    (ir.compiler-ir-phi-input-cons
                      (ir.CompilerIrValue.Var 1)
                      (ir.compiler-ir-label "left")
                      (ir.compiler-ir-phi-input-cons
                        (ir.CompilerIrValue.Var 0)
                        (ir.compiler-ir-label "right")
                        ir.CompilerIrPhiInputList.Nil))
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                    (ir.compiler-ir-instr-seq-empty))))
              (ir.compiler-ir-block-cons
                (ir.CompilerIrBlock.Block
                  (ir.compiler-ir-label "latch")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Phi
                      3
                      (ir.compiler-ir-phi-input-cons
                        (ir.CompilerIrValue.Var 2)
                        (ir.compiler-ir-label "merge")
                        ir.CompilerIrPhiInputList.Nil)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                      (ir.compiler-ir-instr-seq-empty))))
                ir.CompilerIrBlockList.Nil))))))))

(cfg
  test
  (define (compiler-reg-color-carry-priority-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 4 4 11)
      (compiler-reg-color-web-merge-intervals))))

(cfg
  test
  (define (compiler-reg-color-carry-priority-coloring) : reg.CompilerRegColoring
    (reg.compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (reg.CompilerRegPlan.Plan
        (compiler-reg-color-spill-sharing-assignments 5)
        (live.compiler-live-set-empty)
        (compiler-reg-color-carry-priority-intervals)
        (compiler-reg-color-spill-sharing-types 5)
        (reg.compiler-reg-call-split-empty)
        (reg.compiler-reg-split-plan-empty))
      (live.compiler-live-set-empty)
      ir.CompilerIrParamList.Nil
      (compiler-reg-color-carry-priority-blocks)
      5
      5
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-carry-priority-ok?) : bool
    (match (compiler-reg-color-carry-priority-coloring)
      [(reg.CompilerRegColoring.Remap remap _)
        (and
          ;; The merge phi lands in the loop carry's web ...
          (= (array-ref remap 2) (array-ref remap 0))
          ;; ... and NOT in the computed value's, which interferes with it.
          (not (= (array-ref remap 2) (array-ref remap 1))))]
      [(reg.CompilerRegColoring.None) false])))

(define (compiler-regalloc-self-test-failure-message [name : String]) : String
  (str_cat.str-cat "regalloc self-test failed: " name))

(define (compiler-regalloc-self-test-require! [name : String] [ok : bool]) : unit
  (if ok
    unit
    (io.panic (compiler-regalloc-self-test-failure-message name))))

(define (compiler-reg-location-remat? [location : reg.CompilerRegLocation]) : bool
  (match location
    [(reg.CompilerRegLocation.Remat _) true]
    [_ false]))

(define (compiler-reg-maybe-location-remat?
  [maybe-location : reg.CompilerRegMaybeLocation]) : bool
  (match maybe-location
    [(reg.CompilerRegMaybeLocation.Some location)
      (compiler-reg-location-remat? location)]
    [(reg.CompilerRegMaybeLocation.No) false]))

(define (compiler-reg-location-spill-offset?
  [maybe-location : reg.CompilerRegMaybeLocation]
  [offset : i64]) : bool
  (match maybe-location
    [(reg.CompilerRegMaybeLocation.Some location)
      (match location
        [(reg.CompilerRegLocation.Spill found) (= found offset)]
        [_ false])]
    [_ false]))

(define (compiler-reg-unassigned?
  [assignments : reg.CompilerRegAssignmentTable]
  [var : i64]) : bool
  (match (reg.compiler-reg-assignment-lookup assignments var)
    [(reg.CompilerRegMaybeLocation.No) true]
    [_ false]))

(define (compiler-reg-location-any-register?
  [maybe-location : reg.CompilerRegMaybeLocation]) : bool
  (match maybe-location
    [(reg.CompilerRegMaybeLocation.Some location)
      (match location
        [(reg.CompilerRegLocation.Register _) true]
        [(reg.CompilerRegLocation.RegisterPair _ _) true]
        [_ false])]
    [_ false]))

(define (compiler-reg-switch-scratch-test-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "entry")
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.Switch
          (ir.CompilerIrValue.Var 0)
          1
          (ir.compiler-ir-switch-case-seq1
            (ir.CompilerIrSwitchCase.Case 1 (ir.compiler-ir-label "one")))
          (ir.compiler-ir-label "other"))
        (ir.compiler-ir-instr-seq-empty)))
    ir.CompilerIrBlockList.Nil))

(define (compiler-reg-switch-scratch-test-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "switch_scratch_vregs")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    1
    (compiler-reg-switch-scratch-test-blocks)))

(define (compiler-reg-switch-scratch-test-plan) : reg.CompilerRegPlan
  (reg.CompilerRegPlan.Plan
    (reg.compiler-reg-assignments-prepend
      (reg.CompilerRegAssignment
        0
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r9))
      (reg.compiler-reg-assignment-table-empty))
    (live.compiler-live-set-empty)
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 0 1)
      (reg.compiler-reg-interval-seq-empty))
    (reg.compiler-reg-var-types-insert
      (reg.compiler-reg-var-types-empty)
      0
      (ast.AstType.I64))
    (reg.compiler-reg-call-split-empty)
    (reg.compiler-reg-split-plan-empty)))

(define (compiler-reg-switch-scratch-vregs-ok?) : bool
  (cfg
    scratch-vreg
    (let
      [func : ir.CompilerIrFunction (compiler-reg-switch-scratch-test-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-switch-scratch-test-plan)]
      (match (reg.compiler-reg-plan-with-scratch-vreg-result
        (ast.ast-node-pool-reader-type-segment-bases)
        (cabi.CompilerRegTargetAbi.Linux)
        func
        plan
        1)
        [(reg.CompilerRegScratchPlanResult.Result out scratch-plan)
          (let
            [index-reg : i64
              (reg.compiler-reg-scratch-plan-register scratch-plan 0 0)]
            [table-reg : i64
              (reg.compiler-reg-scratch-plan-register scratch-plan 0 1)]
            (and
              (= (reg.compiler-reg-plan-var-count out 1) 1)
              (= (reg.compiler-reg-scratch-plan-count scratch-plan) 2)
              (not (= index-reg cabi.compiler-reg-id-invalid))
              (not (= table-reg cabi.compiler-reg-id-invalid))
              (not (= index-reg table-reg))
              (not (= index-reg cabi.compiler-reg-id-r9))
              (not (= table-reg cabi.compiler-reg-id-r9))))]))
    true))

(define (compiler-reg-bounds-scratch-test-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "entry")
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.BoundsCheck
          (ir.CompilerIrValue.Var 0)
          (ir.CompilerIrValue.I64 8)
          (ir.compiler-ir-label "ok"))
        (ir.compiler-ir-instr-seq-empty)))
    ir.CompilerIrBlockList.Nil))

(define (compiler-reg-bounds-scratch-test-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "bounds_scratch_vregs")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    1
    (compiler-reg-bounds-scratch-test-blocks)))

(define (compiler-reg-bounds-scratch-vregs-ok?) : bool
  (cfg
    scratch-vreg
    (let
      [func : ir.CompilerIrFunction (compiler-reg-bounds-scratch-test-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-switch-scratch-test-plan)]
      (match (reg.compiler-reg-plan-with-scratch-vreg-result
        (ast.ast-node-pool-reader-type-segment-bases)
        (cabi.CompilerRegTargetAbi.Linux)
        func
        plan
        1)
        [(reg.CompilerRegScratchPlanResult.Result out scratch-plan)
          (let
            [length-reg : i64
              (reg.compiler-reg-scratch-plan-register scratch-plan 0 0)]
            [index-reg : i64
              (reg.compiler-reg-scratch-plan-register scratch-plan 0 1)]
            (and
              (= (reg.compiler-reg-plan-var-count out 1) 1)
              (= (reg.compiler-reg-scratch-plan-count scratch-plan) 2)
              (not (= length-reg cabi.compiler-reg-id-invalid))
              (not (= index-reg cabi.compiler-reg-id-invalid))
              (not (= length-reg index-reg))
              (not (= length-reg cabi.compiler-reg-id-r9))
              (not (= index-reg cabi.compiler-reg-id-r9))))]))
    true))

(define (compiler-reg-memory-scratch-test-plan) : reg.CompilerRegPlan
  (reg.CompilerRegPlan.Plan
    (reg.compiler-reg-assignments-prepend
      (reg.CompilerRegAssignment
        0
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r9))
      (reg.compiler-reg-assignments-prepend
        (reg.CompilerRegAssignment
          1
          (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r10))
        (reg.compiler-reg-assignment-table-empty)))
    (live.compiler-live-set-empty)
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 0 1)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 0 1)
        (reg.compiler-reg-interval-seq-empty)))
    (reg.compiler-reg-var-types-insert
      (reg.compiler-reg-var-types-insert
        (reg.compiler-reg-var-types-empty)
        1
        (ast.AstType.U64))
      0
      (ast.AstType.U64))
    (reg.compiler-reg-call-split-empty)
    (reg.compiler-reg-split-plan-empty)))

(define (compiler-reg-memory-scratch-test-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ci.intern "memory_scratch_vregs")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.CopyBytes
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.Var 1)
            7)
          (ir.compiler-ir-instr-seq-empty)))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-memory-scratch-vregs-ok?) : bool
  (cfg
    scratch-vreg
    (match (reg.compiler-reg-plan-with-scratch-vreg-result
      (ast.ast-node-pool-reader-type-segment-bases)
      (cabi.CompilerRegTargetAbi.Linux)
      (compiler-reg-memory-scratch-test-function)
      (compiler-reg-memory-scratch-test-plan)
      2)
      [(reg.CompilerRegScratchPlanResult.Result _ scratch-plan)
        (let
          [dst : i64 (reg.compiler-reg-scratch-plan-register scratch-plan 0 0)]
          [src : i64 (reg.compiler-reg-scratch-plan-register scratch-plan 0 1)]
          [value : i64
            (reg.compiler-reg-scratch-plan-register scratch-plan 0 2)]
          (and
            (= (reg.compiler-reg-scratch-plan-count scratch-plan) 3)
            (not (= dst cabi.compiler-reg-id-invalid))
            (not (= src cabi.compiler-reg-id-invalid))
            (not (= value cabi.compiler-reg-id-invalid))
            (not (= dst src))
            (not (= dst value))
            (not (= src value))
            (not (= dst cabi.compiler-reg-id-r9))
            (not (= dst cabi.compiler-reg-id-r10))
            (not (= src cabi.compiler-reg-id-r9))
            (not (= src cabi.compiler-reg-id-r10))
            (not (= value cabi.compiler-reg-id-r9))
            (not (= value cabi.compiler-reg-id-r10))))])
    true))

(define (compiler-reg-early-scratch-test-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "early_scratch_literal_divmod")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 42)
            (ast.AstType.I64))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              1
              (ir.CompilerIrBinOp.SafeMod)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 7)
              (ast.AstType.I64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
              (ir.compiler-ir-instr-seq-empty)))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-early-scratch-nontarget-blocks) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (ir.CompilerIrBlock.Block
      (ir.compiler-ir-label "entry")
      (compiler-reg-test-instr-seq-prepend
        (ir.CompilerIrInstr.BoundsCheck
          (ir.CompilerIrValue.Var 0)
          (ir.CompilerIrValue.I64 8)
          (ir.compiler-ir-label "ok"))
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Switch
            (ir.CompilerIrValue.Var 0)
            1
            (ir.compiler-ir-switch-case-seq-empty)
            (ir.compiler-ir-label "other"))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              1
              (ir.CompilerIrBinOp.SafeMod)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 1)
              (ast.AstType.I64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                1
                (ir.CompilerIrBinOp.Mod)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.I64 7)
                (ast.AstType.I64))
              (ir.compiler-ir-instr-seq-empty))))))
    ir.CompilerIrBlockList.Nil))

(define (compiler-reg-early-scratch-slot-range-ok?
  [model : reg.CompilerRegEarlyScratchModel]
  [offset : i64]
  [lo : i64]
  [hi : i64]) : bool
  (let
    [var : i64 (+ model.scratch-base offset)]
    [index : reg.CompilerRegIntervalIndex model.interval-index]
    (and
      (= (array-ref index.starts var) lo)
      (= (array-ref index.ends var) hi)
      (let
        [segments : reg.CompilerRegIntervalSeq (array-ref index.segments var)]
        (and
          (= (reg.compiler-reg-interval-seq-count segments) 1)
          (let
            [found : reg.CompilerRegInterval
              (reg.compiler-reg-interval-seq-ref segments 0)]
            (and (= found.var var) (= found.start lo) (= found.end hi))))))))

(define (compiler-reg-early-scratch-model-for-test
  [target-abi : cabi.CompilerRegTargetAbi]) : reg.CompilerRegEarlyScratchModel
  (let
    [func : ir.CompilerIrFunction (compiler-reg-early-scratch-test-function)]
    [types : reg.CompilerRegVarTypes (reg.compiler-reg-function-var-types func)]
    (match (reg.compiler-reg-live-interval-selection
      func
      (live.compiler-live-analyze-function func))
      [(reg.CompilerRegIntervalSelection.Selection _ index)
        (reg.compiler-reg-early-scratch-model
          (ast.ast-node-pool-reader-type-segment-bases)
          target-abi
          func
          index
          types
          (reg.compiler-reg-assignment-table-insert
            (reg.compiler-reg-assignment-table-make 2)
            0
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r10))
          true)])))

(define (compiler-reg-early-scratch-model-one-abi-ok?
  [target-abi : cabi.CompilerRegTargetAbi]) : bool
  (let
    [model : reg.CompilerRegEarlyScratchModel
      (compiler-reg-early-scratch-model-for-test target-abi)]
    [assignments : reg.CompilerRegAssignmentTable model.assignments]
    [base : i64 model.scratch-base]
    [weights : (__tl_dyn-array i64) model.scratch-weights]
    [excluded : (__tl_dyn-array reg.CompilerRegIdSeq) model.scratch-excluded]
    (and
      (= base 2)
      (= model.scratch-count 5)
      (= (array-length weights) 5)
      (= (array-ref weights 0) 0)
      (= (array-ref weights 1) 0)
      (= (array-ref weights 2) 1)
      (= (array-ref weights 3) 1)
      (= (array-ref weights 4) 1)
      (reg.compiler-reg-id-seq-contains?
        (array-ref excluded (+ base 2))
        cabi.compiler-reg-id-r10)
      (reg.compiler-reg-id-seq-contains?
        (array-ref excluded (+ base 3))
        cabi.compiler-reg-id-r10)
      (reg.compiler-reg-id-seq-contains?
        (array-ref excluded (+ base 4))
        cabi.compiler-reg-id-r10)
      (compiler-reg-early-scratch-slot-range-ok? model 0 2 3)
      (compiler-reg-early-scratch-slot-range-ok? model 1 2 3)
      (compiler-reg-early-scratch-slot-range-ok? model 2 2 3)
      (compiler-reg-early-scratch-slot-range-ok? model 3 2 3)
      (compiler-reg-early-scratch-slot-range-ok? model 4 2 3)
      (reg.compiler-reg-location-register?
        (reg.compiler-reg-assignment-table-lookup assignments base)
        cabi.compiler-reg-id-rax)
      (reg.compiler-reg-location-register?
        (reg.compiler-reg-assignment-table-lookup assignments (+ base 1))
        cabi.compiler-reg-id-rdx)
      (match (reg.compiler-reg-assignment-table-lookup assignments (+ base 2))
        [(reg.CompilerRegMaybeLocation.No) true]
        [_ false])
      (match (reg.compiler-reg-assignment-table-lookup assignments (+ base 3))
        [(reg.CompilerRegMaybeLocation.No) true]
        [_ false])
      (match (reg.compiler-reg-assignment-table-lookup assignments (+ base 4))
        [(reg.CompilerRegMaybeLocation.No) true]
        [_ false]))))

(define (compiler-reg-early-scratch-model-ok?) : bool
  (and
    (=
      (reg.compiler-reg-early-scratch-count-blocks
        (compiler-reg-early-scratch-nontarget-blocks))
      0)
    (compiler-reg-early-scratch-model-one-abi-ok?
      (cabi.CompilerRegTargetAbi.Linux))
    (compiler-reg-early-scratch-model-one-abi-ok?
      (cabi.CompilerRegTargetAbi.Windows))))

(define (compiler-reg-live-union-test-seq [var : i64] [start : i64] [end : i64]) : reg.CompilerRegIntervalSeq
  (reg.compiler-reg-interval-seq-append
    (reg.compiler-reg-interval-seq-empty)
    (reg.CompilerRegInterval var start end)))

;; Pins the per-register union against the boundary rules the greedy relies on:
;; a half-open touch at a nonzero point is DISJOINT, a touch at point 0 is
;; OVERLAP, a multi-segment candidate is tested segment by segment, removal
;; really frees the register again, and a resident with no segment data forces
;; the coarse per-resident fallback instead of a union answer.
(define (compiler-reg-greedy-live-union-invariant-ok?) : bool
  (let
    [vars : i64 7]
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
    [ends : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
    [segments : (__tl_dyn-array reg.CompilerRegIntervalSeq)
      (__tl_make-array reg.CompilerRegIntervalSeq vars)]
    [ref-counts : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-make vars)]
    [registers : (__tl_dyn-array i64)
      (reg.compiler-reg-scratch-register-array
        (cabi.CompilerRegTargetAbi.Linux))]
    (begin
      (reg.compiler-reg-fill-i64-array starts -1)
      (reg.compiler-reg-fill-i64-array ends -1)
      (reg.compiler-reg-fill-interval-seq-array! segments 0)
      ;; 0: resident [0,4)   1: touch at 4   2: overlaps   3: point-0 touch
      ;; 4: two segments past the resident  5: no segments (coarse [4,8))
      ;; 6: overlaps segment 4's second range
      (set! (array-ref segments 0) (compiler-reg-live-union-test-seq 0 0 4))
      (set! (array-ref segments 1) (compiler-reg-live-union-test-seq 1 4 8))
      (set! (array-ref segments 2) (compiler-reg-live-union-test-seq 2 3 6))
      (set! (array-ref segments 3) (compiler-reg-live-union-test-seq 3 0 0))
      (set!
        (array-ref segments 4)
        (reg.compiler-reg-interval-seq-append
          (compiler-reg-live-union-test-seq 4 8 9)
          (reg.CompilerRegInterval 4 12 14)))
      (set! (array-ref segments 6) (compiler-reg-live-union-test-seq 6 13 15))
      (set! (array-ref starts 0) 0)
      (set! (array-ref ends 0) 4)
      (set! (array-ref starts 5) 4)
      (set! (array-ref ends 5) 8)
      (let
        [index : reg.CompilerRegIntervalIndex
          (reg.CompilerRegIntervalIndex starts ends segments)]
        [occupancy : reg.CompilerRegGreedyOccupancy
          (reg.compiler-reg-greedy-occupancy-make
            assignments
            index
            registers
            (array-length registers))]
        [resident-0-ok? : bool false]
        [emptied-ok? : bool false]
        [multi-ok? : bool false]
        [coarse-resident-ok? : bool false]
        (begin
          (reg.compiler-reg-greedy-occupancy-assign! occupancy 0 0 -1)
          (set!
            resident-0-ok?
            (and
              ;; touch at 4 is half-open, so [4,8) may share the register
              (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 1 0)
              ;; [3,6) genuinely overlaps [0,4)
              (not
                (reg.compiler-reg-greedy-reg-free?
                  occupancy
                  index
                  ref-counts
                  2
                  0))
              ;; a point-0 touch counts as overlap (M-A RC1)
              (not
                (reg.compiler-reg-greedy-reg-free?
                  occupancy
                  index
                  ref-counts
                  3
                  0))
              ;; both of var 4's segments clear [0,4)
              (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 4 0)
              ;; var 5 has no segments: coarse [4,8) vs [0,4) via the fallback
              (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 5 0)))
          (reg.compiler-reg-greedy-occupancy-clear! occupancy 0)
          (set!
            emptied-ok?
            (and
              (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 2 0)
              (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 3 0)))
          (reg.compiler-reg-greedy-occupancy-assign! occupancy 4 0 -1)
          (set!
            multi-ok?
            (and
              (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 1 0)
              ;; [13,15) overlaps var 4's second segment [12,14)
              (not
                (reg.compiler-reg-greedy-reg-free?
                  occupancy
                  index
                  ref-counts
                  6
                  0))))
          (reg.compiler-reg-greedy-occupancy-clear! occupancy 4)
          (reg.compiler-reg-greedy-occupancy-assign! occupancy 5 0 -1)
          (set!
            coarse-resident-ok?
            (and
              ;; a segment-less resident forces the per-resident scan: var 0's
              ;; coarse [0,4) clears var 5's coarse [4,8) ...
              (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 0 0)
              ;; ... while var 1 has no coarse interval at all, which the
              ;; predicate answers conservatively as interference
              (not
                (reg.compiler-reg-greedy-reg-free?
                  occupancy
                  index
                  ref-counts
                  1
                  0))))
          (and resident-0-ok? emptied-ok? multi-ok? coarse-resident-ok?))))))

(define (compiler-reg-scratch-default-pool-target-invariant-ok?) : bool
  (let
    [intervals : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 1)
        (reg.compiler-reg-interval-seq-empty))]
    [index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build intervals 1)]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-make 1)]
    [linux-registers : (__tl_dyn-array i64)
      (reg.compiler-reg-scratch-register-array
        (cabi.CompilerRegTargetAbi.Linux))]
    [windows-registers : (__tl_dyn-array i64)
      (reg.compiler-reg-scratch-register-array
        (cabi.CompilerRegTargetAbi.Windows))]
    [linux-occupancy : reg.CompilerRegGreedyOccupancy
      (reg.compiler-reg-greedy-occupancy-make
        assignments
        index
        linux-registers
        (array-length linux-registers))]
    [windows-occupancy : reg.CompilerRegGreedyOccupancy
      (reg.compiler-reg-greedy-occupancy-make
        assignments
        index
        windows-registers
        (array-length windows-registers))]
    [excluded : reg.CompilerRegIdSeq
      (reg.compiler-reg-id-seq-prepend
        cabi.compiler-reg-id-rax
        (reg.compiler-reg-id-seq-empty))]
    (and
      (=
        (reg.compiler-reg-scratch-pick-register
          assignments
          linux-occupancy
          index
          (__tl_make-array i64 0)
          0
          1
          (reg.compiler-reg-scratch-default-pool
            (cabi.CompilerRegTargetAbi.Linux)
            (reg.CompilerRegScratchClass.Gp))
          excluded)
        cabi.compiler-reg-id-rsi)
      (=
        (reg.compiler-reg-scratch-pick-register
          assignments
          windows-occupancy
          index
          (__tl_make-array i64 0)
          0
          1
          (reg.compiler-reg-scratch-default-pool
            (cabi.CompilerRegTargetAbi.Windows)
            (reg.CompilerRegScratchClass.Gp))
          excluded)
        cabi.compiler-reg-id-rsi)
      ;; XMM volatility differs materially across ABIs and remains ABI-aware.
      (=
        (reg.compiler-reg-scratch-pick-register
          assignments
          windows-occupancy
          index
          (__tl_make-array i64 0)
          0
          1
          (reg.compiler-reg-scratch-default-pool
            (cabi.CompilerRegTargetAbi.Windows)
            (reg.CompilerRegScratchClass.Xmm))
          (reg.compiler-reg-id-seq-empty))
        (cfg
          scratch-vreg
          (cabi.compiler-abi-xmm-register-id 0)
          (cabi.compiler-abi-xmm-register-id 2))))))

(define (compiler-reg-scratch-callee-saved-registers-ok?) : bool
  (and
    (reg.compiler-reg-scratch-callee-saved-register?
      (cabi.CompilerRegTargetAbi.Linux)
      cabi.compiler-reg-id-r12)
    (reg.compiler-reg-scratch-callee-saved-register?
      (cabi.CompilerRegTargetAbi.Linux)
      cabi.compiler-reg-id-rbp)
    (not
      (reg.compiler-reg-scratch-callee-saved-register?
        (cabi.CompilerRegTargetAbi.Linux)
        cabi.compiler-reg-id-rsi))
    (not
      (reg.compiler-reg-scratch-callee-saved-register?
        (cabi.CompilerRegTargetAbi.Linux)
        (cabi.compiler-abi-xmm-register-id 6)))
    (reg.compiler-reg-scratch-callee-saved-register?
      (cabi.CompilerRegTargetAbi.Windows)
      cabi.compiler-reg-id-rsi)
    (reg.compiler-reg-scratch-callee-saved-register?
      (cabi.CompilerRegTargetAbi.Windows)
      cabi.compiler-reg-id-rdi)
    (reg.compiler-reg-scratch-callee-saved-register?
      (cabi.CompilerRegTargetAbi.Windows)
      (cabi.compiler-abi-xmm-register-id 6))
    (not
      (reg.compiler-reg-scratch-callee-saved-register?
        (cabi.CompilerRegTargetAbi.Windows)
        (cabi.compiler-abi-xmm-register-id 5)))))

(define (compiler-reg-scratch-call-result-exclusions-ok?) : bool
  (let
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignments-prepend
        (reg.CompilerRegAssignment
          0
          (reg.CompilerRegLocation.Register cabi.compiler-reg-id-rbx))
        (reg.compiler-reg-assignments-prepend
          (reg.CompilerRegAssignment
            1
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r10))
          (reg.compiler-reg-assignment-table-empty)))]
    [direct : reg.CompilerRegIdSeq
      (reg.compiler-reg-scratch-instr-registers
        assignments
        (ir.CompilerIrInstr.Call
          0
          0
          (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.I64 64))
          (ast.AstType.U64)))]
    [indirect : reg.CompilerRegIdSeq
      (reg.compiler-reg-scratch-instr-registers
        assignments
        (ir.CompilerIrInstr.CallIndirect
          0
          (ir.CompilerIrValue.Var 1)
          ir.CompilerIrCallArgs.Nil
          (ast.AstType.U64)))]
    (and
      (reg.compiler-reg-id-seq-contains? direct cabi.compiler-reg-id-rbx)
      (reg.compiler-reg-id-seq-contains? indirect cabi.compiler-reg-id-rbx)
      (reg.compiler-reg-id-seq-contains? indirect cabi.compiler-reg-id-r10))))

(define (compiler-reg-scratch-coalesced-home-hull-preserve-ok?) : bool
  (let
    [intervals : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 2)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 8 10)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 2 4 5)
            (reg.compiler-reg-interval-seq-empty))))]
    [index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build intervals 3)]
    [segmented-starts : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [segmented-ends : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [segmented-segments : (__tl_dyn-array reg.CompilerRegIntervalSeq)
      (__tl_make-array reg.CompilerRegIntervalSeq 3)]
    [_segmented-init : unit
      (begin
        (set! (array-ref segmented-starts 0) 0)
        (set! (array-ref segmented-starts 1) -1)
        (set! (array-ref segmented-starts 2) 4)
        (set! (array-ref segmented-ends 0) 10)
        (set! (array-ref segmented-ends 1) -1)
        (set! (array-ref segmented-ends 2) 5)
        (set!
          (array-ref segmented-segments 0)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 0 0 2)
            (reg.compiler-reg-interval-seq-prepend
              (reg.CompilerRegInterval 0 8 10)
              (reg.compiler-reg-interval-seq-empty))))
        (set!
          (array-ref segmented-segments 1)
          (reg.compiler-reg-interval-seq-empty))
        (set!
          (array-ref segmented-segments 2)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 2 4 5)
            (reg.compiler-reg-interval-seq-empty))))]
    [segmented-index : reg.CompilerRegIntervalIndex
      (reg.CompilerRegIntervalIndex
        segmented-starts
        segmented-ends
        segmented-segments)]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-insert
          (reg.compiler-reg-assignment-table-make 3)
          0
          (reg.CompilerRegLocation.Register cabi.compiler-reg-id-rdi))
        1
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-rdi))]
    [coalesced : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [independent : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [requirement : reg.CompilerRegScratchRequirement
      (reg.CompilerRegScratchRequirement
        4
        0
        (reg.CompilerRegScratchRole.MemoryAddress)
        (reg.CompilerRegScratchConstraint
          (reg.CompilerRegScratchClass.Gp)
          (reg.compiler-reg-id-seq-empty)
          (reg.compiler-reg-id-seq-empty)
          cabi.compiler-reg-id-invalid)
        4
        5
        2)]
    [_parents-init : unit
      (begin
        (set! (array-ref coalesced 0) 0)
        (set! (array-ref coalesced 1) 0)
        (set! (array-ref coalesced 2) 2)
        (set! (array-ref independent 0) 0)
        (set! (array-ref independent 1) 1)
        (set! (array-ref independent 2) 2))]
    (and
      ;; Neither expanded member overlaps the scratch point by itself.
      (reg.compiler-reg-scratch-register-free-from?
        assignments
        index
        2
        cabi.compiler-reg-id-rdi
        0
        3)
      ;; The exact coalesced class gap excludes its shared physical home.
      (reg.compiler-reg-scratch-register-coalesced-gap-from?
        assignments
        index
        coalesced
        requirement
        cabi.compiler-reg-id-rdi
        0
        2)
      ;; One segmented vreg can likewise carry its value across a modeled
      ;; lowering group even when its precise segments leave the point free.
      (reg.compiler-reg-scratch-register-coalesced-gap-from?
        assignments
        segmented-index
        independent
        requirement
        cabi.compiler-reg-id-rdi
        0
        2)
      ;; Unrelated values with the same physical home keep their precise gaps.
      (not
        (reg.compiler-reg-scratch-register-coalesced-gap-from?
          assignments
          index
          independent
          requirement
          cabi.compiler-reg-id-rdi
          0
          2)))))

(define (compiler-reg-early-scratch-never-spills-ok?) : bool
  (let
    [intervals : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 4)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 1 3)
          (reg.compiler-reg-interval-seq-empty)))]
    [index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build intervals 2)]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 2)
        0
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
    [base-weights : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [raw-weights : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [scratch-weights : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [weights : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [hints : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref base-weights 0) 3)
      (set! (array-ref raw-weights 0) 1)
      (set! (array-ref scratch-weights 0) 1)
      (set!
        weights
        (reg.compiler-reg-early-scratch-extend-weights
          base-weights
          raw-weights
          2
          1
          1
          scratch-weights))
      (reg.compiler-reg-fill-i64-array hints -1)
      (match (reg.compiler-reg-greedy-state
        intervals
        (reg.compiler-reg-id-seq-prepend
          cabi.compiler-reg-id-r12
          (reg.compiler-reg-id-seq-empty))
        assignments
        index
        (live.compiler-live-set-empty)
        (live.compiler-live-set-empty)
        weights
        hints
        hints
        (live.compiler-live-set-empty)
        (live.compiler-live-set-empty)
        (live.compiler-live-set-empty)
        (reg.compiler-reg-id-seq-prepend
          cabi.compiler-reg-id-r12
          (reg.compiler-reg-id-seq-empty))
        0
        1)
        [(reg.CompilerRegAssignState.State _ out)
          (and
            (= (array-ref weights 0) 3)
            ;; R1 scale: the pseudo's demand (1) is combined with the
            ;; compressed raw tie-break against the same radix (max raw = 1) as a
            ;; real value's, given the one-unit tie-break, and enqueued in the
            ;; GLOBAL priority band.
            (=
              (array-ref weights 1)
              (let
                [span : i64 (reg.compiler-reg-greedy-combine-tie-span)]
                [priced : i64 (+ (+ span (/ span 2)) 1)]
                (+
                  (* priced (reg.compiler-reg-priority-band-span))
                  (- (reg.compiler-reg-priority-band-span) 1))))
            (compiler-reg-location-spill-offset?
              (reg.compiler-reg-assignment-table-lookup out 0)
              (reg.compiler-reg-stack-slot-offset 0))
            (reg.compiler-reg-location-register?
              (reg.compiler-reg-assignment-table-lookup out 1)
              cabi.compiler-reg-id-r12))]))))

(define (compiler-reg-early-scratch-exclusion-rehomes-ok?) : bool
  (let
    [intervals : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 4)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 1 3)
          (reg.compiler-reg-interval-seq-empty)))]
    [index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build intervals 2)]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 2)
        0
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
    [weights : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [hints : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [excluded : (__tl_dyn-array reg.CompilerRegIdSeq)
      (__tl_make-array reg.CompilerRegIdSeq 2)]
    (begin
      ;; Greedy worklist keys (weight * band span + band), not bare weights:
      ;; the eviction gate strips the band with compiler-reg-priority-key-weight.
      (set! (array-ref weights 0) (reg.compiler-reg-priority-band-span))
      (set! (array-ref weights 1) (* 2 (reg.compiler-reg-priority-band-span)))
      (reg.compiler-reg-fill-i64-array hints -1)
      ;; %r10 is free but is the instruction operand home. The scratch pseudo
      ;; must instead evict the colder, CSR-only real value from %r12; when that
      ;; value is requeued it has no legal register and receives a real spill.
      (set!
        (array-ref excluded 1)
        (reg.compiler-reg-id-seq-prepend
          cabi.compiler-reg-id-r10
          (reg.compiler-reg-id-seq-empty)))
      (match (reg.compiler-reg-greedy-state-with-scratch-exclusions
        intervals
        (reg.compiler-reg-id-seq-prepend
          cabi.compiler-reg-id-r10
          (reg.compiler-reg-id-seq-prepend
            cabi.compiler-reg-id-r12
            (reg.compiler-reg-id-seq-empty)))
        assignments
        index
        (live.compiler-live-set-empty)
        (live.compiler-live-set-insert (live.compiler-live-set-empty) 0)
        weights
        hints
        hints
        (live.compiler-live-set-empty)
        (live.compiler-live-set-empty)
        (live.compiler-live-set-empty)
        (reg.compiler-reg-id-seq-prepend
          cabi.compiler-reg-id-r12
          (reg.compiler-reg-id-seq-empty))
        1
        1
        excluded)
        [(reg.CompilerRegAssignState.State _ out)
          (and
            (compiler-reg-location-spill-offset?
              (reg.compiler-reg-assignment-table-lookup out 0)
              (reg.compiler-reg-stack-slot-offset 0))
            (reg.compiler-reg-location-register?
              (reg.compiler-reg-assignment-table-lookup out 1)
              cabi.compiler-reg-id-r12))]))))

(define (compiler-reg-i64-ty) : ast.AstType
  (ast.AstType.I64))

(define (compiler-reg-f64-ty) : ast.AstType
  (ast.AstType.F64))

(define (compiler-reg-reuse-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "reuse")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 1)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g0")
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 2)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-f64-reuse-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "f64_reuse")
    ir.CompilerIrParamList.Nil
    (compiler-reg-f64-ty)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.F64 0x3ff8000000000000)
            (compiler-reg-f64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g0")
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-f64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.F64 0x4004000000000000)
                (compiler-reg-f64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-overlap-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "overlap")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    8
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 1)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.I64 2)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  3
                  (ir.CompilerIrValue.I64 3)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    4
                    (ir.CompilerIrValue.I64 4)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Mov
                      5
                      (ir.CompilerIrValue.I64 5)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Mov
                        6
                        (ir.CompilerIrValue.I64 6)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Store
                          (ir.compiler-ir-test-symbol "g0")
                          (ir.CompilerIrValue.Var 0)
                          (compiler-reg-i64-ty))
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.Store
                            (ir.compiler-ir-test-symbol "g1")
                            (ir.CompilerIrValue.Var 1)
                            (compiler-reg-i64-ty))
                          (compiler-reg-test-instr-seq-prepend
                            (ir.CompilerIrInstr.Store
                              (ir.compiler-ir-test-symbol "g2")
                              (ir.CompilerIrValue.Var 2)
                              (compiler-reg-i64-ty))
                            (compiler-reg-test-instr-seq-prepend
                              (ir.CompilerIrInstr.Store
                                (ir.compiler-ir-test-symbol "g3")
                                (ir.CompilerIrValue.Var 3)
                                (compiler-reg-i64-ty))
                              (compiler-reg-test-instr-seq-prepend
                                (ir.CompilerIrInstr.Store
                                  (ir.compiler-ir-test-symbol "g4")
                                  (ir.CompilerIrValue.Var 4)
                                  (compiler-reg-i64-ty))
                                (compiler-reg-test-instr-seq-prepend
                                  (ir.CompilerIrInstr.Store
                                    (ir.compiler-ir-test-symbol "g5")
                                    (ir.CompilerIrValue.Var 5)
                                    (compiler-reg-i64-ty))
                                  (compiler-reg-test-instr-seq-prepend
                                    (ir.CompilerIrInstr.Store
                                      (ir.compiler-ir-test-symbol "g6")
                                      (ir.CompilerIrValue.Var 6)
                                      (compiler-reg-i64-ty))
                                    (compiler-reg-test-instr-seq-prepend
                                      (ir.CompilerIrInstr.Return
                                        ir.CompilerIrMaybeValue.No)
                                      (ir.compiler-ir-instr-seq-empty)))))))))))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-f64-overlap-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "f64_overlap")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    5
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.F64 0x3fe0000000000000)
            (compiler-reg-f64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.F64 0x3ff8000000000000)
              (compiler-reg-f64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.F64 0x4004000000000000)
                (compiler-reg-f64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  3
                  (ir.CompilerIrValue.F64 0x400c000000000000)
                  (compiler-reg-f64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    4
                    (ir.CompilerIrValue.F64 0x4012000000000000)
                    (compiler-reg-f64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "g0")
                      (ir.CompilerIrValue.Var 0)
                      (compiler-reg-f64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Store
                        (ir.compiler-ir-test-symbol "g1")
                        (ir.CompilerIrValue.Var 1)
                        (compiler-reg-f64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Store
                          (ir.compiler-ir-test-symbol "g2")
                          (ir.CompilerIrValue.Var 2)
                          (compiler-reg-f64-ty))
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.Store
                            (ir.compiler-ir-test-symbol "g3")
                            (ir.CompilerIrValue.Var 3)
                            (compiler-reg-f64-ty))
                          (compiler-reg-test-instr-seq-prepend
                            (ir.CompilerIrInstr.Store
                              (ir.compiler-ir-test-symbol "g4")
                              (ir.CompilerIrValue.Var 4)
                              (compiler-reg-f64-ty))
                            (compiler-reg-test-instr-seq-prepend
                              (ir.CompilerIrInstr.Return
                                ir.CompilerIrMaybeValue.No)
                              (ir.compiler-ir-instr-seq-empty)))))))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-call-live-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "call_live")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 9)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Call
              1
              (ir.compiler-ir-test-symbol "side_effect")
              (ir.CompilerIrCallArgs.Nil)
              (ast.AstType.Unit))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-f64-call-live-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "f64_call_live")
    ir.CompilerIrParamList.Nil
    (compiler-reg-f64-ty)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.F64 0x4023000000000000)
            (compiler-reg-f64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Call
              1
              (ir.compiler-ir-test-symbol "side_effect")
              (ir.CompilerIrCallArgs.Nil)
              (ast.AstType.Unit))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-f64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-call-arg-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "call_arg")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 1)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 2)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                2
                (ir.compiler-ir-test-symbol "use_args")
                (ir.CompilerIrCallArgs.Two
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.Var 1))
                (ast.AstType.Unit))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  3
                  (ir.CompilerIrValue.I64 3)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))
                  (ir.compiler-ir-instr-seq-empty)))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-f64-call-arg-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "f64_call_arg")
    ir.CompilerIrParamList.Nil
    (compiler-reg-f64-ty)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.F64 0x3ff8000000000000)
            (compiler-reg-f64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Call
              1
              (ir.compiler-ir-test-symbol "takes_f64")
              (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.Var 0))
              (ast.AstType.Unit))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.F64 0x4004000000000000)
                (compiler-reg-f64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

;; M-A2 fixture: a direct call mixing a HANDLE arg (8-byte Array descriptor
;; pointer, var 0, produced by a call so it is not remat-classified) with a
;; scalar arg (var 1). Every arg is single-GP-register passed, and var 0 is
;; used again after the call, so it spans the call point.
(define (compiler-reg-handle-call-arg-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "handle_call_arg")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Call
            0
            (ir.compiler-ir-test-symbol "make_handle")
            (ir.CompilerIrCallArgs.Nil)
            (ast.ast-ty-dyn-array (ast.AstType.I64)))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 2)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Call
                2
                (ir.compiler-ir-test-symbol "use_args")
                (ir.CompilerIrCallArgs.Two
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.Var 1))
                (ast.AstType.Unit))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  3
                  (ir.CompilerIrValue.Var 0)
                  (ast.ast-ty-dyn-array (ast.AstType.I64)))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  (ir.compiler-ir-instr-seq-empty)))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-func2-ty) : ast.AstType
  (ast.ast-ty-func
    (ast.ast-type-cons
      (compiler-reg-i64-ty)
      (ast.ast-type-cons (compiler-reg-i64-ty) (ast.ast-type-list-new)))
    (compiler-reg-i64-ty)))

(define (compiler-reg-func4-ty) : ast.AstType
  (ast.ast-ty-func
    (ast.ast-type-cons
      (compiler-reg-i64-ty)
      (ast.ast-type-cons
        (compiler-reg-i64-ty)
        (ast.ast-type-cons
          (compiler-reg-i64-ty)
          (ast.ast-type-cons (compiler-reg-i64-ty) (ast.ast-type-list-new)))))
    (compiler-reg-i64-ty)))

(define (compiler-reg-indirect-call-arg-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "indirect_call_arg")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "callee" (compiler-reg-func2-ty) 0)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 1)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "b" (compiler-reg-i64-ty) 2)
          ir.CompilerIrParamList.Nil)))
    (compiler-reg-i64-ty)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.CallIndirect
            3
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrCallArgs.Two
              (ir.CompilerIrValue.Var 1)
              (ir.CompilerIrValue.Var 2))
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Return
              (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))
            (ir.compiler-ir-instr-seq-empty))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-indirect-call-arg4-function) : ir.CompilerIrFunction
  (let
    [args : (__tl_dyn-array ir.CompilerIrValue)
      (__tl_make-array ir.CompilerIrValue 4)]
    (begin
      (set! (array-ref args 0) (ir.CompilerIrValue.Var 1))
      (set! (array-ref args 1) (ir.CompilerIrValue.Var 2))
      (set! (array-ref args 2) (ir.CompilerIrValue.Var 3))
      (set! (array-ref args 3) (ir.CompilerIrValue.Var 4))
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "indirect_call_arg4")
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "callee" (compiler-reg-func4-ty) 0)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 1)
            (ir.compiler-ir-param-cons
              (ir.CompilerIrParam.Param "b" (compiler-reg-i64-ty) 2)
              (ir.compiler-ir-param-cons
                (ir.CompilerIrParam.Param "c" (compiler-reg-i64-ty) 3)
                (ir.compiler-ir-param-cons
                  (ir.CompilerIrParam.Param "d" (compiler-reg-i64-ty) 4)
                  ir.CompilerIrParamList.Nil)))))
        (compiler-reg-i64-ty)
        6
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "entry")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.CallIndirect
                5
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrCallArgs.Array args)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 5)))
                (ir.compiler-ir-instr-seq-empty))))
          ir.CompilerIrBlockList.Nil)))))

(define (compiler-reg-c-abi-store-result-arg-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "c_abi_store_result_arg")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "base" (compiler-reg-i64-ty) 0)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (compiler-reg-i64-ty) 1)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "b" (compiler-reg-i64-ty) 2)
          ir.CompilerIrParamList.Nil)))
    (ast.AstType.Unit)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.ir-instr-call-cabi-store-result
            (ir.CompilerIrValue.Var 0)
            (ir.compiler-ir-test-symbol "c_ret_pair")
            (ir.CompilerIrCallArgs.Two
              (ir.CompilerIrValue.Var 1)
              (ir.CompilerIrValue.Var 2))
            (ir.CompilerIrCAbiReturnSlotSeq
              (__tl_make-array ir.CompilerIrCAbiReturnSlot 0)
              0))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
            (ir.compiler-ir-instr-seq-empty))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-ineligible-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "ineligible")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "arg" (compiler-reg-i64-ty) 0)
      ir.CompilerIrParamList.Nil)
    (ast.AstType.Unit)
    7
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            1
            (ir.CompilerIrValue.F64 0x3ff8000000000000)
            (ast.AstType.F64))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              2
              (ir.CompilerIrValue.String "heap")
              (ast.AstType.String))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                3
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  4
                  (ir.CompilerIrValue.Unit)
                  (ast.ast-ty-dyn-array (ast.AstType.I64)))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    5
                    (ir.CompilerIrValue.I64 5)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.AddrOf 6 3)
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.TailMask
                        7
                        (ir.CompilerIrValue.Var 5)
                        (ir.CompilerIrValue.Var 5)
                        4)
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Return
                          (ir.CompilerIrMaybeValue.Some
                            (ir.CompilerIrValue.Var 5)))
                        (ir.compiler-ir-instr-seq-empty))))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-param-livein-gap-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "param_livein_gap")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "arg" (compiler-reg-i64-ty) 0)
      ir.CompilerIrParamList.Nil)
    (ast.AstType.I64)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "body"))
          (ir.compiler-ir-instr-seq-empty)))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "body")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              (ir.compiler-ir-instr-seq-empty))))
        ir.CompilerIrBlockList.Nil))))

(define (compiler-reg-single-block-livein-gap-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "single_block_livein_gap")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "arg" (compiler-reg-i64-ty) 0)
      ir.CompilerIrParamList.Nil)
    (ast.AstType.I64)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            1
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Return
              (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
            (ir.compiler-ir-instr-seq-empty))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-move-chain-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "move_chain")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 41)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-same-value-multi-def-census-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "same_value_multi_def_census")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Alloc 0 (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-phi-join-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "phi_join")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))
            (ir.compiler-ir-instr-seq-empty))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "join")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Phi
              1
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.Var 0)
                (ir.compiler-ir-label "entry")
                ir.CompilerIrPhiInputList.Nil)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
              (ir.compiler-ir-instr-seq-empty))))
        ir.CompilerIrBlockList.Nil))))

(define (compiler-reg-loop-backedge-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "loop_backedge")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
            (ir.compiler-ir-instr-seq-empty))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "loop")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Phi
              1
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.Var 0)
                (ir.compiler-ir-label "entry")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 2)
                  (ir.compiler-ir-label "body")
                  ir.CompilerIrPhiInputList.Nil))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Branch
                  (ir.CompilerIrValue.Bool false)
                  (ir.compiler-ir-label "body")
                  (ir.compiler-ir-label "exit"))
                (ir.compiler-ir-instr-seq-empty)))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "body")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              (ir.compiler-ir-instr-seq-empty)))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "exit")
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty)))
            ir.CompilerIrBlockList.Nil))))))

;; Single-block accumulator carry plus a loop counter. The accumulator back-edge
;; value is defined in the block and only feeds successor phis, so EP relaxation
;; may merge its back-edge copy with the header phi even though the value is also
;; live on the exit edge. The counter back-edge value feeds the exit compare, but
;; the counter PHI RESULT is dead from the increment onwards and leaves the block
;; on no edge, so that web is relaxed too -- one register carries the phi result
;; and then the increment, and the back edge needs no copy.
;; Both branch successor orderings exercise edge neutrality.
(define (compiler-reg-self-loop-exit-live-phi-function [loop-first : bool]) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "self_loop_exit_live_phi")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    6
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
          (ir.compiler-ir-instr-seq-empty)))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "loop")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.I64 0)
                (ir.compiler-ir-label "entry")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 3)
                  (ir.compiler-ir-label "loop")
                  ir.CompilerIrPhiInputList.Nil))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Phi
                1
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.I64 0)
                  (ir.compiler-ir-label "entry")
                  (ir.compiler-ir-phi-input-cons
                    (ir.CompilerIrValue.Var 4)
                    (ir.compiler-ir-label "loop")
                    ir.CompilerIrPhiInputList.Nil))
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  2
                  ir.CompilerIrBinOp.Add
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.I64 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    3
                    (ir.CompilerIrValue.Var 2)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.BinOp
                      4
                      ir.CompilerIrBinOp.Add
                      (ir.CompilerIrValue.Var 1)
                      (ir.CompilerIrValue.I64 1)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.BinOp
                        5
                        ir.CompilerIrBinOp.Lt
                        (ir.CompilerIrValue.Var 4)
                        (ir.CompilerIrValue.I64 10)
                        (ast.AstType.Bool))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Branch
                          (ir.CompilerIrValue.Var 5)
                          (if loop-first
                            (ir.compiler-ir-label "loop")
                            (ir.compiler-ir-label "exit"))
                          (if loop-first
                            (ir.compiler-ir-label "exit")
                            (ir.compiler-ir-label "loop")))
                        (ir.compiler-ir-instr-seq-empty)))))))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "exit")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))
              (ir.compiler-ir-instr-seq-empty)))
          ir.CompilerIrBlockList.Nil)))))

(define (compiler-reg-self-loop-exit-live-phi-mask-shape-ok?
  [mask : (__tl_dyn-array i64)]) : bool
  (and
    (= (array-ref mask 0) 1)
    (= (array-ref mask 3) 1)
    (= (array-ref mask 1) 1)
    (= (array-ref mask 4) 1)))

;; Negative counter shape 1: the exit returns the PHI RESULT v0, not the
;; increment v1, so v0 is live on the exit edge. Sharing one register would let
;; `add` destroy the value the exit reads, so the web must stay excluded.
(define (compiler-reg-self-loop-counter-exit-read-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "self_loop_counter_exit_read")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
          (ir.compiler-ir-instr-seq-empty)))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "loop")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.I64 0)
                (ir.compiler-ir-label "entry")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 1)
                  (ir.compiler-ir-label "loop")
                  ir.CompilerIrPhiInputList.Nil))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                1
                ir.CompilerIrBinOp.Add
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.I64 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  2
                  ir.CompilerIrBinOp.Lt
                  (ir.CompilerIrValue.Var 1)
                  (ir.CompilerIrValue.I64 10)
                  (ast.AstType.Bool))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Branch
                    (ir.CompilerIrValue.Var 2)
                    (ir.compiler-ir-label "loop")
                    (ir.compiler-ir-label "exit"))
                  (ir.compiler-ir-instr-seq-empty))))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "exit")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              (ir.compiler-ir-instr-seq-empty)))
          ir.CompilerIrBlockList.Nil)))))

;; Negative counter shape 2: the PHI RESULT v0 is read AGAIN inside the block,
;; after the increment v1 that feeds the back edge. The increment would destroy
;; v0 before that read, so the web must stay excluded here too.
(define (compiler-reg-self-loop-counter-late-read-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "self_loop_counter_late_read")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
          (ir.compiler-ir-instr-seq-empty)))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "loop")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.I64 0)
                (ir.compiler-ir-label "entry")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 1)
                  (ir.compiler-ir-label "loop")
                  ir.CompilerIrPhiInputList.Nil))
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                1
                ir.CompilerIrBinOp.Add
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.I64 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  2
                  ir.CompilerIrBinOp.Mul
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.I64 3)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.BinOp
                    3
                    ir.CompilerIrBinOp.Lt
                    (ir.CompilerIrValue.Var 1)
                    (ir.CompilerIrValue.I64 10)
                    (ast.AstType.Bool))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Branch
                      (ir.CompilerIrValue.Var 3)
                      (ir.compiler-ir-label "loop")
                      (ir.compiler-ir-label "exit"))
                    (ir.compiler-ir-instr-seq-empty)))))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "exit")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
              (ir.compiler-ir-instr-seq-empty)))
          ir.CompilerIrBlockList.Nil)))))

(define (compiler-reg-destructive-straight-chain-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "destructive_straight_chain")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 40)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              1
              ir.CompilerIrBinOp.Add
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                2
                ir.CompilerIrBinOp.Sub
                (ir.CompilerIrValue.Var 1)
                (ir.CompilerIrValue.I64 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-destructive-noncommutative-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "destructive_noncommutative")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 40)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                2
                ir.CompilerIrBinOp.Sub
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  3
                  ir.CompilerIrBinOp.Add
                  (ir.CompilerIrValue.Var 2)
                  (ir.CompilerIrValue.I64 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))
                  (ir.compiler-ir-instr-seq-empty)))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-destructive-commutative-rhs-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "destructive_commutative_rhs")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 40)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              1
              ir.CompilerIrBinOp.Add
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                2
                ir.CompilerIrBinOp.Add
                (ir.CompilerIrValue.I64 1)
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-destructive-div-exclusion-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "destructive_div_exclusion")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 40)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.BinOp
              1
              ir.CompilerIrBinOp.Div
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 2)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.BinOp
                2
                ir.CompilerIrBinOp.Add
                (ir.CompilerIrValue.Var 1)
                (ir.CompilerIrValue.I64 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-destructive-chain-ok?) : bool
  (let
    [straight : ir.CompilerIrFunction
      (compiler-reg-destructive-straight-chain-function)]
    [straight-moves : reg.CompilerRegMoveSeq
      (reg.compiler-reg-function-moves-with-destructive-and-casts
        straight
        false)]
    [clobber-eligible : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [clobber-moves : reg.CompilerRegMoveSeq
      (begin
        (reg.compiler-reg-fill-i64-array clobber-eligible 1)
        (set! (array-ref clobber-eligible 1) 0)
        (reg.compiler-reg-function-moves-with-destructive-and-casts-eligible
          straight
          false
          clobber-eligible
          (reg.compiler-reg-function-alu-prefer-rhs straight)))]
    [noncomm : ir.CompilerIrFunction
      (compiler-reg-destructive-noncommutative-function)]
    [noncomm-moves : reg.CompilerRegMoveSeq
      (reg.compiler-reg-function-moves-with-destructive-and-casts noncomm false)]
    [commutative-rhs-moves : reg.CompilerRegMoveSeq
      (reg.compiler-reg-function-moves-with-destructive-and-casts
        (compiler-reg-destructive-commutative-rhs-function)
        false)]
    [div-moves : reg.CompilerRegMoveSeq
      (reg.compiler-reg-function-moves-with-destructive-and-casts
        (compiler-reg-destructive-div-exclusion-function)
        false)]
    (match (reg.compiler-reg-plan-function-scalar straight)
      [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
        (and
          (reg.compiler-reg-move-list-contains-undirected? straight-moves 0 1)
          (reg.compiler-reg-move-list-contains-undirected? straight-moves 1 2)
          (not
            (reg.compiler-reg-move-list-contains-undirected? clobber-moves 0 1))
          (not
            (reg.compiler-reg-move-list-contains-undirected? clobber-moves 1 2))
          (compiler-reg-same-location? assignments 0 1)
          (compiler-reg-same-location? assignments 1 2)
          (reg.compiler-reg-move-list-contains-undirected? noncomm-moves 0 2)
          (not
            (reg.compiler-reg-move-list-contains-undirected? noncomm-moves 1 2))
          (reg.compiler-reg-move-list-contains-undirected?
            commutative-rhs-moves
            1
            2)
          (not (reg.compiler-reg-move-list-contains-undirected? div-moves 0 1)))])))

;; GAP8-C fixtures. The word-loop shape the backend's commuted ALU fold wants:
;;
;;     %3 = add %2, 1        ; the accumulator (a destructive result)
;;     %4 = gep %0, %1
;;     %5 = load %4          ; the fused load, single use
;;     %6 = <op> %5, %3      ; the load on the LHS
;;     %7 = add %6, 1        ; %6 feeds another destructive op
;;
;; `op` selects commutative (flip expected) vs Sub (no flip). `double-use-load?`
;; adds a second reader of the load, which retires the fold and so must retire
;; the flip with it. The trailing `add` is what makes the BinOp destination an
;; eligible chain candidate at all, matching the loop-carried shape.
(define (compiler-reg-alu-load-lhs-function
  [op : ir.CompilerIrBinOp]
  [double-use-load? : bool]) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "alu_load_lhs")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    9
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 40)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.I64 7)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  3
                  ir.CompilerIrBinOp.Add
                  (ir.CompilerIrValue.Var 2)
                  (ir.CompilerIrValue.I64 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Gep
                    4
                    (ir.CompilerIrValue.Var 0)
                    (ir.CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Load
                      5
                      (ir.CompilerIrValue.Var 4)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.BinOp
                        6
                        op
                        (ir.CompilerIrValue.Var 5)
                        (ir.CompilerIrValue.Var 3)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.BinOp
                          7
                          ir.CompilerIrBinOp.Add
                          (ir.CompilerIrValue.Var 6)
                          (ir.CompilerIrValue.I64 1)
                          (compiler-reg-i64-ty))
                        (if double-use-load?
                          (compiler-reg-test-instr-seq-prepend
                            (ir.CompilerIrInstr.BinOp
                              8
                              ir.CompilerIrBinOp.Add
                              (ir.CompilerIrValue.Var 7)
                              (ir.CompilerIrValue.Var 5)
                              (compiler-reg-i64-ty))
                            (compiler-reg-test-instr-seq-prepend
                              (ir.CompilerIrInstr.Return
                                (ir.CompilerIrMaybeValue.Some
                                  (ir.CompilerIrValue.Var 8)))
                              (ir.compiler-ir-instr-seq-empty)))
                          (compiler-reg-test-instr-seq-prepend
                            (ir.CompilerIrInstr.Return
                              (ir.CompilerIrMaybeValue.Some
                                (ir.CompilerIrValue.Var 7)))
                            (ir.compiler-ir-instr-seq-empty))))))))))))
      ir.CompilerIrBlockList.Nil)))

;; Both operands loaded is the backend's PAIR fold, which needs no operand tie:
;;
;;     %4 = gep ... ; %5 = load %4
;;     %6 = gep ... ; %7 = load %6
;;     %8 = bit_and %7, %5
;;
;; The rhs-defining load sits three slots back, which is exactly the shape the
;; preference declines.
(define (compiler-reg-alu-load-pair-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "alu_load_pair")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    10
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 40)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.I64 2)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.BinOp
                  3
                  ir.CompilerIrBinOp.Add
                  (ir.CompilerIrValue.Var 2)
                  (ir.CompilerIrValue.I64 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Gep
                    4
                    (ir.CompilerIrValue.Var 0)
                    (ir.CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Load
                      5
                      (ir.CompilerIrValue.Var 4)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Gep
                        6
                        (ir.CompilerIrValue.Var 0)
                        (ir.CompilerIrValue.Var 3)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Load
                          7
                          (ir.CompilerIrValue.Var 6)
                          (compiler-reg-i64-ty))
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.BinOp
                            8
                            ir.CompilerIrBinOp.BitAnd
                            (ir.CompilerIrValue.Var 7)
                            (ir.CompilerIrValue.Var 5)
                            (compiler-reg-i64-ty))
                          (compiler-reg-test-instr-seq-prepend
                            (ir.CompilerIrInstr.BinOp
                              9
                              ir.CompilerIrBinOp.Add
                              (ir.CompilerIrValue.Var 8)
                              (ir.CompilerIrValue.I64 1)
                              (compiler-reg-i64-ty))
                            (compiler-reg-test-instr-seq-prepend
                              (ir.CompilerIrInstr.Return
                                (ir.CompilerIrMaybeValue.Some
                                  (ir.CompilerIrValue.Var 9)))
                              (ir.compiler-ir-instr-seq-empty)))))))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-alu-load-lhs-moves
  [op : ir.CompilerIrBinOp]
  [double-use-load? : bool]) : reg.CompilerRegMoveSeq
  (reg.compiler-reg-function-moves-with-destructive-and-casts
    (compiler-reg-alu-load-lhs-function op double-use-load?)
    false))

;; The copy-hint half of the same preference, exercised directly: the hint list
;; is first-wins, so a flipped destination must land on the RHS root and an
;; unflipped one on the LHS root.
(define (compiler-reg-alu-copy-hint-for [flip? : bool]) : i64
  (let
    [hints : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [parents : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [flags : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [index : i64 0]
    (begin
      (reg.compiler-reg-fill-i64-array hints -1)
      (while (< index 8)
        (begin
          (set! (array-ref parents index) index)
          (set! index (+ index 1))))
      (if flip?
        (set! (array-ref flags 6) 1)
        unit)
      (reg.compiler-reg-copy-hints-from-binops-instr!
        (ir.CompilerIrInstr.BinOp
          6
          ir.CompilerIrBinOp.BitAnd
          (ir.CompilerIrValue.Var 5)
          (ir.CompilerIrValue.Var 3)
          (compiler-reg-i64-ty))
        hints
        parents
        flags)
      (array-ref hints 6))))

(define (compiler-reg-alu-load-lhs-tie-ok?) : bool
  (let
    ;; (a) commutative, single-use fused load on the lhs: the destination ties
    ;; to the ACCUMULATOR (%3), not to the load (%5).
    [flipped : reg.CompilerRegMoveSeq
      (compiler-reg-alu-load-lhs-moves ir.CompilerIrBinOp.BitAnd false)]
    ;; (b) the same shape with a twice-read load: no fold, so no flip.
    [double-use : reg.CompilerRegMoveSeq
      (compiler-reg-alu-load-lhs-moves ir.CompilerIrBinOp.BitAnd true)]
    ;; (c) Sub is not commutative -- `MEM - x` is not `x - MEM`.
    [noncommutative : reg.CompilerRegMoveSeq
      (compiler-reg-alu-load-lhs-moves ir.CompilerIrBinOp.Sub false)]
    ;; (d) both operands loaded is the pair fold's shape; ties stay put.
    [pair : reg.CompilerRegMoveSeq
      (reg.compiler-reg-function-moves-with-destructive-and-casts
        (compiler-reg-alu-load-pair-function)
        false)]
    (and
      (reg.compiler-reg-move-list-contains-undirected? flipped 3 6)
      (not (reg.compiler-reg-move-list-contains-undirected? flipped 5 6))
      (reg.compiler-reg-move-list-contains-undirected? double-use 5 6)
      (not (reg.compiler-reg-move-list-contains-undirected? double-use 3 6))
      (reg.compiler-reg-move-list-contains-undirected? noncommutative 5 6)
      (not (reg.compiler-reg-move-list-contains-undirected? noncommutative 3 6))
      (reg.compiler-reg-move-list-contains-undirected? pair 7 8)
      (not (reg.compiler-reg-move-list-contains-undirected? pair 5 8))
      (= (compiler-reg-alu-copy-hint-for true) 3)
      (= (compiler-reg-alu-copy-hint-for false) 5))))

(define (compiler-reg-same-value-clobber-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "same_value_clobber")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Call
              1
              (ir.compiler-ir-test-symbol "side_effect")
              ir.CompilerIrCallArgs.Nil
              (ast.AstType.Unit))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

;; M-C (part 1) census shapes for the extended (mutable-source) same-value
;; relation. `safe`: the source's second def lies OUTSIDE the copy's liveness
;; -> merge. `reject`: the second def lands between the copy and its use ->
;; refused. `chain`: a copy-of-copy must not smuggle a member past the def
;; (the transitive hazard). `cast`: the width-64 int cast counts as a copy.
(define (compiler-reg-sv-multi-safe-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "sv_multi_safe")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "g")
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  0
                  (ir.CompilerIrValue.I64 9)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  (ir.compiler-ir-instr-seq-empty)))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-sv-multi-reject-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "sv_multi_reject")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                0
                (ir.CompilerIrValue.I64 9)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "g")
                  (ir.CompilerIrValue.Var 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  (ir.compiler-ir-instr-seq-empty)))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-sv-multi-chain-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "sv_multi_chain")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              2
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                0
                (ir.CompilerIrValue.I64 9)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  3
                  (ir.CompilerIrValue.Var 2)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "g")
                    (ir.CompilerIrValue.Var 3)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                    (ir.compiler-ir-instr-seq-empty))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-sv-multi-cast-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "sv_multi_cast")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Cast
              1
              (ir.CompilerIrValue.Var 0)
              (ast.AstType.I64)
              (ast.AstType.U64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "g")
                (ir.CompilerIrValue.Var 1)
                (ast.AstType.U64))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  0
                  (ir.CompilerIrValue.I64 9)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  (ir.compiler-ir-instr-seq-empty)))))))
      ir.CompilerIrBlockList.Nil)))

;; ---------------------------------------------------------------------------
;; P22: nested value-identical copies coalesce ACROSS a call.
;;
;; Every fixture below is the loop-index/bounds-check shape the benchmarks show:
;; a long-lived value `0` that is live across a real call (so the kind-6
;; clobber-span exclusion keeps it out of the plain same-value relation) and a
;; short copy `1` of it whose whole live hull sits inside `0`'s. The merged
;; class hull is then exactly `0`'s hull, so the class inherits the call
;; crossing `0` already carried and nothing else.
(define (compiler-reg-p22-nested-copy-function
  [copy : ir.CompilerIrInstr]
  [use-ty : ast.AstType]) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "p22_nested_copy")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            copy
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "g")
                (ir.CompilerIrValue.Var 1)
                use-ty)
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Call
                  2
                  (ir.compiler-ir-test-symbol "side_effect")
                  ir.CompilerIrCallArgs.Nil
                  (ast.AstType.Unit))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "g")
                    (ir.CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                    (ir.compiler-ir-instr-seq-empty))))))))
      ir.CompilerIrBlockList.Nil)))

;; The mutable-source hazard must survive the relaxation: `0` is redefined
;; INSIDE the copy's liveness, so the two are not the same value at the copy's
;; use however neatly their hulls nest.
(define (compiler-reg-p22-nested-reject-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "p22_nested_reject")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 7)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                0
                (ir.CompilerIrValue.I64 9)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "g")
                  (ir.CompilerIrValue.Var 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Call
                    2
                    (ir.compiler-ir-test-symbol "side_effect")
                    ir.CompilerIrCallArgs.Nil
                    (ast.AstType.Unit))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "g")
                      (ir.CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Return
                        (ir.CompilerIrMaybeValue.Some
                          (ir.CompilerIrValue.Var 0)))
                      (ir.compiler-ir-instr-seq-empty)))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-p22-nested-same-home? [func : ir.CompilerIrFunction]) : bool
  (match (reg.compiler-reg-plan-function-scalar func)
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      (compiler-reg-same-location? assignments 0 1)]))

(define (compiler-reg-p22-nested-copy-ok?) : bool
  (and
    ;; A same-width signedness cast whose source stays live shares its home.
    (compiler-reg-p22-nested-same-home?
      (compiler-reg-p22-nested-copy-function
        (ir.CompilerIrInstr.Cast
          1
          (ir.CompilerIrValue.Var 0)
          (ast.AstType.I64)
          (ast.AstType.U64))
        (ast.AstType.U64)))
    ;; Same in the other signedness direction.
    (compiler-reg-p22-nested-same-home?
      (compiler-reg-p22-nested-copy-function
        (ir.CompilerIrInstr.Cast
          1
          (ir.CompilerIrValue.Var 0)
          (ast.AstType.U64)
          (ast.AstType.I64))
        (compiler-reg-i64-ty)))
    ;; A plain Mov whose source stays live shares its home.
    (compiler-reg-p22-nested-same-home?
      (compiler-reg-p22-nested-copy-function
        (ir.CompilerIrInstr.Mov
          1
          (ir.CompilerIrValue.Var 0)
          (compiler-reg-i64-ty))
        (compiler-reg-i64-ty)))
    ;; A NARROWING cast is real work -- the destination home holds the
    ;; sign-normalized 32-bit value, which is not the source's bit pattern --
    ;; so it must keep its own home.
    (not
      (compiler-reg-p22-nested-same-home?
        (compiler-reg-p22-nested-copy-function
          (ir.CompilerIrInstr.Cast
            1
            (ir.CompilerIrValue.Var 0)
            (ast.AstType.I64)
            (ast.AstType.I32))
          (ast.AstType.I32))))
    ;; A widening cast is real work too.
    (not
      (compiler-reg-p22-nested-same-home?
        (compiler-reg-p22-nested-copy-function
          (ir.CompilerIrInstr.Cast
            1
            (ir.CompilerIrValue.Var 0)
            (ast.AstType.I32)
            (compiler-reg-i64-ty))
          (compiler-reg-i64-ty))))
    ;; Nesting lifts the clobber-span refusal ONLY. A source redefined inside
    ;; the copy's liveness is still refused.
    (not
      (compiler-reg-p22-nested-same-home?
        (compiler-reg-p22-nested-reject-function)))))

(define (compiler-reg-interference-blocks-coalesce-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "interference_blocks_coalesce")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 9)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "keep")
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-spill-coalesce-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "spill_coalesce")
    ir.CompilerIrParamList.Nil
    (ast.AstType.I64)
    6
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 1)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.I64 2)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  3
                  (ir.CompilerIrValue.I64 3)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    4
                    (ir.CompilerIrValue.I64 4)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "g0")
                      (ir.CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Store
                        (ir.compiler-ir-test-symbol "g1")
                        (ir.CompilerIrValue.Var 1)
                        (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Store
                          (ir.compiler-ir-test-symbol "g2")
                          (ir.CompilerIrValue.Var 2)
                          (compiler-reg-i64-ty))
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.Store
                            (ir.compiler-ir-test-symbol "g3")
                            (ir.CompilerIrValue.Var 3)
                            (compiler-reg-i64-ty))
                          (compiler-reg-test-instr-seq-prepend
                            (ir.CompilerIrInstr.Mov
                              5
                              (ir.CompilerIrValue.Var 4)
                              (compiler-reg-i64-ty))
                            (compiler-reg-test-instr-seq-prepend
                              (ir.CompilerIrInstr.Return
                                (ir.CompilerIrMaybeValue.Some
                                  (ir.CompilerIrValue.Var 5)))
                              (ir.compiler-ir-instr-seq-empty)))))))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-vector-home-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "vector_home")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.VectorLoad
            0
            (ir.CompilerIrValue.I64 0)
            (ir.CompilerIrValue.I64 0)
            4
            (ast.AstType.I64))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.VectorLoad
              1
              (ir.CompilerIrValue.I64 0)
              (ir.CompilerIrValue.I64 4)
              4
              (ast.AstType.I64))
            (compiler-reg-test-instr-seq-prepend
              (ir.ir-instr-vector-bin-op
                2
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.Var 1)
                4
                (ast.AstType.I64))
              (compiler-reg-test-instr-seq-prepend
                (ir.ir-instr-vector-bin-op
                  3
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.Var 2)
                  4
                  (ast.AstType.I64))
                (compiler-reg-test-instr-seq-prepend
                  (ir.ir-instr-vector-store
                    (ir.CompilerIrValue.I64 0)
                    (ir.CompilerIrValue.I64 8)
                    (ir.CompilerIrValue.Var 3)
                    4
                    (ast.AstType.I64))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                    (ir.compiler-ir-instr-seq-empty))))))))
      ir.CompilerIrBlockList.Nil)))

;; CpuId clobbers fixed GP registers but preserves the XMM bank. A vector live
;; across it must therefore keep an ordinary volatile vector home on SysV.
(define (compiler-reg-vector-gp-clobber-home-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "vector_gp_clobber_home")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    2
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.VectorLoad
            0
            (ir.CompilerIrValue.I64 0)
            (ir.CompilerIrValue.I64 0)
            4
            (ast.AstType.I64))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.CpuId
              1
              (ir.CompilerIrValue.I64 0)
              (ir.CompilerIrValue.I64 0)
              0)
            (compiler-reg-test-instr-seq-prepend
              (ir.ir-instr-vector-store
                (ir.CompilerIrValue.I64 0)
                (ir.CompilerIrValue.I64 4)
                (ir.CompilerIrValue.Var 0)
                4
                (ast.AstType.I64))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-vector-select-false-home-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "vector_select_false_home")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    5
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Splat
            0
            (ir.CompilerIrValue.I64 0)
            8
            (ast.AstType.I64))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Splat
              1
              (ir.CompilerIrValue.I64 1)
              8
              (ast.AstType.I64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Splat
                2
                (ir.CompilerIrValue.I64 2)
                8
                (ast.AstType.I64))
              (compiler-reg-test-instr-seq-prepend
                (ir.ir-instr-vector-store
                  (ir.CompilerIrValue.I64 0)
                  (ir.CompilerIrValue.I64 0)
                  (ir.CompilerIrValue.Var 0)
                  8
                  (ast.AstType.I64))
                (compiler-reg-test-instr-seq-prepend
                  (ir.ir-instr-vector-compare
                    3
                    (ir.CompilerIrBinOp.Lt)
                    (ir.CompilerIrValue.Var 2)
                    (ir.CompilerIrValue.Var 1)
                    8
                    (ast.AstType.I64))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.ir-instr-select
                      4
                      (ir.CompilerIrValue.Var 3)
                      (ir.CompilerIrValue.Var 2)
                      (ir.CompilerIrValue.Var 1)
                      8
                      (ast.AstType.I64))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.ir-instr-vector-store
                        (ir.CompilerIrValue.I64 0)
                        (ir.CompilerIrValue.I64 8)
                        (ir.CompilerIrValue.Var 4)
                        8
                        (ast.AstType.I64))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                        (ir.compiler-ir-instr-seq-empty))))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-mask-home-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "mask_home")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    5
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.TailMask
            0
            (ir.CompilerIrValue.I64 0)
            (ir.CompilerIrValue.I64 8)
            8)
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.TailMask
              1
              (ir.CompilerIrValue.I64 4)
              (ir.CompilerIrValue.I64 8)
              8)
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.MaskBinOp
                2
                (ir.CompilerIrMaskBinOp.And)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.Var 1)
                8)
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.MaskNot 3 (ir.CompilerIrValue.Var 2) 8)
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.MaskReduce
                    4
                    (ir.CompilerIrMaskReduceOp.Any)
                    (ir.CompilerIrValue.Var 3)
                    8)
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 4)))
                    (ir.compiler-ir-instr-seq-empty))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-mask-pressure-uses [index : i64]) : ir.CompilerIrInstrSeq
  (if (>= index 7)
    (compiler-reg-test-instr-seq-prepend
      (ir.CompilerIrInstr.Return
        (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 13)))
      (ir.compiler-ir-instr-seq-empty))
    (compiler-reg-test-instr-seq-prepend
      (ir.CompilerIrInstr.MaskReduce
        (+ 7 index)
        (ir.CompilerIrMaskReduceOp.Any)
        (ir.CompilerIrValue.Var index)
        8)
      (compiler-reg-mask-pressure-uses (+ index 1)))))

(define (compiler-reg-mask-pressure-defs [index : i64]) : ir.CompilerIrInstrSeq
  (if (>= index 7)
    (compiler-reg-mask-pressure-uses 0)
    (compiler-reg-test-instr-seq-prepend
      (ir.CompilerIrInstr.TailMask
        index
        (ir.CompilerIrValue.I64 index)
        (ir.CompilerIrValue.I64 8)
        8)
      (compiler-reg-mask-pressure-defs (+ index 1)))))

(define (compiler-reg-mask-pressure-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "mask_pressure")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Bool)
    14
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-mask-pressure-defs 0))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-reuse-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-reuse-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      (and
        (= (reg.compiler-reg-assignment-count assignments) 2)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          cabi.compiler-reg-id-r12)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 1)
          cabi.compiler-reg-id-r12))]))

(define (compiler-reg-f64-reuse-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-f64-reuse-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      (and
        (= (reg.compiler-reg-assignment-count assignments) 2)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          (cfg
            scratch-vreg
            (cabi.compiler-abi-xmm-register-id 0)
            (cabi.compiler-abi-xmm-register-id 2)))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 1)
          (cfg
            scratch-vreg
            (cabi.compiler-abi-xmm-register-id 0)
            (cabi.compiler-abi-xmm-register-id 2))))]))

(define (compiler-reg-overlap-spill-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-overlap-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      ;; Seven simultaneously live values against a five-register callee-saved
      ;; pool: the first five take %r12..%r15 and %rbx, and the remaining two
      ;; spill. %rbx joined the pool once its fixed scratch role moved under the
      ;; scavenger.
      (and
        (= (reg.compiler-reg-assignment-count assignments) 7)
        (= (reg.compiler-reg-spill-count assignments) 2)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 3)
          cabi.compiler-reg-id-r15)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 4)
          cabi.compiler-reg-id-rbx)
        (compiler-reg-location-spill-offset?
          (reg.compiler-reg-assignment-lookup assignments 6)
          (reg.compiler-reg-stack-slot-offset 6)))]))

(define (compiler-reg-f64-overlap-spill-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-f64-overlap-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      (and
        (= (reg.compiler-reg-assignment-count assignments) 5)
        (= (reg.compiler-reg-spill-count assignments) 0)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          (cfg
            scratch-vreg
            (cabi.compiler-abi-xmm-register-id 0)
            (cabi.compiler-abi-xmm-register-id 2)))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 1)
          (cfg
            scratch-vreg
            (cabi.compiler-abi-xmm-register-id 1)
            (cabi.compiler-abi-xmm-register-id 3)))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 2)
          (cfg
            scratch-vreg
            (cabi.compiler-abi-xmm-register-id 2)
            (cabi.compiler-abi-xmm-register-id 4)))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 3)
          (cfg
            scratch-vreg
            (cabi.compiler-abi-xmm-register-id 3)
            (cabi.compiler-abi-xmm-register-id 5)))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 4)
          (cfg
            scratch-vreg
            (cabi.compiler-abi-xmm-register-id 4)
            (cabi.compiler-abi-xmm-register-id 6))))]))

;; SIMD plan (#perf): an integer value live across a call now keeps a callee-saved
;; register home (the SIMD integer pool is the 5 callee-saved registers, which the
;; callee preserves), exactly like the scalar plan -- it is no longer force-spilled.
;; The unit call result (var 1) stays ineligible (non-scalar).
(define (compiler-reg-call-live-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-call-live-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (live.compiler-live-set-contains? ineligible 1)
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 0))
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 2)))]))

;; Scalar plan (#perf): the same function, but an integer value live across a
;; call now keeps a callee-saved register home (the integer pool is call-safe),
;; while the unit call result stays ineligible.
(define (compiler-reg-scalar-call-live-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-call-live-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 0))
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 2)))]))

;; Scalar SysV correctness: a FLOAT value live across a call reaches the greedy
;; but has no legal nonvolatile XMM home, so it spills without being structurally
;; ineligible.
(define (compiler-reg-scalar-f64-call-live-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-f64-call-live-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (not
          (compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 0))))]))

(define (compiler-reg-scalar-win64-f64-call-live-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar-for-abi
    cabi.CompilerRegTargetAbi.Windows
    (compiler-reg-f64-call-live-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          (cabi.compiler-abi-xmm-register-id 6)))]))

(define (compiler-reg-f64-call-live-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-f64-call-live-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (live.compiler-live-set-contains? ineligible 1)
        (not
          (compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 0)))
        (compiler-reg-unassigned? assignments 1)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 2)
          (cfg
            scratch-vreg
            (cabi.compiler-abi-xmm-register-id 0)
            (cabi.compiler-abi-xmm-register-id 2))))]))

(define (compiler-reg-call-arg-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-call-arg-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (live.compiler-live-set-contains? ineligible 0)
        (live.compiler-live-set-contains? ineligible 1)
        (compiler-reg-unassigned? assignments 0)
        (compiler-reg-unassigned? assignments 1)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 3)
          cabi.compiler-reg-id-r12))]))

(define (compiler-reg-f64-call-arg-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-f64-call-arg-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (live.compiler-live-set-contains? ineligible 0)
        (compiler-reg-unassigned? assignments 0)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 2)
          (cfg
            scratch-vreg
            (cabi.compiler-abi-xmm-register-id 0)
            (cabi.compiler-abi-xmm-register-id 2))))]))

(define (compiler-reg-ineligible-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-ineligible-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (let
        [marked : bool
          (and
            (live.compiler-live-set-contains? ineligible 0)
            (live.compiler-live-set-contains? ineligible 2)
            (live.compiler-live-set-contains? ineligible 3)
            (live.compiler-live-set-contains? ineligible 4)
            (not (live.compiler-live-set-contains? ineligible 6)))]
        [unassigned : bool
          (and
            (compiler-reg-unassigned? assignments 0)
            (compiler-reg-unassigned? assignments 2)
            (compiler-reg-unassigned? assignments 3)
            (compiler-reg-unassigned? assignments 4))]
        [homes : bool
          (and
            (reg.compiler-reg-location-register?
              (reg.compiler-reg-assignment-lookup assignments 1)
              (cfg
                scratch-vreg
                (cabi.compiler-abi-xmm-register-id 0)
                (cabi.compiler-abi-xmm-register-id 2)))
            (reg.compiler-reg-location-register?
              (reg.compiler-reg-assignment-lookup assignments 5)
              cabi.compiler-reg-id-r12)
            (compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 6)))]
        (and marked unassigned homes))]))

;; Scalar plan (#perf): String/DynArray handles (vars 2/4), AddrOf results
;; (var 6), and clobber-free integer params (var 0) are register-eligible
;; 8-byte values; address-taken values (var 3 via the AddrOf) stay ineligible.
(define (compiler-reg-scalar-handle-eligible-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-ineligible-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (live.compiler-live-set-contains? ineligible 3)
        (not (live.compiler-live-set-contains? ineligible 2))
        (not (live.compiler-live-set-contains? ineligible 4))
        (not (live.compiler-live-set-contains? ineligible 6))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          cabi.compiler-reg-id-rdi))]))

;; M-A2: a handle arg of a gp-parallel direct call is register-eligible exactly
;; like a scalar arg (same GP register class; the backend's parallel move
;; handles register-sourced handle args). Var 0 (the handle, live across the
;; call) is register-homed instead of being kept memory-sourced; the scalar arg
;; (var 1) stays eligible as before.
(define (compiler-reg-scalar-handle-call-arg-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-handle-call-arg-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (not (live.compiler-live-set-contains? ineligible 1))
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 0)))]))

(define (compiler-reg-scalar-indirect-call-arg-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar-for-abi
    cabi.CompilerRegTargetAbi.Linux
    (compiler-reg-indirect-call-arg-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (live.compiler-live-set-contains? ineligible 0)
        (not (live.compiler-live-set-contains? ineligible 1))
        (not (live.compiler-live-set-contains? ineligible 2))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 1)
          cabi.compiler-reg-id-rsi)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 2)
          cabi.compiler-reg-id-rdx))]))

(define (compiler-reg-scalar-c-abi-store-result-call-arg-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar-for-abi
    cabi.CompilerRegTargetAbi.Linux
    (compiler-reg-c-abi-store-result-arg-function))
    [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (live.compiler-live-set-contains? ineligible 0)
        (not (live.compiler-live-set-contains? ineligible 1))
        (not (live.compiler-live-set-contains? ineligible 2))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 1)
          cabi.compiler-reg-id-rsi)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 2)
          cabi.compiler-reg-id-rdx))]))

(define (compiler-reg-scalar-win64-indirect-call-arg-cap-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar-for-abi
    cabi.CompilerRegTargetAbi.Windows
    (compiler-reg-indirect-call-arg4-function))
    [(reg.CompilerRegPlan.Plan _ ineligible _ _ _ _)
      (and
        (live.compiler-live-set-contains? ineligible 0)
        (live.compiler-live-set-contains? ineligible 1)
        (live.compiler-live-set-contains? ineligible 2)
        (live.compiler-live-set-contains? ineligible 3)
        (live.compiler-live-set-contains? ineligible 4))]))

(define (compiler-reg-scalar-function-intervals-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-param-livein-gap-function))
    [(reg.CompilerRegPlan.Plan _ _ intervals _ _ _)
      (reg.compiler-reg-interval-range? intervals 0 0 4)]))

(define (compiler-reg-scalar-interval-guardrail-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-single-block-livein-gap-function))
    [(reg.CompilerRegPlan.Plan _ _ intervals _ _ _)
      (reg.compiler-reg-interval-range? intervals 0 0 2)]))

;; Allocation must consume the edge-precise phi view, not merely compute it for
;; coalescing. In this loop, baseline liveness leaks the entry value through the
;; whole function (0..11) and the back-edge input back to entry (1..12). Exact
;; predecessor-edge uses instead produce the three ranges asserted below.
(define (compiler-reg-scalar-edge-precise-allocation-intervals-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-loop-backedge-function))
    [(reg.CompilerRegPlan.Plan _ _ intervals _ _ _)
      (and
        (= (reg.compiler-reg-interval-seq-count intervals) 3)
        (reg.compiler-reg-interval-range? intervals 0 0 4)
        (reg.compiler-reg-interval-range? intervals 1 4 6)
        (reg.compiler-reg-interval-range? intervals 2 4 12))]))

(define (compiler-reg-scalar-loop-backedge-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-loop-backedge-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      (and
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 1))
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 2))
        (compiler-reg-same-location? assignments 1 2))]))

(define (compiler-reg-syscall-clobber-overlap-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "syscall_clobber_overlap")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    7
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 1)
              (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.I64 2)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  3
                  (ir.CompilerIrValue.I64 3)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    4
                    (ir.CompilerIrValue.I64 4)
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Mov
                      5
                      (ir.CompilerIrValue.I64 5)
                      (compiler-reg-i64-ty))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Syscall
                        6
                        (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.I64 39)))
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.Store
                          (ir.compiler-ir-test-symbol "g0")
                          (ir.CompilerIrValue.Var 0)
                          (compiler-reg-i64-ty))
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.Store
                            (ir.compiler-ir-test-symbol "g1")
                            (ir.CompilerIrValue.Var 1)
                            (compiler-reg-i64-ty))
                          (compiler-reg-test-instr-seq-prepend
                            (ir.CompilerIrInstr.Store
                              (ir.compiler-ir-test-symbol "g2")
                              (ir.CompilerIrValue.Var 2)
                              (compiler-reg-i64-ty))
                            (compiler-reg-test-instr-seq-prepend
                              (ir.CompilerIrInstr.Store
                                (ir.compiler-ir-test-symbol "g3")
                                (ir.CompilerIrValue.Var 3)
                                (compiler-reg-i64-ty))
                              (compiler-reg-test-instr-seq-prepend
                                (ir.CompilerIrInstr.Store
                                  (ir.compiler-ir-test-symbol "g4")
                                  (ir.CompilerIrValue.Var 4)
                                  (compiler-reg-i64-ty))
                                (compiler-reg-test-instr-seq-prepend
                                  (ir.CompilerIrInstr.Store
                                    (ir.compiler-ir-test-symbol "g5")
                                    (ir.CompilerIrValue.Var 5)
                                    (compiler-reg-i64-ty))
                                  (compiler-reg-test-instr-seq-prepend
                                    (ir.CompilerIrInstr.Return
                                      ir.CompilerIrMaybeValue.No)
                                    (ir.compiler-ir-instr-seq-empty))))))))))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-call-spanning-caller-saved-function) : ir.CompilerIrFunction
  (let
    [instrs : ir.CompilerIrInstrSeq (ir.compiler-ir-instr-seq-empty)]
    (begin
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g5c")
            (ir.CompilerIrValue.Var 5)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g5b")
            (ir.CompilerIrValue.Var 5)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g6")
            (ir.CompilerIrValue.Var 6)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g5")
            (ir.CompilerIrValue.Var 5)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g4")
            (ir.CompilerIrValue.Var 4)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g3")
            (ir.CompilerIrValue.Var 3)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g2")
            (ir.CompilerIrValue.Var 2)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g1")
            (ir.CompilerIrValue.Var 1)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g0")
            (ir.CompilerIrValue.Var 0)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Call
            7
            (ir.compiler-ir-test-symbol "side_effect")
            (ir.CompilerIrCallArgs.Nil)
            (ast.AstType.Unit))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            6
            (ir.CompilerIrValue.I64 6)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            5
            (ir.CompilerIrValue.I64 5)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            4
            (ir.CompilerIrValue.I64 4)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            3
            (ir.CompilerIrValue.I64 3)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            2
            (ir.CompilerIrValue.I64 2)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            1
            (ir.CompilerIrValue.I64 1)
            (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty))
          instrs))
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "call_spanning_caller_saved")
        ir.CompilerIrParamList.Nil
        (ast.AstType.Unit)
        8
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block (ir.compiler-ir-label "entry") instrs)
          ir.CompilerIrBlockList.Nil)))))

(define (compiler-reg-scalar-zero-call-caller-saved-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar (compiler-reg-overlap-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      (and
        (= (reg.compiler-reg-assignment-count assignments) 7)
        (= (reg.compiler-reg-spill-count assignments) 0)
        ;; #perf call-spanning-aware partitioning homes the non-call-spanning
        ;; values in the caller-saved pool in candidate order. With %rax/%rsi/%rdi
        ;; now pooled at the front, the leading vars land on %rax/%rsi/%rdi (was
        ;; %r9/%rcx/%rdx). Every value still gets a register (0 spills); sound here
        ;; because this is a zero-call function -- no clobber across a call.
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          cabi.compiler-reg-id-rax)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 1)
          cabi.compiler-reg-id-rsi)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 2)
          cabi.compiler-reg-id-rdi))]))

(define (compiler-reg-scalar-caller-saved-clobber-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-syscall-clobber-overlap-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      (and
        ;; W3 step (a) NON-VACUITY. The one value the syscall's clobber pushes
        ;; out is a single-def i64 LITERAL, so the assignment rewrite converts
        ;; its spill into a rematerialisation: no frame slot, no def store, one
        ;; `movl $5` at the use. Before the literal widening this asserted a
        ;; single Spill at stack slot 5; reverting the widening fails here.
        (= (reg.compiler-reg-spill-count assignments) 0)
        (compiler-reg-maybe-location-remat?
          (reg.compiler-reg-assignment-lookup assignments 5)))]))

(define (compiler-reg-scalar-call-spanning-caller-saved-ok?) : bool
  (let
    [func : ir.CompilerIrFunction
      (compiler-reg-call-spanning-caller-saved-function)]
    [plan : reg.CompilerRegPlan (reg.compiler-reg-plan-function-scalar func)]
    (match plan
      [(reg.CompilerRegPlan.Plan assignments _ _ _ split-vars _)
        (and
          ;; 7 call-spanning values vs 5 callee-saved registers -> 2 spill (call-
          ;; spanning values cannot use caller-saved across the call). The greedy's
          ;; spill-weight priority keeps the hottest value (var 5, stored 3x)
          ;; register-homed and spills the single-use overflow; var 6 overflows to
          ;; the stack and needs no save/restore rescue. (The old allocator spilled
          ;; var 5 then save/restored it; the unified greedy's weight ordering
          ;; avoids that round-trip -- a strict improvement.)
          ;; W3 step (a): both overflow values are single-def i64 literals, so
          ;; the spills the weight order picked become rematerialisations
          ;; instead of frame slots (was: 2 spills, var 6 at stack slot 6).
          (= (reg.compiler-reg-spill-count assignments) 0)
          (compiler-reg-maybe-location-remat?
            (reg.compiler-reg-assignment-lookup assignments 6))
          (not
            (live.compiler-live-set-contains?
              (reg.compiler-reg-call-split-shadows split-vars)
              5))
          (not
            (live.compiler-live-set-contains?
              (reg.compiler-reg-call-split-shadows split-vars)
              6)))])))

(define (compiler-reg-same-location?
  [assignments : reg.CompilerRegAssignmentTable]
  [left : i64]
  [right : i64]) : bool
  (match (reg.compiler-reg-assignment-lookup assignments left)
    [(reg.CompilerRegMaybeLocation.Some left-location)
      (match (reg.compiler-reg-assignment-lookup assignments right)
        [(reg.CompilerRegMaybeLocation.Some right-location)
          (reg.compiler-reg-location-eq? left-location right-location)]
        [(reg.CompilerRegMaybeLocation.No) false])]
    [(reg.CompilerRegMaybeLocation.No) false]))

(define (compiler-reg-different-location?
  [assignments : reg.CompilerRegAssignmentTable]
  [left : i64]
  [right : i64]) : bool
  (match (reg.compiler-reg-assignment-lookup assignments left)
    [(reg.CompilerRegMaybeLocation.Some left-location)
      (match (reg.compiler-reg-assignment-lookup assignments right)
        [(reg.CompilerRegMaybeLocation.Some right-location)
          (not (reg.compiler-reg-location-eq? left-location right-location))]
        [(reg.CompilerRegMaybeLocation.No) false])]
    [(reg.CompilerRegMaybeLocation.No) false]))

(define (compiler-reg-dense-lookups-ok?) : bool
  (let
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-insert
        (reg.compiler-reg-assignment-insert
          (reg.compiler-reg-assignment-insert
            (reg.compiler-reg-assignment-table-empty)
            1
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))
          4
          (reg.CompilerRegLocation.RegisterPair
            cabi.compiler-reg-id-r13
            cabi.compiler-reg-id-r14))
        3
        (reg.CompilerRegLocation.Spill 24))]
    [intervals : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 2 5)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 3 5 9)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 4 1 4)
            (reg.compiler-reg-interval-seq-prepend
              (reg.CompilerRegInterval 4 8 10)
              (reg.compiler-reg-interval-seq-empty)))))]
    [assignment-index : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-with-min-capacity assignments 5)]
    [assignment-table : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-insert
          (reg.compiler-reg-assignment-table-insert
            (reg.compiler-reg-assignment-table-make 5)
            1
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))
          4
          (reg.CompilerRegLocation.RegisterPair
            cabi.compiler-reg-id-r13
            cabi.compiler-reg-id-r14))
        3
        (reg.CompilerRegLocation.Spill 24))]
    [interval-index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build intervals 5)]
    [starts : (__tl_dyn-array i64) interval-index.starts]
    [ends : (__tl_dyn-array i64) interval-index.ends]
    [assignment-hit-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-index 1)
        [(reg.CompilerRegMaybeLocation.Some location)
          (reg.compiler-reg-location-eq?
            location
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
        [(reg.CompilerRegMaybeLocation.No) false])]
    [assignment-miss-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-index 2)
        [(reg.CompilerRegMaybeLocation.Some _) false]
        [(reg.CompilerRegMaybeLocation.No) true])]
    [assignment-oob-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-index -1)
        [(reg.CompilerRegMaybeLocation.Some _) false]
        [(reg.CompilerRegMaybeLocation.No) true])]
    [table-hit-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-table 1)
        [(reg.CompilerRegMaybeLocation.Some location)
          (reg.compiler-reg-location-eq?
            location
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
        [(reg.CompilerRegMaybeLocation.No) false])]
    [table-miss-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-table 2)
        [(reg.CompilerRegMaybeLocation.Some _) false]
        [(reg.CompilerRegMaybeLocation.No) true])]
    [table-oob-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-table -1)
        [(reg.CompilerRegMaybeLocation.Some _) false]
        [(reg.CompilerRegMaybeLocation.No) true])]
    [table-direct-ok : bool
      (and
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignment-table 1)
          cabi.compiler-reg-id-r12)
        (reg.compiler-reg-location-eq?
          (match (reg.compiler-reg-assignment-lookup assignment-table 3)
            [(reg.CompilerRegMaybeLocation.Some location) location]
            [(reg.CompilerRegMaybeLocation.No)
              (reg.CompilerRegLocation.Spill -1)])
          (reg.CompilerRegLocation.Spill 24)))]
    [interval-hit-ok : bool
      (match (reg.compiler-reg-interval-index-lookup interval-index 3)
        [(reg.CompilerRegMaybeInterval.Some interval)
          (and (= interval.var 3) (= interval.start 5) (= interval.end 9))]
        [(reg.CompilerRegMaybeInterval.No) false])]
    [interval-miss-ok : bool
      (match (reg.compiler-reg-interval-index-lookup interval-index 2)
        [(reg.CompilerRegMaybeInterval.Some _) false]
        [(reg.CompilerRegMaybeInterval.No) true])]
    [interval-first-ok : bool
      (match (reg.compiler-reg-interval-index-lookup interval-index 4)
        [(reg.CompilerRegMaybeInterval.Some interval)
          (and (= interval.var 4) (= interval.start 1) (= interval.end 4))]
        [(reg.CompilerRegMaybeInterval.No) false])]
    [interference-ok : bool
      (and
        (not (reg.compiler-reg-vars-interfere-index? interval-index 1 3))
        (reg.compiler-reg-vars-interfere-index? interval-index 1 2))]
    [conflict-ok : bool
      (and
        (not
          (reg.compiler-reg-location-conflicts?
            assignments
            interval-index
            3
            -1
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12)))
        (reg.compiler-reg-location-conflicts?
          assignments
          interval-index
          2
          -1
          (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12)))]
    [table-conflict-ok : bool
      (and
        (not
          (reg.compiler-reg-assignment-table-location-conflicts?
            assignment-table
            interval-index
            3
            -1
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12)))
        (reg.compiler-reg-assignment-table-location-conflicts?
          assignment-table
          interval-index
          2
          -1
          (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12)))]
    [shared-query-ok : bool
      (and
        (reg.compiler-reg-location-uses-register?
          (reg.CompilerRegLocation.RegisterPair
            cabi.compiler-reg-id-r13
            cabi.compiler-reg-id-r14)
          cabi.compiler-reg-id-r14)
        (not
          (reg.compiler-reg-location-uses-register?
            (reg.CompilerRegLocation.RegisterPair
              cabi.compiler-reg-id-r13
              cabi.compiler-reg-id-r14)
            cabi.compiler-reg-id-r15))
        (reg.compiler-reg-assignment-table-var-uses-register?
          assignment-index
          1
          cabi.compiler-reg-id-r12)
        (reg.compiler-reg-assignment-table-var-uses-register?
          assignment-index
          4
          cabi.compiler-reg-id-r14)
        (=
          (reg.compiler-reg-assignment-table-primary-register-home
            assignment-index
            4)
          cabi.compiler-reg-id-r13)
        (reg.compiler-reg-assignments-use-register?
          assignments
          cabi.compiler-reg-id-r14)
        (not
          (reg.compiler-reg-assignments-use-register?
            assignments
            cabi.compiler-reg-id-r15))
        (reg.compiler-reg-var-live-at-point? starts ends 1 3)
        (not (reg.compiler-reg-var-live-at-point? starts ends 1 6))
        (reg.compiler-reg-var-live-over-range? starts ends 1 5 7)
        (not (reg.compiler-reg-var-live-over-range? starts ends 1 6 7))
        (not
          (reg.compiler-reg-assignment-table-register-free-at-point?
            starts
            ends
            assignment-index
            5
            3
            cabi.compiler-reg-id-r12))
        (reg.compiler-reg-assignment-table-register-free-at-point?
          starts
          ends
          assignment-index
          5
          6
          cabi.compiler-reg-id-r12)
        (not
          (reg.compiler-reg-assignment-table-register-free-over-range?
            starts
            ends
            assignment-index
            5
            3
            4
            cabi.compiler-reg-id-r14))
        (reg.compiler-reg-assignment-table-register-free-over-range?
          starts
          ends
          assignment-index
          5
          0
          0
          cabi.compiler-reg-id-r12))]
    (and
      assignment-hit-ok
      assignment-miss-ok
      assignment-oob-ok
      table-hit-ok
      table-miss-ok
      table-oob-ok
      table-direct-ok
      interval-hit-ok
      interval-miss-ok
      interval-first-ok
      interference-ok
      conflict-ok
      table-conflict-ok
      shared-query-ok)))

(define (compiler-reg-dense-assignment-snapshot-ok?) : bool
  (let
    [base : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-insert
        (reg.compiler-reg-assignment-table-empty)
        2
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
    [successor : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-override-copy
        base
        2
        (reg.CompilerRegLocation.Spill 40))]
    [expanded : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-override-copy
        successor
        9
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r13))]
    (and
      (= (reg.compiler-reg-assignment-count base) 1)
      (= (reg.compiler-reg-assignment-count successor) 1)
      (= (reg.compiler-reg-assignment-count expanded) 2)
      (>= (array-length expanded.present) 10)
      (reg.compiler-reg-location-register?
        (reg.compiler-reg-assignment-lookup base 2)
        cabi.compiler-reg-id-r12)
      (match (reg.compiler-reg-assignment-lookup successor 2)
        [(reg.CompilerRegMaybeLocation.Some location)
          (reg.compiler-reg-location-eq?
            location
            (reg.CompilerRegLocation.Spill 40))]
        [(reg.CompilerRegMaybeLocation.No) false])
      (match (reg.compiler-reg-assignment-lookup base 9)
        [(reg.CompilerRegMaybeLocation.Some _) false]
        [(reg.CompilerRegMaybeLocation.No) true])
      (reg.compiler-reg-location-register?
        (reg.compiler-reg-assignment-lookup expanded 9)
        cabi.compiler-reg-id-r13))))

(define (compiler-reg-segmented-interference-ok?) : bool
  (let
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [ends : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [segments : (__tl_dyn-array reg.CompilerRegIntervalSeq)
      (__tl_make-array reg.CompilerRegIntervalSeq 5)]
    [segment-index : reg.CompilerRegIntervalIndex
      (reg.CompilerRegIntervalIndex starts ends segments)]
    (begin
      (reg.compiler-reg-fill-i64-array starts -1)
      (reg.compiler-reg-fill-i64-array ends -1)
      (set! (array-ref starts 0) 0)
      (set! (array-ref ends 0) 8)
      (set! (array-ref starts 1) 0)
      (set! (array-ref ends 1) 8)
      (set! (array-ref starts 3) 3)
      (set! (array-ref ends 3) 5)
      (set! (array-ref starts 4) 7)
      (set! (array-ref ends 4) 9)
      (set!
        (array-ref segments 1)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 0 2)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 1 6 8)
            (reg.compiler-reg-interval-seq-empty))))
      (set!
        (array-ref segments 3)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 3 3 5)
          (reg.compiler-reg-interval-seq-empty)))
      (set!
        (array-ref segments 4)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 4 7 9)
          (reg.compiler-reg-interval-seq-empty)))
      (and
        (not
          (reg.compiler-reg-vars-interfere-segmented-index? segment-index 1 3))
        (reg.compiler-reg-vars-interfere-segmented-index? segment-index 1 4)
        (reg.compiler-reg-vars-interfere-segmented-index? segment-index 0 3)
        (reg.compiler-reg-vars-interfere-segmented-index? segment-index 1 2)))))

(define (compiler-reg-hole-aware-register-reuse-ok?) : bool
  (let
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [ends : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [segments : (__tl_dyn-array reg.CompilerRegIntervalSeq)
      (__tl_make-array reg.CompilerRegIntervalSeq 5)]
    [segment-index : reg.CompilerRegIntervalIndex
      (reg.CompilerRegIntervalIndex starts ends segments)]
    [one-reg : reg.CompilerRegIdSeq
      (reg.compiler-reg-id-seq-prepend
        cabi.compiler-reg-id-r12
        (reg.compiler-reg-id-seq-empty))]
    [active-root : reg.CompilerRegActiveSeq
      (reg.compiler-reg-active-insert
        (reg.compiler-reg-active-seq-empty)
        (reg.CompilerRegActive 0 10 cabi.compiler-reg-id-r12))]
    [active-ordinary : reg.CompilerRegActiveSeq
      (reg.compiler-reg-active-insert
        (reg.compiler-reg-active-seq-empty)
        (reg.CompilerRegActive 1 10 cabi.compiler-reg-id-r12))]
    [hole-aware : live.CompilerLiveI64Set (live.compiler-live-set3 0 2 3)]
    [parents : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    (begin
      (reg.compiler-reg-fill-i64-array starts -1)
      (reg.compiler-reg-fill-i64-array ends -1)
      (set! (array-ref starts 0) 0)
      (set! (array-ref ends 0) 10)
      (set! (array-ref starts 1) 4)
      (set! (array-ref ends 1) 6)
      (set! (array-ref starts 2) 4)
      (set! (array-ref ends 2) 6)
      (set! (array-ref starts 3) 1)
      (set! (array-ref ends 3) 3)
      (set! (array-ref starts 4) 8)
      (set! (array-ref ends 4) 9)
      (set!
        (array-ref segments 0)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 0 0 2)
          (reg.compiler-reg-interval-seq-empty)))
      (set!
        (array-ref segments 1)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 4 6)
          (reg.compiler-reg-interval-seq-empty)))
      (set!
        (array-ref segments 2)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 2 4 6)
          (reg.compiler-reg-interval-seq-empty)))
      (set!
        (array-ref segments 3)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 3 1 3)
          (reg.compiler-reg-interval-seq-empty)))
      (set!
        (array-ref segments 4)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 4 8 9)
          (reg.compiler-reg-interval-seq-empty)))
      (set! (array-ref parents 0) 0)
      (set! (array-ref parents 1) 0)
      (set! (array-ref parents 2) 2)
      (set! (array-ref parents 3) 2)
      (set! (array-ref parents 4) 4)
      (let
        ;; General hole-filling: the allocator runs on the merged-root
        ;; index, whose per-candidate segments are COMPLETE -- a singleton carries
        ;; its own live range, a class root the union of its members'. Every
        ;; segment hole is therefore genuine deadness, so ANY value may reuse an
        ;; active register in a hole whose segments are disjoint, regardless of
        ;; whether it is a coalesce root or a singleton. var 1's segment [4,6] is
        ;; disjoint from the active root var 0's [0,2], so it reuses %r12.
        [var1-disjoint-reuses : bool
          (match (reg.compiler-reg-first-free-register-holes
            one-reg
            active-root
            segment-index
            1
            hole-aware)
            [(reg.CompilerRegMaybeId.Some reg) (= reg cabi.compiler-reg-id-r12)]
            [(reg.CompilerRegMaybeId.No) false])]
        [root-hole-reuses : bool
          (match (reg.compiler-reg-first-free-register-holes
            one-reg
            active-root
            segment-index
            2
            hole-aware)
            [(reg.CompilerRegMaybeId.Some reg) (= reg cabi.compiler-reg-id-r12)]
            [(reg.CompilerRegMaybeId.No) false])]
        ;; overlap still conflicts: var 3's segment [1,3] overlaps var 0's [0,2].
        [root-overlap-conflicts : bool
          (match (reg.compiler-reg-first-free-register-holes
            one-reg
            active-root
            segment-index
            3
            hole-aware)
            [(reg.CompilerRegMaybeId.No) true]
            [(reg.CompilerRegMaybeId.Some _) false])]
        ;; var 4's [8,9] is disjoint from the active ordinary var 1's [4,6].
        [var4-disjoint-reuses : bool
          (match (reg.compiler-reg-first-free-register-holes
            one-reg
            active-ordinary
            segment-index
            4
            hole-aware)
            [(reg.CompilerRegMaybeId.Some reg) (= reg cabi.compiler-reg-id-r12)]
            [(reg.CompilerRegMaybeId.No) false])]
        [roots : live.CompilerLiveI64Set
          (reg.compiler-reg-coalesce-merged-root-set
            (reg.CompilerRegCoalesceMap parents))]
        [mapped-blocked : live.CompilerLiveI64Set
          (reg.compiler-reg-coalesce-root-set-from-vars
            (reg.CompilerRegCoalesceMap parents)
            (live.compiler-live-set2 1 4))]
        (and
          var1-disjoint-reuses
          root-hole-reuses
          root-overlap-conflicts
          var4-disjoint-reuses
          (live.compiler-live-set-contains? roots 0)
          (live.compiler-live-set-contains? roots 2)
          (not (live.compiler-live-set-contains? roots 1))
          (not (live.compiler-live-set-contains? roots 3))
          (not (live.compiler-live-set-contains? roots 4))
          (live.compiler-live-set-contains? mapped-blocked 0)
          (live.compiler-live-set-contains? mapped-blocked 4)
          (not (live.compiler-live-set-contains? mapped-blocked 1))
          (not (live.compiler-live-set-contains? mapped-blocked 2))
          (not (live.compiler-live-set-contains? mapped-blocked 3)))))))

(define (compiler-reg-coalesce-test-i64-types [vars : i64]) : reg.CompilerRegVarTypes
  (let
    [present : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
    [types : (__tl_dyn-array ast.AstType) (__tl_make-array ast.AstType vars)]
    [index : i64 0]
    (begin
      (while (< index vars)
        (begin
          (set! (array-ref present index) 1)
          (set! (array-ref types index) (compiler-reg-i64-ty))
          (set! index (+ index 1))))
      (reg.CompilerRegVarTypes
        present
        types
        (ir.compiler-ir-representation-index-empty)
        (profile_state.compiler-profile-state-metrics
          (profile_state.compiler-profile-state-new))))))

(define (compiler-reg-coalesce-test-flat-index) : reg.CompilerRegIntervalIndex
  (reg.compiler-reg-interval-index-build
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 0 1)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 4 5)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 2 2 3)
          (reg.compiler-reg-interval-seq-empty))))
    3))

(define (compiler-reg-coalesce-test-overlap-index) : reg.CompilerRegIntervalIndex
  (reg.compiler-reg-interval-index-build
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 0 5)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 2 6)
        (reg.compiler-reg-interval-seq-empty)))
    2))

(define (compiler-reg-coalesce-test-segment-index) : reg.CompilerRegIntervalIndex
  (let
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [ends : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [segments : (__tl_dyn-array reg.CompilerRegIntervalSeq)
      (__tl_make-array reg.CompilerRegIntervalSeq 2)]
    (begin
      (reg.compiler-reg-fill-i64-array starts -1)
      (reg.compiler-reg-fill-i64-array ends -1)
      (set! (array-ref starts 0) 0)
      (set! (array-ref ends 0) 10)
      (set! (array-ref starts 1) 0)
      (set! (array-ref ends 1) 10)
      (set!
        (array-ref segments 0)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 0 0 2)
          (reg.compiler-reg-interval-seq-empty)))
      (set!
        (array-ref segments 1)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 4 6)
          (reg.compiler-reg-interval-seq-empty)))
      (reg.CompilerRegIntervalIndex starts ends segments))))

(define (compiler-reg-coalesce-fixpoint-map-ok?) : bool
  (let
    [types : reg.CompilerRegVarTypes (compiler-reg-coalesce-test-i64-types 3)]
    [moves : reg.CompilerRegMoveSeq
      (reg.compiler-reg-move-list-add
        (reg.compiler-reg-move-list-add
          (reg.compiler-reg-move-seq-empty)
          0
          2
          false
          true)
        2
        1
        false
        true)]
    [index : reg.CompilerRegIntervalIndex
      (compiler-reg-coalesce-test-flat-index)]
    [coalesce : reg.CompilerRegCoalesceMap
      (reg.compiler-reg-coalesce-map-build
        moves
        index
        types
        (live.compiler-live-set-empty)
        3
        (__tl_make-array i64 0))]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 3)
        0
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
    [tie-assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-insert
          (reg.compiler-reg-assignment-table-make 3)
          2
          (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r13))
        0
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
    (and
      (reg.compiler-reg-location-register?
        (reg.compiler-reg-coalesce-location coalesce assignments index 1)
        cabi.compiler-reg-id-r12)
      (reg.compiler-reg-location-register?
        (reg.compiler-reg-coalesce-location coalesce tie-assignments index 1)
        cabi.compiler-reg-id-r12))))

(define (compiler-reg-coalesce-interference-reject-ok?) : bool
  (let
    [types : reg.CompilerRegVarTypes (compiler-reg-coalesce-test-i64-types 2)]
    [moves : reg.CompilerRegMoveSeq
      (reg.compiler-reg-move-list-add
        (reg.compiler-reg-move-seq-empty)
        0
        1
        false
        true)]
    [index : reg.CompilerRegIntervalIndex
      (compiler-reg-coalesce-test-overlap-index)]
    [coalesce : reg.CompilerRegCoalesceMap
      (reg.compiler-reg-coalesce-map-build
        moves
        index
        types
        (live.compiler-live-set-empty)
        2
        (__tl_make-array i64 0))]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 2)
        0
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
    (match (reg.compiler-reg-coalesce-location coalesce assignments index 1)
      [(reg.CompilerRegMaybeLocation.No) true]
      [(reg.CompilerRegMaybeLocation.Some _) false])))

(define (compiler-reg-coalesce-segmented-map-ok?) : bool
  (let
    [types : reg.CompilerRegVarTypes (compiler-reg-coalesce-test-i64-types 2)]
    [moves : reg.CompilerRegMoveSeq
      (reg.compiler-reg-move-list-add
        (reg.compiler-reg-move-seq-empty)
        0
        1
        false
        true)]
    [index : reg.CompilerRegIntervalIndex
      (compiler-reg-coalesce-test-segment-index)]
    [coalesce : reg.CompilerRegCoalesceMap
      (reg.compiler-reg-coalesce-map-build
        moves
        index
        types
        (live.compiler-live-set-empty)
        2
        (__tl_make-array i64 0))]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 2)
        0
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
    (reg.compiler-reg-location-register?
      (reg.compiler-reg-coalesce-location coalesce assignments index 1)
      cabi.compiler-reg-id-r12)))

(define (compiler-reg-coalesce-strict-segmented-reject-ok?) : bool
  (let
    [types : reg.CompilerRegVarTypes (compiler-reg-coalesce-test-i64-types 2)]
    [moves : reg.CompilerRegMoveSeq
      (reg.compiler-reg-move-list-add
        (reg.compiler-reg-move-seq-empty)
        0
        1
        true
        true)]
    [index : reg.CompilerRegIntervalIndex
      (compiler-reg-coalesce-test-segment-index)]
    [coalesce : reg.CompilerRegCoalesceMap
      (reg.compiler-reg-coalesce-map-build
        moves
        index
        types
        (live.compiler-live-set-empty)
        2
        (__tl_make-array i64 0))]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 2)
        0
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
    (match (reg.compiler-reg-coalesce-location coalesce assignments index 1)
      [(reg.CompilerRegMaybeLocation.No) true]
      [(reg.CompilerRegMaybeLocation.Some _) false])))

(define (compiler-reg-single-segment-range?
  [segments : reg.CompilerRegIntervalSeq]
  [var : i64]
  [start : i64]
  [end : i64]) : bool
  (and
    (= (reg.compiler-reg-interval-seq-count segments) 1)
    (let
      [found : reg.CompilerRegInterval
        (reg.compiler-reg-interval-seq-ref segments 0)]
      (and (= found.var var) (= found.start start) (= found.end end)))))

(define (compiler-reg-merged-root-overlap-segments-ok?) : bool
  (let
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [ends : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [segments : (__tl_dyn-array reg.CompilerRegIntervalSeq)
      (__tl_make-array reg.CompilerRegIntervalSeq 3)]
    [parents : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    (begin
      (reg.compiler-reg-fill-i64-array starts -1)
      (reg.compiler-reg-fill-i64-array ends -1)
      (set! (array-ref segments 0) (reg.compiler-reg-interval-seq-empty))
      (set! (array-ref segments 1) (reg.compiler-reg-interval-seq-empty))
      (set! (array-ref segments 2) (reg.compiler-reg-interval-seq-empty))
      (set! (array-ref starts 0) 0)
      (set! (array-ref ends 0) 6)
      (set! (array-ref starts 1) 2)
      (set! (array-ref ends 1) 8)
      (set!
        (array-ref segments 0)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 0 0 4)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 0 5 6)
            (reg.compiler-reg-interval-seq-empty))))
      (set!
        (array-ref segments 1)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 2 8)
          (reg.compiler-reg-interval-seq-empty)))
      (set! (array-ref parents 0) 0)
      (set! (array-ref parents 1) 0)
      (set! (array-ref parents 2) 2)
      (let
        [merged : reg.CompilerRegIntervalIndex
          (reg.compiler-reg-merged-root-index
            (reg.CompilerRegCoalesceMap parents)
            (reg.CompilerRegIntervalIndex starts ends segments))]
        (and
          (= (array-ref merged.starts 0) 0)
          (= (array-ref merged.ends 0) 8)
          (< (array-ref merged.starts 1) 0)
          (compiler-reg-single-segment-range?
            (array-ref merged.segments 0)
            0
            0
            8))))))

(define (compiler-reg-same-value-multi-def-census-ok?) : bool
  (let
    [parents : (__tl_dyn-array i64)
      (reg.compiler-reg-function-same-value-parents
        (compiler-reg-same-value-multi-def-census-function))]
    (not (reg.compiler-reg-same-value-class? parents 0 1))))

(define (compiler-reg-same-value-phi-census-ok?) : bool
  (let
    [parents : (__tl_dyn-array i64)
      (reg.compiler-reg-function-same-value-parents
        (compiler-reg-loop-backedge-function))]
    (not (reg.compiler-reg-same-value-class? parents 1 2))))

(define (compiler-reg-same-value-clobber-census-ok?) : bool
  (let
    [func : ir.CompilerIrFunction (compiler-reg-same-value-clobber-function)]
    [selection : reg.CompilerRegIntervalSelection
      (reg.compiler-reg-live-interval-selection
        func
        (live.compiler-live-analyze-function func))]
    (match selection
      [(reg.CompilerRegIntervalSelection.Selection _ interval-index)
        (let
          [parents : (__tl_dyn-array i64)
            (reg.compiler-reg-function-same-value-parents-filtered
              func
              (reg.compiler-reg-same-value-eligible-vars
                interval-index
                (reg.compiler-reg-clobber-kind-points
                  (ast.ast-node-pool-reader-type-segment-bases)
                  func
                  0)))]
          (not (reg.compiler-reg-same-value-class? parents 0 2)))])))

;; M-C (part 1): build the extended relation the way plan-from does (precise
;; selection index + kind-0 eligibility + var types).
(define (compiler-reg-sv-multi-parents-for [func : ir.CompilerIrFunction]) : (__tl_dyn-array
    i64)
  (match (reg.compiler-reg-live-interval-selection
    func
    (live.compiler-live-analyze-function func))
    [(reg.CompilerRegIntervalSelection.Selection _ interval-index)
      (reg.compiler-reg-function-same-value-parents-multi
        func
        (reg.compiler-reg-same-value-eligible-vars
          interval-index
          (reg.compiler-reg-clobber-kind-points
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            0))
        (reg.compiler-reg-same-value-eligible-vars
          interval-index
          (live.compiler-live-set-empty))
        (reg.compiler-reg-function-var-types func)
        interval-index)]))

(define (compiler-reg-sv-multi-ok?) : bool
  (let
    [safe : (__tl_dyn-array i64)
      (compiler-reg-sv-multi-parents-for (compiler-reg-sv-multi-safe-function))]
    [reject : (__tl_dyn-array i64)
      (compiler-reg-sv-multi-parents-for
        (compiler-reg-sv-multi-reject-function))]
    [chain : (__tl_dyn-array i64)
      (compiler-reg-sv-multi-parents-for (compiler-reg-sv-multi-chain-function))]
    [cast : (__tl_dyn-array i64)
      (compiler-reg-sv-multi-parents-for (compiler-reg-sv-multi-cast-function))]
    (and
      (reg.compiler-reg-same-value-class? safe 0 1)
      (not (reg.compiler-reg-same-value-class? reject 0 1))
      (reg.compiler-reg-same-value-class? chain 2 3)
      (not (reg.compiler-reg-same-value-class? chain 0 2))
      (not (reg.compiler-reg-same-value-class? chain 0 3))
      (reg.compiler-reg-same-value-class? cast 0 1))))

(define (compiler-reg-coalesce-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-move-chain-function))
    [(reg.CompilerRegPlan.Plan chain-assignments _ _ _ _ _)
      (match (reg.compiler-reg-plan-function (compiler-reg-phi-join-function))
        [(reg.CompilerRegPlan.Plan phi-assignments _ _ _ _ _)
          (match (reg.compiler-reg-plan-function
            (compiler-reg-loop-backedge-function))
            [(reg.CompilerRegPlan.Plan loop-assignments _ _ _ _ _)
              (match (reg.compiler-reg-plan-function
                (compiler-reg-interference-blocks-coalesce-function))
                [(reg.CompilerRegPlan.Plan blocked-assignments _ _ _ _ _)
                  (match (reg.compiler-reg-plan-function
                    (compiler-reg-spill-coalesce-function))
                    [(reg.CompilerRegPlan.Plan spill-assignments _ _ _ _ _)
                      (and
                        (reg.compiler-reg-move-list-parallel-decision-ok?)
                        (compiler-reg-same-location? chain-assignments 0 1)
                        (compiler-reg-same-location? chain-assignments 1 2)
                        (compiler-reg-same-location? phi-assignments 0 1)
                        (compiler-reg-different-location? loop-assignments 1 2)
                        (compiler-reg-different-location?
                          blocked-assignments
                          0
                          1)
                        (compiler-reg-same-location? spill-assignments 4 5)
                        (compiler-reg-destructive-chain-ok?)
                        (compiler-reg-coalesce-fixpoint-map-ok?)
                        (compiler-reg-coalesce-interference-reject-ok?)
                        (compiler-reg-coalesce-segmented-map-ok?)
                        (compiler-reg-coalesce-strict-segmented-reject-ok?)
                        (compiler-reg-merged-root-overlap-segments-ok?)
                        (compiler-reg-same-value-multi-def-census-ok?)
                        (compiler-reg-same-value-phi-census-ok?)
                        (compiler-reg-same-value-clobber-census-ok?)
                        (compiler-reg-sv-multi-ok?))])])])])]))

;; ---------------------------------------------------------------------------
;; Tail calls are not clobber points; clobber spanning is segment-precise.
;; ---------------------------------------------------------------------------
;; Two-arm dispatcher, every arm a TAIL call. `k` selects the arm; both
;; parameters are marshalled (permuted) into the outgoing argument registers.
(define (compiler-reg-tail-dispatch-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "tail_dispatch")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "k" (compiler-reg-i64-ty) 0)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "v" (compiler-reg-i64-ty) 1)
        ir.CompilerIrParamList.Nil))
    (compiler-reg-i64-ty)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.BinOp
            2
            (ir.CompilerIrBinOp.Eq)
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Var 2)
              (ir.compiler-ir-label "arm_a")
              (ir.compiler-ir-label "arm_b"))
            (ir.compiler-ir-instr-seq-empty))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "arm_a")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.TailCall
              (ir.compiler-ir-test-symbol "step_a")
              (ir.CompilerIrCallArgs.Two
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.Var 1))
              (compiler-reg-i64-ty))
            (ir.compiler-ir-instr-seq-empty)))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "arm_b")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.TailCall
                (ir.compiler-ir-test-symbol "step_b")
                (ir.CompilerIrCallArgs.Two
                  (ir.CompilerIrValue.Var 1)
                  (ir.CompilerIrValue.Var 0))
                (compiler-reg-i64-ty))
              (ir.compiler-ir-instr-seq-empty)))
          ir.CompilerIrBlockList.Nil)))))

;; Same dispatcher with a REAL call in the arm that runs FIRST in block order,
;; and both parameters live across it. Nothing may be un-pinned here.
(define (compiler-reg-tail-dispatch-real-call-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "tail_dispatch_real")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "k" (compiler-reg-i64-ty) 0)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "v" (compiler-reg-i64-ty) 1)
        ir.CompilerIrParamList.Nil))
    (compiler-reg-i64-ty)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.BinOp
            2
            (ir.CompilerIrBinOp.Eq)
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Var 2)
              (ir.compiler-ir-label "call_arm")
              (ir.compiler-ir-label "tail_arm"))
            (ir.compiler-ir-instr-seq-empty))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "call_arm")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Call
              3
              (ir.compiler-ir-test-symbol "side_effect")
              ir.CompilerIrCallArgs.Nil
              (ast.AstType.Unit))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "gk")
                (ir.CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "gv")
                  (ir.CompilerIrValue.Var 1)
                  (compiler-reg-i64-ty))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  (ir.compiler-ir-instr-seq-empty))))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "tail_arm")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.TailCall
                (ir.compiler-ir-test-symbol "step_b")
                (ir.CompilerIrCallArgs.Two
                  (ir.CompilerIrValue.Var 1)
                  (ir.CompilerIrValue.Var 0))
                (compiler-reg-i64-ty))
              (ir.compiler-ir-instr-seq-empty)))
          ir.CompilerIrBlockList.Nil)))))

;; MIXED. `call_arm` runs first in block order and holds a real call that only
;; `v` is live across; `k` is referenced at entry and again in the LAST block,
;; so the real call sits inside `k`'s coarse interval HULL and inside no live
;; SEGMENT of it. `k` must therefore keep %rdi while `v` must not keep %rsi.
(define (compiler-reg-tail-dispatch-mixed-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "tail_dispatch_mixed")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "k" (compiler-reg-i64-ty) 0)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "v" (compiler-reg-i64-ty) 1)
        ir.CompilerIrParamList.Nil))
    (compiler-reg-i64-ty)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.BinOp
            2
            (ir.CompilerIrBinOp.Eq)
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.I64 0)
            (compiler-reg-i64-ty))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Var 2)
              (ir.compiler-ir-label "call_arm")
              (ir.compiler-ir-label "tail_arm"))
            (ir.compiler-ir-instr-seq-empty))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "call_arm")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Call
              3
              (ir.compiler-ir-test-symbol "side_effect")
              ir.CompilerIrCallArgs.Nil
              (ast.AstType.Unit))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "gv")
                (ir.CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
                (ir.compiler-ir-instr-seq-empty)))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "tail_arm")
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.TailCall
                (ir.compiler-ir-test-symbol "step_b")
                (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.Var 0))
                (compiler-reg-i64-ty))
              (ir.compiler-ir-instr-seq-empty)))
          ir.CompilerIrBlockList.Nil)))))

;; Kind 0 counts the whole call-like family; kind 6 drops the tail calls and
;; keeps every resuming call. The pure dispatcher has TWO kind-0 points and NO
;; kind-6 point; the real-call shape has three kind-0 points and exactly one
;; kind-6 point (the `call side_effect`).
(define (compiler-reg-tail-call-kind-points-ok?) : bool
  (let
    [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
    [pure-fn : ir.CompilerIrFunction (compiler-reg-tail-dispatch-function)]
    [real-fn : ir.CompilerIrFunction
      (compiler-reg-tail-dispatch-real-call-function)]
    (and
      (=
        (live.compiler-live-set-count
          (reg.compiler-reg-clobber-kind-points bases pure-fn 0))
        2)
      (=
        (live.compiler-live-set-count
          (reg.compiler-reg-clobber-kind-points bases pure-fn 6))
        0)
      (=
        (live.compiler-live-set-count
          (reg.compiler-reg-clobber-kind-points bases real-fn 0))
        2)
      (=
        (live.compiler-live-set-count
          (reg.compiler-reg-clobber-kind-points bases real-fn 6))
        1))))

;; The segment walk itself: one clobber point in the HOLE between two segments
;; is not spanned, the same point moved inside a segment is. The hull-start
;; convention is exclusive for an ordinary value (its def) and inclusive for a
;; parameter (its home is written by the prologue).
(define (compiler-reg-segment-span-clobber-ok?) : bool
  (let
    [segments : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 4)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 0 12 16)
          (reg.compiler-reg-interval-seq-empty)))]
    [in-hole : live.CompilerLiveI64Set
      (live.compiler-live-set-insert (live.compiler-live-set-empty) 8)]
    [in-segment : live.CompilerLiveI64Set
      (live.compiler-live-set-insert (live.compiler-live-set-empty) 14)]
    [at-hull-start : live.CompilerLiveI64Set
      (live.compiler-live-set-insert (live.compiler-live-set-empty) 0)]
    [at-later-segment-start : live.CompilerLiveI64Set
      (live.compiler-live-set-insert (live.compiler-live-set-empty) 12)]
    (and
      (not (reg.compiler-reg-segments-span-clobber? segments in-hole 0 false))
      (reg.compiler-reg-segments-span-clobber? segments in-segment 0 false)
      ;; A clobber AT the hull start is the value's own defining instruction
      ;; for an ordinary value, and already inside the live range of a param.
      (not
        (reg.compiler-reg-segments-span-clobber? segments at-hull-start 0 false))
      (reg.compiler-reg-segments-span-clobber? segments at-hull-start 0 true)
      ;; A later segment opens where the value flows IN from a predecessor, so
      ;; its start is inclusive under BOTH conventions.
      (reg.compiler-reg-segments-span-clobber?
        segments
        at-later-segment-start
        0
        false)
      (reg.compiler-reg-segments-span-clobber?
        segments
        at-later-segment-start
        0
        true))))

(define (compiler-reg-tail-dispatch-pins-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-tail-dispatch-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      (and
        (= (reg.compiler-reg-spill-count assignments) 0)
        ;; Both params keep their incoming (caller-saved) ABI registers: no
        ;; entry copy, and no callee-saved register enters the plan, so the
        ;; prologue emits no push and each tail-jump tail no pop.
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          cabi.compiler-reg-id-rdi)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 1)
          cabi.compiler-reg-id-rsi))]))

(define (compiler-reg-tail-dispatch-real-call-pins-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-tail-dispatch-real-call-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      ;; Both params are live across a resuming call, so neither may keep a
      ;; caller-saved incoming register.
      (and
        (not
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi))
        (not
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi)))]))

(define (compiler-reg-tail-dispatch-mixed-pins-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-tail-dispatch-mixed-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      (and
        ;; `k` is dead across the real call (it lives in the hole between its
        ;; entry and tail-arm segments) -> keeps %rdi.
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          cabi.compiler-reg-id-rdi)
        ;; `v` really is live across the real call -> loses %rsi.
        (not
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi)))]))

(define (compiler-reg-tail-call-clobber-ok?) : bool
  (and
    (compiler-reg-tail-call-kind-points-ok?)
    (compiler-reg-segment-span-clobber-ok?)
    (compiler-reg-tail-dispatch-pins-ok?)
    (compiler-reg-tail-dispatch-real-call-pins-ok?)
    (compiler-reg-tail-dispatch-mixed-pins-ok?)))

(define (compiler-reg-vector-mask-homes-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-vector-home-function))
    [(reg.CompilerRegPlan.Plan vector-assignments _ _ _ _ _)
      (match (reg.compiler-reg-plan-function
        (compiler-reg-vector-gp-clobber-home-function))
        [(reg.CompilerRegPlan.Plan gp-clobber-assignments _ _ _ _ _)
          (match (reg.compiler-reg-plan-function
            (compiler-reg-vector-select-false-home-function))
            [(reg.CompilerRegPlan.Plan select-assignments _ _ _ _ _)
              (match (reg.compiler-reg-plan-function
                (compiler-reg-mask-home-function))
                [(reg.CompilerRegPlan.Plan mask-assignments _ _ _ _ _)
                  (let
                    [vector-ok : bool
                      (and
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            vector-assignments
                            0)
                          (cabi.compiler-abi-vector-register-id 6))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            vector-assignments
                            1)
                          (cabi.compiler-abi-vector-register-id 7))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            vector-assignments
                            2)
                          (cabi.compiler-abi-vector-register-id 7))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            vector-assignments
                            3)
                          (cabi.compiler-abi-vector-register-id 6)))]
                    [gp-clobber-ok : bool
                      (reg.compiler-reg-location-register?
                        (reg.compiler-reg-assignment-lookup
                          gp-clobber-assignments
                          0)
                        (cabi.compiler-abi-vector-register-id 6))]
                    [select-ok : bool
                      (and
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            select-assignments
                            1)
                          (cabi.compiler-abi-vector-register-id 7))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            select-assignments
                            2)
                          (cabi.compiler-abi-vector-register-id 8))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            select-assignments
                            4)
                          (cabi.compiler-abi-vector-register-id 7)))]
                    [mask-ok : bool
                      (and
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            mask-assignments
                            0)
                          (cabi.compiler-abi-mask-register-id 1))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            mask-assignments
                            1)
                          (cabi.compiler-abi-mask-register-id 2))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            mask-assignments
                            3)
                          (cabi.compiler-abi-mask-register-id 1)))]
                    (and vector-ok gp-clobber-ok select-ok mask-ok))])])])]))

(define (compiler-reg-mask-pressure-spill-home-ok?) : bool
  (match (reg.compiler-reg-plan-function (compiler-reg-mask-pressure-function))
    [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
      ;; Six architectural homes are allocatable (%k1..%k6); the seventh
      ;; simultaneously-live mask must stay unassigned for the backend's
      ;; stack-slot mask spill path.
      (match (reg.compiler-reg-assignment-lookup assignments 6)
        [(reg.CompilerRegMaybeLocation.No) true]
        [_ false])]))

(define (compiler-reg-target-clobbers-ok?) : bool
  (let
    [_rbp-off : unit (reg.compiler-reg-set-rbp-pool-enabled! false)]
    [zero-call-callers : reg.CompilerRegIdSeq
      (reg.compiler-reg-zero-call-caller-saved-integer-registers)]
    [greedy-pool : reg.CompilerRegIdSeq (reg.compiler-reg-greedy-integer-pool)]
    [sysv-callers : reg.CompilerRegIdSeq
      (reg.compiler-reg-sysv-caller-saved-integer-registers)]
    [sysv-callees : reg.CompilerRegIdSeq
      (reg.compiler-reg-sysv-callee-saved-integer-registers)]
    [win-callers : reg.CompilerRegIdSeq
      (reg.compiler-reg-win64-caller-saved-integer-registers)]
    [win-callees : reg.CompilerRegIdSeq
      (reg.compiler-reg-win64-callee-saved-integer-registers)]
    [copy-instr : ir.CompilerIrInstr
      (ir.CompilerIrInstr.CopyBytes
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.Var 1)
        24)]
    [add-instr : ir.CompilerIrInstr
      (ir.CompilerIrInstr.BinOp
        2
        (ir.CompilerIrBinOp.Add)
        (ir.CompilerIrValue.Var 0)
        (ir.CompilerIrValue.Var 1)
        (ast.AstType.I64))]
    (and
      (reg.compiler-reg-id-seq-contains? sysv-callers cabi.compiler-reg-id-rdi)
      (not
        (reg.compiler-reg-id-seq-contains?
          sysv-callees
          cabi.compiler-reg-id-rdi))
      (reg.compiler-reg-id-seq-contains? win-callees cabi.compiler-reg-id-rdi)
      (not
        (reg.compiler-reg-id-seq-contains? win-callers cabi.compiler-reg-id-rdi))
      (not
        (=
          (reg.compiler-reg-id-seq-count
            (reg.compiler-reg-sysv-integer-registers))
          (reg.compiler-reg-id-seq-count win-callees)))
      ;; The callee-saved subpool admits only registers that survive an
      ;; intervening call.
      (reg.compiler-reg-id-seq-contains?
        (reg.compiler-reg-sysv-integer-registers)
        cabi.compiler-reg-id-r12)
      ;; The greedy pool owns the caller-saved backend temps behind the
      ;; clobber-point filter.
      (= (reg.compiler-reg-greedy-caller-saved-count) 9)
      (reg.compiler-reg-id-seq-contains? greedy-pool cabi.compiler-reg-id-r8)
      (reg.compiler-reg-id-seq-contains? greedy-pool cabi.compiler-reg-id-r10)
      (reg.compiler-reg-id-seq-contains? greedy-pool cabi.compiler-reg-id-r11)
      ;; ABI-aware split: SysV caller-saved-count=9; Win64=7 (%rsi/%rdi are
      ;; nonvolatile on Win64 -> in the callee-saved suffix, not the prefix).
      (=
        (reg.compiler-reg-greedy-caller-saved-count-for-abi
          cabi.CompilerRegTargetAbi.Linux)
        9)
      (=
        (reg.compiler-reg-greedy-caller-saved-count-for-abi
          cabi.CompilerRegTargetAbi.Windows)
        7)
      (=
        (reg.compiler-reg-id-seq-count
          (reg.compiler-reg-greedy-integer-pool-for-abi
            cabi.CompilerRegTargetAbi.Windows))
        14)
      (reg.compiler-reg-id-seq-contains?
        (reg.compiler-reg-greedy-integer-pool-for-abi
          cabi.CompilerRegTargetAbi.Windows)
        cabi.compiler-reg-id-rsi)
      (reg.compiler-reg-id-seq-contains?
        (reg.compiler-reg-greedy-integer-pool-for-abi
          cabi.CompilerRegTargetAbi.Windows)
        cabi.compiler-reg-id-rdi)
      ;; The scalar zero-call extension is the older three-register subset.
      ;; Keep ABI/result registers and Win64 callee-saved %rsi/%rdi out of it.
      (= (reg.compiler-reg-id-seq-count zero-call-callers) 3)
      (reg.compiler-reg-id-seq-contains?
        zero-call-callers
        cabi.compiler-reg-id-r9)
      (reg.compiler-reg-id-seq-contains?
        zero-call-callers
        cabi.compiler-reg-id-rcx)
      (reg.compiler-reg-id-seq-contains?
        zero-call-callers
        cabi.compiler-reg-id-rdx)
      (not
        (reg.compiler-reg-backend-caller-clobber-instr-for-abi?
          cabi.CompilerRegTargetAbi.Linux
          copy-instr))
      (reg.compiler-reg-backend-caller-clobber-instr-for-abi?
        cabi.CompilerRegTargetAbi.Windows
        copy-instr)
      (not
        (reg.compiler-reg-backend-caller-clobber-instr-for-abi?
          cabi.CompilerRegTargetAbi.Linux
          add-instr))
      (reg.compiler-reg-backend-caller-clobber-instr-for-abi?
        cabi.CompilerRegTargetAbi.Windows
        add-instr)
      (reg.compiler-reg-id-seq-contains? sysv-callers cabi.compiler-reg-id-rcx)
      (reg.compiler-reg-id-seq-contains? sysv-callers cabi.compiler-reg-id-rdx)
      (reg.compiler-reg-id-seq-contains? sysv-callers cabi.compiler-reg-id-r9)
      (reg.compiler-reg-id-seq-contains? win-callers cabi.compiler-reg-id-rcx)
      (reg.compiler-reg-id-seq-contains? win-callers cabi.compiler-reg-id-rdx)
      (reg.compiler-reg-id-seq-contains? win-callers cabi.compiler-reg-id-r9)
      (not
        (reg.compiler-reg-id-seq-contains?
          zero-call-callers
          cabi.compiler-reg-id-rax))
      ;; Win64 FPO appends %rbp to the nonvolatile suffix without moving the
      ;; seven-register volatile boundary or any existing pool member.
      (let
        [_rbp-on : unit (reg.compiler-reg-set-rbp-pool-enabled! true)]
        [fpo-pool : reg.CompilerRegIdSeq
          (reg.compiler-reg-greedy-integer-pool-for-abi
            cabi.CompilerRegTargetAbi.Windows)]
        [ok : bool
          (and
            (= (reg.compiler-reg-id-seq-count fpo-pool) 15)
            (reg.compiler-reg-id-seq-contains?
              fpo-pool
              cabi.compiler-reg-id-rbp)
            (=
              (reg.compiler-reg-greedy-caller-saved-count-for-abi
                cabi.CompilerRegTargetAbi.Windows)
              7))]
        [_rbp-restore : unit (reg.compiler-reg-set-rbp-pool-enabled! false)]
        ok)
      (not
        (reg.compiler-reg-id-seq-contains?
          zero-call-callers
          cabi.compiler-reg-id-r8))
      (not
        (reg.compiler-reg-id-seq-contains?
          zero-call-callers
          cabi.compiler-reg-id-r10))
      (not
        (reg.compiler-reg-id-seq-contains?
          zero-call-callers
          cabi.compiler-reg-id-r11))
      (not
        (reg.compiler-reg-id-seq-contains?
          zero-call-callers
          cabi.compiler-reg-id-rdi))
      (not
        (reg.compiler-reg-id-seq-contains?
          zero-call-callers
          cabi.compiler-reg-id-rsi))
      (not
        (reg.compiler-reg-id-seq-contains?
          (reg.compiler-reg-sysv-integer-registers)
          cabi.compiler-reg-id-r8))
      (not
        (reg.compiler-reg-id-seq-contains?
          (reg.compiler-reg-sysv-integer-registers)
          cabi.compiler-reg-id-r9)))))

(define (compiler-reg-xmm-clobbers-ok?) : bool
  (let
    [sysv-pool : reg.CompilerRegIdSeq
      (reg.compiler-reg-xmm-registers-for-abi cabi.CompilerRegTargetAbi.Linux)]
    [win-pool : reg.CompilerRegIdSeq
      (reg.compiler-reg-xmm-registers-for-abi cabi.CompilerRegTargetAbi.Windows)]
    [win-vector-pool : reg.CompilerRegIdSeq
      (reg.compiler-reg-vector-registers-for-abi
        cabi.CompilerRegTargetAbi.Windows)]
    [sysv-callers : reg.CompilerRegIdSeq
      (reg.compiler-reg-sysv-caller-saved-xmm-registers)]
    [sysv-callees : reg.CompilerRegIdSeq
      (reg.compiler-reg-sysv-callee-saved-xmm-registers)]
    [win-callers : reg.CompilerRegIdSeq
      (reg.compiler-reg-win64-caller-saved-xmm-registers)]
    [win-callees : reg.CompilerRegIdSeq
      (reg.compiler-reg-win64-callee-saved-xmm-registers)]
    [pool-ok : bool
      (and
        ;; Families 14 and 15 are fixed YMM/ZMM spill scratch. They must stay
        ;; outside both scalar-XMM and vector allocation pools so an implicit
        ;; spill temporary cannot overwrite an unrelated resident value.
        (= (reg.compiler-reg-id-seq-count sysv-pool) (cfg scratch-vreg 14 12))
        (= (reg.compiler-reg-id-seq-count win-pool) (cfg scratch-vreg 14 12))
        (= (reg.compiler-reg-id-seq-count win-vector-pool) 12)
        (=
          (reg.compiler-reg-xmm-caller-register-count-for-abi
            cabi.CompilerRegTargetAbi.Linux)
          (cfg scratch-vreg 14 12))
        (=
          (reg.compiler-reg-xmm-caller-register-count-for-abi
            cabi.CompilerRegTargetAbi.Windows)
          (cfg scratch-vreg 6 4))
        (=
          (reg.compiler-reg-id-seq-contains?
            sysv-pool
            (cabi.compiler-abi-xmm-register-id 0))
          (reg.compiler-reg-low-xmm-allocatable?))
        (=
          (reg.compiler-reg-id-seq-contains?
            sysv-pool
            (cabi.compiler-abi-xmm-register-id 1))
          (reg.compiler-reg-low-xmm-allocatable?))
        (reg.compiler-reg-id-seq-contains?
          sysv-pool
          (cabi.compiler-abi-xmm-register-id 2))
        (not
          (reg.compiler-reg-id-seq-contains?
            sysv-pool
            (cabi.compiler-abi-xmm-register-id 14)))
        (not
          (reg.compiler-reg-id-seq-contains?
            sysv-pool
            (cabi.compiler-abi-xmm-register-id 15)))
        (reg.compiler-reg-id-seq-contains?
          win-pool
          (cabi.compiler-abi-xmm-register-id 2))
        (reg.compiler-reg-id-seq-contains?
          win-pool
          (cabi.compiler-abi-xmm-register-id 6))
        (not
          (reg.compiler-reg-id-seq-contains?
            win-pool
            (cabi.compiler-abi-xmm-register-id 14)))
        (not
          (reg.compiler-reg-id-seq-contains?
            win-pool
            (cabi.compiler-abi-xmm-register-id 15)))
        (reg.compiler-reg-id-seq-contains?
          win-vector-pool
          (cabi.compiler-abi-vector-register-id 2))
        (not
          (reg.compiler-reg-id-seq-contains?
            win-vector-pool
            (cabi.compiler-abi-vector-register-id 14)))
        (not
          (reg.compiler-reg-id-seq-contains?
            win-vector-pool
            (cabi.compiler-abi-vector-register-id 15)))
        (not
          (reg.compiler-reg-id-seq-contains?
            win-vector-pool
            (cabi.compiler-abi-vector-register-id 0)))
        (not
          (reg.compiler-reg-id-seq-contains?
            win-vector-pool
            (cabi.compiler-abi-vector-register-id 1))))]
    [sysv-ok : bool
      (and
        (reg.compiler-reg-id-seq-contains?
          sysv-callers
          (cabi.compiler-abi-xmm-register-id 14))
        (not
          (reg.compiler-reg-id-seq-contains?
            sysv-callees
            (cabi.compiler-abi-xmm-register-id 14))))]
    [win-ok : bool
      (and
        (reg.compiler-reg-id-seq-contains?
          win-callers
          (cabi.compiler-abi-xmm-register-id 5))
        (not
          (reg.compiler-reg-id-seq-contains?
            win-callers
            (cabi.compiler-abi-xmm-register-id 6)))
        (reg.compiler-reg-id-seq-contains?
          win-callees
          (cabi.compiler-abi-xmm-register-id 6)))]
    [counts-ok : bool
      (and
        (= (reg.compiler-reg-id-seq-count sysv-callers) 16)
        (= (reg.compiler-reg-id-seq-count sysv-callees) 0)
        (= (reg.compiler-reg-id-seq-count win-callers) 6)
        (= (reg.compiler-reg-id-seq-count win-callees) 10))]
    (and pool-ok sysv-ok win-ok counts-ok)))

(define (compiler-reg-test-xmm-greedy-assignments
  [target-abi : cabi.CompilerRegTargetAbi]
  [vector : bool]
  [spans-call : bool]) : reg.CompilerRegAssignmentTable
  (let
    [intervals : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 10)
        (reg.compiler-reg-interval-seq-empty))]
    [call-points : live.CompilerLiveI64Set
      (if spans-call
        (live.compiler-live-set-insert (live.compiler-live-set-empty) 5)
        (live.compiler-live-set-empty))]
    [state : reg.CompilerRegAssignState
      (reg.compiler-reg-greedy-state
        intervals
        (if vector
          (reg.compiler-reg-vector-registers-for-abi target-abi)
          (reg.compiler-reg-xmm-registers-for-abi target-abi))
        (reg.compiler-reg-assignment-table-make 1)
        (reg.compiler-reg-interval-index-build intervals 1)
        (live.compiler-live-set-empty)
        (live.compiler-live-set-empty)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        call-points
        (live.compiler-live-set-empty)
        (live.compiler-live-set-empty)
        (if vector
          (reg.compiler-reg-vector-callee-registers-for-abi target-abi)
          (reg.compiler-reg-xmm-callee-registers-for-abi target-abi))
        (if vector
          (reg.compiler-reg-vector-caller-register-count-for-abi target-abi)
          (reg.compiler-reg-xmm-caller-register-count-for-abi target-abi))
        -1)]
    (match state
      [(reg.CompilerRegAssignState.State _ assignments) assignments])))

(define (compiler-reg-xmm-abi-call-constraints-ok?) : bool
  (let
    [sysv-float : reg.CompilerRegAssignmentTable
      (compiler-reg-test-xmm-greedy-assignments
        cabi.CompilerRegTargetAbi.Linux
        false
        true)]
    [win-float : reg.CompilerRegAssignmentTable
      (compiler-reg-test-xmm-greedy-assignments
        cabi.CompilerRegTargetAbi.Windows
        false
        true)]
    [sysv-vector : reg.CompilerRegAssignmentTable
      (compiler-reg-test-xmm-greedy-assignments
        cabi.CompilerRegTargetAbi.Linux
        true
        true)]
    [win-vector : reg.CompilerRegAssignmentTable
      (compiler-reg-test-xmm-greedy-assignments
        cabi.CompilerRegTargetAbi.Windows
        true
        true)]
    [sysv-leaf : reg.CompilerRegAssignmentTable
      (compiler-reg-test-xmm-greedy-assignments
        cabi.CompilerRegTargetAbi.Linux
        false
        false)]
    (and
      (not
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup sysv-float 0)))
      (not
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup sysv-vector 0)))
      (reg.compiler-reg-location-register?
        (reg.compiler-reg-assignment-lookup win-float 0)
        (cabi.compiler-abi-xmm-register-id 6))
      ;; Win64 preserves only each register's low XMM half, never the full YMM
      ;; value, so a vector that spans even a private call must be spilled.
      (not
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup win-vector 0)))
      (reg.compiler-reg-location-register?
        (reg.compiler-reg-assignment-lookup sysv-leaf 0)
        (cfg
          scratch-vreg
          (cabi.compiler-abi-xmm-register-id 0)
          (cabi.compiler-abi-xmm-register-id 2))))))

(define (compiler-reg-xmm-shared-greedy-bank-ok?) : bool
  (let
    [scalar-candidates : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 10)
        (reg.compiler-reg-interval-seq-empty))]
    [vector-candidates : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 0 10)
        (reg.compiler-reg-interval-seq-empty))]
    [all-intervals : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 10)
        vector-candidates)]
    [interval-index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build all-intervals 2)]
    [scalar-state : reg.CompilerRegAssignState
      (reg.compiler-reg-greedy-state
        scalar-candidates
        (reg.compiler-reg-id-seq-prepend
          (cabi.compiler-abi-xmm-register-id 6)
          (reg.compiler-reg-id-seq-empty))
        (reg.compiler-reg-assignment-table-make 2)
        interval-index
        (live.compiler-live-set-empty)
        (live.compiler-live-set-empty)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (live.compiler-live-set-empty)
        (live.compiler-live-set-empty)
        (live.compiler-live-set-empty)
        (reg.compiler-reg-id-seq-empty)
        1
        -1)]
    (match scalar-state
      [(reg.CompilerRegAssignState.State _ scalar-assignments)
        (match (reg.compiler-reg-greedy-state
          vector-candidates
          (reg.compiler-reg-vector-registers-for-abi
            cabi.CompilerRegTargetAbi.Linux)
          scalar-assignments
          interval-index
          (live.compiler-live-set-empty)
          (live.compiler-live-set-empty)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (live.compiler-live-set-empty)
          (live.compiler-live-set-empty)
          (live.compiler-live-set-empty)
          (reg.compiler-reg-id-seq-empty)
          14
          -1)
          [(reg.CompilerRegAssignState.State _ assignments)
            (let
              [items : reg.CompilerRegAssignmentTable assignments]
              (and
                (reg.compiler-reg-location-register?
                  (reg.compiler-reg-assignment-lookup items 0)
                  (cabi.compiler-abi-xmm-register-id 6))
                (reg.compiler-reg-location-register?
                  (reg.compiler-reg-assignment-lookup items 1)
                  (cabi.compiler-abi-vector-register-id 7))))])])))

(define (compiler-reg-xmm-vector-class-reset-ok?) : bool
  (let
    [candidates : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 10)
        (reg.compiler-reg-interval-seq-empty))]
    [index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build candidates 1)]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 1)
        0
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
    [_reset : unit
      (reg.compiler-reg-unassign-special-candidates! assignments candidates)]
    (match (reg.compiler-reg-greedy-state
      candidates
      (reg.compiler-reg-vector-registers-for-abi
        cabi.CompilerRegTargetAbi.Linux)
      assignments
      index
      (live.compiler-live-set-empty)
      (live.compiler-live-set-empty)
      (__tl_make-array i64 0)
      (__tl_make-array i64 0)
      (__tl_make-array i64 0)
      (live.compiler-live-set-empty)
      (live.compiler-live-set-empty)
      (live.compiler-live-set-empty)
      (reg.compiler-reg-id-seq-empty)
      14
      -1)
      [(reg.CompilerRegAssignState.State _ out)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-table-lookup out 0)
          (cabi.compiler-abi-vector-register-id 6))])))

(define (compiler-reg-color-register-assignments-to [last : i64]) : reg.CompilerRegAssignmentTable
  (if (< last 0)
    (reg.compiler-reg-assignment-table-empty)
    (reg.compiler-reg-assignment-insert
      (compiler-reg-color-register-assignments-to (- last 1))
      last
      (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))))

(define (compiler-reg-color-storage-function) : ir.CompilerIrFunction
  (let
    [big : ast.AstType (ast.AstType.Struct (ci.intern "BigStorage"))]
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "storage_ranges")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      6
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Alloc 0 big)
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Alloc 1 big)
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.AddrOf 2 1)
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.StorePtr
                    (ir.CompilerIrValue.Var 2)
                    (ir.CompilerIrValue.I64 11)
                    (ast.AstType.I64))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.CompilerIrInstr.Alloc 3 big)
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Alloc 4 big)
                      (compiler-reg-test-instr-seq-prepend
                        (ir.CompilerIrInstr.AddrOf 5 4)
                        (compiler-reg-test-instr-seq-prepend
                          (ir.CompilerIrInstr.StorePtr
                            (ir.CompilerIrValue.Var 5)
                            (ir.CompilerIrValue.I64 22)
                            (ast.AstType.I64))
                          (compiler-reg-test-instr-seq-prepend
                            (ir.CompilerIrInstr.Return
                              ir.CompilerIrMaybeValue.No)
                            (ir.compiler-ir-instr-seq-empty)))))))))))
        ir.CompilerIrBlockList.Nil))))

(define (compiler-reg-color-pointer-assignments) : reg.CompilerRegAssignmentTable
  (reg.compiler-reg-assignment-insert
    (reg.compiler-reg-assignment-insert
      (reg.compiler-reg-assignment-table-empty)
      2
      (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))
    5
    (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r13)))

(define (compiler-reg-color-pointer-intervals) : reg.CompilerRegIntervalSeq
  (reg.compiler-reg-interval-seq-prepend
    (reg.CompilerRegInterval 2 1 3)
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 5 5 7)
      (reg.compiler-reg-interval-seq-empty))))

(define (compiler-reg-color-pointer-types) : reg.CompilerRegVarTypes
  (reg.compiler-reg-var-types-insert
    (reg.compiler-reg-var-types-insert
      (reg.compiler-reg-var-types-empty)
      5
      (ast.AstType.U64))
    2
    (ast.AstType.U64)))

(define (compiler-reg-color-spill-sharing-assignments [vars : i64]) : reg.CompilerRegAssignmentTable
  (if (< vars 1)
    (reg.compiler-reg-assignment-table-empty)
    (reg.compiler-reg-assignment-insert
      (compiler-reg-color-spill-sharing-assignments (- vars 1))
      (- vars 1)
      (reg.CompilerRegLocation.Spill (* (- vars 1) 8)))))

(define (compiler-reg-color-spill-sharing-types [vars : i64]) : reg.CompilerRegVarTypes
  (if (< vars 1)
    (reg.compiler-reg-var-types-empty)
    (reg.compiler-reg-var-types-insert
      (compiler-reg-color-spill-sharing-types (- vars 1))
      (- vars 1)
      (ast.AstType.I64))))

(define (compiler-reg-color-spill-sharing-intervals) : reg.CompilerRegIntervalSeq
  (reg.compiler-reg-interval-seq-prepend
    (reg.CompilerRegInterval 0 0 2)
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 2 1 5)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 3 4)
        (reg.compiler-reg-interval-seq-empty)))))

(define (compiler-reg-color-spill-split-intervals) : reg.CompilerRegIntervalSeq
  (reg.compiler-reg-interval-seq-prepend
    (reg.CompilerRegInterval 0 0 1)
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 1 2 3)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 5 7)
        (reg.compiler-reg-interval-seq-empty)))))

(define (compiler-reg-color-spill-param-intervals) : reg.CompilerRegIntervalSeq
  (reg.compiler-reg-interval-seq-prepend
    (reg.CompilerRegInterval 0 0 1)
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 1 1 2)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 2 3 4)
        (reg.compiler-reg-interval-seq-empty)))))

(define (compiler-reg-color-spill-slot-sharing-ok?) : bool
  (match (reg.compiler-reg-color-stack-slots
    (ast.ast-node-pool-reader-type-segment-bases)
    (reg.CompilerRegPlan.Plan
      (compiler-reg-color-spill-sharing-assignments 3)
      (live.compiler-live-set-empty)
      (compiler-reg-color-spill-sharing-intervals)
      (compiler-reg-color-spill-sharing-types 3)
      (reg.compiler-reg-call-split-empty)
      (reg.compiler-reg-split-plan-empty))
    (live.compiler-live-set-empty)
    ir.CompilerIrParamList.Nil
    ir.CompilerIrBlockList.Nil
    3
    3
    (live.compiler-live-set-empty))
    [(reg.CompilerRegColoring.Remap share-remap share-slots)
      (match (reg.compiler-reg-color-stack-slots
        (ast.ast-node-pool-reader-type-segment-bases)
        (reg.CompilerRegPlan.Plan
          (compiler-reg-color-spill-sharing-assignments 2)
          (live.compiler-live-set-empty)
          (compiler-reg-color-spill-split-intervals)
          (compiler-reg-color-spill-sharing-types 2)
          (reg.compiler-reg-call-split-empty)
          (reg.compiler-reg-split-plan-empty))
        (live.compiler-live-set-empty)
        ir.CompilerIrParamList.Nil
        ir.CompilerIrBlockList.Nil
        2
        2
        (live.compiler-live-set-empty))
        [(reg.CompilerRegColoring.Remap split-remap split-slots)
          (and
            (= share-slots 2)
            (= (array-ref share-remap 0) (array-ref share-remap 1))
            (not (= (array-ref share-remap 0) (array-ref share-remap 2)))
            (= split-slots 2)
            (not (= (array-ref split-remap 0) (array-ref split-remap 1))))]
        [(reg.CompilerRegColoring.None) false])]
    [(reg.CompilerRegColoring.None) false]))

;; Four spilled variables whose intervals form a strictly disjoint chain: the
;; ordinary walk folds every one of them onto a single shared slot.
(define (compiler-reg-color-fusion-pin-intervals) : reg.CompilerRegIntervalSeq
  (reg.compiler-reg-interval-seq-prepend
    (reg.CompilerRegInterval 0 0 1)
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 1 2 3)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 2 4 5)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 3 6 7)
          (reg.compiler-reg-interval-seq-empty))))))

(define (compiler-reg-color-fusion-pin-coloring
  [fusion-pinned : live.CompilerLiveI64Set]) : reg.CompilerRegColoring
  (reg.compiler-reg-color-stack-slots
    (ast.ast-node-pool-reader-type-segment-bases)
    (reg.CompilerRegPlan.Plan
      (compiler-reg-color-spill-sharing-assignments 4)
      (live.compiler-live-set-empty)
      (compiler-reg-color-fusion-pin-intervals)
      (compiler-reg-color-spill-sharing-types 4)
      (reg.compiler-reg-call-split-empty)
      (reg.compiler-reg-split-plan-empty))
    (live.compiler-live-set-empty)
    ir.CompilerIrParamList.Nil
    ir.CompilerIrBlockList.Nil
    4
    4
    fusion-pinned))

;; Vars 0 and 1 stand in for the fusable single-use address temps the backend
;; reports, vars 2 and 3 for ordinary spilled values. The pinned pair must come
;; out of the coloring with distinct private ids -- a shared id would carry the
;; other members' uses and switch off the fusion peephole -- while the ordinary
;; pair keeps sharing exactly as it did before.
(define (compiler-reg-color-fusion-pin-slots-ok?) : bool
  (match (compiler-reg-color-fusion-pin-coloring (live.compiler-live-set-empty))
    [(reg.CompilerRegColoring.Remap merged-remap merged-slots)
      (match (compiler-reg-color-fusion-pin-coloring
        (live.compiler-live-set2 0 1))
        [(reg.CompilerRegColoring.Remap pin-remap pin-slots)
          (and
            (= merged-slots 1)
            (= (array-ref merged-remap 0) (array-ref merged-remap 1))
            (= (array-ref merged-remap 0) (array-ref merged-remap 2))
            (= (array-ref merged-remap 0) (array-ref merged-remap 3))
            (= pin-slots 3)
            (not (= (array-ref pin-remap 0) (array-ref pin-remap 1)))
            (not (= (array-ref pin-remap 0) (array-ref pin-remap 2)))
            (not (= (array-ref pin-remap 0) (array-ref pin-remap 3)))
            (not (= (array-ref pin-remap 1) (array-ref pin-remap 2)))
            (not (= (array-ref pin-remap 1) (array-ref pin-remap 3)))
            (= (array-ref pin-remap 2) (array-ref pin-remap 3))
            (< (array-ref pin-remap 0) pin-slots)
            (< (array-ref pin-remap 1) pin-slots))]
        [(reg.CompilerRegColoring.None) false])]
    [(reg.CompilerRegColoring.None) false]))

(define (compiler-reg-color-spill-param-pins-ok?) : bool
  (match (reg.compiler-reg-color-stack-slots
    (ast.ast-node-pool-reader-type-segment-bases)
    (reg.CompilerRegPlan.Plan
      (compiler-reg-color-spill-sharing-assignments 3)
      (live.compiler-live-set-empty)
      (compiler-reg-color-spill-param-intervals)
      (compiler-reg-color-spill-sharing-types 3)
      (reg.compiler-reg-call-split-empty)
      (reg.compiler-reg-split-plan-empty))
    (live.compiler-live-set-empty)
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "pinned" (ast.AstType.I64) 1)
      ir.CompilerIrParamList.Nil)
    ir.CompilerIrBlockList.Nil
    3
    3
    (live.compiler-live-set-empty))
    [(reg.CompilerRegColoring.Remap remap slots)
      (and
        (= slots 2)
        (= (array-ref remap 1) 1)
        (= (array-ref remap 0) (array-ref remap 2))
        (not (= (array-ref remap 0) 1)))]
    [(reg.CompilerRegColoring.None) false]))

(define (compiler-reg-color-avx2-param-ranges-ok?) : bool
  (let
    [params : ir.CompilerIrParamList
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param
          "__tl_spmd_active_mask_avx2"
          (ast.AstType.Bool)
          0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param
            "__tl_spmd_varying_arg_avx2_x"
            (ast.AstType.I64)
            1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param
              "__tl_spmd_index_base"
              (ast.AstType.I64)
              2)
            ir.CompilerIrParamList.Nil)))]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-insert
        (reg.compiler-reg-assignment-table-empty)
        1
        (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
    (match (reg.compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (reg.CompilerRegPlan.Plan
        assignments
        (live.compiler-live-set-empty)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 0 1)
          (reg.compiler-reg-interval-seq-empty))
        (reg.compiler-reg-var-types-insert
          (reg.compiler-reg-var-types-empty)
          1
          (ast.AstType.I64))
        (reg.compiler-reg-call-split-empty)
        (reg.compiler-reg-split-plan-empty))
      (live.compiler-live-set-empty)
      params
      ir.CompilerIrBlockList.Nil
      3
      3
      (live.compiler-live-set-empty))
      [(reg.CompilerRegColoring.Remap remap slots)
        (let
          [active : i64 (array-ref remap 0)]
          [varying : i64 (array-ref remap 1)]
          [uniform : i64 (array-ref remap 2)]
          [rebuilt : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-color-rebuild-assignments remap 3 assignments)]
          [rebuilt-index : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-assignment-table-with-min-capacity rebuilt 3)]
          (begin
            (compiler-regalloc-self-test-require!
              "AVX2 special parameter range reservation"
              (and
                (= uniform 2)
                (>= active 3)
                (<= (+ active 1) slots)
                (or (< uniform (- active 3)) (> uniform active))
                (not (= varying active))))
            (compiler-regalloc-self-test-require!
              "AVX2 special parameter assignment remap"
              (reg.compiler-reg-location-register?
                (reg.compiler-reg-assignment-table-lookup rebuilt-index varying)
                cabi.compiler-reg-id-r12))
            (compiler-regalloc-self-test-require!
              "AVX2 emitted parameter id remap"
              (match (ir.compiler-ir-param-list-force-cons
                (reg.compiler-reg-remap-params remap params))
                [(ir.CompilerIrParamList.Cons
                    (ir.CompilerIrParam.Param _ _ active-param)
                    rest1)
                  (match (ir.compiler-ir-param-list-force-cons
                    (__tl-box-place rest1))
                    [(ir.CompilerIrParamList.Cons
                        (ir.CompilerIrParam.Param _ _ varying-param)
                        rest2)
                      (match (ir.compiler-ir-param-list-force-cons
                        (__tl-box-place rest2))
                        [(ir.CompilerIrParamList.Cons
                            (ir.CompilerIrParam.Param _ _ uniform-param)
                            _)
                          (and
                            (= active-param active)
                            (= varying-param varying)
                            (= uniform-param uniform))]
                        [_ false])]
                    [_ false])]
                [_ false]))
            true))]
      [(reg.CompilerRegColoring.None) false])))

(define (compiler-reg-color-spill-hole-demand-ok?) : bool
  (match (reg.compiler-reg-color-stack-slots
    (ast.ast-node-pool-reader-type-segment-bases)
    (reg.CompilerRegPlan.Plan
      (compiler-reg-color-spill-sharing-assignments 1)
      (live.compiler-live-set-empty)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 1)
        (reg.compiler-reg-interval-seq-empty))
      (compiler-reg-color-spill-sharing-types 1)
      (reg.compiler-reg-call-split-empty)
      (reg.compiler-reg-split-plan-empty))
    (live.compiler-live-set-empty)
    ir.CompilerIrParamList.Nil
    ir.CompilerIrBlockList.Nil
    10
    10
    (live.compiler-live-set-empty))
    [(reg.CompilerRegColoring.Remap remap slots)
      (and
        (= slots 1)
        (= (array-ref remap 0) 0)
        (not (= (array-ref remap 9) 0)))]
    [(reg.CompilerRegColoring.None) false]))

(define (compiler-reg-color-spill-scratch-demand-ok?) : bool
  (let
    [params : ir.CompilerIrParamList
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "real" (ast.AstType.I64) 0)
        ir.CompilerIrParamList.Nil)]
    (match (reg.compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (reg.CompilerRegPlan.Plan
        (compiler-reg-color-spill-sharing-assignments 2)
        (live.compiler-live-set-empty)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 0 0 1)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 1 0 1)
            (reg.compiler-reg-interval-seq-empty)))
        (compiler-reg-color-spill-sharing-types 2)
        (reg.compiler-reg-call-split-empty)
        (reg.compiler-reg-split-plan-empty))
      (live.compiler-live-set-empty)
      params
      ir.CompilerIrBlockList.Nil
      2
      1
      (live.compiler-live-set-empty))
      [(reg.CompilerRegColoring.Remap remap slots)
        (and (= slots 1) (= (array-ref remap 0) 0) (= (array-ref remap 1) 1))]
      [(reg.CompilerRegColoring.None) false])))

(define (compiler-reg-color-vector-stack-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "vector_stack_slots")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.VectorLoad
            0
            (ir.CompilerIrValue.I64 0)
            (ir.CompilerIrValue.I64 0)
            4
            (ast.AstType.I64))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.VectorLoad
              1
              (ir.CompilerIrValue.I64 0)
              (ir.CompilerIrValue.I64 0)
              8
              (ast.AstType.I64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.TailMask
                2
                (ir.CompilerIrValue.I64 0)
                (ir.CompilerIrValue.I64 1)
                8)
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                (ir.compiler-ir-instr-seq-empty))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-color-vector-stack-slots-ok?) : bool
  (match (compiler-reg-color-vector-stack-function)
    [(ir.CompilerIrFunction.Function _ params _ vars blocks)
      (match (reg.compiler-reg-color-stack-slots
        (ast.ast-node-pool-reader-type-segment-bases)
        (reg.CompilerRegPlan.Plan
          (reg.compiler-reg-assignment-table-empty)
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 0 0 2)
            (reg.compiler-reg-interval-seq-prepend
              (reg.CompilerRegInterval 1 1 3)
              (reg.compiler-reg-interval-seq-prepend
                (reg.CompilerRegInterval 2 2 4)
                (reg.compiler-reg-interval-seq-empty))))
          (reg.compiler-reg-var-types-empty)
          (reg.compiler-reg-call-split-empty)
          (reg.compiler-reg-split-plan-empty))
        (live.compiler-live-set-empty)
        params
        blocks
        vars
        vars
        (live.compiler-live-set-empty))
        [(reg.CompilerRegColoring.Remap remap slots)
          (and
            (= (array-ref remap 0) 3)
            (= (array-ref remap 1) 11)
            (= (array-ref remap 2) 15)
            (= slots 16))]
        [(reg.CompilerRegColoring.None) false])]))

(define (compiler-reg-vector-stack-mask-words-ok?) : bool
  (let
    [words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    (begin
      (reg.compiler-reg-vector-stack-words-instr!
        (ir.ir-instr-vector-compare
          0
          (ir.CompilerIrBinOp.Eq)
          (ir.CompilerIrValue.I64 0)
          (ir.CompilerIrValue.I64 0)
          8
          (ast.AstType.I32))
        words)
      (reg.compiler-reg-vector-stack-words-instr!
        (ir.CompilerIrInstr.MaskBinOp
          1
          (ir.CompilerIrMaskBinOp.And)
          (ir.CompilerIrValue.Var 0)
          (ir.CompilerIrValue.Var 0)
          8)
        words)
      (reg.compiler-reg-vector-stack-words-instr!
        (ir.CompilerIrInstr.MaskNot 2 (ir.CompilerIrValue.Var 1) 8)
        words)
      (reg.compiler-reg-vector-stack-words-instr!
        (ir.CompilerIrInstr.TailMask
          3
          (ir.CompilerIrValue.I64 0)
          (ir.CompilerIrValue.I64 1)
          8)
        words)
      (reg.compiler-reg-vector-stack-words-instr!
        (ir.ir-instr-predicated-load
          4
          (ir.CompilerIrValue.I64 0)
          (ir.CompilerIrValue.I64 0)
          (ir.CompilerIrValue.Var 3)
          8
          (ast.AstType.Bool))
        words)
      (reg.compiler-reg-vector-stack-words-instr!
        (ir.ir-instr-select
          5
          (ir.CompilerIrValue.Var 3)
          (ir.CompilerIrValue.Var 4)
          (ir.CompilerIrValue.Var 4)
          8
          (ast.AstType.Bool))
        words)
      (and
        (= (array-ref words 0) 4)
        (= (array-ref words 1) 4)
        (= (array-ref words 2) 4)
        (= (array-ref words 3) 4)
        (= (array-ref words 4) 4)
        (= (array-ref words 5) 4)))))

(define (compiler-reg-simd-copy-class-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "simd_copy_class")
    ir.CompilerIrParamList.Nil
    (ast.AstType.Unit)
    6
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Mov
            2
            (ir.CompilerIrValue.Var 1)
            (ast.AstType.I64))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.Var 0)
              (ast.AstType.I64))
            (compiler-reg-test-instr-seq-prepend
              (ir.CompilerIrInstr.Splat
                0
                (ir.CompilerIrValue.I64 7)
                8
                (ast.AstType.I64))
              (compiler-reg-test-instr-seq-prepend
                (ir.CompilerIrInstr.Mov
                  5
                  (ir.CompilerIrValue.Var 4)
                  (ast.AstType.Bool))
                (compiler-reg-test-instr-seq-prepend
                  (ir.CompilerIrInstr.Mov
                    4
                    (ir.CompilerIrValue.Var 3)
                    (ast.AstType.Bool))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.ir-instr-vector-compare
                      3
                      (ir.CompilerIrBinOp.Eq)
                      (ir.CompilerIrValue.Var 0)
                      (ir.CompilerIrValue.Var 0)
                      8
                      (ast.AstType.I64))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                      (ir.compiler-ir-instr-seq-empty)))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-simd-copy-classes-and-widths-ok?) : bool
  (let
    [func : ir.CompilerIrFunction (compiler-reg-simd-copy-class-function)]
    [classes : live.CompilerLiveUseDef
      (reg.compiler-reg-function-vector-mask-defs func)]
    [words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    (match func
      [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
        (begin
          (reg.compiler-reg-vector-stack-words-blocks! blocks words)
          (reg.compiler-reg-vector-stack-words-fixpoint! blocks words)
          (and
            (live.compiler-live-set-contains? classes.uses 0)
            (live.compiler-live-set-contains? classes.uses 1)
            (live.compiler-live-set-contains? classes.uses 2)
            (not (live.compiler-live-set-contains? classes.uses 3))
            (live.compiler-live-set-contains? classes.defs 3)
            (live.compiler-live-set-contains? classes.defs 4)
            (live.compiler-live-set-contains? classes.defs 5)
            (not (live.compiler-live-set-contains? classes.defs 0))
            (= (array-ref words 0) 8)
            (= (array-ref words 1) 8)
            (= (array-ref words 2) 8)
            (= (array-ref words 3) 4)
            (= (array-ref words 4) 4)
            (= (array-ref words 5) 4)))])))

(test
  regalloc-simd-copy-class-fixpoint
  (test.assert-true
    (compiler-reg-simd-copy-classes-and-widths-ok?)
    "vector/mask register classes and full spill widths flow through out-of-order Mov chains"))

(define (compiler-reg-color-storage-ranges-ok?) : bool
  (match (compiler-reg-color-storage-function)
    [(ir.CompilerIrFunction.Function _ params _ vars blocks)
      (match (reg.compiler-reg-color-stack-slots
        (ast.ast-node-pool-reader-type-segment-bases)
        (reg.CompilerRegPlan.Plan
          (compiler-reg-color-pointer-assignments)
          (live.compiler-live-set-empty)
          (compiler-reg-color-pointer-intervals)
          (compiler-reg-color-pointer-types)
          (reg.compiler-reg-call-split-empty)
          (reg.compiler-reg-split-plan-empty))
        (live.compiler-live-set-empty)
        params
        blocks
        vars
        vars
        (live.compiler-live-set-empty))
        [(reg.CompilerRegColoring.Remap remap slots)
          (and
            (= slots 2)
            (= (array-ref remap 0) 0)
            (= (array-ref remap 1) 1)
            (= (array-ref remap 3) 0)
            (= (array-ref remap 4) 1))]
        [(reg.CompilerRegColoring.None) false])]))

(define (compiler-reg-color-stack-group-ok?) : bool
  (let
    [group-var : i64 7]
    [coloring : reg.CompilerRegColoring
      (reg.compiler-reg-color-stack-slots
        (ast.ast-node-pool-reader-type-segment-bases)
        (reg.CompilerRegPlan.Plan
          (compiler-reg-color-register-assignments-to (- group-var 1))
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval group-var 0 2)
            (reg.compiler-reg-interval-seq-empty))
          (reg.compiler-reg-var-types-insert
            (reg.compiler-reg-var-types-empty)
            group-var
            (ast.AstType.Struct (ci.intern "RegGroup")))
          (reg.compiler-reg-call-split-empty)
          (reg.compiler-reg-split-plan-empty))
        (live.compiler-live-set1 group-var)
        ir.CompilerIrParamList.Nil
        ir.CompilerIrBlockList.Nil
        (+ group-var 1)
        (+ group-var 1)
        (live.compiler-live-set-empty))]
    (match coloring
      [(reg.CompilerRegColoring.Remap remap slots)
        (and
          (= slots 1)
          (= (array-ref remap group-var) 0)
          (<= (+ (array-ref remap group-var) 1) slots))]
      [(reg.CompilerRegColoring.None) false])))

;; Image-scoped program-map suppression, the contract a STANDALONE plan runs
;; under. The allocator's group/class/C-call maps describe the image the backend
;; is emitting and are owned by that image's arena; a caller that plans outside
;; the backend -- the optimizer's measured inline tier -- must see them missing
;; instead of reading a previous `compile --batch` entry's freed storage. Two
;; halves are asserted: while armed every query answers missing, and the flag
;; does not survive the measurement, because the readers are shared with the
;; backend's own planning.
(define (compiler-reg-program-maps-suppression-ok?) : bool
  (let
    [name : i64 4242]
    [idle-before? : bool (reg.compiler-reg-program-maps-suppressed-current?)]
    [_seed : unit (reg.compiler-reg-add-c-memory-call-name! name)]
    [installed? : bool (reg.compiler-reg-c-memory-call-name? name)]
    [_arm : unit (reg.compiler-reg-suppress-program-maps! true)]
    [armed? : bool (reg.compiler-reg-program-maps-suppressed-current?)]
    [suppressed? : bool (reg.compiler-reg-c-memory-call-name? name)]
    [_clear : unit (reg.compiler-reg-suppress-program-maps! false)]
    [idle-after? : bool (reg.compiler-reg-program-maps-suppressed-current?)]
    [restored? : bool (reg.compiler-reg-c-memory-call-name? name)]
    [_reset : unit (reg.compiler-reg-clear-c-memory-call-names!)]
    (and
      (not idle-before?)
      installed?
      armed?
      (not suppressed?)
      (not idle-after?)
      restored?)))

;; --- CFG loop nest ----------------------------------------------------------
;;
;; The depth analysis used to read the block LAYOUT: a backward edge from index
;; p to index q <= p made every index in [q, p] one level deeper. These fixtures
;; are the shapes that encoding gets WRONG -- an in-range block that is not in
;; the loop, and a backward-in-layout edge that is not a loop edge at all -- and
;; the shapes both readings must agree on, so a future layout permutation is
;; measured against a nest that does not move with it.
(define (compiler-reg-loop-nest-jump [target : String]) : ir.CompilerIrInstrSeq
  (compiler-reg-test-instr-seq-prepend
    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label target))
    (ir.compiler-ir-instr-seq-empty)))

(define (compiler-reg-loop-nest-branch
  [true-label : String]
  [false-label : String]) : ir.CompilerIrInstrSeq
  (compiler-reg-test-instr-seq-prepend
    (ir.CompilerIrInstr.Branch
      (ir.CompilerIrValue.Bool false)
      (ir.compiler-ir-label true-label)
      (ir.compiler-ir-label false-label))
    (ir.compiler-ir-instr-seq-empty)))

(define (compiler-reg-loop-nest-return) : ir.CompilerIrInstrSeq
  (compiler-reg-test-instr-seq-prepend
    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
    (ir.compiler-ir-instr-seq-empty)))

;; A block that ends WITHOUT a terminator: control runs on into whatever block
;; is laid out next, an edge no instruction names.
(define (compiler-reg-loop-nest-open) : ir.CompilerIrInstrSeq
  (compiler-reg-test-instr-seq-prepend
    (ir.CompilerIrInstr.Mov 0 (ir.CompilerIrValue.I64 1) (compiler-reg-i64-ty))
    (ir.compiler-ir-instr-seq-empty)))

(define (compiler-reg-loop-nest-block
  [label : String]
  [instrs : ir.CompilerIrInstrSeq]
  [rest : ir.CompilerIrBlockList]) : ir.CompilerIrBlockList
  (ir.compiler-ir-block-cons
    (ir.CompilerIrBlock.Block (ir.compiler-ir-label label) instrs)
    rest))

(define (compiler-reg-loop-nest-depth-at
  [depths : (__tl_dyn-array i64)]
  [index : i64]) : i64
  (if (and (>= index 0) (< index (array-length depths)))
    (array-ref depths index)
    -1))

;; entry / header / body / early / latch / exit.
;;
;; `early` is the loop's break arm: it is laid out INSIDE [header, latch], so
;; the range encoding charges it loop frequency, but it reaches the exit and
;; never the latch, so it runs at most once per loop ENTRY. The CFG nest leaves
;; it at depth 0.
(define (compiler-reg-loop-nest-early-exit-blocks) : ir.CompilerIrBlockList
  (compiler-reg-loop-nest-block
    "entry"
    (compiler-reg-loop-nest-jump "header")
    (compiler-reg-loop-nest-block
      "header"
      (compiler-reg-loop-nest-branch "body" "exit")
      (compiler-reg-loop-nest-block
        "body"
        (compiler-reg-loop-nest-branch "early" "latch")
        (compiler-reg-loop-nest-block
          "early"
          (compiler-reg-loop-nest-jump "exit")
          (compiler-reg-loop-nest-block
            "latch"
            (compiler-reg-loop-nest-jump "header")
            (compiler-reg-loop-nest-block
              "exit"
              (compiler-reg-loop-nest-return)
              ir.CompilerIrBlockList.Nil)))))))

(define (compiler-reg-loop-nest-early-exit-ok?) : bool
  (let
    [depths : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths
        (compiler-reg-loop-nest-early-exit-blocks))]
    (and
      (= (array-length depths) 6)
      (= (compiler-reg-loop-nest-depth-at depths 0) 0)
      (= (compiler-reg-loop-nest-depth-at depths 1) 1)
      (= (compiler-reg-loop-nest-depth-at depths 2) 1)
      (= (compiler-reg-loop-nest-depth-at depths 3) 0)
      (= (compiler-reg-loop-nest-depth-at depths 4) 1)
      (= (compiler-reg-loop-nest-depth-at depths 5) 0))))

;; entry / hot / join / cold. The motivating shape of the layout arc: `cold` is
;; sunk below every block it can reach, so its jump to `join` runs BACKWARD in
;; layout. The range encoding reads that as a loop covering [join, cold]; there
;; is no cycle in the CFG at all, and the nest says depth 0 everywhere.
(define (compiler-reg-loop-nest-sunk-cold-blocks) : ir.CompilerIrBlockList
  (compiler-reg-loop-nest-block
    "entry"
    (compiler-reg-loop-nest-branch "hot" "cold")
    (compiler-reg-loop-nest-block
      "hot"
      (compiler-reg-loop-nest-jump "join")
      (compiler-reg-loop-nest-block
        "join"
        (compiler-reg-loop-nest-return)
        (compiler-reg-loop-nest-block
          "cold"
          (compiler-reg-loop-nest-jump "join")
          ir.CompilerIrBlockList.Nil)))))

(define (compiler-reg-loop-nest-sunk-cold-ok?) : bool
  (let
    [depths : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths
        (compiler-reg-loop-nest-sunk-cold-blocks))]
    (and
      (= (array-length depths) 4)
      (= (compiler-reg-loop-nest-depth-at depths 0) 0)
      (= (compiler-reg-loop-nest-depth-at depths 1) 0)
      (= (compiler-reg-loop-nest-depth-at depths 2) 0)
      (= (compiler-reg-loop-nest-depth-at depths 3) 0))))

;; entry / header / body / cont / tail / exit. TWO back edges into one header --
;; a `continue` arm and the body tail. That is one loop with two latches, not
;; two nested loops: every body block stays at depth 1.
(define (compiler-reg-loop-nest-two-latch-blocks) : ir.CompilerIrBlockList
  (compiler-reg-loop-nest-block
    "entry"
    (compiler-reg-loop-nest-jump "header")
    (compiler-reg-loop-nest-block
      "header"
      (compiler-reg-loop-nest-branch "body" "exit")
      (compiler-reg-loop-nest-block
        "body"
        (compiler-reg-loop-nest-branch "cont" "tail")
        (compiler-reg-loop-nest-block
          "cont"
          (compiler-reg-loop-nest-jump "header")
          (compiler-reg-loop-nest-block
            "tail"
            (compiler-reg-loop-nest-jump "header")
            (compiler-reg-loop-nest-block
              "exit"
              (compiler-reg-loop-nest-return)
              ir.CompilerIrBlockList.Nil)))))))

(define (compiler-reg-loop-nest-two-latch-ok?) : bool
  (let
    [depths : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths
        (compiler-reg-loop-nest-two-latch-blocks))]
    (and
      (= (array-length depths) 6)
      (= (compiler-reg-loop-nest-depth-at depths 0) 0)
      (= (compiler-reg-loop-nest-depth-at depths 1) 1)
      (= (compiler-reg-loop-nest-depth-at depths 2) 1)
      (= (compiler-reg-loop-nest-depth-at depths 3) 1)
      (= (compiler-reg-loop-nest-depth-at depths 4) 1)
      (= (compiler-reg-loop-nest-depth-at depths 5) 0))))

;; entry / outer / inner / inner-latch / outer-latch / exit. Containment is what
;; makes the level count a NEST: `inner-latch` reaches the outer latch through
;; the inner header, so it carries both levels.
(define (compiler-reg-loop-nest-nested-blocks) : ir.CompilerIrBlockList
  (compiler-reg-loop-nest-block
    "entry"
    (compiler-reg-loop-nest-jump "outer")
    (compiler-reg-loop-nest-block
      "outer"
      (compiler-reg-loop-nest-branch "inner" "exit")
      (compiler-reg-loop-nest-block
        "inner"
        (compiler-reg-loop-nest-branch "inner-latch" "outer-latch")
        (compiler-reg-loop-nest-block
          "inner-latch"
          (compiler-reg-loop-nest-jump "inner")
          (compiler-reg-loop-nest-block
            "outer-latch"
            (compiler-reg-loop-nest-jump "outer")
            (compiler-reg-loop-nest-block
              "exit"
              (compiler-reg-loop-nest-return)
              ir.CompilerIrBlockList.Nil)))))))

(define (compiler-reg-loop-nest-nested-ok?) : bool
  (let
    [depths : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths
        (compiler-reg-loop-nest-nested-blocks))]
    (and
      (= (array-length depths) 6)
      (= (compiler-reg-loop-nest-depth-at depths 0) 0)
      (= (compiler-reg-loop-nest-depth-at depths 1) 1)
      (= (compiler-reg-loop-nest-depth-at depths 2) 2)
      (= (compiler-reg-loop-nest-depth-at depths 3) 2)
      (= (compiler-reg-loop-nest-depth-at depths 4) 1)
      (= (compiler-reg-loop-nest-depth-at depths 5) 0))))

;; entry / header / body / tail / latch / exit, where `body` ends without a
;; terminator. The ONLY edge into `tail` is the unnamed fall-through, so a nest
;; built from named successors alone would leave `body` outside its own loop.
(define (compiler-reg-loop-nest-fallthrough-blocks) : ir.CompilerIrBlockList
  (compiler-reg-loop-nest-block
    "entry"
    (compiler-reg-loop-nest-jump "header")
    (compiler-reg-loop-nest-block
      "header"
      (compiler-reg-loop-nest-branch "body" "exit")
      (compiler-reg-loop-nest-block
        "body"
        (compiler-reg-loop-nest-open)
        (compiler-reg-loop-nest-block
          "tail"
          (compiler-reg-loop-nest-jump "latch")
          (compiler-reg-loop-nest-block
            "latch"
            (compiler-reg-loop-nest-jump "header")
            (compiler-reg-loop-nest-block
              "exit"
              (compiler-reg-loop-nest-return)
              ir.CompilerIrBlockList.Nil)))))))

(define (compiler-reg-loop-nest-fallthrough-ok?) : bool
  (let
    [depths : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths
        (compiler-reg-loop-nest-fallthrough-blocks))]
    (and
      (= (array-length depths) 6)
      (= (compiler-reg-loop-nest-depth-at depths 0) 0)
      (= (compiler-reg-loop-nest-depth-at depths 1) 1)
      (= (compiler-reg-loop-nest-depth-at depths 2) 1)
      (= (compiler-reg-loop-nest-depth-at depths 3) 1)
      (= (compiler-reg-loop-nest-depth-at depths 4) 1)
      (= (compiler-reg-loop-nest-depth-at depths 5) 0))))

;; A loop among blocks the entry cannot reach is still emitted and still
;; allocated, so the DFS is a forest and ranks it. Parity with the range
;; encoding, which never asked about reachability at all.
(define (compiler-reg-loop-nest-unreachable-blocks) : ir.CompilerIrBlockList
  (compiler-reg-loop-nest-block
    "entry"
    (compiler-reg-loop-nest-return)
    (compiler-reg-loop-nest-block
      "dead-header"
      (compiler-reg-loop-nest-jump "dead-latch")
      (compiler-reg-loop-nest-block
        "dead-latch"
        (compiler-reg-loop-nest-jump "dead-header")
        ir.CompilerIrBlockList.Nil))))

(define (compiler-reg-loop-nest-unreachable-ok?) : bool
  (let
    [depths : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths
        (compiler-reg-loop-nest-unreachable-blocks))]
    (and
      (= (array-length depths) 3)
      (= (compiler-reg-loop-nest-depth-at depths 0) 0)
      (= (compiler-reg-loop-nest-depth-at depths 1) 1)
      (= (compiler-reg-loop-nest-depth-at depths 2) 1))))

;; --- CFG loop nest: the member set, and what admits a hoist on it -----------
;;
;; The const-hoist reads the same nest, but it does not want a DEPTH: it wants
;; the loop as a SET, because everything it has to prove -- nothing enters the
;; loop except at the header, so a load placed before the header runs before
;; every site -- is a question about membership, and the answers the index
;; range gave to it were answers about the emitted order.
;; entry / body / latch / header / exit, with the header laid out BELOW the
;; blocks it heads: what a rotation produces, and the shape the index range
;; cannot read. `loop-ends` records a back edge only when the source is at or
;; after the target, so the real latch (block 2, jumping UP to block 3) is
;; invisible to it; it reads block 1 as a header instead, over the range
;; [1..3], and then rejects the loop outright, because `entry` -- outside that
;; range -- branches to block 3, strictly inside it. That false side entry is
;; the refusal the hoist measured. As a member set the same loop is
;; unremarkable: {header, body, latch}, entered only at the header, with
;; `entry` the header's one predecessor from outside it.
(define (compiler-reg-loop-nest-rotated-blocks) : ir.CompilerIrBlockList
  (compiler-reg-loop-nest-block
    "entry"
    (compiler-reg-loop-nest-jump "header")
    (compiler-reg-loop-nest-block
      "body"
      (compiler-reg-loop-nest-jump "latch")
      (compiler-reg-loop-nest-block
        "latch"
        (compiler-reg-loop-nest-jump "header")
        (compiler-reg-loop-nest-block
          "header"
          (compiler-reg-loop-nest-branch "body" "exit")
          (compiler-reg-loop-nest-block
            "exit"
            (compiler-reg-loop-nest-return)
            ir.CompilerIrBlockList.Nil))))))

(define (compiler-reg-loop-nest-rotated-ok?) : bool
  (let
    [nest : reg.CompilerRegLoopNest
      (reg.compiler-reg-loop-nest-build (compiler-reg-loop-nest-rotated-blocks))]
    [total : i64 (reg.compiler-reg-loop-nest-header-members! nest 3 1)]
    [depths : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths
        (compiler-reg-loop-nest-rotated-blocks))]
    (and
      (= (reg.compiler-reg-loop-nest-header-count nest) 1)
      (= (reg.compiler-reg-loop-nest-header nest 0) 3)
      (= total 2)
      (reg.compiler-reg-loop-nest-member? nest 1 1)
      (reg.compiler-reg-loop-nest-member? nest 2 1)
      (reg.compiler-reg-loop-nest-member? nest 3 1)
      (not (reg.compiler-reg-loop-nest-member? nest 0 1))
      (not (reg.compiler-reg-loop-nest-member? nest 4 1))
      ;; The preheader, named without consulting the layout: `entry` is the
      ;; header's only predecessor that is not itself in the loop.
      (= (reg.compiler-reg-loop-nest-outside-pred nest 3 1) 0)
      ;; The span the members occupy is still what an instruction-point hull
      ;; has to be written in, and it does NOT start at the header.
      (= (reg.compiler-reg-loop-nest-member-lo nest 3 total) 1)
      (= (reg.compiler-reg-loop-nest-member-hi nest 3 total) 3)
      ;; And the rotation costs the frequency ranking nothing either.
      (= (compiler-reg-loop-nest-depth-at depths 0) 0)
      (= (compiler-reg-loop-nest-depth-at depths 1) 1)
      (= (compiler-reg-loop-nest-depth-at depths 2) 1)
      (= (compiler-reg-loop-nest-depth-at depths 3) 1)
      (= (compiler-reg-loop-nest-depth-at depths 4) 0))))

;; entry / header / body / latch / second / exit: `second` jumps to the header
;; as well, so the loop has TWO entries. No single place runs before every
;; iteration, and a magic loaded at either one is absent on the other path.
;; Membership cannot express that refusal -- the member set is the honest loop
;; either way -- so the refusal is the predecessor COUNT: two from outside.
(define (compiler-reg-loop-nest-two-entry-blocks) : ir.CompilerIrBlockList
  (compiler-reg-loop-nest-block
    "entry"
    (compiler-reg-loop-nest-branch "header" "second")
    (compiler-reg-loop-nest-block
      "header"
      (compiler-reg-loop-nest-branch "body" "exit")
      (compiler-reg-loop-nest-block
        "body"
        (compiler-reg-loop-nest-jump "latch")
        (compiler-reg-loop-nest-block
          "latch"
          (compiler-reg-loop-nest-jump "header")
          (compiler-reg-loop-nest-block
            "second"
            (compiler-reg-loop-nest-jump "header")
            (compiler-reg-loop-nest-block
              "exit"
              (compiler-reg-loop-nest-return)
              ir.CompilerIrBlockList.Nil)))))))

;; entry / header / body / latch / side / exit, where `side` jumps into the
;; loop BODY rather than its header. The natural-loop walk stops only at the
;; header, so it follows `side` back to `entry` and swallows both: an
;; irreducible entry is answered as a conservative SUPERSET, which is the safe
;; direction. The header is then left with no predecessor from outside its own
;; set at all, and the hoist has nowhere to inject -- refused, by the same one
;; count, without a second predicate.
(define (compiler-reg-loop-nest-side-entry-blocks) : ir.CompilerIrBlockList
  (compiler-reg-loop-nest-block
    "entry"
    (compiler-reg-loop-nest-branch "header" "side")
    (compiler-reg-loop-nest-block
      "header"
      (compiler-reg-loop-nest-branch "body" "exit")
      (compiler-reg-loop-nest-block
        "body"
        (compiler-reg-loop-nest-jump "latch")
        (compiler-reg-loop-nest-block
          "latch"
          (compiler-reg-loop-nest-jump "header")
          (compiler-reg-loop-nest-block
            "side"
            (compiler-reg-loop-nest-jump "body")
            (compiler-reg-loop-nest-block
              "exit"
              (compiler-reg-loop-nest-return)
              ir.CompilerIrBlockList.Nil)))))))

(define (compiler-reg-loop-nest-multi-entry-ok?) : bool
  (let
    [two : reg.CompilerRegLoopNest
      (reg.compiler-reg-loop-nest-build
        (compiler-reg-loop-nest-two-entry-blocks))]
    [two-total : i64 (reg.compiler-reg-loop-nest-header-members! two 1 1)]
    [side : reg.CompilerRegLoopNest
      (reg.compiler-reg-loop-nest-build
        (compiler-reg-loop-nest-side-entry-blocks))]
    ;; WHICH of the two blocks the DFS names the header of an irreducible pair
    ;; depends on the order it walks `entry`'s arms in -- either answer is a
    ;; correct natural loop -- so read it from the nest instead of assuming.
    [side-header : i64 (reg.compiler-reg-loop-nest-header side 0)]
    [side-total : i64
      (reg.compiler-reg-loop-nest-header-members! side side-header 1)]
    (and
      ;; Two entries into the header: header + body + latch, and `second`
      ;; stays outside, so the header keeps two predecessors from outside.
      (= (reg.compiler-reg-loop-nest-header-count two) 1)
      (= two-total 2)
      (not (reg.compiler-reg-loop-nest-member? two 4 1))
      (= (reg.compiler-reg-loop-nest-outside-pred two 1 1) (- 0 2))
      ;; An entry into the BODY instead. The walk stops only at the header, and
      ;; this header does not dominate its own latch, so it runs back past the
      ;; loop until it runs out of graph -- and swallows the function's ENTRY
      ;; block. That is the shape the hoist has to refuse and CANNOT refuse on
      ;; a predecessor count: block 0 is reached from the caller, through no
      ;; predecessor at all, so no injection dominates the set however few
      ;; edges cross into it. The guard is the entry itself being a member
      ;; under a header that is not the entry.
      (= (reg.compiler-reg-loop-nest-header-count side) 1)
      (reg.compiler-reg-loop-nest-member? side 0 1)
      (not (= side-header 0))
      (= (reg.compiler-reg-loop-nest-member-lo side side-header side-total) 0))))

;; The two shapes the range encoding overcharged, read as membership. `early`
;; is laid out inside the loop's span but reaches the exit and never the latch,
;; so it is not a member: the leaf scan skips it, and a call there no longer
;; costs the loop its hoist. The sunk `cold` block's backward-in-layout jump
;; closes no cycle at all, so the nest offers the hoist no region there to
;; consider in the first place.
(define (compiler-reg-loop-nest-non-member-ok?) : bool
  (let
    [nest : reg.CompilerRegLoopNest
      (reg.compiler-reg-loop-nest-build
        (compiler-reg-loop-nest-early-exit-blocks))]
    [total : i64 (reg.compiler-reg-loop-nest-header-members! nest 1 1)]
    [sunk : reg.CompilerRegLoopNest
      (reg.compiler-reg-loop-nest-build
        (compiler-reg-loop-nest-sunk-cold-blocks))]
    (and
      (= (reg.compiler-reg-loop-nest-header-count nest) 1)
      (= (reg.compiler-reg-loop-nest-header nest 0) 1)
      (= total 2)
      (reg.compiler-reg-loop-nest-member? nest 2 1)
      (reg.compiler-reg-loop-nest-member? nest 4 1)
      (not (reg.compiler-reg-loop-nest-member? nest 3 1))
      (= (reg.compiler-reg-loop-nest-member-lo nest 1 total) 1)
      (= (reg.compiler-reg-loop-nest-member-hi nest 1 total) 4)
      (= (reg.compiler-reg-loop-nest-outside-pred nest 1 1) 0)
      (= (reg.compiler-reg-loop-nest-header-count sunk) 0))))

;; The depth vector is one CONSUMER of the producer and not a second analysis:
;; charging one level per member set by hand, from the same nest, has to
;; reproduce `compiler-reg-function-loop-depths` entry for entry.
(define (compiler-reg-loop-nest-producer-agrees?
  [blocks : ir.CompilerIrBlockList]) : bool
  (let
    [depths : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths blocks)]
    [nest : reg.CompilerRegLoopNest (reg.compiler-reg-loop-nest-build blocks)]
    [count : i64 (array-length depths)]
    [mine : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (< index (reg.compiler-reg-loop-nest-header-count nest))
        (let
          [header : i64 (reg.compiler-reg-loop-nest-header nest index)]
          [generation : i64 (+ index 1)]
          [_total : i64
            (reg.compiler-reg-loop-nest-header-members! nest header generation)]
          [block : i64 0]
          (begin
            (while (< block count)
              (begin
                (if (reg.compiler-reg-loop-nest-member? nest block generation)
                  (set! (array-ref mine block) (+ (array-ref mine block) 1))
                  unit)
                (set! block (+ block 1))))
            (set! index (+ index 1)))))
      (set! index 0)
      (while (< index count)
        (begin
          (if (= (array-ref mine index) (array-ref depths index))
            unit
            (set! ok false))
          (set! index (+ index 1))))
      ok)))

(define (compiler-reg-loop-nest-consumer-ok?) : bool
  (and
    (compiler-reg-loop-nest-producer-agrees?
      (compiler-reg-loop-nest-nested-blocks))
    (compiler-reg-loop-nest-producer-agrees?
      (compiler-reg-loop-nest-two-latch-blocks))
    (compiler-reg-loop-nest-producer-agrees?
      (compiler-reg-loop-nest-early-exit-blocks))
    (compiler-reg-loop-nest-producer-agrees?
      (compiler-reg-loop-nest-rotated-blocks))
    (compiler-reg-loop-nest-producer-agrees?
      (compiler-reg-loop-nest-fallthrough-blocks))))

;; The producer keeps nothing a later question could inherit: the same header,
;; asked twice under two generations, answers with the same set, and the inner
;; loop asked in between neither shrinks nor widens it.
(define (compiler-reg-loop-nest-regeneration-ok?) : bool
  (let
    [nest : reg.CompilerRegLoopNest
      (reg.compiler-reg-loop-nest-build (compiler-reg-loop-nest-nested-blocks))]
    [outer : i64 (reg.compiler-reg-loop-nest-header-members! nest 1 1)]
    [inner : i64 (reg.compiler-reg-loop-nest-header-members! nest 2 2)]
    [again : i64 (reg.compiler-reg-loop-nest-header-members! nest 1 3)]
    (and
      (= outer 3)
      (= inner 1)
      (= again outer)
      (reg.compiler-reg-loop-nest-member? nest 2 3)
      (reg.compiler-reg-loop-nest-member? nest 3 3)
      (reg.compiler-reg-loop-nest-member? nest 4 3)
      (not (reg.compiler-reg-loop-nest-member? nest 0 3))
      (not (reg.compiler-reg-loop-nest-member? nest 5 3)))))

;; --- CFG loop nest: the layout span, and the preheader spliced on it --------
;;
;; The last readers of the index range are the ones that still have to speak in
;; SPANS: the loop-split rescue's region, the leaf-CSR region, the call
;; region's loop row. What those want is not "the highest block with an edge
;; into h from at or below it" but "the block range h's loop actually occupies"
;; -- the same numbers only for a layout that keeps every loop contiguous and
;; header-first, and an answer at all for blocks that head no loop whatever.
;;
;; The span is anchored on the loop's lowest MEMBER, so a ROTATED loop -- one
;; whose header is laid out below the body it dominates -- gets a span too;
;; only the assumption "the header is the span's first block" is gone.
(define (compiler-reg-loop-nest-span-lo
  [spans : (__tl_dyn-array i64)]
  [index : i64]) : i64
  (if (and (>= index 0) (< (+ (* 2 index) 1) (array-length spans)))
    (array-ref spans (* 2 index))
    (- 0 2)))

(define (compiler-reg-loop-nest-span-hi
  [spans : (__tl_dyn-array i64)]
  [index : i64]) : i64
  (if (and (>= index 0) (< (+ (* 2 index) 1) (array-length spans)))
    (array-ref spans (+ (* 2 index) 1))
    (- 0 2)))

(define (compiler-reg-loop-nest-spans-of [blocks : ir.CompilerIrBlockList]) : (__tl_dyn-array
    i64)
  (let
    [seq : ir.CompilerIrBlockSeq
      (live.compiler-live-ir-block-list-to-seq blocks)]
    (reg.compiler-reg-loop-nest-spans-seq
      seq
      (ir.compiler-ir-block-seq-count seq))))

(define (compiler-reg-loop-nest-spans-ok?) : bool
  (let
    [nested : (__tl_dyn-array i64)
      (compiler-reg-loop-nest-spans-of (compiler-reg-loop-nest-nested-blocks))]
    [early : (__tl_dyn-array i64)
      (compiler-reg-loop-nest-spans-of
        (compiler-reg-loop-nest-early-exit-blocks))]
    [sunk : (__tl_dyn-array i64)
      (compiler-reg-loop-nest-spans-of
        (compiler-reg-loop-nest-sunk-cold-blocks))]
    [rotated : (__tl_dyn-array i64)
      (compiler-reg-loop-nest-spans-of (compiler-reg-loop-nest-rotated-blocks))]
    (and
      ;; A nest: each loop's span is recorded on its OWN header, and the outer
      ;; span contains the inner one rather than being merged with it.
      (= (compiler-reg-loop-nest-span-lo nested 1) 1)
      (= (compiler-reg-loop-nest-span-hi nested 1) 4)
      (= (compiler-reg-loop-nest-span-lo nested 2) 2)
      (= (compiler-reg-loop-nest-span-hi nested 2) 3)
      (= (compiler-reg-loop-nest-span-hi nested 0) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi nested 3) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi nested 4) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi nested 5) (- 0 1))
      ;; The break arm is laid out inside the span and is not a member. The
      ;; span stays the overapproximation it always was -- which is why every
      ;; consumer of it still re-proves single entry over the range it uses.
      (= (compiler-reg-loop-nest-span-lo early 1) 1)
      (= (compiler-reg-loop-nest-span-hi early 1) 4)
      (= (compiler-reg-loop-nest-span-hi early 3) (- 0 1))
      ;; The sunk cold block's backward-in-layout jump closes no cycle, so no
      ;; block is given a span at all -- where the range encoding published one
      ;; covering [join, cold] and charged a rescue region for it.
      (= (compiler-reg-loop-nest-span-hi sunk 0) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi sunk 1) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi sunk 2) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi sunk 3) (- 0 1))
      ;; A ROTATED loop is contiguous but does not START at its header: the
      ;; span is [body..header] and it is published under the header, block 3.
      ;; A hull anchored on the header could only answer -1 here, which is what
      ;; used to cost every rotated loop its rescue. No other block heads
      ;; anything -- in particular block 1, which the range encoding read as a
      ;; header with no out-of-loop predecessor at all.
      (= (compiler-reg-loop-nest-span-lo rotated 3) 1)
      (= (compiler-reg-loop-nest-span-hi rotated 3) 3)
      (= (compiler-reg-loop-nest-span-hi rotated 0) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi rotated 1) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi rotated 2) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi rotated 4) (- 0 1)))))

;; entry / body / latch / header / other / exit. The rescue's motivating case
;; under rotation: `header` is laid out BELOW the body and latch it heads, and
;; `entry` reaches it over a CRITICAL edge (entry has two successors, header
;; has two predecessors), which is exactly the shape that cannot receive a
;; once-per-loop INTO copy without a dedicated preheader.
;;
;; The index range cannot find that header: it records a back edge only from a
;; source at or after the target, and every edge into block 3 comes from above
;; it, so loop-ends[3] stays -1 and block 1 is read as the header of [1..3]
;; instead -- a block with no out-of-loop predecessor at all. Nothing is
;; spliced and the rescue is refused. As a member set the loop is
;; {header, body, latch}, entered only through `entry`, and the preheader goes
;; in where it belongs.
(define (compiler-reg-preheader-rotated-blocks) : ir.CompilerIrBlockList
  (compiler-reg-loop-nest-block
    "entry"
    (compiler-reg-loop-nest-branch "header" "other")
    (compiler-reg-loop-nest-block
      "body"
      (compiler-reg-loop-nest-jump "latch")
      (compiler-reg-loop-nest-block
        "latch"
        (compiler-reg-loop-nest-jump "header")
        (compiler-reg-loop-nest-block
          "header"
          (compiler-reg-loop-nest-branch "body" "exit")
          (compiler-reg-loop-nest-block
            "other"
            (compiler-reg-loop-nest-jump "exit")
            (compiler-reg-loop-nest-block
              "exit"
              (compiler-reg-loop-nest-return)
              ir.CompilerIrBlockList.Nil)))))))

(define (compiler-reg-preheader-label-at
  [blocks : ir.CompilerIrBlockList]
  [index : i64]) : i64
  (let
    [seq : ir.CompilerIrBlockSeq
      (live.compiler-live-ir-block-list-to-seq blocks)]
    (if (or (< index 0) (>= index (ir.compiler-ir-block-seq-count seq)))
      (ir.compiler-ir-label-none)
      (match (ir.compiler-ir-block-seq-ref seq index)
        [(ir.CompilerIrBlock.Block label _) label]))))

(define (compiler-reg-preheader-succ-has?
  [blocks : ir.CompilerIrBlockList]
  [index : i64]
  [label : i64]) : bool
  (let
    [seq : ir.CompilerIrBlockSeq
      (live.compiler-live-ir-block-list-to-seq blocks)]
    (if (or (< index 0) (>= index (ir.compiler-ir-block-seq-count seq)))
      false
      (live.compiler-live-label-set-contains?
        (live.compiler-live-block-successors
          (ir.compiler-ir-block-seq-ref seq index))
        label))))

(define (compiler-reg-preheader-rotated-splice-ok?) : bool
  (let
    [blocks : ir.CompilerIrBlockList (compiler-reg-preheader-rotated-blocks)]
    [spliced : ir.CompilerIrBlockList
      (reg.compiler-reg-loop-split-splice-preheader
        blocks
        (ir.compiler-ir-label "header"))]
    ;; Asked a second time, the splice finds the preheader it already made and
    ;; leaves the function alone.
    [again : ir.CompilerIrBlockList
      (reg.compiler-reg-loop-split-splice-preheader
        spliced
        (ir.compiler-ir-label "header"))]
    ;; And asked about the block the RANGE encoding would have called a header
    ;; of the sunk-cold shape, there is no loop to give a preheader to.
    [sunk : ir.CompilerIrBlockList
      (reg.compiler-reg-loop-split-splice-preheader
        (compiler-reg-loop-nest-sunk-cold-blocks)
        (ir.compiler-ir-label "join"))]
    (and
      (= (ir.compiler-ir-block-list-count blocks) 6)
      (= (ir.compiler-ir-block-list-count spliced) 7)
      ;; The new block sits immediately before the header it serves.
      (=
        (compiler-reg-preheader-label-at spliced 3)
        (ir.compiler-ir-label "header.preheader"))
      (=
        (compiler-reg-preheader-label-at spliced 4)
        (ir.compiler-ir-label "header"))
      ;; `entry`'s critical edge now lands on the preheader, and the latch's
      ;; back edge -- inside the loop -- is left pointing at the header.
      (compiler-reg-preheader-succ-has?
        spliced
        0
        (ir.compiler-ir-label "header.preheader"))
      (not
        (compiler-reg-preheader-succ-has?
          spliced
          0
          (ir.compiler-ir-label "header")))
      (compiler-reg-preheader-succ-has?
        spliced
        2
        (ir.compiler-ir-label "header"))
      (= (ir.compiler-ir-block-list-count again) 7)
      (= (ir.compiler-ir-block-list-count sunk) 4))))

;; The span array owns no state across calls either: the same block list asked
;; twice gives the same spans, and another shape asked in between must not leak
;; a stamp generation into the second answer.
(define (compiler-reg-loop-nest-spans-deterministic-ok?) : bool
  (let
    [first : (__tl_dyn-array i64)
      (compiler-reg-loop-nest-spans-of (compiler-reg-loop-nest-nested-blocks))]
    [_other : (__tl_dyn-array i64)
      (compiler-reg-loop-nest-spans-of
        (compiler-reg-loop-nest-two-latch-blocks))]
    [second : (__tl_dyn-array i64)
      (compiler-reg-loop-nest-spans-of (compiler-reg-loop-nest-nested-blocks))]
    [count : i64 (array-length first)]
    [index : i64 0]
    [ok : bool (= count (array-length second))]
    (begin
      (while (< index count)
        (begin
          (if (= (array-ref first index) (array-ref second index))
            unit
            (set! ok false))
          (set! index (+ index 1))))
      ok)))

;; --- live-in bridge at a block that opens with a call -----------------------
;;
;; A segment's START is read as the value's own definition, so a clobber AT the
;; start is that definition's own instruction and is not spanned. That reading
;; is sound only while the value's linearly-first live POINT really is its def,
;; which is a property of the block ORDER, not of the program: here `use` is
;; laid out before `def`, so var 0's first touch would be its READ at the return
;; -- and the call that opens `use`, which var 0 is live across, would sit below
;; the hull and read as un-spanned. Handing it a caller-saved home there is a
;; miscompile. The live-in bridge opens the segment at the odd point below the
;; block's first instruction, so the call lands inside the hull for every order.
(define (compiler-reg-live-in-call-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "live_in_call")
    ir.CompilerIrParamList.Nil
    (compiler-reg-i64-ty)
    2
    (compiler-reg-loop-nest-block
      "entry"
      (compiler-reg-loop-nest-jump "def")
      (compiler-reg-loop-nest-block
        "use"
        (compiler-reg-test-instr-seq-prepend
          (ir.CompilerIrInstr.Call
            1
            (ir.compiler-ir-test-symbol "side_effect")
            (ir.CompilerIrCallArgs.Nil)
            (ast.AstType.Unit))
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Return
              (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
            (ir.compiler-ir-instr-seq-empty)))
        (compiler-reg-loop-nest-block
          "def"
          (compiler-reg-test-instr-seq-prepend
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 9)
              (compiler-reg-i64-ty))
            (compiler-reg-loop-nest-jump "use"))
          ir.CompilerIrBlockList.Nil)))))

(define (compiler-reg-live-in-call-ok?) : bool
  (let
    [func : ir.CompilerIrFunction (compiler-reg-live-in-call-function)]
    [liveness : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function func)]
    (match (reg.compiler-reg-live-interval-selection func liveness)
      [(reg.CompilerRegIntervalSelection.Selection _ index)
        (and
          ;; The jump is point 0, so `use` opens at point 2 and the bridge
          ;; anchors var 0 at point 1 -- the odd slot no instruction occupies.
          (= (array-ref index.starts 0) 1)
          ;; And that is what makes the call spanned: hull start 1, exclusive,
          ;; still admits the call at point 2.
          (reg.compiler-reg-segments-span-clobber?
            (array-ref index.segments 0)
            (reg.compiler-reg-direct-call-points func)
            (array-ref index.starts 0)
            false))])))

;; The analysis owns no state across calls: the same block list ranked twice
;; must give the same vector, and ranking another shape in between must not
;; leak a stamp generation into it.
(define (compiler-reg-loop-nest-deterministic-ok?) : bool
  (let
    [first : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths
        (compiler-reg-loop-nest-nested-blocks))]
    [_other : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths
        (compiler-reg-loop-nest-two-latch-blocks))]
    [second : (__tl_dyn-array i64)
      (reg.compiler-reg-function-loop-depths
        (compiler-reg-loop-nest-nested-blocks))]
    [count : i64 (array-length first)]
    [index : i64 0]
    [ok : bool (= count (array-length second))]
    (begin
      (while (< index count)
        (begin
          (if (= (array-ref first index) (array-ref second index))
            unit
            (set! ok false))
          (set! index (+ index 1))))
      ok)))

(define (compiler-regalloc-core-self-test?) : bool
  (begin
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-early-exit-ok?"
      (compiler-reg-loop-nest-early-exit-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-sunk-cold-ok?"
      (compiler-reg-loop-nest-sunk-cold-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-two-latch-ok?"
      (compiler-reg-loop-nest-two-latch-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-nested-ok?"
      (compiler-reg-loop-nest-nested-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-fallthrough-ok?"
      (compiler-reg-loop-nest-fallthrough-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-unreachable-ok?"
      (compiler-reg-loop-nest-unreachable-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-deterministic-ok?"
      (compiler-reg-loop-nest-deterministic-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-rotated-ok?"
      (compiler-reg-loop-nest-rotated-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-multi-entry-ok?"
      (compiler-reg-loop-nest-multi-entry-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-non-member-ok?"
      (compiler-reg-loop-nest-non-member-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-consumer-ok?"
      (compiler-reg-loop-nest-consumer-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-regeneration-ok?"
      (compiler-reg-loop-nest-regeneration-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-spans-ok?"
      (compiler-reg-loop-nest-spans-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-nest-spans-deterministic-ok?"
      (compiler-reg-loop-nest-spans-deterministic-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-preheader-rotated-splice-ok?"
      (compiler-reg-preheader-rotated-splice-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-live-in-call-ok?"
      (compiler-reg-live-in-call-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-program-maps-suppression-ok?"
      (compiler-reg-program-maps-suppression-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-low-bit-index32-powers-ok?"
      (cfg test (compiler-reg-low-bit-index32-powers-ok? 0 1) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-reuse-ok?"
      (compiler-reg-reuse-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-f64-reuse-ok?"
      (compiler-reg-f64-reuse-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-overlap-spill-ok?"
      (compiler-reg-overlap-spill-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-f64-overlap-spill-ok?"
      (compiler-reg-f64-overlap-spill-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-live-ok?"
      (compiler-reg-call-live-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-f64-call-live-ok?"
      (compiler-reg-f64-call-live-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-arg-ok?"
      (compiler-reg-call-arg-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-f64-call-arg-ok?"
      (compiler-reg-f64-call-arg-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-ineligible-ok?"
      (compiler-reg-ineligible-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-target-clobbers-ok?"
      (compiler-reg-target-clobbers-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-xmm-clobbers-ok?"
      (compiler-reg-xmm-clobbers-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-xmm-abi-call-constraints-ok?"
      (compiler-reg-xmm-abi-call-constraints-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-xmm-shared-greedy-bank-ok?"
      (compiler-reg-xmm-shared-greedy-bank-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-xmm-vector-class-reset-ok?"
      (compiler-reg-xmm-vector-class-reset-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-coalesce-ok?"
      (compiler-reg-coalesce-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-p22-nested-copy-ok?"
      (compiler-reg-p22-nested-copy-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-liveness-handle-ok?"
      (cfg test (compiler-reg-liveness-handle-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-liveness-handle-phi-ok?"
      (cfg test (compiler-reg-liveness-handle-phi-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-xmm-physical-ownership-ok?"
      (cfg test (compiler-reg-xmm-physical-ownership-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-dense-mask-on-vector-homes-ok?"
      (cfg test (compiler-reg-dense-mask-on-vector-homes-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-vector-mask-homes-ok?"
      (compiler-reg-vector-mask-homes-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-mask-pressure-spill-home-ok?"
      (compiler-reg-mask-pressure-spill-home-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-segmented-interference-ok?"
      (compiler-reg-segmented-interference-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-hole-aware-register-reuse-ok?"
      (compiler-reg-hole-aware-register-reuse-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-tail-call-clobber-ok?"
      (compiler-reg-tail-call-clobber-ok?))
    true))

(define (compiler-regalloc-scalar-self-test?) : bool
  (begin
    (compiler-regalloc-self-test-require!
      "compiler-reg-early-exit-general-ok?"
      (cfg test (compiler-reg-early-exit-general-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-early-exit-float-guard-refused-ok?"
      (cfg test (compiler-reg-early-exit-float-guard-refused-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-cold-call-split-ok?"
      (cfg test (compiler-reg-cold-call-split-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-weights-ok?"
      (cfg test (compiler-reg-call-hole-weights-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-select-ok?"
      (cfg test (compiler-reg-call-hole-select-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-rewrite-shape-ok?"
      (cfg test (compiler-reg-call-hole-rewrite-shape-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-cross-block-ok?"
      (cfg test (compiler-reg-call-hole-cross-block-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-join-ok?"
      (cfg test (compiler-reg-call-hole-join-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-redef-ok?"
      (cfg test (compiler-reg-call-hole-redef-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-flow-conservative-ok?"
      (cfg test (compiler-reg-call-hole-flow-conservative-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-drop-ok?"
      (cfg test (compiler-reg-call-hole-drop-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-round-ok?"
      (cfg test (compiler-reg-call-hole-round-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-declines-ok?"
      (cfg test (compiler-reg-call-hole-declines-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-cold-arm-weight-ok?"
      (cfg test (compiler-reg-call-hole-cold-arm-weight-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-loop-arm-weight-ok?"
      (cfg test (compiler-reg-call-hole-loop-arm-weight-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-csr-qualify-ok?"
      (cfg test (compiler-reg-call-hole-csr-qualify-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-csr-split-ok?"
      (cfg test (compiler-reg-call-hole-csr-split-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-csr-cost-strict-ok?"
      (cfg test (compiler-reg-call-hole-csr-cost-strict-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-hole-recursive-arm-ok?"
      (cfg test (compiler-reg-call-hole-recursive-arm-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-detect-ok?"
      (cfg test (compiler-reg-loop-park-detect-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-eligible-ok?"
      (cfg test (compiler-reg-loop-park-eligible-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-sites-ok?"
      (cfg test (compiler-reg-loop-park-sites-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-direct-rewrite-ok?"
      (cfg test (compiler-reg-loop-park-direct-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-splice-rewrite-ok?"
      (cfg test (compiler-reg-loop-park-splice-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-verify-ok?"
      (cfg test (compiler-reg-loop-park-verify-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-round-ok?"
      (cfg test (compiler-reg-loop-park-round-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-declines-ok?"
      (cfg test (compiler-reg-loop-park-declines-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-deep-parks-ok?"
      (cfg test (compiler-reg-loop-park-deep-parks-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-deep-two-bases-homed-ok?"
      (cfg test (compiler-reg-loop-park-deep-two-bases-homed-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-deep-declines-ok?"
      (cfg test (compiler-reg-loop-park-deep-declines-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-park-deep-ranking-ok?"
      (cfg test (compiler-reg-loop-park-deep-ranking-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-park-ladder-ok?"
      (cfg test (compiler-reg-park-ladder-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scavenge-segment-hulls-ok?"
      (cfg test (compiler-reg-scavenge-segment-hulls-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-call-live-ok?"
      (compiler-reg-scalar-call-live-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-f64-call-live-ok?"
      (compiler-reg-scalar-f64-call-live-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-win64-f64-call-live-ok?"
      (compiler-reg-scalar-win64-f64-call-live-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-handle-eligible-ok?"
      (compiler-reg-scalar-handle-eligible-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-handle-call-arg-ok?"
      (compiler-reg-scalar-handle-call-arg-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-indirect-call-arg-ok?"
      (compiler-reg-scalar-indirect-call-arg-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-c-abi-store-result-call-arg-ok?"
      (compiler-reg-scalar-c-abi-store-result-call-arg-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-win64-indirect-call-arg-cap-ok?"
      (compiler-reg-scalar-win64-indirect-call-arg-cap-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-linux-param-registers-ok?"
      (cfg test (compiler-reg-scalar-linux-param-registers-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-windows-param-registers-ok?"
      (cfg test (compiler-reg-scalar-windows-param-registers-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-float-param-registers-ok?"
      (cfg test (compiler-reg-scalar-float-param-registers-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-win64-float-param-registers-ok?"
      (cfg test (compiler-reg-scalar-win64-float-param-registers-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-mixed-float-call-args-ok?"
      (cfg test (compiler-reg-scalar-mixed-float-call-args-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-win64-mixed-float-call-args-ok?"
      (cfg test (compiler-reg-scalar-win64-mixed-float-call-args-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-windows-rsi-rdi-pool-ok?"
      (cfg test (compiler-reg-scalar-windows-rsi-rdi-pool-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-win64-arg-result-prefs-ok?"
      (cfg test (compiler-reg-win64-arg-result-prefs-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-indirect-call-arg-prefs-ok?"
      (cfg test (compiler-reg-indirect-call-arg-prefs-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-clobber-ok?"
      (cfg test (compiler-reg-scalar-param-clobber-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-const-shift-pin-ok?"
      (cfg test (compiler-reg-scalar-param-const-shift-pin-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-var-shift-pin-ok?"
      (cfg test (compiler-reg-scalar-param-var-shift-pin-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-dead-before-call-pin-ok?"
      (cfg test (compiler-reg-scalar-param-dead-before-call-pin-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-rdx-div-span-ok?"
      (cfg test (compiler-reg-scalar-param-rdx-div-span-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-rcx-shift-span-ok?"
      (cfg test (compiler-reg-scalar-param-rcx-shift-span-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-pin-coalesce-demote-ok?"
      (cfg test (compiler-reg-scalar-param-pin-coalesce-demote-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-aggregate-param-pinned-ok?"
      (cfg test (compiler-reg-scalar-aggregate-param-pinned-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-function-intervals-ok?"
      (compiler-reg-scalar-function-intervals-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-interval-guardrail-ok?"
      (compiler-reg-scalar-interval-guardrail-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-edge-precise-allocation-intervals-ok?"
      (compiler-reg-scalar-edge-precise-allocation-intervals-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-loop-backedge-ok?"
      (compiler-reg-scalar-loop-backedge-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-zero-call-caller-saved-ok?"
      (compiler-reg-scalar-zero-call-caller-saved-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-zero-call-param-conflict-ok?"
      (cfg test (compiler-reg-scalar-zero-call-param-conflict-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-caller-saved-clobber-ok?"
      (compiler-reg-scalar-caller-saved-clobber-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-call-spanning-caller-saved-ok?"
      (compiler-reg-scalar-call-spanning-caller-saved-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-call-spanning-multiblock-local-ok?"
      (cfg test (compiler-reg-scalar-call-spanning-multiblock-local-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-call-spanning-multiblock-boundary-ok?"
      (cfg
        test
        (compiler-reg-scalar-call-spanning-multiblock-boundary-ok?)
        true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-region-invariant-ok?"
      (cfg test (compiler-reg-loop-region-invariant-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-region-defined-in-loop-refused?"
      (cfg test (compiler-reg-loop-region-defined-in-loop-refused?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-region-call-refused?"
      (cfg test (compiler-reg-loop-region-call-refused?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-region-admit-ok?"
      (cfg test (compiler-reg-loop-region-admit-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-region-score-ok?"
      (cfg test (compiler-reg-loop-region-score-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-region-overlap-ok?"
      (cfg test (compiler-reg-loop-region-overlap-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-evict-parked-ok?"
      (cfg test (compiler-reg-evict-parked-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-evict-busy-victim-refused?"
      (cfg test (compiler-reg-evict-busy-victim-refused?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-evict-all-busy-refused?"
      (cfg test (compiler-reg-evict-all-busy-refused?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-evict-dead-exit-ok?"
      (cfg test (compiler-reg-evict-dead-exit-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-evict-price-refused?"
      (cfg test (compiler-reg-evict-price-refused?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-evict-double-lend-refused?"
      (cfg test (compiler-reg-evict-double-lend-refused?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-evict-coalesced-victim-refused?"
      (cfg test (compiler-reg-evict-coalesced-victim-refused?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-evict-sole-occupant-ok?"
      (cfg test (compiler-reg-evict-sole-occupant-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-evict-class-mention-ok?"
      (cfg test (compiler-reg-evict-class-mention-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-evict-rewrite-shape-ok?"
      (cfg test (compiler-reg-evict-rewrite-shape-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-edge-copy-linear-ok?"
      (cfg test (compiler-reg-edge-copy-linear-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-edge-copy-backedge-ok?"
      (cfg test (compiler-reg-edge-copy-backedge-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-edge-copy-critical-refusal-ok?"
      (cfg test (compiler-reg-edge-copy-critical-refusal-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-rewrite-ok?"
      (cfg test (compiler-reg-loop-split-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-multiple-rewrite-ok?"
      (cfg test (compiler-reg-loop-split-multiple-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-leaf-csr-split-ok?"
      (cfg test (compiler-reg-leaf-csr-split-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-low-benefit-ok?"
      (cfg test (compiler-reg-loop-split-low-benefit-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-phi-region-refusal-ok?"
      (cfg test (compiler-reg-loop-split-phi-region-refusal-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-rcx-rdx-candidates-ok?"
      (cfg test (compiler-reg-loop-split-rcx-rdx-candidates-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-fixed-clobber-scan-ok?"
      (cfg test (compiler-reg-loop-split-fixed-clobber-scan-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-nblock-invariant-rewrite-ok?"
      (cfg test (compiler-reg-loop-split-nblock-invariant-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-nblock-outside-entry-refused-ok?"
      (cfg test (compiler-reg-loop-split-nblock-outside-entry-refused-ok?) true))
    true))

(define (compiler-regalloc-storage-self-test?) : bool
  (begin
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-classifier-ok?"
      (cfg test (compiler-reg-remat-classifier-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-invariant-word-load-admitted-ok?"
      (cfg test (compiler-reg-invariant-word-load-admitted-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-invariant-field-store-refused-ok?"
      (cfg test (compiler-reg-invariant-field-store-refused-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-invariant-call-refused-ok?"
      (cfg test (compiler-reg-invariant-call-refused-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-invariant-recipe-ok?"
      (cfg test (compiler-reg-invariant-recipe-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-invariant-base-availability-ok?"
      (cfg test (compiler-reg-invariant-base-availability-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-recompute-classifier-ok?"
      (cfg test (compiler-reg-remat-recompute-classifier-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-literal-assignment-ok?"
      (cfg test (compiler-reg-remat-literal-assignment-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-frozen-global-ok?"
      (cfg test (compiler-reg-remat-frozen-global-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-discount-weights-ok?"
      (cfg test (compiler-reg-remat-discount-weights-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-spill-weight-eviction-ok?"
      (cfg test (compiler-reg-remat-spill-weight-eviction-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-rewrite-shape-ok?"
      (cfg test (compiler-reg-remat-rewrite-shape-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-register-conflict-ok?"
      (cfg test (compiler-reg-remat-register-conflict-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-caller-clobber-refusal-ok?"
      (cfg test (compiler-reg-remat-caller-clobber-refusal-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-addr-of-source-refusal-ok?"
      (cfg test (compiler-reg-remat-addr-of-source-refusal-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-global-mov-rewrite-ok?"
      (cfg test (compiler-reg-remat-global-mov-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-global-load-rewrite-ok?"
      (cfg test (compiler-reg-remat-global-load-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-global-gep-rewrite-ok?"
      (cfg test (compiler-reg-remat-global-gep-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-global-mutation-refusal-ok?"
      (cfg test (compiler-reg-remat-global-mutation-refusal-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-spill-weight-eviction-ok?"
      (cfg test (compiler-reg-spill-weight-eviction-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-spill-weight-eviction-ok?"
      (cfg test (compiler-reg-loop-spill-weight-eviction-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-foldable-rebate-classification-ok?"
      (cfg test (compiler-reg-foldable-rebate-classification-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-foldable-rebate-keeps-counter-ok?"
      (cfg test (compiler-reg-foldable-rebate-keeps-counter-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-foldable-rebate-index-not-discounted-ok?"
      (cfg test (compiler-reg-foldable-rebate-index-not-discounted-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-foldable-rebate-idempotent-ok?"
      (cfg test (compiler-reg-foldable-rebate-idempotent-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-span-counts-ok?"
      (cfg test (compiler-reg-call-span-counts-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-span-census-ok?"
      (cfg test (compiler-reg-call-span-census-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-group-pair-widening-ok?"
      (cfg test (compiler-reg-group-pair-widening-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-switch-scratch-vregs-ok?"
      (compiler-reg-switch-scratch-vregs-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-bounds-scratch-vregs-ok?"
      (compiler-reg-bounds-scratch-vregs-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-memory-scratch-vregs-ok?"
      (compiler-reg-memory-scratch-vregs-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-early-scratch-model-ok?"
      (compiler-reg-early-scratch-model-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-greedy-live-union-invariant-ok?"
      (compiler-reg-greedy-live-union-invariant-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scratch-default-pool-target-invariant-ok?"
      (compiler-reg-scratch-default-pool-target-invariant-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scratch-callee-saved-registers-ok?"
      (compiler-reg-scratch-callee-saved-registers-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scratch-call-result-exclusions-ok?"
      (compiler-reg-scratch-call-result-exclusions-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scratch-coalesced-home-hull-preserve-ok?"
      (compiler-reg-scratch-coalesced-home-hull-preserve-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-early-scratch-never-spills-ok?"
      (compiler-reg-early-scratch-never-spills-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-early-scratch-exclusion-rehomes-ok?"
      (compiler-reg-early-scratch-exclusion-rehomes-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-dense-lookups-ok?"
      (compiler-reg-dense-lookups-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-dense-assignment-snapshot-ok?"
      (compiler-reg-dense-assignment-snapshot-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-stack-group-ok?"
      (compiler-reg-color-stack-group-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-spill-slot-sharing-ok?"
      (compiler-reg-color-spill-slot-sharing-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-fusion-pin-slots-ok?"
      (compiler-reg-color-fusion-pin-slots-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-phi-web-slot-sharing-ok?"
      (cfg test (compiler-reg-color-phi-web-slot-sharing-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-web-merge-ok?"
      (cfg test (compiler-reg-color-web-merge-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-carry-priority-ok?"
      (cfg test (compiler-reg-color-carry-priority-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-witness-chain-ok?"
      (cfg test (compiler-reg-color-witness-chain-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-spill-param-pins-ok?"
      (compiler-reg-color-spill-param-pins-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-avx2-param-ranges-ok?"
      (compiler-reg-color-avx2-param-ranges-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-spill-hole-demand-ok?"
      (compiler-reg-color-spill-hole-demand-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-spill-scratch-demand-ok?"
      (compiler-reg-color-spill-scratch-demand-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-vector-stack-slots-ok?"
      (compiler-reg-color-vector-stack-slots-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-vector-stack-mask-words-ok?"
      (compiler-reg-vector-stack-mask-words-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-storage-ranges-ok?"
      (compiler-reg-color-storage-ranges-ok?))
    true))

(define (compiler-regalloc-self-test) : i64
  (begin
    (compiler-regalloc-core-self-test?)
    (compiler-regalloc-scalar-self-test?)
    (compiler-regalloc-storage-self-test?)
    42))

(cfg
  test
  (test
    regalloc-call-span-census
    (test.assert-i64-eq
      (compiler-regalloc-self-test)
      42
      "regalloc call-span census fixture result")))