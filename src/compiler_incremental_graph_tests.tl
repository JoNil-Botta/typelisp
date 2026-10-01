;; Synthetic successful-query graphs and hostile graph transcripts (#7322).
(import compiler_incremental_binary as binary)
(import compiler_incremental_graph as graph)
(import compiler_incremental_identity as identity)
(import compiler_incremental_trace as trace)
(import stdlib.byte_buf_core)
(import stdlib.byte_le)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.string)

;; --- synthetic values ----------------------------------------------------------
(define (graph-test-digest [seed : i64]) : sha256.Sha256Digest
  (let
    [octets : (Array u8 32) (make-array u8 32)]
    (begin
      (set! (array-ref octets 0) (cast seed : u8))
      (set! (array-ref octets 31) (cast (+ seed 7) : u8))
      (sha256.Sha256Digest octets))))

(define (graph-test-child [domain : String] [length : i64]) : identity.CompilerIncrementalChildIdentity
  (identity.CompilerIncrementalChildIdentity
    domain
    1
    length
    (graph-test-digest length)))

;; A distinct query for each (kind, build length) pair.
(define (graph-test-query [kind : i64] [length : i64]) : identity.CompilerIncrementalIdentity
  (let
    [query : identity.CompilerIncrementalQuery
      (identity.CompilerIncrementalQuery
        (cond
          [(= kind 0) (identity.CompilerIncrementalQueryKind.Parse)]
          [(= kind 1) (identity.CompilerIncrementalQueryKind.IrDump "macro")]
          [(= kind 2) (identity.CompilerIncrementalQueryKind.Typecheck)]
          [else (identity.CompilerIncrementalQueryKind.Lower)])
        (identity.CompilerIncrementalBuildIdentity.Available
          (graph-test-child "typelisp.compiler-build" length))
        (__tl_make-array identity.CompilerIncrementalInput 0))]
    [limits : identity.CompilerIncrementalIdentityLimits
      (identity.compiler-incremental-identity-default-limits)]
    (match (identity.compiler-incremental-identity-encode query (& limits))
      [(identity.ResultCompilerIncrementalIdentity.Ok value) value]
      [_ (string.tl_oob_abort)])))

(define (graph-test-output [seed : i64]) : identity.CompilerIncrementalSemanticOutputIdentity
  (identity.CompilerIncrementalSemanticOutputIdentity
    (graph-test-child "typelisp.semantic-output" seed)))

(define (graph-test-key [seed : i64]) : graph.CompilerIncrementalStoredResultKey
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 3)]
    (begin
      (set! (array-ref bytes 0) (cast seed : u8))
      (set! (array-ref bytes 1) 42)
      (set! (array-ref bytes 2) (cast (* seed 3) : u8))
      (graph.CompilerIncrementalStoredResultKey
        "typelisp.compiler.incremental.stored-result"
        1
        bytes))))

(define (graph-test-source [path : String]) : trace.CompilerIncrementalTraceEdge
  (trace.CompilerIncrementalTraceEdge
    (trace.CompilerIncrementalTraceKey.Source path)
    (trace.CompilerIncrementalTraceObservation.Source
      (trace.CompilerIncrementalTraceContent.Present
        (identity.CompilerIncrementalContentIdentity
          "typelisp.source-content"
          1
          12
          (graph-test-digest 12))))))

(define (graph-test-macro-edge) : trace.CompilerIncrementalTraceEdge
  (trace.CompilerIncrementalTraceEdge
    (trace.CompilerIncrementalTraceKey.MacroComptime
      "expand"
      (graph-test-child "typelisp.macro-request" 5))
    (trace.CompilerIncrementalTraceObservation.MacroComptime
      (trace.CompilerIncrementalTraceSemantic.Present (graph-test-output 77)))))

(define (graph-test-child-edge
  [ordinal : i64]
  [child : identity.CompilerIncrementalIdentity]
  [output : identity.CompilerIncrementalSemanticOutputIdentity]) : trace.CompilerIncrementalTraceEdge
  (trace.CompilerIncrementalTraceEdge
    (trace.CompilerIncrementalTraceKey.Child "deps" ordinal child)
    (trace.CompilerIncrementalTraceObservation.Child output)))

(define (graph-test-trace-finish
  [builder : trace.CompilerIncrementalTraceBuilder]) : trace.CompilerIncrementalTrace
  (match (trace.compiler-trace-finalize builder)
    [(trace.ResultCompilerIncrementalTrace.Ok value) value]
    [_ (string.tl_oob_abort)]))

(define (graph-test-trace-begin [query : identity.CompilerIncrementalIdentity]) : trace.CompilerIncrementalTraceBuilder
  (match (trace.compiler-trace-begin
    query
    (trace.compiler-trace-default-limits))
    [(trace.ResultCompilerIncrementalTraceBuilder.Ok builder) builder]
    [_ (string.tl_oob_abort)]))

;; Fixture notes and additions; a rejected note is a broken fixture.
(define (graph-test-note!
  [builder : (&mut builder trace.CompilerIncrementalTraceBuilder)]
  [edge : trace.CompilerIncrementalTraceEdge]) : unit
  (unless (trace.compiler-trace-note! builder edge) (string.tl_oob_abort)))

(define (graph-test-add-node!
  [builder : (&mut builder graph.CompilerIncrementalGraphBuilder)]
  [node : graph.CompilerIncrementalGraphNode]) : unit
  (begin
    (graph.compiler-graph-add-node! builder node)
    unit))

(define (graph-test-add-root!
  [builder : (&mut builder graph.CompilerIncrementalGraphBuilder)]
  [root : graph.CompilerIncrementalGraphRoot]) : unit
  (begin
    (graph.compiler-graph-add-root! builder root)
    unit))

