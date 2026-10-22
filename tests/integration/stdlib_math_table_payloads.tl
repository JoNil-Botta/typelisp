;; SHA-256 of every original table word in little-endian order. The pins were
;; captured through the old native accessors and independently checked against
;; their decimal/integer literals before the data rewrite. The existing exp
;; fixture also keeps its individual 128 tail-word comparisons.
(import stdlib.math)
(import stdlib.byte_buf)
(import stdlib.crypto_sha256 as sha)
(import stdlib.iterator)
(import stdlib.string)

(define (payload-digest-matches? [data : (& data bytes)] [expected : String]) : bool
  (match (sha.digest data)
    [(sha.Sha256FinalizeOk digest)
      (let
        [actual : String (sha.to-hex (& digest))]
        (string.eq (& actual) (& expected)))]
    [(sha.Sha256FinalizeErr _) false]))

(defmacro (table-payload? [table : Expr] [count : Expr] [expected : Expr]) : Expr
  `(if (= (array-length ,table) ,count)
    (let
      [data (byte_buf.new)]
      (for [index (iterator.range 0 ,count)]
        (let
          [word : u64 (array-ref ,table index)]
          (for [byte-index (iterator.range 0 8)]
            (set!
              data
              (byte_buf.push data (cast (shr word (* byte-index 8)) : u8))))))
      (payload-digest-matches? (byte_buf.as-bytes (& data)) ,expected))
    false))

(define (main) : i64
  (if (and
    (table-payload?
      math.math-exp-f64-tail-bits
      128
      "ad50743c924d89be38fa8324ef5378d6fa1f6c5462d9f9bfaec3cc2f33042c92")
    (table-payload?
      math.math-exp-f64-scale-bits
      128
      "a204e24ebe681d121af780d91a6577cd50c427c155d274a4e3ed7c2d24100caa")
    (table-payload?
      math.math-log-f64-invc-bits
      128
      "5df959c56038efe36a1aa313afb2573a7a5a86d63ed22fab1255df563dbccc95")
    (table-payload?
      math.math-log-f64-logc-bits
      128
      "87dfb37d6488e7825fa5901aa1b8d8a2bc18f45851afc8cabd2d5bd2f090f081")
    (table-payload?
      math.math-log-f64-chi-bits
      128
      "171d64cd8ea0d9ac5555f4e08b65c9b08dca9d4d004baca6a2d82d83c2e18d84")
    (table-payload?
      math.math-log-f64-clo-bits
      128
      "ed35ce4c88a46b43bf1ab651960103fc78e1b3dc189da08037464a98f74390cc")
    (table-payload?
      math.math-log-f32-invc-bits
      16
      "d4a2dc419380c9b2269f19e912dfd174da71c29e6fad3ef15729db7d0283a414")
    (table-payload?
      math.math-log-f32-logc-bits
      16
      "9201f6260e57bddd938bee9bc48cabdc5954b9446217fc230bf85c5b7fd042a0")
    (table-payload?
      math.math-pow-f64-invc-bits
      128
      "3b7c0dfd0e970e760517c9a21082188cce679b6d0b33f889939dfc0c0e68e649")
    (table-payload?
      math.math-pow-f64-logc-bits
      128
      "090624e106a48fa0828867cc3a66f7e2feeafd7bda56f57d6109c22df3708c97")
    (table-payload?
      math.math-pow-f64-logctail-bits
      128
      "aa9c0df3d556a047c32849d1a2845ad36baa181af64507c835cb5b0212998bd0")
    (table-payload?
      math.math-pow-f32-invc-bits
      16
      "d4a2dc419380c9b2269f19e912dfd174da71c29e6fad3ef15729db7d0283a414")
    (table-payload?
      math.math-pow-f32-logc-bits
      16
      "4fbf676de68b5f913f4f53ce38d1b0bb37eb2f000950a176d756a5ccc89e8e8d")
    (table-payload?
      math.math-trig-two-over-pi-limbs
      66
      "97803ae487c99c2c2518728ac45221b9ec30a816fad66cfda960f310588438a6")
    (table-payload?
      math.math-trig-pi-over-two-piece-bits
      8
      "ec3438eea867cafc272d028cf3100321d6872483009c3d7cd2d938afacf57920"))
    42
    1))