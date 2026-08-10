;; Malformed-frame coverage for the compiler-owned LZSS envelope. Keeping the
;; fixtures outside `compiler_lzss` avoids shipping test constructors in the
;; compiler that decodes the production payloads.
(import compiler_lzss as lzss)
(import stdlib.array)
(import stdlib.string)

(define (compiler-lzss-test-payload
  [header : String]
  [tokens : (__tl_dyn-array u8)]) : (__tl_dyn-array u8)
  (let
    [prefix : String (lzss.compiler-lzss-envelope-prefix)]
    [prefix-len : i64 (string.string-length prefix)]
    [header-len : i64 (string.string-length header)]
    [out : (__tl_dyn-array u8)
      (array.make-array u8 (+ prefix-len header-len (array-length tokens)))]
    [index : i64 0]
    (begin
      (while (< index prefix-len)
        (begin
          (set!
            (array-ref out index)
            (cast (string.string-ref prefix index) : u8))
          (set! index (+ index 1))))
      (let
        [header-index : i64 0]
        (while (< header-index header-len)
          (begin
            (set!
              (array-ref out (+ prefix-len header-index))
              (cast (string.string-ref header header-index) : u8))
            (set! header-index (+ header-index 1)))))
      (let
        [token-index : i64 0]
        (while (< token-index (array-length tokens))
          (begin
            (set!
              (array-ref out (+ prefix-len header-len token-index))
              (array-ref tokens token-index))
            (set! token-index (+ token-index 1)))))
      out)))

(define (compiler-lzss-test-rejects?
  [payload : (__tl_dyn-array u8)]
  [raw-limit : i64]
  [expected : String]) : bool
  (match (lzss.compiler-lzss-decode (& payload) raw-limit)
    [(lzss.CompilerLzssBytes.Err message) (string.eq message expected)]
    [(lzss.CompilerLzssBytes.Ok _) false]))

(define (compiler-lzss-test-decode
  [payload : (__tl_dyn-array u8)]
  [raw-limit : i64]) : lzss.CompilerLzssBytes
  (lzss.compiler-lzss-decode (& payload) raw-limit))

(define (compiler-lzss-self-test-status) : i64
  (cond
    [(not
        (match (compiler-lzss-test-decode
          (compiler-lzss-test-payload "6\n" (make-array 7 65 66 67 0 32))
          64)
          [(lzss.CompilerLzssBytes.Ok bytes)
            (and
              (= (array-length bytes) 6)
              (= (array-ref bytes 0) (cast 65 : u8))
              (= (array-ref bytes 3) (cast 65 : u8))
              (= (array-ref bytes 5) (cast 67 : u8)))]
          [(lzss.CompilerLzssBytes.Err _) false]))
      1]
    [(not
        (match (compiler-lzss-test-decode
          (compiler-lzss-test-payload "0\n" (make-array))
          0)
          [(lzss.CompilerLzssBytes.Ok bytes) (= (array-length bytes) 0)]
          [(lzss.CompilerLzssBytes.Err _) false]))
      2]
    [(not
        (compiler-lzss-test-rejects?
          (make-array 0)
          64
          "compiler lzss: bad envelope prefix"))
      3]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "\n" (make-array))
          64
          "compiler lzss: missing raw length"))
      4]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "1x" (make-array))
          64
          "compiler lzss: malformed raw length"))
      5]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "9223372036854775808\n" (make-array))
          9223372036854775807
          "compiler lzss: raw length overflows i64"))
      6]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "65\n" (make-array 255 0 0 0 0 0 0 0 0))
          64
          "compiler lzss: raw length exceeds consumer limit"))
      7]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "100\n" (make-array 1 65))
          128
          "compiler lzss: impossible raw length"))
      8]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "1\n" (make-array 1))
          64
          "compiler lzss: truncated literal token"))
      9]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "3\n" (make-array 0 0))
          64
          "compiler lzss: truncated backreference token"))
      10]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "3\n" (make-array 0 0 32))
          64
          "compiler lzss: backreference before output"))
      11]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "3\n" (make-array 1 65 0 0))
          64
          "compiler lzss: token exceeds raw length"))
      12]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload
            "9\n"
            (make-array 255 65 65 65 65 65 65 65 65))
          64
          "compiler lzss: truncated token stream"))
      13]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "1\n" (make-array 1 65 99))
          64
          "compiler lzss: trailing compressed bytes"))
      14]
    [(not
        (compiler-lzss-test-rejects?
          (compiler-lzss-test-payload "0\n" (make-array))
          -1
          "compiler lzss: invalid raw length limit"))
      15]
    [else 0]))

(test
  compiler-lzss-bounded-envelope
  (if (= (compiler-lzss-self-test-status) 0)
    unit
    (string.tl_oob_abort)))