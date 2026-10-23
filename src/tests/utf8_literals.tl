(import compiler_builtin_ids as cbi)
(import compiler_intern as intern)
(import lex)
(import token)
(import format_tokens as fmt)
(import stdlib.byte_buf)
(import stdlib.string)
(import stdlib.str_cat_runtime as cat)
(import stdlib.test)

(define (assert-malformed-literals) : unit
  (let
    [rows : (Array (Array i64 7) 7)
      (array
        (array 0x80 0 0 0 1 0 0)
        (array 0xc0 0x80 0 0 2 1 0)
        (array 0xe0 0x80 0x80 0 3 2 1)
        (array 0xed 0xa0 0x80 0 3 3 1)
        (array 0xf4 0x90 0x80 0x80 4 4 1)
        (array 0xe2 0x82 0 0 2 5 2)
        (array 0xe2 0x28 0xa1 0 3 6 1))]
    [names : (Array String 7)
      (array
        "UnexpectedContinuation"
        "InvalidLead"
        "Overlong"
        "Surrogate"
        "OutOfRange"
        "Truncated"
        "InvalidContinuation")]
    [row-index : i64 0]
    (while (< row-index 7)
      (let
        [row : (& rows (Array i64 7)) (& (array-ref rows row-index))]
        [escaped : i64 0]
        (while (< escaped 2)
          (let
            [buffer : byte_buf.ByteBuf (byte_buf.from-string "\n  \"A\\t")]
            [index : i64 0]
            (when
              (= escaped 1)
              (set! buffer (byte_buf.push buffer (cast 92 : u8))))
            (while (< index (array-ref row 4))
              (set!
                buffer
                (byte_buf.push buffer (cast (array-ref row index) : u8)))
              (set! index (+ index 1)))
            (set! buffer (byte_buf.push buffer (cast 34 : u8)))
            (let
              [source : String (byte_buf.to-string buffer)]
              [failure : i64 (array-ref row 6)]
              [column : i64 (+ (+ 7 escaped) failure)]
              [message : String
                (cat.str-cat
                  "lexer: invalid UTF-8 string literal at byte "
                  (string.int->string (+ failure 2))
                  " ("
                  (string.copy (& (array-ref names (array-ref row 5))))
                  ")")]
              (match (lex.spanned-result (& source))
                [(Err error)
                  (let
                    [span : token.SourceSpan error.span]
                    (test.assert-string-eq
                      (& error.message)
                      (& message)
                      "literal UTF-8 error kind and decoded offset")
                    (test.assert-i64-eq
                      span.start-line
                      2
                      "literal diagnostic line")
                    (test.assert-i64-eq
                      span.start-col
                      column
                      "literal diagnostic source column"))]
                [_ (test.assert-true false "malformed source literal rejected")])
              (match (fmt.format-lex-result (string.copy (& source)))
                [(Err error)
                  (test.assert-string-eq
                    (& error.message)
                    (& message)
                    "formatter uses shared literal validation")
                  (test.assert-i64-eq
                    error.span.start-line
                    2
                    "formatter diagnostic line")
                  (test.assert-i64-eq
                    error.span.start-col
                    column
                    "formatter diagnostic column")]
                [_
                  (test.assert-true
                    false
                    "strict formatter rejects malformed text")])))
          (set! escaped (+ escaped 1))))
      (set! row-index (+ row-index 1)))))

(define (assert-valid-literal-bytes) : unit
  (let
    [nul : String
      (byte_buf.to-string
        (byte_buf.push (byte_buf.from-string "") (cast 0 : u8)))]
    [sources : (Array String 3)
      (array
        "\"A\\né€😀é\""
        "\"\""
        (cat.str-cat "\"" (string.copy (& nul)) "\""))]
    [expected : (Array String 3) (array "A\né€😀é" "" nul)]
    [index : i64 0]
    (while (< index 3)
      (let
        [source : (& sources str) (& (array-ref sources index))]
        (match (lex.spanned-result source)
          [(Ok tokens)
            (let
              [tok : (& tokens token.Token)
                (token.spanned-token-token-ref (& (array-ref tokens 0)))]
              (test.assert-string-eq
                (intern.intern-id-str (token.str-id tok))
                (& (array-ref expected index))
                "unescaped UTF-8 literal preserves exact bytes"))]
          [_ (test.assert-true false "valid scalar encodings accepted")])
        (match (fmt.format-lex-result (string.copy source))
          [(Ok _) unit]
          [_ (test.assert-true false "valid Unicode formatter input")]))
      (set! index (+ index 1)))))

(test utf8-literal-invalid-classes-and-source-spans (assert-malformed-literals))

(test utf8-literal-exact-bytes (assert-valid-literal-bytes))

(define (main) : i64
  (cbi.compiler-builtin-initialize-for-parse!)
  (assert-malformed-literals)
  (assert-valid-literal-bytes)
  42)