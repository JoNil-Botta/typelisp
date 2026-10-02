;; compiler_incremental_graph.tl - the immutable, validated graph of a previous
;; run's successful frontend queries (#7322).
;;
;; A graph is a canonical set of named roots and successful nodes. A node joins
;; the #7265 identity of the query that ran, the semantic output identity its
;; parents observed, the opaque key that locates its stored result, and its
;; complete #7267 trace. Finalize and decode share one strict parser: finalize
;; sorts the candidate, encodes it and decodes those bytes, so every published
;; graph has passed the same framing, budget, referential-integrity,
;; reachability and acyclicity checks as persisted bytes, and a failure
;; publishes nothing. Result payloads, the result store, the planner and cache
;; policy live elsewhere.
(import compiler_incremental_binary as binary)
(import compiler_incremental_identity as identity)
(import compiler_incremental_trace as trace)
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.byte_buf_core)
(import stdlib.byte_le)
(import stdlib.byte_reader)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.string)
(import stdlib.vector)

(define compiler-incremental-graph-domain : String
  "typelisp.compiler.incremental.graph")
(define compiler-incremental-graph-schema : i64
  1)
(define compiler-incremental-stored-result-domain : String
  "typelisp.compiler.incremental.stored-result")

;; Distinct tags keep a node's semantic output and its stored-result key apart
;; in the canonical bytes.
(define compiler-graph-output-tag : i64
  79)
(define compiler-graph-key-tag : i64
  75)

;; The smallest encodings of a root and a node, used to reject a count that the
;; remaining input cannot hold before anything is allocated for it.
(define compiler-graph-min-root-bytes : i64
  15)
(define compiler-graph-min-node-bytes : i64
  64)

;; Stable error categories; callers compare these instead of messages.
(define compiler-graph-error-limit-config : i64
  1)
(define compiler-graph-error-limit : i64
  2)
(define compiler-graph-error-state : i64
  3)
(define compiler-graph-error-schema : i64
  4)
(define compiler-graph-error-framing : i64
  5)
(define compiler-graph-error-trailing : i64
  6)
(define compiler-graph-error-order : i64
  7)
(define compiler-graph-error-conflict : i64
  8)
(define compiler-graph-error-query : i64
  9)
(define compiler-graph-error-output : i64
  10)
(define compiler-graph-error-key : i64
  11)
(define compiler-graph-error-trace : i64
  12)
(define compiler-graph-error-trace-parent : i64
  13)
(define compiler-graph-error-absent-child : i64
  14)
(define compiler-graph-error-child-output : i64
  15)
(define compiler-graph-error-root : i64
  16)
(define compiler-graph-error-absent-root : i64
  17)
(define compiler-graph-error-unreachable : i64
  18)
(define compiler-graph-error-cycle : i64
  19)

;; `max-edges` bounds child-result edges across the whole graph; the per-node
;; edge, identity and trace byte budgets are the trace limits'.
(defstruct CompilerIncrementalGraphLimits
  (max-bytes i64)
  (max-roots i64)
  (max-nodes i64)
  (max-edges i64)
  (max-name-bytes i64)
  (max-key-bytes i64)
  (max-work i64)
  (trace trace.CompilerIncrementalTraceLimits))

(define (compiler-graph-default-limits) : CompilerIncrementalGraphLimits
  (CompilerIncrementalGraphLimits
    268435456
    4096
    65536
    1048576
    1024
    1024
    4294967296
    (trace.compiler-trace-default-limits)))

(define (compiler-graph-limits-valid?
  [limits : (& limits CompilerIncrementalGraphLimits)]) : bool
  (and
    (> limits.max-bytes 0)
    (>= limits.max-roots 1)
    (<= limits.max-roots 4294967295)
    (>= limits.max-nodes 1)
    (<= limits.max-nodes 4294967295)
    (>= limits.max-edges 0)
    (<= limits.max-edges 4294967295)
    (>= limits.max-name-bytes 64)
    (<= limits.max-name-bytes 4294967295)
    (> limits.max-key-bytes 0)
    (<= limits.max-key-bytes 4294967295)
    (>= limits.max-work limits.max-bytes)
    (trace.compiler-trace-limits-valid? (& limits.trace))))

;; `root` and `node` index the canonical root and node order of the rejected
;; candidate, or are -1 when the failure has no such position. Messages name
;; the rule that failed and never carry identity bytes, names or paths.
(defstruct CompilerIncrementalGraphError
  (code i64)
  (root i64)
  (node i64)
  (message String))

(define (compiler-graph-error
  [code : i64]
  [root : i64]
  [node : i64]
  [message : String]) : CompilerIncrementalGraphError
  (CompilerIncrementalGraphError code root node message))

;; Locates one stored result payload (#7187) in the result store (#7023). The
;; bytes are opaque here and never stand in for a semantic output identity.
(defstruct CompilerIncrementalStoredResultKey
  (domain String)
  (schema i64)
  (bytes (__tl_dyn-array u8)))

;; A coordinator's purpose domain and a name within it.
(defstruct CompilerIncrementalGraphRootName
  (purpose String)
  (name String))

(defstruct CompilerIncrementalGraphRoot
  (name CompilerIncrementalGraphRootName)
  (query identity.CompilerIncrementalIdentity))

;; Only a committed successful query is a node: every field is required, and
;; the trace is a finalized #7267 trace of exactly this query.
(defstruct CompilerIncrementalGraphNode
  (query identity.CompilerIncrementalIdentity)
  (output identity.CompilerIncrementalSemanticOutputIdentity)
  (stored-key CompilerIncrementalStoredResultKey)
  (trace trace.CompilerIncrementalTrace))

;; Canonical byte pieces the builder sorts: a root's encoded name and query
;; transcript, and a node's query transcript and the rest of its encoding.
(defstruct CompilerIncrementalGraphRootRecord
  (key String)
  (query String))

(defstruct CompilerIncrementalGraphNodeRecord
  (query String)
  (body String))

(import (stdlib.vector.vector CompilerIncrementalGraphRootRecord) as graph_root_vec)
(import (stdlib.vector.vector CompilerIncrementalGraphNodeRecord) as graph_node_vec)

;; state: 1 open, 2 finalized, 3 failed (`error` holds the first failure).
(defstruct CompilerIncrementalGraphBuilder
  (state i64)
  (limits CompilerIncrementalGraphLimits)
  (roots graph_root_vec.Vec)
  (nodes graph_node_vec.Vec)
  (planned-bytes i64)
  (error CompilerIncrementalGraphError))

;; Roots and nodes are in canonical order. `root-nodes` maps each root to its
;; node. The dependency and dependent lists are compressed rows of distinct,
;; ascending node indices; `topological` lists every node after all of its
;; dependencies, smallest index first among nodes that are ready together.
(defstruct CompilerIncrementalGraph
  (schema i64)
  (roots (__tl_dyn-array CompilerIncrementalGraphRoot))
  (root-nodes (__tl_dyn-array i64))
  (nodes (__tl_dyn-array CompilerIncrementalGraphNode))
  (dependency-start (__tl_dyn-array i64))
  (dependencies (__tl_dyn-array i64))
  (dependent-start (__tl_dyn-array i64))
  (dependents (__tl_dyn-array i64))
  (topological (__tl_dyn-array i64))
  (transcript (__tl_dyn-array u8))
  (fingerprint sha256.Sha256Digest))

(defenum ResultCompilerIncrementalGraphBuilder
  (Ok CompilerIncrementalGraphBuilder)
  (Err CompilerIncrementalGraphError))

(defenum ResultCompilerIncrementalGraph
  (Ok CompilerIncrementalGraph)
  (Err CompilerIncrementalGraphError))

(defenum ResultCompilerIncrementalGraphQuery
  (Ok identity.CompilerIncrementalIdentity)
  (Err CompilerIncrementalGraphError))

;; --- byte helpers ------------------------------------------------------------
(define (compiler-graph-bytes-string [bytes : (& bytes (__tl_dyn-array u8))]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity (array-length bytes))]
    (begin
      (byte_buf_core.byte-buf-builder-append-array (&mut out) bytes)
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

(define (compiler-graph-range-bytes
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [length : i64]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (set! (array-ref out index) (array-ref bytes (+ start index)))
          (set! index (+ index 1))))
      out)))

;; Unsigned lexicographic order of two byte ranges: -1, 0 or 1.
(define (compiler-graph-range-compare
  [left : (& left (__tl_dyn-array u8))]
  [left-start : i64]
  [left-length : i64]
  [right : (& right (__tl_dyn-array u8))]
  [right-start : i64]
  [right-length : i64]) : i64
  (let
    [limit : i64
      (if (< left-length right-length)
        left-length
        right-length)]
    [index : i64 0]
    [result : i64 0]
    (begin
      (while (and (= result 0) (< index limit))
        (let
          [a : i64 (cast (array-ref left (+ left-start index)) : i64)]
          [b : i64 (cast (array-ref right (+ right-start index)) : i64)]
          (begin
            (cond
              [(< a b) (set! result -1)]
              [(> a b) (set! result 1)]
              [else unit])
            (set! index (+ index 1)))))
      (cond
        [(!= result 0) result]
        [(< left-length right-length) -1]
        [(> left-length right-length) 1]
        [else 0]))))

