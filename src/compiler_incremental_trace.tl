;; Pure, transactional frontend-query dependency traces (#7267). Producers
;; observe typed facts; only finalize publishes a sorted, complete transcript.
;; Child edges name full portable query transcripts, never cache-store keys.
(import compiler_incremental_binary as binary)
(import compiler_incremental_identity)
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf_core)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.string)
(import stdlib.vector)
(import stdlib.sort)

(define compiler-incremental-trace-domain : String
  "typelisp.compiler.incremental.trace")
(define compiler-incremental-trace-schema : i64
  1)
(define compiler-trace-error-state : i64
  1)
(define compiler-trace-error-limit : i64
  2)
(define compiler-trace-error-parent : i64
  3)
(define compiler-trace-error-edge : i64
  4)
(define compiler-trace-error-conflict : i64
  5)
(define compiler-trace-error-self : i64
  6)
(define compiler-trace-error-corrupt : i64
  7)
(define compiler-trace-error-schema : i64
  8)
(define compiler-trace-miss-query-kind : i64
  1)
(define compiler-trace-miss-source : i64
  2)
(define compiler-trace-miss-import : i64
  3)
(define compiler-trace-miss-config : i64
  4)
(define compiler-trace-miss-compiler : i64
  5)
(define compiler-trace-miss-stdlib : i64
  6)
(define compiler-trace-miss-package : i64
  7)
(define compiler-trace-miss-macro : i64
  8)
(define compiler-trace-miss-child : i64
  9)
(define compiler-trace-miss-corrupt : i64
  10)
(define compiler-trace-miss-schema : i64
  11)
(define compiler-trace-miss-limit : i64
  12)

(defstruct CompilerIncrementalTraceLimits
  (max-bytes i64)
  (max-edges i64)
  (max-edge-bytes i64)
  (max-depth i64)
  (max-owned-bytes i64)
  (max-work i64))

(define (compiler-trace-default-limits) : CompilerIncrementalTraceLimits
  (CompilerIncrementalTraceLimits 16777216 65536 1048576 4 134217728 134217728))

(defstruct CompilerIncrementalTraceError
  (code i64)
  (message String))

;; Absent is an observed bounded decision, not an omitted dependency. The
;; reason code is schema-owned (1=not found, 2=unavailable, 3=rejected).
(defenum CompilerIncrementalTraceContent
  (Present compiler_incremental_identity.CompilerIncrementalContentIdentity)
  (Absent i64))

(defenum CompilerIncrementalTraceSemantic
  (Present
    compiler_incremental_identity.CompilerIncrementalSemanticOutputIdentity)
  (Absent i64))

(defenum CompilerIncrementalTraceArtifact
  (Present compiler_incremental_identity.CompilerIncrementalChildIdentity)
  (Absent i64))

;; A logical key is available before the observation's output exists. In
;; particular, Child's sequence/ordinal/query transcript exclude its result.
(defenum CompilerIncrementalTraceKey
  (Source String)
  (ImportSurface String String)
  (ImportResolution String String)
  (Configuration String)
  (CompilerBuild)
  (Stdlib String)
  (Package String String)
  (MacroComptime
    String
    compiler_incremental_identity.CompilerIncrementalChildIdentity)
  (Child String i64 compiler_incremental_identity.CompilerIncrementalIdentity))

(defenum CompilerIncrementalTraceObservation
  (Source CompilerIncrementalTraceContent)
  (ImportSurface CompilerIncrementalTraceSemantic)
  (ImportResolution CompilerIncrementalTraceArtifact)
  (Configuration compiler_incremental_identity.CompilerIncrementalChildIdentity)
  (CompilerBuild compiler_incremental_identity.CompilerIncrementalChildIdentity)
  (Stdlib compiler_incremental_identity.CompilerIncrementalContentIdentity)
  (Package compiler_incremental_identity.CompilerIncrementalContentIdentity)
  (MacroComptime CompilerIncrementalTraceSemantic)
  (Child
    compiler_incremental_identity.CompilerIncrementalSemanticOutputIdentity))

(defstruct CompilerIncrementalTraceEdge
  (key CompilerIncrementalTraceKey)
  (observation CompilerIncrementalTraceObservation))

(defstruct CompilerIncrementalTraceRecord
  (key String)
  (observation String)
  (kind i64))

(defstruct CompilerIncrementalTraceLogicalKey
  (kind i64)
  (bytes String))

(defenum ResultCompilerIncrementalTraceLogicalKey
  (Ok CompilerIncrementalTraceLogicalKey)
  (Err CompilerIncrementalTraceError))

(import (stdlib.vector.vector CompilerIncrementalTraceRecord) as trace_record_vec)
(import (stdlib.sort.vec CompilerIncrementalTraceRecord) as trace_record_sort)

(defstruct CompilerIncrementalTraceBuilder
  (state i64)
  (parent compiler_incremental_identity.CompilerIncrementalIdentity)
  (edges trace_record_vec.Vec)
  (limits CompilerIncrementalTraceLimits)
  (planned-bytes i64)
  (owned-bytes i64))

(defstruct CompilerIncrementalTrace
  (schema i64)
  (parent compiler_incremental_identity.CompilerIncrementalIdentity)
  (edge-count i64)
  (transcript (__tl_dyn-array u8))
  (fingerprint sha256.Sha256Digest))

(defenum ResultCompilerIncrementalTraceBuilder
  (Ok CompilerIncrementalTraceBuilder)
  (Err CompilerIncrementalTraceError))

(defenum ResultCompilerIncrementalTrace
  (Ok CompilerIncrementalTrace)
  (Err CompilerIncrementalTraceError))

(defenum ResultCompilerIncrementalTraceRecords
  (Ok trace_record_vec.Vec)
  (Err CompilerIncrementalTraceError))

(defenum ResultCompilerIncrementalTraceRecord
  (Ok CompilerIncrementalTraceRecord)
  (Err CompilerIncrementalTraceError))

(defenum CompilerIncrementalTraceCompare
  (Hit)
  (Miss i64 i64)
  (Corrupt CompilerIncrementalTraceError))

(define (compiler-trace-error [code : i64] [message : String]) : CompilerIncrementalTraceError
  (CompilerIncrementalTraceError code message))

(define (compiler-trace-limits-valid?
  [limits : (& limits CompilerIncrementalTraceLimits)]) : bool
  (and
    (> limits.max-bytes 0)
    (<= limits.max-bytes 4294967295)
    (>= limits.max-edges 0)
    (<= limits.max-edges 4294967295)
    (> limits.max-edge-bytes 0)
    (<= limits.max-edge-bytes limits.max-bytes)
    (>= limits.max-depth 3)
    (>= limits.max-owned-bytes (* limits.max-bytes 4))
    (>= limits.max-work (* limits.max-bytes 4))))

