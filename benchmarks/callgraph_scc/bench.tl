;# benchmarks/callgraph_scc/bench.tl - the inliner's whole-program tables.
;#
;# Equivalent to benchmarks/callgraph_scc/baseline.c. The kernel is the
;# TypeLisp optimizer's own whole-program inline preparation - the dense
;# function index, the cons-list call graph, the loop-depth-weighted reference
;# census and the iterative Tarjan SCC solve - run over real programs the
;# compiler produced while compiling itself (see README.md for the corpus and
;# its regeneration command).
;#
;# Mirrored compiler functions, all in src/compiler_optimize.tl:
;#   opt-function-index-capacity / -build / -fill-from / -slot / -slot-id
;#                              -- name-id -> dense slot in an opt_i64_i64_map,
;#                                 sized `count < 4 ? 8 : count * 2` rounded up
;#                                 to a power of two
;#   opt-slot-list-contains? / -add / -count
;#                              -- the OptSlotList cons list: an O(n) membership
;#                                 walk then a prepend, and the O(n) length walk
;#   opt-callgraph-init-edges / -add-callee / -instr / -instr-seq / -blocks /
;#   -callees / -build-slots / -build / -callee-count
;#                              -- one adjacency list per function slot
;#   opt-inline-census-depth-weight / -depth-clear! / -depth-edge! /
;#   -depth-ranges! / -depth-prefix! / -depths-build! / -depth-at
;#                              -- the block-order loop-depth estimate: back
;#                                 edges coalesced to the furthest latch per
;#                                 header, a descending pass to a difference
;#                                 sequence, a prefix sum, and 8^min(depth, 2)
;#   opt-inline-census-bump-map / -add-ref / -add-address / -value / -instr /
;#   -instr-seq / -blocks / -function / -function-seq-from / -build
;#                              -- three i64 -> i64 maps keyed by slot
;#   opt-inline-census-refcount / -hot-refcount / -address-taken? /
;#   -absorb-class, opt-inline-dup-max-refcount
;#                              -- the readers every inline site queries
;#   opt-scc-set-low-min! / -next-child-from / -next-child / -discover! /
;#   -frame-push! / -pop-component! / -copy-order / opt-scc-compute
;#                              -- iterative Tarjan with an explicit frame
;#                                 stack, whose next child is found by scanning
;#                                 the whole cons list every step
;#   stdlib/hashmap.tl generated i64 -> i64 map (round-capacity,
;#   growth-limit-for, with-capacity, clear-ref!, probe, insert-ref!, get,
;#   contains?, needs-grow?, grow!)
;#                              -- the exact policy of opt_i64_i64_map
;#
;# Kept: every algorithm above. The cons list is an index-linked node pool
;# (the compiler boxes each cell into the optimizer arena; the pool IS that
;# arena, and a round resets its bump cursor exactly as an arena rewind does).
;# The two multi-value returns opt-scc-discover! and opt-scc-pop-component!
;# make are single-variant enums here, as they are in the compiler.
;#
;# Dropped, and why none of it changes what is measured:
;#   * the ~50-arm operand walk of opt-inline-census-instr over instructions
;#     that hold no callee name and no function value. Every one of those arms
;#     is pure structural recursion that reaches opt-inline-census-value and
;#     falls through its `_` case; the corpus carries the references the
;#     counting arms actually produce, in the order they produce them.
;#   * the block label hash table (opt-cfg-label-table-put! / -get) that
;#     opt-inline-census-depths-build! uses to turn a label into a block index.
;#     The corpus already carries dense block-order indices, which is exactly
;#     what that table computes; benchmarks/cfg_domloops drops it for the same
;#     reason. The `(>= id 0)` guard the lookup feeds is kept.
;#   * opt-function-index-fill-from's `leaf-starts` (opt-symbol-leaf-start over
;#     the name text) and its `values` array. Neither is read by any function
;#     mirrored here, and the corpus is name-text free by construction.
;#   * the `string.eq (compiler-ir-symbol-text name) "main"` disqualifier in
;#     opt-inline-census-absorb-class: no function in any of the ten dumps is
;#     named `main`, so the test is constant-false over this corpus.
;#   * opt-scc-copy-order allocates its result; here it copies into a scratch
;#     array reserved once at the corpus maximum, as rule 5 requires.
;#
;# The corpus path and the round count are runtime arguments, so nothing can be
;# constant folded. A round rebuilds all four tables for one program and the
;# programs rotate, and inside a round the fold's starting slot advances by one,
;# so no round repeats an earlier round's accumulator. Two structural
;# quantities the exporter computed independently - the deduplicated call-graph
;# edge count and the SCC count - are checked against the kernel's own result
;# every round and folded into the checksum. The checksum is a wrapping 64-bit
;# FNV-1a fold with no division, so the printed decimal matches the C
;# baseline's `%lld` bit for bit.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

(define cg-hash-basis : i64
  1469598103934665603)
(define cg-hash-prime : i64
  1099511628211)

;; opt-scc-discover! reports (next index, node stack length) and
;; opt-scc-pop-component! reports (node stack length, member count) through a
;; single-variant payload enum. Both are kept in that shape here.
(defenum CgSccDiscoverState
  (State i64 i64))

(defenum CgSccPopState
  (State i64 i64))

