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
;# is what `__tl_make-array bool (opt-cfg-index-block-count index)` costs per
;# natural loop in `opt-natural-loop-build`. That per-function loop-enumeration
;# cost is the one this benchmark exists to track.
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

(define (cfg-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (cfg-vec-ref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(define (cfg-vec-set!
  [items : (&mut items i64vec.Vec)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut items) index) value))

(defmacro (cfg-ref [items : Expr] [index : Expr]) : Expr
  `(cfg-vec-ref (& ,items) ,index))

(defmacro (cfg-set! [items : Expr] [index : Expr] [value : Expr]) : Expr
  `(cfg-vec-set! (&mut ,items) ,index ,value))

(define cfg-hash-basis : i64
  1469598103934665603)
(define cfg-hash-prime : i64
  1099511628211)

;; Parsed corpus tokens and the scratch arrays every per-function pass reuses.
;; Module globals keep the analysis functions parameterless, matching how the
;; compiler threads one workspace through a pass.
(define cfg-tokens : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-offsets : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-succ-off : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-succ-edge : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-succ-fill : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-pred-off : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-pred-edge : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-pred-fill : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-child-off : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-child-edge : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-child-fill : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-reachable : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-postorder : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-rpo : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-rpo-num : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-idom : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-tin : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-tout : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-marks : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-worklist : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-stack-node : i64vec.Vec
  (cfg-zero-vec 1))
(define cfg-stack-edge : i64vec.Vec
  (cfg-zero-vec 1))

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

(define (cfg-byte-at [text : (& text str)] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (cfg-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

;; Whitespace-separated decimal integers, with `#` starting a comment that runs
;; to the end of its line.
(define (cfg-scan-ints [text : (& text str)] [out : (&mut out i64vec.Vec)]) : i64
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
                  (i64vec.set-ref!
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
(define (cfg-build-csr
  [tokens-vec : (& tokens i64vec.Vec)]
  [succ-off-vec : (&mut succ-off i64vec.Vec)]
  [succ-edge-vec : (&mut succ-edge i64vec.Vec)]
  [succ-fill-vec : (&mut succ-fill i64vec.Vec)]
  [pred-off-vec : (&mut pred-off i64vec.Vec)]
  [pred-edge-vec : (&mut pred-edge i64vec.Vec)]
  [pred-fill-vec : (&mut pred-fill i64vec.Vec)]) : unit
  (let
    [count : i64 cfg-blocks]
    [i : i64 0]
    [edge : i64 0]
    [succ-total : i64 0]
    [pred-total : i64 0]
    (begin
      (let
        [tokens (i64vec.slots tokens-vec)]
        [succ-fill (i64vec.slots-mut succ-fill-vec)]
        [pred-fill (i64vec.slots-mut pred-fill-vec)]
        (begin
          (while (< i count)
            (begin
              (set! (array-ref succ-fill i) 0)
              (set! (array-ref pred-fill i) 0)
              (set! i (+ i 1))))
          (set! edge 0)
          (while (< edge cfg-edges)
            (let
              [src : i64 (array-ref tokens (+ cfg-edge-base (* edge 2)))]
              [dst : i64 (array-ref tokens (+ (+ cfg-edge-base (* edge 2)) 1))]
              (begin
                (set! (array-ref succ-fill src) (+ (array-ref succ-fill src) 1))
                (set! (array-ref pred-fill dst) (+ (array-ref pred-fill dst) 1))
                (set! edge (+ edge 1)))))
          0))
      (let
        [succ-off (i64vec.slots-mut succ-off-vec)]
        [succ-fill (i64vec.slots-mut succ-fill-vec)]
        [pred-off (i64vec.slots-mut pred-off-vec)]
        [pred-fill (i64vec.slots-mut pred-fill-vec)]
        (begin
          (set! i 0)
          (while (< i count)
            (begin
              (set! (array-ref succ-off i) succ-total)
              (set! succ-total (+ succ-total (array-ref succ-fill i)))
              (set! (array-ref succ-fill i) (array-ref succ-off i))
              (set! (array-ref pred-off i) pred-total)
              (set! pred-total (+ pred-total (array-ref pred-fill i)))
              (set! (array-ref pred-fill i) (array-ref pred-off i))
              (set! i (+ i 1))))
          (set! (array-ref succ-off count) succ-total)
          (set! (array-ref pred-off count) pred-total)
          0))
      (let
        [tokens (i64vec.slots tokens-vec)]
        [succ-edge (i64vec.slots-mut succ-edge-vec)]
        [succ-fill (i64vec.slots-mut succ-fill-vec)]
        [pred-edge (i64vec.slots-mut pred-edge-vec)]
        [pred-fill (i64vec.slots-mut pred-fill-vec)]
        (begin
          (set! edge 0)
          (while (< edge cfg-edges)
            (let
              [src : i64 (array-ref tokens (+ cfg-edge-base (* edge 2)))]
              [dst : i64 (array-ref tokens (+ (+ cfg-edge-base (* edge 2)) 1))]
              (begin
                (set! (array-ref succ-edge (array-ref succ-fill src)) dst)
                (set! (array-ref succ-fill src) (+ (array-ref succ-fill src) 1))
                (set! (array-ref pred-edge (array-ref pred-fill dst)) src)
                (set! (array-ref pred-fill dst) (+ (array-ref pred-fill dst) 1))
                (set! edge (+ edge 1)))))
          0))
      unit)))

;; opt-cfg-index-dfs-postorder! written with an explicit stack: mark on entry,
;; append on exit, successors in CSR row order.
(define (cfg-dfs-postorder
  [succ-off-vec : (& succ-off i64vec.Vec)]
  [succ-edge-vec : (& succ-edge i64vec.Vec)]
  [reachable-vec : (&mut reachable i64vec.Vec)]
  [postorder-vec : (&mut postorder i64vec.Vec)]
  [rpo-vec : (&mut rpo i64vec.Vec)]
  [rpo-num-vec : (&mut rpo-num i64vec.Vec)]
  [stack-node-vec : (&mut stack-node i64vec.Vec)]
  [stack-edge-vec : (&mut stack-edge i64vec.Vec)]) : unit
  (let
    [succ-off (i64vec.slots succ-off-vec)]
    [succ-edge (i64vec.slots succ-edge-vec)]
    [reachable (i64vec.slots-mut reachable-vec)]
    [postorder (i64vec.slots-mut postorder-vec)]
    [rpo (i64vec.slots-mut rpo-vec)]
    [rpo-num (i64vec.slots-mut rpo-num-vec)]
    [stack-node (i64vec.slots-mut stack-node-vec)]
    [stack-edge (i64vec.slots-mut stack-edge-vec)]
    [count : i64 cfg-blocks]
    [i : i64 0]
    [sp : i64 0]
    [post : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! (array-ref reachable i) 0)
          (set! (array-ref postorder i) -1)
          (set! (array-ref rpo i) -1)
          (set! (array-ref rpo-num i) -1)
          (set! i (+ i 1))))
      (when
        (> count 0)
        (begin
          (set! (array-ref reachable 0) 1)
          (set! (array-ref stack-node 0) 0)
          (set! (array-ref stack-edge 0) (array-ref succ-off 0))
          (set! sp 0)
          (while (>= sp 0)
            (let
              [node : i64 (array-ref stack-node sp)]
              [cursor : i64 (array-ref stack-edge sp)]
              (if (< cursor (array-ref succ-off (+ node 1)))
                (let
                  [next : i64 (array-ref succ-edge cursor)]
                  (begin
                    (set! (array-ref stack-edge sp) (+ cursor 1))
                    (when
                      (= (array-ref reachable next) 0)
                      (begin
                        (set! (array-ref reachable next) 1)
                        (set! sp (+ sp 1))
                        (set! (array-ref stack-node sp) next)
                        (set!
                          (array-ref stack-edge sp)
                          (array-ref succ-off next))))))
                (begin
                  (set! (array-ref postorder post) node)
                  (set! post (+ post 1))
                  (set! sp (- sp 1))))))))
      (set! cfg-reach-count post)
      (set! i 0)
      (while (< i post)
        (begin
          (set! (array-ref rpo i) (array-ref postorder (- (- post 1) i)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i post)
        (begin
          (set! (array-ref rpo-num (array-ref rpo i)) i)
          (set! i (+ i 1)))))))

(define (cfg-idom-iterate
  [entry : i64]
  [rpo-vec : (& rpo i64vec.Vec)]
  [pred-off-vec : (& pred-off i64vec.Vec)]
  [pred-edge-vec : (& pred-edge i64vec.Vec)]
  [reachable-vec : (& reachable i64vec.Vec)]
  [idom-vec : (&mut idom i64vec.Vec)]
  [rpo-num-vec : (& rpo-num i64vec.Vec)]) : bool
  (let
    [rpo (i64vec.slots rpo-vec)]
    [pred-off (i64vec.slots pred-off-vec)]
    [pred-edge (i64vec.slots pred-edge-vec)]
    [reachable (i64vec.slots reachable-vec)]
    [idom (i64vec.slots-mut idom-vec)]
    [rpo-num (i64vec.slots rpo-num-vec)]
    [slot : i64 1]
    [changed : bool false]
    (begin
      (while (< slot cfg-reach-count)
        (let
          [id : i64 (array-ref rpo slot)]
          [edge : i64 (array-ref pred-off id)]
          [end : i64 (array-ref pred-off (+ id 1))]
          [candidate : i64 -1]
          (begin
            (while (< edge end)
              (let
                [pred : i64 (array-ref pred-edge edge)]
                (begin
                  (when
                    (and
                      (= (array-ref reachable pred) 1)
                      (>= (array-ref idom pred) 0))
                    (if (< candidate 0)
                      (set! candidate pred)
                      (let
                        [a : i64 pred]
                        [b : i64 candidate]
                        (begin
                          (while (not (= a b))
                            (begin
                              (while (>
                                (array-ref rpo-num a)
                                (array-ref rpo-num b))
                                (set! a (array-ref idom a)))
                              (while (>
                                (array-ref rpo-num b)
                                (array-ref rpo-num a))
                                (set! b (array-ref idom b)))))
                          (set! candidate a)))))
                  (set! edge (+ edge 1)))))
            (when
              (and
                (not (= id entry))
                (>= candidate 0)
                (not (= (array-ref idom id) candidate)))
              (begin
                (set! (array-ref idom id) candidate)
                (set! changed true)))
            (set! slot (+ slot 1)))))
      changed)))

;; opt-dom-build-euler!: dominator-tree children in ascending id order, then a
;; DFS stamping tin on entry and tout on exit.
(define (cfg-build-euler-tree
  [idom-vec : (& idom i64vec.Vec)]
  [reachable-vec : (& reachable i64vec.Vec)]
  [tin-vec : (&mut tin i64vec.Vec)]
  [tout-vec : (&mut tout i64vec.Vec)]
  [child-fill-vec : (&mut child-fill i64vec.Vec)]
  [child-off-vec : (&mut child-off i64vec.Vec)]
  [child-edge-vec : (&mut child-edge i64vec.Vec)]) : unit
  (let
    [idom (i64vec.slots idom-vec)]
    [reachable (i64vec.slots reachable-vec)]
    [tin (i64vec.slots-mut tin-vec)]
    [tout (i64vec.slots-mut tout-vec)]
    [child-fill (i64vec.slots-mut child-fill-vec)]
    [child-off (i64vec.slots-mut child-off-vec)]
    [child-edge (i64vec.slots-mut child-edge-vec)]
    [count : i64 cfg-blocks]
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! (array-ref tin i) -1)
          (set! (array-ref tout i) -1)
          (set! (array-ref child-fill i) 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i count)
        (let
          [parent : i64 (array-ref idom i)]
          (begin
            (when
              (and
                (= (array-ref reachable i) 1)
                (>= parent 0)
                (not (= parent i)))
              (set!
                (array-ref child-fill parent)
                (+ (array-ref child-fill parent) 1)))
            (set! i (+ i 1)))))
      (set! i 0)
      (while (< i count)
        (begin
          (set! (array-ref child-off i) total)
          (set! total (+ total (array-ref child-fill i)))
          (set! (array-ref child-fill i) (array-ref child-off i))
          (set! i (+ i 1))))
      (set! (array-ref child-off count) total)
      (set! i 0)
      (while (< i count)
        (let
          [parent : i64 (array-ref idom i)]
          (begin
            (when
              (and
                (= (array-ref reachable i) 1)
                (>= parent 0)
                (not (= parent i)))
              (begin
                (set! (array-ref child-edge (array-ref child-fill parent)) i)
                (set!
                  (array-ref child-fill parent)
                  (+ (array-ref child-fill parent) 1))))
            (set! i (+ i 1)))))
      unit)))

(define (cfg-stamp-euler
  [entry : i64]
  [reachable-vec : (& reachable i64vec.Vec)]
  [child-off-vec : (& child-off i64vec.Vec)]
  [child-edge-vec : (& child-edge i64vec.Vec)]
  [stack-node-vec : (&mut stack-node i64vec.Vec)]
  [stack-edge-vec : (&mut stack-edge i64vec.Vec)]
  [tin-vec : (&mut tin i64vec.Vec)]
  [tout-vec : (&mut tout i64vec.Vec)]) : unit
  (let
    [reachable (i64vec.slots reachable-vec)]
    [child-off (i64vec.slots child-off-vec)]
    [child-edge (i64vec.slots child-edge-vec)]
    [stack-node (i64vec.slots-mut stack-node-vec)]
    [stack-edge (i64vec.slots-mut stack-edge-vec)]
    [tin (i64vec.slots-mut tin-vec)]
    [tout (i64vec.slots-mut tout-vec)]
    [count : i64 cfg-blocks]
    [sp : i64 0]
    [time : i64 0]
    (begin
      (when
        (and (> count 0) (= (array-ref reachable entry) 1))
        (begin
          (set! (array-ref stack-node 0) entry)
          (set! (array-ref stack-edge 0) (array-ref child-off entry))
          (set! (array-ref tin entry) 0)
          (set! time 1)
          (set! sp 0)
          (while (>= sp 0)
            (let
              [node : i64 (array-ref stack-node sp)]
              [cursor : i64 (array-ref stack-edge sp)]
              (if (< cursor (array-ref child-off (+ node 1)))
                (let
                  [child : i64 (array-ref child-edge cursor)]
                  (begin
                    (set! (array-ref stack-edge sp) (+ cursor 1))
                    (set! (array-ref tin child) time)
                    (set! time (+ time 1))
                    (set! sp (+ sp 1))
                    (set! (array-ref stack-node sp) child)
                    (set! (array-ref stack-edge sp) (array-ref child-off child))))
                (begin
                  (set! (array-ref tout node) time)
                  (set! sp (- sp 1))))))))
      unit)))

;; opt-dom-info-dominates-id?
(define (cfg-dominates?
  [dominator : i64]
  [label : i64]
  [reachable-vec : (& reachable i64vec.Vec)]
  [tin-vec : (& tin i64vec.Vec)]
  [tout-vec : (& tout i64vec.Vec)]) : bool
  (let
    [reachable (i64vec.slots reachable-vec)]
    [tin (i64vec.slots tin-vec)]
    [tout (i64vec.slots tout-vec)]
    (if (and
      (= (array-ref reachable dominator) 1)
      (= (array-ref reachable label) 1))
      (and
        (>= (array-ref tin dominator) 0)
        (>= (array-ref tin label) 0)
        (<= (array-ref tin dominator) (array-ref tin label))
        (<= (array-ref tout label) (array-ref tout dominator)))
      false)))

;; opt-natural-loop-build's body collection: seed the marks with header and
;; latch, then walk predecessors backwards from the latch only (a self loop
;; expands nothing), taking the most recently added label first.
(define (cfg-loop-body
  [header : i64]
  [latch : i64]
  [pred-off-vec : (& pred-off i64vec.Vec)]
  [pred-edge-vec : (& pred-edge i64vec.Vec)]
  [reachable-vec : (& reachable i64vec.Vec)]
  [marks-vec : (&mut marks i64vec.Vec)]
  [worklist-vec : (&mut worklist i64vec.Vec)]) : i64
  (let
    [pred-off (i64vec.slots pred-off-vec)]
    [pred-edge (i64vec.slots pred-edge-vec)]
    [reachable (i64vec.slots reachable-vec)]
    [marks (i64vec.slots-mut marks-vec)]
    [worklist (i64vec.slots-mut worklist-vec)]
    [count : i64 cfg-blocks]
    [i : i64 0]
    [size : i64 0]
    [pending : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! (array-ref marks i) 0)
          (set! i (+ i 1))))
      (set! (array-ref marks header) 1)
      (set! (array-ref marks latch) 1)
      (set! size 1)
      (when
        (not (= header latch))
        (begin
          (set! size 2)
          (set! (array-ref worklist 0) latch)
          (set! pending 1)))
      (while (> pending 0)
        (let
          [node : i64 (array-ref worklist (- pending 1))]
          [edge : i64 0]
          [end : i64 0]
          (begin
            (set! pending (- pending 1))
            (set! edge (array-ref pred-off node))
            (set! end (array-ref pred-off (+ node 1)))
            (while (< edge end)
              (let
                [pred : i64 (array-ref pred-edge edge)]
                (begin
                  (when
                    (and
                      (= (array-ref reachable pred) 1)
                      (= (array-ref marks pred) 0))
                    (begin
                      (set! (array-ref marks pred) 1)
                      (set! size (+ size 1))
                      (set! (array-ref worklist pending) pred)
                      (set! pending (+ pending 1))))
                  (set! edge (+ edge 1))))))))
      size)))

