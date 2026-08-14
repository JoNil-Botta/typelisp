;; Emit the additive host-platform witnesses for the immutable TLCI v2 corpus.
;; The original value-1 fixtures remain unchanged so old-reader rejection and
;; legacy classification stay covered alongside the new enum values.
(import stdlib.byte_buf)
(import stdlib.io)
(import tlci_core)

(define (tlci-platform-corpus-image
  [platform : i64]
  [package-name : String]
  [code-bearing : bool]) : tlci_core.TlciImage
  (tlci_core.tlci-make-image
    platform
    tlci_core.tlci-callback-abi-version
    "tlci-v2-platform-corpus"
    (tlci_core.tlci-make-metadata "v1" package-name "1.0.0")
    (tlci_core.tlci-empty-bytes)
    (if code-bearing
      (__tl_make-array
        (tlci_core.tlci-byte 195)
        (tlci_core.tlci-byte 144)
        (tlci_core.tlci-byte 144))
      (tlci_core.tlci-empty-bytes))
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)
    (tlci_core.tlci-empty-bytes)))

(define (tlci-platform-corpus-write
  [path : String]
  [image : tlci_core.TlciImage]) : i64
  (match (tlci_core.tlci-emit-image image)
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

(define (tlci-platform-corpus-write-unknown [path : String]) : i64
  (match (tlci_core.tlci-emit-image
    (tlci-platform-corpus-image
      tlci_core.tlci-host-platform-x86-64-linux
      "corpus.platform-unknown"
      false))
    [(tlci_core.ResultTlciBytes.Err message)
      (begin
        (io.print-error message)
        1)]
    [(tlci_core.ResultTlciBytes.Ok bytes)
      (let
        [_unknown-platform : unit (tlci_core.tlci-set-u64! bytes 16 99)]
        [contents : byte_buf.ByteBuf (byte_buf.from-array bytes)]
        (begin
          (io.write-file path (byte_buf.as-bytes (& contents)))
          0))]))

(define (main) : i64
  (if (= (io.arg-count) 1)
    0
    (if (not (= (io.arg-count) 6))
      (begin
        (io.print-error
          "tlci platform corpus emitter: expected five output paths\n")
        2)
      (let
        [linux-metadata : i64
          (tlci-platform-corpus-write
            (io.arg 1)
            (tlci-platform-corpus-image
              tlci_core.tlci-host-platform-x86-64-linux
              "corpus.platform-metadata"
              false))]
        (if (not (= linux-metadata 0))
          linux-metadata
          (let
            [windows-metadata : i64
              (tlci-platform-corpus-write
                (io.arg 2)
                (tlci-platform-corpus-image
                  tlci_core.tlci-host-platform-x86-64-windows
                  "corpus.platform-metadata"
                  false))]
            (if (not (= windows-metadata 0))
              windows-metadata
              (let
                [linux-code : i64
                  (tlci-platform-corpus-write
                    (io.arg 3)
                    (tlci-platform-corpus-image
                      tlci_core.tlci-host-platform-x86-64-linux
                      "corpus.platform-code"
                      true))]
                (if (not (= linux-code 0))
                  linux-code
                  (let
                    [windows-code : i64
                      (tlci-platform-corpus-write
                        (io.arg 4)
                        (tlci-platform-corpus-image
                          tlci_core.tlci-host-platform-x86-64-windows
                          "corpus.platform-code"
                          true))]
                    (if (not (= windows-code 0))
                      windows-code
                      (tlci-platform-corpus-write-unknown (io.arg 5)))))))))))))