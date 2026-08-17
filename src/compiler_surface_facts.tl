;; compiler_surface_facts.tl - relocatable checked-prefix facts shared by
;; package surface producers and consumers.
(import compiler_surface_binary as binary)
(import compiler_surface_identity as surface_identity)
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import stdlib.arena))
(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (import stdlib.byte_buf_core))

(defmacro (surface-facts-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(defmacro (surface-facts-array-shared-view [items : Expr] [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (array-data ,items) ,index))))

(defstruct SurfaceTypecheckFacts
  (macro-prefix-decl-count i64)
  (prefix-decl-count i64)
  (summary-values i64)
  (summary-functions i64)
  (summary-externs i64)
  (clone-decl-keys (__tl_dyn-array i64))
  (clone-root-keys (__tl_dyn-array i64))
  (clone-call-indices (__tl_dyn-array i64)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (defenum ResultSurfaceTypecheckFactBytes
    (Ok (__tl_dyn-array u8))
    (Err String)))

(defenum ResultSurfaceTypecheckFacts
  (Ok SurfaceTypecheckFacts)
  (Err String))

(defstruct SurfaceTypecheckFactReader
  (bytes (__tl_dyn-array u8))
  (offset (__tl_dyn-array i64))
  (ok (__tl_dyn-array bool))
  (message (__tl_dyn-array String)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (defstruct SurfaceCloneObservation
    (decl-key i64)
    (root-key i64)
    (call-index i64)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (defstruct SurfaceCloneObservationSeq
    (slots (__tl_dyn-array SurfaceCloneObservation))
    (len i64)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-clone-observation-seq-empty) : SurfaceCloneObservationSeq
    (SurfaceCloneObservationSeq (__tl_make-array SurfaceCloneObservation 0) 0)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-clone-observation-copy-range!
    [dst : (&mut dst (__tl_dyn-array SurfaceCloneObservation))]
    [src : (& src (__tl_dyn-array SurfaceCloneObservation))]
    [count : i64]) : unit
    (let
      [index : i64 0]
      (while (< index count)
        (begin
          (set! (array-ref dst index) (array-ref src index))
          (set! index (+ index 1)))))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-clone-observation-seq-grow!
    [seq : (&mut seq SurfaceCloneObservationSeq)]) : unit
    (let
      [count : i64 seq.len]
      [bigger : (__tl_dyn-array SurfaceCloneObservation)
        (__tl_make-array
          SurfaceCloneObservation
          (if (< count 1)
            16
            (* count 2)))]
      (begin
        (surface-clone-observation-copy-range!
          (&mut bigger)
          (& seq.slots)
          count)
        (set! seq.slots bigger)))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-clone-observation-seq-push!
    [seq : (&mut seq SurfaceCloneObservationSeq)]
    [observation : SurfaceCloneObservation]) : unit
    (begin
      (if (< seq.len (array-length seq.slots))
        unit
        (surface-clone-observation-seq-grow! seq))
      (let
        [index : i64 seq.len]
        (begin
          (set! (array-ref seq.slots index) observation)
          (set! seq.len (+ index 1)))))))

(define surface-typecheck-facts-magic : i64
  6073461667468337970)
(define surface-typecheck-facts-schema-version : i64
  1)

;; Keep composed prefixes within the same deterministic allocation budget as
;; the frontend AST codec. Apart from bounding allocations, checking every sum
;; against this cap makes wrapped i64 arithmetic unreachable.
(define surface-typecheck-facts-max-count : i64
  8388608)
(define surface-typecheck-facts-max-clone-observations : i64
  1048576)

(define (surface-typecheck-facts-empty) : SurfaceTypecheckFacts
  (SurfaceTypecheckFacts
    0
    0
    0
    0
    0
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)))

(define surface-typecheck-facts-installed : bool
  false)
(define surface-typecheck-facts-installed-value : (__tl_dyn-array
    SurfaceTypecheckFacts)
  (__tl_make-array (surface-typecheck-facts-empty)))

