(import "stdlib/json.tl")
(import "stdlib/str_cat.tl")
(import "stdlib/string.tl")
(import "stdlib/test.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (assert-json-found-number
  [lookup : JsonLookup]
  [expected : String]
  [message : String]) : unit
  (match lookup
    [(JsonFound value)
      (match value
        [(JsonNumber text) (assert-owned-string-eq text expected message)]
        [_ (panic message)])]
    [(JsonMissing) (panic message)]))

(define (assert-json-missing [lookup : JsonLookup] [message : String]) : unit
  (match lookup
    [(JsonMissing) unit]
    [(JsonFound _) (panic message)]))

(define (test-json-list-cons [value : Json] [rest : JsonList]) : JsonList
  (JsonListCons value (box rest)))

(define (test-json-member-cons
  [key : String]
  [value : Json]
  [rest : JsonMemberList]) : JsonMemberList
  (JsonMemberListCons key value (box rest)))

(define (test-json-array [items : JsonList]) : Json
  (JsonArray (box items)))

(define (test-json-object [members : JsonMemberList]) : Json
  (JsonObject (box members)))

(define (assert-parse-string
  [result : JsonParseStringResult]
  [expected : String]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseString value pos)
      (begin
        (assert-owned-string-eq value expected message)
        (assert-i64-eq pos next message))]
    [(ErrJsonParseString _) (panic message)]))

(define (assert-parse-escape
  [result : JsonParseEscapeResult]
  [expected : String]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseEscape value pos)
      (begin
        (assert-owned-string-eq value expected message)
        (assert-i64-eq pos next message))]
    [(ErrJsonParseEscape _) (panic message)]))

(define (assert-codepoint
  [result : JsonCodepointStringResult]
  [expected : String]
  [message : String]) : unit
  (match result
    [(OkJsonCodepointString value)
      (assert-owned-string-eq value expected message)]
    [(ErrJsonCodepointString _) (panic message)]))

(define (assert-json-f64
  [result : JsonNumberF64Result]
  [expected : f64]
  [message : String]) : unit
  (match result
    [(OkJsonNumberF64 value) (assert-f64-eq value expected message)]
    [(ErrJsonNumberF64 _) (panic message)]))

(define (assert-json-f32-as-f64
  [result : JsonNumberF32Result]
  [expected : f64]
  [message : String]) : unit
  (match result
    [(OkJsonNumberF32 value)
      (assert-f64-eq (cast value : f64) expected message)]
    [(ErrJsonNumberF32 _) (panic message)]))

(define (assert-json-f64-error
  [result : JsonNumberF64Result]
  [message : String]) : unit
  (match result
    [(ErrJsonNumberF64 _) unit]
    [(OkJsonNumberF64 _) (panic message)]))

(define (assert-json-f32-error
  [result : JsonNumberF32Result]
  [message : String]) : unit
  (match result
    [(ErrJsonNumberF32 _) unit]
    [(OkJsonNumberF32 _) (panic message)]))

(define (assert-json-number-text
  [result : JsonNumberTextResult]
  [expected : String]
  [message : String]) : unit
  (match result
    [(OkJsonNumberText text) (assert-owned-string-eq text expected message)]
    [(ErrJsonNumberText _) (panic message)]))

(define (assert-parse-value-number
  [result : JsonParseValueResult]
  [expected : String]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseValue value pos)
      (match value
        [(JsonNumber text)
          (begin
            (assert-owned-string-eq text expected message)
            (assert-i64-eq pos next message))]
        [_ (panic message)])]
    [(ErrJsonParseValue _) (panic message)]))

(define (assert-parse-value-bool
  [result : JsonParseValueResult]
  [expected : bool]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseValue value pos)
      (match value
        [(JsonBool actual)
          (begin
            (assert-bool-eq actual expected message)
            (assert-i64-eq pos next message))]
        [_ (panic message)])]
    [(ErrJsonParseValue _) (panic message)]))

(define (assert-parse-array-count
  [result : JsonParseValueResult]
  [expected-count : i64]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseValue value pos)
      (match value
        [(JsonArray items)
          (begin
            (assert-i64-eq
              (json-list-count (box-get items))
              expected-count
              message)
            (assert-i64-eq pos next message))]
        [_ (panic message)])]
    [(ErrJsonParseValue _) (panic message)]))

(define (assert-parse-object-count
  [result : JsonParseValueResult]
  [expected-count : i64]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseValue value pos)
      (match value
        [(JsonObject members)
          (begin
            (assert-i64-eq
              (json-member-list-count (box-get members))
              expected-count
              message)
            (assert-i64-eq pos next message))]
        [_ (panic message)])]
    [(ErrJsonParseValue _) (panic message)]))

