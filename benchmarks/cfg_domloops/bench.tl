;# benchmarks/cfg_domloops/bench.tl - optimizer CFG context construction.
;#
;# Equivalent to benchmarks/cfg_domloops/baseline.c. The kernel is the TypeLisp
;# optimizer's own per-function CFG analysis, run over real block graphs the
;# compiler produced while compiling itself (see README.md for the corpus and
;# its regeneration command).
;#
;# Mirrored compiler functions, all in src/compiler_optimize.tl:
;#   opt-cfg-index-build        -- dense block ids in block-list order, CSR
;#                                 successor and predecessor rows, DFS
;#                                 postorder, reverse postorder, RPO numbers
;#   opt-cfg-dominators-with    -- Cooper/Harvey/Kennedy iterative immediate
;#                                 dominators: idom[entry] = entry, then repeat
;#                                 an RPO sweep computing each block's idom as
;#                                 the two-finger `opt-dom-intersect-idom` walk
;#                                 over its already-processed predecessors,
;#                                 until a sweep changes nothing (bounded by
;#                                 count + 1 sweeps), followed by
;#                                 `opt-dom-build-euler!`, a DFS over the
;#                                 dominator-tree child CSR stamping tin/tout so
;#                                 `opt-dom-info-dominates-id?` is O(1)
;#   opt-cfg-natural-loops-with-context -- blocks scanned from last to first,
;#                                 each CSR successor row forward; a successor
;#                                 that dominates its source is a loop header,
;#                                 and `opt-natural-loop-build` collects the
;#                                 body by walking predecessors backwards from
;#                                 the latch (never expanding the header) with
;#                                 an id-indexed marks array as the dedup, then
;#                                 `opt-natural-loop-find-preheader` accepts the
;#                                 single outside predecessor whose only
;#                                 successor is the header
;#   opt-cfg-context-build      -- the composition of the three above
;#
;# Kept: every algorithm above, edge for edge. Dropped: the label hash table
;# (the corpus already carries dense ids, which is what `opt-cfg-index-build`
;# computes), the block VALUES (only the graph matters here), and the loop body
;# label list (the checksum folds body sizes). The compiler's recursive DFS
;# postorder and Euler tour are written here with an explicit stack, which
;# visits nodes in exactly the same order.
;#
;# Each loop's body collection clears a whole `count`-entry marks array, which
;# is what `array.make-array bool (opt-cfg-index-block-count index)` costs per
;# natural loop in `opt-natural-loop-build`. That per-function loop-enumeration
;# cost is the one this benchmark exists to track.
;#
;# The corpus path and the round count are runtime arguments, so nothing can be
;# constant folded. Each round rotates the starting function by one, so no round
;# repeats an earlier round's accumulator. The checksum is a wrapping 64-bit
;# FNV-1a fold with no division, so the printed decimal matches the C baseline's
;# `%lld` bit for bit.
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)

(define cfg-hash-basis : i64
  1469598103934665603)
(define cfg-hash-prime : i64
  1099511628211)

;; Parsed corpus tokens and the scratch arrays every per-function pass reuses.
;; Module globals keep the analysis functions parameterless, matching how the
;; compiler threads one workspace through a pass.
(define cfg-tokens : (Array i64)
  (array.make-array i64 1))
(define cfg-offsets : (Array i64)
  (array.make-array i64 1))
(define cfg-succ-off : (Array i64)
  (array.make-array i64 1))
(define cfg-succ-edge : (Array i64)
  (array.make-array i64 1))
(define cfg-succ-fill : (Array i64)
  (array.make-array i64 1))
(define cfg-pred-off : (Array i64)
  (array.make-array i64 1))
(define cfg-pred-edge : (Array i64)
  (array.make-array i64 1))
(define cfg-pred-fill : (Array i64)
  (array.make-array i64 1))
(define cfg-child-off : (Array i64)
  (array.make-array i64 1))
(define cfg-child-edge : (Array i64)
  (array.make-array i64 1))
(define cfg-child-fill : (Array i64)
  (array.make-array i64 1))
