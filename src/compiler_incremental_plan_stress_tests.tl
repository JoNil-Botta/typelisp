;; Star graphs put every child in one trace and one suspension batch. The
;; executor performs one indexed expected-node lookup and one direct-fact
;; registration per recompute; fixture work cannot hide a waiting-set scan.
(import compiler_incremental_plan as plan)
(import compiler_incremental_plan_tests as pt)
(import compiler_incremental_graph_tests as fixture)
(import compiler_incremental_graph as graph)
(import compiler_incremental_identity as identity)
(import compiler_incremental_trace as trace)
(import compiler_incremental_binary as binary)
(import stdlib.vector)
(import (stdlib.vector.vector trace.CompilerIncrementalTraceRecord) as record_vec)
(import stdlib.profile)

(define (plan-stress-trace-limits) : trace.CompilerIncrementalTraceLimits
  (let
    [limits : trace.CompilerIncrementalTraceLimits
      (trace.compiler-trace-default-limits)]
    (set! limits.max-work 1073741824)
    (set! limits.max-owned-bytes 1073741824)
    limits))

(define (plan-stress-source [mode : i64] [index : i64] [root? : bool]) : i64
  (if (or
    (= mode 4)
    (and root? (= mode 3))
    (and (not root?) (= index 0) (or (= mode 1) (= mode 2))))
    13
    12))

(define (plan-stress-output [mode : i64] [index : i64]) : i64
  (if (= mode 4)
    (+ index 1000)
    (if (and (= mode 2) (= index 0))
      9999
      (+ index 100))))

(define (plan-stress-query [index : i64] [root? : bool]) : identity.CompilerIncrementalIdentity
  (fixture.graph-test-query
    (if root?
      3
      0)
    (if root?
      1
      (+ index 1))))

(define (plan-stress-graph [base-count : i64] [mode : i64]) : graph.CompilerIncrementalGraph
  (let
    [count : i64
      (+
        base-count
        (if (= mode 3)
          1
          0))]
    [graph-limits : graph.CompilerIncrementalGraphLimits
      (graph.compiler-graph-default-limits)]
    [_limits : unit (set! graph-limits.trace (plan-stress-trace-limits))]
    [builder : graph.CompilerIncrementalGraphBuilder
      (match (graph.compiler-graph-begin graph-limits)
        [(Ok value) value]
        [_ (pt.plan-test-stop)])]
    [root : identity.CompilerIncrementalIdentity (plan-stress-query 0 true)]
    [root-trace : trace.CompilerIncrementalTraceBuilder
      (match (trace.compiler-trace-begin
        (clone root)
        (plan-stress-trace-limits))
        [(Ok value) value]
        [_ (pt.plan-test-stop)])]
    [i : i64 0]
    (fixture.graph-test-note!
      (&mut root-trace)
      (pt.plan-test-source (plan-stress-source mode 0 true)))
    (while (< i count)
      (let
        [query : identity.CompilerIncrementalIdentity
          (plan-stress-query i false)]
        [output : i64 (plan-stress-output mode i)]
        [key : i64
          (if (or (= mode 4) (and (= i 0) (or (= mode 1) (= mode 2))))
            (+ i 1000)
            (+ i 1))]
        (fixture.graph-test-note!
          (&mut root-trace)
          (fixture.graph-test-child-edge
            i
            (clone query)
            (fixture.graph-test-output output)))
        (fixture.graph-test-add-node!
          (&mut builder)
          (graph.CompilerIncrementalGraphNode
            query
            (fixture.graph-test-output output)
            (fixture.graph-test-key key)
            (pt.plan-test-trace 0 (+ i 1) (plan-stress-source mode i false) 0 0))))
      (set! i (+ i 1)))
    (fixture.graph-test-add-root!
      (&mut builder)
      (graph.CompilerIncrementalGraphRoot
        (graph.CompilerIncrementalGraphRootName "typelisp.root.check" "star")
        (clone root)))
    (fixture.graph-test-add-node!
      (&mut builder)
      (graph.CompilerIncrementalGraphNode
        root
        (fixture.graph-test-output
          (if (>= mode 2)
            2000
            999))
        (fixture.graph-test-key
          (if (>= mode 2)
            1999
            999))
        (fixture.graph-test-trace-finish root-trace)))
    (fixture.graph-test-unwrap (graph.compiler-graph-finalize builder))))