(define (compiler-trace-identity-limits
  [limits : (& limits CompilerIncrementalTraceLimits)]) : compiler_incremental_identity.CompilerIncrementalIdentityLimits
  (compiler_incremental_identity.CompilerIncrementalIdentityLimits
    limits.max-bytes
    limits.max-edges
    limits.max-edge-bytes
    limits.max-edge-bytes
    limits.max-depth
    limits.max-owned-bytes
    limits.max-work))

(define (compiler-trace-parent-valid?
  [parent
    : (& parent compiler_incremental_identity.CompilerIncrementalIdentity)]
  [limits : (& limits CompilerIncrementalTraceLimits)]) : bool
  (let
    [id-limits : compiler_incremental_identity.CompilerIncrementalIdentityLimits
      (compiler-trace-identity-limits limits)]
    (and
      (<= (array-length parent.transcript) limits.max-edge-bytes)
      (compiler_incremental_identity.compiler-incremental-identity-fingerprint-valid?
        parent)
      (match (compiler_incremental_identity.compiler-incremental-decode-identity-metadata
        parent
        (& id-limits))
        [(compiler_incremental_identity.ResultCompilerIncrementalDecodedQuery.Ok
            _)
          true]
        [(compiler_incremental_identity.ResultCompilerIncrementalDecodedQuery.Err
            _)
          false]))))

(define (compiler-trace-begin
  [parent : compiler_incremental_identity.CompilerIncrementalIdentity]
  [limits : CompilerIncrementalTraceLimits]) : ResultCompilerIncrementalTraceBuilder
  (let
    [header-bytes : i64
      (+
        16
        (+
          (string.string-length compiler-incremental-trace-domain)
          (array-length parent.transcript)))]
    [owned-bytes : i64 (+ 128 (* 4 (array-length parent.transcript)))]
    (cond
      [(not (compiler-trace-limits-valid? (& limits)))
        (ResultCompilerIncrementalTraceBuilder.Err
          (compiler-trace-error
            compiler-trace-error-limit
            "trace limits are invalid"))]
      [(not (compiler-trace-parent-valid? (& parent) (& limits)))
        (ResultCompilerIncrementalTraceBuilder.Err
          (compiler-trace-error
            compiler-trace-error-parent
            "parent query identity is invalid"))]
      [(or
          (> header-bytes limits.max-bytes)
          (> owned-bytes limits.max-owned-bytes))
        (ResultCompilerIncrementalTraceBuilder.Err
          (compiler-trace-error
            compiler-trace-error-limit
            "trace parent exceeds builder budget"))]
      [else
        (ResultCompilerIncrementalTraceBuilder.Ok
          (CompilerIncrementalTraceBuilder
            1
            parent
            (trace_record_vec.with-capacity 0)
            limits
            header-bytes
            owned-bytes))])))

(define (compiler-trace-abort!
  [builder : (&mut builder CompilerIncrementalTraceBuilder)]) : unit
  (set! builder.state 3))

(define (compiler-trace-note!
  [builder : (&mut builder CompilerIncrementalTraceBuilder)]
  [edge : CompilerIncrementalTraceEdge]) : bool
  (if (and
    (= builder.state 1)
    (< (trace_record_vec.len (& builder.edges)) builder.limits.max-edges))
    (match (compiler-trace-record
      (& edge)
      (& builder.parent)
      (& builder.limits))
      [(ResultCompilerIncrementalTraceRecord.Ok record)
        (let
          [record-bytes : i64
            (compiler_incremental_identity.compiler-incremental-add-size
              (string.string-length record.key)
              (string.string-length record.observation))]
          [planned : i64
            (compiler_incremental_identity.compiler-incremental-add-size
              builder.planned-bytes
              (compiler_incremental_identity.compiler-incremental-add-size
                8
                record-bytes))]
          ;; Include encoded-string copies, record storage, vector slack, and
          ;; temporary encoding buffers in the builder's conservative budget.
          [owned : i64
            (compiler_incremental_identity.compiler-incremental-add-size
              builder.owned-bytes
              (+ 128 (* 4 record-bytes)))]
          (if (or
            (< planned 0)
            (> planned builder.limits.max-bytes)
            (< owned 0)
            (> owned builder.limits.max-owned-bytes))
            (begin
              (set! builder.state 3)
              false)
            (begin
              (trace_record_vec.push-ref! (&mut builder.edges) record)
              (set! builder.planned-bytes planned)
              (set! builder.owned-bytes owned)
              true)))]
      [(ResultCompilerIncrementalTraceRecord.Err _)
        (begin
          (set! builder.state 3)
          false)])
    (begin
      (set! builder.state 3)
      false)))

(define (compiler-trace-key-tag [key : (& key CompilerIncrementalTraceKey)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view key)
    [(CompilerIncrementalTraceKey.Source _) 1]
    [(CompilerIncrementalTraceKey.ImportSurface _ _) 2]
    [(CompilerIncrementalTraceKey.ImportResolution _ _) 3]
    [(CompilerIncrementalTraceKey.Configuration _) 4]
    [(CompilerIncrementalTraceKey.CompilerBuild) 5]
    [(CompilerIncrementalTraceKey.Stdlib _) 6]
    [(CompilerIncrementalTraceKey.Package _ _) 7]
    [(CompilerIncrementalTraceKey.MacroComptime _ _) 8]
    [(CompilerIncrementalTraceKey.Child _ _ _) 9]))

(define (compiler-trace-reason-valid? [code : i64]) : bool
  (and (>= code 1) (<= code 3)))

(define (compiler-trace-content-valid?
  [value : (& value CompilerIncrementalTraceContent)]
  [limits
    : (& limits compiler_incremental_identity.CompilerIncrementalIdentityLimits)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view value)
    [(CompilerIncrementalTraceContent.Present content)
      (compiler_incremental_identity.compiler-incremental-content-valid?
        (& content)
        limits)]
    [(CompilerIncrementalTraceContent.Absent code)
      (compiler-trace-reason-valid? code)]))

(define (compiler-trace-semantic-valid?
  [value : (& value CompilerIncrementalTraceSemantic)]
  [limits
    : (& limits compiler_incremental_identity.CompilerIncrementalIdentityLimits)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view value)
    [(CompilerIncrementalTraceSemantic.Present semantic)
      (and
        (compiler_incremental_identity.compiler-incremental-child-valid?
          (& semantic.identity)
          limits)
        (compiler_incremental_identity.compiler-incremental-string-eq?
          (& semantic.identity.domain)
          (&
            compiler_incremental_identity.compiler-incremental-semantic-output-domain)))]
    [(CompilerIncrementalTraceSemantic.Absent code)
      (compiler-trace-reason-valid? code)]))

(define (compiler-trace-artifact-valid?
  [value : (& value CompilerIncrementalTraceArtifact)]
  [limits
    : (& limits compiler_incremental_identity.CompilerIncrementalIdentityLimits)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view value)
    [(CompilerIncrementalTraceArtifact.Present child)
      (compiler_incremental_identity.compiler-incremental-child-valid?
        (& child)
        limits)]
    [(CompilerIncrementalTraceArtifact.Absent code)
      (compiler-trace-reason-valid? code)]))

