;; compiler_incremental_identity.tl - canonical incremental-query identities.
;;
;; This module is deliberately pure.  Callers capture compiler events, prove
;; filesystem authority, serialize results, and operate the cache.  Here they
;; provide typed inputs and receive one portable, versioned transcript plus its
;; exact SHA-256 fingerprint.  No cwd, arena address, intern id, temporary path,
;; scheduler order, or observation-only flag is admitted by this schema.
(import compiler_incremental_binary as binary)
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf)
(import stdlib.byte_buf_core)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.string)

(define compiler-incremental-identity-schema : i64
  1)
(define compiler-incremental-identity-domain : String
  "typelisp.compiler.incremental.query")
(define compiler-incremental-build-domain : String
  "typelisp.compiler-build")
(define compiler-incremental-semantic-output-domain : String
  "typelisp.semantic-output")

;; Stable error categories; callers compare these instead of diagnostic prose.
(define compiler-incremental-error-invalid-limits : i64
  1)
(define compiler-incremental-error-input-limit : i64
  2)
(define compiler-incremental-error-truncated : i64
  3)
(define compiler-incremental-error-schema : i64
  4)
(define compiler-incremental-error-unknown-tag : i64
  5)
(define compiler-incremental-error-record-limit : i64
  6)
(define compiler-incremental-error-string-limit : i64
  7)
(define compiler-incremental-error-owned-limit : i64
  8)
(define compiler-incremental-error-work-limit : i64
  9)
(define compiler-incremental-error-layout : i64
  10)
(define compiler-incremental-error-utf8 : i64
  11)
(define compiler-incremental-error-path : i64
  12)
(define compiler-incremental-error-order : i64
  13)
(define compiler-incremental-error-trailing : i64
  14)
(define compiler-incremental-error-value : i64
  15)
(define compiler-incremental-error-fingerprint : i64
  16)
(define compiler-incremental-error-build-unavailable : i64
  17)
(define compiler-incremental-error-depth-limit : i64
  18)

;; Stable miss categories.  A collision is a miss, never a cache hit.
(define compiler-incremental-miss-query-kind : i64
  1)
(define compiler-incremental-miss-compiler-build : i64
  2)
(define compiler-incremental-miss-record-count : i64
  3)
(define compiler-incremental-miss-input-kind : i64
  4)
(define compiler-incremental-miss-input-value : i64
  5)
(define compiler-incremental-miss-fingerprint-collision : i64
  6)

(defstruct CompilerIncrementalIdentityLimits
  (max-transcript-bytes i64)
  (max-records i64)
  (max-record-bytes i64)
  (max-string-bytes i64)
  (max-nesting-depth i64)
  (max-owned-bytes i64)
  (max-work i64))

(define (compiler-incremental-identity-default-limits) : CompilerIncrementalIdentityLimits
  (CompilerIncrementalIdentityLimits
    16777216
    65536
    1048576
    1048576
    8
    134217728
    134217728))

(defstruct CompilerIncrementalIdentityError
  (code i64)
  (byte-offset i64)
  (message String))

;; Observation flags are intentionally absent.  Assembly, object, IR summary,
;; and pass-specific IR dump identities are distinct semantic products.
(defenum CompilerIncrementalQueryKind
  (Parse)
  (Typecheck)
  (Lower)
  (Optimize)
  (Assembly)
  (Object)
  (IrSummary)
  (IrDump String))

;; Every composite child carries a nominal domain, its own schema, the exact
;; canonical material length used by its producer, and a fixed SHA-256 digest.
(defstruct CompilerIncrementalChildIdentity
  (domain String)
  (schema i64)
  (material-length i64)
  (fingerprint sha256.Sha256Digest))

;; A compiler build is either a properly domain-separated identity or explicitly
;; unavailable.  Encoding the latter fails closed; a bare Git hash is not a
;; substitute for the build recipe owned by #7545.
(defenum CompilerIncrementalBuildIdentity
  (Available CompilerIncrementalChildIdentity)
  (Unavailable String))

;; Kept nominally distinct from an opaque cache-store key.  Consumers such as
;; #7322 can refer to the semantic output while #7023 chooses its own storage key.
(defstruct CompilerIncrementalSemanticOutputIdentity
  (identity CompilerIncrementalChildIdentity))

;; Content digests hash `frame(domain) + u32(schema) + u64(exact-length) +
;; exact-bytes`.
(defstruct CompilerIncrementalContentIdentity
  (domain String)
  (schema i64)
  (exact-length i64)
  (fingerprint sha256.Sha256Digest))

(defstruct CompilerIncrementalConfigField
  (name String)
  (value String))

;; This synthetic resolved record makes known material dimensions explicit
;; without pretending to freeze the compiler's still-distributed CLI/config
;; precedence.  Newly material options can be carried as canonical extensions.
(defstruct CompilerIncrementalConfiguration
  (target String)
  (profile String)
  (backend String)
  (opt-level i64)
  (debug? bool)
  (path-remap String)
  (generated-source-policy String)
  (extensions (__tl_dyn-array CompilerIncrementalConfigField)))

(defenum CompilerIncrementalInput
  (SourceContent String CompilerIncrementalContentIdentity)
  (LogicalName String String)
  (ImportedSurface String String CompilerIncrementalSemanticOutputIdentity)
  (ImportedArtifact String String String CompilerIncrementalChildIdentity)
  (PackageProvenance String String CompilerIncrementalContentIdentity)
  (StdlibProvenance String CompilerIncrementalContentIdentity)
  (Configuration CompilerIncrementalConfiguration)
  (MacroComptime
    String
    CompilerIncrementalChildIdentity
    CompilerIncrementalChildIdentity)
  (CodegenTarget String String String)
  ;; Sequence order is semantic here.  The sequence name plus ordinal survives
  ;; outer set sorting; duplicate ordinals in one sequence are rejected.
  (OrderedChild String i64 CompilerIncrementalChildIdentity))

(defstruct CompilerIncrementalQuery
  (kind CompilerIncrementalQueryKind)
  (compiler-build CompilerIncrementalBuildIdentity)
  ;; A structural set.  Encoding sorts complete record bytes and rejects exact
  ;; duplicates, independent of caller insertion order.
  (inputs (__tl_dyn-array CompilerIncrementalInput)))

(defstruct CompilerIncrementalIdentity
  (schema i64)
  (query-kind-tag i64)
  (record-count i64)
  (transcript (__tl_dyn-array u8))
  (fingerprint sha256.Sha256Digest))

(defstruct CompilerIncrementalDecodedQuery
  (kind CompilerIncrementalQueryKind)
  (compiler-build CompilerIncrementalChildIdentity)
  (inputs (__tl_dyn-array CompilerIncrementalInput)))

(defstruct CompilerIncrementalMiss
  (category i64)
  (record-index i64)
  (path String)
  (explanation String))

(defenum CompilerIncrementalCompareResult
  (Hit)
  (Miss CompilerIncrementalMiss)
  (Corrupt CompilerIncrementalIdentityError))

(defenum ResultCompilerIncrementalIdentity
  (Ok CompilerIncrementalIdentity)
  (Err CompilerIncrementalIdentityError))

(defenum ResultCompilerIncrementalDecodedQuery
  (Ok CompilerIncrementalDecodedQuery)
  (Err CompilerIncrementalIdentityError))

(defenum ResultCompilerIncrementalContentIdentity
  (Ok CompilerIncrementalContentIdentity)
  (Err CompilerIncrementalIdentityError))

(defstruct CompilerIncrementalEncodedRecord
  (tag i64)
  ;; Canonical binary is stored in a length-delimited String while sorting.
  ;; String permits all byte values and the generated vector family can clone
  ;; its owned handle without requiring structural equality for dyn arrays.
  (bytes String)
  (ordered? bool)
  (sequence String)
  (ordinal i64))

(import stdlib.vector)
(import stdlib.sort)
(import (stdlib.vector.vector CompilerIncrementalEncodedRecord) as incremental_record_vec)
(import (stdlib.sort.vec CompilerIncrementalEncodedRecord) as incremental_record_sort)
(import (stdlib.vector.vector CompilerIncrementalConfigField) as incremental_config_vec)
(import (stdlib.sort.vec CompilerIncrementalConfigField) as incremental_config_sort)

(defenum ResultCompilerIncrementalEncodedRecord
  (Ok CompilerIncrementalEncodedRecord)
  (Err CompilerIncrementalIdentityError))

(defenum ResultCompilerIncrementalConfigBytes
  (Ok String)
  (Err CompilerIncrementalIdentityError))

(define (compiler-incremental-error
  [code : i64]
  [offset : i64]
  [message : String]) : CompilerIncrementalIdentityError
  (CompilerIncrementalIdentityError code offset message))

(define (compiler-incremental-limits-valid?
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : bool
  (and
    (>= limits.max-transcript-bytes 0)
    (>= limits.max-records 0)
    (>= limits.max-record-bytes 0)
    (>= limits.max-string-bytes 0)
    (>= limits.max-nesting-depth 0)
    (>= limits.max-owned-bytes 0)
    (>= limits.max-work 0)
    (<= limits.max-transcript-bytes 4294967295)
    (<= limits.max-records 4294967295)
    (<= limits.max-record-bytes 4294967295)
    (<= limits.max-string-bytes 4294967295)))

(define (compiler-incremental-add-size [left : i64] [right : i64]) : i64
  (if (or (< left 0) (< right 0) (> right (- 9223372036854775807 left)))
    -1
    (+ left right)))

(define (compiler-incremental-string-frame-size [text : (& text str)]) : i64
  (compiler-incremental-add-size 4 (string.string-length text)))

(define (compiler-incremental-string-eq?
  [left : (& left str)]
  [right : (& right str)]) : bool
  (let
    [equal? : bool (= (string.string-length left) (string.string-length right))]
    [index : i64 0]
    (begin
      (while (and equal? (< index (string.string-length left)))
        (begin
          (if (= (string.string-ref left index) (string.string-ref right index))
            unit
            (set! equal? false))
          (set! index (+ index 1))))
      equal?)))

(define (compiler-incremental-string-bytes [text : (& text str)]) : (__tl_dyn-array
    u8)
  (let
    [length : i64 (string.string-length text)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (set!
            (array-ref out index)
            (cast (string.string-ref text index) : u8))
          (set! index (+ index 1))))
      out)))