(define (compiler-graph-string-compare
  [left : (& left str)]
  [right : (& right str)]) : i64
  (let
    [left-length : i64 (string.string-length left)]
    [right-length : i64 (string.string-length right)]
    [limit : i64
      (if (< left-length right-length)
        left-length
        right-length)]
    [index : i64 0]
    [result : i64 0]
    (begin
      (while (and (= result 0) (< index limit))
        (let
          [a : i64 (cast (string.string-ref left index) : i64)]
          [b : i64 (cast (string.string-ref right index) : i64)]
          (begin
            (cond
              [(< a b) (set! result -1)]
              [(> a b) (set! result 1)]
              [else unit])
            (set! index (+ index 1)))))
      (cond
        [(!= result 0) result]
        [(< left-length right-length) -1]
        [(> left-length right-length) 1]
        [else 0]))))

(define (compiler-graph-push-string-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : (& text str)]) : unit
  (let
    [index : i64 0]
    (while (< index (string.string-length text))
      (begin
        (byte_buf_core.byte-buf-builder-push
          out
          (cast (string.string-ref text index) : u8))
        (set! index (+ index 1))))))

;; --- field validation and encoding --------------------------------------------
(define (compiler-graph-identity-limits
  [limits : (& limits CompilerIncrementalGraphLimits)]) : identity.CompilerIncrementalIdentityLimits
  (trace.compiler-trace-identity-limits (& limits.trace)))

;; Rebuild a query identity from its transcript. The transcript must decode
;; under the schema with an available compiler-build identity; the fingerprint
;; is recomputed, never taken from the caller.
(define (compiler-graph-query-from-transcript
  [transcript : (__tl_dyn-array u8)]
  [limits : (& limits CompilerIncrementalGraphLimits)]
  [scratch : i64]
  [root : i64]
  [node : i64]) : ResultCompilerIncrementalGraphQuery
  (let
    [shape : i64
      (if (or
        (= (array-length transcript) 0)
        (> (array-length transcript) limits.trace.max-edge-bytes))
        -1
        (with-escape
          (arena.Arena scratch)
          (compiler-graph-query-shape (& transcript) limits)))]
    (if (< shape 0)
      (ResultCompilerIncrementalGraphQuery.Err
        (compiler-graph-error
          compiler-graph-error-query
          root
          node
          "query identity does not decode with an admitted compiler-build identity"))
      (match (with-escape
        (arena.Arena scratch)
        (identity.compiler-incremental-digest-array (& transcript)))
        [(sha256.Sha256FinalizeErr _)
          (ResultCompilerIncrementalGraphQuery.Err
            (compiler-graph-error
              compiler-graph-error-query
              root
              node
              "query identity fingerprint failed"))]
        [(sha256.Sha256FinalizeOk digest)
          (ResultCompilerIncrementalGraphQuery.Ok
            (identity.CompilerIncrementalIdentity
              identity.compiler-incremental-identity-schema
              (/ shape 4294967296)
              (- shape (* (/ shape 4294967296) 4294967296))
              transcript
              digest))]))))

;; A transcript's query-kind tag and record count packed as
;; tag * 2^32 + count, or -1 when it does not decode under the schema with an
;; admitted compiler-build identity. Callers run it in a scratch arena.
(define (compiler-graph-query-shape
  [transcript : (& transcript (__tl_dyn-array u8))]
  [limits : (& limits CompilerIncrementalGraphLimits)]) : i64
  (let
    [id-limits : identity.CompilerIncrementalIdentityLimits
      (compiler-graph-identity-limits limits)]
    [decoded : identity.ResultCompilerIncrementalDecodedQuery
      (identity.compiler-incremental-identity-decode transcript (& id-limits))]
    (compiler-graph-decoded-shape (& decoded))))

(define (compiler-graph-decoded-shape
  [decoded : (& decoded identity.ResultCompilerIncrementalDecodedQuery)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view decoded)
    [(identity.ResultCompilerIncrementalDecodedQuery.Err _) -1]
    [(identity.ResultCompilerIncrementalDecodedQuery.Ok query)
      (if (identity.compiler-incremental-string-eq?
        (& query.compiler-build.domain)
        (& identity.compiler-incremental-build-domain))
        (+
          (*
            (identity.compiler-incremental-query-kind-tag (& query.kind))
            4294967296)
          (array-length query.inputs))
        -1)]))

(define (compiler-graph-transcript-digest
  [bytes : (& bytes (__tl_dyn-array u8))]) : sha256.Sha256FinalizeResult
  (identity.compiler-incremental-digest-array bytes))

;; A caller-supplied identity is admitted only when it is exactly the identity
;; its transcript rebuilds.
(define (compiler-graph-query-valid?
  [query : (& query identity.CompilerIncrementalIdentity)]
  [limits : (& limits CompilerIncrementalGraphLimits)]) : bool
  (let
    [length : i64 (array-length query.transcript)]
    [shape : i64
      (if (or (= length 0) (> length limits.trace.max-edge-bytes))
        -1
        (with-scratch (compiler-graph-query-shape (& query.transcript) limits)))]
    (and
      (>= shape 0)
      (= query.schema identity.compiler-incremental-identity-schema)
      (= query.query-kind-tag (/ shape 4294967296))
      (= query.record-count (- shape (* (/ shape 4294967296) 4294967296)))
      (match (compiler-graph-transcript-digest (& query.transcript))
        [(sha256.Sha256FinalizeErr _) false]
        [(sha256.Sha256FinalizeOk digest)
          (sha256.digest-eq? (& query.fingerprint) (& digest))]))))

(define (compiler-graph-root-name-valid?
  [name : (& name CompilerIncrementalGraphRootName)]
  [limits : (& limits CompilerIncrementalGraphLimits)]) : bool
  (and
    (identity.compiler-incremental-domain-valid?
      (& name.purpose)
      limits.max-name-bytes)
    (identity.compiler-incremental-text-valid?
      (& name.name)
      false
      limits.max-name-bytes)))

