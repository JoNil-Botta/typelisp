;; tlci_core.tl - TypeLisp comptime image v2 and metadata v1/v2 parse/emit helpers.
;;
;; Package emission selects metadata-only or deterministic multi-entry native
;; images, and this module also assembles the focused dispatch proof used by
;; the loader smoke.
(import stdlib.byte_buf_core)
(import stdlib.byte_le)
(import stdlib.comptime)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import compiler_intern as ci)
(import read as reader)

(defmacro (tlci-host-callback-name-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(define (tlci-symbol-text [name-id : ci.InternSyntaxId]) : String
  (reader.symbol-text-for-syntax-id name-id))

(define (tlci-string-length [text : (& text str)]) : i64
  (__tl_string_length text))

(define (tlci-string-ref [text : (& text str)] [index : i64]) : char
  (__tl_string_ref text index))

(defstruct TlciSpmdSpecialization
  (abi String)
  (backend String)
  (lanes i64)
  (args String)
  (result String)
  (index-param i64)
  (symbol String))

(import (vector.vector TlciSpmdSpecialization core) as tlci_specialization_vec)

;: Specializations of one helper, in metadata order.
(defstruct TlciSpmdSpecializations
  (items tlci_specialization_vec.Vec))

(defstruct TlciSpmdCallable
  (name String)
  (signature String)
  (specializations TlciSpmdSpecializations))

(import (vector.vector TlciSpmdCallable core) as tlci_callable_vec)

;: Helper records of one metadata block, in metadata order.
(defstruct TlciSpmdCallables
  (items tlci_callable_vec.Vec))

(define (tlci-make-spmd-specialization
  [abi : String]
  [backend : String]
  [lanes : i64]
  [args : String]
  [result : String]
  [index-param : i64]
  [symbol : String]) : TlciSpmdSpecialization
  (TlciSpmdSpecialization abi backend lanes args result index-param symbol))

(define (tlci-spmd-specializations-with-capacity [capacity : i64]) : TlciSpmdSpecializations
  (TlciSpmdSpecializations (tlci_specialization_vec.with-capacity capacity)))

(define (tlci-spmd-specializations-empty) : TlciSpmdSpecializations
  (tlci-spmd-specializations-with-capacity 0))

(define (tlci-spmd-specializations-len [seq : (& seq TlciSpmdSpecializations)]) : i64
  (tlci_specialization_vec.len (& seq.items)))

(define (tlci-spmd-specializations-ref
  [seq : (& seq TlciSpmdSpecializations)]
  [index : i64]) : TlciSpmdSpecialization
  (clone (array-ref (tlci_specialization_vec.slots (& seq.items)) index)))

(define (tlci-spmd-specializations-push
  [items : TlciSpmdSpecializations]
  [item : TlciSpmdSpecialization]) : TlciSpmdSpecializations
  (let
    [next : TlciSpmdSpecializations items]
    (tlci_specialization_vec.push-ref! (&mut next.items) item)
    next))

(define (tlci-spmd-specializations-push!
  [items : (&mut items TlciSpmdSpecializations)]
  [item : TlciSpmdSpecialization]) : unit
  (tlci_specialization_vec.push-ref! (&mut items.items) item))

(define (tlci-make-spmd-callable
  [name : String]
  [signature : String]
  [specializations : TlciSpmdSpecializations]) : TlciSpmdCallable
  (TlciSpmdCallable name signature specializations))

(define (tlci-spmd-callables-with-capacity [capacity : i64]) : TlciSpmdCallables
  (TlciSpmdCallables (tlci_callable_vec.with-capacity capacity)))

(define (tlci-spmd-callables-empty) : TlciSpmdCallables
  (tlci-spmd-callables-with-capacity 0))

(define (tlci-spmd-callables-len [seq : (& seq TlciSpmdCallables)]) : i64
  (tlci_callable_vec.len (& seq.items)))

(define (tlci-spmd-callables-ref
  [seq : (& seq TlciSpmdCallables)]
  [index : i64]) : TlciSpmdCallable
  (clone (array-ref (tlci_callable_vec.slots (& seq.items)) index)))

(define (tlci-spmd-callables-push
  [items : TlciSpmdCallables]
  [item : TlciSpmdCallable]) : TlciSpmdCallables
  (let
    [next : TlciSpmdCallables items]
    (tlci_callable_vec.push-ref! (&mut next.items) item)
    next))

(define (tlci-spmd-callables-push!
  [items : (&mut items TlciSpmdCallables)]
  [item : TlciSpmdCallable]) : unit
  (tlci_callable_vec.push-ref! (&mut items.items) item))

(defstruct TlciMetadata
  (version String)
  (package-name String)
  (package-version String)
  (spmd-callables TlciSpmdCallables))

(define (tlci-make-metadata
  [version : String]
  [package-name : String]
  [package-version : String]) : TlciMetadata
  (TlciMetadata
    version
    package-name
    package-version
    (tlci-spmd-callables-empty)))

(define (tlci-make-metadata-v2
  [package-name : String]
  [package-version : String]
  [spmd-callables : TlciSpmdCallables]) : TlciMetadata
  (TlciMetadata "v2" package-name package-version spmd-callables))

(defstruct TlciImage
  (host-platform i64)
  (callback-abi-version i64)
  (compiler-build-hash String)
  (metadata TlciMetadata)
  (rodata (__tl_dyn-array u8))
  (code (__tl_dyn-array u8))
  (fixups (__tl_dyn-array u8))
  (entries (__tl_dyn-array u8))
  (symbols (__tl_dyn-array u8))
  (imports (__tl_dyn-array u8)))

;; Construct the aggregate in its declaring module. Besides keeping the tlci
;; API concise, this lets the published stage0 compile dotted importers before
;; its imported-nominal constructor lowering is bootstrapped forward.
(define (tlci-make-image
  [host-platform : i64]
  [callback-abi-version : i64]
  [compiler-build-hash : String]
  [metadata : TlciMetadata]
  [rodata : (__tl_dyn-array u8)]
  [code : (__tl_dyn-array u8)]
  [fixups : (__tl_dyn-array u8)]
  [entries : (__tl_dyn-array u8)]
  [symbols : (__tl_dyn-array u8)]
  [imports : (__tl_dyn-array u8)]) : TlciImage
  (TlciImage
    host-platform
    callback-abi-version
    compiler-build-hash
    metadata
    rodata
    code
    fixups
    entries
    symbols
    imports))

(defenum ResultTlciString
  (Ok String)
  (Err String))

(defenum ResultTlciI64
  (Ok i64)
  (Err String))

(defenum ResultTlciSpmdSpecialization
  (Ok TlciSpmdSpecialization)
  (Err String))

(defenum ResultTlciSpmdCallable
  (Ok TlciSpmdCallable)
  (Err String))

(defenum ResultTlciSpmdCallables
  (Ok TlciSpmdCallables)
  (Err String))

(defenum ResultTlciMetadata
  (Ok TlciMetadata)
  (Err String))

(defenum ResultTlciImage
  (Ok TlciImage)
  (Err String))

(defenum ResultTlciBytes
  (Ok (__tl_dyn-array u8))
  (Err String))

(defenum TlciImageClassification
  (MetadataOnly)
  (CodeBearing))

(defenum TlciImageHostAdmission
  (MetadataOnly)
  (CodeBearing)
  (Rejected String))

;; The container field historically named `compiler-build-hash` is the exact
;; producer-compiler identity for compiler-internal sections.  Native callback
;; catalogs remain governed by their ABI/schema checks; only frontend surface
;; hydration uses this stricter admission result.
(defenum TlciProducerIdentityAdmission
  (ExactMatch)
  (Mismatch)
  (Missing)
  (Legacy)
  (Malformed))

(define tlci-legacy-package-producer-identity : String
  "typelisp-selfhost-v1")

(define (tlci-producer-identity-hex-char? [value : char]) : bool
  (or (and (>= value '0') (<= value '9')) (and (>= value 'a') (<= value 'f'))))

(define (tlci-producer-identity-valid-from?
  [identity : (& identity str)]
  [index : i64]) : bool
  (if (>= index (tlci-string-length identity))
    true
    (and
      (tlci-producer-identity-hex-char? (tlci-string-ref identity index))
      (tlci-producer-identity-valid-from? identity (+ index 1)))))

;; Git's full object name is independent of host OS, build date, checkout path,
;; and other temporary build locations while changing with the checked-in
;; compiler source revision.
(define (tlci-producer-identity-valid? [identity : (& identity str)]) : bool
  (and
    (= (tlci-string-length identity) 40)
    (tlci-producer-identity-valid-from? identity 0)))

(define (tlci-producer-identity-admit
  [image-identity : (& image-identity str)]
  [running-identity : (& running-identity str)]) : TlciProducerIdentityAdmission
  (cond
    [(or
        (= (tlci-string-length image-identity) 0)
        (= (tlci-string-length running-identity) 0))
      Missing]
    [(or
        (string.eq image-identity tlci-legacy-package-producer-identity)
        (string.eq image-identity "unknown")
        (string.eq running-identity tlci-legacy-package-producer-identity)
        (string.eq running-identity "unknown"))
      Legacy]
    [(not (tlci-producer-identity-valid? image-identity)) Malformed]
    [(not (tlci-producer-identity-valid? running-identity)) Malformed]
    [(string.eq image-identity running-identity) ExactMatch]
    [else Mismatch]))

;; Additive package payloads live in the v2 rodata section behind a small
;; directory/trailer envelope. Native-only v2 images keep their byte layout:
;; no envelope is emitted when there are no auxiliary sections. Keeping this
;; directory independent of any one package lets frontend surfaces, macro
;; catalogs, and future package facts share the same container contract.
(defstruct TlciAuxSection
  (kind i64)
  (schema-version i64)
  (payload (__tl_dyn-array u8)))

(defstruct TlciAuxDirectory
  (base-len i64)
  (directory-offset i64)
  (count i64)
  (trailer-offset i64))

(defenum ResultTlciAuxDirectory
  (Missing)
  (Ok TlciAuxDirectory)
  (Err String))

(defenum ResultTlciAuxBytes
  (Ok (__tl_dyn-array u8))
  (Err String))

(defenum ResultTlciAuxLookup
  (Missing)
  (Ok i64 (__tl_dyn-array u8))
  (Err String))

;; Package source ownership is an additive auxiliary section.  The digest is
;; deliberately an integrity/reproducibility identity rather than a
;; cryptographic authenticity proof; the transcript and rolling algorithm are
;; fixed by `tlci-package-source-binding-schema-version`.
(defenum TlciPackageSourceBindingRead
  (Bound i64)
  (MissingOrLegacy)
  (UnsupportedSchema i64)
  (Malformed String))

(defenum TlciPackageSourceBindingAdmission
  (Match i64)
  ;; Keep this ordering stable: expected/current-source digest first, actual
  ;; image digest second.
  (Mismatch i64 i64)
  (MissingOrLegacy)
  (UnsupportedSchema i64)
  (Malformed String))

(defstruct TlciHostCallbackTable
  (magic i64)
  (abi-version i64)
  (byte-size i64)
  (host-context i64)
  (reserved0 i64)
  (reserved1 i64)
  (reserved2 i64)
  (abort-callback i64)
  (import-names (__tl_dyn-array String))
  (import-callbacks (__tl_dyn-array i64))
  (import-count i64))

(defstruct TlciImageRegistration
  (magic i64)
  (abi-version i64)
  (byte-size i64)
  (image-context i64)
  (reserved0 i64)
  (reserved1 i64)
  (macro-entry-table i64)
  (macro-entry-count i64))

(defenum ResultTlciHostAbi
  (Ok)
  (Err String))

(define tlci-format-version : i64
  2)
(define tlci-metadata-version : String
  "v1")
(define tlci-metadata-version-v2 : String
  "v2")

(define (tlci-metadata-version-v2-current) : String
  (string.copy (& tlci-metadata-version-v2)))

(define tlci-host-platform-x86-64-legacy : i64
  1)
(define tlci-host-platform-x86-64-linux : i64
  2)
(define tlci-host-platform-x86-64-windows : i64
  3)

(define (tlci-build-host-platform) : i64
  (cfg
    windows
    tlci-host-platform-x86-64-windows
    tlci-host-platform-x86-64-linux))

(define (tlci-host-platform-supported? [platform : i64]) : bool
  (or
    (= platform tlci-host-platform-x86-64-legacy)
    (= platform tlci-host-platform-x86-64-linux)
    (= platform tlci-host-platform-x86-64-windows)))

(define (tlci-host-platform-name [platform : i64]) : String
  (cond
    [(= platform tlci-host-platform-x86-64-legacy) "x86_64-legacy-ambiguous"]
    [(= platform tlci-host-platform-x86-64-linux) "x86_64-linux"]
    [(= platform tlci-host-platform-x86-64-windows) "x86_64-windows"]
    [else "unknown"]))

(define (tlci-image-classify [image : (& image TlciImage)]) : TlciImageClassification
  (if (= (array-length image.code) 0)
    MetadataOnly
    CodeBearing))

;; Platform is an execution-time trust boundary only for native code. Parsed
;; metadata remains portable, including metadata from another host platform.
;; Unknown constructed values fail closed; parsed images already reject them.
(define (tlci-image-admit-host [image : TlciImage] [host-platform : i64]) : TlciImageHostAdmission
  (cond
    [(not (tlci-host-platform-supported? image.host-platform))
      (Rejected
        (str_cat.str-cat
          "tlci: package `"
          image.metadata.package-name
          "` image uses unsupported host platform "
          (string.int->string image.host-platform)))]
    [(not (tlci-host-platform-supported? host-platform))
      (Rejected "tlci: loader host platform is unsupported")]
    [else
      (match (tlci-image-classify image)
        [(MetadataOnly) MetadataOnly]
        [(CodeBearing)
          (cond
            [(= image.host-platform tlci-host-platform-x86-64-legacy)
              (Rejected
                (str_cat.str-cat
                  "tlci: package `"
                  image.metadata.package-name
                  "` code-bearing image uses legacy/ambiguous host platform"))]
            [(not (= image.host-platform host-platform))
              (Rejected
                (str_cat.str-cat
                  "tlci: package `"
                  image.metadata.package-name
                  "` code-bearing image host platform mismatch: image="
                  (tlci-host-platform-name image.host-platform)
                  ", host="
                  (tlci-host-platform-name host-platform)))]
            [else CodeBearing])])]))

(define tlci-callback-abi-version : i64
  2)
(define tlci-host-abi-version : i64
  2)
(define tlci-image-entry-symbol : String
  "tlci_image_entry")

(define (tlci-image-entry-symbol-shared-view) : String
  (tlci-host-callback-name-shared-view tlci-image-entry-symbol))

(define tlci-image-entry-param-count : i64
  2)
(define tlci-image-entry-success : i64
  0)
(define tlci-host-callback-table-magic : i64
  6076287494138317908)
(define tlci-image-registration-magic : i64
  5134470027336174676)
(define tlci-host-callback-table-header-size : i64
  48)
(define tlci-host-callback-table-size : i64
  64)
(define tlci-image-registration-header-size : i64
  48)
(define tlci-image-registration-size : i64
  64)
(define tlci-host-callback-table-magic-offset : i64
  0)
(define tlci-host-callback-table-abi-version-offset : i64
  8)
(define tlci-host-callback-table-byte-size-offset : i64
  16)
(define tlci-host-callback-table-host-context-offset : i64
  24)
(define tlci-host-callback-table-reserved0-offset : i64
  32)
(define tlci-host-callback-table-reserved1-offset : i64
  40)
(define tlci-host-callback-table-reserved2-offset : i64
  48)
(define tlci-host-callback-table-abort-offset : i64
  56)
(define tlci-image-registration-magic-offset : i64
  0)
(define tlci-image-registration-abi-version-offset : i64
  8)
(define tlci-image-registration-byte-size-offset : i64
  16)
(define tlci-image-registration-image-context-offset : i64
  24)
(define tlci-image-registration-reserved0-offset : i64
  32)
(define tlci-image-registration-reserved1-offset : i64
  40)
(define tlci-image-registration-macro-entry-table-offset : i64
  48)
(define tlci-image-registration-macro-entry-count-offset : i64
  56)
(define tlci-macro-entry-record-size : i64
  32)
(define tlci-macro-entry-name-ptr-offset : i64
  0)
(define tlci-macro-entry-name-len-offset : i64
  8)
(define tlci-macro-entry-function-offset : i64
  16)
(define tlci-macro-entry-reserved0-offset : i64
  24)

;; The most distinct op names one `run-ops` batch may bind. Refs #8274.
(define tlci-run-ops-names-cap : i64
  64)
(define tlci-host-callback-status-ok : i64
  0)
(define tlci-host-callback-status-diagnostic : i64
  1)
(define tlci-host-callback-status-fuel-exhausted : i64
  2)
(define tlci-host-callback-status-abort : i64
  3)
(define tlci-host-callback-status-bad-request : i64
  4)

;; Host callback ABI table: one row per named callback a native image may
;; import, naming the compiler host's implementation
;; `compiler-comptime-host-callback-<name>` of the ABI callback `<name>`.
;; `(tlci-host-callback-table collector contexts...)` expands to
;; `(collector contexts... rows...)`, so this table is the one source of
;; callback identity: `tlci-host-callback-name` checks each ABI name the
;; native producer emits against it, the producer declares one
;; `_tl_comptime_host_<name>` extern per row, and the compiler host registers
;; every row's implementation. (Spelling the implementations here also keeps
;; them in `typelisp test` harnesses, whose source-reachability pruning cannot
;; see names that macros assemble.) Every row shares one native signature, the
;; session cookie plus three i64 arguments; the abort callback has its own
;; fixed table slot and is not a row. Row order is not ABI: images bind
;; imports by name.
(defmacro (tlci-host-callback-table [collector : Expr] [contexts : Expr ...]) : Expr
  `(,collector
    ,@contexts
    compiler-comptime-host-callback-fuel-check
    compiler-comptime-host-callback-diagnostic
    compiler-comptime-host-callback-scratch-alloc
    compiler-comptime-host-callback-scratch-reset
    compiler-comptime-host-callback-expr-string
    compiler-comptime-host-callback-expr-var
    compiler-comptime-host-callback-expr-struct-get
    compiler-comptime-host-callback-expr-tuple-ref
    compiler-comptime-host-callback-expr-struct-set
    compiler-comptime-host-callback-string-eq
    compiler-comptime-host-callback-string-append
    compiler-comptime-host-callback-int->string
    compiler-comptime-host-callback-expr-splice
    compiler-comptime-host-callback-expr-if
    compiler-comptime-host-callback-pattern-wildcard
    compiler-comptime-host-callback-pattern-binding
    compiler-comptime-host-callback-pattern-variant
    compiler-comptime-host-callback-pattern-list-empty
    compiler-comptime-host-callback-pattern-list-cons
    compiler-comptime-host-callback-pattern-list-cons-from-values
    compiler-comptime-host-callback-match-arm
    compiler-comptime-host-callback-match-arm-list-empty
    compiler-comptime-host-callback-match-arm-list-cons
    compiler-comptime-host-callback-expr-match
    compiler-comptime-host-callback-expr-type
    compiler-comptime-host-callback-type-expr
    compiler-comptime-host-callback-module-name
    compiler-comptime-host-callback-module-hook
    compiler-comptime-host-callback-type-kind
    compiler-comptime-host-callback-type-key
    compiler-comptime-host-callback-struct-field-count
    compiler-comptime-host-callback-struct-field-name
    compiler-comptime-host-callback-struct-field-type
    compiler-comptime-host-callback-enum-variant-count
    compiler-comptime-host-callback-enum-variant-name
    compiler-comptime-host-callback-enum-variant-payload-count
    compiler-comptime-host-callback-enum-variant-payload-type
    compiler-comptime-host-callback-array-element-type
    compiler-comptime-host-callback-box-element-type
    compiler-comptime-host-callback-array-length
    compiler-comptime-host-callback-array-dynamic?
    compiler-comptime-host-callback-tuple-element-count
    compiler-comptime-host-callback-tuple-element-type
    compiler-comptime-host-callback-function-param-count
    compiler-comptime-host-callback-function-return-type
    compiler-comptime-host-callback-expr-list-length
    compiler-comptime-host-callback-expr-list-nth
    compiler-comptime-host-callback-expr-list-type-nth
    compiler-comptime-host-callback-expr-binding-clause-name
    compiler-comptime-host-callback-expr-binding-clause-has-type?
    compiler-comptime-host-callback-expr-binding-clause-type
    compiler-comptime-host-callback-expr-binding-clause-init
    compiler-comptime-host-callback-expr-binding-clause-init-callee
    compiler-comptime-host-callback-expr-binding-clause-list-length
    compiler-comptime-host-callback-expr-binding-clause-list-nth
    compiler-comptime-host-callback-pattern-list-bindings
    compiler-comptime-host-callback-type-cleanup-owning?
    compiler-comptime-host-callback-type-cleanup-function
    compiler-comptime-host-callback-module-value?
    compiler-comptime-host-callback-module-value-type
    compiler-comptime-host-callback-module-value-expr
    compiler-comptime-host-callback-function-shared-borrow-returns-string?
    compiler-comptime-host-callback-reference-element-type
    ;; Construction ops for natively compiled quasiquote bodies. Values under
    ;; construction live entirely on a compiler-owned session value stack, so
    ;; the image never holds result handles: list-empty pushes a fresh empty
    ;; expression list, list-append pops an element then a list and pushes the
    ;; appended list, push-operand pushes the macro operand named by immediate
    ;; `a`, expr-call pops an argument list then a callee and pushes the call
    ;; expression. commit-result pops the stack top into the session result. The
    ;; embedded image and its consumer are always the same source-bound binary.
    ;; Refs #5212.
    compiler-comptime-host-callback-expr-list-empty
    compiler-comptime-host-callback-expr-list-cons
    compiler-comptime-host-callback-expr-list-append
    compiler-comptime-host-callback-push-operand
    compiler-comptime-host-callback-expr-call
    compiler-comptime-host-callback-expr-shared-call1
    compiler-comptime-host-callback-commit-result
    ;; Template source spans. The parser wraps every expression it reads in an
    ;; `AstExpr.Spanned`, and the interpreted quasiquote reconstructs that
    ;; wrapper around every template node it rebuilds, so a natively produced
    ;; expansion only matches the interpreted one when it rebuilds the wrappers
    ;; too. Both ops re-wrap the stack top and take the span in their
    ;; immediates: `a` is the start line, `b` the start column, `c` the end line
    ;; and column packed `(line << 32) | column`. expr-span is the
    ;; template-origin form and always wraps. expr-span-unquoted covers a
    ;; template position that was an unquote: the substituted value is already
    ;; spanned at its own call site, so the template span applies only when it
    ;; is not, matching the interpreted quote's unquoted-origin rule. Neither op
    ;; disturbs a stack top that carries no expression node (a type or a
    ;; comptime scalar), which the interpreted route never spans either. Refs
    ;; #5212.
    compiler-comptime-host-callback-expr-span
    compiler-comptime-host-callback-expr-span-unquoted
    ;; Intrinsic node construction: pop two operand expressions and push the
    ;; dedicated node the parser produces (rather than a generic call). Refs
    ;; #5213.
    compiler-comptime-host-callback-expr-array-ref
    compiler-comptime-host-callback-expr-array-take
    compiler-comptime-host-callback-expr-array-push
    compiler-comptime-host-callback-expr-replace
    ;; Pop a size expression and a type value and push the make-array node the
    ;; parser produces for `(__tl_make-array ,T ,count)`. Refs #5213.
    compiler-comptime-host-callback-expr-make-array
    ;; Comptime reflection and literal construction for computed transformer
    ;; bodies (refs #5213 N2/N3). operand-type-kind-eq compares the type-kind
    ;; string of a type operand against caller bytes and returns 1/0 as data (a
    ;; negative value reports a bad request); the literal ops push literal
    ;; expression nodes.
    compiler-comptime-host-callback-operand-type-kind-eq
    compiler-comptime-host-callback-expr-bool-literal
    compiler-comptime-host-callback-expr-int-literal
    compiler-comptime-host-callback-expr-list-fold-if
    compiler-comptime-host-callback-expr-clause-list-fold-if
    compiler-comptime-host-callback-pattern-binding-typed
    compiler-comptime-host-callback-expr-resource-scope
    compiler-comptime-host-callback-expr-let-scope
    compiler-comptime-host-callback-expr-shared-let-scope
    compiler-comptime-host-callback-expr-for-owned
    compiler-comptime-host-callback-expr-set-var
    compiler-comptime-host-callback-expr-begin-unit
    compiler-comptime-host-callback-expr-not
    compiler-comptime-host-callback-expr-while
    compiler-comptime-host-callback-syntax-name-fresh
    ;; General quasiquote template construction (refs #5596): expr-begin pops an
    ;; expression list and pushes the begin node the parser produces;
    ;; expr-binary-op pops the right then the left operand expression and pushes
    ;; a binary node for the AstBinOp ordinal in immediate `a`; expr-unary-op
    ;; pops the operand expression and pushes a unary node for the AstUnOp
    ;; ordinal in immediate `a`; expr-char-literal pushes a char literal node
    ;; for the code point in immediate `a`; expr-unit-literal pushes the unit
    ;; literal node. The embedded image and its consumer are always the same
    ;; source-bound binary.
    compiler-comptime-host-callback-expr-begin
    compiler-comptime-host-callback-expr-binary-op
    compiler-comptime-host-callback-expr-unary-op
    compiler-comptime-host-callback-expr-char-literal
    compiler-comptime-host-callback-expr-unit-literal
    ;; Computed-body locals and declaration-template construction (refs #5603).
    ;; local-set pops one value into the session local slot named by immediate
    ;; `a`; local-get pushes the slot's value. expr-var-from-value pops a
    ;; comptime String or Name value and pushes the variable node the
    ;; interpreted `(comptime.)expr-var` builtin produces (syntax-name
    ;; resolution over the source-name session included). expr-bracket-clause
    ;; pops an expression list and pushes the bracket-clause node the parser
    ;; produces for `[item ...]` in templates. expr-borrow pops the place
    ;; expression and pushes a borrow node: immediate `a` is 1 for `&mut` and 0
    ;; for `&`; the lifetime is inferred. The embedded image and its consumer
    ;; are always the same source-bound binary.
    compiler-comptime-host-callback-local-set
    compiler-comptime-host-callback-local-get
    compiler-comptime-host-callback-expr-var-from-value
    compiler-comptime-host-callback-expr-bracket-clause
    compiler-comptime-host-callback-expr-borrow
    ;; Computed-body support (refs #5603): string-value pushes the comptime
    ;; String value for caller bytes (a parsed-source string identity like the
    ;; lexer's); diagnostic-from-value pops a comptime String into the session
    ;; diagnostic and answers with the diagnostic status; pattern-var pushes a
    ;; unit/variable pattern for caller bytes with the template-source mark.
    compiler-comptime-host-callback-string-value
    compiler-comptime-host-callback-diagnostic-from-value
    compiler-comptime-host-callback-pattern-var
    ;; More template construction (refs #5603): expr-array-set pops the value,
    ;; index, and target expressions and pushes the array-set! node; let-binding
    ;; pops the init expression and pushes a named let binding (template-source
    ;; marked like the interpreted quote); let-binding-list-empty/cons build the
    ;; binding list; expr-let pops the body and the binding list and pushes the
    ;; let node.
    compiler-comptime-host-callback-expr-array-set
    compiler-comptime-host-callback-let-binding
    compiler-comptime-host-callback-let-binding-list-empty
    compiler-comptime-host-callback-let-binding-list-cons
    compiler-comptime-host-callback-expr-let
    ;; expr-lambda reconstructs a quasiquoted lambda from its parameter types,
    ;; optional return type, and body. The parameter names/flags are carried in
    ;; a compact immediate payload so the value stack remains syntax-only.
    compiler-comptime-host-callback-expr-lambda
    ;; Public computed one-parameter lambda builder. Unlike the template
    ;; callback, its hygienic name, reflected parameter type, and assembled body
    ;; are all supplied on the host value stack.
    compiler-comptime-host-callback-expr-lambda1
    ;; Typed template bindings (refs #5603): type-var pushes the AstType.Var for
    ;; caller bytes (unmarked, matching the interpreted type quote);
    ;; let-binding- typed pops the type value then the init expression and
    ;; pushes a binding carrying both.
    compiler-comptime-host-callback-type-var
    compiler-comptime-host-callback-let-binding-typed
    ;; type-scalar pushes the scalar AstType variant named by immediate ordinal
    ;; (the primitive type constructors; refs #5603).
    compiler-comptime-host-callback-type-scalar
    ;; expr-int-from-data pushes an int literal expression whose value is the
    ;; data i64 in immediate `a` (used when a computed reflection yields a
    ;; runtime count, refs #5603).
    compiler-comptime-host-callback-expr-int-from-data
    ;; Expression-value destructuring for computed bodies that match on the
    ;; shape of an operand (refs #5602). operand-expr-call? answers 1/0 as data
    ;; for "operand `a` is a call expression" (a negative value is its
    ;; malformed-request sentinel, like the other data-returning probes); the
    ;; two accessors push the callee expression and the argument list the
    ;; interpreted `(comptime.Expr.Call callee args)` pattern binds. All three
    ;; unwrap `Spanned` and diagnostic-only macro expansion markers first,
    ;; matching `ctfe-match-expr-variant`.
    compiler-comptime-host-callback-operand-expr-call?
    compiler-comptime-host-callback-operand-expr-call-callee
    compiler-comptime-host-callback-operand-expr-call-args
    ;; The `comptime.Expr.Int` half of the same destructuring (refs #5602).
    ;; operand-expr-int? answers 1/0 as data with a negative malformed-request
    ;; sentinel; operand-expr-int-value answers the literal's i64 value as data
    ;; and is only issued after the probe, so it has no error channel of its
    ;; own. Both unwrap `Spanned` and diagnostic-only macro expansion markers
    ;; first. local-expr-list-length and local-expr-list-nth are the local-slot
    ;; twins of the operand-only expr-list callbacks: a destructured `ExprList`
    ;; payload lives in a session local, and the fold bodies index it there.
    compiler-comptime-host-callback-operand-expr-int?
    compiler-comptime-host-callback-operand-expr-int-value
    compiler-comptime-host-callback-local-expr-int?
    compiler-comptime-host-callback-local-expr-int-value
    compiler-comptime-host-callback-local-expr-list-length
    compiler-comptime-host-callback-local-expr-list-nth
    compiler-comptime-host-callback-local-expr-string?
    compiler-comptime-host-callback-local-expr-var?
    compiler-comptime-host-callback-local-expr-var-name
    compiler-comptime-host-callback-local-expr-begin?
    compiler-comptime-host-callback-local-expr-begin-items
    compiler-comptime-host-callback-local-bool-value
    compiler-comptime-host-callback-value-bool
    ;; Remaining binder-free template node kinds (refs #5605, #6240):
    ;; expr-return, expr-box, expr-box-get, and expr-box-take each pop one
    ;; expression and push the corresponding AST node; expr-float-literal pushes
    ;; a float literal carrying the caller bytes, which are the literal's exact
    ;; source text (the interpreted quote preserves float spelling verbatim).
    ;; The embedded image and its consumer are always the same source-bound
    ;; binary.
    compiler-comptime-host-callback-expr-return
    compiler-comptime-host-callback-expr-box
    compiler-comptime-host-callback-expr-box-get
    compiler-comptime-host-callback-expr-box-take
    compiler-comptime-host-callback-expr-float-literal
    ;; Computed-scrutinee probes and cast/init templates (refs #5604, #5606).
    ;; The two probes share operand-type-kind-eq's shape -- operand index in
    ;; `a`, caller bytes in `b`/`c`, 1/0 as data and a negative
    ;; malformed-request sentinel -- so they bypass the status latch the same
    ;; way: operand-expr-type-kind-eq compares the type-kind of an Expr
    ;; operand's produced type, and operand-type-key-eq compares a type
    ;; operand's canonical key. expr-cast pops the type value then the operand
    ;; expression and pushes the cast node the parser produces. expr-init pops
    ;; one type value and pushes the typed `(init : T)` node. The embedded image
    ;; and its consumer are always the same source-bound binary.
    compiler-comptime-host-callback-operand-expr-type-kind-eq
    compiler-comptime-host-callback-operand-type-key-eq
    compiler-comptime-host-callback-expr-cast
    compiler-comptime-host-callback-expr-ann
    compiler-comptime-host-callback-expr-init
    ;; Raw-pointer and `unsafe` template node kinds (refs #5605). expr-unsafe
    ;; pops an expression list and pushes the `(unsafe ...)` node;
    ;; expr-ptr-read, expr-ptr-addr-of, expr-ptr-to-int, and expr-string-data
    ;; each pop one expression; expr-ptr-write, expr-ptr-offset, and
    ;; expr-string-from-bytes pop the second then the first operand;
    ;; expr-array-data pops one. expr-ptr-cast pops the type value then the
    ;; pointer expression. These complete the template subset the
    ;; `stdlib.text_buf_family` generators need.
    compiler-comptime-host-callback-expr-unsafe
    compiler-comptime-host-callback-expr-ptr-read
    compiler-comptime-host-callback-expr-ptr-addr-of
    compiler-comptime-host-callback-expr-ptr-to-int
    compiler-comptime-host-callback-expr-int-to-ptr
    compiler-comptime-host-callback-expr-string-data
    compiler-comptime-host-callback-expr-ptr-write
    compiler-comptime-host-callback-expr-ptr-offset
    compiler-comptime-host-callback-expr-string-from-bytes
    compiler-comptime-host-callback-expr-array-data
    ;; expr-ptr-cast pops the type value then the pointer expression, the order
    ;; expr-make-array uses. Refs #5605.
    compiler-comptime-host-callback-expr-ptr-cast
    ;; The literal text of a string-literal `Expr`, pushed as the comptime
    ;; String value the interpreted `comptime.expr-string-value` yields -- the
    ;; same `(CompilerCtfeValue.String (intern-str id) id)` identity, so a
    ;; downstream `expr-var`/`string-append` sees exactly what interpretation
    ;; gave it. The operand form reads a macro operand directly; the generic
    ;; form pops a computed Expr from the session stack. A non-literal produces
    ;; the interpreted diagnostic rather than silently yielding empty text.
    compiler-comptime-host-callback-operand-expr-string-value
    compiler-comptime-host-callback-expr-string-value
    ;; `comptime.Expr.Var` destructuring: a data probe for "operand `a` is a
    ;; plain identifier expression", and an accessor pushing that identifier's
    ;; spelling as a comptime String so the body can build a derived name from
    ;; it. The serialize nested-alias shape needs exactly this pair. Both unwrap
    ;; `Spanned` and diagnostic-only macro expansion markers first, matching
    ;; `ctfe-match-expr-variant`. Refs #5700.
    compiler-comptime-host-callback-operand-expr-var?
    compiler-comptime-host-callback-operand-expr-var-name
    ;; value-i64 pushes a comptime i64 from immediate `a`, which is what
    ;; `comptime.int->string` consumes when its argument is a literal or a
    ;; compile-time data local rather than a stack value. Refs #5700.
    compiler-comptime-host-callback-value-i64
    ;; A computed value-position unit literal must still occupy a session stack
    ;; slot so conditional validation bindings can share the ordinary local-set
    ;; continuation with their diagnostic alternative. Refs #5606.
    compiler-comptime-host-callback-value-unit
    ;; Select one of two already-computed session values from an i64 condition
    ;; immediate. The producer only emits this for side-effect-free Var
    ;; branches.
    compiler-comptime-host-callback-value-select
    ;; Comptime string scanning over a String session local (refs #5701). The
    ;; scanner bodies bind a String once -- from `comptime.expr-string-value` or
    ;; `type-key` -- and then walk it, so all three read the local by slot
    ;; instead of routing every step through a stack push. local-string-length
    ;; answers the byte length as data and local-string-ref the byte at `b` as
    ;; data, both with a negative malformed-request sentinel; local-string-slice
    ;; pushes the `[b, b+c)` range as the generated comptime String
    ;; `comptime.string-slice` yields. expr-string-from-value pops a comptime
    ;; String and pushes the string-literal expression `comptime.expr-string`
    ;; builds, carrying the popped value's own intern id so a template embeds
    ;; exactly the text interpretation would. Their explicit names keep the
    ;; local-slot semantics distinct from the stack-shaped `string-length` /
    ;; `string-ref` callbacks.
    compiler-comptime-host-callback-local-string-length
    compiler-comptime-host-callback-local-string-ref
    compiler-comptime-host-callback-local-string-slice
    compiler-comptime-host-callback-expr-string-from-value
    ;; operand-expr-string? answers 1/0 as data for "operand `a` is a string
    ;; literal expression", the `comptime.expr-string?` guard every
    ;; literal-template macro opens with, with the same negative
    ;; malformed-request sentinel as the other operand probes. Refs #5701.
    compiler-comptime-host-callback-operand-expr-string?
    ;; Composite type templates (refs #5605), for annotations such as
    ;; `(__tl_dyn-array String)`, `(Ptr u8)`, `(MutPtr i64)`, `(& text str)` and
    ;; `(&mut buf TextBuf)` in the `stdlib.text_buf_family` generators and
    ;; generated vector modules. Each callback pops the element/inner type value
    ;; and pushes the wrapper, so a nested annotation builds bottom-up like an
    ;; expression template does. type-ptr and type-ref select mutability with immediate
    ;; `a`; type-array takes its element count in `a`; type-ref takes the
    ;; lifetime name in `b`/`c`. type-var-args takes a lifetime count in `a` and
    ;; a count-validated newline-delimited nominal/lifetime payload in `b`/`c`,
    ;; preserving the unresolved VarArgs identity and argument order. Refs
    ;; #6551.
    compiler-comptime-host-callback-type-ptr
    compiler-comptime-host-callback-type-box
    compiler-comptime-host-callback-type-dyn-array
    compiler-comptime-host-callback-type-array
    compiler-comptime-host-callback-type-ref
    compiler-comptime-host-callback-type-slice
    compiler-comptime-host-callback-type-tuple
    compiler-comptime-host-callback-type-var-args
    ;; A computed struct field name is a stack value rather than caller bytes:
    ;; pop the name after the target expression and push the resulting field
    ;; projection. Refs #5626.
    compiler-comptime-host-callback-expr-struct-get-from-value
    ;; A computed struct assignment has its field name on the value stack too:
    ;; pop target, Name/String field, and value expressions, then push the
    ;; resulting assignment. Refs #5999.
    compiler-comptime-host-callback-expr-struct-set-from-value
    ;; A quasiquoted `(set! ,place value)` only knows its assignment shape after
    ;; the unquoted place has produced an Expr session value. Pop that place and
    ;; the value expression, then reconstruct the matching variable,
    ;; struct-field, or box assignment. Refs #6550.
    compiler-comptime-host-callback-expr-set-from-place
    ;; Computed enum variant names likewise retain their source-name identity as
    ;; a session value. Pop a PatternList after the name and push the resulting
    ;; variant pattern. Refs #5626.
    compiler-comptime-host-callback-pattern-variant-from-value
    ;; The computed public cons builder evaluates its head before its tail;
    ;; consume that stack order and prepend the head to the MatchArmList. Refs
    ;; #5626.
    compiler-comptime-host-callback-match-arm-list-cons-from-values
    ;; Tuple and array templates consume the ExprList assembled by the shared
    ;; template argument/splice path and push the corresponding expression
    ;; reconstructed by interpreted quasiquote. Refs #5724, #6215.
    compiler-comptime-host-callback-expr-tuple
    compiler-comptime-host-callback-expr-array
    ;; Loop control in templates, such as the `break` that ends a prelude
    ;; `any?` / `all?` scan: push the node the parser produces.
    compiler-comptime-host-callback-expr-break
    compiler-comptime-host-callback-expr-continue
    ;; run-ops replays a batch of status ops encoded as data: `a` points at the
    ;; batch and `b` is its byte length. The batch names each op it uses, so
    ;; it binds callbacks by name like an image import, and it calls each op
    ;; with the immediates a native call would pass, stopping at the first
    ;; non-ok status. `run-ops` itself is not a batchable op. The producer
    ;; emits it for runs of ops whose immediates are all constants, which is
    ;; what keeps template construction out of machine code. Refs #8274.
    compiler-comptime-host-callback-run-ops))

;; `(tlci-host-callback-row-index-rows name rows...)` is the row index of the
;; ABI name `name` among `rows`, or -1: one comparison per row.
(defmacro (tlci-host-callback-row-index-rows [name : Expr] [rows : Expr ...]) : i64
  (let
    [prefix-length : i64
      (string.string-length "compiler-comptime-host-callback-")]
    [row : i64 (expr-list-length rows)]
    [lookup : Expr `-1]
    (while (> row 0)
      (set! row (- row 1))
      (match (expr-list-nth rows row)
        [(comptime.Expr.Var text)
          (set!
            lookup
            `(if (string.eq
              ,name
              ,(comptime.expr-string
                (comptime.string-slice
                  text
                  prefix-length
                  (- (string.string-length text) prefix-length))))
              ,(comptime.expr-int row)
              ,lookup))]
        [_
          (comptime-error
            "tlci-host-callback-row-index-rows: rows must be bare names")]))
    lookup))

;; The row index of ABI name `name` in `tlci-host-callback-table`, or -1. The
;; producer stamps it into `run-ops` batches as a hint that the host confirms
;; against its own row names before trusting it. Refs #8274.
(define (tlci-host-callback-row-index [name : (& name str)]) : i64
  (tlci-host-callback-table tlci-host-callback-row-index-rows name))

;; The ABI name String of one host callback table row. A name outside the
;; table fails to compile. (The definition-time macro checker runs the lookup
;; with no rows; that admits every name.)
(defmacro (tlci-host-callback-name [name : Expr]) : String
  `(tlci-host-callback-table tlci-host-callback-name-lookup ,name))

(defmacro (tlci-host-callback-name-lookup [name : Expr] [rows : Expr ...]) : String
  (match name
    [(comptime.Expr.Var text)
      (let
        [row-name : String
          (comptime.string-append "compiler-comptime-host-callback-" text)]
        [count : i64 (expr-list-length rows)]
        [index : i64 0]
        [found : bool (= count 0)]
        (while (< index count)
          (match (expr-list-nth rows index)
            [(comptime.Expr.Var row)
              (if (string.eq row row-name)
                (begin
                  (set! found true)
                  (set! index count))
                unit)]
            [_ unit])
          (set! index (+ index 1)))
        (if found
          (comptime.expr-string text)
          (comptime-error
            (comptime.string-append "tlci: unknown host callback " text))))]
    [_ (comptime-error "tlci-host-callback-name: expected a bare name")]))

(define tlci-header-size : i64
  176)
(define tlci-page-align : i64
  4096)
(define tlci-format-version-field-offset : i64
  8)
(define tlci-hash-field-offset : i64
  48)
(define tlci-hash-field-size : i64
  8)
(define tlci-import-section-field-offset : i64
  152)
(define tlci-import-count-field-offset : i64
  160)
(define tlci-file-size-field-offset : i64
  168)
(define tlci-section-fixup-record-size : i64
  8)
(define tlci-section-entry-record-size : i64
  24)
(define tlci-section-symbol-record-size : i64
  40)

;; A non-empty import section starts with its record count, followed by fixed
;; records and a packed UTF-8 name blob. Each record is:
;;   (got-slot-offset u64, name-offset u64, name-length u64)
;; Name offsets are relative to the start of the import section.
(define tlci-section-import-header-size : i64
  8)
(define tlci-section-import-record-size : i64
  24)

;; Little-endian ASCII `TLCIAUX1`. The trailer is:
;;   magic, version, base-rodata-len, directory-offset, count, rodata-len.
;; Directory records are:
;;   kind, schema-version, payload-offset, payload-len, payload-hash.
(define tlci-aux-magic : i64
  0x3158554149434c54)
(define tlci-aux-format-version : i64
  1)
(define tlci-aux-record-size : i64
  40)
(define tlci-aux-trailer-size : i64
  48)

;; Stable section identities. They describe package surfaces, not the embedded
;; stdlib deployment that first consumes them (refs #5519, #5522).
(define tlci-aux-kind-package-identity : i64
  1)
(define tlci-aux-kind-frontend-ast : i64
  2)
(define tlci-aux-kind-frontend-facts : i64
  4)
(define tlci-aux-kind-package-source-binding : i64
  8)
(define tlci-package-source-binding-schema-version : i64
  1)

(define (tlci-host-abi-version-error [actual : i64]) : String
  (str_cat.str-cat
    "tlci host ABI: unsupported callback ABI version "
    (string.int->string actual)))

(define (tlci-host-callback-registry-error
  [table : (& table TlciHostCallbackTable)]) : String
  (let
    [count : i64 table.import-count]
    [index : i64 0]
    [prior : i64 0]
    [error : String ""]
    (cond
      [(< count 0) "host callback registry count must not be negative"]
      [(< (array-length table.import-names) count)
        "host callback registry name storage is smaller than its count"]
      [(< (array-length table.import-callbacks) count)
        "host callback registry address storage is smaller than its count"]
      [else
        (while (and (= (string.string-length error) 0) (< index count))
          (cond
            [(string.eq (array-ref table.import-names index) "")
              (set! error "host callback registry name must not be empty")]
            [(= (array-ref table.import-callbacks index) 0)
              (set! error "host callback registry address must be nonzero")]
            [else
              (set! prior 0)
              (while (and (= (string.string-length error) 0) (< prior index))
                (if (string.eq
                  (array-ref table.import-names prior)
                  (array-ref table.import-names index))
                  (set! error "duplicate host callback registry name")
                  (set! prior (+ prior 1))))
              (set! index (+ index 1))]))
        error])))

(define (tlci-validate-host-callback-table [table : TlciHostCallbackTable]) : ResultTlciHostAbi
  (cond
    [(not (= table.magic tlci-host-callback-table-magic))
      (Err "tlci host ABI: bad host callback table magic")]
    [(not (= table.abi-version tlci-host-abi-version))
      (Err (tlci-host-abi-version-error table.abi-version))]
    [(< table.byte-size tlci-host-callback-table-size)
      (Err "tlci host ABI: host callback table byte-size is smaller than v2")]
    [(not (= table.reserved0 0))
      (Err "tlci host ABI: host callback table reserved0 must be zero")]
    [(not (= table.reserved1 0))
      (Err "tlci host ABI: host callback table reserved1 must be zero")]
    [(not (= table.reserved2 0))
      (Err "tlci host ABI: host callback table reserved2 must be zero")]
    [(= table.abort-callback 0)
      (Err "tlci host ABI: host abort callback must be nonzero")]
    [(not (string.eq (tlci-host-callback-registry-error (& table)) ""))
      (Err
        (str_cat.str-cat
          "tlci host ABI: "
          (tlci-host-callback-registry-error (& table))))]
    [else (Ok)]))

(define (tlci-validate-image-registration
  [registration : TlciImageRegistration]) : ResultTlciHostAbi
  (cond
    [(not (= registration.magic tlci-image-registration-magic))
      (Err "tlci host ABI: bad image registration magic")]
    [(not (= registration.abi-version tlci-host-abi-version))
      (Err (tlci-host-abi-version-error registration.abi-version))]
    [(< registration.byte-size tlci-image-registration-size)
      (Err "tlci host ABI: image registration byte-size is smaller than v2")]
    [(not (= registration.reserved0 0))
      (Err "tlci host ABI: image registration reserved0 must be zero")]
    [(not (= registration.reserved1 0))
      (Err "tlci host ABI: image registration reserved1 must be zero")]
    [(and
        (= registration.macro-entry-table 0)
        (not (= registration.macro-entry-count 0)))
      (Err "tlci host ABI: macro entry count requires a table")]
    [(and
        (not (= registration.macro-entry-table 0))
        (= registration.macro-entry-count 0))
      (Err "tlci host ABI: macro entry table requires a count")]
    [else (Ok)]))

(define (tlci-empty-bytes) : (__tl_dyn-array u8)
  (__tl_make-array u8 0))

(define (tlci-byte [value : i64]) : u8
  (cast (bit-and value 0xff) : u8))

(define (tlci-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (tlci-byte value)))

;; Container integers are little-endian u64 fields (stdlib.byte_le).
(define (tlci-push-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_le.push-u64! out value))

(define (tlci-set-u64!
  [out : (&mut out (__tl_dyn-array u8))]
  [offset : i64]
  [value : i64]) : unit
  (byte_le.set-u64! out offset value))

(define (tlci-put-string!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [offset : i64]
  [text : (& text str)]) : unit
  (let
    [index : i64 0]
    [count : i64 (tlci-string-length text)]
    (while (< index count)
      (set!
        (array-ref bytes (+ offset index))
        (cast (tlci-string-ref text index) : u8))
      (set! index (+ index 1)))
    unit))

(define tlci-macro-table-symbol : String
  "tlci_macro_table")

(define (tlci-macro-table-symbol-shared-view) : String
  (tlci-host-callback-name-shared-view tlci-macro-table-symbol))

(defstruct TlciNativePackageInput
  (rodata (__tl_dyn-array u8))
  (code (__tl_dyn-array u8))
  (imports (__tl_dyn-array u8))
  (layout-fixup-offsets (__tl_dyn-array i64))
  (layout-fixup-count i64)
  (identities (__tl_dyn-array String))
  (entry-offsets (__tl_dyn-array i64))
  (macro-count i64))

(define (tlci-native-package-name-blob-len
  [identities : (& identities (__tl_dyn-array String))]
  [count : i64]) : i64
  (let
    [index : i64 0]
    [total : i64 0]
    (while (< index count)
      (set! total (+ total (tlci-string-length (array-ref identities index))))
      (set! index (+ index 1)))
    total))

;; Extend the layout code bytes with the name blob, the aligned count word,
;; and the zeroed macro table. Returns the extended code array.
(define (tlci-native-package-extend-code
  [input : (& input TlciNativePackageInput)]) : (__tl_dyn-array u8)
  (let
    [code : (& input (__tl_dyn-array u8)) (& input.code)]
    [code-len : i64 (array-length code)]
    [count : i64 input.macro-count]
    [names-len : i64 (tlci-native-package-name-blob-len input.identities count)]
    [count-word : i64 (tlci-align-offset (+ code-len names-len) 8)]
    [table-offset : i64 (+ count-word 8)]
    [total : i64 (+ table-offset (* count tlci-macro-entry-record-size))]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 total)]
    [index : i64 0]
    [name-cursor : i64 code-len]
    (while (< index code-len)
      (set! (array-ref out index) (array-ref code index))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index count)
      (let
        [name : (& input str) (& (array-ref input.identities index))]
        [name-len : i64 (tlci-string-length name)]
        (tlci-put-string! (&mut out) name-cursor name)
        (set! name-cursor (+ name-cursor name-len))
        (set! index (+ index 1))))
    (tlci-set-u64! (&mut out) count-word count)
    out))

;; Intra-code offset of the count word for the extended code array.
(define (tlci-native-package-count-word
  [input : (& input TlciNativePackageInput)]) : i64
  (tlci-align-offset
    (+
      (array-length input.code)
      (tlci-native-package-name-blob-len input.identities input.macro-count))
    8))

(define (tlci-native-package-entries [input : (& input TlciNativePackageInput)]) : (__tl_dyn-array
    u8)
  (let
    [out : (__tl_dyn-array u8)
      (__tl_make-array u8 tlci-section-entry-record-size)]
    [symbol : String (string.copy (& tlci-macro-table-symbol))]
    (tlci-set-u64! (&mut out) 0 0)
    (tlci-set-u64! (&mut out) 8 (tlci-string-length symbol))
    (tlci-set-u64! (&mut out) 16 (tlci-native-package-count-word input))
    out))

(define (tlci-native-package-symbols) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8)
      (__tl_make-array u8 tlci-section-symbol-record-size)]
    (let
      [symbol : String (string.copy (& tlci-macro-table-symbol))]
      (tlci-put-string! (&mut out) 0 symbol))
    out))

