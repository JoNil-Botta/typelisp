;; tlci_core_tests.tl - image fixtures and the self-test for tlci_core, kept
;; out of the production module. tlci_core_smoke.tl runs the self-test; the
;; loader tests, the inspect tests and tests/tlci/corpus_emit.tl reuse the
;; fixtures.
(import stdlib.byte_buf_core)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_owned_view as owned_view)
(import tlci_core as tlci)

(define (tlci-test-metadata) : tlci.TlciMetadata
  (tlci.tlci-make-metadata "v1" "demo" "0.1.0"))

(define (tlci-test-v2-metadata) : tlci.TlciMetadata
  (let
    [avx : tlci.TlciSpmdSpecialization
      (tlci.tlci-make-spmd-specialization
        "spmd-call-v1"
        "avx512"
        8
        "v"
        "v"
        0
        "__tl_spmd_demo_alpha_v8")]
    [scalar : tlci.TlciSpmdSpecialization
      (tlci.tlci-make-spmd-specialization
        "spmd-call-v1"
        "scalar"
        1
        "v"
        "v"
        0
        "__tl_spmd_demo_alpha_scalar")]
    [future : tlci.TlciSpmdSpecialization
      (tlci.tlci-make-spmd-specialization
        "spmd-call-future"
        "future"
        4
        "u"
        "u"
        -1
        "__tl_spmd_demo_beta_future")]
    [alpha : tlci.TlciSpmdCallable
      (tlci.tlci-make-spmd-callable
        "demo.alpha"
        "(-> i64 i64)"
        (tlci.tlci-spmd-specializations-push
          (tlci.tlci-spmd-specializations-push
            (tlci.tlci-spmd-specializations-with-capacity 2)
            avx)
          scalar))]
    [beta : tlci.TlciSpmdCallable
      (tlci.tlci-make-spmd-callable
        "demo.beta"
        "(-> i64 i64)"
        (tlci.tlci-spmd-specializations-push
          (tlci.tlci-spmd-specializations-with-capacity 1)
          future))]
    (tlci.tlci-make-metadata-v2
      "demo"
      "0.2.0"
      (tlci.tlci-spmd-callables-push
        (tlci.tlci-spmd-callables-push
          (tlci.tlci-spmd-callables-with-capacity 2)
          alpha)
        beta))))

(define (tlci-test-bytes3 [a : i64] [b : i64] [c : i64]) : (__tl_dyn-array u8)
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (tlci.tlci-push-u8! (&mut out) a)
    (tlci.tlci-push-u8! (&mut out) b)
    (tlci.tlci-push-u8! (&mut out) c)
    (byte_buf_core.byte-buf-builder-finish-array (& out))))

(define (tlci-test-zero-records [record-size : i64] [count : i64]) : (__tl_dyn-array
    u8)
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (tlci.tlci-push-zeroes! (&mut out) (* record-size count))
    (byte_buf_core.byte-buf-builder-finish-array (& out))))

(define (tlci-test-metadata-only-image) : tlci.TlciImage
  (tlci.TlciImage
    (tlci.tlci-build-host-platform)
    tlci.tlci-callback-abi-version
    "abcdef0"
    (tlci-test-metadata)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)))

(define (tlci-test-v2-metadata-only-image) : tlci.TlciImage
  (tlci.TlciImage
    (tlci.tlci-build-host-platform)
    tlci.tlci-callback-abi-version
    "abcdef0"
    (tlci-test-v2-metadata)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)))

(define (tlci-test-imports-bytes) : (__tl_dyn-array u8)
  (let
    [name : String "fuel-check"]
    [name-len : i64 (tlci.tlci-string-length name)]
    [name-offset : i64
      (+
        tlci.tlci-section-import-header-size
        tlci.tlci-section-import-record-size)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 (+ name-offset name-len))]
    (tlci.tlci-set-u64! (&mut out) 0 1)
    (tlci.tlci-set-u64! (&mut out) tlci.tlci-section-import-header-size 8)
    (tlci.tlci-set-u64!
      (&mut out)
      (+ tlci.tlci-section-import-header-size 8)
      name-offset)
    (tlci.tlci-set-u64!
      (&mut out)
      (+ tlci.tlci-section-import-header-size 16)
      name-len)
    (tlci.tlci-put-string! (&mut out) name-offset name)
    out))

(define (tlci-test-imports-image) : tlci.TlciImage
  (tlci.TlciImage
    (tlci.tlci-build-host-platform)
    tlci.tlci-callback-abi-version
    "abcdef0"
    (tlci-test-metadata)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci-test-imports-bytes)))

(define (tlci-test-code-image) : tlci.TlciImage
  (tlci.TlciImage
    (tlci.tlci-build-host-platform)
    tlci.tlci-callback-abi-version
    "abcdef0"
    (tlci-test-metadata)
    (tlci-test-bytes3 1 2 3)
    (tlci-test-bytes3 195 144 144)
    (tlci-test-zero-records tlci.tlci-section-fixup-record-size 1)
    (tlci-test-zero-records tlci.tlci-section-entry-record-size 1)
    (tlci-test-zero-records tlci.tlci-section-symbol-record-size 1)
    (tlci.tlci-empty-bytes)))

(define (tlci-test-malformed-fixups-image) : tlci.TlciImage
  (tlci.TlciImage
    (tlci.tlci-build-host-platform)
    tlci.tlci-callback-abi-version
    "abcdef0"
    (tlci-test-metadata)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci-test-bytes3 1 2 3)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)))

(define (tlci-test-host-callback-table) : tlci.TlciHostCallbackTable
  (tlci.TlciHostCallbackTable
    tlci.tlci-host-callback-table-magic
    tlci.tlci-host-abi-version
    tlci.tlci-host-callback-table-size
    1234
    0
    0
    0
    8192
    (__tl_make-array String 0)
    (__tl_make-array i64 0)
    0))

