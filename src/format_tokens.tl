;; format_tokens.tl - Comment-preserving tokens for the formatter.
;;
;; This lexer is separate from lex.tl because a formatter must keep source
;; spelling and comments. Whitespace is skipped; comments are retained
;; as trivia tokens so later layout rules can place them deliberately.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import stdlib.string)
(import stdlib.result)

(defenum FormatToken
  (LParen)
  (RParen)
  (LBracket)
  (RBracket)
  (Colon)
  (Quote)
  (Backtick)
  (Dot)
  (Comma)
  (CommaAt)
  (Int String)
  (Symbol String)
  (String String)
  (Char String)
  (Comment String)
  (End))

(defstruct FormatSourceSpan
  (start-line i64)
  (start-col i64)
  (end-line i64)
  (end-col i64))

(defstruct FormatSourceError
  (message String)
  (span FormatSourceSpan))

(import (result.result i64 FormatSourceError) as result_fmt_i64)

(defstruct FormatTokenStream
  (source String)
  (tokens (__tl_dyn-array FormatToken))
  (starts (__tl_dyn-array i64))
  (count i64))

(defstruct FormatPosition
  (line i64)
  (col i64))

(defenum ResultFormatTokenStream
  (Ok FormatTokenStream)
  (Err FormatSourceError))

(defenum ResultFmtMaybeCharEnd
  (No)
  (Ok i64)
  (Err FormatSourceError))

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
    [(FormatToken.LParen) (fmt-tag-lparen)]
    [(FormatToken.RParen) (fmt-tag-rparen)]
    [(FormatToken.LBracket) (fmt-tag-lbracket)]
    [(FormatToken.RBracket) (fmt-tag-rbracket)]
    [(FormatToken.Colon) (fmt-tag-colon)]
    [(FormatToken.Quote) (fmt-tag-quote)]
    [(FormatToken.Backtick) (fmt-tag-backtick)]
    [(FormatToken.Dot) (fmt-tag-dot)]
    [(FormatToken.Comma) (fmt-tag-comma)]
    [(FormatToken.CommaAt) (fmt-tag-comma-at)]
    [(FormatToken.Int _) (fmt-tag-int)]
    [(FormatToken.Symbol _) (fmt-tag-symbol)]
    [(FormatToken.String _) (fmt-tag-string)]
    [(FormatToken.Char _) (fmt-tag-char)]
    [(FormatToken.Comment _) (fmt-tag-comment)]
    [(FormatToken.End) (fmt-tag-end)]))

(define (format-token-text [tok : FormatToken]) : String
  (match tok
    [(FormatToken.LParen) "("]
    [(FormatToken.RParen) ")"]
    [(FormatToken.LBracket) "["]
    [(FormatToken.RBracket) "]"]
    [(FormatToken.Colon) ":"]
    [(FormatToken.Quote) "'"]
    [(FormatToken.Backtick) "`"]
    [(FormatToken.Dot) "."]
    [(FormatToken.Comma) ","]
    [(FormatToken.CommaAt) ",@"]
    [(FormatToken.Int text) text]
    [(FormatToken.Symbol text) text]
    [(FormatToken.String text) text]
    [(FormatToken.Char text) text]
    [(FormatToken.Comment text) text]
    [(FormatToken.End) ""]))

(define (format-token-at [stream : FormatTokenStream] [idx : i64]) : FormatToken
  (array-ref stream.tokens idx))

(define (format-token-start [stream : FormatTokenStream] [idx : i64]) : i64
  (array-ref stream.starts idx))

(define (format-token-count [stream : FormatTokenStream]) : i64
  stream.count)

(define (fmt-position-line [pos : FormatPosition]) : i64
  pos.line)

(define (fmt-position-col [pos : FormatPosition]) : i64
  pos.col)

(define (format-source-error-message [err : FormatSourceError]) : String
  err.message)

(define (format-source-error-span [err : FormatSourceError]) : FormatSourceSpan
  err.span)

