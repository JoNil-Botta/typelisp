(import stdlib.json)

(import stdlib.str_cat)

(import stdlib.string)

(import stdlib.test)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (assert-json-found-number
  [lookup : json.JsonLookup]
  [expected : String]
  [message : String]) : unit
  (match lookup
    [(json.JsonFound value)
      (match value
        [(json.JsonNumber text) (assert-owned-string-eq text expected message)]
        [_ (panic message)])]
    [(json.JsonMissing) (panic message)]))

(define (assert-json-missing [lookup : json.JsonLookup] [message : String]) : unit
  (match lookup
    [(json.JsonMissing) unit]
    [(json.JsonFound _) (panic message)]))

(define (test-json-list-cons [value : json.Json] [rest : json.JsonList]) : json.JsonList
  (json.JsonListCons value (box rest)))

(define (test-json-member-cons
  [key : String]
  [value : json.Json]
  [rest : json.JsonMemberList]) : json.JsonMemberList
  (json.JsonMemberListCons key value (box rest)))

(define (test-json-array [items : json.JsonList]) : json.Json
  (json.JsonArray (box items)))

(define (test-json-object [members : json.JsonMemberList]) : json.Json
  (json.JsonObject (box members)))

(define (assert-parse-string
  [result : json.JsonParseStringResult]
  [expected : String]
  [next : i64]
  [message : String]) : unit
  (match result
    [(json.OkJsonParseString value pos)
      (begin
        (assert-owned-string-eq value expected message)
        (test.assert-i64-eq pos next message))]
    [(json.ErrJsonParseString _) (panic message)]))

(define (assert-parse-escape
  [result : json.JsonParseEscapeResult]
  [expected : String]
  [next : i64]
  [message : String]) : unit
  (match result
    [(json.OkJsonParseEscape value pos)
      (begin
        (assert-owned-string-eq value expected message)
        (test.assert-i64-eq pos next message))]
    [(json.ErrJsonParseEscape _) (panic message)]))

(define (assert-codepoint
  [result : json.JsonCodepointStringResult]
  [expected : String]
  [message : String]) : unit
  (match result
    [(json.OkJsonCodepointString value)
      (assert-owned-string-eq value expected message)]
    [(json.ErrJsonCodepointString _) (panic message)]))

(define (assert-json-f64
  [result : json.JsonNumberF64Result]
  [expected : f64]
  [message : String]) : unit
  (match result
    [(json.OkJsonNumberF64 value) (test.assert-f64-eq value expected message)]
    [(json.ErrJsonNumberF64 _) (panic message)]))

(define (assert-json-f32-as-f64
  [result : json.JsonNumberF32Result]
  [expected : f64]
  [message : String]) : unit
  (match result
    [(json.OkJsonNumberF32 value)
      (test.assert-f64-eq (cast value : f64) expected message)]
    [(json.ErrJsonNumberF32 _) (panic message)]))

(define (assert-json-f64-error
  [result : json.JsonNumberF64Result]
  [message : String]) : unit
  (match result
    [(json.ErrJsonNumberF64 _) unit]
    [(json.OkJsonNumberF64 _) (panic message)]))

(define (assert-json-f32-error
  [result : json.JsonNumberF32Result]
  [message : String]) : unit
  (match result
    [(json.ErrJsonNumberF32 _) unit]
    [(json.OkJsonNumberF32 _) (panic message)]))

(define (assert-json-number-text
  [result : json.JsonNumberTextResult]
  [expected : String]
  [message : String]) : unit
  (match result
    [(json.OkJsonNumberText text) (assert-owned-string-eq text expected message)]
    [(json.ErrJsonNumberText _) (panic message)]))

(define (assert-parse-value-number
  [result : json.JsonParseValueResult]
  [expected : String]
  [next : i64]
  [message : String]) : unit
  (match result
    [(json.OkJsonParseValue value pos)
      (match value
        [(json.JsonNumber text)
          (begin
            (assert-owned-string-eq text expected message)
            (test.assert-i64-eq pos next message))]
        [_ (panic message)])]
    [(json.ErrJsonParseValue _) (panic message)]))

(define (assert-parse-value-bool
  [result : json.JsonParseValueResult]
  [expected : bool]
  [next : i64]
  [message : String]) : unit
  (match result
    [(json.OkJsonParseValue value pos)
      (match value
        [(json.JsonBool actual)
          (begin
            (test.assert-bool-eq actual expected message)
            (test.assert-i64-eq pos next message))]
        [_ (panic message)])]
    [(json.ErrJsonParseValue _) (panic message)]))

