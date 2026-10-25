;; Typed post-regalloc evidence boundary for #7236 and its #7294 consumer.
;; The producer owns classification: physical offsets and assembly spellings
;; cannot establish a logical home, source site, or steady-gang membership.
(import compiler_ir_types as ir)
(import compiler_liveness as live)
(import stdlib.string)
(import stdlib.json)
(import stdlib.text_buf)
(import stdlib.iterator)

(defenum CompilerStackTrafficOwner
  (Allocator)
  (PlannedScratch)
  (EmergencyScratch)
  (FixedScratch)
  (CallAbi)
  (UserLocal))

(defenum CompilerStackTrafficBank
  (General)
  (Vector)
  (Mask)
  (Bytes))

(defenum CompilerStackTrafficAccess
  (Read)
  (Write)
  (ReadWrite))

(defenum CompilerStackTrafficRegionKind
  (Ordinary)
  (FullGang)
  (Tail)
  (Cold))

;; Source identity survives inlining into a different emitted function. The
;; spelling is snapshotted with the site's owner. Ordinary cold traps need no
;; fabricated SPMD site; full-gang and tail regions require a real one.
(defenum CompilerStackTrafficSource
  (NoSite)
  (Site ir.CompilerSpmdSiteId String))

(defstruct CompilerStackTrafficRegion
  (kind CompilerStackTrafficRegionKind)
  (source CompilerStackTrafficSource)
  ;; Preorder parent, or -1. Nested regions participate in the parent's CFG
  ;; paths but keep their own traffic classification and source identity.
  (parent i64)
  (header i64))

;; The array index names one logical owner throughout this function's census.
;; Slot coloring may give distinct homes the same offset; that never merges
;; them. These local keys are not persistent source-diagnostic identities.
(defstruct CompilerStackTrafficHome
  (owner CompilerStackTrafficOwner)
  (bank CompilerStackTrafficBank)
  (bytes i64))

;; `operation` is the producer's final emitted instruction ordinal, not an IR
;; var or a frame offset. `access-index` distinguishes explicit/implicit memory
;; accesses of one instruction in execution order (e.g. push reads its source
;; before writing the implicit stack home). Each pair has one owner. Within a
;; ReadWrite access the read precedes the write; it is not its own round trip.
(defstruct CompilerStackTrafficEvent
  (operation i64)
  (access-index i64)
  (block i64)
  (home i64)
  (access CompilerStackTrafficAccess))

(defstruct CompilerStackTraffic
  (function ir.CompilerIrSymbolId)
  ;; Snapshot from the function's owning symbol table, before it retires.
  (function-name String)
  (backend ir.CompilerSpmdBackend)
  (graph live.CompilerLiveBlockGraph)
  (regions (__tl_dyn-array CompilerStackTrafficRegion))
  (block-regions (__tl_dyn-array i64))
  (homes (__tl_dyn-array CompilerStackTrafficHome))
  (events (__tl_dyn-array CompilerStackTrafficEvent)))

(defenum CompilerStackTrafficCheck
  (Ok)
  (Err String))

(defenum CompilerStackTrafficOwnerResult
  (Ok CompilerStackTrafficOwner)
  (Err String))

(defstruct CompilerStackTrafficRecurringAccesses
  (reads i64)
  (writes i64))

(defenum CompilerStackTrafficRecurringResult
  (Ok (__tl_dyn-array CompilerStackTrafficRecurringAccesses))
  (Err String))

;; Event indices name a same-home write followed by a later read before the
;; next visit to the region header. The bool says at least one CFG edge is
;; crossed between them. A repeated block may read an earlier static event;
;; that requires a nonempty path which does not revisit the region header.
(defenum CompilerStackTrafficCycle
  (NoCycle)
  (Ordered i64 i64 bool))

(defenum CompilerStackTrafficCycleResult
  (Ok (__tl_dyn-array CompilerStackTrafficCycle))
  (Err String))

(defenum CompilerStackTrafficTextResult
  (Ok String)
  (Err String))

