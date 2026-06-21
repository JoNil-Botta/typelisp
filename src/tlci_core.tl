;; tlci_core.tl - TypeLisp comptime image v1 parse/emit helpers (#2651).
;;
;; This module is deliberately dormant: it specifies and validates the tlci
;; container and metadata schema, but does not change package build behavior.
(import "../stdlib/string.tl")
(import "../stdlib/str_cat.tl")
(import "read.tl")

(define (tlci-string-length [text : String]) : i64
  (cfg
    feature-private-string-intrinsics
    (__tl_string_length text)
    (string-length text)))

(define (tlci-string-ref [text : String] [index : i64]) : char
  (cfg
    feature-private-string-intrinsics
    (__tl_string_ref text index)
    (string-ref text index)))

(defenum TlciExportKind
  (TlciExportValue)
  (TlciExportType)
  (TlciExportMacro))

(defstruct TlciExport
  (kind TlciExportKind)
  (name String)
  (signature String)
  (layout String))

(defenum TlciExportList
  (TlciExportNil)
  (TlciExportCons TlciExport (Box TlciExportList)))

(defstruct TlciMetadata
  (version String)
  (package-name String)
  (package-version String)
  (exports TlciExportList))

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

(defenum ResultTlciExportKind
  (OkTlciExportKind TlciExportKind)
  (ErrTlciExportKind String))

(defenum ResultTlciExport
  (OkTlciExport TlciExport)
  (ErrTlciExport String))

(defenum ResultTlciExportList
  (OkTlciExportList TlciExportList)
  (ErrTlciExportList String))

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
  (reserved1 i64))

(defstruct TlciImageRegistration
  (magic i64)
  (abi-version i64)
  (byte-size i64)
  (image-context i64)
  (reserved0 i64)
  (reserved1 i64))

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
(define tlci-host-callback-table-size : i64
  48)
(define tlci-image-registration-size : i64
  48)
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

(define (tlci-string-less? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (tlci-string-length left)]
    [right-len : i64 (tlci-string-length right)]
    [limit : i64
      (if (< left-len right-len)
        left-len
        right-len)]
    [idx : i64 0]
    [done : bool false]
    [less : bool false]
    (begin
      (while (and (not done) (< idx limit))
        (let
          [lc : i64 (tlci-char-code-at left idx)]
          [rc : i64 (tlci-char-code-at right idx)]
          (if (= lc rc)
            (set! idx (+ idx 1))
            (begin
              (set! less (< lc rc))
              (set! done true)))))
      (if done
        less
        (< left-len right-len)))))

(define (tlci-export-kind-name [kind : TlciExportKind]) : String
  (match kind
    [(TlciExportValue) "value"]
    [(TlciExportType) "type"]
    [(TlciExportMacro) "macro"]))

(define (tlci-export-kind-rank [kind : TlciExportKind]) : i64
  (match kind
    [(TlciExportValue) 0]
    [(TlciExportType) 1]
    [(TlciExportMacro) 2]))

(define (tlci-export-kind-eq? [left : TlciExportKind] [right : TlciExportKind]) : bool
  (= (tlci-export-kind-rank left) (tlci-export-kind-rank right)))

(define (tlci-export-less? [left : TlciExport] [right : TlciExport]) : bool
  (let
    [lk : i64 (tlci-export-kind-rank (struct-get left kind))]
    [rk : i64 (tlci-export-kind-rank (struct-get right kind))]
    (if (= lk rk)
      (tlci-string-less? (struct-get left name) (struct-get right name))
      (< lk rk))))

(define (tlci-export-same-key? [left : TlciExport] [right : TlciExport]) : bool
  (and
    (tlci-export-kind-eq? (struct-get left kind) (struct-get right kind))
    (string-eq (struct-get left name) (struct-get right name))))