(define (surface-typecheck-facts-installed-shared-view) : SurfaceTypecheckFacts
  (unsafe
    (ptr-read
      (ptr-cast
        (array-data surface-typecheck-facts-installed-value)
        : (Ptr SurfaceTypecheckFacts)))))

(define (surface-typecheck-facts-clear!) : unit
  (begin
    (set! surface-typecheck-facts-installed false)
    (set!
      (array-ref surface-typecheck-facts-installed-value 0)
      (surface-typecheck-facts-empty))))

(define (surface-typecheck-facts-active?) : bool
  surface-typecheck-facts-installed)

(define (surface-typecheck-facts-current) : SurfaceTypecheckFacts
  (surface-typecheck-facts-installed-shared-view))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define surface-typecheck-facts-recording-active : bool
    false))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define surface-typecheck-facts-recording-arena : i64
    0))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define surface-typecheck-facts-recording-decl-key : i64
    -1))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define surface-typecheck-facts-recording-observations : SurfaceCloneObservationSeq
    (surface-clone-observation-seq-empty)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-typecheck-facts-recording-observations-shared-view) : SurfaceCloneObservationSeq
    (cfg
      stage0-seed-bootstrap
      surface-typecheck-facts-recording-observations
      (unsafe
        (ptr-read (ptr-addr-of surface-typecheck-facts-recording-observations))))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define surface-typecheck-facts-recording-next-call : i64
    0))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define surface-typecheck-facts-recording-current-call : i64
    -1))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-typecheck-facts-recording-start! [arena-handle : i64]) : unit
    (begin
      (set! surface-typecheck-facts-recording-arena arena-handle)
      (set! surface-typecheck-facts-recording-decl-key -1)
      (set!
        surface-typecheck-facts-recording-observations
        (surface-clone-observation-seq-empty))
      (set! surface-typecheck-facts-recording-next-call 0)
      (set! surface-typecheck-facts-recording-current-call -1)
      (set! surface-typecheck-facts-recording-active true))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-typecheck-facts-recording-select-decl! [decl-key : i64]) : unit
    (if surface-typecheck-facts-recording-active
      (set! surface-typecheck-facts-recording-decl-key decl-key)
      unit)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-typecheck-facts-recording-start-clone-call!) : unit
    (if surface-typecheck-facts-recording-active
      (begin
        (set!
          surface-typecheck-facts-recording-current-call
          surface-typecheck-facts-recording-next-call)
        (set!
          surface-typecheck-facts-recording-next-call
          (+ surface-typecheck-facts-recording-next-call 1)))
      unit)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-typecheck-facts-recording-note-clone-root! [root-key : i64]) : unit
    (if (and
      surface-typecheck-facts-recording-active
      (>= surface-typecheck-facts-recording-decl-key 0)
      (>= surface-typecheck-facts-recording-current-call 0)
      (>= root-key 0))
      (in-arena
        (arena.Arena surface-typecheck-facts-recording-arena)
        (surface-clone-observation-seq-push!
          (&mut surface-typecheck-facts-recording-observations)
          (SurfaceCloneObservation
            surface-typecheck-facts-recording-decl-key
            root-key
            surface-typecheck-facts-recording-current-call)))
      unit)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-typecheck-facts-recording-finish
    [macro-prefix-decl-count : i64]
    [prefix-decl-count : i64]
    [summary-values : i64]
    [summary-functions : i64]
    [summary-externs : i64]) : SurfaceTypecheckFacts
    (let
      [observations : SurfaceCloneObservationSeq
        (surface-typecheck-facts-recording-observations-shared-view)]
      [count : i64 observations.len]
      [decl-keys : (__tl_dyn-array i64) (make-array i64 count)]
      [root-keys : (__tl_dyn-array i64) (make-array i64 count)]
      [call-indices : (__tl_dyn-array i64) (make-array i64 count)]
      [index : i64 0]
      [slots : (__tl_dyn-array SurfaceCloneObservation)
        (surface-facts-shared-view observations.slots)]
      (begin
        (while (< index count)
          (let
            [observation : SurfaceCloneObservation (array-ref slots index)]
            (begin
              (set! (array-ref decl-keys index) observation.decl-key)
              (set! (array-ref root-keys index) observation.root-key)
              (set! (array-ref call-indices index) observation.call-index)
              (set! index (+ index 1)))))
        (set! surface-typecheck-facts-recording-active false)
        (set! surface-typecheck-facts-recording-arena 0)
        (set! surface-typecheck-facts-recording-decl-key -1)
        (set!
          surface-typecheck-facts-recording-observations
          (surface-clone-observation-seq-empty))
        (set! surface-typecheck-facts-recording-next-call 0)
        (set! surface-typecheck-facts-recording-current-call -1)
        (SurfaceTypecheckFacts
          macro-prefix-decl-count
          prefix-decl-count
          summary-values
          summary-functions
          summary-externs
          decl-keys
          root-keys
          call-indices)))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-typecheck-facts-recording-abort!) : unit
    (begin
      (set! surface-typecheck-facts-recording-active false)
      (set! surface-typecheck-facts-recording-arena 0)
      (set! surface-typecheck-facts-recording-decl-key -1)
      (set!
        surface-typecheck-facts-recording-observations
        (surface-clone-observation-seq-empty))
      (set! surface-typecheck-facts-recording-next-call 0)
      (set! surface-typecheck-facts-recording-current-call -1))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-typecheck-facts-recording?) : bool
    surface-typecheck-facts-recording-active))

