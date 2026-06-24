;; tlci_core.tl - TypeLisp comptime image v1 parse/emit helpers (#2651).
;;
;; This module is deliberately dormant: it specifies and validates the tlci
;; container and metadata schema, but does not change package build behavior.
(import "../stdlib/string.tl")
(import "../stdlib/str_cat.tl")
(import "read.tl")

(define (tlci-string-length [text : String]) : i64
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_length text)
    (string-length text)))

(define (tlci-string-ref [text : String] [index : i64]) : char
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_ref text index)
    (string-ref text index)))

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
  (OkTlciString String)
  (ErrTlciString String))

(defenum ResultTlciMetadata
  (OkTlciMetadata TlciMetadata)
  (ErrTlciMetadata String))

(defenum ResultTlciImage
  (OkTlciImage TlciImage)
  (ErrTlciImage String))

(defenum ResultTlciBytes
  (OkTlciBytes (Array u8))
  (ErrTlciBytes String))

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
  (OkTlciHostAbi)
  (ErrTlciHostAbi String))

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
(define tlci-host-callback-op-expr-var : i64
  102)
(define tlci-host-callback-op-string-concat : i64
  103)
(define tlci-host-callback-op-string-append : i64
  104)
(define tlci-host-callback-op-int->string : i64
  105)
(define tlci-host-callback-op-expr-splice : i64
  106)
(define tlci-host-callback-op-expr-if : i64
  107)
(define tlci-host-callback-op-expr-type : i64
  108)
(define tlci-host-callback-op-module-export-value? : i64
  109)
(define tlci-host-callback-op-module-export-type? : i64
  110)
(define tlci-host-callback-op-module-export-macro? : i64
  111)
(define tlci-host-callback-op-module-export-value-type : i64
  112)
(define tlci-host-callback-op-module-export-type : i64
  113)
(define tlci-host-callback-op-module-export-macro-type : i64
  114)
(define tlci-host-callback-op-expr-bool? : i64
  115)
(define tlci-host-callback-op-expr-bool-value : i64
  116)
(define tlci-host-callback-op-expr-if? : i64
  117)
(define tlci-host-callback-op-expr-if-cond : i64
  118)
(define tlci-host-callback-op-expr-if-then : i64
  119)
(define tlci-host-callback-op-expr-if-else : i64
  120)
(define tlci-host-callback-op-expr-list-empty? : i64
  121)
(define tlci-host-callback-op-expr-list-length : i64
  122)
(define tlci-host-callback-op-expr-list-head : i64
  123)
(define tlci-host-callback-op-expr-list-tail : i64
  124)
(define tlci-host-callback-op-expr-list-nth : i64
  125)
(define tlci-host-callback-op-expr-clause-first : i64
  126)
(define tlci-host-callback-op-expr-clause-second : i64
  127)
(define tlci-host-callback-op-expr-clause-list-empty? : i64
  128)
(define tlci-host-callback-op-expr-clause-list-length : i64
  129)
(define tlci-host-callback-op-expr-clause-list-head : i64
  130)
(define tlci-host-callback-op-expr-clause-list-tail : i64
  131)
(define tlci-host-callback-op-expr-clause-list-nth : i64
  132)
(define tlci-host-callback-op-expr-clause-list->expr-list : i64
  133)
(define tlci-host-callback-op-expr-binding-clause-name : i64
  134)
(define tlci-host-callback-op-expr-binding-clause-has-type? : i64
  135)
(define tlci-host-callback-op-expr-binding-clause-type : i64
  136)
(define tlci-host-callback-op-expr-binding-clause-init : i64
  137)
(define tlci-host-callback-op-expr-binding-clause-list-empty? : i64
  138)
(define tlci-host-callback-op-expr-binding-clause-list-length : i64
  139)
(define tlci-host-callback-op-expr-binding-clause-list-head : i64
  140)
(define tlci-host-callback-op-expr-binding-clause-list-tail : i64
  141)
(define tlci-host-callback-op-expr-binding-clause-list-nth : i64
  142)
(define tlci-host-callback-op-expr-binding-clause-list->expr-list : i64
  143)
