;; Final IR region attribution. Source anchors identify control; natural-loop
;; membership supplies the final blocks. Neither labels nor physical homes are
;; interpreted by spelling. This module sits above the policy-neutral facts.
(import compiler_ir_types as ir)
(import compiler_liveness as live)
(import compiler_optimize as opt)
(import compiler_stack_traffic as traffic)
(import compiler_owned_view as owned_view)
(import stdlib.iterator)
(import stdlib.vector)
(import (vector.vector opt.OptNaturalLoop core) as natural_loops)

(defstruct CompilerStackTrafficPartition
  (regions (__tl_dyn-array traffic.CompilerStackTrafficRegion))
  (blocks (__tl_dyn-array i64)))

(defenum CompilerStackTrafficPartitionResult
  (Ok CompilerStackTrafficPartition)
  (Err String))

(defstruct CompilerStackTrafficRegionCandidate
  (kind traffic.CompilerStackTrafficRegionKind)
  (site ir.CompilerSpmdSiteId)
  (header i64)
  (size i64)
  (members (__tl_dyn-array bool)))

(define (compiler-stack-traffic-region-id
  [graph : (& graph live.CompilerLiveBlockGraph)]
  [label : i64]) : i64
  (live.compiler-live-label-id-map-get (& graph.ids) label))

(define (compiler-stack-traffic-region-size
  [members : (& (__tl_dyn-array bool))]) : i64
  (let
    [size : i64 0]
    (for [block (iterator.range 0 (array-length members))]
      (when (array-ref members block) (+= size 1)))
    size))