;; Parsed corpus tokens plus the directories the round driver indexes. Module
;; globals keep the pass functions parameterless, matching how the compiler
;; threads one workspace through the inline stage.
(define cg-tokens : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

;; Program directory.
(define cg-program-count : i64
  0)
(define cg-program-base : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-program-funcs : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-program-edges : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-program-sccs : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

;; Function directory, flattened across programs.
(define cg-func-name : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-func-blocks : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-func-edge-off : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-func-edges : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-func-ref-off : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-func-refs : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

;; The four opt_i64_i64_map instances, as stdlib/hashmap.tl lays them out: one
;; interleaved slot array of (state, key, value) triples per map, plus a
;; four-word descriptor (base, capacity, len, growth-limit). State 0 is Empty,
;; 1 is Tombstone, 2 is Occupied.
(define cg-map-slots : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-map-desc : (__tl_dyn-array i64)
  (__tl_make-array i64 16))
(define cg-map-scratch-key : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-map-scratch-val : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

;; OptCallGraph: one OptSlotList head per slot over an index-linked node pool.
(define cg-graph-head : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-graph-count : i64
  0)
(define cg-node-slot : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-node-next : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-node-len : i64
  0)

;; opt-inline-census depth scratch and the current block's site weight.
(define cg-depth-slots : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-depth-count : i64
  0)
(define cg-depth-active? : bool
  false)
(define cg-site-weight : i64
  1)

;; opt-scc-compute workspace.
(define cg-scc-indices : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-scc-lowlink : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-scc-on-stack : (__tl_dyn-array bool)
  (__tl_make-array bool 1))
(define cg-scc-of : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-scc-node-stack : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-scc-frame-slots : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-scc-frame-nexts : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-scc-order-scratch : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-scc-order : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define cg-scc-count : i64
  0)

(define (cg-mix [hash : i64] [value : i64]) : i64
  (* (bit-xor hash value) cg-hash-prime))

(define (cg-byte-at [text : (& text str)] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (cg-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

;; Whitespace-separated decimal integers, with `#` starting a comment that runs
;; to the end of its line.
(define (cg-scan-ints [text : (& text str)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [byte : i64 (cg-byte-at text n i)]
          (cond
            [(= byte 35)
              (while (and (< i n) (not (= (cg-byte-at text n i) 10)))
                (set! i (+ i 1)))]
            [(or (cg-digit? byte) (= byte 45))
              (let
                [negative : bool (= byte 45)]
                [value : i64 0]
                (begin
                  (when negative (set! i (+ i 1)))
                  (while (cg-digit? (cg-byte-at text n i))
                    (begin
                      (set! value (+ (* value 10) (- (cg-byte-at text n i) 48)))
                      (set! i (+ i 1))))
                  (set!
                    (array-ref cg-tokens count)
                    (if negative
                      (- 0 value)
                      value))
                  (set! count (+ count 1))))]
            [else (set! i (+ i 1))])))
      count)))

;; --- stdlib/hashmap.tl generated i64 -> i64 map -----------------------------
;; Map ids: 0 = OptFunctionNameIndex.ids, 1 = refcount, 2 = addrtaken,
;; 3 = hotcount.
(define (cg-map-base [m : i64]) : i64
  (array-ref cg-map-desc (* m 4)))

(define (cg-map-capacity [m : i64]) : i64
  (array-ref cg-map-desc (+ (* m 4) 1)))

(define (cg-map-len [m : i64]) : i64
  (array-ref cg-map-desc (+ (* m 4) 2)))

(define (cg-map-limit [m : i64]) : i64
  (array-ref cg-map-desc (+ (* m 4) 3)))

(define (cg-map-set-capacity! [m : i64] [value : i64]) : unit
  (set! (array-ref cg-map-desc (+ (* m 4) 1)) value))

(define (cg-map-set-len! [m : i64] [value : i64]) : unit
  (set! (array-ref cg-map-desc (+ (* m 4) 2)) value))

(define (cg-map-set-limit! [m : i64] [value : i64]) : unit
  (set! (array-ref cg-map-desc (+ (* m 4) 3)) value))

;; `round-capacity`: the next power of two at or above a positive request.
(define (cg-map-round-capacity [capacity : i64]) : i64
  (if (and (>= capacity 1) (= (bit-and capacity (- capacity 1)) 0))
    capacity
    (let
      [rounded : i64 1]
      (begin
        (while (< rounded capacity)
          (set! rounded (* rounded 2)))
        rounded))))

;; `growth-limit-for` for the scalar family: three quarters of the capacity.
(define (cg-map-growth-limit-for [capacity : i64]) : i64
  (- capacity (shr capacity 2)))

;; `clear-ref!`: every slot back to Empty, len 0, the cached limit restored.
;; A round re-initialises the maps rather than allocating new ones, which is
;; what `with-capacity`'s zeroed slot array costs the compiler per compile.
(define (cg-map-clear! [m : i64]) : unit
  (let
    [base : i64 (cg-map-base m)]
    [cap : i64 (cg-map-capacity m)]
    [index : i64 0]
    (begin
      (while (< index cap)
        (begin
          (set! (array-ref cg-map-slots (+ base (* index 3))) 0)
          (set! index (+ index 1))))
      (cg-map-set-len! m 0)
      (cg-map-set-limit! m (cg-map-growth-limit-for cap)))))

;; `with-capacity`, reusing the reserved region instead of allocating.
(define (cg-map-with-capacity! [m : i64] [capacity : i64]) : unit
  (begin
    (cg-map-set-capacity!
      m
      (cg-map-round-capacity
        (if (< capacity 1)
          1
          capacity)))
    (cg-map-clear! m)))

;; `probe`: linear probing over a power-of-two capacity, reusing the first
;; tombstone for an absent key. A non-negative result is the occupied slot
;; index; `-(index + 2)` is the slot an insert would take.
(define (cg-map-probe [m : i64] [key : i64]) : i64
  (let
    [base : i64 (cg-map-base m)]
    [cap : i64 (cg-map-capacity m)]
    [mask : i64 (- cap 1)]
    [cursor : i64 (bit-and (* key 6364136223846793005) mask)]
    [walked : i64 0]
    [first : i64 -1]
    [found : i64 -1]
    [done : bool false]
    (begin
      (while (and (< walked cap) (not done))
        (let
          [state : i64 (array-ref cg-map-slots (+ base (* cursor 3)))]
          (cond
            [(= state 2)
              (if (= (array-ref cg-map-slots (+ base (+ (* cursor 3) 1))) key)
                (begin
                  (set! found cursor)
                  (set! done true))
                (begin
                  (set! cursor (bit-and (+ cursor 1) mask))
                  (set! walked (+ walked 1))))]
            [(= state 0)
              (begin
                (set!
                  found
                  (-
                    0
                    (+
                      2
                      (if (>= first 0)
                        first
                        cursor))))
                (set! done true))]
            [else
              (begin
                (when (< first 0) (set! first cursor))
                (set! cursor (bit-and (+ cursor 1) mask))
                (set! walked (+ walked 1)))])))
      (if done
        found
        (if (>= first 0)
          (- 0 (+ 2 first))
          -1)))))

;; `needs-grow?`: the cached `len + deleted` threshold.
(define (cg-map-needs-grow? [m : i64]) : bool
  (>= (cg-map-len m) (cg-map-limit m)))

;; `grow!`: double the capacity and rehash every occupied slot. The census and
;; index maps hold at most one entry per function while their capacity is at
;; least twice the function count, so this never fires on this corpus; it is
;; kept because `needs-grow?` is on the insert path and the compiler's map
;; carries it.
(define (cg-map-grow! [m : i64]) : unit
  (let
    [base : i64 (cg-map-base m)]
    [old-cap : i64 (cg-map-capacity m)]
    [live : i64 0]
    [index : i64 0]
    (begin
      (while (< index old-cap)
        (begin
          (when
            (= (array-ref cg-map-slots (+ base (* index 3))) 2)
            (begin
              (set!
                (array-ref cg-map-scratch-key live)
                (array-ref cg-map-slots (+ base (+ (* index 3) 1))))
              (set!
                (array-ref cg-map-scratch-val live)
                (array-ref cg-map-slots (+ base (+ (* index 3) 2))))
              (set! live (+ live 1))))
          (set! index (+ index 1))))
      (cg-map-set-capacity! m (* old-cap 2))
      (cg-map-clear! m)
      (let
        [cap : i64 (cg-map-capacity m)]
        [mask : i64 (- cap 1)]
        [item : i64 0]
        (while (< item live)
          (let
            [key : i64 (array-ref cg-map-scratch-key item)]
            [cursor : i64 (bit-and (* key 6364136223846793005) mask)]
            (begin
              (while (= (array-ref cg-map-slots (+ base (* cursor 3))) 2)
                (set! cursor (bit-and (+ cursor 1) mask)))
              (set! (array-ref cg-map-slots (+ base (* cursor 3))) 2)
              (set! (array-ref cg-map-slots (+ base (+ (* cursor 3) 1))) key)
              (set!
                (array-ref cg-map-slots (+ base (+ (* cursor 3) 2)))
                (array-ref cg-map-scratch-val item))
              (cg-map-set-len! m (+ (cg-map-len m) 1))
              (set! item (+ item 1)))))))))

;; `insert-ref!`: the grow test runs once before the probe, and reusing a
;; tombstone gives the cached limit its slot back.
(define (cg-map-insert-ref! [m : i64] [key : i64] [value : i64]) : unit
  (begin
    (when (cg-map-needs-grow? m) (cg-map-grow! m))
    (let
      [base : i64 (cg-map-base m)]
      [slot : i64 (cg-map-probe m key)]
      (if (>= slot 0)
        (set! (array-ref cg-map-slots (+ base (+ (* slot 3) 2))) value)
        (let
          [index : i64 (- (- 0 slot) 2)]
          (begin
            (when
              (= (array-ref cg-map-slots (+ base (* index 3))) 1)
              (cg-map-set-limit! m (+ (cg-map-limit m) 1)))
            (set! (array-ref cg-map-slots (+ base (* index 3))) 2)
            (set! (array-ref cg-map-slots (+ base (+ (* index 3) 1))) key)
            (set! (array-ref cg-map-slots (+ base (+ (* index 3) 2))) value)
            (cg-map-set-len! m (+ (cg-map-len m) 1))))))))

;; `get` / `get-value-or`.
(define (cg-map-get-value-or [m : i64] [key : i64] [fallback : i64]) : i64
  (let
    [slot : i64 (cg-map-probe m key)]
    (if (>= slot 0)
      (array-ref cg-map-slots (+ (cg-map-base m) (+ (* slot 3) 2)))
      fallback)))

;; `contains?`.
(define (cg-map-contains? [m : i64] [key : i64]) : bool
  (>= (cg-map-probe m key) 0))

;; --- opt-function-index -----------------------------------------------------
(define (cg-function-index-capacity [count : i64]) : i64
  (if (< count 4)
    8
    (* count 2)))

;; opt-function-index-fill-from: slot `index` claims the function at `index`,
;; and its name id maps to that slot.
(define (cg-function-index-fill-from! [base : i64] [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (cg-map-insert-ref! 0 (array-ref cg-func-name (+ base index)) index)
        (set! index (+ index 1))))))

(define (cg-function-index-build! [base : i64] [count : i64]) : unit
  (begin
    (cg-map-with-capacity! 0 (cg-function-index-capacity count))
    (cg-function-index-fill-from! base count)))

;; opt-function-index-slot-id: a negative name id is "no symbol". -1 is None.
(define (cg-function-index-slot-id [name-id : i64]) : i64
  (if (< name-id 0)
    -1
    (cg-map-get-value-or 0 name-id -1)))

;; --- OptSlotList ------------------------------------------------------------
;; `-1` is Nil; any other head is a node-pool index. The compiler boxes each
;; Cons cell into the optimizer arena, so the pool's bump cursor is that arena.
(define (cg-slot-list-contains? [slots : i64] [slot : i64]) : bool
  (if (< slots 0)
    false
    (if (= (array-ref cg-node-slot slots) slot)
      true
      (cg-slot-list-contains? (array-ref cg-node-next slots) slot))))

(define (cg-slot-list-add [slots : i64] [slot : i64]) : i64
  (if (cg-slot-list-contains? slots slot)
    slots
    (let
      [node : i64 cg-node-len]
      (begin
        (set! (array-ref cg-node-slot node) slot)
        (set! (array-ref cg-node-next node) slots)
        (set! cg-node-len (+ node 1))
        node))))

(define (cg-slot-list-count [slots : i64]) : i64
  (if (< slots 0)
    0
    (+ 1 (cg-slot-list-count (array-ref cg-node-next slots)))))

;; --- opt-callgraph ----------------------------------------------------------
(define (cg-callgraph-add-callee [callees : i64] [name-id : i64]) : i64
  (let
    [slot : i64 (cg-function-index-slot-id name-id)]
    (if (>= slot 0)
      (cg-slot-list-add callees slot)
      callees)))

;; opt-callgraph-instr over one function's references: only a Call, TailCall,
;; CallCAbiStoreResult or SpmdCall callee (kind 0) becomes an edge.
(define (cg-callgraph-callees [func : i64]) : i64
  (let
    [cursor : i64 (array-ref cg-func-ref-off func)]
    [end : i64
      (+ (array-ref cg-func-ref-off func) (* (array-ref cg-func-refs func) 3))]
    [callees : i64 -1]
    (begin
      (while (< cursor end)
        (begin
          (when
            (= (array-ref cg-tokens (+ cursor 2)) 0)
            (set!
              callees
              (cg-callgraph-add-callee
                callees
                (array-ref cg-tokens (+ cursor 1)))))
          (set! cursor (+ cursor 3))))
      callees)))

(define (cg-callgraph-init-edges! [count : i64]) : unit
  (let
    [slot : i64 0]
    (while (< slot count)
      (begin
        (set! (array-ref cg-graph-head slot) -1)
        (set! slot (+ slot 1))))))

(define (cg-callgraph-build-slots! [base : i64] [count : i64]) : unit
  (let
    [slot : i64 0]
    (while (< slot count)
      (begin
        (set!
          (array-ref cg-graph-head slot)
          (cg-callgraph-callees (+ base slot)))
        (set! slot (+ slot 1))))))

(define (cg-callgraph-build! [base : i64] [count : i64]) : unit
  (begin
    (set! cg-node-len 0)
    (set! cg-graph-count count)
    (cg-callgraph-init-edges! count)
    (cg-callgraph-build-slots! base count)))

(define (cg-callgraph-callee-count [from-slot : i64]) : i64
  (if (or (< from-slot 0) (>= from-slot cg-graph-count))
    -1
    (cg-slot-list-count (array-ref cg-graph-head from-slot))))

;; --- opt-inline-census: the block-order loop-depth estimate -----------------
(define (cg-census-depth-base) : i64
  8)

(define (cg-census-depth-cap) : i64
  2)

(define (cg-census-depth-weight [depth : i64]) : i64
  (let
    [capped : i64
      (if (> depth (cg-census-depth-cap))
        (cg-census-depth-cap)
        depth)]
    [weight : i64 1]
    [level : i64 0]
    (begin
      (while (< level capped)
        (begin
          (set! weight (* weight (cg-census-depth-base)))
          (set! level (+ level 1))))
      weight)))

(define (cg-census-depth-clear! [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (set! (array-ref cg-depth-slots i) 0)
        (set! i (+ i 1))))))

;; One edge. Only a target at or before the source opens a loop; the furthest
;; latch wins so several back edges into one header stay one nesting level.
;; `target` is the dense block index the label table would have returned.
(define (cg-census-depth-edge! [target : i64] [source : i64]) : bool
  (let
    [id : i64 target]
    (if (and (>= id 0) (<= id source))
      (let
        [end : i64 (+ source 1)]
        [previous : i64 (array-ref cg-depth-slots id)]
        (begin
          (when (> end previous) (set! (array-ref cg-depth-slots id) end))
          true))
      false)))

(define (cg-census-depth-prefix! [count : i64]) : unit
  (let
    [i : i64 1]
    (while (< i count)
      (begin
        (set!
          (array-ref cg-depth-slots i)
          (+ (array-ref cg-depth-slots i) (array-ref cg-depth-slots (- i 1))))
        (set! i (+ i 1))))))

;; Header -> furthest-latch records become range deltas. Descending order lets
;; this reuse the same array.
(define (cg-census-depth-ranges! [count : i64]) : unit
  (let
    [i : i64 (- count 1)]
    (while (>= i 0)
      (let
        [end : i64 (array-ref cg-depth-slots i)]
        (begin
          (set! (array-ref cg-depth-slots i) 0)
          (when
            (> end i)
            (begin
              (set!
                (array-ref cg-depth-slots i)
                (+ (array-ref cg-depth-slots i) 1))
              (set!
                (array-ref cg-depth-slots end)
                (- (array-ref cg-depth-slots end) 1))))
          (set! i (- i 1)))))))

;; opt-inline-census-depth-mark! over one function's terminator edges, in block
;; order. A body with no back edge leaves the estimate inactive.
(define (cg-census-depths-build! [func : i64]) : unit
  (let
    [count : i64 (array-ref cg-func-blocks func)]
    (begin
      (set! cg-depth-active? false)
      (set! cg-depth-count 0)
      (set! cg-site-weight 1)
      (when
        (>= count 2)
        (let
          [cursor : i64 (array-ref cg-func-edge-off func)]
          [end : i64
            (+
              (array-ref cg-func-edge-off func)
              (* (array-ref cg-func-edges func) 2))]
          [found : bool false]
          (begin
            (cg-census-depth-clear! (+ count 1))
            (while (< cursor end)
              (begin
                (when
                  (cg-census-depth-edge!
                    (array-ref cg-tokens (+ cursor 1))
                    (array-ref cg-tokens cursor))
                  (set! found true))
                (set! cursor (+ cursor 2))))
            (when
              found
              (begin
                (cg-census-depth-ranges! count)
                (cg-census-depth-prefix! count)
                (set! cg-depth-count count)
                (set! cg-depth-active? true)))))))))

(define (cg-census-depth-at [position : i64]) : i64
  (if (and cg-depth-active? (< position cg-depth-count))
    (array-ref cg-depth-slots position)
    0))

;; --- opt-inline-census: the three counters ----------------------------------
(define (cg-census-bump-map [m : i64] [slot : i64] [amount : i64]) : unit
  (let
    [count : i64 (cg-map-get-value-or m slot -1)]
    (if (>= count 0)
      (cg-map-insert-ref! m slot (+ count amount))
      (cg-map-insert-ref! m slot amount))))

(define (cg-census-add-ref [name-id : i64]) : unit
  (let
    [slot : i64 (cg-function-index-slot-id name-id)]
    (when
      (>= slot 0)
      (begin
        (cg-census-bump-map 1 slot 1)
        (cg-census-bump-map 3 slot cg-site-weight)))))

(define (cg-census-add-address [name-id : i64]) : unit
  (let
    [slot : i64 (cg-function-index-slot-id name-id)]
    (when (>= slot 0) (cg-map-insert-ref! 2 slot 1))))

;; opt-inline-census-blocks: every block installs its own site weight before
;; its instructions are walked, whether or not it holds a reference.
(define (cg-census-blocks [func : i64]) : unit
  (let
    [blocks : i64 (array-ref cg-func-blocks func)]
    [cursor : i64 (array-ref cg-func-ref-off func)]
    [end : i64
      (+ (array-ref cg-func-ref-off func) (* (array-ref cg-func-refs func) 3))]
    [position : i64 0]
    (while (< position blocks)
      (begin
        (set!
          cg-site-weight
          (cg-census-depth-weight (cg-census-depth-at position)))
        (while (and (< cursor end) (= (array-ref cg-tokens cursor) position))
          (begin
            (if (= (array-ref cg-tokens (+ cursor 2)) 0)
              (cg-census-add-ref (array-ref cg-tokens (+ cursor 1)))
              (cg-census-add-address (array-ref cg-tokens (+ cursor 1))))
            (set! cursor (+ cursor 3))))
        (set! position (+ position 1))))))

(define (cg-census-function [func : i64]) : unit
  (begin
    (cg-census-depths-build! func)
    (cg-census-blocks func)))

(define (cg-census-build! [base : i64] [count : i64]) : unit
  (let
    [capacity : i64 (cg-function-index-capacity count)]
    [position : i64 0]
    (begin
      (cg-map-with-capacity! 1 capacity)
      (cg-map-with-capacity! 2 capacity)
      (cg-map-with-capacity! 3 capacity)
      (while (< position count)
        (begin
          (cg-census-function (+ base position))
          (set! position (+ position 1)))))))

(define (cg-census-refcount [name-id : i64]) : i64
  (let
    [slot : i64 (cg-function-index-slot-id name-id)]
    (if (>= slot 0)
      (cg-map-get-value-or 1 slot 0)
      0)))

(define (cg-census-hot-refcount [name-id : i64]) : i64
  (let
    [slot : i64 (cg-function-index-slot-id name-id)]
    (if (>= slot 0)
      (cg-map-get-value-or 3 slot 0)
      0)))

(define (cg-census-address-taken? [name-id : i64]) : bool
  (let
    [slot : i64 (cg-function-index-slot-id name-id)]
    (if (>= slot 0)
      (cg-map-contains? 2 slot)
      false)))

(define (cg-inline-dup-max-refcount) : i64
  2)

;; opt-inline-census-absorb-class, minus the `main` name test the corpus cannot
;; trigger.
(define (cg-census-absorb-class [caller-name : i64] [callee-name : i64]) : i64
  (let
    [refs : i64 (cg-census-refcount callee-name)]
    (if (or
      (< refs 1)
      (> refs (cg-inline-dup-max-refcount))
      (= caller-name callee-name)
      (cg-census-address-taken? callee-name))
      0
      refs)))

;; --- opt-scc-compute --------------------------------------------------------
(define (cg-scc-set-low-min! [slot : i64] [candidate : i64]) : unit
  (let
    [old : i64 (array-ref cg-scc-lowlink slot)]
    (when (< candidate old) (set! (array-ref cg-scc-lowlink slot) candidate))))

;; The NEXT child is the smallest slot greater than `after`, found by scanning
;; the whole cons list every step. That quadratic walk is the compiler's real
;; cost and is kept.
(define (cg-scc-next-child-from [slots : i64] [after : i64] [best : i64]) : i64
  (if (< slots 0)
    best
    (let
      [slot : i64 (array-ref cg-node-slot slots)]
      (cg-scc-next-child-from
        (array-ref cg-node-next slots)
        after
        (if (and (> slot after) (or (< best 0) (< slot best)))
          slot
          best)))))

(define (cg-scc-next-child [slot : i64] [after : i64]) : i64
  (if (or (< slot 0) (>= slot cg-graph-count))
    (- 0 1)
    (cg-scc-next-child-from (array-ref cg-graph-head slot) after (- 0 1))))

(define (cg-scc-discover!
  [slot : i64]
  [node-stack-len : i64]
  [next-index : i64]) : CgSccDiscoverState
  (begin
    (set! (array-ref cg-scc-indices slot) next-index)
    (set! (array-ref cg-scc-lowlink slot) next-index)
    (set! (array-ref cg-scc-on-stack slot) true)
    (set! (array-ref cg-scc-node-stack node-stack-len) slot)
    (CgSccDiscoverState.State (+ next-index 1) (+ node-stack-len 1))))

(define (cg-scc-frame-push! [frame-len : i64] [slot : i64]) : i64
  (begin
    (set! (array-ref cg-scc-frame-slots frame-len) slot)
    (set! (array-ref cg-scc-frame-nexts frame-len) (- 0 1))
    (+ frame-len 1)))

(define (cg-scc-pop-component!
  [node-stack-len : i64]
  [root : i64]
  [scc-id : i64]) : CgSccPopState
  (let
    [len : i64 node-stack-len]
    [done : bool false]
    [members : i64 0]
    (begin
      (while (not done)
        (let
          [next-len : i64 (- len 1)]
          [slot : i64 (array-ref cg-scc-node-stack next-len)]
          (begin
            (set! len next-len)
            (set! (array-ref cg-scc-on-stack slot) false)
            (set! (array-ref cg-scc-of slot) scc-id)
            (set! members (+ members 1))
            (when (= slot root) (set! done true)))))
      (CgSccPopState.State len members))))

(define (cg-scc-copy-order [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set!
          (array-ref cg-scc-order index)
          (array-ref cg-scc-order-scratch index))
        (set! index (+ index 1))))))

;; opt-cfg-fill-i64!, the pre-pass opt-scc-compute runs over four of its arrays.
(define (cg-scc-fill-i64!
  [target : (&mut target (__tl_dyn-array i64))]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref target index) (- 0 1))
        (set! index (+ index 1))))))