(define (json-test-char-code-at [text : String] [idx : i64]) : i64
  (json-char-code-at (& text) idx))

(define (json-test-char-code-eq-at [text : String] [idx : i64] [code : i64]) : bool
  (json-char-code-eq-at (& text) idx code))

(define (json-test-digit-at? [text : String] [idx : i64]) : bool
  (json-digit-at? (& text) idx))

(define (json-test-skip-ws [text : String] [pos : i64]) : i64
  (json-skip-ws (& text) pos))

(define (json-test-prefix-at? [text : String] [prefix : String] [start : i64]) : bool
  (json-string-prefix-at? (& text) (& prefix) start))

(define (json-test-member-list-get [items : JsonMemberList] [key : String]) : JsonLookup
  (json-member-list-get items (& key)))

(define (json-test-object-get [value : Json] [key : String]) : JsonLookup
  (json-object-get value (& key)))

(define (json-test-escape-string [text : String]) : String
  (json-escape-string (& text)))

(define (json-test-parse-unicode-escape [text : String] [pos : i64]) : JsonParseEscapeResult
  (json-parse-unicode-escape (& text) pos))

(define (json-test-parse-escape [text : String] [pos : i64]) : JsonParseEscapeResult
  (json-parse-escape (& text) pos))

(define (json-test-parse-string [text : String] [pos : i64]) : JsonParseStringResult
  (json-parse-string (& text) pos))

(define (json-test-consume-digits [text : String] [pos : i64]) : i64
  (json-consume-digits (& text) pos))

(define (json-test-parse-number [text : String] [pos : i64]) : JsonParseValueResult
  (json-parse-number (& text) pos))

(define (json-test-number-f64 [text : String]) : JsonNumberF64Result
  (json-number->f64 (& text)))

(define (json-test-number-f32 [text : String]) : JsonNumberF32Result
  (json-number->f32 (& text)))

(define (json-test-parse-keyword
  [text : String]
  [pos : i64]
  [keyword : String]
  [value : Json]) : JsonParseValueResult
  (json-parse-keyword (& text) pos keyword value))

(define (json-test-parse-array [text : String] [pos : i64]) : JsonParseValueResult
  (json-parse-array (& text) pos))

(define (json-test-parse-object [text : String] [pos : i64]) : JsonParseValueResult
  (json-parse-object (& text) pos))

(define (json-test-parse-value [text : String] [pos : i64]) : JsonParseValueResult
  (json-parse-value (& text) pos))