(define (tlci-native-package-fixups [input : (& input TlciNativePackageInput)]) : (__tl_dyn-array
    u8)
  (__tl_make-array
    u8
    (*
      (+ input.layout-fixup-count (* input.macro-count 2))
      tlci-section-fixup-record-size)))

;; Post-emit patch: resolve layout fixup slots and fill the macro table's name
;; and function slots plus their fixup records, then restamp the content hash.
(define (tlci-native-package-patch!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [input : (& input TlciNativePackageInput)]) : unit
  (let
    [code-offset : i64 (tlci-read-u64 bytes 88)]
    [fixups-offset : i64 (tlci-read-u64 bytes 104)]
    [count : i64 input.macro-count]
    [layout-count : i64 input.layout-fixup-count]
    [count-word : i64 (tlci-native-package-count-word input)]
    [table-offset : i64 (+ count-word 8)]
    [name-cursor : i64 (array-length input.code)]
    [index : i64 0]
    (while (< index layout-count)
      (let
        [slot : i64
          (+ code-offset (array-ref input.layout-fixup-offsets index))]
        (tlci-set-u64!
          bytes
          (+ fixups-offset (* index tlci-section-fixup-record-size))
          slot)
        (tlci-set-u64! bytes slot (+ code-offset (tlci-read-u64 bytes slot)))
        (set! index (+ index 1))))
    (set! index 0)
    (while (< index count)
      (let
        [name-len : i64 (tlci-string-length (array-ref input.identities index))]
        [record-slot : i64
          (+
            code-offset
            (+ table-offset (* index tlci-macro-entry-record-size)))]
        [name-slot : i64 (+ record-slot tlci-macro-entry-name-ptr-offset)]
        [entry-slot : i64 (+ record-slot tlci-macro-entry-function-offset)]
        [fixup-slot : i64
          (+
            fixups-offset
            (* (+ layout-count (* index 2)) tlci-section-fixup-record-size))]
        (tlci-set-u64! bytes name-slot (+ code-offset name-cursor))
        (tlci-set-u64!
          bytes
          (+ record-slot tlci-macro-entry-name-len-offset)
          name-len)
        (tlci-set-u64!
          bytes
          entry-slot
          (+ code-offset (array-ref input.entry-offsets index)))
        (tlci-set-u64! bytes fixup-slot name-slot)
        (tlci-set-u64!
          bytes
          (+ fixup-slot tlci-section-fixup-record-size)
          entry-slot)
        (set! name-cursor (+ name-cursor name-len))
        (set! index (+ index 1))))
    (let
      [imports-offset : i64 (tlci-read-u64 bytes 152)]
      [imports-count : i64 (tlci-read-u64 bytes 160)]
      [import-index : i64 0]
      (while (< import-index imports-count)
        (let
          [slot : i64
            (+
              imports-offset
              (+
                tlci-section-import-header-size
                (* import-index tlci-section-import-record-size)))]
          (tlci-set-u64! bytes slot (+ code-offset (tlci-read-u64 bytes slot)))
          (set! import-index (+ import-index 1)))))
    (tlci-set-u64! bytes tlci-hash-field-offset (tlci-content-hash bytes))
    unit))

