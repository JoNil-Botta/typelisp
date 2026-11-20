;; Compiler-owned stdlib catalog envelope.
;;
;; One model, one LZ77 token stream and an index of frames, all coded by
;; compiler_lzss: the header carries the total raw length, the index end, the
;; frame count and an index hash; the stored model follows; then the frame
;; records with their names; then one bitstream that expands to every frame's
;; TLCI image back to back.
(import stdlib.string)
(import compiler_lzss as lzss)

(defenum ResultCompilerEmbeddedStdlibTlciCodecModel
  (Err String)
  (Ok lzss.CompilerLzssModel))

(define (compiler-embedded-stdlib-tlci-codec-prefix) : String
  "__typelisp_embedded_stdlib_tlci_v3__")

;; magic, total raw length, index end, frame count, index hash, stream bytes.
(define (compiler-embedded-stdlib-tlci-codec-header-bytes) : i64
  76)

;; The stored model's byte offset in the envelope.
(define (compiler-embedded-stdlib-tlci-codec-model-start) : i64
  (compiler-embedded-stdlib-tlci-codec-header-bytes))

(define (compiler-embedded-stdlib-tlci-codec-model-bytes) : i64
  (lzss.compiler-lzss-model-spec-bytes))

;; The frame records and names start here, right after the stored model.
(define (compiler-embedded-stdlib-tlci-codec-directory) : i64
  (+
    (compiler-embedded-stdlib-tlci-codec-model-start)
    (compiler-embedded-stdlib-tlci-codec-model-bytes)))

(define (compiler-embedded-stdlib-tlci-codec-record-bytes) : i64
  48)

(define (compiler-embedded-stdlib-tlci-codec-prefix?
  [payload : (& payload (__tl_dyn-array u8))]
  [prefix : String]) : bool
  (let
    [index : i64 0]
    [prefix-len : i64 (string.string-length prefix)]
    [matches : bool (>= (array-length payload) prefix-len)]
    (while (and matches (< index prefix-len))
      (if (!=
        (array-ref payload index)
        (cast (string.string-ref prefix index) : u8))
        (set! matches false)
        unit)
      (+= index 1))
    matches))

;; The model stored in the envelope. A short model is a malformed payload, so
;; the bounds are checked before the codec reads its code lengths.
(define (compiler-embedded-stdlib-tlci-codec-model
  [payload : (& payload (__tl_dyn-array u8))]) : ResultCompilerEmbeddedStdlibTlciCodecModel
  (when
    (< (array-length payload) (compiler-embedded-stdlib-tlci-codec-directory))
    (return (Err "embedded stdlib tlci codec: truncated model")))
  (Ok
    (lzss.compiler-lzss-model-from-bytes
      payload
      (compiler-embedded-stdlib-tlci-codec-header-bytes)
      (compiler-embedded-stdlib-tlci-codec-model-bytes))))

;; Expand the envelope's whole stream; every frame's bytes follow in order.
(define (compiler-embedded-stdlib-tlci-codec-decode
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [raw-len : i64]
  [model : (& model lzss.CompilerLzssModel)]) : lzss.CompilerLzssBytes
  (lzss.compiler-lzss-decode-stream payload start raw-len model))