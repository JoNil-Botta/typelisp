;; compiler_surface_identity.tl - relocatable package-surface identity schema.
;;
;; Frontend snapshots cannot retain intern ids: source ids are insertion-local,
;; generated ids grow down from a process-local pool, and both are invalidated
;; by a compiler-session reset. This module serializes spellings plus structural
;; identity and replays them through the public interner APIs. The resulting
;; remap is the only supported bridge from image-local references to the active
;; compiler session.
;;
;; Package keys are intentionally independent of the embedded stdlib. A key is
;; package name + canonical module set + source hash + compiler build + config
;; variant. Later per-package images use the same schema and hydration path.
(import compiler_intern as ci)
(import stdlib.byte_buf_core)
(import tlci_core as tlci)

(defstruct SurfaceIdentityKey
  (package-name String)
  (modules (Array String))
  (source-hash String)
  (compiler-build String)
  (configuration String))

(defstruct SurfaceGeneratedIdentity
  (name String)
  (canonical bool)
  (qualified bool)
  (dotted bool)
  (ref0 i64)
  (ref1 i64)
  (ref2 i64))

(defstruct SurfaceIdentityPayload
  (key SurfaceIdentityKey)
  (source-names (Array String))
  (generated (Array SurfaceGeneratedIdentity)))

(defstruct SurfaceIdentityHydration
  (key SurfaceIdentityKey)
  (remap (Array i64)))

(defstruct SurfaceIdentityReader
  (bytes (Array u8))
  (offset (Array i64))
  (ok (Array bool))
  (message (Array String)))

(defenum ResultSurfaceIdentityBytes
  (Ok (Array u8))
  (Err String))

(defenum ResultSurfaceIdentityPayload
  (Ok SurfaceIdentityPayload)
  (Err String))

(defenum ResultSurfaceIdentityHydration
  (Ok SurfaceIdentityHydration)
  (KeyMismatch String)
  (Err String))

(define surface-identity-magic : i64
  3550889639320046676)
(define surface-identity-schema-version : i64
  1)
(define surface-identity-generated-canonical : i64
  1)
(define surface-identity-generated-qualified : i64
  2)
(define surface-identity-generated-dotted : i64
  4)
(define surface-identity-max-count : i64
  1048576)

(define (surface-identity-empty-bytes) : (Array u8)
  (make-array u8 0))

(define (surface-identity-string-eq? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (tlci.tlci-string-length left)]
    [right-len : i64 (tlci.tlci-string-length right)]
    [index : i64 0]
    [equal : bool (= left-len right-len)]
    (begin
      (while (and equal (< index left-len))
        (if (=
          (tlci.tlci-string-ref left index)
          (tlci.tlci-string-ref right index))
          (set! index (+ index 1))
          (set! equal false)))
      equal)))

(define (surface-identity-string-less? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (tlci.tlci-string-length left)]
    [right-len : i64 (tlci.tlci-string-length right)]
    [limit : i64
      (if (< left-len right-len)
        left-len
        right-len)]
    [index : i64 0]
    [decided : bool false]
    [less : bool false]
    (begin
      (while (and (not decided) (< index limit))
        (let
          [left-char : char (tlci.tlci-string-ref left index)]
          [right-char : char (tlci.tlci-string-ref right index)]
          (cond
            [(< left-char right-char)
              (begin
                (set! less true)
                (set! decided true))]
            [(> left-char right-char) (set! decided true)]
            [else (set! index (+ index 1))])))
      (if decided
        less
        (< left-len right-len)))))

(define (surface-identity-module-set-canonical? [modules : (Array String)]) : bool
  (let
    [index : i64 0]
    [ok : bool (> (array-length modules) 0)]
    (begin
      (while (and ok (< index (array-length modules)))
        (let
          [module-name : String (array-ref modules index)]
          (if (and
            (> (tlci.tlci-string-length module-name) 0)
            (or
              (= index 0)
              (surface-identity-string-less?
                (array-ref modules (- index 1))
                module-name)))
            (set! index (+ index 1))
            (set! ok false))))
      ok)))

