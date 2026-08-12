;; compiler_surface_facts.tl - relocatable checked-prefix facts shared by
;; package surface producers and consumers.
(import compiler_surface_binary as binary)
(import compiler_surface_identity as surface_identity)
(cfg compiler-surface-producer (import stdlib.arena))
(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (import stdlib.byte_buf_core))

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
  compiler-surface-producer
  (defenum ResultSurfaceTypecheckFactBytes
    (Ok (__tl_dyn-array u8))
    (Err String)))

(defenum ResultSurfaceTypecheckFacts
  (Ok SurfaceTypecheckFacts)
  (Err String))

(defstruct SurfaceTypecheckFactsBuilder
  (fragment-count i64)
  (macro-prefix-decl-count i64)
  (prefix-decl-count i64)
  (summary-values i64)
  (summary-functions i64)
  (summary-externs i64)
  (clone-decl-keys (__tl_dyn-array i64))
  (clone-root-keys (__tl_dyn-array i64))
  (clone-call-indices (__tl_dyn-array i64))
  (next-clone-call-index i64))

(defenum ResultSurfaceTypecheckFactsBuilder
  (Ok SurfaceTypecheckFactsBuilder)
  (Err String))

(defstruct SurfaceTypecheckFactReader
  (bytes (__tl_dyn-array u8))
  (offset (__tl_dyn-array i64))
  (ok (__tl_dyn-array bool))
  (message (__tl_dyn-array String)))

(cfg
  compiler-surface-producer
  (defstruct SurfaceCloneObservation
    (decl-key i64)
    (root-key i64)
    (call-index i64)))

(cfg
  compiler-surface-producer
  (defstruct SurfaceCloneObservationSeq
    (slots (__tl_dyn-array SurfaceCloneObservation))
    (len i64)))

(cfg
  compiler-surface-producer
  (define (surface-clone-observation-seq-empty) : SurfaceCloneObservationSeq
    (SurfaceCloneObservationSeq (make-array SurfaceCloneObservation 0) 0)))