(define (compiler-trace-edge-valid?
  [edge : (& edge CompilerIncrementalTraceEdge)]
  [parent
    : (& parent compiler_incremental_identity.CompilerIncrementalIdentity)]
  [limits : (& limits CompilerIncrementalTraceLimits)]) : i64
  (let
    [id-limits : compiler_incremental_identity.CompilerIncrementalIdentityLimits
      (compiler-trace-identity-limits limits)]
    (match (owned_view.compiler-owned-reference-shared-view (& edge.key))
      [(CompilerIncrementalTraceKey.Source path)
        (if (and
          (compiler_incremental_identity.compiler-incremental-path-valid?
            (& path)
            limits.max-edge-bytes)
          (match (owned_view.compiler-owned-reference-shared-view
            (& edge.observation))
            [(CompilerIncrementalTraceObservation.Source value)
              (and
                (compiler-trace-content-valid? (& value) (& id-limits))
                (match (owned_view.compiler-owned-reference-shared-view
                  (& value))
                  [(CompilerIncrementalTraceContent.Present content)
                    (compiler_incremental_identity.compiler-incremental-string-eq?
                      (& content.domain)
                      "typelisp.source-content")]
                  [_ true]))]
            [_ false]))
          0
          compiler-trace-error-edge)]
      [(CompilerIncrementalTraceKey.ImportSurface package module)
        (if (and
          (compiler_incremental_identity.compiler-incremental-text-valid?
            (& package)
            false
            limits.max-edge-bytes)
          (compiler_incremental_identity.compiler-incremental-text-valid?
            (& module)
            false
            limits.max-edge-bytes)
          (match (owned_view.compiler-owned-reference-shared-view
            (& edge.observation))
            [(CompilerIncrementalTraceObservation.ImportSurface value)
              (compiler-trace-semantic-valid? (& value) (& id-limits))]
            [_ false]))
          0
          compiler-trace-error-edge)]
      [(CompilerIncrementalTraceKey.ImportResolution package module)
        (if (and
          (compiler_incremental_identity.compiler-incremental-text-valid?
            (& package)
            false
            limits.max-edge-bytes)
          (compiler_incremental_identity.compiler-incremental-text-valid?
            (& module)
            false
            limits.max-edge-bytes)
          (match (owned_view.compiler-owned-reference-shared-view
            (& edge.observation))
            [(CompilerIncrementalTraceObservation.ImportResolution value)
              (compiler-trace-artifact-valid? (& value) (& id-limits))]
            [_ false]))
          0
          compiler-trace-error-edge)]
      [(CompilerIncrementalTraceKey.Configuration field)
        (if (and
          (compiler_incremental_identity.compiler-incremental-domain-valid?
            (& field)
            limits.max-edge-bytes)
          (match (owned_view.compiler-owned-reference-shared-view
            (& edge.observation))
            [(CompilerIncrementalTraceObservation.Configuration value)
              (compiler_incremental_identity.compiler-incremental-child-valid?
                (& value)
                (& id-limits))]
            [_ false]))
          0
          compiler-trace-error-edge)]
      [(CompilerIncrementalTraceKey.CompilerBuild)
        (match (owned_view.compiler-owned-reference-shared-view
          (& edge.observation))
          [(CompilerIncrementalTraceObservation.CompilerBuild value)
            (if (and
              (compiler_incremental_identity.compiler-incremental-child-valid?
                (& value)
                (& id-limits))
              (compiler_incremental_identity.compiler-incremental-string-eq?
                (& value.domain)
                (&
                  compiler_incremental_identity.compiler-incremental-build-domain)))
              0
              compiler-trace-error-edge)]
          [_ compiler-trace-error-edge])]
      [(CompilerIncrementalTraceKey.Stdlib distribution)
        (if (and
          (compiler_incremental_identity.compiler-incremental-text-valid?
            (& distribution)
            false
            limits.max-edge-bytes)
          (match (owned_view.compiler-owned-reference-shared-view
            (& edge.observation))
            [(CompilerIncrementalTraceObservation.Stdlib value)
              (and
                (compiler_incremental_identity.compiler-incremental-content-valid?
                  (& value)
                  (& id-limits))
                (compiler_incremental_identity.compiler-incremental-string-eq?
                  (& value.domain)
                  "typelisp.stdlib-content"))]
            [_ false]))
          0
          compiler-trace-error-edge)]
      [(CompilerIncrementalTraceKey.Package package version)
        (if (and
          (compiler_incremental_identity.compiler-incremental-text-valid?
            (& package)
            false
            limits.max-edge-bytes)
          (compiler_incremental_identity.compiler-incremental-text-valid?
            (& version)
            false
            limits.max-edge-bytes)
          (match (owned_view.compiler-owned-reference-shared-view
            (& edge.observation))
            [(CompilerIncrementalTraceObservation.Package value)
              (and
                (compiler_incremental_identity.compiler-incremental-content-valid?
                  (& value)
                  (& id-limits))
                (compiler_incremental_identity.compiler-incremental-string-eq?
                  (& value.domain)
                  "typelisp.package-content"))]
            [_ false]))
          0
          compiler-trace-error-edge)]
      [(CompilerIncrementalTraceKey.MacroComptime phase request)
        (if (and
          (compiler_incremental_identity.compiler-incremental-domain-valid?
            (& phase)
            limits.max-edge-bytes)
          (compiler_incremental_identity.compiler-incremental-child-valid?
            (& request)
            (& id-limits))
          (match (owned_view.compiler-owned-reference-shared-view
            (& edge.observation))
            [(CompilerIncrementalTraceObservation.MacroComptime value)
              (compiler-trace-semantic-valid? (& value) (& id-limits))]
            [_ false]))
          0
          compiler-trace-error-edge)]
      [(CompilerIncrementalTraceKey.Child sequence ordinal child)
        (cond
          [(or
              (not
                (compiler_incremental_identity.compiler-incremental-domain-valid?
                  (& sequence)
                  limits.max-edge-bytes))
              (< ordinal 0)
              (not (compiler-trace-parent-valid? (& child) limits)))
            compiler-trace-error-edge]
          [(binary.compiler-incremental-binary-bytes-eq?
              (& child.transcript)
              (& parent.transcript))
            compiler-trace-error-self]
          [(match (owned_view.compiler-owned-reference-shared-view
              (& edge.observation))
              [(CompilerIncrementalTraceObservation.Child value)
                (and
                  (compiler_incremental_identity.compiler-incremental-child-valid?
                    (& value.identity)
                    (& id-limits))
                  (compiler_incremental_identity.compiler-incremental-string-eq?
                    (& value.identity.domain)
                    (&
                      compiler_incremental_identity.compiler-incremental-semantic-output-domain)))]
              [_ false])
            0]
          [else compiler-trace-error-edge])])))