(define (compiler-stack-traffic-owner-name
  [owner : (& CompilerStackTrafficOwner)]) : String
  (match owner
    [(Allocator) "allocator"]
    [(PlannedScratch) "planned-scratch"]
    [(EmergencyScratch) "emergency-scratch"]
    [(FixedScratch) "fixed-scratch"]
    [(CallAbi) "call-abi"]
    [(UserLocal) "user-local"]))

;; Unknown owner names have no default. In particular they are never spills.
(define (compiler-stack-traffic-owner [name : (& str)]) : CompilerStackTrafficOwnerResult
  (cond
    [(string.eq name "allocator") (Ok (Allocator))]
    [(string.eq name "planned-scratch") (Ok (PlannedScratch))]
    [(string.eq name "emergency-scratch") (Ok (EmergencyScratch))]
    [(string.eq name "fixed-scratch") (Ok (FixedScratch))]
    [(string.eq name "call-abi") (Ok (CallAbi))]
    [(string.eq name "user-local") (Ok (UserLocal))]
    [else (Err "stack traffic: unknown owner")]))

(define (compiler-stack-traffic-region-name
  [kind : (& CompilerStackTrafficRegionKind)]) : String
  (match kind
    [(Ordinary) "ordinary"]
    [(FullGang) "full-gang"]
    [(Tail) "tail"]
    [(Cold) "cold"]))

(define (compiler-stack-traffic-bank-name [bank : (& CompilerStackTrafficBank)]) : String
  (match bank
    [(General) "general"]
    [(Vector) "vector"]
    [(Mask) "mask"]
    [(Bytes) "bytes"]))

(define (compiler-stack-traffic-access-name
  [access : (& CompilerStackTrafficAccess)]) : String
  (match access
    [(Read) "read"]
    [(Write) "write"]
    [(ReadWrite) "read-write"]))

(define (compiler-stack-traffic-read? [access : (& CompilerStackTrafficAccess)]) : bool
  (match access
    [(Read) true]
    [(Write) false]
    [(ReadWrite) true]))

(define (compiler-stack-traffic-write?
  [access : (& CompilerStackTrafficAccess)]) : bool
  (match access
    [(Read) false]
    [(Write) true]
    [(ReadWrite) true]))

(define (compiler-stack-traffic-full-gang?
  [kind : (& CompilerStackTrafficRegionKind)]) : bool
  (match kind
    [(FullGang) true]
    [(Ordinary) false]
    [(Tail) false]
    [(Cold) false]))

(define (compiler-stack-traffic-graph-check
  [graph : (& graph live.CompilerLiveBlockGraph)]) : CompilerStackTrafficCheck
  (let
    [count : i64 (array-length graph.blocks)]
    (when
      (or
        (!= (array-length graph.successors) count)
        (!= (array-length graph.predecessors) count))
      (return (Err "stack traffic: graph extent mismatch")))
    (for [block (iterator.range 0 count)]
      (let
        [successors : (& graph live.CompilerLiveIndexVec)
          (& (array-ref graph.successors block))]
        [predecessors : (& graph live.CompilerLiveIndexVec)
          (& (array-ref graph.predecessors block))]
        (for [edge (iterator.range 0 (array-length successors.items))]
          (let
            [target : i64 (array-ref successors.items edge)]
            (when
              (or (< target 0) (>= target count))
              (return (Err "stack traffic: invalid successor")))))
        (for [edge (iterator.range 0 (array-length predecessors.items))]
          (let
            [source : i64 (array-ref predecessors.items edge)]
            (when
              (or (< source 0) (>= source count))
              (return (Err "stack traffic: invalid predecessor")))))))
    ;; Reuse the canonical linear reverse-edge builder. All-pairs membership
    ;; probes would make a large switch join quadratic in its predecessor count.
    (let
      [expected : (__tl_dyn-array live.CompilerLiveIndexVec)
        (live.compiler-live-predecessors-build (& graph.successors))]
      (for [block (iterator.range 0 count)]
        (let
          [wanted : (& expected live.CompilerLiveIndexVec)
            (& (array-ref expected block))]
          [actual : (& graph live.CompilerLiveIndexVec)
            (& (array-ref graph.predecessors block))]
          (when
            (!= (array-length wanted.items) (array-length actual.items))
            (return (Err "stack traffic: inconsistent reverse edges")))
          (for [index (iterator.range 0 (array-length wanted.items))]
            (when
              (!= (array-ref wanted.items index) (array-ref actual.items index))
              (return (Err "stack traffic: noncanonical reverse edges")))))))
    (Ok)))

