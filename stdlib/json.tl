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

(import stdlib.string)
(import stdlib.io)
(import stdlib.text_buf)

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

;: Internal parser-builder object member stored in `JsonMemberVec`.
(defstruct JsonMember
  (key String)
  (value Json))

;: Internal vector-backed parser builder for JSON array elements.
(comptime-decl
  (:generated vector-family JsonVec "Json")
  (defstruct JsonVec
    (slots (Array Json))
    (len i64)))

;: Return the backing slots for an internal JSON element builder.
(comptime-decl
  (:generated vector-family json-vec-slots "Json")
  (define (json-vec-slots [v : JsonVec]) : (Array Json)
    (struct-get v slots)))

;: Return the number of live elements in an internal JSON element builder.
(comptime-decl
  (:generated vector-family json-vec-len "Json")
  (define (json-vec-len [v : JsonVec]) : i64
    (struct-get v len)))

;: Return the backing-slot count for an internal JSON element builder.
(comptime-decl
  (:generated vector-family json-vec-capacity "Json")
  (define (json-vec-capacity [v : JsonVec]) : i64
    (array-length (struct-get v slots))))

;: Create an empty internal JSON element builder with `capacity` slots.
(comptime-decl
  (:generated vector-family json-vec-with-capacity "Json")
  (define (json-vec-with-capacity [capacity : i64]) : JsonVec
    (let
      [cap : i64
        (if (< capacity 0)
          0
          capacity)]
      (JsonVec (make-array Json cap) 0))))

;: Create an empty internal JSON element builder.
(comptime-decl
  (:generated vector-family json-vec-new "Json")
  (define (json-vec-new) : JsonVec
    (json-vec-with-capacity 4)))

;: Copy live JSON elements from `src` into `dst` over `[index, count)`.
(comptime-decl
  (:generated vector-family json-vec-copy-range "Json")
  (define (json-vec-copy-range
    [dst : (Array Json)]
    [src : (Array Json)]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (array-set! dst index (array-ref src index))
        (json-vec-copy-range dst src (+ index 1) count)))))

;: Grow an internal JSON element builder, preserving its live prefix.
(comptime-decl
  (:generated vector-family json-vec-grow "Json")
  (define (json-vec-grow [v : JsonVec]) : JsonVec
    (let
      [n : i64 (json-vec-len v)]
      [cap : i64 (json-vec-capacity v)]
      [bigger : (Array Json)
        (make-array
          Json
          (if (< cap 1)
            4
            (* cap 2)))]
      (begin
        (json-vec-copy-range bigger (json-vec-slots v) 0 n)
        (set! (struct-get v slots) bigger)
        v))))

;: Append `value` to an internal JSON element builder.
(comptime-decl
  (:generated vector-family json-vec-push "Json")
  (define (json-vec-push [v : JsonVec] [value : Json]) : JsonVec
    (if (< (json-vec-len v) (json-vec-capacity v))
      (let
        [slots : (Array Json) (json-vec-slots v)]
        [index : i64 (json-vec-len v)]
        (begin
          (array-set! slots index value)
          (set! (struct-get v len) (+ index 1))
          v))
      (json-vec-push (json-vec-grow v) value))))

;: Convert builder elements `[0, index]` into a public JSON list.
(define (json-vec-to-list-from [items : JsonVec] [index : i64] [acc : JsonList]) : JsonList
  (if (< index 0)
    acc
    (stdlib.json.json-vec-to-list-from
      items
      (- index 1)
      (JsonListCons
        (array-ref (stdlib.json.json-vec-slots items) index)
        (box acc)))))

;: Convert an internal JSON element builder into the public list model.
(define (json-vec-to-list [items : JsonVec]) : JsonList
  (stdlib.json.json-vec-to-list-from
    items
    (- (stdlib.json.json-vec-len items) 1)
    JsonListNil))

;: Internal vector-backed parser builder for JSON object members.
(comptime-decl
  (:generated vector-family JsonMemberVec "JsonMember")
  (defstruct JsonMemberVec
    (slots (Array JsonMember))
    (len i64)))

;: Return the backing slots for an internal JSON member builder.
(comptime-decl
  (:generated vector-family json-member-vec-slots "JsonMember")
  (define (json-member-vec-slots [v : JsonMemberVec]) : (Array JsonMember)
    (struct-get v slots)))

;: Return the number of live members in an internal JSON member builder.
(comptime-decl
  (:generated vector-family json-member-vec-len "JsonMember")
  (define (json-member-vec-len [v : JsonMemberVec]) : i64
    (struct-get v len)))

;: Return the backing-slot count for an internal JSON member builder.
(comptime-decl
  (:generated vector-family json-member-vec-capacity "JsonMember")
  (define (json-member-vec-capacity [v : JsonMemberVec]) : i64
    (array-length (struct-get v slots))))

;: Create an empty internal JSON member builder with `capacity` slots.
(comptime-decl
  (:generated vector-family json-member-vec-with-capacity "JsonMember")
  (define (json-member-vec-with-capacity [capacity : i64]) : JsonMemberVec
    (let
      [cap : i64
        (if (< capacity 0)
          0
          capacity)]
      (JsonMemberVec (make-array JsonMember cap) 0))))

;: Create an empty internal JSON member builder.
(comptime-decl
  (:generated vector-family json-member-vec-new "JsonMember")
  (define (json-member-vec-new) : JsonMemberVec
    (json-member-vec-with-capacity 4)))

;: Copy live JSON object members from `src` into `dst` over `[index, count)`.
(comptime-decl
  (:generated vector-family json-member-vec-copy-range "JsonMember")
  (define (json-member-vec-copy-range
    [dst : (Array JsonMember)]
    [src : (Array JsonMember)]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (array-set! dst index (array-ref src index))
        (json-member-vec-copy-range dst src (+ index 1) count)))))

;: Grow an internal JSON member builder, preserving its live prefix.
(comptime-decl
  (:generated vector-family json-member-vec-grow "JsonMember")
  (define (json-member-vec-grow [v : JsonMemberVec]) : JsonMemberVec
    (let
      [n : i64 (json-member-vec-len v)]
      [cap : i64 (json-member-vec-capacity v)]
      [bigger : (Array JsonMember)
        (make-array
          JsonMember
          (if (< cap 1)
            4
            (* cap 2)))]
      (begin
        (json-member-vec-copy-range bigger (json-member-vec-slots v) 0 n)
        (set! (struct-get v slots) bigger)
        v))))

;: Append `value` to an internal JSON member builder.
(comptime-decl
  (:generated vector-family json-member-vec-push "JsonMember")
  (define (json-member-vec-push [v : JsonMemberVec] [value : JsonMember]) : JsonMemberVec
    (if (< (json-member-vec-len v) (json-member-vec-capacity v))
      (let
        [slots : (Array JsonMember) (json-member-vec-slots v)]
        [index : i64 (json-member-vec-len v)]
        (begin
          (array-set! slots index value)
          (set! (struct-get v len) (+ index 1))
          v))
      (json-member-vec-push (json-member-vec-grow v) value))))

;: Convert builder members `[0, index]` into a public JSON member list.
(define (json-member-vec-to-list-from
  [items : JsonMemberVec]
  [index : i64]
  [acc : JsonMemberList]) : JsonMemberList
  (if (< index 0)
    acc
    (let
      [member : JsonMember
        (array-ref (stdlib.json.json-member-vec-slots items) index)]
      (stdlib.json.json-member-vec-to-list-from
        items
        (- index 1)
        (JsonMemberListCons
          (struct-get member key)
          (struct-get member value)
          (box acc))))))

