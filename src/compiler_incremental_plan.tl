;; Serial, bounded query scheduling (#7188). #7025 supplies execution, payload
;; admission and publication. This module retains metadata, never payloads.
(import compiler_incremental_graph as graph)
(import compiler_incremental_identity as identity)
(import compiler_incremental_trace as trace)
(import compiler_incremental_binary as binary)
(import stdlib.string)
(import stdlib.str_cat)
(import stdlib.vector)
(import (stdlib.vector.vector trace.CompilerIncrementalTraceRecord) as record_vec)

(defstruct CompilerIncrementalPlanLimits
  (graph graph.CompilerIncrementalGraphLimits)
  (max-depth i64)
  (max-requests i64)
  (max-events i64)
  (max-owned-bytes i64)
  (max-work i64))

(define (compiler-plan-default-limits) : CompilerIncrementalPlanLimits
  (CompilerIncrementalPlanLimits
    (graph.compiler-graph-default-limits)
    4096
    1048576
    2097152
    1073741824
    17179869184))

;; Stable errors/events contain only schema-owned codes and planner positions.
;; No input bytes, query names, paths, addresses or executor messages escape.
(define compiler-plan-error-limit : i64
  1)
(define compiler-plan-error-input : i64
  2)
(define compiler-plan-error-conflict : i64
  3)
(define compiler-plan-error-ticket : i64
  4)
(define compiler-plan-error-cycle : i64
  5)
(define compiler-plan-error-feedback : i64
  6)
(define compiler-plan-error-unavailable : i64
  7)
(define compiler-plan-error-executor : i64
  8)
(define compiler-plan-reason-cold : i64
  20)
(define compiler-plan-reason-absent-query : i64
  21)
(define compiler-plan-reason-absent-root : i64
  22)
(define compiler-plan-reason-payload : i64
  23)

(defstruct CompilerIncrementalPlanEvent
  (kind i64)
  (ticket i64)
  (node i64)
  (edge i64))

;; Event codes: 2..9 recomputation reasons from the trace vocabulary;
;; 10 candidate issued; 11 changed, 12 missing, 13 failed direct fact;
;; 14 changed child output; 15 admitted hit; 16 new result; 17 consumed fact;
;; 20 cold, 21 absent query, 22 absent root, 23 unavailable payload;
;; 30 suspend, 31 existing child requested, 32 resume, 33 child removed,
;; 34 child added, 35 ledger mismatch, 38 executor abort, 40 roots resolved.
;; The terminal code is 100 + the first planner error.
(defstruct PlanBudget
  (work i64)
  (owned i64)
  (comparisons i64)
  (transitions i64)
  (actions i64)
  (requests i64)
  (child-requests i64)
  (suspension-peak i64)
  (error i64)
  (max-work i64)
  (max-owned i64))

(define (plan-charge!
  [budget : (&mut budget PlanBudget)]
  [work : i64]
  [owned : i64]) : bool
  (if (or
    (!= budget.error 0)
    (< work 0)
    (< owned 0)
    (> work (- budget.max-work budget.work))
    (> owned (- budget.max-owned budget.owned)))
    (begin
      (when (= budget.error 0) (set! budget.error compiler-plan-error-limit))
      false)
    (begin
      (set! budget.work (+ budget.work work))
      (set! budget.owned (+ budget.owned owned))
      true)))

;; AVL entries own full canonical byte keys. Heights bound recursive insertion
;; to logarithmic depth independently of adversarial key/hash distributions.
(defstruct PlanIndexEntry
  (key String)
  (value i64)
  (left i64)
  (right i64)
  (height i64))

(import (stdlib.vector.vector PlanIndexEntry core) as index_vec)

(defstruct PlanIndex
  (entries index_vec.Vec)
  (root i64))

(define (plan-index) : PlanIndex
  (PlanIndex (index_vec.new) -1))

(define (plan-height [index : (& index PlanIndex)] [at : i64]) : i64
  (if (< at 0)
    0
    (array-ref index.entries.slots at).height))

(define (plan-update-height! [index : (&mut index PlanIndex)] [at : i64]) : unit
  (let
    [left : i64 (plan-height index (array-ref index.entries.slots at).left)]
    [right : i64 (plan-height index (array-ref index.entries.slots at).right)]
    (set!
      (array-ref index.entries.slots at).height
      (+
        1
        (if (> left right)
          left
          right)))))

(define (plan-rotate!
  [index : (&mut index PlanIndex)]
  [at : i64]
  [left? : bool]) : i64
  (let
    [next : i64
      (if left?
        (array-ref index.entries.slots at).right
        (array-ref index.entries.slots at).left)]
    [middle : i64
      (if left?
        (array-ref index.entries.slots next).left
        (array-ref index.entries.slots next).right)]
    (if left?
      (begin
        (set! (array-ref index.entries.slots at).right middle)
        (set! (array-ref index.entries.slots next).left at))
      (begin
        (set! (array-ref index.entries.slots at).left middle)
        (set! (array-ref index.entries.slots next).right at)))
    (plan-update-height! index at)
    (plan-update-height! index next)
    next))

(define (plan-compare!
  [budget : (&mut budget PlanBudget)]
  [left : (& left str)]
  [right : (& right str)]) : i64
  (set! budget.comparisons (+ budget.comparisons 1))
  (if (plan-charge!
    budget
    (+ 1 (+ (string.string-length left) (string.string-length right)))
    0)
    (graph.compiler-graph-string-compare left right)
    0))

(define (plan-find!
  [index : (& index PlanIndex)]
  [key : (& key str)]
  [budget : (&mut budget PlanBudget)]) : i64
  (let
    [at : i64 index.root]
    [found : i64 -1]
    (while (and (>= at 0) (= found -1) (= budget.error 0))
      (let
        [entry : (& index PlanIndexEntry)
          (& index (array-ref index.entries.slots at))]
        [order : i64 (plan-compare! budget key (& entry.key))]
        (cond
          [(= order 0) (set! found entry.value)]
          [(< order 0) (set! at entry.left)]
          [else (set! at entry.right)])))
    found))

(define (plan-insert-at!
  [index : (&mut index PlanIndex)]
  [at : i64]
  [key : (& key str)]
  [value : i64]
  [budget : (&mut budget PlanBudget)]) : i64
  (if (< at 0)
    (if (plan-charge!
      budget
      (string.string-length key)
      (+ 128 (* 4 (string.string-length key))))
      (let
        [new : i64 index.entries.len]
        (index_vec.push-ref!
          (&mut index.entries)
          (PlanIndexEntry (string.copy key) value -1 -1 1))
        new)
      -1)
    (let
      [order : i64
        (plan-compare! budget key (& (array-ref index.entries.slots at).key))]
      (when (!= budget.error 0) (set! order 0))
      (cond
        [(< order 0)
          (let
            [child : i64
              (plan-insert-at!
                index
                (array-ref index.entries.slots at).left
                key
                value
                budget)]
            (set! (array-ref index.entries.slots at).left child))]
        [(> order 0)
          (let
            [child : i64
              (plan-insert-at!
                index
                (array-ref index.entries.slots at).right
                key
                value
                budget)]
            (set! (array-ref index.entries.slots at).right child))]
        [else unit])
      (plan-update-height! index at)
      (let
        [left : i64 (array-ref index.entries.slots at).left]
        [right : i64 (array-ref index.entries.slots at).right]
        [balance : i64 (- (plan-height index left) (plan-height index right))]
        (cond
          [(> balance 1)
            (when
              (<
                (plan-height index (array-ref index.entries.slots left).left)
                (plan-height index (array-ref index.entries.slots left).right))
              (let
                [rotated : i64 (plan-rotate! index left true)]
                (set! (array-ref index.entries.slots at).left rotated)))
            (plan-rotate! index at false)]
          [(< balance -1)
            (when
              (>
                (plan-height index (array-ref index.entries.slots right).left)
                (plan-height index (array-ref index.entries.slots right).right))
              (let
                [rotated : i64 (plan-rotate! index right false)]
                (set! (array-ref index.entries.slots at).right rotated)))
            (plan-rotate! index at true)]
          [else at])))))

(define (plan-put!
  [index : (&mut index PlanIndex)]
  [key : (& key str)]
  [value : i64]
  [budget : (&mut budget PlanBudget)]) : unit
  (let
    [root : i64 (plan-insert-at! index index.root key value budget)]
    (set! index.root root)))

;; Table ownership freezes answers. A repeated (query,key) with a different
;; answer is a stale resolver, rejected before any action can be issued.
(defenum CompilerIncrementalPlanInputAnswer
  (Known trace.CompilerIncrementalTraceRecord)
  (Missing)
  (Failed i64))

(defstruct CompilerIncrementalPlanInput
  (query identity.CompilerIncrementalIdentity)
  (key trace.CompilerIncrementalTraceKey)
  (answer CompilerIncrementalPlanInputAnswer))

(defenum PlanFactAnswer
  (Known trace.CompilerIncrementalTraceRecord)
  (Missing)
  (Failed i64))

(defstruct PlanFact
  (scope String)
  (answer PlanFactAnswer))

(import (stdlib.vector.vector PlanFact core) as fact_vec)

(defstruct PlanLedger
  (key String)
  (kind i64)
  (observation String)
  (child i64))

(import (stdlib.vector.vector PlanLedger core) as ledger_vec)
(import (stdlib.vector.vector i64) as ivec)

(defenum PlanResult
  (Pending)
  (Reused graph.CompilerIncrementalGraphNode)
  (Recomputed graph.CompilerIncrementalGraphNode))

(defstruct PlanNode
  (query identity.CompilerIncrementalIdentity)
  (prior i64)
  (state i64)
  (reason i64)
  (ticket i64)
  (records record_vec.Vec)
  (cursor i64)
  (ledger ledger_vec.Vec)
  (ledger-index PlanIndex)
  (batch ivec.Vec)
  (dependencies ivec.Vec)
  (result PlanResult))

;; States: 0 unseen, 1 prior-validating, 2 awaiting payload admission,
;; 3 running recomputation, 4 suspended, 5 successful, 6 ready-reuse,
;; 7 ready-recompute. Only the stack's top can be active (state 2 or 3).
;; Suspended frames retain their ticket; successful result variants preserve
;; whether the old record was retained or a new one was committed.
(import (stdlib.vector.vector PlanNode core) as node_vec)

(define (plan-ledger-find!
  [nodes : (& nodes node_vec.Vec)]
  [node : i64]
  [key : (& key str)]
  [budget : (&mut budget PlanBudget)]) : i64
  (plan-find! (& (array-ref nodes.slots node).ledger-index) key budget))

(define (plan-ledger-put!
  [nodes : (&mut nodes node_vec.Vec)]
  [node : i64]
  [key : (& key str)]
  [value : i64]
  [budget : (&mut budget PlanBudget)]) : unit
  (plan-put! (&mut (array-ref nodes.slots node).ledger-index) key value budget))

(define (plan-prior-key!
  [nodes : (& nodes node_vec.Vec)]
  [node : i64]
  [key : (& key str)]
  [budget : (&mut budget PlanBudget)]) : i64
  (let
    [low : i64 0]
    [high : i64 (array-ref nodes.slots node).records.len]
    [found : i64 -1]
    (while (and (< low high) (< found 0) (= budget.error 0))
      (let
        [middle : i64 (+ low (/ (- high low) 2))]
        [order : i64
          (plan-compare!
            budget
            key
            (&
              (array-ref (array-ref nodes.slots node).records.slots middle).key))]
        (cond
          [(= order 0) (set! found middle)]
          [(< order 0) (set! high middle)]
          [else (set! low (+ middle 1))])))
    found))

(defstruct PlanRoot
  (key String)
  (root graph.CompilerIncrementalGraphRoot)
  (node i64))

(import (stdlib.vector.vector PlanRoot core) as root_vec)

(defstruct PlanOrder
  (key String)
  (index i64))

(import (stdlib.vector.vector PlanOrder core) as order_vec)
(import (stdlib.vector.vector CompilerIncrementalPlanEvent core) as event_vec)

(defenum CompilerIncrementalPlanPrior
  (Cold i64)
  (Snapshot (__tl_dyn-array u8)))

(defstruct CompilerIncrementalPlan
  (limits CompilerIncrementalPlanLimits)
  (budget PlanBudget)
  (prior graph.CompilerIncrementalGraph)
  (cold i64)
  (roots root_vec.Vec)
  (root-cursor i64)
  (nodes node_vec.Vec)
  (node-index PlanIndex)
  (facts fact_vec.Vec)
  (fact-index PlanIndex)
  (stack ivec.Vec)
  (active i64)
  (next-ticket i64)
  (complete? bool)
  (events event_vec.Vec))

(defenum ResultCompilerIncrementalPlan
  (Ok CompilerIncrementalPlan)
  (Err i64))

(defenum CompilerIncrementalPlanAction
  (Reuse i64 graph.CompilerIncrementalGraphNode)
  (Recompute i64 identity.CompilerIncrementalIdentity i64)
  (Resume i64)
  (Complete)
  (Err i64))

(define (plan-event!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [kind : i64]
  [node : i64]
  [edge : i64]) : unit
  (if (or
    (>= plan.events.len (- plan.limits.max-events 1))
    (not (plan-charge! (&mut plan.budget) 1 64)))
    (set! plan.budget.error compiler-plan-error-limit)
    (begin
      (event_vec.push-ref!
        (&mut plan.events)
        (CompilerIncrementalPlanEvent
          kind
          (if (< node 0)
            0
            (array-ref plan.nodes.slots node).ticket)
          node
          edge))
      unit)))

(define (plan-fail! [plan : (&mut plan CompilerIncrementalPlan)] [code : i64]) : unit
  (when (= plan.budget.error 0) (set! plan.budget.error code)))

;; A virtual terminal scalar reports budget exhaustion without allocating or
;; changing earlier events. It is the final entry of the public event stream.
(define (compiler-plan-event-count [plan : (& plan CompilerIncrementalPlan)]) : i64
  (+
    plan.events.len
    (if (= plan.budget.error 0)
      0
      1)))

(defenum ResultCompilerIncrementalPlanEvent
  (Ok CompilerIncrementalPlanEvent)
  (Err i64))

(define (compiler-plan-event
  [plan : (& plan CompilerIncrementalPlan)]
  [index : i64]) : ResultCompilerIncrementalPlanEvent
  (cond
    [(or (< index 0) (>= index (compiler-plan-event-count plan)))
      (Err compiler-plan-error-input)]
    [(< index plan.events.len)
      (let
        [event : (& plan CompilerIncrementalPlanEvent)
          (& plan (array-ref plan.events.slots index))]
        (Ok
          (CompilerIncrementalPlanEvent
            event.kind
            event.ticket
            event.node
            event.edge)))]
    [else (Ok (CompilerIncrementalPlanEvent (+ 100 plan.budget.error) 0 -1 -1))]))

(define (plan-scope
  [query : (& query identity.CompilerIncrementalIdentity)]
  [key : (& key str)]) : String
  ;; Query transcripts are self-framed, so the concatenation is unambiguous.
  (let
    [prefix : String (graph.compiler-graph-bytes-string (& query.transcript))]
    (str_cat.str-cat prefix key)))

(define (plan-fact-equal?
  [left : (& left PlanFactAnswer)]
  [right : (& right PlanFactAnswer)]) : bool
  (match left
    [(Known a)
      (match right
        [(Known b)
          (and
            (= a.kind b.kind)
            (= (graph.compiler-graph-string-compare (& a.key) (& b.key)) 0)
            (=
              (graph.compiler-graph-string-compare
                (& a.observation)
                (& b.observation))
              0))]
        [_ false])]
    [Missing
      (match right
        [Missing true]
        [_ false])]
    [(Failed a)
      (match right
        [(Failed b) (= a b)]
        [_ false])]))

(define (plan-sort-order! [order : (&mut order order_vec.Vec)]) : unit
  (let
    [roots : (__tl_dyn-array graph.CompilerIncrementalGraphRootRecord)
      (__tl_make-array graph.CompilerIncrementalGraphRootRecord order.len)]
    [nodes : (__tl_dyn-array graph.CompilerIncrementalGraphNodeRecord)
      (__tl_make-array graph.CompilerIncrementalGraphNodeRecord 0)]
    [indices : (__tl_dyn-array i64)
      (graph.compiler-graph-identity-order order.len)]
    [scratch : (__tl_dyn-array i64) (__tl_make-array i64 order.len)]
    [sorted : order_vec.Vec (order_vec.with-capacity order.len)]
    [i : i64 0]
    (while (< i order.len)
      (set!
        (array-ref roots i)
        (graph.CompilerIncrementalGraphRootRecord
          (string.copy (& (array-ref order.slots i).key))
          ""))
      (set! i (+ i 1)))
    (graph.compiler-graph-sort-range!
      (&mut indices)
      (&mut scratch)
      0
      order.len
      (& roots)
      (& nodes)
      1)
    (set! i 0)
    (while (< i order.len)
      (order_vec.push-ref!
        (&mut sorted)
        (PlanOrder
          (string.copy (& (array-ref order.slots (array-ref indices i)).key))
          (array-ref order.slots (array-ref indices i)).index))
      (set! i (+ i 1)))
    (set! (deref order) sorted)))

(define (plan-fact-status
  [answer : (& answer PlanFactAnswer)]
  [observation : (& observation str)]) : i64
  (match answer
    [(Known current)
      (if (=
        (graph.compiler-graph-string-compare
          (& current.observation)
          observation)
        0)
        1
        11)]
    [Missing 12]
    [(Failed _) 13]))

(define (plan-sort-charge!
  [budget : (&mut budget PlanBudget)]
  [count : i64]
  [bytes : i64]) : bool
  (let
    [levels : i64 5]
    [width : i64 16]
    (while (< width count)
      (set! width (* width 2))
      (set! levels (+ levels 1)))
    (plan-charge!
      budget
      (* (+ bytes (* count 128)) (* levels 4))
      (* (+ bytes (* count 128)) 8))))

(define (plan-register!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [query : identity.CompilerIncrementalIdentity]) : i64
  (if (not
    (plan-charge!
      (&mut plan.budget)
      (* 128 (array-length query.transcript))
      (* 4 (array-length query.transcript))))
    -1
    (let
      [key : String (graph.compiler-graph-bytes-string (& query.transcript))]
      [found : i64 (plan-find! (& plan.node-index) (& key) (&mut plan.budget))]
      (cond
        [(>= found 0) found]
        [(or
          (>= plan.nodes.len plan.limits.graph.max-nodes)
          (not
            (plan-charge!
              (&mut plan.budget)
              (array-length query.transcript)
              (+ 1024 (* 8 (array-length query.transcript))))))
          (plan-fail! plan compiler-plan-error-limit)
          -1]
        [else
          (let
            [at : i64 plan.nodes.len]
            [prior : i64
              (if (= plan.cold 0)
                (graph.compiler-graph-find-node (& plan.prior) (& query))
                -1)]
            (node_vec.push-ref!
              (&mut plan.nodes)
              (PlanNode
                query
                prior
                0
                (if (= plan.cold 0)
                  compiler-plan-reason-absent-query
                  compiler-plan-reason-cold)
                0
                (record_vec.new)
                0
                (ledger_vec.new)
                (plan-index)
                (ivec.new)
                (ivec.new)
                Pending))
            (plan-put! (&mut plan.node-index) (& key) at (&mut plan.budget))
            at)]))))

(define (plan-input-size [input : (& input CompilerIncrementalPlanInput)]) : i64
  (+
    512
    (+
      (array-length input.query.transcript)
      (match (& input.answer)
        [(Known record)
          (+
            (string.string-length record.key)
            (string.string-length record.observation))]
        [_ 0]))))

(define (plan-root-present?
  [prior : (& prior graph.CompilerIncrementalGraph)]
  [root : (& root graph.CompilerIncrementalGraphRoot)]) : bool
  (let
    [at : i64 (graph.compiler-graph-find-root prior (& root.name))]
    (and
      (>= at 0)
      (binary.compiler-incremental-binary-bytes-eq?
        (& root.query.transcript)
        (& (array-ref prior.nodes at).query.transcript)))))

(define (plan-root-size [root : (& root graph.CompilerIncrementalGraphRoot)]) : i64
  (+
    512
    (+
      (array-length root.query.transcript)
      (+
        (string.string-length root.name.purpose)
        (string.string-length root.name.name)))))

(define (compiler-plan-begin
  [prior : CompilerIncrementalPlanPrior]
  [roots : (__tl_dyn-array graph.CompilerIncrementalGraphRoot)]
  [inputs : (__tl_dyn-array CompilerIncrementalPlanInput)]
  [limits : CompilerIncrementalPlanLimits]) : ResultCompilerIncrementalPlan
  (if (or
    (not (graph.compiler-graph-limits-valid? (& limits.graph)))
    (< limits.graph.max-bytes (graph.compiler-graph-header-bytes))
    (<= limits.max-depth 0)
    (< limits.max-requests 0)
    (<= limits.max-events 0)
    (<= limits.max-owned-bytes 0)
    (<= limits.max-work 0)
    (> (array-length roots) limits.graph.max-roots)
    (> (array-length inputs) limits.max-requests))
    (Err compiler-plan-error-limit)
    (let
      [empty : graph.CompilerIncrementalGraph
        (match (graph.compiler-graph-begin (clone limits.graph))
          [(Ok builder)
            (match (graph.compiler-graph-finalize builder)
              [(Ok value) value]
              [_ (string.tl_oob_abort)])]
          [_ (string.tl_oob_abort)])]
      [cold : i64 0]
      [snapshot : graph.CompilerIncrementalGraph
        (match prior
          [(Cold reason)
            (set!
              cold
              (if (and (> reason 0) (<= reason 3))
                reason
                -1))
            empty]
          [(Snapshot bytes)
            (match (graph.compiler-graph-decode (& bytes) (& limits.graph))
              [(Ok value) value]
              [(Err error)
                (set! cold (+ 1000 error.code))
                empty])])]
      [plan : CompilerIncrementalPlan
        (CompilerIncrementalPlan
          limits
          (PlanBudget 0 0 0 0 0 0 0 0 0 limits.max-work limits.max-owned-bytes)
          snapshot
          cold
          (root_vec.new)
          0
          (node_vec.new)
          (plan-index)
          (fact_vec.new)
          (plan-index)
          (ivec.new)
          -1
          1
          false
          (event_vec.new))]
      [i : i64 0]
      [root-bytes : i64 0]
      (when (< cold 0) (plan-fail! (&mut plan) compiler-plan-error-input))
      (when
        (> cold 0)
        (plan-event! (&mut plan) compiler-plan-reason-cold -1 cold))
      (while (and
        (= plan.budget.error 0)
        (< i (array-length inputs))
        (plan-charge!
          (&mut plan.budget)
          (* 128 (plan-input-size (& (array-ref inputs i))))
          (* 8 (plan-input-size (& (array-ref inputs i))))))
        (let
          [input : (& inputs CompilerIncrementalPlanInput)
            (& inputs (array-ref inputs i))]
          (if (not
            (graph.compiler-graph-query-valid?
              (& input.query)
              (& plan.limits.graph)))
            (plan-fail! (&mut plan) compiler-plan-error-input)
            (match (trace.compiler-trace-logical-key
              (& input.key)
              (& input.query)
              (& plan.limits.graph.trace))
              [(Err _) (plan-fail! (&mut plan) compiler-plan-error-input)]
              [(Ok logical)
                (if (= logical.kind 9)
                  (plan-fail! (&mut plan) compiler-plan-error-input)
                  (let
                    [answer : PlanFactAnswer
                      (match (& input.answer)
                        [(Known record)
                          (if (and
                            (= record.kind logical.kind)
                            (=
                              (graph.compiler-graph-string-compare
                                (& record.key)
                                (& logical.bytes))
                              0)
                            (trace.compiler-trace-record-parse-valid?
                              record
                              (& input.query)
                              (& plan.limits.graph.trace)))
                            (Known
                              (trace.clone-compiler-incremental-trace-record
                                record))
                            (begin
                              (plan-fail! (&mut plan) compiler-plan-error-input)
                              Missing))]
                        [Missing Missing]
                        [(Failed code)
                          (if (> code 0)
                            (Failed code)
                            (begin
                              (plan-fail! (&mut plan) compiler-plan-error-input)
                              Missing))])]
                    [scope : String
                      (plan-scope (& input.query) (& logical.bytes))]
                    [found : i64
                      (plan-find!
                        (& plan.fact-index)
                        (& scope)
                        (&mut plan.budget))]
                    (if (>= found 0)
                      (unless
                        (plan-fact-equal?
                          (& answer)
                          (& (array-ref plan.facts.slots found).answer))
                        (plan-fail! (&mut plan) compiler-plan-error-conflict))
                      (when
                        (plan-charge!
                          (&mut plan.budget)
                          (string.string-length scope)
                          (+ 256 (* 8 (string.string-length scope))))
                        (let
                          [at : i64 plan.facts.len]
                          (plan-put!
                            (&mut plan.fact-index)
                            (& scope)
                            at
                            (&mut plan.budget))
                          (fact_vec.push-ref!
                            (&mut plan.facts)
                            (PlanFact scope answer)))))))])))
        (set! i (+ i 1)))
      (set! i 0)
      (while (and
        (= plan.budget.error 0)
        (< i (array-length roots))
        (plan-charge!
          (&mut plan.budget)
          (* 128 (plan-root-size (& (array-ref roots i))))
          (* 8 (plan-root-size (& (array-ref roots i))))))
        (let
          [root : (& roots graph.CompilerIncrementalGraphRoot)
            (& roots (array-ref roots i))]
          (if (and
            (graph.compiler-graph-root-name-valid?
              (& root.name)
              (& plan.limits.graph))
            (graph.compiler-graph-query-valid?
              (& root.query)
              (& plan.limits.graph)))
            (let
              [key : String
                (graph.compiler-graph-encode-root-name (& root.name))]
              (set!
                root-bytes
                (+
                  root-bytes
                  (+
                    (string.string-length key)
                    (array-length root.query.transcript))))
              (root_vec.push-ref!
                (&mut plan.roots)
                (PlanRoot
                  key
                  (graph.clone-compiler-incremental-graph-root root)
                  -1)))
            (plan-fail! (&mut plan) compiler-plan-error-input)))
        (set! i (+ i 1)))
      (when
        (and
          (= plan.budget.error 0)
          (plan-sort-charge! (&mut plan.budget) plan.roots.len root-bytes))
        (let
          [order : order_vec.Vec (order_vec.new)]
          [sorted : root_vec.Vec (root_vec.new)]
          (set! i 0)
          (while (< i plan.roots.len)
            (order_vec.push-ref!
              (&mut order)
              (PlanOrder (clone (array-ref plan.roots.slots i).key) i))
            (set! i (+ i 1)))
          (plan-sort-order! (&mut order))
          (set! i 0)
          (while (< i order.len)
            (root_vec.push-ref!
              (&mut sorted)
              (clone
                (array-ref plan.roots.slots (array-ref order.slots i).index)))
            (set! i (+ i 1)))
          (set! plan.roots sorted)))
      (let
        [canonical : root_vec.Vec (root_vec.new)]
        (set! i 0)
        (while (and (= plan.budget.error 0) (< i plan.roots.len))
          (let
            [root : (& plan PlanRoot) (& plan (array-ref plan.roots.slots i))]
            (if (and
              (> canonical.len 0)
              (=
                (graph.compiler-graph-string-compare
                  (& root.key)
                  (& (array-ref canonical.slots (- canonical.len 1)).key))
                0))
              (unless
                (binary.compiler-incremental-binary-bytes-eq?
                  (& root.root.query.transcript)
                  (&
                    (array-ref canonical.slots (- canonical.len 1)).root.query.transcript))
                (plan-fail! (&mut plan) compiler-plan-error-conflict))
              (root_vec.push-ref!
                (&mut canonical)
                (PlanRoot
                  (string.copy (& root.key))
                  (graph.clone-compiler-incremental-graph-root (& root.root))
                  root.node))))
          (set! i (+ i 1)))
        (set! plan.roots canonical))
      (set! i 0)
      (while (and (= plan.budget.error 0) (< i plan.roots.len))
        (let
          [query : identity.CompilerIncrementalIdentity
            (clone (array-ref plan.roots.slots i).root.query)]
          [absent? : bool
            (and
              (= plan.cold 0)
              (not
                (plan-root-present?
                  (& plan.prior)
                  (& (array-ref plan.roots.slots i).root))))]
          [node : i64 (plan-register! (&mut plan) query)]
          (set! (array-ref plan.roots.slots i).node node)
          (when
            (and (>= node 0) absent?)
            (set!
              (array-ref plan.nodes.slots node).reason
              compiler-plan-reason-absent-root)))
        (set! i (+ i 1)))
      (if (= plan.budget.error 0)
        (Ok plan)
        (Err plan.budget.error)))))

;; Successful node access is private to checked state transitions. The public
;; protocol never exposes an unvalidated index or fabricates a partial result.
(define (plan-result [plan : (& plan CompilerIncrementalPlan)] [node : i64]) : (&
    plan
    graph.CompilerIncrementalGraphNode)
  (match (& plan (array-ref plan.nodes.slots node).result)
    [(Reused value) value]
    [(Recomputed value) value]
    [Pending (string.tl_oob_abort)]))

(define (plan-query [plan : (& plan CompilerIncrementalPlan)] [node : i64]) : (&
    plan
    identity.CompilerIncrementalIdentity)
  (& plan (array-ref plan.nodes.slots node).query))

(define (plan-child-observation
  [plan : (& plan CompilerIncrementalPlan)]
  [child : i64]) : String
  (let
    [result : (& plan graph.CompilerIncrementalGraphNode)
      (plan-result plan child)]
    [output : trace.CompilerIncrementalTraceObservation
      (Child
        (identity.clone-compiler-incremental-semantic-output-identity
          (& result.output)))]
    (trace.compiler-trace-encode-observation (& output))))

(define (plan-ledger-observation
  [plan : (& plan CompilerIncrementalPlan)]
  [node : i64]
  [at : i64]) : (Tuple i64 i64 String)
  (let
    [entry : (& plan PlanLedger)
      (& plan (array-ref (array-ref plan.nodes.slots node).ledger.slots at))]
    (tuple
      entry.child
      entry.kind
      (if (< entry.child 0)
        (string.copy (& entry.observation))
        (if (= (array-ref plan.nodes.slots entry.child).state 5)
          (plan-child-observation plan entry.child)
          "")))))

(define (plan-node-bytes [node : (& node graph.CompilerIncrementalGraphNode)]) : i64
  (+
    (+
      1024
      (+
        (string.string-length node.output.identity.domain)
        (+
          (string.string-length node.stored-key.domain)
          (array-length node.trace.parent.transcript))))
    (+
      (array-length node.query.transcript)
      (+
        (array-length node.trace.transcript)
        (array-length node.stored-key.bytes)))))

(define (plan-enter! [plan : (&mut plan CompilerIncrementalPlan)] [node : i64]) : unit
  (cond
    [(< node 0) (plan-fail! plan compiler-plan-error-limit)]
    [(= (array-ref plan.nodes.slots node).state 5) unit]
    [(!= (array-ref plan.nodes.slots node).state 0)
      (plan-fail! plan compiler-plan-error-cycle)]
    [(>= plan.stack.len plan.limits.max-depth)
      (plan-fail! plan compiler-plan-error-limit)]
    [else
      (when
        (plan-charge! (&mut plan.budget) 1 16)
        (ivec.push-ref! (&mut plan.stack) node)
        (when
          (> plan.stack.len plan.budget.suspension-peak)
          (set! plan.budget.suspension-peak plan.stack.len))
        (let
          [prior : i64 (array-ref plan.nodes.slots node).prior]
          (if (< prior 0)
            (set! (array-ref plan.nodes.slots node).state 7)
            (let
              [size : i64
                (plan-node-bytes (& (array-ref plan.prior.nodes prior)))]
              (when
                (plan-charge! (&mut plan.budget) (* size 8) (* size 8))
                (match (trace.compiler-trace-decode
                  (& (array-ref plan.prior.nodes prior).trace)
                  (& plan.limits.graph.trace))
                  [(Err _) (plan-fail! plan compiler-plan-error-input)]
                  [(Ok records)
                    (set! (array-ref plan.nodes.slots node).records records)
                    (set!
                      (array-ref plan.nodes.slots node).state
                      (if (=
                        (array-ref plan.nodes.slots node).reason
                        compiler-plan-reason-absent-root)
                        7
                        1))]))))))]))

(define (plan-recompute!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [node : i64]
  [reason : i64]
  [event : i64]
  [edge : i64]) : unit
  (set! (array-ref plan.nodes.slots node).state 7)
  (set! (array-ref plan.nodes.slots node).reason reason)
  (plan-event! plan event node edge))

;; One cursor per stack frame, never a scan of the waiting set. Direct facts
;; precede Child in canonical traces, so an impossible hit does not execute
;; obsolete children that a new trace may remove.
(define (plan-validate-step!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [node : i64]) : unit
  (let
    [cursor : i64 (array-ref plan.nodes.slots node).cursor]
    [count : i64 (array-ref plan.nodes.slots node).records.len]
    (if (>= cursor count)
      (set! (array-ref plan.nodes.slots node).state 6)
      (let
        [record : trace.CompilerIncrementalTraceRecord
          (trace.clone-compiler-incremental-trace-record
            (&
              (array-ref (array-ref plan.nodes.slots node).records.slots cursor)))]
        (if (< record.kind 9)
          (let
            [scope : String (plan-scope (plan-query plan node) (& record.key))]
            [fact : i64
              (plan-find! (& plan.fact-index) (& scope) (&mut plan.budget))]
            [status : i64
              (if (< fact 0)
                12
                (plan-fact-status
                  (& (array-ref plan.facts.slots fact).answer)
                  (& record.observation)))]
            (if (= status 1)
              (set! (array-ref plan.nodes.slots node).cursor (+ cursor 1))
              (plan-recompute!
                plan
                node
                (trace.compiler-trace-kind-miss record.kind)
                status
                cursor)))
          (match (graph.compiler-graph-trace-child-query
            (& record)
            (plan-query plan node)
            (& plan.limits.graph))
            [(Err _) (plan-fail! plan compiler-plan-error-input)]
            [(Ok query)
              (let
                [child : i64 (plan-register! plan query)]
                (when
                  (and (>= child 0) (= plan.budget.error 0))
                  (if (= (array-ref plan.nodes.slots child).state 5)
                    (let
                      [observation : String (plan-child-observation plan child)]
                      (if (=
                        (graph.compiler-graph-string-compare
                          (& observation)
                          (& record.observation))
                        0)
                        (begin
                          (ivec.push-ref!
                            (&mut
                              (array-ref plan.nodes.slots node).dependencies)
                            child)
                          (set!
                            (array-ref plan.nodes.slots node).cursor
                            (+ cursor 1)))
                        (plan-recompute!
                          plan
                          node
                          trace.compiler-trace-miss-child
                          14
                          cursor)))
                    (plan-enter! plan child))))]))))))

(define (compiler-plan-next-action!
  [plan : (&mut plan CompilerIncrementalPlan)]) : CompilerIncrementalPlanAction
  (cond
    [(!= plan.budget.error 0) (Err plan.budget.error)]
    [(>= plan.active 0)
      (plan-fail! plan compiler-plan-error-ticket)
      (Err plan.budget.error)]
    [plan.complete? Complete]
    [else
      (let
        [action : CompilerIncrementalPlanAction (Err 0)]
        [emitted? : bool false]
        (while (and (not emitted?) (= plan.budget.error 0))
          (unless (plan-charge! (&mut plan.budget) 1 0) unit)
          (set! plan.budget.transitions (+ plan.budget.transitions 1))
          (if (= plan.stack.len 0)
            (if (>= plan.root-cursor plan.roots.len)
              (begin
                (set! plan.complete? true)
                (plan-event! plan 40 -1 -1)
                (set! action Complete)
                (set! emitted? true))
              (let
                [node : i64 (array-ref plan.roots.slots plan.root-cursor).node]
                (set! plan.root-cursor (+ plan.root-cursor 1))
                (plan-enter! plan node)))
            (let
              [node : i64 (array-ref plan.stack.slots (- plan.stack.len 1))]
              [state : i64 (array-ref plan.nodes.slots node).state]
              (cond
                [(= state 1) (plan-validate-step! plan node)]
                [(= state 4)
                  (let
                    [cursor : i64 (array-ref plan.nodes.slots node).cursor]
                    [count : i64 (array-ref plan.nodes.slots node).batch.len]
                    (if (>= cursor count)
                      (begin
                        (set! (array-ref plan.nodes.slots node).state 3)
                        (set! plan.active node)
                        (plan-event! plan 32 node -1)
                        (set!
                          action
                          (Resume (array-ref plan.nodes.slots node).ticket))
                        (set! emitted? true))
                      (let
                        [ledger : i64
                          (array-ref
                            (array-ref plan.nodes.slots node).batch.slots
                            cursor)]
                        [child : i64
                          (array-ref
                            (array-ref plan.nodes.slots node).ledger.slots
                            ledger).child]
                        (if (= (array-ref plan.nodes.slots child).state 5)
                          (set!
                            (array-ref plan.nodes.slots node).cursor
                            (+ cursor 1))
                          (plan-enter! plan child)))))]
                [(or (= state 6) (= state 7))
                  (if (>= plan.next-ticket 9223372036854775807)
                    (plan-fail! plan compiler-plan-error-limit)
                    (let
                      [ticket : i64 plan.next-ticket]
                      [prior : i64 (array-ref plan.nodes.slots node).prior]
                      [size : i64
                        (if (= state 6)
                          (plan-node-bytes
                            (& (array-ref plan.prior.nodes prior)))
                          (+
                            512
                            (array-length (plan-query plan node).transcript)))]
                      (when
                        (plan-charge! (&mut plan.budget) (* size 4) (* size 4))
                        (set! plan.next-ticket (+ ticket 1))
                        (set! plan.budget.actions (+ plan.budget.actions 1))
                        (set! (array-ref plan.nodes.slots node).ticket ticket)
                        (set! plan.active node)
                        (if (= state 6)
                          (begin
                            (set! (array-ref plan.nodes.slots node).state 2)
                            (plan-event! plan 10 node -1)
                            (set!
                              action
                              (Reuse
                                ticket
                                (graph.clone-compiler-incremental-graph-node
                                  (& (array-ref plan.prior.nodes prior))))))
                          (begin
                            (set! (array-ref plan.nodes.slots node).state 3)
                            (set!
                              (array-ref plan.nodes.slots node).dependencies
                              (ivec.new))
                            (plan-event!
                              plan
                              (array-ref plan.nodes.slots node).reason
                              node
                              -1)
                            (set!
                              action
                              (Recompute
                                ticket
                                (identity.clone-compiler-incremental-identity
                                  (plan-query plan node))
                                (array-ref plan.nodes.slots node).reason))))
                        (set! emitted? true))))]
                [else (plan-fail! plan compiler-plan-error-ticket)]))))
        (if (= plan.budget.error 0)
          action
          (Err plan.budget.error)))]))

(define (plan-ticket!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [ticket : i64]
  [query : (& query identity.CompilerIncrementalIdentity)]
  [state : i64]) : i64
  (let
    [node : i64 plan.active]
    (when
      (and (= plan.budget.error 0) (>= node 0))
      (let
        [_charged? : bool
          (plan-charge!
            (&mut plan.budget)
            (* 128 (array-length query.transcript))
            0)]
        unit))
    (if (or (!= plan.budget.error 0) plan.complete? (< node 0))
      (begin
        (plan-fail! plan compiler-plan-error-ticket)
        -1)
      (let
        [expected : (& plan identity.CompilerIncrementalIdentity)
          (plan-query plan node)]
        (if (and
          (= (array-ref plan.nodes.slots node).state state)
          (= (array-ref plan.nodes.slots node).ticket ticket)
          (graph.compiler-graph-query-valid? query (& plan.limits.graph))
          (binary.compiler-incremental-binary-bytes-eq?
            (& query.transcript)
            (& expected.transcript)))
          node
          (begin
            (plan-fail! plan compiler-plan-error-ticket)
            -1))))))

(define (plan-resolve!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [node : i64]
  [value : graph.CompilerIncrementalGraphNode]
  [reused? : bool]) : bool
  (when
    (= plan.budget.error 0)
    (set!
      (array-ref plan.nodes.slots node).result
      (if reused?
        (Reused value)
        (Recomputed value)))
    (set! (array-ref plan.nodes.slots node).state 5)
    (set! plan.active -1)
    (set! plan.stack.len (- plan.stack.len 1))
    (plan-event!
      plan
      (if reused?
        15
        16)
      node
      -1))
  (= plan.budget.error 0))

;; Admission acknowledges the exact named metadata after payload validation.
;; A failed admission instead uses unavailable!, which issues one recomputation.
(define (compiler-plan-admit!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [ticket : i64]
  [query : (& query identity.CompilerIncrementalIdentity)]
  [output : (& output identity.CompilerIncrementalSemanticOutputIdentity)]
  [key : (& key graph.CompilerIncrementalStoredResultKey)]) : bool
  (let
    [node : i64 (plan-ticket! plan ticket query 2)]
    (when
      (and
        (>= node 0)
        (not
          (plan-charge!
            (&mut plan.budget)
            (*
              128
              (+
                512
                (+
                  (string.string-length output.identity.domain)
                  (+ (string.string-length key.domain) (array-length key.bytes)))))
            (*
              8
              (+
                512
                (+
                  (string.string-length output.identity.domain)
                  (+ (string.string-length key.domain) (array-length key.bytes))))))))
      (set! node -1))
    (if (< node 0)
      false
      (let
        [prior-index : i64 (array-ref plan.nodes.slots node).prior]
        [check : (Tuple bool i64)
          (let
            [prior : (& plan graph.CompilerIncrementalGraphNode)
              (& plan (array-ref plan.prior.nodes prior-index))]
            [output-bytes : String
              (if (graph.compiler-graph-output-valid?
                output
                (& plan.limits.graph))
                (graph.compiler-graph-encode-output output)
                "")]
            [prior-output : String
              (graph.compiler-graph-encode-output (& prior.output))]
            [equal? : bool
              (and
                (graph.compiler-graph-output-valid?
                  output
                  (& plan.limits.graph))
                (graph.compiler-graph-stored-key-valid?
                  key
                  (& plan.limits.graph))
                (=
                  (graph.compiler-graph-string-compare
                    (& output-bytes)
                    (& prior-output))
                  0)
                (= key.schema prior.stored-key.schema)
                (=
                  (graph.compiler-graph-string-compare
                    (& key.domain)
                    (& prior.stored-key.domain))
                  0)
                (binary.compiler-incremental-binary-bytes-eq?
                  (& key.bytes)
                  (& prior.stored-key.bytes)))]
            [size : i64 (plan-node-bytes prior)]
            (tuple equal? size))]
        [equal? : bool (tuple-ref check 0)]
        [size : i64 (tuple-ref check 1)]
        (if (and equal? (plan-charge! (&mut plan.budget) (* size 4) (* size 4)))
          (let
            [value : graph.CompilerIncrementalGraphNode
              (graph.clone-compiler-incremental-graph-node
                (&
                  (array-ref
                    plan.prior.nodes
                    (array-ref plan.nodes.slots node).prior)))]
            (plan-resolve! plan node value true))
          (begin
            (plan-fail! plan compiler-plan-error-feedback)
            false))))))

(define (compiler-plan-unavailable!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [ticket : i64]
  [query : (& query identity.CompilerIncrementalIdentity)]) : bool
  (let
    [node : i64 (plan-ticket! plan ticket query 2)]
    (when
      (>= node 0)
      (set! plan.active -1)
      (plan-recompute! plan node compiler-plan-reason-payload 23 -1))
    (= plan.budget.error 0)))

(define (compiler-plan-abort!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [ticket : i64]
  [query : (& query identity.CompilerIncrementalIdentity)]
  [reason : i64]) : unit
  (when
    (>= (plan-ticket! plan ticket query 3) 0)
    (plan-event!
      plan
      38
      plan.active
      (if (and (> reason 0) (<= reason 3))
        reason
        0))
    (plan-fail! plan compiler-plan-error-executor)))

(defenum ResultCompilerIncrementalPlanInput
  (Ok trace.CompilerIncrementalTraceRecord)
  (Err i64))

(define (plan-known-fact [plan : (& plan CompilerIncrementalPlan)] [fact : i64]) : ResultCompilerIncrementalPlanInput
  (if (< fact 0)
    (Err compiler-plan-error-unavailable)
    (match (& plan (array-ref plan.facts.slots fact).answer)
      [(Known record)
        (Ok (trace.clone-compiler-incremental-trace-record record))]
      [_ (Err compiler-plan-error-unavailable)])))

(define (plan-ledger-add!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [node : i64]
  [entry : PlanLedger]) : i64
  (let
    [found : i64
      (plan-ledger-find! (& plan.nodes) node (& entry.key) (&mut plan.budget))]
    (set! plan.budget.requests (+ plan.budget.requests 1))
    (cond
      [(or
        (> plan.budget.requests plan.limits.max-requests)
        (and
          (< found 0)
          (>=
            (array-ref plan.nodes.slots node).ledger.len
            plan.limits.graph.trace.max-edges))
        (not
          (plan-charge!
            (&mut plan.budget)
            (+
              1
              (+
                (string.string-length entry.key)
                (string.string-length entry.observation)))
            (+
              128
              (*
                8
                (+
                  (string.string-length entry.key)
                  (string.string-length entry.observation)))))))
        (plan-fail! plan compiler-plan-error-limit)
        -1]
      [(>= found 0)
        (let
          [old : (& plan PlanLedger)
            (&
              plan
              (array-ref (array-ref plan.nodes.slots node).ledger.slots found))]
          [equal? : bool
            (and
              (= old.kind entry.kind)
              (= old.child entry.child)
              (=
                (graph.compiler-graph-string-compare
                  (& old.observation)
                  (& entry.observation))
                0))]
          (unless equal? (plan-fail! plan compiler-plan-error-conflict))
          found)]
      [else
        (let
          [at : i64 (array-ref plan.nodes.slots node).ledger.len]
          (plan-ledger-put!
            (&mut plan.nodes)
            node
            (& entry.key)
            at
            (&mut plan.budget))
          (ledger_vec.push-ref!
            (&mut (array-ref plan.nodes.slots node).ledger)
            entry)
          at)])))

;; Execution must register each consumed direct fact. Missing/failed answers
;; cannot be invented into a successful trace. Candidate validation's old facts
;; are deliberately separate from this fresh execution ledger.
(define (compiler-plan-register-input!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [ticket : i64]
  [query : (& query identity.CompilerIncrementalIdentity)]
  [key : (& key trace.CompilerIncrementalTraceKey)]) : ResultCompilerIncrementalPlanInput
  (let
    [node : i64 (plan-ticket! plan ticket query 3)]
    (if (< node 0)
      (Err plan.budget.error)
      (match (trace.compiler-trace-logical-key
        key
        query
        (& plan.limits.graph.trace))
        [(Err _)
          (plan-fail! plan compiler-plan-error-input)
          (Err plan.budget.error)]
        [(Ok logical)
          (if (= logical.kind 9)
            (begin
              (plan-fail! plan compiler-plan-error-input)
              (Err plan.budget.error))
            (let
              [scope : String (plan-scope query (& logical.bytes))]
              [fact : i64
                (plan-find! (& plan.fact-index) (& scope) (&mut plan.budget))]
              (match (plan-known-fact plan fact)
                [(Err code)
                  (plan-fail! plan code)
                  (Err plan.budget.error)]
                [(Ok record)
                  (let
                    [entry : PlanLedger
                      (PlanLedger
                        (string.copy (& record.key))
                        record.kind
                        (string.copy (& record.observation))
                        -1)]
                    [at : i64 (plan-ledger-add! plan node entry)]
                    (if (and (>= at 0) (= plan.budget.error 0))
                      (Ok record)
                      (Err plan.budget.error)))])))]))))

(defstruct PlanRequest
  (logical trace.CompilerIncrementalTraceLogicalKey)
  (query identity.CompilerIncrementalIdentity))

(import (stdlib.vector.vector PlanRequest core) as request_vec)

(define (plan-child-request [key : (& key trace.CompilerIncrementalTraceKey)]) : identity.CompilerIncrementalIdentity
  (match key
    [(Child _ _ query) (identity.clone-compiler-incremental-identity query)]
    [_ (string.tl_oob_abort)]))

(define (plan-self-child?
  [key : (& key trace.CompilerIncrementalTraceKey)]
  [query : (& query identity.CompilerIncrementalIdentity)]) : bool
  (match key
    [(Child _ _ child)
      (binary.compiler-incremental-binary-bytes-eq?
        (& child.transcript)
        (& query.transcript))]
    [_ false]))

(define (plan-child-key-size [key : (& key trace.CompilerIncrementalTraceKey)]) : i64
  (match key
    [(Child sequence _ child)
      (+
        512
        (+ (string.string-length sequence) (array-length child.transcript)))]
    [_ 512]))

(define (compiler-plan-request-children!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [ticket : i64]
  [query : (& query identity.CompilerIncrementalIdentity)]
  [keys : (__tl_dyn-array trace.CompilerIncrementalTraceKey)]) : bool
  (let
    [node : i64 (plan-ticket! plan ticket query 3)]
    (when
      (>= node 0)
      (let
        [requests : request_vec.Vec (request_vec.new)]
        [order : order_vec.Vec (order_vec.new)]
        [batch : ivec.Vec (ivec.new)]
        [i : i64 0]
        [bytes : i64 0]
        (set!
          plan.budget.child-requests
          (+ plan.budget.child-requests (array-length keys)))
        (if (or
          (= (array-length keys) 0)
          (>
            (array-length keys)
            (- plan.limits.max-requests plan.budget.requests)))
          (plan-fail! plan compiler-plan-error-limit)
          (while (and
            (= plan.budget.error 0)
            (< i (array-length keys))
            (plan-charge!
              (&mut plan.budget)
              (* 128 (plan-child-key-size (& (array-ref keys i))))
              (* 8 (plan-child-key-size (& (array-ref keys i))))))
            (match (trace.compiler-trace-logical-key
              (& (array-ref keys i))
              query
              (& plan.limits.graph.trace))
              [(Err error)
                (plan-fail!
                  plan
                  (if (or
                    (= error.code trace.compiler-trace-error-self)
                    (plan-self-child? (& (array-ref keys i)) query))
                    compiler-plan-error-cycle
                    compiler-plan-error-input))]
              [(Ok logical)
                (if (!= logical.kind 9)
                  (plan-fail! plan compiler-plan-error-input)
                  (let
                    [child : identity.CompilerIncrementalIdentity
                      (plan-child-request (& (array-ref keys i)))]
                    (set! bytes (+ bytes (string.string-length logical.bytes)))
                    (order_vec.push-ref!
                      (&mut order)
                      (PlanOrder (string.copy (& logical.bytes)) requests.len))
                    (request_vec.push-ref!
                      (&mut requests)
                      (PlanRequest logical child))))])
            (set! i (+ i 1))))
        (when
          (and
            (= plan.budget.error 0)
            (plan-sort-charge! (&mut plan.budget) order.len bytes))
          (plan-sort-order! (&mut order)))
        (set! i 0)
        (while (and (= plan.budget.error 0) (< i order.len))
          (let
            [request-index : i64 (array-ref order.slots i).index]
            [request : (& requests PlanRequest)
              (& requests (array-ref requests.slots request-index))]
            [key : String (string.copy (& request.logical.bytes))]
            [child-query : identity.CompilerIncrementalIdentity
              (identity.clone-compiler-incremental-identity (& request.query))]
            [child : i64 (plan-register! plan child-query)]
            [old : i64
              (plan-ledger-find! (& plan.nodes) node (& key) (&mut plan.budget))]
            [prior : i64
              (plan-prior-key! (& plan.nodes) node (& key) (&mut plan.budget))]
            (when
              (and (>= child 0) (= plan.budget.error 0))
              (let
                [ledger : i64
                  (plan-ledger-add! plan node (PlanLedger key 9 "" child))]
                (when
                  (>= ledger 0)
                  (when
                    (or
                      (= batch.len 0)
                      (!= (array-ref batch.slots (- batch.len 1)) ledger))
                    (ivec.push-ref! (&mut batch) ledger))
                  (when
                    (< old 0)
                    (plan-event!
                      plan
                      (if (< prior 0)
                        34
                        31)
                      node
                      ledger))))))
          (set! i (+ i 1)))
        (when
          (= plan.budget.error 0)
          (set! (array-ref plan.nodes.slots node).batch batch)
          (set! (array-ref plan.nodes.slots node).cursor 0)
          (set! (array-ref plan.nodes.slots node).state 4)
          (set! plan.active -1)
          (plan-event! plan 30 node -1))))
    (= plan.budget.error 0)))

(defstruct CompilerIncrementalPlanChildResult
  (key String)
  (output identity.CompilerIncrementalSemanticOutputIdentity)
  (stored-key graph.CompilerIncrementalStoredResultKey))

(import (stdlib.vector.vector CompilerIncrementalPlanChildResult core) as child_result_vec)

(defenum ResultCompilerIncrementalPlanChildren
  (Ok child_result_vec.Vec)
  (Err i64))

;; Return this batch's distinct rows, including children resolved in a prior
;; batch. Never copy the accumulated ledger on every resume.
(define (compiler-plan-child-results!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [ticket : i64]
  [query : (& query identity.CompilerIncrementalIdentity)]) : ResultCompilerIncrementalPlanChildren
  (let
    [node : i64 (plan-ticket! plan ticket query 3)]
    [out : child_result_vec.Vec (child_result_vec.new)]
    [i : i64 0]
    (when
      (>= node 0)
      (while (and
        (= plan.budget.error 0)
        (< i (array-ref plan.nodes.slots node).batch.len))
        (let
          [at : i64 (array-ref (array-ref plan.nodes.slots node).batch.slots i)]
          [child : i64
            (array-ref (array-ref plan.nodes.slots node).ledger.slots at).child]
          [size : i64
            (+
              512
              (+
                (string.string-length
                  (array-ref (array-ref plan.nodes.slots node).ledger.slots at).key)
                (array-length (plan-result plan child).stored-key.bytes)))]
          (if (plan-charge! (&mut plan.budget) (* size 4) (* size 4))
            (let
              [result : (& plan graph.CompilerIncrementalGraphNode)
                (plan-result plan child)]
              (child_result_vec.push-ref!
                (&mut out)
                (CompilerIncrementalPlanChildResult
                  (string.copy
                    (&
                      (array-ref
                        (array-ref plan.nodes.slots node).ledger.slots
                        at).key))
                  (identity.clone-compiler-incremental-semantic-output-identity
                    (& result.output))
                  (graph.clone-compiler-incremental-stored-result-key
                    (& result.stored-key)))))
            unit))
        (set! i (+ i 1))))
    (if (= plan.budget.error 0)
      (Ok out)
      (Err plan.budget.error))))

(define (compiler-plan-success!
  [plan : (&mut plan CompilerIncrementalPlan)]
  [ticket : i64]
  [value : graph.CompilerIncrementalGraphNode]) : bool
  (let
    [node : i64 (plan-ticket! plan ticket (& value.query) 3)]
    [size : i64 (plan-node-bytes (& value))]
    (when
      (and (>= node 0) (plan-charge! (&mut plan.budget) (* size 16) (* size 8)))
      (if (not
        (and
          (graph.compiler-graph-output-valid?
            (& value.output)
            (& plan.limits.graph))
          (graph.compiler-graph-stored-key-valid?
            (& value.stored-key)
            (& plan.limits.graph))
          (graph.compiler-graph-trace-matches-node?
            (& value)
            (& plan.limits.graph))))
        (plan-fail! plan compiler-plan-error-feedback)
        (match (trace.compiler-trace-decode
          (& value.trace)
          (& plan.limits.graph.trace))
          [(Err _) (plan-fail! plan compiler-plan-error-feedback)]
          [(Ok records)
            (if (!= records.len (array-ref plan.nodes.slots node).ledger.len)
              (begin
                (plan-event! plan 35 node -1)
                (plan-fail! plan compiler-plan-error-feedback))
              (let
                [i : i64 0]
                [dependencies : ivec.Vec (ivec.new)]
                (while (and (= plan.budget.error 0) (< i records.len))
                  (let
                    [record : (& records trace.CompilerIncrementalTraceRecord)
                      (& records (array-ref records.slots i))]
                    [at : i64
                      (plan-ledger-find!
                        (& plan.nodes)
                        node
                        (& record.key)
                        (&mut plan.budget))]
                    (if (< at 0)
                      (begin
                        (plan-event! plan 35 node i)
                        (plan-fail! plan compiler-plan-error-feedback))
                      (let
                        [entry : (Tuple i64 i64 String)
                          (plan-ledger-observation plan node at)]
                        [child : i64 (tuple-ref entry 0)]
                        [kind : i64 (tuple-ref entry 1)]
                        [expected : String (tuple-ref entry 2)]
                        [equal? : bool
                          (and
                            (= kind record.kind)
                            (=
                              (graph.compiler-graph-string-compare
                                (& expected)
                                (& record.observation))
                              0))]
                        (if equal?
                          (if (>= child 0)
                            (ivec.push-ref! (&mut dependencies) child)
                            (plan-event! plan 17 node i))
                          (begin
                            (plan-event! plan 35 node i)
                            (plan-fail! plan compiler-plan-error-feedback))))))
                  (set! i (+ i 1)))
                (set! i 0)
                (while (and
                  (= plan.budget.error 0)
                  (< i (array-ref plan.nodes.slots node).records.len))
                  (let
                    [record : trace.CompilerIncrementalTraceRecord
                      (trace.clone-compiler-incremental-trace-record
                        (&
                          (array-ref
                            (array-ref plan.nodes.slots node).records.slots
                            i)))]
                    [removed? : bool
                      (and
                        (= record.kind 9)
                        (<
                          (plan-ledger-find!
                            (& plan.nodes)
                            node
                            (& record.key)
                            (&mut plan.budget))
                          0))]
                    (when removed? (plan-event! plan 33 node i)))
                  (set! i (+ i 1)))
                (when
                  (= plan.budget.error 0)
                  (set!
                    (array-ref plan.nodes.slots node).dependencies
                    dependencies))))])))
    (if (= plan.budget.error 0)
      (plan-resolve! plan node value false)
      false)))

(define (compiler-plan-finalize! [plan : (&mut plan CompilerIncrementalPlan)]) : graph.ResultCompilerIncrementalGraph
  (if (or (!= plan.budget.error 0) (not plan.complete?) (>= plan.active 0))
    (Err
      (graph.compiler-graph-error
        graph.compiler-graph-error-state
        -1
        -1
        "planner has no complete successful graph"))
    (let
      [seen : (__tl_dyn-array bool) (__tl_make-array bool plan.nodes.len)]
      [pending : ivec.Vec (ivec.new)]
      [i : i64 0]
      (while (< i plan.roots.len)
        (ivec.push-ref! (&mut pending) (array-ref plan.roots.slots i).node)
        (set! i (+ i 1)))
      (while (and (= plan.budget.error 0) (> pending.len 0))
        (let
          [node : i64 (array-ref pending.slots (- pending.len 1))]
          (set! pending.len (- pending.len 1))
          (unless
            (array-ref seen node)
            (set! (array-ref seen node) true)
            (let
              [j : i64 0]
              (while (and
                (= plan.budget.error 0)
                (< j (array-ref plan.nodes.slots node).dependencies.len))
                (when
                  (plan-charge! (&mut plan.budget) 1 16)
                  (ivec.push-ref!
                    (&mut pending)
                    (array-ref
                      (array-ref plan.nodes.slots node).dependencies.slots
                      j)))
                (set! j (+ j 1)))))))
      (match (graph.compiler-graph-begin (clone plan.limits.graph))
        [(Err error) (Err error)]
        [(Ok builder)
          (set! i 0)
          (while (and (= plan.budget.error 0) (< i plan.roots.len))
            (let
              [_accepted? : bool
                (graph.compiler-graph-add-root!
                  (&mut builder)
                  (graph.clone-compiler-incremental-graph-root
                    (& (array-ref plan.roots.slots i).root)))]
              unit)
            (set! i (+ i 1)))
          (set! i 0)
          (while (and (= plan.budget.error 0) (< i plan.nodes.len))
            (when
              (array-ref seen i)
              (let
                [size : i64 (plan-node-bytes (plan-result plan i))]
                (when
                  (plan-charge! (&mut plan.budget) (* size 128) (* size 16))
                  (let
                    [_accepted? : bool
                      (graph.compiler-graph-add-node!
                        (&mut builder)
                        (graph.clone-compiler-incremental-graph-node
                          (plan-result plan i)))]
                    unit))))
            (set! i (+ i 1)))
          (if (= plan.budget.error 0)
            (match (graph.compiler-graph-finalize builder)
              [(Ok value) (Ok value)]
              [(Err error)
                (plan-fail!
                  plan
                  (if (= error.code graph.compiler-graph-error-limit)
                    compiler-plan-error-limit
                    compiler-plan-error-feedback))
                (Err error)])
            (Err
              (graph.compiler-graph-error
                graph.compiler-graph-error-limit
                -1
                -1
                "planner resource limit")))]))))