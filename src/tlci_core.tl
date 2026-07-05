;; tlci_core.tl - TypeLisp comptime image v1 parse/emit helpers.
;;
;; This module is deliberately dormant: it specifies and validates the tlci
;; container and metadata schema, but does not change package build behavior.
(import stdlib.byte_buf_core)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import "read.tl")

(define (tlci-string-length [text : String]) : i64
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_length text)
    (string.string-length text)))

(define (tlci-string-ref [text : String] [index : i64]) : char
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_ref text index)
    (string.string-ref text index)))

(defstruct TlciMetadata
  (version String)
  (package-name String)
  (package-version String))

(defstruct TlciImage
  (host-arch i64)
  (callback-abi-version i64)
  (compiler-build-hash String)
  (metadata TlciMetadata)
  (rodata (Array u8))
  (code (Array u8))
  (fixups (Array u8))
  (entries (Array u8))
  (symbols (Array u8)))

(defenum ResultTlciString
  (Ok String)
  (Err String))

(defenum ResultTlciMetadata
  (Ok TlciMetadata)
  (Err String))

(defenum ResultTlciImage
  (Ok TlciImage)
  (Err String))

(defenum ResultTlciBytes
  (Ok (Array u8))
  (Err String))

(defstruct TlciHostCallbackTable
  (magic i64)
  (abi-version i64)
  (byte-size i64)
  (host-context i64)
  (reserved0 i64)
  (reserved1 i64)
  (invoke-callback i64)
  (abort-callback i64))

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
  1)
(define tlci-metadata-version : String
  "v1")
(define tlci-host-arch-x86-64 : i64
  1)
(define tlci-callback-abi-version : i64
  1)
(define tlci-host-abi-version : i64
  1)