(define (tlci-export-list-insert
  [exports : TlciExportList]
  [entry : TlciExport]) : ResultTlciExportList
  (match exports
    [(TlciExportNil)
      (OkTlciExportList (TlciExportCons entry (box TlciExportNil)))]
    [(TlciExportCons head rest)
      (if (tlci-export-same-key? head entry)
        (ErrTlciExportList
          (str-cat
            "tlci metadata: duplicate export `"
            (tlci-export-kind-name (struct-get entry kind))
            ":"
            (struct-get entry name)
            "`"))
        (if (tlci-export-less? entry head)
          (OkTlciExportList (TlciExportCons entry (box exports)))
          (match (tlci-export-list-insert (box-get rest) entry)
            [(ErrTlciExportList message) (ErrTlciExportList message)]
            [(OkTlciExportList next)
              (OkTlciExportList (TlciExportCons head (box next)))])))]))

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

(define (tlci-parse-export-kind [name : String]) : ResultTlciExportKind
  (cond
    [(string-eq name "value") (OkTlciExportKind (TlciExportValue))]
    [(string-eq name "type") (OkTlciExportKind (TlciExportType))]
    [(string-eq name "macro") (OkTlciExportKind (TlciExportMacro))]
    [else
      (ErrTlciExportKind
        "tlci metadata: export must start with `value`, `type`, or `macro`")]))

(define (tlci-export-fields
  [fields : Sexpr]
  [kind : TlciExportKind]
  [name : String]
  [has-name : bool]
  [signature : String]
  [has-signature : bool]
  [layout : String]
  [has-layout : bool]) : ResultTlciExport
  (match fields
    [(SNil)
      (cond
        [(not has-name)
          (ErrTlciExport "tlci metadata: export missing required field `name`")]
        [(string-eq name "")
          (ErrTlciExport "tlci metadata: export name must not be empty")]
        [(or
            (tlci-export-kind-eq? kind (TlciExportValue))
            (tlci-export-kind-eq? kind (TlciExportMacro)))
          (cond
            [has-layout
              (ErrTlciExport
                "tlci metadata: value and macro exports must not include `layout`")]
            [(not has-signature)
              (ErrTlciExport
                "tlci metadata: value and macro exports require `signature`")]
            [(string-eq signature "")
              (ErrTlciExport
                "tlci metadata: export signature must not be empty")]
            [else (OkTlciExport (TlciExport kind name signature ""))])]
        [has-signature
          (ErrTlciExport
            "tlci metadata: type exports must not include `signature`")]
        [(not has-layout)
          (ErrTlciExport "tlci metadata: type exports require `layout`")]
        [(string-eq layout "")
          (ErrTlciExport "tlci metadata: export layout must not be empty")]
        [else (OkTlciExport (TlciExport kind name "" layout))])]
    [(SCons field rest)
      (match (box-get field)
        [(SCons fhead ftail)
          (match (box-get fhead)
            [(SSym fname)
              (cond
                [(string-eq fname "name")
                  (if has-name
                    (ErrTlciExport
                      "tlci metadata: duplicate export field `name`")
                    (match (tlci-field-string-value (box-get ftail) fname)
                      [(ErrTlciString message) (ErrTlciExport message)]
                      [(OkTlciString value)
                        (tlci-export-fields
                          (box-get rest)
                          kind
                          value
                          true
                          signature
                          has-signature
                          layout
                          has-layout)]))]
                [(string-eq fname "signature")
                  (if has-signature
                    (ErrTlciExport
                      "tlci metadata: duplicate export field `signature`")
                    (match (tlci-field-string-value (box-get ftail) fname)
                      [(ErrTlciString message) (ErrTlciExport message)]
                      [(OkTlciString value)
                        (tlci-export-fields
                          (box-get rest)
                          kind
                          name
                          has-name
                          value
                          true
                          layout
                          has-layout)]))]
                [(string-eq fname "layout")
                  (if has-layout
                    (ErrTlciExport
                      "tlci metadata: duplicate export field `layout`")
                    (match (tlci-field-string-value (box-get ftail) fname)
                      [(ErrTlciString message) (ErrTlciExport message)]
                      [(OkTlciString value)
                        (tlci-export-fields
                          (box-get rest)
                          kind
                          name
                          has-name
                          signature
                          has-signature
                          value
                          true)]))]
                [else
                  (ErrTlciExport
                    (str-cat "tlci metadata: unknown export field `" fname "`"))])]
            [_
              (ErrTlciExport
                "tlci metadata: export fields must start with a name")])]
        [_ (ErrTlciExport "tlci metadata: export fields must be lists")])]
    [_ (ErrTlciExport "tlci metadata: export fields must be lists")]))