(define (assert-parse-array-count
  [result : json.JsonParseValueResult]
  [expected-count : i64]
  [next : i64]
  [message : String]) : unit
  (match result
    [(json.OkJsonParseValue value pos)
      (match value
        [(json.JsonArray items)
          (begin
            (test.assert-i64-eq
              (json.json-list-count (box-get items))
              expected-count
              message)
            (test.assert-i64-eq pos next message))]
        [_ (panic message)])]
    [(json.ErrJsonParseValue _) (panic message)]))

(define (assert-parse-object-count
  [result : json.JsonParseValueResult]
  [expected-count : i64]
  [next : i64]
  [message : String]) : unit
  (match result
    [(json.OkJsonParseValue value pos)
      (match value
        [(json.JsonObject members)
          (begin
            (test.assert-i64-eq
              (json.json-member-list-count (box-get members))
              expected-count
              message)
            (test.assert-i64-eq pos next message))]
        [_ (panic message)])]
    [(json.ErrJsonParseValue _) (panic message)]))

(define (json-test-char-code-at [text : String] [idx : i64]) : i64
  (json.json-char-code-at (& text) idx))

(define (json-test-char-code-eq-at [text : String] [idx : i64] [code : i64]) : bool
  (json.json-char-code-eq-at (& text) idx code))

(define (json-test-digit-at? [text : String] [idx : i64]) : bool
  (json.json-digit-at? (& text) idx))

(define (json-test-skip-ws [text : String] [pos : i64]) : i64
  (json.json-skip-ws (& text) pos))

(define (json-test-prefix-at? [text : String] [prefix : String] [start : i64]) : bool
  (json.json-string-prefix-at? (& text) (& prefix) start))

(define (json-test-member-list-get [items : json.JsonMemberList] [key : String]) : json.JsonLookup
  (json.json-member-list-get items (& key)))

(define (json-test-object-get [value : json.Json] [key : String]) : json.JsonLookup
  (json.json-object-get value (& key)))

(define (json-test-escape-string [text : String]) : String
  (json.json-escape-string (& text)))

(define (json-test-parse-unicode-escape [text : String] [pos : i64]) : json.JsonParseEscapeResult
  (json.json-parse-unicode-escape (& text) pos))

(define (json-test-parse-escape [text : String] [pos : i64]) : json.JsonParseEscapeResult
  (json.json-parse-escape (& text) pos))

(define (json-test-parse-string [text : String] [pos : i64]) : json.JsonParseStringResult
  (json.json-parse-string (& text) pos))

(define (json-test-consume-digits [text : String] [pos : i64]) : i64
  (json.json-consume-digits (& text) pos))

(define (json-test-parse-number [text : String] [pos : i64]) : json.JsonParseValueResult
  (json.json-parse-number (& text) pos))

(define (json-test-number-f64 [text : String]) : json.JsonNumberF64Result
  (json.json-number->f64 (& text)))

(define (json-test-number-f32 [text : String]) : json.JsonNumberF32Result
  (json.json-number->f32 (& text)))

(define (json-test-parse-keyword
  [text : String]
  [pos : i64]
  [keyword : String]
  [value : json.Json]) : json.JsonParseValueResult
  (json.json-parse-keyword (& text) pos keyword value))

(define (json-test-parse-array [text : String] [pos : i64]) : json.JsonParseValueResult
  (json.json-parse-array (& text) pos))

(define (json-test-parse-object [text : String] [pos : i64]) : json.JsonParseValueResult
  (json.json-parse-object (& text) pos))

(define (json-test-parse-value [text : String] [pos : i64]) : json.JsonParseValueResult
  (json.json-parse-value (& text) pos))

