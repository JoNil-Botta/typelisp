;; Bounded decoder for compiler-owned `include-str-lzss` payloads.
;;
;; The declaration form emits a versioned envelope containing arbitrary bytes,
;; despite its historical name. Consumers choose a raw-size limit appropriate
;; for their payload before this module allocates the output buffer.
(import stdlib.string)

(defenum CompilerLzssFrame
  (Err String)
  ;; uncompressed byte length, first token-stream index
  (Ok i64 i64))

(defenum CompilerLzssBytes
  (Err String)
  (Ok (__tl_dyn-array u8)))

(define (compiler-lzss-envelope-prefix) : String
  "__typelisp_embedded_stdlib_lzss_v1__")

(define (compiler-lzss-prefix?
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

;: Validate the envelope and return the claimed raw length and token offset.
;: `raw-limit` is a consumer policy and is checked before any output allocation.
(define (compiler-lzss-frame
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : CompilerLzssFrame
  (let
    [prefix : String (compiler-lzss-envelope-prefix)]
    [prefix-len : i64 (string.string-length prefix)]
    (cond
      [(< raw-limit 0) (Err "compiler lzss: invalid raw length limit")]
      [(not (compiler-lzss-prefix? payload prefix))
        (Err "compiler lzss: bad envelope prefix")]
      [else
        (let
          [payload-len : i64 (array-length payload)]
          [index : i64 prefix-len]
          [raw-len : i64 0]
          [digits : i64 0]
          [overflow : bool false]
          [max-i64 : i64 9223372036854775807]
          (while (and
            (not overflow)
            (< index payload-len)
            (>= (array-ref payload index) (cast 48 : u8))
            (<= (array-ref payload index) (cast 57 : u8)))
            (let
              [digit : i64 (- (cast (array-ref payload index) : i64) 48)]
              (if (> raw-len (/ (- max-i64 digit) 10))
                (set! overflow true)
                (set! raw-len (+ (* raw-len 10) digit)))
              (+= digits 1)
              (+= index 1)))
          (cond
            [overflow (Err "compiler lzss: raw length overflows i64")]
            [(= digits 0) (Err "compiler lzss: missing raw length")]
            [(or
                (>= index payload-len)
                (!= (array-ref payload index) (cast 10 : u8)))
              (Err "compiler lzss: malformed raw length")]
            [(> raw-len raw-limit)
              (Err "compiler lzss: raw length exceeds consumer limit")]
            [else
              (let
                [compressed-start : i64 (+ index 1)]
                [compressed-len : i64 (- payload-len compressed-start)]
                ;; A token byte can expand to at most nine output bytes. This
                ;; cheap necessary bound rejects absurd claimed lengths before
                ;; allocating; the token walk below proves the exact length.
                [ratio-safe : bool
                  (or
                    (>= compressed-len 1024819115206086200)
                    (<= raw-len (* compressed-len 9)))]
                (if ratio-safe
                  (Ok raw-len compressed-start)
                  (Err "compiler lzss: impossible raw length")))]))])))

;: Copy one back-reference: `length` bytes starting `distance` bytes before
;: `out-index` to `out-index`, in the output buffer whose data pointer is
;: `out-data`. The caller has already checked that both ranges lie inside the
;: buffer. A source at least eight bytes back is final for a whole word
;: ahead, so words copy it exactly as the byte loop would; a nearer,
;: overlapping source and the tail go byte by byte. Shared by this decoder and
;: the embedded stdlib TLCH envelope, which decodes the same token stream.
;: `distance` and `length` must be plain locals: they are read repeatedly.
(defmacro (compiler-lzss-copy-match!
  [out-data : Expr]
  [out-index : Expr]
  [distance : Expr]
  [length : Expr]) : unit
  `(let
    [dst : (MutPtr u8)
      (unsafe
        (ptr-offset ,out-data ,out-index))]
    [copied : i64 0]
    (when
      (>= ,distance 8)
      (let
        [words : i64 (- ,length 7)]
        (while (< copied words)
          (unsafe
            (ptr-write!
              (ptr-cast (ptr-offset dst copied) : (MutPtr i64))
              (ptr-read
                (ptr-cast (ptr-offset dst (- copied ,distance)) : (Ptr i64)))))
          (set! copied (+ copied 8)))))
    (while (< copied ,length)
      (unsafe
        (ptr-write!
          (ptr-offset dst copied)
          (ptr-read (ptr-offset dst (- copied ,distance)))))
      (set! copied (+ copied 1)))))

(define (compiler-lzss-decode-tokens
  [payload : (& payload (__tl_dyn-array u8))]
  [compressed-start : i64]
  [raw-len : i64]) : CompilerLzssBytes
  (let
    [payload-len : i64 (array-length payload)]
    [compressed-len : i64 (- payload-len compressed-start)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 raw-len)]
    [compressed-index : i64 0]
    [out-index : i64 0]
    [valid : bool true]
    [error : String ""]
    (while (and valid (< out-index raw-len))
      (if (>= compressed-index compressed-len)
        (begin
          (set! valid false)
          (set! error "compiler lzss: truncated token stream"))
        (let
          [flags : i64
            (cast
              (array-ref payload (+ compressed-start compressed-index))
              : i64)]
          [bit : i64 0]
          (+= compressed-index 1)
          (while (and valid (< bit 8) (< out-index raw-len))
            (if (!= (bit-and flags (shl 1 bit)) 0)
              (if (>= compressed-index compressed-len)
                (begin
                  (set! valid false)
                  (set! error "compiler lzss: truncated literal token"))
                (begin
                  (set!
                    (array-ref out out-index)
                    (array-ref payload (+ compressed-start compressed-index)))
                  (+= compressed-index 1)
                  (+= out-index 1)))
              (if (< (- compressed-len compressed-index) 2)
                (begin
                  (set! valid false)
                  (set! error "compiler lzss: truncated backreference token"))
                (let
                  [packed : i64
                    (bit-or
                      (shl
                        (cast
                          (array-ref
                            payload
                            (+ compressed-start compressed-index))
                          : i64)
                        8)
                      (cast
                        (array-ref
                          payload
                          (+ compressed-start (+ compressed-index 1)))
                        : i64))]
                  [offset : i64 (+ (shr packed 4) 1)]
                  [length : i64 (+ (bit-and packed 15) 3)]
                  (+= compressed-index 2)
                  (cond
                    [(> offset out-index)
                      (set! valid false)
                      (set! error "compiler lzss: backreference before output")]
                    [(> length (- raw-len out-index))
                      (set! valid false)
                      (set! error "compiler lzss: token exceeds raw length")]
                    [else
                      (compiler-lzss-copy-match!
                        (unsafe
                          (__tl_array-data out))
                        out-index
                        offset
                        length)
                      (+= out-index length)]))))
            (+= bit 1)))))
    (cond
      [(not valid) (Err error)]
      [(!= out-index raw-len) (Err "compiler lzss: expanded length mismatch")]
      [(!= compressed-index compressed-len)
        (Err "compiler lzss: trailing compressed bytes")]
      [else (Ok out)])))

;: Decode one complete compiler-owned envelope after bounded validation.
(define (compiler-lzss-decode
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : CompilerLzssBytes
  (match (compiler-lzss-frame payload raw-limit)
    [(Err message) (Err message)]
    [(Ok raw-len compressed-start)
      (compiler-lzss-decode-tokens payload compressed-start raw-len)]))