(define (compiler-stack-traffic-check [facts : (& facts CompilerStackTraffic)]) : CompilerStackTrafficCheck
  (match (compiler-stack-traffic-graph-check (& facts.graph))
    [(Err message) (return (Err message))]
    [(Ok) unit])
  (let
    [blocks : i64 (array-length facts.graph.blocks)]
    [regions : i64 (array-length facts.regions)]
    [homes : i64 (array-length facts.homes)]
    [previous-operation : i64 -1]
    [previous-access : i64 -1]
    [previous-block : i64 -1]
    (when
      (or
        (< facts.function.value 0)
        (= (string.string-length (& facts.function-name)) 0))
      (return (Err "stack traffic: missing source function")))
    (when
      (!= (array-length facts.block-regions) blocks)
      (return (Err "stack traffic: block-region extent mismatch")))
    (for [block (iterator.range 0 blocks)]
      (let
        [region : i64 (array-ref facts.block-regions block)]
        (when
          (or (< region 0) (>= region regions))
          (return (Err "stack traffic: unknown block region")))))
    (for [index (iterator.range 0 regions)]
      (let
        [region : (& facts CompilerStackTrafficRegion)
          (& (array-ref facts.regions index))]
        (when
          (or (< region.parent -1) (>= region.parent index))
          (return (Err "stack traffic: invalid region parent")))
        (when
          (or (< region.header 0) (>= region.header blocks))
          (return (Err "stack traffic: invalid region header")))
        (when
          (!= (array-ref facts.block-regions region.header) index)
          (return (Err "stack traffic: region does not own its header")))
        (match region.source
          [(NoSite)
            (match region.kind
              [(or (FullGang) (Tail))
                (return (Err "stack traffic: missing SPMD site"))]
              [(or (Ordinary) (Cold)) unit])]
          [(Site site function-name)
            (match region.kind
              [(Ordinary)
                (return (Err "stack traffic: ordinary region has a SPMD site"))]
              [(or (FullGang) (Tail) (Cold)) unit])
            (when
              (or
                (< site.ordinal 0)
                (< site.function.value 0)
                (= (string.string-length (& function-name)) 0))
              (return (Err "stack traffic: invalid SPMD site")))])
        (when
          (compiler-stack-traffic-full-gang? (& region.kind))
          (match facts.backend
            [(Scalar) (return (Err "stack traffic: scalar full-gang region"))]
            [(or (Avx2) (Avx512)) unit]))))
    (for [index (iterator.range 0 homes)]
      (when
        (<= (array-ref facts.homes index).bytes 0)
        (return (Err "stack traffic: invalid home width"))))
    (for [index (iterator.range 0 (array-length facts.events))]
      (let
        [event : (& facts CompilerStackTrafficEvent)
          (& (array-ref facts.events index))]
        (when
          (or
            (< event.operation 0)
            (< event.access-index 0)
            (< event.operation previous-operation)
            (and
              (= event.operation previous-operation)
              (<= event.access-index previous-access)))
          (return (Err "stack traffic: duplicate or unordered operation")))
        (when
          (and
            (= event.operation previous-operation)
            (!= event.block previous-block))
          (return (Err "stack traffic: operation spans multiple blocks")))
        (set! previous-operation event.operation)
        (set! previous-access event.access-index)
        (set! previous-block event.block)
        (when
          (or (< event.block 0) (>= event.block blocks))
          (return (Err "stack traffic: unknown event block")))
        (when
          (or (< event.home 0) (>= event.home homes))
          (return (Err "stack traffic: unknown event home")))))
    (Ok)))