(define (cg-scc-compute! [count : i64]) : unit
  (let
    [root : i64 0]
    [next-index : i64 0]
    [node-stack-len : i64 0]
    [frame-len : i64 0]
    [scc-count : i64 0]
    (begin
      (cg-scc-fill-i64! (&mut cg-scc-indices) count)
      (cg-scc-fill-i64! (&mut cg-scc-lowlink) count)
      (cg-scc-fill-i64! (&mut cg-scc-of) count)
      (cg-scc-fill-i64! (&mut cg-scc-order-scratch) count)
      (let
        [i : i64 0]
        (while (< i count)
          (begin
            (set! (array-ref cg-scc-on-stack i) false)
            (set! i (+ i 1)))))
      (while (< root count)
        (begin
          (when
            (= (array-ref cg-scc-indices root) (- 0 1))
            (begin
              (match (cg-scc-discover! root node-stack-len next-index)
                [(CgSccDiscoverState.State next stack-len)
                  (begin
                    (set! next-index next)
                    (set! node-stack-len stack-len))])
              (set! frame-len (cg-scc-frame-push! frame-len root))
              (while (> frame-len 0)
                (let
                  [frame-index : i64 (- frame-len 1)]
                  [slot : i64 (array-ref cg-scc-frame-slots frame-index)]
                  [child : i64
                    (cg-scc-next-child
                      slot
                      (array-ref cg-scc-frame-nexts frame-index))]
                  (if (>= child 0)
                    (begin
                      (set! (array-ref cg-scc-frame-nexts frame-index) child)
                      (if (= (array-ref cg-scc-indices child) (- 0 1))
                        (begin
                          (match (cg-scc-discover!
                            child
                            node-stack-len
                            next-index)
                            [(CgSccDiscoverState.State next stack-len)
                              (begin
                                (set! next-index next)
                                (set! node-stack-len stack-len))])
                          (set! frame-len (cg-scc-frame-push! frame-len child)))
                        (when
                          (array-ref cg-scc-on-stack child)
                          (cg-scc-set-low-min!
                            slot
                            (array-ref cg-scc-indices child)))))
                    (begin
                      (when
                        (=
                          (array-ref cg-scc-lowlink slot)
                          (array-ref cg-scc-indices slot))
                        (match (cg-scc-pop-component!
                          node-stack-len
                          slot
                          scc-count)
                          [(CgSccPopState.State stack-len _)
                            (begin
                              (set! node-stack-len stack-len)
                              (set!
                                (array-ref cg-scc-order-scratch scc-count)
                                scc-count)
                              (set! scc-count (+ scc-count 1)))]))
                      (set! frame-len (- frame-len 1))
                      (when
                        (> frame-len 0)
                        (cg-scc-set-low-min!
                          (array-ref cg-scc-frame-slots (- frame-len 1))
                          (array-ref cg-scc-lowlink slot)))))))))
          (set! root (+ root 1))))
      (set! cg-scc-count scc-count)
      (cg-scc-copy-order scc-count))))

