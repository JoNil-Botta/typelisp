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

(defmacro (surface-identity-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(defmacro (surface-identity-string-array-shared-view
  [items : Expr]
  [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (import stdlib.byte_buf_core))

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

(defstruct SurfaceIdentityReader
  (bytes (__tl_dyn-array u8))
  (offset (__tl_dyn-array i64))
  (ok (__tl_dyn-array bool))
  (message (__tl_dyn-array String)))

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

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-identity-empty-bytes) : (__tl_dyn-array u8)
    (__tl_make-array u8 0)))

(define (surface-identity-string-eq?
  [left : (& left str)]
  [right : (& right str)]) : bool
  (let
    [left-len : i64 (binary.surface-binary-string-length left)]
    [right-len : i64 (binary.surface-binary-string-length right)]
    [index : i64 0]
    [equal : bool (= left-len right-len)]
    (begin
      (while (and equal (< index left-len))
        (if (=
          (binary.surface-binary-string-ref left index)
          (binary.surface-binary-string-ref right index))
          (set! index (+ index 1))
          (set! equal false)))
      equal)))

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
    (begin
      (while (and (not decided) (< index limit))
        (let
          [left-char : char (binary.surface-binary-string-ref left index)]
          [right-char : char (binary.surface-binary-string-ref right index)]
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

(define (surface-identity-module-set-canonical?
  [modules : (& modules (__tl_dyn-array String))]) : bool
  (let
    [index : i64 0]
    [ok : bool (> (array-length modules) 0)]
    (begin
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
      ok)))

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
    (begin
      (while (and equal (< index (array-length left)))
        (if (surface-identity-string-eq?
          (array-ref left index)
          (array-ref right index))
          (set! index (+ index 1))
          (set! equal false)))
      equal)))

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
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
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

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-identity-portable-module-ref
    [stored-module-id : i64]
    [source-count : i64]
    [identity-count : i64]) : i64
    (if (= stored-module-id 0)
      identity-count
      (surface-identity-local-ref (- stored-module-id 1) source-count))))

