;; Bounded decoder for compiler-owned `include-str-lzss` payloads.
;;
;; The declaration form emits a versioned envelope containing arbitrary bytes,
;; despite its historical name. Consumers choose a raw-size limit appropriate
;; for their payload before this module allocates the output buffer.
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_owned_view as owned_view)

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
  [prefix : (& str)]) : bool
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
  (compiler-lzss-frame-with-prefix
    payload
    raw-limit
    (compiler-lzss-envelope-prefix)
    9))

;: The frame under `prefix`, where one compressed byte expands to at most
;: `expansion` output bytes (v1: a flag byte's eight literals and a token's
;: nine; v2: a 3-bit back-reference of 18 bytes, 48 per byte).
(define (compiler-lzss-frame-with-prefix
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]
  [prefix : String]
  [expansion : i64]) : CompilerLzssFrame
  (let
    [prefix-len : i64 (string.string-length prefix)]
    (cond
      [(< raw-limit 0) (Err "compiler lzss: invalid raw length limit")]
      [(not (compiler-lzss-prefix? payload (& prefix)))
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
                ;; A compressed byte expands to at most `expansion` output
                ;; bytes. This cheap necessary bound rejects absurd claimed
                ;; lengths before allocating; the token walk proves the exact
                ;; length.
                [ratio-safe : bool
                  (or
                    (>= compressed-len (/ 9223372036854775807 expansion))
                    (<= raw-len (* compressed-len expansion)))]
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

;; The fast group path needs, before reading a group's flag byte, the flag
;; byte plus two bytes for each of its eight tokens.
(define compiler-lzss-fast-group-input : i64
  17)

;; The fast group path needs this much output room before a group: seven
;; tokens of at most 18 bytes each, then a match that writes three whole words.
;; Within it no token can pass `raw-len`, so the group never ends early.
(define compiler-lzss-fast-group-output : i64
  150)

;: Copy one back-reference of at most 18 bytes inside the fast group path,
;: whose output room covers 24 bytes at `out-index`. A source at least eight
;: bytes back is final for each whole word read, so three words reproduce the
;: byte loop on the first `length` bytes; the bytes after them are rewritten
;: by later tokens before the decode can succeed. A nearer, overlapping source
;: goes byte by byte.
(defmacro (compiler-lzss-copy-short-match!
  [out-data : Expr]
  [out-index : Expr]
  [distance : Expr]
  [length : Expr]) : unit
  `(let
    [dst : (MutPtr u8)
      (unsafe
        (ptr-offset ,out-data ,out-index))]
    (if (>= ,distance 8)
      (let
        [src : (MutPtr u8)
          (unsafe
            (ptr-offset dst (- 0 ,distance)))]
        (unsafe
          (ptr-write!
            (ptr-cast dst : (MutPtr i64))
            (ptr-read (ptr-cast src : (Ptr i64))))
          (ptr-write!
            (ptr-cast (ptr-offset dst 8) : (MutPtr i64))
            (ptr-read (ptr-cast (ptr-offset src 8) : (Ptr i64))))
          (ptr-write!
            (ptr-cast (ptr-offset dst 16) : (MutPtr i64))
            (ptr-read (ptr-cast (ptr-offset src 16) : (Ptr i64))))))
      (let
        [copied : i64 0]
        (while (< copied ,length)
          (unsafe
            (ptr-write!
              (ptr-offset dst copied)
              (ptr-read (ptr-offset dst (- copied ,distance)))))
          (set! copied (+ copied 1)))))))

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
    [payload-view : (__tl_dyn-array u8)
      (owned_view.compiler-owned-reference-shared-view payload)]
    [in-data : (Ptr u8)
      (unsafe
        (ptr-offset
          (ptr-cast (__tl_array-data payload-view) : (Ptr u8))
          compressed-start))]
    [out-data : (MutPtr u8)
      (unsafe
        (__tl_array-data out))]
    (while (and valid (< out-index raw-len))
      ;; A whole group whose input and output room are proven up front reads
      ;; and writes without per-token checks. The only error it can meet is a
      ;; backreference before the output, reported as the checked loop would.
      (while (and
        valid
        (>= (- compressed-len compressed-index) compiler-lzss-fast-group-input)
        (>= (- raw-len out-index) compiler-lzss-fast-group-output))
        (let
          [flags : i64
            (cast
              (unsafe
                (ptr-read (ptr-offset in-data compressed-index)))
              : i64)]
          [token : i64 0]
          (+= compressed-index 1)
          (while (and valid (< token 8))
            (if (= (bit-and flags 1) 1)
              (begin
                (unsafe
                  (ptr-write!
                    (ptr-offset out-data out-index)
                    (ptr-read (ptr-offset in-data compressed-index))))
                (+= compressed-index 1)
                (+= out-index 1))
              (let
                [packed : i64
                  (bit-or
                    (shl
                      (cast
                        (unsafe
                          (ptr-read (ptr-offset in-data compressed-index)))
                        : i64)
                      8)
                    (cast
                      (unsafe
                        (ptr-read (ptr-offset in-data (+ compressed-index 1))))
                      : i64))]
                [offset : i64 (+ (shr packed 4) 1)]
                [length : i64 (+ (bit-and packed 15) 3)]
                (+= compressed-index 2)
                (if (> offset out-index)
                  (begin
                    (set! valid false)
                    (set! error "compiler lzss: backreference before output"))
                  (begin
                    (compiler-lzss-copy-short-match!
                      out-data
                      out-index
                      offset
                      length)
                    (+= out-index length)))))
            (set! flags (shr flags 1))
            (+= token 1))))
      (cond
        [(or (not valid) (>= out-index raw-len)) unit]
        [(>= compressed-index compressed-len)
          (set! valid false)
          (set! error "compiler lzss: truncated token stream")]
        [else
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
                        (set!
                          error
                          "compiler lzss: backreference before output")]
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
              (+= bit 1)))]))
    (cond
      [(not valid) (Err error)]
      [(!= out-index raw-len) (Err "compiler lzss: expanded length mismatch")]
      [(!= compressed-index compressed-len)
        (Err "compiler lzss: trailing compressed bytes")]
      [else (Ok out)])))

;; --- envelope v2 --------------------------------------------------------------
;;
;; The v1 token stream re-coded bit by bit (most significant bit first) under one
;; FIXED canonical Huffman model, so a payload carries no code tables: a main
;; symbol (a literal byte, or 256 for a back-reference), then for a
;; back-reference a distance bucket, its extra bits and a length symbol
;; (length - 3). Distance `d` = offset - 1 (0..4095) is bucket `d` below 4;
;; otherwise, with `b` = its bit length - 1, bucket `2b + bit b-1 of d` and the
;; low `b - 1` bits of `d` as extra bits. The code lengths (one hex digit per
;; symbol, at most 15 bits) were trained once on the embedded stdlib sources;
;; any input stays decodable, only the ratio depends on them. The final byte is
;; zero-padded.
(define (compiler-lzss-v2-prefix) : String
  "__typelisp_embedded_stdlib_lzss_v2__")

(define compiler-lzss-v2-main-lengths : String
  (str_cat.str-cat
    "ffffffffff9fffffffffffffffffffff5a8bfdba77ba867a778888888999a9aa"
    "d9a9b9acc9edaaaaaea99bbbdfe8b9e87576657775b867666a66668887aefeff"
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    "1"))
(define compiler-lzss-v2-distance-lengths : String
  "4cbca9876555444444444434")
(define compiler-lzss-v2-length-lengths : String
  "3344445555555662")
(define compiler-lzss-v2-max-bits : i64
  15)

;; A canonical code: per code length its symbol count, first code and first
;; index into `symbols` (sorted by length, then symbol), and each symbol's own
;; length and code for the encoder.
(defstruct CompilerLzssCanonical
  (counts (__tl_dyn-array i64))
  (firsts (__tl_dyn-array i64))
  (starts (__tl_dyn-array i64))
  (symbols (__tl_dyn-array i64))
  (lengths (__tl_dyn-array i64))
  (codes (__tl_dyn-array i64)))

(define (compiler-lzss-hex-digit [c : char]) : i64
  (if (<= c '9')
    (- (cast c : i64) 48)
    (+ (- (cast c : i64) 97) 10)))

(define (compiler-lzss-canonical [spec : (& spec str)]) : CompilerLzssCanonical
  (let
    [n : i64 (string.string-length spec)]
    [limit : i64 (+ compiler-lzss-v2-max-bits 1)]
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [firsts : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [next : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [symbols : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [lengths : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [codes : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [symbol : i64 0]
    [len : i64 1]
    [code : i64 0]
    [placed : i64 0]
    (while (< symbol n)
      (let
        [length : i64 (compiler-lzss-hex-digit (string.string-ref spec symbol))]
        (set! (array-ref lengths symbol) length)
        (set! (array-ref counts length) (+ (array-ref counts length) 1)))
      (set! symbol (+ symbol 1)))
    (while (< len limit)
      (set! code (shl (+ code (array-ref counts (- len 1))) 1))
      (when (= len 1) (set! code 0))
      (set! (array-ref firsts len) code)
      (set! (array-ref next len) code)
      (set! (array-ref starts len) placed)
      (set! placed (+ placed (array-ref counts len)))
      (set! len (+ len 1)))
    (set! symbol 0)
    (while (< symbol n)
      (let
        [length : i64 (array-ref lengths symbol)]
        (set!
          (array-ref
            symbols
            (+
              (array-ref starts length)
              (- (array-ref next length) (array-ref firsts length))))
          symbol)
        (set! (array-ref codes symbol) (array-ref next length))
        (set! (array-ref next length) (+ (array-ref next length) 1)))
      (set! symbol (+ symbol 1)))
    (CompilerLzssCanonical counts firsts starts symbols lengths codes)))

(define (compiler-lzss-v2-main) : CompilerLzssCanonical
  (compiler-lzss-canonical (& compiler-lzss-v2-main-lengths)))

(define (compiler-lzss-v2-distance) : CompilerLzssCanonical
  (compiler-lzss-canonical (& compiler-lzss-v2-distance-lengths)))

(define (compiler-lzss-v2-length) : CompilerLzssCanonical
  (compiler-lzss-canonical (& compiler-lzss-v2-length-lengths)))

;; The bucket of distance `d` (offset - 1) and its extra-bit count.
(define (compiler-lzss-v2-bucket [d : i64]) : i64
  (if (< d 4)
    d
    (let
      [b : i64 (- (compiler-lzss-bit-length d) 1)]
      (+ (* 2 b) (bit-and (shr d (- b 1)) 1)))))

(define (compiler-lzss-v2-extra-bits [bucket : i64]) : i64
  (if (< bucket 4)
    0
    (- (/ bucket 2) 1)))

(define (compiler-lzss-bit-length [value : i64]) : i64
  (let
    [bits : i64 0]
    [rest : i64 value]
    (while (> rest 0)
      (set! rest (shr rest 1))
      (set! bits (+ bits 1)))
    bits))

;; Direct decoding of the first `bits` bits of a code: an entry is
;; symbol * 16 + length for a code of at most `bits` bits, and 0 for a longer
;; code, which `compiler-lzss-read-symbol` finishes canonically.
(defstruct CompilerLzssLookup
  (bits i64)
  (entries (__tl_dyn-array i64))
  (code CompilerLzssCanonical))

(define (compiler-lzss-lookup [code : CompilerLzssCanonical] [bits : i64]) : CompilerLzssLookup
  (let
    [entries : (__tl_dyn-array i64) (__tl_make-array i64 (shl 1 bits))]
    [symbol : i64 0]
    (while (< symbol (array-length code.lengths))
      (let
        [len : i64 (array-ref code.lengths symbol)]
        (when
          (<= len bits)
          (let
            [first : i64 (shl (array-ref code.codes symbol) (- bits len))]
            [span : i64 (shl 1 (- bits len))]
            [k : i64 0]
            (while (< k span)
              (set! (array-ref entries (+ first k)) (+ (* symbol 16) len))
              (set! k (+ k 1))))))
      (set! symbol (+ symbol 1)))
    (CompilerLzssLookup bits entries code)))

;; Built once per process: decoding never rebuilds a table.
(define compiler-lzss-v2-main-lookup : CompilerLzssLookup
  (compiler-lzss-lookup (compiler-lzss-v2-main) 10))
(define compiler-lzss-v2-distance-lookup : CompilerLzssLookup
  (compiler-lzss-lookup (compiler-lzss-v2-distance) 9))
(define compiler-lzss-v2-length-lookup : CompilerLzssLookup
  (compiler-lzss-lookup (compiler-lzss-v2-length) 6))

;; The token stream `start`..`start + len` read through a bit buffer: the low
;; `count` bits of `buf` are the next bits, most significant first; `pos` is
;; the next byte to load and `consumed` counts the bits taken.
(defstruct CompilerLzssReader
  (start i64)
  (len i64)
  (pos i64)
  (buf i64)
  (count i64)
  (consumed i64))

(define (compiler-lzss-refill!
  [payload : (& payload (__tl_dyn-array u8))]
  [reader : (&mut reader CompilerLzssReader)]) : unit
  (while (and (<= reader.count 48) (< reader.pos reader.len))
    (set!
      reader.buf
      (bit-or
        (shl reader.buf 8)
        (cast (array-ref payload (+ reader.start reader.pos)) : i64)))
    (set! reader.pos (+ reader.pos 1))
    (set! reader.count (+ reader.count 8))))

;; The next `n` bits (at most 48), zero-filled past the end of the stream.
(define (compiler-lzss-peek [reader : (& reader CompilerLzssReader)] [n : i64]) : i64
  (if (>= reader.count n)
    (bit-and (shr reader.buf (- reader.count n)) (- (shl 1 n) 1))
    (bit-and (shl reader.buf (- n reader.count)) (- (shl 1 n) 1))))

;; Take `n` bits; false when the stream holds fewer.
(define (compiler-lzss-consume!
  [reader : (&mut reader CompilerLzssReader)]
  [n : i64]) : bool
  (if (> n reader.count)
    false
    (begin
      (set! reader.count (- reader.count n))
      (set! reader.buf (bit-and reader.buf (- (shl 1 reader.count) 1)))
      (set! reader.consumed (+ reader.consumed n))
      true)))

;; The next `n` raw bits, or -1 for a truncated stream.
(define (compiler-lzss-read-bits
  [payload : (& payload (__tl_dyn-array u8))]
  [reader : (&mut reader CompilerLzssReader)]
  [n : i64]) : i64
  (compiler-lzss-refill! payload reader)
  (let
    [value : i64 (compiler-lzss-peek reader n)]
    (if (compiler-lzss-consume! reader n)
      value
      -1)))

;; The next symbol of `lookup`'s code, or -1 for a truncated or unassigned code.
(define (compiler-lzss-read-symbol
  [payload : (& payload (__tl_dyn-array u8))]
  [reader : (&mut reader CompilerLzssReader)]
  [lookup : (& lookup CompilerLzssLookup)]) : i64
  (compiler-lzss-refill! payload reader)
  (let
    [entry : i64
      (array-ref lookup.entries (compiler-lzss-peek reader lookup.bits))]
    (if (> entry 0)
      (if (compiler-lzss-consume! reader (bit-and entry 15))
        (shr entry 4)
        -1)
      ;; A code longer than the table: finish it canonically.
      (let
        [len : i64 (+ lookup.bits 1)]
        [found : i64 -1]
        (while (and (< found 0) (<= len compiler-lzss-v2-max-bits))
          (let
            [index : i64
              (-
                (compiler-lzss-peek reader len)
                (array-ref lookup.code.firsts len))]
            (when
              (and (>= index 0) (< index (array-ref lookup.code.counts len)))
              (set!
                found
                (if (compiler-lzss-consume! reader len)
                  (array-ref
                    lookup.code.symbols
                    (+ (array-ref lookup.code.starts len) index))
                  -2))))
          (set! len (+ len 1)))
        (if (< found 0)
          -1
          found)))))

(define (compiler-lzss-decode-v2
  [payload : (& payload (__tl_dyn-array u8))]
  [compressed-start : i64]
  [raw-len : i64]) : CompilerLzssBytes
  (let
    [reader : CompilerLzssReader
      (CompilerLzssReader
        compressed-start
        (- (array-length payload) compressed-start)
        0
        0
        0
        0)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 raw-len)]
    [out-index : i64 0]
    [error : String ""]
    (while (and (= (string.string-length (& error)) 0) (< out-index raw-len))
      (let
        [symbol : i64
          (compiler-lzss-read-symbol
            payload
            (&mut reader)
            (& compiler-lzss-v2-main-lookup))]
        (cond
          [(< symbol 0) (set! error "compiler lzss: truncated v2 symbol")]
          [(< symbol 256)
            (set! (array-ref out out-index) (cast symbol : u8))
            (set! out-index (+ out-index 1))]
          [else
            (let
              [bucket : i64
                (compiler-lzss-read-symbol
                  payload
                  (&mut reader)
                  (& compiler-lzss-v2-distance-lookup))]
              [extra-count : i64 (compiler-lzss-v2-extra-bits bucket)]
              [extra : i64
                (if (< bucket 0)
                  -1
                  (compiler-lzss-read-bits payload (&mut reader) extra-count))]
              [length-symbol : i64
                (compiler-lzss-read-symbol
                  payload
                  (&mut reader)
                  (& compiler-lzss-v2-length-lookup))]
              (if (or (< bucket 0) (< extra 0) (< length-symbol 0))
                (set! error "compiler lzss: truncated v2 back-reference")
                (let
                  [d : i64
                    (if (< bucket 4)
                      bucket
                      (bit-or
                        (shl (bit-or 2 (bit-and bucket 1)) extra-count)
                        extra))]
                  [offset : i64 (+ d 1)]
                  [length : i64 (+ length-symbol 3)]
                  (cond
                    [(> offset out-index)
                      (set! error "compiler lzss: backreference before output")]
                    [(> length (- raw-len out-index))
                      (set! error "compiler lzss: token exceeds raw length")]
                    [else
                      (compiler-lzss-copy-match!
                        (unsafe
                          (__tl_array-data out))
                        out-index
                        offset
                        length)
                      (set! out-index (+ out-index length))]))))])))
    (cond
      [(> (string.string-length (& error)) 0) (Err error)]
      ;; The token stream ends in the last byte, whose padding bits are zero.
      [(!= (shr (+ reader.consumed 7) 3) reader.len)
        (Err "compiler lzss: trailing compressed bytes")]
      [(and
          (> (bit-and reader.consumed 7) 0)
          (!=
            (bit-and
              (cast (array-ref payload (+ reader.start (- reader.len 1))) : i64)
              (- (shl 1 (- 8 (bit-and reader.consumed 7))) 1))
            0))
        (Err "compiler lzss: nonzero v2 padding")]
      [else (Ok out)])))

;: Decode one complete compiler-owned envelope after bounded validation.
(define (compiler-lzss-decode
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : CompilerLzssBytes
  (if (compiler-lzss-prefix? payload (compiler-lzss-v2-prefix))
    (match (compiler-lzss-frame-with-prefix
      payload
      raw-limit
      (compiler-lzss-v2-prefix)
      48)
      [(Err message) (Err message)]
      [(Ok raw-len compressed-start)
        (compiler-lzss-decode-v2 payload compressed-start raw-len)])
    (match (compiler-lzss-frame payload raw-limit)
      [(Err message) (Err message)]
      [(Ok raw-len compressed-start)
        (compiler-lzss-decode-tokens payload compressed-start raw-len)])))