(define (plan-stress-inputs [count : i64] [mode : i64]) : (__tl_dyn-array
    plan.CompilerIncrementalPlanInput)
  (let
    [inputs : (__tl_dyn-array plan.CompilerIncrementalPlanInput)
      (__tl_make-array plan.CompilerIncrementalPlanInput (+ count 1))]
    [i : i64 0]
    (while (<= i count)
      (set!
        (array-ref inputs i)
        (pt.plan-test-input
          (if (= i count)
            3
            0)
          (if (= i count)
            1
            (+ i 1))
          (pt.plan-test-source (plan-stress-source mode i (= i count)))))
      (set! i (+ i 1)))
    inputs))

(defstruct CompilerPlanStressReport
  (nodes i64)
  (edges i64)
  (elapsed-ms i64)
  (transitions i64)
  (actions i64)
  (comparisons i64)
  (requests i64)
  (suspension-peak i64)
  (allocated-bytes i64)
  (peak-live-bytes i64)
  (charged-owned-bytes i64)
  (encoded-bytes i64)
  (event-bytes i64))

;; Mode 0 unchanged; 1 sparse output-stable; 2 output-changing; 3 dynamic;
;; 4 all direct facts and semantic outputs change. The oracle is constructed
;; independently of the planner and compared byte-for-byte after finalization.
(define (compiler-plan-stress-run [count : i64] [mode : i64]) : CompilerPlanStressReport
  (let
    [previous : graph.CompilerIncrementalGraph (plan-stress-graph count 0)]
    [expected : graph.CompilerIncrementalGraph (plan-stress-graph count mode)]
    [leaf-count : i64
      (+
        count
        (if (= mode 3)
          1
          0))]
    [inputs : (__tl_dyn-array plan.CompilerIncrementalPlanInput)
      (plan-stress-inputs leaf-count mode)]
    [roots : (__tl_dyn-array graph.CompilerIncrementalGraphRoot)
      (pt.plan-test-roots (& expected))]
    [snapshot : (__tl_dyn-array u8) (graph.compiler-graph-encode (& previous))]
    [limits : plan.CompilerIncrementalPlanLimits
      (plan.compiler-plan-default-limits)]
    [root-query : identity.CompilerIncrementalIdentity
      (plan-stress-query 0 true)]
    [start-total : i64 (profile.alloc-total)]
    [start-live : i64 (profile.alloc-live)]
    [start-ms : i64 (profile.now-ms)]
    (profile.alloc-reset-peak)
    ;; Bounds remain finite; the process tree has an independent OS cap.
    (set! limits.max-work 1099511627776)
    (set! limits.max-owned-bytes 8589934592)
    (set! limits.graph.trace (plan-stress-trace-limits))
    (let
      [state : plan.CompilerIncrementalPlan
        (pt.plan-test-unwrap
          (plan.compiler-plan-begin (Snapshot snapshot) roots inputs limits))]
      [done? : bool false]
      [parent-ticket : i64 0]
      [hits : i64 0]
      [recomputes : i64 0]
      (while (not done?)
        (match (plan.compiler-plan-next-action! (&mut state))
          [(Reuse ticket value)
            (pt.plan-test-require
              (plan.compiler-plan-admit!
                (&mut state)
                ticket
                (& value.query)
                (& value.output)
                (& value.stored-key)))
            (set! hits (+ hits 1))]
          [(Recompute ticket query _)
            (set! recomputes (+ recomputes 1))
            (pt.plan-test-register-source! (&mut state) ticket (& query))
            (if (binary.compiler-incremental-binary-bytes-eq?
              (& query.transcript)
              (& root-query.transcript))
              (let
                [keys : (__tl_dyn-array trace.CompilerIncrementalTraceKey)
                  (__tl_make-array trace.CompilerIncrementalTraceKey leaf-count)]
                [i : i64 0]
                (set! parent-ticket ticket)
                (while (< i leaf-count)
                  ;; Reverse submission order must not become action order.
                  (set!
                    (array-ref keys (- (- leaf-count 1) i))
                    (Child "deps" i (plan-stress-query i false)))
                  (set! i (+ i 1)))
                (pt.plan-test-require
                  (plan.compiler-plan-request-children!
                    (&mut state)
                    ticket
                    (& query)
                    keys)))
              (let
                [at : i64
                  (graph.compiler-graph-find-node (& expected) (& query))]
                (pt.plan-test-require (>= at 0))
                (pt.plan-test-require
                  (plan.compiler-plan-success!
                    (&mut state)
                    ticket
                    (graph.clone-compiler-incremental-graph-node
                      (& (array-ref expected.nodes at)))))))]
          [(Resume ticket)
            (pt.plan-test-require (= ticket parent-ticket))
            (let
              [query : identity.CompilerIncrementalIdentity
                (plan-stress-query 0 true)]
              [at : i64 (graph.compiler-graph-find-node (& expected) (& query))]
              (match (plan.compiler-plan-child-results!
                (&mut state)
                ticket
                (& query))
                [(Ok children)
                  (pt.plan-test-require (= children.len leaf-count))]
                [_ (pt.plan-test-stop)])
              (pt.plan-test-require
                (plan.compiler-plan-success!
                  (&mut state)
                  ticket
                  (graph.clone-compiler-incremental-graph-node
                    (& (array-ref expected.nodes at))))))]
          [Complete (set! done? true)]
          [_ (pt.plan-test-stop)]))
      (let
        [result : graph.CompilerIncrementalGraph
          (fixture.graph-test-unwrap
            (plan.compiler-plan-finalize! (&mut state)))]
        [nodes : i64 (+ leaf-count 1)]
        [elapsed : i64 (- (profile.now-ms) start-ms)]
        [allocated : i64 (- (profile.alloc-total) start-total)]
        [peak : i64 (- (profile.alloc-peak) start-live)]
        (pt.plan-test-require
          (binary.compiler-incremental-binary-bytes-eq?
            (& result.transcript)
            (& expected.transcript)))
        (pt.plan-test-require (= (+ hits recomputes) nodes))
        (pt.plan-test-require
          (< state.budget.transitions (* 16 (+ nodes leaf-count))))
        (pt.plan-test-require
          (< state.budget.comparisons (* 128 (+ nodes leaf-count))))
        (pt.plan-test-require (= state.budget.suspension-peak 2))
        (CompilerPlanStressReport
          nodes
          leaf-count
          elapsed
          state.budget.transitions
          state.budget.actions
          state.budget.comparisons
          state.budget.child-requests
          state.budget.suspension-peak
          allocated
          peak
          state.budget.owned
          (array-length result.transcript)
          (* 32 (plan.compiler-plan-event-count (& state))))))))

