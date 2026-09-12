;; Synthetic frontend dependency graphs and hostile transcript fixtures (#7267).
(import compiler_incremental_binary as binary)
(import compiler_incremental_identity as identity)
(import compiler_incremental_trace as trace)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.string)

(define (trace-test-digest) : sha256.Sha256Digest
  (sha256.Sha256Digest (init)))

(define (trace-test-child [domain : String] [length : i64]) : identity.CompilerIncrementalChildIdentity
  (identity.CompilerIncrementalChildIdentity
    domain
    1
    length
    (trace-test-digest)))

(define (trace-test-parent [length : i64]) : identity.CompilerIncrementalIdentity
  (let
    [query : identity.CompilerIncrementalQuery
      (identity.CompilerIncrementalQuery
        (identity.CompilerIncrementalQueryKind.Typecheck)
        (identity.CompilerIncrementalBuildIdentity.Available
          (trace-test-child "typelisp.compiler-build" length))
        (__tl_make-array identity.CompilerIncrementalInput 0))]
    [limits : identity.CompilerIncrementalIdentityLimits
      (identity.compiler-incremental-identity-default-limits)]
    (match (identity.compiler-incremental-identity-encode query (& limits))
      [(identity.ResultCompilerIncrementalIdentity.Ok value) value]
      [_ (string.tl_oob_abort)])))

(define (trace-test-source [length : i64]) : trace.CompilerIncrementalTraceEdge
  (trace.CompilerIncrementalTraceEdge
    (trace.CompilerIncrementalTraceKey.Source "src/main.tl")
    (trace.CompilerIncrementalTraceObservation.Source
      (trace.CompilerIncrementalTraceContent.Present
        (identity.CompilerIncrementalContentIdentity
          "typelisp.source-content"
          1
          length
          (trace-test-digest))))))

(define (trace-test-absent) : trace.CompilerIncrementalTraceEdge
  (trace.CompilerIncrementalTraceEdge
    (trace.CompilerIncrementalTraceKey.ImportResolution "library" "missing")
    (trace.CompilerIncrementalTraceObservation.ImportResolution
      (trace.CompilerIncrementalTraceArtifact.Absent 1))))

(define (trace-test-child-edge [result-length : i64]) : trace.CompilerIncrementalTraceEdge
  (trace.CompilerIncrementalTraceEdge
    (trace.CompilerIncrementalTraceKey.Child
      "declarations"
      0
      (trace-test-parent 9))
    (trace.CompilerIncrementalTraceObservation.Child
      (identity.CompilerIncrementalSemanticOutputIdentity
        (trace-test-child "typelisp.semantic-output" result-length)))))

(define (trace-test-child-edge-query [query-length : i64]) : trace.CompilerIncrementalTraceEdge
  (trace.CompilerIncrementalTraceEdge
    (trace.CompilerIncrementalTraceKey.Child
      "declarations"
      0
      (trace-test-parent query-length))
    (trace.CompilerIncrementalTraceObservation.Child
      (identity.CompilerIncrementalSemanticOutputIdentity
        (trace-test-child "typelisp.semantic-output" 20)))))

(define (trace-test-colliding-lookup-hash
  [_key : (& _key trace.CompilerIncrementalTraceKey)]) : i64
  0)

(define (trace-test-build
  [reverse? : bool]
  [duplicate? : bool]
  [source-length : i64]
  [result-length : i64]) : trace.CompilerIncrementalTrace
  (let
    [limits : trace.CompilerIncrementalTraceLimits
      (trace.compiler-trace-default-limits)]
    (match (trace.compiler-trace-begin (trace-test-parent 5) limits)
      [(trace.ResultCompilerIncrementalTraceBuilder.Ok builder)
        (begin
          (if reverse?
            (begin
              (trace.compiler-trace-note!
                (&mut builder)
                (trace-test-child-edge result-length))
              (trace.compiler-trace-note! (&mut builder) (trace-test-absent))
              (trace.compiler-trace-note!
                (&mut builder)
                (trace-test-source source-length)))
            (begin
              (trace.compiler-trace-note!
                (&mut builder)
                (trace-test-source source-length))
              (trace.compiler-trace-note! (&mut builder) (trace-test-absent))
              (trace.compiler-trace-note!
                (&mut builder)
                (trace-test-child-edge result-length))))
          (if duplicate?
            (begin
              (trace.compiler-trace-note! (&mut builder) (trace-test-absent))
              unit)
            unit)
          (match (trace.compiler-trace-finalize builder)
            [(trace.ResultCompilerIncrementalTrace.Ok value) value]
            [_ (string.tl_oob_abort)]))]
      [_ (string.tl_oob_abort)])))

