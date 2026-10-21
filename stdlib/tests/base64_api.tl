(import stdlib.base64)
(import stdlib.byte_buf)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.test)

(define (fail [message : String]) : unit
  (test.assert-true false message))

(define (error-kind-code [kind : base64.Base64ErrorKind]) : i64
  (match kind
    [(base64.Base64InvalidLength) 0]
    [(base64.Base64InvalidCharacter) 1]
    [(base64.Base64InvalidPadding) 2]
    [(base64.Base64NonZeroPadBits) 3]
    [(base64.Base64LengthOverflow) 4]
    [(base64.Base64DestinationTooSmall) 5]
    [(base64.Base64DestinationOverlap) 6]
    [(base64.Base64InvalidLimit) 7]
    [(base64.Base64OutputLimitExceeded) 8]))

(define (standard-byte? [code : i64]) : bool
  (or
    (and (>= code 65) (<= code 90))
    (and (>= code 97) (<= code 122))
    (and (>= code 48) (<= code 57))
    (= code 43)
    (= code 47)))

(define (one-byte-buf [a : i64]) : byte_buf.ByteBuf
  (byte_buf.push (byte_buf.new) (cast a : u8)))

(define (two-byte-buf [a : i64] [b : i64]) : byte_buf.ByteBuf
  (byte_buf.push (byte_buf.push (byte_buf.new) (cast a : u8)) (cast b : u8)))

(define (three-byte-buf [a : i64] [b : i64] [c : i64]) : byte_buf.ByteBuf
  (byte_buf.push
    (byte_buf.push (byte_buf.push (byte_buf.new) (cast a : u8)) (cast b : u8))
    (cast c : u8)))

(define (four-byte-buf [a : i64] [b : i64] [c : i64] [d : i64]) : byte_buf.ByteBuf
  (byte_buf.push
    (byte_buf.push
      (byte_buf.push (byte_buf.push (byte_buf.new) (cast a : u8)) (cast b : u8))
      (cast c : u8))
    (cast d : u8)))

(define (pattern-byte [index : i64]) : i64
  (% (+ (* index 73) 19) 256))

(define (pattern-buf [length : i64] [position : i64] [code : i64]) : byte_buf.ByteBuf
  (let
    [buf : byte_buf.ByteBuf (byte_buf.with-capacity length)]
    [index : i64 0]
    (while (< index length)
      (let
        [value : i64
          (if (= index position)
            code
            (pattern-byte index))]
        (set! buf (byte_buf.push buf (cast value : u8)))
        (set! index (+ index 1))))
    buf))

(define (expected-encoded-length [length : i64]) : i64
  (let
    [quanta : i64 (/ length 3)]
    [remainder : i64 (- length (* quanta 3))]
    (if (= remainder 0)
      (* quanta 4)
      (+ (* quanta 4) 4))))

(define (assert-encode-buffer
  [input : (& input bytes)]
  [expected : String]
  [message : String]) : unit
  (match (base64.encode input 1024)
    [(base64.Base64EncodeErr _) (fail message)]
    [(base64.Base64EncodeOk encoded)
      (let
        [actual : String (byte_buf.to-string encoded)]
        (test.assert-string-eq (& actual) (& expected) message))]))

(define (assert-encode-text [text : String] [expected : String]) : unit
  (assert-encode-buffer (byte_buf.str-as-bytes (& text)) expected (clone text)))

(define (assert-decode-text [encoded : String] [expected : String]) : unit
  (match (base64.decode (byte_buf.str-as-bytes (& encoded)) 1024)
    [(base64.Base64DecodeErr _) (fail encoded)]
    [(base64.Base64DecodeOk decoded)
      (let
        [actual : String (byte_buf.to-string decoded)]
        (test.assert-string-eq (& actual) (& expected) encoded))]))

(define (assert-decode-ok-length
  [encoded : String]
  [expected : i64]
  [message : String]) : unit
  (match (base64.decoded-length (byte_buf.str-as-bytes (& encoded)) 1024)
    [(base64.Base64LengthErr _) (fail message)]
    [(base64.Base64LengthOk length)
      (test.assert-i64-eq length expected message)]))

