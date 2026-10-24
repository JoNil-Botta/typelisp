(import compiler_stack_traffic_regions as regions)
(import compiler_stack_traffic as traffic)
(import compiler_ir_types as ir)
(import compiler_ir_text as irt)
(import compiler_liveness as live)
(import compiler_owned_view as owned_view)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.io)
(import stdlib.test)

(define (stack-region-test-graph
  [function : (& ir.CompilerIrFunction)]
  [spare : bool]) : live.CompilerLiveBlockGraph
  (match function
    [(Function _ _ _ vars blocks _)
      (let
        [builder : ir.CompilerIrBlockBuilder
          (ir.compiler-ir-block-builder-with-capacity
            (+
              (ir.compiler-ir-block-list-count blocks)
              (if spare
                23
                0)))]
        (ir.compiler-ir-block-builder-append-list!
          (&mut builder)
          (owned_view.compiler-owned-reference-shared-view blocks))
        (let
          [seq : ir.CompilerIrBlockSeq
            (ir.compiler-ir-block-list-seq
              (ir.compiler-ir-block-builder-to-list builder))]
          (live.compiler-live-block-graph-build-from-array
            (live.compiler-live-build-block-array (& seq) vars))))]))

(define (stack-region-test-anchor!
  [facts : (&mut facts ir.CompilerSpmdDecisions)]
  [function : ir.CompilerIrSymbolId]
  [ordinal : i64]
  [header : String]
  [body : String]
  [tail : String]
  [exit : String]) : unit
  (ir.compiler-spmd-loop-region-list-push
    (&mut facts.loops)
    (ir.CompilerSpmdLoopRegion
      function
      (ir.CompilerSpmdSiteId function ordinal)
      (ir.compiler-ir-label header)
      (ir.compiler-ir-label body)
      (ir.compiler-ir-label tail)
      (ir.compiler-ir-label exit))))

(define (stack-region-test-assert
  [function : (& ir.CompilerIrFunction)]
  [graph : (& graph live.CompilerLiveBlockGraph)]
  [facts : (& ir.CompilerSpmdDecisions)]
  [expected : String]) : regions.CompilerStackTrafficPartition
  (match (regions.compiler-stack-traffic-partition function graph facts)
    [(Err message) (io.panic message)]
    [(Ok partition)
      (let
        [actual : String ""]
        (for [block (iterator.range 0 (array-length partition.blocks))]
          (let
            [token : String
              (match (&
                (array-ref partition.regions (array-ref partition.blocks block)).kind)
                [(Ordinary) "O"]
                [(FullGang) "F"]
                [(Tail) "T"]
                [(Cold) "C"])]
            (set! actual (string.concat actual token))))
        (test.assert-string-eq actual expected "final region attribution")
        (match function
          [(Function name _ _ _ _ _)
            (let
              [checked : traffic.CompilerStackTraffic
                (traffic.CompilerStackTraffic
                  (ir.compiler-ir-symbol-typed-id name)
                  (ir.compiler-ir-symbol-text name)
                  (Avx2)
                  (owned_view.compiler-owned-reference-shared-view graph)
                  (owned_view.compiler-owned-shared-view partition.regions)
                  (owned_view.compiler-owned-shared-view partition.blocks)
                  (__tl_make-array traffic.CompilerStackTrafficHome 0)
                  (__tl_make-array traffic.CompilerStackTrafficEvent 0))]
              (match (traffic.compiler-stack-traffic-check (& checked))
                [(Ok) unit]
                [(Err message) (io.panic message)]))]))
      partition]))

(define (stack-region-test-reject
  [function : (& ir.CompilerIrFunction)]
  [graph : (& live.CompilerLiveBlockGraph)]
  [facts : (& ir.CompilerSpmdDecisions)]) : unit
  (match (regions.compiler-stack-traffic-partition function graph facts)
    [(Err _) unit]
    [(Ok _)
      (test.assert-true false "malformed/ambiguous final mapping must reject")]))

