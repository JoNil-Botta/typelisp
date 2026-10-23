(import compiler_stack_traffic as traffic)
(import compiler_ir_types as ir)
(import compiler_ir_text as irt)
(import compiler_liveness as live)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.json)
(import stdlib.test)
(import stdlib.io)
(import stdlib.text_buf)

(define (stack-traffic-fixture [spare-capacity : bool]) : traffic.CompilerStackTraffic
  (match (irt.func
    "function @traffic() -> i64 vars 1 {
     entry:
       jump head
     head:
       branch %0, left, right
     left:
       jump join
     right:
       jump join
     join:
       branch %0, head, tail
     tail:
       branch %0, cold, exit
     cold:
       return 0
     exit:
       return 0
     dead:
       jump dead
     }")
    [(Function name _ _ vars blocks _)
      (let
        [builder : ir.CompilerIrBlockBuilder
          (ir.compiler-ir-block-builder-with-capacity
            (if spare-capacity
              32
              9))]
        [_ : unit
          (ir.compiler-ir-block-builder-append-list! (&mut builder) blocks)]
        [seq : ir.CompilerIrBlockSeq
          (ir.compiler-ir-block-list-seq
            (ir.compiler-ir-block-builder-to-list builder))]
        [graph : live.CompilerLiveBlockGraph
          (live.compiler-live-block-graph-build-from-array
            (live.compiler-live-build-block-array (& seq) vars))]
        [function : ir.CompilerIrSymbolId (ir.compiler-ir-symbol-typed-id name)]
        [regions : (__tl_dyn-array traffic.CompilerStackTrafficRegion)
          (__tl_make-array traffic.CompilerStackTrafficRegion 6)]
        [block-regions : (__tl_dyn-array i64) (__tl_make-array i64 9)]
        [homes : (__tl_dyn-array traffic.CompilerStackTrafficHome)
          (__tl_make-array traffic.CompilerStackTrafficHome 6)]
        [events : (__tl_dyn-array traffic.CompilerStackTrafficEvent)
          (__tl_make-array traffic.CompilerStackTrafficEvent 13)]
        [owners : (Array traffic.CompilerStackTrafficOwner 6)
          (array
            (Allocator)
            (PlannedScratch)
            (EmergencyScratch)
            (FixedScratch)
            (CallAbi)
            (UserLocal))]
        [banks : (Array traffic.CompilerStackTrafficBank 6)
          (array (Vector) (Mask) (General) (Bytes) (General) (Bytes))]
        [kinds : (Array traffic.CompilerStackTrafficRegionKind 6)
          (array (Ordinary) (FullGang) (Tail) (Cold) (Ordinary) (FullGang))]
        [headers : (Array i64 6) (array 0 1 5 6 7 8)]
        [members : (Array i64 9) (array 0 1 1 1 1 2 3 4 5)]
        (for [index (iterator.range 0 6)]
          (set!
            (array-ref regions index)
            (traffic.CompilerStackTrafficRegion
              (array-ref kinds index)
              (if (or (= index 0) (= index 4))
                (NoSite)
                (Site (ir.CompilerSpmdSiteId function 0) "traffic"))
              -1
              (array-ref headers index)))
          (set!
            (array-ref homes index)
            (traffic.CompilerStackTrafficHome
              (array-ref owners index)
              (array-ref banks index)
              8))
          (set!
            (array-ref events index)
            (traffic.CompilerStackTrafficEvent index 0 2 index (Write))))
        (for [index (iterator.range 0 9)]
          (set! (array-ref block-regions index) (array-ref members index)))
        ;; Mutually exclusive arms can execute in different iterations of
        ;; the same recurring region. A single iteration need not do both.
        (set!
          (array-ref events 6)
          (traffic.CompilerStackTrafficEvent 6 0 3 0 (Read)))
        (set!
          (array-ref events 7)
          (traffic.CompilerStackTrafficEvent 7 0 5 0 (ReadWrite)))
        (set!
          (array-ref events 8)
          (traffic.CompilerStackTrafficEvent 8 0 6 0 (ReadWrite)))
        (set!
          (array-ref events 9)
          (traffic.CompilerStackTrafficEvent 9 0 0 0 (ReadWrite)))
        (set!
          (array-ref events 10)
          (traffic.CompilerStackTrafficEvent 10 0 8 0 (ReadWrite)))
        (set!
          (array-ref events 11)
          (traffic.CompilerStackTrafficEvent 11 0 4 1 (Read)))
        (set!
          (array-ref events 12)
          (traffic.CompilerStackTrafficEvent 12 0 4 2 (ReadWrite)))
        (traffic.CompilerStackTraffic
          function
          (string.copy (& (ir.compiler-ir-symbol-text name)))
          (Avx2)
          graph
          regions
          block-regions
          homes
          events))]))