(test
  compiler-incremental-plan-star-linear-transition-bounds
  (let
    [mode : i64 0]
    (while (< mode 5)
      (let
        [report : CompilerPlanStressReport (compiler-plan-stress-run 256 mode)]
        (pt.plan-test-require (> report.encoded-bytes 0)))
      (set! mode (+ mode 1)))))

(define (plan-depth-graph [count : i64] [current? : bool]) : graph.CompilerIncrementalGraph
  (let
    [builder : graph.CompilerIncrementalGraphBuilder (fixture.graph-test-begin)]
    [i : i64 0]
    (while (< i count)
      (let
        [query : identity.CompilerIncrementalIdentity
          (plan-stress-query i false)]
        [trace : trace.CompilerIncrementalTraceBuilder
          (fixture.graph-test-trace-begin (clone query))]
        (fixture.graph-test-note!
          (&mut trace)
          (pt.plan-test-source
            (if current?
              13
              12)))
        (when
          (> i 0)
          (fixture.graph-test-note!
            (&mut trace)
            (fixture.graph-test-child-edge
              0
              (plan-stress-query (- i 1) false)
              (fixture.graph-test-output (+ i 99)))))
        (fixture.graph-test-add-node!
          (&mut builder)
          (graph.CompilerIncrementalGraphNode
            query
            (fixture.graph-test-output (+ i 100))
            (fixture.graph-test-key
              (+
                i
                (if current?
                  1000
                  1)))
            (fixture.graph-test-trace-finish trace))))
      (set! i (+ i 1)))
    (fixture.graph-test-add-root!
      (&mut builder)
      (graph.CompilerIncrementalGraphRoot
        (graph.CompilerIncrementalGraphRootName "typelisp.root.check" "chain")
        (plan-stress-query (- count 1) false)))
    (fixture.graph-test-unwrap (graph.compiler-graph-finalize builder))))