;: Convert an internal JSON member builder into the public list model.
(define (json-member-vec-to-list [items : JsonMemberVec]) : JsonMemberList
  (stdlib.json.json-member-vec-to-list-from
    items
    (- (stdlib.json.json-member-vec-len items) 1)
    JsonMemberListNil))

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

;: Count immediate array elements or object members for parser-builder sizing.
;:
;: This pre-scan ignores strings and nested arrays/objects so commas in nested
;: values do not affect the result. It is intentionally permissive because the
;: real parser still performs validation after the builder is sized.
(define (json-composite-item-count
  [text : (& text str)]
  [pos : i64]
  [close-code : i64]) : i64
  (let
    [first : i64 (stdlib.json.json-skip-ws text (+ pos 1))]
    [n : i64 (string-length text)]
    (if (or
      (>= first n)
      (stdlib.json.json-char-code-eq-at text first close-code))
      0
      (let
        [i : i64 (+ pos 1)]
        [depth : i64 1]
        [count : i64 1]
        [in-string : bool false]
        [escaped : bool false]
        (begin
          (while (and (< i n) (> depth 0))
            (let
              [code : i64 (stdlib.json.json-char-code-at text i)]
              (begin
                (if in-string
                  (cond
                    [escaped (set! escaped false)]
                    [(= code 92) (set! escaped true)]
                    [(= code 34) (set! in-string false)]
                    [else unit])
                  (cond
                    [(= code 34) (set! in-string true)]
                    [(or (= code 91) (= code 123)) (set! depth (+ depth 1))]
                    [(or (= code 93) (= code 125)) (set! depth (- depth 1))]
                    [(and (= code 44) (= depth 1)) (set! count (+ count 1))]
                    [else unit]))
                (set! i (+ i 1)))))
          count)))))

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
  (stdlib.json.json-list-reverse-onto items JsonListNil))

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
  (stdlib.json.json-member-list-reverse-onto items JsonMemberListNil))

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
      (if (string.string-eq-borrowed (& item-key) key)
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
    (cond
      [(and (>= code 48) (<= code 57)) (- code 48)]
      [(and (>= code 65) (<= code 70)) (+ 10 (- code 65))]
      [(and (>= code 97) (<= code 102)) (+ 10 (- code 97))]
      [else -1])))

;: Encode a value from 0 through 15 as a one-character lowercase hex string.
(define (json-hex-digit [value : i64]) : String
  (cond
    [(= value 0) "0"]
    [(= value 1) "1"]
    [(= value 2) "2"]
    [(= value 3) "3"]
    [(= value 4) "4"]
    [(= value 5) "5"]
    [(= value 6) "6"]
    [(= value 7) "7"]
    [(= value 8) "8"]
    [(= value 9) "9"]
    [(= value 10) "a"]
    [(= value 11) "b"]
    [(= value 12) "c"]
    [(= value 13) "d"]
    [(= value 14) "e"]
    [else "f"]))

;: Return the JSON escape spelling for a control scalar code.
(define (json-control-escape [code : i64]) : String
  (cond
    [(= code 8) "\\b"]
    [(= code 9) "\\t"]
    [(= code 10) "\\n"]
    [(= code 12) "\\f"]
    [(= code 13) "\\r"]
    [else
      (string.string-append
        "\\u00"
        (string.string-append
          (stdlib.json.json-hex-digit (/ code 16))
          (stdlib.json.json-hex-digit (- code (* (/ code 16) 16)))))]))

;: Return the JSON escape spelling for one string scalar code.
(define (json-escape-char [code : i64]) : String
  (if (= code 34)
    (string.string-append "\\" "\"")
    (if (= code 92)
      (string.string-append "\\" "\\")
      (stdlib.json.json-control-escape code))))

;: Escape borrowed raw text for JSON string output.
;:
;: The returned escaped string is allocated in the active arena.
(define (json-escape-string [text : (& text str)]) : String
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [segment-start : i64 0]
    [out : text_buf.TextBuf (text_buf.text-buf-empty)]
    (begin
      (while (< i n)
        (let
          [code : i64 (stdlib.json.json-char-code-at text i)]
          (if (or (= code 34) (= code 92) (< code 32))
            (begin
              (set!
                out
                (text_buf.text-buf-append
                  out
                  (string.substring-borrowed
                    text
                    segment-start
                    (- i segment-start))))
              (set!
                out
                (text_buf.text-buf-append
                  out
                  (stdlib.json.json-escape-char code)))
              (set! i (+ i 1))
              (set! segment-start i))
            (set! i (+ i 1)))))
      (set!
        out
        (text_buf.text-buf-append
          out
          (string.substring-borrowed text segment-start (- n segment-start))))
      (text_buf.text-buf-render out))))