;; A root's canonical name bytes: framed purpose, then framed name.
(define (compiler-graph-encode-root-name
  [name : (& name CompilerIncrementalGraphRootName)]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 64)]
    (begin
      (binary.compiler-incremental-binary-push-string!
        (&mut out)
        (& name.purpose))
      (binary.compiler-incremental-binary-push-string! (&mut out) (& name.name))
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

(define (compiler-graph-output-valid?
  [output : (& output identity.CompilerIncrementalSemanticOutputIdentity)]
  [limits : (& limits CompilerIncrementalGraphLimits)]) : bool
  (let
    [id-limits : identity.CompilerIncrementalIdentityLimits
      (compiler-graph-identity-limits limits)]
    (and
      (identity.compiler-incremental-child-valid?
        (& output.identity)
        (& id-limits))
      (identity.compiler-incremental-string-eq?
        (& output.identity.domain)
        (& identity.compiler-incremental-semantic-output-domain)))))

;; The exact bytes a parent's child-result observation records for this output.
(define (compiler-graph-encode-output
  [output : (& output identity.CompilerIncrementalSemanticOutputIdentity)]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 96)]
    (begin
      (identity.compiler-incremental-push-child! (&mut out) (& output.identity))
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

(define (compiler-graph-stored-key-valid?
  [key : (& key CompilerIncrementalStoredResultKey)]
  [limits : (& limits CompilerIncrementalGraphLimits)]) : bool
  (and
    (identity.compiler-incremental-string-eq?
      (& key.domain)
      (& compiler-incremental-stored-result-domain))
    (> key.schema 0)
    (<= key.schema 4294967295)
    (> (array-length key.bytes) 0)
    (<= (array-length key.bytes) limits.max-key-bytes)))

(define (compiler-graph-push-stored-key!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [key : (& key CompilerIncrementalStoredResultKey)]) : unit
  (begin
    (binary.compiler-incremental-binary-push-string! out (& key.domain))
    (byte_le.push-u32! out key.schema)
    (byte_le.push-u32! out (array-length key.bytes))
    (binary.compiler-incremental-binary-push-array! out (& key.bytes))))

;; Everything a node encodes after its query transcript.
(define (compiler-graph-encode-node-body
  [node : (& node CompilerIncrementalGraphNode)]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity
        (+ 128 (array-length node.trace.transcript)))]
    (begin
      (binary.compiler-incremental-binary-push-u8!
        (&mut out)
        compiler-graph-output-tag)
      (identity.compiler-incremental-push-child!
        (&mut out)
        (& node.output.identity))
      (binary.compiler-incremental-binary-push-u8!
        (&mut out)
        compiler-graph-key-tag)
      (compiler-graph-push-stored-key! (&mut out) (& node.stored-key))
      (byte_le.push-u32! (&mut out) (array-length node.trace.transcript))
      (binary.compiler-incremental-binary-push-array!
        (&mut out)
        (& node.trace.transcript))
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

;; --- builder --------------------------------------------------------------------
(define (compiler-graph-header-bytes) : i64
  (+ 12 (string.string-length compiler-incremental-graph-domain)))

(define (compiler-graph-begin [limits : CompilerIncrementalGraphLimits]) : ResultCompilerIncrementalGraphBuilder
  (if (not (compiler-graph-limits-valid? (& limits)))
    (ResultCompilerIncrementalGraphBuilder.Err
      (compiler-graph-error
        compiler-graph-error-limit-config
        -1
        -1
        "graph limits are invalid"))
    (ResultCompilerIncrementalGraphBuilder.Ok
      (CompilerIncrementalGraphBuilder
        1
        limits
        (graph_root_vec.with-capacity 0)
        (graph_node_vec.with-capacity 0)
        (compiler-graph-header-bytes)
        (compiler-graph-error 0 -1 -1 "")))))

;; Record the first failure and close the builder; always false.
(define (compiler-graph-fail!
  [builder : (&mut builder CompilerIncrementalGraphBuilder)]
  [code : i64]
  [message : String]) : bool
  (begin
    (when
      (= builder.state 1)
      (set! builder.error (compiler-graph-error code -1 -1 message)))
    (set! builder.state 3)
    false))

(define (compiler-graph-abort!
  [builder : (&mut builder CompilerIncrementalGraphBuilder)]) : unit
  (begin
    (compiler-graph-fail!
      builder
      compiler-graph-error-state
      "graph builder aborted")
    unit))

;; Reserve the encoded size of one more record; false once over budget.
(define (compiler-graph-reserve!
  [builder : (&mut builder CompilerIncrementalGraphBuilder)]
  [bytes : i64]) : bool
  (let
    [planned : i64
      (identity.compiler-incremental-add-size builder.planned-bytes bytes)]
    (if (or (< planned 0) (> planned builder.limits.max-bytes))
      (compiler-graph-fail!
        builder
        compiler-graph-error-limit
        "graph exceeds its byte limit")
      (begin
        (set! builder.planned-bytes planned)
        true))))

(define (compiler-graph-add-root!
  [builder : (&mut builder CompilerIncrementalGraphBuilder)]
  [root : CompilerIncrementalGraphRoot]) : bool
  (cond
    [(!= builder.state 1) false]
    [(>= (graph_root_vec.len (& builder.roots)) builder.limits.max-roots)
      (compiler-graph-fail!
        builder
        compiler-graph-error-limit
        "graph exceeds its root limit")]
    [(not (compiler-graph-root-name-valid? (& root.name) (& builder.limits)))
      (compiler-graph-fail!
        builder
        compiler-graph-error-root
        "root name is invalid")]
    [(not (compiler-graph-query-valid? (& root.query) (& builder.limits)))
      (compiler-graph-fail!
        builder
        compiler-graph-error-query
        "root query identity is invalid")]
    [else
      (let
        [record : CompilerIncrementalGraphRootRecord
          (CompilerIncrementalGraphRootRecord
            (compiler-graph-encode-root-name (& root.name))
            (compiler-graph-bytes-string (& root.query.transcript)))]
        (if (compiler-graph-reserve!
          builder
          (+
            4
            (+
              (string.string-length record.key)
              (string.string-length record.query))))
          (begin
            (graph_root_vec.push-ref! (&mut builder.roots) record)
            true)
          false))]))

(define (compiler-graph-trace-matches-node?
  [node : (& node CompilerIncrementalGraphNode)]
  [limits : (& limits CompilerIncrementalGraphLimits)]) : bool
  (and
    (binary.compiler-incremental-binary-bytes-eq?
      (& node.trace.parent.transcript)
      (& node.query.transcript))
    (> (array-length node.trace.transcript) 0)
    (<= (array-length node.trace.transcript) limits.trace.max-bytes)
    (>= node.trace.edge-count 0)
    (<= node.trace.edge-count limits.trace.max-edges)
    (match (compiler-graph-transcript-digest (& node.trace.transcript))
      [(sha256.Sha256FinalizeErr _) false]
      [(sha256.Sha256FinalizeOk digest)
        (sha256.digest-eq? (& node.trace.fingerprint) (& digest))])))

;; Full #7267 validation of a trace. Callers run it in a scratch arena.
(define (compiler-graph-trace-valid?
  [value : (& value trace.CompilerIncrementalTrace)]
  [limits : (& limits CompilerIncrementalGraphLimits)]) : bool
  (match (trace.compiler-trace-decode value (& limits.trace))
    [(trace.ResultCompilerIncrementalTraceRecords.Ok _) true]
    [(trace.ResultCompilerIncrementalTraceRecords.Err _) false]))

(define (compiler-graph-add-node!
  [builder : (&mut builder CompilerIncrementalGraphBuilder)]
  [node : CompilerIncrementalGraphNode]) : bool
  (cond
    [(!= builder.state 1) false]
    [(>= (graph_node_vec.len (& builder.nodes)) builder.limits.max-nodes)
      (compiler-graph-fail!
        builder
        compiler-graph-error-limit
        "graph exceeds its node limit")]
    [(not (compiler-graph-query-valid? (& node.query) (& builder.limits)))
      (compiler-graph-fail!
        builder
        compiler-graph-error-query
        "node query identity is invalid")]
    [(not (compiler-graph-output-valid? (& node.output) (& builder.limits)))
      (compiler-graph-fail!
        builder
        compiler-graph-error-output
        "node semantic output identity is invalid")]
    [(not
        (compiler-graph-stored-key-valid?
          (& node.stored-key)
          (& builder.limits)))
      (compiler-graph-fail!
        builder
        compiler-graph-error-key
        "node stored-result key is invalid")]
    [(not
        (binary.compiler-incremental-binary-bytes-eq?
          (& node.trace.parent.transcript)
          (& node.query.transcript)))
      (compiler-graph-fail!
        builder
        compiler-graph-error-trace-parent
        "node trace belongs to another query")]
    [(not (compiler-graph-trace-matches-node? (& node) (& builder.limits)))
      (compiler-graph-fail!
        builder
        compiler-graph-error-trace
        "node trace is invalid")]
    [else
      (let
        [record : CompilerIncrementalGraphNodeRecord
          (CompilerIncrementalGraphNodeRecord
            (compiler-graph-bytes-string (& node.query.transcript))
            (compiler-graph-encode-node-body (& node)))]
        (if (compiler-graph-reserve!
          builder
          (+
            4
            (+
              (string.string-length record.query)
              (string.string-length record.body))))
          (begin
            (graph_node_vec.push-ref! (&mut builder.nodes) record)
            true)
          false))]))

;; Sort the candidate, collapse byte-identical repeats, reject conflicting
;; ones, and publish only what the canonical decoder accepts.
(define (compiler-graph-finalize [builder : CompilerIncrementalGraphBuilder]) : ResultCompilerIncrementalGraph
  (cond
    [(= builder.state 3) (ResultCompilerIncrementalGraph.Err builder.error)]
    [(!= builder.state 1)
      (ResultCompilerIncrementalGraph.Err
        (compiler-graph-error
          compiler-graph-error-state
          -1
          -1
          "graph builder is not open"))]
    [else
      (let
        [root-count : i64 (graph_root_vec.len (& builder.roots))]
        [node-count : i64 (graph_node_vec.len (& builder.nodes))]
        [root-order : (__tl_dyn-array i64)
          (compiler-graph-identity-order root-count)]
        [node-order : (__tl_dyn-array i64)
          (compiler-graph-identity-order node-count)]
        [scratch : (__tl_dyn-array i64)
          (__tl_make-array
            i64
            (if (> root-count node-count)
              root-count
              node-count))]
        [out : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-with-capacity builder.planned-bytes)]
        (begin
          (compiler-graph-sort-range!
            (&mut root-order)
            (&mut scratch)
            0
            root-count
            (& builder.roots.slots)
            (& builder.nodes.slots)
            1)
          (compiler-graph-sort-range!
            (&mut node-order)
            (&mut scratch)
            0
            node-count
            (& builder.roots.slots)
            (& builder.nodes.slots)
            2)
          (binary.compiler-incremental-binary-push-string!
            (&mut out)
            (& compiler-incremental-graph-domain))
          (byte_le.push-u32! (&mut out) compiler-incremental-graph-schema)
          (cond
            [(not
                (compiler-graph-write-roots!
                  (&mut out)
                  (& builder.roots.slots)
                  (& root-order)))
              (ResultCompilerIncrementalGraph.Err
                (compiler-graph-error
                  compiler-graph-error-conflict
                  -1
                  -1
                  "one root name names two queries"))]
            [(not
                (compiler-graph-write-nodes!
                  (&mut out)
                  (& builder.nodes.slots)
                  (& node-order)))
              (ResultCompilerIncrementalGraph.Err
                (compiler-graph-error
                  compiler-graph-error-conflict
                  -1
                  -1
                  "one query has two different node records"))]
            [else
              (let
                [bytes : (__tl_dyn-array u8)
                  (byte_buf_core.byte-buf-builder-finish-array (& out))]
                (compiler-graph-decode (& bytes) (& builder.limits)))])))]))

(define (compiler-graph-identity-order [count : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref out index) index)
          (set! index (+ index 1))))
      out)))

