;# JSON parser and serializer for TypeLisp.
;#
;# Provides a canonical JSON value model, recoverable parser, and serializer
;# for tools that need JSON without a private selfhost-only implementation.
;#
;# Primitives required from the compiler/runtime: `string-length`,
;# `string-ref`, `substring`, `string-append`, and the imported
;# `stdlib/string.tl`, `stdlib/io.tl`, and `stdlib/text_buf.tl` helpers.
;#
;# Usage: `(import stdlib.json)`
;#
;# Parsed values, list nodes, decoded strings, and serialized strings are
;# ordinary TypeLisp heap values. They are allocated in the active arena once
;# scoped arenas are enabled, and in the default program-lifetime arena today.
;#
;# ```typelisp
;# (import stdlib.json)
;# (define sample : String (json.json-stringify (json.JsonBool true)))
;# ```
(module stdlib.json)

(import stdlib.string as string_mod)

(import stdlib.io as io_mod)

(import stdlib.str_cat)

(import stdlib.text_buf as text_buf_mod)

;: Canonical JSON value model used by the stdlib parser and serializer.
(defenum Json
  (JsonNull)
  (JsonBool bool)
  (JsonNumber String)
  (JsonString String)
  (JsonArray (Box JsonList))
  (JsonObject (Box JsonMemberList)))

;: Immutable list of JSON array elements in source order.
(defenum JsonList
  (JsonListNil)
  (JsonListCons Json (Box JsonList)))

;: Immutable list of JSON object members in source order.
(defenum JsonMemberList
  (JsonMemberListNil)
  (JsonMemberListCons String Json (Box JsonMemberList)))

;: Recoverable top-level parse result.
(defenum JsonParseResult
  (OkJson Json)
  (ErrJson String))

;: Internal value parser result carrying the parsed value and next offset.
(defenum JsonParseValueResult
  (OkJsonParseValue Json i64)
  (ErrJsonParseValue String))

;: Internal string parser result carrying the decoded string and next offset.
(defenum JsonParseStringResult
  (OkJsonParseString String i64)
  (ErrJsonParseString String))

;: Internal escape parser result carrying the decoded string and next offset.
(defenum JsonParseEscapeResult
  (OkJsonParseEscape String i64)
  (ErrJsonParseEscape String))

;: Result for decoding a supported JSON Unicode codepoint into a String.
(defenum JsonCodepointStringResult
  (OkJsonCodepointString String)
  (ErrJsonCodepointString String))

;: Result for converting valid JSON number text into a finite f64.
(defenum JsonNumberF64Result
  (OkJsonNumberF64 f64)
  (ErrJsonNumberF64 String))

;: Result for converting valid JSON number text into a finite f32.
(defenum JsonNumberF32Result
  (OkJsonNumberF32 f32)
  (ErrJsonNumberF32 String))

;: Result for converting valid JSON integer number text into an i64.
(defenum JsonNumberI64Result
  (OkJsonNumberI64 i64)
  (ErrJsonNumberI64 String))

;: Result for rendering a finite float as valid JSON number text.
(defenum JsonNumberTextResult
  (OkJsonNumberText String)
  (ErrJsonNumberText String))

;: Internal decimal shape extracted from JSON number text.
(defenum JsonNumberShapeResult
  (OkJsonNumberShape i64 i64)
  (ErrJsonNumberShape String))

;: Object lookup result that distinguishes missing keys from JSON null values.
(defenum JsonLookup
  (JsonFound Json)
  (JsonMissing))

;: ASCII printable lookup table used to materialize supported codepoints.
(define json-ascii-printable-table : String
  " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")

;: Return the numeric scalar code for `c`.
(define (json-char-code [c : char]) : i64
  (cast c : i64))

;: Return the numeric scalar code at `idx` in borrowed `text`.
(define (json-char-code-at [text : (& text str)] [idx : i64]) : i64
  (stdlib.json.json-char-code (string-ref text idx)))

;: Return true when `text[idx]` exists and has the supplied code.
(define (json-char-code-eq-at [text : (& text str)] [idx : i64] [code : i64]) : bool
  (if (< idx (string-length text))
    (= (stdlib.json.json-char-code-at text idx) code)
    false))

;: Return true for JSON whitespace scalar codes.
(define (json-space-code? [code : i64]) : bool
  (or (= code 32) (= code 10) (= code 13) (= code 9)))

;: Return true for ASCII decimal digit scalar codes.
(define (json-digit-code? [code : i64]) : bool
  (and (>= code 48) (<= code 57)))

;: Return true when `text[idx]` exists and is an ASCII decimal digit.
(define (json-digit-at? [text : (& text str)] [idx : i64]) : bool
  (if (< idx (string-length text))
    (stdlib.json.json-digit-code? (stdlib.json.json-char-code-at text idx))
    false))

;: Maximum non-zero significant decimal digits accepted by JSON float helpers.
(define json-number-max-significant-digits : i64
  300)

;: Return the first offset at or after `pos` that is not JSON whitespace.
(define (json-skip-ws [text : (& text str)] [pos : i64]) : i64
  (let
    [i : i64 pos]
    [n : i64 (string-length text)]
    [done : bool false]
    (begin
      (while (not done)
        (if (< i n)
          (if (stdlib.json.json-space-code?
            (stdlib.json.json-char-code-at text i))
            (set! i (+ i 1))
            (set! done true))
          (set! done true)))
      i)))