;: Append serialized array elements to `buf`.
(define (json-stringify-list-into [items : JsonList] [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (match items
    [(JsonListNil) buf]
    [(JsonListCons head rest)
      (let
        [with-head : text_buf.TextBuf
          (text_buf.text-buf-append buf (stdlib.json.json-stringify head))]
        (match (box-get rest)
          [(JsonListNil) with-head]
          [(JsonListCons _ _)
            (stdlib.json.json-stringify-list-into
              (box-get rest)
              (text_buf.text-buf-append with-head ","))]))]))

;: Serialize array `items` without the surrounding brackets.
;:
;: The returned comma-separated string is allocated in the active arena.
(define (json-stringify-list [items : JsonList]) : String
  (text_buf.text-buf-render
    (stdlib.json.json-stringify-list-into items (text_buf.text-buf-empty))))

;: Append serialized object members to `buf`.
(define (json-stringify-members-into
  [items : JsonMemberList]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (match items
    [(JsonMemberListNil) buf]
    [(JsonMemberListCons key value rest)
      (let
        [text : String key]
        [with-item : text_buf.TextBuf
          (text_buf.text-buf-append
            (text_buf.text-buf-append
              (text_buf.text-buf-append
                (text_buf.text-buf-append buf "\"")
                (stdlib.json.json-escape-string (& text)))
              "\":")
            (stdlib.json.json-stringify value))]
        (match (box-get rest)
          [(JsonMemberListNil) with-item]
          [(JsonMemberListCons _ _ _)
            (stdlib.json.json-stringify-members-into
              (box-get rest)
              (text_buf.text-buf-append with-item ","))]))]))

;: Serialize object `items` without the surrounding braces.
;:
;: The returned comma-separated member string is allocated in the active arena.
(define (json-stringify-members [items : JsonMemberList]) : String
  (text_buf.text-buf-render
    (stdlib.json.json-stringify-members-into items (text_buf.text-buf-empty))))

;: Serialize a JSON value to canonical compact JSON text.
;:
;: The returned string is allocated in the active arena.
;:
;: ```typelisp
;: (import stdlib.json)
;: (define encoded : String
;:   (json.json-stringify
;:     (json.JsonArray
;:       (box (json.JsonListCons (json.JsonBool true) (box json.JsonListNil))))))
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
      (string.string-append
        "\""
        (string.string-append (stdlib.json.json-escape-string (& text)) "\""))]
    [(JsonArray items)
      (string.string-append
        "["
        (string.string-append
          (stdlib.json.json-stringify-list (box-get items))
          "]"))]
    [(JsonObject members)
      (string.string-append
        "{"
        (string.string-append
          (stdlib.json.json-stringify-members (box-get members))
          "}"))]))

;: Render an i64 as a JSON number value.
(define (json-i64->number [value : i64]) : Json
  (JsonNumber (string.int->string value)))

;: Convert a supported Unicode scalar codepoint into a TypeLisp String.
;:
;: Only tab, newline, carriage return, and printable ASCII are supported today.
;: Successful decoded strings allocate in the active arena.
(define (json-codepoint-string [code : i64]) : JsonCodepointStringResult
  (cond
    [(= code 9) (OkJsonCodepointString "\t")]
    [(= code 10) (OkJsonCodepointString "\n")]
    [(= code 13) (OkJsonCodepointString "\r")]
    [(and (>= code 32) (<= code 126))
      (OkJsonCodepointString
        (string.substring stdlib.json.json-ascii-printable-table (- code 32) 1))]
    [else
      (ErrJsonCodepointString
        "json: unicode escape outside supported string range")]))

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
      (cond
        [(= code 34) (OkJsonParseEscape "\"" (+ pos 1))]
        [(= code 92) (OkJsonParseEscape "\\" (+ pos 1))]
        [(= code 47) (OkJsonParseEscape "/" (+ pos 1))]
        [(= code 110) (OkJsonParseEscape "\n" (+ pos 1))]
        [(= code 114) (OkJsonParseEscape "\r" (+ pos 1))]
        [(= code 116) (OkJsonParseEscape "\t" (+ pos 1))]
        [(= code 117) (stdlib.json.json-parse-unicode-escape text (+ pos 1))]
        [else (ErrJsonParseEscape "json: unsupported JSON string escape")]))))

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
      [out : text_buf.TextBuf (text_buf.text-buf-empty)]
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
              (cond
                [(= code 34)
                  (begin
                    (set!
                      out
                      (text_buf.text-buf-append
                        out
                        (string.substring-borrowed
                          text
                          segment-start
                          (- i segment-start))))
                    (set! i (+ i 1))
                    (set! done true))]
                [(= code 92)
                  (begin
                    (set!
                      out
                      (text_buf.text-buf-append
                        out
                        (string.substring-borrowed
                          text
                          segment-start
                          (- i segment-start))))
                    (match (stdlib.json.json-parse-escape text (+ i 1))
                      [(OkJsonParseEscape decoded next)
                        (begin
                          (set! out (text_buf.text-buf-append out decoded))
                          (set! i next)
                          (set! segment-start next))]
                      [(ErrJsonParseEscape err)
                        (begin
                          (set! ok false)
                          (set! done true)
                          (set! message err))]))]
                [(< code 32)
                  (begin
                    (set! ok false)
                    (set! done true)
                    (set! message "json: control character in string"))]
                [else (set! i (+ i 1))]))))
        (if ok
          (OkJsonParseString (text_buf.text-buf-render out) i)
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
          (JsonNumber (string.substring-borrowed text pos (- i pos)))
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
        (if (= (string-ref text 0) '-')
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
        (if (and (< index n) (= (string-ref text index) '.'))
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
            (if (and (< index n) (= (string-ref text index) '-'))
              (begin
                (set! exp-negative true)
                (set! index (+ index 1)))
              (if (and (< index n) (= (string-ref text index) '+'))
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
          (OkJsonNumberText (string.substring-borrowed text 0 n))
          (ErrJsonNumberText "json: trailing characters after number"))]
      [(ErrJsonParseValue message) (ErrJsonNumberText message)])))

;: Return true when validated JSON number text is an integer spelling.
(define (json-number-integer-text? [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    (begin
      (when (and (> n 0) (= (string-ref text 0) '-')) (set! i 1))
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
      (and (> (string-length text) 0) (= (string-ref text 0) '-'))]
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
      (OkJsonNumberI64 (string.string->int owned)))))

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
    (cond
      [(> significant-digits stdlib.json.json-number-max-significant-digits)
        (ErrJsonNumberF64 "json: number has too many significant digits")]
      [(and nonzero (> adjusted-exp 308))
        (ErrJsonNumberF64 "json: number outside finite f64 range")]
      [(and nonzero (< adjusted-exp -324))
        (ErrJsonNumberF64 "json: number underflows f64")]
      [else
        (match (io.io-float-parse-f64 owned)
          [(io.IoFloatSomeF64 value)
            (if (and nonzero (io.io-float-f64-zero-magnitude? value))
              (ErrJsonNumberF64 "json: number underflows f64")
              (OkJsonNumberF64 value))]
          [(io.IoFloatNoF64)
            (ErrJsonNumberF64 "json: number outside finite f64 range")])])))

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
        (if (not (io.io-float-f32-finite? narrow))
          (ErrJsonNumberF32 "json: number outside finite f32 range")
          (if (and
            (io.io-float-f32-zero-magnitude? narrow)
            (not (io.io-float-f64-zero-magnitude? wide)))
            (ErrJsonNumberF32 "json: number underflows f32")
            (OkJsonNumberF32 narrow))))]
    [(ErrJsonNumberF64 message) (ErrJsonNumberF32 message)]))

;: Render a finite f64 as deterministic JSON number text.
;:
;: NaN and infinity are rejected; negative zero renders as `-0`.
(define (json-f64->number-text [value : f64]) : JsonNumberTextResult
  (if (io.io-float-f64-finite? value)
    (OkJsonNumberText (io.io-format-float-core value))
    (ErrJsonNumberText "json: non-finite f64 cannot be rendered as a number")))

;: Render a finite f32 as deterministic JSON number text.
;:
;: Widens to f64 so the binary32-rounded value is formatted deterministically.
(define (json-f32->number-text [value : f32]) : JsonNumberTextResult
  (if (io.io-float-f32-finite? value)
    (OkJsonNumberText (io.io-format-float-core (cast value : f64)))
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
;: Parser elements are accumulated in a vector builder, then converted once to
;: the public list model in source order.
(define (json-parse-array [text : (& text str)] [pos : i64]) : JsonParseValueResult
  (let
    [i : i64 (stdlib.json.json-skip-ws text (+ pos 1))]
    [items : JsonVec
      (stdlib.json.json-vec-with-capacity
        (stdlib.json.json-composite-item-count text pos 93))]
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
              (set! items (stdlib.json.json-vec-push items value))
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
          (JsonArray (box (stdlib.json.json-vec-to-list items)))
          i)
        (ErrJsonParseValue message)))))

;: Parse a JSON object starting at `pos`, including the opening brace.
;:
;: Parser members are accumulated in a vector builder, then converted once to
;: the public list model in source order.
(define (json-parse-object [text : (& text str)] [pos : i64]) : JsonParseValueResult
  (let
    [i : i64 (stdlib.json.json-skip-ws text (+ pos 1))]
    [members : JsonMemberVec
      (stdlib.json.json-member-vec-with-capacity
        (stdlib.json.json-composite-item-count text pos 125))]
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
                        (stdlib.json.json-member-vec-push
                          members
                          (JsonMember key value)))
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
          (JsonObject (box (stdlib.json.json-member-vec-to-list members)))
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
        (cond
          [(= code 110) (stdlib.json.json-parse-keyword text i "null" JsonNull)]
          [(= code 116)
            (stdlib.json.json-parse-keyword text i "true" (JsonBool true))]
          [(= code 102)
            (stdlib.json.json-parse-keyword text i "false" (JsonBool false))]
          [(= code 34)
            (match (stdlib.json.json-parse-string text i)
              [(OkJsonParseString value next)
                (OkJsonParseValue (JsonString value) next)]
              [(ErrJsonParseString err) (ErrJsonParseValue err)])]
          [(= code 91) (stdlib.json.json-parse-array text i)]
          [(= code 123) (stdlib.json.json-parse-object text i)]
          [(or (= code 45) (stdlib.json.json-digit-code? code))
            (stdlib.json.json-parse-number text i)]
          [else
            (ErrJsonParseValue "json: unexpected character while parsing value")])))))

;: Parse an entire JSON document with recoverable errors.
;:
;: Successful values and decoded strings allocate in the active arena.
;:
;: ```typelisp
;: (import stdlib.json)
;: (define parsed : json.JsonParseResult
;:   (let
;:     [text : String "{\"ok\":true}"]
;:     (json.json-parse (& text))))
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

;: Inline test assertion for boolean predicates.
(define (json-stdlib-inline-test-assert-true
  [condition : bool]
  [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

;: Inline test assertion for false predicates.
(define (json-stdlib-inline-test-assert-false
  [condition : bool]
  [message : String]) : unit
  (stdlib.json.json-stdlib-inline-test-assert-true (not condition) message))

;: Inline test assertion for `bool` equality.
(define (json-stdlib-inline-test-assert-bool-eq
  [actual : bool]
  [expected : bool]
  [message : String]) : unit
  (stdlib.json.json-stdlib-inline-test-assert-true (= actual expected) message))

;: Inline test assertion for `i64` equality.
(define (json-stdlib-inline-test-assert-i64-eq
  [actual : i64]
  [expected : i64]
  [message : String]) : unit
  (stdlib.json.json-stdlib-inline-test-assert-true (= actual expected) message))

;: Inline test assertion for `f64` equality.
(define (json-stdlib-inline-test-assert-f64-eq
  [actual : f64]
  [expected : f64]
  [message : String]) : unit
  (stdlib.json.json-stdlib-inline-test-assert-true (= actual expected) message))

;: Inline test assertion for owned string equality.
(define (json-stdlib-inline-test-assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (stdlib.json.json-stdlib-inline-test-assert-true
    (string.string-eq actual expected)
    message))

;: Assert that a lookup found the expected JSON number text.
(define (json-stdlib-inline-test-assert-found-number
  [lookup : JsonLookup]
  [expected : String]
  [message : String]) : unit
  (match lookup
    [(JsonFound value)
      (match value
        [(JsonNumber text)
          (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
            text
            expected
            message)]
        [_ (io.panic message)])]
    [(JsonMissing) (io.panic message)]))

;: Assert that a lookup is missing.
(define (json-stdlib-inline-test-assert-missing
  [lookup : JsonLookup]
  [message : String]) : unit
  (match lookup
    [(JsonMissing) unit]
    [(JsonFound _) (io.panic message)]))

;: Build a JSON list node for inline tests.
(define (json-stdlib-inline-test-list-cons [value : Json] [rest : JsonList]) : JsonList
  (JsonListCons value (box rest)))

;: Build a JSON member-list node for inline tests.
(define (json-stdlib-inline-test-member-cons
  [key : String]
  [value : Json]
  [rest : JsonMemberList]) : JsonMemberList
  (JsonMemberListCons key value (box rest)))

;: Build a JSON array for inline tests.
(define (json-stdlib-inline-test-array [items : JsonList]) : Json
  (JsonArray (box items)))

;: Build a JSON object for inline tests.
(define (json-stdlib-inline-test-object [members : JsonMemberList]) : Json
  (JsonObject (box members)))

;: Assert a successful parsed string and next position.
(define (json-stdlib-inline-test-assert-parse-string
  [result : JsonParseStringResult]
  [expected : String]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseString value pos)
      (begin
        (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
          value
          expected
          message)
        (stdlib.json.json-stdlib-inline-test-assert-i64-eq pos next message))]
    [(ErrJsonParseString _) (io.panic message)]))

;: Assert a successful parsed escape and next position.
(define (json-stdlib-inline-test-assert-parse-escape
  [result : JsonParseEscapeResult]
  [expected : String]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseEscape value pos)
      (begin
        (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
          value
          expected
          message)
        (stdlib.json.json-stdlib-inline-test-assert-i64-eq pos next message))]
    [(ErrJsonParseEscape _) (io.panic message)]))

;: Assert a successful JSON codepoint string.
(define (json-stdlib-inline-test-assert-codepoint
  [result : JsonCodepointStringResult]
  [expected : String]
  [message : String]) : unit
  (match result
    [(OkJsonCodepointString value)
      (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
        value
        expected
        message)]
    [(ErrJsonCodepointString _) (io.panic message)]))

;: Assert a successful JSON number-to-f64 conversion.
(define (json-stdlib-inline-test-assert-json-f64
  [result : JsonNumberF64Result]
  [expected : f64]
  [message : String]) : unit
  (match result
    [(OkJsonNumberF64 value)
      (stdlib.json.json-stdlib-inline-test-assert-f64-eq value expected message)]
    [(ErrJsonNumberF64 _) (io.panic message)]))

;: Assert a successful JSON number-to-f32 conversion as f64.
(define (json-stdlib-inline-test-assert-json-f32-as-f64
  [result : JsonNumberF32Result]
  [expected : f64]
  [message : String]) : unit
  (match result
    [(OkJsonNumberF32 value)
      (stdlib.json.json-stdlib-inline-test-assert-f64-eq
        (cast value : f64)
        expected
        message)]
    [(ErrJsonNumberF32 _) (io.panic message)]))

;: Assert a JSON number-to-f64 conversion error.
(define (json-stdlib-inline-test-assert-json-f64-error
  [result : JsonNumberF64Result]
  [message : String]) : unit
  (match result
    [(ErrJsonNumberF64 _) unit]
    [(OkJsonNumberF64 _) (io.panic message)]))

;: Assert a JSON number-to-f32 conversion error.
(define (json-stdlib-inline-test-assert-json-f32-error
  [result : JsonNumberF32Result]
  [message : String]) : unit
  (match result
    [(ErrJsonNumberF32 _) unit]
    [(OkJsonNumberF32 _) (io.panic message)]))

;: Assert a successful JSON number text rendering.
(define (json-stdlib-inline-test-assert-json-number-text
  [result : JsonNumberTextResult]
  [expected : String]
  [message : String]) : unit
  (match result
    [(OkJsonNumberText text)
      (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
        text
        expected
        message)]
    [(ErrJsonNumberText _) (io.panic message)]))

;: Assert a parsed JSON number and next position.
(define (json-stdlib-inline-test-assert-parse-value-number
  [result : JsonParseValueResult]
  [expected : String]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseValue value pos)
      (match value
        [(JsonNumber text)
          (begin
            (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
              text
              expected
              message)
            (stdlib.json.json-stdlib-inline-test-assert-i64-eq pos next message))]
        [_ (io.panic message)])]
    [(ErrJsonParseValue _) (io.panic message)]))

;: Assert a parsed JSON bool and next position.
(define (json-stdlib-inline-test-assert-parse-value-bool
  [result : JsonParseValueResult]
  [expected : bool]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseValue value pos)
      (match value
        [(JsonBool actual)
          (begin
            (stdlib.json.json-stdlib-inline-test-assert-bool-eq
              actual
              expected
              message)
            (stdlib.json.json-stdlib-inline-test-assert-i64-eq pos next message))]
        [_ (io.panic message)])]
    [(ErrJsonParseValue _) (io.panic message)]))