;; A trace observing one source file and the given child results.
(define (graph-test-trace
  [query : identity.CompilerIncrementalIdentity]
  [source : String]
  [macro? : bool]
  [children : i64]
  [first-kind : i64]
  [first-length : i64]
  [first-output : i64]
  [second-kind : i64]
  [second-length : i64]
  [second-output : i64]) : trace.CompilerIncrementalTrace
  (let
    [builder : trace.CompilerIncrementalTraceBuilder
      (graph-test-trace-begin query)]
    (begin
      (graph-test-note! (&mut builder) (graph-test-source source))
      (when macro? (graph-test-note! (&mut builder) (graph-test-macro-edge)))
      (when
        (>= children 1)
        (graph-test-note!
          (&mut builder)
          (graph-test-child-edge
            0
            (graph-test-query first-kind first-length)
            (graph-test-output first-output))))
      (when
        (>= children 2)
        (graph-test-note!
          (&mut builder)
          (graph-test-child-edge
            1
            (graph-test-query second-kind second-length)
            (graph-test-output second-output))))
      (graph-test-trace-finish builder))))

(define (graph-test-node
  [kind : i64]
  [length : i64]
  [output : i64]
  [key : i64]
  [trace : trace.CompilerIncrementalTrace]) : graph.CompilerIncrementalGraphNode
  (graph.CompilerIncrementalGraphNode
    (graph-test-query kind length)
    (graph-test-output output)
    (graph-test-key key)
    trace))

;; The traces behind the representative nodes.
(define (graph-test-load-trace) : trace.CompilerIncrementalTrace
  (graph-test-trace (graph-test-query 0 1) "src/app.tl" false 0 0 0 0 0 0 0))

(define (graph-test-macro-trace) : trace.CompilerIncrementalTrace
  (graph-test-trace (graph-test-query 1 2) "src/app.tl" true 1 0 1 11 0 0 0))

(define (graph-test-module-trace [load-output : i64]) : trace.CompilerIncrementalTrace
  (graph-test-trace
    (graph-test-query 2 3)
    "src/app.tl"
    false
    2
    0
    1
    load-output
    1
    2
    12))

;; The representative graph: a source load, a macro expansion that reads it,
;; a module over both, and a declaration in the module.
(define (graph-test-load) : graph.CompilerIncrementalGraphNode
  (graph-test-node
    0
    1
    11
    1
    (graph-test-trace (graph-test-query 0 1) "src/app.tl" false 0 0 0 0 0 0 0)))

(define (graph-test-macro) : graph.CompilerIncrementalGraphNode
  (graph-test-node
    1
    2
    12
    2
    (graph-test-trace (graph-test-query 1 2) "src/app.tl" true 1 0 1 11 0 0 0)))

(define (graph-test-module [load-output : i64]) : graph.CompilerIncrementalGraphNode
  (graph-test-node
    2
    3
    13
    3
    (graph-test-trace
      (graph-test-query 2 3)
      "src/app.tl"
      false
      2
      0
      1
      load-output
      1
      2
      12)))

(define (graph-test-decl [module-output : i64]) : graph.CompilerIncrementalGraphNode
  (graph-test-node
    3
    4
    14
    4
    (graph-test-trace
      (graph-test-query 3 4)
      "src/app.tl"
      false
      1
      2
      3
      module-output
      0
      0
      0)))

(define (graph-test-root
  [purpose : String]
  [name : String]
  [kind : i64]
  [length : i64]) : graph.CompilerIncrementalGraphRoot
  (graph.CompilerIncrementalGraphRoot
    (graph.CompilerIncrementalGraphRootName purpose name)
    (graph-test-query kind length)))

(define (graph-test-begin) : graph.CompilerIncrementalGraphBuilder
  (match (graph.compiler-graph-begin (graph.compiler-graph-default-limits))
    [(graph.ResultCompilerIncrementalGraphBuilder.Ok builder) builder]
    [_ (string.tl_oob_abort)]))

(define (graph-test-unwrap [result : graph.ResultCompilerIncrementalGraph]) : graph.CompilerIncrementalGraph
  (match result
    [(graph.ResultCompilerIncrementalGraph.Ok value) value]
    [_ (string.tl_oob_abort)]))

(define (graph-test-error-code [result : graph.ResultCompilerIncrementalGraph]) : i64
  (match result
    [(graph.ResultCompilerIncrementalGraph.Ok _) 0]
    [(graph.ResultCompilerIncrementalGraph.Err error) error.code]))

(define (graph-test-error [result : graph.ResultCompilerIncrementalGraph]) : graph.CompilerIncrementalGraphError
  (match result
    [(graph.ResultCompilerIncrementalGraph.Ok _)
      (graph.compiler-graph-error 0 -2 -2 "")]
    [(graph.ResultCompilerIncrementalGraph.Err error) error]))

;; The representative graph, observed in one of two orders, optionally with
;; byte-identical repeats.
(define (graph-test-representative [reverse? : bool] [repeat? : bool]) : graph.ResultCompilerIncrementalGraph
  (let
    [builder : graph.CompilerIncrementalGraphBuilder (graph-test-begin)]
    (begin
      (if reverse?
        (begin
          (graph-test-add-node! (&mut builder) (graph-test-decl 13))
          (graph-test-add-root!
            (&mut builder)
            (graph-test-root "typelisp.root.check" "lib" 2 3))
          (graph-test-add-node! (&mut builder) (graph-test-module 11))
          (graph-test-add-node! (&mut builder) (graph-test-macro))
          (graph-test-add-root!
            (&mut builder)
            (graph-test-root "typelisp.root.build" "app" 3 4))
          (graph-test-add-node! (&mut builder) (graph-test-load)))
        (begin
          (graph-test-add-root!
            (&mut builder)
            (graph-test-root "typelisp.root.build" "app" 3 4))
          (graph-test-add-root!
            (&mut builder)
            (graph-test-root "typelisp.root.check" "lib" 2 3))
          (graph-test-add-node! (&mut builder) (graph-test-load))
          (graph-test-add-node! (&mut builder) (graph-test-macro))
          (graph-test-add-node! (&mut builder) (graph-test-module 11))
          (graph-test-add-node! (&mut builder) (graph-test-decl 13))))
      (when
        repeat?
        (graph-test-add-node! (&mut builder) (graph-test-module 11))
        (graph-test-add-root!
          (&mut builder)
          (graph-test-root "typelisp.root.build" "app" 3 4)))
      (graph.compiler-graph-finalize builder))))

