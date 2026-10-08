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
(import compiler_intern_state as cis)
(import compiler_surface_binary as binary)
(import stdlib.byte_reader)

(defmacro (surface-identity-string-array-shared-view
  [items : Expr]
  [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import stdlib.byte_buf_core))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import stdlib.byte_le))

(defstruct SurfaceIdentityKey
  (package-name String)
  (modules (__tl_dyn-array String))
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
  (source-names (__tl_dyn-array String))
  (generated (__tl_dyn-array SurfaceGeneratedIdentity)))

(defstruct SurfaceIdentityHydration
  (key SurfaceIdentityKey)
  (remap (__tl_dyn-array i64)))

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
  ;; 2: template-source and fresh-local identities use explicit portable
  ;; component records. Their process-local structural handles never cross the
  ;; wire, and the ordinal range no longer derives from intern capacity.
  2)
(define surface-identity-generated-canonical : i64
  1)
(define surface-identity-generated-qualified : i64
  2)
(define surface-identity-generated-dotted : i64
  4)
(define surface-identity-max-count : i64
  1048576)

(define (surface-identity-string-eq?
  [left : (& left str)]
  [right : (& right str)]) : bool
  (let
    [left-len : i64 (binary.surface-binary-string-length left)]
    [right-len : i64 (binary.surface-binary-string-length right)]
    [index : i64 0]
    [equal : bool (= left-len right-len)]
    (while (and equal (< index left-len))
      (if (=
        (binary.surface-binary-string-ref left index)
        (binary.surface-binary-string-ref right index))
        (set! index (+ index 1))
        (set! equal false)))
    equal))

(define (surface-identity-string-less?
  [left : (& left str)]
  [right : (& right str)]) : bool
  (let
    [left-len : i64 (binary.surface-binary-string-length left)]
    [right-len : i64 (binary.surface-binary-string-length right)]
    [limit : i64
      (if (< left-len right-len)
        left-len
        right-len)]
    [index : i64 0]
    [decided : bool false]
    [less : bool false]
    (while (and (not decided) (< index limit))
      (let
        [left-char : char (binary.surface-binary-string-ref left index)]
        [right-char : char (binary.surface-binary-string-ref right index)]
        (cond
          [(< left-char right-char)
            (set! less true)
            (set! decided true)]
          [(> left-char right-char) (set! decided true)]
          [else (set! index (+ index 1))])))
    (if decided
      less
      (< left-len right-len))))

(define (surface-identity-module-set-canonical?
  [modules : (& modules (__tl_dyn-array String))]) : bool
  (let
    [index : i64 0]
    [ok : bool (> (array-length modules) 0)]
    (while (and ok (< index (array-length modules)))
      (if (and
        (> (binary.surface-binary-string-length (array-ref modules index)) 0)
        (or
          (= index 0)
          (surface-identity-string-less?
            (array-ref modules (- index 1))
            (array-ref modules index))))
        (set! index (+ index 1))
        (set! ok false)))
    ok))

(define (surface-identity-key-valid? [key : (& key SurfaceIdentityKey)]) : bool
  (and
    (> (binary.surface-binary-string-length key.package-name) 0)
    (> (binary.surface-binary-string-length key.source-hash) 0)
    (> (binary.surface-binary-string-length key.compiler-build) 0)
    (surface-identity-module-set-canonical? key.modules)))

(define (surface-identity-string-array-eq?
  [left : (& left (__tl_dyn-array String))]
  [right : (& right (__tl_dyn-array String))]) : bool
  (let
    [index : i64 0]
    [equal : bool (= (array-length left) (array-length right))]
    (while (and equal (< index (array-length left)))
      (if (surface-identity-string-eq?
        (array-ref left index)
        (array-ref right index))
        (set! index (+ index 1))
        (set! equal false)))
    equal))