;: Assert a parsed JSON array element count and next position.
(define (json-stdlib-inline-test-assert-parse-array-count
  [result : JsonParseValueResult]
  [expected-count : i64]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseValue value pos)
      (match value
        [(JsonArray items)
          (begin
            (stdlib.json.json-stdlib-inline-test-assert-i64-eq
              (stdlib.json.json-list-count (box-get items))
              expected-count
              message)
            (stdlib.json.json-stdlib-inline-test-assert-i64-eq pos next message))]
        [_ (io.panic message)])]
    [(ErrJsonParseValue _) (io.panic message)]))

;: Assert a parsed JSON object member count and next position.
(define (json-stdlib-inline-test-assert-parse-object-count
  [result : JsonParseValueResult]
  [expected-count : i64]
  [next : i64]
  [message : String]) : unit
  (match result
    [(OkJsonParseValue value pos)
      (match value
        [(JsonObject members)
          (begin
            (stdlib.json.json-stdlib-inline-test-assert-i64-eq
              (stdlib.json.json-member-list-count (box-get members))
              expected-count
              message)
            (stdlib.json.json-stdlib-inline-test-assert-i64-eq pos next message))]
        [_ (io.panic message)])]
    [(ErrJsonParseValue _) (io.panic message)]))

;: Borrowing wrapper for `json-char-code-at` inline tests.
(define (json-stdlib-inline-test-char-code-at [text : String] [idx : i64]) : i64
  (stdlib.json.json-char-code-at (& text) idx))

