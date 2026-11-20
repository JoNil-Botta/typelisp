;; Catalog envelope coverage: the stored model, the frame index and the whole
;; stream, including malformed and truncated envelopes.
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.byte_buf_core as buf)
(import compiler_embedded_stdlib_tlci_codec as codec)
(import compiler_embedded_stdlib_tlci_frames as frames)
(import compiler_lzss as lzss)
(import tlci_core as tlci)

;; A frame image with the TLCI header shape the index records checksums for.
(define (tlci-codec-test-source) : (__tl_dyn-array u8)
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 256)]
    [index : i64 0]
    (while (< index 256)
      (set! (array-ref bytes index) (cast (% (+ (* index 7) 3) 251) : u8))
      (set! index (+ index 1)))
    (set! (array-ref bytes 0) (cast 84 : u8))
    (set! (array-ref bytes 1) (cast 76 : u8))
    ;; The index records this image's checksum word, which stays inside the
    ;; range the envelope format accepts.
    (tlci.tlci-set-u64! (&mut bytes) 48 1234)
    bytes))

(define (tlci-codec-test-push-bytes!
  [out : (&mut out buf.ByteBufBuilder)]
  [bytes : (& bytes (__tl_dyn-array u8))]) : unit
  (for [index (iterator.range 0 (array-length bytes))]
    (buf.byte-buf-builder-push (&mut out) (array-ref bytes index))))

(define (tlci-codec-test-encode-stream
  [source : (& source (__tl_dyn-array u8))]
  [model : (& model lzss.CompilerLzssModel)]) : String
  (let
    [text : String
      (tlci.tlci-bytes->string source 0 (array-length source))]
    [tokens : (__tl_dyn-array lzss.CompilerLzssToken)
      (lzss.compiler-lzss-tokenize (& text) model)]
    [writer : lzss.CompilerLzssWriter (lzss.compiler-lzss-writer)]
    (lzss.compiler-lzss-emit (& text) (& tokens) model (&mut writer))
    (lzss.compiler-lzss-finish-writer (&mut writer))))