;; opt-natural-loop-find-preheader: the loop has a preheader when exactly one
;; reachable predecessor of the header lies outside the body and its only
;; successor is the header.
(define (cfg-loop-preheader
  [header : i64]
  [pred-off-vec : (& pred-off i64vec.Vec)]
  [pred-edge-vec : (& pred-edge i64vec.Vec)]
  [reachable-vec : (& reachable i64vec.Vec)]
  [marks-vec : (& marks i64vec.Vec)]
  [succ-off-vec : (& succ-off i64vec.Vec)]
  [succ-edge-vec : (& succ-edge i64vec.Vec)]) : i64
  (let
    [pred-off (i64vec.slots pred-off-vec)]
    [pred-edge (i64vec.slots pred-edge-vec)]
    [reachable (i64vec.slots reachable-vec)]
    [marks (i64vec.slots marks-vec)]
    [succ-off (i64vec.slots succ-off-vec)]
    [succ-edge (i64vec.slots succ-edge-vec)]
    [edge : i64 (array-ref pred-off header)]
    [end : i64 (array-ref pred-off (+ header 1))]
    [state : i64 0]
    [found : i64 -1]
    (begin
      (while (< edge end)
        (let
          [pred : i64 (array-ref pred-edge edge)]
          (begin
            (when
              (and
                (= (array-ref reachable pred) 1)
                (= (array-ref marks pred) 0))
              (cond
                [(= state 2) unit]
                [(= state 0)
                  (if (and
                    (=
                      (-
                        (array-ref succ-off (+ pred 1))
                        (array-ref succ-off pred))
                      1)
                    (= (array-ref succ-edge (array-ref succ-off pred)) header))
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
            (= (cfg-ref cfg-reachable pos) 1)
            (let
              [edge : i64 (cfg-ref cfg-succ-off pos)]
              [end : i64 (cfg-ref cfg-succ-off (+ pos 1))]
              (while (< edge end)
                (let
                  [header : i64 (cfg-ref cfg-succ-edge edge)]
                  (begin
                    (when
                      (and
                        (= (cfg-ref cfg-reachable header) 1)
                        (cfg-dominates?
                          header
                          pos
                          (& cfg-reachable)
                          (& cfg-tin)
                          (& cfg-tout)))
                      (let
                        [size : i64
                          (cfg-loop-body
                            header
                            pos
                            (& cfg-pred-off)
                            (& cfg-pred-edge)
                            (& cfg-reachable)
                            (&mut cfg-marks)
                            (&mut cfg-worklist))]
                        [preheader : i64
                          (cfg-loop-preheader
                            header
                            (& cfg-pred-off)
                            (& cfg-pred-edge)
                            (& cfg-reachable)
                            (& cfg-marks)
                            (& cfg-succ-off)
                            (& cfg-succ-edge))]
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
      (cfg-build-csr
        (& cfg-tokens)
        (&mut cfg-succ-off)
        (&mut cfg-succ-edge)
        (&mut cfg-succ-fill)
        (&mut cfg-pred-off)
        (&mut cfg-pred-edge)
        (&mut cfg-pred-fill))
      (cfg-dfs-postorder
        (& cfg-succ-off)
        (& cfg-succ-edge)
        (&mut cfg-reachable)
        (&mut cfg-postorder)
        (&mut cfg-rpo)
        (&mut cfg-rpo-num)
        (&mut cfg-stack-node)
        (&mut cfg-stack-edge))
      (while (< i count)
        (begin
          (cfg-set! cfg-idom i -1)
          (set! i (+ i 1))))
      (when
        (and (> count 0) (= (cfg-ref cfg-reachable 0) 1))
        (begin
          (cfg-set! cfg-idom 0 0)
          (set! remaining (+ count 1))
          (while (and
            (> remaining 0)
            (cfg-idom-iterate
              0
              (& cfg-rpo)
              (& cfg-pred-off)
              (& cfg-pred-edge)
              (& cfg-reachable)
              (&mut cfg-idom)
              (& cfg-rpo-num)))
            (set! remaining (- remaining 1)))))
      (cfg-build-euler-tree
        (& cfg-idom)
        (& cfg-reachable)
        (&mut cfg-tin)
        (&mut cfg-tout)
        (&mut cfg-child-fill)
        (&mut cfg-child-off)
        (&mut cfg-child-edge))
      (cfg-stamp-euler
        0
        (& cfg-reachable)
        (& cfg-child-off)
        (& cfg-child-edge)
        (&mut cfg-stack-node)
        (&mut cfg-stack-edge)
        (&mut cfg-tin)
        (&mut cfg-tout))
      (set! hash (cfg-mix hash count))
      (set! hash (cfg-mix hash cfg-reach-count))
      (set! i 0)
      (while (< i cfg-reach-count)
        (begin
          (set! hash (cfg-mix hash (cfg-ref cfg-rpo i)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i count)
        (begin
          (set! hash (cfg-mix hash (cfg-ref cfg-idom i)))
          (set! i (+ i 1))))
      (cfg-natural-loops hash))))

(define (cfg-bench [path : String] [rounds : i64]) : i64
  (let
    [text : String (byte_buf.to-string (io.read-file path))]
    [capacity : i64 (+ (/ (string.string-length text) 2) 8)]
    [functions : i64 0]
    [cursor : i64 1]
    [max-blocks : i64 1]
    [max-edges : i64 1]
    [round : i64 0]
    [start : i64 0]
    [acc : i64 cfg-hash-basis]
    (begin
      (set! cfg-tokens (cfg-zero-vec capacity))
      (set! acc (cfg-mix acc (cfg-scan-ints text (&mut cfg-tokens))))
      (set! functions (cfg-ref cfg-tokens 0))
      (set! cfg-offsets (cfg-zero-vec (+ functions 1)))
      (let
        [f : i64 0]
        (while (< f functions)
          (let
            [blocks : i64 (cfg-ref cfg-tokens cursor)]
            [edges : i64 (cfg-ref cfg-tokens (+ cursor 1))]
            (begin
              (cfg-set! cfg-offsets f cursor)
              (when (> blocks max-blocks) (set! max-blocks blocks))
              (when (> edges max-edges) (set! max-edges edges))
              (set! cursor (+ cursor (+ 2 (* edges 2))))
              (set! f (+ f 1))))))
      (set! cfg-succ-off (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-succ-edge (cfg-zero-vec (+ max-edges 1)))
      (set! cfg-succ-fill (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-pred-off (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-pred-edge (cfg-zero-vec (+ max-edges 1)))
      (set! cfg-pred-fill (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-child-off (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-child-edge (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-child-fill (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-reachable (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-postorder (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-rpo (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-rpo-num (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-idom (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-tin (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-tout (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-marks (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-worklist (cfg-zero-vec (+ max-blocks 1)))
      (set! cfg-stack-node (cfg-zero-vec (+ max-blocks 2)))
      (set! cfg-stack-edge (cfg-zero-vec (+ max-blocks 2)))
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
                (set! offset (cfg-ref cfg-offsets index))
                (set! cfg-blocks (cfg-ref cfg-tokens offset))
                (set! cfg-edges (cfg-ref cfg-tokens (+ offset 1)))
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
      (io.println "{}" (cfg-bench path rounds))
      0)))