(define (graph-test-array-eq?
  [left : (& left (__tl_dyn-array i64))]
  [right : (& right (__tl_dyn-array i64))]) : bool
  (let
    [equal? : bool (= (array-length left) (array-length right))]
    [index : i64 0]
    (begin
      (while (and equal? (< index (array-length left)))
        (begin
          (unless
            (= (array-ref left index) (array-ref right index))
            (set! equal? false))
          (set! index (+ index 1))))
      equal?)))

(define (graph-test-indices
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [count : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    (begin
      (when (> count 0) (set! (array-ref out 0) a))
      (when (> count 1) (set! (array-ref out 1) b))
      (when (> count 2) (set! (array-ref out 2) c))
      (when (> count 3) (set! (array-ref out 3) d))
      out)))

(define (graph-test-index
  [value : (& value graph.CompilerIncrementalGraph)]
  [kind : i64]
  [length : i64]) : i64
  (let
    [query : identity.CompilerIncrementalIdentity
      (graph-test-query kind length)]
    (graph.compiler-graph-find-node value (& query))))

(define (graph-test-output-string [seed : i64]) : String
  (let
    [output : identity.CompilerIncrementalSemanticOutputIdentity
      (graph-test-output seed)]
    (graph.compiler-graph-encode-output (& output))))

;; --- round trip and canonical form ------------------------------------------------
;; Every decoded node keeps its query, semantic output, stored-result key and
;; trace, and every root its name and query.
(define (graph-test-round-trip?) : bool
  (let
    [limits : graph.CompilerIncrementalGraphLimits
      (graph.compiler-graph-default-limits)]
    [built : graph.CompilerIncrementalGraph
      (graph-test-unwrap (graph-test-representative false false))]
    [bytes : (__tl_dyn-array u8) (graph.compiler-graph-encode (& built))]
    [decoded : graph.CompilerIncrementalGraph
      (graph-test-unwrap (graph.compiler-graph-decode (& bytes) (& limits)))]
    [again : (__tl_dyn-array u8) (graph.compiler-graph-encode (& decoded))]
    [module : i64 (graph-test-index (& decoded) 2 3)]
    [node : graph.CompilerIncrementalGraphNode
      (graph.compiler-graph-node (& decoded) module)]
    [expected-trace : trace.CompilerIncrementalTrace
      (graph-test-module-trace 11)]
    [expected-key : graph.CompilerIncrementalStoredResultKey (graph-test-key 3)]
    [published : String (graph.compiler-graph-encode-output (& node.output))]
    [expected-output : String (graph-test-output-string 13)]
    [app : graph.CompilerIncrementalGraphRootName
      (graph.CompilerIncrementalGraphRootName "typelisp.root.build" "app")]
    [lib : graph.CompilerIncrementalGraphRootName
      (graph.CompilerIncrementalGraphRootName "typelisp.root.check" "lib")]
    [first-root : graph.CompilerIncrementalGraphRoot
      (graph.compiler-graph-root (& decoded) 0)]
    [second-root : graph.CompilerIncrementalGraphRoot
      (graph.compiler-graph-root (& decoded) 1)]
    [built-fingerprint : sha256.Sha256Digest
      (graph.compiler-graph-fingerprint (& built))]
    [decoded-fingerprint : sha256.Sha256Digest
      (graph.compiler-graph-fingerprint (& decoded))]
    (and
      (= (graph.compiler-graph-node-count (& decoded)) 4)
      (= (graph.compiler-graph-root-count (& decoded)) 2)
      (graph.compiler-graph-fingerprint-eq? (& built) (& decoded))
      (binary.compiler-incremental-binary-bytes-eq? (& bytes) (& again))
      (>= module 0)
      (identity.compiler-incremental-string-eq?
        (& published)
        (& expected-output))
      (binary.compiler-incremental-binary-bytes-eq?
        (& node.stored-key.bytes)
        (& expected-key.bytes))
      (binary.compiler-incremental-binary-bytes-eq?
        (& node.trace.transcript)
        (& expected-trace.transcript))
      (binary.compiler-incremental-binary-bytes-eq?
        (& node.trace.parent.transcript)
        (& node.query.transcript))
      (=
        (graph.compiler-graph-find-root (& decoded) (& app))
        (graph-test-index (& decoded) 3 4))
      (= (graph.compiler-graph-find-root (& decoded) (& lib)) module)
      ;; Roots are in canonical name order and name their nodes.
      (identity.compiler-incremental-string-eq?
        (& first-root.name.purpose)
        "typelisp.root.build")
      (=
        (graph.compiler-graph-root-node (& decoded) 0)
        (graph-test-index (& decoded) 3 4))
      (identity.compiler-incremental-string-eq? (& second-root.name.name) "lib")
      (= (graph.compiler-graph-root-node (& decoded) 1) module)
      (sha256.digest-eq? (& built-fingerprint) (& decoded-fingerprint)))))

;; Reversed observation order and byte-identical repeats give the same bytes,
;; fingerprint and traversal.
(define (graph-test-canonical?) : bool
  (let
    [forward : graph.CompilerIncrementalGraph
      (graph-test-unwrap (graph-test-representative false false))]
    [reverse : graph.CompilerIncrementalGraph
      (graph-test-unwrap (graph-test-representative true true))]
    [forward-bytes : (__tl_dyn-array u8)
      (graph.compiler-graph-encode (& forward))]
    [reverse-bytes : (__tl_dyn-array u8)
      (graph.compiler-graph-encode (& reverse))]
    [forward-order : (__tl_dyn-array i64)
      (graph.compiler-graph-topological-order (& forward))]
    [reverse-order : (__tl_dyn-array i64)
      (graph.compiler-graph-topological-order (& reverse))]
    (and
      (binary.compiler-incremental-binary-bytes-eq?
        (& forward-bytes)
        (& reverse-bytes))
      (graph.compiler-graph-fingerprint-eq? (& forward) (& reverse))
      (graph-test-array-eq? (& forward-order) (& reverse-order)))))

;; A graph with the module and declaration nodes supplied by the caller.
(define (graph-test-with
  [module : graph.CompilerIncrementalGraphNode]
  [decl : graph.CompilerIncrementalGraphNode]) : graph.ResultCompilerIncrementalGraph
  (let
    [builder : graph.CompilerIncrementalGraphBuilder (graph-test-begin)]
    (begin
      (graph-test-add-root!
        (&mut builder)
        (graph-test-root "typelisp.root.build" "app" 3 4))
      (graph-test-add-node! (&mut builder) (graph-test-load))
      (graph-test-add-node! (&mut builder) (graph-test-macro))
      (graph-test-add-node! (&mut builder) module)
      (graph-test-add-node! (&mut builder) decl)
      (graph.compiler-graph-finalize builder))))

;; A parent's edge compares semantic outputs, never stored-result keys.
(define (graph-test-output-key-separation?) : bool
  (let
    [base : graph.CompilerIncrementalGraph
      (graph-test-unwrap
        (graph-test-with (graph-test-module 11) (graph-test-decl 13)))]
    ;; New payload key, same semantic output: the declaration still matches.
    [rekeyed : graph.ResultCompilerIncrementalGraph
      (graph-test-with
        (graph-test-node 2 3 13 9 (graph-test-module-trace 11))
        (graph-test-decl 13))]
    ;; Same key, new semantic output: the declaration's edge no longer matches.
    [changed : graph.CompilerIncrementalGraphError
      (graph-test-error
        (graph-test-with
          (graph-test-node 2 3 99 3 (graph-test-module-trace 11))
          (graph-test-decl 13)))]
    [decl : i64 (graph-test-index (& base) 3 4)]
    (and
      (match rekeyed
        [(graph.ResultCompilerIncrementalGraph.Ok value)
          (not (graph.compiler-graph-fingerprint-eq? (& value) (& base)))]
        [(graph.ResultCompilerIncrementalGraph.Err _) false])
      (= changed.code graph.compiler-graph-error-child-output)
      (= changed.node decl))))

;; --- lookup and traversal -------------------------------------------------------
(define (graph-test-traversal?) : bool
  (let
    [value : graph.CompilerIncrementalGraph
      (graph-test-unwrap (graph-test-representative false false))]
    [load : i64 (graph-test-index (& value) 0 1)]
    [macro : i64 (graph-test-index (& value) 1 2)]
    [module : i64 (graph-test-index (& value) 2 3)]
    [decl : i64 (graph-test-index (& value) 3 4)]
    [absent : i64 (graph-test-index (& value) 0 99)]
    [unknown-root : graph.CompilerIncrementalGraphRootName
      (graph.CompilerIncrementalGraphRootName "typelisp.root.build" "other")]
    [order : (__tl_dyn-array i64)
      (graph.compiler-graph-topological-order (& value))]
    [expected-order : (__tl_dyn-array i64)
      (graph-test-indices load macro module decl 4)]
    [module-deps : (__tl_dyn-array i64)
      (graph.compiler-graph-dependencies (& value) module)]
    [expected-deps : (__tl_dyn-array i64)
      (if (< load macro)
        (graph-test-indices load macro 0 0 2)
        (graph-test-indices macro load 0 0 2))]
    [load-dependents : (__tl_dyn-array i64)
      (graph.compiler-graph-dependents (& value) load)]
    [expected-dependents : (__tl_dyn-array i64)
      (if (< macro module)
        (graph-test-indices macro module 0 0 2)
        (graph-test-indices module macro 0 0 2))]
    [load-deps : (__tl_dyn-array i64)
      (graph.compiler-graph-dependencies (& value) load)]
    (and
      (>= load 0)
      (>= macro 0)
      (>= module 0)
      (>= decl 0)
      (= absent -1)
      (= (graph.compiler-graph-find-root (& value) (& unknown-root)) -1)
      (graph-test-array-eq? (& order) (& expected-order))
      (graph-test-array-eq? (& module-deps) (& expected-deps))
      (graph-test-array-eq? (& load-dependents) (& expected-dependents))
      (= (array-length load-deps) 0))))

;; Nodes that become ready together leave in canonical (structural) order.
(define (graph-test-tie-break?) : bool
  (let
    [builder : graph.CompilerIncrementalGraphBuilder (graph-test-begin)]
    [left : graph.CompilerIncrementalGraphNode
      (graph-test-node
        0
        41
        41
        41
        (graph-test-trace
          (graph-test-query 0 41)
          "src/a.tl"
          false
          0
          0
          0
          0
          0
          0
          0))]
    [right : graph.CompilerIncrementalGraphNode
      (graph-test-node
        0
        42
        42
        42
        (graph-test-trace
          (graph-test-query 0 42)
          "src/b.tl"
          false
          0
          0
          0
          0
          0
          0
          0))]
    [top : graph.CompilerIncrementalGraphNode
      (graph-test-node
        2
        43
        43
        43
        (graph-test-trace
          (graph-test-query 2 43)
          "src/c.tl"
          false
          2
          0
          42
          42
          0
          41
          41))]
    (begin
      (graph-test-add-root!
        (&mut builder)
        (graph-test-root "typelisp.root.build" "c" 2 43))
      (graph-test-add-node! (&mut builder) top)
      (graph-test-add-node! (&mut builder) right)
      (graph-test-add-node! (&mut builder) left)
      (let
        [value : graph.CompilerIncrementalGraph
          (graph-test-unwrap (graph.compiler-graph-finalize builder))]
        [a : i64 (graph-test-index (& value) 0 41)]
        [b : i64 (graph-test-index (& value) 0 42)]
        [c : i64 (graph-test-index (& value) 2 43)]
        [order : (__tl_dyn-array i64)
          (graph.compiler-graph-topological-order (& value))]
        [expected : (__tl_dyn-array i64)
          (if (< a b)
            (graph-test-indices a b c 0 3)
            (graph-test-indices b a c 0 3))]
        (graph-test-array-eq? (& order) (& expected))))))

;; Lookup admits only exact transcripts: an identity carrying another node's
;; fingerprint over a different transcript finds nothing, and a forged
;; identity is rejected before it can enter a graph.
(define (graph-test-collision-seams?) : bool
  (let
    [value : graph.CompilerIncrementalGraph
      (graph-test-unwrap (graph-test-representative false false))]
    [load : identity.CompilerIncrementalIdentity (graph-test-query 0 1)]
    [stranger : identity.CompilerIncrementalIdentity (graph-test-query 0 98)]
    [forged : identity.CompilerIncrementalIdentity
      (identity.CompilerIncrementalIdentity
        stranger.schema
        stranger.query-kind-tag
        stranger.record-count
        (binary.compiler-incremental-binary-copy (& stranger.transcript))
        load.fingerprint)]
    [builder : graph.CompilerIncrementalGraphBuilder (graph-test-begin)]
    [admitted? : bool
      (graph.compiler-graph-add-root!
        (&mut builder)
        (graph.CompilerIncrementalGraphRoot
          (graph.CompilerIncrementalGraphRootName "typelisp.root.build" "app")
          (identity.CompilerIncrementalIdentity
            stranger.schema
            stranger.query-kind-tag
            stranger.record-count
            (binary.compiler-incremental-binary-copy (& stranger.transcript))
            load.fingerprint)))]
    (and
      (= (graph.compiler-graph-find-node (& value) (& forged)) -1)
      (not admitted?)
      (=
        (graph-test-error-code (graph.compiler-graph-finalize builder))
        graph.compiler-graph-error-query))))

;; Graph bytes survive a byte-only store and come back as the same graph.
(define (graph-test-opaque-store?) : bool
  (let
    [limits : graph.CompilerIncrementalGraphLimits
      (graph.compiler-graph-default-limits)]
    [value : graph.CompilerIncrementalGraph
      (graph-test-unwrap (graph-test-representative false false))]
    [encoded : (__tl_dyn-array u8) (graph.compiler-graph-encode (& value))]
    [stored : (__tl_dyn-array u8)
      (binary.compiler-incremental-binary-copy (& encoded))]
    [loaded : graph.CompilerIncrementalGraph
      (graph-test-unwrap (graph.compiler-graph-decode (& stored) (& limits)))]
    (graph.compiler-graph-fingerprint-eq? (& value) (& loaded))))

;; --- builder rejections -------------------------------------------------------------
(define (graph-test-builder-error
  [first : graph.CompilerIncrementalGraphNode]
  [second : graph.CompilerIncrementalGraphNode]) : i64
  (let
    [builder : graph.CompilerIncrementalGraphBuilder (graph-test-begin)]
    (begin
      (graph-test-add-root!
        (&mut builder)
        (graph-test-root "typelisp.root.build" "app" 0 1))
      (graph-test-add-node! (&mut builder) first)
      (graph-test-add-node! (&mut builder) second)
      (graph-test-error-code (graph.compiler-graph-finalize builder)))))

(define (graph-test-load-with-key
  [key : graph.CompilerIncrementalStoredResultKey]) : graph.CompilerIncrementalGraphNode
  (graph.CompilerIncrementalGraphNode
    (graph-test-query 0 1)
    (graph-test-output 11)
    key
    (graph-test-load-trace)))

(define (graph-test-builder-rejections?) : bool
  (let
    [wrong-domain : graph.CompilerIncrementalStoredResultKey
      (graph.CompilerIncrementalStoredResultKey
        "typelisp.semantic-output"
        1
        (__tl_make-array u8 1))]
    [empty : graph.CompilerIncrementalStoredResultKey
      (graph.CompilerIncrementalStoredResultKey
        "typelisp.compiler.incremental.stored-result"
        1
        (__tl_make-array u8 0))]
    [zero-schema : graph.CompilerIncrementalStoredResultKey
      (graph.CompilerIncrementalStoredResultKey
        "typelisp.compiler.incremental.stored-result"
        0
        (__tl_make-array u8 1))]
    [bad-output : graph.CompilerIncrementalGraphNode
      (graph.CompilerIncrementalGraphNode
        (graph-test-query 0 1)
        (identity.CompilerIncrementalSemanticOutputIdentity
          (graph-test-child "typelisp.compiler-build" 11))
        (graph-test-key 1)
        (graph-test-load-trace))]
    [foreign-trace : graph.CompilerIncrementalGraphNode
      (graph-test-node 2 3 13 3 (graph-test-load-trace))]
    [small : graph.CompilerIncrementalGraphLimits
      (graph.compiler-graph-default-limits)]
    [_small : unit (set! small.max-nodes 1)]
    [zero-roots : graph.CompilerIncrementalGraphLimits
      (graph.compiler-graph-default-limits)]
    [_zero : unit (set! zero-roots.max-roots 0)]
    [limited : graph.CompilerIncrementalGraphBuilder
      (match (graph.compiler-graph-begin small)
        [(graph.ResultCompilerIncrementalGraphBuilder.Ok builder) builder]
        [_ (string.tl_oob_abort)])]
    [_limited : unit
      (begin
        (graph-test-add-node! (&mut limited) (graph-test-load))
        (graph-test-add-node! (&mut limited) (graph-test-macro))
        unit)]
    [aborted : graph.CompilerIncrementalGraphBuilder (graph-test-begin)]
    [_aborted : unit (graph.compiler-graph-abort! (&mut aborted))]
    [added-after-abort? : bool
      (graph.compiler-graph-add-node! (&mut aborted) (graph-test-load))]
    [conflict-root : graph.CompilerIncrementalGraphBuilder (graph-test-begin)]
    [_conflict-root : unit
      (begin
        (graph-test-add-root!
          (&mut conflict-root)
          (graph-test-root "typelisp.root.build" "app" 0 1))
        (graph-test-add-root!
          (&mut conflict-root)
          (graph-test-root "typelisp.root.build" "app" 1 2))
        (graph-test-add-node! (&mut conflict-root) (graph-test-load))
        (graph-test-add-node! (&mut conflict-root) (graph-test-macro))
        unit)]
    (and
      ;; One query observed with two different stored-result keys.
      (=
        (graph-test-builder-error
          (graph-test-load)
          (graph-test-load-with-key (graph-test-key 5)))
        graph.compiler-graph-error-conflict)
      (=
        (graph-test-builder-error
          (graph-test-load)
          (graph-test-load-with-key wrong-domain))
        graph.compiler-graph-error-key)
      (=
        (graph-test-builder-error
          (graph-test-load)
          (graph-test-load-with-key empty))
        graph.compiler-graph-error-key)
      (=
        (graph-test-builder-error
          (graph-test-load)
          (graph-test-load-with-key zero-schema))
        graph.compiler-graph-error-key)
      (=
        (graph-test-builder-error (graph-test-load) bad-output)
        graph.compiler-graph-error-output)
      (=
        (graph-test-builder-error (graph-test-load) foreign-trace)
        graph.compiler-graph-error-trace-parent)
      (=
        (graph-test-error-code (graph.compiler-graph-finalize limited))
        graph.compiler-graph-error-limit)
      (=
        (graph-test-error-code (graph.compiler-graph-finalize conflict-root))
        graph.compiler-graph-error-conflict)
      ;; An aborted builder accepts nothing and publishes nothing.
      (not added-after-abort?)
      (=
        (graph-test-error-code (graph.compiler-graph-finalize aborted))
        graph.compiler-graph-error-state)
      (match (graph.compiler-graph-begin zero-roots)
        [(graph.ResultCompilerIncrementalGraphBuilder.Ok _) false]
        [(graph.ResultCompilerIncrementalGraphBuilder.Err error)
          (= error.code graph.compiler-graph-error-limit-config)]))))

;; --- structural rejections -------------------------------------------------------
(define (graph-test-structure
  [root-kind : i64]
  [root-length : i64]
  [first : graph.CompilerIncrementalGraphNode]
  [second? : bool]
  [second : graph.CompilerIncrementalGraphNode]) : graph.ResultCompilerIncrementalGraph
  (let
    [builder : graph.CompilerIncrementalGraphBuilder (graph-test-begin)]
    (begin
      (graph-test-add-root!
        (&mut builder)
        (graph-test-root "typelisp.root.build" "app" root-kind root-length))
      (graph-test-add-node! (&mut builder) first)
      (when second? (graph-test-add-node! (&mut builder) second))
      (graph.compiler-graph-finalize builder))))

(define (graph-test-structure-rejections?) : bool
  (let
    [orphan : graph.CompilerIncrementalGraphNode
      (graph-test-node
        2
        50
        50
        50
        (graph-test-trace
          (graph-test-query 2 50)
          "src/x.tl"
          false
          0
          0
          0
          0
          0
          0
          0))]
    ;; a <-> b: each module's result was read by the other.
    [a : graph.CompilerIncrementalGraphNode
      (graph-test-node
        2
        20
        20
        20
        (graph-test-trace
          (graph-test-query 2 20)
          "src/a.tl"
          false
          1
          2
          21
          21
          0
          0
          0))]
    [b : graph.CompilerIncrementalGraphNode
      (graph-test-node
        2
        21
        21
        21
        (graph-test-trace
          (graph-test-query 2 21)
          "src/b.tl"
          false
          1
          2
          20
          20
          0
          0
          0))]
    ;; The same import cycle as one coarsened unit observing both sources.
    [unit-trace : trace.CompilerIncrementalTrace
      (let
        [builder : trace.CompilerIncrementalTraceBuilder
          (graph-test-trace-begin (graph-test-query 2 30))]
        (begin
          (graph-test-note! (&mut builder) (graph-test-source "src/a.tl"))
          (graph-test-note! (&mut builder) (graph-test-source "src/b.tl"))
          (graph-test-trace-finish builder)))]
    [scc : graph.CompilerIncrementalGraphNode
      (graph-test-node 2 30 30 30 unit-trace)]
    [absent-child : graph.CompilerIncrementalGraphError
      (graph-test-error
        (graph-test-structure 3 4 (graph-test-decl 13) false (graph-test-load)))]
    [absent-root : graph.ResultCompilerIncrementalGraph
      (graph-test-structure 3 77 (graph-test-load) false (graph-test-load))]
    [unreachable : graph.ResultCompilerIncrementalGraph
      (graph-test-structure 0 1 (graph-test-load) true orphan)]
    [cycle : graph.ResultCompilerIncrementalGraph
      (graph-test-structure 2 20 a true b)]
    [coarsened : graph.ResultCompilerIncrementalGraph
      (graph-test-structure 2 30 scc false (graph-test-load))]
    (and
      (= absent-child.code graph.compiler-graph-error-absent-child)
      (= absent-child.node 0)
      (=
        (graph-test-error-code absent-root)
        graph.compiler-graph-error-absent-root)
      (=
        (graph-test-error-code unreachable)
        graph.compiler-graph-error-unreachable)
      (= (graph-test-error-code cycle) graph.compiler-graph-error-cycle)
      (= (graph-test-error-code coarsened) 0))))

;; --- hostile transcripts -------------------------------------------------------------
(define (graph-test-push-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [domain : String]
  [schema : i64]) : unit
  (begin
    (binary.compiler-incremental-binary-push-string! out (& domain))
    (byte_le.push-u32! out schema)))

(define (graph-test-push-root!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [purpose : String]
  [name : String]
  [query : identity.CompilerIncrementalIdentity]) : unit
  (begin
    (binary.compiler-incremental-binary-push-string! out (& purpose))
    (binary.compiler-incremental-binary-push-string! out (& name))
    (byte_le.push-u32! out (array-length query.transcript))
    (binary.compiler-incremental-binary-push-array! out (& query.transcript))))

(define (graph-test-push-node!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [node : graph.CompilerIncrementalGraphNode]) : unit
  (begin
    (byte_le.push-u32! out (array-length node.query.transcript))
    (binary.compiler-incremental-binary-push-array!
      out
      (& node.query.transcript))
    (byte_buf_core.byte-buf-builder-append-string
      out
      (graph.compiler-graph-encode-node-body (& node)))))

(define (graph-test-decode-code [bytes : (__tl_dyn-array u8)]) : i64
  (let
    [limits : graph.CompilerIncrementalGraphLimits
      (graph.compiler-graph-default-limits)]
    (graph-test-error-code (graph.compiler-graph-decode (& bytes) (& limits)))))

;; One root over the load node, then `nodes` load nodes or the given pair.
(define (graph-test-crafted
  [domain : String]
  [schema : i64]
  [first : graph.CompilerIncrementalGraphNode]
  [second? : bool]
  [second : graph.CompilerIncrementalGraphNode]) : (__tl_dyn-array u8)
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 4096)]
    (begin
      (graph-test-push-header! (&mut out) domain schema)
      (byte_le.push-u32! (&mut out) 1)
      (graph-test-push-root!
        (&mut out)
        "typelisp.root.build"
        "app"
        (graph-test-query 0 1))
      (byte_le.push-u32!
        (&mut out)
        (if second?
          2
          1))
      (graph-test-push-node! (&mut out) first)
      (when second? (graph-test-push-node! (&mut out) second))
      (byte_buf_core.byte-buf-builder-finish-array (& out)))))