;: Borrowing wrapper for `json-char-code-eq-at` inline tests.
(define (json-stdlib-inline-test-char-code-eq-at
  [text : String]
  [idx : i64]
  [code : i64]) : bool
  (stdlib.json.json-char-code-eq-at (& text) idx code))

;: Borrowing wrapper for `json-digit-at?` inline tests.
(define (json-stdlib-inline-test-digit-at? [text : String] [idx : i64]) : bool
  (stdlib.json.json-digit-at? (& text) idx))

;: Borrowing wrapper for `json-skip-ws` inline tests.
(define (json-stdlib-inline-test-skip-ws [text : String] [pos : i64]) : i64
  (stdlib.json.json-skip-ws (& text) pos))

;: Borrowing wrapper for `json-string-prefix-at?` inline tests.
(define (json-stdlib-inline-test-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (stdlib.json.json-string-prefix-at? (& text) (& prefix) start))

;: Borrowing wrapper for `json-member-list-get` inline tests.
(define (json-stdlib-inline-test-member-list-get
  [items : JsonMemberList]
  [key : String]) : JsonLookup
  (stdlib.json.json-member-list-get items (& key)))

;: Borrowing wrapper for `json-object-get` inline tests.
(define (json-stdlib-inline-test-object-get [value : Json] [key : String]) : JsonLookup
  (stdlib.json.json-object-get value (& key)))

;: Borrowing wrapper for `json-escape-string` inline tests.
(define (json-stdlib-inline-test-escape-string [text : String]) : String
  (stdlib.json.json-escape-string (& text)))

;: Borrowing wrapper for `json-parse-unicode-escape` inline tests.
(define (json-stdlib-inline-test-parse-unicode-escape
  [text : String]
  [pos : i64]) : JsonParseEscapeResult
  (stdlib.json.json-parse-unicode-escape (& text) pos))

;: Borrowing wrapper for `json-parse-escape` inline tests.
(define (json-stdlib-inline-test-parse-escape [text : String] [pos : i64]) : JsonParseEscapeResult
  (stdlib.json.json-parse-escape (& text) pos))

;: Borrowing wrapper for `json-parse-string` inline tests.
(define (json-stdlib-inline-test-parse-string [text : String] [pos : i64]) : JsonParseStringResult
  (stdlib.json.json-parse-string (& text) pos))

;: Borrowing wrapper for `json-consume-digits` inline tests.
(define (json-stdlib-inline-test-consume-digits [text : String] [pos : i64]) : i64
  (stdlib.json.json-consume-digits (& text) pos))

;: Borrowing wrapper for `json-parse-number` inline tests.
(define (json-stdlib-inline-test-parse-number [text : String] [pos : i64]) : JsonParseValueResult
  (stdlib.json.json-parse-number (& text) pos))

;: Borrowing wrapper for `json-number->f64` inline tests.
(define (json-stdlib-inline-test-number-f64 [text : String]) : JsonNumberF64Result
  (stdlib.json.json-number->f64 (& text)))

;: Borrowing wrapper for `json-number->f32` inline tests.
(define (json-stdlib-inline-test-number-f32 [text : String]) : JsonNumberF32Result
  (stdlib.json.json-number->f32 (& text)))

;: Borrowing wrapper for `json-parse-keyword` inline tests.
(define (json-stdlib-inline-test-parse-keyword
  [text : String]
  [pos : i64]
  [keyword : String]
  [value : Json]) : JsonParseValueResult
  (stdlib.json.json-parse-keyword (& text) pos keyword value))

;: Borrowing wrapper for `json-parse-array` inline tests.
(define (json-stdlib-inline-test-parse-array [text : String] [pos : i64]) : JsonParseValueResult
  (stdlib.json.json-parse-array (& text) pos))

;: Borrowing wrapper for `json-parse-object` inline tests.
(define (json-stdlib-inline-test-parse-object [text : String] [pos : i64]) : JsonParseValueResult
  (stdlib.json.json-parse-object (& text) pos))

;: Borrowing wrapper for `json-parse-value` inline tests.
(define (json-stdlib-inline-test-parse-value [text : String] [pos : i64]) : JsonParseValueResult
  (stdlib.json.json-parse-value (& text) pos))

;: Assert a parsed document has the expected name member.
(define (json-stdlib-inline-test-name [doc : Json]) : unit
  (let
    [key : String "name"]
    (match (stdlib.json.json-object-get doc (& key))
      [(JsonFound value)
        (match value
          [(JsonString text)
            (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
              text
              "tl"
              "json name lookup")]
          [_ (io.panic "json name lookup")])]
      [(JsonMissing) (io.panic "json name lookup")])))

;: Assert a parsed document has the expected array member.
(define (json-stdlib-inline-test-numbers [doc : Json]) : unit
  (let
    [key : String "items"]
    (match (stdlib.json.json-object-get doc (& key))
      [(JsonFound value)
        (match value
          [(JsonArray items)
            (begin
              (stdlib.json.json-stdlib-inline-test-assert-i64-eq
                (stdlib.json.json-list-count (box-get items))
                5
                "json array count")
              (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
                (stdlib.json.json-stringify-list (box-get items))
                "1,-2.5e3,true,false,null"
                "json array stringify"))]
          [_ (io.panic "json array lookup")])]
      [(JsonMissing) (io.panic "json array lookup")])))

;: Assert a parsed document has the expected nested object member.
(define (json-stdlib-inline-test-nested [doc : Json]) : unit
  (let
    [key : String "nested"]
    (match (stdlib.json.json-object-get doc (& key))
      [(JsonFound value)
        (match value
          [(JsonObject members)
            (begin
              (stdlib.json.json-stdlib-inline-test-assert-i64-eq
                (stdlib.json.json-member-list-count (box-get members))
                2
                "json nested object count")
              (let
                [key : String "ok"]
                (match (stdlib.json.json-member-list-get
                  (box-get members)
                  (& key))
                  [(JsonFound ok-value)
                    (match ok-value
                      [(JsonBool ok)
                        (stdlib.json.json-stdlib-inline-test-assert-true
                          ok
                          "json nested bool")]
                      [_ (io.panic "json nested bool")])]
                  [(JsonMissing) (io.panic "json nested bool")])))]
          [_ (io.panic "json nested object")])]
      [(JsonMissing) (io.panic "json nested object")])))

;: Assert a parsed document has the expected escaped string member.
(define (json-stdlib-inline-test-escaped [doc : Json]) : unit
  (let
    [key : String "escaped"]
    (match (stdlib.json.json-object-get doc (& key))
      [(JsonFound value)
        (match value
          [(JsonString text)
            (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
              text
              "a\nb\tc"
              "json escaped string")]
          [_ (io.panic "json escaped string")])]
      [(JsonMissing) (io.panic "json escaped string")])))

;: Assert that parsing `text` fails.
(define (json-stdlib-inline-test-assert-parse-error
  [text : String]
  [message : String]) : unit
  (match (stdlib.json.json-parse (& text))
    [(OkJson _) (io.panic message)]
    [(ErrJson _) unit]))

(test
  json-helpers-api
  (begin
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (string.string-append "a" (string.string-append "b" "c"))
      "abc"
      "json-cat3")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (string.string-append
        "a"
        (string.string-append "b" (string.string-append "c" "d")))
      "abcd"
      "json-cat4")
    (stdlib.json.json-stdlib-inline-test-assert-i64-eq
      (stdlib.json.json-char-code 'A')
      65
      "stdlib.json.json-char-code")
    (stdlib.json.json-stdlib-inline-test-assert-i64-eq
      (stdlib.json.json-stdlib-inline-test-char-code-at "AZ" 1)
      90
      "stdlib.json.json-char-code-at")
    (stdlib.json.json-stdlib-inline-test-assert-true
      (stdlib.json.json-stdlib-inline-test-char-code-eq-at "AZ" 0 65)
      "stdlib.json.json-char-code-eq-at true")
    (stdlib.json.json-stdlib-inline-test-assert-false
      (stdlib.json.json-stdlib-inline-test-char-code-eq-at "AZ" 2 65)
      "stdlib.json.json-char-code-eq-at out of range")
    (stdlib.json.json-stdlib-inline-test-assert-true
      (stdlib.json.json-space-code? 32)
      "stdlib.json.json-space-code? space")
    (stdlib.json.json-stdlib-inline-test-assert-false
      (stdlib.json.json-space-code? 65)
      "stdlib.json.json-space-code? false")
    (stdlib.json.json-stdlib-inline-test-assert-true
      (stdlib.json.json-digit-code? 57)
      "stdlib.json.json-digit-code? true")
    (stdlib.json.json-stdlib-inline-test-assert-false
      (stdlib.json.json-digit-code? 65)
      "stdlib.json.json-digit-code? false")
    (stdlib.json.json-stdlib-inline-test-assert-true
      (stdlib.json.json-stdlib-inline-test-digit-at? "a5" 1)
      "stdlib.json.json-digit-at? true")
    (stdlib.json.json-stdlib-inline-test-assert-false
      (stdlib.json.json-stdlib-inline-test-digit-at? "a5" 0)
      "stdlib.json.json-digit-at? false")
    (stdlib.json.json-stdlib-inline-test-assert-false
      (stdlib.json.json-stdlib-inline-test-digit-at? "a5" 2)
      "stdlib.json.json-digit-at? out of range")
    (stdlib.json.json-stdlib-inline-test-assert-i64-eq
      (stdlib.json.json-stdlib-inline-test-skip-ws "   X" 0)
      3
      "stdlib.json.json-skip-ws")
    (stdlib.json.json-stdlib-inline-test-assert-true
      (stdlib.json.json-stdlib-inline-test-prefix-at? "abcdef" "cd" 2)
      "stdlib.json.json-string-prefix-at? true")
    (stdlib.json.json-stdlib-inline-test-assert-false
      (stdlib.json.json-stdlib-inline-test-prefix-at? "abcdef" "cd" 5)
      "stdlib.json.json-string-prefix-at? false")
    (stdlib.json.json-stdlib-inline-test-assert-i64-eq
      (stdlib.json.json-list-count
        (stdlib.json.json-stdlib-inline-test-list-cons
          JsonNull
          (stdlib.json.json-stdlib-inline-test-list-cons
            (JsonBool true)
            JsonListNil)))
      2
      "stdlib.json.json-list-count")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (stdlib.json.json-stringify-list
        (stdlib.json.json-list-reverse
          (stdlib.json.json-stdlib-inline-test-list-cons
            (JsonNumber "2")
            (stdlib.json.json-stdlib-inline-test-list-cons
              (JsonNumber "1")
              JsonListNil))))
      "1,2"
      "stdlib.json.json-list-reverse")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (stdlib.json.json-stringify-list
        (stdlib.json.json-vec-to-list
          (stdlib.json.json-vec-push
            (stdlib.json.json-vec-push
              (stdlib.json.json-vec-new)
              (JsonNumber "1"))
            (JsonNumber "2"))))
      "1,2"
      "stdlib.json.json-vec-to-list")
    (stdlib.json.json-stdlib-inline-test-assert-i64-eq
      (stdlib.json.json-member-list-count
        (stdlib.json.json-stdlib-inline-test-member-cons
          "a"
          JsonNull
          (stdlib.json.json-stdlib-inline-test-member-cons
            "b"
            (JsonBool true)
            JsonMemberListNil)))
      2
      "stdlib.json.json-member-list-count")
    (stdlib.json.json-stdlib-inline-test-assert-found-number
      (stdlib.json.json-stdlib-inline-test-member-list-get
        (stdlib.json.json-stdlib-inline-test-member-cons
          "a"
          (JsonNumber "1")
          (stdlib.json.json-stdlib-inline-test-member-cons
            "b"
            (JsonNumber "2")
            JsonMemberListNil))
        "b")
      "2"
      "stdlib.json.json-member-list-get")
    (stdlib.json.json-stdlib-inline-test-assert-missing
      (stdlib.json.json-stdlib-inline-test-member-list-get
        (stdlib.json.json-stdlib-inline-test-member-cons
          "a"
          (JsonNumber "1")
          JsonMemberListNil)
        "z")
      "stdlib.json.json-member-list-get missing")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (stdlib.json.json-stringify-members
        (stdlib.json.json-member-list-reverse
          (stdlib.json.json-stdlib-inline-test-member-cons
            "b"
            (JsonBool true)
            (stdlib.json.json-stdlib-inline-test-member-cons
              "a"
              JsonNull
              JsonMemberListNil))))
      "\"a\":null,\"b\":true"
      "stdlib.json.json-member-list-reverse")
    (stdlib.json.json-stdlib-inline-test-assert-found-number
      (stdlib.json.json-member-list-get-owned
        (stdlib.json.json-member-vec-to-list
          (stdlib.json.json-member-vec-push
            (stdlib.json.json-member-vec-push
              (stdlib.json.json-member-vec-new)
              (JsonMember "dup" (JsonNumber "1")))
            (JsonMember "dup" (JsonNumber "2"))))
        "dup")
      "1"
      "stdlib.json.json-member-vec-to-list duplicate first")
    (stdlib.json.json-stdlib-inline-test-assert-found-number
      (stdlib.json.json-stdlib-inline-test-object-get
        (stdlib.json.json-stdlib-inline-test-object
          (stdlib.json.json-stdlib-inline-test-member-cons
            "n"
            (JsonNumber "7")
            JsonMemberListNil))
        "n")
      "7"
      "stdlib.json.json-object-get")
    (stdlib.json.json-stdlib-inline-test-assert-missing
      (stdlib.json.json-stdlib-inline-test-object-get JsonNull "n")
      "stdlib.json.json-object-get non-object")
    (stdlib.json.json-stdlib-inline-test-assert-i64-eq
      (stdlib.json.json-hex-value 'A')
      10
      "stdlib.json.json-hex-value upper")
    (stdlib.json.json-stdlib-inline-test-assert-i64-eq
      (stdlib.json.json-hex-value 'f')
      15
      "stdlib.json.json-hex-value lower")
    (stdlib.json.json-stdlib-inline-test-assert-i64-eq
      (stdlib.json.json-hex-value 'g')
      -1
      "stdlib.json.json-hex-value invalid")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (stdlib.json.json-hex-digit 15)
      "f"
      "stdlib.json.json-hex-digit")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (stdlib.json.json-control-escape 10)
      "\\n"
      "stdlib.json.json-control-escape newline")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (stdlib.json.json-control-escape 1)
      "\\u0001"
      "stdlib.json.json-control-escape unicode")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (stdlib.json.json-escape-char 34)
      "\\\""
      "stdlib.json.json-escape-char quote")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (stdlib.json.json-escape-char 92)
      "\\\\"
      "stdlib.json.json-escape-char slash")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (stdlib.json.json-stdlib-inline-test-escape-string "a\n\"\\")
      "a\\n\\\"\\\\"
      "stdlib.json.json-escape-string")
    (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
      (stdlib.json.json-stringify
        (stdlib.json.json-stdlib-inline-test-array
          (stdlib.json.json-stdlib-inline-test-list-cons
            (JsonNumber "1")
            (stdlib.json.json-stdlib-inline-test-list-cons JsonNull JsonListNil))))
      "[1,null]"
      "stdlib.json.json-stringify array")
    (stdlib.json.json-stdlib-inline-test-assert-codepoint
      (stdlib.json.json-codepoint-string 65)
      "A"
      "stdlib.json.json-codepoint-string")
    (match (stdlib.json.json-codepoint-string 200)
      [(ErrJsonCodepointString _) unit]
      [(OkJsonCodepointString _)
        (io.panic "stdlib.json.json-codepoint-string rejects unsupported")])
    (stdlib.json.json-stdlib-inline-test-assert-parse-escape
      (stdlib.json.json-stdlib-inline-test-parse-unicode-escape "0041" 0)
      "A"
      4
      "stdlib.json.json-parse-unicode-escape")
    (match (stdlib.json.json-stdlib-inline-test-parse-unicode-escape "00xz" 0)
      [(ErrJsonParseEscape _) unit]
      [(OkJsonParseEscape _ _)
        (io.panic "stdlib.json.json-parse-unicode-escape rejects invalid")])
    (stdlib.json.json-stdlib-inline-test-assert-parse-escape
      (stdlib.json.json-stdlib-inline-test-parse-escape "\\n" 1)
      "\n"
      2
      "stdlib.json.json-parse-escape")
    (match (stdlib.json.json-stdlib-inline-test-parse-escape "\\x" 1)
      [(ErrJsonParseEscape _) unit]
      [(OkJsonParseEscape _ _)
        (io.panic "stdlib.json.json-parse-escape rejects invalid")])
    (stdlib.json.json-stdlib-inline-test-assert-parse-string
      (stdlib.json.json-stdlib-inline-test-parse-string "\"a\\n\"" 0)
      "a\n"
      5
      "stdlib.json.json-parse-string")
    (match (stdlib.json.json-stdlib-inline-test-parse-string "\"unterminated" 0)
      [(ErrJsonParseString _) unit]
      [(OkJsonParseString _ _)
        (io.panic "stdlib.json.json-parse-string rejects invalid")])
    (stdlib.json.json-stdlib-inline-test-assert-i64-eq
      (stdlib.json.json-stdlib-inline-test-consume-digits "123abc" 0)
      3
      "stdlib.json.json-consume-digits")
    (stdlib.json.json-stdlib-inline-test-assert-parse-value-number
      (stdlib.json.json-stdlib-inline-test-parse-number "-2.5e3" 0)
      "-2.5e3"
      6
      "stdlib.json.json-parse-number")
    (match (stdlib.json.json-stdlib-inline-test-parse-number "01" 0)
      [(ErrJsonParseValue _) unit]
      [(OkJsonParseValue _ _)
        (io.panic "stdlib.json.json-parse-number rejects leading zero")])
    (stdlib.json.json-stdlib-inline-test-assert-json-f64
      (stdlib.json.json-stdlib-inline-test-number-f64 "42")
      42.0
      "stdlib.json.json-number->f64 int")
    (stdlib.json.json-stdlib-inline-test-assert-json-f64
      (stdlib.json.json-stdlib-inline-test-number-f64 "-2.5e3")
      -2500.0
      "stdlib.json.json-number->f64 exponent")
    (stdlib.json.json-stdlib-inline-test-assert-json-f64
      (stdlib.json.json-stdlib-inline-test-number-f64 "6.25E-1")
      0.625
      "stdlib.json.json-number->f64 fraction exponent")
    (match (stdlib.json.json-stdlib-inline-test-number-f64 "-0")
      [(OkJsonNumberF64 value)
        (stdlib.json.json-stdlib-inline-test-assert-json-number-text
          (stdlib.json.json-f64->number-text value)
          "-0"
          "stdlib.json.json-number->f64 preserves negative zero")]
      [(ErrJsonNumberF64 _)
        (io.panic "stdlib.json.json-number->f64 negative zero")])
    (match (stdlib.json.json-stdlib-inline-test-number-f64 "1e+17")
      [(OkJsonNumberF64 value)
        (stdlib.json.json-stdlib-inline-test-assert-json-number-text
          (stdlib.json.json-f64->number-text value)
          "1e+17"
          "stdlib.json.json-number->f64 large magnitude")]
      [(ErrJsonNumberF64 _)
        (io.panic "stdlib.json.json-number->f64 large magnitude")])
    (stdlib.json.json-stdlib-inline-test-assert-json-f64-error
      (stdlib.json.json-stdlib-inline-test-number-f64 "1x")
      "stdlib.json.json-number->f64 trailing")
    (stdlib.json.json-stdlib-inline-test-assert-json-f64-error
      (stdlib.json.json-stdlib-inline-test-number-f64 "01")
      "stdlib.json.json-number->f64 leading")
    (stdlib.json.json-stdlib-inline-test-assert-json-f64-error
      (stdlib.json.json-stdlib-inline-test-number-f64 "1e309")
      "stdlib.json.json-number->f64 overflow")
    (stdlib.json.json-stdlib-inline-test-assert-json-f64-error
      (stdlib.json.json-stdlib-inline-test-number-f64 "1e-400")
      "stdlib.json.json-number->f64 underflow")
    (stdlib.json.json-stdlib-inline-test-assert-json-f32-as-f64
      (stdlib.json.json-stdlib-inline-test-number-f32 "1.5")
      1.5
      "stdlib.json.json-number->f32")
    (stdlib.json.json-stdlib-inline-test-assert-json-f32-error
      (stdlib.json.json-stdlib-inline-test-number-f32 "1e39")
      "stdlib.json.json-number->f32 overflow")
    (stdlib.json.json-stdlib-inline-test-assert-json-f32-error
      (stdlib.json.json-stdlib-inline-test-number-f32 "1e-50")
      "stdlib.json.json-number->f32 underflow")
    (stdlib.json.json-stdlib-inline-test-assert-json-number-text
      (stdlib.json.json-f64->number-text 0.125)
      "0.125"
      "stdlib.json.json-f64->number-text")
    (stdlib.json.json-stdlib-inline-test-assert-json-number-text
      (stdlib.json.json-f32->number-text (cast 1.25 : f32))
      "1.25"
      "stdlib.json.json-f32->number-text")
    (stdlib.json.json-stdlib-inline-test-assert-parse-value-bool
      (stdlib.json.json-stdlib-inline-test-parse-keyword
        "true"
        0
        "true"
        (JsonBool true))
      true
      4
      "stdlib.json.json-parse-keyword")
    (stdlib.json.json-stdlib-inline-test-assert-parse-array-count
      (stdlib.json.json-stdlib-inline-test-parse-array "[1,true]" 0)
      2
      8
      "stdlib.json.json-parse-array")
    (stdlib.json.json-stdlib-inline-test-assert-parse-array-count
      (stdlib.json.json-stdlib-inline-test-parse-array "[]" 0)
      0
      2
      "stdlib.json.json-parse-array empty")
    (stdlib.json.json-stdlib-inline-test-assert-parse-object-count
      (stdlib.json.json-stdlib-inline-test-parse-object "{\"a\":1}" 0)
      1
      7
      "stdlib.json.json-parse-object")
    (stdlib.json.json-stdlib-inline-test-assert-parse-object-count
      (stdlib.json.json-stdlib-inline-test-parse-object "{}" 0)
      0
      2
      "stdlib.json.json-parse-object empty")
    (stdlib.json.json-stdlib-inline-test-assert-parse-value-bool
      (stdlib.json.json-stdlib-inline-test-parse-value " false" 0)
      false
      6
      "stdlib.json.json-parse-value")
    unit))