(define (compiler-incremental-text-valid?
  [text : (& text str)]
  [allow-empty? : bool]
  [max-string-bytes : i64]) : bool
  (let
    [length : i64 (string.string-length text)]
    (if (or (> length max-string-bytes) (and (not allow-empty?) (= length 0)))
      false
      (let
        [bytes : (__tl_dyn-array u8) (compiler-incremental-string-bytes text)]
        (binary.compiler-incremental-binary-utf8-range-valid?
          (& bytes)
          0
          length)))))

(define (compiler-incremental-path-valid?
  [path : (& path str)]
  [max-string-bytes : i64]) : bool
  (let
    [length : i64 (string.string-length path)]
    (if (> length max-string-bytes)
      false
      (let
        [bytes : (__tl_dyn-array u8) (compiler-incremental-string-bytes path)]
        (binary.compiler-incremental-binary-path-range-valid?
          (& bytes)
          0
          length)))))

(define (compiler-incremental-domain-valid?
  [domain : (& domain str)]
  [max-string-bytes : i64]) : bool
  (let
    [length : i64 (string.string-length domain)]
    [index : i64 0]
    [ok? : bool (and (> length 0) (<= length max-string-bytes))]
    (begin
      (while (and ok? (< index length))
        (let
          [code : i64 (cast (string.string-ref domain index) : i64)]
          (if (or
            (and (>= code 97) (<= code 122))
            (and (>= code 48) (<= code 57))
            (= code 45)
            (= code 46)
            (= code 47))
            (set! index (+ index 1))
            (set! ok? false))))
      ok?)))