;: Return true when borrowed `prefix` occurs in borrowed `text` at `start`.
(define (json-string-prefix-at?
  [text : (& text str)]
  [prefix : (& prefix str)]
  [start : i64]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (> (+ start prefix-len) text-len)
      false
      (let
        [i : i64 0]
        [ok : bool true]
        (begin
          (while (and ok (< i prefix-len))
            (if (=
              (stdlib.json.json-char-code-at text (+ start i))
              (stdlib.json.json-char-code (string-ref prefix i)))
              (set! i (+ i 1))
              (set! ok false)))
          ok)))))

;: Reverse `items` onto `acc`, allocating a fresh active-arena list spine.
(define (json-list-reverse-onto [items : JsonList] [acc : JsonList]) : JsonList
  (match items
    [(JsonListNil) acc]
    [(JsonListCons head rest)
      (stdlib.json.json-list-reverse-onto
        (box-get rest)
        (JsonListCons head (box acc)))]))

;: Return `items` in reverse order.
(define (json-list-reverse [items : JsonList]) : JsonList
  (stdlib.json.json-list-reverse-onto items stdlib.json.JsonListNil))

;: Reverse object `items` onto `acc`, allocating a fresh active-arena list spine.
(define (json-member-list-reverse-onto
  [items : JsonMemberList]
  [acc : JsonMemberList]) : JsonMemberList
  (match items
    [(JsonMemberListNil) acc]
    [(JsonMemberListCons key value rest)
      (stdlib.json.json-member-list-reverse-onto
        (box-get rest)
        (JsonMemberListCons key value (box acc)))]))

;: Return object `items` in reverse order.
(define (json-member-list-reverse [items : JsonMemberList]) : JsonMemberList
  (stdlib.json.json-member-list-reverse-onto
    items
    stdlib.json.JsonMemberListNil))

;: Return the number of elements in a JSON array list.
(define (json-list-count [items : JsonList]) : i64
  (match items
    [(JsonListNil) 0]
    [(JsonListCons _ rest) (+ 1 (stdlib.json.json-list-count (box-get rest)))]))

;: Return the number of key/value entries in a JSON object member list.
(define (json-member-list-count [items : JsonMemberList]) : i64
  (match items
    [(JsonMemberListNil) 0]
    [(JsonMemberListCons _ _ rest)
      (+ 1 (stdlib.json.json-member-list-count (box-get rest)))]))

;: Look up borrowed `key` in an object member list.
(define (json-member-list-get [items : JsonMemberList] [key : (& key str)]) : JsonLookup
  (match items
    [(JsonMemberListNil) JsonMissing]
    [(JsonMemberListCons item-key value rest)
      (if (string_mod.string-eq-borrowed (& item-key) key)
        (JsonFound value)
        (stdlib.json.json-member-list-get (box-get rest) key))]))

;: Compare two owned strings with only safe character indexing.
(define (json-string-eq-safe? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
    (if (!= left-len right-len)
      false
      (let
        [i : i64 0]
        [same : bool true]
        (begin
          (while (and same (< i left-len))
            (if (=
              (stdlib.json.json-char-code (string-ref left i))
              (stdlib.json.json-char-code (string-ref right i)))
              (set! i (+ i 1))
              (set! same false)))
          same)))))

;: Look up owned `key` in an object member list without unsafe helpers.
(define (json-member-list-get-owned [items : JsonMemberList] [key : String]) : JsonLookup
  (match items
    [(JsonMemberListNil) JsonMissing]
    [(JsonMemberListCons item-key value rest)
      (if (stdlib.json.json-string-eq-safe? item-key key)
        (JsonFound value)
        (stdlib.json.json-member-list-get-owned (box-get rest) key))]))

;: Look up borrowed `key` in `value` when it is a JSON object.
;:
;: Non-object values return `JsonMissing`.
;:
;: ```typelisp
;: (import stdlib.json)
;: (define found : json.JsonLookup
;:   (let
;:     [key : String "name"]
;:     (json.json-object-get
;:       (json.JsonObject
;:         (box
;:           (json.JsonMemberListCons
;:             "name"
;:             (json.JsonString "tl")
;:             (box json.JsonMemberListNil))))
;:       (& key))))
;: ```
(define (json-object-get [value : Json] [key : (& key str)]) : JsonLookup
  (match value
    [(JsonObject members)
      (stdlib.json.json-member-list-get (box-get members) key)]
    [_ JsonMissing]))

;: Look up owned `key` in `value` without unsafe helpers.
;:
;: This is useful for generated declarations, whose templates are purity-checked.
(define (json-object-get-owned [value : Json] [key : String]) : JsonLookup
  (match value
    [(JsonObject members)
      (stdlib.json.json-member-list-get-owned (box-get members) key)]
    [_ JsonMissing]))

;: Decode a hexadecimal digit char, or return -1 when it is not a hex digit.
(define (json-hex-value [c : char]) : i64
  (let
    [code : i64 (stdlib.json.json-char-code c)]
    (if (and (>= code 48) (<= code 57))
      (- code 48)
      (if (and (>= code 65) (<= code 70))
        (+ 10 (- code 65))
        (if (and (>= code 97) (<= code 102))
          (+ 10 (- code 97))
          -1)))))

;: Encode a value from 0 through 15 as a one-character lowercase hex string.
(define (json-hex-digit [value : i64]) : String
  (if (= value 0)
    "0"
    (if (= value 1)
      "1"
      (if (= value 2)
        "2"
        (if (= value 3)
          "3"
          (if (= value 4)
            "4"
            (if (= value 5)
              "5"
              (if (= value 6)
                "6"
                (if (= value 7)
                  "7"
                  (if (= value 8)
                    "8"
                    (if (= value 9)
                      "9"
                      (if (= value 10)
                        "a"
                        (if (= value 11)
                          "b"
                          (if (= value 12)
                            "c"
                            (if (= value 13)
                              "d"
                              (if (= value 14)
                                "e"
                                "f"))))))))))))))))