(test
  json-parse-stringify-api
  (let
    [text : String
      " { \"name\" : \"tl\", \"items\" : [1, -2.5e3, true, false, null], \"nested\" : { \"ok\" : true, \"empty\" : [] }, \"escaped\" : \"a\\nb\\tc\" } "]
    (match (stdlib.json.json-parse (& text))
      [(OkJson doc)
        (begin
          (stdlib.json.json-stdlib-inline-test-name doc)
          (stdlib.json.json-stdlib-inline-test-numbers doc)
          (stdlib.json.json-stdlib-inline-test-nested doc)
          (stdlib.json.json-stdlib-inline-test-escaped doc)
          (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
            (stdlib.json.json-stringify doc)
            "{\"name\":\"tl\",\"items\":[1,-2.5e3,true,false,null],\"nested\":{\"ok\":true,\"empty\":[]},\"escaped\":\"a\\nb\\tc\"}"
            "json stringify document")
          (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
            (stdlib.json.json-stringify (JsonString "a\n\"\\"))
            "\"a\\n\\\"\\\\\""
            "json stringify escapes")
          (let
            [dupe-text : String "{\"a\":1,\"a\":2}"]
            [dupe-key : String "a"]
            (match (stdlib.json.json-parse (& dupe-text))
              [(OkJson dupe-doc)
                (begin
                  (stdlib.json.json-stdlib-inline-test-assert-found-number
                    (stdlib.json.json-object-get dupe-doc (& dupe-key))
                    "1"
                    "json duplicate key lookup keeps first source member")
                  (stdlib.json.json-stdlib-inline-test-assert-owned-string-eq
                    (stdlib.json.json-stringify dupe-doc)
                    "{\"a\":1,\"a\":2}"
                    "json duplicate key stringify order"))]
              [(ErrJson _) (io.panic "json duplicate keys should parse")]))
          (stdlib.json.json-stdlib-inline-test-assert-parse-error
            "{\"bad\":[1,]}"
            "json rejects trailing comma")
          (stdlib.json.json-stdlib-inline-test-assert-parse-error
            "{\"bad\" 1}"
            "json rejects missing colon")
          (stdlib.json.json-stdlib-inline-test-assert-parse-error
            "\"unterminated"
            "json rejects unterminated string")
          (stdlib.json.json-stdlib-inline-test-assert-parse-error
            "01"
            "json rejects leading zero")
          (stdlib.json.json-stdlib-inline-test-assert-parse-error
            "true false"
            "json rejects trailing text")
          unit)]
      [(ErrJson _) (io.panic "json document should parse")])))