;; Assemble a native package image from normal-backend layout output.
(define (tlci-emit-native-package-image
  [metadata : TlciMetadata]
  [compiler-build-hash : String]
  [host-platform : i64]
  [input : TlciNativePackageInput]) : ResultTlciBytes
  (let
    [bytes
      (try
        (tlci-emit-image
          (tlci-make-image
            host-platform
            tlci-callback-abi-version
            compiler-build-hash
            metadata
            (clone input.rodata)
            (tlci-native-package-extend-code input)
            (tlci-native-package-fixups input)
            (tlci-native-package-entries input)
            (tlci-native-package-symbols)
            (clone input.imports))))]
    (tlci-native-package-patch! (&mut bytes) input)
    (Ok bytes)))

(define (tlci-byte-at [bytes : (& bytes (__tl_dyn-array u8))] [offset : i64]) : i64
  (cast (array-ref bytes offset) : i64))

(define (tlci-read-u64 [bytes : (& bytes (__tl_dyn-array u8))] [offset : i64]) : i64
  (byte_le.read-u64 bytes offset))

(define (tlci-push-zeroes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (tlci-push-u8! out 0)
      (set! i (+ i 1)))
    unit))

(define (tlci-align-offset [offset : i64] [align : i64]) : i64
  (if (<= align 1)
    offset
    (let
      [rem : i64 (% offset align)]
      (if (= rem 0)
        offset
        (+ offset (- align rem))))))

