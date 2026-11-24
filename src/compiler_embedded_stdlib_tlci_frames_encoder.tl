;; Build-only encoder for independently loadable native entries and one surface.
(import stdlib.clone)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.byte_buf_core as buf)
(import compiler_embedded_stdlib_tlci_encoder as encoder)
(import compiler_lzss as lzss)
(import compiler_embedded_stdlib_tlci_frames as frames)
(import compiler_embedded_stdlib_tlci_codec as codec)
(import compiler_tlci_native_producer as producer)
(import tlci_core as tlci)

(defenum ResultCompilerEmbeddedStdlibTlciFramesBuild
  (Err String)
  (Ok (__tl_dyn-array u8) (__tl_dyn-array u8)))

(define (compiler-embedded-stdlib-tlci-frames-source
  [image : (& image (__tl_dyn-array u8))]) : String
  (tlci.tlci-bytes->string image 0 (array-length image)))

(define (compiler-embedded-stdlib-tlci-frames-group-end
  [count : i64]
  [group : i64]) : i64
  (let
    [first : i64 (codec.compiler-embedded-stdlib-tlci-codec-group-first group)]
    [end : i64
      (if (= group 0)
        (+ first 1)
        (+ first (codec.compiler-embedded-stdlib-tlci-codec-group-frames)))]
    (if (< end count)
      end
      count)))