(define (surface-typecheck-facts-count-valid? [count : i64]) : bool
  (and (>= count 0) (<= count surface-typecheck-facts-max-count)))

(define (surface-typecheck-facts-positive-count-valid? [count : i64]) : bool
  (and (> count 0) (<= count surface-typecheck-facts-max-count)))

(define (surface-typecheck-facts-observations-valid?
  [decl-keys : (& decl-keys (__tl_dyn-array i64))]
  [root-keys : (& root-keys (__tl_dyn-array i64))]
  [call-indices : (& call-indices (__tl_dyn-array i64))]) : bool
  (let
    [count : i64 (array-length decl-keys)]
    [index : i64 0]
    [ok : bool
      (and
        (= count (array-length root-keys))
        (= count (array-length call-indices))
        (<= count surface-typecheck-facts-max-clone-observations))]
    (begin
      (while (and ok (< index count))
        (let
          [decl-key : i64 (array-ref decl-keys index)]
          [root-key : i64 (array-ref root-keys index)]
          [call-index : i64 (array-ref call-indices index)]
          (if (and
            (>= decl-key 0)
            (>= root-key 0)
            (>= call-index 0)
            (< call-index surface-typecheck-facts-max-count)
            (or
              (= index 0)
              (and
                (>= call-index (array-ref call-indices (- index 1)))
                (or
                  (not (= call-index (array-ref call-indices (- index 1))))
                  (= decl-key (array-ref decl-keys (- index 1)))))))
            (set! index (+ index 1))
            (set! ok false))))
      ok)))

(define (surface-typecheck-facts-valid?
  [facts : (& facts SurfaceTypecheckFacts)]) : bool
  (and
    (surface-typecheck-facts-positive-count-valid?
      facts.macro-prefix-decl-count)
    (surface-typecheck-facts-positive-count-valid? facts.prefix-decl-count)
    (surface-typecheck-facts-count-valid? facts.summary-values)
    (surface-typecheck-facts-count-valid? facts.summary-functions)
    (surface-typecheck-facts-count-valid? facts.summary-externs)
    (surface-typecheck-facts-observations-valid?
      facts.clone-decl-keys
      facts.clone-root-keys
      facts.clone-call-indices)))

