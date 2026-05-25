;;;; JSON parser and serializer for TypeLisp.
;;;;
;;;; Provides a canonical JSON value model, recoverable parser, and serializer
;;;; for tools that need JSON without a private selfhost-only implementation.
;;;;
;;;; Primitives required from the compiler/runtime: `string-length`,
;;;; `string-ref`, `substring`, `string-append`, `string-eq`, and the imported
;;;; sibling `text_buf.tl` buffer helpers.
;;;;
;;;; Usage: `(import "stdlib/json.tl")`
;;;;
;;;; Parsed values, list nodes, decoded strings, and serialized strings are
;;;; ordinary TypeLisp heap values. They are allocated in the active arena once
;;;; scoped arenas are enabled, and in the default program-lifetime arena today.
;;;;
;;;; ```typelisp
;;;; (import "stdlib/json.tl")
;;;; (define sample : String (json-stringify (JsonBool true)))
;;;; ```
(import "text_buf.tl")

;;; Canonical JSON value model used by the stdlib parser and serializer.
(defenum Json
  (JsonNull)
  (JsonBool bool)
  (JsonNumber String)
  (JsonString String)
  (JsonArray JsonList)
  (JsonObject JsonMemberList))

;;; Immutable list of JSON array elements in source order.
(defenum JsonList
  (JsonListNil)
  (JsonListCons Json JsonList))

;;; Immutable list of JSON object members in source order.
(defenum JsonMemberList
  (JsonMemberListNil)
  (JsonMemberListCons String Json JsonMemberList))

;;; Recoverable top-level parse result.
(defenum JsonParseResult
  (OkJson Json)
  (ErrJson String))

;;; Internal value parser result carrying the parsed value and next offset.
(defenum JsonParseValueResult
  (OkJsonParseValue Json i64)
  (ErrJsonParseValue String))

;;; Internal string parser result carrying the decoded string and next offset.
(defenum JsonParseStringResult
  (OkJsonParseString String i64)
  (ErrJsonParseString String))

;;; Internal escape parser result carrying the decoded string and next offset.
(defenum JsonParseEscapeResult
  (OkJsonParseEscape String i64)
  (ErrJsonParseEscape String))

;;; Result for decoding a supported JSON Unicode codepoint into a String.
(defenum JsonCodepointStringResult
  (OkJsonCodepointString String)
  (ErrJsonCodepointString String))

;;; Object lookup result that distinguishes missing keys from JSON null values.
(defenum JsonLookup
  (JsonFound Json)
  (JsonMissing))

;;; ASCII printable lookup table used to materialize supported codepoints.
(define json-ascii-printable-table : String
  " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")

;;; Concatenate three strings, allocating the joined result in the active arena.
(define (json-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

;;; Concatenate four strings, allocating the joined result in the active arena.
(define (json-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string-append a (string-append b (string-append c d))))

;;; Return the numeric scalar code for `c`.
(define (json-char-code [c : char]) : i64
  (cast c : i64))

;;; Return the numeric scalar code at `idx` in `text`.
(define (json-char-code-at [text : String] [idx : i64]) : i64
  (json-char-code (string-ref text idx)))

;;; Return true when `text[idx]` exists and has the supplied code.
(define (json-char-code-eq-at [text : String] [idx : i64] [code : i64]) : bool
  (if (< idx (string-length text))
    (= (json-char-code-at text idx) code)
    false))

;;; Return true for JSON whitespace scalar codes.
(define (json-space-code? [code : i64]) : bool
  (or (= code 32) (or (= code 10) (or (= code 13) (= code 9)))))

;;; Return true for ASCII decimal digit scalar codes.
(define (json-digit-code? [code : i64]) : bool
  (and (>= code 48) (<= code 57)))

;;; Return true when `text[idx]` exists and is an ASCII decimal digit.
(define (json-digit-at? [text : String] [idx : i64]) : bool
  (if (< idx (string-length text))
    (json-digit-code? (json-char-code-at text idx))
    false))

;;; Return the first offset at or after `pos` that is not JSON whitespace.
(define (json-skip-ws [text : String] [pos : i64]) : i64
  (let (
    [i : i64 pos]
    [n : i64 (string-length text)]
    [done : bool false])
    (begin
      (while (not done)
        (if (< i n)
          (if (json-space-code? (json-char-code-at text i))
            (set! i (+ i 1))
            (set! done true))
          (set! done true)))
      i)))

;;; Return true when `prefix` occurs in `text` at `start`.
(define (json-string-prefix-at? [text : String] [prefix : String] [start : i64]) : bool
  (let (
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)])
    (if (> (+ start prefix-len) text-len)
      false
      (let (
        [i : i64 0]
        [ok : bool true])
        (begin
          (while (and ok (< i prefix-len))
            (if (=
              (json-char-code-at text (+ start i))
              (json-char-code-at prefix i))
              (set! i (+ i 1))
              (set! ok false)))
          ok)))))