(define (surface-identity-key-valid? [key : SurfaceIdentityKey]) : bool
  (and
    (> (tlci.tlci-string-length (struct-get key package-name)) 0)
    (> (tlci.tlci-string-length (struct-get key source-hash)) 0)
    (> (tlci.tlci-string-length (struct-get key compiler-build)) 0)
    (surface-identity-module-set-canonical? (struct-get key modules))))

(define (surface-identity-string-array-eq?
  [left : (Array String)]
  [right : (Array String)]) : bool
  (let
    [index : i64 0]
    [equal : bool (= (array-length left) (array-length right))]
    (begin
      (while (and equal (< index (array-length left)))
        (if (surface-identity-string-eq?
          (array-ref left index)
          (array-ref right index))
          (set! index (+ index 1))
          (set! equal false)))
      equal)))

(define (surface-identity-key-eq?
  [left : SurfaceIdentityKey]
  [right : SurfaceIdentityKey]) : bool
  (and
    (surface-identity-string-eq?
      (struct-get left package-name)
      (struct-get right package-name))
    (surface-identity-string-array-eq?
      (struct-get left modules)
      (struct-get right modules))
    (surface-identity-string-eq?
      (struct-get left source-hash)
      (struct-get right source-hash))
    (surface-identity-string-eq?
      (struct-get left compiler-build)
      (struct-get right compiler-build))
    (surface-identity-string-eq?
      (struct-get left configuration)
      (struct-get right configuration))))

(define (surface-identity-push-string!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : String]) : unit
  (begin
    (tlci.tlci-push-u64! out (tlci.tlci-string-length text))
    (tlci.tlci-push-string-bytes! out text)))

(define (surface-identity-local-ref [id : i64] [source-count : i64]) : i64
  (cond
    [(and (>= id 0) (< id source-count)) id]
    [(ci.intern-generated-id-active? id)
      (+ source-count (- (- (ci.intern-capacity) 1) id))]
    [else -2]))

;; Nominal ids can be either one intern id or a compiler structural pair/triple
;; packed with the active interner capacity. Repack the same shape with the
;; image identity count as its stride. This keeps every component relocatable
;; while preserving one-word AST name fields in the frontend section.
(define (surface-identity-portable-id
  [id : i64]
  [source-count : i64]
  [identity-count : i64]) : i64
  (let
    [session-stride : i64 (ci.intern-capacity)]
    [session-stride2 : i64 (* session-stride session-stride)]
    [session-triple-offset : i64 (+ session-stride session-stride2)]
    [image-stride2 : i64 (* identity-count identity-count)]
    (cond
      [(and
          (>= id session-triple-offset)
          (< id (+ session-triple-offset (* session-stride2 session-stride))))
        (let
          [raw : i64 (- id session-triple-offset)]
          [module-ref : i64
            (surface-identity-local-ref (/ raw session-stride2) source-count)]
          [enum-ref : i64
            (surface-identity-local-ref
              (% (/ raw session-stride) session-stride)
              source-count)]
          [variant-ref : i64
            (surface-identity-local-ref (% raw session-stride) source-count)]
          (if (or (< module-ref 0) (< enum-ref 0) (< variant-ref 0))
            -2
            (+
              identity-count
              (+
                image-stride2
                (+
                  (* module-ref image-stride2)
                  (+ (* enum-ref identity-count) variant-ref))))))]
      [(and (>= id session-stride) (< id (+ session-stride session-stride2)))
        (let
          [raw : i64 (- id session-stride)]
          [module-ref : i64
            (surface-identity-local-ref (/ raw session-stride) source-count)]
          [name-ref : i64
            (surface-identity-local-ref (% raw session-stride) source-count)]
          (if (or (< module-ref 0) (< name-ref 0))
            -2
            (+ identity-count (+ (* module-ref identity-count) name-ref))))]
      [else (surface-identity-local-ref id source-count)])))