;; Publishing validates first and changes both installed fields only on success,
;; so a rejected candidate cannot disturb the previously active prefix.
(define (surface-typecheck-facts-publish! [facts : SurfaceTypecheckFacts]) : bool
  (if (surface-typecheck-facts-valid? facts)
    (begin
      (set! (array-ref surface-typecheck-facts-installed-value 0) facts)
      (set! surface-typecheck-facts-installed true)
      true)
    false))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-i64-array-eq?
    [left : (__tl_dyn-array i64)]
    [right : (__tl_dyn-array i64)]) : bool
    (let
      [index : i64 0]
      [ok : bool (= (array-length left) (array-length right))]
      (begin
        (while (and ok (< index (array-length left)))
          (if (= (array-ref left index) (array-ref right index))
            (set! index (+ index 1))
            (set! ok false)))
        ok))))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-eq?
    [left : SurfaceTypecheckFacts]
    [right : SurfaceTypecheckFacts]) : bool
    (and
      (= left.macro-prefix-decl-count right.macro-prefix-decl-count)
      (= left.prefix-decl-count right.prefix-decl-count)
      (= left.summary-values right.summary-values)
      (= left.summary-functions right.summary-functions)
      (= left.summary-externs right.summary-externs)
      (surface-typecheck-facts-i64-array-eq?
        left.clone-decl-keys
        right.clone-decl-keys)
      (surface-typecheck-facts-i64-array-eq?
        left.clone-root-keys
        right.clone-root-keys)
      (surface-typecheck-facts-i64-array-eq?
        left.clone-call-indices
        right.clone-call-indices))))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-test-fragment-one) : SurfaceTypecheckFacts
    (SurfaceTypecheckFacts
      2
      3
      5
      7
      11
      (__tl_make-array 10 10 11)
      (__tl_make-array 20 21 22)
      (__tl_make-array 0 0 2))))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-tests-ok?) : bool
    (let
      [first : SurfaceTypecheckFacts
        (surface-typecheck-facts-test-fragment-one)]
      [bad-order : SurfaceTypecheckFacts
        (SurfaceTypecheckFacts
          1
          1
          0
          0
          0
          (__tl_make-array 50 50)
          (__tl_make-array 60 61)
          (__tl_make-array 1 0))]
      [bad-group : SurfaceTypecheckFacts
        (SurfaceTypecheckFacts
          1
          1
          0
          0
          0
          (__tl_make-array 50 51)
          (__tl_make-array 60 61)
          (__tl_make-array 0 0))]
      [ok : bool true]
      (begin
        (if (or
          (not (surface-typecheck-facts-valid? first))
          (surface-typecheck-facts-valid? bad-order)
          (surface-typecheck-facts-valid? bad-group))
          (set! ok false)
          unit)
        (surface-typecheck-facts-clear!)
        (if (surface-typecheck-facts-publish! first)
          unit
          (set! ok false))
        ;; Invalid publication is atomic: the active first fragment survives.
        (if (surface-typecheck-facts-publish! bad-order)
          (set! ok false)
          unit)
        (if (and
          (surface-typecheck-facts-active?)
          (surface-typecheck-facts-eq? (surface-typecheck-facts-current) first))
          unit
          (set! ok false))
        (surface-typecheck-facts-clear!)
        (if (surface-typecheck-facts-active?)
          (set! ok false)
          unit)
        ;; A cleared publication can be reused without retaining stale facts.
        (if (surface-typecheck-facts-publish! first)
          unit
          (set! ok false))
        (if (and
          (surface-typecheck-facts-active?)
          (surface-typecheck-facts-eq? (surface-typecheck-facts-current) first))
          unit
          (set! ok false))
        (surface-typecheck-facts-clear!)
        ok))))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-selftest-main) : i64
    (if (surface-typecheck-facts-tests-ok?)
      42
      1)))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-typecheck-facts-encode
    [facts : SurfaceTypecheckFacts]
    [source-count : i64]
    [identity-count : i64]) : ResultSurfaceTypecheckFactBytes
    (if (not (surface-typecheck-facts-valid? facts))
      (ResultSurfaceTypecheckFactBytes.Err
        "surface facts: invalid checked-prefix facts")
      (let
        [decl-keys : (__tl_dyn-array i64) facts.clone-decl-keys]
        [root-keys : (__tl_dyn-array i64) facts.clone-root-keys]
        [call-indices : (__tl_dyn-array i64) facts.clone-call-indices]
        [out : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-new)]
        [index : i64 0]
        [ok : bool true]
        (begin
          (binary.surface-binary-push-u64!
            (&mut out)
            surface-typecheck-facts-magic)
          (binary.surface-binary-push-u64!
            (&mut out)
            surface-typecheck-facts-schema-version)
          (binary.surface-binary-push-u64!
            (&mut out)
            facts.macro-prefix-decl-count)
          (binary.surface-binary-push-u64! (&mut out) facts.prefix-decl-count)
          (binary.surface-binary-push-u64! (&mut out) facts.summary-values)
          (binary.surface-binary-push-u64! (&mut out) facts.summary-functions)
          (binary.surface-binary-push-u64! (&mut out) facts.summary-externs)
          (binary.surface-binary-push-u64! (&mut out) (array-length decl-keys))
          (while (and ok (< index (array-length decl-keys)))
            (let
              [decl-key : i64
                (surface_identity.surface-identity-portable-id
                  (array-ref decl-keys index)
                  source-count
                  identity-count)]
              [root-key : i64
                (surface_identity.surface-identity-portable-id
                  (array-ref root-keys index)
                  source-count
                  identity-count)]
              (if (or (< decl-key 0) (< root-key 0))
                (set! ok false)
                (begin
                  (binary.surface-binary-push-u64! (&mut out) decl-key)
                  (binary.surface-binary-push-u64! (&mut out) root-key)
                  (binary.surface-binary-push-u64!
                    (&mut out)
                    (array-ref call-indices index))
                  (set! index (+ index 1))))))
          (if ok
            (ResultSurfaceTypecheckFactBytes.Ok
              (byte_buf_core.byte-buf-builder-finish-array (& out)))
            (ResultSurfaceTypecheckFactBytes.Err
              "surface facts: identity is not relocatable")))))))