(define (surface-identity-key-eq?
  [left : (& left SurfaceIdentityKey)]
  [right : (& right SurfaceIdentityKey)]) : bool
  (and
    (surface-identity-string-eq? left.package-name right.package-name)
    (surface-identity-string-array-eq? left.modules right.modules)
    (surface-identity-string-eq? left.source-hash right.source-hash)
    (surface-identity-string-eq? left.compiler-build right.compiler-build)
    (surface-identity-string-eq? left.configuration right.configuration)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-identity-local-ref [id : i64] [source-count : i64]) : i64
    (cond
      [(and (>= id 0) (< id source-count)) id]
      [(ci.intern-generated-id-active? id)
        (+ source-count (- (- (ci.intern-capacity) 1) id))]
      [else -2])))

(define (surface-identity-portable-triple-end [identity-count : i64]) : i64
  (let
    [identity-count2 : i64 (* identity-count identity-count)]
    (+ identity-count (+ identity-count2 (* identity-count2 identity-count)))))

(define (surface-identity-portable-template-offset [identity-count : i64]) : i64
  (surface-identity-portable-triple-end identity-count))

(define (surface-identity-portable-macro-global-offset [identity-count : i64]) : i64
  (+ (surface-identity-portable-template-offset identity-count) identity-count))

(define (surface-identity-portable-macro-local-offset [identity-count : i64]) : i64
  (+
    (surface-identity-portable-fresh-local-offset identity-count)
    (* (surface-identity-fresh-local-ordinal-count) identity-count)))

(define (surface-identity-portable-fresh-local-offset [identity-count : i64]) : i64
  (+
    (surface-identity-portable-macro-global-offset identity-count)
    (* 2 (* identity-count identity-count))))

(define (surface-identity-fresh-local-ordinal-count) : i64
  ;; The prior arithmetic identity family admitted ordinals [0, 2^43). Keep
  ;; that portable contract explicitly; it is a wire limit, not an intern-table
  ;; capacity calculation.
  8796093022208)