(define (surface-identity-resolve-portable-id [id : i64] [remap : (Array i64)]) : i64
  (let
    [image-stride : i64 (array-length remap)]
    [image-stride2 : i64 (* image-stride image-stride)]
    [image-triple-offset : i64 (+ image-stride image-stride2)]
    [session-stride : i64 (ci.intern-capacity)]
    [session-stride2 : i64 (* session-stride session-stride)]
    (cond
      [(and
          (>= id image-triple-offset)
          (< id (+ image-triple-offset (* image-stride2 image-stride))))
        (let
          [raw : i64 (- id image-triple-offset)]
          [module-ref : i64 (/ raw image-stride2)]
          [enum-ref : i64 (% (/ raw image-stride) image-stride)]
          [variant-ref : i64 (% raw image-stride)]
          (+
            session-stride
            (+
              session-stride2
              (+
                (* (array-ref remap module-ref) session-stride2)
                (+
                  (* (array-ref remap enum-ref) session-stride)
                  (array-ref remap variant-ref))))))]
      [(and (>= id image-stride) (< id (+ image-stride image-stride2)))
        (let
          [raw : i64 (- id image-stride)]
          (+
            session-stride
            (+
              (* (array-ref remap (/ raw image-stride)) session-stride)
              (array-ref remap (% raw image-stride)))))]
      [(and (>= id 0) (< id image-stride)) (array-ref remap id)]
      [else -1])))

(define (surface-identity-generated-record [id : i64] [source-count : i64]) : SurfaceGeneratedIdentity
  (let
    [qualified : bool (ci.intern-qualified? id)]
    [dotted : bool (ci.intern-dotted? id)]
    [ref0 : i64 -1]
    [ref1 : i64 -1]
    [ref2 : i64 -1]
    (begin
      (if qualified
        (begin
          (set!
            ref0
            (surface-identity-local-ref
              (ci.intern-qualified-module-id id)
              source-count))
          (set!
            ref1
            (surface-identity-local-ref
              (ci.intern-qualified-base-id id)
              source-count)))
        (if dotted
          (begin
            (set!
              ref0
              (surface-identity-local-ref
                (ci.intern-leading-dot-id id)
                source-count))
            (set!
              ref1
              (surface-identity-local-ref
                (ci.intern-dotted-prefix-id id)
                source-count))
            (set!
              ref2
              (surface-identity-local-ref
                (ci.intern-dotted-tail-id id)
                source-count)))
          unit))
      (SurfaceGeneratedIdentity
        (ci.intern-str id)
        (ci.intern-generated-canonical-id? id)
        qualified
        dotted
        ref0
        ref1
        ref2))))

(define (surface-identity-capture [key : SurfaceIdentityKey]) : SurfaceIdentityPayload
  (let
    [source-count : i64 (ci.intern-pool-len)]
    [generated-count : i64 (ci.intern-generated-count)]
    [source-names : (Array String) (make-array String source-count)]
    [generated : (Array SurfaceGeneratedIdentity)
      (make-array SurfaceGeneratedIdentity generated-count)]
    [index : i64 0]
    (begin
      (while (< index source-count)
        (begin
          (array-set! source-names index (ci.intern-str index))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index generated-count)
        (begin
          (array-set!
            generated
            index
            (surface-identity-generated-record
              (ci.intern-generated-id-at-allocation-index index)
              source-count))
          (set! index (+ index 1))))
      (SurfaceIdentityPayload key source-names generated))))

(define (surface-identity-generated-record-valid?
  [record : SurfaceGeneratedIdentity]
  [prior-count : i64]) : bool
  (let
    [qualified : bool (struct-get record qualified)]
    [dotted : bool (struct-get record dotted)]
    [ref0 : i64 (struct-get record ref0)]
    [ref1 : i64 (struct-get record ref1)]
    [ref2 : i64 (struct-get record ref2)]
    (and
      (not (and qualified dotted))
      (if (or qualified dotted)
        (and
          (>= ref0 0)
          (< ref0 prior-count)
          (>= ref1 0)
          (< ref1 prior-count)
          (if dotted
            (and (>= ref2 0) (< ref2 prior-count))
            (= ref2 -1)))
        (and (= ref0 -1) (= ref1 -1) (= ref2 -1))))))