;; Write the distinct roots in sorted order; false when one name is bound to
;; two different queries.
(define (compiler-graph-write-roots!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [records : (& records (__tl_dyn-array CompilerIncrementalGraphRootRecord))]
  [order : (& order (__tl_dyn-array i64))]) : bool
  (let
    [count : i64 0]
    [index : i64 0]
    [ok? : bool true]
    [no-nodes : (__tl_dyn-array CompilerIncrementalGraphNodeRecord)
      (__tl_make-array CompilerIncrementalGraphNodeRecord 0)]
    (begin
      (while (and ok? (< index (array-length order)))
        (begin
          (when
            (or
              (= index 0)
              (!=
                (compiler-graph-record-compare
                  records
                  (& no-nodes)
                  1
                  order
                  (- index 1)
                  index
                  true)
                0))
            (set! count (+ count 1)))
          (when
            (and
              (> index 0)
              (=
                (compiler-graph-record-compare
                  records
                  (& no-nodes)
                  1
                  order
                  (- index 1)
                  index
                  true)
                0)
              (!=
                (compiler-graph-record-compare
                  records
                  (& no-nodes)
                  1
                  order
                  (- index 1)
                  index
                  false)
                0))
            (set! ok? false))
          (set! index (+ index 1))))
      (when
        ok?
        (byte_le.push-u32! out count)
        (set! index 0)
        (while (< index (array-length order))
          (begin
            (when
              (or
                (= index 0)
                (!=
                  (compiler-graph-record-compare
                    records
                    (& no-nodes)
                    1
                    order
                    (- index 1)
                    index
                    true)
                  0))
              (let
                [record : CompilerIncrementalGraphRootRecord
                  (owned_view.compiler-owned-array-element-shared-view
                    (owned_view.compiler-owned-reference-shared-view records)
                    (array-ref order index))]
                (begin
                  (compiler-graph-push-string-bytes! out (& record.key))
                  (byte_le.push-u32! out (string.string-length record.query))
                  (compiler-graph-push-string-bytes! out (& record.query)))))
            (set! index (+ index 1)))))
      ok?)))

;; Write the distinct nodes in sorted order; false when one query carries two
;; different records.
(define (compiler-graph-write-nodes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [records : (& records (__tl_dyn-array CompilerIncrementalGraphNodeRecord))]
  [order : (& order (__tl_dyn-array i64))]) : bool
  (let
    [count : i64 0]
    [index : i64 0]
    [ok? : bool true]
    [roots : (__tl_dyn-array CompilerIncrementalGraphRootRecord)
      (__tl_make-array CompilerIncrementalGraphRootRecord 0)]
    (begin
      (while (and ok? (< index (array-length order)))
        (begin
          (when
            (or
              (= index 0)
              (!=
                (compiler-graph-record-compare
                  (& roots)
                  records
                  2
                  order
                  (- index 1)
                  index
                  true)
                0))
            (set! count (+ count 1)))
          (when
            (and
              (> index 0)
              (=
                (compiler-graph-record-compare
                  (& roots)
                  records
                  2
                  order
                  (- index 1)
                  index
                  true)
                0)
              (!=
                (compiler-graph-record-compare
                  (& roots)
                  records
                  2
                  order
                  (- index 1)
                  index
                  false)
                0))
            (set! ok? false))
          (set! index (+ index 1))))
      (when
        ok?
        (byte_le.push-u32! out count)
        (set! index 0)
        (while (< index (array-length order))
          (begin
            (when
              (or
                (= index 0)
                (!=
                  (compiler-graph-record-compare
                    (& roots)
                    records
                    2
                    order
                    (- index 1)
                    index
                    true)
                  0))
              (let
                [record : CompilerIncrementalGraphNodeRecord
                  (owned_view.compiler-owned-array-element-shared-view
                    (owned_view.compiler-owned-reference-shared-view records)
                    (array-ref order index))]
                (begin
                  (byte_le.push-u32! out (string.string-length record.query))
                  (compiler-graph-push-string-bytes! out (& record.query))
                  (compiler-graph-push-string-bytes! out (& record.body)))))
            (set! index (+ index 1)))))
      ok?)))

;; Compare the records at order[left] and order[right]: mode 1 roots by name
;; (then query unless `primary-only?`), mode 2 nodes by query (then body).
(define (compiler-graph-record-compare
  [roots : (& roots (__tl_dyn-array CompilerIncrementalGraphRootRecord))]
  [nodes : (& nodes (__tl_dyn-array CompilerIncrementalGraphNodeRecord))]
  [mode : i64]
  [order : (& order (__tl_dyn-array i64))]
  [left : i64]
  [right : i64]
  [primary-only? : bool]) : i64
  (compiler-graph-index-compare
    roots
    nodes
    mode
    (array-ref order left)
    (array-ref order right)
    primary-only?))

(define (compiler-graph-index-compare
  [roots : (& roots (__tl_dyn-array CompilerIncrementalGraphRootRecord))]
  [nodes : (& nodes (__tl_dyn-array CompilerIncrementalGraphNodeRecord))]
  [mode : i64]
  [left : i64]
  [right : i64]
  [primary-only? : bool]) : i64
  (cond
    [(= mode 1)
      (let
        [a : CompilerIncrementalGraphRootRecord
          (owned_view.compiler-owned-array-element-shared-view
            (owned_view.compiler-owned-reference-shared-view roots)
            left)]
        [b : CompilerIncrementalGraphRootRecord
          (owned_view.compiler-owned-array-element-shared-view
            (owned_view.compiler-owned-reference-shared-view roots)
            right)]
        [order : i64 (compiler-graph-string-compare (& a.key) (& b.key))]
        (if (or primary-only? (!= order 0))
          order
          (compiler-graph-string-compare (& a.query) (& b.query))))]
    [(= mode 2)
      (let
        [a : CompilerIncrementalGraphNodeRecord
          (owned_view.compiler-owned-array-element-shared-view
            (owned_view.compiler-owned-reference-shared-view nodes)
            left)]
        [b : CompilerIncrementalGraphNodeRecord
          (owned_view.compiler-owned-array-element-shared-view
            (owned_view.compiler-owned-reference-shared-view nodes)
            right)]
        [order : i64 (compiler-graph-string-compare (& a.query) (& b.query))]
        (if (or primary-only? (!= order 0))
          order
          (compiler-graph-string-compare (& a.body) (& b.body))))]
    [(< left right) -1]
    [(> left right) 1]
    [else 0]))

;; --- canonical decode -------------------------------------------------------------
;; One child-result edge read from a node's trace, not yet resolved.
(defstruct CompilerIncrementalGraphEdgeRecord
  (node i64)
  (child String)
  (observation String))

(import (stdlib.vector.vector CompilerIncrementalGraphEdgeRecord) as graph_edge_vec)

(defenum ResultCompilerIncrementalGraphTrace
  (Ok trace.CompilerIncrementalTrace)
  (Err CompilerIncrementalGraphError))

(define (compiler-graph-reader-error
  [reader : (& reader binary.CompilerIncrementalBinaryReader)]
  [root : i64]
  [node : i64]) : CompilerIncrementalGraphError
  (if (= reader.cursor.error-code byte_reader.error-work-limit)
    (compiler-graph-error
      compiler-graph-error-limit
      root
      node
      "graph decode exceeds its work limit")
    (compiler-graph-error
      compiler-graph-error-framing
      root
      node
      "graph bytes are truncated or malformed")))

;; The next u32-framed byte string, 1..max-length bytes long.
(define (compiler-graph-read-framed!
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]
  [max-length : i64]) : (__tl_dyn-array u8)
  (let
    [length-offset : i64 reader.cursor.offset]
    [length : i64 (byte_reader.read-u32! (&mut reader.cursor))]
    (cond
      [(not reader.cursor.ok?) (__tl_make-array u8 0)]
      [(or (= length 0) (> length max-length))
        (begin
          (binary.compiler-incremental-binary-fail!
            reader
            byte_reader.error-truncated
            length-offset
            "graph field length is out of range")
          (__tl_make-array u8 0))]
      [(not (byte_reader.consume! (&mut reader.cursor) length))
        (__tl_make-array u8 0)]
      [else
        (let
          [start : i64 reader.cursor.offset]
          (begin
            (byte_reader.skip! (&mut reader.cursor) length)
            (compiler-graph-range-bytes (& reader.cursor.bytes) start length)))])))

;; Collect the child-result edges (trace key tag 9) of node `node`.
(define (compiler-graph-collect-edges!
  [transcript : (& transcript (__tl_dyn-array u8))]
  [first-record : i64]
  [count : i64]
  [node : i64]
  [limits : (& limits CompilerIncrementalGraphLimits)]
  [edges : (&mut edges graph_edge_vec.Vec)]) : bool
  (let
    [offset : i64 first-record]
    [index : i64 0]
    [ok? : bool true]
    (begin
      (while (and ok? (< index count))
        (let
          [key-length : i64 (compiler-graph-u32-at transcript offset)]
          [key-start : i64 (+ offset 4)]
          [observation-length : i64
            (compiler-graph-u32-at transcript (+ key-start key-length))]
          [observation-start : i64 (+ (+ key-start key-length) 4)]
          (if (or
            (< key-length 1)
            (< observation-length 0)
            (not
              (byte_reader.range-present?
                (array-length transcript)
                observation-start
                observation-length)))
            (set! ok? false)
            (begin
              (when
                (= (cast (array-ref transcript key-start) : i64) 9)
                (let
                  [sequence-length : i64
                    (compiler-graph-u32-at transcript (+ key-start 1))]
                  [child-length-at : i64 (+ (+ key-start 13) sequence-length)]
                  [child-length : i64
                    (compiler-graph-u32-at transcript child-length-at)]
                  [child-start : i64 (+ child-length-at 4)]
                  (if (and
                    (>= sequence-length 0)
                    (>= child-length 0)
                    (= (+ child-start child-length) (+ key-start key-length))
                    (< (graph_edge_vec.len edges) limits.max-edges))
                    (graph_edge_vec.push-ref!
                      edges
                      (CompilerIncrementalGraphEdgeRecord
                        node
                        (compiler-graph-range-string
                          transcript
                          child-start
                          child-length)
                        (compiler-graph-range-string
                          transcript
                          observation-start
                          observation-length)))
                    (set! ok? false))))
              (set! offset (+ observation-start observation-length))
              (set! index (+ index 1))))))
      ok?)))

