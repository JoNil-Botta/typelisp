;; Payload codec coverage: the fixed model, the coding ladders, byte-exact
;; round trips and the rejection of malformed or truncated frames.
(import stdlib.string)
(import stdlib.byte_buf_core)
(import compiler_lzss as lzss)

;; Every table of the fixed model is a complete prefix code: each symbol has a
;; code, no code is longer than the maximum, and the Kraft sum never exceeds
;; one (so no two symbols can share a code).
(define (compiler-lzss-test-kraft-ok?
  [lengths : (& lengths (__tl_dyn-array i64))]
  [start : i64]
  [n : i64]) : bool
  (let
    [limit : i64 (shl 1 (lzss.compiler-lzss-max-code-bits))]
    [sum : i64 0]
    [index : i64 0]
    [ok : bool true]
    (while (< index n)
      (let
        [length : i64 (array-ref lengths (+ start index))]
        (cond
          [(<= length 0) (set! ok false)]
          [(> length (lzss.compiler-lzss-max-code-bits)) (set! ok false)]
          [else (+= sum (shl 1 (- (lzss.compiler-lzss-max-code-bits) length)))]))
      (set! index (+ index 1)))
    (and ok (<= sum limit))))

(define (compiler-lzss-test-model-ok?) : bool
  (let
    [lengths : (__tl_dyn-array i64)
      (lzss.compiler-lzss-spec-lengths (& lzss.compiler-lzss-fixed-spec))]
    [contexts : i64 (lzss.compiler-lzss-contexts)]
    [main-symbols : i64 (lzss.compiler-lzss-main-symbols)]
    [length-start : i64 (* contexts main-symbols)]
    [distance-start : i64 (+ length-start (lzss.compiler-lzss-length-symbols))]
    [context : i64 0]
    [ok : bool (= (array-length lengths) (lzss.compiler-lzss-model-spec-bytes))]
    (while (and ok (< context contexts))
      (unless
        (compiler-lzss-test-kraft-ok?
          (& lengths)
          (* context main-symbols)
          main-symbols)
        (set! ok false))
      (set! context (+ context 1)))
    (when
      ok
      (unless
        (compiler-lzss-test-kraft-ok?
          (& lengths)
          length-start
          (lzss.compiler-lzss-length-symbols))
        (set! ok false)))
    (set! context 0)
    (while (and ok (< context (lzss.compiler-lzss-length-buckets)))
      (unless
        (compiler-lzss-test-kraft-ok?
          (& lengths)
          (+ distance-start (* context (lzss.compiler-lzss-distance-symbols)))
          (lzss.compiler-lzss-distance-symbols))
        (set! ok false))
      (set! context (+ context 1)))
    ok))

;; A length symbol covers exactly its own base range, and so does a distance.
(define (compiler-lzss-test-ladders-ok?) : bool
  (let
    [length : i64 (lzss.compiler-lzss-min-match)]
    [ok : bool true]
    [distance : i64 1]
    (while (and ok (<= length (lzss.compiler-lzss-max-match)))
      (let
        [slot : i64 (lzss.compiler-lzss-length-slot length)]
        [base : i64 (lzss.compiler-lzss-length-base slot)]
        [span : i64 (shl 1 (lzss.compiler-lzss-length-extra slot))]
        (unless
          (and (>= slot 0) (>= length base) (<= length (- (+ base span) 1)))
          (set! ok false)))
      (set! length (+ length 1)))
    (while (and ok (<= distance (lzss.compiler-lzss-window)))
      (let
        [slot : i64 (lzss.compiler-lzss-distance-slot distance)]
        [base : i64 (lzss.compiler-lzss-distance-base slot)]
        [span : i64 (shl 1 (lzss.compiler-lzss-distance-extra slot))]
        (unless
          (and
            (>= slot 0)
            (< slot (lzss.compiler-lzss-distance-symbols))
            (>= distance base)
            (<= distance (- (+ base span) 1)))
          (set! ok false)))
      (set! distance (* distance 2)))
    ;; Every small distance too, not only the powers of two.
    (set! distance 1)
    (while (and ok (<= distance 8192))
      (let
        [slot : i64 (lzss.compiler-lzss-distance-slot distance)]
        [base : i64 (lzss.compiler-lzss-distance-base slot)]
        [span : i64 (shl 1 (lzss.compiler-lzss-distance-extra slot))]
        (unless
          (and (>= distance base) (<= distance (- (+ base span) 1)))
          (set! ok false)))
      (set! distance (+ distance 1)))
    ok))