(define (tlci-test-image-registration) : tlci.TlciImageRegistration
  (tlci.TlciImageRegistration
    tlci.tlci-image-registration-magic
    tlci.tlci-host-abi-version
    tlci.tlci-image-registration-size
    5678
    0
    0
    12288
    1))

(define (tlci-test-host-abi-rejects?
  [result : tlci.ResultTlciHostAbi]
  [expected : String]) : bool
  (match result
    [(Err message) (string.eq message expected)]
    [(Ok) false]))

(define (tlci-test-host-abi-layout-ok?) : bool
  (and
    (= tlci.tlci-host-abi-version tlci.tlci-callback-abi-version)
    (string.eq tlci.tlci-image-entry-symbol "tlci_image_entry")
    (= tlci.tlci-image-entry-param-count 2)
    (= tlci.tlci-image-entry-success 0)
    (= tlci.tlci-host-callback-status-ok 0)
    (= tlci.tlci-host-callback-status-diagnostic 1)
    (= tlci.tlci-host-callback-status-fuel-exhausted 2)
    (= tlci.tlci-host-callback-status-abort 3)
    (= tlci.tlci-host-callback-status-bad-request 4)
    (= tlci.tlci-host-callback-table-header-size 48)
    (= tlci.tlci-host-callback-table-size 64)
    (= tlci.tlci-image-registration-header-size 48)
    (= tlci.tlci-image-registration-size 64)
    (= tlci.tlci-host-callback-table-magic-offset 0)
    (= tlci.tlci-host-callback-table-abi-version-offset 8)
    (= tlci.tlci-host-callback-table-byte-size-offset 16)
    (= tlci.tlci-host-callback-table-host-context-offset 24)
    (= tlci.tlci-host-callback-table-reserved0-offset 32)
    (= tlci.tlci-host-callback-table-reserved1-offset 40)
    (= tlci.tlci-host-callback-table-reserved2-offset 48)
    (= tlci.tlci-host-callback-table-abort-offset 56)
    (= tlci.tlci-image-registration-magic-offset 0)
    (= tlci.tlci-image-registration-abi-version-offset 8)
    (= tlci.tlci-image-registration-byte-size-offset 16)
    (= tlci.tlci-image-registration-image-context-offset 24)
    (= tlci.tlci-image-registration-reserved0-offset 32)
    (= tlci.tlci-image-registration-reserved1-offset 40)
    (= tlci.tlci-image-registration-macro-entry-table-offset 48)
    (= tlci.tlci-image-registration-macro-entry-count-offset 56)
    (= tlci.tlci-macro-entry-record-size 32)
    (= tlci.tlci-macro-entry-name-ptr-offset 0)
    (= tlci.tlci-macro-entry-name-len-offset 8)
    (= tlci.tlci-macro-entry-function-offset 16)
    (= tlci.tlci-macro-entry-reserved0-offset 24)))

(define (tlci-test-host-abi-accepts? [result : tlci.ResultTlciHostAbi]) : bool
  (match result
    [(Ok) true]
    [(Err _) false]))

;; A callback table with no host context and an empty registry; the rejection
;; cases vary its header.
(define (tlci-test-table
  [magic : i64]
  [version : i64]
  [byte-size : i64]
  [reserved0 : i64]
  [reserved2 : i64]
  [abort : i64]) : tlci.TlciHostCallbackTable
  (tlci.TlciHostCallbackTable
    magic
    version
    byte-size
    0
    reserved0
    0
    reserved2
    abort
    (__tl_make-array String 0)
    (__tl_make-array i64 0)
    0))

;; A well-formed header over the given callback registry.
(define (tlci-test-registry-table
  [names : (__tl_dyn-array String)]
  [callbacks : (__tl_dyn-array i64)]
  [count : i64]) : tlci.TlciHostCallbackTable
  (tlci.TlciHostCallbackTable
    tlci.tlci-host-callback-table-magic
    tlci.tlci-host-abi-version
    tlci.tlci-host-callback-table-size
    0
    0
    0
    0
    1
    names
    callbacks
    count))

(define (tlci-test-registration
  [magic : i64]
  [version : i64]
  [byte-size : i64]
  [reserved1 : i64]
  [entry-table : i64]
  [entry-count : i64]) : tlci.TlciImageRegistration
  (tlci.TlciImageRegistration
    magic
    version
    byte-size
    0
    0
    reserved1
    entry-table
    entry-count))

(define (tlci-test-table-rejects?
  [table : tlci.TlciHostCallbackTable]
  [expected : String]) : bool
  (tlci-test-host-abi-rejects?
    (tlci.tlci-validate-host-callback-table table)
    expected))

(define (tlci-test-registration-rejects?
  [registration : tlci.TlciImageRegistration]
  [expected : String]) : bool
  (tlci-test-host-abi-rejects?
    (tlci.tlci-validate-image-registration registration)
    expected))

