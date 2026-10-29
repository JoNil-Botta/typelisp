;; Prove that the deployment envelope expands to the exact ordinary TLCI bytes.
(import compiler_embedded_stdlib_tlci_codec as codec)
(import compiler_embedded_stdlib_tlci_frames as frames)
(import stdlib.byte_buf)
(import tlci_core as tlci)
(import compiler_owned_view as view)
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)

(define (embedded-stdlib-tlci-envelope-eq?
  [left : (& left (__tl_dyn-array u8))]
  [right : (& right (__tl_dyn-array u8))]) : bool
  (let
    [index : i64 0]
    [same : bool (= (array-length left) (array-length right))]
    (while (and same (< index (array-length left)))
      (if (!= (array-ref left index) (array-ref right index))
        (set! same false)
        unit)
      (set! index (+ index 1)))
    same))

(define (embedded-stdlib-tlci-indexed-integrity-ok?
  [envelope : (& envelope (__tl_dyn-array u8))]) : bool
  (match (frames.compiler-embedded-stdlib-tlci-frames-parse envelope 268435456)
    [(Err _) false]
    [(Ok catalog)
      ;; Alter the authenticated checksum binding, then one meaningful bit of
      ;; each endpoint frame. None may produce a valid ordinary catalog.
      (for [case (iterator.range 0 3)]
        (let
          [changed : (__tl_dyn-array u8)
            (clone (view.compiler-owned-reference-shared-view envelope))]
          [record : i64
            (frames.compiler-embedded-stdlib-tlci-frames-record
              (if (= case 2)
                (- catalog.count 1)
                0))]
          [offset : i64
            (if (= case 0)
              (+ record 40)
              (tlci.tlci-read-u64 envelope (+ record 16)))]
          (set!
            (array-ref changed offset)
            (cast (bit-xor (cast (array-ref changed offset) : i64) 128) : u8))
          (when
            (= case 0)
            (tlci.tlci-set-u64!
              (&mut changed)
              60
              (frames.compiler-embedded-stdlib-tlci-frames-index-hash
                (& changed)
                catalog.index-end)))
          (match (frames.compiler-embedded-stdlib-tlci-frames-expand
            (& changed)
            268435456)
            [(Err _) unit]
            [(Ok _) (return false)])))
      true]))

(define (main) : i64
  (if (!= (io.arg-count) 3)
    (begin
      (io.print-error "usage: verify-envelope <input.tlci> <input.tlch>\n")
      2)
    (let
      [raw : (__tl_dyn-array u8) (byte_buf.to-array (io.read-file (io.arg 1)))]
      [envelope : (__tl_dyn-array u8)
        (byte_buf.to-array (io.read-file (io.arg 2)))]
      (match (if (codec.compiler-embedded-stdlib-tlci-codec-prefix?
        (& envelope)
        (frames.compiler-embedded-stdlib-tlci-frames-prefix))
        (frames.compiler-embedded-stdlib-tlci-frames-expand
          (& envelope)
          268435456)
        (match (codec.compiler-embedded-stdlib-tlci-codec-decode
          (& envelope)
          268435456)
          [(Ok bytes) (tlci.ResultTlciBytes.Ok bytes)]
          [(Err message) (tlci.ResultTlciBytes.Err message)]))
        [(Err message)
          (io.print-error (str_cat.str-cat message "\n"))
          1]
        [(Ok expanded)
          (if (and
            (embedded-stdlib-tlci-envelope-eq? (& raw) (& expanded))
            (if (codec.compiler-embedded-stdlib-tlci-codec-prefix?
              (& envelope)
              (frames.compiler-embedded-stdlib-tlci-frames-prefix))
              (embedded-stdlib-tlci-indexed-integrity-ok? (& envelope))
              true))
            0
            (begin
              (io.print-error
                "embedded stdlib tlci envelope: expanded bytes differ\n")
              1))]))))