(define (surface-identity-payload-valid? [payload : SurfaceIdentityPayload]) : bool
  (let
    [source-count : i64 (array-length (struct-get payload source-names))]
    [generated : (Array SurfaceGeneratedIdentity)
      (struct-get payload generated)]
    [index : i64 0]
    [ok : bool (surface-identity-key-valid? (struct-get payload key))]
    (begin
      (while (and ok (< index (array-length generated)))
        (if (surface-identity-generated-record-valid?
          (array-ref generated index)
          (+ source-count index))
          (set! index (+ index 1))
          (set! ok false)))
      ok)))

(define (surface-identity-encode [payload : SurfaceIdentityPayload]) : ResultSurfaceIdentityBytes
  (if (not (surface-identity-payload-valid? payload))
    (ResultSurfaceIdentityBytes.Err
      "surface identity: invalid package key or identity graph")
    (let
      [key : SurfaceIdentityKey (struct-get payload key)]
      [source-names : (Array String) (struct-get payload source-names)]
      [generated : (Array SurfaceGeneratedIdentity)
        (struct-get payload generated)]
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      [index : i64 0]
      (begin
        (tlci.tlci-push-u64! (&mut out) surface-identity-magic)
        (tlci.tlci-push-u64! (&mut out) surface-identity-schema-version)
        (tlci.tlci-push-u64! (&mut out) (array-length (struct-get key modules)))
        (tlci.tlci-push-u64! (&mut out) (array-length source-names))
        (tlci.tlci-push-u64! (&mut out) (array-length generated))
        (surface-identity-push-string! (&mut out) (struct-get key package-name))
        (surface-identity-push-string! (&mut out) (struct-get key source-hash))
        (surface-identity-push-string!
          (&mut out)
          (struct-get key compiler-build))
        (surface-identity-push-string!
          (&mut out)
          (struct-get key configuration))
        (while (< index (array-length (struct-get key modules)))
          (begin
            (surface-identity-push-string!
              (&mut out)
              (array-ref (struct-get key modules) index))
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index (array-length source-names))
          (begin
            (surface-identity-push-string!
              (&mut out)
              (array-ref source-names index))
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index (array-length generated))
          (let
            [record : SurfaceGeneratedIdentity (array-ref generated index)]
            [flags : i64
              (+
                (if (struct-get record canonical)
                  surface-identity-generated-canonical
                  0)
                (+
                  (if (struct-get record qualified)
                    surface-identity-generated-qualified
                    0)
                  (if (struct-get record dotted)
                    surface-identity-generated-dotted
                    0)))]
            (begin
              (tlci.tlci-push-u64! (&mut out) flags)
              (tlci.tlci-push-u64! (&mut out) (struct-get record ref0))
              (tlci.tlci-push-u64! (&mut out) (struct-get record ref1))
              (tlci.tlci-push-u64! (&mut out) (struct-get record ref2))
              (surface-identity-push-string!
                (&mut out)
                (struct-get record name))
              (set! index (+ index 1)))))
        (ResultSurfaceIdentityBytes.Ok
          (byte_buf_core.byte-buf-builder-finish-array (& out)))))))

(define (surface-identity-reader-new [bytes : (Array u8)]) : SurfaceIdentityReader
  (let
    [offset : (Array i64) (make-array i64 1)]
    [ok : (Array bool) (make-array bool 1)]
    [message : (Array String) (make-array String 1)]
    (begin
      (array-set! offset 0 0)
      (array-set! ok 0 true)
      (array-set! message 0 "")
      (SurfaceIdentityReader bytes offset ok message))))

(define (surface-identity-reader-fail!
  [reader : SurfaceIdentityReader]
  [message : String]) : unit
  (if (array-ref (struct-get reader ok) 0)
    (begin
      (array-set! (struct-get reader ok) 0 false)
      (array-set! (struct-get reader message) 0 message))
    unit))

(define (surface-identity-reader-u64! [reader : SurfaceIdentityReader]) : i64
  (let
    [offset : i64 (array-ref (struct-get reader offset) 0)]
    [bytes : (Array u8) (struct-get reader bytes)]
    (if (or
      (not (array-ref (struct-get reader ok) 0))
      (> offset (- (array-length bytes) 8)))
      (begin
        (surface-identity-reader-fail! reader "surface identity: truncated u64")
        -1)
      (begin
        (array-set! (struct-get reader offset) 0 (+ offset 8))
        (tlci.tlci-read-u64 bytes offset)))))