(define (format-source-span-start-line [span : FormatSourceSpan]) : i64
  span.start-line)

(define (format-source-span-start-col [span : FormatSourceSpan]) : i64
  span.start-col)

(define (format-source-span-eq?
  [span : FormatSourceSpan]
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : bool
  (and
    (= span.start-line start-line)
    (= span.start-col start-col)
    (= span.end-line end-line)
    (= span.end-col end-col)))

(define (fmt-source-position-at [src : String] [target : i64]) : FormatPosition
  (let
    [n : i64 (string.string-length src)]
    [i : i64 0]
    [line : i64 1]
    [col : i64 1]
    (begin
      (while (and (< i target) (< i n))
        (let
          [c : char (string.string-ref src i)]
          (begin
            (if (= c '\n')
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
        stream.source
        (format-token-start (owned_view.compiler-owned-shared-view stream) idx))]
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
      (while (< i stream.count)
        (begin
          (if (=
            (format-token-tag
              (format-token-at (owned_view.compiler-owned-shared-view stream) i))
            wanted)
            (set! hits (+ hits 1))
            (set! hits hits))
          (set! i (+ i 1))))
      hits)))

(define (fmt-is-digit [c : char]) : bool
  (and (>= c '0') (<= c '9')))

(define (fmt-is-hex-digit [c : char]) : bool
  (or (fmt-is-digit c) (and (>= c 'a') (<= c 'f')) (and (>= c 'A') (<= c 'F'))))

(define (fmt-is-alpha [c : char]) : bool
  (or (and (>= c 'A') (<= c 'Z')) (and (>= c 'a') (<= c 'z'))))

(define (fmt-is-space [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

(define (fmt-is-symbol-punct [c : char]) : bool
  (or
    (= c '-')
    (= c '+')
    (= c '*')
    (= c '/')
    (= c '?')
    (= c '!')
    (= c '>')
    (= c '<')
    (= c '=')
    (= c '_')
    (= c '$')
    (= c '.')
    (= c '%')
    (= c '&')))

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
(define fmt-char-class-table : (__tl_dyn-array i64)
  (__tl_make-array i64 256))
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
              (set! (array-ref fmt-char-class-table i) mask)
              (set! i (+ i 1)))))
        (set! fmt-char-class-ready true)))))