(define cfg-reachable : (Array i64)
  (array.make-array i64 1))
(define cfg-postorder : (Array i64)
  (array.make-array i64 1))
(define cfg-rpo : (Array i64)
  (array.make-array i64 1))
(define cfg-rpo-num : (Array i64)
  (array.make-array i64 1))
(define cfg-idom : (Array i64)
  (array.make-array i64 1))
(define cfg-tin : (Array i64)
  (array.make-array i64 1))
(define cfg-tout : (Array i64)
  (array.make-array i64 1))
(define cfg-marks : (Array i64)
  (array.make-array i64 1))
(define cfg-worklist : (Array i64)
  (array.make-array i64 1))
(define cfg-stack-node : (Array i64)
  (array.make-array i64 1))
(define cfg-stack-edge : (Array i64)
  (array.make-array i64 1))

;; Per-function view of the corpus, set by cfg-function before it runs.
(define cfg-blocks : i64
  0)
(define cfg-edges : i64
  0)
(define cfg-edge-base : i64
  0)
(define cfg-reach-count : i64
  0)

(define (cfg-mix [hash : i64] [value : i64]) : i64
  (* (bit-xor hash value) cfg-hash-prime))

(define (cfg-byte-at [text : String] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (cfg-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

;; Whitespace-separated decimal integers, with `#` starting a comment that runs
;; to the end of its line.
(define (cfg-scan-ints [text : String] [out : (Array i64)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [byte : i64 (cfg-byte-at text n i)]
          (cond
            [(= byte 35)
              (while (and (< i n) (not (= (cfg-byte-at text n i) 10)))
                (set! i (+ i 1)))]
            [(or (cfg-digit? byte) (= byte 45))
              (let
                [negative : bool (= byte 45)]
                [value : i64 0]
                (begin
                  (when negative (set! i (+ i 1)))
                  (while (cfg-digit? (cfg-byte-at text n i))
                    (begin
                      (set!
                        value
                        (+ (* value 10) (- (cfg-byte-at text n i) 48)))
                      (set! i (+ i 1))))
                  (array-set!
                    out
                    count
                    (if negative
                      (- 0 value)
                      value))
                  (set! count (+ count 1))))]
            [else (set! i (+ i 1))])))
      count)))

;; opt-cfg-csr-build for both directions. The corpus lists a block's successors
;; in the order `opt-cfg-instr-successors` discovers them, so counting sort
;; reproduces the compiler's successor rows exactly; predecessor rows come out
;; in ascending source order, which is the order `opt-i64-list-add` builds and
;; `opt-cfg-csr-fill-rows!` reverses back.
(define (cfg-build-csr) : unit
  (let
    [count : i64 cfg-blocks]
    [i : i64 0]
    [edge : i64 0]
    [succ-total : i64 0]
    [pred-total : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set! cfg-succ-fill i 0)
          (array-set! cfg-pred-fill i 0)
          (set! i (+ i 1))))
      (set! edge 0)
      (while (< edge cfg-edges)
        (let
          [src : i64 (array-ref cfg-tokens (+ cfg-edge-base (* edge 2)))]
          [dst : i64 (array-ref cfg-tokens (+ (+ cfg-edge-base (* edge 2)) 1))]
          (begin
            (array-set! cfg-succ-fill src (+ (array-ref cfg-succ-fill src) 1))
            (array-set! cfg-pred-fill dst (+ (array-ref cfg-pred-fill dst) 1))
            (set! edge (+ edge 1)))))
      (set! i 0)
      (while (< i count)
        (begin
          (array-set! cfg-succ-off i succ-total)
          (set! succ-total (+ succ-total (array-ref cfg-succ-fill i)))
          (array-set! cfg-succ-fill i (array-ref cfg-succ-off i))
          (array-set! cfg-pred-off i pred-total)
          (set! pred-total (+ pred-total (array-ref cfg-pred-fill i)))
          (array-set! cfg-pred-fill i (array-ref cfg-pred-off i))
          (set! i (+ i 1))))
      (array-set! cfg-succ-off count succ-total)
      (array-set! cfg-pred-off count pred-total)
      (set! edge 0)
      (while (< edge cfg-edges)
        (let
          [src : i64 (array-ref cfg-tokens (+ cfg-edge-base (* edge 2)))]
          [dst : i64 (array-ref cfg-tokens (+ (+ cfg-edge-base (* edge 2)) 1))]
          (begin
            (array-set! cfg-succ-edge (array-ref cfg-succ-fill src) dst)
            (array-set! cfg-succ-fill src (+ (array-ref cfg-succ-fill src) 1))
            (array-set! cfg-pred-edge (array-ref cfg-pred-fill dst) src)
            (array-set! cfg-pred-fill dst (+ (array-ref cfg-pred-fill dst) 1))
            (set! edge (+ edge 1))))))))