;; One frame: the embedded model, a single record and the stream.
(define (tlci-codec-test-envelope
  [source : (& source (__tl_dyn-array u8))]
  [model : (& model lzss.CompilerLzssModel)]) : (__tl_dyn-array u8)
  (let
    [raw : i64 (array-length source)]
    [directory : i64 (codec.compiler-embedded-stdlib-tlci-codec-directory)]
    [record : i64 directory]
    [index-end : i64 (+ record (codec.compiler-embedded-stdlib-tlci-codec-record-bytes))]
    [stream : String (tlci-codec-test-encode-stream source model)]
    [stream-bytes : i64 (string.string-length (& stream))]
    [out : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    (buf.byte-buf-builder-append-string
      (&mut out)
      (codec.compiler-embedded-stdlib-tlci-codec-prefix))
    (tlci.tlci-push-u64! (&mut out) raw)
    (tlci.tlci-push-u64! (&mut out) index-end)
    (tlci.tlci-push-u64! (&mut out) 1)
    (tlci.tlci-push-u64! (&mut out) 0)
    (tlci.tlci-push-u64! (&mut out) stream-bytes)
    (buf.byte-buf-builder-append-string (&mut out) (string.copy (& lzss.compiler-lzss-fixed-spec)))
    ;; The single record: no name, the whole stream as frame zero.
    (tlci.tlci-push-u64! (&mut out) index-end)
    (tlci.tlci-push-u64! (&mut out) 0)
    (tlci.tlci-push-u64! (&mut out) 0)
    (tlci.tlci-push-u64! (&mut out) raw)
    (tlci.tlci-push-u64! (&mut out) 0)
    (tlci.tlci-push-u64! (&mut out) (tlci.tlci-read-u64 source 48))
    (buf.byte-buf-builder-append-string (&mut out) stream)
    (let
      [bytes : (__tl_dyn-array u8) (buf.byte-buf-builder-to-array (& out))]
      (tlci.tlci-set-u64!
        (&mut bytes)
        60
        (frames.compiler-embedded-stdlib-tlci-frames-index-hash
          (& bytes)
          index-end))
      bytes)))

(define (tlci-codec-test-rejects?
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : bool
  (match (frames.compiler-embedded-stdlib-tlci-frames-parse
    (& payload)
    raw-limit)
    [(Ok _) false]
    [(Err _) true]))

(define (tlci-codec-test-expands?
  [payload : (& payload (__tl_dyn-array u8))]
  [model : (& model lzss.CompilerLzssModel)]) : bool
  (let
    [catalog
      (match (frames.compiler-embedded-stdlib-tlci-frames-parse
        (& payload)
        268435456)
        [(Ok catalog) catalog]
        [(Err _) (return false)])]
    (match (frames.compiler-embedded-stdlib-tlci-frames-decode-images
      (& payload)
      catalog
      model)
      [(Ok images) true]
      [(Err _) false])))

(define (tlci-codec-test-truncated?
  [payload : (& payload (__tl_dyn-array u8))]
  [model : (& model lzss.CompilerLzssModel)]
  [len : i64]) : bool
  (let
    [cut : (__tl_dyn-array u8) (__tl_make-array u8 len)]
    (for [index (iterator.range 0 len)]
      (set! (array-ref cut index) (array-ref payload index)))
    ;; The index survives a truncated stream, so parse succeeds and the
    ;; expansion must fail.
    (match (frames.compiler-embedded-stdlib-tlci-frames-parse
      (& cut)
      268435456)
      [(Err _) true]
      [(Ok catalog)
        (match (frames.compiler-embedded-stdlib-tlci-frames-decode-images
          (& cut)
          catalog
          model)
          [(Ok _) false]
          [(Err _) true])])))

(define (tlci-codec-status) : i64
  (let
    [source : (__tl_dyn-array u8) (tlci-codec-test-source)]
    [model : lzss.CompilerLzssModel
      (lzss.compiler-lzss-model-from-spec (& lzss.compiler-lzss-fixed-spec))]
    [payload : (__tl_dyn-array u8)
      (tlci-codec-test-envelope (& source) (& model))]
    [catalog
      (match (frames.compiler-embedded-stdlib-tlci-frames-parse
        (& payload)
        268435456)
        [(Ok catalog) catalog]
        [(Err _) (return 12)])]
    [images
      (match (frames.compiler-embedded-stdlib-tlci-frames-decode-images
        (& payload)
        catalog
        (& model))
        [(Ok images) images]
        [(Err _) (return 13)])]
    (unless
      (codec.compiler-embedded-stdlib-tlci-codec-prefix?
        (& payload)
        (codec.compiler-embedded-stdlib-tlci-codec-prefix))
      (return 1))
    (unless (and (= catalog.count 1) (= (array-length images) 1))
      (return 2))
    (unless (= (array-length (array-ref images 0)) (array-length source))
      (return 3))
    ;; The decoded frame must be the source byte for byte.
    (for [index (iterator.range 0 (array-length source))]
      (unless
        (= (array-ref (array-ref images 0) index) (array-ref source index))
        (return 4)))
    ;; A frame name is never found when the envelope has no names.
    (unless
      (=
        (frames.compiler-embedded-stdlib-tlci-frames-find
          (& payload)
          catalog
          (& (string.copy "stdlib/string")))
        -1)
      (return 5))
    ;; A wrong marker is rejected.
    (let
      [broken : (__tl_dyn-array u8)
        (tlci-codec-test-envelope (& source) (& model))]
      (set! (array-ref broken 0) (cast 88 : u8))
      (unless (tlci-codec-test-rejects? (& broken) 268435456) (return 6)))
    ;; A frame count of zero is rejected.
    (let
      [broken : (__tl_dyn-array u8)
        (tlci-codec-test-envelope (& source) (& model))]
      (tlci.tlci-set-u64! (&mut broken) 52 0)
      (unless (tlci-codec-test-rejects? (& broken) 268435456) (return 7)))
    ;; The index must end inside the payload.
    (let
      [broken : (__tl_dyn-array u8)
        (tlci-codec-test-envelope (& source) (& model))]
      (tlci.tlci-set-u64! (&mut broken) 44 (+ (array-length broken) 8))
      (unless (tlci-codec-test-rejects? (& broken) 268435456) (return 8)))
    ;; The index hash and the frame checksum both reject tampering.
    (let
      [broken : (__tl_dyn-array u8)
        (tlci-codec-test-envelope (& source) (& model))]
      (tlci.tlci-set-u64! (&mut broken) 60 12345)
      (unless (tlci-codec-test-rejects? (& broken) 268435456) (return 9)))
    (let
      [broken : (__tl_dyn-array u8)
        (tlci-codec-test-envelope (& source) (& model))]
      (tlci.tlci-set-u64!
        (&mut broken)
        (+ (codec.compiler-embedded-stdlib-tlci-codec-directory) 40)
        7)
      (unless (tlci-codec-test-rejects? (& broken) 268435456) (return 10)))
    ;; A truncated stream is rejected by the decoder, not read past its end.
    (unless
      (tlci-codec-test-truncated?
        (& payload)
        (& model)
        (- (array-length payload) 1))
      (return 11))
    ;; A consumer raw limit below the envelope's raw length rejects first.
    (unless (tlci-codec-test-rejects? (& payload) 8) (return 14))
    0))

(test
  compiler-embedded-stdlib-tlci-payload-codec
  (if (= (tlci-codec-status) 0)
    unit
    (string.tl_oob_abort)))
