;# benchmarks/ssa_construct/bench.tl - the optimizer's SSA construction.
;#
;# Equivalent to benchmarks/ssa_construct/baseline.c. The kernel is the TypeLisp
;# optimizer's `ssa` pass - phi placement at iterated dominance frontiers plus
;# the dominator-tree renaming walk - run over the real non-SSA functions the
;# compiler produced while compiling itself (see README.md for the corpus and
;# its regeneration command).
;#
;# Mirrored compiler functions, all in src/compiler_optimize.tl:
;#   opt-ssa-construct-function-from-context-and-representations-result
;#                                -- the entry: build the CFG context, run the
;#                                   single-def gate, build facts, then the four
;#                                   early-outs, then construct
;#   opt-verify-single-defs?      -- the gate; a function already in SSA is
;#                                   returned unchanged (counted, not skipped
;#                                   before the check runs)
;#   opt-ssa-facts-from-function-with-representations / -add-params / -add-instr
;#                                -- per-var definition counts in an
;#                                   open-addressed i64 map, the `bad` set, and
;#                                   the dense var -> type table with its
;#                                   insertion-order sidecar
;#   opt-ssa-register-value-type? -- the fixed one-word register boundary
;#   opt-ssa-candidate?           -- count > 1, not bad, has a type
;#   opt-ssa-blocks-have-candidate-phi-dst? / -any-candidate? /
;#   opt-ssa-context-within-budget? / opt-ssa-entry-has-preds?
;#                                -- all four early-outs
;#   opt-ssa-def-blocks-from-function / opt-ssa-var-blocks-add
;#                                -- def sites per candidate, with the
;#                                   label-member marks as the dedup
;#   opt-ssa-insert-phis / -types / -for-var / -worklist / opt-ssa-phi-add-
;#   frontier / opt-ssa-phi-add-site
;#                                -- the worklist over candidate vars in
;#                                   NEWEST-FIRST type order, work-members and
;#                                   site-members cleared per var
;#   opt-cfg-dominance-frontier-with-context / -blocks / -block?
;#                                -- DF(label) recomputed from scratch per
;#                                   worklist pop: a full block scan, each
;#                                   block accepted when it is reachable, has a
;#                                   reachable predecessor dominated by `label`,
;#                                   and is not strictly dominated by `label`
;#   opt-ssa-env-* (with-capacity, register, bind, lookup, checkpoint,
;#   rollback, snapshot, snapshot-lookup, bind-phis, from-params)
;#                                -- the compact slot env with its undo log
;#   opt-ssa-rename-function-blocks / -tree / -tree-work / -instr-seq-from /
;#   opt-ssa-rename-dst / opt-ssa-rewrite-value / opt-ssa-rename-missing-blocks
;#                                -- the dominator-tree walk with enter/exit
;#                                   records, children in ascending id order,
;#                                   one env snapshot stored per block exit
;#   opt-ssa-materialize-blocks / opt-ssa-push-phis-for-label! /
;#   opt-ssa-phi-inputs / opt-ssa-phi-undef-input /
;#   opt-ssa-rewrite-preexisting-phi-inputs
;#                                -- each phi operand resolved in the OUT
;#                                   snapshot of its named predecessor
;#   opt-ssa-block-out-lookup / opt-ssa-rename-blocks-lookup-index
;#                                -- the linear newest-first scans the compiler
;#                                   really performs per block and per operand
;#   opt-ssa-construct-checked    -- the verify over the constructed function:
;#                                   single defs, and every use dominated
;#   opt-cfg-index-build / opt-cfg-dominators-with / opt-dom-build-euler! /
;#   opt-dom-info-dominates-id?   -- the CFG context (copied from
;#                                   benchmarks/cfg_domloops/bench.tl)
;#
;# Kept: every algorithm above, including the quadratic newest-first scans and
;# the per-candidate clearing of the two member arrays, which is what the pass
;# actually costs. Dropped: the IR itself (phi operands are folded, not
;# materialized as instructions), the label hash table (the corpus carries the
;# dense block ids `opt-cfg-index-build` computes), the geometric regrowth of
;# `OptLabelSet.Dense` and of the map slot arrays inside a function, and the
;# representation index (the kernel uses the compat `opt-ssa-register-value-
;# type?` boundary, which is what the corpus type classes encode).
;#
;# Self-check: per function the kernel asserts its own candidate count and
;# inserted-phi count against the exporter's independent Python replay carried
;# in the corpus, then re-runs `opt-verify-single-defs?` over the constructed
;# function and checks that every use in a reachable block is dominated by its
;# definition (the Euler interval test, phi operands at the end of their named
;# predecessor). The four outcomes are folded, so a regression changes the
;# printed number.
;#
;# The corpus path and the round count are runtime arguments, so nothing can be
;# constant folded. Each round rotates the starting function by one, so no round
;# repeats an earlier round's accumulator. The checksum is a wrapping 64-bit
;# FNV-1a fold with no division, so the printed decimal matches the C baseline's
;# `%lld` bit for bit.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (ssa-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (ssa-vec-ref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(define (ssa-vec-set!
  [items : (&mut items i64vec.Vec)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut items) index) value))

(defmacro (ssa-ref [items : Expr] [index : Expr]) : Expr
  `(ssa-vec-ref (& ,items) ,index))

(defmacro (ssa-set! [items : Expr] [index : Expr] [value : Expr]) : Expr
  `(ssa-vec-set! (&mut ,items) ,index ,value))

(define ssa-hash-basis : i64
  1469598103934665603)
(define ssa-hash-prime : i64
  1099511628211)

;; stdlib/hashmap.tl's i64 key hash: one multiply, then mask by the
;; power-of-two capacity.
(define ssa-map-hash-mul : i64
  6364136223846793005)

;; Corpus tokens and the per-function offset table.
(define ssa-tokens : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-offsets : i64vec.Vec
  (ssa-zero-vec 1))

;; opt-cfg-index-build: CSR successor and predecessor rows plus the block index.
(define ssa-succ-off : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-succ-edge : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-pred-off : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-pred-edge : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-pred-fill : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-blk-base : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-blk-count : i64vec.Vec
  (ssa-zero-vec 1))

;; opt-cfg-dominators-with + opt-dom-build-euler!
(define ssa-reachable : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-postorder : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-rpo : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-rpo-num : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-idom : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-tin : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-tout : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-child-off : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-child-edge : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-child-fill : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-stack-node : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-stack-edge : i64vec.Vec
  (ssa-zero-vec 1))

;; OptSsaFacts: two open-addressed i64 maps (definition counts, `bad` set) laid
;; out side by side, plus the dense var -> type table and its order sidecar.
(define ssa-map-keys : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-map-vals : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-map-state : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-map-meta : i64vec.Vec
  (ssa-zero-vec 8))
(define ssa-map-scratch-key : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-map-scratch-val : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-map-scratch-state : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-ty : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-ty-order : i64vec.Vec
  (ssa-zero-vec 1))

;; OptSsaVarBlocks: candidate var -> the blocks that define it.
(define ssa-vb-by-var : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-vb-len : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-vb-items : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-vb-members : i64vec.Vec
  (ssa-zero-vec 1))

;; OptSsaPhiInsertState.
(define ssa-site-var : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-site-label : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-site-ty : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-site-phivar : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-work-members : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-site-members : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-worklist : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-df-set : i64vec.Vec
  (ssa-zero-vec 1))

;; OptSsaRenameEnv and its undo log.
(define ssa-env-by-var : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-env-current : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-env-present : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-chg-slot : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-chg-val : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-chg-present : i64vec.Vec
  (ssa-zero-vec 1))

;; opt-ssa-rename-tree's dense work stack and dominator-child links.
(define ssa-w-id : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-w-exit : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-w-chk : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-child-head : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-child-link : i64vec.Vec
  (ssa-zero-vec 1))

;; OptSsaRenameBlocks / OptSsaBlockOuts and the renamed instruction pool.
(define ssa-rb-label : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-rb-base : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-rb-len : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-rn : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-out-label : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-out-entry : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-out-cur : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-out-pres : i64vec.Vec
  (ssa-zero-vec 1))

;; The materialized function and the verifier's definition index.
(define ssa-mt : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-mt-base : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-mt-len : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-def-blk : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-def-pos : i64vec.Vec
  (ssa-zero-vec 1))
(define ssa-def-seen : i64vec.Vec
  (ssa-zero-vec 1))

;; Per-function scalars.
(define ssa-frame : i64
  0)
(define ssa-nparams : i64
  0)
(define ssa-nblocks : i64
  0)
(define ssa-ninstrs : i64
  0)
(define ssa-exp-cands : i64
  0)
(define ssa-exp-phis : i64
  0)
(define ssa-exp-verify : i64
  0)
(define ssa-verify-ok : i64
  -1)
(define ssa-param-base : i64
  0)
(define ssa-reach-count : i64
  0)
(define ssa-map-stride : i64
  0)
(define ssa-ty-count : i64
  0)
(define ssa-vb-count : i64
  0)
(define ssa-site-count : i64
  0)