(define (main) : i64
  (begin
    (assert-owned-string-eq (str-cat "a" "b" "c") "abc" "json-cat3")
    (assert-owned-string-eq (str-cat "a" "b" "c" "d") "abcd" "json-cat4")
    (assert-i64-eq (json-char-code #A') 65 "json-char-code")
    (assert-i64-eq (json-test-char-code-at "AZ" 1) 90 "json-char-code-at")
    (assert-true
      (json-test-char-code-eq-at "AZ" 0 65)
      "json-char-code-eq-at true")
    (assert-false
      (json-test-char-code-eq-at "AZ" 2 65)
      "json-char-code-eq-at out of range")
    (assert-true (json-space-code? 32) "json-space-code? space")
    (assert-false (json-space-code? 65) "json-space-code? false")
    (assert-true (json-digit-code? 57) "json-digit-code? true")
    (assert-false (json-digit-code? 65) "json-digit-code? false")
    (assert-true (json-test-digit-at? "a5" 1) "json-digit-at? true")
    (assert-false (json-test-digit-at? "a5" 0) "json-digit-at? false")
    (assert-false (json-test-digit-at? "a5" 2) "json-digit-at? out of range")
    (assert-i64-eq (json-test-skip-ws "   X" 0) 3 "json-skip-ws")
    (assert-true
      (json-test-prefix-at? "abcdef" "cd" 2)
      "json-string-prefix-at? true")
    (assert-false
      (json-test-prefix-at? "abcdef" "cd" 5)
      "json-string-prefix-at? false")
    (assert-i64-eq
      (json-list-count
        (test-json-list-cons
          JsonNull
          (test-json-list-cons (JsonBool true) JsonListNil)))
      2
      "json-list-count")
    (assert-owned-string-eq
      (json-stringify-list
        (json-list-reverse
          (test-json-list-cons
            (JsonNumber "2")
            (test-json-list-cons (JsonNumber "1") JsonListNil))))
      "1,2"
      "json-list-reverse")
    (assert-i64-eq
      (json-member-list-count
        (test-json-member-cons
          "a"
          JsonNull
          (test-json-member-cons "b" (JsonBool true) JsonMemberListNil)))
      2
      "json-member-list-count")
    (assert-json-found-number
      (json-test-member-list-get
        (test-json-member-cons
          "a"
          (JsonNumber "1")
          (test-json-member-cons "b" (JsonNumber "2") JsonMemberListNil))
        "b")
      "2"
      "json-member-list-get")
    (assert-json-missing
      (json-test-member-list-get
        (test-json-member-cons "a" (JsonNumber "1") JsonMemberListNil)
        "z")
      "json-member-list-get missing")
    (assert-owned-string-eq
      (json-stringify-members
        (json-member-list-reverse
          (test-json-member-cons
            "b"
            (JsonBool true)
            (test-json-member-cons "a" JsonNull JsonMemberListNil))))
      "\"a\":null,\"b\":true"
      "json-member-list-reverse")
    (assert-json-found-number
      (json-test-object-get
        (test-json-object
          (test-json-member-cons "n" (JsonNumber "7") JsonMemberListNil))
        "n")
      "7"
      "json-object-get")
    (assert-json-missing
      (json-test-object-get JsonNull "n")
      "json-object-get non-object")
    (assert-i64-eq (json-hex-value #A') 10 "json-hex-value upper")
    (assert-i64-eq (json-hex-value #f') 15 "json-hex-value lower")
    (assert-i64-eq (json-hex-value #g') -1 "json-hex-value invalid")
    (assert-owned-string-eq (json-hex-digit 15) "f" "json-hex-digit")
    (assert-owned-string-eq
      (json-control-escape 10)
      "\\n"
      "json-control-escape newline")
    (assert-owned-string-eq
      (json-control-escape 1)
      "\\u0001"
      "json-control-escape unicode")
    (assert-owned-string-eq
      (json-escape-char 34)
      "\\\""
      "json-escape-char quote")
    (assert-owned-string-eq
      (json-escape-char 92)
      "\\\\"
      "json-escape-char slash")
    (assert-owned-string-eq
      (json-test-escape-string "a\n\"\\")
      "a\\n\\\"\\\\"
      "json-escape-string")
    (assert-owned-string-eq
      (json-stringify
        (test-json-array
          (test-json-list-cons
            (JsonNumber "1")
            (test-json-list-cons JsonNull JsonListNil))))
      "[1,null]"
      "json-stringify array")
    (assert-codepoint (json-codepoint-string 65) "A" "json-codepoint-string")
    (match (json-codepoint-string 200)
      [(ErrJsonCodepointString _) unit]
      [(OkJsonCodepointString _)
        (panic "json-codepoint-string rejects unsupported")])
    (assert-parse-escape
      (json-test-parse-unicode-escape "0041" 0)
      "A"
      4
      "json-parse-unicode-escape")
    (match (json-test-parse-unicode-escape "00xz" 0)
      [(ErrJsonParseEscape _) unit]
      [(OkJsonParseEscape _ _)
        (panic "json-parse-unicode-escape rejects invalid")])
    (assert-parse-escape
      (json-test-parse-escape "\\n" 1)
      "\n"
      2
      "json-parse-escape")
    (match (json-test-parse-escape "\\x" 1)
      [(ErrJsonParseEscape _) unit]
      [(OkJsonParseEscape _ _) (panic "json-parse-escape rejects invalid")])
    (assert-parse-string
      (json-test-parse-string "\"a\\n\"" 0)
      "a\n"
      5
      "json-parse-string")
    (match (json-test-parse-string "\"unterminated" 0)
      [(ErrJsonParseString _) unit]
      [(OkJsonParseString _ _) (panic "json-parse-string rejects invalid")])
    (assert-i64-eq
      (json-test-consume-digits "123abc" 0)
      3
      "json-consume-digits")
    (assert-parse-value-number
      (json-test-parse-number "-2.5e3" 0)
      "-2.5e3"
      6
      "json-parse-number")
    (match (json-test-parse-number "01" 0)
      [(ErrJsonParseValue _) unit]
      [(OkJsonParseValue _ _) (panic "json-parse-number rejects leading zero")])
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
      [(OkJsonNumberF64 value)
        (assert-json-number-text
          (json-f64->number-text value)
          "-0"
          "json-number->f64 preserves negative zero")]
      [(ErrJsonNumberF64 _) (panic "json-number->f64 negative zero")])
    (match (json-test-number-f64 "1e+17")
      [(OkJsonNumberF64 value)
        (assert-json-number-text
          (json-f64->number-text value)
          "1e+17"
          "json-number->f64 large magnitude")]
      [(ErrJsonNumberF64 _) (panic "json-number->f64 large magnitude")])
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
      (json-f64->number-text 0.125)
      "0.125"
      "json-f64->number-text")
    (assert-json-number-text
      (json-f32->number-text (cast 1.25 : f32))
      "1.25"
      "json-f32->number-text")
    (assert-parse-value-bool
      (json-test-parse-keyword "true" 0 "true" (JsonBool true))
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