;; The full key bytes (not a host hash or digest) are the merge and ordering
;; authority. The observation is encoded independently, after the key exists.
(define (compiler-trace-encode-key [key : (& key CompilerIncrementalTraceKey)]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 128)]
    (begin
      (binary.compiler-incremental-binary-push-u8!
        (&mut out)
        (compiler-trace-key-tag key))
      (match (owned_view.compiler-owned-reference-shared-view key)
        [(CompilerIncrementalTraceKey.Source path)
          (binary.compiler-incremental-binary-push-string! (&mut out) (& path))]
        [(CompilerIncrementalTraceKey.ImportSurface package module)
          (begin
            (binary.compiler-incremental-binary-push-string!
              (&mut out)
              (& package))
            (binary.compiler-incremental-binary-push-string!
              (&mut out)
              (& module)))]
        [(CompilerIncrementalTraceKey.ImportResolution package module)
          (begin
            (binary.compiler-incremental-binary-push-string!
              (&mut out)
              (& package))
            (binary.compiler-incremental-binary-push-string!
              (&mut out)
              (& module)))]
        [(CompilerIncrementalTraceKey.Configuration field)
          (binary.compiler-incremental-binary-push-string! (&mut out) (& field))]
        [(CompilerIncrementalTraceKey.CompilerBuild) unit]
        [(CompilerIncrementalTraceKey.Stdlib distribution)
          (binary.compiler-incremental-binary-push-string!
            (&mut out)
            (& distribution))]
        [(CompilerIncrementalTraceKey.Package package version)
          (begin
            (binary.compiler-incremental-binary-push-string!
              (&mut out)
              (& package))
            (binary.compiler-incremental-binary-push-string!
              (&mut out)
              (& version)))]
        [(CompilerIncrementalTraceKey.MacroComptime phase request)
          (begin
            (binary.compiler-incremental-binary-push-string!
              (&mut out)
              (& phase))
            (compiler_incremental_identity.compiler-incremental-push-child!
              (&mut out)
              (& request)))]
        [(CompilerIncrementalTraceKey.Child sequence ordinal child)
          (begin
            (binary.compiler-incremental-binary-push-string!
              (&mut out)
              (& sequence))
            (binary.compiler-incremental-binary-push-u64! (&mut out) ordinal)
            (binary.compiler-incremental-binary-push-u32!
              (&mut out)
              (array-length child.transcript))
            (binary.compiler-incremental-binary-push-array!
              (&mut out)
              (& child.transcript)))])
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

;; Planners can name an observation before its result has been computed. A
;; nominal key keeps this complete logical identity distinct from a store hash.
(define (compiler-trace-logical-key
  [key : (& key CompilerIncrementalTraceKey)]
  [parent
    : (& parent compiler_incremental_identity.CompilerIncrementalIdentity)]
  [limits : (& limits CompilerIncrementalTraceLimits)]) : ResultCompilerIncrementalTraceLogicalKey
  (if (or
    (not (compiler-trace-limits-valid? limits))
    (not (compiler-trace-parent-valid? parent limits)))
    (ResultCompilerIncrementalTraceLogicalKey.Err
      (compiler-trace-error
        compiler-trace-error-parent
        "invalid trace parent or limits"))
    (let
      [valid : bool
        (match (owned_view.compiler-owned-reference-shared-view key)
          [(CompilerIncrementalTraceKey.Source path)
            (compiler_incremental_identity.compiler-incremental-path-valid?
              (& path)
              limits.max-edge-bytes)]
          [(CompilerIncrementalTraceKey.ImportSurface package module)
            (and
              (compiler_incremental_identity.compiler-incremental-text-valid?
                (& package)
                false
                limits.max-edge-bytes)
              (compiler_incremental_identity.compiler-incremental-text-valid?
                (& module)
                false
                limits.max-edge-bytes))]
          [(CompilerIncrementalTraceKey.ImportResolution package module)
            (and
              (compiler_incremental_identity.compiler-incremental-text-valid?
                (& package)
                false
                limits.max-edge-bytes)
              (compiler_incremental_identity.compiler-incremental-text-valid?
                (& module)
                false
                limits.max-edge-bytes))]
          [(CompilerIncrementalTraceKey.Configuration field)
            (compiler_incremental_identity.compiler-incremental-domain-valid?
              (& field)
              limits.max-edge-bytes)]
          [(CompilerIncrementalTraceKey.CompilerBuild) true]
          [(CompilerIncrementalTraceKey.Stdlib distribution)
            (compiler_incremental_identity.compiler-incremental-text-valid?
              (& distribution)
              false
              limits.max-edge-bytes)]
          [(CompilerIncrementalTraceKey.Package package version)
            (and
              (compiler_incremental_identity.compiler-incremental-text-valid?
                (& package)
                false
                limits.max-edge-bytes)
              (compiler_incremental_identity.compiler-incremental-text-valid?
                (& version)
                false
                limits.max-edge-bytes))]
          [(CompilerIncrementalTraceKey.MacroComptime phase request)
            (let
              [id-limits : compiler_incremental_identity.CompilerIncrementalIdentityLimits
                (compiler-trace-identity-limits limits)]
              (and
                (compiler_incremental_identity.compiler-incremental-domain-valid?
                  (& phase)
                  limits.max-edge-bytes)
                (compiler_incremental_identity.compiler-incremental-child-valid?
                  (& request)
                  (& id-limits))))]
          [(CompilerIncrementalTraceKey.Child sequence ordinal child)
            (and
              (compiler_incremental_identity.compiler-incremental-domain-valid?
                (& sequence)
                limits.max-edge-bytes)
              (>= ordinal 0)
              (compiler-trace-parent-valid? (& child) limits)
              (not
                (binary.compiler-incremental-binary-bytes-eq?
                  (& child.transcript)
                  (& parent.transcript))))])]
      (if (not valid)
        (ResultCompilerIncrementalTraceLogicalKey.Err
          (compiler-trace-error
            compiler-trace-error-edge
            "invalid trace logical key"))
        (let
          [bytes : String (compiler-trace-encode-key key)]
          (if (> (string.string-length bytes) limits.max-edge-bytes)
            (ResultCompilerIncrementalTraceLogicalKey.Err
              (compiler-trace-error
                compiler-trace-error-limit
                "trace logical key is too large"))
            (ResultCompilerIncrementalTraceLogicalKey.Ok
              (CompilerIncrementalTraceLogicalKey
                (compiler-trace-key-tag key)
                bytes))))))))

(define (compiler-trace-push-content!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : (& value CompilerIncrementalTraceContent)]) : unit
  (match (owned_view.compiler-owned-reference-shared-view value)
    [(CompilerIncrementalTraceContent.Present content)
      (begin
        (binary.compiler-incremental-binary-push-u8! out 1)
        (compiler_incremental_identity.compiler-incremental-push-content!
          out
          (& content)))]
    [(CompilerIncrementalTraceContent.Absent reason)
      (begin
        (binary.compiler-incremental-binary-push-u8! out 2)
        (binary.compiler-incremental-binary-push-u8! out reason))]))

