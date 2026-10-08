;; Malformed-frame coverage for the compiler-owned LZSS envelope. Keeping the
;; fixtures outside `compiler_lzss` avoids shipping test constructors in the
;; compiler that decodes the production payloads.
(import compiler_lzss as lzss)
(import stdlib.str_cat)
(import stdlib.string)

(define (compiler-lzss-test-payload
  [header : String]
  [tokens : (__tl_dyn-array u8)]) : (__tl_dyn-array u8)
  (let
    [prefix : String (lzss.compiler-lzss-envelope-prefix)]
    [prefix-len : i64 (string.string-length prefix)]
    [header-len : i64 (string.string-length header)]
    [out : (__tl_dyn-array u8)
      (__tl_make-array u8 (+ prefix-len header-len (array-length tokens)))]
    [index : i64 0]
    (while (< index prefix-len)
      (set! (array-ref out index) (cast (string.string-ref prefix index) : u8))
      (set! index (+ index 1)))
    (let
      [header-index : i64 0]
      (while (< header-index header-len)
        (set!
          (array-ref out (+ prefix-len header-index))
          (cast (string.string-ref header header-index) : u8))
        (set! header-index (+ header-index 1))))
    (let
      [token-index : i64 0]
      (while (< token-index (array-length tokens))
        (set!
          (array-ref out (+ prefix-len header-len token-index))
          (array-ref tokens token-index))
        (set! token-index (+ token-index 1))))
    out))

(define (compiler-lzss-test-rejects?
  [payload : (__tl_dyn-array u8)]
  [raw-limit : i64]
  [expected : String]) : bool
  (match (lzss.compiler-lzss-decode (& payload) raw-limit)
    [(Err message) (string.eq message expected)]
    [(Ok _) false]))

(define (compiler-lzss-test-decode
  [payload : (__tl_dyn-array u8)]
  [raw-limit : i64]) : lzss.CompilerLzssBytes
  (lzss.compiler-lzss-decode (& payload) raw-limit))

(define (compiler-lzss-self-test-status) : i64
  (cond
    [(not
        (match (compiler-lzss-test-decode
          (compiler-lzss-test-payload "6\n" (__tl_make-array 7 65 66 67 0 32))
          64)
          [(Ok bytes)
            (and
              (= (array-length bytes) 6)
              (= (array-ref bytes 0) (cast 65 : u8))
              (= (array-ref bytes 3) (cast 65 : u8))
              (= (array-ref bytes 5) (cast 67 : u8)))]
          [(Err _) false]))
      1]
    [(not
        (match (compiler-lzss-test-decode
          (compiler-lzss-test-payload "0\n" (__tl_make-array))
          0)
          [(Ok bytes) (= (array-length bytes) 0)]
          [(Err _) false]))
      2]
    [(not
        (compiler-lzss-test-rejects?
          (__tl_make-array 0)
          64
          "compiler lzss: bad envelope prefix"))
      3]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "\n" (__tl_make-array))
          64
          "compiler lzss: missing raw length"))
      4]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "1x" (__tl_make-array))
          64
          "compiler lzss: malformed raw length"))
      5]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "9223372036854775808\n" (__tl_make-array))
          9223372036854775807
          "compiler lzss: raw length overflows i64"))
      6]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload
            "65\n"
            (__tl_make-array 255 0 0 0 0 0 0 0 0))
          64
          "compiler lzss: raw length exceeds consumer limit"))
      7]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "100\n" (__tl_make-array 1 65))
          128
          "compiler lzss: impossible raw length"))
      8]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "1\n" (__tl_make-array 1))
          64
          "compiler lzss: truncated literal token"))
      9]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "3\n" (__tl_make-array 0 0))
          64
          "compiler lzss: truncated backreference token"))
      10]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "3\n" (__tl_make-array 0 0 32))
          64
          "compiler lzss: backreference before output"))
      11]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "3\n" (__tl_make-array 1 65 0 0))
          64
          "compiler lzss: token exceeds raw length"))
      12]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload
            "9\n"
            (__tl_make-array 255 65 65 65 65 65 65 65 65))
          64
          "compiler lzss: truncated token stream"))
      13]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "1\n" (__tl_make-array 1 65 99))
          64
          "compiler lzss: trailing compressed bytes"))
      14]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "0\n" (__tl_make-array))
          -1
          "compiler lzss: invalid raw length limit"))
      15]
    [else 0]))

(test
  compiler-lzss-bounded-envelope
  (if (= (compiler-lzss-self-test-status) 0)
    unit
    (string.tl_oob_abort)))