;; Nominal ids can be one intern id, a session-owned structural pair/triple, or
;; one of the compiler's syntax-identity families. Repack every component with
;; the image identity count as its portable stride. The appended ranges preserve
;; template provenance, macro ownership/depth, and structural-local ordinals;
;; hydration reconstructs them with the current session stride while retaining
;; one-word AST name fields in the frontend section. At the maximum 2^17 intern
;; count the complete portable layout ends below 3.5e18, within signed i64.
(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
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
            [(cis.InternMaybeTemplateSourceRecord.Some _) true]
            [(cis.InternMaybeTemplateSourceRecord.No) false])
          (match (cis.intern-structural-session-template-source-record-for-raw
            session
            id)
            [(cis.InternMaybeTemplateSourceRecord.No) -2]
            [(cis.InternMaybeTemplateSourceRecord.Some record)
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
            [(cis.InternMaybeMacroGlobalRecord.Some _) true]
            [(cis.InternMaybeMacroGlobalRecord.No) false])
          (match (cis.intern-structural-session-macro-global-record-for-raw
            session
            id)
            [(cis.InternMaybeMacroGlobalRecord.No) -2]
            [(cis.InternMaybeMacroGlobalRecord.Some record)
              (let
                [role : i64
                  (match record.role
                    [(cis.InternMacroGlobalRole.Legacy) 0]
                    [(cis.InternMacroGlobalRole.Context) 1])]
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
            [(cis.InternMaybeMacroLocalRecord.Some _) true]
            [(cis.InternMaybeMacroLocalRecord.No) false])
          (match (cis.intern-structural-session-macro-local-record-for-raw
            session
            id)
            [(cis.InternMaybeMacroLocalRecord.No) -2]
            [(cis.InternMaybeMacroLocalRecord.Some record)
              (match (cis.intern-structural-session-macro-definition-record
                session
                record.macro-definition)
                [(cis.InternMaybeMacroDefinitionRecord.No) -2]
                [(cis.InternMaybeMacroDefinitionRecord.Some definition)
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
            [(cis.InternMaybeFreshLocalRecord.Some _) true]
            [(cis.InternMaybeFreshLocalRecord.No) false])
          (match (cis.intern-structural-session-fresh-local-record-for-raw
            session
            id)
            [(cis.InternMaybeFreshLocalRecord.No) -2]
            [(cis.InternMaybeFreshLocalRecord.Some record)
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
              cis.InternMacroGlobalRole.Legacy
              cis.InternMacroGlobalRole.Context)]
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
    (begin
      (while (and ok (< index (array-length payload.generated)))
        (if (surface-identity-generated-record-valid?
          (& (array-ref payload.generated index))
          (+ source-count index))
          (set! index (+ index 1))
          (set! ok false)))
      ok)))

(define (surface-identity-reader-new [bytes : (__tl_dyn-array u8)]) : SurfaceIdentityReader
  (let
    [offset : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [ok : (__tl_dyn-array bool) (__tl_make-array bool 1)]
    [message : (__tl_dyn-array String) (__tl_make-array String 1)]
    (begin
      (set! (array-ref offset 0) 0)
      (set! (array-ref ok 0) true)
      (set! (array-ref message 0) "")
      (SurfaceIdentityReader bytes offset ok message))))

(define (surface-identity-reader-fail!
  [reader : (& reader SurfaceIdentityReader)]
  [message : String]) : unit
  (if (array-ref reader.ok 0)
    (begin
      (set! (array-ref reader.ok 0) false)
      (set! (array-ref reader.message 0) message))
    unit))

(define (surface-identity-reader-u64!
  [reader : (& reader SurfaceIdentityReader)]) : i64
  (let
    [offset : i64 (array-ref reader.offset 0)]
    (if (or
      (not (array-ref reader.ok 0))
      (> offset (- (array-length reader.bytes) 8)))
      (begin
        (surface-identity-reader-fail! reader "surface identity: truncated u64")
        -1)
      (begin
        (set! (array-ref reader.offset 0) (+ offset 8))
        (binary.surface-binary-read-u64 reader.bytes offset)))))

(define (surface-identity-reader-string!
  [reader : (& reader SurfaceIdentityReader)]) : String
  (let
    [len : i64 (surface-identity-reader-u64! reader)]
    [offset : i64 (array-ref reader.offset 0)]
    (if (or
      (< len 0)
      (> offset (array-length reader.bytes))
      (> len (- (array-length reader.bytes) offset)))
      (begin
        (surface-identity-reader-fail!
          reader
          "surface identity: truncated string")
        "")
      (let
        [value : String
          (binary.surface-binary-bytes->string reader.bytes offset len)]
        (begin
          (set! (array-ref reader.offset 0) (+ offset len))
          value)))))

(define (surface-identity-safe-count? [count : i64]) : bool
  (and (>= count 0) (<= count surface-identity-max-count)))

(define (surface-identity-decode [bytes : (__tl_dyn-array u8)]) : ResultSurfaceIdentityPayload
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
        [modules : (__tl_dyn-array String)
          (__tl_make-array String module-count)]
        [source-names : (__tl_dyn-array String)
          (__tl_make-array String source-count)]
        [generated : (__tl_dyn-array SurfaceGeneratedIdentity)
          (__tl_make-array SurfaceGeneratedIdentity generated-count)]
        [index : i64 0]
        (begin
          (while (and (array-ref reader.ok 0) (< index module-count))
            (begin
              (set!
                (array-ref modules index)
                (surface-identity-reader-string! reader))
              (set! index (+ index 1))))
          (set! index 0)
          (while (and (array-ref reader.ok 0) (< index source-count))
            (begin
              (set!
                (array-ref source-names index)
                (surface-identity-reader-string! reader))
              (set! index (+ index 1))))
          (set! index 0)
          (while (and (array-ref reader.ok 0) (< index generated-count))
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
                (set!
                  (array-ref generated index)
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
              [(not (array-ref reader.ok 0))
                (ResultSurfaceIdentityPayload.Err
                  (surface-identity-string-array-shared-view reader.message 0))]
              [(not (= (array-ref reader.offset 0) (array-length reader.bytes)))
                (ResultSurfaceIdentityPayload.Err
                  "surface identity: trailing payload bytes")]
              [(not (surface-identity-payload-valid? (& payload)))
                (ResultSurfaceIdentityPayload.Err
                  "surface identity: invalid package key or identity graph")]
              [else (ResultSurfaceIdentityPayload.Ok payload)])))))))

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
  (if (not (surface-identity-key-eq? payload.key expected-key))
    (ResultSurfaceIdentityHydration.KeyMismatch
      "surface identity: package key mismatch")
    (let
      [source-count : i64 (array-length payload.source-names)]
      [remap : (__tl_dyn-array i64)
        (__tl_make-array i64 (+ source-count (array-length payload.generated)))]
      [index : i64 0]
      (begin
        (while (< index source-count)
          (begin
            (set!
              (array-ref remap index)
              (ci.intern
                (surface-identity-string-array-shared-view
                  payload.source-names
                  index)))
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index (array-length payload.generated))
          (begin
            (set!
              (array-ref remap (+ source-count index))
              (surface-identity-hydrate-generated!
                (surface-identity-string-array-shared-view
                  payload.generated
                  index)
                remap))
            (set! index (+ index 1))))
        (ResultSurfaceIdentityHydration.Ok
          (SurfaceIdentityHydration payload.key remap))))))

(define (surface-identity-hydrate
  [bytes : (__tl_dyn-array u8)]
  [expected-key : SurfaceIdentityKey]) : ResultSurfaceIdentityHydration
  (match (surface-identity-decode bytes)
    [(ResultSurfaceIdentityPayload.Err message)
      (ResultSurfaceIdentityHydration.Err message)]
    [(ResultSurfaceIdentityPayload.Ok payload)
      (surface-identity-hydrate-payload payload expected-key)]))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (defenum ResultSurfaceIdentityBytes
    (Ok (__tl_dyn-array u8))
    (Err String)))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-identity-push-string!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [text : String]) : unit
    (begin
      (binary.surface-binary-push-u64!
        out
        (binary.surface-binary-string-length text))
      (binary.surface-binary-push-string! out text))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
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
          ref2)))))

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
      (begin
        (while (< index source-count)
          (begin
            (set! (array-ref source-names index) (ci.intern-str index))
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index generated-count)
          (begin
            (set!
              (array-ref generated index)
              (surface-identity-generated-record
                (ci.intern-generated-id-at-allocation-index index)
                source-count))
            (set! index (+ index 1))))
        (SurfaceIdentityPayload key source-names generated)))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-identity-encode [payload : SurfaceIdentityPayload]) : ResultSurfaceIdentityBytes
    (if (not (surface-identity-payload-valid? (& payload)))
      (ResultSurfaceIdentityBytes.Err
        "surface identity: invalid package key or identity graph")
      (let
        [key : SurfaceIdentityKey payload.key]
        [source-names : (__tl_dyn-array String) payload.source-names]
        [generated : (__tl_dyn-array SurfaceGeneratedIdentity)
          payload.generated]
        [out : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-new)]
        [index : i64 0]
        (begin
          (binary.surface-binary-push-u64! (&mut out) surface-identity-magic)
          (binary.surface-binary-push-u64!
            (&mut out)
            surface-identity-schema-version)
          (binary.surface-binary-push-u64!
            (&mut out)
            (array-length key.modules))
          (binary.surface-binary-push-u64!
            (&mut out)
            (array-length source-names))
          (binary.surface-binary-push-u64! (&mut out) (array-length generated))
          (surface-identity-push-string! (&mut out) key.package-name)
          (surface-identity-push-string! (&mut out) key.source-hash)
          (surface-identity-push-string! (&mut out) key.compiler-build)
          (surface-identity-push-string! (&mut out) key.configuration)
          (while (< index (array-length key.modules))
            (begin
              (surface-identity-push-string!
                (&mut out)
                (surface-identity-string-array-shared-view key.modules index))
              (set! index (+ index 1))))
          (set! index 0)
          (while (< index (array-length source-names))
            (begin
              (surface-identity-push-string!
                (&mut out)
                (surface-identity-string-array-shared-view source-names index))
              (set! index (+ index 1))))
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
              (begin
                (binary.surface-binary-push-u64! (&mut out) flags)
                (binary.surface-binary-push-u64! (&mut out) record.ref0)
                (binary.surface-binary-push-u64! (&mut out) record.ref1)
                (binary.surface-binary-push-u64! (&mut out) record.ref2)
                (surface-identity-push-string! (&mut out) record.name)
                (set! index (+ index 1)))))
          (ResultSurfaceIdentityBytes.Ok
            (byte_buf_core.byte-buf-builder-finish-array (& out))))))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-test-macro-global-id
    [session : cis.InternStructuralSessionHandle]
    [module-id : i64]
    [source-name-id : i64]
    [legacy : bool]) : i64
    (cis.intern-macro-global-identity-raw
      (cis.intern-structural-session-macro-global-identity
        session
        (if legacy
          cis.InternMacroGlobalRole.Legacy
          cis.InternMacroGlobalRole.Context)
        module-id
        source-name-id))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-test-macro-local-id
    [session : cis.InternStructuralSessionHandle]
    [module-id : i64]
    [macro-name-id : i64]
    [depth : i64]
    [source-name-id : i64]) : i64
    (let
      [definition : cis.InternMacroDefinitionIdentity
        (cis.intern-structural-session-macro-definition-identity
          session
          module-id
          macro-name-id)]
      (cis.intern-macro-local-identity-raw
        (cis.intern-structural-session-macro-local-identity
          session
          definition
          depth
          source-name-id)))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-test-copy-bytes [bytes : (__tl_dyn-array u8)]) : (__tl_dyn-array
      u8)
    (let
      [out : (__tl_dyn-array u8) (__tl_make-array u8 (array-length bytes))]
      [index : i64 0]
      (begin
        (while (< index (array-length bytes))
          (begin
            (set! (array-ref out index) (array-ref bytes index))
            (set! index (+ index 1))))
        out))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-test-key) : SurfaceIdentityKey
    (let
      [modules : (__tl_dyn-array String) (__tl_make-array String 2)]
      (begin
        (set! (array-ref modules 0) "pkg/a.tl")
        (set! (array-ref modules 1) "pkg/b.tl")
        (SurfaceIdentityKey "pkg" modules "source-hash" "compiler-build" "host")))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-remap-test-ok?
    [hydration : SurfaceIdentityHydration]
    [source-count : i64]
    [generated-count : i64]) : bool
    (let
      [remap : (__tl_dyn-array i64) hydration.remap]
      (and
        (= (array-length remap) (+ source-count generated-count))
        (= generated-count 4)
        (surface-identity-string-eq?
          (ci.intern-str (array-ref remap 0))
          "alpha")
        (surface-identity-string-eq?
          (ci.intern-str (array-ref remap 1))
          "module")
        (surface-identity-string-eq? (ci.intern-str (array-ref remap 2)) "base")
        (ci.intern-qualified? (array-ref remap (+ source-count 1)))
        (ci.intern-dotted? (array-ref remap (+ source-count 2)))
        (ci.intern-generated-canonical-id? (array-ref remap (+ source-count 3)))))))