;; The little-endian u32 at `offset`, or -1 when it is not wholly present.
(define (compiler-graph-u32-at
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]) : i64
  (if (byte_reader.range-present? (array-length bytes) offset 4)
    (byte_le.read-u32 bytes offset)
    -1))

(define (compiler-graph-range-string
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [length : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity length)]
    (begin
      (byte_buf_core.byte-buf-builder-append-array-range
        (&mut out)
        bytes
        start
        length)
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

;; Rebuild node `node`'s trace from its transcript, check it is a trace of
;; exactly `parent`, and collect its child-result edges.
(define (compiler-graph-read-trace
  [parent : (& parent identity.CompilerIncrementalIdentity)]
  [transcript : (__tl_dyn-array u8)]
  [scratch : i64]
  [node : i64]
  [limits : (& limits CompilerIncrementalGraphLimits)]
  [edges : (&mut edges graph_edge_vec.Vec)]) : ResultCompilerIncrementalGraphTrace
  (let
    [domain-length : i64 (compiler-graph-u32-at (& transcript) 0)]
    [parent-length-at : i64 (+ (+ 4 domain-length) 4)]
    [parent-length : i64
      (compiler-graph-u32-at (& transcript) parent-length-at)]
    [parent-start : i64 (+ parent-length-at 4)]
    [count : i64
      (compiler-graph-u32-at (& transcript) (+ parent-start parent-length))]
    (cond
      [(or (< domain-length 0) (< parent-length 0) (< count 0))
        (ResultCompilerIncrementalGraphTrace.Err
          (compiler-graph-error
            compiler-graph-error-trace
            -1
            node
            "node trace header is malformed"))]
      [(!=
          (compiler-graph-range-compare
            (& transcript)
            parent-start
            parent-length
            (& parent.transcript)
            0
            (array-length parent.transcript))
          0)
        (ResultCompilerIncrementalGraphTrace.Err
          (compiler-graph-error
            compiler-graph-error-trace-parent
            -1
            node
            "node trace belongs to another query"))]
      [else
        (match (with-escape
          (arena.Arena scratch)
          (compiler-graph-transcript-digest (& transcript)))
          [(sha256.Sha256FinalizeErr _)
            (ResultCompilerIncrementalGraphTrace.Err
              (compiler-graph-error
                compiler-graph-error-trace
                -1
                node
                "node trace fingerprint failed"))]
          [(sha256.Sha256FinalizeOk digest)
            (let
              [first-record : i64 (+ (+ parent-start parent-length) 4)]
              [value : trace.CompilerIncrementalTrace
                (trace.CompilerIncrementalTrace
                  trace.compiler-incremental-trace-schema
                  (identity.CompilerIncrementalIdentity
                    parent.schema
                    parent.query-kind-tag
                    parent.record-count
                    (binary.compiler-incremental-binary-copy
                      (& parent.transcript))
                    (sha256.Sha256Digest
                      (sha256.digest-bytes (& parent.fingerprint))))
                  count
                  transcript
                  digest)]
              (cond
                [(not
                    (with-escape
                      (arena.Arena scratch)
                      (compiler-graph-trace-valid? (& value) limits)))
                  (ResultCompilerIncrementalGraphTrace.Err
                    (compiler-graph-error
                      compiler-graph-error-trace
                      -1
                      node
                      "node trace is invalid"))]
                [(not
                    (compiler-graph-collect-edges!
                      (& value.transcript)
                      first-record
                      count
                      node
                      limits
                      edges))
                  (ResultCompilerIncrementalGraphTrace.Err
                    (compiler-graph-error
                      compiler-graph-error-limit
                      -1
                      node
                      "graph exceeds its edge limit"))]
                [else (ResultCompilerIncrementalGraphTrace.Ok value)]))])])))

;; Decode and validate canonical graph bytes. Validation's transient decodes
;; run in one scratch arena that is released before the graph is returned.
(define (compiler-graph-decode
  [bytes : (& bytes (__tl_dyn-array u8))]
  [limits : (& limits CompilerIncrementalGraphLimits)]) : ResultCompilerIncrementalGraph
  (let
    [scratch : arena.Arena (arena.make)]
    [result : ResultCompilerIncrementalGraph
      (compiler-graph-decode-in bytes limits scratch.handle)]
    (begin
      (arena.destroy-safe! scratch)
      result)))

(define (compiler-graph-decode-in
  [bytes : (& bytes (__tl_dyn-array u8))]
  [limits : (& limits CompilerIncrementalGraphLimits)]
  [scratch : i64]) : ResultCompilerIncrementalGraph
  (cond
    [(not (compiler-graph-limits-valid? limits))
      (ResultCompilerIncrementalGraph.Err
        (compiler-graph-error
          compiler-graph-error-limit-config
          -1
          -1
          "graph limits are invalid"))]
    [(> (array-length bytes) limits.max-bytes)
      (ResultCompilerIncrementalGraph.Err
        (compiler-graph-error
          compiler-graph-error-limit
          -1
          -1
          "graph exceeds its byte limit"))]
    [else
      (let
        [reader : binary.CompilerIncrementalBinaryReader
          (binary.compiler-incremental-binary-reader
            bytes
            limits.max-work
            limits.max-work
            limits.max-name-bytes)]
        [domain : String
          (binary.compiler-incremental-binary-read-string! (&mut reader) false)]
        [schema : i64 (byte_reader.read-u32! (&mut reader.cursor))]
        [root-count : i64 (byte_reader.read-u32! (&mut reader.cursor))]
        (begin
          (when
            (not reader.cursor.ok?)
            (return
              (ResultCompilerIncrementalGraph.Err
                (compiler-graph-reader-error (& reader) -1 -1))))
          (when
            (or
              (not
                (identity.compiler-incremental-string-eq?
                  (& domain)
                  (& compiler-incremental-graph-domain)))
              (!= schema compiler-incremental-graph-schema))
            (return
              (ResultCompilerIncrementalGraph.Err
                (compiler-graph-error
                  compiler-graph-error-schema
                  -1
                  -1
                  "graph domain or schema is not supported"))))
          (when
            (> root-count limits.max-roots)
            (return
              (ResultCompilerIncrementalGraph.Err
                (compiler-graph-error
                  compiler-graph-error-limit
                  -1
                  -1
                  "graph exceeds its root limit"))))
          (when
            (>
              root-count
              (/
                (- reader.cursor.end reader.cursor.offset)
                compiler-graph-min-root-bytes))
            (return
              (ResultCompilerIncrementalGraph.Err
                (compiler-graph-error
                  compiler-graph-error-framing
                  -1
                  -1
                  "graph root count exceeds the remaining bytes"))))
          (compiler-graph-decode-body (&mut reader) root-count limits scratch)))]))

(define (compiler-graph-decode-body
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]
  [root-count : i64]
  [limits : (& limits CompilerIncrementalGraphLimits)]
  [scratch : i64]) : ResultCompilerIncrementalGraph
  (let
    [id-limits : identity.CompilerIncrementalIdentityLimits
      (compiler-graph-identity-limits limits)]
    [roots : (__tl_dyn-array CompilerIncrementalGraphRoot)
      (__tl_make-array CompilerIncrementalGraphRoot root-count)]
    [index : i64 0]
    [previous-start : i64 0]
    [previous-length : i64 0]
    (begin
      (while (< index root-count)
        (let
          [key-start : i64 reader.cursor.offset]
          [purpose : String
            (binary.compiler-incremental-binary-read-string! reader false)]
          [name : String
            (binary.compiler-incremental-binary-read-string! reader false)]
          [key-length : i64 (- reader.cursor.offset key-start)]
          [query-bytes : (__tl_dyn-array u8)
            (compiler-graph-read-framed! reader limits.trace.max-edge-bytes)]
          [root-name : CompilerIncrementalGraphRootName
            (CompilerIncrementalGraphRootName purpose name)]
          (begin
            (when
              (not reader.cursor.ok?)
              (return
                (ResultCompilerIncrementalGraph.Err
                  (compiler-graph-reader-error reader index -1))))
            (when
              (and
                (> index 0)
                (>=
                  (compiler-graph-range-compare
                    (& reader.cursor.bytes)
                    previous-start
                    previous-length
                    (& reader.cursor.bytes)
                    key-start
                    key-length)
                  0))
              (return
                (ResultCompilerIncrementalGraph.Err
                  (compiler-graph-error
                    compiler-graph-error-order
                    index
                    -1
                    "graph roots are not in strictly increasing canonical order"))))
            (when
              (not (compiler-graph-root-name-valid? (& root-name) limits))
              (return
                (ResultCompilerIncrementalGraph.Err
                  (compiler-graph-error
                    compiler-graph-error-root
                    index
                    -1
                    "root name is invalid"))))
            (let
              [query
                (try
                  (compiler-graph-query-from-transcript
                    query-bytes
                    limits
                    scratch
                    index
                    -1))]
              (set!
                (array-ref roots index)
                (CompilerIncrementalGraphRoot root-name query)))
            (set! previous-start key-start)
            (set! previous-length key-length)
            (set! index (+ index 1)))))
      (let
        [node-count : i64 (byte_reader.read-u32! (&mut reader.cursor))]
        (begin
          (when
            (not reader.cursor.ok?)
            (return
              (ResultCompilerIncrementalGraph.Err
                (compiler-graph-reader-error reader -1 -1))))
          (when
            (> node-count limits.max-nodes)
            (return
              (ResultCompilerIncrementalGraph.Err
                (compiler-graph-error
                  compiler-graph-error-limit
                  -1
                  -1
                  "graph exceeds its node limit"))))
          (when
            (>
              node-count
              (/
                (- reader.cursor.end reader.cursor.offset)
                compiler-graph-min-node-bytes))
            (return
              (ResultCompilerIncrementalGraph.Err
                (compiler-graph-error
                  compiler-graph-error-framing
                  -1
                  -1
                  "graph node count exceeds the remaining bytes"))))
          (let
            [nodes : (__tl_dyn-array CompilerIncrementalGraphNode)
              (__tl_make-array CompilerIncrementalGraphNode node-count)]
            [edges : graph_edge_vec.Vec (graph_edge_vec.with-capacity 0)]
            (begin
              (set! index 0)
              (while (< index node-count)
                (let
                  [query-start : i64 (+ reader.cursor.offset 4)]
                  [query-bytes : (__tl_dyn-array u8)
                    (compiler-graph-read-framed!
                      reader
                      limits.trace.max-edge-bytes)]
                  [query-length : i64 (array-length query-bytes)]
                  [output-tag : i64 (byte_reader.read-u8! (&mut reader.cursor))]
                  [output : identity.CompilerIncrementalSemanticOutputIdentity
                    (identity.CompilerIncrementalSemanticOutputIdentity
                      (identity.compiler-incremental-read-child!
                        reader
                        (& id-limits)))]
                  [key-tag : i64 (byte_reader.read-u8! (&mut reader.cursor))]
                  [key-domain : String
                    (binary.compiler-incremental-binary-read-string!
                      reader
                      false)]
                  [key-schema : i64
                    (byte_reader.read-u32! (&mut reader.cursor))]
                  [key-bytes : (__tl_dyn-array u8)
                    (compiler-graph-read-framed! reader limits.max-key-bytes)]
                  [trace-bytes : (__tl_dyn-array u8)
                    (compiler-graph-read-framed! reader limits.trace.max-bytes)]
                  [stored-key : CompilerIncrementalStoredResultKey
                    (CompilerIncrementalStoredResultKey
                      key-domain
                      key-schema
                      key-bytes)]
                  (begin
                    (when
                      (not reader.cursor.ok?)
                      (return
                        (ResultCompilerIncrementalGraph.Err
                          (compiler-graph-reader-error reader -1 index))))
                    (when
                      (or
                        (!= output-tag compiler-graph-output-tag)
                        (!= key-tag compiler-graph-key-tag))
                      (return
                        (ResultCompilerIncrementalGraph.Err
                          (compiler-graph-error
                            compiler-graph-error-framing
                            -1
                            index
                            "graph node field tag is unknown"))))
                    (when
                      (and
                        (> index 0)
                        (>=
                          (compiler-graph-range-compare
                            (& reader.cursor.bytes)
                            previous-start
                            previous-length
                            (& reader.cursor.bytes)
                            query-start
                            query-length)
                          0))
                      (return
                        (ResultCompilerIncrementalGraph.Err
                          (compiler-graph-error
                            compiler-graph-error-order
                            -1
                            index
                            "graph nodes are not in strictly increasing canonical order"))))
                    (when
                      (not (compiler-graph-output-valid? (& output) limits))
                      (return
                        (ResultCompilerIncrementalGraph.Err
                          (compiler-graph-error
                            compiler-graph-error-output
                            -1
                            index
                            "node semantic output identity is invalid"))))
                    (when
                      (not
                        (compiler-graph-stored-key-valid? (& stored-key) limits))
                      (return
                        (ResultCompilerIncrementalGraph.Err
                          (compiler-graph-error
                            compiler-graph-error-key
                            -1
                            index
                            "node stored-result key is invalid"))))
                    (let
                      [query
                        (try
                          (compiler-graph-query-from-transcript
                            query-bytes
                            limits
                            scratch
                            -1
                            index))]
                      [value
                        (try
                          (compiler-graph-read-trace
                            (& query)
                            trace-bytes
                            scratch
                            index
                            limits
                            (&mut edges)))]
                      (set!
                        (array-ref nodes index)
                        (CompilerIncrementalGraphNode
                          query
                          output
                          stored-key
                          value)))
                    (set! previous-start query-start)
                    (set! previous-length query-length)
                    (set! index (+ index 1)))))
              (if (!= reader.cursor.offset reader.cursor.end)
                (ResultCompilerIncrementalGraph.Err
                  (compiler-graph-error
                    compiler-graph-error-trailing
                    -1
                    -1
                    "graph bytes continue after the last node"))
                (compiler-graph-link
                  roots
                  nodes
                  (& edges)
                  (binary.compiler-incremental-binary-copy
                    (& reader.cursor.bytes))
                  limits)))))))))

;; --- linking: edges, roots, reachability, topology ---------------------------------
;; Index of the node whose query transcript is exactly `transcript`, or -1.
;; Nodes are in strictly increasing transcript order; only full bytes compare.
(define (compiler-graph-find-node-index
  [nodes : (& nodes (__tl_dyn-array CompilerIncrementalGraphNode))]
  [transcript : (& transcript str)]) : i64
  (let
    [low : i64 0]
    [high : i64 (array-length nodes)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< low high))
        (let
          [middle : i64 (+ low (/ (- high low) 2))]
          [node : CompilerIncrementalGraphNode
            (owned_view.compiler-owned-array-element-shared-view
              (owned_view.compiler-owned-reference-shared-view nodes)
              middle)]
          [order : i64
            (compiler-graph-array-string-compare
              (& node.query.transcript)
              transcript)]
          (cond
            [(= order 0) (set! found middle)]
            [(< order 0) (set! low (+ middle 1))]
            [else (set! high middle)])))
      found)))

