;; inspect_cli_core.tl - Public tlci inspection command.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(cfg embedded-stdlib-tlci (import compiler_embedded_stdlib_tlci))
(import tlci_core)

(define (tlci-inspect-help-text) : String
  "Usage:
    typelisp inspect <file.tlci|embedded:stdlib.tlci>

Summary:
    Inspect a TypeLisp comptime image.
")

(define (tlci-inspect-classification-name
  [image : (& image tlci_core.TlciImage)]) : String
  (match (tlci_core.tlci-image-classify image)
    [(MetadataOnly) "metadata-only"]
    [(CodeBearing) "code-bearing"]))

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

(define (tlci-inspect-spmd-specializations
  [items : tlci_core.TlciSpmdSpecializations]) : String
  (let
    [count : i64 (tlci_core.tlci-spmd-specializations-len items)]
    [index : i64 0]
    [out : String ""]
    (begin
      (while (< index count)
        (let
          [item : tlci_core.TlciSpmdSpecialization
            (tlci_core.tlci-spmd-specializations-ref items index)]
          (begin
            (set!
              out
              (str_cat.str-cat
                out
                "    specialization: abi="
                item.abi
                " backend="
                item.backend
                " lanes="
                (string.int->string item.lanes)
                " args="
                item.args
                " result="
                item.result
                " index-param="
                (string.int->string item.index-param)
                " symbol="
                item.symbol
                "\n"))
            (set! index (+ index 1)))))
      out)))

(define (tlci-inspect-spmd-callables
  [items : (& items tlci_core.TlciSpmdCallables)]) : String
  (let
    [count : i64 (tlci_core.tlci-spmd-callables-len items)]
    [index : i64 0]
    [out : String ""]
    (begin
      (while (< index count)
        (let
          [item : tlci_core.TlciSpmdCallable
            (tlci_core.tlci-spmd-callables-ref items index)]
          (begin
            (set!
              out
              (str_cat.str-cat
                out
                "  helper: name="
                item.name
                " signature="
                item.signature
                "\n"
                (tlci-inspect-spmd-specializations item.specializations)))
            (set! index (+ index 1)))))
      out)))

(define (tlci-inspect-spmd-section
  [metadata : (& metadata tlci_core.TlciMetadata)]) : String
  (if (string.eq metadata.version (tlci_core.tlci-metadata-version-v2-current))
    (str_cat.str-cat
      "spmd-callables:\n"
      (tlci-inspect-spmd-callables metadata.spmd-callables))
    ""))

(define (tlci-inspect-source-binding [rodata : (__tl_dyn-array u8)]) : String
  (match (tlci_core.tlci-package-source-binding-read rodata)
    [(Bound digest)
      (str_cat.str-cat
        "source-set-binding-schema: "
        (string.int->string
          tlci_core.tlci-package-source-binding-schema-version)
        "\n"
        "source-set-digest: "
        (string.int->string digest)
        "\n")]
    [(MissingOrLegacy)
      "source-set-binding-schema: missing-or-legacy\nsource-set-digest: unavailable\n"]
    [(UnsupportedSchema schema)
      (str_cat.str-cat
        "source-set-binding-schema: unsupported ("
        (string.int->string schema)
        ")\n"
        "source-set-digest: unavailable\n")]
    [(Malformed message)
      (str_cat.str-cat
        "source-set-binding-schema: malformed\n"
        "source-set-digest: unavailable\n"
        "source-set-binding-error: "
        message
        "\n")]))

(define (tlci-inspect-surface-section
  [name : String]
  [rodata : (& rodata (__tl_dyn-array u8))]
  [kind : i64]) : String
  (match (tlci_core.tlci-aux-find rodata kind)
    [(Missing) (str_cat.str-cat name ": missing\n")]
    [(Err message)
      (str_cat.str-cat
        (owned_view.compiler-owned-shared-view name)
        ": malformed\n"
        name
        "-error: "
        message
        "\n")]
    [(Ok schema payload)
      (str_cat.str-cat
        name
        ": present schema-version="
        (string.int->string schema)
        " bytes="
        (string.int->string (array-length payload))
        "\n")]))

(define (tlci-inspect-surface
  [rodata : (__tl_dyn-array u8)]
  [producer-identity : String]) : String
  (str_cat.str-cat
    (tlci-inspect-surface-section
      "surface-package-identity"
      rodata
      tlci_core.tlci-aux-kind-package-identity)
    (tlci-inspect-surface-section
      "surface-frontend-ast"
      rodata
      tlci_core.tlci-aux-kind-frontend-ast)
    (tlci-inspect-surface-section
      "surface-frontend-facts"
      rodata
      tlci_core.tlci-aux-kind-frontend-facts)
    "surface-trust-producer-identity: "
    producer-identity
    "\n"
    "surface-trust-policy: exact-producer-and-source-binding-required\n"))

(define (tlci-inspect-render
  [bytes : (__tl_dyn-array u8)]
  [image : tlci_core.TlciImage]) : String
  (let
    [metadata : tlci_core.TlciMetadata image.metadata]
    [host-platform : i64 image.host-platform]
    (str_cat.str-cat
      "tlci image\n"
      "format-version: "
      (string.int->string
        (tlci_core.tlci-read-u64
          bytes
          tlci_core.tlci-format-version-field-offset))
      "\n"
      "host-platform: "
      (tlci_core.tlci-host-platform-name host-platform)
      " ("
      (string.int->string host-platform)
      ")\n"
      "image-classification: "
      (tlci-inspect-classification-name image)
      "\n"
      "callback-abi-version: "
      (string.int->string image.callback-abi-version)
      "\n"
      "producer-compiler-identity: "
      (owned_view.compiler-owned-shared-view image.compiler-build-hash)
      "\n"
      (tlci-inspect-source-binding
        (owned_view.compiler-owned-shared-view image.rodata))
      (tlci-inspect-surface image.rodata image.compiler-build-hash)
      "content-hash: "
      (string.int->string
        (tlci_core.tlci-read-u64 bytes tlci_core.tlci-hash-field-offset))
      "\n"
      "file-size: "
      (string.int->string
        (tlci_core.tlci-read-u64 bytes tlci_core.tlci-file-size-field-offset))
      "\n"
      "metadata-version: "
      metadata.version
      "\n"
      "package-name: "
      metadata.package-name
      "\n"
      "package-version: "
      (owned_view.compiler-owned-shared-view metadata.package-version)
      "\n"
      (tlci-inspect-spmd-section metadata)
      "sections:\n"
      (tlci-inspect-section-line
        "compiler-build-hash"
        (tlci_core.tlci-read-u64 bytes 32)
        (tlci_core.tlci-read-u64 bytes 40))
      (tlci-inspect-section-line
        "metadata"
        (tlci_core.tlci-read-u64 bytes 56)
        (tlci_core.tlci-read-u64 bytes 64))
      (tlci-inspect-section-line
        "rodata"
        (tlci_core.tlci-read-u64 bytes 72)
        (tlci_core.tlci-read-u64 bytes 80))
      (tlci-inspect-section-line
        "code"
        (tlci_core.tlci-read-u64 bytes 88)
        (tlci_core.tlci-read-u64 bytes 96))
      (tlci-inspect-table-line
        "fixups"
        (tlci_core.tlci-read-u64 bytes 104)
        (tlci_core.tlci-read-u64 bytes 112)
        tlci_core.tlci-section-fixup-record-size)
      (tlci-inspect-table-line
        "entries"
        (tlci_core.tlci-read-u64 bytes 120)
        (tlci_core.tlci-read-u64 bytes 128)
        tlci_core.tlci-section-entry-record-size)
      (tlci-inspect-table-line
        "symbols"
        (tlci_core.tlci-read-u64 bytes 136)
        (tlci_core.tlci-read-u64 bytes 144)
        tlci_core.tlci-section-symbol-record-size)
      (tlci-inspect-import-line
        (tlci_core.tlci-read-u64
          bytes
          tlci_core.tlci-import-section-field-offset)
        (tlci_core.tlci-read-u64 bytes tlci_core.tlci-import-count-field-offset)
        (array-length image.imports)))))

(define (tlci-inspect-error [path : String] [message : String]) : String
  (str_cat.str-cat "inspect: " path ": " message "\n"))

(define (tlci-inspect-render-bytes
  [path : String]
  [bytes : (__tl_dyn-array u8)]) : i64
  (match (tlci_core.tlci-parse-image
    (owned_view.compiler-owned-shared-view bytes))
    [(Err message)
      (begin
        (io.print-error (tlci-inspect-error path message))
        1)]
    [(Ok image)
      (begin
        (io.print-format "{}" (tlci-inspect-render bytes image))
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
    (match (compiler_embedded_stdlib_tlci.compiler-embedded-stdlib-tlci-validate)
      [(Err message)
        (begin
          (io.print-error (tlci-inspect-error "embedded:stdlib.tlci" message))
          1)]
      [(Ok count)
        (begin
          (io.print-format
            "{}"
            (str_cat.str-cat
              "embedded-loader-macro-count: "
              (string.int->string count)
              "\n"))
          (tlci-inspect-render-bytes
            "embedded:stdlib.tlci"
            (compiler_embedded_stdlib_tlci.compiler-embedded-stdlib-tlci-copy)))])))

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
          [(ErrIoBytes error)
            (begin
              (io.print-error
                (tlci-inspect-error path (io.error-message error)))
              1)]
          [(OkIoBytes contents)
            (tlci-inspect-render-bytes path (byte_buf.to-array contents))])))))