;; The checked token loop alone, as `compiler-lzss-decode-tokens` ran before it
;; gained a fast group path: the decoder must give the same bytes or the same
;; error text for every stream.
(define (compiler-lzss-test-reference-tokens
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [raw-len : i64]) : lzss.CompilerLzssBytes
  (let
    [compressed-len : i64 (- (array-length payload) start)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 raw-len)]
    [index : i64 0]
    [out-index : i64 0]
    [error : String ""]
    (while (and (string.eq error "") (< out-index raw-len))
      (if (>= index compressed-len)
        (set! error "compiler lzss: truncated token stream")
        (let
          [flags : i64 (cast (array-ref payload (+ start index)) : i64)]
          [bit : i64 0]
          (set! index (+ index 1))
          (while (and (string.eq error "") (< bit 8) (< out-index raw-len))
            (cond
              [(!= (bit-and flags (shl 1 bit)) 0)
                (if (>= index compressed-len)
                  (set! error "compiler lzss: truncated literal token")
                  (begin
                    (set!
                      (array-ref out out-index)
                      (array-ref payload (+ start index)))
                    (set! index (+ index 1))
                    (set! out-index (+ out-index 1))))]
              [(< (- compressed-len index) 2)
                (set! error "compiler lzss: truncated backreference token")]
              [else
                (let
                  [packed : i64
                    (bit-or
                      (shl (cast (array-ref payload (+ start index)) : i64) 8)
                      (cast (array-ref payload (+ start index 1)) : i64))]
                  [offset : i64 (+ (shr packed 4) 1)]
                  [length : i64 (+ (bit-and packed 15) 3)]
                  [copied : i64 0]
                  (set! index (+ index 2))
                  (cond
                    [(> offset out-index)
                      (set! error "compiler lzss: backreference before output")]
                    [(> length (- raw-len out-index))
                      (set! error "compiler lzss: token exceeds raw length")]
                    [else
                      (while (< copied length)
                        (set!
                          (array-ref out (+ out-index copied))
                          (array-ref out (- (+ out-index copied) offset)))
                        (set! copied (+ copied 1)))
                      (set! out-index (+ out-index length))]))])
            (set! bit (+ bit 1))))))
    (cond
      [(not (string.eq error "")) (Err error)]
      [(!= out-index raw-len) (Err "compiler lzss: expanded length mismatch")]
      [(!= index compressed-len)
        (Err "compiler lzss: trailing compressed bytes")]
      [else (Ok out)])))

(define (compiler-lzss-test-reference
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : lzss.CompilerLzssBytes
  (match (lzss.compiler-lzss-frame payload raw-limit)
    [(Err message) (Err message)]
    [(Ok raw-len start)
      (compiler-lzss-test-reference-tokens payload start raw-len)]))

;; Whether the decoder and the reference agree on the stream TOKENS under the
;; claimed raw length RAW-LEN.
(define (compiler-lzss-test-agrees?
  [tokens : (__tl_dyn-array u8)]
  [raw-len : i64]) : bool
  (let
    [payload : (__tl_dyn-array u8)
      (compiler-lzss-test-payload
        (str_cat.str-cat (string.int->string raw-len) "\n")
        tokens)]
    (match (lzss.compiler-lzss-decode (& payload) 16777216)
      [(Ok got)
        (match (compiler-lzss-test-reference (& payload) 16777216)
          [(Ok want)
            (and
              (= (array-length got) (array-length want))
              (let
                [index : i64 0]
                [same : bool true]
                (while (and same (< index (array-length got)))
                  (set! same (= (array-ref got index) (array-ref want index)))
                  (set! index (+ index 1)))
                same))]
          [(Err _) false])]
      [(Err got)
        (match (compiler-lzss-test-reference (& payload) 16777216)
          [(Ok _) false]
          [(Err want) (string.eq got want)])])))

(defstruct CompilerLzssTestStream
  (tokens (__tl_dyn-array u8))
  (raw-len i64))

;; A valid token stream of COUNT tokens drawn from SEED: about a quarter
;; literals, and matches of every length 3..18 whose distances are 1..8 a
;; quarter of the time (overlapping copies) and up to 4096 otherwise. A LONG
;; stream is one literal and then only 18-byte matches, so each later group
;; writes the most output a group can.
(define (compiler-lzss-test-stream [seed : i64] [count : i64] [long : bool]) : CompilerLzssTestStream
  (let
    [buf : (__tl_dyn-array u8)
      (__tl_make-array u8 (+ (* count 2) (/ count 8) 1))]
    [len : i64 0]
    [state : i64 seed]
    [out-len : i64 0]
    [token : i64 0]
    [flag-at : i64 0]
    [flags : i64 0]
    (while (< token count)
      (when
        (= (bit-and token 7) 0)
        (set! flag-at len)
        (set! len (+ len 1))
        (set! flags 0))
      (set! state (bit-and (+ (* state 1103515245) 12345) 2147483647))
      (if (or (= out-len 0) (and (not long) (< (bit-and (shr state 16) 3) 1)))
        (begin
          (set! flags (bit-or flags (shl 1 (bit-and token 7))))
          (set! (array-ref buf len) (cast (bit-and (shr state 8) 255) : u8))
          (set! len (+ len 1))
          (set! out-len (+ out-len 1)))
        (let
          [length : i64
            (if long
              18
              (+ 3 (bit-and (shr state 18) 15)))]
          [wanted : i64
            (if (= (bit-and (shr state 22) 3) 0)
              (+ 1 (bit-and (shr state 24) 7))
              (+ 1 (bit-and (shr state 4) 4095)))]
          [offset : i64
            (if (> wanted out-len)
              (+ 1 (% wanted out-len))
              wanted)]
          [packed : i64 (bit-or (shl (- offset 1) 4) (- length 3))]
          (set! (array-ref buf len) (cast (shr packed 8) : u8))
          (set! (array-ref buf (+ len 1)) (cast (bit-and packed 255) : u8))
          (set! len (+ len 2))
          (set! out-len (+ out-len length))))
      (set! (array-ref buf flag-at) (cast flags : u8))
      (set! token (+ token 1)))
    (let
      [tokens : (__tl_dyn-array u8) (__tl_make-array u8 len)]
      [index : i64 0]
      (while (< index len)
        (set! (array-ref tokens index) (array-ref buf index))
        (set! index (+ index 1)))
      (CompilerLzssTestStream tokens out-len))))

(define (compiler-lzss-test-prefix
  [tokens : (& tokens (__tl_dyn-array u8))]
  [len : i64]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 len)]
    [index : i64 0]
    (while (< index len)
      (set! (array-ref out index) (array-ref tokens index))
      (set! index (+ index 1)))
    out))