(define (compiler-trace-push-semantic!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : (& value CompilerIncrementalTraceSemantic)]) : unit
  (match (owned_view.compiler-owned-reference-shared-view value)
    [(CompilerIncrementalTraceSemantic.Present semantic)
      (begin
        (binary.compiler-incremental-binary-push-u8! out 1)
        (compiler_incremental_identity.compiler-incremental-push-child!
          out
          (& semantic.identity)))]
    [(CompilerIncrementalTraceSemantic.Absent reason)
      (begin
        (binary.compiler-incremental-binary-push-u8! out 2)
        (binary.compiler-incremental-binary-push-u8! out reason))]))

(define (compiler-trace-push-artifact!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : (& value CompilerIncrementalTraceArtifact)]) : unit
  (match (owned_view.compiler-owned-reference-shared-view value)
    [(CompilerIncrementalTraceArtifact.Present child)
      (begin
        (binary.compiler-incremental-binary-push-u8! out 1)
        (compiler_incremental_identity.compiler-incremental-push-child!
          out
          (& child)))]
    [(CompilerIncrementalTraceArtifact.Absent reason)
      (begin
        (binary.compiler-incremental-binary-push-u8! out 2)
        (binary.compiler-incremental-binary-push-u8! out reason))]))

(define (compiler-trace-encode-observation
  [value : (& value CompilerIncrementalTraceObservation)]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 128)]
    (begin
      (match (owned_view.compiler-owned-reference-shared-view value)
        [(CompilerIncrementalTraceObservation.Source content)
          (compiler-trace-push-content! (&mut out) (& content))]
        [(CompilerIncrementalTraceObservation.ImportSurface semantic)
          (compiler-trace-push-semantic! (&mut out) (& semantic))]
        [(CompilerIncrementalTraceObservation.ImportResolution artifact)
          (compiler-trace-push-artifact! (&mut out) (& artifact))]
        [(CompilerIncrementalTraceObservation.Configuration child)
          (compiler_incremental_identity.compiler-incremental-push-child!
            (&mut out)
            (& child))]
        [(CompilerIncrementalTraceObservation.CompilerBuild child)
          (compiler_incremental_identity.compiler-incremental-push-child!
            (&mut out)
            (& child))]
        [(CompilerIncrementalTraceObservation.Stdlib content)
          (compiler_incremental_identity.compiler-incremental-push-content!
            (&mut out)
            (& content))]
        [(CompilerIncrementalTraceObservation.Package content)
          (compiler_incremental_identity.compiler-incremental-push-content!
            (&mut out)
            (& content))]
        [(CompilerIncrementalTraceObservation.MacroComptime semantic)
          (compiler-trace-push-semantic! (&mut out) (& semantic))]
        [(CompilerIncrementalTraceObservation.Child semantic)
          (compiler_incremental_identity.compiler-incremental-push-child!
            (&mut out)
            (& semantic.identity))])
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

(define (compiler-trace-record-less?
  [left : CompilerIncrementalTraceRecord]
  [right : CompilerIncrementalTraceRecord]) : bool
  (stdlib.sort.string-less-borrowed? (& left.key) (& right.key)))

(define (compiler-trace-record
  [edge : (& edge CompilerIncrementalTraceEdge)]
  [parent
    : (& parent compiler_incremental_identity.CompilerIncrementalIdentity)]
  [limits : (& limits CompilerIncrementalTraceLimits)]) : ResultCompilerIncrementalTraceRecord
  (let
    [valid : i64 (compiler-trace-edge-valid? edge parent limits)]
    (if (= valid 0)
      (let
        [key : String (compiler-trace-encode-key (& edge.key))]
        [observation : String
          (compiler-trace-encode-observation (& edge.observation))]
        (if (or
          (> (string.string-length key) limits.max-edge-bytes)
          (> (string.string-length observation) limits.max-edge-bytes)
          (>
            (string.string-length observation)
            (- limits.max-edge-bytes (string.string-length key))))
          (ResultCompilerIncrementalTraceRecord.Err
            (compiler-trace-error
              compiler-trace-error-limit
              "trace edge exceeds byte limit"))
          (ResultCompilerIncrementalTraceRecord.Ok
            (CompilerIncrementalTraceRecord
              key
              observation
              (compiler-trace-key-tag (& edge.key))))))
      (ResultCompilerIncrementalTraceRecord.Err
        (compiler-trace-error
          valid
          (if (= valid compiler-trace-error-self)
            "trace cannot depend directly on its parent query"
            "trace edge is invalid"))))))

;; Checked and domain/version-separated canonical trace. This builder is
;; consumed; an error path cannot return the partially encoded transcript.
(define (compiler-trace-finalize [builder : CompilerIncrementalTraceBuilder]) : ResultCompilerIncrementalTrace
  (if (not (= builder.state 1))
    (ResultCompilerIncrementalTrace.Err
      (compiler-trace-error
        compiler-trace-error-state
        "trace transaction is not open"))
    (let
      [records : trace_record_vec.Vec
        (trace_record_vec.with-capacity
          (trace_record_vec.len (& builder.edges)))]
      [index : i64 0]
      [planned : i64
        (compiler_incremental_identity.compiler-incremental-add-size
          16
          (compiler_incremental_identity.compiler-incremental-add-size
            (string.string-length compiler-incremental-trace-domain)
            (array-length builder.parent.transcript)))]
      [work : i64 0]
      [sort-bytes : i64 0]
      [sort-level : i64 (trace_record_vec.len (& builder.edges))]
      (begin
        (while (< index (trace_record_vec.len (& builder.edges)))
          (let
            [record : CompilerIncrementalTraceRecord
              (owned_view.compiler-owned-array-element-shared-view
                builder.edges.slots
                index)]
            (begin
              (set!
                planned
                (compiler_incremental_identity.compiler-incremental-add-size
                  planned
                  (compiler_incremental_identity.compiler-incremental-add-size
                    8
                    (compiler_incremental_identity.compiler-incremental-add-size
                      (string.string-length record.key)
                      (string.string-length record.observation)))))
              (set!
                work
                (compiler_incremental_identity.compiler-incremental-add-size
                  work
                  (compiler_incremental_identity.compiler-incremental-add-size
                    (string.string-length record.key)
                    (string.string-length record.observation))))
              (when
                (or
                  (< planned 0)
                  (> planned builder.limits.max-bytes)
                  (< work 0)
                  (> work builder.limits.max-work))
                (return
                  (ResultCompilerIncrementalTrace.Err
                    (compiler-trace-error
                      compiler-trace-error-limit
                      "trace byte or work limit exceeded"))))
              (trace_record_vec.push-ref! (&mut records) record)
              (set! index (+ index 1)))))
        (set! sort-bytes work)
        (while (> sort-level 1)
          (begin
            (set!
              work
              (compiler_incremental_identity.compiler-incremental-add-size
                work
                (compiler_incremental_identity.compiler-incremental-add-size
                  sort-bytes
                  sort-bytes)))
            (when
              (or (< work 0) (> work builder.limits.max-work))
              (return
                (ResultCompilerIncrementalTrace.Err
                  (compiler-trace-error
                    compiler-trace-error-limit
                    "trace sorting work limit exceeded"))))
            (set!
              sort-level
              (+ (/ sort-level 2) (- sort-level (* (/ sort-level 2) 2))))))
        (trace_record_sort.sort! (&mut records) compiler-trace-record-less?)
        (let
          [out : byte_buf_core.ByteBufBuilder
            (byte_buf_core.byte-buf-builder-with-capacity planned)]
          [last : String ""]
          [last-value : String ""]
          [count : i64 0]
          (begin
            (set! index 0)
            (while (< index (trace_record_vec.len (& records)))
              (let
                [record : CompilerIncrementalTraceRecord
                  (owned_view.compiler-owned-array-element-shared-view
                    records.slots
                    index)]
                (begin
                  (if (and
                    (> index 0)
                    (compiler_incremental_identity.compiler-incremental-string-eq?
                      (& record.key)
                      (& last)))
                    (unless
                      (compiler_incremental_identity.compiler-incremental-string-eq?
                        (& record.observation)
                        (& last-value))
                      (return
                        (ResultCompilerIncrementalTrace.Err
                          (compiler-trace-error
                            compiler-trace-error-conflict
                            "inconsistent observations for a trace key"))))
                    (set! count (+ count 1)))
                  (set! last record.key)
                  (set! last-value record.observation)
                  (set! index (+ index 1)))))
            (binary.compiler-incremental-binary-push-string!
              (&mut out)
              (& compiler-incremental-trace-domain))
            (binary.compiler-incremental-binary-push-u32!
              (&mut out)
              compiler-incremental-trace-schema)
            (binary.compiler-incremental-binary-push-u32!
              (&mut out)
              (array-length builder.parent.transcript))
            (binary.compiler-incremental-binary-push-array!
              (&mut out)
              (& builder.parent.transcript))
            (binary.compiler-incremental-binary-push-u32! (&mut out) count)
            (set! index 0)
            (set! last "")
            (while (< index (trace_record_vec.len (& records)))
              (let
                [record : CompilerIncrementalTraceRecord
                  (owned_view.compiler-owned-array-element-shared-view
                    records.slots
                    index)]
                (begin
                  (if (and
                    (> index 0)
                    (compiler_incremental_identity.compiler-incremental-string-eq?
                      (& record.key)
                      (& last)))
                    unit
                    (begin
                      (binary.compiler-incremental-binary-push-string!
                        (&mut out)
                        (& record.key))
                      (binary.compiler-incremental-binary-push-string!
                        (&mut out)
                        (& record.observation))))
                  (set! last record.key)
                  (set! index (+ index 1)))))
            (let
              [bytes : (__tl_dyn-array u8)
                (byte_buf_core.byte-buf-builder-finish-array (& out))]
              (match (compiler_incremental_identity.compiler-incremental-digest-array
                (& bytes))
                [(sha256.Sha256FinalizeErr _)
                  (ResultCompilerIncrementalTrace.Err
                    (compiler-trace-error
                      compiler-trace-error-corrupt
                      "trace fingerprint generation failed"))]
                [(sha256.Sha256FinalizeOk digest)
                  (ResultCompilerIncrementalTrace.Ok
                    (CompilerIncrementalTrace
                      compiler-incremental-trace-schema
                      builder.parent
                      count
                      bytes
                      digest))]))))))))

;; Strings here are byte containers: key and observation frames are not UTF-8
;; strings. Only their individual logical-name fields must be canonical text.
(define (compiler-trace-read-raw!
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]
  [ceiling : i64]) : String
  (let
    [length : i64 (binary.compiler-incremental-binary-read-u32! reader)]
    (if (or
      (not reader.ok?)
      (> length ceiling)
      (not
        (binary.compiler-incremental-binary-range-present?
          reader.end
          reader.offset
          length))
      (> length (- reader.max-owned-bytes reader.owned-bytes)))
      (begin
        (binary.compiler-incremental-binary-fail!
          reader
          7
          reader.offset
          "invalid bounded trace frame")
        "")
      (let
        [out : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-with-capacity length)]
        [index : i64 0]
        (begin
          (while (< index length)
            (begin
              (byte_buf_core.byte-buf-builder-push
                (&mut out)
                (cast (binary.compiler-incremental-binary-read-u8! reader) : u8))
              (set! index (+ index 1))))
          (set! reader.owned-bytes (+ reader.owned-bytes length))
          (byte_buf_core.byte-buf-builder-finish-string (& out)))))))