(define (tlci-test-host-abi-ok?) : bool
  (let
    [magic : i64 tlci.tlci-host-callback-table-magic]
    [version : i64 tlci.tlci-host-abi-version]
    [size : i64 tlci.tlci-host-callback-table-size]
    [registration-magic : i64 tlci.tlci-image-registration-magic]
    [registration-size : i64 tlci.tlci-image-registration-size]
    (and
      (tlci-test-host-abi-layout-ok?)
      (tlci-test-host-abi-accepts?
        (tlci.tlci-validate-host-callback-table (tlci-test-host-callback-table)))
      (tlci-test-host-abi-accepts?
        (tlci.tlci-validate-image-registration (tlci-test-image-registration)))
      (tlci-test-host-abi-accepts?
        (tlci.tlci-validate-host-callback-table
          (tlci.TlciHostCallbackTable
            magic
            version
            (+ size 16)
            1234
            0
            0
            0
            8192
            (__tl_make-array String 0)
            (__tl_make-array i64 0)
            0)))
      (tlci-test-host-abi-accepts?
        (tlci.tlci-validate-image-registration
          (tlci.TlciImageRegistration
            registration-magic
            version
            (+ registration-size 16)
            5678
            0
            0
            12288
            1)))
      (tlci-test-table-rejects?
        (tlci-test-table 0 version size 0 1 1)
        "tlci host ABI: bad host callback table magic")
      (tlci-test-table-rejects?
        (tlci-test-table magic (+ version 1) size 0 1 1)
        "tlci host ABI: unsupported callback ABI version 3")
      (tlci-test-table-rejects?
        (tlci-test-table magic version (- size 1) 0 1 1)
        "tlci host ABI: host callback table byte-size is smaller than v2")
      (tlci-test-table-rejects?
        (tlci-test-table magic version size 1 0 1)
        "tlci host ABI: host callback table reserved0 must be zero")
      (tlci-test-table-rejects?
        (tlci-test-table magic version size 0 1 1)
        "tlci host ABI: host callback table reserved2 must be zero")
      (tlci-test-table-rejects?
        (tlci-test-table magic version size 0 0 0)
        "tlci host ABI: host abort callback must be nonzero")
      (tlci-test-table-rejects?
        (tlci-test-registry-table
          (__tl_make-array "fuel-check")
          (__tl_make-array 0)
          1)
        "tlci host ABI: host callback registry address must be nonzero")
      (tlci-test-table-rejects?
        (tlci-test-registry-table
          (__tl_make-array "fuel-check" "fuel-check")
          (__tl_make-array 1 2)
          2)
        "tlci host ABI: duplicate host callback registry name")
      (tlci-test-registration-rejects?
        (tlci-test-registration 0 version registration-size 0 0 0)
        "tlci host ABI: bad image registration magic")
      (tlci-test-registration-rejects?
        (tlci-test-registration
          registration-magic
          (+ version 1)
          registration-size
          0
          0
          0)
        "tlci host ABI: unsupported callback ABI version 3")
      (tlci-test-registration-rejects?
        (tlci-test-registration
          registration-magic
          version
          (- registration-size 1)
          0
          0
          0)
        "tlci host ABI: image registration byte-size is smaller than v2")
      (tlci-test-registration-rejects?
        (tlci-test-registration
          registration-magic
          version
          registration-size
          1
          0
          0)
        "tlci host ABI: image registration reserved1 must be zero")
      (tlci-test-registration-rejects?
        (tlci-test-registration
          registration-magic
          version
          registration-size
          0
          0
          1)
        "tlci host ABI: macro entry count requires a table")
      (tlci-test-registration-rejects?
        (tlci-test-registration
          registration-magic
          version
          registration-size
          0
          1
          0)
        "tlci host ABI: macro entry table requires a count"))))

(define (tlci-test-parse-round-trip? [image : tlci.TlciImage]) : bool
  (match (tlci.tlci-emit-image image)
    [(Err _) false]
    [(Ok bytes)
      (match (tlci.tlci-parse-image (clone bytes))
        [(Err _) false]
        [(Ok parsed)
          (match (tlci.tlci-emit-image parsed)
            [(Err _) false]
            [(Ok again) (tlci.tlci-bytes-eq? bytes again)])])]))

(define (tlci-test-metadata-emit-parse?) : bool
  (let
    [source : String (tlci.tlci-metadata-emit (tlci-test-metadata))]
    (match (tlci.tlci-metadata-parse (string.copy source))
      [(Err _) false]
      [(Ok parsed)
        (and
          (string.eq parsed.version "v1")
          (string.eq parsed.package-name "demo")
          (string.eq parsed.package-version "0.1.0"))])))

(define (tlci-test-v2-alpha-specializations?
  [items : tlci.TlciSpmdSpecializations]) : bool
  (and
    (= (tlci.tlci-spmd-specializations-len items) 2)
    (let
      [first : tlci.TlciSpmdSpecialization
        (tlci.tlci-spmd-specializations-ref items 0)]
      [second : tlci.TlciSpmdSpecialization
        (tlci.tlci-spmd-specializations-ref items 1)]
      (and
        (string.eq first.backend "avx512")
        (= first.lanes 8)
        (string.eq second.backend "scalar")))))

(define (tlci-test-v2-beta-specializations?
  [items : tlci.TlciSpmdSpecializations]) : bool
  (and
    (= (tlci.tlci-spmd-specializations-len items) 1)
    (string.eq
      (__tl-project-field (tlci.tlci-spmd-specializations-ref items 0) abi)
      "spmd-call-future")))

(define (tlci-test-v2-callables-shape? [items : tlci.TlciSpmdCallables]) : bool
  (and
    (= (tlci.tlci-spmd-callables-len items) 2)
    (let
      [alpha : tlci.TlciSpmdCallable (tlci.tlci-spmd-callables-ref items 0)]
      [beta : tlci.TlciSpmdCallable (tlci.tlci-spmd-callables-ref items 1)]
      (and
        (string.eq alpha.name "demo.alpha")
        (tlci-test-v2-alpha-specializations? alpha.specializations)
        (string.eq beta.name "demo.beta")
        (tlci-test-v2-beta-specializations? beta.specializations)))))

(define (tlci-test-v2-parsed-shape? [metadata : tlci.TlciMetadata]) : bool
  (and
    (string.eq metadata.version "v2")
    (string.eq metadata.package-name "demo")
    (tlci-test-v2-callables-shape? metadata.spmd-callables)))