(define (trace-test-canonical?) : bool
  (let
    [a : trace.CompilerIncrementalTrace (trace-test-build false false 10 20)]
    [b : trace.CompilerIncrementalTrace (trace-test-build true true 10 20)]
    [limits : trace.CompilerIncrementalTraceLimits
      (trace.compiler-trace-default-limits)]
    (and
      (= a.edge-count 3)
      (= b.edge-count 3)
      (binary.compiler-incremental-binary-bytes-eq?
        (& a.transcript)
        (& b.transcript))
      (match (trace.compiler-trace-compare (& a) (& b) (& limits))
        [(trace.CompilerIncrementalTraceCompare.Hit) true]
        [_ false]))))

(define (trace-test-misses?) : bool
  (let
    [a : trace.CompilerIncrementalTrace (trace-test-build false false 10 20)]
    [source : trace.CompilerIncrementalTrace
      (trace-test-build true false 11 20)]
    [child : trace.CompilerIncrementalTrace (trace-test-build true false 10 21)]
    [limits : trace.CompilerIncrementalTraceLimits
      (trace.compiler-trace-default-limits)]
    [key : trace.CompilerIncrementalTraceKey
      (trace.CompilerIncrementalTraceKey.Child
        "declarations"
        0
        (trace-test-parent 9))]
    (and
      (match (trace.compiler-trace-compare (& a) (& source) (& limits))
        [(trace.CompilerIncrementalTraceCompare.Miss category _)
          (= category trace.compiler-trace-miss-source)]
        [_ false])
      (match (trace.compiler-trace-compare (& a) (& child) (& limits))
        [(trace.CompilerIncrementalTraceCompare.Miss category _)
          (= category trace.compiler-trace-miss-child)]
        [_ false])
      (match (trace.compiler-trace-logical-key (& key) (& a.parent) (& limits))
        [(trace.ResultCompilerIncrementalTraceLogicalKey.Ok key) (= key.kind 9)]
        [_ false]))))

(define (trace-test-transaction?) : bool
  (let
    [limits : trace.CompilerIncrementalTraceLimits
      (trace.compiler-trace-default-limits)]
    [conflict? : bool
      (match (trace.compiler-trace-begin (trace-test-parent 5) limits)
        [(trace.ResultCompilerIncrementalTraceBuilder.Ok builder)
          (begin
            (trace.compiler-trace-note! (&mut builder) (trace-test-source 1))
            (trace.compiler-trace-note! (&mut builder) (trace-test-source 2))
            (match (trace.compiler-trace-finalize builder)
              [(trace.ResultCompilerIncrementalTrace.Err error)
                (= error.code trace.compiler-trace-error-conflict)]
              [_ false]))]
        [_ false])]
    [self? : bool
      (match (trace.compiler-trace-begin (trace-test-parent 5) limits)
        [(trace.ResultCompilerIncrementalTraceBuilder.Ok builder)
          (let
            [ok? : bool
              (trace.compiler-trace-note!
                (&mut builder)
                (trace.CompilerIncrementalTraceEdge
                  (trace.CompilerIncrementalTraceKey.Child
                    "cycle"
                    0
                    (trace-test-parent 5))
                  (trace.CompilerIncrementalTraceObservation.Child
                    (identity.CompilerIncrementalSemanticOutputIdentity
                      (trace-test-child "typelisp.semantic-output" 1)))))]
            (and
              (not ok?)
              (match (trace.compiler-trace-finalize builder)
                [(trace.ResultCompilerIncrementalTrace.Err error)
                  (= error.code trace.compiler-trace-error-state)]
                [_ false])))]
        [_ false])]
    [aborted? : bool
      (match (trace.compiler-trace-begin (trace-test-parent 5) limits)
        [(trace.ResultCompilerIncrementalTraceBuilder.Ok builder)
          (begin
            (trace.compiler-trace-note! (&mut builder) (trace-test-source 1))
            (trace.compiler-trace-abort! (&mut builder))
            (match (trace.compiler-trace-finalize builder)
              [(trace.ResultCompilerIncrementalTrace.Err error)
                (= error.code trace.compiler-trace-error-state)]
              [_ false]))]
        [_ false])]
    (and conflict? self? aborted?)))

