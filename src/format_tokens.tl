;; format_tokens.tl - Comment-preserving tokens for the formatter (#326).
;;
;; This lexer is separate from lex.tl because a formatter must keep source
;; spelling and comments. Whitespace is skipped for now; comments are retained
;; as trivia tokens so later layout rules can place them deliberately.
(import stdlib.io as io_mod)

(import stdlib.string as string_mod)

(defenum FormatToken
  (FmtLParen)
  (FmtRParen)
  (FmtLBracket)
  (FmtRBracket)
  (FmtColon)
  (FmtQuote)
  (FmtBacktick)
  (FmtDot)
  (FmtComma)
  (FmtCommaAt)
  (FmtInt String)
  (FmtSymbol String)
  (FmtString String)
  (FmtChar String)
  (FmtComment String)
  (FmtEnd))

(defstruct FormatSourceSpan
  (start-line i64)
  (start-col i64)
  (end-line i64)
  (end-col i64))

(defstruct FormatSourceError
  (message String)
  (span FormatSourceSpan))

(defstruct FormatTokenStream
  (source String)
  (tokens (Array FormatToken))
  (starts (Array i64))
  (count i64))

(defstruct FormatPosition
  (line i64)
  (col i64))

(defenum ResultFormatTokenStream
  (OkFormatTokenStream FormatTokenStream)
  (ErrFormatTokenStream FormatSourceError))

(defenum ResultFmtI64
  (OkFmtI64 i64)
  (ErrFmtI64 FormatSourceError))

(define (fmt-tag-lparen) : i64
  1)

(define (fmt-tag-rparen) : i64
  2)

(define (fmt-tag-lbracket) : i64
  3)

(define (fmt-tag-rbracket) : i64
  4)

(define (fmt-tag-colon) : i64
  5)

(define (fmt-tag-quote) : i64
  6)

(define (fmt-tag-backtick) : i64
  7)

(define (fmt-tag-dot) : i64
  8)

(define (fmt-tag-comma) : i64
  9)

(define (fmt-tag-comma-at) : i64
  10)

(define (fmt-tag-int) : i64
  11)

(define (fmt-tag-symbol) : i64
  12)

(define (fmt-tag-string) : i64
  13)

(define (fmt-tag-char) : i64
  14)

(define (fmt-tag-comment) : i64
  15)

(define (fmt-tag-end) : i64
  16)

(define (format-token-tag [tok : FormatToken]) : i64
  (match tok
    [(FmtLParen) (fmt-tag-lparen)]
    [(FmtRParen) (fmt-tag-rparen)]
    [(FmtLBracket) (fmt-tag-lbracket)]
    [(FmtRBracket) (fmt-tag-rbracket)]
    [(FmtColon) (fmt-tag-colon)]
    [(FmtQuote) (fmt-tag-quote)]
    [(FmtBacktick) (fmt-tag-backtick)]
    [(FmtDot) (fmt-tag-dot)]
    [(FmtComma) (fmt-tag-comma)]
    [(FmtCommaAt) (fmt-tag-comma-at)]
    [(FmtInt _) (fmt-tag-int)]
    [(FmtSymbol _) (fmt-tag-symbol)]
    [(FmtString _) (fmt-tag-string)]
    [(FmtChar _) (fmt-tag-char)]
    [(FmtComment _) (fmt-tag-comment)]
    [(FmtEnd) (fmt-tag-end)]))

(define (format-token-text [tok : FormatToken]) : String
  (match tok
    [(FmtLParen) "("]
    [(FmtRParen) ")"]
    [(FmtLBracket) "["]
    [(FmtRBracket) "]"]
    [(FmtColon) ":"]
    [(FmtQuote) "'"]
    [(FmtBacktick) "`"]
    [(FmtDot) "."]
    [(FmtComma) ","]
    [(FmtCommaAt) ",@"]
    [(FmtInt text) text]
    [(FmtSymbol text) text]
    [(FmtString text) text]
    [(FmtChar text) text]
    [(FmtComment text) text]
    [(FmtEnd) ""]))

(define (format-token-at [stream : FormatTokenStream] [idx : i64]) : FormatToken
  (array-ref (struct-get stream tokens) idx))

(define (format-token-start [stream : FormatTokenStream] [idx : i64]) : i64
  (array-ref (struct-get stream starts) idx))

(define (format-token-count [stream : FormatTokenStream]) : i64
  (struct-get stream count))

(define (fmt-position-line [pos : FormatPosition]) : i64
  (struct-get pos line))

(define (fmt-position-col [pos : FormatPosition]) : i64
  (struct-get pos col))

(define (format-source-error-message [err : FormatSourceError]) : String
  (struct-get err message))

(define (format-source-error-span [err : FormatSourceError]) : FormatSourceSpan
  (struct-get err span))

(define (format-source-span-start-line [span : FormatSourceSpan]) : i64
  (struct-get span start-line))

(define (format-source-span-start-col [span : FormatSourceSpan]) : i64
  (struct-get span start-col))

(define (format-source-span-eq?
  [span : FormatSourceSpan]
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : bool
  (and
    (= (struct-get span start-line) start-line)
    (= (struct-get span start-col) start-col)
    (= (struct-get span end-line) end-line)
    (= (struct-get span end-col) end-col)))

(define (fmt-source-position-at [src : String] [target : i64]) : FormatPosition
  (let
    [n : i64 (string-length src)]
    [i : i64 0]
    [line : i64 1]
    [col : i64 1]
    (begin
      (while (and (< i target) (< i n))
        (let
          [c : char (string-ref src i)]
          (begin
            (if (= c #\newline')
              (begin
                (set! line (+ line 1))
                (set! col 1))
              (set! col (+ col 1)))
            (set! i (+ i 1)))))
      (FormatPosition line col))))

(define (fmt-source-error-at [src : String] [idx : i64] [message : String]) : FormatSourceError
  (let
    [pos : FormatPosition (fmt-source-position-at src idx)]
    (FormatSourceError
      message
      (FormatSourceSpan
        (fmt-position-line pos)
        (fmt-position-col pos)
        (fmt-position-line pos)
        (fmt-position-col pos)))))

(define (format-token-span [stream : FormatTokenStream] [idx : i64]) : FormatSourceSpan
  (let
    [pos : FormatPosition
      (fmt-source-position-at
        (struct-get stream source)
        (format-token-start stream idx))]
    (FormatSourceSpan
      (fmt-position-line pos)
      (fmt-position-col pos)
      (fmt-position-line pos)
      (fmt-position-col pos))))

(define (format-token-tag-count [stream : FormatTokenStream] [wanted : i64]) : i64
  (let
    [i : i64 0]
    [hits : i64 0]
    (begin
      (while (< i (struct-get stream count))
        (begin
          (if (= (format-token-tag (format-token-at stream i)) wanted)
            (set! hits (+ hits 1))
            (set! hits hits))
          (set! i (+ i 1))))
      hits)))

(define (fmt-is-digit [c : char]) : bool
  (and (>= c #0') (<= c #9')))

(define (fmt-is-hex-digit [c : char]) : bool
  (or (fmt-is-digit c) (and (>= c #a') (<= c #f')) (and (>= c #A') (<= c #F'))))

(define (fmt-is-binary-digit [c : char]) : bool
  (or (= c #0') (= c #1')))

(define (fmt-is-alpha [c : char]) : bool
  (or (and (>= c #A') (<= c #Z')) (and (>= c #a') (<= c #z'))))

(define (fmt-is-space [c : char]) : bool
  (or (= c #\space') (= c #\tab') (= c #\newline') (= c #\return')))

(define (fmt-is-symbol-punct [c : char]) : bool
  (or
    (= c #-')
    (= c #+')
    (= c #*')
    (= c #/')
    (= c #?')
    (= c #!')
    (= c #>')
    (= c #<')
    (= c #=')
    (= c #_')
    (= c #$')
    (= c #.')
    (= c #%')
    (= c #&')))

(define (fmt-is-symbol-char [c : char]) : bool
  (or (fmt-is-alpha c) (fmt-is-digit c) (fmt-is-symbol-punct c)))

(define (fmt-starts-number [src : String] [i : i64] [n : i64]) : bool
  (let
    [c : char (string-ref src i)]
    (if (fmt-is-digit c)
      true
      (if (= c #-')
        (if (< (+ i 1) n)
          (fmt-is-digit (string-ref src (+ i 1)))
          false)
        false))))

(define (fmt-number-digits-start [src : String] [start : i64]) : i64
  (if (= (string-ref src start) #-')
    (+ start 1)
    start))

(define (fmt-number-prefixed? [src : String] [start : i64] [n : i64]) : bool
  (let
    [digits-start : i64 (fmt-number-digits-start src start)]
    (if (< (+ digits-start 1) n)
      (if (= (string-ref src digits-start) #0')
        (let
          [prefix : char (string-ref src (+ digits-start 1))]
          (or (= prefix #x') (= prefix #X') (= prefix #b') (= prefix #B')))
        false)
      false)))

(define (fmt-number-prefix-base [src : String] [start : i64]) : i64
  (let
    [prefix : char (string-ref src (+ (fmt-number-digits-start src start) 1))]
    (if (or (= prefix #x') (= prefix #X'))
      16
      2)))

(define (fmt-starts-ellipsis [src : String] [i : i64] [n : i64]) : bool
  (and
    (< (+ i 2) n)
    (= (string-ref src i) #.')
    (= (string-ref src (+ i 1)) #.')
    (= (string-ref src (+ i 2)) #.')))

(define (fmt-scan-based-int-end
  [src : String]
  [start : i64]
  [n : i64]
  [base : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (let
            [c : char (string-ref src j)]
            (if (if (= base 16)
              (fmt-is-hex-digit c)
              (fmt-is-binary-digit c))
              (set! j (+ j 1))
              (set! keep false)))
          (set! keep false)))
      j)))

(define (fmt-scan-prefixed-number-end-result
  [src : String]
  [start : i64]
  [n : i64]) : ResultFmtI64
  (let
    [digits-start : i64 (fmt-number-digits-start src start)]
    [base : i64 (fmt-number-prefix-base src start)]
    [value-start : i64 (+ digits-start 2)]
    [end : i64 (fmt-scan-based-int-end src value-start n base)]
    (if (= end value-start)
      (ErrFmtI64
        (fmt-source-error-at
          src
          start
          "format lexer: malformed integer literal"))
      (if (if (< end n)
        (fmt-is-symbol-char (string-ref src end))
        false)
        (ErrFmtI64
          (fmt-source-error-at
            src
            start
            "format lexer: malformed integer literal"))
        (OkFmtI64 end)))))

(define (fmt-scan-prefixed-number-end [src : String] [start : i64] [n : i64]) : i64
  (match (fmt-scan-prefixed-number-end-result src start n)
    [(OkFmtI64 end) end]
    [(ErrFmtI64 err)
      (begin
        (io_mod.panic (format-source-error-message err))
        start)]))

(define (fmt-scan-decimal-number-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [seen-dot : bool false]
    [keep : bool true]
    (begin
      (if (and (< j n) (= (string-ref src j) #-'))
        (set! j (+ j 1))
        (set! j j))
      (while keep
        (if (< j n)
          (let
            [c : char (string-ref src j)]
            (if (and (= c #.') (not seen-dot))
              (begin
                (set! seen-dot true)
                (set! j (+ j 1)))
              (if (or (fmt-is-digit c) (= c #_'))
                (set! j (+ j 1))
                (set! keep false))))
          (set! keep false)))
      j)))

(define (fmt-scan-number-end-result [src : String] [start : i64] [n : i64]) : ResultFmtI64
  (if (fmt-number-prefixed? src start n)
    (fmt-scan-prefixed-number-end-result src start n)
    (OkFmtI64 (fmt-scan-decimal-number-end src start n))))

(define (fmt-scan-number-end [src : String] [start : i64] [n : i64]) : i64
  (match (fmt-scan-number-end-result src start n)
    [(OkFmtI64 end) end]
    [(ErrFmtI64 err)
      (begin
        (io_mod.panic (format-source-error-message err))
        start)]))

(define (fmt-scan-symbol-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (fmt-is-symbol-char (string-ref src j))
            (set! j (+ j 1))
            (set! keep false))
          (set! keep false)))
      j)))

(define (fmt-scan-comment-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (= (string-ref src j) #\newline')
            (set! keep false)
            (set! j (+ j 1)))
          (set! keep false)))
      j)))

(define (fmt-scan-string-end-result [src : String] [start : i64] [n : i64]) : ResultFmtI64
  (let
    [j : i64 start]
    [escaped : bool false]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (let
            [c : char (string-ref src j)]
            (if escaped
              (begin
                (set! escaped false)
                (set! j (+ j 1)))
              (if (= c #\\')
                (begin
                  (set! escaped true)
                  (set! j (+ j 1)))
                (if (= c #"')
                  (begin
                    (set! j (+ j 1))
                    (set! keep false))
                  (set! j (+ j 1))))))
          (begin
            (return
              (ErrFmtI64
                (fmt-source-error-at
                  src
                  (- start 1)
                  "format lexer: unterminated string literal"))))))
      (OkFmtI64 j))))

(define (fmt-scan-string-end [src : String] [start : i64] [n : i64]) : i64
  (match (fmt-scan-string-end-result src start n)
    [(OkFmtI64 end) end]
    [(ErrFmtI64 err)
      (begin
        (io_mod.panic (format-source-error-message err))
        start)]))

(define (fmt-scan-char-end-result [src : String] [start : i64] [n : i64]) : ResultFmtI64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (if (< j n)
        (set! j (+ j 1))
        (return
          (ErrFmtI64
            (fmt-source-error-at
              src
              (- start 1)
              "format lexer: unterminated character literal"))))
      (while keep
        (if (< j n)
          (if (= (string-ref src j) #'')
            (begin
              (set! j (+ j 1))
              (set! keep false))
            (set! j (+ j 1)))
          (return
            (ErrFmtI64
              (fmt-source-error-at
                src
                (- start 1)
                "format lexer: unterminated character literal")))))
      (OkFmtI64 j))))

(define (fmt-scan-char-end [src : String] [start : i64] [n : i64]) : i64
  (match (fmt-scan-char-end-result src start n)
    [(OkFmtI64 end) end]
    [(ErrFmtI64 err)
      (begin
        (io_mod.panic (format-source-error-message err))
        start)]))

(define (fmt-store-token
  [tokens : (Array FormatToken)]
  [starts : (Array i64)]
  [count : i64]
  [start : i64]
  [tok : FormatToken]) : unit
  (begin
    (array-set! tokens count tok)
    (array-set! starts count start)))

(define (format-empty-token-stream) : FormatTokenStream
  (let
    [tokens : (Array FormatToken) (make-array FormatToken 1)]
    [starts : (Array i64) (make-array i64 1)]
    (begin
      (fmt-store-token tokens starts 0 0 (FmtEnd))
      (FormatTokenStream "" tokens starts 1))))

(define (format-lex-result [src : String]) : ResultFormatTokenStream
  (let
    [n : i64 (string-length src)]
    [tokens : (Array FormatToken)
      (make-array FormatToken (+ (string-length src) 1))]
    [starts : (Array i64) (make-array i64 (+ (string-length src) 1))]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref src i)]
          (if (fmt-is-space c)
            (set! i (+ i 1))
            (if (= c #;')
              (let
                [end : i64 (fmt-scan-comment-end src i n)]
                (begin
                  (fmt-store-token
                    tokens
                    starts
                    count
                    i
                    (FmtComment (string_mod.substring src i (- end i))))
                  (set! count (+ count 1))
                  (set! i end)))
              (if (= c #(')
                (begin
                  (fmt-store-token tokens starts count i (FmtLParen))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))
                (if (= c #)')
                  (begin
                    (fmt-store-token tokens starts count i (FmtRParen))
                    (set! count (+ count 1))
                    (set! i (+ i 1)))
                  (if (= c #[')
                    (begin
                      (fmt-store-token tokens starts count i (FmtLBracket))
                      (set! count (+ count 1))
                      (set! i (+ i 1)))
                    (if (= c #]')
                      (begin
                        (fmt-store-token tokens starts count i (FmtRBracket))
                        (set! count (+ count 1))
                        (set! i (+ i 1)))
                      (if (= c #:')
                        (begin
                          (fmt-store-token tokens starts count i (FmtColon))
                          (set! count (+ count 1))
                          (set! i (+ i 1)))
                        (if (= c #'')
                          (begin
                            (fmt-store-token tokens starts count i (FmtQuote))
                            (set! count (+ count 1))
                            (set! i (+ i 1)))
                          (if (= c #`')
                            (begin
                              (fmt-store-token
                                tokens
                                starts
                                count
                                i
                                (FmtBacktick))
                              (set! count (+ count 1))
                              (set! i (+ i 1)))
                            (if (fmt-starts-ellipsis src i n)
                              (begin
                                (fmt-store-token
                                  tokens
                                  starts
                                  count
                                  i
                                  (FmtSymbol "..."))
                                (set! count (+ count 1))
                                (set! i (+ i 3)))
                              (if (= c #.')
                                (begin
                                  (fmt-store-token
                                    tokens
                                    starts
                                    count
                                    i
                                    (FmtDot))
                                  (set! count (+ count 1))
                                  (set! i (+ i 1)))
                                (if (= c #,')
                                  (if (< (+ i 1) n)
                                    (if (= (string-ref src (+ i 1)) #@')
                                      (begin
                                        (fmt-store-token
                                          tokens
                                          starts
                                          count
                                          i
                                          (FmtCommaAt))
                                        (set! count (+ count 1))
                                        (set! i (+ i 2)))
                                      (begin
                                        (fmt-store-token
                                          tokens
                                          starts
                                          count
                                          i
                                          (FmtComma))
                                        (set! count (+ count 1))
                                        (set! i (+ i 1))))
                                    (begin
                                      (fmt-store-token
                                        tokens
                                        starts
                                        count
                                        i
                                        (FmtComma))
                                      (set! count (+ count 1))
                                      (set! i (+ i 1))))
                                  (if (= c #"')
                                    (match (fmt-scan-string-end-result
                                      src
                                      (+ i 1)
                                      n)
                                      [(OkFmtI64 end)
                                        (begin
                                          (fmt-store-token
                                            tokens
                                            starts
                                            count
                                            i
                                            (FmtString
                                              (string_mod.substring
                                                src
                                                i
                                                (- end i))))
                                          (set! count (+ count 1))
                                          (set! i end))]
                                      [(ErrFmtI64 err)
                                        (return (ErrFormatTokenStream err))])
                                    (if (= c ##')
                                      (match (fmt-scan-char-end-result
                                        src
                                        (+ i 1)
                                        n)
                                        [(OkFmtI64 end)
                                          (begin
                                            (fmt-store-token
                                              tokens
                                              starts
                                              count
                                              i
                                              (FmtChar
                                                (string_mod.substring
                                                  src
                                                  i
                                                  (- end i))))
                                            (set! count (+ count 1))
                                            (set! i end))]
                                        [(ErrFmtI64 err)
                                          (return (ErrFormatTokenStream err))])
                                      (if (fmt-starts-number src i n)
                                        (match (fmt-scan-number-end-result
                                          src
                                          i
                                          n)
                                          [(OkFmtI64 end)
                                            (begin
                                              (fmt-store-token
                                                tokens
                                                starts
                                                count
                                                i
                                                (FmtInt
                                                  (string_mod.substring
                                                    src
                                                    i
                                                    (- end i))))
                                              (set! count (+ count 1))
                                              (set! i end))]
                                          [(ErrFmtI64 err)
                                            (return (ErrFormatTokenStream err))])
                                        (if (fmt-is-symbol-char c)
                                          (let
                                            [end : i64
                                              (fmt-scan-symbol-end src i n)]
                                            (begin
                                              (fmt-store-token
                                                tokens
                                                starts
                                                count
                                                i
                                                (FmtSymbol
                                                  (string_mod.substring
                                                    src
                                                    i
                                                    (- end i))))
                                              (set! count (+ count 1))
                                              (set! i end)))
                                          (return
                                            (ErrFormatTokenStream
                                              (fmt-source-error-at
                                                src
                                                i
                                                "format lexer: unexpected character")))))))))))))))))))))
      (fmt-store-token tokens starts count n (FmtEnd))
      (OkFormatTokenStream (FormatTokenStream src tokens starts (+ count 1))))))

(define (format-lex [src : String]) : FormatTokenStream
  (match (format-lex-result src)
    [(OkFormatTokenStream stream) stream]
    [(ErrFormatTokenStream err)
      (begin
        (io_mod.panic (format-source-error-message err))
        (format-empty-token-stream))]))