(define tlci-image-entry-symbol : String
  "tlci_image_entry")
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
(define tlci-host-callback-table-invoke-offset : i64
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
(define tlci-host-callback-status-ok : i64
  0)
(define tlci-host-callback-status-diagnostic : i64
  1)
(define tlci-host-callback-status-fuel-exhausted : i64
  2)
(define tlci-host-callback-status-panic : i64
  3)
(define tlci-host-callback-status-bad-request : i64
  4)
(define tlci-host-callback-op-fuel-check : i64
  1)
(define tlci-host-callback-op-diagnostic : i64
  2)
(define tlci-host-callback-op-scratch-alloc : i64
  3)
(define tlci-host-callback-op-scratch-reset : i64
  4)
(define tlci-host-callback-op-expr-bool : i64
  100)
(define tlci-host-callback-op-expr-int : i64
  101)
(define tlci-host-callback-op-expr-string : i64
  102)
(define tlci-host-callback-op-expr-var : i64
  103)
(define tlci-host-callback-op-expr-struct-get : i64
  104)
(define tlci-host-callback-op-expr-tuple-ref : i64
  105)
(define tlci-host-callback-op-expr-struct-set : i64
  106)
(define tlci-host-callback-op-string-eq : i64
  107)
(define tlci-host-callback-op-string-concat : i64
  108)
(define tlci-host-callback-op-string-append : i64
  109)
(define tlci-host-callback-op-string-length : i64
  110)
(define tlci-host-callback-op-string-ref : i64
  111)
(define tlci-host-callback-op-string->int : i64
  112)
(define tlci-host-callback-op-int->string : i64
  113)
(define tlci-host-callback-op-expr-splice : i64
  114)
(define tlci-host-callback-op-expr-if : i64
  115)
(define tlci-host-callback-op-pattern-wildcard : i64
  116)
(define tlci-host-callback-op-pattern-binding : i64
  117)
(define tlci-host-callback-op-pattern-variant : i64
  118)
(define tlci-host-callback-op-pattern-list-empty : i64
  119)
(define tlci-host-callback-op-pattern-list-cons : i64
  120)
(define tlci-host-callback-op-match-arm : i64
  121)
(define tlci-host-callback-op-match-arm-list-empty : i64
  122)
(define tlci-host-callback-op-match-arm-list-cons : i64
  123)
(define tlci-host-callback-op-expr-match : i64
  124)
(define tlci-host-callback-op-expr-type : i64
  125)
(define tlci-host-callback-op-type-info : i64
  126)
(define tlci-host-callback-op-module-name : i64
  127)
(define tlci-host-callback-op-module-export-macro? : i64
  128)
(define tlci-host-callback-op-module-hook : i64
  129)
(define tlci-host-callback-op-type-kind : i64
  130)
(define tlci-host-callback-op-type-key : i64
  131)
(define tlci-host-callback-op-type-nominal-module : i64
  132)
(define tlci-host-callback-op-type-nominal-name : i64
  133)
(define tlci-host-callback-op-struct-field-count : i64
  134)
(define tlci-host-callback-op-struct-field-name : i64
  135)
(define tlci-host-callback-op-struct-field-type : i64
  136)
(define tlci-host-callback-op-enum-variant-count : i64
  137)
(define tlci-host-callback-op-enum-variant-name : i64
  138)
(define tlci-host-callback-op-enum-variant-payload-count : i64
  139)
(define tlci-host-callback-op-enum-variant-payload-type : i64
  140)
(define tlci-host-callback-op-array-element-type : i64
  141)
(define tlci-host-callback-op-array-length : i64
  142)
(define tlci-host-callback-op-array-dynamic? : i64
  143)
(define tlci-host-callback-op-tuple-element-count : i64
  144)
(define tlci-host-callback-op-tuple-element-type : i64
  145)
(define tlci-host-callback-op-function-param-count : i64
  146)
(define tlci-host-callback-op-function-param-type : i64
  147)
(define tlci-host-callback-op-function-return-type : i64
  148)
(define tlci-host-callback-op-expr-bool? : i64
  149)
(define tlci-host-callback-op-expr-bool-value : i64
  150)
(define tlci-host-callback-op-expr-if? : i64
  151)
(define tlci-host-callback-op-expr-if-cond : i64
  152)
(define tlci-host-callback-op-expr-if-then : i64
  153)
(define tlci-host-callback-op-expr-if-else : i64
  154)
(define tlci-host-callback-op-expr-list-length : i64
  155)
(define tlci-host-callback-op-expr-list-nth : i64
  156)
(define tlci-host-callback-op-expr-clause-first : i64
  157)
(define tlci-host-callback-op-expr-clause-second : i64
  158)
(define tlci-host-callback-op-expr-clause-list-length : i64
  159)
(define tlci-host-callback-op-expr-clause-list-nth : i64
  160)
(define tlci-host-callback-op-expr-clause-list->expr-list : i64
  161)
(define tlci-host-callback-op-expr-binding-clause-name : i64
  162)
(define tlci-host-callback-op-expr-binding-clause-has-type? : i64
  163)
(define tlci-host-callback-op-expr-binding-clause-type : i64
  164)
(define tlci-host-callback-op-expr-binding-clause-init : i64
  165)
(define tlci-host-callback-op-expr-binding-clause-list-length : i64
  166)
(define tlci-host-callback-op-expr-binding-clause-list-nth : i64
  167)
(define tlci-host-callback-op-expr-binding-clause-list->expr-list : i64
  168)
(define tlci-host-callback-stdlib-op-count : i64
  69)
(define tlci-header-size : i64
  160)
(define tlci-page-align : i64
  4096)
(define tlci-hash-field-offset : i64
  48)
(define tlci-hash-field-size : i64
  8)
(define tlci-section-fixup-record-size : i64
  8)
(define tlci-section-entry-record-size : i64
  24)
(define tlci-section-symbol-record-size : i64
  40)

(define (tlci-host-abi-version-error [actual : i64]) : String
  (str_cat.str-cat
    "tlci host ABI: unsupported callback ABI version "
    (string.int->string actual)))

(define (tlci-validate-host-callback-table [table : TlciHostCallbackTable]) : ResultTlciHostAbi
  (cond
    [(not (= (struct-get table magic) tlci-host-callback-table-magic))
      (ResultTlciHostAbi.Err "tlci host ABI: bad host callback table magic")]
    [(not (= (struct-get table abi-version) tlci-host-abi-version))
      (ResultTlciHostAbi.Err
        (tlci-host-abi-version-error (struct-get table abi-version)))]
    [(< (struct-get table byte-size) tlci-host-callback-table-size)
      (ResultTlciHostAbi.Err
        "tlci host ABI: host callback table byte-size is smaller than v1")]
    [(not (= (struct-get table reserved0) 0))
      (ResultTlciHostAbi.Err
        "tlci host ABI: host callback table reserved0 must be zero")]
    [(not (= (struct-get table reserved1) 0))
      (ResultTlciHostAbi.Err
        "tlci host ABI: host callback table reserved1 must be zero")]
    [(= (struct-get table invoke-callback) 0)
      (ResultTlciHostAbi.Err
        "tlci host ABI: host invoke callback must be nonzero")]
    [(= (struct-get table abort-callback) 0)
      (ResultTlciHostAbi.Err
        "tlci host ABI: host abort callback must be nonzero")]
    [else (ResultTlciHostAbi.Ok)]))

(define (tlci-validate-image-registration
  [registration : TlciImageRegistration]) : ResultTlciHostAbi
  (cond
    [(not (= (struct-get registration magic) tlci-image-registration-magic))
      (ResultTlciHostAbi.Err "tlci host ABI: bad image registration magic")]
    [(not (= (struct-get registration abi-version) tlci-host-abi-version))
      (ResultTlciHostAbi.Err
        (tlci-host-abi-version-error (struct-get registration abi-version)))]
    [(< (struct-get registration byte-size) tlci-image-registration-size)
      (ResultTlciHostAbi.Err
        "tlci host ABI: image registration byte-size is smaller than v1")]
    [(not (= (struct-get registration reserved0) 0))
      (ResultTlciHostAbi.Err
        "tlci host ABI: image registration reserved0 must be zero")]
    [(not (= (struct-get registration reserved1) 0))
      (ResultTlciHostAbi.Err
        "tlci host ABI: image registration reserved1 must be zero")]
    [(and
        (= (struct-get registration macro-entry-table) 0)
        (not (= (struct-get registration macro-entry-count) 0)))
      (ResultTlciHostAbi.Err
        "tlci host ABI: macro entry count requires a table")]
    [(and
        (not (= (struct-get registration macro-entry-table) 0))
        (= (struct-get registration macro-entry-count) 0))
      (ResultTlciHostAbi.Err
        "tlci host ABI: macro entry table requires a count")]
    [else (ResultTlciHostAbi.Ok)]))

(define (tlci-empty-bytes) : (Array u8)
  (make-array u8 0))

(define (tlci-byte [value : i64]) : u8
  (cast (bit-and value 0xff) : u8))

(define (tlci-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (tlci-byte value)))

(define (tlci-push-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (tlci-push-u8! out value)
    (tlci-push-u8! out (shr value 8))
    (tlci-push-u8! out (shr value 16))
    (tlci-push-u8! out (shr value 24))
    (tlci-push-u8! out (shr value 32))
    (tlci-push-u8! out (shr value 40))
    (tlci-push-u8! out (shr value 48))
    (tlci-push-u8! out (shr value 56))))

(define (tlci-set-u64! [out : (Array u8)] [offset : i64] [value : i64]) : unit
  (begin
    (array-set! out offset (tlci-byte value))
    (array-set! out (+ offset 1) (tlci-byte (shr value 8)))
    (array-set! out (+ offset 2) (tlci-byte (shr value 16)))
    (array-set! out (+ offset 3) (tlci-byte (shr value 24)))
    (array-set! out (+ offset 4) (tlci-byte (shr value 32)))
    (array-set! out (+ offset 5) (tlci-byte (shr value 40)))
    (array-set! out (+ offset 6) (tlci-byte (shr value 48)))
    (array-set! out (+ offset 7) (tlci-byte (shr value 56)))))

(define (tlci-byte-at [bytes : (Array u8)] [offset : i64]) : i64
  (cast (array-ref bytes offset) : i64))

(define (tlci-read-u64 [bytes : (Array u8)] [offset : i64]) : i64
  (+
    (tlci-byte-at bytes offset)
    (+
      (shl (tlci-byte-at bytes (+ offset 1)) 8)
      (+
        (shl (tlci-byte-at bytes (+ offset 2)) 16)
        (+
          (shl (tlci-byte-at bytes (+ offset 3)) 24)
          (+
            (shl (tlci-byte-at bytes (+ offset 4)) 32)
            (+
              (shl (tlci-byte-at bytes (+ offset 5)) 40)
              (+
                (shl (tlci-byte-at bytes (+ offset 6)) 48)
                (shl (tlci-byte-at bytes (+ offset 7)) 56)))))))))

(define (tlci-push-zeroes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (tlci-push-u8! out 0)
          (set! i (+ i 1))))
      unit)))

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
  (tlci-push-zeroes! out (- offset (struct-get out len))))

(define (tlci-push-magic! [out : (&mut out byte_buf_core.ByteBufBuilder)]) : unit
  (begin
    (tlci-push-u8! out 84)
    (tlci-push-u8! out 76)
    (tlci-push-u8! out 67)
    (tlci-push-u8! out 73)
    (tlci-push-u8! out 13)
    (tlci-push-u8! out 10)
    (tlci-push-u8! out 26)
    (tlci-push-u8! out 10)))