(define (compiler-stack-traffic-region-tests) : unit
  (let
    [function : ir.CompilerIrFunction
      (irt.func
        "function @region() -> i64 vars 1 {
       entry:
         jump h
       h:
         branch %0, b, t
       b:
         branch %0, work, abort
       work:
         jump h
       t:
         branch %0, lane, finish
       lane:
         jump t
       finish:
         return 0
       abort:
         return 1
       dead:
         jump dead
       }")]
    [name : ir.CompilerIrSymbolId
      (match (& function)
        [(Function id _ _ _ _ _) (ir.compiler-ir-symbol-typed-id id)])]
    [facts : ir.CompilerSpmdDecisions (ir.compiler-spmd-decisions-empty)]
    (stack-region-test-anchor! (&mut facts) name 0 "h" "b" "t" "finish")
    (for [spare (iterator.range 0 2)]
      (let
        [graph : live.CompilerLiveBlockGraph
          (stack-region-test-graph (& function) (= spare 1))]
        [_partition : regions.CompilerStackTrafficPartition
          (stack-region-test-assert
            (& function)
            (& graph)
            (& facts)
            "OFFFTTOCO")]
        ;; Canonical reverse edges alone do not establish the graph's identity.
        (set! (array-ref graph.blocks 0).label (ir.compiler-ir-label "wrong"))
        (stack-region-test-reject (& function) (& graph) (& facts))))
    (let
      [graph : live.CompilerLiveBlockGraph
        (stack-region-test-graph (& function) false)]
      ;; Keep labels/order but substitute a different, internally canonical CFG.
      (set! (array-ref graph.successors 0).items (__tl_make-array i64 0))
      (set!
        graph.predecessors
        (live.compiler-live-predecessors-build (& graph.successors)))
      (stack-region-test-reject (& function) (& graph) (& facts)))
    (let
      [graph : live.CompilerLiveBlockGraph
        (stack-region-test-graph (& function) false)]
      [duplicate : ir.CompilerSpmdDecisions
        (ir.compiler-spmd-decisions-escape (& facts))]
      (stack-region-test-anchor! (&mut duplicate) name 1 "h" "b" "t" "finish")
      (stack-region-test-reject (& function) (& graph) (& duplicate))
      (ir.compiler-spmd-loop-unroll-list-push
        (&mut duplicate.unrolls)
        (ir.CompilerSpmdLoopUnroll
          name
          (ir.compiler-ir-label "b")
          (ir.compiler-ir-label "h")
          (ir.compiler-ir-label "work")
          (ir.compiler-ir-label "finish")))
      (stack-region-test-reject (& function) (& graph) (& duplicate)))
    (let
      [graph : live.CompilerLiveBlockGraph
        (stack-region-test-graph (& function) false)]
      [missing : ir.CompilerSpmdDecisions
        (ir.compiler-spmd-decisions-escape (& facts))]
      (set!
        (array-ref missing.loops.slots 0).body
        (ir.compiler-ir-label "retired"))
      (stack-region-test-reject (& function) (& graph) (& missing))
      (set! (array-ref missing.loops.slots 0).body (ir.compiler-ir-label "b"))
      (set!
        (array-ref missing.loops.slots 0).tail
        (ir.compiler-ir-label "work"))
      (stack-region-test-reject (& function) (& graph) (& missing)))
    (let
      [graph : live.CompilerLiveBlockGraph
        (stack-region-test-graph (& function) false)]
      (set!
        (array-ref facts.loops.slots 0).exit
        (ir.compiler-ir-label "removed"))
      (stack-region-test-reject (& function) (& graph) (& facts))))
  ;; Two distinct recurring bodies connected by an acyclic guard are never
  ;; fused into one SCC-based inventory. The source's obsolete header is gone.
  (let
    [function : ir.CompilerIrFunction
      (irt.func
        "function @unrolled() -> i64 vars 1 {
       entry:
         jump gate
       gate:
         branch %0, wide, rest
       wide:
         branch %0, wide, bridge
       bridge:
         jump rest
       rest:
         branch %0, rest, tail
       tail:
         jump done
       done:
         return 0
       }")]
    [name : ir.CompilerIrSymbolId
      (match (& function)
        [(Function id _ _ _ _ _) (ir.compiler-ir-symbol-typed-id id)])]
    [facts : ir.CompilerSpmdDecisions (ir.compiler-spmd-decisions-empty)]
    [graph : live.CompilerLiveBlockGraph
      (stack-region-test-graph (& function) false)]
    (stack-region-test-anchor!
      (&mut facts)
      name
      3
      "retired"
      "rest"
      "tail"
      "done")
    (ir.compiler-spmd-loop-unroll-list-push
      (&mut facts.unrolls)
      (ir.CompilerSpmdLoopUnroll
        name
        (ir.compiler-ir-label "rest")
        (ir.compiler-ir-label "gate")
        (ir.compiler-ir-label "wide")
        (ir.compiler-ir-label "bridge")))
    (let
      [partition : regions.CompilerStackTrafficPartition
        (stack-region-test-assert (& function) (& graph) (& facts) "OCFCFTO")]
      (test.assert-true
        (!= (array-ref partition.blocks 2) (array-ref partition.blocks 4))
        "unrolled and remainder have distinct headers"))
    (set!
      (array-ref facts.unrolls.slots 0).body
      (ir.compiler-ir-label "unbound"))
    (stack-region-test-reject (& function) (& graph) (& facts)))
  ;; Inner source traffic has its own owner and remains CFG control for the
  ;; enclosing gang. The smallest containing set is the preorder parent.
  (let
    [function : ir.CompilerIrFunction
      (irt.func
        "function @nested() -> i64 vars 1 {
       entry:
         jump outer
       outer:
         branch %0, outerbody, outertail
       outerbody:
         jump inner
       inner:
         branch %0, innerbody, innertail
       innerbody:
         jump inner
       innertail:
         jump innerdone
       innerdone:
         jump outer
       outertail:
         jump done
       done:
         return 0
       }")]
    [name : ir.CompilerIrSymbolId
      (match (& function)
        [(Function id _ _ _ _ _) (ir.compiler-ir-symbol-typed-id id)])]
    [facts : ir.CompilerSpmdDecisions (ir.compiler-spmd-decisions-empty)]
    [graph : live.CompilerLiveBlockGraph
      (stack-region-test-graph (& function) true)]
    (stack-region-test-anchor!
      (&mut facts)
      name
      0
      "outer"
      "outerbody"
      "outertail"
      "done")
    (stack-region-test-anchor!
      (&mut facts)
      name
      1
      "inner"
      "innerbody"
      "innertail"
      "innerdone")
    (let
      [partition : regions.CompilerStackTrafficPartition
        (stack-region-test-assert (& function) (& graph) (& facts) "OFFFFTFTO")]
      [outer : i64 (array-ref partition.blocks 1)]
      [inner : i64 (array-ref partition.blocks 3)]
      (test.assert-i64-eq
        (array-ref partition.regions inner).parent
        outer
        "nested full gang parent")
      (test.assert-i64-eq
        (array-ref partition.regions (array-ref partition.blocks 5)).parent
        outer
        "nested tail remains outer control")
      (test.assert-true
        (traffic.compiler-stack-traffic-full-gang?
          (& (array-ref partition.regions outer).kind))
        "outer header remains full gang")))
  ;; Unreachable, completely retired and scalar/fallback sites invent no hot
  ;; region. A live acyclic body without a tracked rewrite instead rejects.
  (let
    [function : ir.CompilerIrFunction
      (irt.func
        "function @ordinary() -> i64 vars 0 {
       entry:
         return 0
       dead:
         jump dead
       }")]
    [name : ir.CompilerIrSymbolId
      (match (& function)
        [(Function id _ _ _ _ _) (ir.compiler-ir-symbol-typed-id id)])]
    [facts : ir.CompilerSpmdDecisions (ir.compiler-spmd-decisions-empty)]
    [graph : live.CompilerLiveBlockGraph
      (stack-region-test-graph (& function) false)]
    [_empty : regions.CompilerStackTrafficPartition
      (stack-region-test-assert (& function) (& graph) (& facts) "OO")]
    (stack-region-test-anchor!
      (&mut facts)
      name
      0
      "dead"
      "dead"
      "retired"
      "entry")
    (let
      [_dead : regions.CompilerStackTrafficPartition
        (stack-region-test-assert (& function) (& graph) (& facts) "OO")]
      unit)
    (set! (array-ref facts.loops.slots 0).body (ir.compiler-ir-label "entry"))
    (stack-region-test-reject (& function) (& graph) (& facts))))