;; --- fold and self-check ----------------------------------------------------
;; The deduplicated call-graph edge total this round's `opt-slot-list-add`
;; filter produced, accumulated by the fold's per-slot callee count.
(define cg-fold-edges : i64
  0)

;; Everything an inline site reads back, once per slot: the SCC id and the
;; bottom-up order, the callee count, the raw and loop-weighted reference
;; counts, and the absorb class of this slot's name seen from its successor's.
(define (cg-program-fold [base : i64] [count : i64] [start : i64] [seed : i64]) : i64
  (let
    [hash : i64 seed]
    [edges : i64 0]
    [step : i64 0]
    [index : i64 0]
    (begin
      (while (< step count)
        (let
          [slot : i64
            (let
              [raw : i64 (+ start step)]
              (if (>= raw count)
                (- raw count)
                raw))]
          [name : i64 (array-ref cg-func-name (+ base slot))]
          [caller : i64
            (array-ref
              cg-func-name
              (+
                base
                (if (>= (+ slot 1) count)
                  0
                  (+ slot 1))))]
          [callees : i64 (cg-callgraph-callee-count slot)]
          (begin
            (set! edges (+ edges callees))
            (set! hash (cg-mix hash (array-ref cg-scc-of slot)))
            (set! hash (cg-mix hash callees))
            (set! hash (cg-mix hash (cg-census-refcount name)))
            (set! hash (cg-mix hash (cg-census-hot-refcount name)))
            (set! hash (cg-mix hash (cg-census-absorb-class caller name)))
            (set! step (+ step 1)))))
      (while (< index cg-scc-count)
        (begin
          (set! hash (cg-mix hash (array-ref cg-scc-order index)))
          (set! index (+ index 1))))
      (set! cg-fold-edges edges)
      (cg-mix hash edges))))