(define (tlci-magic-ok? [bytes : (Array u8)]) : bool
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
  [text : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (tlci-string-length text)]
    (begin
      (while (< i n)
        (begin
          (byte_buf_core.byte-buf-builder-push
            out
            (cast (tlci-string-ref text i) : u8))
          (set! i (+ i 1))))
      unit)))

(define (tlci-string->bytes [text : String]) : (Array u8)
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (begin
      (tlci-push-string-bytes! (&mut out) text)
      (byte_buf_core.byte-buf-builder-finish-array (& out)))))

(define (tlci-bytes->string [bytes : (Array u8)] [offset : i64] [len : i64]) : String
  (let
    [out : (Array u8) (make-array u8 len)]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (array-set! out i (array-ref bytes (+ offset i)))
          (set! i (+ i 1))))
      (unsafe
        (string-from-bytes (ptr-cast (array-data out) : (Ptr u8)) len)))))

(define (tlci-slice-bytes [bytes : (Array u8)] [offset : i64] [len : i64]) : (Array
    u8)
  (let
    [out : (Array u8) (make-array u8 len)]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (array-set! out i (array-ref bytes (+ offset i)))
          (set! i (+ i 1))))
      out)))

(define (tlci-copy-bytes [bytes : (Array u8)]) : (Array u8)
  (tlci-slice-bytes bytes 0 (array-length bytes)))

(define (tlci-append-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [bytes : (Array u8)]) : unit
  (byte_buf_core.byte-buf-builder-append-array out (& bytes)))

(define (tlci-bytes-eq? [left : (Array u8)] [right : (Array u8)]) : bool
  (let
    [n : i64 (array-length left)]
    [i : i64 0]
    [ok : bool (= n (array-length right))]
    (begin
      (while (and ok (< i n))
        (if (= (tlci-byte-at left i) (tlci-byte-at right i))
          (set! i (+ i 1))
          (set! ok false)))
      ok)))

(define (tlci-content-hash [bytes : (Array u8)]) : i64
  (let
    [n : i64 (array-length bytes)]
    [i : i64 0]
    [hash : i64 1]
    (begin
      (while (< i n)
        (let
          [b : i64
            (if (and
              (>= i tlci-hash-field-offset)
              (< i (+ tlci-hash-field-offset tlci-hash-field-size)))
              0
              (tlci-byte-at bytes i))]
          (begin
            (set! hash (% (+ (* hash 131) b) 2147483647))
            (set! i (+ i 1)))))
      hash)))

(define (tlci-char-code-at [text : String] [idx : i64]) : i64
  (cast (tlci-string-ref text idx) : i64))

(define (tlci-field-string-value [ftail : Sexpr] [fname : String]) : ResultTlciString
  (match ftail
    [(Sexpr.Cons vhead vrest)
      (match (box-get vhead)
        [(Sexpr.Str val)
          (match (box-get vrest)
            [(Sexpr.Nil) (ResultTlciString.Ok val)]
            [_
              (ResultTlciString.Err
                (str_cat.str-cat
                  "tlci metadata: field `"
                  fname
                  "` takes one string value"))])]
        [_
          (ResultTlciString.Err
            (str_cat.str-cat
              "tlci metadata: field `"
              fname
              "` must be a string"))])]
    [_
      (ResultTlciString.Err
        (str_cat.str-cat "tlci metadata: field `" fname "` must be a string"))]))

(define (tlci-package-fields
  [fields : Sexpr]
  [name : String]
  [has-name : bool]
  [version : String]
  [has-version : bool]) : ResultTlciMetadata
  (match fields
    [(Sexpr.Nil)
      (cond
        [(not has-name)
          (ResultTlciMetadata.Err
            "tlci metadata: package missing required field `name`")]
        [(not has-version)
          (ResultTlciMetadata.Err
            "tlci metadata: package missing required field `version`")]
        [(string.eq name "")
          (ResultTlciMetadata.Err
            "tlci metadata: package name must not be empty")]
        [(string.eq version "")
          (ResultTlciMetadata.Err
            "tlci metadata: package version must not be empty")]
        [else
          (ResultTlciMetadata.Ok
            (TlciMetadata tlci-metadata-version name version))])]
    [(Sexpr.Cons field rest)
      (match (box-get field)
        [(Sexpr.Cons fhead ftail)
          (match (box-get fhead)
            [(Sexpr.Sym fname)
              (if (string.eq fname "name")
                (if has-name
                  (ResultTlciMetadata.Err
                    "tlci metadata: duplicate package field `name`")
                  (match (tlci-field-string-value (box-get ftail) fname)
                    [(ResultTlciString.Err message)
                      (ResultTlciMetadata.Err message)]
                    [(ResultTlciString.Ok value)
                      (tlci-package-fields
                        (box-get rest)
                        value
                        true
                        version
                        has-version)]))
                (if (string.eq fname "version")
                  (if has-version
                    (ResultTlciMetadata.Err
                      "tlci metadata: duplicate package field `version`")
                    (match (tlci-field-string-value (box-get ftail) fname)
                      [(ResultTlciString.Err message)
                        (ResultTlciMetadata.Err message)]
                      [(ResultTlciString.Ok value)
                        (tlci-package-fields
                          (box-get rest)
                          name
                          has-name
                          value
                          true)]))
                  (ResultTlciMetadata.Err
                    (str_cat.str-cat
                      "tlci metadata: unknown package field `"
                      fname
                      "`"))))]
            [_
              (ResultTlciMetadata.Err
                "tlci metadata: package fields must start with a name")])]
        [_
          (ResultTlciMetadata.Err "tlci metadata: package fields must be lists")])]
    [_ (ResultTlciMetadata.Err "tlci metadata: package fields must be lists")]))

(define (tlci-package-from-field [ftail : Sexpr]) : ResultTlciMetadata
  (tlci-package-fields ftail "" false "" false))