(define (tlci-export-from-form [form : Sexpr]) : ResultTlciExport
  (match form
    [(SCons head rest)
      (match (box-get head)
        [(SSym kind-name)
          (match (tlci-parse-export-kind kind-name)
            [(ErrTlciExportKind message) (ErrTlciExport message)]
            [(OkTlciExportKind kind)
              (tlci-export-fields
                (box-get rest)
                kind
                ""
                false
                ""
                false
                ""
                false)])]
        [_ (ErrTlciExport "tlci metadata: export must start with a kind")])]
    [_ (ErrTlciExport "tlci metadata: export entries must be lists")]))

(define (tlci-export-forms [forms : Sexpr] [acc : TlciExportList]) : ResultTlciExportList
  (match forms
    [(SNil) (OkTlciExportList acc)]
    [(SCons head rest)
      (match (tlci-export-from-form (box-get head))
        [(ErrTlciExport message) (ErrTlciExportList message)]
        [(OkTlciExport entry)
          (match (tlci-export-list-insert acc entry)
            [(ErrTlciExportList message) (ErrTlciExportList message)]
            [(OkTlciExportList next) (tlci-export-forms (box-get rest) next)])])]
    [_ (ErrTlciExportList "tlci metadata: `exports` must contain export lists")]))

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
          (OkTlciMetadata
            (TlciMetadata tlci-metadata-version name version TlciExportNil))])]
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
  [has-package : bool]
  [exports : TlciExportList]
  [has-exports : bool]) : ResultTlciMetadata
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
        [(not has-exports)
          (ErrTlciMetadata "tlci metadata: missing required field `exports`")]
        [else
          (OkTlciMetadata
            (TlciMetadata version package-name package-version exports))])]
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
                          has-package
                          exports
                          has-exports)]))]
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
                          true
                          exports
                          has-exports)]))]
                [(string-eq fname "exports")
                  (if has-exports
                    (ErrTlciMetadata "tlci metadata: duplicate field `exports`")
                    (match (tlci-export-forms (box-get ftail) TlciExportNil)
                      [(ErrTlciExportList message) (ErrTlciMetadata message)]
                      [(OkTlciExportList parsed)
                        (tlci-metadata-fields
                          (box-get rest)
                          version
                          has-version
                          package-name
                          package-version
                          has-package
                          parsed
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
            (tlci-metadata-fields
              (box-get rest)
              ""
              false
              ""
              ""
              false
              TlciExportNil
              false)
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

(define (tlci-emit-export [entry : TlciExport]) : String
  (match (struct-get entry kind)
    [(TlciExportValue)
      (str-cat
        "    (value (name "
        (tlci-quote-string (struct-get entry name))
        ") (signature "
        (tlci-quote-string (struct-get entry signature))
        "))\n")]
    [(TlciExportType)
      (str-cat
        "    (type (name "
        (tlci-quote-string (struct-get entry name))
        ") (layout "
        (tlci-quote-string (struct-get entry layout))
        "))\n")]
    [(TlciExportMacro)
      (str-cat
        "    (macro (name "
        (tlci-quote-string (struct-get entry name))
        ") (signature "
        (tlci-quote-string (struct-get entry signature))
        "))\n")]))

(define (tlci-emit-exports [exports : TlciExportList]) : String
  (match exports
    [(TlciExportNil) ""]
    [(TlciExportCons entry rest)
      (str-cat (tlci-emit-export entry) (tlci-emit-exports (box-get rest)))]))

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
    "))\n"
    "  (exports\n"
    (tlci-emit-exports (struct-get metadata exports))
    "  ))\n"))

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

(define (tlci-test-export-list) : TlciExportList
  (match (tlci-export-list-insert
    TlciExportNil
    (TlciExport (TlciExportMacro) "m" "(Expr)->Expr" ""))
    [(ErrTlciExportList _) TlciExportNil]
    [(OkTlciExportList one)
      (match (tlci-export-list-insert
        one
        (TlciExport (TlciExportValue) "answer" "(-> i64)" ""))
        [(ErrTlciExportList _) one]
        [(OkTlciExportList two)
          (match (tlci-export-list-insert
            two
            (TlciExport (TlciExportType) "Point" "" "size=16 align=8"))
            [(ErrTlciExportList _) two]
            [(OkTlciExportList three) three])])]))

(define (tlci-test-metadata) : TlciMetadata
  (TlciMetadata "v1" "demo" "0.1.0" (tlci-test-export-list)))

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
    0))

(define (tlci-test-image-registration) : TlciImageRegistration
  (TlciImageRegistration
    tlci-image-registration-magic
    tlci-host-abi-version
    tlci-image-registration-size
    5678
    0
    0))

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
    (= tlci-host-callback-table-size 48)
    (= tlci-image-registration-size 48)
    (= tlci-host-callback-table-magic-offset 0)
    (= tlci-host-callback-table-abi-version-offset 8)
    (= tlci-host-callback-table-byte-size-offset 16)
    (= tlci-host-callback-table-host-context-offset 24)
    (= tlci-host-callback-table-reserved0-offset 32)
    (= tlci-host-callback-table-reserved1-offset 40)
    (= tlci-image-registration-magic-offset 0)
    (= tlci-image-registration-abi-version-offset 8)
    (= tlci-image-registration-byte-size-offset 16)
    (= tlci-image-registration-image-context-offset 24)
    (= tlci-image-registration-reserved0-offset 32)
    (= tlci-image-registration-reserved1-offset 40)))