;; Both structural quantities the exporter computed independently, checked
;; against this round's own tables and folded in.
(define (cg-self-check [program : i64]) : i64
  (begin
    (if (= cg-fold-edges (array-ref cg-program-edges program))
      unit
      (io.panic "callgraph_scc: call-graph edge count self-check failed\n"))
    (if (= cg-scc-count (array-ref cg-program-sccs program))
      unit
      (io.panic "callgraph_scc: SCC count self-check failed\n"))
    (cg-mix
      (cg-mix cg-hash-basis (array-ref cg-program-edges program))
      (array-ref cg-program-sccs program))))

(define (cg-bench [path : String] [rounds : i64]) : i64
  (let
    [text : String (byte_buf.to-string (io.read-file path))]
    [capacity : i64 (+ (shr (string.string-length text) 1) 8)]
    [tokens : i64 0]
    [programs : i64 0]
    [total-funcs : i64 0]
    [max-funcs : i64 1]
    [max-blocks : i64 1]
    [max-nodes : i64 1]
    [cursor : i64 0]
    [acc : i64 cg-hash-basis]
    [round : i64 0]
    [program : i64 0]
    [start : i64 0]
    (begin
      (set! cg-tokens (__tl_make-array i64 capacity))
      (set! tokens (cg-scan-ints text))
      (set! acc (cg-mix acc tokens))
      (set! acc (cg-mix acc (array-ref cg-tokens 0)))
      (set! programs (array-ref cg-tokens 1))
      (set! cg-program-count programs)
      (set! cg-program-base (__tl_make-array i64 (+ programs 1)))
      (set! cg-program-funcs (__tl_make-array i64 (+ programs 1)))
      (set! cg-program-edges (__tl_make-array i64 (+ programs 1)))
      (set! cg-program-sccs (__tl_make-array i64 (+ programs 1)))
      (set! cursor 2)
      ;; First pass: count functions so the directories can be sized once.
      (let
        [p : i64 0]
        (while (< p programs)
          (let
            [count : i64 (array-ref cg-tokens cursor)]
            [f : i64 0]
            (begin
              (set! total-funcs (+ total-funcs count))
              (when (> count max-funcs) (set! max-funcs count))
              (set! cursor (+ cursor 3))
              (while (< f count)
                (begin
                  (set!
                    cursor
                    (+
                      cursor
                      (+
                        4
                        (+
                          (* (array-ref cg-tokens (+ cursor 2)) 2)
                          (* (array-ref cg-tokens (+ cursor 3)) 3)))))
                  (set! f (+ f 1))))
              (set! p (+ p 1))))))
      (set! cg-func-name (__tl_make-array i64 (+ total-funcs 1)))
      (set! cg-func-blocks (__tl_make-array i64 (+ total-funcs 1)))
      (set! cg-func-edge-off (__tl_make-array i64 (+ total-funcs 1)))
      (set! cg-func-edges (__tl_make-array i64 (+ total-funcs 1)))
      (set! cg-func-ref-off (__tl_make-array i64 (+ total-funcs 1)))
      (set! cg-func-refs (__tl_make-array i64 (+ total-funcs 1)))
      ;; Second pass: fill the directories.
      (set! cursor 2)
      (let
        [p : i64 0]
        [next-func : i64 0]
        (while (< p programs)
          (let
            [count : i64 (array-ref cg-tokens cursor)]
            [f : i64 0]
            (begin
              (set! (array-ref cg-program-base p) next-func)
              (set! (array-ref cg-program-funcs p) count)
              (set!
                (array-ref cg-program-edges p)
                (array-ref cg-tokens (+ cursor 1)))
              (set!
                (array-ref cg-program-sccs p)
                (array-ref cg-tokens (+ cursor 2)))
              (set! cursor (+ cursor 3))
              (while (< f count)
                (let
                  [blocks : i64 (array-ref cg-tokens (+ cursor 1))]
                  [edges : i64 (array-ref cg-tokens (+ cursor 2))]
                  [refs : i64 (array-ref cg-tokens (+ cursor 3))]
                  (begin
                    (set!
                      (array-ref cg-func-name next-func)
                      (array-ref cg-tokens cursor))
                    (set! (array-ref cg-func-blocks next-func) blocks)
                    (set! (array-ref cg-func-edge-off next-func) (+ cursor 4))
                    (set! (array-ref cg-func-edges next-func) edges)
                    (set!
                      (array-ref cg-func-ref-off next-func)
                      (+ (+ cursor 4) (* edges 2)))
                    (set! (array-ref cg-func-refs next-func) refs)
                    (when (> blocks max-blocks) (set! max-blocks blocks))
                    (set! max-nodes (+ max-nodes refs))
                    (set! cursor (+ (+ (+ cursor 4) (* edges 2)) (* refs 3)))
                    (set! next-func (+ next-func 1))
                    (set! f (+ f 1)))))
              (set! p (+ p 1))))))
      ;; Scratch reserved once at the corpus maximum and reused every round.
      (let
        [cap : i64
          (cg-map-round-capacity (cg-function-index-capacity max-funcs))]
        [i : i64 0]
        (begin
          (set! cg-map-slots (__tl_make-array i64 (* cap 24)))
          (set! cg-map-scratch-key (__tl_make-array i64 (+ cap 1)))
          (set! cg-map-scratch-val (__tl_make-array i64 (+ cap 1)))
          (while (< i 4)
            (begin
              (set! (array-ref cg-map-desc (* i 4)) (* i (* cap 6)))
              (set! i (+ i 1))))))
      (set! cg-graph-head (__tl_make-array i64 (+ max-funcs 1)))
      (set! cg-node-slot (__tl_make-array i64 (+ max-nodes 1)))
      (set! cg-node-next (__tl_make-array i64 (+ max-nodes 1)))
      (set! cg-depth-slots (__tl_make-array i64 (+ max-blocks 2)))
      (set! cg-scc-indices (__tl_make-array i64 (+ max-funcs 1)))
      (set! cg-scc-lowlink (__tl_make-array i64 (+ max-funcs 1)))
      (set! cg-scc-on-stack (__tl_make-array bool (+ max-funcs 1)))
      (set! cg-scc-of (__tl_make-array i64 (+ max-funcs 1)))
      (set! cg-scc-node-stack (__tl_make-array i64 (+ max-funcs 1)))
      (set! cg-scc-frame-slots (__tl_make-array i64 (+ max-funcs 1)))
      (set! cg-scc-frame-nexts (__tl_make-array i64 (+ max-funcs 1)))
      (set! cg-scc-order-scratch (__tl_make-array i64 (+ max-funcs 1)))
      (set! cg-scc-order (__tl_make-array i64 (+ max-funcs 1)))
      ;; A round rebuilds every table for one program; the programs rotate and
      ;; the fold's starting slot advances by one, so no two rounds fold the
      ;; same sequence into the accumulator.
      (while (< round rounds)
        (let
          [base : i64 (array-ref cg-program-base program)]
          [count : i64 (array-ref cg-program-funcs program)]
          (begin
            (when (>= start count) (set! start 0))
            (set! acc (cg-mix acc round))
            (cg-function-index-build! base count)
            (cg-callgraph-build! base count)
            (cg-census-build! base count)
            (cg-scc-compute! count)
            (set! acc (cg-program-fold base count start acc))
            (set! acc (cg-mix acc (cg-self-check program)))
            (set! start (+ start 1))
            (set! program (+ program 1))
            (when (>= program programs) (set! program 0))
            (set! round (+ round 1)))))
      acc)))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.println "{}" (cg-bench path rounds))
      0)))