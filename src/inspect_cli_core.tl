;; inspect_cli_core.tl - Public tlci inspection command.
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(cfg embedded-stdlib-tlci (import "compiler_embedded_stdlib_tlci.tl"))
(import "tlci_core.tl")

(define (tlci-inspect-help-text) : String
  "Usage:
    typelisp inspect <file.tlci|embedded:stdlib.tlci>

Summary:
    Inspect a TypeLisp comptime image.
")

(define (tlci-inspect-host-arch-name [arch : i64]) : String
  (if (= arch tlci-host-arch-x86-64)
    "x86_64"
    "unknown"))

(define (tlci-inspect-section-line [name : String] [offset : i64] [len : i64]) : String
  (str_cat.str-cat
    "  "
    name
    ": offset="
    (string.int->string offset)
    " bytes="
    (string.int->string len)
    "\n"))

(define (tlci-inspect-table-line
  [name : String]
  [offset : i64]
  [count : i64]
  [record-size : i64]) : String
  (str_cat.str-cat
    "  "
    name
    ": offset="
    (string.int->string offset)
    " records="
    (string.int->string count)
    " bytes="
    (string.int->string (* count record-size))
    "\n"))

(define (tlci-inspect-import-line [offset : i64] [count : i64] [bytes : i64]) : String
  (str_cat.str-cat
    "  imports: offset="
    (string.int->string offset)
    " records="
    (string.int->string count)
    " bytes="
    (string.int->string bytes)
    "\n"))

(define (tlci-inspect-spmd-specializations [items : TlciSpmdSpecializationList]) : String
  (match items
    [(TlciSpmdSpecializationList.Nil) ""]
    [(TlciSpmdSpecializationList.Cons item rest)
      (str_cat.str-cat
        "    specialization: abi="
        (struct-get item abi)
        " backend="
        (struct-get item backend)
        " lanes="
        (string.int->string (struct-get item lanes))
        " args="
        (struct-get item args)
        " result="
        (struct-get item result)
        " index-param="
        (string.int->string (struct-get item index-param))
        " symbol="
        (struct-get item symbol)
        "\n"
        (tlci-inspect-spmd-specializations (box-get rest)))]))

(define (tlci-inspect-spmd-callables [items : TlciSpmdCallableList]) : String
  (match items
    [(TlciSpmdCallableList.Nil) ""]
    [(TlciSpmdCallableList.Cons item rest)
      (str_cat.str-cat
        "  helper: name="
        (struct-get item name)
        " signature="
        (struct-get item signature)
        "\n"
        (tlci-inspect-spmd-specializations (struct-get item specializations))
        (tlci-inspect-spmd-callables (box-get rest)))]))

(define (tlci-inspect-spmd-section [metadata : TlciMetadata]) : String
  (if (string.eq (struct-get metadata version) tlci-metadata-version-v2)
    (str_cat.str-cat
      "spmd-callables:\n"
      (tlci-inspect-spmd-callables (struct-get metadata spmd-callables)))
    ""))

(define (tlci-inspect-render [bytes : (__tl_dyn-array u8)] [image : TlciImage]) : String
  (let
    [metadata : TlciMetadata (struct-get image metadata)]
    [host-arch : i64 (struct-get image host-arch)]
    (str_cat.str-cat
      "tlci image\n"
      "format-version: "
      (string.int->string (tlci-read-u64 bytes 8))
      "\n"
      "host-arch: "
      (tlci-inspect-host-arch-name host-arch)
      " ("
      (string.int->string host-arch)
      ")\n"
      "callback-abi-version: "
      (string.int->string (struct-get image callback-abi-version))
      "\n"
      "producer-compiler-identity: "
      (struct-get image compiler-build-hash)
      "\n"
      "content-hash: "
      (string.int->string (tlci-read-u64 bytes 48))
      "\n"
      "file-size: "
      (string.int->string (tlci-read-u64 bytes 168))
      "\n"
      "metadata-version: "
      (struct-get metadata version)
      "\n"
      "package-name: "
      (struct-get metadata package-name)
      "\n"
      "package-version: "
      (struct-get metadata package-version)
      "\n"
      (tlci-inspect-spmd-section metadata)
      "sections:\n"
      (tlci-inspect-section-line
        "compiler-build-hash"
        (tlci-read-u64 bytes 32)
        (tlci-read-u64 bytes 40))
      (tlci-inspect-section-line
        "metadata"
        (tlci-read-u64 bytes 56)
        (tlci-read-u64 bytes 64))
      (tlci-inspect-section-line
        "rodata"
        (tlci-read-u64 bytes 72)
        (tlci-read-u64 bytes 80))
      (tlci-inspect-section-line
        "code"
        (tlci-read-u64 bytes 88)
        (tlci-read-u64 bytes 96))
      (tlci-inspect-table-line
        "fixups"
        (tlci-read-u64 bytes 104)
        (tlci-read-u64 bytes 112)
        tlci-section-fixup-record-size)
      (tlci-inspect-table-line
        "entries"
        (tlci-read-u64 bytes 120)
        (tlci-read-u64 bytes 128)
        tlci-section-entry-record-size)
      (tlci-inspect-table-line
        "symbols"
        (tlci-read-u64 bytes 136)
        (tlci-read-u64 bytes 144)
        tlci-section-symbol-record-size)
      (tlci-inspect-import-line
        (tlci-read-u64 bytes 152)
        (tlci-read-u64 bytes 160)
        (array-length (struct-get image imports))))))

(define (tlci-inspect-error [path : String] [message : String]) : String
  (str_cat.str-cat "inspect: " path ": " message "\n"))

(define (tlci-inspect-render-bytes
  [path : String]
  [bytes : (__tl_dyn-array u8)]) : i64
  (match (tlci-parse-image bytes)
    [(ResultTlciImage.Err message)
      (begin
        (io.print-error (tlci-inspect-error path message))
        1)]
    [(ResultTlciImage.Ok image)
      (begin
        (io.print-string (tlci-inspect-render bytes image))
        0)]))

(cfg
  (not embedded-stdlib-tlci)
  (define (tlci-inspect-embedded-stdlib) : i64
    (begin
      (io.print-error
        (tlci-inspect-error
          "embedded:stdlib.tlci"
          "embedded stdlib tlci is unavailable in this compiler build"))
      1)))

(cfg
  embedded-stdlib-tlci
  (define (tlci-inspect-embedded-stdlib) : i64
    (match (compiler-embedded-stdlib-tlci-validate)
      [(CompilerEmbeddedStdlibTlciValidation.Err message)
        (begin
          (io.print-error (tlci-inspect-error "embedded:stdlib.tlci" message))
          1)]
      [(CompilerEmbeddedStdlibTlciValidation.Ok count)
        (begin
          (io.print-string
            (str_cat.str-cat
              "embedded-loader-macro-count: "
              (string.int->string count)
              "\n"))
          (tlci-inspect-render-bytes
            "embedded:stdlib.tlci"
            (compiler-embedded-stdlib-tlci-copy)))])))

(cfg
  test
  (test
    tlci-inspect-error-includes-path
    (unless
      (string.eq
        (tlci-inspect-error "pkg/dep.tlci" "tlci: content hash mismatch")
        "inspect: pkg/dep.tlci: tlci: content hash mismatch\n")
      (io.panic "inspect error formatting failed"))))

(cfg
  test
  (test
    tlci-inspect-v2-spmd-callables
    (let
      [image : TlciImage
        (tlci-make-image
          tlci-host-arch-x86-64
          tlci-callback-abi-version
          "inspect-v2-test"
          (tlci-test-v2-metadata)
          (tlci-empty-bytes)
          (tlci-empty-bytes)
          (tlci-empty-bytes)
          (tlci-empty-bytes)
          (tlci-empty-bytes)
          (tlci-empty-bytes))]
      [ok : bool
        (match (tlci-emit-image image)
          [(ResultTlciBytes.Err _) false]
          [(ResultTlciBytes.Ok bytes)
            (match (tlci-parse-image bytes)
              [(ResultTlciImage.Err _) false]
              [(ResultTlciImage.Ok parsed)
                (let
                  [rendered : String (tlci-inspect-render bytes parsed)]
                  [expected : String
                    (str_cat.str-cat
                      "spmd-callables:\n"
                      "  helper: name=demo.alpha signature=(-> i64 i64)\n"
                      "    specialization: abi=spmd-call-v1 backend=avx512 lanes=8 args=v result=v index-param=0 symbol=__tl_spmd_demo_alpha_v8\n"
                      "    specialization: abi=spmd-call-v1 backend=scalar lanes=1 args=v result=v index-param=0 symbol=__tl_spmd_demo_alpha_scalar\n"
                      "  helper: name=demo.beta signature=(-> i64 i64)\n"
                      "    specialization: abi=spmd-call-future backend=future lanes=4 args=u result=u index-param=-1 symbol=__tl_spmd_demo_beta_future\n")]
                  (string.contains (& rendered) (& expected)))])])]
      (unless ok (io.panic "inspect v2 SPMD callable rendering failed")))))

(define (tlci-inspect-run-from [idx : i64] [count : i64]) : i64
  (if (not (= count (+ idx 1)))
    (begin
      (io.print-error "inspect: expected one .tlci path\n")
      1)
    (let
      [path : String (io.arg idx)]
      (if (string.eq path "embedded:stdlib.tlci")
        (tlci-inspect-embedded-stdlib)
        (match (io.try-read-file (& path))
          [(io.ErrIoString error)
            (begin
              (io.print-error
                (tlci-inspect-error path (io.error-message error)))
              1)]
          [(io.OkIoString contents)
            (tlci-inspect-render-bytes path (tlci-string->bytes contents))])))))