(define (tlci-test-v2-metadata-emit-parse?) : bool
  (let
    [source : String (tlci.tlci-metadata-emit (tlci-test-v2-metadata))]
    (match (tlci.tlci-metadata-parse (string.copy source))
      [(Err _) false]
      [(Ok parsed)
        (and
          (tlci-test-v2-parsed-shape? (clone parsed))
          (string.eq source (tlci.tlci-metadata-emit parsed)))])))

(define (tlci-test-dense-spmd-sequences?) : bool
  (let
    [specializations : tlci.TlciSpmdSpecializations
      (tlci.tlci-spmd-specializations-empty)]
    [callables : tlci.TlciSpmdCallables (tlci.tlci-spmd-callables-empty)]
    [index : i64 0]
    [ok : bool true]
    ;; Cross several vector growth boundaries for both metadata sequences.
    (while (< index 33)
      (tlci.tlci-spmd-specializations-push!
        (&mut specializations)
        (tlci.tlci-make-spmd-specialization
          "spmd-call-v1"
          "scalar"
          (+ index 1)
          "u"
          "u"
          -1
          (str_cat.str-cat "specialization-" (string.int->string index))))
      (tlci.tlci-spmd-callables-push!
        (&mut callables)
        (tlci.tlci-make-spmd-callable
          (str_cat.str-cat "helper-" (string.int->string index))
          "(-> i64 i64)"
          (tlci.tlci-spmd-specializations-empty)))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index 33)
      (let
        [specialization : tlci.TlciSpmdSpecialization
          (tlci.tlci-spmd-specializations-ref specializations index)]
        [callable : tlci.TlciSpmdCallable
          (tlci.tlci-spmd-callables-ref callables index)]
        (unless
          (and
            (= specialization.lanes (+ index 1))
            (string.eq
              specialization.symbol
              (str_cat.str-cat "specialization-" (string.int->string index)))
            (string.eq
              callable.name
              (str_cat.str-cat "helper-" (string.int->string index))))
          (set! ok false))
        (set! index (+ index 1))))
    (and
      ok
      (= (tlci.tlci-spmd-specializations-len specializations) 33)
      (= (tlci.tlci-spmd-callables-len callables) 33))))

(define (tlci-test-v1-emission-unchanged?) : bool
  (string.eq
    (tlci.tlci-metadata-emit (tlci-test-metadata))
    (str_cat.str-cat
      "(typelisp-tlci-metadata\n"
      "  (version \"v1\")\n"
      "  (package (name \"demo\") (version \"0.1.0\")))\n")))

(define (tlci-test-spmd-specialization-source
  [abi : String]
  [backend : String]
  [lanes : i64]
  [args : String]
  [result : String]
  [index-param : i64]
  [symbol : String]) : String
  (str_cat.str-cat
    "(specialization "
    "(abi "
    (tlci.tlci-quote-string abi)
    ") (backend "
    (tlci.tlci-quote-string backend)
    ") (lanes "
    (string.int->string lanes)
    ") (args "
    (tlci.tlci-quote-string args)
    ") (result "
    (tlci.tlci-quote-string result)
    ") (index-param "
    (string.int->string index-param)
    ") (symbol "
    (tlci.tlci-quote-string symbol)
    "))"))

(define (tlci-test-spmd-helper-source
  [name : String]
  [signature : String]
  [specializations : String]) : String
  (str_cat.str-cat
    "(helper (name "
    (tlci.tlci-quote-string name)
    ") (signature "
    (tlci.tlci-quote-string signature)
    ") "
    specializations
    ")"))

(define (tlci-test-v2-source [helpers : String]) : String
  (str_cat.str-cat
    "(typelisp-tlci-metadata "
    "(version \"v2\") "
    "(package (name \"demo\") (version \"0.2.0\")) "
    "(spmd-callables "
    helpers
    "))"))

(define (tlci-test-metadata-rejects? [source : String] [expected : String]) : bool
  (match (tlci.tlci-metadata-parse source)
    [(Err message) (string.eq message expected)]
    [(Ok _) false]))

(define (tlci-test-parse-rejects?
  [bytes : (__tl_dyn-array u8)]
  [expected : String]) : bool
  (match (tlci.tlci-parse-image bytes)
    [(Err message) (string.eq message expected)]
    [(Ok _) false]))

(define (tlci-test-emit-rejects? [image : tlci.TlciImage] [expected : String]) : bool
  (match (tlci.tlci-emit-image image)
    [(Err message) (string.eq message expected)]
    [(Ok _) false]))

(define (tlci-test-corrupt-byte
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [value : i64]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (tlci.tlci-copy-bytes bytes)]
    (set! (array-ref out offset) (tlci.tlci-byte value))
    out))

(define (tlci-test-rejections-ok?) : bool
  (match (tlci.tlci-emit-image (tlci-test-metadata-only-image))
    [(Err _) false]
    [(Ok bytes)
      (and
        (tlci-test-parse-rejects?
          (tlci-test-corrupt-byte bytes 0 0)
          "tlci: bad magic")
        (tlci-test-parse-rejects?
          (tlci-test-corrupt-byte bytes 8 9)
          "tlci: unsupported format version 9")
        (tlci-test-parse-rejects?
          (tlci-test-corrupt-byte bytes 16 9)
          "tlci: unsupported host platform")
        (tlci-test-parse-rejects?
          (tlci-test-corrupt-byte bytes 24 9)
          "tlci: unsupported callback ABI version")
        (tlci-test-parse-rejects?
          (tlci-test-corrupt-byte bytes 48 255)
          "tlci: content hash mismatch")
        (tlci-test-parse-rejects?
          (tlci.tlci-slice-bytes bytes 0 20)
          "tlci: truncated header"))]))

(define (tlci-test-platform-image [platform : i64] [code-bearing : bool]) : tlci.TlciImage
  (tlci.tlci-make-image
    platform
    tlci.tlci-callback-abi-version
    "abcdef0"
    (tlci-test-metadata)
    (tlci.tlci-empty-bytes)
    (if code-bearing
      (tlci-test-bytes3 195 144 144)
      (tlci.tlci-empty-bytes))
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)))