;; A trace of `query` whose one child-result edge names `query` itself.
(define (graph-test-self-trace [query : identity.CompilerIncrementalIdentity]) : trace.CompilerIncrementalTrace
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 1024)]
    [key : trace.CompilerIncrementalTraceKey
      (trace.CompilerIncrementalTraceKey.Child
        "deps"
        0
        (identity.CompilerIncrementalIdentity
          query.schema
          query.query-kind-tag
          query.record-count
          (binary.compiler-incremental-binary-copy (& query.transcript))
          query.fingerprint))]
    [observation : trace.CompilerIncrementalTraceObservation
      (trace.CompilerIncrementalTraceObservation.Child (graph-test-output 11))]
    [key-bytes : String (trace.compiler-trace-encode-key (& key))]
    [observation-bytes : String
      (trace.compiler-trace-encode-observation (& observation))]
    (begin
      (binary.compiler-incremental-binary-push-string!
        (&mut out)
        (& trace.compiler-incremental-trace-domain))
      (byte_le.push-u32! (&mut out) 1)
      (byte_le.push-u32! (&mut out) (array-length query.transcript))
      (binary.compiler-incremental-binary-push-array!
        (&mut out)
        (& query.transcript))
      (byte_le.push-u32! (&mut out) 1)
      (binary.compiler-incremental-binary-push-string! (&mut out) (& key-bytes))
      (binary.compiler-incremental-binary-push-string!
        (&mut out)
        (& observation-bytes))
      (let
        [bytes : (__tl_dyn-array u8)
          (byte_buf_core.byte-buf-builder-finish-array (& out))]
        (trace.CompilerIncrementalTrace 1 query 1 bytes (graph-test-digest 0))))))