;;; Reverse `items` onto `acc`, allocating a fresh active-arena list spine.
(define (json-list-reverse-onto [items : JsonList] [acc : JsonList]) : JsonList
  (match items
    [(JsonListNil) acc]
    [(JsonListCons head rest)
      (json-list-reverse-onto rest (JsonListCons head acc))]))

;;; Return `items` in reverse order.
(define (json-list-reverse [items : JsonList]) : JsonList
  (json-list-reverse-onto items JsonListNil))

;;; Reverse object `items` onto `acc`, allocating a fresh active-arena list spine.
(define (json-member-list-reverse-onto
  [items : JsonMemberList]
  [acc : JsonMemberList]) : JsonMemberList
  (match items
    [(JsonMemberListNil) acc]
    [(JsonMemberListCons key value rest)
      (json-member-list-reverse-onto rest (JsonMemberListCons key value acc))]))

;;; Return object `items` in reverse order.
(define (json-member-list-reverse [items : JsonMemberList]) : JsonMemberList
  (json-member-list-reverse-onto items JsonMemberListNil))

;;; Return the number of elements in a JSON array list.
(define (json-list-count [items : JsonList]) : i64
  (match items
    [(JsonListNil) 0]
    [(JsonListCons _ rest) (+ 1 (json-list-count rest))]))

;;; Return the number of key/value entries in a JSON object member list.
(define (json-member-list-count [items : JsonMemberList]) : i64
  (match items
    [(JsonMemberListNil) 0]
    [(JsonMemberListCons _ _ rest) (+ 1 (json-member-list-count rest))]))

;;; Look up `key` in an object member list.
(define (json-member-list-get [items : JsonMemberList] [key : String]) : JsonLookup
  (match items
    [(JsonMemberListNil) JsonMissing]
    [(JsonMemberListCons item-key value rest)
      (if (string-eq item-key key)
        (JsonFound value)
        (json-member-list-get rest key))]))

;;; Look up `key` in `value` when it is a JSON object.
;;;
;;; Non-object values return `JsonMissing`.
;;;
;;; ```typelisp
;;; (import "stdlib/json.tl")
;;; (define found : JsonLookup
;;;   (json-object-get
;;;     (JsonObject (JsonMemberListCons "name" (JsonString "tl") JsonMemberListNil))
;;;     "name"))
;;; ```
(define (json-object-get [value : Json] [key : String]) : JsonLookup
  (match value
    [(JsonObject members) (json-member-list-get members key)]
    [_ JsonMissing]))

;;; Decode a hexadecimal digit char, or return -1 when it is not a hex digit.
(define (json-hex-value [c : char]) : i64
  (let ([code : i64 (json-char-code c)])
    (if (and (>= code 48) (<= code 57))
      (- code 48)
      (if (and (>= code 65) (<= code 70))
        (+ 10 (- code 65))
        (if (and (>= code 97) (<= code 102))
          (+ 10 (- code 97))
          -1)))))

;;; Encode a value from 0 through 15 as a one-character lowercase hex string.
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

;;; Return the JSON escape spelling for a control scalar code.
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
            (json-cat4
              "\\u00"
              (json-hex-digit (/ code 16))
              (json-hex-digit (- code (* (/ code 16) 16)))
              "")))))))

;;; Return the JSON escape spelling for one string scalar code.
(define (json-escape-char [code : i64]) : String
  (if (= code 34)
    (string-append "\\" "\"")
    (if (= code 92)
      (string-append "\\" "\\")
      (json-control-escape code))))

;;; Escape a raw string for JSON string output.
;;;
;;; The returned escaped string is allocated in the active arena.
(define (json-escape-string [text : String]) : String
  (let (
    [n : i64 (string-length text)]
    [i : i64 0]
    [segment-start : i64 0]
    [out : TextBuf (text-buf-empty)])
    (begin
      (while (< i n)
        (let ([code : i64 (json-char-code-at text i)])
          (if (or (= code 34) (or (= code 92) (< code 32)))
            (begin
              (set!
                out
                (text-buf-append
                  (text-buf-append
                    out
                    (substring text segment-start (- i segment-start)))
                  (json-escape-char code)))
              (set! i (+ i 1))
              (set! segment-start i))
            (set! i (+ i 1)))))
      (text-buf-render
        (text-buf-append out (substring text segment-start (- n segment-start)))))))