(cfg
  compiler-surface-selftest
  (define (surface-identity-tests-ok?) : bool
    (let
      [_reset : unit (ci.intern-reset!)]
      [alpha : i64 (ci.intern "alpha")]
      [module-id : i64 (ci.intern "module")]
      [base-id : i64 (ci.intern "base")]
      [root-module-id : i64 (ci.intern "root/module")]
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
      [payload : SurfaceIdentityPayload
        (surface-identity-capture (surface-identity-shared-view key))]
      [source-count : i64 (array-length payload.source-names)]
      [identity-count : i64 (+ source-count (array-length payload.generated))]
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [pair-id : i64 (ci.intern-composite-pair-id module-id base-id)]
      [triple-id : i64 (ci.intern-composite-triple-id module-id base-id alpha)]
      [template-id : i64
        (cis.intern-template-source-identity-raw
          (cis.intern-structural-session-template-source-identity session alpha))]
      [fresh-local-id : i64
        (cis.intern-fresh-local-identity-raw
          (cis.intern-structural-session-fresh-local-identity session 7 alpha))]
      [macro-global-id : i64
        (surface-identity-test-macro-global-id session module-id alpha false)]
      [macro-global-root-id : i64
        (surface-identity-test-macro-global-id
          session
          root-module-id
          base-id
          true)]
      [macro-local-id : i64
        (surface-identity-test-macro-local-id
          session
          module-id
          base-id
          1536
          alpha)]
      [portable-pair : i64
        (surface-identity-portable-id
          session
          pair-id
          source-count
          identity-count)]
      [portable-triple : i64
        (surface-identity-portable-id
          session
          triple-id
          source-count
          identity-count)]
      [portable-template : i64
        (surface-identity-portable-id
          session
          template-id
          source-count
          identity-count)]
      [portable-fresh-local : i64
        (surface-identity-portable-id
          session
          fresh-local-id
          source-count
          identity-count)]
      [portable-macro-global : i64
        (surface-identity-portable-id
          session
          macro-global-id
          source-count
          identity-count)]
      [portable-macro-global-root : i64
        (surface-identity-portable-id
          session
          macro-global-root-id
          source-count
          identity-count)]
      [portable-macro-local : i64
        (surface-identity-portable-id
          session
          macro-local-id
          source-count
          identity-count)]
      (if (not (= alpha 0))
        false
        (match (surface-identity-encode (surface-identity-shared-view payload))
          [(ResultSurfaceIdentityBytes.Err _) false]
          [(ResultSurfaceIdentityBytes.Ok bytes)
            (let
              [copy : (__tl_dyn-array u8)
                (surface-identity-test-copy-bytes
                  (surface-identity-shared-view bytes))]
              (begin
                (ci.intern-reset!)
                (let
                  [unrelated : i64 (ci.intern "unrelated")]
                  (match (surface-identity-hydrate
                    bytes
                    (surface-identity-shared-view key))
                    [(ResultSurfaceIdentityHydration.Err _) false]
                    [(ResultSurfaceIdentityHydration.KeyMismatch _) false]
                    [(ResultSurfaceIdentityHydration.Ok hydration)
                      (let
                        [remap : (__tl_dyn-array i64)
                          (surface-identity-shared-view hydration.remap)]
                        [mapped-module : i64 (array-ref remap 1)]
                        [mapped-base : i64 (array-ref remap 2)]
                        [mapped-alpha : i64 (array-ref remap 0)]
                        [mapped-root-module : i64 (array-ref remap 3)]
                        [hydrated-intern-state : ci.InternCompatState
                          (ci.intern-compat-state-capture-active)]
                        [hydrated-session : cis.InternStructuralSessionHandle
                          (cis.intern-structural-session-handle-from-source-names
                            (ci.intern-source-name-session-handle-from-state
                              hydrated-intern-state))]
                        (and
                          (= unrelated 0)
                          (surface-identity-remap-test-ok?
                            (surface-identity-shared-view hydration)
                            source-count
                            (array-length payload.generated))
                          (=
                            (surface-identity-resolve-portable-id
                              hydrated-session
                              portable-pair
                              remap)
                            (ci.intern-composite-pair-id
                              mapped-module
                              mapped-base))
                          (=
                            (surface-identity-resolve-portable-id
                              hydrated-session
                              portable-triple
                              remap)
                            (ci.intern-composite-triple-id
                              mapped-module
                              mapped-base
                              mapped-alpha))
                          (=
                            (surface-identity-resolve-portable-id
                              hydrated-session
                              portable-template
                              remap)
                            (cis.intern-template-source-identity-raw
                              (cis.intern-structural-session-template-source-identity
                                hydrated-session
                                mapped-alpha)))
                          (=
                            (surface-identity-resolve-portable-id
                              hydrated-session
                              portable-fresh-local
                              remap)
                            (cis.intern-fresh-local-identity-raw
                              (cis.intern-structural-session-fresh-local-identity
                                hydrated-session
                                7
                                mapped-alpha)))
                          (=
                            (surface-identity-resolve-portable-id
                              hydrated-session
                              portable-macro-global
                              remap)
                            (surface-identity-test-macro-global-id
                              hydrated-session
                              mapped-module
                              mapped-alpha
                              false))
                          (=
                            (surface-identity-resolve-portable-id
                              hydrated-session
                              portable-macro-global-root
                              remap)
                            (surface-identity-test-macro-global-id
                              hydrated-session
                              mapped-root-module
                              mapped-base
                              true))
                          (=
                            (surface-identity-resolve-portable-id
                              hydrated-session
                              portable-macro-local
                              remap)
                            (surface-identity-test-macro-local-id
                              hydrated-session
                              mapped-module
                              mapped-base
                              1536
                              mapped-alpha))
                          (match (surface-identity-decode copy)
                            [(ResultSurfaceIdentityPayload.Err _) false]
                            [(ResultSurfaceIdentityPayload.Ok decoded)
                              (surface-identity-key-eq? decoded.key key)])))]))))])))))

(cfg
  compiler-surface-selftest
  (define (main) : i64
    (if (surface-identity-tests-ok?)
      42
      1)))