;: Return the JSON escape spelling for a control scalar code.
(define (json-control-escape [code : i64]) : String
  (if (= code 8)
    "\\b"
    (if (= code 9)
      "\\t"
      (if (= code 10)
        "\\n"
        (if (= code 12)
          "\\f"
          (if (= code 13)
            "\\r"
            (str_cat.str-cat
              "\\u00"
              (stdlib.json.json-hex-digit (/ code 16))
              (stdlib.json.json-hex-digit (- code (* (/ code 16) 16)))
              "")))))))

;: Return the JSON escape spelling for one string scalar code.
(define (json-escape-char [code : i64]) : String
  (if (= code 34)
    (string_mod.string-append "\\" "\"")
    (if (= code 92)
      (string_mod.string-append "\\" "\\")
      (stdlib.json.json-control-escape code))))

;: Escape borrowed raw text for JSON string output.
;:
;: The returned escaped string is allocated in the active arena.
(define (json-escape-string [text : (& text str)]) : String
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [segment-start : i64 0]
    [out : text_buf_mod.TextBuf (text_buf_mod.text-buf-empty)]
    (begin
      (while (< i n)
        (let
          [code : i64 (stdlib.json.json-char-code-at text i)]
          (if (or (= code 34) (= code 92) (< code 32))
            (begin
              (set!
                out
                (text_buf_mod.text-buf-append
                  out
                  (string_mod.substring-borrowed
                    text
                    segment-start
                    (- i segment-start))))
              (set!
                out
                (text_buf_mod.text-buf-append
                  out
                  (stdlib.json.json-escape-char code)))
              (set! i (+ i 1))
              (set! segment-start i))
            (set! i (+ i 1)))))
      (set!
        out
        (text_buf_mod.text-buf-append
          out
          (string_mod.substring-borrowed text segment-start (- n segment-start))))
      (text_buf_mod.text-buf-render out))))

;: Append serialized array elements to `buf`.
(define (json-stringify-list-into
  [items : JsonList]
  [buf : text_buf_mod.TextBuf]) : text_buf_mod.TextBuf
  (match items
    [(JsonListNil) buf]
    [(JsonListCons head rest)
      (let
        [with-head : text_buf_mod.TextBuf
          (text_buf_mod.text-buf-append buf (stdlib.json.json-stringify head))]
        (match (box-get rest)
          [(JsonListNil) with-head]
          [(JsonListCons _ _)
            (stdlib.json.json-stringify-list-into
              (box-get rest)
              (text_buf_mod.text-buf-append with-head ","))]))]))

;: Serialize array `items` without the surrounding brackets.
;:
;: The returned comma-separated string is allocated in the active arena.
(define (json-stringify-list [items : JsonList]) : String
  (text_buf_mod.text-buf-render
    (stdlib.json.json-stringify-list-into items (text_buf_mod.text-buf-empty))))

;: Append serialized object members to `buf`.
(define (json-stringify-members-into
  [items : JsonMemberList]
  [buf : text_buf_mod.TextBuf]) : text_buf_mod.TextBuf
  (match items
    [(JsonMemberListNil) buf]
    [(JsonMemberListCons key value rest)
      (let
        [text : String key]
        [with-item : text_buf_mod.TextBuf
          (text_buf_mod.text-buf-append
            (text_buf_mod.text-buf-append
              (text_buf_mod.text-buf-append
                (text_buf_mod.text-buf-append buf "\"")
                (stdlib.json.json-escape-string (& text)))
              "\":")
            (stdlib.json.json-stringify value))]
        (match (box-get rest)
          [(JsonMemberListNil) with-item]
          [(JsonMemberListCons _ _ _)
            (stdlib.json.json-stringify-members-into
              (box-get rest)
              (text_buf_mod.text-buf-append with-item ","))]))]))

;: Serialize object `items` without the surrounding braces.
;:
;: The returned comma-separated member string is allocated in the active arena.
(define (json-stringify-members [items : JsonMemberList]) : String
  (text_buf_mod.text-buf-render
    (stdlib.json.json-stringify-members-into
      items
      (text_buf_mod.text-buf-empty))))

;: Serialize a JSON value to canonical compact JSON text.
;:
;: The returned string is allocated in the active arena.
;:
;: ```typelisp
;: (import stdlib.json)
;: (define encoded : String
;:   (json.json-stringify
;:     (json.JsonArray (box (json.JsonListCons (json.JsonBool true) (box json.JsonListNil))))))
;: ```
(define (json-stringify [value : Json]) : String
  (match value
    [(JsonNull) "null"]
    [(JsonBool b)
      (if b
        "true"
        "false")]
    [(JsonNumber text) text]
    [(JsonString text)
      (str_cat.str-cat "\"" (stdlib.json.json-escape-string (& text)) "\"")]
    [(JsonArray items)
      (str_cat.str-cat
        "["
        (stdlib.json.json-stringify-list (box-get items))
        "]")]
    [(JsonObject members)
      (str_cat.str-cat
        "{"
        (stdlib.json.json-stringify-members (box-get members))
        "}")]))

;: Render an i64 as a JSON number value.
(define (json-i64->number [value : i64]) : Json
  (JsonNumber (string_mod.int->string value)))