;;; Append serialized array elements to `buf`.
(define (json-stringify-list-into [items : JsonList] [buf : TextBuf]) : TextBuf
  (match items
    [(JsonListNil) buf]
    [(JsonListCons head rest)
      (let ([with-head : TextBuf (text-buf-append buf (json-stringify head))])
        (match rest
          [(JsonListNil) with-head]
          [(JsonListCons _ _)
            (json-stringify-list-into rest (text-buf-append with-head ","))]))]))

;;; Serialize array `items` without the surrounding brackets.
;;;
;;; The returned comma-separated string is allocated in the active arena.
(define (json-stringify-list [items : JsonList]) : String
  (text-buf-render (json-stringify-list-into items (text-buf-empty))))

;;; Append serialized object members to `buf`.
(define (json-stringify-members-into [items : JsonMemberList] [buf : TextBuf]) : TextBuf
  (match items
    [(JsonMemberListNil) buf]
    [(JsonMemberListCons key value rest)
      (let ([with-item : TextBuf
        (text-buf-append
          (text-buf-append
            (text-buf-append
              (text-buf-append buf "\"")
              (json-escape-string key))
            "\":")
          (json-stringify value))])
        (match rest
          [(JsonMemberListNil) with-item]
          [(JsonMemberListCons _ _ _)
            (json-stringify-members-into rest (text-buf-append with-item ","))]))]))

;;; Serialize object `items` without the surrounding braces.
;;;
;;; The returned comma-separated member string is allocated in the active arena.
(define (json-stringify-members [items : JsonMemberList]) : String
  (text-buf-render (json-stringify-members-into items (text-buf-empty))))

;;; Serialize a JSON value to canonical compact JSON text.
;;;
;;; The returned string is allocated in the active arena.
;;;
;;; ```typelisp
;;; (import "stdlib/json.tl")
;;; (define encoded : String
;;;   (json-stringify (JsonArray (JsonListCons (JsonBool true) JsonListNil))))
;;; ```
(define (json-stringify [value : Json]) : String
  (match value
    [(JsonNull) "null"]
    [(JsonBool b)
      (if b
        "true"
        "false")]
    [(JsonNumber text) text]
    [(JsonString text) (json-cat3 "\"" (json-escape-string text) "\"")]
    [(JsonArray items) (json-cat3 "[" (json-stringify-list items) "]")]
    [(JsonObject members) (json-cat3 "{" (json-stringify-members members) "}")]))

;;; Convert a supported Unicode scalar codepoint into a TypeLisp String.
;;;
;;; Only tab, newline, carriage return, and printable ASCII are supported today.
;;; Successful decoded strings allocate in the active arena.
(define (json-codepoint-string [code : i64]) : JsonCodepointStringResult
  (if (= code 9)
    (OkJsonCodepointString "\t")
    (if (= code 10)
      (OkJsonCodepointString "\n")
      (if (= code 13)
        (OkJsonCodepointString "\r")
        (if (and (>= code 32) (<= code 126))
          (OkJsonCodepointString
            (substring json-ascii-printable-table (- code 32) 1))
          (ErrJsonCodepointString
            "json: unicode escape outside supported string range"))))))

;;; Parse four hex digits after a `\u` escape and return the decoded string.
(define (json-parse-unicode-escape [text : String] [pos : i64]) : JsonParseEscapeResult
  (let ([n : i64 (string-length text)])
    (if (> (+ pos 4) n)
      (ErrJsonParseEscape "json: unterminated unicode escape")
      (let (
        [j : i64 0]
        [value : i64 0]
        [ok : bool true]
        [message : String ""])
        (begin
          (while (and ok (< j 4))
            (let ([digit : i64 (json-hex-value (string-ref text (+ pos j)))])
              (if (< digit 0)
                (begin
                  (set! ok false)
                  (set! message "json: invalid unicode escape digit"))
                (begin
                  (set! value (+ (* value 16) digit))
                  (set! j (+ j 1))))))
          (if ok
            (match (json-codepoint-string value)
              [(OkJsonCodepointString decoded)
                (OkJsonParseEscape decoded (+ pos 4))]
              [(ErrJsonCodepointString err) (ErrJsonParseEscape err)])
            (ErrJsonParseEscape message)))))))