(define (trace-test-note-budget?) : bool
  (let
    [limits : trace.CompilerIncrementalTraceLimits
      (trace.CompilerIncrementalTraceLimits 512 100 512 4 2048 2048)]
    (match (trace.compiler-trace-begin (trace-test-parent 5) limits)
      [(trace.ResultCompilerIncrementalTraceBuilder.Ok builder)
        (let
          [attempts : i64 0]
          [accepted? : bool true]
          (begin
            ;; Identical notes would collapse at finalization, but must not
            ;; accumulate without a bound in the open transaction.
            (while (and (< attempts 100) accepted?)
              (begin
                (set!
                  accepted?
                  (trace.compiler-trace-note!
                    (&mut builder)
                    (trace-test-absent)))
                (set! attempts (+ attempts 1))))
            (and
              (> attempts 1)
              (< attempts 100)
              (not accepted?)
              (match (trace.compiler-trace-finalize builder)
                [(trace.ResultCompilerIncrementalTrace.Err error)
                  (= error.code trace.compiler-trace-error-state)]
                [_ false]))))]
      [_ false])))

(define (trace-test-structural-child-keys?) : bool
  (let
    [parent : identity.CompilerIncrementalIdentity (trace-test-parent 5)]
    [limits : trace.CompilerIncrementalTraceLimits
      (trace.compiler-trace-default-limits)]
    [first : trace.CompilerIncrementalTraceKey
      (trace.CompilerIncrementalTraceKey.Child
        "declarations"
        0
        (trace-test-parent 9))]
    [second : trace.CompilerIncrementalTraceKey
      (trace.CompilerIncrementalTraceKey.Child
        "declarations"
        0
        (trace-test-parent 10))]
    [distinct? : bool
      (match (trace.compiler-trace-logical-key (& first) (& parent) (& limits))
        [(trace.ResultCompilerIncrementalTraceLogicalKey.Ok a)
          (match (trace.compiler-trace-logical-key
            (& second)
            (& parent)
            (& limits))
            [(trace.ResultCompilerIncrementalTraceLogicalKey.Ok b)
              (not
                (identity.compiler-incremental-string-eq?
                  (& a.bytes)
                  (& b.bytes)))]
            [_ false])]
        [_ false])]
    (and
      distinct?
      (=
        (trace-test-colliding-lookup-hash (& first))
        (trace-test-colliding-lookup-hash (& second)))
      ;; A lookup accelerator returning the same constant for both queries
      ;; cannot collapse them: finalization merges complete key bytes only.
      (match (trace.compiler-trace-begin parent limits)
        [(trace.ResultCompilerIncrementalTraceBuilder.Ok builder)
          (begin
            (trace.compiler-trace-note!
              (&mut builder)
              (trace-test-child-edge-query 10))
            (trace.compiler-trace-note!
              (&mut builder)
              (trace-test-child-edge-query 9))
            (match (trace.compiler-trace-finalize builder)
              [(trace.ResultCompilerIncrementalTrace.Ok value)
                (= value.edge-count 2)]
              [_ false]))]
        [_ false]))))

(define (trace-test-corruption?) : bool
  (let
    [a : trace.CompilerIncrementalTrace (trace-test-build false false 10 20)]
    [limits : trace.CompilerIncrementalTraceLimits
      (trace.compiler-trace-default-limits)]
    [bytes : (__tl_dyn-array u8)
      (binary.compiler-incremental-binary-copy (& a.transcript))]
    (begin
      (set! (array-ref bytes (- (array-length bytes) 1)) (cast 255 : u8))
      (let
        [bad : trace.CompilerIncrementalTrace
          (trace.CompilerIncrementalTrace
            a.schema
            a.parent
            a.edge-count
            bytes
            a.fingerprint)]
        (match (trace.compiler-trace-compare (& a) (& bad) (& limits))
          [(trace.CompilerIncrementalTraceCompare.Corrupt error)
            (= error.code trace.compiler-trace-error-corrupt)]
          [_ false])))))