(define tlci-host-callback-stdlib-op-count : i64
  44)
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
  (str-cat
    "tlci host ABI: unsupported callback ABI version "
    (int->string actual)))

(define (tlci-validate-host-callback-table [table : TlciHostCallbackTable]) : ResultTlciHostAbi
  (cond
    [(not (= (struct-get table magic) tlci-host-callback-table-magic))
      (ErrTlciHostAbi "tlci host ABI: bad host callback table magic")]
    [(not (= (struct-get table abi-version) tlci-host-abi-version))
      (ErrTlciHostAbi
        (tlci-host-abi-version-error (struct-get table abi-version)))]
    [(< (struct-get table byte-size) tlci-host-callback-table-size)
      (ErrTlciHostAbi
        "tlci host ABI: host callback table byte-size is smaller than v1")]
    [(not (= (struct-get table reserved0) 0))
      (ErrTlciHostAbi
        "tlci host ABI: host callback table reserved0 must be zero")]
    [(not (= (struct-get table reserved1) 0))
      (ErrTlciHostAbi
        "tlci host ABI: host callback table reserved1 must be zero")]
    [(= (struct-get table invoke-callback) 0)
      (ErrTlciHostAbi "tlci host ABI: host invoke callback must be nonzero")]
    [(= (struct-get table abort-callback) 0)
      (ErrTlciHostAbi "tlci host ABI: host abort callback must be nonzero")]
    [else (OkTlciHostAbi)]))

(define (tlci-validate-image-registration
  [registration : TlciImageRegistration]) : ResultTlciHostAbi
  (cond
    [(not (= (struct-get registration magic) tlci-image-registration-magic))
      (ErrTlciHostAbi "tlci host ABI: bad image registration magic")]
    [(not (= (struct-get registration abi-version) tlci-host-abi-version))
      (ErrTlciHostAbi
        (tlci-host-abi-version-error (struct-get registration abi-version)))]
    [(< (struct-get registration byte-size) tlci-image-registration-size)
      (ErrTlciHostAbi
        "tlci host ABI: image registration byte-size is smaller than v1")]
    [(not (= (struct-get registration reserved0) 0))
      (ErrTlciHostAbi
        "tlci host ABI: image registration reserved0 must be zero")]
    [(not (= (struct-get registration reserved1) 0))
      (ErrTlciHostAbi
        "tlci host ABI: image registration reserved1 must be zero")]
    [(and
        (= (struct-get registration macro-entry-table) 0)
        (not (= (struct-get registration macro-entry-count) 0)))
      (ErrTlciHostAbi "tlci host ABI: macro entry count requires a table")]
    [(and
        (not (= (struct-get registration macro-entry-table) 0))
        (= (struct-get registration macro-entry-count) 0))
      (ErrTlciHostAbi "tlci host ABI: macro entry table requires a count")]
    [else (OkTlciHostAbi)]))

(define (tlci-empty-bytes) : (Array u8)
  (make-array u8 0))

(define (tlci-byte [value : i64]) : u8
  (cast (bit-and value 0xff) : u8))

(define (tlci-push-u8! [out : (Array u8)] [value : i64]) : unit
  (array-push! out (tlci-byte value)))

(define (tlci-push-u64! [out : (Array u8)] [value : i64]) : unit
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

(define (tlci-push-zeroes! [out : (Array u8)] [count : i64]) : unit
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

(define (tlci-pad-to! [out : (Array u8)] [offset : i64]) : unit
  (tlci-push-zeroes! out (- offset (array-length out))))

(define (tlci-push-magic! [out : (Array u8)]) : unit
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

(define (tlci-push-string-bytes! [out : (Array u8)] [text : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (tlci-string-length text)]
    (begin
      (while (< i n)
        (begin
          (array-push! out (cast (tlci-string-ref text i) : u8))
          (set! i (+ i 1))))
      unit)))

(define (tlci-string->bytes [text : String]) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 0)]
    (begin
      (tlci-push-string-bytes! out text)
      out)))

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

