;; compiler_surface_facts.tl - relocatable checked-prefix facts shared by
;; package surface producers and consumers.
(import compiler_surface_binary as binary)
(import compiler_surface_identity as surface_identity)
(import stdlib.arena)

;; lint-allow: unused-import -- used by compiler-surface-producer builds.
(import stdlib.byte_buf_core)

(defstruct SurfaceTypecheckFacts
  (macro-prefix-decl-count i64)
  (prefix-decl-count i64)
  (summary-values i64)
  (summary-functions i64)
  (summary-externs i64)
  (clone-decl-keys (Array i64))
  (clone-root-keys (Array i64))
  (clone-call-indices (Array i64)))

(defenum ResultSurfaceTypecheckFactBytes
  (Ok (Array u8))
  (Err String))

(defenum ResultSurfaceTypecheckFacts
  (Ok SurfaceTypecheckFacts)
  (Err String))

(defstruct SurfaceTypecheckFactReader
  (bytes (Array u8))
  (offset (Array i64))
  (ok (Array bool))
  (message (Array String)))

(defstruct SurfaceCloneObservation
  (decl-key i64)
  (root-key i64)
  (call-index i64))

(defstruct SurfaceCloneObservationSeq
  (slots (Array SurfaceCloneObservation))
  (len i64))

(define (surface-clone-observation-seq-empty) : SurfaceCloneObservationSeq
  (SurfaceCloneObservationSeq (make-array SurfaceCloneObservation 0) 0))