(define (tlci-metadata-fields
  [fields : Sexpr]
  [version : String]
  [has-version : bool]
  [package-name : String]
  [package-version : String]
  [has-package : bool]) : ResultTlciMetadata
  (match fields
    [(Sexpr.Nil)
      (cond
        [(not has-version)
          (ResultTlciMetadata.Err
            "tlci metadata: missing required field `version`")]
        [(not (string.eq version tlci-metadata-version))
          (ResultTlciMetadata.Err
            (str_cat.str-cat "tlci metadata: unsupported version `" version "`"))]
        [(not has-package)
          (ResultTlciMetadata.Err
            "tlci metadata: missing required field `package`")]
        [else
          (ResultTlciMetadata.Ok
            (TlciMetadata version package-name package-version))])]
    [(Sexpr.Cons field rest)
      (match (box-get field)
        [(Sexpr.Cons fhead ftail)
          (match (box-get fhead)
            [(Sexpr.Sym fname)
              (cond
                [(string.eq fname "version")
                  (if has-version
                    (ResultTlciMetadata.Err
                      "tlci metadata: duplicate field `version`")
                    (match (tlci-field-string-value (box-get ftail) fname)
                      [(ResultTlciString.Err message)
                        (ResultTlciMetadata.Err message)]
                      [(ResultTlciString.Ok value)
                        (tlci-metadata-fields
                          (box-get rest)
                          value
                          true
                          package-name
                          package-version
                          has-package)]))]
                [(string.eq fname "package")
                  (if has-package
                    (ResultTlciMetadata.Err
                      "tlci metadata: duplicate field `package`")
                    (match (tlci-package-from-field (box-get ftail))
                      [(ResultTlciMetadata.Err message)
                        (ResultTlciMetadata.Err message)]
                      [(ResultTlciMetadata.Ok parsed)
                        (tlci-metadata-fields
                          (box-get rest)
                          version
                          has-version
                          (struct-get parsed package-name)
                          (struct-get parsed package-version)
                          true)]))]
                [else
                  (ResultTlciMetadata.Err
                    (str_cat.str-cat "tlci metadata: unknown field `" fname "`"))])]
            [_
              (ResultTlciMetadata.Err
                "tlci metadata: fields must start with a field name")])]
        [_ (ResultTlciMetadata.Err "tlci metadata: fields must be lists")])]
    [_ (ResultTlciMetadata.Err "tlci metadata: fields must be lists")]))

(define (tlci-metadata-from-form [form : Sexpr]) : ResultTlciMetadata
  (match form
    [(Sexpr.Cons head rest)
      (match (box-get head)
        [(Sexpr.Sym name)
          (if (string.eq name "typelisp-tlci-metadata")
            (tlci-metadata-fields (box-get rest) "" false "" "" false)
            (ResultTlciMetadata.Err
              (str_cat.str-cat
                "expected `typelisp-tlci-metadata` form, got `"
                name
                "`")))]
        [_
          (ResultTlciMetadata.Err
            "tlci metadata: form must start with `typelisp-tlci-metadata`")])]
    [_
      (ResultTlciMetadata.Err
        "tlci metadata: expected `(typelisp-tlci-metadata ...)`")]))

(define (tlci-metadata-parse [source : String]) : ResultTlciMetadata
  (match (read-result (lex source))
    [(ResultSexpr.Err message)
      (ResultTlciMetadata.Err (string.append "tlci metadata: " message))]
    [(ResultSexpr.Ok form) (tlci-metadata-from-form form)]))

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
    (begin
      (while (< i n)
        (begin
          (let
            [code : i64 (tlci-char-code-at text i)]
            (cond
              [(= code 34) (set! out (str_cat.str-cat out slash quote))]
              [(= code 92) (set! out (str_cat.str-cat out slash slash))]
              [(= code 10) (set! out (str_cat.str-cat out slash "n"))]
              [(= code 9) (set! out (str_cat.str-cat out slash "t"))]
              [(= code 13) (set! out (str_cat.str-cat out slash "r"))]
              [else
                (set! out (str_cat.str-cat out (string.substring text i 1)))]))
          (set! i (+ i 1))))
      out)))

(define (tlci-quote-string [text : String]) : String
  (str_cat.str-cat
    (tlci-quote-text)
    (tlci-escape-string text)
    (tlci-quote-text)))

(define (tlci-metadata-emit [metadata : TlciMetadata]) : String
  (str_cat.str-cat
    "(typelisp-tlci-metadata\n"
    "  (version "
    (tlci-quote-string (struct-get metadata version))
    ")\n"
    "  (package (name "
    (tlci-quote-string (struct-get metadata package-name))
    ") (version "
    (tlci-quote-string (struct-get metadata package-version))
    ")))\n"))

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

(define (tlci-emit-image [image : TlciImage]) : ResultTlciBytes
  (cond
    [(string.eq (struct-get image compiler-build-hash) "")
      (ResultTlciBytes.Err "tlci: compiler build hash must not be empty")]
    [(not
        (=
          (%
            (array-length (struct-get image fixups))
            tlci-section-fixup-record-size)
          0))
      (ResultTlciBytes.Err "tlci: malformed fixup table length")]
    [(not
        (=
          (%
            (array-length (struct-get image entries))
            tlci-section-entry-record-size)
          0))
      (ResultTlciBytes.Err "tlci: malformed entry table length")]
    [(not
        (=
          (%
            (array-length (struct-get image symbols))
            tlci-section-symbol-record-size)
          0))
      (ResultTlciBytes.Err "tlci: malformed symbol table length")]
    [else
      (let
        [compiler-hash-bytes : (Array u8)
          (tlci-string->bytes (struct-get image compiler-build-hash))]
        [metadata-text : String
          (tlci-metadata-emit (struct-get image metadata))]
        [metadata-bytes : (Array u8) (tlci-string->bytes metadata-text)]
        [hash-offset : i64 tlci-header-size]
        [metadata-offset : i64
          (tlci-align-offset
            (+ hash-offset (array-length compiler-hash-bytes))
            8)]
        [after-metadata : i64 (+ metadata-offset (array-length metadata-bytes))]
        [rodata-len : i64 (array-length (struct-get image rodata))]
        [code-len : i64 (array-length (struct-get image code))]
        [fixups-len : i64 (array-length (struct-get image fixups))]
        [entries-len : i64 (array-length (struct-get image entries))]
        [symbols-len : i64 (array-length (struct-get image symbols))]
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
        [file-size : i64
          (tlci-section-end after-entries symbols-offset symbols-len)]
        [out : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-new)]
        (begin
          (tlci-push-magic! (&mut out))
          (tlci-push-u64! (&mut out) tlci-format-version)
          (tlci-push-u64! (&mut out) (struct-get image host-arch))
          (tlci-push-u64! (&mut out) (struct-get image callback-abi-version))
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
          (tlci-push-u64! (&mut out) file-size)
          (tlci-append-bytes! (&mut out) compiler-hash-bytes)
          (tlci-pad-to! (&mut out) metadata-offset)
          (tlci-append-bytes! (&mut out) metadata-bytes)
          (if (> rodata-len 0)
            (begin
              (tlci-pad-to! (&mut out) rodata-offset)
              (tlci-append-bytes! (&mut out) (struct-get image rodata)))
            unit)
          (if (> code-len 0)
            (begin
              (tlci-pad-to! (&mut out) code-offset)
              (tlci-append-bytes! (&mut out) (struct-get image code)))
            unit)
          (if (> fixups-len 0)
            (begin
              (tlci-pad-to! (&mut out) fixups-offset)
              (tlci-append-bytes! (&mut out) (struct-get image fixups)))
            unit)
          (if (> entries-len 0)
            (begin
              (tlci-pad-to! (&mut out) entries-offset)
              (tlci-append-bytes! (&mut out) (struct-get image entries)))
            unit)
          (if (> symbols-len 0)
            (begin
              (tlci-pad-to! (&mut out) symbols-offset)
              (tlci-append-bytes! (&mut out) (struct-get image symbols)))
            unit)
          (let
            [out-bytes : (Array u8)
              (byte_buf_core.byte-buf-builder-finish-array (& out))]
            (begin
              (tlci-set-u64!
                out-bytes
                tlci-hash-field-offset
                (tlci-content-hash out-bytes))
              (ResultTlciBytes.Ok out-bytes)))))]))

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
  (ResultTlciImage.Err
    (str_cat.str-cat "tlci: section `" name "` extends past end")))