(define (tlci-append-bytes! [out : (Array u8)] [bytes : (Array u8)]) : unit
  (let
    [i : i64 0]
    [n : i64 (array-length bytes)]
    (begin
      (while (< i n)
        (begin
          (array-push! out (array-ref bytes i))
          (set! i (+ i 1))))
      unit)))

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
    [(SCons vhead vrest)
      (match (box-get vhead)
        [(SStr val)
          (match (box-get vrest)
            [(SNil) (OkTlciString val)]
            [_
              (ErrTlciString
                (str-cat
                  "tlci metadata: field `"
                  fname
                  "` takes one string value"))])]
        [_
          (ErrTlciString
            (str-cat "tlci metadata: field `" fname "` must be a string"))])]
    [_
      (ErrTlciString
        (str-cat "tlci metadata: field `" fname "` must be a string"))]))

(define (tlci-package-fields
  [fields : Sexpr]
  [name : String]
  [has-name : bool]
  [version : String]
  [has-version : bool]) : ResultTlciMetadata
  (match fields
    [(SNil)
      (cond
        [(not has-name)
          (ErrTlciMetadata
            "tlci metadata: package missing required field `name`")]
        [(not has-version)
          (ErrTlciMetadata
            "tlci metadata: package missing required field `version`")]
        [(string-eq name "")
          (ErrTlciMetadata "tlci metadata: package name must not be empty")]
        [(string-eq version "")
          (ErrTlciMetadata "tlci metadata: package version must not be empty")]
        [else
          (OkTlciMetadata (TlciMetadata tlci-metadata-version name version))])]
    [(SCons field rest)
      (match (box-get field)
        [(SCons fhead ftail)
          (match (box-get fhead)
            [(SSym fname)
              (if (string-eq fname "name")
                (if has-name
                  (ErrTlciMetadata
                    "tlci metadata: duplicate package field `name`")
                  (match (tlci-field-string-value (box-get ftail) fname)
                    [(ErrTlciString message) (ErrTlciMetadata message)]
                    [(OkTlciString value)
                      (tlci-package-fields
                        (box-get rest)
                        value
                        true
                        version
                        has-version)]))
                (if (string-eq fname "version")
                  (if has-version
                    (ErrTlciMetadata
                      "tlci metadata: duplicate package field `version`")
                    (match (tlci-field-string-value (box-get ftail) fname)
                      [(ErrTlciString message) (ErrTlciMetadata message)]
                      [(OkTlciString value)
                        (tlci-package-fields
                          (box-get rest)
                          name
                          has-name
                          value
                          true)]))
                  (ErrTlciMetadata
                    (str-cat "tlci metadata: unknown package field `" fname "`"))))]
            [_
              (ErrTlciMetadata
                "tlci metadata: package fields must start with a name")])]
        [_ (ErrTlciMetadata "tlci metadata: package fields must be lists")])]
    [_ (ErrTlciMetadata "tlci metadata: package fields must be lists")]))

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
    [(SNil)
      (cond
        [(not has-version)
          (ErrTlciMetadata "tlci metadata: missing required field `version`")]
        [(not (string-eq version tlci-metadata-version))
          (ErrTlciMetadata
            (str-cat "tlci metadata: unsupported version `" version "`"))]
        [(not has-package)
          (ErrTlciMetadata "tlci metadata: missing required field `package`")]
        [else
          (OkTlciMetadata (TlciMetadata version package-name package-version))])]
    [(SCons field rest)
      (match (box-get field)
        [(SCons fhead ftail)
          (match (box-get fhead)
            [(SSym fname)
              (cond
                [(string-eq fname "version")
                  (if has-version
                    (ErrTlciMetadata "tlci metadata: duplicate field `version`")
                    (match (tlci-field-string-value (box-get ftail) fname)
                      [(ErrTlciString message) (ErrTlciMetadata message)]
                      [(OkTlciString value)
                        (tlci-metadata-fields
                          (box-get rest)
                          value
                          true
                          package-name
                          package-version
                          has-package)]))]
                [(string-eq fname "package")
                  (if has-package
                    (ErrTlciMetadata "tlci metadata: duplicate field `package`")
                    (match (tlci-package-from-field (box-get ftail))
                      [(ErrTlciMetadata message) (ErrTlciMetadata message)]
                      [(OkTlciMetadata parsed)
                        (tlci-metadata-fields
                          (box-get rest)
                          version
                          has-version
                          (struct-get parsed package-name)
                          (struct-get parsed package-version)
                          true)]))]
                [else
                  (ErrTlciMetadata
                    (str-cat "tlci metadata: unknown field `" fname "`"))])]
            [_
              (ErrTlciMetadata
                "tlci metadata: fields must start with a field name")])]
        [_ (ErrTlciMetadata "tlci metadata: fields must be lists")])]
    [_ (ErrTlciMetadata "tlci metadata: fields must be lists")]))