(define (tlci-test-platform-image-admission
  [platform : i64]
  [code-bearing : bool]
  [host-platform : i64]) : tlci.TlciImageHostAdmission
  (match (tlci.tlci-emit-image
    (tlci-test-platform-image
      (if (= platform tlci.tlci-host-platform-x86-64-legacy)
        host-platform
        platform)
      code-bearing))
    [(Err message) (Rejected message)]
    [(Ok bytes)
      (tlci.tlci-set-u64! (&mut bytes) 16 platform)
      (tlci.tlci-set-u64!
        (&mut bytes)
        tlci.tlci-hash-field-offset
        (tlci.tlci-content-hash bytes))
      (match (tlci.tlci-parse-image bytes)
        [(Err message) (Rejected message)]
        [(Ok image) (tlci.tlci-image-admit-host image host-platform)])]))

(define (tlci-test-host-platform-admission-ok?) : bool
  (let
    [host-platform : i64 (tlci.tlci-build-host-platform)]
    [other-platform : i64
      (if (= host-platform tlci.tlci-host-platform-x86-64-windows)
        tlci.tlci-host-platform-x86-64-linux
        tlci.tlci-host-platform-x86-64-windows)]
    (and
      (match (tlci-test-platform-image-admission
        other-platform
        false
        host-platform)
        [(MetadataOnly) true]
        [_ false])
      (match (tlci-test-platform-image-admission
        host-platform
        true
        host-platform)
        [(CodeBearing) true]
        [_ false])
      (match (tlci-test-platform-image-admission
        tlci.tlci-host-platform-x86-64-legacy
        true
        host-platform)
        [(Rejected message)
          (string.eq
            message
            "tlci: package `demo` code-bearing image uses legacy/ambiguous host platform")]
        [_ false])
      (match (tlci-test-platform-image-admission
        other-platform
        true
        host-platform)
        [(Rejected message)
          (string.eq
            message
            (str_cat.str-cat
              "tlci: package `demo` code-bearing image host platform mismatch: image="
              (tlci.tlci-host-platform-name other-platform)
              ", host="
              (tlci.tlci-host-platform-name host-platform)))]
        [_ false])
      (match (tlci.tlci-image-admit-host
        (tlci-test-platform-image 99 true)
        host-platform)
        [(Rejected message)
          (string.eq
            message
            "tlci: package `demo` image uses unsupported host platform 99")]
        [_ false])
      (match (tlci.tlci-image-admit-host
        (tlci-test-platform-image 99 false)
        host-platform)
        [(Rejected message)
          (string.eq
            message
            "tlci: package `demo` image uses unsupported host platform 99")]
        [_ false]))))

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

;; One spmd-call-v1 specialization with a varying result.
(define (tlci-test-v1-spec
  [backend : String]
  [lanes : i64]
  [args : String]
  [index-param : i64]
  [symbol : String]) : String
  (tlci-test-spmd-specialization-source
    "spmd-call-v1"
    backend
    lanes
    args
    "v"
    index-param
    symbol))

;; A v2 document whose only helper is `demo.alpha`.
(define (tlci-test-alpha-rejects?
  [signature : String]
  [specializations : String]
  [expected : String]) : bool
  (tlci-test-metadata-rejects?
    (tlci-test-v2-source
      (tlci-test-spmd-helper-source "demo.alpha" signature specializations))
    expected))

(define (tlci-test-v2-metadata-rejections-ok?) : bool
  (let
    [avx : String (tlci-test-v1-spec "avx512" 8 "v" 0 "__tl_spmd_alpha_v8")]
    [scalar : String
      (tlci-test-v1-spec "scalar" 1 "v" 0 "__tl_spmd_alpha_scalar")]
    [alpha : String
      (tlci-test-spmd-helper-source
        "demo.alpha"
        "(-> i64 i64)"
        (string.copy avx))]
    [beta : String
      (tlci-test-spmd-helper-source
        "demo.beta"
        "(-> i64 i64)"
        (string.copy avx))]
    (and
      (tlci-test-metadata-rejects?
        (str_cat.str-cat
          "(typelisp-tlci-metadata "
          "(version \"v1\") "
          "(package (name \"demo\") (version \"0.1.0\")) "
          "(spmd-callables "
          (string.copy alpha)
          "))")
        "tlci metadata: field `spmd-callables` requires version `v2`")
      (tlci-test-alpha-rejects?
        "(-> i64 i64)"
        (tlci-test-v1-spec "avx2" 8 "v" 0 "symbol")
        "tlci metadata: unsupported backend `avx2` for `spmd-call-v1`")
      (tlci-test-alpha-rejects?
        "(-> i64 i64)"
        (tlci-test-v1-spec "avx512" 0 "v" 0 "symbol")
        "tlci metadata: specialization lanes must be positive")
      (tlci-test-alpha-rejects?
        "(-> i64 i64)"
        (tlci-test-v1-spec "avx512" 8 "v,u" 0 "symbol")
        "tlci metadata: specialization args must contain only `u` and `v`")
      (tlci-test-alpha-rejects?
        "(-> i64 i64 i64)"
        (string.copy avx)
        "tlci metadata: specialization args length must equal signature parameter count")
      (tlci-test-alpha-rejects?
        "(-> i64 i64)"
        (tlci-test-v1-spec "avx512" 8 "v" 2 "symbol")
        "tlci metadata: specialization index-param is outside the signature")
      (tlci-test-alpha-rejects?
        "(-> i64 i64)"
        (tlci-test-v1-spec "avx512" 8 "u" 0 "symbol")
        "tlci metadata: specialization index-param must name a varying argument")
      (tlci-test-metadata-rejects?
        (tlci-test-v2-source
          (tlci-test-spmd-helper-source "" "(-> i64 i64)" (string.copy avx)))
        "tlci metadata: helper name must not be empty")
      (tlci-test-alpha-rejects?
        ""
        (string.copy avx)
        "tlci metadata: helper signature must not be empty")
      (tlci-test-alpha-rejects?
        "(-> i64 i64)"
        (tlci-test-v1-spec "avx512" 8 "v" 0 "")
        "tlci metadata: specialization symbol must not be empty")
      (tlci-test-alpha-rejects?
        "(-> i64 i64)"
        (str_cat.str-cat (string.copy avx) (string.copy avx))
        "tlci metadata: duplicate specialization record")
      (tlci-test-alpha-rejects?
        "(-> i64 i64)"
        (str_cat.str-cat (string.copy scalar) (string.copy avx))
        "tlci metadata: specialization records are not in stable order")
      (tlci-test-metadata-rejects?
        (tlci-test-v2-source
          (str_cat.str-cat (string.copy alpha) (string.copy alpha)))
        "tlci metadata: duplicate helper record")
      (tlci-test-metadata-rejects?
        (tlci-test-v2-source
          (str_cat.str-cat (string.copy beta) (string.copy alpha)))
        "tlci metadata: helper records are not in stable order")
      (tlci-test-metadata-rejects?
        (tlci-test-v2-source
          "(helper (name \"demo.alpha\") (signature \"(-> i64 i64)\") (specialization (abi \"spmd-call-v1\")))")
        "tlci metadata: specialization missing required field `backend`"))))

