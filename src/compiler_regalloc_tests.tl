;; compiler_regalloc_tests.tl - Selfhost register-allocator fixtures split
;; from production.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_regalloc as reg)
(import compiler_profile_state as profile_state)
(import compiler_abi as cabi)
(import compiler_liveness as live)
(import compiler_liveness_tests as live_tests)
(import compiler_ir_types as ir)
(import compiler_ir_text as irt)
(import compiler_owned_view as owned_view)
(import compiler_parallel_move as pmove)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import stdlib.io)
(import stdlib.comptime)
(import stdlib.string)
(cfg test (import stdlib.profile))
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
    (ir.compiler-ir-instr-builder-push! (&mut builder) instr)
    (ir.compiler-ir-instr-builder-append-seq-range!
      (&mut builder)
      rest
      0
      rest.len)
    (ir.compiler-ir-instr-builder-to-seq builder)))

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
      (while (< case-index 9)
        (let
          [bits : i64 (compiler-reg-call-word-range-case case-index)]
          [base-index : i64 0]
          (while (< base-index 4)
            (let
              [base : i64 (compiler-reg-call-word-range-base base-index)]
              [start : i64 -2]
              (while (< start 34)
                (let
                  [end : i64 start]
                  (while (< end 42)
                    (if (=
                      (reg.compiler-reg-call-word-in-range? bits base start end)
                      (>
                        (compiler-reg-call-word-count-in-range
                          bits
                          base
                          start
                          end)
                        0))
                      unit
                      (set! ok false))
                    (set! end (+ end 1)))
                  (set! start (+ start 1))))
              (set! base-index (+ base-index 1))))
          (set! case-index (+ case-index 1))))
      ok)))

(define (compiler-reg-remat-defn-with-invariant-loads?
  [instr : ir.CompilerIrInstr]
  [allow-invariant-loads : bool]) : bool
  (match instr
    [(Mov _ value _)
      (reg.compiler-reg-remat-mov-value? value allow-invariant-loads)]
    [(Gep _ base offset _) (reg.compiler-reg-remat-gep? base offset)]
    [(Load _ src _) (reg.compiler-reg-remat-load? src allow-invariant-loads)]
    [_ false]))

(define (compiler-reg-remat-defn? [instr : ir.CompilerIrInstr]) : bool
  (compiler-reg-remat-defn-with-invariant-loads? instr false))

(define (compiler-reg-function-ref-counts [func : ir.CompilerIrFunction]) : (__tl_dyn-array
    i64)
  (match func
    [(Function _ _ _ vars blocks _)
      (let
        [counts : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
        (reg.compiler-reg-fill-i64-array (&mut counts) 0)
        (compiler-reg-ref-counts-blocks!
          (reg.compiler-reg-global-shared-view counts)
          blocks)
        counts)]))

(define (compiler-reg-function-spill-weights-remat
  [func : ir.CompilerIrFunction]
  [coalesce : (& coalesce reg.CompilerRegCoalesceMap)]) : (__tl_dyn-array i64)
  (match (reg.compiler-reg-global-shared-view func)
    [(Function _ _ _ vars blocks _)
      (let
        [counts : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
        [def-status : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
        [rebates : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
        [weights : (__tl_dyn-array i64)
          (reg.compiler-reg-function-block-weights
            (reg.compiler-reg-global-shared-view blocks))]
        [allow-invariant-loads : bool
          (reg.compiler-reg-remat-invariant-loads-ok? func)]
        (reg.compiler-reg-fill-i64-array (&mut counts) 0)
        (reg.compiler-reg-fill-i64-array (&mut def-status) 0)
        (reg.compiler-reg-fill-i64-array (&mut rebates) 0)
        (reg.compiler-reg-ref-counts-blocks-weighted-remat!
          (&mut counts)
          (&mut def-status)
          (&mut rebates)
          blocks
          weights
          0
          allow-invariant-loads)
        (reg.compiler-reg-remat-discount-single-def-spill-weights!
          (&mut counts)
          def-status
          coalesce)
        counts)]))

(define (compiler-reg-plan-function-avx2 [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
  (compiler-reg-plan-function-avx2-for-abi Linux func))

(cfg
  test
  (define (compiler-reg-early-exit-general-test-function) : ir.CompilerIrFunction
    (irt.func
      "function @early_exit_general(n=%0:i64, limit=%1:i64) -> i64 vars 5 {
       entry:
         %2 = le %0, 0 : i64
         branch %2, zero, guard_limit
       zero:
         return 0
       guard_limit:
         %3 = gt %0, %1 : i64
         branch %3, one, body
       one:
         return 1
       body:
         %4 = call work() : i64
         jump entry
       }")))

(cfg
  test
  (define (compiler-reg-early-exit-general-ok?) : bool
    (match (reg.compiler-reg-early-exit-shrinkwrap-function
      (compiler-reg-early-exit-general-test-function))
      [(Function _ params ret-ty _ blocks _)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [body : ir.CompilerIrInstrSeq
            (match (ir.compiler-ir-block-seq-ref seq 5)
              [(Block _ instrs) instrs])]
          (and
            (= (ir.compiler-ir-param-seq-count params) 2)
            (match ret-ty
              [(I64) true]
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
              [(Block label instrs)
                (and
                  (= label (ir.compiler-ir-label "entry"))
                  (match (ir.compiler-ir-instr-seq-ref instrs 1)
                    [(Branch _ yes no)
                      (and
                        (= yes (ir.compiler-ir-label "entry__shrinkwrap_bare0"))
                        (= no (ir.compiler-ir-label "guard_limit")))]
                    [_ false]))])
            (match (ir.compiler-ir-block-seq-ref seq 1)
              [(Block label instrs)
                (and
                  (= label (ir.compiler-ir-label "guard_limit"))
                  (match (ir.compiler-ir-instr-seq-ref instrs 1)
                    [(Branch _ yes no)
                      (and
                        (= yes (ir.compiler-ir-label "entry__shrinkwrap_bare1"))
                        (= no (ir.compiler-ir-label "entry__shrinkwrap_save")))]
                    [_ false]))])
            (match (ir.compiler-ir-instr-seq-ref body 1)
              [(Jump target)
                (= target (ir.compiler-ir-label "entry__shrinkwrap_framed"))]
              [_ false])
            (match (ir.compiler-ir-block-seq-ref seq 7)
              [(Block label _)
                (=
                  label
                  (ir.compiler-ir-label "guard_limit__shrinkwrap_framed"))])))])))

(cfg
  test
  (define (compiler-reg-early-exit-float-guard-test-function) : ir.CompilerIrFunction
    (irt.func
      "function @early_exit_float_guard(actual=%0:f64, expected=%1:f64) -> unit vars 4 {
       entry:
         %2 = eq %0, %1 : f64
         branch %2, equal, failure
       equal:
         return
       failure:
         %3 = call report_float_failure() : unit
         return
       }")))

(cfg
  test
  (define (compiler-reg-early-exit-float-guard-refused-ok?) : bool
    (match (reg.compiler-reg-early-exit-shrinkwrap-function
      (compiler-reg-early-exit-float-guard-test-function))
      [(Function _ _ _ _ blocks _)
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
    (irt.func
      "function @cold_call_split(map=%0:i64, key=%1:i64, value=%2:i64) -> i64 vars 6 {
       entry:
         branch false, cold, bypass
       cold:
         %3 = call grow() : unit
         jump join
       bypass:
         jump join
       join:
         %4 = add %0, %1 : i64
         %5 = add %4, %2 : i64
         jump loop
       loop:
         branch false, loop, exit
       exit:
         return %5
       }")))

(cfg
  test
  (define (compiler-reg-cold-call-test-mov?
    [instr : ir.CompilerIrInstr]
    [dst : i64]
    [src : i64]) : bool
    (match instr
      [(Mov found-dst (Var found-src) _)
        (and (= found-dst dst) (= found-src src))]
      [_ false])))

(cfg
  test
  (define (compiler-reg-cold-call-split-ok?) : bool
    (let
      [rewrite : reg.CompilerRegColdCallRewrite
        (compiler-reg-cold-call-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          (compiler-reg-cold-call-test-function))]
      [rewritten : ir.CompilerIrFunction
        (reg.compiler-reg-cold-call-rewrite-function-value
          (reg.compiler-reg-global-shared-view rewrite))]
      [temp-start : i64 (reg.compiler-reg-cold-call-rewrite-temp-start rewrite)]
      (match (ir.compiler-ir-global-shared-view rewritten)
        [(Function _ _ _ vars blocks _)
          (let
            [seq : ir.CompilerIrBlockSeq
              (live.compiler-live-ir-block-list-to-seq blocks)]
            [instrs : ir.CompilerIrInstrSeq
              (match (ir.compiler-ir-block-seq-ref seq 1)
                [(Block _ found) found])]
            [plan : reg.CompilerRegPlan
              (reg.compiler-reg-plan-function-scalar-cold-for-abi
                Linux
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
                [(Call _ _ _ _) true]
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
                [(Jump target) (= target (ir.compiler-ir-label "join"))]
                [_ false])
              (reg.compiler-reg-location-register?
                (match (reg.compiler-reg-global-shared-view plan)
                  [(Plan assignments _ _ _ _)
                    (reg.compiler-reg-assignment-lookup assignments 0)])
                cabi.compiler-reg-id-rdi)
              (reg.compiler-reg-location-register?
                (match (reg.compiler-reg-global-shared-view plan)
                  [(Plan assignments _ _ _ _)
                    (reg.compiler-reg-assignment-lookup assignments 1)])
                cabi.compiler-reg-id-rsi)
              (reg.compiler-reg-location-register?
                (match (reg.compiler-reg-global-shared-view plan)
                  [(Plan assignments _ _ _ _)
                    (reg.compiler-reg-assignment-lookup assignments 2)])
                cabi.compiler-reg-id-rdx)
              (compiler-reg-cold-call-carriers-stack? plan temp-start vars)))]))))

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
    (irt.func
      "function @call_hole_loop_shape() -> i64 vars 1 {
       entry:
         jump header
       header:
         branch false, body, exit
       body:
         branch false, latch, miss
       latch:
         jump header
       miss:
         return 1
       exit:
         return 0
       }")))

(cfg
  test
  (define (compiler-reg-call-hole-weights-ok?) : bool
    (match (compiler-reg-call-hole-loop-shape-function)
      [(Function _ _ _ _ blocks _)
        (let
          [weights : (__tl_dyn-array i64)
            (let
              [function-loop-depths
                (reg.compiler-reg-function-loop-depths blocks)]
              (reg.compiler-reg-call-hole-block-weights function-loop-depths))]
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

;; entry -> header -> body -> {left, right}; left -> join; right dispatches to
;; s0..s3 -> join; join -> header; header -> exit.
(cfg
  test
  (define (compiler-reg-block-weights-dispatch-loop-blocks) : ir.CompilerIrBlockList
    (irt.blocks
      "entry:
         jump header
       header:
         branch false, body, exit
       body:
         branch false, left, right
       left:
         jump join
       right:
         switch %0 base 3 [0:s0, 1:s1, 2:s2] default s3
       s0:
         jump join
       s1:
         jump join
       s2:
         jump join
       s3:
         jump join
       join:
         jump header
       exit:
         return 0")))

(cfg
  test
  (define (compiler-reg-block-weights-straight-blocks) : ir.CompilerIrBlockList
    (irt.blocks
      "entry:
         jump next
       next:
         jump last
       last:
         return 0")))

(cfg
  test
  (define (compiler-reg-block-weights-ok?) : bool
    (let
      [scale : i64 (reg.compiler-reg-block-frequency-scale)]
      [weights : (__tl_dyn-array i64)
        (reg.compiler-reg-function-block-weights
          (compiler-reg-block-weights-dispatch-loop-blocks))]
      [straight : (__tl_dyn-array i64)
        (reg.compiler-reg-function-block-weights
          (compiler-reg-block-weights-straight-blocks))]
      (and
        (= (array-length weights) 11)
        ;; entry: depth 0, the whole share
        (= (array-ref weights 0) scale)
        ;; header, body: one ladder step, the whole share
        (= (array-ref weights 1) (* 2 scale))
        (= (array-ref weights 2) (* 2 scale))
        ;; a two-way branch carries the whole share down both arms
        (= (array-ref weights 3) (* 2 scale))
        (= (array-ref weights 4) (* 2 scale))
        ;; the four-way dispatch splits it
        (= (array-ref weights 5) (/ scale 2))
        (= (array-ref weights 6) (/ scale 2))
        (= (array-ref weights 7) (/ scale 2))
        (= (array-ref weights 8) (/ scale 2))
        ;; the join: the arms add back up to the whole share
        (= (array-ref weights 9) (* 2 scale))
        ;; exit: outside the loop, and not in the header's in-loop fan-out
        (= (array-ref weights 10) scale)
        ;; a function with no dispatch weighs the ladder alone, everywhere
        (= (array-length straight) 3)
        (= (array-ref straight 0) 1)
        (= (array-ref straight 1) 1)
        (= (array-ref straight 2) 1)))))

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
    (irt.func
      "function @call_hole_cold_arm() -> i64 vars 3 {
       entry:
         branch false, cold, join
       cold:
         %0 = call f() : i64
         jump join
       join:
         jump header
       header:
         branch false, body, exit
       body:
         %1 = call g() : i64
         branch false, arm, latch
       arm:
         %2 = call h() : i64
         jump latch
       latch:
         jump header
       exit:
         return 0
       }")))

(cfg
  test
  (define (compiler-reg-call-hole-cold-arm-weight-ok?) : bool
    (match (compiler-reg-call-hole-cold-arm-function)
      [(Function self-name _ _ _ blocks _)
        (let
          [arms : reg.CompilerRegCallHoleWeights
            (let
              [type-segment-bases (ast.ast-node-pool-reader-type-segment-bases)]
              [seq (live.compiler-live-ir-block-list-to-seq blocks)]
              (reg.compiler-reg-call-hole-cold-arm-weights
                type-segment-bases
                self-name
                seq))]
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
    (irt.func
      "function @call_hole_bypass_loop() -> i64 vars 1 {
       entry:
         branch false, fast, slow
       fast:
         %0 = call bulk() : i64
         jump join
       slow:
         branch false, slow, join
       join:
         return 0
       }")))

(cfg
  test
  (define (compiler-reg-call-hole-bypass-loop-ok?) : bool
    (match (compiler-reg-call-hole-bypass-loop-function)
      [(Function self-name _ _ _ blocks _)
        (let
          [arms : reg.CompilerRegCallHoleWeights
            (let
              [type-segment-bases (ast.ast-node-pool-reader-type-segment-bases)]
              [seq (live.compiler-live-ir-block-list-to-seq blocks)]
              (reg.compiler-reg-call-hole-cold-arm-weights
                type-segment-bases
                self-name
                seq))]
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
    (irt.func
      "function @call_hole_loop_arm_bypass_loop() -> i64 vars 1 {
       entry:
         jump header
       header:
         branch false, body, exit
       body:
         branch false, fast, slow
       fast:
         %0 = call bulk() : i64
         jump join
       slow:
         branch false, slow, join
       join:
         jump latch
       latch:
         jump header
       exit:
         return 0
       }")))

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
      [(Function self-name _ _ _ blocks _)
        (let
          [arms : reg.CompilerRegCallHoleWeights
            (let
              [type-segment-bases (ast.ast-node-pool-reader-type-segment-bases)]
              [seq (live.compiler-live-ir-block-list-to-seq blocks)]
              (reg.compiler-reg-call-hole-cold-arm-weights
                type-segment-bases
                self-name
                seq))]
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
              (reg.compiler-reg-global-shared-view flags)
              (reg.compiler-reg-global-shared-view csr)
              dropped
              (reg.compiler-reg-global-shared-view benefit)
              (reg.compiler-reg-global-shared-view cost)
              (reg.compiler-reg-global-shared-view max-ref)
              (reg.compiler-reg-global-shared-view max-clobber)
              (reg.compiler-reg-global-shared-view max-clobber-hot)
              8)]
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
            (not (reg.compiler-reg-call-hole-qualifies? scores 1))))])))

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
          (reg.compiler-reg-global-shared-view flags)
          csr
          (reg.compiler-reg-global-shared-view dropped)
          (reg.compiler-reg-global-shared-view benefit)
          (reg.compiler-reg-global-shared-view cost)
          (reg.compiler-reg-global-shared-view max-ref)
          (reg.compiler-reg-global-shared-view max-clobber)
          max-clobber-hot
          8)]
      [first : i64 0]
      [after-drop : i64 0]
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
        (reg.compiler-reg-call-hole-select!
          vars
          scores
          (&mut picked)
          (&mut selected)))
      (set! (array-ref dropped 0) true)
      (set!
        after-drop
        (reg.compiler-reg-call-hole-select!
          vars
          scores
          (&mut picked)
          (&mut selected)))
      (and (= first 1) (= (array-ref selected 0) 0) (= after-drop 0)))))

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
          (reg.compiler-reg-global-shared-view flags)
          (reg.compiler-reg-global-shared-view csr)
          dropped
          (reg.compiler-reg-global-shared-view benefit)
          (reg.compiler-reg-global-shared-view cost)
          (reg.compiler-reg-global-shared-view max-ref)
          (reg.compiler-reg-global-shared-view max-clobber)
          (reg.compiler-reg-global-shared-view max-clobber-hot)
          8)]
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
        (not (reg.compiler-reg-call-hole-qualifies? scores 3))))))

;; --- E-1 carrier store and reload placement ---------------------------------
;; The single-block fixture: three calls and one spilled value `%0`. The first
;; crossing stores the carrier and the third stores it again because `%0` is
;; redefined in between; the second crossing's store is elided because the
;; carrier already holds the value on this path.
;;
;; The reload after `call f` is DEAD -- nothing reads `%0` before `call g`
;; restores it -- and the flow decides that for BOTH candidate classes, so the
;; run costs two stores and two reloads rather than two stores and three.
(cfg
  test
  (define (compiler-reg-call-hole-rewrite-function) : ir.CompilerIrFunction
    (irt.func
      "function @call_hole_rewrite() -> i64 vars 6 {
       entry:
         %0 = mov 7 : i64
         %1 = call f() : i64
         %2 = call g() : i64
         %3 = mul %0, %0 : i64
         %0 = mov 9 : i64
         %4 = call h() : i64
         %5 = add %3, %0 : i64
         return %5
       }")))

;; Run the rewrite over a whole function with `%0..%(selected-count-1)` carried,
;; building the flow the same way `compiler-reg-call-hole-split-round` does.
(cfg
  test
  (define (compiler-reg-call-hole-test-rewrite
    [func : ir.CompilerIrFunction]
    [selected : (__tl_dyn-array i64)]
    [selected-count : i64]) : ir.CompilerIrBlockSeq
    (match (reg.compiler-reg-global-shared-view func)
      [(Function _ _ _ vars blocks _)
        (let
          [width : i64 (+ vars selected-count)]
          [carrier : (__tl_dyn-array i64) (__tl_make-array i64 width)]
          [valid : (__tl_dyn-array bool) (__tl_make-array bool width)]
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [liveness : live.CompilerFunctionLiveness
            (live.compiler-live-analyze-function-edge-precise
              (reg.compiler-reg-global-shared-view func))]
          [index : i64 0]
          (reg.compiler-reg-fill-i64-array (&mut carrier) (- 0 1))
          (while (< index selected-count)
            (set! (array-ref carrier (array-ref selected index)) (+ vars index))
            (set! index (+ index 1)))
          (live.compiler-live-ir-block-list-to-seq
            (reg.compiler-reg-call-hole-rewrite-blocks
              (ast.ast-node-pool-reader-type-segment-bases)
              seq
              (reg.compiler-reg-global-shared-view liveness)
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
              (&mut valid))))])))

(cfg
  test
  (define (compiler-reg-call-hole-test-block
    [seq : ir.CompilerIrBlockSeq]
    [index : i64]) : ir.CompilerIrInstrSeq
    (match (ir.compiler-ir-block-seq-ref seq index)
      [(Block _ found) found])))

(cfg
  test
  (define (compiler-reg-call-hole-test-selection [var : i64]) : (__tl_dyn-array
      i64)
    (let
      [selected : (__tl_dyn-array i64) (__tl_make-array i64 1)]
      (set! (array-ref selected 0) var)
      selected)))

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
    (Function
      (ir.compiler-ir-test-symbol "call_hole_cross_block")
      (ir.compiler-ir-param-seq-empty)
      (I64)
      7
      (ir.compiler-ir-blocks
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-seq3
            (irt.instr "%0 = mov 7 : i64")
            (irt.instr "%1 = call f() : i64")
            (irt.instr "branch false, then, else")))
        (ir.compiler-ir-block
          (ir.compiler-ir-label "then")
          (ir.compiler-ir-instr-seq4
            (irt.instr "%2 = call g() : i64")
            (irt.instr "%6 = call k() : i64")
            (irt.instr "%3 = mul %0, %0 : i64")
            (irt.instr "return %3")))
        (ir.compiler-ir-block
          (ir.compiler-ir-label "else")
          (ir.compiler-ir-instr-seq3
            (irt.instr "%4 = call h() : i64")
            (irt.instr "%5 = add %0, %0 : i64")
            (irt.instr "return %5"))))
      Ordinary)))

(cfg
  test
  (define (compiler-reg-call-hole-cross-block-ok?) : bool
    (let
      [seq : ir.CompilerIrBlockSeq
        (compiler-reg-call-hole-test-rewrite
          (compiler-reg-call-hole-cross-block-function)
          (compiler-reg-call-hole-test-selection 0)
          1)]
      [entry : ir.CompilerIrInstrSeq
        (compiler-reg-call-hole-test-block
          (reg.compiler-reg-global-shared-view seq)
          0)]
      [then-block : ir.CompilerIrInstrSeq
        (compiler-reg-call-hole-test-block
          (reg.compiler-reg-global-shared-view seq)
          1)]
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
    (Function
      (ir.compiler-ir-test-symbol "call_hole_join")
      (ir.compiler-ir-param-seq-empty)
      (I64)
      4
      (ir.compiler-ir-blocks
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-seq1 (irt.instr "branch false, a, b")))
        (ir.compiler-ir-block
          (ir.compiler-ir-label "a")
          (ir.compiler-ir-instr-seq3
            (irt.instr "%0 = mov 7 : i64")
            (irt.instr "%1 = call f() : i64")
            (Jump (ir.compiler-ir-label "join"))))
        (ir.compiler-ir-block
          (ir.compiler-ir-label "b")
          (ir.compiler-ir-instr-seq2
            (irt.instr "%0 = mov 8 : i64")
            (Jump (ir.compiler-ir-label "join"))))
        (ir.compiler-ir-block
          (ir.compiler-ir-label "join")
          (ir.compiler-ir-instr-seq3
            (irt.instr "%2 = call g() : i64")
            (irt.instr "%3 = mul %0, %0 : i64")
            (irt.instr "return %3"))))
      Ordinary)))

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
        (compiler-reg-call-hole-test-block
          (reg.compiler-reg-global-shared-view seq)
          1)]
      [b-block : ir.CompilerIrInstrSeq
        (compiler-reg-call-hole-test-block
          (reg.compiler-reg-global-shared-view seq)
          2)]
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
    (Function
      (ir.compiler-ir-test-symbol "call_hole_redef")
      (ir.compiler-ir-param-seq-empty)
      (I64)
      5
      (ir.compiler-ir-blocks
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-seq3
            (irt.instr "%0 = mov 7 : i64")
            (irt.instr "%1 = call f() : i64")
            (Jump (ir.compiler-ir-label "next"))))
        (ir.compiler-ir-block
          (ir.compiler-ir-label "next")
          (ir.compiler-ir-instr-seq5
            (irt.instr "%3 = mul %0, %0 : i64")
            (irt.instr "%0 = mov 9 : i64")
            (irt.instr "%2 = call g() : i64")
            (irt.instr "%4 = add %3, %0 : i64")
            (irt.instr "return %4"))))
      Ordinary)))

(cfg
  test
  (define (compiler-reg-call-hole-redef-ok?) : bool
    (let
      [seq : ir.CompilerIrBlockSeq
        (compiler-reg-call-hole-test-rewrite
          (compiler-reg-call-hole-redef-function)
          (compiler-reg-call-hole-test-selection 0)
          1)]
      [entry : ir.CompilerIrInstrSeq
        (compiler-reg-call-hole-test-block
          (reg.compiler-reg-global-shared-view seq)
          0)]
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
      [(Function _ _ _ _ blocks _)
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
              (live.compiler-live-analyze-function-edge-precise
                (reg.compiler-reg-global-shared-view func))
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
      [(Branch _ _ _) true]
      [_ false])))

(cfg
  test
  (define (compiler-reg-call-hole-mov-const?
    [instr : ir.CompilerIrInstr]
    [dst : i64]) : bool
    (match instr
      [(Mov found-dst (I64 _) _) (= found-dst dst)]
      [_ false])))

(cfg
  test
  (define (compiler-reg-call-hole-call? [instr : ir.CompilerIrInstr]) : bool
    (match instr
      [(Call _ _ _ _) true]
      [_ false])))

(cfg
  test
  (define (compiler-reg-call-hole-binop?
    [instr : ir.CompilerIrInstr]
    [dst : i64]) : bool
    (match instr
      [(BinOp found-dst _ _ _ _) (= found-dst dst)]
      [_ false])))

(cfg
  test
  (define (compiler-reg-call-hole-return? [instr : ir.CompilerIrInstr]) : bool
    (match instr
      [(Return _) true]
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
        (Plan
          (reg.compiler-reg-assignments-prepend
            (reg.CompilerRegAssignment 0 (Register cabi.compiler-reg-id-r12))
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment
                1
                (Spill (reg.compiler-reg-stack-slot-offset 1)))
              (reg.compiler-reg-assignments-prepend
                (reg.CompilerRegAssignment
                  2
                  (Register cabi.compiler-reg-id-r13))
                (reg.compiler-reg-assignments-prepend
                  (reg.CompilerRegAssignment
                    3
                    (Register cabi.compiler-reg-id-rdi))
                  (reg.compiler-reg-assignment-table-empty)))))
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-empty)
          (reg.compiler-reg-var-types-empty)
          (reg.compiler-reg-call-split-empty))]
      [selected : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      [dropped : (__tl_dyn-array bool) (__tl_make-array bool 4)]
      [csr : (__tl_dyn-array bool) (__tl_make-array bool 4)]
      (set! (array-ref selected 0) 0)
      (set! (array-ref selected 1) 1)
      (set! (array-ref selected 2) 2)
      (set! (array-ref selected 3) 3)
      (set! (array-ref csr 2) true)
      (set! (array-ref csr 3) true)
      (and
        (=
          (reg.compiler-reg-call-hole-drop-unimproved!
            Linux
            plan
            csr
            selected
            4
            (&mut dropped))
          2)
        (not (array-ref dropped 0))
        (array-ref dropped 1)
        (array-ref dropped 2)
        (not (array-ref dropped 3))))))

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
    (irt.instrs
      "%1 = add %0, 1 : i64
       %2 = add %0, 2 : i64
       %3 = add %0, 3 : i64
       %4 = add %0, 4 : i64
       %5 = add %0, 5 : i64
       %6 = add %0, 6 : i64
       %7 = add %0, 7 : i64
       %8 = add %0, 8 : i64
       %9 = add %0, 9 : i64
       %10 = add %0, 10 : i64
       %11 = call call_hole_sink() : i64
       %12 = mov 0 : i64
       jump loop")))

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
      (while (< index count)
        ;; The value is the multiply's LHS: a spilled operand there is a
        ;; real reload, unlike an `add`'s RHS.
        (ir.compiler-ir-instr-builder-push!
          (&mut builder)
          (ir.CompilerIrInstr.BinOp
            (+ (+ count 4) index)
            (Mul)
            (Var (+ index 1))
            (Var counter)
            (compiler-reg-i64-ty)))
        (ir.compiler-ir-instr-builder-push!
          (&mut builder)
          (ir.CompilerIrInstr.BinOp
            acc
            (Add)
            (Var acc)
            (Var (+ (+ count 4) index))
            (compiler-reg-i64-ty)))
        (set! index (+ index 1)))
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (irt.instr "%12 = add %12, 1 : i64"))
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop")))
      (ir.compiler-ir-instr-builder-to-seq builder))))

(cfg
  test
  (define (compiler-reg-call-hole-round-function) : ir.CompilerIrFunction
    (let
      [count : i64 (compiler-reg-call-hole-round-values)]
      [acc : i64 (+ count 1)]
      [counter : i64 (+ count 2)]
      [cond-var : i64 (+ count 3)]
      (Function
        (ir.compiler-ir-test-symbol "call_hole_round")
        (irt.params "bound=%0:i64")
        (I64)
        (compiler-reg-call-hole-round-vars)
        (ir.compiler-ir-blocks-with-tail
          (irt.blocks "exit:
                   return %11")
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "entry")
            (compiler-reg-call-hole-round-entry))
          (irt.block
            "loop:
                 %13 = lt %12, %0 : i64
                 branch %13, body, exit")
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "body")
            (compiler-reg-call-hole-round-body)))
        Ordinary))))

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
      (while (< index count)
        (if (reg.compiler-reg-call-hole-register-homed? assignments (+ index 1))
          unit
          (set! total (+ total 1)))
        (set! index (+ index 1)))
      total)))

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
          Linux
          (reg.compiler-reg-global-shared-view func)
          (- 0 1))]
      [split : reg.CompilerRegCallHoleSplit
        (reg.compiler-reg-call-hole-split-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          Linux
          func
          type-info
          (reg.compiler-reg-global-shared-view plan)
          (- 0 1))]
      [split-vars : i64
        (reg.compiler-reg-call-hole-split-vars
          (reg.compiler-reg-global-shared-view split))]
      [split-plan : reg.CompilerRegPlan
        (reg.compiler-reg-call-hole-split-plan
          (reg.compiler-reg-global-shared-view split))]
      (and
        ;; the initial plan really did spill call-spanning values ...
        (> (compiler-reg-call-hole-spilled-value-count plan count) 0)
        ;; ... the round fired, minting one carrier per selection ...
        (> split-vars vars)
        (<= split-vars (+ vars count))
        ;; ... the carriers start at the old watermark and are the threshold ...
        (= (reg.compiler-reg-call-hole-split-temp-start split) vars)
        ;; ... every carrier is stack-homed, never a register ...
        (compiler-reg-cold-call-carriers-stack?
          (reg.compiler-reg-global-shared-view split-plan)
          vars
          split-vars)
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
      [func : ir.CompilerIrFunction (compiler-reg-call-free-loop-function)]
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [plan : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-cold-for-abi
          Linux
          (reg.compiler-reg-global-shared-view func)
          (- 0 1))]
      [split : reg.CompilerRegCallHoleSplit
        (reg.compiler-reg-call-hole-split-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          Linux
          (reg.compiler-reg-global-shared-view func)
          type-info
          plan
          (- 0 1))]
      (match func
        [(Function _ _ _ vars _ _)
          (and
            (=
              (reg.compiler-reg-call-hole-split-vars
                (reg.compiler-reg-global-shared-view split))
              vars)
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
    (irt.func
      "function @call_hole_csr(a=%0:i64, b=%1:i64, c=%2:i64) -> i64 vars 8 {
       entry:
         %3 = lt %0, %1 : i64
         branch %3, grow, hot
       grow:
         %4 = call f() : i64
         %5 = call g() : i64
         jump hot
       hot:
         %6 = add %0, %1 : i64
         %7 = add %6, %2 : i64
         return %7
       }")))

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
          Linux
          (reg.compiler-reg-global-shared-view func)
          (- 0 1))]
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-plan-assignments
          (reg.compiler-reg-global-shared-view plan))]
      [split : reg.CompilerRegCallHoleSplit
        (reg.compiler-reg-call-hole-split-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          Linux
          func
          type-info
          (reg.compiler-reg-global-shared-view plan)
          (- 0 1))]
      [split-vars : i64
        (reg.compiler-reg-call-hole-split-vars
          (reg.compiler-reg-global-shared-view split))]
      [split-plan : reg.CompilerRegPlan
        (reg.compiler-reg-call-hole-split-plan
          (reg.compiler-reg-global-shared-view split))]
      (and
        ;; The defect: no spill anywhere, but all three parameters homed in
        ;; callee-saved registers because they cross the cold arm's calls.
        (not (reg.compiler-reg-assignment-table-has-spill? assignments))
        (reg.compiler-reg-call-hole-csr-home? Linux assignments 0)
        (reg.compiler-reg-call-hole-csr-home? Linux assignments 1)
        (reg.compiler-reg-call-hole-csr-home? Linux assignments 2)
        (= (reg.compiler-reg-call-hole-plan-csr-count Linux 8 plan) 3)
        ;; One carrier per parameter, minted at the old watermark.
        (= split-vars 11)
        (= (reg.compiler-reg-call-hole-split-temp-start split) 8)
        (compiler-reg-cold-call-carriers-stack?
          (reg.compiler-reg-global-shared-view split-plan)
          8
          split-vars)
        ;; Every parameter is back in its incoming ABI register ...
        (compiler-reg-call-hole-plan-register?
          (reg.compiler-reg-global-shared-view split-plan)
          0
          cabi.compiler-reg-id-rdi)
        (compiler-reg-call-hole-plan-register?
          (reg.compiler-reg-global-shared-view split-plan)
          1
          cabi.compiler-reg-id-rsi)
        (compiler-reg-call-hole-plan-register?
          (reg.compiler-reg-global-shared-view split-plan)
          2
          cabi.compiler-reg-id-rdx)
        ;; ... so the prologue saves nothing at all.
        (=
          (reg.compiler-reg-call-hole-plan-csr-count
            Linux
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
      (ir.compiler-ir-blocks
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "hot")
          (compiler-reg-test-instr-seq-prepend
            (BinOp (+ arms 1) (Add) (Var 0) (I64 1) (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (Return (Some (Var (+ arms 1))))
              (ir.compiler-ir-instr-seq-empty)))))
      (ir.compiler-ir-blocks-with-tail
        (compiler-reg-call-hole-cold-arms-chain (+ index 1) arms callee)
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label (compiler-reg-call-hole-guard-label index))
          (compiler-reg-test-instr-seq-prepend
            (Branch
              (Bool false)
              (ir.compiler-ir-label
                (compiler-reg-call-hole-arm-label "cold" index))
              (ir.compiler-ir-label
                (compiler-reg-call-hole-join-label (+ index 1) arms)))
            (ir.compiler-ir-instr-seq-empty)))
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label (compiler-reg-call-hole-arm-label "cold" index))
          (compiler-reg-test-instr-seq-prepend
            (Call (+ index 1) callee (Nil) (compiler-reg-i64-ty))
            (compiler-reg-test-instr-seq-prepend
              (Jump
                (ir.compiler-ir-label
                  (compiler-reg-call-hole-join-label (+ index 1) arms)))
              (ir.compiler-ir-instr-seq-empty))))))))

(cfg
  test
  (define (compiler-reg-call-hole-cold-arms-function
    [arms : i64]
    [callee : i64]) : ir.CompilerIrFunction
    (Function
      (compiler-reg-call-hole-cold-arms-name)
      (irt.params "a=%0:i64")
      (I64)
      (+ arms 2)
      (compiler-reg-call-hole-cold-arms-chain 0 arms callee)
      Ordinary)))

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
          Linux
          (reg.compiler-reg-global-shared-view func)
          (- 0 1))]
      (reg.compiler-reg-call-hole-split-rewrite-function
        (ast.ast-node-pool-reader-type-segment-bases)
        Linux
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
        (=
          (reg.compiler-reg-call-hole-split-vars
            (reg.compiler-reg-global-shared-view three))
          6)
        (=
          (reg.compiler-reg-call-hole-split-temp-start
            (reg.compiler-reg-global-shared-view three))
          5)
        (compiler-reg-call-hole-plan-register?
          (reg.compiler-reg-call-hole-split-plan
            (reg.compiler-reg-global-shared-view three))
          0
          cabi.compiler-reg-id-rdi)
        (=
          (reg.compiler-reg-call-hole-plan-csr-count
            Linux
            6
            (reg.compiler-reg-call-hole-split-plan three))
          0)
        ;; 4 arms: the carriers now cost exactly what the pair costs, and the
        ;; rule is strictly-below, so nothing is selected and the round returns
        ;; its input untouched.
        (=
          (reg.compiler-reg-call-hole-split-vars
            (reg.compiler-reg-global-shared-view four))
          6)
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
      [(Function self-name _ _ _ blocks _)
        (let
          [type-segment-bases (ast.ast-node-pool-reader-type-segment-bases)]
          [seq (live.compiler-live-ir-block-list-to-seq blocks)]
          (reg.compiler-reg-call-hole-cold-arm-weights
            type-segment-bases
            self-name
            seq))])))

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
        (=
          (reg.compiler-reg-call-hole-split-vars
            (reg.compiler-reg-global-shared-view foreign-split))
          4)
        (=
          (reg.compiler-reg-call-hole-split-temp-start
            (reg.compiler-reg-global-shared-view foreign-split))
          3)
        (compiler-reg-call-hole-plan-register?
          (reg.compiler-reg-call-hole-split-plan foreign-split)
          0
          cabi.compiler-reg-id-rdi)
        ;; Recursive: nothing selected, input returned untouched.
        (=
          (reg.compiler-reg-call-hole-split-vars
            (reg.compiler-reg-global-shared-view recursive-split))
          3)
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
    (irt.func
      "function @loop_park_direct(bound=%0:i64) -> i64 vars 9 {
       entry:
         %1 = mov 100 : i64
         %2 = mov 200 : i64
         jump preheader
       preheader:
         %8 = mov 7 : i64
         jump header
       header:
         %3 = phi [%8, preheader], [%6, latch] : i64
         %5 = lt %3, %0 : i64
         branch %5, body, exit
       body:
         %4 = add %3, %2 : i64
         jump latch
       latch:
         %6 = add %3, 1 : i64
         jump header
       exit:
         %7 = add %1, %3 : i64
         return %7
       }")))

(cfg
  test
  (define (compiler-reg-loop-park-splice-function) : ir.CompilerIrFunction
    (irt.func
      "function @loop_park_splice(bound=%0:i64) -> i64 vars 11 {
       entry:
         %1 = mov 100 : i64
         %2 = mov 200 : i64
         %10 = lt %0, 5 : i64
         branch %10, preheader, other
       other:
         %8 = mov 9 : i64
         jump exit
       preheader:
         jump header
       header:
         %3 = phi [0, preheader], [%6, latch] : i64
         %5 = lt %3, %0 : i64
         branch %5, body, exit
       body:
         %4 = add %3, %2 : i64
         jump latch
       latch:
         %6 = add %3, 1 : i64
         branch %5, header, ret_blk
       ret_blk:
         return %4
       exit:
         %7 = phi [%3, header], [%8, other] : i64
         %9 = add %1, %7 : i64
         return %9
       }")))

(cfg
  test
  (define (compiler-reg-loop-park-block-index
    [seq : ir.CompilerIrBlockSeq]
    [name : String]) : i64
    (let
      [want : i64 (ir.compiler-ir-label name)]
      [count : i64 (ir.compiler-ir-block-seq-count seq)]
      [index : i64 0]
      (while (< index count)
        (when
          (= (reg.compiler-reg-loop-park-block-label seq index) want)
          (return index))
        (set! index (+ index 1)))
      (- 0 1))))

;; Loop structure and residency. The through value is the one the loop never
;; mentions; a value used in the loop, a value that is only a header-phi INPUT
;; there, and the loop's own phi result are all residents.
(cfg
  test
  (define (compiler-reg-loop-park-detect-ok?) : bool
    (match (compiler-reg-loop-park-direct-function)
      [(Function _ _ _ vars blocks _)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [count : i64 (ir.compiler-ir-block-seq-count seq)]
          [nest : reg.CompilerRegLoopNest
            (reg.compiler-reg-loop-nest-build-seq seq)]
          [header : i64
            (compiler-reg-loop-park-block-index
              (ir.compiler-ir-global-shared-view seq)
              "header")]
          [entry : i64
            (compiler-reg-loop-park-block-index
              (ir.compiler-ir-global-shared-view seq)
              "entry")]
          [pre : i64
            (compiler-reg-loop-park-block-index
              (ir.compiler-ir-global-shared-view seq)
              "preheader")]
          [total : i64
            (reg.compiler-reg-loop-nest-header-members! nest header 1)]
          [depths : (__tl_dyn-array i64) (__tl_make-array i64 count)]
          [weights : (__tl_dyn-array i64) (__tl_make-array i64 count)]
          [stamp : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [refs : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [residents : (__tl_dyn-array i64) (__tl_make-array i64 32)]
          [cursor : (__tl_dyn-array i64) (__tl_make-array i64 2)]
          [index : i64 0]
          (while (< index count)
            (set! (array-ref weights index) 1)
            (set! index (+ index 1)))
          (reg.compiler-reg-loop-park-mark-residents!
            seq
            nest
            header
            total
            1
            weights
            vars
            (&mut stamp)
            (&mut refs)
            (&mut residents)
            (&mut cursor))
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
            (> (array-ref cursor 1) 0)))])))

;; Through-value eligibility: a REGISTER home admits, a spill home declines (it
;; has no register to give up), a missing home declines, and the planner's
;; ineligible set declines even a register-homed value.
(cfg
  test
  (define (compiler-reg-loop-park-eligible-ok?) : bool
    (let
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignments-prepend
          (reg.CompilerRegAssignment 0 (Register cabi.compiler-reg-id-r12))
          (reg.compiler-reg-assignments-prepend
            (reg.CompilerRegAssignment
              1
              (Spill (reg.compiler-reg-stack-slot-offset 1)))
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment 3 (Register cabi.compiler-reg-id-r13))
              (reg.compiler-reg-assignment-table-empty))))]
      [type-info : reg.CompilerRegVarTypes
        (let
          [func (compiler-reg-loop-park-direct-function)]
          (reg.compiler-reg-function-var-types func))]
      [ineligible : live.CompilerLiveI64Set
        (live.compiler-live-set-insert (live.compiler-live-set-empty) 3)]
      [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
      (and
        (let
          [type-info-copy type-info]
          [assignments-copy assignments]
          [set-empty (live.compiler-live-set-empty)]
          (reg.compiler-reg-loop-park-through-eligible?
            bases
            type-info-copy
            assignments-copy
            set-empty
            0))
        (not
          (let
            [type-info-copy type-info]
            [assignments-copy assignments]
            [set-empty (live.compiler-live-set-empty)]
            (reg.compiler-reg-loop-park-through-eligible?
              bases
              type-info-copy
              assignments-copy
              set-empty
              1)))
        (not
          (let
            [type-info-copy type-info]
            [assignments-copy assignments]
            [set-empty (live.compiler-live-set-empty)]
            (reg.compiler-reg-loop-park-through-eligible?
              bases
              type-info-copy
              assignments-copy
              set-empty
              2)))
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
          (match (reg.compiler-reg-global-shared-view direct-func)
            [(Function _ _ _ _ blocks _) blocks]))]
      [splice-seq : ir.CompilerIrBlockSeq
        (live.compiler-live-ir-block-list-to-seq
          (match (reg.compiler-reg-global-shared-view splice-func)
            [(Function _ _ _ _ blocks _) blocks]))]
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
      [dh : i64
        (compiler-reg-loop-park-block-index
          (ir.compiler-ir-global-shared-view direct-seq)
          "header")]
      [de : i64
        (compiler-reg-loop-park-block-index
          (ir.compiler-ir-global-shared-view direct-seq)
          "exit")]
      [sh : i64
        (compiler-reg-loop-park-block-index
          (ir.compiler-ir-global-shared-view splice-seq)
          "header")]
      [sl : i64
        (compiler-reg-loop-park-block-index
          (ir.compiler-ir-global-shared-view splice-seq)
          "latch")]
      [se : i64
        (compiler-reg-loop-park-block-index
          (ir.compiler-ir-global-shared-view splice-seq)
          "exit")]
      [sr : i64
        (compiler-reg-loop-park-block-index
          (ir.compiler-ir-global-shared-view splice-seq)
          "ret_blk")]
      [direct-total : i64
        (reg.compiler-reg-loop-nest-header-members! direct-nest dh 1)]
      [direct-count : i64
        (reg.compiler-reg-loop-park-collect-sites!
          direct-seq
          direct-nest
          (reg.compiler-reg-global-shared-view direct-live)
          dh
          direct-total
          1
          weights
          (&mut from)
          (&mut to)
          (&mut kind)
          (&mut weight)
          (&mut scratch))]
      [direct-kind : i64 (array-ref kind 0)]
      [direct-to : i64 (array-ref to 0)]
      [splice-total : i64
        (reg.compiler-reg-loop-nest-header-members! splice-nest sh 1)]
      [splice-count : i64
        (reg.compiler-reg-loop-park-collect-sites!
          splice-seq
          splice-nest
          (reg.compiler-reg-global-shared-view splice-live)
          sh
          splice-total
          1
          weights
          (&mut from)
          (&mut to)
          (&mut kind)
          (&mut weight)
          (&mut scratch))]
      (and
        ;; one exit, served at the head of its target
        (= direct-count 1)
        (= direct-kind (reg.compiler-reg-loop-park-site-direct))
        (= direct-to de)
        ;; the through value is live at that target and the in-loop value is not
        (reg.compiler-reg-loop-park-needs-reload?
          direct-seq
          (reg.compiler-reg-global-shared-view direct-live)
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
          (reg.compiler-reg-global-shared-view splice-live)
          (reg.compiler-reg-loop-park-site-splice)
          sh
          se
          3)
        ;; nothing but the returned value is live into the Return block, so the
        ;; through value needs no reload there
        (not
          (reg.compiler-reg-loop-park-needs-reload?
            splice-seq
            (reg.compiler-reg-global-shared-view splice-live)
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

;; Which exit edges a splice may redirect. A switch's case entries sit in a jump
;; table the backend renders before this rewrite runs, so only a default edge
;; that no case shares may move; two-way branches and jumps always may.
(cfg
  test
  (define (compiler-reg-loop-park-redirectable-ok?) : bool
    (let
      [seq : ir.CompilerIrBlockSeq
        (live.compiler-live-ir-block-list-to-seq
          (irt.blocks
            "sw:
               switch %0 base 3 [0:s0, 1:s1, 2:s2] default s3
             shared:
               switch %0 base 2 [0:s0, 1:s3] default s3
             br:
               branch %0, s0, s1"))]
      (and
        ;; case edges are pinned by the jump table
        (not
          (reg.compiler-reg-loop-park-redirectable?
            seq
            0
            (ir.compiler-ir-label "s0")))
        (not
          (reg.compiler-reg-loop-park-redirectable?
            seq
            0
            (ir.compiler-ir-label "s2")))
        ;; the default edge is emitted from the rewritten IR
        (reg.compiler-reg-loop-park-redirectable?
          seq
          0
          (ir.compiler-ir-label "s3"))
        ;; unless a case names the same label
        (not
          (reg.compiler-reg-loop-park-redirectable?
            seq
            1
            (ir.compiler-ir-label "s3")))
        (reg.compiler-reg-loop-park-redirectable?
          seq
          2
          (ir.compiler-ir-label "s1"))))))

;; The rewrite shape, driven from a hand-built decision so the assertions are
;; about the emitter and not about the planner.
(cfg
  test
  (define (compiler-reg-loop-park-mov?
    [instr : ir.CompilerIrInstr]
    [dst : i64]
    [src : i64]) : bool
    (match instr
      [(Mov d value _)
        (and
          (= d dst)
          (match value
            [(Var v) (= v src)]
            [_ false]))]
      [_ false])))

(cfg
  test
  (define (compiler-reg-loop-park-phi-keyed-on?
    [instr : ir.CompilerIrInstr]
    [var : i64]
    [label : i64]) : bool
    (match instr
      [(Phi _ inputs _)
        (reg.compiler-reg-loop-park-phi-input-on-edge? inputs label var)]
      [_ false])))

(cfg
  test
  (define (compiler-reg-loop-park-branch-false [instr : ir.CompilerIrInstr]) : i64
    (match instr
      [(Branch _ _ f) f]
      [_ (- 0 1)])))

(cfg
  test
  (define (compiler-reg-loop-park-direct-rewrite-ok?) : bool
    (match (compiler-reg-loop-park-direct-function)
      [(Function _ _ _ vars blocks _)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [count : i64 (ir.compiler-ir-block-seq-count seq)]
          [type-info : reg.CompilerRegVarTypes
            (let
              [func (compiler-reg-loop-park-direct-function)]
              (reg.compiler-reg-function-var-types func))]
          [pre : i64
            (compiler-reg-loop-park-block-index
              (ir.compiler-ir-global-shared-view seq)
              "preheader")]
          [exit : i64
            (compiler-reg-loop-park-block-index
              (ir.compiler-ir-global-shared-view seq)
              "exit")]
          [pk : reg.CompilerRegLoopParkPlan
            (reg.compiler-reg-loop-park-plan-make count vars)]
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
                3))))])))

(cfg
  test
  (define (compiler-reg-loop-park-splice-rewrite-ok?) : bool
    (match (compiler-reg-loop-park-splice-function)
      [(Function _ _ _ vars blocks _)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [count : i64 (ir.compiler-ir-block-seq-count seq)]
          [type-info : reg.CompilerRegVarTypes
            (let
              [func (compiler-reg-loop-park-splice-function)]
              (reg.compiler-reg-function-var-types func))]
          [pre : i64
            (compiler-reg-loop-park-block-index
              (ir.compiler-ir-global-shared-view seq)
              "preheader")]
          [header : i64
            (compiler-reg-loop-park-block-index
              (ir.compiler-ir-global-shared-view seq)
              "header")]
          [exit : i64
            (compiler-reg-loop-park-block-index
              (ir.compiler-ir-global-shared-view seq)
              "exit")]
          [splice-label : i64
            (reg.compiler-reg-loop-park-splice-label seq header 0)]
          [pk : reg.CompilerRegLoopParkPlan
            (reg.compiler-reg-loop-park-plan-make count vars)]
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
                (ir.compiler-ir-global-shared-view out)
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
                (ir.compiler-ir-label "other")))))])))

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
        (Plan
          (reg.compiler-reg-assignments-prepend
            (reg.CompilerRegAssignment 2 (Register cabi.compiler-reg-id-r12))
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment
                4
                (Spill (reg.compiler-reg-stack-slot-offset 1)))
              (reg.compiler-reg-assignment-table-empty)))
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-empty)
          (reg.compiler-reg-var-types-empty)
          (reg.compiler-reg-call-split-empty))]
      [dropped : (__tl_dyn-array bool) (__tl_make-array bool 8)]
      (reg.compiler-reg-loop-park-plan-reset! pk)
      ;; loop 0 targets var 2, which the replan registerised; loop 1 targets
      ;; var 4, which it did not
      (set! (array-ref pk.resident-mask 2) 1)
      (set! (array-ref pk.resident-mask 4) 2)
      (set! (array-ref pk.loop-header 0) 3)
      (set! (array-ref pk.loop-header 1) 5)
      (set! (array-ref pk.counts 2) 2)
      (and
        (= (reg.compiler-reg-loop-park-drop-failed! pk plan 6 (&mut dropped)) 1)
        (not (array-ref dropped 3))
        (array-ref dropped 5)))))

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
        (Plan
          (reg.compiler-reg-assignments-prepend
            (reg.CompilerRegAssignment 1 (Register cabi.compiler-reg-id-r12))
            (reg.compiler-reg-assignments-prepend
              (reg.CompilerRegAssignment
                2
                (Spill (reg.compiler-reg-stack-slot-offset 1)))
              (reg.compiler-reg-assignment-table-empty)))
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-empty)
          (reg.compiler-reg-var-types-empty)
          (reg.compiler-reg-call-split-empty))]
      [split : reg.CompilerRegCallHoleSplit
        (reg.compiler-reg-loop-park-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          Linux
          (reg.compiler-reg-global-shared-view func)
          type-info
          plan
          (- 0 1)
          false)]
      (match func
        [(Function _ _ _ vars _ _)
          (and
            (=
              (reg.compiler-reg-call-hole-split-vars
                (reg.compiler-reg-global-shared-view split))
              (+ vars 1))
            (=
              (reg.compiler-reg-call-hole-split-temp-start
                (reg.compiler-reg-global-shared-view split))
              vars)
            (compiler-reg-cold-call-carriers-stack?
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
        (Plan
          (reg.compiler-reg-assignments-prepend
            (reg.CompilerRegAssignment 1 (Register cabi.compiler-reg-id-r12))
            (reg.compiler-reg-assignment-table-empty))
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-empty)
          (reg.compiler-reg-var-types-empty)
          (reg.compiler-reg-call-split-empty))]
      [split : reg.CompilerRegCallHoleSplit
        (reg.compiler-reg-loop-park-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          Linux
          (reg.compiler-reg-global-shared-view func)
          type-info
          plan
          (- 0 1)
          false)]
      (match func
        [(Function _ _ _ vars _ _)
          (and
            (=
              (reg.compiler-reg-call-hole-split-vars
                (reg.compiler-reg-global-shared-view split))
              vars)
            (= (reg.compiler-reg-call-hole-split-temp-start split) (- 0 1)))]))))

;; --- P12: the merged-kernel shape, and the two ladders that decide it --------
;; A hand-inlined kernel puts its hottest loop DEEP. `it-intern-slice` inlined
;; into its driver leaves the byte compare at loop depth 5, inside a depth-4
;; probe loop, inside the per-symbol / per-pass / per-round loops. Two frequency
;; ladders read that depth, and either one flattening at depth 4 decides that
;; loop against itself:
;;
;;   * P3c's parking cost model (`compiler-reg-loop-park-block-weight`). The
;;     round prices "park a value the loop never touches" as W(preheader) plus
;;     one W(exit) per live exit, against W(body) per reference an L-resident
;;     makes. On a ladder that flattens, a depth-5 body and a depth-4 boundary
;;     weigh the SAME, so the boundary costs at least twice one resident
;;     reference and `compiler-reg-loop-park-pair!` can never accept -- however
;;     hot the loop actually is.
;;
;;   * the greedy's spill weight (`compiler-reg-loop-depth-weight`). Flattened,
;;     a reference at depth 5 scores exactly as much as one at depth 4, so the
;;     byte loop's own base pointer ranks level with the hoisted Vec headers the
;;     loop never touches, and loses the tie on var id.
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
    (BinOp dst op lhs rhs (compiler-reg-i64-ty))))

;; entry: mint the three through values, then descend into the nest.
(cfg
  test
  (define (compiler-reg-park-nest-entry-block) : ir.CompilerIrBlock
    (irt.block
      "entry:
         %10 = mov 11 : i64
         %11 = mov 12 : i64
         %12 = mov 13 : i64
         jump pre.0")))

(cfg
  test
  (define (compiler-reg-park-nest-pre-block [level : i64]) : ir.CompilerIrBlock
    (Block
      (compiler-reg-park-nest-label "pre." level)
      (compiler-reg-test-instr-seq-prepend
        (Jump (compiler-reg-park-nest-label "hdr." level))
        (ir.compiler-ir-instr-seq-empty)))))

(cfg
  test
  (define (compiler-reg-park-nest-hdr-block [level : i64]) : ir.CompilerIrBlock
    (Block
      (compiler-reg-park-nest-label "hdr." level)
      (compiler-reg-test-instr-seq-prepend
        (Phi
          (compiler-reg-park-nest-ctr level)
          (ir.compiler-ir-phi-input-seq-prepend
            (I64 0)
            (compiler-reg-park-nest-label "pre." level)
            (ir.compiler-ir-phi-input-seq-prepend
              (Var (compiler-reg-park-nest-next level))
              (compiler-reg-park-nest-label "lat." level)
              (ir.compiler-ir-phi-input-seq-empty)))
          (compiler-reg-i64-ty))
        (compiler-reg-test-instr-seq-prepend
          (compiler-reg-park-nest-binop
            (compiler-reg-park-nest-cond level)
            (Lt)
            (Var (compiler-reg-park-nest-ctr level))
            (Var 0))
          (compiler-reg-test-instr-seq-prepend
            (Branch
              (Var (compiler-reg-park-nest-cond level))
              (compiler-reg-park-nest-label "body." level)
              (compiler-reg-park-nest-label "exit." level))
            (ir.compiler-ir-instr-seq-empty)))))))

;; The innermost level's body is where the two base pointers are computed: once
;; per entry into the inner loop, one level OUT from the references that read
;; them, which is the merged kernel's own shape.
(cfg
  test
  (define (compiler-reg-park-nest-body-block [level : i64] [levels : i64]) : ir.CompilerIrBlock
    (Block
      (compiler-reg-park-nest-label "body." level)
      (if (< level (- levels 1))
        (compiler-reg-test-instr-seq-prepend
          (Jump (compiler-reg-park-nest-label "pre." (+ level 1)))
          (ir.compiler-ir-instr-seq-empty))
        (compiler-reg-test-instr-seq-prepend
          (compiler-reg-park-nest-binop
            1
            (Add)
            (Var 0)
            (Var (compiler-reg-park-nest-ctr level)))
          (compiler-reg-test-instr-seq-prepend
            (compiler-reg-park-nest-binop
              2
              (Add)
              (Var (compiler-reg-park-nest-ctr level))
              (Var 0))
            (irt.instrs
              "%67 = add %10, %11 : i64
               %68 = add %67, %12 : i64
               jump land")))))))

(cfg
  test
  (define (compiler-reg-park-nest-lat-block [level : i64] [levels : i64]) : ir.CompilerIrBlock
    (Block
      (compiler-reg-park-nest-label "lat." level)
      (if (= level (- levels 1))
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%69 = add %66, %68 : i64")
          (compiler-reg-test-instr-seq-prepend
            (compiler-reg-park-nest-binop
              (compiler-reg-park-nest-next level)
              (Add)
              (Var (compiler-reg-park-nest-ctr level))
              (Var 69))
            (compiler-reg-test-instr-seq-prepend
              (Jump (compiler-reg-park-nest-label "hdr." level))
              (ir.compiler-ir-instr-seq-empty))))
        (compiler-reg-test-instr-seq-prepend
          (compiler-reg-park-nest-binop
            (compiler-reg-park-nest-next level)
            (Add)
            (Var (compiler-reg-park-nest-ctr level))
            (I64 1))
          (compiler-reg-test-instr-seq-prepend
            (Jump (compiler-reg-park-nest-label "hdr." level))
            (ir.compiler-ir-instr-seq-empty)))))))

;; The outermost exit is the only place the three through values are read, so
;; each of them is live across every loop of the nest and mentioned in none.
(cfg
  test
  (define (compiler-reg-park-nest-exit-block [level : i64]) : ir.CompilerIrBlock
    (Block
      (compiler-reg-park-nest-label "exit." level)
      (if (> level 0)
        (compiler-reg-test-instr-seq-prepend
          (Jump (compiler-reg-park-nest-label "lat." (- level 1)))
          (ir.compiler-ir-instr-seq-empty))
        (irt.instrs
          "%70 = add %10, %11 : i64
           %71 = add %70, %12 : i64
           return %71")))))

;; The rotated inner loop, in the versioner's `__bce_fast` form: `land` is the
;; rotate landing block and the loop's dedicated preheader, `ihdr` opens with
;; the induction phi, and the trip test lives at the bottom in `imerge`. Both
;; exits leave for a block that opens with a phi, so both are SPLICED sites.
(cfg
  test
  (define (compiler-reg-park-nest-land-block) : ir.CompilerIrBlock
    (irt.block "land:
         jump ihdr")))

(cfg
  test
  (define (compiler-reg-park-nest-ihdr-block) : ir.CompilerIrBlock
    (irt.block
      "ihdr:
         %60 = phi [0, land], [%64, imerge] : i64
         jump ibody")))

(cfg
  test
  (define (compiler-reg-park-nest-ibody-block) : ir.CompilerIrBlock
    (irt.block
      "ibody:
         %61 = add %1, %60 : i64
         %62 = add %2, %60 : i64
         %63 = lt %61, %62 : i64
         branch %63, imerge, iexit")))

(cfg
  test
  (define (compiler-reg-park-nest-imerge-block) : ir.CompilerIrBlock
    (irt.block
      "imerge:
         %64 = add %60, 1 : i64
         %65 = lt %64, %0 : i64
         branch %65, ihdr, iexit")))

(cfg
  test
  (define (compiler-reg-park-nest-iexit-block [levels : i64]) : ir.CompilerIrBlock
    (Block
      (ir.compiler-ir-label "iexit")
      (compiler-reg-test-instr-seq-prepend
        (irt.instr "%66 = phi [0, ibody], [1, imerge] : i64")
        (compiler-reg-test-instr-seq-prepend
          (Jump (compiler-reg-park-nest-label "lat." (- levels 1)))
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
      (set! (array-ref blocks write) (compiler-reg-park-nest-entry-block))
      (set! write (+ write 1))
      (while (< level levels)
        (set! (array-ref blocks write) (compiler-reg-park-nest-pre-block level))
        (set!
          (array-ref blocks (+ write 1))
          (compiler-reg-park-nest-hdr-block level))
        (set!
          (array-ref blocks (+ write 2))
          (compiler-reg-park-nest-body-block level levels))
        (set! write (+ write 3))
        (set! level (+ level 1)))
      (set! (array-ref blocks write) (compiler-reg-park-nest-land-block))
      (set! (array-ref blocks (+ write 1)) (compiler-reg-park-nest-ihdr-block))
      (set! (array-ref blocks (+ write 2)) (compiler-reg-park-nest-ibody-block))
      (set!
        (array-ref blocks (+ write 3))
        (compiler-reg-park-nest-imerge-block))
      (set!
        (array-ref blocks (+ write 4))
        (compiler-reg-park-nest-iexit-block levels))
      (set! write (+ write 5))
      (set! level (- levels 1))
      (while (>= level 0)
        (set!
          (array-ref blocks write)
          (compiler-reg-park-nest-lat-block level levels))
        (set!
          (array-ref blocks (+ write 1))
          (compiler-reg-park-nest-exit-block level))
        (set! write (+ write 2))
        (set! level (- level 1)))
      (Function
        (ir.compiler-ir-test-symbol "loop_park_deep_nest")
        (irt.params "bound=%0:i64")
        (I64)
        80
        (Array (ir.CompilerIrBlockSeq blocks write))
        Ordinary))))

;; Two small builders for a hand-written plan, so the fixture can say exactly
;; which values the greedy is imagined to have homed.
(cfg
  test
  (define (compiler-reg-park-nest-reg
    [var : i64]
    [id : i64]
    [rest : reg.CompilerRegAssignmentTable]) : reg.CompilerRegAssignmentTable
    (reg.compiler-reg-assignments-prepend
      (reg.CompilerRegAssignment var (Register id))
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
        (Spill (reg.compiler-reg-stack-slot-offset slot)))
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
    (Plan
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
      (reg.compiler-reg-call-split-empty))))

(cfg
  test
  (define (compiler-reg-loop-park-deep-nest-split [bases-homed : bool]) : reg.CompilerRegCallHoleSplit
    (let
      [func : ir.CompilerIrFunction (compiler-reg-loop-park-deep-nest-function)]
      (reg.compiler-reg-loop-park-rewrite-function
        (ast.ast-node-pool-reader-type-segment-bases)
        Linux
        (reg.compiler-reg-global-shared-view func)
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
        [(Function _ _ _ vars _ _)
          (and
            ;; one park per base: a parked value frees ONE register over the
            ;; loop and the loop has two operands that each need one
            (=
              (reg.compiler-reg-call-hole-split-vars
                (reg.compiler-reg-global-shared-view split))
              (+ vars 2))
            (=
              (reg.compiler-reg-call-hole-split-temp-start
                (reg.compiler-reg-global-shared-view split))
              vars)
            ;; every carrier is forced to the stack, so the boundary movs pay
            ;; for themselves inside the round's own estimate
            (compiler-reg-cold-call-carriers-stack?
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
        [(Function _ _ _ vars _ _)
          (and
            (=
              (reg.compiler-reg-call-hole-split-vars
                (reg.compiler-reg-global-shared-view split))
              vars)
            (= (reg.compiler-reg-call-hole-split-temp-start split) (- 0 1)))]))))

;; And the ranking side of the same fixture, read straight off the greedy's own
;; spill weights. Base pointer %1 has one reference INSIDE the inner loop plus
;; its definition one level out; %67 is a value the inner loop never touches
;; with two references at that outer level. Flattened at depth 4 the two score
;; identically, and an exact tie is broken by var id rather than by frequency.
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
    (irt.func
      "function @scavenge_segment_hole() -> i64 vars 4 {
       entry:
         %0 = mov 7 : i64
         %1 = mov %0 : i64
         jump middle
       middle:
         %2 = add %1, 1 : i64
         jump tail
       tail:
         %0 = mov 9 : i64
         %3 = add %0, %2 : i64
         return %3
       }")))

;; Rotated layout: entry -> body -> latch -> {body, exit}. Var 1 is READ in
;; `latch` (laid out second) and DEFINED in `body` (laid out third).
(cfg
  test
  (define (compiler-reg-scavenge-rotated-function) : ir.CompilerIrFunction
    (irt.func
      "function @scavenge_segment_rotated() -> i64 vars 3 {
       entry:
         jump body
       latch:
         %2 = lt %1, 10 : i64
         branch %2, body, exit
       body:
         %1 = mov 7 : i64
         jump latch
       exit:
         return %1
       }")))

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
        (live.compiler-live-analyze-function
          (reg.compiler-reg-global-shared-view func))]
      [hull-only : reg.CompilerRegIntervalIndex
        (reg.compiler-reg-interval-index-build
          (reg.compiler-reg-live-intervals
            (reg.compiler-reg-global-shared-view func)
            (reg.compiler-reg-global-shared-view liveness))
          4)]
      [unseeded : reg.CompilerRegIntervalSelection
        (reg.compiler-reg-live-interval-selection-with-live-in
          func
          liveness
          false)]
      [rotated : ir.CompilerIrFunction (compiler-reg-scavenge-rotated-function)]
      [rotated-liveness : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function
          (reg.compiler-reg-global-shared-view rotated))]
      [rotated-unseeded : reg.CompilerRegIntervalSelection
        (reg.compiler-reg-live-interval-selection-with-live-in
          (reg.compiler-reg-global-shared-view rotated)
          (reg.compiler-reg-global-shared-view rotated-liveness)
          false)]
      [rotated-seeded : reg.CompilerRegIntervalSelection
        (reg.compiler-reg-live-interval-selection rotated rotated-liveness)]
      (match unseeded
        [(Selection _ index)
          (match rotated-unseeded
            [(Selection _ rotated-index)
              (match rotated-seeded
                [(Selection _ rotated-seeded-index)
                  (and
                    ;; (1a) the coarse arrays are the hull builder's, unchanged
                    (compiler-reg-scavenge-hull-arrays-eq?
                      hull-only
                      (reg.compiler-reg-global-shared-view index)
                      4
                      0)
                    ;; (1b) var 0 is defined and consumed in `entry`, untouched
                    ;; in `middle`, then redefined and consumed in `tail`
                    (>=
                      (reg.compiler-reg-interval-seq-count
                        (reg.compiler-reg-global-array-element-shared-view
                          index.segments
                          0))
                      2)
                    ;; ... and the hole is real: `middle`'s two instructions sit
                    ;; at points 6 and 8, inside var 0's hull [0, 12]
                    (= (array-ref index.starts 0) 0)
                    (= (array-ref index.ends 0) 12)
                    (compiler-reg-scavenge-segments-cover?
                      (reg.compiler-reg-global-array-element-shared-view
                        index.segments
                        0)
                      0
                      0)
                    (compiler-reg-scavenge-segments-cover?
                      (reg.compiler-reg-global-array-element-shared-view
                        index.segments
                        0)
                      10
                      0)
                    (not
                      (compiler-reg-scavenge-segments-cover?
                        (reg.compiler-reg-global-array-element-shared-view
                          index.segments
                          0)
                        6
                        0))
                    (not
                      (compiler-reg-scavenge-segments-cover?
                        (reg.compiler-reg-global-array-element-shared-view
                          index.segments
                          0)
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
    (irt.func
      "function @param_registers(a=%0:i64, b=%1:i64, c=%2:i64) -> unit vars 3 {
       entry:
         store @pa, %0 : i64
         store @pb, %1 : i64
         store @pc, %2 : i64
         return
       }")))

(cfg
  test
  (define (compiler-reg-float-param-register-function) : ir.CompilerIrFunction
    (irt.func
      "function @float_param_registers(a=%0:f64, b=%1:f64, c=%2:f64) -> unit vars 3 {
       entry:
         store @fa, %0 : f64
         store @fb, %1 : f64
         store @fc, %2 : f64
         return
       }")))

(cfg
  test
  (define (compiler-reg-low-xmm-splat-boundary-function) : ir.CompilerIrFunction
    (irt.func
      "function @low_xmm_splat_boundary(value=%0:f64) -> unit vars 2 {
       entry:
         %1 = splat 7 lanes 4 : i64
         store @low_xmm_splat_sink, %0 : f64
         return
       }")))

(cfg
  test
  (define (compiler-reg-low-xmm-vector-clobber-function) : ir.CompilerIrFunction
    (Function
      (ir.compiler-ir-test-symbol "low_xmm_vector_clobber")
      (irt.params "value=%0:f64")
      (Unit)
      4
      (ir.compiler-ir-blocks
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "%1 = splat 3 lanes 4 : i64")
            (compiler-reg-test-instr-seq-prepend
              (irt.instr "%2 = splat 5 lanes 4 : i64")
              (compiler-reg-test-instr-seq-prepend
                (ir.ir-instr-vector-bin-op 3 (Mul) (Var 1) (Var 2) 4 (I64))
                (irt.instrs
                  "store @low_xmm_vector_sink, %0 : f64
                   return"))))))
      Ordinary)))

(cfg
  test
  (define (compiler-reg-low-xmm-vector-boundaries-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar
      (compiler-reg-low-xmm-splat-boundary-function))
      [(Plan splat-assignments _ _ _ _)
        (match (reg.compiler-reg-plan-function-scalar
          (compiler-reg-low-xmm-vector-clobber-function))
          [(Plan clobber-assignments _ _ _ _)
            (and
              (not
                (compiler-reg-location-any-register?
                  (reg.compiler-reg-assignment-lookup splat-assignments 0)))
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
    (irt.func
      "function @mixed_float_call_args(i=%0:i64, a=%1:f64, b=%2:f64, c=%3:f64) -> unit vars 5 {
       entry:
         %4 = call mixed_float_callee(%0, %1, %2, %3) : unit
         return
       }")))

(cfg
  test
  (define (compiler-reg-win64-rsi-rdi-pressure-function) : ir.CompilerIrFunction
    (irt.func
      "function @win64_rsi_rdi_pressure(p0=%0:i64, p1=%1:i64, p2=%2:i64, p3=%3:i64, p4=%4:i64, p5=%5:i64, p6=%6:i64) -> unit vars 8 {
       entry:
         %7 = call side_effect() : unit
         store @g, %0 : i64
         store @g, %1 : i64
         store @g, %2 : i64
         store @g, %3 : i64
         store @g, %4 : i64
         store @g, %5 : i64
         store @g, %6 : i64
         return
       }")))

(cfg
  test
  (define (compiler-reg-zero-call-param-conflict-function) : ir.CompilerIrFunction
    (irt.func
      "function @zero_call_param_conflict(a=%0:i64, b=%1:i64, c=%2:i64, d=%3:i64, e=%4:i64, f=%5:i64) -> unit vars 13 {
       entry:
         %6 = mov 6 : i64
         %7 = mov 7 : i64
         %8 = mov 8 : i64
         %9 = mov 9 : i64
         %10 = mov 10 : i64
         %11 = mov 11 : i64
         %12 = mov 12 : i64
         store @g6, %6 : i64
         store @g7, %7 : i64
         store @g8, %8 : i64
         store @g9, %9 : i64
         store @g10, %10 : i64
         store @g11, %11 : i64
         store @g12, %12 : i64
         store @p5, %5 : i64
         return
       }")))

(cfg
  test
  (define (compiler-reg-param-clobber-function) : ir.CompilerIrFunction
    (irt.func
      "function @param_clobber(arg=%0:i64) -> i64 vars 2 {
       entry:
         %1 = call side_effect() : unit
         return %0
       }")))

(cfg
  test
  (define (compiler-reg-param-aggregate-function) : ir.CompilerIrFunction
    (let
      [ty : ast.AstType (Struct (ci.intern "ParamAggregate"))]
      (Function
        (ir.compiler-ir-test-symbol "param_aggregate")
        (ir.compiler-ir-param-seq-prepend
          (Param "state" (ast.ast-global-shared-view ty) 0)
          (ir.compiler-ir-param-seq-empty))
        (Unit)
        2
        (irt.blocks
          "entry:
             %1 = mov %0 : ParamAggregate
             return")
        Ordinary))))

(cfg
  test
  ;; GAP3a: zero-call function whose only would-be clobber is a shift by an
  ;; in-range CONSTANT (emitted as `shrq $3` -- no %rcx/%cl use). Params keep
  ;; their ABI pins.
  (define (compiler-reg-param-const-shift-function) : ir.CompilerIrFunction
    (irt.func
      "function @param_const_shift(a=%0:i64, n=%1:i64) -> i64 vars 3 {
       entry:
         %2 = shr %0, 3 : i64
         %2 = add %2, %1 : i64
         return %2
       }")))

(cfg
  test
  ;; GAP3a counterpart: a VARIABLE-count shift stays a clobber point (the
  ;; backend moves the count into %rcx and shifts by %cl). `a` (var 0) is live
  ;; across the shift: t = a >> n; return t + a.
  (define (compiler-reg-param-var-shift-function) : ir.CompilerIrFunction
    (irt.func
      "function @param_var_shift(a=%0:i64, n=%1:i64) -> i64 vars 3 {
       entry:
         %2 = shr %0, %1 : i64
         %2 = add %2, %0 : i64
         return %2
       }")))

(cfg
  test
  ;; GAP3a: constant in-range shifts are not clobber points, so the pin gate
  ;; sees a clobber-free function and both params keep their incoming ABI
  ;; registers (%rdi/%rsi) -- the crc_update shape.
  (define (compiler-reg-scalar-param-const-shift-pin-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-param-const-shift-function))
      [(Plan assignments ineligible _ _ _)
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
      Linux
      (compiler-reg-param-var-shift-function))
      [(Plan assignments ineligible _ _ _)
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
    (irt.func
      "function @param_dead_before_call(a=%0:i64) -> i64 vars 4 {
       entry:
         %1 = add %0, %0 : i64
         %2 = call side_effect() : unit
         %3 = add %1, %1 : i64
         return %3
       }")))

(cfg
  test
  (define (compiler-reg-scalar-param-dead-before-call-pin-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-param-dead-before-call-function))
      [(Plan assignments ineligible _ _ _)
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
  ;; it (last use point 4) -- must NOT keep its pin, while v0 (%rdi, ends
  ;; point 0) and v1 (%rsi, the divisor, last-used AT the div = read before
  ;; the clobber) keep theirs.
  ;; R3S-1: the demoted v2 does not fall to a callee-saved home. It is the
  ;; LAST parameter, so its entry copy is the last one emitted and no schedule
  ;; constraint applies; it spans no CALL, so it is not csr-only; and it spans
  ;; the div, so `forbidden` still excludes exactly {%rax,%rdx}. First free in
  ;; pool order past those, with %rsi/%rdi held by the two kept pins, is %r9 --
  ;; a caller-saved home in a function with no call, so no CSR push/pop.
  (define (compiler-reg-param-rdx-div-span-function) : ir.CompilerIrFunction
    (irt.func
      "function @param_rdx_div_span(a=%0:i64, b=%1:i64, c=%2:i64) -> i64 vars 6 {
       entry:
         %3 = add %0, %0 : i64
         %4 = div %3, %1 : i64
         %5 = add %4, %2 : i64
         return %5
       }")))

(cfg
  test
  (define (compiler-reg-scalar-param-rdx-div-span-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-param-rdx-div-span-function))
      [(Plan assignments ineligible _ _ _)
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
            cabi.compiler-reg-id-r9))])))

(cfg
  test
  ;; GAP3c per-register narrowing, shift: v4 = v0 + v0; v5 = v4 << v1;
  ;; v6 = v5 + v2; v7 = v6 + v3; return v7. The variable shift (point 2)
  ;; hardwires only %rcx, so the %rcx param v3 -- live across it (last use
  ;; point 6) -- must NOT keep its pin, while v2 (%rdx) ALSO spans the shift
  ;; and keeps its pin (%rdx is not shift-clobbered), and v0/v1 end at/before
  ;; the shift and keep theirs.
  ;; R3S-1: the demoted v3 lands in the caller-saved %r9 rather than a
  ;; callee-saved home. It is the last of four parameters, so no later entry
  ;; copy can read the register it is given; it spans no call; and the shift
  ;; narrowing still forbids exactly %rcx.
  (define (compiler-reg-param-rcx-shift-span-function) : ir.CompilerIrFunction
    (irt.func
      "function @param_rcx_shift_span(a=%0:i64, n=%1:i64, c=%2:i64, d=%3:i64) -> i64 vars 8 {
       entry:
         %4 = add %0, %0 : i64
         %5 = shl %4, %1 : i64
         %6 = add %5, %2 : i64
         %7 = add %6, %3 : i64
         return %7
       }")))

(cfg
  test
  (define (compiler-reg-scalar-param-rcx-shift-span-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-param-rcx-shift-span-function))
      [(Plan assignments ineligible _ _ _)
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
            cabi.compiler-reg-id-r9))])))

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
    (irt.func
      "function @param_pin_coalesce_demote(a=%0:i64) -> unit vars 4 {
       entry:
         %3 = add %0, %0 : i64
         %1 = mov %0 : i64
         %2 = call side_effect() : unit
         store @g, %1 : i64
         return
       }")))

(cfg
  test
  (define (compiler-reg-scalar-param-pin-coalesce-demote-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-param-pin-coalesce-demote-function))
      [(Plan assignments _ _ _ _)
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
      (compiler-reg-function-phi-touched-safe
        (ir.compiler-ir-global-shared-view loop-first)
        (live.compiler-live-analyze-function-edge-precise
          (ir.compiler-ir-global-shared-view loop-first)))]
    [exit-first-mask : (__tl_dyn-array i64)
      (compiler-reg-function-phi-touched-safe
        (ir.compiler-ir-global-shared-view exit-first)
        (live.compiler-live-analyze-function-edge-precise exit-first))]
    [fixed-register-mask : (__tl_dyn-array i64)
      (reg.compiler-reg-function-phi-touched-safe-mode
        (ir.compiler-ir-global-shared-view loop-first)
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
    Linux
    (compiler-reg-self-loop-exit-live-phi-function true))
    [(Plan assignments _ _ _ _)
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
      (compiler-reg-function-phi-touched-safe
        (owned_view.compiler-owned-shared-view exit-read)
        (live.compiler-live-analyze-function-edge-precise
          (owned_view.compiler-owned-shared-view exit-read)))]
    [late-read-mask : (__tl_dyn-array i64)
      (compiler-reg-function-phi-touched-safe
        (owned_view.compiler-owned-shared-view late-read)
        (live.compiler-live-analyze-function-edge-precise
          (owned_view.compiler-owned-shared-view late-read)))]
    (and
      (= (array-ref exit-read-mask 0) 0)
      (= (array-ref exit-read-mask 1) 0)
      (= (array-ref late-read-mask 0) 0)
      (= (array-ref late-read-mask 1) 0)
      (match (reg.compiler-reg-plan-function-scalar-for-abi Linux exit-read)
        [(Plan assignments _ _ _ _)
          (compiler-reg-different-location? assignments 0 1)])
      (match (reg.compiler-reg-plan-function-scalar-for-abi Linux late-read)
        [(Plan assignments _ _ _ _)
          (compiler-reg-different-location? assignments 0 1)]))))

(cfg
  test
  (define (compiler-reg-indirect-call-arg-prefs-ok?) : bool
    (let
      [pool : reg.CompilerRegIdSeq
        (reg.compiler-reg-greedy-integer-pool-for-abi Linux)]
      [prefs : (__tl_dyn-array i64)
        (let
          [indirect-call-arg-function (compiler-reg-indirect-call-arg-function)]
          [test-identity-coalesce (compiler-reg-test-identity-coalesce 4)]
          (reg.compiler-reg-function-arg-prefs
            Linux
            indirect-call-arg-function
            test-identity-coalesce
            4))]
      (and
        (= (array-ref prefs 0) -1)
        (=
          (array-ref prefs 1)
          (reg.compiler-reg-id-seq-index-of
            (reg.compiler-reg-global-shared-view pool)
            cabi.compiler-reg-id-rsi
            0))
        (=
          (array-ref prefs 2)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rdx 0))))))

(cfg
  test
  (define (compiler-reg-scalar-linux-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-param-register-function))
      [(Plan assignments ineligible _ _ _)
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
  ;; WIN1: R3S-1's entry-copy schedule constraint is answered EMPTY for every
  ;; non-Linux ABI (compiler-reg-param-entry-forbidden), so a Windows parameter
  ;; class stays callee-saved-only.
  ;; The companion test below pins that refusal directly.
  (define (compiler-reg-scalar-windows-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Windows
      (compiler-reg-param-register-function))
      [(Plan assignments ineligible _ _ _)
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
  (define (compiler-reg-entry-forbidden-i64-params-7) : ir.CompilerIrParamSeq
    (irt.params
      "p0=%0:i64, p1=%1:i64, p2=%2:i64, p3=%3:i64, p4=%4:i64, p5=%5:i64, p6=%6:i64")))

(cfg
  test
  (define (compiler-reg-entry-forbidden-float-params-3) : ir.CompilerIrParamSeq
    (irt.params "p0=%0:f64, p1=%1:i64, p2=%2:i64")))

(cfg
  test
  (define (compiler-reg-entry-forbidden-rows
    [n : i64]
    [params : ir.CompilerIrParamSeq]) : (__tl_dyn-array reg.CompilerRegIdSeq)
    (let
      [coalesce : reg.CompilerRegCoalesceMap
        (compiler-reg-test-identity-coalesce n)]
      (reg.compiler-reg-param-entry-forbidden
        (ast.ast-node-pool-reader-type-segment-bases)
        (ir.compiler-ir-representation-index-empty)
        Linux
        params
        coalesce.parents
        n))))

(cfg
  test
  (define (compiler-reg-entry-forbidden-row-has?
    [rows : (__tl_dyn-array reg.CompilerRegIdSeq)]
    [row : i64]
    [want : i64]) : bool
    (reg.compiler-reg-id-seq-contains?
      (reg.compiler-reg-global-array-element-shared-view rows row)
      want)))

(cfg
  test
  ;; R3S-1: the entry-copy schedule constraint itself. Seven i64 parameters on
  ;; SysV: positions 0-5 arrive in %rdi/%rsi/%rdx/%rcx/%r8/%r9 and position 6 on
  ;; the stack. The backend emits the entry copies in position order, so the row
  ;; for position p must be exactly the incoming registers of the positions
  ;; AFTER p -- never its own (a self-move is what an ABI pin is), never an
  ;; earlier one (already copied out of), and nothing at all once no
  ;; register-passed parameter follows.
  (define (compiler-reg-param-entry-forbidden-ok?) : bool
    (let
      [rows : (__tl_dyn-array reg.CompilerRegIdSeq)
        (compiler-reg-entry-forbidden-rows
          7
          (compiler-reg-entry-forbidden-i64-params-7))]
      (and
        (= (array-length rows) 7)
        (not
          (compiler-reg-entry-forbidden-row-has?
            (reg.compiler-reg-global-shared-view rows)
            0
            cabi.compiler-reg-id-rdi))
        (compiler-reg-entry-forbidden-row-has?
          (reg.compiler-reg-global-shared-view rows)
          0
          cabi.compiler-reg-id-rsi)
        (compiler-reg-entry-forbidden-row-has?
          (reg.compiler-reg-global-shared-view rows)
          0
          cabi.compiler-reg-id-r8)
        (compiler-reg-entry-forbidden-row-has?
          (reg.compiler-reg-global-shared-view rows)
          0
          cabi.compiler-reg-id-r9)
        ;; position 4 (%r8 -- the one register position the pin walk never
        ;; pins, so the one the greedy always sees): only the single later
        ;; incoming register %r9 is out of reach.
        (compiler-reg-entry-forbidden-row-has?
          (reg.compiler-reg-global-shared-view rows)
          4
          cabi.compiler-reg-id-r9)
        (not
          (compiler-reg-entry-forbidden-row-has?
            (reg.compiler-reg-global-shared-view rows)
            4
            cabi.compiler-reg-id-r8))
        (not
          (compiler-reg-entry-forbidden-row-has?
            (reg.compiler-reg-global-shared-view rows)
            4
            cabi.compiler-reg-id-rdi))
        (not
          (compiler-reg-entry-forbidden-row-has?
            (reg.compiler-reg-global-shared-view rows)
            4
            cabi.compiler-reg-id-rcx))
        ;; position 5 is the last register-passed parameter; position 6 is
        ;; stack-passed. No entry copy reads a register after either.
        (not
          (compiler-reg-entry-forbidden-row-has?
            (reg.compiler-reg-global-shared-view rows)
            5
            cabi.compiler-reg-id-r9))
        (not
          (compiler-reg-entry-forbidden-row-has?
            (reg.compiler-reg-global-shared-view rows)
            5
            cabi.compiler-reg-id-rdi))
        (not
          (compiler-reg-entry-forbidden-row-has? rows 6 cabi.compiler-reg-id-r9))))))

(cfg
  test
  ;; WIN1: the entry-copy schedule constraint is Linux-only. The SAME seven i64
  ;; parameters that produce a full constraint on SysV must answer the legacy
  ;; EMPTY array on Win64, so alloc-one! keeps every Windows parameter class
  ;; callee-saved-only and Windows codegen is byte-identical to the compiler
  ;; before the constraint existed.
  (define (compiler-reg-param-entry-forbidden-refuses-windows-ok?) : bool
    (let
      [coalesce : reg.CompilerRegCoalesceMap
        (compiler-reg-test-identity-coalesce 7)]
      (and
        (=
          (array-length
            (reg.compiler-reg-param-entry-forbidden
              (ast.ast-node-pool-reader-type-segment-bases)
              (ir.compiler-ir-representation-index-empty)
              Windows
              (compiler-reg-entry-forbidden-i64-params-7)
              coalesce.parents
              7))
          0)
        (>
          (array-length
            (compiler-reg-entry-forbidden-rows
              7
              (compiler-reg-entry-forbidden-i64-params-7)))
          0)))))

(cfg
  test
  ;; R3S-1 fail-closed shape gate: a float parameter makes the position -> ABI
  ;; index map depend on two-bank bookkeeping this constraint does not carry, so
  ;; the builder answers an EMPTY array and alloc-one! keeps the legacy
  ;; callee-saved-only parameter rule for the whole function.
  (define (compiler-reg-param-entry-forbidden-refuses-float-ok?) : bool
    (=
      (array-length
        (compiler-reg-entry-forbidden-rows
          3
          (compiler-reg-entry-forbidden-float-params-3)))
      0)))

(cfg
  test
  ;; FLT-1: an internal by-memory ABI transport parameter -- what
  ;; lower-internal-transport-type emits for a >16-byte by-value Tuple/Array.
  ;; It arrives in the incoming STACK area and advances NEITHER argument bank,
  ;; yet it is a nominal Struct: register-eligible, not a register group, so it
  ;; satisfied every test compiler-reg-integer-param-type? makes.
  (define (compiler-reg-entry-forbidden-memory-params-3) : ir.CompilerIrParamSeq
    (ir.compiler-ir-param-seq-prepend
      (Param
        "pm"
        (Struct (ir.compiler-ir-symbol "__tl_internal_abi_mem_s24__flt_probe"))
        0)
      (ir.compiler-ir-param-seq-prepend
        (Param "p1" (compiler-reg-i64-ty) 1)
        (ir.compiler-ir-param-seq-prepend
          (Param "p2" (compiler-reg-i64-ty) 2)
          (ir.compiler-ir-param-seq-empty))))))

(cfg
  test
  ;; FLT-1 fail-closed shape gate, the by-memory half: a transport that passed
  ;; the gate would make both this constraint and the pin walk shift every
  ;; LATER position's ABI index by one -- a wrong-code bug, not a missed
  ;; optimisation (see compiler-reg-param-assign-walk's note and
  ;; tests/integration/param_memory_transport_abi.tl). The builder must answer
  ;; an EMPTY array so the whole function keeps the legacy rule. The seven-i64
  ;; positive case above is what pins that the refusal is not over-broad.
  (define (compiler-reg-param-entry-forbidden-refuses-memory-ok?) : bool
    (=
      (array-length
        (compiler-reg-entry-forbidden-rows
          3
          (compiler-reg-entry-forbidden-memory-params-3)))
      0)))

(cfg
  test
  (define (compiler-reg-scalar-float-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-float-param-register-function))
      [(Plan assignments ineligible _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (and
            (not
              (compiler-reg-location-any-register?
                (reg.compiler-reg-assignment-lookup assignments 0)))
            (not
              (compiler-reg-location-any-register?
                (reg.compiler-reg-assignment-lookup assignments 1))))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            (cabi.compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-win64-float-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Windows
      (compiler-reg-float-param-register-function))
      [(Plan assignments ineligible _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            (cabi.compiler-abi-xmm-register-id 6))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            (cabi.compiler-abi-xmm-register-id 7))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            (cabi.compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-mixed-float-call-args-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-mixed-float-call-arg-function))
      [(Plan assignments ineligible _ _ _)
        (and
          (live.compiler-live-set-contains? ineligible 0)
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (not (live.compiler-live-set-contains? ineligible 3))
          (compiler-reg-unassigned? assignments 0)
          (and
            (compiler-reg-unassigned? assignments 1)
            (compiler-reg-unassigned? assignments 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 3)
            (cabi.compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-win64-mixed-float-call-args-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Windows
      (compiler-reg-mixed-float-call-arg-function))
      [(Plan assignments ineligible _ _ _)
        (and
          (live.compiler-live-set-contains? ineligible 0)
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (not (live.compiler-live-set-contains? ineligible 3))
          (compiler-reg-unassigned? assignments 0)
          (compiler-reg-unassigned? assignments 1)
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
      Windows
      (compiler-reg-win64-rsi-rdi-pressure-function))
      [(Plan assignments ineligible _ _ _)
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
      (reg.compiler-reg-coalesce-map-init! (&mut parents) (&mut sizes) 0)
      (reg.CompilerRegCoalesceMap parents))))

(cfg
  test
  (define (compiler-reg-win64-arg-result-pref-function) : ir.CompilerIrFunction
    (irt.func
      "function @win64_arg_result_pref() -> i64 vars 6 {
       entry:
         %5 = call callee(%0, %1, %2, %3, %4) : i64
         return %5
       }")))

(cfg
  test
  (define (compiler-reg-win64-arg-result-prefs-ok?) : bool
    (let
      [pool : reg.CompilerRegIdSeq
        (reg.compiler-reg-greedy-integer-pool-for-abi Windows)]
      [prefs : (__tl_dyn-array i64)
        (let
          [win64-arg-result-pref-function
            (compiler-reg-win64-arg-result-pref-function)]
          [test-identity-coalesce (compiler-reg-test-identity-coalesce 6)]
          (reg.compiler-reg-function-arg-prefs
            Windows
            win64-arg-result-pref-function
            test-identity-coalesce
            6))]
      (and
        (=
          (array-ref prefs 0)
          (reg.compiler-reg-id-seq-index-of
            (reg.compiler-reg-global-shared-view pool)
            cabi.compiler-reg-id-rcx
            0))
        (=
          (array-ref prefs 1)
          (reg.compiler-reg-id-seq-index-of
            (reg.compiler-reg-global-shared-view pool)
            cabi.compiler-reg-id-rdx
            0))
        (=
          (array-ref prefs 2)
          (reg.compiler-reg-id-seq-index-of
            (reg.compiler-reg-global-shared-view pool)
            cabi.compiler-reg-id-r8
            0))
        (=
          (array-ref prefs 3)
          (reg.compiler-reg-id-seq-index-of
            (reg.compiler-reg-global-shared-view pool)
            cabi.compiler-reg-id-r9
            0))
        (= (array-ref prefs 4) -1)
        (=
          (array-ref prefs 5)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rax 0))))))

(cfg
  test
  ;; M-A (RC1): a clobber-point function does not stack-home its params. The
  ;; scalar param cannot keep its ABI pin (the call clobbers %rdi) but becomes
  ;; an ordinary greedy candidate restricted to callee-saved homes: it wins the
  ;; first callee-saved register and is copied there once at entry instead of
  ;; being reloaded from the stack at every use.
  (define (compiler-reg-scalar-param-clobber-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-param-clobber-function))
      [(Plan assignments ineligible _ _ _)
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
  ;; incoming %rdi instead of taking a greedy callee-saved home.
  (define (compiler-reg-scalar-aggregate-param-pinned-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-param-aggregate-function))
      [(Plan assignments ineligible _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi))])))

;; M-A (RC1): a used param's interval is force-extended to the function's first
;; point (the entry copy writes its home register in the prologue), so the
;; live-in gap param spans [0,4] instead of the precise builder's [1,4].
(cfg
  test
  ;; Zero-call function with six scalar params, only `f` (var 5) used. The
  ;; unused params 0-4 have no interval, so they can be neither pinned nor
  ;; greedy-allocated; var 5 keeps its %r9 ABI pin. The
  ;; zero-call locals 6..12 then fill the caller-saved pool head in candidate
  ;; order -- %rax/%rsi/%rdi with the current pool ordering -- skipping the
  ;; pinned %r9; nothing spills.
  (define (compiler-reg-scalar-zero-call-param-conflict-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      Linux
      (compiler-reg-zero-call-param-conflict-function))
      [(Plan assignments _ _ _ _)
        (and
          (= (compiler-reg-spill-count assignments) 0)
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
    (irt.func
      "function @remat_weight() -> unit vars 2 {
       entry:
         %0 = mov 7 : i64
         %1 = add 1, 2 : i64
         store @use1, %1 : i64
         store @use0a, %0 : i64
         store @use0b, %0 : i64
         return
       }")))

(cfg
  test
  (define (compiler-reg-remat-multi-def-function) : ir.CompilerIrFunction
    (irt.func
      "function @remat_multi_def() -> unit vars 1 {
       entry:
         %0 = mov 7 : i64
         %0 = add 1, 2 : i64
         return
       }")))

;; ---------------------------------------------------------------------------
;; R5: invariant facts.
;;
;; The shape is cfg-build-csr's, reduced: a `&Vec` parameter, the slots handle
;; read out of it, the handle's `len` and `data` words, and an ELEMENT store
;; through the data pointer. That store writes payload only, so every global
;; cell stays invariant across it.
(cfg
  test
  (define (compiler-reg-invariant-descriptor-function
    [extra : ir.CompilerIrInstrSeq]) : ir.CompilerIrFunction
    (Function
      (ir.compiler-ir-test-symbol "invariant_descriptor")
      (irt.params "v=%0:(& size-of i64)")
      (Unit)
      9
      (ir.compiler-ir-blocks
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "%1 = gep %0, 0 : u8")
            (compiler-reg-test-instr-seq-prepend
              (irt.instr "%2 = load %1 : (__tl_dyn-array i64)")
              (compiler-reg-test-instr-seq-prepend
                (irt.instr "%3 = gep %2, 1 : i64")
                (compiler-reg-test-instr-seq-prepend
                  (irt.instr "%4 = load %3 : i64")
                  (compiler-reg-test-instr-seq-prepend
                    (irt.instr "%5 = gep %2, 0 : i64")
                    (compiler-reg-test-instr-seq-prepend
                      (irt.instr "%6 = load %5 : u64")
                      (compiler-reg-test-instr-seq-prepend
                        (irt.instr "%7 = gep %6, %4 : i64")
                        (compiler-reg-test-instr-seq-prepend
                          (irt.instr "store_ptr %7, 0 : i64")
                          extra))))))))))
      Ordinary)))

(cfg
  test
  (define (compiler-reg-invariant-return-seq) : ir.CompilerIrInstrSeq
    (irt.instrs "return")))

(cfg
  test
  (define (compiler-reg-invariant-facts-for [extra : ir.CompilerIrInstrSeq]) : reg.CompilerRegInvariantFacts
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-invariant-descriptor-function extra)]
      (reg.compiler-reg-invariant-facts-build
        (ir.compiler-ir-global-shared-view func)
        (reg.compiler-reg-function-var-types func)))))

(cfg
  test
  (define (compiler-reg-invariant-element-store-cells-clean-ok?) : bool
    (let
      [facts : reg.CompilerRegInvariantFacts
        (compiler-reg-invariant-facts-for (compiler-reg-invariant-return-seq))]
      facts.cells-clean)))

;; A FIELD store -- one whose address is a descriptor word rather than an
;; element of a payload buffer -- may write anything, so the whole function
;; falls back to "nothing is invariant".
(cfg
  test
  (define (compiler-reg-invariant-field-store-refused-ok?) : bool
    (let
      [facts : reg.CompilerRegInvariantFacts
        (compiler-reg-invariant-facts-for
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "store_ptr %3, 0 : i64")
            (compiler-reg-invariant-return-seq)))]
      (not facts.cells-clean))))

;; A CALL that may write memory is the `&mut`-parameter case: the callee can
;; push through the reference and move `data`/`len`, or write any global cell,
;; so nothing in this function is invariant any more (LLVM refuses the same way
;; through `isDereferenceableInvariantLoad`'s mod/ref query).
(cfg
  test
  (define (compiler-reg-invariant-call-refused-ok?) : bool
    (let
      [facts : reg.CompilerRegInvariantFacts
        (compiler-reg-invariant-facts-for
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "%8 = call vec_push() : unit")
            (compiler-reg-invariant-return-seq)))]
      (not facts.cells-clean))))

(cfg
  test
  (define (compiler-reg-remat-classifier-ok?) : bool
    (and
      (compiler-reg-remat-defn? (irt.instr "%10 = mov 1 : i64"))
      (compiler-reg-remat-defn? (irt.instr "%11 = mov true : bool"))
      (compiler-reg-remat-defn? (Mov 12 (Char 'x') (Char)))
      (compiler-reg-remat-defn?
        (Mov 13 (F64 0x3ff0000000000000) (compiler-reg-f64-ty)))
      (compiler-reg-remat-defn? (irt.instr "%14 = mov &@global : u64"))
      (not (compiler-reg-remat-defn? (irt.instr "%15 = mov @global : i64")))
      (compiler-reg-remat-defn-with-invariant-loads?
        (irt.instr "%16 = mov @global : i64")
        true)
      (compiler-reg-remat-defn? (irt.instr "%17 = gep &@global, 2 : i64"))
      (not
        (compiler-reg-remat-defn? (irt.instr "%18 = gep &@global, %0 : i64")))
      ;; R5: `gep BASE, K` with a REGISTER base and a constant offset is one
      ;; `leaq K*w(%base), %r` -- exactly the cost of the reload it replaces --
      ;; so the shape is admitted here; whether the base is really in a register
      ;; and live at a given use is the rewrite's per-use question.
      (compiler-reg-remat-defn? (irt.instr "%19 = gep %0, 2 : i64"))
      (not (compiler-reg-remat-defn? (irt.instr "%27 = gep %0, %1 : i64")))
      (not (compiler-reg-remat-defn? (irt.instr "%20 = load &@global : i64")))
      (compiler-reg-remat-defn-with-invariant-loads?
        (irt.instr "%21 = load &@global : i64")
        true)
      (not
        (compiler-reg-remat-defn-with-invariant-loads?
          (irt.instr "%22 = load %0 : i64")
          true))
      (not (compiler-reg-remat-defn? (irt.instr "%23 = mov %0 : i64")))
      ;; W3: a String/Function/Bytes mov materialises as one
      ;; `leaq label(%rip)` and IS rematerialisable, so the spill-weight
      ;; discount must see it as a candidate (it was missing before).
      (compiler-reg-remat-defn? (Mov 24 (String "heap") (String)))
      (compiler-reg-remat-defn? (irt.instr "%26 = mov fn@fn : u64"))
      (not (compiler-reg-remat-defn? (irt.instr "%25 = add 1, 2 : i64"))))))

(cfg
  test
  (define (compiler-reg-remat-recompute-classifier-ok?) : bool
    (and
      ;; Static address materialisations: admitted at any word type, unchanged.
      (reg.compiler-reg-remat-recompute-value?
        (GlobalAddr (ir.compiler-ir-test-symbol "global"))
        (U64)
        false)
      (reg.compiler-reg-remat-recompute-value?
        (Function (ir.compiler-ir-test-symbol "fn"))
        (U64)
        false)
      (reg.compiler-reg-remat-recompute-value? (String "s") (String) false)
      ;; W3 step (a): integer/bool/char literals at a type whose reload is
      ;; bit-identical to the immediate materialisation.
      (reg.compiler-reg-remat-recompute-value?
        (I64 7)
        (compiler-reg-i64-ty)
        false)
      (reg.compiler-reg-remat-recompute-value? (I64 0) (U64) false)
      (reg.compiler-reg-remat-recompute-value?
        (I64 -1)
        (compiler-reg-i64-ty)
        false)
      (reg.compiler-reg-remat-recompute-value? (Bool false) (Bool) false)
      (reg.compiler-reg-remat-recompute-value?
        (Bool true)
        (compiler-reg-i64-ty)
        false)
      (reg.compiler-reg-remat-recompute-value? (Char 'x') (Char) false)
      ;; NEGATIVE GATE. A narrow var reloads sign/zero-EXTENDED from its slot
      ;; (movslq / movzbq), so an i64 literal homed there is not reproduced by
      ;; `movl $K` and must be refused.
      (not (reg.compiler-reg-remat-recompute-value? (I64 7) (I32) false))
      (not (reg.compiler-reg-remat-recompute-value? (I64 7) (U8) false))
      (not (reg.compiler-reg-remat-recompute-value? (Char 'x') (U8) false))
      ;; NEGATIVE GATE. A literal in a register-GROUP / handle type is refused:
      ;; the backend errors on a rematerialised group var.
      (not (reg.compiler-reg-remat-recompute-value? (I64 0) (String) false))
      ;; NEGATIVE GATE. No scalar backend materialisation for f64, and a LOAD
      ;; of a global cell is not a static value.
      (not
        (reg.compiler-reg-remat-recompute-value?
          (F64 0x3ff0000000000000)
          (compiler-reg-f64-ty)
          false))
      (not
        (reg.compiler-reg-remat-recompute-value?
          (Global (ir.compiler-ir-test-symbol "global"))
          (compiler-reg-i64-ty)
          false))
      (not
        (reg.compiler-reg-remat-recompute-value?
          (Var 0)
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
      (reg.compiler-reg-assignment-table-insert assignments var (Spill 0))
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
          [(Some location) location]
          [(No) (Spill -1)])))))

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
    (Function
      (ir.compiler-ir-test-symbol "remat_addr_taken")
      (ir.compiler-ir-param-seq-empty)
      (Unit)
      2
      (ir.compiler-ir-blocks
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-seq3
            (irt.instr "%0 = mov 7 : i64")
            (AddrOf 1 0)
            (Return No))))
      Ordinary)))

(cfg
  test
  (define (compiler-reg-remat-frozen-global-function [load-shape? : bool]) : ir.CompilerIrFunction
    (Function
      (ir.compiler-ir-test-symbol "remat_frozen_global")
      (ir.compiler-ir-param-seq-empty)
      (Unit)
      1
      (ir.compiler-ir-blocks
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-seq3
            (if load-shape?
              (irt.instr "%0 = load &@frozen : i64")
              (irt.instr "%0 = mov @frozen : i64"))
            (irt.instr "store @sink, %0 : i64")
            (Return No))))
      Ordinary)))

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
      [cell : ir.CompilerIrValue (Global (ir.compiler-ir-test-symbol "frozen"))]
      [unseeded? : bool
        (not
          (reg.compiler-reg-remat-recompute-value?
            (reg.compiler-reg-global-shared-view cell)
            (compiler-reg-i64-ty)
            false))]
      (reg.compiler-reg-frozen-globals-begin!)
      (reg.compiler-reg-frozen-globals-finish!)
      (let
        [seeded? : bool
          (reg.compiler-reg-remat-recompute-value?
            (reg.compiler-reg-global-shared-view cell)
            (compiler-reg-i64-ty)
            false)]
        [narrow-refused? : bool
          (not
            (reg.compiler-reg-remat-recompute-value?
              (reg.compiler-reg-global-shared-view cell)
              (I32)
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
            written-load-refused?))))))

(cfg
  test
  (define (compiler-reg-remat-discount-weights-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-weight-function)]
      [empty-coalesce : reg.CompilerRegCoalesceMap
        (reg.CompilerRegCoalesceMap (__tl_make-array i64 0))]
      [raw : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights
          (ir.compiler-ir-global-shared-view func))]
      [discounted : (__tl_dyn-array i64)
        (compiler-reg-function-spill-weights-remat
          (ir.compiler-ir-global-shared-view func)
          empty-coalesce)]
      [multi-raw : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights
          (compiler-reg-remat-multi-def-function))]
      [multi-discounted : (__tl_dyn-array i64)
        (compiler-reg-function-spill-weights-remat
          (compiler-reg-remat-multi-def-function)
          empty-coalesce)]
      [parents : (__tl_dyn-array i64) (__tl_make-array i64 2)]
      (set! (array-ref parents 0) 0)
      (set! (array-ref parents 1) 0)
      (let
        [coalesced : (__tl_dyn-array i64)
          (let
            [coalesce (reg.CompilerRegCoalesceMap parents)]
            (compiler-reg-function-spill-weights-remat func coalesce))]
        (and
          (= (array-ref raw 0) 3)
          (= (array-ref raw 1) 2)
          (= (array-ref discounted 0) 1)
          (= (array-ref discounted 1) 2)
          (= (array-ref coalesced 0) 3)
          (= (array-ref coalesced 1) 2)
          (= (array-ref multi-raw 0) 2)
          (= (array-ref multi-discounted 0) 2))))))

(cfg
  test
  (define (compiler-reg-remat-spill-weight-eviction-function) : ir.CompilerIrFunction
    (let
      [instrs : ir.CompilerIrInstrSeq (ir.compiler-ir-instr-seq-empty)]
      (set! instrs (compiler-reg-test-instr-seq-prepend (Return No) instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "store @hot0b, %0 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "store @hot0a, %0 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "store @cold1, %1 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "store @use5, %5 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "store @use4, %4 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "store @use3, %3 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "store @use2, %2 : i64")
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
          (irt.instr "%6 = syscall(39)")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%5 = mov 5 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%4 = mov 4 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%3 = mov 3 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%2 = mov 2 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%1 = add 1, 2 : i64")
          instrs))
      (set!
        instrs
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%0 = mov 0 : i64")
          instrs))
      (Function
        (ir.compiler-ir-test-symbol "remat_spill_weight_eviction")
        (ir.compiler-ir-param-seq-empty)
        (Unit)
        7
        (ir.compiler-ir-blocks
          (ir.CompilerIrBlock.Block (ir.compiler-ir-label "entry") instrs))
        Ordinary))))

(cfg
  test
  (define (compiler-reg-remat-spill-weight-eviction-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-remat-spill-weight-eviction-function)]
      [empty-coalesce : reg.CompilerRegCoalesceMap
        (reg.CompilerRegCoalesceMap (__tl_make-array i64 0))]
      [raw : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights
          (ir.compiler-ir-global-shared-view func))]
      [discounted : (__tl_dyn-array i64)
        (compiler-reg-function-spill-weights-remat
          (ir.compiler-ir-global-shared-view func)
          empty-coalesce)]
      (match (reg.compiler-reg-plan-function-scalar func)
        [(Plan assignments _ _ _ _)
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
            ;; frame slot at all -- it is rematerialised at its one use.
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
    (irt.func
      "function @spill_weight_eviction() -> unit vars 7 {
       entry:
         %0 = mov 0 : i64
         %1 = mov 1 : i64
         %2 = mov 2 : i64
         %3 = mov 3 : i64
         %4 = mov 4 : i64
         %5 = mov 5 : i64
         %6 = syscall(39)
         store @use2a, %2 : i64
         store @use2b, %2 : i64
         store @use3a, %3 : i64
         store @use3b, %3 : i64
         store @use4a, %4 : i64
         store @use4b, %4 : i64
         store @use5a, %5 : i64
         store @use5b, %5 : i64
         store @cold1, %1 : i64
         store @hot0a, %0 : i64
         store @hot0b, %0 : i64
         store @hot0c, %0 : i64
         return
       }")))

(cfg
  test
  (define (compiler-reg-spill-weight-eviction-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar
      (compiler-reg-spill-weight-eviction-function))
      [(Plan assignments _ _ _ _)
        (and
          (compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 0))
          ;; W3 step (a): the victim's def is an i64 literal, so it leaves no
          ;; frame slot behind.
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
    (irt.func
      "function @loop_spill_weight_eviction() -> unit vars 7 {
       entry:
         %0 = mov 0 : i64
         %1 = mov 1 : i64
         %2 = mov 2 : i64
         %3 = mov 3 : i64
         %4 = mov 4 : i64
         %5 = mov 5 : i64
         %6 = syscall(39)
         jump loop
       loop:
         store @hot0, %0 : i64
         store @hot2, %2 : i64
         store @hot3, %3 : i64
         store @hot4, %4 : i64
         store @hot5, %5 : i64
         branch false, body, exit
       body:
         jump loop
       exit:
         store @cold1, %1 : i64
         return
       }")))

(cfg
  test
  (define (compiler-reg-loop-spill-weight-eviction-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-loop-spill-weight-eviction-function)]
      [static-counts : (__tl_dyn-array i64)
        (compiler-reg-function-ref-counts
          (ir.compiler-ir-global-shared-view func))]
      [weighted-counts : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights
          (ir.compiler-ir-global-shared-view func))]
      (match (reg.compiler-reg-plan-function-scalar func)
        [(Plan assignments _ _ _ _)
          (and
            (= (array-ref static-counts 0) (array-ref static-counts 1))
            (> (array-ref weighted-counts 0) (array-ref weighted-counts 1))
            (compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 0))
            ;; W3 step (a): the victim's def is an i64 literal.
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
            (BoundsCheck (I64 0) (Var var) (ir.compiler-ir-label "ok"))
            (BoundsCheck (Var var) (I64 64) (ir.compiler-ir-label "ok")))
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
          (Mov var (I64 (+ var 1)) (compiler-reg-i64-ty))
          (if (< var 1)
            tail
            (compiler-reg-test-instr-seq-prepend
              (Mov var (I64 (+ var 100)) (compiler-reg-i64-ty))
              tail)))))))

(cfg
  test
  (define (compiler-reg-foldable-rebate-function [fold? : bool]) : ir.CompilerIrFunction
    (Function
      (ir.compiler-ir-test-symbol "foldable_rebate_pressure")
      (ir.compiler-ir-param-seq-empty)
      (Unit)
      7
      (ir.compiler-ir-blocks-with-tail
        (irt.blocks
          "l3latch:
                   jump l3
                 l2latch:
                   jump l2
                 l1latch:
                   jump l1
                 exit:
                   return")
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-foldable-rebate-defs
            5
            (compiler-reg-test-instr-seq-prepend
              (Syscall 6 (One (I64 39)))
              (compiler-reg-test-instr-seq-prepend
                (Jump (ir.compiler-ir-label "l1"))
                (ir.compiler-ir-instr-seq-empty)))))
        (irt.block
          "l1:
               %0 = add %0, 1 : i64
               branch false, l2, exit")
        (irt.block "l2:
                 branch false, l3, l1latch")
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "l3")
          (compiler-reg-foldable-rebate-checks
            5
            fold?
            (irt.instrs "branch false, l3latch, l2latch"))))
      Ordinary)))

(cfg
  test
  (define (compiler-reg-foldable-rebate-array [func : ir.CompilerIrFunction]) : (__tl_dyn-array
      i64)
    (match func
      [(Function _ _ _ vars blocks _)
        (compiler-reg-function-foldable-rebates
          (reg.compiler-reg-global-shared-view blocks)
          (reg.compiler-reg-function-block-weights blocks)
          vars)])))

(cfg
  test
  (define (compiler-reg-foldable-rebate-combined [func : ir.CompilerIrFunction]) : (__tl_dyn-array
      i64)
    (match (reg.compiler-reg-global-shared-view func)
      [(Function _ _ _ vars _ _)
        (let
          [coalesce-map (reg.CompilerRegCoalesceMap (__tl_make-array i64 0))]
          (reg.compiler-reg-function-spill-weights-combined
            func
            coalesce-map
            vars))])))

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
        [(Plan assignments _ _ _ _)
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
        [(Plan assignments _ _ _ _)
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
        (compiler-reg-foldable-rebate-array
          (reg.compiler-reg-global-shared-view func))]
      [second-rebates : (__tl_dyn-array i64)
        (compiler-reg-foldable-rebate-array
          (reg.compiler-reg-global-shared-view func))]
      [first-combined : (__tl_dyn-array i64)
        (compiler-reg-foldable-rebate-combined
          (reg.compiler-reg-global-shared-view func))]
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

(cfg
  test
  (define (compiler-reg-remat-parameter-global-rhs-function) : ir.CompilerIrFunction
    (irt.func
      "function @remat_parameter_global_rhs(x=%0:i64, y=%1:i64) -> i64 vars 3 {
       entry:
         %2 = mul %0, @global_value : i64
         return %2
       }")))

(cfg
  test
  (define (compiler-reg-remat-parameters-poisoned-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-remat-parameter-global-rhs-function)]
      [table : reg.CompilerRegRematTable
        (reg.compiler-reg-remat-table-build
          (ir.compiler-ir-global-shared-view func)
          (reg.compiler-reg-function-var-types func))]
      [candidates : (__tl_dyn-array i64) table.candidates]
      (and
        (= (array-ref candidates 0) 2)
        (= (array-ref candidates 1) 2)
        (= (array-ref candidates 2) 0)))))

(cfg
  test
  (define (compiler-reg-remat-parameter-assignment-keeps-home-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-remat-parameter-global-rhs-function)]
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignments-prepend
          (reg.CompilerRegAssignment
            0
            (Spill (reg.compiler-reg-stack-slot-offset 0)))
          (reg.compiler-reg-assignment-table-empty))]
      [rewritten : reg.CompilerRegAssignmentTable
        (let
          [test-identity-coalesce (compiler-reg-test-identity-coalesce 3)]
          (reg.compiler-reg-rewrite-remat-assignments
            assignments
            func
            test-identity-coalesce
            (live.compiler-live-set-empty)
            true
            3))]
      (match (reg.compiler-reg-assignment-lookup rewritten 0)
        [(Some (Spill _)) true]
        [_ false]))))

(cfg
  test
  (define (compiler-reg-call-spanning-multiblock-local-function) : ir.CompilerIrFunction
    (irt.func
      "function @call_spanning_multiblock_local() -> unit vars 8 {
       entry:
         jump body
       body:
         %0 = mov 0 : i64
         %1 = mov 1 : i64
         %2 = mov 2 : i64
         %3 = mov 3 : i64
         %4 = mov 4 : i64
         %5 = mov 5 : i64
         %6 = mov 6 : i64
         %7 = call side_effect() : unit
         store @g0, %0 : i64
         store @g1, %1 : i64
         store @g2, %2 : i64
         store @g3, %3 : i64
         store @g4, %4 : i64
         store @g5, %5 : i64
         store @g6, %6 : i64
         store @g5b, %5 : i64
         store @g5c, %5 : i64
         jump exit
       exit:
         return
       }")))

(cfg
  test
  (define (compiler-reg-call-spanning-multiblock-boundary-function) : ir.CompilerIrFunction
    (irt.func
      "function @call_spanning_multiblock_boundary() -> unit vars 8 {
       entry:
         %0 = mov 0 : i64
         %1 = mov 1 : i64
         %2 = mov 2 : i64
         %3 = mov 3 : i64
         %4 = mov 4 : i64
         %5 = mov 5 : i64
         %6 = mov 6 : i64
         jump body
       body:
         %7 = call side_effect() : unit
         store @g0, %0 : i64
         store @g1, %1 : i64
         store @g2, %2 : i64
         store @g3, %3 : i64
         store @g4, %4 : i64
         store @g5, %5 : i64
         store @g6, %6 : i64
         store @g5b, %5 : i64
         store @g5c, %5 : i64
         jump exit
       exit:
         return
       }")))

(cfg
  test
  (define (compiler-reg-scalar-call-spanning-multiblock-local-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-call-spanning-multiblock-local-function)]
      [plan : reg.CompilerRegPlan (reg.compiler-reg-plan-function-scalar func)]
      (match plan
        [(Plan assignments _ _ _ split-vars)
          (and
            ;; Same capacity story as the single-block fixture: the greedy
            ;; register-homes the hot call-spanning value (spill-weight priority)
            ;; and the single-use overflow (var 6) takes no register. W3 step
            ;; (a): both overflows are i64 literals, so they rematerialise
            ;; instead of taking frame slots.
            (= (compiler-reg-spill-count assignments) 0)
            (compiler-reg-maybe-location-remat?
              (reg.compiler-reg-assignment-lookup assignments 6))
            (not
              (let
                [call-split-shadows
                  (reg.compiler-reg-call-split-shadows
                    (reg.compiler-reg-global-shared-view split-vars))]
                (live.compiler-live-set-contains? call-split-shadows 5)))
            (not
              (let
                [call-split-shadows
                  (reg.compiler-reg-call-split-shadows split-vars)]
                (live.compiler-live-set-contains? call-split-shadows 6))))]))))

(cfg
  test
  (define (compiler-reg-scalar-call-spanning-multiblock-boundary-ok?) : bool
    (let
      [plan : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar
          (compiler-reg-call-spanning-multiblock-boundary-function))]
      (match plan
        [(Plan _ _ _ _ split-vars)
          (and
            (not
              (let
                [call-split-shadows
                  (reg.compiler-reg-call-split-shadows
                    (reg.compiler-reg-global-shared-view split-vars))]
                (live.compiler-live-set-contains? call-split-shadows 5)))
            (not
              (let
                [call-split-shadows
                  (reg.compiler-reg-call-split-shadows split-vars)]
                (live.compiler-live-set-contains? call-split-shadows 6))))]))))

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
        (irt.instrs
          "%2 = add %1, %0 : i64
           %1 = mov %2 : i64
           branch %2, loop, exit")]
      [loop-body : ir.CompilerIrInstrSeq
        (if define-in-loop?
          (irt.instrs
            "%0 = mov 9 : i64
             %2 = add %1, %0 : i64
             %1 = mov %2 : i64
             branch %2, loop, exit")
          (if call-in-loop?
            (irt.instrs
              "%3 = call side_effect() : unit
               %2 = add %1, %0 : i64
               %1 = mov %2 : i64
               branch %2, loop, exit")
            loop-tail))]
      (Function
        (ir.compiler-ir-test-symbol "loop_region_fixture")
        (ir.compiler-ir-param-seq-empty)
        (Unit)
        4
        (ir.compiler-ir-blocks-with-tail
          (irt.blocks "exit:
                 return")
          (irt.block
            "entry:
               %0 = mov 7 : i64
               %1 = mov 0 : i64
               jump loop")
          (ir.CompilerIrBlock.Block (ir.compiler-ir-label "loop") loop-body))
        Ordinary))))

;; Collect loop rows for var 0 (marked a full-grade candidate) and return the
;; bucket the collector filled.
(cfg
  test
  (define (compiler-reg-loop-region-rows-for
    [define-in-loop? : bool]
    [call-in-loop? : bool]) : reg.CompilerRegCallRegionStatSeq
    (match (compiler-reg-loop-region-fixture define-in-loop? call-in-loop?)
      [(Function _ _ _ vars blocks _)
        (let
          [cand : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [order : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
          [buckets : (__tl_dyn-array reg.CompilerRegCallRegionStatSeq)
            (__tl_make-array reg.CompilerRegCallRegionStatSeq vars)]
          [bi : i64 0]
          (while (< bi vars)
            (set!
              (array-ref buckets bi)
              (reg.compiler-reg-call-region-stat-seq-empty))
            (set! bi (+ bi 1)))
          (set! (array-ref cand 0) (reg.compiler-reg-call-region-cand-full))
          (set! (array-ref order 0) 0)
          (let
            [ast-node-pool-reader-type-segment-bases
              (ast.ast-node-pool-reader-type-segment-bases)]
            [blocks-copy (ir.compiler-ir-global-shared-view blocks)]
            [function-loop-depths
              (reg.compiler-reg-function-loop-depths blocks)]
            (reg.compiler-reg-call-region-loop-rows!
              ast-node-pool-reader-type-segment-bases
              blocks-copy
              function-loop-depths
              cand
              order
              1
              vars
              (reg.compiler-reg-global-shared-view buckets)))
          (array-ref buckets 0))])))

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
          [(CompilerRegCallRegionStat var lo hi uses defs firstdef depth kind)
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
      (set! (array-ref ranges 0) 3)
      (set! (array-ref ranges 1) (- 0 1))
      (set! (array-ref ranges 2) header-lo)
      (set! (array-ref ranges 3) header-hi)
      (set! (array-ref ranges 4) 1)
      (set! (array-ref ranges 5) 1)
      ranges)))

(cfg
  test
  (define (compiler-reg-loop-region-depths [header-depth : i64]) : (__tl_dyn-array
      i64)
    (let
      [depths : (__tl_dyn-array i64) (__tl_make-array i64 3)]
      (set! (array-ref depths 0) 0)
      (set! (array-ref depths 1) header-depth)
      (set! (array-ref depths 2) 0)
      depths)))

(cfg
  test
  (define (compiler-reg-loop-region-rotated-ranges) : (__tl_dyn-array i64)
    (let
      [ranges : (__tl_dyn-array i64) (__tl_make-array i64 6)]
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
      ranges)))

(cfg
  test
  (define (compiler-reg-loop-region-rotated-depths) : (__tl_dyn-array i64)
    (let
      [depths : (__tl_dyn-array i64) (__tl_make-array i64 3)]
      (set! (array-ref depths 0) 0)
      (set! (array-ref depths 1) 1)
      (set! (array-ref depths 2) 1)
      depths)))

;; (e) Single-entry admission. The header may be entered ONLY from its layout
;; predecessor and from inside the region; any other edge in means the anchor
;; does not dominate the remapped uses.
(cfg
  test
  (define (compiler-reg-loop-region-admit-ok?) : bool
    (and
      ;; preds {entry, self}: the admitted self-loop shape
      (let
        [loop-region-ranges (compiler-reg-loop-region-ranges 0 1)]
        [loop-region-depths (compiler-reg-loop-region-depths 1)]
        (reg.compiler-reg-call-region-loop-admit?
          loop-region-ranges
          loop-region-depths
          3
          1
          1
          1))
      ;; a later block also jumps into the header -> refuse
      (not
        (let
          [loop-region-ranges (compiler-reg-loop-region-ranges 0 2)]
          [loop-region-depths (compiler-reg-loop-region-depths 1)]
          (reg.compiler-reg-call-region-loop-admit?
            loop-region-ranges
            loop-region-depths
            3
            1
            1
            1)))
      ;; no edge from the layout predecessor -> there is no preheader to anchor
      (not
        (let
          [loop-region-ranges (compiler-reg-loop-region-ranges 1 1)]
          [loop-region-depths (compiler-reg-loop-region-depths 1)]
          (reg.compiler-reg-call-region-loop-admit?
            loop-region-ranges
            loop-region-depths
            3
            1
            1
            1)))
      ;; not a loop at all
      (not
        (let
          [loop-region-ranges (compiler-reg-loop-region-ranges 0 1)]
          [loop-region-depths (compiler-reg-loop-region-depths 0)]
          (reg.compiler-reg-call-region-loop-admit?
            loop-region-ranges
            loop-region-depths
            3
            1
            1
            1)))
      ;; the header is block 0: no layout predecessor exists
      (not
        (let
          [loop-region-ranges (compiler-reg-loop-region-ranges 0 1)]
          [loop-region-depths (compiler-reg-loop-region-depths 1)]
          (reg.compiler-reg-call-region-loop-admit?
            loop-region-ranges
            loop-region-depths
            3
            0
            0
            0)))
      ;; ROTATED: the span is [1..2] and the header is its LAST block, entered
      ;; from block 0 (the preheader, directly above the span) and from block 1
      ;; (the body, over the back edge that falls through into it). The anchor
      ;; is the span's layout predecessor, so admission holds with the header
      ;; in the middle of the region rather than at its start.
      (let
        [loop-region-rotated-ranges (compiler-reg-loop-region-rotated-ranges)]
        [loop-region-rotated-depths (compiler-reg-loop-region-rotated-depths)]
        (reg.compiler-reg-call-region-loop-admit?
          loop-region-rotated-ranges
          loop-region-rotated-depths
          3
          2
          1
          2)))))

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
        (CompilerRegCallRegionStat
          0
          4
          10
          1
          0
          0
          1
          (reg.compiler-reg-call-region-kind-block))]
      [one-use-loop : reg.CompilerRegCallRegionStat
        (CompilerRegCallRegionStat
          0
          4
          10
          1
          0
          0
          1
          (reg.compiler-reg-call-region-kind-loop))]
      [deep-loop : reg.CompilerRegCallRegionStat
        (CompilerRegCallRegionStat
          0
          4
          10
          2
          0
          0
          3
          (reg.compiler-reg-call-region-kind-loop))]
      (reg.compiler-reg-fill-i64-array (&mut ends) 1073741824)
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
            (CompilerRegCallRegionStat
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
            (CompilerRegCallRegionStat
              0
              4
              10
              1
              0
              0
              0
              (reg.compiler-reg-call-region-kind-loop))
            ends))))))

;; Picked-row exclusion is an OVERLAP test now: a loop row spans the block rows
;; nested inside it, and one root can only hold one shadow at a time.
(cfg
  test
  (define (compiler-reg-loop-region-overlap-ok?) : bool
    (let
      [lo : (__tl_dyn-array i64) (__tl_make-array i64 4)]
      [hi : (__tl_dyn-array i64) (__tl_make-array i64 4)]
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
        (not (reg.compiler-reg-call-region-picked? lo hi 0 120 140))))))

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
          (Var 3)
          (Var 0))]
      (Function
        (ir.compiler-ir-test-symbol "evict_fixture")
        (ir.compiler-ir-param-seq-empty)
        (Unit)
        7
        (ir.compiler-ir-blocks-with-tail
          (irt.blocks
            "exit:
                 %4 = mov %3 : i64
                 return")
          (irt.block
            "entry:
               %0 = mov 7 : i64
               %3 = mov 11 : i64
               %1 = mov 0 : i64
               jump loop")
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "loop")
            (compiler-reg-test-instr-seq-prepend
              (irt.instr "%2 = add %1, %0 : i64")
              (compiler-reg-test-instr-seq-prepend
                (BinOp 5 (Add) (Var 2) mid (compiler-reg-i64-ty))
                (irt.instrs
                  "%6 = add %5, %0 : i64
                     %1 = mov %6 : i64
                     branch %6, loop, exit")))))
        Ordinary))))

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
      (while (< i 7)
        (set! (array-ref parents i) i)
        (set! i (+ i 1)))
      parents)))

;; v3 spans the region and is read after it (`victim-end` 18); v5 is defined and
;; consumed strictly inside the loop, which is what a BUSY co-occupant looks
;; like to the interval index.
(cfg
  test
  (define (compiler-reg-evict-test-index [victim-end : i64]) : reg.CompilerRegIntervalIndex
    (let
      [starts : (__tl_dyn-array i64) (__tl_make-array i64 7)]
      [ends : (__tl_dyn-array i64) (__tl_make-array i64 7)]
      (reg.compiler-reg-fill-i64-array (&mut starts) (- 0 1))
      (reg.compiler-reg-fill-i64-array (&mut ends) (- 0 1))
      (set! (array-ref starts 3) 2)
      (set! (array-ref ends 3) victim-end)
      (set! (array-ref starts 5) 12)
      (set! (array-ref ends 5) 14)
      (reg.CompilerRegIntervalIndex
        starts
        ends
        (__tl_make-array reg.CompilerRegIntervalSeq 0)))))

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
          (Register cabi.compiler-reg-id-r12))]
      (reg.compiler-reg-assignment-table-insert
        with-victim
        5
        (Register cabi.compiler-reg-id-r13)))))

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
      [(Function _ _ _ _ blocks _)
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
          (let
            [blocks-copy (owned_view.compiler-owned-shared-view blocks)]
            [function-loop-depths
              (reg.compiler-reg-function-loop-depths blocks)]
            [evict-test-index (compiler-reg-evict-test-index victim-end)]
            [evict-test-assignments (compiler-reg-evict-test-assignments)]
            [evict-test-pool (compiler-reg-evict-test-pool)]
            (reg.compiler-reg-call-region-evict-try
              blocks-copy
              function-loop-depths
              weights
              evict-test-index
              parents
              evict-test-assignments
              evict-test-pool
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
              (&mut out-points)
              (&mut out-saves))))])))

(cfg
  test
  (define (compiler-reg-evict-picked?
    [pick : reg.CompilerRegCallEvictPick]
    [pix : i64]
    [victim : i64]
    [exits : i64]
    [save : i64]) : bool
    (match pick
      [(CompilerRegCallEvictNoPick) false]
      [(CompilerRegCallEvictSomePick p v e s)
        (and (= p pix) (= v victim) (= e exits) (= s save))])))

(cfg
  test
  (define (compiler-reg-evict-no-pick? [pick : reg.CompilerRegCallEvictPick]) : bool
    (match pick
      [(CompilerRegCallEvictNoPick) true]
      [(CompilerRegCallEvictSomePick _ _ _ _) false])))

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
          (compiler-reg-evict-attempt
            false
            18
            3
            false
            1
            false
            (reg.compiler-reg-global-shared-view points)
            (reg.compiler-reg-global-shared-view saves))
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

;; (e) PRICING: a trip-amplified benefit, a 2x margin, and a two-use floor.
;;
;; The fixture's ONE in-region use is refused by the floor, which the trip
;; factor needs beside it: the victim's save sits at its definition, which for
;; a parameter is the function entry, so it runs on every CALL while the
;; benefit needs the loop to be entered; no depth model sees that asymmetry.
;; Two uses in the same fixture pay: 2*2*8 = 32 >= 2*(2*1 + 1).
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
            0))))))

;; A sibling's read is the class's read: with v5 (used inside the loop) coalesced
;; onto v3, v3 is no longer parked and the verifier says so. Checking the root
;; alone miscompiles this shape: the root's hull covers the region BECAUSE a
;; member is read inside it.
(cfg
  test
  (define (compiler-reg-evict-class-mention-ok?) : bool
    (match (compiler-reg-evict-fixture false)
      [(Function _ _ _ _ blocks _)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [bslots : (__tl_dyn-array ir.CompilerIrBlock) seq.slots]
          [points : (__tl_dyn-array i64)
            (reg.compiler-reg-loop-phi-mb-block-points bslots)]
          [parents : (__tl_dyn-array i64) (compiler-reg-evict-test-parents)]
          [class-parents : (__tl_dyn-array i64)
            (compiler-reg-evict-test-parents)]
          (set! (array-ref class-parents 5) 3)
          (and
            ;; the anchor's point is the preheader's terminator
            (= (- (array-ref points 1) 2) 6)
            (= (- (array-ref points 2) 2) 16)
            ;; v3 alone: parked
            (not
              (reg.compiler-reg-call-region-evict-var-mentioned?
                (reg.compiler-reg-global-shared-view bslots)
                (reg.compiler-reg-global-shared-view points)
                0
                1
                6
                parents
                7
                3))
            ;; v3 with v5 in its class: busy
            (reg.compiler-reg-call-region-evict-var-mentioned?
              (reg.compiler-reg-global-shared-view bslots)
              (reg.compiler-reg-global-shared-view points)
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
              0)))])))

;; (g) PLAN SHAPE. The rewrite realizes exactly three movs for the accepted
;; eviction above: the victim's store right after its definition, the shadow's
;; load at the region anchor, and the victim's reload at the head of the exit
;; block. The loop body gains NOTHING; its reads of v0 are remapped to the
;; shadow var.
(cfg
  test
  (define (compiler-reg-evict-rewrite-shape-ok?) : bool
    (match (compiler-reg-evict-fixture false)
      [(Function _ _ _ vars blocks _)
        (let
          [shadow-regs : (__tl_dyn-array i64) (__tl_make-array i64 7)]
          [split : reg.CompilerRegCallSplit
            (begin
              (reg.compiler-reg-fill-i64-array
                (&mut shadow-regs)
                cabi.compiler-reg-id-invalid)
              (set! (array-ref shadow-regs 0) cabi.compiler-reg-id-r12)
              (CompilerRegCallSplit
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
            (Plan
              (reg.compiler-reg-assignment-table-empty)
              (live.compiler-live-set-empty)
              (reg.compiler-reg-interval-seq-empty)
              (reg.compiler-reg-var-types-empty)
              split)]
          (match (reg.compiler-reg-caller-save-rewrite-blocks
            blocks
            vars
            (reg.compiler-reg-var-types-empty)
            plan)
            [(Rewrite out _ next-vars _ _)
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
                  (=
                    (compiler-reg-evict-block-len
                      (reg.compiler-reg-global-array-element-shared-view
                        oslots
                        0))
                    6)
                  (compiler-reg-evict-block-mov?
                    (reg.compiler-reg-global-array-element-shared-view oslots 0)
                    2
                    7
                    3)
                  (compiler-reg-evict-block-mov?
                    (reg.compiler-reg-global-array-element-shared-view oslots 0)
                    4
                    8
                    0)
                  ;; loop body untouched in COUNT: no reload lands inside it
                  (=
                    (compiler-reg-evict-block-len
                      (reg.compiler-reg-global-array-element-shared-view
                        oslots
                        1))
                    5)
                  ;; exit: the reload, then the two originals
                  (=
                    (compiler-reg-evict-block-len
                      (reg.compiler-reg-global-array-element-shared-view
                        oslots
                        2))
                    3)
                  (compiler-reg-evict-block-mov?
                    (reg.compiler-reg-global-array-element-shared-view oslots 2)
                    0
                    3
                    7)))]))])))

(cfg
  test
  (define (compiler-reg-evict-block-len [block : ir.CompilerIrBlock]) : i64
    (match block
      [(Block _ instrs) (ir.compiler-ir-instr-seq-count instrs)])))

(cfg
  test
  (define (compiler-reg-evict-block-mov?
    [block : ir.CompilerIrBlock]
    [index : i64]
    [dst : i64]
    [src : i64]) : bool
    (match block
      [(Block _ instrs)
        (if (>= index (ir.compiler-ir-instr-seq-count instrs))
          false
          (match (ir.compiler-ir-instr-seq-ref instrs index)
            [(Mov d value _)
              (match value
                [(Var s) (and (= d dst) (= s src))]
                [_ false])]
            [_ false]))])))

(cfg
  test
  (define (compiler-reg-linear-jump-function) : ir.CompilerIrFunction
    (irt.func
      "function @linear_jump() -> i64 vars 1 {
       entry:
         %0 = mov 7 : i64
         jump hot
       hot:
         return %0
       }")))

(cfg
  test
  (define (compiler-reg-call-free-loop-function) : ir.CompilerIrFunction
    (irt.func
      "function @call_free_loop() -> i64 vars 2 {
       entry:
         %0 = mov 7 : i64
         jump loop
       loop:
         %1 = eq %0, 7 : i64
         branch %1, body, exit
       body:
         store @hot0, %0 : i64
         store @hot1, %0 : i64
         jump loop
       exit:
         return 0
       }")))

(cfg
  test
  (define (compiler-reg-call-span-counts-ok?) : bool
    (let
      [points : live.CompilerLiveI64Set (live_tests.compiler-live-set4 2 4 6 8)]
      (and
        (=
          (compiler-reg-call-set-count-in-range
            (reg.compiler-reg-global-shared-view points)
            0
            2)
          0)
        (=
          (compiler-reg-call-set-count-in-range
            (reg.compiler-reg-global-shared-view points)
            0
            3)
          1)
        (=
          (compiler-reg-call-set-count-in-range
            (reg.compiler-reg-global-shared-view points)
            0
            7)
          3)
        (=
          (compiler-reg-call-set-count-in-range
            (reg.compiler-reg-global-shared-view points)
            0
            9)
          4)
        (= (compiler-reg-call-set-count-in-range points 2 8) 2)))))

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
          (Register preassigned-reg))]
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
        [(State _ out)
          (match (reg.compiler-reg-assignment-table-lookup out 1)
            [(Some location)
              (reg.compiler-reg-location-primary-register location)]
            [(No) cabi.compiler-reg-id-invalid])]))))

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
        (cabi.compiler-abi-gp-arg-register-id (Linux) 0)
        cabi.compiler-reg-id-rdi)
      (=
        (cabi.compiler-abi-gp-arg-register-id (Windows) 3)
        cabi.compiler-reg-id-r9)
      (=
        (cabi.compiler-abi-float-arg-register-id (Linux) 7)
        (cabi.compiler-abi-xmm-register-id 7))
      (=
        (cabi.compiler-abi-callee-saved-xmm-register-id (Windows) 9)
        (cabi.compiler-abi-xmm-register-id 15))
      (=
        (cabi.compiler-abi-gp-arg-register-id (Windows) 4)
        cabi.compiler-reg-id-invalid)
      (=
        (cabi.compiler-abi-caller-saved-xmm-register-id (Windows) 6)
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
            (reg.compiler-reg-global-shared-view overlap)
            2
            6
            (reg.compiler-reg-global-shared-view vector-pool))
          (cabi.compiler-abi-vector-register-id 7))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-vector-register-id 6)
            (reg.compiler-reg-global-shared-view overlap)
            2
            6
            (reg.compiler-reg-global-shared-view vector-pool))
          (cabi.compiler-abi-vector-register-id 7))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-vector-register-id 6)
            (reg.compiler-reg-global-shared-view overlap)
            2
            6
            (reg.compiler-reg-global-shared-view vector-pool))
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
            (reg.compiler-reg-global-shared-view vector-pool))
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
        (ir.compiler-ir-global-shared-view list-func)]
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
      [func : ir.CompilerIrFunction (compiler-reg-linear-jump-function)]
      [profile : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [metrics : profile_state.CompilerProfileMetrics
        (profile_state.compiler-profile-state-metrics profile)]
      (reg.compiler-reg-liveness-census-reset!
        (owned_view.compiler-owned-shared-view metrics))
      (let
        [_handle : reg.CompilerRegLivenessHandle
          (reg.compiler-reg-liveness-handle-make
            func
            true
            (owned_view.compiler-owned-shared-view metrics))]
        (and
          (= (compiler-reg-liveness-census-baseline-count metrics) 1)
          ;; The linear fixture is phi-free, so the edge-precise analysis is
          ;; the baseline itself and no second fixpoint is computed.
          (= (compiler-reg-liveness-census-edge-precise-count metrics) 0))))))

(cfg
  test
  (define (compiler-reg-liveness-handle-phi-fixture) : ir.CompilerIrFunction
    (irt.func
      "function @liveness_handle_phi() -> i64 vars 2 {
       entry:
         %0 = mov 7 : i64
         jump loop
       loop:
         %1 = phi [%0, entry], [%1, loop] : i64
         return %1
       }")))

(cfg
  test
  (define (compiler-reg-liveness-handle-phi-ok?) : bool
    (let
      [profile : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [metrics : profile_state.CompilerProfileMetrics
        (profile_state.compiler-profile-state-metrics profile)]
      (reg.compiler-reg-liveness-census-reset!
        (owned_view.compiler-owned-shared-view metrics))
      (let
        [_handle : reg.CompilerRegLivenessHandle
          (reg.compiler-reg-liveness-handle-make
            (compiler-reg-liveness-handle-phi-fixture)
            true
            (owned_view.compiler-owned-shared-view metrics))]
        (and
          (= (compiler-reg-liveness-census-baseline-count metrics) 1)
          ;; Phi present: the second, edge-precise fixpoint is computed.
          (= (compiler-reg-liveness-census-edge-precise-count metrics) 1))))))

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
      (reg.compiler-reg-liveness-census-reset!
        (owned_view.compiler-owned-shared-view left))
      (reg.compiler-reg-liveness-census-reset!
        (owned_view.compiler-owned-shared-view right))
      (let
        [_left : reg.CompilerRegLivenessHandle
          (reg.compiler-reg-liveness-handle-make
            (compiler-reg-liveness-handle-phi-fixture)
            true
            (owned_view.compiler-owned-shared-view left))]
        [_right : reg.CompilerRegLivenessHandle
          (reg.compiler-reg-liveness-handle-make
            (compiler-reg-linear-jump-function)
            true
            (owned_view.compiler-owned-shared-view right))]
        (test.assert-i64-eq
          (compiler-reg-liveness-census-edge-precise-count left)
          1
          "left owner records edge-precise liveness")
        (test.assert-i64-eq
          (compiler-reg-liveness-census-edge-precise-count right)
          0
          "right owner retains its serial result")
        (reg.compiler-reg-liveness-census-reset!
          (owned_view.compiler-owned-shared-view left))
        (test.assert-i64-eq
          (compiler-reg-liveness-census-baseline-count left)
          0
          "left reset clears only left baseline")
        (test.assert-i64-eq
          (compiler-reg-liveness-census-baseline-count right)
          1
          "left reset leaves right baseline intact")))))

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
            (Register (reg.compiler-reg-group-pair-csr (- var 1))))]
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
  (define (compiler-reg-group-pair-placement-shapes?
    [assignments : reg.CompilerRegAssignmentTable]
    [caller-occupied : reg.CompilerRegAssignmentTable]
    [csr-assignments : reg.CompilerRegAssignmentTable]) : bool
    (let
      [assignment0 : reg.CompilerRegMaybeLocation
        (reg.compiler-reg-assignment-table-lookup assignments 0)]
      [assignment1 : reg.CompilerRegMaybeLocation
        (reg.compiler-reg-assignment-table-lookup assignments 1)]
      [caller0 : reg.CompilerRegMaybeLocation
        (reg.compiler-reg-assignment-table-lookup caller-occupied 0)]
      [caller1 : reg.CompilerRegMaybeLocation
        (reg.compiler-reg-assignment-table-lookup caller-occupied 1)]
      [csr0 : reg.CompilerRegMaybeLocation
        (reg.compiler-reg-assignment-table-lookup csr-assignments 0)]
      [csr1 : reg.CompilerRegMaybeLocation
        (reg.compiler-reg-assignment-table-lookup csr-assignments 1)]
      [csr2 : reg.CompilerRegMaybeLocation
        (reg.compiler-reg-assignment-table-lookup csr-assignments 2)]
      (and
        (match assignment0
          [(Some location)
            (match location
              [(RegisterPair first second)
                (and
                  (= first cabi.compiler-reg-id-r8)
                  (= second cabi.compiler-reg-id-r9))]
              [_ false])]
          [(No) false])
        (match assignment1
          [(Some location)
            (match location
              [(Register reg) (= reg cabi.compiler-reg-id-r12)]
              [_ false])]
          [(No) false])
        (match caller0
          [(Some location)
            (match location
              [(RegisterPair first second)
                (and
                  (= first cabi.compiler-reg-id-r8)
                  (= second cabi.compiler-reg-id-r9))]
              [_ false])]
          [(No) false])
        (match caller1
          [(Some location)
            (match location
              [(Spill _) true]
              [_ false])]
          [(No) false])
        (match csr0
          [(Some location)
            (match location
              [(RegisterPair first second)
                (and
                  (= first cabi.compiler-reg-id-r12)
                  (= second cabi.compiler-reg-id-r13))]
              [_ false])]
          [(No) false])
        (match csr1
          [(Some location)
            (match location
              [(Spill _) true]
              [_ false])]
          [(No) false])
        (match csr2
          [(Some location)
            (match location
              [(Spill _) true]
              [_ false])]
          [(No) false])))))

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
      (reg.compiler-reg-fill-i64-array
        (&mut shadow-regs)
        cabi.compiler-reg-id-invalid)
      (set! (array-ref members 0) 0)
      ;; Greedy worklist keys, not bare weights: the pair pass reads them
      ;; through compiler-reg-group-pair-weight, which strips the priority band
      ;; (compiler-reg-priority-keys!). Weights 1 and 10 on that scale.
      (reg.compiler-reg-fill-i64-array
        (&mut weights)
        (reg.compiler-reg-priority-band-span))
      (set! (array-ref weights 0) (* 10 (reg.compiler-reg-priority-band-span)))
      (let
        [v : i64 0]
        (while (< v vars)
          (set! (array-ref parents v) v)
          (set! (array-ref poisoned v) false)
          (set! v (+ v 1))))
      (set! (array-ref shadow-regs 1) cabi.compiler-reg-id-r8)
      (compiler-reg-group-pair-test-fill-homes! assignments 1 vars)
      (compiler-reg-group-pair-test-fill-homes! csr-assignments 1 vars)
      (compiler-reg-group-pair-test-fill-homes! caller-occupied 1 vars)
      (let
        [_nonoccupying-spill : reg.CompilerRegAssignmentTable
          (reg.compiler-reg-assignment-table-insert
            nonoccupying
            1
            (Spill (reg.compiler-reg-stack-slot-offset 1)))]
        [_nonoccupying-pair : reg.CompilerRegAssignmentTable
          (reg.compiler-reg-assignment-table-insert
            nonoccupying
            2
            (RegisterPair cabi.compiler-reg-id-r12 cabi.compiler-reg-id-r13))]
        [_caller-occupied-r8 : reg.CompilerRegAssignmentTable
          (reg.compiler-reg-assignment-table-insert
            caller-occupied
            1
            (Register cabi.compiler-reg-id-r8))]
        [_caller-occupied-r12 : reg.CompilerRegAssignmentTable
          (reg.compiler-reg-assignment-table-insert
            caller-occupied
            6
            (Register cabi.compiler-reg-id-r12))]
        [empty-split : reg.CompilerRegCallSplit
          (reg.compiler-reg-call-split-empty)]
        [shadow-split : reg.CompilerRegCallSplit
          (CompilerRegCallSplit
            (live.compiler-live-set-empty)
            shadow-regs
            (reg.compiler-reg-call-region-seq-push
              (reg.compiler-reg-call-region-seq-empty)
              (reg.CompilerRegCallRegion 1 0 10 0 0))
            (reg.compiler-reg-call-evict-seq-empty))]
        [phi-excluded : live.CompilerLiveI64Set
          (let
            [set-empty (live.compiler-live-set-empty)]
            [phi (irt.instr "%0 = phi  : Pair")]
            [set1 (live.compiler-live-set1 0)]
            (reg.compiler-reg-group-pair-excluded-instr set-empty phi set1))]
        [call-caller-unsafe : live.CompilerLiveI64Set
          (reg.compiler-reg-group-pair-caller-unsafe-instr
            (live.compiler-live-set-empty)
            (irt.instr "%1 = call callee(%0) : i64"))]
        [indirect-call-caller-unsafe : live.CompilerLiveI64Set
          (reg.compiler-reg-group-pair-caller-unsafe-instr
            (live.compiler-live-set-empty)
            (irt.instr "%1 = call* %2(%0) : i64"))]
        [indirect-c-call-caller-unsafe : live.CompilerLiveI64Set
          (reg.compiler-reg-group-pair-caller-unsafe-instr
            (live.compiler-live-set-empty)
            (irt.instr "%1 = call_c* %2(%0) : i64"))]
        [pair-conflicts : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
        [pair-conflict-count : i64
          (reg.compiler-reg-group-pair-conflict-vars!
            interval-index
            members
            1
            vars
            (&mut pair-conflicts))]
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
            (reg.compiler-reg-global-shared-view empty-split)
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
            (reg.compiler-reg-global-shared-view empty-split)
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
            (reg.compiler-reg-global-shared-view empty-split)
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
            (reg.compiler-reg-global-shared-view empty-split)
            cabi.compiler-reg-id-r12)]
        [_caller-placed : unit
          (let
            [ast-node-pool-reader-type-segment-bases
              (ast.ast-node-pool-reader-type-segment-bases)]
            [coalesce-test-i64-types
              (compiler-reg-coalesce-test-i64-types vars)]
            [set1 (live.compiler-live-set1 0)]
            [set-empty (live.compiler-live-set-empty)]
            [set-empty-b (live.compiler-live-set-empty)]
            [interval-index-copy
              (reg.compiler-reg-global-shared-view interval-index)]
            [caller-occupied-copy caller-occupied]
            [set-empty-2 (live.compiler-live-set-empty)]
            (reg.compiler-reg-assign-group-pair-component
              ast-node-pool-reader-type-segment-bases
              0
              vars
              coalesce-test-i64-types
              set1
              set-empty
              set-empty-b
              interval-index.starts
              interval-index.ends
              poisoned
              (&mut parents)
              (&mut members)
              interval-index-copy
              caller-occupied-copy
              weights
              set-empty-2
              (reg.compiler-reg-global-shared-view empty-split)))]
        [_csr-placed : unit
          (let
            [ast-node-pool-reader-type-segment-bases
              (ast.ast-node-pool-reader-type-segment-bases)]
            [coalesce-test-i64-types
              (compiler-reg-coalesce-test-i64-types vars)]
            [set1 (live.compiler-live-set1 0)]
            [set-empty (live.compiler-live-set-empty)]
            [set1-b (live.compiler-live-set1 0)]
            [interval-index-copy
              (reg.compiler-reg-global-shared-view interval-index)]
            [csr-assignments-copy csr-assignments]
            [set-empty-2 (live.compiler-live-set-empty)]
            (reg.compiler-reg-assign-group-pair-component
              ast-node-pool-reader-type-segment-bases
              0
              vars
              coalesce-test-i64-types
              set1
              set-empty
              set1-b
              interval-index.starts
              interval-index.ends
              poisoned
              (&mut parents)
              (&mut members)
              interval-index-copy
              csr-assignments-copy
              weights
              set-empty-2
              (reg.compiler-reg-global-shared-view empty-split)))]
        [_placed : unit
          (let
            [ast-node-pool-reader-type-segment-bases
              (ast.ast-node-pool-reader-type-segment-bases)]
            [coalesce-test-i64-types
              (compiler-reg-coalesce-test-i64-types vars)]
            [set1 (live.compiler-live-set1 0)]
            [set-empty (live.compiler-live-set-empty)]
            [set-empty-b (live.compiler-live-set-empty)]
            [interval-index-copy
              (reg.compiler-reg-global-shared-view interval-index)]
            [assignments-copy assignments]
            [set-empty-2 (live.compiler-live-set-empty)]
            (reg.compiler-reg-assign-group-pair-component
              ast-node-pool-reader-type-segment-bases
              0
              vars
              coalesce-test-i64-types
              set1
              set-empty
              set-empty-b
              interval-index.starts
              interval-index.ends
              poisoned
              (&mut parents)
              (&mut members)
              interval-index-copy
              assignments-copy
              weights
              set-empty-2
              empty-split))]
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
          (let
            [interval-index-copy
              (reg.compiler-reg-global-shared-view interval-index)]
            [set-empty (live.compiler-live-set-empty)]
            (reg.compiler-reg-group-pair-component-clobber-free?
              interval-index-copy
              set-empty
              members
              1))
          (not
            (let
              [set1 (live.compiler-live-set1 5)]
              (reg.compiler-reg-group-pair-component-clobber-free?
                interval-index
                set1
                members
                1)))
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
          (compiler-reg-group-pair-placement-shapes?
            assignments
            caller-occupied
            csr-assignments))))))

(cfg
  test
  (define (compiler-reg-test-interval-shape?
    [items : (& items reg.CompilerRegIntervalSeq)]
    [index : i64]
    [var : i64]
    [start : i64]
    [end : i64]) : bool
    (let
      [got : reg.CompilerRegInterval (array-ref items.slots index)]
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
      ;; Cross several capacity boundaries in both construction directions.
      (while (< i 10)
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
        (set! i (+ i 1)))
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
        (reg.compiler-reg-interval-seq-overlaps? zero-left zero-right)))))

(cfg
  test
  (test
    regalloc-dense-interval-sequence
    (test.assert-true
      (compiler-reg-dense-interval-seq-ok?)
      "dense interval growth preserves order and merge overlap boundaries")))

(cfg
  test
  (define (compiler-reg-dense-id-seqs-ok?) : bool
    (let
      [ids : reg.CompilerRegIdSeq (reg.compiler-reg-id-seq-with-capacity 4)]
      [id-snapshot : reg.CompilerRegIdSeq (reg.compiler-reg-id-seq-empty)]
      [id-prepended : reg.CompilerRegIdSeq (reg.compiler-reg-id-seq-empty)]
      (set! ids (reg.compiler-reg-id-seq-push ids cabi.compiler-reg-id-r12))
      (set! ids (reg.compiler-reg-id-seq-push ids cabi.compiler-reg-id-r13))
      ;; A retained snapshot has an exact logical length and prefix even while
      ;; the continuing builder fills its spare suffix.
      (set! id-snapshot (clone ids))
      (set! ids (reg.compiler-reg-id-seq-push ids cabi.compiler-reg-id-r12))
      (set!
        id-prepended
        (reg.compiler-reg-id-seq-prepend
          cabi.compiler-reg-id-rbx
          (reg.compiler-reg-global-shared-view id-snapshot)))
      (and
        (= (reg.compiler-reg-id-seq-count id-snapshot) 2)
        (= (reg.compiler-reg-id-seq-ref id-snapshot 0) cabi.compiler-reg-id-r12)
        (= (reg.compiler-reg-id-seq-ref id-snapshot 1) cabi.compiler-reg-id-r13)
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
          cabi.compiler-reg-id-r13)))))

(cfg
  test
  (test
    regalloc-dense-register-sequences
    (test.assert-true
      (compiler-reg-dense-id-seqs-ok?)
      "dense register sequences preserve snapshots, order, and duplicates")))

(cfg
  test
  (define (compiler-reg-dense-var-types-ok?) : bool
    (let
      [base : reg.CompilerRegVarTypes
        (reg.compiler-reg-var-types-insert
          (reg.compiler-reg-var-types-insert
            (reg.compiler-reg-var-types-empty)
            2
            (I64))
          5
          (U64))]
      [extra : reg.CompilerRegVarTypes
        (reg.compiler-reg-var-types-insert
          (reg.compiler-reg-var-types-empty)
          5
          (Bool))]
      [merged : reg.CompilerRegVarTypes
        (reg.compiler-reg-var-types-merge extra base)]
      (and
        (= (array-ref (reg.compiler-reg-var-types-present base) 2) 1)
        (= (array-ref (reg.compiler-reg-var-types-present base) 3) 0)
        (match (reg.compiler-reg-var-types-lookup base 2)
          [(Some (I64)) true]
          [_ false])
        (match (reg.compiler-reg-var-types-lookup base 3)
          [(No) true]
          [_ false])
        ;; Merge overrides a present extra entry without mutating the published
        ;; base view retained by retry paths.
        (match (reg.compiler-reg-var-types-lookup base 5)
          [(Some (U64)) true]
          [_ false])
        (match (reg.compiler-reg-var-types-lookup merged 5)
          [(Some (Bool)) true]
          [_ false])))))

(cfg
  test
  (test
    regalloc-dense-var-types
    (test.assert-true
      (compiler-reg-dense-var-types-ok?)
      "dense var types preserve holes, exact types, growth, and merge isolation")))

;; SEL-1. A scalar `select` (lanes 0) defines a typed scalar value the
;; function's type table must carry -- it is the register-eligibility and
;; coalescing key for the cmov result -- while a vector select (lanes > 0)
;; stays out of the scalar table.
(cfg
  test
  (define (compiler-reg-select-var-types-function) : ir.CompilerIrFunction
    (Function
      (ir.compiler-ir-test-symbol "select_var_types")
      (ir.compiler-ir-param-seq-empty)
      (compiler-reg-i64-ty)
      5
      (ir.compiler-ir-blocks
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "%0 = mov 7 : i64")
            (compiler-reg-test-instr-seq-prepend
              (irt.instr "%1 = mov 9 : i64")
              (compiler-reg-test-instr-seq-prepend
                (irt.instr "%2 = lt %0, %1 : i64")
                (compiler-reg-test-instr-seq-prepend
                  (ir.ir-instr-select
                    3
                    (Var 2)
                    (Var 0)
                    (Var 1)
                    0
                    (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.ir-instr-select
                      4
                      (Var 2)
                      (Var 0)
                      (Var 1)
                      4
                      (compiler-reg-i64-ty))
                    (irt.instrs "return %3"))))))))
      Ordinary)))

(cfg
  test
  (define (compiler-reg-select-var-types-ok?) : bool
    (let
      [types : reg.CompilerRegVarTypes
        (let
          [func (compiler-reg-select-var-types-function)]
          (reg.compiler-reg-function-var-types func))]
      (and
        (match (reg.compiler-reg-var-types-lookup types 3)
          [(Some (I64)) true]
          [_ false])
        (match (reg.compiler-reg-var-types-lookup types 4)
          [(No) true]
          [_ false])))))

(cfg
  test
  (test
    regalloc-select-var-types
    (test.assert-true
      (compiler-reg-select-var-types-ok?)
      "a scalar select's result is typed in the var table; a vector select's is not")))

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
    (ir.compiler-ir-blocks
      (irt.block "entry:
           %1 = mov 7 : i64
           jump merge")
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "merge")
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%0 = phi [%1, entry] : i64")
          (compiler-reg-test-instr-seq-prepend
            (Return
              (Some
                (Var
                  (if live-after-phi
                    1
                    0))))
            (ir.compiler-ir-instr-seq-empty)))))))

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
    (compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (Plan
        (compiler-reg-color-spill-sharing-assignments 2)
        (live.compiler-live-set-empty)
        (compiler-reg-color-phi-web-intervals)
        (compiler-reg-color-spill-sharing-types 2)
        (reg.compiler-reg-call-split-empty))
      (live.compiler-live-set-empty)
      (ir.compiler-ir-param-seq-empty)
      (compiler-reg-color-phi-web-blocks live-after-phi)
      2
      2
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-phi-web-slot-sharing-ok?) : bool
    (match (compiler-reg-color-phi-web-coloring false)
      [(Remap share-remap share-slots)
        (match (compiler-reg-color-phi-web-coloring true)
          [(Remap live-remap live-slots)
            (and
              (= share-slots 1)
              (= (array-ref share-remap 0) (array-ref share-remap 1))
              (= live-slots 2)
              (not (= (array-ref live-remap 0) (array-ref live-remap 1))))]
          [(None) false])]
      [(None) false])))

;; M-B3 order-independent web construction. The loop below is the shape every
;; spilled loop carry in intern_table's it-intern-slice has: a header phi (%0)
;; fed by an entry constant (%3) and by a latch phi (%2), with a third phi (%1)
;; on the path between them. All four EP hulls are pairwise disjoint --
;; %3 dies in `entry`, %0 in `body`, %1 in `merge`, %2 in `latch` -- so ONE slot
;; serves the whole chain.
;;
;; A monotone rule cannot see that. Visiting `header` first it joins %2 to %0
;; (the only pair whose hulls are ordered the way the rule wants), which pushes
;; the web's running end out to %2's; %3 and %1 both start before that end and
;; are refused even though neither overlaps anything in the web, and %1's own
;; web can never be joined to a second web anyway, leaving 3 slots and two
;; slot-to-slot phi copies per iteration. With all-pairs disjointness plus
;; web-to-web merging the chain collapses to 1 slot.
;;
;; `overlap` injects a genuine interference to prove the test still refuses: the
;; exit returns %1, so %1 stays live from `merge` past `latch` and really does
;; overlap %2. %1 must then keep its own slot.
(cfg
  test
  (define (compiler-reg-color-web-merge-blocks [overlap : bool]) : ir.CompilerIrBlockList
    (ir.compiler-ir-blocks
      (irt.block "entry:
           %3 = mov 7 : i64
           jump header")
      (irt.block
        "header:
             %0 = phi [%2, latch], [%3, entry] : i64
             branch %0, body, exit")
      (irt.block "body:
               jump merge")
      (irt.block
        "merge:
                 %1 = phi [%0, body] : i64
                 jump latch")
      (irt.block
        "latch:
                   %2 = phi [%1, merge] : i64
                   jump header")
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "exit")
        (compiler-reg-test-instr-seq-prepend
          (Return
            (Some
              (if overlap
                (Var 1)
                (I64 0))))
          (ir.compiler-ir-instr-seq-empty))))))

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
    (compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (Plan
        (compiler-reg-color-spill-sharing-assignments 4)
        (live.compiler-live-set-empty)
        (compiler-reg-color-web-merge-intervals)
        (compiler-reg-color-spill-sharing-types 4)
        (reg.compiler-reg-call-split-empty))
      (live.compiler-live-set-empty)
      (ir.compiler-ir-param-seq-empty)
      (compiler-reg-color-web-merge-blocks overlap)
      4
      4
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-web-merge-ok?) : bool
    (match (compiler-reg-color-web-merge-coloring false)
      [(Remap merged-remap merged-slots)
        (match (compiler-reg-color-web-merge-coloring true)
          [(Remap overlap-remap overlap-slots)
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
          [(None) false])]
      [(None) false])))

;; The induction-step witness. Same fixture idea as the web-merge case above, cut
;; down to the counter itself: `%0 = phi(%2 entry, %1 latch)` with the back-edge
;; value produced by `%1 = %0 + 1` -- a BinOp, which is what every counted loop
;; writes and what a Mov-only witness cannot see. The two hulls TOUCH at the
;; step (the counter's last event and the step's definition are the same
;; instruction), so the all-pairs disjointness rule alone refuses them and the
;; pair would cost a second slot plus a slot-to-slot phi copy on the back edge.
;;
;; `outlives` is the negative: `exit` returns the COUNTER, so %0's hull runs past
;; the step into a later block and the equality that carries the witness no longer
;; holds. The step must then keep its own slot -- exactly the case where sharing
;; one home would clobber a value still to be read.
(cfg
  test
  (define (compiler-reg-color-step-witness-blocks [outlives : bool]) : ir.CompilerIrBlockList
    (ir.compiler-ir-blocks
      (irt.block "entry:
           %2 = mov 0 : i64
           jump header")
      (irt.block
        "header:
             %0 = phi [%1, latch], [%2, entry] : i64
             branch %0, body, exit")
      (irt.block
        "body:
               %1 = add %0, 1 : i64
               jump latch")
      (irt.block "latch:
                 jump header")
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "exit")
        (compiler-reg-test-instr-seq-prepend
          (Return
            (Some
              (if outlives
                (Var 0)
                (I64 0))))
          (ir.compiler-ir-instr-seq-empty))))))

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
    (compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (Plan
        (compiler-reg-color-spill-sharing-assignments 3)
        (live.compiler-live-set-empty)
        (compiler-reg-color-step-witness-intervals)
        (compiler-reg-color-spill-sharing-types 3)
        (reg.compiler-reg-call-split-empty))
      (live.compiler-live-set-empty)
      (ir.compiler-ir-param-seq-empty)
      (compiler-reg-color-step-witness-blocks outlives)
      3
      3
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-step-witness-ok?) : bool
    (match (compiler-reg-color-step-witness-coloring false)
      [(Remap step-remap step-slots)
        (match (compiler-reg-color-step-witness-coloring true)
          [(Remap live-remap live-slots)
            (and
              ;; Counter, its step and the entry seed all share ONE slot, so the
              ;; back-edge phi copy is a same-home no-op.
              (= step-slots 1)
              (= (array-ref step-remap 0) (array-ref step-remap 1))
              (= (array-ref step-remap 0) (array-ref step-remap 2))
              ;; A counter still live past its step keeps its own home.
              (> live-slots 1)
              (not (= (array-ref live-remap 0) (array-ref live-remap 1))))]
          [(None) false])]
      [(None) false])))

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
;; of its own, but not the one being offered. A single-pair rule refuses it
;; there, and offering %2 again through the MOV witness meets the %1/%2 touch
;; and refuses it again, so the add's result would take a second slot and the
;; block would store one register to two slots every iteration.
;;
;; `outlives` is the negative: `exit` returns %2, so %2 is still live where %3
;; is defined, the endpoint equality that carries the witness no longer holds,
;; and %2 must keep its own home.
(cfg
  test
  (define (compiler-reg-color-witness-chain-blocks [outlives : bool]) : ir.CompilerIrBlockList
    (ir.compiler-ir-blocks
      (irt.block "entry:
           %4 = mov 0 : i64
           jump header")
      (irt.block
        "header:
             %0 = phi [%3, latch], [%4, entry] : i64
             branch %0, body, exit")
      (irt.block
        "body:
               %1 = mul %0, 3 : i64
               %2 = add %1, 5 : i64
               %3 = mov %2 : i64
               jump latch")
      (irt.block "latch:
                 jump header")
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "exit")
        (compiler-reg-test-instr-seq-prepend
          (Return
            (Some
              (if outlives
                (Var 2)
                (I64 0))))
          (ir.compiler-ir-instr-seq-empty))))))

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
    (compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (Plan
        (compiler-reg-color-spill-sharing-assignments 5)
        (live.compiler-live-set-empty)
        (compiler-reg-color-witness-chain-intervals)
        (compiler-reg-color-spill-sharing-types 5)
        (reg.compiler-reg-call-split-empty))
      (live.compiler-live-set-empty)
      (ir.compiler-ir-param-seq-empty)
      (compiler-reg-color-witness-chain-blocks outlives)
      5
      5
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-witness-chain-ok?) : bool
    (match (compiler-reg-color-witness-chain-coloring false)
      [(Remap chain-remap chain-slots)
        (match (compiler-reg-color-witness-chain-coloring true)
          [(Remap live-remap live-slots)
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
          [(None) false])]
      [(None) false])))

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
    (irt.blocks
      "entry:
         %4 = mov 7 : i64
         jump header
       header:
         %0 = phi [%3, latch], [%4, entry] : i64
         branch %0, left, right
       left:
         %1 = mov 9 : i64
         jump merge
       right:
         jump merge
       merge:
         %2 = phi [%1, left], [%0, right] : i64
         jump latch
       latch:
         %3 = phi [%2, merge] : i64
         jump header")))

(cfg
  test
  (define (compiler-reg-color-carry-priority-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 4 4 11)
      (compiler-reg-color-web-merge-intervals))))

(cfg
  test
  (define (compiler-reg-color-carry-priority-coloring) : reg.CompilerRegColoring
    (compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (Plan
        (compiler-reg-color-spill-sharing-assignments 5)
        (live.compiler-live-set-empty)
        (compiler-reg-color-carry-priority-intervals)
        (compiler-reg-color-spill-sharing-types 5)
        (reg.compiler-reg-call-split-empty))
      (live.compiler-live-set-empty)
      (ir.compiler-ir-param-seq-empty)
      (compiler-reg-color-carry-priority-blocks)
      5
      5
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-carry-priority-ok?) : bool
    (match (compiler-reg-color-carry-priority-coloring)
      [(Remap remap _)
        (and
          ;; The merge phi lands in the loop carry's web ...
          (= (array-ref remap 2) (array-ref remap 0))
          ;; ... and NOT in the computed value's, which interferes with it.
          (not (= (array-ref remap 2) (array-ref remap 1))))]
      [(None) false])))

(define (compiler-regalloc-self-test-failure-message [name : String]) : String
  (str_cat.str-cat "regalloc self-test failed: " name))

(define (compiler-regalloc-self-test-require! [name : String] [ok : bool]) : unit
  (if ok
    unit
    (io.panic (compiler-regalloc-self-test-failure-message name))))

;; `(require-each! (p args ...) ...)` requires each check in order, and names a
;; failed check after its callee. A `(cfg test (p ...) true)` check reads as
;; `true` outside test builds and requires nothing there.
(defmacro (require-each! [checks : comptime.Expr ...]) : unit
  (let
    [out : comptime.ExprList (comptime.expr-list-empty)]
    [i : i64 (comptime.expr-list-length checks)]
    (while (> i 0)
      (set! i (- i 1))
      (let
        [check : comptime.Expr (comptime.expr-list-nth checks i)]
        (match check
          [(comptime.Expr.Call head _)
            (match head
              [(comptime.Expr.Var name)
                (set!
                  out
                  (comptime.expr-list-cons
                    `(compiler-regalloc-self-test-require!
                      ,(comptime.expr-string name)
                      ,check)
                    out))]
              [_
                (comptime.comptime-error
                  "require-each! checks call a named predicate")])]
          [(comptime.Expr.Bool always)
            (if always
              unit
              (comptime.comptime-error
                "require-each! checks call a named predicate"))]
          [_
            (comptime.comptime-error
              "require-each! checks call a named predicate")])))
    `(begin
      ,@out
      unit)))

(define (compiler-reg-location-remat? [location : reg.CompilerRegLocation]) : bool
  (match location
    [(Remat _) true]
    [_ false]))

(define (compiler-reg-maybe-location-remat?
  [maybe-location : reg.CompilerRegMaybeLocation]) : bool
  (match maybe-location
    [(Some location) (compiler-reg-location-remat? location)]
    [(No) false]))

(define (compiler-reg-location-spill-offset?
  [maybe-location : reg.CompilerRegMaybeLocation]
  [offset : i64]) : bool
  (match maybe-location
    [(Some location)
      (match location
        [(Spill found) (= found offset)]
        [_ false])]
    [_ false]))

(define (compiler-reg-unassigned?
  [assignments : reg.CompilerRegAssignmentTable]
  [var : i64]) : bool
  (match (reg.compiler-reg-assignment-lookup assignments var)
    [(No) true]
    [_ false]))

(define (compiler-reg-location-any-register?
  [maybe-location : reg.CompilerRegMaybeLocation]) : bool
  (match maybe-location
    [(Some location)
      (match location
        [(Register _) true]
        [(RegisterPair _ _) true]
        [_ false])]
    [_ false]))

(define (compiler-reg-early-scratch-test-function) : ir.CompilerIrFunction
  (irt.func
    "function @early_scratch_literal_divmod() -> i64 vars 2 {
     entry:
       %0 = mov 42 : i64
       %1 = safe_mod %0, 7 : i64
       return %1
     }"))

(define (compiler-reg-early-scratch-nontarget-blocks) : ir.CompilerIrBlockList
  (irt.blocks
    "entry:
       bounds_check %0, 8 message \"ok\"
       switch %0 base 1 [] default other
       %1 = safe_mod %0, %1 : i64
       %1 = mod %0, 7 : i64"))

(define (compiler-reg-early-scratch-slot-range-ok?
  [model : (& model reg.CompilerRegEarlyScratchModel)]
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
        [segments : reg.CompilerRegIntervalSeq
          (reg.compiler-reg-global-array-element-shared-view index.segments var)]
        (and
          (= (reg.compiler-reg-interval-seq-count segments) 1)
          (let
            [found : reg.CompilerRegInterval
              (reg.compiler-reg-interval-seq-ref segments 0)]
            (and (= found.var var) (= found.start lo) (= found.end hi))))))))

(define (compiler-reg-early-scratch-model-for-test) : reg.CompilerRegEarlyScratchModel
  (let
    [func : ir.CompilerIrFunction (compiler-reg-early-scratch-test-function)]
    [types : reg.CompilerRegVarTypes (reg.compiler-reg-function-var-types func)]
    (match (reg.compiler-reg-live-interval-selection
      (ir.compiler-ir-global-shared-view func)
      (live.compiler-live-analyze-function
        (ir.compiler-ir-global-shared-view func)))
      [(Selection _ index)
        (reg.compiler-reg-early-scratch-model
          func
          index
          types
          (reg.compiler-reg-assignment-table-insert
            (reg.compiler-reg-assignment-table-make 2)
            0
            (Register cabi.compiler-reg-id-r10))
          true)])))

(define (compiler-reg-early-scratch-model-divmod-ok?) : bool
  (let
    [model : reg.CompilerRegEarlyScratchModel
      (compiler-reg-early-scratch-model-for-test)]
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
        (reg.compiler-reg-global-array-element-shared-view excluded (+ base 2))
        cabi.compiler-reg-id-r10)
      (reg.compiler-reg-id-seq-contains?
        (reg.compiler-reg-global-array-element-shared-view excluded (+ base 3))
        cabi.compiler-reg-id-r10)
      (reg.compiler-reg-id-seq-contains?
        (reg.compiler-reg-global-array-element-shared-view excluded (+ base 4))
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
        [(No) true]
        [_ false])
      (match (reg.compiler-reg-assignment-table-lookup assignments (+ base 3))
        [(No) true]
        [_ false])
      (match (reg.compiler-reg-assignment-table-lookup assignments (+ base 4))
        [(No) true]
        [_ false]))))

(define (compiler-reg-early-scratch-model-ok?) : bool
  (and
    (=
      (reg.compiler-reg-early-scratch-count-blocks
        (compiler-reg-early-scratch-nontarget-blocks))
      0)
    (compiler-reg-early-scratch-model-divmod-ok?)))

;; Occupancy fixture: the SysV greedy integer pool followed by XMM0, XMM1 and
;; the target's allocatable XMM registers.
(define (compiler-reg-test-register-array
  [target-abi : cabi.CompilerRegTargetAbi]) : (__tl_dyn-array i64)
  (let
    [xmm-registers : reg.CompilerRegIdSeq
      (reg.compiler-reg-id-seq-prepend
        (cabi.compiler-abi-xmm-register-id 0)
        (reg.compiler-reg-id-seq-prepend
          (cabi.compiler-abi-xmm-register-id 1)
          (reg.compiler-reg-xmm-registers-for-abi target-abi)))]
    [registers : reg.CompilerRegIdSeq
      (reg.compiler-reg-id-seq-append
        (reg.compiler-reg-greedy-integer-pool-for-abi (Linux))
        xmm-registers)]
    [out : (__tl_dyn-array i64)
      (__tl_make-array i64 (reg.compiler-reg-id-seq-count registers))]
    (reg.compiler-reg-greedy-id-seq-to-array registers (&mut out) 0)
    out))

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
      (compiler-reg-test-register-array (Linux))]
    (reg.compiler-reg-fill-i64-array (&mut starts) -1)
    (reg.compiler-reg-fill-i64-array (&mut ends) -1)
    (reg.compiler-reg-fill-interval-seq-array! (&mut segments) 0)
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
          (reg.compiler-reg-global-shared-view index)
          registers
          (array-length registers))]
      [resident-0-ok? : bool false]
      [emptied-ok? : bool false]
      [multi-ok? : bool false]
      [coarse-resident-ok? : bool false]
      (reg.compiler-reg-greedy-occupancy-assign! occupancy 0 0 -1)
      (set!
        resident-0-ok?
        (and
          ;; touch at 4 is half-open, so [4,8) may share the register
          (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 1 0)
          ;; [3,6) genuinely overlaps [0,4)
          (not
            (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 2 0))
          ;; a point-0 touch counts as overlap (M-A RC1)
          (not
            (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 3 0))
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
            (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 6 0))))
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
            (reg.compiler-reg-greedy-reg-free? occupancy index ref-counts 1 0))))
      (and resident-0-ok? emptied-ok? multi-ok? coarse-resident-ok?))))

(define (compiler-reg-scratch-borrow-masks-ok?) : bool
  (and
    ;; The scratch-borrow estimator follows the same ABI split as the backend:
    ;; %rsi is an unconditional candidate on SysV, but on Win64 it is available
    ;; only through the plan-saved nonvolatile mask.
    (not
      (=
        (bit-and
          (reg.compiler-reg-scratch-borrow-volatile-mask (Linux))
          (reg.compiler-reg-scratch-reg-bit cabi.compiler-reg-id-rsi))
        0))
    (=
      (bit-and
        (reg.compiler-reg-scratch-borrow-csr-mask (Linux))
        (reg.compiler-reg-scratch-reg-bit cabi.compiler-reg-id-rsi))
      0)
    (=
      (bit-and
        (reg.compiler-reg-scratch-borrow-volatile-mask (Windows))
        (reg.compiler-reg-scratch-reg-bit cabi.compiler-reg-id-rsi))
      0)
    (not
      (=
        (bit-and
          (reg.compiler-reg-scratch-borrow-csr-mask (Windows))
          (reg.compiler-reg-scratch-reg-bit cabi.compiler-reg-id-rsi))
        0))))

(define (compiler-reg-early-scratch-never-spills-ok?) : bool
  (let
    [intervals : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 4)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 1 3)
          (reg.compiler-reg-interval-seq-empty)))]
    [index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build
        (reg.compiler-reg-global-shared-view intervals)
        2)]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 2)
        0
        (Register cabi.compiler-reg-id-r12))]
    [base-weights : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [raw-weights : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [scratch-weights : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [weights : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [hints : (__tl_dyn-array i64) (__tl_make-array i64 2)]
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
    (reg.compiler-reg-fill-i64-array (&mut hints) -1)
    (match (let
      [regs
        (reg.compiler-reg-id-seq-prepend
          cabi.compiler-reg-id-r12
          (reg.compiler-reg-id-seq-empty))]
      [group-vars (live.compiler-live-set-empty)]
      [param-roots (live.compiler-live-set-empty)]
      [param-entry-forbidden (__tl_make-array reg.CompilerRegIdSeq 0)]
      [call-points (live.compiler-live-set-empty)]
      [div-points (live.compiler-live-set-empty)]
      [shift-points (live.compiler-live-set-empty)]
      (reg.compiler-reg-greedy-state
        intervals
        regs
        assignments
        index
        group-vars
        param-roots
        param-entry-forbidden
        (reg.compiler-reg-global-shared-view weights)
        hints
        (reg.compiler-reg-global-shared-view hints)
        call-points
        div-points
        shift-points
        (reg.compiler-reg-id-seq-prepend
          cabi.compiler-reg-id-r12
          (reg.compiler-reg-id-seq-empty))
        0
        1))
      [(State _ out)
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
            cabi.compiler-reg-id-r12))])))

(define (compiler-reg-early-scratch-exclusion-rehomes-ok?) : bool
  (let
    [intervals : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 4)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 1 3)
          (reg.compiler-reg-interval-seq-empty)))]
    [index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build
        (reg.compiler-reg-global-shared-view intervals)
        2)]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 2)
        0
        (Register cabi.compiler-reg-id-r12))]
    [weights : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [hints : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [excluded : (__tl_dyn-array reg.CompilerRegIdSeq)
      (__tl_make-array reg.CompilerRegIdSeq 2)]
    ;; Greedy worklist keys (weight * band span + band), not bare weights:
    ;; the eviction gate strips the band with compiler-reg-priority-key-weight.
    (set! (array-ref weights 0) (reg.compiler-reg-priority-band-span))
    (set! (array-ref weights 1) (* 2 (reg.compiler-reg-priority-band-span)))
    (reg.compiler-reg-fill-i64-array (&mut hints) -1)
    ;; %r10 is free but is the instruction operand home. The scratch pseudo
    ;; must instead evict the colder, CSR-only real value from %r12; when that
    ;; value is requeued it has no legal register and receives a real spill.
    (set!
      (array-ref excluded 1)
      (reg.compiler-reg-id-seq-prepend
        cabi.compiler-reg-id-r10
        (reg.compiler-reg-id-seq-empty)))
    (match (let
      [regs
        (reg.compiler-reg-id-seq-prepend
          cabi.compiler-reg-id-r10
          (reg.compiler-reg-id-seq-prepend
            cabi.compiler-reg-id-r12
            (reg.compiler-reg-id-seq-empty)))]
      [group-vars (live.compiler-live-set-empty)]
      [param-roots
        (live.compiler-live-set-insert (live.compiler-live-set-empty) 0)]
      [param-entry-forbidden (__tl_make-array reg.CompilerRegIdSeq 0)]
      [call-points (live.compiler-live-set-empty)]
      [div-points (live.compiler-live-set-empty)]
      [shift-points (live.compiler-live-set-empty)]
      (reg.compiler-reg-greedy-state-with-scratch-exclusions
        intervals
        regs
        assignments
        index
        group-vars
        param-roots
        param-entry-forbidden
        weights
        hints
        (reg.compiler-reg-global-shared-view hints)
        call-points
        div-points
        shift-points
        (reg.compiler-reg-id-seq-prepend
          cabi.compiler-reg-id-r12
          (reg.compiler-reg-id-seq-empty))
        1
        1
        excluded))
      [(State _ out)
        (and
          (compiler-reg-location-spill-offset?
            (reg.compiler-reg-assignment-table-lookup out 0)
            (reg.compiler-reg-stack-slot-offset 0))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-table-lookup out 1)
            cabi.compiler-reg-id-r12))])))

(define (compiler-reg-i64-ty) : ast.AstType
  (I64))

(define (compiler-reg-f64-ty) : ast.AstType
  (F64))

(define (compiler-reg-reuse-function) : ir.CompilerIrFunction
  (irt.func
    "function @reuse() -> unit vars 2 {
     entry:
       %0 = mov 1 : i64
       store @g0, %0 : i64
       %1 = mov 2 : i64
       return %1
     }"))

(define (compiler-reg-f64-reuse-function) : ir.CompilerIrFunction
  (irt.func
    "function @f64_reuse() -> f64 vars 2 {
     entry:
       %0 = mov float-bits:4609434218613702656 : f64
       store @g0, %0 : f64
       %1 = mov float-bits:4612811918334230528 : f64
       return %1
     }"))

(define (compiler-reg-overlap-function) : ir.CompilerIrFunction
  (irt.func
    "function @overlap() -> unit vars 8 {
     entry:
       %0 = mov 0 : i64
       %1 = mov 1 : i64
       %2 = mov 2 : i64
       %3 = mov 3 : i64
       %4 = mov 4 : i64
       %5 = mov 5 : i64
       %6 = mov 6 : i64
       store @g0, %0 : i64
       store @g1, %1 : i64
       store @g2, %2 : i64
       store @g3, %3 : i64
       store @g4, %4 : i64
       store @g5, %5 : i64
       store @g6, %6 : i64
       return
     }"))

(define (compiler-reg-f64-overlap-function) : ir.CompilerIrFunction
  (irt.func
    "function @f64_overlap() -> unit vars 5 {
     entry:
       %0 = mov float-bits:4602678819172646912 : f64
       %1 = mov float-bits:4609434218613702656 : f64
       %2 = mov float-bits:4612811918334230528 : f64
       %3 = mov float-bits:4615063718147915776 : f64
       %4 = mov float-bits:4616752568008179712 : f64
       store @g0, %0 : f64
       store @g1, %1 : f64
       store @g2, %2 : f64
       store @g3, %3 : f64
       store @g4, %4 : f64
       return
     }"))

(define (compiler-reg-call-live-function) : ir.CompilerIrFunction
  (irt.func
    "function @call_live() -> unit vars 3 {
     entry:
       %0 = mov 9 : i64
       %1 = call side_effect() : unit
       %2 = mov %0 : i64
       return %2
     }"))

(define (compiler-reg-f64-call-live-function) : ir.CompilerIrFunction
  (irt.func
    "function @f64_call_live() -> f64 vars 3 {
     entry:
       %0 = mov float-bits:4621537642612260864 : f64
       %1 = call side_effect() : unit
       %2 = mov %0 : f64
       return %2
     }"))

(define (compiler-reg-call-arg-function) : ir.CompilerIrFunction
  (irt.func
    "function @call_arg() -> unit vars 4 {
     entry:
       %0 = mov 1 : i64
       %1 = mov 2 : i64
       %2 = call use_args(%0, %1) : unit
       %3 = mov 3 : i64
       return %3
     }"))

(define (compiler-reg-f64-call-arg-function) : ir.CompilerIrFunction
  (irt.func
    "function @f64_call_arg() -> f64 vars 3 {
     entry:
       %0 = mov float-bits:4609434218613702656 : f64
       %1 = call takes_f64(%0) : unit
       %2 = mov float-bits:4612811918334230528 : f64
       return %2
     }"))

;; M-A2 fixture: a direct call mixing a HANDLE arg (8-byte Array descriptor
;; pointer, var 0, produced by a call so it is not remat-classified) with a
;; scalar arg (var 1). Every arg is single-GP-register passed, and var 0 is
;; used again after the call, so it spans the call point.
(define (compiler-reg-handle-call-arg-function) : ir.CompilerIrFunction
  (irt.func
    "function @handle_call_arg() -> unit vars 4 {
     entry:
       %0 = call make_handle() : (__tl_dyn-array i64)
       %1 = mov 2 : i64
       %2 = call use_args(%0, %1) : unit
       %3 = mov %0 : (__tl_dyn-array i64)
       return
     }"))

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
  (Function
    (ir.compiler-ir-test-symbol "indirect_call_arg")
    (ir.compiler-ir-param-seq-prepend
      (Param "callee" (compiler-reg-func2-ty) 0)
      (irt.params "a=%1:i64, b=%2:i64"))
    (compiler-reg-i64-ty)
    4
    (irt.blocks
      "entry:
         %3 = call* %0(%1, %2) : i64
         return %3")
    Ordinary))

(define (compiler-reg-indirect-call-arg4-function) : ir.CompilerIrFunction
  (let
    [args : (__tl_dyn-array ir.CompilerIrValue)
      (__tl_make-array ir.CompilerIrValue 4)]
    (set! (array-ref args 0) (ir.CompilerIrValue.Var 1))
    (set! (array-ref args 1) (ir.CompilerIrValue.Var 2))
    (set! (array-ref args 2) (ir.CompilerIrValue.Var 3))
    (set! (array-ref args 3) (ir.CompilerIrValue.Var 4))
    (Function
      (ir.compiler-ir-test-symbol "indirect_call_arg4")
      (ir.compiler-ir-param-seq-prepend
        (Param "callee" (compiler-reg-func4-ty) 0)
        (irt.params "a=%1:i64, b=%2:i64, c=%3:i64, d=%4:i64"))
      (compiler-reg-i64-ty)
      6
      (ir.compiler-ir-blocks
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-reg-test-instr-seq-prepend
            (CallIndirect 5 (Var 0) (Array args) (compiler-reg-i64-ty))
            (irt.instrs "return %5"))))
      Ordinary)))

(define (compiler-reg-c-abi-store-result-arg-function) : ir.CompilerIrFunction
  (Function
    (ir.compiler-ir-test-symbol "c_abi_store_result_arg")
    (irt.params "base=%0:i64, a=%1:i64, b=%2:i64")
    (Unit)
    3
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (ir.ir-instr-call-cabi-store-result
            (Var 0)
            (ir.compiler-ir-test-symbol "c_ret_pair")
            (Two (Var 1) (Var 2))
            (ir.CompilerIrCAbiReturnSlotSeq
              (__tl_make-array ir.CompilerIrCAbiReturnSlot 0)
              0))
          (irt.instrs "return"))))
    Ordinary))

(define (compiler-reg-ineligible-function) : ir.CompilerIrFunction
  (Function
    (ir.compiler-ir-test-symbol "ineligible")
    (irt.params "arg=%0:i64")
    (Unit)
    7
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (Mov 1 (F64 0x3ff8000000000000) (F64))
          (compiler-reg-test-instr-seq-prepend
            (Mov 2 (String "heap") (String))
            (compiler-reg-test-instr-seq-prepend
              (Mov 3 (Var 0) (compiler-reg-i64-ty))
              (compiler-reg-test-instr-seq-prepend
                (Mov 4 (Unit) (ast.ast-ty-dyn-array (I64)))
                (compiler-reg-test-instr-seq-prepend
                  (Mov 5 (I64 5) (compiler-reg-i64-ty))
                  (compiler-reg-test-instr-seq-prepend
                    (AddrOf 6 3)
                    (compiler-reg-test-instr-seq-prepend
                      (TailMask 7 (Var 5) (Var 5) 4)
                      (compiler-reg-test-instr-seq-prepend
                        (Return (Some (Var 5)))
                        (ir.compiler-ir-instr-seq-empty)))))))))))
    Ordinary))

(define (compiler-reg-param-livein-gap-function) : ir.CompilerIrFunction
  (irt.func
    "function @param_livein_gap(arg=%0:i64) -> i64 vars 2 {
     entry:
       jump body
     body:
       %1 = mov 7 : i64
       return %0
     }"))

(define (compiler-reg-single-block-livein-gap-function) : ir.CompilerIrFunction
  (irt.func
    "function @single_block_livein_gap(arg=%0:i64) -> i64 vars 2 {
     entry:
       %1 = mov 7 : i64
       return %0
     }"))

(define (compiler-reg-move-chain-function) : ir.CompilerIrFunction
  (irt.func
    "function @move_chain() -> i64 vars 3 {
     entry:
       %0 = mov 41 : i64
       %1 = mov %0 : i64
       %2 = mov %1 : i64
       return %2
     }"))

(define (compiler-reg-same-value-multi-def-census-function) : ir.CompilerIrFunction
  (irt.func
    "function @same_value_multi_def_census() -> i64 vars 2 {
     entry:
       %0 = alloc i64
       %0 = mov 7 : i64
       %1 = mov %0 : i64
       return %1
     }"))

(define (compiler-reg-phi-join-function) : ir.CompilerIrFunction
  (irt.func
    "function @phi_join() -> i64 vars 2 {
     entry:
       %0 = mov 7 : i64
       jump join
     join:
       %1 = phi [%0, entry] : i64
       return %1
     }"))

(define (compiler-reg-loop-backedge-function) : ir.CompilerIrFunction
  (irt.func
    "function @loop_backedge() -> i64 vars 3 {
     entry:
       %0 = mov 0 : i64
       jump loop
     loop:
       %1 = phi [%0, entry], [%2, body] : i64
       %2 = mov %1 : i64
       branch false, body, exit
     body:
       jump loop
     exit:
       return %2
     }"))

;; Single-block accumulator carry plus a loop counter. The accumulator back-edge
;; value is defined in the block and only feeds successor phis, so EP relaxation
;; may merge its back-edge copy with the header phi even though the value is also
;; live on the exit edge. The counter back-edge value feeds the exit compare, but
;; the counter PHI RESULT is dead from the increment onwards and leaves the block
;; on no edge, so that web is relaxed too -- one register carries the phi result
;; and then the increment, and the back edge needs no copy.
;; Both branch successor orderings exercise edge neutrality.
(define (compiler-reg-self-loop-exit-live-phi-function [loop-first : bool]) : ir.CompilerIrFunction
  (Function
    (ir.compiler-ir-test-symbol "self_loop_exit_live_phi")
    (ir.compiler-ir-param-seq-empty)
    (I64)
    6
    (ir.compiler-ir-blocks-with-tail
      (irt.blocks "exit:
             return %3")
      (irt.block "entry:
           jump loop")
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "loop")
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%0 = phi [0, entry], [%3, loop] : i64")
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "%1 = phi [0, entry], [%4, loop] : i64")
            (compiler-reg-test-instr-seq-prepend
              (irt.instr "%2 = add %0, 1 : i64")
              (compiler-reg-test-instr-seq-prepend
                (irt.instr "%3 = mov %2 : i64")
                (compiler-reg-test-instr-seq-prepend
                  (irt.instr "%4 = add %1, 1 : i64")
                  (compiler-reg-test-instr-seq-prepend
                    (irt.instr "%5 = lt %4, 10 : bool")
                    (compiler-reg-test-instr-seq-prepend
                      (Branch
                        (Var 5)
                        (if loop-first
                          (ir.compiler-ir-label "loop")
                          (ir.compiler-ir-label "exit"))
                        (if loop-first
                          (ir.compiler-ir-label "exit")
                          (ir.compiler-ir-label "loop")))
                      (ir.compiler-ir-instr-seq-empty))))))))))
    Ordinary))

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
  (irt.func
    "function @self_loop_counter_exit_read() -> i64 vars 3 {
     entry:
       jump loop
     loop:
       %0 = phi [0, entry], [%1, loop] : i64
       %1 = add %0, 1 : i64
       %2 = lt %1, 10 : bool
       branch %2, loop, exit
     exit:
       return %0
     }"))

;; Negative counter shape 2: the PHI RESULT v0 is read AGAIN inside the block,
;; after the increment v1 that feeds the back edge. The increment would destroy
;; v0 before that read, so the web must stay excluded here too.
(define (compiler-reg-self-loop-counter-late-read-function) : ir.CompilerIrFunction
  (irt.func
    "function @self_loop_counter_late_read() -> i64 vars 4 {
     entry:
       jump loop
     loop:
       %0 = phi [0, entry], [%1, loop] : i64
       %1 = add %0, 1 : i64
       %2 = mul %0, 3 : i64
       %3 = lt %1, 10 : bool
       branch %3, loop, exit
     exit:
       return %2
     }"))

(define (compiler-reg-destructive-straight-chain-function) : ir.CompilerIrFunction
  (irt.func
    "function @destructive_straight_chain() -> i64 vars 3 {
     entry:
       %0 = mov 40 : i64
       %1 = add %0, 3 : i64
       %2 = sub %1, 1 : i64
       return %2
     }"))

(define (compiler-reg-destructive-noncommutative-function) : ir.CompilerIrFunction
  (irt.func
    "function @destructive_noncommutative() -> i64 vars 4 {
     entry:
       %0 = mov 40 : i64
       %1 = mov 3 : i64
       %2 = sub %0, %1 : i64
       %3 = add %2, 1 : i64
       return %3
     }"))

(define (compiler-reg-destructive-commutative-rhs-function) : ir.CompilerIrFunction
  (irt.func
    "function @destructive_commutative_rhs() -> i64 vars 3 {
     entry:
       %0 = mov 40 : i64
       %1 = add %0, 3 : i64
       %2 = add 1, %1 : i64
       return %2
     }"))

(define (compiler-reg-destructive-div-exclusion-function) : ir.CompilerIrFunction
  (irt.func
    "function @destructive_div_exclusion() -> i64 vars 3 {
     entry:
       %0 = mov 40 : i64
       %1 = div %0, 2 : i64
       %2 = add %1, 1 : i64
       return %2
     }"))

(define (compiler-reg-destructive-chain-ok?) : bool
  (let
    [straight : ir.CompilerIrFunction
      (compiler-reg-destructive-straight-chain-function)]
    [straight-moves : reg.CompilerRegMoveSeq
      (compiler-reg-function-moves-with-destructive-and-casts
        (ir.compiler-ir-global-shared-view straight)
        false)]
    [clobber-eligible : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [clobber-moves : reg.CompilerRegMoveSeq
      (begin
        (reg.compiler-reg-fill-i64-array (&mut clobber-eligible) 1)
        (set! (array-ref clobber-eligible 1) 0)
        (reg.compiler-reg-function-moves-with-destructive-and-casts-eligible
          (ir.compiler-ir-global-shared-view straight)
          false
          clobber-eligible
          (reg.compiler-reg-function-alu-prefer-rhs
            (ir.compiler-ir-global-shared-view straight))))]
    [noncomm : ir.CompilerIrFunction
      (compiler-reg-destructive-noncommutative-function)]
    [noncomm-moves : reg.CompilerRegMoveSeq
      (compiler-reg-function-moves-with-destructive-and-casts noncomm false)]
    [commutative-rhs-moves : reg.CompilerRegMoveSeq
      (compiler-reg-function-moves-with-destructive-and-casts
        (compiler-reg-destructive-commutative-rhs-function)
        false)]
    [div-moves : reg.CompilerRegMoveSeq
      (compiler-reg-function-moves-with-destructive-and-casts
        (compiler-reg-destructive-div-exclusion-function)
        false)]
    (match (reg.compiler-reg-plan-function-scalar straight)
      [(Plan assignments _ _ _ _)
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
  (Function
    (ir.compiler-ir-test-symbol "alu_load_lhs")
    (ir.compiler-ir-param-seq-empty)
    (I64)
    9
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%0 = mov 40 : i64")
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "%1 = mov 0 : i64")
            (compiler-reg-test-instr-seq-prepend
              (irt.instr "%2 = mov 7 : i64")
              (compiler-reg-test-instr-seq-prepend
                (irt.instr "%3 = add %2, 1 : i64")
                (compiler-reg-test-instr-seq-prepend
                  (irt.instr "%4 = gep %0, %1 : i64")
                  (compiler-reg-test-instr-seq-prepend
                    (irt.instr "%5 = load %4 : i64")
                    (compiler-reg-test-instr-seq-prepend
                      (BinOp 6 op (Var 5) (Var 3) (compiler-reg-i64-ty))
                      (compiler-reg-test-instr-seq-prepend
                        (irt.instr "%7 = add %6, 1 : i64")
                        (if double-use-load?
                          (irt.instrs
                            "%8 = add %7, %5 : i64
                             return %8")
                          (irt.instrs "return %7"))))))))))))
    Ordinary))

;; Both operands loaded is the backend's PAIR fold, which needs no operand tie:
;;
;;     %4 = gep ... ; %5 = load %4
;;     %6 = gep ... ; %7 = load %6
;;     %8 = bit_and %7, %5
;;
;; The rhs-defining load sits three slots back, which is exactly the shape the
;; preference declines.
(define (compiler-reg-alu-load-pair-function) : ir.CompilerIrFunction
  (irt.func
    "function @alu_load_pair() -> i64 vars 10 {
     entry:
       %0 = mov 40 : i64
       %1 = mov 0 : i64
       %2 = mov 2 : i64
       %3 = add %2, 1 : i64
       %4 = gep %0, %1 : i64
       %5 = load %4 : i64
       %6 = gep %0, %3 : i64
       %7 = load %6 : i64
       %8 = bit_and %7, %5 : i64
       %9 = add %8, 1 : i64
       return %9
     }"))

(define (compiler-reg-alu-load-lhs-moves
  [op : ir.CompilerIrBinOp]
  [double-use-load? : bool]) : reg.CompilerRegMoveSeq
  (compiler-reg-function-moves-with-destructive-and-casts
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
    (reg.compiler-reg-fill-i64-array (&mut hints) -1)
    (while (< index 8)
      (set! (array-ref parents index) index)
      (set! index (+ index 1)))
    (if flip?
      (set! (array-ref flags 6) 1)
      unit)
    (reg.compiler-reg-copy-hints-from-binops-instr!
      (irt.instr "%6 = bit_and %5, %3 : i64")
      (&mut hints)
      parents
      flags)
    (array-ref hints 6)))

(define (compiler-reg-alu-load-lhs-tie-ok?) : bool
  (let
    ;; (a) commutative, single-use fused load on the lhs: the destination ties
    ;; to the ACCUMULATOR (%3), not to the load (%5).
    [flipped : reg.CompilerRegMoveSeq
      (compiler-reg-alu-load-lhs-moves BitAnd false)]
    ;; (b) the same shape with a twice-read load: no fold, so no flip.
    [double-use : reg.CompilerRegMoveSeq
      (compiler-reg-alu-load-lhs-moves BitAnd true)]
    ;; (c) Sub is not commutative -- `MEM - x` is not `x - MEM`.
    [noncommutative : reg.CompilerRegMoveSeq
      (compiler-reg-alu-load-lhs-moves Sub false)]
    ;; (d) both operands loaded is the pair fold's shape; ties stay put.
    [pair : reg.CompilerRegMoveSeq
      (compiler-reg-function-moves-with-destructive-and-casts
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
  (irt.func
    "function @same_value_clobber() -> i64 vars 3 {
     entry:
       %0 = mov 7 : i64
       %1 = call side_effect() : unit
       %2 = mov %0 : i64
       return %2
     }"))

;; M-C (part 1) census shapes for the extended (mutable-source) same-value
;; relation. `safe`: the source's second def lies OUTSIDE the copy's liveness
;; -> merge. `reject`: the second def lands between the copy and its use ->
;; refused. `chain`: a copy-of-copy must not smuggle a member past the def
;; (the transitive hazard). `cast`: the width-64 int cast counts as a copy.
(define (compiler-reg-sv-multi-safe-function) : ir.CompilerIrFunction
  (irt.func
    "function @sv_multi_safe() -> i64 vars 2 {
     entry:
       %0 = mov 7 : i64
       %1 = mov %0 : i64
       store @g, %1 : i64
       %0 = mov 9 : i64
       return %0
     }"))

(define (compiler-reg-sv-multi-reject-function) : ir.CompilerIrFunction
  (irt.func
    "function @sv_multi_reject() -> i64 vars 2 {
     entry:
       %0 = mov 7 : i64
       %1 = mov %0 : i64
       %0 = mov 9 : i64
       store @g, %1 : i64
       return %0
     }"))

(define (compiler-reg-sv-multi-chain-function) : ir.CompilerIrFunction
  (irt.func
    "function @sv_multi_chain() -> i64 vars 4 {
     entry:
       %0 = mov 7 : i64
       %2 = mov %0 : i64
       %0 = mov 9 : i64
       %3 = mov %2 : i64
       store @g, %3 : i64
       return %0
     }"))

(define (compiler-reg-sv-multi-cast-function) : ir.CompilerIrFunction
  (irt.func
    "function @sv_multi_cast() -> i64 vars 2 {
     entry:
       %0 = mov 7 : i64
       %1 = cast %0 : i64 to u64
       store @g, %1 : u64
       %0 = mov 9 : i64
       return %0
     }"))

;; The mutable-source hazard must survive the relaxation: `0` is redefined
;; INSIDE the copy's liveness, so the two are not the same value at the copy's
;; use however neatly their hulls nest.
(define (compiler-reg-p22-nested-reject-function) : ir.CompilerIrFunction
  (irt.func
    "function @p22_nested_reject() -> i64 vars 3 {
     entry:
       %0 = mov 7 : i64
       %1 = mov %0 : i64
       %0 = mov 9 : i64
       store @g, %1 : i64
       %2 = call side_effect() : unit
       store @g, %0 : i64
       return %0
     }"))

(define (compiler-reg-p22-nested-same-home? [func : ir.CompilerIrFunction]) : bool
  (match (reg.compiler-reg-plan-function-scalar func)
    [(Plan assignments _ _ _ _) (compiler-reg-same-location? assignments 0 1)]))

(define (compiler-reg-p22-nested-copy-ok?) : bool
  (and
    ;; A same-width signedness cast whose source stays live shares its home.
    (compiler-reg-p22-nested-same-home?
      (irt.func
        "function @p22_nested_copy() -> i64 vars 3 {
         entry:
           %0 = mov 7 : i64
           %1 = cast %0 : i64 to u64
           store @g, %1 : u64
           %2 = call side_effect() : unit
           store @g, %0 : i64
           return %0
         }"))
    ;; Same in the other signedness direction.
    (compiler-reg-p22-nested-same-home?
      (irt.func
        "function @p22_nested_copy() -> i64 vars 3 {
         entry:
           %0 = mov 7 : i64
           %1 = cast %0 : u64 to i64
           store @g, %1 : i64
           %2 = call side_effect() : unit
           store @g, %0 : i64
           return %0
         }"))
    ;; A plain Mov whose source stays live shares its home.
    (compiler-reg-p22-nested-same-home?
      (irt.func
        "function @p22_nested_copy() -> i64 vars 3 {
         entry:
           %0 = mov 7 : i64
           %1 = mov %0 : i64
           store @g, %1 : i64
           %2 = call side_effect() : unit
           store @g, %0 : i64
           return %0
         }"))
    ;; A NARROWING cast is real work -- the destination home holds the
    ;; sign-normalized 32-bit value, which is not the source's bit pattern --
    ;; so it must keep its own home.
    (not
      (compiler-reg-p22-nested-same-home?
        (irt.func
          "function @p22_nested_copy() -> i64 vars 3 {
           entry:
             %0 = mov 7 : i64
             %1 = cast %0 : i64 to i32
             store @g, %1 : i32
             %2 = call side_effect() : unit
             store @g, %0 : i64
             return %0
           }")))
    ;; A widening cast is real work too.
    (not
      (compiler-reg-p22-nested-same-home?
        (irt.func
          "function @p22_nested_copy() -> i64 vars 3 {
           entry:
             %0 = mov 7 : i64
             %1 = cast %0 : i32 to i64
             store @g, %1 : i64
             %2 = call side_effect() : unit
             store @g, %0 : i64
             return %0
           }")))
    ;; Nesting lifts the clobber-span refusal ONLY. A source redefined inside
    ;; the copy's liveness is still refused.
    (not
      (compiler-reg-p22-nested-same-home?
        (compiler-reg-p22-nested-reject-function)))))

(define (compiler-reg-interference-blocks-coalesce-function) : ir.CompilerIrFunction
  (irt.func
    "function @interference_blocks_coalesce() -> i64 vars 2 {
     entry:
       %0 = mov 9 : i64
       %1 = mov %0 : i64
       store @keep, %0 : i64
       return %1
     }"))

(define (compiler-reg-spill-coalesce-function) : ir.CompilerIrFunction
  (irt.func
    "function @spill_coalesce() -> i64 vars 6 {
     entry:
       %0 = mov 0 : i64
       %1 = mov 1 : i64
       %2 = mov 2 : i64
       %3 = mov 3 : i64
       %4 = mov 4 : i64
       store @g0, %0 : i64
       store @g1, %1 : i64
       store @g2, %2 : i64
       store @g3, %3 : i64
       %5 = mov %4 : i64
       return %5
     }"))

(define (compiler-reg-vector-home-function) : ir.CompilerIrFunction
  (Function
    (ir.compiler-ir-test-symbol "vector_home")
    (ir.compiler-ir-param-seq-empty)
    (Unit)
    4
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%0 = vector_load 0, 0 lanes 4 : i64")
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "%1 = vector_load 0, 4 lanes 4 : i64")
            (compiler-reg-test-instr-seq-prepend
              (ir.ir-instr-vector-bin-op 2 (Add) (Var 0) (Var 1) 4 (I64))
              (compiler-reg-test-instr-seq-prepend
                (ir.ir-instr-vector-bin-op 3 (Add) (Var 0) (Var 2) 4 (I64))
                (compiler-reg-test-instr-seq-prepend
                  (ir.ir-instr-vector-store (I64 0) (I64 8) (Var 3) 4 (I64))
                  (irt.instrs "return"))))))))
    Ordinary))

;; CpuId clobbers fixed GP registers but preserves the XMM bank. A vector live
;; across it must therefore keep an ordinary volatile vector home on SysV.
(define (compiler-reg-vector-gp-clobber-home-function) : ir.CompilerIrFunction
  (Function
    (ir.compiler-ir-test-symbol "vector_gp_clobber_home")
    (ir.compiler-ir-param-seq-empty)
    (Unit)
    2
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%0 = vector_load 0, 0 lanes 4 : i64")
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "%1 = cpuid 0, 0 word 0")
            (compiler-reg-test-instr-seq-prepend
              (ir.ir-instr-vector-store (I64 0) (I64 4) (Var 0) 4 (I64))
              (irt.instrs "return"))))))
    Ordinary))

(define (compiler-reg-vector-select-false-home-function) : ir.CompilerIrFunction
  (Function
    (ir.compiler-ir-test-symbol "vector_select_false_home")
    (ir.compiler-ir-param-seq-empty)
    (Unit)
    5
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%0 = splat 0 lanes 8 : i64")
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "%1 = splat 1 lanes 8 : i64")
            (compiler-reg-test-instr-seq-prepend
              (irt.instr "%2 = splat 2 lanes 8 : i64")
              (compiler-reg-test-instr-seq-prepend
                (ir.ir-instr-vector-store (I64 0) (I64 0) (Var 0) 8 (I64))
                (compiler-reg-test-instr-seq-prepend
                  (ir.ir-instr-vector-compare 3 (Lt) (Var 2) (Var 1) 8 (I64))
                  (compiler-reg-test-instr-seq-prepend
                    (ir.ir-instr-select 4 (Var 3) (Var 2) (Var 1) 8 (I64))
                    (compiler-reg-test-instr-seq-prepend
                      (ir.ir-instr-vector-store (I64 0) (I64 8) (Var 4) 8 (I64))
                      (irt.instrs "return"))))))))))
    Ordinary))

(define (compiler-reg-mask-home-function) : ir.CompilerIrFunction
  (irt.func
    "function @mask_home() -> unit vars 5 {
     entry:
       %0 = tail_mask 0, 8 lanes 8
       %1 = tail_mask 4, 8 lanes 8
       %2 = mask_and %0, %1 lanes 8
       %3 = mask_not %2 lanes 8
       %4 = mask_reduce_any %3 lanes 8
       return %4
     }"))

(define (compiler-reg-mask-pressure-uses [index : i64]) : ir.CompilerIrInstrSeq
  (if (>= index 7)
    (irt.instrs "return %13")
    (compiler-reg-test-instr-seq-prepend
      (MaskReduce (+ 7 index) (Any) (Var index) 8)
      (compiler-reg-mask-pressure-uses (+ index 1)))))

(define (compiler-reg-mask-pressure-defs [index : i64]) : ir.CompilerIrInstrSeq
  (if (>= index 7)
    (compiler-reg-mask-pressure-uses 0)
    (compiler-reg-test-instr-seq-prepend
      (TailMask index (I64 index) (I64 8) 8)
      (compiler-reg-mask-pressure-defs (+ index 1)))))

(define (compiler-reg-mask-pressure-function) : ir.CompilerIrFunction
  (Function
    (ir.compiler-ir-test-symbol "mask_pressure")
    (ir.compiler-ir-param-seq-empty)
    (Bool)
    14
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-mask-pressure-defs 0)))
    Ordinary))

(define (compiler-reg-reuse-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-reuse-function))
    [(Plan assignments _ _ _ _)
      (and
        (= (reg.compiler-reg-assignment-count assignments) 2)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          cabi.compiler-reg-id-r12)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 1)
          cabi.compiler-reg-id-r12))]))

(define (compiler-reg-f64-reuse-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-reuse-function))
    [(Plan assignments _ _ _ _)
      (and
        (= (reg.compiler-reg-assignment-count assignments) 2)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          (cabi.compiler-abi-xmm-register-id 2))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 1)
          (cabi.compiler-abi-xmm-register-id 2)))]))

(define (compiler-reg-overlap-spill-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-overlap-function))
    [(Plan assignments _ _ _ _)
      ;; Seven simultaneously live values against a five-register callee-saved
      ;; pool: the first five take %r12..%r15 and %rbx, and the remaining two
      ;; spill. %rbx joined the pool once its fixed scratch role moved under the
      ;; scavenger.
      (and
        (= (reg.compiler-reg-assignment-count assignments) 7)
        (= (compiler-reg-spill-count assignments) 2)
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
  (match (compiler-reg-plan-function (compiler-reg-f64-overlap-function))
    [(Plan assignments _ _ _ _)
      (and
        (= (reg.compiler-reg-assignment-count assignments) 5)
        (= (compiler-reg-spill-count assignments) 0)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          (cabi.compiler-abi-xmm-register-id 2))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 1)
          (cabi.compiler-abi-xmm-register-id 3))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 2)
          (cabi.compiler-abi-xmm-register-id 4))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 3)
          (cabi.compiler-abi-xmm-register-id 5))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 4)
          (cabi.compiler-abi-xmm-register-id 6)))]))

;; SIMD plan: an integer value live across a call keeps a callee-saved register
;; home (the SIMD integer pool is the 5 callee-saved registers, which the callee
;; preserves), exactly like the scalar plan.
;; The unit call result (var 1) stays ineligible (non-scalar).
(define (compiler-reg-call-live-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-call-live-function))
    [(Plan assignments ineligible _ _ _)
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
    [(Plan assignments ineligible _ _ _)
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
    [(Plan assignments ineligible _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (not
          (compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 0))))]))

(define (compiler-reg-scalar-win64-f64-call-live-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar-for-abi
    Windows
    (compiler-reg-f64-call-live-function))
    [(Plan assignments ineligible _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 0)
          (cabi.compiler-abi-xmm-register-id 6)))]))

(define (compiler-reg-f64-call-live-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-call-live-function))
    [(Plan assignments ineligible _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (live.compiler-live-set-contains? ineligible 1)
        (not
          (compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 0)))
        (compiler-reg-unassigned? assignments 1)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 2)
          (cabi.compiler-abi-xmm-register-id 2)))]))

(define (compiler-reg-call-arg-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-call-arg-function))
    [(Plan assignments ineligible _ _ _)
      (and
        (live.compiler-live-set-contains? ineligible 0)
        (live.compiler-live-set-contains? ineligible 1)
        (compiler-reg-unassigned? assignments 0)
        (compiler-reg-unassigned? assignments 1)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 3)
          cabi.compiler-reg-id-r12))]))

(define (compiler-reg-f64-call-arg-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-call-arg-function))
    [(Plan assignments ineligible _ _ _)
      (and
        (live.compiler-live-set-contains? ineligible 0)
        (compiler-reg-unassigned? assignments 0)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignments 2)
          (cabi.compiler-abi-xmm-register-id 2)))]))

(define (compiler-reg-ineligible-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-ineligible-function))
    [(Plan assignments ineligible _ _ _)
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
              (cabi.compiler-abi-xmm-register-id 2))
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
    [(Plan assignments ineligible _ _ _)
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
    [(Plan assignments ineligible _ _ _)
      (and
        (not (live.compiler-live-set-contains? ineligible 0))
        (not (live.compiler-live-set-contains? ineligible 1))
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 0)))]))

(define (compiler-reg-scalar-indirect-call-arg-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar-for-abi
    Linux
    (compiler-reg-indirect-call-arg-function))
    [(Plan assignments ineligible _ _ _)
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
    Linux
    (compiler-reg-c-abi-store-result-arg-function))
    [(Plan assignments ineligible _ _ _)
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
    Windows
    (compiler-reg-indirect-call-arg4-function))
    [(Plan _ ineligible _ _ _)
      (and
        (live.compiler-live-set-contains? ineligible 0)
        (live.compiler-live-set-contains? ineligible 1)
        (live.compiler-live-set-contains? ineligible 2)
        (live.compiler-live-set-contains? ineligible 3)
        (live.compiler-live-set-contains? ineligible 4))]))

(define (compiler-reg-scalar-function-intervals-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-param-livein-gap-function))
    [(Plan _ _ intervals _ _) (compiler-reg-interval-range? intervals 0 0 4)]))

(define (compiler-reg-scalar-interval-guardrail-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-single-block-livein-gap-function))
    [(Plan _ _ intervals _ _) (compiler-reg-interval-range? intervals 0 0 2)]))

;; Allocation must consume the edge-precise phi view, not merely compute it for
;; coalescing. In this loop, baseline liveness leaks the entry value through the
;; whole function (0..11) and the back-edge input back to entry (1..12). Exact
;; predecessor-edge uses instead produce the three ranges asserted below.
(define (compiler-reg-scalar-edge-precise-allocation-intervals-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-loop-backedge-function))
    [(Plan _ _ intervals _ _)
      (and
        (= (reg.compiler-reg-interval-seq-count intervals) 3)
        (compiler-reg-interval-range?
          (reg.compiler-reg-global-shared-view intervals)
          0
          0
          4)
        (compiler-reg-interval-range?
          (reg.compiler-reg-global-shared-view intervals)
          1
          4
          6)
        (compiler-reg-interval-range? intervals 2 4 12))]))

(define (compiler-reg-scalar-loop-backedge-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-loop-backedge-function))
    [(Plan assignments _ _ _ _)
      (and
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 1))
        (compiler-reg-location-any-register?
          (reg.compiler-reg-assignment-lookup assignments 2))
        (compiler-reg-same-location? assignments 1 2))]))

(define (compiler-reg-syscall-clobber-overlap-function) : ir.CompilerIrFunction
  (irt.func
    "function @syscall_clobber_overlap() -> unit vars 7 {
     entry:
       %0 = mov 0 : i64
       %1 = mov 1 : i64
       %2 = mov 2 : i64
       %3 = mov 3 : i64
       %4 = mov 4 : i64
       %5 = mov 5 : i64
       %6 = syscall(39)
       store @g0, %0 : i64
       store @g1, %1 : i64
       store @g2, %2 : i64
       store @g3, %3 : i64
       store @g4, %4 : i64
       store @g5, %5 : i64
       return
     }"))

(define (compiler-reg-call-spanning-caller-saved-function) : ir.CompilerIrFunction
  (irt.func
    "function @call_spanning_caller_saved() -> unit vars 8 {
     entry:
       %0 = mov 0 : i64
       %1 = mov 1 : i64
       %2 = mov 2 : i64
       %3 = mov 3 : i64
       %4 = mov 4 : i64
       %5 = mov 5 : i64
       %6 = mov 6 : i64
       %7 = call side_effect() : unit
       store @g0, %0 : i64
       store @g1, %1 : i64
       store @g2, %2 : i64
       store @g3, %3 : i64
       store @g4, %4 : i64
       store @g5, %5 : i64
       store @g6, %6 : i64
       store @g5b, %5 : i64
       store @g5c, %5 : i64
       return
     }"))

(define (compiler-reg-scalar-zero-call-caller-saved-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar (compiler-reg-overlap-function))
    [(Plan assignments _ _ _ _)
      (and
        (= (reg.compiler-reg-assignment-count assignments) 7)
        (= (compiler-reg-spill-count assignments) 0)
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
    [(Plan assignments _ _ _ _)
      (and
        ;; W3 step (a) NON-VACUITY. The one value the syscall's clobber pushes
        ;; out is a single-def i64 LITERAL, so the assignment rewrite converts
        ;; its spill into a rematerialisation: no frame slot, no def store, one
        ;; `movl $5` at the use. Before the literal widening this asserted a
        ;; single Spill at stack slot 5; reverting the widening fails here.
        (= (compiler-reg-spill-count assignments) 0)
        (compiler-reg-maybe-location-remat?
          (reg.compiler-reg-assignment-lookup assignments 5)))]))

(define (compiler-reg-scalar-call-spanning-caller-saved-ok?) : bool
  (let
    [func : ir.CompilerIrFunction
      (compiler-reg-call-spanning-caller-saved-function)]
    [plan : reg.CompilerRegPlan (reg.compiler-reg-plan-function-scalar func)]
    (match plan
      [(Plan assignments _ _ _ split-vars)
        (and
          ;; 7 call-spanning values vs 5 callee-saved registers -> 2 spill (call-
          ;; spanning values cannot use caller-saved across the call). The greedy's
          ;; spill-weight priority keeps the hottest value (var 5, stored 3x)
          ;; register-homed and spills the single-use overflow; var 6 overflows to
          ;; the stack and needs no save/restore rescue.
          ;; W3 step (a): both overflow values are single-def i64 literals, so
          ;; the spills the weight order picked become rematerialisations
          ;; instead of frame slots.
          (= (compiler-reg-spill-count assignments) 0)
          (compiler-reg-maybe-location-remat?
            (reg.compiler-reg-assignment-lookup assignments 6))
          (not
            (let
              [call-split-shadows
                (reg.compiler-reg-call-split-shadows
                  (reg.compiler-reg-global-shared-view split-vars))]
              (live.compiler-live-set-contains? call-split-shadows 5)))
          (not
            (let
              [call-split-shadows
                (reg.compiler-reg-call-split-shadows split-vars)]
              (live.compiler-live-set-contains? call-split-shadows 6))))])))

(define (compiler-reg-same-location?
  [assignments : reg.CompilerRegAssignmentTable]
  [left : i64]
  [right : i64]) : bool
  (match (reg.compiler-reg-assignment-lookup assignments left)
    [(Some left-location)
      (match (reg.compiler-reg-assignment-lookup assignments right)
        [(Some right-location)
          (reg.compiler-reg-location-eq? left-location right-location)]
        [(No) false])]
    [(No) false]))

(define (compiler-reg-different-location?
  [assignments : reg.CompilerRegAssignmentTable]
  [left : i64]
  [right : i64]) : bool
  (match (reg.compiler-reg-assignment-lookup assignments left)
    [(Some left-location)
      (match (reg.compiler-reg-assignment-lookup assignments right)
        [(Some right-location)
          (not (reg.compiler-reg-location-eq? left-location right-location))]
        [(No) false])]
    [(No) false]))

(define (compiler-reg-dense-lookups-ok?) : bool
  (let
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-insert
        (reg.compiler-reg-assignment-insert
          (reg.compiler-reg-assignment-insert
            (reg.compiler-reg-assignment-table-empty)
            1
            (Register cabi.compiler-reg-id-r12))
          4
          (RegisterPair cabi.compiler-reg-id-r13 cabi.compiler-reg-id-r14))
        3
        (Spill 24))]
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
            (Register cabi.compiler-reg-id-r12))
          4
          (RegisterPair cabi.compiler-reg-id-r13 cabi.compiler-reg-id-r14))
        3
        (Spill 24))]
    [interval-index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build intervals 5)]
    [starts : (__tl_dyn-array i64) interval-index.starts]
    [ends : (__tl_dyn-array i64) interval-index.ends]
    [assignment-hit-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-index 1)
        [(Some location)
          (reg.compiler-reg-location-eq?
            location
            (Register cabi.compiler-reg-id-r12))]
        [(No) false])]
    [assignment-miss-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-index 2)
        [(Some _) false]
        [(No) true])]
    [assignment-oob-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-index -1)
        [(Some _) false]
        [(No) true])]
    [table-hit-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-table 1)
        [(Some location)
          (reg.compiler-reg-location-eq?
            location
            (Register cabi.compiler-reg-id-r12))]
        [(No) false])]
    [table-miss-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-table 2)
        [(Some _) false]
        [(No) true])]
    [table-oob-ok : bool
      (match (reg.compiler-reg-assignment-table-lookup assignment-table -1)
        [(Some _) false]
        [(No) true])]
    [table-direct-ok : bool
      (and
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup assignment-table 1)
          cabi.compiler-reg-id-r12)
        (reg.compiler-reg-location-eq?
          (match (reg.compiler-reg-assignment-lookup assignment-table 3)
            [(Some location) location]
            [(No) (Spill -1)])
          (Spill 24)))]
    [interval-hit-ok : bool
      (match (reg.compiler-reg-interval-index-lookup interval-index 3)
        [(Some interval)
          (and (= interval.var 3) (= interval.start 5) (= interval.end 9))]
        [(No) false])]
    [interval-miss-ok : bool
      (match (reg.compiler-reg-interval-index-lookup interval-index 2)
        [(Some _) false]
        [(No) true])]
    [interval-first-ok : bool
      (match (reg.compiler-reg-interval-index-lookup interval-index 4)
        [(Some interval)
          (and (= interval.var 4) (= interval.start 1) (= interval.end 4))]
        [(No) false])]
    [interference-ok : bool
      (and
        (not (reg.compiler-reg-vars-interfere-index? interval-index 1 3))
        (reg.compiler-reg-vars-interfere-index? interval-index 1 2))]
    [conflict-ok : bool
      (and
        (not
          (compiler-reg-location-conflicts?
            assignments
            interval-index
            3
            -1
            (Register cabi.compiler-reg-id-r12)))
        (compiler-reg-location-conflicts?
          assignments
          interval-index
          2
          -1
          (Register cabi.compiler-reg-id-r12)))]
    [table-conflict-ok : bool
      (and
        (not
          (reg.compiler-reg-assignment-table-location-conflicts?
            assignment-table
            interval-index
            3
            -1
            (Register cabi.compiler-reg-id-r12)))
        (reg.compiler-reg-assignment-table-location-conflicts?
          assignment-table
          interval-index
          2
          -1
          (Register cabi.compiler-reg-id-r12)))]
    [shared-query-ok : bool
      (and
        (reg.compiler-reg-location-uses-register?
          (RegisterPair cabi.compiler-reg-id-r13 cabi.compiler-reg-id-r14)
          cabi.compiler-reg-id-r14)
        (not
          (reg.compiler-reg-location-uses-register?
            (RegisterPair cabi.compiler-reg-id-r13 cabi.compiler-reg-id-r14)
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
          (clone assignments)
          cabi.compiler-reg-id-r14)
        (not
          (reg.compiler-reg-assignments-use-register?
            (clone assignments)
            cabi.compiler-reg-id-r15))
        (reg.compiler-reg-var-live-at-point? starts ends 1 3)
        (not (reg.compiler-reg-var-live-at-point? starts ends 1 6))
        (reg.compiler-reg-var-live-over-range? starts ends 1 5 7)
        (not (reg.compiler-reg-var-live-over-range? starts ends 1 6 7))
        (not
          (compiler-reg-assignment-table-register-free-at-point?
            (clone starts)
            (clone ends)
            (clone assignment-index)
            5
            3
            cabi.compiler-reg-id-r12))
        (compiler-reg-assignment-table-register-free-at-point?
          (clone starts)
          (clone ends)
          (clone assignment-index)
          5
          6
          cabi.compiler-reg-id-r12)
        (not
          (compiler-reg-assignment-table-register-free-over-range?
            starts
            ends
            assignment-index
            5
            3
            4
            cabi.compiler-reg-id-r14))
        (compiler-reg-assignment-table-register-free-over-range?
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

(define (compiler-reg-test-assignment-table-count
  [assignments : reg.CompilerRegAssignmentTable]) : i64
  (let
    [present : (__tl_dyn-array i64)
      (reg.compiler-reg-assignment-table-present assignments)]
    [index : i64 0]
    [count : i64 0]
    (while (< index (array-length present))
      (when (not (= (array-ref present index) 0)) (set! count (+ count 1)))
      (set! index (+ index 1)))
    count))

(define (compiler-reg-dense-assignment-snapshot-ok?) : bool
  (let
    [base : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-insert
        (reg.compiler-reg-assignment-table-empty)
        2
        (Register cabi.compiler-reg-id-r12))]
    [successor : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-override-copy base 2 (Spill 40))]
    [expanded : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-override-copy
        successor
        9
        (Register cabi.compiler-reg-id-r13))]
    (and
      (= (compiler-reg-test-assignment-table-count base) 1)
      (= (compiler-reg-test-assignment-table-count successor) 1)
      (= (compiler-reg-test-assignment-table-count expanded) 2)
      (>=
        (array-length (reg.compiler-reg-assignment-table-present expanded))
        10)
      (reg.compiler-reg-location-register?
        (reg.compiler-reg-assignment-table-lookup base 2)
        cabi.compiler-reg-id-r12)
      (match (reg.compiler-reg-assignment-table-lookup successor 2)
        [(Some location) (reg.compiler-reg-location-eq? location (Spill 40))]
        [(No) false])
      (match (reg.compiler-reg-assignment-table-lookup base 9)
        [(Some _) false]
        [(No) true])
      (reg.compiler-reg-location-register?
        (reg.compiler-reg-assignment-table-lookup expanded 9)
        cabi.compiler-reg-id-r13))))

(define (compiler-reg-segmented-interference-ok?) : bool
  (let
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [ends : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [segments : (__tl_dyn-array reg.CompilerRegIntervalSeq)
      (__tl_make-array reg.CompilerRegIntervalSeq 5)]
    [segment-index : reg.CompilerRegIntervalIndex
      (reg.CompilerRegIntervalIndex
        (reg.compiler-reg-global-shared-view starts)
        (reg.compiler-reg-global-shared-view ends)
        (reg.compiler-reg-global-shared-view segments))]
    (reg.compiler-reg-fill-i64-array (&mut starts) -1)
    (reg.compiler-reg-fill-i64-array (&mut ends) -1)
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
      (not (reg.compiler-reg-vars-interfere-segmented-index? segment-index 1 3))
      (reg.compiler-reg-vars-interfere-segmented-index? segment-index 1 4)
      (reg.compiler-reg-vars-interfere-segmented-index? segment-index 0 3)
      (reg.compiler-reg-vars-interfere-segmented-index? segment-index 1 2))))

(define (compiler-reg-hole-aware-register-reuse-ok?) : bool
  (let
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [ends : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [segments : (__tl_dyn-array reg.CompilerRegIntervalSeq)
      (__tl_make-array reg.CompilerRegIntervalSeq 5)]
    [segment-index : reg.CompilerRegIntervalIndex
      (reg.CompilerRegIntervalIndex
        (reg.compiler-reg-global-shared-view starts)
        (reg.compiler-reg-global-shared-view ends)
        (reg.compiler-reg-global-shared-view segments))]
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
    [hole-aware : live.CompilerLiveI64Set (live_tests.compiler-live-set3 0 2 3)]
    [parents : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    (reg.compiler-reg-fill-i64-array (&mut starts) -1)
    (reg.compiler-reg-fill-i64-array (&mut ends) -1)
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
        (match (compiler-reg-first-free-register-holes
          (clone one-reg)
          (clone active-root)
          (clone segment-index)
          1
          (clone hole-aware))
          [(Some reg) (= reg cabi.compiler-reg-id-r12)]
          [(No) false])]
      [root-hole-reuses : bool
        (match (compiler-reg-first-free-register-holes
          (clone one-reg)
          (clone active-root)
          (clone segment-index)
          2
          (clone hole-aware))
          [(Some reg) (= reg cabi.compiler-reg-id-r12)]
          [(No) false])]
      ;; overlap still conflicts: var 3's segment [1,3] overlaps var 0's [0,2].
      [root-overlap-conflicts : bool
        (match (compiler-reg-first-free-register-holes
          (clone one-reg)
          (clone active-root)
          (clone segment-index)
          3
          (clone hole-aware))
          [(No) true]
          [(Some _) false])]
      ;; var 4's [8,9] is disjoint from the active ordinary var 1's [4,6].
      [var4-disjoint-reuses : bool
        (match (compiler-reg-first-free-register-holes
          (clone one-reg)
          (clone active-ordinary)
          (clone segment-index)
          4
          (clone hole-aware))
          [(Some reg) (= reg cabi.compiler-reg-id-r12)]
          [(No) false])]
      [roots : live.CompilerLiveI64Set
        (let
          [coalesce-map (reg.CompilerRegCoalesceMap (clone parents))]
          (reg.compiler-reg-coalesce-merged-root-set coalesce-map))]
      [mapped-blocked : live.CompilerLiveI64Set
        (let
          [coalesce-map (reg.CompilerRegCoalesceMap (clone parents))]
          (reg.compiler-reg-coalesce-root-set-from-vars
            coalesce-map
            (live_tests.compiler-live-set2 1 4)))]
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
        (not (live.compiler-live-set-contains? mapped-blocked 3))))))

(define (compiler-reg-coalesce-test-i64-types [vars : i64]) : reg.CompilerRegVarTypes
  (let
    [present : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
    [types : (__tl_dyn-array ast.AstType) (__tl_make-array ast.AstType vars)]
    [index : i64 0]
    (while (< index vars)
      (set! (array-ref present index) 1)
      (set! (array-ref types index) (compiler-reg-i64-ty))
      (set! index (+ index 1)))
    (reg.compiler-reg-var-types-new
      present
      types
      (ir.compiler-ir-representation-index-empty)
      (profile_state.compiler-profile-state-metrics
        (profile_state.compiler-profile-state-new)))))

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
    (reg.compiler-reg-fill-i64-array (&mut starts) -1)
    (reg.compiler-reg-fill-i64-array (&mut ends) -1)
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
    (reg.CompilerRegIntervalIndex starts ends segments)))

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
      (let
        [index-clone (clone index)]
        [set-empty (live.compiler-live-set-empty)]
        (reg.compiler-reg-coalesce-map-build
          moves
          index-clone
          types
          set-empty
          3
          (__tl_make-array i64 0)))]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 3)
        0
        (Register cabi.compiler-reg-id-r12))]
    [tie-assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-insert
          (reg.compiler-reg-assignment-table-make 3)
          2
          (Register cabi.compiler-reg-id-r13))
        0
        (Register cabi.compiler-reg-id-r12))]
    (and
      (reg.compiler-reg-location-register?
        (compiler-reg-coalesce-location
          (clone coalesce)
          assignments
          (clone index)
          1)
        cabi.compiler-reg-id-r12)
      (reg.compiler-reg-location-register?
        (compiler-reg-coalesce-location
          (clone coalesce)
          tie-assignments
          (clone index)
          1)
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
      (let
        [index-clone (clone index)]
        [set-empty (live.compiler-live-set-empty)]
        (reg.compiler-reg-coalesce-map-build
          moves
          index-clone
          types
          set-empty
          2
          (__tl_make-array i64 0)))]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 2)
        0
        (Register cabi.compiler-reg-id-r12))]
    (match (compiler-reg-coalesce-location coalesce assignments index 1)
      [(No) true]
      [(Some _) false])))

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
      (let
        [index-clone (clone index)]
        [set-empty (live.compiler-live-set-empty)]
        (reg.compiler-reg-coalesce-map-build
          moves
          index-clone
          types
          set-empty
          2
          (__tl_make-array i64 0)))]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 2)
        0
        (Register cabi.compiler-reg-id-r12))]
    (reg.compiler-reg-location-register?
      (compiler-reg-coalesce-location coalesce assignments index 1)
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
      (let
        [index-clone (clone index)]
        [set-empty (live.compiler-live-set-empty)]
        (reg.compiler-reg-coalesce-map-build
          moves
          index-clone
          types
          set-empty
          2
          (__tl_make-array i64 0)))]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 2)
        0
        (Register cabi.compiler-reg-id-r12))]
    (match (compiler-reg-coalesce-location coalesce assignments index 1)
      [(No) true]
      [(Some _) false])))

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
    (reg.compiler-reg-fill-i64-array (&mut starts) -1)
    (reg.compiler-reg-fill-i64-array (&mut ends) -1)
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
        (let
          [coalesce-map (reg.CompilerRegCoalesceMap parents)]
          (reg.compiler-reg-merged-root-index
            coalesce-map
            (reg.CompilerRegIntervalIndex starts ends segments)))]
      (and
        (= (array-ref merged.starts 0) 0)
        (= (array-ref merged.ends 0) 8)
        (< (array-ref merged.starts 1) 0)
        (compiler-reg-single-segment-range?
          (reg.compiler-reg-global-array-element-shared-view merged.segments 0)
          0
          0
          8)))))

(define (compiler-reg-same-value-multi-def-census-ok?) : bool
  (let
    [parents : (__tl_dyn-array i64)
      (compiler-reg-function-same-value-parents
        (compiler-reg-same-value-multi-def-census-function))]
    (not (reg.compiler-reg-same-value-class? (&mut parents) 0 1))))

(define (compiler-reg-same-value-phi-census-ok?) : bool
  (let
    [parents : (__tl_dyn-array i64)
      (compiler-reg-function-same-value-parents
        (compiler-reg-loop-backedge-function))]
    (not (reg.compiler-reg-same-value-class? (&mut parents) 1 2))))

(define (compiler-reg-same-value-clobber-census-ok?) : bool
  (let
    [func : ir.CompilerIrFunction (compiler-reg-same-value-clobber-function)]
    [selection : reg.CompilerRegIntervalSelection
      (reg.compiler-reg-live-interval-selection
        (clone func)
        (live.compiler-live-analyze-function (clone func)))]
    (match selection
      [(Selection _ interval-index)
        (let
          [parents : (__tl_dyn-array i64)
            (reg.compiler-reg-function-same-value-parents-filtered
              (clone func)
              (let
                [clobber-kind-points
                  (reg.compiler-reg-clobber-kind-points
                    (ast.ast-node-pool-reader-type-segment-bases)
                    func
                    0)]
                (reg.compiler-reg-same-value-eligible-vars
                  interval-index
                  clobber-kind-points)))]
          (not (reg.compiler-reg-same-value-class? (&mut parents) 0 2)))])))

;; M-C (part 1): build the extended relation the way plan-from does (precise
;; selection index + kind-0 eligibility + var types).
(define (compiler-reg-sv-multi-parents-for [func : ir.CompilerIrFunction]) : (__tl_dyn-array
    i64)
  (match (reg.compiler-reg-live-interval-selection
    (clone func)
    (live.compiler-live-analyze-function (clone func)))
    [(Selection _ interval-index)
      (reg.compiler-reg-function-same-value-parents-multi
        (clone func)
        (let
          [clobber-kind-points
            (reg.compiler-reg-clobber-kind-points
              (ast.ast-node-pool-reader-type-segment-bases)
              func
              0)]
          (reg.compiler-reg-same-value-eligible-vars
            interval-index
            clobber-kind-points))
        (let
          [set-empty (live.compiler-live-set-empty)]
          (reg.compiler-reg-same-value-eligible-vars interval-index set-empty))
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
      (reg.compiler-reg-same-value-class? (&mut safe) 0 1)
      (not (reg.compiler-reg-same-value-class? (&mut reject) 0 1))
      (let
        [chain-clone (clone chain)]
        (reg.compiler-reg-same-value-class? (&mut chain-clone) 2 3))
      (not
        (let
          [chain-clone (clone chain)]
          (reg.compiler-reg-same-value-class? (&mut chain-clone) 0 2)))
      (not
        (let
          [chain-clone (clone chain)]
          (reg.compiler-reg-same-value-class? (&mut chain-clone) 0 3)))
      (reg.compiler-reg-same-value-class? (&mut cast) 0 1))))

(define (compiler-reg-coalesce-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-move-chain-function))
    [(Plan chain-assignments _ _ _ _)
      (match (compiler-reg-plan-function (compiler-reg-phi-join-function))
        [(Plan phi-assignments _ _ _ _)
          (match (compiler-reg-plan-function
            (compiler-reg-loop-backedge-function))
            [(Plan loop-assignments _ _ _ _)
              (match (compiler-reg-plan-function
                (compiler-reg-interference-blocks-coalesce-function))
                [(Plan blocked-assignments _ _ _ _)
                  (match (compiler-reg-plan-function
                    (compiler-reg-spill-coalesce-function))
                    [(Plan spill-assignments _ _ _ _)
                      (and
                        (compiler-reg-move-list-parallel-decision-ok?)
                        (compiler-reg-same-location?
                          (clone chain-assignments)
                          0
                          1)
                        (compiler-reg-same-location?
                          (clone chain-assignments)
                          1
                          2)
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
  (irt.func
    "function @tail_dispatch(k=%0:i64, v=%1:i64) -> i64 vars 3 {
     entry:
       %2 = eq %0, 0 : i64
       branch %2, arm_a, arm_b
     arm_a:
       tailcall step_a(%0, %1) : i64
     arm_b:
       tailcall step_b(%1, %0) : i64
     }"))

;; Same dispatcher with a REAL call in the arm that runs FIRST in block order,
;; and both parameters live across it. Nothing may be un-pinned here.
(define (compiler-reg-tail-dispatch-real-call-function) : ir.CompilerIrFunction
  (irt.func
    "function @tail_dispatch_real(k=%0:i64, v=%1:i64) -> i64 vars 4 {
     entry:
       %2 = eq %0, 0 : i64
       branch %2, call_arm, tail_arm
     call_arm:
       %3 = call side_effect() : unit
       store @gk, %0 : i64
       store @gv, %1 : i64
       return %0
     tail_arm:
       tailcall step_b(%1, %0) : i64
     }"))

;; MIXED. `call_arm` runs first in block order and holds a real call that only
;; `v` is live across; `k` is referenced at entry and again in the LAST block,
;; so the real call sits inside `k`'s coarse interval HULL and inside no live
;; SEGMENT of it. `k` must therefore keep %rdi while `v` must not keep %rsi.
(define (compiler-reg-tail-dispatch-mixed-function) : ir.CompilerIrFunction
  (irt.func
    "function @tail_dispatch_mixed(k=%0:i64, v=%1:i64) -> i64 vars 4 {
     entry:
       %2 = eq %0, 0 : i64
       branch %2, call_arm, tail_arm
     call_arm:
       %3 = call side_effect() : unit
       store @gv, %1 : i64
       return %1
     tail_arm:
       tailcall step_b(%0) : i64
     }"))

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
        (let
          [clobber-kind-points
            (reg.compiler-reg-clobber-kind-points bases pure-fn 0)]
          (live.compiler-live-set-count clobber-kind-points))
        2)
      (=
        (let
          [clobber-kind-points
            (reg.compiler-reg-clobber-kind-points bases pure-fn 6)]
          (live.compiler-live-set-count clobber-kind-points))
        0)
      (=
        (let
          [clobber-kind-points
            (reg.compiler-reg-clobber-kind-points bases real-fn 0)]
          (live.compiler-live-set-count clobber-kind-points))
        2)
      (=
        (let
          [clobber-kind-points
            (reg.compiler-reg-clobber-kind-points bases real-fn 6)]
          (live.compiler-live-set-count clobber-kind-points))
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
      (not
        (let
          [segments-clone (clone segments)]
          [in-hole-clone (clone in-hole)]
          (reg.compiler-reg-segments-span-clobber?
            segments-clone
            in-hole-clone
            0
            false)))
      (let
        [segments-clone (clone segments)]
        [in-segment-clone (clone in-segment)]
        (reg.compiler-reg-segments-span-clobber?
          segments-clone
          in-segment-clone
          0
          false))
      ;; A clobber AT the hull start is the value's own defining instruction
      ;; for an ordinary value, and already inside the live range of a param.
      (not
        (let
          [segments-clone (clone segments)]
          [at-hull-start-clone (clone at-hull-start)]
          (reg.compiler-reg-segments-span-clobber?
            segments-clone
            at-hull-start-clone
            0
            false)))
      (let
        [segments-clone (clone segments)]
        [at-hull-start-clone (clone at-hull-start)]
        (reg.compiler-reg-segments-span-clobber?
          segments-clone
          at-hull-start-clone
          0
          true))
      ;; A later segment opens where the value flows IN from a predecessor, so
      ;; its start is inclusive under BOTH conventions.
      (let
        [segments-clone (clone segments)]
        [at-later-segment-start-clone (clone at-later-segment-start)]
        (reg.compiler-reg-segments-span-clobber?
          segments-clone
          at-later-segment-start-clone
          0
          false))
      (let
        [segments-clone (clone segments)]
        [at-later-segment-start-clone (clone at-later-segment-start)]
        (reg.compiler-reg-segments-span-clobber?
          segments-clone
          at-later-segment-start-clone
          0
          true)))))

(define (compiler-reg-tail-dispatch-pins-ok?) : bool
  (match (reg.compiler-reg-plan-function-scalar
    (compiler-reg-tail-dispatch-function))
    [(Plan assignments _ _ _ _)
      (and
        (= (compiler-reg-spill-count assignments) 0)
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
    [(Plan assignments _ _ _ _)
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
    [(Plan assignments _ _ _ _)
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
  (match (compiler-reg-plan-function (compiler-reg-vector-home-function))
    [(Plan vector-assignments _ _ _ _)
      (match (compiler-reg-plan-function
        (compiler-reg-vector-gp-clobber-home-function))
        [(Plan gp-clobber-assignments _ _ _ _)
          (match (compiler-reg-plan-function
            (compiler-reg-vector-select-false-home-function))
            [(Plan select-assignments _ _ _ _)
              (match (compiler-reg-plan-function
                (compiler-reg-mask-home-function))
                [(Plan mask-assignments _ _ _ _)
                  (let
                    [vector-ok : bool
                      (and
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            (clone vector-assignments)
                            0)
                          (cabi.compiler-abi-vector-register-id 6))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            (clone vector-assignments)
                            1)
                          (cabi.compiler-abi-vector-register-id 7))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            (clone vector-assignments)
                            2)
                          (cabi.compiler-abi-vector-register-id 7))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            (clone vector-assignments)
                            3)
                          (cabi.compiler-abi-vector-register-id 6)))]
                    [gp-clobber-ok : bool
                      (reg.compiler-reg-location-register?
                        (reg.compiler-reg-assignment-lookup
                          (clone gp-clobber-assignments)
                          0)
                        (cabi.compiler-abi-vector-register-id 6))]
                    [select-ok : bool
                      (and
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            (clone select-assignments)
                            1)
                          (cabi.compiler-abi-vector-register-id 7))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            (clone select-assignments)
                            2)
                          (cabi.compiler-abi-vector-register-id 8))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            (clone select-assignments)
                            4)
                          (cabi.compiler-abi-vector-register-id 7)))]
                    [mask-ok : bool
                      (and
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            (clone mask-assignments)
                            0)
                          (cabi.compiler-abi-mask-register-id 1))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            (clone mask-assignments)
                            1)
                          (cabi.compiler-abi-mask-register-id 2))
                        (reg.compiler-reg-location-register?
                          (reg.compiler-reg-assignment-lookup
                            (clone mask-assignments)
                            3)
                          (cabi.compiler-abi-mask-register-id 1)))]
                    (and vector-ok gp-clobber-ok select-ok mask-ok))])])])]))

(define (compiler-reg-mask-pressure-spill-home-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-mask-pressure-function))
    [(Plan assignments _ _ _ _)
      ;; Six architectural homes are allocatable (%k1..%k6); the seventh
      ;; simultaneously-live mask must stay unassigned for the backend's
      ;; stack-slot mask spill path.
      (match (reg.compiler-reg-assignment-lookup assignments 6)
        [(No) true]
        [_ false])]))

(define (compiler-reg-target-clobbers-ok?) : bool
  (let
    [_rbp-off : unit (reg.compiler-reg-set-rbp-pool-enabled! false)]
    [zero-call-callers : reg.CompilerRegIdSeq
      (compiler-reg-zero-call-caller-saved-integer-registers)]
    [greedy-pool : reg.CompilerRegIdSeq (reg.compiler-reg-greedy-integer-pool)]
    [sysv-callers : reg.CompilerRegIdSeq
      (compiler-reg-sysv-caller-saved-integer-registers)]
    [sysv-callees : reg.CompilerRegIdSeq
      (compiler-reg-sysv-callee-saved-integer-registers)]
    [win-callers : reg.CompilerRegIdSeq
      (compiler-reg-win64-caller-saved-integer-registers)]
    [win-callees : reg.CompilerRegIdSeq
      (reg.compiler-reg-win64-callee-saved-integer-registers)]
    [copy-instr : ir.CompilerIrInstr (irt.instr "copy_bytes %0, %1, 24")]
    [add-instr : ir.CompilerIrInstr (irt.instr "%2 = add %0, %1 : i64")]
    (and
      (reg.compiler-reg-id-seq-contains?
        (clone sysv-callers)
        cabi.compiler-reg-id-rdi)
      (not
        (reg.compiler-reg-id-seq-contains?
          (clone sysv-callees)
          cabi.compiler-reg-id-rdi))
      (reg.compiler-reg-id-seq-contains?
        (clone win-callees)
        cabi.compiler-reg-id-rdi)
      (not
        (reg.compiler-reg-id-seq-contains?
          (clone win-callers)
          cabi.compiler-reg-id-rdi))
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
      (reg.compiler-reg-id-seq-contains?
        (clone greedy-pool)
        cabi.compiler-reg-id-r8)
      (reg.compiler-reg-id-seq-contains?
        (clone greedy-pool)
        cabi.compiler-reg-id-r10)
      (reg.compiler-reg-id-seq-contains?
        (clone greedy-pool)
        cabi.compiler-reg-id-r11)
      ;; ABI-aware split: SysV caller-saved-count=9; Win64=7 (%rsi/%rdi are
      ;; nonvolatile on Win64 -> in the callee-saved suffix, not the prefix).
      (= (reg.compiler-reg-greedy-caller-saved-count-for-abi Linux) 9)
      (= (reg.compiler-reg-greedy-caller-saved-count-for-abi Windows) 7)
      (=
        (reg.compiler-reg-id-seq-count
          (reg.compiler-reg-greedy-integer-pool-for-abi Windows))
        14)
      (reg.compiler-reg-id-seq-contains?
        (reg.compiler-reg-greedy-integer-pool-for-abi Windows)
        cabi.compiler-reg-id-rsi)
      (reg.compiler-reg-id-seq-contains?
        (reg.compiler-reg-greedy-integer-pool-for-abi Windows)
        cabi.compiler-reg-id-rdi)
      ;; The scalar zero-call extension is the older three-register subset.
      ;; Keep ABI/result registers and Win64 callee-saved %rsi/%rdi out of it.
      (= (reg.compiler-reg-id-seq-count zero-call-callers) 3)
      (reg.compiler-reg-id-seq-contains?
        (clone zero-call-callers)
        cabi.compiler-reg-id-r9)
      (reg.compiler-reg-id-seq-contains?
        (clone zero-call-callers)
        cabi.compiler-reg-id-rcx)
      (reg.compiler-reg-id-seq-contains?
        (clone zero-call-callers)
        cabi.compiler-reg-id-rdx)
      (not
        (compiler-reg-backend-caller-clobber-instr-for-abi?
          Linux
          (clone copy-instr)))
      (compiler-reg-backend-caller-clobber-instr-for-abi?
        Windows
        (clone copy-instr))
      (not
        (compiler-reg-backend-caller-clobber-instr-for-abi?
          Linux
          (clone add-instr)))
      (compiler-reg-backend-caller-clobber-instr-for-abi?
        Windows
        (clone add-instr))
      (reg.compiler-reg-id-seq-contains?
        (clone sysv-callers)
        cabi.compiler-reg-id-rcx)
      (reg.compiler-reg-id-seq-contains?
        (clone sysv-callers)
        cabi.compiler-reg-id-rdx)
      (reg.compiler-reg-id-seq-contains?
        (clone sysv-callers)
        cabi.compiler-reg-id-r9)
      (reg.compiler-reg-id-seq-contains?
        (clone win-callers)
        cabi.compiler-reg-id-rcx)
      (reg.compiler-reg-id-seq-contains?
        (clone win-callers)
        cabi.compiler-reg-id-rdx)
      (reg.compiler-reg-id-seq-contains?
        (clone win-callers)
        cabi.compiler-reg-id-r9)
      (not
        (reg.compiler-reg-id-seq-contains?
          (clone zero-call-callers)
          cabi.compiler-reg-id-rax))
      ;; Win64 FPO appends %rbp to the nonvolatile suffix without moving the
      ;; seven-register volatile boundary or any existing pool member.
      (let
        [_rbp-on : unit (reg.compiler-reg-set-rbp-pool-enabled! true)]
        [fpo-pool : reg.CompilerRegIdSeq
          (reg.compiler-reg-greedy-integer-pool-for-abi Windows)]
        [ok : bool
          (and
            (= (reg.compiler-reg-id-seq-count fpo-pool) 15)
            (reg.compiler-reg-id-seq-contains?
              fpo-pool
              cabi.compiler-reg-id-rbp)
            (= (reg.compiler-reg-greedy-caller-saved-count-for-abi Windows) 7))]
        [_rbp-restore : unit (reg.compiler-reg-set-rbp-pool-enabled! false)]
        ok)
      (not
        (reg.compiler-reg-id-seq-contains?
          (clone zero-call-callers)
          cabi.compiler-reg-id-r8))
      (not
        (reg.compiler-reg-id-seq-contains?
          (clone zero-call-callers)
          cabi.compiler-reg-id-r10))
      (not
        (reg.compiler-reg-id-seq-contains?
          (clone zero-call-callers)
          cabi.compiler-reg-id-r11))
      (not
        (reg.compiler-reg-id-seq-contains?
          (clone zero-call-callers)
          cabi.compiler-reg-id-rdi))
      (not
        (reg.compiler-reg-id-seq-contains?
          (clone zero-call-callers)
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
      (reg.compiler-reg-xmm-registers-for-abi Linux)]
    [win-pool : reg.CompilerRegIdSeq
      (reg.compiler-reg-xmm-registers-for-abi Windows)]
    [win-vector-pool : reg.CompilerRegIdSeq
      (reg.compiler-reg-vector-registers-for-abi Windows)]
    [sysv-callers : reg.CompilerRegIdSeq
      (compiler-reg-sysv-caller-saved-xmm-registers)]
    [sysv-callees : reg.CompilerRegIdSeq
      (compiler-reg-sysv-callee-saved-xmm-registers)]
    [win-callers : reg.CompilerRegIdSeq
      (compiler-reg-win64-caller-saved-xmm-registers)]
    [win-callees : reg.CompilerRegIdSeq
      (compiler-reg-win64-callee-saved-xmm-registers)]
    [pool-ok : bool
      (and
        ;; Families 14 and 15 are fixed YMM/ZMM spill scratch. They must stay
        ;; outside both scalar-XMM and vector allocation pools so an implicit
        ;; spill temporary cannot overwrite an unrelated resident value.
        (= (reg.compiler-reg-id-seq-count sysv-pool) 12)
        (= (reg.compiler-reg-id-seq-count win-pool) 12)
        (= (reg.compiler-reg-id-seq-count win-vector-pool) 12)
        (= (reg.compiler-reg-xmm-caller-register-count-for-abi Linux) 12)
        (= (reg.compiler-reg-xmm-caller-register-count-for-abi Windows) 4)
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone sysv-pool)
            (cabi.compiler-abi-xmm-register-id 0)))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone sysv-pool)
            (cabi.compiler-abi-xmm-register-id 1)))
        (reg.compiler-reg-id-seq-contains?
          (clone sysv-pool)
          (cabi.compiler-abi-xmm-register-id 2))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone sysv-pool)
            (cabi.compiler-abi-xmm-register-id 14)))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone sysv-pool)
            (cabi.compiler-abi-xmm-register-id 15)))
        (reg.compiler-reg-id-seq-contains?
          (clone win-pool)
          (cabi.compiler-abi-xmm-register-id 2))
        (reg.compiler-reg-id-seq-contains?
          (clone win-pool)
          (cabi.compiler-abi-xmm-register-id 6))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone win-pool)
            (cabi.compiler-abi-xmm-register-id 14)))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone win-pool)
            (cabi.compiler-abi-xmm-register-id 15)))
        (reg.compiler-reg-id-seq-contains?
          (clone win-vector-pool)
          (cabi.compiler-abi-vector-register-id 2))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone win-vector-pool)
            (cabi.compiler-abi-vector-register-id 14)))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone win-vector-pool)
            (cabi.compiler-abi-vector-register-id 15)))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone win-vector-pool)
            (cabi.compiler-abi-vector-register-id 0)))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone win-vector-pool)
            (cabi.compiler-abi-vector-register-id 1))))]
    [sysv-ok : bool
      (and
        (reg.compiler-reg-id-seq-contains?
          (clone sysv-callers)
          (cabi.compiler-abi-xmm-register-id 14))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone sysv-callees)
            (cabi.compiler-abi-xmm-register-id 14))))]
    [win-ok : bool
      (and
        (reg.compiler-reg-id-seq-contains?
          (clone win-callers)
          (cabi.compiler-abi-xmm-register-id 5))
        (not
          (reg.compiler-reg-id-seq-contains?
            (clone win-callers)
            (cabi.compiler-abi-xmm-register-id 6)))
        (reg.compiler-reg-id-seq-contains?
          (clone win-callees)
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
      (let
        [candidates (clone intervals)]
        [regs
          (if vector
            (reg.compiler-reg-vector-registers-for-abi target-abi)
            (reg.compiler-reg-xmm-registers-for-abi target-abi))]
        [assignments (reg.compiler-reg-assignment-table-make 1)]
        [interval-index (reg.compiler-reg-interval-index-build intervals 1)]
        [group-vars (live.compiler-live-set-empty)]
        [param-roots (live.compiler-live-set-empty)]
        [param-entry-forbidden (__tl_make-array reg.CompilerRegIdSeq 0)]
        [ref-counts (__tl_make-array i64 0)]
        [copy-hints (__tl_make-array i64 0)]
        [arg-prefs (__tl_make-array i64 0)]
        [div-points (live.compiler-live-set-empty)]
        [shift-points (live.compiler-live-set-empty)]
        (reg.compiler-reg-greedy-state
          candidates
          regs
          assignments
          interval-index
          group-vars
          param-roots
          param-entry-forbidden
          ref-counts
          copy-hints
          arg-prefs
          call-points
          div-points
          shift-points
          (if vector
            (reg.compiler-reg-vector-callee-registers-for-abi target-abi)
            (reg.compiler-reg-xmm-callee-registers-for-abi target-abi))
          (if vector
            (reg.compiler-reg-vector-caller-register-count-for-abi target-abi)
            (reg.compiler-reg-xmm-caller-register-count-for-abi target-abi))
          -1))]
    (match state
      [(State _ assignments) assignments])))

(define (compiler-reg-xmm-abi-call-constraints-ok?) : bool
  (let
    [sysv-float : reg.CompilerRegAssignmentTable
      (compiler-reg-test-xmm-greedy-assignments Linux false true)]
    [win-float : reg.CompilerRegAssignmentTable
      (compiler-reg-test-xmm-greedy-assignments Windows false true)]
    [sysv-vector : reg.CompilerRegAssignmentTable
      (compiler-reg-test-xmm-greedy-assignments Linux true true)]
    [win-vector : reg.CompilerRegAssignmentTable
      (compiler-reg-test-xmm-greedy-assignments Windows true true)]
    [sysv-leaf : reg.CompilerRegAssignmentTable
      (compiler-reg-test-xmm-greedy-assignments Linux false false)]
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
        (cabi.compiler-abi-xmm-register-id 2)))))

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
        (clone vector-candidates))]
    [interval-index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build all-intervals 2)]
    [scalar-state : reg.CompilerRegAssignState
      (let
        [regs
          (reg.compiler-reg-id-seq-prepend
            (cabi.compiler-abi-xmm-register-id 6)
            (reg.compiler-reg-id-seq-empty))]
        [assignments (reg.compiler-reg-assignment-table-make 2)]
        [interval-index-2 (clone interval-index)]
        [group-vars (live.compiler-live-set-empty)]
        [param-roots (live.compiler-live-set-empty)]
        [param-entry-forbidden (__tl_make-array reg.CompilerRegIdSeq 0)]
        [ref-counts (__tl_make-array i64 0)]
        [copy-hints (__tl_make-array i64 0)]
        [arg-prefs (__tl_make-array i64 0)]
        [call-points (live.compiler-live-set-empty)]
        [div-points (live.compiler-live-set-empty)]
        [shift-points (live.compiler-live-set-empty)]
        (reg.compiler-reg-greedy-state
          scalar-candidates
          regs
          assignments
          interval-index-2
          group-vars
          param-roots
          param-entry-forbidden
          ref-counts
          copy-hints
          arg-prefs
          call-points
          div-points
          shift-points
          (reg.compiler-reg-id-seq-empty)
          1
          -1))]
    (match scalar-state
      [(State _ scalar-assignments)
        (match (let
          [regs (reg.compiler-reg-vector-registers-for-abi Linux)]
          [group-vars (live.compiler-live-set-empty)]
          [param-roots (live.compiler-live-set-empty)]
          [param-entry-forbidden (__tl_make-array reg.CompilerRegIdSeq 0)]
          [ref-counts (__tl_make-array i64 0)]
          [copy-hints (__tl_make-array i64 0)]
          [arg-prefs (__tl_make-array i64 0)]
          [call-points (live.compiler-live-set-empty)]
          [div-points (live.compiler-live-set-empty)]
          [shift-points (live.compiler-live-set-empty)]
          (reg.compiler-reg-greedy-state
            vector-candidates
            regs
            scalar-assignments
            interval-index
            group-vars
            param-roots
            param-entry-forbidden
            ref-counts
            copy-hints
            arg-prefs
            call-points
            div-points
            shift-points
            (reg.compiler-reg-id-seq-empty)
            14
            -1))
          [(State _ assignments)
            (let
              [items : reg.CompilerRegAssignmentTable assignments]
              (and
                (reg.compiler-reg-location-register?
                  (reg.compiler-reg-assignment-lookup (clone items) 0)
                  (cabi.compiler-abi-xmm-register-id 6))
                (reg.compiler-reg-location-register?
                  (reg.compiler-reg-assignment-lookup (clone items) 1)
                  (cabi.compiler-abi-vector-register-id 7))))])])))

(define (compiler-reg-xmm-vector-class-reset-ok?) : bool
  (let
    [candidates : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 10)
        (reg.compiler-reg-interval-seq-empty))]
    [index : reg.CompilerRegIntervalIndex
      (reg.compiler-reg-interval-index-build (clone candidates) 1)]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-table-insert
        (reg.compiler-reg-assignment-table-make 1)
        0
        (Register cabi.compiler-reg-id-r12))]
    [_reset : unit
      (reg.compiler-reg-unassign-special-candidates!
        assignments
        (reg.compiler-reg-global-shared-view candidates))]
    (match (let
      [regs (reg.compiler-reg-vector-registers-for-abi Linux)]
      [group-vars (live.compiler-live-set-empty)]
      [param-roots (live.compiler-live-set-empty)]
      [param-entry-forbidden (__tl_make-array reg.CompilerRegIdSeq 0)]
      [ref-counts (__tl_make-array i64 0)]
      [copy-hints (__tl_make-array i64 0)]
      [arg-prefs (__tl_make-array i64 0)]
      [call-points (live.compiler-live-set-empty)]
      [div-points (live.compiler-live-set-empty)]
      [shift-points (live.compiler-live-set-empty)]
      (reg.compiler-reg-greedy-state
        candidates
        regs
        assignments
        index
        group-vars
        param-roots
        param-entry-forbidden
        ref-counts
        copy-hints
        arg-prefs
        call-points
        div-points
        shift-points
        (reg.compiler-reg-id-seq-empty)
        14
        -1))
      [(State _ out)
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-table-lookup out 0)
          (cabi.compiler-abi-vector-register-id 6))])))

(define (compiler-reg-color-register-assignments-to [last : i64]) : reg.CompilerRegAssignmentTable
  (if (< last 0)
    (reg.compiler-reg-assignment-table-empty)
    (reg.compiler-reg-assignment-insert
      (compiler-reg-color-register-assignments-to (- last 1))
      last
      (Register cabi.compiler-reg-id-r12))))

(define (compiler-reg-color-storage-function) : ir.CompilerIrFunction
  (irt.func
    "function @storage_ranges() -> unit vars 6 {
     entry:
       %0 = alloc BigStorage
       %1 = alloc BigStorage
       %2 = addr_of %1
       store_ptr %2, 11 : i64
       %3 = alloc BigStorage
       %4 = alloc BigStorage
       %5 = addr_of %4
       store_ptr %5, 22 : i64
       return
     }"))

;; Stack-only planning still needs enough lifetime information to color the
;; frame. The two inline-storage ranges below live on mutually exclusive CFG
;; arms, so their backing words, address temporaries, and scalar additions may
;; share. Parameter var 0 must nevertheless retain its identity for prologue
;; spills.
(define (compiler-reg-stack-only-storage-branch-function) : ir.CompilerIrFunction
  (irt.func
    "function @stack_only_storage_branch(condition=%0:bool) -> unit vars 9 {
     entry:
       branch %0, left, right
     left:
       %1 = alloc StackOnlyStorage
       %2 = alloc StackOnlyStorage
       %3 = addr_of %2
       %4 = add 10, 1 : i64
       store_ptr %3, %4 : i64
       jump join
     right:
       %5 = alloc StackOnlyStorage
       %6 = alloc StackOnlyStorage
       %7 = addr_of %6
       %8 = add 20, 2 : i64
       store_ptr %7, %8 : i64
       jump join
     join:
       return
     }"))

;; The first address remains live across construction of the second range and
;; escapes through a call. Its backing range must stay private even though the
;; planner itself performs no scalar register allocation.
(define (compiler-reg-stack-only-storage-escape-function) : ir.CompilerIrFunction
  (irt.func
    "function @stack_only_storage_escape() -> unit vars 7 {
     entry:
       %0 = alloc StackOnlyEscape
       %1 = alloc StackOnlyEscape
       %2 = addr_of %1
       store_ptr %2, 11 : i64
       %3 = alloc StackOnlyEscape
       %4 = alloc StackOnlyEscape
       %5 = addr_of %4
       store_ptr %5, 22 : i64
       %6 = call escape(%2) : unit
       return
     }"))

;; Block-level hulls (`compiler-reg-block-intervals`), rendered as
;; `var:start-end` and pinned to what the dense bit-matrix fixpoint produced
;; before the per-variable walk replaced it (#8417).
(define (compiler-reg-block-hulls-text [func : ir.CompilerIrFunction]) : String
  (let
    [hulls : reg.CompilerRegIntervalSeq (reg.compiler-reg-block-intervals func)]
    [slots : (__tl_dyn-array reg.CompilerRegInterval) hulls.slots]
    [out : String ""]
    [index : i64 0]
    (while (< index hulls.len)
      (let
        [hull : reg.CompilerRegInterval (array-ref slots index)]
        (set!
          out
          (str_cat.str-cat
            out
            (string.int->string hull.var)
            ":"
            (string.int->string hull.start)
            "-"
            (string.int->string hull.end)
            " "))
        (set! index (+ index 1))))
    out))

;; A loop: the phi'd counter and the bound stay live around the back edge.
(define (compiler-reg-block-hulls-loop-function) : ir.CompilerIrFunction
  (irt.func
    "function @hulls_loop(bound=%0:i64) -> i64 vars 6 {
     entry:
       %1 = mov 0 : i64
       jump header
     header:
       %2 = phi [%1, entry], [%4, body] : i64
       %3 = lt %2, %0 : i64
       branch %3, body, exit
     body:
       %4 = add %2, 1 : i64
       jump header
     exit:
       %5 = add %2, %0 : i64
       return %5
     }"))

;; A self-looping block whose leading phis read each other's previous values:
;; the lagged copy keeps `%3` live around the back edge.
(define (compiler-reg-block-hulls-lagged-function) : ir.CompilerIrFunction
  (irt.func
    "function @hulls_lagged(bound=%0:i64) -> i64 vars 6 {
     entry:
       %1 = mov 0 : i64
       jump header
     header:
       %2 = phi [%1, entry], [%3, header] : i64
       %3 = phi [%1, entry], [%4, header] : i64
       %4 = add %3, 1 : i64
       %5 = lt %4, %0 : i64
       branch %5, header, exit
     exit:
       return %2
     }"))

;; Vars in three different scratch words. `%65` is used before its redefinition
;; in `middle` (upward-exposed); `%40` is defined before its use there (not).
(define (compiler-reg-block-hulls-words-function) : ir.CompilerIrFunction
  (irt.func
    "function @hulls_words(x=%0:i64) -> i64 vars 70 {
     entry:
       %65 = add %0, 1 : i64
       %33 = add %65, %0 : i64
       jump middle
     middle:
       %66 = add %65, 2 : i64
       %65 = add %66, 3 : i64
       %40 = add %0, 4 : i64
       %41 = add %40, %66 : i64
       jump last
     last:
       %67 = add %33, %65 : i64
       %68 = add %67, %41 : i64
       return %68
     }"))

;; A call with 65 distinct arguments, wider than the id extraction buffer, so
;; its uses take the bitset path.
(define (compiler-reg-block-hulls-wide-function) : ir.CompilerIrFunction
  (let
    [text : String "function @hulls_wide() -> i64 vars 67 {\n entry:\n"]
    [args : String ""]
    [index : i64 1]
    (while (<= index 65)
      (set!
        text
        (str_cat.str-cat
          text
          "   %"
          (string.int->string index)
          " = mov "
          (string.int->string index)
          " : i64\n"))
      (set!
        args
        (str_cat.str-cat
          args
          (if (= index 1)
            ""
            ", ")
          "%"
          (string.int->string index)))
      (set! index (+ index 1)))
    (irt.func
      (str_cat.str-cat
        text
        "   jump call\n call:\n   %66 = call wide("
        args
        ") : i64\n   return %66\n }"))))

(define (compiler-reg-block-hulls-wide-expected) : String
  (let
    [out : String ""]
    [index : i64 1]
    (while (<= index 65)
      (set!
        out
        (str_cat.str-cat
          out
          (string.int->string index)
          ":"
          (string.int->string (* 2 (- index 1)))
          "-132 "))
      (set! index (+ index 1)))
    (str_cat.str-cat out "66:132-134 ")))

(define (compiler-reg-block-hulls-ok?) : bool
  (and
    (string.eq
      (compiler-reg-block-hulls-text (compiler-reg-block-hulls-loop-function))
      "0:0-14 1:0-14 2:4-14 3:6-8 4:0-14 5:14-16 ")
    (string.eq
      (compiler-reg-block-hulls-text (compiler-reg-block-hulls-lagged-function))
      "0:0-14 1:0-14 2:4-14 3:0-14 4:0-14 5:10-12 ")
    (string.eq
      (compiler-reg-block-hulls-text (compiler-reg-block-hulls-words-function))
      "0:0-10 33:2-16 40:10-12 41:12-18 65:0-16 66:6-12 67:16-18 68:18-20 ")
    (string.eq
      (compiler-reg-block-hulls-text (compiler-reg-block-hulls-wide-function))
      (compiler-reg-block-hulls-wide-expected))))

(define (compiler-reg-color-pointer-assignments) : reg.CompilerRegAssignmentTable
  (reg.compiler-reg-assignment-insert
    (reg.compiler-reg-assignment-insert
      (reg.compiler-reg-assignment-table-empty)
      2
      (Register cabi.compiler-reg-id-r12))
    5
    (Register cabi.compiler-reg-id-r13)))

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
      (U64))
    2
    (U64)))

(define (compiler-reg-color-spill-sharing-assignments [vars : i64]) : reg.CompilerRegAssignmentTable
  (if (< vars 1)
    (reg.compiler-reg-assignment-table-empty)
    (reg.compiler-reg-assignment-insert
      (compiler-reg-color-spill-sharing-assignments (- vars 1))
      (- vars 1)
      (Spill (* (- vars 1) 8)))))

(define (compiler-reg-color-spill-sharing-types [vars : i64]) : reg.CompilerRegVarTypes
  (if (< vars 1)
    (reg.compiler-reg-var-types-empty)
    (reg.compiler-reg-var-types-insert
      (compiler-reg-color-spill-sharing-types (- vars 1))
      (- vars 1)
      (I64))))

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
  (match (compiler-reg-color-stack-slots
    (ast.ast-node-pool-reader-type-segment-bases)
    (Plan
      (compiler-reg-color-spill-sharing-assignments 3)
      (live.compiler-live-set-empty)
      (compiler-reg-color-spill-sharing-intervals)
      (compiler-reg-color-spill-sharing-types 3)
      (reg.compiler-reg-call-split-empty))
    (live.compiler-live-set-empty)
    (ir.compiler-ir-param-seq-empty)
    (ir.compiler-ir-block-list-empty)
    3
    3
    (live.compiler-live-set-empty))
    [(Remap share-remap share-slots)
      (match (compiler-reg-color-stack-slots
        (ast.ast-node-pool-reader-type-segment-bases)
        (Plan
          (compiler-reg-color-spill-sharing-assignments 2)
          (live.compiler-live-set-empty)
          (compiler-reg-color-spill-split-intervals)
          (compiler-reg-color-spill-sharing-types 2)
          (reg.compiler-reg-call-split-empty))
        (live.compiler-live-set-empty)
        (ir.compiler-ir-param-seq-empty)
        (ir.compiler-ir-block-list-empty)
        2
        2
        (live.compiler-live-set-empty))
        [(Remap split-remap split-slots)
          (and
            (= share-slots 2)
            (= (array-ref share-remap 0) (array-ref share-remap 1))
            (not (= (array-ref share-remap 0) (array-ref share-remap 2)))
            (= split-slots 2)
            (not (= (array-ref split-remap 0) (array-ref split-remap 1))))]
        [(None) false])]
    [(None) false]))

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
  (compiler-reg-color-stack-slots
    (ast.ast-node-pool-reader-type-segment-bases)
    (Plan
      (compiler-reg-color-spill-sharing-assignments 4)
      (live.compiler-live-set-empty)
      (compiler-reg-color-fusion-pin-intervals)
      (compiler-reg-color-spill-sharing-types 4)
      (reg.compiler-reg-call-split-empty))
    (live.compiler-live-set-empty)
    (ir.compiler-ir-param-seq-empty)
    (ir.compiler-ir-block-list-empty)
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
    [(Remap merged-remap merged-slots)
      (match (compiler-reg-color-fusion-pin-coloring
        (live_tests.compiler-live-set2 0 1))
        [(Remap pin-remap pin-slots)
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
        [(None) false])]
    [(None) false]))

(define (compiler-reg-color-spill-param-pins-ok?) : bool
  (match (compiler-reg-color-stack-slots
    (ast.ast-node-pool-reader-type-segment-bases)
    (Plan
      (compiler-reg-color-spill-sharing-assignments 3)
      (live.compiler-live-set-empty)
      (compiler-reg-color-spill-param-intervals)
      (compiler-reg-color-spill-sharing-types 3)
      (reg.compiler-reg-call-split-empty))
    (live.compiler-live-set-empty)
    (irt.params "pinned=%1:i64")
    (ir.compiler-ir-block-list-empty)
    3
    3
    (live.compiler-live-set-empty))
    [(Remap remap slots)
      (and
        (= slots 2)
        (= (array-ref remap 1) 1)
        (= (array-ref remap 0) (array-ref remap 2))
        (not (= (array-ref remap 0) 1)))]
    [(None) false]))

(define (compiler-reg-color-avx2-param-ranges-ok?) : bool
  (let
    [params : ir.CompilerIrParamSeq
      (irt.params
        "__tl_spmd_active_mask_avx2=%0:bool, __tl_spmd_varying_arg_avx2_x=%1:i64, __tl_spmd_index_base=%2:i64")]
    [assignments : reg.CompilerRegAssignmentTable
      (reg.compiler-reg-assignment-insert
        (reg.compiler-reg-assignment-table-empty)
        1
        (Register cabi.compiler-reg-id-r12))]
    (match (compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (Plan
        (clone assignments)
        (live.compiler-live-set-empty)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 0 1)
          (reg.compiler-reg-interval-seq-empty))
        (reg.compiler-reg-var-types-insert
          (reg.compiler-reg-var-types-empty)
          1
          (I64))
        (reg.compiler-reg-call-split-empty))
      (live.compiler-live-set-empty)
      (clone params)
      (ir.compiler-ir-block-list-empty)
      3
      3
      (live.compiler-live-set-empty))
      [(Remap remap slots)
        (let
          [active : i64 (array-ref remap 0)]
          [varying : i64 (array-ref remap 1)]
          [uniform : i64 (array-ref remap 2)]
          [rebuilt : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-color-rebuild-assignments
              (clone remap)
              3
              (clone assignments))]
          [rebuilt-index : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-assignment-table-with-min-capacity rebuilt 3)]
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
            (let
              [remapped : ir.CompilerIrParamSeq
                (reg.compiler-reg-remap-params remap params)]
              (and
                (= remapped.len 3)
                (match (ir.compiler-ir-param-seq-ref remapped 0)
                  [(Param _ _ active-param) (= active-param active)])
                (match (ir.compiler-ir-param-seq-ref remapped 1)
                  [(Param _ _ varying-param) (= varying-param varying)])
                (match (ir.compiler-ir-param-seq-ref remapped 2)
                  [(Param _ _ uniform-param) (= uniform-param uniform)]))))
          true)]
      [(None) false])))

(define (compiler-reg-color-spill-hole-demand-ok?) : bool
  (match (compiler-reg-color-stack-slots
    (ast.ast-node-pool-reader-type-segment-bases)
    (Plan
      (compiler-reg-color-spill-sharing-assignments 1)
      (live.compiler-live-set-empty)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 0 1)
        (reg.compiler-reg-interval-seq-empty))
      (compiler-reg-color-spill-sharing-types 1)
      (reg.compiler-reg-call-split-empty))
    (live.compiler-live-set-empty)
    (ir.compiler-ir-param-seq-empty)
    (ir.compiler-ir-block-list-empty)
    10
    10
    (live.compiler-live-set-empty))
    [(Remap remap slots)
      (and
        (= slots 1)
        (= (array-ref remap 0) 0)
        (not (= (array-ref remap 9) 0)))]
    [(None) false]))

(define (compiler-reg-color-spill-scratch-demand-ok?) : bool
  (let
    [params : ir.CompilerIrParamSeq (irt.params "real=%0:i64")]
    (match (compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (Plan
        (compiler-reg-color-spill-sharing-assignments 2)
        (live.compiler-live-set-empty)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 0 0 1)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 1 0 1)
            (reg.compiler-reg-interval-seq-empty)))
        (compiler-reg-color-spill-sharing-types 2)
        (reg.compiler-reg-call-split-empty))
      (live.compiler-live-set-empty)
      params
      (ir.compiler-ir-block-list-empty)
      2
      1
      (live.compiler-live-set-empty))
      [(Remap remap slots)
        (and (= slots 1) (= (array-ref remap 0) 0) (= (array-ref remap 1) 1))]
      [(None) false])))

(define (compiler-reg-color-vector-stack-function) : ir.CompilerIrFunction
  (irt.func
    "function @vector_stack_slots() -> unit vars 3 {
     entry:
       %0 = vector_load 0, 0 lanes 4 : i64
       %1 = vector_load 0, 0 lanes 8 : i64
       %2 = tail_mask 0, 1 lanes 8
       return
     }"))

(define (compiler-reg-color-vector-stack-slots-ok?) : bool
  (match (compiler-reg-color-vector-stack-function)
    [(Function _ params _ vars blocks _)
      (match (compiler-reg-color-stack-slots
        (ast.ast-node-pool-reader-type-segment-bases)
        (Plan
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
          (reg.compiler-reg-call-split-empty))
        (live.compiler-live-set-empty)
        params
        blocks
        vars
        vars
        (live.compiler-live-set-empty))
        [(Remap remap slots)
          (and
            (= (array-ref remap 0) 3)
            (= (array-ref remap 1) 11)
            (= (array-ref remap 2) 15)
            (= slots 16))]
        [(None) false])]))

(define (compiler-reg-vector-stack-mask-words-ok?) : bool
  (let
    [words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    (reg.compiler-reg-vector-stack-words-instr!
      (ir.ir-instr-vector-compare 0 (Eq) (I64 0) (I64 0) 8 (I32))
      (&mut words))
    (reg.compiler-reg-vector-stack-words-instr!
      (irt.instr "%1 = mask_and %0, %0 lanes 8")
      (&mut words))
    (reg.compiler-reg-vector-stack-words-instr!
      (MaskNot 2 (Var 1) 8)
      (&mut words))
    (reg.compiler-reg-vector-stack-words-instr!
      (irt.instr "%3 = tail_mask 0, 1 lanes 8")
      (&mut words))
    (reg.compiler-reg-vector-stack-words-instr!
      (ir.ir-instr-predicated-load 4 (I64 0) (I64 0) (Var 3) 8 (Bool))
      (&mut words))
    (reg.compiler-reg-vector-stack-words-instr!
      (ir.ir-instr-select 5 (Var 3) (Var 4) (Var 4) 8 (Bool))
      (&mut words))
    (and
      (= (array-ref words 0) 4)
      (= (array-ref words 1) 4)
      (= (array-ref words 2) 4)
      (= (array-ref words 3) 4)
      (= (array-ref words 4) 4)
      (= (array-ref words 5) 4))))

(define (compiler-reg-simd-copy-class-function) : ir.CompilerIrFunction
  (Function
    (ir.compiler-ir-test-symbol "simd_copy_class")
    (ir.compiler-ir-param-seq-empty)
    (Unit)
    6
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-reg-test-instr-seq-prepend
          (irt.instr "%2 = mov %1 : i64")
          (compiler-reg-test-instr-seq-prepend
            (irt.instr "%1 = mov %0 : i64")
            (compiler-reg-test-instr-seq-prepend
              (irt.instr "%0 = splat 7 lanes 8 : i64")
              (compiler-reg-test-instr-seq-prepend
                (irt.instr "%5 = mov %4 : bool")
                (compiler-reg-test-instr-seq-prepend
                  (irt.instr "%4 = mov %3 : bool")
                  (compiler-reg-test-instr-seq-prepend
                    (ir.ir-instr-vector-compare 3 (Eq) (Var 0) (Var 0) 8 (I64))
                    (irt.instrs "return")))))))))
    Ordinary))

(define (compiler-reg-simd-copy-classes-and-widths-ok?) : bool
  (let
    [func : ir.CompilerIrFunction (compiler-reg-simd-copy-class-function)]
    [classes : live.CompilerLiveUseDef
      (reg.compiler-reg-function-vector-mask-defs
        (reg.compiler-reg-global-shared-view func))]
    [words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    (match func
      [(Function _ _ _ _ blocks _)
        (reg.compiler-reg-vector-stack-words-blocks!
          (reg.compiler-reg-global-shared-view blocks)
          (&mut words))
        (reg.compiler-reg-vector-stack-words-fixpoint! blocks (&mut words))
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
          (= (array-ref words 5) 4))])))

(test
  regalloc-simd-copy-class-fixpoint
  (test.assert-true
    (compiler-reg-simd-copy-classes-and-widths-ok?)
    "vector/mask register classes and full spill widths flow through out-of-order Mov chains"))

(define (compiler-reg-color-storage-ranges-ok?) : bool
  (match (compiler-reg-color-storage-function)
    [(Function _ params _ vars blocks _)
      (match (compiler-reg-color-stack-slots
        (ast.ast-node-pool-reader-type-segment-bases)
        (Plan
          (compiler-reg-color-pointer-assignments)
          (live.compiler-live-set-empty)
          (compiler-reg-color-pointer-intervals)
          (compiler-reg-color-pointer-types)
          (reg.compiler-reg-call-split-empty))
        (live.compiler-live-set-empty)
        params
        blocks
        vars
        vars
        (live.compiler-live-set-empty))
        [(Remap remap slots)
          (and
            (= slots 2)
            (= (array-ref remap 0) 0)
            (= (array-ref remap 1) 1)
            (= (array-ref remap 3) 0)
            (= (array-ref remap 4) 1))]
        [(None) false])]))

;; The hidden output pointer is borrowed only across the call. Its result is
;; another alias of the same two-word range; an ordinary pointer call must
;; still invalidate the range even when it has the same physical ABI.
(define (compiler-reg-sret-color-blocks
  [ordinary? : bool]
  [overlap? : bool]
  [derived-escape? : bool]
  [structural? : bool]) : ir.CompilerIrBlockList
  (let
    [big : ast.AstType (Struct (ci.intern "SretColor"))]
    [builder : ir.CompilerIrInstrBuilder
      (ir.compiler-ir-instr-builder-with-capacity 12)]
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.Alloc 0 (clone big)))
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.Alloc 1 (clone big)))
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.AddrOf 2 1))
    (if structural?
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (irt.instr "%12 = cast %2 : (Array i64 2) to u64"))
      unit)
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.Call
        3
        (ir.compiler-ir-test-symbol "sret_one")
        (if ordinary?
          (One
            (Var
              (if structural?
                12
                2)))
          (ir.compiler-ir-call-args-sret-from-seq
            (ir.compiler-ir-value-seq1
              (Var
                (if structural?
                  12
                  2)))
            0))
        (U64)))
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.Load
        4
        (Var
          (if ordinary?
            2
            3))
        (I64)))
    (if derived-escape?
      (begin
        (ir.compiler-ir-instr-builder-push!
          (&mut builder)
          (irt.instr "%10 = gep %2, 0 : u64"))
        (ir.compiler-ir-instr-builder-push!
          (&mut builder)
          (irt.instr "%11 = call escaping_pointer(%10) : u64")))
      unit)
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.Alloc 5 (clone big)))
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.Alloc 6 big))
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.AddrOf 7 6))
    (if structural?
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (irt.instr "%13 = cast %7 : (Array i64 2) to u64"))
      unit)
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.Call
        8
        (ir.compiler-ir-test-symbol "sret_two")
        (ir.compiler-ir-call-args-sret-from-seq
          (ir.compiler-ir-value-seq1
            (Var
              (if structural?
                13
                7)))
          0)
        (U64)))
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.Load 9 (Var 8) (I64)))
    (if overlap?
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (irt.instr "%10 = load %3 : i64"))
      unit)
    (ir.compiler-ir-instr-builder-push!
      (&mut builder)
      (ir.CompilerIrInstr.Return No))
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-builder-to-seq builder)))))

(define (compiler-reg-sret-color-intervals
  [overlap? : bool]
  [derived-escape? : bool]
  [structural? : bool]) : reg.CompilerRegIntervalSeq
  (let
    [second : i64
      (if derived-escape?
        9
        7)]
    [shift : i64
      (if structural?
        1
        0)]
    [rest : reg.CompilerRegIntervalSeq
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval
          2
          2
          (+
            shift
            (if derived-escape?
              6
              4)))
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval
            3
            (+ shift 3)
            (+
              (* shift 2)
              (if overlap?
                10
                4)))
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval
              7
              (+ second shift)
              (+ second 2 (* shift 2)))
            (reg.compiler-reg-interval-seq-prepend
              (reg.CompilerRegInterval
                8
                (+ second 1 (* shift 2))
                (+ second 2 (* shift 2)))
              (if structural?
                (reg.compiler-reg-interval-seq-prepend
                  (reg.CompilerRegInterval 12 3 4)
                  (reg.compiler-reg-interval-seq-prepend
                    (reg.CompilerRegInterval 13 (+ second 2) (+ second 3))
                    (reg.compiler-reg-interval-seq-empty)))
                (reg.compiler-reg-interval-seq-empty))))))]
    (if derived-escape?
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 10 5 6)
        rest)
      rest)))

(define (compiler-reg-sret-color-case
  [ordinary? : bool]
  [overlap? : bool]
  [derived-escape? : bool]
  [structural? : bool]) : bool
  (let
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 32)]
    [remap : (__tl_dyn-array i64) (__tl_make-array i64 14)]
    [index : i64 0]
    (while (< index 32)
      (set! (array-ref slots index) -1)
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index 14)
      (set! (array-ref remap index) -1)
      (set! index (+ index 1)))
    (reg.compiler-reg-color-inline-storage
      (compiler-reg-sret-color-blocks
        ordinary?
        overlap?
        derived-escape?
        structural?)
      (compiler-reg-sret-color-intervals overlap? derived-escape? structural?)
      (&mut slots)
      (&mut remap)
      14
      0)
    (if (or ordinary? overlap? derived-escape?)
      (not (= (array-ref remap 0) (array-ref remap 5)))
      (and
        (= (array-ref remap 0) (array-ref remap 5))
        (= (array-ref remap 1) (array-ref remap 6))))))

(test
  regalloc-call-scoped-sret-storage
  (test.assert-true
    (and
      (compiler-reg-sret-color-case false false false false)
      (compiler-reg-sret-color-case true false false false)
      (compiler-reg-sret-color-case false true false false)
      (compiler-reg-sret-color-case false false true false)
      (compiler-reg-sret-color-case false false false true)
      (compiler-reg-sret-color-case true false false true))
    "sret calls reuse disjoint ranges; ordinary, derived and overlapping uses do not"))

;; Coalescing class chains (#7874). The coalescer enumerates a class by
;; walking `next` from its root; these fixtures hold that walk to a full scan of
;; `parents`, the enumeration it replaced, after every merge.
(cfg
  test
  (defstruct CompilerRegCoalesceTestMap
    (parents (__tl_dyn-array i64))
    (sizes (__tl_dyn-array i64))
    (next (__tl_dyn-array i64))
    (tail (__tl_dyn-array i64))
    (starts (__tl_dyn-array i64))
    (ends (__tl_dyn-array i64))))

;; Every var starts as its own one-member class with no coarse extent.
(cfg
  test
  (define (compiler-reg-coalesce-test-map [n : i64]) : CompilerRegCoalesceTestMap
    (let
      [parents : (__tl_dyn-array i64) (__tl_make-array i64 n)]
      [sizes : (__tl_dyn-array i64) (__tl_make-array i64 n)]
      [next : (__tl_dyn-array i64) (__tl_make-array i64 n)]
      [tail : (__tl_dyn-array i64) (__tl_make-array i64 n)]
      [starts : (__tl_dyn-array i64) (__tl_make-array i64 n)]
      [ends : (__tl_dyn-array i64) (__tl_make-array i64 n)]
      [index : i64 0]
      (reg.compiler-reg-coalesce-map-init! (&mut parents) (&mut sizes) 0)
      (reg.compiler-reg-coalesce-chains-init! (&mut next) (&mut tail))
      (while (< index n)
        (set! (array-ref starts index) -1)
        (set! (array-ref ends index) -1)
        (set! index (+ index 1)))
      (CompilerRegCoalesceTestMap parents sizes next tail starts ends))))

;; Merges the classes of `left` and `right` the way the coalescer does: the
;; smaller root wins. Returns false when they already share a class.
(cfg
  test
  (define (compiler-reg-coalesce-test-union!
    [map : CompilerRegCoalesceTestMap]
    [left : i64]
    [right : i64]) : bool
    (let
      [left-root : i64 (array-ref map.parents left)]
      [right-root : i64 (array-ref map.parents right)]
      (if (= left-root right-root)
        false
        (begin
          (reg.compiler-reg-coalesce-map-merge-root-into!
            (owned_view.compiler-owned-shared-view map.parents)
            (owned_view.compiler-owned-shared-view map.sizes)
            (owned_view.compiler-owned-shared-view map.next)
            (owned_view.compiler-owned-shared-view map.tail)
            (owned_view.compiler-owned-shared-view map.starts)
            (owned_view.compiler-owned-shared-view map.ends)
            (if (< left-root right-root)
              left-root
              right-root)
            (if (< left-root right-root)
              right-root
              left-root))
          true)))))

;; The chain from each root visits exactly the vars a full scan of `parents`
;; assigns to that root, each once, ends at `tail[root]` and counts
;; `sizes[root]`; a var that is no root heads no class and has size 0.
(cfg
  test
  (define (compiler-reg-coalesce-test-chains-match-scan?
    [map : (& map CompilerRegCoalesceTestMap)]) : bool
    (let
      [n : i64 (array-length map.parents)]
      [seen : (__tl_dyn-array bool) (__tl_make-array bool n)]
      [root : i64 0]
      [ok : bool true]
      (while (and ok (< root n))
        (let
          [scanned : i64 0]
          [var : i64 0]
          (while (< var n)
            (if (= (array-ref map.parents var) root)
              (set! scanned (+ scanned 1))
              unit)
            (set! var (+ var 1)))
          (if (= (array-ref map.parents root) root)
            (let
              [member : i64 root]
              [walked : i64 0]
              [last : i64 -1]
              (while (and ok (>= member 0) (<= walked n))
                (set!
                  ok
                  (and
                    (= (array-ref map.parents member) root)
                    (not (array-ref seen member))))
                (set! (array-ref seen member) true)
                (set! last member)
                (set! walked (+ walked 1))
                (set! member (array-ref map.next member)))
              (set!
                ok
                (and
                  ok
                  (< member 0)
                  (= walked scanned)
                  (= walked (array-ref map.sizes root))
                  (= last (array-ref map.tail root)))))
            (set! ok (and (= scanned 0) (= (array-ref map.sizes root) 0))))
          (set! root (+ root 1))))
      ok)))

;; The members of `root`'s class in chain order, as one comparable number:
;; each member contributes a base-64 digit.
(cfg
  test
  (define (compiler-reg-coalesce-test-chain-digits
    [map : (& map CompilerRegCoalesceTestMap)]
    [root : i64]) : i64
    (let
      [member : i64 root]
      [digits : i64 0]
      (while (>= member 0)
        (set! digits (+ (* digits 64) member))
        (set! member (array-ref map.next member)))
      digits)))

(cfg
  test
  (define (compiler-reg-coalesce-chains-singletons-ok?) : bool
    (let
      [map : CompilerRegCoalesceTestMap (compiler-reg-coalesce-test-map 5)]
      (and
        (compiler-reg-coalesce-test-chains-match-scan? (& map))
        (= (compiler-reg-coalesce-test-chain-digits (& map) 3) 3)
        (= (array-ref map.tail 3) 3)
        (= (array-ref map.sizes 3) 1)))))

;; Winner and loser are both multi-member: {0 1 2} absorbs {3 4}. The loser's
;; chain is spliced behind the winner's, so the class reads 0 1 2 3 4.
(cfg
  test
  (define (compiler-reg-coalesce-chains-multi-member-ok?) : bool
    (let
      [map : CompilerRegCoalesceTestMap (compiler-reg-coalesce-test-map 6)]
      [built : bool
        (and
          (compiler-reg-coalesce-test-union!
            (owned_view.compiler-owned-shared-view map)
            0
            1)
          (compiler-reg-coalesce-test-union!
            (owned_view.compiler-owned-shared-view map)
            2
            1)
          (compiler-reg-coalesce-test-union!
            (owned_view.compiler-owned-shared-view map)
            4
            3)
          (compiler-reg-coalesce-test-chains-match-scan? (& map))
          (compiler-reg-coalesce-test-union!
            (owned_view.compiler-owned-shared-view map)
            4
            2))]
      (and
        built
        (compiler-reg-coalesce-test-chains-match-scan? (& map))
        (=
          (compiler-reg-coalesce-test-chain-digits (& map) 0)
          (+ (* 64 (+ (* 64 (+ (* 64 (+ (* 64 0) 1)) 2)) 3)) 4))
        (= (array-ref map.tail 0) 4)
        (= (array-ref map.sizes 0) 5)
        (= (array-ref map.sizes 3) 0)
        (= (compiler-reg-coalesce-test-chain-digits (& map) 5) 5)))))

;; Three classes {0 1} {2 3 4} {5} joined in all six orders: the final class
;; always holds all six vars, and every intermediate state matches the scan.
(cfg
  test
  (define (compiler-reg-coalesce-chains-order-case-ok?
    [first : i64]
    [second : i64]
    [third : i64]) : bool
    (let
      [map : CompilerRegCoalesceTestMap (compiler-reg-coalesce-test-map 6)]
      [heads : (__tl_dyn-array i64) (__tl_make-array i64 3)]
      (set! (array-ref heads 0) 1)
      (set! (array-ref heads 1) 4)
      (set! (array-ref heads 2) 5)
      (and
        (compiler-reg-coalesce-test-union!
          (owned_view.compiler-owned-shared-view map)
          1
          0)
        (compiler-reg-coalesce-test-union!
          (owned_view.compiler-owned-shared-view map)
          3
          2)
        (compiler-reg-coalesce-test-union!
          (owned_view.compiler-owned-shared-view map)
          4
          3)
        (compiler-reg-coalesce-test-union!
          (owned_view.compiler-owned-shared-view map)
          (array-ref heads first)
          (array-ref heads second))
        (compiler-reg-coalesce-test-chains-match-scan? (& map))
        (compiler-reg-coalesce-test-union!
          (owned_view.compiler-owned-shared-view map)
          (array-ref heads second)
          (array-ref heads third))
        (compiler-reg-coalesce-test-chains-match-scan? (& map))
        (= (array-ref map.sizes 0) 6)
        (= (array-ref map.parents 5) 0)))))

(cfg
  test
  (define (compiler-reg-coalesce-chains-merge-orders-ok?) : bool
    (and
      (compiler-reg-coalesce-chains-order-case-ok? 0 1 2)
      (compiler-reg-coalesce-chains-order-case-ok? 0 2 1)
      (compiler-reg-coalesce-chains-order-case-ok? 1 0 2)
      (compiler-reg-coalesce-chains-order-case-ok? 1 2 0)
      (compiler-reg-coalesce-chains-order-case-ok? 2 0 1)
      (compiler-reg-coalesce-chains-order-case-ok? 2 1 0))))

;; A join of two vars that already share a class is declined before any
;; interval or fact is read, and leaves every array as it was.
(cfg
  test
  (define (compiler-reg-coalesce-chains-self-merge-declined-ok?) : bool
    (let
      [map : CompilerRegCoalesceTestMap (compiler-reg-coalesce-test-map 4)]
      [intervals : reg.CompilerRegIntervalIndex
        (reg.CompilerRegIntervalIndex
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array reg.CompilerRegIntervalSeq 0))]
      [facts : reg.CompilerRegCoalesceFacts
        (reg.CompilerRegCoalesceFacts
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0))]
      [sv-parents : (__tl_dyn-array i64) (__tl_make-array i64 0)]
      [joined : bool
        (and
          (compiler-reg-coalesce-test-union!
            (owned_view.compiler-owned-shared-view map)
            1
            2)
          (compiler-reg-coalesce-test-union!
            (owned_view.compiler-owned-shared-view map)
            2
            3))]
      [before : i64 (compiler-reg-coalesce-test-chain-digits (& map) 1)]
      (and
        joined
        (not
          (reg.compiler-reg-coalesce-map-try-merge!
            (owned_view.compiler-owned-shared-view map.parents)
            (owned_view.compiler-owned-shared-view map.sizes)
            (owned_view.compiler-owned-shared-view map.next)
            (owned_view.compiler-owned-shared-view map.tail)
            (owned_view.compiler-owned-shared-view map.starts)
            (owned_view.compiler-owned-shared-view map.ends)
            (& intervals)
            (& facts)
            3
            2
            false
            (&mut sv-parents)))
        (not
          (compiler-reg-coalesce-test-union!
            (owned_view.compiler-owned-shared-view map)
            3
            1))
        (= (compiler-reg-coalesce-test-chain-digits (& map) 1) before)
        (= (array-ref map.sizes 1) 3)
        (= (array-ref map.tail 1) 3)
        (compiler-reg-coalesce-test-chains-match-scan? (& map))))))

;; Generated maps: a fixed linear congruential sequence picks var pairs and
;; joins their classes; the chains must match the full scan after every join.
(cfg
  test
  (define (compiler-reg-coalesce-chains-generated-case-ok?
    [n : i64]
    [steps : i64]
    [seed : i64]) : bool
    (let
      [map : CompilerRegCoalesceTestMap (compiler-reg-coalesce-test-map n)]
      [state : i64 seed]
      [step : i64 0]
      [joins : i64 0]
      [ok : bool true]
      (while (and ok (< step steps))
        (let
          [left : i64 0]
          [right : i64 0]
          (set! state (bit-and (+ (* state 1103515245) 12345) 2147483647))
          (set! left (% (shr state 8) n))
          (set! state (bit-and (+ (* state 1103515245) 12345) 2147483647))
          (set! right (% (shr state 8) n))
          (when
            (compiler-reg-coalesce-test-union!
              (owned_view.compiler-owned-shared-view map)
              left
              right)
            (set! joins (+ joins 1))
            (set! ok (compiler-reg-coalesce-test-chains-match-scan? (& map))))
          (set! step (+ step 1))))
      (and ok (>= joins (/ n 2))))))

(cfg
  test
  (define (compiler-reg-coalesce-chains-generated-ok?) : bool
    (and
      (compiler-reg-coalesce-chains-generated-case-ok? 2 4 7)
      (compiler-reg-coalesce-chains-generated-case-ok? 17 40 1)
      (compiler-reg-coalesce-chains-generated-case-ok? 64 120 7874)
      (compiler-reg-coalesce-chains-generated-case-ok? 64 400 8022))))

(test
  regalloc-coalesce-class-chains
  (test.assert-true
    (and
      (compiler-reg-coalesce-chains-singletons-ok?)
      (compiler-reg-coalesce-chains-multi-member-ok?)
      (compiler-reg-coalesce-chains-merge-orders-ok?)
      (compiler-reg-coalesce-chains-self-merge-declined-ok?)
      (compiler-reg-coalesce-chains-generated-ok?))
    "coalescing class chains enumerate exactly the members a full scan of parents finds"))

(define (compiler-reg-plan-function-stack-only [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
  (reg.compiler-reg-plan-function-stack-only-with-representations-and-metrics
    func
    (ir.compiler-ir-representation-index-empty)
    (reg.compiler-reg-profile-metrics-new)))

(define (compiler-reg-stack-only-storage-branch-ok?) : bool
  (let
    [func : ir.CompilerIrFunction
      (compiler-reg-stack-only-storage-branch-function)]
    [plan : reg.CompilerRegPlan
      (compiler-reg-plan-function-stack-only (clone func))]
    [assignment-count : i64
      (reg.compiler-reg-assignment-count
        (reg.compiler-reg-plan-assignments
          (reg.compiler-reg-global-shared-view plan)))]
    [ineligible-count : i64
      (let
        [plan-ineligible
          (reg.compiler-reg-plan-ineligible
            (reg.compiler-reg-global-shared-view plan))]
        (live.compiler-live-set-count plan-ineligible))]
    [interval-count : i64
      (reg.compiler-reg-interval-seq-count
        (reg.compiler-reg-plan-intervals
          (reg.compiler-reg-global-shared-view plan)))]
    (match func
      [(Function _ params _ vars blocks _)
        (match (compiler-reg-color-stack-slots
          (ast.ast-node-pool-reader-type-segment-bases)
          plan
          (live.compiler-live-set-empty)
          params
          blocks
          vars
          vars
          (live.compiler-live-set-empty))
          [(Remap remap slots)
            (and
              (= assignment-count 0)
              (= ineligible-count 0)
              (= interval-count vars)
              (< slots vars)
              (= (array-ref remap 0) 0)
              (= (array-ref remap 1) (array-ref remap 5))
              (= (array-ref remap 2) (array-ref remap 6))
              (= (array-ref remap 3) (array-ref remap 7))
              (= (array-ref remap 4) (array-ref remap 8)))]
          [(None) false])])))

(define (compiler-reg-stack-only-storage-escape-ok?) : bool
  (let
    [func : ir.CompilerIrFunction
      (compiler-reg-stack-only-storage-escape-function)]
    [plan : reg.CompilerRegPlan
      (compiler-reg-plan-function-stack-only (clone func))]
    [assignment-count : i64
      (reg.compiler-reg-assignment-count
        (reg.compiler-reg-plan-assignments
          (reg.compiler-reg-global-shared-view plan)))]
    [interval-count : i64
      (reg.compiler-reg-interval-seq-count
        (reg.compiler-reg-plan-intervals
          (reg.compiler-reg-global-shared-view plan)))]
    (match func
      [(Function _ params _ vars blocks _)
        (match (compiler-reg-color-stack-slots
          (ast.ast-node-pool-reader-type-segment-bases)
          plan
          (live.compiler-live-set-empty)
          params
          blocks
          vars
          vars
          (live.compiler-live-set-empty))
          [(Remap remap _)
            (and
              (= assignment-count 0)
              (= interval-count vars)
              (not (= (array-ref remap 0) (array-ref remap 3)))
              (not (= (array-ref remap 1) (array-ref remap 4))))]
          [(None) false])])))

(define (compiler-reg-color-stack-group-ok?) : bool
  (let
    [group-var : i64 7]
    [coloring : reg.CompilerRegColoring
      (compiler-reg-color-stack-slots
        (ast.ast-node-pool-reader-type-segment-bases)
        (Plan
          (compiler-reg-color-register-assignments-to (- group-var 1))
          (live.compiler-live-set-empty)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval group-var 0 2)
            (reg.compiler-reg-interval-seq-empty))
          (reg.compiler-reg-var-types-insert
            (reg.compiler-reg-var-types-empty)
            group-var
            (Struct (ci.intern "RegGroup")))
          (reg.compiler-reg-call-split-empty))
        (live.compiler-live-set1 group-var)
        (ir.compiler-ir-param-seq-empty)
        (ir.compiler-ir-block-list-empty)
        (+ group-var 1)
        (+ group-var 1)
        (live.compiler-live-set-empty))]
    (match coloring
      [(Remap remap slots)
        (and
          (= slots 1)
          (= (array-ref remap group-var) 0)
          (<= (+ (array-ref remap group-var) 1) slots))]
      [(None) false])))

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
    [idle-before? : bool (compiler-reg-program-maps-suppressed-current?)]
    [_seed : unit (reg.compiler-reg-add-c-memory-call-name! name)]
    [installed? : bool (reg.compiler-reg-c-memory-call-name? name)]
    [_arm : unit (reg.compiler-reg-suppress-program-maps! true)]
    [armed? : bool (compiler-reg-program-maps-suppressed-current?)]
    [suppressed? : bool (reg.compiler-reg-c-memory-call-name? name)]
    [_clear : unit (reg.compiler-reg-suppress-program-maps! false)]
    [idle-after? : bool (compiler-reg-program-maps-suppressed-current?)]
    [restored? : bool (reg.compiler-reg-c-memory-call-name? name)]
    [_reset : unit (reg.compiler-reg-clear-c-memory-call-names!)]
    (and
      (not idle-before?)
      installed?
      armed?
      (not suppressed?)
      (not idle-after?)
      restored?)))

(define (compiler-reg-loop-nest-depth-at
  [depths : (& depths (__tl_dyn-array i64))]
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
  (irt.blocks
    "entry:
       jump header
     header:
       branch false, body, exit
     body:
       branch false, early, latch
     early:
       jump exit
     latch:
       jump header
     exit:
       return"))

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
  (irt.blocks
    "entry:
       branch false, hot, cold
     hot:
       jump join
     join:
       return
     cold:
       jump join"))

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
  (irt.blocks
    "entry:
       jump header
     header:
       branch false, body, exit
     body:
       branch false, cont, tail
     cont:
       jump header
     tail:
       jump header
     exit:
       return"))

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
  (irt.blocks
    "entry:
       jump outer
     outer:
       branch false, inner, exit
     inner:
       branch false, inner-latch, outer-latch
     inner-latch:
       jump inner
     outer-latch:
       jump outer
     exit:
       return"))

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
  (irt.blocks
    "entry:
       jump header
     header:
       branch false, body, exit
     body:
       %0 = mov 1 : i64
     tail:
       jump latch
     latch:
       jump header
     exit:
       return"))

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
  (irt.blocks
    "entry:
       return
     dead-header:
       jump dead-latch
     dead-latch:
       jump dead-header"))

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
;; every site -- is a question about membership, and an index range answers
;; it in terms of the emitted order.
;; entry / body / latch / header / exit, with the header laid out BELOW the
;; blocks it heads: what a rotation produces, and the shape an index range
;; cannot read. A range that records a back edge only when the source is at or
;; after the target never sees the real latch (block 2, jumping UP to block
;; 3); it reads block 1 as a header instead, over the range [1..3], and then
;; rejects the loop outright, because `entry` -- outside that range --
;; branches to block 3, strictly inside it. As a member set the same loop is
;; unremarkable: {header, body, latch}, entered only at the header, with
;; `entry` the header's one predecessor from outside it.
(define (compiler-reg-loop-nest-rotated-blocks) : ir.CompilerIrBlockList
  (irt.blocks
    "entry:
       jump header
     body:
       jump latch
     latch:
       jump header
     header:
       branch false, body, exit
     exit:
       return"))

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
      (=
        (reg.compiler-reg-loop-nest-header
          (reg.compiler-reg-global-shared-view nest)
          0)
        3)
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
  (irt.blocks
    "entry:
       branch false, header, second
     header:
       branch false, body, exit
     body:
       jump latch
     latch:
       jump header
     second:
       jump header
     exit:
       return"))

;; entry / header / body / latch / side / exit, where `side` jumps into the
;; loop BODY rather than its header. The natural-loop walk stops only at the
;; header, so it follows `side` back to `entry` and swallows both: an
;; irreducible entry is answered as a conservative SUPERSET, which is the safe
;; direction. The header is then left with no predecessor from outside its own
;; set at all, and the hoist has nowhere to inject -- refused, by the same one
;; count, without a second predicate.
(define (compiler-reg-loop-nest-side-entry-blocks) : ir.CompilerIrBlockList
  (irt.blocks
    "entry:
       branch false, header, side
     header:
       branch false, body, exit
     body:
       jump latch
     latch:
       jump header
     side:
       jump body
     exit:
       return"))

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
    [side-header : i64
      (reg.compiler-reg-loop-nest-header
        (reg.compiler-reg-global-shared-view side)
        0)]
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

;; Two shapes an index-range encoding overcharges, read as membership. `early`
;; is laid out inside the loop's span but reaches the exit and never the latch,
;; so it is not a member: the leaf scan skips it, and a call there does not
;; cost the loop its hoist. The sunk `cold` block's backward-in-layout jump
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
      (=
        (reg.compiler-reg-loop-nest-header
          (reg.compiler-reg-global-shared-view nest)
          0)
        1)
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
      (reg.compiler-reg-function-loop-depths
        (reg.compiler-reg-global-shared-view blocks))]
    [nest : reg.CompilerRegLoopNest (reg.compiler-reg-loop-nest-build blocks)]
    [count : i64 (array-length depths)]
    [mine : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    [ok : bool true]
    (while (< index (reg.compiler-reg-loop-nest-header-count nest))
      (let
        [header : i64
          (reg.compiler-reg-loop-nest-header
            (reg.compiler-reg-global-shared-view nest)
            index)]
        [generation : i64 (+ index 1)]
        [_total : i64
          (reg.compiler-reg-loop-nest-header-members! nest header generation)]
        [block : i64 0]
        (while (< block count)
          (if (reg.compiler-reg-loop-nest-member? nest block generation)
            (set! (array-ref mine block) (+ (array-ref mine block) 1))
            unit)
          (set! block (+ block 1)))
        (set! index (+ index 1))))
    (set! index 0)
    (while (< index count)
      (if (= (array-ref mine index) (array-ref depths index))
        unit
        (set! ok false))
      (set! index (+ index 1)))
    ok))

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
;; Some readers still have to speak in SPANS: the call region's loop rows and
;; its loop-scope eviction. What those want is not "the highest block with an
;; edge into h from at or below it" but "the block range h's loop actually
;; occupies" -- the same numbers only for a layout that keeps every loop
;; contiguous and header-first, and an answer at all for blocks that head no
;; loop whatever.
;;
;; The span is anchored on the loop's lowest MEMBER, so a ROTATED loop -- one
;; whose header is laid out below the body it dominates -- gets a span too;
;; only the assumption "the header is the span's first block" is gone.
(define (compiler-reg-loop-nest-span-lo
  [spans : (& spans (__tl_dyn-array i64))]
  [index : i64]) : i64
  (if (and (>= index 0) (< (+ (* 2 index) 1) (array-length spans)))
    (array-ref spans (* 2 index))
    (- 0 2)))

(define (compiler-reg-loop-nest-span-hi
  [spans : (& spans (__tl_dyn-array i64))]
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
      ;; block is given a span at all.
      (= (compiler-reg-loop-nest-span-hi sunk 0) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi sunk 1) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi sunk 2) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi sunk 3) (- 0 1))
      ;; A ROTATED loop is contiguous but does not START at its header: the
      ;; span is [body..header] and it is published under the header, block 3.
      ;; A hull anchored on the header could only answer -1 here, which would
      ;; cost every rotated loop its rescue. No other block heads anything --
      ;; in particular block 1, which a back-edge index range reads as a header
      ;; with no out-of-loop predecessor at all.
      (= (compiler-reg-loop-nest-span-lo rotated 3) 1)
      (= (compiler-reg-loop-nest-span-hi rotated 3) 3)
      (= (compiler-reg-loop-nest-span-hi rotated 0) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi rotated 1) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi rotated 2) (- 0 1))
      (= (compiler-reg-loop-nest-span-hi rotated 4) (- 0 1)))))

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
    (while (< index count)
      (if (= (array-ref first index) (array-ref second index))
        unit
        (set! ok false))
      (set! index (+ index 1)))
    ok))

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
  (irt.func
    "function @live_in_call() -> i64 vars 2 {
     entry:
       jump def
     use:
       %1 = call side_effect() : unit
       return %0
     def:
       %0 = mov 9 : i64
       jump use
     }"))

(define (compiler-reg-live-in-call-ok?) : bool
  (let
    [func : ir.CompilerIrFunction (compiler-reg-live-in-call-function)]
    [liveness : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function
        (reg.compiler-reg-global-shared-view func))]
    (match (reg.compiler-reg-live-interval-selection
      (reg.compiler-reg-global-shared-view func)
      liveness)
      [(Selection _ index)
        (and
          ;; The jump is point 0, so `use` opens at point 2 and the bridge
          ;; anchors var 0 at point 1 -- the odd slot no instruction occupies.
          (= (array-ref index.starts 0) 1)
          ;; And that is what makes the call spanned: hull start 1, exclusive,
          ;; still admits the call at point 2.
          (let
            [segments0
              (reg.compiler-reg-global-array-element-shared-view
                index.segments
                0)]
            [direct-call-points (compiler-reg-direct-call-points func)]
            (reg.compiler-reg-segments-span-clobber?
              segments0
              direct-call-points
              (array-ref index.starts 0)
              false)))])))

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
    (while (< index count)
      (if (= (array-ref first index) (array-ref second index))
        unit
        (set! ok false))
      (set! index (+ index 1)))
    ok))

(define (compiler-regalloc-core-self-test?) : bool
  (require-each!
    (compiler-reg-loop-nest-early-exit-ok?)
    (compiler-reg-loop-nest-sunk-cold-ok?)
    (compiler-reg-loop-nest-two-latch-ok?)
    (compiler-reg-loop-nest-nested-ok?)
    (compiler-reg-loop-nest-fallthrough-ok?)
    (compiler-reg-loop-nest-unreachable-ok?)
    (compiler-reg-loop-nest-deterministic-ok?)
    (compiler-reg-loop-nest-rotated-ok?)
    (compiler-reg-loop-nest-multi-entry-ok?)
    (compiler-reg-loop-nest-non-member-ok?)
    (compiler-reg-loop-nest-consumer-ok?)
    (compiler-reg-loop-nest-regeneration-ok?)
    (compiler-reg-loop-nest-spans-ok?)
    (compiler-reg-loop-nest-spans-deterministic-ok?)
    (compiler-reg-live-in-call-ok?)
    (compiler-reg-program-maps-suppression-ok?)
    (cfg test (compiler-reg-low-bit-index32-powers-ok? 0 1) true)
    (compiler-reg-reuse-ok?)
    (compiler-reg-f64-reuse-ok?)
    (compiler-reg-overlap-spill-ok?)
    (compiler-reg-f64-overlap-spill-ok?)
    (compiler-reg-call-live-ok?)
    (compiler-reg-f64-call-live-ok?)
    (compiler-reg-call-arg-ok?)
    (compiler-reg-f64-call-arg-ok?)
    (compiler-reg-ineligible-ok?)
    (compiler-reg-target-clobbers-ok?)
    (compiler-reg-xmm-clobbers-ok?)
    (compiler-reg-xmm-abi-call-constraints-ok?)
    (compiler-reg-xmm-shared-greedy-bank-ok?)
    (compiler-reg-xmm-vector-class-reset-ok?)
    (compiler-reg-coalesce-ok?)
    (compiler-reg-p22-nested-copy-ok?)
    (cfg test (compiler-reg-liveness-handle-ok?) true)
    (cfg test (compiler-reg-liveness-handle-phi-ok?) true)
    (cfg test (compiler-reg-xmm-physical-ownership-ok?) true)
    (cfg test (compiler-reg-dense-mask-on-vector-homes-ok?) true)
    (compiler-reg-vector-mask-homes-ok?)
    (compiler-reg-mask-pressure-spill-home-ok?)
    (compiler-reg-segmented-interference-ok?)
    (compiler-reg-hole-aware-register-reuse-ok?)
    (compiler-reg-tail-call-clobber-ok?))
  true)

(define (compiler-regalloc-scalar-self-test?) : bool
  (require-each!
    (cfg test (compiler-reg-early-exit-general-ok?) true)
    (cfg test (compiler-reg-early-exit-float-guard-refused-ok?) true)
    (cfg test (compiler-reg-cold-call-split-ok?) true)
    (cfg test (compiler-reg-call-hole-weights-ok?) true)
    (cfg test (compiler-reg-block-weights-ok?) true)
    (cfg test (compiler-reg-call-hole-select-ok?) true)
    (cfg test (compiler-reg-call-hole-rewrite-shape-ok?) true)
    (cfg test (compiler-reg-call-hole-cross-block-ok?) true)
    (cfg test (compiler-reg-call-hole-join-ok?) true)
    (cfg test (compiler-reg-call-hole-redef-ok?) true)
    (cfg test (compiler-reg-call-hole-flow-conservative-ok?) true)
    (cfg test (compiler-reg-call-hole-drop-ok?) true)
    (cfg test (compiler-reg-call-hole-round-ok?) true)
    (cfg test (compiler-reg-call-hole-declines-ok?) true)
    (cfg test (compiler-reg-call-hole-cold-arm-weight-ok?) true)
    (cfg test (compiler-reg-call-hole-loop-arm-weight-ok?) true)
    (cfg test (compiler-reg-call-hole-csr-qualify-ok?) true)
    (cfg test (compiler-reg-call-hole-csr-split-ok?) true)
    (cfg test (compiler-reg-call-hole-csr-cost-strict-ok?) true)
    (cfg test (compiler-reg-call-hole-recursive-arm-ok?) true)
    (cfg test (compiler-reg-loop-park-detect-ok?) true)
    (cfg test (compiler-reg-loop-park-eligible-ok?) true)
    (cfg test (compiler-reg-loop-park-sites-ok?) true)
    (cfg test (compiler-reg-loop-park-redirectable-ok?) true)
    (cfg test (compiler-reg-loop-park-direct-rewrite-ok?) true)
    (cfg test (compiler-reg-loop-park-splice-rewrite-ok?) true)
    (cfg test (compiler-reg-loop-park-verify-ok?) true)
    (cfg test (compiler-reg-loop-park-round-ok?) true)
    (cfg test (compiler-reg-loop-park-declines-ok?) true)
    (cfg test (compiler-reg-loop-park-deep-parks-ok?) true)
    (cfg test (compiler-reg-loop-park-deep-two-bases-homed-ok?) true)
    (cfg test (compiler-reg-loop-park-deep-declines-ok?) true)
    (cfg test (compiler-reg-loop-park-deep-ranking-ok?) true)
    (cfg test (compiler-reg-park-ladder-ok?) true)
    (cfg test (compiler-reg-scavenge-segment-hulls-ok?) true)
    (compiler-reg-scalar-call-live-ok?)
    (compiler-reg-scalar-f64-call-live-ok?)
    (compiler-reg-scalar-win64-f64-call-live-ok?)
    (compiler-reg-scalar-handle-eligible-ok?)
    (compiler-reg-scalar-handle-call-arg-ok?)
    (compiler-reg-scalar-indirect-call-arg-ok?)
    (compiler-reg-scalar-c-abi-store-result-call-arg-ok?)
    (compiler-reg-scalar-win64-indirect-call-arg-cap-ok?)
    (cfg test (compiler-reg-scalar-linux-param-registers-ok?) true)
    (cfg test (compiler-reg-scalar-windows-param-registers-ok?) true)
    (cfg test (compiler-reg-param-entry-forbidden-ok?) true)
    (cfg test (compiler-reg-param-entry-forbidden-refuses-windows-ok?) true)
    (cfg test (compiler-reg-param-entry-forbidden-refuses-float-ok?) true)
    (cfg test (compiler-reg-param-entry-forbidden-refuses-memory-ok?) true)
    (cfg test (compiler-reg-scalar-float-param-registers-ok?) true)
    (cfg test (compiler-reg-scalar-win64-float-param-registers-ok?) true)
    (cfg test (compiler-reg-scalar-mixed-float-call-args-ok?) true)
    (cfg test (compiler-reg-scalar-win64-mixed-float-call-args-ok?) true)
    (cfg test (compiler-reg-scalar-windows-rsi-rdi-pool-ok?) true)
    (cfg test (compiler-reg-win64-arg-result-prefs-ok?) true)
    (cfg test (compiler-reg-indirect-call-arg-prefs-ok?) true)
    (cfg test (compiler-reg-scalar-param-clobber-ok?) true)
    (cfg test (compiler-reg-scalar-param-const-shift-pin-ok?) true)
    (cfg test (compiler-reg-scalar-param-var-shift-pin-ok?) true)
    (cfg test (compiler-reg-scalar-param-dead-before-call-pin-ok?) true)
    (cfg test (compiler-reg-scalar-param-rdx-div-span-ok?) true)
    (cfg test (compiler-reg-scalar-param-rcx-shift-span-ok?) true)
    (cfg test (compiler-reg-scalar-param-pin-coalesce-demote-ok?) true)
    (cfg test (compiler-reg-scalar-aggregate-param-pinned-ok?) true)
    (compiler-reg-scalar-function-intervals-ok?)
    (compiler-reg-scalar-interval-guardrail-ok?)
    (compiler-reg-scalar-edge-precise-allocation-intervals-ok?)
    (compiler-reg-scalar-loop-backedge-ok?)
    (compiler-reg-scalar-zero-call-caller-saved-ok?)
    (cfg test (compiler-reg-scalar-zero-call-param-conflict-ok?) true)
    (compiler-reg-scalar-caller-saved-clobber-ok?)
    (compiler-reg-scalar-call-spanning-caller-saved-ok?)
    (cfg test (compiler-reg-scalar-call-spanning-multiblock-local-ok?) true)
    (cfg test (compiler-reg-scalar-call-spanning-multiblock-boundary-ok?) true)
    (cfg test (compiler-reg-loop-region-invariant-ok?) true)
    (cfg test (compiler-reg-loop-region-defined-in-loop-refused?) true)
    (cfg test (compiler-reg-loop-region-call-refused?) true)
    (cfg test (compiler-reg-loop-region-admit-ok?) true)
    (cfg test (compiler-reg-loop-region-score-ok?) true)
    (cfg test (compiler-reg-loop-region-overlap-ok?) true)
    (cfg test (compiler-reg-evict-parked-ok?) true)
    (cfg test (compiler-reg-evict-busy-victim-refused?) true)
    (cfg test (compiler-reg-evict-all-busy-refused?) true)
    (cfg test (compiler-reg-evict-dead-exit-ok?) true)
    (cfg test (compiler-reg-evict-price-refused?) true)
    (cfg test (compiler-reg-evict-double-lend-refused?) true)
    (cfg test (compiler-reg-evict-coalesced-victim-refused?) true)
    (cfg test (compiler-reg-evict-sole-occupant-ok?) true)
    (cfg test (compiler-reg-evict-class-mention-ok?) true)
    (cfg test (compiler-reg-evict-rewrite-shape-ok?) true))
  true)

(define (compiler-regalloc-storage-self-test?) : bool
  (require-each!
    (cfg test (compiler-reg-remat-classifier-ok?) true)
    (cfg test (compiler-reg-invariant-element-store-cells-clean-ok?) true)
    (cfg test (compiler-reg-invariant-field-store-refused-ok?) true)
    (cfg test (compiler-reg-invariant-call-refused-ok?) true)
    (cfg test (compiler-reg-remat-recompute-classifier-ok?) true)
    (cfg test (compiler-reg-remat-literal-assignment-ok?) true)
    (cfg test (compiler-reg-remat-frozen-global-ok?) true)
    (cfg test (compiler-reg-remat-discount-weights-ok?) true)
    (cfg test (compiler-reg-remat-spill-weight-eviction-ok?) true)
    (cfg test (compiler-reg-remat-parameters-poisoned-ok?) true)
    (cfg test (compiler-reg-remat-parameter-assignment-keeps-home-ok?) true)
    (cfg test (compiler-reg-spill-weight-eviction-ok?) true)
    (cfg test (compiler-reg-loop-spill-weight-eviction-ok?) true)
    (cfg test (compiler-reg-foldable-rebate-classification-ok?) true)
    (cfg test (compiler-reg-foldable-rebate-keeps-counter-ok?) true)
    (cfg test (compiler-reg-foldable-rebate-index-not-discounted-ok?) true)
    (cfg test (compiler-reg-foldable-rebate-idempotent-ok?) true)
    (cfg test (compiler-reg-call-span-counts-ok?) true)
    (cfg test (compiler-reg-group-pair-widening-ok?) true)
    (compiler-reg-early-scratch-model-ok?)
    (compiler-reg-greedy-live-union-invariant-ok?)
    (compiler-reg-scratch-borrow-masks-ok?)
    (compiler-reg-early-scratch-never-spills-ok?)
    (compiler-reg-early-scratch-exclusion-rehomes-ok?)
    (compiler-reg-dense-lookups-ok?)
    (compiler-reg-dense-assignment-snapshot-ok?)
    (compiler-reg-color-stack-group-ok?)
    (compiler-reg-color-spill-slot-sharing-ok?)
    (compiler-reg-color-fusion-pin-slots-ok?)
    (cfg test (compiler-reg-color-phi-web-slot-sharing-ok?) true)
    (cfg test (compiler-reg-color-web-merge-ok?) true)
    (cfg test (compiler-reg-color-carry-priority-ok?) true)
    (cfg test (compiler-reg-color-witness-chain-ok?) true)
    (compiler-reg-color-spill-param-pins-ok?)
    (compiler-reg-color-avx2-param-ranges-ok?)
    (compiler-reg-color-spill-hole-demand-ok?)
    (compiler-reg-color-spill-scratch-demand-ok?)
    (compiler-reg-color-vector-stack-slots-ok?)
    (compiler-reg-vector-stack-mask-words-ok?)
    (compiler-reg-color-storage-ranges-ok?)
    (compiler-reg-stack-only-storage-branch-ok?)
    (compiler-reg-stack-only-storage-escape-ok?)
    (compiler-reg-block-hulls-ok?)
    (cfg test (compiler-reg-trace-reason-vocabulary-ok?) true))
  true)

(cfg
  test
  (define (compiler-reg-trace-fixture-function) : ir.CompilerIrFunction
    (irt.func
      "function @trace_reason_vocabulary() -> i64 vars 9 {
       entry:
         %0 = add 1, 1 : i64
         %1 = add 2, 1 : i64
         %2 = add 3, 1 : i64
         %3 = add 4, 1 : i64
         %4 = add 5, 1 : i64
         %5 = add 6, 1 : i64
         %6 = call work() : i64
         %7 = add %0, %1 : i64
         %7 = add %2, %3 : i64
         %7 = add %4, %5 : i64
         %8 = add %7, %6 : i64
         return %8
       }")))

(cfg
  test
  (define (compiler-reg-trace-reason-vocabulary-ok?) : bool
    (let
      [_on : unit (reg.compiler-reg-debug-set-trace-homes! true)]
      [plan : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-for-abi
          Linux
          (compiler-reg-trace-fixture-function))]
      [homed : i64 (reg.compiler-reg-trace-reason-at 0)]
      [spilled : i64 (reg.compiler-reg-trace-reason-at 5)]
      [_off : unit (reg.compiler-reg-debug-set-trace-homes! false)]
      (and
        (string.eq (reg.compiler-reg-trace-reason-name homed) "csr-pool-free")
        (string.eq
          (reg.compiler-reg-trace-reason-name spilled)
          "spill-split-eligible")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-arg-abi-pref))
          "arg-abi-pref")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-copy-hint))
          "copy-hint")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-pool-free))
          "pool-free")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-evict-lower))
          "evict-lower")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-csr-evict-lower))
          "csr-evict-lower")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-spill-whole))
          "spill-whole")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-scratch-unassigned))
          "scratch-unassigned")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-param-abi-pin))
          "param-abi-pin")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-preassigned))
          "preassigned")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-coalesced-member))
          "coalesced-member")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-group-pair))
          "group-pair")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-memory-rule))
          "memory-rule")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-blocked))
          "blocked")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-forced-carrier))
          "forced-carrier")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-call-save-carrier))
          "call-save-carrier")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-remat))
          "remat")
        (string.eq
          (reg.compiler-reg-trace-reason-name
            (reg.compiler-reg-trace-reason-none))
          "none")))))

(cfg
  test
  (define (compiler-reg-heapsort-golden-input [index : i64]) : reg.CompilerRegInterval
    (cond
      [(= index 0) (reg.CompilerRegInterval 2 1 90)]
      [(= index 1) (reg.CompilerRegInterval 1 1 80)]
      [(= index 2) (reg.CompilerRegInterval 1 1 70)]
      [(= index 3) (reg.CompilerRegInterval 0 2 60)]
      [(= index 4) (reg.CompilerRegInterval 1 1 50)]
      [(= index 5) (reg.CompilerRegInterval 0 0 40)]
      [else (reg.CompilerRegInterval 1 1 30)])))

(cfg
  test
  (define (compiler-reg-heapsort-golden-output
    [candidate? : bool]
    [index : i64]) : reg.CompilerRegInterval
    (cond
      [(= index 0) (reg.CompilerRegInterval 0 0 40)]
      [(= index 1)
        (reg.CompilerRegInterval
          1
          1
          (if candidate?
            30
            70))]
      [(= index 2)
        (reg.CompilerRegInterval
          1
          1
          (if candidate?
            50
            80))]
      [(= index 3)
        (reg.CompilerRegInterval
          1
          1
          (if candidate?
            70
            50))]
      [(= index 4)
        (reg.CompilerRegInterval
          1
          1
          (if candidate?
            80
            30))]
      [(= index 5) (reg.CompilerRegInterval 2 1 90)]
      [else (reg.CompilerRegInterval 0 2 60)])))

(cfg
  test
  (define (compiler-reg-heapsort-interval-eq?
    [left : reg.CompilerRegInterval]
    [right : reg.CompilerRegInterval]) : bool
    (and
      (= left.var right.var)
      (= left.start right.start)
      (= left.end right.end))))

(cfg
  test
  (define (compiler-reg-heapsort-fill-golden!
    [items : (__tl_dyn-array reg.CompilerRegInterval)]
    [base : i64]) : unit
    (let
      [index : i64 0]
      (while (< index 7)
        (set!
          (array-ref items (+ base index))
          (compiler-reg-heapsort-golden-input index))
        (set! index (+ index 1))))))

(cfg
  test
  (define (compiler-reg-heapsort-matches-golden?
    [items : (__tl_dyn-array reg.CompilerRegInterval)]
    [base : i64]
    [candidate? : bool]) : bool
    (let
      [index : i64 0]
      (while (< index 7)
        (unless
          (compiler-reg-heapsort-interval-eq?
            (array-ref items (+ base index))
            (compiler-reg-heapsort-golden-output candidate? index))
          (return false))
        (set! index (+ index 1)))
      true)))

(cfg
  test
  (define (compiler-reg-heapsort-sentinel [index : i64]) : reg.CompilerRegInterval
    (reg.CompilerRegInterval (- 0 index) -700 (- 0 (+ index 900)))))

(cfg
  test
  (define (compiler-reg-heapsort-fill-sentinels!
    [items : (__tl_dyn-array reg.CompilerRegInterval)]) : unit
    (let
      [index : i64 0]
      (while (< index (array-length items))
        (set! (array-ref items index) (compiler-reg-heapsort-sentinel index))
        (set! index (+ index 1))))))

(cfg
  test
  (define (compiler-reg-heapsort-sentinels-ok?
    [items : (__tl_dyn-array reg.CompilerRegInterval)]
    [base : i64]
    [count : i64]) : bool
    (let
      [index : i64 0]
      (while (< index (array-length items))
        (when
          (or (< index base) (>= index (+ base count)))
          (unless
            (compiler-reg-heapsort-interval-eq?
              (array-ref items index)
              (compiler-reg-heapsort-sentinel index))
            (return false)))
        (set! index (+ index 1)))
      true)))

(cfg
  test
  (define (compiler-reg-heapsort-large-item [index : i64]) : reg.CompilerRegInterval
    (let
      [mixed : i64 (+ (* index 1103515245) 12345)]
      [start : i64 (bit-and mixed 255)]
      (reg.CompilerRegInterval
        index
        start
        (+ start (bit-and (shr mixed 13) 127))))))

(cfg
  test
  (define (compiler-reg-heapsort-fill-large!
    [items : (__tl_dyn-array reg.CompilerRegInterval)]
    [base : i64]
    [count : i64]) : unit
    (let
      [index : i64 0]
      (while (< index count)
        (set!
          (array-ref items (+ base index))
          (compiler-reg-heapsort-large-item index))
        (set! index (+ index 1))))))

(cfg
  test
  (define (compiler-reg-heapsort-order-permutation-ok?
    [items : (__tl_dyn-array reg.CompilerRegInterval)]
    [base : i64]
    [count : i64]
    [candidate? : bool]) : bool
    (let
      [seen : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      [index : i64 0]
      (while (< index count)
        (let
          [item : reg.CompilerRegInterval (array-ref items (+ base index))]
          [var : i64 item.var]
          (when (or (< var 0) (>= var count)) (return false))
          (when (= (array-ref seen var) 1) (return false))
          (unless
            (compiler-reg-heapsort-interval-eq?
              item
              (compiler-reg-heapsort-large-item var))
            (return false))
          (when
            (> index 0)
            (let
              [previous : reg.CompilerRegInterval
                (array-ref items (+ base (- index 1)))]
              (when
                (if candidate?
                  (reg.compiler-reg-interval-before? item previous)
                  (reg.compiler-reg-color-interval-before? item previous))
                (return false))))
          (set! (array-ref seen var) 1)
          (set! index (+ index 1))))
      true)))

(cfg
  test
  (define (compiler-reg-heapsort-exact-goldens-ok?) : bool
    (let
      [candidate : (__tl_dyn-array reg.CompilerRegInterval)
        (__tl_make-array reg.CompilerRegInterval 7)]
      [color : (__tl_dyn-array reg.CompilerRegInterval)
        (__tl_make-array reg.CompilerRegInterval 7)]
      [ordered : (__tl_dyn-array reg.CompilerRegInterval)
        (__tl_make-array reg.CompilerRegInterval 7)]
      [range : (__tl_dyn-array reg.CompilerRegInterval)
        (__tl_make-array reg.CompilerRegInterval 14)]
      (compiler-reg-heapsort-fill-golden!
        (reg.compiler-reg-global-shared-view candidate)
        0)
      (compiler-reg-heapsort-fill-golden!
        (reg.compiler-reg-global-shared-view color)
        0)
      (compiler-reg-heapsort-fill-sentinels!
        (reg.compiler-reg-global-shared-view range))
      (compiler-reg-heapsort-fill-golden!
        (reg.compiler-reg-global-shared-view range)
        3)
      (reg.compiler-reg-candidate-heapsort!
        (reg.compiler-reg-global-shared-view candidate)
        7)
      (reg.compiler-reg-color-heapsort-unordered!
        (reg.compiler-reg-global-shared-view color)
        7)
      (reg.compiler-reg-scratch-hull-heapsort-range!
        (reg.compiler-reg-global-shared-view range)
        3
        7)
      ;; The unordered heap would permute these four equivalent records, so
      ;; exact preservation proves the handwritten ordered scan returned.
      (let
        [index : i64 0]
        (while (< index 7)
          (set!
            (array-ref ordered index)
            (compiler-reg-heapsort-golden-output false index))
          (set! index (+ index 1))))
      (reg.compiler-reg-color-heapsort
        (reg.compiler-reg-global-shared-view ordered)
        7)
      (and
        (compiler-reg-heapsort-matches-golden? candidate 0 true)
        (compiler-reg-heapsort-matches-golden? color 0 false)
        (compiler-reg-heapsort-matches-golden? ordered 0 false)
        (compiler-reg-heapsort-sentinels-ok?
          (reg.compiler-reg-global-shared-view range)
          3
          7)
        (compiler-reg-heapsort-matches-golden? range 3 false)))))

(cfg
  test
  (define (compiler-reg-heapsort-range-case-ok? [count : i64]) : bool
    (let
      [base : i64 3]
      [items : (__tl_dyn-array reg.CompilerRegInterval)
        (__tl_make-array reg.CompilerRegInterval (+ base (+ count 4)))]
      (compiler-reg-heapsort-fill-sentinels!
        (reg.compiler-reg-global-shared-view items))
      (compiler-reg-heapsort-fill-large!
        (reg.compiler-reg-global-shared-view items)
        base
        count)
      (reg.compiler-reg-scratch-hull-heapsort-range!
        (reg.compiler-reg-global-shared-view items)
        base
        count)
      (and
        (compiler-reg-heapsort-sentinels-ok?
          (reg.compiler-reg-global-shared-view items)
          base
          count)
        (compiler-reg-heapsort-order-permutation-ok? items base count false)))))

(cfg
  test
  (define (compiler-reg-heapsort-large-ok?) : bool
    (let
      [count : i64 2049]
      [candidate : (__tl_dyn-array reg.CompilerRegInterval)
        (__tl_make-array reg.CompilerRegInterval count)]
      [color : (__tl_dyn-array reg.CompilerRegInterval)
        (__tl_make-array reg.CompilerRegInterval count)]
      (compiler-reg-heapsort-fill-large!
        (reg.compiler-reg-global-shared-view candidate)
        0
        count)
      (compiler-reg-heapsort-fill-large!
        (reg.compiler-reg-global-shared-view color)
        0
        count)
      (reg.compiler-reg-candidate-heapsort!
        (reg.compiler-reg-global-shared-view candidate)
        count)
      (reg.compiler-reg-color-heapsort-unordered!
        (reg.compiler-reg-global-shared-view color)
        count)
      (and
        (compiler-reg-heapsort-order-permutation-ok? candidate 0 count true)
        (compiler-reg-heapsort-order-permutation-ok? color 0 count false)))))

(cfg
  test
  (define (compiler-reg-heapsort-allocation-free-ok?) : bool
    (let
      [candidate : (__tl_dyn-array reg.CompilerRegInterval)
        (__tl_make-array reg.CompilerRegInterval 7)]
      [color : (__tl_dyn-array reg.CompilerRegInterval)
        (__tl_make-array reg.CompilerRegInterval 7)]
      [range : (__tl_dyn-array reg.CompilerRegInterval)
        (__tl_make-array reg.CompilerRegInterval 14)]
      [before : i64 0]
      [after : i64 0]
      (compiler-reg-heapsort-fill-golden!
        (reg.compiler-reg-global-shared-view candidate)
        0)
      (compiler-reg-heapsort-fill-golden!
        (reg.compiler-reg-global-shared-view color)
        0)
      (compiler-reg-heapsort-fill-sentinels!
        (reg.compiler-reg-global-shared-view range))
      (compiler-reg-heapsort-fill-golden!
        (reg.compiler-reg-global-shared-view range)
        3)
      (set! before (profile.alloc-total))
      (reg.compiler-reg-candidate-heapsort!
        (reg.compiler-reg-global-shared-view candidate)
        7)
      (reg.compiler-reg-color-heapsort-unordered!
        (reg.compiler-reg-global-shared-view color)
        7)
      (reg.compiler-reg-scratch-hull-heapsort-range!
        (reg.compiler-reg-global-shared-view range)
        3
        7)
      (set! after (profile.alloc-total))
      (and
        (= after before)
        (= (array-ref candidate 0).end 40)
        (= (array-ref color 1).end 70)
        (= (array-ref range 4).end 70)))))

(cfg
  test
  (test
    regalloc-generated-heapsort-exact-goldens
    (test.assert-true
      (compiler-reg-heapsort-exact-goldens-ok?)
      "generated interval heapsorts preserve exact legacy permutations")))

(cfg
  test
  (test
    regalloc-generated-heapsort-order-permutation
    (test.assert-true
      (and
        (compiler-reg-heapsort-large-ok?)
        (compiler-reg-heapsort-range-case-ok? 0)
        (compiler-reg-heapsort-range-case-ok? 1)
        (compiler-reg-heapsort-range-case-ok? 97))
      "generated heapsorts preserve order, permutation, and range sentinels")))

(cfg
  test
  (test
    regalloc-generated-heapsort-allocation-free
    (test.assert-true
      (compiler-reg-heapsort-allocation-free-ok?)
      "generated heapsort entries allocate no auxiliary arena storage")))

(cfg
  test
  (define (compiler-reg-dense-seq-expected-capacity [len : i64]) : i64
    (cond
      [(= len 0) 0]
      [(<= len 4) 4]
      [(<= len 8) 8]
      [(<= len 16) 16]
      [else 32])))

;; Every field of a generated element depends on its index and differs from
;; its sibling fields, so a copy that drops, swaps or reorders data fails.
(cfg
  test
  (define (compiler-reg-dense-seq-test-id [index : i64]) : i64
    (cond
      [(= index 0) (- 0 9223372036854775807)]
      [(= index 1) 0]
      [(= index 2) 9223372036854775807]
      [(= index 3) -1]
      [else (- (* index 1000003) 9)])))

(cfg
  test
  (define (compiler-reg-dense-seq-test-id-same? [left : i64] [right : i64]) : bool
    (= left right)))

(cfg
  test
  (define (compiler-reg-dense-seq-test-move [index : i64]) : reg.CompilerRegMove
    (reg.CompilerRegMove index (+ index 1000) (= (% index 3) 1))))

(cfg
  test
  (define (compiler-reg-dense-seq-test-move-same?
    [left : reg.CompilerRegMove]
    [right : reg.CompilerRegMove]) : bool
    (and
      (= left.src right.src)
      (= left.dst right.dst)
      (= left.strict right.strict))))

(cfg
  test
  (define (compiler-reg-dense-seq-test-evict [index : i64]) : reg.CompilerRegCallEvict
    (CompilerRegCallEvict index (+ index 1000) (- -1 index))))

(cfg
  test
  (define (compiler-reg-dense-seq-test-evict-same?
    [left : reg.CompilerRegCallEvict]
    [right : reg.CompilerRegCallEvict]) : bool
    (match left
      [(CompilerRegCallEvict a b c)
        (match right
          [(CompilerRegCallEvict x y z) (and (= a x) (= b y) (= c z))])])))

(cfg
  test
  (define (compiler-reg-dense-seq-test-region [index : i64]) : reg.CompilerRegCallRegion
    (CompilerRegCallRegion
      index
      (+ index 1000)
      (+ index 2000)
      (+ index 3000)
      (- -1 index))))

(cfg
  test
  (define (compiler-reg-dense-seq-test-region-same?
    [left : reg.CompilerRegCallRegion]
    [right : reg.CompilerRegCallRegion]) : bool
    (match left
      [(CompilerRegCallRegion a b c d e)
        (match right
          [(CompilerRegCallRegion v w x y z)
            (and (= a v) (= b w) (= c x) (= d y) (= e z))])])))

(cfg
  test
  (define (compiler-reg-dense-seq-test-stat [index : i64]) : reg.CompilerRegCallRegionStat
    (CompilerRegCallRegionStat
      index
      (+ index 1000)
      (+ index 2000)
      (+ index 3000)
      (+ index 4000)
      (+ index 5000)
      (+ index 6000)
      (- -1 index))))

(cfg
  test
  (define (compiler-reg-dense-seq-test-stat-same?
    [left : reg.CompilerRegCallRegionStat]
    [right : reg.CompilerRegCallRegionStat]) : bool
    (match left
      [(CompilerRegCallRegionStat a b c d e f g h)
        (match right
          [(CompilerRegCallRegionStat s t u v w x y z)
            (and
              (= a s)
              (= b t)
              (= c u)
              (= d v)
              (= e w)
              (= f x)
              (= g y)
              (= h z))])])))

;; Drives one generated family through lengths 0..17, which crosses the 0->4
;; first growth and the 4->8, 8->16 and 16->32 doublings, checking length,
;; backing capacity and the whole live prefix after every push. `push`
;; consumes its sequence, so a pre-push value survives only as an unchecked
;; shared view, and the contract for a view is not persistence: the view keeps
;; its own prefix, a second push onto it with spare capacity overwrites the
;; slot the first push wrote, and a push onto a full sequence copies into
;; fresh storage. A push with spare capacity allocates nothing.
(cfg
  test
  (defmacro (compiler-reg-dense-seq-contract-ok?
    [seq-type : type]
    [empty : Expr]
    [push : Expr]
    [item : Expr]
    [same? : Expr]) : bool
    `(let
      [seq : ,seq-type (,empty)]
      [ok : bool (and (= seq.len 0) (= (array-length seq.slots) 0))]
      [count : i64 0]
      [index : i64 0]
      (while (< count 17)
        (set! seq (,push seq (,item count)))
        (set! count (+ count 1))
        (set!
          ok
          (and
            ok
            (= seq.len count)
            (=
              (array-length seq.slots)
              (compiler-reg-dense-seq-expected-capacity count))))
        (set! index 0)
        (while (< index count)
          (set! ok (and ok (,same? (array-ref seq.slots index) (,item index))))
          (set! index (+ index 1))))
      (let
        [five : ,seq-type (,empty)]
        [full : ,seq-type (,empty)]
        [spare-item (,item 102)]
        (set! index 0)
        (while (< index 8)
          (if (< index 5)
            (set! five (,push five (,item index)))
            unit)
          (set! full (,push full (,item index)))
          (set! index (+ index 1)))
        (let
          [view : ,seq-type (reg.compiler-reg-global-shared-view five)]
          [full-view : ,seq-type (reg.compiler-reg-global-shared-view full)]
          [first : ,seq-type (,push five (,item 100))]
          [view-intact : bool
            (and
              (= view.len 5)
              (,same? (array-ref view.slots 0) (,item 0))
              (,same? (array-ref view.slots 4) (,item 4)))]
          [second : ,seq-type (,push view (,item 101))]
          [grown-a : ,seq-type (,push full (,item 200))]
          [grown-b : ,seq-type (,push full-view (,item 201))]
          [before : i64 (profile.alloc-total)]
          [extra : ,seq-type (,push second spare-item)]
          [after : i64 (profile.alloc-total)]
          (set! index 0)
          (while (< index 5)
            (set!
              ok
              (and ok (,same? (array-ref first.slots index) (,item index))))
            (set! index (+ index 1)))
          (and
            ok
            view-intact
            (= first.len 6)
            (= (array-length first.slots) 8)
            (,same? (array-ref first.slots 5) (,item 101))
            (= grown-a.len 9)
            (= (array-length grown-a.slots) 16)
            (,same? (array-ref grown-a.slots 7) (,item 7))
            (,same? (array-ref grown-a.slots 8) (,item 200))
            (= grown-b.len 9)
            (,same? (array-ref grown-b.slots 8) (,item 201))
            (= extra.len 7)
            (,same? (array-ref extra.slots 6) spare-item)
            (= after before)))))))

(cfg
  test
  (test
    regalloc-generated-dense-seq-contract
    (begin
      (test.assert-true
        (compiler-reg-dense-seq-contract-ok?
          reg.CompilerRegIdSeq
          reg.compiler-reg-id-seq-empty
          reg.compiler-reg-id-seq-push
          compiler-reg-dense-seq-test-id
          compiler-reg-dense-seq-test-id-same?)
        "id sequence")
      (test.assert-true
        (compiler-reg-dense-seq-contract-ok?
          reg.CompilerRegMoveSeq
          reg.compiler-reg-move-seq-empty
          reg.compiler-reg-move-seq-push
          compiler-reg-dense-seq-test-move
          compiler-reg-dense-seq-test-move-same?)
        "move sequence")
      (test.assert-true
        (compiler-reg-dense-seq-contract-ok?
          reg.CompilerRegCallEvictSeq
          reg.compiler-reg-call-evict-seq-empty
          reg.compiler-reg-call-evict-seq-push
          compiler-reg-dense-seq-test-evict
          compiler-reg-dense-seq-test-evict-same?)
        "call-evict sequence")
      (test.assert-true
        (compiler-reg-dense-seq-contract-ok?
          reg.CompilerRegCallRegionSeq
          reg.compiler-reg-call-region-seq-empty
          reg.compiler-reg-call-region-seq-push
          compiler-reg-dense-seq-test-region
          compiler-reg-dense-seq-test-region-same?)
        "call-region sequence")
      (test.assert-true
        (compiler-reg-dense-seq-contract-ok?
          reg.CompilerRegCallRegionStatSeq
          reg.compiler-reg-call-region-stat-seq-empty
          reg.compiler-reg-call-region-stat-seq-push
          compiler-reg-dense-seq-test-stat
          compiler-reg-dense-seq-test-stat-same?)
        "call-region-stat sequence"))))

(cfg
  test
  (test
    regalloc-root-conflict-absorbs-replay
    (let
      [roots : (__tl_dyn-array i64) (__tl_make-array i64 1)]
      [invalid : (__tl_dyn-array bool) (__tl_make-array bool 2)]
      (set! (array-ref roots 0) -1)
      (test.assert-true
        (reg.compiler-reg-color-set-root! (&mut roots) (&mut invalid) 0 0)
        "first root propagates")
      (test.assert-true
        (reg.compiler-reg-color-set-root! (&mut roots) (&mut invalid) 0 1)
        "conflicting root invalidates")
      (test.assert-i64-eq (array-ref roots 0) -2 "conflict sentinel")
      (test.assert-true (array-ref invalid 0) "first root invalidated")
      (test.assert-true (array-ref invalid 1) "second root invalidated")
      (test.assert-true
        (not (reg.compiler-reg-color-set-root! (&mut roots) (&mut invalid) 0 0))
        "replay cannot restore first root")
      (test.assert-true
        (not (reg.compiler-reg-color-set-root! (&mut roots) (&mut invalid) 0 1))
        "replay cannot restore second root")
      (test.assert-i64-eq (array-ref roots 0) -2 "conflict remains terminal"))))

(define (compiler-regalloc-self-test) : i64
  (compiler-regalloc-core-self-test?)
  (compiler-regalloc-scalar-self-test?)
  (compiler-regalloc-storage-self-test?)
  42)

(cfg
  test
  (test
    regalloc-self-test
    (test.assert-i64-eq
      (compiler-regalloc-self-test)
      42
      "regalloc self-test fixture result")))

(cfg
  test
  (define (compiler-reg-check-returned-plan-profile-owner
    [func : ir.CompilerIrFunction]) : unit
    (let
      [state : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [metrics : profile_state.CompilerProfileMetrics
        (profile_state.compiler-profile-state-metrics state)]
      [types : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types-with-metrics
          (owned_view.compiler-owned-shared-view func)
          (owned_view.compiler-owned-shared-view metrics))]
      [plan : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-forced-spill-with-types
          (ast.ast-node-pool-reader-type-segment-bases)
          Linux
          func
          (- 0 1)
          false
          types
          (reg.compiler-reg-assignment-table-make 0))]
      (test.assert-i64-eq
        (compiler-reg-liveness-census-baseline-count metrics)
        1
        "planning records baseline liveness in the caller's owner")
      (test.assert-i64-eq
        (compiler-reg-liveness-census-edge-precise-count metrics)
        1
        "planning records edge-precise liveness in the caller's owner")
      (match plan
        [(Plan _ _ _ returned-types _)
          (reg.compiler-reg-liveness-census-reset!
            (reg.compiler-reg-var-types-metrics returned-types))])
      (test.assert-i64-eq
        (compiler-reg-liveness-census-baseline-count metrics)
        0
        "reset through the returned plan reaches the original owner")
      (test.assert-i64-eq
        (compiler-reg-liveness-census-edge-precise-count metrics)
        0
        "returned plan does not carry a cloned metrics owner"))))

(cfg
  test
  (test
    compiler-reg-returned-plan-profile-owner
    (begin
      (compiler-reg-check-returned-plan-profile-owner
        (compiler-reg-liveness-handle-phi-fixture))
      ;; The same phi analysis crosses the scratch budget with an unused
      ;; frame suffix. Its returned metrics must still refer to the caller.
      (compiler-reg-check-returned-plan-profile-owner
        (match (compiler-reg-liveness-handle-phi-fixture)
          [(Function symbol params result _ blocks function-abi)
            (Function symbol params result 262144 blocks function-abi)])))))

(cfg
  test
  (test
    compiler-reg-retained-plan-survives-later-planning
    (let
      [first : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-for-abi
          Linux
          (compiler-reg-trace-fixture-function))]
      [saved : reg.CompilerRegAssignmentTable
        (clone
          (reg.compiler-reg-plan-assignments
            (owned_view.compiler-owned-shared-view first)))]
      [round : i64 0]
      (test.assert-true
        (let
          [plan-assignments
            (reg.compiler-reg-plan-assignments
              (owned_view.compiler-owned-shared-view first))]
          (reg.compiler-reg-assignment-table-prefix-eq?
            saved
            plan-assignments
            9
            0))
        "fixture has comparable register/spill homes")
      (while (< round 32)
        (let
          [_later : reg.CompilerRegPlan
            (reg.compiler-reg-plan-function-scalar-for-abi
              Windows
              (compiler-reg-trace-fixture-function))]
          (set! round (+ round 1))))
      (test.assert-true
        (let
          [plan-assignments (reg.compiler-reg-plan-assignments first)]
          (reg.compiler-reg-assignment-table-prefix-eq?
            saved
            plan-assignments
            9
            0))
        "retained plan keeps its homes after later analysis arenas retire"))))

;; Widen only the unused frame suffix: identical live vregs must keep their
;; homes when auxiliary liveness storage crosses its scratch-owner budget.
(cfg
  test
  (define (compiler-reg-analysis-owner-fixture [vars : i64]) : ir.CompilerIrFunction
    (match (compiler-reg-trace-fixture-function)
      [(Function symbol params result _ blocks function-abi)
        (Function symbol params result vars blocks function-abi)])))

(cfg
  test
  (define (compiler-reg-analysis-owner-homes-ok?
    [abi : cabi.CompilerRegTargetAbi]) : bool
    (let
      [_trace-on : unit (reg.compiler-reg-debug-set-trace-homes! true)]
      [small : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-for-abi
          abi
          (compiler-reg-analysis-owner-fixture 9))]
      [first-reason : i64 (reg.compiler-reg-trace-reason-at 0)]
      [sixth-reason : i64 (reg.compiler-reg-trace-reason-at 5)]
      [below : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-for-abi
          abi
          (compiler-reg-analysis-owner-fixture 87359))]
      [above : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-for-abi
          abi
          (compiler-reg-analysis-owner-fixture 87360))]
      ;; Force another scratch lifetime before reading the first escaped plan.
      [again : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar-for-abi
          abi
          (compiler-reg-analysis-owner-fixture 87360))]
      [_trace-off : unit (reg.compiler-reg-debug-set-trace-homes! false)]
      (and
        (= first-reason (reg.compiler-reg-trace-reason-at 0))
        (= sixth-reason (reg.compiler-reg-trace-reason-at 5))
        (let
          [plan-assignments
            (reg.compiler-reg-plan-assignments
              (owned_view.compiler-owned-shared-view small))]
          [plan-assignments-b (reg.compiler-reg-plan-assignments below)]
          (reg.compiler-reg-assignment-table-prefix-eq?
            plan-assignments
            plan-assignments-b
            9
            0))
        (let
          [plan-assignments (reg.compiler-reg-plan-assignments small)]
          [plan-assignments-b
            (reg.compiler-reg-plan-assignments
              (owned_view.compiler-owned-shared-view above))]
          (reg.compiler-reg-assignment-table-prefix-eq?
            plan-assignments
            plan-assignments-b
            9
            0))
        (let
          [plan-assignments (reg.compiler-reg-plan-assignments above)]
          [plan-assignments-b (reg.compiler-reg-plan-assignments again)]
          (reg.compiler-reg-assignment-table-prefix-eq?
            plan-assignments
            plan-assignments-b
            9
            0))))))

(cfg
  test
  (test
    compiler-reg-analysis-owner-boundary-homes
    (begin
      (match (compiler-reg-trace-fixture-function)
        [(Function _ _ _ _ blocks _)
          (test.assert-i64-eq
            (ir.compiler-ir-block-list-instruction-count
              (owned_view.compiler-owned-shared-view blocks))
            12
            "fixture keeps the exact ownership-budget boundary")
          (test.assert-true
            (not
              (reg.compiler-reg-analysis-needs-scratch?
                87359
                (owned_view.compiler-owned-shared-view blocks)))
            "lower boundary uses the existing owner")
          (test.assert-true
            (reg.compiler-reg-analysis-needs-scratch? 87360 blocks)
            "upper boundary uses an independent scratch owner")])
      (test.assert-true
        (compiler-reg-analysis-owner-homes-ok? Linux)
        "Linux homes survive both ownership paths and later planning")
      (test.assert-true
        (compiler-reg-analysis-owner-homes-ok? Windows)
        "Windows homes survive both ownership paths and later planning"))))

(define (compiler-reg-liveness-census-baseline-count
  [_metrics : (& _metrics profile_state.CompilerProfileMetrics)]) : i64
  (let
    [_metrics : profile_state.CompilerProfileMetrics
      (owned_view.compiler-owned-reference-shared-view _metrics)]
    (cfg
      test
      (profile_state.compiler-profile-metrics-value
        _metrics
        reg.compiler-reg-liveness-census-baseline-metric)
      0)))

(define (compiler-reg-liveness-census-edge-precise-count
  [_metrics : (& _metrics profile_state.CompilerProfileMetrics)]) : i64
  (let
    [_metrics : profile_state.CompilerProfileMetrics
      (owned_view.compiler-owned-reference-shared-view _metrics)]
    (cfg
      test
      (profile_state.compiler-profile-metrics-value
        _metrics
        reg.compiler-reg-liveness-census-edge-precise-metric)
      0)))

;; Conservative caller-saved extension for the scalar opt2 pass. These registers
;; are caller-saved on both SysV and Win64, are not callee-saved registers that
;; would need prologue/epilogue save/restore, and are used only for intervals
;; that do not span a modeled backend caller-clobber point. This legacy helper is
;; intentionally the three-register subset; the unified greedy pool owns
;; %r10/%r11/%r8 behind the same clobber filter.
(define (compiler-reg-zero-call-caller-saved-integer-registers) : reg.CompilerRegIdSeq
  (let
    [out : reg.CompilerRegIdSeq (reg.compiler-reg-id-seq-with-capacity 3)]
    (set! out (reg.compiler-reg-id-seq-push out cabi.compiler-reg-id-r9))
    (set! out (reg.compiler-reg-id-seq-push out cabi.compiler-reg-id-rcx))
    (set! out (reg.compiler-reg-id-seq-push out cabi.compiler-reg-id-rdx))
    out))

(define (compiler-reg-caller-saved-integer-registers-from-abi
  [target-abi : cabi.CompilerRegTargetAbi]
  [idx : i64]) : reg.CompilerRegIdSeq
  (let
    [count : i64 (cabi.compiler-abi-caller-saved-gp-register-count target-abi)]
    [index : i64 idx]
    [out : reg.CompilerRegIdSeq
      (reg.compiler-reg-id-seq-with-capacity
        (if (< idx count)
          (- count idx)
          0))]
    (while (< index count)
      (set!
        out
        (reg.compiler-reg-id-seq-push
          out
          (cabi.compiler-abi-caller-saved-gp-register-id target-abi index)))
      (set! index (+ index 1)))
    out))

(define (compiler-reg-sysv-caller-saved-integer-registers) : reg.CompilerRegIdSeq
  (compiler-reg-caller-saved-integer-registers-from-abi Linux 0))

(define (compiler-reg-sysv-callee-saved-integer-registers) : reg.CompilerRegIdSeq
  (reg.compiler-reg-callee-saved-integer-registers-from-abi Linux 0))

(define (compiler-reg-win64-caller-saved-integer-registers) : reg.CompilerRegIdSeq
  (compiler-reg-caller-saved-integer-registers-from-abi Windows 0))

(define (compiler-reg-caller-saved-xmm-registers-from-abi
  [target-abi : cabi.CompilerRegTargetAbi]
  [idx : i64]) : reg.CompilerRegIdSeq
  (let
    [count : i64 (cabi.compiler-abi-caller-saved-xmm-register-count target-abi)]
    [index : i64 idx]
    [out : reg.CompilerRegIdSeq
      (reg.compiler-reg-id-seq-with-capacity
        (if (< idx count)
          (- count idx)
          0))]
    (while (< index count)
      (set!
        out
        (reg.compiler-reg-id-seq-push
          out
          (cabi.compiler-abi-caller-saved-xmm-register-id target-abi index)))
      (set! index (+ index 1)))
    out))

(define (compiler-reg-callee-saved-xmm-registers-from-abi
  [target-abi : cabi.CompilerRegTargetAbi]
  [idx : i64]) : reg.CompilerRegIdSeq
  (let
    [count : i64 (cabi.compiler-abi-callee-saved-xmm-register-count target-abi)]
    [index : i64 idx]
    [out : reg.CompilerRegIdSeq
      (reg.compiler-reg-id-seq-with-capacity
        (if (< idx count)
          (- count idx)
          0))]
    (while (< index count)
      (set!
        out
        (reg.compiler-reg-id-seq-push
          out
          (cabi.compiler-abi-callee-saved-xmm-register-id target-abi index)))
      (set! index (+ index 1)))
    out))

(define (compiler-reg-sysv-caller-saved-xmm-registers) : reg.CompilerRegIdSeq
  (compiler-reg-caller-saved-xmm-registers-from-abi Linux 0))

(define (compiler-reg-sysv-callee-saved-xmm-registers) : reg.CompilerRegIdSeq
  (compiler-reg-callee-saved-xmm-registers-from-abi Linux 0))

(define (compiler-reg-win64-caller-saved-xmm-registers) : reg.CompilerRegIdSeq
  (compiler-reg-caller-saved-xmm-registers-from-abi Windows 0))

(define (compiler-reg-win64-callee-saved-xmm-registers) : reg.CompilerRegIdSeq
  (compiler-reg-callee-saved-xmm-registers-from-abi Windows 0))

(define (compiler-reg-move-parallel-resource [var : i64]) : i64
  (+ var 1))

(define (compiler-reg-move-parallel-id [src : i64] [dst : i64]) : i64
  (+ (* (+ src 1) 1000000) (+ dst 1)))

(define (compiler-reg-move-parallel-edge [move : reg.CompilerRegMove]) : pmove.CompilerParallelMoveEdge
  (ParallelMoveEdge
    (compiler-reg-move-parallel-id move.src move.dst)
    (compiler-reg-move-parallel-resource move.dst)
    0
    (compiler-reg-move-parallel-resource move.src)
    0))

(define (compiler-reg-move-list-parallel-edges [moves : reg.CompilerRegMoveSeq]) : pmove.CompilerParallelMoveEdgeSeq
  (let
    [slots : (__tl_dyn-array reg.CompilerRegMove) moves.slots]
    [count : i64 moves.len]
    [index : i64 (- count 1)]
    [edges : pmove.CompilerParallelMoveEdgeSeq
      (pmove.compiler-parallel-move-edge-seq-with-capacity count)]
    ;; The former loop consed each ascending move onto the head. Walk the
    ;; dense source backward so decision order remains newest-first.
    (while (>= index 0)
      (pmove.compiler-parallel-move-edge-push!
        (&mut edges)
        (compiler-reg-move-parallel-edge (array-ref slots index)))
      (set! index (- index 1)))
    edges))

(define (compiler-reg-move-list-parallel-decision
  [moves : reg.CompilerRegMoveSeq]) : pmove.CompilerParallelMoveDecision
  (let
    [edges : pmove.CompilerParallelMoveEdgeSeq
      (compiler-reg-move-list-parallel-edges moves)]
    (pmove.compiler-parallel-move-decision edges edges)))

(define (compiler-reg-move-list-parallel-decision-ok?) : bool
  (let
    [chain : reg.CompilerRegMoveSeq
      (reg.compiler-reg-move-seq-push
        (reg.compiler-reg-move-seq-push
          (reg.compiler-reg-move-seq-empty)
          (reg.CompilerRegMove 1 2 false))
        (reg.CompilerRegMove 0 1 false))]
    [cycle : reg.CompilerRegMoveSeq
      (reg.compiler-reg-move-seq-push
        (reg.compiler-reg-move-seq-push
          (reg.compiler-reg-move-seq-empty)
          (reg.CompilerRegMove 1 0 false))
        (reg.CompilerRegMove 0 1 false))]
    (and
      (match (compiler-reg-move-list-parallel-decision chain)
        [(CompilerParallelMoveUnblocked id)
          (= id (compiler-reg-move-parallel-id 1 2))]
        [_ false])
      (match (compiler-reg-move-list-parallel-decision cycle)
        [(CompilerParallelMoveCycle id)
          (= id (compiler-reg-move-parallel-id 0 1))]
        [_ false]))))

(define (compiler-reg-function-moves-with-destructive-and-casts
  [func : ir.CompilerIrFunction]
  [strict-pairs : bool]) : reg.CompilerRegMoveSeq
  (match (reg.compiler-reg-global-shared-view func)
    [(Function _ _ _ vars _ _)
      (let
        [eligible : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
        (reg.compiler-reg-fill-i64-array (&mut eligible) 1)
        (reg.compiler-reg-function-moves-with-destructive-and-casts-eligible
          (reg.compiler-reg-global-shared-view func)
          strict-pairs
          eligible
          (reg.compiler-reg-function-alu-prefer-rhs func)))]))

(define (compiler-reg-function-phi-touched-safe
  [func : ir.CompilerIrFunction]
  [liveness : live.CompilerFunctionLiveness]) : (__tl_dyn-array i64)
  (reg.compiler-reg-function-phi-touched-safe-mode func liveness true))

(define (compiler-reg-call-live-instr-seq
  [instrs : ir.CompilerIrInstrSeq]
  [liveness : live.CompilerFunctionLiveness]
  [label : i64]
  [start-index : i64]
  [set : live.CompilerLiveI64Set]) : live.CompilerLiveI64Set
  (let
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [index : i64 0]
    [instr-index : i64 start-index]
    [out : live.CompilerLiveI64Set set]
    (while (< index count)
      (set!
        out
        (match (array-ref slots index)
          [(Call _ _ _ _)
            (live.compiler-live-set-union
              out
              (live.compiler-live-after
                (reg.compiler-reg-global-shared-view liveness)
                label
                instr-index))]
          [(CallCAbiStoreResult payload-box)
            (live.compiler-live-set-union
              out
              (live.compiler-live-after
                (reg.compiler-reg-global-shared-view liveness)
                label
                instr-index))]
          [(CallIndirectCAbiStoreResult payload-box)
            (live.compiler-live-set-union
              out
              (live.compiler-live-after
                (reg.compiler-reg-global-shared-view liveness)
                label
                instr-index))]
          [(SpmdCall payload-box)
            (live.compiler-live-set-union
              out
              (live.compiler-live-after
                (reg.compiler-reg-global-shared-view liveness)
                label
                instr-index))]
          [(TailCall _ _ _)
            (live.compiler-live-set-union
              out
              (live.compiler-live-after
                (reg.compiler-reg-global-shared-view liveness)
                label
                instr-index))]
          [(TailCallIndirect _ _ _)
            (live.compiler-live-set-union
              out
              (live.compiler-live-after
                (reg.compiler-reg-global-shared-view liveness)
                label
                instr-index))]
          [_ out]))
      (set! instr-index (+ instr-index 1))
      (set! index (+ index 1)))
    out))

(define (compiler-reg-call-live-blocks
  [blocks : ir.CompilerIrBlockList]
  [liveness : live.CompilerFunctionLiveness]
  [set : live.CompilerLiveI64Set]) : live.CompilerLiveI64Set
  (match blocks
    [(Array seq)
      (let
        [i : i64 0]
        [count : i64 (ir.compiler-ir-block-seq-count seq)]
        [out : live.CompilerLiveI64Set set]
        (while (< i count)
          (match (ir.compiler-ir-block-seq-ref seq i)
            [(Block label instrs)
              (set!
                out
                (compiler-reg-call-live-instr-seq
                  instrs
                  (reg.compiler-reg-global-shared-view liveness)
                  label
                  0
                  out))])
          (set! i (+ i 1)))
        out)]))

;; First register not in conflict with `var` over its live segments
;; (CompilerRegMaybeId.No if every register is occupied by an interfering value).
(define (compiler-reg-first-free-register-holes
  [regs : reg.CompilerRegIdSeq]
  [active : reg.CompilerRegActiveSeq]
  [index : reg.CompilerRegIntervalIndex]
  [var : i64]
  [hole-aware-vars : live.CompilerLiveI64Set]) : reg.CompilerRegMaybeId
  (let
    [at : i64 0]
    [result : reg.CompilerRegMaybeId (No)]
    [done : bool false]
    (while (and (< at (reg.compiler-reg-id-seq-count regs)) (not done))
      (let
        [reg-id : i64 (reg.compiler-reg-id-seq-ref regs at)]
        (if (reg.compiler-reg-active-register-conflicts?
          active
          reg-id
          index
          var
          hole-aware-vars)
          (set! at (+ at 1))
          (begin
            (set! result (Some reg-id))
            (set! done true)))))
    result))

(define (compiler-reg-assignment-table-register-free-at-point?
  [starts : (__tl_dyn-array i64)]
  [ends : (__tl_dyn-array i64)]
  [assignment-index : reg.CompilerRegAssignmentTable]
  [vars : i64]
  [point : i64]
  [reg-id : i64]) : bool
  (let
    [v : i64 0]
    [free : bool true]
    (while (and (< v vars) free)
      (if (and
        (reg.compiler-reg-var-live-at-point? starts ends v point)
        (reg.compiler-reg-assignment-table-var-uses-register?
          assignment-index
          v
          reg-id))
        (set! free false)
        unit)
      (set! v (+ v 1)))
    free))

(define (compiler-reg-assignment-table-register-free-over-range?
  [starts : (& starts (__tl_dyn-array i64))]
  [ends : (& ends (__tl_dyn-array i64))]
  [assignment-index : reg.CompilerRegAssignmentTable]
  [vars : i64]
  [lo : i64]
  [hi : i64]
  [reg-id : i64]) : bool
  (let
    [v : i64 0]
    [free : bool true]
    (while (and (< v vars) free)
      (if (and
        (reg.compiler-reg-var-live-over-range? starts ends v lo hi)
        (reg.compiler-reg-assignment-table-var-uses-register?
          assignment-index
          v
          reg-id))
        (set! free false)
        unit)
      (set! v (+ v 1)))
    free))

(define (compiler-reg-interval-lookup
  [intervals : reg.CompilerRegIntervalSeq]
  [var : i64]) : reg.CompilerRegMaybeInterval
  (let
    [index : i64 0]
    [result : reg.CompilerRegMaybeInterval No]
    [done : bool false]
    (while (and
      (< index (reg.compiler-reg-interval-seq-count intervals))
      (not done))
      (let
        [interval : reg.CompilerRegInterval
          (reg.compiler-reg-interval-seq-ref intervals index)]
        [id : i64 interval.var]
        (cond
          [(= id var)
            (set! result (Some interval))
            (set! done true)]
          [(> id var) (set! done true)]
          [else (set! index (+ index 1))])))
    result))

(define (compiler-reg-interval-range?
  [intervals : reg.CompilerRegIntervalSeq]
  [var : i64]
  [start : i64]
  [end : i64]) : bool
  (match (compiler-reg-interval-lookup intervals var)
    [(Some interval) (and (= interval.start start) (= interval.end end))]
    [(No) false]))

(define (compiler-reg-location-conflicts?
  [assignments : reg.CompilerRegAssignmentTable]
  [intervals : (& intervals reg.CompilerRegIntervalIndex)]
  [var : i64]
  [ignore-var : i64]
  [location : reg.CompilerRegLocation]) : bool
  (reg.compiler-reg-assignment-table-location-conflicts?
    assignments
    intervals
    var
    ignore-var
    location))

(define (compiler-reg-assignment-table-location-conflicts-segmented-from?
  [assignments : reg.CompilerRegAssignmentTable]
  [intervals : (& intervals reg.CompilerRegIntervalIndex)]
  [var : i64]
  [ignore-var : i64]
  [location : reg.CompilerRegLocation]
  [index : i64]) : bool
  (let
    [present : (__tl_dyn-array i64)
      (reg.compiler-reg-assignment-table-present assignments)]
    [items : (__tl_dyn-array reg.CompilerRegLocation)
      (reg.compiler-reg-assignment-table-items assignments)]
    (cond
      [(>= index (array-length present)) false]
      [(= (reg.compiler-reg-global-array-element-shared-view present index) 0)
        (compiler-reg-assignment-table-location-conflicts-segmented-from?
          assignments
          intervals
          var
          ignore-var
          location
          (+ index 1))]
      [(or (= index var) (= index ignore-var))
        (compiler-reg-assignment-table-location-conflicts-segmented-from?
          assignments
          intervals
          var
          ignore-var
          location
          (+ index 1))]
      [(and
          (reg.compiler-reg-location-overlaps?
            (reg.compiler-reg-global-array-element-shared-view items index)
            (reg.compiler-reg-global-shared-view location))
          (reg.compiler-reg-vars-interfere-segmented-index? intervals var index))
        true]
      [else
        (compiler-reg-assignment-table-location-conflicts-segmented-from?
          assignments
          intervals
          var
          ignore-var
          location
          (+ index 1))])))

(define (compiler-reg-assignment-table-location-conflicts-segmented?
  [assignments : reg.CompilerRegAssignmentTable]
  [intervals : (& intervals reg.CompilerRegIntervalIndex)]
  [var : i64]
  [ignore-var : i64]
  [location : reg.CompilerRegLocation]) : bool
  (compiler-reg-assignment-table-location-conflicts-segmented-from?
    assignments
    intervals
    var
    ignore-var
    location
    0))

(define (compiler-reg-function-same-value-parents
  [func : ir.CompilerIrFunction]) : (__tl_dyn-array i64)
  (reg.compiler-reg-function-same-value-parents-filtered
    func
    (__tl_make-array i64 0)))

(define (compiler-reg-coalesce-location-from-class-from
  [coalesce : (& coalesce reg.CompilerRegCoalesceMap)]
  [assignments : reg.CompilerRegAssignmentTable]
  [intervals : reg.CompilerRegIntervalIndex]
  [var : i64]
  [root : i64]
  [index : i64]) : reg.CompilerRegMaybeLocation
  (let
    [parents : (__tl_dyn-array i64) coalesce.parents]
    (cond
      [(>= index (array-length parents)) No]
      [(or (= index var) (not (= (array-ref parents index) root)))
        (compiler-reg-coalesce-location-from-class-from
          coalesce
          assignments
          intervals
          var
          root
          (+ index 1))]
      [else
        (match (reg.compiler-reg-assignment-table-lookup assignments index)
          [(Some location)
            (if (compiler-reg-assignment-table-location-conflicts-segmented?
              assignments
              intervals
              var
              index
              (reg.compiler-reg-global-shared-view location))
              (compiler-reg-coalesce-location-from-class-from
                coalesce
                assignments
                intervals
                var
                root
                (+ index 1))
              (Some location))]
          [(No)
            (compiler-reg-coalesce-location-from-class-from
              coalesce
              assignments
              intervals
              var
              root
              (+ index 1))])])))

(define (compiler-reg-coalesce-location
  [coalesce : reg.CompilerRegCoalesceMap]
  [assignments : reg.CompilerRegAssignmentTable]
  [intervals : reg.CompilerRegIntervalIndex]
  [var : i64]) : reg.CompilerRegMaybeLocation
  (let
    [parents : (__tl_dyn-array i64) coalesce.parents]
    [root : i64 (reg.compiler-reg-coalesce-map-root-from-parents parents var)]
    (if (< root 0)
      No
      (compiler-reg-coalesce-location-from-class-from
        coalesce
        assignments
        intervals
        var
        root
        0))))

(define (compiler-reg-spill-count
  [assignments : reg.CompilerRegAssignmentTable]) : i64
  (let
    [present : (__tl_dyn-array i64)
      (reg.compiler-reg-assignment-table-present assignments)]
    [items : (__tl_dyn-array reg.CompilerRegLocation)
      (reg.compiler-reg-assignment-table-items assignments)]
    [index : i64 0]
    [count : i64 0]
    (while (< index (array-length present))
      (if (= (array-ref present index) 0)
        unit
        (match (array-ref items index)
          [(Spill _) (set! count (+ count 1))]
          [_ unit]))
      (set! index (+ index 1)))
    count))

;; Every instruction except allocation, bounds checks, CPU queries, calls,
;; jumps and phis.
(define (compiler-reg-backend-win64-extra-clobber-instr?
  [instr : ir.CompilerIrInstr]) : bool
  (match instr
    [(Alloc _ _) false]
    [(BoundsCheck _ _ _) false]
    [(CpuId _ _ _ _) false]
    [(Xgetbv _ _) false]
    [(Syscall _ _) false]
    [(Call _ _ _ _) false]
    [(CallIndirect _ _ _ _) false]
    [(CallIndirectC _ _ _ _) false]
    [(CallCAbiStoreResult _) false]
    [(CallIndirectCAbiStoreResult _) false]
    [(SpmdCall _) false]
    [(TailCall _ _ _) false]
    [(TailCallIndirect _ _ _) false]
    [(Jump _) false]
    [(Phi _ _ _) false]
    [_ true]))

(define (compiler-reg-backend-caller-clobber-instr-for-abi?
  [target-abi : cabi.CompilerRegTargetAbi]
  [instr : ir.CompilerIrInstr]) : bool
  (match target-abi
    [(Linux) (reg.compiler-reg-backend-caller-clobber-instr? instr)]
    [(Windows)
      (or
        (reg.compiler-reg-backend-caller-clobber-instr?
          (reg.compiler-reg-global-shared-view instr))
        (compiler-reg-backend-win64-extra-clobber-instr? instr))]))

;; Sample `k` of the call-family agreement test below: 0-8 are the call family
;; (6 and 7 the tail calls), 9 a bounds check, 10 a move and 11 a division.
(define (compiler-reg-call-family-sample [k : i64]) : ir.CompilerIrInstr
  (let
    [args : ir.CompilerIrCallArgs (One (Var 0))]
    [callee : ir.CompilerIrValue (Var 0)]
    [slots : ir.CompilerIrCAbiReturnSlotSeq
      (ir.CompilerIrCAbiReturnSlotSeq
        (__tl_make-array ir.CompilerIrCAbiReturnSlot 0)
        0)]
    [symbol : i64 (ir.compiler-ir-test-symbol "callee")]
    (cond
      [(= k 0) (Call 1 symbol args (I64))]
      [(= k 1) (CallIndirect 1 callee args (I64))]
      [(= k 2) (CallIndirectC 1 callee args (I64))]
      [(= k 3) (ir.ir-instr-call-cabi-store-result callee symbol args slots)]
      [(= k 4)
        (ir.ir-instr-call-indirect-cabi-store-result (Var 1) callee args slots)]
      [(= k 5)
        (ir.ir-instr-spmd-call-with-origin
          symbol
          (Scalar)
          1
          (Bool true)
          (ir.compiler-ir-spmd-call-arg-seq-empty)
          (Unit)
          (Imported
            (box
              (ir.CompilerIrImportedSpmdCall
                "owner"
                "0.1.0"
                "helper"
                "signature"
                "abi"
                "scalar"
                1
                ""
                ""
                0
                "helper"))))]
      [(= k 6) (TailCall symbol args (I64))]
      [(= k 7) (TailCallIndirect callee args (I64))]
      [(= k 8) (Syscall 1 args)]
      [(= k 9) (BoundsCheck (Var 0) (I64 4) 0)]
      [(= k 10) (Mov 1 (Var 0) (I64))]
      [else (BinOp 1 (Mod) (Var 0) (I64 3) (I64))])))

;; Every call-like instruction, a scalar SPMD helper call included, is a
;; caller-saved clobber, makes its block not call-free for the constant
;; hoister, and counts as a returning call unless it is a tail call. No other
;; instruction is in the call family (#8198).
(define (compiler-reg-call-family-predicates-agree?) : bool
  (let
    [k : i64 0]
    [ok : bool true]
    (while (and ok (< k 12))
      (let
        [call? : bool (< k 9)]
        [returning? : bool (and (< k 9) (not (= k 6)) (not (= k 7)))]
        [clobber? : bool (or (< k 9) (= k 9) (= k 11))]
        [seq : ir.CompilerIrInstrSeq
          (compiler-reg-test-instr-seq-prepend
            (compiler-reg-call-family-sample k)
            (ir.compiler-ir-instr-seq-empty))]
        (set!
          ok
          (and
            (=
              (reg.compiler-reg-call-instr? (compiler-reg-call-family-sample k))
              call?)
            (=
              (reg.compiler-reg-backend-caller-clobber-instr?
                (compiler-reg-call-family-sample k))
              clobber?)
            (=
              (reg.compiler-reg-loop-split-seq-has-call-or-syscall? (& seq))
              call?)
            (=
              (reg.compiler-reg-seq-has-returning-call-or-syscall? seq)
              returning?)))
        (set! k (+ k 1))))
    ok))

(cfg
  test
  (test
    regalloc-call-family-predicates-agree
    (test.assert-true
      (compiler-reg-call-family-predicates-agree?)
      "call-freedom, caller-clobber and returning-call queries share one call family")))

(cfg
  test
  (define (compiler-reg-call-word-count-in-range
    [bits : i64]
    [var-base : i64]
    [start : i64]
    [end : i64]) : i64
    (if (= bits 0)
      0
      (let
        [i : i64 (reg.compiler-reg-low-bit-index32 bits)]
        [c : i64 (+ var-base i)]
        [rest : i64
          (compiler-reg-call-word-count-in-range
            (bit-and bits (- bits 1))
            var-base
            start
            end)]
        (if (if (< start c)
          (< c end)
          false)
          (+ 1 rest)
          rest)))))

(define (compiler-reg-direct-call-points-seq
  [instrs : ir.CompilerIrInstrSeq]
  [point : i64]
  [set : live.CompilerLiveI64Set]) : reg.CompilerRegCallScan
  (let
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [index : i64 0]
    [p : i64 point]
    [out : live.CompilerLiveI64Set set]
    (while (< index count)
      (set!
        out
        (match (array-ref slots index)
          [(Call _ _ _ _) (live.compiler-live-set-insert out p)]
          [(SpmdCall payload-box) (live.compiler-live-set-insert out p)]
          [_ out]))
      (set! p (+ p 2))
      (set! index (+ index 1)))
    (Scan p out)))

(define (compiler-reg-direct-call-points-blocks
  [blocks : ir.CompilerIrBlockList]
  [point : i64]
  [set : live.CompilerLiveI64Set]) : reg.CompilerRegCallScan
  (match blocks
    [(Array seq)
      (let
        [i : i64 0]
        [count : i64 (ir.compiler-ir-block-seq-count seq)]
        [out-point : i64 point]
        [out-set : live.CompilerLiveI64Set set]
        (while (< i count)
          (match (ir.compiler-ir-block-seq-ref seq i)
            [(Block _ instrs)
              (match (compiler-reg-direct-call-points-seq
                instrs
                out-point
                (reg.compiler-reg-global-shared-view out-set))
                [(Scan p2 s2)
                  (set! out-point p2)
                  (set! out-set s2)])])
          (set! i (+ i 1)))
        (Scan out-point out-set))]))

(define (compiler-reg-direct-call-points [func : ir.CompilerIrFunction]) : live.CompilerLiveI64Set
  (match func
    [(Function _ _ _ _ blocks _)
      (match (compiler-reg-direct-call-points-blocks
        blocks
        0
        (live.compiler-live-set-empty))
        [(Scan _ set) set])]))

(define (compiler-reg-ref-counts-add-instr!
  [counts : (&mut counts (__tl_dyn-array i64))]
  [instr : ir.CompilerIrInstr]) : unit
  (reg.compiler-reg-ref-counts-add-instr-weighted! counts instr 1))

(define (compiler-reg-ref-counts-seq!
  [counts : (&mut counts (__tl_dyn-array i64))]
  [instrs : ir.CompilerIrInstrSeq]) : unit
  (let
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [index : i64 0]
    (while (< index count)
      (compiler-reg-ref-counts-add-instr!
        counts
        (reg.compiler-reg-global-array-element-shared-view slots index))
      (set! index (+ index 1)))))

(define (compiler-reg-ref-counts-blocks!
  [counts : (__tl_dyn-array i64)]
  [blocks : ir.CompilerIrBlockList]) : unit
  (match blocks
    [(Array seq)
      (let
        [i : i64 0]
        [count : i64 (ir.compiler-ir-block-seq-count seq)]
        (while (< i count)
          (match (ir.compiler-ir-block-seq-ref seq i)
            [(Block _ instrs)
              (compiler-reg-ref-counts-seq! (&mut counts) instrs)])
          (set! i (+ i 1))))]))

(define (compiler-reg-foldable-rebate-seq!
  [rebates : (&mut rebates (__tl_dyn-array i64))]
  [instrs : ir.CompilerIrInstrSeq]
  [weight : i64]) : unit
  (let
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [index : i64 0]
    (while (< index count)
      (reg.compiler-reg-foldable-rebate-add-instr!
        rebates
        (reg.compiler-reg-global-array-element-shared-view slots index)
        weight)
      (set! index (+ index 1)))))

(define (compiler-reg-foldable-rebate-blocks!
  [rebates : (&mut rebates (__tl_dyn-array i64))]
  [blocks : ir.CompilerIrBlockList]
  [weights : (__tl_dyn-array i64)]
  [block-index : i64]) : unit
  (match blocks
    [(Array seq)
      (let
        [i : i64 0]
        [count : i64 (ir.compiler-ir-block-seq-count seq)]
        [index : i64 block-index]
        (while (< i count)
          (match (ir.compiler-ir-block-seq-ref seq i)
            [(Block _ instrs)
              (compiler-reg-foldable-rebate-seq!
                rebates
                instrs
                (array-ref weights index))])
          (set! index (+ index 1))
          (set! i (+ i 1))))]))

(define (compiler-reg-function-foldable-rebates
  [blocks : ir.CompilerIrBlockList]
  [weights : (__tl_dyn-array i64)]
  [vars : i64]) : (__tl_dyn-array i64)
  (let
    [rebates : (__tl_dyn-array i64) (__tl_make-array i64 vars)]
    (compiler-reg-foldable-rebate-blocks! (&mut rebates) blocks weights 0)
    rebates))

(define (compiler-reg-cold-call-rewrite-function
  [type-segment-bases : i64]
  [func : ir.CompilerIrFunction]) : reg.CompilerRegColdCallRewrite
  (reg.compiler-reg-cold-call-rewrite-function-with-representations
    type-segment-bases
    func
    (ir.compiler-ir-representation-index-empty)))

(cfg
  test
  (define (compiler-reg-call-set-count-in-range-words
    [set : live.CompilerLiveI64Set]
    [start : i64]
    [end : i64]
    [word-index : i64]) : i64
    (if (>= word-index (live.compiler-live-set-word-count set))
      0
      (+
        (compiler-reg-call-word-count-in-range
          (live.compiler-live-set-word-at-bounded set word-index)
          (* word-index (live.compiler-live-set-word-bits))
          start
          end)
        (compiler-reg-call-set-count-in-range-words
          set
          start
          end
          (+ word-index 1))))))

(cfg
  test
  (define (compiler-reg-call-set-count-in-range
    [set : live.CompilerLiveI64Set]
    [start : i64]
    [end : i64]) : i64
    (compiler-reg-call-set-count-in-range-words set start end 0)))

(define (compiler-reg-program-maps-suppressed-current?) : bool
  reg.compiler-reg-program-maps-suppressed?)

;; Backend-private SysV MEMORY transport values retain a nominal Struct name
;; carrying `__tl_internal_abi_mem_s<SIZE>__...`.  Regalloc only needs a
;; conservative prefix/shape test to reserve staging scratch; the backend's
;; bounded decoder is authoritative for the actual byte count.
(define (compiler-reg-private-memory-name? [name : String]) : bool
  (let
    [prefix : String "__tl_internal_abi_mem_s"]
    [prefix-len : i64 (string.string-length prefix)]
    [n : i64 (string.string-length name)]
    [i : i64 prefix-len]
    [digits : i64 0]
    [delimiter? : bool false]
    [valid : bool
      (and
        (>= n prefix-len)
        (string.eq (string.substring name 0 prefix-len) prefix))]
    (while (and valid (< i n))
      (let
        [digit : i64 (cast (string.string-ref name i) : i64)]
        (if (and (>= digit 48) (<= digit 57))
          (begin
            (set! digits (+ digits 1))
            (set! i (+ i 1)))
          (if (and
            (= (cast (string.string-ref name i) : i64) 95)
            (< (+ i 1) n)
            (= (cast (string.string-ref name (+ i 1)) : i64) 95))
            (begin
              (set! delimiter? true)
              (set! i n))
            (set! valid false)))))
    (and valid (> digits 0) delimiter?)))

(define (compiler-reg-private-memory-type?
  [type-segment-bases : i64]
  [ty : ast.AstType]) : bool
  (match ty
    [(Struct name)
      (and
        (ir.compiler-ir-symbol-owned? name)
        (compiler-reg-private-memory-name? (ir.compiler-ir-symbol-text name)))]
    [(StructArgs name _)
      (and
        (ir.compiler-ir-symbol-owned? name)
        (compiler-reg-private-memory-name? (ir.compiler-ir-symbol-text name)))]
    [(Region _ inner)
      (compiler-reg-private-memory-type?
        type-segment-bases
        (ast.ast-type-segment-bases-get type-segment-bases inner))]
    [_ false]))

(define (compiler-reg-type-register-group-word-sse?
  [type-segment-bases : i64]
  [representations : ir.CompilerIrRepresentationIndex]
  [ty : ast.AstType]
  [word-index : i64]) : bool
  (match (reg.compiler-reg-global-shared-view ty)
    [(Ref _ _) false]
    [(MutRef _ _) false]
    [(Region _ inner)
      (compiler-reg-type-register-group-word-sse?
        type-segment-bases
        representations
        (ast.ast-type-segment-bases-get type-segment-bases inner)
        word-index)]
    [_
      (if (or (< word-index 0) (> word-index 1))
        false
        (match (ir.compiler-ir-representation-index-kind
          type-segment-bases
          representations
          ty)
          [(RegisterGroup _ mask)
            (not
              (=
                (bit-and
                  mask
                  (if (= word-index 0)
                    1
                    2))
                0))]
          [_ false]))]))

(define (compiler-reg-plan-function-with-type-segment-bases-for-abi-and-representations
  [type-segment-bases : i64]
  [target-abi : cabi.CompilerRegTargetAbi]
  [func : ir.CompilerIrFunction]
  [representations : ir.CompilerIrRepresentationIndex]) : reg.CompilerRegPlan
  (reg.compiler-reg-plan-function-with-type-segment-bases-for-abi-and-representations-and-metrics
    type-segment-bases
    target-abi
    func
    representations
    (reg.compiler-reg-profile-metrics-new)))

(define (compiler-reg-plan-function-with-type-segment-bases-for-abi
  [type-segment-bases : i64]
  [target-abi : cabi.CompilerRegTargetAbi]
  [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
  (compiler-reg-plan-function-with-type-segment-bases-for-abi-and-representations
    type-segment-bases
    target-abi
    func
    (ir.compiler-ir-representation-index-empty)))

(define (compiler-reg-plan-function-for-abi
  [target-abi : cabi.CompilerRegTargetAbi]
  [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
  (compiler-reg-plan-function-with-type-segment-bases-for-abi
    (ast.ast-node-pool-reader-type-segment-bases)
    target-abi
    func))

(define (compiler-reg-plan-function [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
  (compiler-reg-plan-function-for-abi Linux func))

(define (compiler-reg-plan-function-avx2-with-type-segment-bases-for-abi-and-representations
  [type-segment-bases : i64]
  [target-abi : cabi.CompilerRegTargetAbi]
  [func : ir.CompilerIrFunction]
  [representations : ir.CompilerIrRepresentationIndex]) : reg.CompilerRegPlan
  (reg.compiler-reg-plan-function-avx2-with-type-segment-bases-for-abi-and-representations-and-metrics
    type-segment-bases
    target-abi
    func
    representations
    (reg.compiler-reg-profile-metrics-new)))

(define (compiler-reg-plan-function-avx2-with-type-segment-bases-for-abi
  [type-segment-bases : i64]
  [target-abi : cabi.CompilerRegTargetAbi]
  [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
  (compiler-reg-plan-function-avx2-with-type-segment-bases-for-abi-and-representations
    type-segment-bases
    target-abi
    func
    (ir.compiler-ir-representation-index-empty)))

(define (compiler-reg-plan-function-avx2-for-abi
  [target-abi : cabi.CompilerRegTargetAbi]
  [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
  (compiler-reg-plan-function-avx2-with-type-segment-bases-for-abi
    (ast.ast-node-pool-reader-type-segment-bases)
    target-abi
    func))

;; The cold-call carrier is the ABI boundary: it must never be colored into a
;; register or rematerialized, because the real call is deliberately absent
;; from the GP clobber mask.  Missing assignments are the backend's ordinary
;; stack-home representation and are therefore valid here.
(cfg
  test
  (define (compiler-reg-cold-call-carriers-stack?
    [plan : reg.CompilerRegPlan]
    [temp-start : i64]
    [vars : i64]) : bool
    (if (< temp-start 0)
      true
      (match plan
        [(Plan assignments _ _ _ _)
          (let
            [v : i64 temp-start]
            [ok : bool (< temp-start vars)]
            (while (and ok (< v vars))
              (match (reg.compiler-reg-assignment-lookup assignments v)
                [(No) unit]
                [(Some location)
                  (match location
                    [(Spill _) unit]
                    [_ (set! ok false)])])
              (set! v (+ v 1)))
            ok)]))))

(define (compiler-reg-color-stack-slots
  [type-segment-bases : i64]
  [plan : reg.CompilerRegPlan]
  [group-vars : live.CompilerLiveI64Set]
  [params : ir.CompilerIrParamSeq]
  [blocks : ir.CompilerIrBlockList]
  [vars : i64]
  [slot-candidate-vars : i64]
  [identity-pinned : live.CompilerLiveI64Set]) : reg.CompilerRegColoring
  (reg.compiler-reg-color-stack-slots-with-stack-only
    type-segment-bases
    plan
    group-vars
    params
    blocks
    vars
    slot-candidate-vars
    identity-pinned
    false))