;; A deep recomputation suspends every parent. The last legal depth succeeds;
;; one more frame fails with a typed resource error and no partial graph.
(define (compiler-plan-depth-stress-run [count : i64] [depth-limit : i64]) : CompilerPlanStressReport
  (let
    [previous : graph.CompilerIncrementalGraph (plan-depth-graph count false)]
    [expected : graph.CompilerIncrementalGraph (plan-depth-graph count true)]
    [inputs : (__tl_dyn-array plan.CompilerIncrementalPlanInput)
      (__tl_make-array plan.CompilerIncrementalPlanInput count)]
    [roots : (__tl_dyn-array graph.CompilerIncrementalGraphRoot)
      (pt.plan-test-roots (& expected))]
    [snapshot : (__tl_dyn-array u8) (graph.compiler-graph-encode (& previous))]
    [limits : plan.CompilerIncrementalPlanLimits
      (plan.compiler-plan-default-limits)]
    [tickets : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
    [i : i64 0]
    (while (< i count)
      (set!
        (array-ref inputs i)
        (pt.plan-test-input 0 (+ i 1) (pt.plan-test-source 13)))
      (set! i (+ i 1)))
    (set! limits.max-depth depth-limit)
    (let
      [start-total : i64 (profile.alloc-total)]
      [start-live : i64 (profile.alloc-live)]
      [start-ms : i64 (profile.now-ms)]
      [_reset : unit (profile.alloc-reset-peak)]
      [state : plan.CompilerIncrementalPlan
        (pt.plan-test-unwrap
          (plan.compiler-plan-begin (Snapshot snapshot) roots inputs limits))]
      [done? : bool false]
      [resumes : i64 0]
      [encoded-bytes : i64 0]
      (while (not done?)
        (match (plan.compiler-plan-next-action! (&mut state))
          [(Recompute ticket query _)
            (let
              [at : i64 (graph.compiler-graph-find-node (& expected) (& query))]
              [value : (& expected graph.CompilerIncrementalGraphNode)
                (& expected (array-ref expected.nodes at))]
              [records : record_vec.Vec
                (match (trace.compiler-trace-decode
                  (& value.trace)
                  (& state.limits.graph.trace))
                  [(Ok rows) rows]
                  [_ (pt.plan-test-stop)])]
              (set! (array-ref tickets ticket) at)
              (pt.plan-test-register-source! (&mut state) ticket (& query))
              (if (= records.len 1)
                (pt.plan-test-require
                  (plan.compiler-plan-success!
                    (&mut state)
                    ticket
                    (graph.clone-compiler-incremental-graph-node value)))
                (match (graph.compiler-graph-trace-child-query
                  (& (array-ref records.slots 1))
                  (& query)
                  (& state.limits.graph))
                  [(Ok child)
                    (pt.plan-test-require
                      (plan.compiler-plan-request-children!
                        (&mut state)
                        ticket
                        (& query)
                        (pt.plan-test-children child false)))]
                  [_ (pt.plan-test-stop)])))]
          [(Resume ticket)
            (set! resumes (+ resumes 1))
            (let
              [value : (& expected graph.CompilerIncrementalGraphNode)
                (&
                  expected
                  (array-ref expected.nodes (array-ref tickets ticket)))]
              (match (plan.compiler-plan-child-results!
                (&mut state)
                ticket
                (& value.query))
                [(Ok children) (pt.plan-test-require (= children.len 1))]
                [_ (pt.plan-test-stop)])
              (pt.plan-test-require
                (plan.compiler-plan-success!
                  (&mut state)
                  ticket
                  (graph.clone-compiler-incremental-graph-node value))))]
          [Complete (set! done? true)]
          [(Err code)
            (pt.plan-test-require
              (and
                (> count depth-limit)
                (= code plan.compiler-plan-error-limit)))
            (set! done? true)]
          [_ (pt.plan-test-stop)]))
      (if (> count depth-limit)
        (pt.plan-test-closed (&mut state) plan.compiler-plan-error-limit)
        (let
          [result : graph.CompilerIncrementalGraph
            (fixture.graph-test-unwrap
              (plan.compiler-plan-finalize! (&mut state)))]
          (pt.plan-test-require
            (binary.compiler-incremental-binary-bytes-eq?
              (& result.transcript)
              (& expected.transcript)))
          (set! encoded-bytes (array-length result.transcript))
          (pt.plan-test-require (= state.budget.actions count))
          (pt.plan-test-require (= resumes (- count 1)))))
      (pt.plan-test-require
        (=
          state.budget.suspension-peak
          (if (> count depth-limit)
            depth-limit
            count)))
      (pt.plan-test-require (< state.budget.transitions (* 16 count)))
      (CompilerPlanStressReport
        count
        (- count 1)
        (- (profile.now-ms) start-ms)
        state.budget.transitions
        state.budget.actions
        state.budget.comparisons
        state.budget.child-requests
        state.budget.suspension-peak
        (- (profile.alloc-total) start-total)
        (- (profile.alloc-peak) start-live)
        state.budget.owned
        encoded-bytes
        (* 32 (plan.compiler-plan-event-count (& state)))))))

(test
  compiler-incremental-plan-chain-suspension-boundary
  (let
    [valid : CompilerPlanStressReport (compiler-plan-depth-stress-run 64 64)]
    [limited : CompilerPlanStressReport (compiler-plan-depth-stress-run 65 64)]
    (pt.plan-test-require (> valid.encoded-bytes 0))
    (pt.plan-test-require (= limited.encoded-bytes 0))))