(define ssa-site-cap : i64
  0)
(define ssa-phi-next : i64
  0)
(define ssa-env-count : i64
  0)
(define ssa-chg-count : i64
  0)
(define ssa-rb-count : i64
  0)
(define ssa-rn-len : i64
  0)
(define ssa-out-count : i64
  0)
(define ssa-out-stride : i64
  0)
(define ssa-mt-fill : i64
  0)
(define ssa-next-var : i64
  0)
(define ssa-cand-count : i64
  0)
(define ssa-work-count : i64
  0)

(define (ssa-mix [hash : i64] [value : i64]) : i64
  (* (bit-xor hash value) ssa-hash-prime))

(define (ssa-byte-at [text : (& text str)] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (ssa-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

;; Whitespace-separated decimal integers, with `#` starting a comment that runs
;; to the end of its line.
(define (ssa-scan-ints [text : (& text str)] [out : (&mut out i64vec.Vec)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [byte : i64 (ssa-byte-at text n i)]
          (cond
            [(= byte 35)
              (while (and (< i n) (not (= (ssa-byte-at text n i) 10)))
                (set! i (+ i 1)))]
            [(or (ssa-digit? byte) (= byte 45))
              (let
                [negative : bool (= byte 45)]
                [value : i64 0]
                (begin
                  (when negative (set! i (+ i 1)))
                  (while (ssa-digit? (ssa-byte-at text n i))
                    (begin
                      (set!
                        value
                        (+ (* value 10) (- (ssa-byte-at text n i) 48)))
                      (set! i (+ i 1))))
                  (i64vec.set-ref!
                    out
                    count
                    (if negative
                      (- 0 value)
                      value))
                  (set! count (+ count 1))))]
            [else (set! i (+ i 1))])))
      count)))

;; --- open-addressed i64 -> i64 map (stdlib/hashmap.tl's i64 family) ---------
;;
;; Map 0 is `opt-ssa-count`'s definition counts, map 1 is `opt-used-add`'s bad
;; set. Neither ever removes, so the Tombstone state cannot occur; state 0 is
;; Empty and 1 is Occupied. The probe order, the multiplicative bucket hash,
;; the `capacity - capacity/4` growth limit and the doubling growth are
;; stdlib/hashmap.tl's.
(define (ssa-map-reset! [map-id : i64] [capacity : i64]) : unit
  (let
    [base : i64 (* map-id ssa-map-stride)]
    [i : i64 0]
    (begin
      (while (< i capacity)
        (begin
          (ssa-set! ssa-map-state (+ base i) 0)
          (set! i (+ i 1))))
      (ssa-set! ssa-map-meta (* map-id 4) capacity)
      (ssa-set! ssa-map-meta (+ (* map-id 4) 1) 0)
      (ssa-set! ssa-map-meta (+ (* map-id 4) 2) (- capacity (shr capacity 2))))))

(define (ssa-map-find [map-id : i64] [key : i64]) : i64
  (let
    [base : i64 (* map-id ssa-map-stride)]
    [capacity : i64 (ssa-ref ssa-map-meta (* map-id 4))]
    [mask : i64 (- capacity 1)]
    [cursor : i64 (bit-and (* key ssa-map-hash-mul) mask)]
    [walked : i64 0]
    (begin
      (while (< walked capacity)
        (let
          [slot : i64 (+ base cursor)]
          (cond
            [(= (ssa-ref ssa-map-state slot) 0) (return -1)]
            [(= (ssa-ref ssa-map-keys slot) key) (return slot)]
            [else
              (begin
                (set! cursor (bit-and (+ cursor 1) mask))
                (set! walked (+ walked 1)))])))
      -1)))

(define (ssa-map-get [map-id : i64] [key : i64] [fallback : i64]) : i64
  (let
    [slot : i64 (ssa-map-find map-id key)]
    (if (< slot 0)
      fallback
      (ssa-ref ssa-map-vals slot))))

(define (ssa-map-contains? [map-id : i64] [key : i64]) : bool
  (>= (ssa-map-find map-id key) 0))

(define (ssa-map-grow! [map-id : i64]) : unit
  (let
    [base : i64 (* map-id ssa-map-stride)]
    [old-capacity : i64 (ssa-ref ssa-map-meta (* map-id 4))]
    [capacity : i64 (* old-capacity 2)]
    [mask : i64 (- capacity 1)]
    [scan : i64 0]
    (begin
      ;; Growth recomputes the bucket of every live slot into the doubled
      ;; table, exactly as stdlib/hashmap.tl's `grow!` does.
      (while (< scan old-capacity)
        (begin
          (ssa-set!
            ssa-map-scratch-key
            scan
            (ssa-ref ssa-map-keys (+ base scan)))
          (ssa-set!
            ssa-map-scratch-val
            scan
            (ssa-ref ssa-map-vals (+ base scan)))
          (ssa-set!
            ssa-map-scratch-state
            scan
            (ssa-ref ssa-map-state (+ base scan)))
          (set! scan (+ scan 1))))
      (set! scan 0)
      (while (< scan capacity)
        (begin
          (ssa-set! ssa-map-state (+ base scan) 0)
          (set! scan (+ scan 1))))
      (set! scan 0)
      (while (< scan old-capacity)
        (begin
          (when
            (= (ssa-ref ssa-map-scratch-state scan) 1)
            (let
              [key : i64 (ssa-ref ssa-map-scratch-key scan)]
              [cursor : i64 (bit-and (* key ssa-map-hash-mul) mask)]
              (begin
                (while (= (ssa-ref ssa-map-state (+ base cursor)) 1)
                  (set! cursor (bit-and (+ cursor 1) mask)))
                (ssa-set! ssa-map-state (+ base cursor) 1)
                (ssa-set! ssa-map-keys (+ base cursor) key)
                (ssa-set!
                  ssa-map-vals
                  (+ base cursor)
                  (ssa-ref ssa-map-scratch-val scan)))))
          (set! scan (+ scan 1))))
      (ssa-set! ssa-map-meta (* map-id 4) capacity)
      (ssa-set! ssa-map-meta (+ (* map-id 4) 2) (- capacity (shr capacity 2))))))

(define (ssa-map-insert! [map-id : i64] [key : i64] [value : i64]) : unit
  (let
    [slot : i64 (ssa-map-find map-id key)]
    (if (>= slot 0)
      (ssa-set! ssa-map-vals slot value)
      (begin
        (when
          (>=
            (ssa-ref ssa-map-meta (+ (* map-id 4) 1))
            (ssa-ref ssa-map-meta (+ (* map-id 4) 2)))
          (ssa-map-grow! map-id))
        (let
          [base : i64 (* map-id ssa-map-stride)]
          [mask : i64 (- (ssa-ref ssa-map-meta (* map-id 4)) 1)]
          [cursor : i64 (bit-and (* key ssa-map-hash-mul) mask)]
          (begin
            (while (= (ssa-ref ssa-map-state (+ base cursor)) 1)
              (set! cursor (bit-and (+ cursor 1) mask)))
            (ssa-set! ssa-map-state (+ base cursor) 1)
            (ssa-set! ssa-map-keys (+ base cursor) key)
            (ssa-set! ssa-map-vals (+ base cursor) value)
            (ssa-set!
              ssa-map-meta
              (+ (* map-id 4) 1)
              (+ (ssa-ref ssa-map-meta (+ (* map-id 4) 1)) 1))))))))

;; --- corpus decoding -------------------------------------------------------
;;
;; Instruction records are variable width; both languages walk them with the
;; same stride function.
(define (ssa-instr-next [items : (& items i64vec.Vec)] [pos : i64]) : i64
  (let
    [slots (i64vec.slots items)]
    [kind : i64 (array-ref slots pos)]
    (if (= kind 5)
      (+ (+ pos 4) (* 2 (array-ref slots (+ pos 3))))
      (let
        [uses : i64 (array-ref slots (+ pos 1))]
        (+
          (+ (+ pos 2) uses)
          (+
            (if (= kind 0)
              0
              1)
            (if (= kind 1)
              1
              0)))))))

(define (ssa-instr-dst [items : (& items i64vec.Vec)] [pos : i64]) : i64
  (let
    [slots (i64vec.slots items)]
    [kind : i64 (array-ref slots pos)]
    (cond
      [(= kind 0) -1]
      [(= kind 5) (array-ref slots (+ pos 1))]
      [else (array-ref slots (+ (+ pos 2) (array-ref slots (+ pos 1))))])))

;; opt-cfg-index-build for one corpus record: block ids in list order, the CSR
;; successor rows as written, then the predecessor rows by counting sort (which
;; is `opt-cfg-csr-fill-rows!`'s ascending source order).
(define (ssa-load-function [offset : i64]) : unit
  (let
    [cursor : i64 offset]
    [block : i64 0]
    [edge : i64 0]
    [total : i64 0]
    (begin
      (set! ssa-frame (ssa-ref ssa-tokens cursor))
      (set! ssa-nparams (ssa-ref ssa-tokens (+ cursor 1)))
      (set! ssa-nblocks (ssa-ref ssa-tokens (+ cursor 2)))
      (set! ssa-ninstrs (ssa-ref ssa-tokens (+ cursor 3)))
      (set! ssa-exp-cands (ssa-ref ssa-tokens (+ cursor 4)))
      (set! ssa-exp-phis (ssa-ref ssa-tokens (+ cursor 5)))
      (set! ssa-exp-verify (ssa-ref ssa-tokens (+ cursor 6)))
      (set! ssa-param-base (+ cursor 7))
      (set! cursor (+ (+ cursor 7) (* 2 ssa-nparams)))
      (while (< block ssa-nblocks)
        (let
          [succs : i64 (ssa-ref ssa-tokens cursor)]
          [k : i64 0]
          [count : i64 0]
          (begin
            (ssa-set! ssa-succ-off block edge)
            (while (< k succs)
              (begin
                (ssa-set!
                  ssa-succ-edge
                  edge
                  (ssa-ref ssa-tokens (+ (+ cursor 1) k)))
                (set! edge (+ edge 1))
                (set! k (+ k 1))))
            (set! cursor (+ (+ cursor 1) succs))
            (set! count (ssa-ref ssa-tokens cursor))
            (set! cursor (+ cursor 1))
            (ssa-set! ssa-blk-base block cursor)
            (ssa-set! ssa-blk-count block count)
            (set! k 0)
            (while (< k count)
              (begin
                (set! cursor (ssa-instr-next (& ssa-tokens) cursor))
                (set! k (+ k 1))))
            (set! block (+ block 1)))))
      (ssa-set! ssa-succ-off ssa-nblocks edge)
      (set! block 0)
      (while (< block ssa-nblocks)
        (begin
          (ssa-set! ssa-pred-fill block 0)
          (set! block (+ block 1))))
      (set! block 0)
      (while (< block edge)
        (let
          [dst : i64 (ssa-ref ssa-succ-edge block)]
          (begin
            (ssa-set! ssa-pred-fill dst (+ (ssa-ref ssa-pred-fill dst) 1))
            (set! block (+ block 1)))))
      (set! block 0)
      (while (< block ssa-nblocks)
        (begin
          (ssa-set! ssa-pred-off block total)
          (set! total (+ total (ssa-ref ssa-pred-fill block)))
          (ssa-set! ssa-pred-fill block (ssa-ref ssa-pred-off block))
          (set! block (+ block 1))))
      (ssa-set! ssa-pred-off ssa-nblocks total)
      (set! block 0)
      (while (< block ssa-nblocks)
        (let
          [k : i64 (ssa-ref ssa-succ-off block)]
          [end : i64 (ssa-ref ssa-succ-off (+ block 1))]
          (begin
            (while (< k end)
              (let
                [dst : i64 (ssa-ref ssa-succ-edge k)]
                (begin
                  (ssa-set! ssa-pred-edge (ssa-ref ssa-pred-fill dst) block)
                  (ssa-set! ssa-pred-fill dst (+ (ssa-ref ssa-pred-fill dst) 1))
                  (set! k (+ k 1)))))
            (set! block (+ block 1))))))))

;; --- opt-cfg-context-build (copied from benchmarks/cfg_domloops/bench.tl) ---
(define (ssa-dfs-postorder) : unit
  (let
    [count : i64 ssa-nblocks]
    [i : i64 0]
    [sp : i64 0]
    [post : i64 0]
    (begin
      (while (< i count)
        (begin
          (ssa-set! ssa-reachable i 0)
          (ssa-set! ssa-postorder i -1)
          (ssa-set! ssa-rpo i -1)
          (ssa-set! ssa-rpo-num i -1)
          (set! i (+ i 1))))
      (when
        (> count 0)
        (begin
          (ssa-set! ssa-reachable 0 1)
          (ssa-set! ssa-stack-node 0 0)
          (ssa-set! ssa-stack-edge 0 (ssa-ref ssa-succ-off 0))
          (set! sp 0)
          (while (>= sp 0)
            (let
              [node : i64 (ssa-ref ssa-stack-node sp)]
              [cursor : i64 (ssa-ref ssa-stack-edge sp)]
              (if (< cursor (ssa-ref ssa-succ-off (+ node 1)))
                (let
                  [next : i64 (ssa-ref ssa-succ-edge cursor)]
                  (begin
                    (ssa-set! ssa-stack-edge sp (+ cursor 1))
                    (when
                      (= (ssa-ref ssa-reachable next) 0)
                      (begin
                        (ssa-set! ssa-reachable next 1)
                        (set! sp (+ sp 1))
                        (ssa-set! ssa-stack-node sp next)
                        (ssa-set! ssa-stack-edge sp (ssa-ref ssa-succ-off next))))))
                (begin
                  (ssa-set! ssa-postorder post node)
                  (set! post (+ post 1))
                  (set! sp (- sp 1))))))))
      (set! ssa-reach-count post)
      (set! i 0)
      (while (< i post)
        (begin
          (ssa-set! ssa-rpo i (ssa-ref ssa-postorder (- (- post 1) i)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i post)
        (begin
          (ssa-set! ssa-rpo-num (ssa-ref ssa-rpo i) i)
          (set! i (+ i 1)))))))

(define (ssa-idom-iterate) : bool
  (let
    [slot : i64 1]
    [changed : bool false]
    (begin
      (while (< slot ssa-reach-count)
        (let
          [id : i64 (ssa-ref ssa-rpo slot)]
          [edge : i64 (ssa-ref ssa-pred-off id)]
          [end : i64 (ssa-ref ssa-pred-off (+ id 1))]
          [candidate : i64 -1]
          (begin
            (while (< edge end)
              (let
                [pred : i64 (ssa-ref ssa-pred-edge edge)]
                (begin
                  (when
                    (and
                      (= (ssa-ref ssa-reachable pred) 1)
                      (>= (ssa-ref ssa-idom pred) 0))
                    (if (< candidate 0)
                      (set! candidate pred)
                      (let
                        [a : i64 pred]
                        [b : i64 candidate]
                        (begin
                          (while (not (= a b))
                            (begin
                              (while (>
                                (ssa-ref ssa-rpo-num a)
                                (ssa-ref ssa-rpo-num b))
                                (set! a (ssa-ref ssa-idom a)))
                              (while (>
                                (ssa-ref ssa-rpo-num b)
                                (ssa-ref ssa-rpo-num a))
                                (set! b (ssa-ref ssa-idom b)))))
                          (set! candidate a)))))
                  (set! edge (+ edge 1)))))
            (when
              (and
                (not (= id 0))
                (>= candidate 0)
                (not (= (ssa-ref ssa-idom id) candidate)))
              (begin
                (ssa-set! ssa-idom id candidate)
                (set! changed true)))
            (set! slot (+ slot 1)))))
      changed)))

(define (ssa-build-euler) : unit
  (let
    [count : i64 ssa-nblocks]
    [i : i64 0]
    [total : i64 0]
    [sp : i64 0]
    [time : i64 0]
    (begin
      (while (< i count)
        (begin
          (ssa-set! ssa-tin i -1)
          (ssa-set! ssa-tout i -1)
          (ssa-set! ssa-child-fill i 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i count)
        (let
          [parent : i64 (ssa-ref ssa-idom i)]
          (begin
            (when
              (and
                (= (ssa-ref ssa-reachable i) 1)
                (>= parent 0)
                (not (= parent i)))
              (ssa-set!
                ssa-child-fill
                parent
                (+ (ssa-ref ssa-child-fill parent) 1)))
            (set! i (+ i 1)))))
      (set! i 0)
      (while (< i count)
        (begin
          (ssa-set! ssa-child-off i total)
          (set! total (+ total (ssa-ref ssa-child-fill i)))
          (ssa-set! ssa-child-fill i (ssa-ref ssa-child-off i))
          (set! i (+ i 1))))
      (ssa-set! ssa-child-off count total)
      (set! i 0)
      (while (< i count)
        (let
          [parent : i64 (ssa-ref ssa-idom i)]
          (begin
            (when
              (and
                (= (ssa-ref ssa-reachable i) 1)
                (>= parent 0)
                (not (= parent i)))
              (begin
                (ssa-set! ssa-child-edge (ssa-ref ssa-child-fill parent) i)
                (ssa-set!
                  ssa-child-fill
                  parent
                  (+ (ssa-ref ssa-child-fill parent) 1))))
            (set! i (+ i 1)))))
      (when
        (and (> count 0) (= (ssa-ref ssa-reachable 0) 1))
        (begin
          (ssa-set! ssa-stack-node 0 0)
          (ssa-set! ssa-stack-edge 0 (ssa-ref ssa-child-off 0))
          (ssa-set! ssa-tin 0 0)
          (set! time 1)
          (set! sp 0)
          (while (>= sp 0)
            (let
              [node : i64 (ssa-ref ssa-stack-node sp)]
              [cursor : i64 (ssa-ref ssa-stack-edge sp)]
              (if (< cursor (ssa-ref ssa-child-off (+ node 1)))
                (let
                  [child : i64 (ssa-ref ssa-child-edge cursor)]
                  (begin
                    (ssa-set! ssa-stack-edge sp (+ cursor 1))
                    (ssa-set! ssa-tin child time)
                    (set! time (+ time 1))
                    (set! sp (+ sp 1))
                    (ssa-set! ssa-stack-node sp child)
                    (ssa-set! ssa-stack-edge sp (ssa-ref ssa-child-off child))))
                (begin
                  (ssa-set! ssa-tout node time)
                  (set! sp (- sp 1)))))))))))

;; opt-dom-info-dominates-id?
(define (ssa-dominates? [dominator : i64] [label : i64]) : bool
  (if (and
    (= (ssa-ref ssa-reachable dominator) 1)
    (= (ssa-ref ssa-reachable label) 1))
    (and
      (>= (ssa-ref ssa-tin dominator) 0)
      (>= (ssa-ref ssa-tin label) 0)
      (<= (ssa-ref ssa-tin dominator) (ssa-ref ssa-tin label))
      (<= (ssa-ref ssa-tout label) (ssa-ref ssa-tout dominator)))
    false))

(define (ssa-build-context) : unit
  (let
    [i : i64 0]
    [remaining : i64 0]
    (begin
      (ssa-dfs-postorder)
      (while (< i ssa-nblocks)
        (begin
          (ssa-set! ssa-idom i -1)
          (set! i (+ i 1))))
      (when
        (and (> ssa-nblocks 0) (= (ssa-ref ssa-reachable 0) 1))
        (begin
          (ssa-set! ssa-idom 0 0)
          (set! remaining (+ ssa-nblocks 1))
          (while (and (> remaining 0) (ssa-idom-iterate))
            (set! remaining (- remaining 1)))))
      (ssa-build-euler))))

;; opt-ssa-entry-has-preds?
(define (ssa-entry-has-preds?) : bool
  (> (- (ssa-ref ssa-pred-off 1) (ssa-ref ssa-pred-off 0)) 0))

;; --- opt-verify-single-defs? over the input function -----------------------
(define (ssa-input-single-defs?) : bool
  (let
    [i : i64 0]
    [block : i64 0]
    [ok : bool true]
    (begin
      (while (< i ssa-frame)
        (begin
          (ssa-set! ssa-def-seen i 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i ssa-nparams)
        (let
          [var : i64 (ssa-ref ssa-tokens (+ ssa-param-base (* 2 i)))]
          (begin
            (if (or (< var 0) (>= var ssa-frame))
              (set! ok false)
              (if (= (ssa-ref ssa-def-seen var) 1)
                (set! ok false)
                (ssa-set! ssa-def-seen var 1)))
            (when (not ok) (return false))
            (set! i (+ i 1)))))
      (while (< block ssa-nblocks)
        (let
          [pos : i64 (ssa-ref ssa-blk-base block)]
          [k : i64 0]
          [count : i64 (ssa-ref ssa-blk-count block)]
          (begin
            (while (< k count)
              (let
                [dst : i64 (ssa-instr-dst (& ssa-tokens) pos)]
                (begin
                  (when
                    (>= dst 0)
                    (if (>= dst ssa-frame)
                      (set! ok false)
                      (if (= (ssa-ref ssa-def-seen dst) 1)
                        (set! ok false)
                        (ssa-set! ssa-def-seen dst 1))))
                  (when (not ok) (return false))
                  (set! pos (ssa-instr-next (& ssa-tokens) pos))
                  (set! k (+ k 1)))))
            (set! block (+ block 1)))))
      true)))

;; --- opt-ssa-facts-from-function-with-representations ----------------------
(define (ssa-facts-add-def-ty [var : i64] [ty : i64]) : unit
  (begin
    (ssa-map-insert! 0 var (+ (ssa-map-get 0 var 0) 1))
    (if (< ty 0)
      (ssa-map-insert! 1 var 1)
      (let
        [old : i64 (ssa-ref ssa-ty var)]
        (if (= old 0)
          (begin
            (ssa-set! ssa-ty var ty)
            (ssa-set! ssa-ty-order ssa-ty-count var)
            (set! ssa-ty-count (+ ssa-ty-count 1)))
          (unless (= old ty) (ssa-map-insert! 1 var 1)))))))

(define (ssa-facts-add-def-bad [var : i64]) : unit
  (begin
    (ssa-map-insert! 0 var (+ (ssa-map-get 0 var 0) 1))
    (ssa-map-insert! 1 var 1)))

(define (ssa-build-facts) : unit
  (let
    [i : i64 0]
    [block : i64 0]
    (begin
      (ssa-map-reset! 0 64)
      (ssa-map-reset! 1 64)
      (while (< i ssa-frame)
        (begin
          (ssa-set! ssa-ty i 0)
          (set! i (+ i 1))))
      (set! ssa-ty-count 0)
      (set! i 0)
      (while (< i ssa-nparams)
        (begin
          (ssa-facts-add-def-ty
            (ssa-ref ssa-tokens (+ ssa-param-base (* 2 i)))
            (ssa-ref ssa-tokens (+ (+ ssa-param-base (* 2 i)) 1)))
          (set! i (+ i 1))))
      (while (< block ssa-nblocks)
        (let
          [pos : i64 (ssa-ref ssa-blk-base block)]
          [k : i64 0]
          [count : i64 (ssa-ref ssa-blk-count block)]
          (begin
            (while (< k count)
              (let
                [kind : i64 (ssa-ref ssa-tokens pos)]
                [uses : i64 0]
                (begin
                  (cond
                    [(= kind 1)
                      (begin
                        (set! uses (ssa-ref ssa-tokens (+ pos 1)))
                        (ssa-facts-add-def-ty
                          (ssa-ref ssa-tokens (+ (+ pos 2) uses))
                          (ssa-ref ssa-tokens (+ (+ pos 3) uses))))]
                    [(= kind 5)
                      (ssa-facts-add-def-ty
                        (ssa-ref ssa-tokens (+ pos 1))
                        (ssa-ref ssa-tokens (+ pos 2)))]
                    [(= kind 2)
                      (ssa-facts-add-def-bad
                        (ssa-ref
                          ssa-tokens
                          (+ (+ pos 2) (ssa-ref ssa-tokens (+ pos 1)))))]
                    [(= kind 3)
                      (begin
                        (set! uses (ssa-ref ssa-tokens (+ pos 1)))
                        (ssa-facts-add-def-bad
                          (ssa-ref ssa-tokens (+ (+ pos 2) uses)))
                        (when
                          (> uses 0)
                          (ssa-map-insert! 1 (ssa-ref ssa-tokens (+ pos 2)) 1)))]
                    [else unit])
                  (set! pos (ssa-instr-next (& ssa-tokens) pos))
                  (set! k (+ k 1)))))
            (set! block (+ block 1))))))))

;; opt-ssa-candidate?
(define (ssa-candidate? [var : i64]) : bool
  (and
    (> (ssa-map-get 0 var 0) 1)
    (not (ssa-map-contains? 1 var))
    (not (= (ssa-ref ssa-ty var) 0))))

;; opt-ssa-any-candidate? / opt-ssa-env-candidate-count-from: the type table is
;; walked newest first.
(define (ssa-count-candidates) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index ssa-ty-count)
        (begin
          (when
            (ssa-candidate? (ssa-ref ssa-ty-order (- (- ssa-ty-count index) 1)))
            (set! count (+ count 1)))
          (set! index (+ index 1))))
      count)))

;; opt-ssa-blocks-have-candidate-phi-dst?
(define (ssa-candidate-phi-dst?) : bool
  (let
    [block : i64 0]
    (begin
      (while (< block ssa-nblocks)
        (let
          [pos : i64 (ssa-ref ssa-blk-base block)]
          [k : i64 0]
          [count : i64 (ssa-ref ssa-blk-count block)]
          (begin
            (while (< k count)
              (begin
                (when
                  (and
                    (= (ssa-ref ssa-tokens pos) 5)
                    (ssa-candidate? (ssa-ref ssa-tokens (+ pos 1))))
                  (return true))
                (set! pos (ssa-instr-next (& ssa-tokens) pos))
                (set! k (+ k 1))))
            (set! block (+ block 1)))))
      false)))

;; --- opt-ssa-def-blocks-from-function --------------------------------------
(define (ssa-var-blocks-add [var : i64] [label : i64]) : unit
  (let
    [slot : i64 (ssa-ref ssa-vb-by-var var)]
    [entry : i64 0]
    [base : i64 0]
    [i : i64 0]
    (begin
      (if (> slot 0)
        (set! entry (- slot 1))
        (begin
          (set! entry ssa-vb-count)
          (set! ssa-vb-count (+ ssa-vb-count 1))
          (set! base (* entry ssa-nblocks))
          ;; `opt-ssa-label-members-new` allocates a zeroed block-count array
          ;; the first time a var gets a definition site.
          (while (< i ssa-nblocks)
            (begin
              (ssa-set! ssa-vb-members (+ base i) 0)
              (set! i (+ i 1))))
          (ssa-set! ssa-vb-len entry 0)
          (ssa-set! ssa-vb-by-var var (+ entry 1))))
      (set! base (* entry ssa-nblocks))
      (when
        (= (ssa-ref ssa-vb-members (+ base label)) 0)
        (begin
          (ssa-set! ssa-vb-members (+ base label) 1)
          (ssa-set! ssa-vb-items (+ base (ssa-ref ssa-vb-len entry)) label)
          (ssa-set! ssa-vb-len entry (+ (ssa-ref ssa-vb-len entry) 1)))))))

(define (ssa-def-blocks) : unit
  (let
    [i : i64 0]
    [block : i64 0]
    (begin
      (while (< i ssa-frame)
        (begin
          (ssa-set! ssa-vb-by-var i 0)
          (set! i (+ i 1))))
      (set! ssa-vb-count 0)
      (set! i 0)
      (while (< i ssa-nparams)
        (let
          [var : i64 (ssa-ref ssa-tokens (+ ssa-param-base (* 2 i)))]
          (begin
            (when (ssa-candidate? var) (ssa-var-blocks-add var 0))
            (set! i (+ i 1)))))
      (while (< block ssa-nblocks)
        (let
          [pos : i64 (ssa-ref ssa-blk-base block)]
          [k : i64 0]
          [count : i64 (ssa-ref ssa-blk-count block)]
          (begin
            (while (< k count)
              (let
                [dst : i64 (ssa-instr-dst (& ssa-tokens) pos)]
                (begin
                  (when
                    (and (>= dst 0) (ssa-candidate? dst))
                    (ssa-var-blocks-add dst block))
                  (set! pos (ssa-instr-next (& ssa-tokens) pos))
                  (set! k (+ k 1)))))
            (set! block (+ block 1))))))))

;; --- opt-cfg-dominance-frontier-with-context -------------------------------
;;
;; A full block scan per query, no cache: a block is in DF(label) when it is
;; reachable, has a reachable predecessor that `label` dominates, and is not
;; strictly dominated by `label`. `opt-label-add` re-scans the growing set.
(define (ssa-dominance-frontier [label : i64]) : i64
  (let
    [block : i64 0]
    [len : i64 0]
    (begin
      (while (< block ssa-nblocks)
        (begin
          (when
            (= (ssa-ref ssa-reachable block) 1)
            (let
              [edge : i64 (ssa-ref ssa-pred-off block)]
              [end : i64 (ssa-ref ssa-pred-off (+ block 1))]
              [found : bool false]
              [i : i64 0]
              (begin
                (while (and (< edge end) (not found))
                  (let
                    [pred : i64 (ssa-ref ssa-pred-edge edge)]
                    (begin
                      (when
                        (and
                          (= (ssa-ref ssa-reachable pred) 1)
                          (ssa-dominates? label pred))
                        (set! found true))
                      (set! edge (+ edge 1)))))
                (when
                  (and
                    found
                    (not
                      (and (not (= label block)) (ssa-dominates? label block))))
                  (let
                    [seen : bool false]
                    (begin
                      (while (< i len)
                        (begin
                          (when
                            (= (ssa-ref ssa-df-set i) block)
                            (set! seen true))
                          (set! i (+ i 1))))
                      (unless
                        seen
                        (begin
                          (ssa-set! ssa-df-set len block)
                          (set! len (+ len 1))))))))))
          (set! block (+ block 1))))
      len)))

;; --- opt-ssa-insert-phis ---------------------------------------------------
(define (ssa-phi-add-site [var : i64] [ty : i64] [label : i64]) : unit
  (when
    (and (= (ssa-ref ssa-site-members label) 0) (< ssa-site-count ssa-site-cap))
    (begin
      (ssa-set! ssa-site-members label 1)
      (ssa-set! ssa-site-var ssa-site-count var)
      (ssa-set! ssa-site-label ssa-site-count label)
      (ssa-set! ssa-site-ty ssa-site-count ty)
      (ssa-set! ssa-site-phivar ssa-site-count ssa-phi-next)
      (set! ssa-site-count (+ ssa-site-count 1))
      (set! ssa-phi-next (+ ssa-phi-next 1))
      (when
        (= (ssa-ref ssa-work-members label) 0)
        (begin
          (ssa-set! ssa-work-members label 1)
          (ssa-set! ssa-worklist ssa-work-count label)
          (set! ssa-work-count (+ ssa-work-count 1)))))))

(define (ssa-insert-phis-for-var [var : i64] [ty : i64]) : unit
  (let
    [i : i64 0]
    [slot : i64 (ssa-ref ssa-vb-by-var var)]
    (begin
      (while (< i ssa-nblocks)
        (begin
          (ssa-set! ssa-work-members i 0)
          (ssa-set! ssa-site-members i 0)
          (set! i (+ i 1))))
      (set! ssa-work-count 0)
      (when
        (> slot 0)
        (let
          [base : i64 (* (- slot 1) ssa-nblocks)]
          [len : i64 (ssa-ref ssa-vb-len (- slot 1))]
          (begin
            (set! i 0)
            (while (< i len)
              (begin
                (ssa-set! ssa-worklist i (ssa-ref ssa-vb-items (+ base i)))
                (ssa-set! ssa-work-members (ssa-ref ssa-vb-items (+ base i)) 1)
                (set! i (+ i 1))))
            (set! ssa-work-count len))))
      (while (> ssa-work-count 0)
        (let
          [label : i64 (ssa-ref ssa-worklist (- ssa-work-count 1))]
          [len : i64 0]
          [k : i64 0]
          (begin
            (set! ssa-work-count (- ssa-work-count 1))
            (set! len (ssa-dominance-frontier label))
            (while (< k len)
              (begin
                (ssa-phi-add-site var ty (ssa-ref ssa-df-set k))
                (set! k (+ k 1))))))))))

(define (ssa-insert-phis) : unit
  (let
    [index : i64 0]
    (begin
      (set! ssa-site-count 0)
      (set! ssa-phi-next ssa-frame)
      (ssa-def-blocks)
      (while (< index ssa-ty-count)
        (let
          [var : i64 (ssa-ref ssa-ty-order (- (- ssa-ty-count index) 1))]
          (begin
            (when
              (ssa-candidate? var)
              (ssa-insert-phis-for-var var (ssa-ref ssa-ty var)))
            (set! index (+ index 1))))))))

;; --- opt-ssa-rename-* ------------------------------------------------------
(define (ssa-env-lookup [var : i64]) : i64
  (if (or (< var 0) (>= var ssa-phi-next))
    -1
    (let
      [slot : i64 (- (ssa-ref ssa-env-by-var var) 1)]
      (if (or
        (< slot 0)
        (>= slot ssa-env-count)
        (= (ssa-ref ssa-env-present slot) 0))
        -1
        (ssa-ref ssa-env-current slot)))))

(define (ssa-env-bind [original : i64] [current : i64]) : unit
  (let
    [slot : i64 (- (ssa-ref ssa-env-by-var original) 1)]
    (begin
      (ssa-set! ssa-chg-slot ssa-chg-count slot)
      (ssa-set! ssa-chg-val ssa-chg-count (ssa-ref ssa-env-current slot))
      (ssa-set! ssa-chg-present ssa-chg-count (ssa-ref ssa-env-present slot))
      (ssa-set! ssa-env-current slot current)
      (ssa-set! ssa-env-present slot 1)
      (set! ssa-chg-count (+ ssa-chg-count 1)))))

(define (ssa-env-rollback [checkpoint : i64]) : unit
  (while (> ssa-chg-count checkpoint)
    (let
      [change : i64 (- ssa-chg-count 1)]
      [slot : i64 (ssa-ref ssa-chg-slot change)]
      (begin
        (ssa-set! ssa-env-current slot (ssa-ref ssa-chg-val change))
        (ssa-set! ssa-env-present slot (ssa-ref ssa-chg-present change))
        (set! ssa-chg-count change)))))

;; opt-ssa-env-bind-phis: a full newest-first scan of the phi sites per block.
(define (ssa-env-bind-phis [label : i64]) : unit
  (let
    [index : i64 0]
    (while (< index ssa-site-count)
      (let
        [site : i64 (- (- ssa-site-count index) 1)]
        (begin
          (when
            (= (ssa-ref ssa-site-label site) label)
            (ssa-env-bind
              (ssa-ref ssa-site-var site)
              (ssa-ref ssa-site-phivar site)))
          (set! index (+ index 1)))))))

;; opt-ssa-rename-instr-seq-from + opt-ssa-rename-dst + opt-ssa-rewrite-value.
;; A Phi passes through untouched; its inputs are edge uses resolved later.
(define (ssa-rename-block [block : i64]) : unit
  (let
    [pos : i64 (ssa-ref ssa-blk-base block)]
    [k : i64 0]
    [count : i64 (ssa-ref ssa-blk-count block)]
    (while (< k count)
      (let
        [kind : i64 (ssa-ref ssa-tokens pos)]
        [next : i64 (ssa-instr-next (& ssa-tokens) pos)]
        [i : i64 0]
        (begin
          (if (= kind 5)
            (begin
              (while (< (+ pos i) next)
                (begin
                  (ssa-set!
                    ssa-rn
                    (+ ssa-rn-len i)
                    (ssa-ref ssa-tokens (+ pos i)))
                  (set! i (+ i 1))))
              (set! ssa-rn-len (+ ssa-rn-len i)))
            (let
              [uses : i64 (ssa-ref ssa-tokens (+ pos 1))]
              [dst : i64 0]
              (begin
                (ssa-set! ssa-rn ssa-rn-len kind)
                (ssa-set! ssa-rn (+ ssa-rn-len 1) uses)
                (set! i 0)
                (while (< i uses)
                  (let
                    [var : i64 (ssa-ref ssa-tokens (+ (+ pos 2) i))]
                    [current : i64 (ssa-env-lookup var)]
                    (begin
                      (ssa-set!
                        ssa-rn
                        (+ (+ ssa-rn-len 2) i)
                        (if (< current 0)
                          var
                          current))
                      (set! i (+ i 1)))))
                (when
                  (not (= kind 0))
                  (begin
                    (set! dst (ssa-ref ssa-tokens (+ (+ pos 2) uses)))
                    (if (ssa-candidate? dst)
                      (begin
                        (ssa-set! ssa-rn (+ (+ ssa-rn-len 2) uses) ssa-next-var)
                        (ssa-env-bind dst ssa-next-var)
                        (set! ssa-next-var (+ ssa-next-var 1)))
                      (ssa-set! ssa-rn (+ (+ ssa-rn-len 2) uses) dst))
                    (when
                      (= kind 1)
                      (ssa-set!
                        ssa-rn
                        (+ (+ ssa-rn-len 3) uses)
                        (ssa-ref ssa-tokens (+ (+ pos 3) uses))))))
                (set! ssa-rn-len (- (+ ssa-rn-len (- next pos)) 0)))))
          (set! pos next)
          (set! k (+ k 1)))))))

(define (ssa-add-rename-block [block : i64] [base : i64]) : unit
  (let
    [i : i64 0]
    [dest : i64 (* ssa-out-count ssa-out-stride)]
    (begin
      (ssa-set! ssa-rb-label ssa-rb-count block)
      (ssa-set! ssa-rb-base ssa-rb-count base)
      (ssa-set! ssa-rb-len ssa-rb-count (- ssa-rn-len base))
      (set! ssa-rb-count (+ ssa-rb-count 1))
      ;; opt-ssa-env-snapshot clones the compact current/present prefixes.
      (while (< i ssa-env-count)
        (begin
          (ssa-set! ssa-out-cur (+ dest i) (ssa-ref ssa-env-current i))
          (ssa-set! ssa-out-pres (+ dest i) (ssa-ref ssa-env-present i))
          (set! i (+ i 1))))
      (ssa-set! ssa-out-label ssa-out-count block)
      (ssa-set! ssa-out-entry ssa-out-count ssa-env-count)
      (set! ssa-out-count (+ ssa-out-count 1)))))

;; opt-ssa-block-out-lookup: linear, newest first.
(define (ssa-out-lookup [label : i64]) : i64
  (let
    [index : i64 0]
    (begin
      (while (< index ssa-out-count)
        (let
          [entry : i64 (- (- ssa-out-count index) 1)]
          (begin
            (when (= (ssa-ref ssa-out-label entry) label) (return entry))
            (set! index (+ index 1)))))
      -1)))

;; opt-ssa-rename-blocks-lookup-index: linear, newest first.
(define (ssa-rb-lookup [label : i64]) : i64
  (let
    [index : i64 0]
    (begin
      (while (< index ssa-rb-count)
        (let
          [entry : i64 (- (- ssa-rb-count index) 1)]
          (begin
            (when (= (ssa-ref ssa-rb-label entry) label) (return entry))
            (set! index (+ index 1)))))
      -1)))

;; opt-ssa-env-snapshot-lookup
(define (ssa-snapshot-lookup [entry : i64] [var : i64]) : i64
  (if (or (< entry 0) (< var 0) (>= var ssa-phi-next))
    -1
    (let
      [slot : i64 (- (ssa-ref ssa-env-by-var var) 1)]
      (if (or
        (< slot 0)
        (>= slot (ssa-ref ssa-out-entry entry))
        (= (ssa-ref ssa-out-pres (+ (* entry ssa-out-stride) slot)) 0))
        -1
        (ssa-ref ssa-out-cur (+ (* entry ssa-out-stride) slot))))))

(define (ssa-rename-tree) : unit
  (let
    [count : i64 ssa-nblocks]
    [i : i64 0]
    [work : i64 0]
    (begin
      (while (< i count)
        (begin
          (ssa-set! ssa-child-head i 0)
          (ssa-set! ssa-child-link i 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i count)
        (begin
          (when
            (and
              (not (= (ssa-ref ssa-idom i) i))
              (= (ssa-ref ssa-reachable i) 1))
            (let
              [parent : i64 (ssa-ref ssa-idom i)]
              (when
                (and (>= parent 0) (< parent count))
                (begin
                  (ssa-set! ssa-child-link i (ssa-ref ssa-child-head parent))
                  (ssa-set! ssa-child-head parent (+ i 1))))))
          (set! i (+ i 1))))
      (ssa-set! ssa-w-id 0 0)
      (ssa-set! ssa-w-exit 0 0)
      (ssa-set! ssa-w-chk 0 0)
      (set! work 1)
      (while (> work 0)
        (let
          [slot : i64 (- work 1)]
          [id : i64 (ssa-ref ssa-w-id slot)]
          [checkpoint : i64 (ssa-ref ssa-w-chk slot)]
          (if (= (ssa-ref ssa-w-exit slot) 1)
            (begin
              (ssa-env-rollback checkpoint)
              (set! work slot))
            (let
              [block-checkpoint : i64 ssa-chg-count]
              [base : i64 ssa-rn-len]
              [link : i64 0]
              (begin
                (ssa-env-bind-phis id)
                (ssa-rename-block id)
                (ssa-add-rename-block id base)
                (ssa-set! ssa-w-id slot id)
                (ssa-set! ssa-w-exit slot 1)
                (ssa-set! ssa-w-chk slot block-checkpoint)
                (set! work (+ slot 1))
                (set! link (ssa-ref ssa-child-head id))
                (while (> link 0)
                  (let
                    [child : i64 (- link 1)]
                    (begin
                      (ssa-set! ssa-w-id work child)
                      (ssa-set! ssa-w-exit work 0)
                      (ssa-set! ssa-w-chk work 0)
                      (set! work (+ work 1))
                      (set! link (ssa-ref ssa-child-link child)))))))))))))

(define (ssa-rename-missing-blocks) : unit
  (let
    [block : i64 0]
    (while (< block ssa-nblocks)
      (begin
        (when
          (< (ssa-rb-lookup block) 0)
          (let
            [checkpoint : i64 ssa-chg-count]
            [base : i64 ssa-rn-len]
            (begin
              (ssa-env-bind-phis block)
              (ssa-rename-block block)
              (ssa-add-rename-block block base)
              (ssa-env-rollback checkpoint))))
        (set! block (+ block 1))))))

(define (ssa-rename) : unit
  (let
    [index : i64 0]
    (begin
      (set! ssa-env-count 0)
      (set! ssa-chg-count 0)
      (while (< index ssa-phi-next)
        (begin
          (ssa-set! ssa-env-by-var index 0)
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index ssa-ty-count)
        (let
          [var : i64 (ssa-ref ssa-ty-order (- (- ssa-ty-count index) 1))]
          (begin
            (when
              (and (ssa-candidate? var) (= (ssa-ref ssa-env-by-var var) 0))
              (begin
                (ssa-set! ssa-env-by-var var (+ ssa-env-count 1))
                (ssa-set! ssa-env-current ssa-env-count 0)
                (ssa-set! ssa-env-present ssa-env-count 0)
                (set! ssa-env-count (+ ssa-env-count 1))))
            (set! index (+ index 1)))))
      (set! index 0)
      (while (< index ssa-nparams)
        (let
          [var : i64 (ssa-ref ssa-tokens (+ ssa-param-base (* 2 index)))]
          (begin
            (when (ssa-candidate? var) (ssa-env-bind var var))
            (set! index (+ index 1)))))
      (set! ssa-rb-count 0)
      (set! ssa-out-count 0)
      (set! ssa-rn-len 0)
      (set! ssa-next-var ssa-phi-next)
      (ssa-rename-tree)
      (ssa-rename-missing-blocks))))

;; --- opt-ssa-materialize-blocks -------------------------------------------
(define (ssa-materialize) : unit
  (let
    [block : i64 0]
    (begin
      (set! ssa-mt-fill 0)
      (while (< block ssa-nblocks)
        (let
          [index : i64 0]
          [start : i64 ssa-mt-fill]
          (begin
            ;; opt-ssa-push-phis-for-label!: sites newest first, each operand
            ;; resolved in the OUT snapshot of its named predecessor.
            (while (< index ssa-site-count)
              (let
                [site : i64 (- (- ssa-site-count index) 1)]
                (begin
                  (when
                    (= (ssa-ref ssa-site-label site) block)
                    (let
                      [edge : i64 (- (ssa-ref ssa-pred-off (+ block 1)) 1)]
                      [stop : i64 (ssa-ref ssa-pred-off block)]
                      [head : i64 ssa-mt-fill]
                      [inputs : i64 0]
                      (begin
                        (ssa-set! ssa-mt head 5)
                        (ssa-set!
                          ssa-mt
                          (+ head 1)
                          (ssa-ref ssa-site-phivar site))
                        (ssa-set! ssa-mt (+ head 2) (ssa-ref ssa-site-ty site))
                        (set! ssa-mt-fill (+ head 4))
                        (while (>= edge stop)
                          (let
                            [pred : i64 (ssa-ref ssa-pred-edge edge)]
                            [entry : i64 (ssa-out-lookup pred)]
                            (begin
                              (ssa-set!
                                ssa-mt
                                ssa-mt-fill
                                (ssa-snapshot-lookup
                                  entry
                                  (ssa-ref ssa-site-var site)))
                              (ssa-set! ssa-mt (+ ssa-mt-fill 1) pred)
                              (set! ssa-mt-fill (+ ssa-mt-fill 2))
                              (set! inputs (+ inputs 1))
                              (set! edge (- edge 1)))))
                        (ssa-set! ssa-mt (+ head 3) inputs))))
                  (set! index (+ index 1)))))
            ;; opt-ssa-push-rewritten-preexisting-instrs!
            (let
              [entry : i64 (ssa-rb-lookup block)]
              (when
                (>= entry 0)
                (let
                  [pos : i64 (ssa-ref ssa-rb-base entry)]
                  [stop : i64
                    (+ (ssa-ref ssa-rb-base entry) (ssa-ref ssa-rb-len entry))]
                  (while (< pos stop)
                    (let
                      [next : i64 (ssa-instr-next (& ssa-rn) pos)]
                      [i : i64 0]
                      (begin
                        (while (< (+ pos i) next)
                          (begin
                            (ssa-set!
                              ssa-mt
                              (+ ssa-mt-fill i)
                              (ssa-ref ssa-rn (+ pos i)))
                            (set! i (+ i 1))))
                        (when
                          (= (ssa-ref ssa-rn pos) 5)
                          (let
                            [inputs : i64 (ssa-ref ssa-rn (+ pos 3))]
                            [k : i64 0]
                            (while (< k inputs)
                              (let
                                [value : i64
                                  (ssa-ref ssa-rn (+ (+ pos 4) (* 2 k)))]
                                [pred : i64
                                  (ssa-ref ssa-rn (+ (+ pos 5) (* 2 k)))]
                                (begin
                                  (when
                                    (and (>= value 0) (ssa-candidate? value))
                                    (ssa-set!
                                      ssa-mt
                                      (+ (+ ssa-mt-fill 4) (* 2 k))
                                      (ssa-snapshot-lookup
                                        (ssa-out-lookup pred)
                                        value)))
                                  (set! k (+ k 1)))))))
                        (set! ssa-mt-fill (+ ssa-mt-fill (- next pos)))
                        (set! pos next)))))))
            (ssa-set! ssa-mt-base block start)
            (ssa-set! ssa-mt-len block (- ssa-mt-fill start))
            (set! block (+ block 1))))))))

;; --- opt-ssa-construct-checked: single defs, then use dominance ------------
(define (ssa-verify-defs) : i64
  (let
    [block : i64 0]
    [i : i64 0]
    [ok : i64 1]
    (begin
      (while (< i ssa-next-var)
        (begin
          (ssa-set! ssa-def-seen i 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i ssa-nparams)
        (let
          [var : i64 (ssa-ref ssa-tokens (+ ssa-param-base (* 2 i)))]
          (begin
            (when (= (ssa-ref ssa-def-seen var) 1) (set! ok 0))
            (ssa-set! ssa-def-seen var 1)
            (ssa-set! ssa-def-blk var 0)
            (ssa-set! ssa-def-pos var 0)
            (set! i (+ i 1)))))
      (while (< block ssa-nblocks)
        (let
          [pos : i64 (ssa-ref ssa-mt-base block)]
          [stop : i64
            (+ (ssa-ref ssa-mt-base block) (ssa-ref ssa-mt-len block))]
          [order : i64 1]
          (begin
            (while (< pos stop)
              (let
                [dst : i64 (ssa-instr-dst (& ssa-mt) pos)]
                (begin
                  (when
                    (>= dst 0)
                    (begin
                      (when (= (ssa-ref ssa-def-seen dst) 1) (set! ok 0))
                      (ssa-set! ssa-def-seen dst 1)
                      (ssa-set! ssa-def-blk dst block)
                      (ssa-set!
                        ssa-def-pos
                        dst
                        (if (= (ssa-ref ssa-mt pos) 5)
                          0
                          order))))
                  (set! order (+ order 1))
                  (set! pos (ssa-instr-next (& ssa-mt) pos)))))
            (set! block (+ block 1)))))
      ok)))

(define (ssa-verify-phi-uses [pos : i64]) : i64
  (let
    [inputs : i64 (ssa-ref ssa-mt (+ pos 3))]
    [k : i64 0]
    [ok : i64 1]
    (begin
      (while (< k inputs)
        (let
          [value : i64 (ssa-ref ssa-mt (+ (+ pos 4) (* 2 k)))]
          [pred : i64 (ssa-ref ssa-mt (+ (+ pos 5) (* 2 k)))]
          (begin
            (when
              (and (>= value 0) (= (ssa-ref ssa-reachable pred) 1))
              (when
                (or
                  (= (ssa-ref ssa-def-seen value) 0)
                  (not (ssa-dominates? (ssa-ref ssa-def-blk value) pred)))
                (set! ok 0)))
            (set! k (+ k 1)))))
      ok)))

(define (ssa-verify-plain-uses [pos : i64] [block : i64] [order : i64]) : i64
  (let
    [uses : i64 (ssa-ref ssa-mt (+ pos 1))]
    [k : i64 0]
    [ok : i64 1]
    (begin
      (while (< k uses)
        (let
          [value : i64 (ssa-ref ssa-mt (+ (+ pos 2) k))]
          (begin
            (when
              (= (ssa-ref ssa-def-seen value) 1)
              (let
                [home : i64 (ssa-ref ssa-def-blk value)]
                (when
                  (not
                    (if (= home block)
                      (< (ssa-ref ssa-def-pos value) order)
                      (ssa-dominates? home block)))
                  (set! ok 0))))
            (set! k (+ k 1)))))
      ok)))

(define (ssa-verify) : i64
  (let
    [block : i64 0]
    [ok : i64 (ssa-verify-defs)]
    (begin
      (while (< block ssa-nblocks)
        (begin
          (when
            (= (ssa-ref ssa-reachable block) 1)
            (let
              [pos : i64 (ssa-ref ssa-mt-base block)]
              [stop : i64
                (+ (ssa-ref ssa-mt-base block) (ssa-ref ssa-mt-len block))]
              [order : i64 1]
              (while (< pos stop)
                (let
                  [next : i64 (ssa-instr-next (& ssa-mt) pos)]
                  (begin
                    (when
                      (=
                        0
                        (if (= (ssa-ref ssa-mt pos) 5)
                          (ssa-verify-phi-uses pos)
                          (ssa-verify-plain-uses pos block order)))
                      (set! ok 0))
                    (set! order (+ order 1))
                    (set! pos next))))))
          (set! block (+ block 1))))
      ok)))

;; One record's `ssa` pass, folded into a checksum over the early-out taken,
;; the candidate and phi counts, the self-check outcomes and every materialized
;; instruction's destination and resolved operands.
(define (ssa-function) : i64
  (let
    [hash : i64 ssa-hash-basis]
    [block : i64 0]
    (begin
      (ssa-build-context)
      (set! ssa-verify-ok -1)
      (if (ssa-input-single-defs?)
        (ssa-mix hash 1)
        (begin
          (ssa-build-facts)
          (set! ssa-site-count 0)
          (set! ssa-cand-count (ssa-count-candidates))
          (cond
            [(ssa-candidate-phi-dst?) (set! hash (ssa-mix hash 2))]
            [(= ssa-cand-count 0) (set! hash (ssa-mix hash 3))]
            [(> ssa-nblocks 4096) (set! hash (ssa-mix hash 4))]
            [(ssa-entry-has-preds?) (set! hash (ssa-mix hash 5))]
            [else
              (begin
                (ssa-insert-phis)
                (ssa-rename)
                (ssa-materialize)
                (set! hash (ssa-mix hash 6))
                (set! hash (ssa-mix hash ssa-site-count))
                (set! hash (ssa-mix hash ssa-next-var))
                (set! hash (ssa-mix hash (- ssa-next-var ssa-phi-next)))
                (set! ssa-verify-ok (ssa-verify))
                (set! hash (ssa-mix hash ssa-verify-ok))
                (while (< block ssa-nblocks)
                  (let
                    [pos : i64 (ssa-ref ssa-mt-base block)]
                    [stop : i64
                      (+ (ssa-ref ssa-mt-base block) (ssa-ref ssa-mt-len block))]
                    (begin
                      (while (< pos stop)
                        (let
                          [next : i64 (ssa-instr-next (& ssa-mt) pos)]
                          [i : i64 1]
                          (begin
                            (set! hash (ssa-mix hash (ssa-ref ssa-mt pos)))
                            (while (< (+ pos i) next)
                              (begin
                                (set!
                                  hash
                                  (ssa-mix hash (ssa-ref ssa-mt (+ pos i))))
                                (set! i (+ i 1))))
                            (set! pos next))))
                      (set! block (+ block 1)))))
                unit)])
          (set! hash (ssa-mix hash ssa-cand-count))
          (set!
            hash
            (ssa-mix
              hash
              (if (= ssa-cand-count ssa-exp-cands)
                1
                0)))
          (set!
            hash
            (ssa-mix
              hash
              (if (= ssa-site-count ssa-exp-phis)
                1
                0)))
          (set!
            hash
            (ssa-mix
              hash
              (if (or (= ssa-verify-ok -1) (= ssa-verify-ok ssa-exp-verify))
                1
                0)))
          hash)))))

(define (ssa-bench [path : String] [rounds : i64]) : i64
  (let
    [text : String (byte_buf.to-string (io.read-file path))]
    [capacity : i64 (+ (/ (string.string-length text) 2) 8)]
    [functions : i64 0]
    [cursor : i64 1]
    [max-frame : i64 1]
    [max-blocks : i64 1]
    [max-instrs : i64 1]
    [max-edges : i64 1]
    [max-span : i64 1]
    [max-phis : i64 1]
    [map-capacity : i64 64]
    [round : i64 0]
    [start : i64 0]
    [acc : i64 ssa-hash-basis]
    (begin
      (set! ssa-tokens (ssa-zero-vec capacity))
      (set! acc (ssa-mix acc (ssa-scan-ints text (&mut ssa-tokens))))
      (set! functions (ssa-ref ssa-tokens 0))
      (set! ssa-offsets (ssa-zero-vec (+ functions 1)))
      (let
        [f : i64 0]
        (while (< f functions)
          (let
            [frame : i64 (ssa-ref ssa-tokens cursor)]
            [params : i64 (ssa-ref ssa-tokens (+ cursor 1))]
            [blocks : i64 (ssa-ref ssa-tokens (+ cursor 2))]
            [instrs : i64 (ssa-ref ssa-tokens (+ cursor 3))]
            [phis : i64 (ssa-ref ssa-tokens (+ cursor 5))]
            [edges : i64 0]
            [pos : i64 (+ (+ cursor 7) (* 2 params))]
            [block : i64 0]
            (begin
              (ssa-set! ssa-offsets f cursor)
              (while (< block blocks)
                (let
                  [succs : i64 (ssa-ref ssa-tokens pos)]
                  [count : i64 0]
                  [k : i64 0]
                  (begin
                    (set! edges (+ edges succs))
                    (set! pos (+ (+ pos 1) succs))
                    (set! count (ssa-ref ssa-tokens pos))
                    (set! pos (+ pos 1))
                    (while (< k count)
                      (begin
                        (set! pos (ssa-instr-next (& ssa-tokens) pos))
                        (set! k (+ k 1))))
                    (set! block (+ block 1)))))
              (when (> frame max-frame) (set! max-frame frame))
              (when (> blocks max-blocks) (set! max-blocks blocks))
              (when (> instrs max-instrs) (set! max-instrs instrs))
              (when (> edges max-edges) (set! max-edges edges))
              (when (> phis max-phis) (set! max-phis phis))
              (when (> (- pos cursor) max-span) (set! max-span (- pos cursor)))
              (set! cursor pos)
              (set! f (+ f 1))))))
      (while (< map-capacity (* 4 (+ max-frame max-phis)))
        (set! map-capacity (* map-capacity 2)))
      (set! ssa-map-stride map-capacity)
      (set! ssa-site-cap max-phis)
      (set! ssa-out-stride (+ max-frame 1))
      (set! ssa-succ-off (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-succ-edge (ssa-zero-vec (+ max-edges 2)))
      (set! ssa-pred-off (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-pred-edge (ssa-zero-vec (+ max-edges 2)))
      (set! ssa-pred-fill (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-blk-base (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-blk-count (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-reachable (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-postorder (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-rpo (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-rpo-num (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-idom (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-tin (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-tout (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-child-off (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-child-edge (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-child-fill (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-stack-node (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-stack-edge (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-map-keys (ssa-zero-vec (* 2 map-capacity)))
      (set! ssa-map-vals (ssa-zero-vec (* 2 map-capacity)))
      (set! ssa-map-state (ssa-zero-vec (* 2 map-capacity)))
      (set! ssa-map-scratch-key (ssa-zero-vec (+ map-capacity 1)))
      (set! ssa-map-scratch-val (ssa-zero-vec (+ map-capacity 1)))
      (set! ssa-map-scratch-state (ssa-zero-vec (+ map-capacity 1)))
      (set! ssa-ty (ssa-zero-vec (+ max-frame 1)))
      (set! ssa-ty-order (ssa-zero-vec (+ max-frame 1)))
      (set! ssa-vb-by-var (ssa-zero-vec (+ max-frame 1)))
      (set! ssa-vb-len (ssa-zero-vec (+ max-frame 1)))
      (set! ssa-vb-items (ssa-zero-vec (+ (* max-frame max-blocks) 1)))
      (set! ssa-vb-members (ssa-zero-vec (+ (* max-frame max-blocks) 1)))
      (set! ssa-site-var (ssa-zero-vec (+ max-phis 2)))
      (set! ssa-site-label (ssa-zero-vec (+ max-phis 2)))
      (set! ssa-site-ty (ssa-zero-vec (+ max-phis 2)))
      (set! ssa-site-phivar (ssa-zero-vec (+ max-phis 2)))
      (set! ssa-work-members (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-site-members (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-worklist (ssa-zero-vec (+ (* 2 max-blocks) 2)))
      (set! ssa-df-set (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-env-by-var (ssa-zero-vec (+ (+ max-frame max-phis) 2)))
      (set! ssa-env-current (ssa-zero-vec (+ max-frame 2)))
      (set! ssa-env-present (ssa-zero-vec (+ max-frame 2)))
      (set!
        ssa-chg-slot
        (ssa-zero-vec (+ (+ (+ max-instrs max-phis) max-frame) 2)))
      (set!
        ssa-chg-val
        (ssa-zero-vec (+ (+ (+ max-instrs max-phis) max-frame) 2)))
      (set!
        ssa-chg-present
        (ssa-zero-vec (+ (+ (+ max-instrs max-phis) max-frame) 2)))
      (set! ssa-w-id (ssa-zero-vec (+ (* 2 max-blocks) 2)))
      (set! ssa-w-exit (ssa-zero-vec (+ (* 2 max-blocks) 2)))
      (set! ssa-w-chk (ssa-zero-vec (+ (* 2 max-blocks) 2)))
      (set! ssa-child-head (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-child-link (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-rb-label (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-rb-base (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-rb-len (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-rn (ssa-zero-vec (+ max-span 2)))
      (set! ssa-out-label (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-out-entry (ssa-zero-vec (+ max-blocks 2)))
      (set!
        ssa-out-cur
        (ssa-zero-vec (+ (* (+ max-blocks 1) ssa-out-stride) 1)))
      (set!
        ssa-out-pres
        (ssa-zero-vec (+ (* (+ max-blocks 1) ssa-out-stride) 1)))
      (set!
        ssa-mt
        (ssa-zero-vec (+ (+ max-span (* max-phis (+ 4 (* 2 max-edges)))) 2)))
      (set! ssa-mt-base (ssa-zero-vec (+ max-blocks 2)))
      (set! ssa-mt-len (ssa-zero-vec (+ max-blocks 2)))
      (set!
        ssa-def-blk
        (ssa-zero-vec (+ (+ (+ max-frame max-phis) max-instrs) 2)))
      (set!
        ssa-def-pos
        (ssa-zero-vec (+ (+ (+ max-frame max-phis) max-instrs) 2)))
      (set!
        ssa-def-seen
        (ssa-zero-vec (+ (+ (+ max-frame max-phis) max-instrs) 2)))
      (while (< round rounds)
        (let
          [step : i64 0]
          [index : i64 0]
          (begin
            (set! acc (ssa-mix acc round))
            (while (< step functions)
              (begin
                (set! index (+ start step))
                (when (>= index functions) (set! index (- index functions)))
                (ssa-load-function (ssa-ref ssa-offsets index))
                (set! acc (ssa-mix acc (ssa-function)))
                (set! step (+ step 1))))
            (set! start (+ start 1))
            (when (>= start functions) (set! start 0))
            (set! round (+ round 1)))))
      acc)))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.println "{}" (ssa-bench path rounds))
      0)))