(define (stack-traffic-cycle-assert
  [facts : (& traffic.CompilerStackTraffic)]
  [region : i64]
  [home : i64]
  [reads : i64]
  [writes : i64]) : unit
  (match (traffic.compiler-stack-traffic-cycles facts region)
    [(Ok cycles)
      (test.assert-i64-eq
        (array-ref cycles home).reads
        reads
        "cycle read count")
      (test.assert-i64-eq
        (array-ref cycles home).writes
        writes
        "cycle write count")]
    [(Err message) (io.panic message)]))

(define (stack-traffic-cycles-test) : unit
  (let
    [facts : traffic.CompilerStackTraffic (stack-traffic-fixture false)]
    (stack-traffic-cycle-assert (& facts) 1 0 1 1)
    ;; Ownership is retained; graph facts do not implement warning policy.
    (stack-traffic-cycle-assert (& facts) 1 1 1 1)
    (stack-traffic-cycle-assert (& facts) 1 2 1 2)
    (for [home (iterator.range 3 6)]
      (stack-traffic-cycle-assert (& facts) 1 home 0 1))
    (for [region (iterator.range 2 6)]
      (stack-traffic-cycle-assert (& facts) region 0 0 0))
    (stack-traffic-cycle-assert (& facts) 0 0 0 0)
    ;; Removing the back edge makes all remaining accesses one-way.
    (set! (array-ref facts.graph.successors 4).items (__tl_make-array i64 0))
    (set! (array-ref facts.graph.predecessors 1).items (__tl_make-array i64 1))
    (set! (array-ref (array-ref facts.graph.predecessors 1).items 0) 0)
    (set! (array-ref facts.graph.predecessors 5).items (__tl_make-array i64 0))
    (stack-traffic-cycle-assert (& facts) 1 0 0 0)))