(define (trace-test-rehash [bytes : (__tl_dyn-array u8)] [count : i64]) : trace.CompilerIncrementalTrace
  (match (identity.compiler-incremental-digest-array (& bytes))
    [(sha256.Sha256FinalizeOk digest)
      (trace.CompilerIncrementalTrace
        trace.compiler-incremental-trace-schema
        (trace-test-parent 5)
        count
        bytes
        digest)]
    [_ (string.tl_oob_abort)]))

(define (trace-test-hostile-frames?) : bool
  (let
    [original : trace.CompilerIncrementalTrace
      (trace-test-build false false 10 20)]
    [limits : trace.CompilerIncrementalTraceLimits
      (trace.compiler-trace-default-limits)]
    [header : i64
      (+
        16
        (+
          (string.string-length trace.compiler-incremental-trace-domain)
          (array-length original.parent.transcript)))]
    [schema-bytes : (__tl_dyn-array u8)
      (binary.compiler-incremental-binary-copy (& original.transcript))]
    [count-bytes : (__tl_dyn-array u8)
      (binary.compiler-incremental-binary-copy (& original.transcript))]
    [tag-bytes : (__tl_dyn-array u8)
      (binary.compiler-incremental-binary-copy (& original.transcript))]
    [trailing : (__tl_dyn-array u8)
      (__tl_make-array u8 (+ (array-length original.transcript) 1))]
    [index : i64 0]
    (begin
      (set!
        (array-ref
          schema-bytes
          (+ 4 (string.string-length trace.compiler-incremental-trace-domain)))
        (cast 2 : u8))
      (set! (array-ref count-bytes (- header 4)) (cast 4 : u8))
      (set! (array-ref tag-bytes (+ header 4)) (cast 255 : u8))
      (while (< index (array-length original.transcript))
        (begin
          (set!
            (array-ref trailing index)
            (array-ref original.transcript index))
          (set! index (+ index 1))))
      (let
        [schema : trace.CompilerIncrementalTrace
          (trace-test-rehash schema-bytes 3)]
        [count : trace.CompilerIncrementalTrace
          (trace-test-rehash count-bytes 3)]
        [tag : trace.CompilerIncrementalTrace (trace-test-rehash tag-bytes 3)]
        [extra : trace.CompilerIncrementalTrace (trace-test-rehash trailing 3)]
        [small : trace.CompilerIncrementalTraceLimits
          (trace.CompilerIncrementalTraceLimits
            limits.max-bytes
            2
            limits.max-edge-bytes
            limits.max-depth
            limits.max-owned-bytes
            limits.max-work)]
        (and
          (match (trace.compiler-trace-compare
            (& original)
            (& schema)
            (& limits))
            [(trace.CompilerIncrementalTraceCompare.Miss category _)
              (= category trace.compiler-trace-miss-schema)]
            [_ false])
          (match (trace.compiler-trace-compare
            (& original)
            (& count)
            (& limits))
            [(trace.CompilerIncrementalTraceCompare.Corrupt _) true]
            [_ false])
          (match (trace.compiler-trace-compare (& original) (& tag) (& limits))
            [(trace.CompilerIncrementalTraceCompare.Corrupt _) true]
            [_ false])
          (match (trace.compiler-trace-compare
            (& original)
            (& extra)
            (& limits))
            [(trace.CompilerIncrementalTraceCompare.Corrupt _) true]
            [_ false])
          (match (trace.compiler-trace-compare
            (& original)
            (& original)
            (& small))
            [(trace.CompilerIncrementalTraceCompare.Miss category _)
              (= category trace.compiler-trace-miss-limit)]
            [_ false]))))))

(test
  compiler-incremental-trace-canonical-order-and-dedup
  (if (trace-test-canonical?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-trace-typed-first-miss-and-logical-key
  (if (trace-test-misses?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-trace-transaction-and-self-dependency
  (if (trace-test-transaction?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-trace-note-budget-before-finalize
  (if (trace-test-note-budget?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-trace-structural-child-keys-survive-hash-collision
  (if (trace-test-structural-child-keys?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-trace-corrupt-fingerprint
  (if (trace-test-corruption?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-trace-schema-tag-count-trailing-and-ceilings
  (if (trace-test-hostile-frames?)
    unit
    (string.tl_oob_abort)))