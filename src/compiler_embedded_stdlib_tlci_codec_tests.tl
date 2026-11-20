;; Catalog envelope coverage: the stored model parse, the group index, the
;; grouped decode path, and malformed or truncated envelopes.
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.byte_buf_core as buf)
(import compiler_embedded_stdlib_tlci_codec as codec)
(import compiler_embedded_stdlib_tlci_frames as frames)
(import compiler_lzss as lzss)
(import tlci_core as tlci)

;; A frame image with the TLCI header shape the index records checksums for.
;; Its body repeats itself, so the token stream really carries matches.
(define (tlci-codec-test-source [tag : i64]) : (__tl_dyn-array u8)
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 320)]
    [index : i64 0]
    (while (< index 320)
      (set!
        (array-ref bytes index)
        (if (< index 64)
          (cast (% (+ (* index 7) tag) 251) : u8)
          (cast (% (+ (* (% (- index 64) 37) 11) tag) 97) : u8)))
      (set! index (+ index 1)))
    (tlci.tlci-set-u64! (&mut bytes) 48 (+ 100 tag))
    bytes))

(define (tlci-codec-test-model) : lzss.CompilerLzssModel
  (lzss.compiler-lzss-model-from-spec (& lzss.compiler-lzss-fixed-spec)))

(define (tlci-codec-test-bytes->string [bytes : (& bytes (__tl_dyn-array u8))]) : String
  (tlci.tlci-bytes->string bytes 0 (array-length bytes)))

(define (tlci-codec-test-encode-group
  [bytes : (& bytes (__tl_dyn-array u8))]
  [model : (& model lzss.CompilerLzssModel)]) : String
  (let
    [text : String (tlci-codec-test-bytes->string bytes)]
    [tokens : (__tl_dyn-array lzss.CompilerLzssToken)
      (lzss.compiler-lzss-tokenize (& text) model)]
    [writer : lzss.CompilerLzssWriter (lzss.compiler-lzss-writer)]
    (lzss.compiler-lzss-emit (& text) (& tokens) model (&mut writer))
    (lzss.compiler-lzss-finish-writer (&mut writer))))

;; Two frames in two groups: the fixed model is stored verbatim, group 0 holds
;; frame 0 alone and group 1 the second frame.
(define (tlci-codec-test-envelope) : (__tl_dyn-array u8)
  (let
    [model : lzss.CompilerLzssModel (tlci-codec-test-model)]
    [first : (__tl_dyn-array u8) (tlci-codec-test-source 0)]
    [second : (__tl_dyn-array u8) (tlci-codec-test-source 1)]
    [first-stream : String (tlci-codec-test-encode-group (& first) (& model))]
    [second-stream : String (tlci-codec-test-encode-group (& second) (& model))]
    [groups : i64 (codec.compiler-embedded-stdlib-tlci-codec-group-count 2)]
    [directory : i64
      (codec.compiler-embedded-stdlib-tlci-codec-directory groups)]
    [record-bytes : i64
      (codec.compiler-embedded-stdlib-tlci-codec-record-bytes)]
    [name : String "stdlib/string"]
    [name-bytes : i64 (string.string-length (& name))]
    [index-end : i64 (+ (+ directory (* 2 record-bytes)) name-bytes)]
    [out : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    (buf.byte-buf-builder-append-string
      (&mut out)
      (codec.compiler-embedded-stdlib-tlci-codec-prefix))
    (tlci.tlci-push-u64!
      (&mut out)
      (+ (array-length first) (array-length second)))
    (tlci.tlci-push-u64! (&mut out) index-end)
    (tlci.tlci-push-u64! (&mut out) 2)
    (tlci.tlci-push-u64! (&mut out) 0)
    (tlci.tlci-push-u64!
      (&mut out)
      (+
        (string.string-length (& first-stream))
        (string.string-length (& second-stream))))
    (tlci.tlci-push-u64! (&mut out) groups)
    (buf.byte-buf-builder-append-string
      (&mut out)
      (tlci-codec-test-spec-string))
    ;; Group table: (stream off, stream len, raw off, raw len).
    (tlci.tlci-push-u64! (&mut out) 0)
    (tlci.tlci-push-u64! (&mut out) (string.string-length (& first-stream)))
    (tlci.tlci-push-u64! (&mut out) 0)
    (tlci.tlci-push-u64! (&mut out) (array-length first))
    (tlci.tlci-push-u64! (&mut out) (string.string-length (& first-stream)))
    (tlci.tlci-push-u64! (&mut out) (string.string-length (& second-stream)))
    (tlci.tlci-push-u64! (&mut out) (array-length first))
    (tlci.tlci-push-u64! (&mut out) (array-length second))
    ;; Frame records: name off, name len, raw off, raw len, group, checksum.
    (tlci.tlci-push-u64! (&mut out) (+ directory (* 2 record-bytes)))
    (tlci.tlci-push-u64! (&mut out) 0)
    (tlci.tlci-push-u64! (&mut out) 0)
    (tlci.tlci-push-u64! (&mut out) (array-length first))
    (tlci.tlci-push-u64! (&mut out) 0)
    (tlci.tlci-push-u64! (&mut out) 100)
    (tlci.tlci-push-u64! (&mut out) (+ directory (* 2 record-bytes)))
    (tlci.tlci-push-u64! (&mut out) name-bytes)
    (tlci.tlci-push-u64! (&mut out) (array-length first))
    (tlci.tlci-push-u64! (&mut out) (array-length second))
    (tlci.tlci-push-u64! (&mut out) 1)
    (tlci.tlci-push-u64! (&mut out) 101)
    (buf.byte-buf-builder-append-string (&mut out) (string.copy (& name)))
    (buf.byte-buf-builder-append-string (&mut out) first-stream)
    (buf.byte-buf-builder-append-string (&mut out) second-stream)
    (let
      [bytes : (__tl_dyn-array u8) (buf.byte-buf-builder-to-array (& out))]
      (tlci.tlci-set-u64!
        (&mut bytes)
        60
        (frames.compiler-embedded-stdlib-tlci-frames-index-hash
          (& bytes)
          index-end))
      bytes)))

(define (tlci-codec-test-copy [bytes : (& bytes (__tl_dyn-array u8))]) : (__tl_dyn-array
    u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 (array-length bytes))]
    [index : i64 0]
    (while (< index (array-length bytes))
      (set! (array-ref out index) (array-ref bytes index))
      (set! index (+ index 1)))
    out))