(define (compiler-stack-traffic-member?
  [facts : (& facts CompilerStackTraffic)]
  [block : i64]
  [region : i64]) : bool
  (if (< region 0)
    true
    (let
      [current : i64 (array-ref facts.block-regions block)]
      (while (>= current 0)
        (when (= current region) (return true))
        (set! current (array-ref facts.regions current).parent))
      false)))

;; Reachability uses the canonical CFG's indexed adjacency, restricted to one
;; producer-owned region. No loop/header guess is made from assembly labels.
(define (compiler-stack-traffic-reach
  [facts : (& facts CompilerStackTraffic)]
  [region : i64]
  [reverse : bool]) : (__tl_dyn-array bool)
  (let
    [count : i64 (array-length facts.graph.blocks)]
    [seen : (__tl_dyn-array bool) (__tl_make-array bool count)]
    [queue : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [head : i64 0]
    [tail : i64 1]
    [root : i64
      (if (< region 0)
        0
        (array-ref facts.regions region).header)]
    (set! (array-ref seen root) true)
    (set! (array-ref queue 0) root)
    (while (< head tail)
      (let
        [block : i64 (array-ref queue head)]
        [edges : (& facts live.CompilerLiveIndexVec)
          (if reverse
            (& (array-ref facts.graph.predecessors block))
            (& (array-ref facts.graph.successors block)))]
        (for [edge (iterator.range 0 (array-length edges.items))]
          (let
            [next : i64 (array-ref edges.items edge)]
            (when
              (and
                (compiler-stack-traffic-member? facts next region)
                (not (array-ref seen next)))
              (set! (array-ref seen next) true)
              (set! (array-ref queue tail) next)
              (set! tail (+ tail 1))))))
      (set! head (+ head 1)))
    seen))

;; Precondition: `check` succeeded, and region is in range. This is a
;; inventory, not an ordered write/read proof. Mutually exclusive arms may
;; contribute different directions on different iterations. An acyclic
;; header's zero-length path is not recurrence.
(define (compiler-stack-traffic-recurring-accesses-checked
  [facts : (& facts CompilerStackTraffic)]
  [region : i64]) : (__tl_dyn-array CompilerStackTrafficRecurringAccesses)
  (let
    [cycles : (__tl_dyn-array CompilerStackTrafficRecurringAccesses)
      (__tl_make-array
        CompilerStackTrafficRecurringAccesses
        (array-length facts.homes))]
    (if (not
      (compiler-stack-traffic-full-gang?
        (& (array-ref facts.regions region).kind)))
      cycles
      (let
        [entry : (__tl_dyn-array bool)
          (compiler-stack-traffic-reach facts -1 false)]
        [forward : (__tl_dyn-array bool)
          (compiler-stack-traffic-reach facts region false)]
        [backward : (__tl_dyn-array bool)
          (compiler-stack-traffic-reach facts region true)]
        [header : i64 (array-ref facts.regions region).header]
        [predecessors : (& facts live.CompilerLiveIndexVec)
          (& (array-ref facts.graph.predecessors header))]
        [recurs : bool false]
        (for [index (iterator.range 0 (array-length predecessors.items))]
          (let
            [source : i64 (array-ref predecessors.items index)]
            (when
              (and
                (compiler-stack-traffic-member? facts source region)
                (array-ref forward source))
              (set! recurs true))))
        (when
          (and recurs (array-ref entry header))
          (for [index (iterator.range 0 (array-length facts.events))]
            (let
              [event : (& facts CompilerStackTrafficEvent)
                (& (array-ref facts.events index))]
              (when
                (and
                  (= (array-ref facts.block-regions event.block) region)
                  (array-ref forward event.block)
                  (array-ref backward event.block))
                (when
                  (compiler-stack-traffic-read? (& event.access))
                  (set!
                    (array-ref cycles event.home).reads
                    (+ (array-ref cycles event.home).reads 1)))
                (when
                  (compiler-stack-traffic-write? (& event.access))
                  (set!
                    (array-ref cycles event.home).writes
                    (+ (array-ref cycles event.home).writes 1)))))))
        cycles))))

(define (compiler-stack-traffic-recurring-accesses
  [facts : (& facts CompilerStackTraffic)]
  [region : i64]) : CompilerStackTrafficRecurringResult
  (match (compiler-stack-traffic-check facts)
    [(Err message) (return (Err message))]
    [(Ok) unit])
  (if (or (< region 0) (>= region (array-length facts.regions)))
    (Err "stack traffic: cycle query outside census")
    (Ok (compiler-stack-traffic-recurring-accesses-checked facts region))))

;; One search per home, not per write. Reads are visited before writes within
;; each event. Every seed is after a reachable write and every queued block
;; is entered in full, so even a ReadWrite event can be read only on a later
;; event or a later block execution. Never enqueue the region header: taking
;; that edge ends the iteration. Reverse reachability proves a return after
;; the read; child blocks can carry paths but cannot contribute parent events.
(define (compiler-stack-traffic-cycle-home
  [facts : (& facts CompilerStackTraffic)]
  [region : i64]
  [home : i64]
  [forward : (& (__tl_dyn-array bool))]
  [backward : (& (__tl_dyn-array bool))]) : CompilerStackTrafficCycle
  (let
    [blocks : i64 (array-length facts.graph.blocks)]
    [writes : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [reads : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [origins : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [queue : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [head : i64 0]
    [tail : i64 0]
    [header : i64 (array-ref facts.regions region).header]
    (for [block (iterator.range 0 blocks)]
      (set! (array-ref writes block) -1)
      (set! (array-ref reads block) -1)
      (set! (array-ref origins block) -1))
    (for [index (iterator.range 0 (array-length facts.events))]
      (let
        [event : (& facts CompilerStackTrafficEvent)
          (& (array-ref facts.events index))]
        (when
          (and
            (= event.home home)
            (= (array-ref facts.block-regions event.block) region)
            (array-ref forward event.block)
            (array-ref backward event.block))
          (when
            (compiler-stack-traffic-read? (& event.access))
            (when
              (< (array-ref reads event.block) 0)
              (set! (array-ref reads event.block) index))
            (when
              (>= (array-ref writes event.block) 0)
              (return (Ordered (array-ref writes event.block) index false))))
          (when
            (and
              (compiler-stack-traffic-write? (& event.access))
              (< (array-ref writes event.block) 0))
            (set! (array-ref writes event.block) index)))))
    ;; Seed complete successor-block visits. A return to the write block can
    ;; legitimately reach a statically earlier read on an inner cycle.
    (for [block (iterator.range 0 blocks)]
      (when
        (>= (array-ref writes block) 0)
        (let
          [edges : (& facts live.CompilerLiveIndexVec)
            (& (array-ref facts.graph.successors block))]
          (for [edge (iterator.range 0 (array-length edges.items))]
            (let
              [target : i64 (array-ref edges.items edge)]
              (when
                (and
                  (!= target header)
                  (< (array-ref origins target) 0)
                  (compiler-stack-traffic-member? facts target region)
                  (array-ref backward target))
                (set! (array-ref origins target) (array-ref writes block))
                (set! (array-ref queue tail) target)
                (set! tail (+ tail 1))))))))
    (while (< head tail)
      (let
        [block : i64 (array-ref queue head)]
        [origin : i64 (array-ref origins block)]
        [edges : (& facts live.CompilerLiveIndexVec)
          (& (array-ref facts.graph.successors block))]
        (when
          (>= (array-ref reads block) 0)
          (return (Ordered origin (array-ref reads block) true)))
        (for [edge (iterator.range 0 (array-length edges.items))]
          (let
            [target : i64 (array-ref edges.items edge)]
            (when
              (and
                (!= target header)
                (< (array-ref origins target) 0)
                (compiler-stack-traffic-member? facts target region)
                (array-ref backward target))
              (set! (array-ref origins target) origin)
              (set! (array-ref queue tail) target)
              (set! tail (+ tail 1))))))
      (set! head (+ head 1)))
    (NoCycle)))

;; Checked structural proof only: no allocator, bank or warning selection.
;; Positive SCC counts are merely a prefilter; the witness additionally
;; requires temporal order on one path before the next header visit.
(define (compiler-stack-traffic-cycles-checked
  [facts : (& facts CompilerStackTraffic)]
  [region : i64]) : (__tl_dyn-array CompilerStackTrafficCycle)
  (let
    [counts : (__tl_dyn-array CompilerStackTrafficRecurringAccesses)
      (compiler-stack-traffic-recurring-accesses-checked facts region)]
    [cycles : (__tl_dyn-array CompilerStackTrafficCycle)
      (__tl_make-array CompilerStackTrafficCycle (array-length facts.homes))]
    [forward : (__tl_dyn-array bool)
      (compiler-stack-traffic-reach facts region false)]
    [backward : (__tl_dyn-array bool)
      (compiler-stack-traffic-reach facts region true)]
    (for [home (iterator.range 0 (array-length facts.homes))]
      (set! (array-ref cycles home) (NoCycle))
      (when
        (and
          (> (array-ref counts home).reads 0)
          (> (array-ref counts home).writes 0))
        (set!
          (array-ref cycles home)
          ;; Clone only the witness out; per-home worklists are reclaimed.
          (with-scratch
            (compiler-stack-traffic-cycle-home
              facts
              region
              home
              (& forward)
              (& backward))))))
    cycles))

(define (compiler-stack-traffic-cycles
  [facts : (& facts CompilerStackTraffic)]
  [region : i64]) : CompilerStackTrafficCycleResult
  (match (compiler-stack-traffic-check facts)
    [(Err message) (return (Err message))]
    [(Ok) unit])
  (if (or (< region 0) (>= region (array-length facts.regions)))
    (Err "stack traffic: cycle query outside census")
    (Ok (compiler-stack-traffic-cycles-checked facts region))))

(define (compiler-stack-traffic-json-text [text : String]) : String
  (json.stringify (json.JsonString text)))

(define (compiler-stack-traffic-sha256? [text : (& text str)]) : bool
  (if (!= (string.string-length text) 64)
    false
    (begin
      (for [index (iterator.range 0 64)]
        (let
          [c : char (string.char-at text index)]
          (when
            (not (or (and (>= c '0') (<= c '9')) (and (>= c 'a') (<= c 'f'))))
            (return false))))
      true)))

;; The renderer accepts only checked facts and explicit producer identities.
;; Array order is the canonical function/block/region/home/operation order
;; supplied by the producer; hash-table iteration never determines the schema.
(define (compiler-stack-traffic-render
  [facts : (& facts CompilerStackTraffic)]
  [compiler-sha256 : String]
  [source-identity : String]) : CompilerStackTrafficTextResult
  (match (compiler-stack-traffic-check facts)
    [(Err message) (return (Err message))]
    [(Ok) unit])
  (when
    (or
      (not (compiler-stack-traffic-sha256? (& compiler-sha256)))
      (= (string.string-length (& source-identity)) 0))
    (return (Err "stack traffic: missing producer identity")))
  (let
    [out : text_buf.TextBuf (text_buf.empty)]
    (text_buf.append!
      out
      "{\"schema\":\"typelisp-stack-traffic-v1\",\"compiler_sha256\":")
    (text_buf.append! out (compiler-stack-traffic-json-text compiler-sha256))
    (text_buf.append! out ",\"source\":")
    (text_buf.append! out (compiler-stack-traffic-json-text source-identity))
    (text_buf.append! out ",\"function\":")
    (text_buf.append!
      out
      (compiler-stack-traffic-json-text (string.copy (& facts.function-name))))
    (text_buf.append! out ",\"backend\":")
    (text_buf.append!
      out
      (compiler-stack-traffic-json-text
        (match facts.backend
          [(Scalar) "scalar"]
          [(Avx2) "avx2"]
          [(Avx512) "avx512"])))
    (text_buf.append! out ",\"regions\":[")
    (for [index (iterator.range 0 (array-length facts.regions))]
      (let
        [region : (& facts CompilerStackTrafficRegion)
          (& (array-ref facts.regions index))]
        (when (> index 0) (text_buf.append! out ","))
        (text_buf.append! out "{\"kind\":")
        (text_buf.append!
          out
          (compiler-stack-traffic-json-text
            (compiler-stack-traffic-region-name (& region.kind))))
        (text_buf.append! out ",\"site\":")
        (match region.source
          [(NoSite) (text_buf.append! out "null,\"source_function\":null")]
          [(Site site function-name)
            (text_buf.append-int! out site.ordinal)
            (text_buf.append! out ",\"source_function\":")
            (text_buf.append!
              out
              (compiler-stack-traffic-json-text (string.copy (& function-name))))])
        (text_buf.append! out ",\"parent\":")
        (text_buf.append-int! out region.parent)
        (text_buf.append! out ",\"header\":")
        (text_buf.append-int! out region.header)
        (text_buf.append! out "}")))
    (text_buf.append! out "],\"blocks\":[")
    (for [index (iterator.range 0 (array-length facts.graph.blocks))]
      (let
        [edges : (& facts live.CompilerLiveIndexVec)
          (& (array-ref facts.graph.successors index))]
        (when (> index 0) (text_buf.append! out ","))
        (text_buf.append! out "{\"region\":")
        (text_buf.append-int! out (array-ref facts.block-regions index))
        (text_buf.append! out ",\"successors\":[")
        (for [edge (iterator.range 0 (array-length edges.items))]
          (when (> edge 0) (text_buf.append! out ","))
          (text_buf.append-int! out (array-ref edges.items edge)))
        (text_buf.append! out "]}")))
    (text_buf.append! out "],\"homes\":[")
    (for [index (iterator.range 0 (array-length facts.homes))]
      (let
        [home : (& facts CompilerStackTrafficHome)
          (& (array-ref facts.homes index))]
        (when (> index 0) (text_buf.append! out ","))
        (text_buf.append! out "{\"owner\":")
        (text_buf.append!
          out
          (compiler-stack-traffic-json-text
            (compiler-stack-traffic-owner-name (& home.owner))))
        (text_buf.append! out ",\"bank\":")
        (text_buf.append!
          out
          (compiler-stack-traffic-json-text
            (compiler-stack-traffic-bank-name (& home.bank))))
        (text_buf.append! out ",\"bytes\":")
        (text_buf.append-int! out home.bytes)
        (text_buf.append! out "}")))
    (text_buf.append! out "],\"events\":[")
    (for [index (iterator.range 0 (array-length facts.events))]
      (let
        [event : (& facts CompilerStackTrafficEvent)
          (& (array-ref facts.events index))]
        (when (> index 0) (text_buf.append! out ","))
        (text_buf.append! out "{\"operation\":")
        (text_buf.append-int! out event.operation)
        (text_buf.append! out ",\"access_index\":")
        (text_buf.append-int! out event.access-index)
        (text_buf.append! out ",\"block\":")
        (text_buf.append-int! out event.block)
        (text_buf.append! out ",\"home\":")
        (text_buf.append-int! out event.home)
        (text_buf.append! out ",\"access\":")
        (text_buf.append!
          out
          (compiler-stack-traffic-json-text
            (compiler-stack-traffic-access-name (& event.access))))
        (text_buf.append! out "}")))
    (text_buf.append! out "]}\n")
    (Ok (text_buf.render out))))