;; Nominal ids can be one intern id, a session-owned structural pair/triple, or
;; one of the compiler's syntax-identity families. Repack every component with
;; the image identity count as its portable stride. The appended ranges preserve
;; template provenance, macro ownership/depth, and structural-local ordinals;
;; hydration reconstructs them with the current session stride while retaining
;; one-word AST name fields in the frontend section. At the maximum 2^17 intern
;; count the complete portable layout ends below 3.5e18, within signed i64.
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-identity-portable-id
    [session : cis.InternStructuralSessionHandle]
    [id : i64]
    [source-count : i64]
    [identity-count : i64]) : i64
    (let
      [session-stride : i64 (ci.intern-capacity)]
      [session-stride2 : i64 (* session-stride session-stride)]
      [session-triple-offset : i64 (+ session-stride session-stride2)]
      [image-stride2 : i64 (* identity-count identity-count)]
      (cond
        [(ci.intern-composite-triple-id? id)
          (let
            [left-ref : i64
              (surface-identity-local-ref
                (ci.intern-composite-left-id-unchecked id)
                source-count)]
            [middle-ref : i64
              (surface-identity-local-ref
                (ci.intern-composite-middle-id-unchecked id)
                source-count)]
            [right-ref : i64
              (surface-identity-local-ref
                (ci.intern-composite-right-id-unchecked id)
                source-count)]
            (if (or (< left-ref 0) (< middle-ref 0) (< right-ref 0))
              -2
              (+
                identity-count
                (+
                  image-stride2
                  (+
                    (* left-ref image-stride2)
                    (+ (* middle-ref identity-count) right-ref))))))]
        [(ci.intern-composite-pair-id? id)
          (let
            [left-ref : i64
              (surface-identity-local-ref
                (ci.intern-composite-left-id-unchecked id)
                source-count)]
            [right-ref : i64
              (surface-identity-local-ref
                (ci.intern-composite-right-id-unchecked id)
                source-count)]
            (if (or (< left-ref 0) (< right-ref 0))
              -2
              (+ identity-count (+ (* left-ref identity-count) right-ref))))]
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
        [(match (cis.intern-structural-session-template-source-record-for-raw
            session
            id)
            [(Some _) true]
            [(No) false])
          (match (cis.intern-structural-session-template-source-record-for-raw
            session
            id)
            [(No) -2]
            [(Some record)
              (let
                [source-ref : i64
                  (surface-identity-local-ref
                    record.source-name-id
                    source-count)]
                (if (< source-ref 0)
                  -2
                  (+
                    (surface-identity-portable-template-offset identity-count)
                    source-ref)))])]
        [(match (cis.intern-structural-session-macro-global-record-for-raw
            session
            id)
            [(Some _) true]
            [(No) false])
          (match (cis.intern-structural-session-macro-global-record-for-raw
            session
            id)
            [(No) -2]
            [(Some record)
              (let
                [role : i64
                  (match record.role
                    [(Legacy) 0]
                    [(Context) 1])]
                [module-ref : i64
                  (surface-identity-local-ref
                    record.definition-module-id
                    source-count)]
                [source-ref : i64
                  (surface-identity-local-ref
                    record.source-name-id
                    source-count)]
                (if (or (< module-ref 0) (< source-ref 0))
                  -2
                  (+
                    (surface-identity-portable-macro-global-offset
                      identity-count)
                    (+
                      (* (+ (* role identity-count) module-ref) identity-count)
                      source-ref))))])]
        [(match (cis.intern-structural-session-macro-local-record-for-raw
            session
            id)
            [(Some _) true]
            [(No) false])
          (match (cis.intern-structural-session-macro-local-record-for-raw
            session
            id)
            [(No) -2]
            [(Some record)
              (match (cis.intern-structural-session-macro-definition-record
                session
                record.macro-definition)
                [(No) -2]
                [(Some definition)
                  (let
                    [module-ref : i64
                      (surface-identity-local-ref
                        definition.definition-module-id
                        source-count)]
                    [macro-ref : i64
                      (surface-identity-local-ref
                        definition.macro-name-id
                        source-count)]
                    [source-ref : i64
                      (surface-identity-local-ref
                        record.source-name-id
                        source-count)]
                    (if (or (< module-ref 0) (< macro-ref 0) (< source-ref 0))
                      -2
                      (+
                        (surface-identity-portable-macro-local-offset
                          identity-count)
                        (+
                          (*
                            (+
                              (*
                                (+
                                  (* record.lexical-depth identity-count)
                                  module-ref)
                                identity-count)
                              macro-ref)
                            identity-count)
                          source-ref))))])])]
        [(match (cis.intern-structural-session-fresh-local-record-for-raw
            session
            id)
            [(Some _) true]
            [(No) false])
          (match (cis.intern-structural-session-fresh-local-record-for-raw
            session
            id)
            [(No) -2]
            [(Some record)
              (let
                [source-ref : i64
                  (surface-identity-local-ref
                    record.source-name-id
                    source-count)]
                (if (or
                  (< source-ref 0)
                  (< record.ordinal 0)
                  (>=
                    record.ordinal
                    (surface-identity-fresh-local-ordinal-count)))
                  -2
                  (+
                    (surface-identity-portable-fresh-local-offset
                      identity-count)
                    (+ (* record.ordinal identity-count) source-ref))))])]
        [else (surface-identity-local-ref id source-count)]))))