(define (tlci-codec-test-rejects?
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : bool
  (match (frames.compiler-embedded-stdlib-tlci-frames-parse payload raw-limit)
    [(Ok _) false]
    [(Err _) true]))

(define (tlci-codec-test-model-rejects? [spec : (& spec str)]) : bool
  (let
    [lengths : (__tl_dyn-array i64) (lzss.compiler-lzss-spec-lengths spec)]
    (match (lzss.compiler-lzss-model-check (& lengths))
      [(lzss.CompilerLzssCheck.Ok _) false]
      [(lzss.CompilerLzssCheck.Err _) true])))

;; A stored model that claims no code, an over-long code, or more code space
;; than a prefix code allows is rejected before anything decodes.
(define (tlci-codec-test-spec-edited [first : char] [second : char]) : String
  (let
    [spec : String (tlci-codec-test-spec-string)]
    [bytes : (__tl_dyn-array u8)
      (__tl_make-array u8 (string.string-length (& spec)))]
    [index : i64 0]
    (while (< index (array-length bytes))
      (set!
        (array-ref bytes index)
        (cast (string.string-ref (& spec) index) : u8))
      (set! index (+ index 1)))
    (set! (array-ref bytes 0) (cast first : u8))
    (set! (array-ref bytes 1) (cast second : u8))
    (let
      [text : String (tlci.tlci-bytes->string (& bytes) 0 (array-length bytes))]
      text)))

(define (tlci-codec-test-spec-string) : String
  (string.copy (& lzss.compiler-lzss-fixed-spec)))

(define (tlci-codec-test-model-validation-ok?) : bool
  (let
    [good : String (tlci-codec-test-spec-string)]
    [no-code : String (tlci-codec-test-spec-edited 'A' 'B')]
    [too-long : String (tlci-codec-test-spec-edited 'P' 'B')]
    [crowded : String (tlci-codec-test-spec-edited 'B' 'B')]
    (and
      (not (tlci-codec-test-model-rejects? (& good)))
      (tlci-codec-test-model-rejects? (& no-code))
      (tlci-codec-test-model-rejects? (& too-long))
      (tlci-codec-test-model-rejects? (& crowded)))))

(define (tlci-codec-test-frames-ok?) : bool
  (let
    [payload : (__tl_dyn-array u8) (tlci-codec-test-envelope)]
    [catalog
      (match (frames.compiler-embedded-stdlib-tlci-frames-parse
        (& payload)
        268435456)
        [(Ok catalog) catalog]
        [(Err _) (return false)])]
    [model
      (match (codec.compiler-embedded-stdlib-tlci-codec-model (& payload))
        [(Ok model) model]
        [(Err _) (return false)])]
    [first
      (match (frames.compiler-embedded-stdlib-tlci-frames-decode-group
        (& payload)
        catalog
        0
        (& model))
        [(Ok bytes) bytes]
        [(Err _) (return false)])]
    [second
      (match (frames.compiler-embedded-stdlib-tlci-frames-decode-group
        (& payload)
        catalog
        1
        (& model))
        [(Ok bytes) bytes]
        [(Err _) (return false)])]
    [want-first : (__tl_dyn-array u8) (tlci-codec-test-source 0)]
    [want-second : (__tl_dyn-array u8) (tlci-codec-test-source 1)]
    (and
      (= catalog.count 2)
      (= catalog.groups 2)
      (= (array-length first) (array-length want-first))
      (= (array-length second) (array-length want-second))
      (=
        (frames.compiler-embedded-stdlib-tlci-frames-find
          (& payload)
          catalog
          (& (string.copy "stdlib/string")))
        1))))

(define (tlci-codec-status) : i64
  (let
    [payload : (__tl_dyn-array u8) (tlci-codec-test-envelope)]
    (when (not (tlci-codec-test-model-validation-ok?)) (return 1))
    (when (not (tlci-codec-test-frames-ok?)) (return 2))
    ;; A wrong marker, a bad frame count, an unwritable group range and a
    ;; re-hashed but corrupted index are all rejected.
    (let
      [broken : (__tl_dyn-array u8) (tlci-codec-test-copy (& payload))]
      (set! (array-ref broken 0) (cast 88 : u8))
      (when (not (tlci-codec-test-rejects? (& broken) 268435456)) (return 3)))
    (let
      [broken : (__tl_dyn-array u8) (tlci-codec-test-copy (& payload))]
      (tlci.tlci-set-u64! (&mut broken) 52 0)
      (when (not (tlci-codec-test-rejects? (& broken) 268435456)) (return 4)))
    (let
      [broken : (__tl_dyn-array u8) (tlci-codec-test-copy (& payload))]
      (tlci.tlci-set-u64! (&mut broken) 76 3)
      (when (not (tlci-codec-test-rejects? (& broken) 268435456)) (return 5)))
    (let
      [broken : (__tl_dyn-array u8) (tlci-codec-test-copy (& payload))]
      (tlci.tlci-set-u64! (&mut broken) 60 12345)
      (when (not (tlci-codec-test-rejects? (& broken) 268435456)) (return 6)))
    ;; The first group's raw length must not exceed the group's bytes.
    (let
      [broken : (__tl_dyn-array u8) (tlci-codec-test-copy (& payload))]
      [group-table : i64
        (codec.compiler-embedded-stdlib-tlci-codec-group-table)]
      (tlci.tlci-set-u64! (&mut broken) (+ group-table 24) 4096)
      (when (not (tlci-codec-test-rejects? (& broken) 268435456)) (return 7)))
    ;; A checksum that no longer matches its frame fails the frame decode.
    (let
      [broken : (__tl_dyn-array u8) (tlci-codec-test-copy (& payload))]
      [directory : i64 (codec.compiler-embedded-stdlib-tlci-codec-directory 2)]
      [catalog
        (match (frames.compiler-embedded-stdlib-tlci-frames-parse
          (& broken)
          268435456)
          [(Ok catalog) catalog]
          [(Err _) (return 8)])]
      (tlci.tlci-set-u64! (&mut broken) (+ directory 40) 7)
      (tlci.tlci-set-u64!
        (&mut broken)
        60
        (frames.compiler-embedded-stdlib-tlci-frames-index-hash
          (& broken)
          catalog.index-end))
      (let
        [model
          (match (codec.compiler-embedded-stdlib-tlci-codec-model (& broken))
            [(Ok model) model]
            [(Err _) (return 9)])]
        (match (frames.compiler-embedded-stdlib-tlci-frames-decode-group
          (& broken)
          catalog
          0
          (& model))
          [(Ok bytes)
            (when (= (tlci.tlci-read-u64 (& bytes) 48) 7) (return 10))]
          [(Err _) unit])))
    ;; A consumer raw limit below the envelope's raw length rejects first.
    (when (not (tlci-codec-test-rejects? (& payload) 8)) (return 11))
    0))

(test
  compiler-embedded-stdlib-tlci-payload-codec
  (if (= (tlci-codec-status) 0)
    unit
    (string.tl_oob_abort)))