(define (surface-identity-reader-string! [reader : SurfaceIdentityReader]) : String
  (let
    [len : i64 (surface-identity-reader-u64! reader)]
    [offset : i64 (array-ref (struct-get reader offset) 0)]
    [bytes : (Array u8) (struct-get reader bytes)]
    (if (or
      (< len 0)
      (> offset (array-length bytes))
      (> len (- (array-length bytes) offset)))
      (begin
        (surface-identity-reader-fail!
          reader
          "surface identity: truncated string")
        "")
      (let
        [value : String (tlci.tlci-bytes->string bytes offset len)]
        (begin
          (array-set! (struct-get reader offset) 0 (+ offset len))
          value)))))

(define (surface-identity-safe-count? [count : i64]) : bool
  (and (>= count 0) (<= count surface-identity-max-count)))

(define (surface-identity-decode [bytes : (Array u8)]) : ResultSurfaceIdentityPayload
  (let
    [reader : SurfaceIdentityReader (surface-identity-reader-new bytes)]
    [magic : i64 (surface-identity-reader-u64! reader)]
    [schema : i64 (surface-identity-reader-u64! reader)]
    [module-count : i64 (surface-identity-reader-u64! reader)]
    [source-count : i64 (surface-identity-reader-u64! reader)]
    [generated-count : i64 (surface-identity-reader-u64! reader)]
    (if (or
      (not (= magic surface-identity-magic))
      (not (= schema surface-identity-schema-version))
      (not (surface-identity-safe-count? module-count))
      (not (surface-identity-safe-count? source-count))
      (not (surface-identity-safe-count? generated-count)))
      (ResultSurfaceIdentityPayload.Err
        "surface identity: bad magic, schema, or count")
      (let
        [package-name : String (surface-identity-reader-string! reader)]
        [source-hash : String (surface-identity-reader-string! reader)]
        [compiler-build : String (surface-identity-reader-string! reader)]
        [configuration : String (surface-identity-reader-string! reader)]
        [modules : (Array String) (make-array String module-count)]
        [source-names : (Array String) (make-array String source-count)]
        [generated : (Array SurfaceGeneratedIdentity)
          (make-array SurfaceGeneratedIdentity generated-count)]
        [index : i64 0]
        (begin
          (while (and
            (array-ref (struct-get reader ok) 0)
            (< index module-count))
            (begin
              (array-set!
                modules
                index
                (surface-identity-reader-string! reader))
              (set! index (+ index 1))))
          (set! index 0)
          (while (and
            (array-ref (struct-get reader ok) 0)
            (< index source-count))
            (begin
              (array-set!
                source-names
                index
                (surface-identity-reader-string! reader))
              (set! index (+ index 1))))
          (set! index 0)
          (while (and
            (array-ref (struct-get reader ok) 0)
            (< index generated-count))
            (let
              [flags : i64 (surface-identity-reader-u64! reader)]
              [ref0 : i64 (surface-identity-reader-u64! reader)]
              [ref1 : i64 (surface-identity-reader-u64! reader)]
              [ref2 : i64 (surface-identity-reader-u64! reader)]
              [name : String (surface-identity-reader-string! reader)]
              (begin
                (if (or (< flags 0) (> flags 7))
                  (surface-identity-reader-fail!
                    reader
                    "surface identity: invalid generated identity flags")
                  unit)
                (array-set!
                  generated
                  index
                  (SurfaceGeneratedIdentity
                    name
                    (not
                      (= (bit-and flags surface-identity-generated-canonical) 0))
                    (not
                      (= (bit-and flags surface-identity-generated-qualified) 0))
                    (not
                      (= (bit-and flags surface-identity-generated-dotted) 0))
                    ref0
                    ref1
                    ref2))
                (set! index (+ index 1)))))
          (let
            [key : SurfaceIdentityKey
              (SurfaceIdentityKey
                package-name
                modules
                source-hash
                compiler-build
                configuration)]
            [payload : SurfaceIdentityPayload
              (SurfaceIdentityPayload key source-names generated)]
            (cond
              [(not (array-ref (struct-get reader ok) 0))
                (ResultSurfaceIdentityPayload.Err
                  (array-ref (struct-get reader message) 0))]
              [(not
                  (=
                    (array-ref (struct-get reader offset) 0)
                    (array-length bytes)))
                (ResultSurfaceIdentityPayload.Err
                  "surface identity: trailing payload bytes")]
              [(not (surface-identity-payload-valid? payload))
                (ResultSurfaceIdentityPayload.Err
                  "surface identity: invalid package key or identity graph")]
              [else (ResultSurfaceIdentityPayload.Ok payload)])))))))