(define (tlci-pad-to!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [offset : i64]) : unit
  (tlci-push-zeroes! out (- offset out.len)))

(define (tlci-push-magic! [out : (&mut out byte_buf_core.ByteBufBuilder)]) : unit
  (tlci-push-u8! out 84)
  (tlci-push-u8! out 76)
  (tlci-push-u8! out 67)
  (tlci-push-u8! out 73)
  (tlci-push-u8! out 13)
  (tlci-push-u8! out 10)
  (tlci-push-u8! out 26)
  (tlci-push-u8! out 10))

(define (tlci-magic-ok? [bytes : (& bytes (__tl_dyn-array u8))]) : bool
  (and
    (= (tlci-byte-at bytes 0) 84)
    (= (tlci-byte-at bytes 1) 76)
    (= (tlci-byte-at bytes 2) 67)
    (= (tlci-byte-at bytes 3) 73)
    (= (tlci-byte-at bytes 4) 13)
    (= (tlci-byte-at bytes 5) 10)
    (= (tlci-byte-at bytes 6) 26)
    (= (tlci-byte-at bytes 7) 10)))

(define (tlci-push-string-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : (& text str)]) : unit
  (let
    [i : i64 0]
    [n : i64 (tlci-string-length text)]
    (while (< i n)
      (byte_buf_core.byte-buf-builder-push
        out
        (cast (tlci-string-ref text i) : u8))
      (set! i (+ i 1)))
    unit))

(define (tlci-string->bytes [text : String]) : (__tl_dyn-array u8)
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (tlci-push-string-bytes! (&mut out) text)
    (byte_buf_core.byte-buf-builder-finish-array (& out))))

(define (tlci-bytes->string
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [len : i64]) : String
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 len)]
    [i : i64 0]
    (while (< i len)
      (set! (array-ref out i) (array-ref bytes (+ offset i)))
      (set! i (+ i 1)))
    (unsafe
      (string-from-bytes (ptr-cast (__tl_array-data out) : (Ptr u8)) len))))

(define (tlci-slice-bytes
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [len : i64]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 len)]
    [i : i64 0]
    (while (< i len)
      (set! (array-ref out i) (array-ref bytes (+ offset i)))
      (set! i (+ i 1)))
    out))

(define (tlci-copy-bytes [bytes : (& bytes (__tl_dyn-array u8))]) : (__tl_dyn-array
    u8)
  (tlci-slice-bytes bytes 0 (array-length bytes)))

(define (tlci-append-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [bytes : (& bytes (__tl_dyn-array u8))]) : unit
  (byte_buf_core.byte-buf-builder-append-array out (& bytes)))

(define (tlci-bytes-eq?
  [left : (& left (__tl_dyn-array u8))]
  [right : (& right (__tl_dyn-array u8))]) : bool
  (let
    [n : i64 (array-length left)]
    [i : i64 0]
    [ok : bool (= n (array-length right))]
    (while (and ok (< i n))
      (if (= (tlci-byte-at left i) (tlci-byte-at right i))
        (set! i (+ i 1))
        (set! ok false)))
    ok))

;; The image and range digests are the polynomial hash
;;
;;     h = 1;  h = (h * 131 + b) mod p   for each byte b,   p = 2^31 - 1
;;
;; and are part of the format, so they must keep their exact values. Computing
;; them a byte at a time costs a 64-bit modulo per byte, too slow for verifying
;; the whole embedded stdlib image on every compile. Eight bytes at a time is
;; the same polynomial, reduced once:
;;
;;     h' = h * 131^8 + (((b0 * 131 + b1) * 131 + ...) * 131 + b7)   (mod p)
;;
;; With h < p < 2^31, 131^8 mod p < 2^29 and the eight-byte Horner sum below
;; 2^58, the sum stays below 2^61, and p being a Mersenne prime reduces it with
;; two folds `x = (x & p) + (x >> 31)` and one conditional subtract instead of a
;; division.
(define tlci-hash-modulus : i64
  2147483647)

;; 131^8 mod p.
(define tlci-hash-step-8 : i64
  460949235)

;; x mod p for 0 <= x < 2^62.
(define (tlci-hash-reduce [x : i64]) : i64
  (let
    [once : i64 (+ (bit-and x tlci-hash-modulus) (shr x 31))]
    [twice : i64 (+ (bit-and once tlci-hash-modulus) (shr once 31))]
    (if (>= twice tlci-hash-modulus)
      (- twice tlci-hash-modulus)
      twice)))

