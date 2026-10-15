;; Synthetic executor/oracle and hostile serial-protocol inputs (#7188).
(import compiler_incremental_plan as plan)
(import compiler_incremental_graph as graph)
(import compiler_incremental_identity as identity)
(import compiler_incremental_trace as trace)
(import compiler_incremental_binary as binary)
(import compiler_incremental_graph_tests as fixture)
(import stdlib.string)
(import stdlib.vector)
(import stdlib.byte_buf_core)
(import stdlib.byte_le)
(import stdlib.crypto_sha256 as sha256)
(import (stdlib.vector.vector trace.CompilerIncrementalTraceRecord) as record_vec)

(define (plan-test-stop) : never
  (string.tl_oob_abort))

(define (plan-test-require [ok? : bool]) : unit
  (unless ok? (plan-test-stop)))

(define (plan-test-unwrap [value : plan.ResultCompilerIncrementalPlan]) : plan.CompilerIncrementalPlan
  (match value
    [(Ok state) state]
    [_ (plan-test-stop)]))

(define (plan-test-record
  [edge : (& edge trace.CompilerIncrementalTraceEdge)]
  [query : (& query identity.CompilerIncrementalIdentity)]) : trace.CompilerIncrementalTraceRecord
  (let
    [limits : trace.CompilerIncrementalTraceLimits
      (trace.compiler-trace-default-limits)]
    (match (trace.compiler-trace-record edge query (& limits))
      [(Ok record) record]
      [_ (plan-test-stop)])))

(define (plan-test-source [seed : i64]) : trace.CompilerIncrementalTraceEdge
  (trace.CompilerIncrementalTraceEdge
    (Source "src/app.tl")
    (Source
      (Present
        (identity.CompilerIncrementalContentIdentity
          "typelisp.source-content"
          1
          seed
          (fixture.graph-test-digest seed))))))

(define (plan-test-input
  [kind : i64]
  [length : i64]
  [edge : trace.CompilerIncrementalTraceEdge]) : plan.CompilerIncrementalPlanInput
  (let
    [query : identity.CompilerIncrementalIdentity
      (fixture.graph-test-query kind length)]
    [record : trace.CompilerIncrementalTraceRecord
      (plan-test-record (& edge) (& query))]
    (plan.CompilerIncrementalPlanInput query edge.key (Known record))))

(define (plan-test-trace
  [kind : i64]
  [length : i64]
  [source : i64]
  [children : i64]
  [load-output : i64]) : trace.CompilerIncrementalTrace
  (let
    [builder : trace.CompilerIncrementalTraceBuilder
      (fixture.graph-test-trace-begin (fixture.graph-test-query kind length))]
    (fixture.graph-test-note! (&mut builder) (plan-test-source source))
    (when
      (> children 0)
      (fixture.graph-test-note!
        (&mut builder)
        (fixture.graph-test-child-edge
          0
          (fixture.graph-test-query 0 1)
          (fixture.graph-test-output load-output))))
    (when
      (> children 1)
      (fixture.graph-test-note!
        (&mut builder)
        (fixture.graph-test-child-edge
          1
          (fixture.graph-test-query 1 2)
          (fixture.graph-test-output 12))))
    (fixture.graph-test-trace-finish builder)))

;; 1=private edit, 2=changed semantic output, 3=new child, 4=removed child.
(define (plan-test-graph [mode : i64] [reverse? : bool]) : graph.CompilerIncrementalGraph
  (let
    [builder : graph.CompilerIncrementalGraphBuilder (fixture.graph-test-begin)]
    [parent-source : i64
      (if (or (= mode 3) (= mode 4))
        13
        12)]
    [load-source : i64
      (if (or (= mode 1) (= mode 2))
        13
        12)]
    [load-output : i64
      (if (= mode 2)
        21
        11)]
    [children : i64
      (if (= mode 4)
        0
        (if (= mode 3)
          2
          1))]
    [parent : graph.CompilerIncrementalGraphNode
      (fixture.graph-test-node
        2
        3
        (if (= mode 2)
          23
          13)
        (if (= mode 0)
          3
          (if (= mode 1)
            3
            23))
        (plan-test-trace 2 3 parent-source children load-output))]
    (fixture.graph-test-add-root!
      (&mut builder)
      (fixture.graph-test-root "typelisp.root.check" "app" 2 3))
    (when reverse? (fixture.graph-test-add-node! (&mut builder) (clone parent)))
    (unless
      (= mode 4)
      (fixture.graph-test-add-node!
        (&mut builder)
        (fixture.graph-test-node
          0
          1
          load-output
          (if (or (= mode 1) (= mode 2))
            21
            1)
          (plan-test-trace 0 1 load-source 0 11))))
    (when
      (= mode 3)
      (fixture.graph-test-add-node!
        (&mut builder)
        (fixture.graph-test-node 1 2 12 2 (plan-test-trace 1 2 12 0 11))))
    (unless reverse? (fixture.graph-test-add-node! (&mut builder) parent))
    (fixture.graph-test-unwrap (graph.compiler-graph-finalize builder))))

(define (plan-test-inputs [mode : i64]) : (__tl_dyn-array
    plan.CompilerIncrementalPlanInput)
  (__tl_make-array
    (plan-test-input
      0
      1
      (plan-test-source
        (if (or (= mode 1) (= mode 2))
          13
          12)))
    (plan-test-input
      2
      3
      (plan-test-source
        (if (or (= mode 3) (= mode 4))
          13
          12)))
    (plan-test-input 1 2 (plan-test-source 12))))

(define (plan-test-roots [value : (& value graph.CompilerIncrementalGraph)]) : (__tl_dyn-array
    graph.CompilerIncrementalGraphRoot)
  (let
    [out : (__tl_dyn-array graph.CompilerIncrementalGraphRoot)
      (__tl_make-array
        graph.CompilerIncrementalGraphRoot
        (array-length value.roots))]
    [i : i64 0]
    (while (< i (array-length out))
      (set!
        (array-ref out i)
        (graph.clone-compiler-incremental-graph-root
          (& (array-ref value.roots i))))
      (set! i (+ i 1)))
    out))

(define (plan-test-register!
  [state : (&mut state plan.CompilerIncrementalPlan)]
  [ticket : i64]
  [query : (& query identity.CompilerIncrementalIdentity)]
  [inputs : (& inputs (__tl_dyn-array plan.CompilerIncrementalPlanInput))]
  [records : (& records record_vec.Vec)]) : unit
  (let
    [i : i64 0]
    (while (< i (array-length inputs))
      (let
        [input : (& inputs plan.CompilerIncrementalPlanInput)
          (& inputs (array-ref inputs i))]
        (when
          (binary.compiler-incremental-binary-bytes-eq?
            (& input.query.transcript)
            (& query.transcript))
          (match (trace.compiler-trace-logical-key
            (& input.key)
            query
            (& state.limits.graph.trace))
            [(Ok key)
              (let
                [j : i64 0]
                [used? : bool false]
                (while (< j records.len)
                  (when
                    (=
                      (graph.compiler-graph-string-compare
                        (& key.bytes)
                        (& (array-ref records.slots j).key))
                      0)
                    (set! used? true))
                  (set! j (+ j 1)))
                (when
                  used?
                  (match (plan.compiler-plan-register-input!
                    state
                    ticket
                    query
                    (& input.key))
                    [(Ok _) unit]
                    [_ (plan-test-stop)])))]
            [_ (plan-test-stop)])))
      (set! i (+ i 1)))))

(defstruct PlanTestRun
  (graph graph.CompilerIncrementalGraph)
  (hits i64)
  (recomputes i64)
  (resumes i64)
  (events String))

(define (plan-test-events [state : (& state plan.CompilerIncrementalPlan)]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity
        (* 32 (plan.compiler-plan-event-count state)))]
    [i : i64 0]
    (while (< i (plan.compiler-plan-event-count state))
      (match (plan.compiler-plan-event state i)
        [(Ok event)
          (byte_le.push-u64! (&mut out) event.kind)
          (byte_le.push-u64! (&mut out) event.ticket)
          (byte_le.push-u64! (&mut out) event.node)
          (byte_le.push-u64! (&mut out) event.edge)]
        [_ (plan-test-stop)])
      (set! i (+ i 1)))
    (byte_buf_core.byte-buf-builder-finish-string (& out))))