(define (surface-clone-observation-copy-range!
  [dst : (&mut dst (Array SurfaceCloneObservation))]
  [src : (& src (Array SurfaceCloneObservation))]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (surface-clone-observation-seq-grow!
  [seq : (&mut seq SurfaceCloneObservationSeq)]) : unit
  (let
    [count : i64 (struct-get seq len)]
    [bigger : (Array SurfaceCloneObservation)
      (make-array
        SurfaceCloneObservation
        (if (< count 1)
          16
          (* count 2)))]
    (begin
      (surface-clone-observation-copy-range!
        (&mut bigger)
        (& (struct-get seq slots))
        count)
      (set! (struct-get seq slots) bigger))))

(define (surface-clone-observation-seq-push!
  [seq : (&mut seq SurfaceCloneObservationSeq)]
  [observation : SurfaceCloneObservation]) : unit
  (begin
    (if (< (struct-get seq len) (array-length (struct-get seq slots)))
      unit
      (surface-clone-observation-seq-grow! seq))
    (let
      [index : i64 (struct-get seq len)]
      (begin
        (array-set! (struct-get seq slots) index observation)
        (set! (struct-get seq len) (+ index 1))))))

(define surface-typecheck-facts-magic : i64
  6073461667468337970)
(define surface-typecheck-facts-schema-version : i64
  1)
(define surface-typecheck-facts-max-clone-observations : i64
  1048576)

(define (surface-typecheck-facts-empty) : SurfaceTypecheckFacts
  (SurfaceTypecheckFacts
    0
    0
    0
    0
    0
    (make-array i64 0)
    (make-array i64 0)
    (make-array i64 0)))

(define surface-typecheck-facts-installed : bool
  false)
(define surface-typecheck-facts-installed-value : SurfaceTypecheckFacts
  (surface-typecheck-facts-empty))

(define (surface-typecheck-facts-install! [facts : SurfaceTypecheckFacts]) : unit
  (begin
    (set! surface-typecheck-facts-installed-value facts)
    (set! surface-typecheck-facts-installed true)))

(define (surface-typecheck-facts-clear!) : unit
  (begin
    (set! surface-typecheck-facts-installed false)
    (set!
      surface-typecheck-facts-installed-value
      (surface-typecheck-facts-empty))))

(define (surface-typecheck-facts-active?) : bool
  surface-typecheck-facts-installed)

(define (surface-typecheck-facts-current) : SurfaceTypecheckFacts
  surface-typecheck-facts-installed-value)

(define surface-typecheck-facts-recording-active : bool
  false)
(define surface-typecheck-facts-recording-arena : i64
  0)
(define surface-typecheck-facts-recording-decl-key : i64
  -1)
(define surface-typecheck-facts-recording-observations : SurfaceCloneObservationSeq
  (surface-clone-observation-seq-empty))
(define surface-typecheck-facts-recording-next-call : i64
  0)
(define surface-typecheck-facts-recording-current-call : i64
  -1)

(define (surface-typecheck-facts-recording-start! [arena-handle : i64]) : unit
  (begin
    (set! surface-typecheck-facts-recording-arena arena-handle)
    (set! surface-typecheck-facts-recording-decl-key -1)
    (set!
      surface-typecheck-facts-recording-observations
      (surface-clone-observation-seq-empty))
    (set! surface-typecheck-facts-recording-next-call 0)
    (set! surface-typecheck-facts-recording-current-call -1)
    (set! surface-typecheck-facts-recording-active true)))

(define (surface-typecheck-facts-recording-select-decl! [decl-key : i64]) : unit
  (if surface-typecheck-facts-recording-active
    (set! surface-typecheck-facts-recording-decl-key decl-key)
    unit))

(define (surface-typecheck-facts-recording-start-clone-call!) : unit
  (if surface-typecheck-facts-recording-active
    (begin
      (set!
        surface-typecheck-facts-recording-current-call
        surface-typecheck-facts-recording-next-call)
      (set!
        surface-typecheck-facts-recording-next-call
        (+ surface-typecheck-facts-recording-next-call 1)))
    unit))

(define (surface-typecheck-facts-recording-note-clone-root! [root-key : i64]) : unit
  (if (and
    surface-typecheck-facts-recording-active
    (>= surface-typecheck-facts-recording-decl-key 0)
    (>= surface-typecheck-facts-recording-current-call 0)
    (>= root-key 0))
    (let
      [previous-arena : i64 (arena.tl_arena_current)]
      (begin
        (unsafe
          (arena.tl_arena_set surface-typecheck-facts-recording-arena))
        (surface-clone-observation-seq-push!
          (&mut surface-typecheck-facts-recording-observations)
          (SurfaceCloneObservation
            surface-typecheck-facts-recording-decl-key
            root-key
            surface-typecheck-facts-recording-current-call))
        (set! surface-typecheck-facts-recording-arena (arena.tl_arena_current))
        (unsafe
          (arena.tl_arena_set previous-arena))))
    unit))

(define (surface-typecheck-facts-recording-finish
  [macro-prefix-decl-count : i64]
  [prefix-decl-count : i64]
  [summary-values : i64]
  [summary-functions : i64]
  [summary-externs : i64]) : SurfaceTypecheckFacts
  (let
    [count : i64
      (struct-get surface-typecheck-facts-recording-observations len)]
    [decl-keys : (Array i64) (make-array i64 count)]
    [root-keys : (Array i64) (make-array i64 count)]
    [call-indices : (Array i64) (make-array i64 count)]
    [index : i64 0]
    [slots : (Array SurfaceCloneObservation)
      (struct-get surface-typecheck-facts-recording-observations slots)]
    (begin
      (while (< index count)
        (let
          [observation : SurfaceCloneObservation (array-ref slots index)]
          (begin
            (array-set! decl-keys index (struct-get observation decl-key))
            (array-set! root-keys index (struct-get observation root-key))
            (array-set! call-indices index (struct-get observation call-index))
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
        call-indices))))

(define (surface-typecheck-facts-recording-abort!) : unit
  (begin
    (set! surface-typecheck-facts-recording-active false)
    (set! surface-typecheck-facts-recording-arena 0)
    (set! surface-typecheck-facts-recording-decl-key -1)
    (set!
      surface-typecheck-facts-recording-observations
      (surface-clone-observation-seq-empty))
    (set! surface-typecheck-facts-recording-next-call 0)
    (set! surface-typecheck-facts-recording-current-call -1)))

(define (surface-typecheck-facts-recording?) : bool
  surface-typecheck-facts-recording-active)

(define (surface-typecheck-facts-valid? [facts : SurfaceTypecheckFacts]) : bool
  (let
    [decl-keys : (Array i64) (struct-get facts clone-decl-keys)]
    [root-keys : (Array i64) (struct-get facts clone-root-keys)]
    [call-indices : (Array i64) (struct-get facts clone-call-indices)]
    (and
      (> (struct-get facts macro-prefix-decl-count) 0)
      (> (struct-get facts prefix-decl-count) 0)
      (>= (struct-get facts summary-values) 0)
      (>= (struct-get facts summary-functions) 0)
      (>= (struct-get facts summary-externs) 0)
      (= (array-length decl-keys) (array-length root-keys))
      (= (array-length decl-keys) (array-length call-indices))
      (<=
        (array-length decl-keys)
        surface-typecheck-facts-max-clone-observations))))

(cfg
  compiler-surface-producer
  (define (surface-typecheck-facts-encode
    [facts : SurfaceTypecheckFacts]
    [source-count : i64]
    [identity-count : i64]) : ResultSurfaceTypecheckFactBytes
    (if (not (surface-typecheck-facts-valid? facts))
      (ResultSurfaceTypecheckFactBytes.Err
        "surface facts: invalid checked-prefix facts")
      (let
        [decl-keys : (Array i64) (struct-get facts clone-decl-keys)]
        [root-keys : (Array i64) (struct-get facts clone-root-keys)]
        [call-indices : (Array i64) (struct-get facts clone-call-indices)]
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
            (struct-get facts macro-prefix-decl-count))
          (binary.surface-binary-push-u64!
            (&mut out)
            (struct-get facts prefix-decl-count))
          (binary.surface-binary-push-u64!
            (&mut out)
            (struct-get facts summary-values))
          (binary.surface-binary-push-u64!
            (&mut out)
            (struct-get facts summary-functions))
          (binary.surface-binary-push-u64!
            (&mut out)
            (struct-get facts summary-externs))
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

(define (surface-typecheck-fact-reader-new [bytes : (Array u8)]) : SurfaceTypecheckFactReader
  (let
    [offset : (Array i64) (make-array i64 1)]
    [ok : (Array bool) (make-array bool 1)]
    [message : (Array String) (make-array String 1)]
    (begin
      (array-set! offset 0 0)
      (array-set! ok 0 true)
      (array-set! message 0 "")
      (SurfaceTypecheckFactReader bytes offset ok message))))

(define (surface-typecheck-fact-reader-fail!
  [reader : SurfaceTypecheckFactReader]
  [message : String]) : unit
  (if (array-ref (struct-get reader ok) 0)
    (begin
      (array-set! (struct-get reader ok) 0 false)
      (array-set! (struct-get reader message) 0 message))
    unit))

(define (surface-typecheck-fact-reader-u64!
  [reader : SurfaceTypecheckFactReader]) : i64
  (let
    [offset : i64 (array-ref (struct-get reader offset) 0)]
    [bytes : (Array u8) (struct-get reader bytes)]
    (if (or
      (not (array-ref (struct-get reader ok) 0))
      (> offset (- (array-length bytes) 8)))
      (begin
        (surface-typecheck-fact-reader-fail!
          reader
          "surface facts: truncated u64")
        -1)
      (begin
        (array-set! (struct-get reader offset) 0 (+ offset 8))
        (binary.surface-binary-read-u64 bytes offset)))))

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
  [bytes : (Array u8)]
  [remap : (Array i64)]) : ResultSurfaceTypecheckFacts
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
        [decl-keys : (Array i64) (make-array i64 clone-count)]
        [root-keys : (Array i64) (make-array i64 clone-count)]
        [call-indices : (Array i64) (make-array i64 clone-count)]
        [identity-count : i64 (array-length remap)]
        [index : i64 0]
        (begin
          (while (and
            (array-ref (struct-get reader ok) 0)
            (< index clone-count))
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
                  (array-set!
                    decl-keys
                    index
                    (surface_identity.surface-identity-resolve-portable-id
                      decl-key
                      remap))
                  (array-set!
                    root-keys
                    index
                    (surface_identity.surface-identity-resolve-portable-id
                      root-key
                      remap))
                  (array-set! call-indices index call-index)
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
              [(not (array-ref (struct-get reader ok) 0))
                (ResultSurfaceTypecheckFacts.Err
                  (array-ref (struct-get reader message) 0))]
              [(not
                  (=
                    (array-ref (struct-get reader offset) 0)
                    (array-length bytes)))
                (ResultSurfaceTypecheckFacts.Err
                  "surface facts: trailing payload bytes")]
              [(not (surface-typecheck-facts-valid? facts))
                (ResultSurfaceTypecheckFacts.Err
                  "surface facts: invalid checked-prefix facts")]
              [else (ResultSurfaceTypecheckFacts.Ok facts)])))))))