(cfg
  test
  (export
    (value json-stdlib-inline-test-assert-true)
    (value json-stdlib-inline-test-assert-false)
    (value json-stdlib-inline-test-assert-bool-eq)
    (value json-stdlib-inline-test-assert-i64-eq)
    (value json-stdlib-inline-test-assert-f64-eq)
    (value json-stdlib-inline-test-assert-owned-string-eq)
    (value json-stdlib-inline-test-assert-found-number)
    (value json-stdlib-inline-test-assert-missing)
    (value json-stdlib-inline-test-list-cons)
    (value json-stdlib-inline-test-member-cons)
    (value json-stdlib-inline-test-array)
    (value json-stdlib-inline-test-object)
    (value json-stdlib-inline-test-assert-parse-string)
    (value json-stdlib-inline-test-assert-parse-escape)
    (value json-stdlib-inline-test-assert-codepoint)
    (value json-stdlib-inline-test-assert-json-f64)
    (value json-stdlib-inline-test-assert-json-f32-as-f64)
    (value json-stdlib-inline-test-assert-json-f64-error)
    (value json-stdlib-inline-test-assert-json-f32-error)
    (value json-stdlib-inline-test-assert-json-number-text)
    (value json-stdlib-inline-test-assert-parse-value-number)
    (value json-stdlib-inline-test-assert-parse-value-bool)
    (value json-stdlib-inline-test-assert-parse-array-count)
    (value json-stdlib-inline-test-assert-parse-object-count)
    (value json-stdlib-inline-test-char-code-at)
    (value json-stdlib-inline-test-char-code-eq-at)
    (value json-stdlib-inline-test-digit-at?)
    (value json-stdlib-inline-test-skip-ws)
    (value json-stdlib-inline-test-prefix-at?)
    (value json-stdlib-inline-test-member-list-get)
    (value json-stdlib-inline-test-object-get)
    (value json-stdlib-inline-test-escape-string)
    (value json-stdlib-inline-test-parse-unicode-escape)
    (value json-stdlib-inline-test-parse-escape)
    (value json-stdlib-inline-test-parse-string)
    (value json-stdlib-inline-test-consume-digits)
    (value json-stdlib-inline-test-parse-number)
    (value json-stdlib-inline-test-number-f64)
    (value json-stdlib-inline-test-number-f32)
    (value json-stdlib-inline-test-parse-keyword)
    (value json-stdlib-inline-test-parse-array)
    (value json-stdlib-inline-test-parse-object)
    (value json-stdlib-inline-test-parse-value)
    (value json-stdlib-inline-test-name)
    (value json-stdlib-inline-test-numbers)
    (value json-stdlib-inline-test-nested)
    (value json-stdlib-inline-test-escaped)
    (value json-stdlib-inline-test-assert-parse-error)))