(define (plan-test-execute
  [prior : plan.CompilerIncrementalPlanPrior]
  [expected : (& expected graph.CompilerIncrementalGraph)]
  [inputs : (__tl_dyn-array plan.CompilerIncrementalPlanInput)]
  [miss? : bool]) : PlanTestRun
  (let
    [state : plan.CompilerIncrementalPlan
      (plan-test-unwrap
        (plan.compiler-plan-begin
          prior
          (plan-test-roots expected)
          (clone inputs)
          (plan.compiler-plan-default-limits)))]
    [tickets : (__tl_dyn-array i64) (__tl_make-array i64 128)]
    [done? : bool false]
    [hits : i64 0]
    [recomputes : i64 0]
    [resumes : i64 0]
    [missed? : bool false]
    (while (not done?)
      (match (plan.compiler-plan-next-action! (&mut state))
        [(Reuse ticket value)
          (if (and miss? (not missed?))
            (begin
              (set! missed? true)
              (plan-test-require
                (plan.compiler-plan-unavailable!
                  (&mut state)
                  ticket
                  (& value.query))))
            (begin
              (plan-test-require
                (plan.compiler-plan-admit!
                  (&mut state)
                  ticket
                  (& value.query)
                  (& value.output)
                  (& value.stored-key)))
              (set! hits (+ hits 1))))]
        [(Recompute ticket query _)
          (set! recomputes (+ recomputes 1))
          (let
            [at : i64 (graph.compiler-graph-find-node expected (& query))]
            (plan-test-require (>= at 0))
            (set! (array-ref tickets ticket) at)
            (let
              [value : (& expected graph.CompilerIncrementalGraphNode)
                (& expected (array-ref expected.nodes at))]
              [records : record_vec.Vec
                (match (trace.compiler-trace-decode
                  (& value.trace)
                  (& state.limits.graph.trace))
                  [(Ok rows) rows]
                  [_ (plan-test-stop)])]
              [count : i64 0]
              [i : i64 0]
              (plan-test-register!
                (&mut state)
                ticket
                (& query)
                (& inputs)
                (& records))
              (while (< i records.len)
                (when
                  (= (array-ref records.slots i).kind 9)
                  (set! count (+ count 1)))
                (set! i (+ i 1)))
              (if (= count 0)
                (plan-test-require
                  (plan.compiler-plan-success!
                    (&mut state)
                    ticket
                    (graph.clone-compiler-incremental-graph-node value)))
                (let
                  [keys : (__tl_dyn-array trace.CompilerIncrementalTraceKey)
                    (__tl_make-array trace.CompilerIncrementalTraceKey count)]
                  [ordinal : i64 0]
                  (set! i 0)
                  (while (< i records.len)
                    (when
                      (= (array-ref records.slots i).kind 9)
                      (match (graph.compiler-graph-trace-child-query
                        (& (array-ref records.slots i))
                        (& query)
                        (& state.limits.graph))
                        [(Ok child)
                          (set!
                            (array-ref keys ordinal)
                            (Child "deps" ordinal child))
                          (set! ordinal (+ ordinal 1))]
                        [_ (plan-test-stop)]))
                    (set! i (+ i 1)))
                  (plan-test-require
                    (plan.compiler-plan-request-children!
                      (&mut state)
                      ticket
                      (& query)
                      keys))))))]
        [(Resume ticket)
          (set! resumes (+ resumes 1))
          (let
            [value : (& expected graph.CompilerIncrementalGraphNode)
              (& expected (array-ref expected.nodes (array-ref tickets ticket)))]
            (match (plan.compiler-plan-child-results!
              (&mut state)
              ticket
              (& value.query))
              [(Ok children) (plan-test-require (> children.len 0))]
              [_ (plan-test-stop)])
            (plan-test-require
              (plan.compiler-plan-success!
                (&mut state)
                ticket
                (graph.clone-compiler-incremental-graph-node value))))]
        [Complete (set! done? true)]
        [(Err _) (plan-test-stop)]))
    (let
      [result : graph.CompilerIncrementalGraph
        (fixture.graph-test-unwrap (plan.compiler-plan-finalize! (&mut state)))]
      [events : String (plan-test-events (& state))]
      (plan-test-require
        (binary.compiler-incremental-binary-bytes-eq?
          (& result.transcript)
          (& expected.transcript)))
      ;; Event transcript deliberately uses only bounded scalar positions.
      (PlanTestRun result hits recomputes resumes events))))