;; opt-cfg-index-dfs-postorder! written with an explicit stack: mark on entry,
;; append on exit, successors in CSR row order.
(define (cfg-dfs-postorder) : unit
  (let
    [count : i64 cfg-blocks]
    [i : i64 0]
    [sp : i64 0]
    [post : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set! cfg-reachable i 0)
          (array-set! cfg-postorder i -1)
          (array-set! cfg-rpo i -1)
          (array-set! cfg-rpo-num i -1)
          (set! i (+ i 1))))
      (when
        (> count 0)
        (begin
          (array-set! cfg-reachable 0 1)
          (array-set! cfg-stack-node 0 0)
          (array-set! cfg-stack-edge 0 (array-ref cfg-succ-off 0))
          (set! sp 0)
          (while (>= sp 0)
            (let
              [node : i64 (array-ref cfg-stack-node sp)]
              [cursor : i64 (array-ref cfg-stack-edge sp)]
              (if (< cursor (array-ref cfg-succ-off (+ node 1)))
                (let
                  [next : i64 (array-ref cfg-succ-edge cursor)]
                  (begin
                    (array-set! cfg-stack-edge sp (+ cursor 1))
                    (when
                      (= (array-ref cfg-reachable next) 0)
                      (begin
                        (array-set! cfg-reachable next 1)
                        (set! sp (+ sp 1))
                        (array-set! cfg-stack-node sp next)
                        (array-set!
                          cfg-stack-edge
                          sp
                          (array-ref cfg-succ-off next))))))
                (begin
                  (array-set! cfg-postorder post node)
                  (set! post (+ post 1))
                  (set! sp (- sp 1))))))))
      (set! cfg-reach-count post)
      (set! i 0)
      (while (< i post)
        (begin
          (array-set! cfg-rpo i (array-ref cfg-postorder (- (- post 1) i)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i post)
        (begin
          (array-set! cfg-rpo-num (array-ref cfg-rpo i) i)
          (set! i (+ i 1)))))))

;; opt-dom-intersect-idom: walk both fingers up the partial dominator tree until
;; they meet, always advancing the one with the larger RPO number.
(define (cfg-intersect [left : i64] [right : i64]) : i64
  (let
    [a : i64 left]
    [b : i64 right]
    (begin
      (while (not (= a b))
        (begin
          (while (> (array-ref cfg-rpo-num a) (array-ref cfg-rpo-num b))
            (set! a (array-ref cfg-idom a)))
          (while (> (array-ref cfg-rpo-num b) (array-ref cfg-rpo-num a))
            (set! b (array-ref cfg-idom b)))))
      a)))

(define (cfg-idom-from-preds [id : i64]) : i64
  (let
    [edge : i64 (array-ref cfg-pred-off id)]
    [end : i64 (array-ref cfg-pred-off (+ id 1))]
    [candidate : i64 -1]
    (begin
      (while (< edge end)
        (let
          [pred : i64 (array-ref cfg-pred-edge edge)]
          (begin
            (when
              (and
                (= (array-ref cfg-reachable pred) 1)
                (>= (array-ref cfg-idom pred) 0))
              (if (< candidate 0)
                (set! candidate pred)
                (set! candidate (cfg-intersect pred candidate))))
            (set! edge (+ edge 1)))))
      candidate)))