(define (assert-decode-error
  [encoded : String]
  [expected-kind : i64]
  [expected-offset : i64]) : unit
  (match (base64.decode (byte_buf.str-as-bytes (& encoded)) 1024)
    [(base64.Base64DecodeOk _) (fail encoded)]
    [(base64.Base64DecodeErr error)
      (test.assert-i64-eq
        (error-kind-code error.kind)
        expected-kind
        "decode error kind")
      (test.assert-i64-eq error.offset expected-offset "decode error offset")]))

(define (assert-buffer-decode-error
  [input : (& input bytes)]
  [expected-kind : i64]
  [expected-offset : i64]
  [message : String]) : unit
  (match (base64.decode input 1024)
    [(base64.Base64DecodeOk _) (fail message)]
    [(base64.Base64DecodeErr error)
      (test.assert-i64-eq
        (error-kind-code error.kind)
        expected-kind
        "decode error kind")
      (test.assert-i64-eq error.offset expected-offset "decode error offset")]))

(define (assert-roundtrip-buffer [input : (& input bytes)] [message : String]) : unit
  (let
    [input-length : i64 (byte_buf.bytes-length input)]
    (match (base64.encoded-length input 1024)
      [(base64.Base64LengthErr _) (fail message)]
      [(base64.Base64LengthOk encoded-length)
        (test.assert-i64-eq
          encoded-length
          (expected-encoded-length input-length)
          (clone message))
        (match (base64.encode input 1024)
          [(base64.Base64EncodeErr _) (fail message)]
          [(base64.Base64EncodeOk encoded)
            (test.assert-i64-eq
              (byte_buf.len encoded)
              encoded-length
              (clone message))
            (match (base64.decode (byte_buf.as-bytes (& encoded)) 1024)
              [(base64.Base64DecodeErr _) (fail message)]
              [(base64.Base64DecodeOk decoded)
                (let
                  [index : i64 0]
                  (test.assert-i64-eq
                    (byte_buf.len decoded)
                    input-length
                    (clone message))
                  (while (< index input-length)
                    (begin
                      (test.assert-i64-eq
                        (cast (byte_buf.ref decoded index) : i64)
                        (cast (byte_buf.bytes-ref input index) : i64)
                        (clone message))
                      (set! index (+ index 1))))
                  unit)])])])))

(define (assert-rfc-vectors) : unit
  (assert-encode-text "" "")
  (assert-encode-text "f" "Zg==")
  (assert-encode-text "fo" "Zm8=")
  (assert-encode-text "foo" "Zm9v")
  (assert-encode-text "foob" "Zm9vYg==")
  (assert-encode-text "fooba" "Zm9vYmE=")
  (assert-encode-text "foobar" "Zm9vYmFy")
  (assert-encode-text "s" "cw==")
  (assert-encode-text "su" "c3U=")
  (assert-encode-text "sur" "c3Vy")
  (assert-encode-text "sure" "c3VyZQ==")
  (assert-encode-text "sure." "c3VyZS4=")
  (assert-encode-text "M" "TQ==")
  (assert-encode-text "Ma" "TWE=")
  (assert-encode-text "Man" "TWFu")
  (assert-decode-text "" "")
  (assert-decode-text "Zg==" "f")
  (assert-decode-text "Zm8=" "fo")
  (assert-decode-text "Zm9v" "foo")
  (assert-decode-text "Zm9vYg==" "foob")
  (assert-decode-text "Zm9vYmE=" "fooba")
  (assert-decode-text "Zm9vYmFy" "foobar")
  (assert-decode-text "cw==" "s")
  (assert-decode-text "c3U=" "su")
  (assert-decode-text "c3Vy" "sur")
  (assert-decode-text "c3VyZQ==" "sure")
  (assert-decode-text "c3VyZS4=" "sure.")
  (assert-decode-text "TQ==" "M")
  (assert-decode-text "TWE=" "Ma")
  (assert-decode-text "TWFu" "Man")
  (assert-decode-ok-length "" 0 "empty encoded length")
  (assert-decode-ok-length "Zg==" 1 "one byte decoded length")
  (assert-decode-ok-length "Zm8=" 2 "two byte decoded length")
  (assert-decode-ok-length "Zm9v" 3 "three byte decoded length")
  (assert-decode-ok-length "Zm9vYg==" 4 "four byte decoded length")
  (assert-decode-ok-length "Zm9vYmE=" 5 "five byte decoded length")
  (assert-decode-ok-length "Zm9vYmFy" 6 "six byte decoded length"))