(define (tlci-metadata-from-form [form : Sexpr]) : ResultTlciMetadata
  (match form
    [(SCons head rest)
      (match (box-get head)
        [(SSym name)
          (if (string-eq name "typelisp-tlci-metadata")
            (tlci-metadata-fields (box-get rest) "" false "" "" false)
            (ErrTlciMetadata
              (str-cat "expected `typelisp-tlci-metadata` form, got `" name "`")))]
        [_
          (ErrTlciMetadata
            "tlci metadata: form must start with `typelisp-tlci-metadata`")])]
    [_
      (ErrTlciMetadata "tlci metadata: expected `(typelisp-tlci-metadata ...)`")]))

(define (tlci-metadata-parse [source : String]) : ResultTlciMetadata
  (match (read-result (lex source))
    [(ErrSexpr message)
      (ErrTlciMetadata (string-append "tlci metadata: " message))]
    [(OkSexpr form) (tlci-metadata-from-form form)]))

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
              [(= code 34) (set! out (str-cat out slash quote))]
              [(= code 92) (set! out (str-cat out slash slash))]
              [(= code 10) (set! out (str-cat out slash "n"))]
              [(= code 9) (set! out (str-cat out slash "t"))]
              [(= code 13) (set! out (str-cat out slash "r"))]
              [else (set! out (str-cat out (substring text i 1)))]))
          (set! i (+ i 1))))
      out)))

(define (tlci-quote-string [text : String]) : String
  (str-cat (tlci-quote-text) (tlci-escape-string text) (tlci-quote-text)))

(define (tlci-metadata-emit [metadata : TlciMetadata]) : String
  (str-cat
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
    [(string-eq (struct-get image compiler-build-hash) "")
      (ErrTlciBytes "tlci: compiler build hash must not be empty")]
    [(not
        (=
          (%
            (array-length (struct-get image fixups))
            tlci-section-fixup-record-size)
          0))
      (ErrTlciBytes "tlci: malformed fixup table length")]
    [(not
        (=
          (%
            (array-length (struct-get image entries))
            tlci-section-entry-record-size)
          0))
      (ErrTlciBytes "tlci: malformed entry table length")]
    [(not
        (=
          (%
            (array-length (struct-get image symbols))
            tlci-section-symbol-record-size)
          0))
      (ErrTlciBytes "tlci: malformed symbol table length")]
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
        [out : (Array u8) (make-array u8 0)]
        (begin
          (tlci-push-magic! out)
          (tlci-push-u64! out tlci-format-version)
          (tlci-push-u64! out (struct-get image host-arch))
          (tlci-push-u64! out (struct-get image callback-abi-version))
          (tlci-push-u64! out hash-offset)
          (tlci-push-u64! out (array-length compiler-hash-bytes))
          (tlci-push-u64! out 0)
          (tlci-push-u64! out metadata-offset)
          (tlci-push-u64! out (array-length metadata-bytes))
          (tlci-push-u64! out rodata-offset)
          (tlci-push-u64! out rodata-len)
          (tlci-push-u64! out code-offset)
          (tlci-push-u64! out code-len)
          (tlci-push-u64! out fixups-offset)
          (tlci-push-u64! out (/ fixups-len tlci-section-fixup-record-size))
          (tlci-push-u64! out entries-offset)
          (tlci-push-u64! out (/ entries-len tlci-section-entry-record-size))
          (tlci-push-u64! out symbols-offset)
          (tlci-push-u64! out (/ symbols-len tlci-section-symbol-record-size))
          (tlci-push-u64! out file-size)
          (tlci-append-bytes! out compiler-hash-bytes)
          (tlci-pad-to! out metadata-offset)
          (tlci-append-bytes! out metadata-bytes)
          (if (> rodata-len 0)
            (begin
              (tlci-pad-to! out rodata-offset)
              (tlci-append-bytes! out (struct-get image rodata)))
            unit)
          (if (> code-len 0)
            (begin
              (tlci-pad-to! out code-offset)
              (tlci-append-bytes! out (struct-get image code)))
            unit)
          (if (> fixups-len 0)
            (begin
              (tlci-pad-to! out fixups-offset)
              (tlci-append-bytes! out (struct-get image fixups)))
            unit)
          (if (> entries-len 0)
            (begin
              (tlci-pad-to! out entries-offset)
              (tlci-append-bytes! out (struct-get image entries)))
            unit)
          (if (> symbols-len 0)
            (begin
              (tlci-pad-to! out symbols-offset)
              (tlci-append-bytes! out (struct-get image symbols)))
            unit)
          (tlci-set-u64! out tlci-hash-field-offset (tlci-content-hash out))
          (OkTlciBytes out)))]))

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
  (ErrTlciImage (str-cat "tlci: section `" name "` extends past end")))