(define (surface-identity-resolve-portable-id
  [session : cis.InternStructuralSessionHandle]
  [id : i64]
  [remap : (& remap (__tl_dyn-array i64))]) : i64
  (let
    [image-stride : i64 (array-length remap)]
    [image-stride2 : i64 (* image-stride image-stride)]
    [image-triple-offset : i64 (+ image-stride image-stride2)]
    [image-triple-end : i64 (surface-identity-portable-triple-end image-stride)]
    [template-offset : i64
      (surface-identity-portable-template-offset image-stride)]
    [macro-global-offset : i64
      (surface-identity-portable-macro-global-offset image-stride)]
    [macro-local-offset : i64
      (surface-identity-portable-macro-local-offset image-stride)]
    [fresh-local-offset : i64
      (surface-identity-portable-fresh-local-offset image-stride)]
    [fresh-local-end : i64
      (+
        fresh-local-offset
        (* (surface-identity-fresh-local-ordinal-count) image-stride))]
    (cond
      [(and (>= id image-triple-offset) (< id image-triple-end))
        (let
          [raw : i64 (- id image-triple-offset)]
          [module-ref : i64 (/ raw image-stride2)]
          [enum-ref : i64 (% (/ raw image-stride) image-stride)]
          [variant-ref : i64 (% raw image-stride)]
          (ci.intern-composite-triple-id
            (array-ref remap module-ref)
            (array-ref remap enum-ref)
            (array-ref remap variant-ref)))]
      [(and (>= id image-stride) (< id (+ image-stride image-stride2)))
        (let
          [raw : i64 (- id image-stride)]
          (ci.intern-composite-pair-id
            (array-ref remap (/ raw image-stride))
            (array-ref remap (% raw image-stride))))]
      [(and (>= id 0) (< id image-stride)) (array-ref remap id)]
      [(and (>= id template-offset) (< id macro-global-offset))
        (cis.intern-template-source-identity-raw
          (cis.intern-structural-session-template-source-identity
            session
            (array-ref remap (- id template-offset))))]
      [(and (>= id macro-global-offset) (< id fresh-local-offset))
        (let
          [raw : i64 (- id macro-global-offset)]
          [source-ref : i64 (% raw image-stride)]
          [owner : i64 (/ raw image-stride)]
          [module-ref : i64 (% owner image-stride)]
          [role-code : i64 (/ owner image-stride)]
          [role : cis.InternMacroGlobalRole
            (if (= role-code 0)
              Legacy
              Context)]
          (if (or (> role-code 1) (>= source-ref image-stride))
            -1
            (cis.intern-macro-global-identity-raw
              (cis.intern-structural-session-macro-global-identity
                session
                role
                (array-ref remap module-ref)
                (array-ref remap source-ref)))))]
      [(and (>= id fresh-local-offset) (< id fresh-local-end))
        (let
          [raw : i64 (- id fresh-local-offset)]
          (cis.intern-fresh-local-identity-raw
            (cis.intern-structural-session-fresh-local-identity
              session
              (/ raw image-stride)
              (array-ref remap (% raw image-stride)))))]
      [(>= id macro-local-offset)
        (let
          [raw : i64 (- id macro-local-offset)]
          [source-ref : i64 (% raw image-stride)]
          [macro-owner : i64 (/ raw image-stride)]
          [macro-ref : i64 (% macro-owner image-stride)]
          [definition-owner : i64 (/ macro-owner image-stride)]
          [module-ref : i64 (% definition-owner image-stride)]
          [depth : i64 (/ definition-owner image-stride)]
          (if (or
            (>= source-ref image-stride)
            (>= macro-ref image-stride)
            (>= module-ref image-stride))
            -1
            (let
              [definition : cis.InternMacroDefinitionIdentity
                (cis.intern-structural-session-macro-definition-identity
                  session
                  (array-ref remap module-ref)
                  (array-ref remap macro-ref))]
              (cis.intern-macro-local-identity-raw
                (cis.intern-structural-session-macro-local-identity
                  session
                  definition
                  depth
                  (array-ref remap source-ref))))))]
      [else -1])))

