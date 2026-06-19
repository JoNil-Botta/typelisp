;; format_cst.tl - Neutral formatter CST over format_tokens.tl (#326).
;;
;; The CST keeps enough shape for a formatter without committing to final
;; layout: atoms keep original token spelling, comments stay as trivia nodes,
;; and parenthesized/bracketed lists keep their delimiter kind.
(import "../stdlib/io.tl")
(import "format_tokens.tl")

(defenum FormatCst
  (FmtCstAtom FormatToken)
  (FmtCstComment String)
  (FmtCstPrefix FormatToken (Box FormatCst))
  (FmtCstList (Box FormatCstList))
  (FmtCstBracketList (Box FormatCstList))
  (FmtCstForms (Box FormatCstList)))

(defenum FormatCstList
  (FmtCstNil)
  (FmtCstCons FormatCst (Box FormatCstList)))

(defenum FormatParsedCst
  (FmtParsedCst FormatCst i64))

(defenum FormatParsedCstList
  (FmtParsedCstList FormatCstList i64))

(defenum ResultFormatCst
  (OkFormatCst FormatCst)
  (ErrFormatCst FormatSourceError))

(defenum ResultFormatParsedCst
  (OkFormatParsedCst FormatParsedCst)
  (ErrFormatParsedCst FormatSourceError))

(defenum ResultFormatParsedCstList
  (OkFormatParsedCstList FormatParsedCstList)
  (ErrFormatParsedCstList FormatSourceError))

(define (fmt-list-count [items : FormatCstList]) : i64
  (match items
    [(FmtCstNil) 0]
    [(FmtCstCons _ rest) (+ 1 (fmt-list-count (box-get rest)))]))

(define (fmt-cst-count [node : FormatCst]) : i64
  (match node
    [(FmtCstAtom _) 1]
    [(FmtCstComment _) 1]
    [(FmtCstPrefix _ child) (+ 1 (fmt-cst-count (box-get child)))]
    [(FmtCstList items) (+ 1 (fmt-cst-list-total (box-get items)))]
    [(FmtCstBracketList items) (+ 1 (fmt-cst-list-total (box-get items)))]
    [(FmtCstForms items) (+ 1 (fmt-cst-list-total (box-get items)))]))

(define (fmt-cst-list-total [items : FormatCstList]) : i64
  (match items
    [(FmtCstNil) 0]
    [(FmtCstCons node rest)
      (+ (fmt-cst-count node) (fmt-cst-list-total (box-get rest)))]))

(define (fmt-cst-comment-count [node : FormatCst]) : i64
  (match node
    [(FmtCstAtom _) 0]
    [(FmtCstComment _) 1]
    [(FmtCstPrefix _ child) (fmt-cst-comment-count (box-get child))]
    [(FmtCstList items) (fmt-cst-list-comment-count (box-get items))]
    [(FmtCstBracketList items) (fmt-cst-list-comment-count (box-get items))]
    [(FmtCstForms items) (fmt-cst-list-comment-count (box-get items))]))

(define (fmt-cst-list-comment-count [items : FormatCstList]) : i64
  (match items
    [(FmtCstNil) 0]
    [(FmtCstCons node rest)
      (+
        (fmt-cst-comment-count node)
        (fmt-cst-list-comment-count (box-get rest)))]))

(define (fmt-cst-bracket-count [node : FormatCst]) : i64
  (match node
    [(FmtCstAtom _) 0]
    [(FmtCstComment _) 0]
    [(FmtCstPrefix _ child) (fmt-cst-bracket-count (box-get child))]
    [(FmtCstList items) (fmt-cst-list-bracket-count (box-get items))]
    [(FmtCstBracketList items)
      (+ 1 (fmt-cst-list-bracket-count (box-get items)))]
    [(FmtCstForms items) (fmt-cst-list-bracket-count (box-get items))]))

(define (fmt-cst-list-bracket-count [items : FormatCstList]) : i64
  (match items
    [(FmtCstNil) 0]
    [(FmtCstCons node rest)
      (+
        (fmt-cst-bracket-count node)
        (fmt-cst-list-bracket-count (box-get rest)))]))

(define (fmt-unexpected-closing [tag : i64]) : bool
  (or (= tag (fmt-tag-rparen)) (= tag (fmt-tag-rbracket))))

(define (fmt-prefix-tag? [tag : i64]) : bool
  (or
    (= tag (fmt-tag-quote))
    (= tag (fmt-tag-backtick))
    (= tag (fmt-tag-comma))
    (= tag (fmt-tag-comma-at))))

(define (fmt-parse-seq-result
  [stream : FormatTokenStream]
  [idx : i64]
  [stop-tag : i64]) : ResultFormatParsedCstList
  (let
    [tag : i64 (format-token-tag (format-token-at stream idx))]
    (cond
      [(= tag (fmt-tag-end))
        (if (= stop-tag 0)
          (OkFormatParsedCstList (FmtParsedCstList FmtCstNil idx))
          (ErrFormatParsedCstList
            (FormatSourceError
              "format cst: unclosed delimiter"
              (format-token-span stream idx))))]
      [(and (!= stop-tag 0) (= tag stop-tag))
        (OkFormatParsedCstList (FmtParsedCstList FmtCstNil (+ idx 1)))]
      [(fmt-unexpected-closing tag)
        (ErrFormatParsedCstList
          (FormatSourceError
            "format cst: unexpected closing delimiter"
            (format-token-span stream idx)))]
      [else
        (match (fmt-parse-one-result stream idx)
          [(OkFormatParsedCst parsed)
            (match parsed
              [(FmtParsedCst node next)
                (match (fmt-parse-seq-result stream next stop-tag)
                  [(OkFormatParsedCstList parsed-rest)
                    (match parsed-rest
                      [(FmtParsedCstList rest final)
                        (OkFormatParsedCstList
                          (FmtParsedCstList (FmtCstCons node (box rest)) final))])]
                  [(ErrFormatParsedCstList err) (ErrFormatParsedCstList err)])])]
          [(ErrFormatParsedCst err) (ErrFormatParsedCstList err)])])))

(define (fmt-parse-seq
  [stream : FormatTokenStream]
  [idx : i64]
  [stop-tag : i64]) : FormatParsedCstList
  (match (fmt-parse-seq-result stream idx stop-tag)
    [(OkFormatParsedCstList parsed) parsed]
    [(ErrFormatParsedCstList err)
      (begin
        (panic (format-source-error-message err))
        ;; lint-allow: unreachable-code
        (FmtParsedCstList FmtCstNil idx))]))

(define (fmt-parse-one-result [stream : FormatTokenStream] [idx : i64]) : ResultFormatParsedCst
  (let
    [tok : FormatToken (format-token-at stream idx)]
    [tag : i64 (format-token-tag (format-token-at stream idx))]
    (cond
      [(= tag (fmt-tag-lparen))
        (match (fmt-parse-seq-result stream (+ idx 1) (fmt-tag-rparen))
          [(OkFormatParsedCstList parsed)
            (match parsed
              [(FmtParsedCstList items next)
                (OkFormatParsedCst (FmtParsedCst (FmtCstList (box items)) next))])]
          [(ErrFormatParsedCstList err) (ErrFormatParsedCst err)])]
      [(= tag (fmt-tag-lbracket))
        (match (fmt-parse-seq-result stream (+ idx 1) (fmt-tag-rbracket))
          [(OkFormatParsedCstList parsed)
            (match parsed
              [(FmtParsedCstList items next)
                (OkFormatParsedCst
                  (FmtParsedCst (FmtCstBracketList (box items)) next))])]
          [(ErrFormatParsedCstList err) (ErrFormatParsedCst err)])]
      [(= tag (fmt-tag-comment))
        (OkFormatParsedCst
          (FmtParsedCst (FmtCstComment (format-token-text tok)) (+ idx 1)))]
      [(fmt-prefix-tag? tag)
        (match (fmt-parse-one-result stream (+ idx 1))
          [(OkFormatParsedCst parsed)
            (match parsed
              [(FmtParsedCst child next)
                (OkFormatParsedCst
                  (FmtParsedCst (FmtCstPrefix tok (box child)) next))])]
          [(ErrFormatParsedCst err) (ErrFormatParsedCst err)])]
      [(fmt-unexpected-closing tag)
        (ErrFormatParsedCst
          (FormatSourceError
            "format cst: unexpected closing delimiter"
            (format-token-span stream idx)))]
      [(= tag (fmt-tag-end))
        (ErrFormatParsedCst
          (FormatSourceError
            "format cst: unexpected end"
            (format-token-span stream idx)))]
      [else (OkFormatParsedCst (FmtParsedCst (FmtCstAtom tok) (+ idx 1)))])))

(define (fmt-parse-one [stream : FormatTokenStream] [idx : i64]) : FormatParsedCst
  (match (fmt-parse-one-result stream idx)
    [(OkFormatParsedCst parsed) parsed]
    [(ErrFormatParsedCst err)
      (begin
        (panic (format-source-error-message err))
        ;; lint-allow: unreachable-code
        (FmtParsedCst (FmtCstAtom (format-token-at stream idx)) idx))]))

(define (parse-format-tokens-result [stream : FormatTokenStream]) : ResultFormatCst
  (match (fmt-parse-seq-result stream 0 0)
    [(OkFormatParsedCstList parsed)
      (match parsed
        [(FmtParsedCstList items _) (OkFormatCst (FmtCstForms (box items)))])]
    [(ErrFormatParsedCstList err) (ErrFormatCst err)]))

(define (parse-format-tokens [stream : FormatTokenStream]) : FormatCst
  (match (parse-format-tokens-result stream)
    [(OkFormatCst tree) tree]
    [(ErrFormatCst err)
      (begin
        (panic (format-source-error-message err))
        ;; lint-allow: unreachable-code
        (FmtCstForms (box FmtCstNil)))]))

(define (parse-format-source-result [src : String]) : ResultFormatCst
  (match (format-lex-result src)
    [(OkFormatTokenStream stream) (parse-format-tokens-result stream)]
    [(ErrFormatTokenStream err) (ErrFormatCst err)]))

(define (parse-format-source [src : String]) : FormatCst
  (match (parse-format-source-result src)
    [(OkFormatCst tree) tree]
    [(ErrFormatCst err)
      (begin
        (panic (format-source-error-message err))
        ;; lint-allow: unreachable-code
        (FmtCstForms (box FmtCstNil)))]))

(define (format-cst-fixture) : String
  "(import \"std.tl\")
; header comment
(extern (print [arg0 : i64]) : unit)
(defenum Maybe (Some i64) (None))
(defstruct Point (x i64) (y i64))
(define (main [xs : (Array i64)] [p : Point]) : i64
  (let
    [n : i64 (array-ref xs 0)]
    [c : char ' ']
    (match (Some n)
      [(Some v) (+ v (cast c : i64))]
      [None 0])))")

(define (format-cst-boxed-nested-ok?) : bool
  (let
    [tree : FormatCst (parse-format-source "'(outer [x ; inner\n y] ,z)")]
    (and
      (= (fmt-cst-comment-count tree) 1)
      (> (fmt-cst-bracket-count tree) 0)
      (> (fmt-cst-count tree) 8))))

(define (format-cst-prefixed-int-ok?) : bool
  (let
    [stream : FormatTokenStream (format-lex "(0x2a -0b101010)")]
    (and
      (= (format-token-tag-count stream (fmt-tag-int)) 2)
      (= (format-token-tag (format-token-at stream 1)) (fmt-tag-int))
      (string-eq (format-token-text (format-token-at stream 1)) "0x2a")
      (= (format-token-tag (format-token-at stream 2)) (fmt-tag-int))
      (string-eq (format-token-text (format-token-at stream 2)) "-0b101010")
      (= (format-token-tag (format-token-at stream 4)) (fmt-tag-end)))))

(define (format-cst-apostrophe-char-ok?) : bool
  (let
    [stream : FormatTokenStream (format-lex "'a' '\"' '('")]
    (and
      (= (format-token-tag-count stream (fmt-tag-char)) 3)
      (= (format-token-tag (format-token-at stream 3)) (fmt-tag-end)))))

(define (format-cst-error-location-ok?) : bool
  (match (parse-format-source-result "(define x\n  ]")
    [(OkFormatCst _) false]
    [(ErrFormatCst err)
      (and
        (string-eq
          (format-source-error-message err)
          "format cst: unexpected closing delimiter")
        (format-source-span-eq? (format-source-error-span err) 2 3 2 3))]))

(define (format-cst-legacy-char-rejected-ok?) : bool
  (and
    (match (parse-format-source-result "#x'")
      [(OkFormatCst _) false]
      [(ErrFormatCst err)
        (string-eq
          (format-source-error-message err)
          "format lexer: unexpected character")])
    (match (parse-format-source-result "#\\space'")
      [(OkFormatCst _) false]
      [(ErrFormatCst err)
        (string-eq
          (format-source-error-message err)
          "format lexer: unexpected character")])))

(define (format-cst-self-test) : i64
  (let
    [stream : FormatTokenStream (format-lex (format-cst-fixture))]
    [tree : FormatCst (parse-format-source (format-cst-fixture))]
    (begin
      (unless (> (format-token-count stream) 40) (return 1))
      (unless (> (fmt-cst-count tree) 40) (return 2))
      (unless (= (fmt-cst-comment-count tree) 1) (return 3))
      (unless (> (fmt-cst-bracket-count tree) 4) (return 4))
      (unless (= (format-token-tag-count stream (fmt-tag-char)) 1) (return 5))
      (unless (format-cst-boxed-nested-ok?) (return 6))
      (unless (format-cst-prefixed-int-ok?) (return 7))
      (unless (format-cst-apostrophe-char-ok?) (return 8))
      (unless (format-cst-error-location-ok?) (return 9))
      (unless (format-cst-legacy-char-rejected-ok?) (return 10))
      42)))