;; Inline class test: no function call, just a table load and bit test.
(defmacro (fmt-char-class? [c : Expr] [mask : i64]) : bool
  `(not (= 0 (bit-and (array-ref fmt-char-class-table (cast ,c : i64)) ,mask))))

(define (fmt-starts-number [data : (Ptr u8)] [i : i64] [n : i64]) : bool
  (let
    [c : char (fmt-source-byte-bounds-proven data i)]
    (if (fmt-char-class? c 2)
      true
      (if (= c '-')
        (if (< (+ i 1) n)
          (fmt-char-class? (fmt-source-byte-bounds-proven data (+ i 1)) 2)
          false)
        false))))

(define (fmt-number-digits-start [data : (Ptr u8)] [start : i64]) : i64
  (if (= (fmt-source-byte-bounds-proven data start) '-')
    (+ start 1)
    start))

(define (fmt-number-prefixed? [data : (Ptr u8)] [start : i64] [n : i64]) : bool
  (let
    [digits-start : i64 (fmt-number-digits-start data start)]
    (if (< (+ digits-start 1) n)
      (if (= (fmt-source-byte-bounds-proven data digits-start) '0')
        (let
          [prefix : char
            (fmt-source-byte-bounds-proven data (+ digits-start 1))]
          (or (= prefix 'x') (= prefix 'X') (= prefix 'b') (= prefix 'B')))
        false)
      false)))

(define (fmt-number-prefix-base [data : (Ptr u8)] [start : i64]) : i64
  (let
    [prefix : char
      (fmt-source-byte-bounds-proven
        data
        (+ (fmt-number-digits-start data start) 1))]
    (if (or (= prefix 'x') (= prefix 'X'))
      16
      2)))

(define (fmt-starts-ellipsis [data : (Ptr u8)] [i : i64] [n : i64]) : bool
  (and
    (< (+ i 2) n)
    (= (fmt-source-byte-bounds-proven data i) '.')
    (= (fmt-source-byte-bounds-proven data (+ i 1)) '.')
    (= (fmt-source-byte-bounds-proven data (+ i 2)) '.')))

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
              (fmt-char-class? c 8)
              (or (= c '0') (= c '1')))
              (set! j (+ j 1))
              (set! keep false)))
          (set! keep false)))
      j)))

(define (fmt-scan-prefixed-number-end-result
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : result_fmt_i64.Result
  (let
    [digits-start : i64 (fmt-number-digits-start data start)]
    [base : i64 (fmt-number-prefix-base data start)]
    [value-start : i64 (+ digits-start 2)]
    [end : i64 (fmt-scan-based-int-end data value-start n base)]
    (if (= end value-start)
      (result_fmt_i64.Err
        (fmt-source-error-at
          src
          start
          "format lexer: malformed integer literal"))
      (if (if (< end n)
        (fmt-char-class? (fmt-source-byte-bounds-proven data end) 4)
        false)
        (result_fmt_i64.Err
          (fmt-source-error-at
            src
            start
            "format lexer: malformed integer literal"))
        (result_fmt_i64.Ok end)))))

(define (fmt-scan-decimal-number-end [data : (Ptr u8)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [seen-dot : bool false]
    [found : bool false]
    [valid : bool true]
    [keep : bool true]
    (begin
      (if (< j n)
        (if (= (fmt-source-byte-bounds-proven data j) '-')
          (set! j (+ j 1))
          unit)
        unit)
      (while keep
        (if (< j n)
          (let
            [c : char (fmt-source-byte-bounds-proven data j)]
            (cond
              [(and (= c '.') (not seen-dot))
                (begin
                  (set! seen-dot true)
                  (set! j (+ j 1)))]
              [(or (fmt-char-class? c 2) (= c '_'))
                (begin
                  (if (= c '_')
                    (set! valid false)
                    (if (and seen-dot (fmt-char-class? c 2))
                      (set! found true)
                      unit))
                  (set! j (+ j 1)))]
              [(and valid (or (not seen-dot) found) (or (= c 'e') (= c 'E')))
                (let
                  [mark : i64 j]
                  [exp-digits : i64 (+ j 1)]
                  (begin
                    (if (< exp-digits n)
                      (if (or
                        (= (fmt-source-byte-bounds-proven data exp-digits) '+')
                        (= (fmt-source-byte-bounds-proven data exp-digits) '-'))
                        (set! exp-digits (+ exp-digits 1))
                        unit)
                      unit)
                    (if (< exp-digits n)
                      (if (fmt-char-class?
                        (fmt-source-byte-bounds-proven data exp-digits)
                        2)
                        (begin
                          (while (and
                            (< exp-digits n)
                            (fmt-char-class?
                              (fmt-source-byte-bounds-proven data exp-digits)
                              2))
                            (set! exp-digits (+ exp-digits 1)))
                          (set! j exp-digits)
                          ;; A valid exponent terminates the numeric token;
                          ;; any following dot/underscore is rejected by the
                          ;; trailing-symbol guard rather than absorbed here.
                          (set! keep false))
                        (begin
                          ;; Leave an invalid marker at the scan end so the
                          ;; result wrapper can report the error at the
                          ;; numeric token start.
                          (set! j mark)
                          (set! keep false)))
                      (begin
                        (set! j mark)
                        (set! keep false)))))]
              [else (set! keep false)]))
          (set! keep false)))
      j)))

(define (fmt-scan-number-end-result
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : result_fmt_i64.Result
  (if (fmt-number-prefixed? data start n)
    (fmt-scan-prefixed-number-end-result src data start n)
    (let
      [end : i64 (fmt-scan-decimal-number-end data start n)]
      [malformed : bool
        (if (< end n)
          (fmt-char-class? (fmt-source-byte-bounds-proven data end) 4)
          false)]
      (if malformed
        (result_fmt_i64.Err
          (fmt-source-error-at
            src
            start
            (str_cat.str-cat
              (string.substring "format lexer: malformed integer literal" 0 24)
              "number"
              (string.substring "format lexer: malformed integer literal" 31 8))))
        (result_fmt_i64.Ok end)))))

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
          (if (= (fmt-source-byte-bounds-proven data j) '\n')
            (set! keep false)
            (set! j (+ j 1)))
          (set! keep false)))
      j)))

(define (fmt-scan-string-end-result
  [src : String]
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : result_fmt_i64.Result
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
              [(= c '\\')
                (begin
                  (set! escaped true)
                  (set! j (+ j 1)))]
              [(= c '"')
                (begin
                  (set! j (+ j 1))
                  (set! keep false))]
              [else (set! j (+ j 1))]))
          (return
            (result_fmt_i64.Err
              (fmt-source-error-at
                src
                (- start 1)
                "format lexer: unterminated string literal")))))
      (result_fmt_i64.Ok j))))

(define (fmt-apostrophe-escape? [c : char]) : bool
  (or (= c 'n') (= c 't') (= c 'r') (= c '0') (= c '\\') (= c '\'')))

(define (fmt-char-close-error
  [src : String]
  [data : (Ptr u8)]
  [idx : i64]
  [n : i64]) : ResultFmtMaybeCharEnd
  (if (< idx n)
    (if (= (fmt-source-byte-bounds-proven data idx) '\'')
      (ResultFmtMaybeCharEnd.Ok (+ idx 1))
      (ResultFmtMaybeCharEnd.Err
        (fmt-source-error-at src idx "format lexer: expected ' after character")))
    (ResultFmtMaybeCharEnd.Err
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
        [(= payload '\\')
          (let
            [esc-idx : i64 (+ start 2)]
            (if (< esc-idx n)
              (if (fmt-apostrophe-escape?
                (fmt-source-byte-bounds-proven data esc-idx))
                (fmt-char-close-error src data (+ start 3) n)
                (ResultFmtMaybeCharEnd.Err
                  (fmt-source-error-at
                    src
                    esc-idx
                    "format lexer: unknown character escape")))
              (ResultFmtMaybeCharEnd.Err
                (fmt-source-error-at
                  src
                  start
                  "format lexer: unterminated character literal"))))]
        [(or (= payload '\'') (= payload '\n') (= payload '\r'))
          (ResultFmtMaybeCharEnd.No)]
        [else
          (if (< (+ start 2) n)
            (if (= (fmt-source-byte-bounds-proven data (+ start 2)) '\'')
              (ResultFmtMaybeCharEnd.Ok (+ start 3))
              (ResultFmtMaybeCharEnd.No))
            (ResultFmtMaybeCharEnd.No))]))
    (ResultFmtMaybeCharEnd.No)))

(define (fmt-store-token
  [tokens : (__tl_dyn-array FormatToken)]
  [starts : (__tl_dyn-array i64)]
  [count : i64]
  [start : i64]
  [tok : FormatToken]) : unit
  (begin
    (set! (array-ref tokens count) tok)
    (set! (array-ref starts count) start)))

;; Copy `count` token slots into a freshly sized array. The lexer sizes its
;; token buffers to an estimate of the token count and grows them by doubling
;; rather than pre-allocating one slot per source byte (most bytes are inside
;; multi-character tokens or whitespace, so the byte-sized arrays were ~3x
;; larger than needed and paid that cost in zero-init on every file).
(define (fmt-grow-token-array
  [old : (__tl_dyn-array FormatToken)]
  [count : i64]
  [newcap : i64]) : (__tl_dyn-array FormatToken)
  (let
    [bigger : (__tl_dyn-array FormatToken) (__tl_make-array FormatToken newcap)]
    [j : i64 0]
    (begin
      (while (< j count)
        (begin
          (set! (array-ref bigger j) (array-ref old j))
          (set! j (+ j 1))))
      bigger)))

(define (fmt-grow-i64-array
  [old : (__tl_dyn-array i64)]
  [count : i64]
  [newcap : i64]) : (__tl_dyn-array i64)
  (let
    [bigger : (__tl_dyn-array i64) (__tl_make-array i64 newcap)]
    [j : i64 0]
    (begin
      (while (< j count)
        (begin
          (set! (array-ref bigger j) (array-ref old j))
          (set! j (+ j 1))))
      bigger)))

;; Token-buffer capacity estimate for a `n`-byte source: roughly one token per
;; three bytes, with slack for short inputs and the trailing `FmtEnd`.
(define (fmt-token-capacity-estimate [n : i64]) : i64
  (+ (/ n 3) 16))

(define (fmt-recovery-token-delimiter? [c : char]) : bool
  (or
    (fmt-char-class? c 1)
    (= c '(')
    (= c ')')
    (= c '[')
    (= c ']')
    (= c ';')
    (= c '"')
    (= c '\'')
    (= c '`')
    (= c ',')))