(define (main) : i64
  (begin
    (assert-owned-string-eq (str_cat.str-cat "a" "b" "c") "abc" "json-cat3")
    (assert-owned-string-eq (str_cat.str-cat "a" "b" "c" "d") "abcd" "json-cat4")
    (test.assert-i64-eq (json.json-char-code #A') 65 "json-char-code")
    (test.assert-i64-eq (json-test-char-code-at "AZ" 1) 90 "json-char-code-at")
    (test.assert-true
      (json-test-char-code-eq-at "AZ" 0 65)
      "json-char-code-eq-at true")
    (test.assert-false
      (json-test-char-code-eq-at "AZ" 2 65)
      "json-char-code-eq-at out of range")
    (test.assert-true (json.json-space-code? 32) "json-space-code? space")
    (test.assert-false (json.json-space-code? 65) "json-space-code? false")
    (test.assert-true (json.json-digit-code? 57) "json-digit-code? true")
    (test.assert-false (json.json-digit-code? 65) "json-digit-code? false")
    (test.assert-true (json-test-digit-at? "a5" 1) "json-digit-at? true")
    (test.assert-false (json-test-digit-at? "a5" 0) "json-digit-at? false")
    (test.assert-false (json-test-digit-at? "a5" 2) "json-digit-at? out of range")
    (test.assert-i64-eq (json-test-skip-ws "   X" 0) 3 "json-skip-ws")
    (test.assert-true
      (json-test-prefix-at? "abcdef" "cd" 2)
      "json-string-prefix-at? true")
    (test.assert-false
      (json-test-prefix-at? "abcdef" "cd" 5)
      "json-string-prefix-at? false")
    (test.assert-i64-eq
      (json.json-list-count
        (test-json-list-cons
          json.JsonNull
          (test-json-list-cons (json.JsonBool true) json.JsonListNil)))
      2
      "json-list-count")
    (assert-owned-string-eq
      (json.json-stringify-list
        (json.json-list-reverse
          (test-json-list-cons
            (json.JsonNumber "2")
            (test-json-list-cons (json.JsonNumber "1") json.JsonListNil))))
      "1,2"
      "json-list-reverse")
    (test.assert-i64-eq
      (json.json-member-list-count
        (test-json-member-cons
          "a"
          json.JsonNull
          (test-json-member-cons "b" (json.JsonBool true) json.JsonMemberListNil)))
      2
      "json-member-list-count")
    (assert-json-found-number
      (json-test-member-list-get
        (test-json-member-cons
          "a"
          (json.JsonNumber "1")
          (test-json-member-cons "b" (json.JsonNumber "2") json.JsonMemberListNil))
        "b")
      "2"
      "json-member-list-get")
    (assert-json-missing
      (json-test-member-list-get
        (test-json-member-cons "a" (json.JsonNumber "1") json.JsonMemberListNil)
        "z")
      "json-member-list-get missing")
    (assert-owned-string-eq
      (json.json-stringify-members
        (json.json-member-list-reverse
          (test-json-member-cons
            "b"
            (json.JsonBool true)
            (test-json-member-cons "a" json.JsonNull json.JsonMemberListNil))))
      "\"a\":null,\"b\":true"
      "json-member-list-reverse")
    (assert-json-found-number
      (json-test-object-get
        (test-json-object
          (test-json-member-cons "n" (json.JsonNumber "7") json.JsonMemberListNil))
        "n")
      "7"
      "json-object-get")
    (assert-json-missing
      (json-test-object-get json.JsonNull "n")
      "json-object-get non-object")
    (test.assert-i64-eq (json.json-hex-value #A') 10 "json-hex-value upper")
    (test.assert-i64-eq (json.json-hex-value #f') 15 "json-hex-value lower")
    (test.assert-i64-eq (json.json-hex-value #g') -1 "json-hex-value invalid")
    (assert-owned-string-eq (json.json-hex-digit 15) "f" "json-hex-digit")
    (assert-owned-string-eq
      (json.json-control-escape 10)
      "\\n"
      "json-control-escape newline")
    (assert-owned-string-eq
      (json.json-control-escape 1)
      "\\u0001"
      "json-control-escape unicode")
    (assert-owned-string-eq
      (json.json-escape-char 34)
      "\\\""
      "json-escape-char quote")
    (assert-owned-string-eq
      (json.json-escape-char 92)
      "\\\\"
      "json-escape-char slash")
    (assert-owned-string-eq
      (json-test-escape-string "a\n\"\\")
      "a\\n\\\"\\\\"
      "json-escape-string")
    (assert-owned-string-eq
      (json.json-stringify
        (test-json-array
          (test-json-list-cons
            (json.JsonNumber "1")
            (test-json-list-cons json.JsonNull json.JsonListNil))))
      "[1,null]"
      "json-stringify array")
    (assert-codepoint (json.json-codepoint-string 65) "A" "json-codepoint-string")
    (match (json.json-codepoint-string 200)
      [(json.ErrJsonCodepointString _) unit]
      [(json.OkJsonCodepointString _)
        (panic "json-codepoint-string rejects unsupported")])
    (assert-parse-escape
      (json-test-parse-unicode-escape "0041" 0)
      "A"
      4
      "json-parse-unicode-escape")
    (match (json-test-parse-unicode-escape "00xz" 0)
      [(json.ErrJsonParseEscape _) unit]
      [(json.OkJsonParseEscape _ _)
        (panic "json-parse-unicode-escape rejects invalid")])
    (assert-parse-escape
      (json-test-parse-escape "\\n" 1)
      "\n"
      2
      "json-parse-escape")
    (match (json-test-parse-escape "\\x" 1)
      [(json.ErrJsonParseEscape _) unit]
      [(json.OkJsonParseEscape _ _) (panic "json-parse-escape rejects invalid")])
    (assert-parse-string
      (json-test-parse-string "\"a\\n\"" 0)
      "a\n"
      5
      "json-parse-string")
    (match (json-test-parse-string "\"unterminated" 0)
      [(json.ErrJsonParseString _) unit]
      [(json.OkJsonParseString _ _) (panic "json-parse-string rejects invalid")])
    (test.assert-i64-eq
      (json-test-consume-digits "123abc" 0)
      3
      "json-consume-digits")
    (assert-parse-value-number
      (json-test-parse-number "-2.5e3" 0)
      "-2.5e3"
      6
      "json-parse-number")
    (match (json-test-parse-number "01" 0)
      [(json.ErrJsonParseValue _) unit]
      [(json.OkJsonParseValue _ _) (panic "json-parse-number rejects leading zero")])
    (assert-json-f64 (json-test-number-f64 "42") 42.0 "json-number->f64 int")
    (assert-json-f64
      (json-test-number-f64 "-2.5e3")
      -2500.0
      "json-number->f64 exponent")
    (assert-json-f64
      (json-test-number-f64 "6.25E-1")
      0.625
      "json-number->f64 fraction exponent")
    (match (json-test-number-f64 "-0")
      [(json.OkJsonNumberF64 value)
        (assert-json-number-text
          (json.json-f64->number-text value)
          "-0"
          "json-number->f64 preserves negative zero")]
      [(json.ErrJsonNumberF64 _) (panic "json-number->f64 negative zero")])
    (match (json-test-number-f64 "1e+17")
      [(json.OkJsonNumberF64 value)
        (assert-json-number-text
          (json.json-f64->number-text value)
          "1e+17"
          "json-number->f64 large magnitude")]
      [(json.ErrJsonNumberF64 _) (panic "json-number->f64 large magnitude")])
    (assert-json-f64-error
      (json-test-number-f64 "1x")
      "json-number->f64 trailing")
    (assert-json-f64-error
      (json-test-number-f64 "01")
      "json-number->f64 leading")
    (assert-json-f64-error
      (json-test-number-f64 "1e309")
      "json-number->f64 overflow")
    (assert-json-f64-error
      (json-test-number-f64 "1e-400")
      "json-number->f64 underflow")
    (assert-json-f32-as-f64 (json-test-number-f32 "1.5") 1.5 "json-number->f32")
    (assert-json-f32-error
      (json-test-number-f32 "1e39")
      "json-number->f32 overflow")
    (assert-json-f32-error
      (json-test-number-f32 "1e-50")
      "json-number->f32 underflow")
    (assert-json-number-text
      (json.json-f64->number-text 0.125)
      "0.125"
      "json-f64->number-text")
    (assert-json-number-text
      (json.json-f32->number-text (cast 1.25 : f32))
      "1.25"
      "json-f32->number-text")
    (assert-parse-value-bool
      (json-test-parse-keyword "true" 0 "true" (json.JsonBool true))
      true
      4
      "json-parse-keyword")
    (assert-parse-array-count
      (json-test-parse-array "[1,true]" 0)
      2
      8
      "json-parse-array")
    (assert-parse-object-count
      (json-test-parse-object "{\"a\":1}" 0)
      1
      7
      "json-parse-object")
    (assert-parse-value-bool
      (json-test-parse-value " false" 0)
      false
      6
      "json-parse-value")
    42))