(define (assert-binary-fixtures) : unit
  (let
    [zero : byte_buf.ByteBuf (one-byte-buf 0)]
    [zero-one : byte_buf.ByteBuf (two-byte-buf 0 255)]
    [high : byte_buf.ByteBuf (three-byte-buf 251 255 191)]
    [zeros : byte_buf.ByteBuf (three-byte-buf 0 0 0)]
    [ones : byte_buf.ByteBuf (three-byte-buf 255 255 255)]
    (assert-encode-buffer (byte_buf.as-bytes (& zero)) "AA==" "one NUL byte")
    (assert-encode-buffer (byte_buf.as-bytes (& zero-one)) "AP8=" "NUL then FF")
    (assert-encode-buffer (byte_buf.as-bytes (& high)) "+/+/" "high bytes")
    (assert-encode-buffer
      (byte_buf.as-bytes (& zeros))
      "AAAA"
      "three zero bytes")
    (assert-encode-buffer (byte_buf.as-bytes (& ones)) "////" "three FF bytes")
    (assert-roundtrip-buffer
      (byte_buf.as-bytes (& zero))
      "binary round trip NUL")
    (assert-roundtrip-buffer
      (byte_buf.as-bytes (& zero-one))
      "binary round trip NUL FF")
    (assert-roundtrip-buffer
      (byte_buf.as-bytes (& high))
      "binary round trip high bytes")
    (assert-roundtrip-buffer
      (byte_buf.as-bytes (& ones))
      "binary round trip FF")))

(define (assert-length-planner) : unit
  (match (base64.encoded-length-count 0 9223372036854775807)
    [(base64.Base64LengthErr _) (fail "encoded length zero")]
    [(base64.Base64LengthOk length)
      (test.assert-i64-eq length 0 "encoded length zero")])
  (match (base64.encoded-length-count 1 9223372036854775807)
    [(base64.Base64LengthErr _) (fail "encoded length one")]
    [(base64.Base64LengthOk length)
      (test.assert-i64-eq length 4 "encoded length one")])
  (match (base64.encoded-length-count 2 9223372036854775807)
    [(base64.Base64LengthErr _) (fail "encoded length two")]
    [(base64.Base64LengthOk length)
      (test.assert-i64-eq length 4 "encoded length two")])
  (match (base64.encoded-length-count 3 9223372036854775807)
    [(base64.Base64LengthErr _) (fail "encoded length three")]
    [(base64.Base64LengthOk length)
      (test.assert-i64-eq length 4 "encoded length three")])
  (match (base64.encoded-length-count 4 9223372036854775807)
    [(base64.Base64LengthErr _) (fail "encoded length four")]
    [(base64.Base64LengthOk length)
      (test.assert-i64-eq length 8 "encoded length four")])
  (match (base64.encoded-length-count -1 9223372036854775807)
    [(base64.Base64LengthOk _) (fail "negative encoded length")]
    [(base64.Base64LengthErr error)
      (test.assert-i64-eq
        (error-kind-code error.kind)
        0
        "negative encoded length kind")
      (test.assert-i64-eq error.offset 0 "negative encoded length offset")])
  (match (base64.encoded-length-count 9223372036854775807 9223372036854775807)
    [(base64.Base64LengthOk _) (fail "huge encoded length")]
    [(base64.Base64LengthErr error)
      (test.assert-i64-eq
        (error-kind-code error.kind)
        4
        "huge encoded length kind")
      (test.assert-i64-eq
        error.offset
        9223372036854775807
        "huge encoded length offset")])
  (match (base64.encoded-length-count 6917529027641081853 9223372036854775807)
    [(base64.Base64LengthErr _) (fail "largest exact encoded length")]
    [(base64.Base64LengthOk length)
      (test.assert-i64-eq
        length
        9223372036854775804
        "largest exact encoded length")])
  (match (base64.encoded-length-count 6917529027641081854 9223372036854775807)
    [(base64.Base64LengthOk _) (fail "largest padded encoded length")]
    [(base64.Base64LengthErr error)
      (test.assert-i64-eq
        (error-kind-code error.kind)
        4
        "largest padded encoded length kind")
      (test.assert-i64-eq
        error.offset
        6917529027641081854
        "largest padded encoded length offset")]))

