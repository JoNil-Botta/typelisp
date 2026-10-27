(import stdlib.json)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.string_utf8 as utf8)
(import stdlib.test)

(define (parsed-string [encoded : String]) : String
  (match (json.parse (& encoded))
    [(OkJson (JsonString decoded)) decoded]
    [_
      (test.assert-true false "Unicode JSON string must parse")
      ""]))

(define (assert-string [encoded : String] [expected : (& expected str)]) : unit
  (let
    [decoded : String (parsed-string encoded)]
    [roundtrip : String
      (parsed-string (json.stringify (JsonString (clone decoded))))]
    (test.assert-string-eq (& decoded) expected "decoded UTF-8 bytes")
    (test.assert-string-eq
      (& roundtrip)
      expected
      "stringify/parse Unicode roundtrip")))

(define (hex4 [value : i64]) : String
  (let
    [digits : String "0123456789abcdef"]
    (str_cat.str-cat
      (string.substring (& digits) (bit-and (shr value 12) 15) 1)
      (string.substring (& digits) (bit-and (shr value 8) 15) 1)
      (string.substring (& digits) (bit-and (shr value 4) 15) 1)
      (string.substring (& digits) (bit-and value 15) 1))))

(define (assert-scalar [encoded : String] [value : i64]) : unit
  (let
    [decoded : String (parsed-string encoded)]
    [roundtrip : String
      (parsed-string (json.stringify (JsonString (clone decoded))))]
    (match (utf8.decode-at (& decoded) 0)
      [(Scalar scalar next)
        (test.assert-i64-eq
          (cast scalar.value : i64)
          value
          "escaped scalar value")
        (test.assert-i64-eq
          next
          (string.string-length (& decoded))
          "one complete scalar")]
      [_ (test.assert-true false "escaped scalar must be checked UTF-8")])
    (test.assert-string-eq (& roundtrip) (& decoded) "scalar roundtrip bytes")))

(define (assert-invalid [text : String] [message : (& message str)]) : unit
  (match (json.parse (& text))
    [(ErrJson error)
      (test.assert-string-eq (& error) message "located surrogate error")]
    [_ (test.assert-true false "invalid surrogate must reject")]))

(define (assert-bmp [value : i64]) : unit
  (assert-scalar (str_cat.str-cat "\"\\u" (hex4 value) "\"") value))

(define (assert-pair [index : i64]) : unit
  (let
    [low : i64 (% (* index 37) 1024)]
    (assert-scalar
      (str_cat.str-cat
        "\"\\u"
        (hex4 (+ 0xd800 index))
        "\\u"
        (hex4 (+ 0xdc00 low))
        "\"")
      (+ 0x10000 (+ (* index 1024) low)))))

(define (check-unicode-escapes) : unit
  (assert-scalar "\"\\u007f\"" 0x7f)
  (assert-string "\"\\u0080\\u07ff\\u0800\"" "߿ࠀ")
  (assert-string "\"\\u00e9\\u20AC\\u4e2d\"" "é€中")
  (assert-string "\"\\uD7FF\\uE000\\uFFFF\"" "퟿￿")
  (assert-string "\"\\ud800\\udc00\\uDBFF\\uDFFF\"" "𐀀􏿿")
  (assert-string
    "\"raw é \\ud834\\udd1e \\ud83d\\ude00 end\""
    "raw é 𝄞 😀 end")
  ;; Original qa-20261026-01 unicode-escaped input's string, byte for byte.
  (assert-string
    "\"L\\u00f6dtenn \\ud83d\\udee0 \\t\\\"\\\\\\n\""
    "Lödtenn 🛠 \t\"\\\n")
  ;; Every BMP scalar, including controls, noncharacters and unassigned values.
  (let
    [value : i64 0]
    (while (< value 0x10000)
      (unless
        (and (>= value 0xd800) (<= value 0xdfff))
        (with-arena scratch (assert-bmp value)))
      (set! value (+ value 1))))
  ;; Exercise every high and low code unit, with changing pair combinations.
  (let
    [index : i64 0]
    (while (< index 1024)
      (with-arena scratch (assert-pair index))
      (set! index (+ index 1))))
  (let
    [text : String "{\"\\u00e9\\ud83d\\ude00\":\"\\u4e2d\"}"]
    (match (json.parse (& text))
      [(OkJson value)
        (let
          [rendered : String (json.stringify value)]
          (test.assert-string-eq
            (& rendered)
            "{\"é😀\":\"中\"}"
            "Unicode object key"))]
      [_ (test.assert-true false "Unicode object must parse")]))
  (assert-invalid "\"\\ud800\"" "json: expected low surrogate escape at byte 3")
  (assert-invalid "\"\\udbff\"" "json: expected low surrogate escape at byte 3")
  (assert-invalid "\"\\udc00\"" "json: unpaired low surrogate escape at byte 3")
  (assert-invalid "\"\\udfff\"" "json: unpaired low surrogate escape at byte 3")
  (assert-invalid
    "\"\\udc00\\ud800\""
    "json: unpaired low surrogate escape at byte 3")
  (assert-invalid
    "\"\\ud800\\ud800\""
    "json: expected low surrogate escape at byte 3")
  (assert-invalid
    "\"\\ud800\\u0041\""
    "json: expected low surrogate escape at byte 3")
  (assert-invalid
    "\"\\ud800x\\udc00\""
    "json: expected low surrogate escape at byte 3")
  (assert-invalid
    "\"\\ud800\\n\""
    "json: expected low surrogate escape at byte 3")
  (assert-invalid
    "\"\\ud800\\udc0\""
    "json: expected low surrogate escape at byte 3")
  (assert-invalid
    "\"\\ud800\\udc0x\""
    "json: expected low surrogate escape at byte 3")
  (assert-invalid
    "\"\\ud800\\\\udc00\""
    "json: expected low surrogate escape at byte 3")
  (assert-invalid
    "[\n \"é\\udc00\"]"
    "json: unpaired low surrogate escape at byte 8")
  (assert-invalid
    "\"\\ud800\\udc00\\udc00\""
    "json: unpaired low surrogate escape at byte 15"))

(define (main) : i64
  (check-unicode-escapes)
  42)

(test unicode-escapes (check-unicode-escapes))