;; inspect_cli_core.tl - Public tlci inspection command.
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import "tlci_core.tl")

(define (tlci-inspect-help-text) : String
  "Usage:
    typelisp inspect <file.tlci>

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

(define (tlci-inspect-render [bytes : (Array u8)] [image : TlciImage]) : String
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
      "compiler-build-hash: "
      (struct-get image compiler-build-hash)
      "\n"
      "content-hash: "
      (string.int->string (tlci-read-u64 bytes 48))
      "\n"
      "file-size: "
      (string.int->string (tlci-read-u64 bytes 152))
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
        tlci-section-symbol-record-size))))

(define (tlci-inspect-error [path : String] [message : String]) : String
  (str_cat.str-cat "inspect: " path ": " message "\n"))

(cfg
  test
  (test
    tlci-inspect-error-includes-path
    (unless
      (string.eq
        (tlci-inspect-error "pkg/dep.tlci" "tlci: content hash mismatch")
        "inspect: pkg/dep.tlci: tlci: content hash mismatch\n")
      (io.panic "inspect error formatting failed"))))

(define (tlci-inspect-run-from [idx : i64] [count : i64]) : i64
  (if (not (= count (+ idx 1)))
    (begin
      (io.print-error "inspect: expected one .tlci path\n")
      1)
    (let
      [path : String (io.arg idx)]
      (match (io.try-read-file (& path))
        [(io.ErrIoString error)
          (begin
            (io.print-error (tlci-inspect-error path (io.error-message error)))
            1)]
        [(io.OkIoString contents)
          (let
            [bytes : (Array u8) (tlci-string->bytes contents)]
            (match (tlci-parse-image bytes)
              [(ResultTlciImage.Err message)
                (begin
                  (io.print-error (tlci-inspect-error path message))
                  1)]
              [(ResultTlciImage.Ok image)
                (begin
                  (io.print-string (tlci-inspect-render bytes image))
                  0)]))]))))