(define (tlci-parse-image [bytes : (Array u8)]) : ResultTlciImage
  (let
    [actual-size : i64 (array-length bytes)]
    (if (< actual-size tlci-header-size)
      (ErrTlciImage "tlci: truncated header")
      (if (not (tlci-magic-ok? bytes))
        (ErrTlciImage "tlci: bad magic")
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
              (ErrTlciImage
                (str-cat
                  "tlci: unsupported format version "
                  (int->string version)))]
            [(not (= host-arch tlci-host-arch-x86-64))
              (ErrTlciImage "tlci: unsupported host arch")]
            [(not (= callback-abi tlci-callback-abi-version))
              (ErrTlciImage "tlci: unsupported callback ABI version")]
            [(not (= declared-size actual-size))
              (ErrTlciImage "tlci: file size field does not match input length")]
            [(not (tlci-section-range-ok? actual-size hash-offset hash-len))
              (tlci-section-error "compiler-build-hash")]
            [(= hash-len 0)
              (ErrTlciImage "tlci: compiler build hash must not be empty")]
            [(not (= hash-offset tlci-header-size))
              (ErrTlciImage "tlci: compiler build hash must start after header")]
            [(not
                (tlci-section-range-ok?
                  actual-size
                  metadata-offset
                  metadata-len))
              (tlci-section-error "metadata")]
            [(= metadata-len 0)
              (ErrTlciImage "tlci: metadata section must not be empty")]
            [(not (tlci-section-aligned? metadata-offset metadata-len 8))
              (ErrTlciImage "tlci: metadata section must be 8-byte aligned")]
            [(not (tlci-section-ordered? hash-end metadata-offset metadata-len))
              (ErrTlciImage "tlci: metadata section overlaps previous section")]
            [(not (tlci-section-range-ok? actual-size rodata-offset rodata-len))
              (tlci-section-error "rodata")]
            [(not
                (tlci-section-aligned? rodata-offset rodata-len tlci-page-align))
              (ErrTlciImage "tlci: rodata section must be page-aligned")]
            [(not (tlci-section-ordered? metadata-end rodata-offset rodata-len))
              (ErrTlciImage "tlci: rodata section overlaps previous section")]
            [(not (tlci-section-range-ok? actual-size code-offset code-len))
              (tlci-section-error "code")]
            [(not (tlci-section-aligned? code-offset code-len tlci-page-align))
              (ErrTlciImage "tlci: code section must be page-aligned")]
            [(not (tlci-section-ordered? rodata-end code-offset code-len))
              (ErrTlciImage "tlci: code section overlaps previous section")]
            [(not (tlci-section-range-ok? actual-size fixups-offset fixups-len))
              (tlci-section-error "fixups")]
            [(not (tlci-section-aligned? fixups-offset fixups-len 8))
              (ErrTlciImage "tlci: fixup table must be 8-byte aligned")]
            [(not (tlci-section-ordered? code-end fixups-offset fixups-len))
              (ErrTlciImage "tlci: fixup table overlaps previous section")]
            [(not
                (tlci-section-range-ok? actual-size entries-offset entries-len))
              (tlci-section-error "entries")]
            [(not (tlci-section-aligned? entries-offset entries-len 8))
              (ErrTlciImage "tlci: entry table must be 8-byte aligned")]
            [(not (tlci-section-ordered? fixups-end entries-offset entries-len))
              (ErrTlciImage "tlci: entry table overlaps previous section")]
            [(not
                (tlci-section-range-ok? actual-size symbols-offset symbols-len))
              (tlci-section-error "symbols")]
            [(not (tlci-section-aligned? symbols-offset symbols-len 8))
              (ErrTlciImage "tlci: symbol table must be 8-byte aligned")]
            [(not
                (tlci-section-ordered? entries-end symbols-offset symbols-len))
              (ErrTlciImage "tlci: symbol table overlaps previous section")]
            [(not
                (tlci-table-len-ok? fixups-len tlci-section-fixup-record-size))
              (ErrTlciImage "tlci: malformed fixup table length")]
            [(not
                (tlci-table-len-ok? entries-len tlci-section-entry-record-size))
              (ErrTlciImage "tlci: malformed entry table length")]
            [(not
                (tlci-table-len-ok? symbols-len tlci-section-symbol-record-size))
              (ErrTlciImage "tlci: malformed symbol table length")]
            [(not (= declared-size content-end))
              (ErrTlciImage "tlci: file has trailing bytes")]
            [(not (= expected-hash (tlci-content-hash bytes)))
              (ErrTlciImage "tlci: content hash mismatch")]
            [else
              (let
                [metadata-text : String
                  (tlci-bytes->string bytes metadata-offset metadata-len)]
                (match (tlci-metadata-parse metadata-text)
                  [(ErrTlciMetadata message)
                    (ErrTlciImage
                      (str-cat "tlci: malformed metadata: " message))]
                  [(OkTlciMetadata metadata)
                    (OkTlciImage
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
    [out : (Array u8) (make-array u8 0)]
    (begin
      (tlci-push-u8! out a)
      (tlci-push-u8! out b)
      (tlci-push-u8! out c)
      out)))

(define (tlci-test-zero-records [record-size : i64] [count : i64]) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 0)]
    (begin
      (tlci-push-zeroes! out (* record-size count))
      out)))

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
    [(ErrTlciHostAbi message) (string-eq message expected)]
    [(OkTlciHostAbi) false]))

(define (tlci-test-host-abi-layout-ok?) : bool
  (and
    (= tlci-host-abi-version tlci-callback-abi-version)
    (string-eq tlci-image-entry-symbol "tlci_image_entry")
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
    (= tlci-host-callback-op-expr-var 102)
    (= tlci-host-callback-op-string-concat 103)
    (= tlci-host-callback-op-string-append 104)
    (= tlci-host-callback-op-int->string 105)
    (= tlci-host-callback-op-expr-splice 106)
    (= tlci-host-callback-op-expr-if 107)
    (= tlci-host-callback-op-expr-type 108)
    (= tlci-host-callback-op-module-export-value? 109)
    (= tlci-host-callback-op-module-export-type? 110)
    (= tlci-host-callback-op-module-export-macro? 111)
    (= tlci-host-callback-op-module-export-value-type 112)
    (= tlci-host-callback-op-module-export-type 113)
    (= tlci-host-callback-op-module-export-macro-type 114)
    (= tlci-host-callback-op-expr-bool? 115)
    (= tlci-host-callback-op-expr-bool-value 116)
    (= tlci-host-callback-op-expr-if? 117)
    (= tlci-host-callback-op-expr-if-cond 118)
    (= tlci-host-callback-op-expr-if-then 119)
    (= tlci-host-callback-op-expr-if-else 120)
    (= tlci-host-callback-op-expr-list-empty? 121)
    (= tlci-host-callback-op-expr-list-length 122)
    (= tlci-host-callback-op-expr-list-head 123)
    (= tlci-host-callback-op-expr-list-tail 124)
    (= tlci-host-callback-op-expr-list-nth 125)
    (= tlci-host-callback-op-expr-clause-first 126)
    (= tlci-host-callback-op-expr-clause-second 127)
    (= tlci-host-callback-op-expr-clause-list-empty? 128)
    (= tlci-host-callback-op-expr-clause-list-length 129)
    (= tlci-host-callback-op-expr-clause-list-head 130)
    (= tlci-host-callback-op-expr-clause-list-tail 131)
    (= tlci-host-callback-op-expr-clause-list-nth 132)
    (= tlci-host-callback-op-expr-clause-list->expr-list 133)
    (= tlci-host-callback-op-expr-binding-clause-name 134)
    (= tlci-host-callback-op-expr-binding-clause-has-type? 135)
    (= tlci-host-callback-op-expr-binding-clause-type 136)
    (= tlci-host-callback-op-expr-binding-clause-init 137)
    (= tlci-host-callback-op-expr-binding-clause-list-empty? 138)
    (= tlci-host-callback-op-expr-binding-clause-list-length 139)
    (= tlci-host-callback-op-expr-binding-clause-list-head 140)
    (= tlci-host-callback-op-expr-binding-clause-list-tail 141)
    (= tlci-host-callback-op-expr-binding-clause-list-nth 142)
    (= tlci-host-callback-op-expr-binding-clause-list->expr-list 143)
    (= tlci-host-callback-stdlib-op-count 44)))

(define (tlci-test-host-abi-ok?) : bool
  (and
    (tlci-test-host-abi-layout-ok?)
    (tlci-test-host-callback-op-layout-ok?)
    (match (tlci-validate-host-callback-table (tlci-test-host-callback-table))
      [(OkTlciHostAbi) true]
      [(ErrTlciHostAbi _) false])
    (match (tlci-validate-image-registration (tlci-test-image-registration))
      [(OkTlciHostAbi) true]
      [(ErrTlciHostAbi _) false])
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
    [(ErrTlciBytes _) false]
    [(OkTlciBytes bytes)
      (match (tlci-parse-image bytes)
        [(ErrTlciImage _) false]
        [(OkTlciImage parsed)
          (match (tlci-emit-image parsed)
            [(ErrTlciBytes _) false]
            [(OkTlciBytes again) (tlci-bytes-eq? bytes again)])])]))

(define (tlci-test-metadata-emit-parse?) : bool
  (let
    [source : String (tlci-metadata-emit (tlci-test-metadata))]
    (match (tlci-metadata-parse source)
      [(ErrTlciMetadata _) false]
      [(OkTlciMetadata parsed)
        (and
          (string-eq (struct-get parsed version) "v1")
          (string-eq (struct-get parsed package-name) "demo")
          (string-eq (struct-get parsed package-version) "0.1.0"))])))

(define (tlci-test-metadata-rejects? [source : String] [expected : String]) : bool
  (match (tlci-metadata-parse source)
    [(ErrTlciMetadata message) (string-eq message expected)]
    [(OkTlciMetadata _) false]))

(define (tlci-test-parse-rejects? [bytes : (Array u8)] [expected : String]) : bool
  (match (tlci-parse-image bytes)
    [(ErrTlciImage message) (string-eq message expected)]
    [(OkTlciImage _) false]))

(define (tlci-test-emit-rejects? [image : TlciImage] [expected : String]) : bool
  (match (tlci-emit-image image)
    [(ErrTlciBytes message) (string-eq message expected)]
    [(OkTlciBytes _) false]))

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
    [(ErrTlciBytes _) false]
    [(OkTlciBytes bytes)
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
      (str-cat
        "(typelisp-tlci-metadata "
        "(package (name \"demo\") (version \"0.1.0\")))")
      "tlci metadata: missing required field `version`")
    (tlci-test-metadata-rejects?
      (str-cat "(typelisp-tlci-metadata " "(version \"v1\"))")
      "tlci metadata: missing required field `package`")
    (tlci-test-metadata-rejects?
      (str-cat
        "(typelisp-tlci-metadata "
        "(version \"v9\") "
        "(package (name \"demo\") (version \"0.1.0\")))")
      "tlci metadata: unsupported version `v9`")
    (tlci-test-metadata-rejects?
      (str-cat
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
    (panic "tlci-core: self-test mismatch")))

(test
  tlci-core-parse-emit-round-trip
  (if (= (tlci-core-self-test-status) 0)
    unit
    (panic "tlci-core: inline self-test mismatch")))