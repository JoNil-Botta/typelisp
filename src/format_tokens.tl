;; format_tokens.tl - Comment-preserving tokens for the formatter (#326).
;;
;; This lexer is separate from lex.tl because a formatter must keep source
;; spelling and comments. Whitespace is skipped for now; comments are retained
;; as trivia tokens so later layout rules can place them deliberately.
(import "../stdlib/io.tl")
(import "../stdlib/string.tl")

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

(defenum ResultFmtMaybeCharEnd
  (NoFmtCharEnd)
  (OkFmtCharEnd i64)
  (ErrFmtCharEnd FormatSourceError))

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

;; Caller must prove `idx` is within the original source string bounds.
(defmacro (fmt-source-byte-bounds-proven [data : Expr] [idx : Expr]) : char
  `(cast
    (unsafe
      (ptr-read (ptr-offset ,data ,idx)))
    : char))

;; --- char classification lookup table (lexer hot path) ----------------------
;; The per-character scan loops (symbol and number scans, whitespace skipping,
;; the main dispatch) tested character classes with `fmt-is-*`, which stay real
;; function calls at every opt level. Lexing ~9 MB of source therefore paid
;; millions of call prologues just to classify bytes. Precompute a 256-entry
;; class table once per process and test membership with an inline array lookup.
;; Bit 0 = whitespace, bit 1 = digit, bit 2 = symbol char, bit 3 = hex digit.
(define fmt-char-class-table : (Array i64)
  (make-array i64 256))
(define fmt-char-class-ready : bool
  false)

(define (fmt-char-class-init) : unit
  (if fmt-char-class-ready
    unit
    (let
      [i : i64 0]
      (begin
        (while (< i 256)
          (let
            [c : char (cast i : char)]
            [mask : i64
              (+
                (if (fmt-is-space c)
                  1
                  0)
                (+
                  (if (fmt-is-digit c)
                    2
                    0)
                  (+
                    (if (fmt-is-symbol-char c)
                      4
                      0)
                    (if (fmt-is-hex-digit c)
                      8
                      0))))]
            (begin
              (array-set! fmt-char-class-table i mask)
              (set! i (+ i 1)))))
        (set! fmt-char-class-ready true)))))

;; Inline class test: no function call, just a table load and bit test.
(defmacro (fmt-char-class? [c : Expr] [mask : i64]) : bool
  `(not (= 0 (bit-and (array-ref fmt-char-class-table (cast ,c : i64)) ,mask))))

(define (fmt-starts-number [data : (Ptr u8)] [i : i64] [n : i64]) : bool
  (let
    [c : char (fmt-source-byte-bounds-proven data i)]
    (if (fmt-is-digit c)
      true
      (if (= c #-')
        (if (< (+ i 1) n)
          (fmt-is-digit (fmt-source-byte-bounds-proven data (+ i 1)))
          false)
        false))))

(define (fmt-number-digits-start [data : (Ptr u8)] [start : i64]) : i64
  (if (= (fmt-source-byte-bounds-proven data start) #-')
    (+ start 1)
    start))

(define (fmt-number-prefixed? [data : (Ptr u8)] [start : i64] [n : i64]) : bool
  (let
    [digits-start : i64 (fmt-number-digits-start data start)]
    (if (< (+ digits-start 1) n)
      (if (= (fmt-source-byte-bounds-proven data digits-start) #0')
        (let
          [prefix : char
            (fmt-source-byte-bounds-proven data (+ digits-start 1))]
          (or (= prefix #x') (= prefix #X') (= prefix #b') (= prefix #B')))
        false)
      false)))

(define (fmt-number-prefix-base [data : (Ptr u8)] [start : i64]) : i64
  (let
    [prefix : char
      (fmt-source-byte-bounds-proven
        data
        (+ (fmt-number-digits-start data start) 1))]
    (if (or (= prefix #x') (= prefix #X'))
      16
      2)))

(define (fmt-starts-ellipsis [data : (Ptr u8)] [i : i64] [n : i64]) : bool
  (and
    (< (+ i 2) n)
    (= (fmt-source-byte-bounds-proven data i) #.')
    (= (fmt-source-byte-bounds-proven data (+ i 1)) #.')
    (= (fmt-source-byte-bounds-proven data (+ i 2)) #.')))

(define (fmt-scan-based-int-end
  [data : (Ptr u8)]
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
            [c : char (fmt-source-byte-bounds-proven data j)]
            (if (if (= base 16)
              (fmt-is-hex-digit c)
              (fmt-is-binary-digit c))
              (set! j (+ j 1))
              (set! keep false)))
          (set! keep false)))
      j)))

(define (fmt-scan-prefixed-number-end-result
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : ResultFmtI64
  (let
    [digits-start : i64 (fmt-number-digits-start data start)]
    [base : i64 (fmt-number-prefix-base data start)]
    [value-start : i64 (+ digits-start 2)]
    [end : i64 (fmt-scan-based-int-end data value-start n base)]
    (if (= end value-start)
      (ErrFmtI64
        (fmt-source-error-at
          src
          start
          "format lexer: malformed integer literal"))
      (if (if (< end n)
        (fmt-is-symbol-char (fmt-source-byte-bounds-proven data end))
        false)
        (ErrFmtI64
          (fmt-source-error-at
            src
            start
            "format lexer: malformed integer literal"))
        (OkFmtI64 end)))))

(define (fmt-scan-prefixed-number-end
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : i64
  (match (fmt-scan-prefixed-number-end-result src data start n)
    [(OkFmtI64 end) end]
    [(ErrFmtI64 err)
      (begin
        (panic (format-source-error-message err))
        ;; lint-allow: unreachable-code
        start)]))

(define (fmt-scan-decimal-number-end [data : (Ptr u8)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [seen-dot : bool false]
    [keep : bool true]
    (begin
      (if (and (< j n) (= (fmt-source-byte-bounds-proven data j) #-'))
        (set! j (+ j 1))
        (set! j j))
      (while keep
        (if (< j n)
          (let
            [c : char (fmt-source-byte-bounds-proven data j)]
            (if (and (= c #.') (not seen-dot))
              (begin
                (set! seen-dot true)
                (set! j (+ j 1)))
              (if (or (fmt-is-digit c) (= c #_'))
                (set! j (+ j 1))
                (set! keep false))))
          (set! keep false)))
      j)))

(define (fmt-scan-number-end-result
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : ResultFmtI64
  (if (fmt-number-prefixed? data start n)
    (fmt-scan-prefixed-number-end-result src data start n)
    (OkFmtI64 (fmt-scan-decimal-number-end data start n))))

(define (fmt-scan-number-end
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : i64
  (match (fmt-scan-number-end-result src data start n)
    [(OkFmtI64 end) end]
    [(ErrFmtI64 err)
      (begin
        (panic (format-source-error-message err))
        ;; lint-allow: unreachable-code
        start)]))

(define (fmt-scan-symbol-end [data : (Ptr u8)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (fmt-char-class? (fmt-source-byte-bounds-proven data j) 4)
            (set! j (+ j 1))
            (set! keep false))
          (set! keep false)))
      j)))

(define (fmt-scan-comment-end [data : (Ptr u8)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (= (fmt-source-byte-bounds-proven data j) #\newline')
            (set! keep false)
            (set! j (+ j 1)))
          (set! keep false)))
      j)))

(define (fmt-scan-string-end-result
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : ResultFmtI64
  (let
    [j : i64 start]
    [escaped : bool false]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (let
            [c : char (fmt-source-byte-bounds-proven data j)]
            (cond
              [escaped
                (begin
                  (set! escaped false)
                  (set! j (+ j 1)))]
              [(= c #\\')
                (begin
                  (set! escaped true)
                  (set! j (+ j 1)))]
              [(= c #"')
                (begin
                  (set! j (+ j 1))
                  (set! keep false))]
              [else (set! j (+ j 1))]))
          (begin
            (return
              (ErrFmtI64
                (fmt-source-error-at
                  src
                  (- start 1)
                  "format lexer: unterminated string literal"))))))
      (OkFmtI64 j))))

(define (fmt-scan-string-end
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : i64
  (match (fmt-scan-string-end-result src data start n)
    [(OkFmtI64 end) end]
    [(ErrFmtI64 err)
      (begin
        (panic (format-source-error-message err))
        ;; lint-allow: unreachable-code
        start)]))

(define (fmt-scan-char-end-result
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : ResultFmtI64
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
          (if (= (fmt-source-byte-bounds-proven data j) #'')
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

(define (fmt-scan-char-end
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : i64
  (match (fmt-scan-char-end-result src data start n)
    [(OkFmtI64 end) end]
    [(ErrFmtI64 err)
      (begin
        (panic (format-source-error-message err))
        ;; lint-allow: unreachable-code
        start)]))

(define (fmt-apostrophe-escape? [c : char]) : bool
  (or (= c #n') (= c #t') (= c #r') (= c #0') (= c #\\') (= c #'')))

(define (fmt-char-close-error
  [src : String]
  [data : (Ptr u8)]
  [idx : i64]
  [n : i64]) : ResultFmtMaybeCharEnd
  (if (< idx n)
    (if (= (fmt-source-byte-bounds-proven data idx) #'')
      (OkFmtCharEnd (+ idx 1))
      (ErrFmtCharEnd
        (fmt-source-error-at src idx "format lexer: expected ' after character")))
    (ErrFmtCharEnd
      (fmt-source-error-at
        src
        (- idx 1)
        "format lexer: unterminated character literal"))))

(define (fmt-scan-apostrophe-char-end-result
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : ResultFmtMaybeCharEnd
  (if (< (+ start 1) n)
    (let
      [payload : char (fmt-source-byte-bounds-proven data (+ start 1))]
      (cond
        [(= payload #\\')
          (let
            [esc-idx : i64 (+ start 2)]
            (if (< esc-idx n)
              (if (fmt-apostrophe-escape?
                (fmt-source-byte-bounds-proven data esc-idx))
                (fmt-char-close-error src data (+ start 3) n)
                (ErrFmtCharEnd
                  (fmt-source-error-at
                    src
                    esc-idx
                    "format lexer: unknown character escape")))
              (ErrFmtCharEnd
                (fmt-source-error-at
                  src
                  start
                  "format lexer: unterminated character literal"))))]
        [(or (= payload #'') (= payload #\newline') (= payload #\return'))
          (NoFmtCharEnd)]
        [else
          (if (< (+ start 2) n)
            (if (= (fmt-source-byte-bounds-proven data (+ start 2)) #'')
              (OkFmtCharEnd (+ start 3))
              (NoFmtCharEnd))
            (NoFmtCharEnd))]))
    (NoFmtCharEnd)))

(define (fmt-store-token
  [tokens : (Array FormatToken)]
  [starts : (Array i64)]
  [count : i64]
  [start : i64]
  [tok : FormatToken]) : unit
  (begin
    (array-set! tokens count tok)
    (array-set! starts count start)))

;; Copy `count` token slots into a freshly sized array. The lexer sizes its
;; token buffers to an estimate of the token count and grows them by doubling
;; rather than pre-allocating one slot per source byte (most bytes are inside
;; multi-character tokens or whitespace, so the byte-sized arrays were ~3x
;; larger than needed and paid that cost in zero-init on every file).
(define (fmt-grow-token-array
  [old : (Array FormatToken)]
  [count : i64]
  [newcap : i64]) : (Array FormatToken)
  (let
    [bigger : (Array FormatToken) (make-array FormatToken newcap)]
    [j : i64 0]
    (begin
      (while (< j count)
        (begin
          (array-set! bigger j (array-ref old j))
          (set! j (+ j 1))))
      bigger)))

(define (fmt-grow-i64-array [old : (Array i64)] [count : i64] [newcap : i64]) : (Array
    i64)
  (let
    [bigger : (Array i64) (make-array i64 newcap)]
    [j : i64 0]
    (begin
      (while (< j count)
        (begin
          (array-set! bigger j (array-ref old j))
          (set! j (+ j 1))))
      bigger)))

;; Token-buffer capacity estimate for a `n`-byte source: roughly one token per
;; three bytes, with slack for short inputs and the trailing `FmtEnd`.
(define (fmt-token-capacity-estimate [n : i64]) : i64
  (+ (/ n 3) 16))

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
    [data : (Ptr u8)
      (unsafe
        (string-data (& src)))]
    [cap : i64 (fmt-token-capacity-estimate n)]
    [tokens : (Array FormatToken) (make-array FormatToken cap)]
    [starts : (Array i64) (make-array i64 cap)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (fmt-char-class-init)
      (while (< i n)
        (begin
          ;; Each iteration emits at most one token; keep one free slot.
          (if (>= count cap)
            (let
              [newcap : i64 (* cap 2)]
              (begin
                (set! tokens (fmt-grow-token-array tokens count newcap))
                (set! starts (fmt-grow-i64-array starts count newcap))
                (set! cap newcap)))
            unit)
          (let
            [c : char (fmt-source-byte-bounds-proven data i)]
            (cond
              [(fmt-char-class? c 1) (set! i (+ i 1))]
              [(= c #;')
                (let
                  [end : i64 (fmt-scan-comment-end data i n)]
                  (begin
                    (fmt-store-token
                      tokens
                      starts
                      count
                      i
                      (FmtComment (substring src i (- end i))))
                    (set! count (+ count 1))
                    (set! i end)))]
              [(= c #(')
                (begin
                  (fmt-store-token tokens starts count i (FmtLParen))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c #)')
                (begin
                  (fmt-store-token tokens starts count i (FmtRParen))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c #[')
                (begin
                  (fmt-store-token tokens starts count i (FmtLBracket))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c #]')
                (begin
                  (fmt-store-token tokens starts count i (FmtRBracket))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c #:')
                (begin
                  (fmt-store-token tokens starts count i (FmtColon))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c #'')
                (match (fmt-scan-apostrophe-char-end-result src data i n)
                  [(OkFmtCharEnd end)
                    (begin
                      (fmt-store-token
                        tokens
                        starts
                        count
                        i
                        (FmtChar (substring src i (- end i))))
                      (set! count (+ count 1))
                      (set! i end))]
                  [(ErrFmtCharEnd err) (return (ErrFormatTokenStream err))]
                  [(NoFmtCharEnd)
                    (begin
                      (fmt-store-token tokens starts count i (FmtQuote))
                      (set! count (+ count 1))
                      (set! i (+ i 1)))])]
              [(= c #`')
                (begin
                  (fmt-store-token tokens starts count i (FmtBacktick))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(fmt-starts-ellipsis data i n)
                (begin
                  (fmt-store-token tokens starts count i (FmtSymbol "..."))
                  (set! count (+ count 1))
                  (set! i (+ i 3)))]
              [(= c #.')
                (begin
                  (fmt-store-token tokens starts count i (FmtDot))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c #,')
                (if (< (+ i 1) n)
                  (if (= (fmt-source-byte-bounds-proven data (+ i 1)) #@')
                    (begin
                      (fmt-store-token tokens starts count i (FmtCommaAt))
                      (set! count (+ count 1))
                      (set! i (+ i 2)))
                    (begin
                      (fmt-store-token tokens starts count i (FmtComma))
                      (set! count (+ count 1))
                      (set! i (+ i 1))))
                  (begin
                    (fmt-store-token tokens starts count i (FmtComma))
                    (set! count (+ count 1))
                    (set! i (+ i 1))))]
              [(= c #"')
                (match (fmt-scan-string-end-result src data (+ i 1) n)
                  [(OkFmtI64 end)
                    (begin
                      (fmt-store-token
                        tokens
                        starts
                        count
                        i
                        (FmtString (substring src i (- end i))))
                      (set! count (+ count 1))
                      (set! i end))]
                  [(ErrFmtI64 err) (return (ErrFormatTokenStream err))])]
              [(= c ##')
                (match (fmt-scan-char-end-result src data (+ i 1) n)
                  [(OkFmtI64 end)
                    (begin
                      (fmt-store-token
                        tokens
                        starts
                        count
                        i
                        (FmtChar (substring src i (- end i))))
                      (set! count (+ count 1))
                      (set! i end))]
                  [(ErrFmtI64 err) (return (ErrFormatTokenStream err))])]
              [(fmt-starts-number data i n)
                (match (fmt-scan-number-end-result src data i n)
                  [(OkFmtI64 end)
                    (begin
                      (fmt-store-token
                        tokens
                        starts
                        count
                        i
                        (FmtInt (substring src i (- end i))))
                      (set! count (+ count 1))
                      (set! i end))]
                  [(ErrFmtI64 err) (return (ErrFormatTokenStream err))])]
              [(fmt-char-class? c 4)
                (let
                  [end : i64 (fmt-scan-symbol-end data i n)]
                  (begin
                    (fmt-store-token
                      tokens
                      starts
                      count
                      i
                      (FmtSymbol (substring src i (- end i))))
                    (set! count (+ count 1))
                    (set! i end)))]
              [else
                (return
                  (ErrFormatTokenStream
                    (fmt-source-error-at
                      src
                      i
                      "format lexer: unexpected character")))]))))
      (if (>= count cap)
        (let
          [newcap : i64 (* cap 2)]
          (begin
            (set! tokens (fmt-grow-token-array tokens count newcap))
            (set! starts (fmt-grow-i64-array starts count newcap))
            (set! cap newcap)))
        unit)
      (fmt-store-token tokens starts count n (FmtEnd))
      (OkFormatTokenStream (FormatTokenStream src tokens starts (+ count 1))))))

(define (format-lex [src : String]) : FormatTokenStream
  (match (format-lex-result src)
    [(OkFormatTokenStream stream) stream]
    [(ErrFormatTokenStream err)
      (begin
        (panic (format-source-error-message err))
        ;; lint-allow: unreachable-code
        (format-empty-token-stream))]))