;; One group's frames back to back: a group is one window, so a match may reach
;; back into the frames before it but never across groups.
(define (compiler-embedded-stdlib-tlci-frames-group-source
  [images : (& images (__tl_dyn-array (__tl_dyn-array u8)))]
  [group : i64]) : String
  (let
    [count : i64 (array-length images)]
    [end : i64 (compiler-embedded-stdlib-tlci-frames-group-end count group)]
    [index : i64 (codec.compiler-embedded-stdlib-tlci-codec-group-first group)]
    [out : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    (while (< index end)
      (buf.byte-buf-builder-append-array-range
        (&mut out)
        (& (array-ref images index))
        0
        (array-length (array-ref images index)))
      (set! index (+ index 1)))
    (buf.byte-buf-builder-to-string (& out))))

;; Re-price every group with the model these code lengths describe, then return
;; the lengths of the token stream that model produced.
(define (compiler-embedded-stdlib-tlci-frames-refine
  [images : (& images (__tl_dyn-array (__tl_dyn-array u8)))]
  [lengths : (__tl_dyn-array i64)]) : (__tl_dyn-array i64)
  (let
    [model : lzss.CompilerLzssModel
      (lzss.compiler-lzss-model-from-lengths (clone.deep lengths))]
    [counts : encoder.CompilerEmbeddedStdlibTlciEncoderFrequencies
      (encoder.compiler-embedded-stdlib-tlci-encoder-frequencies)]
    [groups : i64
      (codec.compiler-embedded-stdlib-tlci-codec-group-count
        (array-length images))]
    [group : i64 0]
    (while (< group groups)
      (let
        [source : String
          (compiler-embedded-stdlib-tlci-frames-group-source images group)]
        [tokens : (__tl_dyn-array lzss.CompilerLzssToken)
          (lzss.compiler-lzss-tokenize (& source) (& model))]
        (encoder.compiler-embedded-stdlib-tlci-encoder-count!
          (&mut counts)
          (& source)
          (& tokens)))
      (set! group (+ group 1)))
    (encoder.compiler-embedded-stdlib-tlci-encoder-lengths (& counts))))

(define (compiler-embedded-stdlib-tlci-frames-encode
  [images : (& images (__tl_dyn-array (__tl_dyn-array u8)))]
  [names : (& names (__tl_dyn-array String))]) : ResultCompilerEmbeddedStdlibTlciFramesBuild
  (let
    [count : i64 (array-length images)]
    [raw-total : i64 0]
    [name-bytes : i64 0]
    [index : i64 0]
    (unless
      (= count (+ (array-length names) 1))
      (return (Err "embedded stdlib tlci frames: frame/name count mismatch")))
    ;; Pass one: tokenize every group under the fixed model and count symbols;
    ;; each frame's raw length still comes from its own image.
    (while (< index count)
      (let
        [source : String
          (compiler-embedded-stdlib-tlci-frames-source
            (& (array-ref images index)))]
        (+= raw-total (string.string-length (& source))))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index (array-length names))
      (+= name-bytes (string.string-length (array-ref names index)))
      (set! index (+ index 1)))
    (let
      [groups : i64
        (codec.compiler-embedded-stdlib-tlci-codec-group-count count)]
      [frequencies : encoder.CompilerEmbeddedStdlibTlciEncoderFrequencies
        (encoder.compiler-embedded-stdlib-tlci-encoder-frequencies)]
      (set! index 0)
      (while (< index groups)
        (let
          [source : String
            (compiler-embedded-stdlib-tlci-frames-group-source images index)]
          [tokens : (__tl_dyn-array lzss.CompilerLzssToken)
            (lzss.compiler-lzss-tokenize
              (& source)
              (& lzss.compiler-lzss-fixed-model))]
          (encoder.compiler-embedded-stdlib-tlci-encoder-count!
            (&mut frequencies)
            (& source)
            (& tokens)))
        (set! index (+ index 1)))
      ;; Refine twice: each model re-prices the tokenizer that produced it.
      (let
        [first-lengths
          (encoder.compiler-embedded-stdlib-tlci-encoder-lengths
            (& frequencies))]
        [refined-once
          (compiler-embedded-stdlib-tlci-frames-refine images first-lengths)]
        [lengths
          (compiler-embedded-stdlib-tlci-frames-refine images refined-once)]
        [spec (encoder.compiler-embedded-stdlib-tlci-encoder-spec (& lengths))]
        [model : lzss.CompilerLzssModel
          (lzss.compiler-lzss-model-from-lengths (clone.deep lengths))]
        [record-bytes : i64
          (frames.compiler-embedded-stdlib-tlci-frames-record-bytes)]
        [directory : i64
          (codec.compiler-embedded-stdlib-tlci-codec-directory groups)]
        [index-end : i64 (+ (+ directory (* count record-bytes)) name-bytes)]
        [name-cursor : i64 (+ directory (* count record-bytes))]
        [out : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
        [stream : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
        [group-stream-offset : i64 0]
        [group-raw-offset : i64 0]
        [raw-offset : i64 0]
        (buf.byte-buf-builder-append-string
          (&mut out)
          (frames.compiler-embedded-stdlib-tlci-frames-prefix))
        (tlci.tlci-push-u64! (&mut out) raw-total)
        (tlci.tlci-push-u64! (&mut out) index-end)
        (tlci.tlci-push-u64! (&mut out) count)
        (tlci.tlci-push-u64! (&mut out) 0)
        (tlci.tlci-push-u64! (&mut out) 0)
        (tlci.tlci-push-u64! (&mut out) groups)
        (buf.byte-buf-builder-append-string (&mut out) spec)
        ;; Tokenize and emit one group at a time, recording its stream range.
        (set! index 0)
        (while (< index groups)
          (let
            [source : String
              (compiler-embedded-stdlib-tlci-frames-group-source images index)]
            [tokens : (__tl_dyn-array lzss.CompilerLzssToken)
              (lzss.compiler-lzss-tokenize (& source) (& model))]
            [writer : lzss.CompilerLzssWriter (lzss.compiler-lzss-writer)]
            (lzss.compiler-lzss-emit
              (& source)
              (& tokens)
              (& model)
              (&mut writer))
            (let
              [bytes : String (lzss.compiler-lzss-finish-writer (&mut writer))]
              [bytes-len : i64 (string.string-length (& bytes))]
              [raw-group-len : i64 (string.string-length (& source))]
              (tlci.tlci-push-u64! (&mut out) group-stream-offset)
              (tlci.tlci-push-u64! (&mut out) bytes-len)
              (tlci.tlci-push-u64! (&mut out) group-raw-offset)
              (tlci.tlci-push-u64! (&mut out) raw-group-len)
              (buf.byte-buf-builder-append-string (&mut stream) bytes)
              (+= group-stream-offset bytes-len)
              (+= group-raw-offset raw-group-len)))
          (set! index (+ index 1)))
        (set! index 0)
        (while (< index count)
          (let
            [name-len : i64
              (if (= index 0)
                0
                (string.string-length (array-ref names (- index 1))))]
            [source : String
              (compiler-embedded-stdlib-tlci-frames-source
                (& (array-ref images index)))]
            (tlci.tlci-push-u64! (&mut out) name-cursor)
            (tlci.tlci-push-u64! (&mut out) name-len)
            (tlci.tlci-push-u64! (&mut out) raw-offset)
            (tlci.tlci-push-u64! (&mut out) (string.string-length (& source)))
            (tlci.tlci-push-u64!
              (&mut out)
              (frames.compiler-embedded-stdlib-tlci-frames-group-of index))
            (tlci.tlci-push-u64!
              (&mut out)
              (tlci.tlci-read-u64 (& (array-ref images index)) 48))
            (+= name-cursor name-len)
            (+= raw-offset (string.string-length (& source))))
          (set! index (+ index 1)))
        (set! index 0)
        (while (< index (array-length names))
          (buf.byte-buf-builder-append-string
            (&mut out)
            (string.copy (& (array-ref names index))))
          (set! index (+ index 1)))
        (let
          [stream-bytes : i64 (buf.byte-buf-builder-len (& stream))]
          (tlci.tlci-set-u64! (&mut out.slots) 68 stream-bytes)
          (buf.byte-buf-builder-append-array-range
            (&mut out)
            (& stream.slots)
            0
            stream-bytes))
        (let
          [bytes : (__tl_dyn-array u8) (buf.byte-buf-builder-to-array (& out))]
          (tlci.tlci-set-u64!
            (&mut bytes)
            60
            (frames.compiler-embedded-stdlib-tlci-frames-index-hash
              (& bytes)
              index-end))
          (Ok (__tl_make-array u8 0) bytes))))))

;; Sort identities once; runtime lookup can binary-search the authenticated index.
(define (compiler-embedded-stdlib-tlci-frames-build
  [context : (& context producer.TlciNativeSourceContext)]
  [metadata-text : String]
  [build-hash : String]
  [windows-target : bool]
  [rodata : (__tl_dyn-array u8)]
  [names : (& names (__tl_dyn-array String))]
  [captures : (& captures producer.TlciNativeMacroCaptures)]) : ResultCompilerEmbeddedStdlibTlciFramesBuild
  (let
    [count : i64 (array-length names)]
    [sorted : (__tl_dyn-array String) (__tl_make-array String count)]
    [images : (__tl_dyn-array (__tl_dyn-array u8))
      (__tl_make-array (__tl_dyn-array u8) (+ count 1))]
    [metadata (try (tlci.tlci-metadata-parse (& metadata-text)))]
    [surface
      (try
        (tlci.tlci-emit-image
          (&
            (tlci.tlci-make-image
              (if windows-target
                tlci.tlci-host-platform-x86-64-windows
                tlci.tlci-host-platform-x86-64-linux)
              tlci.tlci-callback-abi-version
              (string.copy (& build-hash))
              metadata
              rodata
              (tlci.tlci-empty-bytes)
              (tlci.tlci-empty-bytes)
              (tlci.tlci-empty-bytes)
              (tlci.tlci-empty-bytes)
              (tlci.tlci-empty-bytes)))))]
    (set! (array-ref images 0) surface)
    (for [index (iterator.range 0 count)]
      (set! (array-ref sorted index) (string.copy (& (array-ref names index)))))
    (for [index (iterator.range 1 count)]
      (let
        [cursor : i64 index]
        (while (and
          (> cursor 0)
          (<
            (tlci.tlci-string-compare
              (& (array-ref sorted cursor))
              (& (array-ref sorted (- cursor 1))))
            0))
          (let
            [name : String (string.copy (& (array-ref sorted cursor)))]
            (set!
              (array-ref sorted cursor)
              (string.copy (& (array-ref sorted (- cursor 1)))))
            (set! (array-ref sorted (- cursor 1)) name))
          (-= cursor 1))))
    (for [index (iterator.range 1 count)]
      (when
        (string.eq (array-ref sorted (- index 1)) (array-ref sorted index))
        (return (Err "embedded stdlib tlci frames: duplicate native identity"))))
    (for [index (iterator.range 0 count)]
      (let
        [bytes
          (try
            (with-scratch
              (unsafe
                ;; unsafe: the native report strings are read before this arena ends
                (producer.embedded-native-emit-package
                  context
                  (string.copy (& metadata-text))
                  (string.copy (& build-hash))
                  windows-target
                  (tlci.tlci-empty-bytes)
                  (__tl_make-array (string.copy (& (array-ref sorted index))))
                  captures))))]
        (set! (array-ref images (+ index 1)) bytes)))
    (let
      [ordinary
        (try
          (frames.compiler-embedded-stdlib-tlci-frames-aggregate
            (& images)
            (& sorted)))]
      [packed
        (match (compiler-embedded-stdlib-tlci-frames-encode
          (& images)
          (& sorted))
          [(Ok empty packed) packed]
          [(Err message) (return (Err message))])]
      (Ok ordinary packed))))