;; Unsigned lexicographic order of a byte array and a string's bytes.
(define (compiler-graph-array-string-compare
  [left : (& left (__tl_dyn-array u8))]
  [right : (& right str)]) : i64
  (let
    [left-length : i64 (array-length left)]
    [right-length : i64 (string.string-length right)]
    [limit : i64
      (if (< left-length right-length)
        left-length
        right-length)]
    [index : i64 0]
    [result : i64 0]
    (begin
      (while (and (= result 0) (< index limit))
        (let
          [a : i64 (cast (array-ref left index) : i64)]
          [b : i64 (cast (string.string-ref right index) : i64)]
          (begin
            (cond
              [(< a b) (set! result -1)]
              [(> a b) (set! result 1)]
              [else unit])
            (set! index (+ index 1)))))
      (cond
        [(!= result 0) result]
        [(< left-length right-length) -1]
        [(> left-length right-length) 1]
        [else 0]))))

;; Stable merge sort of values[start, end) using scratch of the same length.
;; Mode 0 orders the values themselves; modes 1 and 2 treat them as indices of
;; root and node records (compiler-graph-index-compare).
(define (compiler-graph-sort-range!
  [values : (&mut values (__tl_dyn-array i64))]
  [scratch : (&mut scratch (__tl_dyn-array i64))]
  [start : i64]
  [end : i64]
  [roots : (& roots (__tl_dyn-array CompilerIncrementalGraphRootRecord))]
  [nodes : (& nodes (__tl_dyn-array CompilerIncrementalGraphNodeRecord))]
  [mode : i64]) : unit
  (let
    [width : i64 1]
    [count : i64 (- end start)]
    (while (< width count)
      (let
        [left : i64 start]
        (begin
          (while (< left end)
            (let
              [middle : i64
                (if (< (+ left width) end)
                  (+ left width)
                  end)]
              [right-end : i64
                (if (< (+ middle width) end)
                  (+ middle width)
                  end)]
              [i : i64 left]
              [j : i64 middle]
              [k : i64 left]
              (begin
                (while (< k right-end)
                  (if (and
                    (< i middle)
                    (or
                      (>= j right-end)
                      (<=
                        (compiler-graph-index-compare
                          roots
                          nodes
                          mode
                          (array-ref values i)
                          (array-ref values j)
                          false)
                        0)))
                    (begin
                      (set! (array-ref scratch k) (array-ref values i))
                      (set! i (+ i 1))
                      (set! k (+ k 1)))
                    (begin
                      (set! (array-ref scratch k) (array-ref values j))
                      (set! j (+ j 1))
                      (set! k (+ k 1)))))
                (set! k left)
                (while (< k right-end)
                  (begin
                    (set! (array-ref values k) (array-ref scratch k))
                    (set! k (+ k 1))))
                (set! left right-end))))
          (set! width (* width 2)))))))