(define (graph-test-hostile?) : bool
  (let
    [valid : graph.CompilerIncrementalGraph
      (graph-test-unwrap (graph-test-representative false false))]
    [bytes : (__tl_dyn-array u8) (graph.compiler-graph-encode (& valid))]
    [length : i64 (array-length bytes)]
    [prefixes-ok? : bool true]
    [prefix : i64 0]
    [trailing : (__tl_dyn-array u8) (__tl_make-array u8 (+ length 1))]
    [huge-roots : (__tl_dyn-array u8)
      (binary.compiler-incremental-binary-copy (& bytes))]
    [huge-nodes : (__tl_dyn-array u8)
      (graph-test-crafted
        "typelisp.compiler.incremental.graph"
        1
        (graph-test-load)
        false
        (graph-test-load))]
    [bad-tag : (__tl_dyn-array u8)
      (graph-test-crafted
        "typelisp.compiler.incremental.graph"
        1
        (graph-test-load)
        false
        (graph-test-load))]
    [header : i64
      (+ 4 (string.string-length graph.compiler-incremental-graph-domain))]
    [load : graph.CompilerIncrementalGraphNode (graph-test-load)]
    [load-query-bytes : i64 (array-length load.query.transcript)]
    (begin
      ;; Every proper prefix fails, terminates, and leaves decoding reusable.
      (while (< prefix length)
        (let
          [cut : (__tl_dyn-array u8)
            (graph.compiler-graph-range-bytes (& bytes) 0 prefix)]
          (begin
            (when (= (graph-test-decode-code cut) 0) (set! prefixes-ok? false))
            (set! prefix (+ prefix 1)))))
      (let
        [index : i64 0]
        (while (< index length)
          (begin
            (set! (array-ref trailing index) (array-ref bytes index))
            (set! index (+ index 1)))))
      ;; Counts no input could hold are refused before any allocation.
      (set! (array-ref huge-roots (+ header 4)) 255)
      (set! (array-ref huge-roots (+ header 5)) 255)
      (set! (array-ref huge-roots (+ header 6)) 255)
      (set! (array-ref huge-roots (+ header 7)) 255)
      (let
        ;; header, schema and root count, then the root's purpose, name and query.
        [node-count : i64
          (+
            (+ header 8)
            (+
              (+ 4 (string.string-length "typelisp.root.build"))
              (+ (+ 4 3) (+ 4 load-query-bytes))))]
        (begin
          (set! (array-ref huge-nodes node-count) 255)
          (set! (array-ref huge-nodes (+ node-count 1)) 255)
          (set! (array-ref huge-nodes (+ node-count 2)) 255)
          (set! (array-ref bad-tag (+ node-count (+ 8 load-query-bytes))) 0)))
      (and
        prefixes-ok?
        (=
          (graph-test-decode-code
            (graph.compiler-graph-range-bytes (& bytes) 0 length))
          0)
        (=
          (graph-test-decode-code trailing)
          graph.compiler-graph-error-trailing)
        (=
          (graph-test-decode-code
            (graph-test-crafted
              "typelisp.compiler.incremental.trace"
              1
              (graph-test-load)
              false
              (graph-test-load)))
          graph.compiler-graph-error-schema)
        (=
          (graph-test-decode-code
            (graph-test-crafted
              "typelisp.compiler.incremental.graph"
              2
              (graph-test-load)
              false
              (graph-test-load)))
          graph.compiler-graph-error-schema)
        (let
          [code : i64 (graph-test-decode-code huge-roots)]
          (or
            (= code graph.compiler-graph-error-limit)
            (= code graph.compiler-graph-error-framing)))
        (let
          [code : i64 (graph-test-decode-code huge-nodes)]
          (or
            (= code graph.compiler-graph-error-limit)
            (= code graph.compiler-graph-error-framing)))
        (= (graph-test-decode-code bad-tag) graph.compiler-graph-error-framing)
        ;; The same node twice, and two nodes out of canonical order.
        (=
          (graph-test-decode-code
            (graph-test-crafted
              "typelisp.compiler.incremental.graph"
              1
              (graph-test-load)
              true
              (graph-test-load)))
          graph.compiler-graph-error-order)
        (let
          [macro : graph.CompilerIncrementalGraphNode (graph-test-macro)]
          [load-first? : bool
            (<
              (graph.compiler-graph-range-compare
                (& load.query.transcript)
                0
                (array-length load.query.transcript)
                (& macro.query.transcript)
                0
                (array-length macro.query.transcript))
              0)]
          [code : i64
            (if load-first?
              (graph-test-decode-code
                (graph-test-crafted
                  "typelisp.compiler.incremental.graph"
                  1
                  (graph-test-macro)
                  true
                  (graph-test-load)))
              (graph-test-decode-code
                (graph-test-crafted
                  "typelisp.compiler.incremental.graph"
                  1
                  (graph-test-load)
                  true
                  (graph-test-macro))))]
          (= code graph.compiler-graph-error-order))
        ;; A node whose trace is another query's, and one naming itself.
        (=
          (graph-test-decode-code
            (graph-test-crafted
              "typelisp.compiler.incremental.graph"
              1
              (graph-test-node 0 1 11 1 (graph-test-macro-trace))
              false
              (graph-test-load)))
          graph.compiler-graph-error-trace-parent)
        (=
          (graph-test-decode-code
            (graph-test-crafted
              "typelisp.compiler.incremental.graph"
              1
              (graph-test-node
                0
                1
                11
                1
                (graph-test-self-trace (graph-test-query 0 1)))
              false
              (graph-test-load)))
          graph.compiler-graph-error-trace)))))