(define (tlci-test-emit-rejections-ok?) : bool
  (and
    (tlci-test-emit-rejects?
      (tlci-test-malformed-fixups-image)
      "tlci: malformed fixup table length")
    (tlci-test-emit-rejects?
      (tlci-test-platform-image tlci.tlci-host-platform-x86-64-legacy false)
      "tlci: new images must record a non-legacy host platform")
    (tlci-test-emit-rejects?
      (tlci-test-platform-image 99 false)
      "tlci: unsupported host platform")))

(define (tlci-test-aux-sections-ok?) : bool
  (let
    [base : (__tl_dyn-array u8) (tlci.tlci-string->bytes "native")]
    [identity : (__tl_dyn-array u8) (tlci.tlci-string->bytes "identity")]
    [ast : (__tl_dyn-array u8) (tlci.tlci-string->bytes "ast")]
    [sections : (__tl_dyn-array tlci.TlciAuxSection)
      (__tl_make-array tlci.TlciAuxSection 2)]
    (set!
      (array-ref sections 0)
      (tlci.TlciAuxSection
        tlci.tlci-aux-kind-package-identity
        1
        (clone identity)))
    (set!
      (array-ref sections 1)
      (tlci.TlciAuxSection tlci.tlci-aux-kind-frontend-ast 3 (clone ast)))
    (match (tlci.tlci-aux-pack-rodata (clone base) sections)
      [(Err _) false]
      [(Ok packed)
        (and
          (match (tlci.tlci-aux-directory packed)
            [(Ok directory) (= directory.base-len (array-length base))]
            [_ false])
          (match (tlci.tlci-aux-find packed tlci.tlci-aux-kind-package-identity)
            [(Ok version payload)
              (and (= version 1) (tlci.tlci-bytes-eq? payload identity))]
            [_ false])
          (match (tlci.tlci-aux-find packed tlci.tlci-aux-kind-frontend-ast)
            [(Ok version payload)
              (and (= version 3) (tlci.tlci-bytes-eq? payload ast))]
            [_ false])
          (match (tlci.tlci-aux-find packed tlci.tlci-aux-kind-frontend-facts)
            [(Missing) true]
            [_ false])
          (match (tlci.tlci-aux-pack-rodata base sections)
            [(Ok again) (tlci.tlci-bytes-eq? packed again)]
            [(Err _) false]))])))

(define (tlci-test-aux-corruption-rejected?) : bool
  (let
    [sections : (__tl_dyn-array tlci.TlciAuxSection)
      (__tl_make-array tlci.TlciAuxSection 1)]
    (set!
      (array-ref sections 0)
      (tlci.TlciAuxSection
        tlci.tlci-aux-kind-package-identity
        1
        (tlci.tlci-string->bytes "identity")))
    (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
      [(Err _) false]
      [(Ok packed)
        (match (tlci.tlci-aux-directory packed)
          [(Ok directory)
            (let
              [corrupt : (__tl_dyn-array u8) (tlci.tlci-copy-bytes packed)]
              [record : i64 directory.directory-offset]
              [payload-offset : i64 (tlci.tlci-read-u64 corrupt (+ record 16))]
              (set! (array-ref corrupt payload-offset) 0)
              (match (tlci.tlci-aux-find
                corrupt
                tlci.tlci-aux-kind-package-identity)
                [(Err _) true]
                [_ false]))]
          [_ false])])))