(define (assert-malformed-lengths) : unit
  (assert-decode-error "A" 0 0)
  (assert-decode-error "AA" 0 0)
  (assert-decode-error "AAA" 0 0)
  (assert-decode-error "AAAAA" 0 4)
  (assert-decode-error "AAAAAA" 0 4)
  (assert-decode-error "AAAAAAA" 0 4)
  (assert-decode-error "AAAAAAAAA" 0 8)
  (assert-decode-error "AA==\n" 0 4)
  (assert-decode-error "AA==\r\n" 0 4)
  (assert-decode-error "AA ==" 0 4))

(define (assert-invalid-characters) : unit
  (assert-decode-error "A?==" 1 1)
  (assert-decode-error "AA?=" 1 2)
  (assert-decode-error "AAA?" 1 3)
  (assert-decode-error "?A==" 1 0)
  (assert-decode-error "-===" 1 0)
  (assert-decode-error "AA-_" 1 2)
  (assert-decode-error "A A=" 1 1)
  (assert-decode-error "AA A" 1 2)
  (assert-decode-error "AAA " 1 3)
  (assert-decode-error " AA=" 1 0)
  (assert-decode-error "AA\n=" 1 2))

(define (assert-invalid-character-positions) : unit
  (let
    [position : i64 0]
    (while (< position 4)
      (let
        [code : i64 0]
        (while (< code 256)
          (when
            (and (not (standard-byte? code)) (!= code 61))
            (let
              [input : byte_buf.ByteBuf
                (cond
                  [(= position 0) (four-byte-buf code 65 65 65)]
                  [(= position 1) (four-byte-buf 65 code 65 65)]
                  [(= position 2) (four-byte-buf 65 65 code 65)]
                  [else (four-byte-buf 65 65 65 code)])]
              (assert-buffer-decode-error
                (byte_buf.as-bytes (& input))
                1
                position
                "every invalid character position")))
          (set! code (+ code 1)))
        (set! position (+ position 1))))))

(define (assert-padding-shapes) : unit
  (assert-decode-ok-length "AA==" 1 "two data two pad")
  (assert-decode-ok-length "AAA=" 2 "three data one pad")
  (assert-decode-ok-length "AAAA" 3 "four data no pad")
  (assert-decode-ok-length "AAAAAA==" 4 "trailing padded quantum")
  (assert-decode-ok-length "AAAAAAA=" 5 "trailing one-pad quantum")
  (assert-decode-ok-length "AAAAAAAA" 6 "trailing unpadded quantum")
  (assert-decode-error "====" 2 0)
  (assert-decode-error "A===" 2 1)
  (assert-decode-error "=AAA" 2 0)
  (assert-decode-error "A=AA" 2 1)
  (assert-decode-error "AA=A" 2 3)
  (assert-decode-error "AA==AAAA" 2 2)
  (assert-decode-error "AAAAA===" 2 5)
  (assert-decode-error "AAAA====" 2 4)
  (assert-decode-error "AAAAAA=A" 2 7)
  (assert-decode-error "AAAAAAA==" 0 8))