(define (plan-test-oracle
  [mode : i64]
  [hits : i64]
  [recomputes : i64]
  [resumes : i64]) : unit
  (let
    [previous : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    [expected : graph.CompilerIncrementalGraph (plan-test-graph mode true)]
    [incremental : PlanTestRun
      (plan-test-execute
        (Snapshot (graph.compiler-graph-encode (& previous)))
        (& expected)
        (plan-test-inputs mode)
        false)]
    [clean : PlanTestRun
      (plan-test-execute (Cold 1) (& expected) (plan-test-inputs mode) false)]
    (plan-test-require (= incremental.hits hits))
    (plan-test-require (= incremental.recomputes recomputes))
    (plan-test-require (= incremental.resumes resumes))
    (plan-test-require (= clean.hits 0))
    (plan-test-require (= clean.recomputes (array-length expected.nodes)))
    (plan-test-require
      (binary.compiler-incremental-binary-bytes-eq?
        (& incremental.graph.transcript)
        (& clean.graph.transcript)))))

(test
  compiler-incremental-plan-unchanged-admission-and-exact-graph
  (plan-test-oracle 0 2 0 0))

(test
  compiler-incremental-plan-stable-output-keeps-parent
  (plan-test-oracle 1 1 1 0))

(test
  compiler-incremental-plan-changed-output-recomputes-parent
  (plan-test-oracle 2 0 2 1))

(test
  compiler-incremental-plan-dynamic-added-child-and-resume
  (plan-test-oracle 3 1 2 1))

(test
  compiler-incremental-plan-removed-child-never-runs
  (plan-test-oracle 4 0 1 0))

(test
  compiler-incremental-plan-payload-unavailable-recomputes-once
  (let
    [expected : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    [result : PlanTestRun
      (plan-test-execute
        (Snapshot (graph.compiler-graph-encode (& expected)))
        (& expected)
        (plan-test-inputs 0)
        true)]
    (plan-test-require (= result.hits 1))
    (plan-test-require (= result.recomputes 1))))

(define (plan-test-closed
  [state : (&mut state plan.CompilerIncrementalPlan)]
  [code : i64]) : unit
  (plan-test-require (= state.budget.error code))
  (plan-test-require
    (=
      (fixture.graph-test-error-code (plan.compiler-plan-finalize! state))
      graph.compiler-graph-error-state)))

(define (plan-test-leaf-state) : plan.CompilerIncrementalPlan
  (let
    [value : graph.CompilerIncrementalGraph (plan-test-graph 4 false)]
    (plan-test-unwrap
      (plan.compiler-plan-begin
        (Cold 1)
        (plan-test-roots (& value))
        (plan-test-inputs 4)
        (plan.compiler-plan-default-limits)))))

(define (plan-test-register-source!
  [state : (&mut state plan.CompilerIncrementalPlan)]
  [ticket : i64]
  [query : (& query identity.CompilerIncrementalIdentity)]) : unit
  (match (plan.compiler-plan-register-input!
    state
    ticket
    query
    (& (trace.CompilerIncrementalTraceKey.Source "src/app.tl")))
    [(Ok _) unit]
    [_ (plan-test-stop)]))

(define (plan-test-bad-feedback [mode : i64]) : unit
  (let
    [state : plan.CompilerIncrementalPlan (plan-test-leaf-state)]
    [expected : graph.CompilerIncrementalGraph (plan-test-graph 4 false)]
    [value : graph.CompilerIncrementalGraphNode
      (graph.clone-compiler-incremental-graph-node
        (& (array-ref expected.nodes 0)))]
    [code : i64 plan.compiler-plan-error-feedback]
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Recompute ticket query _)
        (unless
          (or (= mode 6) (= mode 12) (= mode 14))
          (plan-test-register-source! (&mut state) ticket (& query)))
        (cond
          [(= mode 1)
            (set! code plan.compiler-plan-error-ticket)
            (plan-test-require
              (not
                (plan.compiler-plan-success! (&mut state) (+ ticket 1) value)))]
          [(= mode 2)
            (set! code plan.compiler-plan-error-ticket)
            (set! value.query (fixture.graph-test-query 0 1))
            (plan-test-require
              (not (plan.compiler-plan-success! (&mut state) ticket value)))]
          [(= mode 3)
            (set! code plan.compiler-plan-error-ticket)
            (plan-test-require
              (plan.compiler-plan-success! (&mut state) ticket (clone value)))
            (plan-test-require
              (not (plan.compiler-plan-success! (&mut state) ticket value)))]
          [(= mode 4)
            (set! value.trace.schema 2)
            (plan-test-require
              (not (plan.compiler-plan-success! (&mut state) ticket value)))]
          [(= mode 5)
            (set! value.trace.parent (fixture.graph-test-query 0 1))
            (plan-test-require
              (not (plan.compiler-plan-success! (&mut state) ticket value)))]
          [(= mode 7)
            (set! (array-ref value.trace.transcript 0) 255)
            (plan-test-require
              (not (plan.compiler-plan-success! (&mut state) ticket value)))]
          [(= mode 8)
            (set! value.stored-key.domain "bad.domain")
            (plan-test-require
              (not (plan.compiler-plan-success! (&mut state) ticket value)))]
          [(= mode 9)
            (set! value.output.identity.domain "bad.domain")
            (plan-test-require
              (not (plan.compiler-plan-success! (&mut state) ticket value)))]
          [(= mode 10)
            (set! code plan.compiler-plan-error-ticket)
            (match (plan.compiler-plan-next-action! (&mut state))
              [(Err error) (plan-test-require (= error code))]
              [_ (plan-test-stop)])]
          [(or (= mode 11) (= mode 13))
            (set! code plan.compiler-plan-error-executor)
            (plan.compiler-plan-abort! (&mut state) ticket (& query) 2)
            (when
              (= mode 13)
              (plan-test-require
                (not (plan.compiler-plan-success! (&mut state) ticket value))))]
          [(= mode 12)
            (set! code plan.compiler-plan-error-unavailable)
            (match (plan.compiler-plan-register-input!
              (&mut state)
              ticket
              (& query)
              (& (trace.CompilerIncrementalTraceKey.Source "src/deleted.tl")))
              [(Err error) (plan-test-require (= error code))]
              [_ (plan-test-stop)])]
          [(= mode 14)
            (set! code plan.compiler-plan-error-input)
            (match (plan.compiler-plan-register-input!
              (&mut state)
              ticket
              (& query)
              (&
                (trace.CompilerIncrementalTraceKey.Child
                  "deps"
                  0
                  (fixture.graph-test-query 0 1))))
              [(Err error) (plan-test-require (= error code))]
              [_ (plan-test-stop)])]
          [else
            (plan-test-require
              (not (plan.compiler-plan-success! (&mut state) ticket value)))])]
      [_ (plan-test-stop)])
    (plan-test-closed (&mut state) code)))

(define (plan-test-children
  [child : identity.CompilerIncrementalIdentity]
  [repeat? : bool]) : (__tl_dyn-array trace.CompilerIncrementalTraceKey)
  (let
    [keys : (__tl_dyn-array trace.CompilerIncrementalTraceKey)
      (__tl_make-array
        trace.CompilerIncrementalTraceKey
        (if repeat?
          2
          1))]
    (when repeat? (set! (array-ref keys 1) (Child "deps" 0 (clone child))))
    (set! (array-ref keys 0) (Child "deps" 0 child))
    keys))

(define (plan-test-bad-children [mode : i64]) : unit
  (let
    [state : plan.CompilerIncrementalPlan (plan-test-leaf-state)]
    [code : i64
      (if (= mode 4)
        plan.compiler-plan-error-limit
        (if (= mode 3)
          plan.compiler-plan-error-ticket
          plan.compiler-plan-error-cycle))]
    (when (= mode 4) (set! state.limits.max-depth 1))
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Recompute ticket query _)
        (if (= mode 1)
          (plan-test-require
            (not
              (plan.compiler-plan-request-children!
                (&mut state)
                ticket
                (& query)
                (plan-test-children (clone query) false))))
          (begin
            (plan-test-require
              (plan.compiler-plan-request-children!
                (&mut state)
                ticket
                (& query)
                (plan-test-children (fixture.graph-test-query 0 1) true)))
            (if (= mode 3)
              (let
                [expected : graph.CompilerIncrementalGraph
                  (plan-test-graph 4 false)]
                (plan-test-require
                  (not
                    (plan.compiler-plan-success!
                      (&mut state)
                      ticket
                      (graph.clone-compiler-incremental-graph-node
                        (& (array-ref expected.nodes 0)))))))
              (match (plan.compiler-plan-next-action! (&mut state))
                [(Err error) (plan-test-require (= error code))]
                [(Recompute child-ticket child-query _)
                  (plan-test-require
                    (plan.compiler-plan-request-children!
                      (&mut state)
                      child-ticket
                      (& child-query)
                      (plan-test-children query false)))
                  (match (plan.compiler-plan-next-action! (&mut state))
                    [(Err error) (plan-test-require (= error code))]
                    [_ (plan-test-stop)])]
                [_ (plan-test-stop)]))))]
      [_ (plan-test-stop)])
    (plan-test-closed (&mut state) code)))