(define (tlci-test-aux-directory-shapes-ok?) : bool
  (let
    [sections : (__tl_dyn-array tlci.TlciAuxSection)
      (__tl_make-array tlci.TlciAuxSection 2)]
    [duplicates : (__tl_dyn-array tlci.TlciAuxSection)
      (__tl_make-array tlci.TlciAuxSection 2)]
    [first : (__tl_dyn-array u8) (tlci.tlci-string->bytes "first")]
    [unknown : (__tl_dyn-array u8) (tlci.tlci-string->bytes "unknown")]
    (set!
      (array-ref sections 0)
      (tlci.TlciAuxSection tlci.tlci-aux-kind-package-identity 1 first))
    (set!
      (array-ref sections 1)
      (tlci.TlciAuxSection 99 7 (owned_view.compiler-owned-shared-view unknown)))
    (set!
      (array-ref duplicates 0)
      (owned_view.compiler-owned-array-element-shared-view sections 0))
    (set!
      (array-ref duplicates 1)
      (owned_view.compiler-owned-array-element-shared-view sections 0))
    (and
      (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) duplicates)
        [(Err _) true]
        [_ false])
      (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
        [(Err _) false]
        [(Ok packed)
          (match (tlci.tlci-aux-directory packed)
            [(Ok directory)
              (let
                [duplicate-kind : (__tl_dyn-array u8)
                  (tlci.tlci-copy-bytes packed)]
                [overlap : (__tl_dyn-array u8) (tlci.tlci-copy-bytes packed)]
                [oversized : (__tl_dyn-array u8) (tlci.tlci-copy-bytes packed)]
                [truncated : (__tl_dyn-array u8)
                  (tlci.tlci-slice-bytes packed 0 (- (array-length packed) 1))]
                [first-record : i64 directory.directory-offset]
                [second-record : i64 (+ first-record tlci.tlci-aux-record-size)]
                [first-offset : i64
                  (tlci.tlci-read-u64 packed (+ first-record 16))]
                (tlci.tlci-set-u64!
                  (&mut duplicate-kind)
                  second-record
                  tlci.tlci-aux-kind-package-identity)
                (tlci.tlci-set-u64!
                  (&mut overlap)
                  (+ second-record 16)
                  first-offset)
                (tlci.tlci-set-u64!
                  (&mut oversized)
                  (+ first-record 24)
                  (+ directory.directory-offset 1))
                (and
                  (match (tlci.tlci-aux-find packed 99)
                    [(Ok schema payload)
                      (and (= schema 7) (tlci.tlci-bytes-eq? payload unknown))]
                    [_ false])
                  (match (tlci.tlci-aux-find
                    duplicate-kind
                    tlci.tlci-aux-kind-package-identity)
                    [(Err _) true]
                    [_ false])
                  (match (tlci.tlci-aux-find
                    overlap
                    tlci.tlci-aux-kind-package-identity)
                    [(Err _) true]
                    [_ false])
                  (match (tlci.tlci-aux-find
                    oversized
                    tlci.tlci-aux-kind-package-identity)
                    [(Err _) true]
                    [_ false])
                  (match (tlci.tlci-aux-directory truncated)
                    [(Missing) true]
                    [_ false])))]
            [_ false])]))))

(define (tlci-test-producer-identity-admission-ok?) : bool
  (let
    [current : String "0123456789abcdef0123456789abcdef01234567"]
    [stale : String "1123456789abcdef0123456789abcdef01234567"]
    (and
      (tlci.tlci-producer-identity-valid? current)
      (not
        (tlci.tlci-producer-identity-valid?
          "0123456789ABCDEF0123456789ABCDEF01234567"))
      (match (tlci.tlci-producer-identity-admit current current)
        [(ExactMatch) true]
        [_ false])
      (match (tlci.tlci-producer-identity-admit stale current)
        [(Mismatch) true]
        [_ false])
      (match (tlci.tlci-producer-identity-admit "" current)
        [(Missing) true]
        [_ false])
      (match (tlci.tlci-producer-identity-admit current "")
        [(Missing) true]
        [_ false])
      (match (tlci.tlci-producer-identity-admit "typelisp-selfhost-v1" current)
        [(Legacy) true]
        [_ false])
      (match (tlci.tlci-producer-identity-admit current "unknown")
        [(Legacy) true]
        [_ false])
      (match (tlci.tlci-producer-identity-admit "not-a-build-identity" current)
        [(Malformed) true]
        [_ false])
      (match (tlci.tlci-producer-identity-admit current "not-a-build-identity")
        [(Malformed) true]
        [_ false]))))