(define (assert-pad-bits) : unit
  (let
    [alphabet : String
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"]
    [value : i64 0]
    (while (< value 64)
      (let
        [last : String (string.substring alphabet value 1)]
        [two-data : String (str_cat.str-cat "A" last "==")]
        [three-data : String (str_cat.str-cat "AA" last "=")]
        (if (= (% value 16) 0)
          (assert-decode-ok-length two-data 1 "canonical two-data pad bits")
          (assert-decode-error two-data 3 1))
        (if (= (% value 4) 0)
          (assert-decode-ok-length three-data 2 "canonical one-pad bits")
          (assert-decode-error three-data 3 2))
        (set! value (+ value 1))))))

(define (assert-destination-contract) : unit
  (let
    [text : String "foobar"]
    [source : (& text bytes) (byte_buf.str-as-bytes (& text))]
    (let
      [short : byte_buf.ByteBuf (byte_buf.from-string "xy")]
      (match (base64.encode-into source (&mut short) 1024)
        [(base64.Base64EncodeIntoOk _)
          (fail "encode-into short capacity should fail")]
        [(base64.Base64EncodeIntoErr error)
          (test.assert-i64-eq
            (error-kind-code error.kind)
            5
            "encode-into short kind")
          (test.assert-i64-eq error.offset 2 "encode-into short capacity")])
      (test.assert-i64-eq (byte_buf.len short) 2 "short destination len")
      (test.assert-i64-eq
        (cast (byte_buf.ref short 0) : i64)
        120
        "short destination first byte")
      (test.assert-i64-eq
        (cast (byte_buf.ref short 1) : i64)
        121
        "short destination second byte"))
    (let
      [exact : byte_buf.ByteBuf (byte_buf.with-capacity 8)]
      (match (base64.encode-into source (&mut exact) 1024)
        [(base64.Base64EncodeIntoErr _) (fail "encode-into exact capacity")]
        [(base64.Base64EncodeIntoOk written)
          (test.assert-i64-eq written 8 "encode-into exact written")])
      (let
        [actual : String (byte_buf.to-string exact)]
        (test.assert-string-eq (& actual) "Zm9vYmFy" "encode-into exact bytes")))
    (let
      [roomy : byte_buf.ByteBuf (byte_buf.with-capacity 9)]
      (match (base64.encode-into source (&mut roomy) 1024)
        [(base64.Base64EncodeIntoErr _) (fail "encode-into roomy capacity")]
        [(base64.Base64EncodeIntoOk written)
          (test.assert-i64-eq written 8 "encode-into roomy written")])
      (test.assert-i64-eq (byte_buf.len roomy) 8 "roomy destination len"))
    (let
      [encoded : String "Zm9vYmFy"]
      [input : (& encoded bytes) (byte_buf.str-as-bytes (& encoded))]
      (let
        [short : byte_buf.ByteBuf (byte_buf.from-string "xy")]
        (match (base64.decode-into input (&mut short) 1024)
          [(base64.Base64DecodeIntoOk _)
            (fail "decode-into short capacity should fail")]
          [(base64.Base64DecodeIntoErr error)
            (test.assert-i64-eq
              (error-kind-code error.kind)
              5
              "decode-into short kind")
            (test.assert-i64-eq error.offset 2 "decode-into short capacity")])
        (test.assert-i64-eq
          (byte_buf.len short)
          2
          "decode short destination len")
        (test.assert-i64-eq
          (cast (byte_buf.ref short 0) : i64)
          120
          "decode short destination first byte"))
      (let
        [exact : byte_buf.ByteBuf (byte_buf.with-capacity 6)]
        (match (base64.decode-into input (&mut exact) 1024)
          [(base64.Base64DecodeIntoErr _) (fail "decode-into exact capacity")]
          [(base64.Base64DecodeIntoOk written)
            (test.assert-i64-eq written 6 "decode-into exact written")])
        (let
          [actual : String (byte_buf.to-string exact)]
          (test.assert-string-eq (& actual) (& text) "decode-into exact bytes")))
      (let
        [roomy : byte_buf.ByteBuf (byte_buf.with-capacity 7)]
        (match (base64.decode-into input (&mut roomy) 1024)
          [(base64.Base64DecodeIntoErr _) (fail "decode-into roomy capacity")]
          [(base64.Base64DecodeIntoOk written)
            (test.assert-i64-eq written 6 "decode-into roomy written")])
        (test.assert-i64-eq
          (byte_buf.len roomy)
          6
          "decode roomy destination len")))))

(define (assert-destination-validation-atomicity) : unit
  (let
    [invalid : String "A?=="]
    [input : (& invalid bytes) (byte_buf.str-as-bytes (& invalid))]
    [dst : byte_buf.ByteBuf (byte_buf.from-string "xy")]
    (match (base64.decode-into input (&mut dst) 1024)
      [(base64.Base64DecodeIntoOk _)
        (fail "decode-into invalid source should fail")]
      [(base64.Base64DecodeIntoErr error)
        (test.assert-i64-eq
          (error-kind-code error.kind)
          1
          "decode-into invalid source kind")
        (test.assert-i64-eq error.offset 1 "decode-into invalid source offset")])
    (test.assert-i64-eq
      (byte_buf.len dst)
      2
      "invalid source leaves destination len")
    (test.assert-i64-eq
      (cast (byte_buf.ref dst 0) : i64)
      120
      "invalid source leaves destination first byte")
    (test.assert-i64-eq
      (cast (byte_buf.ref dst 1) : i64)
      121
      "invalid source leaves destination second byte")))

(define (assert-alias-rejection) : unit
  (let
    [store : byte_buf.ByteBuf (byte_buf.from-string "AAAA")]
    [alias : byte_buf.ByteBuf
      (unsafe
        (ptr-read (ptr-addr-of store)))]
    [input : (& alias bytes) (byte_buf.as-bytes (& alias))]
    (match (base64.decode-into input (&mut store) 1024)
      [(base64.Base64DecodeIntoOk _) (fail "decode-into alias accepted")]
      [(base64.Base64DecodeIntoErr error)
        (test.assert-i64-eq
          (error-kind-code error.kind)
          6
          "decode-into alias kind")])
    (test.assert-i64-eq (byte_buf.len store) 4 "decode alias destination len")
    (test.assert-i64-eq
      (cast (byte_buf.ref store 0) : i64)
      65
      "decode alias destination byte"))
  (let
    [store : byte_buf.ByteBuf
      (byte_buf.append-string (byte_buf.with-capacity 8) "foo")]
    [alias : byte_buf.ByteBuf
      (unsafe
        (ptr-read (ptr-addr-of store)))]
    [input : (& alias bytes) (byte_buf.as-bytes (& alias))]
    (match (base64.encode-into input (&mut store) 1024)
      [(base64.Base64EncodeIntoOk _) (fail "encode-into alias accepted")]
      [(base64.Base64EncodeIntoErr error)
        (test.assert-i64-eq
          (error-kind-code error.kind)
          6
          "encode-into alias kind")])
    (test.assert-i64-eq (byte_buf.len store) 3 "encode alias destination len")
    (test.assert-i64-eq
      (cast (byte_buf.ref store 0) : i64)
      102
      "encode alias destination byte")))

(define (assert-limit-error
  [error : base64.Base64Error]
  [limit : i64]
  [expected-length : i64]) : unit
  (test.assert-true (< limit expected-length) "limit failure must be required")
  (test.assert-i64-eq
    (error-kind-code error.kind)
    (if (< limit 0)
      7
      8)
    "configured limit error kind")
  (test.assert-i64-eq error.offset limit "configured limit error value"))

(define (assert-limit-length
  [result : base64.Base64LengthResult]
  [limit : i64]
  [expected : i64]) : unit
  (match result
    [(base64.Base64LengthErr error) (assert-limit-error error limit expected)]
    [(base64.Base64LengthOk length)
      (test.assert-true (>= limit expected) "planner must enforce limit")
      (test.assert-i64-eq length expected "bounded length")]))

(define (sentinel-destination [capacity : i64]) : byte_buf.ByteBuf
  (let
    [dst : byte_buf.ByteBuf (byte_buf.with-capacity capacity)]
    [index : i64 0]
    (while (< index capacity)
      (set! (array-ref dst.slots index) (cast 165 : u8))
      (set! index (+ index 1)))
    (set! dst.len 2)
    dst))

(define (assert-sentinel-unchanged [dst : (& dst byte_buf.ByteBuf)]) : unit
  (let
    [index : i64 0]
    (test.assert-i64-eq (byte_buf.len dst) 2 "failure preserves length")
    (while (< index (byte_buf.capacity dst))
      (test.assert-i64-eq
        (cast (array-ref dst.slots index) : i64)
        165
        "failure preserves every physical byte")
      (set! index (+ index 1)))))

(define (assert-limit-destination
  [dst : (& dst byte_buf.ByteBuf)]
  [limit : i64]
  [expected : i64]) : unit
  (if (>= limit expected)
    (test.assert-i64-eq
      (byte_buf.len dst)
      expected
      "bounded destination length")
    (assert-sentinel-unchanged dst)))

(define (assert-capacity-and-late-failure) : unit
  (let
    [plain : String "foobar"]
    [encoded : String "Zm9vYmFy"]
    [late-invalid : String "AAAAAA?="]
    [encoding-dst : byte_buf.ByteBuf (sentinel-destination 7)]
    [decoding-dst : byte_buf.ByteBuf (sentinel-destination 5)]
    [invalid-dst : byte_buf.ByteBuf (sentinel-destination 16)]
    (match (base64.encode-into
      (byte_buf.str-as-bytes (& plain))
      (&mut encoding-dst)
      8)
      [(base64.Base64EncodeIntoOk _)
        (fail "one-byte-short encoding destination")]
      [(base64.Base64EncodeIntoErr error)
        (test.assert-i64-eq
          (error-kind-code error.kind)
          5
          "encoding capacity kind")
        (test.assert-i64-eq error.offset 7 "encoding capacity")])
    (match (base64.decode-into
      (byte_buf.str-as-bytes (& encoded))
      (&mut decoding-dst)
      6)
      [(base64.Base64DecodeIntoOk _)
        (fail "one-byte-short decoding destination")]
      [(base64.Base64DecodeIntoErr error)
        (test.assert-i64-eq
          (error-kind-code error.kind)
          5
          "decoding capacity kind")
        (test.assert-i64-eq error.offset 5 "decoding capacity")])
    (match (base64.decode-into
      (byte_buf.str-as-bytes (& late-invalid))
      (&mut invalid-dst)
      6)
      [(base64.Base64DecodeIntoOk _) (fail "late invalid quantum")]
      [(base64.Base64DecodeIntoErr error)
        (test.assert-i64-eq
          (error-kind-code error.kind)
          1
          "late invalid character kind")
        (test.assert-i64-eq error.offset 6 "late invalid character offset")])
    (assert-sentinel-unchanged (& encoding-dst))
    (assert-sentinel-unchanged (& decoding-dst))
    (assert-sentinel-unchanged (& invalid-dst))))

(define (assert-output-limits [plain : String] [canonical : String]) : unit
  (let
    [input : (& plain bytes) (byte_buf.str-as-bytes (& plain))]
    [encoded : (& canonical bytes) (byte_buf.str-as-bytes (& canonical))]
    [raw-length : i64 (byte_buf.bytes-length input)]
    [encoded-length : i64 (byte_buf.bytes-length encoded)]
    [limit : i64 -1]
    (while (<= limit (+ encoded-length 1))
      (let
        [encoding-dst : byte_buf.ByteBuf (sentinel-destination 16)]
        [decoding-dst : byte_buf.ByteBuf (sentinel-destination 16)]
        (assert-limit-length
          (base64.encoded-length-count raw-length limit)
          limit
          encoded-length)
        (assert-limit-length
          (base64.encoded-length input limit)
          limit
          encoded-length)
        (assert-limit-length
          (base64.decoded-length encoded limit)
          limit
          raw-length)
        (match (base64.encode input limit)
          [(base64.Base64EncodeErr error)
            (assert-limit-error error limit encoded-length)]
          [(base64.Base64EncodeOk result)
            (test.assert-true
              (>= limit encoded-length)
              "owned encoding must enforce limit")
            (test.assert-i64-eq
              (byte_buf.len result)
              encoded-length
              "bounded owned encoding")])
        (match (base64.decode encoded limit)
          [(base64.Base64DecodeErr error)
            (assert-limit-error error limit raw-length)]
          [(base64.Base64DecodeOk result)
            (test.assert-true
              (>= limit raw-length)
              "owned decoding must enforce limit")
            (test.assert-i64-eq
              (byte_buf.len result)
              raw-length
              "bounded owned decoding")])
        (match (base64.encode-into input (&mut encoding-dst) limit)
          [(base64.Base64EncodeIntoErr error)
            (assert-limit-error error limit encoded-length)]
          [(base64.Base64EncodeIntoOk written)
            (test.assert-true
              (>= limit encoded-length)
              "encoding into must enforce limit")
            (test.assert-i64-eq
              written
              encoded-length
              "bounded encoding written")])
        (match (base64.decode-into encoded (&mut decoding-dst) limit)
          [(base64.Base64DecodeIntoErr error)
            (assert-limit-error error limit raw-length)]
          [(base64.Base64DecodeIntoOk written)
            (test.assert-true
              (>= limit raw-length)
              "decoding into must enforce limit")
            (test.assert-i64-eq written raw-length "bounded decoding written")])
        (assert-limit-destination (& encoding-dst) limit encoded-length)
        (assert-limit-destination (& decoding-dst) limit raw-length))
      (set! limit (+ limit 1)))))

(define (assert-exhaustive-lengths) : unit
  (let
    [length : i64 0]
    (while (<= length 12)
      (begin
        (let
          [position : i64 0]
          (while (< position length)
            (let
              [code : i64 0]
              (while (< code 256)
                (begin
                  (let
                    [buf : byte_buf.ByteBuf (pattern-buf length position code)]
                    (assert-roundtrip-buffer
                      (byte_buf.as-bytes (& buf))
                      "exhaustive position round trip"))
                  (set! code (+ code 1)))))
            (set! position (+ position 1))))
        (let
          [boundary : byte_buf.ByteBuf (pattern-buf length 0 (pattern-byte 0))]
          (assert-roundtrip-buffer
            (byte_buf.as-bytes (& boundary))
            "length boundary round trip"))
        (set! length (+ length 1))))
    unit))

(define (assert-two-byte-exhaustive) : unit
  (let
    [alphabet : String
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"]
    [alphabet-bytes : (& alphabet bytes) (byte_buf.str-as-bytes (& alphabet))]
    [first : i64 0]
    (while (< first 256)
      (let
        [second : i64 0]
        (while (< second 256)
          (begin
            (let
              [buf : byte_buf.ByteBuf (two-byte-buf first second)]
              (match (base64.encode (byte_buf.as-bytes (& buf)) 1024)
                [(base64.Base64EncodeErr _) (fail "two-byte encode")]
                [(base64.Base64EncodeOk encoded)
                  (test.assert-i64-eq
                    (byte_buf.len encoded)
                    4
                    "two-byte encoded length")
                  (test.assert-i64-eq
                    (cast (byte_buf.ref encoded 3) : i64)
                    61
                    "two-byte terminal padding")
                  ; Literal alphabet and division/remainders provide
                  ; an oracle independent of the codec's bit packing.
                  (test.assert-i64-eq
                    (cast (byte_buf.ref encoded 0) : i64)
                    (cast (byte_buf.bytes-ref alphabet-bytes (/ first 4)) : i64)
                    "two-byte first sextet")
                  (test.assert-i64-eq
                    (cast (byte_buf.ref encoded 1) : i64)
                    (cast
                      (byte_buf.bytes-ref
                        alphabet-bytes
                        (+ (* (% first 4) 16) (/ second 16)))
                      : i64)
                    "two-byte second sextet")
                  (test.assert-i64-eq
                    (cast (byte_buf.ref encoded 2) : i64)
                    (cast
                      (byte_buf.bytes-ref alphabet-bytes (* (% second 16) 4))
                      : i64)
                    "two-byte third sextet")
                  (match (base64.decode (byte_buf.as-bytes (& encoded)) 1024)
                    [(base64.Base64DecodeErr _) (fail "two-byte decode")]
                    [(base64.Base64DecodeOk decoded)
                      (test.assert-i64-eq
                        (byte_buf.len decoded)
                        2
                        "two-byte decoded length")
                      (test.assert-i64-eq
                        (cast (byte_buf.ref decoded 0) : i64)
                        first
                        "two-byte first byte")
                      (test.assert-i64-eq
                        (cast (byte_buf.ref decoded 1) : i64)
                        second
                        "two-byte second byte")])]))
            (set! second (+ second 1)))))
      (set! first (+ first 1)))
    unit))

(test
  base64-rfc4648-round-trip
  (let
    [text : String "foobar"]
    (match (base64.encode (byte_buf.str-as-bytes (& text)) 8)
      [(base64.Base64EncodeErr _)
        (test.assert-true false "encode should succeed")]
      [(base64.Base64EncodeOk encoded)
        (test.assert-i64-eq (byte_buf.len encoded) 8 "encoded length")
        (match (base64.decode (byte_buf.as-bytes (& encoded)) 6)
          [(base64.Base64DecodeErr _)
            (test.assert-true false "decode should succeed")]
          [(base64.Base64DecodeOk decoded)
            (let
              [actual : String (byte_buf.to-string decoded)]
              (test.assert-string-eq
                (& actual)
                (& text)
                "RFC 4648 vector round trip"))])
        (let
          [rendered : String (byte_buf.to-string encoded)]
          (test.assert-string-eq
            (& rendered)
            "Zm9vYmFy"
            "RFC 4648 vector spelling"))])))

(define (main) : i64
  (assert-rfc-vectors)
  (assert-binary-fixtures)
  (assert-length-planner)
  (assert-malformed-lengths)
  (assert-invalid-characters)
  (assert-invalid-character-positions)
  (assert-padding-shapes)
  (assert-pad-bits)
  (assert-destination-contract)
  (assert-destination-validation-atomicity)
  (assert-alias-rejection)
  (assert-capacity-and-late-failure)
  (assert-output-limits "" "")
  (assert-output-limits "f" "Zg==")
  (assert-output-limits "fo" "Zm8=")
  (assert-output-limits "foo" "Zm9v")
  (assert-output-limits "foobar" "Zm9vYmFy")
  (assert-exhaustive-lengths)
  (assert-two-byte-exhaustive)
  42)