;; Extend `hash` (< p) over bytes [start, end).
(define (tlci-hash-extend
  [bytes : (& bytes (__tl_dyn-array u8))]
  [hash : i64]
  [start : i64]
  [end : i64]) : i64
  (let
    [h : i64 hash]
    [i : i64 start]
    [limit : i64
      (if (< end (array-length bytes))
        end
        (array-length bytes))]
    ;; Four independent recurrences consume the eight-byte pieces of each
    ;; 32-byte group. Each advances by 131^32 mod p = 938964152. After the
    ;; last full group, weight them by 131^24, 131^16, 131^8 and 1 to put
    ;; the pieces back in byte order. The incoming digest starts in h3 so
    ;; its weight is exactly 131^(32 * groups), without an extra factor.
    ;;
    ;; Even maximal bytes and h_j = p-1 give x <= 2186534790481770432,
    ;; below 2^61, so the existing Mersenne reduction applies throughout.
    ;; Guard the subtraction once; neither the bound nor i+32 can overflow.
    ;; Keep the block polynomials here: extracting calls inhibits this
    ;; compiler's inlining and loses most of the independent-chain benefit.
    (when
      (and (>= i 0) (>= limit 32) (<= i (- limit 32)))
      (let
        [h0 : i64 0]
        [h1 : i64 0]
        [h2 : i64 0]
        [h3 : i64 h]
        (while (<= i (- limit 32))
          (let
            [a : i64
              (+ (* (tlci-byte-at bytes i) 131) (tlci-byte-at bytes (+ i 1)))]
            [b : i64
              (+
                (* (tlci-byte-at bytes (+ i 2)) 131)
                (tlci-byte-at bytes (+ i 3)))]
            [c : i64
              (+
                (* (tlci-byte-at bytes (+ i 4)) 131)
                (tlci-byte-at bytes (+ i 5)))]
            [d : i64
              (+
                (* (tlci-byte-at bytes (+ i 6)) 131)
                (tlci-byte-at bytes (+ i 7)))]
            [t : i64 (+ (* (+ (* a 17161) b) 294499921) (+ (* c 17161) d))]
            (set! h0 (tlci-hash-reduce (+ (* h0 938964152) t))))
          (let
            [a : i64
              (+
                (* (tlci-byte-at bytes (+ i 8)) 131)
                (tlci-byte-at bytes (+ i 9)))]
            [b : i64
              (+
                (* (tlci-byte-at bytes (+ i 10)) 131)
                (tlci-byte-at bytes (+ i 11)))]
            [c : i64
              (+
                (* (tlci-byte-at bytes (+ i 12)) 131)
                (tlci-byte-at bytes (+ i 13)))]
            [d : i64
              (+
                (* (tlci-byte-at bytes (+ i 14)) 131)
                (tlci-byte-at bytes (+ i 15)))]
            [t : i64 (+ (* (+ (* a 17161) b) 294499921) (+ (* c 17161) d))]
            (set! h1 (tlci-hash-reduce (+ (* h1 938964152) t))))
          (let
            [a : i64
              (+
                (* (tlci-byte-at bytes (+ i 16)) 131)
                (tlci-byte-at bytes (+ i 17)))]
            [b : i64
              (+
                (* (tlci-byte-at bytes (+ i 18)) 131)
                (tlci-byte-at bytes (+ i 19)))]
            [c : i64
              (+
                (* (tlci-byte-at bytes (+ i 20)) 131)
                (tlci-byte-at bytes (+ i 21)))]
            [d : i64
              (+
                (* (tlci-byte-at bytes (+ i 22)) 131)
                (tlci-byte-at bytes (+ i 23)))]
            [t : i64 (+ (* (+ (* a 17161) b) 294499921) (+ (* c 17161) d))]
            (set! h2 (tlci-hash-reduce (+ (* h2 938964152) t))))
          (let
            [a : i64
              (+
                (* (tlci-byte-at bytes (+ i 24)) 131)
                (tlci-byte-at bytes (+ i 25)))]
            [b : i64
              (+
                (* (tlci-byte-at bytes (+ i 26)) 131)
                (tlci-byte-at bytes (+ i 27)))]
            [c : i64
              (+
                (* (tlci-byte-at bytes (+ i 28)) 131)
                (tlci-byte-at bytes (+ i 29)))]
            [d : i64
              (+
                (* (tlci-byte-at bytes (+ i 30)) 131)
                (tlci-byte-at bytes (+ i 31)))]
            [t : i64 (+ (* (+ (* a 17161) b) 294499921) (+ (* c 17161) d))]
            (set! h3 (tlci-hash-reduce (+ (* h3 938964152) t))))
          (set! i (+ i 32)))
        (set!
          h
          (tlci-hash-reduce
            (+
              (tlci-hash-reduce (* h0 1117162002))
              (+
                (tlci-hash-reduce (* h1 549389049))
                (+ (tlci-hash-reduce (* h2 tlci-hash-step-8)) h3)))))))
    ;; Eight bytes per reduction (see above); the two-step Mersenne fold
    ;; of a sum below 2^61 lands in [0, p + 2], one conditional subtract
    ;; from p. The loop runs to the array length, so one guard covers all
    ;; eight reads.
    (while (<= (+ i 8) limit)
      (let
        ;; Pair adjacent bytes, then pairs of pairs. This is the same
        ;; eight-byte polynomial with three dependent multiplies instead
        ;; of seven; 131^2 and 131^4 both fit signed immediate operands.
        [a : i64
          (+ (* (tlci-byte-at bytes i) 131) (tlci-byte-at bytes (+ i 1)))]
        [b : i64
          (+ (* (tlci-byte-at bytes (+ i 2)) 131) (tlci-byte-at bytes (+ i 3)))]
        [c : i64
          (+ (* (tlci-byte-at bytes (+ i 4)) 131) (tlci-byte-at bytes (+ i 5)))]
        [d : i64
          (+ (* (tlci-byte-at bytes (+ i 6)) 131) (tlci-byte-at bytes (+ i 7)))]
        [t : i64 (+ (* (+ (* a 17161) b) 294499921) (+ (* c 17161) d))]
        [x : i64 (+ (* h tlci-hash-step-8) t)]
        [once : i64 (+ (bit-and x tlci-hash-modulus) (shr x 31))]
        [twice : i64 (+ (bit-and once tlci-hash-modulus) (shr once 31))]
        (set!
          h
          (if (>= twice tlci-hash-modulus)
            (- twice tlci-hash-modulus)
            twice))
        (set! i (+ i 8))))
    (while (< i end)
      (set! h (tlci-hash-reduce (+ (* h 131) (tlci-byte-at bytes i))))
      (set! i (+ i 1)))
    h))

;; The image digest; the digest field itself hashes as zeros.
(define (tlci-content-hash [bytes : (& bytes (__tl_dyn-array u8))]) : i64
  (let
    [n : i64 (array-length bytes)]
    [field-end : i64 (+ tlci-hash-field-offset tlci-hash-field-size)]
    (if (< n field-end)
      (tlci-content-hash-bytewise bytes)
      (tlci-hash-extend
        bytes
        (tlci-hash-reduce
          (*
            (tlci-hash-extend bytes 1 0 tlci-hash-field-offset)
            tlci-hash-step-8))
        field-end
        n))))

;; The byte-at-a-time definition, kept for images too short to hold the digest
;; field and as the reference the tests check the fast form against.
(define (tlci-content-hash-bytewise [bytes : (& bytes (__tl_dyn-array u8))]) : i64
  (let
    [n : i64 (array-length bytes)]
    [i : i64 0]
    [hash : i64 1]
    (while (< i n)
      (let
        [b : i64
          (if (and
            (>= i tlci-hash-field-offset)
            (< i (+ tlci-hash-field-offset tlci-hash-field-size)))
            0
            (tlci-byte-at bytes i))]
        (set! hash (% (+ (* hash 131) b) 2147483647))
        (set! i (+ i 1))))
    hash))

(define (tlci-range-hash
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [len : i64]) : i64
  (tlci-hash-extend bytes 1 offset (+ offset len)))