(test
  compiler-incremental-plan-illegal-feedback-table
  (let
    [mode : i64 1]
    (while (<= mode 14)
      (plan-test-bad-feedback mode)
      (set! mode (+ mode 1)))))

(test compiler-incremental-plan-self-cycle (plan-test-bad-children 1))

(test compiler-incremental-plan-ancestor-cycle (plan-test-bad-children 2))

(test compiler-incremental-plan-suspended-ticket (plan-test-bad-children 3))

(test compiler-incremental-plan-depth-limit (plan-test-bad-children 4))

(define (plan-test-initial-error [mode : i64]) : i64
  (let
    [value : graph.CompilerIncrementalGraph (plan-test-graph 4 false)]
    [limits : plan.CompilerIncrementalPlanLimits
      (plan.compiler-plan-default-limits)]
    [roots : (__tl_dyn-array graph.CompilerIncrementalGraphRoot)
      (plan-test-roots (& value))]
    [inputs : (__tl_dyn-array plan.CompilerIncrementalPlanInput)
      (plan-test-inputs 4)]
    (cond
      [(= mode 0) (set! limits.max-depth 0)]
      [(= mode 1) (set! limits.max-requests 0)]
      [(= mode 2) (set! limits.max-events 0)]
      [(= mode 3) (set! limits.max-owned-bytes 1)]
      [(= mode 4) (set! limits.max-work 1)]
      [(= mode 5) (set! limits.graph.max-nodes 0)]
      [(= mode 6) (set! limits.graph.trace.max-depth 1)]
      [(= mode 7)
        (set!
          roots
          (__tl_make-array
            (fixture.graph-test-root "typelisp.root.check" "app" 2 3)
            (fixture.graph-test-root "typelisp.root.check" "app" 0 1)))]
      [(= mode 8)
        (set! (array-ref inputs 2) (plan-test-input 2 3 (plan-test-source 99)))]
      [(= mode 9)
        (set!
          (array-ref inputs 2)
          (plan.CompilerIncrementalPlanInput
            (fixture.graph-test-query 2 3)
            (Source "src/app.tl")
            Missing))]
      [(= mode 10)
        (set!
          (array-ref inputs 0)
          (plan.CompilerIncrementalPlanInput
            (fixture.graph-test-query 0 1)
            (Source "different.tl")
            (Known
              (plan-test-record
                (& (plan-test-source 12))
                (& (fixture.graph-test-query 0 1))))))]
      [(= mode 11) (set! (array-ref roots 0).query.schema 2)]
      [else unit])
    (match (plan.compiler-plan-begin
      (Cold
        (if (= mode 12)
          0
          1))
      roots
      inputs
      limits)
      [(Ok _) 0]
      [(Err code) code])))

(test
  compiler-incremental-plan-initial-limits-conflicts-malformed-facts
  (let
    [i : i64 0]
    (while (<= i 12)
      (plan-test-require
        (=
          (plan-test-initial-error i)
          (if (<= i 6)
            plan.compiler-plan-error-limit
            (if (<= i 9)
              plan.compiler-plan-error-conflict
              plan.compiler-plan-error-input))))
      (set! i (+ i 1)))))

(test
  compiler-incremental-plan-corrupt-and-incompatible-prior-become-cold
  (let
    [value : graph.CompilerIncrementalGraph (plan-test-graph 4 false)]
    [bad : (__tl_dyn-array u8) (graph.compiler-graph-encode (& value))]
    [incompatible : (__tl_dyn-array u8) (graph.compiler-graph-encode (& value))]
    (set! (array-ref bad 0) 255)
    (set!
      (array-ref
        incompatible
        (+ 4 (string.string-length graph.compiler-incremental-graph-domain)))
      2)
    (let
      [a : PlanTestRun
        (plan-test-execute (Snapshot bad) (& value) (plan-test-inputs 4) false)]
      [b : PlanTestRun
        (plan-test-execute
          (Snapshot incompatible)
          (& value)
          (plan-test-inputs 4)
          false)]
      (plan-test-require (= a.recomputes 1))
      (plan-test-require (= b.recomputes 1)))))

(define (plan-test-admission-error [mode : i64]) : unit
  (let
    [value : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    [state : plan.CompilerIncrementalPlan
      (plan-test-unwrap
        (plan.compiler-plan-begin
          (Snapshot (graph.compiler-graph-encode (& value)))
          (plan-test-roots (& value))
          (plan-test-inputs 0)
          (plan.compiler-plan-default-limits)))]
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Reuse ticket result)
        (cond
          [(= mode 0) (set! result.stored-key (fixture.graph-test-key 99))]
          [(= mode 1) (set! result.output (fixture.graph-test-output 99))]
          [(= mode 2) (set! result.query (fixture.graph-test-query 3 4))]
          [else unit])
        (if (= mode 3)
          (begin
            (plan-test-require
              (plan.compiler-plan-unavailable!
                (&mut state)
                ticket
                (& result.query)))
            (plan-test-require
              (not
                (plan.compiler-plan-unavailable!
                  (&mut state)
                  ticket
                  (& result.query)))))
          (plan-test-require
            (not
              (plan.compiler-plan-admit!
                (&mut state)
                ticket
                (& result.query)
                (& result.output)
                (& result.stored-key)))))]
      [_ (plan-test-stop)])
    (plan-test-closed
      (&mut state)
      (if (< mode 2)
        plan.compiler-plan-error-feedback
        plan.compiler-plan-error-ticket))))

(test
  compiler-incremental-plan-admission-names-exact-payload-and-rejects-repeat
  (let
    [i : i64 0]
    (while (< i 4)
      (plan-test-admission-error i)
      (set! i (+ i 1)))))