;: Convert a supported Unicode scalar codepoint into a TypeLisp String.
;:
;: Only tab, newline, carriage return, and printable ASCII are supported today.
;: Successful decoded strings allocate in the active arena.
(define (json-codepoint-string [code : i64]) : JsonCodepointStringResult
  (if (= code 9)
    (OkJsonCodepointString "\t")
    (if (= code 10)
      (OkJsonCodepointString "\n")
      (if (= code 13)
        (OkJsonCodepointString "\r")
        (if (and (>= code 32) (<= code 126))
          (OkJsonCodepointString
            (string_mod.substring json-ascii-printable-table (- code 32) 1))
          (ErrJsonCodepointString
            "json: unicode escape outside supported string range"))))))

;: Parse four hex digits after a `\u` escape and return the decoded string.
(define (json-parse-unicode-escape [text : (& text str)] [pos : i64]) : JsonParseEscapeResult
  (let
    [n : i64 (string-length text)]
    (if (> (+ pos 4) n)
      (ErrJsonParseEscape "json: unterminated unicode escape")
      (let
        [j : i64 0]
        [value : i64 0]
        [ok : bool true]
        [message : String ""]
        (begin
          (while (and ok (< j 4))
            (let
              [digit : i64
                (stdlib.json.json-hex-value (string-ref text (+ pos j)))]
              (if (< digit 0)
                (begin
                  (set! ok false)
                  (set! message "json: invalid unicode escape digit"))
                (begin
                  (set! value (+ (* value 16) digit))
                  (set! j (+ j 1))))))
          (if ok
            (match (stdlib.json.json-codepoint-string value)
              [(OkJsonCodepointString decoded)
                (OkJsonParseEscape decoded (+ pos 4))]
              [(ErrJsonCodepointString err) (ErrJsonParseEscape err)])
            (ErrJsonParseEscape message)))))))

;: Parse a JSON string escape at `pos`.
;:
;: Successful decoded strings allocate in the active arena.
(define (json-parse-escape [text : (& text str)] [pos : i64]) : JsonParseEscapeResult
  (if (>= pos (string-length text))
    (ErrJsonParseEscape "json: unterminated JSON escape")
    (let
      [code : i64 (stdlib.json.json-char-code-at text pos)]
      (if (= code 34)
        (OkJsonParseEscape "\"" (+ pos 1))
        (if (= code 92)
          (OkJsonParseEscape "\\" (+ pos 1))
          (if (= code 47)
            (OkJsonParseEscape "/" (+ pos 1))
            (if (= code 110)
              (OkJsonParseEscape "\n" (+ pos 1))
              (if (= code 114)
                (OkJsonParseEscape "\r" (+ pos 1))
                (if (= code 116)
                  (OkJsonParseEscape "\t" (+ pos 1))
                  (if (= code 117)
                    (stdlib.json.json-parse-unicode-escape text (+ pos 1))
                    (ErrJsonParseEscape "json: unsupported JSON string escape")))))))))))

;: Parse a JSON string starting at `pos`, including the opening quote.
;:
;: The decoded string is allocated in the active arena.
(define (json-parse-string [text : (& text str)] [pos : i64]) : JsonParseStringResult
  (if (not (stdlib.json.json-char-code-eq-at text pos 34))
    (ErrJsonParseString "json: expected string")
    (let
      [n : i64 (string-length text)]
      [i : i64 (+ pos 1)]
      [segment-start : i64 (+ pos 1)]
      [out : text_buf_mod.TextBuf (text_buf_mod.text-buf-empty)]
      [ok : bool true]
      [done : bool false]
      [message : String ""]
      (begin
        (while (and ok (not done))
          (if (>= i n)
            (begin
              (set! ok false)
              (set! done true)
              (set! message "json: unterminated string"))
            (let
              [code : i64 (stdlib.json.json-char-code-at text i)]
              (if (= code 34)
                (begin
                  (set!
                    out
                    (text_buf_mod.text-buf-append
                      out
                      (string_mod.substring-borrowed
                        text
                        segment-start
                        (- i segment-start))))
                  (set! i (+ i 1))
                  (set! done true))
                (if (= code 92)
                  (begin
                    (set!
                      out
                      (text_buf_mod.text-buf-append
                        out
                        (string_mod.substring-borrowed
                          text
                          segment-start
                          (- i segment-start))))
                    (match (stdlib.json.json-parse-escape text (+ i 1))
                      [(OkJsonParseEscape decoded next)
                        (begin
                          (set! out (text_buf_mod.text-buf-append out decoded))
                          (set! i next)
                          (set! segment-start next))]
                      [(ErrJsonParseEscape err)
                        (begin
                          (set! ok false)
                          (set! done true)
                          (set! message err))]))
                  (if (< code 32)
                    (begin
                      (set! ok false)
                      (set! done true)
                      (set! message "json: control character in string"))
                    (set! i (+ i 1))))))))
        (if ok
          (OkJsonParseString (text_buf_mod.text-buf-render out) i)
          (ErrJsonParseString message))))))

;: Return the first offset at or after `pos` that is not an ASCII digit.
(define (json-consume-digits [text : (& text str)] [pos : i64]) : i64
  (let
    [i : i64 pos]
    [done : bool false]
    (begin
      (while (not done)
        (if (stdlib.json.json-digit-at? text i)
          (set! i (+ i 1))
          (set! done true)))
      i)))