(define (fmt-scan-recovery-token-end [data : (Ptr u8)] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    (begin
      (while (and
        (< i n)
        (not
          (fmt-recovery-token-delimiter? (fmt-source-byte-bounds-proven data i))))
        (set! i (+ i 1)))
      (if (> i start)
        i
        (+ start 1)))))

;; The recovering mode is used by editor tooling on incomplete buffers. It
;; retains every proven token before an error, treats an unterminated string as
;; a string through EOF, and advances past other malformed source without
;; guessing an identifier. The formatter keeps the strict result surface.
(define (format-lex-mode-result [src : String] [recover : bool]) : ResultFormatTokenStream
  (let
    [n : i64 (string.string-length src)]
    [data : (Ptr u8)
      (unsafe
        (string-data (& src)))]
    [cap : i64 (fmt-token-capacity-estimate n)]
    [tokens : (__tl_dyn-array FormatToken) (__tl_make-array FormatToken cap)]
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 cap)]
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
                (set!
                  tokens
                  (fmt-grow-token-array
                    (owned_view.compiler-owned-shared-view tokens)
                    count
                    newcap))
                (set! starts (fmt-grow-i64-array starts count newcap))
                (set! cap newcap)))
            unit)
          (let
            [c : char (fmt-source-byte-bounds-proven data i)]
            (cond
              [(fmt-char-class? c 1) (set! i (+ i 1))]
              [(= c ';')
                (let
                  [end : i64 (fmt-scan-comment-end data i n)]
                  (begin
                    (fmt-store-token
                      (owned_view.compiler-owned-shared-view tokens)
                      (owned_view.compiler-owned-shared-view starts)
                      count
                      i
                      (FormatToken.Comment (string.substring src i (- end i))))
                    (set! count (+ count 1))
                    (set! i end)))]
              [(= c '(')
                (begin
                  (fmt-store-token
                    (owned_view.compiler-owned-shared-view tokens)
                    (owned_view.compiler-owned-shared-view starts)
                    count
                    i
                    (FormatToken.LParen))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c ')')
                (begin
                  (fmt-store-token
                    (owned_view.compiler-owned-shared-view tokens)
                    (owned_view.compiler-owned-shared-view starts)
                    count
                    i
                    (FormatToken.RParen))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c '[')
                (begin
                  (fmt-store-token
                    (owned_view.compiler-owned-shared-view tokens)
                    (owned_view.compiler-owned-shared-view starts)
                    count
                    i
                    (FormatToken.LBracket))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c ']')
                (begin
                  (fmt-store-token
                    (owned_view.compiler-owned-shared-view tokens)
                    (owned_view.compiler-owned-shared-view starts)
                    count
                    i
                    (FormatToken.RBracket))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c ':')
                (begin
                  (fmt-store-token
                    (owned_view.compiler-owned-shared-view tokens)
                    (owned_view.compiler-owned-shared-view starts)
                    count
                    i
                    (FormatToken.Colon))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c '\'')
                (match (fmt-scan-apostrophe-char-end-result
                  (owned_view.compiler-owned-shared-view src)
                  data
                  i
                  n)
                  [(ResultFmtMaybeCharEnd.Ok end)
                    (begin
                      (fmt-store-token
                        (owned_view.compiler-owned-shared-view tokens)
                        (owned_view.compiler-owned-shared-view starts)
                        count
                        i
                        (FormatToken.Char (string.substring src i (- end i))))
                      (set! count (+ count 1))
                      (set! i end))]
                  [(ResultFmtMaybeCharEnd.Err err)
                    (if recover
                      (begin
                        (fmt-store-token
                          (owned_view.compiler-owned-shared-view tokens)
                          (owned_view.compiler-owned-shared-view starts)
                          count
                          i
                          (FormatToken.Quote))
                        (set! count (+ count 1))
                        (set! i (+ i 1)))
                      (return (ResultFormatTokenStream.Err err)))]
                  [(ResultFmtMaybeCharEnd.No)
                    (begin
                      (fmt-store-token
                        (owned_view.compiler-owned-shared-view tokens)
                        (owned_view.compiler-owned-shared-view starts)
                        count
                        i
                        (FormatToken.Quote))
                      (set! count (+ count 1))
                      (set! i (+ i 1)))])]
              [(= c '`')
                (begin
                  (fmt-store-token
                    (owned_view.compiler-owned-shared-view tokens)
                    (owned_view.compiler-owned-shared-view starts)
                    count
                    i
                    (FormatToken.Backtick))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(fmt-starts-ellipsis data i n)
                (begin
                  (fmt-store-token
                    (owned_view.compiler-owned-shared-view tokens)
                    (owned_view.compiler-owned-shared-view starts)
                    count
                    i
                    (FormatToken.Symbol "..."))
                  (set! count (+ count 1))
                  (set! i (+ i 3)))]
              [(= c '.')
                (begin
                  (fmt-store-token
                    (owned_view.compiler-owned-shared-view tokens)
                    (owned_view.compiler-owned-shared-view starts)
                    count
                    i
                    (FormatToken.Dot))
                  (set! count (+ count 1))
                  (set! i (+ i 1)))]
              [(= c ',')
                (if (< (+ i 1) n)
                  (if (= (fmt-source-byte-bounds-proven data (+ i 1)) '@')
                    (begin
                      (fmt-store-token
                        (owned_view.compiler-owned-shared-view tokens)
                        (owned_view.compiler-owned-shared-view starts)
                        count
                        i
                        (FormatToken.CommaAt))
                      (set! count (+ count 1))
                      (set! i (+ i 2)))
                    (begin
                      (fmt-store-token
                        (owned_view.compiler-owned-shared-view tokens)
                        (owned_view.compiler-owned-shared-view starts)
                        count
                        i
                        (FormatToken.Comma))
                      (set! count (+ count 1))
                      (set! i (+ i 1))))
                  (begin
                    (fmt-store-token
                      (owned_view.compiler-owned-shared-view tokens)
                      (owned_view.compiler-owned-shared-view starts)
                      count
                      i
                      (FormatToken.Comma))
                    (set! count (+ count 1))
                    (set! i (+ i 1))))]
              [(= c '"')
                (match (fmt-scan-string-end-result
                  (owned_view.compiler-owned-shared-view src)
                  data
                  (+ i 1)
                  n)
                  [(result_fmt_i64.Ok end)
                    (begin
                      (fmt-store-token
                        (owned_view.compiler-owned-shared-view tokens)
                        (owned_view.compiler-owned-shared-view starts)
                        count
                        i
                        (FormatToken.String (string.substring src i (- end i))))
                      (set! count (+ count 1))
                      (set! i end))]
                  [(result_fmt_i64.Err err)
                    (if recover
                      (begin
                        (fmt-store-token
                          (owned_view.compiler-owned-shared-view tokens)
                          (owned_view.compiler-owned-shared-view starts)
                          count
                          i
                          (FormatToken.String (string.substring src i (- n i))))
                        (set! count (+ count 1))
                        (set! i n))
                      (return (ResultFormatTokenStream.Err err)))])]
              [(fmt-starts-number data i n)
                (match (fmt-scan-number-end-result
                  (owned_view.compiler-owned-shared-view src)
                  data
                  i
                  n)
                  [(result_fmt_i64.Ok end)
                    (begin
                      (fmt-store-token
                        (owned_view.compiler-owned-shared-view tokens)
                        (owned_view.compiler-owned-shared-view starts)
                        count
                        i
                        (FormatToken.Int
                          (string.substring
                            (owned_view.compiler-owned-shared-view src)
                            i
                            (- end i))))
                      (set! count (+ count 1))
                      (set! i end))]
                  [(result_fmt_i64.Err err)
                    (if recover
                      (let
                        [end : i64 (fmt-scan-recovery-token-end data i n)]
                        (begin
                          (fmt-store-token
                            (owned_view.compiler-owned-shared-view tokens)
                            (owned_view.compiler-owned-shared-view starts)
                            count
                            i
                            (FormatToken.Int (string.substring src i (- end i))))
                          (set! count (+ count 1))
                          (set! i end)))
                      (return (ResultFormatTokenStream.Err err)))])]
              [(fmt-char-class? c 4)
                (let
                  [end : i64 (fmt-scan-symbol-end data i n)]
                  (begin
                    (fmt-store-token
                      (owned_view.compiler-owned-shared-view tokens)
                      (owned_view.compiler-owned-shared-view starts)
                      count
                      i
                      (FormatToken.Symbol
                        (string.substring
                          (owned_view.compiler-owned-shared-view src)
                          i
                          (- end i))))
                    (set! count (+ count 1))
                    (set! i end)))]
              [else
                (if recover
                  (set! i (+ i 1))
                  (return
                    (ResultFormatTokenStream.Err
                      (fmt-source-error-at
                        (owned_view.compiler-owned-shared-view src)
                        i
                        "format lexer: unexpected character"))))]))))
      (if (>= count cap)
        (let
          [newcap : i64 (* cap 2)]
          (begin
            (set!
              tokens
              (fmt-grow-token-array
                (owned_view.compiler-owned-shared-view tokens)
                count
                newcap))
            (set!
              starts
              (fmt-grow-i64-array
                (owned_view.compiler-owned-shared-view starts)
                count
                newcap))
            (set! cap newcap)))
        unit)
      (fmt-store-token
        (owned_view.compiler-owned-shared-view tokens)
        (owned_view.compiler-owned-shared-view starts)
        count
        n
        (FormatToken.End))
      (ResultFormatTokenStream.Ok
        (FormatTokenStream
          src
          (owned_view.compiler-owned-shared-view tokens)
          starts
          (+ count 1))))))

(define (format-lex-result [src : String]) : ResultFormatTokenStream
  (format-lex-mode-result src false))

(define (format-lex-recover [src : String]) : FormatTokenStream
  (match (format-lex-mode-result
    (owned_view.compiler-owned-shared-view src)
    true)
    [(ResultFormatTokenStream.Ok stream) stream]
    ;; Recovering mode consumes every error path above. Keep this arm total so
    ;; callers do not need a second fallback grammar if that invariant changes.
    [(ResultFormatTokenStream.Err _)
      (FormatTokenStream
        src
        (__tl_make-array FormatToken 0)
        (__tl_make-array i64 0)
        0)]))

(define (format-lex [src : String]) : FormatTokenStream
  (match (format-lex-result src)
    [(ResultFormatTokenStream.Ok stream) stream]
    [(ResultFormatTokenStream.Err err)
      (io.panic (format-source-error-message err))]))