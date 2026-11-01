(import stdlib.byte_buf)
(import stdlib.crypto_secret as secret)
(import stdlib.crypto_aes_core as aes)
(import stdlib.test)
(import stdlib.string)

;: Decode only public hexadecimal vector material.
(define (public-hex [text : String]) : byte_buf.ByteBuf
  (let
    [result : byte_buf.ByteBuf (byte_buf.new)]
    [source : (& text bytes) (byte_buf.str-as-bytes (& text))]
    [index : i64 0]
    (while (< index (byte_buf.bytes-length source))
      (let
        [high : i64 (cast (byte_buf.bytes-ref source index) : i64)]
        [low : i64 (cast (byte_buf.bytes-ref source (+ index 1)) : i64)]
        (set!
          high
          (if (<= high 57)
            (- high 48)
            (- high 87)))
        (set!
          low
          (if (<= low 57)
            (- low 48)
            (- low 87)))
        (set! result (byte_buf.push result (cast (+ (* high 16) low) : u8))))
      (set! index (+ index 2)))
    result))

;: Import a public vector into opaque secret storage.
(define (fixed-hex [size : secret.SecretSize] [text : String]) : secret.SecretFixed
  (let
    [bytes : byte_buf.ByteBuf (public-hex text)]
    (match (secret.fixed-from-bytes size (byte_buf.as-bytes (& bytes)))
      [(SecretFixedOk value) value]
      [(SecretFixedErr _)
        (test.assert-true false "invalid public AES vector")
        (secret.fixed-zero size)])))

;: Compare opaque outputs without reading secret bytes.
(define (equal-fixed?
  [left : (& left secret.SecretFixed)]
  [right : (& right secret.SecretFixed)]) : bool
  (match (secret.fixed-equal left right)
    [(SecretCompareOk equal) equal]
    [(SecretCompareErr _) false]))

;: Both variants use the same public plaintext/output driver.
(define (vector
  [wide : bool]
  [key-text : String]
  [plain-text : String]
  [cipher-text : String]) : unit
  (let
    [key : secret.SecretFixed
      (fixed-hex
        (if wide
          (secret.Secret32)
          (secret.Secret16))
        key-text)]
    [source : secret.SecretFixed (fixed-hex (secret.Secret16) plain-text)]
    [destination : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [expected : secret.SecretFixed (fixed-hex (secret.Secret16) cipher-text)]
    (if wide
      (match (aes.new-256 key)
        [(Aes256Ok schedule)
          (match (aes.encrypt-256! (& schedule) (& source) (&mut destination))
            [(AesOk) unit]
            [_ (test.assert-true false "AES-256 block status")])
          (aes.close-256 schedule)]
        [_ (test.assert-true false "AES-256 construction")])
      (match (aes.new-128 key)
        [(Aes128Ok schedule)
          (match (aes.encrypt-128! (& schedule) (& source) (&mut destination))
            [(AesOk) unit]
            [_ (test.assert-true false "AES-128 block status")])
          (aes.close-128 schedule)]
        [_ (test.assert-true false "AES-128 construction")]))
    (test.assert-true
      (equal-fixed? (& destination) (& expected))
      "FIPS forward cipher")
    (secret.close-fixed source)
    (secret.close-fixed destination)
    (secret.close-fixed expected)))

(test
  aes-fips-forward
  (begin
    (vector
      false
      "000102030405060708090a0b0c0d0e0f"
      "00112233445566778899aabbccddeeff"
      "69c4e0d86a7b0430d8cdb78070b4c55a")
    (vector
      true
      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
      "00112233445566778899aabbccddeeff"
      "8ea2b7ca516745bfeafc49904b496089")))

;: Shared bounded driver for the generated public KAT corpus.
(define (corpus [wide : bool] [count : i64] [data : String]) : unit
  (let
    [key-length : i64
      (if wide
        64
        32)]
    [stride : i64 (+ key-length 64)]
    [index : i64 0]
    (test.assert-i64-eq
      (string.string-length (& data))
      (* count stride)
      "complete pinned corpus")
    (while (< index count)
      (let
        [offset : i64 (* index stride)]
        (vector
          wide
          (string.substring (& data) offset key-length)
          (string.substring (& data) (+ offset key-length) 32)
          (string.substring (& data) (+ offset (+ key-length 32)) 32)))
      (set! index (+ index 1)))))