(define (plan-test-fact [kind : i64] [seed : i64]) : trace.CompilerIncrementalTraceEdge
  (let
    [semantic : trace.CompilerIncrementalTraceSemantic
      (Present (fixture.graph-test-output seed))]
    [artifact : trace.CompilerIncrementalTraceArtifact
      (Present (fixture.graph-test-child "typelisp.artifact" seed))]
    (cond
      [(= kind 1) (plan-test-source seed)]
      [(= kind 2)
        (trace.CompilerIncrementalTraceEdge
          (ImportSurface "pkg" "module")
          (ImportSurface semantic))]
      [(= kind 3)
        (trace.CompilerIncrementalTraceEdge
          (ImportResolution "pkg" "module")
          (ImportResolution artifact))]
      [(<= kind 6)
        (trace.CompilerIncrementalTraceEdge
          (Configuration
            (cond
              [(= kind 4) "typelisp.target"]
              [(= kind 5) "typelisp.cfg"]
              [else "typelisp.profile"]))
          (Configuration
            (fixture.graph-test-child "typelisp.configuration" seed)))]
      [(= kind 7)
        (trace.CompilerIncrementalTraceEdge
          CompilerBuild
          (CompilerBuild
            (fixture.graph-test-child "typelisp.compiler-build" seed)))]
      [(= kind 8)
        (trace.CompilerIncrementalTraceEdge
          (Stdlib "distribution")
          (Stdlib
            (identity.CompilerIncrementalContentIdentity
              "typelisp.stdlib-content"
              1
              seed
              (fixture.graph-test-digest seed))))]
      [(= kind 9)
        (trace.CompilerIncrementalTraceEdge
          (Package "dependency-tlci" "1")
          (Package
            (identity.CompilerIncrementalContentIdentity
              "typelisp.package-content"
              1
              seed
              (fixture.graph-test-digest seed))))]
      [(<= kind 12)
        (trace.CompilerIncrementalTraceEdge
          (MacroComptime
            (cond
              [(= kind 10) "implementation"]
              [(= kind 11) "generated-output"]
              [else "generated-declarations"])
            (fixture.graph-test-child "typelisp.macro-request" 5))
          (MacroComptime semantic))]
      [(= kind 13)
        (trace.CompilerIncrementalTraceEdge
          (Source "src/fallback.tl")
          (Source
            (if (= seed 10)
              (Absent 2)
              (Present
                (identity.CompilerIncrementalContentIdentity
                  "typelisp.source-content"
                  1
                  seed
                  (fixture.graph-test-digest seed))))))]
      [(= kind 14)
        (trace.CompilerIncrementalTraceEdge
          (ImportResolution "pkg" "negative")
          (ImportResolution
            (if (= seed 10)
              (Absent 1)
              artifact)))]
      [else
        (trace.CompilerIncrementalTraceEdge
          (ImportSurface "pkg" "negative")
          (ImportSurface
            (if (= seed 10)
              (Absent 1)
              semantic)))])))

(define (plan-test-fact-graph [kind : i64] [seed : i64]) : graph.CompilerIncrementalGraph
  (let
    [builder : graph.CompilerIncrementalGraphBuilder (fixture.graph-test-begin)]
    [trace : trace.CompilerIncrementalTraceBuilder
      (fixture.graph-test-trace-begin (fixture.graph-test-query 0 1))]
    (fixture.graph-test-note! (&mut trace) (plan-test-fact kind seed))
    (fixture.graph-test-add-root!
      (&mut builder)
      (fixture.graph-test-root "typelisp.root.check" "app" 2 3))
    (fixture.graph-test-add-node!
      (&mut builder)
      (fixture.graph-test-node
        0
        1
        11
        seed
        (fixture.graph-test-trace-finish trace)))
    (fixture.graph-test-add-node!
      (&mut builder)
      (fixture.graph-test-node 2 3 13 3 (plan-test-trace 2 3 12 1 11)))
    (fixture.graph-test-unwrap (graph.compiler-graph-finalize builder))))

(define (plan-test-fact-inputs [kind : i64] [seed : i64]) : (__tl_dyn-array
    plan.CompilerIncrementalPlanInput)
  (__tl_make-array
    (plan-test-input 0 1 (plan-test-fact kind seed))
    (plan-test-input 2 3 (plan-test-source 12))))

(test
  compiler-incremental-plan-typed-fact-mutation-table-clean-oracle
  (let
    [kind : i64 1]
    (while (<= kind 15)
      (let
        [previous : graph.CompilerIncrementalGraph
          (plan-test-fact-graph kind 10)]
        [expected : graph.CompilerIncrementalGraph
          (plan-test-fact-graph kind 20)]
        [incremental : PlanTestRun
          (plan-test-execute
            (Snapshot (graph.compiler-graph-encode (& previous)))
            (& expected)
            (plan-test-fact-inputs kind 20)
            false)]
        [clean : PlanTestRun
          (plan-test-execute
            (Cold 1)
            (& expected)
            (plan-test-fact-inputs kind 20)
            false)]
        (plan-test-require (= incremental.hits 1))
        (plan-test-require (= incremental.recomputes 1))
        (plan-test-require
          (binary.compiler-incremental-binary-bytes-eq?
            (& incremental.graph.transcript)
            (& clean.graph.transcript))))
      (set! kind (+ kind 1)))))

(define (plan-test-representative-inputs [reverse? : bool]) : (__tl_dyn-array
    plan.CompilerIncrementalPlanInput)
  (let
    [inputs : (__tl_dyn-array plan.CompilerIncrementalPlanInput)
      (__tl_make-array plan.CompilerIncrementalPlanInput 5)]
    [i : i64 0]
    (while (< i 4)
      (set!
        (array-ref
          inputs
          (if reverse?
            (- 4 i)
            i))
        (plan-test-input i (+ i 1) (plan-test-source 12)))
      (set! i (+ i 1)))
    (set!
      (array-ref
        inputs
        (if reverse?
          0
          4))
      (plan-test-input 1 2 (fixture.graph-test-macro-edge)))
    inputs))

(test
  compiler-incremental-plan-diamond-multiple-roots-and-frozen-table-order
  (let
    [previous : graph.CompilerIncrementalGraph
      (fixture.graph-test-unwrap
        (fixture.graph-test-representative false false))]
    [expected : graph.CompilerIncrementalGraph
      (fixture.graph-test-unwrap (fixture.graph-test-representative true true))]
    [forward : PlanTestRun
      (plan-test-execute
        (Snapshot (graph.compiler-graph-encode (& previous)))
        (& expected)
        (plan-test-representative-inputs false)
        false)]
    [reverse : PlanTestRun
      (plan-test-execute
        (Snapshot (graph.compiler-graph-encode (& previous)))
        (& expected)
        (plan-test-representative-inputs true)
        false)]
    [clean : PlanTestRun
      (plan-test-execute
        (Cold 1)
        (& expected)
        (plan-test-representative-inputs true)
        false)]
    (plan-test-require (= forward.hits 4))
    (plan-test-require (= clean.recomputes 4))
    (plan-test-require (= clean.resumes 3))
    (plan-test-require
      (=
        (graph.compiler-graph-string-compare
          (& forward.events)
          (& reverse.events))
        0))))

