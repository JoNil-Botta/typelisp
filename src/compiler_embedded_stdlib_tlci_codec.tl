;; Compiler-owned stdlib catalog envelope: one stored model, one index of frames
;; and independently decodable groups of frames.
;;
;; Layout: a 36-byte marker; the total raw length, index end, frame count, index
;; hash, stream length and group count (u64 each); the stored model as one
;; 'A' + code-length character per symbol; a group table of 32-byte records
;; (stream offset, stream length, raw offset, raw length); the frame records;
;; the frame names; then the token stream. Frame zero is its own group and the
;; rest come sixteen at a time, so a reader expands only the group holding the
;; frame it needs.
(import stdlib.string)
(import compiler_lzss as lzss)

(defenum ResultCompilerEmbeddedStdlibTlciCodecModel
  (Err String)
  (Ok lzss.CompilerLzssModel))

(define (compiler-embedded-stdlib-tlci-codec-prefix) : String
  "__typelisp_embedded_stdlib_tlci_v3__")

;; magic(36) + raw, index end, count, hash, stream bytes, groups (6 * 8).
(define (compiler-embedded-stdlib-tlci-codec-header-bytes) : i64
  84)

(define (compiler-embedded-stdlib-tlci-codec-model-start) : i64
  (compiler-embedded-stdlib-tlci-codec-header-bytes))

(define (compiler-embedded-stdlib-tlci-codec-model-bytes) : i64
  (lzss.compiler-lzss-model-spec-bytes))

(define (compiler-embedded-stdlib-tlci-codec-group-bytes) : i64
  32)

(define (compiler-embedded-stdlib-tlci-codec-record-bytes) : i64
  48)

;; Frames per group after the first: frame zero is decoded on its own, so a
;; plain compile never expands the rest of the catalog.
(define (compiler-embedded-stdlib-tlci-codec-group-frames) : i64
  16)

(define (compiler-embedded-stdlib-tlci-codec-group-count [count : i64]) : i64
  (if (<= count 1)
    1
    (+
      1
      (/
        (+ (- count 2) (compiler-embedded-stdlib-tlci-codec-group-frames))
        (compiler-embedded-stdlib-tlci-codec-group-frames)))))

(define (compiler-embedded-stdlib-tlci-codec-group-of [index : i64]) : i64
  (if (<= index 0)
    0
    (+ 1 (/ (- index 1) (compiler-embedded-stdlib-tlci-codec-group-frames)))))

;; First frame index of `group`.
(define (compiler-embedded-stdlib-tlci-codec-group-first [group : i64]) : i64
  (if (<= group 0)
    0
    (+ 1 (* (- group 1) (compiler-embedded-stdlib-tlci-codec-group-frames)))))

(define (compiler-embedded-stdlib-tlci-codec-group-table) : i64
  (+
    (compiler-embedded-stdlib-tlci-codec-model-start)
    (compiler-embedded-stdlib-tlci-codec-model-bytes)))

;; The frame records start after the group table.
(define (compiler-embedded-stdlib-tlci-codec-directory [groups : i64]) : i64
  (+
    (compiler-embedded-stdlib-tlci-codec-group-table)
    (* groups (compiler-embedded-stdlib-tlci-codec-group-bytes))))

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

;; The model stored in the envelope. A short model, a code length outside 1..15
;; or a Kraft sum over one is a malformed payload, so the bounds are checked
;; before any symbol is decoded with it.
(define (compiler-embedded-stdlib-tlci-codec-model
  [payload : (& payload (__tl_dyn-array u8))]) : ResultCompilerEmbeddedStdlibTlciCodecModel
  (when
    (<
      (array-length payload)
      (+
        (compiler-embedded-stdlib-tlci-codec-model-start)
        (compiler-embedded-stdlib-tlci-codec-model-bytes)))
    (return (Err "embedded stdlib tlci codec: truncated model")))
  (let
    [spec : String
      (lzss.compiler-lzss-spec-string
        payload
        (compiler-embedded-stdlib-tlci-codec-model-start)
        (compiler-embedded-stdlib-tlci-codec-model-bytes))]
    [lengths : (__tl_dyn-array i64) (lzss.compiler-lzss-spec-lengths (& spec))]
    (match (lzss.compiler-lzss-model-check (& lengths))
      [(lzss.CompilerLzssCheck.Err message) (Err message)]
      [(lzss.CompilerLzssCheck.Ok _)
        (Ok (lzss.compiler-lzss-model-from-lengths lengths))])))

;; Expand one group of frames; every frame's bytes follow in order. With
;; `soft`, `raw-len` may fall inside a token: the token that crosses it
;; finishes, so the caller gets at least `raw-len` bytes.
(define (compiler-embedded-stdlib-tlci-codec-decode-group-prefix
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [raw-len : i64]
  [soft : bool]
  [model : (& model lzss.CompilerLzssModel)]) : lzss.CompilerLzssBytes
  (if soft
    (lzss.compiler-lzss-decode-prefix-soft payload start raw-len model)
    (lzss.compiler-lzss-decode-prefix payload start raw-len model)))