(define (compiler-incremental-child-valid?
  [child : (& child CompilerIncrementalChildIdentity)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : bool
  (and
    (compiler-incremental-domain-valid?
      (& child.domain)
      limits.max-string-bytes)
    (> child.schema 0)
    (<= child.schema 4294967295)
    (>= child.material-length 0)))

(define (compiler-incremental-child-size
  [child : (& child CompilerIncrementalChildIdentity)]) : i64
  (compiler-incremental-add-size
    (compiler-incremental-string-frame-size (& child.domain))
    44))

(define (compiler-incremental-content-valid?
  [content : (& content CompilerIncrementalContentIdentity)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : bool
  (and
    (compiler-incremental-domain-valid?
      (& content.domain)
      limits.max-string-bytes)
    (> content.schema 0)
    (<= content.schema 4294967295)
    (>= content.exact-length 0)))

(define (compiler-incremental-content-size
  [content : (& content CompilerIncrementalContentIdentity)]) : i64
  (compiler-incremental-add-size
    (compiler-incremental-string-frame-size (& content.domain))
    44))

(define (compiler-incremental-query-kind-tag
  [kind : (& kind CompilerIncrementalQueryKind)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view kind)
    [(CompilerIncrementalQueryKind.Parse) 1]
    [(CompilerIncrementalQueryKind.Typecheck) 2]
    [(CompilerIncrementalQueryKind.Lower) 3]
    [(CompilerIncrementalQueryKind.Optimize) 4]
    [(CompilerIncrementalQueryKind.Assembly) 5]
    [(CompilerIncrementalQueryKind.Object) 6]
    [(CompilerIncrementalQueryKind.IrSummary) 7]
    [(CompilerIncrementalQueryKind.IrDump _) 8]))

(define (compiler-incremental-input-tag
  [input : (& input CompilerIncrementalInput)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view input)
    [(CompilerIncrementalInput.SourceContent _ _) 1]
    [(CompilerIncrementalInput.LogicalName _ _) 2]
    [(CompilerIncrementalInput.ImportedSurface _ _ _) 3]
    [(CompilerIncrementalInput.ImportedArtifact _ _ _ _) 4]
    [(CompilerIncrementalInput.PackageProvenance _ _ _) 5]
    [(CompilerIncrementalInput.StdlibProvenance _ _) 6]
    [(CompilerIncrementalInput.Configuration _) 7]
    [(CompilerIncrementalInput.MacroComptime _ _ _) 8]
    [(CompilerIncrementalInput.CodegenTarget _ _ _) 9]
    [(CompilerIncrementalInput.OrderedChild _ _ _) 10]))

(define (compiler-incremental-push-digest!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [digest : (& digest sha256.Sha256Digest)]) : unit
  (let
    [index : i64 0]
    (while (< index 32)
      (begin
        (byte_buf_core.byte-buf-builder-push
          out
          (sha256.digest-byte digest index))
        (set! index (+ index 1))))))

(define (compiler-incremental-push-child!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [child : (& child CompilerIncrementalChildIdentity)]) : unit
  (begin
    (binary.compiler-incremental-binary-push-string! out (& child.domain))
    (binary.compiler-incremental-binary-push-u32! out child.schema)
    (binary.compiler-incremental-binary-push-u64! out child.material-length)
    (compiler-incremental-push-digest! out (& child.fingerprint))))

(define (compiler-incremental-push-content!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [content : (& content CompilerIncrementalContentIdentity)]) : unit
  (begin
    (binary.compiler-incremental-binary-push-string! out (& content.domain))
    (binary.compiler-incremental-binary-push-u32! out content.schema)
    (binary.compiler-incremental-binary-push-u64! out content.exact-length)
    (compiler-incremental-push-digest! out (& content.fingerprint))))

(define (compiler-incremental-digest-array
  [bytes : (& bytes (__tl_dyn-array u8))]) : sha256.Sha256FinalizeResult
  (let
    [copy : (__tl_dyn-array u8) (binary.compiler-incremental-binary-copy bytes)]
    [owner : byte_buf.ByteBuf (byte_buf.from-array copy)]
    (sha256.digest (byte_buf.as-bytes (& owner)))))

;; Construct a domain-separated content identity from exact caller bytes.
(define (compiler-incremental-content-identity
  [domain : String]
  [bytes : (& bytes (__tl_dyn-array u8))]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : ResultCompilerIncrementalContentIdentity
  (let
    [material-size : i64
      (compiler-incremental-add-size
        (compiler-incremental-add-size 16 (string.string-length domain))
        (array-length bytes))]
    [owned-size : i64
      (compiler-incremental-add-size material-size material-size)]
    (cond
      [(not (compiler-incremental-limits-valid? limits))
        (ResultCompilerIncrementalContentIdentity.Err
          (compiler-incremental-error
            compiler-incremental-error-invalid-limits
            0
            "incremental identity limits are invalid"))]
      [(or
          (< material-size 0)
          (not
            (compiler-incremental-domain-valid?
              (& domain)
              limits.max-string-bytes))
          (> material-size limits.max-transcript-bytes))
        (ResultCompilerIncrementalContentIdentity.Err
          (compiler-incremental-error
            compiler-incremental-error-value
            0
            "content identity domain or byte length is invalid"))]
      [(or (< owned-size 0) (> owned-size limits.max-owned-bytes))
        (ResultCompilerIncrementalContentIdentity.Err
          (compiler-incremental-error
            compiler-incremental-error-owned-limit
            0
            "content identity material exceeds its owned-byte limit"))]
      [else
        (let
          [out : byte_buf_core.ByteBufBuilder
            (byte_buf_core.byte-buf-builder-with-capacity material-size)]
          (begin
            (binary.compiler-incremental-binary-push-string!
              (&mut out)
              (& domain))
            (binary.compiler-incremental-binary-push-u32! (&mut out) 1)
            (binary.compiler-incremental-binary-push-u64!
              (&mut out)
              (array-length bytes))
            (binary.compiler-incremental-binary-push-array! (&mut out) bytes)
            (let
              [material : (__tl_dyn-array u8)
                (byte_buf_core.byte-buf-builder-finish-array (& out))]
              (match (compiler-incremental-digest-array (& material))
                [(sha256.Sha256FinalizeErr _)
                  (ResultCompilerIncrementalContentIdentity.Err
                    (compiler-incremental-error
                      compiler-incremental-error-fingerprint
                      0
                      "SHA-256 rejected content identity material"))]
                [(sha256.Sha256FinalizeOk digest)
                  (ResultCompilerIncrementalContentIdentity.Ok
                    (CompilerIncrementalContentIdentity
                      domain
                      1
                      (array-length bytes)
                      digest))]))))])))

(define (compiler-incremental-record-less?
  [left : CompilerIncrementalEncodedRecord]
  [right : CompilerIncrementalEncodedRecord]) : bool
  (stdlib.sort.string-less-borrowed? (& left.bytes) (& right.bytes)))

(define (compiler-incremental-config-field-less?
  [left : CompilerIncrementalConfigField]
  [right : CompilerIncrementalConfigField]) : bool
  (stdlib.sort.string-less-borrowed? (& left.name) (& right.name)))

(define (compiler-incremental-record-bytes-eq?
  [left : (& left CompilerIncrementalEncodedRecord)]
  [right : (& right CompilerIncrementalEncodedRecord)]) : bool
  (compiler-incremental-string-eq? (& left.bytes) (& right.bytes)))

(define (compiler-incremental-size-chain2 [a : i64] [b : i64]) : i64
  (compiler-incremental-add-size a b))

(define (compiler-incremental-size-chain3 [a : i64] [b : i64] [c : i64]) : i64
  (compiler-incremental-add-size (compiler-incremental-add-size a b) c))

(define (compiler-incremental-size-chain4
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]) : i64
  (compiler-incremental-add-size (compiler-incremental-size-chain3 a b c) d))

(define (compiler-incremental-config-payload-size
  [config : (& config CompilerIncrementalConfiguration)]) : i64
  (let
    [size : i64
      (compiler-incremental-size-chain4
        (compiler-incremental-string-frame-size (& config.target))
        (compiler-incremental-string-frame-size (& config.profile))
        (compiler-incremental-string-frame-size (& config.backend))
        5)]
    (begin
      (set!
        size
        (compiler-incremental-add-size
          size
          (compiler-incremental-string-frame-size (& config.path-remap))))
      (set!
        size
        (compiler-incremental-add-size
          size
          (compiler-incremental-string-frame-size
            (& config.generated-source-policy))))
      (set! size (compiler-incremental-add-size size 4))
      (let
        [index : i64 0]
        (begin
          (while (and (>= size 0) (< index (array-length config.extensions)))
            (let
              [field : CompilerIncrementalConfigField
                (owned_view.compiler-owned-array-element-shared-view
                  config.extensions
                  index)]
              [field-payload : i64
                (compiler-incremental-size-chain2
                  (compiler-incremental-string-frame-size (& field.name))
                  (compiler-incremental-string-frame-size (& field.value)))]
              (begin
                (set!
                  size
                  (compiler-incremental-add-size
                    size
                    (compiler-incremental-add-size 4 field-payload)))
                (set! index (+ index 1)))))
          size)))))

(define (compiler-incremental-config-valid?
  [config : (& config CompilerIncrementalConfiguration)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : bool
  (let
    [index : i64 0]
    [ok? : bool
      (and
        (compiler-incremental-text-valid?
          (& config.target)
          false
          limits.max-string-bytes)
        (compiler-incremental-text-valid?
          (& config.profile)
          false
          limits.max-string-bytes)
        (compiler-incremental-text-valid?
          (& config.backend)
          false
          limits.max-string-bytes)
        (>= config.opt-level 0)
        (<= config.opt-level 3)
        (compiler-incremental-text-valid?
          (& config.path-remap)
          true
          limits.max-string-bytes)
        (compiler-incremental-text-valid?
          (& config.generated-source-policy)
          false
          limits.max-string-bytes)
        (<= (array-length config.extensions) limits.max-records))]
    (begin
      (while (and ok? (< index (array-length config.extensions)))
        (let
          [field : CompilerIncrementalConfigField
            (owned_view.compiler-owned-array-element-shared-view
              config.extensions
              index)]
          (if (and
            (compiler-incremental-domain-valid?
              (& field.name)
              limits.max-string-bytes)
            (compiler-incremental-text-valid?
              (& field.value)
              true
              limits.max-string-bytes))
            (set! index (+ index 1))
            (set! ok? false))))
      ok?)))

(define (compiler-incremental-content-domain?
  [content : (& content CompilerIncrementalContentIdentity)]
  [expected : (& expected str)]) : bool
  (compiler-incremental-string-eq? (& content.domain) expected))

(define (compiler-incremental-input-valid?
  [input : (& input CompilerIncrementalInput)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view input)
    [(CompilerIncrementalInput.SourceContent path content)
      (and
        (compiler-incremental-path-valid? (& path) limits.max-string-bytes)
        (compiler-incremental-content-valid? (& content) limits)
        (compiler-incremental-content-domain?
          (& content)
          "typelisp.source-content"))]
    [(CompilerIncrementalInput.LogicalName module declaration)
      (and
        (compiler-incremental-text-valid?
          (& module)
          false
          limits.max-string-bytes)
        (compiler-incremental-text-valid?
          (& declaration)
          true
          limits.max-string-bytes))]
    [(CompilerIncrementalInput.ImportedSurface package module semantic)
      (and
        (compiler-incremental-text-valid?
          (& package)
          false
          limits.max-string-bytes)
        (compiler-incremental-text-valid?
          (& module)
          false
          limits.max-string-bytes)
        (compiler-incremental-child-valid? (& semantic.identity) limits)
        (compiler-incremental-string-eq?
          (& semantic.identity.domain)
          (& compiler-incremental-semantic-output-domain)))]
    [(CompilerIncrementalInput.ImportedArtifact
        package
        path
        artifact-kind
        child)
      (and
        (compiler-incremental-text-valid?
          (& package)
          false
          limits.max-string-bytes)
        (compiler-incremental-path-valid? (& path) limits.max-string-bytes)
        (compiler-incremental-domain-valid?
          (& artifact-kind)
          limits.max-string-bytes)
        (compiler-incremental-child-valid? (& child) limits))]
    [(CompilerIncrementalInput.PackageProvenance package version content)
      (and
        (compiler-incremental-text-valid?
          (& package)
          false
          limits.max-string-bytes)
        (compiler-incremental-text-valid?
          (& version)
          false
          limits.max-string-bytes)
        (compiler-incremental-content-valid? (& content) limits)
        (compiler-incremental-content-domain?
          (& content)
          "typelisp.package-content"))]
    [(CompilerIncrementalInput.StdlibProvenance distribution content)
      (and
        (compiler-incremental-text-valid?
          (& distribution)
          false
          limits.max-string-bytes)
        (compiler-incremental-content-valid? (& content) limits)
        (compiler-incremental-content-domain?
          (& content)
          "typelisp.stdlib-content"))]
    [(CompilerIncrementalInput.Configuration config)
      (compiler-incremental-config-valid? (& config) limits)]
    [(CompilerIncrementalInput.MacroComptime phase request result)
      (and
        (compiler-incremental-domain-valid? (& phase) limits.max-string-bytes)
        (compiler-incremental-child-valid? (& request) limits)
        (compiler-incremental-child-valid? (& result) limits))]
    [(CompilerIncrementalInput.CodegenTarget target backend feature-set)
      (and
        (compiler-incremental-text-valid?
          (& target)
          false
          limits.max-string-bytes)
        (compiler-incremental-text-valid?
          (& backend)
          false
          limits.max-string-bytes)
        (compiler-incremental-text-valid?
          (& feature-set)
          false
          limits.max-string-bytes))]
    [(CompilerIncrementalInput.OrderedChild sequence ordinal child)
      (and
        (compiler-incremental-domain-valid?
          (& sequence)
          limits.max-string-bytes)
        (>= ordinal 0)
        (compiler-incremental-child-valid? (& child) limits))]))

(define (compiler-incremental-input-payload-size
  [input : (& input CompilerIncrementalInput)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view input)
    [(CompilerIncrementalInput.SourceContent path content)
      (compiler-incremental-size-chain2
        (compiler-incremental-string-frame-size (& path))
        (compiler-incremental-content-size (& content)))]
    [(CompilerIncrementalInput.LogicalName module declaration)
      (compiler-incremental-size-chain2
        (compiler-incremental-string-frame-size (& module))
        (compiler-incremental-string-frame-size (& declaration)))]
    [(CompilerIncrementalInput.ImportedSurface package module semantic)
      (compiler-incremental-size-chain3
        (compiler-incremental-string-frame-size (& package))
        (compiler-incremental-string-frame-size (& module))
        (compiler-incremental-child-size (& semantic.identity)))]
    [(CompilerIncrementalInput.ImportedArtifact
        package
        path
        artifact-kind
        child)
      (compiler-incremental-size-chain4
        (compiler-incremental-string-frame-size (& package))
        (compiler-incremental-string-frame-size (& path))
        (compiler-incremental-string-frame-size (& artifact-kind))
        (compiler-incremental-child-size (& child)))]
    [(CompilerIncrementalInput.PackageProvenance package version content)
      (compiler-incremental-size-chain3
        (compiler-incremental-string-frame-size (& package))
        (compiler-incremental-string-frame-size (& version))
        (compiler-incremental-content-size (& content)))]
    [(CompilerIncrementalInput.StdlibProvenance distribution content)
      (compiler-incremental-size-chain2
        (compiler-incremental-string-frame-size (& distribution))
        (compiler-incremental-content-size (& content)))]
    [(CompilerIncrementalInput.Configuration config)
      (compiler-incremental-config-payload-size (& config))]
    [(CompilerIncrementalInput.MacroComptime phase request result)
      (compiler-incremental-size-chain3
        (compiler-incremental-string-frame-size (& phase))
        (compiler-incremental-child-size (& request))
        (compiler-incremental-child-size (& result)))]
    [(CompilerIncrementalInput.CodegenTarget target backend feature-set)
      (compiler-incremental-size-chain3
        (compiler-incremental-string-frame-size (& target))
        (compiler-incremental-string-frame-size (& backend))
        (compiler-incremental-string-frame-size (& feature-set)))]
    [(CompilerIncrementalInput.OrderedChild sequence _ child)
      (compiler-incremental-size-chain3
        (compiler-incremental-string-frame-size (& sequence))
        8
        (compiler-incremental-child-size (& child)))]))

(define (compiler-incremental-encode-config-field
  [field : (& field CompilerIncrementalConfigField)]) : CompilerIncrementalEncodedRecord
  (let
    [payload-size : i64
      (compiler-incremental-size-chain2
        (compiler-incremental-string-frame-size (& field.name))
        (compiler-incremental-string-frame-size (& field.value)))]
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity (+ 4 payload-size))]
    (begin
      (binary.compiler-incremental-binary-push-u32! (&mut out) payload-size)
      (binary.compiler-incremental-binary-push-string!
        (&mut out)
        (& field.name))
      (binary.compiler-incremental-binary-push-string!
        (&mut out)
        (& field.value))
      (CompilerIncrementalEncodedRecord
        0
        (byte_buf_core.byte-buf-builder-finish-string (& out))
        false
        ""
        -1))))

(define (compiler-incremental-encode-config-extensions
  [config : (& config CompilerIncrementalConfiguration)]) : ResultCompilerIncrementalConfigBytes
  (let
    [fields : incremental_config_vec.Vec
      (incremental_config_vec.with-capacity (array-length config.extensions))]
    [index : i64 0]
    [duplicate? : bool false]
    (begin
      (while (< index (array-length config.extensions))
        (let
          [field : CompilerIncrementalConfigField
            (owned_view.compiler-owned-array-element-shared-view
              config.extensions
              index)]
          (begin
            (incremental_config_vec.push-ref! (&mut fields) field)
            (set! index (+ index 1)))))
      (incremental_config_sort.sort!
        (&mut fields)
        compiler-incremental-config-field-less?)
      (set! index 1)
      (while (and
        (not duplicate?)
        (< index (incremental_config_vec.len (& fields))))
        (let
          [slots (incremental_config_vec.slots (& fields))]
          (if (compiler-incremental-string-eq?
            (& (array-ref slots (- index 1)).name)
            (& (array-ref slots index).name))
            (set! duplicate? true)
            (set! index (+ index 1)))))
      (if duplicate?
        (ResultCompilerIncrementalConfigBytes.Err
          (compiler-incremental-error
            compiler-incremental-error-order
            0
            "duplicate canonical configuration field"))
        (let
          [out : byte_buf_core.ByteBufBuilder
            (byte_buf_core.byte-buf-builder-new)]
          [record-index : i64 0]
          (begin
            (binary.compiler-incremental-binary-push-u32!
              (&mut out)
              (incremental_config_vec.len (& fields)))
            (while (< record-index (incremental_config_vec.len (& fields)))
              (let
                [slots (incremental_config_vec.slots (& fields))]
                [record : CompilerIncrementalEncodedRecord
                  (compiler-incremental-encode-config-field
                    (& (array-ref slots record-index)))]
                (begin
                  (byte_buf_core.byte-buf-builder-append-string
                    (&mut out)
                    record.bytes)
                  (set! record-index (+ record-index 1)))))
            (ResultCompilerIncrementalConfigBytes.Ok
              (byte_buf_core.byte-buf-builder-finish-string (& out)))))))))

(define (compiler-incremental-input-invalid-code
  [input : (& input CompilerIncrementalInput)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view input)
    [(CompilerIncrementalInput.SourceContent path _)
      (if (compiler-incremental-path-valid? (& path) limits.max-string-bytes)
        compiler-incremental-error-value
        compiler-incremental-error-path)]
    [(CompilerIncrementalInput.ImportedArtifact _ path _ _)
      (if (compiler-incremental-path-valid? (& path) limits.max-string-bytes)
        compiler-incremental-error-value
        compiler-incremental-error-path)]
    [_ compiler-incremental-error-value]))

(define (compiler-incremental-encode-input
  [input : (& input CompilerIncrementalInput)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : ResultCompilerIncrementalEncodedRecord
  (let
    [payload-size : i64 (compiler-incremental-input-payload-size input)]
    [tag : i64 (compiler-incremental-input-tag input)]
    (if (not (compiler-incremental-input-valid? input limits))
      (ResultCompilerIncrementalEncodedRecord.Err
        (compiler-incremental-error
          (compiler-incremental-input-invalid-code input limits)
          0
          "incremental query input is invalid"))
      (if (or
        (< payload-size 0)
        (> payload-size limits.max-record-bytes)
        (> payload-size 4294967295))
        (ResultCompilerIncrementalEncodedRecord.Err
          (compiler-incremental-error
            compiler-incremental-error-input-limit
            0
            "incremental query record exceeds its byte limit"))
        (let
          [out : byte_buf_core.ByteBufBuilder
            (byte_buf_core.byte-buf-builder-with-capacity (+ 5 payload-size))]
          [ordered? : bool false]
          [sequence : String ""]
          [ordinal : i64 -1]
          (begin
            (binary.compiler-incremental-binary-push-u8! (&mut out) tag)
            (binary.compiler-incremental-binary-push-u32!
              (&mut out)
              payload-size)
            (match (owned_view.compiler-owned-reference-shared-view input)
              [(CompilerIncrementalInput.SourceContent path content)
                (begin
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& path))
                  (compiler-incremental-push-content! (&mut out) (& content)))]
              [(CompilerIncrementalInput.LogicalName module declaration)
                (begin
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& module))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& declaration)))]
              [(CompilerIncrementalInput.ImportedSurface
                  package
                  module
                  semantic)
                (begin
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& package))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& module))
                  (compiler-incremental-push-child!
                    (&mut out)
                    (& semantic.identity)))]
              [(CompilerIncrementalInput.ImportedArtifact
                  package
                  path
                  artifact-kind
                  child)
                (begin
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& package))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& path))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& artifact-kind))
                  (compiler-incremental-push-child! (&mut out) (& child)))]
              [(CompilerIncrementalInput.PackageProvenance
                  package
                  version
                  content)
                (begin
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& package))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& version))
                  (compiler-incremental-push-content! (&mut out) (& content)))]
              [(CompilerIncrementalInput.StdlibProvenance distribution content)
                (begin
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& distribution))
                  (compiler-incremental-push-content! (&mut out) (& content)))]
              [(CompilerIncrementalInput.Configuration config)
                (begin
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& config.target))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& config.profile))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& config.backend))
                  (binary.compiler-incremental-binary-push-u32!
                    (&mut out)
                    config.opt-level)
                  (binary.compiler-incremental-binary-push-u8!
                    (&mut out)
                    (if config.debug?
                      1
                      0))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& config.path-remap))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& config.generated-source-policy))
                  (match (compiler-incremental-encode-config-extensions
                    (& config))
                    [(ResultCompilerIncrementalConfigBytes.Err error)
                      (return
                        (ResultCompilerIncrementalEncodedRecord.Err error))]
                    [(ResultCompilerIncrementalConfigBytes.Ok extension-bytes)
                      (byte_buf_core.byte-buf-builder-append-string
                        (&mut out)
                        extension-bytes)]))]
              [(CompilerIncrementalInput.MacroComptime phase request result)
                (begin
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& phase))
                  (compiler-incremental-push-child! (&mut out) (& request))
                  (compiler-incremental-push-child! (&mut out) (& result)))]
              [(CompilerIncrementalInput.CodegenTarget
                  target
                  backend
                  feature-set)
                (begin
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& target))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& backend))
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& feature-set)))]
              [(CompilerIncrementalInput.OrderedChild
                  actual-sequence
                  actual-ordinal
                  child)
                (begin
                  (set! ordered? true)
                  (set! sequence actual-sequence)
                  (set! ordinal actual-ordinal)
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& sequence))
                  (binary.compiler-incremental-binary-push-u64!
                    (&mut out)
                    ordinal)
                  (compiler-incremental-push-child! (&mut out) (& child)))])
            (ResultCompilerIncrementalEncodedRecord.Ok
              (CompilerIncrementalEncodedRecord
                tag
                (byte_buf_core.byte-buf-builder-finish-string (& out))
                ordered?
                sequence
                ordinal))))))))

