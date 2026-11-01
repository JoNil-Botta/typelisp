(import stdlib.byte_buf)
(import stdlib.json)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.test)

(define (assert-parsed-string [encoded : String] [expected : (& expected str)]) : unit
  (match (json.parse (& encoded))
    [(OkJson (JsonString decoded))
      (test.assert-i64-eq
        (string.string-length (& decoded))
        (string.string-length expected)
        "JSON decoded byte length")
      (let
        [index : i64 0]
        (while (< index (string.string-length expected))
          (test.assert-i64-eq
            (cast (string.string-ref (& decoded) index) : i64)
            (cast (string.string-ref expected index) : i64)
            "JSON decoded control byte")
          (set! index (+ index 1))))]
    [_ (test.assert-true false "JSON control string should parse")]))

(define (assert-rejected [encoded : String]) : unit
  (match (json.parse (& encoded))
    [(ErrJson _) unit]
    [_ (test.assert-true false "JSON invalid string should reject")]))

(define (check-control-escapes) : unit
  (let
    [all : byte_buf.ByteBuf (byte_buf.append-string (byte_buf.new) "before")]
    [code : i64 0]
    [upper-hex : String "0123456789ABCDEF"]
    (while (< code 32)
      (let
        [original : String
          (byte_buf.to-string (byte_buf.push (byte_buf.new) (cast code : u8)))]
        [encoded : String (json.stringify (JsonString (clone original)))]
        [unicode : String
          (str_cat.str-cat
            "\"\\u00"
            (string.substring (& upper-hex) (/ code 16) 1)
            (string.substring (& upper-hex) (bit-and code 15) 1)
            "\"")]
        (assert-parsed-string encoded (& original))
        (assert-parsed-string unicode (& original))
        (assert-rejected (str_cat.str-cat "\"" original "\"")))
      (set! all (byte_buf.push all (cast code : u8)))
      (set! code (+ code 1)))
    (let
      [original : String
        (byte_buf.to-string (byte_buf.append-string all "after"))]
      [encoded : String (json.stringify (JsonString (clone original)))]
      (test.assert-string-eq
        (& encoded)
        "\"before\\u0000\\u0001\\u0002\\u0003\\u0004\\u0005\\u0006\\u0007\\b\\t\\n\\u000b\\f\\r\\u000e\\u000f\\u0010\\u0011\\u0012\\u0013\\u0014\\u0015\\u0016\\u0017\\u0018\\u0019\\u001a\\u001b\\u001c\\u001d\\u001e\\u001fafter\""
        "JSON canonical control escapes")
      (assert-parsed-string encoded (& original))))
  (assert-parsed-string "\"\\t\\n\\r\"" "\t\n\r")
  (assert-parsed-string "\"\\u0020\\u0041\\u007E\"" " A~")
  (assert-parsed-string "\"\\\"\\\\\\/\"" "\"\\/")
  (assert-rejected "\"\\u\"")
  (assert-rejected "\"\\u000\"")
  (assert-rejected "\"\\u00xz\"")
  (assert-rejected "\"\\x\"")
  (assert-rejected "\"\\^@\"")
  ;; Invalid UTF-16 remains rejected; valid Unicode is covered separately.
  (assert-rejected "\"\\ud800\"")
  (assert-rejected "\"\\udc00\""))

(define (main) : i64
  (check-control-escapes)
  42)

(test control-escapes (check-control-escapes))