(define (cfg-idom-iterate [entry : i64]) : bool
  (let
    [slot : i64 1]
    [changed : bool false]
    (begin
      (while (< slot cfg-reach-count)
        (let
          [id : i64 (array-ref cfg-rpo slot)]
          [next : i64 (cfg-idom-from-preds id)]
          (begin
            (when
              (and
                (not (= id entry))
                (>= next 0)
                (not (= (array-ref cfg-idom id) next)))
              (begin
                (array-set! cfg-idom id next)
                (set! changed true)))
            (set! slot (+ slot 1)))))
      changed)))

;; opt-dom-build-euler!: dominator-tree children in ascending id order, then a
;; DFS stamping tin on entry and tout on exit.
(define (cfg-build-euler [entry : i64]) : unit
  (let
    [count : i64 cfg-blocks]
    [i : i64 0]
    [total : i64 0]
    [sp : i64 0]
    [time : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set! cfg-tin i -1)
          (array-set! cfg-tout i -1)
          (array-set! cfg-child-fill i 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i count)
        (let
          [parent : i64 (array-ref cfg-idom i)]
          (begin
            (when
              (and
                (= (array-ref cfg-reachable i) 1)
                (>= parent 0)
                (not (= parent i)))
              (array-set!
                cfg-child-fill
                parent
                (+ (array-ref cfg-child-fill parent) 1)))
            (set! i (+ i 1)))))
      (set! i 0)
      (while (< i count)
        (begin
          (array-set! cfg-child-off i total)
          (set! total (+ total (array-ref cfg-child-fill i)))
          (array-set! cfg-child-fill i (array-ref cfg-child-off i))
          (set! i (+ i 1))))
      (array-set! cfg-child-off count total)
      (set! i 0)
      (while (< i count)
        (let
          [parent : i64 (array-ref cfg-idom i)]
          (begin
            (when
              (and
                (= (array-ref cfg-reachable i) 1)
                (>= parent 0)
                (not (= parent i)))
              (begin
                (array-set! cfg-child-edge (array-ref cfg-child-fill parent) i)
                (array-set!
                  cfg-child-fill
                  parent
                  (+ (array-ref cfg-child-fill parent) 1))))
            (set! i (+ i 1)))))
      (when
        (and (> count 0) (= (array-ref cfg-reachable entry) 1))
        (begin
          (array-set! cfg-stack-node 0 entry)
          (array-set! cfg-stack-edge 0 (array-ref cfg-child-off entry))
          (array-set! cfg-tin entry 0)
          (set! time 1)
          (set! sp 0)
          (while (>= sp 0)
            (let
              [node : i64 (array-ref cfg-stack-node sp)]
              [cursor : i64 (array-ref cfg-stack-edge sp)]
              (if (< cursor (array-ref cfg-child-off (+ node 1)))
                (let
                  [child : i64 (array-ref cfg-child-edge cursor)]
                  (begin
                    (array-set! cfg-stack-edge sp (+ cursor 1))
                    (array-set! cfg-tin child time)
                    (set! time (+ time 1))
                    (set! sp (+ sp 1))
                    (array-set! cfg-stack-node sp child)
                    (array-set!
                      cfg-stack-edge
                      sp
                      (array-ref cfg-child-off child))))
                (begin
                  (array-set! cfg-tout node time)
                  (set! sp (- sp 1)))))))))))

;; opt-dom-info-dominates-id?
(define (cfg-dominates? [dominator : i64] [label : i64]) : bool
  (if (and
    (= (array-ref cfg-reachable dominator) 1)
    (= (array-ref cfg-reachable label) 1))
    (and
      (>= (array-ref cfg-tin dominator) 0)
      (>= (array-ref cfg-tin label) 0)
      (<= (array-ref cfg-tin dominator) (array-ref cfg-tin label))
      (<= (array-ref cfg-tout label) (array-ref cfg-tout dominator)))
    false))

