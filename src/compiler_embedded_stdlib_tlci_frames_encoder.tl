;; Build-only encoder for independently loadable native entries and one surface.
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.byte_buf_core as buf)
(import compiler_ctfe as ctfe)
(import compiler_embedded_stdlib_tlci_encoder as encoder)
(import compiler_embedded_stdlib_tlci_frames as frames)
(import compiler_tlci_native_producer as producer)
(import tlci_core as tlci)

(defenum ResultCompilerEmbeddedStdlibTlciFramesBuild
  (Err String)
  (Ok (__tl_dyn-array u8) (__tl_dyn-array u8)))

(define (compiler-embedded-stdlib-tlci-frames-encode
  [images : (& images (__tl_dyn-array (__tl_dyn-array u8)))]
  [names : (& names (__tl_dyn-array String))]) : encoder.ResultCompilerEmbeddedStdlibTlciEncoderBytes
  (let
    [count : i64 (array-length images)]
    [streams : (__tl_dyn-array String) (__tl_make-array String count)]
    [counts : (__tl_dyn-array
      encoder.CompilerEmbeddedStdlibTlciEncoderFrequencies)
      (__tl_make-array
        encoder.CompilerEmbeddedStdlibTlciEncoderFrequencies
        count)]
    [main : (__tl_dyn-array i64) (__tl_make-array i64 257)]
    [distance : (__tl_dyn-array i64) (__tl_make-array i64 4096)]
    [length : (__tl_dyn-array i64) (__tl_make-array i64 16)]
    [raw-total : i64 0]
    [name-bytes : i64 0]
    (unless
      (= count (+ (array-length names) 1))
      (return (Err "embedded stdlib tlci frames: frame/name count mismatch")))
    (for [index (iterator.range 0 count)]
      (let
        [source : String
          (tlci.tlci-bytes->string
            (& (array-ref images index))
            0
            (array-length (array-ref images index)))]
        [stream : String
          (ctfe.ctfe-embedded-stdlib-binary-data-bytes (& source))]
        [freq
          (try (encoder.compiler-embedded-stdlib-tlci-encoder-count (& stream)))]
        (for [i (iterator.range 0 257)]
          (+= (array-ref main i) (array-ref freq.main i)))
        (for [i (iterator.range 0 4096)]
          (+= (array-ref distance i) (array-ref freq.distance i)))
        (for [i (iterator.range 0 16)]
          (+= (array-ref length i) (array-ref freq.length i)))
        (+= raw-total freq.raw-len)
        (set! (array-ref streams index) stream)
        (set! (array-ref counts index) freq)))
    (for [index (iterator.range 0 (array-length names))]
      (+= name-bytes (string.string-length (array-ref names index))))
    (let
      [main-codes
        (try (encoder.compiler-embedded-stdlib-tlci-encoder-build-codes main))]
      [distance-codes
        (try
          (encoder.compiler-embedded-stdlib-tlci-encoder-build-codes distance))]
      [length-codes
        (try (encoder.compiler-embedded-stdlib-tlci-encoder-build-codes length))]
      [index-end : i64
        (+
          (frames.compiler-embedded-stdlib-tlci-frames-record count)
          name-bytes)]
      [name-cursor : i64
        (frames.compiler-embedded-stdlib-tlci-frames-record count)]
      [out : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
      (buf.byte-buf-builder-append-string
        (&mut out)
        (frames.compiler-embedded-stdlib-tlci-frames-prefix))
      (tlci.tlci-push-u64! (&mut out) raw-total)
      (tlci.tlci-push-u64! (&mut out) index-end)
      (tlci.tlci-push-u64! (&mut out) count)
      (tlci.tlci-push-u64! (&mut out) 0)
      (encoder.compiler-embedded-stdlib-tlci-encoder-append-lengths!
        (&mut out)
        (& main-codes))
      (encoder.compiler-embedded-stdlib-tlci-encoder-append-lengths!
        (&mut out)
        (& distance-codes))
      (encoder.compiler-embedded-stdlib-tlci-encoder-append-lengths!
        (&mut out)
        (& length-codes))
      (for [index (iterator.range 0 count)]
        (let
          [name-len : i64
            (if (= index 0)
              0
              (string.string-length (array-ref names (- index 1))))]
          (tlci.tlci-push-u64! (&mut out) name-cursor)
          (tlci.tlci-push-u64! (&mut out) name-len)
          (tlci.tlci-push-u64! (&mut out) 0)
          (tlci.tlci-push-u64!
            (&mut out)
            (__tl-project-field (array-ref counts index) raw-len))
          (tlci.tlci-push-u64! (&mut out) 0)
          (tlci.tlci-push-u64!
            (&mut out)
            (tlci.tlci-read-u64 (& (array-ref images index)) 48))
          (+= name-cursor name-len)))
      (for [index (iterator.range 0 (array-length names))]
        (buf.byte-buf-builder-append-string
          (&mut out)
          (string.copy (& (array-ref names index)))))
      (for [index (iterator.range 0 count)]
        (let
          [writer : encoder.CompilerEmbeddedStdlibTlciEncoderBitWriter
            (encoder.compiler-embedded-stdlib-tlci-encoder-encode-tokens
              (& (array-ref streams index))
              (& (array-ref counts index))
              (& main-codes)
              (& distance-codes)
              (& length-codes))]
          [record : i64
            (frames.compiler-embedded-stdlib-tlci-frames-record index)]
          (tlci.tlci-set-u64! (&mut out.slots) (+ record 16) out.len)
          (tlci.tlci-set-u64! (&mut out.slots) (+ record 32) writer.bits)
          (buf.byte-buf-builder-append-array-range
            (&mut out)
            (& writer.out.slots)
            0
            writer.out.len)))
      (let
        [bytes : (__tl_dyn-array u8) (buf.byte-buf-builder-to-array (& out))]
        (tlci.tlci-set-u64!
          (&mut bytes)
          60
          (frames.compiler-embedded-stdlib-tlci-frames-index-hash
            (& bytes)
            index-end))
        (Ok bytes)))))

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
            [name : String (clone (array-ref sorted cursor))]
            (set!
              (array-ref sorted cursor)
              (clone (array-ref sorted (- cursor 1))))
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
              (producer.embedded-native-emit-package
                context
                (string.copy (& metadata-text))
                (string.copy (& build-hash))
                windows-target
                (tlci.tlci-empty-bytes)
                (__tl_make-array (string.copy (& (array-ref sorted index))))
                captures)))]
        (set! (array-ref images (+ index 1)) bytes)))
    (let
      [ordinary
        (try
          (frames.compiler-embedded-stdlib-tlci-frames-aggregate
            (& images)
            (& sorted)))]
      [payload
        (try
          (compiler-embedded-stdlib-tlci-frames-encode (& images) (& sorted)))]
      (Ok ordinary payload))))