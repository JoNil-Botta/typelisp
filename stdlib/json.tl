;; stdlib/json.tl - JSON parser and serializer for TypeLisp tools (#800).

;; Provides a canonical JSON value model, recoverable parser, and serializer

;; built on compiler/runtime string primitives.

;;

;; Primitives required from the compiler/runtime:

;;   string-length, string-ref, substring, string-append

;;

;; Allocation policy:

;;   Parsed values, lists, object members, decoded strings, and serialized

;;   strings allocate in the active arena. Outside scoped arenas that is the

;;   default program-lifetime arena; inside `(with-region ...)` it is the

;;   innermost scoped arena. The future `(with-arena ...)` spelling keeps the

;;   same policy.

;;

;; Limits:

;;   `\uXXXX`, `\b`, and `\f` string escapes are reported as recoverable parse

;;   errors until TypeLisp has a char/codepoint-to-string primitive.

;; Usage: (import "stdlib/json.tl")

(defenum Json
  (JsonNull)
  (JsonBool bool)
  (JsonNum String)
  (JsonStr String)
  (JsonArray JsonList)
  (JsonObject JsonMemberList))

(defenum JsonList
  (JsonNil)
  (JsonCons Json JsonList))

(defenum JsonMemberList
  (JsonMemberNil)
  (JsonMemberCons String Json JsonMemberList))

(defenum JsonParse
  (JsonParseOk Json i64)
  (JsonParseErr String))

(defenum JsonStringParse
  (JsonStringParseOk String i64)
  (JsonStringParseErr String))

(defenum JsonListParse
  (JsonListParseOk JsonList i64)
  (JsonListParseErr String))

(defenum JsonMemberListParse
  (JsonMemberListParseOk JsonMemberList i64)
  (JsonMemberListParseErr String))

(defenum JsonLookup
  (JsonMissing)
  (JsonFound Json))

(define (json-char-code-at [text : String] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

(define (json-ws? [c : char]) : bool
  (or (= c #\space') (or (= c #\newline') (or (= c #\tab') (= c #\return')))))

(define (json-digit? [c : char]) : bool
  (and
    (>= (cast c : i64) (cast #0' : i64))
    (<= (cast c : i64) (cast #9' : i64))))

(define (json-nonzero-digit? [c : char]) : bool
  (and
    (>= (cast c : i64) (cast #1' : i64))
    (<= (cast c : i64) (cast #9' : i64))))

(define (json-number-start? [c : char]) : bool
  (or (= c #-') (json-digit? c)))

(define (json-exp-char? [c : char]) : bool
  (or (= c #e') (= c #E')))

(define (json-sign? [c : char]) : bool
  (or (= c #-') (= c #+')))

(define (json-skip-ws [text : String] [pos : i64]) : i64
  (let ([i : i64 pos] [n : i64 (string-length text)] [keep : bool true])
    (begin
      (while keep
        (if (< i n)
          (if (json-ws? (string-ref text i))
            (set! i (+ i 1))
            (set! keep false))
          (set! keep false)))
      i)))

(define (json-prefix-at? [text : String] [prefix : String] [start : i64]) : bool
  (let ([text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)])
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let ([i : i64 0] [ok : bool true])
          (begin
            (while ok
              (if (< i prefix-len)
                (if (=
                  (json-char-code-at text (+ start i))
                  (json-char-code-at prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (json-parse-keyword
  [text : String]
  [pos : i64]
  [keyword : String]
  [value : Json]) : JsonParse
  (if (json-prefix-at? text keyword pos)
    (JsonParseOk value (+ pos (string-length keyword)))
    (JsonParseErr (string-append "expected JSON keyword " keyword))))

(define (json-scan-digits [text : String] [pos : i64] [n : i64]) : i64
  (let ([i : i64 pos] [keep : bool true])
    (begin
      (while keep
        (if (< i n)
          (if (json-digit? (string-ref text i))
            (set! i (+ i 1))
            (set! keep false))
          (set! keep false)))
      i)))

(define (json-parse-number [text : String] [pos : i64]) : JsonParse
  (let ([n : i64 (string-length text)] [i : i64 pos] [ok : bool true])
    (begin
      (if (< i n)
        (if (= (string-ref text i) #-')
          (set! i (+ i 1))
          unit)
        (set! ok false))
      (if ok
        (if (< i n)
          (let ([first : char (string-ref text i)])
            (if (= first #0')
              (set! i (+ i 1))
              (if (json-nonzero-digit? first)
                (set! i (json-scan-digits text (+ i 1) n))
                (set! ok false))))
          (set! ok false))
        unit)
      (if ok
        (if (< i n)
          (if (= (string-ref text i) #.')
            (begin
              (set! i (+ i 1))
              (let ([digits-start : i64 i])
                (begin
                  (set! i (json-scan-digits text i n))
                  (if (= i digits-start)
                    (set! ok false)
                    unit))))
            unit)
          unit)
        unit)
      (if ok
        (if (< i n)
          (if (json-exp-char? (string-ref text i))
            (begin
              (set! i (+ i 1))
              (if (< i n)
                (if (json-sign? (string-ref text i))
                  (set! i (+ i 1))
                  unit)
                (set! ok false))
              (if ok
                (let ([digits-start : i64 i])
                  (begin
                    (set! i (json-scan-digits text i n))
                    (if (= i digits-start)
                      (set! ok false)
                      unit)))
                unit))
            unit)
          unit)
        unit)
      (if ok
        (JsonParseOk (JsonNum (substring text pos (- i pos))) i)
        (JsonParseErr "expected JSON number")))))

(define (json-escape-replacement [escaped : char]) : JsonStringParse
  (if (= escaped #"')
    (JsonStringParseOk "\"" 0)
    (if (= escaped #\\')
      (JsonStringParseOk "\\" 0)
      (if (= escaped #/')
        (JsonStringParseOk "/" 0)
        (if (= escaped #n')
          (JsonStringParseOk "\n" 0)
          (if (= escaped #t')
            (JsonStringParseOk "\t" 0)
            (if (= escaped #r')
              (JsonStringParseOk "\r" 0)
              (if (= escaped #u')
                (JsonStringParseErr "unsupported JSON unicode escape")
                (JsonStringParseErr "unsupported JSON escape")))))))))

(define (json-parse-string [text : String] [pos : i64]) : JsonStringParse
  (let ([n : i64 (string-length text)])
    (if (>= pos n)
      (JsonStringParseErr "expected JSON string")
      (if (not (= (string-ref text pos) #"'))
        (JsonStringParseErr "expected JSON string")
        (let ([i : i64 (+ pos 1)]
          [out : String ""]
          [done : bool false]
          [err : bool false]
          [message : String ""])
          (begin
            (while (and (not done) (not err))
              (if (>= i n)
                (begin
                  (set! err true)
                  (set! message "unterminated JSON string"))
                (let ([c : char (string-ref text i)])
                  (if (= c #"')
                    (begin
                      (set! done true)
                      (set! i (+ i 1)))
                    (if (= c #\\')
                      (if (< (+ i 1) n)
                        (let ([escaped : char (string-ref text (+ i 1))])
                          (match (json-escape-replacement escaped)
                            [(JsonStringParseOk piece _)
                              (begin
                                (set! out (string-append out piece))
                                (set! i (+ i 2)))]
                            [(JsonStringParseErr err-message)
                              (begin
                                (set! err true)
                                (set! message err-message))]))
                        (begin
                          (set! err true)
                          (set! message "unterminated JSON escape")))
                      (if (< (cast c : i64) 32)
                        (begin
                          (set! err true)
                          (set! message "control character in JSON string"))
                        (begin
                          (set! out (string-append out (substring text i 1)))
                          (set! i (+ i 1)))))))))
            (if err
              (JsonStringParseErr message)
              (JsonStringParseOk out i))))))))

(define (json-parse-array-items [text : String] [pos : i64]) : JsonListParse
  (match (json-parse-value text pos)
    [(JsonParseOk value after-value)
      (let ([i : i64 (json-skip-ws text after-value)]
        [n : i64 (string-length text)])
        (if (>= i n)
          (JsonListParseErr "unterminated JSON array")
          (if (= (string-ref text i) #,')
            (match (json-parse-array-items text (json-skip-ws text (+ i 1)))
              [(JsonListParseOk rest end)
                (JsonListParseOk (JsonCons value rest) end)]
              [(JsonListParseErr message) (JsonListParseErr message)])
            (if (= (string-ref text i) #]')
              (JsonListParseOk (JsonCons value JsonNil) (+ i 1))
              (JsonListParseErr "expected ',' or ']' in JSON array")))))]
    [(JsonParseErr message) (JsonListParseErr message)]))

(define (json-parse-array [text : String] [pos : i64]) : JsonParse
  (let ([i : i64 (json-skip-ws text (+ pos 1))] [n : i64 (string-length text)])
    (if (>= i n)
      (JsonParseErr "unterminated JSON array")
      (if (= (string-ref text i) #]')
        (JsonParseOk (JsonArray JsonNil) (+ i 1))
        (match (json-parse-array-items text i)
          [(JsonListParseOk items end) (JsonParseOk (JsonArray items) end)]
          [(JsonListParseErr message) (JsonParseErr message)])))))

(define (json-parse-object-members [text : String] [pos : i64]) : JsonMemberListParse
  (match (json-parse-string text pos)
    [(JsonStringParseOk key after-key)
      (let ([colon-pos : i64 (json-skip-ws text after-key)]
        [n : i64 (string-length text)])
        (if (>= colon-pos n)
          (JsonMemberListParseErr "unterminated JSON object")
          (if (not (= (string-ref text colon-pos) #:'))
            (JsonMemberListParseErr "expected ':' in JSON object")
            (match (json-parse-value text (json-skip-ws text (+ colon-pos 1)))
              [(JsonParseOk value after-value)
                (let ([i : i64 (json-skip-ws text after-value)])
                  (if (>= i n)
                    (JsonMemberListParseErr "unterminated JSON object")
                    (if (= (string-ref text i) #,')
                      (match (json-parse-object-members
                        text
                        (json-skip-ws text (+ i 1)))
                        [(JsonMemberListParseOk rest end)
                          (JsonMemberListParseOk
                            (JsonMemberCons key value rest)
                            end)]
                        [(JsonMemberListParseErr message)
                          (JsonMemberListParseErr message)])
                      (if (= (string-ref text i) #}')
                        (JsonMemberListParseOk
                          (JsonMemberCons key value JsonMemberNil)
                          (+ i 1))
                        (JsonMemberListParseErr
                          "expected ',' or '}' in JSON object")))))]
              [(JsonParseErr message) (JsonMemberListParseErr message)]))))]
    [(JsonStringParseErr message) (JsonMemberListParseErr message)]))

(define (json-parse-object [text : String] [pos : i64]) : JsonParse
  (let ([i : i64 (json-skip-ws text (+ pos 1))] [n : i64 (string-length text)])
    (if (>= i n)
      (JsonParseErr "unterminated JSON object")
      (if (= (string-ref text i) #}')
        (JsonParseOk (JsonObject JsonMemberNil) (+ i 1))
        (match (json-parse-object-members text i)
          [(JsonMemberListParseOk members end)
            (JsonParseOk (JsonObject members) end)]
          [(JsonMemberListParseErr message) (JsonParseErr message)])))))

(define (json-parse-value [text : String] [pos : i64]) : JsonParse
  (let ([i : i64 (json-skip-ws text pos)] [n : i64 (string-length text)])
    (if (>= i n)
      (JsonParseErr "expected JSON value")
      (let ([c : char (string-ref text i)])
        (if (= c #n')
          (json-parse-keyword text i "null" JsonNull)
          (if (= c #t')
            (json-parse-keyword text i "true" (JsonBool true))
            (if (= c #f')
              (json-parse-keyword text i "false" (JsonBool false))
              (if (= c #"')
                (match (json-parse-string text i)
                  [(JsonStringParseOk value end)
                    (JsonParseOk (JsonStr value) end)]
                  [(JsonStringParseErr message) (JsonParseErr message)])
                (if (= c #[')
                  (json-parse-array text i)
                  (if (= c #{')
                    (json-parse-object text i)
                    (if (json-number-start? c)
                      (json-parse-number text i)
                      (JsonParseErr "unexpected JSON character"))))))))))))

(define (json-parse [text : String]) : JsonParse
  (match (json-parse-value text 0)
    [(JsonParseOk value end)
      (let ([trailing : i64 (json-skip-ws text end)])
        (if (= trailing (string-length text))
          (JsonParseOk value trailing)
          (JsonParseErr "trailing characters after JSON value")))]
    [(JsonParseErr message) (JsonParseErr message)]))

(define (json-string-escape-piece [c : char]) : String
  (if (= c #"')
    "\\\""
    (if (= c #\\')
      "\\\\"
      (if (= c #\newline')
        "\\n"
        (if (= c #\tab')
          "\\t"
          (if (= c #\return')
            "\\r"
            ""))))))

(define (json-escape-string [text : String]) : String
  (let ([i : i64 0] [n : i64 (string-length text)] [out : String ""])
    (begin
      (while (< i n)
        (let ([piece : String (json-string-escape-piece (string-ref text i))])
          (begin
            (if (string-eq piece "")
              (set! out (string-append out (substring text i 1)))
              (set! out (string-append out piece)))
            (set! i (+ i 1)))))
      out)))

(define (json-stringify-list [items : JsonList]) : String
  (match items
    [(JsonNil) ""]
    [(JsonCons head rest)
      (string-append
        (json-stringify head)
        (match rest
          [(JsonNil) ""]
          [_ (string-append "," (json-stringify-list rest))]))]))

(define (json-stringify-members [members : JsonMemberList]) : String
  (match members
    [(JsonMemberNil) ""]
    [(JsonMemberCons key value rest)
      (string-append
        (string-append
          (string-append "\"" (string-append (json-escape-string key) "\""))
          (string-append ":" (json-stringify value)))
        (match rest
          [(JsonMemberNil) ""]
          [_ (string-append "," (json-stringify-members rest))]))]))

(define (json-stringify [value : Json]) : String
  (match value
    [(JsonNull) "null"]
    [(JsonBool b)
      (if b
        "true"
        "false")]
    [(JsonNum text) text]
    [(JsonStr text)
      (string-append "\"" (string-append (json-escape-string text) "\""))]
    [(JsonArray items)
      (string-append "[" (string-append (json-stringify-list items) "]"))]
    [(JsonObject members)
      (string-append "{" (string-append (json-stringify-members members) "}"))]))

(define (json-object-get [members : JsonMemberList] [key : String]) : JsonLookup
  (match members
    [(JsonMemberNil) JsonMissing]
    [(JsonMemberCons member-key value rest)
      (if (string-eq member-key key)
        (JsonFound value)
        (json-object-get rest key))]))

(define (json-list-length [items : JsonList]) : i64
  (match items
    [(JsonNil) 0]
    [(JsonCons _ rest) (+ 1 (json-list-length rest))]))