;; opt-natural-loop-build's body collection: seed the marks with header and
;; latch, then walk predecessors backwards from the latch only (a self loop
;; expands nothing), taking the most recently added label first.
(define (cfg-loop-body [header : i64] [latch : i64]) : i64
  (let
    [count : i64 cfg-blocks]
    [i : i64 0]
    [size : i64 0]
    [pending : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set! cfg-marks i 0)
          (set! i (+ i 1))))
      (array-set! cfg-marks header 1)
      (array-set! cfg-marks latch 1)
      (set! size 1)
      (when
        (not (= header latch))
        (begin
          (set! size 2)
          (array-set! cfg-worklist 0 latch)
          (set! pending 1)))
      (while (> pending 0)
        (let
          [node : i64 (array-ref cfg-worklist (- pending 1))]
          [edge : i64 0]
          [end : i64 0]
          (begin
            (set! pending (- pending 1))
            (set! edge (array-ref cfg-pred-off node))
            (set! end (array-ref cfg-pred-off (+ node 1)))
            (while (< edge end)
              (let
                [pred : i64 (array-ref cfg-pred-edge edge)]
                (begin
                  (when
                    (and
                      (= (array-ref cfg-reachable pred) 1)
                      (= (array-ref cfg-marks pred) 0))
                    (begin
                      (array-set! cfg-marks pred 1)
                      (set! size (+ size 1))
                      (array-set! cfg-worklist pending pred)
                      (set! pending (+ pending 1))))
                  (set! edge (+ edge 1))))))))
      size)))

;; opt-natural-loop-find-preheader: the loop has a preheader when exactly one
;; reachable predecessor of the header lies outside the body and its only
;; successor is the header.
(define (cfg-loop-preheader [header : i64]) : i64
  (let
    [edge : i64 (array-ref cfg-pred-off header)]
    [end : i64 (array-ref cfg-pred-off (+ header 1))]
    [state : i64 0]
    [found : i64 -1]
    (begin
      (while (< edge end)
        (let
          [pred : i64 (array-ref cfg-pred-edge edge)]
          (begin
            (when
              (and
                (= (array-ref cfg-reachable pred) 1)
                (= (array-ref cfg-marks pred) 0))
              (cond
                [(= state 2) unit]
                [(= state 0)
                  (if (and
                    (=
                      (-
                        (array-ref cfg-succ-off (+ pred 1))
                        (array-ref cfg-succ-off pred))
                      1)
                    (=
                      (array-ref cfg-succ-edge (array-ref cfg-succ-off pred))
                      header))
                    (begin
                      (set! state 1)
                      (set! found pred))
                    (set! state 2))]
                [else (set! state 2)]))
            (set! edge (+ edge 1)))))
      (if (= state 1)
        found
        -1))))

;; opt-cfg-natural-loop-block-seq-csr: blocks last to first, each successor row
;; forward; a reachable successor that dominates its source closes a loop.
(define (cfg-natural-loops [seed : i64]) : i64
  (let
    [hash : i64 seed]
    [pos : i64 (- cfg-blocks 1)]
    [loops : i64 0]
    (begin
      (while (>= pos 0)
        (begin
          (when
            (= (array-ref cfg-reachable pos) 1)
            (let
              [edge : i64 (array-ref cfg-succ-off pos)]
              [end : i64 (array-ref cfg-succ-off (+ pos 1))]
              (while (< edge end)
                (let
                  [header : i64 (array-ref cfg-succ-edge edge)]
                  (begin
                    (when
                      (and
                        (= (array-ref cfg-reachable header) 1)
                        (cfg-dominates? header pos))
                      (let
                        [size : i64 (cfg-loop-body header pos)]
                        [preheader : i64 (cfg-loop-preheader header)]
                        (begin
                          (set! hash (cfg-mix hash header))
                          (set! hash (cfg-mix hash pos))
                          (set! hash (cfg-mix hash size))
                          (set! hash (cfg-mix hash preheader))
                          (set! loops (+ loops 1)))))
                    (set! edge (+ edge 1)))))))
          (set! pos (- pos 1))))
      (cfg-mix hash loops))))