;: Parse a JSON number starting at `pos`.
;:
;: The numeric spelling is kept as a String allocated in the active arena.
(define (json-parse-number [text : (& text str)] [pos : i64]) : JsonParseValueResult
  (let
    [n : i64 (string-length text)]
    [i : i64 pos]
    [ok : bool true]
    [message : String ""]
    (begin
      (if (stdlib.json.json-char-code-eq-at text i 45)
        (set! i (+ i 1))
        unit)
      (if (>= i n)
        (begin
          (set! ok false)
          (set! message "json: expected digit in number"))
        unit)
      (if ok
        (if (stdlib.json.json-char-code-eq-at text i 48)
          (begin
            (set! i (+ i 1))
            (if (stdlib.json.json-digit-at? text i)
              (begin
                (set! ok false)
                (set! message "json: leading zero in number"))
              unit))
          (if (stdlib.json.json-digit-at? text i)
            (set! i (stdlib.json.json-consume-digits text i))
            (begin
              (set! ok false)
              (set! message "json: expected digit in number"))))
        unit)
      (if ok
        (if (stdlib.json.json-char-code-eq-at text i 46)
          (begin
            (set! i (+ i 1))
            (if (stdlib.json.json-digit-at? text i)
              (set! i (stdlib.json.json-consume-digits text i))
              (begin
                (set! ok false)
                (set! message "json: expected digit after decimal point"))))
          unit)
        unit)
      (if ok
        (if (or
          (stdlib.json.json-char-code-eq-at text i 101)
          (stdlib.json.json-char-code-eq-at text i 69))
          (begin
            (set! i (+ i 1))
            (if (or
              (stdlib.json.json-char-code-eq-at text i 43)
              (stdlib.json.json-char-code-eq-at text i 45))
              (set! i (+ i 1))
              unit)
            (if (stdlib.json.json-digit-at? text i)
              (set! i (stdlib.json.json-consume-digits text i))
              (begin
                (set! ok false)
                (set! message "json: expected digit in exponent"))))
          unit)
        unit)
      (if ok
        (OkJsonParseValue
          (JsonNumber (string_mod.substring-borrowed text pos (- i pos)))
          i)
        (ErrJsonParseValue message)))))

;: Return the integer value of an ASCII decimal digit.
(define (json-number-digit-value [c : char]) : i64
  (- (stdlib.json.json-char-code c) 48))

;: Return true when `code` is a JSON exponent marker.
(define (json-number-exponent-code? [code : i64]) : bool
  (or (= code 101) (= code 69)))

