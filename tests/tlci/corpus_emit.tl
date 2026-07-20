;; Emit the two canonical valid images used by the TLCI format corpus. The
;; gate compares these bytes with the checked-in fixtures, so a synchronized
;; emitter/parser change cannot silently redefine the container format.
(import stdlib.io)
(import "../../src/tlci_core.tl")

(define (tlci-v1-corpus-empty-image) : TlciImage
  (tlci-make-image
    tlci-host-arch-x86-64
    tlci-callback-abi-version
    "tlci-v1-corpus"
    (tlci-make-metadata "v1" "corpus.empty" "1.0.0")
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)))

(define (tlci-v1-corpus-sections-image) : TlciImage
  (let
    [fixups : (Array u8) (make-array u8 tlci-section-fixup-record-size)]
    [entries : (Array u8) (make-array u8 tlci-section-entry-record-size)]
    [symbols : (Array u8) (make-array u8 tlci-section-symbol-record-size)]
    (begin
      ;; One inert load-base fixup, entry, and symbol record. The fixture is
      ;; parsed and inspected, never mapped or executed.
      (tlci-set-u64! fixups 0 0)
      (tlci-set-u64! entries 0 0)
      (tlci-set-u64! entries 8 0)
      (tlci-set-u64! entries 16 0)
      (tlci-set-u64! symbols 0 0)
      (tlci-set-u64! symbols 8 0)
      (tlci-set-u64! symbols 16 2)
      (tlci-set-u64! symbols 24 0)
      (tlci-set-u64! symbols 32 3)
      (tlci-make-image
        tlci-host-arch-x86-64
        tlci-callback-abi-version
        "tlci-v1-corpus"
        (tlci-make-metadata "v1" "corpus.sections" "1.0.0")
        (make-array
          (tlci-byte 222)
          (tlci-byte 173)
          (tlci-byte 190)
          (tlci-byte 239))
        (make-array (tlci-byte 195) (tlci-byte 144) (tlci-byte 144))
        fixups
        entries
        symbols
        (tlci-empty-bytes)))))

(define (tlci-v1-corpus-write [path : String] [result : ResultTlciBytes]) : i64
  (match result
    [(ResultTlciBytes.Err message)
      (begin
        (io.print-error message)
        1)]
    [(ResultTlciBytes.Ok bytes)
      (begin
        (io.write-file path (tlci-bytes->string bytes 0 (array-length bytes)))
        0)]))

(define (main) : i64
  (if (= (io.arg-count) 1)
    0
    (if (not (= (io.arg-count) 3))
      (begin
        (io.print-error
          "tlci v1 corpus emitter: expected metadata and sections output paths\n")
        2)
      (let
        [empty-status : i64
          (tlci-v1-corpus-write
            (io.arg 1)
            (tlci-emit-image (tlci-v1-corpus-empty-image)))]
        (if (not (= empty-status 0))
          empty-status
          (tlci-v1-corpus-write
            (io.arg 2)
            (tlci-emit-image (tlci-v1-corpus-sections-image))))))))