(define (tlci-aux-pack-rodata
  [base : (__tl_dyn-array u8)]
  [sections : (& sections (__tl_dyn-array TlciAuxSection))]) : ResultTlciAuxBytes
  (let
    [count : i64 (array-length sections)]
    (if (= count 0)
      (Ok (tlci-copy-bytes base))
      (let
        [offsets : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [lengths : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [hashes : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [out : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-new)]
        [index : i64 0]
        [previous-kind : i64 0]
        [ok : bool true]
        [message : String ""]
        (tlci-append-bytes! (&mut out) base)
        (while (and ok (< index count))
          (let
            [section : TlciAuxSection (clone (array-ref sections index))]
            [kind : i64 section.kind]
            [schema-version : i64 section.schema-version]
            [payload : (__tl_dyn-array u8) (clone section.payload)]
            (cond
              [(<= kind previous-kind)
                (set! ok false)
                (set!
                  message
                  "tlci: auxiliary section kinds must be positive and strictly ordered")]
              [(<= schema-version 0)
                (set! ok false)
                (set!
                  message
                  "tlci: auxiliary section schema version must be positive")]
              [else
                (let
                  [offset : i64 (tlci-align-offset out.len 8)]
                  [len : i64 (array-length payload)]
                  (tlci-pad-to! (&mut out) offset)
                  (set! (array-ref offsets index) offset)
                  (set! (array-ref lengths index) len)
                  (tlci-append-bytes! (&mut out) payload)
                  (set!
                    (array-ref hashes index)
                    (tlci-range-hash payload 0 len))
                  (set! previous-kind kind)
                  (set! index (+ index 1)))])))
        (if (not ok)
          (Err message)
          (let
            [directory-offset : i64 (tlci-align-offset out.len 8)]
            (tlci-pad-to! (&mut out) directory-offset)
            (set! index 0)
            (while (< index count)
              (let
                [section : TlciAuxSection (clone (array-ref sections index))]
                (tlci-push-u64! (&mut out) section.kind)
                (tlci-push-u64! (&mut out) section.schema-version)
                (tlci-push-u64! (&mut out) (array-ref offsets index))
                (tlci-push-u64! (&mut out) (array-ref lengths index))
                (tlci-push-u64! (&mut out) (array-ref hashes index))
                (set! index (+ index 1))))
            (let
              [trailer-offset : i64 out.len]
              [total-len : i64 (+ trailer-offset tlci-aux-trailer-size)]
              (tlci-push-u64! (&mut out) tlci-aux-magic)
              (tlci-push-u64! (&mut out) tlci-aux-format-version)
              (tlci-push-u64! (&mut out) (array-length base))
              (tlci-push-u64! (&mut out) directory-offset)
              (tlci-push-u64! (&mut out) count)
              (tlci-push-u64! (&mut out) total-len)
              (Ok (byte_buf_core.byte-buf-builder-finish-array (& out))))))))))

(define (tlci-aux-directory [rodata : (& rodata (__tl_dyn-array u8))]) : ResultTlciAuxDirectory
  (let
    [rodata-len : i64 (array-length rodata)]
    (if (< rodata-len tlci-aux-trailer-size)
      (Missing)
      (let
        [trailer-offset : i64 (- rodata-len tlci-aux-trailer-size)]
        [magic : i64 (tlci-read-u64 rodata trailer-offset)]
        (if (not (= magic tlci-aux-magic))
          (Missing)
          (let
            [version : i64 (tlci-read-u64 rodata (+ trailer-offset 8))]
            [base-len : i64 (tlci-read-u64 rodata (+ trailer-offset 16))]
            [directory-offset : i64
              (tlci-read-u64 rodata (+ trailer-offset 24))]
            [count : i64 (tlci-read-u64 rodata (+ trailer-offset 32))]
            [declared-len : i64 (tlci-read-u64 rodata (+ trailer-offset 40))]
            (cond
              [(not (= version tlci-aux-format-version))
                (Err "tlci: unsupported auxiliary section format version")]
              [(not (= declared-len rodata-len))
                (Err "tlci: auxiliary section length does not match rodata")]
              [(or
                  (<= count 0)
                  (> count (/ trailer-offset tlci-aux-record-size)))
                (Err "tlci: malformed auxiliary section count")]
              [(or
                  (< base-len 0)
                  (> base-len directory-offset)
                  (> directory-offset trailer-offset)
                  (not (= (% directory-offset 8) 0)))
                (Err "tlci: malformed auxiliary section directory offset")]
              [(not
                  (=
                    (+ directory-offset (* count tlci-aux-record-size))
                    trailer-offset))
                (Err "tlci: malformed auxiliary section directory length")]
              [else
                (Ok
                  (TlciAuxDirectory
                    base-len
                    directory-offset
                    count
                    trailer-offset))])))))))

(define (tlci-aux-records-valid?
  [rodata : (& rodata (__tl_dyn-array u8))]
  [directory : TlciAuxDirectory]) : bool
  (let
    [index : i64 0]
    [previous-kind : i64 0]
    [previous-end : i64 (tlci-align-offset directory.base-len 8)]
    [ok : bool true]
    (while (and ok (< index directory.count))
      (let
        [record : i64
          (+ directory.directory-offset (* index tlci-aux-record-size))]
        [kind : i64 (tlci-read-u64 rodata record)]
        [schema-version : i64 (tlci-read-u64 rodata (+ record 8))]
        [offset : i64 (tlci-read-u64 rodata (+ record 16))]
        [len : i64 (tlci-read-u64 rodata (+ record 24))]
        [expected-hash : i64 (tlci-read-u64 rodata (+ record 32))]
        (if (and
          (> kind previous-kind)
          (> schema-version 0)
          (>= offset previous-end)
          (= (% offset 8) 0)
          (>= len 0)
          (<= offset directory.directory-offset)
          (<= len (- directory.directory-offset offset))
          (= expected-hash (tlci-range-hash rodata offset len)))
          (begin
            (set! previous-kind kind)
            (set! previous-end (+ offset len))
            (set! index (+ index 1)))
          (set! ok false))))
    ok))

(define (tlci-aux-find
  [rodata : (& rodata (__tl_dyn-array u8))]
  [wanted-kind : i64]) : ResultTlciAuxLookup
  (match (tlci-aux-directory rodata)
    [(Missing) (Missing)]
    [(Err message) (Err message)]
    [(Ok directory)
      (if (not (tlci-aux-records-valid? rodata directory))
        (Err "tlci: malformed or corrupt auxiliary section directory")
        (let
          [index : i64 0]
          (while (< index directory.count)
            (let
              [record : i64
                (+ directory.directory-offset (* index tlci-aux-record-size))]
              [kind : i64 (tlci-read-u64 rodata record)]
              (if (= kind wanted-kind)
                (return
                  (Ok
                    (tlci-read-u64 rodata (+ record 8))
                    (tlci-slice-bytes
                      rodata
                      (tlci-read-u64 rodata (+ record 16))
                      (tlci-read-u64 rodata (+ record 24)))))
                (set! index (+ index 1)))))
          (Missing)))]))

(define (tlci-package-source-binding-digest-valid? [digest : i64]) : bool
  (and (>= digest 0) (< digest 2147483647)))

(define (tlci-package-source-binding-section [digest : i64]) : TlciAuxSection
  (let
    [payload : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    (tlci-set-u64! (&mut payload) 0 digest)
    (TlciAuxSection
      tlci-aux-kind-package-source-binding
      tlci-package-source-binding-schema-version
      payload)))

(define (tlci-package-source-binding-read
  [rodata : (& rodata (__tl_dyn-array u8))]) : TlciPackageSourceBindingRead
  (match (tlci-aux-find rodata tlci-aux-kind-package-source-binding)
    [(Missing) (MissingOrLegacy)]
    [(Err message) (Malformed message)]
    [(Ok schema payload)
      (if (not (= schema tlci-package-source-binding-schema-version))
        ;; Do not inspect a payload whose schema is not understood.
        (UnsupportedSchema schema)
        (if (not (= (array-length payload) 8))
          (Malformed
            "tlci: package source binding payload must be exactly 8 bytes")
          (let
            [digest : i64 (tlci-read-u64 payload 0)]
            (if (not (tlci-package-source-binding-digest-valid? digest))
              (Malformed "tlci: package source binding digest is out of range")
              (Bound digest)))))]))

(define (tlci-package-source-binding-admit
  [rodata : (& rodata (__tl_dyn-array u8))]
  [expected-digest : i64]) : TlciPackageSourceBindingAdmission
  (if (not (tlci-package-source-binding-digest-valid? expected-digest))
    (Malformed "tlci: expected package source binding digest is out of range")
    (match (tlci-package-source-binding-read rodata)
      [(Bound actual)
        (if (= expected-digest actual)
          (Match actual)
          (Mismatch expected-digest actual))]
      [(MissingOrLegacy) (MissingOrLegacy)]
      [(UnsupportedSchema schema) (UnsupportedSchema schema)]
      [(Malformed message) (Malformed message)])))

(define (tlci-char-code-at [text : (& text str)] [idx : i64]) : i64
  (cast (tlci-string-ref text idx) : i64))

(define (tlci-field-string-value [ftail : reader.SpannedSexpr] [fname : String]) : ResultTlciString
  (match (reader.sexpr-view ftail)
    [(List (slice (Str val-id _))) (Ok (ci.intern-id-str val-id))]
    [(List (slice (Str _ _) & _))
      (Err
        (str_cat.str-cat
          "tlci metadata: field `"
          fname
          "` takes one string value"))]
    [_
      (Err
        (str_cat.str-cat "tlci metadata: field `" fname "` must be a string"))]))

(define (tlci-field-i64-value [ftail : reader.SpannedSexpr] [fname : String]) : ResultTlciI64
  (match (reader.sexpr-view ftail)
    [(List (slice (Int val _ _))) (Ok val)]
    [(List (slice (Int _ _ _) & _))
      (Err
        (str_cat.str-cat
          "tlci metadata: field `"
          fname
          "` takes one integer value"))]
    [_
      (Err
        (str_cat.str-cat "tlci metadata: field `" fname "` must be an integer"))]))

(define (tlci-string-compare [left : (& left str)] [right : (& right str)]) : i64
  (let
    [left-len : i64 (tlci-string-length left)]
    [right-len : i64 (tlci-string-length right)]
    [limit : i64
      (if (< left-len right-len)
        left-len
        right-len)]
    [index : i64 0]
    [result : i64 0]
    (while (and (= result 0) (< index limit))
      (let
        [lc : i64 (tlci-char-code-at left index)]
        [rc : i64 (tlci-char-code-at right index)]
        (if (< lc rc)
          (set! result -1)
          (if (> lc rc)
            (set! result 1)
            unit))
        (set! index (+ index 1))))
    (if (= result 0)
      (if (< left-len right-len)
        -1
        (if (> left-len right-len)
          1
          0))
      result)))

(define (tlci-sexpr-list-length [items : reader.SpannedSexpr]) : i64
  (match (reader.sexpr-view items)
    [(List items-items) (tlci-sexpr-list-length-items items-items)]
    [_ -1]))

(define (tlci-sexpr-list-length-items
  [items : (& program (Slice reader.SpannedSexpr))]) : i64
  (match items
    [(slice) 0]
    [(slice _ & rest)
      (let
        [tail-len : i64 (tlci-sexpr-list-length-items rest)]
        (if (< tail-len 0)
          -1
          (+ tail-len 1)))]))

(define (tlci-signature-param-count [signature : String]) : i64
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [count : i64
      (match (reader.data-result signature)
        [(Err _) -1]
        [(Ok form)
          (match (reader.sexpr-view form)
            [(List (slice (Sym arrow _) & rest))
              (if (string.eq (tlci-symbol-text arrow) "->")
                (let
                  [item-count : i64 (tlci-sexpr-list-length-items rest)]
                  (if (> item-count 0)
                    (- item-count 1)
                    -1))
                -1)]
            [_ -1])])]
    (reader.sp-node-pool-truncate! mark)
    count))

(define (tlci-spmd-args-valid? [args : (& args str)]) : bool
  (let
    [count : i64 (tlci-string-length args)]
    [index : i64 0]
    [valid : bool true]
    (while (and valid (< index count))
      (let
        [code : i64 (tlci-char-code-at args index)]
        (if (or (= code 117) (= code 118))
          unit
          (set! valid false))
        (set! index (+ index 1))))
    valid))

(define (tlci-spmd-result-valid? [result : (& result str)]) : bool
  (or (string.eq result "unit") (string.eq result "u") (string.eq result "v")))

(define (tlci-spmd-specialization-validation-error
  [specialization : TlciSpmdSpecialization]
  [param-count : i64]) : String
  (let
    [abi : String specialization.abi]
    [backend : String specialization.backend]
    [lanes : i64 specialization.lanes]
    [args : String specialization.args]
    [result : String specialization.result]
    [index-param : i64 specialization.index-param]
    [symbol : String specialization.symbol]
    (cond
      [(string.eq abi "") "tlci metadata: specialization ABI must not be empty"]
      [(and
          (string.eq abi "spmd-call-v1")
          (not (or (string.eq backend "scalar") (string.eq backend "avx512"))))
        (str_cat.str-cat
          "tlci metadata: unsupported backend `"
          backend
          "` for `spmd-call-v1`")]
      [(string.eq backend "")
        "tlci metadata: specialization backend must not be empty"]
      [(<= lanes 0) "tlci metadata: specialization lanes must be positive"]
      [(and
          (string.eq abi "spmd-call-v1")
          (string.eq backend "scalar")
          (not (= lanes 1)))
        "tlci metadata: scalar `spmd-call-v1` specialization must use one lane"]
      [(not (tlci-spmd-args-valid? args))
        "tlci metadata: specialization args must contain only `u` and `v`"]
      [(not (= (tlci-string-length args) param-count))
        "tlci metadata: specialization args length must equal signature parameter count"]
      [(not (tlci-spmd-result-valid? result))
        "tlci metadata: specialization result must be `unit`, `u`, or `v`"]
      [(not
          (or
            (= index-param -1)
            (and (>= index-param 0) (< index-param param-count))))
        "tlci metadata: specialization index-param is outside the signature"]
      [(and
          (>= index-param 0)
          (not (= (tlci-char-code-at args index-param) 118)))
        "tlci metadata: specialization index-param must name a varying argument"]
      [(string.eq symbol "")
        "tlci metadata: specialization symbol must not be empty"]
      [else ""])))

(define (tlci-spmd-specialization-compare
  [left : (& left TlciSpmdSpecialization)]
  [right : TlciSpmdSpecialization]) : i64
  (let
    [backend : i64 (tlci-string-compare left.backend right.backend)]
    (if (not (= backend 0))
      backend
      (let
        [left-lanes : i64 left.lanes]
        [right-lanes : i64 right.lanes]
        (if (not (= left-lanes right-lanes))
          (if (< left-lanes right-lanes)
            -1
            1)
          (let
            [args : i64 (tlci-string-compare left.args right.args)]
            (if (not (= args 0))
              args
              (let
                [result : i64 (tlci-string-compare left.result right.result)]
                (if (not (= result 0))
                  result
                  (let
                    [left-index : i64 left.index-param]
                    [right-index : i64 right.index-param]
                    (if (not (= left-index right-index))
                      (if (< left-index right-index)
                        -1
                        1)
                      (let
                        [symbol : i64
                          (tlci-string-compare left.symbol right.symbol)]
                        (if (not (= symbol 0))
                          symbol
                          0)))))))))))))

(define (tlci-spmd-callable-compare
  [left : (& left TlciSpmdCallable)]
  [right : TlciSpmdCallable]) : i64
  (let
    [name : i64 (tlci-string-compare left.name right.name)]
    (if (not (= name 0))
      name
      (tlci-string-compare left.signature right.signature))))

(define (tlci-spmd-specializations-validation-error
  [items : TlciSpmdSpecializations]
  [param-count : i64]) : String
  (let
    [count : i64 (tlci-spmd-specializations-len items)]
    [index : i64 0]
    ;; A separate stop flag keeps `error` unborrowed at the loop head, so the
    ;; first failing record can be moved into it.
    [failed : bool false]
    [error : String ""]
    (while (and (not failed) (< index count))
      (let
        [item : TlciSpmdSpecialization
          (tlci-spmd-specializations-ref items index)]
        [item-error : String
          (tlci-spmd-specialization-validation-error (clone item) param-count)]
        [item-ok : bool (string.eq item-error "")]
        (cond
          [(not item-ok)
            (set! failed true)
            (set! error item-error)]
          [(>= (+ index 1) count) unit]
          [else
            (let
              [order : i64
                (tlci-spmd-specialization-compare
                  item
                  (tlci-spmd-specializations-ref items (+ index 1)))]
              (cond
                [(= order 0)
                  (set! failed true)
                  (set! error "tlci metadata: duplicate specialization record")]
                [(> order 0)
                  (set! failed true)
                  (set!
                    error
                    "tlci metadata: specialization records are not in stable order")]
                [else unit]))])
        (set! index (+ index 1))))
    error))

(define (tlci-spmd-callable-validation-error [callable : TlciSpmdCallable]) : String
  (let
    [name : String callable.name]
    [signature : String callable.signature]
    [param-count : i64 (tlci-signature-param-count (string.copy signature))]
    (cond
      [(string.eq name "") "tlci metadata: helper name must not be empty"]
      [(string.eq signature "")
        "tlci metadata: helper signature must not be empty"]
      [(< param-count 0)
        "tlci metadata: helper signature must be a function signature"]
      [(= (tlci-spmd-specializations-len callable.specializations) 0)
        "tlci metadata: helper requires at least one specialization"]
      [else
        (tlci-spmd-specializations-validation-error
          callable.specializations
          param-count)])))

(define (tlci-spmd-callables-validation-error [items : TlciSpmdCallables]) : String
  (let
    [count : i64 (tlci-spmd-callables-len items)]
    [index : i64 0]
    ;; Same stop flag as the specialization walk above.
    [failed : bool false]
    [error : String ""]
    (while (and (not failed) (< index count))
      (let
        [item : TlciSpmdCallable (tlci-spmd-callables-ref items index)]
        [item-error : String (tlci-spmd-callable-validation-error (clone item))]
        [item-ok : bool (string.eq item-error "")]
        (cond
          [(not item-ok)
            (set! failed true)
            (set! error item-error)]
          [(>= (+ index 1) count) unit]
          [else
            (let
              [order : i64
                (tlci-spmd-callable-compare
                  item
                  (tlci-spmd-callables-ref items (+ index 1)))]
              (cond
                [(= order 0)
                  (set! failed true)
                  (set! error "tlci metadata: duplicate helper record")]
                [(> order 0)
                  (set! failed true)
                  (set!
                    error
                    "tlci metadata: helper records are not in stable order")]
                [else unit]))])
        (set! index (+ index 1))))
    error))

(define (tlci-spmd-specialization-fields
  [fields : reader.SpannedSexpr]
  [abi : String]
  [has-abi : bool]
  [backend : String]
  [has-backend : bool]
  [lanes : i64]
  [has-lanes : bool]
  [args : String]
  [has-args : bool]
  [result : String]
  [has-result : bool]
  [index-param : i64]
  [has-index-param : bool]
  [symbol : String]
  [has-symbol : bool]) : ResultTlciSpmdSpecialization
  (match (reader.sexpr-view fields)
    [(List items)
      (tlci-spmd-specialization-fields-items
        items
        abi
        has-abi
        backend
        has-backend
        lanes
        has-lanes
        args
        has-args
        result
        has-result
        index-param
        has-index-param
        symbol
        has-symbol)]
    [_ (Err "tlci metadata: specialization fields must be lists")]))

(define (tlci-spmd-specialization-fields-items
  [fields : (& program (Slice reader.SpannedSexpr))]
  [abi : String]
  [has-abi : bool]
  [backend : String]
  [has-backend : bool]
  [lanes : i64]
  [has-lanes : bool]
  [args : String]
  [has-args : bool]
  [result : String]
  [has-result : bool]
  [index-param : i64]
  [has-index-param : bool]
  [symbol : String]
  [has-symbol : bool]) : ResultTlciSpmdSpecialization
  (match fields
    [(slice)
      (cond
        [(not has-abi)
          (Err "tlci metadata: specialization missing required field `abi`")]
        [(not has-backend)
          (Err "tlci metadata: specialization missing required field `backend`")]
        [(not has-lanes)
          (Err "tlci metadata: specialization missing required field `lanes`")]
        [(not has-args)
          (Err "tlci metadata: specialization missing required field `args`")]
        [(not has-result)
          (Err "tlci metadata: specialization missing required field `result`")]
        [(not has-index-param)
          (Err
            "tlci metadata: specialization missing required field `index-param`")]
        [(not has-symbol)
          (Err "tlci metadata: specialization missing required field `symbol`")]
        [else
          (Ok
            (TlciSpmdSpecialization
              abi
              backend
              lanes
              args
              result
              index-param
              symbol))])]
    [(slice field & rest)
      (match (reader.sexpr-view field)
        [(List (slice (Sym fname _) & _))
          (let
            [ftail (reader.spanned-sexpr-drop field 1)]
            (cond
              [(string.eq (tlci-symbol-text fname) "abi")
                (if has-abi
                  (Err "tlci metadata: duplicate specialization field `abi`")
                  (let
                    [value
                      (try
                        (tlci-field-string-value ftail (tlci-symbol-text fname)))]
                    (tlci-spmd-specialization-fields-items
                      rest
                      value
                      true
                      backend
                      has-backend
                      lanes
                      has-lanes
                      args
                      has-args
                      result
                      has-result
                      index-param
                      has-index-param
                      symbol
                      has-symbol)))]
              [(string.eq (tlci-symbol-text fname) "backend")
                (if has-backend
                  (Err
                    "tlci metadata: duplicate specialization field `backend`")
                  (let
                    [value
                      (try
                        (tlci-field-string-value ftail (tlci-symbol-text fname)))]
                    (tlci-spmd-specialization-fields-items
                      rest
                      abi
                      has-abi
                      value
                      true
                      lanes
                      has-lanes
                      args
                      has-args
                      result
                      has-result
                      index-param
                      has-index-param
                      symbol
                      has-symbol)))]
              [(string.eq (tlci-symbol-text fname) "lanes")
                (if has-lanes
                  (Err "tlci metadata: duplicate specialization field `lanes`")
                  (let
                    [value
                      (try
                        (tlci-field-i64-value ftail (tlci-symbol-text fname)))]
                    (tlci-spmd-specialization-fields-items
                      rest
                      abi
                      has-abi
                      backend
                      has-backend
                      value
                      true
                      args
                      has-args
                      result
                      has-result
                      index-param
                      has-index-param
                      symbol
                      has-symbol)))]
              [(string.eq (tlci-symbol-text fname) "args")
                (if has-args
                  (Err "tlci metadata: duplicate specialization field `args`")
                  (let
                    [value
                      (try
                        (tlci-field-string-value ftail (tlci-symbol-text fname)))]
                    (tlci-spmd-specialization-fields-items
                      rest
                      abi
                      has-abi
                      backend
                      has-backend
                      lanes
                      has-lanes
                      value
                      true
                      result
                      has-result
                      index-param
                      has-index-param
                      symbol
                      has-symbol)))]
              [(string.eq (tlci-symbol-text fname) "result")
                (if has-result
                  (Err "tlci metadata: duplicate specialization field `result`")
                  (let
                    [value
                      (try
                        (tlci-field-string-value ftail (tlci-symbol-text fname)))]
                    (tlci-spmd-specialization-fields-items
                      rest
                      abi
                      has-abi
                      backend
                      has-backend
                      lanes
                      has-lanes
                      args
                      has-args
                      value
                      true
                      index-param
                      has-index-param
                      symbol
                      has-symbol)))]
              [(string.eq (tlci-symbol-text fname) "index-param")
                (if has-index-param
                  (Err
                    "tlci metadata: duplicate specialization field `index-param`")
                  (let
                    [value
                      (try
                        (tlci-field-i64-value ftail (tlci-symbol-text fname)))]
                    (tlci-spmd-specialization-fields-items
                      rest
                      abi
                      has-abi
                      backend
                      has-backend
                      lanes
                      has-lanes
                      args
                      has-args
                      result
                      has-result
                      value
                      true
                      symbol
                      has-symbol)))]
              [(string.eq (tlci-symbol-text fname) "symbol")
                (if has-symbol
                  (Err "tlci metadata: duplicate specialization field `symbol`")
                  (let
                    [value
                      (try
                        (tlci-field-string-value ftail (tlci-symbol-text fname)))]
                    (tlci-spmd-specialization-fields-items
                      rest
                      abi
                      has-abi
                      backend
                      has-backend
                      lanes
                      has-lanes
                      args
                      has-args
                      result
                      has-result
                      index-param
                      has-index-param
                      value
                      true)))]
              [else
                (Err
                  (str_cat.str-cat
                    "tlci metadata: unknown specialization field `"
                    (tlci-symbol-text fname)
                    "`"))]))]
        [(List (slice _ & _))
          (Err "tlci metadata: specialization fields must start with a name")]
        [_ (Err "tlci metadata: specialization fields must be lists")])]))

(define (tlci-spmd-specialization-from-field [fields : reader.SpannedSexpr]) : ResultTlciSpmdSpecialization
  (tlci-spmd-specialization-fields
    fields
    ""
    false
    ""
    false
    0
    false
    ""
    false
    ""
    false
    0
    false
    ""
    false))

(define (tlci-spmd-helper-fields
  [fields : reader.SpannedSexpr]
  [name : String]
  [has-name : bool]
  [signature : String]
  [has-signature : bool]
  [specializations : TlciSpmdSpecializations]) : ResultTlciSpmdCallable
  (match (reader.sexpr-view fields)
    [(List items)
      (tlci-spmd-helper-fields-items
        items
        name
        has-name
        signature
        has-signature
        specializations)]
    [_ (Err "tlci metadata: helper fields must be lists")]))

(define (tlci-spmd-helper-fields-items
  [fields : (& program (Slice reader.SpannedSexpr))]
  [name : String]
  [has-name : bool]
  [signature : String]
  [has-signature : bool]
  [specializations : TlciSpmdSpecializations]) : ResultTlciSpmdCallable
  (match fields
    [(slice)
      (cond
        [(not has-name)
          (Err "tlci metadata: helper missing required field `name`")]
        [(not has-signature)
          (Err "tlci metadata: helper missing required field `signature`")]
        [else (Ok (TlciSpmdCallable name signature specializations))])]
    [(slice field & rest)
      (match (reader.sexpr-view field)
        [(List (slice (Sym fname _) & _))
          (let
            [ftail (reader.spanned-sexpr-drop field 1)]
            (cond
              [(string.eq (tlci-symbol-text fname) "name")
                (if has-name
                  (Err "tlci metadata: duplicate helper field `name`")
                  (let
                    [value
                      (try
                        (tlci-field-string-value ftail (tlci-symbol-text fname)))]
                    (tlci-spmd-helper-fields-items
                      rest
                      value
                      true
                      signature
                      has-signature
                      specializations)))]
              [(string.eq (tlci-symbol-text fname) "signature")
                (if has-signature
                  (Err "tlci metadata: duplicate helper field `signature`")
                  (let
                    [value
                      (try
                        (tlci-field-string-value ftail (tlci-symbol-text fname)))]
                    (tlci-spmd-helper-fields-items
                      rest
                      name
                      has-name
                      value
                      true
                      specializations)))]
              [(string.eq (tlci-symbol-text fname) "specialization")
                (let
                  [specialization
                    (try (tlci-spmd-specialization-from-field ftail))]
                  (tlci-spmd-helper-fields-items
                    rest
                    name
                    has-name
                    signature
                    has-signature
                    (tlci-spmd-specializations-push
                      specializations
                      specialization)))]
              [else
                (Err
                  (str_cat.str-cat
                    "tlci metadata: unknown helper field `"
                    (tlci-symbol-text fname)
                    "`"))]))]
        [(List (slice _ & _))
          (Err "tlci metadata: helper fields must start with a name")]
        [_ (Err "tlci metadata: helper fields must be lists")])]))

(define (tlci-spmd-helper-from-form [form : reader.SpannedSexpr]) : ResultTlciSpmdCallable
  (match (reader.sexpr-view form)
    [(List (slice (Sym name _) & _))
      (let
        [rest (reader.spanned-sexpr-drop form 1)]
        (if (string.eq (tlci-symbol-text name) "helper")
          (let
            [field-count : i64 (tlci-sexpr-list-length (clone rest))]
            (tlci-spmd-helper-fields
              rest
              ""
              false
              ""
              false
              (tlci-spmd-specializations-with-capacity
                (if (< field-count 0)
                  0
                  field-count))))
          (Err
            (str_cat.str-cat
              "tlci metadata: expected `helper`, got `"
              (tlci-symbol-text name)
              "`"))))]
    [(List (slice _ & _))
      (Err "tlci metadata: spmd-callables entries must start with `helper`")]
    [_ (Err "tlci metadata: spmd-callables entries must be helper lists")]))

(define (tlci-spmd-callables-from-fields
  [fields : reader.SpannedSexpr]
  [items : TlciSpmdCallables]) : ResultTlciSpmdCallables
  (match (reader.sexpr-view fields)
    [(List fields-items)
      (tlci-spmd-callables-from-fields-items fields-items items)]
    [_ (Err "tlci metadata: spmd-callables must contain helper lists")]))

(define (tlci-spmd-callables-from-fields-items
  [fields : (& program (Slice reader.SpannedSexpr))]
  [items : TlciSpmdCallables]) : ResultTlciSpmdCallables
  (match fields
    [(slice) (Ok items)]
    [(slice item & rest)
      (let
        [callable (try (tlci-spmd-helper-from-form item))]
        (tlci-spmd-callables-from-fields-items
          rest
          (tlci-spmd-callables-push items callable)))]))

(define (tlci-spmd-callables-from-field [fields : reader.SpannedSexpr]) : ResultTlciSpmdCallables
  (let
    [field-count : i64 (tlci-sexpr-list-length (clone fields))]
    (tlci-spmd-callables-from-fields
      fields
      (tlci-spmd-callables-with-capacity
        (if (< field-count 0)
          0
          field-count)))))

(define (tlci-package-fields
  [fields : reader.SpannedSexpr]
  [name : String]
  [has-name : bool]
  [version : String]
  [has-version : bool]) : ResultTlciMetadata
  (match (reader.sexpr-view fields)
    [(List items)
      (tlci-package-fields-items items name has-name version has-version)]
    [_ (Err "tlci metadata: package fields must be lists")]))

(define (tlci-package-fields-items
  [fields : (& program (Slice reader.SpannedSexpr))]
  [name : String]
  [has-name : bool]
  [version : String]
  [has-version : bool]) : ResultTlciMetadata
  (match fields
    [(slice)
      (cond
        [(not has-name)
          (Err "tlci metadata: package missing required field `name`")]
        [(not has-version)
          (Err "tlci metadata: package missing required field `version`")]
        [(string.eq name "")
          (Err "tlci metadata: package name must not be empty")]
        [(string.eq version "")
          (Err "tlci metadata: package version must not be empty")]
        [else
          (Ok
            (TlciMetadata
              (string.copy (& tlci-metadata-version))
              name
              version
              (tlci-spmd-callables-empty)))])]
    [(slice field & rest)
      (match (reader.sexpr-view field)
        [(List (slice (Sym fname _) & _))
          (let
            [ftail (reader.spanned-sexpr-drop field 1)]
            (if (string.eq (tlci-symbol-text fname) "name")
              (if has-name
                (Err "tlci metadata: duplicate package field `name`")
                (let
                  [value
                    (try
                      (tlci-field-string-value ftail (tlci-symbol-text fname)))]
                  (tlci-package-fields-items
                    rest
                    value
                    true
                    version
                    has-version)))
              (if (string.eq (tlci-symbol-text fname) "version")
                (if has-version
                  (Err "tlci metadata: duplicate package field `version`")
                  (let
                    [value
                      (try
                        (tlci-field-string-value ftail (tlci-symbol-text fname)))]
                    (tlci-package-fields-items rest name has-name value true)))
                (Err
                  (str_cat.str-cat
                    "tlci metadata: unknown package field `"
                    (tlci-symbol-text fname)
                    "`")))))]
        [(List (slice _ & _))
          (Err "tlci metadata: package fields must start with a name")]
        [_ (Err "tlci metadata: package fields must be lists")])]))

(define (tlci-package-from-field [ftail : reader.SpannedSexpr]) : ResultTlciMetadata
  (tlci-package-fields ftail "" false "" false))

(define (tlci-metadata-fields-items
  [fields : (& program (Slice reader.SpannedSexpr))]
  [version : String]
  [has-version : bool]
  [package-name : String]
  [package-version : String]
  [has-package : bool]
  [spmd-callables : TlciSpmdCallables]
  [has-spmd-callables : bool]) : ResultTlciMetadata
  (match fields
    [(slice)
      (cond
        [(not has-version)
          (Err "tlci metadata: missing required field `version`")]
        [(not
            (or
              (string.eq version tlci-metadata-version)
              (string.eq version tlci-metadata-version-v2)))
          (Err
            (str_cat.str-cat "tlci metadata: unsupported version `" version "`"))]
        [(not has-package)
          (Err "tlci metadata: missing required field `package`")]
        [(and (string.eq version tlci-metadata-version) has-spmd-callables)
          (Err "tlci metadata: field `spmd-callables` requires version `v2`")]
        [(not
            (string.eq
              (tlci-spmd-callables-validation-error (clone spmd-callables))
              ""))
          (Err (tlci-spmd-callables-validation-error (clone spmd-callables)))]
        [else
          (Ok
            (TlciMetadata version package-name package-version spmd-callables))])]
    [(slice field & rest)
      (match (reader.sexpr-view field)
        [(List (slice (Sym fname _) & _))
          (let
            [ftail (reader.spanned-sexpr-drop field 1)]
            (cond
              [(string.eq (tlci-symbol-text fname) "version")
                (if has-version
                  (Err "tlci metadata: duplicate field `version`")
                  (let
                    [value
                      (try
                        (tlci-field-string-value ftail (tlci-symbol-text fname)))]
                    (tlci-metadata-fields-items
                      rest
                      value
                      true
                      package-name
                      package-version
                      has-package
                      spmd-callables
                      has-spmd-callables)))]
              [(string.eq (tlci-symbol-text fname) "package")
                (if has-package
                  (Err "tlci metadata: duplicate field `package`")
                  (let
                    [parsed (try (tlci-package-from-field ftail))]
                    (tlci-metadata-fields-items
                      rest
                      version
                      has-version
                      parsed.package-name
                      parsed.package-version
                      true
                      spmd-callables
                      has-spmd-callables)))]
              [(string.eq (tlci-symbol-text fname) "spmd-callables")
                (if has-spmd-callables
                  (Err "tlci metadata: duplicate field `spmd-callables`")
                  (let
                    [parsed (try (tlci-spmd-callables-from-field ftail))]
                    (tlci-metadata-fields-items
                      rest
                      version
                      has-version
                      package-name
                      package-version
                      has-package
                      parsed
                      true)))]
              [else
                (Err
                  (str_cat.str-cat
                    "tlci metadata: unknown field `"
                    (tlci-symbol-text fname)
                    "`"))]))]
        [(List (slice _ & _))
          (Err "tlci metadata: fields must start with a field name")]
        [_ (Err "tlci metadata: fields must be lists")])]))

(define (tlci-metadata-from-form [form : reader.SpannedSexpr]) : ResultTlciMetadata
  (match (reader.sexpr-view form)
    [(List items) (tlci-metadata-from-form-items items)]
    [_ (Err "tlci metadata: expected `(typelisp-tlci-metadata ...)`")]))

(define (tlci-metadata-from-form-items
  [form : (& program (Slice reader.SpannedSexpr))]) : ResultTlciMetadata
  (match form
    [(slice head & rest)
      (match (reader.sexpr-view head)
        [(Sym name)
          (if (string.eq (tlci-symbol-text name) "typelisp-tlci-metadata")
            (tlci-metadata-fields-items
              rest
              ""
              false
              ""
              ""
              false
              (tlci-spmd-callables-empty)
              false)
            (Err
              (str_cat.str-cat
                "expected `typelisp-tlci-metadata` form, got `"
                (tlci-symbol-text name)
                "`")))]
        [_ (Err "tlci metadata: form must start with `typelisp-tlci-metadata`")])]
    [_ (Err "tlci metadata: expected `(typelisp-tlci-metadata ...)`")]))

(define (tlci-metadata-parse [source : String]) : ResultTlciMetadata
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [result : ResultTlciMetadata
      (match (reader.data-result source)
        [(Err message) (Err (str_cat.str-cat "tlci metadata: " message))]
        [(Ok form) (tlci-metadata-from-form form)])]
    (reader.sp-node-pool-truncate! mark)
    result))

(define (tlci-quote-text) : String
  "\"")

(define (tlci-backslash-text) : String
  "\\")

(define (tlci-escape-string [text : String]) : String
  (let
    [n : i64 (tlci-string-length text)]
    [i : i64 0]
    [out : String ""]
    [slash : String (tlci-backslash-text)]
    [quote : String (tlci-quote-text)]
    (while (< i n)
      (let
        [code : i64 (tlci-char-code-at text i)]
        (cond
          [(= code 34)
            (set!
              out
              (str_cat.str-cat out (string.copy slash) (string.copy quote)))]
          [(= code 92)
            (set!
              out
              (str_cat.str-cat out (string.copy slash) (string.copy slash)))]
          [(= code 10) (set! out (str_cat.str-cat out (string.copy slash) "n"))]
          [(= code 9) (set! out (str_cat.str-cat out (string.copy slash) "t"))]
          [(= code 13) (set! out (str_cat.str-cat out (string.copy slash) "r"))]
          [else (set! out (str_cat.str-cat out (string.substring text i 1)))]))
      (set! i (+ i 1)))
    out))

(define (tlci-quote-string [text : String]) : String
  (str_cat.str-cat
    (tlci-quote-text)
    (tlci-escape-string text)
    (tlci-quote-text)))

(define (tlci-spmd-specializations-emit [items : TlciSpmdSpecializations]) : String
  (let
    [count : i64 (tlci-spmd-specializations-len items)]
    [index : i64 0]
    [out : String ""]
    (while (< index count)
      (let
        [item : TlciSpmdSpecialization
          (tlci-spmd-specializations-ref items index)]
        (set!
          out
          (str_cat.str-cat
            out
            "    (specialization\n"
            "      (abi "
            (tlci-quote-string item.abi)
            ")\n"
            "      (backend "
            (tlci-quote-string item.backend)
            ")\n"
            "      (lanes "
            (string.int->string item.lanes)
            ")\n"
            "      (args "
            (tlci-quote-string item.args)
            ")\n"
            "      (result "
            (tlci-quote-string item.result)
            ")\n"
            "      (index-param "
            (string.int->string item.index-param)
            ")\n"
            "      (symbol "
            (tlci-quote-string item.symbol)
            "))\n"))
        (set! index (+ index 1))))
    out))

(define (tlci-spmd-callables-emit-items [items : TlciSpmdCallables]) : String
  (let
    [count : i64 (tlci-spmd-callables-len items)]
    [index : i64 0]
    [out : String ""]
    (while (< index count)
      (let
        [item : TlciSpmdCallable (tlci-spmd-callables-ref items index)]
        (set!
          out
          (str_cat.str-cat
            out
            "  (helper\n"
            "    (name "
            (tlci-quote-string item.name)
            ")\n"
            "    (signature "
            (tlci-quote-string item.signature)
            ")\n"
            (tlci-spmd-specializations-emit item.specializations)
            "  )\n"))
        (set! index (+ index 1))))
    out))

(define (tlci-spmd-callables-emit [items : TlciSpmdCallables]) : String
  (if (= (tlci-spmd-callables-len items) 0)
    ""
    (str_cat.str-cat
      "  (spmd-callables\n"
      (tlci-spmd-callables-emit-items items)
      "  )\n")))

(define (tlci-metadata-validation-error [metadata : TlciMetadata]) : String
  (let
    [version : String metadata.version]
    [callables : TlciSpmdCallables metadata.spmd-callables]
    (cond
      [(not
          (or
            (string.eq version tlci-metadata-version)
            (string.eq version tlci-metadata-version-v2)))
        (str_cat.str-cat "tlci metadata: unsupported version `" version "`")]
      [(string.eq metadata.package-name "")
        "tlci metadata: package name must not be empty"]
      [(string.eq metadata.package-version "")
        "tlci metadata: package version must not be empty"]
      [(and
          (string.eq version tlci-metadata-version)
          (> (tlci-spmd-callables-len callables) 0))
        "tlci metadata: field `spmd-callables` requires version `v2`"]
      [else (tlci-spmd-callables-validation-error callables)])))

(define (tlci-metadata-emit [metadata : TlciMetadata]) : String
  (let
    [prefix : String
      (str_cat.str-cat
        "(typelisp-tlci-metadata\n"
        "  (version "
        (tlci-quote-string metadata.version)
        ")\n"
        "  (package (name "
        (tlci-quote-string metadata.package-name)
        ") (version "
        (tlci-quote-string metadata.package-version))]
    [callables : TlciSpmdCallables metadata.spmd-callables]
    (if (= (tlci-spmd-callables-len callables) 0)
      (str_cat.str-cat prefix ")))\n")
      (str_cat.str-cat prefix "))\n" (tlci-spmd-callables-emit callables) ")\n"))))

(define (tlci-section-offset [cursor : i64] [len : i64] [align : i64]) : i64
  (if (= len 0)
    0
    (tlci-align-offset cursor align)))

(define (tlci-section-end [cursor : i64] [offset : i64] [len : i64]) : i64
  (if (= len 0)
    cursor
    (+ offset len)))

(define (tlci-section-ordered? [cursor : i64] [offset : i64] [len : i64]) : bool
  (or (= len 0) (>= offset cursor)))

(define (tlci-import-section-count [imports : (& imports (__tl_dyn-array u8))]) : i64
  (let
    [len : i64 (array-length imports)]
    (cond
      [(= len 0) 0]
      [(< len tlci-section-import-header-size) -1]
      [else (tlci-read-u64 imports 0)])))

(define (tlci-import-section-validation-error
  [imports : (& imports (__tl_dyn-array u8))]
  [expected-count : i64]) : String
  (let
    [len : i64 (array-length imports)]
    [records-end : i64
      (+
        tlci-section-import-header-size
        (* expected-count tlci-section-import-record-size))]
    [index : i64 0]
    [error : String ""]
    (cond
      [(< expected-count 0) "import count must not be negative"]
      [(= expected-count 0)
        (if (= len 0)
          ""
          "empty import table has payload bytes")]
      [(< len tlci-section-import-header-size)
        "import section is smaller than its header"]
      [(not (= (tlci-read-u64 imports 0) expected-count))
        "import section count does not match the tlci header"]
      [(or (< records-end tlci-section-import-header-size) (> records-end len))
        "import records exceed the import section"]
      [else
        (while (and (= (string.string-length error) 0) (< index expected-count))
          (let
            [record : i64
              (+
                tlci-section-import-header-size
                (* index tlci-section-import-record-size))]
            [name-offset : i64 (tlci-read-u64 imports (+ record 8))]
            [name-len : i64 (tlci-read-u64 imports (+ record 16))]
            (cond
              [(= name-len 0) (set! error "import name must not be empty")]
              [(< name-offset records-end)
                (set! error "import name overlaps the record table")]
              [(not
                  (and
                    (>= name-offset 0)
                    (>= name-len 0)
                    (<= name-offset len)
                    (<= name-len (- len name-offset))))
                (set! error "import name is outside the import section")]
              [else (set! index (+ index 1))])))
        error])))

(define (tlci-emit-image-v2-legacy-compatible [image : TlciImage]) : ResultTlciBytes
  (cond
    [(not
        (string.eq (tlci-metadata-validation-error (clone image.metadata)) ""))
      (Err (tlci-metadata-validation-error (clone image.metadata)))]
    [(string.eq image.compiler-build-hash "")
      (Err "tlci: compiler build hash must not be empty")]
    [(not (= (% (array-length image.fixups) tlci-section-fixup-record-size) 0))
      (Err "tlci: malformed fixup table length")]
    [(not (= (% (array-length image.entries) tlci-section-entry-record-size) 0))
      (Err "tlci: malformed entry table length")]
    [(not
        (= (% (array-length image.symbols) tlci-section-symbol-record-size) 0))
      (Err "tlci: malformed symbol table length")]
    [(not
        (string.eq
          (tlci-import-section-validation-error
            image.imports
            (tlci-import-section-count image.imports))
          ""))
      (Err
        (str_cat.str-cat
          "tlci: malformed import section: "
          (tlci-import-section-validation-error
            image.imports
            (tlci-import-section-count image.imports))))]
    [else
      (let
        [compiler-hash-bytes : (__tl_dyn-array u8)
          (tlci-string->bytes image.compiler-build-hash)]
        [metadata-text : String (tlci-metadata-emit image.metadata)]
        [metadata-bytes : (__tl_dyn-array u8)
          (tlci-string->bytes metadata-text)]
        [hash-offset : i64 tlci-header-size]
        [metadata-offset : i64
          (tlci-align-offset
            (+ hash-offset (array-length compiler-hash-bytes))
            8)]
        [after-metadata : i64 (+ metadata-offset (array-length metadata-bytes))]
        [rodata-len : i64 (array-length image.rodata)]
        [code-len : i64 (array-length image.code)]
        [fixups-len : i64 (array-length image.fixups)]
        [entries-len : i64 (array-length image.entries)]
        [symbols-len : i64 (array-length image.symbols)]
        [rodata-offset : i64
          (tlci-section-offset after-metadata rodata-len tlci-page-align)]
        [after-rodata : i64
          (tlci-section-end after-metadata rodata-offset rodata-len)]
        [code-offset : i64
          (tlci-section-offset after-rodata code-len tlci-page-align)]
        [after-code : i64 (tlci-section-end after-rodata code-offset code-len)]
        [fixups-offset : i64 (tlci-section-offset after-code fixups-len 8)]
        [after-fixups : i64
          (tlci-section-end after-code fixups-offset fixups-len)]
        [entries-offset : i64 (tlci-section-offset after-fixups entries-len 8)]
        [after-entries : i64
          (tlci-section-end after-fixups entries-offset entries-len)]
        [symbols-offset : i64 (tlci-section-offset after-entries symbols-len 8)]
        [after-symbols : i64
          (tlci-section-end after-entries symbols-offset symbols-len)]
        [imports-len : i64 (array-length image.imports)]
        [imports-offset : i64 (tlci-section-offset after-symbols imports-len 8)]
        [file-size : i64
          (tlci-section-end after-symbols imports-offset imports-len)]
        [out : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-new)]
        (tlci-push-magic! (&mut out))
        (tlci-push-u64! (&mut out) tlci-format-version)
        (tlci-push-u64! (&mut out) image.host-platform)
        (tlci-push-u64! (&mut out) image.callback-abi-version)
        (tlci-push-u64! (&mut out) hash-offset)
        (tlci-push-u64! (&mut out) (array-length compiler-hash-bytes))
        (tlci-push-u64! (&mut out) 0)
        (tlci-push-u64! (&mut out) metadata-offset)
        (tlci-push-u64! (&mut out) (array-length metadata-bytes))
        (tlci-push-u64! (&mut out) rodata-offset)
        (tlci-push-u64! (&mut out) rodata-len)
        (tlci-push-u64! (&mut out) code-offset)
        (tlci-push-u64! (&mut out) code-len)
        (tlci-push-u64! (&mut out) fixups-offset)
        (tlci-push-u64!
          (&mut out)
          (/ fixups-len tlci-section-fixup-record-size))
        (tlci-push-u64! (&mut out) entries-offset)
        (tlci-push-u64!
          (&mut out)
          (/ entries-len tlci-section-entry-record-size))
        (tlci-push-u64! (&mut out) symbols-offset)
        (tlci-push-u64!
          (&mut out)
          (/ symbols-len tlci-section-symbol-record-size))
        (tlci-push-u64! (&mut out) imports-offset)
        (tlci-push-u64! (&mut out) (tlci-import-section-count image.imports))
        (tlci-push-u64! (&mut out) file-size)
        (tlci-append-bytes! (&mut out) compiler-hash-bytes)
        (tlci-pad-to! (&mut out) metadata-offset)
        (tlci-append-bytes! (&mut out) metadata-bytes)
        (when
          (> rodata-len 0)
          (tlci-pad-to! (&mut out) rodata-offset)
          (tlci-append-bytes! (&mut out) image.rodata))
        (when
          (> code-len 0)
          (tlci-pad-to! (&mut out) code-offset)
          (tlci-append-bytes! (&mut out) image.code))
        (when
          (> fixups-len 0)
          (tlci-pad-to! (&mut out) fixups-offset)
          (tlci-append-bytes! (&mut out) image.fixups))
        (when
          (> entries-len 0)
          (tlci-pad-to! (&mut out) entries-offset)
          (tlci-append-bytes! (&mut out) image.entries))
        (when
          (> symbols-len 0)
          (tlci-pad-to! (&mut out) symbols-offset)
          (tlci-append-bytes! (&mut out) image.symbols))
        (when
          (> imports-len 0)
          (tlci-pad-to! (&mut out) imports-offset)
          (tlci-append-bytes! (&mut out) image.imports))
        (let
          [out-bytes : (__tl_dyn-array u8)
            (byte_buf_core.byte-buf-builder-finish-array (& out))]
          (tlci-set-u64!
            (&mut out-bytes)
            tlci-hash-field-offset
            (tlci-content-hash out-bytes))
          (Ok out-bytes)))]))