(define (surface-identity-generated-record-valid?
  [record : (& record SurfaceGeneratedIdentity)]
  [prior-count : i64]) : bool
  (let
    [qualified : bool record.qualified]
    [dotted : bool record.dotted]
    [ref0 : i64 record.ref0]
    [ref1 : i64 record.ref1]
    [ref2 : i64 record.ref2]
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

(define (surface-identity-payload-valid?
  [payload : (& payload SurfaceIdentityPayload)]) : bool
  (let
    [source-count : i64 (array-length payload.source-names)]
    [index : i64 0]
    [ok : bool (surface-identity-key-valid? (& payload.key))]
    (while (and ok (< index (array-length payload.generated)))
      (if (surface-identity-generated-record-valid?
        (& (array-ref payload.generated index))
        (+ source-count index))
        (set! index (+ index 1))
        (set! ok false)))
    ok))

(define (surface-identity-reader-u64!
  [reader : (&mut reader byte_reader.ByteReader)]) : i64
  (if (byte_reader.available? reader 8)
    (byte_reader.read-u64! reader)
    (let
      [offset : i64 reader.offset]
      (byte_reader.fail!
        reader
        byte_reader.error-truncated
        offset
        "surface identity: truncated u64")
      -1)))

(define (surface-identity-reader-string!
  [reader : (&mut reader byte_reader.ByteReader)]) : String
  (let
    [len : i64 (surface-identity-reader-u64! (&mut reader))]
    [offset : i64 reader.offset]
    (if (and (>= len 0) (byte_reader.available? reader len))
      (let
        [value : String
          (binary.surface-binary-bytes->string reader.bytes offset len)]
        (byte_reader.skip! reader len)
        value)
      (begin
        (byte_reader.fail!
          reader
          byte_reader.error-truncated
          offset
          "surface identity: truncated string")
        ""))))

(define (surface-identity-safe-count? [count : i64]) : bool
  (and (>= count 0) (<= count surface-identity-max-count)))

(define (surface-identity-decode [bytes : (__tl_dyn-array u8)]) : ResultSurfaceIdentityPayload
  (let
    [reader : byte_reader.ByteReader
      (byte_reader.new bytes byte_reader.unlimited-work)]
    [magic : i64 (surface-identity-reader-u64! (&mut reader))]
    [schema : i64 (surface-identity-reader-u64! (&mut reader))]
    [module-count : i64 (surface-identity-reader-u64! (&mut reader))]
    [source-count : i64 (surface-identity-reader-u64! (&mut reader))]
    [generated-count : i64 (surface-identity-reader-u64! (&mut reader))]
    (if (or
      (not (= magic surface-identity-magic))
      (not (= schema surface-identity-schema-version))
      (not (surface-identity-safe-count? module-count))
      (not (surface-identity-safe-count? source-count))
      (not (surface-identity-safe-count? generated-count)))
      (Err "surface identity: bad magic, schema, or count")
      (let
        [package-name : String (surface-identity-reader-string! (&mut reader))]
        [source-hash : String (surface-identity-reader-string! (&mut reader))]
        [compiler-build : String
          (surface-identity-reader-string! (&mut reader))]
        [configuration : String (surface-identity-reader-string! (&mut reader))]
        [modules : (__tl_dyn-array String)
          (__tl_make-array String module-count)]
        [source-names : (__tl_dyn-array String)
          (__tl_make-array String source-count)]
        [generated : (__tl_dyn-array SurfaceGeneratedIdentity)
          (__tl_make-array SurfaceGeneratedIdentity generated-count)]
        [index : i64 0]
        (while (and reader.ok? (< index module-count))
          (set!
            (array-ref modules index)
            (surface-identity-reader-string! (&mut reader)))
          (set! index (+ index 1)))
        (set! index 0)
        (while (and reader.ok? (< index source-count))
          (set!
            (array-ref source-names index)
            (surface-identity-reader-string! (&mut reader)))
          (set! index (+ index 1)))
        (set! index 0)
        (while (and reader.ok? (< index generated-count))
          (let
            [flags : i64 (surface-identity-reader-u64! (&mut reader))]
            [ref0 : i64 (surface-identity-reader-u64! (&mut reader))]
            [ref1 : i64 (surface-identity-reader-u64! (&mut reader))]
            [ref2 : i64 (surface-identity-reader-u64! (&mut reader))]
            [name : String (surface-identity-reader-string! (&mut reader))]
            (if (or (< flags 0) (> flags 7))
              (let
                [offset : i64 reader.offset]
                (byte_reader.fail!
                  (&mut reader)
                  byte_reader.error-invalid
                  offset
                  "surface identity: invalid generated identity flags"))
              unit)
            (set!
              (array-ref generated index)
              (SurfaceGeneratedIdentity
                name
                (not (= (bit-and flags surface-identity-generated-canonical) 0))
                (not (= (bit-and flags surface-identity-generated-qualified) 0))
                (not (= (bit-and flags surface-identity-generated-dotted) 0))
                ref0
                ref1
                ref2))
            (set! index (+ index 1))))
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
            [(not reader.ok?) (Err reader.error-message)]
            [(not (= reader.offset reader.end))
              (Err "surface identity: trailing payload bytes")]
            [(not (surface-identity-payload-valid? (& payload)))
              (Err "surface identity: invalid package key or identity graph")]
            [else (Ok payload)]))))))