;; A binary min-heap of node indices in heap[0, size).
(define (compiler-graph-heap-push!
  [heap : (&mut heap (__tl_dyn-array i64))]
  [size : i64]
  [value : i64]) : i64
  (let
    [child : i64 size]
    [done? : bool false]
    (begin
      (set! (array-ref heap child) value)
      (while (and (not done?) (> child 0))
        (let
          [parent : i64 (/ (- child 1) 2)]
          (if (< (array-ref heap child) (array-ref heap parent))
            (let
              [swap : i64 (array-ref heap parent)]
              (begin
                (set! (array-ref heap parent) (array-ref heap child))
                (set! (array-ref heap child) swap)
                (set! child parent)))
            (set! done? true))))
      (+ size 1))))

;; Remove and return the smallest of heap[0, size); the heap then holds size-1.
(define (compiler-graph-heap-pop!
  [heap : (&mut heap (__tl_dyn-array i64))]
  [size : i64]) : i64
  (let
    [top : i64 (array-ref heap 0)]
    [last : i64 (- size 1)]
    [parent : i64 0]
    [done? : bool false]
    (begin
      (set! (array-ref heap 0) (array-ref heap last))
      (while (not done?)
        (let
          [left : i64 (+ (* parent 2) 1)]
          [right : i64 (+ (* parent 2) 2)]
          [smallest : i64 parent]
          (begin
            (when
              (and
                (< left last)
                (< (array-ref heap left) (array-ref heap smallest)))
              (set! smallest left))
            (when
              (and
                (< right last)
                (< (array-ref heap right) (array-ref heap smallest)))
              (set! smallest right))
            (if (= smallest parent)
              (set! done? true)
              (let
                [swap : i64 (array-ref heap parent)]
                (begin
                  (set! (array-ref heap parent) (array-ref heap smallest))
                  (set! (array-ref heap smallest) swap)
                  (set! parent smallest)))))))
      top)))

(define (compiler-graph-link
  [roots : (__tl_dyn-array CompilerIncrementalGraphRoot)]
  [nodes : (__tl_dyn-array CompilerIncrementalGraphNode)]
  [edges : (& edges graph_edge_vec.Vec)]
  [transcript : (__tl_dyn-array u8)]
  [limits : (& limits CompilerIncrementalGraphLimits)]) : ResultCompilerIncrementalGraph
  (let
    [node-count : i64 (array-length nodes)]
    [root-count : i64 (array-length roots)]
    [edge-count : i64 (graph_edge_vec.len edges)]
    [targets : (__tl_dyn-array i64) (__tl_make-array i64 edge-count)]
    [scratch : (__tl_dyn-array i64) (__tl_make-array i64 edge-count)]
    [no-roots : (__tl_dyn-array CompilerIncrementalGraphRootRecord)
      (__tl_make-array CompilerIncrementalGraphRootRecord 0)]
    [no-nodes : (__tl_dyn-array CompilerIncrementalGraphNodeRecord)
      (__tl_make-array CompilerIncrementalGraphNodeRecord 0)]
    [dependency-start : (__tl_dyn-array i64)
      (__tl_make-array i64 (+ node-count 1))]
    [dependencies : (__tl_dyn-array i64) (__tl_make-array i64 edge-count)]
    [dependency-count : i64 0]
    [root-nodes : (__tl_dyn-array i64) (__tl_make-array i64 root-count)]
    [outputs : (__tl_dyn-array String) (__tl_make-array String node-count)]
    [index : i64 0]
    (begin
      (while (< index node-count)
        (let
          [node : CompilerIncrementalGraphNode
            (owned_view.compiler-owned-array-element-shared-view nodes index)]
          (begin
            (set!
              (array-ref outputs index)
              (compiler-graph-encode-output (& node.output)))
            (set! index (+ index 1)))))
      (set! index 0)
      ;; Resolve each child-result edge to the node with exactly that query, and
      ;; require the output that node publishes to be the one observed. A node
      ;; cannot name itself: its trace is a trace of its own query, and a trace
      ;; never names its parent.
      (while (< index edge-count)
        (let
          [edge : CompilerIncrementalGraphEdgeRecord
            (owned_view.compiler-owned-array-element-shared-view
              edges.slots
              index)]
          [target : i64
            (compiler-graph-find-node-index (& nodes) (& edge.child))]
          (begin
            (when
              (< target 0)
              (return
                (ResultCompilerIncrementalGraph.Err
                  (compiler-graph-error
                    compiler-graph-error-absent-child
                    -1
                    edge.node
                    "a child-result edge names no node in the graph"))))
            (let
              [published : String
                (owned_view.compiler-owned-array-element-shared-view
                  outputs
                  target)]
              (when
                (not
                  (identity.compiler-incremental-string-eq?
                    (& published)
                    (& edge.observation)))
                (return
                  (ResultCompilerIncrementalGraph.Err
                    (compiler-graph-error
                      compiler-graph-error-child-output
                      -1
                      edge.node
                      "a child-result edge observed a different semantic output")))))
            (set! (array-ref targets index) target)
            (set! index (+ index 1)))))
      ;; Edges arrive grouped by node in node order; sort and dedupe each row.
      (let
        [edge : i64 0]
        [node : i64 0]
        (while (< node node-count)
          (let
            [row-start : i64 edge]
            (begin
              (while (and
                (< edge edge-count)
                (=
                  (__tl-project-field
                    (owned_view.compiler-owned-array-element-shared-view
                      edges.slots
                      edge)
                    node)
                  node))
                (set! edge (+ edge 1)))
              (compiler-graph-sort-range!
                (&mut targets)
                (&mut scratch)
                row-start
                edge
                (& no-roots)
                (& no-nodes)
                0)
              (set! (array-ref dependency-start node) dependency-count)
              (let
                [k : i64 row-start]
                (while (< k edge)
                  (begin
                    (when
                      (or
                        (= k row-start)
                        (!= (array-ref targets k) (array-ref targets (- k 1))))
                      (set!
                        (array-ref dependencies dependency-count)
                        (array-ref targets k))
                      (set! dependency-count (+ dependency-count 1)))
                    (set! k (+ k 1)))))
              (set! node (+ node 1))))))
      (set! (array-ref dependency-start node-count) dependency-count)
      ;; Every root names a node.
      (set! index 0)
      (while (< index root-count)
        (let
          [root : CompilerIncrementalGraphRoot
            (owned_view.compiler-owned-array-element-shared-view roots index)]
          [key : String (compiler-graph-bytes-string (& root.query.transcript))]
          [target : i64 (compiler-graph-find-node-index (& nodes) (& key))]
          (begin
            (when
              (< target 0)
              (return
                (ResultCompilerIncrementalGraph.Err
                  (compiler-graph-error
                    compiler-graph-error-absent-root
                    index
                    -1
                    "a root names no node in the graph"))))
            (set! (array-ref root-nodes index) target)
            (set! index (+ index 1)))))
      (compiler-graph-order
        roots
        root-nodes
        nodes
        dependency-start
        (compiler-graph-range-prefix (& dependencies) dependency-count)
        transcript))))

(define (compiler-graph-range-prefix
  [values : (& values (__tl_dyn-array i64))]
  [count : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref out index) (array-ref values index))
          (set! index (+ index 1))))
      out)))