(define (surface-identity-hydrate-generated!
  [record : SurfaceGeneratedIdentity]
  [remap : (Array i64)]) : i64
  (let
    [name : String (struct-get record name)]
    [canonical : bool (struct-get record canonical)]
    [qualified : bool (struct-get record qualified)]
    [dotted : bool (struct-get record dotted)]
    [ref0 : i64 (struct-get record ref0)]
    [ref1 : i64 (struct-get record ref1)]
    [ref2 : i64 (struct-get record ref2)]
    (cond
      [qualified
        (if canonical
          (ci.intern-generated-canonical-qualified-name
            name
            (array-ref remap ref0)
            (array-ref remap ref1))
          (ci.intern-generated-qualified-name
            name
            (array-ref remap ref0)
            (array-ref remap ref1)))]
      [dotted
        (if canonical
          (ci.intern-generated-canonical-dotted-name
            name
            (array-ref remap ref0)
            (array-ref remap ref1)
            (array-ref remap ref2))
          (ci.intern-generated-dotted-name
            name
            (array-ref remap ref0)
            (array-ref remap ref1)
            (array-ref remap ref2)))]
      [canonical (ci.intern-generated-canonical-name name)]
      [else (ci.intern-generated-name name)])))

(define (surface-identity-hydrate-payload
  [payload : SurfaceIdentityPayload]
  [expected-key : SurfaceIdentityKey]) : ResultSurfaceIdentityHydration
  (let
    [key : SurfaceIdentityKey (struct-get payload key)]
    (if (not (surface-identity-key-eq? key expected-key))
      (ResultSurfaceIdentityHydration.KeyMismatch
        "surface identity: package key mismatch")
      (let
        [source-names : (Array String) (struct-get payload source-names)]
        [generated : (Array SurfaceGeneratedIdentity)
          (struct-get payload generated)]
        [source-count : i64 (array-length source-names)]
        [remap : (Array i64)
          (make-array i64 (+ source-count (array-length generated)))]
        [index : i64 0]
        (begin
          (while (< index source-count)
            (begin
              (array-set!
                remap
                index
                (ci.intern (array-ref source-names index)))
              (set! index (+ index 1))))
          (set! index 0)
          (while (< index (array-length generated))
            (begin
              (array-set!
                remap
                (+ source-count index)
                (surface-identity-hydrate-generated!
                  (array-ref generated index)
                  remap))
              (set! index (+ index 1))))
          (ResultSurfaceIdentityHydration.Ok
            (SurfaceIdentityHydration key remap)))))))

(define (surface-identity-hydrate
  [bytes : (Array u8)]
  [expected-key : SurfaceIdentityKey]) : ResultSurfaceIdentityHydration
  (match (surface-identity-decode bytes)
    [(ResultSurfaceIdentityPayload.Err message)
      (ResultSurfaceIdentityHydration.Err message)]
    [(ResultSurfaceIdentityPayload.Ok payload)
      (surface-identity-hydrate-payload payload expected-key)]))

(define (surface-identity-test-key) : SurfaceIdentityKey
  (let
    [modules : (Array String) (make-array String 2)]
    (begin
      (array-set! modules 0 "pkg/a.tl")
      (array-set! modules 1 "pkg/b.tl")
      (SurfaceIdentityKey "pkg" modules "source-hash" "compiler-build" "host"))))