(test
  compiler-incremental-plan-fresh-arena-decision-stream
  (let
    [expected : graph.CompilerIncrementalGraph (plan-test-graph 3 false)]
    [previous : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    [forward : PlanTestRun
      (plan-test-execute
        (Snapshot (graph.compiler-graph-encode (& previous)))
        (& expected)
        (plan-test-inputs 3)
        false)]
    (plan-test-require
      (with-scratch
        (let
          [fresh : PlanTestRun
            (plan-test-execute
              (Snapshot (graph.compiler-graph-encode (& previous)))
              (& expected)
              (plan-test-inputs 3)
              false)]
          (=
            (graph.compiler-graph-string-compare
              (& forward.events)
              (& fresh.events))
            0))))))

(define (plan-test-child-feedback [mode : i64]) : unit
  (let
    [state : plan.CompilerIncrementalPlan (plan-test-leaf-state)]
    [parent-query : identity.CompilerIncrementalIdentity
      (fixture.graph-test-query 2 3)]
    [parent-ticket : i64 0]
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Recompute ticket query _)
        (set! parent-ticket ticket)
        (plan-test-register-source! (&mut state) ticket (& query))
        (plan-test-require
          (plan.compiler-plan-request-children!
            (&mut state)
            ticket
            (& query)
            (plan-test-children (fixture.graph-test-query 0 1) true)))]
      [_ (plan-test-stop)])
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Recompute ticket query _)
        (plan-test-register-source! (&mut state) ticket (& query))
        (plan-test-require
          (plan.compiler-plan-success!
            (&mut state)
            ticket
            (fixture.graph-test-load)))]
      [_ (plan-test-stop)])
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Resume ticket) (plan-test-require (= ticket parent-ticket))]
      [_ (plan-test-stop)])
    (let
      [builder : trace.CompilerIncrementalTraceBuilder
        (fixture.graph-test-trace-begin (clone parent-query))]
      (fixture.graph-test-note!
        (&mut builder)
        (plan-test-source
          (if (= mode 4)
            12
            13)))
      (unless
        (= mode 0)
        (fixture.graph-test-note!
          (&mut builder)
          (fixture.graph-test-child-edge
            (if (= mode 2)
              1
              0)
            (fixture.graph-test-query
              (if (= mode 3)
                1
                0)
              (if (= mode 3)
                2
                1))
            (fixture.graph-test-output
              (if (= mode 1)
                99
                11)))))
      (plan-test-require
        (not
          (plan.compiler-plan-success!
            (&mut state)
            parent-ticket
            (fixture.graph-test-node
              2
              3
              13
              23
              (fixture.graph-test-trace-finish builder))))))
    (plan-test-closed (&mut state) plan.compiler-plan-error-feedback)))

(test
  compiler-incremental-plan-child-ledger-omission-output-key-and-fact-mismatches
  (let
    [mode : i64 0]
    (while (< mode 5)
      (plan-test-child-feedback mode)
      (set! mode (+ mode 1)))))

(define (plan-test-runtime-limit [mode : i64]) : unit
  (let
    [value : graph.CompilerIncrementalGraph (plan-test-graph 4 false)]
    [limits : plan.CompilerIncrementalPlanLimits
      (plan.compiler-plan-default-limits)]
    (cond
      [(= mode 0) (set! limits.max-events 2)]
      [(= mode 1) (set! limits.max-requests 3)]
      [(= mode 2) (set! limits.graph.max-nodes 1)]
      [(= mode 3) (set! limits.graph.trace.max-edges 0)]
      [else unit])
    (let
      [state : plan.CompilerIncrementalPlan
        (plan-test-unwrap
          (plan.compiler-plan-begin
            (Cold 1)
            (plan-test-roots (& value))
            (plan-test-inputs 4)
            limits))]
      (when (= mode 4) (set! state.budget.max-work state.budget.work))
      (match (plan.compiler-plan-next-action! (&mut state))
        [(Err code) (plan-test-require (= code plan.compiler-plan-error-limit))]
        [(Recompute ticket query _)
          (cond
            [(= mode 1)
              (let
                [i : i64 0]
                (while (< i 3)
                  (plan-test-register-source! (&mut state) ticket (& query))
                  (set! i (+ i 1)))
                (match (plan.compiler-plan-register-input!
                  (&mut state)
                  ticket
                  (& query)
                  (& (trace.CompilerIncrementalTraceKey.Source "src/app.tl")))
                  [(Err code)
                    (plan-test-require (= code plan.compiler-plan-error-limit))]
                  [_ (plan-test-stop)]))]
            [(= mode 2)
              (plan-test-require
                (not
                  (plan.compiler-plan-request-children!
                    (&mut state)
                    ticket
                    (& query)
                    (plan-test-children (fixture.graph-test-query 0 1) false))))]
            [(= mode 3)
              (match (plan.compiler-plan-register-input!
                (&mut state)
                ticket
                (& query)
                (& (trace.CompilerIncrementalTraceKey.Source "src/app.tl")))
                [(Err code)
                  (plan-test-require (= code plan.compiler-plan-error-limit))]
                [_ (plan-test-stop)])]
            [else (plan-test-stop)])]
        [_ (plan-test-stop)])
      (plan-test-closed (&mut state) plan.compiler-plan-error-limit)
      (plan-test-require
        (<= (plan.compiler-plan-event-count (& state)) state.limits.max-events))
      (match (plan.compiler-plan-event
        (& state)
        (- (plan.compiler-plan-event-count (& state)) 1))
        [(Ok event)
          (plan-test-require
            (= event.kind (+ 100 plan.compiler-plan-error-limit)))]
        [_ (plan-test-stop)]))))

(test
  compiler-incremental-plan-runtime-work-event-request-node-and-edge-limits
  (let
    [mode : i64 0]
    (while (< mode 5)
      (plan-test-runtime-limit mode)
      (set! mode (+ mode 1)))))