(cfg
  compiler-surface-producer
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
  compiler-surface-producer
  (define (surface-clone-observation-seq-grow!
    [seq : (&mut seq SurfaceCloneObservationSeq)]) : unit
    (let
      [count : i64 seq.len]
      [bigger : (__tl_dyn-array SurfaceCloneObservation)
        (make-array
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
  compiler-surface-producer
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
    (make-array i64 0)
    (make-array i64 0)
    (make-array i64 0)))

(define surface-typecheck-facts-installed : bool
  false)
(define surface-typecheck-facts-installed-value : (__tl_dyn-array
    SurfaceTypecheckFacts)
  (make-array (surface-typecheck-facts-empty)))

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
  compiler-surface-producer
  (define surface-typecheck-facts-recording-active : bool
    false))
(cfg
  compiler-surface-producer
  (define surface-typecheck-facts-recording-arena : i64
    0))
(cfg
  compiler-surface-producer
  (define surface-typecheck-facts-recording-decl-key : i64
    -1))
(cfg
  compiler-surface-producer
  (define surface-typecheck-facts-recording-observations : SurfaceCloneObservationSeq
    (surface-clone-observation-seq-empty)))

(cfg
  compiler-surface-producer
  (define (surface-typecheck-facts-recording-observations-shared-view) : SurfaceCloneObservationSeq
    (cfg
      stage0-seed-bootstrap
      surface-typecheck-facts-recording-observations
      (unsafe
        (ptr-read (ptr-addr-of surface-typecheck-facts-recording-observations))))))

(cfg
  compiler-surface-producer
  (define surface-typecheck-facts-recording-next-call : i64
    0))
(cfg
  compiler-surface-producer
  (define surface-typecheck-facts-recording-current-call : i64
    -1))

(cfg
  compiler-surface-producer
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
  compiler-surface-producer
  (define (surface-typecheck-facts-recording-select-decl! [decl-key : i64]) : unit
    (if surface-typecheck-facts-recording-active
      (set! surface-typecheck-facts-recording-decl-key decl-key)
      unit)))

(cfg
  compiler-surface-producer
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
  compiler-surface-producer
  (define (surface-typecheck-facts-recording-note-clone-root! [root-key : i64]) : unit
    (if (and
      surface-typecheck-facts-recording-active
      (>= surface-typecheck-facts-recording-decl-key 0)
      (>= surface-typecheck-facts-recording-current-call 0)
      (>= root-key 0))
      (in-arena
        (arena.Arena surface-typecheck-facts-recording-arena)
        (begin
          (surface-clone-observation-seq-push!
            (&mut surface-typecheck-facts-recording-observations)
            (SurfaceCloneObservation
              surface-typecheck-facts-recording-decl-key
              root-key
              surface-typecheck-facts-recording-current-call))))
      unit)))

(cfg
  compiler-surface-producer
  (define (surface-typecheck-facts-recording-finish
    [macro-prefix-decl-count : i64]
    [prefix-decl-count : i64]
    [summary-values : i64]
    [summary-functions : i64]
    [summary-externs : i64]) : SurfaceTypecheckFacts
    (let
      [count : i64
        (__tl-project-field
          (surface-typecheck-facts-recording-observations-shared-view)
          len)]
      [decl-keys : (__tl_dyn-array i64) (make-array i64 count)]
      [root-keys : (__tl_dyn-array i64) (make-array i64 count)]
      [call-indices : (__tl_dyn-array i64) (make-array i64 count)]
      [index : i64 0]
      [slots : (__tl_dyn-array SurfaceCloneObservation)
        (__tl-project-field
          (surface-typecheck-facts-recording-observations-shared-view)
          slots)]
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
  compiler-surface-producer
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
  compiler-surface-producer
  (define (surface-typecheck-facts-recording?) : bool
    surface-typecheck-facts-recording-active))

(define (surface-typecheck-facts-count-valid? [count : i64]) : bool
  (and (>= count 0) (<= count surface-typecheck-facts-max-count)))

(define (surface-typecheck-facts-positive-count-valid? [count : i64]) : bool
  (and (> count 0) (<= count surface-typecheck-facts-max-count)))

(define (surface-typecheck-facts-count-sum-valid? [left : i64] [right : i64]) : bool
  (and
    (surface-typecheck-facts-count-valid? left)
    (surface-typecheck-facts-count-valid? right)
    (<= left (- surface-typecheck-facts-max-count right))))

(define (surface-typecheck-facts-observations-valid?
  [decl-keys : (__tl_dyn-array i64)]
  [root-keys : (__tl_dyn-array i64)]
  [call-indices : (__tl_dyn-array i64)]) : bool
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

(define (surface-typecheck-facts-valid? [facts : SurfaceTypecheckFacts]) : bool
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

(define (surface-typecheck-facts-builder-empty) : SurfaceTypecheckFactsBuilder
  (SurfaceTypecheckFactsBuilder
    0
    0
    0
    0
    0
    0
    (make-array i64 0)
    (make-array i64 0)
    (make-array i64 0)
    0))

(define (surface-typecheck-facts-builder-valid?
  [builder : SurfaceTypecheckFactsBuilder]) : bool
  (let
    [fragment-count : i64 builder.fragment-count]
    [call-indices : (__tl_dyn-array i64) builder.clone-call-indices]
    [observation-count : i64 (array-length call-indices)]
    [next-call-index : i64 builder.next-clone-call-index]
    (if (= fragment-count 0)
      (and
        (= builder.macro-prefix-decl-count 0)
        (= builder.prefix-decl-count 0)
        (= builder.summary-values 0)
        (= builder.summary-functions 0)
        (= builder.summary-externs 0)
        (= (array-length builder.clone-decl-keys) 0)
        (= (array-length builder.clone-root-keys) 0)
        (= observation-count 0)
        (= next-call-index 0))
      (and
        (surface-typecheck-facts-positive-count-valid? fragment-count)
        (surface-typecheck-facts-valid?
          (SurfaceTypecheckFacts
            builder.macro-prefix-decl-count
            builder.prefix-decl-count
            builder.summary-values
            builder.summary-functions
            builder.summary-externs
            builder.clone-decl-keys
            builder.clone-root-keys
            call-indices))
        (if (= observation-count 0)
          (= next-call-index 0)
          (and
            (> next-call-index 0)
            (<= next-call-index surface-typecheck-facts-max-count)
            (=
              next-call-index
              (+ (array-ref call-indices (- observation-count 1)) 1))))))))

(define (surface-typecheck-facts-copy-i64-range!
  [dst : (&mut dst (__tl_dyn-array i64))]
  [dst-offset : i64]
  [src : (& src (__tl_dyn-array i64))]) : unit
  (let
    [index : i64 0]
    (while (< index (array-length src))
      (begin
        (set! (array-ref dst (+ dst-offset index)) (array-ref src index))
        (set! index (+ index 1))))))

(define (surface-typecheck-facts-builder-append
  [builder : SurfaceTypecheckFactsBuilder]
  [fragment : SurfaceTypecheckFacts]) : ResultSurfaceTypecheckFactsBuilder
  (cond
    [(not (surface-typecheck-facts-builder-valid? builder))
      (ResultSurfaceTypecheckFactsBuilder.Err
        "surface facts: invalid composition builder")]
    [(not (surface-typecheck-facts-valid? fragment))
      (ResultSurfaceTypecheckFactsBuilder.Err
        "surface facts: invalid composition fragment")]
    [else
      (let
        [builder-count : i64 (array-length builder.clone-decl-keys)]
        [fragment-count : i64 (array-length fragment.clone-decl-keys)]
        [base-call-index : i64 builder.next-clone-call-index]
        [last-local-call-index : i64
          (if (= fragment-count 0)
            -1
            (array-ref fragment.clone-call-indices (- fragment-count 1)))]
        [call-range-size : i64 (+ last-local-call-index 1)]
        (if (or
          (not
            (surface-typecheck-facts-count-sum-valid? builder.fragment-count 1))
          (not
            (surface-typecheck-facts-count-sum-valid?
              builder.macro-prefix-decl-count
              fragment.macro-prefix-decl-count))
          (not
            (surface-typecheck-facts-count-sum-valid?
              builder.prefix-decl-count
              fragment.prefix-decl-count))
          (not
            (surface-typecheck-facts-count-sum-valid?
              builder.summary-values
              fragment.summary-values))
          (not
            (surface-typecheck-facts-count-sum-valid?
              builder.summary-functions
              fragment.summary-functions))
          (not
            (surface-typecheck-facts-count-sum-valid?
              builder.summary-externs
              fragment.summary-externs))
          (>
            builder-count
            (- surface-typecheck-facts-max-clone-observations fragment-count))
          (>
            base-call-index
            (- surface-typecheck-facts-max-count call-range-size)))
          (ResultSurfaceTypecheckFactsBuilder.Err
            "surface facts: composition count limit exceeded")
          (let
            [combined-count : i64 (+ builder-count fragment-count)]
            [decl-keys : (__tl_dyn-array i64) (make-array i64 combined-count)]
            [root-keys : (__tl_dyn-array i64) (make-array i64 combined-count)]
            [call-indices : (__tl_dyn-array i64)
              (make-array i64 combined-count)]
            [index : i64 0]
            (begin
              (surface-typecheck-facts-copy-i64-range!
                (&mut decl-keys)
                0
                (& builder.clone-decl-keys))
              (surface-typecheck-facts-copy-i64-range!
                (&mut root-keys)
                0
                (& builder.clone-root-keys))
              (surface-typecheck-facts-copy-i64-range!
                (&mut call-indices)
                0
                (& builder.clone-call-indices))
              (surface-typecheck-facts-copy-i64-range!
                (&mut decl-keys)
                builder-count
                (& fragment.clone-decl-keys))
              (surface-typecheck-facts-copy-i64-range!
                (&mut root-keys)
                builder-count
                (& fragment.clone-root-keys))
              (while (< index fragment-count)
                (begin
                  (set!
                    (array-ref call-indices (+ builder-count index))
                    (+
                      base-call-index
                      (array-ref fragment.clone-call-indices index)))
                  (set! index (+ index 1))))
              (ResultSurfaceTypecheckFactsBuilder.Ok
                (SurfaceTypecheckFactsBuilder
                  (+ builder.fragment-count 1)
                  (+
                    builder.macro-prefix-decl-count
                    fragment.macro-prefix-decl-count)
                  (+ builder.prefix-decl-count fragment.prefix-decl-count)
                  (+ builder.summary-values fragment.summary-values)
                  (+ builder.summary-functions fragment.summary-functions)
                  (+ builder.summary-externs fragment.summary-externs)
                  decl-keys
                  root-keys
                  call-indices
                  (+ base-call-index call-range-size)))))))]))

(define (surface-typecheck-facts-builder-finish
  [builder : SurfaceTypecheckFactsBuilder]) : ResultSurfaceTypecheckFacts
  (if (or
    (= builder.fragment-count 0)
    (not (surface-typecheck-facts-builder-valid? builder)))
    (ResultSurfaceTypecheckFacts.Err
      "surface facts: empty or invalid composition")
    (ResultSurfaceTypecheckFacts.Ok
      (SurfaceTypecheckFacts
        builder.macro-prefix-decl-count
        builder.prefix-decl-count
        builder.summary-values
        builder.summary-functions
        builder.summary-externs
        builder.clone-decl-keys
        builder.clone-root-keys
        builder.clone-call-indices))))

(define (surface-typecheck-facts-compose
  [fragments : (__tl_dyn-array SurfaceTypecheckFacts)]) : ResultSurfaceTypecheckFacts
  (let
    [builder : SurfaceTypecheckFactsBuilder
      (surface-typecheck-facts-builder-empty)]
    [index : i64 0]
    (begin
      (while (< index (array-length fragments))
        (match (surface-typecheck-facts-builder-append
          builder
          (array-ref fragments index))
          [(ResultSurfaceTypecheckFactsBuilder.Err message)
            (return (ResultSurfaceTypecheckFacts.Err message))]
          [(ResultSurfaceTypecheckFactsBuilder.Ok next)
            (begin
              (set! builder next)
              (set! index (+ index 1)))]))
      (surface-typecheck-facts-builder-finish builder))))

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
      (make-array 10 10 11)
      (make-array 20 21 22)
      (make-array 0 0 2))))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-test-fragment-two) : SurfaceTypecheckFacts
    (SurfaceTypecheckFacts
      4
      5
      13
      17
      19
      (make-array 30 31)
      (make-array 40 41)
      (make-array 0 1))))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-test-composite-ok?
    [facts : SurfaceTypecheckFacts]) : bool
    (and
      (= facts.macro-prefix-decl-count 6)
      (= facts.prefix-decl-count 8)
      (= facts.summary-values 18)
      (= facts.summary-functions 24)
      (= facts.summary-externs 30)
      (surface-typecheck-facts-i64-array-eq?
        facts.clone-decl-keys
        (make-array 10 10 11 30 31))
      (surface-typecheck-facts-i64-array-eq?
        facts.clone-root-keys
        (make-array 20 21 22 40 41))
      ;; The second fragment also starts at call zero. Rebasing it after the
      ;; first fragment's local range makes the boundary strictly disjoint.
      (surface-typecheck-facts-i64-array-eq?
        facts.clone-call-indices
        (make-array 0 0 2 3 4)))))

