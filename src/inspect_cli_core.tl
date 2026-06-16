;; inspect_cli_core.tl - Public tlci inspection command (#2655).
(import "../stdlib/io.tl")
(import "../stdlib/string.tl")
(import "../stdlib/str_cat.tl")
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
  (str-cat
    "  "
    name
    ": offset="
    (int->string offset)
    " bytes="
    (int->string len)
    "\n"))

(define (tlci-inspect-table-line
  [name : String]
  [offset : i64]
  [count : i64]
  [record-size : i64]) : String
  (str-cat
    "  "
    name
    ": offset="
    (int->string offset)
    " records="
    (int->string count)
    " bytes="
    (int->string (* count record-size))
    "\n"))

(define (tlci-inspect-export-line [entry : TlciExport]) : String
  (match (struct-get entry kind)
    [(TlciExportValue)
      (str-cat
        "  value "
        (struct-get entry name)
        " signature="
        (struct-get entry signature)
        "\n")]
    [(TlciExportType)
      (str-cat
        "  type "
        (struct-get entry name)
        " layout="
        (struct-get entry layout)
        "\n")]
    [(TlciExportMacro)
      (str-cat
        "  macro "
        (struct-get entry name)
        " signature="
        (struct-get entry signature)
        "\n")]))

(define (tlci-inspect-export-list-empty? [exports : TlciExportList]) : bool
  (match exports
    [(TlciExportNil) true]
    [_ false]))

(define (tlci-inspect-export-lines [exports : TlciExportList]) : String
  (match exports
    [(TlciExportNil) ""]
    [(TlciExportCons entry rest)
      (str-cat
        (tlci-inspect-export-line entry)
        (tlci-inspect-export-lines (box-get rest)))]))

(define (tlci-inspect-exports [exports : TlciExportList]) : String
  (if (tlci-inspect-export-list-empty? exports)
    "  (none)\n"
    (tlci-inspect-export-lines exports)))

(define (tlci-inspect-render [bytes : (Array u8)] [image : TlciImage]) : String
  (let
    [metadata : TlciMetadata (struct-get image metadata)]
    [host-arch : i64 (struct-get image host-arch)]
    (str-cat
      "tlci image\n"
      "format-version: "
      (int->string (tlci-read-u64 bytes 8))
      "\n"
      "host-arch: "
      (tlci-inspect-host-arch-name host-arch)
      " ("
      (int->string host-arch)
      ")\n"
      "callback-abi-version: "
      (int->string (struct-get image callback-abi-version))
      "\n"
      "compiler-build-hash: "
      (struct-get image compiler-build-hash)
      "\n"
      "content-hash: "
      (int->string (tlci-read-u64 bytes 48))
      "\n"
      "file-size: "
      (int->string (tlci-read-u64 bytes 152))
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
        tlci-section-symbol-record-size)
      "exports:\n"
      (tlci-inspect-exports (struct-get metadata exports)))))

(define (tlci-inspect-run-from [idx : i64] [count : i64]) : i64
  (if (not (= count (+ idx 1)))
    (begin
      (print-error "inspect: expected one .tlci path\n")
      1)
    (let
      [path : String (arg idx)]
      (match (try-read-file (& path))
        [(ErrIoString error)
          (begin
            (print-error (str-cat "inspect: " (io-error-message error) "\n"))
            1)]
        [(OkIoString contents)
          (let
            [bytes : (Array u8) (tlci-string->bytes contents)]
            (match (tlci-parse-image bytes)
              [(ErrTlciImage message)
                (begin
                  (print-error (str-cat "inspect: " message "\n"))
                  1)]
              [(OkTlciImage image)
                (begin
                  (print-string (tlci-inspect-render bytes image))
                  0)]))]))))