(define (surface-identity-hydrate-generated!
  [record : SurfaceGeneratedIdentity]
  [remap : (& remap (__tl_dyn-array i64))]) : i64
  (let
    [name : String record.name]
    [canonical : bool record.canonical]
    [qualified : bool record.qualified]
    [dotted : bool record.dotted]
    [ref0 : i64 record.ref0]
    [ref1 : i64 record.ref1]
    [ref2 : i64 record.ref2]
    (cond
      [qualified
        (if canonical
          (ci.intern-generated-canonical-qualified-name
            name
            (array-ref remap ref0)
            (array-ref remap ref1))
          (ci.intern-generated-qualified-name
            (& name)
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
            (& name)
            (array-ref remap ref0)
            (array-ref remap ref1)
            (array-ref remap ref2)))]
      [canonical (ci.intern-generated-canonical-name name)]
      [else (ci.intern-generated-name (& name))])))

(define (surface-identity-hydrate-payload
  [payload : SurfaceIdentityPayload]
  [expected-key : (& expected-key SurfaceIdentityKey)]) : ResultSurfaceIdentityHydration
  (if (not (surface-identity-key-eq? payload.key expected-key))
    (KeyMismatch "surface identity: package key mismatch")
    (let
      [source-count : i64 (array-length payload.source-names)]
      [remap : (__tl_dyn-array i64)
        (__tl_make-array i64 (+ source-count (array-length payload.generated)))]
      [index : i64 0]
      (while (< index source-count)
        (set!
          (array-ref remap index)
          (ci.intern
            (surface-identity-string-array-shared-view
              payload.source-names
              index)))
        (set! index (+ index 1)))
      (set! index 0)
      (while (< index (array-length payload.generated))
        (set!
          (array-ref remap (+ source-count index))
          (surface-identity-hydrate-generated!
            (surface-identity-string-array-shared-view payload.generated index)
            remap))
        (set! index (+ index 1)))
      (Ok (SurfaceIdentityHydration payload.key remap)))))