;;; Parse a JSON string escape at `pos`.
;;;
;;; Successful decoded strings allocate in the active arena.
(define (json-parse-escape [text : String] [pos : i64]) : JsonParseEscapeResult
  (if (>= pos (string-length text))
    (ErrJsonParseEscape "json: unterminated JSON escape")
    (let ([code : i64 (json-char-code-at text pos)])
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
                    (json-parse-unicode-escape text (+ pos 1))
                    (ErrJsonParseEscape "json: unsupported JSON string escape")))))))))))

;;; Parse a JSON string starting at `pos`, including the opening quote.
;;;
;;; The decoded string is allocated in the active arena.
(define (json-parse-string [text : String] [pos : i64]) : JsonParseStringResult
  (if (not (json-char-code-eq-at text pos 34))
    (ErrJsonParseString "json: expected string")
    (let (
      [n : i64 (string-length text)]
      [i : i64 (+ pos 1)]
      [segment-start : i64 (+ pos 1)]
      [out : TextBuf (text-buf-empty)]
      [ok : bool true]
      [done : bool false]
      [message : String ""])
      (begin
        (while (and ok (not done))
          (if (>= i n)
            (begin
              (set! ok false)
              (set! done true)
              (set! message "json: unterminated string"))
            (let ([code : i64 (json-char-code-at text i)])
              (if (= code 34)
                (begin
                  (set!
                    out
                    (text-buf-append
                      out
                      (substring text segment-start (- i segment-start))))
                  (set! i (+ i 1))
                  (set! done true))
                (if (= code 92)
                  (begin
                    (set!
                      out
                      (text-buf-append
                        out
                        (substring text segment-start (- i segment-start))))
                    (match (json-parse-escape text (+ i 1))
                      [(OkJsonParseEscape decoded next)
                        (begin
                          (set! out (text-buf-append out decoded))
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
          (OkJsonParseString (text-buf-render out) i)
          (ErrJsonParseString message))))))

;;; Return the first offset at or after `pos` that is not an ASCII digit.
(define (json-consume-digits [text : String] [pos : i64]) : i64
  (let (
    [i : i64 pos]
    [done : bool false])
    (begin
      (while (not done)
        (if (json-digit-at? text i)
          (set! i (+ i 1))
          (set! done true)))
      i)))

;;; Parse a JSON number starting at `pos`.
;;;
;;; The numeric spelling is kept as a String allocated in the active arena.
(define (json-parse-number [text : String] [pos : i64]) : JsonParseValueResult
  (let (
    [n : i64 (string-length text)]
    [i : i64 pos]
    [ok : bool true]
    [message : String ""])
    (begin
      (if (json-char-code-eq-at text i 45)
        (set! i (+ i 1))
        unit)
      (if (>= i n)
        (begin
          (set! ok false)
          (set! message "json: expected digit in number"))
        unit)
      (if ok
        (if (json-char-code-eq-at text i 48)
          (begin
            (set! i (+ i 1))
            (if (json-digit-at? text i)
              (begin
                (set! ok false)
                (set! message "json: leading zero in number"))
              unit))
          (if (json-digit-at? text i)
            (set! i (json-consume-digits text i))
            (begin
              (set! ok false)
              (set! message "json: expected digit in number"))))
        unit)
      (if ok
        (if (json-char-code-eq-at text i 46)
          (begin
            (set! i (+ i 1))
            (if (json-digit-at? text i)
              (set! i (json-consume-digits text i))
              (begin
                (set! ok false)
                (set! message "json: expected digit after decimal point"))))
          unit)
        unit)
      (if ok
        (if (or
          (json-char-code-eq-at text i 101)
          (json-char-code-eq-at text i 69))
          (begin
            (set! i (+ i 1))
            (if (or
              (json-char-code-eq-at text i 43)
              (json-char-code-eq-at text i 45))
              (set! i (+ i 1))
              unit)
            (if (json-digit-at? text i)
              (set! i (json-consume-digits text i))
              (begin
                (set! ok false)
                (set! message "json: expected digit in exponent"))))
          unit)
        unit)
      (if ok
        (OkJsonParseValue (JsonNumber (substring text pos (- i pos))) i)
        (ErrJsonParseValue message)))))

;;; Parse `keyword` at `pos` and return its fixed JSON value.
(define (json-parse-keyword
  [text : String]
  [pos : i64]
  [keyword : String]
  [value : Json]) : JsonParseValueResult
  (if (json-string-prefix-at? text keyword pos)
    (OkJsonParseValue value (+ pos (string-length keyword)))
    (ErrJsonParseValue "json: expected keyword")))

;;; Parse a JSON array starting at `pos`, including the opening bracket.
;;;
;;; The returned array list and nested values are allocated in the active arena.
(define (json-parse-array [text : String] [pos : i64]) : JsonParseValueResult
  (let (
    [i : i64 (json-skip-ws text (+ pos 1))]
    [items : JsonList JsonListNil]
    [ok : bool true]
    [done : bool false]
    [message : String ""])
    (begin
      (if (json-char-code-eq-at text i 93)
        (begin
          (set! i (+ i 1))
          (set! done true))
        unit)
      (while (and ok (not done))
        (match (json-parse-value text i)
          [(OkJsonParseValue value next)
            (begin
              (set! items (JsonListCons value items))
              (set! i (json-skip-ws text next))
              (if (json-char-code-eq-at text i 93)
                (begin
                  (set! i (+ i 1))
                  (set! done true))
                (if (json-char-code-eq-at text i 44)
                  (set! i (json-skip-ws text (+ i 1)))
                  (begin
                    (set! ok false)
                    (set! message "json: expected ',' or ']' in array")))))]
          [(ErrJsonParseValue err)
            (begin
              (set! ok false)
              (set! message err))]))
      (if ok
        (OkJsonParseValue (JsonArray (json-list-reverse items)) i)
        (ErrJsonParseValue message)))))

;;; Parse a JSON object starting at `pos`, including the opening brace.
;;;
;;; The returned member list, keys, and nested values allocate in the active arena.
(define (json-parse-object [text : String] [pos : i64]) : JsonParseValueResult
  (let (
    [i : i64 (json-skip-ws text (+ pos 1))]
    [members : JsonMemberList JsonMemberListNil]
    [ok : bool true]
    [done : bool false]
    [message : String ""])
    (begin
      (if (json-char-code-eq-at text i 125)
        (begin
          (set! i (+ i 1))
          (set! done true))
        unit)
      (while (and ok (not done))
        (match (json-parse-string text i)
          [(OkJsonParseString key after-key)
            (let ([colon-pos : i64 (json-skip-ws text after-key)])
              (if (json-char-code-eq-at text colon-pos 58)
                (match (json-parse-value text (+ colon-pos 1))
                  [(OkJsonParseValue value next)
                    (begin
                      (set! members (JsonMemberListCons key value members))
                      (set! i (json-skip-ws text next))
                      (if (json-char-code-eq-at text i 125)
                        (begin
                          (set! i (+ i 1))
                          (set! done true))
                        (if (json-char-code-eq-at text i 44)
                          (set! i (json-skip-ws text (+ i 1)))
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
        (OkJsonParseValue (JsonObject (json-member-list-reverse members)) i)
        (ErrJsonParseValue message)))))

;;; Parse one JSON value from `text` at `pos`, after skipping whitespace.
;;;
;;; Returned aggregate, string, and number values allocate in the active arena.
(define (json-parse-value [text : String] [pos : i64]) : JsonParseValueResult
  (let (
    [i : i64 (json-skip-ws text pos)]
    [n : i64 (string-length text)])
    (if (>= i n)
      (ErrJsonParseValue "json: expected JSON value")
      (let ([code : i64 (json-char-code-at text i)])
        (if (= code 110)
          (json-parse-keyword text i "null" JsonNull)
          (if (= code 116)
            (json-parse-keyword text i "true" (JsonBool true))
            (if (= code 102)
              (json-parse-keyword text i "false" (JsonBool false))
              (if (= code 34)
                (match (json-parse-string text i)
                  [(OkJsonParseString value next)
                    (OkJsonParseValue (JsonString value) next)]
                  [(ErrJsonParseString err) (ErrJsonParseValue err)])
                (if (= code 91)
                  (json-parse-array text i)
                  (if (= code 123)
                    (json-parse-object text i)
                    (if (or (= code 45) (json-digit-code? code))
                      (json-parse-number text i)
                      (ErrJsonParseValue
                        "json: unexpected character while parsing value"))))))))))))

;;; Parse an entire JSON document with recoverable errors.
;;;
;;; Successful values and decoded strings allocate in the active arena.
;;;
;;; ```typelisp
;;; (import "stdlib/json.tl")
;;; (define parsed : JsonParseResult (json-parse "{\"ok\":true}"))
;;; ```
(define (json-parse [text : String]) : JsonParseResult
  (match (json-parse-value text 0)
    [(OkJsonParseValue value pos)
      (let ([end : i64 (json-skip-ws text pos)])
        (if (= end (string-length text))
          (OkJson value)
          (ErrJson "json: trailing characters after JSON value")))]
    [(ErrJsonParseValue message) (ErrJson message)]))