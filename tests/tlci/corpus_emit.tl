;; Emit the two canonical valid images used by the TLCI format corpus. The
;; gate compares these bytes with the checked-in fixtures, so a synchronized
;; emitter/parser change cannot silently redefine the container format.
;; TLCI's internal byte sections intentionally retain private dynamic storage.
(import stdlib.byte_buf)
(import stdlib.io)
(import tlci_core)

;; These immutable fixtures predate the platform split and deliberately pin
;; the legacy/ambiguous host-platform value 1.
(define (tlci-v2-corpus-empty-image) : tlci_core.TlciImage
  (tlci_core.tlci-make-image
    tlci_core.tlci-host-platform-x86-64-legacy
    tlci_core.tlci-callback-abi-version
    "tlci-v2-corpus"
    (tlci_core.tlci-make-metadata "v1" "corpus.empty" "1.0.0")
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)))

(define (tlci-v2-corpus-sections-image) : tlci_core.TlciImage
  (let
    [fixups : (__tl_dyn-array u8)
      (__tl_make-array u8 tlci_core.tlci-section-fixup-record-size)]
    [entries : (__tl_dyn-array u8)
      (__tl_make-array u8 tlci_core.tlci-section-entry-record-size)]
    [symbols : (__tl_dyn-array u8)
      (__tl_make-array u8 tlci_core.tlci-section-symbol-record-size)]
    (begin
      ;; One inert load-base fixup, entry, and symbol record. The fixture is
      ;; parsed and inspected, never mapped or executed.
      (tlci_core.tlci-set-u64! fixups 0 0)
      (tlci_core.tlci-set-u64! entries 0 0)
      (tlci_core.tlci-set-u64! entries 8 0)
      (tlci_core.tlci-set-u64! entries 16 0)
      (tlci_core.tlci-set-u64! symbols 0 0)
      (tlci_core.tlci-set-u64! symbols 8 0)
      (tlci_core.tlci-set-u64! symbols 16 2)
      (tlci_core.tlci-set-u64! symbols 24 0)
      (tlci_core.tlci-set-u64! symbols 32 3)
      (tlci_core.tlci-make-image
        tlci_core.tlci-host-platform-x86-64-legacy
        tlci_core.tlci-callback-abi-version
        "tlci-v2-corpus"
        (tlci_core.tlci-make-metadata "v1" "corpus.sections" "1.0.0")
        (__tl_make-array
          (tlci_core.tlci-byte 222)
          (tlci_core.tlci-byte 173)
          (tlci_core.tlci-byte 190)
          (tlci_core.tlci-byte 239))
        (__tl_make-array
          (tlci_core.tlci-byte 195)
          (tlci_core.tlci-byte 144)
          (tlci_core.tlci-byte 144))
        fixups
        entries
        symbols
        (tlci_core.tlci-empty-bytes)))))

(define (tlci-v2-corpus-imports-image) : tlci_core.TlciImage
  (tlci_core.tlci-make-image
    tlci_core.tlci-host-platform-x86-64-legacy
    tlci_core.tlci-callback-abi-version
    "tlci-v2-corpus"
    (tlci_core.tlci-make-metadata "v1" "corpus.imports" "1.0.0")
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-test-imports-bytes)))

(define (tlci-v2-corpus-write
  [path : String]
  [result : tlci_core.ResultTlciBytes]) : i64
  (match result
    [(tlci_core.ResultTlciBytes.Err message)
      (begin
        (io.print-error message)
        1)]
    [(tlci_core.ResultTlciBytes.Ok bytes)
      (let
        [contents : byte_buf.ByteBuf (byte_buf.from-array bytes)]
        (begin
          (io.write-file path (byte_buf.as-bytes (& contents)))
          0))]))

(define (main) : i64
  (if (= (io.arg-count) 1)
    0
    (if (not (= (io.arg-count) 4))
      (begin
        (io.print-error
          "tlci v2 corpus emitter: expected metadata, sections, and imports output paths\n")
        2)
      (let
        [empty-status : i64
          (tlci-v2-corpus-write
            (io.arg 1)
            (tlci_core.tlci-emit-image-v2-legacy-compatible
              (tlci-v2-corpus-empty-image)))]
        (if (not (= empty-status 0))
          empty-status
          (let
            [sections-status : i64
              (tlci-v2-corpus-write
                (io.arg 2)
                (tlci_core.tlci-emit-image-v2-legacy-compatible
                  (tlci-v2-corpus-sections-image)))]
            (if (not (= sections-status 0))
              sections-status
              (tlci-v2-corpus-write
                (io.arg 3)
                (tlci_core.tlci-emit-image-v2-legacy-compatible
                  (tlci-v2-corpus-imports-image))))))))))