(define (surface-identity-hydrate
  [bytes : (__tl_dyn-array u8)]
  [expected-key : (& expected-key SurfaceIdentityKey)]) : ResultSurfaceIdentityHydration
  (match (surface-identity-decode bytes)
    [(Err message) (Err message)]
    [(Ok payload) (surface-identity-hydrate-payload payload expected-key)]))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (defenum ResultSurfaceIdentityBytes
    (Ok (__tl_dyn-array u8))
    (Err String)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-identity-push-string!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [text : String]) : unit
    (byte_le.push-u64! out (binary.surface-binary-string-length text))
    (binary.surface-binary-push-string! out text)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-identity-generated-record [id : i64] [source-count : i64]) : SurfaceGeneratedIdentity
    (let
      [qualified : bool (ci.intern-qualified? id)]
      [dotted : bool (ci.intern-dotted? id)]
      [ref0 : i64 -1]
      [ref1 : i64 -1]
      [ref2 : i64 -1]
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
        (when
          dotted
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
              source-count))))
      (SurfaceGeneratedIdentity
        (ci.intern-str id)
        (ci.intern-generated-canonical-id? id)
        qualified
        dotted
        ref0
        ref1
        ref2))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-identity-capture [key : SurfaceIdentityKey]) : SurfaceIdentityPayload
    (let
      [source-count : i64 (ci.intern-pool-len)]
      [generated-count : i64 (ci.intern-generated-count)]
      [source-names : (__tl_dyn-array String)
        (__tl_make-array String source-count)]
      [generated : (__tl_dyn-array SurfaceGeneratedIdentity)
        (__tl_make-array SurfaceGeneratedIdentity generated-count)]
      [index : i64 0]
      (while (< index source-count)
        (set! (array-ref source-names index) (ci.intern-str index))
        (set! index (+ index 1)))
      (set! index 0)
      (while (< index generated-count)
        (set!
          (array-ref generated index)
          (surface-identity-generated-record
            (ci.intern-generated-id-at-allocation-index index)
            source-count))
        (set! index (+ index 1)))
      (SurfaceIdentityPayload key source-names generated))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-identity-encode [payload : SurfaceIdentityPayload]) : ResultSurfaceIdentityBytes
    (if (not (surface-identity-payload-valid? (& payload)))
      (Err "surface identity: invalid package key or identity graph")
      (let
        [key : SurfaceIdentityKey payload.key]
        [source-names : (__tl_dyn-array String) payload.source-names]
        [generated : (__tl_dyn-array SurfaceGeneratedIdentity)
          payload.generated]
        [out : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-new)]
        [index : i64 0]
        (byte_le.push-u64! (&mut out) surface-identity-magic)
        (byte_le.push-u64! (&mut out) surface-identity-schema-version)
        (byte_le.push-u64! (&mut out) (array-length key.modules))
        (byte_le.push-u64! (&mut out) (array-length source-names))
        (byte_le.push-u64! (&mut out) (array-length generated))
        (surface-identity-push-string! (&mut out) key.package-name)
        (surface-identity-push-string! (&mut out) key.source-hash)
        (surface-identity-push-string! (&mut out) key.compiler-build)
        (surface-identity-push-string! (&mut out) key.configuration)
        (while (< index (array-length key.modules))
          (surface-identity-push-string!
            (&mut out)
            (surface-identity-string-array-shared-view key.modules index))
          (set! index (+ index 1)))
        (set! index 0)
        (while (< index (array-length source-names))
          (surface-identity-push-string!
            (&mut out)
            (surface-identity-string-array-shared-view source-names index))
          (set! index (+ index 1)))
        (set! index 0)
        (while (< index (array-length generated))
          (let
            [record : SurfaceGeneratedIdentity
              (surface-identity-string-array-shared-view generated index)]
            [flags : i64
              (+
                (if record.canonical
                  surface-identity-generated-canonical
                  0)
                (+
                  (if record.qualified
                    surface-identity-generated-qualified
                    0)
                  (if record.dotted
                    surface-identity-generated-dotted
                    0)))]
            (byte_le.push-u64! (&mut out) flags)
            (byte_le.push-u64! (&mut out) record.ref0)
            (byte_le.push-u64! (&mut out) record.ref1)
            (byte_le.push-u64! (&mut out) record.ref2)
            (surface-identity-push-string! (&mut out) record.name)
            (set! index (+ index 1))))
        (Ok (byte_buf_core.byte-buf-builder-finish-array (& out)))))))