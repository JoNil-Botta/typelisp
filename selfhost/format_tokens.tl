;; format_tokens.tl - Comment-preserving tokens for the formatter (#326).

;;

;; This lexer is separate from lex.tl because a formatter must keep source

;; spelling and comments. Whitespace is skipped for now; comments are retained

;; as trivia tokens so later layout rules can place them deliberately.

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

(defstruct FormatTokenStream
  (tokens (Array FormatToken))
  (count i64))

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

(define (format-token-count [stream : FormatTokenStream]) : i64
  (struct-get stream count))

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

(define (fmt-is-alpha [c : char]) : bool
  (or (and (>= c #A') (<= c #Z')) (and (>= c #a') (<= c #z'))))

(define (fmt-is-space [c : char]) : bool
  (or (= c #\space') (or (= c #\tab') (or (= c #\newline') (= c #\return')))))

(define (fmt-is-symbol-punct [c : char]) : bool
  (or
    (= c #-')
    (or
      (= c #+')
      (or
        (= c #*')
        (or
          (= c #/')
          (or
            (= c #?')
            (or
              (= c #!')
              (or
                (= c #>')
                (or
                  (= c #<')
                  (or
                    (= c #=')
                    (or (= c #_') (or (= c #$') (or (= c #%') (= c #&'))))))))))))))

(define (fmt-is-symbol-char [c : char]) : bool
  (or (fmt-is-alpha c) (or (fmt-is-digit c) (fmt-is-symbol-punct c))))

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

(define (fmt-scan-number-end [src : String] [start : i64] [n : i64]) : i64
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

(define (fmt-scan-string-end [src : String] [start : i64] [n : i64]) : i64
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
            (panic "format lexer: unterminated string literal")
            (set! keep false))))
      j)))

(define (fmt-scan-char-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (if (< j n)
        (set! j (+ j 1))
        (begin
          (panic "format lexer: unterminated character literal")
          (set! keep false)))
      (while keep
        (if (< j n)
          (if (= (string-ref src j) #'')
            (begin
              (set! j (+ j 1))
              (set! keep false))
            (set! j (+ j 1)))
          (begin
            (panic "format lexer: unterminated character literal")
            (set! keep false))))
      j)))

(define (fmt-store-token
  [tokens : (Array FormatToken)]
  [count : i64]
  [tok : FormatToken]) : unit
  (array-set! tokens count tok))

(define (format-lex [src : String]) : FormatTokenStream
  (let
    [n : i64 (string-length src)]
    [tokens : (Array FormatToken)
      (make-array FormatToken (+ (string-length src) 1))]
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
                    count
                    (FmtComment (substring src i (- end i))))
                  (set! count (+ count 1))
                  (set! i end)))
              (if (= c #(')
                (begin
                  (fmt-store-token tokens count (FmtLParen))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))
                (if (= c #)')
                  (begin
                    (fmt-store-token tokens count (FmtRParen))
                    (set! count (+ count 1))
                    (set! i (+ i 1)))
                  (if (= c #[')
                    (begin
                      (fmt-store-token tokens count (FmtLBracket))
                      (set! count (+ count 1))
                      (set! i (+ i 1)))
                    (if (= c #]')
                      (begin
                        (fmt-store-token tokens count (FmtRBracket))
                        (set! count (+ count 1))
                        (set! i (+ i 1)))
                      (if (= c #:')
                        (begin
                          (fmt-store-token tokens count (FmtColon))
                          (set! count (+ count 1))
                          (set! i (+ i 1)))
                        (if (= c #'')
                          (begin
                            (fmt-store-token tokens count (FmtQuote))
                            (set! count (+ count 1))
                            (set! i (+ i 1)))
                          (if (= c #`')
                            (begin
                              (fmt-store-token tokens count (FmtBacktick))
                              (set! count (+ count 1))
                              (set! i (+ i 1)))
                            (if (= c #.')
                              (begin
                                (fmt-store-token tokens count (FmtDot))
                                (set! count (+ count 1))
                                (set! i (+ i 1)))
                              (if (= c #,')
                                (if (< (+ i 1) n)
                                  (if (= (string-ref src (+ i 1)) #@')
                                    (begin
                                      (fmt-store-token
                                        tokens
                                        count
                                        (FmtCommaAt))
                                      (set! count (+ count 1))
                                      (set! i (+ i 2)))
                                    (begin
                                      (fmt-store-token tokens count (FmtComma))
                                      (set! count (+ count 1))
                                      (set! i (+ i 1))))
                                  (begin
                                    (fmt-store-token tokens count (FmtComma))
                                    (set! count (+ count 1))
                                    (set! i (+ i 1))))
                                (if (= c #"')
                                  (let
                                    [end : i64
                                      (fmt-scan-string-end src (+ i 1) n)]
                                    (begin
                                      (fmt-store-token
                                        tokens
                                        count
                                        (FmtString (substring src i (- end i))))
                                      (set! count (+ count 1))
                                      (set! i end)))
                                  (if (= c ##')
                                    (let
                                      [end : i64
                                        (fmt-scan-char-end src (+ i 1) n)]
                                      (begin
                                        (fmt-store-token
                                          tokens
                                          count
                                          (FmtChar (substring src i (- end i))))
                                        (set! count (+ count 1))
                                        (set! i end)))
                                    (if (fmt-starts-number src i n)
                                      (let
                                        [end : i64
                                          (fmt-scan-number-end src i n)]
                                        (begin
                                          (fmt-store-token
                                            tokens
                                            count
                                            (FmtInt (substring src i (- end i))))
                                          (set! count (+ count 1))
                                          (set! i end)))
                                      (if (fmt-is-symbol-char c)
                                        (let
                                          [end : i64
                                            (fmt-scan-symbol-end src i n)]
                                          (begin
                                            (fmt-store-token
                                              tokens
                                              count
                                              (FmtSymbol
                                                (substring src i (- end i))))
                                            (set! count (+ count 1))
                                            (set! i end)))
                                        (begin
                                          (panic
                                            "format lexer: unexpected character")
                                          (set! i (+ i 1))))))))))))))))))))
      (fmt-store-token tokens count (FmtEnd))
      (FormatTokenStream tokens (+ count 1)))))