(define (tlci-test-package-source-binding-admission-ok?) : bool
  (let
    [sections : (__tl_dyn-array tlci.TlciAuxSection)
      (__tl_make-array tlci.TlciAuxSection 1)]
    [unsupported : (__tl_dyn-array u8) (tlci.tlci-string->bytes "future")]
    [short : (__tl_dyn-array u8) (__tl_make-array u8 7)]
    [zero : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    [negative : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    [limit : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    [empty : (__tl_dyn-array u8) (tlci.tlci-empty-bytes)]
    (set!
      (array-ref sections 0)
      (tlci.tlci-package-source-binding-section 12345))
    (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
      [(Err _) false]
      [(Ok packed)
        (and
          (match (tlci.tlci-package-source-binding-read packed)
            [(Bound digest) (= digest 12345)]
            [_ false])
          (match (tlci.tlci-package-source-binding-admit packed 12345)
            [(Match digest) (= digest 12345)]
            [_ false])
          (match (tlci.tlci-package-source-binding-admit packed 54321)
            [(Mismatch expected actual)
              (and (= expected 54321) (= actual 12345))]
            [_ false])
          (match (tlci.tlci-package-source-binding-read empty)
            [(MissingOrLegacy) true]
            [_ false])
          (match (tlci.tlci-package-source-binding-admit empty 12345)
            [(MissingOrLegacy) true]
            [_ false]))])
    (set!
      (array-ref sections 0)
      (tlci.TlciAuxSection
        tlci.tlci-aux-kind-package-source-binding
        2
        unsupported))
    (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
      [(Err _) false]
      [(Ok packed)
        (and
          (match (tlci.tlci-package-source-binding-read packed)
            [(UnsupportedSchema schema) (= schema 2)]
            [_ false])
          (match (tlci.tlci-package-source-binding-admit packed 12345)
            [(UnsupportedSchema schema) (= schema 2)]
            [_ false]))])
    (set!
      (array-ref sections 0)
      (tlci.TlciAuxSection
        tlci.tlci-aux-kind-package-source-binding
        tlci.tlci-package-source-binding-schema-version
        short))
    (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
      [(Err _) false]
      [(Ok packed)
        (match (tlci.tlci-package-source-binding-read packed)
          [(Malformed _) true]
          [_ false])])
    (tlci.tlci-set-u64! (&mut zero) 0 0)
    (set!
      (array-ref sections 0)
      (tlci.TlciAuxSection
        tlci.tlci-aux-kind-package-source-binding
        tlci.tlci-package-source-binding-schema-version
        zero))
    (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
      [(Err _) false]
      [(Ok packed)
        (and
          (match (tlci.tlci-package-source-binding-read packed)
            [(Bound digest) (= digest 0)]
            [_ false])
          (match (tlci.tlci-package-source-binding-admit packed 0)
            [(Match digest) (= digest 0)]
            [_ false])
          (match (tlci.tlci-package-source-binding-admit packed -1)
            [(Malformed _) true]
            [_ false])
          (match (tlci.tlci-package-source-binding-admit packed 2147483647)
            [(Malformed _) true]
            [_ false]))])
    (tlci.tlci-set-u64! (&mut negative) 0 -1)
    (set!
      (array-ref sections 0)
      (tlci.TlciAuxSection
        tlci.tlci-aux-kind-package-source-binding
        tlci.tlci-package-source-binding-schema-version
        negative))
    (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
      [(Err _) false]
      [(Ok packed)
        (match (tlci.tlci-package-source-binding-read packed)
          [(Malformed _) true]
          [_ false])])
    (tlci.tlci-set-u64! (&mut limit) 0 2147483647)
    (set!
      (array-ref sections 0)
      (tlci.TlciAuxSection
        tlci.tlci-aux-kind-package-source-binding
        tlci.tlci-package-source-binding-schema-version
        limit))
    (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
      [(Err _) false]
      [(Ok packed)
        (match (tlci.tlci-package-source-binding-read packed)
          [(Malformed _) true]
          [_ false])])))

;; The block form of the digest against the byte-at-a-time definition, at
;; every length around the digest field and the four-byte blocks, and on
;; all-0xff bytes (the largest intermediate sums).
(define (tlci-test-hash-bytes [n : i64] [seed : i64]) : (__tl_dyn-array u8)
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [state : i64 seed]
    [i : i64 0]
    (while (< i n)
      (set! state (+ (* state 6364136223846793005) 1442695040888963407))
      (set!
        (array-ref bytes i)
        (if (< seed 0)
          (cast 255 : u8)
          (cast (bit-and (shr state 33) 255) : u8)))
      (set! i (+ i 1)))
    bytes))

(define (tlci-test-range-hash-bytewise
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [len : i64]) : i64
  (let
    [hash : i64 1]
    [i : i64 0]
    (while (< i len)
      (set!
        hash
        (% (+ (* hash 131) (tlci.tlci-byte-at bytes (+ offset i))) 2147483647))
      (set! i (+ i 1)))
    hash))

(define (tlci-test-hash-blocks-ok?) : bool
  (let
    [n : i64 0]
    [ok : bool true]
    (while (and ok (< n 140))
      (let
        [random : (__tl_dyn-array u8) (tlci-test-hash-bytes n (+ n 3))]
        [ones : (__tl_dyn-array u8) (tlci-test-hash-bytes n (- 0 1))]
        (set!
          ok
          (and
            (=
              (tlci.tlci-content-hash (& random))
              (tlci.tlci-content-hash-bytewise (& random)))
            (=
              (tlci.tlci-content-hash (& ones))
              (tlci.tlci-content-hash-bytewise (& ones)))
            (or
              (< n 5)
              (=
                (tlci.tlci-range-hash (& random) 2 (- n 5))
                (tlci-test-range-hash-bytewise (& random) 2 (- n 5))))))
        (set! n (+ n 1))))
    ok))

(define (tlci-core-self-test-status) : i64
  (cond
    [(not (tlci-test-metadata-emit-parse?)) 1]
    [(not (tlci-test-parse-round-trip? (tlci-test-metadata-only-image))) 2]
    [(not (tlci-test-parse-round-trip? (tlci-test-code-image))) 3]
    [(not (tlci-test-rejections-ok?)) 4]
    [(not (tlci-test-metadata-rejections-ok?)) 5]
    [(not (tlci-test-emit-rejections-ok?)) 6]
    [(not (tlci-test-host-abi-ok?)) 7]
    [(not (tlci-test-v1-emission-unchanged?)) 9]
    [(not (tlci-test-v2-metadata-emit-parse?)) 10]
    [(not (tlci-test-parse-round-trip? (tlci-test-v2-metadata-only-image))) 11]
    [(not (tlci-test-v2-metadata-rejections-ok?)) 12]
    [(not (tlci-test-parse-round-trip? (tlci-test-imports-image))) 13]
    [(not (tlci-test-aux-sections-ok?)) 14]
    [(not (tlci-test-aux-corruption-rejected?)) 15]
    [(not (tlci-test-producer-identity-admission-ok?)) 16]
    [(not (tlci-test-dense-spmd-sequences?)) 17]
    [(not (tlci-test-package-source-binding-admission-ok?)) 18]
    [(not (tlci-test-host-platform-admission-ok?)) 19]
    [(not (tlci-test-aux-directory-shapes-ok?)) 20]
    [(not (tlci-test-hash-blocks-ok?)) 21]
    [else 0]))

(define (tlci-core-self-test) : i64
  (if (= (tlci-core-self-test-status) 0)
    42
    (io.panic "tlci-core: self-test mismatch")))

(test
  tlci-core-parse-emit-round-trip
  (if (= (tlci-core-self-test-status) 0)
    unit
    (io.panic "tlci-core: inline self-test mismatch")))