(test
  compiler-incremental-graph-round-trip
  (unless (graph-test-round-trip?) (string.tl_oob_abort)))

(test
  compiler-incremental-graph-canonical-across-observation-order
  (unless (graph-test-canonical?) (string.tl_oob_abort)))

(test
  compiler-incremental-graph-output-identity-not-stored-key
  (unless (graph-test-output-key-separation?) (string.tl_oob_abort)))

(test
  compiler-incremental-graph-lookup-and-traversal
  (unless (graph-test-traversal?) (string.tl_oob_abort)))

(test
  compiler-incremental-graph-ready-nodes-leave-in-structural-order
  (unless (graph-test-tie-break?) (string.tl_oob_abort)))

(test
  compiler-incremental-graph-exact-transcripts-at-lookup
  (unless (graph-test-collision-seams?) (string.tl_oob_abort)))

(test
  compiler-incremental-graph-opaque-store-round-trip
  (unless (graph-test-opaque-store?) (string.tl_oob_abort)))

(test
  compiler-incremental-graph-builder-rejections
  (unless (graph-test-builder-rejections?) (string.tl_oob_abort)))

(test
  compiler-incremental-graph-structure-rejections
  (unless (graph-test-structure-rejections?) (string.tl_oob_abort)))

(test
  compiler-incremental-graph-hostile-transcripts
  (unless (graph-test-hostile?) (string.tl_oob_abort)))