(define (stack-traffic-invalid-test) : unit
  (for [mutation (iterator.range 0 23)]
    (let
      [facts : traffic.CompilerStackTraffic (stack-traffic-fixture false)]
      (cond
        [(= mutation 0) (set! (array-ref facts.events 1).operation 0)]
        [(= mutation 1) (set! (array-ref facts.events 0).operation -1)]
        [(= mutation 2) (set! (array-ref facts.events 0).home 6)]
        [(= mutation 3) (set! (array-ref facts.events 0).block 9)]
        [(= mutation 4) (set! (array-ref facts.homes 0).bytes 0)]
        [(= mutation 5) (set! (array-ref facts.block-regions 0) 6)]
        [(= mutation 6) (set! (array-ref facts.regions 1).header 9)]
        [(= mutation 7) (set! (array-ref facts.regions 1).header 0)]
        [(= mutation 8) (set! (array-ref facts.regions 1).source (NoSite))]
        [(= mutation 9)
          (set!
            (array-ref facts.regions 0).source
            (Site (ir.CompilerSpmdSiteId facts.function 0) "traffic"))]
        [(= mutation 10)
          (set! (array-ref (array-ref facts.graph.successors 0).items 0) 9)]
        [(= mutation 11)
          (set! (array-ref (array-ref facts.graph.predecessors 1).items 0) 2)]
        [(= mutation 12) (set! (array-ref facts.regions 1).parent 1)]
        [(= mutation 13) (set! (array-ref facts.regions 1).parent -2)]
        [(= mutation 14)
          (set!
            (array-ref facts.regions 1).source
            (Site
              (ir.CompilerSpmdSiteId (ir.CompilerIrSymbolId -1) 0)
              "traffic"))]
        [(= mutation 15) (set! facts.function-name "")]
        [(= mutation 16) (set! facts.block-regions (__tl_make-array i64 0))]
        [(= mutation 17)
          (set!
            facts.graph.successors
            (__tl_make-array live.CompilerLiveIndexVec 0))]
        [(= mutation 18) (set! (array-ref facts.events 0).access-index -1)]
        [(= mutation 19) (set! facts.backend (Scalar))]
        [(= mutation 20)
          (set!
            (array-ref facts.regions 1).source
            (Site (ir.CompilerSpmdSiteId facts.function 0) ""))]
        [(= mutation 21)
          (set!
            (array-ref facts.regions 1).source
            (Site (ir.CompilerSpmdSiteId facts.function -1) "traffic"))]
        [else
          (set!
            (array-ref facts.regions 1).source
            (Site (ir.CompilerSpmdSiteId facts.function -2) "traffic"))])
      (match (traffic.compiler-stack-traffic-check (& facts))
        [(Err _) unit]
        [(Ok) (io.panic "stack traffic: malformed fact accepted")])
      (match (traffic.compiler-stack-traffic-render
        (& facts)
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        "source")
        [(Err _) unit]
        [(Ok _) (io.panic "stack traffic: rendered malformed facts")])
      (match (traffic.compiler-stack-traffic-cycles (& facts) 1)
        [(Err _) unit]
        [(Ok _) (io.panic "stack traffic: proved malformed cycle")]))))

(define (stack-traffic-render [facts : (& traffic.CompilerStackTraffic)]) : String
  (match (traffic.compiler-stack-traffic-render
    facts
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    "source\"\\\t\r\n")
    [(Ok text) text]
    [(Err message) (io.panic message)]))