(define (surface-typecheck-fact-reader-new [bytes : (__tl_dyn-array u8)]) : SurfaceTypecheckFactReader
  (let
    [offset : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [ok : (__tl_dyn-array bool) (__tl_make-array bool 1)]
    [message : (__tl_dyn-array String) (__tl_make-array String 1)]
    (begin
      (set! (array-ref offset 0) 0)
      (set! (array-ref ok 0) true)
      (set! (array-ref message 0) "")
      (SurfaceTypecheckFactReader bytes offset ok message))))

(define (surface-typecheck-fact-reader-fail!
  [reader : (& reader SurfaceTypecheckFactReader)]
  [message : String]) : unit
  (if (array-ref reader.ok 0)
    (begin
      (set! (array-ref reader.ok 0) false)
      (set! (array-ref reader.message 0) message))
    unit))

(define (surface-typecheck-fact-reader-u64!
  [reader : (& reader SurfaceTypecheckFactReader)]) : i64
  (let
    [offset : i64 (array-ref reader.offset 0)]
    (if (or
      (not (array-ref reader.ok 0))
      (> offset (- (array-length reader.bytes) 8)))
      (begin
        (surface-typecheck-fact-reader-fail!
          reader
          "surface facts: truncated u64")
        -1)
      (begin
        (set! (array-ref reader.offset 0) (+ offset 8))
        (binary.surface-binary-read-u64 reader.bytes offset)))))

(define (surface-typecheck-facts-portable-id-valid?
  [id : i64]
  [identity-count : i64]) : bool
  (let
    [identity-count2 : i64 (* identity-count identity-count)]
    [triple-offset : i64 (+ identity-count identity-count2)]
    (or
      (and (>= id 0) (< id identity-count))
      (and (>= id identity-count) (< id (+ identity-count identity-count2)))
      (and
        (>= id triple-offset)
        (< id (+ triple-offset (* identity-count2 identity-count)))))))

(define (surface-typecheck-facts-decode
  [bytes : (__tl_dyn-array u8)]
  [remap : (__tl_dyn-array i64)]) : ResultSurfaceTypecheckFacts
  (let
    [reader : SurfaceTypecheckFactReader
      (surface-typecheck-fact-reader-new bytes)]
    [magic : i64 (surface-typecheck-fact-reader-u64! reader)]
    [schema : i64 (surface-typecheck-fact-reader-u64! reader)]
    [macro-prefix-decl-count : i64 (surface-typecheck-fact-reader-u64! reader)]
    [prefix-decl-count : i64 (surface-typecheck-fact-reader-u64! reader)]
    [summary-values : i64 (surface-typecheck-fact-reader-u64! reader)]
    [summary-functions : i64 (surface-typecheck-fact-reader-u64! reader)]
    [summary-externs : i64 (surface-typecheck-fact-reader-u64! reader)]
    [clone-count : i64 (surface-typecheck-fact-reader-u64! reader)]
    (if (or
      (not (= magic surface-typecheck-facts-magic))
      (not (= schema surface-typecheck-facts-schema-version))
      (<= macro-prefix-decl-count 0)
      (<= prefix-decl-count 0)
      (< summary-values 0)
      (< summary-functions 0)
      (< summary-externs 0)
      (< clone-count 0)
      (> clone-count surface-typecheck-facts-max-clone-observations))
      (ResultSurfaceTypecheckFacts.Err
        "surface facts: bad magic, schema, or count")
      (let
        [decl-keys : (__tl_dyn-array i64) (__tl_make-array i64 clone-count)]
        [root-keys : (__tl_dyn-array i64) (__tl_make-array i64 clone-count)]
        [call-indices : (__tl_dyn-array i64) (__tl_make-array i64 clone-count)]
        [identity-count : i64 (array-length remap)]
        [index : i64 0]
        (begin
          (while (and (array-ref reader.ok 0) (< index clone-count))
            (let
              [decl-key : i64 (surface-typecheck-fact-reader-u64! reader)]
              [root-key : i64 (surface-typecheck-fact-reader-u64! reader)]
              [call-index : i64 (surface-typecheck-fact-reader-u64! reader)]
              (if (or
                (not
                  (surface-typecheck-facts-portable-id-valid?
                    decl-key
                    identity-count))
                (not
                  (surface-typecheck-facts-portable-id-valid?
                    root-key
                    identity-count))
                (< call-index 0))
                (surface-typecheck-fact-reader-fail!
                  reader
                  "surface facts: invalid identity reference")
                (begin
                  (set!
                    (array-ref decl-keys index)
                    (surface_identity.surface-identity-resolve-portable-id
                      decl-key
                      remap))
                  (set!
                    (array-ref root-keys index)
                    (surface_identity.surface-identity-resolve-portable-id
                      root-key
                      remap))
                  (set! (array-ref call-indices index) call-index)
                  (set! index (+ index 1))))))
          (let
            [facts : SurfaceTypecheckFacts
              (SurfaceTypecheckFacts
                macro-prefix-decl-count
                prefix-decl-count
                summary-values
                summary-functions
                summary-externs
                decl-keys
                root-keys
                call-indices)]
            (cond
              [(not (array-ref reader.ok 0))
                (ResultSurfaceTypecheckFacts.Err
                  (surface-facts-array-shared-view reader.message 0))]
              [(not (= (array-ref reader.offset 0) (array-length reader.bytes)))
                (ResultSurfaceTypecheckFacts.Err
                  "surface facts: trailing payload bytes")]
              [(not (surface-typecheck-facts-valid? facts))
                (ResultSurfaceTypecheckFacts.Err
                  "surface facts: invalid checked-prefix facts")]
              [else (ResultSurfaceTypecheckFacts.Ok facts)])))))))