(export
  (value json-vec-slots)
  (value json-vec-len)
  (value json-vec-capacity)
  (value json-vec-with-capacity)
  (value json-vec-new)
  (value json-vec-copy-range)
  (value json-vec-grow)
  (value json-vec-push)
  (value json-vec-to-list-from)
  (value json-vec-to-list)
  (value json-member-vec-slots)
  (value json-member-vec-len)
  (value json-member-vec-capacity)
  (value json-member-vec-with-capacity)
  (value json-member-vec-new)
  (value json-member-vec-copy-range)
  (value json-member-vec-grow)
  (value json-member-vec-push)
  (value json-member-vec-to-list-from)
  (value json-member-vec-to-list)
  (value json-ascii-printable-table)
  (value json-char-code)
  (value json-char-code-at)
  (value json-char-code-eq-at)
  (value json-space-code?)
  (value json-digit-code?)
  (value json-digit-at?)
  (value json-number-max-significant-digits)
  (value json-skip-ws)
  (value json-composite-item-count)
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
  (type JsonMember)
  (type JsonVec)
  (type JsonMemberVec)
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
  (constructor JsonMember)
  (constructor JsonVec)
  (constructor JsonMemberVec)
  (field JsonMember key)
  (field JsonMember value)
  (field JsonVec slots)
  (field JsonVec len)
  (field JsonMemberVec slots)
  (field JsonMemberVec len)
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