;: Scan grammar-checked JSON number text for significant digits and exponent.
(define (json-number-shape [text : String]) : JsonNumberShapeResult
  (let
    [n : i64 (string-length text)]
    [index : i64 0]
    [seen-significant : bool false]
    [significant-digits : i64 0]
    [digit-count : i64 0]
    [frac-digits : i64 0]
    [exp-negative : bool false]
    [exp-value : i64 0]
    [exp-digits : i64 0]
    [saw-exp : bool false]
    (if (= n 0)
      (ErrJsonNumberShape "json: expected digit in number")
      (begin
        (if (= (string-ref text 0) #-')
          (set! index 1)
          unit)
        (while (and
          (< index n)
          (stdlib.json.json-digit-code?
            (stdlib.json.json-char-code (string-ref text index))))
          (let
            [digit : i64
              (stdlib.json.json-number-digit-value (string-ref text index))]
            (begin
              (when
                (or seen-significant (!= digit 0))
                (begin
                  (set! seen-significant true)
                  (set! significant-digits (+ significant-digits 1))))
              (set! digit-count (+ digit-count 1))
              (set! index (+ index 1)))))
        (if (and (< index n) (= (string-ref text index) #.'))
          (begin
            (set! index (+ index 1))
            (while (and
              (< index n)
              (stdlib.json.json-digit-code?
                (stdlib.json.json-char-code (string-ref text index))))
              (let
                [digit : i64
                  (stdlib.json.json-number-digit-value (string-ref text index))]
                (begin
                  (when
                    (or seen-significant (!= digit 0))
                    (begin
                      (set! seen-significant true)
                      (set! significant-digits (+ significant-digits 1))))
                  (set! frac-digits (+ frac-digits 1))
                  (set! digit-count (+ digit-count 1))
                  (set! index (+ index 1))))))
          unit)
        (if (and
          (< index n)
          (stdlib.json.json-number-exponent-code?
            (stdlib.json.json-char-code (string-ref text index))))
          (begin
            (set! saw-exp true)
            (set! index (+ index 1))
            (if (and (< index n) (= (string-ref text index) #-'))
              (begin
                (set! exp-negative true)
                (set! index (+ index 1)))
              (if (and (< index n) (= (string-ref text index) #+'))
                (set! index (+ index 1))
                unit))
            (while (and
              (< index n)
              (stdlib.json.json-digit-code?
                (stdlib.json.json-char-code (string-ref text index))))
              (let
                [digit : i64
                  (stdlib.json.json-number-digit-value (string-ref text index))]
                (begin
                  (when
                    (< exp-value 4000)
                    (set! exp-value (+ (* exp-value 10) digit)))
                  (set! exp-digits (+ exp-digits 1))
                  (set! index (+ index 1))))))
          unit)
        (if (or (= digit-count 0) (!= index n) (and saw-exp (= exp-digits 0)))
          (ErrJsonNumberShape "json: invalid number")
          (OkJsonNumberShape
            (-
              (if exp-negative
                (- 0 exp-value)
                exp-value)
              frac-digits)
            significant-digits))))))

;: Validate that borrowed text is exactly one JSON number and return an owned copy.
(define (json-number-validated-text [text : (& text str)]) : JsonNumberTextResult
  (let
    [n : i64 (string-length text)]
    (match (stdlib.json.json-parse-number text 0)
      [(OkJsonParseValue _ next)
        (if (= next n)
          (OkJsonNumberText (string_mod.substring-borrowed text 0 n))
          (ErrJsonNumberText "json: trailing characters after number"))]
      [(ErrJsonParseValue message) (ErrJsonNumberText message)])))

;: Return true when validated JSON number text is an integer spelling.
(define (json-number-integer-text? [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    (begin
      (when (and (> n 0) (= (string-ref text 0) #-')) (set! i 1))
      (if (>= i n)
        false
        (let
          [first : i64 (stdlib.json.json-char-code (string-ref text i))]
          [ok : bool true]
          (if (= first 48)
            (= (+ i 1) n)
            (if (and (>= first 49) (<= first 57))
              (begin
                (set! i (+ i 1))
                (while (and ok (< i n))
                  (let
                    [code : i64
                      (stdlib.json.json-char-code (string-ref text i))]
                    (if (stdlib.json.json-digit-code? code)
                      (set! i (+ i 1))
                      (set! ok false))))
                ok)
              false)))))))

;: Return true when `text[start..]` is lexicographically greater than `limit`.
(define (json-number-digits-gt-limit?
  [text : String]
  [start : i64]
  [limit : String]) : bool
  (let
    [digits-len : i64 (- (string-length text) start)]
    [limit-len : i64 (string-length limit)]
    [i : i64 0]
    [greater : bool false]
    [done : bool false]
    (if (> digits-len limit-len)
      true
      (if (< digits-len limit-len)
        false
        (begin
          (while (and (not done) (< i limit-len))
            (let
              [actual : i64
                (stdlib.json.json-char-code (string-ref text (+ start i)))]
              [expected : i64 (stdlib.json.json-char-code (string-ref limit i))]
              (if (> actual expected)
                (begin
                  (set! greater true)
                  (set! done true))
                (if (< actual expected)
                  (set! done true)
                  (set! i (+ i 1))))))
          greater)))))

;: Return true when integer number text fits in the signed i64 range.
(define (json-number-i64-range? [text : String]) : bool
  (let
    [negative : bool
      (and (> (string-length text) 0) (= (string-ref text 0) #-'))]
    [start : i64
      (if negative
        1
        0)]
    [limit : String
      (if negative
        "9223372036854775808"
        "9223372036854775807")]
    (not (stdlib.json.json-number-digits-gt-limit? text start limit))))

;: Parse owned JSON integer number text into an i64 with recoverable errors.
(define (json-number-owned->i64 [owned : String]) : JsonNumberI64Result
  (if (not (stdlib.json.json-number-integer-text? owned))
    (ErrJsonNumberI64 "json: expected integer number")
    (if (not (stdlib.json.json-number-i64-range? owned))
      (ErrJsonNumberI64 "json: integer outside i64 range")
      (OkJsonNumberI64 (string_mod.string->int owned)))))

;: Parse borrowed JSON integer number text into an i64 with recoverable errors.
;:
;: The text must be exactly one JSON integer number. Decimal fractions,
;: exponents, malformed numbers, and i64 overflow reject.
(define (json-number->i64 [text : (& text str)]) : JsonNumberI64Result
  (match (stdlib.json.json-number-validated-text text)
    [(OkJsonNumberText owned) (stdlib.json.json-number-owned->i64 owned)]
    [(ErrJsonNumberText message) (ErrJsonNumberI64 message)]))

;: Convert validated JSON number text into a finite f64 result.
(define (json-number-decimal-f64-result
  [owned : String]
  [decimal-exp : i64]
  [significant-digits : i64]) : JsonNumberF64Result
  (let
    [nonzero : bool (> significant-digits 0)]
    [adjusted-exp : i64
      (if nonzero
        (+ decimal-exp (- significant-digits 1))
        0)]
    (if (> significant-digits stdlib.json.json-number-max-significant-digits)
      (ErrJsonNumberF64 "json: number has too many significant digits")
      (if (and nonzero (> adjusted-exp 308))
        (ErrJsonNumberF64 "json: number outside finite f64 range")
        (if (and nonzero (< adjusted-exp -324))
          (ErrJsonNumberF64 "json: number underflows f64")
          (match (io_mod.io-float-parse-f64 owned)
            [(io_mod.IoFloatSomeF64 value)
              (if (and nonzero (io_mod.io-float-f64-zero-magnitude? value))
                (ErrJsonNumberF64 "json: number underflows f64")
                (OkJsonNumberF64 value))]
            [(io_mod.IoFloatNoF64)
              (ErrJsonNumberF64 "json: number outside finite f64 range")]))))))

;: Parse borrowed JSON number text into a finite f64.
;:
;: The text must be exactly one JSON number; overflow and underflow reject.
(define (json-number->f64 [text : (& text str)]) : JsonNumberF64Result
  (match (stdlib.json.json-number-validated-text text)
    [(OkJsonNumberText owned)
      (match (stdlib.json.json-number-shape owned)
        [(OkJsonNumberShape decimal-exp significant-digits)
          (stdlib.json.json-number-decimal-f64-result
            owned
            decimal-exp
            significant-digits)]
        [(ErrJsonNumberShape message) (ErrJsonNumberF64 message)])]
    [(ErrJsonNumberText message) (ErrJsonNumberF64 message)]))

;: Parse borrowed JSON number text into a finite f32.
;:
;: Uses the f64 path, then rejects f32 overflow and non-zero underflow.
(define (json-number->f32 [text : (& text str)]) : JsonNumberF32Result
  (match (stdlib.json.json-number->f64 text)
    [(OkJsonNumberF64 wide)
      (let
        [narrow : f32 (cast wide : f32)]
        (if (not (io_mod.io-float-f32-finite? narrow))
          (ErrJsonNumberF32 "json: number outside finite f32 range")
          (if (and
            (io_mod.io-float-f32-zero-magnitude? narrow)
            (not (io_mod.io-float-f64-zero-magnitude? wide)))
            (ErrJsonNumberF32 "json: number underflows f32")
            (OkJsonNumberF32 narrow))))]
    [(ErrJsonNumberF64 message) (ErrJsonNumberF32 message)]))

;: Render a finite f64 as deterministic JSON number text.
;:
;: NaN and infinity are rejected; negative zero renders as `-0`.
(define (json-f64->number-text [value : f64]) : JsonNumberTextResult
  (if (io_mod.io-float-f64-finite? value)
    (OkJsonNumberText (io_mod.io-format-float-core value))
    (ErrJsonNumberText "json: non-finite f64 cannot be rendered as a number")))

;: Render a finite f32 as deterministic JSON number text.
;:
;: Widens to f64 so the binary32-rounded value is formatted deterministically.
(define (json-f32->number-text [value : f32]) : JsonNumberTextResult
  (if (io_mod.io-float-f32-finite? value)
    (OkJsonNumberText (io_mod.io-format-float-core (cast value : f64)))
    (ErrJsonNumberText "json: non-finite f32 cannot be rendered as a number")))

;: Parse `keyword` at `pos` and return its fixed JSON value.
(define (json-parse-keyword
  [text : (& text str)]
  [pos : i64]
  [keyword : String]
  [value : Json]) : JsonParseValueResult
  (let
    [prefix : String keyword]
    (if (stdlib.json.json-string-prefix-at? text (& prefix) pos)
      (OkJsonParseValue value (+ pos (string-length prefix)))
      (ErrJsonParseValue "json: expected keyword"))))

;: Parse a JSON array starting at `pos`, including the opening bracket.
;:
;: The returned array list and nested values are allocated in the active arena.
(define (json-parse-array [text : (& text str)] [pos : i64]) : JsonParseValueResult
  (let
    [i : i64 (stdlib.json.json-skip-ws text (+ pos 1))]
    [items : JsonList stdlib.json.JsonListNil]
    [ok : bool true]
    [done : bool false]
    [message : String ""]
    (begin
      (if (stdlib.json.json-char-code-eq-at text i 93)
        (begin
          (set! i (+ i 1))
          (set! done true))
        unit)
      (while (and ok (not done))
        (match (stdlib.json.json-parse-value text i)
          [(OkJsonParseValue value next)
            (begin
              (set! items (JsonListCons value (box items)))
              (set! i (stdlib.json.json-skip-ws text next))
              (if (stdlib.json.json-char-code-eq-at text i 93)
                (begin
                  (set! i (+ i 1))
                  (set! done true))
                (if (stdlib.json.json-char-code-eq-at text i 44)
                  (set! i (stdlib.json.json-skip-ws text (+ i 1)))
                  (begin
                    (set! ok false)
                    (set! message "json: expected ',' or ']' in array")))))]
          [(ErrJsonParseValue err)
            (begin
              (set! ok false)
              (set! message err))]))
      (if ok
        (OkJsonParseValue
          (JsonArray (box (stdlib.json.json-list-reverse items)))
          i)
        (ErrJsonParseValue message)))))

;: Parse a JSON object starting at `pos`, including the opening brace.
;:
;: The returned member list, keys, and nested values allocate in the active arena.
(define (json-parse-object [text : (& text str)] [pos : i64]) : JsonParseValueResult
  (let
    [i : i64 (stdlib.json.json-skip-ws text (+ pos 1))]
    [members : JsonMemberList stdlib.json.JsonMemberListNil]
    [ok : bool true]
    [done : bool false]
    [message : String ""]
    (begin
      (if (stdlib.json.json-char-code-eq-at text i 125)
        (begin
          (set! i (+ i 1))
          (set! done true))
        unit)
      (while (and ok (not done))
        (match (stdlib.json.json-parse-string text i)
          [(OkJsonParseString key after-key)
            (let
              [colon-pos : i64 (stdlib.json.json-skip-ws text after-key)]
              (if (stdlib.json.json-char-code-eq-at text colon-pos 58)
                (match (stdlib.json.json-parse-value text (+ colon-pos 1))
                  [(OkJsonParseValue value next)
                    (begin
                      (set!
                        members
                        (JsonMemberListCons key value (box members)))
                      (set! i (stdlib.json.json-skip-ws text next))
                      (if (stdlib.json.json-char-code-eq-at text i 125)
                        (begin
                          (set! i (+ i 1))
                          (set! done true))
                        (if (stdlib.json.json-char-code-eq-at text i 44)
                          (set! i (stdlib.json.json-skip-ws text (+ i 1)))
                          (begin
                            (set! ok false)
                            (set! message "json: expected ',' or '}' in object")))))]
                  [(ErrJsonParseValue err)
                    (begin
                      (set! ok false)
                      (set! message err))])
                (begin
                  (set! ok false)
                  (set! message "json: expected ':' in object"))))]
          [(ErrJsonParseString err)
            (begin
              (set! ok false)
              (set! message err))]))
      (if ok
        (OkJsonParseValue
          (JsonObject (box (stdlib.json.json-member-list-reverse members)))
          i)
        (ErrJsonParseValue message)))))

;: Parse one JSON value from `text` at `pos`, after skipping whitespace.
;:
;: Returned aggregate, string, and number values allocate in the active arena.
(define (json-parse-value [text : (& text str)] [pos : i64]) : JsonParseValueResult
  (let
    [i : i64 (stdlib.json.json-skip-ws text pos)]
    [n : i64 (string-length text)]
    (if (>= i n)
      (ErrJsonParseValue "json: expected JSON value")
      (let
        [code : i64 (stdlib.json.json-char-code-at text i)]
        (if (= code 110)
          (stdlib.json.json-parse-keyword text i "null" stdlib.json.JsonNull)
          (if (= code 116)
            (stdlib.json.json-parse-keyword text i "true" (JsonBool true))
            (if (= code 102)
              (stdlib.json.json-parse-keyword text i "false" (JsonBool false))
              (if (= code 34)
                (match (stdlib.json.json-parse-string text i)
                  [(OkJsonParseString value next)
                    (OkJsonParseValue (JsonString value) next)]
                  [(ErrJsonParseString err) (ErrJsonParseValue err)])
                (if (= code 91)
                  (stdlib.json.json-parse-array text i)
                  (if (= code 123)
                    (stdlib.json.json-parse-object text i)
                    (if (or (= code 45) (stdlib.json.json-digit-code? code))
                      (stdlib.json.json-parse-number text i)
                      (ErrJsonParseValue
                        "json: unexpected character while parsing value"))))))))))))

;: Parse an entire JSON document with recoverable errors.
;:
;: Successful values and decoded strings allocate in the active arena.
;:
;: ```typelisp
;: (import stdlib.json)
;: (define parsed : JsonParseResult
;:   (let
;:     [text : String "{\"ok\":true}"]
;:     (stdlib.json.json-parse (& text))))
;: ```
(define (json-parse [text : (& text str)]) : JsonParseResult
  (match (stdlib.json.json-parse-value text 0)
    [(OkJsonParseValue value pos)
      (let
        [end : i64 (stdlib.json.json-skip-ws text pos)]
        (if (= end (string-length text))
          (OkJson value)
          (ErrJson "json: trailing characters after JSON value")))]
    [(ErrJsonParseValue message) (ErrJson message)]))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value json-ascii-printable-table)
  (value json-char-code)
  (value json-char-code-at)
  (value json-char-code-eq-at)
  (value json-space-code?)
  (value json-digit-code?)
  (value json-digit-at?)
  (value json-number-max-significant-digits)
  (value json-skip-ws)
  (value json-string-prefix-at?)
  (value json-list-reverse-onto)
  (value json-list-reverse)
  (value json-member-list-reverse-onto)
  (value json-member-list-reverse)
  (value json-list-count)
  (value json-member-list-count)
  (value json-member-list-get)
  (value json-string-eq-safe?)
  (value json-member-list-get-owned)
  (value json-object-get)
  (value json-object-get-owned)
  (value json-hex-value)
  (value json-hex-digit)
  (value json-control-escape)
  (value json-escape-char)
  (value json-escape-string)
  (value json-stringify-list-into)
  (value json-stringify-list)
  (value json-stringify-members-into)
  (value json-stringify-members)
  (value json-stringify)
  (value json-i64->number)
  (value json-codepoint-string)
  (value json-parse-unicode-escape)
  (value json-parse-escape)
  (value json-parse-string)
  (value json-consume-digits)
  (value json-parse-number)
  (value json-number-digit-value)
  (value json-number-exponent-code?)
  (value json-number-shape)
  (value json-number-validated-text)
  (value json-number-integer-text?)
  (value json-number-digits-gt-limit?)
  (value json-number-i64-range?)
  (value json-number-owned->i64)
  (value json-number->i64)
  (value json-number-decimal-f64-result)
  (value json-number->f64)
  (value json-number->f32)
  (value json-f64->number-text)
  (value json-f32->number-text)
  (value json-parse-keyword)
  (value json-parse-array)
  (value json-parse-object)
  (value json-parse-value)
  (value json-parse)
  (type Json)
  (type JsonList)
  (type JsonMemberList)
  (type JsonParseResult)
  (type JsonParseValueResult)
  (type JsonParseStringResult)
  (type JsonParseEscapeResult)
  (type JsonCodepointStringResult)
  (type JsonNumberF64Result)
  (type JsonNumberF32Result)
  (type JsonNumberI64Result)
  (type JsonNumberTextResult)
  (type JsonNumberShapeResult)
  (type JsonLookup)
  (variant JsonNull)
  (variant JsonBool)
  (variant JsonNumber)
  (variant JsonString)
  (variant JsonArray)
  (variant JsonObject)
  (variant JsonListNil)
  (variant JsonListCons)
  (variant JsonMemberListNil)
  (variant JsonMemberListCons)
  (variant OkJson)
  (variant ErrJson)
  (variant OkJsonParseValue)
  (variant ErrJsonParseValue)
  (variant OkJsonParseString)
  (variant ErrJsonParseString)
  (variant OkJsonParseEscape)
  (variant ErrJsonParseEscape)
  (variant OkJsonCodepointString)
  (variant ErrJsonCodepointString)
  (variant OkJsonNumberF64)
  (variant ErrJsonNumberF64)
  (variant OkJsonNumberF32)
  (variant ErrJsonNumberF32)
  (variant OkJsonNumberI64)
  (variant ErrJsonNumberI64)
  (variant OkJsonNumberText)
  (variant ErrJsonNumberText)
  (variant OkJsonNumberShape)
  (variant ErrJsonNumberShape)
  (variant JsonFound)
  (variant JsonMissing))