(define (compiler-trace-raw-bytes [raw : (& raw str)]) : (__tl_dyn-array u8)
  (let
    [length : i64 (string.string-length raw)]
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (set!
            (array-ref bytes index)
            (cast (string.string-ref raw index) : u8))
          (set! index (+ index 1))))
      bytes)))

(define (compiler-trace-record-parse-valid?
  [record : (& record CompilerIncrementalTraceRecord)]
  [parent
    : (& parent compiler_incremental_identity.CompilerIncrementalIdentity)]
  [limits : (& limits CompilerIncrementalTraceLimits)]) : bool
  (let
    [key-bytes : (__tl_dyn-array u8) (compiler-trace-raw-bytes (& record.key))]
    [value-bytes : (__tl_dyn-array u8)
      (compiler-trace-raw-bytes (& record.observation))]
    [key-reader : binary.CompilerIncrementalBinaryReader
      (binary.compiler-incremental-binary-reader
        (& key-bytes)
        limits.max-work
        limits.max-owned-bytes
        limits.max-edge-bytes)]
    [value-reader : binary.CompilerIncrementalBinaryReader
      (binary.compiler-incremental-binary-reader
        (& value-bytes)
        limits.max-work
        limits.max-owned-bytes
        limits.max-edge-bytes)]
    [id-limits : compiler_incremental_identity.CompilerIncrementalIdentityLimits
      (compiler-trace-identity-limits limits)]
    [tag : i64 (binary.compiler-incremental-binary-read-u8! (&mut key-reader))]
    [key-ok? : bool false]
    [value-ok? : bool false]
    (begin
      (set!
        key-ok?
        (cond
          [(= tag 1)
            (let
              [path : String
                (binary.compiler-incremental-binary-read-string!
                  (&mut key-reader)
                  true)]
              (compiler_incremental_identity.compiler-incremental-path-valid?
                (& path)
                limits.max-edge-bytes))]
          [(or (= tag 2) (= tag 3) (= tag 7))
            (let
              [first : String
                (binary.compiler-incremental-binary-read-string!
                  (&mut key-reader)
                  false)]
              [second : String
                (binary.compiler-incremental-binary-read-string!
                  (&mut key-reader)
                  false)]
              (and
                (compiler_incremental_identity.compiler-incremental-text-valid?
                  (& first)
                  false
                  limits.max-edge-bytes)
                (compiler_incremental_identity.compiler-incremental-text-valid?
                  (& second)
                  false
                  limits.max-edge-bytes)))]
          [(= tag 4)
            (let
              [field : String
                (binary.compiler-incremental-binary-read-string!
                  (&mut key-reader)
                  false)]
              (compiler_incremental_identity.compiler-incremental-domain-valid?
                (& field)
                limits.max-edge-bytes))]
          [(= tag 5) true]
          [(= tag 6)
            (let
              [distribution : String
                (binary.compiler-incremental-binary-read-string!
                  (&mut key-reader)
                  false)]
              (compiler_incremental_identity.compiler-incremental-text-valid?
                (& distribution)
                false
                limits.max-edge-bytes))]
          [(= tag 8)
            (let
              [phase : String
                (binary.compiler-incremental-binary-read-string!
                  (&mut key-reader)
                  false)]
              [_request : compiler_incremental_identity.CompilerIncrementalChildIdentity
                (compiler_incremental_identity.compiler-incremental-read-child!
                  (&mut key-reader)
                  (& id-limits))]
              (compiler_incremental_identity.compiler-incremental-domain-valid?
                (& phase)
                limits.max-edge-bytes))]
          [(= tag 9)
            (let
              [sequence : String
                (binary.compiler-incremental-binary-read-string!
                  (&mut key-reader)
                  false)]
              [ordinal : i64
                (binary.compiler-incremental-binary-read-u64! (&mut key-reader))]
              [child-raw : String
                (compiler-trace-read-raw!
                  (&mut key-reader)
                  limits.max-edge-bytes)]
              [child-bytes : (__tl_dyn-array u8)
                (compiler-trace-raw-bytes (& child-raw))]
              (and
                (compiler_incremental_identity.compiler-incremental-domain-valid?
                  (& sequence)
                  limits.max-edge-bytes)
                (>= ordinal 0)
                (not
                  (binary.compiler-incremental-binary-bytes-eq?
                    (& child-bytes)
                    (& parent.transcript)))
                (match (compiler_incremental_identity.compiler-incremental-identity-decode
                  (& child-bytes)
                  (& id-limits))
                  [(compiler_incremental_identity.ResultCompilerIncrementalDecodedQuery.Ok
                      _)
                    true]
                  [_ false])))]
          [else false]))
      (set!
        value-ok?
        (cond
          [(or (= tag 1) (= tag 2) (= tag 3) (= tag 8))
            (let
              [present : i64
                (binary.compiler-incremental-binary-read-u8!
                  (&mut value-reader))]
              (cond
                [(= present 2)
                  (compiler-trace-reason-valid?
                    (binary.compiler-incremental-binary-read-u8!
                      (&mut value-reader)))]
                [(= present 1)
                  (cond
                    [(= tag 1)
                      (let
                        [content : compiler_incremental_identity.CompilerIncrementalContentIdentity
                          (compiler_incremental_identity.compiler-incremental-read-content!
                            (&mut value-reader)
                            (& id-limits))]
                        (compiler_incremental_identity.compiler-incremental-string-eq?
                          (& content.domain)
                          "typelisp.source-content"))]
                    [else
                      (let
                        [child : compiler_incremental_identity.CompilerIncrementalChildIdentity
                          (compiler_incremental_identity.compiler-incremental-read-child!
                            (&mut value-reader)
                            (& id-limits))]
                        (if (or (= tag 2) (= tag 8))
                          (compiler_incremental_identity.compiler-incremental-string-eq?
                            (& child.domain)
                            (&
                              compiler_incremental_identity.compiler-incremental-semantic-output-domain))
                          true))])]
                [else false]))]
          [(or (= tag 4) (= tag 5) (= tag 9))
            (let
              [child : compiler_incremental_identity.CompilerIncrementalChildIdentity
                (compiler_incremental_identity.compiler-incremental-read-child!
                  (&mut value-reader)
                  (& id-limits))]
              (cond
                [(= tag 5)
                  (compiler_incremental_identity.compiler-incremental-string-eq?
                    (& child.domain)
                    (&
                      compiler_incremental_identity.compiler-incremental-build-domain))]
                [(= tag 9)
                  (compiler_incremental_identity.compiler-incremental-string-eq?
                    (& child.domain)
                    (&
                      compiler_incremental_identity.compiler-incremental-semantic-output-domain))]
                [else true]))]
          [(or (= tag 6) (= tag 7))
            (let
              [content : compiler_incremental_identity.CompilerIncrementalContentIdentity
                (compiler_incremental_identity.compiler-incremental-read-content!
                  (&mut value-reader)
                  (& id-limits))]
              (compiler_incremental_identity.compiler-incremental-string-eq?
                (& content.domain)
                (if (= tag 6)
                  "typelisp.stdlib-content"
                  "typelisp.package-content")))]
          [else false]))
      (and
        key-reader.ok?
        value-reader.ok?
        key-ok?
        value-ok?
        (= record.kind tag)
        (= key-reader.offset key-reader.end)
        (= value-reader.offset value-reader.end)))))