;; Build the dependent rows, then order the nodes dependencies-first and check
;; that the graph is acyclic and that every node is reachable from a root.
(define (compiler-graph-order
  [roots : (__tl_dyn-array CompilerIncrementalGraphRoot)]
  [root-nodes : (__tl_dyn-array i64)]
  [nodes : (__tl_dyn-array CompilerIncrementalGraphNode)]
  [dependency-start : (__tl_dyn-array i64)]
  [dependencies : (__tl_dyn-array i64)]
  [transcript : (__tl_dyn-array u8)]) : ResultCompilerIncrementalGraph
  (let
    [node-count : i64 (array-length nodes)]
    [edge-count : i64 (array-length dependencies)]
    [dependent-start : (__tl_dyn-array i64)
      (__tl_make-array i64 (+ node-count 1))]
    [dependents : (__tl_dyn-array i64) (__tl_make-array i64 edge-count)]
    [fill : (__tl_dyn-array i64) (__tl_make-array i64 node-count)]
    [remaining : (__tl_dyn-array i64) (__tl_make-array i64 node-count)]
    [heap : (__tl_dyn-array i64) (__tl_make-array i64 node-count)]
    [heap-size : i64 0]
    [topological : (__tl_dyn-array i64) (__tl_make-array i64 node-count)]
    [emitted : i64 0]
    [node : i64 0]
    [k : i64 0]
    (begin
      ;; Dependents: count, prefix-sum, then fill in ascending node order so
      ;; each row comes out ascending.
      (while (< k edge-count)
        (begin
          (set!
            (array-ref dependent-start (+ (array-ref dependencies k) 1))
            (+ (array-ref dependent-start (+ (array-ref dependencies k) 1)) 1))
          (set! k (+ k 1))))
      (set! node 0)
      (while (< node node-count)
        (begin
          (set!
            (array-ref dependent-start (+ node 1))
            (+
              (array-ref dependent-start (+ node 1))
              (array-ref dependent-start node)))
          (set! (array-ref fill node) (array-ref dependent-start node))
          (set! node (+ node 1))))
      (set! node 0)
      (while (< node node-count)
        (begin
          (set! k (array-ref dependency-start node))
          (while (< k (array-ref dependency-start (+ node 1)))
            (let
              [target : i64 (array-ref dependencies k)]
              (begin
                (set! (array-ref dependents (array-ref fill target)) node)
                (set! (array-ref fill target) (+ (array-ref fill target) 1))
                (set! k (+ k 1)))))
          (set!
            (array-ref remaining node)
            (-
              (array-ref dependency-start (+ node 1))
              (array-ref dependency-start node)))
          (when
            (= (array-ref remaining node) 0)
            (set!
              heap-size
              (compiler-graph-heap-push! (&mut heap) heap-size node)))
          (set! node (+ node 1))))
      ;; Kahn's algorithm; the heap releases the smallest ready index first.
      (while (> heap-size 0)
        (let
          [ready : i64 (compiler-graph-heap-pop! (&mut heap) heap-size)]
          (begin
            (set! heap-size (- heap-size 1))
            (set! (array-ref topological emitted) ready)
            (set! emitted (+ emitted 1))
            (set! k (array-ref dependent-start ready))
            (while (< k (array-ref dependent-start (+ ready 1)))
              (let
                [dependent : i64 (array-ref dependents k)]
                (begin
                  (set!
                    (array-ref remaining dependent)
                    (- (array-ref remaining dependent) 1))
                  (when
                    (= (array-ref remaining dependent) 0)
                    (set!
                      heap-size
                      (compiler-graph-heap-push!
                        (&mut heap)
                        heap-size
                        dependent)))
                  (set! k (+ k 1))))))))
      (when
        (< emitted node-count)
        (set! node 0)
        (while (= (array-ref remaining node) 0)
          (set! node (+ node 1)))
        (return
          (ResultCompilerIncrementalGraph.Err
            (compiler-graph-error
              compiler-graph-error-cycle
              -1
              node
              "the graph's dependencies form a cycle"))))
      ;; Reachability from the roots over dependencies, with an explicit stack.
      (let
        [visited : (__tl_dyn-array bool) (__tl_make-array bool node-count)]
        [stack : (__tl_dyn-array i64) (__tl_make-array i64 node-count)]
        [top : i64 0]
        (begin
          (set! k 0)
          (while (< k (array-length root-nodes))
            (let
              [start : i64 (array-ref root-nodes k)]
              (begin
                (unless
                  (array-ref visited start)
                  (set! (array-ref visited start) true)
                  (set! (array-ref stack top) start)
                  (set! top (+ top 1)))
                (set! k (+ k 1)))))
          (while (> top 0)
            (let
              [current : i64 (array-ref stack (- top 1))]
              [edge : i64 0]
              (begin
                (set! top (- top 1))
                (set! edge (array-ref dependency-start current))
                (while (< edge (array-ref dependency-start (+ current 1)))
                  (let
                    [target : i64 (array-ref dependencies edge)]
                    (begin
                      (unless
                        (array-ref visited target)
                        (set! (array-ref visited target) true)
                        (set! (array-ref stack top) target)
                        (set! top (+ top 1)))
                      (set! edge (+ edge 1))))))))
          (set! node 0)
          (while (< node node-count)
            (begin
              (unless
                (array-ref visited node)
                (return
                  (ResultCompilerIncrementalGraph.Err
                    (compiler-graph-error
                      compiler-graph-error-unreachable
                      -1
                      node
                      "a node is not reachable from any root"))))
              (set! node (+ node 1))))))
      (match (identity.compiler-incremental-digest-array (& transcript))
        [(sha256.Sha256FinalizeErr _)
          (ResultCompilerIncrementalGraph.Err
            (compiler-graph-error
              compiler-graph-error-framing
              -1
              -1
              "graph fingerprint failed"))]
        [(sha256.Sha256FinalizeOk digest)
          (ResultCompilerIncrementalGraph.Ok
            (CompilerIncrementalGraph
              compiler-incremental-graph-schema
              roots
              root-nodes
              nodes
              dependency-start
              dependencies
              dependent-start
              dependents
              topological
              transcript
              digest))]))))

;; --- published graph access -----------------------------------------------------
(define (compiler-graph-node-count [graph : (& graph CompilerIncrementalGraph)]) : i64
  (array-length graph.nodes))

(define (compiler-graph-root-count [graph : (& graph CompilerIncrementalGraph)]) : i64
  (array-length graph.roots))

;; The node at canonical position `index`.
(define (compiler-graph-node
  [graph : (& graph CompilerIncrementalGraph)]
  [index : i64]) : CompilerIncrementalGraphNode
  (owned_view.compiler-owned-array-element-shared-view graph.nodes index))

(define (compiler-graph-root
  [graph : (& graph CompilerIncrementalGraph)]
  [index : i64]) : CompilerIncrementalGraphRoot
  (owned_view.compiler-owned-array-element-shared-view graph.roots index))

;; The node a root names.
(define (compiler-graph-root-node
  [graph : (& graph CompilerIncrementalGraph)]
  [index : i64]) : i64
  (array-ref graph.root-nodes index))

;; The canonical position of the node for exactly `query`, or -1.
(define (compiler-graph-find-node
  [graph : (& graph CompilerIncrementalGraph)]
  [query : (& query identity.CompilerIncrementalIdentity)]) : i64
  (let
    [key : String (compiler-graph-bytes-string (& query.transcript))]
    (compiler-graph-find-node-index (& graph.nodes) (& key))))

;; The node a root name names, or -1.
(define (compiler-graph-find-root
  [graph : (& graph CompilerIncrementalGraph)]
  [name : (& name CompilerIncrementalGraphRootName)]) : i64
  (let
    [wanted : String (compiler-graph-encode-root-name name)]
    [low : i64 0]
    [high : i64 (array-length graph.roots)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< low high))
        (let
          [middle : i64 (+ low (/ (- high low) 2))]
          [root : CompilerIncrementalGraphRoot
            (owned_view.compiler-owned-array-element-shared-view
              graph.roots
              middle)]
          [key : String (compiler-graph-encode-root-name (& root.name))]
          [order : i64 (compiler-graph-string-compare (& key) (& wanted))]
          (cond
            [(= order 0) (set! found (array-ref graph.root-nodes middle))]
            [(< order 0) (set! low (+ middle 1))]
            [else (set! high middle)])))
      found)))

(define (compiler-graph-row
  [start : (& start (__tl_dyn-array i64))]
  [values : (& values (__tl_dyn-array i64))]
  [index : i64]) : (__tl_dyn-array i64)
  (let
    [from : i64 (array-ref start index)]
    [count : i64 (- (array-ref start (+ index 1)) from)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [k : i64 0]
    (begin
      (while (< k count)
        (begin
          (set! (array-ref out k) (array-ref values (+ from k)))
          (set! k (+ k 1))))
      out)))

;; The distinct nodes `index` depends on, ascending.
(define (compiler-graph-dependencies
  [graph : (& graph CompilerIncrementalGraph)]
  [index : i64]) : (__tl_dyn-array i64)
  (compiler-graph-row (& graph.dependency-start) (& graph.dependencies) index))

;; The distinct nodes that depend on `index`, ascending.
(define (compiler-graph-dependents
  [graph : (& graph CompilerIncrementalGraph)]
  [index : i64]) : (__tl_dyn-array i64)
  (compiler-graph-row (& graph.dependent-start) (& graph.dependents) index))

;; Every node after all of its dependencies; ties go to the smaller index.
(define (compiler-graph-topological-order
  [graph : (& graph CompilerIncrementalGraph)]) : (__tl_dyn-array i64)
  (compiler-graph-range-prefix
    (& graph.topological)
    (array-length graph.topological)))

;; The canonical bytes a graph is stored as.
(define (compiler-graph-encode [graph : (& graph CompilerIncrementalGraph)]) : (__tl_dyn-array
    u8)
  (binary.compiler-incremental-binary-copy (& graph.transcript)))

(define (compiler-graph-fingerprint
  [graph : (& graph CompilerIncrementalGraph)]) : sha256.Sha256Digest
  (sha256.Sha256Digest (sha256.digest-bytes (& graph.fingerprint))))

;; Exact equality of the full 32-byte canonical fingerprints.
(define (compiler-graph-fingerprint-eq?
  [left : (& left CompilerIncrementalGraph)]
  [right : (& right CompilerIncrementalGraph)]) : bool
  (sha256.digest-eq? (& left.fingerprint) (& right.fingerprint)))