;; One shared CFG walk serves tail/control slices and the optimizer's guarded
;; memory analysis. The caller has checked IDs and supplies exact-sized arrays.
(define (compiler-stack-traffic-region-cone
  [context : (& context opt.OptCfgContext)]
  [root : i64]
  [stop : i64]) : (__tl_dyn-array bool)
  (let
    [count : i64 (array-length context.index.labels)]
    [members : (__tl_dyn-array bool) (__tl_make-array bool count)]
    [stack : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    (when
      (and (>= root 0) (!= root stop))
      (opt.opt-cfg-reach-fill!
        (& context.index.succs)
        root
        stop
        count
        (&mut members)
        (&mut stack)))
    members))

;; Multiple backedges with one header are one source region. Dominance in the
;; canonical natural-loop analysis excludes entry-bypassing and irreducible
;; cycles; a raw SCC would incorrectly absorb setup or an enclosing loop.
(define (compiler-stack-traffic-region-loop
  [loops : (& loops (Slice opt.OptNaturalLoop))]
  [header : i64]
  [count : i64]) : (__tl_dyn-array bool)
  (let
    [members : (__tl_dyn-array bool) (__tl_make-array bool count)]
    (for [index (iterator.range 0 (array-length loops))]
      (let
        [loop : (& loops opt.OptNaturalLoop) (& (array-ref loops index))]
        (when
          (= (opt.opt-natural-loop-header loop) header)
          (for [block (iterator.range 0 count)]
            (when
              (opt.opt-natural-loop-body-contains-id? loop block)
              (set! (array-ref members block) true))))))
    members))

(define (compiler-stack-traffic-partition
  [function : (& ir.CompilerIrFunction)]
  [graph : (& graph live.CompilerLiveBlockGraph)]
  [facts : (& facts ir.CompilerSpmdDecisions)]) : CompilerStackTrafficPartitionResult
  (match (traffic.compiler-stack-traffic-graph-check graph)
    [(Err message) (return (Err message))]
    [(Ok) unit])
  (match function
    [(Function name _ _ _ blocks _)
      (let
        [dense-blocks : ir.CompilerIrBlockList
          (owned_view.compiler-owned-reference-shared-view blocks)]
        [seq : (& dense-blocks (Slice ir.CompilerIrBlock))
          (ir.compiler-ir-block-list-view (& dense-blocks))]
        [count : i64 (array-length seq)]
        [context : opt.OptCfgContext
          (opt.opt-cfg-context-build
            (owned_view.compiler-owned-reference-shared-view blocks))]
        [loops : natural_loops.Vec
          (opt.opt-cfg-natural-loops-with-context
            (owned_view.compiler-owned-reference-shared-view blocks)
            (& context))]
        [candidates : (__tl_dyn-array CompilerStackTrafficRegionCandidate)
          (__tl_make-array
            CompilerStackTrafficRegionCandidate
            (+ (* facts.loops.len 2) facts.unrolls.len))]
        [used : i64 0]
        [cold-sites : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [cold-sizes : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        (when
          (!= count (array-length graph.blocks))
          (return (Err "stack traffic: final IR/graph extent mismatch")))
        (for [block (iterator.range 0 count)]
          (match (& (array-ref seq block))
            [(Block label _)
              (when
                (or
                  (!= label (array-ref graph.blocks block).label)
                  (!= (compiler-stack-traffic-region-id graph label) block))
                (return
                  (Err "stack traffic: final graph label identity mismatch")))])
          (let
            [edges : (& graph live.CompilerLiveIndexVec)
              (& (array-ref graph.successors block))]
            [start : i64 (array-ref context.index.succs.offsets block)]
            [end : i64 (array-ref context.index.succs.offsets (+ block 1))]
            (unless
              (= (- end start) (array-length edges.items))
              (return (Err "stack traffic: final IR/graph edge mismatch")))
            (for [edge (iterator.range start end)]
              (let
                [found : bool false]
                (for [actual (iterator.range 0 (array-length edges.items))]
                  (when
                    (=
                      (array-ref context.index.succs.edges edge)
                      (array-ref edges.items actual))
                    (set! found true)))
                (unless
                  found
                  (return (Err "stack traffic: final IR/graph edge mismatch"))))))
          (set! (array-ref cold-sites block) -1)
          (set! (array-ref cold-sizes block) (+ count 1)))
        ;; Reject duplicate source-body associations even if a lucky final
        ;; block order would otherwise choose one. No stale transform may
        ;; silently turn into ordinary traffic.
        (for [index (iterator.range 0 facts.unrolls.len)]
          (let
            [unroll : (& facts ir.CompilerSpmdLoopUnroll)
              (& (array-ref facts.unrolls.slots index))]
            (when
              (= unroll.function.value name)
              (let
                [sources : i64 0]
                (for [source (iterator.range 0 facts.loops.len)]
                  (let
                    [anchor : (& facts ir.CompilerSpmdLoopRegion)
                      (& (array-ref facts.loops.slots source))]
                    (when
                      (and
                        (= anchor.function.value name)
                        (= anchor.body unroll.body))
                      (+= sources 1))))
                (unless
                  (= sources 1)
                  (return (Err "stack traffic: unroll has no unique source")))))))
        ;; All candidate sets are retained before ownership is assigned. Inner
        ;; source loops own their accesses while remaining control for parents.
        (for [source (iterator.range 0 facts.loops.len)]
          (let
            [anchor : (& facts ir.CompilerSpmdLoopRegion)
              (& (array-ref facts.loops.slots source))]
            (when
              (= anchor.function.value name)
              (let
                [body : i64
                  (compiler-stack-traffic-region-id graph anchor.body)]
                [header : i64
                  (compiler-stack-traffic-region-id graph anchor.header)]
                [tail : i64
                  (compiler-stack-traffic-region-id graph anchor.tail)]
                [exit : i64
                  (compiler-stack-traffic-region-id graph anchor.exit)]
                [hot : (__tl_dyn-array bool)
                  (compiler-stack-traffic-region-loop
                    (natural_loops.view loops)
                    anchor.header
                    count)]
                [hot-header : i64 header]
                [cone : (__tl_dyn-array bool)
                  (compiler-stack-traffic-region-cone
                    (& context)
                    (if (>= header 0)
                      header
                      body)
                    exit)]
                (when
                  (and
                    (< body 0)
                    (> (compiler-stack-traffic-region-size (& hot)) 0))
                  (return
                    (Err "stack traffic: recurring source header lost its body")))
                ;; Rotation may retire the test header. The typed body is the
                ;; only permitted replacement, and must itself head a natural
                ;; loop. Arbitrary containing SCCs are never substituted.
                (when
                  (and (>= body 0) (array-ref context.index.reachable body))
                  (when
                    (< exit 0)
                    (return
                      (Err
                        "stack traffic: full gang has no retained source exit")))
                  (when
                    (= (compiler-stack-traffic-region-size (& hot)) 0)
                    (set!
                      hot
                      (compiler-stack-traffic-region-loop
                        (natural_loops.view loops)
                        anchor.body
                        count))
                    (set! hot-header body))
                  (when
                    (or
                      (= (compiler-stack-traffic-region-size (& hot)) 0)
                      (not (array-ref hot body)))
                    (return
                      (Err "stack traffic: untracked full-gang control rewrite")))
                  (set!
                    (array-ref candidates used)
                    (CompilerStackTrafficRegionCandidate
                      (FullGang)
                      (clone anchor.site)
                      hot-header
                      (compiler-stack-traffic-region-size (& hot))
                      hot))
                  (+= used 1))
                (when
                  (and
                    (>= tail 0)
                    (!= tail exit)
                    (array-ref context.index.reachable tail))
                  (when
                    (< exit 0)
                    (return
                      (Err "stack traffic: tail has no retained source exit")))
                  (let
                    [members : (__tl_dyn-array bool)
                      (compiler-stack-traffic-region-cone (& context) tail exit)]
                    (when
                      (and (>= body 0) (array-ref members body))
                      (return
                        (Err "stack traffic: tail re-enters full-gang control")))
                    (set!
                      (array-ref candidates used)
                      (CompilerStackTrafficRegionCandidate
                        (Tail)
                        (clone anchor.site)
                        tail
                        (compiler-stack-traffic-region-size (& members))
                        members))
                    (+= used 1)))
                ;; A committed unroll's new recurring header has an explicit
                ;; unique source-body association. Dead history owns nothing.
                (for [unroll-index (iterator.range 0 facts.unrolls.len)]
                  (let
                    [unroll : (& facts ir.CompilerSpmdLoopUnroll)
                      (& (array-ref facts.unrolls.slots unroll-index))]
                    (when
                      (and
                        (= unroll.function.value name)
                        (= unroll.body anchor.body))
                      (let
                        [id : i64
                          (compiler-stack-traffic-region-id
                            graph
                            unroll.unrolled)]
                        [guard : i64
                          (compiler-stack-traffic-region-id graph unroll.guard)]
                        [guard-cone : (__tl_dyn-array bool)
                          (compiler-stack-traffic-region-cone
                            (& context)
                            guard
                            exit)]
                        (for [block (iterator.range 0 count)]
                          (when
                            (array-ref guard-cone block)
                            (set! (array-ref cone block) true)))
                        (when
                          (and (>= id 0) (array-ref context.index.reachable id))
                          (let
                            [members : (__tl_dyn-array bool)
                              (compiler-stack-traffic-region-loop
                                (natural_loops.view loops)
                                unroll.unrolled
                                count)]
                            (when
                              (=
                                (compiler-stack-traffic-region-size (& members))
                                0)
                              (return
                                (Err
                                  "stack traffic: untracked committed unroll")))
                            (set!
                              (array-ref candidates used)
                              (CompilerStackTrafficRegionCandidate
                                (FullGang)
                                (clone anchor.site)
                                id
                                (compiler-stack-traffic-region-size (& members))
                                members))
                            (+= used 1)))))))
                (let
                  [size : i64 (compiler-stack-traffic-region-size (& cone))]
                  (for [block (iterator.range 0 count)]
                    (when
                      (and
                        (array-ref cone block)
                        (array-ref context.index.reachable block)
                        (< size (array-ref cold-sizes block)))
                      (set! (array-ref cold-sites block) source)
                      (set! (array-ref cold-sizes block) size))))))))
        ;; Larger containing sets precede children. Partially overlapping or
        ;; identical claims are ambiguous, including distinct sites with the
        ;; same final header, and therefore reject instead of double counting.
        (for [left (iterator.range 0 used)]
          (for [right (iterator.range (+ left 1) used)]
            (when
              (<
                (array-ref candidates left).size
                (array-ref candidates right).size)
              (let
                [swap : CompilerStackTrafficRegionCandidate
                  (clone (array-ref candidates left))]
                (set!
                  (array-ref candidates left)
                  (clone (array-ref candidates right)))
                (set! (array-ref candidates right) swap)))))
        (let
          [regions : (__tl_dyn-array traffic.CompilerStackTrafficRegion)
            (__tl_make-array traffic.CompilerStackTrafficRegion count)]
          [owners : (__tl_dyn-array i64) (__tl_make-array i64 count)]
          [region-count : i64 used]
          (when
            (> used count)
            (return (Err "stack traffic: too many source regions")))
          (for [block (iterator.range 0 count)]
            (set! (array-ref owners block) -1))
          (for [index (iterator.range 0 used)]
            (let
              [candidate : (& candidates CompilerStackTrafficRegionCandidate)
                (& (array-ref candidates index))]
              [parent : i64 -1]
              (for [previous (iterator.range 0 index)]
                (let
                  [other : (& candidates CompilerStackTrafficRegionCandidate)
                    (& (array-ref candidates previous))]
                  [intersection : i64 0]
                  (for [block (iterator.range 0 count)]
                    (when
                      (and
                        (array-ref candidate.members block)
                        (array-ref other.members block))
                      (+= intersection 1)))
                  (when
                    (> intersection 0)
                    (unless
                      (and
                        (= intersection candidate.size)
                        (< candidate.size other.size))
                      (return
                        (Err "stack traffic: ambiguous source-region overlap")))
                    (set! parent previous))))
              (set!
                (array-ref regions index)
                (traffic.CompilerStackTrafficRegion
                  (clone candidate.kind)
                  (Site
                    (clone candidate.site)
                    (ir.compiler-ir-symbol-id-text
                      (clone candidate.site.function)))
                  parent
                  candidate.header))
              (for [block (iterator.range 0 count)]
                (when
                  (array-ref candidate.members block)
                  (set! (array-ref owners block) index)))))
          (for [index (iterator.range 0 used)]
            (unless
              (= (array-ref owners (array-ref regions index).header) index)
              (return
                (Err "stack traffic: nested region takes its parent's header"))))
          ;; Every remaining block owns a singleton region. This includes
          ;; unreachable blocks: reachability never invents a hot attribution.
          (for [block (iterator.range 0 count)]
            (when
              (< (array-ref owners block) 0)
              (let
                [source : i64 (array-ref cold-sites block)]
                (set!
                  (array-ref regions region-count)
                  (traffic.CompilerStackTrafficRegion
                    (if (< source 0)
                      (Ordinary)
                      (Cold))
                    (if (< source 0)
                      (NoSite)
                      (let
                        [site : ir.CompilerSpmdSiteId
                          (clone (array-ref facts.loops.slots source).site)]
                        (Site
                          site
                          (ir.compiler-ir-symbol-id-text site.function))))
                    -1
                    block))
                (set! (array-ref owners block) region-count)
                (+= region-count 1))))
          (let
            [packed : (__tl_dyn-array traffic.CompilerStackTrafficRegion)
              (__tl_make-array traffic.CompilerStackTrafficRegion region-count)]
            (for [index (iterator.range 0 region-count)]
              (set! (array-ref packed index) (clone (array-ref regions index))))
            (Ok (CompilerStackTrafficPartition packed owners)))))]))