(define (stack-traffic-render-test) : unit
  (let
    [facts : traffic.CompilerStackTraffic (stack-traffic-fixture false)]
    [spare : traffic.CompilerStackTraffic (stack-traffic-fixture true)]
    [text : String (stack-traffic-render (& facts))]
    (test.assert-true
      (string.eq (& text) (stack-traffic-render (& spare)))
      "canonical output ignores inactive IR capacity")
    (match (json.parse (& text))
      [(json.OkJson _) unit]
      [(json.ErrJson message) (io.panic message)])
    (for [index (iterator.range 0 6)]
      (let
        [name : String
          (traffic.compiler-stack-traffic-owner-name
            (& (array-ref facts.homes index).owner))]
        (match (traffic.compiler-stack-traffic-owner (& name))
          [(Ok owner)
            (test.assert-true
              (string.eq
                (& name)
                (traffic.compiler-stack-traffic-owner-name (& owner)))
              "owner round trip")]
          [(Err message) (io.panic message)])))
    (match (traffic.compiler-stack-traffic-owner "new-stack-kind")
      [(Err _) unit]
      [(Ok _) (io.panic "stack traffic: unknown owner accepted")])
    (for [digest
      (array
        ""
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde"
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0"
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeG"
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg")]
      (match (traffic.compiler-stack-traffic-render (& facts) digest "source")
        [(Err _) unit]
        [(Ok _) (io.panic "stack traffic: invalid compiler digest accepted")]))
    (match (traffic.compiler-stack-traffic-render
      (& facts)
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      "")
      [(Err _) unit]
      [(Ok _) (io.panic "stack traffic: missing source identity accepted")])
    (match (traffic.compiler-stack-traffic-cycles (& facts) 6)
      [(Err _) unit]
      [(Ok _) (io.panic "stack traffic: invalid query accepted")]))
  (let
    [facts : traffic.CompilerStackTraffic (stack-traffic-fixture false)]
    (set! facts.backend (Avx512))
    (match (json.parse (stack-traffic-render (& facts)))
      [(json.OkJson _) unit]
      [(json.ErrJson message) (io.panic message)])
    (set! facts.backend (Scalar))
    (for [region (iterator.range 0 6)]
      (set! (array-ref facts.regions region).kind (Ordinary))
      (set! (array-ref facts.regions region).source (NoSite)))
    (match (json.parse (stack-traffic-render (& facts)))
      [(json.OkJson _) unit]
      [(json.ErrJson message) (io.panic message)])))

(define (stack-traffic-boundaries-test) : unit
  (let
    [facts : traffic.CompilerStackTraffic (stack-traffic-fixture false)]
    [homes : (__tl_dyn-array traffic.CompilerStackTrafficHome)
      (__tl_make-array traffic.CompilerStackTrafficHome 1)]
    [regions : (__tl_dyn-array traffic.CompilerStackTrafficRegion)
      (__tl_make-array traffic.CompilerStackTrafficRegion 1)]
    [events : (__tl_dyn-array traffic.CompilerStackTrafficEvent)
      (__tl_make-array traffic.CompilerStackTrafficEvent 1)]
    [members : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [func : ir.CompilerIrFunction
      (irt.func
        "function @traffic() -> i64 vars 0 {
       entry:
         jump entry
       }")]
    (match func
      [(Function _ _ _ vars blocks _)
        (let
          [seq : ir.CompilerIrBlockSeq (ir.compiler-ir-block-list-seq blocks)]
          (set!
            facts.graph
            (live.compiler-live-block-graph-build-from-array
              (live.compiler-live-build-block-array (& seq) vars))))])
    (set!
      (array-ref homes 0)
      (traffic.CompilerStackTrafficHome (Allocator) (Vector) 32))
    (set!
      (array-ref regions 0)
      (traffic.CompilerStackTrafficRegion
        (FullGang)
        (Site (ir.CompilerSpmdSiteId facts.function 0) "traffic")
        -1
        0))
    (set!
      (array-ref events 0)
      (traffic.CompilerStackTrafficEvent 0 0 0 0 (ReadWrite)))
    (set! facts.homes homes)
    (set! facts.regions regions)
    (set! facts.events events)
    (set! facts.block-regions members)
    (stack-traffic-cycle-assert (& facts) 0 0 1 1)
    (match (traffic.compiler-stack-traffic-render
      (& facts)
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      "fixture")
      [(Ok text)
        (test.assert-true
          (string.eq
            (& text)
            "{\"schema\":\"typelisp-stack-traffic-v1\",\"compiler_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"source\":\"fixture\",\"function\":\"traffic\",\"backend\":\"avx2\",\"regions\":[{\"kind\":\"full-gang\",\"site\":0,\"source_function\":\"traffic\",\"parent\":-1,\"header\":0}],\"blocks\":[{\"region\":0,\"successors\":[0]}],\"homes\":[{\"owner\":\"allocator\",\"bank\":\"vector\",\"bytes\":32}],\"events\":[{\"operation\":0,\"access_index\":0,\"block\":0,\"home\":0,\"access\":\"read-write\"}]}\n")
          "versioned census golden")]
      [(Err message) (io.panic message)])
    ;; An empty function has no headers, homes or events, and no fabricated
    ;; loop witness. Rendering preserves the empty arrays explicitly.
    (set!
      facts.graph
      (live.compiler-live-block-graph-build-from-array
        (__tl_make-array live.CompilerLiveBlock 0)))
    (set! facts.homes (__tl_make-array traffic.CompilerStackTrafficHome 0))
    (set! facts.regions (__tl_make-array traffic.CompilerStackTrafficRegion 0))
    (set! facts.events (__tl_make-array traffic.CompilerStackTrafficEvent 0))
    (set! facts.block-regions (__tl_make-array i64 0))
    (match (traffic.compiler-stack-traffic-check (& facts))
      [(Ok) unit]
      [(Err message) (io.panic message)])
    (match (json.parse (stack-traffic-render (& facts)))
      [(json.OkJson _) unit]
      [(json.ErrJson message) (io.panic message)])
    (match (traffic.compiler-stack-traffic-cycles (& facts) 0)
      [(Err _) unit]
      [(Ok _) (io.panic "stack traffic: empty function has a cycle")]))
  (let
    [facts : traffic.CompilerStackTraffic (stack-traffic-fixture false)]
    ;; A nested region may carry a path back to the parent header. Its own
    ;; writes stay classified at that child and do not enter parent counts.
    (set! (array-ref facts.regions 4).kind (FullGang))
    (set!
      (array-ref facts.regions 4).source
      (Site (ir.CompilerSpmdSiteId facts.function 1) "traffic"))
    (set! (array-ref facts.regions 4).header 2)
    (set! (array-ref facts.regions 4).parent 1)
    (set! (array-ref facts.block-regions 2) 4)
    (set! (array-ref facts.block-regions 7) 0)
    (stack-traffic-cycle-assert (& facts) 1 0 1 0)
    (stack-traffic-cycle-assert (& facts) 4 0 0 0))
  (let
    [facts : traffic.CompilerStackTraffic (stack-traffic-fixture false)]
    ;; One instruction can read an explicit home and write an implicit ABI
    ;; home. Their access keys differ; ownership is still exactly once.
    (set! (array-ref facts.events 1).operation 0)
    (set! (array-ref facts.events 1).access-index 1)
    (match (traffic.compiler-stack-traffic-check (& facts))
      [(Ok) unit]
      [(Err message) (io.panic message)])))

(define (stack-traffic-inlined-source-test) : unit
  (let
    [facts : traffic.CompilerStackTraffic (stack-traffic-fixture false)]
    [callee : ir.CompilerIrSymbolId
      (ir.compiler-ir-symbol-typed-id (ir.compiler-ir-test-symbol "callee"))]
    (set!
      (array-ref facts.regions 1).source
      (Site (ir.CompilerSpmdSiteId callee 0) "callee"))
    (stack-traffic-cycle-assert (& facts) 1 0 1 1)
    (let
      [text : String (stack-traffic-render (& facts))]
      (test.assert-true
        (string.contains (& text) "\"function\":\"traffic\"")
        "emitted function retained")
      (test.assert-true
        (string.contains (& text) "\"source_function\":\"callee\"")
        "inlined source function retained")
      (match (json.parse (& text))
        [(json.OkJson _) unit]
        [(json.ErrJson message) (io.panic message)]))
    (set! (array-ref facts.regions 3).source (NoSite))
    (let
      [text : String (stack-traffic-render (& facts))]
      (test.assert-true
        (string.contains
          (& text)
          "\"kind\":\"cold\",\"site\":null,\"source_function\":null")
        "ordinary trap has no fabricated SPMD source"))))

;; Exhaust every directed graph on three vertices without self edges. Floyd's
;; transitive closure is an independent oracle for the worklist proof. Self
;; edges, disconnected components and region boundaries have separate cases.
(define (stack-traffic-graph-oracle-test) : unit
  (for [mask (iterator.range 0 64)]
    (let
      [text : text_buf.TextBuf (text_buf.empty)]
      [paths : (__tl_dyn-array bool) (__tl_make-array bool 9)]
      [regions : (__tl_dyn-array traffic.CompilerStackTrafficRegion)
        (__tl_make-array traffic.CompilerStackTrafficRegion 1)]
      [homes : (__tl_dyn-array traffic.CompilerStackTrafficHome)
        (__tl_make-array traffic.CompilerStackTrafficHome 1)]
      [members : (__tl_dyn-array i64) (__tl_make-array i64 3)]
      [events : (__tl_dyn-array traffic.CompilerStackTrafficEvent)
        (__tl_make-array traffic.CompilerStackTrafficEvent 3)]
      [expected : i64 0]
      (text_buf.append! text "function @graph() -> i64 vars 1 {\n")
      (for [block (iterator.range 0 3)]
        (let
          [left : i64 (% (+ block 1) 3)]
          [right : i64 (% (+ block 2) 3)]
          [has-left : bool (!= (bit-and mask (shl 1 (* block 2))) 0)]
          [has-right : bool (!= (bit-and mask (shl 1 (+ (* block 2) 1))) 0)]
          (set! (array-ref paths (+ (* block 3) left)) has-left)
          (set! (array-ref paths (+ (* block 3) right)) has-right)
          (set!
            (array-ref events block)
            (traffic.CompilerStackTrafficEvent block 0 block 0 (ReadWrite)))
          (text_buf.append! text "b")
          (text_buf.append-int! text block)
          (text_buf.append! text ":\n")
          (cond
            [(and has-left has-right)
              (text_buf.append! text "branch %0, b")
              (text_buf.append-int! text left)
              (text_buf.append! text ", b")
              (text_buf.append-int! text right)]
            [(or has-left has-right)
              (text_buf.append! text "jump b")
              (text_buf.append-int!
                text
                (if has-left
                  left
                  right))]
            [else (text_buf.append! text "return 0")])
          (text_buf.append! text "\n")))
      (text_buf.append! text "}")
      (for [via (iterator.range 0 3)]
        (for [from (iterator.range 0 3)]
          (for [to (iterator.range 0 3)]
            (when
              (and
                (array-ref paths (+ (* from 3) via))
                (array-ref paths (+ (* via 3) to)))
              (set! (array-ref paths (+ (* from 3) to)) true)))))
      (when
        (array-ref paths 0)
        (for [block (iterator.range 0 3)]
          (when
            (and (array-ref paths block) (array-ref paths (* block 3)))
            (set! expected (+ expected 1)))))
      (match (irt.func (text_buf.render text))
        [(Function name _ _ vars blocks _)
          (let
            [function : ir.CompilerIrSymbolId
              (ir.compiler-ir-symbol-typed-id name)]
            [seq : ir.CompilerIrBlockSeq (ir.compiler-ir-block-list-seq blocks)]
            [graph : live.CompilerLiveBlockGraph
              (live.compiler-live-block-graph-build-from-array
                (live.compiler-live-build-block-array (& seq) vars))]
            [_ : unit
              (begin
                (set!
                  (array-ref regions 0)
                  (traffic.CompilerStackTrafficRegion
                    (FullGang)
                    (Site (ir.CompilerSpmdSiteId function 0) "graph")
                    -1
                    0))
                (set!
                  (array-ref homes 0)
                  (traffic.CompilerStackTrafficHome (Allocator) (Mask) 8)))]
            [facts : traffic.CompilerStackTraffic
              (traffic.CompilerStackTraffic
                function
                "graph"
                (Avx512)
                graph
                regions
                members
                homes
                events)]
            (stack-traffic-cycle-assert (& facts) 0 0 expected expected))]))))

(define (compiler-stack-traffic-self-test) : unit
  (stack-traffic-cycles-test)
  (stack-traffic-invalid-test)
  (stack-traffic-render-test)
  (stack-traffic-boundaries-test)
  (stack-traffic-inlined-source-test)
  (stack-traffic-graph-oracle-test))

(test stack-traffic-facts-and-cycles (compiler-stack-traffic-self-test))