(define (compiler-incremental-query-kind-valid?
  [kind : (& kind CompilerIncrementalQueryKind)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view kind)
    [(CompilerIncrementalQueryKind.IrDump pass)
      (compiler-incremental-text-valid? (& pass) false limits.max-string-bytes)]
    [_ true]))

(define (compiler-incremental-query-kind-size
  [kind : (& kind CompilerIncrementalQueryKind)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view kind)
    [(CompilerIncrementalQueryKind.IrDump pass)
      (compiler-incremental-add-size
        1
        (compiler-incremental-string-frame-size (& pass)))]
    [_ 1]))

(define (compiler-incremental-push-query-kind!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [kind : (& kind CompilerIncrementalQueryKind)]) : unit
  (begin
    (binary.compiler-incremental-binary-push-u8!
      out
      (compiler-incremental-query-kind-tag kind))
    (match (owned_view.compiler-owned-reference-shared-view kind)
      [(CompilerIncrementalQueryKind.IrDump pass)
        (binary.compiler-incremental-binary-push-string! out (& pass))]
      [_ unit])))

(define (compiler-incremental-build-available
  [build : (& build CompilerIncrementalBuildIdentity)]) : CompilerIncrementalChildIdentity
  (match (owned_view.compiler-owned-reference-shared-view build)
    [(CompilerIncrementalBuildIdentity.Available child) child]
    [(CompilerIncrementalBuildIdentity.Unavailable _)
      (CompilerIncrementalChildIdentity
        "invalid"
        0
        0
        (sha256.Sha256Digest (init)))]))

(define (compiler-incremental-build-valid?
  [build : (& build CompilerIncrementalBuildIdentity)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view build)
    [(CompilerIncrementalBuildIdentity.Unavailable _) false]
    [(CompilerIncrementalBuildIdentity.Available child)
      (and
        (compiler-incremental-child-valid? (& child) limits)
        (compiler-incremental-string-eq?
          (& child.domain)
          (& compiler-incremental-build-domain)))]))