;; --- frame fixtures ---------------------------------------------------------
(define (compiler-lzss-test-bytes-of [text : (& text str)]) : (__tl_dyn-array
    u8)
  (let
    [n : i64 (string.string-length text)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [index : i64 0]
    (while (< index n)
      (set! (array-ref out index) (cast (string.string-ref text index) : u8))
      (set! index (+ index 1)))
    out))

(define (compiler-lzss-test-same?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [text : (& text str)]) : bool
  (let
    [n : i64 (string.string-length text)]
    [same : bool (= (array-length bytes) n)]
    [index : i64 0]
    (while (and same (< index n))
      (unless
        (= (array-ref bytes index) (cast (string.string-ref text index) : u8))
        (set! same false))
      (set! index (+ index 1)))
    same))

;; Pseudo-random bytes as a String, built through a byte buffer.
(define (compiler-lzss-test-noise [seed : i64] [count : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity count)]
    [state : i64 seed]
    [index : i64 0]
    (while (< index count)
      (set! state (% (+ (* state 1103515245) 12345) 2147483648))
      (byte_buf_core.byte-buf-builder-push
        (&mut out)
        (cast (% (shr state 16) 37) : u8))
      (set! index (+ index 1)))
    (byte_buf_core.byte-buf-builder-to-string (& out))))

(define (compiler-lzss-test-round-trip? [text : (& text str)]) : bool
  (let
    [payload : String (lzss.compiler-lzss-encode text)]
    [packed : (__tl_dyn-array u8) (compiler-lzss-test-bytes-of (& payload))]
    (match (lzss.compiler-lzss-decode (& packed) 268435456)
      [(Err _) false]
      [(Ok bytes) (compiler-lzss-test-same? (& bytes) text)])))

;; Corrupting any single byte of a valid payload may decode to different bytes,
;; but it must never abort: every code, length and distance is checked.
(define (compiler-lzss-test-corrupt-safe? [text : (& text str)]) : bool
  (let
    [payload : String (lzss.compiler-lzss-encode text)]
    [clean : (__tl_dyn-array u8) (compiler-lzss-test-bytes-of (& payload))]
    [len : i64 (array-length clean)]
    [position : i64 0]
    [safe : bool true]
    (while (and safe (< position len))
      (let
        [broken : (__tl_dyn-array u8) (compiler-lzss-test-bytes-of (& payload))]
        (set!
          (array-ref broken position)
          (cast
            (bit-and (+ (cast (array-ref broken position) : i64) 129) 255)
            : u8))
        (match (lzss.compiler-lzss-decode (& broken) 268435456)
          [(Ok _) unit]
          [(Err _) unit]))
      (set! position (+ position 1)))
    safe))

;; Every proper truncation is rejected.
(define (compiler-lzss-test-truncations-rejected? [text : (& text str)]) : bool
  (let
    [payload : String (lzss.compiler-lzss-encode text)]
    [clean : (__tl_dyn-array u8) (compiler-lzss-test-bytes-of (& payload))]
    [len : i64 (array-length clean)]
    [keep : i64 0]
    [ok : bool true]
    (while (and ok (< keep len))
      (let
        [cut : (__tl_dyn-array u8) (__tl_make-array u8 keep)]
        [index : i64 0]
        (while (< index keep)
          (set! (array-ref cut index) (array-ref clean index))
          (set! index (+ index 1)))
        (match (lzss.compiler-lzss-decode (& cut) 268435456)
          [(Ok _) (set! ok false)]
          [(Err _) unit]))
      (set! keep (+ keep 1)))
    ok))

(define (compiler-lzss-test-rejects?
  [payload : (__tl_dyn-array u8)]
  [raw-limit : i64]) : bool
  (match (lzss.compiler-lzss-decode (& payload) raw-limit)
    [(Ok _) false]
    [(Err _) true]))

(define (compiler-lzss-test-header-attack?
  [text : (& text str)]
  [raw-len-delta : i64]) : bool
  (let
    [payload : String (lzss.compiler-lzss-encode text)]
    [packed : (__tl_dyn-array u8) (compiler-lzss-test-bytes-of (& payload))]
    [prefix-len : i64
      (string.string-length (lzss.compiler-lzss-envelope-prefix))]
    [raw : i64 (+ (string.string-length text) raw-len-delta)]
    [patched : (__tl_dyn-array u8)
      (compiler-lzss-test-patch-header packed prefix-len raw)]
    (compiler-lzss-test-rejects? patched 268435456)))