;; 0 when the decoder agrees with the reference on the stream from SEED and
;; COUNT and on every variant of it: the stream cut after each of its bytes,
;; each byte flipped two ways (turning literals into matches, distances into
;; ones before the output, and so on), and claimed raw lengths one short and
;; one long. Otherwise the first variant that disagrees, as a code.
(define (compiler-lzss-test-differential-status
  [seed : i64]
  [count : i64]
  [long : bool]) : i64
  (let
    [stream : CompilerLzssTestStream
      (compiler-lzss-test-stream seed count long)]
    [tokens : (__tl_dyn-array u8) stream.tokens]
    [raw-len : i64 stream.raw-len]
    [len : i64 (array-length tokens)]
    [status : i64 0]
    [index : i64 0]
    (cond
      [(not (compiler-lzss-test-agrees? (clone tokens) raw-len))
        (set! status 1)]
      [(not (compiler-lzss-test-agrees? (clone tokens) (+ raw-len 1)))
        (set! status 2)]
      [(not (compiler-lzss-test-agrees? (clone tokens) (/ raw-len 2)))
        (set! status 3)]
      [else unit])
    ;; Claimed lengths short of the stream put the end of the output where
    ;; plenty of input remains, at every distance up to the fast path's
    ;; output room.
    (let
      [short : i64 1]
      (while (and (= status 0) (<= short 160) (< short raw-len))
        (unless
          (compiler-lzss-test-agrees? (clone tokens) (- raw-len short))
          (set! status (+ 100 short)))
        (set! short (+ short 1))))
    (while (and (= status 0) (< index len))
      (let
        [flipped : (__tl_dyn-array u8) (clone tokens)]
        [high : (__tl_dyn-array u8) (clone tokens)]
        (set!
          (array-ref flipped index)
          (cast (bit-xor (cast (array-ref tokens index) : i64) 90) : u8))
        (set!
          (array-ref high index)
          (cast (bit-xor (cast (array-ref tokens index) : i64) 240) : u8))
        (cond
          [(not
              (compiler-lzss-test-agrees?
                (compiler-lzss-test-prefix (& tokens) index)
                raw-len))
            (set! status (+ 1000 index))]
          [(not (compiler-lzss-test-agrees? flipped raw-len))
            (set! status (+ 100000 index))]
          [(not (compiler-lzss-test-agrees? high raw-len))
            (set! status (+ 10000000 index))]
          [else unit]))
      (set! index (+ index 1)))
    status))

;; The fast group path must reproduce the checked loop: long streams that use
;; it for most groups, a short one that never reaches it, one whose groups each
;; write the most output a group can, and every truncation, corruption and
;; wrong raw length of each.
(test
  compiler-lzss-fast-path-matches-checked-loop
  (if (and
    (= (compiler-lzss-test-differential-status 1 400 false) 0)
    (= (compiler-lzss-test-differential-status 7 23 false) 0)
    (= (compiler-lzss-test-differential-status 12345 900 false) 0)
    (= (compiler-lzss-test-differential-status 99 200 true) 0))
    unit
    (string.tl_oob_abort)))