;; All published traces are revalidated before comparison. Hashes detect
;; corruption, while the strict frame parser also rejects a correctly hashed
;; but noncanonical transcript.
(define (compiler-trace-decode
  [trace : (& trace CompilerIncrementalTrace)]
  [limits : (& limits CompilerIncrementalTraceLimits)]) : ResultCompilerIncrementalTraceRecords
  (cond
    [(not (compiler-trace-limits-valid? limits))
      (ResultCompilerIncrementalTraceRecords.Err
        (compiler-trace-error compiler-trace-error-limit "invalid trace limits"))]
    [(> (array-length trace.transcript) limits.max-bytes)
      (ResultCompilerIncrementalTraceRecords.Err
        (compiler-trace-error
          compiler-trace-error-limit
          "trace exceeds byte limit"))]
    [(or
        (not (compiler-trace-parent-valid? (& trace.parent) limits))
        (not
          (match (compiler_incremental_identity.compiler-incremental-digest-array
            (& trace.transcript))
            [(sha256.Sha256FinalizeOk digest)
              (sha256.digest-eq? (& digest) (& trace.fingerprint))]
            [_ false])))
      (ResultCompilerIncrementalTraceRecords.Err
        (compiler-trace-error
          compiler-trace-error-corrupt
          "invalid trace fingerprint or parent"))]
    [else
      (let
        [reader : binary.CompilerIncrementalBinaryReader
          (binary.compiler-incremental-binary-reader
            (& trace.transcript)
            limits.max-work
            limits.max-owned-bytes
            limits.max-edge-bytes)]
        [domain : String
          (binary.compiler-incremental-binary-read-string! (&mut reader) false)]
        [schema : i64
          (binary.compiler-incremental-binary-read-u32! (&mut reader))]
        [parent-raw : String
          (compiler-trace-read-raw! (&mut reader) limits.max-edge-bytes)]
        [parent-bytes : (__tl_dyn-array u8)
          (compiler-trace-raw-bytes (& parent-raw))]
        [count : i64
          (binary.compiler-incremental-binary-read-u32! (&mut reader))]
        [records : trace_record_vec.Vec (trace_record_vec.with-capacity 0)]
        [index : i64 0]
        [last-key : String ""]
        (begin
          (when
            (or
              (not reader.ok?)
              (not
                (compiler_incremental_identity.compiler-incremental-string-eq?
                  (& domain)
                  (& compiler-incremental-trace-domain)))
              (!= schema compiler-incremental-trace-schema)
              (!= trace.schema schema))
            (return
              (ResultCompilerIncrementalTraceRecords.Err
                (compiler-trace-error
                  compiler-trace-error-schema
                  "unsupported trace schema or domain"))))
          (when
            (or
              (not
                (binary.compiler-incremental-binary-bytes-eq?
                  (& parent-bytes)
                  (& trace.parent.transcript)))
              (!= count trace.edge-count)
              (> count (- reader.end reader.offset)))
            (return
              (ResultCompilerIncrementalTraceRecords.Err
                (compiler-trace-error
                  compiler-trace-error-corrupt
                  "invalid trace header"))))
          (when
            (> count limits.max-edges)
            (return
              (ResultCompilerIncrementalTraceRecords.Err
                (compiler-trace-error
                  compiler-trace-error-limit
                  "trace edge count exceeds limit"))))
          (while (< index count)
            (let
              [key : String
                (compiler-trace-read-raw! (&mut reader) limits.max-edge-bytes)]
              [observation : String
                (compiler-trace-read-raw! (&mut reader) limits.max-edge-bytes)]
              [kind : i64
                (if (> (string.string-length key) 0)
                  (cast (string.string-ref (& key) 0) : i64)
                  0)]
              [record : CompilerIncrementalTraceRecord
                (CompilerIncrementalTraceRecord key observation kind)]
              (begin
                (when
                  (or
                    (not reader.ok?)
                    (= (string.string-length record.key) 0)
                    (>
                      (string.string-length record.observation)
                      (-
                        limits.max-edge-bytes
                        (string.string-length record.key)))
                    (not
                      (compiler-trace-record-parse-valid?
                        (& record)
                        (& trace.parent)
                        limits))
                    (and
                      (> index 0)
                      (not
                        (stdlib.sort.string-less-borrowed?
                          (& last-key)
                          (& record.key)))))
                  (return
                    (ResultCompilerIncrementalTraceRecords.Err
                      (compiler-trace-error
                        compiler-trace-error-corrupt
                        "invalid trace record"))))
                (set! last-key (string.copy (& record.key)))
                (trace_record_vec.push-ref! (&mut records) record)
                (set! index (+ index 1)))))
          (if (or (not reader.ok?) (!= reader.offset reader.end))
            (ResultCompilerIncrementalTraceRecords.Err
              (compiler-trace-error
                compiler-trace-error-corrupt
                "trailing or truncated trace"))
            (ResultCompilerIncrementalTraceRecords.Ok records))))]))