;; Rebuild a payload with its decimal raw length replaced.
(define (compiler-lzss-test-patch-header
  [packed : (& packed (__tl_dyn-array u8))]
  [prefix-len : i64]
  [raw : i64]) : (__tl_dyn-array u8)
  (let
    [text : String (string.int->string raw)]
    [digits : i64 (string.string-length (& text))]
    [end : i64 prefix-len]
    (while (and
      (< end (array-length packed))
      (>= (cast (array-ref packed end) : i64) 48)
      (<= (cast (array-ref packed end) : i64) 57))
      (set! end (+ end 1)))
    (let
      [tail : i64 (- (array-length packed) end)]
      [out : (__tl_dyn-array u8)
        (__tl_make-array u8 (+ prefix-len digits tail))]
      [index : i64 0]
      (while (< index prefix-len)
        (set! (array-ref out index) (array-ref packed index))
        (set! index (+ index 1)))
      (set! index 0)
      (while (< index digits)
        (set!
          (array-ref out (+ prefix-len index))
          (cast (string.string-ref (& text) index) : u8))
        (set! index (+ index 1)))
      (set! index 0)
      (while (< index tail)
        (set!
          (array-ref out (+ prefix-len digits index))
          (array-ref packed (+ end index)))
        (set! index (+ index 1)))
      out)))

(define (compiler-lzss-test-trailing-byte-rejected? [text : (& text str)]) : bool
  (let
    [payload : String (lzss.compiler-lzss-encode text)]
    [packed : (__tl_dyn-array u8) (compiler-lzss-test-bytes-of (& payload))]
    [len : i64 (array-length packed)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 (+ len 1))]
    [index : i64 0]
    (while (< index len)
      (set! (array-ref out index) (array-ref packed index))
      (set! index (+ index 1)))
    (set! (array-ref out len) (cast 0 : u8))
    (compiler-lzss-test-rejects? out 268435456)))

(define (compiler-lzss-test-wrong-prefix-rejected? [text : (& text str)]) : bool
  (let
    [payload : String (lzss.compiler-lzss-encode text)]
    [packed : (__tl_dyn-array u8) (compiler-lzss-test-bytes-of (& payload))]
    (set! (array-ref packed 0) (cast 88 : u8))
    (compiler-lzss-test-rejects? packed 268435456)))

(define (compiler-lzss-codec-status) : i64
  (let
    [noise : String (compiler-lzss-test-noise 4242 6000)]
    [repeat : String
      (string.copy
        "the quick brown fox jumps over the lazy dog; the quick brown fox\n")]
    (cond
      [(not (compiler-lzss-test-model-ok?)) 1]
      [(not (compiler-lzss-test-ladders-ok?)) 2]
      [(not (compiler-lzss-test-round-trip? "")) 3]
      [(not (compiler-lzss-test-round-trip? "a")) 4]
      [(not (compiler-lzss-test-round-trip? "abcabcabcabcabcabc")) 5]
      [(not (compiler-lzss-test-round-trip? (& repeat))) 6]
      [(not (compiler-lzss-test-round-trip? (& noise))) 7]
      [(not (compiler-lzss-test-corrupt-safe? (& noise))) 8]
      [(not (compiler-lzss-test-truncations-rejected? "abcdefghij")) 9]
      [(not (compiler-lzss-test-truncations-rejected? (& noise))) 10]
      [(not (compiler-lzss-test-header-attack? (& repeat) 1)) 11]
      [(not (compiler-lzss-test-header-attack? (& repeat) -1)) 12]
      [(not (compiler-lzss-test-trailing-byte-rejected? (& repeat))) 13]
      [(not (compiler-lzss-test-wrong-prefix-rejected? (& repeat))) 14]
      ;; A consumer limit below the raw length rejects before allocating.
      [(not
          (let
            [payload : String (lzss.compiler-lzss-encode (& repeat))]
            [packed : (__tl_dyn-array u8)
              (compiler-lzss-test-bytes-of (& payload))]
            (compiler-lzss-test-rejects? packed 8)))
        15]
      [else 0])))

(test
  compiler-lzss-payload-codec
  (if (= (compiler-lzss-codec-status) 0)
    unit
    (string.tl_oob_abort)))