;; One function's opt-cfg-context-build plus natural-loop enumeration, folded
;; into a checksum over the RPO order, the idom vector, and every loop.
(define (cfg-function) : i64
  (let
    [count : i64 cfg-blocks]
    [hash : i64 cfg-hash-basis]
    [i : i64 0]
    [remaining : i64 0]
    (begin
      (cfg-build-csr)
      (cfg-dfs-postorder)
      (while (< i count)
        (begin
          (array-set! cfg-idom i -1)
          (set! i (+ i 1))))
      (when
        (and (> count 0) (= (array-ref cfg-reachable 0) 1))
        (begin
          (array-set! cfg-idom 0 0)
          (set! remaining (+ count 1))
          (while (and (> remaining 0) (cfg-idom-iterate 0))
            (set! remaining (- remaining 1)))))
      (cfg-build-euler 0)
      (set! hash (cfg-mix hash count))
      (set! hash (cfg-mix hash cfg-reach-count))
      (set! i 0)
      (while (< i cfg-reach-count)
        (begin
          (set! hash (cfg-mix hash (array-ref cfg-rpo i)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i count)
        (begin
          (set! hash (cfg-mix hash (array-ref cfg-idom i)))
          (set! i (+ i 1))))
      (cfg-natural-loops hash))))

(define (cfg-bench [path : String] [rounds : i64]) : i64
  (let
    [text : String (io.read-file path)]
    [capacity : i64 (+ (/ (string.string-length text) 2) 8)]
    [functions : i64 0]
    [cursor : i64 1]
    [max-blocks : i64 1]
    [max-edges : i64 1]
    [round : i64 0]
    [start : i64 0]
    [acc : i64 cfg-hash-basis]
    (begin
      (set! cfg-tokens (array.make-array i64 capacity))
      (set! acc (cfg-mix acc (cfg-scan-ints text cfg-tokens)))
      (set! functions (array-ref cfg-tokens 0))
      (set! cfg-offsets (array.make-array i64 (+ functions 1)))
      (let
        [f : i64 0]
        (while (< f functions)
          (let
            [blocks : i64 (array-ref cfg-tokens cursor)]
            [edges : i64 (array-ref cfg-tokens (+ cursor 1))]
            (begin
              (array-set! cfg-offsets f cursor)
              (when (> blocks max-blocks) (set! max-blocks blocks))
              (when (> edges max-edges) (set! max-edges edges))
              (set! cursor (+ cursor (+ 2 (* edges 2))))
              (set! f (+ f 1))))))
      (set! cfg-succ-off (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-succ-edge (array.make-array i64 (+ max-edges 1)))
      (set! cfg-succ-fill (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-pred-off (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-pred-edge (array.make-array i64 (+ max-edges 1)))
      (set! cfg-pred-fill (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-child-off (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-child-edge (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-child-fill (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-reachable (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-postorder (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-rpo (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-rpo-num (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-idom (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-tin (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-tout (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-marks (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-worklist (array.make-array i64 (+ max-blocks 1)))
      (set! cfg-stack-node (array.make-array i64 (+ max-blocks 2)))
      (set! cfg-stack-edge (array.make-array i64 (+ max-blocks 2)))
      (while (< round rounds)
        (let
          [step : i64 0]
          [index : i64 0]
          [offset : i64 0]
          (begin
            (set! acc (cfg-mix acc round))
            (while (< step functions)
              (begin
                (set! index (+ start step))
                (when (>= index functions) (set! index (- index functions)))
                (set! offset (array-ref cfg-offsets index))
                (set! cfg-blocks (array-ref cfg-tokens offset))
                (set! cfg-edges (array-ref cfg-tokens (+ offset 1)))
                (set! cfg-edge-base (+ offset 2))
                (set! acc (cfg-mix acc (cfg-function)))
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
      (io.print (cfg-bench path rounds))
      0)))