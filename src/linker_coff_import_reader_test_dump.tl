;; Test-only stable projection. Validated names cannot contain tabs/newlines;
;; numeric physical IDs replace host addresses and filesystem spellings.
(import linker_coff_import_reader as coff)
(import stdlib.format)
(import stdlib.str_cat_runtime as cat)

(define (error-name [kind : (& k coff.CoffImportErrorKind)]) : String
  (match kind
    [(InvalidLimits) "invalid-limits"]
    [(InvalidMember) "invalid-member"]
    [(InputLimit) "input-limit"]
    [(NameLimit) "name-limit"]
    [(OutputLimit) "output-limit"]
    [(WorkLimit) "work-limit"]
    [(MalformedHeader) "malformed-header"]
    [(UnsupportedVersion) "unsupported-version"]
    [(UnsupportedMachine) "unsupported-machine"]
    [(UnsupportedKind) "unsupported-kind"]
    [(ReservedBits) "reserved-bits"]
    [(UnsupportedNameMode) "unsupported-name-mode"]
    [(UnsupportedExportAs)
      "unsupported IMPORT_NAME_EXPORTAS (supported NameType: 0..3)"]
    [(SizeMismatch) "size-mismatch"]
    [(UnterminatedString) "unterminated-string"]
    [(InvalidName) "invalid-name"]
    [(TrailingData) "trailing-data"]
    [(ZeroOrdinal) "zero-ordinal"]))

(define (dump [result : (& r coff.CoffImportReadResult)] [complete : bool]) : String
  (match result
    [(OrdinaryCoff) "COFF\n"]
    [(BigObj) "BIGOBJ\n"]
    [(ReadFailed error)
      (format.format
        "E\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
        error.member.archive.input
        error.member.archive.content
        error.member.ordinal
        error.member.header-offset
        error.field
        error.offset
        (error-name (& error.kind)))]
    [(ShortImport record)
      (cat.str-cat
        (if complete
          (format.format
            "P\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
            record.member.archive.input
            record.member.archive.content
            record.member.ordinal
            record.member.header-offset
            record.timestamp
            record.plan.name-mode
            record.plan.hint
            record.public-offset
            record.dll-offset)
          "")
        (format.format
          "K\t{}\t{}\t{}\t{}\t{}\t{}\n"
          record.dll-key
          record.plan.kind
          record.plan.public-name
          record.iat-symbol
          record.plan.import-name
          record.plan.ordinal))]))