(define (tlci-parse-image [bytes : (Array u8)]) : ResultTlciImage
  (let
    [actual-size : i64 (array-length bytes)]
    (if (< actual-size tlci-header-size)
      (ResultTlciImage.Err "tlci: truncated header")
      (if (not (tlci-magic-ok? bytes))
        (ResultTlciImage.Err "tlci: bad magic")
        (let
          [version : i64 (tlci-read-u64 bytes 8)]
          [host-arch : i64 (tlci-read-u64 bytes 16)]
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
          [declared-size : i64 (tlci-read-u64 bytes 152)]
          [fixups-len : i64 (* fixups-count tlci-section-fixup-record-size)]
          [entries-len : i64 (* entries-count tlci-section-entry-record-size)]
          [symbols-len : i64 (* symbols-count tlci-section-symbol-record-size)]
          [hash-end : i64 (+ hash-offset hash-len)]
          [metadata-end : i64 (+ metadata-offset metadata-len)]
          [rodata-end : i64
            (tlci-section-end metadata-end rodata-offset rodata-len)]
          [code-end : i64 (tlci-section-end rodata-end code-offset code-len)]
          [fixups-end : i64
            (tlci-section-end code-end fixups-offset fixups-len)]
          [entries-end : i64
            (tlci-section-end fixups-end entries-offset entries-len)]
          [content-end : i64
            (tlci-section-end entries-end symbols-offset symbols-len)]
          (cond
            [(not (= version tlci-format-version))
              (ResultTlciImage.Err
                (str_cat.str-cat
                  "tlci: unsupported format version "
                  (string.int->string version)))]
            [(not (= host-arch tlci-host-arch-x86-64))
              (ResultTlciImage.Err "tlci: unsupported host arch")]
            [(not (= callback-abi tlci-callback-abi-version))
              (ResultTlciImage.Err "tlci: unsupported callback ABI version")]
            [(not (= declared-size actual-size))
              (ResultTlciImage.Err
                "tlci: file size field does not match input length")]
            [(not (tlci-section-range-ok? actual-size hash-offset hash-len))
              (tlci-section-error "compiler-build-hash")]
            [(= hash-len 0)
              (ResultTlciImage.Err
                "tlci: compiler build hash must not be empty")]
            [(not (= hash-offset tlci-header-size))
              (ResultTlciImage.Err
                "tlci: compiler build hash must start after header")]
            [(not
                (tlci-section-range-ok?
                  actual-size
                  metadata-offset
                  metadata-len))
              (tlci-section-error "metadata")]
            [(= metadata-len 0)
              (ResultTlciImage.Err "tlci: metadata section must not be empty")]
            [(not (tlci-section-aligned? metadata-offset metadata-len 8))
              (ResultTlciImage.Err
                "tlci: metadata section must be 8-byte aligned")]
            [(not (tlci-section-ordered? hash-end metadata-offset metadata-len))
              (ResultTlciImage.Err
                "tlci: metadata section overlaps previous section")]
            [(not (tlci-section-range-ok? actual-size rodata-offset rodata-len))
              (tlci-section-error "rodata")]
            [(not
                (tlci-section-aligned? rodata-offset rodata-len tlci-page-align))
              (ResultTlciImage.Err "tlci: rodata section must be page-aligned")]
            [(not (tlci-section-ordered? metadata-end rodata-offset rodata-len))
              (ResultTlciImage.Err
                "tlci: rodata section overlaps previous section")]
            [(not (tlci-section-range-ok? actual-size code-offset code-len))
              (tlci-section-error "code")]
            [(not (tlci-section-aligned? code-offset code-len tlci-page-align))
              (ResultTlciImage.Err "tlci: code section must be page-aligned")]
            [(not (tlci-section-ordered? rodata-end code-offset code-len))
              (ResultTlciImage.Err
                "tlci: code section overlaps previous section")]
            [(not (tlci-section-range-ok? actual-size fixups-offset fixups-len))
              (tlci-section-error "fixups")]
            [(not (tlci-section-aligned? fixups-offset fixups-len 8))
              (ResultTlciImage.Err "tlci: fixup table must be 8-byte aligned")]
            [(not (tlci-section-ordered? code-end fixups-offset fixups-len))
              (ResultTlciImage.Err
                "tlci: fixup table overlaps previous section")]
            [(not
                (tlci-section-range-ok? actual-size entries-offset entries-len))
              (tlci-section-error "entries")]
            [(not (tlci-section-aligned? entries-offset entries-len 8))
              (ResultTlciImage.Err "tlci: entry table must be 8-byte aligned")]
            [(not (tlci-section-ordered? fixups-end entries-offset entries-len))
              (ResultTlciImage.Err
                "tlci: entry table overlaps previous section")]
            [(not
                (tlci-section-range-ok? actual-size symbols-offset symbols-len))
              (tlci-section-error "symbols")]
            [(not (tlci-section-aligned? symbols-offset symbols-len 8))
              (ResultTlciImage.Err "tlci: symbol table must be 8-byte aligned")]
            [(not
                (tlci-section-ordered? entries-end symbols-offset symbols-len))
              (ResultTlciImage.Err
                "tlci: symbol table overlaps previous section")]
            [(not
                (tlci-table-len-ok? fixups-len tlci-section-fixup-record-size))
              (ResultTlciImage.Err "tlci: malformed fixup table length")]
            [(not
                (tlci-table-len-ok? entries-len tlci-section-entry-record-size))
              (ResultTlciImage.Err "tlci: malformed entry table length")]
            [(not
                (tlci-table-len-ok? symbols-len tlci-section-symbol-record-size))
              (ResultTlciImage.Err "tlci: malformed symbol table length")]
            [(not (= declared-size content-end))
              (ResultTlciImage.Err "tlci: file has trailing bytes")]
            [(not (= expected-hash (tlci-content-hash bytes)))
              (ResultTlciImage.Err "tlci: content hash mismatch")]
            [else
              (let
                [metadata-text : String
                  (tlci-bytes->string bytes metadata-offset metadata-len)]
                (match (tlci-metadata-parse metadata-text)
                  [(ResultTlciMetadata.Err message)
                    (ResultTlciImage.Err
                      (str_cat.str-cat "tlci: malformed metadata: " message))]
                  [(ResultTlciMetadata.Ok metadata)
                    (ResultTlciImage.Ok
                      (TlciImage
                        host-arch
                        callback-abi
                        (tlci-bytes->string bytes hash-offset hash-len)
                        metadata
                        (tlci-slice-bytes bytes rodata-offset rodata-len)
                        (tlci-slice-bytes bytes code-offset code-len)
                        (tlci-slice-bytes bytes fixups-offset fixups-len)
                        (tlci-slice-bytes bytes entries-offset entries-len)
                        (tlci-slice-bytes bytes symbols-offset symbols-len)))]))]))))))