(define (compiler-trace-kind-miss [kind : i64]) : i64
  (cond
    [(= kind 1) compiler-trace-miss-source]
    [(or (= kind 2) (= kind 3)) compiler-trace-miss-import]
    [(= kind 4) compiler-trace-miss-config]
    [(= kind 5) compiler-trace-miss-compiler]
    [(= kind 6) compiler-trace-miss-stdlib]
    [(= kind 7) compiler-trace-miss-package]
    [(= kind 8) compiler-trace-miss-macro]
    [else compiler-trace-miss-child]))

(define (compiler-trace-invalid-result [error : CompilerIncrementalTraceError]) : CompilerIncrementalTraceCompare
  (cond
    [(= error.code compiler-trace-error-schema)
      (CompilerIncrementalTraceCompare.Miss compiler-trace-miss-schema -1)]
    [(= error.code compiler-trace-error-limit)
      (CompilerIncrementalTraceCompare.Miss compiler-trace-miss-limit -1)]
    [else (CompilerIncrementalTraceCompare.Corrupt error)]))

(define (compiler-trace-compare
  [left : (& left CompilerIncrementalTrace)]
  [right : (& right CompilerIncrementalTrace)]
  [limits : (& limits CompilerIncrementalTraceLimits)]) : CompilerIncrementalTraceCompare
  (match (compiler-trace-decode left limits)
    [(ResultCompilerIncrementalTraceRecords.Err error)
      (compiler-trace-invalid-result error)]
    [(ResultCompilerIncrementalTraceRecords.Ok left-records)
      (match (compiler-trace-decode right limits)
        [(ResultCompilerIncrementalTraceRecords.Err error)
          (compiler-trace-invalid-result error)]
        [(ResultCompilerIncrementalTraceRecords.Ok right-records)
          (if (not
            (binary.compiler-incremental-binary-bytes-eq?
              (& left.parent.transcript)
              (& right.parent.transcript)))
            (CompilerIncrementalTraceCompare.Miss
              compiler-trace-miss-query-kind
              -1)
            (let
              [index : i64 0]
              [left-count : i64 (trace_record_vec.len (& left-records))]
              [right-count : i64 (trace_record_vec.len (& right-records))]
              (begin
                (while (and (< index left-count) (< index right-count))
                  (let
                    [a : CompilerIncrementalTraceRecord
                      (owned_view.compiler-owned-array-element-shared-view
                        left-records.slots
                        index)]
                    [b : CompilerIncrementalTraceRecord
                      (owned_view.compiler-owned-array-element-shared-view
                        right-records.slots
                        index)]
                    (begin
                      (when
                        (or
                          (not
                            (compiler_incremental_identity.compiler-incremental-string-eq?
                              (& a.key)
                              (& b.key)))
                          (not
                            (compiler_incremental_identity.compiler-incremental-string-eq?
                              (& a.observation)
                              (& b.observation))))
                        (return
                          (CompilerIncrementalTraceCompare.Miss
                            (compiler-trace-kind-miss
                              (if (stdlib.sort.string-less-borrowed?
                                (& b.key)
                                (& a.key))
                                b.kind
                                a.kind))
                            index)))
                      (set! index (+ index 1)))))
                (if (!= left-count right-count)
                  (let
                    [record : CompilerIncrementalTraceRecord
                      (if (< index left-count)
                        (owned_view.compiler-owned-array-element-shared-view
                          left-records.slots
                          index)
                        (owned_view.compiler-owned-array-element-shared-view
                          right-records.slots
                          index))]
                    (CompilerIncrementalTraceCompare.Miss
                      (compiler-trace-kind-miss record.kind)
                      index))
                  (CompilerIncrementalTraceCompare.Hit)))))])]))