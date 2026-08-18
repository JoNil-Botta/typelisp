;; inspect_cli_core.tl - Public tlci inspection command.
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

(define (tlci-inspect-classification-name [image : tlci_core.TlciImage]) : String
  (match (tlci_core.tlci-image-classify image)
    [(tlci_core.TlciImageClassification.MetadataOnly) "metadata-only"]
    [(tlci_core.TlciImageClassification.CodeBearing) "code-bearing"]))

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

(define (tlci-inspect-spmd-callables [items : tlci_core.TlciSpmdCallables]) : String
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

(define (tlci-inspect-spmd-section [metadata : tlci_core.TlciMetadata]) : String
  (if (string.eq metadata.version (tlci_core.tlci-metadata-version-v2-current))
    (str_cat.str-cat
      "spmd-callables:\n"
      (tlci-inspect-spmd-callables metadata.spmd-callables))
    ""))

(define (tlci-inspect-source-binding [rodata : (__tl_dyn-array u8)]) : String
  (match (tlci_core.tlci-package-source-binding-read rodata)
    [(tlci_core.TlciPackageSourceBindingRead.Bound digest)
      (str_cat.str-cat
        "source-set-binding-schema: "
        (string.int->string
          tlci_core.tlci-package-source-binding-schema-version)
        "\n"
        "source-set-digest: "
        (string.int->string digest)
        "\n")]
    [(tlci_core.TlciPackageSourceBindingRead.MissingOrLegacy)
      "source-set-binding-schema: missing-or-legacy\nsource-set-digest: unavailable\n"]
    [(tlci_core.TlciPackageSourceBindingRead.UnsupportedSchema schema)
      (str_cat.str-cat
        "source-set-binding-schema: unsupported ("
        (string.int->string schema)
        ")\n"
        "source-set-digest: unavailable\n")]
    [(tlci_core.TlciPackageSourceBindingRead.Malformed message)
      (str_cat.str-cat
        "source-set-binding-schema: malformed\n"
        "source-set-digest: unavailable\n"
        "source-set-binding-error: "
        message
        "\n")]))

(define (tlci-inspect-surface-section
  [name : String]
  [rodata : (__tl_dyn-array u8)]
  [kind : i64]) : String
  (match (tlci_core.tlci-aux-find rodata kind)
    [(tlci_core.ResultTlciAuxLookup.Missing)
      (str_cat.str-cat name ": missing\n")]
    [(tlci_core.ResultTlciAuxLookup.Err message)
      (str_cat.str-cat name ": malformed\n" name "-error: " message "\n")]
    [(tlci_core.ResultTlciAuxLookup.Ok schema payload)
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
      image.compiler-build-hash
      "\n"
      (tlci-inspect-source-binding image.rodata)
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
      metadata.package-version
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
  (match (tlci_core.tlci-parse-image bytes)
    [(tlci_core.ResultTlciImage.Err message)
      (begin
        (io.print-error (tlci-inspect-error path message))
        1)]
    [(tlci_core.ResultTlciImage.Ok image)
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
      [(compiler_embedded_stdlib_tlci.CompilerEmbeddedStdlibTlciValidation.Err
          message)
        (begin
          (io.print-error (tlci-inspect-error "embedded:stdlib.tlci" message))
          1)]
      [(compiler_embedded_stdlib_tlci.CompilerEmbeddedStdlibTlciValidation.Ok
          count)
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
    tlci-inspect-source-binding-shapes
    (let
      [sections : (__tl_dyn-array tlci_core.TlciAuxSection)
        (__tl_make-array tlci_core.TlciAuxSection 1)]
      [bound : String ""]
      [unsupported : String ""]
      [malformed : String ""]
      [bound-schema : String "source-set-binding-schema: 1\n"]
      [bound-digest : String "source-set-digest: 12345\n"]
      [missing-schema : String "source-set-binding-schema: missing-or-legacy\n"]
      [missing-digest : String "source-set-digest: unavailable\n"]
      [unsupported-schema : String
        "source-set-binding-schema: unsupported (2)\n"]
      [malformed-schema : String "source-set-binding-schema: malformed\n"]
      (begin
        (set!
          (array-ref sections 0)
          (tlci_core.tlci-package-source-binding-section 12345))
        (match (tlci_core.tlci-aux-pack-rodata
          (tlci_core.tlci-empty-bytes)
          sections)
          [(tlci_core.ResultTlciAuxBytes.Ok packed)
            (set! bound (tlci-inspect-source-binding packed))]
          [_ unit])
        (set!
          (array-ref sections 0)
          (tlci_core.TlciAuxSection
            tlci_core.tlci-aux-kind-package-source-binding
            2
            (tlci_core.tlci-string->bytes "future")))
        (match (tlci_core.tlci-aux-pack-rodata
          (tlci_core.tlci-empty-bytes)
          sections)
          [(tlci_core.ResultTlciAuxBytes.Ok packed)
            (set! unsupported (tlci-inspect-source-binding packed))]
          [_ unit])
        (set!
          (array-ref sections 0)
          (tlci_core.TlciAuxSection
            tlci_core.tlci-aux-kind-package-source-binding
            tlci_core.tlci-package-source-binding-schema-version
            (__tl_make-array u8 7)))
        (match (tlci_core.tlci-aux-pack-rodata
          (tlci_core.tlci-empty-bytes)
          sections)
          [(tlci_core.ResultTlciAuxBytes.Ok packed)
            (set! malformed (tlci-inspect-source-binding packed))]
          [_ unit])
        (let
          [missing : String
            (tlci-inspect-source-binding (tlci_core.tlci-empty-bytes))]
          (if (and
            (string.contains (& bound) (& bound-schema))
            (string.contains (& bound) (& bound-digest))
            (string.contains (& missing) (& missing-schema))
            (string.contains (& missing) (& missing-digest))
            (string.contains (& unsupported) (& unsupported-schema))
            (string.contains (& malformed) (& malformed-schema)))
            unit
            (io.panic "inspect source binding rendering failed")))))))

(cfg
  test
  (test
    tlci-inspect-surface-shapes
    (let
      [sections : (__tl_dyn-array tlci_core.TlciAuxSection)
        (__tl_make-array tlci_core.TlciAuxSection 3)]
      (begin
        (set!
          (array-ref sections 0)
          (tlci_core.TlciAuxSection
            tlci_core.tlci-aux-kind-package-identity
            1
            (tlci_core.tlci-string->bytes "identity")))
        (set!
          (array-ref sections 1)
          (tlci_core.TlciAuxSection
            tlci_core.tlci-aux-kind-frontend-ast
            5
            (tlci_core.tlci-empty-bytes)))
        (set!
          (array-ref sections 2)
          (tlci_core.TlciAuxSection
            tlci_core.tlci-aux-kind-frontend-facts
            1
            (tlci_core.tlci-string->bytes "facts")))
        (match (tlci_core.tlci-aux-pack-rodata
          (tlci_core.tlci-empty-bytes)
          sections)
          [(tlci_core.ResultTlciAuxBytes.Err _)
            (io.panic "inspect surface fixture packing failed")]
          [(tlci_core.ResultTlciAuxBytes.Ok rodata)
            (let
              [rendered : String
                (tlci-inspect-surface
                  rodata
                  "0123456789abcdef0123456789abcdef01234567")]
              [identity-line : String
                "surface-package-identity: present schema-version=1 bytes=8\n"]
              [ast-line : String
                "surface-frontend-ast: present schema-version=5 bytes=0\n"]
              [facts-line : String
                "surface-frontend-facts: present schema-version=1 bytes=5\n"]
              [trust-line : String
                "surface-trust-policy: exact-producer-and-source-binding-required\n"]
              (unless
                (and
                  (string.contains (& rendered) (& identity-line))
                  (string.contains (& rendered) (& ast-line))
                  (string.contains (& rendered) (& facts-line))
                  (string.contains (& rendered) (& trust-line)))
                (io.panic "inspect surface rendering failed")))])))))

(cfg
  test
  (test
    tlci-inspect-imports-and-file-size
    (let
      [ok : bool
        (match (tlci_core.tlci-emit-image (tlci_core.tlci-test-imports-image))
          [(tlci_core.ResultTlciBytes.Err _) false]
          [(tlci_core.ResultTlciBytes.Ok bytes)
            (match (tlci_core.tlci-parse-image bytes)
              [(tlci_core.ResultTlciImage.Err _) false]
              [(tlci_core.ResultTlciImage.Ok parsed)
                (let
                  [rendered : String (tlci-inspect-render bytes parsed)]
                  [expected-file-size : String "file-size: 314\n"]
                  [expected-imports : String
                    "  imports: offset=272 records=1 bytes=42\n"]
                  [expected-platform : String
                    (str_cat.str-cat
                      "host-platform: "
                      (tlci_core.tlci-host-platform-name
                        (tlci_core.tlci-build-host-platform))
                      " ("
                      (string.int->string (tlci_core.tlci-build-host-platform))
                      ")"
                      "\n")]
                  [expected-classification : String
                    "image-classification: metadata-only\n"]
                  (and
                    (string.contains (& rendered) (& expected-file-size))
                    (string.contains (& rendered) (& expected-imports))
                    (string.contains (& rendered) (& expected-platform))
                    (string.contains (& rendered) (& expected-classification))))])])]
      (unless ok (io.panic "inspect import section rendering failed")))))

(cfg
  test
  (test
    tlci-inspect-v2-spmd-callables
    (let
      [image : tlci_core.TlciImage
        (tlci_core.tlci-make-image
          (tlci_core.tlci-build-host-platform)
          tlci_core.tlci-callback-abi-version
          "inspect-v2-test"
          (tlci_core.tlci-test-v2-metadata)
          (tlci_core.tlci-empty-bytes)
          (tlci_core.tlci-empty-bytes)
          (tlci_core.tlci-empty-bytes)
          (tlci_core.tlci-empty-bytes)
          (tlci_core.tlci-empty-bytes)
          (tlci_core.tlci-empty-bytes))]
      [ok : bool
        (match (tlci_core.tlci-emit-image image)
          [(tlci_core.ResultTlciBytes.Err _) false]
          [(tlci_core.ResultTlciBytes.Ok bytes)
            (match (tlci_core.tlci-parse-image bytes)
              [(tlci_core.ResultTlciImage.Err _) false]
              [(tlci_core.ResultTlciImage.Ok parsed)
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
          [(io.ErrIoBytes error)
            (begin
              (io.print-error
                (tlci-inspect-error path (io.error-message error)))
              1)]
          [(io.OkIoBytes contents)
            (tlci-inspect-render-bytes path (byte_buf.to-array contents))])))))