(define (tlci-emit-image [image : TlciImage]) : ResultTlciBytes
  (cond
    [(= image.host-platform tlci-host-platform-x86-64-legacy)
      (Err "tlci: new images must record a non-legacy host platform")]
    [(not (tlci-host-platform-supported? image.host-platform))
      (Err "tlci: unsupported host platform")]
    [else (tlci-emit-image-v2-legacy-compatible image)]))

(define (tlci-section-range-ok? [file-size : i64] [offset : i64] [len : i64]) : bool
  (if (= len 0)
    (= offset 0)
    (and
      (>= len 0)
      (>= offset tlci-header-size)
      (<= offset file-size)
      (<= len (- file-size offset)))))

(define (tlci-section-aligned? [offset : i64] [len : i64] [align : i64]) : bool
  (or (= len 0) (= (% offset align) 0)))

(define (tlci-table-len-ok? [len : i64] [record-size : i64]) : bool
  (= (% len record-size) 0))

(define (tlci-section-error [name : String]) : ResultTlciImage
  (Err (str_cat.str-cat "tlci: section `" name "` extends past end")))

(define (tlci-parse-image [bytes : (__tl_dyn-array u8)]) : ResultTlciImage
  (let
    [actual-size : i64 (array-length bytes)]
    (if (< actual-size tlci-header-size)
      (Err "tlci: truncated header")
      (if (not (tlci-magic-ok? bytes))
        (Err "tlci: bad magic")
        (let
          [version : i64 (tlci-read-u64 bytes tlci-format-version-field-offset)]
          [host-platform : i64 (tlci-read-u64 bytes 16)]
          [callback-abi : i64 (tlci-read-u64 bytes 24)]
          [hash-offset : i64 (tlci-read-u64 bytes 32)]
          [hash-len : i64 (tlci-read-u64 bytes 40)]
          [expected-hash : i64 (tlci-read-u64 bytes 48)]
          [metadata-offset : i64 (tlci-read-u64 bytes 56)]
          [metadata-len : i64 (tlci-read-u64 bytes 64)]
          [rodata-offset : i64 (tlci-read-u64 bytes 72)]
          [rodata-len : i64 (tlci-read-u64 bytes 80)]
          [code-offset : i64 (tlci-read-u64 bytes 88)]
          [code-len : i64 (tlci-read-u64 bytes 96)]
          [fixups-offset : i64 (tlci-read-u64 bytes 104)]
          [fixups-count : i64 (tlci-read-u64 bytes 112)]
          [entries-offset : i64 (tlci-read-u64 bytes 120)]
          [entries-count : i64 (tlci-read-u64 bytes 128)]
          [symbols-offset : i64 (tlci-read-u64 bytes 136)]
          [symbols-count : i64 (tlci-read-u64 bytes 144)]
          [imports-offset : i64
            (tlci-read-u64 bytes tlci-import-section-field-offset)]
          [imports-count : i64
            (tlci-read-u64 bytes tlci-import-count-field-offset)]
          [declared-size : i64
            (tlci-read-u64 bytes tlci-file-size-field-offset)]
          [fixups-len : i64 (* fixups-count tlci-section-fixup-record-size)]
          [entries-len : i64 (* entries-count tlci-section-entry-record-size)]
          [symbols-len : i64 (* symbols-count tlci-section-symbol-record-size)]
          [imports-len : i64
            (if (= imports-count 0)
              0
              (- declared-size imports-offset))]
          [hash-end : i64 (+ hash-offset hash-len)]
          [metadata-end : i64 (+ metadata-offset metadata-len)]
          [rodata-end : i64
            (tlci-section-end metadata-end rodata-offset rodata-len)]
          [code-end : i64 (tlci-section-end rodata-end code-offset code-len)]
          [fixups-end : i64
            (tlci-section-end code-end fixups-offset fixups-len)]
          [entries-end : i64
            (tlci-section-end fixups-end entries-offset entries-len)]
          [symbols-end : i64
            (tlci-section-end entries-end symbols-offset symbols-len)]
          [content-end : i64
            (tlci-section-end symbols-end imports-offset imports-len)]
          (cond
            [(not (= version tlci-format-version))
              (Err
                (str_cat.str-cat
                  "tlci: unsupported format version "
                  (string.int->string version)))]
            [(not (tlci-host-platform-supported? host-platform))
              (Err "tlci: unsupported host platform")]
            [(not (= callback-abi tlci-callback-abi-version))
              (Err "tlci: unsupported callback ABI version")]
            [(not (= declared-size actual-size))
              (Err "tlci: file size field does not match input length")]
            [(not (tlci-section-range-ok? actual-size hash-offset hash-len))
              (tlci-section-error "compiler-build-hash")]
            [(= hash-len 0) (Err "tlci: compiler build hash must not be empty")]
            [(not (= hash-offset tlci-header-size))
              (Err "tlci: compiler build hash must start after header")]
            [(not
                (tlci-section-range-ok?
                  actual-size
                  metadata-offset
                  metadata-len))
              (tlci-section-error "metadata")]
            [(= metadata-len 0)
              (Err "tlci: metadata section must not be empty")]
            [(not (tlci-section-aligned? metadata-offset metadata-len 8))
              (Err "tlci: metadata section must be 8-byte aligned")]
            [(not (tlci-section-ordered? hash-end metadata-offset metadata-len))
              (Err "tlci: metadata section overlaps previous section")]
            [(not (tlci-section-range-ok? actual-size rodata-offset rodata-len))
              (tlci-section-error "rodata")]
            [(not
                (tlci-section-aligned? rodata-offset rodata-len tlci-page-align))
              (Err "tlci: rodata section must be page-aligned")]
            [(not (tlci-section-ordered? metadata-end rodata-offset rodata-len))
              (Err "tlci: rodata section overlaps previous section")]
            [(not (tlci-section-range-ok? actual-size code-offset code-len))
              (tlci-section-error "code")]
            [(not (tlci-section-aligned? code-offset code-len tlci-page-align))
              (Err "tlci: code section must be page-aligned")]
            [(not (tlci-section-ordered? rodata-end code-offset code-len))
              (Err "tlci: code section overlaps previous section")]
            [(not (tlci-section-range-ok? actual-size fixups-offset fixups-len))
              (tlci-section-error "fixups")]
            [(not (tlci-section-aligned? fixups-offset fixups-len 8))
              (Err "tlci: fixup table must be 8-byte aligned")]
            [(not (tlci-section-ordered? code-end fixups-offset fixups-len))
              (Err "tlci: fixup table overlaps previous section")]
            [(not
                (tlci-section-range-ok? actual-size entries-offset entries-len))
              (tlci-section-error "entries")]
            [(not (tlci-section-aligned? entries-offset entries-len 8))
              (Err "tlci: entry table must be 8-byte aligned")]
            [(not (tlci-section-ordered? fixups-end entries-offset entries-len))
              (Err "tlci: entry table overlaps previous section")]
            [(not
                (tlci-section-range-ok? actual-size symbols-offset symbols-len))
              (tlci-section-error "symbols")]
            [(not (tlci-section-aligned? symbols-offset symbols-len 8))
              (Err "tlci: symbol table must be 8-byte aligned")]
            [(not
                (tlci-section-ordered? entries-end symbols-offset symbols-len))
              (Err "tlci: symbol table overlaps previous section")]
            [(not
                (tlci-table-len-ok? fixups-len tlci-section-fixup-record-size))
              (Err "tlci: malformed fixup table length")]
            [(not
                (tlci-table-len-ok? entries-len tlci-section-entry-record-size))
              (Err "tlci: malformed entry table length")]
            [(not
                (tlci-table-len-ok? symbols-len tlci-section-symbol-record-size))
              (Err "tlci: malformed symbol table length")]
            [(not
                (tlci-section-range-ok? actual-size imports-offset imports-len))
              (tlci-section-error "imports")]
            [(not (tlci-section-aligned? imports-offset imports-len 8))
              (Err "tlci: import section must be 8-byte aligned")]
            [(not
                (tlci-section-ordered? symbols-end imports-offset imports-len))
              (Err "tlci: import section overlaps previous section")]
            [(not
                (let
                  [imports : (__tl_dyn-array u8)
                    (tlci-slice-bytes bytes imports-offset imports-len)]
                  (string.eq
                    (tlci-import-section-validation-error imports imports-count)
                    "")))
              (Err
                (let
                  [imports : (__tl_dyn-array u8)
                    (tlci-slice-bytes bytes imports-offset imports-len)]
                  (str_cat.str-cat
                    "tlci: malformed import section: "
                    (tlci-import-section-validation-error imports imports-count))))]
            [(not (= declared-size content-end))
              (Err "tlci: file has trailing bytes")]
            [(not (= expected-hash (tlci-content-hash bytes)))
              (Err "tlci: content hash mismatch")]
            [else
              (let
                [metadata-text : String
                  (tlci-bytes->string bytes metadata-offset metadata-len)]
                (match (tlci-metadata-parse metadata-text)
                  [(Err message)
                    (Err (str_cat.str-cat "tlci: malformed metadata: " message))]
                  [(Ok metadata)
                    (Ok
                      (TlciImage
                        host-platform
                        callback-abi
                        (tlci-bytes->string bytes hash-offset hash-len)
                        metadata
                        (tlci-slice-bytes bytes rodata-offset rodata-len)
                        (tlci-slice-bytes bytes code-offset code-len)
                        (tlci-slice-bytes bytes fixups-offset fixups-len)
                        (tlci-slice-bytes bytes entries-offset entries-len)
                        (tlci-slice-bytes bytes symbols-offset symbols-len)
                        (tlci-slice-bytes bytes imports-offset imports-len)))]))]))))))