(define (tlci-test-metadata) : TlciMetadata
  (TlciMetadata "v1" "demo" "0.1.0"))

(define (tlci-test-bytes3 [a : i64] [b : i64] [c : i64]) : (Array u8)
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (begin
      (tlci-push-u8! (&mut out) a)
      (tlci-push-u8! (&mut out) b)
      (tlci-push-u8! (&mut out) c)
      (byte_buf_core.byte-buf-builder-finish-array (& out)))))

(define (tlci-test-zero-records [record-size : i64] [count : i64]) : (Array u8)
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (begin
      (tlci-push-zeroes! (&mut out) (* record-size count))
      (byte_buf_core.byte-buf-builder-finish-array (& out)))))

(define (tlci-test-metadata-only-image) : TlciImage
  (TlciImage
    tlci-host-arch-x86-64
    tlci-callback-abi-version
    "abcdef0"
    (tlci-test-metadata)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)))

(define (tlci-test-code-image) : TlciImage
  (TlciImage
    tlci-host-arch-x86-64
    tlci-callback-abi-version
    "abcdef0"
    (tlci-test-metadata)
    (tlci-test-bytes3 1 2 3)
    (tlci-test-bytes3 195 144 144)
    (tlci-test-zero-records tlci-section-fixup-record-size 1)
    (tlci-test-zero-records tlci-section-entry-record-size 1)
    (tlci-test-zero-records tlci-section-symbol-record-size 1)))

(define (tlci-test-malformed-fixups-image) : TlciImage
  (TlciImage
    tlci-host-arch-x86-64
    tlci-callback-abi-version
    "abcdef0"
    (tlci-test-metadata)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-test-bytes3 1 2 3)
    (tlci-empty-bytes)
    (tlci-empty-bytes)))

(define (tlci-test-host-callback-table) : TlciHostCallbackTable
  (TlciHostCallbackTable
    tlci-host-callback-table-magic
    tlci-host-abi-version
    tlci-host-callback-table-size
    1234
    0
    0
    4096
    8192))

(define (tlci-test-image-registration) : TlciImageRegistration
  (TlciImageRegistration
    tlci-image-registration-magic
    tlci-host-abi-version
    tlci-image-registration-size
    5678
    0
    0
    12288
    1))

(define (tlci-test-host-abi-rejects?
  [result : ResultTlciHostAbi]
  [expected : String]) : bool
  (match result
    [(ResultTlciHostAbi.Err message) (string.eq message expected)]
    [(ResultTlciHostAbi.Ok) false]))

(define (tlci-test-host-abi-layout-ok?) : bool
  (and
    (= tlci-host-abi-version tlci-callback-abi-version)
    (string.eq tlci-image-entry-symbol "tlci_image_entry")
    (= tlci-image-entry-param-count 2)
    (= tlci-image-entry-success 0)
    (= tlci-host-callback-table-header-size 48)
    (= tlci-host-callback-table-size 64)
    (= tlci-image-registration-header-size 48)
    (= tlci-image-registration-size 64)
    (= tlci-host-callback-table-magic-offset 0)
    (= tlci-host-callback-table-abi-version-offset 8)
    (= tlci-host-callback-table-byte-size-offset 16)
    (= tlci-host-callback-table-host-context-offset 24)
    (= tlci-host-callback-table-reserved0-offset 32)
    (= tlci-host-callback-table-reserved1-offset 40)
    (= tlci-host-callback-table-invoke-offset 48)
    (= tlci-host-callback-table-abort-offset 56)
    (= tlci-image-registration-magic-offset 0)
    (= tlci-image-registration-abi-version-offset 8)
    (= tlci-image-registration-byte-size-offset 16)
    (= tlci-image-registration-image-context-offset 24)
    (= tlci-image-registration-reserved0-offset 32)
    (= tlci-image-registration-reserved1-offset 40)
    (= tlci-image-registration-macro-entry-table-offset 48)
    (= tlci-image-registration-macro-entry-count-offset 56)
    (= tlci-macro-entry-record-size 32)
    (= tlci-macro-entry-name-ptr-offset 0)
    (= tlci-macro-entry-name-len-offset 8)
    (= tlci-macro-entry-function-offset 16)
    (= tlci-macro-entry-reserved0-offset 24)))