(define (surface-identity-remap-test-ok?
  [hydration : SurfaceIdentityHydration]
  [source-count : i64]
  [generated-count : i64]) : bool
  (let
    [remap : (Array i64) (struct-get hydration remap)]
    (and
      (= (array-length remap) (+ source-count generated-count))
      (= generated-count 4)
      (surface-identity-string-eq? (ci.intern-str (array-ref remap 0)) "alpha")
      (surface-identity-string-eq? (ci.intern-str (array-ref remap 1)) "module")
      (surface-identity-string-eq? (ci.intern-str (array-ref remap 2)) "base")
      (ci.intern-qualified? (array-ref remap (+ source-count 1)))
      (ci.intern-dotted? (array-ref remap (+ source-count 2)))
      (ci.intern-generated-canonical-id? (array-ref remap (+ source-count 3))))))

(define (surface-identity-tests-ok?) : bool
  (let
    [_reset : unit (ci.intern-reset!)]
    [alpha : i64 (ci.intern "alpha")]
    [module-id : i64 (ci.intern "module")]
    [base-id : i64 (ci.intern "base")]
    [dotted-source : i64 (ci.intern "base.Item")]
    [_opaque : i64 (ci.intern-generated-name "opaque/local")]
    [_qualified : i64
      (ci.intern-generated-qualified-name "module/base" module-id base-id)]
    [_dotted : i64
      (ci.intern-generated-dotted-name
        "base.Item.Next"
        base-id
        dotted-source
        (ci.intern-dotted-tail-id dotted-source))]
    [_canonical : i64 (ci.intern-generated-canonical-name "canonical")]
    [key : SurfaceIdentityKey (surface-identity-test-key)]
    [payload : SurfaceIdentityPayload (surface-identity-capture key)]
    [source-count : i64 (array-length (struct-get payload source-names))]
    [identity-count : i64
      (+ source-count (array-length (struct-get payload generated)))]
    [session-stride : i64 (ci.intern-capacity)]
    [pair-id : i64 (+ session-stride (+ (* module-id session-stride) base-id))]
    [triple-id : i64
      (+
        session-stride
        (+
          (* session-stride session-stride)
          (+
            (* module-id (* session-stride session-stride))
            (+ (* base-id session-stride) alpha))))]
    [portable-pair : i64
      (surface-identity-portable-id pair-id source-count identity-count)]
    [portable-triple : i64
      (surface-identity-portable-id triple-id source-count identity-count)]
    (if (not (= alpha 0))
      false
      (match (surface-identity-encode payload)
        [(ResultSurfaceIdentityBytes.Err _) false]
        [(ResultSurfaceIdentityBytes.Ok bytes)
          (let
            [copy : (Array u8) (tlci.tlci-copy-bytes bytes)]
            (begin
              (ci.intern-reset!)
              (let
                [unrelated : i64 (ci.intern "unrelated")]
                (match (surface-identity-hydrate bytes key)
                  [(ResultSurfaceIdentityHydration.Err _) false]
                  [(ResultSurfaceIdentityHydration.KeyMismatch _) false]
                  [(ResultSurfaceIdentityHydration.Ok hydration)
                    (let
                      [remap : (Array i64) (struct-get hydration remap)]
                      [mapped-module : i64 (array-ref remap 1)]
                      [mapped-base : i64 (array-ref remap 2)]
                      [mapped-alpha : i64 (array-ref remap 0)]
                      (and
                        (= unrelated 0)
                        (surface-identity-remap-test-ok?
                          hydration
                          source-count
                          (array-length (struct-get payload generated)))
                        (=
                          (surface-identity-resolve-portable-id
                            portable-pair
                            remap)
                          (+
                            session-stride
                            (+ (* mapped-module session-stride) mapped-base)))
                        (=
                          (surface-identity-resolve-portable-id
                            portable-triple
                            remap)
                          (+
                            session-stride
                            (+
                              (* session-stride session-stride)
                              (+
                                (*
                                  mapped-module
                                  (* session-stride session-stride))
                                (+ (* mapped-base session-stride) mapped-alpha)))))
                        (match (surface-identity-decode copy)
                          [(ResultSurfaceIdentityPayload.Err _) false]
                          [(ResultSurfaceIdentityPayload.Ok decoded)
                            (surface-identity-key-eq?
                              (struct-get decoded key)
                              key)])))]))))]))))

(define (main) : i64
  (if (surface-identity-tests-ok?)
    42
    1))