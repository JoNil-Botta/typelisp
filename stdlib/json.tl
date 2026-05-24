;;;; JSON parser and serializer for TypeLisp.

;;;;

;;;; Provides a canonical JSON value model, recoverable parser, and serializer

;;;; for tools that need JSON without a private selfhost-only implementation.

;;;;

;;;; Primitives required from the compiler/runtime: `string-length`,

;;;; `string-ref`, `substring`, `string-append`, and `string-eq`.

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

;;; Canonical JSON value model used by the stdlib parser and serializer.

(defenum Json
  (JsonNull)
  (JsonBool bool)
  (JsonNumber String)
  (JsonString String)
  (JsonArray JsonList)
  (JsonObject JsonMemberList))

(defenum JsonList
  (JsonListNil)
  (JsonListCons Json JsonList))

(defenum JsonMemberList
  (JsonMemberListNil)
  (JsonMemberListCons String Json JsonMemberList))

(defenum JsonParseResult
  (OkJson Json)
  (ErrJson String))

(defenum JsonParseValueResult
  (OkJsonParseValue Json i64)
  (ErrJsonParseValue String))

(defenum JsonParseStringResult
  (OkJsonParseString String i64)
  (ErrJsonParseString String))

(defenum JsonParseEscapeResult
  (OkJsonParseEscape String i64)
  (ErrJsonParseEscape String))

(defenum JsonCodepointStringResult
  (OkJsonCodepointString String)
  (ErrJsonCodepointString String))

(defenum JsonLookup
  (JsonFound Json)
  (JsonMissing))

(define json-ascii-printable-table : String
  " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")

(define (json-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (json-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string-append a (string-append b (string-append c d))))

(define (json-char-code [c : char]) : i64
  (cast c : i64))

(define (json-char-code-at [text : String] [idx : i64]) : i64
  (json-char-code (string-ref text idx)))

(define (json-char-code-eq-at [text : String] [idx : i64] [code : i64]) : bool
  (if (< idx (string-length text))
    (= (json-char-code-at text idx) code)
    false))

(define (json-space-code? [code : i64]) : bool
  (or (= code 32) (or (= code 10) (or (= code 13) (= code 9)))))

(define (json-digit-code? [code : i64]) : bool
  (and (>= code 48) (<= code 57)))

(define (json-digit-at? [text : String] [idx : i64]) : bool
  (if (< idx (string-length text))
    (json-digit-code? (json-char-code-at text idx))
    false))

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

(define (json-list-reverse-onto [items : JsonList] [acc : JsonList]) : JsonList
  (match items
    [(JsonListNil) acc]
    [(JsonListCons head rest)
      (json-list-reverse-onto rest (JsonListCons head acc))]))

(define (json-list-reverse [items : JsonList]) : JsonList
  (json-list-reverse-onto items JsonListNil))

(define (json-member-list-reverse-onto
  [items : JsonMemberList]
  [acc : JsonMemberList]) : JsonMemberList
  (match items
    [(JsonMemberListNil) acc]
    [(JsonMemberListCons key value rest)
      (json-member-list-reverse-onto rest (JsonMemberListCons key value acc))]))

(define (json-member-list-reverse [items : JsonMemberList]) : JsonMemberList
  (json-member-list-reverse-onto items JsonMemberListNil))

(define (json-list-count [items : JsonList]) : i64
  (match items
    [(JsonListNil) 0]
    [(JsonListCons _ rest) (+ 1 (json-list-count rest))]))

(define (json-member-list-count [items : JsonMemberList]) : i64
  (match items
    [(JsonMemberListNil) 0]
    [(JsonMemberListCons _ _ rest) (+ 1 (json-member-list-count rest))]))

(define (json-member-list-get [items : JsonMemberList] [key : String]) : JsonLookup
  (match items
    [(JsonMemberListNil) JsonMissing]
    [(JsonMemberListCons item-key value rest)
      (if (string-eq item-key key)
        (JsonFound value)
        (json-member-list-get rest key))]))

(define (json-object-get [value : Json] [key : String]) : JsonLookup
  (match value
    [(JsonObject members) (json-member-list-get members key)]
    [_ JsonMissing]))

(define (json-hex-value [c : char]) : i64
  (let ([code : i64 (json-char-code c)])
    (if (and (>= code 48) (<= code 57))
      (- code 48)
      (if (and (>= code 65) (<= code 70))
        (+ 10 (- code 65))
        (if (and (>= code 97) (<= code 102))
          (+ 10 (- code 97))
          -1)))))

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

(define (json-escape-char [code : i64]) : String
  (if (= code 34)
    (string-append "\\" "\"")
    (if (= code 92)
      (string-append "\\" "\\")
      (json-control-escape code))))

(define (json-escape-string [text : String]) : String
  (let (
    [n : i64 (string-length text)]
    [i : i64 0]
    [segment-start : i64 0]
    [out : String ""])
    (begin
      (while (< i n)
        (let ([code : i64 (json-char-code-at text i)])
          (if (or (= code 34) (or (= code 92) (< code 32)))
            (begin
              (set!
                out
                (json-cat3
                  out
                  (substring text segment-start (- i segment-start))
                  (json-escape-char code)))
              (set! i (+ i 1))
              (set! segment-start i))
            (set! i (+ i 1)))))
      (string-append out (substring text segment-start (- n segment-start))))))

(define (json-stringify-list [items : JsonList]) : String
  (match items
    [(JsonListNil) ""]
    [(JsonListCons head rest)
      (match rest
        [(JsonListNil) (json-stringify head)]
        [(JsonListCons _ _)
          (json-cat3 (json-stringify head) "," (json-stringify-list rest))])]))

(define (json-stringify-members [items : JsonMemberList]) : String
  (match items
    [(JsonMemberListNil) ""]
    [(JsonMemberListCons key value rest)
      (let ([item : String
        (json-cat4 "\"" (json-escape-string key) "\":" (json-stringify value))])
        (match rest
          [(JsonMemberListNil) item]
          [(JsonMemberListCons _ _ _)
            (json-cat3 item "," (json-stringify-members rest))]))]))

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

(define (json-parse-string [text : String] [pos : i64]) : JsonParseStringResult
  (if (not (json-char-code-eq-at text pos 34))
    (ErrJsonParseString "json: expected string")
    (let (
      [n : i64 (string-length text)]
      [i : i64 (+ pos 1)]
      [segment-start : i64 (+ pos 1)]
      [out : String ""]
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
                    (string-append
                      out
                      (substring text segment-start (- i segment-start))))
                  (set! i (+ i 1))
                  (set! done true))
                (if (= code 92)
                  (begin
                    (set!
                      out
                      (string-append
                        out
                        (substring text segment-start (- i segment-start))))
                    (match (json-parse-escape text (+ i 1))
                      [(OkJsonParseEscape decoded next)
                        (begin
                          (set! out (string-append out decoded))
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
          (OkJsonParseString out i)
          (ErrJsonParseString message))))))

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

(define (json-parse-keyword
  [text : String]
  [pos : i64]
  [keyword : String]
  [value : Json]) : JsonParseValueResult
  (if (json-string-prefix-at? text keyword pos)
    (OkJsonParseValue value (+ pos (string-length keyword)))
    (ErrJsonParseValue "json: expected keyword")))

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

(define (json-parse [text : String]) : JsonParseResult
  (match (json-parse-value text 0)
    [(OkJsonParseValue value pos)
      (let ([end : i64 (json-skip-ws text pos)])
        (if (= end (string-length text))
          (OkJson value)
          (ErrJson "json: trailing characters after JSON value")))]
    [(ErrJsonParseValue message) (ErrJson message)]))