(test
  compiler-incremental-plan-deleted-all-roots-publishes-empty-graph
  (let
    [prior : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    [state : plan.CompilerIncrementalPlan
      (plan-test-unwrap
        (plan.compiler-plan-begin
          (Snapshot (graph.compiler-graph-encode (& prior)))
          (__tl_make-array graph.CompilerIncrementalGraphRoot 0)
          (__tl_make-array plan.CompilerIncrementalPlanInput 0)
          (plan.compiler-plan-default-limits)))]
    (match (plan.compiler-plan-next-action! (&mut state))
      [Complete unit]
      [_ (plan-test-stop)])
    (let
      [empty : graph.CompilerIncrementalGraph
        (fixture.graph-test-unwrap (plan.compiler-plan-finalize! (&mut state)))]
      (plan-test-require (= (array-length empty.nodes) 0))
      (plan-test-require (= (array-length empty.roots) 0)))))

(test
  compiler-incremental-plan-impossible-graph-byte-budget-is-typed
  (let
    [limits : plan.CompilerIncrementalPlanLimits
      (plan.compiler-plan-default-limits)]
    (set! limits.graph.max-bytes 1)
    (match (plan.compiler-plan-begin
      (Cold 1)
      (__tl_make-array graph.CompilerIncrementalGraphRoot 0)
      (__tl_make-array plan.CompilerIncrementalPlanInput 0)
      limits)
      [(Err code) (plan-test-require (= code plan.compiler-plan-error-limit))]
      [_ (plan-test-stop)])))

(define (plan-test-root-change [rename? : bool]) : unit
  (let
    [prior : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    [builder : graph.CompilerIncrementalGraphBuilder (fixture.graph-test-begin)]
    (fixture.graph-test-add-root!
      (&mut builder)
      (fixture.graph-test-root
        "typelisp.root.check"
        (if rename?
          "renamed"
          "app")
        (if rename?
          2
          0)
        (if rename?
          3
          1)))
    (fixture.graph-test-add-node! (&mut builder) (fixture.graph-test-load))
    (when
      rename?
      (fixture.graph-test-add-node!
        (&mut builder)
        (fixture.graph-test-node 2 3 13 3 (plan-test-trace 2 3 12 1 11))))
    (let
      [expected : graph.CompilerIncrementalGraph
        (fixture.graph-test-unwrap (graph.compiler-graph-finalize builder))]
      [result : PlanTestRun
        (plan-test-execute
          (Snapshot (graph.compiler-graph-encode (& prior)))
          (& expected)
          (plan-test-inputs 0)
          false)]
      (plan-test-require (= result.recomputes 1))
      (plan-test-require
        (=
          result.hits
          (if rename?
            1
            0))))))

(test
  compiler-incremental-plan-new-root-name-or-query-forces-recomputation
  (plan-test-root-change true)
  (plan-test-root-change false))

(test
  compiler-incremental-plan-resolved-obsolete-child-does-not-leak
  (let
    [prior : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    [state : plan.CompilerIncrementalPlan
      (plan-test-unwrap
        (plan.compiler-plan-begin
          (Snapshot (graph.compiler-graph-encode (& prior)))
          (plan-test-roots (& prior))
          (plan-test-inputs 2)
          (plan.compiler-plan-default-limits)))]
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Recompute ticket query reason)
        (plan-test-require (= reason trace.compiler-trace-miss-source))
        (plan-test-register-source! (&mut state) ticket (& query))
        (plan-test-require
          (plan.compiler-plan-success!
            (&mut state)
            ticket
            (fixture.graph-test-node 0 1 21 21 (plan-test-trace 0 1 13 0 0))))]
      [_ (plan-test-stop)])
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Recompute ticket query reason)
        (plan-test-require (= reason trace.compiler-trace-miss-child))
        (plan-test-register-source! (&mut state) ticket (& query))
        (plan-test-require
          (plan.compiler-plan-success!
            (&mut state)
            ticket
            (fixture.graph-test-node 2 3 13 23 (plan-test-trace 2 3 12 0 0))))]
      [_ (plan-test-stop)])
    (match (plan.compiler-plan-next-action! (&mut state))
      [Complete unit]
      [_ (plan-test-stop)])
    (let
      [result : graph.CompilerIncrementalGraph
        (fixture.graph-test-unwrap (plan.compiler-plan-finalize! (&mut state)))]
      [builder : graph.CompilerIncrementalGraphBuilder
        (fixture.graph-test-begin)]
      (fixture.graph-test-add-root!
        (&mut builder)
        (fixture.graph-test-root "typelisp.root.check" "app" 2 3))
      (fixture.graph-test-add-node!
        (&mut builder)
        (fixture.graph-test-node 2 3 13 23 (plan-test-trace 2 3 12 0 0)))
      (let
        [clean : graph.CompilerIncrementalGraph
          (fixture.graph-test-unwrap (graph.compiler-graph-finalize builder))]
        (plan-test-require (= (array-length result.nodes) 1))
        (plan-test-require
          (binary.compiler-incremental-binary-bytes-eq?
            (& result.transcript)
            (& clean.transcript)))))))

(define (plan-test-batch-order [reverse? : bool]) : String
  (let
    [expected : graph.CompilerIncrementalGraph (plan-test-graph 3 false)]
    [state : plan.CompilerIncrementalPlan
      (plan-test-unwrap
        (plan.compiler-plan-begin
          (Cold 1)
          (plan-test-roots (& expected))
          (plan-test-inputs 3)
          (plan.compiler-plan-default-limits)))]
    [parent-ticket : i64 0]
    [i : i64 0]
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Recompute ticket query _)
        (set! parent-ticket ticket)
        (plan-test-register-source! (&mut state) ticket (& query))
        (let
          [keys : (__tl_dyn-array trace.CompilerIncrementalTraceKey)
            (__tl_make-array trace.CompilerIncrementalTraceKey 2)]
          (set!
            (array-ref
              keys
              (if reverse?
                1
                0))
            (Child "deps" 0 (fixture.graph-test-query 0 1)))
          (set!
            (array-ref
              keys
              (if reverse?
                0
                1))
            (Child "deps" 1 (fixture.graph-test-query 1 2)))
          (plan-test-require
            (plan.compiler-plan-request-children!
              (&mut state)
              ticket
              (& query)
              keys)))]
      [_ (plan-test-stop)])
    (while (< i 2)
      (match (plan.compiler-plan-next-action! (&mut state))
        [(Recompute ticket query _)
          (let
            [wanted : identity.CompilerIncrementalIdentity
              (fixture.graph-test-query i (+ i 1))]
            [at : i64 (graph.compiler-graph-find-node (& expected) (& query))]
            (plan-test-require
              (binary.compiler-incremental-binary-bytes-eq?
                (& query.transcript)
                (& wanted.transcript)))
            (plan-test-register-source! (&mut state) ticket (& query))
            (plan-test-require
              (plan.compiler-plan-success!
                (&mut state)
                ticket
                (graph.clone-compiler-incremental-graph-node
                  (& (array-ref expected.nodes at))))))]
        [_ (plan-test-stop)])
      (set! i (+ i 1)))
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Resume ticket)
        (plan-test-require (= ticket parent-ticket))
        (let
          [query : identity.CompilerIncrementalIdentity
            (fixture.graph-test-query 2 3)]
          [at : i64 (graph.compiler-graph-find-node (& expected) (& query))]
          (plan-test-require
            (plan.compiler-plan-success!
              (&mut state)
              ticket
              (graph.clone-compiler-incremental-graph-node
                (& (array-ref expected.nodes at))))))]
      [_ (plan-test-stop)])
    (match (plan.compiler-plan-next-action! (&mut state))
      [Complete unit]
      [_ (plan-test-stop)])
    (let
      [result : graph.CompilerIncrementalGraph
        (fixture.graph-test-unwrap (plan.compiler-plan-finalize! (&mut state)))]
      (plan-test-require
        (binary.compiler-incremental-binary-bytes-eq?
          (& result.transcript)
          (& expected.transcript))))
    (plan-test-events (& state))))

(test
  compiler-incremental-plan-child-batch-insertion-order-is-not-action-order
  (let
    [forward : String (plan-test-batch-order false)]
    [reverse : String (plan-test-batch-order true)]
    (plan-test-require
      (= (graph.compiler-graph-string-compare (& forward) (& reverse)) 0))))