(cfg
  compiler-surface-selftest
  (define (surface-typecheck-facts-tests-ok?) : bool
    (let
      [first : SurfaceTypecheckFacts
        (surface-typecheck-facts-test-fragment-one)]
      [second : SurfaceTypecheckFacts
        (surface-typecheck-facts-test-fragment-two)]
      [bad-order : SurfaceTypecheckFacts
        (SurfaceTypecheckFacts
          1
          1
          0
          0
          0
          (make-array 50 50)
          (make-array 60 61)
          (make-array 1 0))]
      [bad-group : SurfaceTypecheckFacts
        (SurfaceTypecheckFacts
          1
          1
          0
          0
          0
          (make-array 50 51)
          (make-array 60 61)
          (make-array 0 0))]
      [limit-fragment : SurfaceTypecheckFacts
        (SurfaceTypecheckFacts
          surface-typecheck-facts-max-count
          surface-typecheck-facts-max-count
          surface-typecheck-facts-max-count
          surface-typecheck-facts-max-count
          surface-typecheck-facts-max-count
          (make-array i64 0)
          (make-array i64 0)
          (make-array i64 0))]
      [builder : SurfaceTypecheckFactsBuilder
        (surface-typecheck-facts-builder-empty)]
      [limit-builder : SurfaceTypecheckFactsBuilder
        (surface-typecheck-facts-builder-empty)]
      [fragments : (__tl_dyn-array SurfaceTypecheckFacts)
        (make-array SurfaceTypecheckFacts 2)]
      [composite : SurfaceTypecheckFacts (surface-typecheck-facts-empty)]
      [ok : bool true]
      (begin
        (set! (array-ref fragments 0) first)
        (set! (array-ref fragments 1) second)
        (match (surface-typecheck-facts-builder-finish builder)
          [(ResultSurfaceTypecheckFacts.Err _) unit]
          [(ResultSurfaceTypecheckFacts.Ok _) (set! ok false)])
        (match (surface-typecheck-facts-builder-append builder first)
          [(ResultSurfaceTypecheckFactsBuilder.Err _) (set! ok false)]
          [(ResultSurfaceTypecheckFactsBuilder.Ok next) (set! builder next)])
        ;; A rejected later fragment leaves the completed first-fragment
        ;; builder reusable and unchanged.
        (match (surface-typecheck-facts-builder-append builder bad-order)
          [(ResultSurfaceTypecheckFactsBuilder.Err _) unit]
          [(ResultSurfaceTypecheckFactsBuilder.Ok _) (set! ok false)])
        (match (surface-typecheck-facts-builder-finish builder)
          [(ResultSurfaceTypecheckFacts.Err _) (set! ok false)]
          [(ResultSurfaceTypecheckFacts.Ok unchanged)
            (if (surface-typecheck-facts-eq? unchanged first)
              unit
              (set! ok false))])
        (match (surface-typecheck-facts-builder-append builder second)
          [(ResultSurfaceTypecheckFactsBuilder.Err _) (set! ok false)]
          [(ResultSurfaceTypecheckFactsBuilder.Ok next) (set! builder next)])
        (match (surface-typecheck-facts-builder-finish builder)
          [(ResultSurfaceTypecheckFacts.Err _) (set! ok false)]
          [(ResultSurfaceTypecheckFacts.Ok facts)
            (begin
              (if (surface-typecheck-facts-test-composite-ok? facts)
                unit
                (set! ok false))
              (set! composite facts))])
        (if (or
          (surface-typecheck-facts-valid? bad-order)
          (surface-typecheck-facts-valid? bad-group))
          (set! ok false)
          unit)
        (match (surface-typecheck-facts-builder-append
          limit-builder
          limit-fragment)
          [(ResultSurfaceTypecheckFactsBuilder.Err _) (set! ok false)]
          [(ResultSurfaceTypecheckFactsBuilder.Ok next)
            (set! limit-builder next)])
        (match (surface-typecheck-facts-builder-append limit-builder second)
          [(ResultSurfaceTypecheckFactsBuilder.Err _) unit]
          [(ResultSurfaceTypecheckFactsBuilder.Ok _) (set! ok false)])
        (match (surface-typecheck-facts-compose fragments)
          [(ResultSurfaceTypecheckFacts.Err _) (set! ok false)]
          [(ResultSurfaceTypecheckFacts.Ok facts)
            (if (surface-typecheck-facts-test-composite-ok? facts)
              unit
              (set! ok false))])
        (match (surface-typecheck-facts-compose
          (make-array SurfaceTypecheckFacts 0))
          [(ResultSurfaceTypecheckFacts.Err _) unit]
          [(ResultSurfaceTypecheckFacts.Ok _) (set! ok false)])
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
        (if (surface-typecheck-facts-publish! composite)
          unit
          (set! ok false))
        (if (and
          (surface-typecheck-facts-active?)
          (surface-typecheck-facts-eq?
            (surface-typecheck-facts-current)
            composite))
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
  (any compiler-surface-producer compiler-surface-selftest)
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
    [offset : (__tl_dyn-array i64) (make-array i64 1)]
    [ok : (__tl_dyn-array bool) (make-array bool 1)]
    [message : (__tl_dyn-array String) (make-array String 1)]
    (begin
      (set! (array-ref offset 0) 0)
      (set! (array-ref ok 0) true)
      (set! (array-ref message 0) "")
      (SurfaceTypecheckFactReader bytes offset ok message))))

(define (surface-typecheck-fact-reader-fail!
  [reader : SurfaceTypecheckFactReader]
  [message : String]) : unit
  (if (array-ref reader.ok 0)
    (begin
      (set! (array-ref reader.ok 0) false)
      (set! (array-ref reader.message 0) message))
    unit))

(define (surface-typecheck-fact-reader-u64!
  [reader : SurfaceTypecheckFactReader]) : i64
  (let
    [offset : i64 (array-ref reader.offset 0)]
    [bytes : (__tl_dyn-array u8) reader.bytes]
    (if (or (not (array-ref reader.ok 0)) (> offset (- (array-length bytes) 8)))
      (begin
        (surface-typecheck-fact-reader-fail!
          reader
          "surface facts: truncated u64")
        -1)
      (begin
        (set! (array-ref reader.offset 0) (+ offset 8))
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
        [decl-keys : (__tl_dyn-array i64) (make-array i64 clone-count)]
        [root-keys : (__tl_dyn-array i64) (make-array i64 clone-count)]
        [call-indices : (__tl_dyn-array i64) (make-array i64 clone-count)]
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
                (ResultSurfaceTypecheckFacts.Err (array-ref reader.message 0))]
              [(not (= (array-ref reader.offset 0) (array-length bytes)))
                (ResultSurfaceTypecheckFacts.Err
                  "surface facts: trailing payload bytes")]
              [(not (surface-typecheck-facts-valid? facts))
                (ResultSurfaceTypecheckFacts.Err
                  "surface facts: invalid checked-prefix facts")]
              [else (ResultSurfaceTypecheckFacts.Ok facts)])))))))