(define (tlci-test-host-abi-ok?) : bool
  (and
    (tlci-test-host-abi-layout-ok?)
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
          0))
      "tlci host ABI: bad host callback table magic")
    (tlci-test-host-abi-rejects?
      (tlci-validate-host-callback-table
        (TlciHostCallbackTable
          tlci-host-callback-table-magic
          (+ tlci-host-abi-version 1)
          tlci-host-callback-table-size
          0
          0
          0))
      "tlci host ABI: unsupported callback ABI version 2")
    (tlci-test-host-abi-rejects?
      (tlci-validate-host-callback-table
        (TlciHostCallbackTable
          tlci-host-callback-table-magic
          tlci-host-abi-version
          (- tlci-host-callback-table-size 1)
          0
          0
          0))
      "tlci host ABI: host callback table byte-size is smaller than v1")
    (tlci-test-host-abi-rejects?
      (tlci-validate-image-registration
        (TlciImageRegistration
          0
          tlci-host-abi-version
          tlci-image-registration-size
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
          0))
      "tlci host ABI: image registration byte-size is smaller than v1")))

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
        "(version \"v1\") "
        "(package (name \"demo\") (version \"0.1.0\")))")
      "tlci metadata: missing required field `exports`")
    (tlci-test-metadata-rejects?
      (str-cat
        "(typelisp-tlci-metadata "
        "(version \"v1\") "
        "(package (name \"demo\") (version \"0.1.0\")) "
        "(exports (value (name \"answer\") (signature \"\"))))")
      "tlci metadata: export signature must not be empty")
    (tlci-test-metadata-rejects?
      (str-cat
        "(typelisp-tlci-metadata "
        "(version \"v1\") "
        "(package (name \"demo\") (version \"0.1.0\")) "
        "(exports (type (name \"Point\") (layout \"\"))))")
      "tlci metadata: export layout must not be empty")
    (tlci-test-metadata-rejects?
      (str-cat
        "(typelisp-tlci-metadata "
        "(version \"v1\") "
        "(package (name \"demo\") (version \"0.1.0\")) "
        "(exports (type (name \"Point\") "
        "(signature \"sig\") (layout \"size=16\"))))")
      "tlci metadata: type exports must not include `signature`")))

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
    (begin
      (panic "tlci-core: self-test mismatch")
      ;; lint-allow: unreachable-code
      1)))

(test
  tlci-core-parse-emit-round-trip
  (if (= (tlci-core-self-test-status) 0)
    unit
    (panic "tlci-core: inline self-test mismatch")))