(define (tlci-test-host-callback-op-layout-ok?) : bool
  (and
    (= tlci-host-callback-status-ok 0)
    (= tlci-host-callback-status-diagnostic 1)
    (= tlci-host-callback-status-fuel-exhausted 2)
    (= tlci-host-callback-status-panic 3)
    (= tlci-host-callback-status-bad-request 4)
    (= tlci-host-callback-op-fuel-check 1)
    (= tlci-host-callback-op-diagnostic 2)
    (= tlci-host-callback-op-scratch-alloc 3)
    (= tlci-host-callback-op-scratch-reset 4)
    (= tlci-host-callback-op-expr-bool 100)
    (= tlci-host-callback-op-expr-int 101)
    (= tlci-host-callback-op-expr-string 102)
    (= tlci-host-callback-op-expr-var 103)
    (= tlci-host-callback-op-expr-struct-get 104)
    (= tlci-host-callback-op-expr-tuple-ref 105)
    (= tlci-host-callback-op-expr-struct-set 106)
    (= tlci-host-callback-op-string-eq 107)
    (= tlci-host-callback-op-string-concat 108)
    (= tlci-host-callback-op-string-append 109)
    (= tlci-host-callback-op-string-length 110)
    (= tlci-host-callback-op-string-ref 111)
    (= tlci-host-callback-op-string->int 112)
    (= tlci-host-callback-op-int->string 113)
    (= tlci-host-callback-op-expr-splice 114)
    (= tlci-host-callback-op-expr-if 115)
    (= tlci-host-callback-op-pattern-wildcard 116)
    (= tlci-host-callback-op-pattern-binding 117)
    (= tlci-host-callback-op-pattern-variant 118)
    (= tlci-host-callback-op-pattern-list-empty 119)
    (= tlci-host-callback-op-pattern-list-cons 120)
    (= tlci-host-callback-op-match-arm 121)
    (= tlci-host-callback-op-match-arm-list-empty 122)
    (= tlci-host-callback-op-match-arm-list-cons 123)
    (= tlci-host-callback-op-expr-match 124)
    (= tlci-host-callback-op-expr-type 125)
    (= tlci-host-callback-op-type-info 126)
    (= tlci-host-callback-op-module-name 127)
    (= tlci-host-callback-op-module-export-macro? 128)
    (= tlci-host-callback-op-module-hook 129)
    (= tlci-host-callback-op-type-kind 130)
    (= tlci-host-callback-op-type-key 131)
    (= tlci-host-callback-op-type-nominal-module 132)
    (= tlci-host-callback-op-type-nominal-name 133)
    (= tlci-host-callback-op-struct-field-count 134)
    (= tlci-host-callback-op-struct-field-name 135)
    (= tlci-host-callback-op-struct-field-type 136)
    (= tlci-host-callback-op-enum-variant-count 137)
    (= tlci-host-callback-op-enum-variant-name 138)
    (= tlci-host-callback-op-enum-variant-payload-count 139)
    (= tlci-host-callback-op-enum-variant-payload-type 140)
    (= tlci-host-callback-op-array-element-type 141)
    (= tlci-host-callback-op-array-length 142)
    (= tlci-host-callback-op-array-dynamic? 143)
    (= tlci-host-callback-op-tuple-element-count 144)
    (= tlci-host-callback-op-tuple-element-type 145)
    (= tlci-host-callback-op-function-param-count 146)
    (= tlci-host-callback-op-function-param-type 147)
    (= tlci-host-callback-op-function-return-type 148)
    (= tlci-host-callback-op-expr-bool? 149)
    (= tlci-host-callback-op-expr-bool-value 150)
    (= tlci-host-callback-op-expr-if? 151)
    (= tlci-host-callback-op-expr-if-cond 152)
    (= tlci-host-callback-op-expr-if-then 153)
    (= tlci-host-callback-op-expr-if-else 154)
    (= tlci-host-callback-op-expr-list-length 155)
    (= tlci-host-callback-op-expr-list-nth 156)
    (= tlci-host-callback-op-expr-clause-first 157)
    (= tlci-host-callback-op-expr-clause-second 158)
    (= tlci-host-callback-op-expr-clause-list-length 159)
    (= tlci-host-callback-op-expr-clause-list-nth 160)
    (= tlci-host-callback-op-expr-clause-list->expr-list 161)
    (= tlci-host-callback-op-expr-binding-clause-name 162)
    (= tlci-host-callback-op-expr-binding-clause-has-type? 163)
    (= tlci-host-callback-op-expr-binding-clause-type 164)
    (= tlci-host-callback-op-expr-binding-clause-init 165)
    (= tlci-host-callback-op-expr-binding-clause-list-length 166)
    (= tlci-host-callback-op-expr-binding-clause-list-nth 167)
    (= tlci-host-callback-op-expr-binding-clause-list->expr-list 168)
    (= tlci-host-callback-stdlib-op-count 69)))

(define (tlci-test-host-abi-ok?) : bool
  (and
    (tlci-test-host-abi-layout-ok?)
    (tlci-test-host-callback-op-layout-ok?)
    (match (tlci-validate-host-callback-table (tlci-test-host-callback-table))
      [(ResultTlciHostAbi.Ok) true]
      [(ResultTlciHostAbi.Err _) false])
    (match (tlci-validate-image-registration (tlci-test-image-registration))
      [(ResultTlciHostAbi.Ok) true]
      [(ResultTlciHostAbi.Err _) false])
    (match (tlci-validate-host-callback-table
      (TlciHostCallbackTable
        tlci-host-callback-table-magic
        tlci-host-abi-version
        (+ tlci-host-callback-table-size 16)
        1234
        0
        0
        4096
        8192))
      [(ResultTlciHostAbi.Ok) true]
      [(ResultTlciHostAbi.Err _) false])
    (match (tlci-validate-image-registration
      (TlciImageRegistration
        tlci-image-registration-magic
        tlci-host-abi-version
        (+ tlci-image-registration-size 16)
        5678
        0
        0
        12288
        1))
      [(ResultTlciHostAbi.Ok) true]
      [(ResultTlciHostAbi.Err _) false])
    (tlci-test-host-abi-rejects?
      (tlci-validate-host-callback-table
        (TlciHostCallbackTable
          0
          tlci-host-abi-version
          tlci-host-callback-table-size
          0
          0
          0
          1
          1))
      "tlci host ABI: bad host callback table magic")
    (tlci-test-host-abi-rejects?
      (tlci-validate-host-callback-table
        (TlciHostCallbackTable
          tlci-host-callback-table-magic
          (+ tlci-host-abi-version 1)
          tlci-host-callback-table-size
          0
          0
          0
          1
          1))
      "tlci host ABI: unsupported callback ABI version 2")
    (tlci-test-host-abi-rejects?
      (tlci-validate-host-callback-table
        (TlciHostCallbackTable
          tlci-host-callback-table-magic
          tlci-host-abi-version
          (- tlci-host-callback-table-size 1)
          0
          0
          0
          1
          1))
      "tlci host ABI: host callback table byte-size is smaller than v1")
    (tlci-test-host-abi-rejects?
      (tlci-validate-host-callback-table
        (TlciHostCallbackTable
          tlci-host-callback-table-magic
          tlci-host-abi-version
          tlci-host-callback-table-size
          0
          1
          0
          1
          1))
      "tlci host ABI: host callback table reserved0 must be zero")
    (tlci-test-host-abi-rejects?
      (tlci-validate-host-callback-table
        (TlciHostCallbackTable
          tlci-host-callback-table-magic
          tlci-host-abi-version
          tlci-host-callback-table-size
          0
          0
          0
          0
          1))
      "tlci host ABI: host invoke callback must be nonzero")
    (tlci-test-host-abi-rejects?
      (tlci-validate-host-callback-table
        (TlciHostCallbackTable
          tlci-host-callback-table-magic
          tlci-host-abi-version
          tlci-host-callback-table-size
          0
          0
          0
          1
          0))
      "tlci host ABI: host abort callback must be nonzero")
    (tlci-test-host-abi-rejects?
      (tlci-validate-image-registration
        (TlciImageRegistration
          0
          tlci-host-abi-version
          tlci-image-registration-size
          0
          0
          0
          0
          0))
      "tlci host ABI: bad image registration magic")
    (tlci-test-host-abi-rejects?
      (tlci-validate-image-registration
        (TlciImageRegistration
          tlci-image-registration-magic
          (+ tlci-host-abi-version 1)
          tlci-image-registration-size
          0
          0
          0
          0
          0))
      "tlci host ABI: unsupported callback ABI version 2")
    (tlci-test-host-abi-rejects?
      (tlci-validate-image-registration
        (TlciImageRegistration
          tlci-image-registration-magic
          tlci-host-abi-version
          (- tlci-image-registration-size 1)
          0
          0
          0
          0
          0))
      "tlci host ABI: image registration byte-size is smaller than v1")
    (tlci-test-host-abi-rejects?
      (tlci-validate-image-registration
        (TlciImageRegistration
          tlci-image-registration-magic
          tlci-host-abi-version
          tlci-image-registration-size
          0
          0
          1
          0
          0))
      "tlci host ABI: image registration reserved1 must be zero")
    (tlci-test-host-abi-rejects?
      (tlci-validate-image-registration
        (TlciImageRegistration
          tlci-image-registration-magic
          tlci-host-abi-version
          tlci-image-registration-size
          0
          0
          0
          0
          1))
      "tlci host ABI: macro entry count requires a table")
    (tlci-test-host-abi-rejects?
      (tlci-validate-image-registration
        (TlciImageRegistration
          tlci-image-registration-magic
          tlci-host-abi-version
          tlci-image-registration-size
          0
          0
          0
          1
          0))
      "tlci host ABI: macro entry table requires a count")))