(define (compiler-incremental-query-planned-size
  [query : (& query CompilerIncrementalQuery)]) : i64
  (let
    [build : CompilerIncrementalChildIdentity
      (compiler-incremental-build-available (& query.compiler-build))]
    [size : i64
      (compiler-incremental-size-chain4
        (compiler-incremental-string-frame-size
          (& compiler-incremental-identity-domain))
        4
        (compiler-incremental-query-kind-size (& query.kind))
        (compiler-incremental-child-size (& build)))]
    [index : i64 0]
    (begin
      (set! size (compiler-incremental-add-size size 4))
      (while (and (>= size 0) (< index (array-length query.inputs)))
        (let
          [input : CompilerIncrementalInput
            (owned_view.compiler-owned-array-element-shared-view
              query.inputs
              index)]
          [payload-size : i64
            (compiler-incremental-input-payload-size (& input))]
          (begin
            (set!
              size
              (compiler-incremental-add-size
                size
                (compiler-incremental-add-size 5 payload-size)))
            (set! index (+ index 1)))))
      size)))

(define (compiler-incremental-owned-plan-valid?
  [transcript-size : i64]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : bool
  (let
    ;; Record buffers, validation material, final transcript, and the one-shot
    ;; SHA adapter each retain at most one transcript-sized byte population.
    [owned : i64 transcript-size]
    [copy-index : i64 1]
    (begin
      (while (and (>= owned 0) (< copy-index 5))
        (begin
          (set! owned (compiler-incremental-add-size owned transcript-size))
          (set! copy-index (+ copy-index 1))))
      (and (>= owned 0) (<= owned limits.max-owned-bytes)))))

(define (compiler-incremental-identity-encode
  [query : CompilerIncrementalQuery]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : ResultCompilerIncrementalIdentity
  (cond
    [(not (compiler-incremental-limits-valid? limits))
      (ResultCompilerIncrementalIdentity.Err
        (compiler-incremental-error
          compiler-incremental-error-invalid-limits
          0
          "incremental identity limits are invalid"))]
    [(<
        limits.max-nesting-depth
        (if (> (array-length query.inputs) 0)
          3
          2))
      (ResultCompilerIncrementalIdentity.Err
        (compiler-incremental-error
          compiler-incremental-error-depth-limit
          0
          "incremental query exceeds the nesting-depth limit"))]
    [(> (array-length query.inputs) limits.max-records)
      (ResultCompilerIncrementalIdentity.Err
        (compiler-incremental-error
          compiler-incremental-error-record-limit
          0
          "incremental query has too many input records"))]
    [(not (compiler-incremental-query-kind-valid? (& query.kind) limits))
      (ResultCompilerIncrementalIdentity.Err
        (compiler-incremental-error
          compiler-incremental-error-value
          0
          "incremental query kind payload is invalid"))]
    [(not (compiler-incremental-build-valid? (& query.compiler-build) limits))
      (ResultCompilerIncrementalIdentity.Err
        (compiler-incremental-error
          compiler-incremental-error-build-unavailable
          0
          "canonical compiler-build identity is unavailable"))]
    [else
      (let
        [planned-size : i64 (compiler-incremental-query-planned-size (& query))]
        (if (or
          (< planned-size 0)
          (> planned-size limits.max-transcript-bytes)
          (not (compiler-incremental-owned-plan-valid? planned-size limits)))
          (ResultCompilerIncrementalIdentity.Err
            (compiler-incremental-error
              (if (> planned-size limits.max-transcript-bytes)
                compiler-incremental-error-input-limit
                compiler-incremental-error-owned-limit)
              0
              "incremental query exceeds a byte ownership limit"))
          (let
            [records : incremental_record_vec.Vec
              (incremental_record_vec.with-capacity (array-length query.inputs))]
            [index : i64 0]
            (begin
              (while (< index (array-length query.inputs))
                (let
                  [input : CompilerIncrementalInput
                    (owned_view.compiler-owned-array-element-shared-view
                      query.inputs
                      index)]
                  (match (compiler-incremental-encode-input (& input) limits)
                    [(ResultCompilerIncrementalEncodedRecord.Err error)
                      (return (ResultCompilerIncrementalIdentity.Err error))]
                    [(ResultCompilerIncrementalEncodedRecord.Ok record)
                      (begin
                        (incremental_record_vec.push-ref! (&mut records) record)
                        (set! index (+ index 1)))])))
              (incremental_record_sort.sort!
                (&mut records)
                compiler-incremental-record-less?)
              (set! index 1)
              (while (< index (incremental_record_vec.len (& records)))
                (let
                  [previous : CompilerIncrementalEncodedRecord
                    (owned_view.compiler-owned-array-element-shared-view
                      records.slots
                      (- index 1))]
                  [current : CompilerIncrementalEncodedRecord
                    (owned_view.compiler-owned-array-element-shared-view
                      records.slots
                      index)]
                  (cond
                    [(compiler-incremental-record-bytes-eq?
                        (& previous)
                        (& current))
                      (return
                        (ResultCompilerIncrementalIdentity.Err
                          (compiler-incremental-error
                            compiler-incremental-error-order
                            0
                            "duplicate canonical input record")))]
                    [(and
                        previous.ordered?
                        current.ordered?
                        (= previous.ordinal current.ordinal)
                        (compiler-incremental-string-eq?
                          (& previous.sequence)
                          (& current.sequence)))
                      (return
                        (ResultCompilerIncrementalIdentity.Err
                          (compiler-incremental-error
                            compiler-incremental-error-order
                            0
                            "duplicate ordered-child sequence ordinal")))]
                    [else (set! index (+ index 1))])))
              (let
                [build : CompilerIncrementalChildIdentity
                  (compiler-incremental-build-available
                    (& query.compiler-build))]
                [out : byte_buf_core.ByteBufBuilder
                  (byte_buf_core.byte-buf-builder-with-capacity planned-size)]
                [record-index : i64 0]
                (begin
                  (binary.compiler-incremental-binary-push-string!
                    (&mut out)
                    (& compiler-incremental-identity-domain))
                  (binary.compiler-incremental-binary-push-u32!
                    (&mut out)
                    compiler-incremental-identity-schema)
                  (compiler-incremental-push-query-kind!
                    (&mut out)
                    (& query.kind))
                  (compiler-incremental-push-child! (&mut out) (& build))
                  (binary.compiler-incremental-binary-push-u32!
                    (&mut out)
                    (incremental_record_vec.len (& records)))
                  (while (<
                    record-index
                    (incremental_record_vec.len (& records)))
                    (let
                      [slots (incremental_record_vec.slots (& records))]
                      (begin
                        (byte_buf_core.byte-buf-builder-append-string
                          (&mut out)
                          (owned_view.compiler-owned-string-place-shared-view
                            (array-ref slots record-index).bytes))
                        (set! record-index (+ record-index 1)))))
                  (let
                    [transcript : (__tl_dyn-array u8)
                      (byte_buf_core.byte-buf-builder-finish-array (& out))]
                    (if (!= (array-length transcript) planned-size)
                      (ResultCompilerIncrementalIdentity.Err
                        (compiler-incremental-error
                          compiler-incremental-error-layout
                          0
                          "incremental identity size plan disagrees with encoder"))
                      (match (compiler-incremental-digest-array (& transcript))
                        [(sha256.Sha256FinalizeErr _)
                          (ResultCompilerIncrementalIdentity.Err
                            (compiler-incremental-error
                              compiler-incremental-error-fingerprint
                              0
                              "SHA-256 rejected incremental transcript"))]
                        [(sha256.Sha256FinalizeOk digest)
                          (ResultCompilerIncrementalIdentity.Ok
                            (CompilerIncrementalIdentity
                              compiler-incremental-identity-schema
                              (compiler-incremental-query-kind-tag
                                (& query.kind))
                              (array-length query.inputs)
                              transcript
                              digest))])))))))))]))

(define (compiler-incremental-reader-error
  [reader : (& reader binary.CompilerIncrementalBinaryReader)]) : CompilerIncrementalIdentityError
  (compiler-incremental-error
    reader.error-code
    reader.error-offset
    (string.copy (& reader.error-message))))

(define (compiler-incremental-read-digest!
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]) : sha256.Sha256Digest
  (let
    [octets : (Array u8 32) (init)]
    [index : i64 0]
    (begin
      (while (< index 32)
        (begin
          (set!
            (array-ref octets index)
            (cast (binary.compiler-incremental-binary-read-u8! reader) : u8))
          (set! index (+ index 1))))
      (sha256.Sha256Digest octets))))

(define (compiler-incremental-read-child!
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : CompilerIncrementalChildIdentity
  (let
    [domain : String
      (binary.compiler-incremental-binary-read-string! reader false)]
    [schema : i64 (binary.compiler-incremental-binary-read-u32! reader)]
    [material-length : i64
      (binary.compiler-incremental-binary-read-u64! reader)]
    [digest : sha256.Sha256Digest (compiler-incremental-read-digest! reader)]
    [child : CompilerIncrementalChildIdentity
      (CompilerIncrementalChildIdentity domain schema material-length digest)]
    (begin
      (if (if reader.ok?
        (not (compiler-incremental-child-valid? (& child) limits))
        false)
        (binary.compiler-incremental-binary-fail!
          reader
          compiler-incremental-error-value
          reader.offset
          "incremental child identity is invalid")
        unit)
      child)))

(define (compiler-incremental-read-content!
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : CompilerIncrementalContentIdentity
  (let
    [domain : String
      (binary.compiler-incremental-binary-read-string! reader false)]
    [schema : i64 (binary.compiler-incremental-binary-read-u32! reader)]
    [exact-length : i64 (binary.compiler-incremental-binary-read-u64! reader)]
    [digest : sha256.Sha256Digest (compiler-incremental-read-digest! reader)]
    [content : CompilerIncrementalContentIdentity
      (CompilerIncrementalContentIdentity domain schema exact-length digest)]
    (begin
      (if (if reader.ok?
        (not (compiler-incremental-content-valid? (& content) limits))
        false)
        (binary.compiler-incremental-binary-fail!
          reader
          compiler-incremental-error-value
          reader.offset
          "incremental content identity is invalid")
        unit)
      content)))

(define (compiler-incremental-range-eq?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [left-start : i64]
  [left-length : i64]
  [right-start : i64]
  [right-length : i64]) : bool
  (let
    [equal? : bool (= left-length right-length)]
    [index : i64 0]
    (begin
      (while (and equal? (< index left-length))
        (begin
          (if (=
            (array-ref bytes (+ left-start index))
            (array-ref bytes (+ right-start index)))
            unit
            (set! equal? false))
          (set! index (+ index 1))))
      equal?)))

(define (compiler-incremental-range-less?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [left-start : i64]
  [left-length : i64]
  [right-start : i64]
  [right-length : i64]) : bool
  (let
    [limit : i64
      (if (< left-length right-length)
        left-length
        right-length)]
    [index : i64 0]
    [decided? : bool false]
    [less? : bool false]
    (begin
      (while (and (not decided?) (< index limit))
        (let
          [left-byte : u8 (array-ref bytes (+ left-start index))]
          [right-byte : u8 (array-ref bytes (+ right-start index))]
          (cond
            [(< left-byte right-byte)
              (begin
                (set! less? true)
                (set! decided? true))]
            [(> left-byte right-byte) (set! decided? true)]
            [else (set! index (+ index 1))])))
      (if decided?
        less?
        (< left-length right-length)))))

(define (compiler-incremental-reader-charge-work!
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]
  [additional : i64]) : bool
  (if (or (< additional 0) (> additional (- reader.max-work reader.work)))
    (begin
      (binary.compiler-incremental-binary-fail!
        reader
        compiler-incremental-error-work-limit
        reader.offset
        "incremental identity work limit exceeded")
      false)
    (begin
      (set! reader.work (+ reader.work additional))
      true)))

(define (compiler-incremental-read-query-kind!
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]) : CompilerIncrementalQueryKind
  (let
    [tag-offset : i64 reader.offset]
    [tag : i64 (binary.compiler-incremental-binary-read-u8! reader)]
    (cond
      [(= tag 1) (CompilerIncrementalQueryKind.Parse)]
      [(= tag 2) (CompilerIncrementalQueryKind.Typecheck)]
      [(= tag 3) (CompilerIncrementalQueryKind.Lower)]
      [(= tag 4) (CompilerIncrementalQueryKind.Optimize)]
      [(= tag 5) (CompilerIncrementalQueryKind.Assembly)]
      [(= tag 6) (CompilerIncrementalQueryKind.Object)]
      [(= tag 7) (CompilerIncrementalQueryKind.IrSummary)]
      [(= tag 8)
        (CompilerIncrementalQueryKind.IrDump
          (binary.compiler-incremental-binary-read-string! reader false))]
      [else
        (begin
          (binary.compiler-incremental-binary-fail!
            reader
            compiler-incremental-error-unknown-tag
            tag-offset
            "unknown incremental query-kind tag")
          (CompilerIncrementalQueryKind.Parse))])))

(define (compiler-incremental-reader-reserve-owned-records!
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]
  [count : i64]
  [bytes-per-record : i64]) : bool
  (let
    [available : i64 (- reader.max-owned-bytes reader.owned-bytes)]
    (if (or
      (< count 0)
      (< bytes-per-record 1)
      (< available 0)
      (> count (/ available bytes-per-record)))
      (begin
        (binary.compiler-incremental-binary-fail!
          reader
          compiler-incremental-error-owned-limit
          reader.offset
          "incremental identity record storage exceeds owned-byte limit")
        false)
      (begin
        (set!
          reader.owned-bytes
          (+ reader.owned-bytes (* count bytes-per-record)))
        true))))