(test
  compiler-incremental-plan-admission-miss-preserves-suspended-parent-ticket
  (let
    [expected : graph.CompilerIncrementalGraph (plan-test-graph 3 false)]
    [previous : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    [result : PlanTestRun
      (plan-test-execute
        (Snapshot (graph.compiler-graph-encode (& previous)))
        (& expected)
        (plan-test-inputs 3)
        true)]
    (plan-test-require (= result.recomputes 3))
    (plan-test-require (= result.hits 0))
    (plan-test-require (= result.resumes 1))))

(test
  compiler-incremental-plan-full-semantic-identity-survives-digest-collision
  (let
    [previous : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    [builder : graph.CompilerIncrementalGraphBuilder (fixture.graph-test-begin)]
    (fixture.graph-test-add-root!
      (&mut builder)
      (fixture.graph-test-root "typelisp.root.check" "app" 2 3))
    (fixture.graph-test-add-node!
      (&mut builder)
      (fixture.graph-test-node 0 1 267 21 (plan-test-trace 0 1 13 0 0)))
    (fixture.graph-test-add-node!
      (&mut builder)
      (fixture.graph-test-node 2 3 23 23 (plan-test-trace 2 3 12 1 267)))
    (let
      [expected : graph.CompilerIncrementalGraph
        (fixture.graph-test-unwrap (graph.compiler-graph-finalize builder))]
      [result : PlanTestRun
        (plan-test-execute
          (Snapshot (graph.compiler-graph-encode (& previous)))
          (& expected)
          (plan-test-inputs 2)
          false)]
      [a : identity.CompilerIncrementalSemanticOutputIdentity
        (fixture.graph-test-output 11)]
      [b : identity.CompilerIncrementalSemanticOutputIdentity
        (fixture.graph-test-output 267)]
      (plan-test-require
        (sha256.digest-eq?
          (& a.identity.fingerprint)
          (& b.identity.fingerprint)))
      (plan-test-require (= result.recomputes 2))
      (plan-test-require (= result.hits 0)))))

(test
  compiler-incremental-plan-exact-duplicate-roots-and-facts-collapse
  (let
    [expected : graph.CompilerIncrementalGraph (plan-test-graph 4 false)]
    [roots : (__tl_dyn-array graph.CompilerIncrementalGraphRoot)
      (__tl_make-array
        (fixture.graph-test-root "typelisp.root.check" "app" 2 3)
        (fixture.graph-test-root "typelisp.root.check" "app" 2 3))]
    [inputs : (__tl_dyn-array plan.CompilerIncrementalPlanInput)
      (__tl_make-array
        (plan-test-input 2 3 (plan-test-source 13))
        (plan-test-input 2 3 (plan-test-source 13)))]
    [state : plan.CompilerIncrementalPlan
      (plan-test-unwrap
        (plan.compiler-plan-begin
          (Cold 1)
          roots
          inputs
          (plan.compiler-plan-default-limits)))]
    (match (plan.compiler-plan-next-action! (&mut state))
      [(Recompute ticket query _)
        (plan-test-register-source! (&mut state) ticket (& query))
        (plan-test-require
          (plan.compiler-plan-success!
            (&mut state)
            ticket
            (graph.clone-compiler-incremental-graph-node
              (& (array-ref expected.nodes 0)))))]
      [_ (plan-test-stop)])
    (match (plan.compiler-plan-next-action! (&mut state))
      [Complete unit]
      [_ (plan-test-stop)])
    (let
      [result : graph.CompilerIncrementalGraph
        (fixture.graph-test-unwrap (plan.compiler-plan-finalize! (&mut state)))]
      [clean : PlanTestRun
        (plan-test-execute (Cold 1) (& expected) (plan-test-inputs 4) false)]
      [events : String (plan-test-events (& state))]
      (plan-test-require (= state.budget.actions 1))
      (plan-test-require
        (binary.compiler-incremental-binary-bytes-eq?
          (& result.transcript)
          (& clean.graph.transcript)))
      (plan-test-require
        (= (graph.compiler-graph-string-compare (& events) (& clean.events)) 0)))))

(test
  compiler-incremental-plan-one-child-query-retains-distinct-semantic-ordinals
  (let
    [previous : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    [builder : graph.CompilerIncrementalGraphBuilder (fixture.graph-test-begin)]
    [parent : trace.CompilerIncrementalTraceBuilder
      (fixture.graph-test-trace-begin (fixture.graph-test-query 2 3))]
    (fixture.graph-test-note! (&mut parent) (plan-test-source 13))
    (fixture.graph-test-note!
      (&mut parent)
      (fixture.graph-test-child-edge
        0
        (fixture.graph-test-query 0 1)
        (fixture.graph-test-output 11)))
    (fixture.graph-test-note!
      (&mut parent)
      (fixture.graph-test-child-edge
        1
        (fixture.graph-test-query 0 1)
        (fixture.graph-test-output 11)))
    (fixture.graph-test-add-root!
      (&mut builder)
      (fixture.graph-test-root "typelisp.root.check" "app" 2 3))
    (fixture.graph-test-add-node! (&mut builder) (fixture.graph-test-load))
    (fixture.graph-test-add-node!
      (&mut builder)
      (fixture.graph-test-node
        2
        3
        13
        23
        (fixture.graph-test-trace-finish parent)))
    (let
      [expected : graph.CompilerIncrementalGraph
        (fixture.graph-test-unwrap (graph.compiler-graph-finalize builder))]
      [result : PlanTestRun
        (plan-test-execute
          (Snapshot (graph.compiler-graph-encode (& previous)))
          (& expected)
          (plan-test-inputs 4)
          false)]
      [clean : PlanTestRun
        (plan-test-execute (Cold 1) (& expected) (plan-test-inputs 4) false)]
      (plan-test-require (= result.hits 1))
      (plan-test-require (= result.recomputes 1))
      (plan-test-require (= clean.recomputes 2)))))

(test
  compiler-incremental-plan-missing-and-failed-facts-schedule-owning-query
  (let
    [mode : i64 0]
    [previous : graph.CompilerIncrementalGraph (plan-test-graph 0 false)]
    (while (< mode 2)
      (let
        [inputs : (__tl_dyn-array plan.CompilerIncrementalPlanInput)
          (plan-test-inputs 0)]
        (set!
          (array-ref inputs 0).answer
          (if (= mode 0)
            Missing
            (Failed 7)))
        (let
          [state : plan.CompilerIncrementalPlan
            (plan-test-unwrap
              (plan.compiler-plan-begin
                (Snapshot (graph.compiler-graph-encode (& previous)))
                (plan-test-roots (& previous))
                inputs
                (plan.compiler-plan-default-limits)))]
          (match (plan.compiler-plan-next-action! (&mut state))
            [(Recompute ticket query reason)
              (let
                [wanted : identity.CompilerIncrementalIdentity
                  (fixture.graph-test-query 0 1)]
                (plan-test-require (= reason trace.compiler-trace-miss-source))
                (plan-test-require
                  (binary.compiler-incremental-binary-bytes-eq?
                    (& query.transcript)
                    (& wanted.transcript))))
              (plan.compiler-plan-abort!
                (&mut state)
                ticket
                (& query)
                (if (= mode 0)
                  1
                  3))]
            [_ (plan-test-stop)])
          (plan-test-closed (&mut state) plan.compiler-plan-error-executor)))
      (set! mode (+ mode 1)))))