(define (tlci-test-parse-round-trip? [image : TlciImage]) : bool
  (match (tlci-emit-image image)
    [(ResultTlciBytes.Err _) false]
    [(ResultTlciBytes.Ok bytes)
      (match (tlci-parse-image bytes)
        [(ResultTlciImage.Err _) false]
        [(ResultTlciImage.Ok parsed)
          (match (tlci-emit-image parsed)
            [(ResultTlciBytes.Err _) false]
            [(ResultTlciBytes.Ok again) (tlci-bytes-eq? bytes again)])])]))

(define (tlci-test-metadata-emit-parse?) : bool
  (let
    [source : String (tlci-metadata-emit (tlci-test-metadata))]
    (match (tlci-metadata-parse source)
      [(ResultTlciMetadata.Err _) false]
      [(ResultTlciMetadata.Ok parsed)
        (and
          (string.eq (struct-get parsed version) "v1")
          (string.eq (struct-get parsed package-name) "demo")
          (string.eq (struct-get parsed package-version) "0.1.0"))])))

(define (tlci-test-metadata-rejects? [source : String] [expected : String]) : bool
  (match (tlci-metadata-parse source)
    [(ResultTlciMetadata.Err message) (string.eq message expected)]
    [(ResultTlciMetadata.Ok _) false]))

(define (tlci-test-parse-rejects? [bytes : (Array u8)] [expected : String]) : bool
  (match (tlci-parse-image bytes)
    [(ResultTlciImage.Err message) (string.eq message expected)]
    [(ResultTlciImage.Ok _) false]))

(define (tlci-test-emit-rejects? [image : TlciImage] [expected : String]) : bool
  (match (tlci-emit-image image)
    [(ResultTlciBytes.Err message) (string.eq message expected)]
    [(ResultTlciBytes.Ok _) false]))

(define (tlci-test-corrupt-byte
  [bytes : (Array u8)]
  [offset : i64]
  [value : i64]) : (Array u8)
  (let
    [out : (Array u8) (tlci-copy-bytes bytes)]
    (begin
      (array-set! out offset (tlci-byte value))
      out)))

(define (tlci-test-rejections-ok?) : bool
  (match (tlci-emit-image (tlci-test-metadata-only-image))
    [(ResultTlciBytes.Err _) false]
    [(ResultTlciBytes.Ok bytes)
      (and
        (tlci-test-parse-rejects?
          (tlci-test-corrupt-byte bytes 0 0)
          "tlci: bad magic")
        (tlci-test-parse-rejects?
          (tlci-test-corrupt-byte bytes 8 2)
          "tlci: unsupported format version 2")
        (tlci-test-parse-rejects?
          (tlci-test-corrupt-byte bytes 16 9)
          "tlci: unsupported host arch")
        (tlci-test-parse-rejects?
          (tlci-test-corrupt-byte bytes 24 9)
          "tlci: unsupported callback ABI version")
        (tlci-test-parse-rejects?
          (tlci-test-corrupt-byte bytes 48 255)
          "tlci: content hash mismatch")
        (tlci-test-parse-rejects?
          (tlci-slice-bytes bytes 0 20)
          "tlci: truncated header"))]))

(define (tlci-test-metadata-rejections-ok?) : bool
  (and
    (tlci-test-metadata-rejects?
      (str_cat.str-cat
        "(typelisp-tlci-metadata "
        "(package (name \"demo\") (version \"0.1.0\")))")
      "tlci metadata: missing required field `version`")
    (tlci-test-metadata-rejects?
      (str_cat.str-cat "(typelisp-tlci-metadata " "(version \"v1\"))")
      "tlci metadata: missing required field `package`")
    (tlci-test-metadata-rejects?
      (str_cat.str-cat
        "(typelisp-tlci-metadata "
        "(version \"v9\") "
        "(package (name \"demo\") (version \"0.1.0\")))")
      "tlci metadata: unsupported version `v9`")
    (tlci-test-metadata-rejects?
      (str_cat.str-cat
        "(typelisp-tlci-metadata "
        "(version \"v1\") "
        "(package (name \"demo\") (version \"0.1.0\")) "
        "(exports (value (name \"answer\") (signature \"x\"))))")
      "tlci metadata: unknown field `exports`")))

(define (tlci-test-emit-rejections-ok?) : bool
  (tlci-test-emit-rejects?
    (tlci-test-malformed-fixups-image)
    "tlci: malformed fixup table length"))

(define (tlci-core-self-test-status) : i64
  (cond
    [(not (tlci-test-metadata-emit-parse?)) 1]
    [(not (tlci-test-parse-round-trip? (tlci-test-metadata-only-image))) 2]
    [(not (tlci-test-parse-round-trip? (tlci-test-code-image))) 3]
    [(not (tlci-test-rejections-ok?)) 4]
    [(not (tlci-test-metadata-rejections-ok?)) 5]
    [(not (tlci-test-emit-rejections-ok?)) 6]
    [(not (tlci-test-host-abi-ok?)) 7]
    [else 0]))

(define (tlci-core-self-test-ok?) : bool
  (= (tlci-core-self-test-status) 0))

(define (tlci-core-self-test) : i64
  (if (= (tlci-core-self-test-status) 0)
    42
    (io.panic "tlci-core: self-test mismatch")))

(test
  tlci-core-parse-emit-round-trip
  (if (= (tlci-core-self-test-status) 0)
    unit
    (io.panic "tlci-core: inline self-test mismatch")))