(define (compiler-incremental-read-config!
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : CompilerIncrementalConfiguration
  (let
    [target : String
      (binary.compiler-incremental-binary-read-string! reader false)]
    [profile : String
      (binary.compiler-incremental-binary-read-string! reader false)]
    [backend : String
      (binary.compiler-incremental-binary-read-string! reader false)]
    [opt-level : i64 (binary.compiler-incremental-binary-read-u32! reader)]
    [debug-byte-offset : i64 reader.offset]
    [debug-byte : i64 (binary.compiler-incremental-binary-read-u8! reader)]
    [path-remap : String
      (binary.compiler-incremental-binary-read-string! reader false)]
    [generated-source-policy : String
      (binary.compiler-incremental-binary-read-string! reader false)]
    [count-offset : i64 reader.offset]
    [count : i64 (binary.compiler-incremental-binary-read-u32! reader)]
    [allocation-ok? : bool
      (if (and reader.ok? (<= count limits.max-records))
        (compiler-incremental-reader-reserve-owned-records! reader count 64)
        false)]
    [extensions : (__tl_dyn-array CompilerIncrementalConfigField)
      (if allocation-ok?
        (__tl_make-array CompilerIncrementalConfigField count)
        (__tl_make-array CompilerIncrementalConfigField 0))]
    [index : i64 0]
    (begin
      (if (and reader.ok? (> count limits.max-records))
        (binary.compiler-incremental-binary-fail!
          reader
          compiler-incremental-error-record-limit
          count-offset
          "configuration extension count exceeds limit")
        unit)
      (if (and reader.ok? (not (or (= debug-byte 0) (= debug-byte 1))))
        (binary.compiler-incremental-binary-fail!
          reader
          compiler-incremental-error-value
          debug-byte-offset
          "configuration debug byte must be zero or one")
        unit)
      (while (and reader.ok? (< index count))
        (let
          [frame-start : i64 reader.offset]
          [payload-length : i64
            (binary.compiler-incremental-binary-read-u32! reader)]
          [payload-start : i64 reader.offset]
          [outer-end : i64 reader.end]
          (if (> payload-length limits.max-record-bytes)
            (binary.compiler-incremental-binary-fail!
              reader
              compiler-incremental-error-input-limit
              frame-start
              "configuration extension frame exceeds its byte limit")
            (if (not
              (binary.compiler-incremental-binary-range-present?
                outer-end
                payload-start
                payload-length))
              (binary.compiler-incremental-binary-fail!
                reader
                compiler-incremental-error-truncated
                frame-start
                "configuration extension frame is truncated")
              (let
                [payload-end : i64 (+ payload-start payload-length)]
                (begin
                  (set! reader.end payload-end)
                  (let
                    [name : String
                      (binary.compiler-incremental-binary-read-string!
                        reader
                        false)]
                    [value : String
                      (binary.compiler-incremental-binary-read-string!
                        reader
                        false)]
                    (begin
                      (if (and reader.ok? (!= reader.offset payload-end))
                        (binary.compiler-incremental-binary-fail!
                          reader
                          compiler-incremental-error-layout
                          reader.offset
                          "configuration extension has trailing bytes")
                        unit)
                      (set! reader.end outer-end)
                      (if (and
                        reader.ok?
                        (> index 0)
                        (not
                          (stdlib.sort.string-less-borrowed?
                            (& (array-ref extensions (- index 1)).name)
                            (& name))))
                        (binary.compiler-incremental-binary-fail!
                          reader
                          compiler-incremental-error-order
                          frame-start
                          "configuration field names are duplicate or out of order")
                        unit)
                      (if reader.ok?
                        (begin
                          (set!
                            (array-ref extensions index)
                            (CompilerIncrementalConfigField name value))
                          (set! index (+ index 1)))
                        unit)))))))))
      (CompilerIncrementalConfiguration
        target
        profile
        backend
        opt-level
        (= debug-byte 1)
        path-remap
        generated-source-policy
        extensions))))

(define (compiler-incremental-read-input!
  [reader : (&mut reader binary.CompilerIncrementalBinaryReader)]
  [tag : i64]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : CompilerIncrementalInput
  (let
    [input : CompilerIncrementalInput
      (cond
        [(= tag 1)
          (CompilerIncrementalInput.SourceContent
            (binary.compiler-incremental-binary-read-string! reader true)
            (compiler-incremental-read-content! reader limits))]
        [(= tag 2)
          (CompilerIncrementalInput.LogicalName
            (binary.compiler-incremental-binary-read-string! reader false)
            (binary.compiler-incremental-binary-read-string! reader false))]
        [(= tag 3)
          (CompilerIncrementalInput.ImportedSurface
            (binary.compiler-incremental-binary-read-string! reader false)
            (binary.compiler-incremental-binary-read-string! reader false)
            (CompilerIncrementalSemanticOutputIdentity
              (compiler-incremental-read-child! reader limits)))]
        [(= tag 4)
          (CompilerIncrementalInput.ImportedArtifact
            (binary.compiler-incremental-binary-read-string! reader false)
            (binary.compiler-incremental-binary-read-string! reader true)
            (binary.compiler-incremental-binary-read-string! reader false)
            (compiler-incremental-read-child! reader limits))]
        [(= tag 5)
          (CompilerIncrementalInput.PackageProvenance
            (binary.compiler-incremental-binary-read-string! reader false)
            (binary.compiler-incremental-binary-read-string! reader false)
            (compiler-incremental-read-content! reader limits))]
        [(= tag 6)
          (CompilerIncrementalInput.StdlibProvenance
            (binary.compiler-incremental-binary-read-string! reader false)
            (compiler-incremental-read-content! reader limits))]
        [(= tag 7)
          (CompilerIncrementalInput.Configuration
            (compiler-incremental-read-config! reader limits))]
        [(= tag 8)
          (CompilerIncrementalInput.MacroComptime
            (binary.compiler-incremental-binary-read-string! reader false)
            (compiler-incremental-read-child! reader limits)
            (compiler-incremental-read-child! reader limits))]
        [(= tag 9)
          (CompilerIncrementalInput.CodegenTarget
            (binary.compiler-incremental-binary-read-string! reader false)
            (binary.compiler-incremental-binary-read-string! reader false)
            (binary.compiler-incremental-binary-read-string! reader false))]
        [(= tag 10)
          (CompilerIncrementalInput.OrderedChild
            (binary.compiler-incremental-binary-read-string! reader false)
            (binary.compiler-incremental-binary-read-u64! reader)
            (compiler-incremental-read-child! reader limits))]
        [else
          (begin
            (binary.compiler-incremental-binary-fail!
              reader
              compiler-incremental-error-unknown-tag
              (- reader.offset 5)
              "unknown incremental input tag")
            (CompilerIncrementalInput.LogicalName "invalid" ""))])]
    (begin
      (if (if reader.ok?
        (not (compiler-incremental-input-valid? (& input) limits))
        false)
        (binary.compiler-incremental-binary-fail!
          reader
          (compiler-incremental-input-invalid-code (& input) limits)
          reader.offset
          "decoded incremental input is invalid")
        unit)
      input)))

(define (compiler-incremental-ordered-key-eq?
  [left : (& left CompilerIncrementalInput)]
  [right : (& right CompilerIncrementalInput)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view left)
    [(CompilerIncrementalInput.OrderedChild left-sequence left-ordinal _)
      (match (owned_view.compiler-owned-reference-shared-view right)
        [(CompilerIncrementalInput.OrderedChild right-sequence right-ordinal _)
          (and
            (= left-ordinal right-ordinal)
            (compiler-incremental-string-eq?
              (& left-sequence)
              (& right-sequence)))]
        [_ false])]
    [_ false]))

(define (compiler-incremental-identity-decode
  [transcript : (& transcript (__tl_dyn-array u8))]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : ResultCompilerIncrementalDecodedQuery
  (if (not (compiler-incremental-limits-valid? limits))
    (ResultCompilerIncrementalDecodedQuery.Err
      (compiler-incremental-error
        compiler-incremental-error-invalid-limits
        0
        "incremental identity limits are invalid"))
    (if (> (array-length transcript) limits.max-transcript-bytes)
      (ResultCompilerIncrementalDecodedQuery.Err
        (compiler-incremental-error
          compiler-incremental-error-input-limit
          0
          "incremental transcript exceeds input byte limit"))
      (let
        [reader : binary.CompilerIncrementalBinaryReader
          (binary.compiler-incremental-binary-reader
            transcript
            limits.max-work
            limits.max-owned-bytes
            limits.max-string-bytes)]
        [domain : String
          (binary.compiler-incremental-binary-read-string! (&mut reader) false)]
        [schema-offset : i64 reader.offset]
        [schema : i64
          (binary.compiler-incremental-binary-read-u32! (&mut reader))]
        [kind : CompilerIncrementalQueryKind
          (compiler-incremental-read-query-kind! (&mut reader))]
        [build : CompilerIncrementalChildIdentity
          (compiler-incremental-read-child! (&mut reader) limits)]
        [count-offset : i64 reader.offset]
        [count : i64
          (binary.compiler-incremental-binary-read-u32! (&mut reader))]
        [required-depth : i64
          (if (> count 0)
            3
            2)]
        [allocation-ok? : bool
          (if (and
            reader.ok?
            (<= count limits.max-records)
            (>= limits.max-nesting-depth required-depth))
            (compiler-incremental-reader-reserve-owned-records!
              (&mut reader)
              count
              256)
            false)]
        [inputs : (__tl_dyn-array CompilerIncrementalInput)
          (if allocation-ok?
            (__tl_make-array CompilerIncrementalInput count)
            (__tl_make-array CompilerIncrementalInput 0))]
        [index : i64 0]
        [previous-start : i64 -1]
        [previous-length : i64 0]
        (begin
          (if (and
            reader.ok?
            (not
              (compiler-incremental-string-eq?
                (& domain)
                (& compiler-incremental-identity-domain))))
            (binary.compiler-incremental-binary-fail!
              (&mut reader)
              compiler-incremental-error-schema
              0
              "incremental transcript domain is unknown")
            unit)
          (if (and reader.ok? (!= schema compiler-incremental-identity-schema))
            (binary.compiler-incremental-binary-fail!
              (&mut reader)
              compiler-incremental-error-schema
              schema-offset
              "incremental transcript schema is unknown")
            unit)
          (if (and
            reader.ok?
            (not
              (compiler-incremental-string-eq?
                (& build.domain)
                (& compiler-incremental-build-domain))))
            (binary.compiler-incremental-binary-fail!
              (&mut reader)
              compiler-incremental-error-value
              count-offset
              "compiler-build identity has the wrong nominal domain")
            unit)
          (if (and reader.ok? (> count limits.max-records))
            (binary.compiler-incremental-binary-fail!
              (&mut reader)
              compiler-incremental-error-record-limit
              count-offset
              "incremental transcript record count exceeds limit")
            unit)
          (if (and reader.ok? (< limits.max-nesting-depth required-depth))
            (binary.compiler-incremental-binary-fail!
              (&mut reader)
              compiler-incremental-error-depth-limit
              count-offset
              "incremental transcript exceeds the nesting-depth limit")
            unit)
          (while (and reader.ok? (< index count))
            (let
              [frame-start : i64 reader.offset]
              [tag : i64
                (binary.compiler-incremental-binary-read-u8! (&mut reader))]
              [payload-length : i64
                (binary.compiler-incremental-binary-read-u32! (&mut reader))]
              [payload-start : i64 reader.offset]
              [query-end : i64 reader.end]
              (if (> payload-length limits.max-record-bytes)
                (binary.compiler-incremental-binary-fail!
                  (&mut reader)
                  compiler-incremental-error-input-limit
                  frame-start
                  "incremental input frame exceeds its byte limit")
                (if (not
                  (binary.compiler-incremental-binary-range-present?
                    query-end
                    payload-start
                    payload-length))
                  (binary.compiler-incremental-binary-fail!
                    (&mut reader)
                    compiler-incremental-error-truncated
                    frame-start
                    "incremental input frame is truncated")
                  (let
                    [payload-end : i64 (+ payload-start payload-length)]
                    [frame-length : i64 (+ 5 payload-length)]
                    (begin
                      (set! reader.end payload-end)
                      (let
                        [input : CompilerIncrementalInput
                          (compiler-incremental-read-input!
                            (&mut reader)
                            tag
                            limits)]
                        (begin
                          (if (and reader.ok? (!= reader.offset payload-end))
                            (binary.compiler-incremental-binary-fail!
                              (&mut reader)
                              compiler-incremental-error-layout
                              reader.offset
                              "incremental input frame has trailing bytes")
                            unit)
                          (set! reader.end query-end)
                          (if (and
                            reader.ok?
                            (>= previous-start 0)
                            (compiler-incremental-reader-charge-work!
                              (&mut reader)
                              (+ previous-length frame-length))
                            (not
                              (compiler-incremental-range-less?
                                (& reader.bytes)
                                previous-start
                                previous-length
                                frame-start
                                frame-length)))
                            (binary.compiler-incremental-binary-fail!
                              (&mut reader)
                              compiler-incremental-error-order
                              frame-start
                              "incremental input records are duplicate or out of order")
                            unit)
                          (if (and reader.ok? (> index 0))
                            (let
                              [previous : CompilerIncrementalInput
                                (owned_view.compiler-owned-array-element-shared-view
                                  inputs
                                  (- index 1))]
                              (if (compiler-incremental-ordered-key-eq?
                                (& previous)
                                (& input))
                                (binary.compiler-incremental-binary-fail!
                                  (&mut reader)
                                  compiler-incremental-error-order
                                  frame-start
                                  "duplicate ordered-child sequence ordinal")
                                unit))
                            unit)
                          (if reader.ok?
                            (begin
                              (set! (array-ref inputs index) input)
                              (set! previous-start frame-start)
                              (set! previous-length frame-length)
                              (set! index (+ index 1)))
                            unit)))))))))
          (if (and reader.ok? (!= reader.offset (array-length reader.bytes)))
            (binary.compiler-incremental-binary-fail!
              (&mut reader)
              compiler-incremental-error-trailing
              reader.offset
              "incremental transcript has trailing bytes")
            unit)
          (if reader.ok?
            (ResultCompilerIncrementalDecodedQuery.Ok
              (CompilerIncrementalDecodedQuery kind build inputs))
            (ResultCompilerIncrementalDecodedQuery.Err
              (compiler-incremental-reader-error (& reader)))))))))

(define (compiler-incremental-child-eq?
  [left : (& left CompilerIncrementalChildIdentity)]
  [right : (& right CompilerIncrementalChildIdentity)]) : bool
  (and
    (compiler-incremental-string-eq? (& left.domain) (& right.domain))
    (= left.schema right.schema)
    (= left.material-length right.material-length)
    (sha256.digest-eq? (& left.fingerprint) (& right.fingerprint))))

(define (compiler-incremental-query-kind-eq?
  [left : (& left CompilerIncrementalQueryKind)]
  [right : (& right CompilerIncrementalQueryKind)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view left)
    [(CompilerIncrementalQueryKind.Parse)
      (match (owned_view.compiler-owned-reference-shared-view right)
        [(CompilerIncrementalQueryKind.Parse) true]
        [_ false])]
    [(CompilerIncrementalQueryKind.Typecheck)
      (match (owned_view.compiler-owned-reference-shared-view right)
        [(CompilerIncrementalQueryKind.Typecheck) true]
        [_ false])]
    [(CompilerIncrementalQueryKind.Lower)
      (match (owned_view.compiler-owned-reference-shared-view right)
        [(CompilerIncrementalQueryKind.Lower) true]
        [_ false])]
    [(CompilerIncrementalQueryKind.Optimize)
      (match (owned_view.compiler-owned-reference-shared-view right)
        [(CompilerIncrementalQueryKind.Optimize) true]
        [_ false])]
    [(CompilerIncrementalQueryKind.Assembly)
      (match (owned_view.compiler-owned-reference-shared-view right)
        [(CompilerIncrementalQueryKind.Assembly) true]
        [_ false])]
    [(CompilerIncrementalQueryKind.Object)
      (match (owned_view.compiler-owned-reference-shared-view right)
        [(CompilerIncrementalQueryKind.Object) true]
        [_ false])]
    [(CompilerIncrementalQueryKind.IrSummary)
      (match (owned_view.compiler-owned-reference-shared-view right)
        [(CompilerIncrementalQueryKind.IrSummary) true]
        [_ false])]
    [(CompilerIncrementalQueryKind.IrDump left-pass)
      (match (owned_view.compiler-owned-reference-shared-view right)
        [(CompilerIncrementalQueryKind.IrDump right-pass)
          (compiler-incremental-string-eq? (& left-pass) (& right-pass))]
        [_ false])]))

(define (compiler-incremental-identity-metadata-valid?
  [identity : (& identity CompilerIncrementalIdentity)]
  [query : (& query CompilerIncrementalDecodedQuery)]) : bool
  (and
    (= identity.schema compiler-incremental-identity-schema)
    (=
      identity.query-kind-tag
      (compiler-incremental-query-kind-tag (& query.kind)))
    (= identity.record-count (array-length query.inputs))))

(define (compiler-incremental-identity-fingerprint-valid?
  [identity : (& identity CompilerIncrementalIdentity)]) : bool
  (match (compiler-incremental-digest-array (& identity.transcript))
    [(sha256.Sha256FinalizeErr _) false]
    [(sha256.Sha256FinalizeOk actual)
      (sha256.digest-eq? (& actual) (& identity.fingerprint))]))

(define (compiler-incremental-decode-identity-metadata
  [identity : (& identity CompilerIncrementalIdentity)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : ResultCompilerIncrementalDecodedQuery
  (match (compiler-incremental-identity-decode (& identity.transcript) limits)
    [(ResultCompilerIncrementalDecodedQuery.Err error)
      (ResultCompilerIncrementalDecodedQuery.Err error)]
    [(ResultCompilerIncrementalDecodedQuery.Ok query)
      (if (compiler-incremental-identity-metadata-valid? identity (& query))
        (ResultCompilerIncrementalDecodedQuery.Ok query)
        (ResultCompilerIncrementalDecodedQuery.Err
          (compiler-incremental-error
            compiler-incremental-error-fingerprint
            0
            "incremental identity metadata disagrees with transcript")))]))

;; Exact 32-byte fixture boundary expected by the opaque store work in #7023.
;; Store policy and result serialization are intentionally not selected here.
(define (compiler-incremental-identity-store-fingerprint
  [identity : (& identity CompilerIncrementalIdentity)]) : (Array u8 32)
  (sha256.digest-bytes (& identity.fingerprint)))

(define (compiler-incremental-compare-miss
  [category : i64]
  [record-index : i64]
  [path : String]
  [explanation : String]) : CompilerIncrementalCompareResult
  (CompilerIncrementalCompareResult.Miss
    (CompilerIncrementalMiss category record-index path explanation)))

(define (compiler-incremental-input-miss-path
  [input : (& input CompilerIncrementalInput)]) : String
  (match (owned_view.compiler-owned-reference-shared-view input)
    [(CompilerIncrementalInput.SourceContent _ _) "inputs.source-content"]
    [(CompilerIncrementalInput.LogicalName _ _) "inputs.logical-name"]
    [(CompilerIncrementalInput.ImportedSurface _ _ _) "inputs.imported-surface"]
    [(CompilerIncrementalInput.ImportedArtifact _ _ _ _)
      "inputs.imported-artifact"]
    [(CompilerIncrementalInput.PackageProvenance _ _ _)
      "inputs.package-provenance"]
    [(CompilerIncrementalInput.StdlibProvenance _ _) "inputs.stdlib-provenance"]
    [(CompilerIncrementalInput.Configuration _) "inputs.configuration"]
    [(CompilerIncrementalInput.MacroComptime _ _ _) "inputs.macro-comptime"]
    [(CompilerIncrementalInput.CodegenTarget _ _ _) "inputs.codegen-target"]
    [(CompilerIncrementalInput.OrderedChild _ _ _) "inputs.ordered-child"]))

(define (compiler-incremental-decoded-inputs-miss
  [left : (& left CompilerIncrementalDecodedQuery)]
  [right : (& right CompilerIncrementalDecodedQuery)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : CompilerIncrementalCompareResult
  (if (!= (array-length left.inputs) (array-length right.inputs))
    (compiler-incremental-compare-miss
      compiler-incremental-miss-record-count
      -1
      "inputs"
      "canonical input record counts differ")
    (let
      [index : i64 0]
      [different? : bool false]
      [different-kind? : bool false]
      [different-path : String "inputs"]
      (begin
        (while (and (not different?) (< index (array-length left.inputs)))
          (let
            [left-input : CompilerIncrementalInput
              (owned_view.compiler-owned-array-element-shared-view
                left.inputs
                index)]
            [right-input : CompilerIncrementalInput
              (owned_view.compiler-owned-array-element-shared-view
                right.inputs
                index)]
            (if (!=
              (compiler-incremental-input-tag (& left-input))
              (compiler-incremental-input-tag (& right-input)))
              (begin
                (set! different? true)
                (set! different-kind? true)
                (set!
                  different-path
                  (compiler-incremental-input-miss-path (& left-input))))
              (match (compiler-incremental-encode-input (& left-input) limits)
                [(ResultCompilerIncrementalEncodedRecord.Err error)
                  (return (CompilerIncrementalCompareResult.Corrupt error))]
                [(ResultCompilerIncrementalEncodedRecord.Ok left-record)
                  (match (compiler-incremental-encode-input
                    (& right-input)
                    limits)
                    [(ResultCompilerIncrementalEncodedRecord.Err error)
                      (return (CompilerIncrementalCompareResult.Corrupt error))]
                    [(ResultCompilerIncrementalEncodedRecord.Ok right-record)
                      (if (compiler-incremental-record-bytes-eq?
                        (& left-record)
                        (& right-record))
                        (set! index (+ index 1))
                        (begin
                          (set! different? true)
                          (set!
                            different-path
                            (compiler-incremental-input-miss-path
                              (& left-input)))))])]))))
        (if different?
          (compiler-incremental-compare-miss
            (if different-kind?
              compiler-incremental-miss-input-kind
              compiler-incremental-miss-input-value)
            index
            different-path
            (if different-kind?
              "first canonical input record kind differs"
              "first canonical input record value differs"))
          (CompilerIncrementalCompareResult.Corrupt
            (compiler-incremental-error
              compiler-incremental-error-layout
              0
              "distinct canonical transcripts decoded to the same query")))))))

;; Compare complete identities and report the first stable typed difference.
;; Any decode or metadata failure is Corrupt.  Equal claimed digests with
;; distinct canonical transcripts are explicitly a collision miss.
(define (compiler-incremental-identity-compare
  [left : (& left CompilerIncrementalIdentity)]
  [right : (& right CompilerIncrementalIdentity)]
  [limits : (& limits CompilerIncrementalIdentityLimits)]) : CompilerIncrementalCompareResult
  (match (compiler-incremental-decode-identity-metadata left limits)
    [(ResultCompilerIncrementalDecodedQuery.Err error)
      (CompilerIncrementalCompareResult.Corrupt error)]
    [(ResultCompilerIncrementalDecodedQuery.Ok left-query)
      (match (compiler-incremental-decode-identity-metadata right limits)
        [(ResultCompilerIncrementalDecodedQuery.Err error)
          (CompilerIncrementalCompareResult.Corrupt error)]
        [(ResultCompilerIncrementalDecodedQuery.Ok right-query)
          (let
            [same-transcript? : bool
              (binary.compiler-incremental-binary-bytes-eq?
                (& left.transcript)
                (& right.transcript))]
            [same-fingerprint? : bool
              (sha256.digest-eq? (& left.fingerprint) (& right.fingerprint))]
            (cond
              [(and (not same-transcript?) same-fingerprint?)
                (compiler-incremental-compare-miss
                  compiler-incremental-miss-fingerprint-collision
                  -1
                  "fingerprint"
                  "equal SHA-256 fingerprints name distinct canonical transcripts")]
              [(not (compiler-incremental-identity-fingerprint-valid? left))
                (CompilerIncrementalCompareResult.Corrupt
                  (compiler-incremental-error
                    compiler-incremental-error-fingerprint
                    0
                    "left incremental identity fingerprint is corrupt"))]
              [(not (compiler-incremental-identity-fingerprint-valid? right))
                (CompilerIncrementalCompareResult.Corrupt
                  (compiler-incremental-error
                    compiler-incremental-error-fingerprint
                    0
                    "right incremental identity fingerprint is corrupt"))]
              [same-transcript? (CompilerIncrementalCompareResult.Hit)]
              [(not
                  (compiler-incremental-query-kind-eq?
                    (& left-query.kind)
                    (& right-query.kind)))
                (compiler-incremental-compare-miss
                  compiler-incremental-miss-query-kind
                  -1
                  "query-kind"
                  "canonical query kinds differ")]
              [(not
                  (compiler-incremental-child-eq?
                    (& left-query.compiler-build)
                    (& right-query.compiler-build)))
                (compiler-incremental-compare-miss
                  compiler-incremental-miss-compiler-build
                  -1
                  "compiler-build"
                  "canonical compiler-build identities differ")]
              [else
                (compiler-incremental-decoded-inputs-miss
                  (& left-query)
                  (& right-query)
                  limits)]))])]))